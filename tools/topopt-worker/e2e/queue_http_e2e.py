#!/usr/bin/env python3
"""queue_http_e2e.py — HTTP-level proof of the handoff-121 human-facing worker,
independent of Xcode. Starts the real worker wrapping stub_cli.py and proves, over
the wire:

  1. GET /jobs GOLDEN — submit two jobs at max-concurrency 1; the first runs, the
     second QUEUES (position 1). The /jobs list matches a golden shape (volatile
     fields — ids, timestamps, live iter — normalized away).
  2. WEBHOOK — a worker launched with --webhook-url POSTs a small completion JSON
     (job, project, state, summary) to the configured URL when a job finishes.
  3. Queue reorder + queued-cancel over HTTP.

Run:  python3 queue_http_e2e.py         (exit 0 = pass)
"""

import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_health(port, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                return True
        except OSError:
            time.sleep(0.1)
    return False


def submit(port, project=None):
    boundary = "----e2e"
    doc = {"model": "m.step", "material": "PLA", "resolution": 32,
           "mode": "minimize_plastic", "loads": {"anchor_face_ids": [1]}}
    if project:
        doc["project"] = project
    job = json.dumps(doc)
    body = (
        "--%s\r\nContent-Disposition: form-data; name=\"step\"; "
        "filename=\"m.step\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        "ISO-10303-21;\r\n" % boundary
        + "--%s\r\nContent-Disposition: form-data; name=\"job\"; "
          "filename=\"job.json\"\r\nContent-Type: application/json\r\n\r\n%s\r\n"
          % (boundary, job)
        + "--%s--\r\n" % boundary
    ).encode()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("POST", "/jobs", body,
              {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    return json.loads(c.getresponse().read())["job_id"]


def get_json(port, path, method="GET"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request(method, path)
    r = c.getresponse()
    return r.status, json.loads(r.read())


def start_worker(port, mode, gap, extra_env=None, args=None):
    env = dict(os.environ)
    env["TOPOPT_CLI"] = STUB
    env["TOPOPT_STUB_MODE"] = mode
    env["TOPOPT_STUB_GAP"] = str(gap)
    env["TOPOPT_HEARTBEAT_SECONDS"] = "1"
    env["TOPOPT_WORKER_DIR"] = os.path.join(HERE, ".qe2e-work-%d" % port)
    if extra_env:
        env.update(extra_env)
    cmd = [sys.executable, WORKER, "--host", "127.0.0.1", "--port", str(port),
           "--cli", STUB]
    if args:
        cmd += args
    return subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)


# ---------------------------------------------------------------------------
# A tiny webhook receiver that captures the POSTed JSON bodies.

class _WebhookReceiver(BaseHTTPRequestHandler):
    received = []
    lock = threading.Lock()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        try:
            obj = json.loads(body)
        except ValueError:
            obj = {"_raw": body.decode("utf-8", "replace")}
        with _WebhookReceiver.lock:
            _WebhookReceiver.received.append(obj)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


def start_receiver(port):
    srv = ThreadingHTTPServer(("127.0.0.1", port), _WebhookReceiver)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# ---------------------------------------------------------------------------

FAILS = []


def check(cond, msg):
    print(("  OK  " if cond else " FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def normalize_jobs(doc, id_map):
    """Strip volatile fields so /jobs can be golden-compared."""
    out = {"jobs": [], "max_concurrency": doc["max_concurrency"],
           "running": doc["running"], "queued": doc["queued"]}
    for row in doc["jobs"]:
        r = dict(row)
        r["id"] = id_map.get(r["id"], r["id"])
        # Timestamps: keep only presence (a float) vs absence (null).
        for k in ("created_at", "started_at", "finished_at"):
            r[k] = "<ts>" if isinstance(r[k], (int, float)) else None
        # A running job's live iter/rung/variants is timing-dependent — keep presence.
        for k in ("rung", "rungs", "iter"):
            r[k] = "<n>" if isinstance(r[k], int) else None
        r["variants"] = "<n>" if isinstance(r.get("variants"), int) else None
        out["jobs"].append(r)
    return out


def test_jobs_golden_and_queue():
    port = free_port()
    proc = start_worker(port, mode="slow", gap=0.2)  # job A runs effectively forever
    try:
        if not wait_health(port):
            check(False, "worker came up"); return
        a = submit(port, project="Runner")
        # Wait until A is actually running with at least one progress tick.
        for _ in range(50):
            st, doc = get_json(port, "/jobs/%s" % a)
            if doc.get("state") == "running" and doc.get("iter") is not None:
                break
            time.sleep(0.1)
        b = submit(port, project="Waiter")
        time.sleep(0.3)

        st, doc = get_json(port, "/jobs")
        id_map = {a: "A", b: "B"}
        got = normalize_jobs(doc, id_map)
        golden = {
            "jobs": [
                {"id": "A", "project": "Runner", "state": "running", "paused": False,
                 "rung": "<n>", "rungs": "<n>", "iter": "<n>", "variants": "<n>",
                 "position": None,
                 "created_at": "<ts>", "started_at": "<ts>", "finished_at": None},
                {"id": "B", "project": "Waiter", "state": "queued", "paused": False,
                 "rung": None, "rungs": None, "iter": None, "variants": "<n>",
                 "position": 1,
                 "created_at": "<ts>", "started_at": None, "finished_at": None},
            ],
            "max_concurrency": 1, "running": 1, "queued": 1,
        }
        check(got == golden, "GET /jobs matches the golden shape")
        if got != golden:
            print("   GOT   :", json.dumps(got, indent=2))
            print("   GOLDEN:", json.dumps(golden, indent=2))

        # Reorder is a no-op with a single queued job, but the endpoint answers.
        st, mv = get_json(port, "/jobs/%s/front" % b, method="POST")
        check(st == 200 and mv["moved"] is True, "POST /jobs/{queued}/front moves it")

        # Cancel the queued job → dequeued (no process); the runner is untouched.
        st, cx = get_json(port, "/jobs/%s" % b, method="DELETE")
        check(cx.get("cancel") == "dequeued", "DELETE on a queued job dequeues it")
        st, doc = get_json(port, "/jobs/%s" % a)
        check(doc["state"] == "running", "the running job survives a queued cancel")
    finally:
        proc.terminate()


def test_webhook_fires_on_completion():
    _WebhookReceiver.received = []
    rport = free_port()
    srv = start_receiver(rport)
    port = free_port()
    hook = "http://127.0.0.1:%d/notify" % rport
    proc = start_worker(port, mode="normal", gap=0.1,
                        args=["--webhook-url", hook])
    try:
        if not wait_health(port):
            check(False, "worker (webhook) came up"); return
        submit(port, project="Bracket")
        # Wait for the completion webhook.
        deadline = time.time() + 15
        while time.time() < deadline:
            with _WebhookReceiver.lock:
                if _WebhookReceiver.received:
                    break
            time.sleep(0.1)
        with _WebhookReceiver.lock:
            got = list(_WebhookReceiver.received)
        check(len(got) >= 1, "the worker POSTed a completion webhook")
        if got:
            hook_doc = got[0]
            check(hook_doc.get("state") == "done", "webhook state == done")
            check(hook_doc.get("project") == "Bracket", "webhook carries the project name")
            check("job" in hook_doc and hook_doc["job"], "webhook carries the job id")
            check("variant" in (hook_doc.get("summary") or ""),
                  "webhook summary names the variant count (%r)" % hook_doc.get("summary"))
    finally:
        proc.terminate()
        srv.shutdown()


def test_pause_resume_freezes_progress():
    """SIGSTOP/SIGCONT (handoff 121, requirement 7): a paused running job stops
    advancing its iteration (compute really stops), then advances again on resume."""
    port = free_port()
    proc = start_worker(port, mode="slow", gap=0.2)  # steady progress ticks
    try:
        if not wait_health(port):
            check(False, "worker (pause) came up"); return
        a = submit(port, project="Pausable")
        for _ in range(50):
            st, doc = get_json(port, "/jobs/%s" % a)
            if doc.get("state") == "running" and doc.get("iter") is not None:
                break
            time.sleep(0.1)

        st, pd = get_json(port, "/jobs/%s/pause" % a, method="POST")
        check(st == 200 and pd.get("paused") is True, "POST /pause reports paused")
        _, doc = get_json(port, "/jobs/%s" % a)
        check(doc.get("paused") is True, "/jobs reflects the paused flag")
        iter_at_pause = doc.get("iter")
        time.sleep(1.2)  # well over several gaps — a live child would advance
        _, doc2 = get_json(port, "/jobs/%s" % a)
        check(doc2.get("iter") == iter_at_pause,
              "a paused solve does NOT advance (iter frozen at %s)" % iter_at_pause)

        st, rd = get_json(port, "/jobs/%s/resume" % a, method="POST")
        check(st == 200 and rd.get("paused") is False, "POST /resume clears paused")
        time.sleep(1.0)
        _, doc3 = get_json(port, "/jobs/%s" % a)
        check((doc3.get("iter") or 0) > (iter_at_pause or 0),
              "a resumed solve advances again (iter %s > %s)"
              % (doc3.get("iter"), iter_at_pause))
    finally:
        proc.terminate()


def test_name_roundtrip_and_progress():
    """Handoff 124, item 2 + item 1 evidence. A submitted project name survives the
    app→worker POST→parse→/jobs round-trip; a job with NO name is reported as a null
    project (the worker never fabricates one — the menu supplies the id fallback);
    and a running job exposes live integer rung/rungs/iter in /jobs (the telemetry
    the menu row renders)."""
    port = free_port()
    proc = start_worker(port, mode="slow", gap=0.2)  # runs long enough to observe
    try:
        if not wait_health(port):
            check(False, "worker (name round-trip) came up"); return

        named = submit(port, project="L-Bracket v3")
        # Wait until it is running with a real progress tick.
        doc = {}
        for _ in range(50):
            st, doc = get_json(port, "/jobs/%s" % named)
            if doc.get("state") == "running" and doc.get("iter") is not None:
                break
            time.sleep(0.1)
        check(doc.get("project") == "L-Bracket v3",
              "the project name survives POST→parse→/jobs (%r)" % doc.get("project"))
        check(isinstance(doc.get("iter"), int) and isinstance(doc.get("rungs"), int),
              "a running job reports live integer rung/rungs/iter (rung=%s rungs=%s iter=%s)"
              % (doc.get("rung"), doc.get("rungs"), doc.get("iter")))

        # A job submitted with NO project → the worker reports project == null and
        # does NOT invent a name. (The menu turns null into the job-id short form; it
        # must never show "Untitled".) It queues behind the runner at concurrency 1.
        anon = submit(port)  # no project
        time.sleep(0.3)
        st, adoc = get_json(port, "/jobs/%s" % anon)
        check(adoc.get("project") is None,
              "a no-name job reports project == null, not a fabricated string (%r)"
              % adoc.get("project"))
    finally:
        proc.terminate()


def test_bind_failure_is_courteous():
    """Handoff 124, item 3. A second worker on an in-use port prints one actionable
    line (naming the port + the lsof command) and exits non-zero — NOT a naked
    traceback."""
    port = free_port()
    first = start_worker(port, mode="normal", gap=0.1)
    try:
        if not wait_health(port):
            check(False, "first worker (bind) came up"); return
        # Second worker, same port — capture its output and exit code.
        env = dict(os.environ)
        env["TOPOPT_CLI"] = STUB
        second = subprocess.run(
            [sys.executable, WORKER, "--host", "127.0.0.1", "--port", str(port),
             "--cli", STUB, "--workdir", os.path.join(HERE, ".qe2e-bind-%d" % port)],
            env=env, capture_output=True, text=True, timeout=20)
        out = (second.stdout or "") + (second.stderr or "")
        check(second.returncode == 1,
              "the port-clash worker exits with code 1 (got %d)" % second.returncode)
        check("in use" in out and ("lsof -i :%d" % port) in out,
              "it prints the port-in-use + lsof hint (%r)" % out.strip().splitlines()[-1:])
        check("Traceback" not in out,
              "it does NOT print a raw Python traceback")
    finally:
        first.terminate()


def test_startup_identity_line():
    """Handoff 124, item 4. The worker prints ONE startup line naming its version,
    the core fingerprint it serves, and its workdir — so a supervisor log answers
    "which worker is this?" without archaeology."""
    port = free_port()
    workdir = os.path.join(HERE, ".qe2e-id-%d" % port)
    proc = start_worker(port, mode="normal", gap=0.1,
                        extra_env={"TOPOPT_STUB_FINGERPRINT": "cafef00d1234",
                                   "TOPOPT_WORKER_DIR": workdir})
    try:
        if not wait_health(port):
            check(False, "worker (identity) came up"); return
        # Read a few startup lines from the captured stdout.
        lines = []
        for _ in range(6):
            line = proc.stdout.readline()
            if not line:
                break
            lines.append(line)
            if line.startswith("topopt-worker "):
                break
        ident = next((l for l in lines if l.startswith("topopt-worker ")), "")
        check("cafef00d1234" in ident and workdir in ident and WORKER_VERSION_HINT in ident,
              "startup identity line names version+fingerprint+workdir (%r)" % ident.strip())
    finally:
        proc.terminate()


# The worker version string, mirrored here only to assert it appears in the identity
# line (the worker is the source of truth; this is a loose contains-check).
WORKER_VERSION_HINT = "1.1.0"


def main():
    print("== (1) GET /jobs golden + queue + reorder + queued-cancel ==")
    test_jobs_golden_and_queue()
    print("\n== (2) completion webhook ==")
    test_webhook_fires_on_completion()
    print("\n== (3) pause/resume freezes compute (SIGSTOP/SIGCONT) ==")
    test_pause_resume_freezes_progress()
    print("\n== (4) project-name round-trip + live progress in /jobs (124 item 1+2) ==")
    test_name_roundtrip_and_progress()
    print("\n== (5) port-in-use is courteous, not a traceback (124 item 3) ==")
    test_bind_failure_is_courteous()
    print("\n== (6) startup identity line (124 item 4) ==")
    test_startup_identity_line()
    print()
    if FAILS:
        print("FAILED: %d check(s)" % len(FAILS))
        for m in FAILS:
            print("   - " + m)
        sys.exit(1)
    print("OK: /jobs golden, queue, reorder, queued-cancel, webhook, name round-trip, "
          "live progress, port-in-use courtesy, and startup identity all verified.")


if __name__ == "__main__":
    main()
