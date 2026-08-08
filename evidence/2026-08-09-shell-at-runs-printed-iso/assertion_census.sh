#!/usr/bin/env bash
# assertion_census.sh — the assertion-message census bar (task 2026-08-09-fix-inward-wound-normals), done as a MESSAGE census rather than a name grep.
#
# A count of `CHECK(` calls proves nothing: a check can be renamed, weakened
# (`== ` → `>= `), or have its message rewritten while the count stays put. What
# must not happen is that a QUESTION THE SUITE USED TO ASK stops being asked. So
# this compares, between the merge base and the working tree:
#
#   1. every CHECK / REQUIRE MESSAGE STRING in core's unit tests — the
#      human-readable claim each assertion makes, which is what actually names
#      the question;
#   2. every registered ctest NAME, so a whole test binary cannot quietly stop
#      running;
#   3. every `throw JobError(` / `throw std::` REFUSAL MESSAGE in core/src —
#      production refusals are assertions too, and this task adds one; a refusal
#      that disappears is a guard that stopped guarding.
#
# Anything in the BEFORE set and not in the AFTER set is printed. Empty removal
# lists are the bar being met.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# ★ THE BASELINE IS THIS PR's PARENT, NOT THE MERGE BASE. This branch STACKS on
# strut-clip-matches-shell (it edits that task's mesh_distance.cpp and
# test_lattice_clip_shell.cpp), so censusing against `main` would credit this PR
# with the other one's assertions and hide anything it removed from them.
# Override with BASE_REF=<sha> if the stack changes.
BASE="${BASE_REF:-$(git rev-parse HEAD)}"   # this PR is the WORKING TREE against HEAD
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== R6 assertion census: $BASE → working tree ==="
echo

# --- 1. CHECK / REQUIRE message strings in core's unit tests -----------------
# The message is the last string literal of a CHECK(...) call; taking EVERY
# string literal of >= 8 characters inside the test files is deliberately
# broader, which is the conservative direction for a "nothing was weakened"
# check.
git grep -h -oE '"[^"]{8,}"' "$BASE" -- 'core/tests/unit/*.cpp' | sort -u > "$TMP/msg.before"
grep -rh -oE '"[^"]{8,}"' core/tests/unit --include='*.cpp' | sort -u > "$TMP/msg.after"
echo "1. TEST ASSERTION MESSAGES   before=$(wc -l < "$TMP/msg.before" | tr -d ' ')  after=$(wc -l < "$TMP/msg.after" | tr -d ' ')"
echo "   REMOVED:"
comm -23 "$TMP/msg.before" "$TMP/msg.after" | sed 's/^/     /'
echo "   (nothing above = no assertion message disappeared)"
echo

# --- 2. registered ctest names ----------------------------------------------
git grep -h -oE 'add_test\(NAME [A-Za-z0-9_]+' "$BASE" -- core/CMakeLists.txt \
  | sed 's/.*NAME //' | sort -u > "$TMP/test.before"
grep -h -oE 'add_test\(NAME [A-Za-z0-9_]+' core/CMakeLists.txt \
  | sed 's/.*NAME //' | sort -u > "$TMP/test.after"
echo "2. REGISTERED CTESTS   before=$(wc -l < "$TMP/test.before" | tr -d ' ')  after=$(wc -l < "$TMP/test.after" | tr -d ' ')"
echo "   REMOVED:"
comm -23 "$TMP/test.before" "$TMP/test.after" | sed 's/^/     /'
echo "   ADDED:"
comm -13 "$TMP/test.before" "$TMP/test.after" | sed 's/^/     /'
echo

# --- 3. production refusal messages ------------------------------------------
# A `throw` in core/src is a production assertion, and a refusal that vanishes is
# a guard that stopped guarding. The message often starts on the line AFTER the
# `throw`, so match the first string literal within three lines of it — a
# same-line-only regex silently misses every wrapped refusal, including the one
# this task adds.
first_literal_after_throw() {
  awk '
    /throw (JobError|std::[a-z_]+)\(/ { hunt = 3 }
    hunt > 0 {
      if (match($0, /"[^"]{8,}"/)) {
        print substr($0, RSTART, RLENGTH); hunt = 0; next
      }
      --hunt
    }'
}
git grep -h '' "$BASE" -- 'core/src/**/*.cpp' | first_literal_after_throw \
  | sort -u > "$TMP/thr.before"
find core/src -name '*.cpp' -print0 | xargs -0 cat | first_literal_after_throw \
  | sort -u > "$TMP/thr.after"
echo "3. PRODUCTION REFUSALS   before=$(wc -l < "$TMP/thr.before" | tr -d ' ')  after=$(wc -l < "$TMP/thr.after" | tr -d ' ')"
echo "   REMOVED:"
comm -23 "$TMP/thr.before" "$TMP/thr.after" | sed 's/^/     /'
echo "   (nothing above = no production refusal disappeared)"
echo

# --- 4. assertion KIND histogram in core's unit tests ------------------------
# A silent weakening of a strict comparison into a loose one shows up here even
# when the message is unchanged.
kinds() {
  sed -nE 's/.*CHECK\((.*)/\1/p' \
    | grep -oE '(==|!=|<=|>=|<|>|&&|\|\|)' | sort | uniq -c \
    | awk '{print $2" "$1}' | sort
}
git grep -h 'CHECK(' "$BASE" -- 'core/tests/unit/*.cpp' | kinds > "$TMP/kind.before"
grep -rh 'CHECK(' core/tests/unit --include='*.cpp' | kinds > "$TMP/kind.after"
echo "4. COMPARISON KINDS INSIDE CHECK() (before → after; a DROP is the thing to look at)"
join -a1 -a2 -e 0 -o 0,1.2,2.2 "$TMP/kind.before" "$TMP/kind.after" \
  | awk '{ d = $3 - $2; printf "     %-6s %6d → %6d  %s\n", $1, $2, $3, (d<0 ? "*** DROPPED "d" ***" : "") }'
