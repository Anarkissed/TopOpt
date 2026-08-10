#!/bin/sh
# R1 — ★ SIMP'S DEFAULT PATH IS BYTE-IDENTICAL, BY CHECKSUM, NOT BY CONSTRUCTION.
#
# The parametric level set is a MODE, and the whole point of a mode is that the
# path nobody selected does not move. "The branch is guarded" is an argument;
# this is the measurement.
#
# ★ ONE FOLDER, TWO BINARIES, AND THAT IS THE BAR. Both binaries are built in the
# SAME build directory from the SAME source folder — `git stash` takes the tree
# back to the pre-task commit, the build directory is rebuilt in place, the run is
# made, and the stash is popped and rebuilt again. Building the two sides in two
# different folders would leave a configuration difference (a stale cache, a
# different compiler flag) able to hide inside the comparison, which is exactly
# what "not by construction" is guarding against.
#
# ★ THE STASH IS NAMED AND POPPED BY NAME. A `git stash push -- <paths>` that
# matches nothing silently pops SOMEONE ELSE'S stash; this uses an unqualified
# `push -u` with a message and verifies that message before popping.
#
# WHAT IS COMPARED: `design.bin` (every evaluated rung's density field, the
# design itself) and `report.json` (every margin, mass and verdict), byte for
# byte, plus every computed column of `iterations.csv`.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
cd "$REPO"

MATS="core/src/materials/materials.json"
JOB="$BAKE/job_simp.json"
OUT="$HERE/r1_byte_identity"
mkdir -p "$OUT"
STASH_MSG="plsm-production-r1-$$"

# AFTER — this tree, with the whole parametric path present and the mode OFF
# (the job document does not carry a "plsm" block).
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt-cli > /dev/null
rm -rf "$SCRATCH/r1_after"
# ★ NO --threads ON EITHER SIDE. The BEFORE binary predates that flag, and more
# to the point the GenEO coarse space is a DOMAIN DECOMPOSITION — the matrix-free
# APPLY is bit-identical for any thread count, but a decomposition need not be, so
# comparing two runs at different counts would test the wrong thing. Both sides
# therefore run at production_matfree_thread_count() and only the SOURCE differs.
./build/topopt-cli run "$JOB" --out "$SCRATCH/r1_after" --materials "$MATS" \
    > "$OUT/after.log" 2>&1

# BEFORE — the pre-task commit, in the SAME folder and the SAME build directory.
git stash push -u -m "$STASH_MSG" > "$OUT/stash.log" 2>&1
if ! git stash list | head -1 | grep -q "$STASH_MSG"; then
  echo "FATAL: the stash at the top is not this script's — refusing to touch it."
  exit 2
fi
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt-cli > /dev/null
rm -rf "$SCRATCH/r1_before"
./build/topopt-cli run "$JOB" --out "$SCRATCH/r1_before" --materials "$MATS" \
    > "$OUT/before.log" 2>&1 || true

# Restore, and rebuild so the tree is left as it was found.
git stash pop >> "$OUT/stash.log" 2>&1
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt-cli > /dev/null

{
  echo "== R1 — SIMP'S DEFAULT PATH IS BYTE-IDENTICAL =="
  echo
  echo "One folder, one build directory, two binaries:"
  echo "  BEFORE  the pre-task commit (git stash), rebuilt in place"
  echo "  AFTER   this tree, with the parametric path present and PlsmMode::Off"
  echo "His own job document, which carries no \"plsm\" block."
  echo
  echo "-- design.bin: every evaluated rung's density field"
  cmp "$SCRATCH/r1_before/design.bin" "$SCRATCH/r1_after/design.bin" \
    && echo "   BYTE-IDENTICAL  ($(wc -c < "$SCRATCH/r1_after/design.bin") bytes)"
  echo
  echo "-- report.json: every margin, mass, verdict and recommended setting"
  cmp "$SCRATCH/r1_before/report.json" "$SCRATCH/r1_after/report.json" \
    && echo "   BYTE-IDENTICAL"
  echo
  echo "-- the exported meshes"
  for f in "$SCRATCH/r1_after"/variant_*.stl; do
    b=$(basename "$f")
    cmp "$SCRATCH/r1_before/$b" "$f" && echo "   $b BYTE-IDENTICAL"
  done
  echo
  echo "-- iterations.csv: every COMPUTED column (wall clocks and memory excluded,"
  echo "   they are wall clocks)"
  python3 - "$SCRATCH/r1_before/iterations.csv" "$SCRATCH/r1_after/iterations.csv" <<'PY'
import sys
a, b = sys.argv[1], sys.argv[2]
def cols(p):
    rows = [l.rstrip("\n").split(",") for l in open(p) if l.strip()]
    head = rows[0]
    drop = {i for i, h in enumerate(head)
            if "_ms" in h or "wall" in h or "rss" in h or "available" in h
            or "compressed" in h or "faults" in h or "swapins" in h}
    return head, [[c for i, c in enumerate(r) if i not in drop] for r in rows]
ha, ra = cols(a)
hb, rb = cols(b)
if ha != hb:
    print("   ★ THE HEADER MOVED — a column was added or removed")
elif ra != rb:
    n = sum(1 for x, y in zip(ra, rb) if x != y)
    print(f"   ★ {n} ROW(S) DIFFER")
    for x, y in zip(ra, rb):
        if x != y:
            print("     before:", ",".join(x))
            print("     after :", ",".join(y))
            break
else:
    print(f"   IDENTICAL across {len(ra) - 1} iterations and "
          f"{len(ha)} columns (minus the timing/memory columns)")
PY
} > "$OUT/verdict.txt" 2>&1
cat "$OUT/verdict.txt"
