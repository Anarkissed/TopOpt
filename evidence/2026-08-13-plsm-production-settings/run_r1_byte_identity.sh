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
# ★★★ THIS SCRIPT PASSED VACUOUSLY ONCE, FOR TWO INDEPENDENT REASONS, AND BOTH
# ARE GUARDED BELOW. It reported BYTE-IDENTICAL on design.bin, report.json and
# every mesh. It had measured nothing.
#
#   (1) ★ `cmake --build build --target topopt-cli` IS A SILENT NO-OP. The CMake
#       target is `topopt_cli`; `topopt-cli` is the OUTPUT FILE in the build
#       directory, so make finds no rule, sees the file, calls it up to date and
#       exits 0. NEITHER side was rebuilt — both runs used a binary built before
#       the script started. This is a documented trap in this repository and it
#       still cost a 3.5-hour cycle, because the command was INHERITED with the
#       script rather than typed.
#
#   (2) ★ THE CLI HAS NO SIMP ROUTE. `core/src/cli/main.cpp` (~line 429) sets
#       `job.has_plsm = true; job.plsm_enabled = true` unconditionally on `run`,
#       and REFUSES `plsm.enabled: false` outright. So this script's original
#       premise — "the job carries no plsm block, therefore PlsmMode::Off holds"
#       — is FALSE. A job document cannot select SIMP through this binary.
#
# ★ SO THE COMPARISON IS RE-AIMED, AND FOR THIS TASK IT IS STRONGER. BEFORE is
# the base binary on his job, which that binary runs with the OLD PLSM defaults
# (H_eta, eta = 2, the continuum weight, cap 60, no probe). AFTER is the NEW
# binary on the same job with those settings PINNED EXPLICITLY. If the two agree
# byte for byte then:
#
#   ★★ EVERY DIFFERENCE THIS TASK PRODUCES COMES FROM A DEFAULT AND NOT FROM AN
#      UNINTENDED CHANGE TO THE MACHINERY — the new paths are genuinely opt-in,
#      and the old path still computes exactly what it computed.
#
# ★ AND SIMP's OWN BYTE-IDENTITY IS NOT THIS SCRIPT'S TO PROVE. `main.cpp` says
# so: `run_job` and `minimize_plastic` keep `PlsmMode::Off`, and "22 test files
# call them IN-PROCESS with values pinned from SIMP designs ... those tests are
# the evidence that the SIMP code is unmoved." That evidence is the ctest suite,
# not a CLI run that cannot reach the path.
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
# ★ THE STEP TRAVELS WITH THE JOB. A job document names its model RELATIVE TO
# ITS OWN DIRECTORY, so writing the pinned copy into $SCRATCH without the
# STEP beside it makes the model unresolvable — which is exactly what the
# first attempt did, and `set -e` correctly aborted rather than producing
# half a comparison. The original cannot be edited in place: the BEFORE
# checkout would delete it.
cp "$BAKE/M2_verticalStand.step" "$SCRATCH/"
python3 "$HERE/r1_pin_job.py" "$JOB" "$SCRATCH/r1_pinned.json"
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt_cli > /dev/null
# ★ THE BUILD GUARD. Hash the binary on each side and REFUSE if they match —
# that is the silent-no-op failure this script already shipped once, and it must
# be impossible to pass rather than merely unlikely.
HASH_AFTER=$(shasum -a 256 build/topopt-cli | cut -d" " -f1)
echo "AFTER  binary $HASH_AFTER"
rm -rf "$SCRATCH/r1_after"
# ★ NO --threads ON EITHER SIDE. The GenEO coarse space is a DOMAIN
# DECOMPOSITION — the matrix-free APPLY is bit-identical for any thread count,
# but a decomposition need not be, so comparing two runs at different counts
# would test the wrong thing. Both sides run at production_matfree_thread_count()
# and only the SOURCE differs.
./build/topopt-cli run "$SCRATCH/r1_pinned.json" --out "$SCRATCH/r1_after" --materials "$MATS" \
    > "$LOGS/after.log" 2>&1

# BEFORE — the pre-task commit, in the SAME folder and the SAME build directory.
git checkout --detach "$BASE" > "$LOGS/checkout.log" 2>&1
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt_cli > /dev/null
HASH_BEFORE=$(shasum -a 256 build/topopt-cli | cut -d" " -f1)
echo "BEFORE binary $HASH_BEFORE"
if [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then
  echo "FATAL: the BEFORE and AFTER binaries are the SAME FILE. The rebuild did"
  echo "       not happen, so a PASS below would mean nothing. Refusing."
  git checkout "$BRANCH" >> "$LOGS/checkout.log" 2>&1
  exit 2
fi
rm -rf "$SCRATCH/r1_before"
./build/topopt-cli run "$JOB" --out "$SCRATCH/r1_before" --materials "$MATS" \
    > "$LOGS/before.log" 2>&1 || true

# Restore, and rebuild so the tree is left exactly as it was found.
git checkout "$BRANCH" >> "$LOGS/checkout.log" 2>&1
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt_cli > /dev/null

{
  echo "== R1 — BYTE-IDENTICAL WHERE NOTHING SHOULD CHANGE =="
  echo
  echo "One folder, one build directory, two binaries:"
  echo "  BEFORE  $BASE (the merge-base with main), checked out in place"
  echo "  AFTER   $BRANCH, with the OLD defaults PINNED in the plsm block"
  echo "  binaries $HASH_BEFORE vs $HASH_AFTER (checked distinct above)"
  echo "His own job document; the CLI forces the parametric path either way."
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
