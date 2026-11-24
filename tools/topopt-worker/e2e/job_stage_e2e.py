"""362 11-23 (his notes: the worker window sat on "starting..." for a whole lattice-file job, and a refused
file reached the iPad as a generic failure): a job's GET /jobs row carries its command (`mode`), its latest
stage line from the CLI (`stage`, `stage_at`), and, on a failure, the engine's plain reason (`message`) and
`code` from the job's own report. Pure Python; no CLI, no HTTP.

Run: python3 -I tools/topopt-worker/e2e/job_stage_e2e.py
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import topopt_worker as w  # noqa: E402


def check(cond, what):
    if not cond:
        print("FAIL:", what)
        sys.exit(1)
    print("ok:", what)


tmp = tempfile.mkdtemp(prefix="job_stage_e2e_")
out = os.path.join(tmp, "out")
os.makedirs(out)

job = w.Job("j1", tmp, out, ["/x/topopt-cli", "lattice-file", "job.json", "--out", out], project_name="stand")
check(job.snapshot()["mode"] == "lattice-file", "mode is the CLI's command")
check(job.snapshot()["stage"] is None, "no stage before the CLI says one")

for line in ("lattice-file: opening the part", "lattice-file: laying the lattice", "lattice-file: making the file"):
    job.emit(w.parse_cli_line(line + "\n"))
snap = job.snapshot()
check(snap["stage"] == "making the file", "the latest stage line is the job's stage")
check(isinstance(snap["stage_at"], float), "the stage carries its time")

job.emit(w.parse_cli_line("model: something else\n"))
check(job.snapshot()["stage"] == "making the file", "a line of another kind leaves the stage")

why, code = w._report_reason(out)
check((why, code) == (None, None), "no report, no reason")
with open(os.path.join(out, "lattice_file.json"), "w") as f:
    json.dump({"ok": False, "code": "would_not_print", "why": "1 bridge is longer than a printer can span."}, f)
why, code = w._report_reason(out)
check(code == "would_not_print" and why.startswith("1 bridge"), "a refused report gives its reason and code")

job.emit({"type": "error", "returncode": 3, "message": why, "code": code})
snap = job.snapshot()
check(snap["state"] == "error", "the job ends in error")
check(snap["message"].startswith("1 bridge") and snap["code"] == "would_not_print", "the job record carries the reason")

opt = w.Job("j2", tmp, out, ["/x/topopt-cli", "run", "job.json"])
opt.emit(w.parse_cli_line("PROGRESS rung=1 rungs=4 iter=12\n"))
check(opt.snapshot()["mode"] == "run" and opt.snapshot()["rung"] == 1, "an optimizer job keeps its rungs")
print("PASS job_stage_e2e")
