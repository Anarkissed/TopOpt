# PROPOSAL 1 — what to ship in the parametric level set

★ **One recommendation, one line of production code, measured at the shipped
volume convention.** Everything else tried across four tasks and ~30 arms is
listed below as rejected, with the number that rejected it.

★ **A proposal, not a change.** `git diff main -- core/src core/include app/` is
empty and stays empty.

---

## 0. THE RECOMMENDATION — REWRITTEN 2026-08-13

★★ **THE PERIMETER PENALTY IS SUPERSEDED. THE RECOMMENDATION IS THE ROBUST
ERODE/DILATE TRIPLE, GATED ON DRAINABILITY.** The original §0 recommended C=1 on
the strength of ten arms at one rung; Stage B ran twelve arms at two rungs and
the ordering changed. This section is rewritten rather than patched.

### the shipped rung, 0.7973 (SIMP: n_cut 26,191, carved 7.5521, margin 3254.34)

| | n_cut | vs SIMP | carved | margin | vs SIMP | sealed void | wall |
|---|---|---|---|---|---|---|---|
| perimeter C=1 (superseded) | 27,887 | +6.5% | 9.1155 | 3251 | −0.1% | 5,946 mm³ | 61 min |
| ★ **robust triple** | **27,511** | **+5.0%** | **7.5190** | 3250 | −0.1% | **11,158 mm³** | 88 min |

★ **Its carved roughness beats SIMP outright — 7.5190 against 7.5521 — the first
arm in five tasks to do so at the shipped volume**, and it beats the penalty on
internal surface at identical margin.

### the light rung, 0.5283 (SIMP margin 3014.12)

| | margin | vs SIMP | vs control | n_cut | vs control |
|---|---|---|---|---|---|
| control | 2183 | −27.6% | — | 88,066 | — |
| ★ **robust triple** | **2605** | **−13.6%** | **+19.3%** | **77,723** | **−11.7%** |
| perimeter C=1 | 1931 | −35.9% | −11.6% | 69,115 | −21.5% |
| filter r=2 | 510 | −83.1% | — | — | — |
| filter r=3 | 308 | −89.8% | — | — | — |

★★ **The robust triple is the only mechanism that GAINS margin AND REMOVES
SURFACE.** Every other arm trades one for the other, and the filters collapse.

### ★ the wall-clock correction

**1.4× the penalty at the shipped rung (88 min against 61) and 2.0× at the light
rung (137 against 70).** ★ **NOT the 3× the original rejection table asserted** —
that figure came from counting the robust formulation's three state solves, and
it was an assumption, never a measurement. Recorded here so nobody re-inherits it.

### ★★ what blocks it — AND IT BLOCKS LATTICING, NOT PRINTING

**Sealed void 11,158 mm³ against the penalty's 5,946 — the worst arm on
drainability.** But the refusal path is narrower than "blocked" implies, read at
file and line:

| | |
|---|---|
| `run_job.cpp:3466` | the whole check is behind `if (job.lattice.require_lattice_void_reaches_exterior)` |
| `lattice_void.cpp:119-122` | **VACUOUS guard** — `latticed_voxels == 0` returns `decidable = false` before any walk |
| `lattice_void.hpp:177` | **the verdict is `latticed_sealed > 0`** |
| `lattice_void.cpp:231-239` | and `latticed_sealed` only counts pockets **containing latticed voxels**; a sealed pocket in plain solid goes to `sealed_pockets_without_lattice` and **does not refuse** |

★★ **SO THE ROBUST TRIPLE IS SHIPPABLE NOW FOR TO-ONLY JOBS.** With no lattice
there are no latticed voxels, `sealed()` is false, and nothing refuses. An
enclosed void inside a solid part is just a void.

★ **And even on a latticed job the blocker is smaller than 11,158 mm³.** That
figure is ALL sealed void in the part; only the subset overlapping the lattice
mask can refuse. **11,158 mm³ is an upper bound, not the refusal quantity.**
Production's 337 mm³ refusal was a pocket *with* lattice (7 of 215 cells), so the
33× ratio compares an upper bound against a realised value and overstates the gap.

★ **A documentation defect found on the way, worth its own fix:**
`run_job.cpp:3463` says *"Off by default: `require_lattice_void_reaches_exterior`
is false unless the job asks"* — but `job.hpp:289` declares it **`= true`**. The
comment is wrong; the check is armed by default.

### ★★ AND FOR LATTICED PARTS THE PERIMETER PENALTY IS THE ONLY ONE THAT SHIPS

★ **MEASURED 2026-08-13, one `lattice-variant` run per arm on his recipe.** The
11,158 / 5,946 figures above are ALL sealed void in the part — an upper bound.
The quantity that actually refuses is the subset inside the lattice:

| | carved | all sealed void | ★ **latticed** sealed void | lattice verdict |
|---|---|---|---|---|
| robust triple | **7.5190** (beats SIMP) | 11,158 mm³ | **1,021.5 mm³** | ★ **REFUSED** |
| perimeter C=1 | 9.1155 | 5,946 mm³ | ★ **0 mm³** | ★ **ACCEPTED, exported** |

★ **The bound overstated the robust blocker by 11×** — 3.0× the 337 mm³ refusal,
not 33×. ★★ **But the ordering did not merely persist, it became CATEGORICAL: one
refuses and one ships.**

**So the recommendation splits on the job type, and both halves are measured:**

- ★ **TO-only → the ROBUST TRIPLE.** Nothing reads sealed void when there is no
  lattice, so it ships today with the better surface.
- ★ **TO+lattice → the PERIMETER PENALTY.** Not a consolation: on this recipe it
  is **the only mechanism of the two that produces a part at all.**

### ★★ AND THE FINDING WITH NO OWNER

**NOTHING CLEARS SIMP AT THE LIGHT RUNG, INCLUDING DOING NOTHING.** The
unmodified control is **−27.6%** (2183 against 3014.12). That is a property of
the parametric level set itself, not of any mechanism in this document. It is the
largest open number on this branch, **no task is assigned to it**, and it is
recorded here so it stops depending on anyone remembering.

### the secondary recommendations

1. ★ **η 2.0 → 1.0.** Now measured at the SHIPPED volume as a matched pair with
   C=1: n_cut 27,887 vs 28,934 (**−3.6%**), carved 9.1155 vs 11.6466 (−21.7%),
   CAD 0.4373 vs 0.4461, margins identical. ★ Direction confirmed; the magnitude
   is a third of the −11.7% measured at rung 0.68.
2. **`max_iterations`** — ★ **still HELD.** Margin curves turn over at both rungs:
   the light-rung control peaks 2609 at it80 and falls to 2183 by it120 (−16.3%).
   Surface wants shorter, margin wants longer, and the trade is still unpriced.
3. ~~`hole_period_voxels` 8 → 16~~ **WITHDRAWN** (+1.8% worse at the shipped volume).
4. **Drop the monotone enforcement, keep its counters.**

## 1. WHY THIS AND NOT THE OTHERS — the rejection table

Every mechanism built across `plsm-minimise-the-extra-surface`,
`plsm-restriction-operator`, `plsm-monotone-no-nucleation` and
`plsm-matched-volume`. ★ Rows marked **[0.68]** were measured at the OLD volume
convention and their numbers are not comparable to SIMP; rows marked **[.7973]**
are at the shipped convention.

| mechanism | verdict | the number |
|---|---|---|
| perimeter penalty C=1 | ★ **SUPERSEDED ON SURFACE, RETAINED FOR LATTICED PARTS** (§0) | [.7973] +7.1% surface, margin flat, CAD better |
| Helmholtz density filter r=1 | rejected | [0.68] −12.8% surface, less than half the penalty's, and CAD degrades |
| Helmholtz filter r=2, r=3 | rejected | [0.68] margins 2095 / 1955 against SIMP's 3254 |
| ★ **robust erode/dilate triple** | ★ **RECOMMENDED** — this rejection was WRONG on both counts | [0.68] margin 3209; re-tested at both shipped rungs it is the best arm, and the compute is 1.4-2×, not 3× |
| reaction-diffusion (Yamada) | rejected | [0.68] surface **+1.8% and +7.5% — it makes it worse** |
| filter + penalty together | rejected | [0.68] 56,281 vs the penalty's 53,175 — they do not compound |
| monotone no-nucleation | rejected | [0.68] −1.7% surface; the component count already falls on its own |
| gyroid TPMS seed | rejected | [.7973] +26.8% — **reverses sign** from −12.0% at 0.68 |
| stress-aligned seed | rejected | [.7973] +33.7% — also reverses, from −33.8% at 0.68 |
| coarse seed period 16 / 24 / 32 | rejected | [.7973] +22.5% / +16.5% / +25.8% — see §2 |
| hexagonal rod seed | rejected | [.7973] +36.8%, as predicted by the phase diagram |
| ★ topological-derivative renucleation | rejected | [.7973] **+99.6% — it doubles the surface** |
| perimeter **ramp** (delay the penalty) | rejected | [0.68] dominated: 21% worse carved, 10.5% more surface, 26% less margin |

**Nothing found since has come within 9 percentage points of the penalty.**

## 2. ★ THE PREDICTION I MADE AND THE MEASUREMENT THAT KILLED IT

I argued from the block-copolymer phase sequence that at 20% void the minority
phase is compact spheres, so total interfacial area goes as **N^(1/3)** in the
hole count — predicting that coarsening the seed period 8 → 16 → 24 → 32 would
cut internal surface by 20 / 37 / 50%.

| seed period | predicted | ★ measured |
|---|---|---|
| 16 | −20.6% | **+1.8%** |
| 24 | −37.0% | **−3.2%** |
| 32 | −50.0% | **+4.6%** |

★ **Non-monotone, negligible, and two of the three are worse than the default.**

**The law is not wrong — it does not apply.** It describes the *final*
configuration, and the optimiser does not keep the seed's hole count: final void
components across the sweep are 43 / 37 / 23 with no ordering by seed period. The
seed sets where the run starts, not where it lands. ★ **Three separate seed
mechanisms (gyroid, stress, period) have now each looked strong and then failed
or reversed. I would stop investing in seed design.**

## 3. ★ THE FINDING THAT MATTERS MOST AND IS NOT A RECOMMENDATION

**At the shipped volume, the certified margin stops discriminating between
designs.**

| | margin spread |
|---|---|
| rung 0.68, restriction task, 10 arms | 1837 – 3395 (85%) |
| rung 0.68, monotone task, 8 arms | 1815 – 3393 (87%) |
| ★ **rung 0.7973, 10 arms + SIMP** | ★ **3242.9 – 3279.8 (1.1%)** |

At 88,424 printed voxels the worst case is set by the loaded and frozen regions,
not by how the interior is carved.

★ **Consequence 1 — four mechanisms were rejected against a constraint that does
not bind here.** Filter r=2, filter r=3, the robust triple and the stress seed all
failed on margin at rung 0.68. The stress seed has already been shown to reverse:
−44.2% margin there, **+0.8% here**. The other three deserve one re-test each
before being written off permanently.

★ **Consequence 2 — this cuts both ways and I will not spin it.** A margin that
cannot move also cannot confirm that anything is safe. It says *this part at this
volume is not margin-limited*. A lighter rung will bring the constraint back, and
nothing here licenses relaxing the check.

## 4. THE SECONDARY RECOMMENDATIONS

1. ★ **`eta_voxels` 2.0 → 1.0.** −11.7% internal surface, −27% carved, and the
   margin settles instead of still climbing. Measured at 0.68 as a matched A/B,
   so the DIRECTION is established and the magnitude is indicative.
2. ★ **`max_iterations` 60 → 120, or better a margin-plateau stop.** Production's
   own run of record reports last-10 compliance spreads of 4.43 / 10.24 / 20.40%
   on rungs 0.52 / 0.38 / 0.26 under a 40-iteration cap and calls those rungs
   unmeasured. ★ **But note the tension I found and have not resolved:** interface
   area reaches its MINIMUM near iteration 31 and then grows 6–9% in every arm,
   while the margin is still climbing. Margin wants longer, surface wants shorter.
   **Nobody has priced that trade at the shipped volume and it should be priced
   before the cap is changed.**
3. ~~`hole_period_voxels` 8 → 16~~ ★ **WITHDRAWN by §2.** Period 16 measures
   **+1.8% worse** at the shipped volume.
4. **Drop the monotone enforcement, keep its counters.** −1.7% does not justify a
   flag; the topology counters cost milliseconds and made every other finding in
   these tasks legible.

## 5. WHAT I WOULD MEASURE NEXT, RANKED

1. **Re-test the four margin-rejected mechanisms at rung 0.7973** (§3). Four arms,
   ~2 hours, and one of them (the filter at r=2 or r=3) removed 17–24% of the
   surface before the margin killed it. **This is the highest expected value left
   in the PLSM line.**
2. **Sweep C at the shipped volume.** Only C=1 has been run at 0.7973. C=2, 4, 8
   were all measured at 0.68 and C=8 was the smoothest arm there.
3. **Price the stopping trade** (§4.2) — the surface minimum against the margin
   plateau, at 0.7973.
4. **A drainability constraint.** §6.

## 6. ★ THE PRINTABILITY RESULT NOBODY ASKED FOR

Measured with `sealed_void.py`, which uses the *manufacturing* definition — void
6-connected, escape to the true part exterior, frozen material counted as solid
because powder does not pass through a bolt boss:

| | trapped powder |
|---|---|
| no operator | 16,131 mm³ (14.5% of void) |
| ★ **perimeter C=1** | **7,974 mm³ (7.2%)** |

★ **Production's lattice step REFUSED a PLSM design over 337 mm³ in one sealed
cavity**, where SIMP's design at the same rung was accepted first time. The
no-operator arm has **48× that**. So the penalty roughly halves the exact defect
that blocks a PLSM design from being latticed — **a second, independent argument
for it that has nothing to do with roughness.**

★ **And note the probe's own cavity count disagrees** (5 / 0 / 2 against 51 / 21 /
32). It is not wrong; `plsm_topology.hpp`'s `in_region` treats the FROZEN set as
outside-the-region, so a pocket walled in by a bolt boss scores as drainable.
Right for the optimiser, wrong for the printer. **A drainability constraint should
use the manufacturing definition**, and that is a different predicate on the same
union-find already built.

## 7. IN PLAIN LANGUAGE

After four rounds of work and about thirty full runs, **one thing works**:
charging the design a flat fee for every square millimetre of interior surface it
creates. At the correct weight it removes two thirds of the excess surface, makes
the part *closer* to the CAD drawing, halves the trapped powder, and costs nothing
in weight or strength.

**Everything else lost.** Three principled restriction operators from the
literature. Four different starting patterns, two of which looked like clear wins
until we corrected the weight and then **reversed sign**. A rule forbidding new
holes. A rule forcing new holes, which doubled the surface. A schedule that
delayed the penalty, which was worse on every column.

★ **And one prediction of my own, which I argued for confidently and which the
measurement destroyed** — that using fewer, bigger starting holes would halve the
surface. It moved it by 3%, in the wrong direction twice out of three.

★ **The most useful thing learned is not the recommendation.** It is that at the
weight this part actually ships at, **the strength barely changes no matter how
the interior is carved** — every one of ten designs landed within 1.1% of the
others. Most of what was rejected over the last two weeks was rejected for costing
strength, at a lighter weight where strength was the binding limit. **At this
weight it is not.** Several of those rejections should be revisited, and that is
worth more than anything in this proposal.
