#!/bin/sh
# Reproduce the multiscale-production-wiring evidence
# (handoff docs/handoffs/2026-08-01-multiscale-production-wiring.md).
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, Release.
set -e
cd "$(dirname "$0")/../.."

EV=evidence/2026-08-01-multiscale-production-wiring

# 1. Build the library + the test suite.
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build -j

# 2. The unit + parity guards (I1/I4/I5 test faces). Full suite:
( cd core/build && ctest --output-on-failure )

# 3. The measurement harness (I3 gate table + flips, I6 both-regime traces,
#    I7 four-way interaction, I8 apply cost, I9 memory, I10 determinism).
#    Run i8 on an OTHERWISE IDLE machine (it times applies).
c++ -std=c++17 -O2 -I core/include -I core/src -I core/tests/harness \
    core/tests/harness/multiscale_stack_probe.cpp core/build/libtopopt.a \
    -o core/build/multiscale_stack_probe
./core/build/multiscale_stack_probe i6 "$EV"
./core/build/multiscale_stack_probe i7 "$EV"
./core/build/multiscale_stack_probe i3 "$EV"
./core/build/multiscale_stack_probe i8 "$EV"

# 4. The I5 fingerprint negative control (i5_fingerprint_negative_control.txt)
#    is reproduced by compiling out the lattice-field hashing in
#    geneo.cpp:moduli_fingerprint and re-running core/build/test_matfree_cubic:
#    the section-6 assertion must FAIL with geneo_action==1 (silent reuse).

# 5. I1 byte-identity (library default OFF): see i1_stash_rebuild.txt — the
#    checksum procedure is documented there (stash the branch, build main,
#    run the reference lattice certification + a scalar solve, FNV the outputs,
#    unstash, rebuild, re-run, compare).
