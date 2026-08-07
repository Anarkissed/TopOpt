#!/usr/bin/env bash
# R1 — BYTE-IDENTICAL WHERE NOTHING CHANGED. MEASURED, never "by construction".
#
#   BASE_REF=<commit> ./r1_byte_identity.sh <branch-build-dir> <out-dir>
#
# Adapted from evidence/2026-08-05-lattice-cell-fit-mode/r1_byte_identity.sh, INCLUDING
# its ★ trap: the CMake target is `topopt_cli` (underscore) while the BINARY is
# `topopt-cli` (hyphen), so `--target topopt-cli` finds an existing FILE, declares it up
# to date, exits 0 and builds NOTHING. This asserts the two binaries DIFFER before
# comparing a single artifact.
#
# ★ WHAT THIS BAR COVERS AND WHAT IT DOES NOT. It compares BYTES: meshes, design.bin,
# fields.bin, report.json, the lattice receipts, run_info.json (minus named clocks) and
# iterations.csv. It does NOT cover MESSAGE TEXT — S3 rewrites every multi-region
# refusal and forecast, so on any job that declares lattice regions the stderr text is
# EXPECTED to differ and is compared separately in s3_message_before_after.txt. Case D
# below is the one that carries regions, and it asserts exactly that split: geometry
# identical, text different.
#
# SEVEN CASES:
#   A  NO LATTICE AT ALL. Nothing here may touch a run that does not lattice.
#   B  GRADED FIXED, cell above the rho_min floor. Untouched by this task.
#   C  GRADED SWEPT, declared minimum ABOVE the rho_min floor. THE S1 NO-OP PROOF:
#      the new rule returns the declared minimum unchanged there, which is every swept
#      job the app authors (runSpec pushes both ends onto core's floor).
#   D  GRADED AUTO WITH REGIONS, thick enough not to refuse. Geometry identical;
#      stderr text DIFFERENT by design (S3).
#   E  GRADED SWEPT, declared minimum BETWEEN the two floors, with a thin region.
#      DELIBERATELY DIFFERENT: base REFUSES, branch RUNS. That is S1.
#   F  UNIFORM (non-graded) lattice. Untouched.
#   G  SWEPT + MULTISCALE with a sub-floor minimum and NO regions — the ONE path where
#      S1 reaches geometry (multiscale_floor_cell_mm feeds min_feature_mm). Measured
#      rather than assumed, because a flip here would be a blocked-stop.
set -euo pipefail
BUILD="$(cd "${1:?usage: r1_byte_identity.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_REF="${BASE_REF:-origin/main}"
BASE_BUILD="$OUT/.base-build"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
outp = {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
# resolution 24 and NO "loads" block, so the ladder can be stated and capped: with a
# "loads" block the job runs the production ladder to the MMA plateau (the schema
# refuses both "ladder" and "margin_stop" there, and simp.max_iterations does not bind
# the plateau).
base = {"model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
        "resolution": 24,
        "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
        "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
        "ladder": [0.6], "margin_stop": 0.0,
        "simp": {"max_iterations": 12}, "output": outp}

# At a 0.20 mm strut line width:
#   light floor (rho_MIN)  = 0.20 / 0.091252 = 2.1917 mm  <- what SWEPT used to report
#   frontier    (rho_MAX)  = 0.20 / 0.383575 = 0.5214 mm  <- what actually binds
W = 0.20

# A — no lattice block at all.
json.dump(base, open(os.path.join(out, "job_nolattice.json"), "w"), indent=1)

def graded(gr, regions=None, multiscale=False):
    j = json.loads(json.dumps(base))
    lat = {"topology": "octet", "emit_stl": True, "skin": "none",
           "min_extrudable_width_mm": W}
    if regions is not None:
        lat["regions"] = regions
    if multiscale:
        lat["multiscale"] = True
    j["lattice"] = lat
    j["grading"] = dict({"topology": "octet", "min_extrudable_width_mm": W}, **gr)
    return j

def slab(depth):
    return [{"role": "include", "kind": "face",
             "geometry": {"origin": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0],
                          "half_u_mm": 300.0, "half_w_mm": 300.0,
                          "depth_mm": depth}}]

json.dump(graded({"cell_mode": "fixed", "cell_mm": 2.5}),
          open(os.path.join(out, "job_fixed.json"), "w"), indent=1)
json.dump(graded({"cell_mode": "swept", "cell_min_mm": 2.5, "cell_max_mm": 10.0}),
          open(os.path.join(out, "job_swept_above.json"), "w"), indent=1)
json.dump(graded({"cell_mode": "auto"}, regions=slab(30.0)),
          open(os.path.join(out, "job_auto_regions.json"), "w"), indent=1)
# E — the S1 case. 0.6 mm sits between the two floors; the 1.5 mm region gives
# 1.5/2.1917 = 0.68 cells under the OLD rule (refused, under the 1.0 percolation
# floor) and 1.5/0.6 = 2.50 under the new one (runs).
json.dump(graded({"cell_mode": "swept", "cell_min_mm": 0.6, "cell_max_mm": 4.8},
                 regions=slab(1.5)),
          open(os.path.join(out, "job_swept_below.json"), "w"), indent=1)
# F — UNIFORM lattice: no grading block at all.
u = json.loads(json.dumps(base))
u["lattice"] = {"topology": "octet", "emit_stl": True, "skin": "none",
                "cell_mm": 4.0, "strut_radius_mm": 0.5,
                "min_extrudable_width_mm": W}
json.dump(u, open(os.path.join(out, "job_uniform.json"), "w"), indent=1)
# G — the ONE geometry-reaching path: multiscale reads multiscale_floor_cell_mm and
# turns it into min_feature_mm. NO regions, so the pre-flight refusal never fires and
# the job runs on BOTH sides — which is what makes a flip here a blocked-stop.
json.dump(graded({"cell_mode": "swept", "cell_min_mm": 0.6, "cell_max_mm": 4.8},
                 multiscale=True),
          open(os.path.join(out, "job_multiscale_swept.json"), "w"), indent=1)
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
  # A MISSING RUN IS A FAILURE, NOT A MATCH.
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

lattice_receipts() {
  ls "$OUT/$1"/*_lattice.report.json 2>/dev/null | wc -l | tr -d ' ' || true
}

fail=0
echo "########## A — NO LATTICE. MUST be identical. ##########"
run "$BASE_CLI" job_nolattice.json A_base > /dev/null
run "$BR_CLI"   job_nolattice.json A_branch > /dev/null
if compare A_base A_branch; then echo "  A PASS"; else echo "  A FAIL"; fail=1; fi
echo

echo "########## B — GRADED FIXED. MUST be identical. ##########"
run "$BASE_CLI" job_fixed.json B_base > /dev/null
run "$BR_CLI"   job_fixed.json B_branch > /dev/null
n=$(lattice_receipts B_base); echo "  lattice receipts emitted by the control: $n"
if [ "$n" = "0" ]; then echo "  B VACUOUS — the control emitted NO lattice."; fail=1
elif compare B_base B_branch; then echo "  B PASS"; else echo "  B FAIL"; fail=1; fi
echo

echo "########## C — GRADED SWEPT, minimum ABOVE the rho_min floor. MUST be identical. ##########"
run "$BASE_CLI" job_swept_above.json C_base > /dev/null
run "$BR_CLI"   job_swept_above.json C_branch > /dev/null
n=$(lattice_receipts C_base); echo "  lattice receipts emitted by the control: $n"
if [ "$n" = "0" ]; then echo "  C VACUOUS — the control emitted NO lattice."; fail=1
elif compare C_base C_branch; then echo "  C PASS (S1 is inert at or above the floor)"
else echo "  C FAIL"; fail=1; fi
echo

echo "########## D — GRADED AUTO WITH REGIONS. Geometry identical, TEXT different. ##########"
run "$BASE_CLI" job_auto_regions.json D_base > /dev/null
run "$BR_CLI"   job_auto_regions.json D_branch > /dev/null
n=$(lattice_receipts D_base); echo "  lattice receipts emitted by the control: $n"
if [ "$n" = "0" ]; then echo "  D VACUOUS — the control emitted NO lattice."; fail=1
elif compare D_base D_branch; then echo "  D geometry PASS"; else echo "  D geometry FAIL"; fail=1; fi
if diff -q <(grep '^\[lattice\]' "$OUT/D_base.log" || true) \
           <(grep '^\[lattice\]' "$OUT/D_branch.log" || true) >/dev/null; then
  echo "  D TEXT UNCHANGED — S3 did not reach this message. Investigate."
  fail=1
else
  echo "  D TEXT DIFFERS, as S3 intends (compared in s3_message_before_after.txt)"
fi
echo

echo "########## E — GRADED SWEPT, minimum BETWEEN the floors, thin region. DELIBERATELY DIFFERENT. ##########"
rcE1=$(run "$BASE_CLI" job_swept_below.json E_base)
rcE2=$(run "$BR_CLI"   job_swept_below.json E_branch)
echo "  base exit=$rcE1   branch exit=$rcE2"
if [ "$rcE1" != "0" ] && [ "$rcE2" = "0" ]; then
  echo "  E PASS — base REFUSED a declared 0.6 mm minimum it had silently raised to"
  echo "           2.1917 mm; branch RUNS it. That is S1, end to end."
  grep -m1 'planned lattice cell is too COARSE' "$OUT/E_base.log" | sed 's/^/    base: /' || true
  grep -m1 'cell_base_mm' "$OUT/E_branch/run_info.json" | sed 's/^/    branch: /' || true
else
  echo "  E FAIL — expected base to refuse and branch to run"
  fail=1
fi
echo

echo "########## F — UNIFORM (non-graded) LATTICE. MUST be identical. ##########"
run "$BASE_CLI" job_uniform.json F_base > /dev/null
run "$BR_CLI"   job_uniform.json F_branch > /dev/null
n=$(lattice_receipts F_base); echo "  lattice receipts emitted by the control: $n"
if [ "$n" = "0" ]; then echo "  F VACUOUS — the control emitted NO lattice."; fail=1
elif compare F_base F_branch; then echo "  F PASS"; else echo "  F FAIL"; fail=1; fi
echo

echo "########## G — SWEPT + MULTISCALE, sub-floor minimum, NO regions. ##########"
echo "  This is the ONE path on which S1 reaches GEOMETRY: multiscale_floor_cell_mm"
echo "  feeds options.min_feature_mm. A flip here is a blocked-stop, so it is measured."
rcG1=$(run "$BASE_CLI" job_multiscale_swept.json G_base)
rcG2=$(run "$BR_CLI"   job_multiscale_swept.json G_branch)
echo "  base exit=$rcG1   branch exit=$rcG2"
grep -h 'length scale' "$OUT/G_base.log"   | sed 's/^/    base:   /' || true
grep -h 'length scale' "$OUT/G_branch.log" | sed 's/^/    branch: /' || true
if [ "$rcG1" = "0" ] && [ "$rcG2" = "0" ]; then
  if compare G_base G_branch; then
    echo "  G IDENTICAL — S1 did not move this run"
  else
    echo "  G DIFFERS — REPORT THIS: S1 moved a multiscale job that runs today."
  fi
else
  echo "  G both sides refused this job (exit $rcG1 / $rcG2) — see the logs for why."
fi
echo

echo "=========================================================================="
if [ "$fail" = "0" ]; then echo "R1: PASS"; else echo "R1: FAIL"; fi
exit "$fail"
