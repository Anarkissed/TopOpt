#!/usr/bin/env bash
# Z6 — EXISTING PATHS BYTE-IDENTICAL.
#
# Builds the tree AT HEAD (before this task's changes) in a throwaway git
# worktree, runs the same optimize job and the same analyze job through both
# binaries, and compares the checksums of every artifact that existed before.
#
# What must match: report.json, fields.bin, every variant mesh, and the analyze
# route's analysis_report.json + analysis.json. What is EXPECTED to differ: the
# new, additive files (design.bin, loadcase.json), and run_info.json — which
# carries a wall-clock stamp and so differs between any two runs, before this
# task as much as after it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/z6-lattice-a-variant"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "== building HEAD (pre-change) in a throwaway worktree =="
git -C "$REPO" worktree add --detach "$WORK/head" HEAD >/dev/null 2>&1
cmake -S "$WORK/head/core" -B "$WORK/head/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$WORK/head/build" --target topopt_cli -j8 >/dev/null

echo "== building the working tree (post-change) =="
cmake --build "$REPO/core/build" --target topopt_cli -j8 >/dev/null

FIX="$REPO/core/tests/fixtures/mesh"
MAT="$REPO/core/src/materials/materials.json"
RUL="$REPO/core/src/settings/rules.json"

mk_job() {  # $1 = mode
  cat > "$WORK/job_$1.json" <<JSON
{
  "model": "$FIX/plate_bore.stl",
  "material": "PLA",
  "mode": "$1",
  "resolution": 32,
  "fixture_faces": [{"kind": "cylindrical", "radius_mm": 3.0}],
  "gravity": {"direction": [0, 0, -1], "magnitude_mm_s2": 9810},
  "ladder": [0.6],
  "margin_stop": 0.0,
  "simp": {"max_iterations": 8},
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON
}
mk_job minimize_plastic
mk_job analyze

run_pair() {  # $1 = cli, $2 = tag
  "$1" run     "$WORK/job_minimize_plastic.json" --out "$WORK/opt_$2" \
       --materials "$MAT" --rules "$RUL" >/dev/null
  "$1" analyze "$WORK/job_analyze.json"          --out "$WORK/ana_$2" \
       --materials "$MAT" --rules "$RUL" >/dev/null
}
run_pair "$WORK/head/build/topopt-cli" head
run_pair "$REPO/core/build/topopt-cli" work

echo
echo "== PRE-EXISTING ARTIFACTS (must be identical) =="
status=0
for f in opt/report.json opt/fields.bin opt/variant_060.stl \
         ana/analysis_report.json ana/analysis.json ana/fields.bin; do
  d="${f%%/*}"; n="${f#*/}"
  a="$WORK/${d}_head/$n"; b="$WORK/${d}_work/$n"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    printf '  MISSING  %-34s\n' "$f"; status=1; continue
  fi
  ha=$(shasum -a 256 "$a" | cut -d' ' -f1)
  hb=$(shasum -a 256 "$b" | cut -d' ' -f1)
  if [ "$ha" = "$hb" ]; then printf '  IDENTICAL %-34s %s\n' "$f" "${ha:0:16}"
  else printf '  DIFFERS   %-34s %s vs %s\n' "$f" "${ha:0:16}" "${hb:0:16}"; status=1; fi
done

echo
echo "== NEW, ADDITIVE ARTIFACTS (absent at HEAD, present now) =="
for f in design.bin loadcase.json; do
  a="$WORK/opt_head/$f"; b="$WORK/opt_work/$f"
  printf '  %-14s HEAD:%s  now:%s\n' "$f" \
    "$([ -f "$a" ] && echo present || echo absent)" \
    "$([ -f "$b" ] && echo present || echo absent)"
done

git -C "$REPO" worktree remove --force "$WORK/head" >/dev/null 2>&1 || true
echo
[ $status -eq 0 ] && echo "Z6: PASS — every pre-existing artifact is byte-identical." \
                  || echo "Z6: FAIL"
exit $status
