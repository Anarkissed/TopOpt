#!/bin/sh
# ★ THE COMPARATOR THE TASK CANNOT BE ANSWERED WITHOUT.
#
# The brief's question is whether a RESTRICTION OPERATOR beats the GLOBAL SCALAR
# TAX that PR 326 found. Candidate A's sweep measures the filter against NO
# operator (`F0_none`) — but PR 326's perimeter arm ran at a different iteration
# count, in a different task, and was measured at iteration 60 where this task
# matches at 50. Comparing across those is exactly the mismatched-iteration
# error PR 326 §2 records.
#
# ★ SO THE PERIMETER PENALTY IS RE-RUN HERE, IN THIS TASK'S CONFIGURATION, AT
# THE SAME ITERATIONS, MEASURED IN THE SAME INVOCATION. Without it "the filter
# is worse than the penalty" would be a cross-task guess.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
run() {
  name=$1; shift
  if [ -f "$HERE/arms/$name/summary.txt" ]; then echo "$name present"; return 0; fi
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$BAKE/M2_verticalStand.step" core/src/materials/materials.json \
      "$BAKE/s2_simp_baseline/design.bin" "$HERE/arms/$name" \
      --rung 0.68 --iters 60 --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 \
      --certify-every 10 --certify-from 30 --no-compliance-stop "$@" \
      > "$HERE/arms/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arms/$name.log") iterations, $(date '+%H:%M:%S')"
}
BASE="--seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 --eta 1"
run FP_perim1 $BASE --perimeter 1
echo RUN_D_DONE
