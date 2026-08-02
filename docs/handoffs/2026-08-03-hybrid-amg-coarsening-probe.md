# Can an ALGEBRAIC coarse space rescue the dilute regime?

**Task:** `hybrid-amg-coarsening-probe` · **Evidence:** `evidence/2026-08-03-hybrid-amg-coarsening-probe/`
**Kind:** MEASUREMENT. Adds ONE harness-only seam to the solver (a coarse-space
hook, default uninstalled) plus its tripwire test. Changes NO default, no gate,
no fixture, no assertion. Proven bit-identical (§7).

---

## The answer, first

**No — and the measurement says why, in one number.**

On PR 280's exact stagnating field, the GEOMETRIC level-1 coarse space —
`range(P0)`, the one level this task was told to keep — captures **1.5954 % of
the exact solution's energy**. Every space built below level 1 is a SUBSPACE of
it, so **1.5954 % is a hard ceiling on anything algebraic aggregation from A1 can
reach**. The measurement walks right up to that ceiling and stops: an algebraic
level 2 pushed to 18,688 of level 1's 18,738 dimensions captures 1.5952 %.

**The hypothesis is aimed one level too low.** PR 280's diagnosis — "the coarse
space is wrong, not the recipe around it" — is CONFIRMED and SHARPENED: the wrong
coarse space is `range(P0)`, formed at the very first halving, not the levels
built beneath it.

**Algebraic aggregation works exactly as the literature says it should. It is
just working on a space that is already 98.4 % blind.** At matched coarse
dimension it captures **1.74x more** than geometric halving (0.7661 % at
dim 2,351 vs 0.4402 % at dim 2,364) — a real, reproducible advantage of
aggregates over halving on a dilute field, and worth nothing here.

**The healthy control is what makes the number legible.** On a well-connected
block at rho 0.6 the same instrument reads **99.2959 %** at geometric level 1.
The instrument is not pessimistic; the field is.

**And it explains PR 280's decisive datum exactly.** PR 280 found levels 2, 3, 4,
5 and MAX all producing an IDENTICAL 4,841 applies. Its `levels=2` cell is a
two-grid method whose coarse space IS `range(P0)`, solved EXACTLY by a direct
factorisation — and it stagnated like the rest. It had to: an exact solve on a
space that sees 1.6 % of the answer leaves 98.4 % for damped Jacobi alone.

### The two things this found on the way, which matter more than the answer

**1. An ALGEBRAIC LEVEL 1 captures 56.3 % — and CONVERGES in 86 iterations.**
Aggregating from the FINE operator instead of halving it (matrix-free, A0 never
assembled) lifts the level-1 capture from 1.5954 % to **56.3293 % at a SMALLER
coarse dimension** (13,140 vs 18,738) — **35x**. Solved, that hierarchy takes
**86 PCG iterations to the production tolerance where the shipped V-cycle
stagnates at 300 and falls back**, and where the exact Jacobi-CG reference needs
**3,636**. It adds **45.6 MB** at 150k DOF. The fix exists; it is at level 1.

**2. 72 % of the energy the solver is asked to resolve is in material at the
SIMP void floor.** 95.4 % is in elements below rho = 0.02. The mechanism is not
subtle: self-weight loads are **density-INDEPENDENT** (`assembly.cpp:88` lumps
`gravity * material_density * voxel_volume / 8` onto every solid-TAGGED voxel)
while stiffness is `rho^3` — so at the floor the load is full PLA and the
stiffness is 1e-9 of solid. Hence `max|u| = 4.5e+04 mm` on an 80 mm part. That
is documented behaviour (`minimize_plastic.cpp:258-266` states it), not a bug
found — but it is the reason the field is unsolvable, and it deserves its own
task (§8).

---

## 1. AF1 — the diagnosis, tested BEFORE the fix was built

### The instrument

For an SPD system `A0 u = b`, the A-orthogonal projection of the exact `u` onto a
coarse space `range(W)` is `W z` with `(W^T A0 W) z = W^T b`, and its energy is
`z . (W^T b)`. The exact solution's energy is `u . b`. Their ratio is the fraction
of the solution's energy the coarse space can represent; **1 minus it is exactly
what the smoother is left to remove alone.** No modelling, no fitting, one sparse
solve per space. Because `range(P0 P1) ⊆ range(P0)` for any `P1`, and the
projection energy is monotone in the subspace, **level 1's capture is a hard
upper bound for every level below it** — which is what turns this measurement
into a decision.

Three things make the reading trustworthy rather than merely plausible:

* **The reference `u` is exact.** Matrix-free Jacobi-CG at the production
  certification tolerance 1e-8: **3,636 iterations, residual 9.137e-09,
  max|u| = 4.4905e+04** — the same 3,636 and the same 4.5e+04 PR 280 reported on
  the same field. The probe REFUSES to report a capture if the reference did not
  converge.
* **`P0` and `A1` are the solver's own**, read at the seam as
  `build_mf_hierarchy` forms them, not re-derived. `P0` is 150,075 x 18,738
  (478,137 nnz); `A1` is 18,738 x 18,738 (1,351,836 nnz).
* **`A1` is VERIFIED to be the Galerkin operator of `P0`**, not assumed: for a
  random `z`, `z^T A1 z` is compared against `(P0 z)^T A0 (P0 z)` through the
  production matrix-free apply. Agreement **1.29e-15 relative**. That check
  licenses every number below, and the probe stops if it fails.

### The expected number, stated before the measurement

The probe's file header, written before the first run, says the geometric level-1
space should capture MOST of the energy, level 2 materially less, and algebraic
aggregation at matched dimension should recover part of the gap — and names the
alternative: *"If instead LEVEL 1 ITSELF is already the deficient space, this
task's hypothesis is aimed one level too low, and that is the finding."*

**That alternative is what happened.** The expectation of a high level-1 capture
was wrong by a factor of about sixty.

### The numbers

Field: PR 280's `ladder32` reproduction, design-iteration snapshot 2 of 80,
solved grid **48x32x40**, `achieved_vf` **0.0368**, 150,075 reduced DOFs.

| coarse space | dim | captured energy |
| --- | ---: | ---: |
| **geometric level 1** (`range P0`) | 18,738 | **1.5954 %** |
| geometric level 2 (13x9x11 nodes) | 2,364 | 0.4402 % |
| geometric level 3 (7x5x6 nodes) | 285 | 0.0700 % |

The same three rows on the HEALTHY control (rho 0.6, 32x16x32, 53,856 DOFs):

| coarse space | dim | captured energy |
| --- | ---: | ---: |
| geometric level 1 | 7,344 | **99.2959 %** |
| geometric level 2 (9x5x9) | 1,080 | 97.2898 % |
| geometric level 3 (5x3x5) | 180 | 91.8493 % |

**99.30 % against 1.60 %.** That contrast is the finding.

---

## 2. AF2 — does algebraic aggregation capture more? Yes, and it does not matter

Aggregation from `A1`: Vanek strength test on the 3x3 nodal blocks, 6 rigid-body
modes, smoothed and unsmoothed prolongators, swept over the strength threshold so
the comparison lands at MATCHED coarse dimension rather than at whatever one
theta happens to give.

| coarse space | dim | captured energy |
| --- | ---: | ---: |
| geometric level 2 | 2,364 | 0.4402 % |
| **algebraic level 2, theta 0.04, smoothed** | **2,351** | **0.7661 %** |
| algebraic level 2, theta 0.04, P = T | 2,351 | 0.7154 % |
| algebraic level 2, theta 0.02, smoothed | 1,948 | 0.6335 % |
| algebraic level 2, theta 0.08, smoothed | 3,049 | 0.9434 % |
| algebraic level 2, theta 0.12, smoothed | 4,671 | 1.1224 % |
| algebraic level 2, theta 0.20, smoothed | 14,813 | 1.5562 % |
| algebraic level 2, theta 0.30, smoothed | 18,688 | **1.5952 %** |
| *(the ceiling: geometric level 1)* | *18,738* | *1.5954 %* |

Two readings, and the second ends the task:

1. **Aggregation beats halving at equal size, by 1.74x** (0.7661 % vs 0.4402 % at
   ~2,360 dimensions). Peetz & Elbanna are right that aggregates follow the
   structure where a halved grid cannot. Smoothing the prolongator adds a further
   ~7 % relative over `P = T` at every matched size.
2. **It converges to level 1's ceiling and stops there.** At theta 0.30 the
   aggregation keeps 18,688 of 18,738 possible dimensions — essentially all of
   level 1 — and captures 1.5952 % against level 1's 1.5954 %. **There is nothing
   below level 1 to find, because there is nothing in level 1 to find.**

This is AF2's stop condition, reached from an unexpected direction: not "algebraic
does not capture materially more", but "materially more of 1.6 % is still 1.6 %".

---

## 3. WHERE THE ENERGY ACTUALLY IS — the reason for the 1.6 %

A 1.6 % capture is a startling number, and a report that leaves it unexplained
invites the wrong fix. Strain energy is exactly additive over elements —
`sum_e factor_e (u_e^T Ke u_e) = u^T A0 u` — so "which material holds the
energy?" is one O(N) sweep of the production element table, with the identity as
its own check. **It closes to 5.78e-09 relative.**

| density bin | elements | share of energy | cumulative |
| --- | ---: | ---: | ---: |
| **rho < 0.0015 (the SIMP void floor)** | **30,043** | **72.2477 %** | 72.25 % |
| 0.0015 <= rho < 0.005 | 1,638 | 11.8465 % | 84.09 % |
| 0.005 <= rho < 0.02 | 1,911 | 11.3380 % | **95.43 %** |
| 0.02 <= rho < 0.05 | 2,062 | 4.4875 % | 99.92 % |
| 0.05 <= rho < 0.10 | 1,918 | 0.0757 % | 100.00 % |
| 0.10 <= rho < 0.30 | 8,535 | 0.0047 % | 100.00 % |
| 0.30 <= rho < 0.60 | 0 | 0 | |
| rho >= 0.60 (solid) | 32 | 0.0000 % | 100.00 % |

On the healthy control the same sweep reads **100.0000 % in rho >= 0.60**, with
the identity closing to 4.22e-15.

**65 % of the design elements sit at the void floor and carry 72 % of the
energy.** The near-null-space this V-cycle has to represent is therefore not a
smooth structural mode at all — it is near-independent motion of tens of
thousands of nearly-free elements. No coarse space of dimension n/8 built by
interpolation can hold that, which is precisely what the 1.6 % says.

### Why the void is loaded at all

`self_weight_loads` (`core/src/fea/assembly.cpp:70-104`) lumps
`gravity * material.density_g_cm3 * voxel_volume / 8` onto the eight corners of
**every solid-TAGGED voxel**, with no dependence on the design density; and
`minimize_plastic.cpp:258-266` computes it ONCE and holds it fixed across rungs,
its own comment stating that "with a design box the weight covers the frozen part
plus the Active design envelope, held fixed across rungs". Stiffness meanwhile is
`rho^p` with `rho_min = 1e-3`, `p = 3` — a 1e-9 floor.

So a floor-density element is pulled with the weight of solid PLA through a
stiffness one part in a billion. That is the whole of `max|u| = 4.5e+04 mm` on an
80 mm part, and 95 % of the compliance the optimiser is minimising.

**This is documented behaviour, not a defect this task discovered**, and changing
it is out of scope here. It is flagged because it is the mechanism, and because
the classical self-weight-TO literature (Bruyneel & Duysinx 2005) names the
density-independent body force as the standard parasitic-load trap. §8 carries it
as an open question.

---

## 4. The one-level-up control — is it aggregation that fails, or the level?

AF2's stop rule exists so nobody builds a solver on a dead hypothesis. But
stopping at "aimed one level too low" leaves the obvious question unanswered:
**would an ALGEBRAIC LEVEL 1 capture more?** So the same instrument was pointed
one level up.

**This does NOT trip the BLOCKED-STOP.** `amg_lean.hpp` (PR 230's lean rebuild)
streams the fine strength graph, the prolongator and the Galerkin product
ELEMENT-LOCALLY off the production `MatfreeReduced` — the same element table
`multigrid.cpp` already uses to form `A1`. **A0 is never assembled**, which is
exactly the condition the blocked-stop names ("if aggregation from A1 requires
assembling anything at level 0, STOP — that is pure AMG"). Nothing here is armed
or proposed for production; the rows exist to say whether a follow-on task is
worth commissioning.

### Capture

| level-1 space | dim | captured energy |
| --- | ---: | ---: |
| geometric (shipped, halving) | 18,738 | 1.5954 % |
| **algebraic, theta 0.02, P = T** | **13,140** | **56.3293 %** |
| **algebraic, theta 0.08, P = T** | **21,252** | **61.7518 %** |

**35x the capture at a SMALLER coarse dimension.** The smoothed-prolongator cells
were skipped by the probe's stated 10 s budget for this sweep and reported as
skipped: a smoothed FINE-level prolongator densifies its Galerkin operator by
~3x, and factoring that directly is the most expensive thing in this probe. They
are not unmeasured — the convergence table below measures them by the more
relevant instrument.

### Convergence — the capture number, cashed

`amg_lean`'s own matrix-free hierarchy and PCG over the PRODUCTION reduced
operator (`FineMF::apply` IS `m.apply_kgg_raw`). Reported as an amg_lean
measurement, not as a production V-cycle: its fine smoother is Chebyshev where
production's is damped Jacobi, and its coarse levels use symmetric Gauss-Seidel.
What it licenses is "converges vs stagnates", not a wall ratio against the
shipped solver.

| configuration | levels | PCG its | converged | setup s | solve s | rel \|du\| | AMG adds |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| **theta 0.02, P = T** | 4 | **86** | **YES** | 0.606 | 2.975 | 6.33e-09 | **45.6 MB** |
| theta 0.08, P = T | 3 | 292 | YES | 0.733 | 19.811 | 2.83e-09 | 61.3 MB |
| theta 0.02, smoothed | 2 | 243 | YES | 7.713 | 40.013 | 2.80e-09 | 149.8 MB |
| theta 0.08, smoothed | — | — | **NOBUILD** | 11.373 | — | — | — |
| *shipped geometric V-cycle (§5)* | — | *300* | ***STAGNATES*** | — | — | — | — |
| *exact Jacobi-CG reference* | — | *3,636* | *YES* | — | — | — | — |

Level shapes for the winner: `L0 150,075 (matrix-free) -> L1 13,140 (1.41M nnz)
-> L2 1,830 (165k nnz) -> L3 690 (41k nnz)`.

Three readings:

* **86 iterations against a stagnation.** The shipped hierarchy cannot converge
  on this field at any depth, smoothing, cycle or smoother (PR 280, 25 cells).
  An algebraic level 1 converges to the production tolerance, at 42x fewer
  iterations than the plain Jacobi-CG the solver currently falls back to.
* **PR 230's `P = T` finding reproduces exactly.** Unsmoothed beats smoothed on
  every axis here: 86 vs 243 iterations, 45.6 vs 149.8 MB, 0.6 vs 7.7 s setup —
  and at theta 0.08 the smoothed variant is REFUSED outright by amg_lean's own
  coarsening control (444 nnz/row past its 400 cap).
* **Capture is necessary, not sufficient.** theta 0.08 captures MORE (61.75 % vs
  56.33 %) and needs MORE iterations (292 vs 86), because its hierarchy degrades
  below level 1 — level 3 rejected on coarsening ratio, bottom level 8,544
  smoothed rather than solved. A good level-1 space still needs a working stack
  under it.

---

## 5. AF3 / AF4 / AF5 — the hybrid, run on the real field

The prediction from §1-2 is that a hybrid whose level 1 stays geometric CANNOT
converge, whatever aggregation is used below it. Run through the PRODUCTION
solver via the seam, on the same field, that prediction is exactly what happens.

**AF3 — cycles to convergence against the 300-cycle budget.** Same field, same
production solver, the only change being where the levels below 1 come from:

| configuration | cycles | outcome | DOF-wtd work | nnz-wtd work | build s | aggr s | cycle s |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| SHIPPED (geometric) | 300 | **STAGNATES** | 1017.1 | 1003.8 | 0.522 | — | 6.629 |
| algebraic, theta 0.02, smoothed | 300 | **STAGNATES** | 1016.3 | 1012.3 | 0.801 | 0.163 | 3.679 |
| algebraic, theta 0.08, smoothed | 300 | **STAGNATES** | 1018.5 | 1027.5 | 1.468 | 0.252 | 4.411 |
| algebraic, theta 0.20, smoothed | 300 | STAGNATES *(chain refused -> geometric)* | 1042.0 | 1270.8 | 2.396 | 1.191 | 3.260 |
| algebraic, theta 0.02, P = T | 300 | **STAGNATES** | 1016.3 | 1004.7 | 0.540 | 0.043 | 3.243 |
| algebraic, theta 0.08, P = T | 300 | **STAGNATES** | 1018.5 | 1007.6 | 0.718 | 0.043 | 5.279 |
| algebraic, theta 0.20, P = T | 300 | STAGNATES *(chain refused -> geometric)* | 1121.8 | 1116.7 | 0.691 | 0.094 | 6.240 |

**Six configurations, zero convergences**, on top of PR 280's 25. The prediction
from the capture measurement is confirmed by the solver: nothing below level 1
can rescue a level-1 space that sees 1.6 % of the answer.

Two of the seven rows are marked **chain refused**: at theta 0.20 the aggregation
stalls with a bottom level above the solver's 6,000-DOF direct-solve cap, so
`build_hierarchy_from_prolongators` rejects it and the geometric builder runs
instead. Those rows are GEOMETRIC rows wearing an algebraic label and the probe
says so rather than reporting them as the hybrid — the same refusal path the
tripwire test exercises with five malformed prolongators.

**AF4 — cost, in both currencies.** The DOF- and nnz-weighted columns are
FINE-LEVEL-APPLY EQUIVALENTS: one V-cycle's work summed over levels, weighted by
each level's DOF count (respectively nonzeros, against the 12,156,075-entry
assembled equivalent of the matrix-free fine operator — 81 per row for a hex-8
27-point stencil, stated as the proxy it is), multiplied by the cycles run.

* **The hybrid is not free and not expensive**: 1016-1122 DOF-weighted units
  against the shipped 1017. Below level 1 there is simply too little work for the
  choice to matter — level 2 is ~2-16 % of level 1's DOFs, which is itself 12 %
  of the fine level. **That is the same fact the capture measured, seen from the
  cost side.**
* **Aggregation setup is charged explicitly**, per the bar: **0.043-0.252 s**
  against a **0.522-1.468 s** hierarchy build and a ~3-7 s cycle loop. On this
  dilute fixture the build is ~3-9 % of the solve, not PR 273's healthy-regime
  26.4 % — PR 280 measured the same inversion (~2 % here vs 39.9 % on a healthy
  4-level run), because a stagnating solve's wall is dominated by the fallback.
  On the HEALTHY control (§6) the aggregation costs 0.031-0.506 s against a
  1.29 s geometric build, i.e. **2-39 % of the build**, which is where it would
  actually be paid.
* **The smoothed prolongator is the one that costs**: 1.191 s of aggregation and
  a 1270.8 nnz-weighted cycle cost at theta 0.20, against 0.094 s and 1116.7 for
  `P = T`. PR 230's finding again.

**AF5 — memory.** Reported as what the hybrid ADDS, because level 1 is
production's cost either way.

| configuration | L1 | below L1 | projected to 8.44M DOF (below L1) |
| --- | ---: | ---: | ---: |
| SHIPPED (geometric) | 15.54 MB | 1.75 MB | **0.10 GB** |
| algebraic theta 0.02, P = T | 15.54 MB | 2.12 MB | **0.12 GB** |
| algebraic theta 0.08, P = T | 15.54 MB | 3.50 MB | 0.19 GB |
| algebraic theta 0.02, smoothed | 15.54 MB | 5.68 MB | 0.31 GB |
| algebraic theta 0.08, smoothed | 15.54 MB | 12.74 MB | 0.70 GB |
| algebraic theta 0.20, smoothed | 15.54 MB | 125.58 MB | **6.90 GB** |

Level 1 itself projects to **0.85 GB** at 8.44M DOF. Measured peak RSS for the
whole probe process, which holds the reference field, the seam copy and every
hierarchy it builds: **0.96 GB**.

**Against PR 230's 20-35 GB for pure AMG: the hybrid costs 0.12 GB extra at the
unsmoothed setting and 0.85 GB for the level-1 operator production already
builds.** Memory was never the obstacle to this design — the coarse space was.
The one row that would have been a problem is smoothed aggregation at theta 0.20,
at 6.90 GB projected, and it is also the worst-performing row.

The projection is a LINEAR extrapolation by DOF ratio and is labelled as one:
level 1 is a fixed 1/8 vertex coarsening of the fine grid, and each algebraic
level below was a fixed fraction of level 1 *on this field*. A different field
aggregates differently.

---

## 6. AF6 — the healthy case

A well-connected block at rho 0.6, 64x32x64 (418k DOFs), where geometric
multigrid converges today. **The hybrid does not break it — and it is not free.**

| configuration | levels | cycles | carried | DOF-wtd work | build s | aggr s | TOTAL s | rel \|du\| |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| **SHIPPED (geometric)** | 4 | **18** | YES | **62.1** | 1.292 | — | **1.727** | 1.79e-10 |
| algebraic theta 0.02, smoothed | 3 | 22 | YES | 74.9 | 2.111 | 0.358 | 2.738 | 2.41e-10 |
| algebraic theta 0.08, smoothed | 3 | 22 | YES | 74.9 | 2.603 | 0.506 | 4.173 | 1.93e-10 |
| algebraic theta 0.02, P = T | 3 | 26 | YES | 88.5 | 1.581 | 0.094 | 2.252 | 1.87e-10 |
| algebraic theta 0.08, P = T | 3 | 24 | YES | 81.7 | 1.568 | 0.089 | 2.244 | 2.11e-10 |
| algebraic theta 0.20 (both) | 4 | 18 | YES | 56.4 | — | — | — | 1.79e-10 |

The last row is a **chain refused -> geometric** fallback (the aggregation
produced a single level and the solver rejected it), so it IS the shipped
hierarchy and reports shipped numbers.

**The hybrid is a 21-42 % LOSS on the healthy field** — 22-26 cycles against 18,
74.9-88.5 DOF-weighted units against 62.1 — plus 0.089-0.506 s of aggregation
setup on top of the build. Every configuration still carries and still reaches
the same field. Wall (1.86-4.17 s against 1.73 s) agrees in sign but the host was
at load 13-18 and no ranking rests on it; the DOF-weighted column is the one to
read, and it is unambiguous.

**This is the expected direction and it matters.** Geometric coarsening is the
right coarse space for a well-connected field — it captures 99.30 % there — so
anything armed must be a SWITCH, never a replacement.

### A cheap switching signal?

AF6 asks for one if it can be measured. **Two candidates, and one honest caveat.**

* **The runtime signal already exists.** `multigrid.cpp`'s stagnation latch fires
  after `kMgLatchThreshold == 3` consecutive stagnations and is what this task's
  fixture trips at design iteration 3. What has been missing is not a detector
  but something to switch TO; §4 is the first measured candidate.
* **A pre-solve signal that separates the two fixtures cleanly: the share of
  design elements at the SIMP void floor.** Stagnating field: **65.1 %**
  (30,043 of 46,139 below rho = 0.0015). Healthy control: **0 %**. It is free —
  one pass over the density vector the solver is already handed.
* **The caveat, stated plainly: two points do not establish a threshold.** PR 280
  found a THIRD regime (the occ-hole design box) where the V-cycle stagnates from
  DEPTH alone and the ordinary component levers rescue it — a switching rule has
  to place that case too, and this task did not measure its void-floor share.

---

## 7. Bars

### AF8 — no production change, proven three ways

The seam is `fea_detail::MgCoarseSpaceHook` (`core/src/fea/fea_matfree.hpp`),
default-uninstalled and thread-local like `mg_set_tuning` and the stagnation
latch. `build_mf_hierarchy` consults it only inside `if (g_mg_coarse_hook)`, and
even the copy of `P0` out to the seam happens only there. Every prolongator a
hook returns is CHECKED — shape, index range, that it shrinks the level, that the
bottom fits the DOF cap, that the bottom factors — and any failure falls straight
through to `build_hierarchy` unchanged. Only the coarse SPACES come from outside;
the Galerkin products, `R = P^T` and the bottom factorisation stay this file's
own, so the cycle is SPD by the same construction it always was.

* **`tests/unit/test_mg_coarse_hook.cpp`** (new, in CTest as
  `fea_mg_coarse_hook`): asserts the seam is uninstalled by default; that the
  solver REACHES it; that a DECLINING hook leaves the solve **bit-identical**
  (`memcmp`, not a tolerance) at the same level and cycle counts; that **five
  distinct malformed prolongators** are each rejected bit-identically; that a
  valid non-geometric coarse space CHANGES the hierarchy (18 -> 45 cycles) and
  still reaches the same field (rel 2.5e-10); and that clearing restores the
  pre-hook path bit-identically.
* **Stash-rebuild**: the tree at HEAD (`b06da24`) extracted with `git archive`
  and built independently (Release, OCCT on, same compiler); same job, 180
  iterations.

| artifact | result |
| --- | --- |
| `design.bin`, `fields.bin`, `report.json`, `loadcase.json` | **IDENTICAL** |
| `variant_030.stl`, `variant_050.stl`, `variant_070.stl` | **IDENTICAL** |
| `iterations.csv` | 180 rows, identical header, **ZERO non-timing columns differ** |
| `build_orientation.json` | only `sweep_seconds` — pre-existing (PR 273 records it differing on every pair, including ON-vs-ON2) |
| `run_info.json` | only the build fingerprint and `created_wall_ms` |

The CSV check is column-by-column: `cg_iters`, `cg_multigrid`, `hier_built`,
`mg_cycles_attempted`, `matvecs`, `compliance` and `achieved_vf` are identical on
all 180 rows — the direct statement that the solver did the same work.

* **ctest: 97 tests, 97 passed, 0 failed** (`evidence/.../ctest.txt`), including
  the new `fea_mg_coarse_hook` at 2.50 s. The suite has grown since PR 280 ran it
  (94 tests then, of which one — `build_direction` — was a pre-existing wall-ratio
  flake under host contention); `build_direction` passed here in 1.63 s.

**No assertion was weakened or deleted anywhere in this task.**

### AF7 — exactness

Every configuration is compared against the exact matrix-free Jacobi-CG field on
the same system — and compared in the SAME NUMBERING, which is worth stating
because getting it wrong is easy: `FeaSolution::u` is the FULL displacement
vector while the reference is over the KEPT DOFs, so the reference is lifted
through `kept_global` rather than indexed against.

| field | worst relative displacement deviation |
| --- | ---: |
| healthy control (multigrid CARRIES in every row) | **2.41e-10** |
| stagnating field (every row falls back to the exact solve) | **0.00e+00**, exactly |

The healthy row is the meaningful one: there the hybrid V-cycle really did
precondition the CG, at a different cycle count, and reached the same field to
2.4e-10. The stagnating row is exact by construction — every configuration
stagnates and falls back to the same matrix-free Jacobi-CG the reference is.

This is structurally guaranteed rather than lucky: the outer FP64 CG's residual
test defines convergence, and a different coarse space can only change the
iteration count. The tripwire test asserts the same property independently
(rel 2.5e-10 on a deliberately non-geometric coarse space).

### AF9 — determinism

The same hybrid configuration (theta 0.08, `P = T`), run twice on the stagnating
field: same 300 cycles, same carried flag, **same aggregation output (coarse dims
18,738 -> 3,049 both times)** and the same FNV-1a field fingerprint
`c573782fac60eb3b`. The aggregation is deterministic because `amg_sa`'s passes
walk nodes in ascending index order and its accumulators emit sorted columns —
there is no tie-break on anything but the index.

### AB — the fixture, reproduced to the grid

`develop_stepbox` rebuilt PR 273's `ladder32.json` from the same public pieces
`run_job` uses, and the shipped solver behaves on it exactly as PR 280 recorded:

| design iter | hier_built | V-cycles | carried | latched |
| ---: | ---: | ---: | --- | --- |
| 0 | 1 | 83 | YES | |
| 1 | 1 | **300** | no | |
| 2 | 1 | **300** | no | |
| 3 | 1 | **300** | no | **LATCHED** |
| 4-79 | **0** | 0 | no | LATCHED |

Solved grid **48x32x40**; over 80 design iterations, **carried 1, stagnated 3,
latch fired at design iteration 3**, and the run spent **1,931 s of 1,946.7 s in
the Jacobi fallback**. Snapshot 2 — a field the shipped configuration is measured
to stagnate on, and the one PR 280 swept — is what every measurement above uses,
loaded from the SAME cache file `mg_component_sweep` writes, so the two probes
cannot drift apart.

### Host load, recorded rather than assumed away

**The machine was NOT quiet.** Other campaigns ran throughout — including a
`topopt-cli` from an unrelated worktree — and the 1-minute load average reached
**66 on 10 logical cores**. PR 277's discipline is applied: the load average is
printed at the start and end of every measurement and is in every evidence file.

**Every headline number here is load-independent.** Captured energy is a ratio of
two exact solves. Iteration counts, coarse dimensions, nnz and byte counts are
exact. The identity checks (1.29e-15, 5.78e-09) are arithmetic. **Wall is
reported and is not ranked on below about 1.5x.**

---

## 8. What this does NOT settle

1. **The self-weight modelling in a whole-domain design box (§3).** Loads are
   density-independent while stiffness is `rho^3`, so 72 % of the compliance
   being minimised is void sag at the SIMP floor. This is documented, deliberate
   behaviour, and it may well be the intended conservative envelope load — but it
   is also what makes the linear system unsolvable and what 95 % of the objective
   is measuring. Whether the body force should scale with `rho` (the standard
   self-weight-TO treatment) is a PIPELINE question, out of this task's scope, and
   it is now the single highest-value open question this line of work has
   produced. It should be asked before a new solver is built for a system that
   may not need to exist in this form.
2. **Whether the algebraic level 1 survives production.** §4 is a harness
   measurement with amg_lean's smoothers, on ONE field at 150k DOF. Production
   arming needs: the same measurement across a trajectory and across scales; the
   setup cost charged per design iteration against PR 273's 26.4 % geometric
   build; the memory projection re-measured rather than extrapolated; and the
   damped-Jacobi fine smoother production actually ships, not Chebyshev.
3. **The switching rule (§6).** Two fixtures separate cleanly on void-floor
   share; PR 280's depth-stagnating occ-hole regime is a third case nobody has
   placed on that axis.
4. **The smoothed fine-level prolongator's capture**, skipped under the probe's
   stated budget. The convergence table measures it (243 iterations, 149.8 MB,
   or NOBUILD at theta 0.08) and it loses on every axis, so the missing capture
   row would not change the recommendation — but it is missing, and is named as
   missing rather than quietly dropped.
5. **The GenEO alternative.** PR 280's §8 named two structural candidates:
   hybrid coarsening (this task) and reusing GenEO's spectral basis as a
   multigrid LEVEL rather than a deflation block. This task refutes the first as
   posed and points at algebraic level 1; the GenEO-as-a-level option is still
   unmeasured. Note `geneo.cpp` and `recycle.cpp` were untouched here — a
   concurrent task owns the recycler.

---

## 9. RECOMMENDATION

**Do not build the hybrid this task was commissioned to test.** Levels below 1
cannot help: they are subspaces of a space that captures 1.6 % of the answer.
Arming aggregation there would buy a measured 1.74x of nearly nothing and cost a
per-design-iteration setup.

**Commission the level-1 question instead, and ask the modelling question
first.** In order:

1. **Ask whether the field should exist.** 72 % of the energy — and of the
   objective — is void at the SIMP floor being pulled by a density-independent
   body force. That is a half-day investigation in the pipeline, and if the
   answer changes the load model it may dissolve the solver problem entirely.
   PR 281 already showed that keeping the design non-dilute takes the stagnation
   to zero; it flipped gate verdicts because it changed the DESIGN. Changing the
   LOAD MODEL is a different lever nobody has pulled.
2. **If the field stands, price an ALGEBRAIC LEVEL 1** — unsmoothed `P = T`,
   theta ~0.02, matrix-free from the element table. Measured here: 86 PCG
   iterations against a stagnation, 45.6 MB added at 150k DOF, 0.6 s setup. That
   is a real candidate with a real number, and PR 230's infrastructure for it
   already exists in the harness.
3. **Keep the geometric path for healthy fields.** It captures 99.30 % there and
   costs nothing. Whatever gets armed must be a SWITCH, not a replacement.

---

## In plain language

The fast solver at the heart of this program works by making a coarse, simplified
copy of the shape, solving the easy version, and using that to help solve the
real one. On the maintainer's real runs it fails: it tries 300 times, gets
nowhere, and after three failures a safety catch turns it off for the rest of the
job. Everything then runs the slow way — in our reproduction, **32 minutes of the
33-minute run**.

The previous piece of work tried twenty-five different settings and none of them
helped. Its conclusion was that the coarse copy itself is the problem. **This
task's job was to test the obvious fix — build the coarse copies more cleverly,
letting the solver work out which bits of the shape matter instead of just
halving the grid — and to check the diagnosis before building anything.**

So we measured the thing directly. There is a clean way to ask "how much of the
real answer can this coarse copy even express?", and it needs only the exact
answer and one extra calculation. We ran it.

**The coarse copy can express 1.6 % of the answer.** On a healthy, well-connected
shape the same measurement reads **99.3 %**. That is the entire story: the coarse
copy is not slightly wrong, it is essentially blind.

And it is blind at the FIRST step — the very first halving, the one this task was
told to leave alone. Everything built below that first step is a smaller piece of
it, so **no amount of cleverness further down can help**. We proved that the hard
way as well as the easy way: we built the clever coarse copies, pushed them until
they were nearly as big as the first step's copy, and watched them climb to
1.5952 % — against the first step's 1.5954 %. There is nothing further down to
find.

The clever coarsening does work, by the way. At the same size it captures about
**1.74 times** as much as plain halving. It is just 1.74 times as much of almost
nothing.

**Then we found the two things that actually matter.**

First: we pointed the same measurement one level UP, at the first step itself,
and asked what would happen if THAT were built cleverly instead of by halving.
It jumps from 1.6 % to **56 %** — and with a *smaller* coarse copy. We then
actually solved with it. **It converges in 86 steps, where today's solver gives
up after 300 and where the slow fallback needs 3,636.** It costs 46 MB. So there
is a fix, it is affordable, and it is one level above where this task was pointed.

Second, and more important: we asked where the energy in these calculations
actually sits. **Seventy-two per cent of it is in material the optimiser has
already decided is empty** — 95 % is in material below 2 % density. The reason is
that the program computes the weight of the part as if every cell of the design
space were solid plastic, regardless of how much material the optimiser has left
there. So a cell that is 0.1 % material is pulled down with the full weight of
plastic while being a billion times floppier. It sags enormously — the
calculation reports displacements of 45 metres on an 80 mm bracket — and that
sag is most of what the solver is straining to compute and most of what the
optimiser is trying to minimise.

That behaviour is deliberate and documented; we are not reporting a bug. But it
is *why* the problem is unsolvable, and it is a modelling question, not a solver
question. **Our recommendation is to ask that question before building a new
solver** — because if the load model changes, the solver may not need fixing at
all. If it does not change, the level-1 fix above is the measured candidate.

Nothing about how the program behaves was changed. We checked the hard way: built
the version from before this work, ran the same job, compared byte for byte. The
design, the physics and all three 3D-printable files come out identical, and of
the 180 rows in the per-step log the only numbers that differ are stopwatch and
memory readings — every count of solver work is the same.

One honest caveat: the test machine was heavily loaded throughout, at times
running six times more work than it has cores for. We planned for that. Every
headline number here is a ratio of exact calculations or a count of steps —
"1.6 % versus 99.3 %", "86 steps versus gave-up-at-300" — none of which changes
with how busy the computer is. Timings are reported and deliberately not relied
on.
