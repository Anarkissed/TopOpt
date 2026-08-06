#!/usr/bin/env bash
# R6 — NEVER WEAKEN OR DELETE AN ASSERTION. The sweep, on this branch's OWN diff.
# (task 2026-08-05-lattice-void-reaches-exterior)
#
#   ./r6_deleted_test_sweep.sh [base-ref]
#
# A test COUNT never shows what stopped being asked, and a rename reads as a
# deletion. So this sweep accounts for every REMOVED LINE in the diff, and
# separately for every CHECK( that existed on the base and does not exist on the
# branch — by its message text, so a moved assertion is not miscounted as a lost
# one.
set -euo pipefail
BASE="${1:-origin/main}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

echo "=== R6 — deleted-test sweep, branch vs $BASE ==="
echo

echo "--- 1. Files changed ---"
git diff --stat "$BASE" -- core app
echo
echo "--- untracked (new) files ---"
git ls-files --others --exclude-standard -- core app
echo

echo "--- 2. EVERY removed line in core/ and app/, with its file ---"
echo "(a line that starts with '-' and is not the /dev/null header)"
git diff -U0 "$BASE" -- core app |
  awk '/^\+\+\+ /{f=substr($0,7)} /^-[^-]/{print f": "substr($0,2)}'
echo

echo "--- 3. Assertion census: CHECK( messages present on $BASE and absent now ---"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
collect() {  # collect <ref|WORKTREE> <outfile>
  local ref="$1" out="$2"
  : > "$out"
  if [ "$ref" = "WORKTREE" ]; then
    for f in $(git ls-files core/tests) $(git ls-files --others --exclude-standard -- core/tests); do
      grep -ho 'CHECK(.*' "$f" 2>/dev/null || true
    done >> "$out"
  else
    for f in $(git ls-tree -r --name-only "$ref" -- core/tests); do
      git show "$ref:$f" 2>/dev/null | grep -ho 'CHECK(.*' || true
    done >> "$out"
  fi
  sort -u "$out" -o "$out"
}
collect "$BASE" "$tmp/base.txt"
collect WORKTREE "$tmp/branch.txt"
nb=$(wc -l < "$tmp/base.txt" | tr -d ' ')
nn=$(wc -l < "$tmp/branch.txt" | tr -d ' ')
echo "distinct CHECK( lines on $BASE: $nb"
echo "distinct CHECK( lines on branch : $nn"
lost=$(comm -23 "$tmp/base.txt" "$tmp/branch.txt" | wc -l | tr -d ' ')
echo "present on $BASE, absent on branch: $lost"
if [ "$lost" != "0" ]; then
  echo
  echo "THE LOST ONES — every line must be accounted for in the handoff:"
  comm -23 "$tmp/base.txt" "$tmp/branch.txt"
fi
echo
gained=$(comm -13 "$tmp/base.txt" "$tmp/branch.txt" | wc -l | tr -d ' ')
echo "added on branch: $gained"
echo
if [ "$lost" = "0" ]; then
  echo "R6 PASS — no assertion that existed on $BASE is missing from the branch."
  exit 0
fi
echo "R6 — $lost assertion line(s) disappeared. Account for each ABOVE before"
echo "     pushing; do not push on the assumption they were renames."
exit 1
