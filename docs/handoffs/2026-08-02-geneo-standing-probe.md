# Does GenEO pay as an ALWAYS-ON preconditioner, not a rescue?

**Date:** 2026-08-01
**Branch:** `claude/geneo-standing-preconditioner-da5a2f`
**Task:** `geneo-standing-preconditioner-probe`
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang, `-O2`, Release.
**Evidence:** `evidence/2026-08-02-geneo-standing-probe/`
**Scope:** core/ PROBE ONLY. No production arming, no default change, no gate
change. `run_job.cpp` and `minimize_plastic.cpp` untouched.

---

## Verdict: NO. BLOCKED-STOP.

**Standing GenEO reproduces the literature's iteration win in full and still
loses on wall clock, by 1.25x, on the regime the maintainer actually runs.**

Interleaved A/B benchmark (the timing to trust — see the caveat under W1), on the
pinned post-latch fixture at 40x16x41 (26,240 voxels), medians over 8
steady-state design iterations:

| posture | CG per solve | s per solve | |
|---|---|---|---|
| plain latched Jacobi-CG | 906 | **1.112** | 1.000x |
| standing GenEO (core 8^3, shipped tiling) | 241 | **1.389** | **1.249x SLOWER** |
| standing GenEO (core 16^3, best tiling found) | 443 | 1.075 | 1.036x — parity |
| *(for scale†)* **healthy multigrid** | **40** | **0.45** | **~0.4x — 2.5x FASTER** |

† The multigrid row is from a separate run (W7), not the interleaved pair — it
cannot be interleaved, since it is a different solver route on the same problem.
Its margin is far larger than the cross-run timing noise, so the direction is
safe; the exact ratio is not a precision figure.

The hypothesis's first half is CONFIRMED and then some: 906 -> 241 CG
iterations, a **3.8x reduction**, and the deflated count is **flat across grid
sizes** (191 / 202 / 201 / 213 as the grid grows 3,360 -> 51,000 voxels while
plain Jacobi climbs 388 -> 977). That is exactly the contrast/mode-count
independence Alexandersen & Lazarov report, measured here on our own operator.

The hypothesis's second half is REFUTED. The iterations GenEO removes cost less
than the machinery that removes them. Per design iteration at the shipped
tiling:

```
  coarse refresh    0.66 s   <-- paid EVERY design iteration (N_t matvecs)
  deflation apply   0.46 s   <-- paid EVERY CG iteration
  CG itself         0.29 s
  ---------------------------
  total             1.39 s   vs   1.11 s for plain Jacobi-CG
                             (+ a one-off 12.4 s basis build on top)
```

**80% of the standing posture's time is GenEO's own overhead**, and the 3.8x
iteration saving does not cover it.

---

## Why — the arithmetic that generalises

The task framed the basis build as the thing that must amortise (W2). It
amortises fine. **The build was never the problem.** The problem is a per-solve
cost the DTU comparison does not have to pay in the same proportion:

1. **The coarse operator must be REFRESHED on every solve whose moduli moved.**
   `build_coarse_operator` recomputes `V^T A V` with **N_t full matvecs** on the
   production operator (`geneo.cpp`, the loop over `q < Nt` calling
   `apply_kgg_raw`). In a topology-optimization ladder the moduli move every
   design iteration, so this is not amortisable across iterations the way the
   basis is. Measured: 15 refreshes over 16 iterations, 4,640 coarse matvecs.
   It is also MANDATORY — phase 2 §P6 measured divergence from a stale coarse
   operator, so it cannot simply be skipped.

2. **The deflation apply runs every CG iteration** — a sparse gather/scatter over
   all N_t basis columns plus a dense N_t x N_t solve. The interleaved run times
   one apply at ~1.22 ms against a plain matvec at ~1.15 ms, so **a deflated CG
   iteration costs about twice a plain one**. GenEO must therefore cut the
   iteration count by more than 2x *just to break even*, before paying a single
   refresh matvec.

So the standing posture pays, per design iteration, roughly

```
    ~2 x N_t  (refresh: N_t matvecs plus the N_t^2 dot products and dense LDLT)
  + ~2 x k_geneo  (each deflated iteration = its own matvec + one basis apply)
```

matvec-equivalents, against a baseline of `k_jacobi`. At the shipped tiling that
is `2(313) + 2(241) = 1,108` against 906 — measured 1.249x. At core 16^3 it is
`2(47) + 2(443) = 980` against 906 — measured 1.036x. **Both ends of the tiling
sweep lose, and so does everything between them**: small tiles buy iterations and
pay in refresh, large tiles buy refresh and pay in iterations.

**And the two terms scale differently.** `N_t` grows with the design VOLUME (it
is modes-per-subdomain x volume / core^3); `k_jacobi` grows with the grid
DIAMETER. So `N_t / k_jacobi` grows roughly quadratically in the linear grid
size, and the posture gets monotonically worse as the problem gets bigger — the
opposite of the direction that would make it a production default.

Measured (`w1b_scaling.csv`, 4 design iterations per point):

| grid | voxels | k_jacobi | N_t | N_t / k_jacobi | k_geneo |
|---|---|---|---|---|---|
| 20x8x21 | 3,360 | 388 | 36 | 0.09 | 192 |
| 30x12x31 | 11,160 | 594 | 145 | 0.24 | 202 |
| 40x16x41 | 26,240 | 771 | 290 | 0.38 | 201 |
| 50x20x51 | 51,000 | 977 | 756 | 0.77 | 213 |

**The maintainer's own operating point sits far off the end of that table.** The
armed production run measured **N_t = 7,588**, and the latched solves in
`iterations.csv` run at **~275 CG iterations**, so there

```
    N_t / k_jacobi  =  7,588 / 275  =  27.6
```

The refresh alone would cost **27.6x the entire solve it is meant to accelerate**,
every design iteration, before a single CG iteration is saved. There is no
tuning of a trigger constant that survives that.

---

## The bars

### W1 — THE CHEAP TEST. Standing GenEO LOSES. ✗

Predictions were recorded before any measurement
(`evidence/.../00-predictions.md`) and are graded in §Predictions below.

Fixture: a wall-mount bracket load path in a dilute designable box with 4 bolt
clearances carved out as permanently void voxels, 40x16x41, vf 0.50, spacing
1.5 mm, tip load 40 N down, wall face fully fixed. Per-iteration records in
`w1_baseline_iters.csv`, `w1_shipped_iters.csv`, `w1_standing_iters.csv`;
summary in `w1_summary.csv`.

**Timing caveat, and how it was handled.** This machine was NOT quiet during the
first battery (two unrelated `xctest` processes at ~100% CPU, load average
15-38), and the same plain-Jacobi baseline came out at 1.14 s/solve in one run
and 3.20 s/solve in another. Iteration counts, N_t, refresh counts and matvec
counts are deterministic and unaffected; wall time across separately-run
postures is not. So the load-bearing wall number is the **interleaved A/B
benchmark** (`bench` mode, `w1c_interleaved_bench.csv`), which alternates the two
postures solve-by-solve on the same system inside one process and reports
medians, so stationary load hits both equally and cancels. The whole-trajectory
tables above are consistent with it in direction and are reported as such, not
as precision timings.

Whole-trajectory run, 16 design iterations (directional, not a precision timing —
see the caveat above):

| posture | CG total | CG mean | wall |
|---|---|---|---|
| plain latched Jacobi-CG | 14,016 | 876 | 18.5 s |
| shipped trigger (500) | 4,051 | 253 | 31.9 s |
| standing GenEO (trigger 0) | 3,658 | 229 | 27.7 s |

Its GenEO wall split was build 5.7 s + refresh 10.0 s + apply 6.3 s = 22.0 s of
the 27.7 s run (80%), consistent with the interleaved decomposition.

**W1c — the interleaved result (9 reps, medians over the 8 steady-state ones):**

| posture | CG/solve | s/solve |
|---|---|---|
| plain Jacobi-CG | 906 | **1.112** |
| standing GenEO (core 8^3) | 241 | **1.389** |
| | **0.266x** | **1.249x** |

Deterministic, load-independent accounting for the same reps:

```
plain    : 906 matvecs (one per CG iteration)
standing : 313 refresh matvecs + 241 CG matvecs + 241 deflation applies
one-off  : 12.4 s basis build
```

**The production change would indeed be a CONSTANT, not a rewrite** — the trigger
is a single named constant and the harness moves it from outside without touching
an algorithm. The task asked me to say that plainly if W1 won. It did not win, so
the constant is not worth changing.

One finding worth separating out: on THIS fixture the shipped trigger of 500
*does* fire (the first solve burns 578 iterations), so production would arm GenEO
here anyway — and that posture is 1.72x SLOWER than plain Jacobi, worse than the
standing one, because it pays the 578-iteration burn on top. On the maintainer's
fixture the trigger correctly does not fire at 275. **The shipped trigger is not
merely defensible at this operating point, it is load-bearing: it is what keeps
the armed GenEO from making these runs slower.**

### W2 — THE BASIS AMORTISES. THE REFRESH IS WHAT DOES NOT. ✓/✗

| quantity | measured | DTU |
|---|---|---|
| basis builds | 1 | 7 |
| design iterations | 16 | 200 |
| design iterations per build | **16.0** | **28.6** |
| coarse refreshes | 15 (one per moved-moduli solve) | — |

The basis is robust across the trajectory: **one build served all 16 design
iterations**, a ratio in the same class as DTU's 28.6, and the deflated iteration
count stayed flat (229 mean, 193-251 range) with no degradation rebuild ever
scheduled. The reuse policy works exactly as designed.

That is precisely why the negative result is structural rather than a tuning
miss: the term that kills it (`N_t` matvecs per solve) is paid **even when the
basis is perfect and never rebuilt**.

### W3 — THE EIGENVALUE CUT IS INERT HERE. ✗ (and this is a real finding)

`w3_lambda_cut_sweep.csv`, 40x16x41, 10 design iterations per config:

| lambda cut | N_t | CG mean | basis MB |
|---|---|---|---|
| 0.002 | 288 | 222 | 10.1 |
| 0.005 | 288 | 222 | 10.1 |
| 0.010 | 288 | 222 | 10.1 |
| 0.020 | 288 | 222 | 10.1 |
| 0.050 (shipped) | 290 | 222 | 10.1 |
| 0.100 | 290 | 221 | 10.1 |

**A 50x sweep of the eigenvalue threshold moves the basis dimension by 0.7% and
the iteration count by nothing.** The lever the task expected (and that DTU used
to trade dimension against iterations) does not exist on this operator.

The reason is structural and worth recording. The basis is 288 columns over 60
subdomains = **4.8 modes per subdomain** — and those modes are the near-NULL
modes of a floating agglomerate, i.e. essentially its rigid-body space. Their
eigenvalues sit orders of magnitude below even the smallest cut tested, so
lowering the threshold does not exclude them and raising it does not admit
meaningfully more. The GenEO basis here IS the near-null space, and its size is
set by the number of subdomains, not by any threshold.

**Consequence: the ONLY lever on N_t is the TILING (W4).** That is why W3 cannot
rescue the economics and W4 is the whole search space.

### W4 — TILING IS THE ONLY LEVER, AND IT STILL DOES NOT PAY. ✗

`w4_tiling_sweep.csv` (10 design iterations per config) plus the interleaved
benchmark, which is the timing to trust:

| tiling | N_t | CG mean | interleaved wall vs plain |
|---|---|---|---|
| plain Jacobi | — | 906 | 1.000x |
| core = 4^3 | 2,376 | 97 | ~10x SLOWER (not benchmarked; 9.3-13.3 s/solve vs 1.1) |
| core = 8^3 (shipped) | 313 | 241 | **1.249x** |
| core = 16^3 | 47 | 443 | **1.036x** |

N_t tracks the subdomain count exactly as predicted (2,376 / 313 / 47 as the
tile volume grows 64x), and the iteration count moves the opposite way. **Larger
agglomerates are better here — PR 257's finding holds and the paper's does not**,
and my stated prediction was right, though for a reason PR 257 did not name: it
is not only that the subdomain must span the contrast feature, it is that N_t is
the recurring price.

But the optimum over tiling is **parity, not a win**. The cost simply MOVES:

| | core 8^3 | core 16^3 |
|---|---|---|
| refresh, per design iteration | 0.66 s | 0.07 s |
| deflation applies, per design iteration | 0.46 s | 0.54 s |
| CG itself | 0.29 s | 0.51 s |
| **total** | **1.39 s** | **1.12 s** |
| plain Jacobi | 1.11 s | 1.04 s |

Big tiles kill the refresh and pay it back in iterations; small tiles kill the
iterations and pay it back in refresh. Neither end wins, and the middle does not
either.

**The reason no tiling wins — the sharpest single number in this probe.** The
interleaved run measures one deflation apply at ~1.22 ms against a plain matvec
at ~1.15 ms: **a deflated CG iteration costs about twice a plain one** (its own
matvec plus the basis apply). So standing GenEO must cut the iteration count by
more than 2x *just to break even*, before paying a single refresh matvec. At
core 8^3 it cuts 3.76x — nearly enough — and then the refresh (~2 x N_t = ~626
matvec-equivalents) consumes the entire remaining margin.

### W5 — NOT RUN, per BLOCKED-STOP.

The task's BLOCKED-STOP says to stop after W1-W3 if arming GenEO every solve does
not beat latched Jacobi-CG. It does not. W5's two mechanism changes were
therefore not measured, and here is why neither could have changed the verdict:

* **W5a (diag(K_agglomerate) weighting)** makes the eigensolve's B-applies a
  scale instead of an element pass. That reduces the **BUILD** — the one cost
  that already amortises to 5.7 s / 16 = 0.36 s per design iteration. It does
  nothing to the refresh (N_t matvecs) or the apply, which are 16.3 s of the
  22.0 s of overhead. The mechanism is implemented and wired behind the probe
  config (`GeneoProbeConfig::eig_weighting = 1`) for whoever picks this up.
* **W5b (forced rebuild at continuation points)** ADDS builds. The measured
  problem is that the recurring cost is already too high with ZERO extra
  rebuilds; adding rebuilds at p-continuation steps can only make it worse. The
  forcing hook (`geneo_request_rebuild`) and a p-continuation schedule are
  implemented in the harness (`w5b` mode) and ready to run if the picture changes.

### W6 — CORRECTNESS. ✓ PASS

`w6_correctness.csv`. Developed design on the 40x16x41 analysis grid, modulus
contrast E_max/E_min = 1e9, solved three ways:

| check | value | bar | verdict |
|---|---|---|---|
| plain Jacobi-CG | 906 iters, converged, rel.res 9.42e-09 | — | — |
| standing GenEO | 243 iters, converged, rel.res 9.15e-09, N_t=313 | — | — |
| `max|u_geneo - u_plain| / max|u_plain|` | **4.02e-07** | <= 1e-5 | **PASS** |
| rerun bit-identical (u, iterations, N_t) | YES | YES | **PASS** |

The coarse correction stays SPD and the solve stays exact: both postures reach
the same relative-residual tolerance and their fields agree to 4e-07, two orders
inside the bar, which is the expected O(tol) spread between two solves stopped at
`cg_tolerance = 1e-8` — not bit-parity, and bit-parity is not owed (the 133/248
discipline: an engaged accelerator changes the iteration path). Reruns ARE
bit-identical, as the fixed LOBPCG seeds and fixed merge order promise.

`test_geneo` (the existing CTest target) also passes 24/24 with the probe surface
present, including its own exactness and determinism bars.

### W7 — THE HONEST COMPARISON. ★ THIS IS THE NUMBER THAT SHOULD DRIVE THE NEXT TASK.

Same fixture, same OC trajectory, same 10 design iterations — but with the parity
pad left at its production AUTO setting so the odd axis is padded and a multigrid
hierarchy actually builds (`w7_healthy_mg_iters.csv`):

| solver | CG per solve | s per solve |
|---|---|---|
| **healthy multigrid** | **40** | **0.45** |
| plain latched Jacobi-CG | 906 | 1.11 |
| standing GenEO (core 8^3) | 241 | 1.39 |

**Working multigrid is 2.5x faster than the latched Jacobi baseline and 3.1x
faster than the best standing-GenEO posture, on the identical problem.**
Multigrid carried on 10/10 solves at 40 iterations.

So the answer to "is standing GenEO competitive with working multigrid, or only
with its absence?" is: **only with its absence, and not even convincingly with
that.** The prize on this fixture is not a better fallback preconditioner worth
-25%; it is keeping multigrid alive, worth 2.5x. The maintainer's run had
multigrid BUILD and then stagnate — that stagnation, not the trigger constant, is
where the time is.

---

## What this changes in production

**Nothing.** That is the recommendation.

* `kGeneoTriggerIters = 500` stays. It is doing its job.
* GenEO stays armed as the RESCUE it was measured to be in PR 248 — the
  21.7x / 7.2x wins on the 5,412-iteration stagnating rung are not in question
  and are not contradicted by anything here. At 5,412 baseline iterations the
  same arithmetic comes out overwhelmingly in GenEO's favour; at 275 it does not.
* The maintainer's run behaved CORRECTLY. The 127 latch turned off a stagnating
  multigrid; the remaining ~275-iteration Jacobi solves are not a pathology GenEO
  can fix at a profit.

---

## What the paper's route would actually require

The task anticipated this: if W1 failed, the real fix is the paper's own recipe —
replace the multigrid COARSE GRID with the spectral basis and add a Gauss-Seidel
smoother, rather than bolting a standing deflation onto Jacobi-CG. The
measurements say why that framing is the right one, and sharpen it:

The deflation form `M^-1 = D^-1 + V (V^T A V)^-1 V^T` puts the ENTIRE coarse
space in one flat block, so both of its costs are linear in `N_t`: `N_t` matvecs
to refresh, and an `N_t`-column apply every CG iteration. A multigrid coarse
GRID does not work that way — the coarse operator is assembled by Galerkin
projection through a hierarchy (cheap, and the geometry-only block is already
cached here per `galerkin-block-is-geometry-only`), and the coarse solve is one
V-cycle rather than a dense factorisation.

So the honest next question is not "should GenEO stand" but **"can the spectral
basis be used as a multigrid coarse LEVEL instead of a deflation block, so its
cost stops being linear in N_t?"** That is a larger task and should not start on
a hunch — but it now starts from a measured mechanism rather than a paper's
promise, and it has a clear success criterion: the per-design-iteration coarse
cost must be sublinear in `N_t`.

---

## Reproducing

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build --target topopt -j
c++ -std=c++17 -O2 -I core/include -I core/src \
  -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
  core/tests/harness/geneo_standing_probe.cpp core/build/libtopopt.a \
  -o core/build/geneo_standing_probe
TOPOPT_GSP_DIR=evidence/2026-08-02-geneo-standing-probe \
TOPOPT_GSP_N=32 TOPOPT_GSP_DIL=0.25 TOPOPT_GSP_VF=0.5 TOPOPT_GSP_ITERS=16 \
  ./core/build/geneo_standing_probe w1
```

Modes: `regime` `w1` `scale` `w3` `w4` `w5a` `w5b` `w6` `w7`.

---

## Predictions, graded

Recorded in `evidence/.../00-predictions.md` before the first measurement.

| # | prediction | outcome |
|---|---|---|
| W1 | standing GenEO LOSES; CG falls to 60-150; wall worse by 2-10x | **RIGHT on direction, WRONG on magnitude.** CG fell to 241 (the 60-150 band was only reached at core 4^3, where it hit 97); wall worse by 1.25x, not 2-10x. I over-predicted the damage. |
| W1 | ~1-3 builds, one refresh per design iteration | **RIGHT.** 1 build, 15 refreshes over 16 iterations. |
| W2 | basis amortises fine; refresh is the problem | **RIGHT.** 16.0 design iterations per build, comparable to DTU's 28.6. |
| W3 | smallest basis wins on wall; parity at best | **WRONG, and the reason is the finding.** The eigenvalue cut turned out to be an INERT lever here — a 50x sweep moved N_t by 0.7%. I assumed the threshold controlled the dimension; on this operator the kept modes are near-null rigid-body modes far below any threshold tested. |
| W4 | larger tiles win (PR 257 over the paper) | **RIGHT**, and for the reason I gave (N_t is the recurring price). But the win tops out at parity, which I did not predict. |
| W5a | cheaper build, verdict unchanged | Not run per BLOCKED-STOP; the reasoning behind it is confirmed by the cost split (build is 0.36 s/iteration of a 1.39 s/iteration cost). |
| W5b | shipped policy misses continuation points; forcing costs more | Not run per BLOCKED-STOP. |
| W6 | PASS | **RIGHT.** 4.02e-07 against a 1e-5 bar, deterministic. |
| W7 | healthy MG far cheaper than either | **RIGHT, and by more than I expected** — 40 iterations vs 906/241. |

The one prediction I would flag as a real miss is W3. I predicted the eigenvalue
threshold would trade dimension against iterations as it does for DTU; it does
not do that here at all, and finding out why (the basis IS the near-null space)
is more useful than the number I expected.

---

## What was touched

**Production files (3), all default-preserving, all measurement-only:**

* `core/src/fea/geneo.hpp` — added `GeneoProbeConfig` (trigger, tiling, overlap,
  LOBPCG block size, eigenvalue cut, eigenproblem weighting), its getter/setter,
  `geneo_probe_defaults_match_tripwire()`, `geneo_request_rebuild()`, and four
  cost counters (coarse matvecs, build/refresh/apply seconds). The struct's
  DEFAULTS ARE the shipped tripwire constants.
* `core/src/fea/geneo.cpp` — reads the config in `build_basis`, implements the
  W5a diagonal weighting variant, instruments the costs.
* `core/src/fea/matfree.cpp` — the stagnation-trigger comparison reads
  `geneo_probe_config().trigger_iters` instead of the constant directly, and
  `fea_geneo_trigger_iters()` now reports the EFFECTIVE trigger (the 114/132
  discipline: run_info echoes what the run actually executed under).

**Byte-identity proven, not asserted.** `geneo_byteid_xbuild` (public API only,
a 2-rung production ladder, FNV over densities/compliance/margins/accepts):

```
with the probe surface     : fnv = 2318d4342a24861e
git-checkout pre-change    : fnv = 2318d4342a24861e     IDENTICAL
```
(`byteid_after.txt` / `byteid_before.txt`.)

**Test:** `core/tests/unit/test_geneo.cpp` gains two checks pinning the EFFECTIVE
trigger to 500 and the rebuild factor to 2.0 at library default — so a stray
override, or a probe default drifting from the tripwire, fails a test rather than
silently changing production. 24/24 checks pass.

**Harness (new, not a CTest target):**
`core/tests/harness/geneo_standing_probe.cpp` + `_modes.inc`.

**Not touched:** `run_job.cpp`, `minimize_plastic.cpp`, fixtures, materials.json,
ARCHITECTURE.md, DECISIONS.md.

---

## Caveats a reader should hold

* **The fixture is a synthetic stand-in, and a CHARITABLE one.** It reproduces
  the maintainer's SOLVE PATH exactly (matrix-free Jacobi-CG, multigrid absent)
  but sits at 906 baseline iterations rather than ~275, and at 26,240 voxels
  rather than the real run's ~468,000. Both differences favour standing GenEO:
  more baseline iterations to save, and a much smaller N_t. It still loses. The
  real operating point is worse for it by the N_t/k argument above, not better.
  * The harness CAN hit the observed iteration band exactly — at `TOPOPT_GSP_N=16`
    the `regime` mode reports mean 378 with multigrid absent, inside the [120,600]
    target. But that point is a 3,360-voxel grid, and its N_t/k of 0.09 is two and
    a half orders of magnitude away from the real run's 27.6. **Matching the
    maintainer's ITERATION COUNT and matching their GRID SIZE cannot be done at
    once with a synthetic cantilever** — a slender bar conditions far worse per
    DOF than a real bracket's load path. The headline runs use the larger grid
    (n=32) because N_t/k is the quantity that decides the verdict, and reporting
    it from the least favourable-to-my-conclusion end would have been the
    misleading choice.
* **Multigrid absence is IMPOSED, not earned.** The harness rejects the hierarchy
  via `fea_set_mg_parity_pad_mode(0)` on a grid with an odd axis, rather than
  waiting for three consecutive stagnations to trip the 127 latch. That is the
  documented test lever for exercising this fallback, and it makes every sweep
  deterministic — but it means this probe says nothing about WHY multigrid
  stagnates on the maintainer's part.
* **Wall times from separately-run postures on this machine are noisy** (two
  unrelated `xctest` processes at ~100% CPU throughout). Every load-bearing wall
  claim comes from the interleaved A/B benchmark; the whole-trajectory tables are
  directionally consistent and reported as such.
* **The `scale` table's timing columns are contaminated** for the same reason;
  its N_t, iteration counts and ratios are deterministic and are what it is cited
  for.

---

## PLAIN LANGUAGE

**The question.** GenEO is a clever preconditioner we already ship. Today it only
switches on as an emergency rescue: a solve has to grind through 500 useless
iterations first. A well-regarded paper uses the same mathematics as the *normal*
preconditioner, always on. Your bracket run spent all its time in ~275-iteration
solves, just under our threshold, so GenEO never woke up. The question was
whether it should have.

**The answer: no, and it is not close enough to be worth a second look.**

**What GenEO genuinely does.** It works. Turned on from the first solve, it cut
the number of solver iterations by **3.8x** — from 906 to 241 — and, exactly as
the paper promises, that number stayed flat (about 200) even as the problem grew
15x bigger, while the ordinary solver got steadily worse. The mathematics is not
in doubt.

**Why it still loses.** Two hidden bills.

The first is that GenEO has to re-do a chunk of setup **every single design
iteration**. It builds a small summary of the structure once — and that part is
fine, one build covered all 16 iterations. But every time the design changes
shape, the summary has to be re-measured against the new shape, and that
re-measurement costs about as much as several hundred solver iterations. The
design changes shape every iteration. That bill never goes away.

The second is that each GenEO-assisted iteration costs about **twice** an
ordinary one, because the preconditioner does extra work inside every step. So
GenEO has to cut the iteration count by more than half just to get back to even,
before paying the first bill at all.

Put together: it cut the work 3.8x and the overhead ate 4.7x of it. Net, the run
got **25% slower**.

**And it gets worse on bigger parts, not better.** The re-measurement cost grows
with the *volume* of the part, while the solver's own cost grows only with its
*size across*. On your actual bracket the numbers we already have from a previous
run say the re-measurement alone would cost roughly **28 times** the whole solve
it was supposed to speed up. Every iteration. There is no threshold setting that
survives that.

**We tried the obvious escapes.** Making the summary smaller by changing how
picky it is: no effect at all — a 50-fold change moved the size by under 1%,
because what it is capturing is a fixed feature of the geometry, not something a
dial controls. Changing the size of the chunks it works on: this *did* move
things, a lot, but it just shifted the cost from one bill to the other — the best
setting reached a dead heat, never a win.

**The thing actually worth your attention.** On the very same test part, when the
multigrid solver was allowed to work properly it finished in **40 iterations,
0.45 seconds** — against 1.11 seconds for the plain solver and 1.39 for GenEO.
Multigrid working is **2.5x faster than the baseline and 3.1x faster than the
best GenEO setting.**

Your bracket run shows multigrid *starting up and then failing to make progress*,
after which the system correctly switched it off. That is where the time went.
Chasing a better replacement for multigrid was worth −25%; getting multigrid to
survive on that part is worth 2.5x. **That is the next task, not this one.**

**What changed in the product: nothing.** The 500-iteration threshold stays. It
turns out to be doing real work — on a fixture where it *does* fire, arming GenEO
made things 1.72x slower, so the threshold is what protects those runs. Every
production file I touched was verified to produce byte-for-byte identical results
to before, and a test now guards that.
