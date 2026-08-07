#!/usr/bin/env bash
# assertion_census.sh — bar R4, done as a MESSAGE census rather than a name grep.
#
# A count of `XCTAssert` calls proves nothing: a test can be renamed, weakened
# ("XCTAssertEqual" → "XCTAssertGreaterThan"), or have its message rewritten while
# the count stays put. What must not happen is that a QUESTION THE SUITE USED TO
# ASK stops being asked. So this compares, between the merge base and the working
# tree:
#
#   1. every test FUNCTION NAME — a name that disappears is a question retired;
#   2. every assertion MESSAGE STRING — the human-readable claim each assertion
#      makes, which is what actually names the question;
#   3. the assertion-KIND histogram per file, so a silent weakening of a strict
#      comparison into a loose one shows up as a shift even when the message is
#      unchanged.
#
# Anything in the BEFORE set and not in the AFTER set is printed. An empty output
# for sections 1 and 2 is the bar being met.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

BASE="$(git merge-base HEAD main 2>/dev/null || echo HEAD)"
TESTS='app/TopOptKit/Tests'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== R4 assertion census: $BASE → working tree ==="
echo

# --- 1. test function names -------------------------------------------------
git grep -h -oE 'func test[A-Za-z0-9_]*' "$BASE" -- "$TESTS/*.swift" \
  | sort -u > "$TMP/names.before"
grep -rh -oE 'func test[A-Za-z0-9_]*' "$TESTS" --include='*.swift' \
  | sort -u > "$TMP/names.after"
echo "1. TEST FUNCTIONS   before=$(wc -l < "$TMP/names.before" | tr -d ' ')  after=$(wc -l < "$TMP/names.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/names.before" "$TMP/names.after" | sed 's/^/     /'
echo "   (nothing above = no test stopped being asked)"
echo

# --- 2. assertion message strings -------------------------------------------
# Every string literal that appears anywhere inside a test file. Deliberately
# broader than "the message argument": an assertion's meaning also lives in the
# expected VALUES and in the identifiers it compares, and a broad set is the
# conservative direction for a "nothing was weakened" check.
git grep -h -oE '"[^"]{8,}"' "$BASE" -- "$TESTS/*.swift" | sort -u > "$TMP/msg.before"
grep -rh -oE '"[^"]{8,}"' "$TESTS" --include='*.swift' | sort -u > "$TMP/msg.after"
echo "2. ASSERTION / LITERAL MESSAGES   before=$(wc -l < "$TMP/msg.before" | tr -d ' ')  after=$(wc -l < "$TMP/msg.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/msg.before" "$TMP/msg.after" | sed 's/^/     /'
echo "   (nothing above = no assertion message disappeared)"
echo

# --- 3. assertion kind histogram --------------------------------------------
git grep -h -oE 'XCT(Assert[A-Za-z]*|Unwrap|Fail|Skip[A-Za-z]*)' "$BASE" -- "$TESTS/*.swift" \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > "$TMP/kind.before"
grep -rh -oE 'XCT(Assert[A-Za-z]*|Unwrap|Fail|Skip[A-Za-z]*)' "$TESTS" --include='*.swift' \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > "$TMP/kind.after"
echo "3. ASSERTION KINDS (before → after; a kind that DROPPED is the thing to look at)"
join -a1 -a2 -e 0 -o 0,1.2,2.2 "$TMP/kind.before" "$TMP/kind.after" \
  | awk '{ d = $3 - $2; printf "     %-28s %6d → %6d  %s\n", $1, $2, $3, (d<0 ? "*** DROPPED "d" ***" : "") }'
