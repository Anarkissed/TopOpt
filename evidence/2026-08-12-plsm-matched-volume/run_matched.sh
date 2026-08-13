#!/bin/sh
# ★★ THE MATCHED-VOLUME ARM — the experiment ranked first in the last two
# handoffs, and the one without which none of their numbers can be quoted
# against what ships.
#
# Every arm in PR 324/325/326, plsm-restriction-operator and
# plsm-monotone-no-nucleation ran at `--rung 0.68` on the PROBE convention,
# which targets `rung x part_solid` over EVERY non-Empty voxel. The shipped
# ladder targets `volume_fraction x n_active` with the ~40,216 frozen-solid
# voxels OUTSIDE the budget. Same dial, two parts:
#
#     old method at "0.68"   88,424 printed voxels   440,551 mm3   543.7 g
#     these arms at "0.68"  ~75,415 printed voxels  ~372,000 mm3   463.7 g
#
# 80 grams apart. Interior surface scales with void, so every cross-method
# comparison in those handoffs mixed "is this method rougher" with "did I remove
# more metal".
#
# ★ 0.7973 IS NOT A GUESS. `docs/handoffs/2026-08-10-plsm-production.md` §3
# reports SIMP's own printed fraction, measured on this convention, as 0.7973 at
# rung 0.68. Dial that in and both parts hold the same metal.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"
B="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
ST="$HERE/STATUS"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }

BASE="--rung 0.7973 --iters 60 --threads 6 --snapshot-every 10 \
--plsm-export 1 --plsm-export 2 --plsm-mma --plsm-basis gaussian \
--plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24 --volume-count \
--plsm-refit-every 5 --eta 1 --no-compliance-stop"

run() {
  name=$1; shift
  [ -f "$HERE/arms/$name/summary.txt" ] && { say "SKIP $name"; return 0; }
  say "START $name"
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$B/M2_verticalStand.step" core/src/materials/materials.json \
      "$B/s2_simp_baseline/design.bin" "$HERE/arms/$name" $BASE "$@" \
      > "$HERE/arms/$name.log" 2>&1
  rc=$?
  its=$(grep -c '^it ' "$HERE/arms/$name.log" 2>/dev/null || echo 0)
  [ $rc -ne 0 ] && { say "★ FAIL $name exit=$rc after $its iterations"; return 0; }
  [ -f "$HERE/arms/$name/summary.txt" ] || { say "★ FAIL $name no summary.txt"; return 0; }
  grep -q FATAL "$HERE/arms/$name.log" && { say "★ FAIL $name FATAL"; return 0; }
  # ★ CONTENT CHECK, not just liveness — the lesson from the monotone control arm.
  pv=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="printed_voxels") k=i; next} END{print $k}' \
        "$HERE/arms/$name/iterations.csv")
  say "OK $name $its iterations, printed_voxels=$pv (target ~88424)"
}

# 1. the control at matched volume — is the +188% gap really +20% here?
run V0_none      --seed holes --seed-period 8
# 2. ★ THE QUESTION: does the perimeter penalty still buy anything at +20%?
run V1_perim1    --seed holes --seed-period 8 --perimeter 1
# 3. the gyroid seed, the other free win, so it does not need its own run later
run V2_gyr20     --seed gyroid --seed-period 20
say "QUEUE_DONE"
