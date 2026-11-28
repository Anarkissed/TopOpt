#!/usr/bin/env bash
# The low-density strut-law rows of bcc, diamond and sc (step 3 of reproduce.sh): the 11-09 probe and recipe
# (selfcheck, bulk, boundary, fit), on the rows UNDER the 11-09 band floor only, one core each, side by side.
#   TOPOPT_DEHOMOG_RHOS        the rows: "lo" is the new band floor read from core (the tensor rows of step 1-2)
#   TOPOPT_DEHOMOG_MIN_VOX=6   bulk: the law row (the finest) has >= 6 voxels across the strut (PR 198)
#   TOPOPT_DEHOMOG_BND_MIN_VOX=4  boundary: start on the first ladder rung with >= 4 voxels across
#   TOPOPT_DEHOMOG_LADDER_TOP=64  boundary: the aliasing re-measure ladder carries on past vpc40 to vpc64
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-25-strut-laws-low-density
P=./core/build/lattice_dehomog_probe
run() {  # type rows
  local d="$EV/$1"
  mkdir -p "$d"
  for ph in selfcheck bulk boundary fit; do
    TOPOPT_DEHOMOG_TYPE=$1 TOPOPT_DEHOMOG_RHOS=$2 TOPOPT_DEHOMOG_MIN_VOX=6 TOPOPT_DEHOMOG_BND_MIN_VOX=4 \
      TOPOPT_DEHOMOG_LADDER_TOP=64 "$P" "$ph" "$d" > "$d/$ph.log" 2>&1
    echo "exit $?" >> "$d/$ph.log"
  done
}
run bcc     lo,0.05,0.07,0.10,0.157 &
run diamond lo,0.05,0.07,0.10,0.125 &
run sc      lo,0.025,0.035,0.05,0.065 &
wait
