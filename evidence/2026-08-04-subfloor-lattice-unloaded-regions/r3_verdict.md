# PER-REGION RETENTION — BUILT, TESTED, **DISARMED**. IT DID NOT PASS ITS BAR.

Follow-on to `2026-08-04-subfloor-lattice-unloaded-regions`.
Budget pre-registered in `r0_preregistration.md` **before** any of this was written.

---

## THE VERDICT, FIRST

**BLOCKED-STOP. The widening is not shipped.**

The two numbers I pre-registered — a 3.0 % aggregate exposure cap and a 0.10 %
certified-margin bound — turn out to be **mutually inconsistent on a real part**.
A single region at **2.889 % exposure, INSIDE the cap**, moved the composite
certified margin by **+0.1801 %**, which is **1.8× the bound**.

The rule for this was stated in advance and is not negotiable afterwards: *report
the number, do not adjust the threshold until it fits.* So the per-region
predicate is implemented, unit-tested and **left disarmed**; the shipped law keeps
the UNION reading, which is the conservative one.

---

## THE MEASUREMENT

`r2_additivity.txt`. l-bracket, resolution 48, swept 4–16 mm ladder, two regions
measured quiet on the part's own von Mises field (not guessed — see below).

### A single region, inside the cap, already breaks the margin bound

| rung | retained | printed | exposure | inside 3.0 % cap? | Δ composite margin |
|---:|---:|---:|---:|---|---:|
| 0.68 | 384 | 13,291 | **2.889 %** | **YES** | **+0.1801 %** |
| 0.52 | 384 | 11,382 | 3.374 % | no | +0.1652 % |
| 0.38 | 384 | 9,709 | 3.955 % | no | +0.3740 % |
| 0.26 | 384 | 8,277 | 4.639 % | no | +0.0003 % |

Worst |Δ| for a configuration the cap **admits**: **0.3740 %** — 3.7× the bound.

### And a second, separate finding inside that table

**Exposure climbs down the ladder even though nothing changes.** The retained
count is a constant 384 while the printed set shrinks 13,291 → 8,277 as the volume
fraction drops, so the same region goes from 2.889 % to 4.639 % of the part. A cap
checked per rung — which is what the implementation does — can therefore **admit a
region at the top rung and refuse it at the bottom**. That is the correct
behaviour, but it means "this region is under the cap" is a per-rung statement,
not a property of the region.

### Larger exposure, larger movement

| configuration | exposure | Δ margin |
|---|---:|---:|
| the one fully verified case (maintainer's wall, res 128) | 0.930 % | +0.0853 % |
| single region, this fixture | 2.889 % | +0.1801 % |
| single region, this fixture | 31.43 % | +0.5479 % |

Roughly monotone in exposure. **That is the whole argument for having a cap** — and
also the reason 3.0 % is the wrong number for it.

---

## WHAT DID **NOT** GET MEASURED, AND I AM NOT CLAIMING IT DID

**A-3, additivity, is UNTESTED.** The two regions I built **overlap**: region A's
384 voxels sit inside region B's slab, so `retained(AB) == retained(B)` exactly at
every rung, and A+B was never actually measured. The script's first run reported
"A-3 MET" from four *identical* configurations that all retained nothing, and its
second reported "A-3 MET" from a pair that was really one region. Both were
vacuous passes and both are corrected in the script rather than quietly dropped —
it now fails loudly if any armed configuration retains nothing.

And on a fixture this size the test **cannot** be constructed legally: the smaller
region alone is 2.889 % of the part, so two disjoint regions under a 3.0 % cap do
not fit. **Whether two regions compose additively remains an open question.**

---

## WHAT IS TRUE, AND WORTH KEEPING

* On the maintainer's own part the per-region predicate retains **exactly what
  scoping to the wall by hand already retained** — 822 voxels, 0.930 % exposure,
  under the cap (`r1_per_region.txt`). Exactly **one** of his eight regions is
  quiet enough (0.1707); the rest measure 0.26–0.91. So per-region would have
  bought him convenience, not extra material, and the feared multiplication does
  not occur on his job at all.
* Every Δ measured was **positive** — the certified margin went *up*, the safe
  direction. That is worth noting and is **not** a defence: the margin is
  structurally blind to cells-per-member (lattice.hpp ★★), so its sign carries
  little more information than its magnitude.
* The implementation, the aggregate cap, the per-region receipt and the unit tests
  (`test_grading` 13j/13k, 26,009 checks) all work and all pass. Turning it on is
  one line. It is off because of the measurement, not because it is unfinished.

---

## WHAT WOULD UNBLOCK IT

An exposure cap derived **from the margin evidence** rather than from a multiple of
one verified case. The evidence currently supports something near **1 %** — the
verified configuration sits at 0.930 % / +0.0853 %, just inside the bound, and
2.889 % is already 1.8× outside it.

That is a decision about how much of the feature to give up, and it is the
maintainer's to make, not one to quietly pick here. It also should not be made on
this evidence alone: every number above comes from a margin the certification
cannot use to see this defect, so a tighter cap would be bounding exposure by
proxy, not by proof.

---

## THE HONEST SUMMARY OF THE BUDGET EXERCISE

The pre-registration did its job — and what it caught was **my own numbers**, not
the code. Had the cap been chosen after seeing the results, 3.0 % would have looked
fine on the maintainer's part (0.930 %, comfortably inside) and the inconsistency
with the margin bound would never have surfaced. It surfaced because both numbers
were written down first and then both were checked.

"Each region qualified individually" and "the part is fine" did not diverge on the
maintainer's job. They diverge on the fixture, and the cap is what notices.
