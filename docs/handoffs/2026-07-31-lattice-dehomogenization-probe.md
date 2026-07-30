# Does macro stress predict strut stress? — de-homogenization PROBE

**Date:** 2026-07-31
**Branch:** `claude/lattice-macro-strut-stress-7ed495`
**Predecessors:** lattice layer anisotropy (`2026-07-29-lattice-layer-anisotropy` —
the ~25–44× estimate this probe was asked to turn into a measured law), multiscale
feasibility (`2026-07-31-multiscale-lattice-feasibility` — the certified designs J6
re-gates), homogenization library (`2026-07-26-lattice-homog-phase0`), density band
(`2026-07-28-lattice-density-band`).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang; library Release, harness -O2.
**Production change: NONE.** The production library is linked UNMODIFIED. The probe
lives in `core/tests/harness/lattice_dehomog_probe.cpp`; the instrument-pinning unit
test in `core/tests/unit/test_lattice_dehomog.cpp` (registered in `core/CMakeLists.txt`
— the only production-tree file touched, and only to add the test target). No gate
verdict, tolerance, fixture, or materials.json change; no assertion weakened.
**Evidence:** `evidence/2026-07-31-lattice-dehomogenization-probe/` (CSVs + logs +
`reproduce.sh`; deterministic — single-threaded solves, fixed-seed integer LCG only).

---

## Verdict in one paragraph

**Yes — there is a defensible map from macro stress + local rho to peak strut
stress, and PR 255's freshly-certified multiscale designs fail it.** The map is
NOT the scalar K·vm(Sigma) everyone (including PR 247) implicitly assumed — that
form is measurably unbounded, because hydrostatic macro stress carries zero
macro von Mises while octet struts still load (biaxial states already show 2×
the deviatoric worst case). The defensible form needs TWO invariants of the
macro tensor: `strut_vm <= K_dev(rho)·vm(Sigma) + K_vol(rho)·|p(Sigma)|`, which
is provably conservative under the cubic eigenspace split + von Mises
subadditivity, with K_dev the EXACT worst case over all deviatoric states
(computed per voxel as a 5×5 generalized eigenproblem, not sampled). Measured
across the band read from core: K_dev = 124 → 3.7 and K_vol = 61 → 2.9 (rho
0.048 → 0.896), a smooth per-rho table with <2% per-cell scatter at fixed
(rho, state) — a FUNCTION, not scatter, so the bound-only fallback was not
needed. Its error bar is resolution, not scatter: the joint peak grows ~log with
voxel refinement (+10–18% per 32→48 step where measured), so law rows quote the
finest measured vpc and the band floor row is a still-rising lower bound. Free
surfaces add only 7–21%; CUT cells add 43–79% and double their interlayer
amplification — the envelope over all populations is the law handed to J6.
Applied to PR 255's three ACCEPTED designs (shipped margins 1.455–1.497): strut
von Mises margins fall to 0.62–0.63 (still above the 0.5 bar), but the strut
INTERLAYER margins fall to 0.377–0.394 — **all three would be REJECTED at
margin_stop 0.5**, with the caveat that the interlayer term divides by the
unsourced z_knockdown=0.55; the measured ratios are reported separately and
survive any future re-sourcing of that constant.

---

## The question, restated precisely

Every lattice receipt carries `strength_uncertified = 1`: the gate certifies
STIFFNESS through the homogenized cubic tensor, but the macro stress at a latticed
voxel is the CELL-AVERAGE, and failure happens in one strut at a concentration.
This probe measures the amplification

    K(rho, state) = peak strut von Mises / macro von Mises

on strut-resolved octet blocks, asks whether K has usable structure (J3), whether
the strain STATE matters more than rho (J5), what boundary and cut struts add (J4),
what the measured law would have said about PR 255's certified designs (J6), and
what the same gap does to the interlayer check (J7) — which today reads +infinity
for a fully-latticed part because `analyze.cpp` excludes lattice voxels from the
interlayer field (ABSENT, not conservative).

## Method — why this instrument can answer it

* **Geometry is the library's own basis.** Legs-only octet struts (fc↔corner —
  exactly PR 198's `octet_struts`, the geometry inside the production
  `octet_relative_density` and the tensor rows), voxelized cylinders. Every strut
  radius is calibrated by bisection through the PRODUCTION `octet_relative_density`
  (vpc48 basis), so each K row keys on the same rho scale every certified job uses.
  Band endpoints are READ FROM CORE (`lattice_rho_min/max`), never hardcoded.
* **Micro stress is linear in the applied macro strain**, so each fixture is solved
  once per unit Voigt strain (6 solves) and every macro state is a superposition.
  Peak-vm and macro-vm are then quadratic forms in the 6-vector strain, so the
  worst case over ALL deviatoric states is an EXACT per-voxel 5×5 generalized
  eigenproblem — no sampling gap in the reported maximum. 512 fixed-seed sampled
  deviatoric states supply the distribution (min/median/p95/max) around it.
* **The bound has a provable shape.** Cubic symmetry maps traceless strain to
  traceless stress and hydrostatic to hydrostatic (pinned by unit test T5), and
  pointwise von Mises is subadditive, so

      peak_vm(any state) <= K_dev(rho)·vm(Sigma) + K_vol(rho)·|p(Sigma)|

  is RIGOROUS within the model once K_dev is the exact deviatoric worst case and
  K_vol the hydrostatic ratio (selfcheck S6 verifies it empirically on 64 mixed
  states). The hydrostatic term is not decoration: vm(Sigma) = 0 under hydrostatic
  strain while the struts still load — **no scalar macro-von-Mises law can be
  complete**, and this is measured, not argued (J5).
* **Fixtures.** `periodic` (1 cell, periodic BCs, Eigen — the bulk law, the N→∞
  interior limit); `kubc` (N×N×N cells, u = ε·x on all faces, PRODUCTION
  `fea_solve_cg` with nonzero Dirichlet — interior-cell convergence with N);
  `sandwich` (grips on two x faces, four lateral faces FREE — the free-surface
  population); `cut` (sandwich with the top cell layer cut at 0.6 of a cell — the
  cut-strut population PR 250/253 clipping makes real). Stress is recovered with
  the PRODUCTION `hex8_stress` at element centroids everywhere.
* **Instrument honesty (selfcheck + unit test, all green).** Solid-block KUBC
  reproduces K = 1 to the CG tolerance; superposition matches a direct combined
  solve to 7.5e-9; the periodic solid cell recovers the analytic isotropic tensor
  to 5e-15; the calibrated radius lands on the production rho scale to 3.2e-3;
  the dev/vol bound holds on mixed states.

## J1 — the fixture is honest: N and resolution convergence

**Convergence in N (cells per block) is settled.** Interior-cell exact K_dev on
finite KUBC blocks vs the periodic single cell, at matched vpc16:

| rho_lib | periodic | N=3 interior | N=4 interior | movement N3→N4 |
|---|---|---|---|---|
| 0.204 | 24.71 | 24.62 | 24.77 | +0.6% |
| 0.444 | 8.05 | 8.06 | 8.09 | +0.4% |

The periodic cell IS the interior limit to <1%, and N=4 has stopped moving —
**N is converged at 3–4 cells; the bulk law is measured on the periodic cell**
(the N→∞ instrument), with the finite blocks as its cross-check. Cells adjacent
to the kinematically-prescribed faces run ~10–12% hotter (K_dev 27.6 vs 24.8);
they are a BC artifact of the KUBC window and are excluded from every law row.

**Convergence in resolution is where the honesty lives.** The vpc study at
rho 0.20 / 0.45 (periodic, exact K_dev): 24.7 → 25.8 → 27.2 → 31.3 → 32.3 and
8.0 → 9.8 → 11.3 → 11.6 across vpc 16/24/32/40/48. The peak sits at voxelized
re-entrant joints and grows log-like without a finite limit (the p99 of the same
fields is converged to ~1% from vpc24 — see J3). The law rows quote the finest
measured vpc and carry the last-refinement drift as the resolution error bar;
the band-floor row (wall 2 voxels even at vpc48) is flagged still-rising.

## J2 — K measured across the band (expectation stated first)

**Stated before measuring** (printed by the probe before the sweep): PR 247's ~25×
(rho 0.31) / ~44× (rho 0.20) joint-peak estimate, i.e. K ~ A/rho with A ~ 8,
extrapolating to ~160 at the band floor and ~8–13 at 0.60–0.90; shear expected
WORSE than uniaxial per unit macro vm.

**Measured** (periodic bulk, finest resolved vpc per row; K = peak strut vm /
macro vm except the hydro column, which is peak vm per unit macro |pressure|):

| rho_lib | vpc | uni_x | biax_xy | shear_xy | shear_diag | uni_111 | K_dev_max (exact) | dev sampled min/med/p95/max | hydro peak/\|p\| |
|---|---|---|---|---|---|---|---|---|---|
| 0.0476 | 48 | 151.0 | 233.5 | 110.3 | 100.5 | 96.7 | 124.1 | 67 / 100 / 116 / 123 | 60.6 |
| 0.0951 | 48 | 99.4 | 140.9 | 57.7 | 56.9 | 56.3 | 65.4 | 38 / 55 / 62 / 65 | 37.9 |
| 0.1552 | 32 | 47.8 | 65.8 | 33.3 | 32.3 | 31.6 | 38.8 | 22 / 32 / 37 / 39 | 18.9 |
| 0.2041 | 48 | 48.2 | 60.5 | 25.7 | 26.9 | 29.9 | 32.3 | 20 / 28 / 31 / 32 | 18.4 |
| 0.3162 | 32 | 24.6 | 29.0 | 14.3 | 14.1 | 17.9 | 16.8 | 12 / 15 / 16 / 17 | 10.2 |
| 0.4439 | 32 | 18.0 | 19.8 | 8.9 | 9.5 | 14.4 | 11.3 | 8 / 10 / 11 / 11 | 8.2 |
| 0.6000 | 32 | 10.1 | 11.8 | 5.5 | 5.2 | 10.3 | 6.7 | 5.3 / 6.0 / 6.5 / 6.7 | 5.4 |
| 0.7521 | 32 | 6.3 | 8.1 | 3.6 | 3.5 | 7.8 | 4.7 | 3.2 / 3.7 / 4.4 / 4.7 | 3.6 |
| 0.8960 | 48 | 4.1 | 7.2 | 2.9 | 2.2 | 6.6 | 3.7 | 2.1 / 2.9 / 3.5 / 3.7 | 2.9 |

**Scorecard against the stated expectation.** The 25–44× estimate is CONFIRMED at
matched conditions: at PR 247's own vpc32, uniaxial K measures 24.6 (rho 0.316,
theirs ~25) and 42.6 (rho 0.204, theirs ~44). The rho scaling is close to and
slightly steeper than A/rho (power fit on the exact bulk dev maxima at finest
vpc: K_dev ≈ 3.74·rho^-1.22, worst row deviation 23% — which is why the LAW is
the per-rho table, interpolated, and the power fit stays descriptive). Two expectations were WRONG, in
instructive ways: (1) shear is NOT worse than uniaxial per unit macro vm —
uniaxial and especially BIAXIAL strain rank worse, because they carry hydrostatic
strain content that loads struts while contributing nothing to macro vm; (2) the
band floor lands near ~124–151×, short of the naive 160 extrapolation, but that
row is resolution-limited (wall 2 voxels at vpc48) and still rising with vpc —
treat it as a floor, not a converged value.

## J3 — function or scatter? A FUNCTION, with one caveat about what "peak" means

Three independent spread measurements, all small:

* **Across cells at fixed (rho, state):** in the sandwich fixtures, the per-cell
  K (each cell's own peak over its own envelope-averaged macro vm — exactly the
  local quantity a certification would apply) is essentially CONSTANT: interior
  cells spread <1% (e.g. 14.8–14.8 at rho 0.32 under uni_x across 8 cells),
  free-surface cells <2%. No order-of-magnitude scatter anywhere — the
  conservative-BOUND fallback is NOT needed; a law exists.
* **Across the deviatoric state sphere at fixed rho:** factor ~1.5–1.9 (J5),
  absorbed exactly by using the per-voxel worst case K_dev.
* **Across rho:** smooth and monotone; the per-rho TABLE interpolates within a
  few % (descriptive power fits miss rows by up to 23% on the bulk maxima —
  K_dev ≈ 3.74·rho^-1.22 — and 30% on the all-population envelope, 4.21·rho^-1.18
  per fit.log; so the table, not a fit, is the law).

**The caveat — the peak is a joint peak and it is mesh-DIVERGENT.** At rho 0.20
the raw uniaxial peak grows 32.9 → 38.1 → 42.6 → 47.0 → 48.2 across vpc
16/24/32/40/48 (voxelized re-entrant joints approximate a stress singularity;
+2.5% on the last refinement, log-like), while the volume-p99 of the SAME field
is converged to ~1% from vpc24 on (31.7/29.0/29.4/29.6). The law rows therefore
carry the finest-vpc PEAK (conservative direction) with the 32→48 drift (~+10–18%
where measured) as the stated resolution error bar; the physical cap on the real
part is the printed fillet radius, which voxel geometry cannot represent — in
BOTH directions (a printed fillet relieves the corner; print defects can be
worse). Rows with wall < ~3 voxels (the band floor) are flagged under-resolved
and still rising — treat the floor rows as lower bounds.

**Aliasing guard (instrument note, worth keeping).** At vpc16 the voxel-center
distance spectrum has a gap that maps the rho-0.10 and rho-0.157 radii onto the
IDENTICAL voxel set (both measure rho 0.119) — reproduced standalone, not a
probe bug. The fit therefore refuses any row whose measured density disagrees
with its library rho by >15%, and the low-rho boundary fixtures are re-measured
at vpc24 where the sets are distinct.

## J4 — boundary and cut struts vs interior (measured separately, as required)

Sandwich fixture (grips on two faces, four faces free) and cut fixture (top cell
layer sliced at 0.6 of a cell — the population PR 250/253 clipping makes real),
exact per-population K_dev:

| rho_lib | interior | free surface | cut layer | free/int | cut/int |
|---|---|---|---|---|---|
| 0.048 (vpc24, under-resolved) | 97.3 | 104.5 | — | 1.07 | — |
| 0.095 (vpc24) | 51.0 | 61.9 | — | 1.21 | — |
| 0.155 (vpc24) | 30.0 | 32.2 | — | 1.07 | — |
| 0.204 (vpc16) | 22.9 | 26.4 | 34.8 | 1.15 | **1.43** |
| 0.204 (vpc24) | 24.3 | 27.3 | — | 1.12 | — |
| 0.316 | 12.1 / 12.8* | 13.3 | 20.7 | 1.10 | **1.61** |
| 0.600 | 5.2 | 5.9 | 9.4 | 1.13 | **1.79** |
| 0.752 | 3.46 | 3.52 | — | 1.02 | — |
| 0.896 | 2.43 | 2.46 | — | 1.01 | — |

\* sandwich / cut fixture interiors.

* **Free surfaces of WHOLE cells are mild:** +7–21% over interior across the
  band, vanishing by rho 0.75. A bulk law is only slightly optimistic there.
* **CUT cells are the real boundary population:** +43–79% over interior, growing
  with rho, and their INTERLAYER amplification roughly DOUBLES (K_il_dev 22.7 vs
  11.9 at rho 0.20; 12.8 vs 6.5 at 0.32; 5.5 vs 3.4 at 0.60). A law fitted on
  interior struts only would be optimistic exactly where parts fail — the
  measured law's envelope (`K*_cert` columns of `kfit.csv`) therefore takes the
  max over bulk, free-surface and cut populations per rho.
* One relieving effect, named so nobody "fixes" it: near free surfaces the
  exact-worst INTERLAYER ratio is LOWER than periodic bulk (free faces cannot
  sustain the through-thickness constraint that maximizes n·sigma·n), so the
  bulk row dominates that column of the envelope — conservative for thick
  regions, correctly so.
* Boundary fixtures at the band floor are resolution-limited: at vpc16 the
  rho-0.05 lattice voxelizes DISCONNECTED (every voxel dropped by the floater
  guard) and 0.10/0.157 alias (J3); the vpc24 re-measurements cover them, and
  below that the envelope falls back to the bulk row.

## J5 — state dependence: which matters more, rho or state?

Split the question the way the physics splits it:

* **Within deviatoric states, rho dominates.** Across the band K_dev spans ~34×
  (3.7 → 124) while the spread across the entire deviatoric state sphere at fixed
  rho is only ~1.5–1.9× (sampled min→exact max, e.g. 20→32 at rho 0.20, 2.1→3.7 at
  0.90). A single per-rho K_dev (the exact worst case) costs at most that factor
  in conservatism and can never under-predict a deviatoric state.
* **But "state" is not one axis, and the volumetric direction is QUALITATIVE, not
  a factor.** Under hydrostatic macro strain the macro von Mises is EXACTLY zero
  (cubic symmetry — pinned by unit test T5) while the struts still carry
  10.2×|p| at rho 0.31 (60.6×|p| at the band floor). Any law of the form
  `strut_vm <= K·vm(Sigma)` is therefore UNBOUNDEDLY wrong on states with
  hydrostatic content — biaxial strain already shows it (K_vm(biax) = 60.5 at
  rho 0.20, nearly 2× the deviatoric worst case 32.3). This is measured, not
  hypothesized: **a scalar macro von Mises measure cannot certify strut strength.
  The certification needs the full macro tensor** — though only through TWO of
  its invariants:

      strut_vm <= K_dev(rho)·vm(Sigma) + K_vol(rho)·|p(Sigma)|

  which is rigorous by the cubic eigenspace split + von Mises subadditivity
  (selfcheck S6 verifies it on mixed states) and costs one table lookup and two
  invariants per voxel — the gate already carries the full `stress_tensor_field`,
  so the tensor is available where it would be needed.

## J6 — what would the gate have said about PR 255's designs? REJECTED, all three

The three certified multiscale designs (margins 1.455–1.497, all ACCEPTED, all
`strength_uncertified=1`) were rebuilt EXACTLY from the PR 255 evidence
(`p2_field_*.csv` + the same snap-to-feasible), re-run through the REAL
`analyze_fixed_design` (the shipped margins reproduce to 4 digits — the receipt
is the same solve), and the measured law applied to every latticed voxel's macro
stress tensor:

| design | shipped margin | max lattice macro vm | strut vm bound | strut VM margin | strut interlayer bound | interlayer margin | verdict at 0.5 |
|---|---|---|---|---|---|---|---|
| s0_plain | 1.497 (ACCEPTED) | 16.1 MPa | 89.2 MPa (argmax rho 0.63) | 0.616 | 76.9 MPa | 0.394 | **REJECTED** |
| s2_gappen | 1.481 (ACCEPTED) | 16.5 MPa | 87.0 MPa (argmax rho 0.90) | 0.632 | 79.6 MPa | 0.380 | **REJECTED** |
| s3_contin | 1.455 (ACCEPTED) | 17.8 MPa | 87.8 MPa (argmax rho 0.90) | 0.627 | 80.3 MPa | 0.377 | **REJECTED** |

Read it precisely — the two terms carry different confidence:

* **Strut von Mises alone: margins 0.62–0.63.** A ~2.4× cut from the shipped
  1.46–1.50, but still ABOVE the 0.5 acceptance bar. The certified stiffness
  margins were living almost entirely on strength headroom the gate never
  checked — yet on in-plane strength alone these particular designs would
  (barely) survive. The worst voxel is at HIGH rho (0.63–0.90): K is small
  there but the macro stress is largest — the danger is not where intuition
  puts it (the thinnest struts).
* **Strut interlayer: margins 0.377–0.394 — this is what rejects.** It compares
  the de-homogenized layer-normal tension bound (~77–80 MPa) against
  z_knockdown·yield = 0.55·55 MPa. The RATIO (bound/macro) is this probe's
  measured, geometry-driven number; the 0.55 it is divided by is the UNSOURCED
  constant (ARCHITECTURE.md:118) — reported separately exactly per J7. If the
  true interlayer knockdown were 1.0 the interlayer margins become 0.69–0.72
  and the verdict flips to (barely) accepted on both terms; at any realistic
  FDM knockdown it stays rejected.

Also worth the maintainer's eye: these designs declare cell_size 4 mm inside a
48×24×6 mm domain — 1.5 cells through the thickness, far below the measured
5-cells-per-member floor (`lattice_cells_per_member_min`), so their HOMOGENIZED
stiffness field itself is outside the tensor's validated regime. The strength
verdict above is therefore, if anything, generous to them.

## J7 — interlayer, strut-resolved vs macro

The interlayer gap is worse than the von Mises gap in structure, not just size:
today a lattice voxel is EXCLUDED from the interlayer field (`analyze.cpp:258`),
so a fully-latticed part reports `margin.interlayer = +inf` — ABSENT, not
conservative. Measured on the strut-resolved model (build direction z; by cubic
symmetry x/y are the same law):

* **The ratio (geometry-only, robust):** peak strut layer-normal tension per
  unit macro layer-normal tension, uniaxial-along-build state: 51.2 (rho 0.048),
  37.9 (0.095), 28.0 (0.155), 27.6 (0.204), 17.4 (0.316), 13.8 (0.444), 8.0
  (0.60), 4.8 (0.752), 2.4 (0.896). Load transverse to build (uni_x) is milder
  (e.g. 14.5 at rho 0.32) — same orientation rule as solids, measured at strut
  level. The exact worst-case dev/vol interlayer envelope is in `kfit.csv`
  (`Kild/Kilv` columns); cut cells DOUBLE their interlayer amplification (J4).
* **Absolute margins inherit z_knockdown** (assumed 0.55, unsourced —
  ARCHITECTURE.md:118) and are quoted only inside J6's receipts, with that label
  attached. The ratio table above is the durable measurement.

## J8 — determinism + no production changes

* **Byte-identical rerun:** TWO complete independent runs of every phase with
  the final binary (run A = the evidence dir, run B = a scratch dir) produced
  byte-identical output for all 11 CSVs and `j6_receipts.txt` —
  `determinism_rerun.sha256`. No threads (`fea_set_matfree_threads(1)`;
  Eigen CG and assembled Jacobi-CG are sequential), no RNG except the
  fixed-seed integer LCG for the sampled states.
* **Full ctest green:** 82/82 pass, including the new `lattice_dehomog`
  instrument test (total 822 s on the machine of record, under concurrent
  probe load).
* **Stash-rebuild identity:** with `core/CMakeLists.txt` stashed (the only
  tracked-file change; everything else is additive harness/test/evidence
  files) the library rebuilds and the certification-path ordinary run
  (`test_analyze_fixed_design`) is BIT-IDENTICAL to the run with the probe's
  changes present (`cmp` clean on full stdout). The probe cannot have touched
  production behavior.
* The J6 receipts double as an end-to-end identity check: re-running the real
  `analyze_fixed_design` on the rebuilt PR 255 designs reproduces the shipped
  margins 1.4967 / 1.4811 / 1.4550 to four digits.

## The gate change a strength certification WOULD need (shape only — NOT made)

Reported because the task requires naming it; nothing here was implemented:

1. In `analyze_fixed_design`, for each latticed voxel the effective stress
   tensor is already computed (`hex8_stress_cubic` → `stress_tensor_field`).
   A strength gate would evaluate `K_dev(rho_v)·vm + K_vol(rho_v)·|p|` per
   latticed voxel from a shipped per-rho law table (the `K*_cert` columns of
   `kfit.csv`), take `yield / max(...)` as `margin.lattice_strut`, the analogous
   `Kild/Kilv` bound against `z_knockdown·yield` as `margin.lattice_interlayer`,
   and fold both into the acceptance min. `lattice_strength_uncertified` would
   then finally be droppable.
2. The law table becomes a versioned material artifact like the tensor rows
   (same octet ±10% resolution caveat, plus this probe's joint-peak resolution
   bar), keyed on the same rho scale (`octet_relative_density`).
3. Open items before arming: the band floor row is a still-rising lower bound
   (needs vpc>48 or a fillet-resolved model); z_knockdown is unsourced
   (coupons); layer-anisotropy of the BASE material (PR 247) stacks on top of
   this purely-geometric law; other topologies have no law at all.

## Files

* `core/tests/harness/lattice_dehomog_probe.cpp` — the probe (phases: selfcheck,
  bulk, blocks, boundary, fit, j6). Harness-only, Eigen for the periodic cell,
  PRODUCTION `fea_solve_cg` / `hex8_stress` / `octet_relative_density` /
  `lattice_cubic_tensor` / `analyze_fixed_design` everywhere they exist.
* `core/tests/unit/test_lattice_dehomog.cpp` — instrument pinned to production
  (T1 affine patch K=1, T2 superposition, T3 rho mapping + band, T4 stress
  recovery, T5 cubic eigenspace split). Registered in `core/CMakeLists.txt`
  (the only production-tree file touched).
* `evidence/2026-07-31-lattice-dehomogenization-probe/` — `k_states_bulk.csv`,
  `k_exact_bulk.csv`, `bulk_tensor.csv`, `k_states_blocks.csv`,
  `k_exact_blocks.csv`, `k_states_boundary.csv`, `k_exact_boundary.csv`,
  `k_cells.csv`, `kfit.csv` (the law), `j6_margins.csv`, `j6_receipts.txt`,
  `selfcheck.csv`, phase logs, `reproduce.sh`, determinism checksums.

## What this probe deliberately did NOT do

No production arming; no edit to `run_job.cpp`, `lattice_boundary.*`,
`lattice_gen.*`, `analyze.cpp`, fixtures, or `materials.json`; no gate change. The
gate-change SHAPE a strength certification would need is described in J6/J8 as a
finding, not smuggled in.

## Plain language

Imagine the lattice inside a part as a sponge of thin plastic rods. When the
software checks whether a latticed part is strong enough, it currently smears
each spongy region into a uniform block of "effective material" and computes the
stress of that smeared block. But the part doesn't break as a smeared block — it
breaks at one rod, at the corner where rods meet, where the real stress is many
times higher than the smeared number. Until now the software knew this blind
spot existed (every report says "strength uncertified") but nobody had measured
HOW MUCH higher the real rod stress is.

This probe built the real thing: blocks of actual rods, simulated rod by rod,
squeezed and sheared every way a part can be loaded, and compared the true worst
rod stress against the smeared prediction. The answer: at a comfortable medium
density the rods see about 10–30× the smeared stress; at the thinnest printable
density, over 100×. The good news is that this ratio is orderly — it depends on
the sponge density and the type of loading in a smooth, repeatable way, so it
can be written down as a lookup table and used for certification. Two genuine
surprises came out. First, the usual single-number stress summary (von Mises)
can be fooled completely: squeezing a lattice equally from all sides shows up as
ZERO on that summary while the rods inside are very much loaded — so a strength
check must look at two numbers from the stress, not one. Second, rods that get
sliced through where the lattice meets the part's surface (which the current
clipping does all the time) run up to ~80% hotter than rods deep inside, and
their layer-peeling stress doubles.

Then the probe asked the question that matters: the three lattice designs the
gate certified two days ago with comfortable-looking margins of ~1.5 — would
they survive a strength check built on these measurements? No. All three fail.
Their ordinary strength margin drops to ~0.62 (just above the acceptance line of
0.5), and their layer-peeling margin drops to ~0.38, below the line. In plain
terms: the certified stiffness numbers were real, but the parts would likely
fail at the rods — most likely along the print layers — well before the report's
margin suggested. One honest caveat: the layer-peeling number divides by a
"how much weaker are layer bonds" constant that has always been a guess in this
codebase; the measured geometric ratios are reported separately so they survive
whenever that constant gets measured for real. Nothing in the shipping product
was changed by this probe — it hands the maintainer the measured table, the
receipts, and the exact shape of the gate change a real strength certification
would need.
