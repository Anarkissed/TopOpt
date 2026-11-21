#!/usr/bin/env python3
"""crlf_body_bytes_e2e.py — an uploaded file keeps every one of its own bytes, even
when it begins or ends with CR / LF. Pure-Python HTTP-level, independent of Xcode.
Starts the real worker wrapping stub_cli.py in its own temporary folder on its own
port and, for bodies that

  * END in 0x0A,
  * END in 0x0D 0x0A,
  * END in 0x0D 0x0A 0x0D 0x0A,
  * BEGIN with 0x0D 0x0A 0x0D 0x0A,

proves the model part, the "design" part and the "demand" part each come out on
disk byte-identical to what was sent. The multipart parser may drop only the one
framing CRLF at each end of a part, never a byte of the file itself.

Run: python3 crlf_body_bytes_e2e.py
     TOPOPT_E2E_WORKER=/path/to/topopt_worker.py python3 crlf_body_bytes_e2e.py
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

CASES = [
    ("ends in LF", lambda b: b + b"\n"),
    ("ends in CRLF", lambda b: b + b"\r\n"),
    ("ends in CRLF CRLF", lambda b: b + b"\r\n\r\n"),
    ("begins with CRLF CRLF", lambda b: b"\r\n\r\n" + b),
]

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


def submit(port, doc, parts):
    """POST /jobs with the job part plus each (name, filename, bytes) in `parts`."""
    boundary = "----crlf-e2e-91c2"
    body = ("--%s\r\nContent-Disposition: form-data; name=\"job\"; "
            "filename=\"job.json\"\r\nContent-Type: application/json\r\n\r\n"
            % boundary).encode() + json.dumps(doc).encode() + b"\r\n"
    for name, filename, data in parts:
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; "
                 "filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                 % (boundary, name, filename)).encode() + data + b"\r\n"
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


def read(path):
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()


def main():
    port = free_port()
    workdir = tempfile.mkdtemp(prefix="crlf-e2e-")
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

        doc = {"model": "m.step", "material": "PLA", "resolution": 32,
               "mode": "minimize_plastic", "loads": {"anchor_face_ids": [1]}}
        for label, shape in CASES:
            print("-- body %s --" % label)
            model = shape(b"ISO-10303-21;\nHEADER;\nENDSEC;\nEND-ISO-10303-21;")
            design = shape(b"DESIGN" + bytes(range(256)))
            demand = shape(b"DEMAND" + bytes(reversed(range(256))))
            st, resp = submit(port, doc, [("step", "m.step", model),
                                          ("design", "design.bin", design),
                                          ("demand", "demand.bin", demand)])
            check(st == 202, "job accepted (202)")
            jid = resp.get("job_id", "")
            wait_done(port, jid)
            jdir = os.path.join(workdir, jid)
            check(read(os.path.join(jdir, "m.step")) == model,
                  "model m.step is byte-identical")
            check(read(os.path.join(jdir, "design.bin")) == design,
                  "design.bin is byte-identical")
            check(read(os.path.join(jdir, "demand.bin")) == demand,
                  "demand.bin is byte-identical")

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
