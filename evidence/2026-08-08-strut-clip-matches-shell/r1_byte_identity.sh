#!/usr/bin/env bash
# R1 — BYTE-IDENTICAL WHEN NO LATTICE IS PRESENT, MEASURED.
#
#   BASE_REF=<commit> ./r1_byte_identity.sh <branch-build-dir> <out-dir>
#
# Adapted from evidence/2026-08-06-strut-line-width-field/S4a_byte_identity.sh,
# INCLUDING its ★ trap: the CMake target is `topopt_cli` (underscore) while the
# BINARY is `topopt-cli` (hyphen), so `--target topopt-cli` finds an existing FILE,
# declares it up to date, exits 0 and builds NOTHING. Both binaries are rebuilt
# here — base from a fresh worktree at BASE_REF, branch from the working tree —
# and the script REFUSES to compare a single artifact until it has proved they
# differ.
#
# ★ WHAT "NOTHING CHANGED" MEANS ON THIS TASK, PRECISELY. The change replaces the
# lattice boundary's BASE SURFACE — the voxel-cube union becomes the exported
# shell — and adds a measurement + refusal on the latticed export. Nothing on it
# is reachable without a `lattice` block: `set_shell_base` is only called from
# `lattice_boundary_for`, and `lattice_boundary_for` is only called from
# `lattice_one_variant` and the lattice forecast. So:
#
#   A  NO LATTICE BLOCK      — must be byte-identical. This is the bar.
#   B  NO LATTICE, but a CLEARANCE keep-out AND a DESIGN BOX — must be
#      byte-identical too. Those two share the machinery the lattice path uses
#      (ClearanceGeometry; resolve_design_domain's expanded grid and remapped
#      BCs), so a change that leaked out of the lattice path would most plausibly
#      land here. It is a LOADCASE job, because that is where clearances live —
#      which is why `ladder`, `margin_stop`, `fixture_faces` and `gravity` are
#      absent: the schema refuses all four alongside "loads".
#   C  ★ POSITIVE CONTROL. A graded lattice job. It MUST DIFFER — if it came back
#      identical, the fix is not reaching the export at all and A and B would be
#      proving nothing about a change that never happened.
set -euo pipefail
BUILD="$(cd "${1:?usage: r1_byte_identity.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_REF="${BASE_REF:?set BASE_REF to the merge-base of this branch with main}"
BASE_BUILD="$OUT/.base-build"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
outp = {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}

# A — NO LATTICE. Self-weight, a bounded ladder, resolution 40: the same shape of
# fixture the cell-fit and line-width tasks used, so today's numbers sit beside
# numbers already in the repo.
def base_job():
    return {"model": "l-bracket.step", "material": "PLA",
            "mode": "minimize_plastic", "resolution": 40,
            "simp": {"max_iterations": 20},
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
            "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
            "ladder": [0.6], "margin_stop": 0.0, "output": outp}

# B — NO LATTICE, but with a CLEARANCE keep-out and a design box: the two features
# that share machinery with the lattice path.
def clearance_box_job():
    # A LOADCASE job: the anchors are the fixtures and the groups are the design
    # load, so `ladder`, `margin_stop`, `fixture_faces` and `gravity` are all
    # refused here by the schema and must come off. `simp.max_iterations` bounds
    # the run instead.
    # Resolution 24 and 4 iterations: a loadcase job runs the PRODUCTION
    # four-rung ladder (the schema refuses "ladder"/"margin_stop" here), and a
    # design box EXPANDS the grid on top of that, so the full-resolution version
    # of this case costs about an hour per binary. Byte-identity does not need a
    # converged design — it needs the same arithmetic on both sides — so this is
    # sized to exercise the clearance + expanded-domain machinery and stop.
    j = {"model": "l-bracket.step", "material": "PLA",
         "mode": "minimize_plastic", "resolution": 24,
         "simp": {"max_iterations": 4}, "output": outp,
         "loads": {"minimize_plastic": True, "build_dir": [0.0, 0.0, 1.0],
                   "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
                   # A MANUAL primitive is spelled as a "geometry" object; the
                   # schema takes exactly one of "face_id" or "geometry" and has
                   # no "manual" key of its own.
                   "clearances": [{"kind": "bolt",
                                   "geometry": {"axis_point": [0.0, 0.0, 0.0],
                                                "axis_dir": [0.0, 0.0, 1.0],
                                                "radius_mm": 3.0,
                                                "half_length_mm": 20.0}}]},
         # A DESIGN BOX as well: it puts the run on the EXPANDED domain, which is
         # the other machinery the lattice path shares (resolve_design_domain,
         # the remapped BCs, the added-material accounting).
         "design_box": {"min": [-30.0, -30.0, -2.0],
                        "max": [30.0, 30.0, 30.0]}}
    return j

# C — ★ POSITIVE CONTROL: a graded lattice on one 12 mm include region, the
# fixture evidence/2026-08-05-lattice-cell-fit-mode/r6_cost.sh established as one
# where the lattice actually engages.
def lattice_job():
    j = base_job()
    regions = [{"role": "include", "kind": "face",
                "geometry": {"origin": [0.0, 0.0, 10.0], "normal": [0.0, 0.0, 1.0],
                             "half_u_mm": 200.0, "half_w_mm": 200.0,
                             "depth_mm": 12.0}}]
    j["lattice"] = {"topology": "octet", "emit_stl": True, "skin": "none",
                    "min_extrudable_width_mm": 0.45, "regions": regions}
    j["grading"] = {"topology": "octet", "cell_mode": "fit",
                    "min_extrudable_width_mm": 0.45}
    return j

json.dump(base_job(),          open(os.path.join(out, "job_a_nolattice.json"), "w"), indent=1)
json.dump(clearance_box_job(), open(os.path.join(out, "job_b_clearance.json"), "w"), indent=1)
json.dump(lattice_job(),       open(os.path.join(out, "job_c_lattice.json"), "w"), indent=1)
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
echo "branch HEAD : $(git -C "$REPO" rev-parse HEAD)"
echo "base   cli sha256: $bs"
echo "branch cli sha256: $br"
[ "$bs" != "$br" ] || { echo; echo "R1 FAIL — the two CLIs are THE SAME BINARY (the silent no-op target trap)."; exit 1; }
echo "the two binaries differ, as they must for this bar to mean anything."
echo

run() { # run <cli> <job> <sub>
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

compare() { # compare <L> <R> -> 0 identical, 1 differs
  local L="$1" R="$2" bad=0 f a b meshes
  # A MISSING RUN IS A FAILURE, NOT A MATCH. Without this a run that never started
  # compares two empty directories and reports IDENTICAL for everything.
  if [ ! -d "$OUT/$L" ] || [ ! -d "$OUT/$R" ]; then
    echo "  MISSING    $L or $R never produced a run directory (see $L.log / $R.log)"
    return 1
  fi
  meshes=$(cd "$OUT/$L" && ls variant_*.stl 2>/dev/null | sort)
  for f in report.json fields.bin design.bin $meshes; do
    [ -f "$OUT/$L/$f" ] || continue
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" 2>/dev/null | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "  IDENTICAL  $f  ${a:0:16}…"
    else echo "  DIFFERS    $f"; bad=1; fi
  done
  for f in $(cd "$OUT/$L" && ls *_lattice.report.json *_lattice.stl 2>/dev/null | sort); do
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" 2>/dev/null | cut -d' ' -f1)
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
  return $bad
}

fail=0
for c in a_nolattice b_clearance; do
  echo "=== CASE ${c} — must be BYTE-IDENTICAL ==="
  rcb=$(run "$BASE_CLI" "job_${c}.json" "base_${c}")
  rcn=$(run "$BR_CLI"   "job_${c}.json" "branch_${c}")
  echo "  exit codes: base=$rcb branch=$rcn"
  if compare "base_${c}" "branch_${c}"; then
    echo "  => R1 HOLDS for case ${c}"
  else
    echo "  => ★ R1 FAILS for case ${c}"; fail=1
  fi
  echo
done

echo "=== CASE c_lattice — ★ POSITIVE CONTROL, must DIFFER ==="
rcb=$(run "$BASE_CLI" "job_c_lattice.json" "base_c_lattice")
rcn=$(run "$BR_CLI"   "job_c_lattice.json" "branch_c_lattice")
echo "  exit codes: base=$rcb branch=$rcn"
if compare "base_c_lattice" "branch_c_lattice"; then
  echo "  => ★ CONTROL FAILED — the latticed run is IDENTICAL, so the fix is not"
  echo "     reaching the export and the cases above prove nothing."
  fail=1
else
  echo "  => control holds: the latticed run MOVED, which is the fix landing."
fi
echo
echo "R1 overall: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
