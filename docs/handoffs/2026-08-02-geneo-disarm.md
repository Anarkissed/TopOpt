# GenEO must let go — an ENGAGEMENT GATE for the armed two-level path

**Task:** `geneo-disarm` · **Evidence:** `evidence/2026-08-02-geneo-disarm/`
**Branch:** `claude/geneo-disarm-rule-5ce4fb`, from `main` after PR 273 + PR 275.
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang `-O2`, Release.
**Kind:** BEHAVIOUR CHANGE to an armed solver default. The gate's verdict logic
and tolerance are untouched. No assertion weakened or deleted; `test_geneo` goes
from 24 checks to 42.

---

## The answer, first

**A held GenEO basis no longer carries the arming decision.** Every fallback
solve now starts plain and must burn past the **measured all-in price of the
armed alternative** before the deflation may engage:

```
engage when   burn_iters  >=  2*N_t  +  engaged_burn  +  2*engaged_tail
                              ^^^^^     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                              coarse    what the last basis-BUILDING solve
                              refresh   actually cost, its plain leg at 1
                                        equivalent each and its deflated leg
                                        at 2 (PR 273 / PR 275 measured both)
```

Read literally: *engage only once finishing plain has already cost more than the
whole armed alternative did last time.* That is the ski-rental rule, the optimal
deterministic online policy — at most 2x off the offline optimum in **either**
direction. Everything in it is a deterministic COUNT, never a clock, so the CG
route stays reproducible.

**On the production gate ladder the change is exactly what it should be:**
deflated solves fall from **168 to 1**, and **no verdict moves on any rung**,
with voxel-classification flips at **zero** against a 1e-9 negative control that
is also zero.

| | before | after |
| --- | ---: | ---: |
| GenEO-deflated solves on the ladder | 168 | **1** |
| coarse refreshes paid | 167 | **0** |
| ladder CG total (GenEO on / GenEO off) | 0.589x | 0.983x |
| verdict flips (4 rungs) | 0 | **0** |
| voxel classification flips vs the 1e-9 control | 0 / 0 | **0 / 0** |

The iteration count went UP and that is the point: PR 273 measured that on this
path **iterations are not cost**. GenEO was buying a 1.7x iteration saving with
a coarse refresh per solve and a 2-3.3x per-iteration surcharge.

---

## 1. Which rule, and why not the other two

### The rule shipped: (A)'s mechanism, denominated in (C)'s currency

The task offered three candidates. The mechanism is **(A) — re-require the
trigger per solve**; a persisted basis must not carry the arming decision, and
that is the defect PR 273 named. But **(A) as literally written does not work**,
and this is the first thing measured on this branch rather than argued:

> On the latched reproduction (the pinned Jacobi fallback, bracket 40x16x41),
> the **plain** Jacobi-CG count is **843 per solve** — *above* the 500 trigger.
> The armed posture runs those same solves at **262** CG.
> (`evidence/…/w1_before.txt`.)

That count is deterministic and is the whole argument: **843 > 500.** The same
run also timed the armed posture 1.85x slower, but it was a separately-run
posture on a loaded host, so it is reported here as directional only — the
load-bearing wall comparison is the interleaved bench under AA2, which puts the
armed posture at 1.24x slower on the mean rather than 1.85x.

So `215` and `275` in the maintainer's `iterations.csv` are `N_defl`, not
`N_plain`. A bare 500-iteration re-require would have re-armed on exactly the
solves this task exists to disarm — and would have been **strictly worse than
today** on them, because it adds a 500-iteration burn to a cost that was already
losing. The task's framing that rung 3 ran "far BELOW the 500 trigger" compares
a deflated count against a plain threshold; the two are not the same quantity.

The reason a fixed count cannot be the gate is structural: **a count cannot see
`N_t`, and `N_t` is what prices the refresh.** The maintainer's run measured
`N_t = 7,588`; a refresh there costs ~27x the entire solve it accelerates
(PR 275). The same 500 that is generous at `N_t = 290` is absurd at 7,588.

So the threshold is denominated in the cost model the task supplied — **(C)'s
currency** — but paid in **counts, not clocks**, because a wall-clock threshold
would make the arming point depend on machine load and therefore make the
converged field non-reproducible run to run. That is a real loss in a
certification product, and AA4 forbids it.

### How this avoids the signal problem

PR 275 measured the **deflated** count to be flat — 191 / 202 / 201 / 213 while
the grid grew 15x and plain Jacobi climbed 388 → 977. The task is right that a
rule reading `N_defl` is blind.

**This rule never reads `N_defl` as a difficulty signal.** The quantity compared
against the threshold is *this solve's own PLAIN burn*, measured on the
undeflated recurrence — the only honest difficulty signal available, and the one
the trigger has always used. `N_defl` enters only on the **cost** side, where its
flatness is exactly what makes it a good predictor of what the armed alternative
will cost. The property that ruins it as a difficulty proxy is what qualifies it
as a price.

There is a second, subtler trap here that measurement caught and reasoning would
not have. The obvious estimate of the deflated leg is the *tail* of the last
engaged solve. It is **wrong**, and wrong in the dangerous direction: a gated
engagement starts from the warm iterate the plain burn already produced, so its
tail understates the price. On the reproduction fixture the build solve's tail is
**78** iterations against a cold deflated count of **187**. Pricing the threshold
off 78 gave a threshold of 736, below the plain count of 843 — so the gate
engaged on every solve and lost **1.9x** on each. The shipped estimator prices
the **whole** armed solve (its plain leg plus its deflated leg) and takes it
**only from a solve that BUILT the basis**, never from a gated engagement —
otherwise the estimate feeds on its own output and the threshold ratchets
upward geometrically until the accelerator switches itself off for good. Both
failure modes are recorded in `src/fea/geneo.hpp` beside the constant.

### What the rejected rules would have cost

**(B) periodic plain re-baseline.** Honest, and it directly measures the thing
that matters. Its cost is that it must run the slow posture ON PURPOSE, on the
exact regime where the slow posture is catastrophic: one undeflated solve on a
41,063-iteration rung is **84 s** at PR 273's 2.05 ms/iteration, versus ~1-4 s
for a truncated burn — and it buys a number the burn measures for free every
solve. **The burn IS a re-baseline, truncated.** We never need to know whether
`N_plain` is 1,685 or 41,063, only whether it exceeds the threshold, and the
burn answers exactly that question and stops paying the moment it has.

*This is the answer to the task's first BLOCKED-STOP: the re-baseline is NOT the
price. A bounded burn separates the two cases, and it is cheaper than (B) by the
ratio of the threshold to the full plain count.*

**(C) wall-based against a modelled plain wall.** Cheapest, and its currency is
right — but as a *decision input* a clock makes the CG path machine-load
dependent. Two runs of the same job would arm at different iterations, take
different Krylov routes, and land on fields that differ at solver tolerance. The
shipped rule keeps C's currency and pays counts for it.

---

## 2. What changed in the code

| file | change |
| --- | --- |
| `core/src/fea/geneo.hpp` | the ENGAGEMENT GATE block: `kGeneoRefreshCostPerColumn = 2.0`, `kGeneoDeflatedIterCost = 2.0`, both derived from PR 273/275 measurements and both taken at the LOW end (under-pricing GenEO makes the gate more willing to engage — the safe direction for the rescue). `GeneoReport::threshold`, action code 5, `GeneoDecision`, the new lifecycle entry points. |
| `core/src/fea/geneo.cpp` | `geneo_solve_begin` no longer engages — it invalidates a stale-DOF basis, computes the threshold and returns. `geneo_engage_now` replaces `geneo_build_now` and handles both the refresh-and-reuse and the build case. `geneo_solve_end` records the DECLINE and the decision log. The degradation reference now uses the DEFLATED iteration count (identical to the old quantity on the old path, where the burn was always 0). |
| `core/src/fea/matfree.cpp` | the CG loop reads `geneo_engage_threshold()` instead of the raw trigger constant and calls `geneo_engage_now`. The mid-solve PCG restart is unchanged. |
| `core/include/topopt/fea.hpp` | `CgInfo::geneo_threshold`; `fea_geneo_declined_solves()`, the two cost constants, and the decision-log accessors. |
| `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` | two new `iterations.csv` columns (`geneo_burn`, `geneo_threshold`) and the `run_info.json` echo including the `geneo_decisions` event log. |
| `core/include/topopt/simp.hpp`, `core/src/simp/simp.cpp` | forward burn/threshold into the per-iteration observation (both `simp_optimize` overloads). |
| `core/src/cli/run_job.cpp` | populate the new run_info fields. |

**Not touched:** fixtures, `materials.json`, `ARCHITECTURE.md`, `DECISIONS.md`,
ROADMAP, the gate's verdict logic or tolerance, the Krylov recycler, the
multigrid hierarchy, `warm_start_coarse`, penalisation continuation.

### Three things the gate deliberately does NOT do

1. **It does not disarm GenEO.** The basis is KEPT. A later genuinely hard solve
   re-engages it with a cheap refresh, never a fresh 38 s eigensolve.
2. **It does not govern the first build on a structure.** No basis means no
   known `N_t`, so PR 248's `kGeneoTriggerIters = 500` governs, unchanged and
   with its derivation intact.
3. **It does not govern a scheduled degradation rebuild on its own.** A rebuild
   is an eigensolve, and "when may a solve pay an eigensolve" is precisely what
   the 500 trigger was derived to answer — so a rebuild solve must clear BOTH
   bars. Neither is weakened; they compose.

---

## 3. The bars

<!-- BARS FILLED BELOW -->

### A note on the machine, before any wall number

The host was **not quiet**. Several other worktrees ran solver campaigns
throughout (`mg_component_sweep`, `mg_sweep2`, two other `topopt-cli` ladders);
1-minute load average ranged **32 to 213** on a 10-core machine. PR 275 hit the
same problem and set the discipline this handoff follows:

* **Iteration counts, `N_t`, thresholds, gate actions, verdicts and margins are
  DETERMINISTIC** and unaffected by load. Every claim that decides something
  rests on those.
* **Wall numbers come only from comparisons that share the load** — postures
  alternated inside one process, or per-solve medians pooled across alternating
  blocks. Cross-run walls are reported as directional, and labelled as such.

The harness makes this possible because the PRE-change posture is exactly
reachable from the probe surface (`engage_threshold = 0` *is* what
`geneo_solve_begin` used to do), so before and after are two settings of one
binary.

---

### AA1 — THE RESCUE CASE STILL WINS ✔

The catastrophic regime is **not reachable by a hand-rolled OC fixture**, and
finding that out cost a false start worth recording. PR 275's own argument says
why: plain Jacobi's count grows with the grid DIAMETER while `N_t` grows with its
VOLUME, so a grid small enough to have a cheap basis is also too small to
stagnate. A sweep over dilution and volume fraction on a 26,240-voxel box moved
the plain count only **764 → 797** (`regime.txt`); a pinned-part variant at 15.9x
dilution reached 491, i.e. it never even hit the 500 trigger in ANY posture, so
GenEO never armed before the change either. That is a null result, not a
negative one, and the harness now says so rather than scoring it a failure.

So AA1 is measured on the **production path**: `minimize_plastic` over PR 248's
big-stagnation design box (73,728 elements, 48.8x dilution), full production
posture minus draft, three postures alternated in ABBA order, per-solve numbers
from PR 273's observation stream. **Pooled over 2 blocks, fallback solves only**
(a multigrid solve never enters GenEO):

| posture | median CG / fallback solve | median wall / solve | engaged | builds | refreshes |
| --- | ---: | ---: | ---: | ---: | ---: |
| plain (GenEO off) | 8,004 | 153.3 s | — | 0 | 0 |
| ARMED (pre-change) | 865 | 105.4 s — **0.69x** | 4/4 | 2 | 2 |
| **GATED (after)** | 3,511 | **99.1 s — 0.65x** | **4/4** | 2 | 2 |

**The gate engaged on every stagnating solve and still beat plain in wall.**

The pooled medians mix the basis-BUILDING solve (identical in both armed
postures) with the one where they differ, so the per-solve rows are the sharper
read. Taking the solve where the postures actually diverge, in both blocks
(`aa1prod.csv`):

| | block 1 | block 2 |
| --- | ---: | ---: |
| plain | 8,004 CG, 153.3 s | 8,004 CG, 165.1 s |
| ARMED | 618 CG, 45.7 s — **3.4x** | 618 CG, 32.1 s — **5.1x** |
| GATED | 3,511 CG, 90.7 s — **1.7x** | 3,511 CG, 87.1 s — **1.9x** |

**Stated plainly: the gate keeps the rescue and gives up roughly half of it.**
It engages at a burn of 2,986 plain iterations instead of at iteration 0, so the
solve pays those iterations before the deflation starts helping. That is the
ski-rental price of not knowing the future, and it is exactly the factor-2 bound
the rule carries — you cannot both refuse to pay GenEO on cheap solves and get
the full win on expensive ones, because until a solve has burned the price of the
alternative you cannot tell which kind it is.

**The trade, in one line:** on this fixture the gate turns a 3.4-5.1x rescue into
a 1.7-1.9x rescue, and in exchange it removes 100 % of GenEO's cost from every
solve that does not need it — which on the production gate ladder is 167 solves
out of 168.

The CG counts are **bit-identical across the two blocks in every posture** (plain
8,004/8,004; armed 618/618; gated 3,511/3,511) while the wall for the same
posture swung 153.3 s vs 165.1 s from machine load alone. That is the whole case
for reading the counts and pooling the walls.

Evidence: `aa1prod.txt`, `aa1prod.csv`, `regime.txt`, `aa1.txt` (the null result).

---

### AA2 — THE TAX IS GONE. THE WALL WIN IS SMALLER THAN I PREDICTED ✗/✔

**Predicted before measuring** (`evidence/…/00-predictions.md`): the gate declines
on >= 90 % of solves, and wall per design iteration falls **4-5x**.

**Measured:** declines on **21 of 24** steady-state solves — right. Wall falls
**1.24x on the mean, 1.03x on the median, 1.9x on the worst solve** — I was
wrong by roughly a factor of four, and the reason is worth more than the number.

`bench` mode: the latched Jacobi reproduction (bracket 40x16x41, multigrid pinned
absent, recycling ON — the production posture), ARMED and GATED run as
ALTERNATING whole trajectories in ABBA order across 3 blocks, per-solve walls
pooled per posture. Steady state = every iteration after the one-off basis build.

| | ARMED (pre-change) | GATED (after) |
| --- | ---: | ---: |
| wall per solve, **mean** | 5.1 s | **4.1 s — 1.24x faster** |
| wall per solve, median | 3.637 s | 3.535 s — 1.03x |
| wall per solve, **worst** | **14.6 s** | **7.7 s — 1.9x** |
| CG iterations | 178 | 495 |
| `cg_ms` | 1,302 | 2,836 |
| `geneo_setup_ms` | 2,550 (max **9,336**) | **0.5** |
| `geneo_apply_ms` | 451 | **0.0** |
| `recycle_ms` | 782 | 1,234 |
| coarse refreshes over 3 blocks | 18 | **0** |
| accelerator overhead, share of solve | **74.4 %** | **30.3 %** |
| — of which GenEO | **59.0 %** | **0.0 %** |
| — of which recycle | 15.4 % | 30.3 % |

**The GenEO tax is gone completely: 59.0 % of the solve → 0.0 %.** PR 273
measured 87.9 % of a latched iteration as accelerator overhead; the fraction
that remains here is **30.3 %, and every point of it is the Krylov recycler** —
a separate cost with a separate owner (AA6), untouched by this task.

**Why I was wrong about the wall, stated plainly.** I treated PR 273's 87.9 %
as removable overhead and predicted the iteration would shrink to what was left.
It does not, because **the deflation was genuinely buying iterations** — 178
against 495, a 2.8x cut, exactly the contrast-independence PR 275 measured. Take
the deflation away and those iterations come back: `cg_ms` rises 1,302 → 2,836 ms
and consumes most of the 3,001 ms of GenEO overhead removed. I made the same
mistake in the opposite direction that PR 248 made: PR 248 counted iterations and
forgot they were not cost; I counted cost and forgot the iterations were real.

So the honest verdict on this fixture is **not** "GenEO was a disaster and the
gate fixes it". It is: **GenEO here was roughly break-even, and the gate converts
a mildly-negative accelerator into a mildly-positive one while removing its
worst behaviour** — the 9.3 s coarse-setup spikes and the 14.6 s rebuild
iterations that the median hides and the mean does not.

**Where the gate's win is large is where `N_t` is large, and this fixture cannot
show it.** Here `N_t = 290`; the maintainer's run measured **7,588**. The refresh
is `2*N_t` plain-iteration equivalents per solve, so it grows with the design
VOLUME while the plain count grows with its DIAMETER (PR 275). At 7,588 the
refresh alone is ~27x the solve it accelerates, and the gate declines it outright.
That is arithmetic from PR 275's measurements, not a measurement of mine, and it
is labelled as such.

The other place the win IS measured is the production ladder: **168 deflated
solves → 1** (AA3), i.e. 167 solves that used to pay a refresh now pay nothing.

Evidence: `aa2_bench.txt`, `bench.csv`, and `w1_before.txt` /
`w1_after_shipped_iters.csv` for the recycling-off variant of the same fixture.

---

### AA4 — EXACTNESS PRESERVED ✔

One developed design on the latched fixture, solved three ways, with a throwaway
solve first so a basis EXISTS and the gate has a real decision to take:

| check | value | bar | verdict |
| --- | ---: | ---: | :--- |
| never-armed | 886 iterations, action 0 | — | — |
| always-armed | 242 iterations, action 1 | — | — |
| GATED | 886 iterations, action 5 (declined) | — | — |
| `max\|du\|/max\|u\|` vs **never-armed** | **0.000e+00** | <= 1e-5 | **PASS** |
| `max\|du\|/max\|u\|` vs **always-armed** | **4.016e-07** | <= 1e-5 | **PASS** |
| rerun bit-identical (field, iterations, action, threshold) | YES | YES | **PASS** |

The first row is exact zero and that is structural, not luck: a solve the gate
declines **is** the plain solve, bit for bit — the deflation never ran. The
agreement with the always-armed posture is 4.016e-07, two orders inside the bar
and the expected O(tol) spread between two solves stopped at the same relative
residual by different Krylov routes (the 133/248 discipline).

**Determinism is owed here and delivered**, because the gate compares COUNTS and
never a clock. Independently corroborated on the production path: the gate
table's "twice-run bit-identical" reads YES for both OFF and ON, before and
after (AA3), and `aa1prod`'s CG counts are identical across both ABBA blocks in
all three postures (plain 8,004/8,004, armed 618/618, gated 3,511/3,511) while
the wall for the same posture swung 153.3 s vs 165.1 s from load alone.

---

### AA6 — RECYCLING IS UNAFFECTED, AND ITS BILL GOES UP ANYWAY ✔ (reported, not changed)

| | ARMED | GATED |
| --- | ---: | ---: |
| **recycle setup matvecs** | **80** | **80 — IDENTICAL** |
| recycle wall per solve | 538.6 ms | 1,170.9 ms |
| recycle share of the solve | 5.7 % | 16.0 % |

**Nothing in the recycler changed** — its setup does exactly the same 80 operator
applies. Two things move anyway, and both are consequences worth naming rather
than burying:

1. **Its SHARE rises** simply because GenEO left the denominator. On the bench
   fixture 15.4 % → 30.3 %. That is not a regression; it is the same cost against
   a smaller total.
2. **Its ABSOLUTE cost rises too**, and this one is real: the recycler harvests
   directions *during* the CG recurrence, so its work scales with the iteration
   count. More plain iterations ⇒ more harvesting. On the stagnation fixture the
   effect is large: recycle setup runs 1.7 s armed, 12.3 s gated, 35.1 s fully
   plain (`aa1prod.csv`).

**This task changes nothing about recycling** — that is the bar, and it holds on
the number that measures the recycler itself (setup matvecs, identical). But a
reader should not be surprised to see the recycle column grow after this change,
and PR 273's 7.2 % figure will read higher on a gated run for exactly this
reason. Whether the recycler should harvest less on a long plain solve is a real
question with a separate owner.

---

### AA3 — NO VERDICT MOVES ✔

`geneo_arming_gate gate`, the production ladder on the stagnation fixture, run
on a **stash-rebuilt pre-change binary** (`/tmp/topopt_before`, `git archive
HEAD`) and on this branch. Recycling + AD + draft armed in both; GenEO OFF vs
ARMED within each.

| rung | vf | verdict OFF → ON | margin BEFORE (OFF → ON) | margin AFTER (OFF → ON) |
| ---: | ---: | :--- | ---: | ---: |
| 0 | 0.68 | ACCEPT → ACCEPT | 26.5863 → 26.5863 | 26.5863 → 26.5863 |
| 1 | 0.52 | ACCEPT → ACCEPT | 12.6812 → 12.6812 | 12.6812 → 12.6812 |
| 2 | 0.38 | ACCEPT → ACCEPT | 7.2076 → 7.08124 | 7.2076 → 7.08086 |
| 3 | 0.26 | REJECT → REJECT | 2.41709 → 2.41612 | 2.41709 → 2.40774 |

**Verdict flips: 0, before and after. Rung count 4 → 4 in both.**

Voxel classification over the 4,608 solid voxels of each rung, against PR 248's
**1e-9 negative-control floor** (the same ladder re-run at a 1e-9 tighter
`cg_tolerance`, which is the smallest perturbation the solver can be asked to
make):

| rung | control flips (floor) | GenEO-ON flips BEFORE | GenEO-ON flips AFTER |
| ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 |
| 1 | 0 | 0 | 0 |
| 2 | 0 | 0 | 0 |
| 3 | 0 | 0 | 0 |

**Zero flips everywhere — nothing to report above the control, because nothing
moved at all.** The `|drho|` columns do move on rung 3 (mean 2.1e-05 → 5.4e-05,
max 6.6e-03 → 1.2e-02), and they sit *below* the control's own rung-3 spread
(mean 3.9e-05, max 7.6e-03) at the mean and just above it at the max. That is
the expected O(tol) spread between two solves stopped at the same relative
residual by different Krylov routes — the 133/248 discipline: an accelerator
that engages or stands down changes the route, never the answer.

What DID change is how much accelerator ran:

| | before | after |
| --- | ---: | ---: |
| GenEO-deflated solves | 168 | **1** |
| coarse refreshes | 167 | **0** |
| ladder CG total, ON / OFF | 0.589x | 0.983x |
| twice-run bit-identical (OFF / ON) | YES / YES | **YES / YES** |

The "after" table was **re-run against the final library** once the last two
source changes had landed (the rebuild pricing and the shared report mapping),
and it reproduced the earlier run exactly — same verdicts, same margins to every
printed digit, same zero flips, same `deflated solves ON=1`, same twice-run
bit-identity. So this table describes the code that ships, not an intermediate
state of it.

Evidence: `aa3_gate_table_before.txt`, `aa3_gate_table_after.txt`,
`aa3_gate_before.csv`, `aa3_gate_after.csv`.

---

### AA5 — THE INSTRUMENT REPORTS THE DECISION ✔

Three surfaces, and one bug found by using them.

**`iterations.csv`** gains `geneo_burn` and `geneo_threshold` beside the existing
`geneo_dim` / `geneo_action`. The pair *is* the decision: `burn >= threshold`
means engage, `burn < threshold` with a held basis means action 5, declined. A
later reader grades the gate from the CSV without re-instrumenting for it.
PR 273's 28 phase columns are untouched and still close their accounting.

**`run_info.json`** gains `geneo_declined_solves`, the two cost constants
(`geneo_refresh_cost_per_column`, `geneo_deflated_iter_cost` — the 114/132
discipline: echo what the run executed under), `geneo_decisions_dropped`, and
**`geneo_decisions`**, the event log: one object per arm/disarm TRANSITION plus
every build, rebuild and memory refusal, each carrying `solve`, `action`,
`burn`, `threshold`, `basis_dim`, `engaged_burn`, `engaged_tail`, `iterations`
and `converged`. Runs of identical consecutive decisions collapse to their first
entry so the log stays legible on a long ladder; the cap is 256 and what it
swallows is COUNTED, not hidden.

**Proven end-to-end on a real job, not just in a unit test.** `ladder32.json`
(the maintainer's own job shape — `l-bracket.step` res 32 in a whole-domain
design box, the exact fixture PR 273 used) cut to a single rung so the run
completes:

```
geneo_armed_solves     9        geneo_basis_builds       5
geneo_declined_solves 23        geneo_coarse_refreshes   4
geneo_decisions_dropped 0       geneo_basis_dim        700
```

with 15 logged transitions, each carrying its numbers. Every threshold in that
log is reproducible from the row above it — solve 3 engaged at a burn of exactly
`2*724 + 500 + 2*700 = 3,348`. See `cli_1rung_README.md` for the full table.

On the **4-rung** version of the same job (`cli_ladder32_README.md`, 64
iterations, 61 of them latched) the gate **declined 50 of 61 fallback solves**
— median 2,839 CG on the ones it turned down against 10,736 on the 5 it took —
and **GenEO's share of the solver's wall fell from PR 273's measured 80.7 % to
16.5 %**, most of what remains being the six basis BUILDS that PR 248's trigger
governs and this task did not touch.

That 4-rung run **aborted** after rung 1 on the pre-existing non-finite-margin
defect PR 273 documented (its "what to do next" item 5, still open). One
consequence is worth knowing: run_info's counters and decision log are written by
a finalize block an aborting run never reaches, so they read zero there, while
the per-iteration CSV columns — flushed row by row — survive intact. That is the
argument for having both surfaces rather than one.

**The bug this bar found.** Two matrix-free entry points fill `CgInfo` from the
GenEO report, and the field-by-field copies had drifted: `multigrid.cpp`'s Jacobi
fallback — *the one production actually runs* — reported `geneo_trigger_burn` and
silently dropped `geneo_threshold`. So a real design-box ladder wrote
`geneo_threshold = 0` on every row while `test_geneo`, which uses the OTHER entry
point, read it correctly. Caught by reading a live run's CSV, not by reasoning.
Fixed structurally: **one** `geneo_fill_cg_info` mapping that both sites call, and
a new test that solves an ODD-AXIS fixture through the multigrid entry point and
asserts it reports the gate's real threshold. That test found its own first
version wrong too — a 32³ grid still coarsens, so the "fallback" it measured was
a 35-iteration multigrid solve that never entered GenEO at all.


---

### AA7 — BYTE-IDENTITY AND THE TEST SUITE

**Byte-identity where GenEO never arms ✔.** `geneo_byteid_xbuild` — public API
only, a 2-rung production ladder, FNV-1a over densities / compliance / margins /
accepts — built against a **stash-rebuilt pre-change library** (`git archive
HEAD` into `/tmp/topopt_before`) and against this branch:

```
pre-change (git archive HEAD) : fnv = 2318d4342a24861e
this branch                   : fnv = 2318d4342a24861e     IDENTICAL
```

That is also the **same hash PR 275 recorded two PRs ago**, so the invariant has
now held across three consecutive changes to this file.

**`test_geneo`: 24 checks → 42 checks, 0 failures.** No assertion was removed or
weakened. The reuse bar (old bar 4) was REWRITTEN rather than deleted, because
its contract genuinely changed — and it gained both branches instead of losing
one:

* the DECLINE branch: the gate's threshold is asserted to BE the cost model's own
  arithmetic on this run's numbers (`2*288 + 500 + 2*91 = 1258`, computed in the
  test, not hard-coded); the declined solve is asserted to reproduce the plain
  field to **1e-12** and the plain iteration count exactly; the basis is asserted
  to be KEPT, not dropped; and the refresh counter is asserted to stay at **0**.
* the ENGAGE branch: with the threshold opened through the harness-only probe
  surface, the same held basis still refreshes (action 2) and still deflates in
  well under half the plain count — *the gate changed WHEN, not WHETHER*.
* a new cross-entry-point check (see AA5) and a new determinism check that the
  gate takes the same decision on the same numbers.

`test_observability` (48 checks) and `test_production_parity` also gained
assertions: the golden CSV row now pins `geneo_burn` / `geneo_threshold` as a
consistent decision, and the parity test pins the two cost constants and the
decline counter beside the trigger and rebuild factor they now govern with.

**Full ctest: 93 tests, 93 passed, 0 failures** (1,388.7 s;
`evidence/…/ctest.txt`).

An enumeration pass before the fixes found exactly **two** failures, both this
task's own doing and both fixed by ADDING assertions rather than relaxing any:

* `matfree_cubic_lattice` — its lattice-tensor fingerprint bar (I5) observed a
  REFRESH, which the gate now declines. Rewritten to assert BOTH branches: the
  closed gate declines and reports its threshold (2,018 = `2*608 + 500 + 2*151`,
  computed in the test), and with the gate opened through the probe surface the
  original fingerprint bar runs unchanged. 29 → **31 checks**. The contract it
  now states is the right one: *the gate decides WHEN the coarse operator is
  used, never WHETHER it may be stale.*
* `observability_capture` — it pinned the CSV at "42 columns" and read memory by
  hard-coded index, so appending two columns made it report **the phase
  accounting as broken**, which is a far more alarming fact than "the schema
  grew". Now it resolves every column BY NAME from `kIterationCsvHeader`, so a
  future column cannot make it lie about what failed. 14 → **16 checks**, and
  the new one asserts on LIVE rows that a declined solve carries a positive
  threshold and a burn equal to its own iteration count.

---

## 4. Predictions, graded

Recorded in `evidence/…/00-predictions.md` before the first measurement.

| # | prediction | outcome |
| --- | --- | --- |
| rule | (A)'s mechanism with a cost-denominated threshold; a bare 500 re-require is not enough | **RIGHT**, and the deciding measurement is the first one on the branch: plain 843 CG > 500. |
| AA2b | the plain count on the latched solves lands in 600-1000, i.e. above 500 | **RIGHT** — 843 (recycling off), 495-522 under the gate with recycling on. |
| AA2 | gate declines on >= 90 % of solves | **RIGHT** — 21/24 steady-state, and 167/168 on the production ladder. |
| AA2 | wall per design iteration falls **4-5x** | **WRONG, by about 4x.** Measured 1.24x mean / 1.03x median / 1.9x worst. I treated PR 273's 87.9 % overhead as removable without consequence and forgot that the deflation was really buying iterations (178 vs 495). This is the most useful thing I got wrong. |
| AA2 | remaining accelerator overhead is the recycler, ~7 % of the OLD iteration | **RIGHT in kind, wrong in size** — it is the recycler and nothing else (GenEO 59.0 % → 0.0 %), but it is 30.3 % of the new solve, not 7 %, partly because the recycler's own cost grows with the iteration count (AA6). |
| AA1 | still arms; burn grows to `2*N_t + 2*N_defl` (predicted 1,500-2,500); win drops by single-digit percent and stays > 5x | **HALF RIGHT.** Still arms, 4/4. The burn came out 2,986, in the predicted band. But the win does NOT stay above 5x — it falls from 3.4-5.1x to 1.7-1.9x. I under-estimated what the burn costs on a solve whose plain iterations are expensive. |
| AA3 | no verdict moves; flips at or under the 1e-9 control; expect BIT-identity on the healthy gate fixture | **RIGHT on the verdicts** (0 flips). **WRONG on the mechanism** — the gate fixture is not a healthy multigrid run at all: it takes 167 Jacobi fallbacks, so GenEO is very much active there and bit-identity was never owed. The verdicts held anyway. |
| AA4 | fields agree to <= 1e-6; reruns bit-identical | **RIGHT, and better than predicted** — agreement with the never-armed posture is exactly **0.000e+00**, because a declined solve IS the plain solve. |
| AA6 | recycle absolute cost unchanged, share rises | **HALF RIGHT.** The recycler's own work is identical (80 setup matvecs both ways) but its absolute wall RISES, because it harvests during CG and there are now more CG iterations. I predicted the share would rise and said the absolute must not move; the absolute does move, for a reason that is not a regression. |
| AA7 | ctest green; byte-identical where GenEO never arms; `test_geneo` needs updating by ADDING assertions | **RIGHT.** 93/93 green, identical FNV, `test_geneo` 24 → 42 checks. I predicted ONE test would need updating; **two** did, and the second (`observability_capture`) was a schema-fragility bug of its own. |

The two predictions I would flag as real misses are the AA2 wall factor and the
AA1 win retention, and they are the same mistake: **I priced the accelerator's
overhead correctly and forgot to price the iterations it was removing.**

---

## 5. Known limitation, named rather than fixed

**The threshold ratchets upward within a rung.** On the production ladder trace
(`cli_ladder32_README.md`) it climbs 3,348 → 3,848 → 5,240 → 5,740 → 7,270 →
7,770. The cause: each degradation REBUILD re-measures the armed cost, and a
rebuild that fires at a high burn records that burn as the armed alternative's
"plain leg" — but that burn is a property of the GATE POLICY, not of GenEO. By
iteration 14 the gate declines a 5,826-iteration solve it might have won.

The direction is **conservative** (fewer engagements, never more), so it cannot
reintroduce the tax, and the rescue still fired three times on that trace. The
obvious tightening is to price the plain leg at
`min(engaged_burn, kGeneoTriggerIters)` — the armed alternative's *intrinsic*
plain leg is the trigger burn, not whatever the gate made this solve burn.

**It is deliberately NOT done here.** It changes a solver default, and this
codebase's discipline is that such a change lands with a re-run AA1/AA2/AA3
battery and a new gate table, not as a one-line improvement at the end of
someone else's task.

---

## 6. Files

**The rule**
- `core/src/fea/geneo.hpp` — the ENGAGEMENT GATE block (constants, derivation,
  both estimator traps), `GeneoReport::threshold`, action 5, `GeneoDecision`,
  the one `geneo_fill_cg_info` mapping, the new lifecycle signatures.
- `core/src/fea/geneo.cpp` — `geneo_solve_begin` (invalidate + threshold, never
  engage), `geneo_engage_threshold`, `geneo_engage_now`, the decline path and
  decision log in `geneo_solve_end`.
- `core/src/fea/matfree.cpp` — the CG loop's gate check; the public accessors.
- `core/src/fea/multigrid.cpp` — the fallback now copies the report through the
  shared mapping.

**The instrument**
- `core/include/topopt/fea.hpp`, `core/include/topopt/observability.hpp`,
  `core/include/topopt/simp.hpp`, `core/src/simp/observability.cpp`,
  `core/src/simp/simp.cpp`, `core/src/cli/run_job.cpp`.

**Tests (all gained assertions)**
- `core/tests/unit/test_geneo.cpp` — 24 → 42 checks.
- `core/tests/unit/test_observability.cpp`, `core/tests/validation/test_production_parity.cpp`.
- `core/CMakeLists.txt` — `src/` on test_geneo's include path for the probe surface.

**Harness (new, not CTest)**
- `core/tests/harness/geneo_disarm_gate.cpp` + `_modes.inc` — modes `regime`,
  `aa1`, `aa1prod`, `aa2`, `bench`, `aa4`, `aa6`.

**Not touched:** fixtures, `materials.json`, `ARCHITECTURE.md`, `DECISIONS.md`,
ROADMAP, the gate's verdict logic or tolerance, the Krylov recycler, the
multigrid hierarchy, `warm_start_coarse`, penalisation continuation, `/app/`.

---

## 7. What to do next

1. **The ratchet** (§5). One line, but it needs the battery re-run.
2. **Measure the gate at the maintainer's real scale.** Everything here says the
   win grows with `N_t`, and `N_t = 7,588` on their run against 290-878 on every
   fixture that fits on this machine. That claim is currently arithmetic from
   PR 275, not a measurement.
3. **The recycler's cost on long plain solves** (AA6). 35 s of recycle setup on
   an 8,004-iteration solve is its own finding, and this task deliberately did
   not touch it.
4. **PR 273's item 3 still stands:** the multigrid hierarchy rebuild is 26 % of a
   HEALTHY run's wall, rebuilt from scratch every iteration. Independent of all
   of the above, and probably worth more than any of it.

---

## In plain language

**The problem.** The optimiser solves a physics problem over and over — hundreds
of times in a single run. Most of the time a fast method handles it. When that
method gets into trouble, a helper called GenEO switches on: it spends a while
building a summary of the structure, and then uses that summary to get the
stubborn solves finished.

The bug was that **GenEO only knew how to switch on.** Once it had built its
summary, it used it on *every* solve from then on, whether that solve needed help
or not. And using it is not free: before each solve it has to re-measure the
summary against the new shape, and while it runs it makes every step of the
solver roughly twice as expensive. Last week's work measured the bill on the
maintainer's own run — **about seven-eighths of each step was the helper, not the
work** — on solves that were never in trouble to begin with.

**The fix.** Now every solve starts without the helper and has to *earn* it.
Before switching on, a solve must have already spent more effort struggling on
its own than the helper's whole approach would cost. The program knows what that
costs, because it measured it the last time it built the summary. In plain terms:
*don't call in the expensive specialist until you've already wasted more time
than the specialist would have charged you.*

This is the same reasoning as the old advice about renting skis — rent until
you've spent what a pair costs, then buy. It is provably the best you can do when
you can't see the future, and it is never worse than twice the ideal choice in
either direction.

**Does it still rescue the bad cases?** Yes. On a genuinely stuck run — solves
grinding through eight thousand steps — the helper still switches on every single
time, and the run still finishes faster than it would without it. It just waits
until roughly three thousand steps in, rather than starting immediately.

**What it costs.** Waiting is not free. On those stuck solves the helper used to
deliver a 3-5x speed-up and now delivers 1.7-1.9x, because the waiting itself
takes time. That is the honest price of not being able to tell in advance which
solves are the bad ones. In exchange, on the production test run **167 of 168
solves now pay the helper nothing at all**, where before every one of them did.

**What I got wrong, and it matters.** I predicted the everyday solves would get
four to five times faster. They got about **1.2 times** faster. The reason is a
mistake worth writing down: I knew the helper's overhead was most of each step,
so I assumed removing it would leave almost nothing. But the helper was *genuinely
doing something* — it was cutting the number of solver steps by nearly three
times — and when you remove it, those steps come back and eat most of the saving.
The person who first switched GenEO on made the mirror-image error: they counted
steps and forgot steps aren't the same as time. I counted time and forgot the
steps were real. The clean win is that GenEO's share of a step went from **59 %
to zero**, and the worst individual steps — the ones where it stopped to rebuild
its summary from scratch — went from 14.6 seconds to 7.7.

**Did the answers change?** No, and this is the part that had to be checked
hardest, because this is a program that certifies whether a part is strong
enough. Every rung of the test ladder returns the **same verdict** as before, and
not a single voxel of material changed category — measured against a deliberately
tiny control perturbation, which also changed nothing. Where the helper stands
down, the answer is **bit-for-bit** the old plain answer, because the helper
simply never ran. Where it still engages, the answer matches to about four parts
in ten million, which is the ordinary disagreement between two runs of the same
solver stopped at the same accuracy. Re-running the same job twice gives
identical results, because the new decision is made by counting, never by looking
at a clock — a clock would have made the program's answers depend on how busy the
computer was, which is not something you want in a tool that signs off on parts.

**One bug fell out of doing this.** The program has two internal routes into the
solver. When I added the new "why did it decide that" number, I added it to one
route and the other silently kept reporting a zero — and the silent one was the
route real jobs actually take. I only found it by reading an actual run's output
rather than trusting the test, which used the other route. It is now impossible
to repeat: both routes copy the same single block of code, and there is a test
that runs the real route and checks the number is really there.

**And one honest wart.** As a run goes on, the bar the helper has to clear
drifts upward, because of how the program re-measures its own cost. It drifts in
the safe direction — it makes the helper more reluctant, never more eager — but
by the end of a long run it is turning down solves it might have won. I know the
one-line change that fixes it. I did not make it, because changing how the solver
behaves means re-running the whole verification battery, and slipping that in at
the end of a different piece of work is how a certification tool quietly stops
being trustworthy.
