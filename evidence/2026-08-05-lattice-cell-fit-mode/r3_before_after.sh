#!/usr/bin/env bash
# R3 — THE FAILING TEST FIRST, on the maintainer's own shape.
#
#   ./r3_before_after.sh <branch-build-dir> <out-dir>
#
# THE JOB: seven include regions, each 4 mm across its thinnest dimension — his
# overnight run's geometry — declared on the demo l-bracket, GRADED, at his own
# 0.42 mm bead. Three runs of the same job:
#
#   A  BASE binary, "cell_mode": "auto"   — what he gets today.
#   B  BRANCH binary, "cell_mode": "auto" — must be IDENTICAL to A (bar S4: auto is
#      not redefined; the alias constant is at its default).
#   C  BRANCH binary, "cell_mode": "fit"  — the deliverable.
#
# WHAT "TODAY" ACTUALLY DOES, and it is worth stating precisely because it changed
# once already this week: at the stack base (PR #298) a graded AUTO job on 4 mm
# regions plans the 4.6026 mm rho_min floor, computes 0.87 cells across the region,
# and REFUSES before the solve (pre-flight case B). Before PR #298 it planned the
# same cell, ran the solve, and emitted nothing in the regions. Either way the cell
# it plans is 4.6026 mm and the lattice it puts in his regions is none.
set -euo pipefail
BUILD="$(cd "${1:?usage: r3_before_after.sh <branch-build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_REF="${BASE_REF:?set BASE_REF to the stack base commit}"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
regions = [{"role": "include", "kind": "face",
            "geometry": {"origin": [0.0, 0.0, 8.0 + 6.0 * i],
                         "normal": [0.0, 0.0, 1.0],
                         "half_u_mm": 200.0, "half_w_mm": 200.0,
                         "depth_mm": 4.0}}
           for i in range(7)]
def job(mode):
    return {
      "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
      "resolution": 48, "simp": {"max_iterations": 12},
      "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
                "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]},
      "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                  "min_extrudable_width_mm": 0.42, "regions": regions},
      "grading": {"topology": "octet", "cell_mode": mode,
                  "min_extrudable_width_mm": 0.42},
      "output": {"report": "report.json", "mesh_format": "stl",
                 "mesh_prefix": "variant"}
    }
json.dump(job("auto"), open(os.path.join(out, "job_auto.json"), "w"), indent=1)
json.dump(job("fit"),  open(os.path.join(out, "job_fit.json"),  "w"), indent=1)
PY

# ── the BASE binary, built from the stack base ────────────────────────────────────
BASE_BUILD="$OUT/.base-build"
WT="$OUT/.base-worktree"
rm -rf "$WT"
git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_wt.log" 2>&1
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
cmake -S "$WT/core" -B "$BASE_BUILD" -DCMAKE_BUILD_TYPE=Release > "$OUT/base_cfg.log" 2>&1
cmake --build "$BASE_BUILD" --target topopt_cli -j8 > "$OUT/base_build.log" 2>&1
cmake --build "$BUILD"      --target topopt_cli -j8 > "$OUT/branch_build.log" 2>&1
bs=$(shasum -a 256 "$BASE_BUILD/topopt-cli" | cut -d' ' -f1)
br=$(shasum -a 256 "$BUILD/topopt-cli"      | cut -d' ' -f1)
echo "base   cli sha256: $bs"
echo "branch cli sha256: $br"
[ "$bs" != "$br" ] || { echo "FAIL — the two CLIs are THE SAME BINARY (the silent no-op target trap)."; exit 1; }
echo

run() { # run <cli> <job> <sub>
  rm -rf "${OUT:?}/$3"
  set +e
  ( cd "$OUT" && "$1" run "$2" --out "$3" > "$3.log" 2>&1 )
  echo $?
  set -e
}

report() { # report <sub>
  python3 - "$OUT/$1" <<'PY'
import glob, json, os, sys
d = sys.argv[1]
ri = os.path.join(d, "run_info.json")
if not os.path.exists(ri):
    print("    (no run_info.json — the run did not get that far)")
    raise SystemExit
g = (json.load(open(ri)).get("grading") or {})
print(f"    cell_mode          : {g.get('cell_mode')}")
print(f"    cell_size_mm       : {g.get('cell_size_mm')}")
print(f"    printability_floor : {g.get('printability_floor_mm')}")
print(f"    region_voxels      : {g.get('region_voxels')}")
print(f"    latticed_voxels    : {g.get('latticed_voxels')}")
print(f"    solid_fallback     : {g.get('solid_fallback_voxels')}")
fit = g.get("fit")
if fit:
    print(f"    fit.min_printable_cell_mm      : {fit.get('min_printable_cell_mm')}")
    print(f"    fit.distinct_cells             : {fit.get('distinct_cells')}")
    print(f"    fit.out_of_regime_voxels       : {fit.get('out_of_regime_voxels')}")
    print(f"    fit.density_raised_for_print   : {fit.get('density_raised_for_print_voxels')}")
    for r in fit.get("regions", []):
        print("      region {region_index}: extent {extent_mm} mm -> cell {cell_mm} mm "
              "@ rho {relative_density} (strut {strut_mm} mm), {cells_per_member} cells, "
              "out_of_regime={out_of_regime}".format(**r))
for f in sorted(glob.glob(os.path.join(d, "*_lattice.report.json"))):
    j = json.load(open(f))
    print(f"    {os.path.basename(f)}: cell_mm={j.get('cell_mm')} "
          f"latticed_cells={(j.get('generation') or {}).get('latticed_cells')}")
PY
}

echo "########## A — BASE binary, cell_mode auto ##########"
rcA=$(run "$BASE_BUILD/topopt-cli" job_auto.json A_base_auto)
echo "exit code: $rcA"
grep -E "FORECAST|FIT |planned cell|refus" "$OUT/A_base_auto.log" | head -8 || true
report A_base_auto
echo

echo "########## B — BRANCH binary, cell_mode auto (must match A) ##########"
rcB=$(run "$BUILD/topopt-cli" job_auto.json B_branch_auto)
echo "exit code: $rcB"
grep -E "FORECAST|FIT |planned cell|refus" "$OUT/B_branch_auto.log" | head -8 || true
report B_branch_auto
echo

echo "########## C — BRANCH binary, cell_mode fit ##########"
rcC=$(run "$BUILD/topopt-cli" job_fit.json C_branch_fit)
echo "exit code: $rcC"
grep -E "FIT region|FIT:" "$OUT/C_branch_fit.log" | head -10 || true
report C_branch_fit
echo

fail=0
[ "$rcA" = "$rcB" ] || { echo "R3 FAIL — auto behaves differently on the branch"; fail=1; }
[ "$rcC" = "0" ]    || { echo "R3 FAIL — fit did not complete"; fail=1; }
echo "A exit=$rcA  B exit=$rcB  C exit=$rcC"
[ "$fail" = "0" ] && echo "R3 PASS — auto is unchanged and fit runs." || exit 1
