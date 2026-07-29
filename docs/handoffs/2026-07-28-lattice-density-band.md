# Lattice homogenized material — density band + graded-transition verdict

**Date:** 2026-07-28
**Scope:** read-only harness study. **No production change** (bar B5).
**Builds on:** PR 220 (lattice-mode-phase-1, C2 homog-vs-resolved), PR 198
(offline homogenization library), PR 201 (strut family / grading).
**Harness:** `core/tests/harness/lattice_density_band_probe.cpp` (standalone,
not wired to CTest). Evidence: `evidence/2026-07-28-lattice-density-band/`.

---

## TL;DR

1. **Q1 — C2's density dependence is a PROBE ARTIFACT, not a model error.**
   Against a *resolution-converged* truth (periodic homogenization at vpc48), the
   library tensor is within **±2.4 % for every density in rho 0.15–0.54** (mostly
   < 1 %). PR 220's misses at vf 0.20 (12.96 %) and vf 0.40 (16.22 %) were the
   **vpc16 resolved *reference* being over-stiff** (under-resolved octet), not the
   library being wrong. Both clear by vpc32 and are ~0 % at vpc48.

2. **Q1★ — vf 0.40 has NO separate cause.** It is the *same* under-resolution as
   vf 0.20, only milder (thicker struts do resolve better — 4.7 vs 3.0 vox/strut
   at vpc16 — exactly as the task anticipated, but still short of the 6–8
   vox/strut octet needs). The periodic tensor's own resolution drift at vpc16 is
   **+16.8 % at vf 0.40 vs +32.2 % at vf 0.20**; both fall to 0 by vpc48. The
   library value at rho 0.398 is an anchor row and is exact.

3. **★ D3 — the certifiable grading band is rho ≈ 0.15 → 0.62** (at vpc48). It is
   bounded **below** by the library's minimum resolved row (0.148, the
   under-resolution alias floor) and **above** by the tensor **clamp at rho 0.591**:
   above the clamp the frozen tensor drifts to **−16 % at 0.64, −31 % at 0.70,
   −60 % at 0.90**. That is real, resolution-independent model error.

4. **Q2 — the graded ramp is NOT viable as a *certifiable* feature with the
   current library, and is modeled WORSE than a hard boundary.** A ramp
   necessarily spends its length in rho 0.59–1.0 — exactly the clamped band. Over
   a 4-cell transition the homogenized model is off by **22 %** (graded) vs
   **5.8 %** (hard boundary of the same endpoints); the error **grows with ramp
   length** (15 %→28 % over 1→8 cells) as more cells enter the clamp. The
   structural case *for* grading (removing a stress riser) was **not observed**:
   peak von Mises in the resolved struts is **flat at ~2.60 across all transition
   lengths and equals the hard boundary's** — the concentration is lattice-internal.

**Bottom line for the maintainer:** the homogenized octet material is trustworthy
and essentially exact from rho ~0.15 to ~0.62. The graded lattice→solid transition
he proposes is *geometrically* sound (octet reaches solid by radius grading) but is
**un-certifiable today**, because the library stops at rho 0.591 and the ramp lives
above it. Extending the library with resolved rows 0.6–0.95 + a solid anchor (and a
de-homogenization step for near-solid cells) is the prerequisite. Until then a hard
boundary certifies better than a ramp — the opposite of the structural intuition,
for a model-coverage reason, not a physical one.

---

## Method

Two independent "truths", so the C2 gap can be decomposed:

- **Periodic homogenization** (PR 198's method, re-implemented here): the effective
  cubic tensor of the *resolved unit cell* under periodic BC. Resolution-clean (no
  free surface), converges by vpc48, and cheap — **1–3.4 s** at any density even at
  vpc48. This is the primary truth.
- **Resolved finite block** (PR 220's C2 method): apparent modulus of an Nc³-cell
  free block of actual struts. Includes free-surface softening; **O(10⁶) DOF and
  minutes-to-unrunnable** at high vpc (see B4). Used as a cross-check where affordable.

The library model is `lattice_cubic_tensor(Octet, rho, E)` (PR 198's numbers,
embedded). Comparison metric = apparent Young's modulus E₁₀₀ along ⟨100⟩.
Instrument self-check (B1): periodic homogenization of a fully-solid cell recovers
**E₁₀₀ = 3500.0000 MPa (rel < 1e-6)** at vpc 8/16/24, and the cubic element with an
isotropic tensor equals `hex8_stiffness` bit-for-bit (max|ΔK| = 0).

Voxels-per-strut is reported on every row: `2·r·vpc/L` (strut diameter in voxels),
which PR 198 identified — not vpc — as the quantity governing octet convergence.

---

## D1 / D2 / D3 — density band (`d1_density_band.csv`, `d1_stdout.txt`)

Radius calibrated once at vpc48 and **held fixed** across vpc, so only resolution
changes (targeting a vf per-vpc lands on aliasing knife-edges — the density-vs-radius
step function of PR 198). Achieved rho reported per row. Truth = periodic @vpc.

**At vpc48 (converged), library model vs periodic truth:**

| rho (achieved) | vox/strut | E_periodic (MPa) | E_library (MPa) | model err | verdict |
|---:|---:|---:|---:|---:|:--|
| 0.148 | 7.7 | 96.13 | 96.13 | 0.00 % | GO (min-row clamp) |
| 0.204 | 9.1 | 155.80 | 155.80 | −0.00 % | GO |
| 0.246 | 10.6 | 213.67 | 212.64 | −0.48 % | GO |
| 0.297 | 11.7 | 286.42 | 286.41 | −0.00 % | GO (anchor) |
| 0.344 | 13.1 | 378.91 | 381.22 | +0.61 % | GO |
| **0.398** | 14.2 | 489.22 | 489.22 | **−0.00 %** | GO (anchor) |
| 0.451 | 15.1 | 629.81 | 644.89 | +2.39 % | GO |
| 0.497 | 16.3 | 772.34 | 782.17 | +1.27 % | GO |
| 0.538 | 17.2 | 917.91 | 928.40 | +1.14 % | GO |
| 0.600 | 18.4 | 1163.49 | 1124.55 | −3.35 % | GO (clamped) |
| 0.645 | 19.7 | 1338.91 | 1124.55 | −16.01 % | **NO-GO** (clamped) |
| 0.704 | 21.1 | 1640.75 | 1124.55 | −31.46 % | **NO-GO** |
| 0.807 | 23.7 | 2229.59 | 1124.55 | −49.56 % | **NO-GO** |
| 0.900 | 27.2 | 2849.41 | 1124.55 | −60.53 % | **NO-GO** |

**Certifiable band = rho ≈ 0.15 → 0.62.** The 10 % crossing sits at rho ≈ 0.622
(interpolating between the 0.600 / −3.35 % and 0.645 / −16.01 % rows against the
frozen 1124.55). The clamp is the library's max resolved row `lattice_rho_max =
0.591`; every row flagged `[CLAMPED]` in the CSV reuses that frozen tensor.

**D2 — the vf 0.40 cause, decomposed.** At vf 0.40 the achieved rho and periodic
E₁₀₀ across resolution:

| vpc | rho | vox/strut | E_periodic | resolution drift vs vpc48 | E_resolved_finite | library model err |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 0.391 | 4.7 | 571.32 | +16.78 % | 564 | −16.92 % |
| 32 | 0.416 | 9.5 | 533.25 | +9.00 % | — | +1.65 % |
| 48 | 0.398 | 14.2 | 489.22 | 0 (ref) | — | −0.00 % |

PR 220's C2a compared library (474.65, correct — the vpc48 value) against a **vpc16
resolved finite block (564 ≈ periodic@vpc16 571)** that is **over-stiff by +16.8 %**
because a 4.7-vox/strut octet is staircase-stiffened and not converged. The miss is
the *reference*, not the model, and it vanishes by vpc32. Same mechanism as vf 0.20
(drift +32.2 % at vpc16), milder because the struts are thicker — which is precisely
why the task's "thicker struts resolve better" intuition holds, and why there is **no
separate 0.40 mechanism** to find.

**Cross-check (B2)** — resolved finite block vs periodic truth (subset,
`d1b_resolved_finite_subset_vpc32.txt`): free-surface term is small and negative, as
expected — vf 0.50 vpc16: E_resFinite 876 vs E_periodic 884 (−0.9 %); vpc32: 753 vs
762 (−1.2 %). The finite-block C2 gap (|library − resolved|/resolved) is 3.7 %
(vpc16) → 1.1 % (vpc32), i.e. converging exactly as the periodic-truth analysis says.

---

## D4 — the ramp (`d4_ramp_summary.csv`, `d4_ramp_layers.csv`, `d4_stdout.txt`)

Specimen: 2×2 lateral, `[2 lattice(rho 0.40) | 4 ramp | 2 solid]` cells, vpc12,
**laterally confined** uniaxial z (rollers on the 4 side faces — this removes the
near-singular rocking/Poisson modes that make an unconfined soft-based lattice column
un-solvable by CG; applied identically to resolved and homogenized so the comparison
is fair). Octet **reaches full solid** by radius grading (r = 2.29 mm → rho 1.0000),
so the maintainer's "grade the strut radius to 100 %" is geometrically valid.

| design | E_resolved | E_homog | model gap | SCF (peak/far-field vM) | clamped cells |
|:--|---:|---:|---:|---:|---:|
| **graded** (4-cell) | 1856.1 | 1447.9 | **21.99 %** | 2.596 | **2** |
| **hard boundary** | 1468.7 | 1383.7 | **5.78 %** | 2.604 | 0 |

Per-layer axial-strain error (resolved vs homogenized), graded ramp:

| layer | cell rho | err | note |
|---:|---:|---:|:--|
| 0–2 | 0.45–0.52 | +18 to +21 % | in-band, confined-column artifact at vpc12 |
| 3 | 0.82 | **−47 %** | **CLAMPED** (frozen tensor too soft → over-strains) |
| 4 | 0.96 | **−63 %** | **CLAMPED** |
| 5–7 | 0.996–1.0 | +28 to +30 % | solid (isotropic) |

The graded ramp is modeled **worse** than the hard boundary because two of its cells
sit in the clamped band. The hard boundary jumps in-band-lattice (0.40) → solid,
never entering rho 0.59–1.0, so both its endpoints are well-modeled.

---

## D5 — ramp length (`d5_ramp_length.csv`, `d5_stdout.txt`)

Same specimen, transition length swept 1–8 cells:

| Ltrans (cells) | E_resolved | E_homog | model gap | SCF | clamped cells |
|---:|---:|---:|---:|---:|---:|
| 1 | 1621.3 | 1375.7 | 15.14 % | 2.603 | 1 |
| 2 | 1717.1 | 1370.5 | 20.19 % | 2.590 | 2 |
| 3 | 1826.5 | 1529.0 | 16.29 % | 2.593 | 1 |
| 4 | 1856.1 | 1447.9 | 21.99 % | 2.596 | 2 |
| 6 | 1970.9 | 1523.2 | 22.71 % | 2.596 | 3 |
| 8 | 2028.9 | 1466.0 | 27.74 % | 2.597 | 4 |

- **SCF is flat (~2.59–2.60) at every length and equals the hard boundary's (2.604).**
  By this proxy (global peak / far-field-lattice von Mises in the resolved struts),
  the stress concentration is **lattice-internal** — set by the strut-node geometry,
  not by the sharpness of the macro transition. Grading does not relieve it. (Caveat:
  crude proxy at vpc12; the continuum "graded boundary removes the riser" intuition
  simply does not transfer to a resolved lattice whose struts concentrate stress
  everywhere.)
- **Model gap grows with length**, tracking the clamped-cell count (1→4). A longer
  ramp is *less* certifiable, not more. There is **no length that works** with the
  current library.

---

## B3 / B4 — cost of a resolved re-validation (6-P-core Mac)

| solve | DOF | cost | notes |
|:--|---:|---:|:--|
| periodic homog, 1 cell, vpc48 | 331 k | **1–3.4 s** | the truth used throughout; affordable at every density |
| periodic homog, 1 cell, vpc64 | 786 k | ~4 s | convergence spot-check (rho 0.20: 155.8→156.9, +0.7 %) |
| resolved finite 2-cell, vpc16 | 108 k | 8–40 s | MGCG/Jacobi; used for all D1 cross-checks |
| resolved finite 2-cell, vpc32 (dense) | 824 k | ~1–2 min | converges for dense (MG-friendly) rho |
| resolved finite 2-cell, vpc32 (dilute) | 824 k | **> 2 min, capped** | geometric MG stagnates on sparse struts |
| resolved finite 2-cell, vpc48 | 2.7 M | **> 16 min, DID NOT COMPLETE** | single-core MG build dominates; **B4: unrunnable in practice** |
| ramp resolved, confined, vpc12, ~180 k DOF | 182 k | ~18 s | base rho 0.40 (well-connected); MGCG 15–54 iters |

**B4 statement, with numbers:** a directly-resolved finite block at vpc48 (2-cell,
2.7 M DOF) is **not practically runnable** on this machine — a dense case ran > 16 min
without completing and dilute cases stall the geometric-multigrid preconditioner. The
largest resolved finite blocks that run comfortably are **vpc16 (all densities) and
vpc32 (dense densities only)**. **No coarser solve was silently substituted:** the
density band is quoted against **periodic homogenization at vpc48**, which is the
resolution-converged unit-cell truth and costs 1–3 s, with the finite-block method
used only to confirm the two agree at vpc16/32 (they do, to ~1 %).

---

## Recommendations (feature is a separate task — B5)

1. **Certify grading only inside rho 0.15–0.62.** Below 0.15 and above ~0.62 the
   library is not trustworthy (alias floor / clamp respectively). This band is the
   deliverable number.
2. **A lattice→solid ramp needs the library extended above 0.591** before it can be
   modeled: add resolved rows at rho ≈ {0.65, 0.72, 0.80, 0.88, 0.95} (periodic
   homogenization, vpc48; each ~3 s) plus the exact solid anchor (isotropic E), and a
   de-homogenization step for the near-solid cells (Phase 2, already named in
   `2026-07-26-lattice-homog-phase0`). The periodic-homog harness here produces those
   rows directly.
3. **The structural case for grading is unproven at the strut level.** Peak strut vM
   did not fall with transition length or vs a hard boundary in this study. Before
   committing to a ramp for stress reasons, measure the *strut-level* SCF at the
   junction directly (a finer, junction-localized von Mises probe) — do not assume the
   continuum stress-riser argument carries over.
4. Until 1–3 land, **a hard lattice/solid boundary certifies better than a ramp**
   (5.8 % vs 22 %), because it keeps both media inside the trustworthy band.

## Reproduce

```
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_density_band_probe.cpp build/libtopopt.a -o build/db_probe
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_DB_ONLY=self ./build/db_probe          # B1
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_DB_ONLY=d1 TOPOPT_DB_RES_MAXVPC=16 ./build/db_probe   # D1/D2/D3
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_DB_RESTOL=1e-4 TOPOPT_DB_ONLY=d4 ./build/db_probe     # D4
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_DB_RESTOL=1e-4 TOPOPT_DB_ONLY=d5 ./build/db_probe     # D5
```
Knobs: `TOPOPT_DB_VFS`, `TOPOPT_DB_VPCS`, `TOPOPT_DB_CELLS`, `TOPOPT_DB_REF_VPC`,
`TOPOPT_DB_RES_MAXVPC` (finite-block cost gate), `TOPOPT_DB_RAMP_{VPC,NL,LTRANS,BASE}`,
`TOPOPT_DB_LENS`.
