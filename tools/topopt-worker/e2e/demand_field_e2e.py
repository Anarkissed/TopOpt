#!/usr/bin/env python3
"""demand_field_e2e.py — the worker's multipart "demand" field (Install 2, density
by stress), pure-Python HTTP-level, independent of Xcode. Starts the real worker
wrapping stub_cli.py in its own temporary folder on its own port and proves:

  1. a job sent WITH a "demand" part has demand.bin beside the job holding exactly
     the bytes sent, and the job.json handed to the CLI says "demand": "demand.bin";
  2. the same job WITHOUT the part has no demand.bin and no "demand" key;
  3. a job with both "design" and "demand" saves and names both, and neither
     disturbs the other.

The worker does not judge the file: a job asking for stress grading without one is
refused by core (no_stress_result), passed through like any other core refusal.

Run: python3 demand_field_e2e.py
     TOPOPT_E2E_WORKER=/path/to/topopt_worker.py python3 demand_field_e2e.py
       (runs the same checks against another copy of the worker file)
"""

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.environ.get("TOPOPT_E2E_WORKER") or os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")

# Bytes that would be mangled by any text handling: NULs, CR/LF pairs, high bytes.
DEMAND = bytes(range(256)) + b"\r\n\r\n--not-a-boundary\r\n" + b"\x00" * 64
DESIGN = b"DESIGN" + bytes(reversed(range(256))) + b"\r\n"

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


def submit(port, doc, extra):
    """POST /jobs with step + job, plus each (name, bytes) in `extra`."""
    boundary = "----demand-e2e-7f3a"
    body = b""
    body += ("--%s\r\nContent-Disposition: form-data; name=\"step\"; "
             "filename=\"m.step\"\r\nContent-Type: application/octet-stream\r\n\r\n"
             % boundary).encode() + b"ISO-10303-21;\r\n"
    body += ("--%s\r\nContent-Disposition: form-data; name=\"job\"; "
             "filename=\"job.json\"\r\nContent-Type: application/json\r\n\r\n"
             % boundary).encode() + json.dumps(doc).encode() + b"\r\n"
    for name, data in extra:
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; "
                 "filename=\"%s.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                 % (boundary, name, name)).encode() + data + b"\r\n"
    body += ("--%s--\r\n" % boundary).encode()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("POST", "/jobs", body,
              {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    r = c.getresponse()
    return r.status, json.loads(r.read() or b"{}")


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


def read(path, mode="rb"):
    if not os.path.isfile(path):
        return None
    with open(path, mode) as f:
        return f.read()


def main():
    port = free_port()
    workdir = tempfile.mkdtemp(prefix="demand-e2e-")
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
        print("== worker %s up on 127.0.0.1:%d (stub cli) ==" % (WORKER, port))

        base = {"model": "m.step", "material": "PLA", "resolution": 32,
                "mode": "minimize_plastic", "loads": {"anchor_face_ids": [1]}}

        # -- (1) with a "demand" part ------------------------------------------
        st, resp = submit(port, base, [("demand", DEMAND)])
        check(st == 202, "job with a demand part accepted (202)")
        jid = resp.get("job_id", "")
        row = wait_done(port, jid)
        check(row is not None and row["state"] == "done", "job with demand reached done")
        jdir = os.path.join(workdir, jid)
        check(read(os.path.join(jdir, "demand.bin")) == DEMAND,
              "demand.bin beside the job holds exactly the bytes sent")
        doc = json.loads(read(os.path.join(jdir, "job.json"), "r") or "{}")
        check(doc.get("demand") == "demand.bin",
              "job.json handed to the CLI names \"demand\": \"demand.bin\"")
        recv = json.loads(read(os.path.join(jdir, "out", "received_job.json"), "r") or "{}")
        check(recv.get("demand") == "demand.bin",
              "the CLI itself received \"demand\": \"demand.bin\"")

        # -- (2) the same job without the part --------------------------------
        st, resp = submit(port, base, [])
        check(st == 202, "job without a demand part accepted (202)")
        nid = resp.get("job_id", "")
        row = wait_done(port, nid)
        check(row is not None and row["state"] == "done", "job without demand reached done")
        ndir = os.path.join(workdir, nid)
        check(not os.path.exists(os.path.join(ndir, "demand.bin")), "no demand.bin")
        ndoc = json.loads(read(os.path.join(ndir, "job.json"), "r") or "{}")
        check("demand" not in ndoc, "no \"demand\" key in job.json")
        check(ndoc == dict(base, model="m.step"),
              "job.json is exactly the job sent (nothing added)")

        # -- (3) both "design" and "demand" ------------------------------------
        vdoc = dict(base, mode="lattice_variant", variant={"index": 0})
        st, resp = submit(port, vdoc, [("design", DESIGN), ("demand", DEMAND)])
        check(st == 202, "job with design and demand accepted (202)")
        bid = resp.get("job_id", "")
        wait_done(port, bid)  # the stub has no lattice-variant; only the saved files matter
        bdir = os.path.join(workdir, bid)
        check(read(os.path.join(bdir, "design.bin")) == DESIGN,
              "design.bin holds exactly the design bytes")
        check(read(os.path.join(bdir, "demand.bin")) == DEMAND,
              "demand.bin holds exactly the demand bytes")
        bdoc = json.loads(read(os.path.join(bdir, "job.json"), "r") or "{}")
        check((bdoc.get("variant") or {}).get("design") == "design.bin",
              "job.json names variant.design = design.bin")
        check(bdoc.get("demand") == "demand.bin",
              "job.json names demand = demand.bin")

        print("\n%s (%d failures)" % ("ALL PASS" if failures == 0 else "FAILURES",
                                      failures))
        sys.exit(0 if failures == 0 else 1)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
