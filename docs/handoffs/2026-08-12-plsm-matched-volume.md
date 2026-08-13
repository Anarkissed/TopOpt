# plsm-matched-volume — the comparison the last four handoffs could not make

Evidence: `evidence/2026-08-12-plsm-matched-volume/`. Three arms at rung
**0.7973**, 60 iterations, six threads, one binary. `run_matched.sh` reproduces
the runs; one `external_field_surface_probe` invocation and one certification
invocation produce every number below.

---

## 0. THE ANSWERS

★★ **This is the first like-for-like row in the entire PLSM line.** Same printed
voxels (88,423–88,424 against SIMP's 88,424), same mass to 0.1 g (543.7), same
certified margin to 0.2%. Nothing needs normalising and nothing is being
compared across conventions.

| at 88,424 printed voxels | ★ n_cut | vs SIMP | carved | CAD err | margin | vs SIMP | mass |
|---|---|---|---|---|---|---|---|
| **SIMP** | **26,191** | — | **7.5521** | **0.4293** | **3254.34** | — | 543.7 g |
| V0_none — no operator | 31,520 | **+20.3%** | 10.6486 | 0.4611 | 3252.15 | −0.1% | 543.7 g |
| ★ **V1_perim1 — perimeter C=1** | **28,045** | ★ **+7.1%** | **8.7480** | **0.4385** | 3251.93 | −0.1% | 543.7 g |
| V2_gyr20 — gyroid seed | 33,200 | +26.8% | 9.6364 | 0.4597 | 3259.01 | +0.1% | 543.7 g |

**1. Is the "3× the internal surface" premise real? — NO, AND NOW IT IS REFUTED
TWICE.** I predicted +20.4% from production's numbers
(`2026-08-11-plsm-restriction-operator.md` §5). Measured directly here on my own
arms: **+20.3%.** Two code paths, two runs, one answer.

★★ **2. Does the perimeter penalty survive the correction? — YES, AND THE
WITHDRAWAL IS HEREBY REVERSED.** It takes the gap from **+20.3% to +7.1%**, i.e.
it closes **65% of the distance to SIMP**, at margin parity and identical mass.
★ **And it improves CAD accuracy at the same time** — 0.4611 → 0.4385 against
SIMP's 0.4293 — which a smoothing operator cannot fake, because `obl_cad_rms_mm`
measures against the CAD faces themselves. This is a recommendation again, now
with the right number attached.

★★ **3. The gyroid seed REVERSES SIGN. −12% at the probe volume becomes +5.3%
WORSE THAN DOING NOTHING here**, and +26.8% against SIMP — the worst arm in this
table. §2. **This retracts the headline of
`2026-08-12-plsm-monotone-no-nucleation.md`.**

★★ **4. AND AT THIS VOLUME THE MARGIN STOPS DISCRIMINATING.** All four designs
certify within **0.2%** of each other (3251.9 / 3252.2 / 3254.3 / 3259.0), where
the same arms at rung 0.68 spread over 3254–3394 and, with the stress seed, down
to 1815. §3. **That is the most useful engineering fact here: at production's
volume the surface can be optimised essentially for free**, because the margin is
no longer what the design is trading against.

---

## 2. ★ THE GYROID REVERSES, AND THAT RETRACTS THIS MORNING'S HEADLINE

`2026-08-12-plsm-monotone-no-nucleation.md` §0 answer 2 reads: *"A gyroid TPMS
seed at period 20 gives 66,393 (−12.0%) at margin 3378.3. Seven times the
constraint's effect, at no cost. Seed B, deprioritised in the addendum's
ordering, is the result of this task."*

★ **At the matched volume it is the worst arm measured**: 33,200 against the
no-operator control's 31,520. The mechanism did not shrink — **it changed sign.**

**The likely reason, stated as a hypothesis and not a result.** A gyroid is a
minimal surface at the balanced split, dividing space into two interwoven halves
at roughly 50/50. Asked to leave 68% of the part solid it is already off that
point; asked to leave **80%** it is well outside the regime where it minimises
anything, and the thin connected void it produces has more surface per unit
volume than an array of compact holes does. **A minimal surface is only minimal
at its own volume fraction.**

★ **And my ranked next step in that handoff was wrong.** I put "sweep the gyroid
period" first. The right first move was not to refine the mechanism but to check
whether it worked at all at the volume that ships. It does not. **Item 1 of that
handoff's §7 is withdrawn**; the period sweep is not worth machine time until
someone shows a TPMS helps at 80% solid.

## 3. ★ THE MARGIN STOPS DISCRIMINATING, AND THAT IS THE USEFUL PART

| | margin spread across arms |
|---|---|
| rung 0.68, restriction task, 10 arms | 1837 – 3395 (85%) |
| rung 0.68, monotone task, 8 arms | 1815 – 3393 (87%) |
| ★ **rung 0.7973, here, 3 arms + SIMP** | ★ **3251.9 – 3259.0 (0.2%)** |

At 88,424 printed voxels the certified worst case is set by something every
design shares — the loaded and frozen regions — not by how the interior was
carved. **So at production's actual volume, interior surface is very nearly a
free variable.** Every mechanism that was rejected in the last two tasks *for
costing margin* deserves re-testing here before being written off: filter r=2,
filter r=3, the robust triple and the stress seed were all rejected at a volume
where the margin was the binding constraint, and it is not binding here.

★ **The caveat this cuts both ways.** A margin that does not move also cannot
confirm that a mechanism is safe — it confirms that *this part at this volume* is
not margin-limited. On a lighter rung the ordering may return. Nothing here
licenses dropping the margin check.

## 4. WHAT I RECOMMEND NOW

1. ★★ **Give production the perimeter penalty at C=1.** +20.3% → +7.1% internal
   surface, margin parity, mass identical, CAD accuracy improved. It is one term
   in the velocity, it needs no extra solve, and it is the only mechanism in four
   tasks that has now been measured at the shipped convention.
2. ★ **Re-test the four margin-rejected mechanisms at this volume** (§3). They
   were rejected against a constraint that does not bind here. Cheap: four arms.
3. **Raise `eta_voxels` 2.0 → 1.0 and `max_iterations` 60 → 120** as previously
   proposed (`2026-08-12-plsm-production-defaults-PROPOSAL.md`). ★ **But drop
   `hole_period_voxels` 8 → 16 from that proposal** — every seed measurement
   behind it is at the probe volume, and the gyroid reversal is direct evidence
   that seed conclusions do not transfer across volumes.
4. **Retire the monotone constraint's enforcement, keep its counters.** −1.7% at
   the wrong volume, and unmeasured at the right one.

## 5. IN PLAIN LANGUAGE

We finally compared like with like: same weight of metal, same strength, same
part. **The new method leaves 20% more interior surface than the old one — not
three times more.** That confirms, with a second independent measurement, that
the problem three rounds of work were chasing was about five times smaller than
we believed.

**The crude fix works and I was right to be cautious rather than to withdraw it
permanently.** Charging the design a flat fee per unit of surface takes the gap
from 20% down to **7%**, with no weight penalty, no strength penalty, and a shape
that is *closer* to the CAD drawing than it was before. That is now a
recommendation.

★ **And the clever fix from this morning turned out to be an artefact of the
wrong weight.** Starting from a soap-film shape looked like a free 12% win. At
the correct weight it is 5% *worse* than doing nothing. Not smaller — reversed.
**A soap film is only the most efficient shape when it is splitting the space
roughly in half; asked to leave four-fifths of the part solid, it is the wrong
tool.** I retracted that headline the same day I wrote it.

★ **One more thing worth knowing.** At the weight that actually ships, the
strength barely changes no matter how the interior is carved — all four designs
came within 0.2% of each other. Most of the mechanisms rejected over the last two
weeks were rejected for costing strength, at a lighter weight where strength was
the binding limit. **At this weight it is not.** Several of them deserve another
look.
