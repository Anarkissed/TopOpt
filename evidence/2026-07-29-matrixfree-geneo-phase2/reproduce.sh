#!/usr/bin/env bash
# Reproduce the matrix-free GenEO two-level preconditioner Phase-2 measurements.
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, -O2.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-29-matrixfree-geneo-phase2
mkdir -p "$EV"

# 1. Build the production library (with the DEFAULT-OFF phase-2 hook).
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build --target topopt -j

# 2. Build the harness (links Eigen; the eigensolve/decomposition live here, NOT the lib).
c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/geneo_twolevel_probe.cpp core/build/libtopopt.a \
    -o core/build/geneo_twolevel_probe

P=./core/build/geneo_twolevel_probe

# 3. Modes (CSV + logs land in $EV). The stagnating field is developed through the REAL
#    production ladder once per fixture and cached; later modes reuse the cache.
# The P2 headline fixture (40x32x40, Jacobi ~5.4k) and the amort fixture (32x24x32):
STAG20="TL_ARM=20 TL_SPAN=20 TL_NY=8 TL_T=4 TL_ITERS=18 TL_MAXIT=120000"

$P selfcheck "$EV" | tee "$EV/selfcheck.log"                          # SPD + ablation (near-disconnection)
$P byteid    "$EV" | tee "$EV/byteid.log"                             # P1: hook off => byte-identical + deterministic
env $STAG20 TL_SNAPS=3 $P p2      "$EV" | tee "$EV/p2.log"            # P2: Jacobi-CG vs two-level on the rung
env $STAG20              $P control "$EV" | tee "$EV/control.log"     # P4: negative control + same-answer floor
env $STAG20              $P det     "$EV" | tee "$EV/det.log"         # P8: determinism
env TL_ARM=16 TL_SPAN=16 TL_NY=4 TL_T=4 TL_ITERS=12 TL_MAXIT=40000 TL_GAP=4 \
                         $P amort   "$EV" | tee "$EV/amort.log"       # P6: basis reuse vs rebuild
$P healthy   "$EV" | tee "$EV/healthy.log"                           # P7: where MG carries, two-level is worse
env TL_ARM=16 TL_SPAN=16 TL_NY=4 TL_T=4 TL_ITERS=12 $P p4design "$EV" | tee "$EV/p4.log"  # P4: full-ladder same design (inert where MG carries)
TL_SIZES=24,32,40,48 TL_CELL=4 TL_MAXIT=200000 \
                         $P hard    "$EV" | tee "$EV/hard_scaling.log"# scaling: mode-count independence

# 4. P1 byte-identical vs a stashed PRE-CHANGE build (public-API-only harness):
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/geneo_byteid_xbuild.cpp core/build/libtopopt.a -o core/build/geneo_byteid_xbuild
./core/build/geneo_byteid_xbuild | tee "$EV/byteid_after.txt"        # phase-2 build (hook present, OFF)
git stash push core/src/fea/matfree.cpp core/src/fea/fea_matfree.hpp \
    core/include/topopt/fea.hpp core/src/fea/multigrid.cpp
cmake --build core/build --target topopt -j
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/geneo_byteid_xbuild.cpp core/build/libtopopt.a -o core/build/geneo_byteid_xbuild_pre
./core/build/geneo_byteid_xbuild_pre | tee "$EV/byteid_before.txt"   # PRE-CHANGE build
git stash pop; cmake --build core/build --target topopt -j           # restore phase-2
diff "$EV/byteid_before.txt" "$EV/byteid_after.txt" && echo "P1: BYTE-IDENTICAL"
echo "done — evidence in $EV"
