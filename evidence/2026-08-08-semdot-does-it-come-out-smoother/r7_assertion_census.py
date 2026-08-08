#!/usr/bin/env python3
"""R7 — ASSERTION-MESSAGE CENSUS, not a name grep.

The bar is "never weaken or delete an assertion", and counting `assert(` would
pass a diff that renamed one and silently dropped another. So this censuses the
MESSAGE TEXT of every assert(), static_assert() and throw in core/, at the base
commit and on the working tree, and reports deletions, count drops and additions.

It is comment-stripped and MULTI-LINE aware on purpose: this codebase's assertion
messages routinely start on the line after the `assert(`, and adjacent string
literals are concatenated by the compiler. A line-oriented grep sees neither, and
would have reported this branch's own new refusals as "no messages added" — which
is how a census lies.

  ./r7_assertion_census.py [base-ref]      (default: main)
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EV = Path(__file__).resolve().parent
BASE = sys.argv[1] if len(sys.argv) > 1 else "main"

SRC_GLOB = ("core/include", "core/src")
STRIP_BLOCK = re.compile(r"/\*.*?\*/", re.S)
STRIP_LINE = re.compile(r"//[^\n]*")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
OPENER = re.compile(r"\b(?:assert|static_assert)\s*\(|\bthrow\s+[A-Za-z_][A-Za-z_0-9:]*\s*\(")


def strings_in_assertions(text):
    """Every string literal lexically inside an assert / static_assert / throw
    call, with adjacent literals concatenated as the compiler concatenates them."""
    text = STRIP_BLOCK.sub(" ", text)
    text = STRIP_LINE.sub(" ", text)
    out = []
    for m in OPENER.finditer(text):
        depth = 1
        i = m.end()
        n = len(text)
        parts = []
        while i < n and depth:
            c = text[i]
            if c == '"':
                sm = STRING.match(text, i)
                if not sm:
                    break
                parts.append(sm.group(0)[1:-1])
                i = sm.end()
                continue
            if c == "'":
                i += 2 if i + 1 < n and text[i + 1] != "\\" else 3
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        joined = "".join(parts)
        joined = " ".join(joined.split())
        if joined:
            out.append(joined)
    return out


def census_worktree():
    counts = {}
    for d in SRC_GLOB:
        for p in sorted((ROOT / d).rglob("*")):
            if p.suffix not in (".hpp", ".cpp"):
                continue
            for s in strings_in_assertions(p.read_text(errors="replace")):
                counts[s] = counts.get(s, 0) + 1
    return counts


def census_ref(ref):
    files = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref, "core/include", "core/src"],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    counts = {}
    for f in sorted(files):
        if not f.endswith((".hpp", ".cpp")):
            continue
        blob = subprocess.run(["git", "show", f"{ref}:{f}"], cwd=ROOT,
                              capture_output=True, text=True, check=True).stdout
        for s in strings_in_assertions(blob):
            counts[s] = counts.get(s, 0) + 1
    return counts


base = census_ref(BASE)
branch = census_worktree()

lines = []
lines.append(f"=== R7 — assertion / static_assert / throw MESSAGE census ===")
lines.append(f"base ref   {BASE}")
lines.append(f"base       {len(base)} distinct messages, "
             f"{sum(base.values())} occurrences")
lines.append(f"branch     {len(branch)} distinct messages, "
             f"{sum(branch.values())} occurrences")
lines.append("")

deleted = sorted(set(base) - set(branch))
lines.append("--- PRESENT AT BASE, ABSENT ON THE BRANCH (deletions) ---")
lines += [f"  DELETED  {s}" for s in deleted]
if not deleted:
    lines.append("  (none — nothing was deleted)")
lines.append("")

weakened = sorted((s, base[s], branch[s]) for s in set(base) & set(branch)
                  if branch[s] < base[s])
lines.append("--- OCCURRENCE COUNT DROPPED (weakenings) ---")
lines += [f"  WEAKENED base={b} branch={n}  {s}" for s, b, n in weakened]
if not weakened:
    lines.append("  (none — no message lost an occurrence)")
lines.append("")

added = sorted(set(branch) - set(base))
lines.append("--- ADDED ON THE BRANCH ---")
lines += [f"  ADDED    {s}" for s in added]
if not added:
    lines.append("  (none)")

text = "\n".join(lines) + "\n"
(EV / "r7_assertion_census.txt").write_text(text)
print(text)
sys.exit(1 if (deleted or weakened) else 0)
