#!/bin/sh
# S0 — ★ THE THREE HEADER MOVES INTO CORE ARE NO-OPS, AND THIS MEASURES IT.
#
# Task 2026-08-10-plsm-production needed the parametric level-set BASIS, the
# level-set FIELD KERNEL and the coefficient-space MMA STEP on the PRODUCTION
# path. All three lived in `core/tests/harness/`. A production copy of any of
# them would have been exactly the two-implementations failure PR 324 created
# those headers to prevent — a second smoothing law, a second basis, a second
# MMA — so they were MOVED into core and the harness headers became SHIMS:
#
#   core/tests/harness/plsm_basis.hpp     -> core/include/topopt/plsm_basis.hpp
#   core/tests/harness/levelset_kernel.hpp-> core/include/topopt/plsm_kernel.hpp
#   core/tests/harness/plsm_mma.hpp       -> core/include/topopt/plsm_mma.hpp
#
# ★ A MOVE IS VERIFIED, NEVER ASSERTED (PR 324's own S0 discipline). BEFORE is
# the pre-task commit, extracted with `git archive HEAD` into a scratch tree and
# built there — nothing in the working tree is stashed and nothing is cloned.
# AFTER is this tree. Both run the SAME two probes on the SAME inputs at three
# threads, and every computed column plus every emitted field must be identical.
#
# Cost on the machine of record (10 cores, 3 threads): ~4 min for the BEFORE
# build, ~2 min for the two trajectories, ~3 min for the two fits.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
ALPHA="$REPO/evidence/2026-08-10-parametric-level-set"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
cd "$REPO"

STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
OUT="$HERE/s0_core_move"
mkdir -p "$OUT"

# The fit subject: PR 324's own, so this is the same measurement on the same
# object and the two runs differ only in which tree built the binary.
mkdir -p "$SCRATCH/src"
gunzip -c "$ALPHA/sources/C2it25.f64.gz" > "$SCRATCH/src/C2it25.f64"
cp "$ALPHA/sources/C2it25.meta" "$SCRATCH/src/C2it25.meta"

# BEFORE — the pre-task commit, built OUTSIDE the repository.
rm -rf "$SCRATCH/before-tree"
mkdir -p "$SCRATCH/before-tree"
git archive HEAD | tar -x -C "$SCRATCH/before-tree"
cmake -S "$SCRATCH/before-tree/core" -B "$SCRATCH/before-build" \
    -DCMAKE_BUILD_TYPE=Release > "$SCRATCH/before-cm.log" 2>&1
cmake --build "$SCRATCH/before-build" -j6 \
    --target plsm_probe levelset_probe > "$SCRATCH/before-build.log" 2>&1

# AFTER — this tree.
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target plsm_probe levelset_probe > /dev/null

for side in before after; do
  if [ "$side" = before ]; then BIN="$SCRATCH/before-build"; else BIN="$REPO/build"; fi
  # (1) the KERNEL + the shipped voxel arm: a 3-iteration trajectory.
  "$BIN/levelset_probe" "$STEP" "$MATS" "$REF" "$OUT/traj_$side" \
      --rung 0.68 --iters 3 --threads 3 --gridap-auto min \
      > "$OUT/traj_$side.log" 2>&1
  # (2) the BASIS: PR 324's own two fits.
  "$BIN/plsm_probe" "$SCRATCH/src/C2it25" "$OUT/fit_$side" \
      --threads 3 --emit-factor 1 \
      --fit W4:wendland:4,4,4:2 --fit G2:gaussian:2,2,2:2 \
      > "$OUT/fit_$side.log" 2>&1
done

# Columns 1-12 and 15-22 of iterations.csv: everything but the three wall clocks.
for f in "$OUT/traj_before" "$OUT/traj_after"; do
  cut -d, -f1-12,15-22 "$f/iterations.csv" > "$f.cols"
done
# fits.csv: everything but the wall clock (whose column name is `fit_s`).
python3 - "$OUT/fit_before/fits.csv" "$OUT/fit_after/fits.csv" \
         "$OUT/fit_before.cols" "$OUT/fit_after.cols" <<'PY'
import sys
src_b, src_a, dst_b, dst_a = sys.argv[1:5]
for src, dst in ((src_b, dst_b), (src_a, dst_a)):
    rows = [l.rstrip("\n").split(",") for l in open(src)]
    drop = [i for i, h in enumerate(rows[0]) if "wall" in h or h.strip() == "fit_s"]
    with open(dst, "w") as f:
        for r in rows:
            f.write(",".join(c for i, c in enumerate(r) if i not in drop) + "\n")
PY

{
  echo "== THE THREE HEADER MOVES INTO CORE ARE NO-OPS =="
  echo
  echo "BEFORE: $(git rev-parse --short HEAD), built in $SCRATCH/before-build"
  echo "AFTER : this tree, with plsm_basis / plsm_kernel / plsm_mma in core and"
  echo "        the three harness headers reduced to shims over them."
  echo "Both at 3 threads."
  echo
  echo "-- (1) THE KERNEL. levelset_probe, 3 iterations, --gridap-auto min."
  echo "   every COMPUTED column of iterations.csv (all but the three wall clocks)"
  diff "$OUT/traj_before.cols" "$OUT/traj_after.cols" \
    && echo "   IDENTICAL (the diff above is empty)"
  echo
  echo "   the final ersatz occupancy, 468224 float64"
  cmp "$OUT/traj_before/rho.f64" "$OUT/traj_after/rho.f64" \
    && echo "   rho.f64 BYTE-IDENTICAL"
  echo
  echo "-- (2) THE BASIS. plsm_probe, W4 wendland 4,4,4 s2 and G2 gaussian 2,2,2 s2."
  echo "   every column of fits.csv but the wall clock"
  diff "$OUT/fit_before.cols" "$OUT/fit_after.cols" \
    && echo "   IDENTICAL (the diff above is empty)"
  echo
  echo "   the emitted voxel-lattice occupancy of each fit"
  for g in W4 G2; do
    cmp "$OUT/fit_before/${g}_vm_f1.f64" "$OUT/fit_after/${g}_vm_f1.f64" \
      && echo "   ${g}_vm_f1.f64 BYTE-IDENTICAL"
  done
  echo
  echo "-- (3) THE MMA STEP is exercised by --plsm-mma, which the S2 frontier runs;"
  echo "   its move is covered by the R1 byte-identity control and by the fact that"
  echo "   core/tests/harness/plsm_mma.hpp now DEFINES nothing (it is 2 using-"
  echo "   declarations), so there is no second copy left to drift."
} > "$OUT/verdict.txt" 2>&1
rm -f "$OUT"/*.cols
cat "$OUT/verdict.txt"
