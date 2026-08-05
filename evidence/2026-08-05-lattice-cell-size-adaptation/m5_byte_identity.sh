#!/usr/bin/env bash
# M5 / R1 — WHAT IS BYTE-IDENTICAL, AND WHAT DELIBERATELY IS NOT.
#
#   ./m5_byte_identity.sh <branch-build-dir> <out-dir>
#
# Adapted from evidence/2026-08-04-subfloor-lattice-unloaded-regions/s1_byte_identity.sh,
# including its ★ trap: the CMake target is `topopt_cli` (underscore) while the BINARY
# is `topopt-cli` (hyphen), so `--target topopt-cli` finds an existing FILE, declares
# it up to date, exits 0 and builds NOTHING. This script asserts the two binaries
# DIFFER before comparing a single artifact.
#
# THIS PR HAS FOUR CASES WITH DIFFERENT IDENTITY PROPERTIES. Collapsing them into one
# question would hide three of them.
#
#   A. NO LATTICE AT ALL, base vs branch. Must be BYTE-IDENTICAL. Nothing in this PR
#      may touch a run that does not lattice. HARD ASSERTION.
#
#   B. LATTICE, base vs branch, NO new key set, and a job that trips NEITHER new
#      refusal (skin "none", regions comfortably above every floor). Must be
#      BYTE-IDENTICAL: the new code is two throw paths and one additive receipt
#      block, none of which this job reaches. HARD ASSERTION. This is the case R1
#      is really about — "by construction" is exactly what R1 forbids, so it is
#      measured.
#
#   C. LATTICE, report_region_cells ON vs OFF, SAME binary. Everything must match
#      EXCEPT the `regions` block the graded receipt gains — which MUST differ, or
#      the user could not tell the option was on. HARD ASSERTION.
#
#   D. The two REFUSALS, base vs branch. DELIBERATELY DIFFERENT — that is the
#      feature. Asserted: base SUCCEEDS and branch REFUSES, and the refusal names
#      the arithmetic. Covered by b1_all_regions_too_thin.sh, m1_before/after and
#      m4_blast_radius.sh; restated here only so the record is in one place.
set -euo pipefail
BUILD="${1:?usage: m5_byte_identity.sh <branch-build-dir> <out-dir>}"
OUT="${2:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_BUILD="$OUT/.base-build"
mkdir -p "$OUT"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
loads = {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
         "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]}
outp = {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}

# A — no lattice block at all.
json.dump({"model": "l-bracket.step", "material": "PLA",
           "mode": "minimize_plastic", "resolution": 40,
           "simp": {"max_iterations": 12}, "loads": loads, "output": outp},
          open(os.path.join(out, "job_nolattice.json"), "w"), indent=1)

# B — a GRADED lattice that trips neither new refusal: skin "none" (so the rim
# refusal cannot fire) and NO include regions (so the too-thin refusal, which is
# scoped to declared include regions, cannot fire either).
lat = {"model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
       "resolution": 40, "simp": {"max_iterations": 12}, "loads": loads,
       "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                   "min_extrudable_width_mm": 0.20},
       "grading": {"topology": "octet", "cell_mode": "swept",
                   "cell_min_mm": 2.5, "cell_max_mm": 10.0,
                   "min_extrudable_width_mm": 0.20},
       "output": outp}
json.dump(lat, open(os.path.join(out, "job_lattice.json"), "w"), indent=1)

# C — the same job with the Stage A/E report armed.
c = json.loads(json.dumps(lat))
c["grading"]["report_region_cells"] = True
json.dump(c, open(os.path.join(out, "job_lattice_report.json"), "w"), indent=1)
PY

BASE_REF="${BASE_REF:-origin/main}"
WT="$OUT/.base-worktree"
rm -rf "$WT"
git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_wt.log" 2>&1
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
cmake -S "$WT/core" -B "$BASE_BUILD" -DCMAKE_BUILD_TYPE=Release > "$OUT/base_cfg.log" 2>&1
cmake --build "$BASE_BUILD" --target topopt_cli -j8 > "$OUT/base_build.log" 2>&1
cmake --build "$BUILD"      --target topopt_cli -j8 > "$OUT/branch_build.log" 2>&1
git -C "$REPO" rev-parse "$BASE_REF" > "$OUT/base_commit.txt"

BASE_CLI="$BASE_BUILD/topopt-cli"
BR_CLI="$BUILD/topopt-cli"
bs=$(shasum -a 256 "$BASE_CLI" | cut -d' ' -f1)
br=$(shasum -a 256 "$BR_CLI"   | cut -d' ' -f1)
echo "base commit : $(cat "$OUT/base_commit.txt")"
echo "base   cli sha256: $bs"
echo "branch cli sha256: $br"
[ "$bs" != "$br" ] || { echo; echo "M5 FAIL — the two CLIs are THE SAME BINARY (the silent-no-op target trap)."; exit 1; }
echo "the two binaries differ, as they must for this bar to mean anything."
echo

run() {
  local cli="$1" job="$2" sub="$3"
  rm -rf "${OUT:?}/$sub"
  ( cd "$OUT" && "$cli" run "$job" --out "$sub" > "$sub.log" 2>&1 ) || {
    echo "RUN FAILED ($sub):"; tail -20 "$OUT/$sub.log"; exit 1; }
}

# The clock-bearing keys, NAMED one by one rather than pattern-matched, because
# "we dropped the keys that differed" is exactly the move that hides a regression.
# `fingerprint` is the build-provenance commit and is dropped ONLY across binaries,
# which the run above already proved differ.
strip_run_info() {
  python3 -c "
import json,sys
CLOCKS={'created_wall_ms','gen_seconds','gen_fraction','preflight_ms'}
if len(sys.argv)>2 and sys.argv[2]=='crossbinary': CLOCKS.add('fingerprint')
def scrub(x):
    if isinstance(x, dict): return {k: scrub(v) for k, v in x.items() if k not in CLOCKS}
    if isinstance(x, list): return [scrub(v) for v in x]
    return x
print(json.dumps(scrub(json.load(open(sys.argv[1]))), sort_keys=True, indent=1))" "$1" "${2:-}"
}
strip_iters() { cut -d, -f1,2,4-13 "$1"; }
# RECURSIVE strip of the Stage A/E `regions` block — it is nested inside `grading`,
# so a top-level pop silently strips nothing.
strip_regions() {
  python3 -c "
import json,sys
def scrub(x):
    if isinstance(x, dict):
        return {k: scrub(v) for k, v in x.items() if k not in ('regions','regions_note')}
    if isinstance(x, list): return [scrub(v) for v in x]
    return x
print(json.dumps(scrub(json.load(open(sys.argv[1]))), sort_keys=True, indent=1))" "$1"
}

compare() { # compare <L> <R> <crossbinary|samebinary> [stripregions]
  local L="$1" R="$2" mode="$3" strip="${4:-}" bad=0 f a b meshes
  meshes=$(cd "$OUT/$L" && ls variant_*.stl 2>/dev/null | sort)
  for f in report.json fields.bin design.bin $meshes; do
    [ -f "$OUT/$L/$f" ] || continue
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "  IDENTICAL  $f  ${a:0:16}…"
    else echo "  DIFFERS    $f"; bad=1; fi
  done
  for f in $(cd "$OUT/$L" && ls *_lattice.report.json 2>/dev/null | sort); do
    if [ "$strip" = "stripregions" ]; then
      if diff -q <(strip_regions "$OUT/$L/$f") <(strip_regions "$OUT/$R/$f") >/dev/null; then
        echo "  IDENTICAL  $f (minus the Stage A/E regions block)"
      else echo "  DIFFERS    $f beyond the regions block"; bad=1; fi
    else
      a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
      b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
      if [ "$a" = "$b" ]; then echo "  IDENTICAL  $f  ${a:0:16}…"
      else echo "  DIFFERS    $f"; bad=1; fi
    fi
  done
  if [ "$(strip_run_info "$OUT/$L/run_info.json" "$mode")" = \
       "$(strip_run_info "$OUT/$R/run_info.json" "$mode")" ]; then
    echo "  IDENTICAL  run_info.json (minus the named clock keys)"
  else echo "  DIFFERS    run_info.json beyond the clocks"; bad=1; fi
  if diff -q <(strip_iters "$OUT/$L/iterations.csv") \
             <(strip_iters "$OUT/$R/iterations.csv") >/dev/null; then
    echo "  IDENTICAL  iterations.csv (physics columns)"
  else echo "  DIFFERS    iterations.csv in a physics column"; bad=1; fi
  return $bad
}

fail=0
echo "########## A — NO LATTICE, base vs branch. MUST be identical. ##########"
run "$BASE_CLI" job_nolattice.json A_base
run "$BR_CLI"   job_nolattice.json A_branch
if compare A_base A_branch crossbinary; then echo "  A PASS"; else echo "  A FAIL"; fail=1; fi
echo

echo "########## B — GRADED LATTICE, no new key, base vs branch. MUST be identical. ##########"
run "$BASE_CLI" job_lattice.json B_base
run "$BR_CLI"   job_lattice.json B_branch
nlat=$(ls "$OUT/B_base"/*_lattice.report.json 2>/dev/null | wc -l | tr -d ' ')
echo "  lattice receipts emitted by the control: $nlat"
if [ "$nlat" = "0" ]; then
  echo "  B VACUOUS — the control emitted NO lattice, so this compares two empty"
  echo "    results and says nothing about the lattice path. Fix the fixture."
  fail=1
elif compare B_base B_branch crossbinary; then echo "  B PASS"; else echo "  B FAIL"; fail=1; fi
echo

echo "########## C — report_region_cells ON vs OFF, same binary. ##########"
echo "Everything must match EXCEPT the regions block, which MUST differ."
run "$BR_CLI" job_lattice_report.json C_on
if compare B_branch C_on samebinary stripregions; then echo "  C base PASS"
else echo "  C FAIL — arming the report changed something else."; fail=1; fi
python3 - "$OUT/B_branch" "$OUT/C_on" <<'PY' || fail=1
import glob, json, os, sys
off, on = sys.argv[1], sys.argv[2]
seen = False
for f in sorted(glob.glob(os.path.join(on, "*_lattice.report.json"))):
    g = json.load(open(f)).get("grading") or {}
    r = g.get("regions")
    base = os.path.join(off, os.path.basename(f))
    gb = (json.load(open(base)).get("grading") or {}) if os.path.exists(base) else {}
    print(f"  {os.path.basename(f)}: OFF has regions={'regions' in gb}, "
          f"ON has regions={r is not None}"
          + (f" ({len(r)} row(s))" if r else ""))
    if r is not None and "regions" not in gb:
        seen = True
if not seen:
    print("  UNEXPECTED: the regions block did not appear, so C tested nothing.")
sys.exit(0 if seen else 1)
PY
echo

echo "########## D — the two REFUSALS. DELIBERATELY DIFFERENT. ##########"
echo "  Measured separately and in full:"
echo "    b1_before.txt / b1_after.txt  — all-regions-too-thin: base exits 0 and"
echo "        emits 161 cells; branch refuses and names the working cell range."
echo "    m1_before.txt / m1_after.txt  — graded AUTO at 6 mm: the pre-review"
echo "        branch refused (the M1 defect); it now runs."
echo "    m4_blast_radius.txt           — a skin/rim finish that emits nothing:"
echo "        base succeeds while emitting zero rim geometry, branch refuses."
echo "        Measured on BOTH a faceless boundary and a bolt-clearance one"
echo "        (the latter is the case the faces()-empty predicate MISSED)."
echo

if [ "$fail" = "0" ]; then
  echo "M5 PASS — a run with no lattice is byte-identical (A); a graded lattice run"
  echo "          that trips neither refusal is byte-identical (B); arming the Stage"
  echo "          A/E report changes nothing but its own block (C); and the two new"
  echo "          refusals move only the runs they are meant to (D)."
  exit 0
fi
echo "M5 FAIL."
exit 1
