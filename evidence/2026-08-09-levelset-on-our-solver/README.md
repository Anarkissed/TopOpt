# evidence — 2026-08-09-levelset-on-our-solver

A working level-set topology optimizer, in a sandbox target, driven by our own
matrix-free solver, run on his part at rung 0.68. Handoff:
`docs/handoffs/2026-08-09-levelset-on-our-solver.md`.

`./reproduce.sh` regenerates everything here. Unlike the bakeoff this task
follows from, nothing is cloned and no third-party toolchain is installed — the
whole measurement is in this repository.

## the answer, in one table

Rung 0.68, 120 iterations, seeded from his converged SIMP rung. SIMP's and
Gridap's columns are PR 321's, on the same grid on the same machine.

| | ours (level set) | SIMP | Gridap |
|---|---|---|---|
| s / iteration | **25.09** | 13.62 | 277.73 |
| iterations | 120 (budget) | 27 (converged) | 3 (unconverged) |
| total wall, the rung | 3010.5 s | 367.7 s | 1110.9 s |
| cut roughness (deg) | **6.7080 (+11.2%)** | 7.5521 | 4.0156 (+46.9%) |
| CAD amplitude (mm) | 0.4489 (-4.6%) | 0.4293 | 0.7080 |
| margin worst case | **3378.49 (+3.8%)** | 3254.36 | not certified |
| verdict | **ACCEPTED** | ACCEPTED | — |
| achieved vf | 0.681319 | 0.679951 | 0.774451 |
| sub-voxel crossing rms (mm) | 0.2168 (+67%) | 0.1297 | 0.5790 |
| crossings at the edge midpoint | 72.82% | 85.28% | 7.20% |

**1.84x SIMP per iteration and 11.1x faster than Gridap** — so PR 321's 25x was
the library, not the method. Per RUNG we are 8.19x, because the level set had not
converged at 120 iterations where SIMP converged in 27; that is the more
important of the two costs and it is a property of the descent, not of the FEA.

The roughness win is real and is **a quarter of Gridap's**. The last two rows say
why: at `eta = 1 voxel` our field is 91.7% saturated at a band end and carries
10466 fractional samples against Gridap's 100834. The representation is coherent
— reinitialisation bought that, and the crossings moved decisively off SIMP's
85.3% edge-midpoint staircase — but there is less sub-voxel content in it.

Two independent FP64 runs of all 120 iterations gave 25.054 s and 25.088 s per
iteration and **byte-identical** designs, so the optimizer is deterministic and
the timing is not one sample.

## the program

`core/tests/harness/levelset_probe.cpp`, an `EXCLUDE_FROM_ALL` target declared in
`core/CMakeLists.txt`. It writes **no FEA**: `simp_compliance` runs every state
solve and `analyze_fixed_design` the certification — the same two calls the
shipped ladder makes, on the same matrix-free operator, at the same tolerance —
and `build_production_loadcase` supplies the grid, tags, clamped DOFs and nodal
loads. What is new is only the design variable in front of them.

    cmake --build build --target levelset_probe
    ./build/levelset_probe <part.step> <materials.json> <ref/design.bin> <out_dir> \
         [--rung 0.68] [--iters 120] [--eta 1.0] [--cfl 0.4] [--smooth 4] \
         [--seed simp|holes] [--fp32] [--isolate] [--reinit-every N] [--sweeps N]

## the two things that were nearly measured wrong

**1. The solver posture is production's, not an isolated one.** The first cut of
this probe disarmed Krylov recycling and GenEO at startup, copying the
re-certifying probes (`boundary_cell_probe` and friends), which do that for a
real reason: `analyze_fixed_design` is not a pure function of its arguments while
the recycler carries a subspace between solves. On his part that posture cost
**2.5x per iteration** — 28.4 s against the production posture's number — and it
was measuring the handicap, not the level set. His run is precisely the Jacobi
regime the recycler was armed for (`run_info.json`: `krylov_recycling: true`,
`recycle_dim: 16`, `cg_multigrid: false`, `mg_mode: "stagnated-latched"`), where
handoff 133 measured 45.4% fewer CG iterations.

`build_production_loadcase` already runs `configure_production_options`, which
arms the Galerkin block cache, recycling, GenEO and the thread count globally.
The run of record leaves that posture alone, so its seconds-per-iteration is
comparable to SIMP's 11.2 s, which was measured in the same posture. `--isolate`
restores the disarmed posture as a control; it is not the run of record. The
**certification** is isolated separately and in FP64 regardless, exactly as
production isolates it (`ScopedLadderSolverIsolation`, `run_job.cpp:2847`).

**2. The roughness row is produced by the same binary that produced PR 321's.**
`external_field_surface_probe` is invoked, not reimplemented: it reads an
external occupancy on his lattice and puts it through
`extract -> PR 307's CAD/cut classifier -> PR 299's oblique mask ->
deviation_from_cad + dihedral_rms_deg -> PR 306's controls`. The reference
`design.bin` it is given supplies his grid **and contributes the four SIMP rows
itself**, so the run carries its own baseline and no row is compared against a
remembered number. The probe demands an occupancy (0 void, 1 solid, iso between,
background 0) and refuses a raw level set; the ersatz density is exactly that by
construction, which is why `rho.f64` and not `phi` is what is written.

## the six pieces, and which are on their fallback

| piece | what runs | fallback? |
|---|---|---|
| (a) phi | signed distance on his 128 x 31 x 118 grid, negative inside | seeded from his own converged SIMP rung 0.68, the option the task names first |
| (b) ersatz | `rho = rho_min + (1-rho_min) * H_eta(-phi)`, C1 smoothed Heaviside, `H(0) = 0.5` | eta = **1 voxel**, as instructed |
| (c) shape derivative | per-element strain energy density, read off `simp_compliance`'s own `dc/drho_e`, less the volume multiplier | no |
| (d) velocity extension | separable `[1 2 1]/4` smoothing, 4 passes | **yes** — the Gaussian fallback the task names |
| (e) advection | explicit upwind Hamilton-Jacobi, Godunov gradient, CFL 0.4 | no |
| (f) reinitialisation | fast sweeping to `\|grad phi\| = 1`, 8 sweeps, every iteration | no — this is the piece that makes it coherent |
| (g) volume | constant offset on phi, bisected to the rung target each iteration | **yes** — and the task calls it probably the right choice |

Three of seven on their fallback, which is what the task asked for over missing
the morning.

## two stated design choices that a reader must not have to infer

**Penalty 3, the production value, on the ersatz band.** The trajectory and the
certification both use the shipped `SimpParams` (penalty 3, `density_min` 1e-3)
rather than a linear ersatz interpolation, so the certificate is produced by the
same material law as every other certificate here. The cost is that a band voxel
at `rho = 0.5` is stiffness 0.125 rather than 0.5 — a systematic sub-voxel
thinning of the interface, one band wide. It biases the compliance UP relative to
reading the same geometry as binary, so **our compliance and SIMP's converged
compliance are not directly comparable**, and the handoff says so rather than
putting them in the same column as if they were. It is a bias, not an
instability: the volume target is met on the ersatz measure regardless.

**The certified design is the best-compliance iterate, not the last one.** An
explicit Hamilton-Jacobi step can overshoot; certifying an overshoot would report
the scheme's worst moment as its result. `summary.txt` records which iteration it
was.

## the volume bisection recovers what PR 321's SDF arm could not

PR 321's `GTO-SDF` arm reinitialised his rung 0.68 and came out at achieved
`vf = 0.774451` against a requested 0.68 — its rows are geometry at the wrong
volume, which is why that arm reports no compliance and no verdict. The same
effect appears here: at zero offset the seeded level set sits well above target,
and the bisection is what pulls it back onto the rung. The per-iteration
`offset_mm` column in `iterations.csv` is that correction, in millimetres.

## files

| file | what it is |
|---|---|
| `reproduce.sh` | regenerates everything below |
| `s2_ls_fp64.log` | **the run of record**: rung 0.68, FP64, production posture |
| `s2_ls_fp64/summary.txt` | the three numbers section 0 of the handoff states |
| `s2_ls_fp64/iterations.csv` | per iteration: compliance, volume, offset, dt, CG iterations, V-cycle engagement, wall split |
| `s2_ls_fp64/design.bin` | the design, in the shipped container |
| `s2_ls_fp64/rho.f64.gz`, `rho.meta` | the final ersatz occupancy, for `external_field_surface_probe` |
| `s1_ls_fp32.log`, `s1_ls_fp32/` | S1: the same run with the opt-in FP32 V-cycle armed |
| `s1_fp32_is_a_noop.txt` | S1's answer, settled by byte-identity rather than by a wall clock |
| `s3_surface_probe.txt` | the roughness measurement, carrying its own four SIMP baseline rows |
| `s3_levelset_vs_simp.csv` | the row this task adds to PR 306/314/319/321's table |
| `ctest.txt` | R4: the suite at CI's denominator |
| `r3_no_production_change.txt` | R3: the diff against `main` over `core/src`, `core/include`, `app/` |

**To look at the design**, from the repository root:

    cmake --build build --target design_rung_dump
    ./build/design_rung_dump evidence/2026-08-09-levelset-on-our-solver/s2_ls_fp64/design.bin \
        <out_dir> --stl

The probe also writes `levelset.stl` beside `design.bin` on every run. Neither
that nor the raw `rho.f64` is committed — 14 MB and 4 MB of exactly what
`design.bin` already contains — and `rho.f64.gz` is 98 KB, so `reproduce.sh`
gunzips it before the surface probe reads it.

**The FP32 arm's binaries are not committed either**, because they are
byte-identical to the FP64 arm's (sha256 in `s1_fp32_is_a_noop.txt`). Its
`summary.txt` and `iterations.csv` are, because the wall time and the V-cycle
engagement count are what that arm is for.

## the bars

**R1 — it runs and it finishes.** 120 iterations, a design on disk, a wall time.
Twice, byte-identically.

**R2 — our instruments, included not retyped.** `external_field_surface_probe`
is *invoked*; not one line of PR 299/306/307's metrics is restated here. Its
four SIMP rows come from the reference `design.bin` in the same run that measures
ours, so the comparison never leans on a remembered number.

**R3 — the shipped SIMP path is untouched.** `git diff main -- core/src
core/include app/` is **empty** (`r3_no_production_change.txt`). The whole change
is one `EXCLUDE_FROM_ALL` target declaration in `core/CMakeLists.txt` (+14 lines,
nothing removed) and one new file under `core/tests/harness/`. Byte-identity on a
normal run follows from there being no production code to change it.

**R4 — no assertion weakened or deleted.** The diff adds only; no test file is
touched and no `add_test` is added or removed, so the denominator is `main`'s by
construction. `ctest.txt`: **117/117 passed**. That is above CI's 114 because
lib3mf is present on this host — the failure mode handoff
`local-ctest-denominator-is-not-cis` warns about is local having *fewer* tests
than CI, and 117 > 114 rules it out.

**R5 — no unfilled placeholders, no scratch at the repository root.**
