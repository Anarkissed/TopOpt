#!/bin/bash
# Build the strut-lattice-family generator (handoff 2026-07-27-strut-lattice-family).
# Standalone; NOT wired into CTest, NOT built into production. Compiles the
# OCCT/Eigen-free core sources it needs (mesh.cpp, stl.cpp) plus the lib3mf-gated
# threemf.cpp, and links lib3mf from this worktree's vcpkg tree. Without lib3mf it
# still builds (LAT_HAVE_3MF undefined) and writes STL only.
# Mirrors evidence/2026-07-27-octet-print-test/build_octet_block.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../core" && pwd)"
OUT="${1:-/private/tmp/claude-501/strut-lattice-build}"
mkdir -p "$OUT"

# lib3mf from the current worktree's vcpkg install (vcpkg 2.5.0#1, == CI).
L3MF_ROOT="$(cd "$HERE/../.." && pwd)/.vcpkg/installed/arm64-osx-dynamic"
L3MF_INC="$L3MF_ROOT/include/Bindings/Cpp"
L3MF_LIB="$L3MF_ROOT/lib"

CXX="${CXX:-c++}"
FLAGS="-std=c++17 -O2 -I $CORE/include"

HAVE_3MF=0
if [ -f "$L3MF_INC/lib3mf_implicit.hpp" ] && [ -f "$L3MF_LIB/lib3mf.dylib" ]; then
  HAVE_3MF=1
fi

echo "core       = $CORE"
echo "lib3mf     = $([ $HAVE_3MF = 1 ] && echo "yes ($L3MF_LIB)" || echo no)"
echo "output dir = $OUT"

$CXX $FLAGS -c "$CORE/src/mesh/mesh.cpp" -o "$OUT/mesh.o"
$CXX $FLAGS -c "$CORE/src/io/stl.cpp"    -o "$OUT/stl.o"

OBJS="$OUT/mesh.o $OUT/stl.o"
EXTRA=""
if [ $HAVE_3MF = 1 ]; then
  $CXX $FLAGS -DTOPOPT_HAVE_3MF -I "$L3MF_INC" -c "$CORE/src/io/threemf.cpp" -o "$OUT/threemf.o"
  OBJS="$OBJS $OUT/threemf.o"
  EXTRA="-DLAT_HAVE_3MF -I $L3MF_INC -L $L3MF_LIB -l3mf -Wl,-rpath,$L3MF_LIB"
fi

$CXX $FLAGS $EXTRA -c "$HERE/strut_lattice_gen.cpp" -o "$OUT/strut_lattice_gen.o"
$CXX $FLAGS $OBJS "$OUT/strut_lattice_gen.o" $EXTRA -o "$OUT/strut_lattice_gen"

echo "built: $OUT/strut_lattice_gen"
