#!/usr/bin/env python3
"""Rebuild the M2-stand jobs this round's evidence ran, from the jobs already committed in
evidence/2026-08-20-lattice-only-grading/jobs/ (structural_on.json, aes_bandB_on.json, and the
M2_verticalStand.step beside them). No job file is committed here: these are derived.

usage: make_stand_jobs.py <topology> <out_dir> [--fixed MM]
writes <out_dir>/{analyze,run}_{struct,aes}_<topology>.json and lv_<topology>.json
  analyze_*  mode "analyze", res 128, as committed except the topology (both keys)
  run_*      mode "minimize_plastic", res 64
  --fixed MM one cell size instead of the committed jobs' swept (Doubled) ladder, for a type
             whose Doubled verdict is a refusal (rhombic): grading.cell_mode "fixed", cell_mm MM
  lv_*       "lattice_variant" of run_struct's own design.bin (rung index 2, vf 0.38), with
             lattice.emit_welded_stl + emit_organic_spans so the run writes its spans
"""
import json
import os
import sys

topo, out = sys.argv[1], sys.argv[2]
fixed = float(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[3] == "--fixed" else 0.0
src = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "../../../../evidence/2026-08-20-lattice-only-grading/jobs")
for intent, name in (("struct", "structural_on.json"), ("aes", "aes_bandB_on.json")):
    j = json.load(open(os.path.join(src, name)))
    j["model"] = os.path.abspath(os.path.join(src, j["model"]))
    j["lattice"]["topology"] = topo
    j["grading"]["topology"] = topo
    if fixed > 0:
        for key in ("cell_min_mm", "cell_max_mm"):
            j["grading"].pop(key, None)
        j["grading"]["cell_mode"] = "fixed"
        j["grading"]["cell_mm"] = fixed
    json.dump(j, open(os.path.join(out, "analyze_%s_%s.json" % (intent, topo)), "w"), indent=1)
    j["mode"] = "minimize_plastic"
    j["resolution"] = 64
    json.dump(j, open(os.path.join(out, "run_%s_%s.json" % (intent, topo)), "w"), indent=1)
    if intent == "struct":
        j["mode"] = "lattice_variant"
        j["variant"] = {"design": "out_run_struct_%s/design.bin" % topo, "index": 2}
        j["lattice"]["emit_welded_stl"] = True
        j["lattice"]["emit_organic_spans"] = True
        json.dump(j, open(os.path.join(out, "lv_%s.json" % topo), "w"), indent=1)
