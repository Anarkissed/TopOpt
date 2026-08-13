#!/bin/sh
# ★ CANDIDATES B AND C, AND THE COMBINATION THE BRIEF ASKS FOR.
#
# ★ 3 THREADS, STRICTLY SERIAL, RUNG 0.68 ONLY.
#
# `FA_BEST` is the filter radius Candidate A's sweep picked; it is an argument
# because it is chosen from a measurement, and the value the handoff's tables
# were produced with is the default below so re-running reproduces them.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
# ★ r = 1 VOXEL, AND CANDIDATE A's SWEEP IS WHERE THAT COMES FROM. The
# certified margin over the radius sweep reads 3394 (r=0) / 3290 (r=1) /
# 1984 (r=2) / 1837 (r=3): r=1 is the only radius that clears R4's bar of
# SIMP's 3254.3, and r=2 already costs 39% of the margin.
FA_BEST="${FA_BEST:-1}"

run() {
  name=$1; shift
  if [ -f "$HERE/arms/$name/summary.txt" ]; then echo "$name present"; return 0; fi
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arms/$name" \
      --rung 0.68 --iters 60 --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 \
      --certify-every 10 --certify-from 30 --no-compliance-stop "$@" \
      > "$HERE/arms/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arms/$name.log") iterations, $(date '+%H:%M:%S')"
}

BASE="--seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 --eta 1"

# ── ★ CANDIDATE C — the diffusion energy, swept. One Laplacian and one
# transpose apply per iteration: no extra solve of any kind, which makes it the
# cheapest of the three. Bracketed the way the perimeter weight was, since it
# carries the same lambda*h scaling and so lives on the same dimensionless axis.
# Ordered 4, 16, 1 so the range is bracketed after two arms.
run FC_t4 $BASE --diffusion 4
run FC_t16 $BASE --diffusion 16
run FC_t1 $BASE --diffusion 1

# ── ★ CANDIDATE B — the robust triple on the filtered field. THREE state solves
# per iteration; PR 324 measured 99.5% of an iteration as the state solve, so
# expect about 3x the wall clock. It is the escalation, run only because A is
# cheap enough to have run first.
# ── ★ THE COMBINATION. The brief's S(b): the best restriction operator TOGETHER
# with the perimeter penalty at PR 326's knee. If the filter makes the penalty
# unnecessary that is the headline; if they compound, that is also the headline.
run FX_best_perim $BASE --filter-radius "$FA_BEST" --perimeter 1

# ── ★ CANDIDATE B, LAST because it is the escalation and the most expensive:
# THREE state solves per iteration, and PR 324 measured 99.5% of an iteration as
# the state solve, so about 3x the wall clock.
run FB_robust $BASE --filter-radius "$FA_BEST" --robust-eta 0.15

echo RUN_BC_DONE
