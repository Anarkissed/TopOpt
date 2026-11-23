#!/usr/bin/env python3
"""chain_e2e.py — 362 11-23 (his Organic run: the iPad switched apps between the strengthening and the print file, and
the Mac sat idle for 10 minutes): a strengthening asked with "then" = file makes its print file ITSELF on the Mac.
Pure-Python HTTP-level, the real worker wrapping stub_cli.py. Proves:

  1. run = organic-strengthen + then = file: the strengthening's record names `next` when it is done, and that next job
     is the SAME job through `lattice-file`, with the model and every file beside it (tensor.bin), its job.json naming
     "strengthened": "strengthened.json", and the last round's strengthened.json + the additions it names beside it;
  2. without "then" there is no next job (the iPad makes the file as before);
  3. "then" anything but file, or "then" without the strengthening, is refused 400 and leaves nothing behind.

Run: python3 chain_e2e.py
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import demand_field_e2e as base  # noqa: E402
import organic_cut2_e2e as cut2  # noqa: E402

WORKER = os.environ.get("TOPOPT_E2E_WORKER") or os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")
failures = 0


def check(ok, msg):
    global failures
    print("  [%s] %s" % ("PASS" if ok else "FAIL", msg))
    if not ok:
        failures += 1


def main():
    port = base.free_port()
    workdir = tempfile.mkdtemp(prefix="chain-e2e-")
    env = dict(os.environ)
    env["TOPOPT_WORKER_DIR"] = workdir
    proc = subprocess.Popen([sys.executable, WORKER, "--host", "127.0.0.1", "--port", str(port), "--cli", STUB,
                             "--workdir", workdir],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        if not base.wait_health(port):
            print("FAIL: worker did not come up")
            sys.exit(1)
        print("== worker up on 127.0.0.1:%d (stub cli) ==" % port)

        # -- (1) the chain -----------------------------------------------------------------------------------------
        st, resp = base.submit(port, cut2.JOB, [("tensor", cut2.TENSOR), ("run", b"organic-strengthen"), ("then", b"file")])
        check(st == 202, "run = organic-strengthen with then = file is accepted (202)")
        sid = resp.get("job_id", "")
        row = base.wait_done(port, sid)
        check(row is not None and row.get("state") == "done", "the strengthening runs to done")
        nid = (row or {}).get("next")
        check(isinstance(nid, str) and nid and nid != sid, "its record names the next job (the print file)")
        nrow = base.wait_done(port, nid) if nid else None
        check(nrow is not None and nrow.get("state") == "done", "the next job runs to done on its own")
        check(cut2.invocation(workdir, nid)[:1] == ["lattice-file"] if nid else False, "the next job is lattice-file")
        ndir = os.path.join(workdir, nid or "x")
        ndoc = json.loads(base.read(os.path.join(ndir, "job.json"), "r") or "{}")
        sdoc = json.loads(base.read(os.path.join(workdir, sid, "job.json"), "r") or "{}")
        check(ndoc.get("strengthened") == "strengthened.json", "its job.json names \"strengthened\": \"strengthened.json\"")
        check({k: v for k, v in ndoc.items() if k != "strengthened"} == sdoc, "and is otherwise the strengthening's own job")
        check(base.read(os.path.join(ndir, "tensor.bin")) == cut2.TENSOR, "the tensor beside it, as sent")
        check(json.loads(base.read(os.path.join(ndir, "strengthened.json"), "r") or "{}").get("additions") == "additions.bin",
              "the last round's strengthened.json beside it")
        check(base.read(os.path.join(ndir, "additions.bin")) == b"\x01\x02\x03", "and the additions it names")
        check(nrow is not None and nrow.get("project") == (row or {}).get("project"), "under the same project name")

        # -- (2) no then, no chain ---------------------------------------------------------------------------------
        st, resp = base.submit(port, cut2.JOB, [("tensor", cut2.TENSOR), ("run", b"organic-strengthen")])
        row = base.wait_done(port, resp.get("job_id", ""))
        check(row is not None and row.get("next") is None, "a strengthening without then makes no next job")

        # -- (3) refusals ------------------------------------------------------------------------------------------
        for what, parts in (("then = stl", [("run", b"organic-strengthen"), ("then", b"stl")]),
                            ("then without the strengthening", [("then", b"file")])):
            before = set(os.listdir(workdir))
            st, resp = base.submit(port, cut2.JOB, parts)
            check(st == 400 and "then" in (resp.get("error") or ""), "refused 400: %s" % what)
            check(set(os.listdir(workdir)) <= before | {"jobs.json", "queue.json"}, "and leaves no job folder behind")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    print("ALL PASS (0 failures)" if failures == 0 else "FAILURES: %d" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
