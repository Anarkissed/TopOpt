#!/usr/bin/env bash
# ★ S3 — THE POSITIVE CONTROL. A spherical cavity in a bar under uniform uniaxial
# tension, whose stress concentration is classical and FINITE:
#
#     K = (27 - 15 nu) / (2 (7 - 5 nu))  = 2.0714 at nu = 0.35
#                                          [Southwell & Gough 1926]
#
# Same ersatz, same arms, same `analyze_fixed_design`. If S1's fitted exponent is
# near zero, this is what makes that believable: an instrument that cannot return
# zero on a geometry with a finite peak has not measured convergence anywhere.
#
# The `--radius 0` rows are the control's OWN control: with no cavity the exact
# solution is a uniform uniaxial stress that trilinear hexes reproduce exactly, so
# the peak must be sigma0 = 1 MPa at every resolution.
#
#   ./evidence/2026-08-19-peak-stress-convergence/s3_cavity.sh [resolutions...]

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$ROOT/core/build/cavity_convergence_probe"
CSV="$HERE/s3_cavity.csv"
[ -x "$PROBE" ] || { echo "build it first"; exit 1; }

RES=( "$@" )
[ ${#RES[@]} -gt 0 ] || RES=( 24 32 48 64 80 96 )

run() {  # arm radius res
  local arm="$1" rad="$2" r="$3"
  local out="$HERE/raw/cavity_${arm}_r${rad}_res${r}.txt"
  [ -f "$out" ] && { echo "=== SKIP $(basename "$out")"; return; }
  echo "=== cavity ${arm} R/L=${rad} res ${r}"
  "$PROBE" "$r" "$CSV" --arm "$arm" --radius "$rad" > "$out" 2>&1
  echo "    exit=$?  $(grep -m1 'K = peak' "$out" || true)"
}

# the control's own control: no cavity, exact uniform stress
for r in "${RES[@]}"; do run smooth 0 "$r"; done
# the finite concentration, both arms
for arm in smooth staircase; do
  for r in "${RES[@]}"; do run "$arm" 0.16666666666666666 "$r"; done
done
echo "done -> $CSV"
