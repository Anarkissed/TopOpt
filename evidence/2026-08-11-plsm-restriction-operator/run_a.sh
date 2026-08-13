#!/bin/sh
# ★ CANDIDATE A — THE HELMHOLTZ DENSITY FILTER, SWEPT.
#
# ★ 3 THREADS, STRICTLY SERIAL, RUNG 0.68 ONLY. He needs his machine.
#
# ★ THE BASELINE IS PR 326's BEST ARM **WITHOUT THE PERIMETER PENALTY**, which
# the brief asks for so each candidate is measured as a restriction operator in
# its own right and not stacked on one that already works. That is eta = 1
# (PR 326 §3(e)'s free win) with the default seed, `--volume-count`, and the
# approximate reinitialisation — everything PR 326's `E1_c1_eta1` had except the
# penalty. `F0_none` is that arm, and it is the control every filter row is read
# against.
#
# ★ CERTIFY EVERY 10 FROM 30. R3 wants the margin as a curve with the settling
# iteration stated, and PR 326 measured that the margin settles far LATER than
# the compliance — C=8's margin doubled between iterations 40 and 60 while its
# compliance moved 2%. In-loop certification makes the curve visible while the
# arm runs instead of after it, and its cost is reported apart from the
# optimisation's. Nothing before iteration 30 is certified because certifying an
# unconverged design costs 26x what certifying a converged one costs (PR 326
# measured 537.9 s against 20.9 s).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

run() {
  name=$1; shift
  if [ -f "$HERE/arms/$name/summary.txt" ]; then echo "$name present"; return 0; fi
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arms/$name" \
      --rung 0.68 --iters 60 --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 \
      --certify-every 10 --certify-from 30 "$@" \
      > "$HERE/arms/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arms/$name.log") iterations, $(date '+%H:%M:%S')"
}

BASE="--seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 --eta 1"

# ── the control: no restriction operator of any kind.
run F0_none $BASE

# ── ★ CANDIDATE A, SWEPT. R5 — the radius is PER AXIS and a single number is
# expanded to three, never derived from a minimum over them. The bracket is
# chosen from his printable feature: the bead is 0.42 mm and the voxel is
# 1.705 mm, so 1 to 3 voxels spans "just above the representation floor" to
# "well above the 4.50 mm wall stack that closes holes anyway" (PR 326).
run FA_r1 $BASE --filter-radius 1
run FA_r2 $BASE --filter-radius 2
run FA_r3 $BASE --filter-radius 3

echo RUN_A_DONE
