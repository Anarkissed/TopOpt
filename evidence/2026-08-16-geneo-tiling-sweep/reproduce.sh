#!/bin/sh
# Regenerates everything in this directory. Nothing is cloned or downloaded; the
# only inputs are his STEP part, his job, and this repository's own sources.
#
# ★ STEPS 1-3 COST NOTHING AND ANSWER §3 OUTRIGHT. Both "while the machine is
# quiet" items turned out to be already measured — `warm_start_coarse` by
# 2026-08-02-warm-start-coarse-experiment (a "DO NOT ARM" recommendation) and
# `matfree_threads` by 2026-07-28-apple-silicon-envelope (the exact 1/2/4/6/8/10
# sweep the task asks for). `s3_extras.md` is the reading, with the line numbers
# corrected. If you only want that, read it and stop.
#
# ★ 6 THREADS, STRICTLY SERIAL. He needs his machine. And read `host_load.txt`
# before any wall figure here: the host was shared with three other worktrees
# throughout (load averages 18-137 on a 10-core box), so NO wall figure is cited
# as evidence anywhere in the handoff. The CG iteration counts and `N_t` are
# deterministic and are the signal.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

# ── 1. R3 — the build, and the build TYPE recorded beside it. An unoptimised
# build is how PR 334 quoted 590.6 s for something that takes 28.0 s.
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build -j6 --target topopt_cli solver_arm_sweep test_geneo
{
  echo "CMAKE_BUILD_TYPE, verified before any wall-clock number is quoted (R3):"
  grep -E "^CMAKE_BUILD_TYPE" build/CMakeCache.txt
  echo
  echo "The optimisation flags actually reaching the compiler:"
  grep -E "^CMAKE_CXX_FLAGS_RELEASE" build/CMakeCache.txt
  echo
  echo "solver_arm_sweep md5 (one binary for every sweep point):"
  md5 -q build/solver_arm_sweep 2>/dev/null || md5sum build/solver_arm_sweep
} > "$HERE/build_type.txt"

# ── 2. R7 — the assertion census. Baselined on HEAD, not `main`; the script
# header explains why that is a correction (this branch is 83 commits ahead).
bash "$HERE/assertion_census.sh" > "$HERE/r7_assertion_census.txt"

# ── 3. R6 — the per-axis tiling assertion, plus every other GenEO guard.
./build/test_geneo > "$HERE/r6_test_geneo.txt" 2>&1

# ── 4. R2 — the host, before the sweep claims it.
{
  date; uptime
  echo "--- concurrent heavy jobs (other agents' worktrees) ---"
  ps -Ao pcpu,pid,command -r | grep -E "topopt-cli|solver_arm_sweep|test_" \
    | grep -v grep | head -12
} > "$HERE/host_load.txt"

# ── 5. §1(a) THE SWEEP — N_t at each tiling, ONE solve per point. This is the
# measurement PR 329 could not finish, and it is what decides §2's outcome.
sh "$HERE/run_nt_triage.sh" | tee "$HERE/nt_triage.txt"
sh "$HERE/collect_triage.sh"

# ── 6. §1(c) THE ARMS — TOTAL CG ITERATIONS, the figure of merit. Deeper than
# the triage; run_arms.sh's header explains why the triage cannot answer this.
sh "$HERE/run_arms.sh" all || true

# ── 7. R2 again — the host at the END of the sweep, so the whole window is on
# the record and not just its start.
{
  echo; echo "=== after the sweep ==="; date; uptime
  ps -Ao pcpu,pid,command -r | grep -E "topopt-cli|solver_arm_sweep|test_" \
    | grep -v grep | head -12
} >> "$HERE/host_load.txt"

# ── 8. the tables.
python3 "$HERE/tables.py" | tee "$HERE/tables.txt"

echo REPRODUCE_DONE
