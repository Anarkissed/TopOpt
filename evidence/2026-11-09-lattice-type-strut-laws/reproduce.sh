#!/usr/bin/env bash
# Reproduce the strut-strength laws of the other eight lattice types (reviewer's ruling
# 11-08 (B), R10), measured exactly the PR 259 way
# (evidence/2026-07-31-lattice-dehomogenization-probe/reproduce.sh is octet's).
# Machine of record: Apple M2 Pro, Apple clang; library Release, probe -O3.
# Deterministic: fea_set_matfree_threads(1), fixed-seed LCG states. The re-measure below
# reproduced every row it did not touch bit for bit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-09-lattice-type-strut-laws

cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
c++ -std=c++17 -O3 -DNDEBUG -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/lattice_dehomog_probe.cpp core/build/libtopopt.a \
    -framework Accelerate -o core/build/lattice_dehomog_probe
# (link the same libraries test_lattice_dehomog links, from its link.txt, if the line
# above is missing any)

# Every phase for each type: selfcheck (S1-S6), bulk (periodic cell, vpc 16..48), blocks
# (KUBC N-convergence), boundary (sandwich free faces + cut layer at 0.6, every rho of the
# band; an aliased case is re-measured one pitch finer), fit (kfit.csv: the *_cert columns
# are the law strut_strength.cpp carries). One core each; the eight can run in parallel.
for t in sc bcc fcc diamond kelvin rhombic gyroid schwarz_d; do
  mkdir -p "$EV/$t"
  TOPOPT_DEHOMOG_TYPE=$t ./core/build/lattice_dehomog_probe all "$EV/$t" > "$EV/$t/all.log" 2>&1
done
# The committed sc, diamond, rhombic and schwarz_d ran `all` first with the probe before
# the re-measure rule (all.log, *_first_run.csv), then `boundary` + `fit` with it
# (boundary2.log, fit2.log). Running `all` with the committed probe gives the same CSVs.
