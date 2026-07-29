#!/usr/bin/env bash
# Build the Apple-silicon envelope benchmark harnesses (handoff
# 2026-07-28-apple-silicon-envelope). Standalone; NOT wired into CTest and NOT
# compiled into libtopopt — measurement-only, per bar B3 (no production change, no
# new build dependency: Accelerate and Metal are system frameworks).
#
#   stream            H1  STREAM triad memory bandwidth (no deps)
#   matvec_roofline   H2  production matrix-free operator roofline (links core objs)
#   accel_amx         H3  Accelerate/AMX FP64 gemv/gemm vs our hand kernel
#   metal_matvec      H4  Metal FP32 element-apply prototype (operator only)
#
# Usage: ./build.sh [out_dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../core" && pwd)"
EIGEN="${EIGEN_PREFIX:-/opt/homebrew/include/eigen3}"
OUT="${1:-/private/tmp/claude-501/asi-bench}"
mkdir -p "$OUT"

CXX="${CXX:-c++}"
STD="-O3 -std=c++17"
INC="-I $CORE/include -I $CORE/src/fea -I $EIGEN"

echo "core  = $CORE"
echo "eigen = $EIGEN"
echo "out   = $OUT"

# --- H1: STREAM (no deps) ----------------------------------------------------
$CXX $STD "$HERE/stream.cpp" -o "$OUT/stream"

# --- H2: matrix-free operator roofline (links the real production kernel) -----
# Compile the minimal core objects the reduced matvec needs: matfree (operator),
# assembly (fea_node_count / fea_element_nodes), hex_element (hex8_stiffness),
# recycle (RecycleSession). voxelize.o is deliberately NOT linked — the harness
# defines VoxelGrid::solid_count() itself (byte-identical) to stay geometry-free.
for f in fea/matfree fea/assembly fea/hex_element fea/recycle; do
  $CXX $STD $INC -c "$CORE/src/$f.cpp" -o "$OUT/$(basename "$f").o"
done
$CXX $STD $INC "$HERE/matvec_roofline.cpp" \
  "$OUT/matfree.o" "$OUT/assembly.o" "$OUT/hex_element.o" "$OUT/recycle.o" \
  -o "$OUT/matvec_roofline"

# --- H3: Accelerate / AMX ----------------------------------------------------
$CXX $STD -DACCELERATE_NEW_LAPACK "$HERE/accel_amx.cpp" -framework Accelerate \
  -o "$OUT/accel_amx"

# --- H4: Metal FP32 prototype ------------------------------------------------
# Objective-C++ driver with the MSL kernel compiled at runtime from a source
# string (no offline .metallib step, no new build rule). Reuses the same core
# objects as H2 to build the production element table before uploading it.
$CXX $STD -fobjc-arc $INC "$HERE/metal_matvec.mm" \
  "$OUT/matfree.o" "$OUT/assembly.o" "$OUT/hex_element.o" "$OUT/recycle.o" \
  -framework Metal -framework Foundation -o "$OUT/metal_matvec"

echo "built: stream matvec_roofline accel_amx metal_matvec -> $OUT"
