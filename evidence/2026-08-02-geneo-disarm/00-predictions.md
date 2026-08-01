# Predictions, recorded BEFORE any measurement

Task `geneo-disarm`. Written after reading PR 248 / 273 / 275 and the source,
before running a single measurement on this branch. Graded in the handoff.

## The rule I expect to recommend

**(A) re-require the trigger per solve — but with the trigger denominated in the
COST MODEL rather than in a fixed iteration count.**

Reasoning recorded up front, so the grading can catch me if the numbers disagree:

* A held basis must stop carrying the arming decision. That is the defect.
* A bare re-require of `kGeneoTriggerIters = 500` is **not enough**, and I expect
  to be able to show that. If the maintainer's rung 3 shows ~215 CG iterations
  *with deflation active*, then 215 is `N_defl`, not `N_plain`. PR 275 measured
  `N_plain / N_defl ≈ 3.8x`, so the plain count on those solves is plausibly
  700-950 — **above** 500. A bare 500-iteration re-require would therefore
  re-arm on exactly the solves the task wants disarmed, and would be *strictly
  worse* than today on them (today's cost + a 500-iteration burn).
* The fixed count cannot see `N_t`, and `N_t` is what makes the refresh
  expensive. The maintainer's run measured `N_t = 7,588`.
* So the threshold must be PR 275's own break-even inequality, evaluated per
  solve from the run's own measured `N_t` and deflated reference count:

  ```
  engage when   burn_iters  >=  2*N_t  +  2*N_defl_ref
  ```

  in plain-iteration equivalents (PR 275: refresh ~ 2*N_t matvec-equivalents; a
  deflated CG iteration ~ 2 plain ones).

* Denominated in COUNTS, not wall, so the arming decision stays DETERMINISTIC.
  A wall-clock threshold would make the CG path machine-load dependent, which
  AA4 forbids.
* When no basis is held, `N_t` is unknown, so the first build keeps PR 248's
  `kGeneoTriggerIters = 500` unchanged.

## Numbers predicted before measuring

| # | prediction |
|---|---|
| AA2 | On the reproduced latched state the gate **declines on >= 90 %** of solves. Wall per design iteration falls by **~4-5x** (PR 273: GenEO is 80.7 % of a latched iteration; removing it leaves 19.2 %, i.e. 5.2x — I shade it down for the CG iterations that come back when deflation stops). Accelerator overhead remaining = **the recycle setup only, ~7 % of the OLD iteration, ~37 % of the NEW one**. |
| AA2b | The plain (undeflated) iteration count on those solves lands in **600-1000**, i.e. ABOVE 500 — which is the evidence that a bare 500 re-require fails. If it lands below 500, my central argument is wrong and rule (A)-as-written is sufficient. |
| AA1 | On a genuinely catastrophic solve GenEO **still arms and still wins in wall**. The burn grows from 500 to `2*N_t + 2*N_defl` (I predict 1,500-2,500 on the harness fixture), costing ~2-4 s extra. On a 1,685-41,063-iteration solve that is **3-6 % of the solve**, so the win drops by single-digit percent and stays **> 5x**. |
| AA3 | **No verdict moves.** Voxel-classification flips at or under the 1e-9 negative-control floor on the gate fixture, because the production gate fixture is a HEALTHY multigrid run that never enters the Jacobi fallback at all — GenEO is inert there and I expect BIT-identity, not merely tolerance agreement. |
| AA4 | Displacement fields agree with both the always-armed and never-armed postures to **<= 1e-6 relative**, and reruns are **bit-identical** (the decision is a count comparison, not a clock reading). |
| AA6 | Recycle setup share **unchanged in absolute seconds per solve**; its *share* of the iteration rises (because the denominator shrinks), and I will report both so the rise is not mistaken for a regression. |
| AA7 | Full ctest green. Byte-identical on a job where GenEO never arms. I expect to have to UPDATE `test_geneo`'s reuse bar — the second solve of the same system no longer deflates from iteration 0 — and I will do that by ADDING assertions for both gate branches, not by removing the reuse check. |

## What would make me change the recommendation

* If the measured plain count on the latched state is **below 500**, then rule
  (A) as literally written in the task is sufficient and I should ship that
  instead — simpler, and it needs no new constant.
* If the cost gate declines on the catastrophic fixture (AA1), the rule is wrong
  and I stop and report.

## What the rejected rules would have cost

* **(B) periodic plain re-baseline.** One undeflated solve every K design
  iterations. On the catastrophic regime that solve costs 41,063 x 2.05 ms = **84
  s**, versus ~1-4 s for a truncated burn — and it buys a number the burn
  measures for free. Its real cost is that it must run the slow posture ON
  PURPOSE, on the exact regime where the slow posture is catastrophic.
* **(C) wall-based, modelled plain wall.** Cheapest, but it makes the arming
  decision depend on machine load, so the CG path — and therefore the converged
  field to solver tolerance — stops being reproducible. That is a real loss in a
  certification product. The rule I recommend keeps C's *currency* (cost) while
  paying counts instead of clocks for it.
