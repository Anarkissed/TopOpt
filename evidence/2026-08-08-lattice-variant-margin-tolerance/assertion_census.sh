#!/usr/bin/env bash
# assertion_census.sh — bar R5, done as a MESSAGE census rather than a name grep,
# and extended to cover CORE's tests as well as the app's (this task changes both).
#
# A count of assertions proves nothing: a test can be renamed, weakened
# ("XCTAssertEqual" → "XCTAssertGreaterThan"), or have its message rewritten while
# the count stays put. What must not happen is that a QUESTION THE SUITE USED TO
# ASK stops being asked. So this compares, between the merge base and the working
# tree, for BOTH test trees:
#
#   1. every test FUNCTION NAME — a name that disappears is a question retired;
#   2. every assertion MESSAGE STRING — the human-readable claim each assertion
#      makes, which is what actually names the question;
#   3. the assertion-KIND histogram, so a silent weakening of a strict comparison
#      into a loose one shows up as a shift even when the message is unchanged.
#
# ★ THIS TASK DELIBERATELY CHANGES TWO THINGS, AND THEY ARE EXPECTED TO APPEAR
#   IN THE "removed" LISTS. Both are named in the handoff (§ "What was relaxed"):
#
#   R  the PRODUCTION check `lattice_variant`'s margin reproduction — a bare `==`
#      on a double — becomes a stated relative band. That is the task. The exact
#      comparison survives as a REPORTED flag (`reproduction_exact`,
#      `solid_reconstruction_exact`) and both core tests that assert it
#      (test_lattice_variant Z2, test_designbox_lattice_recert) are UNTOUCHED and
#      still pass.
#
#   P  the app test `testTheRecommendationPointsAtTheHeaviestLatticedObject`,
#      which PR 311 wrote to pin the old recommendation rule until the maintainer
#      ruled on it. He ruled. It is re-pinned as
#      `testTheRecommendationPointsAtTheLightestPrintedObject`, keeping every
#      measured fact it asserted and adding the 31.22 g the old rule cost.
#
# Anything else in the BEFORE set and not in the AFTER set is a regression.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

BASE="$(git merge-base HEAD main 2>/dev/null || echo HEAD)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== R5 assertion census: $BASE → working tree ==="
echo

# ── APP ──────────────────────────────────────────────────────────────────────
TESTS='app/TopOptKit/Tests'
git grep -h -oE 'func test[A-Za-z0-9_]*' "$BASE" -- "$TESTS/*.swift" | sort -u > "$TMP/names.before"
grep -rh -oE 'func test[A-Za-z0-9_]*' "$TESTS" --include='*.swift' | sort -u > "$TMP/names.after"
echo "APP 1. TEST FUNCTIONS   before=$(wc -l < "$TMP/names.before" | tr -d ' ')  after=$(wc -l < "$TMP/names.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/names.before" "$TMP/names.after" | sed 's/^/     /'
echo "   (only the re-pinned P above = bar met)"
echo

git grep -h -oE '"[^"]{8,}"' "$BASE" -- "$TESTS/*.swift" | sort -u > "$TMP/msg.before"
grep -rh -oE '"[^"]{8,}"' "$TESTS" --include='*.swift' | sort -u > "$TMP/msg.after"
echo "APP 2. ASSERTION / LITERAL MESSAGES   before=$(wc -l < "$TMP/msg.before" | tr -d ' ')  after=$(wc -l < "$TMP/msg.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/msg.before" "$TMP/msg.after" | sed 's/^/     /'
echo

git grep -h -oE 'XCT(Assert[A-Za-z]*|Unwrap|Fail|Skip[A-Za-z]*)' "$BASE" -- "$TESTS/*.swift" \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > "$TMP/kind.before"
grep -rh -oE 'XCT(Assert[A-Za-z]*|Unwrap|Fail|Skip[A-Za-z]*)' "$TESTS" --include='*.swift' \
  | sort | uniq -c | awk '{print $2" "$1}' | sort > "$TMP/kind.after"
echo "APP 3. ASSERTION KINDS (before → after; a kind that DROPPED is the thing to look at)"
join -a1 -a2 -e 0 -o 0,1.2,2.2 "$TMP/kind.before" "$TMP/kind.after" \
  | awk '{ d = $3 - $2; printf "     %-28s %6d → %6d  %s\n", $1, $2, $3, (d<0 ? "*** DROPPED "d" ***" : "") }'
echo

# ── CORE ─────────────────────────────────────────────────────────────────────
CTESTS='core/tests'
git grep -h -oE 'CHECK\(' "$BASE" -- "$CTESTS/*.cpp" | wc -l | tr -d ' ' > "$TMP/c.before"
grep -rh -oE 'CHECK\(' "$CTESTS" --include='*.cpp' | wc -l | tr -d ' ' > "$TMP/c.after"
echo "CORE 1. CHECK() CALL SITES   before=$(cat "$TMP/c.before")  after=$(cat "$TMP/c.after")"

git grep -h -oE '"[^"]{8,}"' "$BASE" -- "$CTESTS/*.cpp" | sort -u > "$TMP/cmsg.before"
grep -rh -oE '"[^"]{8,}"' "$CTESTS" --include='*.cpp' | sort -u > "$TMP/cmsg.after"
echo "CORE 2. ASSERTION / LITERAL MESSAGES   before=$(wc -l < "$TMP/cmsg.before" | tr -d ' ')  after=$(wc -l < "$TMP/cmsg.after" | tr -d ' ')"
echo "   removed:"
comm -23 "$TMP/cmsg.before" "$TMP/cmsg.after" | sed 's/^/     /'
echo "   (nothing above = no core assertion message disappeared)"
echo

# ── THE PRODUCTION RELAXATION, NAMED AND LOCATED ─────────────────────────────
echo "R. THE ONE PRODUCTION CHECK THIS TASK RELAXES"
echo "   before (merge base):"
git grep -n -A1 'result.reproduction_exact =' "$BASE" -- core/src/cli/run_job.cpp | sed 's/^/     /'
git grep -n 'if (!result.reproduction_exact)' "$BASE" -- core/src/cli/run_job.cpp | sed 's/^/     /'
echo "   after (working tree):"
grep -n 'result.reproduction_within_band =' -A2 core/src/cli/run_job.cpp | sed 's/^/     /'
grep -n 'if (!result.reproduction_within_band)' core/src/cli/run_job.cpp | sed 's/^/     /'
echo "   the EXACT flag survives, reported, and both core tests that assert it are untouched:"
grep -rn 'reproduction_exact' core/tests | sed 's/^/     /'
