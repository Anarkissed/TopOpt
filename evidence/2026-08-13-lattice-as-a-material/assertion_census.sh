#!/usr/bin/env bash
# assertion_census.sh — R7, done as a MESSAGE census rather than a name grep.
#
# A count of `CHECK(` calls proves nothing: a check can be renamed, weakened
# (`==` -> `>=`), or have its message rewritten while the count stays put. What
# must not happen is that a QUESTION THE SUITE USED TO ASK stops being asked. So
# this compares, between `main` and the working tree:
#
#   1. every CHECK / REQUIRE MESSAGE STRING in core's unit tests;
#   2. every registered ctest NAME, so a whole test binary cannot quietly stop
#      running;
#   3. every `throw JobError(` / `throw std::` REFUSAL MESSAGE in core/src —
#      production refusals are assertions too;
#   4. the comparison-operator histogram inside CHECK(), which catches a silent
#      weakening that left the message alone;
#   5. ★ THE HARNESS'S OWN REFUSALS. Censused as ONE bag, so a message that
#      moved between harness files still shows up as present.
#
# ★ THIS TASK EDITS PRODUCTION, so section 3 is the one that matters most here —
# unlike the previous task, whose whole diff was in the harness.
#
# Anything in the BEFORE set and not in the AFTER set is printed. Empty removal
# lists are the bar being met.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# This branch does NOT stack: it branches from `main` and every file it touches
# it either created or is the sole editor of in this PR.
BASE="${BASE_REF:-main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== R7 assertion census: $BASE -> working tree ==="
echo

# --- 1. CHECK / REQUIRE message strings in core's unit tests -----------------
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
kinds() {
  sed -nE 's/.*CHECK\((.*)/\1/p' \
    | grep -oE '(==|!=|<=|>=|<|>|&&|\|\|)' | sort | uniq -c \
    | awk '{print $2" "$1}' | sort
}
git grep -h 'CHECK(' "$BASE" -- 'core/tests/unit/*.cpp' | kinds > "$TMP/kind.before"
grep -rh 'CHECK(' core/tests/unit --include='*.cpp' | kinds > "$TMP/kind.after"
echo "4. COMPARISON KINDS INSIDE CHECK() (before -> after; a DROP is the thing to look at)"
join -a1 -a2 -e 0 -o 0,1.2,2.2 "$TMP/kind.before" "$TMP/kind.after" \
  | awk '{ d = $3 - $2; printf "     %-6s %6d -> %6d  %s\n", $1, $2, $3, (d<0 ? "*** DROPPED "d" ***" : "") }'
echo

# --- 5. ★ THE HARNESS'S OWN REFUSALS, which is where this task's diff lives --
# `levelset_kernel.hpp` and `plsm_basis.hpp` are code MOVED OUT of
# `levelset_probe.cpp` and `plsm_probe.cpp`; counting the harness as one bag
# means a refusal that was dropped during either move shows up as REMOVED even
# though the file it came from still exists.
harness_msgs() {
  grep -hoE '"(FATAL|WARNING|ERROR)[^"]*"|"[^"]{12,}"' 2>/dev/null | sort -u
}
git grep -h '' "$BASE" -- 'core/tests/harness/*.cpp' 'core/tests/harness/*.hpp' \
  'core/tests/harness/*.inc' | harness_msgs > "$TMP/h.before"
cat core/tests/harness/*.cpp core/tests/harness/*.hpp core/tests/harness/*.inc \
  2>/dev/null | harness_msgs > "$TMP/h.after"
echo "5. HARNESS MESSAGES (the whole of core/tests/harness as ONE bag)"
echo "   before=$(wc -l < "$TMP/h.before" | tr -d ' ')  after=$(wc -l < "$TMP/h.after" | tr -d ' ')"
echo "   REMOVED:"
comm -23 "$TMP/h.before" "$TMP/h.after" | sed 's/^/     /'
echo "   (nothing above = no harness refusal and no harness message disappeared)"
echo

# --- 6. of the REMOVED strings, which were EXTENDED rather than deleted? ----
# A usage line or a CSV header that gains a column is a string that "disappears"
# and is not an assertion that stopped being made. Rather than hand-annotate the
# two this task produces — which would hide the next one — every removed harness
# string is checked for a SUPERSET still present in the after set. A string with
# a superset was extended; a string without one is a genuine deletion and is the
# only kind that matters.
echo "6. THE REMOVED HARNESS STRINGS, TRIAGED"
if [ ! -s "$TMP/h.removed" ]; then
  comm -23 "$TMP/h.before" "$TMP/h.after" > "$TMP/h.removed"
fi
if [ ! -s "$TMP/h.removed" ]; then
  echo "     nothing was removed"
else
  while IFS= read -r line; do
    inner=$(printf '%s' "$line" | sed -e 's/^"//' -e 's/"$//' -e 's/\\n$//')
    prefix=$(printf '%s' "$inner" | cut -c1-20)
    if grep -qF -- "$inner" "$TMP/h.after"; then
      echo "     EXTENDED (a superset is still present): $line"
    elif [ -n "$prefix" ] && grep -qF -- "$prefix" "$TMP/h.after"; then
      # The string was REWRITTEN in place: its first 20 characters still occur,
      # so the line still exists and says something else. A usage line that
      # gained an option lands here. It is not an assertion that stopped being
      # made, but it does want a human eye, so it is called out separately
      # rather than folded in with the clean case.
      echo "     REWRITTEN (its first 20 chars still occur — read it): $line"
    else
      echo "     *** GENUINELY DELETED ***: $line"
    fi
  done < "$TMP/h.removed"
fi
