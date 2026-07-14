# 077 — Matrix-free FEA operator + matrix-free CG

**Track:** core. **Territory:** `/core/` only (no app, no fixtures, no benchmarks,
no materials.json, no ARCHITECTURE.md, no ROADMAP box).
**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/results-chips-animations-fcd354`
(branch `claude/matrix-free-fea-cg-01a3c4`).

## Goal

Compute the voxel-FEA linear system `K u = f` **element-by-element without
assembling the global sparse `K`**. The assembled `K` (a `SpMat`) is what OOMs on
large design-box grids; this is the memory foundation that removes it. No new
physics — the identical isotropic Hex8 system fea_solve_cg solves, same DOF
numbering, same M3.1 void gate, same convergence criterion — just computed
matrix-free.

## What was built

All additions are new, opt-in, default-OFF. **The assembled path
(`fea_solve`, `fea_solve_cg`, `fea_solve_mgcg`, `PenalizedSolver`) is byte-for-byte
untouched** — the diff to `assembly.cpp` is purely additive (see below).

### 1. Matrix-free apply operator `y = K·u`  (`src/fea/matfree.cpp`, Eigen-FREE)

`fea_matfree_apply(grid, E|youngs_per_voxel, poisson, u) -> y` computes `K·u` over
the full global stiffness of all solid voxels, element-by-element. It exploits the
regular grid: every solid voxel is the same unit cube, so there is **one reference
24×24 element stiffness `Ke`** and each element's contribution scales it by the
per-voxel modulus. For each solid voxel: gather the 24 local DOFs of `u`, form
`y_local += factor · Ke · u_local`, scatter back.

- **Uniform**: `Ke = hex8_stiffness(E, nu, spacing)`, `factor = 1`.
- **Graded (SIMP)**: `Ke = hex8_stiffness(1, nu, spacing)`, `factor = E_voxel`
  (the isotropic Hex8 is exactly linear in `E`).

These mirror `assemble_reduced`'s two element builds byte-for-byte, so the
matrix-free apply equals the assembled `K·u`.

### 2. Matrix-free Jacobi-CG `fea_solve_cg_matfree`  (two overloads + `CgInfo`)

Mirrors `fea_solve_cg`'s two overloads exactly (uniform + graded, `CgInfo`,
optional graded warm-start `initial_guess`). It:
- builds the **same free-DOF numbering** (Dirichlet reduction) and the **same M3.1
  void-DOF gate** — resolved *topologically* (a free DOF survives iff a solid
  element touches it, which equals the assembled non-zero-diagonal test for
  strictly-positive moduli, exactly as `PenalizedSolver` already relies on);
- moves prescribed non-zero Dirichlet displacements to the RHS with the **same
  matrix-free apply** (`rhs = f − K·u_prescribed`);
- runs Jacobi (diagonal) preconditioned CG whose matvec is the matrix-free apply
  restricted to the surviving DOFs (scatter → element apply → gather), replicating
  Eigen's `ConjugateGradient<DiagonalPreconditioner>` algorithm and relative-
  residual criterion `sqrt(||r||²/||f||²) ≤ tol` (default cap `2·ng`, matching
  Eigen);
- **never constructs an Eigen `SpMat`** — `matfree.cpp` includes no Eigen header at
  all (the only reference to K is the 576-double reference `Ke`).

Same throws as `fea_solve_cg`: `invalid_argument` on bad BC/load index, graded size
mismatch, or non-positive solid modulus; `runtime_error` (before any iteration,
`CgInfo` = {converged:false, iterations:0}) on an all-void system or a load on a
void DOF; `runtime_error` on CG non-convergence within the cap.

### 3. Support surface
- `fea_assembled_apply` (uniform + graded) in `assembly.cpp` — the assembled
  reference operator (`y = Kff·u` via the real `assemble_reduced` with no BCs, so
  `Kff` is the full global `K`). The verification reference for operator equality;
  Eigen-free signature so the test needs no Eigen.
- `fea_matfree_operator_storage_doubles()` → `576` — grid-independent memory
  evidence.

## Correctness — proven, two levels (the anti-hollow guards)

Test: `core/tests/unit/test_matfree.cpp` (`ctest -R fea_matfree`), **78 checks,
all pass**.

**a. OPERATOR EQUALITY (atomic proof).** For random `u` (3 trials each) the
matrix-free `y = K·u` equals `fea_assembled_apply` DOF-for-DOF within `1e-9`
relative on: uniform solid grids `4³`, `5×3×2`, **`7³` (non-2-divisible)**,
`3×5×4`; a SIMP soft-void graded grid (`rho_min^p ≈ 1e-9 .. 1` per-voxel spread);
and a grid with genuine `Empty` voxels (void tail) — the operator ignores empty
voxels exactly like the assembled path. A wrong gather/scatter, wrong `Ke`, or
wrong density scaling fails this.

**b. FULL-SOLVE EQUALITY.** Matrix-free CG converges to the same field as
`fea_solve_cg` (and the direct `fea_solve`) `max|du|/max|u| ≤ 1e-6` on: the exact
`2×1×1` uniaxial patch (closed form); uniform cantilevers `6×4×4` and **`9×4×4`
(odd)**; the **ill-conditioned `16³` SIMP soft-void graded grid** (`rho_min^p =
1e-9`); a prescribed non-zero Dirichlet displacement case; and a warm-started
graded solve (equal field, no more iterations than cold).

**c. VOID-GATE + VALIDATION PARITY.** Same behaviour as `fea_solve_cg`: void DOFs
filtered and returned exactly 0 (solid nodes match the lone-cube solve); load on an
unsupported void DOF throws `runtime_error` before any iteration; all-void grid
throws; 1-iteration cap on a tight tolerance throws (`CgInfo` reports the
unconverged attempt); bad BC/load indices, graded size mismatch, non-positive solid
modulus, and a bad Poisson ratio all throw `invalid_argument`.

**d. MEMORY EVIDENCE.** `fea_matfree_operator_storage_doubles() == 576` asserted
constant across a `4³` and a `24³` solve (both converge; an assembled `K` would
grow from ~10⁴ to ~10⁷ nonzeros between these). Structural corroboration:
`matfree.cpp` contains **no Eigen include and no `SpMat`/`setFromTriplets`** — the
matrix-free solve path cannot allocate an assembled global operator. Verified:
`grep -nE "Eigen|SpMat|SparseMatrix|setFromTriplets" src/fea/matfree.cpp` matches
only comment lines.

## Evidence (raw ctest)

FEA subset (`ctest -R "fea_matfree|fea_cg|fea_mgcg|fea_assembly|hex_stiffness|traction_loads|beam"`):
```
fea_assembly ..... Passed   traction_loads ..... Passed
fea_cg ........... Passed   fea_mgcg ........... Passed
fea_matfree ...... Passed   beam_validation .... Passed
100% tests passed, 0 tests failed out of 6
```
`fea_matfree` self-report: `matfree 4^3 cantilever: 34 iterations, residual
8.155e-09, operator storage 576 doubles (grid-independent)`; `matfree 24^3
cantilever: 216 iterations, residual 8.240e-09, ...`; `fea matfree: all 78 checks
passed`.

Full suite: `ctest --test-dir build` — **100% tests passed, 0 failed out of 34**
(`gate_v2` 51.37s green; `fea_cg`, `fea_mgcg`, `beam_validation`, `simp`, `mma`,
`stress`, `variants`, … all pass; existing tests unchanged). *(Configured DEPS=OFF
locally: Eigen + OpenCASCADE present, lib3mf absent, so the 3MF-only tests are not
built — same as the existing local cache; the 34 built tests include Gate-V2. CI
runs DEPS=ON.)*

## Files
- `core/include/topopt/fea.hpp` — declarations (+90 lines, additive).
- `core/src/fea/matfree.cpp` — **new**, Eigen-free operator + CG.
- `core/src/fea/assembly.cpp` — `fea_assembled_apply` only (+36 lines, additive;
  existing solvers byte-identical).
- `core/CMakeLists.txt` — build `matfree.cpp` into `topopt`; add `test_matfree`.
- `core/tests/unit/test_matfree.cpp` — **new**, 78 checks.

## Not done / scope boundaries (honest)
- **No multigrid change** — the multigrid path (`fea_solve_mgcg`) is untouched, per
  task; the matrix-free preconditioner for MG is the next task. This is the plain
  matrix-free operator + Jacobi-CG only.
- **Nothing calls the matrix-free path in production** — it is opt-in; no bridge/app
  wiring, no ROADMAP box checked, no fixtures regenerated.
- The matrix-free apply is a straightforward per-element loop (no SIMD/threading);
  correctness first. It is O(elements) time, O(ndof) memory — the memory win is the
  point, not raw speed.
- `/core/` change — invisible to the app until `build_core.sh` rebuilds the
  xcframework.
