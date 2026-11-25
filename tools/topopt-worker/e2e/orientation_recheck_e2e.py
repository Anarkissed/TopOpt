#!/usr/bin/env python3
"""orientation_recheck_e2e.py — ★ notes27 (his print orientation, "Check strength"): the worker carries the orientation
keys to the CLI. Pure-Python HTTP level, the real worker over stub_cli.py. Proves:

  1. an analyze job with "orientation_recheck" and the multipart "recheck_mesh" saves the mesh beside the job under its
     bare name and names it in the job (orientation_recheck.mesh), its build_dir untouched;
  2. "recheck_mesh" without an analyze job's orientation_recheck is refused (400), and so is one named like the model;
  3. a lattice_file job's "print_frame" reaches the CLI's job.json untouched (the worker passes job keys through).

Run: python3 orientation_recheck_e2e.py
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



def submit(port, job, extra=()):
    boundary = "----orient-e2e"
    parts = [
        "--%s\r\nContent-Disposition: form-data; name=\"step\"; "
        "filename=\"m.step\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        "ISO-10303-21;\r\n" % boundary,
        "--%s\r\nContent-Disposition: form-data; name=\"job\"; "
        "filename=\"job.json\"\r\nContent-Type: application/json\r\n\r\n%s\r\n"
        % (boundary, json.dumps(job)),
    ]
    for name, filename, data in extra:
        parts.append("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                     "Content-Type: application/octet-stream\r\n\r\n%s\r\n" % (boundary, name, filename, data))
    body = ("".join(parts) + "--%s--\r\n" % boundary).encode()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("POST", "/jobs", body, {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
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


def get_file(port, job_id, name):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", "/jobs/%s/files/%s" % (job_id, name))
    r = c.getresponse()
    return r.status, r.read()



def main():
    port = free_port()
    workdir = os.path.join(HERE, ".orient-work")
    env = dict(os.environ)
    env["TOPOPT_WORKER_DIR"] = workdir
    proc = subprocess.Popen([sys.executable, WORKER, "--host", "127.0.0.1", "--port", str(port), "--cli", STUB,
                             "--workdir", workdir], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        if not wait_health(port):
            print("FAIL: worker did not come up")
            sys.exit(1)
        base = {"model": "m.step", "material": "PLA", "resolution": 32, "mode": "analyze",
                "loads": {"anchor_face_ids": [1]}}
        # (1) the re-check's mesh beside the job, named by it
        job = dict(base, orientation_recheck={"mesh": "whatever.stl", "build_dir": [0, 1, 0]})
        status, r = submit(port, job, [("recheck_mesh", "recheck.stl", "solid x\nendsolid x")])
        check(status < 300 and "job_id" in r, "analyze job with a re-check mesh accepted")
        jid = r.get("job_id", "")
        doc = json.load(open(os.path.join(workdir, jid, "job.json"))) if jid else {}
        check(doc.get("orientation_recheck", {}).get("mesh") == "recheck.stl", "the job names the saved mesh")
        check(doc.get("orientation_recheck", {}).get("build_dir") == [0, 1, 0], "its build_dir untouched")
        check(os.path.isfile(os.path.join(workdir, jid, "recheck.stl")), "the mesh is beside the job")
        wait_done(port, jid)
        # (2) refused without the block, or named like the model
        status, _ = submit(port, base, [("recheck_mesh", "recheck.stl", "x")])
        check(status == 400, "RED CONTROL: a re-check mesh without orientation_recheck is refused")
        status, _ = submit(port, job, [("recheck_mesh", "m.step", "x")])
        check(status == 400, "a re-check mesh named like the model is refused")
        # (3) print_frame passes through on a lattice_file job
        lj = {"mode": "lattice_file", "model": "m.step", "output": "lattice.stl", "layout": {},
              "print_frame": {"up": [0.7071067812, 0, 0.7071067812]}}
        status, r = submit(port, lj)
        check(status < 300 and "job_id" in r, "lattice_file job with print_frame accepted")
        jid = r.get("job_id", "")
        doc = json.load(open(os.path.join(workdir, jid, "job.json"))) if jid else {}
        check(doc.get("print_frame") == {"up": [0.7071067812, 0, 0.7071067812]}, "print_frame reaches the CLI's job.json")
        wait_done(port, jid)
        # (4) ★ notes28 (a): Check strength on an Organic result re-sends the job that made its file (kept with the result),
        # its print_frame set to the new up, with the stress it followed: the groups, the new frame and the stress reach the
        # CLI exactly as kept
        groups = [{"name": "Back wall", "organic_mode": "traced", "regions": [3]}, {"organic_mode": "grown", "regions": [4]}]
        kept = {"mode": "lattice_file", "model": "m.step", "output": "lattice.stl", "file_format": "3mf",
                "layout": {"organic_groups": groups}, "tensor": "tensor.bin", "print_frame": {"up": [0, 1, 0]}}
        status, r = submit(port, kept, [("tensor", "tensor.bin", "TOTENSOR-kept-with-the-result")])
        check(status < 300 and "job_id" in r, "the kept Organic job, standing the new way, accepted")
        jid = r.get("job_id", "")
        doc = json.load(open(os.path.join(workdir, jid, "job.json"))) if jid else {}
        check(doc.get("layout", {}).get("organic_groups") == groups, "its groups reach the CLI untouched")
        check(doc.get("print_frame") == {"up": [0, 1, 0]}, "its new print_frame reaches the CLI")
        tensor_path = os.path.join(workdir, jid, "tensor.bin")
        check(os.path.isfile(tensor_path) and open(tensor_path).read() == "TOTENSOR-kept-with-the-result",
              "the stress it followed beside it, byte for byte")
        wait_done(port, jid)
        print("\n%s (%d failures)" % ("ALL PASS" if failures == 0 else "FAILURES", failures))
        sys.exit(0 if failures == 0 else 1)
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
