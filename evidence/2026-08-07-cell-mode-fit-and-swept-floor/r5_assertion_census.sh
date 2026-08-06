#!/usr/bin/env bash
# R5 — NEVER WEAKEN OR DELETE AN ASSERTION, measured as a SET DIFFERENCE OF MESSAGES.
#
#   BASE_REF=<commit> ./r5_assertion_census.sh
#
# WHY MESSAGES AND NOT FUNCTION NAMES. A renamed test function reads as a deletion and
# a re-ordered file reads as a rewrite; neither is a weakened bar. The MESSAGE a
# failing assertion prints is the bar in the author's own words, so the honest question
# is: which messages exist on origin/main and no longer exist on this branch?
#
# Covers both languages:
#   C++   the CHECK(cond, "msg") harness across core/tests
#   Swift XCTAssert*(..., "msg") across app/TopOptKit/Tests
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_REF="${BASE_REF:-origin/main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pull every double-quoted string that follows a CHECK(/XCTAssert*( comma, from a git
# revision's tree rather than from a checkout, so nothing has to be stashed.
harvest() { # harvest <rev|WORK> <outfile>
  local rev="$1" out="$2"
  : > "$out"
  local files
  if [ "$rev" = "WORK" ]; then
    files=$(cd "$REPO" && find core/tests app/TopOptKit/Tests \
              \( -name '*.cpp' -o -name '*.swift' -o -name '*.hpp' \) | sort)
    for f in $files; do cat "$REPO/$f"; done > "$TMP/all.txt"
  else
    files=$(git -C "$REPO" ls-tree -r --name-only "$rev" -- core/tests app/TopOptKit/Tests \
              | grep -E '\.(cpp|swift|hpp)$' | sort)
    : > "$TMP/all.txt"
    for f in $files; do git -C "$REPO" show "$rev:$f" >> "$TMP/all.txt"; done
  fi
  # The message is the LAST quoted run on the assertion's argument list; assertions
  # here are written across lines, so join the file first and then extract.
  python3 - "$TMP/all.txt" "$out" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Join C++ adjacent string literals: "a" "b" -> "ab"
src = re.sub(r'"\s*\n\s*"', '', src)
# Swift's + concatenation across lines, same idea.
src = re.sub(r'"\s*\n\s*\+\s*"', '', src)
msgs = set()
for m in re.finditer(r'(CHECK|XCTAssert\w*|XCTFail|XCTUnwrap)\s*\((.*?)\)\s*[;\n]',
                     src, re.S):
    args = m.group(2)
    q = re.findall(r'"((?:[^"\\]|\\.)*)"', args)
    if q:
        s = q[-1].strip()
        # Skip literals that are obviously data rather than a bar's wording.
        if len(s) >= 12 and " " in s:
            msgs.add(s)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(sorted(msgs)) + "\n")
PY
}

harvest "$BASE_REF" "$TMP/base.txt"
harvest WORK        "$TMP/branch.txt"

nb=$(wc -l < "$TMP/base.txt" | tr -d ' ')
nr=$(wc -l < "$TMP/branch.txt" | tr -d ' ')
echo "base ref            : $(git -C "$REPO" rev-parse "$BASE_REF")"
echo "assertion messages on base   : $nb"
echo "assertion messages on branch : $nr"
echo

echo "=== PRESENT ON MAIN, ABSENT ON BRANCH (the only direction that matters) ==="
gone=$(comm -23 "$TMP/base.txt" "$TMP/branch.txt" || true)
if [ -z "$gone" ]; then
  echo "  (none — no assertion message was removed or reworded)"
else
  echo "$gone" | sed 's/^/  - /'
fi
echo

echo "=== ADDED ON BRANCH (informational) ==="
comm -13 "$TMP/base.txt" "$TMP/branch.txt" | sed 's/^/  + /' || true
echo

if [ -z "$gone" ]; then echo "R5: PASS"; else echo "R5: REVIEW THE LIST ABOVE"; fi
