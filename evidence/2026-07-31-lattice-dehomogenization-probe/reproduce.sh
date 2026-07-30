#!/usr/bin/env bash
# Reproduce the lattice de-homogenization probe (handoff
# 2026-07-31-lattice-dehomogenization-probe).
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang; library
# Release, harness -O2. Deterministic: no threads (fea_set_matfree_threads(1)),
# no RNG except a fixed-seed integer LCG for the sampled strain states — the
# CSVs reproduce bit-for-bit (see determinism_rerun.sha256).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-31-lattice-dehomogenization-probe
PR255=evidence/2026-07-31-multiscale-lattice-feasibility
mkdir -p "$EV"

# 1. Production library (UNMODIFIED — this probe changes no production file)
#    and the instrument-pinning unit test.
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt test_lattice_dehomog -j8
./core/build/test_lattice_dehomog

# 2. The probe. Phases:
#    selfcheck  instrument honesty (affine patch K=1, superposition, the
#               production rho mapping, the dev/vol bound on mixed states)
#    bulk       periodic-cell law K(rho, state) across the band read from
#               core, vpc study 16..48 (J1/J2/J3/J5)
#    blocks     finite KUBC blocks, interior-cell convergence with N (J1)
#    boundary   free-surface + cut-cell populations (J4), per-cell records
#    fit        law table kfit.csv + power-law fit + residuals (J3)
#    j6         PR 255's certified designs re-gated under the measured law
#               (reads $PR255/p2_field_*.csv, snaps them exactly as the gap
#               probe did, re-runs the REAL analyze_fixed_design)
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/lattice_dehomog_probe.cpp core/build/libtopopt.a \
    -o core/build/lattice_dehomog_probe
./core/build/lattice_dehomog_probe selfcheck "$EV"   | tee "$EV/selfcheck.log"
./core/build/lattice_dehomog_probe bulk      "$EV"   | tee "$EV/bulk.log"
./core/build/lattice_dehomog_probe blocks    "$EV"   | tee "$EV/blocks.log"
./core/build/lattice_dehomog_probe boundary  "$EV"   | tee "$EV/boundary.log"
./core/build/lattice_dehomog_probe fit       "$EV"   | tee "$EV/fit.log"
./core/build/lattice_dehomog_probe j6 "$EV" "$PR255" | tee "$EV/j6.log"

echo "done — evidence in $EV"
