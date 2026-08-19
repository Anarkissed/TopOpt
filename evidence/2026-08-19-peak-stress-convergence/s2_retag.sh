#!/usr/bin/env bash
# S2 — RETAG MODE: `build_production_loadcase` run outright at each resolution.
#
# ★ THIS IS NOT A CONVERGENCE MEASUREMENT AND MUST NOT BE READ AS ONE. The anchor
# pad's depth is specified in VOXELS, so the certified object is a different
# physical solid at every resolution — 10.2 mm of pad at 64, 2.6 mm at 192. What
# it prices is real and different: what a RE-CERTIFICATION of this job at another
# resolution actually returns, which is the number a user would see. S1 is the
# reference; the two are never mixed.
#
#   ./evidence/2026-08-19-peak-stress-convergence/s2_retag.sh [resolutions...]

set -u
JOB="${JOB:-$HOME/.topopt-worker/4f8a5fc335a44253}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$ROOT/core/build/smooth_convergence_probe"
STEM="$JOB/out/variant_068_alpha"
CSV="$HERE/s2_retag.csv"

[ -x "$PROBE" ] || { echo "build it first"; exit 1; }

RES=( "$@" )
[ ${#RES[@]} -gt 0 ] || RES=( 64 80 96 112 128 144 160 192 )

for arm in frac stair_fine; do
  for r in "${RES[@]}"; do
    out="$HERE/raw/retag_${arm}_res${r}.txt"
    [ -f "$out" ] && { echo "=== SKIP (already have) $(basename "$out")"; continue; }
    echo "=== retag ${arm} res ${r} -> $(basename "$out")"
    /usr/bin/time -l "$PROBE" "$JOB" "$STEM" "$r" "$CSV" --mode retag --arm "$arm" \
        > "$out" 2>&1
    echo "    exit=$?  $(grep -m1 'peak von Mises' "$out" || true)  $(grep -m1 'analyze wall' "$out" || true)"
  done
done
echo "done -> $CSV"
