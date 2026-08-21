#!/usr/bin/env bash
# ★ S1 — THE CONVERGENCE MEASUREMENT, in REPLICATE mode.
#
# ONE analytic design — `variant_068_alpha` from worker job 4f8a5fc335a44253, the
# maintainer's own M2_verticalStand.step PLSM run — with the load case built ONCE
# at resolution 96 and the grid then subdivided 1x / 2x / 3x / 4x. The tags, the
# mask, the anchor pad, the load pad and the face protection are the SAME PHYSICAL
# SOLIDS at every rung; the level set is the SAME ANALYTIC SURFACE at every rung,
# re-evaluated. ONLY THE ELEMENT SIZE CHANGES. That is PR 320's own reference
# construction, and it is the only mode in which "does the peak converge" is a
# question with an answer.
#
# TWO ARMS, differing ONLY in how the ACTIVE cells read the same phi:
#   frac        the production exact volume fraction (the question)
#   stair_base  ★ THE NEGATIVE CONTROL — the staircase FROZEN at the base grid and
#               replicated down, which is exactly what PR 320 did to a stored
#               design.bin. It must reproduce q ~ 0.45.
#
# `stair_fine` (the staircase re-cut at each solve grid) is a THIRD arm the probe
# supports and this script no longer runs: it is not a control for anything —
# both its geometry and its element size move — and its top rung costs 13 minutes.
# Its rows from the earlier pass are in `raw/pre_stable_gate/`.
#
# ARM=... overrides the arm list; refine 4 is NOT in the default ladder — see the
# handoff's cost note.
#
# Sequential by design (R8): one process per solve, a wall clock per rung, and no
# solve inherits a Krylov recycle space.
#
#   ./evidence/2026-08-19-peak-stress-convergence/s1_replicate.sh [refine...]

set -u
JOB="${JOB:-$HOME/.topopt-worker/4f8a5fc335a44253}"
BASE_RES="${BASE_RES:-96}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$ROOT/core/build/smooth_convergence_probe"
STEM="$JOB/out/variant_068_alpha"
CSV="$HERE/s1_replicate.csv"

[ -x "$PROBE" ] || { echo "build it first"; exit 1; }
[ -f "$STEM.f64" ] || { echo "no alpha at $STEM.f64"; exit 1; }

REF=( "$@" )
[ ${#REF[@]} -gt 0 ] || REF=( 1 2 3 )

for r in "${REF[@]}"; do
  for arm in ${ARMS:-frac stair_base}; do
    out="$HERE/raw/rep_${arm}_r${r}.txt"
    [ -f "$out" ] && { echo "=== SKIP (already have) $(basename "$out")"; continue; }
    echo "=== replicate ${arm} refine ${r}x (effective $((BASE_RES*r))) -> $(basename "$out")"
    /usr/bin/time -l "$PROBE" "$JOB" "$STEM" "$BASE_RES" "$CSV" \
        --mode replicate --refine "$r" --arm "$arm" > "$out" 2>&1
    echo "    exit=$?  $(grep -m1 'peak von Mises' "$out" || true)  $(grep -m1 'analyze wall' "$out" || true)"
  done
done
echo "done -> $CSV"
