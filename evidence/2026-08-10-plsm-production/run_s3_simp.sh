#!/bin/sh
# S3(b) — ★ THE SOLVER WIN ON SIMP, ALL FOUR RUNGS, ON THE PRODUCTION PATH.
#
# PR 324 measured 76% fewer solver steps and 59% less wall clock from LOOSENING
# the trajectory solve and WARM STARTING it, and the two are MULTIPLICATIVE: 4%
# and 44% alone, 76% together, because loosening removes the long tail that was
# swamping the warm start's head start. NOTHING IN THAT FINDING IS LEVEL-SET
# SPECIFIC — it is a statement about a design that moves a bounded amount per
# iteration, which is what an optimiser does. So it is measured HERE on the
# shipped SIMP ladder, on his own job document, at four rungs.
#
# ★ FOUR ARMS, AND THE POINT IS THE FOURTH.
#
#   base    what runs today: tight trajectory, cold solves
#   loose   the "draft" block (SimpOptions::cg_tolerance_loose), already shipped
#   warm    the matrix-free warm start alone (warm_start.matfree) — NEW
#   both    loose + warm
#
# Measuring either of the middle two alone badly undersells the pair; PR 324 did
# exactly that and nearly dropped the idea at 5%.
#
# ★ NO VERDICT MAY MOVE (R5). Every arm's report.json is compared rung by rung
# on accept/reject, and the margin deltas are reported against BOTH bars: PR 313's
# margin-reproduction tolerance of 1.0e-06 relative, and the machinery's own
# measured warm-vs-cold noise floor of 3e-10 to 3e-9. The certification solve is
# never warm-started and never loosened on ANY arm — analyze.cpp:269 passes
# `initial_guess = nullptr` unconditionally and minimize_plastic asserts the tight
# tolerance — so this is structural, and the comparison measures whether the
# TRAJECTORY landed somewhere else.
#
# ★ THREE THREADS, and the machine otherwise quiet. Every wall clock here is
# compared against another wall clock from this same script.
#
# ★ AND AN ITERATION CAP, STATED RATHER THAN HIDDEN. His ladder runs 27 / 127 /
# 140 / 153 iterations to convergence — 447 in all, about 2.5 hours per arm at
# three threads, and four arms of that do not fit. `simp_max_iterations` is
# therefore capped at $CAP (default 40) on EVERY arm, so all four are the same
# experiment and the comparison between them is exact. RUNG 0.68 IS UNAFFECTED:
# it converges in 27 iterations, below the cap, and it is the rung every bar in
# this task lives at. Rungs 0.52 / 0.38 / 0.26 are truncated, so their designs are
# not the shipped ones — what is measured there is the SOLVER, which is the
# question, on four fields that are identical across arms by construction.
# Set CAP=0 to run the full ladder.
#
# Cost on the machine of record (10 cores, 3 threads): ~50 / 35 / 45 / 25 min.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
cd "$REPO"

OUT="$HERE/s3_simp"
mkdir -p "$OUT" "$SCRATCH/s3jobs"
cp "$BAKE/M2_verticalStand.step" "$SCRATCH/s3jobs/"

# The four job documents, from HIS job document and differing ONLY in the block
# under test. Written by a script rather than by hand so no other key can drift
# between arms.
CAP="${CAP:-40}"
python3 - "$BAKE/job_simp.json" "$SCRATCH/s3jobs" "$CAP" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
base = json.load(open(src))
cap = int(sys.argv[3]) if len(sys.argv) > 3 else 0
arms = {
    "base":  {},
    "loose": {"draft": {"quality": True}},
    "warm":  {"warm_start": {"coarse": False, "matfree": True}},
    "both":  {"draft": {"quality": True},
              "warm_start": {"coarse": False, "matfree": True}},
}
for name, extra in arms.items():
    j = dict(base)
    if cap > 0:
        j["simp"] = {"max_iterations": cap}
    j.update(extra)
    json.dump(j, open(f"{dst}/simp_{name}.json", "w"), indent=1)
print("wrote", len(arms), "job documents, iteration cap", cap or "none")
PY

for arm in base loose warm both; do
  [ -d "$SCRATCH/s3_$arm" ] && rm -rf "$SCRATCH/s3_$arm"
  /usr/bin/time -p ./build/topopt-cli run "$SCRATCH/s3jobs/simp_$arm.json" \
      --out "$SCRATCH/s3_$arm" --materials core/src/materials/materials.json \
      --threads 3 > "$OUT/$arm.log" 2>&1
  cp "$SCRATCH/s3_$arm/report.json" "$OUT/$arm.report.json"
  cp "$SCRATCH/s3_$arm/iterations.csv" "$OUT/$arm.iterations.csv"
  cp "$SCRATCH/s3_$arm/run_info.json" "$OUT/$arm.run_info.json"
  echo "$arm done"
done

python3 "$HERE/s3_table.py" "$OUT" > "$OUT/verdict.txt"
cat "$OUT/verdict.txt"
