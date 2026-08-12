#!/bin/sh
# ★ THE TREE THIS TASK RUNS ON, VERIFIED RATHER THAN ASSERTED.
#
# The brief's bar and its seed are PR 326's re-baseline, and R5 asks for ONE
# variable to change from it. PR 326 is OPEN and branched from PR 324's merge —
# BEFORE PR 325 shipped the production parametric optimiser into
# `core/include/topopt/plsm_*.hpp` — so its sandbox tree does not contain those
# files at all.
#
# Branching from PR 326 would have made `git diff main -- core/src core/include
# app/` show PR 325's whole production path as deleted, which is exactly what R6
# forbids reporting. So PR 326 was MERGED INTO main instead. Two conflicts, both
# mechanical (PR 325 turned two harness files into shims over core while PR 326
# added functions beside them); both resolved by keeping both sides.
#
# ★ A MERGE THAT SILENTLY CHANGED A NUMBER WOULD INVALIDATE EVERY COMPARISON IN
# THIS TASK, so it is checked the only way that means anything: three iterations
# of PR 326's own re-baseline configuration on THIS tree, diffed against PR
# 326's committed `iterations.csv`. Identical to all twelve printed digits or
# the merge is wrong.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
REF326="$REPO/evidence/2026-08-11-plsm-minimise-extra-surface/arms/RB1_volcount/iterations.csv"
cd "$REPO"

OUT="$HERE/merge_identity"
if [ ! -f "$OUT/iterations.csv" ]; then
  mkdir -p "$OUT"
  ./build/levelset_probe "$BAKE/M2_verticalStand.step" \
      core/src/materials/materials.json "$BAKE/s2_simp_baseline/design.bin" \
      "$OUT" --rung 0.68 --iters 3 --threads 3 \
      --seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --plsm-refit-every 5 --hj-steps 24 --volume-count \
      > "$HERE/merge_identity.log" 2>&1
fi

# ★ COLUMNS 1-9 ONLY, AND THE REASON IS STATED. Columns 10 onward are wall
# clocks, CG iteration counts and solver-path flags — they are properties of the
# MACHINE and of the posture, not of the design, and this host had another
# worktree's optimiser running throughout. 1-9 are compliance, the two volumes,
# the achieved fraction, the offset, the step, |v|max and lambda: the trajectory
# itself. If those agree to twelve digits the merge changed no arithmetic.
NEW=$(cut -d, -f1-9 "$OUT/iterations.csv")
OLD=$(head -4 "$REF326" | cut -d, -f1-9)
if [ "$NEW" = "$OLD" ]; then
  echo "MERGE IDENTITY PASS — three iterations identical to PR 326's re-baseline"
  echo "$NEW"
else
  echo "FAIL: the merged tree does not reproduce PR 326's re-baseline"
  echo "$OLD" > "$HERE/merge_identity.expected"
  echo "$NEW" > "$HERE/merge_identity.actual"
  diff "$HERE/merge_identity.expected" "$HERE/merge_identity.actual" || true
  exit 1
fi
