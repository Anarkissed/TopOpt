# Graded cell size — Phase 0 (harness, read-only)

**Date:** 2026-07-28
**Scope:** read-only measurement harness. **No production change** (bar B4).
**Builds on:** PR 198 (offline periodic-homogenization library), PR 201 / lattice
generator (`lattice_gen.cpp`, struts along segments), PR 220 / PR 234 (lattice
certification + density ramp), and the 2026-07-28 density-band study.
**Harness:** `core/tests/harness/graded_cell_size_probe.cpp` (standalone, not in
CTest). Evidence: `evidence/2026-07-28-graded-cell-size-phase0/`.

---

## TL;DR

1. **★ C1 — the physics is REAL and the tensor is EXACTLY scale-invariant.** Homogenize
   octet at the same relative density with cells of 4, 8, 16, 32 mm and the cubic
   tensor is **identical to 0.000e+00** (machine/CG precision), while the printed
   strut diameter spans **8×** (0.75 → 6.0 mm). This is not an approximation: at fixed
   `r/L` and voxels-per-cell the occupancy pattern is identical and the hex8
   homogenization is a uniform mesh scaling, so `CH ~ h³/h³ = 1`. **Cell size costs
   nothing in the certification tensor.**

2. **★ C2 — but DEPLOYING that tensor needs cells-per-member, and that is the ceiling.**
   Cell size is free in the tensor; it is *not* free in the solve, because a bigger
   cell means fewer cells across a member and homogenization loses scale separation.
   - **Axial** effective modulus (RVE convergence, free surfaces): within ±2.4% by **~1
     cell** across (1 cell +2.36%, 2 cells +1.20%, 3 cells +0.81%; **0.5 cell =
     DISCONNECTED**, the member does not percolate and homogenization is meaningless).
   - **Bending** (guided-cantilever transverse stiffness, resolved struts vs the
     homogenized macro model — 1 cubic element per cell, the finest a homogenized
     lattice can legitimately be meshed): the binding case. Error 1c +48.5%, 2c +8.5%,
     3c +4.1%, 4c +2.59%, 5c +1.78% — **crossing 2.4% between 4 and 5 cells as
     deployed** (~3 for the fundamental scale-separation part alone; the extra is the
     unavoidable coarse-element response — a homogenized lattice can't be meshed below
     one cell). This confirms and slightly exceeds the survey / PR 198 "≈3 cells".

3. **★ C3 / BLOCKED-STOP — for THIS project's members, cells cannot grow at all.** The
   ceiling is dimensionless (the homogenization error at a fixed cells-per-member is
   scale-invariant, from C1), so the largest usable cell is `W / N*`. With the bending
   ceiling `N* ≈ 3–5` (and even the generous axial `N* ≈ 1`):

   | member width | max cell @ N*=5 (deployed) | @ N*=3 (fundamental) | @ N*=1 (axial floor) |
   |---:|---:|---:|---:|
   | 5.0 mm | 1.0 mm | 1.67 mm | 5.0 mm |
   | **9.4 mm** (this project) | **1.88 mm** | 3.13 mm | 9.4 mm |
   | 20.0 mm | 4.0 mm | 6.7 mm | 20 mm |

   The maintainer wants to grow **8 → 16 mm+**. A **16 mm cell in a 9.4 mm rib is 0.59
   cells across = the DISCONNECTED regime** — homogenization is meaningless, no ceiling
   argument even applies. An **8 mm cell is 1.18 cells across** — below the bending
   ceiling and only marginal even for pure axial. **Scale separation collapses before
   the cell can grow at all**, which is the task's declared BLOCKED-STOP condition.

4. **C5 — a conformal warp breaks the cubic tensor almost immediately.** A stretched
   octet is orthotropic, not cubic: `Ez/Ex` departs 1.0 to **1.15 by an ~8% per-cell
   stretch**, 1.55 at 25%, 4.1 at 100%. This is the real physics of the warp tilting
   the struts. The homogenized cubic tensor applies only for a **very gentle grade
   (per-cell size change of a few percent)**; past that the cell "stops being periodic
   enough" and would need its own orthotropic tensor.

5. **C4 — a dyadic transition is geometrically free but not a certification fix.** A
   factor-2 (8→16 mm) octet transition connects with **zero bridge struts and zero
   extra triangles**: the coarse cell's nodes *nest* in the fine grid, so the levels
   meet at shared nodes. The cost is only that half the fine interface nodes carry a
   coarse strut (interface SCF — see C4). But this is moot for certification, because
   both levels must still each clear the cells-per-member ceiling.

**Bottom line for the maintainer.** The scale-invariance intuition is correct and
proven (C1): cell size is free *in the tensor*, and PR 234's low-density floor is not a
tensor-magnitude limit. **But it is a DEPLOYMENT limit, and that limit is real, not a
printability artifact.** To keep a rho-0.05 octet strut printable you must grow the cell
to ≥8–16 mm (B3), and at that size a ~9.4 mm member holds **less than one cell** — the
homogenized model cannot certify it. So graded cell size does **not** rescue low-density
certification here. The low-density end needs a *different* answer — a finer/extended
library with de-homogenization, an accepted density floor (PR 234 stands), or treating
low-density lattice as **non-certified printability infill** (not load-bearing), in
which case the cell may grow freely for printing but carries no certified load. This is
better known now, before any build.

---

## Method / instruments (bar B1)

Two truths, both ported verbatim from `lattice_density_band_probe.cpp` so the self-check
is the same instrument:
- **Periodic homogenization** (PR 198): the effective cubic tensor of the resolved unit
  cell under periodic BC. Resolution-clean, cheap. Used for C1, and as the homogenized
  prediction in C2/C2b/C3/C5.
- **Resolved apparent modulus / stiffness** (PR 220 method): apparent modulus of the
  actual strutted geometry. Used as the reference the homogenized model is graded against.

**B1 self-check (`self_check.txt`):** periodic homogenization of a fully-solid cell
recovers **E100 = 3500.0000 MPa (rel −0.000000)** at cell sizes 4/8/16/32 mm, and the
cubic element with an isotropic tensor equals `hex8_stiffness` **bit-for-bit**
(max|ΔK| = 0). Every row carries relative density, cell size, strut diameter,
voxels-per-strut and its reference (bar B2).

---

## C1 — tensor scale-invariance (`c1_scale_invariance.csv`)

At fixed relative density and voxels-per-cell, across cell sizes 4/8/16/32 mm:

| target rho | vpc | cell (mm) | strut d (mm) | E100 (MPa) | max |ΔE100| across 4× cells |
|---:|---:|---:|---:|---:|---:|
| 0.20 | 16 | 4→32 | 0.75 → 6.00 | 78.443 (all) | **0.000e+00** |
| 0.20 | 24 | 4→32 | 0.83 → 6.67 | 176.504 (all) | **0.000e+00** |
| 0.40 | 16 | 4→32 | 1.25 → 10.00 | 610.422 (all) | **0.000e+00** |
| 0.40 | 24 | 4→32 | 1.19 → 9.52 | 476.288 (all) | **0.000e+00** |

`C11, C12, C44, Zener` are likewise identical to all printed digits. **The tensor is
scale-invariant to CG precision; the strut diameter it corresponds to is not** — an 8×
diameter range at a byte-identical tensor. This is the whole basis of the maintainer's
idea, and it holds exactly.

---

## C2 — the ceiling: homogenization error vs cells-per-member

### Axial (`c2_cells_per_member.csv`) — RVE modulus convergence, free surfaces, rho≈0.285

| cells across | E_resolved | E100_periodic | homog err | verdict |
|---:|---:|---:|---:|:--|
| 0.5 | ~0 | 280.58 | — | **DISCONNECTED** |
| 1 | 274.11 | 280.58 | **+2.36%** | GO (at the bar) |
| 2 | 277.25 | 280.58 | +1.20% | GO |
| 3 | 278.34 | 280.58 | +0.81% | GO |

The axial effective modulus is representative down to ~1 cell; below one cell the member
does not percolate. Axial is the **generous lower bound** on the ceiling.

### Bending (`c2b_bending.csv`) — guided-cantilever transverse stiffness, rho≈0.199

Resolved struts vs the homogenized macro (1 cubic element per cell = the finest a
homogenized lattice can be meshed; the periodic tensor is taken at the *achieved* rho so
the only difference is scale separation + the unavoidable coarse-element response):

| cells across | K_resolved | K_homog_macro | bend err | verdict |
|---:|---:|---:|---:|:--|
| 1 | 7.195 | 10.686 | +48.5% | NO-GO |
| 2 | 93.609 | 101.528 | +8.5% | NO-GO |
| 3 | 339.258 | 353.229 | +4.1% | NO-GO |
| 4 | 772.352 | 792.346 | +2.59% | NO-GO |
| 5 | 1390.542 | 1415.312 | +1.78% | GO |

Bending needs **~5 cells** across to reach ±2.4% for the model **as deployed** (crossing
between 4 and 5). Two mechanisms stack: (a) the fundamental scale-separation deficit
(the survey / PR 198 "≈3 cells"), and (b) a homogenized lattice cannot be meshed finer
than one cell, so the coarse trilinear-hex response (which shear-locks / can't resolve
the bending gradient with few elements) is part of the *deployed* error, not an artifact
to refine away. A locking-free homogenized element would relax the ceiling toward ~3.
Either way the binding structural ceiling is **N\* ≈ 3–5**, far above the axial ~1.

---

## C3 — ceiling × member width

_(Derived from C1 + C2, not a separate solve — the `c3` harness section runs the
redundant per-width solves if wanted; they are byte-identical grids by C1, so it is
omitted from evidence.)_

**Part A — the ceiling is dimensionless (follows directly from C1).** A member of
`cells_across` cells at voxels-per-cell `vpc` has a voxel occupancy pattern that depends
only on `cells_across` and `vpc`, never on the physical cell size — the voxel centres map
to the same unit-cell fractions (this is exactly the mechanism C1 proved gives an
identical tensor). So the 3-cells-across resolved member for W = 5, 9.4, 20 mm is the
**byte-identical grid scaled**, and its homogenization error is identical:
**+0.81%** for all three (the measured 3-cells-across axial value from C2). One ceiling
number therefore serves every width — which is what makes Part B just arithmetic.

**Part B — the deliverable: max cell per width** (from the TL;DR table), `S_max = W / N*`:

| member width | axial N*≈1 | bending N*≈3 (fundamental) | bending N*≈5 (as deployed) |
|---:|---:|---:|---:|
| 5.0 mm | 5.0 mm | 1.67 mm | 1.0 mm |
| **9.4 mm** | 9.4 mm | 3.13 mm | 1.88 mm |
| 20.0 mm | 20 mm | 6.7 mm | 4.0 mm |

A thin 9.4 mm rib caps the certifiable cell at **~2–3 mm** (bending) — smaller than the
8 mm base the grade wants to grow *from*, and far below the 16 mm it wants to grow *to*.
A thick 20 mm boss tolerates ~4–7 mm. **The user cannot use one graded cell schedule
for a thin rib and a thick boss** — the certifiable cell is a fixed fraction of the
member width, so grading must be tied to the *local member width*, not the density.

---

## C5 — conformal warp: distortion limit (`c5_conformal_warp.csv`)

Homogenize a cell stretched by aspect `a = grown height / base` (rho held fixed; the
density-free anisotropy `Ez/Ex` is the primary metric — the `drift%` columns carry a
residual density-quantization offset at vpc24 and are secondary):

| aspect (per-cell stretch) | Ez/Ex (anisotropy) |
|---:|---:|
| 1.00 (0%) | 1.000 |
| 1.08 (8%) | 1.150 |
| 1.13 (13%) | 1.199 |
| 1.17 (17%) | 1.372 |
| 1.25 (25%) | 1.553 |
| 1.50 (50%) | 2.254 |
| 2.00 (100%) | 4.125 |

A stretched octet becomes strongly **orthotropic**: even an ~8% per-cell size change
pushes the directional-modulus ratio to 1.15 (15%), far outside the ±2.4% band the
cubic tensor is trusted to. **A conformal warp preserves the cubic certification tensor
only for a per-cell size change of a few percent** — enough to smooth a boundary, not
enough to grade 8→16 mm without re-homogenizing the warped cell as orthotropic.

---

## C4 — dyadic transition (`c4_dyadic.csv`)

Fine octet (cell S) meeting coarse octet (cell 2S), resolved, confined-z:

- **Bridging is free.** The coarse cell's nodes (corners + face centres) *nest* in the
  fine grid at factor 2 — every coarse interface node is also a fine-grid node — so the
  two levels connect at shared nodes with **zero bridge struts and zero extra transition
  triangles**. A coarse cell has the same triangle count as a fine cell but 8× the
  volume, so the transition simply carries 8× fewer triangles per volume. (This is why
  slicers' adaptive-cubic infill can double cell size at a plane without stitching.)
- **But the interface is a stress riser.** Only half the fine interface nodes carry a
  coarse strut, so load funnels through them. Measured (fine rho 0.199, coarse 0.170 —
  a residual density-quantization mismatch caveat): peak von Mises in ±1 cell of the
  interface is **SCF 3.75 vs 2.24 in the fine bulk = 1.68× the baseline concentration**.
  The factor-2 jump concentrates stress ~1.7× above the lattice's own internal riser.

Connectivity/triangle cost is the robust finding (pure geometry); the 1.68× SCF is
indicative with the density caveat. For **certification** this is moot anyway — both
levels must still each clear the cells-per-member ceiling (C2), and a coarse level is
*further* from clearing it.

---

## B3 — printability along the density ramp (`b3_printability.csv`)

Printed strut diameter `d(rho, cell)` in mm; 0.4 mm nozzle floor (1 bead), ~0.8 mm
reliable (2 beads):

| rho | S=4 mm | S=8 mm | S=16 mm | S=32 mm |
|---:|---:|---:|---:|---:|
| 0.05 | 0.363 ✗ | 0.726 ~ | 1.453 ✓ | 2.906 ✓ |
| 0.10 | 0.534 ~ | 1.067 ✓ | 2.134 ✓ | 4.269 ✓ |
| 0.20 | 0.759 ~ | 1.518 ✓ | 3.037 ✓ | 6.074 ✓ |
| 0.40 | 1.181 ✓ | 2.363 ✓ | 4.726 ✓ | 9.452 ✓ |
| 0.60 | 1.534 ✓ | 3.069 ✓ | 6.137 ✓ | 12.28 ✓ |

(✗ below 0.4 mm, ~ single-bead 0.4–0.8 mm). **The printability payoff is real**: at
rho 0.05 an 8 mm cell gives a marginal 0.73 mm strut, a 16 mm cell a comfortable 1.45
mm. This is exactly the motivation — and exactly the cell growth C2/C3 forbid for a
certified ~9.4 mm member. The two requirements are in direct conflict at low density.

---

## C6 — resolved dyadic vs conformal graded column (`c6_layers.csv`, `c6_summary.csv`)

One specimen, density grade ~0.58 → ~0.11 over 44 mm, base lateral cell 4 mm, 2×2
lateral, resolved & confined. Height-graded in z (constant lateral so struts connect by
construction — PR 201's segment endpoints move), realized two ways:

| route | E_confined (MPa) | worst-transition SCF | min strut d (mm) | printable throughout? |
|:--|---:|---:|---:|:--|
| **dyadic** (cell 4→8→16 mm) | 613.8 | 3.72 | 0.950 | yes |
| **conformal** (cell 2.5→9.9 mm smooth) | 446.7 | 7.57 | 0.647 | marginal at top |

**Caveat:** the two routes sample rho(z) at their (different) cell centres, so the
conformal column reaches a lower top density (0.11 vs 0.15) with thinner struts — which
accounts for most of its lower E and higher peak stress. So the E/SCF gap is **not** a
clean route effect; the clean per-transition riser is C4's 1.68×.

**Printed strut diameter along the ramp (B3, both routes):** both keep struts above the
0.4 mm nozzle by growing the cell — dyadic bottoms out at **0.95 mm**, conformal at
**0.65 mm** (marginal). This is the payoff working: at these low densities a *fixed* 4 mm
cell would have thinned to ~0.36 mm (unprintable, B3) — the growth is what saves it.

**Which route to ship — for the intended (certified) use: NEITHER.** Both are capped by
the cells-per-member ceiling per cell (C2/C3); growing the cell for printability pushes
each cell below the ceiling in a ~9.4 mm member, so neither graded lattice can be
certified there. **For printability-only (non-load-bearing) infill: dyadic.** It (a)
connects with zero extra struts/triangles (C4, nested nodes), (b) keeps struts thicker at
a given height (0.95 vs 0.65 mm), (c) is exactly slicers' adaptive-cubic infill (proven
manufacturable), and (d) preserves the cubic tensor *within* each level, whereas
conformal's warp destroys it (C5) — so conformal buys no certification advantage to
offset its thinner struts and warp complexity. Its one price, the interface stress step
(1.68×, C4), is acceptable for infill that carries no certified load.

---

## Synthesis / recommendation (feature is a separate task — bar B4)

1. **The maintainer's physics is right; the deployment is not.** Cell size is provably
   free in the certification tensor (C1). It is *not* free in the solve: a bigger cell
   means fewer cells across a member, and homogenization needs ≥ ~3 (fundamental) to ~5
   (as deployed) cells across (C2/C2b).
2. **For this project's ~9.4 mm members, cells cannot grow at all under certification.**
   The certifiable cell is a fixed *fraction of member width* (~W/4), i.e. ~2–3 mm — the
   8 mm base is already ~1 cell across, and 16 mm is *sub*-cell (disconnected). PR 234's
   low-density floor is therefore a **real model-deployment limit**, not merely a
   printability limit — you cannot keep a rho-0.05 strut printable (needs 8–16 mm cells)
   *and* homogenize a 9.4 mm member (needs ≤ ~3 mm cells) at the same time.
3. **BLOCKED-STOP (as the task defined it).** Scale separation collapses before the cell
   can grow meaningfully. The low-density end needs a *different* answer, chosen by the
   maintainer:
   - **(a) Accept a density floor** — PR 234's floor stands; do not grade below it.
   - **(b) Extend the library + de-homogenize** — resolved rows above the current band
     and a strut-level (de-homogenization) check, so thin members can be certified
     without homogenization. This is the honest structural route named in the earlier
     lattice handoffs; graded cell size does not shortcut it.
   - **(c) Treat low-density lattice as non-certified printability infill** — then grow
     the cell freely (C1) to keep struts printable (B3), via **dyadic** transitions (C4/
     C6), but do not count it as load-bearing.
4. **Tie any grading to local member width, not to density.** Because the ceiling is a
   fixed fraction of width (C3), a thin rib and a thick boss cannot share one cell-size
   schedule.

---

## B3 / cost notes (6-P-core Mac)

- Periodic homogenization (single cell, 6 RHS): vpc16 ~1 s, vpc24 ~3–10 s, vpc32 ~15 s,
  vpc48 unaffordable at tol 1e-10 (diagonal-CG iteration cap on the lattice — vpc≤32 is
  the practical range here).
- Resolved free-surface member (axial), vpc16, ~100–220 k DOF: assembled Jacobi-CG
  8–120 s; matrix-free geometric-MG **STALLS on the sparse lattice** (same failure mode
  the density-band study logged) — assembled CG is the reliable path for these.
- Resolved guided-cantilever (bending), vpc12, well-conditioned (clamped both ends):
  assembled CG solves through nc=5.

## Reproduce

```
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/graded_cell_size_probe.cpp build/libtopopt.a -o build/gcs_probe
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=self ./build/gcs_probe     # B1
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c1   ./build/gcs_probe     # C1
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c2  TOPOPT_GCS_MG=0 TOPOPT_GCS_C2_MLONG=2 ./build/gcs_probe  # C2 axial
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c2b TOPOPT_GCS_MG=0 ./build/gcs_probe  # C2b bending
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=b3   ./build/gcs_probe     # B3 printability
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c5   ./build/gcs_probe     # C5 conformal
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c4   ./build/gcs_probe     # C4 dyadic
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c3   TOPOPT_GCS_MG=0 ./build/gcs_probe  # C3
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c6   ./build/gcs_probe     # C6
```
Knobs: `TOPOPT_GCS_C1_{LS,VFS,VPCS}`, `TOPOPT_GCS_C2_{VPC,MLONG,CPM,VFS}`,
`TOPOPT_GCS_C2B_{VPC,LB,NC,CELL,VF}`, `TOPOPT_GCS_C3_{W,CPM,NSTARS}`,
`TOPOPT_GCS_C5_{VPC,ASPECTS}`, `TOPOPT_GCS_C4_{VPC,CELL,VF}`, `TOPOPT_GCS_C6_{...}`,
`TOPOPT_GCS_MG` (0=assembled CG), `TOPOPT_GCS_RESTOL`.
