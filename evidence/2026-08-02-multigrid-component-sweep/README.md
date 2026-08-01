# Evidence — multigrid-component-sweep

Why multigrid stagnates: a sweep of hierarchy depth, smoothing, cycle type and
smoother, measured on a fixture that actually stagnates.

**Result: nothing in the sweep rescues the maintainer's case.** 25 configurations,
zero convergences. Handoff:
`docs/handoffs/2026-08-02-multigrid-component-sweep.md`

---

## Harness

`core/tests/harness/mg_component_sweep.cpp`. Not a CI test, not in CTest, not
linked into any production path. It links the production library and drives the
production solver `fea_solve_mgcg_matfree` through the harness-only tuning
surface `fea_detail::mg_set_tuning` (declared in `core/src/fea/fea_matfree.hpp`,
defined in `core/src/fea/multigrid.cpp`). It restores the shipped recipe between
every cell; `core/tests/unit/test_mg_tuning.cpp` is the tripwire that asserts
every effective default is still its shipped literal.

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build --target topopt -j
c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/mg_component_sweep.cpp core/build/libtopopt.a \
    $(ls /opt/homebrew/lib/libTK*.dylib) -o core/build/mg_component_sweep
```

OCCT is needed only for the `MG_STEP` fixture; the others link without it.

Modes: `stag` (walk a design trajectory under the shipped recipe, with the latch
live), `sweep` (the A-E grid on one field), `healthy` (the same grid on a
well-connected field), `rescue` (apply every lever on top of a stagnating
configuration), `det` (byte-identical rerun), `latch`.

## Regenerating each file

The developed density trajectories are cached to `.bin` files beside these
outputs. **Those caches are NOT committed** — together they were ~190 MB. The
first run of each command below re-develops the fixture (cost noted) and writes
its cache; later runs hit the cache and are fast.

| file | command | develop cost |
| --- | --- | --- |
| `stag_stepbox.txt` | `MG_STEP=core/tests/fixtures/demo/l-bracket.step MG_RES=32 mg_component_sweep stag <dir>` | **69 min** |
| `sweep_stagnating.txt` / `.csv` | same env + `MG_SNAP=2 MG_MAX_DIRECT=40000 MG_REPEATS=2 … sweep <dir>` | cached |
| `rescue_stagnating.txt` | same env + `MG_SNAP=2 MG_MAX_DIRECT=40000 … rescue <dir>` | cached |
| `stag_occhole.txt` | `MG_OCCHOLE=1 … stag <dir>` | 7 min |
| `sweep_occhole.txt` | `MG_OCCHOLE=1 … sweep <dir>` | cached |
| `stag_occhole64.txt`, `stag_trajectory_occhole64.csv` | `MG_OCCHOLE=1 MG_NX=64 MG_NYY=32 MG_NZ=64 MG_MAXIT=25 … stag <dir>` | 10 min |
| `sweep_occhole64.txt` | same + `MG_MAX_DIRECT=20000 MG_REPEATS=3 … sweep <dir>` | cached |
| `rescue.txt` | same + `MG_MAX_DIRECT=20000 … rescue <dir>` | cached |
| `sweep_healthy.txt` | `MG_HX=32 MG_HY=16 MG_HZ=32 … healthy <dir>` | none |
| `sweep_healthy64.txt` | `MG_HX=64 MG_HY=32 MG_HZ=64 MG_MAX_DIRECT=20000 … healthy <dir>` | none |
| `stag_synthetic48.txt`, `stag_trajectory_synthetic48.csv` | `MG_ITERS=40 MG_VF=0.15 MG_HOLE=0.35 … stag <dir>` | 85 s |
| `det.txt` | `MG_OCCHOLE=1 MG_NX=64 … MG_DET_CFG="point-block w0.6" … det <dir>` | cached |

## The fixtures

**The stagnating one (`MG_STEP`).** PR 273's `ladder32.json`
(`evidence/2026-08-02-iteration-phase-timing/ladder32.json`) reassembled from the
same public pieces `run_job` uses: `l-bracket.step` at resolution 32,
`fixture_faces` = every cylindrical face of radius 2.5 mm (the two Ø5 screw
holes), gravity −Z at 9810 mm/s², whole-domain design box
`[-35,-27.5,-6]..[45,27.5,64]` with `freeze_imported_part` false, ladder
`[0.68, 0.52, 0.38, 0.26]`, `simp.max_iterations` 16. **Reproduces to the grid**
— solved grid 48×32×40, latch fires at design iteration 3, same early abort.
The sweeps target `MG_SNAP=2`, a field the shipped recipe is measured to stagnate
on; snapshots after the latch fires carry no evidence, because multigrid is never
attempted on them.

**`occ0.4+hole` (`MG_OCCHOLE`).** A whole-domain design box with a rectangular
through-hole, developed down the production reduction ladder with the production
solver and updater — the fixture `conditioning_probe.cpp` is built around. Does
NOT stagnate today at either size, which is itself reported (see the handoff §1).
Used for the depth study, where it stagnates only when forced one level deeper
than the builder chooses.

**Healthy (`healthy`).** A well-connected, domain-filling cantilever at ρ = 0.6.

GenEO and Krylov recycling are disabled for every measurement — including during
each develop — so the trajectory and the sweep both measure multigrid alone.

## Measurement discipline

* **Iterations AND wall, always separate**, with the hierarchy build reported
  apart from the cycle loop. A configuration that cuts cycles and raises wall is
  printed as a LOSS.
* **Shared host.** Three other campaigns ran concurrently; load averages 29–262
  on 10 logical cores, printed into every sweep file at start and end. Defences:
  the deterministic `matvecs` column, round-robin repeats keeping the fastest
  repeat *whole* (not a column-wise minimum, which would mix phases from
  different repeats), and a stated refusal to rank on wall differences below
  ~1.5×. The headline results are load-independent facts ("stagnates",
  "4,841 applies").
* **Exactness.** Every carrying configuration is compared against the exact
  matrix-free Jacobi-CG field on the same system.

## Bars

| file | bar |
| --- | --- |
| `byteid.txt`, `byteid_job.json` | AB5 — pre/post-change run byte-identical; column-by-column CSV check |
| `ctest.txt` | AB5 — 94 tests, 93 passed; the one failure diagnosed in the handoff §6 |
| `det.txt` | AB8 — byte-identical rerun at the recommendation |

`byteid_job.json` is the committed demo fixture verbatim, with only
`output.mesh_format` switched 3mf→stl (this build has no lib3mf) and the model
path absolutised. **The fixture itself was not modified.**
