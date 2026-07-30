#!/usr/bin/env bash
# Reproduce the multiscale-lattice-feasibility probe measurements.
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, harness -O2,
# library from core/build (Release). Everything is deterministic (no RNG, no
# threads in the harness loop): the CSVs reproduce bit-for-bit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-31-multiscale-lattice-feasibility
mkdir -p "$EV"

# 1. Build the production library (UNMODIFIED — this probe changes no
#    production file) and the pinning unit test.
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt test_lattice_material_model -j

# 2. The unit test that pins the harness model to the production library
#    (row transcription == lattice_cubic_tensor, band == lattice_rho_min/max,
#    admissibility, continuity, FD sensitivities).
./core/build/test_lattice_material_model

# 3. PART 1 — the material model bars G1..G5 (CSVs land in $EV):
#    g1 fit + leave-one-out accuracy    g2 admissibility everywhere
#    g3 FD-checked sensitivities        g4 table adequacy (octet decimation)
#    g4b gap severity                   g5 bridge continuity
c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
    core/tests/harness/lattice_material_probe.cpp core/build/libtopopt.a \
    -o core/build/lattice_material_probe
./core/build/lattice_material_probe all "$EV" | tee "$EV/part1_probe.log"

# 4. PART 2 — forbidden-interval feasibility on OCTET (the only generatable
#    topology): SIMP baseline vs s0_plain / s2_gappen / s3_contin on one
#    cantilever fixture; per-iteration traces + in-loop CG counts
#    (p2_trace.csv), final occupancy (p2_occupancy.csv), density histograms
#    (p2_histogram.csv), snap-to-feasible pricing (p2_snap.csv), and the
#    certification gate receipts incl. the E5 refusal (p2_gate_receipts.txt).
#    ~6-7 min on the machine of record (480 assembled Jacobi-CG solves).
c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
    core/tests/harness/lattice_gap_probe.cpp core/build/libtopopt.a \
    -o core/build/lattice_gap_probe
./core/build/lattice_gap_probe "$EV" | tee "$EV/p2_probe.log"

echo "done — evidence in $EV"
