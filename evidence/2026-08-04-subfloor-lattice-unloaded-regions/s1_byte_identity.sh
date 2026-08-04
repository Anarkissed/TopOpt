#!/usr/bin/env bash
# S1 — BYTE-IDENTICAL WHEN OFF (task 2026-08-04-subfloor-lattice-unloaded-regions).
#
# "A job that does not opt in is bit-identical." This is the load-bearing bar, so
# it is measured the load-bearing way the task prescribes: STASH the branch, REBUILD
# the CLI from the stashed (= base) tree, run the job, checksum every artifact;
# then restore, rebuild, run the SAME job, and compare the bytes. Not "the code path
# looks unchanged" — the bytes.
#
#   ./s1_byte_identity.sh <branch-build-dir> <base-build-dir> <out-dir>
#
# THE BASE BINARY is produced by the stash-rebuild the bar names: `git stash` the
# tracked tree, build the CLI into a SEPARATE build directory, restore. A separate
# directory rather than in place for two reasons — the branch binary is not
# clobbered mid-run, and, more importantly, see the trap below.
#
# ★ THE TRAP THIS SCRIPT GUARDS AGAINST, because it caught this task once already.
# The CMake target is `topopt_cli` (underscore); the BINARY it produces is
# `topopt-cli` (hyphen), and it sits in the build directory. So
# `cmake --build <dir> --target topopt-cli` finds an existing FILE by that name,
# declares it up to date, EXITS 0, and builds nothing. The first run of this bar
# did exactly that: base and branch were the same binary, every checksum matched,
# and the bar "passed" while proving only that the code is deterministic. So the
# script now asserts the two binaries DIFFER before it compares a single artifact.
# A byte-identity bar whose two sides are the same binary is worse than no bar.
set -euo pipefail

BUILD="${1:?usage: s1_byte_identity.sh <branch-build-dir> <base-build-dir> <out-dir>}"
BASE_BUILD="${2:?}"
OUT="${3:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="$REPO/core/tests/fixtures/demo"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"

cat > "$OUT/job.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "simp": {"max_iterations": 14},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]
  },
  "lattice": {
    "topology": "octet",
    "emit_stl": true,
    "skin": "rim",
    "min_extrudable_width_mm": 0.42
  },
  "grading": {
    "topology": "octet",
    "cell_mode": "swept",
    "cell_min_mm": 3.0,
    "cell_max_mm": 12.0,
    "min_extrudable_width_mm": 0.42
  },
  "output": {
    "report": "report.json",
    "mesh_format": "stl",
    "mesh_prefix": "variant"
  }
}
JSON

run() {  # run <cli> <subdir>
  local cli="$1" sub="$2"
  rm -rf "${OUT:?}/$sub"
  ( cd "$OUT" && "$cli" run job.json --out "$sub" > "$sub.log" 2>&1 ) || {
    echo "RUN FAILED ($sub) — tail of log:"; tail -30 "$OUT/$sub.log"; exit 1; }
  ( cd "$OUT/$sub" && find . -type f ! -name '*.log' | sort \
      | xargs shasum -a 256 ) > "$OUT/$sub.sha256"
}

echo "=== S1 — graded lattice run, retention NOT opted in, base vs branch ==="
echo "branch build: $BUILD"
echo "base   build: $BASE_BUILD"
echo

# ── PRODUCING THE BASE BINARY. Two ways, because the branch's state decides which
# is honest:
#
#   UNCOMMITTED work  -> STASH-REBUILD, the form the bar names: stash the tracked
#     tree, build into a SEPARATE build dir, restore. Only tracked paths are
#     stashed, so the untracked evidence directory this script lives in survives.
#
#   COMMITTED work    -> `git stash` has nothing to take, and stashing a clean
#     tree would build the BRANCH twice and "pass" vacuously. So the base is built
#     from a detached worktree at the merge base instead. Set BASE_REF (default
#     origin/main) and the script does it.
#
# Either way the target is `topopt_cli` — see the trap note at the top of this
# file — and either way the two binaries are compared before anything else is.
BASE_REF="${BASE_REF:-origin/main}"
if git -C "$REPO" diff --quiet -- core app && \
   git -C "$REPO" diff --cached --quiet -- core app; then
  echo "--- tree is clean: building BASE from $BASE_REF in a detached worktree ---"
  WT="$OUT/.base-worktree"
  rm -rf "$WT"
  git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_worktree.log" 2>&1 \
    || { echo "WORKTREE FAILED"; cat "$OUT/base_worktree.log"; exit 1; }
  trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
  BASE_WT="$WT"
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
  echo "--- restoring the branch ---"
  git -C "$REPO" stash pop --quiet || true
fi
# The base worktree STAYS until the runs are done. topopt-cli bakes its default
# materials.json path in at compile time (TOPOPT_CLI_DEFAULT_MATERIALS), so a
# binary built from the worktree cannot run once the worktree is gone — deleting
# it here made the base run fail with "cannot open materials file". The EXIT trap
# set above removes it whichever way the script leaves.
cmake --build "$BUILD" --target topopt_cli -j8 > "$OUT/branch_build.log" 2>&1 \
  || { echo "BRANCH BUILD FAILED"; tail -30 "$OUT/branch_build.log"; exit 1; }

# ★ THE PRECONDITION. If these two are the same bytes, the comparison below is
# vacuous and every "IDENTICAL" line under it means nothing.
BASE_CLI="$BASE_BUILD/topopt-cli"
BRANCH_CLI="$BUILD/topopt-cli"
bs=$(shasum -a 256 "$BASE_CLI"   | cut -d' ' -f1)
br=$(shasum -a 256 "$BRANCH_CLI" | cut -d' ' -f1)
echo
echo "base   cli sha256: $bs"
echo "branch cli sha256: $br"
if [ "$bs" = "$br" ]; then
  echo
  echo "S1 FAIL — the two CLIs are THE SAME BINARY. Nothing below would be"
  echo "          evidence of anything. (Almost certainly the silent-no-op"
  echo "          target trap described at the top of this file.)"
  exit 1
fi
echo "the two binaries differ, as they must for this bar to mean anything."
echo

run "$BASE_CLI" base
run "$BRANCH_CLI" branch

echo
echo "--- base artifacts ---";   cat "$OUT/base.sha256"
echo
echo "--- branch artifacts ---"; cat "$OUT/branch.sha256"
echo

# ── THE BAR ITSELF: report.json, fields.bin and the meshes, byte for byte.
fail=0
echo "--- the bar's named artifacts ---"
MESHES=$(cd "$OUT/base" && ls variant_*.stl 2>/dev/null | sort)
for f in report.json fields.bin design.bin $MESHES; do
  [ -f "$OUT/base/$f" ] || { echo "MISSING in base: $f"; fail=1; continue; }
  a=$(shasum -a 256 "$OUT/base/$f"   | cut -d' ' -f1)
  b=$(shasum -a 256 "$OUT/branch/$f" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
  else echo "DIFFERS    $f"; echo "  base   $a"; echo "  branch $b"; fail=1; fi
done

# ── THE CLOCK-BEARING ARTIFACTS, compared with the clock removed — stated
# explicitly, because "we excluded the files that differed" is exactly the move
# that hides a real regression. Neither can be byte-identical across two runs of
# the SAME binary, so a strict comparison here would prove nothing.
echo
echo "--- clock-bearing artifacts, compared with the clock removed ---"
# THE CLOCK-BEARING KEYS, named one by one rather than pattern-matched, because
# "we dropped the keys that differed" is exactly the move that hides a regression.
# Each of these is a WALL-CLOCK reading and none is physics:
#   created_wall_ms  — the run's start timestamp.
#   gen_seconds      — lattice generation wall time      (observability.hpp:698)
#   gen_fraction     — gen_seconds / total job wall time (observability.hpp:699)
#   preflight_ms     — pre-flight reachability wall time
# PR 294's version of this script named only the first; this job additionally runs
# the lattice GENERATOR and the pre-flight, so it has three more clocks.
#
# AND ONE KEY THAT IS NOT A CLOCK, excluded for a different and stronger reason:
#   fingerprint      — the GIT COMMIT the binary was built from.
# This bar begins by asserting the two binaries DIFFER. A build-provenance stamp
# is therefore GUARANTEED to differ, by construction, on every correct run of this
# script — comparing it would make the bar impossible to pass rather than
# meaningful to fail. It records which source produced the run, not what the run
# computed. (Measured, not assumed: base a70bca05 vs branch 6572eabd was the ONLY
# difference in the whole document.)
#
# Every other key — every count, every margin, every voxel figure — is compared
# verbatim.
strip_run_info() {
  python3 -c "
import json,sys
CLOCKS={'created_wall_ms','gen_seconds','gen_fraction','preflight_ms','fingerprint'}
def scrub(x):
    if isinstance(x, dict):
        return {k: scrub(v) for k, v in x.items() if k not in CLOCKS}
    if isinstance(x, list):
        return [scrub(v) for v in x]
    return x
print(json.dumps(scrub(json.load(open(sys.argv[1]))), sort_keys=True, indent=1))" "$1"
}
if diff -u <(strip_run_info "$OUT/base/run_info.json") \
           <(strip_run_info "$OUT/branch/run_info.json") \
           > "$OUT/run_info.stripped.diff"; then
  echo "IDENTICAL  run_info.json (minus the four wall-clock keys + fingerprint)"
else
  echo "DIFFERS    run_info.json beyond the timestamp:"
  cat "$OUT/run_info.stripped.diff"; fail=1
fi
strip_iters() { cut -d, -f1,2,4-13 "$1"; }
if diff -u <(strip_iters "$OUT/base/iterations.csv") \
           <(strip_iters "$OUT/branch/iterations.csv") \
           > "$OUT/iterations.stripped.diff"; then
  echo "IDENTICAL  iterations.csv (physics columns; timestamps + ms timings dropped)"
else
  echo "DIFFERS    iterations.csv in a physics column:"
  cat "$OUT/iterations.stripped.diff"; fail=1
fi

# ── AND THE LATTICE RECEIPTS, which are where this task's new block lives. They
# must be identical too: a disarmed run emits NO subfloor_retention block in
# run_info, and the graded receipt's block must read all-zero/false.
echo
echo "--- per-variant lattice receipts ---"
for f in $(cd "$OUT/base" && ls *_lattice.report.json 2>/dev/null | sort); do
  a=$(shasum -a 256 "$OUT/base/$f"   | cut -d' ' -f1)
  b=$(shasum -a 256 "$OUT/branch/$f" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
  else echo "DIFFERS    $f"; diff <(python3 -m json.tool "$OUT/base/$f") \
                                  <(python3 -m json.tool "$OUT/branch/$f") | head -40
       fail=1; fi
done

echo
if [ "$fail" = "0" ]; then
  echo "S1 PASS — a graded lattice run that does not opt in to sub-floor retention"
  echo "          is byte-identical: report.json, fields.bin, design.bin, every"
  echo "          mesh and every lattice receipt match, and the two clock-bearing"
  echo "          artifacts match once the clock is removed."
  exit 0
fi
echo "S1 FAIL."
exit 1
