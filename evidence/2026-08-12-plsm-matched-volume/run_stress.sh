#!/bin/sh
# ★ THE STRESS SEED AT THE MATCHED VOLUME. At rung 0.68 it gave the lowest
# internal surface of any mechanism in three tasks (49,950, -33.8%) and lost
# 44.2% of the certified margin. §3 of the matched-volume handoff showed the
# margin STOPS DISCRIMINATING at rung 0.7973 — all four arms within 0.2% — so
# the constraint that killed it may not bind here. This is the re-test.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; cd "$REPO"
B="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"; ST="$HERE/STATUS"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }
BASE="--rung 0.7973 --iters 60 --threads 6 --snapshot-every 10 \
--plsm-export 1 --plsm-export 2 --plsm-mma --plsm-basis gaussian \
--plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24 --volume-count \
--plsm-refit-every 5 --eta 1 --no-compliance-stop"
run() {
  name=$1; shift
  [ -f "$HERE/arms/$name/summary.txt" ] && { say "SKIP $name"; return 0; }
  say "START $name"; mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$B/M2_verticalStand.step" core/src/materials/materials.json \
      "$B/s2_simp_baseline/design.bin" "$HERE/arms/$name" $BASE "$@" \
      > "$HERE/arms/$name.log" 2>&1
  rc=$?; its=$(grep -c '^it ' "$HERE/arms/$name.log" 2>/dev/null || echo 0)
  [ $rc -ne 0 ] && { say "★ FAIL $name exit=$rc after $its"; return 0; }
  [ -f "$HERE/arms/$name/summary.txt" ] || { say "★ FAIL $name no summary"; return 0; }
  grep -q FATAL "$HERE/arms/$name.log" && { say "★ FAIL $name FATAL"; return 0; }
  pv=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="printed_voxels") k=i; next} END{print $k}' \
        "$HERE/arms/$name/iterations.csv")
  say "OK $name $its iterations, printed_voxels=$pv (target ~88424)"
}
run V3_stress --seed stress
say "STRESS_DONE"
