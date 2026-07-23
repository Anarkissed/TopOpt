# 134 — ACTIVE DOMAIN Phase 0: feasibility de-risk, measure-first (READ-ONLY)

**Status:** Measurement complete. **No production code changed** — `git diff main --
core/src core/include` is **empty**. Deliverable = this handoff + one measurement
harness (`core/tests/harness/active_domain_probe.cpp`, standalone, NOT wired into
CTest — the 129/130 precedent) + `docs/handoffs/evidence/134/`.

**Handoff-number note:** drafted as 131 (the top of `docs/handoffs/` when the
measurements were taken was 130). While this sat, **three** siblings landed —
`131-amg-phase-0-feasibility`, `131-rung-infeasibility-fast-fail` (they collided with
each other), `132-mixed-precision-blocked-and-pcore-pin` and
`133-krylov-recycling-deflation`. Renumbered to **134**; the predicted rename happened.

**Measurement baseline, stated because `main` moved underneath it:** every number here
was captured at **`ac9769f`**. The branch has since been rebased onto **`c6c7af7`**, and
the harness **rebuilds and runs unchanged** against it. What that does and does not mean
is in §7 — one of the landed siblings arms a rung terminator by default, which moves a
projection input (`f_bar`) but cannot move an active-fraction measurement.

**Sibling reconciliation:** `131-amg-phase-0-feasibility` measured the exact composition
partner §4d speculates about, and it **contradicts the naive version of my claim**. §4d
has been rewritten against its numbers rather than left as prediction.

**Verdict: GO** — build the Phase 1 opt-in mask at `k = ceil(rmin_voxels) + 1` (**= 4**
under the production config, not 2), cadence 1, **framed as a measured approximation,
not as an exact-answer accelerator** (the stated Bar 2 was not met as written; §5 says
what it was met against instead). **The projected end-to-end win is ~1x at 10x dilution
and ~4x at 49x** — it is not a uniform win across the maintainer's stated 10-60x range,
and §4b says so with numbers.

**The four answers, one line each:**

- **[1] CEILING:** Real, and a strong function of two things — dilution and **band
  width**. Terminal active fraction at `k = 0 / 2 / 4 / 8`: **72/100/100/100 %** on a
  SNUG part domain (**nothing to win, and this handoff says so**), **17/36/60/84 %** on
  a 10x design box, **5/11/19/40 %** at 25x, **2.5/5.4/9.7/20.6 %** at 49x.
- **[2] CORRECTNESS:** Restriction is an **approximation, not exact**. At CG tolerance
  `1e-10` the compliance moves `~1e-5..1e-3` relative and the sensitivity field
  `~1e-3..1e-2`, and **the error grows with dilution** (§2e). Accumulated over 40
  optimizer steps at production-like 49x dilution the two designs differ by
  `mean|drho| = 3.6e-6` at `k=4` — **8 400x inside the calibrated 0.03 design bar that
  BLOCKED handoff 130's flip**, though the worst single voxel (4.2e-3) is only 7.2x
  inside it. Monotone in `k`. Reported as an approximation.
- **[3] MECHANICS:** Mask is a pure function of the density field with a fixed
  traversal (bit-identical re-derivation, tested). Sizing rule
  `k = ceil(min_feature_mm/spacing) + 1`. Cadence 1. **Growth invariant: ZERO band
  escapes on every iteration of all ten configurations** — the optimizer never wanted
  material outside even a 2-voxel band.
- **[4] ARITHMETIC:** Measured per-solve speedup **14.1x / 8.0x / 2.7x** at
  `k = 2 / 4 / 8` and production dilution (6.4x / 3.4x / 1.6x at 25x) — **only ~65 % of
  the naive element-count ceiling**, because the restricted system needs **1.4-2.0x MORE
  CG iterations**. That penalty was not anticipated and is the single most important
  number here. **AMG absorbs it on the iteration axis** (131 measures 25-103x), but 131
  also retires the "they multiply" story on wall-clock; the surviving composition claim
  is that active domain makes AMG **affordable in memory** (§4d).

---

## 0. THE ONE FACT THAT REORGANISES EVERYTHING

The active fraction is **not** set by how little material the part needs. It is set by
**two things that have nothing to do with the part**:

1. **The growth band times the surface area of a thin skeleton.** A SIMP design in a
   dilute box is a lattice of ~3-voxel members (the min-feature floor). Dilating that
   skeleton by `k` voxels multiplies its volume by roughly `((t+2k)/t)^2` transverse to
   each member. Measured on the 10x box: the core set is **17 %** but a `k=4` band is
   **60 %** and `k=8` is **84 %**. **The band, not the structure, is the cost.**
2. **The sub-1 % gray cloud.** MMA has no Heaviside projection unless the per-rung
   grayness gate fires (123), so the physical density is a ramp. On the real CLI
   design-box capture at 1.7 % part fill, **62 % of the domain sits between
   `1.5*rho_min` and `0.01`** and only **0.03 %** is above `rho = 0.3`. Under the
   task's stated `rho > 1.5*rho_min` rule the "active set" on that run is numerical
   mush, and the ceiling vanishes.

Both facts push the same way: **the win exists only for a NARROW band.** And the
narrow band is exactly what the growth-invariant measurement licenses — **zero band
escapes at `k=2`, on every iteration of every trajectory measured** (§3b). That is the
result this whole handoff turns on: the ceiling is worth 3.7-18.5x at `k=2` and
1.2-2.5x at `k=8`, and `k=4` — the width §3b's ARGUMENT (not just its measurement)
supports — is the shippable middle.

**Second-order fact, discovered in §4a and not anticipated:** the restricted system is
**harder** for the geometric V-cycle, not easier — CG iterations rise 1.4-2.0x when the
`rho_min` filler is removed and the thin skeleton is left floating alone. That is
handoff 125's stagnation geometry, arrived at from the other direction. Handoff 131's
AMG measurements confirm AMG absorbs that penalty on the ITERATION axis (its win is
25-103x, the penalty is 1.4-2.0x) — but 131 R1b also measures AMG's wall-clock advantage
**inverting** on developed-design fields, so "active domain + AMG multiply" is retracted.
§4d is rewritten against 131's numbers; the surviving composition claim is about
**memory**, not speed.

---

## 1. THE CEILING — active fraction per iteration per rung

**What is measured.** Every fixture runs the REAL driver (`minimize_plastic` under
`configure_production_options` — matrix-free MG, Galerkin cache, MMA, conditional
projection, 2.5 mm physical min-feature, `production_reduction_ladder()`
`{0.68, 0.52, 0.38, 0.26}`) with the 117 read-only `on_density_snapshot` hook
attached. For every iteration of every rung the harness computes `{rho > 1.5*rho_min}`
dilated by `k in {0,2,4,8}` and reports it as a fraction of the analysis ELEMENT count
and of the analysis NODE count (nodes are what scale the CG vectors). The design is
byte-identical with or without the hook (117's contract), so the capture does not
perturb what it measures.

**Rung volume targets are PART-RELATIVE (handoff 080), and this is the whole game.**
On a design-box run `minimize_plastic` rescales rung `vf` to
`(vf*part_solid - frozen)/active_effective`, so rung 0.26 on a 10x box asks for ~2.6 %
of the DOMAIN, not 26 %. The harness reproduces the same rescaling in its own loops
(§2). Missing this makes every ceiling number wrong by the dilution factor.

### 1a. Terminal active fraction per rung (element %; lower is better)

```
fixture                  part fill  rung   elems |   k=0   k=2   k=4   k=8 | nodes k=4
F1  L-bracket, NO box       100 %     0    4480  |  72.0 100.0 100.0 100.0 |   100.0
                                      1    4480  |  57.3  99.4 100.0 100.0 |   100.0
                                      2    4480  |  45.6  98.4 100.0 100.0 |   100.0
                                      3    4480  |  32.6  89.6 100.0 100.0 |   100.0
F2  design box, 10x         9.7 %     0   46080  |  17.1  36.4  59.5  83.6 |    61.2
                                      1   46080  |  14.8  32.2  54.7  82.1 |    56.5
                                      2   46080  |  13.2  31.1  54.1  88.1 |    55.9
                                      3   46080  |  10.9  27.0  48.1  82.8 |    50.1
F3  design box, 172x       0.58 %     0  262144  |   5.9  11.8  18.8  35.9 |    19.8   TRUNCATED, 4 iters
harness dilute box, 25x     3.9 %  vf.26  38400  |   5.4  10.8  18.8  40.4 |     20.8  §2, 40 iters
harness dilute box, 49x     2.1 %  vf.26  73728  |   2.5   5.4   9.5  20.6 |     10.8  §2, 40 iters
CLI capture, 1.7 % fill     1.7 %     0   39672  |  62.5  86.9  98.0 100.0 |     98.3  DEGENERATE, §1c
```
(F1/F2/F3 from `ceiling.csv`; the CLI row from `ceiling_cli_res16_plateau.csv` — the
plateau-terminated iteration-31 design, the same one §1c's threshold sweep uses. The
two harness rows' node fractions are §4a's measurement on that fixture's iteration-40
design, since `trajectory.csv` carries element fractions only.)

Implied speedup ceiling (1 / active element fraction) — the NAIVE ceiling, before
§4a's CG-iteration penalty:

```
                        k=0     k=2     k=4     k=8
F1 (snug, no box)       1.4x    1.1x    1.0x    1.0x     <- NOTHING TO WIN
F2 (10x box, rung 3)    9.2x    3.7x    2.1x    1.2x
dilute box (25x)       18.5x    9.3x    5.3x    2.5x
dilute box (49x)       40.0x   18.4x   10.5x    4.9x
```

**Reading it.** (i) On a snug domain there is nothing to win — correctly, since there
is no empty space to skip. Any claim that active domain helps a normal part is false.
(ii) The win scales with dilution, as it must. (iii) **Band width destroys the win**:
each doubling of `k` costs roughly a factor of two, because a thin skeleton has
enormous surface area. This is why §3b's "zero escapes at `k=2`" is the load-bearing
measurement of this handoff.

### 1b. Active fraction vs iteration (F2, rung 0 — the shape of a trajectory)

```
iter    k=0   k=2   k=4   k=8
   1   42.0  55.7  68.1  82.5     <- uniform start: everything is above 1.5*rho_min
  10   50.5  64.6  75.6  87.2     <- material SPREADS before it condenses
  20   48.4  64.9  76.0  89.9
  30   22.8  43.8  64.2  84.9     <- condensation
  40   17.6  37.2  59.6  83.7
  60   17.2  36.0  58.9  83.4     <- flat from here to termination
 120   17.1  36.4  59.5  83.6
```

**The first ~25 iterations are NOT cheap** — the field is still spread and the active
fraction is 40-70 %. The saving is a property of the CONVERGED half of a rung, and a
rung that terminates early (the 086/128 plateau stop) spends proportionally more of its
life in the expensive phase. An end-to-end projection that assumes the TERMINAL active
fraction for every iteration overstates the win by **~1.5-1.7x** on these trajectories;
§4b projects with the per-iteration mean `f_bar` instead.

### 1c. The real CLI design-box capture — and why its number is 62 %, not 6 %

The task asked for one small box run captured through the 117 flags. Two were taken,
both of the committed `l-bracket.step` (35 525.84 mm^3) inside a 140x110x135 mm box
(2.079e6 mm^3) = **1.71 % part fill**, the shape the maintainer reported:

| capture | grid | elements | outcome |
|---|---|---|---|
| `resolution 24` (spacing 2.5 mm) | 56x48x56 | 150 528 | **budget-truncated at 4 iterations.** Iteration 4 alone took **189 s**: `cg_multigrid=0`, `hier_built=1`, `mg_cycles_attempted=300`, **15 516 Jacobi CG iterations**. This is handoff **125 STAGNATION reproduced on a plain 1.7 %-fill box with no clearance hole** — a new, cleaner repro than 125's. Reproduced identically on two independent runs. |
| `resolution 16` (spacing 3.75 mm) | 40x32x40 | 39 672 | ran to the MMA plateau stop at iteration 31, then **failed the gate**: `recommend_settings: worst_case_stress_margin must be finite and >= 0`. |

The res-16 design's threshold sweep says why its active fraction is 62 %:

```
threshold      k=0    k=2    k=4    k=8      (element active %, iter-31 design)
   0.0015    62.49  86.89  98.03 100.00     <- the task's 1.5*rho_min rule
   0.01      15.34  35.58  60.56  97.49
   0.05       2.12  11.65  23.40  53.91
   0.1        0.11   2.34   7.44  27.58
   0.3        0.03   0.81   2.69  11.75
```

**Only 0.03 % of the domain is above `rho = 0.3`.** There is essentially no solid
material anywhere — which is also exactly why the stress-margin gate returned a
non-finite worst case (no printed voxels above the 0.5 iso).

**Cross-reference, and a distinction worth keeping straight.** Handoff **131
(rung-infeasibility fast-fail)** landed a detector for a neighbouring failure: a rung
whose load path is SEVERED, recognised by compliance jumping >100x and then going flat
while CG blows up. This capture is a **different member of the same family** and the
detector would NOT have fired on it: my compliance never went flat (it swung
475 919 -> 108 044 -> 57 694 across the last iterations), and the run died by a THROW out
of `recommend_settings`, not by certifying a corpse. 131's failure is a structure that
carries nothing and gets a finite, flattering margin; mine is a gray cloud that produces
no margin at all. Both argue the same thing — a degenerate design should be caught before
the gate, not at it — but they are not the same signature and one does not cover the
other.

**Both captures are compromised, and neither should be used as the ceiling number:**
- res-24 by the probe budget (125 stagnation makes each iteration ~3 min);
- res-16 by **under-resolution, not by dilution**: the bracket's mounting plate is
  8 mm, i.e. **2.1 voxels** at 3.75 mm spacing, while the min-feature filter floors at
  1.5 voxels = 5.6 mm. The mesh cannot represent the part, so the optimizer cannot
  crisp anything. That is a fixture defect, not a finding about active domains.

They are reported because they are the honest state of the evidence, and because the
res-24 stagnation is a genuine citable result in its own right. **A converged,
well-resolved ultra-dilute DRIVER capture is the single biggest gap in this Phase 0**
(§5); the `ultradilute` harness fixture in §1a/§2 is the stand-in, and it is a harness
OC run, not a driver MMA run.

### 1d. What the threshold rule costs — the knob Phase 1 will have to face

The `1.5*rho_min` rule is the task's, and it is the SAFE one: everything it eliminates
has modulus `<= (1.5e-3)^3 = 3.4e-9 * E0`. Raising the threshold to 0.05 would cut the
CLI capture's active set from 62 % to 2 % — but it eliminates elements at up to
`(0.05)^3 = 1.25e-4 * E0`, ~10^5 times stiffer than the floor, and **this handoff did
not measure that error.** Phase 1 must either keep `1.5*rho_min` and accept that a gray
run gets no speedup, or measure the higher-threshold error properly. Quoting a 2 %
active fraction at threshold 0.05 as a ceiling would be exactly the unmeasured claim
130 blocked.

---

## 2. CORRECTNESS PROTOTYPE — full domain vs restricted, at tight tolerance

### 2a. What "restricted" means here (the stated boundary treatment)

Out-of-band voxels are re-tagged `Empty` on a COPY of the analysis grid. The existing
M3.1 void-DOF gate (`mf_build_reduced`, [matfree.cpp](core/src/fea/matfree.cpp)) then
removes every DOF no surviving element touches — exactly, and by construction. The band
boundary is therefore a **traction-free free surface**: the far void's `rho_min`
stiffness is ELIMINATED, not approximated. No new code path, no new boundary-condition
code. This is precisely why Phase 1 is a mask argument to `mf_build_elems` and nothing
more (§6).

### 2b. Experiment

Two harness OC loops run side by side from an identical start with an identical filter
(`physical_filter_radius(2.5 mm, spacing)` = 2.5 voxels), identical move limit,
identical part-relative volume target, identical `oc_update`. **The ONLY difference is
which grid the FEA solve sees.** Both trajectories accumulate independently for 40
iterations, so `|drho|` at iteration `i` is the ACCUMULATED design divergence, not a
per-step residual. CG tolerance `1e-10`; solver `MultigridCG_Matfree` (production).

The updater is OC, not MMA, because the public API exposes an MMA *loop* but no MMA
*step*. This is a real limitation. Why it does not change the verdict: OC and MMA
consume the SAME object — the filtered `dc/drho` field `simp_compliance` returns — and
the substitution under test is the solve that produces that field. `max |dSens|/|Sens|`
is therefore reported alongside `|drho|` as the updater-independent number.

### 2c. Result

```
fixture         k  cad iters | active% | worst dC/C  worst dSens | end mean|drho|  end max|drho| | escapes
dilute40 vf.26  2   1    40  |  10.80  |  8.14e-05    2.01e-03   |    4.678e-07     8.436e-04   |    0
dilute40 vf.26  4   1    40  |  18.82  |  5.07e-05    1.74e-03   |    2.146e-07     4.457e-04   |    0
dilute40 vf.26  8   1    40  |  40.38  |  1.46e-05    6.49e-04   |    6.556e-08     1.415e-04   |    0
dilute40 vf.68  4   1    40  |  23.59  |  6.31e-07    1.69e-04   |    7.442e-09     9.949e-06   |    0
dilute40 vf.26  4   2    40  |  18.85  |  1.35e-05    1.14e-03   |    1.061e-07     2.852e-04   |    0
dilute40 vf.26  4   5    40  |  18.89  |  1.23e-05    1.14e-03   |    5.286e-08     1.009e-04   |    0
dilute40 vf.26  4  10    40  |  19.04  |  1.91e-06    4.80e-04   |    3.061e-08     4.556e-05   |    0
ultradil vf.26  2   1    40  |   5.43  |  9.65e-04    7.47e-03   |  worst 7.998e-06 1.035e-02   |    0
ultradil vf.26  4   1    40  |   9.53  |  4.02e-04    3.33e-03   |  worst 3.582e-06 4.172e-03   |    0
ultradil vf.26  8   1    40  |  20.57  |  6.54e-05    9.66e-04   |  worst 7.147e-07 8.963e-04   |    0
```

(The `dilute40` rows report the ENDPOINT `|drho|`; the `ultradil` rows are labelled
`worst` because they report the max over the run. On `dilute40` the `mean|drho|` peak
is mid-run and slightly above the endpoint — `k=2` peaks at `2.409e-06`, `k=4` at
`6.826e-07`, `k=8` at `2.030e-07`; §5's comparison table uses worst-over-run
throughout. Full per-iteration series in `trajectory.csv`.)

**Monotone in `k`, as physics requires**: a wider band eliminates fewer elements, so
every error metric shrinks — `dC/C` 8.1e-5 -> 5.1e-5 -> 1.5e-5 and `mean|drho|`
4.7e-7 -> 2.1e-7 -> 6.6e-8 across `k = 2, 4, 8`. It is also two orders SMALLER at the
heavy rung (0.68) than the light one (0.26), the right sign: a heavier design leaves
less far void to eliminate.

**Against the stated bar: the deltas are NOT at solver-tolerance level.** At CG
tolerance `1e-10` the compliance moves `~1e-5` and the sensitivity field `~1e-3`
relative. **Restriction is an APPROXIMATION.** It cannot be otherwise: the eliminated
elements carry a real, if tiny, `rho_min^p = 1e-9` stiffness and there are millions of
them; a traction-free band boundary discards it. Widening the band shrinks the error
monotonically but never to zero. §5 states what that means for the verdict, and against
which calibrated bar it is judged instead.

### 2d. Divergence growth with iteration count — the caveat Phase 1 must close

`mean|drho|` is FLAT-to-decreasing over the 40 steps, but `max|drho|` GROWS (`k=2`):

```
iter     5     10     15     20     25     30     35     40
max   8.4e-5 1.5e-4 2.3e-4 4.3e-4 6.7e-4 6.9e-4 7.3e-4 8.4e-4
mean  7.9e-7 6.8e-7 6.2e-7 6.2e-7 5.8e-7 5.5e-7 4.6e-7 4.7e-7
```

Growth is sub-linear and flattening after ~iteration 25, but 40 steps is not a
production rung (150-250). A LINEAR extrapolation to 250 steps gives
`max|drho| ~ 5.3e-3` — still ~6x inside the 0.03 bar, but on an extrapolation, which is
not enough to ship on. **The gating Phase 1 measurement is a full-length rung.**

### 2e. THE ERROR SCALES WITH DILUTION — and this is what constrains the design

The 25x box is not the production regime; the reference job is ~59x diluted. Running
the identical experiment on a 49x box (73 728 elements, 2.05 % part fill) moves every
error metric **3x to 12x in the wrong direction**:

```
                        dC/C      dSens     worst mean|drho|   worst max|drho|
dilute box 25x, k=2   8.14e-05   2.01e-03      2.409e-06          8.436e-04
dilute box 49x, k=2   9.65e-04   7.47e-03      7.998e-06          1.035e-02   <- 12x worse
dilute box 25x, k=4   5.07e-05   1.74e-03      6.826e-07          4.457e-04
dilute box 49x, k=4   4.02e-04   3.33e-03      3.582e-06          4.172e-03   <-  9x worse
dilute box 25x, k=8   1.46e-05   6.49e-04      2.030e-07          1.415e-04
dilute box 49x, k=8   6.54e-05   9.66e-04      7.147e-07          8.963e-04   <-  4x worse
```

This is the expected sign — a more dilute box means a larger fraction of the domain is
eliminated, so more discarded `rho_min` stiffness — but the MAGNITUDE matters for the
verdict. At 49x and `k=2` the worst single-voxel excursion is **1.0e-2, only 2.9x
inside the 0.03 bar**, over 40 steps. The MEAN is still 3 750x inside (7.998e-06 vs
0.03), and the mean is the quantity 130's bar is stated on — but the trend line is
clear and it points at the production regime.

**Two consequences, and they are the operative recommendations of this handoff:**

1. **Ship `k=4`, not `k=2`.** `k=4` is what §3b's ARGUMENT licenses
   (`k >= ceil(rmin)+1`), not merely what its measurement survived. It costs ~1.75x of
   the ceiling at 49x (18.4x -> 10.5x, and 14.1x -> 8.0x once measured, §4a) and buys
   ~2.4x on every error metric at production dilution.
2. **The Phase 1 gate must be at PRODUCTION dilution AND full rung length**, because
   both axes move the error the same way and this Phase 0 measured neither at its
   production value. Extrapolating both together from these fixtures would be exactly
   the unmeasured claim 130 blocked; it is not attempted here.

---

## 3. MASK MECHANICS

### 3a. The mask rule (pure function of the density field, fixed traversal)

```
active(e) = solid(e) AND [ rho_e > 1.5*rho_min                      (core)
                           OR e carries a Load or Fixture tag       (BC pin)
                           OR dist_cheb(e, core) <= k ]             (growth band)
```

- **Pure function.** Depends only on `(grid tags, physical density, k)` — no iteration
  counter, no history, no RNG, no floating-point reduction. The dilation is a
  **separable Chebyshev max-filter** run x -> y -> z in fixed order over three integer
  passes; nothing in it can reorder.
- **Determinism, tested.** `mask_determinism()` re-derives the mask three times (twice
  from the same vector, once from a bit-identical copy) for `k in {0,2,4,8}` on a
  deterministically-textured field and asserts bit-identical results. **PASS.**
- **Chebyshev is the CONSERVATIVE choice.** A cube of half-width `k` contains the
  Euclidean ball of radius `k`, so every active fraction in §1 is an **upper bound** on
  what a Euclidean band of the same `k` costs. The reported ceilings are pessimistic,
  not flattering.
- **BC pin.** Load/Fixture voxels are unconditionally active, so the M3.1 void-load
  gate can never be handed a load on a stiffness-free DOF. In practice these are part
  material at `rho = 1` and already in the core set; the pin is a guard, not a
  workaround.

### 3b. THE GROWTH INVARIANT — "the band must grow before the design can"

**Statement.** Under the restricted solve, out-of-band elements receive
`dc/drho_e = 0` (`simp_compliance` zeroes the sensitivity on Empty voxels). The OC step
`x_new = x * sqrt(-dc/(lambda*dv))` then drives every out-of-band voxel to
`density_min`. **An out-of-band voxel can never grow.** So the mask is sound only if

> **INVARIANT:** the band derived at iteration `i` is a superset of every voxel the
> iteration-`i` step would raise above the active threshold.

**Test.** Directly, on the FULL-domain trajectory — so the answer does not depend on
the restriction being right: derive the band from iteration `i`'s field, take the
**full-domain** step, filter, and count voxels above `1.5*rho_min` lying OUTSIDE that
band ("band escapes"), plus the largest density any such voxel reached.

**Result: ZERO escapes, on every one of the 400 measured iterations across all ten
configurations** (two dilutions, two rungs, `k in {2,4,8}`, cadence 1/2/5/10), and the
largest out-of-band density is exactly `rho_min = 0.0010` — the full-domain step left
every out-of-band voxel at the floor. This holds at `k=2`, the narrowest band swept.

**Why it holds** (so a reader can predict where it would not): the density filter has
radius `rmin = min_feature_mm / spacing` (2.5 voxels here). A design variable reaches
the *physical* field only within `rmin` voxels of itself, and the step is driven by the
FILTERED sensitivity, likewise smeared by `rmin`. So the physical density can only
become non-floor within ~`rmin` of existing non-floor material — and the band's `k` is
measured against that same physical field. **The rule this implies:
`k >= ceil(rmin) + 1`.** At `rmin = 2.5` that is `k = 4`. `k = 2` also measured clean,
so the bound is not tight on these fixtures — but **`k >= ceil(rmin) + 1` is the rule
to ship**, because it is the one with an argument behind it, and §1 shows `k=4` still
leaves a real win at production dilution.

**Consequence for staleness:** the invariant is stated per iteration, so it is only
valid at **cadence 1**. Any cadence `K > 1` must widen the band to
`k >= ceil(rmin) + K` to keep the same argument.

### 3c. Band-update cadence (staleness vs cost)

Rebuilding the mask is three integer passes plus one grid sweep — O(N), no
floating-point work — against a solve that is dozens of V-cycles of 24-DOF element
applies. **The mask rebuild is not the thing to amortise**, and the measured sweep
(`k=4`, cadence 1/2/5/10) says a larger cadence is not free either:

```
cadence      1       2       5      10
terminal   18.82   18.85   18.89   19.04  %   <- looks like it costs nothing
f_bar      27.51   28.61   31.62   40.32  %   <- the cost-relevant number: +47 %
worst dC/C 5.1e-05 1.4e-05 1.2e-05 1.9e-06    <- error gets SMALLER, not larger
escapes        0       0       0       0
```

The TERMINAL active fraction is indifferent to cadence, but the **iteration-mean**
`f_bar` — which is what §4b's projection multiplies — rises 47 % from cadence 1 to 10,
because a stale band lingers over the spread-out early iterations (§1b). So a larger
cadence **costs speed**, in exchange for nothing.

The falling error deserves an honest reading rather than a victory lap: a stale band was
derived from an EARLIER, more spread field, so on a **condensing** trajectory it is
strictly LARGER than the fresh one — it eliminates less, so it errs less. That is a
property of this trajectory shape, not a general licence: on a growing trajectory a
stale band would be too SMALL, and §3b's invariant would not cover it.

**Recommendation: cadence 1.** It is the only setting §3b's invariant covers, its
rebuild cost is negligible, and every larger cadence buys accuracy the project does not
need by spending the exact resource it does.

### 3d. Growth-margin sizing rule

```
k = ceil(min_feature_mm / spacing) + 1        (>= 3, since rmin floors at 1.5 voxels)
```

Resolution-independent by construction: it is the filter radius in voxels, which is
already the resolution-independent length scale (handoff 060 /
`physical_filter_radius`). Under the production config (`min_feature_mm = 2.5`) this is
`k = 3` on a 2.5 mm grid and `k = 4` on a 1.0 mm grid — always in the range where §1
still shows a win.

### 3e. Degeneracy modes, and what Phase 1 must do about each

| Mode | Symptom | Honest handling |
|---|---|---|
| Band covers the whole domain | `active_fraction -> 1.0` | Not an error — the run is simply not faster. **Latch OFF and record it** (§6.5). This is the CLI-capture case (§1c). |
| Band disconnects load from support | restricted solve throws (M3.1 under-constrained) | Never observed here (the core set contains a connected load path whenever material does). Phase 1 must **latch off and re-solve full-domain**, never propagate the throw. |
| Band collapses to the BC pin | `active_fraction ~ 0`, compliance meaningless | Floor the band at core set + BC pin; if the core set is empty the design is already degenerate and the existing gates fire first. |

---

## 4. THE ARITHMETIC

### 4a. Measured per-solve cost, full vs restricted, on identical fields

Same field, same tolerance (`1e-8`), same solver (`MultigridCG_Matfree`), median of 3
interleaved repeats (113 thermal protocol). `dilute40`, 38 400 elements, terminal
`vf 0.26` design. Raw in `arithmetic_stdout.txt`.

```
k     elems           nodes          cg iters   wall      elem   node   WALL     C delta
      full -> rest    full -> rest   full->rest full->rest ratio ratio  speedup  (rel)
2    38400 ->  4141  42025 ->  5314   31 -> 48  0.664 -> 0.104  0.108  0.126   6.41x  1.79e-06
4    38400 ->  7218  42025 ->  8759   31 -> 54  0.660 -> 0.193  0.188  0.208   3.41x  1.41e-06
8    38400 -> 15499  42025 -> 17789   31 -> 62  0.658 -> 0.422  0.404  0.423   1.56x  5.98e-07
```

**The finding that was not anticipated: the restricted solve needs 1.4-2.0x MORE CG
iterations** (31 -> 48 / 54 / 62 here; 32 -> 44 / 49 / 55 at 49x). Removing the
`rho_min` filler leaves the thin skeleton floating alone, which is exactly the geometry
handoff 125 measured the geometric V-cycle failing to contract on. Per-element cost
rises correspondingly (17.2 -> 25.0-27.3 us/element/solve) — the extra iterations plus
worse locality on a scattered element table. The penalty is WORST at large `k` (2.00x
at `k=8` vs 1.55x at `k=2`) and slightly milder at higher dilution, which is why the
efficiency constant below is best at `k=2..4` on the more dilute fixture.

The same measurement at **production dilution** (`ultradilute`, 73 728 elements, 2.05 %
part fill, 49x):

```
k     elems           nodes          cg iters   wall       elem   node   WALL     C delta
      full -> rest    full -> rest   full->rest full->rest ratio  ratio  speedup  (rel)
2    73728 ->  3996  79233 ->  5145   32 -> 44  1.360 -> 0.096  0.054  0.065  14.14x  2.18e-06
4    73728 ->  7012  79233 ->  8529   32 -> 49  1.411 -> 0.177  0.095  0.108   7.97x  1.71e-06
8    73728 -> 15148  79233 -> 17413   32 -> 55  1.407 -> 0.522  0.205  0.220   2.70x  7.50e-07
```

**Net, the realised speedup is 55-76 % of the naive element-count ceiling:**

```
speedup_measured  ~=  C / active_element_fraction ,   C measured in [0.55, 0.76]

  25x fixture:  6.41 x 0.108 = 0.69   3.41 x 0.188 = 0.64   1.56 x 0.404 = 0.63
  49x fixture: 14.14 x 0.054 = 0.76   7.97 x 0.095 = 0.76   2.70 x 0.205 = 0.55
```

Use **`0.65 / f`** as the central estimate (the low end, 0.55, is the `k=8` case where
the CG penalty is largest). Anyone quoting `1/f` is quoting a number this handoff
measured to be optimistic by ~1.3-1.8x.

### 4b. Projection to last night's job shape

The reference job (handoffs 106 / 122): design box **183.5 x 100.4 x 125.4 mm**,
**~4.8-5.4 M voxels**, 4-rung ladder, **535 iterations, 11.5 h wall** in the Jacobi
fallback regime; 106's earlier instance was 10 h+.

Projection, stated as a formula with its inputs visible rather than a single number,
because one input (`f_bar`) is the quantity §1c failed to measure cleanly:

```
wall_active  ~=  wall_full  x  ( f_bar / 0.65 )

  f_bar = the ITERATION-MEAN active element fraction over a rung
          (NOT the terminal value — §1b: the first ~25 iterations run at 40-70 %)
  0.65  = §4a's efficiency constant, held at the CENTRAL value even for the 49x
          row whose own measured constant is 0.76 — i.e. the projection is
          deliberately conservative by ~15 % there
```

Measured `f_bar` at `k=4`, over the whole captured trajectory:

| fixture | dilution | terminal `f` | iteration-mean `f_bar` | projected 11.5 h -> | speedup |
|---|---|---|---|---|---|
| F2 design box (driver, MMA, 4 rungs) | 10x | 0.595 | **0.639** | **11.3 h** | **1.0x** |
| harness dilute (OC, 40 steps) | 25x | 0.188 | **0.275** | **4.9 h** | **2.4x** |
| harness ultra-dilute (OC, 40 steps) | 49x | 0.095 | **0.160** | **2.8 h** | **4.1x** |
| reference job | ~59x | — | not measured | — | — |

At `k=2` the same three rows are `f_bar = 0.438 -> 7.7 h (1.5x)`, `0.191 -> 3.4 h
(3.4x)` and `0.113 -> 2.0 h (5.8x)`.

**Read the first row before the last one.** At 10x dilution — inside the maintainer's
stated 10-60x range — the projection is **1.0x: no win at all** at `k=4`, and 1.5x at
`k=2`. The win only becomes interesting past ~25x. Note also that `f_bar` is **1.5-1.7x
the terminal fraction** on every fixture (0.275 vs 0.188; 0.160 vs 0.095), exactly the
§1b spread-then-condense effect: a projection built on terminal fractions would have
claimed ~1.6x more than this one does.

**What this projection does NOT include, stated so it is not over-read:**
- the multigrid hierarchy REBUILD, which handoff 090 measured at 48-66 % of the solve
  and which the band forces to happen every iteration (it already does — the moduli
  change every iteration — but the band changes its SHAPE too);
- the 125 stagnation the reference run was actually in. Both captures at 1.7 % fill
  reproduced it (§1c). **A run that has fallen back to Jacobi-CG scales with DOF count
  far worse than linearly**, so restriction plausibly helps that regime MORE than this
  linear projection says — but "plausibly" is not measured, and it is not claimed here.

### 4c. Memory

The harness reports a **model**, not an RSS measurement: the CG state plus the
operator's full-length scratch, `7 x 3 x nodes x 8 B`.

```
                 25x fixture              49x fixture
k=2:   6.7 MB ->  0.9 MB  (7.91x)   12.7 MB -> 0.8 MB  (15.40x)
k=4:   6.7 MB ->  1.4 MB  (4.80x)   12.7 MB -> 1.4 MB   (9.29x)
k=8:   6.7 MB ->  2.9 MB  (2.36x)   12.7 MB -> 2.8 MB   (4.55x)
```

Scaled to the reference job's ~5.4 M voxels (~5.6 M nodes) the full-domain solver
vectors alone are **~940 MB**; at the 49x fixture's measured `k=4` node ratio (0.108)
that is **~101 MB**.
This matters beyond speed: handoff 079/091's design-box `std::bad_alloc` was a memory
wall, and the matrix-free solver exists because of it. Active domain attacks the same
wall from the other side. **Not measured here:** the element table, the multigrid
hierarchy levels, and the density/filter arrays, which are grid-sized and are NOT
reduced by the band (the design vector still spans the whole domain). So the whole-
process saving is smaller than the solver-vector ratio; do not quote 7.9x as a process
number.

### 4d. Composition with AMG — REWRITTEN against handoff 131's measurements

> This section was drafted as prediction. Handoff **131 (AMG Phase 0)** then landed and
> measured the partner directly. **It contradicts the comfortable half of what I wrote.**
> The original claim ("they multiply; AMG repays the iteration penalty") is kept below
> only where 131's numbers support it, and retracted where they do not.

The two accelerators attack **different** factors of
`cost = (system size) x (iterations to converge) x (cost per iteration)`.

**Active domain shrinks the system size.** Measured here: element count 0.054-0.404,
node count 0.065-0.423 (§4a).

**AMG attacks iterations to converge — and 131 confirms it does, robustly.** 131 R1
measures **25-97x fewer outer iterations** on the exact stagnation fixtures, and its R1b
shows the iteration win **holds at 103x on a developed-design proxy**. So the half of my
prediction that says *AMG removes the iteration penalty active domain introduces* is
supported: the penalty I measured is 1.4-2.0x (§4a), against an AMG iteration win one to
two orders larger.

**What is retracted: "they multiply" into an end-to-end speedup.** 131 R1b measures that
on a developed-design field (thin members + ~1e5 contrast — the field a real run spends
almost all its iterations at) AMG's setup blows up 6.7x, its coarse operators go **100 %
dense**, and its total wall-clock goes from 2.1x FASTER than the failing geometric path
to **1.11x and 4.1x SLOWER**. An iteration win that arrives with a wall-clock loss does
not multiply with anything. My "`1/f` x whatever AMG buys" formulation assumed AMG's
per-iteration cost was roughly constant; 131 measured that it is not.

**What the composition actually looks like, on 131's numbers:**

| axis | active domain (here) | AMG (131) | composed |
|---|---|---|---|
| system size | **0.054-0.404x** | 1x (same system) | shrinks |
| outer iterations | **1.4-2.0x WORSE** | **25-103x better** | net strongly better |
| per-iteration cost | ~1.5x worse (locality) | setup 6.7x worse on developed fields | **the open question** |
| memory | **0.065-0.423x** | **23.3x WORSE** (2 072 MB vs 88.9 MB) | **see below — this is the real result** |

**The one genuinely NEW claim this reconciliation produces, and it is about memory.**
131 R4 states plainly that memory, not contraction, is what gates AMG Phase 1: its
hierarchy is **23.3x** the geometric matrix-free footprint because it assembles the fine
matrix that 078 deliberately removed. Active domain's saving is **exactly on that axis**
— it removes elements from the assembled operator before AMG ever sees it. At the 49x
fixture's measured `k=4` node ratio (0.108), 131's 2 072 MB hierarchy would be
**~224 MB**, and its 3 296 MB developed-design hierarchy **~356 MB**. *That* is the
composition worth having: **active domain does not make AMG faster, it makes AMG
affordable.** Stated as arithmetic on 131's measured footprint and my measured ratio —
not measured jointly, and it must be, before either side leans on it.

**The interaction that spoils the neat version, stated because it is easy to miss.**
131's developed-design fixture carries its thin members at `rho = 1.0` against
**`rho = 0.02`** filler. My shipped core rule is `rho > 1.5*rho_min = 0.0015` — so
**`0.02` filler is ABOVE my threshold and would stay in the active set.** Active domain
as specified therefore does **not** relieve the ~1e5 contrast that 131 measured
densifying AMG's coarse operators. Relieving it needs the higher threshold §1d flags as
**unmeasured**. So the memory claim above holds (it is about element count), but any hope
that active domain also fixes AMG's densification is **not supported by what I shipped**.

**Sequencing corollary — unchanged in direction, strengthened in reason:** active domain
should land **before** AMG work. Not (as I first argued) because it makes AMG's case
stronger on conditioning, but because 131 identifies memory as AMG's gate and this is the
only measured lever on it.

**What does NOT compose:** the geometric-MG hierarchy CACHE. The band changes shape
every iteration, so the hierarchy must be rebuilt every iteration — and 090 measured
the build at 48-66 % of the solve. The build is O(elements), so it should shrink with
the band, but 090's "Galerkin block is geometry-only" result means the shape of that
win differs from the matvec's. **Measure it in Phase 1; do not assume it.**

---

## 5. GO / NO-GO against the bars stated BEFORE measuring

| # | Bar (stated up front) | Measured | Verdict |
|---|---|---|---|
| 1 | **Ceiling** — report the active fraction honestly, whatever it is | 100 % (snug — **no win**) / 27-84 % (10x) / 11-40 % (25x) / 5-21 % (49x); band width dominates | **REPORTED** |
| 2 | **Correctness** — deltas at solver-tolerance level; an EXACT-answer accelerator, not an approximation | `dC/C` 1e-5 to 1e-3, `dSens` 1e-3 to 1e-2 at CG tol `1e-10`, growing with dilution | **NOT MET as written** — see below |
| 3 | **Mechanics** — deterministic mask, stated sizing rule, growth invariant tested | pure function, bit-identical re-derivation PASS; `k = ceil(rmin)+1`; **0 band escapes, every iteration, all 10 configurations** | **MET** |
| 4 | **Arithmetic** — per-voxel cost x active fraction vs full domain, projected, memory, AMG composition | 14.1x / 8.0x / 2.7x at 49x (6.4x / 3.4x / 1.6x at 25x); `0.65/f` law; **+1.4-2.0x CG-iteration penalty** found; memory model up to 15.4x on solver vectors; end-to-end projection 1.0x (10x) to 4.1x (49x) | **REPORTED** |

### The bar that was not met, stated plainly

Bar 2 asked for **solver-tolerance-level** deltas. They are five to seven orders ABOVE
the solve tolerance. **Restricting the domain is not an exact-answer accelerator, and
this handoff does not claim it is.** It cannot be: the eliminated elements carry a real
`rho_min^p = 1e-9` stiffness and there are millions of them.

**So why GO?** Because the 130/160 lesson is "if restriction moves designs beyond
noise, report it and stop" — and the project already has a **calibrated design-motion
bar** for exactly this judgement: 130's `mean|drho| <= 0.03` on the shipped part, the
bar that BLOCKED the loose-CG flip. Against that bar:

| | 130's loose-CG flip (**BLOCKED**) | `k=2` @ 25x | `k=4` @ 25x | `k=2` @ 49x | `k=4` @ 49x |
|---|---|---|---|---|---|
| worst-over-run `mean\|drho\|` | **0.055** | 2.4e-06 | 6.8e-07 | **8.0e-06** | **3.6e-06** |
| vs the 0.03 bar | **1.8x OVER** | 12 400x inside | 44 000x inside | **3 750x inside** | **8 400x inside** |
| worst `max\|drho\|` (single voxel) | — | 8.4e-04 (36x) | 4.5e-04 (67x) | **1.0e-02 (2.9x)** | **4.2e-03 (7.2x)** |

That is the honest framing: **an approximation whose measured design motion is three to
four orders of magnitude inside the bar this project uses to decide whether an
approximation ships** — the opposite of 130, where the motion exceeded it. Recorded as
an approximation, so the next reader is not misled into thinking it is exact.

But note the last row and §2e: **the single-voxel excursion at 49x dilution and `k=2`
is only 2.9x inside the bar**, and both dilution and rung length push it the wrong way.
That is why the verdict below ships `k=4` and why the Phase 1 gate is at production
dilution and full rung length rather than here.

### Where this GO is weakest (read this before acting on it)

1. **Two axes were measured below their production values, and both push the error the
   same way** (§2d, §2e): iteration count (40 vs 150-250) and dilution (49x vs ~59x).
   Neither extrapolation is attempted here.
2. **No converged ultra-dilute DRIVER capture.** Both real CLI runs at 1.7 % fill were
   compromised (§1c); the ultra-dilute evidence is a harness OC fixture, and the only
   fully-converged 4-rung driver ladder in the ceiling table is the **10x** box —
   where the projection is **1.0x, i.e. no win** (§4b).
3. **MMA is not measured.** The trajectory comparison is OC (§2b). The sensitivity-delta
   number is the updater-independent bridge, but it is a bridge, not a measurement.
4. **The `1.5*rho_min` threshold gets no win on a gray run** (§1d), and the higher
   thresholds that would were not error-measured.
5. **The win is not uniform across the maintainer's stated 10-60x range** — it is ~1x
   at the bottom of it and ~4x at the top. Anyone reading "10-60x dilution" as "a
   speedup across the whole range" is reading more than this evidence supports.

### Verdict

**GO**, with four conditions on the Phase 1 deliverable:

1. `k = ceil(min_feature_mm / spacing) + 1` — **`k=4` under the production config, not
   `k=2`** (§2e) — cadence 1, core rule `rho > 1.5*rho_min`.
2. Framed as an **approximation with a measured design-motion budget**, not as a
   byte-identical accelerator. Default OFF; byte-identical when off.
3. A **full-length-rung `|drho|` measurement under MMA at production dilution** as the
   gate to any production flip. The 40-step OC result is necessary, not sufficient.
4. The latch (§6.5), because at the low end of the dilution range the feature buys
   nothing and must say so rather than silently costing.

---

## 6. PHASE 1 SKETCH

**Scope: the matrix-free operator only. One opt-in field, one CSV column, one latch.**

1. **`SimpOptions::active_domain_band` (int, default 0 = OFF).** `0` keeps the current
   path byte-for-byte — the same opt-in discipline as `min_feature_mm == 0`,
   `cg_tolerance_loose == 0`, `warm_start_inherit == false` (THE ONE RULE). `> 0` is
   `k`; `MinimizePlasticOptions` derives `ceil(min_feature_mm/spacing) + 1` when the
   caller asks for auto.
2. **Where the mask lands: `mf_build_reduced` / `mf_build_elems`
   ([matfree.cpp](core/src/fea/matfree.cpp)).** The element table is already built from
   the grid's non-Empty voxels and the M3.1 void gate already eliminates DOFs no
   surviving element touches. The whole feature is therefore: **pass an optional
   per-voxel active mask into `mf_build_elems` and skip inactive elements.** The void
   gate, the reduced numbering, the Jacobi diagonal, the multigrid hierarchy build and
   `apply_kgg` all follow for free and stay exact on the surviving system. **No new
   solver, no new boundary-condition code** — the band boundary is the existing
   traction-free free surface. That is why Phase 0 could prototype the whole thing with
   a re-tagged copy of the grid.
3. **Mask ownership: `simp.cpp`, not the FEA layer.** It needs the physical density, so
   derive it in the SIMP loop and pass it down as a `const std::vector<char>*` beside
   `elem_youngs`. Keeps the FEA layer stateless and keeps the mask a pure function of a
   field the optimizer already holds.
4. **`active_fraction` as an `iterations.csv` column** (117 schema), plus
   `active_domain_band` echoed in `run_info.json`. Write `1.0` on the OFF path so the
   column is meaningful for every run; the golden `test_observability` change is one
   line. This is the column that turns a future "why was this run slow?" into a read
   rather than a forensic exercise — 117's whole point, and 125 §0's lesson.
5. **Latch-style honesty when the mask degenerates.** Mirror 128's `mg_mode` latch: if
   `active_fraction > 0.95` for K consecutive iterations, **latch the mask OFF for the
   rest of the rung**, record `active_domain_latched` in `run_info.json`, and emit the
   CLI WARNING. A band that covers the domain costs the derivation and the hierarchy
   churn and buys nothing — and per 125 §0, a feature that silently does nothing while
   reporting nothing is the failure mode this codebase keeps re-learning. Same latch if
   a restricted solve throws under-constrained: fall back to full domain, record it,
   do not propagate.
6. **Test seam — `test_active_domain`:** (a) `band == 0` is bit-identical to the current
   path on the Gate-V2 fixture; (b) the mask is a pure function (re-derivation
   bit-identical); (c) the growth invariant holds over a short trajectory; (d) the latch
   fires AND is recorded when the band is forced to 100 %.

**Explicitly NOT in Phase 1:** AMG (§4d — separate, sequenced after), any change to the
ladder / updater / filter, and any app-side surface. The band is a solver-internal
accelerator and must not become a user-visible knob.

**Phase 1's first measurement, before any of the above:** a converged, well-resolved,
ultra-dilute DRIVER capture (§1c's gap) and a full-length-rung MMA `|drho|` comparison
(§5). Both are measurements this Phase 0 could not afford; neither is optional before a
production flip.

---

## 7. WHAT THE REBASE DOES AND DOES NOT INVALIDATE

Every number here was captured at **`ac9769f`**. The branch is now rebased onto
**`c6c7af7`**, which carries handoffs 131 (x2), 132 and 133 — including production
changes to `src/simp` and the solver. The harness **rebuilds and links clean** against
it. What that means, split honestly:

**Cannot have moved** — §1's active fractions, §2's `|drho|` deltas and §3's determinism
and growth-invariant results. The mask is a **pure function of a density field** (§3a);
given the same field it returns the same set regardless of how that field was produced.
131's `rung_infeasible` changes WHICH fields a run visits, not what the mask does to one.

**Could have moved, and in the unfavourable direction** — §4b's projection input `f_bar`.
131's detector is **armed by default** (`infeasible_window = 5`, `simp.hpp`). A rung that
now fast-fails runs FEWER iterations, and per §1b the iterations it drops are the LATE,
cheap, low-active-fraction ones — the early spread-out iterations are the expensive ones
and they are exactly what a fast-fail keeps. **So arming it RAISES `f_bar` and LOWERS the
projected win.** Neither direction is measured here; §4b's projection should be re-derived
on a post-131 capture before anyone leans on it.

**Untested against the new main** — nothing re-run. The rebuild proves compilation and
linkage, not numerical agreement. A Phase 1 that re-runs `ceiling` on `c6c7af7` should
expect `f_bar` to differ and should treat any change in the ACTIVE-FRACTION-vs-field
relationship as a bug in the mask, not as drift.

---

## Gates / provenance

- **No production code changed.** `git diff main -- core/src core/include` is **empty**.
  The only additions are the harness `core/tests/harness/active_domain_probe.cpp` (not
  wired into CTest — same status as `cg_tol_probe.cpp`, `mma_probe.cpp`,
  `per_iter_probe.cpp`), this handoff, and `docs/handoffs/evidence/134/`.
- **Nothing was flipped.** No option default moved; there is no `active_domain_band`
  field yet. Production is byte-identical to `main`.
- **The restricted solve is prototyped entirely through the PUBLIC API** —
  `minimize_plastic`, `minimize_plastic_solved_grid`, `simp_compliance`, `oc_update`,
  `make_density_filter`, `physical_filter_radius`, `read_density_f16`, and the 117
  observability hooks. No private header, no patched translation unit (contrast 125,
  which needed one temporary patch).
- **CTest not re-run** — no library source changed, so there is nothing for it to cover
  that `main`'s last green run did not (61/61 as of 131). The harness links into no test
  target. **The library and CLI WERE rebuilt** against the post-rebase `c6c7af7` and the
  harness recompiles warning-clean against it (§7).
- **Thermal protocol (113):** every §1/§2/§3 number is deterministic (active fractions,
  iteration counts, `|drho|`, escapes) and was captured once. Only §4a's wall-clock is
  thermally exposed; it is the median of 3 interleaved full/restricted repeats, taken on
  an otherwise-idle machine, and the CG-iteration ratio — not the wall ratio — is the
  durable part of the cost claim. The §1/§2 captures DID share the machine with each
  other, which costs wall-clock only and cannot move a deterministic number.
- **Machine:** Apple M2 Pro (6 P + 4 E), macOS 26.5.1, Release build, matrix-free
  thread count 10.
- **Two captures were cut short by the probe budget and are labelled as such** — the
  64^3 `F3` ceiling fixture (4 iterations) and the res-24 CLI capture (4 iterations).
  Neither is used for a headline number; both are in the evidence directory as they
  stand. `ceiling.csv` is written append-and-flush per row, so a truncated run keeps
  everything it reached.

## Evidence (every claim in this handoff traces to one of these)

| file | what |
|---|---|
| `evidence/134/ceiling.csv` | §1 — per-iteration active fractions, every fixture/rung/iteration, elements AND nodes, `k in {0,2,4,8}` |
| `evidence/134/ceiling_summary.txt` | §1a/§1b — the rendered tables above |
| `evidence/134/trajectory.csv` | §2/§2e/§3b/§3c — per-iteration full-vs-restricted deltas, `|drho|`, band escapes, all **10** configurations (400 rows) |
| `evidence/134/trajectory_stdout.txt` | §2c — raw harness output including the per-iteration table (25x fixture, 7 configurations) |
| `evidence/134/ultradilute_stdout.txt` | §2e/§4a — the 49x fixture: 3 trajectories + its arithmetic block |
| `evidence/134/arithmetic_stdout.txt` | §4a — raw timing/CG/memory output (25x fixture, idle machine) |
| `evidence/134/ceiling_cli_res16_plateau.csv` | §1c — ceiling table for the real CLI capture |
| `evidence/134/threshold_sweep_cli_res16_plateau.csv` | §1c/§1d — threshold x band-k sweep on the plateau-terminated design |
| `evidence/134/threshold_sweep_cli_res16_rung0.csv` | §1d — same sweep on the 25-iteration capture |
| `evidence/134/cli_box_res24_partial_iterations.csv` | §1c — **the 125-stagnation repro**: iteration 4, `cg_multigrid=0`, `hier_built=1`, 15 516 Jacobi iterations |
| `evidence/134/cli_box_res16_plateau_iterations.csv` | §1c — the plateau-terminated rung 0 |
| `evidence/134/cli_box_res*_run_info.json` | §1c — solver/config provenance for each capture |
| `evidence/134/summarize_ceiling.py`, `summarize_trajectory.py` | the scripts that render the tables from the CSVs |
| `evidence/134/box_job.json` | the design-box job for the CLI captures (the res-24 run is the same file with `resolution: 24`) |

## Recipe (reproduce)

```bash
# 1. Build the library + CLI in this worktree
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j10 --target topopt topopt_cli

# 2. Build the harness (standalone, not a CTest target)
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
  core/tests/harness/active_domain_probe.cpp build/libtopopt.a -o /tmp/adp

# 3. The ceiling table (F1 snug + F2 10x box + F3 dilute; hours — F3 is the long pole)
TOPOPT_AD_CSV_DIR=docs/handoffs/evidence/134 /tmp/adp ceiling

# 4. Correctness + mechanics (7 configurations x 40 steps; ~1 h)
TOPOPT_AD_CSV_DIR=docs/handoffs/evidence/134 /tmp/adp traj

# 5. Arithmetic — run on an IDLE machine, it is the only wall-clock claim
TOPOPT_AD_CSV_DIR=docs/handoffs/evidence/134 /tmp/adp arith

# 6. Ultra-dilute (~2 % fill) trajectory + arithmetic
TOPOPT_AD_CSV_DIR=docs/handoffs/evidence/134 /tmp/adp ultradilute

# 7. The real CLI design-box capture via the 117 flags, then scan it
REPO=$PWD
mkdir -p /tmp/boxjob && cp core/tests/fixtures/demo/l-bracket.step /tmp/boxjob/
cp docs/handoffs/evidence/134/box_job.json /tmp/boxjob/job.json
(cd /tmp/boxjob && "$REPO/build/topopt-cli" run job.json --out out \
   --snapshots --snapshot-every 1 --snapshot-cap 900)
# writes ceiling.csv rows tagged `cli_snapshot` + threshold_sweep.csv
TOPOPT_AD_CSV_DIR=docs/handoffs/evidence/134 /tmp/adp snapshots /tmp/boxjob/out/snapshots

# 8. Render the tables
python3 docs/handoffs/evidence/134/summarize_ceiling.py \
        docs/handoffs/evidence/134/ceiling.csv
python3 docs/handoffs/evidence/134/summarize_trajectory.py \
        docs/handoffs/evidence/134/trajectory.csv
```

Note on step 3: the `F3` 64^3 fixture was cut by the probe budget at 4 iterations
(~2 min/iteration under contention). Raise `iter_cap` or drop the fixture depending on
the budget available; `ceiling.csv` is written append-and-flush per row, so a truncated
run still yields everything it reached.
