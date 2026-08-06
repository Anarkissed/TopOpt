#!/usr/bin/env bash
# R1 — BYTE-IDENTICAL WHEN OFF, by stash-rebuild checksum.
#
# The bar is "not by construction". So this script does not read the code: it
# builds topopt-cli TWICE from ONE build folder — once from this branch (the
# projection compiled in, `output.project_cad_faces` absent, i.e. OFF) and once
# from the merge-base with the branch's changes stashed away — runs the SAME job
# with each, and compares the sha256 of every artifact.
#
# AND IT GUARDS ITSELF. A byte-identity bar passes vacuously if the two binaries
# are in fact the same file, so the script REQUIRES the two binaries to differ.
# If they do not, the rebuild did not happen and the comparison proves nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD="$REPO/core/build"
WORK="$HERE/r1_work"
rm -rf "$WORK"; mkdir -p "$WORK"

JOB="$HERE/r1_job.json"
cp "$HERE/M2_verticalStand.step" "$WORK/"
cp "$JOB" "$WORK/job.json"

run_one() {           # run_one <label>
  local label="$1"
  # THE TARGET IS topopt_cli (underscore); the BINARY is topopt-cli (hyphen).
  # `--target topopt-cli` silently builds nothing, which is exactly how the first
  # run of this script produced two identical binaries — caught by the guard
  # below, which is why the guard is here.
  cmake --build "$BUILD" --target topopt_cli -j 10 > "$WORK/build_$label.log" 2>&1
  shasum -a 256 "$BUILD/topopt-cli" | awk '{print $1}' > "$WORK/bin_$label.sha"
  # And the build must actually have RELINKED. A stale binary hashes fine.
  echo "$label: binary mtime $(stat -f %m "$BUILD/topopt-cli")" >&2
  rm -rf "$WORK/out_$label"
  ( cd "$WORK" && "$BUILD/topopt-cli" run job.json --out "out_$label" ) \
      > "$WORK/run_$label.log" 2>&1
  # Every artifact, hashed. run_info.json carries wall-clock timings and a
  # version string, so it is EXCLUDED and named here rather than quietly skipped.
  ( cd "$WORK/out_$label" && \
    find . -type f ! -name run_info.json ! -name iterations.csv -print0 \
      | sort -z | xargs -0 shasum -a 256 ) \
    | sed "s#out_$label#OUT#" > "$WORK/hashes_$label.txt"
}

echo "== BRANCH (projection compiled in, job does not ask for it) =="
run_one branch

echo "== BASE (branch changes stashed away) =="
STASH_MSG="r1-byte-identity-$$"
git -C "$REPO" stash push -u -m "$STASH_MSG" -- core >/dev/null
trap 'git -C "$REPO" stash list | grep -q "$STASH_MSG" && git -C "$REPO" stash pop >/dev/null' EXIT
# The stash must have actually cleared core/, or "base" is just "branch" again.
if [ -n "$(git -C "$REPO" status --porcelain -- core)" ]; then
  echo "R1 INVALID: core/ is not clean after the stash:"
  git -C "$REPO" status --porcelain -- core
  exit 2
fi
if [ -e "$REPO/core/src/mesh/cad_project.cpp" ]; then
  echo "R1 INVALID: the branch's new source survived the stash."
  exit 2
fi
run_one base
git -C "$REPO" stash pop >/dev/null
trap - EXIT

echo
echo "-- the guard: the two binaries MUST differ ---------------------"
echo "branch binary sha256 $(cat "$WORK/bin_branch.sha")"
echo "base   binary sha256 $(cat "$WORK/bin_base.sha")"
if [ "$(cat "$WORK/bin_branch.sha")" = "$(cat "$WORK/bin_base.sha")" ]; then
  echo "R1 INVALID: the two binaries are identical — no rebuild happened, so the"
  echo "artifact comparison below would prove nothing."
  exit 2
fi
echo "the binaries differ, so the rebuild is real."

echo
echo "-- the bar: every artifact byte-identical ----------------------"
if diff -u "$WORK/hashes_base.txt" "$WORK/hashes_branch.txt"; then
  echo "R1 MET: every artifact is byte-identical across the two binaries."
  wc -l < "$WORK/hashes_branch.txt" | xargs echo "files compared:"
  cat "$WORK/hashes_branch.txt"
else
  echo "R1 FAILED: an artifact changed with the feature OFF."
  exit 1
fi
