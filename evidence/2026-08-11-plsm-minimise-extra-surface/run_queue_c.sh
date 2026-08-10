#!/bin/sh
# QUEUE C — the one thing the eta PROBE cannot answer.
#
# `run_eta_probe.sh` showed that eta cannot change the EXTRACTED mesh's topology
# or classification at all — the crossing set is the sign set of phi_eff, which
# does not contain eta — and that carved roughness saturates by eta = 2.
#
# ★ BUT THE PERIMETER FUNCTIONAL CONTAINS eta: Per = ∫ DH_eta(phi)|grad phi| dΩ,
# and its GRADIENT is what S3's sweep optimised against. A narrower band
# concentrates the velocity more tightly at the interface, which is a statement
# about the TRAJECTORY, not about the extraction. The frontier is conditional on
# eta = 2 until this pair says otherwise.
#
# One arm, at the KNEE, against `P1_c1` — same weight, same seed, same
# everything, eta halved. If the frontier is eta-conditional it shows here.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
if [ -f "$HERE/arms/E1_c1_eta1/summary.txt" ]; then echo "E1 present, skipping"; exit 0; fi
mkdir -p "$HERE/arms/E1_c1_eta1"
./build/levelset_probe "$BAKE/M2_verticalStand.step" core/src/materials/materials.json \
    "$BAKE/s2_simp_baseline/design.bin" "$HERE/arms/E1_c1_eta1" \
    --rung 0.68 --iters 60 --threads 3 --snapshot-every 10 \
    --plsm-export 1 --plsm-export 2 \
    --seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
    --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 \
    --eta 1 --perimeter 1 \
    > "$HERE/arms/E1_c1_eta1.log" 2>&1
echo "E1_c1_eta1 done: $(grep -c '^it ' "$HERE/arms/E1_c1_eta1.log") iterations"
