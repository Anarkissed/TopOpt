#!/usr/bin/env bash
# reproduce.sh — task 2026-07-31-lattice-page-core-hookup evidence.
#
# Rebuilds core, runs the hookup test suites, then replays every evidence CLI
# run into $OUT (default /tmp/hookup_evidence_repro). The parent-binary
# byte-identity halves need a checkout of 21ce7ed built separately; point
# PARENT_CLI at its topopt-cli to include those comparisons.
#
# Usage: ./reproduce.sh [repo-root]   (default: two levels up from this file)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$HERE/../.." && pwd)}"
OUT="${OUT:-/tmp/hookup_evidence_repro}"
MAT="$ROOT/core/src/materials/materials.json"
RUL="$ROOT/core/src/settings/rules.json"
JOBS="$HERE/jobs"

cmake -S "$ROOT/core" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release
make -C "$ROOT/build" -j8

# The hookup suites: schema (H1e/H3a), role precedence per pair + one-predicate
# coherence (H1a/H1b), enum tripwire (H2), and the E2E matrix/graded/analyze
# suite (H1c/H1d/H4a-c/H3a-c/H5).
(cd "$ROOT/build" && ctest -R "job_schema|lattice_boundary|lattice_gen|grading|lattice_hookup" --output-on-failure)

CLI="$ROOT/build/topopt-cli"
rm -rf "$OUT"; mkdir -p "$OUT"

run() { "$CLI" run "$JOBS/$1.json" --out "$OUT/$2" --materials "$MAT" --rules "$RUL" > "$OUT/$2.log" 2>&1; }

run nolattice nolattice
run uniform uniform
run exclude exclude
run include include
run include_exclude include_exclude_1
run include_exclude include_exclude_2
run graded graded_1
run graded graded_2
"$CLI" analyze "$JOBS/analyze.json" --out "$OUT/analyze" --materials "$MAT" --rules "$RUL" > "$OUT/analyze.log" 2>&1
if "$CLI" run "$JOBS/analyze.json" --out "$OUT/analyze_refused" --materials "$MAT" --rules "$RUL" > "$OUT/analyze_run_refusal.log" 2>&1; then
  echo "FAIL: run accepted an analyze-mode job"; exit 1
fi
# The all-three-roles loadcase run (production ladder — the slow one).
run clearance_roles_loadcase clearance_roles

echo "== determinism (H5) =="
for f in variant_060_lattice.stl variant_060_lattice.report.json report.json; do
  cmp "$OUT/include_exclude_1/$f" "$OUT/include_exclude_2/$f" && echo "identical: roles/$f"
done
for f in variant_100_lattice.stl variant_100_lattice.report.json report.json fields.bin; do
  cmp "$OUT/graded_1/$f" "$OUT/graded_2/$f" && echo "identical: graded/$f"
done

# Parent-binary halves (optional): PARENT_CLI must be a topopt-cli built at
# 21ce7ed (the pre-task main). Expect: nolattice/uniform outputs bit-identical;
# exclude.json / graded.json REFUSED by the parent's strict parser.
if [ -n "${PARENT_CLI:-}" ]; then
  for job in nolattice uniform; do
    "$PARENT_CLI" run "$JOBS/$job.json" --out "$OUT/${job}_parent" --materials "$MAT" --rules "$RUL" > /dev/null 2>&1
    for f in report.json variant_060.stl variant_060_lattice.stl variant_060_lattice.report.json fields.bin; do
      [ -f "$OUT/${job}_parent/$f" ] || continue
      cmp "$OUT/${job}_parent/$f" "$OUT/$job/$f" && echo "identical vs parent: $job/$f"
    done
  done
  "$PARENT_CLI" run "$JOBS/exclude.json" --out "$OUT/parent_reject" --materials "$MAT" --rules "$RUL" 2>&1 | tail -1
fi

# Worker analyze-route e2e (stage 3, pure python — no Xcode).
python3 "$ROOT/tools/topopt-worker/e2e/analyze_route_e2e.py"

echo "reproduce: DONE — artifacts in $OUT"
