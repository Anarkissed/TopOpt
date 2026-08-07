#!/usr/bin/env bash
# R3 — the exhaustiveness sweep behind s1c_consumers.md.
#
# The lattice file is named in exactly ONE place (lattice_base_name,
# core/src/cli/run_job.cpp:396), so every consumer must either spell the
# `_lattice.stl` / `_lattice.3mf` suffix or receive the path as a string out of
# `LatticeExportOutcome::paths`. Both routes are swept here, plus the negative
# checks that certification and the void rule never see a mesh at all.
set -u
cd "$(dirname "$0")/../.." || exit 1

echo "=== 1. Every spelling of the lattice file in SOURCE"
echo "    (whole repo minus evidence/, docs/, .git/, build outputs and caches)"
grep -rnI "_lattice\.stl\|_lattice\.3mf" . 2>/dev/null \
  | grep -v "^\./evidence/\|^\./docs/\|^\./\.git/\|^\./build\|/build/\|__pycache__\|\.claude/worktrees/" \
  | sed 's/[[:space:]]\+/ /g'
echo

echo "=== 2. The path-as-string route: LatticeExportOutcome::paths"
grep -rn "oc\.paths\|R\.oc\.paths\|result\.mesh_paths\|lattice_paths" core/src core/include \
  | sed 's/[[:space:]]\+/ /g'
echo

echo "=== 3. NEGATIVE — certification and the void rule hold no TriangleMesh"
for f in core/src/simp/analyze.cpp core/src/mesh/lattice_void.cpp \
         core/src/fea/strut_strength.cpp; do
  printf "  %-40s TriangleMesh occurrences: %s\n" "$f" "$(grep -c "TriangleMesh" "$f")"
done
echo "  analyze_fixed_design signature (core/include/topopt/analyze.hpp):"
grep -n "FixedDesignAnalysis analyze_fixed_design" -A 8 core/include/topopt/analyze.hpp \
  | sed 's/^/    /'
echo

echo "=== 4. NEGATIVE — nothing in core re-imports a mesh it wrote"
echo "  production callers of read_stl_file / import_stl_file (excluding tests):"
grep -rn "read_stl_file\|import_stl_file" core/src core/include \
  | grep -v "core/src/io/stl.cpp\|core/include/topopt/stl.hpp" \
  | sed 's/^/    /'
echo

echo "=== 5. The app: every fetch of a lattice artifact"
grep -rn "_lattice\.stl\|_lattice\.report\.json\|design\.bin\|lattice_variant\.json" \
     app/TopOptKit/Sources | sed 's/[[:space:]]\+/ /g' | sed 's/^/  /'
echo

echo "=== 6. What the worker announces as a VARIANT mesh (it is the SOLID one)"
grep -n 'printf("VARIANT' -A 3 core/src/cli/run_job.cpp | sed 's/^/  /'
grep -n '"mesh": os.path.basename' -B 2 tools/topopt-worker/topopt_worker.py | sed 's/^/  /'
echo

echo "=== 7. The worker's retention of out/ (there is none)"
grep -n "rmtree" tools/topopt-worker/topopt_worker.py | sed 's/^/  /'
echo "  ^ both are the UPLOAD staging tmpdir; out/ is never pruned."
