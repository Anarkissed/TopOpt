#!/usr/bin/env bash
# Reproduce the matrix-free-cubic-tensor probe measurements.
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, harness -O3
# (matching the library's Release build), library from core/build (Release).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-30-matfree-cubic-probe
mkdir -p "$EV"

# 1. Build the production library (UNMODIFIED — this probe changes no production file).
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j

# 2. Build the harness (the cubic kernel lives HERE, not in the library).
c++ -std=c++17 -O3 -DNDEBUG -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
    core/tests/harness/matfree_cubic_probe.cpp core/build/libtopopt.a \
    -o core/build/matfree_cubic_probe

# 3. All five bars (CSVs land in $EV):
#    d1 decomposition exactness  d2 apply==assembled + solve==fea_solve_cg_lattice
#    d3 apply-cost ratio          d4 SPD + recycling/multigrid/GenEO engagement
#    d5 all-scalar bit-identity + 8.44M-DOF memory numbers
./core/build/matfree_cubic_probe all "$EV" | tee "$EV/probe_all.log"

# 4. GenEO tiling sensitivity (d4 appendix): probe-sized 4^3 tiles and overlap 2
#    vs the armed production 8^3/ov1 tiling used in the main run.
MC_CORE=4 MC_OV=1 ./core/build/matfree_cubic_probe d4 "$EV" | tee "$EV/d4_core4_ov1.log"
MC_CORE=4 MC_OV=2 ./core/build/matfree_cubic_probe d4 "$EV" | tee "$EV/d4_core4_ov2.log"
echo "done — evidence in $EV"
