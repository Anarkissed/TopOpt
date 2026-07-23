# 132 — Mixed-precision production flip (BLOCKED) + P-core pin (SHIPPED)

Task B2: the two "banked free wins" handoff 113 left owed. One of them was not free.

**Outcome in one line: (C) the P-core pin ships; (D) the mixed-precision flip was
implemented, gated, and BLOCKED by its own gate — it costs ~20% MORE CG iterations,
not ~1.1-1.15x fewer.**

Library defaults are untouched either way. `run_info.json` tells the truth:
`matfree_threads=6`, `mixed_precision:false`.

---

## D — MIXED PRECISION: measured, BLOCKED

### What was proposed

113 §D: the FP32 mixed-precision V-cycle shipped complete in 092, but
`configure_production_options` never called `fea_set_matfree_mixed_precision`, so
every production run to date solved FP64 and echoed `mixed_precision:false`. Three of
the four fine applies per CG iteration sit inside the V-cycle, and the matvec is
bandwidth-bound, so 113 expected **~1.1-1.15x on the iterate share** for a one-line
flip. The certificate solves stay FP64 — that is the capability's own design, not an
extra guarantee.

113 attached a condition: *"Verify no iteration-count regression on the ladder before
flipping."* That verification is this handoff, and it is the reason the flip is not
in the tree.

### The gate

One full production ladder on the l-bracket fixture, on current main (127 stagnation
latch + 128 flatness-escape world), FP64 vs FP32, **both phases the conditional-
projection gate (123) produces** — the grayscale phase and the fired-projection
phase, separated per-iteration by the observer's `beta` (`beta == 0` is gray,
`beta > 0` is projecting).

Harness: `core/tests/harness/mixed_precision_probe.cpp` (not wired into CTest, in the
lineage of `cg_tol_probe.cpp`). Four modes, interleaved fp64/fp32 so thermal drift
cannot bias one precision. Two exact replicates per mode.

Fixture: l-bracket loadcase, **48 x 16 x 48**, 16128 solid voxels, h = 2.0 mm.

### Two traps this gate had to clear first

**1. A vacuous grid.** The first attempt reused the tiny 16 x 5 x 16 l-bracket the
sibling probes use. `ny = 5` is odd, so the coarsener rejected the hierarchy
(`mg_grid_coarsenable` halves only while EVERY axis is even and stays >= 2), every
solve fell back to Jacobi-CG, and **mixed precision never executed at all**. All four
modes returned a perfect, meaningless `1.000x` at `mg_frac=0.00`. Mixed precision
lives ONLY in the V-cycle, so on a non-coarsenable grid the fp64 and fp32 runs are
literally the same code path. The harness now calls `mg_grid_coarsenable` up front and
**refuses to run** rather than report that. The shipped fixture reaches `mg_frac=1.00`
— multigrid on every single solve.

**2. Wall-clock is unusable on this box — worse than 113 recorded.** The two FP64
modes (`gate-fp64`, `forced-fp64`) are provably the SAME computation: identical CG
counts (40715), identical designs, identical margins. They clocked **592.60 s and
239.15 s** — a **2.5x spread**, each stable across its own replicates. So the spread
is systematic between modes, not run-to-run noise, and it dwarfs 113's ±30% band.
**No wall-clock number from this run is quoted as evidence, for or against.** The
iteration counts are deterministic and exactly reproducible, and they are the claim.

### Result

| mode | outer iters | CG iters | gray CG | projected CG | mg_frac |
|---|---|---|---|---|---|
| gate-fp64 | 625 (gray 246 / proj 379) | 40715 | 13741 | 26974 | 1.00 |
| gate-fp32 | 625 (gray 246 / proj 379) | **48717** | **15947** | **32770** | 1.00 |
| forced-fp64 | 625 | 40715 | 13741 | 26974 | 1.00 |
| forced-fp32 | 625 | 48717 | 15947 | 32770 | 1.00 |

**fp32 / fp64 CG iterations: total 1.197x, grayscale 1.161x, fired-projection
1.215x.** All four values are exact — both fp64 replicates gave exactly 40715 and both
fp32 replicates exactly 48717, so this is not noise with an error bar.

Per rung (`docs/handoffs/evidence/132/mixed_precision_ladder.csv`):

| vf | iters (gray/proj) | CG fp64 | CG fp32 | ratio |
|---|---|---|---|---|
| 0.68 | 130 (53/77) | 7185 | 9017 | 1.255x |
| 0.52 | 126 (47/79) | 6539 | 7941 | 1.214x |
| 0.38 | 145 (55/90) | 8419 | 10144 | 1.205x |
| 0.26 | 224 (91/133) | 18572 | 21615 | 1.164x |

The `gate` and `forced` arms coincide because this fixture is genuinely gray:
projection FIRED on all four rungs even at the production threshold 0.07, so forcing
it changed nothing. They therefore serve as a free second replicate. Both phases were
still measured independently, within each rung, and **both regress**.

**Correctness is untouched.** Outer MMA iterations identical (625), accept/reject
verdicts identical, terminal design mean|Δρ| = 1e-5, max 0.000, margin delta 0.00%,
compliance delta 0.00%. The FP64 outer certificate does exactly its job. **This is a
cost failure, not a correctness failure** — which is precisely the failure mode 092's
design predicted was the only one available.

### Why it lost, mechanically

`simp.cg_tolerance` is **1e-8**, which is essentially FP32's ~1e-7 relative precision.
Near convergence the single-precision V-cycle stops returning a useful correction and
starts returning its own rounding noise, so CG stalls and burns extra iterations. The
47-83% gains in the literature (Kronbichler, Ljungkvist et al. 2019) come from the
opposite end of that regime. A ~20% iteration regression is not recoverable by a
~1.15x per-iteration bandwidth saving: 1.197 / 1.15 ≈ **1.04, still a net loss**, and
that arithmetic is generous to the flip.

**The measured cost is probably an UNDER-estimate.** In `solve_mgcg_matfree`, when an
FP32 attempt fails to reach tol within budget, the solver retries the whole solve in
FP64 on the same hierarchy — and `diag.iterations = it` is overwritten by the retry.
The burned FP32 cycles are therefore invisible to the very counter this gate reads.
(Most solves clearly did succeed in FP32, or the counts would match FP64 exactly
rather than exceed it, so retries are not dominant — but they are not free either.)

**The regression grew with scale**, so it is not a small-problem artifact that
production resolution would wash out: 1.165x on a smaller coarsenable grid
(16 x 8 x 16) → **1.197x** at 48 x 16 x 48.

### Disposition

`configure_production_options` does **not** arm mixed precision. The capability is
untouched and still available opt-in via `fea_set_matfree_mixed_precision` — this is a
decision about production, not a withdrawal of 092. `test_production_parity` now
**asserts the global stays OFF**, with the measured reason in the failure message, so
anyone arming it has to re-run this gate and land new numbers first.

Reviving it should mean changing what made it lose, not retrying it: an FP32
preconditioner under a LOOSER trajectory tolerance (composes with the 128 adaptive-CG
machinery), or FP32 confined to the early slack iterations where the preconditioner's
precision floor is far from binding.

---

## C — P-CORE PIN: shipped

`production_matfree_thread_count()` (new, in `production.hpp` / `production.cpp`)
returns the performance-core count on Apple silicon via
`sysctl hw.perflevel0.physicalcpu`, and `std::thread::hardware_concurrency()`
everywhere else — Intel Macs (where the key does not exist), Linux, Windows, or any
failed query. Always >= 1. `configure_production_options` installs it via
`fea_set_matfree_threads`. On this box: **6**, down from 10.

Justification is 113's thread sweep, not a fresh measurement: FP64 matvec at 6 / 8 /
10 threads = 45.0 / 45.0 / 48.3 GB/s. The apply is gather/bandwidth-bound, so the four
E-cores buy ~0-7% at best while contending for the same memory system, and 113 watched
a 10-thread run REGRESS to 36 GB/s under sustained thermal load. The production ladder
is exactly such a soak. **This handoff does not re-litigate that sweep; it acts on it.**

**Determinism asserted at both counts.** The 8-colour (2x2x2) partition fixes the
accumulation order independently of thread count, so this is bit-identical by
construction. `test_production_parity` now proves it end-to-end where the change
actually lands — a whole production `minimize_plastic` ladder at the pinned count vs
at full hardware concurrency:

```
  [132 (C)] design bit-identical at 6 and 10 threads
production parity (handoff 093): all checks passed
```

The pin is a default, not a lock: an explicit `fea_set_matfree_threads(n)` after
`configure_production_options` wins, and `n <= 0` restores automatic resolution. Both
are asserted.

### The one platform-conditional in /core/

`#if defined(__APPLE__)` around `<sys/sysctl.h>` in `production.cpp` is the only
platform-conditional code in `/core/`, and it is deliberately confined to the
production *configuration* layer rather than the solver. ARCHITECTURE §3/§4 forbid
Apple **frameworks** in `/core/`; `<sys/sysctl.h>` is a BSD libc header — nothing links
Foundation or CoreFoundation and the CMake link line is unchanged. Every non-Apple
target compiles the `#else` path and gets today's exact behaviour, so this is a no-op
off Apple silicon.

---

## Config echoes (the one rule)

`test_production_parity` (a) now checks each global **before and after**
`configure_production_options`:

| global | library default (Gate-V2 / reference) | production |
|---|---|---|
| Galerkin block cache | off | **on** |
| mixed precision | off (FP64) | **off** — 132 (D) blocked |
| matfree threads | `hardware_concurrency` (10) | **6** (P-core pin) |

These are read through the 114 accessors — the same functions `run_job.cpp`'s
`build_run_info` reads — so asserting them here is asserting the `run_info.json` echo.
Verified live by the probe under the real production config:

```
production config: threads=6 (production_matfree_thread_count=6)  galerkin_cache=1  mixed_precision=0
```

`production.cpp` is the sole caller of either setter outside tests, and all three
production front-ends (`bridge.cpp`, `run_job.cpp`, `loadcase.cpp`) route through
`configure_production_options`, so the config cannot drift.

---

## Evidence

- Ladder table + per-rung CSV: `docs/handoffs/evidence/132/mixed_precision_ladder.csv`
- Harness: `core/tests/harness/mixed_precision_probe.cpp`
  (`mp_probe 48 16 12`; `TOPOPT_MP_PROBE_CSV_DIR` for the CSV,
  `TOPOPT_MP_PROBE_REPS` for replicates)
- Raw ctest: see below.
- Box: Apple M2 Pro, 6 P + 4 E (`hw.perflevel0.physicalcpu = 6`,
  `hw.logicalcpu = 10`).

### Thermal protocol (113)

Iteration counts, CG counts, margins, designs and gate verdicts are deterministic —
captured once, exact, no thermal band. Modes interleaved fp64/fp32. Wall-clock was
recorded but is **explicitly not quoted**, because two provably identical FP64 runs
differed 2.5x (592.60 s vs 239.15 s) in this very run. The full ctest suite was held
until the ladder finished so it could not contaminate the measurement.

## Limitations

- **One fixture, one scale.** 48 x 16 x 48 (16128 solid voxels, ~48k DOF) is well
  below the ~2.29M DOF at which 113 measured its roofline numbers. The regression grew
  from 1.165x to 1.197x between the two scales tested, i.e. it moved AGAINST the flip
  with size, which is why the verdict is stated as blocked rather than "unproven at
  production scale". A run at res 64-128 would sharpen it, at multi-hour cost.
- **The FP32→FP64 retry count is not instrumented.** Quantifying the hidden cost would
  need a new diagnostic field in `CgInfo`; out of scope here, and it can only make the
  flip look worse.
- The P-core pin's payoff is not re-measured here — 113's sweep is the evidence, and
  this handoff's own wall-clock was demonstrably too noisy to add anything.

---

## Raw ctest (full suite, run after the ladder so it could not contaminate it)

```
57/60 Test #57: production_parity ................   Passed   18.63 sec
...
100% tests passed out of 60

Total Test time (real) = 774.09 sec
```

`production_parity` output, showing the (C) end-to-end determinism check:

```
  [132 (C)] design bit-identical at 6 and 10 threads
production parity (handoff 093): all checks passed
```

## Files

- `core/src/simp/production.cpp` — `production_matfree_thread_count()` +
  `fea_set_matfree_threads(...)`; the (D) decision recorded in place as a
  do-not-re-add note.
- `core/include/topopt/production.hpp` — declaration + the "what it does NOT arm"
  contract.
- `core/tests/validation/test_production_parity.cpp` — before/after echoes for all
  three globals, override/restore semantics, and (f) the both-thread-counts ladder.
- `core/tests/harness/mixed_precision_probe.cpp` — the gate harness (new, not in CTest).

The whole functional diff is one helper and one setter call; everything else is
documentation and test. No library default, no app, no bridge, no wire format changed.
