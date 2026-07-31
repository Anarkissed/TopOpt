#!/bin/sh
# Reproduce the active-domain-disarm evidence
# (handoff docs/handoffs/2026-08-01-active-domain-disarm.md).
#
# Machine of record: Apple M2 Pro (6P + 4E), macOS, Release (-O3 -DNDEBUG),
# matrix-free threads pinned to the P-core count (the 132 pin).
#
# CG-iteration counts, gate verdicts, margins, latch iterations, escape counts,
# resolved bands and every |drho| here are DETERMINISTIC and reproduce to the
# digit. WALL CLOCK does not: run the wall-sensitive modes on an OTHERWISE IDLE
# machine, and check `uptime` before trusting a wall number (several of the
# captures in this directory were taken while another worktree ran its full
# ctest suite — each log says so where it matters).
set -e
cd "$(dirname "$0")/../.."

EV=evidence/2026-08-01-active-domain-disarm

# 1. Build the library + the test suite.
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j10

# 2. The full CTest suite (T5) — the disarm's CI face is test_production_parity,
#    which asserts the named constant is 0 and that a real production ladder ran
#    every rung with band 0 while STILL writing the active_domain_* observability.
( cd build && ctest --output-on-failure )

# 3. The measurement harness (standalone; not a CTest target).
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
  core/tests/harness/ad_disarm_gate.cpp build/libtopopt.a -o /tmp/addg

#    dims     — which grids can even carry an odd axis (cheap, seconds)
#    gate     — T2: the full gate table, OFF vs ON vs the 1e-9 control, x2 each
#    padinert — is the odd-axis parity pad inert on the AD fixture class?
#    odd      — the class the pad actually rescued: 2x2 pad x AD
#    stag     — the +26% coin-flip regime re-measured today, AD off vs on
TOPOPT_ADD_DIR=$PWD/$EV /tmp/addg dims     | tee $EV/dims.log
TOPOPT_ADD_DIR=$PWD/$EV /tmp/addg gate     | tee $EV/gate_table.log
TOPOPT_ADD_DIR=$PWD/$EV /tmp/addg padinert | tee $EV/pad_inert.log
#    `odd` and `stag` were CUT during the original capture (the host went to load
#    535 under three other worktrees' solver suites). Neither is load-bearing —
#    see the handoff's T3 section. Take them on an IDLE host:
TOPOPT_ADD_DIR=$PWD/$EV /tmp/addg odd 25   | tee $EV/odd_axis.log
TOPOPT_ADD_DIR=$PWD/$EV /tmp/addg stag 12  | tee $EV/stagnation.log

# 4. T4 — the observability survives the disarm, proven on a REAL CLI run:
#    run_info.json must still carry every active_domain_* field, now recording
#    the disarmed posture (band 0, resolved [0,...], no latch, no escapes,
#    active fraction 1.0) rather than omitting them.
mkdir -p /tmp/ad_disarm_cli && cp core/tests/fixtures/demo/l-bracket.step /tmp/ad_disarm_cli/
cp $EV/job_ad_disarm.json /tmp/ad_disarm_cli/job.json
( cd /tmp/ad_disarm_cli && "$OLDPWD/build/topopt-cli" run job.json --out out )
grep -A 8 '"active_domain_band"' /tmp/ad_disarm_cli/out/run_info.json
