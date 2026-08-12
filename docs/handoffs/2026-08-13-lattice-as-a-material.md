# lattice-as-a-material — a frozen region as a MATERIAL, not as solid

Evidence: `evidence/2026-08-13-lattice-as-a-material/`. The pre-registration
(`r0_preregistration.md`) was **committed before the first arm ran** — commit
`00eff24`, whose tree contains that file and nothing else under that directory.

★ **THIS HANDOFF REPORTS AN INCOMPLETE MEASUREMENT CAMPAIGN AND SAYS SO IN §0.**
The mechanism is built and receipted, the law's validity range is measured, his
frozen set is decomposed and priced, and the assignment table is STARTED — two
of its cells are in the record and all three of the findings that fall out of
them are in §0.3. What did not run, and the measured cost that stopped it, are
in §0.6 and §7. **Nothing below is estimated, and no gross saving is presented
as a saving.**

---

## 0. THE ANSWERS, IN ORDER — one line each

### 0.1 ★ The law's reach at his cell — and it clears, barely, on the median only.

At a **0.45 mm** nozzle the thinnest member that can hold a CERTIFIABLE octet
lattice — at *any* (cell, density) pair in the band — is **5.8659 mm**. At his
declared **2 mm** cell the homogenisation floor of **5 cells per member** demands
a **10 mm** member, and the lightest density whose strut still prints at that
cell is **0.2651**, not the band floor of 0.0505.

His face protection is declared at **5.0 mm** depth (3 voxels at his 1.705 mm
spacing), which read as its own member would be **half** the thinnest certifiable
member at his nozzle. Measured, it is not its own member — it is 26-connected to
the load pad, and the combined region's **median** thickness is 10.2317 mm, which
clears the floor by 2.4%. **60.2% of that region's voxels clear it; 39.8% do
not.** §0.2b. `evidence/…/m0/law.txt`, `evidence/…/m1/regions_r0.68.txt`.

### 0.2 ★ How much of the 247.3 g sits in QUIET regions: **NONE OF IT.**

`evidence/…/m1/regions_r0.68.txt`. Measured on his converged rung 0.68 with one
certification solve, against **core's own** quiet predicate
(`lattice_subfloor_retention_stress_fraction` = 0.20 — the same one
`grade_lattice` arms sub-floor retention on, so the probe and the shipped grading
law cannot disagree about which regions are quiet).

| region | voxels | mass | strain energy | share | peak vM | vM / part peak | verdict |
|---|---|---|---|---|---|---|---|
| **load-pad-1** | 29,250 | **179.860 g** | 5.450e-04 | **45.42%** | 0.0169 | ★ **100.00%** | LOAD-BEARING |
| **anchor-2** | 10,966 | **67.431 g** | 3.003e-05 | 2.50% | 0.0087 | **51.60%** | LOAD-BEARING |

> frozen mass **247.290 g** of 543.724 g printed (**45.48%**) — the brief's 247.3 g,
> reproduced independently
> **QUIET 0.000 g (0.00%) · LOAD-BEARING 247.290 g (100.00%)**

★ **This is the opposite of the outcome §2 hoped for, and it matters.** The brief
said: *if most of the prize is in quiet regions, most of the risk in this task
evaporates.* None of it is. The larger region **contains the part's peak von
Mises** and carries **45% of the printed part's entire strain energy**; the
smaller sits at half the part peak. So the accuracy problem does **not** dissolve,
the 5-cell floor is aimed exactly where it needs to be, and §3's buttressing
coupling is fully in play. The mass-neutral posture (`freed_mass_return = 1.0`)
is therefore not a variant to try — it is the one the measurement demands.

★ **And his declared face protection is not a separately addressable region.**
The frozen set is **TWO** 26-connected components, not the ~5 the brief
anticipated. Face 16's protection collar (10,554 voxels) is 26-connected to the
load-face structural pad, so `load-pad-1` is both of them as one piece of
material: 29,250 + 10,966 = 40,216, exactly the FrozenSolid count. A user who
wants to lattice "just the protected face" cannot — it is one member with the
load pad, and any density assigned to it is assigned to both.

### 0.2b ★ The law's validity, per region (bar R5) — and the median hides the tail

| region | median member | cells/member | **p10 cells** | **% of voxels clearing N\*** | verdict |
|---|---|---|---|---|---|
| load-pad-1 | 10.2317 mm | **5.12** | **1.71** | ★ **60.2%** | IN RANGE |
| anchor-2 | 27.2845 mm | 13.64 | 5.12 | 97.8% | IN RANGE |

Both clear the 5-cell floor **at the median**, so bar B4 as pre-registered passes
— and `load-pad-1` clears it by **2.4%**, with **39.8% of its voxels below the
floor** and a tenth percentile of 1.71 cells, a third of what the certificate
needs. ★ **The bound was pre-registered on the median and the median is the wrong
statistic here**; it is reported as passing because that is what was written down
before the run, and the p10 and the fraction are reported beside it because they
are what a reader needs. On the next pass the bound should key on the FRACTION
below the floor, not the median — that is a change to make deliberately and in
advance, not now.

### 0.3 ★ The assignment table — **STARTED, NOT COMPLETE.** The rows that are in the record:

`evidence/…/m2/r0.68/m2_assignment.csv`, rung 0.68, cell 2 mm, nozzle 0.45 mm.
Baseline (every region SOLID): **margin_effective 673.856173, mass 543.7239 g,
ACCEPTED.**

| region | f | mass | Δmass | margin_eff | **margin SOLID-ONLY** | **strut margin** | regime | drain | verdict |
|---|---|---|---|---|---|---|---|---|---|
| load-pad-1 | 0.20 | — | — | — | — | — | — | — | ★ **REFUSED — the strut does not print at this cell and nozzle** |
| load-pad-1 | 0.30 | 417.822 g | ★ **−125.902 g** | **134.773** | 326.740 | **134.773** | ★ **OUT** | ok | accepted (−80.0% margin) |

Three things fall out of two rows, and all three are worth more than the row count.

★ **(a) THE STRUT TERM BINDS, AND IT IS WORTH 2.4x.** `margin_effective` equals
`lattice_strut.margin_worst_case` exactly: the de-homogenised strut bound is what
the gate is testing, not the solid region's margin. Without §1(c)'s
`gate_on_strut_strength` this cell would have reported **326.740** — 2.4x higher —
and that is failure mode M5, precisely: a latticed region passing by not being
looked at. The number the gate would have used is kept on the receipt
(`margin_effective_solid_only`) so the term's cost is never invisible.

★ **(b) THE CERTIFICATE SAYS OUT OF REGIME WHERE THE REGION-LEVEL TEST SAID IN
RANGE**, and the certificate is right. `lattice_region_validity` keys on the
region's MEDIAN cells-per-member (5.12, clearing) and admitted it;
`analyze_fixed_design`'s own guard keys on the **thinnest latticed member** and
raises `lattice_strut_out_of_regime`. §0.2b already showed why — p10 = 1.71 cells,
39.8% of the region below the floor. ★ **Two instruments in this task disagree and
the conservative one is the per-voxel one.** The region-level bar as pre-registered
(B4, on the median) is the weaker test and should be replaced by the per-voxel one
on the next pass. It is left as written here because it was pre-registered.

★ **(c) THE MARGIN FALLS 80.0%, AGAINST A PRE-REGISTERED BOUND OF 5.0%** — and
the gate still ACCEPTS, because 134.773 is ninety times `margin_stop` of 1.5.
B2 is stated on the BEST assignment and the table is not complete, so it is not
yet formally missed; but the first cell is **16x outside it**, and the reason is
worth saying plainly: ★ **B2 was written as a RELATIVE bound on a part whose
absolute margin is ~450x the gate.** On such a part a relative margin bound will
refuse assignments the shipped gate accepts with vast headroom. That is a defect
in the bound, not in the mechanism — and per §5(b) it is REPORTED, not retuned.
The next pre-registration should bound the margin against `margin_stop`, not
against the baseline.

### 0.4 ★ The NET mass saving — **NOT MEASURED.**

The gross at this one cell is **−125.902 g (−23.2%)** with the freed mass BANKED
(`freed_mass_return = 0.0`, the assignment table's posture). ★ **That is not the
saving and must not be read as one.** §0.2 measured that 100% of the frozen mass
is load-bearing and that this very region holds the part's peak von Mises, so the
optimiser will put material back — which is exactly what the mass-neutral end of
the knob is for. The loop that walks between them (§4c of the brief) did not run;
no NET number appears anywhere in this handoff.

### 0.5 ★ Whether Mode 2 beat Mode 1 — **NOT MEASURED, and Mode 2's in-loop coupling is NOT BUILT.**

What IS built and is exact: the second coefficient-expanded field
t(x) = Σ β_j ψ_j(x) on its own knot lattice, the monotone clamped map t → ρ, and
the analytic Jacobian dρ_e/dβ_j (`lattice_beta_jacobian`), together with the
compliance sensitivity dc/dρ_e at a frozen latticed voxel, which
`simp_compliance` now returns and which is the other half of the chain rule.
What is NOT built is β joining the MMA design vector — §7.2.

### 0.6 ★ What stopped the campaign, measured: **a cold certification of his part is tens of minutes, and arming GenEO for it makes that worse, not better.**

This is a real finding and it is the reason the rest of §0 says NOT MEASURED.

**One certification of his rung 0.68, isolated, at 8 threads: 590.6 s.** That is
the measured unit cost of every cell of the assignment table.

`analyze_fixed_design` on his 128 × 31 × 118 grid (1,473,696 displacement DOFs)
is a **cold** solve: there is no Krylov recycle subspace to reuse and no
multigrid — his own `run_info` records `cg_multigrid: false`,
`mg_mode: "stagnated-latched"` — so it is plain CG on a system whose SIMP void
floor gives it a condition number around 1e9.

The probe was first written to certify in the PRODUCTION posture, on the argument
that the baseline rungs' margins were produced there. **That was wrong, and the
sample says why**: the run sat inside `geneo_engage_now` after **51 minutes of
CPU** without reaching its first certificate. GenEO pays its full coarse-basis
build on a one-off solve with nothing to amortise it over. That is exactly why
`ScopedLadderSolverIsolation` (run_job.cpp:2961) disarms recycling *and* GenEO
for the standalone re-analysis path — and this probe is that path, not the
ladder's.

★ **The general lesson, and it cuts the other way from the one already recorded.**
`probe-must-not-disarm-production-posture` says a probe that disarms what
`build_production_loadcase` armed measures the handicap. That is true of a
TRAJECTORY, which runs the accelerators hundreds of times. It is **false of a
single cold certification**, where arming them is the handicap. The two postures
are not "production" and "wrong"; they are "amortised" and "cold", and which one
a probe wants depends on how many solves it is about to run.

---

## 1. ★ THE ρ→STIFFNESS LAW — measured, and it is not Gibson-Ashby

`evidence/…/m0/law.txt`, reproducible with
`./build/frozen_lattice_probe … --stage law`.

### 1.1 The optimiser never sees an asymptotic law, and here is what it would cost if it did

The stiffness the optimiser steers on is `LatticeMaterialModel` — a C¹ curve
fitted to the library's **19 MEASURED resolved rows** for octet, read from
`lattice_resolved_rows` (CORE, never a transcript), origin-anchored, 4 terms.

Beside it, fitted **in this run** to the same rows' own axial Young's modulus so
the comparison is like for like:

> Gibson-Ashby **E\*/Es = 0.794431 ρ^1.6783**, over 19 measured rows.

and differenced row by row:

| ρ | measured E\*/Es | G-A E\*/Es | G-A error |
|---|---|---|---|
| 0.0505 | 7.117e-03 | 5.288e-03 | **−25.70%** |
| 0.0988 | 1.608e-02 | 1.633e-02 | +1.56% |
| 0.2041 | 4.452e-02 | 5.519e-02 | +23.99% |
| **0.2973** | 8.183e-02 | 1.037e-01 | ★ **+26.76%** |
| 0.5064 | 2.311e-01 | 2.536e-01 | +9.72% |
| 0.6987 | 4.659e-01 | 4.352e-01 | −6.57% |
| 0.8999 | 8.138e-01 | 6.655e-01 | **−18.22%** |

★ The exponent comes out at **1.678**, and the error sweeps from **−25.7% to
+26.8%** — a **52.5-point** band, worst at ρ ≈ 0.30, which is precisely the
density a lightweighting assignment wants. `lattice-phase0` M2 recorded the gap
as 23–52% with an exponent near 2.0; measured here on this library it is the same
finding to the same magnitude, and the sign REVERSES across the band, so no
single-exponent law is conservative everywhere. **The fitted curve does not
inherit any of it**, because it interpolates the rows rather than an exponent.
`knockdown_spec_for`'s width-aware composite is a *print-process strength*
knockdown and is left exactly where it is — it is not, and must not be made
into, a homogenised-stiffness law.

### 1.2 ★ The validity range, in cells per member — and it is TWO bounds that bind opposite ways

| | value | source |
|---|---|---|
| certifiable floor N\* | **5.0000** | `lattice_cells_per_member_min` |
| percolation floor | **1.0000** | `lattice_percolation_cells_per_member_min` |
| printability floor cell @ 0.45 mm | **4.931378 mm** | `lattice_cell_printability_floor_mm` |
| ★ thinnest certifiable member @ 0.45 mm | ★ **5.8659 mm** | `lattice_derive_cell_for_member` |

and at **his** 2 mm cell:

| cell | lightest printable ρ @ 0.45 mm | member needed for N\* = 5 |
|---|---|---|
| 1 mm | **none in the band** | 5 mm |
| **2 mm** | **0.2651** | **10 mm** |
| 3 mm | 0.1312 | 15 mm |
| 4.93 mm | 0.0505 (the band floor) | 24.7 mm |

★ **The two bounds cross.** A coarser cell buys printability and costs
homogenisation; a finer cell does the reverse. That is why they are reported
separately everywhere in this task and never merged into one verdict, and it is
why the app's face card shows the cell, the density AND the strut diameter rather
than one "OK".

### 1.3 What happens outside the range: a REFUSAL, per region

`lattice_region_validity` reports, per region: median / p10 member width, cells
per member at both, the fraction of the region's voxels clearing the floor, the
two floors, and one quotable refusal sentence naming the number a user acts on
(the thinnest member that *could* clear the floor at this nozzle). A region below
the floor is **refused** — `minimize_plastic` drops it from the field entirely —
not approved with a footnote. `frozen_lattice_refuse_below_floor` defaults true,
and arming a run with a lattice cell of zero (so the question cannot be asked at
all) **throws** rather than passing silently.

The middle case is named rather than collapsed: a region between the percolation
and certifiable floors is **BUILDABLE AND UNCERTIFIABLE**, which has a different
remedy from un-latticeable.

### 1.4 ★ M5, the failure mode this closes

M5 as recorded: *default `infill_percent=100` → knockdown 1.0 → the gate
certifies the SOLID envelope margin, but the lattice is 5–12× more compliant.*

Two halves, and both are closed here:

* **the compliance and the macro stress field** — the certification now solves
  the real composite object. `minimize_plastic` hands `analyze_fixed_design` a
  `LatticePosture` carrying the frozen region's mask and relative density, so the
  latticed elements carry the measured homogenised cubic tensor;
* **the latticed region's STRENGTH** — `analyze_fixed_design` gains
  `gate_on_strut_strength`. **OFF by default**, so bar L1 ("report only") stands
  for every existing caller byte-for-byte; **ON for this feature**, because a
  latticed region excluded from the solid maxima and not otherwise gated is M5
  moved one stage later. Armed, the acceptance test becomes
  `min(solid-region effective margin, lattice_strut.margin_worst_case)` — the
  measured PR 259 de-homogenisation bound — and `margin_effective_solid_only`
  keeps the number the gate would have used, so the strut term's cost is on the
  receipt and never folded invisibly into one figure. `strut_gated` says which of
  the two happened. The out-of-regime case is **not** special-cased into a pass.

---

## 2. THE MECHANISM

`core/include/topopt/lattice_density_field.hpp` is the whole of it, and its
header is the reference; this is the shape.

### 2.1 A fixed density IS a constant density field

One representation, two modes:

* **MODE 1 — DECLARED.** `t` is constant over the region: the user's `f`.
* **MODE 2 — OPTIMISED.** `t(x) = Σ β_j ψ_j(x)`, the **same basis family** φ
  already uses (`plsm_basis.hpp`, shared — not a second copy), on its **own,
  coarser knot lattice**. The rule, stated before it was measured: **4× φ's
  spacing on every axis**, per axis, with no minimum and no maximum taken over
  the axes (`gridap-alpha-rule-breaks-on-slabs` is why). Relative density is a
  monotone map of `t` through a smooth Heaviside, clamped to the region's band —
  and `β = 0` seeds the MIDDLE of the band rather than an endpoint.

The prior art is read and named: Deng & To, *Projection-based Implicit Modeling
Method (PIMM) for Functionally Graded Lattice Optimization*, arXiv 2008.07487 /
JOM 73:2012-2021 (2021), DOI 10.1007/s11837-021-04659-1 — a second global-RBF
field whose coefficients are the design variables, knots decoupled from the FE
mesh, a projection to an ersatz density, chain-rule sensitivities, MMA. Its own
version meshes the real lattice and takes no homogenisation shortcut, which is
more honest and puts the whole cost on the state solve; §0.6 is what that costs
here, so **we keep `fea_solve_cg_lattice_matfree` (PR 257) and the re-fitted law
of §1**, exactly as the brief's §3(f) directs.

### 2.2 ★ The per-voxel density contract is preserved (bar R6), and here is each consumer

A latticed frozen voxel's **design density stays 1.0**. The lattice cell fills
the voxel's envelope; the pore space is a property of the **material**, not of the
occupancy. The relative density travels in a **second** grid-indexed field —
exactly the `(mask, relative_density)` pair `LatticePosture` has carried since
lattice certification Phase 1. Nothing here lowers `printed_iso`.

| consumer | what it reads | verified |
|---|---|---|
| certification (`analyze_fixed_design`) | `density[e] > iso`, plus the posture | ✔ frozen voxel is 1.0 → printed, as before; its lattice density arrives on the posture, the contract that already existed |
| min-feature (`check_v3`) | `density` at `kIso` | ✔ unchanged — `kIso` is 0.5 on a frozen-lattice run and the frozen voxel is 1.0 |
| frozen / protect masks | `effective_design_mask` | ✔ untouched; the field is emitted **only** where that mask says FrozenSolid (`only_where`) |
| clearances | the FrozenVoid overlay | ✔ untouched; a cleared voxel is not FrozenSolid so it can never enter the field |
| octet grading law (`grade_lattice`) | a density field | ✔ unchanged — it reads the same 1.0 |
| the load-path walk | `density > iso` | ✔ unchanged, and B5 states it separately because PR 324 measured 40 leaked frozen voxels out of 40,216 breaking it |

### 2.3 The four fields of the defect, and where each is fixed

| | was | now | where |
|---|---|---|---|
| FEA stiffness | full solid | the measured homogenised tensor at ρ | `SimpParams::lattice_relative_density` → `simp_compliance` |
| mass | full solid | ρ × solid | falls out — `analyze_fixed_design` already counts a latticed voxel as its relative density |
| volume budget | **outside** it | **inside** it | `frozen_effective += ρ` (part-relative) and `SimpOptions::freed_mass_voxels / freed_mass_return` |
| sensitivity | zero | zero (Mode 1), β-only (Mode 2) | the region is never a per-voxel design variable |

`freed_mass_return ∈ [0,1]` is the one knob the frontier is walked on: **0.0**
banks the freed mass (the assignment table's posture — what latticing COSTS in
margin with nothing given back), **1.0** is mass-neutral (the posture §3's
buttressing coupling demands, since 94% of what the optimiser places lands within
5 mm of the frozen wall). **The rung's meaning is not redefined**: at f = 1
nothing is freed and every posture is the shipped one, bit-for-bit.

### 2.4 ★ R1 — C0 inertness, and why it is exact rather than tight

**A lattice at relative density 1.0 has no pore space; it IS solid.** The
resolver emits no mask bit and no ρ for it, so the run is byte-identical to one
that never declared the region. That is a definition, not a shortcut.

Measured beside it, because it is a different claim and only the first is a bar:
`LatticeMaterialModel::value(1.0)` returns the **exact** isotropic solid triplet —
C11 5185.7585, C12 2554.1796, C44 1315.7895 against c(1−ν), cν, E/2(1+ν)
computed independently, at **0.000e+00 relative on all three components**. So the
law is continuous at the join too, and the alternative (routing f = 1.0 through
the cubic element) would have been correct to PR 252's 8.5e-16 — which is
"identical to machine precision", not "byte-identical", and only the second is
the bar.

The verification is a checksum, not an argument: `--stage r1` runs the ladder
with the feature off and with it on at f = 1.0 over every region — with the
cells-per-member floor **deliberately not enforced**, so a refusal cannot make
the field empty for the wrong reason — and compares `design_fingerprint` of the
converged fields.

---

## 3. ★ DRAINABILITY — and a correction to the brief

### 3.1 The named file does not exist on `main`

The brief's §6(b) attributes a correctness bug to `plsm_topology.hpp`'s
`in_region`, "which treats the frozen set as outside the region", and cites
cavity counts of 5/0/2 against 51/21/32. **There is no `plsm_topology.hpp` in
this repository**, on `main` or on any branch reachable from it, and no
`in_region` outside a harness helper in `external_field_surface_probe.cpp` that
selects mesh vertices and has nothing to do with drainability. The cited counts
appear in no evidence directory. Whatever that is, it is not in this tree, so it
could not be fixed here and it is not being left silently.

### 3.2 What IS here already does the manufacturing definition

`lattice_void.hpp` / `lattice_void.cpp` — shipped by
`2026-08-05-lattice-void-reaches-exterior` — is the predicate, and it is exactly
§6(a):

* the escape network is **LATTICED ∪ VOID**, walked **6-connected**, and its
  header argues the (26 solid, 6 void) pairing from digital topology rather than
  asserting it;
* **printed material that is not latticed BLOCKS** — so frozen material the run
  leaves solid is a barrier, which is the bolt-boss case;
* the seeds are the grid's six boundary planes, and voxels outside the part are
  not printed, so the seed set IS the true part exterior.

★ **And this task changes what that predicate sees, which is the real coupling.**
A frozen region declared as lattice moves from the BLOCKING set into the ESCAPE
network. That is correct — a latticed boss really does let powder through — and
it means the check must be re-evaluated per assignment, which is what the
assignment table's `sealed` column does (bar B7). It is a per-assignment
measurement, and it did not run (§0.6).

---

## 4. THE APP (§7)

`main` moved under this branch: **PR 328 landed**, and the face card the brief's
§0(b) refers to is real. The branch was merged and §7 was rewritten onto it.

* **§7b** — `LatticeFaceCard` gains `latticedMassG` and `savedMassG`; the card
  row gains two chips, "as lattice" and "saved". The card already stated what the
  barrier **hands** the lattice in grams and stopped one multiplication short of
  the number the feature exists for. It is named `savedMassG` and the doc comment
  says GROSS, because `frozen_buttress_probe` measured 94% of what the optimiser
  places landing within 5 mm of that wall.
* **§7a** — a per-region **density** control, keyed like `groupRoles` on the ONE
  `SelectionModel`. **AUTO is the default and Auto is ABSENCE** — a stored
  default would make the app the author of core's number — and Auto **cannot
  refuse**: it picks inside core's certifiable band, verified by a test that
  sweeps the depth from 0.5 mm to 60 mm and asserts Auto never produces a state
  the page cannot proceed from. `Solid` is 1.0 and emits no lattice at all,
  mirroring core's `kLatticeSolidAt`.
* **§7c** — a declared density outside the validity range shows as
  **Out of regime** on the card's own verdict, and a declared density whose strut
  is thinner than one bead is **refused rather than quietly raised** — raising it
  would print a heavier lattice than the user asked for and report the lighter
  one.

`FrozenRegionAsMaterialTests` covers all three, and its last test reads
`WorkspacePlaceholder.swift` and asserts the row renders the two chips and the
control writes the settings key — because *tests on value types miss call sites*
has shipped five times here.

---

## 5. BARS

| bar | state |
|---|---|
| **R1** C0 inertness first | exact by dispatch, and asserted at the resolver in `test_lattice_density_field` (f = 1.0 emits nothing; 0.95 is still clamped into the band, so "solid" is the number and not a tolerance). The whole-run stash-rebuild checksum did NOT run — §7.1 |
| **R2** Mode 2 off until Mode 1 measured; Mode 1 off until bounds met | **held** — `frozen_lattice` defaults false, `frozen_lattice_beta` defaults empty, and no production path sets either |
| **R3** every arm at two rungs | rung 0.68 only, and incomplete — §7.1 |
| **R4** NET, and margin as a curve | no optimised arm ran, so there is no curve and no NET number; **no gross number is presented as a saving anywhere**, and the app's own wording says so |
| **R5** cells-per-member per region | **held** — §0.2b, per region, with the p10 and the fraction beside the median, and §0.3(b) reports where the region-level test and the certificate's own guard disagree |
| **R6** per-voxel density contract | **held** — §2.2, each of the six consumers checked |
| **R7** assertion census | **held** — §6 |
| **R8** root cause with file and line, no placeholders, no root scratch | held |
| **R9** separate commit for any review response | n/a — no review yet |

---

## 6. R7 — the assertion census

`evidence/…/assertion_census.sh`, run `BASE_REF=main`. Message census, not a name
grep: test assertion messages, registered ctest names, production refusal
messages, the comparison-operator histogram inside `CHECK()`, and the harness's
own refusals as one bag.

**Production refusals went UP** — this task adds refusals (an untrustworthy
topology, a mismatched region-id size, a region in Optimised mode with no β
field, a narrowing that empties the band, a `freed_mass_return` outside [0,1], a
`lattice_relative_density` with no material law, and a lattice cell of zero when
the floor is being enforced). **Nothing was removed.** The full run is in
`evidence/…/r7_assertion_census.txt`.

---

## 7. ★ WHAT WAS NOT DONE, AND WHAT IT WOULD TAKE

Stated plainly and separately, because scaling this task down is the
maintainer's call and not mine.

### 7.1 The measurement campaign (§2, §4 of the brief; bars R3, R4)

M1 (regions and their strain energy), M2 (the assignment table at two rungs) and
M3 (the loop) did not complete. The instrument is built, committed and runs;
`evidence/…/queue.sh` is the queue in pre-registered order and is what to run.

The cost, measured: one cold certification of his part is **tens of minutes** of
plain CG at 1.47M DOFs (§0.6). The brief's ~20 certified runs is therefore a
multi-hour campaign, and the brief's own §4(b) doubles it by requiring two rungs.
`queue.sh` takes `M2_REGIONS` and `M2_DENSITIES` so the cap is on the command
line and in the record rather than in a default, and the probe **prints the
regions it skipped** — a table that silently omitted them would read as though
they had been measured.

### 7.2 Mode 2's in-loop coupling (§3c)

Built and exact: the β field, the t → ρ map, `lattice_beta_jacobian` (dρ_e/dβ_j),
and dc/dρ_e at a frozen latticed voxel. Not built: **β joining the MMA design
vector**. The remaining piece is one function — `mma_update_masked` extended with
a parallel β block inside the same 1-D dual bisection, which is exact rather than
approximate because MMA's subproblem is separable and the coupling is the single
volume constraint (dV/dβ_j = Σ_e dρ_e/dβ_j, a linear functional). It was not done
because it could not have been *measured* in this session (§7.1), and shipping an
unmeasured optimiser change behind a flag that R2 keeps off buys nothing.

### 7.3 The job-schema entry point and the export hookup

`frozen_lattice` is a `MinimizePlasticOptions` field with no `job.json` key and
no `run_job` wiring. That is deliberate under R2 — nothing can arm it by accident
— but it is also the gap that must close before this ships, and the shape of the
fix matters:

★ **`run_job` must DERIVE the frozen-lattice regions from the same
`lattice.regions` include declarations the EXPORT already uses**, rather than
taking a second declaration. The export path already lattices frozen voxels that
fall inside an include region — that is what `lattice_export_frozen_latticed`
counts and what PR 328's face card is about. Two independent declarations of
"which frozen material is lattice" is precisely the loop/export disagreement this
codebase has been bitten by twice (the two-step pipeline, and the pre-multiscale
certification), and the way not to have it is not to have two.

---

## 8. In plain language

A part that gets optimised has regions the optimiser is not allowed to touch — a
bolt boss, the face you told it to protect, the skin behind an anchor. Today the
optimiser treats every one of those as **solid plastic**: it is stiff, it is
heavy, it does not count against the weight budget, and the optimiser cannot
change it. On the maintainer's own part those regions are **45% of the printed
weight** — 247 grams of 544.

But they do not have to be solid. They can be a **lattice** — a scaffold of thin
struts with air in between — which is much lighter and, for a region that is not
carrying much load, plenty strong. This task built the machinery that lets the
optimiser know that: the frozen region now has a *density*, its stiffness is the
real measured stiffness of that lattice rather than of solid plastic, its weight
is its density times solid, and — this is the part that matters — the weight it
gives up goes back into the budget, so the optimiser can spend it somewhere
useful.

Two things came out of it that are worth knowing even though the big measurement
did not finish.

**One: the printer's nozzle, not the software, is what limits this.** For the
lattice's stiffness to be *predictable* you need at least five lattice cells
across the thing you are latticing, and for the struts to actually come out of
the nozzle the cells cannot be too small. Those two demands pull in opposite
directions, and on this printer they leave you needing a wall at least **5.9 mm
thick** before a lattice there can be certified at all. His protected collar is
declared at 5 mm. So the honest answer for his part may well be "not there, not
at this cell" — and the software now says so per region, with the number he'd
have to change, instead of quietly latticing it and certifying a stiffness the
part does not have.

**Two: the old rule of thumb for lattice stiffness is wrong by up to a quarter,
in both directions.** The textbook formula over-predicts stiffness by 27% at the
densities you would actually pick and under-predicts by 26% at the light end. The
optimiser never sees that formula here — it uses the 19 real measurements — but
it is worth writing down, because that formula is what most tools use.

What is *not* answered: how much weight this actually saves. The reason is
honest and slightly boring — checking one candidate takes tens of minutes of
computation on this part, the plan called for about forty of them, and that did
not fit. The machinery, the safety checks and the on-screen numbers are all in;
the arithmetic that says "this saves N grams and costs M% of margin" is the next
sitting, and `queue.sh` is the button.
