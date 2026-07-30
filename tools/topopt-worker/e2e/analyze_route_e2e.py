#!/usr/bin/env python3
"""analyze_route_e2e.py — the worker ANALYZE route (task lattice-page-core-hookup
stage 3), pure-Python HTTP-level, independent of Xcode. Starts the real worker
wrapping stub_cli.py and proves:

  1. a job.json with "mode": "analyze" is routed to `topopt-cli analyze` (the
     worker.log records the launch argv);
  2. the run produces NO variant events (job.variants == 0 — H3b at the wire)
     and its artifacts are the analysis receipts (analysis_report.json,
     analysis.json with the solid-part field label, fields.bin) with NO
     variant mesh;
  3. a "minimize_plastic" job on the SAME worker still routes to `run` and
     still produces variants — the routing widened nothing.

Run: python3 analyze_route_e2e.py
"""

import http.client
import json
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")

failures = 0


def check(ok, msg):
    global failures
    print("  [%s] %s" % ("PASS" if ok else "FAIL", msg))
    if not ok:
        failures += 1


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


def submit(port, mode):
    boundary = "----analyze-e2e"
    job = json.dumps({"model": "m.step", "material": "PLA", "resolution": 32,
                      "mode": mode, "loads": {"anchor_face_ids": [1]}})
    parts = [
        "--%s\r\nContent-Disposition: form-data; name=\"step\"; "
        "filename=\"m.step\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        "ISO-10303-21;\r\n" % boundary,
        "--%s\r\nContent-Disposition: form-data; name=\"job\"; "
        "filename=\"job.json\"\r\nContent-Type: application/json\r\n\r\n%s\r\n"
        % (boundary, job),
    ]
    body = ("".join(parts) + "--%s--\r\n" % boundary).encode()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("POST", "/jobs", body,
              {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    return json.loads(c.getresponse().read())["job_id"]


def wait_done(port, job_id, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        c.request("GET", "/jobs/%s" % job_id)
        row = json.loads(c.getresponse().read())
        if row.get("state") in ("done", "error", "cancelled"):
            return row
        time.sleep(0.2)
    return None


def get_file(port, job_id, name):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", "/jobs/%s/files/%s" % (job_id, name))
    r = c.getresponse()
    return r.status, r.read()


def main():
    port = free_port()
    workdir = os.path.join(HERE, ".analyze-work")
    env = dict(os.environ)
    env["TOPOPT_WORKER_DIR"] = workdir
    proc = subprocess.Popen([sys.executable, WORKER, "--host", "127.0.0.1",
                             "--port", str(port), "--cli", STUB,
                             "--workdir", workdir],
                            env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    try:
        if not wait_health(port):
            print("FAIL: worker did not come up")
            sys.exit(1)
        print("== worker up on 127.0.0.1:%d (stub cli) ==" % port)

        # -- (1) analyze-mode job routes to `topopt-cli analyze` ---------------
        aid = submit(port, "analyze")
        row = wait_done(port, aid)
        check(row is not None and row["state"] == "done",
              "analyze job reached done")
        check(row is not None and row.get("variants") == 0,
              "H3b: analyze job produced ZERO variants on the wire")
        log_path = os.path.join(workdir, aid, "worker.log")
        log = open(log_path).read() if os.path.isfile(log_path) else ""
        first = log.splitlines()[0] if log else ""
        check(" analyze " in first and " run " not in first,
              "worker.log records the `analyze` subcommand launch")
        status, prov = get_file(port, aid, "analysis.json")
        check(status == 200, "analysis.json served as an artifact")
        pd = json.loads(prov or b"{}")
        check(pd.get("analysis_solves") == 1,
              "H3b: receipt says ONE analysis solve")
        check(pd.get("field_scope") == "solid_part",
              "H3c: receipt labels the field SOLID-PART")
        check("INVALIDATES" in (pd.get("field_scope_note") or ""),
              "H3c: the optimization-invalidates note travels")
        status, _ = get_file(port, aid, "analysis_report.json")
        check(status == 200, "analysis_report.json served")
        status, _ = get_file(port, aid, "fields.bin")
        check(status == 200, "fields.bin served (overlays light up)")
        status, _ = get_file(port, aid, "variant_070.stl")
        check(status == 404, "H3b: no variant mesh exists to serve")

        # -- (2) minimize_plastic on the SAME worker still routes to `run` -----
        rid = submit(port, "minimize_plastic")
        row2 = wait_done(port, rid)
        check(row2 is not None and row2["state"] == "done",
              "run job reached done on the same worker")
        check(row2 is not None and (row2.get("variants") or 0) > 0,
              "run job still produces variants (routing widened nothing)")
        log2_path = os.path.join(workdir, rid, "worker.log")
        log2 = open(log2_path).read() if os.path.isfile(log2_path) else ""
        first2 = log2.splitlines()[0] if log2 else ""
        check(" run " in first2 and " analyze " not in first2,
              "worker.log records the `run` subcommand for minimize_plastic")

        print("\n%s (%d failures)" % ("ALL PASS" if failures == 0 else "FAILURES",
                                      failures))
        sys.exit(0 if failures == 0 else 1)
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
