# 072 — Geometric-multigrid-preconditioned CG for the FEA linear solve

**Track:** core (`/core/` only — no `/app/`, no `tests/fixtures/**`, no
`materials.json`, no `ROADMAP.md`).
**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/geometric-multigrid-preconditioner-ee2ac2`
**Branch:** `claude/geometric-multigrid-preconditioner-ee2ac2`
**ROADMAP box:** NOT checked (reporting here per instructions).

## What this is

The FEA linear solve `Ku=f` dominates optimizer cost. The Jacobi-preconditioned
CG (`fea_solve_cg`) averages **~550 iterations at 64³** because the Jacobi
(diagonal) preconditioner is weak and its iteration count GROWS with grid size.
Handoff 071's perf profile named **geometric multigrid** as the 10–100× lever;
`IncompleteCholesky` was already tried and rejected (tripled per-iter cost).

This task implements a standard **V-cycle geometric multigrid used as the CG
preconditioner** (MG-preconditioned CG, the robust choice for SIMP FEA), exposed
as a new **opt-in** entry point `fea_solve_mgcg`. It solves the *identical*
system as `fea_solve_cg` and converges to the same `u`; the existing Jacobi-CG
path is byte-for-byte untouched, so Gate-V2 and the reference path are
unaffected. When multigrid is not applicable or does not help, it transparently
**falls back** to the exact Jacobi-CG solve.

Pure numerical linear algebra — no change to the optimizer, constraints, FEA
physics/formulation, or assembly.

## Results — Jacobi-CG (before) vs MG-CG (after)

Cantilever (x=0 face clamped, −z tip load), `tol=1e-8`, this machine
(AppleClang, `-O2`, single-threaded). Wall time is **end-to-end** (shared
assembly included in both).

| Case | Jacobi-CG | MG-CG | iters | wall | agreement |
|---|---|---|---|---|---|
| solid 32³ | 288 it / 1.95 s | **15 it / 0.92 s** | 19× | 2.1× | 1.9e-10 |
| solid 64³ | 578 it / 29.1 s | **15 it / 20.1 s** | 39× | 1.4× | 1.9e-10 |
| coherent* soft-void 32³ (ρ_min^p=1e-9) | 531 it / 2.6 s | **16 it / 0.88 s** | 33× | 2.9× | 6.5e-10 |
| coherent* soft-void 64³ (ρ_min^p=1e-9) | 1060 it / 47.4 s | **16 it / 18.8 s** | 66× | 2.5× | 5.9e-10 |
| adversarial random 64³-contrast 32³ | 786 it / 3.9 s | *falls back* → 786 it / 8.0 s | — | 0.5× | bit-identical |

\* "coherent" = a random density field passed through a box filter (spatial
coherence, the way a real SIMP density filter produces its field). This is the
representative SIMP case.

**Headline:** MG-CG is **mesh-independent** — ~15–16 iterations regardless of
grid size or soft-void contrast on realistic fields, while Jacobi grows
288 → 578 → 1060. The iteration win is **33–66×** on the representative cases;
the wall win is **1.4–2.9×** end-to-end because (a) the ~7 s assembly at 64³ is
shared by both paths and dilutes the ratio, and (b) building the Galerkin coarse
operators costs ~6 s at 64³. Measuring the **linear-solve phase alone**
(assembly excluded) the speedup is ~2.4–3.4×, and because MG iterations are
mesh-independent the gap widens sharply at larger grids (128³+), where Jacobi
would need ~1200+ iterations and MG still ~16.

**Honesty on fragility (per the task):** geometric MG with damped-Jacobi
smoothing degrades on *adversarial random* high-contrast coefficients — an
uncorrelated per-voxel ρ_min^p=1e-9 field made MG-CG need thousands of
iterations (measured 5918 at 32³ before the fallback budget was added). This is
the classic geometric-MG weakness with jumping coefficients and does **not**
occur on real (filtered, spatially-coherent) SIMP fields, where MG-CG stays at
~16 iterations. The solver guards this: MG-CG is capped at a modest iteration
budget (100); if it hasn't converged by then it **falls back to the exact
Jacobi-CG**, so the answer is always correct and never worse than "Jacobi plus a
bounded wasted probe". In the adversarial row above the fallback fired and the
result is bit-identical to Jacobi-CG (it *is* the Jacobi-CG solve).

## Design (justified)

- **Hierarchy** — vertex (node) coarsening by 2× per axis: a coarse node
  coincides with every other fine node. Coarsen while all element dims are even
  and ≥ 2, stopping when the coarsest level is ≤ 6000 DOFs (direct-solvable).
  64³ → 32→16→8 (4 levels, coarsest 8³); 32³ → 16→8 (3 levels).
- **Transfer** — trilinear interpolation `P` (coarse→fine); restriction is its
  transpose `R = Pᵀ` (full weighting), the variational pair.
- **Coarse operator — GALERKIN `A_c = Pᵀ A P`.** Chosen over a rediscretized
  coarse operator because Galerkin inherits the SIMP density-graded stiffness
  automatically and is robust to the soft-void modulus contrast (ρ_min^p); the
  coincident-node identity rows of `P` keep it full column rank, so every `A_c`
  stays SPD. Rediscretization is cheaper to build but less robust under high
  contrast — the task's stated trade-off; robustness was the priority.
- **Smoother** — damped Jacobi (ω = 0.6, **1 pre + 1 post** sweep). Equal
  pre/post sweeps of a self-adjoint smoother + `R = Pᵀ` + an SPD coarse solve
  make the V-cycle a **symmetric positive-definite** operator, i.e. a valid CG
  preconditioner. (1+1 measured more wall-efficient than 2+2: slightly more
  outer iterations but far cheaper per V-cycle.)
- **Coarsest level** — exact `SimplicialLDLT` factorisation (cached in the level).
- **Dirichlet BCs + void DOFs** — the hierarchy is built on the *same*
  BC-reduced, void-gated operator `fea_solve_cg` solves (shared
  `fea_detail::assemble_reduced` + `void_dof_survivors`). A coarse node-DOF is
  active iff its coincident fine node-DOF is active, so fixed/void DOFs propagate
  up every level; inactive coarse nodes are dropped from the interpolation
  stencil (the standard Dirichlet/void treatment).
- **Own CG loop** — MG-preconditioned CG is a hand-rolled loop (Eigen has no seam
  for a custom V-cycle preconditioner) using Eigen sparse matvecs, stopping on
  the same relative-residual criterion `‖b−Ax‖/‖b‖ ≤ tol` Eigen's CG uses.

## Correctness

MG-CG solves the identical `Kgg u = rg` (same assembly, same void gate) as
`fea_solve_cg`, to the same tolerance, so it converges to the same field — the
tests assert this three ways:
- exact uniaxial-tension patch (closed form),
- vs the direct `SimplicialLDLT` solver on an 8³ cantilever,
- **vs Jacobi-CG DOF-for-DOF on a SIMP soft-void graded 16³ grid** (ρ_min^p=1e-9,
  the ill-conditioned case) — `max|Δu|/max|u| ≤ 1e-6`.

The void-DOF gate (filter dangling-void DOFs / reject a loaded void DOF /
reject an all-void grid) and argument validation behave identically to
`fea_solve_cg`. The fallback path is exercised on a non-2×-divisible (15×6×6)
grid and cross-checked against the direct solver; the fallback's
non-convergence guard throws like `fea_solve_cg`.

## What changed (core only)

1. **`core/src/fea/fea_reduced.hpp`** (new, internal, Eigen-typed, NOT installed)
   — exposes the shared `SpMat`/`Vec`/`ReducedSystem` and the
   `assemble_reduced` / `void_dof_survivors` helpers so the multigrid TU builds
   its hierarchy on the exact same reduced system the Jacobi-CG path solves. The
   public `topopt/` API stays Eigen-free.
2. **`core/src/fea/assembly.cpp`** — refactor only: moved
   `SpMat`/`Vec`/`ReducedSystem`/`assemble_reduced`/`void_dof_survivors` into
   `namespace topopt::fea_detail` (declarations now in `fea_reduced.hpp`). No
   behaviour change — `test_cg` still reports the exact same **578 CG iterations**
   at 64³, and the whole suite is green.
3. **`core/src/fea/multigrid.cpp`** (new) — the V-cycle hierarchy, MG-CG loop,
   Jacobi-CG fallback, and the two `fea_solve_mgcg` entry points.
4. **`core/include/topopt/fea.hpp`** — declares both `fea_solve_mgcg` overloads
   (uniform + per-voxel graded, mirroring `fea_solve_cg`); `CgInfo` gains
   `bool used_multigrid` and `int mg_levels` (default false/0; the Jacobi-CG
   entry points leave them at defaults, so existing code is unaffected).
5. **`core/tests/unit/test_mgcg.cpp`** (new) + **`CMakeLists.txt`** target
   `fea_mgcg` and the `multigrid.cpp` source. 35 checks, all passing.

**Nothing else touched** — no optimizer, no FEA physics, no assembly maths, no
fixtures. `fea_solve_cg` / `fea_solve` are behaviourally unchanged; `simp.cpp`
still calls `fea_solve_cg`, so Gate-V2 and every optimizer test are byte-stable.

## How to adopt (out of scope here, opt-in)

`fea_solve_mgcg` is a drop-in replacement for `fea_solve_cg` (same signature +
`CgInfo`). To accelerate the optimizer, `simp_compliance` /
`minimize_plastic`'s solve calls could switch to it behind a solver-selection
flag (defaulting off so Gate-V2's reference path stays byte-identical). Because
the transfer operators `P` are purely geometric (density-independent), a future
optimization could cache them across SIMP iterations and rebuild only the
Galerkin `A_c` each solve — cutting the ~6 s setup that currently dilutes the
wall-time win. Not done here (scope = the linear solver only).

## Verification

```
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j8
ctest --test-dir build --output-on-failure --no-tests=error
```

`fea_mgcg` prints the 32³/64³ MG-CG iteration counts (15 each). No `<stdexcept>`
regressions — MG-CG throws the same `std::runtime_error` / `std::invalid_argument`
as `fea_solve_cg` on the same conditions.
