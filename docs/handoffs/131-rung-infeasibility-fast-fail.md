# 131 — Rung-infeasibility fast-fail ("the load path is gone; stop")

**Track:** core only. **Territory:** `/core/` (`src/simp`, `src/settings`,
`src/cli`, headers, tests, one committed fixture). **NO app, NO bridge, NO
solver change.** Parallel-legal with the AMG Phase 0 harness task — they touch
disjoint files.

**Handoff number:** `docs/handoffs/` tops at **130**. This takes **131**.

**Gates (all green):** full `ctest` **61/61** (60 pre-existing + the new
`rung_infeasible`), 446 s. Raw output in
`docs/handoffs/evidence/131/ctest_raw.txt`. THE ONE RULE:
this is an honest termination of a provably broken rung, sanctioned by the
maintainer exactly as 128's flatness escape was; on any run where the signature
never occurs the design is **byte-for-byte identical**, proven by a test that
runs the same ladder armed and disarmed.

---

## 0. The evidence

96³ design-box run, 2026-07-22, worker job `e5ca9b258a9c4af7`. Its
`iterations.csv` is committed twice: as the test fixture
`core/tests/fixtures/infeasible/iterations_96_designbox.csv` and as evidence in
`docs/handoffs/evidence/131/` (with `run_info.json` and the worker-log excerpt).

| rung | vf | iters | compliance | CG iters | outcome |
|---|---|---|---|---|---|
| 0 | 0.68 | 146 | 10.64 → 1.672e-3 | 4551–11977 | accepted, margin 4580.9 |
| 1 | 0.52 | 45 | 1.370e-2 → 3.703e-3 | 5264–5821 | accepted, margin 1741.1 |
| 2 | 0.38 | **31** | 0.6568 → **1.674e5**, then FLAT | **~43.5k** | **accepted, margin 680.9, shipped as `variant_038.stl`** |
| 3 | 0.26 | **27** | starts at 1.674e5, stays | **~43.4k** | killed by the user (rc=-9) after 9 h |

Rung 2's first design step severed the structure. From iteration 2 the objective
read `167427.3…` and never moved again — the last digits wander in the fifth
decimal, a relative spread of **3.8e-7** across any five iterations — because a
severed structure's compliance is fixed by the frozen skin and nothing the
optimizer does to the design can change it. Each of those 31 iterations cost
~9 minutes. Then two further insults:

* the corpse was **certified**: a structure that carries nothing has no stress,
  so `compute_stress_margin` returned 680.9 — comfortably over `margin_stop`
  1.5 — and the rung was accepted and exported as a mesh;
* rung 3 **inherited it** (`warm_start_inherit` was on) and spent 27 more
  iterations at the identical dead objective.

~8.5 hours optimizing a load path that no longer existed, ending in a shipped
STL of a broken part.

### Correcting the prompt on one point

The task described the CG conjunct as *"CG hit its iteration cap (~43-44k, likely
unconverged)"*. It did not. `cg_max_iterations` is 0 everywhere in the driver, so
the cap is Eigen's default `2 * n_dof` — order 10⁶ on that grid — and a solve that
misses its tolerance **throws** (`fea_solve_cg_matfree`, and again in
`simp_optimize`), which would have ended the run loudly. The 43–44k counts are
genuine **converged** counts, ~9× the same run's healthy 4.6k: the near-singular
high-contrast operator a severed load path leaves is simply very expensive to
solve. The shipped conjunct is that observation stated in terms the run can
actually see (below). Nothing else in the prompt's diagnosis changed.

---

## 1. The signature

`bool rung_infeasible(compliance_history, cg_iteration_history, ratio, cg_blowup,
flat_tol, window)` — `core/include/topopt/simp.hpp`, implemented beside
`mma_objective_plateau` in `simp.cpp`. Pure, deterministic, a function only of
quantities every run already logs (`iterations.csv`'s `compliance` and
`cg_iters`). No wall clock, no randomness, no solver state.

It fires iff, across the trailing `window` iterations:

1. **Compliance blow-up** — `c[i] >= ratio * c[0]` at every one of them. The
   baseline is the rung's OWN starting compliance. Default **ratio = 100**.
2. **Solver distress** — `cg[i] >= cg_blowup * min(cg[0 .. n-window-1])` at every
   one of them; the baseline is the cheapest solve before the window (taking the
   minimum, not `cg[0]`, matters: rung 0's first solve cost 11977 against a
   steady-state 4551 because of a multigrid stagnation fallback, and keying off
   that one sample would hide a real blow-up). Default **cg_blowup = 4**.
3. **Frozen objective** — the window's relative spread `(max - min) / min <=
   flat_tol`. Default **flat_tol = 1e-3**.
4. **Sustained** — (1) and (2) at every iteration of the window, (3) over the
   window as a whole. Default **window = 5**, so the earliest possible verdict is
   iteration 6.

**N = 5 is the answer to "pick N small, state it, test it."** At the measured
~9 min/iter it costs ~45 minutes of confirmation against the 8.5 hours actually
burnt; it is short enough that the verdict lands at iteration 6 of 31 (and 25
iterations before the objective-plateau detector noticed at iteration 31 — a flat
corpse looks exactly like a converged design to that detector); and it is long
enough that no single bad MMA step can produce it.

### Conjunct (3) exists because a measurement demanded it

I built the two-conjunct predicate the prompt described, then probed it against a
live low-vf rung. A 24×5×6 cantilever whose ladder drops to vf 0.03 goes through a
**violent forming transient**: warm-started from the heavier rung, it runs to
**36,160× its own starting compliance with a 14.2× CG blow-up** for a dozen
iterations — satisfying (1) and (2) outright — and then **recovers** to below where
it started and produces a normal design. Conditions (1)+(2) alone would have
killed a rung that was still optimizing. That is the exact failure the prompt
forbids.

Magnitude does not separate the two cases. **Motion** does:

| | relative spread over a 5-iteration window |
|---|---|
| real corpse (96³ rung 2) | **3.8e-7** |
| live forming transient (24×5×6 @ vf 0.03) | **1.21** |

Six orders of magnitude. `flat_tol = 1e-3` sits ~3 orders above the corpse and
~3 below the transient. It is also the physically right test: a field the
objective does not respond to produces no sensitivity to recover along, so
"frozen and high" is terminal in a way that "high" alone is not. Both cases are
regression tests (§4, groups 1 and 4) — the transient one runs **live**, so it
re-derives its own counter-example every time the suite runs.

---

## 2. What the optimizer does

`SimpOptions` gains `infeasible_compliance_ratio` / `infeasible_cg_blowup` /
`infeasible_flat_tol` / `infeasible_window`, wired into **both** `simp_optimize`
overloads (a lost load path is not an MMA phenomenon). Each loop keeps a
`cg_history` index-aligned with `result.history`, evaluates the predicate once per
completed iteration, and on a verdict sets `SimpOptimizeResult::infeasible` +
`infeasible_iteration` and breaks out of the stage and continuation loops.

**Armed by default, and byte-identity-safe by construction:** the detector is a
pure read of the history that can only STOP the loop — it never touches `x`, the
filter, the solver or the update. `infeasible_window <= 0` disarms it to the exact
pre-131 predicate, which is how the byte-identity test pins it.

An infeasible run also **skips the final recovery solve**. Two reasons, both
load-bearing: it is the run's most expensive single solve (tight tolerance against
the near-singular operator — the 43–44k case), and it is precisely the solve that
could miss its tolerance and *throw*, replacing an honest verdict with an
exception. `compliance` is then the last recorded objective (the corpse's plateau
value); `converged` is false and `infeasible` is true, so nothing can read it as
an achievement.

New `SimpIterationObservation::infeasible` carries the verdict per iteration.

---

## 3. What the driver does

`minimize_plastic` gains a branch right after the cancel branch. Three
consequences, each a fix for something the 96³ run actually did:

1. **No analysis.** Stress solve, V3 suite and settings engine are skipped,
   exactly as for a cancelled rung — so no margin 680.9, no mesh, nothing to
   certify. The rung is never accepted.
2. **No inheritance.** `warm_seed` is left untouched, so it still holds the last
   **feasible** rung's converged density (or is empty when there has been none, or
   inheritance is off). **State of the rule:** *a rung's warm start comes from the
   most recent rung that was neither cancelled nor infeasible; an infeasible rung
   never updates the seed.* This is not hygiene — it is what keeps the detector
   able to see the next rung at all: a rung seeded from a corpse starts at the dead
   objective, so nothing is ever 100× above its own start and it is **undetectable**
   (measured: the real rung 3, §4 group 1).
3. **No stop.** The ladder continues. Infeasibility is a failure of *this* carve,
   not the strength verdict `stopped_on_margin` is, so the next rung gets a fresh
   attempt from the last feasible field. With fast-fail the worst case is
   `window + 1 = 6` iterations per remaining rung instead of a full rung each. The
   `MinimizePlasticResult::evaluated` contract is updated accordingly: accepted
   rungs, optionally interleaved with infeasible ones, then at most one rejected
   terminal rung.

**Reported, never dropped.** `VariantReport` gains `rejection_reason`, `""` on
accepted rungs and on ordinary too-weak rejections, and
`"rung infeasible (load path lost)"` (`kRungInfeasibleReason`, one definition in
`pipeline.hpp`) here. The line goes into `report.rejected` →
`report.json` `rejected_variants`. It carries the geometry it honestly has
(achieved/printed fraction — a voxel count, not an analysis) and **zero
placeholders** for everything the skipped analysis would have filled; the header
says so in as many words, and the JSON validator enforces that a non-empty
`rejection_reason` can only appear on a line declaring `accepted=false`.

Surfaces:

* `iterations.csv` gains a 12th column **`infeasible`** (0/1), which can read 1 on
  at most one row per rung — that rung's last.
* `run_info.json` gains the three thresholds + `infeasible_window` (config,
  written up front) and **`rung_infeasible`** (outcome, one entry per evaluated
  rung, written only at the post-run finalize like `cg_multigrid`, so an
  unfinished run claims nothing). All-false is the positive statement "no rung
  lost its load path."
* `topopt-cli` prints a **stderr WARNING** per infeasible rung with the thresholds
  and the firing iteration, and its per-variant console line prints the reason
  instead of a margin it does not have.

---

## 4. Evidence

`core/tests/validation/test_rung_infeasible.cpp` (ctest name `rung_infeasible`),
55 checks, ~45 s standalone (~60 s under the parallel suite). It consumes the
committed real CSV by absolute path.

**Group 1 — the real 96³ trajectory at PRODUCTION thresholds.** Replays each
recorded rung prefix-by-prefix, exactly as the live loop consumes it.

```
[real] rung 0: 146 iters, c 10.6361 -> 0.00167184, cg 4551..11977 — fire=-1
[real] rung 1: 45 iters,  c 0.013704 -> 0.00370307, cg 5264..5821  — fire=-1
[real] rung 2 (severed): c[0]=0.656802 -> 167427 (2.549e+05x), cg 8371 -> 43532 — fire=6 of 31 iterations run
[real] rung 3 (corpse-seeded): starts at 167427 — undetectable, 27 iterations wasted
```

Also asserted on that same trace: each conjunct is load-bearing — make any one
threshold unreachable and the verdict disappears.

**Group 2 — pure-predicate guards.** Empty history; fewer than `window+1` samples;
exactly `window+1` (the earliest verdict); mismatched history lengths; one
recovering iteration inside the window clearing it; a monotone descent; an
ordinary converged plateau *below* the start; a non-finite objective.

**Group 3 — the live false-positive guard + THE ONE RULE.** Ladder {0.6, 0.03} on
the bar, run twice — armed at production defaults and disarmed.

```
[transient] rung 1 peaked at 3.616e+04x its start compliance with a 14.2x CG blow-up — and was NOT killed
[one rule] 2 rungs, armed == disarmed bit-for-bit: yes
```

The byte-identity check compares, per rung, iteration count, `compliance`, and the
full `physical_density` vector with `==`. The test also asserts the transient
really does exceed both magnitude conjuncts, so it cannot pass by being tame.

**Group 4 — the driver + the inheritance rule.** Ladder {0.6, 0.001, 0.0005}.

```
[driver] rung 1: infeasible at iteration 6, reason "rung infeasible (load path lost)"
[inheritance] rung-after-corpse == rung-after-last-feasible: yes
```

The inheritance proof is by construction rather than by inspection: run the same
ladder with the infeasible rung **removed** — {0.6, 0.0005}, where the 0.0005 rung
is provably seeded by rung 0 — and require the two results to agree **bit-for-bit**
(iterations, density, compliance). The optimizer is deterministic, so they can only
agree if the seed skipped the corpse. Also checked: the ladder continued (3 rungs
evaluated), the rung is not accepted, not analysed (`von_mises_field`,
`displacement_field`, mesh all empty), reports no fabricated margin, carries the
reason, appears in `rejected_variants`, and the assembled report still validates
with the reason present in the JSON.

**Scaled thresholds in group 4, stated plainly.** That fixture's collapse is
*uniform* (every design voxel at `density_min`), and a uniformly scaled operator
is no worse conditioned than a solid one, so CG does **not** blow up there the way
it does on the production grid's mixed frozen/collapsed field. Group 4 therefore
runs with `ratio = 2.0` and `cg_blowup = 0.5` (`flat_tol` and `window` unrelaxed)
and its job is the **driver wiring**, not the calibration — the production
calibration is proven on the real trajectory in group 1. The compliance conjunct
is still discriminating at that scale (the healthy heavy rung never approaches 2×
its start), so the scenario cannot pass by firing on everything.

---

## 5. Known limitation, measured and asserted — the BORN-DEAD rung

The predicate is relative to the rung's own starting compliance, so it **cannot
see a rung that is already dead at iteration 1**: nothing is ever 100× above a
value that is itself the dead one. Group 4 asserts this rather than leaving it to
be discovered:

```
[blind spot] rung starts: 7.02e+04, 4.795e+12, 1.464e+13 — rung 2 begins at the dead level
```

Two ways a rung is born dead:

* **inheriting a corpse** — which §3(2) is exactly what removes, and it is the
  reason that rule matters;
* **a target that collapses to the density floor.** This is what the 96³ run's
  rung 2 was: its `achieved_vf` reads `0.001000` — `density_min` — from iteration 1,
  because the part-relative design-box target `vf * part_solid -
  frozen_effective` went non-positive against the frozen part + face protections
  and clamped to the floor. **The honest fix is upstream**: refuse (or report) a
  rung whose effective target clamps to `density_min`, at the point that target is
  computed in `minimize_plastic`. That is a separate, small change and is
  deliberately **not** claimed here — this handoff stops the hours being burnt and
  the corpse being certified; it does not stop the rung being asked for.

One thing I could not reconstruct from the artifacts: rung 2's iteration 1 read
0.6568 while iteration 2 read 1.674e5, even though `achieved_vf` was already at
the floor at iteration 1. Both are recorded facts; the mechanism connecting them
is not in the surviving data, and I did not re-run a 9-hour job to find out. It
does not affect the detector, which keys on the recorded trajectory either way.

---

## 6. Files

| file | change |
|---|---|
| `core/include/topopt/simp.hpp` | `rung_infeasible` decl + rationale; 4 `SimpOptions` thresholds; `SimpOptimizeResult::infeasible`/`infeasible_iteration`; `SimpIterationObservation::infeasible` |
| `core/src/simp/simp.cpp` | the predicate; `observe_infeasible`; `cg_history` + verdict + break in both overloads; skip the final solve when infeasible |
| `core/include/topopt/pipeline.hpp` | `kRungInfeasibleReason`; `MinimizePlasticVariant::infeasible`; `MinimizePlasticResult::rung_infeasible`; updated `evaluated` contract |
| `core/src/simp/minimize_plastic.cpp` | the infeasible branch (no analysis / no inheritance / no stop); per-rung echo; skip conditional projection on a corpse |
| `core/include/topopt/report.hpp`, `core/src/settings/report.cpp` | `VariantReport::rejection_reason` + emit + validate |
| `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` | CSV `infeasible` column; `RunInfo` thresholds + `rung_infeasible` |
| `core/src/cli/run_job.cpp`, `core/src/cli/main.cpp` | run_info config echo + post-run finalize; stderr WARNING; honest console line |
| `core/tests/validation/test_rung_infeasible.cpp` | new, 55 checks |
| `core/tests/fixtures/infeasible/iterations_96_designbox.csv` | the real run, committed |
| `core/tests/unit/test_observability.cpp`, `core/tests/validation/test_observability_capture.cpp` | golden CSV schema updated for the 12th column |
| `core/CMakeLists.txt` | register `rung_infeasible` |
| `docs/handoffs/evidence/131/` | CSV + run_info + worker-log excerpt |

**Not touched:** the app, the bridge, any solver, any updater, any gate.

**Boundary check (done, not assumed).** `fields.bin` (`io/fields.cpp`) and the CLI
mesh export both filter to `accepted` variants, and an infeasible rung is never
accepted, so neither can misindex. The bridge's `to_optimize_result` pushes every
`evaluated` entry through, which means an infeasible rung reaches the app in
**exactly the shape a cancelled or gate-rejected rung already does today** — empty
mesh, empty fields, `accepted == false` — so it needs no bridge change to be safe.
Surfacing the *reason* in the app UI (so a user sees "load path lost" rather than
an unexplained missing variant) is a deliberate **follow-up**, out of this
core-only track.

---

## Gates

```
100% tests passed out of 61
Total Test time (real) = 446.06 sec
```

Raw output: `docs/handoffs/evidence/131/ctest_raw.txt`. Every pre-existing test
passes unchanged; the two golden CSV-schema tests (`observability`,
`observability_capture`) were updated in the same commit for the new 12th column,
as 128 did for its two.
