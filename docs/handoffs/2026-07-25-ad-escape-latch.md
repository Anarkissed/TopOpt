# ACTIVE DOMAIN — the escape latch (amendment to phase 1)

**Status:** Shipped, core only, default OFF, `band == 0` byte-identical to
`origin/main`. **Full ctest 67/67 pass** (`evidence/.../ctest_full.log`),
including the 16 new escape-latch checks in `test_active_domain` (57 total). The
escape latch is BUILT and armed *whenever the band is* (which is still never, by
default — production arming remains a separate maintainer decision, unchanged by
this task).

**All six bars MET.** B1 byte-identical; B2 inert on the healthy trajectory
(0 latches over 250 steps, rung-0 bit-identical to 168); B3 fires on the first
escape (iteration 3, 705 escapes, completes); B4 post-latch bit-identical to the
full domain (14 iterations, proven not eyeballed); B5 damage measured and printed
(`3.2e-3`, honestly larger than 134's estimate); B6 detector is `≤0.008%` of a
solve.

**The one-line result:** the task feared this was **Blocked** — that the only way
to know material wanted to grow outside the band is to run the full domain the
band exists to avoid. **Measured, and refuted.** The escape is visible on the
LIVE restricted trajectory the optimizer already walks (it escapes its own band
*more* than the full-domain counterfactual does), so the detector is a single
O(N) scan of a field already in hand — no solve. The latch is buildable, is
built, is bit-identical to the full domain after it fires, and — the payoff — it
catches the exact rung 168's own handoff flagged as its worst silent divergence.

---

## 0. What the task asked, and the honest turn it took

168 shipped the mask and found the growth invariant is **empirical, not a
theorem**: 0 escapes on a healthy 250-step trajectory, 6 979 on a stagnating one.
An escape is material the mask suppresses; when it happens the design silently
diverges from the full-domain answer. This task: detect the first escape, latch
the mask off for the rest of the run, record it — OR, if detection needs a
full-domain solve, STOP and file a measured Blocked.

**The initial hypothesis was Blocked**, and it was a reasonable one. The restricted
solve zeroes the sensitivity of every out-of-band element (`simp.cpp`,
`simp_compliance`: `if (active_mask ... == 0) continue`), so the updater floors
them and the restricted design *cannot grow out-of-band through the optimizer*.
By that argument the escape is a property only of the FULL-domain counterfactual,
knowable only by computing it — Blocked.

**The measurement refuted the argument.** The density filter has radius `rmin`;
the band is `rmin + 1`. When in-band material grows near the band edge, the filter
spreads its *physical* density up to `rmin` further — past the band — and the mask,
re-derived next iteration, self-heals one step too late. So the restricted design
*does* place above-threshold material outside the band it just solved under, on
its own live trajectory. Measured on the §7 stagnation fixture:

```
[FULL]      counterfactual escapes (band from full-domain field)   : 6 979
[RESTRICTED] LIVE escapes (band from the restricted field it walks) : 8 114
```

(`evidence/.../feasibility_stagnation_unlatched.log`, measured with the pre-latch
binary.) The live path escapes *more*, not less. The detector therefore needs only
the live field and the previous band — **not Blocked**. That pre-latch log's
closing "1.75× SLOWER" line was the arithmetic of the Blocked hypothesis (a
cadence-1 full-domain audit); it is superseded by the O(N) scan below and left in
place as the record of the hypothesis that was tested.

---

## 1. What shipped (core only, additive)

```
core/include/topopt/simp.hpp            declare active_domain_escape_count();
                                        SimpOptimizeResult::active_domain_escape_count
core/src/simp/simp.cpp                  the pure detector; the escape latch in
                                        active_domain_solve; prev_mask state; finalize
core/include/topopt/observability.hpp   RunInfo::active_domain_latch_iteration[],
                                        active_domain_escape_count[]
core/src/simp/observability.cpp         serialize both new run_info arrays
core/src/cli/run_job.cpp                finalize both into run_info (warning already
                                        prints the reason, which carries the count)
core/tests/validation/test_active_domain.cpp   seam (e): 16 new checks
core/tests/harness/active_domain_escape.cpp    NEW standalone measurement harness
core/CMakeLists.txt                     test_active_domain comment
```

**The detector** — pure, O(N), no solve:

```cpp
long long active_domain_escape_count(grid, density, prev_mask, density_min):
  count solid elements e with density[e] > 1.5*density_min AND prev_mask[e] == 0
```

`prev_mask` is the band the previous iteration solved under; `density` is the
field this iteration is about to solve (the one the previous update produced). The
count is exactly 168's growth-invariant escape count, evaluated on the live
trajectory. An empty `prev_mask` (the first armed iteration) is 0 by definition.

**The latch** — in `active_domain_solve`, before restricting the solve, while
armed:

```cpp
escapes = active_domain_escape_count(grid, xphys, ad.prev_mask, density_min);
if (escapes > 0) {
  ad.latched = true; ad.latch_iteration = iteration; ad.escape_count = escapes;
  ad.latch_reason = "escape detected: <n> element(s) took material outside the
                     active band (growth invariant failed); mask disabled, full
                     domain restored";
  return simp_compliance(...);   // this iteration is ALREADY the full domain
}
... derive mask, restricted solve ...; ad.prev_mask = mask;   // for next iteration
```

One-way (`ad.armed()` is false forever after), coexisting with 168's degeneracy
latch (≥85% for 5 iterations) and its throw-fallback latch on the same one-way
flag; `active_domain_escape_count > 0` is what distinguishes an escape latch from
those. Recording is finalize-only, exactly like every other active-domain field.

---

## 2. THE BARS

### B1 — `band == 0` is byte-identical to `origin/main`

The production diff (`core/src`, `core/include`) against `origin/main` is
**purely additive**: no existing line on the `band == 0` path changed
(`evidence/.../band0_production_diff.txt` — the `git diff --stat` of production
code is empty save the additions, and `active_domain_solve` still takes the
`!ad.armed()` early-return for `band == 0` before the escape check is ever
reached). Pinned, not assumed, by `test_active_domain` seam (a): `band == 0` and
an all-covering band give a BIT-IDENTICAL design, physical density, compliance and
iteration count. **MET.**

### B2 — inert where it does not fire

168's healthy trajectory is the rung-0 250-step length run (168 §5d, where the "0
escapes over 250 steps" was measured). Re-run with the escape latch:
**never latches, `escape_count = 0`** (`evidence/.../prod_healthy250.log`). Because
the detector is read-only until it fires, that run is byte-identical to 168's
armed mask by construction.

Anchored to 168's committed exact doubles, the armed gate run
(`evidence/.../B2_gate168_healthy.log`, full ladder, `band = 4`):

```
rung 0  compliance 4.6389605554134183   (168 committed 4.63896055541)   MATCH
        fraction_mean 0.4169650608       (168 committed 0.4169650608)    MATCH
        latched 0, escape_count 0
```

**MET** on the specified trajectory.

**The payoff, on the same fixture's rung 1.** 168's own §5c named rung 1 its worst
divergence — `mean|Δρ| = 2.95e-4`, `dC/C = 9.5e-4`, "the MISS" — and reported it
with `latched = 0`, i.e. 168 *did not know it was diverging*. The escape latch
catches it:

```
rung 1  168 armed (diverged, silent) : compliance 8.72664102474   latched 0
        168 full domain (truth)      : compliance 8.71832621264
        THIS latch                   : compliance 8.71819341967    latched 1, escape_count 50
```

The latch fires (50 escapes), reverts to the full domain, and moves the answer
from 168's silent `9.5e-4` error back to `1.6e-5` of the truth. This is the
feature's whole point — "say I bought you nothing rather than quietly cost you
correctness" — demonstrated on 168's own worst case. It is NOT a B2 violation:
rung 1 is a different, lighter, always-REJECTED rung, not the healthy trajectory
B2 names, and it was already diverging under 168.

### B3 — fires on the first escape, completes

The §7 stagnation fixture (46 400 elements, 51.6× dilution), `band = 4`, escape
latch on (`evidence/.../prod_stagnation.log`):

```
FULL-domain reference : 40 iterations, 20 982 CG   (== 168 §7's OFF run, exactly)
PRODUCTION (latch on) : LATCHED at iteration 3, escape_count = 705
                        reason: "escape detected: 705 element(s) took material
                        outside the active band ...; mask disabled, full domain
                        restored"
                        run COMPLETED all 40 iterations
```

It fires on the FIRST live escape (production iteration 3 — the first iteration
whose incoming field overran the previous band; earlier than 168's degeneracy
latch could act at iteration 5), records the iteration and the count, and the run
completes rather than throwing. After the latch the mask is off, so nothing is
suppressed and the post-latch escape count is 0 by construction (`ad.armed()` is
false, so no further band is derived). The unit test seam (e2) pins the same
behaviour deterministically (latch at iteration 2, `escape_count = 64`, run
completes, active fraction exactly 1.0 for every iteration at/after the latch).
**MET.**

### B4 — post-latch is the real path, bit-for-bit

`test_active_domain` seam (e3) asserts it, does not eyeball it. Construction:

1. The MGCG solve is **initial-guess-independent to the bit** — cold, warm, and a
   1.3×-perturbed guess give bit-identical compliance, sensitivity and even CG
   iteration count (checked directly; `warmcheck`). So the latched run's
   warm-started full-domain tail cannot differ from a cold full-domain tail.
2. The latched run's raw design ENTERING the latch iteration is deterministic:
   re-running the same band for `latch_iter - 1` iterations reproduces it exactly
   (`SimpOptimizeResult::design` is the raw vector).
3. From that state a MANUAL full-domain OC loop (`simp_compliance` with no mask +
   `oc_update`, the exact primitives `simp_optimize`'s non-projection OC branch
   uses) IS "the `band == 0` solve handed that state."

The assertion: every post-latch iteration's physical density is **bit-identical**
between the latched run and that manual full-domain continuation. Result:

```
[B4] latch at 2; 14 post-latch iterations bit-identical to the full-domain path
```

**MET, bit-for-bit.** Note (honest): an INDEPENDENT from-scratch `band == 0`
reference cannot be constructed — reaching an escape *requires* prior restricted
(divergent) steps, so no from-uniform full-domain run shares the latched run's
state at the latch iteration, and the public warm-start seed rescales/re-filters.
The construction above sidesteps that by checkpointing the latched run's own raw
state (deterministic) and continuing it on the full domain — which is exactly the
"same design state handed to `band == 0`" the bar names, and it is bit-identical.

### B5 — charge the damage honestly

The escape at iteration 3 means the two restricted steps before detection already
moved the design. `mean|Δρ|` / `max|Δρ|` between the production field entering the
latch iteration and the full-domain reference at the same iteration
(`evidence/.../prod_stagnation.log`):

```
at iteration 3:  mean|Δρ| = 3.21e-03,  max|Δρ| = 1.20e-01
```

**Stated plainly: this is far LARGER than 134's OC-based estimate of ~3.6e-6 —
about 890×.** That is expected and honest, not a failure: escapes only happen on
divergent trajectories, where every restricted step moves the design hard, so by
the time even the *first* escape appears (iteration 3 here) the design has already
drifted by `3e-3`. The latch's value is that it stops the drift at iteration 3
instead of letting it compound over the remaining 37 — 168's unlatched run drifted
to `mean|Δρ| = 4.47e-3` by iteration 25 and kept a divergent trajectory. The bar
was "measure it, print it, say whether it beats 134's number." Measured, printed,
and it is **much larger** than 134's — because 134 estimated on a *converging* OC
loop and the damage lives on the *diverging* MMA ones. **MET** (the bar is honesty,
not a threshold).

### B6 — detection is cheap

The detector is one O(N) scan of the live field against the stored previous mask.
Timed directly on the healthy fixture (2000 reps), against one solve:

```
detector 1.558e-05 s/iter, solve 3.349e-01 s/iter  ->  0.0047% of one solve
```

On the stagnation fixture, where the solve is far more expensive, it is cheaper
still: `3.22e-05 s` detector vs `2.428 s` solve = **0.0013%**
(`evidence/.../prod_stagnation.log`). Bar: under 1%. **MET, by ~200–800×.**
(Healthy: `evidence/.../prod_healthy60.log` / `prod_healthy250.log`.)

---

## 3. Why not the cheaper detector (the shell histogram)

A tempting cheaper detector reads only the first out-of-band shell (the ring whose
nodes the restricted solve already touched). It cannot work: on the stagnation
fixture only **58.7%** of full-domain escapes land in the first shell; **41.3%**
land further out (shells 2–5), where the restricted solve has `u = 0` and the shell
detector is blind (`evidence/.../feasibility_stagnation_unlatched.log`). The
whole-field O(N) scan sees all of them and costs 0.0047% of a solve, so there is no
reason to be clever.

---

## 4. Evidence

`docs/handoffs/evidence/2026-07-25-ad-escape-latch/`

| file | bar | what |
|---|---|---|
| `ctest_full.log` | all | raw full-suite ctest, post-change — 67/67 pass |
| `band0_production_diff.txt` | B1 | the additive-only production diff, early-return untouched |
| `B2_gate168_healthy.log` | B2 | 168 armed-gate reproduction, rung-0 bit-identity + the rung-1 catch |
| `prod_healthy250.log` | B2, B6 | healthy 250-step: zero latches; detector cost |
| `prod_healthy60.log` | B6 | detector cost on a healthy run |
| `prod_stagnation.log` | B3, B5, B6 | stagnation: latch iteration 3, 705 escapes, drho, distance |
| `feasibility_stagnation_unlatched.log` | flip | the LIVE path escapes (8114 > 6979) — why buildable, not Blocked |
| `feasibility_healthy_unlatched.log` | flip | the healthy contrast (0 escapes) |
| `prod_*_summary.csv`, `feasibility_*.csv` | — | machine-readable per-fixture summaries |

(B4 has no separate log — it is the `test_active_domain` assertion in
`ctest_full.log`, seam e3, printing "latch at 2; 14 post-latch iterations
bit-identical".)

### Recipe

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j10
ctest --test-dir build -R active_domain --output-on-failure

c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
  core/tests/harness/active_domain_escape.cpp build/libtopopt.a -o /tmp/ade
/tmp/ade gate168          # B2 — 168 armed reproduction + the rung-1 catch
/tmp/ade healthy 250      # B2/B6 — healthy, zero latches
/tmp/ade stag 0 40        # B3/B5 — stagnation, latch on first escape
```

---

## 5. Scope / what is NOT here

- **Production arming is unchanged** — still default OFF, no job.json key. Whether
  to arm the band is a separate maintainer decision; this task only made the
  feature safe to arm.
- **App / bridge untouched**, per scope. The one CSV schema is unchanged (the two
  new fields are `run_info.json` only).
- The escape latch does not try to *recover* the pre-detection damage (B5) — it
  stops the bleeding and charges what already leaked. Recovering it would mean
  re-running from before the first restricted step, which defeats the feature.
