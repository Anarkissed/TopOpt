#!/usr/bin/env bash
# R1 — BYTE-IDENTICAL WHEN OFF. MEASURED, never "by construction".
#
#   BASE_REF=<commit> ./r1_byte_identity.sh <branch-build-dir> <out-dir>
#
# Adapted from evidence/2026-08-04-subfloor-lattice-unloaded-regions/s1_byte_identity.sh
# and its successor in 2026-08-05-lattice-cell-size-adaptation, INCLUDING the ★ trap:
# the CMake target is `topopt_cli` (underscore) while the BINARY is `topopt-cli`
# (hyphen), so `--target topopt-cli` finds an existing FILE, declares it up to date,
# exits 0 and builds NOTHING. This asserts the two binaries DIFFER before comparing a
# single artifact.
#
# ★★ WHAT THE BASELINE IS, AND WHY IT IS NOT origin/main. This branch is STACKED on
# PR #298 (claude/lattice-cell-size-adaptation), which is open and mergeable and which
# this task's brief assumes is already in the tree — `lattice_derive_cell_for_member`,
# `lattice_percolation_cells_per_member_min` and the three-case pre-flight all live
# there. So the honest control for "does THIS task move anything" is PR #298's tip,
# and BASE_REF must be that commit. PR #298's own movement against origin/main is
# measured in its own evidence (m5_byte_identity.txt); it is not re-litigated here.
#
# FOUR CASES:
#   A  NO LATTICE AT ALL. Must be byte-identical. Nothing here may touch a run that
#      does not lattice.
#   B  A GRADED SWEPT LATTICE with no new key. Must be byte-identical: fit is a new
#      mode nothing selects, and the S2 change is provably inert at a cell at or above
#      the rho_min floor. This is the case R1 is really about.
#   C  A GRADED FIXED LATTICE whose target is ABOVE the rho_min printability floor.
#      Must be byte-identical — this is the S2 no-op proof, measured: the max() picks
#      the target either way and no density is raised.
#   D  A GRADED FIXED LATTICE whose target is BELOW that floor. DELIBERATELY DIFFERENT.
#      That is the S2 fix. Asserted to differ, and the difference reported.
set -euo pipefail
BUILD="$(cd "${1:?usage: r1_byte_identity.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_REF="${BASE_REF:?set BASE_REF to the stack base (PR #298 tip)}"
BASE_BUILD="$OUT/.base-build"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
outp = {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
# resolution 24 and NO "loads" block, so the ladder can be stated and capped: with a
# "loads" block the job runs the production ladder to the MMA plateau (the schema
# refuses both "ladder" and "margin_stop" there, and simp.max_iterations does not bind
# the plateau), which on a shared machine is hours for a bar that only needs two
# binaries to agree bit for bit.
base = {"model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
        "resolution": 24,
        "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
        "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
        "ladder": [0.6], "margin_stop": 0.0,
        "simp": {"max_iterations": 12}, "output": outp}

# A — no lattice block at all.
json.dump(base, open(os.path.join(out, "job_nolattice.json"), "w"), indent=1)

def graded(gr):
    j = json.loads(json.dumps(base))
    j["lattice"] = {"topology": "octet", "emit_stl": True, "skin": "none",
                    "min_extrudable_width_mm": 0.20}
    j["grading"] = dict({"topology": "octet",
                         "min_extrudable_width_mm": 0.20}, **gr)
    return j

# B — swept: untouched by this task.
json.dump(graded({"cell_mode": "swept", "cell_min_mm": 2.5, "cell_max_mm": 10.0}),
          open(os.path.join(out, "job_swept.json"), "w"), indent=1)
# The rho_min printability floor at a 0.20 mm bead is 0.20/0.091252 = 2.1917 mm;
# the floor that binds (band top) is 0.20/0.383575 = 0.5214 mm.
# C — fixed ABOVE the rho_min floor: inert. 2.5 mm, not 4.0: it has to be above the
# floor AND fine enough that the members here clear the 5-cell ceiling, or the case
# lattices nothing and compares two empty results.
json.dump(graded({"cell_mode": "fixed", "cell_mm": 2.5}),
          open(os.path.join(out, "job_fixed_above.json"), "w"), indent=1)
# D — fixed BETWEEN the two floors: the S2 fix, deliberately different.
json.dump(graded({"cell_mode": "fixed", "cell_mm": 1.0}),
          open(os.path.join(out, "job_fixed_below.json"), "w"), indent=1)
PY

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
[ "$bs" != "$br" ] || { echo; echo "R1 FAIL — the two CLIs are THE SAME BINARY (the silent no-op target trap)."; exit 1; }
echo "the two binaries differ, as they must for this bar to mean anything."
echo

run() {
  local cli="$1" job="$2" sub="$3"
  rm -rf "${OUT:?}/$sub"
  set +e
  ( cd "$OUT" && "$cli" run "$job" --out "$sub" > "$sub.log" 2>&1 )
  local rc=$?
  set -e
  echo "$rc"
}

# The clock-bearing keys, NAMED one by one rather than pattern-matched, because
# "we dropped the keys that differed" is exactly the move that hides a regression.
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

compare() { # compare <L> <R>
  local L="$1" R="$2" bad=0 f a b meshes n=0
  # A MISSING RUN IS A FAILURE, NOT A MATCH. Without this a run that never started
  # compares two empty directories and reports IDENTICAL for everything — the
  # vacuous-bar failure this project has shipped before.
  if [ ! -d "$OUT/$L" ] || [ ! -d "$OUT/$R" ]; then
    echo "  MISSING    $L or $R never produced a run directory (see $L.log)"
    return 1
  fi
  meshes=$(cd "$OUT/$L" && ls variant_*.stl 2>/dev/null | sort)
  for f in report.json fields.bin design.bin $meshes; do
    [ -f "$OUT/$L/$f" ] || continue
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
    n=$((n+1))
    if [ "$a" = "$b" ]; then echo "  IDENTICAL  $f  ${a:0:16}…"
    else echo "  DIFFERS    $f"; bad=1; fi
  done
  for f in $(cd "$OUT/$L" && ls *_lattice.report.json 2>/dev/null | sort); do
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "  IDENTICAL  $f  ${a:0:16}…"
    else echo "  DIFFERS    $f"; bad=1; fi
  done
  if [ "$(strip_run_info "$OUT/$L/run_info.json" crossbinary)" = \
       "$(strip_run_info "$OUT/$R/run_info.json" crossbinary)" ]; then
    echo "  IDENTICAL  run_info.json (minus the named clock keys)"
  else echo "  DIFFERS    run_info.json beyond the clocks"; bad=1; fi
  if [ -f "$OUT/$L/iterations.csv" ] && [ -f "$OUT/$R/iterations.csv" ] &&
     diff -q <(strip_iters "$OUT/$L/iterations.csv") \
             <(strip_iters "$OUT/$R/iterations.csv") >/dev/null; then
    echo "  IDENTICAL  iterations.csv (physics columns)"
  else echo "  DIFFERS or MISSING  iterations.csv"; bad=1; fi
  if [ "$n" -eq 0 ]; then
    echo "  VACUOUS    no artifact was actually compared"
    bad=1
  fi
  return $bad
}

# `|| true`: with `set -o pipefail` a no-match `ls` fails, the command substitution
# fails, and `set -e` kills the whole script mid-bar — which is exactly how the first
# run of this file died silently between cases C and D.
lattice_receipts() {
  ls "$OUT/$1"/*_lattice.report.json 2>/dev/null | wc -l | tr -d ' ' || true
}

fail=0
echo "########## A — NO LATTICE, base vs branch. MUST be identical. ##########"
run "$BASE_CLI" job_nolattice.json A_base > /dev/null
run "$BR_CLI"   job_nolattice.json A_branch > /dev/null
if compare A_base A_branch; then echo "  A PASS"; else echo "  A FAIL"; fail=1; fi
echo

echo "########## B — GRADED SWEPT LATTICE, base vs branch. MUST be identical. ##########"
run "$BASE_CLI" job_swept.json B_base > /dev/null
run "$BR_CLI"   job_swept.json B_branch > /dev/null
n=$(lattice_receipts B_base); echo "  lattice receipts emitted by the control: $n"
if [ "$n" = "0" ]; then echo "  B VACUOUS — the control emitted NO lattice. Fix the fixture."; fail=1
elif compare B_base B_branch; then echo "  B PASS"; else echo "  B FAIL"; fail=1; fi
echo

echo "########## C — GRADED FIXED, cell ABOVE the rho_min floor. MUST be identical. ##########"
run "$BASE_CLI" job_fixed_above.json C_base > /dev/null
run "$BR_CLI"   job_fixed_above.json C_branch > /dev/null
n=$(lattice_receipts C_base); echo "  lattice receipts emitted by the control: $n"
if [ "$n" = "0" ]; then echo "  C VACUOUS — the control emitted NO lattice. Fix the fixture."; fail=1
elif compare C_base C_branch; then echo "  C PASS (the S2 path is inert here)"; else echo "  C FAIL"; fail=1; fi
echo

echo "########## D — GRADED FIXED, cell BELOW that floor. DELIBERATELY DIFFERENT. ##########"
rcD1=$(run "$BASE_CLI" job_fixed_below.json D_base)
rcD2=$(run "$BR_CLI"   job_fixed_below.json D_branch)
echo "  base exit $rcD1, branch exit $rcD2"
python3 - "$OUT/D_base" "$OUT/D_branch" <<'PY'
import json, os, sys
for d in sys.argv[1:]:
    ri = os.path.join(d, "run_info.json")
    if not os.path.exists(ri):
        print(f"  {os.path.basename(d)}: no run_info.json (refused or unfinished)")
        continue
    g = json.load(open(ri)).get("grading") or {}
    print(f"  {os.path.basename(d)}: cell_size_mm={g.get('cell_size_mm')} "
          f"floored={g.get('cell_size_floored')} "
          f"latticed={g.get('latticed_voxels')} "
          f"solid_fallback={g.get('solid_fallback_voxels')}")
PY
if compare D_base D_branch > /dev/null 2>&1; then
  echo "  D FAIL — the S2 fix changed NOTHING on the job it exists to fix."
  fail=1
else
  echo "  D PASS — they differ, which is the deliverable. The cells above say how."
fi
echo

[ "$fail" = "0" ] && echo "R1 PASS." || { echo "R1 FAIL."; exit 1; }
