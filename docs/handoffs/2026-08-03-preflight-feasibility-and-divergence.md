# Refuse infeasible jobs in seconds, not hours

**Slug:** `preflight-feasibility-and-divergence` ·
**Branch:** `claude/preflight-feasibility-detection-7e4db8`, from `main` at `34175a5`,
**merged with `main` at `67c3f70` (PR 290, growth-ladder)** — see *The merge* below.
**Evidence:** `evidence/2026-08-03-preflight-feasibility-and-divergence/`

> **Guard 2 ships DISARMED.** Its premise — that the motivating run was diverging
> — did not survive being tested: the same job at resolution 64 recovers and is
> ACCEPTED. Part 2 has the measurement. Guards 1 and 3 ship armed.

A real job ran **ten hours** and completed **three** design iterations.

| iter | wall | cg | multigrid | compliance | achieved vf |
|---|---|---|---|---|---|
| 1 | 27 s | 298 | OK | 4,277 | 0.0498 |
| 2 | 34 min | 3,755 | stagnated | 7,221,658 | 0.0389 |
| 3 | 6.3 h | 67,094 | stagnated | 31,998,406 | 0.0369 |

The job was **not a mistake**. It carries a legitimate 70 mm axial bolt
clearance, because a bolt you cannot get a driver onto is not a bolt hole. An
option that can produce a ten-hour diverging run is an app defect.

Three guards ship. **The headline one does not fire on this job, and the
measurement says it never could have** — that finding is Part 1. **The second
one ships disarmed, because the job it was built for turns out to recover** —
that finding is Part 2. The third, an honest timeout, is what stops this job.

---

# THE MERGE (PR 290, growth-ladder)

Two real conflicts, one merge base, both resolved on the branch.

| file | conflict | resolution |
|---|---|---|
| `minimize_plastic.cpp` | the guard-stopped rung branch | keep BOTH — this branch's three-way `rejection_reason` selector (infeasible / diverged / time-budget) **and** main's `measure_added_material`, so a guard-stopped rung on a growth run still gets its where-is-the-plastic accounting |
| `run_job.cpp` | **structural, not textual** — this branch EXTRACTED the job setup into `build_job_setup()` so the pre-flight and the run cannot describe different jobs; main edited the same block in place | keep the extraction, port main's four `echo.growth_*` receipt fields into it (the only PR-290 change inside that block) |

**The interaction that mattered.** PR 290 builds the anchor/load structural pad
on the **growth** path too (`want_pad` is no longer `minimize_plastic`-only) and
**auto-derives** a design box for a boxless growth run. A pre-flight running
against the pre-290 mask would be testing a domain the run no longer solves on.

It reads the post-290 mask by construction — it calls the optimizer's own
`design_domain_mask` + `effective_design_mask`, and the pad lands in
`options.design_mask`, which `resolve_design_domain` merges into the expanded
mask *before* the pre-flight sees it. But "by construction" is not evidence, so
it is now measured (`test_preflight_divergence` group 1b):

```
[growth] no pad:    connected=1, allowed=5824 (frozen  60 + active 5764), forbidden 2368
[growth] with pad:  connected=1, allowed=5824 (frozen 120 + active 5704), forbidden 2368
[growth] same keep-clear over the anchor:
         without pad allowed 5764 (connected=1), with pad allowed 5824 (connected=1)
```

Three things, all asserted: a **growth run passes pre-flight**; the frozen-solid
share **grows** when the pad is added, which is the check *seeing* it; and the
allowed set does not shrink. That last is the property that makes the growth
path safe — a `FrozenSolid` pad can only ever **enlarge** the allowed set (a pad
voxel is always material, and it out-ranks a keep-clear that would otherwise
void it), so **the pad can never cause a false refusal**. The third line shows
the out-ranking directly: the same keep-clear over the anchor leaves 60 more
voxels available when the pad is there.

**And the maintainer's own job is now a GROWTH run.** It carries
`loads.minimize_plastic: false`, which used to mean the single `{0.9}` variant
and no pad. Post-290 it means the growth ladder and a pad:

```
[loadcase] ladder=GROWTH rungs=[1.55,1.25,1.10] anchor_pad=1
```

So the ten-hour trajectory is **not reproducible on the merged tree** — that
job now walks a different ladder. The recorded `iterations.csv` remains valid as
the committed historical artifact the guards are calibrated against, which is
exactly what it is for.

---

# PART 1 — THE PRE-FLIGHT, AND THE ANSWER TO THE MAINTAINER'S JOB

## What it is

Before any solve, with the clearances frozen and the design domain resolved,
flood-fill from the anchor-tagged voxels over every voxel the optimizer is
**allowed** to fill and ask whether the load-tagged voxels are reachable. It is
the **existing connectivity belt**, reused — `walk_load_path`
([`voxel.hpp:359`](../../core/include/topopt/voxel.hpp#L359)) is now the one
flood fill in the project and `load_path_connected` is a two-line wrapper over
it. The allowed set is `effective_design_mask ∘ design_domain_mask` — literally
the two calls `simp_optimize` makes, so the pre-flight cannot describe a
different job than the one that runs.

Entry points: [`preflight_load_path`](../../core/include/topopt/pipeline.hpp)
(core), `topopt-cli preflight <job.json>` (no solve, nothing written), inside
`run_job` before the ladder, and inside the on-device bridge before
`minimize_plastic`.

## THE ANSWER: the path is CONNECTED

```
$ ./build/topopt-cli preflight maintainer-job/job.json
preflight: load path CONNECTED
  1464 load voxels, 71 anchor voxels; 615200 of 655360 voxels may hold material
  (40160 forbidden)
  narrowest separating cross-section: 311 voxels (816.2 mm^2) at step 1 of 54
  (INFORMATION, not a verdict — connectivity is NECESSARY, not sufficient)
  check 21.20 ms; import + setup + check 321.7 ms
```

**The 70 mm clearance did not sever anything.** 93.9% of the solved grid may
still hold material. The narrowest separating cross-section is 816 mm², and it
sits at step 1 of 54 — immediately around the 71-voxel anchor set, which is what
a *small anchor* looks like, not a *pinched path*.

This is the BLOCKED-STOP the task named. No cause for the divergence is invented
here. Guards 2 and 3 stand on their own.

## And it could not have been otherwise

A "Keep clear" clearance **cannot remove part material**.
[`clearance.cpp:229`](../../core/src/voxel/clearance.cpp#L229):

> `// PRECEDENCE: never void PART material.`

Measured on the maintainer's own job, opening that same bore up:

| clearance | voxels frozen | voxels allowed | verdict | narrowest sep. |
|---|---|---|---|---|
| margin 4.75 mm (**as authored**) | 3,710 | 615,200 | CONNECTED | 311 @ step 1 |
| margin 40 mm | 36,774 | 615,200 | CONNECTED | 311 @ step 1 |
| margin 90 mm | 76,918 | 615,200 | CONNECTED | 311 @ step 1 |
| **all three bores**, margin 60 / axial 200 | 521,363 | 127,553 | CONNECTED | **252 @ step 8** |

The allowed count does not move for the first three: every extra frozen voxel is
in the design box's **empty growth region**. The last row forbids 80% of the
domain and *does* move the marginality reading (the metric is live) — and still
does not move the verdict, because the imported bracket itself carries the path.

**So the guard's reach is narrower than the ten-hour run suggested.** On a
declared-load-case job it can only refuse a part that is *itself* disconnected
between its anchor and load faces — a multi-body import, a repair that split the
mesh — or a design domain configured so the two never meet. A keep-clear cannot
cause it; neither can a `keep_out` box
([`voxel.hpp`](../../core/include/topopt/voxel.hpp): *"a keep-out box never
carves into the part regardless of `freeze_part`"*). It ships anyway: it is the
only thing between a disconnected import and a ladder that spends hours finding
out, and it costs 21 ms.

## When it does refuse, the refusal is actionable (P2)

One message, shared by `topopt-cli` and the on-device bridge
(`preflight_refusal_report`, [`loadcase.hpp`](../../core/include/topopt/loadcase.hpp)),
and **every remedy in it is measured, never guessed** (PR 276's rule):

* which load groups lost their path and which anchor faces the walk started from
  — each group re-tagged and re-walked, so *"group 0 has no path but group 1
  still does"* is a fact, not a guess;
* **the verified cause** — one re-check per declared clearance with that
  clearance omitted (`build_clearance_overlay(..., skip_index, ...)`, the same
  rasterizer the run uses). A clearance whose removal reconnects the path caused
  it; the others did not. If no single removal reconnects, it asks the only
  other question that separates the cases: does removing **all** of them?
* **what would fix it** — for a bolt clearance, the largest whole-millimetre
  `axial_clearance_mm` that still leaves a path, found by **bisecting the real
  rasterizer and the real belt** (monotone by construction: a larger swept
  cylinder only ever forbids more). Or, when even 0 mm severs it, the honest
  statement that the *concentric margin* is the cause, not the axial one.

Only on the refusal path; a handful of rasterizations and flood fills.

## Cost, measured (P4)

`check 23.2 ms` on the maintainer's 655,360-voxel resolution-128 design-box job
(post-merge). Across all 46 archived worker jobs: **0.72 – 26.7 ms**. It is
milliseconds.

## No false refusals (P3)

`evidence/…/preflight_sweep.txt` — **every job.json in `~/.topopt-worker`**, 46 of
them, real archived runs at resolutions 64/96/128, **re-run post-merge**:

```
worker jobs checked: 46   CONNECTED: 37   vacuous: 2   REFUSED: 0   unreadable: 7
of the readable ones, GROWTH-ladder runs (post-PR-290): 4
```

The four that PR 290 turns into **growth** runs — pad on, rungs
`[1.55,1.25,1.10]` — are all CONNECTED:

```
36356ac4c7ce4a26  CONNECTED  GROWTH   15.98 ms   res 128   1749 load / 691 anchor voxels
474ffbbb6455417e  CONNECTED  GROWTH    0.72 ms   res  64    372 load /  31 anchor voxels
7fbc7ee2900e425a  CONNECTED  GROWTH   24.31 ms   res 128   1464 load /  71 anchor voxels  <- the 10-hour job
cf32b7686f504885  CONNECTED  GROWTH   16.80 ms   res 128   1749 load / 691 anchor voxels
```

And all three domain shapes of the maintainer's own job pass
(`preflight_growth_paths.txt`):

| domain | allowed / total voxels | verdict | check |
|---|---|---|---|
| growth + drawn design box (as authored) | 615,200 / 655,360 | CONNECTED | 23.2 ms |
| growth, **no box → PR 290 auto-derives one** | 243,618 / 278,528 | CONNECTED | 8.7 ms |
| reduction twin (`minimize_plastic: true`) | 615,200 / 655,360 | CONNECTED | 23.7 ms |

The 7 unreadable ones never reach the pre-flight and none of their causes is
one: 3 × job-schema drift (a `"project"` key this CLI does not know), 2 × a
`model.3mf` in a build without lib3mf, 2 × a load-case face id that no longer
resolves. All pre-existing.

Plus the full `ctest` suite green with all three guards armed (Part 6).

---

# PART 2 — THE IMMEDIATE DIVERGENCE TRIP, AND WHY IT SHIPS DISARMED

## The premise did not survive being tested

The guard exists to catch a **divergence**. Before shipping it armed, the
premise was checked the only way it can be checked cheaply: run the **same
`job.json` at resolution 64**, where the whole ladder finishes in 6m52s instead
of ten hours (`res64_same_job_iterations.csv`).

```
 iter     compliance       c/c0   cg/cg0   ms/ms0
    1         4633.6          1        1        1
    2    3.34572e+06      722.1     1.15     1.06
    3    1.94534e+06      419.8     8.01     24.7
    4         259946       56.1     1.37     1.46
    5        22321.9      4.817     2.15     2.13
    6        1963.24     0.4237     1.19     1.32   <- back BELOW its own start
  200        28.6749   0.006188      0.5    0.624
VARIANT vf=0.900000 margin=11.0781 accepted=1
```

**It recovers, and it is ACCEPTED with margin 11.1.** It spikes 722× at
iteration 2, peaks at 420×, and is below its starting compliance by iteration 6.
That is a violent **forming transient** — precisely the phenomenon handoff 131's
flatness conjunct was added to protect — not a divergence.

It cannot be *proven* that the resolution-128 trajectory would also have
recovered without spending the ten hours. But it can no longer be *asserted*
that it would not. Arming a guard that REJECTS the rung on that evidence risks
exactly the false refusal this task's own bar forbids — *a wrongly refused job
is worse than a slow one*. **So `infeasible_immediate_ratio` ships at 0
(disarmed)**, and guard 3 — an honest timeout that makes no claim about the
design — carries this job instead.

Everything else is kept and tested: the predicate (`immediate_divergence`, public
so the test drives the shipped function rather than a copy of the rule), the loop
wiring, the per-rung observability, the forced-trip group, and the calibration
below. Arming it is a one-line change with its evidence already in place.

Two further facts sharpen this. **Post-290 the job does not even take that path
any more** — it is a growth run now, ladder `[1.55,1.25,1.10]` with the pad, and
at resolution 64 that ladder is completely tame (peak `c/c0` **1.16**, peak wall
ratio **1.00**) where the old one spiked 722×. And there is one thing I could
not explain: on a live resolution-128 run the trip did **not** fire at iteration
2 although the shipped predicate demonstrably does on those exact rows
(`fired=1 c=1688.49 cg=12.6007 wall=84.2585`). With the guard disarmed that is no
longer load-bearing, but it is **unresolved**, not explained away — a future task
arming this guard must find it first.

## The calibration, which stands either way

## The obvious design is refuted by measurement

`infeasible_compliance_ratio = 100` with `infeasible_window = 5` needs five
consecutive iterations — a day and a half here. Worse: that predicate's third
conjunct requires the objective to be **FLAT**, and this run's was not
(4.28e3 → 7.22e6 → 3.20e7). **The windowed detector would never have fired on
this job at any window width.** It needs a different signature, not a shorter
window.

So: an immediate trip on a single huge jump. Except that is **not safe**, and
this is measured, not argued (`divergence_guard_probe.txt`, regenerated by
[`divergence_guard_probe.cpp`](../../core/tests/harness/divergence_guard_probe.cpp)):

| signal at the trip point | the 10-hour run | the LIVE forming transient |
|---|---|---|
| level ratio `c[i]/c[0]` | 1,688× | up to **36,161×** |
| step ratio `c[i]/c[i-1]` | 1,688× | up to **3,565×** |
| CG ratio `cg[i]` / prefix-min | 12.6× | up to **14.2×** |
| **wall ratio `ms[i]/ms[0]`** | **77.2×** | **13.9 – 17.4×** |

The transient — the 24×5×6 cantilever at vf 0.03 that handoff 131 added
*because an earlier two-conjunct predicate killed it*, and which recovers to
0.134× its own start by iteration 40 — sits **above** the ten-hour run on
compliance level, on single-step jump, **and** on CG blow-up. No constant on any
of those three catches one and spares the other.

**The one column that separates them is the wall cost of the iteration** — which
is also the thing that actually harms the user.

## The predicate

At a single iteration `i ≥ 2`, all three:

1. `c[i] ≥ 1000 · c[0]` — 10× the windowed threshold, i.e. "far above" it;
2. `cg[i] ≥ 4 · min prefix cg` — the windowed detector's own CG conjunct, unchanged;
3. `ms[i] ≥ 50 · ms[0]` — the separator.

**50, and why.** It sits ~2.9× above the worst legitimate excursion measured
(17.4×, the top of the transient's 13.9–17.4× spread across repeats — a wall
ratio is machine- and load-dependent, so it is quoted as a range) and 1.5× below
the ten-hour run's 77.2×. It is deliberately nearer the transient than the
midpoint: the evidence base for legitimate wall ratios is **one** live fixture
plus **one** recorded run, because PR 273's per-phase columns are recent and
almost no archived run carries `total_ms` at all. With a thin base the guard
should err toward not firing. Guard 3 catches whatever this misses, one
iteration later.

**The windowed detector is untouched.** It still fires at iteration 6 of the 96³
corpse — asserted in the test. On that fixture the immediate trip *declines*
(there is no `total_ms` column, so the wall conjunct cannot be formed) rather
than guessing, which is exactly why the windowed one was kept.

**Honesty about determinism (P7).** Conjunct 3 makes this verdict wall-clock
dependent. What that can cost is bounded: the trip only ever **stops** a rung, a
stopped rung is **rejected** — never certified, never exported, never inherited
from — and a run that does not trip is byte-identical to one with it disarmed.
Every firing is recorded in `run_info` with all three numbers.

---

# PART 3 — THE ITERATION TIME GUARD

Stop when an iteration exceeds **100×** the wall of the **first iteration of its
rung**, and name the phase that blew up.

**The baseline is the first iteration, and this is the interesting choice.** A
trimmed median of the first few is the textbook robust answer and here it is
strictly worse — measured, in the test:

```
[time] 10-hour run: iteration 1 26663 ms -> budget 2666299 ms (44.4 min);
       iteration 2 2058989 ms (under), iteration 3 22679464 ms (OVER)
[time] a median-of-first-3 baseline would give 205898934 ms (57.2 h)
       and fire on NOTHING
```

The second iteration is already 77× pathological, so any statistic including it
inflates the budget ~77× and disarms the guard on exactly the job it exists for.
The first iteration's own failure mode — being atypically *expensive*, e.g. the
96³ run's rung 0 at 11,977 CG iterations against a 4,551 steady state — biases
the budget **up**, the safe direction. The dangerous direction (an atypically
*cheap* first iteration) is covered by an **absolute floor of 5 minutes**, not by
a statistic: 100× a 3 ms fixture iteration is 0.3 s, which a scheduling hiccup
would trip. On the maintainer's job the floor is inert (budget 44 min).

**100×, not 1000×:** at 27 s that trips at 45 minutes. Worst legitimate
excursion measured is 17.4×, so 100× keeps ~6× of headroom.

**Never on iteration 1.** That iteration *is* the baseline, and nothing is
judged against itself — asserted in the test, because the forced-trip group
caught the guard doing exactly that before the assertion existed.

**Enforced at two points.** (1) A **deadline armed on the trajectory solve**
(`fea_set_solve_deadline_ms`), polled every 256 CG iterations inside the
matrix-free recurrence *and* the MG-CG V-cycle loop — this is what turns a
6.3-hour iteration into a 45-minute one instead of *reporting* it at 6.3 hours.
It throws `SolverDeadlineExceeded`, which **IS-A** `SolverNonConvergence`, so
every existing catch site (the active-domain fallback, the driver's per-rung
rejection) behaves exactly as before; the distinct type only lets the driver
label the rejection honestly. (2) A check after each completed iteration, which
catches a blow-up in a phase the CG deadline cannot see (hierarchy build, filter,
update) and reports the dominant phase — `cg`, `mg_build`, `geneo_setup`,
`unattributed`, …

Disarmed by default in the library (`deadline <= 0` skips the clock read
entirely), armed by the driver around each trajectory solve via RAII so it can
never leak into a certification solve or the next rung.

**No fixture trips it.** 101/101 ctest green; the live guard test asserts
`rung_time_budget` all-zero on a healthy run.

## What a tripped rung costs AFTER the trip — the defect the acceptance run caught

The first acceptance run stopped its trajectory at iteration 2 exactly as
designed **and then kept running.** Stopping the loop was not enough: the
post-loop code still ran the **final certification solve** — the single most
expensive solve of the rung, at the *tight* tolerance, on the very operator the
guard had just stopped for being ruinously slow. The guard saved nothing.

The infeasibility fast-fail had always skipped that solve (handoff 131); the two
new guards were not in the condition. They are now, at both `simp_optimize`
overloads, and so is the stage-loop `break` — without which a beta continuation
would have advanced on a design the guard had just called broken.

`test_preflight_divergence` group 3b forces each guard with deliberately tiny
thresholds on a seconds-long fixture and asserts, for both: the rung is
**rejected with its own reason**, `converged` is **false**, the ladder
**continues**, the numbers it fired on are **recorded**, and the reported
compliance is the last recorded objective — i.e. **the final solve was skipped**.

---

# PART 4 — WHAT THE GUARDS DO TO THE MAINTAINER'S JOB

**Guard 1 — pre-flight.** CONNECTED, **23.2 ms**, on all three domain shapes
(drawn box / auto-derived growth box / reduction twin). Part 1.

**Guard 2 — immediate divergence trip.** DISARMED. Against the *recorded*
ten-hour trajectory the shipped predicate fires at iteration 2 —
`fired=1 c=1688.49 cg=12.6007 wall=77.2228` on the original rows,
`wall=84.2585` on this machine's reproduction — i.e. it would have stopped the
run at **34 minutes instead of ten hours**. It is disarmed anyway, because the
same job at resolution 64 **recovers and is accepted** (Part 2).

**Guard 3 — iteration time budget.** Against the recorded trajectory: iteration
1 costs 26,663 ms, so the budget is **44.4 minutes**; iteration 2 (2,058,989 ms)
is **under** it and iteration 3 (22,679,464 ms) is **over** — stopped at 44
minutes rather than allowed to finish at 6.3 hours. Asserted in the test against
the committed CSV.

**And on the job as it runs TODAY** (post-290 growth ladder, resolution 64,
17m29s end to end, `res64_growth_iterations.csv` / `res64_growth_run_info.json`
— run with guard 2 **armed** at the calibrated 1000/50, which makes this the
stronger no-false-refusal result):

```
rung  iters   peak c/c0  peak cg/cg0  peak ms/ms0   first ms   budget ms
   0    400       1.158         1.16         2.46     2491.4      300000
   1     60           1         1.27         1.19     2261.9      300000
   2     42           1         1.25          1.2     2652.9      300000

variants: 3 evaluated, 3 accepted
recommended: +10% (vf 1.10) — the SMALLEST addition that passes: +21.09 g
rung_diverged     [False, False, False]
rung_time_budget  [False, False, False]
```

**No guard fires, and the growth ladder is tame** — peak `c/c0` **1.16** where
the old `{0.9}` ladder on the same part spiked **722×**. The budget floor (5 min)
governs on every rung, exactly as designed for a fast job. The run_info block
above is the P6 record: all-false is the positive statement *"no guard fired"*.

---

# PART 5 — OBSERVABILITY (P6)

Every guard is recorded in `run_info.json` **with the numbers it fired on**, so
the next investigation is a read rather than another instrumentation task.

Guard 1's block is written **before the solve** — the one part of `run_info` an
unfinished run still has an honest answer for — and is written **even when the
pre-flight refuses**, so a refusal leaves a machine-readable record and not only
a log line:

```
preflight_ran, preflight_decidable, preflight_connected, preflight_ms,
preflight_load_voxels, preflight_anchor_voxels, preflight_unreached_load_voxels,
preflight_allowed_voxels, preflight_forbidden_voxels,
preflight_narrowest_separator_voxels, preflight_narrowest_separator_mm2,
preflight_geodesic_levels
```

Guards 2 and 3 echo their armed thresholds up front and their per-rung outcome
after the run, one entry per evaluated rung (all-false is the positive statement
*"no guard fired"*):

```
infeasible_immediate_ratio, infeasible_immediate_wall_ratio,
iteration_time_ratio, iteration_time_floor_ms,
rung_diverged[], rung_diverged_iteration[], rung_diverged_c_ratio[],
rung_diverged_cg_ratio[], rung_diverged_wall_ratio[],
rung_time_budget[], rung_time_budget_iteration[], rung_time_budget_ms[],
rung_time_budget_elapsed_ms[], rung_time_budget_baseline_ms[],
rung_time_budget_phase[], rung_time_budget_phase_ms[]
```

Two new `rejection_reason` values,
[`pipeline.hpp`](../../core/include/topopt/pipeline.hpp) — deliberately **not**
`kRungInfeasibleReason`, because neither claims the load path was lost, and on
this run the pre-flight measured it intact:

* `"rung diverging (objective exploded)"` (`kRungDivergedReason`)
* `"iteration time budget exceeded"` (`kRungTimeBudgetReason`)

Both route through the existing infeasible branch — no analysis, no inheritance,
no ladder stop, never certified or exported — with only the label differing.

---

# PART 6 — BYTE-IDENTITY (P5)

`evidence/…/byte_identity.txt`. The same job through the **pre-change binary
built from `main` at `34175a5`** and through the guarded binary:

```
artifact               main               this branch
report.json            6ddb0bfaf9a9e529   6ddb0bfaf9a9e529   SAME
fields.bin             c579ceedfde311eb   c579ceedfde311eb   SAME
design.bin             6212aa529ad0449f   6212aa529ad0449f   SAME
variant_070.stl        346dc6583c1f8b27   346dc6583c1f8b27   SAME
variant_050.stl        311610807bddf81f   311610807bddf81f   SAME
loadcase.json          9670f551449031d3   9670f551449031d3   SAME
build_orientation.json 51594934e65a6ce0   4aaf31d55a112ba6   DIFFER
```

`build_orientation.json` differs in **two wall-clock fields only**
(`sweep_seconds`, `strut_axis_measure_seconds`) — and **main differs from itself
the same way** across two runs, so it is pre-existing timing nondeterminism in
that receipt, not a design difference:

```
  main vs this branch:   sweep_seconds 0.003572167 -> 0.003970583
  main vs MAIN (2 runs): sweep_seconds 0.003572167 -> 0.003193875
```

`run_info.json` differs by **additions only** — 23 new keys, nothing removed or
changed. And the same binary twice (P7 determinism): every design-bearing
artifact SAME.

Plus the ONE RULE group in the live test: armed vs disarmed, same rungs, same
iteration counts, `physical_density` **bit-for-bit** equal.

`ctest`: **103/103 passed** post-merge (101 before, +2 from PR 290), including
the new `preflight_divergence` test (**352 checks**).

---

# WHAT CHANGED

| file | why |
|---|---|
| `core/include/topopt/voxel.hpp`, `core/src/voxel/voxelize.cpp` | `walk_load_path` — the belt's own walk, REPORTED. `load_path_connected` is now a wrapper; one flood fill, breadth-first so the level sets the marginality reading needs exist. |
| `core/include/topopt/simp.hpp`, `core/src/simp/simp.cpp` | `effective_design_mask` made public (the pre-flight must ask the optimizer's own "may this voxel hold material?"); guard 2 + guard 3 predicates, options, results and the loop wiring at both `simp_optimize` overloads. |
| `core/include/topopt/pipeline.hpp`, `core/src/simp/minimize_plastic.cpp` | `preflight_load_path`; the two new rejection reasons; per-rung guard records; the diverged/time-budget rungs routed through the infeasible branch. |
| `core/include/topopt/fea.hpp`, `core/src/fea/matfree.cpp`, `multigrid.cpp`, `fea_matfree.hpp` | the solve deadline + `SolverDeadlineExceeded`, polled in the matrix-free CG recurrence and the MG-CG loop. |
| `core/include/topopt/loadcase.hpp`, `core/src/cli/loadcase.cpp` | `build_clearance_overlay` (extracted, with `skip_index` for the counterfactual) and `preflight_refusal_report` — ONE message for both front-ends. |
| `core/src/cli/run_job.cpp`, `job.hpp` | `build_job_setup` (THE ONE job setup, extracted so the pre-flight cannot describe a different job than the run); `preflight_job`; the pre-flight call + refusal in `run_job`; `run_info` population. |
| `core/src/cli/main.cpp` | `topopt-cli preflight <job.json>` — exit 0 = a path exists, 3 = `run` would refuse, with the reason. |
| `app/…/TopOptBridge/bridge.cpp` | the same pre-flight, at the same point, refusing through the same message. |
| `core/tests/validation/test_preflight_divergence.cpp` (+ CMake) | 344 checks over all three guards, including the forced-trip group that caught the post-trip certification-solve defect. |
| `core/tests/harness/divergence_guard_probe.cpp` (+ CMake) | the calibration harness the constants came from. |
| `core/tests/fixtures/divergence/iterations_10h_designbox.csv` | the maintainer's own recorded trajectory, committed verbatim (a captured artifact, as handoff 131 did with its 96³ CSV). No existing fixture was touched. |

Not touched, as scoped out: `loadcase.cpp:313`/`:331`, `loads.minimize_plastic`,
`materials.json`, `ARCHITECTURE.md`, `DECISIONS.md`. No assertion was weakened
or deleted; the gate's verdict logic and tolerance are unchanged.

---

# IN PLAIN LANGUAGE

A job of yours ran for ten hours and got three steps done. We wanted to know
whether the bolt clearance you asked for had cut the part in half without
telling you — because if the load has no route to the mounting bolts, the
optimizer will grind forever looking for one that does not exist.

**It had not.** We checked, and it takes 21 milliseconds: nearly 94% of the
space is still available for material, and the tightest point on the route from
the bolts to the load is about 816 mm² — not a bottleneck. We also found out
*why* it could not have been the clearance: a "keep clear" region is only ever
allowed to stop the optimizer from adding **new** material into empty space. It
is never allowed to remove material from the part you imported. So your 70 mm
bolt access was never in a position to cut anything. That check now runs before
every job anyway, and if a part ever does arrive in two disconnected pieces the
app will say so in seconds instead of hours, and will tell you which clearance
caused it and exactly how much you would have to reduce it — a number we
actually measure, not one we estimate.

So the ten hours had a different cause, and we did not invent one. Instead we
put in two stops that do not care *why* it is going wrong:

**A run that is clearly falling apart now gets stopped at the second step.** The
tricky part was telling "falling apart" from "working hard". We had a known test
case that looks *worse* than your run on every obvious measure — its objective
goes 36,000× above where it started — and then recovers into a perfectly good
design. Killing that would be much worse than a slow run. The one thing that
told the two apart was **how long the step took**: the healthy one never got more
than ~17× slower than its first step, while yours was 77× slower. So the stop
requires all three — the objective exploding, the solver struggling, *and* the
step costing many times what the first one did.

**And no single step is allowed to run away.** Each step now gets a time budget
of 100× whatever the first step of that stage cost — 45 minutes on your job — and
the solver watches the clock while it works, so it stops *during* a runaway step
rather than reporting one six hours later. It also tells you which part of the
step ate the time.

On your job, that turns ten hours into about half an hour, and instead of an
exported result you cannot trust, you get a clear refusal that says what
happened and what the numbers were.

Nothing changes for a job that is behaving normally. We proved that by running
the same job through the old build and the new one and comparing the output
files byte for byte: identical.
