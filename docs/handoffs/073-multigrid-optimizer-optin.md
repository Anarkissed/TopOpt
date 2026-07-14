# 073 — Wire the geometric-multigrid solver into the optimizer (OPT-IN)

**Track:** core (`/core/` only — no `/app/`, no `tests/fixtures/**`, no
`materials.json`, no `ARCHITECTURE.md`, no `ROADMAP.md`).
**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/multigrid-solver-opt-in-e1bba5`
**Branch:** `claude/multigrid-solver-opt-in-e1bba5`
**ROADMAP box:** NOT checked (reporting here per instructions).

## What this is

Handoff 072 landed `fea_solve_mgcg` (geometric-multigrid-preconditioned CG) and
proved it byte-agrees with `fea_solve_cg` at the single-solve level — but nothing
called it. This task is the "put the engine in the car" step: the optimizer can
now USE the multigrid solver, as an **opt-in accelerator that defaults OFF**.

**THE ONE RULE held:** the default optimizer behaviour is byte-identical to
before. Gate-V2 and every existing optimizer test produce the exact same result.
The multigrid solver is only reached when a caller explicitly turns it on.

## Where the flag was added and how a caller sets it

A plain enum selects the FEA linear solver, threaded through the options structs
the optimizer already takes. **Default is `JacobiCG` everywhere** — the current
path.

1. **`core/include/topopt/simp.hpp`**
   - New enum: `enum class SolverKind { JacobiCG, MultigridCG };` (documented
     as an opt-in accelerator switch).
   - `simp_compliance(...)` gained a trailing optional parameter
     `SolverKind solver_kind = SolverKind::JacobiCG` (after the existing
     `PenalizedSolver* solver = nullptr`).
   - `SimpOptions` gained a field `SolverKind solver = SolverKind::JacobiCG;`
     (drives `simp_optimize` and, via `MinimizePlasticOptions::simp`,
     `minimize_plastic`).

2. **`core/src/simp/simp.cpp`**
   - `simp_compliance`: when `solver_kind == MultigridCG` the penalized solve
     calls `fea_solve_mgcg` instead of `fea_solve_cg` — same arguments, same
     `CgInfo`. The multigrid path is stateless, so the cached `PenalizedSolver`
     fast path and CG warm start are bypassed (documented). All other branches
     unchanged.
   - Both `simp_optimize` overloads (unconstrained + passive-region masked) pass
     `options.solver` into their per-iteration and final `simp_compliance` calls
     (four call sites total).

3. **`core/src/simp/minimize_plastic.cpp`**
   - The final recovery `simp_compliance` solve passes `opt.solver` (which flows
     from `MinimizePlasticOptions::simp.solver`), so the whole ladder + recovery
     uses the selected solver.

**How a caller opts in** (example):

```cpp
topopt::SimpOptions opt;
opt.solver = topopt::SolverKind::MultigridCG;   // default is JacobiCG
auto result = topopt::simp_optimize(grid, params, bcs, loads, opt);

// or a single analysis solve:
auto sc = topopt::simp_compliance(grid, params, density, bcs, loads,
                                  1e-8, 0, /*initial_guess=*/nullptr,
                                  /*solver=*/nullptr,
                                  topopt::SolverKind::MultigridCG);

// or the plastic driver:
topopt::MinimizePlasticOptions mpo;
mpo.simp.solver = topopt::SolverKind::MultigridCG;
```

## How the multigrid path is surfaced per solve

`fea_solve_mgcg` already writes `CgInfo::used_multigrid` (true if the V-cycle
ran, false if it fell back to the exact Jacobi-CG) and `CgInfo::mg_levels`. That
`CgInfo` is returned on `SimpCompliance::cg`, so it flows through the existing
solve diagnostics — no new logging channel was added. A caller (e.g. the
`minimize_plastic` recovery solve, which keeps `sc.cg`) can read
`cg.used_multigrid` to see which path actually ran.

## Correctness guards (the proof the answers don't change)

New test section **13** in `core/tests/unit/test_simp.cpp` (`simp` ctest target),
on the same tiny 8×4×4 cantilever the existing simp tests use:

- **(a) Same result through the FULL optimize loop.** Runs the identical
  optimization twice — once `SolverKind::JacobiCG`, once `SolverKind::MultigridCG`
  (`change_tol = 0` so both run the full 15-iteration cap deterministically) —
  and asserts:
  - `iterations` identical and `converged` identical (same accepted/rejected
    outcome by construction),
  - final design `max|Δρ| ≤ 1e-6`,
  - final compliance agrees to `1e-6` relative.
  This is the optimizer-level "same result, faster engine" proof (072 proved it
  at the single solve; this survives iteration after iteration through the OC
  updates).
- **(b) The DEFAULT path is genuinely Jacobi-CG.** A default `simp_compliance`
  (no `solver_kind` arg) asserts `cg.used_multigrid == false` and
  `cg.mg_levels == 0`; an explicit `JacobiCG` does the same.
- **Bonus — multigrid genuinely engages (not a silent fallback).** A
  `MultigridCG` `simp_compliance` on the 2×-divisible 8×4×4 grid asserts
  `cg.used_multigrid == true` and `cg.mg_levels ≥ 2`, and that its single-solve
  field/compliance match the Jacobi solve. So the test exercises the real
  V-cycle, not just the fallback.

`test_simp` reports **170/170 checks passed** (was 159; +11 new).

## Verification (raw ctest output)

Configured locally without `-DTOPOPT_REQUIRE_DEPS=ON` (this machine lacks
`lib3mf`; every Eigen-gated optimizer/FEA target still builds and runs — the
3MF round-trip is the only skipped target and is untouched by this change):

```
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j8
ctest --test-dir build --output-on-failure --no-tests=error
```

Full suite — **100% tests passed, 0 failed out of 33** (total 581.85 s). The
correctness-relevant lines:

```
12/33 Test #12: fea_cg ...........................   Passed   22.18 sec
13/33 Test #13: fea_mgcg .........................   Passed   10.31 sec
17/33 Test #17: simp .............................   Passed    0.70 sec   <- new opt-in test
19/33 Test #19: mbb_validation ...................   Passed    4.24 sec
20/33 Test #20: gate_v2 ..........................   Passed   51.96 sec   <- GATE-V2 GREEN, unchanged
22/33 Test #22: variants .........................   Passed    4.63 sec
23/33 Test #23: passive_regions ..................   Passed    6.25 sec
24/33 Test #24: minimize_plastic .................   Passed   17.26 sec
27/33 Test #27: mma ..............................   Passed   41.19 sec
28/33 Test #28: mma_projection_gate ..............   Passed    1.31 sec
29/33 Test #29: stress ...........................   Passed   19.20 sec

100% tests passed, 0 tests failed out of 33

Total Test time (real) = 581.85 sec
```

Standalone `simp` target:

```
simp: all 170 checks passed
```

## The default is unchanged

**Explicit statement:** the default optimizer behaviour is byte-identical to
before this task. `SimpOptions::solver`, `simp_compliance`'s `solver_kind`
parameter, and `MinimizePlasticOptions::simp.solver` all default to
`SolverKind::JacobiCG`, which routes to the exact same `fea_solve_cg` /
`PenalizedSolver` code paths as before (the new `MultigridCG` branch is only
entered when a caller sets the flag). Gate-V2 (test #20) and the full optimizer
suite pass unchanged, as expected. No default was flipped; no shipping config
(Gate-V2, `minimize_plastic` production, the app bridge) was pointed at
multigrid. This task only makes multigrid **available** to turn on.

## Honest scope notes / what was NOT done

- The **stress path** (`simp_optimize_stress` / `simp_stress_aggregate`, the
  primal+adjoint `fea_solve_cg` calls in `simp.cpp`) was left on Jacobi-CG. The
  task named `simp_compliance` / `minimize_plastic`; the stress path is a
  separate MMA-only entry point and threading the flag through its two solve
  sites is a clean follow-up if wanted.
- When `MultigridCG` is selected inside `simp_optimize`, the `PenalizedSolver` is
  still constructed (one assembly) but then bypassed — a small, harmless waste on
  the opt-in path; not optimized here (scope = availability, not tuning the MG
  path). The transfer-operator caching optimization suggested in handoff 072 is
  also still future work.
- Flipping the default to `MultigridCG` for real users is deliberately a **later
  task**, once this proves out.

## App visibility

This changes `/core/`, so it is **invisible to the app** until
`./app/scripts/build_core.sh` rebuilds the xcframework. No app code was touched
and the app's behaviour is unchanged regardless (the default is JacobiCG); a
rebuild would only make the new `SolverKind` symbol available to app-side
callers.
