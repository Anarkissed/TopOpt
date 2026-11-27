#!/usr/bin/env python3
"""lattice_part_route_e2e.py — the worker routes a "lattice_part" job (the Lattice button: lattice the
imported part, no optimization) to `topopt-cli lattice-variant`, the entry point core gives both
lattice modes (core/src/cli/main.cpp). His job of 2026-11-16 (7f99b667) went to `run` and was refused
"unsupported mode: lattice_part" because the worker's table had no row for it.

Starts the real worker wrapping stub_cli.py and proves:
  1. a "lattice_part" job is launched as `lattice-variant` (worker.log's launch line), never `run`;
  2. a "minimize_plastic" job on the same worker still launches `run` (nothing else moved).

RED CONTROL: `--worker <path>` runs the same checks against another worker script; given the script
installed before this fix it must FAIL check 1.

Run: python3 lattice_part_route_e2e.py [--worker path/to/topopt_worker.py]
"""

import http.client
import json
import os
import shutil
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
    boundary = "----lattice-part-e2e"
    job = json.dumps({"model": "m.step", "material": "PLA", "resolution": 32,
                      "mode": mode, "loads": {"anchor_face_ids": [1]},
                      "lattice": {"topology": "octet"}})
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


def launch_line(workdir, job_id):
    p = os.path.join(workdir, job_id, "worker.log")
    if not os.path.isfile(p):
        return ""
    for line in open(p, errors="replace"):
        if " launch " in line:
            return line
    return ""


def main():
    worker = WORKER
    if "--worker" in sys.argv:
        worker = os.path.abspath(sys.argv[sys.argv.index("--worker") + 1])
    port = free_port()
    workdir = os.path.join(HERE, ".lattice-part-work")
    shutil.rmtree(workdir, ignore_errors=True)
    env = dict(os.environ)
    env["TOPOPT_WORKER_DIR"] = workdir
    proc = subprocess.Popen([sys.executable, worker, "--host", "127.0.0.1",
                             "--port", str(port), "--cli", STUB,
                             "--workdir", workdir],
                            env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    try:
        if not wait_health(port):
            print("FAIL: worker did not come up")
            sys.exit(1)
        print("== worker %s up on 127.0.0.1:%d (stub cli) ==" % (worker, port))

        lid = submit(port, "lattice_part")
        wait_done(port, lid)
        first = launch_line(workdir, lid)
        check(" lattice-variant " in first and " run " not in first,
              "a lattice_part job launches `lattice-variant`, not `run` (got: %s)" % first.strip()[-160:])

        rid = submit(port, "minimize_plastic")
        wait_done(port, rid)
        first2 = launch_line(workdir, rid)
        check(" run " in first2 and " lattice-variant " not in first2,
              "a minimize_plastic job still launches `run`")

        print("\n%s (%d failures)" % ("ALL PASS" if failures == 0 else "FAILURES", failures))
        sys.exit(0 if failures == 0 else 1)
    finally:
        proc.terminate()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
