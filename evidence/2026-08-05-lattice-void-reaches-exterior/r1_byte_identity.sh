#!/usr/bin/env bash
# R1 — BYTE-IDENTICAL WHEN OFF, by stash-rebuild checksum.
# (task 2026-08-05-lattice-void-reaches-exterior)
#
#   ./r1_byte_identity.sh <branch-build-dir> <base-build-dir> <out-dir>
#
# "By construction" is not the bar. The option defaults false; this proves the
# DEFAULT PATH IS UNTOUCHED by comparing artifacts from two SEPARATELY BUILT
# binaries — base (this branch stashed / origin-main worktree) and branch.
#
# TWO JOBS, both with the option ABSENT:
#   A  NO LATTICE AT ALL. The blast radius must not even reach a lattice run.
#   B  A LATTICE RUN WITH ROLE REGIONS — the shape the check actually inspects.
#      Every artifact must match: report.json, design.bin, fields.bin, every
#      solid mesh, every latticed mesh, every per-variant lattice receipt,
#      run_info.json (minus the named clock keys) and iterations.csv.
#
# And one job with the option ARMED, on the BRANCH binary only, asserting the
# only thing that may differ is the void_escape block the receipt gains. If
# arming changed anything else, "off is identical" would be true and useless.
#
# ★ THE TRAP THIS SCRIPT GUARDS AGAINST (it has bitten this project more than
# once). The CMake target is `topopt_cli` (underscore); the BINARY it produces is
# `topopt-cli` (hyphen), and it sits in the build directory. So
# `cmake --build <dir> --target topopt-cli` finds an existing FILE by that name,
# declares it up to date, EXITS 0, and builds nothing — base and branch end up
# being the same binary, every checksum matches, and the bar "passes" while
# proving only that the code is deterministic. The script therefore asserts the
# two binaries DIFFER before it compares a single artifact.
set -euo pipefail

BUILD="${1:?usage: r1_byte_identity.sh <branch-build-dir> <base-build-dir> <out-dir>}"
BASE_BUILD="${2:?}"
OUT="${3:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="$REPO/core/tests/fixtures/demo"
CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release
            -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/eigen\;/opt/homebrew/opt/opencascade)

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
  "lattice": {"topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
              "emit_stl": true, "skin": "rim",
              "regions": [{"role": "include", "kind": "face",
                           "geometry": {"origin": [-5.0, 0.0, 6.0],
                                        "normal": [0.0, 0.0, -1.0],
                                        "half_u_mm": 8.0, "half_w_mm": 40.0,
                                        "depth_mm": 3.0}}]},
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
d = json.load(open(os.path.join(out, "job_lattice.json")))
d["lattice"]["require_lattice_void_reaches_exterior"] = True
json.dump(d, open(os.path.join(out, "job_lattice_armed.json"), "w"), indent=1)
PY

run() {  # run <cli> <job> <subdir>
  local cli="$1" job="$2" sub="$3"
  rm -rf "${OUT:?}/$sub"
  ( cd "$OUT" && "$cli" run "$job" --out "$sub" > "$sub.log" 2>&1 ) || {
    echo "RUN FAILED ($sub) — tail of log:"; tail -30 "$OUT/$sub.log"; exit 1; }
}

echo "=== R1 — byte-identity when the option is OFF ==="
echo "branch build: $BUILD"
echo "base   build: $BASE_BUILD"
echo

# PRODUCING THE BASE BINARY. Two ways, because the branch's state decides which
# is honest:
#   UNCOMMITTED work -> STASH-REBUILD, the form the bar names.
#   COMMITTED work   -> `git stash` has nothing to take, and stashing a clean
#     tree would build the BRANCH twice and "pass" vacuously. The base is then
#     built from a detached worktree at BASE_REF (default origin/main).
BASE_REF="${BASE_REF:-origin/main}"
if git -C "$REPO" diff --quiet -- core app && \
   git -C "$REPO" diff --cached --quiet -- core app; then
  echo "--- tree is clean: building BASE from $BASE_REF in a detached worktree ---"
  WT="$OUT/.base-worktree"
  rm -rf "$WT"
  git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_worktree.log" 2>&1 \
    || { echo "WORKTREE FAILED"; cat "$OUT/base_worktree.log"; exit 1; }
  trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
  cmake -S "$WT/core" -B "$BASE_BUILD" "${CMAKE_ARGS[@]}" \
    > "$OUT/base_cfg.log" 2>&1 || { echo "BASE CONFIGURE FAILED"; tail -20 "$OUT/base_cfg.log"; exit 1; }
  git -C "$REPO" rev-parse "$BASE_REF" > "$OUT/base_commit.txt"
else
  # ★ THE SECOND TRAP, and this one bit the first run of this bar. `git stash`
  # leaves the tree CLEAN, so a "pop it back if the tree is dirty" test after the
  # base build is FALSE — the branch build then compiles the STASHED (= base)
  # tree and both binaries come out byte-identical. The sha guard below caught
  # it, which is exactly what it is for. The stash is now popped
  # UNCONDITIONALLY, by a flag, before the branch is built.
  echo "--- stashing the branch and rebuilding BASE (target: topopt_cli) ---"
  git -C "$REPO" stash push --quiet --message "r1-byte-identity" -- core app
  STASHED=1
  trap '[ "${STASHED:-0}" = "1" ] && { echo "restoring branch..."; \
        git -C "$REPO" stash pop --quiet || true; }' EXIT
  git -C "$REPO" rev-parse HEAD > "$OUT/base_commit.txt"
  cmake -S "$REPO/core" -B "$BASE_BUILD" "${CMAKE_ARGS[@]}" \
    > "$OUT/base_cfg.log" 2>&1 || { echo "BASE CONFIGURE FAILED"; tail -20 "$OUT/base_cfg.log"; exit 1; }
fi
cmake --build "$BASE_BUILD" --target topopt_cli -j8 > "$OUT/base_build.log" 2>&1 \
  || { echo "BASE BUILD FAILED"; tail -30 "$OUT/base_build.log"; exit 1; }
if [ "${STASHED:-0}" = "1" ]; then
  git -C "$REPO" stash pop --quiet
  STASHED=0
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
  echo; echo "R1 FAIL — the two CLIs are THE SAME BINARY. Nothing below would be"
  echo "          evidence of anything (the silent-no-op target trap)."
  exit 1
fi
echo "the two binaries differ, as they must for this bar to mean anything."
echo

run "$BASE_CLI"   job_nolattice.json     A_base
run "$BRANCH_CLI" job_nolattice.json     A_branch
run "$BASE_CLI"   job_lattice.json       B_base
run "$BRANCH_CLI" job_lattice.json       B_branch
run "$BRANCH_CLI" job_lattice_armed.json C_armed

# THE CLOCK-BEARING KEYS, named one by one rather than pattern-matched, because
# "we dropped the keys that differed" is exactly the move that hides a
# regression. Each is a WALL-CLOCK reading and none is physics.
# AND ONE KEY THAT IS NOT A CLOCK, excluded ONLY in the cross-binary
# comparisons: `fingerprint`, the GIT COMMIT the binary was built from. Those
# comparisons BEGIN by asserting the two binaries differ, so a build-provenance
# stamp is guaranteed to differ.
strip_run_info() {
  python3 -c "
import json,sys
CLOCKS={'created_wall_ms','gen_seconds','gen_fraction','preflight_ms','wall_seconds'}
if len(sys.argv)>2 and sys.argv[2]=='crossbinary': CLOCKS.add('fingerprint')
def scrub(x):
    if isinstance(x, dict): return {k: scrub(v) for k, v in x.items() if k not in CLOCKS}
    if isinstance(x, list): return [scrub(v) for v in x]
    return x
print(json.dumps(scrub(json.load(open(sys.argv[1]))), sort_keys=True, indent=1))" "$1" "${2:-}"
}
strip_iters() { cut -d, -f1,2,4-13 "$1"; }

compare() {  # compare <dirL> <dirR> <crossbinary|samebinary>  -> 0 identical
  local L="$1" R="$2" mode="$3" bad=0 f a b meshes
  meshes=$(cd "$OUT/$L" && ls variant_*.stl 2>/dev/null | sort)
  for f in report.json fields.bin design.bin $meshes; do
    [ -f "$OUT/$L/$f" ] || continue
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
    else echo "DIFFERS    $f"; bad=1; fi
  done
  for f in $(cd "$OUT/$L" && ls *_lattice.report.json 2>/dev/null | sort); do
    a=$(shasum -a 256 "$OUT/$L/$f" | cut -d' ' -f1)
    b=$(shasum -a 256 "$OUT/$R/$f" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
    else echo "DIFFERS    $f"; bad=1; fi
  done
  if [ "$(strip_run_info "$OUT/$L/run_info.json" "$mode")" = \
       "$(strip_run_info "$OUT/$R/run_info.json" "$mode")" ]; then
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

echo "########## B — LATTICE + ROLE REGIONS, option OFF, base vs branch. ##########"
echo "The exact shape the check inspects, with the check not armed. MUST be"
echo "identical: the default path may not move by one byte."
if compare B_base B_branch crossbinary; then echo; echo "B PASS"
else echo; echo "B FAIL — the default lattice path moved."; fail=1; fi
echo

echo "########## C — SAME BINARY, ARMED vs NOT. ##########"
echo "The only thing that may change is the void_escape record the documents"
echo "GAIN — and it must change, or the user could not tell the check was on."
python3 - "$OUT/B_branch" "$OUT/C_armed" <<'PY' || fail=1
import glob, hashlib, json, os, sys
L, R = sys.argv[1], sys.argv[2]
def sha(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()
def scrub(x):
    if isinstance(x, dict):
        return {k: scrub(v) for k, v in x.items()
                if k not in ('void_escape', 'created_wall_ms', 'gen_seconds',
                             'gen_fraction', 'preflight_ms')}
    if isinstance(x, list): return [scrub(v) for v in x]
    return x
bad = False
names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(L, "variant_*.stl")))
for f in ["report.json", "design.bin", "fields.bin"] + names:
    a, b = os.path.join(L, f), os.path.join(R, f)
    if not (os.path.exists(a) and os.path.exists(b)):
        print(f"  MISSING    {f}"); bad = True; continue
    if sha(a) == sha(b): print(f"  IDENTICAL  {f}")
    else: print(f"  DIFFERS    {f}  *** arming changed the geometry ***"); bad = True
for f in sorted(os.path.basename(p) for p in
                glob.glob(os.path.join(L, "*_lattice.report.json"))):
    la = json.load(open(os.path.join(L, f)))
    ra = json.load(open(os.path.join(R, f)))
    if "void_escape" in la:
        print(f"  UNEXPECTED {f}: the UN-ARMED receipt carries void_escape"); bad = True
    if "void_escape" not in ra:
        print(f"  MISSING    {f}: the ARMED receipt carries NO void_escape — the "
              f"user could not tell the check ran"); bad = True
    else:
        v = ra["void_escape"]
        print(f"  {f} void_escape: ran={v['ran']} sealed={v['sealed']} "
              f"reached={v['latticed_voxels_reached']} "
              f"faces={v['escape_faces']} bfs_visits={v['bfs_visits']} "
              f"wall_seconds={v['wall_seconds']}")
    if json.dumps(scrub(la), sort_keys=True) == json.dumps(scrub(ra), sort_keys=True):
        print(f"  IDENTICAL  {f} (minus the void_escape block)")
    else:
        print(f"  DIFFERS    {f} beyond the void_escape block"); bad = True
la = scrub(json.load(open(os.path.join(L, "run_info.json"))))
ra = scrub(json.load(open(os.path.join(R, "run_info.json"))))
if json.dumps(la, sort_keys=True) == json.dumps(ra, sort_keys=True):
    print("  IDENTICAL  run_info.json (minus void_escape and the clocks)")
else:
    print("  DIFFERS    run_info.json beyond void_escape"); bad = True
print()
print("  C " + ("PASS — arming adds the record and changes nothing else."
      if not bad else "FAIL"))
sys.exit(1 if bad else 0)
PY
echo

if [ "$fail" = "0" ]; then
  echo "R1 PASS — with the option off (its default), a no-lattice run and a"
  echo "          lattice-with-roles run are BYTE-IDENTICAL across two separately"
  echo "          built binaries; arming it adds the void_escape record and"
  echo "          changes no geometry."
  exit 0
fi
echo "R1 FAIL."
exit 1
