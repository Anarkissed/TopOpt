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
# ★ AND A CAP THAT DID NOT WORK, LEFT IN THE RECORD RATHER THAN TIDIED AWAY.
# The first pass of this script capped `simp.max_iterations` at 40 so four arms
# would fit. IT DID NOTHING. `run_job.cpp:6481` applies `job.simp_max_iterations`
# only on the SELF-WEIGHT branch; this is a LOAD-CASE job, so the key is accepted
# by the schema, mapped onto nothing, and silently dropped. The arms ran the full
# 381-iteration ladder and the first one took nearly an hour.
#
# That is a defect in the shipped CLI, not just a mistake here: the load-case
# schema REFUSES `ladder` and `margin_stop` with a message explaining that the
# production ladder and margin apply, and then accepts `simp.max_iterations` and
# drops it. It should be honoured (it is a budget, not something the load case
# determines) or refused. It is reported in the handoff and NOT fixed here.
#
# ★ SO THESE ARMS ARE UNCAPPED AND FULL-FIDELITY, which is better evidence than
# what was planned — and THREE arms rather than four, because four did not fit:
#
#   base    what runs today
#   loose   the draft block, WHICH ALREADY SHIPS — the control that says whether
#           this task's change adds anything to what he already has
#   both    loose + the new warm start
#
# `warm` alone is dropped. PR 324 already measured it at 4% alone and the
# mechanism is understood; what is NOT known is whether the PAIR transfers to
# SIMP, and `base`/`loose`/`both` answer that.
#
# Cost on the machine of record (10 cores, 3 threads): ~55 / 35 / 20 min.
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
python3 - "$BAKE/job_simp.json" "$SCRATCH/s3jobs" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
base = json.load(open(src))
arms = {
    "base":  {},
    "loose": {"draft": {"quality": True}},
    "both":  {"draft": {"quality": True},
              "warm_start": {"coarse": False, "matfree": True}},
}
for name, extra in arms.items():
    j = dict(base)
    j.update(extra)
    json.dump(j, open(f"{dst}/simp_{name}.json", "w"), indent=1)
print("wrote", len(arms), "job documents, UNCAPPED (see the header)")
PY

for arm in base loose both; do
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
