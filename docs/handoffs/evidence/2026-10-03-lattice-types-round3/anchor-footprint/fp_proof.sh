#!/bin/zsh
# Usage: fp_proof.sh SNAPSHOT_DIR ID [convert] [release]
# Ruling A (2026-10-03): the anchor-footprint identical-bake proof for one project. A fresh writable
# COPY of the project folder from a read-only snapshot (converted to Default Grade when asked, with
# round 2's converter, labelled), then LatticeOctreeFootprintProof bakes it four times in one process
# (control, control again, footprint, RED inset) and writes <ID>.txt next to this script. The harness
# log stays in the work dir (it is the renderer's whole NSLog stream); its DIAG octree lines are
# appended to <ID>.txt. Test products must be built first (`swift build --build-tests`, or
# `swift build -c release -Xswiftc -enable-testing --build-tests` for `release`).
# Env: FP_WORK (copies + logs; default $TMPDIR/fp-proof), OCTREE_FIELD=none, OCTREE_AA=0.
set -u
here=${0:A:h}
repo=${0:A:h:h:h:h:h:h}
snap=${1:?SNAPSHOT_DIR}; id=${2:?ID}; conv=${3:-}; cfg=${4:-}
[[ "$snap" == *CoreSimulator* ]] && { echo "refusing: that is the live store"; exit 2; }
work=${FP_WORK:-${TMPDIR:-/tmp}/fp-proof}/$id
rm -rf "$work"; mkdir -p "$work/project"
cp -R "$snap/$id/." "$work/project/"; chmod -R u+w "$work/project"
[[ "$conv" == convert ]] && python3 "$repo/docs/handoffs/evidence/2026-10-02-lattice-types-round2/tools/convert_default_grade.py" "$work/project"
extra=()
[[ "$cfg" == release ]] && extra=(-c release -Xswiftc -enable-testing)
start=$(date +%s)
( cd "$repo/app/TopOptKit" && OCTREE_PROOF_DIR="$work/project" OCTREE_PROOF_OUT="$here" \
    swift test --skip-build "${extra[@]}" --filter LatticeOctreeFootprintProof > "$work/harness.log" 2>&1 )
rc=$?
{
  echo ""
  echo "harness: exit $rc, $(( $(date +%s) - start ))s wall, build ${cfg:-debug}${conv:+, converted to Default Grade (copy)}"
  grep -E "Executed [0-9]+ test" "$work/harness.log" | head -1 | sed 's/^[[:space:]]*//'
  echo "the renderer's own DIAG octree lines, in arm order:"
  grep -E "DIAG octree" "$work/harness.log" | sed 's/^.*DIAG octree/  DIAG octree/'
} >> "$here/$id.txt"
grep -E "FP-PROJECT|FP-SCENE|FP-ARM|error:|skipped|Executed [0-9]+ test" "$work/harness.log" | sed 's/^.*\] //' | head -20
exit $rc
