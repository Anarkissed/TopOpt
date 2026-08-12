#!/bin/sh
# ★ STAGE B — the four mechanisms rejected on margin at rung 0.68, re-tested at
# BOTH rungs (reviewer R3). Light rung FIRST: Stage A showed the margin moves
# 16-19% there and 0.1% at the shipped rung, so the light rung is where a
# mechanism can actually be judged. "A mechanism that only passes where the
# margin cannot discriminate has not passed."
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; cd "$REPO"
B="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"; ST="$HERE/STATUS"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }
COMMON="--eta 1 --threads 6 --plsm-export 1 --plsm-export 2 --plsm-mma --plsm-basis gaussian \
--plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 \
--no-compliance-stop --iters 120 --snapshot-every 20 --certify-from 40 --certify-every 20"
run() {
  name=$1; rung=$2; shift 2
  [ -f "$HERE/arms/$name/summary.txt" ] && { say "SKIP $name"; return 0; }
  say "START $name (rung $rung)"; mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$B/M2_verticalStand.step" core/src/materials/materials.json \
      "$B/s2_simp_baseline/design.bin" "$HERE/arms/$name" --rung "$rung" $COMMON "$@" \
      > "$HERE/arms/$name.log" 2>&1
  rc=$?; its=$(grep -c '^it ' "$HERE/arms/$name.log" 2>/dev/null || echo 0)
  [ $rc -ne 0 ] && { say "★ FAIL $name exit=$rc after $its"; return 0; }
  [ -f "$HERE/arms/$name/summary.txt" ] || { say "★ FAIL $name no summary"; return 0; }
  grep -q FATAL "$HERE/arms/$name.log" && { say "★ FAIL $name FATAL"; return 0; }
  pv=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="printed_voxels") k=i; next} END{print $k}' "$HERE/arms/$name/iterations.csv")
  nb=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="void_components") k=i; next} {print $k}' "$HERE/arms/$name/iterations.csv" | sort -u | wc -l | tr -d ' ')
  [ "$nb" -le 1 ] && say "★ FAIL $name void_components CONSTANT — measuring nothing"
  say "OK $name $its it, printed=$pv, b0 distinct=$nb"
}
# ── light rung first: this is where the margin discriminates
run BL_r2      0.5283 --seed holes --seed-period 8 --filter-radius 2
run BL_r3      0.5283 --seed holes --seed-period 8 --filter-radius 3
run BL_robust  0.5283 --seed holes --seed-period 8 --robust 0.15
run BL_stress  0.5283 --seed stress
# ── then the shipped rung, at the SAME 120 iterations so the pair is matched
run BS_r2      0.7973 --seed holes --seed-period 8 --filter-radius 2
run BS_r3      0.7973 --seed holes --seed-period 8 --filter-radius 3
run BS_robust  0.7973 --seed holes --seed-period 8 --robust 0.15
run BS_stress  0.7973 --seed stress
say "STAGE_B_DONE"
