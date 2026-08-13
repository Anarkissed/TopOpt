#!/bin/sh
# Regenerates everything in this directory. Nothing is cloned and nothing is
# downloaded; the only inputs are his STEP part, his job, this repository's own
# sources, and one artifact already committed here —
# `evidence/2026-08-10-plsm-production/s1_production_run/`, the captured
# production run that §1 and §2 are READ from rather than re-run.
#
# ★ THE READING COMES FIRST AND COSTS NOTHING. `tables.py` alone reproduces the
# GenEO decision log, its arithmetic, and the multigrid latch point — the two
# root causes — from artifacts already in the repository. If you only want the
# diagnosis, run step 1 and stop; it takes under a second.
#
# ★ 6 THREADS, AND STRICTLY SERIAL. He needs his machine. The host was shared
# during the original measurement (host_load.txt records load averages of 22-31
# and other agents' `topopt-cli` processes throughout), so no wall figure in the
# handoff is cited as evidence — the CG iteration counts are deterministic and
# are the signal. See run_arms.sh's header.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

# ── 1. THE DIAGNOSIS, from committed artifacts. No build, no solve.
python3 "$HERE/tables.py" | tee "$HERE/tables.txt"

# ── 2. the binaries. One configure, one build, both targets, so the R2
# byte-identity check below is comparing two binaries from one tree.
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j8 --target topopt_cli solver_arm_sweep test_mg_tuning

# ── 3. R6 — the assertion census. Nothing removed.
bash "$HERE/assertion_census.sh" | tee "$HERE/r6_assertion_census.txt"

# ── 4. R2 — the harness is inert: `--arm base` reproduces `topopt-cli run`,
# and this tree reproduces HIS captured run. Compares the COMMON PREFIX; see the
# script header for why neither a positional zip nor a (rung,iter) key is right.
python3 "$HERE/check_r2.py" | tee "$HERE/r2_byte_identity.txt"

# ── 5. §1(b) TRIAGE — N_t at each tiling, one solve per point. Cheap, and it
# is what decides whether a smaller-basis ARM is worth running at all.
sh "$HERE/run_nt_triage.sh" | tee "$HERE/nt_triage.txt"

# ── 6. THE MECHANISM PROBES. Three solves each; see run_probes.sh for why
# three is the whole question.
sh "$HERE/run_probes.sh" all | tee "$HERE/probes.txt"

# ── 7. THE ARMS. A 4-rung ladder each, capped identically. The long part.
sh "$HERE/run_arms.sh" all

# ── 8. the tables again, now with the arms in them.
python3 "$HERE/tables.py" > "$HERE/tables.txt"
cat "$HERE/tables.txt"

echo REPRODUCE_DONE
