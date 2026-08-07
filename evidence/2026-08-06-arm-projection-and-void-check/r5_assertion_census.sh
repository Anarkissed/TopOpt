#!/usr/bin/env bash
# R5 — NEVER WEAKEN OR DELETE AN ASSERTION.
# task 2026-08-06-arm-projection-and-void-check
#
#   ./r5_assertion_census.sh <merge-base-ref>
#
# PR 305's method, unchanged, because it is the right one: compare the SET OF
# ASSERTION MESSAGES on the merge base against the branch and report
# present-on-main-absent-on-branch. Grepping function names would read a RENAME
# as a deletion and a MOVE as a loss; comparing the message text does not,
# because the message is what states the claim.
#
# Both languages are censused. The core uses a self-contained `CHECK(cond, "…")`
# harness; the app uses XCTest. Counting only one of them would miss exactly the
# half this task touched most.
#
# ★ AN ASSERTION THAT CHANGED SHAPE STILL SHOWS UP HERE as one lost message and
# one gained one — the census cannot tell a weakening from a rewording. So every
# line it reports is accounted for BY HAND in the handoff, individually, with
# the reason. The census's job is to make sure none is missed, not to judge.
set -euo pipefail

BASE="${1:-d9fe8f7}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The message text of every assertion, one per line, deduplicated.
extract_cpp() {           # reads a git ref, writes messages to stdout
  local ref="$1"
  git ls-tree -r --name-only "$ref" -- core/tests \
    | grep -E '\.(cpp|hpp)$' \
    | while read -r f; do git show "$ref:$f" 2>/dev/null || true; done \
    | grep -oE 'CHECK\([^;]*"[^"]*"' \
    | grep -oE '"[^"]*"$' | sort -u
}
extract_swift() {
  local ref="$1"
  git ls-tree -r --name-only "$ref" -- app/TopOptKit/Tests \
    | grep -E '\.swift$' \
    | while read -r f; do git show "$ref:$f" 2>/dev/null || true; done \
    | grep -oE 'XCTAssert[A-Za-z]*\(' | sort | uniq -c | sort -rn
}
# Swift assertion IDENTITY is the test-function name plus the assertion kind:
# XCTest messages are optional and frequently absent, so message text alone
# would census almost nothing. Function names are used HERE only, and a rename
# is resolved by hand in the handoff.
extract_swift_tests() {
  local ref="$1"
  git ls-tree -r --name-only "$ref" -- app/TopOptKit/Tests \
    | grep -E '\.swift$' \
    | while read -r f; do git show "$ref:$f" 2>/dev/null || true; done \
    | grep -oE 'func +test[A-Za-z0-9_]*' | sed 's/func *//' | sort -u
}

echo "merge base: $BASE ($(git log -1 --format=%s "$BASE"))"
echo "branch    : $(git rev-parse --abbrev-ref HEAD)"
echo

echo "=== C++ (core/tests): distinct CHECK message texts ====================="
extract_cpp "$BASE" > "$TMP/cpp_base"
extract_cpp HEAD    > "$TMP/cpp_head"
echo "on the merge base : $(wc -l < "$TMP/cpp_base" | tr -d ' ')"
echo "on the branch     : $(wc -l < "$TMP/cpp_head" | tr -d ' ')"
lost=$(comm -23 "$TMP/cpp_base" "$TMP/cpp_head" | wc -l | tr -d ' ')
gain=$(comm -13 "$TMP/cpp_base" "$TMP/cpp_head" | wc -l | tr -d ' ')
echo "PRESENT ON MAIN, ABSENT ON BRANCH : $lost"
echo "added                             : $gain"
if [ "$lost" != "0" ]; then
  echo
  echo "--- the lost messages, in full, every one to be accounted for by hand ---"
  comm -23 "$TMP/cpp_base" "$TMP/cpp_head"
fi
echo

echo "=== Swift (app/TopOptKit/Tests): test functions ========================"
extract_swift_tests "$BASE" > "$TMP/sw_base"
extract_swift_tests HEAD    > "$TMP/sw_head"
echo "on the merge base : $(wc -l < "$TMP/sw_base" | tr -d ' ')"
echo "on the branch     : $(wc -l < "$TMP/sw_head" | tr -d ' ')"
slost=$(comm -23 "$TMP/sw_base" "$TMP/sw_head" | wc -l | tr -d ' ')
sgain=$(comm -13 "$TMP/sw_base" "$TMP/sw_head" | wc -l | tr -d ' ')
echo "PRESENT ON MAIN, ABSENT ON BRANCH : $slost"
echo "added                             : $sgain"
if [ "$slost" != "0" ]; then
  echo
  echo "--- the lost test functions ---"
  comm -23 "$TMP/sw_base" "$TMP/sw_head"
fi
echo
echo "=== Swift assertion-call census (kind x count) ========================="
echo "--- merge base ---"; extract_swift "$BASE"
echo "--- branch ---";     extract_swift HEAD
echo

echo "=== every REMOVED line under core/tests and app/TopOptKit/Tests ========"
echo "(so a change inside an assertion is visible even when the message survives)"
git diff "$BASE" HEAD -- core/tests app/TopOptKit/Tests | grep -E '^-[^-]' || \
  echo "  (none)"
echo
echo "=== files changed under the two test trees ============================="
git diff --stat "$BASE" HEAD -- core/tests app/TopOptKit/Tests
