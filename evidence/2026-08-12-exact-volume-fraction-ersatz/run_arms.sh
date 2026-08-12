#!/bin/sh
# THE TWO ARMS. ★ ONE VARIABLE CHANGES BETWEEN THEM (R5).
#
# Both are PR 326's re-baseline configuration verbatim — `--seed holes` with no
# SIMP anywhere, the gaussian basis at 85,680 coefficients, MMA, S1's
# `--volume-count`, `--plsm-refit-every 5`, 24 HJ steps, ★ NO PERIMETER PENALTY —
# and they differ in exactly one flag:
#
#   H1_heaviside   rho_e = H_eta(-phi(cell centre)), eta = 2 voxels.  PR 326's.
#   F1_frac4       rho_e = |{phi<0} cap cell| / |cell|, 4x4x4 sub-samples,
#                  with the matching surface-integral sensitivity.
#
# ★ AND ONE THING CHANGES FROM PR 326 IN *BOTH* ARMS, NAMED HERE RATHER THAN
# BURIED: 120 iterations instead of 60. PR 326 §2 measured every unsettled arm's
# margin still CLIMBING at 60 — the re-baseline by 26.7% between iterations 40
# and 60 while its compliance moved 0.05% — and §9 ranks "run them longer than
# 60" as the top item. The brief asks for MARGIN convergence, not compliance
# convergence, and 60 is known not to reach it. It is applied to both arms, so
# it is not a variable between them.
#
# ★ 3 THREADS, STRICTLY SERIAL. He needs his machine.
# ★ RUNG 0.68 ONLY.
#
# Snapshots every 10 iterations; NOTHING is certified inside the loop. PR 326
# measured that certifying an unconverged design costs 26x what certifying a
# converged one costs, and an in-loop certificate would also put the instrument
# inside the timing the handoff quotes. `certify.sh` reads the snapshots
# afterwards, in one process, so the STEP import is paid once.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

ITERS=${ITERS:-120}

BASE="--seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --plsm-refit-every 5 --hj-steps 24 --volume-count"

run() {
  name=$1; shift
  if [ -f "$HERE/arms/$name/summary.txt" ]; then
    echo "$name already present, skipping"
    return 0
  fi
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arms/$name" \
      --rung 0.68 --iters "$ITERS" --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 $BASE "$@" \
      > "$HERE/arms/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arms/$name.log") iterations, $(date '+%H:%M:%S')"
}

# ── the control: PR 326's re-baseline, run to 120.
run H1_heaviside

# ── ★ THE ARM. One flag. `--frac-export` additionally emits the same design as a
# volume-fraction field beside the H_eta one, so what the EXPORT convention is
# worth can be separated from what the DENSITY change is worth. The row of
# record is still the H_eta export (R5).
run F1_frac4 --frac 4 --frac-export

# ── ★★ ARM 2 — ALL MECHANISMS AT ONCE, as the brief requires. Two flags:
#
#   --frac-soft     M1. The hard sample indicator becomes the exact
#                   ANTIDERIVATIVE of the quadrature mollifier, so the value and
#                   the gradient are two facts about ONE function. Answers P2 and
#                   P13 — the 1/64 staircase that makes the compliance
#                   sensitivity unverifiable at any affordable step. ★ AND IT IS
#                   NOT A GUESS: Fu, Rolfe, Chiu, Wang, Huang & Ghabraie
#                   (SEMDOT, Advances in Engineering Software 150:102921, 2020)
#                   ran exactly this pair on an architecture that is ours — a
#                   sub-sampled element volume fraction times a reference
#                   stiffness — and measured the step function fluctuating for
#                   its first 20 iterations, converging to a WORSE compliance in
#                   MORE iterations, and producing an asymmetric topology with
#                   "several tiny holes and one thin bar".
#
#   --frac-eps-l1   M5. The quadrature bandwidth on |grad phi|_1 rather than
#                   |grad phi|_2, which is what Engquist, Tornberg & Tsai (JCP
#                   207(1):28-51, 2005) prove is required for a mollified
#                   surface delta to converge at all in 3D. P14 — a defect in
#                   what ARM 1 built, found by the literature and not by me.
#
# ★ ATTRIBUTION COMES FROM R4, NOT FROM MORE ARMS. Each flag is
# finite-differenced ALONE against the same design in `run_fd.sh`, so the
# combination can be run once — at an hour of state solves — without the result
# being uninterpretable.
run A2_all --frac 4 --frac-soft --frac-eps-l1 --frac-export

echo ARMS_DONE
