# Code map — matrix-free GenEO Phase-0 harness

Single file: `core/tests/harness/geneo_matfree_probe.cpp` (NOT in CTest, NOT linked into
any production path, ZERO new build dependency — Homebrew Eigen dense + `libtopopt.a`).

## Build & run
```
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build --target topopt -j
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/geneo_matfree_probe.cpp core/build/libtopopt.a -o core/build/geneo_matfree_probe
./core/build/geneo_matfree_probe all evidence/2026-07-28-matrixfree-geneo-phase0
```
Modes: `selfcheck` | `measure` | `all`.

## What it builds on (production library, reused verbatim)
- `develop_field` runs the production OC recipe (`simp_compliance` + `oc_update`,
  `MultigridCG_Matfree`, 2.5 mm filter, rho_min 1e-3) to get a REAL developed density field.
- `hex8_stiffness`, `fea_element_nodes`, `fea_node_index/count` — the same element and DOF
  machinery the solver uses.

## The pencil and the operators (matrix-free)
`LocalOp` = compact per-subdomain object: element→local-DOF topology + per-element modulus +
the PoU diagonal D + `diag(A^Neu)`. It NEVER forms an n×n matrix.
- `applyNeu(x)` = A^Neu·x = Σ_{e∈agg} E_e (Ke·x_e)  (Ke = one shared 24×24 `hex8_stiffness(1)`).
- `applyDad(x)` = (D A^Neu D)·x = D∘applyNeu(D∘x).
Pencil solved for the SMALLEST λ: `A^Neu V = λ (D A^Neu D) V` (== arXiv 1912.13225 Def 3.1
reciprocal; the modes GenEO keeps).

## The two solvers
- **Reference (ground truth, harness-only):** `reference_smallest` / `reference_values` —
  dense `Eigen::GeneralizedSelfAdjointEigenSolver` on assembled A^Neu, (D A^Neu D + σI). The
  ONLY factorized object anywhere; used to score LOBPCG. σ-insensitivity checked in selfcheck.
- **Matrix-free `lobpcg_smallest`:** block LOBPCG for the m smallest eigenpairs, using ONLY
  `applyNeu`/`applyDad` + a preconditioner. Robust B-inner-product orthonormalisation
  (`borthonormalize`, eigen-drop of near-null / ker(B) directions). No shift, no pencil
  factorization. Matvecs counted (`g_mv`) as the cost currency.

## Preconditioners (E3)
`Precond::{None, Jacobi, InnerCG}`. Jacobi = diag(A^Neu)⁻¹ (the production Jacobi diagonal).
InnerCG = `inner_pcg`, k steps of Jacobi-PCG on A^Neu with the analytic rigid nullspace
projected out each step — a stand-in for "the existing matrix-free CG/MG as an inexact local
inverse"; its inner-iteration cost vs contrast is the E3 circular-dependency probe.
`rigid_modes` builds the 6 analytic rigid-body vectors (span ker A^Neu exactly).

## Scoring (B3)
`score_recovery` — for each reference eigenvector below the cut, the B-inner-product capture
= ‖proj onto LOBPCG subspace‖_B / ‖v‖_B. A mode is captured iff ≥ 0.999. Reports
captured/total and worst capture — a missed mode is reported, never averaged.

## Cases in `measure`
- Real field: cantilever 32×16×32, developed at rung 0.30 (wispy).
- `pick_surcharge` — scans core-6 agglomerates (dense eigenvalues-only) for the one with the
  most high-contrast surcharge modes (band (1e-8, 0.05) beyond the 6 rigid).
- **E1** plain picked subdomain @1e9; **E1b** adversarial channel (real density + inserted
  1-voxel soft-void plane → ~12 sub-threshold modes) — the many-mode B3 stress; **E2**
  contrast sweep 1e3/1e6/1e9/1e12 on the channel geometry; **E3** preconditioner study;
  **E4** memory (matrix-free vs dense) + cost + 8.44M-DOF extrapolation.

## Outputs
`probe_stdout.txt`, `e1_recovery.csv`, `e2_contrast.csv`, `e3_precond.csv`, `e4_cost.csv`,
`spectrum.csv`.
