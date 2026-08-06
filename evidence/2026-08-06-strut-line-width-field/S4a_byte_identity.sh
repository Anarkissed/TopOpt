#!/usr/bin/env bash
# S4(a) / R1 — BYTE-IDENTICAL WHERE NOTHING CHANGED, MEASURED.
#
#   BASE_REF=<commit> ./S4a_byte_identity.sh <branch-build-dir> <out-dir>
#
# Adapted from evidence/2026-08-05-lattice-cell-fit-mode/r1_byte_identity.sh,
# INCLUDING its ★ trap: the CMake target is `topopt_cli` (underscore) while the
# BINARY is `topopt-cli` (hyphen), so `--target topopt-cli` finds an existing FILE,
# declares it up to date, exits 0 and builds NOTHING. Both binaries are rebuilt here
# — base from a fresh worktree at BASE_REF, branch from the working tree — and the
# script REFUSES to compare a single artifact until it has proved they differ.
#
# ★ WHAT "NOTHING CHANGED" MEANS ON THIS TASK, PRECISELY.
#
# This task moves two things, and only one of them is inert:
#
#   S0 (the core fix) restores `lc.wall_line_width_outer_mm`. On a job whose two wall
#   beads are EQUAL, the restored value and the "mirror inner" sentinel resolve to the
#   SAME number, so nothing can move. On a job whose beads DIFFER it moves the
#   recorded outer width and the wall ring — deliberately, because that is the drop
#   being fixed.
#
#   S2 (the app change) defaults the lattice strut width to max(outer, inner). On a
#   project whose two beads are EQUAL that is the outer bead, i.e. exactly what the
#   strut floor was taking before, so the job document is unchanged. On the shipped
#   0.42 / 0.45 profile it is 0.45 instead of 0.42, and every derived cell moves ~7.1 %
#   coarser. THAT CASE IS NOT BYTE-IDENTICAL AND IS NOT CLAIMED TO BE — it is
#   enumerated in S4b_flip_table.sh.
#
# FOUR CASES:
#   A  EQUAL BEADS, no lattice          — must be byte-identical (the S0 no-op).
#   B  EQUAL BEADS, graded lattice at the equal width — must be byte-identical
#      (the S2 no-op: max(w, w) == w, so the job core receives is unchanged).
#   C  ★ POSITIVE CONTROL. DIFFERENT beads (his 0.42 / 0.45), no lattice.
#      DELIBERATELY DIFFERENT — this is the S0 fix, and if it came back identical the
#      other two cases would be proving nothing. The difference is reported key by key.
#   D  ★ POSITIVE CONTROL. The SAME graded lattice job at 0.42 vs 0.45, both run on
#      the BRANCH binary — the S2 width move, isolated from the S0 fix. Asserted to
#      differ, and the derived cell reported at each width (bar R3: every derived
#      number carries the width it was computed at).
set -euo pipefail
BUILD="$(cd "${1:?usage: S4a_byte_identity.sh <build-dir> <out-dir>}" && pwd)"
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

# --- A and C: THE WALL-WIDTH cases. They need a "loads" block, because that is where
# the two wall beads live and case C is exactly "a job that states both". This is the
# COMMITTED fixture from evidence/2026-07-28-line-width-plumbing/ (resolution 16,
# max_iterations 4, anchors on the 2.5 mm screw holes) — the same three jobs S1's
# reproduction used, so today's numbers sit beside numbers already in the repo.
def wall_job(outer, inner):
    return {"model": "l-bracket.step", "material": "PLA",
            "mode": "minimize_plastic", "resolution": 16,
            "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
                      "minimize_plastic": True, "build_dir": [0.0, 0.0, 1.0],
                      "infill_percent": 20, "wall_loops": 5,
                      "wall_line_width_mm": inner,
                      "wall_line_width_outer_mm": outer},
            "simp": {"max_iterations": 4}, "output": outp}

# --- B and D: THE STRUT-WIDTH cases. Self-weight, so `ladder` and `max_iterations`
# can be stated and the run is bounded (on the loadcase path the schema refuses both
# and the ladder runs to the MMA plateau). ONE 12 mm include region, graded `fit` —
# the fixture evidence/2026-08-05-lattice-cell-fit-mode/r6_cost.sh established as one
# where the lattice actually engages, so the comparison is not vacuous.
def strut_job(width):
    regions = [{"role": "include", "kind": "face",
                "geometry": {"origin": [0.0, 0.0, 10.0], "normal": [0.0, 0.0, 1.0],
                             "half_u_mm": 200.0, "half_w_mm": 200.0,
                             "depth_mm": 12.0}}]
    return {"model": "l-bracket.step", "material": "PLA",
            "mode": "minimize_plastic", "resolution": 40,
            "simp": {"max_iterations": 20},
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
            "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
            "ladder": [0.6], "margin_stop": 0.0,
            "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                        "min_extrudable_width_mm": width, "regions": regions},
            "grading": {"topology": "octet", "cell_mode": "fit",
                        "min_extrudable_width_mm": width},
            "output": outp}

# A — EQUAL beads (0.45 / 0.45). The S0 no-op: the restored assignment and the
#     mirror-inner sentinel resolve to the same number.
json.dump(wall_job(0.45, 0.45), open(os.path.join(out, "job_equal.json"), "w"), indent=1)
# B — a graded lattice at a fixed stated strut width, base vs branch. Nothing in core
#     changed on this path, INCLUDING the code motion that took
#     production_loadcase_from_job out of run_job.cpp's anonymous namespace.
json.dump(strut_job(0.45), open(os.path.join(out, "job_equal_lattice.json"), "w"), indent=1)
# C — DIFFERENT beads: his 0.42 outer / 0.45 inner. The S0 fix, deliberately different.
json.dump(wall_job(0.42, 0.45), open(os.path.join(out, "job_split.json"), "w"), indent=1)
# D — the S2 width move on its own: the SAME graded job at the two strut widths.
json.dump(strut_job(0.42), open(os.path.join(out, "job_lattice_042.json"), "w"), indent=1)
json.dump(strut_job(0.45), open(os.path.join(out, "job_lattice_045.json"), "w"), indent=1)
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
  for f in $(cd "$OUT/$L" && ls *_lattice.report.json 2>/dev/null | sort); do
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

# Name the run_info keys that moved, so a difference is REPORTED and not just flagged.
diff_run_info_keys() { # diff_run_info_keys <L> <R>
  python3 - "$OUT/$1/run_info.json" "$OUT/$2/run_info.json" <<'PY'
import json, sys
CLOCKS = {'created_wall_ms', 'gen_seconds', 'gen_fraction', 'preflight_ms', 'fingerprint'}
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
def walk(x, y, p=""):
    if isinstance(x, dict) and isinstance(y, dict):
        for k in sorted(set(x) | set(y)):
            if k in CLOCKS: continue
            walk(x.get(k), y.get(k), f"{p}.{k}" if p else k)
    elif isinstance(x, list) and isinstance(y, list) and len(x) == len(y):
        for i, (u, v) in enumerate(zip(x, y)): walk(u, v, f"{p}[{i}]")
    elif x != y:
        print(f"    {p}: {x!r}  ->  {y!r}")
print("  keys that moved (base -> branch), clocks excluded:")
walk(a, b)
PY
}

fail=0

echo "=== A — EQUAL BEADS (outer 0.45 mm = inner 0.45 mm), NO LATTICE ==="
echo "    the S0 no-op: restoring the assignment cannot move a job whose"
echo "    stated outer width already equals what the sentinel mirrors."
rcA1=$(run "$BASE_CLI" job_equal.json A_base)
rcA2=$(run "$BR_CLI"   job_equal.json A_branch)
echo "  exit codes: base $rcA1, branch $rcA2"
compare A_base A_branch || fail=1
echo

echo "=== B — A GRADED LATTICE at a fixed 0.45 mm stated strut width, base vs branch ==="
echo "    core's lattice path is untouched by this task, INCLUDING the code motion that"
echo "    took production_loadcase_from_job out of run_job.cpp's anonymous namespace."
echo "    The app-side S2 no-op — equal beads make max(outer, inner) the outer bead, so"
echo "    the job document is unchanged — is asserted in StrutLineWidthTests."
rcB1=$(run "$BASE_CLI" job_equal_lattice.json B_base)
rcB2=$(run "$BR_CLI"   job_equal_lattice.json B_branch)
echo "  exit codes: base $rcB1, branch $rcB2"
compare B_base B_branch || fail=1
echo

echo "=== C — ★ POSITIVE CONTROL: DIFFERENT BEADS (outer 0.42 mm, inner 0.45 mm) ==="
echo "    THIS MUST DIFFER. It is the S0 fix. If it came back identical, A and B"
echo "    would be measuring a binary that does not contain the change."
rcC1=$(run "$BASE_CLI" job_split.json C_base)
rcC2=$(run "$BR_CLI"   job_split.json C_branch)
echo "  exit codes: base $rcC1, branch $rcC2"
if compare C_base C_branch; then
  echo "  ★ CONTROL FAILED — the split-bead job is byte-identical across the fix."
  fail=1
else
  echo "  as required: the split-bead job MOVED."
fi
diff_run_info_keys C_base C_branch
echo

echo "=== D — ★ POSITIVE CONTROL: the S2 width move alone, BRANCH binary both sides ==="
echo "    the same graded job at a 0.42 mm and a 0.45 mm stated STRUT width."
rcD1=$(run "$BR_CLI" job_lattice_042.json D_042)
rcD2=$(run "$BR_CLI" job_lattice_045.json D_045)
echo "  exit codes: 0.42 mm $rcD1, 0.45 mm $rcD2"
if compare D_042 D_045; then
  echo "  ★ CONTROL FAILED — the strut width made no difference at all, so the"
  echo "    lattice cases above cannot be said to test it."
  fail=1
else
  echo "  as required: the two strut widths produce different runs."
fi
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
for sub, w in (("D_042", 0.42), ("D_045", 0.45)):
    p = os.path.join(out, sub, "run_info.json")
    if not os.path.exists(p):
        print(f"    {sub}: no run_info.json"); continue
    g = (json.load(open(p)).get("grading") or {})
    print(f"    at a {w:.2f} mm stated strut width: cell_mode {g.get('cell_mode')}  "
          f"cell_size_mm {g.get('cell_size_mm')}  "
          f"printability_floor_mm {g.get('printability_floor_mm')}  "
          f"latticed_voxels {g.get('latticed_voxels')}")
PY
echo

if [ "$fail" = 0 ]; then
  echo "R1: PASS — byte-identical where nothing changed (A, B), and both positive"
  echo "controls (C, D) moved, so the bar was not passed vacuously."
else
  echo "R1: FAIL — see above."
fi
exit $fail
