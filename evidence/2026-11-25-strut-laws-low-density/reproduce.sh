#!/usr/bin/env bash
# Reproduce the low-density strut-strength laws (and tensor rows) of bcc, diamond and sc (the maintainer's decision
# 2026-11-24 23:17 EST, "STRENGTH: YES, MEASURE"). The 11-09 recipe
# (evidence/2026-11-09-lattice-type-strut-laws/reproduce.sh), on the rows under each type's 11-09 band floor.
# Machine of record: Apple M2 Pro (10 cores, 16 GB), Apple clang; library Release, probes -O3. Deterministic
# (fea_set_matfree_threads(1), fixed-seed states). Each step's processes run one core each, side by side.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-25-strut-laws-low-density

# 0. Build (the library first from the tree BEFORE the law commit for step 4's "before", then from the law commit).
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_REQUIRE_DEPS=ON   # + the dependency paths of your Mac
cmake --build core/build --target topopt -j8
for p in tensor_library_nine_probe lattice_dehomog_probe; do
  c++ -std=c++17 -O3 -DNDEBUG -I core/include -I /opt/homebrew/include/eigen3 core/tests/harness/$p.cpp \
      core/build/libtopopt.a -framework Accelerate -o core/build/$p
done

# 1. The tensor rows (21 min) and 1b the floor block (18 min); assemble.py prints the rows lattice.cpp carries
#    (kBcc, kDiamond, kSimpleCubic: the rows under the old floors).
$EV/tensor/run_tensor.sh
$EV/tensor/run_tensor_floor.sh
python3 $EV/tensor/assemble.py $EV/tensor

# 2. With those rows in lattice.cpp, rebuild the library and the dehomog probe (as in 0); the new band floors are read
#    from core by the probe ("lo").

# 3. The strut laws (1 h 41 min, the slowest type): selfcheck, bulk, boundary, fit per type. kfit.csv's *_cert rows are
#    the rows strut_strength.cpp carries under the 11-09 floor, verbatim (test_lattice_type_strut_law pins them).
$EV/run_laws.sh
python3 $EV/summary.py $EV                                        # summary.csv: vpc, voxels across, fixtures, growth
python3 $EV/gripcheck.py evidence/2026-11-09-lattice-type-strut-laws $EV   # what sets the cut-layer population
python3 $EV/crosscheck.py $EV evidence/2026-11-09-lattice-type-strut-laws > $EV/crosscheck.log   # published laws

# 4. Before / after on core's cube and plate: margins.cpp linked like test_lattice_strength (its link.txt), once on
#    the library before the law commit (margins/before.csv), once after (margins/after.csv); and the type matrix
#    (test_lattice_types_matrix) before (matrix/before.log), after with builder D's kExpected
#    (matrix/after_with_d_list.log: the six XPASS), and after with them taken off (ctest, tests/ctest.log).
