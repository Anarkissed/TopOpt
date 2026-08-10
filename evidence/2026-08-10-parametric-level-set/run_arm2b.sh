#!/bin/sh
# ARM 2, second wave — THE STEP-SIZE PARITY ARM, added after watching A1.
#
# ★ WHY. A1 descends about half as fast per iteration as the voxel arm it is
# being compared against, and the reason is not the representation: it is the
# STEP. `--hj-steps` survives in `--plsm` mode only as the step-size unit — the
# coefficient step is sized to move the interface by gamma * hj_steps * h, which
# is what one state solve buys a voxel arm. A1 ran at the DEFAULT 6 steps, so its
# interface moves 0.6 voxels per solve. PR 325's C=2 arm, the design in the §0
# table, ran `--gridap-auto max` = 24 steps and moved 2.4 voxels per solve.
#
# Comparing them was comparing a 4x smaller step, which would have been reported
# as "the parametric arm converges slowly" when it was only stepping shorter.
# A6 puts them on the same step and is the row that belongs beside the voxel arms.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

run() {
  name=$1; iters=$2; shift 2
  mkdir -p "$HERE/arm2/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arm2/$name" \
      --rung 0.68 --iters "$iters" --threads 3 --snapshot-every 5 \
      --plsm-export 1 --plsm-export 2 --plsm-export 3 "$@" \
      > "$HERE/arm2/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arm2/$name.log") iterations"
}

# A6 — step parity with PR 325's C=2 arm: 24 x 0.1 x h = 2.4 voxels per solve.
run A6_step24 30 --plsm-mma --plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24

# A7 — the MAX configuration at the same step. Everything there is reason to
# believe helps, and the step that lets it move.
run A7_max_step24 30 --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
    --plsm-support 2 --plsm-refit-every 5 --hj-steps 24

# ── A4b — THE EXTENSION ABLATION, RUN CORRECTLY THIS TIME ───────────────────
#
# ★ A4_hilb WAS A NO-OP AND THE RUN IS KEPT AS THE EVIDENCE OF IT. `--plsm-hilb`
# under `--plsm-mma` changed nothing: A4's compliance matched A1's to TWELVE
# DIGITS at every iteration. The reason is structural — MMA consumes the
# SENSITIVITIES, built from the un-extended field by the chain rule, while the
# Hilbertian extension produces a DESCENT DIRECTION, which is not a derivative.
# `levelset_probe` now REFUSES the combination rather than ignoring it.
#
# So the extension ablation belongs against STEEPEST DESCENT, where a velocity is
# a velocity: A4b against A3, same 20 iterations, same everything else.
run A4b_hilb_descent 20 --plsm --plsm-knots 2,2,2 --plsm-support 2 --plsm-hilb

echo ARM2B_DONE
