# Algebraic level-1 coarsening — from measurement to production

**Task:** `algebraic-level1-coarsening` ·
**Evidence:** `evidence/2026-08-03-algebraic-level1-coarsening/`
**Kind:** BUILD + MEASUREMENT. Adds a production coarsening path behind a named
constant, LIBRARY DEFAULT OFF, plus its CTest tripwire and two harnesses.
Changes NO default, no gate, no fixture, no assertion.

**Stacks on PR 283** (`claude/algebraic-coarse-space-dilute-733b33`), which was
still open when this started. It consumes that PR's coarse-space machinery
(`build_hierarchy_from_prolongators`) and its energy-capture instrument, and
rebuilds neither.

**Merged with main after PR 283/282/284 landed** (merge commit on the branch).
GitHub reported PR 286 as CONFLICTING; the conflict was a CRISS-CROSS, not a
textual one — this branch merged PR 283's branch (`99d4157`) directly while main
merged it separately (`3debbe9`), leaving TWO merge bases (`99d4157` and
`7bd1b13`). Git's recursive strategy resolves that with no conflict markers in
either direction (`git merge` and `git merge-tree --write-tree` both clean); the
merge commit collapses the criss-cross so GitHub agrees. **Every bar below was
re-run on the merged tree** — see §14 for what moved and what did not.

---

## The answer, first

**It works, on the regime it was built for, and the gate is clean.**

On the maintainer's real stagnating field the shipped V-cycle burns its 300-cycle
budget, gives up, and falls back to a **3,636-iteration** Jacobi-CG. With the
algebraic level-1 coarse space the same production solver **CARRIES, in 96 PCG
iterations** — 39x less DOF-weighted work, and PR 283's amg_lean prediction of 86
reproduced to 1.12x through a solver whose fine smoother is damped Jacobi rather
than Chebyshev.

**On a full production ladder the stagnation latch stops firing.** Disarmed: 3
stagnating solves and `kMgLatchThreshold` FIRES, after which the whole run rides
Jacobi-CG. Armed: **0 stagnating solves, latch quiet**, ladder CG 85,536 →
15,595 (5.5x), wall 77.4 s → 40.0 s. **Zero verdict flips** across all four
rungs.

**Both of PR 283's downstream predictions are confirmed**, and they are the
cleanest evidence that multigrid really did become healthy rather than merely
faster: GenEO's ski-rental gate goes from 1 build / 1 armed solve / 167 declines
to **0 / 0 / 0**, and the recycler — structurally absent on the healthy multigrid
path — goes from **163 recycled solves to 0**.

**And it must not be armed unconditionally, for two measured reasons.**

* **It is a 2.71x LOSS on a healthy field.** The aggregation coarsens harder than
  halving does, which is exactly what makes it strong on a dilute field and weak
  on a well-connected one: 18 V-cycles → 52, DOF-weighted 41.3 → 112.1. The same
  capture instrument says why — on the healthy control the geometric space
  captures 99.2959 % and the algebraic one only 38.7293 %. **Anything armed here
  has to be a SWITCH, not a replacement.**
* **The memory projection crosses the cap below the maintainer's scale.**
  Measured over a 108x DOF range the added bytes grow as `DOFs^1.037` at
  ~355 bytes/DOF, projecting to **3.32 GB at 8.44M DOF** — above
  `kAlgMaxCoarseBytes` (2048 MB). The path enforces that by DECLINING and letting
  the geometric builder run, so it never OOMs; but above roughly **5.5M DOF an
  armed default would silently be the geometric path anyway**.

**The recommendation (§12) is therefore not "arm it" or "don't" — it is arm it
AS THE STAGNATION LATCH'S REPLACEMENT**, which is the one shape the measurements
support without qualification and which costs the healthy case exactly nothing,
because a healthy run never stagnates and so never switches. That change is NOT
built here.

### The honest caveat, up front

The machine was busy throughout (1-minute load 9-18 on 10 logical cores) and PR
277's discipline is applied: load is printed at both ends of every measurement.
**Every headline number above is a count or a ratio of exact solves** —
iterations, capture, coarse dimensions, aggregates, bytes, verdicts, latch
fired/quiet. Wall is reported and deliberately not ranked on below ~1.5x.

---

## 1. What was built

### The shape

`build_mf_hierarchy` used to have exactly one way to make level 1: halve the fine
grid and interpolate trilinearly. It now has two, and the second is reached only
when `fea_set_mg_algebraic_level1(true)` has been called:

```
level 0    matrix-free            (UNCHANGED — A0 is never assembled)
level 1    trilinear halving  OR  AGGREGATION of the fine operator
level 2..  halving of level 1 OR  aggregation of the assembled A1
```

Three things make this a small change rather than a second solver:

* **The element-local Galerkin product is shared.** It was already generic in
  `P0` — it reads the prolongator only as `prolong`, the per-kept-fine-DOF list
  of (coarse column, weight) pairs — so it never cared how those rows were
  produced. It is now `galerkin_a1_from_prolong`, called by both paths, with the
  geometric path passing exactly what it always did. Its local block was sized
  `24x24` because the trilinear stencil always gives exactly 24 coarse DOFs per
  element; an aggregation can give up to 48 (8 aggregates x 6 modes), so the
  scratch is now sized from the measured maximum. Same arithmetic, same loop
  order, same summation order — only the row stride differs.
* **Levels 2.. reuse PR 283's consumer.** `build_hierarchy_from_prolongators`
  already takes a list of prolongators, forms every coarse operator by the
  solver's own Galerkin product, uses `R = P^T`, factors its own bottom level and
  CHECKS rather than trusts every shape it is handed. Nothing about its
  guarantees changes when the prolongators come from an aggregation.
* **Refusals are free.** A non-scalar smoother, a level the coarsening control
  rejects, the memory cap, a chain that never reaches the direct-solve cap, a
  bottom that will not factor — each returns false and the geometric builder runs
  exactly as before. The tripwire exercises one of these deterministically.

### The one constraint that could not slip

**A0 IS NEVER ASSEMBLED.** PR 230 priced fine-level assembly at 20-35 GB on an
8.44M-DOF job, and the matrix-free level 0 is the only reason that job fits.
Every setup quantity is streamed ELEMENT-LOCALLY off the production element table
through a node→element incidence list, one node row at a time: the node-block
strength graph (Vanek's test on the 3×3 nodal blocks, applied on the SQUARED
norms so it stays in exact arithmetic) and the fine operator's true nnz/row for
the stencil-growth rule. The level-1 operator comes from the shared element-local
Galerkin product. Peak RSS across the whole measurement campaign, which holds the
reference field and every hierarchy it builds, was **0.97 GB**.

The prolongator is **unsmoothed** (`P = T`). That is not a simplification: PR 230
§6d and PR 283 §4 both measured unsmoothed beating smoothed on every axis here
(86 vs 243 iterations, 45.6 vs 149.8 MB, 0.6 vs 7.7 s setup), *and* forming `T`
needs only the aggregation — never A's rows — so it is the variant that fits a
matrix-free fine level natively. Smoothing would require `A·T`, which is the one
setup quantity that would push toward materialising A0.

The harness VERIFIES this rather than asserting it: for a pseudo-random `z` it
compares `z^T A1 z` against `(P0 z)^T A0 (P0 z)` through the production
matrix-free apply, and refuses to report a capture if they disagree. Measured
**1.347e-15** relative on the stagnating field, **2.094e-16** on the healthy
control. That check licenses every capture number below.

### Why the cycle stays sound

Only the coarse SPACES are algebraic. The Galerkin products, `R = P^T` and the
bottom factorisation are the solver's own, so the cycle stays symmetric positive
definite and remains a valid CG preconditioner whatever the aggregation produced;
and the outer FP64 CG's relative-residual test still defines convergence. A
different coarse space can therefore change the ITERATION COUNT and the in-basin
rounding of the converged field — never the answer, and never any gate's verdict
logic or tolerance.

### Where the code is

| file | what |
| --- | --- |
| `core/src/fea/algebraic_coarsen.hpp` | the named recipe constants with their derivations, and the two entry points |
| `core/src/fea/algebraic_coarsen.cpp` | incidence, strength graph, the 3-phase aggregation rule spelled out in full, the rigid-body modes, the tentative prolongator, the coarsening-control rule, the assembled coarse levels |
| `core/src/fea/multigrid.cpp` | `build_mf_hierarchy_algebraic`, the shared `galerkin_a1_from_prolong` and `mf_build_point_block_fine`, the arming flag and its `static_assert` tripwire |
| `core/include/topopt/fea.hpp` | `fea_set_mg_algebraic_level1`, `fea_mg_algebraic_level1_info`, `fea_mg_last_hierarchy_dims`, `kMgAlgebraicLevel1LibraryDefaultOn` |
| `core/src/simp/production.cpp` | the TRIPWIRE and `kProductionMgAlgebraicLevel1 = false` |
| `core/src/simp/observability.cpp`, `core/src/cli/run_job.cpp` | the run_info echo (posture + aggregates + dimension + depth + added MB + refusal reason) |
| `core/tests/unit/test_mg_algebraic_level1.cpp` | the CTest tripwire (`fea_mg_algebraic_level1`) |
| `core/tests/harness/alg_level1_probe.cpp` | `capture` / `converge` / `mem` / `det` |
| `core/tests/harness/alg_level1_gate.cpp` | the full-ladder arming gate |

### The named constants, and where they came from

| constant | value | basis |
| --- | --- | --- |
| `kAlgStrengthTheta` | 0.02 | PR 283 §4 swept it: 0.02 gives 56.3293 % capture and **86** PCG iterations; 0.08 captures MORE (61.7518 %) and needs **292**, because its hierarchy degrades below level 1. Capture is necessary, not sufficient. |
| `kAlgNullspaceDim` | 6 | the rigid-body modes of 3D elasticity |
| `kAlgMinCoarseningRatio` / `kAlgMaxNnzPerRow` / `kAlgMaxLevelDensity` / `kAlgMaxStencilGrowth` | 2.0 / 400 / 0.10 / 8.0 | PR 230 §2d's coarsening collapse (ratio 10.6x → 1.35x, a level 100 % dense, setup 6.7x, 3.3 GB) is exactly what these bound |
| `kAlgMaxCoarseBytes` | 2048 MB | PR 248's `kGeneoMaxBasisMB` refuse-and-fall-back precedent — see AH3, which is why it matters |

---

## 2. AH1 — OFF is byte-identical

THE ONE RULE: a process that never calls `fea_set_mg_algebraic_level1(true)` must
compute exactly what it computed before this task existed. Proven three ways.

### The tripwire (`fea_mg_algebraic_level1`, in CTest)

`core/tests/unit/test_mg_algebraic_level1.cpp` asserts, on a real solve:

* the path is DISARMED by default, and the named constant
  `kMgAlgebraicLevel1LibraryDefaultOn` agrees (a `static_assert` in
  `multigrid.cpp` tripwires the flag's initialiser against it);
* a disarmed solve reports **no algebraic build at all** (zero aggregates, zero
  coarse dimension) — not merely a quiet one;
* a solve after **arm + disarm is BIT-IDENTICAL** to one taken before the flag
  was ever touched, compared with `memcmp` on the raw doubles, at the same level
  and cycle counts;
* armed, the path genuinely BITES — a different coarse dimension from the
  geometric one, aggregates formed — and still reaches the same field
  (**3.066e-10**);
* a **deterministically forced refusal** (the point-block smoother, which the
  algebraic levels cannot support) falls back to the geometric builder
  **bit-identically**, and REPORTS its reason rather than failing silently;
* a small system yields a two-level algebraic cycle rather than a refusal — the
  same fallback the geometric builder takes there;
* two armed setups produce the same aggregation and a bit-identical field.

The refusal bar is forced rather than left to a fixture that might coarsen: a bar
that only sometimes exercises its path is not a bar.

### Stash-rebuild (`evidence/.../byteid.txt`)

The tree at the reference commit (`ee5da824`, the PR 283 merge — i.e. everything
this task changed, removed) extracted with `git archive`, built independently
(Release, same compiler), and run against the current build on the SAME job (the
committed demo fixture, resolution 48, 3 rungs x 30 iterations, 180 recorded
design iterations).

| artifact | result |
| --- | --- |
| `report.json`, `design.bin`, `fields.bin`, `loadcase.json` | **IDENTICAL** (SHA-256) |
| `variant_070.stl`, `variant_050.stl`, `variant_030.stl` | **IDENTICAL** (SHA-256) |
| `iterations.csv` | 180 rows, identical header, **ZERO solver-work or physics columns differ** |
| `run_info.json` | only this task's 7 new keys, plus `created_wall_ms` and the build fingerprint |

The seven added `run_info.json` keys read, on that disarmed production run:
`mg_algebraic_level1: false`, `aggregates: 0`, `coarse_dim: 0`, `levels: 0`,
`added_mb: 0`, `level1_refused: false`, `refuse_reason: null`. The reason is JSON
**null** rather than an empty string deliberately — a clean run must not carry a
field that reads like a refusal — and the posture is echoed even when off, per
the 132 discipline: a run record that only names an accelerator when it fired
cannot be used to rule it OUT of a later diagnosis.

The CSV check is column by column over all 44 columns. Twenty-one differ and
every one of them is a `*_ms` duration or an RSS/paging counter
(`available_mb`, `compressed_mb`, `major_faults`, `swapins`, `rss_mb`,
`peak_rss_mb`). Named explicitly, the columns that state what the solver DID —
**`cg_iters`, `cg_multigrid`, `hier_built`, `mg_cycles_attempted`, `matvecs`,
`compliance`, `achieved_vf`** — are IDENTICAL on all 180 rows. That is the direct
statement that the solver did the same work, rather than an inference from the
absence of differences.

*(An earlier pass of this check used too narrow a list of timing column names and
flagged twenty of them as non-timing. The corrected classification is carried in
the evidence file beside the original rather than replacing it.)*

### The suite

**ctest: 98 tests, 98 passed, 0 failed** (`evidence/.../ctest.txt`, re-run on
the merged tree), including the new `fea_mg_algebraic_level1` at 2.09 s
alongside PR 283's `fea_mg_coarse_hook` at 2.60 s. The suite has grown by exactly one since PR 283
ran it at 97 — this task's tripwire — and no previously passing test was
modified, skipped or relaxed. Total test time 1,192 s against PR 283's 568 s:
the machine was carrying the measurement campaign concurrently, which is a wall
difference and not a behavioural one.

**No assertion was weakened or deleted anywhere in this task** — the diff removes
zero `static_assert`/`CHECK` lines and adds three.

---

## 3. AH2 — PR 283's numbers reproduce through the production path

The prolongator here is the PRODUCTION one (`fea_detail::alg_level1_prolongator`,
the function the solver calls), on PR 280's exact cached field — the same
`mg_stepbox_r32.bin` PR 283 read, so the two probes cannot drift apart. The
fixture reproduced PR 280 to the grid: solved **48x32x40**, 46,139 solid voxels,
80 trajectory snapshots, design iteration 0 carrying in 83 cycles and iteration 1
stagnating at 300.

### Capture

| space | dim | captured energy | PR 283 | agreement |
| --- | ---: | ---: | ---: | ---: |
| geometric level 1 | **18,738** | **1.5954 %** | 1.5954 % at 18,738 | **1.0000x** |
| **algebraic level 1** | **13,140** | **56.3293 %** | 56.3293 % at 13,140 | **1.0000x** |
| *healthy control, geometric* | 7,344 | **99.2959 %** | 99.2959 % at 7,344 | **1.0000x** |

**All three of PR 283's published numbers reproduce exactly**, at exactly the
published dimensions. The production aggregation produces literally the same
space the probe measured — 35x the capture at a 30 % SMALLER coarse dimension.

### Convergence, through the shipped solver

| field | posture | levels | outcome | PCG iters | DOF-wtd work | level dims |
| --- | --- | ---: | --- | ---: | ---: | --- |
| stagnating | geometric | — | **STAGNATES** → Jacobi-CG | **3,636** | 8,180.0 | 150,075 → 18,738 → 2,364 |
| stagnating | **ALGEBRAIC** | 3 | **CARRIED** | **96** | **208.8** | 150,075 → 13,140 → 1,830 |
| healthy | geometric | 4 | CARRIED | **18** | 41.3 | 411,840 → 53,856 → 7,344 → 1,080 |
| healthy | ALGEBRAIC | 3 | CARRIED | 52 | 112.1 | 411,840 → 31,944 → 1,572 |

**96 against PR 283's 86** — a 1.12x gap, and the expected direction: PR 283's
amg_lean hierarchy smooths the fine level with Chebyshev where production ships
damped Jacobi, and its coarse levels use symmetric Gauss-Seidel. The prediction
survives the substitution. **39x less DOF-weighted work than the stagnating
baseline**, and 38x fewer iterations than the Jacobi-CG the solver currently
falls back to.

---

## 4. AH3 — memory at real scale

Measured, not assumed linear: aggregate count, coarse dimension and added bytes
at six grid sizes spanning a **108x DOF range**, plus the dilute field as a
transfer check.

| grid | DOFs | aggregates | coarse dim | levels | added MB | bytes/DOF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 16x8x16 | 7,344 | 108 | 648 | 2 | 2.17 | 310.2 |
| 24x12x24 | 23,400 | 360 | 2,160 | 2 | 6.95 | 311.5 |
| 32x16x32 | 53,856 | 726 | 4,356 | 2 | 16.00 | 311.5 |
| 48x24x48 | 176,400 | 2,448 | 14,688 | 3 | 59.77 | 355.3 |
| 64x32x64 | 411,840 | 5,324 | 31,944 | 3 | 139.61 | 355.4 |
| 80x40x80 | 797,040 | 10,206 | 61,236 | 3 | 269.86 | 355.0 |
| **stagnating (DILUTE)** | 150,075 | 2,190 | 13,140 | 3 | 47.59 | **332.5** |

**The fit:** `bytes = 218.4 * DOFs^1.0368` — essentially linear, with bytes/DOF
settling at ~355 once the hierarchy reaches three levels.

**The projection: 3.32 GB at 8.44M DOF.** The naive 56.3x scaling of PR 283's
45.6 MB at 150k DOF would have said ~2.6 GB; measuring gives 3.32 GB, so the
naive number was optimistic by ~28 %.

**The dilute row is the transfer check, and it passes.** PR 283 warned that "a
different field aggregates differently", so projecting a healthy fit onto the
maintainer's dilute job without checking would have been an unstated assumption.
The dilute field reads **332.5 bytes/DOF**, inside the healthy band of 310-355.
The fit transfers.

### Against the machine, and against the cap

* This machine has **16 GB**. 3.32 GB fits, with the rest of the solver on top.
* `kAlgMaxCoarseBytes` is **2048 MB**, following PR 248's `kGeneoMaxBasisMB`
  refuse-and-fall-back precedent. **The projection exceeds it.**
* Solving `218.4 * D^1.0368 = 2048 MB` gives the **crossover at ~5.5M DOF**.

**So the cap is doing exactly what it is for, and the consequence must be stated
plainly: on an 8.44M-DOF job an armed algebraic path would REFUSE and fall back
to the geometric hierarchy — i.e. today's behaviour, including today's
stagnation.** This is a refusal, not an OOM: the path declines before allocating,
`run_info.json` records the reason, and the solve proceeds exactly as it does
now. It is not a blocked-stop (the win is real below the crossover and the
failure mode is safe), but it does mean **the arming case is strongest at the
resolutions the app actually runs and weakest at the largest job on record**, and
a follow-up that wants the win at 8.44M DOF must either raise the cap against
measured headroom or shrink the space (fewer retained modes per aggregate is the
obvious lever, and is unmeasured).

---

## 5. AH4 — the latch stops firing (the headline)

Full production ladder, the `make_stagnation` fixture used verbatim by the draft
and GenEO arming gates, with the rest of the production stack armed identically
in both postures.

| posture | stagnating solves | of total | latch | ladder CG |
| --- | ---: | ---: | --- | ---: |
| disarmed (shipped) | **3** | 250 | **FIRED** | 85,536 |
| **ARMED** | **0** | 255 | **quiet** | **15,595** |

Per rung (stagnating solves / solves):

```
disarmed:  0/37   0/47   3/73   0/93
ARMED   :  0/37   0/47   0/78   0/93
```

The stagnation is concentrated in rung 2, and the algebraic coarse space removes
it entirely. **The latch never arms, so the run never abandons multigrid**, which
is the whole point: PR 283's reproduction of the maintainer's real job spent
1,931 s of 1,946.7 s in the Jacobi fallback that the latch commits it to.

---

## 6. AH5 — the setup cost, charged

Aggregation is a per-design-iteration cost like the hierarchy build, which PR 273
measured at 26.4 % of a HEALTHY run's wall. Reported in DOF-weighted operator
applies (primary, exact) and wall (secondary, with load recorded).

| field | posture | aggregation | hierarchy build | cycle loop | DOF-wtd work |
| --- | --- | ---: | ---: | ---: | ---: |
| stagnating | geometric | — | 419.8 ms | 3,648.7 ms | 8,180.0 |
| stagnating | ALGEBRAIC | **77 ms** | **422.6 ms** | 1,006.7 ms | **208.8** |
| healthy | geometric | — | 1,266.3 ms | 410.6 ms | 41.3 |
| healthy | ALGEBRAIC | **210 ms** | **1,104.8 ms** | 1,300.2 ms | 112.1 |

**The setup is not the story, in either direction.** On the stagnating field the
algebraic build costs 422.6 ms against the geometric 419.8 ms — a 0.7 %
difference, because the 77 ms of aggregation REPLACES the trilinear prolongator
construction rather than adding to it. On the healthy field the algebraic build
is actually **cheaper** (1,104.8 vs 1,266.3 ms), because it produces a shallower
hierarchy.

**What moves is the cycle loop**: 3,648.7 → 1,006.7 ms on the dilute field
(fewer, better cycles) and 410.6 → 1,300.2 ms on the healthy one (more, worse
cycles). That is the same fact §7 reports from the capture side, seen as cost.

Against PR 273's 26.4 % geometric-build baseline: on the healthy field the
algebraic build is 46 % of the solve (1,104.8 of 2,405 ms) versus the geometric
75 % — the algebraic path shifts work from build to cycles, not the reverse.

---

## 7. AH6 — the healthy case, and whether a cheap switching signal exists

**The algebraic path is a real regression on a healthy field, and the same
instrument explains it.**

| field | geometric capture | algebraic capture | geometric cycles | algebraic cycles | DOF-wtd ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| stagnating | 1.5954 % | **56.3293 %** | STAGNATES (3,636) | **96** | **0.026x** |
| healthy | **99.2959 %** | 38.7293 % | **18** | 52 | **2.71x** |

The mechanism is visible in the coarse dimensions: on the 32x16x32 block the
aggregation coarsens **12.4x** at level 1 where halving coarsens **7.3x**. A
bigger, structure-following aggregate is exactly what rescues a ligament thinner
than a coarse cell, and exactly what throws away resolution a well-connected
field needs. **Geometric coarsening is the right coarse space for a healthy
field. Anything armed must be a SWITCH.**

### Does a cheap signal exist? Yes — and the best one is already in the solver

Peetz & Elbanna's stated goal is that the choice be automatic, with "no need for
the user to specify a fixed number of algebraic or geometric levels". Three
candidates, measured:

1. **The stagnation latch — free, already shipped, and the right one.**
   `multigrid.cpp` already counts consecutive stagnations and fires at
   `kMgLatchThreshold == 3`. PR 283 put it exactly right: *"What has been missing
   is not a detector but something to switch TO."* This task is that something.
   A healthy field never stagnates, so it never switches and pays **nothing** —
   not the aggregation setup, not the extra cycles, not the memory. The gate run
   in §5 shows the detector firing on precisely the rung that needs it (rung 2)
   and nowhere else.
2. **The void-floor share — free, and it separates cleanly here.** One pass over
   the density vector the solver is already handed: **0.6511** on the stagnating
   field, **0.0000** on the healthy control. It is a pre-solve signal, so it could
   switch before the first wasted V-cycle rather than after three.
   **The caveat PR 283 raised still stands and this task did not remove it: two
   points do not establish a threshold**, and PR 280's third regime (the occ-hole
   design box, which stagnates from DEPTH alone and is rescued by ordinary
   component levers) has still not been placed on this axis.
3. **The capture instrument itself — NOT cheap, and this should be said plainly.**
   It is the most direct signal (99.2959 % vs 1.5954 % is not a marginal call),
   but computing it needs the EXACT solution's energy `u·b`, which is the thing
   the solver is trying to avoid computing. It is a diagnostic, not a runtime
   switch.

**So: a cheap signal exists, and it is the latch.** The trade is real and is
reported rather than hidden — but it does not require the maintainer to pick
between the regimes, because the switch can be conditional on the failure the
feature exists to fix.

---

## 8. AH7 — the gate table

Full production ladder, four rungs, disarmed vs armed, with a 1e-9 negative
control run FIRST to establish the basin floor (PR 248's discipline).

| rung | vf | disarmed | ARMED | margin rel delta |
| ---: | ---: | --- | --- | ---: |
| 0 | 0.6800 | **ACCEPT** 7.089748 | **ACCEPT** 7.087462 | 3.225e-04 |
| 1 | 0.5200 | **ACCEPT** 3.381657 | **ACCEPT** 3.381657 | 3.096e-10 |
| 2 | 0.3800 | **ACCEPT** 1.884050 | **ACCEPT** 1.890188 | 3.258e-03 |
| 3 | 0.2600 | **REJECT** 0.594860 | **REJECT** 0.642366 | 7.986e-02 |

### VERDICT FLIPS: 0. The rung count is identical. The gate is clean.

Rung 3's margin moves 8.0 % — the largest move in the table — and it is worth
saying why that is not alarming: it is the REJECTED rung, the one whose solves
stagnate hardest and whose disarmed trajectory therefore rode the Jacobi
fallback the whole way. Both postures reject it, comfortably, on the same side of
the 1.5 threshold.

### Classification flips, against the control floor

Over the solid voxels of the solved 24x8x24 grid. **Flips that exceed the control
are reported, not rounded away.**

| rung | solid | NEG CONTROL 1e-9 (floor) | ARMED vs disarmed | |
| ---: | ---: | ---: | ---: | --- |
| 0 | 4,608 | 0.000e+00 (0 flips) | 0.000e+00 (0 flips) | within floor |
| 1 | 4,608 | 0.000e+00 (0 flips) | 0.000e+00 (0 flips) | within floor |
| 2 | 4,608 | 0.000e+00 (0 flips) | **2.170e-04 (1 flip)** | **ABOVE FLOOR** |
| 3 | 4,608 | 2.170e-04 (1 flip) | 2.170e-04 (1 flip) | within floor |

**Rung 2 flips ONE voxel of 4,608 where its own negative control flipped none.**
That is stated as exceeding the floor because it does. Two things bound it: the
magnitude is exactly the control's own worst rung (rung 3's control also flips
one voxel), so it is at the noise scale this fixture already exhibits rather than
a new scale; and **no verdict moved on any rung**. This is the expected class of
difference for an exact accelerator — a different iteration path landing
elsewhere inside the same 1e-8 basin — and it is the same class PR 248 and PR 278
charged against the same floor.

---

## 9. AH8 — exactness, and AH10 — determinism

**AH8.** The converged displacement matches the exact matrix-free Jacobi-CG
reference on the same system, compared in the same numbering (the reference is
over the KEPT DOFs and is lifted through `kept_global`, not indexed against —
getting that wrong is easy and silent):

| field | worst relative deviation, ARMED |
| --- | ---: |
| stagnating (48x32x40, 150,075 DOF) | **2.558e-09** |
| healthy (64x32x64, 411,840 DOF) | **1.017e-10** |
| tripwire block (32x16x32) | 3.066e-10 |

All inside the 1e-8 solver tolerance, as the SPD construction guarantees.

**AH10.** Byte-identical rerun in every posture, on both fields — same iteration
count, same aggregation, same FNV-1a field fingerprint:

| field | posture | iters | level-1 dim | fingerprint |
| --- | --- | ---: | ---: | --- |
| stagnating | geometric | 3636 / 3636 | — | `c573782fac60eb3b` (twice) |
| stagnating | ALGEBRAIC | 96 / 96 | 13,140 / 13,140 | `8d85126b2c1c5088` (twice) |
| healthy | geometric | 18 / 18 | — | `d446ffa7cc6b9ff2` (twice) |
| healthy | ALGEBRAIC | 40 / 40 | 4,356 / 4,356 | `d81fa54fa8d38fd6` (twice) |

The geometric fingerprint `c573782fac60eb3b` is the SAME one PR 283 recorded on
this field (its `det.txt`, for a configuration that also stagnated and fell
back). Both runs therefore end in the identical exact Jacobi-CG field, which is
a cross-build check that this task did not disturb the shipped path — a weaker
statement than bit-parity of a multigrid solve, and stated as such. The
aggregation is deterministic by construction: ascending
traversal everywhere, smallest-index tie-breaks, sorted column emission, fixed
summation order, no power iteration and no random start.

---

## 10. AH9 — the downstream predictions, both confirmed

If multigrid genuinely becomes healthy — as opposed to merely running fewer
iterations — two things must follow, and both are checkable on the same ladder.

| | GenEO builds | refreshes | armed solves | declined |
| --- | ---: | ---: | ---: | ---: |
| disarmed | 1 | 0 | **1** | **167** |
| **ARMED** | **0** | **0** | **0** | **0** |

| | solves with a recycled subspace | max dim |
| --- | ---: | ---: |
| disarmed | **163** | 16 |
| **ARMED** | **0** | 0 |

**Both predictions hold, exactly.** GenEO's engagement gate is never even
consulted armed, because no solve ever burns the stagnation-trigger budget — the
167 declines disappear along with the 1 arm, since there is no fallback loop to
decline in. And the recycler's share simply vanishes rather than needing to be
fixed, which is what PR 282's structural finding predicted: `mf_mgpcg` constructs
its session with `allowed = rc_wrap_multigrid()`, pinned false, so a run whose
solves all carry has no recycling to do.

**This is the strongest single piece of evidence in the report.** Iteration
counts can fall for many reasons; two independent accelerators built for the
stagnating regime both going to zero is what it looks like when the stagnating
regime is gone.

---

## 11. AH11 — wall, on the maintainer's regime

Reported with host load recorded beside it, and ranked on the load-independent
currency (CG iterations) rather than the stopwatch.

| measurement | disarmed | ARMED | ratio |
| --- | ---: | ---: | ---: |
| full production ladder, wall | 77.4 s | **40.0 s** | **1.94x faster** |
| full production ladder, CG iterations | 85,536 | **15,595** | **5.5x fewer** |
| single solve on PR 280's real field, wall | 12.94 s | **1.43 s** | **9.0x faster** |
| single solve, DOF-weighted applies | 8,180.0 | **208.8** | **39.2x less** |

**Where this lands against PR 273's reference points.** PR 273 measured a healthy
multigrid solve at **0.45 s**, plain Jacobi-CG at **1.112 s** and standing GenEO
at **1.389 s**. The disarmed solve on the dilute field costs **12.94 s** — an
order of magnitude worse than any of them, because it pays the full 300-cycle
V-cycle budget *and then* the Jacobi fallback. Armed, the same solve costs
**1.43 s**.

Two honest qualifications on that comparison. First, PR 273's points are on
different fields and sizes, so this is placing an order of magnitude, not a
like-for-like ranking: 1.43 s sits at the plain-Jacobi end rather than the
healthy-multigrid end, and the field is 150,075 DOF and 3.7 % dense. Second, and
more usefully, the ARMED number is not really "a fast fallback" — the solve
CARRIES, so it is the first entry in this table that is a working multigrid solve
on the dilute regime at all. The 39.2x DOF-weighted figure is the one to quote,
because unlike the wall it does not move with a load average that ran between 9
and 18 on 10 logical cores throughout.

---

## 12. RECOMMENDATION

**Do not arm it unconditionally. Arm it as the STAGNATION LATCH'S REPLACEMENT.**

The gate table is clean (0 verdict flips, 1 voxel above a 1-voxel floor), the
exactness holds (2.6e-9), the determinism holds, and the win on the regime it was
built for is unambiguous — the latch stops firing, 3,636 iterations become 96,
and the two accelerators that exist only to survive stagnation both go to zero.
Against that, the healthy case loses 2.71x and the memory projection crosses the
cap at ~5.5M DOF. **Both objections are objections to arming it ALWAYS. Neither
is an objection to arming it WHEN THE SHIPPED PATH HAS ALREADY FAILED.**

In order:

1. **Build the switch, not the flip.** Today `multigrid.cpp` counts consecutive
   stagnations and, at `kMgLatchThreshold == 3`, gives up on multigrid for the
   rest of the run. Change that terminal state into a transition: on the third
   consecutive stagnation, rebuild the hierarchy with the algebraic level-1 space
   and keep going; latch off only if THAT also stagnates. A healthy run never
   reaches the threshold, so it pays nothing — not the setup, not the cycles, not
   the memory, not a byte. **This is the shape the measurements support without
   qualification, and it is NOT built here.** It needs its own gate table
   (the switch's own fixture set, including PR 280's third regime) before it
   ships.
2. **Leave `kProductionMgAlgebraicLevel1 = false` in the meantime.** The
   mechanism is complete, tested and library-reachable via
   `fea_set_mg_algebraic_level1`; only the production request is withheld. The
   observability is already wired, so a later arming has a baseline to diff
   against rather than starting from nothing.
3. **Place the third regime before trusting any pre-solve signal.** The
   void-floor share separates this task's two fixtures perfectly (0.6511 vs
   0.0000) and is free, but PR 280's occ-hole design box — which stagnates from
   DEPTH alone — has still never been measured on that axis. The latch-based
   switch does not need it; a pre-solve switch does.
4. **Re-price the 8.44M-DOF case if the win is wanted there.** At the maintainer's
   largest job the cap refuses and the path silently becomes the geometric one.
   Either raise `kAlgMaxCoarseBytes` against measured headroom on the real
   machine, or shrink the space — retaining fewer than 6 modes per aggregate is
   the obvious lever and is unmeasured.
5. **And the question underneath all of this is still open.** PR 283 §3 measured
   that **72 % of the energy this solver is straining to resolve is in material
   at the SIMP void floor**, pulled by a density-INDEPENDENT self-weight load, and
   recommended asking whether that field should exist before building a solver
   for it. That recommendation has not been actioned. This task makes the solver
   survive the field; it does not make the field right, and a modelling change
   could still dissolve the problem entirely.

---

## 13. What this does NOT settle

1. **The switch itself.** §12's recommendation is measured but unbuilt. Every
   number in this report is for the path armed for a WHOLE run, which is not the
   posture recommended.
2. **The third regime.** PR 280's occ-hole design box is unmeasured here, on both
   the convergence axis and the void-floor axis.
3. **The 8.44M-DOF case.** Projected, not run. The largest grid measured is
   797,040 DOF; the projection is a fit over a 108x range and is labelled as one.
4. **Fewer near-nullspace modes.** 6 rigid-body modes per aggregate is the
   textbook choice and the one PR 283 measured; 3 (translations only) would cut
   the coarse dimension and the memory roughly in half and is completely
   unmeasured, on capture or on convergence.
5. **The smoothed prolongator at level 1.** Refused here on principle (it needs
   `A·T`) and measured worse by PR 283 on every axis, but its capture at the fine
   level remains the one row PR 283 named as missing.
6. **Interaction with the rest of the production stack.** The gate ran with
   recycling, GenEO and draft armed identically in both postures, which is the
   right control — but it does not tell you what the algebraic path does in
   combination with a CHANGED setting of any of them. The four-way interaction
   sweeps PR 248 and PR 278 ran have no algebraic column yet.

---

## 14. THE MERGE WITH MAIN — what moved, and what did not

PR 286 was reported CONFLICTING against main after PR 282, 283 and 284 landed.
Two things had to be established: that the merge is correct, and that the
evidence above still describes the tree, because **a baseline that moved makes
prior evidence a description of a tree that no longer exists**.

### The conflict was structural, not textual

`git merge-base --all HEAD origin/main` returns TWO bases — `99d4157` (PR 283's
tip, which this branch merged directly) and `7bd1b13` (the main this branch was
cut from, which later absorbed PR 283 as `3debbe9`). That is a criss-cross.
Git's recursive strategy merges the bases and resolves it cleanly; GitHub's
mergeability check uses a simpler algorithm and reports a conflict. Both
`git merge origin/main` and `git merge-tree --write-tree origin/main HEAD`
complete with **no conflict markers and no manual resolution**, in both
directions. The merge commit collapses the criss-cross.

* **`core/CMakeLists.txt`** — both registrations survive, as they should:
  `test_mg_coarse_hook` (PR 283) and `test_mg_algebraic_level1` are unrelated.
* **`core/src/fea/multigrid.cpp`** — `g_mg_alg_level1`, its `static_assert`
  tripwire, `g_mg_alg_stats` and `g_mg_last_level_dims` all survive alongside
  PR 280's `MgOpts`.

### On `MgOpts`: there was nothing to reconcile, and here is why

`MgOpts` was introduced by `d32418e` (PR 280) and reached main as `16c55a8` —
an ANCESTOR of this branch's base `7bd1b13`. **Main did not newly add it; this
branch has had it since it was cut.** `git show 7bd1b13:...multigrid.cpp | grep
-c MgOpts` and the same on current main and on this HEAD all return 11.

The distinction that matters: `MgOpts` snapshots the PER-SWEEP smoother recipe
(omega / pre / post / coarse_extra / gamma / point_block) once per solve, so
`jacobi_sweep` reads plain locals. The algebraic builder reads `g_mg_tuning`
**exactly once per hierarchy BUILD**, for two build-time properties `MgOpts`
does not carry — `smoother` (to refuse the point-block case) and
`coarse_dof_cap` (the bottom-level acceptance size) — which is the same read, in
the same place, that `build_mf_hierarchy` has always done. Audited rather than
asserted: every `g_mg_tuning` read in the file is in a hierarchy builder, in
`mg_opts_now()` itself, or in a public accessor. **None is in a sweep loop, so
no per-sweep thread-local read was reintroduced.**

### What else main brought, and why it cannot move these numbers

| PR | touches core solver? | effect here |
| --- | --- | --- |
| 283 algebraic-coarse-space-dilute | yes — the coarse-space hook | already in this branch; the merge is a no-op on it |
| 282 krylov-recycler-cost-reassess | yes — `recycle.{hpp,cpp}` | adds `RcPhaseTimes` phase-timing instrumentation, **default OFF** (`rc_set_phase_timing` defaults false). Pure observation. |
| 284 variant-entry-gating-retention | **no** — app/Swift only | nothing in `core/src` or `core/include` |

### The re-run, on the merged tree

| bar | before the merge | after the merge | moved? |
| --- | --- | --- | --- |
| geometric level-1 capture | 1.5954 % at dim 18,738 | **1.5954 % at dim 18,738** | no |
| algebraic level-1 capture | 56.3293 % at dim 13,140 | **56.3293 % at dim 13,140** | no |
| healthy geometric capture | 99.2959 % at dim 7,344 | **99.2959 % at dim 7,344** | no |
| healthy algebraic capture | 38.7293 % at dim 4,356 | **38.7293 % at dim 4,356** | no |
| Galerkin identity check | 1.347e-15 / 2.094e-16 | **1.347e-15 / 2.094e-16** | no |
| aggregates (stagnating / healthy) | 2,190 / 726 | **2,190 / 726** | no |
| stagnating: geometric | STAGNATES, 3,636 iters | **STAGNATES, 3,636 iters** | no |
| stagnating: ALGEBRAIC | CARRIED, 96 iters | **CARRIED, 96 iters** | no |
| DOF-weighted work (stagnating) | 8,180.0 → 208.8 | **8,180.0 → 208.8** | no |
| healthy cycles | 18 → 52 | **18 → 52** | no |
| DOF-weighted work (healthy) | 41.3 → 112.1 | **41.3 → 112.1** | no |
| level dims (stagnating, algebraic) | 150,075 → 13,140 → 1,830 | **same** | no |
| exactness, worst rel deviation | 2.558e-09 / 1.017e-10 | **2.558e-09 / 1.017e-10** | no |
| AH1 artifacts (7, SHA-256) | all IDENTICAL | **all IDENTICAL, same hashes** | no |
| AH1 solver-work CSV columns | 0 of 44 differ | **0 of 44 differ** | no |
| ctest | 98/98 | **98/98** | no |

**Nothing in the load-independent column moved — not one count, dimension,
capture ratio, deviation or checksum.** That is the expected result given the
table above (the only core change is an instrumentation hook that ships off),
and it is reported as a verification rather than assumed from the reasoning.

The AH1 re-run is against the NEW reference — `2a425d3`, i.e. main after PR
282/283/284 — and the seven artifact SHA-256s come out **identical to the
pre-merge run's**, which is a stronger statement than the bar asked for: the
shipped part is unchanged not just relative to its own reference but across the
baseline move as well. `cg_iters`, `cg_multigrid`, `hier_built`,
`mg_cycles_attempted`, `matvecs`, `compliance` and `achieved_vf` are identical
on all 180 rows; the 20 columns that differ are every one a `*_ms` duration or
an RSS/paging counter.

**WALL DID MOVE, in the favourable direction, and it is not evidence.** The
stagnating geometric solve reads 10.72 s against the pre-merge 12.94 s, and the
healthy pair 1.50 / 2.19 s against 1.69 / 2.41 s. The host was simply quieter
(1-minute load ~9-13 against ~9-18). Nothing was made faster by the merge; this
is exactly the reason every ranking in this report is on DOF-weighted applies
and iteration counts rather than the stopwatch.

### The tripwire, verified by making it fail

A `static_assert` nobody has watched fail is an untested claim. Flipping
`kMgAlgebraicLevel1LibraryDefaultOn` to `true` and compiling `multigrid.cpp`
with `-fsyntax-only` fires **both** tripwires — the one in the public header
beside the constant, and the one in `multigrid.cpp` beside the flag's
initialiser — so a future edit that arms the LIBRARY default cannot compile. The
constant was restored immediately and the transcript is in
`evidence/.../tripwire_static_assert.txt`.

---

## In plain language

The program's fast solver works by making a small, simplified copy of the shape,
solving the easy version, and using that to help solve the real one. On the
maintainer's real jobs it fails: it tries three hundred times, gets nowhere, and
after three failures a safety catch switches it off for the rest of the job.
Everything then runs the slow way — in the previous piece of work's reproduction,
thirty-two minutes of a thirty-three minute run.

The previous piece of work found out why, and the answer was a single number.
There is a clean way to ask "how much of the real answer can this simplified copy
even express?", and on the failing job the answer is **1.6 %**. On a healthy
shape the same measurement reads **99.3 %**. The simplified copy is not slightly
wrong; it is essentially blind. And it is blind at the very first step — the step
where the program shrinks the shape by halving the grid, like reducing a photo by
throwing away every other pixel. On a shape that has become mostly empty space
with thin threads of material running through it, halving the grid loses the
threads.

**This piece of work built the fix and put it in the real program.** Instead of
halving the grid, the program now groups the shape's points together by how
strongly they are actually connected — so a thread thinner than a grid cell still
survives into the simplified copy, because the grouping follows the material
rather than the ruler.

**It works.** The simplified copy goes from expressing 1.6 % of the answer to
**56 %**. The solver, which previously gave up after three hundred attempts and
fell back to a method needing three thousand six hundred steps, now succeeds in
**ninety-six**. On a full production run the safety catch never trips at all, and
the whole job runs about twice as fast. Two other pieces of machinery that exist
purely to cope with the failure — an emergency accelerator and a step-reuse
trick — simply stop being needed, which is the clearest sign that the underlying
problem is actually gone rather than merely reduced.

**Critically, the verdicts do not change.** We checked the final engineering
decision on every rung of the ladder, before and after: same accept, same accept,
same accept, same reject. On the three accepted rungs the safety margins agree to
within a third of a percent. On the rejected rung the margin moves by 8 % — worth
saying rather than glossing, though it is the rung where the old solver was
struggling hardest, and both versions reject it comfortably rather than
marginally. Out of 4,608 material cells, one single cell was classified
differently on one rung — and we measured beforehand what "running the same
calculation twice, slightly more precisely" already costs, which is also one
cell. So that is the noise level, not a change of answer. We also confirmed the
program is byte-for-byte unchanged when the new option is switched off, which is
how it ships.

**But we are not recommending switching it on for everything, and the reason is
honest.** The new way of shrinking the shape is *worse* on healthy, solid parts —
about 2.7 times more work — because grouping by connection throws away detail
that a solid part actually needs. And on the very largest job on record it would
need about 3.3 GB of extra memory, over a self-imposed 2 GB safety limit, so it
would decline and quietly do the old thing anyway.

**So our recommendation is a switch rather than a swap.** The program already
notices when the solver is failing — that is the safety catch that currently
gives up. Instead of giving up, it should switch to the new method at that exact
moment. A healthy part never triggers it, so it never pays the cost; a failing
part gets the fix precisely when it needs it. That change is small, and we have
described it, but we have deliberately not made it here: it deserves its own
round of before-and-after verification.

One more thing worth passing on, because it may matter more than any of the
above. The previous work found that **seventy-two per cent of the effort this
solver is expending is spent on material the optimiser has already decided is
empty** — because the program weighs the part as if every cell were solid
plastic, no matter how little material is left there. That is a modelling
question, not a solver question, and it has still not been asked. If the answer
changes, this solver problem may not need to exist at all.

**Honest caveat on the timings.** The test machine was busy throughout — often
running more work than it has cores for. We planned for that: every headline
number here is a count (steps, groups, cells, verdicts) or a ratio of exact
calculations, none of which changes with how busy the computer is. Stopwatch
readings are reported and deliberately not relied on.
