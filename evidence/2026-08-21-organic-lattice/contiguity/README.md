# Contiguity instruments

Probes behind the contiguity findings. CMAKE_BUILD_TYPE=Release, linked against
libtopopt.

- `contig.cpp`      one table for uniform AND graded: segments, length, top-2, top-5,
                    dust, bridges. Written because the first report quoted top-5 for
                    uniform rows and top-2 for graded ones, which made two rows with
                    the same measurements look like different verdicts.
- `lumps2.cpp`      the per-piece breakdown. A component COUNT says nothing on its own:
                    3 mm has 172 pieces and is a good lattice because 170 of them are
                    1.1% of the material.
- `bridgeprobe.cpp` components + bridge fraction, no FEA.
- `growbridge.cpp`  bridge fraction of GROWN geometry across the separation sweep, both
                    sides of the support prune. The unpruned side is read off the
                    returned OrganicLattice (curves + connectors) rather than through a
                    switch that would disarm a printability rule in a production path.
- `segweld.cpp`     tests whether struts crossing WITHOUT a shared node explain the gap
                    between the generator's component count and the beam network's.
                    They do not: segment-level welding adds 8-23 joins.

Build: clang++ -std=c++17 -O2 -framework Accelerate -I core/include <f>.cpp \
       -L core/build -ltopopt -o <f>
