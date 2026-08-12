# PROPOSAL 1 — what to ship in the parametric level set

★ **One recommendation, one line of production code, measured at the shipped
volume convention.** Everything else tried across four tasks and ~30 arms is
listed below as rejected, with the number that rejected it.

★ **A proposal, not a change.** `git diff main -- core/src core/include app/` is
empty and stays empty.

---

## 0. THE RECOMMENDATION

**Turn the perimeter penalty on at C = 1, with `eta_voxels = 1.0`.**

Measured at rung 0.7973 — the rung that puts the parametric path on SIMP's own
printed-voxel count — against SIMP in the same probe invocation:

| | SIMP | PLSM as shipped | ★ **+ perimeter C=1** |
|---|---|---|---|
| internal surface (`n_cut`) | 26,191 | 31,520 (**+20.3%**) | **28,045 (+7.1%)** |
| carved roughness | 7.5521 | 10.6486 | **8.7480** |
| CAD error mm | 0.4293 | 0.4611 | **0.4385** |
| certified margin | 3254.34 | 3252.15 | 3251.93 |
| mass | 543.7 g | 543.7 g | 543.7 g |
| sealed void | — | 16,131 mm³ | **7,974 mm³** |

★ **It closes 65% of the internal-surface gap, improves CAD accuracy, and halves
the trapped powder, at identical mass and unchanged margin.** It is one term in
the shape-derivative velocity, needs no extra solve, and has no tuning parameter
beyond C.

★ **On the margin, stated precisely rather than favourably.** 3251.93 against
SIMP's 3254.34 is **−0.07%**. That is *below* SIMP, and I am not going to call it
"parity" without the caveat: at this volume every arm measured lands within
**0.2%** of every other (3242.9 to 3279.8 across ten designs), so the margin is
not resolving differences between designs here — see §3. The honest statement is
**"the margin does not move", not "the margin improves"**.

## 1. WHY THIS AND NOT THE OTHERS — the rejection table

Every mechanism built across `plsm-minimise-the-extra-surface`,
`plsm-restriction-operator`, `plsm-monotone-no-nucleation` and
`plsm-matched-volume`. ★ Rows marked **[0.68]** were measured at the OLD volume
convention and their numbers are not comparable to SIMP; rows marked **[.7973]**
are at the shipped convention.

| mechanism | verdict | the number |
|---|---|---|
| ★ **perimeter penalty C=1** | **RECOMMENDED** | [.7973] +7.1% surface, margin flat, CAD better |
| Helmholtz density filter r=1 | rejected | [0.68] −12.8% surface, less than half the penalty's, and CAD degrades |
| Helmholtz filter r=2, r=3 | rejected | [0.68] margins 2095 / 1955 against SIMP's 3254 |
| robust erode/dilate triple | rejected | [0.68] margin 3209 (fails), at 3× the compute |
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
