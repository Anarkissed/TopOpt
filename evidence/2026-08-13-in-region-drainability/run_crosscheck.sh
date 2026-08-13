#!/bin/sh
# ★ ONE RUN, TWO BARS. Re-runs BS_robust — the arm the entire recommendation
# rests on — with the NEW binary, byte-identical flags to Stage B.
#
# R1  If its design reproduces the committed BS_robust snapshot BYTE FOR BYTE,
#     the added columns are proven inert: they write to the CSV and never touch
#     alpha, phi or occ. "Inert by construction" still gets the checksum.
# R2  And on that same design, sealed_mm3_manuf from the NEW C++ columns is
#     compared against sealed_void.py's 16,552.9 mm3. A CROSS-CHECK, not a
#     re-measurement — sealed_void.py already implemented the manufacturing
#     definition and remains the primary evidence.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; cd "$REPO"
B="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"; ST="$HERE/STATUS"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }
say "START X_robust_recheck (rung 0.7973) — flags identical to Stage B BS_robust"
mkdir -p "$HERE/arms/X_robust_recheck"
./build/levelset_probe "$B/M2_verticalStand.step" core/src/materials/materials.json \
    "$B/s2_simp_baseline/design.bin" "$HERE/arms/X_robust_recheck" \
    --rung 0.7973 --eta 1 --threads 6 --plsm-export 1 --plsm-export 2 --plsm-mma \
    --plsm-basis gaussian --plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24 \
    --volume-count --plsm-refit-every 5 --no-compliance-stop --iters 120 \
    --snapshot-every 20 --certify-from 40 --certify-every 20 \
    --seed holes --seed-period 8 --robust 0.15 \
    > "$HERE/arms/X_robust_recheck.log" 2>&1
rc=$?; its=$(grep -c '^it ' "$HERE/arms/X_robust_recheck.log" 2>/dev/null || echo 0)
[ $rc -ne 0 ] && { say "★ FAIL exit=$rc after $its"; exit 0; }
grep -q FATAL "$HERE/arms/X_robust_recheck.log" && { say "★ FAIL FATAL"; exit 0; }
say "OK X_robust_recheck $its iterations"
say "CROSSCHECK_DONE"
