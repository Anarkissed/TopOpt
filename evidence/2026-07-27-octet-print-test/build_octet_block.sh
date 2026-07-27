#!/bin/bash
# Build the octet PRINT-TEST block generator (handoff 2026-07-27-octet-print-test).
# Standalone; NOT wired into CTest. Compiles the OCCT/Eigen-free core sources it
# needs (mesh.cpp, stl.cpp) plus the lib3mf-gated threemf.cpp, and links lib3mf
# from the sibling lib3mf-macos-build worktree's vcpkg tree. Without lib3mf it
# still builds (OCTET_HAVE_3MF undefined) and writes STL only.
# Mirrors evidence/2026-07-26-octet-generation-cost/build_octet_probe.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../core" && pwd)"
OUT="${1:-/private/tmp/claude-501/octet-block-build}"
mkdir -p "$OUT"

L3MF_ROOT="/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lib3mf-macos-build-66e622/.vcpkg/installed/arm64-osx-dynamic"
L3MF_INC="$L3MF_ROOT/include/Bindings/Cpp"
L3MF_LIB="$L3MF_ROOT/lib"

CXX="${CXX:-c++}"
FLAGS="-std=c++17 -O2 -I $CORE/include"

HAVE_3MF=0
if [ -f "$L3MF_INC/lib3mf_implicit.hpp" ] && [ -f "$L3MF_LIB/lib3mf.dylib" ]; then
  HAVE_3MF=1
fi

echo "core       = $CORE"
echo "lib3mf     = $([ $HAVE_3MF = 1 ] && echo yes || echo no)"
echo "output dir = $OUT"

$CXX $FLAGS -c "$CORE/src/mesh/mesh.cpp" -o "$OUT/mesh.o"
$CXX $FLAGS -c "$CORE/src/io/stl.cpp"    -o "$OUT/stl.o"

OBJS="$OUT/mesh.o $OUT/stl.o"
EXTRA=""
if [ $HAVE_3MF = 1 ]; then
  $CXX $FLAGS -DTOPOPT_HAVE_3MF -I "$L3MF_INC" -c "$CORE/src/io/threemf.cpp" -o "$OUT/threemf.o"
  OBJS="$OBJS $OUT/threemf.o"
  EXTRA="-DOCTET_HAVE_3MF -I $L3MF_INC -L $L3MF_LIB -l3mf -Wl,-rpath,$L3MF_LIB"
fi

$CXX $FLAGS $EXTRA -c "$HERE/octet_block_gen.cpp" -o "$OUT/octet_block_gen.o"
$CXX $FLAGS $OBJS "$OUT/octet_block_gen.o" $EXTRA -o "$OUT/octet_block_gen"

echo "built: $OUT/octet_block_gen"
