# Why multigrid stagnates — sweeping levels, smoother and cycle

**Task:** `multigrid-component-sweep` · **Evidence:** `evidence/2026-08-02-multigrid-component-sweep/`
**Kind:** MEASUREMENT. Parameterises the V-cycle recipe so it can be swept;
changes NO default, no gate, no fixture, no assertion. Proven bit-identical (§6).

---

## The answer, first

**NOTHING in the component sweep rescues the maintainer's stagnating case.**

On the fixture that reproduces their failure to the grid — PR 273's
`ladder32.json`, solved grid 48x32x40, latch firing at design iteration 3 — every
configuration the task asked for burns the full 300-cycle budget without
converging:

| lever, applied to the real stagnating field | outcome |
| --- | --- |
| levels 2 / 3 / 4 / 5 / MAX | **all stagnate**, at an IDENTICAL 4,841 applies |
| 2+2 and 3+3 uniform smoothing | stagnate |
| +1 and +2 extra COARSE-ONLY sweeps | stagnate |
| W-cycle | stagnates |
| point-block Jacobi, w0.5 and w0.6 | stagnate |
| omega 0.5 | stagnates |
| W-cycle AND point-block | stagnates |
| W-cycle AND point-block AND coarse sweep | stagnates |

**25 measured configurations across the sweep and the rescue grid. Zero
convergences.** That is the plain-statement outcome the task named, and it points
where the task said it would: the fix is structural, not a tuning constant.

**Why, and the number that says it.** The exact reference solve of that system
needs **3,636 Jacobi-CG iterations** and reaches **max |u| = 4.5e+04**. At
`achieved_vf` 2-5 % inside a whole-domain box ~9.2 part-volumes, the structure is
so dilute it is nearly disconnected. A geometric coarse grid formed by halving
cannot represent a near-null-space that thin — there is almost nothing left on
the coarse grid to carry it. Smoothing harder, cycling more, or inverting a 3x3
nodal block instead of a scalar all act on the SMOOTHER or the CYCLE; none of
them changes what the COARSE SPACE can represent. **The diagnosis is that the
coarse space is wrong, not that the recipe around it is mistuned**, and the
decisive evidence is that hierarchy depth — the one knob that changes the coarse
space's shape — makes no difference at all here: 2, 3, 4, 5 and MAX levels all
produce exactly 4,841 applies.

**There are TWO stagnation mechanisms, and only one of them is tunable.** On a
moderately dilute design-box field (§4) the V-cycle stagnates purely from having
one grid level too many, and there the levers work beautifully — point-block
Jacobi alone takes it from stagnating to 117 cycles. On the maintainer's field
the stagnation is DILUTION-induced and depth is irrelevant. Component tuning
addresses the first and cannot touch the second.

---

## 1. AB2 — the stagnating fixture, reproduced to the grid

PR 273's `ladder32.json` reassembled from the same public pieces `run_job` uses:
`l-bracket.step` at resolution 32, `fixture_faces` = the two cylindrical
r = 2.5 mm screw holes, gravity −Z at 9810 mm/s², whole-domain design box
`[-35,-27.5,-6]..[45,27.5,64]` with `freeze_imported_part` false, ladder
`[0.68, 0.52, 0.38, 0.26]`, `simp.max_iterations` 16. Replayed with the
production latch live and both accelerators OFF, so this is multigrid alone:

| design iter | hier_built | levels | V-cycles | carried | fallback s | latched |
| ---: | ---: | ---: | ---: | --- | ---: | --- |
| 0 | 1 | 3 | 83 | YES | 0.00 | |
| 1 | 1 | — | **300** | no | 38.78 | |
| 2 | 1 | — | **300** | no | 27.90 | |
| 3 | 1 | — | **300** | no | 21.79 | **LATCHED** |
| 4 | **0** | — | 0 | no | **433.66** | LATCHED |
| 5-10 | **0** | — | 0 | no | 13.65-266.18 | LATCHED |

**Solved grid 48x32x40 — the grid PR 273 reported.** The run ended with the same
pre-existing abort they documented (`recommend_settings:
worst_case_stress_margin must be finite and >= 0`), which is why the trajectory
stops at 80 snapshots.

### AB3 — the latch rate, which is worse than a rate

**3 stagnations, latch fires at design iteration 3, multigrid dead for the rest
of the run.** The latch is a ONE-WAY DOOR — `g_mg_latched` is only cleared at run
start — so "stagnations per 50 design iterations" understates it. The correct
statement is that the shipped configuration loses multigrid **permanently within
the first four design iterations** of this job, and every solve afterwards is
plain Jacobi-CG, one of them for **433 seconds**.

The sweeps below therefore solve **design-iteration snapshot 2** — a field the
shipped configuration is measured to stagnate on. Snapshots after the latch fires
carry no evidence about the V-cycle, because it was never attempted on them.

### Fixtures that did NOT stagnate, reported because they bound the claims

| fixture | grid | levels | shipped V-cycles | latch |
| --- | --- | ---: | --- | --- |
| synthetic L-bracket in a dilute box | 48x32x48 | 3 | 65-79 over 40 design iters | never fired |
| occ0.4+hole whole-domain box | 32x16x32 | 3 | 26-60 over 118 design iters | never fired |
| occ0.4+hole whole-domain box | 64x32x64 | 4 | 26-231 over 100 design iters | never fired |

The second is a negative worth its own line. `multigrid.cpp`'s latch comment
names "occ0.4+hole" as the genuinely pathological case, and handoff 125 §1d
recorded it as *not converging even at 2000 cycles*. Rebuilt today from the same
recipe `conditioning_probe.cpp` uses, it converges in 26-60 cycles. Either the
intervening work moved it (the 128 budget raise 100 -> 300, the odd-axis parity
pad, the deep-block pad) or the 125-era instance differed from what that probe
builds. **A comment in the solver is making a claim the code no longer
supports.** Flagged, not silently relied upon.

---

## 2. The sweep on the stagnating fixture — every cell

Design-iteration snapshot 2 of the reproduction. Shipped hierarchy 3 levels; the
grid expresses 4. Direct-solve budget 40,000 DOFs, which admits even the 2-level
cell (coarsest 26,775 DOFs). Two repeats, round-robin.

| configuration | levels | V-cycles | applies | build s | cycle s | total s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **SHIPPED** (V, 1+1, scalar w0.6) | — | **300 STAG** | 4841 | 0.545 | 6.568 | 27.449 |
| A: levels=2 | — | 300 STAG | 4841 | **10.128** | 15.013 | 42.705 |
| A: levels=3 | — | 300 STAG | 4841 | 0.605 | 5.788 | 25.991 |
| A: levels=4 | — | 300 STAG | 4841 | 0.463 | 6.081 | 23.056 |
| A: levels=5 | — | 300 STAG | 4841 | 0.489 | 5.470 | 27.004 |
| A: levels=MAX | — | 300 STAG | 4841 | 0.501 | 5.885 | 23.267 |
| B: 2+2 uniform | — | 300 STAG | 5443 | 0.524 | 8.311 | 30.050 |
| B: 3+3 uniform | — | 300 STAG | 6045 | 0.741 | 12.487 | 31.638 |
| B: +1 coarse-only | — | 300 STAG | 4841 | 0.503 | 5.491 | 21.140 |
| B: +2 coarse-only | — | 300 STAG | 4841 | 0.536 | 7.989 | 27.259 |
| C: W-cycle | — | 300 STAG | 5142 | 0.504 | 8.363 | 30.628 |
| D: point-block w0.5 | — | 300 STAG | 4841 | 0.662 | 5.915 | 21.682 |
| D: point-block w0.6 | — | 300 STAG | 4841 | 0.745 | 4.970 | 21.515 |

Sweep E was **skipped and reported as skipped**: no configuration carried, so
there was no A-D winner to refine. That is the harness stating a negative rather
than silently picking a "best" among failures.

**The applies column is the tell.** Every level cell reads exactly **4,841** —
300 V-cycles at 4 applies each (3,641 of the 4,841) plus the identical Jacobi
fallback that follows. Depth changes the coarse space's shape and changes
NOTHING about the outcome. B and C differ only because they spend more applies
per cycle, and they still stagnate.

### AB4 — hierarchy build cost, separated

On this fixture the build is **~0.5 s against a ~21-30 s solve, i.e. ~2 %**.
Skipping it is not where the money is here — the Jacobi fallback is. This is the
opposite of the healthy regime, where PR 273 measured the build at 26.4 % and
this task measured it at **39.9 %** on the 4-level occ-hole run (§4). Reported
separately precisely because the answer inverts between regimes.

The one exception is `levels=2`, whose build is **10.1 s** — 20x the shipped
build — because it directly factors a 26,775-DOF coarse operator. At 64x32x64
the same cell would need 55,539 DOFs and the harness refuses it above its stated
budget. **A two-grid hierarchy is a small-grid luxury**, whatever the SMO
paper's iteration counts suggest.

---

## 3. The rescue experiment — does ANY lever save a stagnating configuration?

Same field, single samples, every lever applied on top of the stagnating
baseline. The applies count is deterministic; the wall column is single-sample
and is not used for ranking.

| lever | V-cycles | applies | rescued? |
| --- | ---: | ---: | --- |
| *stagnating baseline* | 300 | 4841 | — |
| + 2+2 uniform smoothing | 300 | 5443 | **no** |
| + 3+3 uniform smoothing | 300 | 6045 | **no** |
| + 1 extra coarse-only sweep | 300 | 4841 | **no** |
| + 2 extra coarse-only sweeps | 300 | 4841 | **no** |
| + W-cycle | 300 | 5142 | **no** |
| + point-block w0.5 | 300 | 4841 | **no** |
| + point-block w0.6 | 300 | 4841 | **no** |
| + omega 0.5 | 300 | 4841 | **no** |
| + W-cycle AND point-block w0.5 | 300 | 5142 | **no** |
| + W-cycle AND point-block AND coarse sweep | 300 | 5142 | **no** |
| control: one level shallower | 300 | 4841 | **no** |

**12 of 12. Nothing rescues it.**

---

## 4. The OTHER stagnation mechanism — where the levers DO work

This section exists because the sweep found a real, tunable failure mode. It is
NOT the maintainer's, and the scope is stated so nobody transfers it.

Fixture: occ0.4+hole whole-domain design box **64x32x64**, production ladder,
terminal (vf 0.26) field. Shipped hierarchy 4 levels; the grid expresses 5.

**Depth alone stagnates it, and depth alone is enough to explain it:**

| levels | V-cycles | applies | outcome |
| ---: | ---: | ---: | --- |
| 3 | **70** (61 at w0.5) | 280 (244) | converges, 1.86x faster than shipped |
| **4 — shipped here** | 195 | 780 | converges, at 65 % of budget |
| 5 | **300** | 3400 | **STAGNATES** |

And on this field the levers rescue it — the 5-level configuration, plus:

| lever | V-cycles | applies | rescued? |
| --- | ---: | ---: | --- |
| + 2 extra COARSE-ONLY sweeps | 300 | 3400 | **no** |
| + 1 extra coarse-only sweep | 275 | 1100 | barely |
| + 3+3 uniform | 290 | 2320 | barely |
| + 2+2 uniform | 246 | 1476 | yes |
| + W-cycle | 146 | 730 | yes |
| + omega 0.5 | 127 | 508 | yes |
| + point-block w0.6 | **117** | **468** | yes |
| + W-cycle AND point-block | 68 | 340 | yes |
| control: one level shallower | 70 | 280 | yes |

Two readings that survive into the recommendation:

* **The SMO paper's own stated fix is the one lever that FAILS**, in both
  regimes. Two extra coarse-only sweeps leave the depth-stagnating case at 300
  cycles, and one barely scrapes in at 275 of 300. On the 4-level field it costs
  cycles outright (195 -> 196 and 242). Cited, tested, refuted.
* **The W-cycle earns its keep only at depth.** Neutral at 3 levels (1.02x wall,
  83 -> 60 cycles for the same wall — the iteration-count trap PR 273 was burned
  by, reproduced), a genuine 1.32x at 4 levels.

The same monotone depth ladder appears on the smaller 32x16x32 grid — 2/3/4
levels cost 28/83/119 cycles — so it is not an artifact of one field.

---

## 5. AB6 — the healthy control

Same sweep, well-connected solid block at rho 0.6, at BOTH scales.

At 64x32x64 (shipped = 4 levels, matching §4's fixture):

| configuration | levels | V-cycles | applies |
| --- | ---: | ---: | ---: |
| SHIPPED | 4 | 18 | 72 |
| A: levels=3 | 3 | 17 | 68 |
| A: levels=5 | 5 | 18 | 72 |
| B: 2+2 uniform | 4 | 13 | 78 |
| C: W-cycle | 4 | 17 | 85 |
| **D: point-block w0.6** | 4 | **15** | **60** |
| D: point-block w0.5 | 4 | 16 | 64 |
| A: levels=2 | — | NOBUILD | 653 |

**On a healthy field, hierarchy depth costs nothing at all**: 3, 4 and 5 levels
give 17/18/18 cycles. Set that beside the same three numbers on the dilute field
— 70 / 195 / stagnate. Depth is not globally harmful; it is catastrophic on
high-contrast dilute fields and free on well-connected ones. That contrast is
the cleanest single result in this task.

Point-block is **−17 % applies** on the healthy control (72 -> 60), so it is not
a trade. Every other lever that helped somewhere either hurts healthy runs
(`levels=2`, NOBUILD or a 0.9 s build against 0.3 s of cycles at 32-scale) or
buys cycles with work (B and C both cut cycles while RAISING applies).

At 32x16x32 the same picture holds: shipped 18 cycles / 72 applies, point-block
w0.6 15 / 60.

---

## 6. Bars

### AB5 — no default changed, proven three ways

`fea_detail::MgTuning` (`core/src/fea/fea_matfree.hpp`) parameterises the recipe;
production never calls the setter.

* **Nine `static_assert`s** in `multigrid.cpp` bind the header's defaults to that
  file's shipped constants, so changing one without the other fails the BUILD.
* **`tests/unit/test_mg_tuning.cpp`** asserts each effective default against a
  written-out LITERAL (the pattern PR 275 used) — a test comparing a constant to
  itself would prove nothing. It also proves the knobs bite, that
  `mg_reset_tuning` restores every field, and that a post-reset solve is
  BIT-IDENTICAL to the reference.
* **Stash-rebuild**: the tree at HEAD (`c7194b4`) extracted with `git archive`
  and built independently (Release, same compiler); same job, 180 iterations.

| artifact | result |
| --- | --- |
| `design.bin`, `fields.bin`, `report.json`, `loadcase.json` | **IDENTICAL** |
| `variant_030.stl`, `variant_050.stl`, `variant_070.stl` | **IDENTICAL** |
| `iterations.csv` | 180 rows, identical header, **ZERO non-timing columns differ** |
| `build_orientation.json` | only `sweep_seconds` / `strut_axis_measure_seconds` — pre-existing; PR 273 recorded this file differs on every pair including ON-vs-ON2 |
| `run_info.json` | only the build fingerprint and `created_wall_ms` |

The CSV check is column-by-column, not a file hash, so it says something
stronger than "the file changed": `cg_iters`, `cg_multigrid`, `hier_built`,
`achieved_vf` and `compliance` are identical on all 180 rows.

**ctest: 94 tests, 93 passed.** The one failure, `build_direction`, is a
**pre-existing wall-ratio flake under host contention**, diagnosed rather than
waved off: its only failing-capable assertion is `sweep_seconds < 0.05 *
solve_s`, it drives `SolverKind::JacobiCG` (a path this change does not touch at
all), it passed **4/4 in isolation**, and the suite ran at host load 150-250. No
assertion was weakened or deleted anywhere in this task.

### AB7 — exactness

Every carrying configuration is compared against the exact matrix-free Jacobi-CG
field on the same system. **Worst relative displacement deviation across the
whole sweep: 4.7e-08** (dilute 32-scale), 3.7e-08 (dilute 64-scale), 7.2e-10
(healthy). No configuration changes the answer — structurally guaranteed, since
the outer FP64 CG's residual test is what defines convergence and a different
preconditioner can only change the iteration count.

### AB8 — determinism

Byte-identical rerun at the recommended configuration (point-block w0.6, 4-level
occ-hole fixture): same FNV-1a fingerprint `61ecf001b163ade7`, same 104 cycles,
same carried flag, twice.

### AB1 — iterations and wall, and the shared host

**The machine was NOT quiet.** Three other campaigns ran concurrently
throughout; recorded load averages ranged **29-262** on 10 logical cores. PR 273
records exactly how a shared host corrupts a judgement, so it is handled:

1. **Operator applies are the currency** — deterministic and load-independent.
2. **Round-robin repeats**, keeping the FASTEST repeat WHOLE rather than a
   column-wise minimum (which would mix phases from different repeats, so build
   + cycle would stop summing to the total beside them).
3. **Proof it mattered**: sweep E re-ran the IDENTICAL winning configuration and
   measured 228 applies both times but wall of **1.026 s vs 1.725 s** — a 1.7x
   swing on identical work. Load averages are printed into every evidence file.

**Stated as a limit: no configuration is ranked on a wall difference below about
1.5x.** The load average at each sweep's start and end is in the evidence. The
headline results do not depend on wall at all — "stagnates" and "4,841 applies"
are load-independent facts.

### The point-block derivation is verified, not assumed

The two multigrid paths build the same 3x3 nodal blocks by different routes: the
assembled path reads them off A0; the matrix-free path — which never assembles
A0 — accumulates them from the element table. Pinned to the same depth, both take
**16 cycles** and reach the same field. `test_mgcg_matfree` already pins that the
two paths agree at the same iteration count under the SHIPPED scalar smoother, so
this isolates exactly one thing: whether the element derivation is right. It is.

### A stale comment fixed

`multigrid.cpp:17` claimed "2 pre + 2 post sweeps" while `kPreSmooth` has been 1.
It now names the constants rather than restating a number that can go stale.

---

## 7. RECOMMENDATION

**For the maintainer's stagnating case: change NOTHING. No component-level
configuration helps, and this task should not be allowed to imply otherwise.**
25 configurations, zero convergences. Arming any of them would be re-tuning on a
fixture that does not represent the failure.

**Separately, as a PERFORMANCE change worth its own task: point-block Jacobi at
the shipped weight omega = 0.6.** Stated honestly, it is not a fix for the
stagnation — it is a broad reduction in work everywhere the V-cycle still
functions:

| regime | applies, shipped -> point-block w0.6 |
| --- | --- |
| healthy control, 4 levels | 72 -> **60** (−17 %) |
| dilute design box, 3 levels | 332 -> **232** (−30 %) |
| dilute design box, 4 levels | 780 -> **416** (−47 %) |
| depth-stagnating (5 levels) | 3400 -> **468**, and it CONVERGES |
| the maintainer's field | no effect — stagnates either way |

**What it costs the healthy control: nothing — it is a 17 % gain there too.**
It is grid-size independent (unlike the depth and DOF-cap levers, whose sign
flips with scale), it costs the same operator applies per cycle as the scalar
smoother, and its only price is building the 3x3 blocks — measured between 0.5 s
and 4.4 s against a 1.8-2.7 s scalar build at 64-scale, a spread wide enough that
**this host could not separate them**; that build cost needs a quiet machine
before anything is armed.

Arming it is a production default change and therefore out of scope here, per the
task's own SCOPE line.

**Hold omega at the shipped 0.6.** It is worth 13 % on one field and one cycle on
another, and the sign flips between them. Not a lever at this operating point.

---

## 8. What this does NOT settle

1. **The structural fix, which is where the evidence points.** The maintainer's
   stagnation is a COARSE-SPACE failure: the field is so dilute that a
   halving-based geometric coarse grid cannot represent its near-null-space, and
   no smoother or cycle can compensate. The candidates the task names — hybrid
   geometric/algebraic coarsening (Peetz & Elbanna), or reusing GenEO's spectral
   basis as a multigrid LEVEL rather than a deflation block — are exactly aimed
   at this. Both are separate and much larger tasks. This sweep's contribution is
   to have EXCLUDED the cheap alternatives with measurement rather than argument.
2. **Whether the latch's one-way door is right.** Three stagnations at design
   iteration 3 cost this job multigrid for all 80 iterations, including one
   433-second Jacobi solve. Whether a periodic re-arm would pay is a question
   this task did not ask; handoff `mg-latch-rearm-refuted` says re-arming at rung
   boundaries cannot rescue, but the field changes every iteration and nobody has
   measured a cheaper probe.
3. **The point-block build cost**, which this host could not resolve (§7).
4. **`kMgCoarseDofCap` as a scale-dependent lever.** Raising it stops the walk
   earlier, which is a large win at 64-scale (1.86x) and free on healthy fields,
   but at 32-scale it produces a 2-level hierarchy whose direct factorisation is
   a 0.9 s build against 0.3 s of cycles. Its sign flips with grid size, so it
   needs a scale study, not a constant.
5. **The stale "occ0.4+hole does not converge at 2000 cycles" claim** in
   `multigrid.cpp`'s latch comment and handoff 125 §1d (§1). It converges in
   26-60 today.
6. **The non-finite-margin abort** that ends this job's ladder early
   (`recommend_settings: worst_case_stress_margin must be finite and >= 0`).
   Pre-existing, already logged by PR 273 §2, hit again here.

---

## In plain language

The fast solver at the heart of this program is called multigrid. When it works
it is worth about two and a half times a plain solver. On the maintainer's real
runs it starts up, fails to make progress, gives up after 300 attempts, and after
three failures in a row a safety catch switches it off for the rest of the job —
after which every calculation runs the slow way. One of those slow calculations
in our reproduction took **seven minutes on its own**.

The literature offers four explanations, and this task was to test them. The main
one is that the solver may be building **too many levels** — it works by making
progressively coarser copies of the shape, and a 2025 paper reports that going
from two copies to four makes the work "totally explode."

So we made the solver's recipe adjustable — how many coarse copies it makes, how
much smoothing it does at each, what shape of cycle it walks, and what kind of
smoothing — **without changing what it actually does by default**. Then we
rebuilt the maintainer's failing job from a recipe an earlier piece of work had
already written down, and confirmed it fails in exactly the same way, on exactly
the same size of grid, with the safety catch tripping at the same point.

Then we tried everything. Twenty-five different settings. **Not one of them
worked.** Every single one gave up after the same 300 attempts.

The reason turns out to be the interesting part. By that stage of the job the
shape being designed is almost nothing — a few thin threads of material in a
mostly-empty box, about 2-5 % full. The solver's whole strategy is to make a
coarser copy of the shape and solve the easy version first. But you cannot make a
coarse copy of something that is already barely there: the threads are thinner
than a single coarse cell, so they vanish from the coarse copy entirely. Every
setting we tested adjusts how the solver *polishes* its answer or *how many
times* it goes round the loop. **None of them changes what the coarse copy can
represent, and that is the thing that is broken.**

The clearest proof is that changing the number of coarse copies — two, three,
four, five — made **no difference whatsoever** on the real case. Identical work,
identical failure, every time.

We did find a genuine and separate problem along the way. On a *milder* case —
still a sparse design, but not as extreme — the solver does fail purely from
having one coarse copy too many, and there the fixes work well. One of them, a
smarter kind of smoothing from a 2020 paper, rescues that case outright and cuts
the work by 17-47 % everywhere else we measured, including on healthy shapes
where nothing was wrong. That is worth having, and we recommend it as its own
piece of work — but we are being careful to say it is a **speed improvement, not
a cure**. It does nothing for the maintainer's actual problem.

Worth adding: the fix the 2025 paper itself recommends — more smoothing on the
coarse copies — was the one thing that made matters *worse* in both cases we
tested. We cited it, tested it, and it failed.

Nothing about how the program behaves was changed. We checked the hard way:
built the version from before this work, ran the same job, compared the results
byte for byte. The design, the physics and all three 3D-printable files come out
identical, and of the 180 rows in the per-step log, the only numbers that differ
are stopwatch readings.

**What we did not settle**, and should say plainly: we found what the problem is
not. Fixing it properly means changing how the coarse copy is built — letting the
solver work out for itself which parts of the shape matter rather than blindly
halving the grid. That is a substantially bigger job, and it now has a much
better justification than it did this morning, because the cheap alternatives
have been ruled out by measurement instead of by argument.

One honest caveat about the numbers: the test machine was busy with other work
throughout, at times heavily. We planned for that — the main results are counts
of arithmetic operations, which are exactly reproducible and unaffected by how
busy the machine is, and we deliberately refuse to rank anything on a timing
difference smaller than about 1.5x. The headline finding does not rest on timing
at all. "It gave up after 300 attempts" is true no matter what else the computer
was doing.
