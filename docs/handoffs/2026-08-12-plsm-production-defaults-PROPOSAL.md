# PROPOSAL — three `PlsmOptions` defaults, with the measurements, and with what the measurements do NOT establish

★ **This is a proposal, not a change.** Both tasks in flight are bound by
*"`git diff main -- core/src core/include app/` stays EMPTY"*, so I cannot make
this edit on this branch and have not. It is written up separately because the
reviewer asked for it separately: three one-line edits to shipped code deserve
their own review, not a paragraph inside a handoff about something else.

★★ **AND IT IS WEAKER THAN IT WAS WHEN I ASKED FOR IT.** The decision request
that raised these defaults did so alongside a claim that PLSM carries 3× SIMP's
internal surface. **It carries +20.4%**
(`docs/handoffs/2026-08-11-plsm-restriction-operator.md` §5). Every measurement
below was taken at the probe volume convention — **17.1% less printed material
than production** — and a knob's magnitude at 75,016 printed voxels is not its
magnitude at 88,001. Read the DIRECTIONS as established and the NUMBERS as
indicative.

---

## The three

### 1. `eta_voxels = 2.0` → **1.0**

The ersatz band half-width. PR 326, matched iteration 60, everything else held:

| | η = 2 | η = 1 |
|---|---|---|
| internal surface | 60,329 | **53,243** (−11.7%) |
| carved roughness | 12.7098 | **9.2460** (−27%) |
| settled margin | 3028, still climbing | **3388.6** |

★ **η cannot change the extracted topology at all** — the crossing set of
H_η(−φ) at iso 0.5 is the sign set of φ, for every η — so this is not a
measurement of the extractor. It is a measurement of the OPTIMISATION: η sets
how wide a band the shape derivative sees, and a wide band spreads velocity over
material that is not near the interface.

**Confidence: high on direction, medium on magnitude.** A/B at matched
everything, but at the probe volume.

### 2. `hole_period_voxels = 8.0` → **16.0**

The initial hole-seed spacing. PR 326, same conditions:

| | period 8 | period 16 |
|---|---|---|
| internal surface | 79,577 | **73,014** (−8.2%) |
| certified margin | 2859.5 | **3389.5** |
| peak stress | — | a third lower |

Costs nothing: no extra term, no extra solve, one number in the seed.

★ **Caveat specific to this one.** The monotone task is currently sweeping seed
richness (periods 6, 8, 12, 16 and a phase offset) precisely because seed choice
looked load-bearing. **Wait for it** — it may find a better value than 16, or
find that the effect is smaller than PR 326's single A/B suggested.

**Confidence: medium.** One A/B, and a live task is about to give a sweep.

### 3. `max_iterations = 60` → **at least 120, or a margin-based stop**

★ **This one is supported by production's OWN data and does not depend on my
convention at all.** `2026-08-10-plsm-production.md` §3 reports the run of record
capped at 40 iterations per rung, with a last-10 compliance spread of 0.92% on
rung 0.68 and **4.43% / 10.24% / 20.40%** on rungs 0.52 / 0.38 / 0.26 — and says
so itself: *"rungs 0.52-0.26 are UNMEASURED, not lost."*

My own contribution is the mechanism: **the certified margin settles far later
than compliance.** In PR 326 one arm moved 27% in margin while compliance moved
0.05%, and C=8's margin doubled between iterations 40 and 60 while compliance
moved 2%. A compliance-plateau stop halted the restriction task's control arm at
iteration 56 while its margin was still rising 3195 → 3395.

★ **So the real proposal is not the number — it is that a COMPLIANCE plateau is
the wrong stopping signal for a run whose acceptance test is a MARGIN.** Raising
60 to 120 is the cheap version; a margin-plateau stop is the right version.

**Confidence: high.** Two independent lines of evidence, one of them production's
own.

---

## What I am NOT proposing

★ **Not the perimeter penalty.** I recommended it in the decision request and
**withdrew it** after the convention correction: −29.6% internal surface was
measured against a baseline 9× rougher than the shipped path's. Whether it buys
anything at production's volume is one hour of machine time and it has not been
spent.

★ **Not a restriction operator of any kind.** Production has none, and at +20.4%
it is not obvious it needs one. That is the ranked-first open question, not a
recommendation.

## Cost of being wrong

All three are default-OFF today — `plsm` is opt-in — so nothing regresses until
someone switches it on. Items 1 and 2 are one number each and trivially
revertible. Item 3 costs machine time and nothing else. **None of them can change
a verdict without also changing the certified margin, which is measured on every
rung and gates acceptance.**
