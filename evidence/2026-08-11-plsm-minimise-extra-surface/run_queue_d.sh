#!/bin/sh
# QUEUE D — THE NUCLEATION BAND, and the margin-variance measurement it carries.
#
# ★ A4 ISOLATES THE MASK. Same configuration as `S0_seed16` — coarse seed, no
# perimeter term at all — plus `--nucleation-band 2`. Against S0 it is the mask
# and nothing else. The perimeter penalty is deliberately ABSENT so the two
# mechanisms are not confounded: this task's §4 says the surface is nucleated,
# and this is the only mechanism that acts on nucleation DIRECTLY rather than by
# taxing all interface forever after.
#
# W = 2 voxels. The RBF support radius is 2 x 2 = 4 voxels, and a mask at or
# above that radius cannot zero a single non-zero gradient component (the probe
# refuses it). 2 is half the radius and equals eta.
#
# ★ --snapshot-every 1, AND THAT IS THE SECOND PURPOSE. The certified margin has
# moved 28% between iterations 57 and 60 of ONE trajectory whose compliance
# differed by 0.2%. Every "costs X% of margin" in this task is a difference of
# two single draws from that. Certifying EVERY iterate of a converged tail is
# what turns it into an error bar, and it costs one run that was being made
# anyway. 60 snapshots instead of 7.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
if [ -f "$HERE/arms/A4_mask/summary.txt" ]; then echo "A4 present, skipping"; exit 0; fi
mkdir -p "$HERE/arms/A4_mask"
./build/levelset_probe "$BAKE/M2_verticalStand.step" core/src/materials/materials.json \
    "$BAKE/s2_simp_baseline/design.bin" "$HERE/arms/A4_mask" \
    --rung 0.68 --iters 60 --threads 3 --snapshot-every 1 \
    --plsm-export 1 --plsm-export 2 \
    --seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
    --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 \
    --seed-period 16 --nucleation-band 2 \
    > "$HERE/arms/A4_mask.log" 2>&1
echo "A4_mask done: $(grep -c '^it ' "$HERE/arms/A4_mask.log") iterations"
