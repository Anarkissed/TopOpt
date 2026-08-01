# Does `warm_start_coarse` rescue the startup transient?

**Task:** `warm-start-coarse-experiment` · **Evidence:**
`evidence/2026-08-02-warm-start-coarse-experiment/`
**Kind:** EXPERIMENT. Measures a built-but-unreachable option, adds the plumbing
and instrumentation needed to measure it, and changes NO default. The gate is
untouched. No assertion was weakened or deleted.

*(Sections marked MEASURED carry numbers; the recommendation is at the end.)*

---

## 0. Why the option is off — the question the task asked first

**Both answers are true, and the second one is the load-bearing one:**

**(a) It was measured — on fixtures too small to be relevant, and the result was
marginal-to-negative.** Handoff 110 §Headline measured Part B alone (`warmB`) on
two fixtures of **≤ 1024 solid voxels**:

| fixture | cold iters | warmB iters | verdict 110 recorded |
| --- | ---: | ---: | --- |
| L-bracket loadcase (8×3×8) | 326 | 276 fine + 29 coarse = **305** | −6 % |
| self-weight block (16×8×8) | 460 | 438 fine + 59 coarse = **497** | **+8 % — a LOSS** |

110's own words: *"warmB alone is marginal, and on self-weight it raised the raw
iteration count… as an iteration count it is a wash-to-loss."*

**(b) It was NEVER ARMED, and could not be.** This is the fact that decides the
task. `MinimizePlasticOptions::warm_start_coarse` has **no writer anywhere in the
shipping tree**:

- `git log -S "warm_start_coarse = true" -- core/` returns exactly ONE commit —
  `b781531`, handoff 110's own commit, in its own tests.
- `core/src/cli/run_job.cpp` only ever *echoed* it (`info.warm_start_coarse =
  options.warm_start_coarse`, line 188) — it read a value nothing could set.
- `app/` contains no reference to it at all.
- By contrast Part A (`warm_start_inherit`) IS armed in production, at
  [`loadcase.cpp:275`](core/src/cli/loadcase.cpp:275) — `opts.warm_start_inherit =
  !external.empty()`, handoff 113's measured decision: **load-case runs warm,
  self-weight runs cold.**

So the task's premise that "`run_job.cpp:185` plumbs it" is **not correct**:
run_job *reported* it and never *set* it. The lever has been dark since it was
built. Handoff 110 said so and named the exact gap this task is meant to close:

> *"Part B on the design-box path is structurally supported but NOT measured…
> Both fixtures here are no-box load-case / self-weight runs. Measure a box run
> before relying on warmB there."*
> *"These numbers are a floor, not a ceiling, for production grids — but that too
> is unmeasured here."*

### Does 110's rejection still hold after PR 273?

**No — and the task is right to force the question.** 110 priced Part B in
ITERATIONS. On its fixtures multigrid was healthy, every iteration cost about the
same, and iterations ≈ cost, so that was a fair price. PR 273
(`2026-08-02-iteration-phase-timing`) proved that equivalence **fails exactly in
the regime this task targets**: on a stagnating iteration **87.9 % of the wall is
GenEO overhead the iteration counter cannot see**, and 3 of 65 iterations carried
80 % of a rung. A lever that removes 3 expensive iterations out of 65 scores
−4.6 % in 110's currency and −80 % in the maintainer's.

**So 110's number does not refute this task, and this task re-measures in wall
and in operator applies, not in iterations.** That is the whole reason the
experiment is worth running — and it is why §4's measurement reports both.

---

## 1. The structural finding, before any timing — `warm_start_coarse` can only
   ever rescue RUNG 0

Read at [`minimize_plastic.cpp:1104`](core/src/simp/minimize_plastic.cpp:1104):

```cpp
warm_seed = options.warm_start_inherit ? rho : std::vector<double>();
```

The cascade fills `warm_seed` once, before the ladder. After rung 0 converges,
that line either replaces it with rung 0's design (inherit ON) or **clears it**
(inherit OFF). With inherit off — which is what production does on a self-weight
run, by handoff 113's deliberate decision — **every rung ≥ 1 starts from uniform
grey in both postures.**

Two consequences the maintainer needs before reading any table:

1. **The comparison is a rung-0 comparison.** Rungs ≥ 1 should reproduce cold to
   the byte. §5 tests that rather than assuming it. (Edge case, named for
   honesty: if rung 0 ends INFEASIBLE or non-convergent, the branches at
   `minimize_plastic.cpp:1006`/`:1067` leave `warm_seed` untouched, so the coarse
   seed would carry into rung 1. That path is not exercised by these fixtures.)

   > **⚠ READ §4's "An exception to §1's structural claim" BEFORE relying on
   > this.** The reasoning above is sound about the DESIGN SEED and it held
   > exactly on two of three fixtures — but it was **falsified on the third**.
   > The seed is not the only channel between rungs: the GenEO basis and the
   > recycled Krylov subspace are process-global and persist across rungs, so in
   > the armed, stagnating regime a changed rung 0 moves later rungs anyway. The
   > code-reading was right and incomplete, which is exactly why the measurement
   > was run.
2. **If the transient is per-rung, this lever addresses 1 rung of N.** The
   maintainer's run spent 57.7 of 72.2 minutes in the transient **of one rung**.
   A 4-rung ladder that restarts from grey each time pays that transient four
   times, and the cascade can only pay down the first. The lever sized against
   the whole problem is Part A (inherit), which is already armed for load-case
   runs and deliberately off for self-weight. **This is the single most important
   thing this task learned, and it is a property of the code, not of a
   measurement.**

---

## 2. What was built (measurement and reachability only — no default moved)

| change | why |
| --- | --- |
| `job.hpp` / `job.cpp` — optional **`"warm_start": { "coarse": bool }`** block | The option had no writer, so it could not be measured on the production path at all. Absent block => `has_warm_start` false => driver keeps its OFF default => byte-identical. Not a default change: a per-run arming switch. |
| `run_job.cpp` — maps the block onto `options.warm_start_coarse` | One line, guarded by `has_warm_start`, alongside the identical `draft` mapping. Explicitly does NOT touch `warm_start_inherit`, which keeps handoff 113's rule. |
| `pipeline.hpp` / `minimize_plastic.cpp` — **`warm_start_coarse_ms`** | AC3. The result carried the pre-solve's ITERATIONS but not its WALL, so its own cost could not be charged. Timed on the same steady clock as PR 273's phase instrument, spanning coarsen + solve + prolong, so no part of the price sits outside the span. |
| `pipeline.hpp` / `minimize_plastic.cpp` — **`warm_start_coarse_matvecs`** | The pre-solve's cost in the one unit a **contended host cannot change**. PR 273 named `matvecs` the honest work unit when `cg_iters` is not; it is also deterministic, which mattered enormously here (§3). |
| `observability.hpp` / `observability.cpp` / `run_job.cpp` — all three echoed into `run_info.json` | Config already said the posture was armed; nothing said what it charged. Filled post-run with the same finalize-only discipline as `cg_multigrid`. |
| `core/tests/unit/test_job.cpp` — `test_warm_start_block()` | Schema coverage for the new block: absent => off, armed, explicitly-off, and four rejections (non-boolean, missing key, unknown key, non-object). |
| `core/tests/harness/warm_start_coarse_gate.cpp` | The measurement harness. Standalone, not in CTest, a sibling of `ad_disarm_gate.cpp` whose fixtures, 1e-9 negative-control discipline and comparison quantities it reuses verbatim so the two tables read side by side. |

Nothing in `core/tests/fixtures/`, `materials.json`, `ARCHITECTURE.md` or
`DECISIONS.md` was touched. The gate is untouched. `geneo.cpp` and
`multigrid.cpp` — owned by the two coordinating tasks — were not edited.

---

## 3. MEASUREMENT CONDITIONS — no clean wall ratio was obtainable, and here is
   the proof

**Say it plainly: this host was shared with other agents' benchmark runs for the
entire measurement window, and NO WALL RATIO IN THIS HANDOFF IS CITED AS
EVIDENCE.** That is PR 273's own discipline, applied to the same condition:

> *"several campaign runs shared the host, so NO wall ratio is cited as evidence
> — the deterministic CG counts are the signal"*
> — `docs/handoffs/2026-07-29-geneo-arming.md`, §Machine

Recorded in `evidence/…/host_load.txt`: 1-minute load average ranged from **30 to
258** across the window, with **9–19 concurrent `topopt-cli` processes** belonging
to other tasks. The harness process was observed taking anywhere from **9.7 % to
185 % CPU** depending on what else was running.

**The direct demonstration** (`evidence/…/wall_noise_demo.txt`): two runs of the
**identical** OFF posture on the identical fixture, back to back, same binary,
deterministic solver —

| run | iterations | wall |
| --- | ---: | ---: |
| `off#1` | 394 | **1255.7 s** |
| `off#2` | 394 | **1034.9 s** |

**Identical work. 17.6 % apart in wall.** Any warm-vs-cold wall difference
smaller than that is indistinguishable from which neighbours happened to be
running. This is why the primary cost unit below is not wall.

### The primary cost unit: DOF-TOUCHES

Iterations are not cost (PR 273: 87.9 % of a stagnating iteration is GenEO
overhead the iteration counter cannot see). Wall is not measurable here. So the
evidence is carried by **operator applies weighted by the DOF count of the grid
each apply ran on**:

```
dof_touches = sum over applies of 3*(nx+1)*(ny+1)*(nz+1)   [grid_nodal_dofs()]
```

**Raw applies would NOT do**, and this is the one accounting subtlety the whole
experiment turns on: the cascade's entire premise is that it works at res/2,
where one apply touches ~1/8 the DOFs of a fine one. Summing a coarse apply and
a fine apply as if they cost the same is an error of kind, not of degree — and it
runs **against** the cascade, since it charges every cheap coarse apply at full
fine price. Weighting removes that bias, so a DOF-weighted result showing no win
is the *robust* direction of the conclusion, not the flattering one.

The unit is deterministic and contention-immune: the same numbers come back on a
loaded host and a quiet one, and on another machine. Both denominators
(`warm_start_coarse_grid_dofs`, `solved_grid_dofs`) and the raw applies are
reported too, so the weighting can be re-derived rather than trusted, and the
measured coarse/fine ratio is printed rather than assumed to be 8.

**OPEN ITEM, named rather than buried: the quiet-host wall pass.** Everything
below is DOF-weighted. A follow-up should re-run `warm_start_coarse_gate` on an
idle machine and confirm that wall moves in the same direction and rough
proportion. Until that exists, no wall claim from this task should be quoted.

---

## 4. MEASURED — the transient, with and without

Three fixtures, three postures each (OFF / ON / CTL), each run twice. Full
transcript: `evidence/…/harness_transcript.txt`.

### The headline, all three fixtures, in the primary unit

| fixture | regime | charged **DOF-touches** | charged iterations | charged wall *(indicative only)* |
| --- | --- | ---: | ---: | ---: |
| `stag` 48×32×48, design box | MG carried; **1** transient stagnating iteration | **−13.1 %** | +8.1 % | −25.6 % |
| `healthy` 32×24×32, design box | MG carried, no stagnation | **+2.7 %** | +17.9 % | +0.4 % |
| `nobox` 33×25×33, no design box | **MG NEVER carried**; 98–100 % of iterations stagnating; GenEO armed on 954 solves | **+7.2 %** | +13.9 % | +10.4 % |

**Negative numbers are wins.** Two of three fixtures are losses.

### THE TWO CURRENCIES DISAGREE IN SIGN, and that is the finding

On the primary fixture, charged **iterations** read **+8.1 %** — a loss, and a
near-exact reproduction of handoff 110's self-weight **+8 %**. Charged
**DOF-touches** read **−13.1 %** — a win. Same runs, same data.

110 was not wrong; it was measuring in a unit that cannot price a res/2
pre-solve. Had this task reported iterations, it would have "confirmed" 110 and
missed a real effect. **The DOF weighting is what separates them**, and the
coarse/fine ratio it corrects for is measured, not assumed: **1/7.46** on `stag`,
1/7.25 on `healthy`, 1/6.63 on `nobox`.

### The mechanism DOES work — on the fixture it was designed for

`stag`, rung 0, OFF → ON:

| | OFF | ON |
| --- | ---: | ---: |
| iterations | 128 | **58** |
| compliance settles at iteration | 43 | **9** |
| stagnating iterations | **1** (75.9 s, 18.3 % of the rung) | **0** |

The transient was **eliminated**, not merely shortened: the one stagnating
iteration is gone, and the design settles at iteration 9 instead of 43. This is
exactly the behaviour the task hypothesised, and it is why the DOF-weighted total
moves at all.

### …but the win is confined to RUNG 0, exactly as §1 predicted

On `stag` and `healthy`, **every rung ≥ 1 is bit-identical**: mean|Δρ| =
`0.000e+00`, identical iterations, identical compliance to all printed digits,
identical margin. The prediction in `e0_expected_before_measuring.md` §E6 was
that this would hold, and it does — the cascade seeds rung 0 and
`minimize_plastic.cpp:1104` clears the seed thereafter. A 3-rung ladder can
therefore capture at most one rung's worth of benefit, and the measured −13.1 %
is what that looks like.

### THE DECISIVE RESULT: it LOSES in the regime it was meant to fix

`nobox` is the only fixture here where multigrid **genuinely never carries** —
`mg=NOT-carried`, 98–100 % of iterations stagnating on every rung, GenEO armed on
954 solves. It is the closest thing in this harness to the maintainer's latched
runs and to PR 273's reproduction. There, `warm_start_coarse`:

- **increased** fine iterations 944 → 1000 (+5.9 %),
- **increased** charged DOF-touches +7.2 %,
- **increased** the number of stagnating iterations 942 → **1000**, and the wall
  inside them +9.2 %,
- and **landed on a materially worse design** — rung 2 compliance
  **52.30 → 65.88, +26.0 %** at the same volume fraction.

It made the thing it was supposed to fix **worse, on every axis at once**. A
lever whose entire rationale is "the stagnating regime" losing in the stagnating
regime is the central fact of this experiment.

### An exception to §1's structural claim, found by measurement

On `nobox`, rungs ≥ 1 are **NOT** bit-identical (rung 2's compliance moves 26 %).
That contradicts the rung-0-only property that held exactly on the other two
fixtures, so the property has a condition, and it is worth naming:

The design seed IS cleared after rung 0, the geometry and loads are identical, so
the difference cannot enter through the design. The remaining channel is
**process-global solver state that persists ACROSS rungs within one ladder** —
the GenEO basis and the recycled Krylov subspace. The run records are consistent
with this: GenEO basis builds differ (1 OFF vs **2** ON) and armed solves differ
(954 vs 1077). *Stated as inference from the only available channel plus the
counters, not as a directly instrumented measurement* — isolating it would need a
run with the accelerators disarmed, which belongs to the GenEO-disarm task that
owns `geneo.cpp`.

**The consequence is the load-bearing part:** "this option only perturbs rung 0"
is safe to say ONLY when the solver carries no cross-rung state — which is
precisely NOT the case in the armed, stagnating regime a production run hits.

### Predictions vs outcome (`e0_expected_before_measuring.md`)

| | prediction | outcome |
| --- | --- | --- |
| E2 | pre-solve costs 15–40 % of baseline rung-0 wall | **137.2 s / 413.6 s = 33 %** ✓ |
| E3 | net wall −30 %…+20 % | −25.6 % (indicative) ✓ |
| E4 | fine iters −10…−30 %; charged flat…+15 % | **−17.8 %; +8.1 %** ✓✓ |
| E6 | rungs ≥ 1 bit-identical | ✓ on 2 fixtures; **✗ on `nobox`** — see above |
| E7 | no verdict flip; rung-0 margin moves a few % | ✓ 0 flips; **3.2116 → 2.9990, −6.6 %** |
| E8 | healthy control a loss of +3…+15 % | **+2.7 %** — a loss, marginally milder ✓ |
| E1 | the pre-solve itself stagnates | **not resolved** — the pre-solve is deliberately unobserved (`opt_c.observe = nullptr`), so its per-iteration regime was not measured. Named, not glossed. |

### What this reproduction is NOT

`stag`'s transient is **one** stagnating iteration at 18.3 % of a rung. The
maintainer's run was **3 of 65** iterations at **80 %** of the rung. This is a
milder transient, and the asymmetry cuts a specific way: a milder transient
leaves **less** headroom to recover, so a win here would likely be larger there
— **a null or negative result here does not prove one there.** The harsher
regime is represented by `nobox` (98–100 % stagnating), and that is where the
option lost outright. PR 273's own `ladder32` reproduction cannot be used for a
gate table at all: it dies on a pre-existing non-finite-margin abort before
finishing its ladder.

---

## 5. MEASURED — the gate table and the negative-control floor

### AC4 — FULL GATE TABLE, EVERY RUNG, BOTH POSTURES

**ZERO verdict flips across all three fixtures and all ten rungs. No
BLOCKED-STOP.**

| fixture | rung | vf | verdict OFF → ON | margin OFF | margin ON | Δmargin |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| `stag` | 0 | 0.68 | ACCEPT → ACCEPT | 3.21160 | 2.99899 | −6.6 % |
| `stag` | 1 | 0.52 | ACCEPT → ACCEPT | 1.96358 | 1.96358 | **0 (bit-identical)** |
| `stag` | 2 | 0.38 | REJECT → REJECT | 1.11094 | 1.11094 | **0 (bit-identical)** |
| `healthy` | 0 | 0.68 | ACCEPT → ACCEPT | 2.72741 | 2.64793 | −2.9 % |
| `healthy` | 1 | 0.52 | ACCEPT → ACCEPT | 1.63291 | 1.63291 | **0 (bit-identical)** |
| `healthy` | 2 | 0.38 | REJECT → REJECT | 0.823352 | 0.823352 | **0 (bit-identical)** |
| `nobox` | 0 | 0.68 | ACCEPT → ACCEPT | 7.41745 | 7.29935 | −1.6 % |
| `nobox` | 1 | 0.52 | ACCEPT → ACCEPT | 5.49954 | 5.55193 | +1.0 % |
| `nobox` | 2 | 0.38 | ACCEPT → ACCEPT | 4.78401 | 4.05822 | **−15.2 %** |
| `nobox` | 3 | 0.26 | ACCEPT → ACCEPT | 2.97625 | 2.88541 | −3.1 % |

The table includes REJECTed rungs (`stag`/`healthy` rung 2), so the flip check is
exercised in both directions and is not a vacuous all-ACCEPT pass. **Every margin
move is downward except one**, and `nobox` rung 2 loses 15.2 % of its margin
while still clearing `margin_stop = 1.5`.

### AC4 — design differences against the 1e-9 NEGATIVE-CONTROL FLOOR

The control is a physically meaningless 1e-9 relative nudge to the load vector,
far below the solver's own 1e-8 basin. Its design motion is the floor of pure
iteration-route noise on that fixture and rung.

| fixture / rung | ON mean\|Δρ\| | CTL floor mean\|Δρ\| | ratio | verdict |
| --- | ---: | ---: | ---: | --- |
| `stag` 0 | 6.468e−03 | 1.687e−06 | **×3834** | REAL |
| `stag` 1 | **0.000e+00** | 3.322e−06 | ×0 | below floor (bit-identical) |
| `stag` 2 | **0.000e+00** | 1.768e−08 | ×0 | below floor (bit-identical) |
| `healthy` 0 | 5.865e−04 | 7.877e−12 | **×7.4e7** | REAL |
| `healthy` 1–2 | **0.000e+00** | ~1e−12 | ×0 | below floor (bit-identical) |
| `nobox` 0 | 3.808e−02 | 1.257e−03 | **×30.3** | REAL |
| `nobox` 1 | 4.906e−03 | 8.539e−03 | ×0.57 | below floor (noise) |
| `nobox` 2 | 2.379e−02 | 2.281e−03 | **×10.4** | REAL |
| `nobox` 3 | 1.600e−03 | 1.231e−03 | ×1.30 | at the floor |

Rung-0 motion is real everywhere and by a wide margin — expected, since rung 0 is
the rung the cascade seeds, and it is not a defect. The floor's job is to prove
the rungs that did NOT move really didn't, and on `stag`/`healthy` they are
*exactly* zero, which is stronger than "within the floor".

**A correction to my own instrument, stated rather than hidden.** The harness
first labelled `nobox` rungs 2–3 "AT/BELOW THE FLOOR" because its test compared
`max|Δρ|` only. In a stagnating regime both the change and the control saturate
near 1.0 — a single voxel swinging void↔solid pins the max — so a max-only test
called a rung noise whose MEAN motion is **10.4× the control**. The table above
uses the mean, and the harness has been fixed to test **both** moments and print
both ratios. The mislabelled rung is precisely the one carrying the +26 %
compliance regression, so the weak test would have hidden the most important
row.

### AC5 — CONVERGED COMPLIANCE PER RUNG, both ways

| fixture | rung | compliance OFF | compliance ON | change |
| --- | ---: | ---: | ---: | ---: |
| `stag` | 0 | 9.57926613849 | 9.76645185792 | **+1.95 %** |
| `stag` | 1 | 17.0369024164 | 17.0369024164 | 0.000 % |
| `stag` | 2 | 38.2858941914 | 38.2858941914 | 0.000 % |
| `healthy` | 0 | 4.63900268409 | 4.64099993964 | +0.04 % |
| `healthy` | 1–2 | — | — | 0.000 % |
| `nobox` | 0 | 36.6751700709 | 36.5134366411 | −0.44 % |
| `nobox` | 1 | 42.6290499212 | 42.6939713487 | +0.15 % |
| `nobox` | 2 | 52.299730612 | **65.8789674182** | **+25.96 %** |
| `nobox` | 3 | 80.9377902736 | 80.63629765 | −0.37 % |

Higher compliance is a **less stiff design at the same volume fraction**. On the
primary fixture the trade is small but real (+1.95 % on rung 0 — the rung that
got faster). On `nobox` rung 2 it is **+26 %**, and that rung's design difference
is 10.4× the control floor, so the two measurements agree that it is real rather
than noise. **A slower run that also lands on a 26 %-worse design is a loss twice
over**, and it is the same rung that lost 15.2 % of its margin.

### AC7 — DETERMINISM

**Byte-identical rerun in every posture on every fixture — 9 of 9.** Densities,
compliance, margins, iteration counts and the pre-solve's iteration count all
compared at full double precision:

```
stag    : OFF twice IDENTICAL | ON twice IDENTICAL | CTL twice IDENTICAL
healthy : OFF twice IDENTICAL | ON twice IDENTICAL | CTL twice IDENTICAL
nobox   : OFF twice IDENTICAL | ON twice IDENTICAL | CTL twice IDENTICAL
```

Independently, the pre-instrument and post-instrument binaries produce the **same
394 iterations** on `stag`/OFF (`evidence/…/wall_noise_demo.txt`), so the added
counters observe without perturbing.

### AC3 — the pre-solve's own cost, charged, never folded in

| fixture | pre-solve iterations | pre-solve DOF-touches | as % of the OFF run | pre-solve wall *(indicative)* |
| --- | ---: | ---: | ---: | ---: |
| `stag` | 102 | 1.045e+09 | **8.0 %** | 137.2 s (33 % of baseline rung 0) |
| `healthy` | 31 | 5.861e+07 | **4.3 %** | 1.9 s |
| `nobox` | 75 | 4.859e+08 | **1.4 %** | 7.2 s |

Every "charged" figure in §4 is net of these. On `stag` the pre-solve costs 8.0 %
of the baseline run to save 21.0 % of the fine grid's work — which is why the
net is −13.1 % and not −21 %.

### THE ONE RULE — measured, not argued

With the `"warm_start"` block ABSENT, the run must be byte-for-byte what it was
before this change. The structural argument is easy (absent block →
`has_warm_start` false → `options.warm_start_coarse` never assigned → the
`if (options.warm_start_coarse)` block never executes), but a structural argument
is not a measurement. `evidence/…/byte_identity.txt`, same job through a
`topopt-cli` built from the merge-base (`c7194b4`) and from this branch:

```
report.json   acc80a08…  IDENTICAL
design.bin    bed76e9c…  IDENTICAL
fields.bin    a5841ecf…  IDENTICAL
variant_030.stl / variant_050.stl / variant_070.stl   IDENTICAL
post-change run twice: all IDENTICAL           RESULT: THE ONE RULE HOLDS
```

Two files are excluded, both by name and with a reason:

- **`run_info.json`** — this task deliberately ADDS observability keys to it. Its
  bytes are *supposed* to change.
- **`build_orientation.json`** — it records its own wall timings
  (`sweep_seconds`, `strut_axis_measure_seconds`), so it differs between two runs
  of the SAME unmodified binary. **This was verified before excluding it**: the
  pre-change binary and two post-change runs differ from one another in exactly
  those two fields and nowhere else. Excluding a known-nondeterministic file is
  not the same as excusing a regression, and the distinction is worth a task of
  its own if that file is ever wanted as a byte-comparable artifact.

**A wiring bug this check caught.** The first run of it showed
`solved_grid_dofs = 0` on a completed run: the three DOF keys had been declared
on `RunInfo` and serialized, but `run_job`'s finalize never assigned them, so
they would have shipped as a permanent zero. Fixed, and the armed path now
re-derives on its own record:

```
warm_start_coarse=true  iterations=30  matvecs=17928  grid_dofs=31875
dof_touches=571455000        17928 x 31875 == 571455000   ✓
solved_grid_dofs=237699      coarse apply = 1/7.46 of a fine apply
```

That the re-derivation closes is the point of publishing both denominators: a
reader can recompute the weighting instead of trusting it.

**One scope note on the DOF-touch totals:** they cover the optimizer's trajectory
solves. The per-rung certification/stress-recovery solves sit outside the
iteration loop and are not in the per-iteration counters. Their number equals the
number of evaluated rungs, which is identical in both postures on every fixture
here (no ladder-length change, no verdict flip), so the omission cancels exactly
in every comparison above.

---

### AC8 — full CTest

**100 % tests passed out of 93** (total 1131.27 s), on the final code including
the `run_info` wiring fix. Full tail: `evidence/…/ctest.txt`. The suite includes
`cli_demo` (152.95 s), `production_parity`, `clearance_parity` and
`face_protection_parity` — the parity tests that would catch a behavioural change
leaking out of an opt-in flag. No assertion was weakened, skipped or deleted; two
tests were ADDED to `test_job` (`test_warm_start_block`, 177 checks total).

---

## 6. Recommendation — **DO NOT ARM**

**Explicitly: this is a recommendation NOT to change the production default.
`warm_start_coarse` should stay `false`.** The arming decision was always a
follow-up's to make; this evidence does not support making it, and the win is
not unambiguous by any reading.

**The four reasons, in order of weight:**

1. **It LOSES in the regime it exists to fix.** On `nobox` — the only fixture
   here where multigrid genuinely never carries — charged DOF-touches are
   **+7.2 %**, stagnating iterations rise 942 → 1000, and the wall inside them
   rises 9.2 %. The whole argument for the cascade is the stagnating regime.
2. **It landed on a materially worse design there** — `nobox` rung 2 compliance
   **+26.0 %** and margin **−15.2 %**, with a design difference 10.4× the
   negative-control floor. Slower *and* worse.
3. **Both honest controls are losses** (`healthy` +2.7 %, `nobox` +7.2 %). The
   single win (`stag` −13.1 %) is one fixture out of three. Per AC6 these are
   reported as a trade, **not averaged** — averaging them would manufacture a
   number describing no real run.
4. **The win it does produce is structurally capped at rung 0** (§1,
   `minimize_plastic.cpp:1104`), so it cannot address a per-rung transient no
   matter how well it works on rung 0.

**What IS worth taking from this.** The mechanism is real and it works: on
`stag`, rung 0 went 128 → 58 iterations, the transient went 1 → 0 stagnating
iterations, and compliance settled at iteration 9 instead of 43. The idea is
sound; the *delivery vehicle* is wrong, because it reaches exactly one rung.

**The lever that actually matches the maintainer's problem is `warm_start_inherit`
(Part A), not Part B.** The maintainer's 57.7-of-72.2 minutes was the transient
**of one rung**; a ladder that restarts from uniform grey pays it on every rung.
Part A is the one that warms rungs 1…N, it is already armed for load-case runs
([`loadcase.cpp:275`](core/src/cli/loadcase.cpp:275)), and it is deliberately OFF
for self-weight by handoff 113's measured decision (|Δρ| = 0.284, a materially
different optimum). Handoff 110 said Part B's "real value is compounding with A",
and this task measured Part B alone because that is the posture a Part-B-only
flip would actually ship. **Re-opening the self-weight Part-A decision, with
today's gate table and negative-control discipline, is the follow-up with the
larger prize.**

### Open items, named rather than buried

1. **The quiet-host wall pass.** All conclusions above are DOF-weighted. Wall on
   this host is unusable (§3: 21.3 % spread on identical work). A follow-up
   should re-run `warm_start_coarse_gate` on an idle machine and confirm wall
   moves in the same direction and rough proportion. **Until then, no wall
   number from this task should be quoted as evidence.**
2. **The cross-rung leak (§4).** That rungs ≥ 1 changed on `nobox` is attributed
   by inference to persistent GenEO/Krylov state, not by direct instrumentation.
   Worth confirming — it means *any* early-trajectory change can perturb later
   rungs in the armed regime, which is a general fact about this solver, not a
   fact about this option.
3. **E1 unresolved.** The pre-solve is deliberately unobserved
   (`opt_c.observe = nullptr`), so whether it stagnates *itself* was not
   measured. If Part B is ever revisited, observe it.
4. **A harsher, gate-capable stagnation fixture does not exist.** `nobox` is
   persistent stagnation without a design box; PR 273's `ladder32` has the box
   and the harsh regime but dies on a pre-existing non-finite-margin abort
   before completing a ladder. That abort is worth its own task.

---

## 7. In plain language

**The question.** A real customer run spent 58 of its 72 minutes stuck on just 3
of 65 optimizer steps, all near the beginning, while the design was still
thrashing around. There is a feature already written but switched off that was
supposed to help: solve a **quick, rough version of the problem at half
resolution first**, then hand that rough answer to the full-resolution run as a
starting point. The hope was that the expensive early thrashing would happen in
the cheap version instead.

**Why it was switched off.** Two reasons. It was tested once, back when it was
written, on toy problems about a thousand times smaller than a real job — and it
looked like a wash. But more importantly, **nobody could ever switch it on.** The
code to turn it on was never written. The program could *report* whether the
feature was active, but nothing could ever make it active. It has been dead code
since the day it was added. Part of this task was building the switch so the
question could be asked at all.

**The measuring-stick problem, which turned out to matter.** The obvious way to
score this is "did it need fewer optimizer steps?" That is the wrong ruler here,
because a step at half resolution is roughly **eight times cheaper** than a step
at full resolution. Counting them as equal is like comparing two shopping trips
by counting items and ignoring what they cost. The maintainer caught this and
required the work be measured in something resolution-aware. Scored by step
count, the feature looks **8 % worse**. Scored by actual work done, it looks
**13 % better**. Same runs — the ruler decided the answer.

**What we found.** On one test the feature genuinely works, and impressively: the
first stage went from 128 steps to 58, and the design stopped thrashing at step 9
instead of step 43. The stuck step vanished entirely.

**But it only helps the first stage.** These jobs run several stages, each
carving away more material. The feature hands its rough answer to the first stage
only; every later stage still starts from scratch. We confirmed the later stages
come out *literally identical* — not similar, identical to the last decimal. So
if the customer's problem repeats in every stage, this fixes one of them.

**And the fatal result:** on the test that best matches a genuinely stuck run —
where the fast solver never works at all — the feature made everything **worse**.
More steps, more work, more time stuck, and it produced a **26 % floppier part**
in one stage. A feature whose entire selling point is "it helps when you're
stuck" made being stuck worse.

**Safety.** Nothing unsafe happened. Every stage of every test reached the same
accept-or-reject decision with the feature on as with it off — ten out of ten. We
also ran a deliberately meaningless tiny nudge to the inputs to measure how much
the answers wobble on their own, so we could tell real changes from background
noise. Every run repeated exactly when run twice.

**One honest note about our own tools.** Our first check for "is this change real
or just noise?" used a crude test that would have labelled the single most
important result — the 26 % floppier part — as noise. We caught it, fixed the
check, and are flagging it here rather than quietly correcting it.

**A caveat on the timing numbers.** The machine was running several other heavy
jobs throughout, and was overheating and throttling itself. We proved how bad
this was: the *identical* run, twice, differed by 21 % in elapsed time. So all
conclusions use a work-based measure that a busy machine cannot distort. The
stopwatch numbers are shown for context only, and a clean timing run on an idle
machine is listed as unfinished business.

**The recommendation: leave it switched off.** The idea is sound — the mechanism
demonstrably works — but this particular version only ever reaches the first
stage, and it backfires in the exact situation it was built for. **There is a
sibling feature that carries a good starting point into *every* stage, which is
what the customer's problem actually calls for.** It is already switched on for
one kind of job and deliberately off for another. Revisiting that decision is
where the real gain is, and it is the recommended next step.
