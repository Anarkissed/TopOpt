# Lattice material model + forbidden-interval feasibility — PROBE

**Date:** 2026-07-31
**Branch:** `claude/lattice-material-forbidden-interval-265383`
**Predecessors:** matrix-free cubic tensor probe (`2026-07-30-matfree-cubic-probe`
— the SOLVER can carry per-voxel cubic tensors; this probe asks whether the
OPTIMIZATION FORMULATION can), tensor library nine (`2026-07-29-tensor-library-nine`),
density band extension (`2026-07-28-density-band-extension`), lattice certification
Phase 1 + E2E (`2026-07-27-lattice-certification`, `2026-07-29-lattice-certification-e2e`).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang; library Release, harness -O2.
**Production change: NONE.** The production library is linked UNMODIFIED. The material
model lives in the harness header `core/tests/harness/lattice_material_model.hpp`; the
Part 1 bars in `core/tests/harness/lattice_material_probe.cpp`; the Part 2 optimizer
loop in `core/tests/harness/lattice_gap_probe.cpp`; the pinning unit test in
`core/tests/unit/test_lattice_material_model.cpp` (registered in core/CMakeLists.txt —
the only production-tree file touched, and only to add the test target). No constant
armed, no default changed, no gate logic or tolerance touched.
**Evidence:** `evidence/2026-07-31-multiscale-lattice-feasibility/` (CSVs + logs +
`reproduce.sh`; deterministic — no RNG, no threading in the harness loop).

---

## Verdict in one paragraph

**Part 1 — the material model works.** A three-regime tensor curve C(ρ) (Hermite
void bridge → origin-anchored polynomial fit through the measured rows → quadratic
solid bridge) passes every stated bar for all seven cubic topologies: max row error
≤ 3.1%, held-out (leave-one-out) max ≤ 6.5% (both inside the library's own ±10%
measurement caveat), cubic-admissible and derivative-PSD at EVERY point of [0,1]
including both bridges, sensitivities exact to 9×10⁻⁹ against finite differences,
C0/C1 clean at both regime joints. **Part 2 — the forbidden interval is real but
cheap.** On a cantilever fixture, NO in-loop strategy (plain, gap-penalized,
continuation) reached zero voxels inside the gaps — the density filter's transition
band guarantees a nonzero gap population (85–100% of parked voxels sit on a
void↔band or band↔solid ramp, and classic SIMP parks even more voxels at illegal
intermediate densities on the same fixture). But snapping the survivors to the
nearest feasible value costs **+0.13–0.18% volume for −0.4–0.5% compliance**
(slightly better, because snap rounds half of them up), and the REAL certification
gate then **ACCEPTS the snapped graded designs** (per-voxel ρ ∈ [0.0505, 0.8999]
across 3,648–3,833 latticed voxels) and **REFUSES the unsnapped one** via the E5
band gate exactly as it should. **The blocker for Phase 2 is not the gap and not
the gate — it is that six of seven topologies have too few rows above their band
ceiling (G4/G4b), and that the upper gap for those six is a 0.41–0.50-wide hole the
model bridges with pure interpolation.**

---

## What PR 252 settled vs. what this probe asked

PR 252 proved Ke = C11·K_A + C12·K_B + C44·K_C exactly, and that a matrix-free
cubic apply runs at 2.4–2.7× scalar cost with multigrid/GenEO/recycling engaged.
The SOLVER is not the question. This probe asked the FORMULATION question: SIMP
penalizes intermediate density because it is unrealisable; with lattices it IS
realisable — a voxel at ρ is a lattice cell with a MEASURED tensor — but only
inside the certified band. The feasible set is {0} ∪ [ρ_lo, ρ_hi] ∪ {1}: two
forbidden intervals per topology, where a gradient method can park voxels that
are neither printable lattice nor void nor solid.

---

## PART 1 — the material model C(ρ)

### The construction (harness header `lattice_material_model.hpp`)

Three regimes, per topology, per component (C11, C12, C44):

| regime | ρ range | form | properties |
|---|---|---|---|
| void bridge | [0, ρ_lo) | cubic Hermite, value 0 AND slope 0 at ρ=0, value+slope matched to the fit at ρ_lo | reaches exactly 0; C1 joint |
| lattice (fit) | [ρ_lo, ρ_hi] | origin-anchored polynomial Σₖ aₖρᵏ, k = 1..nterms, weighted least squares in RELATIVE error through the RESOLVED rows | C∞; nterms = 4 when ≥ 6 resolved rows, else 3 (fixed rule, stated before measuring) |
| solid bridge | (ρ_hi, 1] | quadratic, value+slope matched at ρ_hi, exact isotropic solid triplet at ρ=1 | reaches exactly (c(1−ν), cν, E/2(1+ν)); C1 joint |

Band endpoints are READ FROM CORE (`lattice_rho_min`/`lattice_rho_max`) at build
time, never hardcoded. The row tables are transcribed from `lattice.cpp`; the unit
test pins every row against `lattice_cubic_tensor` at the row's own ρ (interpolation
weight is 0 at an anchor, so the library returns the row exactly) and the band
endpoints against core — a core table change breaks the test, it cannot silently
skew the fit.

Model choice was prototyped against two families (log-log polynomial vs
origin-anchored polynomial): log-log needs degree ≥ 3 for comparable accuracy and
structurally cannot reach C = 0 at ρ = 0; origin-anchored reaches 0 exactly and won
on held-out error at every table size. The naive alternative lower bridge — just
extending the fit below ρ_lo — goes INADMISSIBLE for kelvin (C11−|C12| hits −0.29,
C44 < 0) and rhombic (C44 < 0), which is why the explicit Hermite bridge exists.

### G1 — fit accuracy (bar stated first: row max ≤ 5%, row RMS ≤ 2%, LOO max ≤ 10%)

The LOO bar is 10% because the rows themselves carry a ~±10% resolution caveat
(lattice.hpp) — a fit cannot be more trustworthy than its data, and demanding
held-out error under the data's own uncertainty is the honest ceiling.
**All 21 topology×component cells PASS** (`g1_fit_accuracy.csv`):

| topology | rows | nterms | worst row max (comp) | worst LOO max (comp) |
|---|---|---|---|---|
| octet | 19 | 4 | 3.09% (C12) | 5.07% (C12) |
| sc | 7 | 4 | 1.83% (C44) | 6.50% (C44) |
| bcc | 5 | 3 | 0.68% (C12) | 3.16% (C11) |
| fcc | 7 | 4 | 0.82% (C11) | 2.46% (C12) |
| diamond | 6 | 4 | 0.69% (C11) | 1.94% (C44) |
| kelvin | 6 | 4 | 1.01% (C11) | 4.86% (C11) |
| rhombic | 4 | 3 | 0.36% (C11) | 3.40% (C11) |

C12 is systematically the hardest component (octet row max 3.09% vs ≤ 0.95% for
C11/C44) — it has the strongest curvature in ρ. Note the row counts: "8 rows" from
the task brief is optimistic — the six analysis-only topologies have only **4–7
RESOLVED rows** once the unresolved head/tail rows are excluded (the resolved span
is what the band covers).

### G2 — admissibility everywhere (bar: every tensor margin > 0 on (0, 1])

Dense sweep, 4,000 points per region, per topology, over the FULL [0,1] including
both bridges (`g2_admissibility.csv`). **All PASS.** Worst normalized margins
(full range): bcc C11−|C12| = 0.055 (its C12/C11 ratio is genuinely high — Zener
≫ 1 bending topology), everything else ≥ 0.09; C44/C11 ≥ 0.009 (sc, whose shear
is genuinely tiny). Also swept: the DERIVATIVE'S PSD margins (dC11−dC12,
dC11+2dC12, dC44 > 0 everywhere) — dC/dρ being PSD is what makes stiffness
monotone in ρ and compliance sensitivities one-signed for the optimizer; all
positive. The unit test additionally feeds swept tensors through
`hex8_stiffness_cubic` — the production element's own admissibility check accepts
the whole curve.

### G3 — sensitivities (bar: FD relative error ≤ 1e-6 away from the two C1 joints)

Central finite differences (h = 1e-6) vs the analytic dC/dρ at 2,000 points:
worst interior error **9.6×10⁻⁹** across all topologies/components; at the joints
(within 2h) worst 1.6×10⁻⁶ — the expected O(h·|ΔC″|) of a C1 joint, reported
separately (`g3_sensitivity_fd.csv`). Smoothness: dC/dρ is tabulated at 400 points
per topology (`g3_sensitivity_curve.csv`); it is piecewise-smooth with NO C1 kinks
anywhere (the joints are C1 by construction) — the only non-smoothness in the whole
model is the C2 jump at the two joints. Nothing for an optimizer to stall on.

### G4 — table adequacy: how few rows still support a trustworthy derivative?

Octet decimated to evenly-spread subsets, refit under the same fixed order rule,
compared to the 19-row fit ACROSS the band (`g4_table_adequacy.csv`):

| rows kept | nterms | worst value dev | worst deriv dev | verdict |
|---|---|---|---|---|
| 8 | 4 | 1.08% (C12) | 2.10% (C12) | supports |
| 6 | 4 | 2.34% (C12) | 4.19% (C12) | supports |
| 5 | 3 | 14.43% (C12) | 35.31% (C12) | **too few** |
| 4 | 3 | 13.32% (C12) | 34.89% (C12) | **too few** |

The cliff is the model order, not the row count per se: 6–8 rows carry a 4-term
fit fine; at ≤ 5 rows the rule drops to 3 terms and the C12 DERIVATIVE goes to
~35% error — an optimizer steering on that would chase a fiction. Read-across to
the six analysis-only topologies (with the caveat that their bands are ~half as
wide, which is exactly why their own G1 LOO numbers still pass): **bcc (5 resolved
rows) and rhombic (4) sit below the cliff** — their in-band fits are fine today
only because their bands are narrow; they cannot support band extension or
derivative-hungry use without more rows. sc/fcc (7), diamond/kelvin (6) are at the
edge: adequate in-band, no margin for widening.

### G4b — gap severity (the upper gap is the harder case, reported separately)

From `g4b_gaps.csv` (bands read from core):

| topology | band | lower gap | upper gap | upper/lower | C11 jump across upper gap |
|---|---|---|---|---|---|
| **octet** | [0.050, 0.900] | 0.050 | **0.100** | 2.0× | 1.36× |
| sc | [0.087, 0.496] | 0.087 | **0.504** | 5.8× | 4.62× |
| bcc | [0.211, 0.593] | 0.211 | **0.407** | 1.9× | 4.62× |
| fcc | [0.095, 0.591] | 0.095 | **0.409** | 4.3× | 3.85× |
| diamond | [0.157, 0.592] | 0.157 | **0.408** | 2.6× | 4.25× |
| kelvin | [0.094, 0.505] | 0.094 | **0.495** | 5.3× | 4.48× |
| rhombic | [0.172, 0.513] | 0.172 | **0.487** | 2.8× | 5.20× |

**Plain statement on the six analysis-only topologies:** for multiscale TO they
are NOT usable today. Their upper gap is a 0.41–0.50-wide interval in which the
model is pure interpolation between a measured point and the solid corner — a
stress concentration that wants ρ ∈ (0.6, 1.0) would traverse ~40+ points of
unmeasured territory carrying a 3.9–5.2× stiffness swing. (For CERTIFICATION they
remain fine: the E5 gate refuses out-of-band postures regardless of this model.)
They need rows above ~0.6 first — octet's PR 237 extension measured 7 new rows
(0.615–0.900) to close a 0.31-wide gap; scaling by width, **each of the six needs
roughly 8–11 additional rows** (~0.04–0.05 ρ spacing, matching PR 237's grid) to
reach a defensible ~0.90 ceiling, plus 1–3 more rows for bcc/rhombic to clear the
G4 cliff in-band. Octet's own gaps (0.050 / 0.100) are narrow and bridged tightly
(1.36× C11 jump) — which is why Part 2 runs on octet and why it works.

### G5 — regime bridging (bar: no jump beyond the O(ε·slope) drift at ±1e-9)

Both joints, all topologies, all components (`g5_bridge_continuity.csv`): C0
"jump" ≤ 4.5×10⁻⁸ and C1 ≤ 2.1×10⁻⁸ relative — entirely accounted for by the
smooth slope drift across the 2×10⁻⁹ measurement window, i.e. **no discontinuity;
the joints are exactly C1 as constructed.** (The gap-penalized STRATEGY of Part 2
deliberately introduces a C1 kink at the band edges — dC11 drops 2199→833 at ρ_lo
and 11823→0 at ρ_hi for p=3 — that is its mechanism, logged as its price.)

---

## PART 2 — the forbidden interval, on octet

### Fixture (identical for every strategy)

48×24×6 cantilever (1 mm voxels, 25,725 DOF), root face fixed, −200 N tip line
load at mid-height; PLA (E=3500, ν=0.33); volume fraction 0.35; density filter
radius 1.5 voxels; the probe's own OC updater (volume constraint enforced on the
PHYSICAL filtered density, λ by bisection); 120 iterations each. In-loop solver:
the PRODUCTION `fea_solve_cg_lattice` (per-voxel cubic tensor, assembled
Jacobi-CG) at 1e-6; final/cert solves at 1e-8. Void floor: additive ε·C_solid,
ε = 1e-6. Occupancy classes: void ρ ≤ 1e-3, solid ρ ≥ 1−1e-3, band per the core
endpoints ±1e-9, gaps in between.

### What each strategy did and where it parked (6,912 voxels)

From `p2_occupancy.csv` / `p2_trace.csv` / `p2_snap.csv`:

| strategy | void | lower gap | band | upper gap | solid | gap total | final compliance |
|---|---|---|---|---|---|---|---|
| simp (ρ³ comparison) | 2,636 | 556 | 2,556* | 508 | 656 | 1,064 (+2,556*) | 205.3 |
| s0_plain (no gap handling) | 2,120 | 528 | 3,320 | 412 | 532 | 940 | 185.3 |
| s2_gappen (p=3 in-gap SIMP curves) | 2,036 | 425 | 3,613 | 266 | 572 | 691 | 186.9 |
| s3_contin (40 plain → 40 p=3 → 40 p=6, damped move) | 2,022 | 402 | 3,565 | 303 | 620 | 705 | 188.9 |

\* For SIMP the whole 0/1 interpretation makes EVERY intermediate voxel illegal:
3,620 voxels sit in (0.001, 0.999). The lattice material model LEGALIZES 2,556 of
them (they are certifiable lattice); the honest comparison is SIMP's 3,620 illegal
voxels vs the lattice formulation's 691–940.

**BLOCKED-STOP taken, as instructed: NO strategy reached zero gap voxels.** Where
they parked: the ramp-fraction metric (share of gap voxels with a 6-neighbour
differing by more than half the gap width — i.e. sitting on the filter's
void↔band or band↔solid transition layer) is **96.5–100% for every strategy and
both gaps** (s0 100%/98.1%, s2 99.5%/100%, s3 96.5%/100%, simp 100%/100%) — the
gap population IS the density filter's transition band, not an interior region
the optimizer prefers. The filter GUARANTEES a nonzero gap population: any void↔band
boundary must pass through (0, ρ_lo) over ~1 voxel ring at radius 1.5. Gap
penalization thins it (s2 cut the upper gap 412→266 and steepened the ramps) but
cannot zero it while the filter is in the chain. This is the same phenomenon that
makes unprojected SIMP gray at boundaries — production SIMP solves it with
Heaviside projection continuation, which is exactly the shape of the Phase-2 fix
here (a projection that maps the filtered field onto the feasible set, β-scheduled).

### The price of feasibility: snap + re-solve (cert tolerance 1e-8)

Snapping every surviving gap voxel to its nearest feasible value (lower gap →
{0, ρ_lo}, upper gap → {ρ_hi, 1}), then re-solving:

| strategy | snapped (lo+up) | Δcompliance | Δvolume |
|---|---|---|---|
| s0_plain | 528 + 412 | **−0.48%** | +0.18% |
| s2_gappen | 425 + 266 | **−0.41%** | +0.13% |
| s3_contin | 402 + 303 | **−0.46%** | +0.13% |

Feasibility is essentially FREE on this fixture: snap trades +0.13–0.18% mass for
−0.4–0.5% compliance (half the snapped voxels round up, so the design gets
slightly heavier and stiffer). The forbidden interval is an accounting problem at
the boundary layer, not a structural trap.

### The gate receipt (`p2_gate_receipts.txt`)

The REAL certification gate (`analyze_fixed_design` + `LatticePosture`), untouched:

* **All three snapped designs: ACCEPTED.** `lattice_certified=1`, 3,648–3,833
  latticed voxels carrying a GRADED per-voxel ρ spanning [0.0505, 0.8999] (the
  full core band), margin 1.46–1.50 at margin_stop 0.5, certification solve
  converged, `lattice_strength_uncertified=1` flagged as designed (strut-level
  strength stays Phase-2 de-homogenization work).
* **The unsnapped s0 design: REFUSED** — `LatticeDensityOutOfBand`, offending
  ρ = 0.9936 against band [0.0505, 0.8999], the E5 message verbatim in the
  receipt. The band gate does its job against exactly the failure mode this
  probe measured.

So: **the existing gate structurally CAN certify a graded design** — the
`LatticePosture.relative_density` vector is per-voxel and the E2E path exercised
it here at 3,600+ distinct densities. No gate work is needed for grading;
what is needed is the projection step that guarantees the field handed to the
gate is feasible.

### In-loop CG behaviour (`p2_trace.csv`, cg_iters column)

Jacobi-CG iterations per in-loop solve (25,725 DOF, tol 1e-6, 1e-6 void floor):

| strategy / phase | n solves | min | mean | max |
|---|---|---|---|---|
| simp | 120 | 236 | 442 | 460 |
| s0_plain | 120 | 207 | 344 | 368 |
| s2_gappen (p=3) | 120 | 207 | 473 | 946 |
| s3_contin phase 1 (plain) | 40 | 207 | 304 | 359 |
| s3_contin phase 2 (p=3) | 40 | 345 | 364 | 368 |
| s3_contin phase 3 (p=6) | 40 | 368 | 474 | 914 |

The cubic-tensor in-loop solves are unremarkable: no non-convergence anywhere
(including every 1e-8 cert solve), counts drift up as void/solid contrast forms.
The plain lattice model actually solves CHEAPER than SIMP (mean 344 vs 442 —
its stiffness contrast between neighbouring densities is milder than ρ³'s). The
one flag: the sharpened gap curves (s2 late iterations, s3's p=6 phase) pay up
to ~2.7× the plain cost per solve — penalization steepens the stiffness
contrast at the band edges. A production loop would want the PR 252 matrix-free cubic path +
multigrid/GenEO anyway; nothing here changes that conclusion.

---

## Files

* `core/tests/harness/lattice_material_model.hpp` — the model (fit + bridges),
  shared by both probes and the unit test. Harness-only.
* `core/tests/harness/lattice_material_probe.cpp` — Part 1 bars G1–G5.
* `core/tests/harness/lattice_gap_probe.cpp` — Part 2 fixture, strategies, snap,
  gate receipts.
* `core/tests/unit/test_lattice_material_model.cpp` — pins transcription to core,
  end-point exactness, continuity, FD sensitivities, admissibility (incl. the
  production element's own check), tetragonal refusal. Registered in
  `core/CMakeLists.txt` (`lattice_material_model`).
* `evidence/2026-07-31-multiscale-lattice-feasibility/` — all CSVs, logs,
  `reproduce.sh`.

## What this probe deliberately did NOT do

No production arming; no edits to matfree.cpp / geneo.cpp / production.cpp; no
gate verdict/tolerance change; no fixture or materials.json change; no assertion
weakened. The G4/G4b findings are reported as findings (probe exit code reflects
implementation bars only). The Heaviside-onto-feasible-set projection, the
matrix-free-cubic optimizer loop, and strut-level strength (de-homogenization)
are named Phase-2 work, not smuggled in.

---

## Plain language

Think of every small cube of the part as having a dial from 0% to 100% material.
The old optimizer (SIMP) punishes any middle setting, because a 40%-dense blob of
plastic isn't a thing you can print. But a 40%-dense LATTICE is a thing you can
print — and we have real measured stiffness numbers for it. So this probe built
the "dial-to-stiffness" curve from those measurements.

The catch: the measurements only cover part of the dial. For the octet lattice
it's 5%–90%; below 5% the struts are too thin to trust, above 90% it's nearly
solid. So the legal settings are "off", "5–90%", or "fully solid" — with two
forbidden zones in between. The worry was that the optimizer would leave lots of
cubes stuck in those zones, where we can neither print nor certify them.

What we found: the curve itself is solid — it matches the measurements to a few
percent, it's smooth, and its slopes (which the optimizer steers by) are exact.
The optimizer does leave some cubes in the forbidden zones — around 10% of them,
almost all sitting on the blurry boundary between empty and lattice regions,
which the smoothing filter creates by construction. But nudging each of those
cubes to the nearest legal setting costs essentially nothing — the design gets
0.15% heavier and slightly stiffer — and the real certification machinery then
accepts the result, including a different density in every single lattice cube.
It also correctly rejects the un-nudged design. So the forbidden zones are a
solvable bookkeeping problem, not a wall.

The real wall is elsewhere: six of the seven lattice types only have measurements
up to ~60% density, so the "60% to solid" stretch of their dial is guesswork —
far too wide a stretch to optimize across. Only octet is ready. Before anyone
builds the full multiscale optimizer on the other six, they need roughly 8–11
more measured points each at the dense end (and bcc/rhombic need a few more
points, period — their tables are so sparse the fitted slopes can't be trusted
if their range ever widens).
