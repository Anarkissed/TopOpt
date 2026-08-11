#!/bin/sh
# R4 — THE SENSITIVITY AGAINST A CENTRAL DIFFERENCE, on ONE design.
#
# ★ THE DESIGN IS PR 326's RE-BASELINE AT ITERATION 60, read back through
# `--alpha`, so every row below is the SAME design and the only thing that
# changes between them is which (density, gradient) pair is being differenced.
# Nothing is re-optimised and no arm's trajectory is involved.
#
# ★ 3 THREADS, STRICTLY SERIAL. He needs his machine.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
BASE="--seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --plsm-refit-every 5 --hj-steps 24 --volume-count"

fd() {
  name=$1; shift
  [ -f "$HERE/probe/fd_$name/frac_fd.csv" ] && { echo "$name present"; return 0; }
  mkdir -p "$HERE/probe/fd_$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/probe/fd_$name" \
      --rung 0.68 --threads 3 $BASE --alpha "$HERE/probe/RB1_alpha" \
      --frac-fd 3 "$@" > "$HERE/probe/fd_$name.log" 2>&1
  echo "fd_$name done $(date '+%H:%M:%S')"
}

# ── THE CONTROL FIRST. PR 326's own gradient — DH_eta(phi)*|grad phi| projected
# by Psi^T — against the H_eta density it belongs to. Without this row "the new
# gradient checks out" is a number with nothing to be better or worse than.
fd heaviside

# ── the exact fraction, with the sample-scatter gradient. THE ARM.
fd frac_k4      --frac 4

# ── the two ablations: psi_i factored out at the cell centre (what Psi^T does),
# and the consistently mollified value (which has no staircase to average over).
fd frac_centre  --frac 4 --frac-sens centre
fd frac_soft    --frac 4 --frac-soft
echo FD_DONE
