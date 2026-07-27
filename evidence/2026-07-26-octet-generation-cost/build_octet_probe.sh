#!/bin/bash
# Build the octet generation-cost probe (handoff 2026-07-26-octet-generation-cost).
# Standalone; NOT wired into CTest. Compiles the few OCCT/Eigen-free core sources
# it needs (mesh.cpp, stl.cpp) plus the lib3mf-gated threemf.cpp, and links lib3mf
# from the sibling lib3mf-macos-build worktree's vcpkg tree (handoff
# 2026-07-24-3mf-enable). If lib3mf is absent the probe still builds without the
# 3MF path (OCTET_HAVE_3MF undefined) and reports STL only.
set -euo pipefail

CORE="$(cd "$(dirname "$0")/../../core" && pwd)"
OUT="${1:-/private/tmp/claude-501/octet-build}"
mkdir -p "$OUT"

# lib3mf from the sibling worktree's vcpkg install (dynamic).
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

$CXX $FLAGS $EXTRA -c "$CORE/tests/harness/octet_gen_probe.cpp" -o "$OUT/octet_gen_probe.o"
$CXX $FLAGS $OBJS "$OUT/octet_gen_probe.o" $EXTRA -o "$OUT/octet_gen_probe"

echo "built: $OUT/octet_gen_probe"
