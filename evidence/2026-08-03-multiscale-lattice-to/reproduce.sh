#!/bin/sh
# reproduce.sh — task multiscale-lattice-to (2026-08-03)
#
# Everything below is deterministic: no RNG, no threading in any measurement loop,
# and the two M2 runs are executed SEQUENTIALLY on an otherwise idle host so the
# wall numbers compare like for like (PR 277's discipline; host_*.txt records the
# load average either side of each run).
#
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, library Release.
# Run from the repo root.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-03-multiscale-lattice-to"
cd "$ROOT"

# ── 0. build ────────────────────────────────────────────────────────────────
cmake -S core -B build >/dev/null
cmake --build build -j10

# ── 1. the correctness bars: C(rho), its sensitivities against central
#       differences, the exact three-block decomposition, and the feasible-set
#       projection with its charge (unit test; registered in ctest as
#       `multiscale_material`).
./build/test_multiscale_material | tee "$EV/unit_multiscale_material.txt"

# ── 2. M6 / M7 / M8 — the accelerators, the cost and the determinism of a
#       multiscale DESIGN LOOP (harness; the production library is linked
#       unmodified and nothing is armed that production does not arm).
c++ -std=c++17 -O2 -I core/include -I core/src \
    core/tests/harness/multiscale_to_probe.cpp build/libtopopt.a \
    -o build/multiscale_to_probe
./build/multiscale_to_probe all "$EV" | tee "$EV/probe_m6_m7_m8.txt"

# ── 3. M2 / M3 / M4 / M5 — THE MAINTAINER'S PART, END TO END, BOTH WAYS.
#       job_twostep.json is the maintainer's captured job document VERBATIM
#       (from ~/.topopt-worker/95f4130119414636 — the run that produced the
#       0 / 82 / 472 latticed voxels this task exists to fix).
#       job_multiscale.json is the SAME document with ONE key added:
#         "lattice": { ..., "multiscale": true }
#       Takes roughly an hour per run on the machine of record.
sh "$EV/run_m2.sh"

# ── 4. M1 — OFF IS BYTE-IDENTICAL. Stash the branch, rebuild, rerun the same
#       fixture, and compare sha256 of report.json / fields.bin / the meshes.
sh "$EV/m1_byteid.sh"

# ── 5. the full core suite.
cd build && ctest --output-on-failure 2>&1 | tail -40
