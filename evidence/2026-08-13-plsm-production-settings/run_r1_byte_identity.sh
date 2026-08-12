#!/bin/sh
# R1 — ★ BYTE-IDENTICAL WHERE NOTHING SHOULD CHANGE, BY CHECKSUM.
#
# The parametric level set is a MODE, and the whole point of a mode is that the
# path nobody selected does not move. "The branch is guarded" is an argument;
# this is the measurement.
#
# ★★ AND THIS TASK NEEDED IT MORE THAN THE ONE THAT WROTE IT, because this task
# changes DEFAULTS rather than adding a branch. A default that leaks is exactly
# what a byte-identity check catches and an argument does not: while wiring item 1
# it turned out `JobDescription` duplicated `PlsmOptions`' defaults as literals,
# so the production edit alone would have been a no-op for every job that carries
# a plsm block. The reverse failure — a PLSM default reaching the SIMP path — is
# what this script rules out.
#
# ★ WHAT IS AND IS NOT EXPECTED TO MOVE. The job document below carries NO "plsm"
# block, so `PlsmMode::Off` holds and every number must be identical. A job that
# DOES carry one is expected to move: that is items 1-3, and the arms measure it.
# The bar is not "nothing changed"; it is "nothing changed where nothing should".
#
# ★ `run_info.json` IS DELIBERATELY NOT IN THE COMPARISON AND THAT IS STATED
# RATHER THAN QUIETLY OMITTED. This task ADDS KEYS to the receipt
# (`plsm_ersatz`, `plsm_stop_reason`, the topology counters, ...), which are
# empty or zero on a SIMP run but are new lines in the file. That is an additive
# record change, not a behaviour change, and folding it into a byte comparison
# would either fail for the wrong reason or force the keys to be conditional —
# which is how a receipt ends up unable to say "this feature did not run".
#
# ★★ ONE FOLDER, TWO BINARIES, AND THAT IS THE BAR. Both are built in the SAME
# build directory from the SAME source folder. Building the two sides in two
# folders would leave a configuration difference (a stale cache, a different
# compiler flag) able to hide inside the comparison, which is exactly what "not
# by construction" is guarding against.
#
# ★ THIS BRANCH'S WORK IS COMMITTED, SO THE BEFORE SIDE IS A CHECKOUT AND NOT A
# STASH — and that distinction is why this script was rewritten. The version it
# came from ran `git stash push -u`, which on a CLEAN tree saves nothing, pops
# something else, and produces a BEFORE side identical to AFTER for the worst
# possible reason: it never went back. It is refused explicitly below.
#
# WHAT IS COMPARED: `design.bin` (every evaluated rung's density field — the
# design itself), `report.json` (every margin, mass and verdict), the exported
# meshes, and every computed column of `iterations.csv`.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
SCRATCH="${SCRATCH:?set SCRATCH to a directory outside the repository}"
cd "$REPO"

MATS="core/src/materials/materials.json"
JOB="$BAKE/job_simp.json"
OUT="$HERE/r1_byte_identity"
# ★ THE INTERMEDIATE LOGS GO TO SCRATCH, NOT TO $OUT, AND THE REASON IS THIS
# SCRIPT'S OWN MECHANISM. `git checkout --detach $BASE` takes the tree back to a
# commit where THIS EVIDENCE DIRECTORY DOES NOT EXIST, so anything written under
# $OUT before the checkout is deleted by it and anything written during it has
# nowhere to land. Only the final verdict is written to $OUT, after the branch is
# restored.
LOGS="$SCRATCH/r1_logs"
mkdir -p "$LOGS"

# ★ REFUSE ON A DIRTY TREE. The BEFORE side is a checkout, so uncommitted work
# would be destroyed — and a script that destroys work to prove a point is worse
# than the point.
if [ -n "$(git status --porcelain)" ]; then
  echo "FATAL: the working tree is dirty. R1 checks out the pre-task commit in"
  echo "       place; commit or stash your own work first. Refusing."
  exit 2
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BASE="$(git merge-base HEAD main)"
# ★ AND REFUSE IF THE TWO SIDES ARE THE SAME COMMIT — a BEFORE that never went
# back is the failure mode this rewrite exists to prevent, and it must be loud.
if [ "$(git rev-parse HEAD)" = "$BASE" ]; then
  echo "FATAL: HEAD is already the merge-base with main. There is nothing to"
  echo "       compare and a PASS here would mean nothing. Refusing."
  exit 2
fi
echo "branch $BRANCH   base $BASE"

# AFTER — this tree, with the whole parametric path present and the mode OFF
# (the job document carries no "plsm" block).
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt-cli > /dev/null
rm -rf "$SCRATCH/r1_after"
# ★ NO --threads ON EITHER SIDE. The GenEO coarse space is a DOMAIN
# DECOMPOSITION — the matrix-free APPLY is bit-identical for any thread count,
# but a decomposition need not be, so comparing two runs at different counts
# would test the wrong thing. Both sides run at production_matfree_thread_count()
# and only the SOURCE differs.
./build/topopt-cli run "$JOB" --out "$SCRATCH/r1_after" --materials "$MATS" \
    > "$LOGS/after.log" 2>&1

# BEFORE — the pre-task commit, in the SAME folder and the SAME build directory.
git checkout --detach "$BASE" > "$LOGS/checkout.log" 2>&1
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt-cli > /dev/null
rm -rf "$SCRATCH/r1_before"
./build/topopt-cli run "$JOB" --out "$SCRATCH/r1_before" --materials "$MATS" \
    > "$LOGS/before.log" 2>&1 || true

# Restore, and rebuild so the tree is left exactly as it was found.
git checkout "$BRANCH" >> "$LOGS/checkout.log" 2>&1
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt-cli > /dev/null

{
  echo "== R1 — BYTE-IDENTICAL WHERE NOTHING SHOULD CHANGE =="
  echo
  echo "One folder, one build directory, two binaries:"
  echo "  BEFORE  $BASE (the merge-base with main), checked out in place"
  echo "  AFTER   $BRANCH, with the parametric path present and PlsmMode::Off"
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
  echo
  echo "-- run_info.json is NOT compared, and the diff is shown instead: this task"
  echo "   ADDS keys to the receipt, which are empty/zero on a SIMP run."
  python3 - "$SCRATCH/r1_before/run_info.json" "$SCRATCH/r1_after/run_info.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
added = sorted(set(b) - set(a))
removed = sorted(set(a) - set(b))
changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
print(f"   keys added   ({len(added)}): {', '.join(added) if added else 'none'}")
print(f"   keys REMOVED ({len(removed)}): {', '.join(removed) if removed else 'none'}")
noisy = {k for k in changed if "ms" in k or "wall" in k or "rss" in k
         or "fingerprint" in k or "seconds" in k}
real = [k for k in changed if k not in noisy]
print(f"   values changed on a SHARED key, excluding clocks "
      f"({len(real)}): {', '.join(real) if real else 'none'}")
print("   ★ 'keys REMOVED: none' and 'values changed: none' is the bar. An added")
print("     key is the receipt learning to say a feature did not run.")
PY
} > "$LOGS/verdict.txt" 2>&1
mkdir -p "$OUT"
cp "$LOGS/verdict.txt" "$LOGS/after.log" "$LOGS/before.log" "$OUT/"
cat "$OUT/verdict.txt"
