# A non-converging solve rejects the RUNG, not the run

**Track:** core only. **Territory:** `/core/` (`src/fea`, `src/simp`, `src/cli`,
headers, one new validation test). **NO app, NO bridge.** Follows handoff 131's
rung-rejection pattern exactly — a rejected rung is reported, its accepted
predecessors survive, the ladder continues.

**Handoff number:** `docs/handoffs/` is on the date scheme; this is
`2026-07-27-nonconvergence-rejection.md`.

**THE ONE RULE:** on any run where no linear solve fails to converge, the design is
**byte-for-byte identical** — the whole change is confined to the throwing path, and
that path is unreachable when every solve converges. The pre-existing suite
(`production_parity`, `rung_infeasible`, `minimize_plastic`, `analyze_fixed_design`,
`simp`, `warm_start*`, all four `fea_*` solver tests) passes **unchanged**, which is
the byte-identity proof at large.

---

## 0. The problem

`fea_solve_cg` (and every sibling: `fea_solve_mgcg`, `fea_solve_cg_matfree`,
`fea_solve_mgcg_matfree`) **threw** `std::runtime_error` when CG reached its
iteration cap without meeting the requested relative-residual tolerance. That throw
propagated up through `simp_optimize` and `analyze_fixed_design` and out of
`minimize_plastic`, destroying the **entire** run — including rungs that had already
passed the gate and produced variants the maintainer could have printed.

This is not hypothetical on this project:

* **PR 209** measured an active-domain posture (AD-on at the L grid) that **does not
  converge at all** — the trajectory solve fails.
* **PR 200** found a real variant that **fails to converge during re-certification** —
  the certification solve fails, on a design whose trajectory converged fine (the
  certification solve is stateless/cold, so it is strictly harder than the
  warm-started trajectory solves that produced the design).

Both failure modes now reject the offending **rung** and let the run finish.

---

## 1. The mechanism: a typed exception, caught at two honest places

### 1.1 `SolverNonConvergence` (`core/include/topopt/fea.hpp`)

A new `struct SolverNonConvergence : public std::runtime_error` carrying `int
iterations` and `double residual`. Every CG solver throws it — with the **identical
`what()` message string** it threw before — on the ONE failure that is a property of
the *linear solve* rather than of a malformed problem: the iteration cap reached
short of tolerance. A malformed system (bad BC/load index, void-only DOF set,
preconditioner-setup/factorization failure) still throws `std::invalid_argument` /
plain `std::runtime_error` and is **not** caught anywhere below — those are bugs in
the request and must still abort loudly. This is the whole discrimination: catch
non-convergence *precisely*, never swallow a genuine error.

Because it IS-A `std::runtime_error`, every existing `catch (const
std::runtime_error&)` / `catch (const std::exception&)` keeps behaving exactly as
before — in particular the active-domain restricted-solve fallback
(`active_domain_solve`, simp.cpp) still catches a restricted-solve non-convergence
and retries the FULL domain, and its `latch_reason` string (built from `what()`) is
byte-identical. Only when the **full-domain** solve itself fails to converge does the
exception reach the new handling.

### 1.2 Trajectory + final-certification (`simp_optimize`, `core/src/simp/simp.cpp`)

`SimpOptimizeResult` gains `non_convergent` / `non_convergent_iteration` /
`non_convergent_residual`, mirroring `infeasible`. In **both** overloads
(unconstrained and masked/passive), non-convergence is converted to a RETURN, never
propagated:

* The **trajectory** solve (`active_domain_solve`) is wrapped: a
  `SolverNonConvergence` sets the flag + numbers and `break`s the loops, exactly as
  the infeasibility fast-fail ends a corpse. The `!c.cg.converged` return-path (some
  matrix-free solvers report rather than throw) is handled identically.
* The **B2 final certification solve** is wrapped too. It STILL runs at the tight
  `options.cg_tolerance` — the existing asserts that the trajectory schedule's floor
  equals the certification tolerance are untouched — but if IT fails to converge the
  result is marked `non_convergent` instead of throwing. A non_convergent run
  **skips** that final solve entirely when the trajectory already failed, for the
  same two reasons handoff 131 skips it on an infeasible run (it is the most
  expensive single solve, and the one that would replace an honest verdict with an
  exception).

`simp_optimize_stress` (M7.mma.2) is **not** on the `minimize_plastic` path and is
left untouched; its inner solves now throw `SolverNonConvergence`, which propagates
as the `std::runtime_error` subclass it always did (byte-identical behaviour).

### 1.3 Certification (`analyze_fixed_design`, `core/src/simp/analyze.cpp`)

`FixedDesignAnalysis` gains the same three fields. The certification
`simp_compliance` call is wrapped: on `SolverNonConvergence` it returns early with
`non_convergent` set and — the load-bearing invariant, **asserted not commented** —
`accepted` left FALSE:

```cpp
assert(out.accepted == false &&
       "non-convergence rejection: a failed certification solve must never "
       "certify a design");
```

The tolerance is never softened or retried; the flag only records that the tight
solve missed. This is BAR N2 made structural: a design whose certification solve the
CG cannot resolve is **rejected, never certified**.

### 1.4 The driver (`minimize_plastic`, `core/src/simp/minimize_plastic.cpp`)

Two rejection branches, both mirroring 131's infeasible branch:

* **Trajectory** (`variant.optimization.non_convergent`), placed right after the
  infeasible branch — BEFORE the warm-seed update. No analysis, no inheritance
  (§2/N3), no stop; a rejected report line with `rejection_reason =
  kRungNonConvergentReason` and only the geometry it honestly has (a printed-voxel
  count), zero placeholders for the analysis it never ran.
* **Certification** (`fda.non_convergent`), placed right after the
  `analyze_fixed_design` call and BEFORE any of `fda`'s fields are read as
  measurements. Same rejected line.

Both `continue` (ladder continues). The escalation and conditional-projection blocks
are guarded with `&& !non_convergent` exactly as they already guard `!infeasible`.

`kRungNonConvergentReason = "linear solve did not converge"` is one definition in
`pipeline.hpp`, shared by the driver, the CLI console line, the CLI warning and the
test — the string in `report.json` can never drift from what anything checks for. It
is the **fourth** exhaustive `rejection_reason`, and deliberately worded as a SOLVER
failure so a reader does not mistake the absent margin for a measured one (BAR N5).

---

## 2. Warm-start inheritance across a rejected rung (BAR N3, handoff 131's rule)

Handoff 131's rule: *a rung's warm start comes from the most recent rung that
produced a converged, connected design; a rung that did not must not seed the next.*
It still holds, and the two non-convergence sub-cases differ **because the facts
differ** — this is principled, not an inconsistency:

* **Trajectory non-convergent** — there is no trustworthy field at all (the solver
  could not resolve the displacement). The branch sits BEFORE the seed update, so
  `warm_seed` is left holding the last FEASIBLE rung's density. The next rung
  inherits what it would have inherited had the failing rung never run — **proven
  bit-for-bit** in the test (group 3): ladder `{0.6, 0.02, 0.015}` vs `{0.6, 0.015}`
  produces an identical last rung (same verdict, iteration, residual, and
  `physical_density`), because the intervening non-convergent rung changed nothing
  about the seed. This is the PR-209 case, and it is 131's rule verbatim.

* **Certification non-convergent** — the trajectory CONVERGED to a connected design;
  only the separate cold certification solve failed. `warm_seed` was already updated
  (a few lines up, gated on `load_path_ok`) with that converged, connected density,
  and is LEFT there — exactly as a too-weak-but-connected rung seeds the next one.
  The certification failing does not make the trajectory design a corpse: it
  converged, it is connected, it is the right seed. This is the PR-200 case.

No solver state that a later rung depends on is lost in either case: the only
cross-rung state is `warm_seed` (handled above), and each rung's `PenalizedSolver` /
CG warm vector is per-`simp_optimize`-call and never shared. **BLOCKED-STOP does not
apply** — the throw converts cleanly.

---

## 3. Surfaces

* `run_info.json` gains `rung_non_convergent` (bool per evaluated rung),
  `rung_non_convergent_iteration` (int) and `rung_non_convergent_residual` (double) —
  finalize-only, like `rung_infeasible`, so an unfinished run asserts nothing.
  All-false/zeros is the positive statement "every rung's solves converged." This is
  BAR "run_info records which rungs were rejected for non-convergence, with the
  iteration and the residual reached." A real sample is in the evidence dir:
  `"rung_non_convergent": [false, true]`, `"..._iteration": [0, 800]`,
  `"..._residual": [0, 0.001063071998]`.
* `topopt-cli` prints a **stderr WARNING** per non-convergent rung (the CG tolerance,
  the residual it stalled at, the iteration it reached, and that the run completed
  and accepted variants are unaffected), and a distinct per-variant console line
  (`"<vf>: linear solve did not converge — not certified"`), separate from the
  infeasible and margin lines.
* **No `iterations.csv` column** was added: non-convergence is a solve-level event
  that ends a solve, not a per-iteration verdict like `infeasible`. The golden CSV
  schema tests (`observability`, `observability_capture`) are therefore unchanged and
  pass as-is.

**CLI reachability, stated plainly:** `cg_max_iterations` is a solver-internal, NOT a
`job.json` key (only `simp_max_iterations` — the design iteration count — is). So
from a plain `topopt-cli run` today the CG cap is Eigen's default (~2·nDOF), and this
path is triggered only by a posture that genuinely does not converge within that
default (PR 209) or by a front-end that sets a small cap. The CLI surfacing is
written and live for the moment either arises — exactly as handoff 131 wrote the
active-domain latch warning that a plain run cannot yet trigger.

---

## 4. Evidence (`evidence/2026-07-27-nonconvergence-rejection/`)

* `test_output.txt` — the new suite: **47 checks, 0 failures**.
* `driver_mixed_outcome.txt` (+ `driver_mixed_outcome.cpp`) — the driver on
  `{0.6, 0.02}` at cap 800: rung 0 **accepted, 1584-triangle mesh**; rung 1
  **non_convergent, reason "linear solve did not converge", 0 triangles**; run
  completes (`evaluated=2, cancelled=0`); `rung_non_convergent=[0 1]`,
  `nc_iter=[0 800]`, `nc_resid=[0 0.00106307]`.
* `measure_cg_counts.cpp` — the calibration: a cold dense-field solve needs **295**
  CG iterations, a near-void field **2623**; cap **800** sits robustly between (the
  separation is conditioning, not timing, so it is platform-stable).
* `run_info_sample.json` (+ `emit_run_info.cpp`) — a real serialized `run_info`
  fragment with the three new keys.
* `ctest_full.txt` — the full suite, all tests passing (byte-identity at large).

### The test (`core/tests/validation/test_nonconvergence_rejection.cpp`, ctest
`nonconvergence_rejection`), 47 checks, ~9 s, on handoff 131's cantilever fixture:

* **Group 1 — the mechanism fires at each layer.** A starved CG solve throws
  `SolverNonConvergence` carrying a positive iteration count and an above-tolerance
  residual (and is still catchable as `std::runtime_error`); `simp_optimize` at cap 1
  RETURNS `non_convergent` without throwing; and **N2** — `analyze_fixed_design` on
  ONE fixed density rejects it at a starved cap (`non_convergent`, `accepted==false`)
  and CERTIFIES the identical field at the identical tolerance under a generous cap
  (`accepted==true`): the tolerance never changed, only convergence did.
* **Group 2 — N4 + N5.** The driver run COMPLETES; rung 0 is accepted and its mesh is
  **written to an STL on disk and read back** with the same triangle count; rung 1 is
  non_convergent, not accepted, not infeasible, unmeshed, in `report.rejected`; the
  per-rung run_info numbers are present; the reason differs from all three other
  reasons and the assembled report **validates**.
* **Group 3 — N3.** The bit-for-bit inheritance proof above.
* **Group 4 — N1.** A generous-cap run is inert: no rung non_convergent, the surface
  is all-false, accepted meshed variants as normal.

---

## 5. Files

| file | change |
|---|---|
| `core/include/topopt/fea.hpp` | `SolverNonConvergence` type |
| `core/src/fea/assembly.cpp`, `multigrid.cpp`, `matfree.cpp` | throw it (identical `what()`) at the 5 non-convergence sites |
| `core/include/topopt/simp.hpp` | `SimpOptimizeResult` non_convergent/iteration/residual; updated `simp_optimize` throw doc |
| `core/src/simp/simp.cpp` | both overloads: catch trajectory + B2 non-convergence → flag; skip final solve; outer break |
| `core/include/topopt/analyze.hpp`, `core/src/simp/analyze.cpp` | `FixedDesignAnalysis` fields; catch cert solve → flag, asserted `accepted==false` |
| `core/include/topopt/pipeline.hpp` | `kRungNonConvergentReason`; `MinimizePlasticVariant::non_convergent`; `MinimizePlasticResult::rung_non_convergent*`; updated contracts |
| `core/src/simp/minimize_plastic.cpp` | two rejection branches; `record_rung_convergence` helper; escalation/projection guards |
| `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` | `RunInfo` three vectors + JSON |
| `core/src/cli/run_job.cpp` | finalize the vectors + LOUD WARNING per rung |
| `core/src/cli/main.cpp` | distinct console line |
| `core/tests/validation/test_nonconvergence_rejection.cpp`, `core/CMakeLists.txt` | new test, registered |

**Not touched:** the app, the bridge, `simp_optimize_stress`, any updater, any gate,
the `iterations.csv` schema.

---

## 6. Boundary, stated (not hidden)

* Only genuine **non-convergence** (iteration cap reached short of tolerance) is
  converted. A **preconditioner-setup / factorization failure** ("preconditioner
  setup failed on K_ff") is a distinct, near-singular-*setup* failure and still
  aborts — converting it would risk masking a malformed-system bug, and it is not the
  failure PR 209/200 describe. If a real run ever hits it, that is a separate, small
  follow-up with the same shape.
* The two sub-cases (trajectory vs certification) seed differently by design (§2). If
  a future policy wants the certification case to ALSO not seed, the single change is
  to move the `warm_seed` update below the certification branch — deliberately not
  done here, because a converged connected design is the right seed.
