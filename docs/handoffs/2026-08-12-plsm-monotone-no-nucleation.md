# plsm-monotone-no-nucleation

★★ **RETRACTION, SAME DAY, BY A LATER MEASUREMENT — READ THIS FIRST.**
Answer 2 below calls the gyroid seed "the result of this task": −12.0% internal
surface at no cost. **At the volume that actually ships it is +5.3% WORSE than
doing nothing**, and the worst of four arms measured against SIMP. See
`docs/handoffs/2026-08-12-plsm-matched-volume.md` §2. Every arm in this handoff
ran at the probe volume convention — ~372,000 mm³ against the shipped path's
~440,551 — and **the gyroid's advantage does not shrink across that gap, it
changes sign.** A minimal surface is only minimal at its own volume fraction.

★ **What survives:** the constraint is still nearly nothing (answer 1); the
component count still falls rather than rises (answer 4); splitting still
dominates nucleation 422 to 3 (answer 5); the stress seed still fails the margin
(answer 3); compliance is still not a proxy for margin (answer 8). Those are
within-task comparisons at one convention and are unaffected.

★ **What is withdrawn:** answer 2, and §7 item 1 ("sweep the gyroid period").
The right first move was not to refine the mechanism but to check whether it
worked at the volume that ships.

Evidence: `evidence/2026-08-12-plsm-monotone-no-nucleation/`. Eight arms, 60
iterations each, six threads, one binary, no failures. `measure.sh` reproduces
every table; `topology_tables.py` reproduces every curve.

---

## 0. THE ANSWERS

★★ **1. Does forbidding nucleation reduce the internal surface? — BARELY. IT IS
THE SMALLEST EFFECT MEASURED IN THIS TASK.** At matched iteration 60, same seed,
the only difference being the constraint: internal surface **75,442 → 74,124
(−1.7%)**, carved roughness 14.1373 → 13.5794 (−3.9%). Margin unchanged (3393.13
→ 3393.17). **It is free, and it is nearly nothing.**

★★ **2. WHAT WORKS IS THE SEED — AND IT IS THE ONE THE BRIEF RANKED THIRD.** A
**gyroid** TPMS seed at period 20 gives **66,393 (−12.0%)** at margin **3378.3
(+3.8% over SIMP)**. Seven times the constraint's effect, at no cost. Period 12
is within noise of it. **Seed B, deprioritised in the addendum's ordering, is the
result of this task.**

★★ **3. THE STRESS SEED LOOKED LIKE THE ANSWER AND IS REFUTED BY THE MARGIN.** It
gives by far the lowest internal surface — **49,950 (−33.8%)**, carved 8.6202,
the best number any mechanism has produced in three tasks — and it certifies at
**1814.7, which is −44.2% against SIMP.** It fails R4 outright. **Not a
candidate, and the surface figure must not be quoted without the margin beside
it.**

★★ **4. AND THE PREMISE IS WRONG: THE VOID'S COMPONENT COUNT DOES NOT RISE OVER
THE RUN. IT FALLS.** In every one of the eight arms. It spikes in the first ~6
iterations as the seed dissolves, then decays monotonically: the control goes
87 → 439 (iteration 6) → 41. **A constraint forbidding increase is being asked to
police a quantity that is already decreasing**, which is why answer 1 is what it
is.

★ **5. The increase that does occur is SPLITTING, not NUCLEATION** — the declared
override, now confirmed on the control arm rather than argued from a smoke test.
99.3% of the control's largest jump is splitting. §2.

★ **6. Repair never failed. `mono_reverts` is 0 on all eight arms**, against
43–57 violations each. The constraint never cost a design step — which is both
why it is free and why it does so little.

★ **7. Does any arm clear SIMP on carved roughness at SIMP's margin? — NO.** Best
qualifying carved is the gyroid's 10.4613 against SIMP's 7.5521. Same standing
caveat as the previous task: these arms print ~372,000 mm³ against SIMP's 440,551,
so the SIMP column is a reference point and not a like-for-like comparison.

★★ **8. AND COMPLIANCE IS NOT A SAFE PROXY FOR THE CERTIFIED MARGIN.** The stress
arm is **+10.6%** on compliance and **−44.2%** on margin — a fourfold
amplification. Every other arm sits within ±0.4% on compliance and within ±0.5%
on margin, so the proxy looks excellent right up to the point where it matters.
**An arm screened on compliance alone would have been shipped.**

---

## 2. ★ THE OVERRIDE, DECLARED, AND NOW MEASURED ON THE CONTROL

The brief says: *"ENFORCE THAT THE NUMBER OF CONNECTED VOID COMPONENTS NEVER
INCREASES."* Implemented literally that fires on almost every iteration. **The
count is not rising because holes are being created. It is rising because
existing void FRAGMENTS as solid bridges across a channel and divides it.**

★ **A void split is a solid merge, and that is classically legal.** Cui et al.'s
own list of what a Hamilton–Jacobi level set may do — *"vanishing of a hole,
merging of holes, and breaking apart of a region"* — permits exactly this.

So the constraint fires on **genuinely new** components only: those sharing no
voxel with any previous void. The control arm now measures both, which it could
not do when the brief was written:

| control arm, iteration 2 | |
|---|---|
| change in component count | **+425** |
| of which genuinely NEW | **3** |
| of which SPLITTING | **422** |

★ **99.3% of the count increase is splitting.** A literal implementation would
have spent its entire budget reverting legal moves. Totals over 60 iterations:
NEW 263, SPLIT −309 (the control's void nets *fewer* components than it started
with).

## 3. THE TABLE

Matched iteration 60 — **computed, not chosen**: the highest snapshot index
present in every arm, which `measure.sh` derives and refuses to proceed without.
All arms print ~372,000 mm³ (the probe volume convention), so the SIMP row is a
reference point and **not a like-for-like comparison** — see
`docs/handoffs/2026-08-11-plsm-restriction-operator.md` §5.

| arm | seed | monotone | carved | ★ n_cut | vs control | CAD err | compliance |
|---|---|---|---|---|---|---|---|
| SIMP | — | — | 7.5521 | 26,191 | — | 0.4293 | — |
| MN_nucleating | holes p8 | **off** | 14.1373 | 75,442 | — | 0.4770 | 0.00252843 |
| MA_holes8 | holes p8 | on | 13.5794 | 74,124 | **−1.7%** | 0.4498 | 0.00252906 |
| MA_phase | holes p8 φ.5 | on | 13.4938 | 74,476 | −1.3% | 0.4559 | 0.00252652 |
| MA_poor12 | holes p12 | on | 12.5509 | 73,000 | −3.2% | 0.4762 | 0.00252744 |
| MA_rich6 | holes p6 | on | 11.5745 | 68,382 | −9.4% | 0.4461 | 0.00253080 |
| MB_gyr20 | **gyroid** p20 | on | 10.4908 | 66,393 | −12.0% | 0.4592 | 0.00254096 |
| MB_gyr12 | **gyroid** p12 | on | 10.4613 | 67,674 | −10.3% | 0.4746 | 0.00252624 |
| ★ **MC_stress** | **stress** | on | **8.6202** | **49,950** | ★ **−33.8%** | **0.4392** | 0.00279875 |

★ **The ordering is seed, seed, seed** — the constraint moves the surface 1.7%,
a gyroid moves it 12%, stress trajectories move it 34% — **but only the first two
survive the margin.** With the margin column attached:

| arm | n_cut | vs control | margin | vs SIMP | verdict |
|---|---|---|---|---|---|
| ★ **MB_gyr20** | **66,393** | **−12.0%** | **3378.3** | **+3.8%** | ★ **the result** |
| MB_gyr12 | 67,674 | −10.3% | 3383.5 | +4.0% | ✓ |
| MA_rich6 | 68,382 | −9.4% | 3386.6 | +4.1% | ✓ |
| MA_poor12 | 73,000 | −3.2% | 3376.6 | +3.8% | ✓ |
| MA_holes8 | 74,124 | −1.7% | 3393.2 | +4.3% | ✓ (the constraint alone) |
| MA_phase | 74,476 | −1.3% | 3378.5 | +3.8% | ✓ |
| MN_nucleating | 75,442 | — | 3393.1 | +4.3% | the control |
| ★ MC_stress | 49,950 | −33.8% | **1814.7** | **−44.2%** | ★ **REFUTED** |

Every arm's load path is connected and every arm is `accepted` by the analyzer;
**the stress arm fails on margin, not on validity.** Masses are 463.7–463.8 g
across all eight — the volume constraint held to within 0.1 g.

### ★ what the stress seed actually is

**One state solve on the fully solid domain with the real load case**, then void
is seeded where the strain energy density is lowest, thresholded at the quantile
that yields the requested rung. Strain-energy density rather than the principal
directions, because it is what `simp_compliance`'s sensitivity already returns —
no second stress recovery, no second convention — and for an isotropic material
it is monotone in |σ|, so *low energy* is *between the load paths*.

**Cost: one extra FEA solve, once, before iteration 1.** The arm's total wall
time is 18.0 minutes against the control's 29.2 — it is the *cheapest* arm in the
task as well as the smoothest.

★★ **AND IT IS STILL REFUTED.** Margin 1814.7, −44.2% against SIMP. The seed
concentrates material onto the load paths the *fully solid* part used, and the
optimiser then cannot recover the redundancy that the certified worst case needs:
low compliance under the design load is not the same property as margin under the
worst case. **This is the fourth mechanism across three tasks to produce a large
surface reduction and fail the margin bar**, after filter r=2, filter r=3 and the
robust triple.

### ★ the seed-period sweep is NON-MONOTONE, and I will not smooth that over

Periods 6, 8 and 12 give 68,382 / 74,124 / 73,000. **Period 8 is the worst of the
three, and both a richer and a poorer seed beat it.** PR 326 found period 16 beat
period 8 too, which is consistent, but it means "richer seeds are better" is NOT
what the data says. A phase offset at fixed period changes nothing (74,476 vs
74,124 — within the spread of neighbouring iterations).

## 4. ★ THE 3D CAVEAT — CHECKED, NOT ASSUMED

In 3D a hole can be tunnelled through material between two pieces of existing
boundary without any new component appearing: the void stays connected, b0 is
flat, and b1 rises. Component monotonicity would call that legal. So b1 is
computed exactly, from the Euler characteristic of the void's cubical complex
(χ = V − E + F − C, b1 = b0 + b2 − χ), and reported beside b0.

| arm | Δb0 | Δb1 | verdict |
|---|---|---|---|
| MN_nucleating | −46 | −1941 | clean |
| MA_holes8 | −76 | −1967 | clean |
| MA_poor12 | −481 | −1847 | clean |
| MA_rich6 | −1254 | −4351 | clean |
| MA_phase | −80 | −1970 | clean |
| MB_gyr12 | −5 | −76 | clean |
| MB_gyr20 | −9 | −12 | clean |
| MC_stress | −4 | **+2** | ★ b0 held, b1 rose |

★ **No arm evades the constraint meaningfully.** Only the stress arm shows the
signature at all, and at +2 tunnels over 60 iterations it is not a mechanism —
it is a rounding. The honest reading is that **the evasion the brief worried
about does not occur here**, because the topology is simplifying on its own.

## 5. ★ THE TPMS PREMISE WAS WRONG, AND THE GYROID IS NEW CODE

The addendum said: *"THE PROJECT ALREADY HAS TPMS MACHINERY from the lattice
track — reuse it, do not write a second implementation. Say which file you took
it from."*

★ **There is no TPMS machinery in this repository.** The only `gyroid` in `core/`
is a comment at `core/include/topopt/lattice.hpp:22` saying TPMS sheets *"attach
to the same machinery **later**"* — explicitly not built — plus a string in
`rules.json`. The lattice track is seven **strut** topologies, a different object
from a TPMS sheet.

**So the gyroid here is three lines I wrote**:

    phi = sin(wx) cos(wy) + sin(wy) cos(wz) + sin(wz) cos(wx) - t

★ **with w = 2π/period applied PER AXIS in voxels (R5), never from a minimum over
the axes** — this grid is 128 × 31 × 118, a 4:1 slab, and a period keyed to the
smallest axis is the trap PR 323 lost a day to. I flagged the missing machinery
before starting and am recording it again rather than implying a reuse that did
not happen.

★ **And the bet it was making is worth stating, because it lost.** A TPMS is a
minimal surface — locally area-minimising — so it starts at the lowest interface
area available for its topology, which in a run that can only simplify should be
a lasting advantage. It gave −10 to −12%, real but a third of what the stress
seed gave. **Starting with little surface matters less than starting with the
surface in the right place.**

## 6. ★ THE PROBLEMS I HIT

**P1 — ★★ THE CONTROL ARM RAN FOR 36 ITERATIONS AND MEASURED NOTHING, AND EVERY
HEALTH CHECK PASSED.** `void_components`, `euler_chi`, `cavities` and `tunnels`
were 0 on every row of `MN_nucleating`. The counters lived inside the
`if (a.monotone && …)` branch, and the control is *by definition* the arm that
does not pass `--monotone` — so the one arm whose entire purpose is to show the
count rising without the constraint was the one arm that could not.

★ The night queue verifies each arm four ways — **exit code 0, `summary.txt`
present, ≥1 iteration, no `FATAL` in the log** — and all four passed. **Every one
of those tests that the process RAN. None tests that it RECORDED.**

**Solved** by separating measurement from enforcement: topology is counted on
every iteration of every PLSM arm and `--monotone` gates only the repair.
`mono_violations` is counted on the control too, since "how often would the
constraint have fired" is precisely what a control is for. 25 minutes discarded
and the queue restarted so all eight arms share one binary. The watcher gained a
**content** check — any finished arm whose `void_components` column is constant
wakes me — because four liveness checks could not see this.

**P2 — the brief's constraint fires on the wrong quantity.** §2. **Solved** by the
declared override, and the control now measures both halves so the override is
evidence rather than assertion.

**P3 — `--certify-field` must be repeated per field.** I wrote the new
`measure.sh` from memory instead of copying the working invocation, passed the
flag once followed by N paths, and the probe rejected path 2 with `FATAL: unknown
argument` — **after** completing all of M1's work. **Solved**, and the reason is
now a comment in the script.

**P4 — 57 certifications at ~6 minutes each is 5.7 hours.** The full per-snapshot
margin curves would not have finished in the time available. **Handled by
scoping**: iteration 60 for all eight arms plus SIMP — the nine certifications
the verdict actually needs — ran instead. ★ **The per-iteration margin curves are
therefore NOT in this handoff**, and that is a stated gap, not an oversight. The
partial sweep is kept at `m2_partial_allsnaps/`.

**P5 — I drafted §0 before the margins existed and had to rewrite it.** The draft
led on the stress seed as the task's result. **The margin refuted it** (−44.2%),
and the draft was never committed, which is the only reason it is a note here
rather than a correction commit. Related to the previous task's harder lesson:
**do not write a comparison table until the sweep that feeds it has exited.**

## 7. WHAT I WOULD DO NEXT, RANKED

1. ★★ **Sweep the gyroid period.** 12 and 20 are within noise of each other
   (67,674 and 66,393) and both beat every hole-array arm. Nobody has looked
   between or beyond them, and this is the one mechanism in this task that is
   free. Four arms, ~80 minutes.
2. ★ **Combine the gyroid seed with the perimeter penalty at C=1.** They act at
   different times — one sets where the surface starts, the other prices it
   throughout — so unlike the filter-plus-penalty pair in the previous task there
   is a reason to expect them to compound. One arm.
3. ★ **Ask why the stress seed loses 44% of the margin while losing only 10.6% of
   the compliance.** That gap is the most interesting number in this task. If the
   answer is that the seed removes redundancy the worst case needs, it is a
   general warning about energy-based seeding, not a quirk of this part.
4. **Retire the monotone constraint, or keep it as a free diagnostic.** −1.7% does
   not justify a flag on its own, but the topology counters it introduced cost
   milliseconds and made every other finding in this task legible. My preference
   is to keep the measurement and drop the enforcement.
5. **Everything is still at the probe volume convention.** The matched-volume arm
   ranked first in the previous handoff outranks all four of the above.

## 8. IN PLAIN LANGUAGE

**The thing I was asked to build barely matters, and I can say so precisely.** The
idea was to forbid the method from punching new holes, on the theory that new
holes are where the extra roughness comes from. Built, measured: it removes
**1.7%** of the interior surface. It costs nothing, and it does almost nothing.

★ **The reason is that the premise was backwards.** I expected the number of
separate holes to climb through the run. It *falls* — sharply, in every single
test. It jumps in the first few steps as the starting pattern breaks up, then
drops steadily for the remaining fifty. Forbidding an increase in something that
is already decreasing is not much of a constraint.

★★ **What actually worked was the starting pattern.** Beginning from a smooth
mathematical surface — a gyroid, the shape soap film makes — instead of a grid of
round holes removes **12%** of the interior surface for free, with the part just
as strong. That is seven times what the constraint bought. It was ranked third of
four in the instructions I was given.

★★ **And the most promising result was a trap.** Starting the holes where the
solid part carries the least load looked like the best thing found in three
tasks: a **third** of the interior surface gone. Then it was certified and it had
lost **44% of its strength margin** — while its stiffness had only dropped 10%.
**The cheap measurement said it was fine and the real one said it was not.** If I
had screened on stiffness, as would have been natural, I would have recommended
it.

**One mistake of mine is worth your attention.** The control test — the one that
exists to show what happens *without* the new rule — ran for 36 iterations
writing zeros into every column it was supposed to fill, because I had put the
measuring code inside the rule it was measuring. It passed all four automatic
health checks, because all four ask "did it run?" and none asks "did it record
anything?". I caught it by reading the actual numbers rather than the status
line. The checks now include that question.
