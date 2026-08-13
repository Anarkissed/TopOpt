#!/bin/sh
# ★ STAGE A — the two amendments that gate the recommendation.
#
# AMENDMENT 1 — eta and C are NOT independent knobs. The perimeter functional
# integrates DH_eta(phi)*|grad phi|, so eta is INSIDE the thing C weights and a C
# measured at one eta does not transfer. Reviewer preferred option (a): run the
# matched pair at the SHIPPED volume. V1_perim1 (C=1, eta=1, rung 0.7973) already
# exists, so only its eta=2 partner is new.
#
# AMENDMENT 2 — ★ THE SAFETY CASE. At rung 0.7973 the margin spread across ten
# arms is 1.1%, so "margin unchanged at C=1" says nothing about safety; it says
# nothing moves the margin there. At rung 0.68 the SAME mechanism at C=8
# collapsed the margin to 1282. The ladder runs to 0.26.
#
# ★ THE LIGHT RUNG IS 0.5283, NOT 0.26. Same convention correction as everything
# else: production's run of record reports SIMP's PRINTED fraction at rung 0.26
# as 0.5283, so 0.5283 on the probe path is the rung that puts this arm on SIMP's
# own printed-voxel count there. SIMP's margin at that rung is 3014.12.
#
# 120 iterations, not 60: PR 327 measured a margin PEAKING at iteration 80 and
# falling 19.4% by 120, and Proposal 1 §4.2 left the surface-minimum (~31) vs
# margin-plateau trade unpriced. Both need iterations past 80 to be visible.
# Certify every 20 from 40 so the CURVE and its settling iteration are reported
# rather than a point (R2).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; cd "$REPO"
B="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"; ST="$HERE/STATUS"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }
COMMON="--eta 1 --threads 6 --plsm-export 1 --plsm-export 2 --plsm-mma --plsm-basis gaussian \
--plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 \
--no-compliance-stop --seed holes --seed-period 8"
run() {
  name=$1; rung=$2; iters=$3; snap=$4; cfrom=$5; cevery=$6; shift 6
  [ -f "$HERE/arms/$name/summary.txt" ] && { say "SKIP $name"; return 0; }
  say "START $name (rung $rung, $iters it)"; mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$B/M2_verticalStand.step" core/src/materials/materials.json \
      "$B/s2_simp_baseline/design.bin" "$HERE/arms/$name" \
      --rung "$rung" --iters "$iters" --snapshot-every "$snap" \
      --certify-from "$cfrom" --certify-every "$cevery" $COMMON "$@" \
      > "$HERE/arms/$name.log" 2>&1
  rc=$?; its=$(grep -c '^it ' "$HERE/arms/$name.log" 2>/dev/null || echo 0)
  [ $rc -ne 0 ] && { say "★ FAIL $name exit=$rc after $its"; return 0; }
  [ -f "$HERE/arms/$name/summary.txt" ] || { say "★ FAIL $name no summary"; return 0; }
  grep -q FATAL "$HERE/arms/$name.log" && { say "★ FAIL $name FATAL"; return 0; }
  pv=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="printed_voxels") k=i; next} END{print $k}' \
        "$HERE/arms/$name/iterations.csv")
  nb=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="void_components") k=i; next} {print $k}' \
        "$HERE/arms/$name/iterations.csv" | sort -u | wc -l | tr -d ' ')
  [ "$nb" -le 1 ] && say "★ FAIL $name void_components CONSTANT — measuring nothing"
  say "OK $name $its it, printed=$pv, b0 distinct=$nb"
}
# ── Amendment 2 first: it is the one that gates the default.
run L0_none    0.5283 120 20 40 20
run L1_perim1  0.5283 120 20 40 20 --perimeter 1
# ── Amendment 1: the matched eta pair at the shipped volume.
run E2_c1_eta2 0.7973 120 20 40 20 --perimeter 1 --eta 2
run E1_c1_eta1 0.7973 120 20 40 20 --perimeter 1 --eta 1
say "STAGE_A_DONE"
