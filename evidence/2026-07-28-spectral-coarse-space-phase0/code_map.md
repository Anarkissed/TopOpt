# Code map (Phase-0 anchors used by the harness)

- Real developed field recipe: `core/tests/harness/amg_lean_probe.cpp:284` `develop_ultradilute`
  (OC loop: `simp_uniform_density` → {`filter_density`, `simp_compliance(...,MultigridCG_Matfree)`,
  `oc_update(...,move=0.2,rho_min=1e-3)`}). Ultradilute geometry `build_ultradilute` at
  `amg_lean_probe.cpp:243` (48×32×48 L-bracket, provenance handoff 134).
- Ladder rungs `{0.68,0.52,0.38,0.26}`: `core/src/simp/production.cpp:419` `production_reduction_ladder()`.
- SIMP: `SimpParams` `core/include/topopt/simp.hpp:34` — `youngs_modulus`(E0), `poisson`, `penalty=3`,
  `density_min=1e-3`. **No additive E_min**; floor = `density_min^p·E0 = 1e-9·E0` → **contrast 1e9**.
  `simp_youngs`/graded path `core/src/simp/simp.cpp:207,429`: `pow(clamp(rho,rho_min,1),p)·E0`.
- Element stiffness: `hex8_stiffness(E,nu,h)` `core/include/topopt/fea.hpp:48`, 24×24 row-major,
  `K(E,h)=E·h·K(1,1)`. Node id `(c*(ny+1)+b)*(nx+1)+a`; edof `3*node+comp`. `fea_element_nodes`
  `fea.hpp:143`, `fea_node_index` `fea.hpp:140`, `fea_node_count` `fea.hpp:137`.
- Constants: E0=3500 MPa, nu=0.33, p=3, rho_min=1e-3 (`amg_lean_probe.cpp:96`).
- Assembled global K (Eigen SparseMatrix): `assemble_reduced` `core/src/fea/assembly.cpp:218`
  (internal `fea_detail`); void-DOF gate `void_dof_survivors` `assembly.cpp:332` (drops DOFs with
  `|diag|≤1e-12·dmax`; soft-void 1e-9 SURVIVES → production keeps ~all DOFs). Matrix-free path
  `matfree.cpp`/`fea_matfree.hpp` (no assembled K — the 8M-DOF path).
- Real 8M extent: 192×112×128 elements = 193×113×129 nodes = 2,814,561 nodes → **8.44M DOF**
  (`amg_lean_probe.cpp`/`amg_probe.cpp`).
- Eigen: Homebrew 5.0.1 (`/opt/homebrew/include/eigen3`), `<Eigen/Eigenvalues>`
  `GeneralizedSelfAdjointEigenSolver` available. **No Spectra/SLEPc/HPDDM anywhere** — Eigen-only
  keeps BAR B2.
- No existing overlapping-subdomain / GenEO / partition-of-unity machinery. Geometric MG
  (`multigrid.cpp`, 2× vertex coarsening, Galerkin) and non-overlapping aggregation AMG
  (`amg_lean.hpp`) are the only coarse spaces. GenEO agglomerates are net-new (harness-only).
