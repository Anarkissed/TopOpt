#!/usr/bin/env bash
# Reproduce the GenEO production-arming evidence (handoff 2026-07-29-geneo-arming).
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, -O2 harnesses /
# -O3 Release library. CG-iteration counts, actions, dims, verdicts and checksums
# are deterministic; wall clock is reported but NOT load-bearing.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-29-geneo-arming
mkdir -p "$EV"

# 1. Build the ARMED library (harness build: OCCT off, tests off).
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build --target topopt -j

# 2. Harnesses.
CXX="c++ -std=c++17 -O2 -I core/include -DSETTINGS_RULES_PATH=\"\\\"$PWD/core/src/settings/rules.json\\\"\""
eval $CXX core/tests/harness/geneo_arming_gate.cpp core/build/libtopopt.a -o core/build/geneo_arming_gate
eval $CXX core/tests/harness/geneo_arm_identity_probe.cpp core/build/libtopopt.a -o core/build/geneo_arm_identity_probe
eval "$CXX -I core/src -I /opt/homebrew/include/eigen3" \
  core/tests/harness/geneo_twolevel_probe.cpp core/build/libtopopt.a -o core/build/geneo_twolevel_probe

G=./core/build/geneo_arming_gate

# 3. A1 — byte-identity at LIBRARY defaults, armed build vs stashed pre-change
#    build (three ladders incl. the matfree-MG fallback straight through the
#    edited mf_cg_solve loop).
./core/build/geneo_arm_identity_probe | tee "$EV/A1_after.txt"
git stash push -m geneo-arming-a1 -- core/CMakeLists.txt core/include/topopt/fea.hpp \
  core/include/topopt/observability.hpp core/include/topopt/production.hpp \
  core/include/topopt/simp.hpp core/src/cli/run_job.cpp core/src/fea/matfree.cpp \
  core/src/fea/multigrid.cpp core/src/simp/minimize_plastic.cpp \
  core/src/simp/observability.cpp core/src/simp/production.cpp core/src/simp/simp.cpp \
  core/tests/validation/test_production_parity.cpp
cmake -S core -B core/build-pre -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build-pre --target topopt -j
eval $CXX core/tests/harness/geneo_arm_identity_probe.cpp core/build-pre/libtopopt.a -o core/build-pre/gai_pre
./core/build-pre/gai_pre | tee "$EV/A1_before.txt"
git stash pop
diff "$EV/A1_before.txt" "$EV/A1_after.txt" && echo "A1: BYTE-IDENTICAL"

# 4. The measurement campaign (IDLE HOST for anything whose wall you care about;
#    the CG counts are deterministic either way).
TOPOPT_GA_DIR=$PWD/$EV $G healthy 60           | tee "$EV/healthy.log"      # A7
TOPOPT_GA_DIR=$PWD/$EV $G interaction 200      | tee "$EV/interaction.log"  # ****
TOPOPT_GA_DIR=$PWD/$EV $G stag 12              | tee "$EV/stag.log"         # **** recycling-wrap regime
TOPOPT_GA_DIR=$PWD/$EV $G gate                 | tee "$EV/gate.log"         # A3 + A4
TOPOPT_GA_DIR=$PWD/$EV $G amort 12             | tee "$EV/amort.log"        # A6
TOPOPT_GA_DIR=$PWD/$EV $G fast 8               | tee "$EV/fast.log"         # A6 fast-motion
TOPOPT_GA_CELL=2 TOPOPT_GA_DIR=$PWD/$EV $G fast 6 | tee "$EV/fast_cell2.log"
TOPOPT_GA_DIR=$PWD/$EV $G mem 8                | tee "$EV/mem.log"          # A5

# 5. The ARMED path on the REAL developed stagnating rung (the phase-2 P2
#    fixture, 40x32x40): plain baseline first (also develops + caches the field),
#    then the armed run (TL_GENEO=1 arms the internal provider on the baseline
#    column; read THAT column, the hook column is phase-2 apparatus).
STAG20="TL_ARM=20 TL_SPAN=20 TL_NY=8 TL_T=4 TL_ITERS=18 TL_MAXIT=120000 TL_SNAPS=3"
env $STAG20            ./core/build/geneo_twolevel_probe p2 "$EV" | tee "$EV/p2_plain.log"
env $STAG20 TL_GENEO=1 ./core/build/geneo_twolevel_probe p2 "$EV" | tee "$EV/p2_armed.log"

# 6. Full test tree (parity assertions incl. the GenEO echo + test_geneo).
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j
ctest --test-dir build --output-on-failure 2>&1 | tee "$EV/ctest_full.log"
echo "done — evidence in $EV"
