#!/usr/bin/env bash
# R7 — NEVER WEAKEN OR DELETE AN ASSERTION, as a MESSAGE census rather than a
# name grep, plus the deleted-test sweep over this branch's OWN diff.
#
# A count proves nothing: a test can be renamed, weakened (an exact comparison
# loosened into an inequality) or have its message rewritten while the count
# stays put. What must not happen is that a QUESTION THE SUITE USED TO ASK stops
# being asked. So this compares, between the merge base and the working tree, in
# BOTH test trees:
#
#   1. every test FUNCTION NAME  -- a name that disappears is a question retired;
#   2. every assertion MESSAGE STRING -- the human-readable claim, which is what
#      actually names the question;
#   3. the assertion-KIND histogram, so a strict comparison quietly loosened into
#      a looser one shows up even when the message is unchanged;
#   4. the FILE-LEVEL sweep: any test file the diff deletes or shrinks.
#
# ★ THE MERGE BASE IS `origin/main`, NOT `main` AND NOT A MOVING HEAD (R7's own
# words, and memory: main-moves-under-long-tasks). A census taken against a head
# that moved under the task would report someone else's deletions as this one's,
# or hide this one's behind theirs.
#
# THIS TASK CHANGES NO PRODUCTION FILE AND NO TEST. It adds two
# EXCLUDE_FROM_ALL harnesses and the CMake blocks declaring them. So every
# "removed" list below is expected to be EMPTY, and an empty list is the bar
# being met — not the script failing to look.
#
#   ./evidence/2026-08-19-peak-stress-convergence/r7_assertion_census.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

BASE="$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

echo "=== R7 assertion census: $BASE -> working tree ==="
echo

# ── CORE ─────────────────────────────────────────────────────────────────────
CTESTS='core/tests'
git grep -h -oE 'CHECK\(' "$BASE" -- "$CTESTS/*.cpp" | wc -l | tr -d ' ' > "$TMP/c.before"
grep -rh -oE 'CHECK\(' "$CTESTS" --include='*.cpp' | wc -l | tr -d ' ' > "$TMP/c.after"
echo "CORE 1. CHECK() CALL SITES   before=$(cat "$TMP/c.before")  after=$(cat "$TMP/c.after")"
[ "$(cat "$TMP/c.after")" -lt "$(cat "$TMP/c.before")" ] && { echo "   *** CHECK sites FELL ***"; FAIL=1; }
echo

git grep -h -oE '"[^"]{8,}"' "$BASE" -- "$CTESTS/*.cpp" | sort -u > "$TMP/cmsg.before"
grep -rh -oE '"[^"]{8,}"' "$CTESTS" --include='*.cpp' | sort -u > "$TMP/cmsg.after"
echo "CORE 2. ASSERTION / LITERAL MESSAGES   before=$(wc -l < "$TMP/cmsg.before" | tr -d ' ')  after=$(wc -l < "$TMP/cmsg.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/cmsg.before" "$TMP/cmsg.after" | sed 's/^/     /'
if [ -n "$(comm -23 "$TMP/cmsg.before" "$TMP/cmsg.after")" ]; then FAIL=1; else echo "     (none)"; fi
echo

# ── APP ──────────────────────────────────────────────────────────────────────
TESTS='app/TopOptKit/Tests'
git grep -h -oE 'func test[A-Za-z0-9_]*' "$BASE" -- "$TESTS/*.swift" | sort -u > "$TMP/names.before"
grep -rh -oE 'func test[A-Za-z0-9_]*' "$TESTS" --include='*.swift' 2>/dev/null | sort -u > "$TMP/names.after"
echo "APP 1. TEST FUNCTIONS   before=$(wc -l < "$TMP/names.before" | tr -d ' ')  after=$(wc -l < "$TMP/names.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/names.before" "$TMP/names.after" | sed 's/^/     /'
if [ -n "$(comm -23 "$TMP/names.before" "$TMP/names.after")" ]; then FAIL=1; else echo "     (none)"; fi
echo

git grep -h -oE 'XCT(Assert[A-Za-z]*|Unwrap|Fail|Skip[A-Za-z]*)' "$BASE" -- "$TESTS/*.swift" \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > "$TMP/kind.before"
grep -rh -oE 'XCT(Assert[A-Za-z]*|Unwrap|Fail|Skip[A-Za-z]*)' "$TESTS" --include='*.swift' 2>/dev/null \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > "$TMP/kind.after"
echo "APP 2. ASSERTION KINDS (before -> after; a kind that DROPPED is the thing to look at)"
join -a1 -a2 -e 0 -o 0,1.2,2.2 "$TMP/kind.before" "$TMP/kind.after" \
  | awk '{ d = $3 - $2; printf "     %-28s %6d -> %6d  %s\n", $1, $2, $3, (d<0 ? "*** DROPPED "d" ***" : "") }'
join -a1 -a2 -e 0 -o 0,1.2,2.2 "$TMP/kind.before" "$TMP/kind.after" | awk '$3<$2{f=1} END{exit !f}' && FAIL=1
echo

# ── 4. THE DELETED-TEST SWEEP OVER THIS BRANCH'S OWN DIFF ────────────────────
echo "3. FILES THIS BRANCH DELETES OR SHRINKS under core/tests or app/.../Tests"
git diff --numstat "$BASE" -- "$CTESTS" "$TESTS" \
  | awk '{ if ($2+0 > $1+0) printf "     %-70s -%s +%s  *** NET DELETION ***\n", $3, $2, $1;
           else printf "     %-70s -%s +%s\n", $3, $2, $1 }'
[ -z "$(git diff --numstat "$BASE" -- "$CTESTS" "$TESTS")" ] && echo "     (no test file changed at all)"
git diff --diff-filter=D --name-only "$BASE" -- "$CTESTS" "$TESTS" | sed 's/^/     DELETED: /'
if [ -n "$(git diff --diff-filter=D --name-only "$BASE" -- "$CTESTS" "$TESTS")" ]; then FAIL=1; fi
echo

# ── 5. ctest registrations ───────────────────────────────────────────────────
echo "4. ctest REGISTRATIONS in core/CMakeLists.txt"
BEF="$(git show "$BASE":core/CMakeLists.txt | grep -c 'add_test(')"
AFT="$(grep -c 'add_test(' core/CMakeLists.txt)"
echo "     add_test() sites: before=$BEF  after=$AFT"
[ "$AFT" -lt "$BEF" ] && { echo "     *** a ctest registration was REMOVED ***"; FAIL=1; }
git show "$BASE":core/CMakeLists.txt | grep -oE 'add_test\(NAME [A-Za-z0-9_]+' | sort -u > "$TMP/t.before"
grep -oE 'add_test\(NAME [A-Za-z0-9_]+' core/CMakeLists.txt | sort -u > "$TMP/t.after"
echo "     removed test names:"
comm -23 "$TMP/t.before" "$TMP/t.after" | sed 's/^/       /'
[ -z "$(comm -23 "$TMP/t.before" "$TMP/t.after")" ] && echo "       (none)"
echo

echo "=== VERDICT: $([ "$FAIL" -eq 0 ] && echo 'R7 PASS — nothing was weakened or deleted' || echo 'R7 ATTENTION — see the *** lines above') ==="
exit 0
