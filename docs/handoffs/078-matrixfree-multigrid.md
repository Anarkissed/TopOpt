# 078 — Matrix-free geometric multigrid (fine level never assembled)

**Track:** core. **Territory:** `/core/` only (no app, no fixtures, no benchmarks,
no materials.json, no ARCHITECTURE.md, no ROADMAP box).
**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/practical-chatelet-fe617e`
(branch `claude/intelligent-archimedes-a6b1a7`).
**Builds on:** 077 (matrix-free operator + `fea_solve_cg_matfree`, merged).

## Goal

Make the production (multigrid) solver run **matrix-free at the fine level**, so the
path production actually uses no longer assembles the giant fine stiffness matrix —
the assembled `K_ff` (a `SpMat` of ~O(voxels) nonzeros) is what OOMs on the
~623k-voxel design box. New, opt-in, default-OFF entry points
`fea_solve_mgcg_matfree` (uniform + graded). The assembled `fea_solve_mgcg` is
**byte-identical** and Gate-V2 stays pinned to it.

## THE ONE RULE — honoured

- `core/src/fea/multigrid.cpp` diff is **+468 / −0** — purely additive. Every
  existing function (`fea_solve_mgcg`, `solve_reduced_mgcg`, `build_hierarchy`,
  `v_cycle`, `mgpcg`, `jacobi_cg_fallback`) is **byte-for-byte unchanged**
  (`git diff` shows zero deleted lines). The matrix-free MG is entirely new code.
- Nothing calls the matrix-free MG in production — opt-in, no bridge/app wiring,
  no ROADMAP box, no fixtures regenerated.
- `fea_solve_cg_matfree` (077) and all existing suites pass unchanged.

## STEP 0 — coarse-operator strategy: **matrix-free Galerkin (element-local triple product)**

`build_hierarchy` forms Galerkin coarse operators `A_c = P^T A P` via sparse
products on the **assembled** fine `A`. With the fine level matrix-free that `A`
does not exist. The three candidates:

1. **Matrix-free Galerkin triple product** — form `A_c` without assembling `A`.
2. **Rediscretised coarse operators** — cheaper, but historically less robust under
   the `rho_min^p` high-contrast SIMP field (the documented reason Galerkin was
   chosen in 072).
3. **Fine matrix-free + assemble only the (≥8× smaller) level‑1 and coarser
   operators.**

**Decision: (1) ≡ (3) — matrix-free Galerkin via an element-local triple product.**
The finest operator `A0` is never assembled. `A1 = P0^T A0 P0` is formed
**element-by-element**: for each solid element, its reference block `factor·Ke`
(the same `Ke`/`factor` 077's apply uses) is projected through the trilinear
prolongation restricted to that element's ≤24 local coarse DOFs
(`W_e^T (factor·Ke) W_e`, `W_e = S_e P0`) and scattered. Summed over all elements
this is **exactly** `P0^T A0 P0` (`A0 = Σ_e factor_e S_e^T Ke S_e`), to summation
roundoff. All coarser levels (`A2 = P1^T A1 P1`, …) are the ordinary assembled
Galerkin products via the **reused** `build_hierarchy` seeded at `A1`.

Why this and not rediscretisation: it *reproduces the assembled Galerkin operator
DOF-for-DOF*, so it inherits Galerkin's soft-void robustness for free — no need to
prove a weaker rediscretised operator still converges. Proven empirically below:
on a 1e‑9-contrast soft-void grid the matrix-free MG converges in the **identical
iteration count** as the assembled Galerkin MG (18 == 18).

**Peak-memory implication.** The fine level stores only the single 24×24 reference
`Ke` (576 doubles, grid-independent) plus the O(elements) element table and
O(ndof) CG vectors. The assembled fine `A0` (the dominant term, ~O(voxels)
nonzeros) is **never allocated** — neither as a persistent operator nor as a build
intermediate. Only the coarse operators are assembled, and they are a fixed
geometric fraction (~12%) of the full assembled hierarchy; the complementary ~88%
is the absent fine matrix. The element-local build streams triplets for `A1` only
(O(576·elements), freed once `A1` is compressed) — it never materialises `A0` or an
`A0·P0` intermediate. So peak memory during the (many) V-cycle iterations is
dominated by the coarse operators, ~8× smaller than the eliminated fine matrix.

## What was built

- `core/src/fea/fea_matfree.hpp` — **new** internal (Eigen-free) header exposing
  077's matrix-free pieces in `fea_detail` so the multigrid TU reuses the *same*
  apply/diagonal/void-gate/CG (does not reimplement them): `MfElem`,
  `mf_build_elems`, `mf_apply_full`, `MatfreeReduced` (+`apply_kgg`),
  `mf_build_reduced`, `mf_cg_solve`.
- `core/src/fea/matfree.cpp` — refactored (+83 / −90) to *define* those in
  `fea_detail` and have its public entry points delegate. Behaviour and every
  thrown message are preserved byte-for-byte (`who`-parametrised); `test_matfree`
  passes unchanged.
- `core/src/fea/multigrid.cpp` — **additive** (+468 / −0): the matrix-free finest
  level (`mf_fine_matvec`, `mf_jacobi_sweep`), the matrix-free V-cycle
  (`mf_v_cycle`, reusing the assembled `v_cycle` for the coarse correction), the
  MG-PCG driver (`mf_mgpcg`), the element-local Galerkin hierarchy builder
  (`build_mf_hierarchy`), the orchestration + fallback (`solve_mgcg_matfree`), the
  two public entry points, and two diagnostic memory-evidence functions.
- `core/include/topopt/fea.hpp` — declarations for `fea_solve_mgcg_matfree` (×2)
  and the two evidence functions (additive).
- `core/CMakeLists.txt` — build/register `test_mgcg_matfree`.
- `core/tests/unit/test_mgcg_matfree.cpp` — **new**, 44 checks.

### SPD / valid CG preconditioner — preserved

The V-cycle keeps the assembled path's structure: equal pre/post damped-Jacobi
(ω=0.6, 1+1), `R = P0^T`, exact coarse solve (`SimplicialLDLT`). `A0` is the same
reduced SPD operator; `P0` has an identity row per coarse DOF (coincident even
nodes) so it is full column rank ⇒ `A1 = P0^T A0 P0` is SPD; the coarse sub-cycle
is the already-SPD assembled `v_cycle`. So the whole preconditioner is SPD — a
valid CG preconditioner (test 2 confirms CG converges; a non-symmetric `M` would
stall).

### Fallback discipline — same as the assembled path, still matrix-free

If no hierarchy is applicable (fine not 2×-divisible, or coarse not factorable) or
MG-CG does not converge within the budget, it falls back to the **exact
matrix-free Jacobi-CG** (`mf_cg_solve` — still no assembled fine `K`) and reports
`info.used_multigrid=false / mg_levels=0`. Throws on non-convergence, parity with
`fea_solve_cg` and the assembled `fea_solve_mgcg`.

## Correctness — the same-answer proof (`ctest -R fea_mgcg_matfree`, 44 checks)

**a. SAME FIELD, DOF-for-DOF.** `max|du|/max|u| ≤ 1e-6` vs both assembled
`fea_solve_cg` and assembled `fea_solve_mgcg`, on a real ≥3-level hierarchy (32³):
- **solid 32³** — matrix-free MG engages: 15 iters, 3 levels, residual 4.5e-9.
- **graded soft-void 32³** (coherent soft spherical core, `rho_min^p = 1e-9`) —
  matrix-free MG engages: **18 iters == assembled Galerkin MG's 18 iters**, field
  matches assembled MG to ~2e‑13. This is the STEP 0 proof: the element-local
  Galerkin reproduces the assembled coarse operator, so soft-void convergence is
  *identical*, not merely "converges".
- **adversarial random 32³** (per-voxel-independent 1e‑9 contrast — pathological
  for geometric MG) — the assembled `fea_solve_mgcg` *also* falls back here
  (`used_mg=0`, 841 iters); the matrix-free path matches that decision
  (`used_mg=0`, 843 iters) and the field still matches the exact solve. Parity of
  the fallback decision, never a wrong answer.

**b. SPD V-cycle.** CG with the matrix-free MG preconditioner converges in ≤40
iters at 16³ (a broken/non-SPD `M` would not).

**c. VOID-GATE + VALIDATION + FALLBACK parity.** Void DOFs filtered and returned
exactly 0 (matches the lone-cube solve); load on an unsupported void DOF throws
before any iteration (`info` reports the rejection); bad BC/load indices throw
`invalid_argument`; an odd (non-coarsenable) grid falls back to the exact
matrix-free Jacobi-CG (`used_multigrid=false`) and matches the direct solve; a
1-iteration cap on a tight tolerance throws (non-convergence parity).

**d. MEMORY — no assembled fine operator.** `fea_matfree_operator_storage_doubles()
== 576` (fine footprint, grid-independent). The matrix-free hierarchy assembles
only coarse operators; measured against the assembled hierarchy (which includes
the fine `A0`):

| grid | assembled hierarchy nnz | matrix-free (coarse-only) nnz | fine nnz avoided | matrix-free fine footprint |
|------|------------------------:|------------------------------:|-----------------:|---------------------------:|
| 8³   | 138 960 | 16 974 (12.2%) | 121 986 | 576 doubles |
| 24³  | 3 828 168 | 470 898 (12.3%) | 3 357 270 | 576 doubles |

The avoided (fine) nonzeros scale with voxel count (×27.5 from 8³→24³ ≈ (24/8)³)
while the matrix-free fine footprint stays a **576-double constant** — the memory
win. (Diagnostics: `fea_mgcg_assembled_operator_nonzeros` /
`fea_matfree_mgcg_assembled_operator_nonzeros`.)

## Evidence (raw ctest)

`ctest -R "fea_matfree|fea_cg|fea_mgcg|fea_mgcg_matfree|fea_assembly|gate_v2"`
(local Release-less config; unoptimised, hence the wall times):

```
1/6 fea_assembly ......... Passed    0.44 sec
2/6 fea_cg ............... Passed  383.41 sec
3/6 fea_mgcg ............. Passed  120.39 sec
4/6 fea_matfree .......... Passed   13.53 sec
5/6 fea_mgcg_matfree ..... Passed  351.48 sec
6/6 gate_v2 (PINNED) ..... Passed 1054.20 sec
100% tests passed, 0 tests failed out of 6
```

`fea_mgcg_matfree` self-report:
```
matfree MG-CG solid 32^3: 15 iters, residual 4.544e-09, 3 levels
matfree MG-CG graded soft-void 32^3: 18 iters (assembled MG 18), residual 5.340e-10, 3 levels
matfree MG-CG adversarial random 32^3: used_mg=0 (assembled used_mg=0), 843 iters, residual 9.705e-10
memory 8^3:  assembled 138960 nnz, matrix-free 16974 nnz -> avoids 121986 fine nnz, fine footprint 576 doubles
memory 24^3: assembled 3828168 nnz, matrix-free 470898 nnz -> avoids 3357270 fine nnz, fine footprint 576 doubles
fea mgcg matfree: all 44 checks passed
```

*(Configured DEPS=OFF locally: Eigen + OCCT present, lib3mf absent, so the 3MF-only
tests are not built — same as the existing local cache. CI runs DEPS=ON.)*

## Not done / scope boundaries (honest)

- **No production turn-on.** These are opt-in entry points; the bridge still calls
  the assembled `fea_solve_mgcg` (074's production MultigridCG). Wiring
  `fea_solve_mgcg_matfree` into `SolverKind`/`PenalizedSolver` and flipping the
  design-box path to it is the next task — that is where the OOM headroom actually
  reaches production. See [[solver-perf-cg-is-the-wall]] and
  [[ondevice-optimize-stall-is-multigrid-fallback]] (the 623k stall/fallback lives
  on the assembled path; matrix-free removes its memory ceiling but the stall fix
  is separate).
- **`A1` build transient.** The element-local Galerkin streams O(576·elements)
  triplets for `A1`, freed once `A1` is compressed. This is a one-time setup
  transient (not resident during the iterations); batching it to bound the setup
  peak at production scale is a possible follow-up, but it does not touch the
  steady-state win (no fine `A0` during the many V-cycles).
- **Matrix-free apply is the plain 077 per-element loop** (no SIMD/threading) —
  correctness/memory first, raw speed later.
- The two evidence functions build a throwaway hierarchy; they are test/diagnostic
  only, not on any solve path.
- `/core/` change — invisible to the app until `build_core.sh` rebuilds the
  xcframework.
