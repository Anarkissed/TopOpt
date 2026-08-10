# BLOCKED-STOP — review request

**Task:** 2026-08-10-plsm-production, S3 (the solver win).
**Status:** the task's own blocked-stop condition fired. Work on the parametric
deliverables continues; no adoption decision has been taken.
**Evidence:** `evidence/2026-08-10-plsm-production/s3_simp/` — `verdict.txt`,
both arms' `iterations.csv` and `report.json`.

---

## 1. The bar, and that it failed

The task brief lists among its BLOCKED-STOPS:

> the solver win moves a verdict or a margin beyond PR 313's 1.0e-06.

Measured on the maintainer's own job (`job_simp.json`, M2_verticalStand at
resolution 128, declared load case), full uncapped four-rung ladder, three
threads, machine otherwise quiet:

| rung | margin, as shipped | margin, loose + warm | relative change |
|---|---|---|---|
| 0.68 | 3254.356637 | 3254.689339 | 1.02e-04 |
| 0.52 | 3389.417071 | 3389.617960 | 5.93e-05 |
| 0.38 | 3290.912400 | 3291.015473 | 3.13e-05 |
| 0.26 | 3014.120054 | 3011.506053 | **8.67e-04** |

Worst deviation **8.67e-04 — 867× the 1.0e-06 bar**, and 289,000× the
machinery's own warm-vs-cold noise floor (3e-09). **The bar failed.**

## 2. What passed

* **No verdict moved.** All four rungs ACCEPTED on both arms, as before.
* **The speed win is large and real.**

| | iterations | solver steps | wall |
|---|---|---|---|
| as shipped (tight, cold) | 447 | 419,205 | 3776 s |
| loose + warm | 441 | **128,264** | **1832 s** |

  **69.4% fewer solver steps, 51.5% less wall.** PR 324 measured 76% / 59% on a
  single-rung probe; it transfers to the production ladder at 69% / 52%.

## 3. ★ THE DIAGNOSIS I FIRST GAVE WAS WRONG, AND THE CORRECTION MATTERS

My first reading was that the two arms follow a numerically identical trajectory
and merely stop at different iterations, so the margin difference is a
termination artefact and not a solver-accuracy question. **The per-iteration data
refutes that.** Comparing the two arms' compliance at MATCHED iterations:

| | rung 0 | rung 3 |
|---|---|---|
| iteration 1 | **0.00e+00** (identical) | 1.45e-03 (inherited from rung 2) |
| iteration 2 | 5.69e-05 | 1.34e-03 |
| worst, mid-run | 3.16e-04 | **8.60e-02** |
| last matched iteration | 3.67e-04 | 9.54e-05 |

The trajectories diverge by up to **8.6%** in compliance mid-run. That is not a
perturbation at the noise floor; it is a **different optimisation**.

**The mechanism is straightforward and should have been predicted.** The
sensitivity field is computed from the displacement field. Loosening the solve
from 1e-8 to 1e-3 admits a displacement field wrong by ~1e-3, so the design
update is wrong by ~1e-3, and the next iteration starts somewhere else. Rung 0's
iteration 1 is bit-identical because both arms start from the same uniform design
and the first solve happens to land in the same place; from iteration 2 onward
they are following different paths.

**So the honest statement is:** the loose+warm posture does not reproduce the
shipped design. It follows a materially different trajectory and converges to a
**different design that is just as good** — margins within 0.09%, every verdict
unchanged. That is a real and defensible property of a well-conditioned
optimisation problem. It is not the "same design to seven significant figures"
PR 324 reported, and this handoff should not repeat that claim for the ladder.

## 4. ★ THE ATTRIBUTION IS UNRESOLVED, AND IT DECIDES WHOSE PROBLEM THIS IS

The arm that failed combines **two** changes:

1. **the loosened trajectory tolerance** — the `draft` block, which **ALREADY
   SHIPS**. It is not part of this task; it is a posture the maintainer can arm
   today.
2. **the matrix-free warm start** — the only thing this task added.

The mechanism in §3 points squarely at (1): a warm-started solve converges to the
**same tolerance** as a cold one and therefore yields a displacement field within
that tolerance, so it should not move the sensitivity field meaningfully.
Loosening the tolerance necessarily does.

**If that is right, the blocked-stop is a property of a feature that already
exists, and this task's change adds speed without adding divergence.** That is a
completely different review question from the one this document appears to be
asking.

**It has not been measured.** The `loose`-alone arm was cut when four arms did
not fit in the available machine time. **It is one 35-minute run and it should be
run before any allowance is granted**, because it may show that no allowance is
needed for this task's change at all.

## 5. ★ THE LIVE CONSEQUENCE, WHICH IS NOT HYPOTHETICAL

`PlsmOptions` (`core/include/topopt/plsm.hpp`) defaults `cg_tolerance_loose` to
1e-4 and `warm_start` to true. The parametric path is therefore running **the
posture that just failed this bar**, by default — and at the maintainer's
request the front-end (iPad on-device, and the LAN worker) now runs the
parametric path exclusively.

This is defensible on its own terms — a brand-new representation has no prior
certificate to reproduce, so there is nothing for it to be non-identical *to* —
but it should be a decision taken knowingly rather than inherited from a default.
**Nothing has been disarmed pending this review**, on the maintainer's
instruction to keep the work running.

## 6. What would settle it

| experiment | cost | what it decides |
|---|---|---|
| the `loose`-alone arm | ~35 min | whether the divergence is the pre-existing draft posture or this task's warm start. **Do this first.** |
| both arms with the termination pinned to a fixed iteration count per rung | ~2 h | whether the two solvers, on the *same* iterate sequence, agree to the noise floor. Separates "different path" from "different answer". |
| repeat on a second part | ~2 h | whether 0.09% margin agreement is a property of this problem or of the method. One part is one data point. |

## 7. The decision being asked for

Stated neutrally; the recommendation follows.

* **(a) Refuse.** Disarm the loose tolerance on the parametric path
  (`cg_tolerance_loose = 0`), keep the warm start, re-measure. Costs most of the
  speed win. Safe.
* **(b) Allow on the parametric path only.** The parametric path is new and has
  no prior design to reproduce; the SIMP path keeps tight+cold. Keeps the app
  fast, keeps the shipped ladder bit-stable.
* **(c) Allow everywhere.** Accepts that a re-run of a SIMP job may produce a
  different (equally-certifying) design than the one on record. That is a
  reproducibility change, not just a speed change, and it interacts with the
  `lattice_variant` entry point, which REFUSES to re-lattice a design whose
  recorded margin does not reproduce within `100 × cg_tolerance`.
* **(d) Defer** until §6's first experiment has run.

**Recommendation: (d), then most likely (b).** The 35-minute `loose`-alone run
may remove the need for an allowance entirely by showing the divergence belongs
to a feature that already ships. If it confirms that, (b) follows naturally and
this task's contribution — the warm start — is exact and free.

**What I would not do is grant (c) on this evidence.** One part, one comparison,
and an unresolved attribution is not enough to accept a reproducibility change on
the path that produces certificates of record.

---

*Prepared by the implementing agent. §3 corrects a diagnosis I gave verbally
before reading the per-iteration data; the corrected version is the one to act
on.*
