#!/bin/sh
# The probes that need no optimiser: they read ONE design's coefficients back in
# through `--alpha` and ask a question about it.
#
# ★ THE DESIGN IS PR 326's RE-BASELINE AT ITERATION 60. It is the arm the brief's
# bar is written against, its coefficients are committed, and using it means
# S1(a)'s k-convergence and ARM 2's anisotropy price are measured on the SAME
# object the tables compare — not on a seed, and not on a design this task
# produced and could have tuned.
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

# PR 326's committed coefficients, unpacked once.
[ -f "$HERE/probe/RB1_alpha.f64" ] || {
  mkdir -p "$HERE/probe"
  gunzip -c "$REPO/evidence/2026-08-11-plsm-minimise-extra-surface/arms/RB1_volcount/alpha.f64.gz" \
      > "$HERE/probe/RB1_alpha.f64"
}

probe() {
  name=$1; shift
  [ -d "$HERE/probe/$name" ] && [ -n "$(ls -A "$HERE/probe/$name" 2>/dev/null)" ] && \
      { echo "$name present"; return 0; }
  mkdir -p "$HERE/probe/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/probe/$name" \
      --rung 0.68 --threads 3 $BASE --alpha "$HERE/probe/RB1_alpha" "$@" \
      > "$HERE/probe/$name.log" 2>&1
  echo "$name done $(date '+%H:%M:%S')"
}

# S1(a) — the fraction against k = 2, 4, 8.
probe kreport --frac 4 --frac-kreport
# ARM 2 — the cut cell's anisotropy, priced by the rank-one laminate.
probe aniso   --frac 4 --frac-aniso
echo PROBES_DONE
