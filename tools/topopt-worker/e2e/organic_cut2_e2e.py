#!/usr/bin/env python3
"""organic_cut2_e2e.py — the worker's Organic cut 2 fields (organic-cut2-handover.md, f), pure-Python HTTP-level,
independent of Xcode. Starts the real worker wrapping stub_cli.py in its own temporary folder on its own port and proves:

  1. a "tensor" part is saved beside the job as tensor.bin, exactly as sent, and named by the job's "tensor";
  2. "run" = organic-strengthen sends the SAME lattice_file job through `organic-strengthen` (not `lattice-file`);
     anything else in "run", or "run" on another kind of job, is refused 400 and leaves nothing behind;
  3. the strengthening's round files are served (GET /jobs/{id}/files/r2/strengthened.json) and the result zip holds
     them at their own paths; a path out of the round folders is never served;
  4. "strengthened" + "strengthened_additions" are saved beside the job (the additions under the bare name the json
     gives) and named by the job's "strengthened"; a json naming a path, or naming a file not sent, is refused 400;
  5. a job with none of these is the job it was (no tensor, no strengthened, `lattice-file`).

Run: python3 organic_cut2_e2e.py
     TOPOPT_E2E_WORKER=/path/to/topopt_worker.py python3 organic_cut2_e2e.py
"""

import http.client
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import demand_field_e2e as base  # noqa: E402  (its harness: free_port, wait_health, submit, wait_done, read)

WORKER = os.environ.get("TOPOPT_E2E_WORKER") or os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")

TENSOR = b"TOTENSOR" + bytes(range(200)) + b"\r\n--x\r\n"
JOB = {"mode": "lattice_file", "model": "m.step", "output": "lattice.stl",
       "layout": {"all_lattice": False, "organic_mode": "grown"}}

failures = 0


def check(ok, msg):
    global failures
    print("  [%s] %s" % ("PASS" if ok else "FAIL", msg))
    if not ok:
        failures += 1


def get(port, path):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", path)
    r = c.getresponse()
    return r.status, r.read()


def invocation(workdir, jid):
    doc = json.loads(base.read(os.path.join(workdir, jid, "out", "invocation.json"), "r") or "{}")
    return doc.get("argv") or []


def main():
    port = base.free_port()
    workdir = tempfile.mkdtemp(prefix="cut2-e2e-")
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

        # -- (1) the tensor ---------------------------------------------------------------------------------------
        st, resp = base.submit(port, JOB, [("tensor", TENSOR)])
        check(st == 202, "a lattice_file job with a tensor part is accepted (202)")
        jid = resp.get("job_id", "")
        base.wait_done(port, jid)
        jdir = os.path.join(workdir, jid)
        check(base.read(os.path.join(jdir, "tensor.bin")) == TENSOR, "tensor.bin saved beside the job, exactly as sent")
        doc = json.loads(base.read(os.path.join(jdir, "job.json"), "r") or "{}")
        check(doc.get("tensor") == "tensor.bin", "job.json names \"tensor\": \"tensor.bin\"")
        check(invocation(workdir, jid)[:1] == ["lattice-file"], "no run field: the lattice file (lattice-file)")

        # -- (2) the strengthening --------------------------------------------------------------------------------
        st, resp = base.submit(port, JOB, [("tensor", TENSOR), ("run", b"organic-strengthen")])
        check(st == 202, "run = organic-strengthen is accepted (202)")
        sid = resp.get("job_id", "")
        row = base.wait_done(port, sid)
        check(row is not None and row.get("state") == "done", "and runs to done")
        argv = invocation(workdir, sid)
        check(argv[:1] == ["organic-strengthen"] and argv[1].endswith("job.json") and "--out" in argv,
              "the SAME job through organic-strengthen <job.json> --out DIR")
        sdoc = json.loads(base.read(os.path.join(workdir, sid, "job.json"), "r") or "{}")
        check(sdoc.get("mode") == "lattice_file" and "run" not in sdoc, "the job is still a lattice_file job, no run key")
        for bad, jobdoc in ((b"rm -rf", JOB), (b"organic-strengthen", dict(JOB, mode="lattice_part"))):
            before = set(os.listdir(workdir))
            st, resp = base.submit(port, jobdoc, [("run", bad)])
            check(st == 400 and "run" in (resp.get("error") or ""), "refused 400: run=%r on %s" % (bad, jobdoc["mode"]))
            check(set(os.listdir(workdir)) <= before | {"jobs.json", "queue.json"}, "and leaves no job folder behind")

        # -- (3) the round files ----------------------------------------------------------------------------------
        st, body = get(port, "/jobs/%s/files/r2/strengthened.json" % sid)
        check(st == 200 and json.loads(body).get("additions") == "additions.bin", "a round's file is served (r2/...)")
        st, body = get(port, "/jobs/%s/files/strengthen.json" % sid)
        check(st == 200 and json.loads(body).get("strengthened") == "r2/strengthened.json", "the summary is served")
        st, _ = get(port, "/jobs/%s/files/..%%2F..%%2Fjob.json" % sid)
        check(st == 404, "a path out of the job's output is never served")
        st, _ = get(port, "/jobs/%s/files/x9/strength.json" % sid)
        check(st == 404, "only round folders (rN) are served")
        st, body = get(port, "/jobs/%s/result" % sid)
        names = set(zipfile.ZipFile(io.BytesIO(body)).namelist()) if st == 200 else set()
        check({"strengthen.json", "r1/strength.json", "r2/strength.json", "r2/strengthened.json", "r2/additions.bin"}
              <= names, "the result zip holds every round's files at their own paths")

        # -- (4) a strengthened lattice to make ------------------------------------------------------------------
        sj = json.dumps({"version": 2, "additions": "additions.bin"}).encode()
        st, resp = base.submit(port, JOB, [("tensor", TENSOR), ("strengthened", sj),
                                           ("strengthened_additions", b"\x01\x02\x03")])
        check(st == 202, "a strengthened lattice is accepted (202)")
        eid = resp.get("job_id", "")
        base.wait_done(port, eid)
        edir = os.path.join(workdir, eid)
        edoc = json.loads(base.read(os.path.join(edir, "job.json"), "r") or "{}")
        check(edoc.get("strengthened") == "strengthened.json", "job.json names \"strengthened\": \"strengthened.json\"")
        check(base.read(os.path.join(edir, "strengthened.json")) == sj, "strengthened.json saved as sent")
        check(base.read(os.path.join(edir, "additions.bin")) == b"\x01\x02\x03", "its additions under the name it gives")
        for bad, parts in (("a path", [("strengthened", json.dumps({"version": 2, "additions": "../x.bin"}).encode()),
                                       ("strengthened_additions", b"\x00")]),
                           ("no additions sent", [("strengthened", sj)]),
                           ("not JSON", [("strengthened", b"{"), ("strengthened_additions", b"\x00")])):
            before = set(os.listdir(workdir))
            st, resp = base.submit(port, JOB, parts)
            check(st == 400 and "strengthened" in (resp.get("error") or ""), "refused 400: %s" % bad)
            check(set(os.listdir(workdir)) <= before | {"jobs.json", "queue.json"}, "and leaves no job folder behind")

        # -- (5) none of these -------------------------------------------------------------------------------------
        st, resp = base.submit(port, JOB, [])
        nid = resp.get("job_id", "")
        base.wait_done(port, nid)
        ndoc = json.loads(base.read(os.path.join(workdir, nid, "job.json"), "r") or "{}")
        check(st == 202 and "tensor" not in ndoc and "strengthened" not in ndoc, "RED CONTROL: no parts, no keys")
        check(not os.path.exists(os.path.join(workdir, nid, "tensor.bin")), "and no tensor.bin")

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
