# Handoff 071 — Solver performance: profile + targeted fix (64³ minimize_plastic)

## Task
TRACK core (`/core/` only). A 64³ `minimize_plastic` run took **over an hour** to
reach ~18% progress — pathologically slow for ~260k voxels. Phase 1: PROFILE
(measure, don't guess) where each optimization iteration spends time. Phase 2:
apply the targeted fix(es) Phase 1 shows matter most (candidate levers: linear
solver / preconditioner, CG warm-starting, avoiding full reassembly). Hard
CORRECTNESS GUARD: the optimized result must be unchanged within tolerance
(speed fix, not a physics change); Gate-V2 and the suite must still pass. Do not
touch `tests/fixtures/**`, `materials.json`, `ROADMAP.md`. Do NOT check the
ROADMAP box.

## Worktree
`/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/hungry-jennings-3504eb`
Branch `claude/solver-perf-profile-b4a339`. macOS, AppleClang, C++17, Eigen via
`/opt/homebrew`. Release build (`-DCMAKE_BUILD_TYPE=Release`,
`-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake`). Full local `ctest`: **32/32
passed** (this checkout builds OCCT + lib3mf too, so all 32 run locally).

## Hot path (before the fix)
`minimize_plastic` → per ladder rung `simp_optimize` (masked/MMA) → per iteration
`simp_compliance` → **`fea_solve_cg` (graded)**. Every iteration that call
`assemble_reduced` **rebuilt the entire global stiffness from ~151M triplets**
(262k solid voxels × 24×24), `setFromTriplets` (a sort), then **re-formed the
BC-reduced operator with sparse selection-matrix products** `P·K·Pᵀ`, and finally
ran a **cold-start Jacobi-preconditioned CG**. The grid / BCs / loads are FIXED
across a whole run — only the per-voxel modulus E(ρ) changes — so all of that
reassembly was redundant work repeated every iteration.

## Phase 1 — PROFILE (measured, env-gated timers, since removed)
Instrumented `assemble_reduced` / `solve_reduced_cg` with per-phase wall clock
and ran a representative 64³ solid cantilever (clamped i==0, self-weight −z,
vf 0.5), the same shape/loading the driver uses.

**64³ (823,875 DOFs), baseline (original code):**

| phase        | per iteration | share |
|--------------|--------------:|------:|
| CG solve     |        ~26 s  | 54.9% |
| assembly     |        ~14 s  | 30.1% |
| BC reduce (P·K·Pᵀ) | ~7 s   | 14.8% |
| precond setup|       ~0.1 s  |  0.2% |
| **total FEA**|   **~47–52 s/iter** | 100% |

- CG averaged **~552 iterations per solve** (Jacobi preconditioner, cold start).
- 32³ split for reference: CG 76%, assembly 14%, reduce 16% (~273 CG iters).

**Reading:** CG dominates (55%), but **assembly + reduce is a further 45%** and is
pure per-iteration redundancy (fixed sparsity pattern). The 40-iter × 3-rung
ladder at ~47 s/iter ≈ the reported ">1 hour". Single biggest sinks: (1) the CG
solve, (2) the redundant reassembly.

## Phase 2 — TARGETED FIX

### Levers evaluated
1. **CG warm-start** (previous iteration's `u` as the CG initial guess).
   Implemented and measured: only **~5–10%** here. The problem is ill-conditioned
   by the SIMP soft-void modulus contrast (ρ_minᵖ), and Eigen's CG tolerance is
   relative to `‖b‖`, so a good starting iterate doesn't shortcut the
   slowly-converging low-frequency error. Kept (it's free and correct) but it is
   NOT the main lever, contrary to the task's prior.
2. **Stronger preconditioner — IncompleteCholesky** (the task's "10–100×"
   candidate). Prototyped behind an env switch and measured on 32³: it **halved**
   CG iterations (273→153) but **tripled** per-iteration cost (triangular solves)
   plus a factorization each solve → **net LOSS** (2.83 vs 1.46 s/iter). Rejected,
   with evidence. (Off-the-shelf strong preconditioners don't pay off here; the
   real 10–100× is a geometric-multigrid preconditioner — see "Remaining".)
3. **Eliminate redundant reassembly** — the clearly-wasteful 45%. This is the fix
   applied.

### The fix: `PenalizedSolver` (cached, pre-reduced operator) + warm start
New `topopt::PenalizedSolver` (declared in `core/include/topopt/fea.hpp`,
implemented in `core/src/fea/assembly.cpp`). For a fixed (grid, poisson, bcs,
loads) it **assembles the BC-reduced, void-gated stiffness PATTERN once** at
construction and, on every `solve(youngs_per_voxel)`, only:
  * zeroes and **rescales the cached matrix values in place** — `K = Σ_e E_e ·
    K_unit_block` scattered through a precomputed `slot` map (element-entry →
    CSR value index), O(nnz), no triplet rebuild, no sparse projection; and
  * **warm-starts** Jacobi-CG from the previous solve's field.

Design points that keep it correct and in-scope:
- **Void gate resolved topologically.** With every solid voxel carrying E>0
  (density clamped to [ρ_min,1]>0), a free DOF has stiffness iff a solid element
  touches it — exactly the diagonal-zero test the stateless `void_dof_survivors`
  does, but E-independent, so the kept set is fixed for the whole run. Same
  under-constrained/void-load exceptions preserved.
- **Homogeneous-BC requirement.** With a prescribed non-zero displacement the
  reduced RHS depends on E and can't be cached; the constructor then reports
  `usable()==false` and callers fall back to the stateless `fea_solve_cg`. The
  SIMP pipeline only ever uses homogeneous clamps, so it always takes the fast
  path.

Wiring (`core/src/simp/simp.cpp`): both `simp_optimize` overloads construct one
`PenalizedSolver` per run and pass it to `simp_compliance` each iteration and for
the final consistency solve. `simp_compliance` and the graded `fea_solve_cg` both
gained an optional trailing arg (`PenalizedSolver*` / `const FeaSolution*
initial_guess`), each defaulting to the exact prior path — so **every existing
caller and test is byte-for-byte unchanged** unless it opts in.

### Result — 64³, same case

| build            | s/iter | assembly | reduce | CG solve |
|------------------|-------:|---------:|-------:|---------:|
| baseline         | ~52.06 |    30.1% |  14.8% |    54.9% |
| **cached + warm**| **~29.13** | **2.3%** | **0%** | **96.7%** |

**≈1.8× faster at 64³**, and the win GROWS with resolution (assembly is O(N) with
a huge constant that is now amortized to once-per-run). Assembly went 44%→2.3%;
the sparse `P·K·Pᵀ` reduce is gone entirely. CG is now 96.7% — the irreducible
physics under Jacobi.

## Correctness (the guard)
- **Full `ctest`: 32/32 pass** on the clean production build, including the locked
  `gate_v2` (projected/OC formulation), `minimize_plastic`, `beam_validation`,
  `mbb_validation`, `variants`, `passive_regions`, `anchor_integrity`,
  `design_domain`, `mma`, `mma_projection_gate`, `stress`, `property_v3`. The
  unchanged direct-solver tests `fea_assembly` / `fea_cg` also pass (their paths
  are untouched — the new args default to the old behavior).
- **Direct equivalence check** (scratch harness): `PenalizedSolver.solve()` vs the
  reference stateless `fea_solve_cg` on the same graded systems (with Empty voxels
  exercising the void gate), across 4 random modulus fields → worst relative field
  difference **1.3e-9**, well inside the 1e-8 CG tolerance. The cached solver
  solves the *same* operator to the *same* residual criterion; it does not change
  the answer, only how fast it is reached.
- Gate-V2's asserts are tolerance bands (1%/5%/±0.01), and all held; no fixture
  was touched. This is a pure speed change.

## Files changed (all `/core/`)
- `core/include/topopt/fea.hpp` — `PenalizedSolver` class (Eigen-free pimpl);
  optional `initial_guess` on the graded `fea_solve_cg`.
- `core/src/fea/assembly.cpp` — `PenalizedSolver` impl (cached pattern + slot
  rescale + warm start); opt-in warm start in `solve_reduced_cg`.
- `core/include/topopt/simp.hpp` / `core/src/simp/simp.cpp` — optional
  `initial_guess` + `PenalizedSolver*` on `simp_compliance`; both `simp_optimize`
  overloads own a per-run solver and route every solve through it.

No `/app/`, no `tests/fixtures/**`, no `materials.json`, no `ROADMAP.md`. The
Phase-1 timing instrumentation was temporary and has been removed.

## Remaining bottleneck / recommended follow-up (NOT done here)
After this fix CG is 96.7% of a 64³ iteration: ~600 Jacobi-CG iterations/solve,
scaling ~O(h⁻¹) (273 at 32³ → ~600 at 64³). The genuine 10–100× lever is a
**geometric-multigrid V-cycle preconditioner** on the structured voxel grid
(mesh-independent iteration count) — the task's "standard huge win". It is a
larger, correctness-sensitive build (must handle the masked / void-gated /
arbitrary-domain analysis grid) and is left as a scoped follow-up; evidence above
shows off-the-shelf IncompleteCholesky does not net out. A second, cheaper lever
is **inexact intermediate solves** (loosen `cg_tolerance` for non-final optimizer
iterations while keeping the final/analysis solve at 1e-8) — standard in topopt,
but it perturbs the design path and touches the V2-locked tolerance, so it is
**flagged for maintainer review** rather than applied.

## ROADMAP
Not checked (per task).
