# PER-REGION RETENTION — THE BUDGET, PRE-REGISTERED

**Written and committed BEFORE the per-region predicate was implemented or
measured.** That ordering is the point: a budget stated after seeing the numbers
is not a budget, it is a description.

Follow-on to `2026-08-04-subfloor-lattice-unloaded-regions`. The shipped predicate
is scoped to the UNION of every include region; this task makes it per region.

---

## WHY THIS NEEDS A BUDGET AT ALL

Per-region is **not** a refinement. It is a **widening**.

Today one region qualifies or none does, and the union reading refuses more than
it admits — the conservative direction. Per region, a part with eight include
regions can have eight of them qualify independently, and the material held under
the accuracy claim multiplies accordingly.

And the claim cannot be checked. `core/include/topopt/lattice.hpp`, above
`lattice_subfloor_retention_stress_fraction()`: the certification is
**STRUCTURALLY BLIND to cells-per-member** — §10's control swept the cell from
5.00 to 1.00 cells per member at fixed density and the certified margin was
identical to **ten decimal places**. So no margin measurement, on any number of
regions, is evidence that widening this is safe. The margin *cannot* move.

If the quantity of material under an unpriceable claim cannot be bounded by
measurement, it has to be bounded by **policy**. That is what this document is.

---

## THE ANCHOR: THE ONLY CONFIGURATION EVER VERIFIED END TO END

The maintainer's wall, resolution 128, rung 0.68 — the single case where the whole
chain was checked (argmax steady, composite margin +0.0853 % against a 0.10 %
pre-stated bound, no verdict flips):

| | |
|---|---:|
| part printed voxels | 88,424 |
| sub-floor voxels retained | 822 |
| **exposure** | **0.930 % of the part** |

Everything below is stated as a multiple of that one number, because it is the
only one with a verified chain behind it.

---

## THE BUDGET (binding, stated before measurement)

**B-1 — PER REGION, unchanged.** Each region's own measured peak von Mises must be
at or under `lattice_subfloor_retention_stress_fraction()` (0.20) of the PART's
peak. Measured from the demand field, never declared.

**B-2 — AGGREGATE CAP: 3.0 % of the part's printed voxels.**
The TOTAL sub-floor material retained across ALL regions, summed, may not exceed
3.0 % of the printed set. That is **~3.2× the only configuration ever verified**.

*Why a cap and not a per-region rule alone:* "each region qualified individually"
and "the part is fine" are different statements. Eight regions each under 20 % of
peak is eight separate accepted inaccuracies, and nothing in the certificate adds
them up. The cap is the only thing that does.

*Why 3.0 %:* it is a stated, bounded multiple of the verified case — enough
headroom for a part with several genuinely quiet regions, far short of "unlimited
because every region passed". It is a **policy ceiling on exposure, not a safety
threshold**. No measurement supports 3.0 % as safe, and none could; what it does
is stop the widening from being unbounded.

**B-3 — OVER BUDGET ⇒ REFUSE WHOLESALE.** If the total exceeds the cap, retention
retains NOTHING and the receipt says why. It does not retain "as much as fits":
partial retention would mean choosing which regions to sacrifice, and nothing
measures that choice. Refusing everything is the only option that needs no
unmeasured judgement.

---

## WHAT WILL BE REPORTED, WHETHER OR NOT IT IS FLATTERING

1. **The TOTAL retained across all regions**, in voxels and as a fraction of the
   printed set, against the 3.0 % cap. Reported on every armed run.
2. **Per region**: the measured fraction, whether it qualified, and how much it
   retained. A single aggregate would hide which region carries the exposure.
3. **Whether the two readings diverge.** If every region qualifies individually
   while the aggregate is a large share of the part, that is stated as a finding
   in those words — not smoothed over.

---

## ACCEPTANCE BOUNDS FOR THE MEASUREMENT (pre-stated)

**A-1 — the argmax must not move**, measured with **ALL** qualifying regions
retained simultaneously — not one at a time. A move is a BLOCKED-STOP.

**A-2 — composite margin within 0.10 %**, the same bound the shipped work used,
again with all regions armed at once.

**A-3 — ADDITIVITY, the question per-region actually raises.** Retaining N regions
is measured against retaining each alone. If Δ(all N) exceeds the worst single
region's Δ by more than a factor of 2, the effects are **not** additive, the
one-region measurement does not extrapolate, and that is the finding — reported
rather than absorbed. Note in advance: this test is run knowing the margin is
structurally blind, so a flat result here is **weak** evidence and will be
labelled as such.

**A-4 — S1 and S6 re-run.** Byte-identity when off, and the full gate table with
the 1e-9 negative control. Any verdict flip is a BLOCKED-STOP.

---

## WHAT THIS BUDGET CANNOT DO

It bounds how much material is held under the claim. It does not make the claim
true. Nothing in this task, or the one before it, measures whether a sub-floor
lattice is actually accurate — that needs direct FEA of the real strut geometry,
measured at a **44–276× cost ceiling**. The cap is a limit on exposure taken in
the absence of that measurement, and it should be revisited the moment the
measurement exists.
