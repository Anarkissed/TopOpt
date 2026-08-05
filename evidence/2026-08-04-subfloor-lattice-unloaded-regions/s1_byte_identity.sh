#!/usr/bin/env bash
# S1 — WHAT IS BYTE-IDENTICAL, AND WHAT DELIBERATELY IS NOT.
# (task 2026-08-04-subfloor-lattice-unloaded-regions)
#
#   ./s1_byte_identity.sh <branch-build-dir> <base-build-dir> <out-dir>
#
# This PR contains TWO changes with DIFFERENT byte-identity properties. Collapsing
# them into one "is it identical?" question would hide the second, so this bar asks
# three separate questions and states the answer to each.
#
#   A. NO LATTICE AT ALL, base vs branch.
#      Must be BYTE-IDENTICAL. Nothing here may touch a run that does not lattice.
#      HARD ASSERTION.
#
#   B. GRADED LATTICE, ARMED vs NOT, on the SAME binary — the FLAG's own bar, and
#      the one that matters most. Split in two, because "identical" means different
#      things depending on whether the option actually fires:
#
#      B1 ARMED BUT INERT (no qualifying region). Everything must match EXCEPT the
#         `subfloor_retention` reporting block the receipt gains — which MUST
#         differ, or the user could not tell the option was on. The block is
#         stripped and the rest compared; the block itself is then asserted to
#         report `voxels_retained: 0`. HARD ASSERTION.
#
#      B2 ARMED AND FIRING. The lattice artifacts SHOULD change — that is the
#         feature. What must NOT change is the SOLID ladder: report.json,
#         design.bin, fields.bin and every solid mesh must be bit-identical,
#         because a rung's optimize may not depend on whether the previous rung's
#         lattice was retained. This is the property the §7 leak broke and the
#         scoped solver-state guard restores. HARD ASSERTION.
#
#   C. GRADED LATTICE, base vs branch.
#      DELIBERATELY DIFFERENT, reported rather than asserted away. The PR also
#      closes a solver-state leak (handoff §7): on the STREAMING path the lattice
#      pipeline runs FEA solves BETWEEN rungs, and those solves were harvesting
#      into — and dropping — the Krylov recycle subspace and the GenEO basis that
#      the NEXT rung's optimize consumes. Closing that necessarily moves the
#      designs of rungs after the first latticed one, on every streaming lattice
#      run, opted in or not. That is the fix working, not a regression.
#      WHAT IS ASSERTED: no verdict may flip.
#
# B is what makes the feature safe to ship. C is the price of fixing a defect the
# feature exposed. A proves the blast radius stops at lattice runs.
#
# ★ THE TRAP THIS SCRIPT GUARDS AGAINST, because it caught this task once already.
# The CMake target is `topopt_cli` (underscore); the BINARY it produces is
# `topopt-cli` (hyphen), and it sits in the build directory. So
# `cmake --build <dir> --target topopt-cli` finds an existing FILE by that name,
# declares it up to date, EXITS 0, and builds nothing. The first run of this bar
# did exactly that: base and branch were the same binary, every checksum matched,
# and the bar "passed" while proving only that the code is deterministic. So the
# script asserts the two binaries DIFFER before it compares a single artifact.
set -euo pipefail

BUILD="${1:?usage: s1_byte_identity.sh <branch-build-dir> <base-build-dir> <out-dir>}"
BASE_BUILD="${2:?}"
OUT="${3:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="$REPO/core/tests/fixtures/demo"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"

cat > "$OUT/job_nolattice.json" <<'JSON'
{
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 48, "simp": {"max_iterations": 14},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]
  },
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON

cat > "$OUT/job_lattice.json" <<'JSON'
{
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 48, "simp": {"max_iterations": 14},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]
  },
  "lattice": {"topology": "octet", "emit_stl": true, "skin": "rim",
              "min_extrudable_width_mm": 0.42},
  "grading": {"topology": "octet", "cell_mode": "swept", "cell_min_mm": 3.0,
              "cell_max_mm": 12.0, "min_extrudable_width_mm": 0.42},
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
d = json.load(open(os.path.join(out, "job_lattice.json")))
d["grading"]["retain_subfloor_in_unloaded_regions"] = True
json.dump(d, open(os.path.join(out, "job_lattice_armed.json"), "w"), indent=1)

# B2's pair: a region that QUALIFIES and material that is genuinely sub-floor, so
# retention actually fires. The region is the top 8 mm slab — measured on this
# part's own field at ~0.021 of peak — and the 4-16 mm ladder makes every voxel in
# it fail the cells-per-member floor. (The slab runs from `origin` ALONG +normal,
# so the normal points DOWN to take the TOP of the part; pointing it up put the
# region outside the part entirely and it came back empty.)
q = json.load(open(os.path.join(out, "job_lattice.json")))
q["lattice"]["regions"] = [{"role": "include", "kind": "face",
    "geometry": {"origin": [0.0, 0.0, 60.0], "normal": [0.0, 0.0, -1.0],
                 "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": 8.0}}]
q["grading"]["cell_min_mm"] = 4.0
q["grading"]["cell_max_mm"] = 16.0
json.dump(q, open(os.path.join(out, "job_fire.json"), "w"), indent=1)
q2 = json.loads(json.dumps(q))
q2["grading"]["retain_subfloor_in_unloaded_regions"] = True
json.dump(q2, open(os.path.join(out, "job_fire_armed.json"), "w"), indent=1)
PY

run() {  # run <cli> <job> <subdir>
  local cli="$1" job="$2" sub="$3"
  rm -rf "${OUT:?}/$sub"
  ( cd "$OUT" && "$cli" run "$job" --out "$sub" > "$sub.log" 2>&1 ) || {
    echo "RUN FAILED ($sub) — tail of log:"; tail -30 "$OUT/$sub.log"; exit 1; }
}

echo "=== S1 — three questions, three different answers ==="
echo "branch build: $BUILD"
echo "base   build: $BASE_BUILD"
echo

# ── PRODUCING THE BASE BINARY. Two ways, because the branch's state decides which
# is honest:
#   UNCOMMITTED work -> STASH-REBUILD, the form the bar names.
#   COMMITTED work   -> `git stash` has nothing to take, and stashing a clean tree
#     would build the BRANCH twice and "pass" vacuously. The base is then built
#     from a detached worktree at BASE_REF (default origin/main).
BASE_REF="${BASE_REF:-origin/main}"
if git -C "$REPO" diff --quiet -- core app && \
   git -C "$REPO" diff --cached --quiet -- core app; then
  echo "--- tree is clean: building BASE from $BASE_REF in a detached worktree ---"
  WT="$OUT/.base-worktree"
  rm -rf "$WT"
  git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_worktree.log" 2>&1 \
    || { echo "WORKTREE FAILED"; cat "$OUT/base_worktree.log"; exit 1; }
  trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
  cmake -S "$WT/core" -B "$BASE_BUILD" -DCMAKE_BUILD_TYPE=Release \
    > "$OUT/base_cfg.log" 2>&1 || { echo "BASE CONFIGURE FAILED"; tail -20 "$OUT/base_cfg.log"; exit 1; }
  git -C "$REPO" rev-parse "$BASE_REF" > "$OUT/base_commit.txt"
else
  echo "--- stashing the branch and rebuilding BASE (target: topopt_cli) ---"
  git -C "$REPO" stash push --quiet --message "s1-byte-identity" -- core app
  trap 'echo "restoring branch..."; git -C "$REPO" stash pop --quiet || true' EXIT
  git -C "$REPO" rev-parse HEAD > "$OUT/base_commit.txt"
fi
cmake --build "$BASE_BUILD" --target topopt_cli -j8 > "$OUT/base_build.log" 2>&1 \
  || { echo "BASE BUILD FAILED"; tail -30 "$OUT/base_build.log"; exit 1; }
if ! git -C "$REPO" diff --quiet -- core app; then
  git -C "$REPO" stash pop --quiet || true
fi
# The base worktree STAYS until the runs are done: topopt-cli bakes its default
# materials.json path in at compile time, so a binary built from the worktree
# cannot run once the worktree is gone. The EXIT trap removes it either way.
cmake --build "$BUILD" --target topopt_cli -j8 > "$OUT/branch_build.log" 2>&1 \
  || { echo "BRANCH BUILD FAILED"; tail -30 "$OUT/branch_build.log"; exit 1; }

BASE_CLI="$BASE_BUILD/topopt-cli"
BRANCH_CLI="$BUILD/topopt-cli"
bs=$(shasum -a 256 "$BASE_CLI"   | cut -d' ' -f1)
br=$(shasum -a 256 "$BRANCH_CLI" | cut -d' ' -f1)
echo "base   cli sha256: $bs"
echo "branch cli sha256: $br"
if [ "$bs" = "$br" ]; then
  echo; echo "S1 FAIL — the two CLIs are THE SAME BINARY. Nothing below would be"
  echo "          evidence of anything (the silent-no-op target trap)."
  exit 1
fi
echo "the two binaries differ, as they must for this bar to mean anything."
echo

run "$BASE_CLI"   job_nolattice.json      A_base
run "$BRANCH_CLI" job_nolattice.json      A_branch
run "$BRANCH_CLI" job_lattice.json        B_off
run "$BRANCH_CLI" job_lattice_armed.json  B_on
run "$BASE_CLI"   job_lattice.json        C_base
run "$BRANCH_CLI" job_fire.json           D_off
run "$BRANCH_CLI" job_fire_armed.json     D_on

# THE CLOCK-BEARING KEYS, named one by one rather than pattern-matched, because
# "we dropped the keys that differed" is exactly the move that hides a regression.
# Each is a WALL-CLOCK reading and none is physics: created_wall_ms (run start),
# gen_seconds (lattice generation wall time), gen_fraction (that over total wall
# time), preflight_ms (pre-flight reachability wall time).
#
# AND ONE KEY THAT IS NOT A CLOCK, excluded ONLY in the cross-binary comparisons:
# `fingerprint`, the GIT COMMIT the binary was built from. Those comparisons BEGIN
# by asserting the two binaries differ, so a build-provenance stamp is guaranteed
# to differ — comparing it would make the bar impossible to pass rather than
# meaningful to fail. In the SAME-binary comparison (B) it is compared verbatim,
# where it must match.
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

# Strip the `subfloor_retention` reporting block from a receipt. Used ONLY where
# the two sides differ in whether the option was ARMED: the block is exactly what
# arming adds, and a receipt that hid it would leave the user unable to tell the
# option was on. Everything else in the document is still compared verbatim.
strip_block() {
  python3 -c "
import json,sys
def scrub(x):
    if isinstance(x, dict): return {k: scrub(v) for k, v in x.items() if k != 'subfloor_retention'}
    if isinstance(x, list): return [scrub(v) for v in x]
    return x
print(json.dumps(scrub(json.load(open(sys.argv[1]))), sort_keys=True, indent=1))" "$1"
}

compare() {  # compare <dirL> <dirR> <crossbinary|samebinary> [stripblock]  -> 0 identical
  local L="$1" R="$2" mode="$3" strip="${4:-}" bad=0 meshes f a b
  meshes=$(cd "$OUT/$L" && ls variant_*.stl 2>/dev/null | sort)
  for f in report.json fields.bin design.bin $meshes; do
    [ -f "$OUT/$L/$f" ] || continue
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
    else echo "DIFFERS    $f"; bad=1; fi
  done
  for f in $(cd "$OUT/$L" && ls *_lattice.report.json 2>/dev/null | sort); do
    if [ "$strip" = "stripblock" ]; then
      if diff -q <(strip_block "$OUT/$L/$f") <(strip_block "$OUT/$R/$f") > /dev/null; then
        echo "IDENTICAL  $f (minus the subfloor_retention block)"
      else echo "DIFFERS    $f beyond the subfloor_retention block"; bad=1; fi
    else
      a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
      b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
      if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
      else echo "DIFFERS    $f"; bad=1; fi
    fi
  done
  local ril rir
  if [ "$strip" = "stripblock" ]; then
    # RECURSIVE: run_info carries the block NESTED inside its `grading` object,
    # so a top-level pop silently strips nothing — which is exactly how the first
    # version of this comparison reported a difference it had already excluded.
    local scrub="
import json,sys
def scrub(x):
    if isinstance(x, dict): return {k: scrub(v) for k, v in x.items() if k != 'subfloor_retention'}
    if isinstance(x, list): return [scrub(v) for v in x]
    return x
print(json.dumps(scrub(json.load(sys.stdin)), sort_keys=True, indent=1))"
    ril=$(strip_run_info "$OUT/$L/run_info.json" "$mode" | python3 -c "$scrub")
    rir=$(strip_run_info "$OUT/$R/run_info.json" "$mode" | python3 -c "$scrub")
  else
    ril=$(strip_run_info "$OUT/$L/run_info.json" "$mode")
    rir=$(strip_run_info "$OUT/$R/run_info.json" "$mode")
  fi
  if [ "$ril" = "$rir" ]; then
    echo "IDENTICAL  run_info.json (minus the named clock keys)"
  else echo "DIFFERS    run_info.json beyond the clocks"; bad=1; fi
  if diff -q <(strip_iters "$OUT/$L/iterations.csv") \
             <(strip_iters "$OUT/$R/iterations.csv") > /dev/null; then
    echo "IDENTICAL  iterations.csv (physics columns)"
  else echo "DIFFERS    iterations.csv in a physics column"; bad=1; fi
  return $bad
}

fail=0

echo "########## A — NO LATTICE, base vs branch. MUST be identical. ##########"
if compare A_base A_branch crossbinary; then echo; echo "A PASS"
else echo; echo "A FAIL — this PR changed a run that does not lattice."; fail=1; fi
echo

echo "########## B1 — LATTICE, ARMED but INERT, same binary. ##########"
echo "No qualifying region, so retention is armed and retains nothing. Everything"
echo "must match EXCEPT the subfloor_retention block the receipt gains — which MUST"
echo "differ, or the user could not tell the option was on."
if compare B_off B_on samebinary stripblock; then echo; echo "B1 PASS"
else echo; echo "B1 FAIL — arming changed something other than the reporting block."; fail=1; fi
python3 - "$OUT/B_on" <<'PY2' || fail=1
import glob, json, os, sys
d = sys.argv[1]
bad = False
for f in sorted(glob.glob(os.path.join(d, "*_lattice.report.json"))):
    s = (json.load(open(f)).get("grading") or {}).get("subfloor_retention") or {}
    ok = s.get("armed") is True and s.get("voxels_retained") == 0
    print(f"  {os.path.basename(f)}: armed={s.get('armed')} "
          f"qualified={s.get('region_qualified')} "
          f"measured={s.get('region_stress_fraction_measured')} "
          f"retained={s.get('voxels_retained')}  {'ok' if ok else 'UNEXPECTED'}")
    bad = bad or not ok
print("  the block is present and reports ZERO retention, as it must here."
      if not bad else "  UNEXPECTED: this job should retain nothing.")
sys.exit(1 if bad else 0)
PY2
echo

echo "########## B2 — LATTICE, ARMED and FIRING, same binary. ##########"
echo "A qualifying region with genuinely sub-floor material, so retention fires."
echo "The LATTICE artifacts should change — that is the feature. The SOLID LADDER"
echo "must NOT: a rung's optimize may not depend on whether the previous rung's"
echo "lattice was retained. This is exactly what the §7 leak broke."
d2fail=0
for f in report.json design.bin fields.bin $(cd "$OUT/D_off" && ls variant_*.stl 2>/dev/null | grep -v _lattice | sort); do
  a=$(shasum -a 256 "$OUT/D_off/$f" | cut -d' ' -f1)
  b=$(shasum -a 256 "$OUT/D_on/$f"  | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
  else echo "DIFFERS    $f   *** THE LADDER MOVED — the leak is not closed ***"; d2fail=1; fi
done
python3 - "$OUT/D_on" <<'PY3' || d2fail=1
import glob, json, os, sys
tot = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*_lattice.report.json"))):
    s = (json.load(open(f)).get("grading") or {}).get("subfloor_retention") or {}
    tot += s.get("voxels_retained") or 0
    print(f"  {os.path.basename(f)}: measured="
          f"{s.get('region_stress_fraction_measured'):.4f} "
          f"qualified={s.get('region_qualified')} "
          f"retained={s.get('voxels_retained')} of {s.get('voxels_below_floor')}")
print(f"  total retained across the run: {tot}")
if tot == 0:
    print("  UNEXPECTED: retention did not fire, so B2 tested nothing.")
sys.exit(1 if tot == 0 else 0)
PY3
if [ "$d2fail" = "0" ]; then echo; echo "B2 PASS — retention fired and the solid ladder did not move."
else echo; echo "B2 FAIL — this is the blocking one."; fail=1; fi
echo

echo "########## C — LATTICE, base vs branch. DELIBERATELY DIFFERENT. ##########"
echo "The PR closes a solver-state leak: on the streaming path the lattice"
echo "pipeline's FEA solves were polluting the Krylov recycle subspace and the"
echo "GenEO basis the NEXT rung's optimize consumes. Closing it moves the designs"
echo "of rungs after the first latticed one. Reported, not asserted away."
echo "WHAT IS ASSERTED: no verdict may flip."
compare C_base B_off crossbinary || true
echo
python3 - "$OUT/C_base/report.json" "$OUT/B_off/report.json" <<'PY' || fail=1
import json, sys
def rows(p):
    r = json.load(open(p))
    vs = list(r.get('variants') or []) + list(r.get('rejected_variants') or [])
    return {round(v['volume_fraction'], 4):
            (v['margin']['worst_case'], bool(v['accepted'])) for v in vs}
a, b = rows(sys.argv[1]), rows(sys.argv[2])
print(f"{'rung':>7} {'margin base':>15} {'margin branch':>15} {'d':>11}  verdict")
flip = False
for k in sorted(a, reverse=True):
    ma, va = a[k]; mb, vb = b[k]
    d = 100.0 * (mb - ma) / ma if ma else 0.0
    mark = ""
    if va != vb:
        mark = "  *** VERDICT FLIP — BLOCKED-STOP ***"; flip = True
    print(f"{k:>7.2f} {ma:>15.6f} {mb:>15.6f} {d:>+10.4f}%  {va}->{vb}{mark}")
print()
print("C " + ("FAIL — a verdict flipped." if flip else
      "PASS — designs moved (that is the leak fix), NO verdict flipped."))
sys.exit(1 if flip else 0)
PY
echo

if [ "$fail" = "0" ]; then
  echo "S1 PASS — a run with no lattice is byte-identical (A); arming retention"
  echo "          changes nothing but its own reporting block when inert (B1) and"
  echo "          does not move the solid ladder when it FIRES (B2); and the leak"
  echo "          fix's deliberate movement on lattice runs flips no verdict (C)."
  exit 0
fi
echo "S1 FAIL."
exit 1
