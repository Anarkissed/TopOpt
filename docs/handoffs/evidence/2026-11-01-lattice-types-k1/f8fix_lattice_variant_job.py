#!/usr/bin/env python3
# f8fix_lattice_variant_job.py RUN_JOB DESIGN_BIN VF OUT_JOB: one rung of a stand run, latticed alone.
# RUN_JOB is a stand job written by make_stand_jobs.py (run_struct_<type>.json); DESIGN_BIN that
# run's solved design.bin, copied beside OUT_JOB. The job is the run's own with mode
# "lattice_variant" and a variant block, which is the lattice-variant contract (job.cpp): the load
# case is re-used, not re-authored. Used for f8fix_stand_052.txt:
#   f8fix_lattice_variant_job.py run_struct_gyroid.json design_c.bin 0.52 lv052.json
#   topopt-cli lattice-variant lv052.json --out out052
import json
import os
import sys

run_job, design, vf, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
with open(run_job) as f:
    job = json.load(f)
job["mode"] = "lattice_variant"
job["variant"] = {"design": os.path.basename(design), "volume_fraction": vf}
with open(out, "w") as f:
    json.dump(job, f, indent=1)
