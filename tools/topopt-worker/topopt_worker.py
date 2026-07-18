#!/usr/bin/env python3
"""topopt-worker — a small, dependency-light LAN compute server that wraps the
EXISTING `topopt-cli` so a desktop (e.g. the maintainer's Mac Mini) runs the
optimizer while the iPad drives it (handoff 093, LAN compute offload).

Why this exists: Fine + design box (~5.4M voxels) is set by the iteration-0 build
peak, which recurs every rung and does not fit in the iPad's memory budget. On a
desktop that cap simply does not exist. STEP 0 already made `topopt-cli` produce
the SAME PART the app produces (configure_production_options + build_production_
loadcase), so a worker that shells out to `topopt-cli` returns exactly what the
app would have computed locally.

Design choices (deliberately minimal — single user, LAN only):
  * STDLIB ONLY (http.server + subprocess + threading). No pip install, runs on
    Linux/macOS/Windows with just python3. The core is platform-agnostic C++17;
    nothing here adds an OS dependency.
  * NO AUTH beyond binding to the LAN. This is a single-user tool on a trusted
    home/office network; bind to a specific interface (see --host) and do not
    expose it to the internet. Documented in README.md.
  * The CLI streams PROGRESS/VARIANT checkpoint lines to stdout and writes each
    accepted variant's mesh as it completes (run_job emit_progress), so this
    server forwards LIVE progress + PROGRESSIVE artifacts over SSE rather than
    blocking until the whole ladder finishes.

Endpoints:
  POST   /jobs                 multipart: `step` (the STEP/STL file) + `job`
                               (job.json). Runs topopt-cli in a per-job temp dir.
                               -> {"job_id": "..."}
  GET    /jobs/{id}/events     Server-Sent Events: progress/variant/log/done/error.
                               Replays from the start on (re)connect, so a dropped
                               connection (iPad sleeps) never loses a finished run.
  GET    /jobs/{id}/result     application/zip of the job's output directory.
  GET    /jobs/{id}/files/{n}  a single output artifact (progressive mesh fetch).
  DELETE /jobs/{id}            cancel: kill the subprocess.
  GET    /health               {ok, cli_version, fingerprint, worker_version, ...}
                               fingerprint = the core build id, so the app can
                               REFUSE a worker whose core differs from its own.
"""

import argparse
import io
import json
import os
import shutil
import subprocess
import sys
import threading
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORKER_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Configuration, resolved once at startup.


class Config:
    def __init__(self, cli, workdir, materials, rules, host, port):
        self.cli = cli
        self.workdir = workdir
        self.materials = materials  # optional; None => the CLI's build-time default
        self.rules = rules          # optional; None => the CLI's build-time default
        self.host = host
        self.port = port


CFG = None  # set in main()


# ---------------------------------------------------------------------------
# Job model. Events are append-only and guarded by a Condition so any number of
# SSE subscribers (usually one) can replay from the start and then block for more.


class Job:
    def __init__(self, job_id, tmpdir, out_dir):
        self.id = job_id
        self.tmpdir = tmpdir
        self.out_dir = out_dir
        self.proc = None
        self.events = []             # list[dict]
        self.done = False            # terminal event appended
        self.status = "running"      # running | done | error | cancelled
        self.cond = threading.Condition()

    def emit(self, event):
        with self.cond:
            self.events.append(event)
            if event.get("type") in ("done", "error", "cancelled"):
                self.done = True
                self.status = event["type"]
            self.cond.notify_all()
        # Echo a compact, line-oriented status to the server's OWN stdout so a
        # supervisor (the TopOpt Worker menu-bar app, handoff 097) can show the
        # active job + current rung/iter and hold a keep-awake assertion while a
        # job runs — WITHOUT a second HTTP client. This does not touch the SSE/HTTP
        # protocol; it is additive logging on top of the existing server.
        t = event.get("type")
        if t == "progress":
            print("STATUS job=%s state=running rung=%s rungs=%s iter=%s"
                  % (self.id, event.get("rung"), event.get("rungs"), event.get("iter")),
                  flush=True)
        elif t == "variant":
            print("STATUS job=%s state=running variant=%s"
                  % (self.id, event.get("mesh")), flush=True)
        elif t in ("done", "error", "cancelled"):
            print("STATUS job=%s state=%s" % (self.id, t), flush=True)


JOBS = {}
JOBS_LOCK = threading.Lock()


def parse_cli_line(line):
    """Map one topopt-cli stdout line to an SSE event dict, or None to skip.

    The CLI emits (run_job emit_progress, job.hpp):
      PROGRESS rung=<i> rungs=<n> iter=<k>
      VARIANT vf=<req> achieved=<vf> margin=<m> accepted=<0|1> mesh=<path>
    plus a human summary at the end (model:/variants:/report:/mesh:). We forward
    the structured lines as typed events and everything else as a log line. We do
    NOT fabricate progress the CLI did not emit.
    """
    line = line.rstrip("\n")
    if line.startswith("PROGRESS "):
        kv = _kv(line[len("PROGRESS "):])
        return {"type": "progress",
                "rung": _int(kv.get("rung")),
                "rungs": _int(kv.get("rungs")),
                "iter": _int(kv.get("iter"))}
    if line.startswith("VARIANT "):
        kv = _kv(line[len("VARIANT "):])
        mesh = kv.get("mesh")
        return {"type": "variant",
                "vf": _float(kv.get("vf")),
                "achieved": _float(kv.get("achieved")),
                "margin": _float(kv.get("margin")),
                "accepted": kv.get("accepted") == "1",
                "mesh": os.path.basename(mesh) if mesh else None}
    if line.strip():
        return {"type": "log", "line": line}
    return None


def _kv(s):
    out = {}
    for tok in s.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def run_job_thread(job, cmd):
    """Launch topopt-cli, stream its stdout as events, and post a terminal event.

    stderr is captured separately so a failure (bad job, disk full, solver error)
    surfaces its diagnostic in the `error` event instead of being lost.
    """
    try:
        job.proc = subprocess.Popen(
            cmd, cwd=job.tmpdir,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1)
    except OSError as e:
        job.emit({"type": "error", "message": f"failed to launch topopt-cli: {e}"})
        return

    stderr_buf = []
    stderr_t = threading.Thread(
        target=lambda: stderr_buf.extend(job.proc.stderr.readlines()), daemon=True)
    stderr_t.start()

    for line in job.proc.stdout:
        ev = parse_cli_line(line)
        if ev is not None:
            job.emit(ev)

    rc = job.proc.wait()
    stderr_t.join(timeout=5)

    if job.status == "cancelled":
        return  # a DELETE already posted the terminal event
    if rc == 0:
        meshes = sorted(os.listdir(job.out_dir)) if os.path.isdir(job.out_dir) else []
        job.emit({"type": "done", "returncode": 0,
                  "artifacts": meshes})
    else:
        msg = "".join(stderr_buf).strip() or f"topopt-cli exited with code {rc}"
        job.emit({"type": "error", "returncode": rc, "message": msg})


# ---------------------------------------------------------------------------
# Minimal multipart/form-data parser (stdlib `cgi` was removed in 3.13). Handles
# the two fields this API needs: `step` (a file) and `job` (the job.json text).


def parse_multipart(body, content_type):
    idx = content_type.find("boundary=")
    if idx < 0:
        raise ValueError("multipart request without a boundary")
    boundary = content_type[idx + len("boundary="):].strip().strip('"')
    delim = b"--" + boundary.encode()
    fields = {}
    for part in body.split(delim):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        if not _:
            continue
        headers = head.decode("utf-8", "replace")
        name = _header_param(headers, "name")
        filename = _header_param(headers, "filename")
        if name:
            fields[name] = {"filename": filename, "data": data}
    return fields


def _header_param(headers, param):
    key = param + '="'
    i = headers.find(key)
    if i < 0:
        return None
    i += len(key)
    j = headers.find('"', i)
    return headers[i:j] if j > i else None


# ---------------------------------------------------------------------------
# HTTP handler.


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass  # quiet; the launcher prints a startup banner

    # -- helpers ------------------------------------------------------------
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _not_found(self, msg="not found"):
        self._json(404, {"error": msg})

    def _job_from_path(self, parts):
        with JOBS_LOCK:
            return JOBS.get(parts[1]) if len(parts) > 1 else None

    # -- routing ------------------------------------------------------------
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if self.path == "/health":
            return self._health()
        if parts and parts[0] == "jobs":
            job = self._job_from_path(parts)
            if job is None:
                return self._not_found("no such job")
            if len(parts) == 3 and parts[2] == "events":
                return self._events(job)
            if len(parts) == 3 and parts[2] == "result":
                return self._result_zip(job)
            if len(parts) == 4 and parts[2] == "files":
                return self._file(job, parts[3])
            return self._json(200, {"job_id": job.id, "status": job.status})
        return self._not_found()

    def do_POST(self):
        if self.path.rstrip("/") == "/jobs":
            return self._create_job()
        return self._not_found()

    def do_DELETE(self):
        parts = self.path.strip("/").split("/")
        if parts and parts[0] == "jobs":
            job = self._job_from_path(parts)
            if job is None:
                return self._not_found("no such job")
            return self._cancel(job)
        return self._not_found()

    # -- endpoints ----------------------------------------------------------
    def _health(self):
        version, fingerprint = "unknown", "unknown"
        ok = True
        try:
            out = subprocess.run([CFG.cli, "--version"], capture_output=True,
                                 text=True, timeout=15).stdout
            kv = _kv(out.strip())
            version = kv.get("version", "unknown")
            fingerprint = kv.get("fingerprint", "unknown")
        except (OSError, subprocess.SubprocessError):
            ok = False
        with JOBS_LOCK:
            active = sum(1 for j in JOBS.values() if j.status == "running")
        self._json(200, {
            "ok": ok,
            "worker_version": WORKER_VERSION,
            "cli": CFG.cli,
            "cli_version": version,
            # The core build id. The app must compare this to its OWN core
            # fingerprint and REFUSE a mismatch (STEP 3d): a worker whose core
            # differs silently produces a different part.
            "fingerprint": fingerprint,
            "active_jobs": active,
        })

    def _create_job(self):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return self._json(400, {"error": "empty request body"})
        body = self.rfile.read(length)
        ctype = self.headers.get("Content-Type", "")
        try:
            fields = parse_multipart(body, ctype)
        except ValueError as e:
            return self._json(400, {"error": str(e)})
        if "step" not in fields or "job" not in fields:
            return self._json(400, {"error": "multipart must include 'step' and 'job'"})

        job_id = uuid.uuid4().hex[:16]
        tmpdir = os.path.join(CFG.workdir, job_id)
        out_dir = os.path.join(tmpdir, "out")
        os.makedirs(out_dir, exist_ok=True)

        # Save the geometry under its uploaded name (default model.step) and point
        # the job.json's `model` at it, so the CLI's relative-path resolution
        # (against the job-file dir) finds it regardless of what the client set.
        step_name = fields["step"]["filename"] or "model.step"
        step_name = os.path.basename(step_name)
        with open(os.path.join(tmpdir, step_name), "wb") as f:
            f.write(fields["step"]["data"])
        try:
            job_doc = json.loads(fields["job"]["data"].decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            shutil.rmtree(tmpdir, ignore_errors=True)
            return self._json(400, {"error": f"job.json is not valid JSON: {e}"})
        job_doc["model"] = step_name
        job_path = os.path.join(tmpdir, "job.json")
        with open(job_path, "w") as f:
            json.dump(job_doc, f)

        cmd = [CFG.cli, "run", job_path, "--out", out_dir]
        if CFG.materials:
            cmd += ["--materials", CFG.materials]
        if CFG.rules:
            cmd += ["--rules", CFG.rules]

        job = Job(job_id, tmpdir, out_dir)
        with JOBS_LOCK:
            JOBS[job_id] = job
        threading.Thread(target=run_job_thread, args=(job, cmd), daemon=True).start()
        self._json(202, {"job_id": job_id})

    def _events(self, job):
        # Server-Sent Events. Replay all events so far, then block for new ones;
        # end after the terminal event. Replaying from the start means a dropped
        # connection (iPad sleeps) loses nothing — reconnect re-reads the stream.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        idx = 0
        try:
            while True:
                with job.cond:
                    while idx >= len(job.events):
                        if job.done:
                            return
                        job.cond.wait(timeout=15.0)
                    batch = job.events[idx:]
                    idx = len(job.events)
                for ev in batch:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                self.wfile.flush()
                if batch and batch[-1].get("type") in ("done", "error", "cancelled"):
                    return
        except (BrokenPipeError, ConnectionResetError):
            return  # client went away; the job keeps running, events persist

    def _result_zip(self, job):
        if not os.path.isdir(job.out_dir):
            return self._not_found("no output yet")
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for name in sorted(os.listdir(job.out_dir)):
                z.write(os.path.join(job.out_dir, name), name)
        data = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition",
                         f'attachment; filename="{job.id}.zip"')
        self.end_headers()
        self.wfile.write(data)

    def _file(self, job, name):
        name = os.path.basename(name)
        path = os.path.join(job.out_dir, name)
        if not os.path.isfile(path):
            return self._not_found("no such artifact")
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _cancel(self, job):
        if job.proc is not None and job.proc.poll() is None:
            job.proc.kill()
        job.emit({"type": "cancelled"})
        self._json(200, {"job_id": job.id, "status": "cancelled"})


def main():
    global CFG
    ap = argparse.ArgumentParser(description="topopt LAN compute worker")
    ap.add_argument("--cli", default=os.environ.get("TOPOPT_CLI", "topopt-cli"),
                    help="path to the topopt-cli binary (or TOPOPT_CLI env)")
    ap.add_argument("--workdir", default=os.environ.get("TOPOPT_WORKER_DIR",
                    os.path.join(os.path.expanduser("~"), ".topopt-worker")),
                    help="scratch directory for per-job temp dirs")
    ap.add_argument("--materials", default=os.environ.get("TOPOPT_MATERIALS"),
                    help="materials.json (optional; else the CLI build default)")
    ap.add_argument("--rules", default=os.environ.get("TOPOPT_RULES"),
                    help="settings rules.json (optional; else the CLI build default)")
    ap.add_argument("--host", default="0.0.0.0",
                    help="bind address (0.0.0.0 = all interfaces on the LAN)")
    ap.add_argument("--port", type=int, default=8757)
    args = ap.parse_args()

    os.makedirs(args.workdir, exist_ok=True)
    CFG = Config(args.cli, args.workdir, args.materials, args.rules,
                 args.host, args.port)

    # Fail fast if the CLI is not runnable — the whole point is to wrap it.
    try:
        v = subprocess.run([CFG.cli, "--version"], capture_output=True,
                           text=True, timeout=15)
        print(f"topopt-worker {WORKER_VERSION}: {v.stdout.strip() or CFG.cli}")
    except (OSError, subprocess.SubprocessError) as e:
        print(f"WARNING: could not run '{CFG.cli} --version': {e}", file=sys.stderr)
        print("         set --cli or TOPOPT_CLI to the topopt-cli binary path.",
              file=sys.stderr)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"listening on http://{args.host}:{args.port}  (LAN only; no auth)")
    print(f"work dir: {args.workdir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")


if __name__ == "__main__":
    main()
