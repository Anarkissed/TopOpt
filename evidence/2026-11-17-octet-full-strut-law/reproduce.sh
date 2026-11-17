#!/usr/bin/env bash
# Reproduce the octet strut law of 2026-11-17 (the FULL octet, the cell the generator lays), the
# 11-09 recipe of evidence/2026-11-09-lattice-type-strut-laws/reproduce.sh with octet through its
# production strut cell. Machine of record: Apple M2 Pro, Apple clang; library Release, probe -O3.
# Single-threaded and deterministic. About 38 min; the boundary phase peaks near 10.4 GB.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-17-octet-full-strut-law

cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
c++ -std=c++17 -O3 -DNDEBUG -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/lattice_dehomog_probe.cpp core/build/libtopopt.a \
    -framework Accelerate -o core/build/lattice_dehomog_probe
# (link the same libraries test_lattice_dehomog links, from its link.txt, if the line
# above is missing any)

mkdir -p "$EV/octet" "$EV/fcc_control"
for ph in selfcheck bulk blocks boundary fit; do
  TOPOPT_DEHOMOG_TYPE=octet ./core/build/lattice_dehomog_probe $ph "$EV/octet" > "$EV/octet/$ph.log" 2>&1
done
# The control: FCC's selfcheck and bulk, byte-identical to the 11-09 evidence.
for ph in selfcheck bulk; do
  TOPOPT_DEHOMOG_TYPE=fcc ./core/build/lattice_dehomog_probe $ph "$EV/fcc_control" > "$EV/fcc_control/$ph.log" 2>&1
done
cmp "$EV/fcc_control/k_exact_bulk.csv" evidence/2026-11-09-lattice-type-strut-laws/fcc/k_exact_bulk.csv
