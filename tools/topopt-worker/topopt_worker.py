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
  * STDLIB ONLY (http.server + subprocess + threading + urllib). No pip install,
    runs on Linux/macOS/Windows with just python3. The core is platform-agnostic
    C++17; nothing here adds an OS dependency.
  * NO AUTH beyond binding to the LAN. This is a single-user tool on a trusted
    home/office network; bind to a specific interface (see --host) and do not
    expose it to the internet. Documented in README.md.
  * The CLI streams PROGRESS/VARIANT checkpoint lines to stdout and writes each
    accepted variant's mesh as it completes (run_job emit_progress), so this
    server forwards LIVE progress + PROGRESSIVE artifacts over SSE rather than
    blocking until the whole ladder finishes.

── JOB QUEUE (handoff 121) ─────────────────────────────────────────────────
The worker became HUMAN-FACING: multiple jobs can be submitted (from the iPad, or
several projects). Solves on this hardware are MEMORY-BANDWIDTH-BOUND — handoff
113 measured 127 GB/s of shared bandwidth, and the matvec is gather-bound at ~35%
of STREAM. Two solves running at once do NOT finish in half the time each; they
contend for the same bus and BOTH run slower, so N parallel jobs are slower than N
sequential ones. Therefore the default `max_concurrency` is 1: a second submitted
job QUEUES behind the running one instead of spawning a competing solver. This is
faster, not merely tidier. `--max-concurrency` raises it for future bigger
hardware (more memory channels), where the trade-off may flip.

The single-job protocol is UNCHANGED for a client that never queues: a lone job
starts immediately and streams exactly as before (no `queued` event). Only a job
that actually has to wait emits a `queued` event (with its position) and then
streams normally once it is promoted to running.

Endpoints:
  POST   /jobs                 multipart: `step` (the STEP/STL file) + `job`
                               (job.json). Enqueues a topopt-cli run in a per-job
                               temp dir. -> {"job_id": "..."}
  GET    /jobs                 list EVERY known job (id, project, state, progress,
                               timestamps, queue position) — the menu app + iPad
                               read this instead of inferring from one stream.
  GET    /jobs/{id}/events     Server-Sent Events: queued/progress/variant/log/
                               done/error/cancelled. Replays from the start on
                               (re)connect, so a dropped connection never loses a
                               finished run.
  GET    /jobs/{id}/result     application/zip of the job's output directory.
  GET    /jobs/{id}/files/{n}  a single output artifact (progressive mesh fetch).
  POST   /jobs/{id}/front      move a QUEUED job to the front of the queue.
  POST   /jobs/{id}/pause      pause a RUNNING solve (SIGSTOP the child).
  POST   /jobs/{id}/resume     resume a paused solve (SIGCONT the child).
  DELETE /jobs/{id}            cancel: kill the subprocess.
  GET    /health               {ok, cli_version, fingerprint, worker_version, ...}
                               fingerprint = the core build id, so the app can
                               REFUSE a worker whose core differs from its own.
"""

import argparse
import datetime
import errno
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORKER_VERSION = "1.1.0"

# Handoff 114 — worker.log rotation/retention. The child's stdout + stderr are
# tee'd, timestamped, to <workdir>/<job-id>/worker.log so a run's per-iteration
# history is durable on the desktop even if the iPad client dropped (handoff 106
# had to reconstruct a 10-hour run from three STL mtimes for lack of exactly this
# file). A size cap with a single rotation (worker.log -> worker.log.1) bounds the
# log to ~(1 + backups) * MAX bytes so a long run can't fill the disk. Both are
# env-overridable. The CLI stdout is ~1 short line/iteration (~60 B), so a full
# 4-rung production run is well under the default cap; the cap is the backstop.
WORKER_LOG_MAX_BYTES = int(
    os.environ.get("TOPOPT_WORKER_LOG_MAX_BYTES", str(8 * 1024 * 1024)))
WORKER_LOG_BACKUPS = int(os.environ.get("TOPOPT_WORKER_LOG_BACKUPS", "1"))

# SSE keepalive cadence (handoff 101). While a job runs, the events loop emits a
# ": ping" comment every this-many seconds if no real event was ready, so the
# client's inactivity watchdog stays fed through minutes-long optimizer iterations.
# Overridable via env for the E2E harness (which drives a fast heartbeat so the
# slow-sparse liveness path is provable in seconds, not minutes).
HEARTBEAT_SECONDS = float(os.environ.get("TOPOPT_HEARTBEAT_SECONDS", "20"))

# ---------------------------------------------------------------------------
# Configuration, resolved once at startup.


class Config:
    def __init__(self, cli, workdir, materials, rules, host, port,
                 max_concurrency=1, webhook_url=None):
        self.cli = cli
        self.workdir = workdir
        self.materials = materials  # optional; None => the CLI's build-time default
        self.rules = rules          # optional; None => the CLI's build-time default
        self.host = host
        self.port = port
        # Default 1: solves are memory-bandwidth-bound (see the module header), so
        # queueing a second job is FASTER than running it in parallel. Raise only on
        # hardware with more memory channels.
        self.max_concurrency = max_concurrency
        # Optional completion webhook (handoff 121, requirement 4): a small JSON is
        # POSTed here when any job reaches a terminal state. `ntfy.sh` is the
        # documented zero-infrastructure phone-notification recipe (README).
        self.webhook_url = webhook_url


CFG = None   # set in main()
SCHED = None  # the Scheduler, set in main() (or by a test)


# ---------------------------------------------------------------------------
# Job model. Events are append-only and guarded by a Condition so any number of
# SSE subscribers (usually one) can replay from the start and then block for more.


class Job:
    def __init__(self, job_id, tmpdir, out_dir, cmd, project_name=None):
        self.id = job_id
        self.tmpdir = tmpdir
        self.out_dir = out_dir
        self.cmd = cmd                    # argv the launcher runs when promoted
        self.project_name = project_name  # from job.json (handoff 121), may be None
        self.proc = None
        self.events = []             # list[dict]
        self.done = False            # terminal event appended
        # queued | running | done | error | cancelled  (handoff 121). Replaces the
        # old two-state `status`; the wire still exposes `status` as an alias.
        self.state = "queued"
        # True while a RUNNING solve is SIGSTOPped (handoff 121, requirement 7).
        # The state stays "running" (the job is not finished, not failed); `paused`
        # is a separate axis the UI renders and the iPad's freshness dimming reads.
        self.paused = False
        # Latest progress, tracked so GET /jobs answers rung/iter without replaying
        # the whole event log.
        self.rung = None
        self.rungs = None
        self.iter = None
        # Count of ACCEPTED variant meshes so far (handoff 124): the History pane on the
        # Mac shows a real outcome summary ("3 variants · 12m") rather than a placeholder.
        self.variants = 0
        # Timestamps (epoch seconds). created = submit; started = promoted to
        # running; finished = terminal.
        self.created_at = time.time()
        self.started_at = None
        self.finished_at = None
        self.cond = threading.Condition()

    def emit(self, event):
        with self.cond:
            self.events.append(event)
            t = event.get("type")
            if t == "progress":
                self.rung = event.get("rung")
                self.rungs = event.get("rungs")
                self.iter = event.get("iter")
            elif t == "variant" and event.get("accepted"):
                self.variants += 1
            elif t in ("done", "error", "cancelled"):
                self.done = True
                self.state = t
                if self.finished_at is None:
                    self.finished_at = time.time()
            self.cond.notify_all()
        # Echo a compact, line-oriented status to the server's OWN stdout so a log
        # reader (or a supervisor) can follow the active job — WITHOUT a second HTTP
        # client. This does not touch the SSE/HTTP protocol; it is additive logging.
        t = event.get("type")
        if t == "queued":
            print("STATUS job=%s state=queued position=%s"
                  % (self.id, event.get("position")), flush=True)
        elif t == "progress":
            print("STATUS job=%s state=running rung=%s rungs=%s iter=%s"
                  % (self.id, event.get("rung"), event.get("rungs"), event.get("iter")),
                  flush=True)
        elif t == "variant":
            print("STATUS job=%s state=running variant=%s"
                  % (self.id, event.get("mesh")), flush=True)
        elif t in ("done", "error", "cancelled"):
            print("STATUS job=%s state=%s" % (self.id, t), flush=True)
        # A completion webhook fires on ANY terminal state (handoff 121). Best-effort
        # and off the run thread — see post_webhook.
        if t in ("done", "error", "cancelled"):
            post_webhook(self, t, event)

    # -- lifecycle transitions (called by the Scheduler) --------------------

    def mark_started(self):
        """queued -> running (promoted). Records the start time; the `queued` event,
        if any, has already been emitted."""
        with self.cond:
            self.state = "running"
            if self.started_at is None:
                self.started_at = time.time()

    def snapshot(self, position=None):
        """The GET /jobs row for this job (handoff 121). Timestamps are epoch
        seconds; `position` is 1-based within the queue (only for a queued job)."""
        return {
            "id": self.id,
            "project": self.project_name,
            "state": self.state,
            "paused": self.paused,
            "rung": self.rung,
            "rungs": self.rungs,
            "iter": self.iter,
            "variants": self.variants,
            "position": position,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
        }


def parse_cli_line(line):
    """Map one topopt-cli stdout line to an SSE event dict, or None to skip.

    The CLI emits (run_job emit_progress, job.hpp):
      PROGRESS rung=<i> rungs=<n> iter=<k>
      VARIANT vf=<req> achieved=<vf> printed=<pf> margin=<m> accepted=<0|1> mesh=<path>
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
        # `achieved` = optimizer-achieved (continuous) fraction, the join key;
        # `printed` = printed/count basis the app's savings uses (handoff 104, a new
        # field — falls back to `achieved` for a pre-104 CLI that omits it).
        printed = kv.get("printed")
        return {"type": "variant",
                "vf": _float(kv.get("vf")),
                "achieved": _float(kv.get("achieved")),
                "printed": _float(printed) if printed is not None
                           else _float(kv.get("achieved")),
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


# ---------------------------------------------------------------------------
# Completion webhook (handoff 121, requirement 4). Fire-and-forget: a small JSON
# POST to a user-configured URL on any terminal state. Best-effort — a webhook that
# is slow or down NEVER affects the run — so it runs on a daemon thread with a
# short timeout and swallows every error. Documented recipe: point it at an
# ntfy.sh topic for a free, zero-infra phone push (README). We deliberately do NOT
# run our own push/email service: that means credentials + delivery infrastructure
# we don't want to own, and the iPad already gets in-app notice via re-attach.


def _webhook_summary(job, state, event):
    name = job.project_name or "job"
    if state == "done":
        artifacts = event.get("artifacts") or []
        meshes = [a for a in artifacts if a.endswith((".stl", ".3mf", ".obj"))]
        n = len(meshes)
        return "%s: %d variant%s ready" % (name, n, "" if n == 1 else "s")
    if state == "error":
        msg = (event.get("message") or "optimization failed").strip()
        return "%s: %s" % (name, msg.splitlines()[0][:200])
    return "%s: cancelled" % name


def post_webhook(job, state, event):
    url = CFG.webhook_url if CFG else None
    if not url:
        return
    payload = {
        "job": job.id,
        "project": job.project_name,
        "state": state,
        "summary": _webhook_summary(job, state, event),
        "worker_version": WORKER_VERSION,
    }

    def _send():
        try:
            body = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(
                url, data=body, method="POST",
                headers={"Content-Type": "application/json",
                         # ntfy.sh reads these to title/prioritise the push; a plain
                         # webhook receiver simply ignores them.
                         "Title": "TopOpt",
                         "X-Title": "TopOpt"})
            urllib.request.urlopen(req, timeout=10).read()
        except Exception:
            pass  # best-effort; a down webhook must never break or log-spam a run

    threading.Thread(target=_send, daemon=True).start()


# ---------------------------------------------------------------------------
# Scheduler (handoff 121). Owns the job table + the FIFO queue and enforces
# `max_concurrency`. A submitted job is enqueued; the scheduler promotes queued
# jobs to running as running slots free up. All queue mutations happen under one
# reentrant lock; the actual process launch (the `launcher`) is non-blocking (it
# spawns a thread), and a running job's completion calls back into `on_finished`,
# which promotes the next queued job.
#
# The launcher is injected so the queue STATE MACHINE is testable headlessly
# without spawning real solves: a test substitutes a launcher it controls and
# drives promotion deterministically (see e2e/queue_state_machine.py).


class Scheduler:
    def __init__(self, max_concurrency=1, launcher=None):
        self.max_concurrency = max(1, int(max_concurrency))
        self.launcher = launcher or default_launch
        self.jobs = {}        # id -> Job, insertion-ordered (submission order)
        self.queue = []       # list[str] of QUEUED job ids; index 0 = next to run
        self.running = set()  # ids currently running
        self.lock = threading.RLock()

    def submit(self, job):
        """Enqueue a job. If a slot is free it starts immediately (and gets NO
        `queued` event — the single-job protocol is byte-identical). Otherwise it
        is marked queued and emits one `queued` event with its position."""
        with self.lock:
            self.jobs[job.id] = job
            self.queue.append(job.id)
            self._pump_locked()
            queued_now = job.state == "queued"
            position = self._position_locked(job.id) if queued_now else None
        if queued_now:
            job.emit({"type": "queued", "position": position})

    def _pump_locked(self):
        """Promote queued jobs to running while slots are free. Caller holds lock."""
        while len(self.running) < self.max_concurrency and self.queue:
            jid = self.queue.pop(0)
            job = self.jobs.get(jid)
            if job is None or job.state != "queued":
                continue  # cancelled while queued — skip
            self.running.add(jid)
            job.mark_started()
            # Non-blocking: the launcher spawns the run thread and returns.
            self.launcher(job)

    def on_finished(self, job):
        """A running job reached a terminal state — free its slot and promote the
        next queued job. Called by the run thread after the terminal event."""
        with self.lock:
            self.running.discard(job.id)
            self._pump_locked()

    def cancel(self, job):
        """Cancel a job. A QUEUED job is dequeued (no process to kill) and marked
        cancelled; a RUNNING job's child is killed (its run thread posts the
        terminal event). Returns 'dequeued' | 'killed' | 'noop'."""
        with self.lock:
            if job.id in self.queue and job.state == "queued":
                self.queue.remove(job.id)
                job.emit({"type": "cancelled"})
                return "dequeued"
            running = job.id in self.running
        if running:
            # Kill outside the lock (subprocess IO). Emit the `cancelled` terminal
            # event HERE (as the pre-121 _cancel did) so the run thread's exit sees
            # state == "cancelled" and does NOT post a spurious `error` for the
            # killed child; the run thread's on_finished then promotes the next job.
            if job.proc is not None and job.proc.poll() is None:
                # If paused, resume first so the SIGKILL is delivered promptly.
                if job.paused:
                    _signal_child(job, signal.SIGCONT)
                    job.paused = False
                job.proc.kill()
            job.emit({"type": "cancelled"})
            return "killed"
        return "noop"

    def move_to_front(self, job):
        """Move a QUEUED job to the front so a quick check jumps an 8-hour run
        (handoff 121, requirement 6). Running jobs are never preempted. Returns
        True if the job was queued and moved."""
        with self.lock:
            if job.id in self.queue and job.state == "queued":
                self.queue.remove(job.id)
                self.queue.insert(0, job.id)
                return True
            return False

    def _position_locked(self, job_id):
        try:
            return self.queue.index(job_id) + 1  # 1-based
        except ValueError:
            return None

    def position(self, job_id):
        with self.lock:
            return self._position_locked(job_id)

    def get(self, job_id):
        with self.lock:
            return self.jobs.get(job_id)

    def list_snapshots(self):
        """All jobs as GET /jobs rows, in submission order, with live queue
        positions (handoff 121)."""
        with self.lock:
            rows = [j.snapshot(position=self._position_locked(j.id))
                    for j in self.jobs.values()]
            summary = {
                "max_concurrency": self.max_concurrency,
                "running": len(self.running),
                "queued": len(self.queue),
            }
        return rows, summary


def default_launch(job):
    """Production launcher: spawn the run thread for a promoted job."""
    threading.Thread(target=run_job_thread, args=(job,), daemon=True).start()


class RotatingLog:
    """Timestamped, size-capped tee of the CLI child's stdout/stderr to
    <workdir>/<job-id>/worker.log (handoff 114). Each line is prefixed with an ISO
    wall-clock timestamp and a `stdout`/`stderr`/`meta` stream tag, so a run's
    per-iteration history is durable and directly readable on the desktop even
    after the SSE client drops. When the file reaches `max_bytes` it is rotated to
    `worker.log.1` (older backup dropped) and a fresh file started, bounding disk
    to ~(1 + backups) * max_bytes. Thread-safe: the stdout loop and the stderr
    pump thread both write. A failure to open/write the log NEVER breaks the run —
    the log is best-effort observability, not part of the compute path.
    """

    def __init__(self, path, max_bytes=WORKER_LOG_MAX_BYTES,
                 backups=WORKER_LOG_BACKUPS):
        self.path = path
        self.max_bytes = max_bytes
        self.backups = backups
        self._lock = threading.Lock()
        self._size = 0
        try:
            self._f = open(path, "w", buffering=1)  # line-buffered
        except OSError:
            self._f = None

    def write(self, stream, text):
        if self._f is None:
            return
        ts = datetime.datetime.now().isoformat(timespec="milliseconds")
        line = "%s %-6s %s\n" % (ts, stream, text.rstrip("\n"))
        data = line.encode("utf-8", "replace")
        with self._lock:
            if self._f is None:
                return
            try:
                self._rotate_if_needed(len(data))
                self._f.write(line)
                self._f.flush()
                self._size += len(data)
            except OSError:
                pass

    def _rotate_if_needed(self, incoming):
        # Called under _lock. Rotate BEFORE writing a line that would exceed the cap.
        if self.max_bytes <= 0 or self._size + incoming <= self.max_bytes:
            return
        try:
            self._f.close()
        except OSError:
            pass
        self._f = None
        try:
            if self.backups > 0:
                bak = self.path + ".1"
                if os.path.exists(bak):
                    os.remove(bak)
                os.replace(self.path, bak)
        except OSError:
            pass
        # If reopen fails, self._f stays None and logging quietly stops.
        try:
            self._f = open(self.path, "w", buffering=1)
        except OSError:
            self._f = None
        self._size = 0

    def close(self):
        with self._lock:
            if self._f is not None:
                try:
                    self._f.close()
                except OSError:
                    pass
                self._f = None


def run_job_thread(job):
    """Launch topopt-cli, stream its stdout as events, and post a terminal event.

    stderr is captured separately so a failure (bad job, disk full, solver error)
    surfaces its diagnostic in the `error` event instead of being lost. Both
    stdout and stderr are ALSO tee'd, timestamped, to <workdir>/<job-id>/worker.log
    (handoff 114) with rotation/retention so a long run can't fill the disk.

    Handoff 121: on any exit this calls SCHED.on_finished(job) so the scheduler
    frees the slot and promotes the next queued job.
    """
    cmd = job.cmd
    log = RotatingLog(os.path.join(job.tmpdir, "worker.log"))
    log.write("meta", "launch " + " ".join(cmd))
    try:
        job.proc = subprocess.Popen(
            cmd, cwd=job.tmpdir,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1)
    except OSError as e:
        log.write("meta", f"failed to launch topopt-cli: {e}")
        log.close()
        job.emit({"type": "error", "message": f"failed to launch topopt-cli: {e}"})
        if SCHED is not None:
            SCHED.on_finished(job)
        return

    stderr_buf = []

    def _pump_stderr():
        for line in job.proc.stderr:
            stderr_buf.append(line)
            log.write("stderr", line)

    stderr_t = threading.Thread(target=_pump_stderr, daemon=True)
    stderr_t.start()

    for line in job.proc.stdout:
        log.write("stdout", line)
        ev = parse_cli_line(line)
        if ev is not None:
            job.emit(ev)

    rc = job.proc.wait()
    stderr_t.join(timeout=5)
    log.write("meta", f"exit rc={rc}")
    log.close()

    try:
        if job.state == "cancelled":
            return  # a DELETE already posted the terminal event
        if rc == 0:
            meshes = sorted(os.listdir(job.out_dir)) if os.path.isdir(job.out_dir) else []
            job.emit({"type": "done", "returncode": 0, "artifacts": meshes})
        else:
            msg = "".join(stderr_buf).strip() or f"topopt-cli exited with code {rc}"
            job.emit({"type": "error", "returncode": rc, "message": msg})
    finally:
        if SCHED is not None:
            SCHED.on_finished(job)


def _signal_child(job, sig):
    """Send a signal to the job's child, best-effort. Used for pause/resume/kill."""
    try:
        if job.proc is not None and job.proc.poll() is None:
            job.proc.send_signal(sig)
            return True
    except (OSError, ValueError):
        pass
    return False


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
        return SCHED.get(parts[1]) if len(parts) > 1 else None

    # -- routing ------------------------------------------------------------
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if self.path == "/health":
            return self._health()
        if parts and parts[0] == "jobs":
            if len(parts) == 1:
                return self._jobs_list()          # GET /jobs (handoff 121)
            job = self._job_from_path(parts)
            if job is None:
                return self._not_found("no such job")
            if len(parts) == 3 and parts[2] == "events":
                return self._events(job)
            if len(parts) == 3 and parts[2] == "result":
                return self._result_zip(job)
            if len(parts) == 4 and parts[2] == "files":
                return self._file(job, parts[3])
            return self._json(200, self._single_job(job))
        return self._not_found()

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        if self.path.rstrip("/") == "/jobs":
            return self._create_job()
        # /jobs/{id}/{action}  — queue reorder + pause/resume (handoff 121).
        if len(parts) == 3 and parts[0] == "jobs":
            job = self._job_from_path(parts)
            if job is None:
                return self._not_found("no such job")
            if parts[2] == "front":
                return self._move_front(job)
            if parts[2] == "pause":
                return self._pause(job)
            if parts[2] == "resume":
                return self._resume(job)
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
        _, summary = SCHED.list_snapshots()
        self._json(200, {
            "ok": ok,
            "worker_version": WORKER_VERSION,
            "cli": CFG.cli,
            "cli_version": version,
            # The core build id. The app must compare this to its OWN core
            # fingerprint and REFUSE a mismatch (STEP 3d): a worker whose core
            # differs silently produces a different part.
            "fingerprint": fingerprint,
            "active_jobs": summary["running"],
            "queued_jobs": summary["queued"],
            "max_concurrency": summary["max_concurrency"],
        })

    def _single_job(self, job):
        # Back-compat: the client's status probe (handoff 101) reads `status`; keep
        # it as an alias for the canonical `state`, and add the richer fields.
        snap = job.snapshot(position=SCHED.position(job.id))
        snap["status"] = job.state
        snap["job_id"] = job.id
        return snap

    def _jobs_list(self):
        rows, summary = SCHED.list_snapshots()
        out = {"jobs": rows}
        out.update(summary)
        self._json(200, out)

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

        # Project name for the human-facing job list (handoff 121). PREFER the explicit
        # multipart `project` field (the app sends it there — handoff 129); fall back to
        # a `project`/`project_name` key in job.json only for an OLDER client. None is
        # fine (the UI shows "job").
        project_name = None
        if "project" in fields:
            try:
                project_name = fields["project"]["data"].decode("utf-8").strip() or None
            except UnicodeDecodeError:
                project_name = None
        if project_name is None:
            project_name = job_doc.get("project") or job_doc.get("project_name")
        # BELT-AND-SUSPENDERS strip: whatever the source, the CLI never sees a project
        # key. Its job schema is deliberately strict (unknown keys are rejected — a
        # stray key would fail the run on a device), and the name is worker-level
        # metadata, not a physics input. A current app already omits it from job.json,
        # so this only rewrites the file for an older client.
        if "project" in job_doc or "project_name" in job_doc:
            job_doc.pop("project", None)
            job_doc.pop("project_name", None)
            with open(job_path, "w") as f:
                json.dump(job_doc, f)

        cmd = [CFG.cli, "run", job_path, "--out", out_dir]
        if CFG.materials:
            cmd += ["--materials", CFG.materials]
        if CFG.rules:
            cmd += ["--rules", CFG.rules]

        job = Job(job_id, tmpdir, out_dir, cmd, project_name=project_name)
        SCHED.submit(job)
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
                    # Wait for new events OR the job to finish, but wake every
                    # HEARTBEAT_SECONDS so a long-but-live solve can send a
                    # keepalive instead of going silent.
                    if idx >= len(job.events) and not job.done:
                        job.cond.wait(timeout=HEARTBEAT_SECONDS)
                    if idx < len(job.events):
                        batch = job.events[idx:]
                        idx = len(job.events)
                    elif job.done:
                        return
                    else:
                        batch = None  # timed out with nothing new -> heartbeat
                if batch is None:
                    # No new event within the window: send a keepalive comment. The
                    # job is still running OR queued (we hold no terminal event), so
                    # this line tells the client "the worker is alive" without
                    # inventing progress the CLI did not emit. A PAUSED job also
                    # heartbeats — the iPad shows the stall via freshness dimming
                    # rather than a fake failure (handoff 121, requirement 7).
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                for ev in batch:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                self.wfile.flush()
                if batch[-1].get("type") in ("done", "error", "cancelled"):
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
        result = SCHED.cancel(job)
        self._json(200, {"job_id": job.id, "status": job.state, "cancel": result})

    def _move_front(self, job):
        moved = SCHED.move_to_front(job)
        self._json(200, {"job_id": job.id, "moved": moved,
                         "position": SCHED.position(job.id)})

    def _pause(self, job):
        if job.state != "running":
            return self._json(409, {"error": "only a running job can be paused",
                                    "state": job.state})
        if job.paused:
            return self._json(200, {"job_id": job.id, "paused": True})
        ok = _signal_child(job, signal.SIGSTOP)
        if ok:
            job.paused = True
        self._json(200 if ok else 409, {"job_id": job.id, "paused": job.paused})

    def _resume(self, job):
        if not job.paused:
            return self._json(200, {"job_id": job.id, "paused": False})
        ok = _signal_child(job, signal.SIGCONT)
        if ok:
            job.paused = False
        self._json(200 if ok else 409, {"job_id": job.id, "paused": job.paused})


def main():
    global CFG, SCHED
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
    # Handoff 121: solves are memory-bandwidth-bound (127 GB/s shared, handoff 113),
    # so a second concurrent job runs BOTH slower — queueing is faster. Default 1;
    # raise only on hardware with more memory channels.
    ap.add_argument("--max-concurrency", type=int,
                    default=int(os.environ.get("TOPOPT_MAX_CONCURRENCY", "1")),
                    help="how many solves run at once (default 1; solves are "
                         "memory-bandwidth-bound, so >1 is slower on most hardware)")
    ap.add_argument("--webhook-url", default=os.environ.get("TOPOPT_WEBHOOK_URL"),
                    help="POST a small JSON here on job completion (e.g. an ntfy.sh "
                         "topic URL for a free phone notification; see README)")
    args = ap.parse_args()

    os.makedirs(args.workdir, exist_ok=True)
    CFG = Config(args.cli, args.workdir, args.materials, args.rules,
                 args.host, args.port,
                 max_concurrency=args.max_concurrency, webhook_url=args.webhook_url)
    SCHED = Scheduler(max_concurrency=args.max_concurrency)

    # Fail fast if the CLI is not runnable — the whole point is to wrap it. The
    # fingerprint (the core build id) is parsed out here so the identity line below
    # can name it without a second probe.
    fingerprint = "unknown"
    try:
        v = subprocess.run([CFG.cli, "--version"], capture_output=True,
                           text=True, timeout=15)
        fingerprint = _kv(v.stdout.strip()).get("fingerprint") or "unknown"
    except (OSError, subprocess.SubprocessError) as e:
        print(f"WARNING: could not run '{CFG.cli} --version': {e}", file=sys.stderr)
        print("         set --cli or TOPOPT_CLI to the topopt-cli binary path.",
              file=sys.stderr)

    # Bind BEFORE announcing anything (handoff 124, requirement 3). A second worker
    # on the same port fails here with EADDRINUSE; turn the naked traceback into one
    # actionable line + a clean non-zero exit — the maintainer's tonight-bootloop
    # diagnosis, banked. Uses the real port so a non-default --port stays honest.
    try:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            print(f"port {args.port} in use — is another worker already running? "
                  f"(lsof -i :{args.port})", file=sys.stderr)
            sys.exit(1)
        raise

    # ONE identity line (handoff 124, requirement 4): worker version + the core
    # fingerprint it will serve + the workdir its per-job folders live under. The
    # supervisor's log can grep this to answer "which worker is this?" with no
    # archaeology.
    print(f"topopt-worker {WORKER_VERSION}  ·  core {fingerprint}  ·  "
          f"workdir {args.workdir}", flush=True)
    print(f"listening on http://{args.host}:{args.port}  (LAN only; no auth)  ·  "
          f"max-concurrency: {args.max_concurrency}"
          + (f"  ·  webhook: on" if args.webhook_url else ""), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")


if __name__ == "__main__":
    main()
