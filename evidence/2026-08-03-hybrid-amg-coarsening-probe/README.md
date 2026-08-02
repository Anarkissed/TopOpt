# hybrid-amg-coarsening-probe — evidence

Handoff: `docs/handoffs/2026-08-03-hybrid-amg-coarsening-probe.md`

**The question:** PR 280 showed the shipped V-cycle stagnates on the maintainer's
dilute fields and that no component tuning rescues it, diagnosing a COARSE-SPACE
failure. This task tested the natural fix — keep level 0 -> 1 geometric and
matrix-free, build the levels BELOW 1 by algebraic aggregation from A1 (Peetz &
Elbanna's hybrid) — by measuring the coarse space directly before building a
solver on it.

**The answer:** no. The GEOMETRIC LEVEL-1 space captures 1.5954 % of the exact
solution's energy, and every space below it is a subspace, so 1.5954 % is a hard
ceiling. Algebraic aggregation from A1 does capture 1.74x more at matched
dimension — and converges to that same ceiling. The hypothesis is aimed one level
too low. An ALGEBRAIC LEVEL 1 captures 56.3 % and converges in 86 PCG iterations.

## Files

| file | what it is |
| --- | --- |
| `capture_stagnating.txt/.csv` | **AF1/AF2.** Captured-energy fractions on PR 280's stagnating field: geometric levels 1-3, algebraic level 2 swept over theta (smoothed and `P = T`), and the algebraic LEVEL-1 control. |
| `capture_healthy.txt/.csv` | The same instrument on a healthy block (rho 0.6, 32x16x32) — 99.2959 % at level 1. This is what makes the 1.6 % legible. |
| `energy_stagnating.txt/.csv` | WHERE the energy is: 72.2 % at the SIMP void floor, 95.4 % below rho 0.02. Identity check closes to 5.78e-09. |
| `energy_healthy.txt/.csv` | Same sweep on the healthy control: 100 % in rho >= 0.60. |
| `leanconv_stagnating.txt/.csv` | The level-1 capture CASHED: `amg_lean`'s matrix-free hierarchy + PCG over the production reduced operator. 86 iterations, converged, 45.6 MB. |
| `converge_stagnating.txt/.csv` | **AF3/AF4/AF5/AF7.** The hybrid run through the PRODUCTION solver via the coarse-space seam: 6 configurations, 0 convergences, with DOF- and nnz-weighted work, aggregation setup charged separately, and the memory projection to 8.44M DOF. |
| `converge_healthy.txt/.csv` | **AF6.** The same on the healthy control: the hybrid carries but costs 21-42 % more work than geometric. |
| `det.txt` | **AF9.** Same configuration twice: identical coarse dims and field fingerprint `c573782fac60eb3b`. |
| `byteid.txt`, `byteid_job.json` | **AF8.** Stash-rebuild against HEAD (`b06da24`): design/fields/report/loadcase and all three variant STLs IDENTICAL; `iterations.csv` differs in NO non-timing column. |
| `ctest.txt` | **AF8.** 97 tests, 97 passed, including the new `fea_mg_coarse_hook`. |
| `fixture_stag.txt`, `stag_trajectory.csv` | The fixture reproduced to the grid: PR 273's `ladder32.json` rebuilt, solved grid 48x32x40, carried 1 / stagnated 3, latch at design iteration 3, 1,931 s of 1,946.7 s in the Jacobi fallback. |

## Reproducing

The measurements read a cached density trajectory (~40 MB) that is NOT committed.
Build the library and both harnesses, then develop the fixture once:

    cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=ON -DTOPOPT_BUILD_TESTS=OFF
    cmake --build core/build --target topopt -j
    # both probes, linked against the OCCT toolkits the library uses
    c++ -std=c++17 -O2 -I core/include -I core/src -I core/src/fea -I /opt/homebrew/include/eigen3 \
        -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
        core/tests/harness/mg_component_sweep.cpp core/build/libtopopt.a \
        -L/opt/homebrew/lib -lTKDESTEP -lTKXSBase -lTKDE -lTKMesh -lTKTopAlgo -lTKGeomAlgo \
        -lTKPrim -lTKBRep -lTKGeomBase -lTKG3d -lTKG2d -lTKMath -lTKernel \
        -o core/build/mg_component_sweep
    # ... same line with hybrid_amg_probe.cpp -> core/build/hybrid_amg_probe

    D=evidence/2026-08-03-hybrid-amg-coarsening-probe
    MG_STEP=core/tests/fixtures/demo/l-bracket.step MG_RES=32 ./core/build/mg_component_sweep stag $D
    HA_SNAP=2 HA_L1_BUDGET=10 ./core/build/hybrid_amg_probe capture   $D
    HA_SNAP=2 ./core/build/hybrid_amg_probe energy   $D
    HA_SNAP=2 ./core/build/hybrid_amg_probe leanconv $D
    HA_SNAP=2 ./core/build/hybrid_amg_probe converge $D
    HA_SNAP=2 ./core/build/hybrid_amg_probe det      $D
    ./core/build/hybrid_amg_probe capture_healthy $D
    ./core/build/hybrid_amg_probe energy_healthy  $D
    ./core/build/hybrid_amg_probe healthy         $D

The unit tests (including the new `fea_mg_coarse_hook` tripwire) need their own
configure with tests on:

    cmake -S core -B core/build-probe -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=ON -DTOPOPT_BUILD_TESTS=ON
    cmake --build core/build-probe -j && (cd core/build-probe && ctest --output-on-failure)

`HA_SNAP=2` selects the design-iteration snapshot PR 280 swept — a field the
shipped configuration is measured to stagnate on. `HA_L1_BUDGET` bounds the
algebraic-level-1 capture sweep (a smoothed fine-level prolongator's direct
factorisation is the most expensive thing in the probe); cells past the budget
are reported as SKIPPED rather than dropped.

## Host

**The machine was NOT quiet.** Other campaigns ran throughout, including a
`topopt-cli` from an unrelated worktree; the 1-minute load average reached 66 on
10 logical cores, and it is printed at the start and end of every measurement.
Every headline number is load-independent: captured energy is a ratio of two
exact solves, iteration counts and dimensions are exact, and no ranking rests on
a wall difference below about 1.5x.
