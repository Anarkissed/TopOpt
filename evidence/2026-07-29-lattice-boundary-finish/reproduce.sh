#!/usr/bin/env bash
# Reproduce the lattice boundary-finish measurements
# (handoff 2026-07-29-lattice-boundary-finish).
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, -O2.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-29-lattice-boundary-finish
mkdir -p "$EV"

# 1. Build the production library + CLI + unit tests.
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=ON
cmake --build core/build --target topopt topopt_cli test_lattice_gen test_lattice_boundary -j

# 2. Unit gates: golden byte-identity of the legacy path, and the boundary
#    bars incl. the ADVERSARIAL B3 test (must fail vs a centreline clip).
./core/build/test_lattice_gen      | tee "$EV/test_lattice_gen.txt"
./core/build/test_lattice_boundary | tee "$EV/test_lattice_boundary.txt"

# 3. The evidence part (straight edge + 45-degree diagonal edge + 15.000 mm
#    protected bore), real generator, all bars measured from emitted geometry.
#    One process per cell size so B8's ru_maxrss is per-configuration.
c++ -std=c++17 -O2 -I core/include core/tests/harness/lattice_boundary_probe.cpp \
    core/build/libtopopt.a -o core/build/lattice_boundary_probe
P=./core/build/lattice_boundary_probe
$P before   "$EV" 8         > "$EV/before_8mm.txt"           # the OLD behaviour
$P before   "$EV" 4         > "$EV/before_4mm.txt"
$P evidence "$EV" 8 uniform > "$EV/evidence_8mm.txt"         # the boundary finish
$P evidence "$EV" 4 uniform > "$EV/evidence_4mm.txt"
$P evidence "$EV" 2 uniform > "$EV/evidence_2mm.txt"         # B8: RSS flat in size
$P evidence "$EV" 8 graded  > "$EV/evidence_8mm_graded.txt"  # B5 with grading ON
$P evidence "$EV" 4 graded  > "$EV/evidence_4mm_graded.txt"

# 4. B1 — no-lattice jobs byte-identical, proven by STASH-REBUILD checksum.
#    (Run the job on THIS build, stash the change set, rebuild, rerun, compare.)
./core/build/topopt-cli run "$EV/job_nolattice.json" --out "$EV/out_nolattice_after"
git stash push core
cmake --build core/build --target topopt_cli -j
./core/build/topopt-cli run "$EV/job_nolattice.json" --out "$EV/out_nolattice_before"
git stash pop
cmake --build core/build --target topopt_cli -j
shasum -a 256 "$EV"/out_nolattice_after/report.json "$EV"/out_nolattice_after/fields.bin \
              "$EV"/out_nolattice_before/report.json "$EV"/out_nolattice_before/fields.bin \
  | tee "$EV/b1_checksums.txt"

# 5. The REAL run_job lattice path (loadcase + manual bolt keep-out + lattice
#    block): receipt carries the B9 volume accounting; the exported STL is the
#    clipped/skinned composite.
./core/build/topopt-cli run "$EV/job_lattice.json" --out "$EV/out_lattice"

# 6. Full core suite (B1's "Gate-V2 green and unchanged" rides in here).
( cd core/build && ctest -j 8 ) | tee "$EV/ctest.txt"
