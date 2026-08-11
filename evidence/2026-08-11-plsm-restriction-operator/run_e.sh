#!/bin/sh
# ★ THE RE-ATTEMPT, PRIORITY-ORDERED.
#
# 1. FP_perim1  — the COMPARATOR. Without it "the filter loses to the penalty"
#                 is a cross-task guess at mismatched iterations, which is the
#                 error PR 326 §2 records. Runs first because it decides the
#                 task's headline.
# 2. FX         — the brief's S(b): the best filter TOGETHER with the penalty.
# 3. FC_*       — ★ CANDIDATE C RE-ATTEMPTED. The first sweep used a scaling I
#                 invented (tau = T*lambda*h) at T = 1, 4, 16 and destroyed
#                 three arms. Yamada (2010) says tau is "the ratio of the
#                 fictitious interface energy and the objective functional",
#                 applied to NORMALISED sensitivities, swept between 1e-5 and
#                 5e-4. `--diffusion` is now that ratio against the objective's
#                 own gradient, and the probe REFUSES anything >= 1.
#                 The mis-scaled arms are kept under `misscaled/` as evidence.
# 4. FB_robust  — the escalation. THREE state solves per iteration.
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

run FP_perim1     $BASE --perimeter 1
run FX_best_perim $BASE --filter-radius 1 --perimeter 1
# A decade apart, so the shape of the response is visible on two arms. Yamada's
# own range is 1e-5..5e-4 against HIS normalisation; this normalisation is a
# gradient-norm ratio and is not the same one, so the bracket is set wider and
# the measurement decides.
run FC_r03        $BASE --diffusion 0.03
run FC_r30        $BASE --diffusion 0.30
run FB_robust     $BASE --filter-radius 1 --robust-eta 0.15
echo RUN_E_DONE
