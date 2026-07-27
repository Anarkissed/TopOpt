# 2026-07-26 — Lattice homogenization LIBRARY (Phase 0, harness / offline)

**Track:** offline library + measurement. **NO production code, NO `/app/`, NO gate
change, NO knockdown-law change, NO solver wiring.** One new standalone harness
(`core/tests/harness/lattice_homog_probe.cpp`, the sanctioned `cg_tol_probe.cpp` /
`lattice_probe.cpp` pattern — grids built programmatically, standalone build, NOT
wired into CTest), this report, and its evidence directory. `git status` in the last
section shows exactly the additive files. Nothing under `core/src`, `core/include`,
`docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md` or `materials.json`
was touched.

**What this is.** The lattice NO-GO ([2026-07-26-lattice-phase0](2026-07-26-lattice-phase0.md))
closed *direct* lattice FEA on memory (560 M–1.5 B voxels for a printable 200 mm part,
44×–276× the ceiling) and closed explicit-triangle output on device — and named the
**only honest structural route: homogenization** (Road B). This task builds the
foundation for that road: a numerical homogenization routine that computes the
effective elasticity tensor of a unit cell under **periodic boundary conditions**,
sweeps it across a density grid, and writes a tensor library. It is offline library
work, not a feature; Phase 1 (a separate task) wires these tensors into the macro
solver as an element constitutive law, adding **zero DOF** to the structural solve.

**Scope.** IN: gyroid, Schwarz-D, octet (an octet-style strut lattice: corner +
face-centre nodes). OUT: Voronoi, stress-aligned graph lattices, Lidinoid, Neovius,
Schwarz-P — they do not move the answer and attach to the same machinery later.

---

## METHOD — periodic-BC strain homogenization on the production element

Effective stiffness is computed by the standard energy/strain homogenization
(Andreassen–Bendsøe, 3-D). The cell is meshed with the **same 8-node hex element the
production solver uses** (`topopt::hex8_stiffness`, isotropic PLA E=3500 MPa, ν=0.33,
Voigt `[xx,yy,zz,gxy,gyz,gzx]`, engineering shear, 2×2×2 Gauss). For each of six unit
macro strains e⁰_I we solve for the Y-periodic corrector χ_I:

  K χ_I = F_I ,  F_I = Σ_e ke·χ0_I,e  (periodic assembly, opposite-face nodes identified)

three DOFs of one node pin the rigid-body translations (periodic BCs admit no
rotation nullspace), and DOFs touched by no solid element are pinned (the production
void-DOF gate). Then, by the average-stress form (Galerkin-orthogonal to, hence equal
to, the symmetric energy form for solved cases, and additionally yielding the
transverse rows from a single axial solve):

  C^H_IJ = (1/|Y|) Σ_e χ0_I,eᵀ ke (χ0_J,e − χ_J,e) ,  |Y| = full bounding volume (solid+void).

|Y| is the whole envelope, so C^H is the cellular solid's stiffness relative to its
bounding volume — the quantity a knockdown claims to model. Void = no element
(two-phase solid/empty). The periodic system is assembled and solved with Eigen
directly (the core solvers offer no periodic BCs); the direct free-surface comparison
(H4/H3) reuses the **production** `fea_solve_cg`.

---

## H1 — SELF-CHECK FIRST (bar: solid cell recovers the solid tensor to 4 digits)

A fully-solid periodic cell must return the analytic isotropic tensor (χ = 0 exactly,
so C^H = D). Measured (`evidence/.../h1_self_check.csv`, `probe_stdout.txt`):

| quantity | analytic | measured | rel. err |
|---|---|---|---|
| C11 = λ+2μ | 5185.7585 | 5185.7585 | **8.1e-15** |
| C12 = λ | 2554.1796 | 2554.1796 | 5.0e-15 |
| C44 = μ | 1315.7895 | 1315.7895 | 7.3e-15 |
| Zener | 1.0000 | 1.0000 | — |

Off-cubic coupling residual **3.9e-13**. **PASS — recovered to machine precision
(~15 digits), 11 orders past the 4-digit bar. The instrument is sound.**

---

## H2 + H6 — FULL CUBIC TENSOR, ZENER PER TOPOLOGY PER DENSITY

All three topologies have cubic symmetry; the measured **off-cubic residual is
0.0000 MPa on every library row** (`tensor_library.csv`, `offcubic_MPa` column) — no
spurious axial–shear or shear–shear coupling — so **(C11, C12, C44) fully describe
each**. The tensor library (single cell, L = 5 mm, **vpc = 48**, PLA Es = 3500 MPa;
scale travels every row — cells, cell size, ρ, wall thickness, wall voxels):

**gyroid** — mildly stiff-diagonal, Zener ≈ 1.05–1.16:

| ρ | wall mm (vox) | C11 | C12 | C44 | Zener | E₁₀₀/Es | E₁₁₁/Es |
|---|---|---|---|---|---|---|---|
| 0.101* | 0.21 (2) | 161.9 | 80.8 | 42.8 | 1.055 | 0.0309 | 0.0324 |
| 0.150 | 0.42 (4) | 250.8 | 126.2 | 70.8 | 1.136 | 0.0475 | 0.0532 |
| 0.201 | 0.42 (4) | 351.7 | 168.4 | 100.0 | 1.091 | 0.0693 | 0.0748 |
| 0.249 | 0.63 (6) | 455.0 | 216.0 | 134.4 | 1.125 | 0.0903 | 0.1001 |
| 0.301 | 0.73 (7) | 566.6 | 265.2 | 173.8 | 1.154 | 0.1136 | 0.1286 |
| 0.399 | 0.94 (9) | 824.1 | 369.0 | 264.7 | 1.163 | 0.1702 | 0.1940 |
| 0.500 | 1.15 (11) | 1149.3 | 492.3 | 377.0 | 1.148 | 0.2440 | 0.2746 |
| 0.600 | 1.35 (13) | 1555.3 | 653.4 | 510.2 | 1.132 | 0.3339 | 0.3712 |

**Schwarz-D** — soft-diagonal at low density, Zener ≈ 0.64 → 1.02:

| ρ | wall mm (vox) | C11 | C12 | C44 | Zener | E₁₀₀/Es | E₁₁₁/Es |
|---|---|---|---|---|---|---|---|
| 0.099* | 0.21 (2) | 166.8 | 67.0 | 32.7 | 0.656 | 0.0367 | 0.0253 |
| 0.149* | 0.31 (3) | 276.5 | 106.5 | 54.1 | 0.636 | 0.0621 | 0.0417 |
| 0.202 | 0.42 (4) | 382.8 | 154.6 | 88.5 | 0.776 | 0.0840 | 0.0673 |
| 0.247 | 0.42 (4) | 496.3 | 187.2 | 111.5 | 0.721 | 0.1125 | 0.0847 |
| 0.301 | 0.52 (5) | 612.7 | 241.6 | 156.9 | 0.845 | 0.1360 | 0.1176 |
| 0.400 | 0.73 (7) | 886.2 | 343.7 | 247.8 | 0.913 | 0.1983 | 0.1835 |
| 0.501 | 0.94 (9) | 1208.3 | 474.6 | 369.0 | 1.006 | 0.2688 | 0.2701 |
| 0.600 | 1.04 (10) | 1635.4 | 643.7 | 504.9 | 1.018 | 0.3634 | 0.3690 |

**octet** — strongly stiff-diagonal at low density, Zener ≈ 1.61 → 0.87 (through
isotropy near ρ ≈ 0.5):

| ρ | wall mm (vox) | C11 | C12 | C44 | Zener | E₁₀₀/Es | E₁₁₁/Es |
|---|---|---|---|---|---|---|---|
| 0.103* | 0.31 (3) | 88.2 | 42.0 | 37.3 | 1.613 | 0.0175 | 0.0263 |
| 0.148 | 0.42 (4) | 137.0 | 64.1 | 56.7 | 1.555 | 0.0275 | 0.0400 |
| 0.204 | 0.52 (5) | 213.8 | 94.5 | 83.4 | 1.398 | 0.0445 | 0.0592 |
| 0.253 | 0.52 (5) | 295.1 | 124.0 | 109.2 | 1.276 | 0.0633 | 0.0779 |
| 0.297 | 0.63 (6) | 374.2 | 152.0 | 135.1 | 1.215 | 0.0818 | 0.0965 |
| 0.398 | 0.73 (7) | 611.5 | 226.3 | 204.0 | 1.059 | 0.1398 | 0.1467 |
| 0.506 | 0.83 (8) | 974.9 | 328.8 | 297.3 | 0.921 | 0.2311 | 0.2156 |
| 0.591 | 0.94 (9) | 1344.7 | 443.7 | 392.2 | 0.871 | 0.3213 | 0.2859 |

`*` = under-resolved (wall < 4 voxels); see HR below — flagged, excluded from the fits.

**Which a scalar knockdown would misrepresent (the E₁₁₁/E₁₀₀ directional spread):**

| lattice | Zener range | E₁₁₁/E₁₀₀ (worst) | scalar verdict |
|---|---|---|---|
| **octet** | 1.61 → 0.87 | **+50%** at ρ≈0.10 (1.50), +18% at ρ≈0.30 | **needs a tensor** — the classic anisotropic strut lattice; literature ≈1.93, we measure 1.61 at printable low density. Invisible to a 3-axis test (Ex=Ey=Ez by cubic symmetry). |
| **Schwarz-D** | 0.64 → 1.02 | **−36%** at ρ≈0.15 (E₁₁₁/E₁₀₀=0.67) | **needs a tensor** — soft-diagonal, crosses 15% below ρ≈0.5. |
| **gyroid** | 1.05 → 1.16 | +13% at ρ≈0.30, +9% at ρ≈0.10 | **borderline** — stays ≈±13%, at/under the 15% line across the band; a scalar is defensible only if the ±13% is carried as error, not as truth. |

The 3-axis anisotropy test the earlier probe ran ([2026-07-26-lattice-phase0](2026-07-26-lattice-phase0.md)
§M6) reported 0.0% for all three — exactly because cubic symmetry forces Ex=Ey=Ez.
The full tensor here exposes the real (Zener) anisotropy that test is blind to:
**octet and Schwarz-D genuinely need a tensor; gyroid is borderline.**

---

## H3 — CONVERGENCE WITH CELL COUNT, single-cell error named

Two boundary conditions per cell count (L=5 mm, vpc=16, ρ≈0.30;
`h3_convergence.csv`):
(a) **periodic** homogenization — the effective-property machinery; (b) **direct
free-surface** uniaxial (production `fea_solve_cg`, free lateral) — the *windowed*
RVE the literature's single-cell warning is actually about.

| lattice | periodic E₁₀₀ (K=1..5) | free-surface single-cell err (K=1) | K=2 | K=3 |
|---|---|---|---|---|
| gyroid | **419.85 (0.00% flat)** | **−30.6%** | −15.7% | −10.7% |
| Schwarz-D | **711.77 (0.00% flat)** | **−0.3%** | −0.0% | +0.0% |
| octet | **280.58 (0.00% flat)** | **−2.3%** | −1.2% | −0.8% |

**Read this carefully — the periodic result is bit-identical across 1→5 cells
(0.00%).** That is not a null result: for a *periodic* medium a single periodic cell
is the **exact** effective property, so cell-count adds nothing. The literature's
"~15–16% single-cell error, avoid single-cell RVEs" is a **windowed / kinematic-
boundary** artifact that periodic BCs eliminate by construction — which is precisely
why periodic BCs are the mature choice. The genuine single-cell error therefore lives
in the free-surface column, and it is **topology-dependent**:

* **Schwarz-D and octet separate at ONE cell** (−0.3%, −2.3%) — bicontinuous /
  well-connected; a single cell already carries bulk behaviour. Matches the earlier
  probe's M3 (Schwarz-D reached bulk at 1 cell).
* **gyroid needs ~3 cells** (−30.6% at 1 → −10.7% at 3) — the free single gyroid cell
  is genuinely soft; the named single-cell error is **−30.6%**, decaying to the
  literature's ~10% band by 3 cells.

So the measured single-cell error, stated plainly: **periodic 0% (exact); free-surface
−30.6% (gyroid), −2.3% (octet), −0.3% (Schwarz-D).**

---

## HR — RESOLUTION CONVERGENCE (what the library resolution rests on)

The absolute tensor is voxel-resolution sensitive at thin walls; the library must sit
where it has stopped moving. Single cell, geometry fixed at a vpc=64 reference, only
resolution swept (`hr_resolution.csv`, ρ drifts at coarse vpc from aliasing):

| lattice | E₁₀₀/Es @ vpc 16 / 32 / 48 | Δ(32→48) | Zener @ vpc48 |
|---|---|---|---|
| gyroid | 0.098 / 0.113 / 0.115 | **1.8%** | 1.14 |
| Schwarz-D | 0.123 / 0.132 / 0.134 | **1.4%** | 0.84 |
| octet | 0.080 / 0.092 / 0.082 | **11%** | 1.22 |

**Gyroid and Schwarz-D are converged at vpc48** (≈7-voxel walls at ρ0.30) → the
library is trustworthy for ρ ≳ 0.20. **Octet is NOT fully converged even at vpc48**
(struts alias worse — the earlier M1 needed 6–8 vox/wall for octet vs 4 for TPMS), so
octet's *absolute* magnitudes carry ~±10% resolution uncertainty and low-ρ octet rows
are the least reliable. The `wall<4vox` rows are flagged in the library and excluded
from the scaling fits. (A cubic-symmetry sub-bug found and fixed in development — the
2-case fast path must recover C12 by the average-stress form, not the energy form —
is why these numbers supersede any mid-run intermediate; the fast path now matches the
full 6-case solve bit-for-bit, verified in `probe_stdout.txt`.)

---

## H4 — GO/NO-GO (bar: homogenized within 10% of a direct resolved 3-cell block)

Homogenized single-cell E₁₀₀ vs a **directly-resolved 3×3×3-cell free-surface block**
(production solver), same grid (vpc=16) for a fair comparison (`h4_go_no_go.csv`):

| lattice | ρ | homog E₁₀₀ | direct 3-cell E | gap | verdict |
|---|---|---|---|---|---|
| **Schwarz-D** | 0.375 | 711.77 | 712.03 | **0.04%** | **GO** |
| **octet** | 0.285 | 280.58 | 278.33 | **0.81%** | **GO** |
| gyroid | 0.305 | 419.85 | 375.04 | **11.9%** | **NO-GO (marginal)** |

**The homogenized road is OPEN for Schwarz-D and octet** (within 1% of a resolved
3-cell block) **and marginal for gyroid** (11.9% at 3 cells, driven by gyroid's slow
free-surface convergence in H3 — it clears 10% by ~3–4 cells). This is a materially
different and more favourable answer than the earlier probe's estimate, because it is
measured with periodic homogenization rather than inferred from the `f^1.5` knockdown.
Contrast the knockdown gap the earlier probe measured (17–52%, non-conservative):
**periodic homogenization is 0.04–0.81% (Schwarz-D, octet) — one to two orders better,
and it carries the anisotropy the scalar cannot.**

---

## H5 — SCALING LAW, MEASURED (E₁₀₀/Es ∼ ρ^p; do not assume 1.5)

Least-squares on ln(E₁₀₀/Es) vs ln ρ over the **resolved** rows (wall ≥ 4 vox):

| lattice | p (all resolved) | p (low-ρ half) | note |
|---|---|---|---|
| gyroid | **1.40** | 1.26 | bending-dominated TPMS; not 1.5 |
| Schwarz-D | **1.31** | 1.23 | bending-dominated TPMS; not 1.5 |
| octet | **1.78** | 1.56 | **NOT the textbook linear (~1.0)** |

**The assumed 1.5 is wrong for all three**, and in **both** directions: the TPMS run
~1.3–1.4 (below 1.5), octet runs ~1.6–1.8 (above). The octet result deserves a
caveat: the literature's linear E ≈ (1/9)·ρ̄·Es is a **ρ→0 stretch-dominated
asymptote**; at printable ρ 0.1–0.6 the joints/node volume add bending and the
measured exponent is well above 1 — *and* the low-ρ octet rows are the ones the HR
study flags as resolution-sensitive (thin struts alias, depressing E and inflating the
slope). So octet's exponent is measured ~1.6–1.8 here but is the least resolution-
robust number in the report. **Where the fit breaks down:** at high density the power
law flattens as E₁₀₀/Es → 1 (approach to solid) — visible as p(all) > p(low-ρ half)
for every topology; and at low density it breaks on resolution (the `*` rows).

---

## VERDICT — the homogenization road is OPEN (with named limits)

* **Instrument (H1):** exact to machine precision. Sound.
* **Tensor, not scalar (H2):** octet and Schwarz-D are genuinely cubic-anisotropic
  (Zener 1.61 / 0.64; E₁₁₁/E₁₀₀ up to +50% / −36%) — a scalar knockdown misrepresents
  them; gyroid is borderline (±13%). Phase 1 must carry a **stiffness tensor**, not a
  number, for octet and Schwarz-D.
* **Convergence (H3):** periodic single-cell is exact (0%); the real (free-surface)
  single-cell error is topology-dependent — Schwarz-D/octet separate at 1 cell,
  gyroid needs ~3.
* **GO/NO-GO (H4):** Schwarz-D and octet PASS the 10% bar at 3 cells (0.04%, 0.81%);
  gyroid is a marginal NO-GO (11.9%) that clears by ~3–4 cells. **Homogenization
  carries an honest margin where direct resolution (44×–276× the ceiling) never
  could.**
* **Scaling (H5):** measured p = 1.40 / 1.31 / 1.78 — the assumed 1.5 is wrong for
  all three; octet is not the textbook linear.

**Bottom line:** Road B (homogenize) is not just "not impossible" — it is **measured
open** for Schwarz-D and octet and marginal for gyroid, at unit-cell cost (seconds–
minutes on this 6-P-core Mac, adding **zero DOF** to the macro solve). Phase 1 can
wire these tensors in against these numbers. It is a **per-lattice, tensor-valued**
constitutive law (§2's excluded "infill homogenization"), not a scalar knockdown — a
maintainer decision recorded in DECISIONS, not made here.

---

## KNOWN LIMIT — stated, not solved: free surfaces, interfaces, graded transitions

Homogenization assumes local periodicity, which **fails exactly where printed lattice
parts fail**: at free surfaces, at solid-to-lattice interfaces, and across graded-
density transitions. H3/H4 measure this directly — the free-surface single-cell error
is −30.6% for gyroid, and a 3-cell free block sits 11.9% below the bulk tensor
(gyroid). For a large part the interior is bulk (homogenization is accurate there,
per H3) but a **~1–2-cell-deep boundary layer** at every free surface is softer than
the tensor predicts, and near a solid↔lattice interface the effective law is
undefined.

**What a localization step would look like (describe, do NOT build):** after the
coarse macro solve on the homogenized field, (1) read the macro strain in every cell
and rank by strain energy / a failure metric; (2) take the highest-strain cell(s) —
and every cell touching a free surface or a graded/interface transition — and
**re-simulate that single cell explicitly** at full resolution with boundary
conditions interpolated from the macro field (periodic-plus-macro-strain for interior
cells, the true traction-free condition for surface cells); (3) compare the localized
stress to the homogenized estimate and apply a correction / flag the margin where they
diverge. This is one *cell*-scale FEA per hot spot (thousands of DOF), not a part-scale
one — affordable, unlike Road A — and it is where the honest margin at the surface
would come from. It is Phase-2+ work, named here so Phase 1 does not silently claim
surface accuracy the periodic assumption cannot deliver.

---

## SCOPE COMPLIANCE

No production code, no `/app/`, no gate change, no knockdown-law change, no solver
wiring. The only new source is the standalone harness
`core/tests/harness/lattice_homog_probe.cpp` (not in CTest, mirrors the sanctioned
probe pattern). `ARCHITECTURE.md` §2 ("not a research project in infill
homogenization") is the clause Road B would amend — **not touched**; amending it, and
adding the validation-gate class effective moduli need (V1 beam theory cannot certify
a tensor), is a maintainer act for DECISIONS.md. No fixture, `materials.json`, ROADMAP
box or benchmark was added. The one thing this task cannot produce is a **physical
calibration** — printed-and-tested coupons at several volume fractions to anchor the
law empirically; that remains the maintainer's fixture if Phase 1 proceeds.

## VERIFICATION / REPRODUCE

From `core/`:
```bash
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_homog_probe.cpp build/libtopopt.a -o build/lattice_homog_probe
TOPOPT_LATTICE_CSV_DIR=../evidence/2026-07-26-lattice-homog-phase0 ./build/lattice_homog_probe
```
`TOPOPT_HOMOG_ONLY=h1|hr|h5|h3|h4` runs one section; `=verify` runs the 2-case-vs-
6-case tensor cross-check. Every number is first-hand in
`evidence/2026-07-26-lattice-homog-phase0/`: `probe_stdout.txt` (full run incl. the
H1 machine-precision self-check and the cubic2==full6 verify), `h1_self_check.csv`,
`tensor_library.csv` (the deliverable library), `hr_resolution.csv`,
`h3_convergence.csv`, `h4_go_no_go.csv`. The largest single solve was the H3 5-cell
periodic (512 k voxels, 1.5 M periodic DOF); everything ran on this 6-P-core Mac in
seconds–minutes — the part-scale wall of the earlier NO-GO is not hit because
homogenization is a **unit-cell** computation.

## Found in passing (NOT acted on)

The earlier probe's three flagged items (decoupled recommended-infill vs knockdown
input; core/app `f^1.5` copies un-pinned in CI; `mass_grams` solid mass shown as
"plastic") are unchanged and all become live if Phase 1 proceeds — the knockdown
copies especially, since this report's measured exponents (1.3–1.8, tensor-valued)
show `f^1.5` is the wrong law. No new production defect surfaced. Nothing was touched.
