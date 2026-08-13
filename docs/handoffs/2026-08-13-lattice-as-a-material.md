# lattice-as-a-material — a frozen region as a MATERIAL, not as solid

Evidence: `evidence/2026-08-13-lattice-as-a-material/`. The pre-registration
(`r0_preregistration.md`) was **committed before the first arm ran** — commit
`00eff24`, whose tree contains that file and nothing else under that directory.

★ **THE ASSIGNMENT TABLES ARE COMPLETE AT BOTH RUNGS; THE LOOP IS NOT RUN.**
The mechanism is built and receipted, the law's validity range is measured, his
frozen set is decomposed and priced, and **the assignment table is COMPLETE at
BOTH rungs** — 8 cells at 0.68 and 6 at 0.26, failures included. ★ The light rung
**refuses the region holding 73% of the prize** while the shipped rung admits it
(§0.3b) — the finding the two-rung bar exists to produce — and between them they
settle the pre-registered mass bound **against** the feature for this part at this
cell (§0.4), without the loop needing to run. ★ **Under the certificate's own per-voxel regime guard,
NONE of the assignments measured is certifiable** (§0.3b), and the pre-registered
margin bound is missed at every cell for a reason that is a defect in the bound
(§0.3e). What did not run — the loop (bar R4) and Mode 2's in-loop
coupling — and the measured cost behind that, are in §0.6 and §7. **Nothing below is estimated, and no gross saving is presented
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

### 0.1b ★★ TWO OF §0'S OWN FINDINGS ARE RETRACTED. Read this before the tables.

Both came from decisions I made in the instrument, not from the part, and both
made the feature look worse than it is.

★ **RETRACTED 1 — "the frozen region carries the part's peak stress" (§0.2).**
I built regions by flood-filling the frozen set, and face 16's protection collar
turns out to be 26-CONNECTED to the structural pads under the 22 load faces. So
`load-pad-1` is *the declared wall fused with the load pads*, and the load pads
sit directly under the applied force. **The 100%-of-part-peak figure is the load
pads' stress attributed to a blob that also contains the wall.** It says nothing
about the wall. `mask_step_face` (step.hpp) gives per-face provenance and would
have separated them; I did not use it. §0.2's QUIET/LOAD-BEARING split is
therefore **not a measurement of his declared regions** and should not be quoted
as one.

★ **RETRACTED 2 — "the light rung refuses the region holding 73% of the prize"
(§0.3b).** That refusal was MY CODE, on a rule that should not have applied. The
cells-per-member floor is a property of the region **and the cell**, not of the
region alone: the same 6.8 mm member misses 5 cells at a 2 mm cell and clears
them at a 1.3 mm one. My first cut took ONE cell for the whole run and refused
everything that could not hold it. `lattice_derive_cell_for_member` has answered
this since PR 302 and I did not call it. **With the cell fitted to each region's
own thickness the floor is cleared by construction and the refusal disappears** —
see §2.5. The rung-dependence measurement in §0.3b is real and still stands; what
it does NOT show is that the region is un-latticeable.

★ **What survives both retractions**, because it is arithmetic on the user's own
print profile rather than on my region definition: §0.1's window, §1's law and
its Gibson-Ashby gap, the drainability result, and — from the tables — that the
STRUT bound binds in every certified cell and that latticing the anchor moves the
solid region's margin by −0.003%.

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

### 0.3 ★ The assignment table at the shipped rung — COMPLETE, all 8 cells

`evidence/…/m2/r0.68/m2_assignment.csv`, rung 0.68, cell 2 mm, nozzle 0.45 mm,
one certified analysis per cell through the shipped gate, **every cell reported
including the failures**. Baseline (every region SOLID): **margin_effective
673.856, mass 543.724 g, ACCEPTED**, 592.8 s.

| region | f | mass | Δmass | **margin_eff** | Δ% | **solid-only** | Δ% | **strut** | regime | drain | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| load-pad-1 | 0.20 | — | — | — | — | — | — | — | — | — | ★ **REFUSED — the strut does not print at this cell and nozzle** |
| load-pad-1 | 0.30 | 417.822 | ★ **−125.902** | 134.773 | −80.00% | 326.740 | −51.5% | 134.773 | ★ OUT | ok | accepted |
| load-pad-1 | 0.45 | 444.801 | −98.923 | 150.978 | −77.59% | 383.930 | −43.0% | 150.978 | ★ OUT | ok | accepted |
| load-pad-1 | 0.60 | 471.780 | −71.944 | 213.935 | −68.25% | 453.097 | −32.8% | 213.935 | ★ OUT | ok | accepted |
| anchor-2 | 0.20 | — | — | — | — | — | — | — | — | — | ★ **REFUSED — printability** |
| anchor-2 | 0.30 | 496.523 | −47.201 | 173.117 | −74.31% | 665.609 | ★ −1.2% | 173.117 | ★ OUT | ok | accepted |
| anchor-2 | 0.45 | 506.637 | −37.087 | 232.855 | −65.44% | 670.349 | ★ −0.5% | 232.855 | ★ OUT | ok | accepted |
| anchor-2 | 0.60 | 516.752 | −26.972 | ★ **361.292** | −46.38% | 672.327 | ★ −0.2% | 361.292 | ★ OUT | ok | accepted |

Every certified cell is ACCEPTED by the shipped gate (`margin_stop` = 1.5) and
every one is DRAINABLE. Per-cell certification: 491–756 s, mean ≈ 610 s.

★ **(a) THE STRUT TERM BINDS IN EVERY ROW, AND IT IS WORTH UP TO 3.8x.**
`margin_effective` equals `lattice_strut.margin_worst_case` **exactly, in all
six**. Without §1(c)'s `gate_on_strut_strength` these cells would report the
solid-only column — 2.4x, 2.5x, 2.1x, 3.8x, 2.9x and 1.9x higher. That is failure
mode M5 precisely: a latticed region passing by not being looked at.
`margin_effective_solid_only` keeps the number the gate would have used, so the
term's cost is never invisible.

★ **(b) THE CERTIFICATE SAYS OUT OF REGIME ON EVERY CELL**, including all three
`anchor-2` cells — a region whose median is **13.64** cells per member with
**97.8%** of its voxels clearing the 5-cell floor. `lattice_region_validity` keys
on the region's MEDIAN and admits both regions; `analyze_fixed_design` keys on
the **thinnest latticed member** and flags every assignment. ★ **Two instruments
in this task disagree on every cell measured, and the per-voxel one is the
conservative one.** Bar B4 as pre-registered (on the median) is the weaker test;
it is left as written because it was pre-registered, and the next pre-registration
must key on the thinnest member. ★ **Under the certificate's own guard, NO
assignment in this table is certifiable** — that is the honest reading, and it is
the finding that should govern what happens next.

★ **(c) LATTICING THE ANCHOR IS STRUCTURALLY ALMOST FREE.** Its solid-only margin
moves **−1.2% / −0.5% / −0.2%** across the three densities — i.e. essentially not
at all. The whole of its −74%/−65%/−46% is **the newly-latticed material's own
strut strength becoming the binding term**, not the structure weakening. The two
receipt columns separate exactly those two questions, which is why both exist.

★ **(d) A LIGHT LATTICE IN THE QUIET REGION IS DOMINATED BY A DENSE ONE IN THE
LOUD REGION.** `load-pad-1` at 0.60 saves **71.9 g** at margin **213.9**;
`anchor-2` at 0.30 saves **47.2 g** at margin **173.1** — strictly worse on
*both* axes, from the region carrying half the peak stress rather than all of it.
The Pareto set over the six certified cells is `load-pad-1` at 0.30/0.45/0.60 and
`anchor-2` at 0.45/0.60; `anchor-2` at 0.30 is the only dominated cell. ★ The
governing quantity is the STRUT bound over the lattice itself, not how much the
surrounding structure is disturbed — so **assign density by the strut bound, not
by how quiet the region looks.**

★ **(e) B2 IS MISSED AT EVERY CELL INCLUDING THE BEST, AND THE BOUND IS WHAT IS
WRONG.** The best cell in the table is `anchor-2` at 0.60: **−46.38%** against a
pre-registered **−5.0%**. Per §5(b) this is REPORTED and NOT retuned. The reason
matters: ★ **B2 was written as a RELATIVE bound on a part whose absolute margin is
~450x the gate it must clear.** Every certified cell above passes the shipped
gate with 90–240x headroom. A relative margin bound on such a part refuses
assignments the shipped gate accepts comfortably. The next pre-registration
should bound the margin against `margin_stop`, not against the baseline.

### 0.3b ★★ THE LIGHT RUNG — COMPLETE, and it is why §4(b) exists

`evidence/…/m2/r0.26/m2_assignment.csv`, rung **0.26**, everything else identical.
Baseline: **margin_effective 624.112, mass 360.304 g, ACCEPTED**, 688.0 s.

| region | f | mass | Δmass | margin_eff | Δ% | **solid-only** | Δ% | regime | verdict |
|---|---|---|---|---|---|---|---|---|---|
| **load-pad-1** | 0.30 | — | — | — | — | — | — | — | ★ **REFUSED — below the cells-per-member floor** |
| **load-pad-1** | 0.45 | — | — | — | — | — | — | — | ★ **REFUSED — below the floor** |
| **load-pad-1** | 0.60 | — | — | — | — | — | — | — | ★ **REFUSED — below the floor** |
| anchor-2 | 0.30 | 313.102 | −47.201 | 128.856 | −79.35% | 624.094 | ★ **−0.003%** | OUT | accepted |
| anchor-2 | 0.45 | 323.217 | −37.087 | 184.502 | −70.44% | 624.108 | ★ −0.0006% | OUT | accepted |
| anchor-2 | 0.60 | 333.332 | −26.972 | **299.039** | −52.09% | 624.112 | ★ −0.0003% | OUT | accepted |

★ **THE REGION HOLDING 73% OF THE PRIZE IS REFUSED AT THE LIGHT RUNG, AT EVERY
DENSITY**, and the reason is geometric, not statistical:

| region | cells/member @ 0.68 | **@ 0.26** |
|---|---|---|
| load-pad-1 (179.9 g) | 5.12 | ★ **3.41** |
| anchor-2 (67.4 g) | 13.64 | ★ **5.12** |

A lighter rung carves material from around the frozen collar, its members thin,
and `load-pad-1` falls through the 5-cell homogenisation floor. `anchor-2` falls
13.64 to 5.12 and survives by 2.4%. ★ **Region validity is RUNG-DEPENDENT and
moves by ~2.7x across this ladder. A single-rung assignment table is not a
conservative approximation of a two-rung one — it is a different answer**, and at
the shipped rung BOTH regions looked in range. This is exactly what bar R3 and
§4(b) exist to produce.

★ **AND IT SHARPENS §0.3(c) TO THE POINT OF PROOF.** At the light rung the
anchor's SOLID-only margin is **624.094 / 624.108 / 624.112** against a baseline
of **624.112114** — unchanged to four decimal places. Latticing the anchor pad
has *no measurable effect on the rest of the part*; 100% of the margin movement
is the new lattice's own strut bound. The two receipt columns are not a nicety;
they are the difference between "this weakened the structure" and "this
introduced material whose own strength now governs".

★ **THE GROSS SAVING IN GRAMS IS IDENTICAL AT BOTH RUNGS** (−26.972 / −37.087 /
−47.201) because the frozen region is the same voxels at the same densities —
only the denominator moves (4.96% / 6.82% / 8.68% of the shipped rung,
7.48% / 10.29% / 13.10% of the light one). That is the mechanism doing exactly
what it says it does.

★ **THE COMBINED READING OVER BOTH RUNGS: THE ONLY REGION THAT SURVIVES THE
LADDER IS THE ANCHOR PAD**, worth **67.4 g** solid, and even it clears the
homogenisation floor by 2.4% at the bottom rung while the certificate flags every
one of its cells out of regime.

### 0.4 ★★ The NET mass saving — not measured, but **B3 is decided against without it**

No optimised arm ran, so there is no NET number and none is estimated. But the
two completed tables settle **B3 (>= 8.0% NET at the shipped rung)** anyway:

* the only region surviving BOTH rungs is `anchor-2` (§0.3b);
* its GROSS saving at the shipped rung is **4.96% / 6.82% / 8.68%** of 543.724 g
  at densities 0.60 / 0.45 / 0.30 — all with the freed mass BANKED
  (`freed_mass_return = 0.0`, the assignment table's posture);
* so only its **0.30** cell clears 8.0% *on gross alone*, and that is the cell
  with the worst margin of the three (−79.35%);
* NET is strictly smaller than gross, because §0.2 measured **100% of the frozen
  mass load-bearing** and §3's coupling says the optimiser puts material back.

★ **So B3 cannot be met by any assignment that survives the ladder.** It is not
"unmeasured" — it is decided against, and the loop would only quantify by how
much. ★ That is a verdict on **this part at this cell**, not on the mechanism:
§0.1's arithmetic says a finer cell or a thicker collar moves it, and §0.3b says
the ladder rung alone moves region validity by 2.7x.

★ **AND NO GROSS NUMBER IS PRESENTED AS A SAVING ANYWHERE** — not here, not in the
tables, and not on the app's face card, whose own label says the difference is
"before the optimiser re-places material".

### 0.5 ★ Whether Mode 2 beat Mode 1 — **NOT MEASURED, and Mode 2's in-loop coupling is NOT BUILT.**

What IS built and is exact: the second coefficient-expanded field
t(x) = Σ β_j ψ_j(x) on its own knot lattice, the monotone clamped map t → ρ, and
the analytic Jacobian dρ_e/dβ_j (`lattice_beta_jacobian`), together with the
compliance sensitivity dc/dρ_e at a frozen latticed voxel, which
`simp_compliance` now returns and which is the other half of the chain rule.
What is NOT built is β joining the MMA design vector — §7.2.

### 0.6 ★ What the campaign cost, measured: **a cold certification of his part is tens of minutes, and arming GenEO for it makes that worse, not better.**

This is a real finding, it is why the tables above are 14 cells rather than 40,
and it is why the loop (§7.1) is the piece that did not fit.

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

### 1.2b ★★ PRINTABILITY IS ENTIRELY USER INPUT — and this task got it wrong first

Every project carries a print profile the user chose and the software may not
change. The minimum extrudable strut width comes from **there** — `job.hpp`'s
`min_extrudable_width_mm` ("stated minimum strut width (mm), finite > 0"), which
the app fills from `PrintParams.strutLineWidthMM`. Core's own convention is that
**0 means UNSET**, not "use a sensible number".

★ **An earlier cut of this task defaulted `frozen_lattice_min_extrudable_width_mm`
to 0.45.** That is HIS nozzle, from HIS profile, baked into a production options
struct where every other project would have inherited it silently. The app side
was worse: `LatticeFaceCardDerivation.card` treated a width of 0 as "skip the
printability test", so a project whose profile had not reached the call
**certified every density as printable**.

Both are fixed, and the rule is now pinned by tests rather than by comment:

* core defaults the field to **0.0** and `minimize_plastic` **REFUSES** a
  frozen-lattice run that does not state it — printability cannot be assumed and
  cannot be skipped;
* the app's card takes the width with **no default**, and an unknown width reads
  as `outOfRegime` — "I cannot tell", never a silent pass. Making it required
  immediately found a pre-existing caller that was not supplying it.

★ **AND THE NUMBER MATTERS BY MORE THAN 3x, MEASURED.** Across the common nozzle
range the printability floor moves 2.74 mm → 4.93 mm → 8.77 mm at 0.25 / 0.45 /
0.80 mm. The same 30 mm slab at the same declared density is **certified** under
a 0.25 mm profile and **out of regime** under a 0.80 mm one — same geometry, same
lattice, opposite verdict, because the coarse profile pushes the printability
floor above what the slab can homogenize. A hardcoded width would have refused
lattices that print perfectly well and approved ones that come out as gaps.

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

### 2.5 ★★ THE CELL IS FITTED TO THE REGION — the difference between refusing and working

The cells-per-member floor is a property of the region **and the cell**. Taking
one cell for a whole run and refusing every region that cannot hold it throws
away regions that are perfectly latticeable at a cell derived from their own
thickness. That is what my first cut did, and on his part it refused the region
holding 73% of the mass.

`lattice_derive_cell_for_member` (lattice.hpp, PR 302) returns the admissible
(cell, density) window from a member's own width and **the user's own stated
strut width**. Its coarsest end — exactly N\* cells across, at the lightest
density that still prints there — is the **minimum-mass certified lattice** for
that member.

| | |
|---|---|
| `LatticeRegionCellMode::Fit` | derive this region's cell from its own thickness |
| `ResolvedLatticeDensityField::cell_mm` | the per-voxel cell it produces — which IS `LatticePosture::cell_size_field`, the SWEPT posture from `2026-08-01-lattice-cell-size-sweep`, so the certificate's regime guard asks each voxel about **its own** cell rather than one number for the part |
| a Declared density below the fitted cell's printable floor | **RAISED** to it, and the raise is **REPORTED** — the user asked for one mass and got another, and that must never be silent |
| refusal | only when **no** (cell, density) pair fits the member at the user's width — the one case a finer cell cannot rescue, whose remedy is a thicker member or a finer nozzle |

★ **And every refusal now carries the number that fixes it.** "IT FITS AT ITS OWN
CELL: at 1.6 mm this member holds exactly 5 cells, and the lightest density that
prints there is 0.22" versus "NO FINER CELL RESCUES IT: it must be at least
5.8659 mm across". *Too thin for a 2 mm cell* and *cannot be latticed* are very
different statements and only one of them is usually true.

Measured end to end (`test_frozen_lattice_c0`), same region, same declared
density, floor enforced in both arms:

```
FIXED  member 24.000 mm = 4.00 cells at 6.00 mm  refused ->    0 latticed
FIT    member 24.000 mm = 4.00 cells at 4.80 mm          -> 2304 latticed
```

★ **In the app this is what AUTO already meant.** PR 328's face card derives the
cell as `depth / N*` and floors it at core's printability floor — the same
derivation. So the card and the run now agree about which cell a region gets,
instead of the card previewing one and the run refusing at another.

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
assignment table's `sealed` column does (bar B7). ★ **Measured on every certified
cell at both rungs: `sealed = 0` throughout.** Latticing either of his frozen
regions at any admissible density leaves the pore space connected to the exterior,
so B7 is HELD on all nine certified assignments.

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
| **R3** every arm at two rungs | ★ **HELD, and it paid for itself** — both tables complete (8/8 and 6/6), and the light rung REFUSED the region holding 73% of the prize while the shipped rung admitted it (§0.3b) |
| **R4** NET, and margin as a curve | **MISSED** — no optimised arm ran, so there is no curve and no NET number. **No gross number is presented as a saving anywhere**, the app's own wording says so, and §0.4 settles the mass bound from the certified tables instead |
| **R5** cells-per-member per region | **held** — §0.2b, per region, with the p10 and the fraction beside the median, and §0.3(b) reports where the region-level test and the certificate's own guard disagree. ★ Read with §0.1b: the REGIONS those numbers are attributed to were built by connectivity, so a declared face's numbers are fused with its neighbour's |
| **R6** per-voxel density contract | **held** — §2.2, each of the six consumers checked |
| **R7** assertion census | **held** — §6 |
| **R8** root cause with file and line, no placeholders, no root scratch | held |
| **R9** separate commit for any review response | n/a — no review yet |

---

## 5b. The test suites

**New, and green:**

* `core` — `test_lattice_density_field` (registered as ctest `lattice_density_field`):
  the C0 dispatch, the two floors, every refusal, and **the β field's analytic
  Jacobian against a central difference — worst relative error 6.013e-10**.
* `app` — `FrozenRegionAsMaterialTests`, **11 tests, 0 failures**, including the
  Auto-never-refuses sweep across 0.5–60 mm of depth and the call-site test that
  reads `WorkspacePlaceholder.swift`.

**A TARGETED `ctest` OVER THE CHANGED PATHS: 13 of 13.**
`minimize_plastic`, `mbb`, `beam`, `v4`, `v5`, `stress`, `production_parity`,
`lattice_certification`, `multiscale_material`, `protect_freeze_vs_solidity`,
`designbox_lattice_recert`, `loadcase_analyze`, `nonconvergence_rejection`,
`rung_infeasible`, `conditional_projection`, `mma_projection` — every test whose
subject this diff touches. Total 5637 s.

★ **AND THE ONE THAT FIRST CAME BACK RED WAS MY HARNESS, NOT THE CODE**, which is
worth writing down because the red was convincing. `protect_freeze_vs_solidity`
— the test closest to this change — reported `***Timeout` at **1200.03 s**. Two
things were wrong with the run, both mine: I passed `--timeout 1200`, which is
**tighter than the CI default that test actually runs under** (it declares none),
and the machine was saturated by the assignment campaign throughout —
`conditional_projection` took 960 s and `rung_infeasible` 932 s under the same
contention. Re-run directly: **`protect_freeze_vs_solidity: all 26 checks
passed`, exit 0.** A timeout is not a failure, and a self-imposed cap below CI's
is a way to manufacture one.

★ **THE FULL LOCAL `ctest` STILL DID NOT RUN.** The subset above is chosen by
what this diff touches, not by what is cheap, but it is a subset: **CI is what
must confirm the rest.** And this worktree's `ctest` denominator is not CI's in
any case — without `lib3mf` the `export_3mf` and `threemf_import` tests do not
register (the configure step says so), so report N over CI's total, never N/N.

The byte-identity argument for every existing path is not a test result, it is a
construction, and it is stated so it can be checked by reading: every new option
defaults to the value that takes no new branch, `vf_target` reduces to
`options.volume_fraction` by adding exactly 0.0, `SimpParams::lattice_relative_density`
is null on every existing caller, and `gate_on_strut_strength` is false unless a
run actually latticed something.

## 6. R7 — the assertion census

`evidence/…/assertion_census.sh`, run `BASE_REF=main`. Message census, not a name
grep: test assertion messages, registered ctest names, production refusal
messages, the comparison-operator histogram inside `CHECK()`, and the harness's
own refusals as one bag.

Run against `main` **after merging it twice** — it moved under this task both
times (PR 328's lattice-page redesign, then PR 329's solver-speed work), which is
the trap `main-moves-under-long-tasks` records. A census against a stale base
reports the OTHER branch's additions as this one's removals; the first run here
did exactly that, flagging eight latch-re-arm assertions that were simply not in
this tree yet.

Against the merged tree: **nothing removed in any of the five sections.**
Registered ctests **121 → 123** (`frozen_lattice_c0`, `lattice_density_field`),
production refusals **418 → 445**, and no comparison operator inside `CHECK()`
weakened.

Production refusals went UP because this task adds them: an untrustworthy
topology, a mismatched region-id size, a region in Optimised mode with no β
field, a fitted region with no validity to fit against, a narrowing that empties
the band, a `freed_mass_return` outside [0,1], a `lattice_relative_density` with
no material law, a lattice cell of zero when the floor is enforced, and — the one
this task learned late — **an unset minimum extrudable strut width** (§1.2b).
The full run is in `evidence/…/r7_assertion_census.txt`.

---

## 7. ★ WHAT WAS NOT DONE, AND WHAT IT WOULD TAKE

Stated plainly and separately, because scaling this task down is the
maintainer's call and not mine.

### 7.1 ★ THE LOOP (§4c of the brief; bar R4) — the one measurement still owed

**M0, M1 and M2 all completed**, both rungs, every cell including the failures
(§0.1–§0.3b). What did NOT run is **M3, the loop**: assign → re-optimise the
remainder at the rung the freed mass allows → certify → step the densest region
up one level → repeat.

So there is no NET number and no margin CURVE with a settling iteration, which is
what bar R4 asks for. ★ **It is not, however, the thing standing between this and
a decision**: §0.4 settles B3 against the feature from the two completed tables
alone, because the only region surviving the ladder saves at most 8.68% GROSS at
its worst-margin density and NET is strictly smaller. The loop would quantify how
much smaller. Run it with `freed_mass_return` swept from 0.0 to 1.0 —
`evidence/…/queue.sh` is the queue, in the pre-registered order.

The cost, measured rather than assumed: **491–882 s per certified cell**, mean
~610 s at the shipped rung and ~820 s at the light one, on 1.47M DOFs of plain CG
(§0.6). The 14 cells reported here were ~4 hours of solve. A loop pass adds a
full re-optimisation (60+ iterations) on top of a certification, per point.

`queue.sh` takes `M2_REGIONS` and `M2_DENSITIES` from the environment so any cap
is on the command line and in the record rather than hidden in a default, and the
probe **prints the regions it skipped** — a table that silently omitted them would
read as though they had been measured.

### 7.1b ★ REGIONS BY PROVENANCE (the retraction in §0.1b)

The probe builds regions by 26-connected components of the frozen set. That fuses
a declared face protection with the structural pads it happens to touch, and then
attributes the pads' stress to the wall. **The fix is to key regions on
PROVENANCE — which declared thing froze each voxel — via `mask_step_face`**, which
is public and is the same primitive `build_production_loadcase` uses to create
those voxels in the first place.

★ **Core needs no change for this**: `frozen_lattice_region_id` is already a
per-voxel id supplied by the caller, and the APP is already right — it keys
regions on `SelectionGroup.id`, which is provenance by construction. It is the
probe (and, when it is wired, `run_job`) that must build the ids from the
declaration rather than from connectivity.

Until that is done, no per-region stress number measured on his part should be
quoted for a declared face.

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

**Three: I measured this part and got two things wrong, and both were my
software rather than the part.**

The first was how I grouped the regions. I found them by "what's touching what",
and it turns out the protected wall is touching the pads that sit directly under
where the load is applied. So my measurement fused them into one blob and then
reported the pads' stress as if it were the wall's. That number should not be
used.

The second was worse. I had the software pick **one lattice cell size for the
whole part** and refuse any region that was too thin to hold five of them. That
is the wrong question: a wall that can't hold five 2 mm cells holds five 1.3 mm
cells perfectly well. The software already had a function that works this out per
region — it has since a task months ago — and I didn't call it. So when the
optimiser stripped material and the wall got thinner, my code refused it, and I
wrote that up as "the part can't be latticed". It can. That's now fixed: each
region gets a cell derived from its own thickness, so the accuracy requirement is
met by construction instead of by luck, and the only genuine refusal left is a
member so thin that *no* cell works — where the software now tells you the
thickness you'd need.

**What still stands** is the arithmetic that doesn't depend on how I grouped
things: what a lattice can and can't do at a given nozzle, the fact that the
struts' own strength is what limits these designs rather than damage to the
surrounding part, and that latticing the anchor pad barely disturbs the rest of
the structure at all.

**What's still open** is the last loop — give the freed weight back to the
optimiser and see how much comes back as material — and re-measuring the part now
that the two bugs above are fixed. `queue.sh` is the button for both.
