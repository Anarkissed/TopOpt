# SIMP penalization continuation — ramp p instead of fixing it at 3

**Task:** `simp-penalization-continuation` ·
**Evidence:** `evidence/2026-08-02-simp-penalization-continuation/`
**Kind:** OPT-IN FEATURE, **DEFAULT OFF**, **NOT ARMED**. The shipped formulation
(ARCHITECTURE §4, "SIMP, penalty p = 3") is untouched and proven bit-identical
(§AD1). `ARCHITECTURE.md`, `DECISIONS.md`, `benchmarks.json` and the fixtures
were not edited. `minimize_plastic.cpp` and `multigrid.cpp` were not touched.

---

## The answer, first

**The contrast hypothesis is CONFIRMED as a solver claim and REFUTED as a net
win. I recommend AGAINST arming any schedule tested.**

Ramping `p` does exactly what the WHY predicted. On the fixture that stagnates,
the shipped `p = 3` burns the multigrid budget and falls to Jacobi-CG on design
iterations **3, 4 and 6 of every rung** — three stagnating solves per rung, with
CG spikes of 858 / 2091 / 1212 against a healthy ~50. Ramp `p` from 1 and that
goes to **zero**, with **1.65–3.65× fewer trajectory CG iterations per rung**
and **1.88–4.52× less wall**.

And then the design fails the gate.

All figures below are the matched two-rung ladder (rungs 0 and 1), the only
apples-to-apples basis — the baseline evaluated a third rung that no schedule
reached.

| | stagnating iters | traj. CG | wall | rung-0 verdict | rung-1 verdict |
| --- | ---: | ---: | ---: | --- | --- |
| **S0 — OFF (shipped p = 3)** | **6** | 13462 | 454.3 s | ACCEPT 3.596 | ACCEPT 2.162 |
| S1 — Peetz literal, 20 it/value | **0** | 3708 | 120.9 s | **REJECT** 1.983 | **REJECT** 1.260 |
| S2 — Peetz values, 1 it/value | 3 | 7591 | 241.4 s | ACCEPT 3.241 | **REJECT** 0.876 |
| S3 — Amir–Sigmund 1→3, 1 it/value | 2 | 6418 | 158.4 s | ACCEPT 3.737 | **REJECT** 1.277 |
| S4 — stagnation-window 1→3, 2 it/value | **0** | 6035 | **100.5 s** | ACCEPT 4.111 | **REJECT** 1.428 |

**Every schedule flips at least one verdict**, and by AD4's own rule that is a
BLOCKED-STOP for each of them. All four lose rung 1 to `load path not connected`;
the baseline carries it at margin 2.162 and only stops at rung 2. The
rejections are not marginal — the rung-1 compliance goes from 14.55 to 36–1257.

So the accelerator works and the optimizer does not survive it. §7 names the
suspected mechanism (and §7a records that the experiment meant to confirm it
failed), and §9 names the change that would test it properly — a change in a file
this task does not own.

---

## 1. What was built

The whole change is 234 inserted lines across three tracked files, plus two new
ones:

```
 core/CMakeLists.txt          |  13 +   (registers the new CTest target)
 core/include/topopt/simp.hpp | 104 +
 core/src/simp/simp.cpp       | 119 +-  (2 lines changed: the two solve call sites)
 core/tests/validation/test_penalty_continuation.cpp   (new, CTest)
 core/tests/harness/penalty_continuation_probe.cpp     (new, not a CTest target)
```

The two changed lines in `simp.cpp` are the trajectory-solve call in each
`simp_optimize` overload, `params` → `traj_params`. Everything else is addition.
No fixture, `materials.json`, `benchmarks.json`, `ARCHITECTURE.md`,
`DECISIONS.md`, `minimize_plastic.cpp`, `geneo.cpp` or `multigrid.cpp` was
touched, and no assertion anywhere was weakened or removed.

### 1a. `SimpOptions::penalty_continuation` — a schedule, EMPTY by default

```cpp
struct PenaltyStage {
  double penalty = 1.0;  // p for this stage (finite, > 0)
  int iterations = 20;   // design iterations held at this p (>= 1)
};
std::vector<PenaltyStage> penalty_continuation;  // EMPTY = OFF
```

Consumed cumulatively against **this `simp_optimize` call's own 1-based design
iteration**. Past the end of the schedule the **last stage's penalty is HELD**,
so a schedule ending at 3.0 spends its tail running exactly the shipped law.

### 1b. `penalty_at_iteration()` — pure, and the schedule builders

`penalty_at_iteration(schedule, iteration)` has no clock, no state and no
floating-point reduction, so re-derivation is bit-identical. It refuses an empty
schedule and a zero/negative iteration rather than inventing a default.

`penalty_continuation_ramp(p0, p1, step, iterations_per_stage)` builds a linear
ramp and lands its endpoints **exactly** — each value is synthesised as
`p0 + k*step` from a stage count derived from the arithmetic, never accumulated,
so `1.0 → 3.0` by `0.25` ends on `3.00` and not `2.9999999999999996`.

`penalty_continuation_peetz()` is Peetz & Elbanna verbatim: increments of 0.25
from 1 to 4, twenty iterations per value.

### 1c. The wiring — TRAJECTORY ONLY

Both `simp_optimize` overloads compute one `SimpParams` per iteration and pass it
to the trajectory solve. **The final / certified compliance solve always runs at
`params.penalty`** — the documented `p = 3` — exactly as warm starts (110), the
draft CG tolerance (128) and the active domain are trajectory-only. The certified
number is never computed under a law the schedule invented.

The per-iteration `p` is reported on `SimpIterationObservation::penalty`, so the
trace answers "which material law produced this row's compliance and CG count"
by reading rather than by inference. On the OFF path the column reads 3 on every
row.

`simp_optimize_stress` **REFUSES** a schedule: the qp relaxation requires
`0 < relaxation_q < params.penalty` at every step, an invariant a moving `p`
would have to re-establish per stage. Out of scope means refused, not quietly
ignored.

### 1d. Why this needed no `minimize_plastic.cpp` change

`MinimizePlasticOptions::simp` is copied wholesale into each rung's
`SimpOptions`, so the field rides through the production driver untouched — the
same route `projection` and `mma_projection` already take. The measurement probe
therefore drives `minimize_plastic()` **directly**, with the real ladder, the
real gate and the real verdicts. Nothing was simulated and no coordinated file
was edited.

The consequence: the schedule is **not reachable from `job.json`**. Arming it for
production would need a `minimize_plastic.cpp` / `run_job.cpp` change. Given the
result below, that is not work anyone should do yet.

---

## 2. AD1 — OFF IS BYTE-IDENTICAL (the load-bearing bar)

`evidence/…/ad1_byte_identity.txt`, `ad1_designbox_trajectory.txt`.

Stash-rebuild checksum on the gate demo fixture (l-bracket, resolution 48, ladder
0.70/0.50/0.30, 3 × 60 design iterations), three runs:

| artifact | PRE run 1 | PRE run 2 | POST (option off) |
| --- | --- | --- | --- |
| `report.json` | `acc80a08…` | `acc80a08…` | `acc80a08…` |
| `fields.bin` | `a5841ecf…` | `a5841ecf…` | `a5841ecf…` |
| `variant_070.stl` | `88bf4e62…` | `88bf4e62…` | `88bf4e62…` |
| `variant_050.stl` | `c021eba3…` | `c021eba3…` | `c021eba3…` |
| `variant_030.stl` | `cd935817…` | `cd935817…` | `cd935817…` |
| `build_orientation.json` | `7b9076ce…` | `3db79143…` | `008375d8…` |

`build_orientation.json` differs on **every** pair including PRE-vs-PRE, on the
same binary. Its whole delta is a wall-clock field (`sweep_seconds`,
`strut_axis_measure_seconds`). Every deterministic artifact is bit-identical.

The unit test pins something stronger than "empty is inert": a schedule that is
**CONSTANT at `params.penalty`** produces a bit-identical design, compliance and
iteration count on both overloads. So the substitution machinery itself
introduces no arithmetic, and any design motion under a real schedule is the
different `p` and nothing else.

**Second witness — the path this task is actually about.** The demo fixture is a
healthy no-design-box run whose multigrid carries every solve, so it does not
exercise the stagnating, matrix-free, design-box path at all. That path was
checked separately (`ad1_designbox_trajectory.txt`, job in `designbox_job.json`):
the l-bracket at resolution 24 in a 9.24× design box, run to its end on both
binaries. Every deterministic column of `iterations.csv`, row by row:

> **64 rows × 17 deterministic columns = 1088 values compared. 0 differing.**

Same 64 rows, same four stagnating iterations (rung 0, iterations 3/5/6/7, with
`mg_cycles_attempted` 300 on each), same terminal `recommend_settings:
worst_case_stress_margin must be finite and >= 0` refusal — which is a
PRE-EXISTING abort on that job, present identically on the stashed pre-change
binary, and untouched by this task.

---

## 3. AD2 — DOES IT RESCUE THE STAGNATION? Yes, completely.

**Expected, stated before the numbers** (it is in the probe's own banner): with
`p` ramped from 1 the early high-contrast solves are softer, so the V-cycle
should carry more early iterations → fewer stagnating iterations, and less wall
if the CG saved exceeds the ramp's cost.

**The fixture.** `make_big_stagnation()` from `draft_arming_gate.cpp`,
reproduced verbatim: a 24×6×24 mm L-bracket at 1.0 mm spacing in a design box
padded 0.35 × the canonical amount, ladder 0.68/0.52/0.38, `margin_stop 1.5`,
20-iteration rung budget, the armed production option stack. A *stagnating*
iteration is one where a multigrid hierarchy **built** and the V-cycle **did not
carry** — read directly off `cg_used_multigrid` / `cg_hier_built`, not inferred.

**The baseline signature, and it is the one the task described:**

| rung | stagnating iterations |
| --- | --- |
| 0 (vf 0.68) | it 3 (cg 858), it 4 (cg 2091), it 6 (cg 1212) |
| 1 (vf 0.52) | it 3 (cg 2117), it 4 (cg 1341), it 6 (cg 1535) |
| 2 (vf 0.38) | it 3 (cg 1769), it 4 (cg 936), it 6 (cg 1037) |

Three stagnations per rung, always at iterations 3/4/6, always at `p = 3` and
`β = 0`, and **never again** — every other iteration of the run costs 26–296 CG.
That is the "stagnated on iterations 1, 3 and 5 and then never again" pattern,
reproduced on a fixture anyone can re-run.

**With continuation:**

| posture | stagnating iters (2 rungs) |
| --- | ---: |
| S0 OFF | 6 (3 per rung) |
| S1 Peetz literal | **0** |
| S2 Peetz values, 1 it/value | 3 |
| S3 Amir–Sigmund, 1 it/value | 2 |
| S4 stagnation-window | **0** |

S2 and S3 do not eliminate it, they **move** it. Their surviving stagnations are
at iteration 6 (`p` already 2.25 under a 1-iteration dwell) and, for S2, again at
iteration 10 (`p` = 3.25 — past the shipped exponent). A dwell short enough to
fit 9–13 stages into a 20-iteration rung sharpens the law faster than the design
forms, so the ramp arrives at high contrast while the design is still thrashing —
which is the exact failure it was meant to avoid, just two iterations later.

S4's 2-iteration dwell keeps `p ≤ 2.5` through iteration 8, which covers the
whole measured stagnation window (3–6) with margin, and it stagnates **zero**
times. That is why the schedule was built that way: the window was measured
first, then the dwell was chosen to cover it.

**AD2 verdict: continuation genuinely rescues the stagnation.** Reported plainly
because it is the one part of the hypothesis that survived.

---

## 4. AD3 — ITERATIONS AND WALL, BOTH, SEPARATELY

Iteration counts are **unchanged by construction**: the penalty is a pure
function of the iteration counter and never adds or removes a step. Every rung in
every posture ran its full 40 design iterations (20 grayscale + 20 projection).
So the whole cost story is CG work and wall.

**Trajectory CG per rung** — same rung, same 40 iterations, directly comparable:

| posture | rung 0 | rung 1 |
| --- | --- | --- |
| S0 OFF | 6368 | 7094 |
| S1 Peetz literal | 1745 (**3.65×** fewer) | 1963 (**3.61×**) |
| S2 Peetz values 1 it/val | 3861 (1.65×) | 3730 (1.90×) |
| S3 Amir–Sigmund 1 it/val | 3068 (2.08×) | 3350 (2.12×) |
| S4 stagnation-window | 2559 (**2.49×**) | 3476 (2.04×) |

**Wall.** The first run is NOT a fair wall comparison and its totals are not
cited: the baseline evaluated **three** rungs while every schedule stopped at
two. So the whole set was re-run on a **matched two-rung ladder**
(`probe_matched_ladder.txt`), one serialized process, nothing else on the
machine:

| posture | wall (2 rungs) | vs OFF | traj. CG | stagnating |
| --- | ---: | ---: | ---: | ---: |
| S0 OFF | **454.3 s** | — | 13462 | 6 |
| S1 Peetz literal | 120.9 s | **3.76× faster** | 3708 | 0 |
| S2 Peetz values 1 it/val | 241.4 s | 1.88× | 7591 | 3 |
| S3 Amir–Sigmund 1 it/val | 158.4 s | 2.87× | 6418 | 2 |
| S4 stagnation-window | **100.5 s** | **4.52× faster** | 6035 | 0 |

**No posture raises wall.** Iterations are unchanged, CG falls, wall falls — the
three columns agree, so there is no cycle-reduction-that-costs-wall trap here.

**The two columns are NOT proportional, and that is worth stating rather than
glossing.** S1 runs 3708 trajectory CG in 120.9 s; S4 runs **63 % more** CG (6035)
in **17 % less** wall (100.5 s). The trajectory CG column is what `on_iteration`
can see; the wall is the whole `minimize_plastic` call, which also carries each
rung's certification solve and V3 suite. Those are not instrumented here, so I
cannot attribute the gap — only report that it exists and that neither column can
stand in for the other. (The per-phase-timing handoff made the same point from
the other side: on this path an iteration count is not a cost.)

What the two columns DO agree on is direction: every posture is cheaper than the
baseline on both, so AD3's loss condition — a cycle reduction that raises wall —
does not occur anywhere in this set.

---

## 5. AD4 — THE DESIGN CHANGES, AND IT CHANGES FOR THE WORSE

Byte-identity is impossible with a schedule on and is **not claimed**.

### The gate table, every evaluated rung

| posture | rung | vf | verdict | margin | margin_eff | compliance | achieved vf | min-feature | components | reason |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **S0 OFF** | 0 | 0.68 | ACCEPT | 3.5957 | 3.5957 | 8.0408 | 0.5939 | 60 | 1 | |
| | 1 | 0.52 | ACCEPT | 2.1617 | 2.1617 | 14.551 | 0.3876 | 80 | 1 | |
| | 2 | 0.38 | REJECT | 1.1139 | 1.1139 | 31.670 | 0.2526 | 80 | 1 | margin below required |
| **S1 Peetz literal** | 0 | 0.68 | **REJECT** | 1.9826 | 1.9826 | 188.41 | 0.2407 | 46 | 1 | load path not connected |
| | 1 | 0.52 | **REJECT** | 1.2601 | 1.2601 | 1257.1 | 0.0886 | 56 | 1 | load path not connected |
| **S2 Peetz values 1 it/val** | 0 | 0.68 | ACCEPT | 3.2407 | 3.2407 | 8.1329 | 0.5833 | 52 | 1 | |
| | 1 | 0.52 | **REJECT** | 0.8760 | 0.8760 | 51.343 | 0.1085 | 64 | 1 | load path not connected |
| **S3 Amir–Sigmund 1 it/val** | 0 | 0.68 | ACCEPT | 3.7372 | 3.7372 | 8.2733 | 0.5820 | 50 | 1 | |
| | 1 | 0.52 | **REJECT** | 1.2769 | 1.2769 | 55.531 | 0.1310 | 58 | 1 | load path not connected |
| **S4 stagnation-window** | 0 | 0.68 | ACCEPT | 4.1109 | 4.1109 | 7.5686 | 0.5952 | 72 | 1 | |
| | 1 | 0.52 | **REJECT** | 1.4282 | 1.4282 | 35.971 | 0.1812 | 74 | 1 | load path not connected |

### The BLOCKED-STOP

```
FLIP  rung 0 (vf 0.68): ACCEPT -> REJECT   [S1 Peetz literal]
FLIP  rung 1 (vf 0.52): ACCEPT -> REJECT   [S1 Peetz literal]
FLIP  rung 1 (vf 0.52): ACCEPT -> REJECT   [S2 Peetz values 1 it/val]
FLIP  rung 1 (vf 0.52): ACCEPT -> REJECT   [S3 Amir-Sigmund 1 it/val]
FLIP  rung 1 (vf 0.52): ACCEPT -> REJECT   [S4 stagnation-window]
RUNG COUNT: OFF 3 -> 2 for every schedule
```

**Four schedules, four BLOCKED-STOPs.** The rejection is always the same one and
it is not a strength verdict: `load path not connected` — the connectivity belt.
The achieved volume fraction at rung 1 collapses from 0.388 to 0.089–0.181. The
design is not weaker; it is in pieces.

### The literal published schedules do not fit this project at all

`penalty_continuation_peetz()` holds each value for **20 iterations** and needs
**260** to finish. A production rung here runs 20. So the literal schedule never
leaves its first stage: **the entire rung optimizes at `p = 1.0`** and is then
certified at `p = 3`. That is why S1 has zero stagnation (it never applies real
contrast) and why it is also the worst design by an order of magnitude
(compliance 188 and 1257 against 8.04 and 14.55). This is pinned in the unit test
so nobody re-derives it: `penalty_at_iteration(peetz, 16) == 1.0`.

Both papers run at contrast `Emax/Emin ≈ 1e6`; this project runs `≈ 1e9`, and both
budget 200–260 iterations against this project's 20. Neither schedule transfers
as published.

---

## 6. AD5 — IS THE DESIGN BETTER OR WORSE? Worse.

The literature's claim is that continuation improves the optimum by avoiding
early local minima. Measured here, at the **certified** compliance (always solved
at `p = 3`, so the comparison is like for like):

| posture | rung 0 | | rung 1 | |
| --- | ---: | --- | ---: | --- |
| S0 OFF | 8.0408 | — | 14.551 | — |
| S1 Peetz literal | 188.41 | +2243 % | 1257.1 | +8539 % |
| S2 Peetz values 1 it/val | 8.1329 | +1.15 % | 51.343 | +253 % |
| S3 Amir–Sigmund 1 it/val | 8.2733 | +2.89 % | 55.531 | +282 % |
| S4 stagnation-window | **7.5686** | **−5.87 %** | 35.971 | +147 % |

**One number in this table supports the literature and the rest refute it.** S4's
rung 0 is 5.9 % stiffer than the baseline at a slightly *higher* achieved volume
fraction and a *higher* margin (4.111 vs 3.596) — a genuinely better design, and
the only evidence here that the local-minimum argument has anything in it.

Every rung-1 result is catastrophic. There is no speed-for-compliance trade to
put to the maintainer: it is speed for a **disconnected structure**.

---

## 7. AD6 — INTERACTION WITH β-CONTINUATION, MEASURED

The two continuations **overlap completely**, and the reason is a property of the
implementation that the measurement made visible.

The handoff-123 conditional gate runs each rung as **TWO `simp_optimize` calls** —
a grayscale phase, then a β-projection phase seeded from it. `penalty_continuation`
is scoped **per call**, so it **REPLAYS from stage 1** in the projection phase.
S4, rung 0, straight from the trace:

```
p:    1.0 1.0 1.5 1.5 2.0 2.0 2.5 2.5 3.0 3.0 3.0 … 3.0 | 1.0 1.0 1.5 1.5 2.0 2.0 2.5 2.5 3.0 3.0 … 3.0
beta: 0   0   0   0   0   0   0   0   0   0   0   … 0   | 1   1   1   1   1   1   1   1   1   1   … 2
                                                        ^ the projection call starts here
```

The overlap counter says the same thing arithmetically — for every schedule, the
number of ramping iterations with β off **equals** the number with β on
(S1 40/40, S2 24/24, S3 16/16, S4 16/16). It is 100 %, by construction.

**When each is active.** In the baseline the grayscale phase (iterations 1–20) runs
`β = 0` and the projection phase (21–40) runs `β = 1`, doubling to `β = 2` at
iteration 33. **Every baseline stagnation is in the `β = 0` window** (all nine of the
three-rung run; all six of the matched two-rung run) — so
β-continuation is *not* what protects those iterations, and it is not competing
with p-continuation for the problem. It is competing for the *design*.

**That makes the replay the leading suspect for the verdict flips.** The projection phase
exists to *sharpen* a formed design. Replaying the p-ramp there re-softens it —
drops `p` back to 1.0 for two iterations, exactly while β starts thresholding —
so the structure is being pulled toward gray and pushed toward black/white at the
same moment. The connectivity failures are concentrated in rung 1, the rung that
inherits a warm start from an already-perturbed rung 0.

This is a hypothesis with a named mechanism and a measured signature, not a
certainty — and the experiment I ran to test it **did not work**. §7a.

### 7a. The isolation experiment FAILED to isolate. Reported as such.

`probe_replay_isolation.txt`. The conditional projection gate can be disarmed
from the probe (`conditional_mma_projection_mnd_threshold = 0`), which makes each
rung ONE `simp_optimize` call, so the schedule runs exactly once and the replay
is removed as a variable. That was the design.

**It produced no usable comparison, because the BASELINE also fails there.** With
the projection phase gone, every rung of every posture — including S0 — comes
back `load path not connected` at achieved vf 0.0476, which is the frozen
Load/Fixture skin and nothing else. Twenty grayscale iterations without the
projection phase simply do not form a design on this fixture. The verdict-flip
count is 0 for all four schedules, and that means nothing: everything already
failed.

So the replay hypothesis in §7 is **UNTESTED**, not supported. I am not going to
present a 0-flip line from a run whose control is broken as evidence for it.

The run is not worthless — it confirms one thing cleanly. The stagnation counts
are **identical** to the projection-on run (S0: 3 per rung; S2: 2 and 1; S3: 1 and
1; S4 and S1: 0), which independently confirms §7's other finding: **all the
stagnation lives in the grayscale (β = 0) phase**, and the projection phase
contributes none of it.

---

## 8. AD7 — DETERMINISM AND CTEST

**Determinism, in each posture** (`determinism.txt`). The whole set was run twice
in separate process invocations (run 1 on ladder 0.68/0.52/0.38, run 2 on
0.68/0.52 — rungs 0 and 1 are the same computation in both). Compared across the
OFF baseline and all four schedules: **10 rung records × 13 deterministic fields
= 130 values, 0 differing.** Verdict, margin, `margin_effective`, certified
compliance, achieved volume fraction, iteration count, stagnating-iteration
count, latched count, summed CG, min-feature violations, mesh components and
rejection reason all reproduce to the last recorded digit. Wall seconds are the
only field allowed to move, and are excluded.

The pure schedule map is deterministic by construction and the unit test pins it
(`penalty_at_iteration` twice on the same input is bit-identical).

**CTest** (`ctest.txt`). Full suite after the change:

> **100 % tests passed, 94 of 94.** Total test time 1681.52 s.

Test 73 is the new `penalty_continuation` target (7.01 s, 67 internal checks);
the other 93 are the pre-existing suite and all still pass. No assertion was
weakened, deleted or skipped, and the gate was not changed.

---

## 9. What would have to change to test the fix — REPORTED, NOT MADE

The task says: *if a change to `minimize_plastic.cpp` is unavoidable, report it
rather than making it.* Here is the report.

**The change.** Scope the schedule **per RUNG** instead of per `simp_optimize`
call. `simp_optimize` cannot do this alone: it does not know it is the second
phase of a rung. `minimize_plastic.cpp` already carries the exact quantity
needed — `rung_iter_base`, the grayscale phase's iteration count, which it raises
before the projection phase specifically so the forwarded `iter` numbers stay
monotone within a rung. The change is to forward that same base into
`SimpOptions` (a new `penalty_continuation_iteration_base`, default 0 = today's
per-call behaviour) and add it to the counter in `penalty_for_iteration`. Roughly
five lines in `minimize_plastic.cpp` and two in `simp.cpp`.

**Why I did not make it.** `minimize_plastic.cpp` is owned by
`warm-start-coarse-experiment` this cycle.

**What it would probably NOT fix.** The rung-1 collapse also survives in S2/S3,
whose ramp is over by iteration 9 or 13 — most of both phases already runs at the
terminal `p`. So the replay is a suspect, not a diagnosis; the warm start
carrying a perturbed rung-0 design into a tighter rung is the other half. Any
follow-up should measure both, and should **not** repeat §7a's mistake: the
control must be a configuration in which the baseline still produces a connected,
accepted design.

---

## 10. What the doc would need to say if this were ever armed

`ARCHITECTURE.md:75` is the Optimizer row, and it currently reads:

> | Optimizer | SIMP, penalty p=3, density filter (radius ≥ 1.5 voxels),
> Optimality Criteria updater | Standard Sigmund 99-line formulation, extended to
> 3D + anisotropy. |

**It was not edited and does not need to be: nothing is armed.** If a future task
did arm a schedule, the accurate replacement would be:

> SIMP with a **penalization-continuation schedule** (`p` ramped from `p₀` to the
> terminal `p` across the first N design iterations of each rung, held there
> after), density filter, Optimality Criteria / MMA updater. The **certified**
> compliance is always solved at the terminal `p = 3`; the schedule governs the
> optimization trajectory only. Departs from the standard Sigmund 99-line
> formulation, which fixes `p = 3` throughout.

The last sentence is the load-bearing one: the current text's claim to be the
standard 99-line formulation would stop being true.

---

## 11. RECOMMENDATION

**Recommend AGAINST arming any of the four schedules. Keep the default OFF.**

* **S1 (Peetz, literal)** — REFUSE. Does not fit a 20-iteration rung at all; pins
  `p = 1` for the whole run, flips two verdicts, and is 23–86× worse in
  compliance. It is the published schedule and it is unusable here.
* **S2 (Peetz values, 1 it/value)** — REFUSE. Flips a verdict, only 1.65–1.90× CG,
  still stagnates, and its terminal `p = 4.0` is a trajectory/certificate
  mismatch on top.
* **S3 (Amir–Sigmund 1→3, 1 it/value)** — REFUSE. Flips a verdict.
* **S4 (stagnation-window 1→3, 2 it/value)** — the best of the four, and still
  REFUSE. It is the only one with a genuinely better design anywhere
  (rung 0: −5.87 % compliance, +14 % margin, zero stagnation, 2.49× less CG) and
  the only one whose ramp actually covers the measured stagnation window. But it
  flips rung 1, and a verdict flip is a BLOCKED-STOP.

**If anyone picks this up again**, S4's shape is the one worth pursuing —
`penalty_continuation_ramp(1.0, 3.0, 0.5, 2)`, terminal `p` equal to
`params.penalty` so trajectory and certificate agree — and the first thing to try
is the per-rung scoping in §9. The feature stays in the tree, off, so that
experiment costs a schedule assignment rather than a re-implementation.

**Do not arm it on the strength of the CG numbers alone.** That is the error
`docs/handoffs/2026-08-02-iteration-phase-timing.md` found in the GenEO arming:
armed on a deterministic iteration-count measurement, on a path where iteration
count is not cost. Here the temptation is stronger, because the CG reduction is
honest work genuinely removed — and it still is not the deciding number. The
deciding number is a gate verdict, which no CG count can see.

---

## 12. In plain language

SIMP works by making half-solid material *disproportionately* useless, so the
optimizer is pushed to choose solid or empty and stop hedging. The dial for that
is `p`. At `p = 3` a voxel that is 10 % dense is 1000× floppier than solid; at
`p = 1` it is only 10× floppier.

Today the code turns that dial straight to 3 on the very first step — when the
design is still a uniform gray fog and there is no structure at all. The worry
was that this is the worst possible moment: the stiffness numbers span a billion
to one, and the fast solver (multigrid) chokes on that. It does. We measured it:
on iterations 3, 4 and 6 of every rung the fast solver gives up and falls back to
a slow one, costing up to 40× more work on those steps.

Turning the dial up gradually instead fixes that completely. Start at `p = 1`,
walk up to 3 over the first eight or ten steps, and the fast solver never chokes.
The linear-algebra work drops by a factor of two to three. That part of the idea
is simply correct, and the literature is right about it.

But the design that comes out is broken. Under a soft `p` the optimizer is happy
to spread material thin and gray, because thin material is not being punished
yet. By the time `p` climbs back to 3 there are not enough steps left to gather
that fog into a solid load path. On the second rung of the ladder — where the
part is already being made lighter — the structure comes out **in pieces**. The
gate catches it, correctly, and rejects it. That happened with all four schedules
we tried, including the two straight out of the papers.

There is one bright spot. On the *first* rung, the schedule we designed ourselves
produced a design that is genuinely better than what ships today: 6 % stiffer,
14 % more safety margin, at essentially the same weight, in a third of the solver
work. So
the idea is not empty. It just needs the second half of the run to be protected.
We have a suspect for why it currently is not: the part of the run that is
supposed to *sharpen* the design restarts the softening ramp from the beginning,
so the two pull in opposite directions at the same moment. We tried to test that
suspicion and the test did not work — switching the sharpening phase off broke
the ordinary run too, so there was nothing left to compare against. It stays a
suspicion, written down honestly, and checking it properly means touching a file
another task owns this cycle.

Bottom line: **nothing changed for anyone using the tool.** The new dial exists,
it is switched off, and the code with it switched off produces byte-for-byte the
same results as before — that was checked with checksums. The recommendation is
to leave it off until the second-rung breakage is understood.
