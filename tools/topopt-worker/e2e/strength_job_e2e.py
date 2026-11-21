#!/usr/bin/env python3
"""strength_job_e2e.py — the worker's multipart "strength_job" field (Install 3, the strength check of a print file;
LatticeReview's shape of 2026-11-17), pure-Python HTTP-level, independent of Xcode. Starts the real worker wrapping
stub_cli.py in its own temporary folder on its own port and proves:

  1. a lattice_file job sent WITH a "strength_job" part has strength_job.json beside the job, its own `model` pointed at the
     saved model (whatever the client called it), the rest exactly as sent; and the job.json handed to the CLI says
     "strength_job": "strength_job.json";
  2. the same job WITHOUT the part has no strength_job.json and no "strength_job" key (no check: rule V2);
  3. a strength_job that is not JSON is refused 400 and leaves nothing behind;
  4. with both "demand" and "strength_job", both are saved and named.

Run: python3 strength_job_e2e.py
     TOPOPT_E2E_WORKER=/path/to/topopt_worker.py python3 strength_job_e2e.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import demand_field_e2e as base  # noqa: E402  (its harness: free_port, wait_health, submit, wait_done, read)

WORKER = os.environ.get("TOPOPT_E2E_WORKER") or os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")

STRENGTH = {"model": "part-on-the-ipad.step", "material": "PLA", "resolution": 64, "mode": "lattice_part",
            "loads": {"anchor_face_ids": [3]}, "safety_margin": 1.5,
            "output": {"report": "report.json", "mesh_format": "stl"}}
DEMAND = bytes(range(256)) + b"\r\n--x\r\n"

failures = 0


def check(ok, msg):
    global failures
    print("  [%s] %s" % ("PASS" if ok else "FAIL", msg))
    if not ok:
        failures += 1


def main():
    port = base.free_port()
    workdir = tempfile.mkdtemp(prefix="strength-e2e-")
    env = dict(os.environ)
    env["TOPOPT_WORKER_DIR"] = workdir
    proc = subprocess.Popen([sys.executable, WORKER, "--host", "127.0.0.1", "--port", str(port), "--cli", STUB,
                             "--workdir", workdir],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        if not base.wait_health(port):
            print("FAIL: worker did not come up")
            sys.exit(1)
        print("== worker %s up on 127.0.0.1:%d (stub cli) ==" % (WORKER, port))
        job = {"mode": "lattice_file", "model": "m.step", "output": "lattice.stl", "layout": {"all_lattice": True}}

        # -- (1) with the part --------------------------------------------------
        st, resp = base.submit(port, job, [("strength_job", json.dumps(STRENGTH).encode())])
        check(st == 202, "a lattice_file job with a strength_job part is accepted (202)")
        jid = resp.get("job_id", "")
        base.wait_done(port, jid)
        jdir = os.path.join(workdir, jid)
        saved = json.loads(base.read(os.path.join(jdir, "strength_job.json"), "r") or "{}")
        check(saved.get("model") == "m.step", "strength_job.json's model is the saved model, not the iPad's name")
        check({k: v for k, v in saved.items() if k != "model"} == {k: v for k, v in STRENGTH.items() if k != "model"},
              "and the rest of it exactly as sent")
        doc = json.loads(base.read(os.path.join(jdir, "job.json"), "r") or "{}")
        check(doc.get("strength_job") == "strength_job.json", "job.json names \"strength_job\": \"strength_job.json\"")

        # -- (2) without ----------------------------------------------------------
        st, resp = base.submit(port, job, [])
        nid = resp.get("job_id", "")
        base.wait_done(port, nid)
        ndir = os.path.join(workdir, nid)
        check(st == 202 and not os.path.exists(os.path.join(ndir, "strength_job.json")), "no part: no strength_job.json")
        ndoc = json.loads(base.read(os.path.join(ndir, "job.json"), "r") or "{}")
        check("strength_job" not in ndoc, "no part: no \"strength_job\" key (no check)")

        # -- (3) not JSON ---------------------------------------------------------
        before = set(os.listdir(workdir))
        st, resp = base.submit(port, job, [("strength_job", b"{not json")])
        check(st == 400 and "strength_job" in (resp.get("error") or ""), "a strength_job that is not JSON is refused 400")
        check(set(os.listdir(workdir)) <= before | {"jobs.json", "queue.json"}, "and leaves no job folder behind")

        # -- (4) with demand too --------------------------------------------------
        st, resp = base.submit(port, job, [("demand", DEMAND), ("strength_job", json.dumps(STRENGTH).encode())])
        bid = resp.get("job_id", "")
        base.wait_done(port, bid)
        bdir = os.path.join(workdir, bid)
        bdoc = json.loads(base.read(os.path.join(bdir, "job.json"), "r") or "{}")
        check(base.read(os.path.join(bdir, "demand.bin")) == DEMAND and bdoc.get("demand") == "demand.bin",
              "demand.bin saved and named")
        check(os.path.isfile(os.path.join(bdir, "strength_job.json")) and bdoc.get("strength_job") == "strength_job.json",
              "strength_job.json saved and named beside it")

        print("\n%s (%d failures)" % ("ALL PASS" if failures == 0 else "FAILURES", failures))
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
