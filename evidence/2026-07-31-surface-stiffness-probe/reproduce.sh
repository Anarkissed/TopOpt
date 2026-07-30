#!/usr/bin/env bash
# Reproduce the surface-stiffness probe measurements
# (docs/handoffs/2026-07-31-surface-stiffness-probe.md).
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang; library
# Release (-O3), harness -O2. Everything is deterministic (no RNG, no threads
# in the harness accumulations; the production solver paths are the
# bit-identical-across-threads kernels): the CSVs reproduce byte-for-byte.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-31-surface-stiffness-probe
mkdir -p "$EV"

# 1. Build the production library (UNMODIFIED — this probe changes no
#    production file) and the pinning unit test.
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt test_surface_stiffness_model -j

# 2. The unit test that pins the harness numerics to production arithmetic:
#    general-D integrator == hex8_stiffness_cubic / hex8_stiffness
#    bit-for-bit, rod-Voigt smear == analytic, embedded bar == pin-jointed
#    bar, harness assembled energy == production fea_solve energy.
./core/build/test_surface_stiffness_model

# 3. The probe: K1 strut-resolved reference (resolution ladder), K2 Route A
#    (iso / cubic / full-anisotropic smear), K3 Route B (embedded bars),
#    K4 graded skin radius, K5 solid shell. CSVs land in $EV.
c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
    -I /opt/homebrew/include/eigen3 \
    core/tests/harness/surface_stiffness_probe.cpp core/build/libtopopt.a \
    -o core/build/surface_stiffness_probe
./core/build/surface_stiffness_probe all "$EV" | tee "$EV/probe_all.log"

# 4. Determinism: a full rerun into a fresh directory must reproduce every CSV
#    byte-for-byte (the log differs only in wall-clock timings, so it is
#    excluded from the comparison).
RERUN=$(mktemp -d)
./core/build/surface_stiffness_probe all "$RERUN" > "$RERUN/probe_all.log" 2>&1
for f in k1_reference.csv k2_k3_routes.csv k2b_corrected_base.csv \
         k4_grading.csv k5_shell.csv; do
  cmp "$EV/$f" "$RERUN/$f" && echo "byte-identical: $f"
done
rm -rf "$RERUN"
