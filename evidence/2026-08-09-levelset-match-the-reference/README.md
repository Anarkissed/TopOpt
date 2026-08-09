# evidence — 2026-08-09-levelset-match-the-reference

All five differences from GridapTopOpt implemented on our own solver, in a
sandbox target, on his part at rung 0.68, **at 3 threads throughout**. Handoff:
`docs/handoffs/2026-08-09-levelset-match-the-reference.md`.

`./reproduce.sh` regenerates everything here. Nothing is cloned and no
third-party toolchain is installed.

## the answer, in one table

| | SIMP (3 thr) | run of record | **best operating point** | PR 322 (6 thr) | Gridap |
|---|---|---|---|---|---|
| | | s2, converged | **s6 @ it 20** | | |
| cut roughness (deg) | 7.5521 | 13.0156 (+72.3%) | **8.3451 (+10.5%)** | 6.7080 | 4.0156 |
| whole-mesh roughness | 8.4075 | 10.7063 (+27.3%) | **8.6894 (+3.4%)** | — | — |
| midpoint fraction | 85.28% | **60.96%** | **66.60%** | 72.82% | 7.20% |
| margin worst case | 3254.36 | 3405.33 | **3400.31 (+4.5%)** | 3378.49 | not certified |
| verdict | ACCEPTED | ACCEPTED | **ACCEPTED** | ACCEPTED | — |
| min-feature violations | 5464 | 5194 | **4731** | — | 4547 |
| s / iteration | 11.281 | 22.206 | 24.075 | 25.09 | 277.73 |
| iterations | 27 | 76 (converged) | **20** | 120 (did NOT) | 3 |
| total wall, the rung | 304.6 s | 1687.6 s (5.54x) | **481.5 s (1.58x)** | 3010.5 s | 1110.9 s |

**Stop at iteration 20** and the level set matches SIMP's surface to +3.4%
whole-mesh while carrying +4.5% margin, 19 points better sub-voxel placement and
1.58x SIMP's cost. The margin SATURATES there — 3400.31 at it 20, 3400.29 at
it 30, 3401.08 at convergence — so the last 23 iterations buy +0.02% margin and
cost 16% roughness.

## the three arms, and what each isolates

One instrument, one invocation, four SIMP baseline rows carried in the same run.

| arm | alpha (voxels) | HJ steps | damper | iters | cut (deg) | margin |
|---|---|---|---|---|---|---|
| `s2_levelset` — their rule as written | 2.4 | 6 | — | 76 | 13.0156 | 3405.33 |
| `s5_alpha8` — **alpha ALONE** | 8.0 | 6 | — | 68 | 10.9833 | 3404.00 |
| `s6_corrected` — corrected rule + damper | 9.6 | 24 | 3 fires | 43 | 9.6572 | 3401.08 |

`s5` is the clean single-variable test and recovers 37% of the regression.

## why alpha was wrong, in one table

arXiv 2405.10478 §4.1.6 calls alpha "the so-called REGULARISATION LENGTH SCALE"
and sets it so that "the number of elements over which we regularise the gradient
is increased" with mesh refinement:

    max_steps = floor(order*minimum(el_size)/10)   [DOUBLED in 3D]
    alpha     = 4*max_steps*gamma*maximum(el_delta)

With gamma = 0.1 the length in VOXELS is just `0.4*max_steps`:

| | mesh | min(el_size) | max_steps | alpha, voxels |
|---|---|---|---|---|
| their 2D example | 200 x 200 | 200 | 20 | 8.0 |
| their 3D example | 150 x 150 x 150 | 150 | 30 | 12.0 |
| **his part** | 128 x **31** x 118 | **31** | 6 | **2.4** |

`minimum(el_size)` is a proxy for mesh REFINEMENT. On their cubic meshes it is
exact; his part is a 4:1 slab, so the rule reads the THIN axis and regularises
five times less than their own 3D example. `--gridap-auto min|max` evaluates the
rule on the real grid and prints the derivation; `min` is a POSITIVE CONTROL that
must reproduce the run of record's 6 steps / alpha 2.4, and does
(`s6_gridap_auto_min.txt`).

## the program

`core/tests/harness/levelset_probe.cpp`, an `EXCLUDE_FROM_ALL` target that
already existed (PR 322). **`git diff main -- core/src core/include app/` is
EMPTY** — this task did not even add a CMake line.

    ./build/levelset_probe <part.step> <materials.json> <ref/design.bin> <out> \
        [--rung 0.68] [--iters 300] [--eta 2.0] [--gamma 0.1] [--hj-steps 6] \
        [--alpha-coeff 2.4] [--traj-penalty 1.0] [--threads 3] \
        [--gridap-auto min|max] [--damp] [--snapshot-every 10] \
        [--simp --rules <rules.json>]           the 3-thread SIMP baseline \
        [--certify-field <prefix> [--binarize]] a re-certification control

## files

| file | what it is |
|---|---|
| `reproduce.sh` | regenerates everything below |
| `s1_simp_3thread.log`, `s1_simp_3thread/` | the 3-THREAD SIMP BASELINE — the shipped `minimize_plastic`, invoked, ladder narrowed to one rung |
| `s2_levelset.log`, `s2_levelset/` | **the run of record**: all five differences, their alpha rule as written |
| `s3_surface_probe.txt` | the roughness measurement, all three arms + every snapshot, carrying its own four SIMP rows |
| `s3_levelset_vs_simp.csv` | the rows this task adds to PR 306/314/319/321/322's table |
| `s4_recert_binarized/` | the ersatz band is NOT softening the certificate (3400.87 vs 3405.33) |
| `s5_alpha8.log`, `s5_alpha8/` | alpha ALONE — the single-variable test |
| `s6_corrected.log`, `s6_corrected/` | their rule keyed to the resolution axis + their gamma damper |
| `s6_gridap_auto_min.txt` | the positive control on `--gridap-auto` |
| `s7_early_stop/`, `s7_early_stop.log` | per-iterate certification of the s6 trajectory — where the margin saturates |
| `ctest.txt` | the suite at CI's denominator |

Each arm directory carries `summary.txt`, `iterations.csv`, `design.bin`,
`rho.f64.gz` + `rho.meta`, and `snap/` (the every-10-iterations occupancy the
roughness CURVE is measured from — the instrument invoked on each, never
retyped).

`levelset.stl` is NOT committed on any arm: it is 17 MB of exactly what
`design.bin` already contains. To look at a design:

    cmake --build build --target design_rung_dump
    ./build/design_rung_dump evidence/2026-08-09-levelset-match-the-reference/s6_corrected/design.bin <out> --stl

## the three things that were nearly measured wrong

**1. A defect PR 322 carried, which only difference 1 could expose.** PR 322 held
the volume correction as a scalar `offset` and read the ersatz at `phi + offset`.
Once the surface delta concentrates the velocity at the interface, `{phi = 0}` is
the one surface that barely moves — and reinitialisation re-distances about
`{phi = 0}`, so every iteration rebuilt phi from the surface that had NOT been
advected. Measured before the fix: `offset_mm` at +3.57, +3.58, +3.58 mm instead
of shrinking. Folding the offset into phi is exact and is the structure the
reference has; after it, compliance falls ~3x faster per iteration.

**2. The reinitialisation residual has to be an RMS.** The exact signed distance
function of any solid has kinks on the medial axis where the discrete |grad phi|
is 0 — an error of exactly 1. His thinnest members put those kinks inside the
two-voxel band, so the MAX is pinned at 1.0 by geometry that is correct
(measured: 0.996). A statistic that saturates on the right answer measures
nothing.

**3. The gamma damper took two attempts.** The first counted sign flips only and
fired on every window — gamma annealed 0.1 -> 0.075 -> 0.05625 -> 0.042 in twenty
iterations, which would have frozen the design short of its fixed point and let
the plateau test call that "converged". The trajectory it fired on was a noisy
DESCENT. The trigger now also requires NO NET PROGRESS across the window; a
Lagrangian that is still descending is not oscillating. That run was discarded and
re-run.

## the bars

**R1 — it runs and it finishes.** Three arms, all converged on the shipped MMA
plateau rule (76, 68, 43 iterations), designs and curves on disk.

**R2 — our instruments, invoked not retyped.** `external_field_surface_probe`
produces every roughness row, in ONE invocation carrying its own four SIMP
baseline rows. `minimize_plastic` produces the SIMP baseline — and reproduces PR
321's production run bit-for-bit in compliance, CG count and every certified
number, which is the positive control that it is that run re-timed rather than a
re-implementation.

**R3 — margin and verdict reported, certification unchanged.**
`analyze_fixed_design` at the PRODUCTION penalty 3, isolated exactly as
production isolates a re-certification, on every arm and on four iterates of the
s6 trajectory. Every one ACCEPTED. The trajectory runs at penalty 1 (their linear
interpolation) and nothing about it reaches the certificate.

**R4 — the shipped SIMP path is untouched.** `git diff main -- core/src
core/include app/` is EMPTY.

**R5 — see the handoff §2 and §5.** All five implemented; two things in the
reference have nothing in our scheme to apply to and are named; a sixth
difference and a parameter-transfer error were found by reading the paper.

**R6 — no assertion weakened or deleted, no scratch at the repository root.** The
diff touches one file under `core/tests/harness/`; no test file is touched and no
`add_test` is added or removed, so the denominator is `main`'s by construction.
`ctest.txt`: **117/117 passed**. That is above CI's 114 because lib3mf is present
on this host — the failure mode `local-ctest-denominator-is-not-cis` warns about
is local having FEWER tests than CI, and 117 > 114 rules it out.
