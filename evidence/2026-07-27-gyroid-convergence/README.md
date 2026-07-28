# evidence — 2026-07-27 gyroid direct free-surface convergence

First-hand output for the handoff `docs/handoffs/2026-07-27-gyroid-convergence.md`.
Answers the question: **why did PR 198's 5-cell direct comparison return
`direct_freeface_E = 0.0000`, and what is the real value?**

## Files

- `h3b_direct_convergence.csv` — the deliverable. Direct free-surface uniaxial
  modulus (production `fea_solve_cg`, free lateral faces) for gyroid at
  K = 1, 2, 3, 5, 7 cells and Schwarz-D / octet at K = 1, 2, 3, 5, each against
  its own exact periodic-homogenized bulk. This is the column PR 198 left at
  `0.0` for K > 3. Columns: `lattice, cells, vpc, voxels, rho, wall_mm,
  periodic_bulk_E_MPa, direct_freeface_E_MPa, direct_over_Es, gap_vs_bulk_pct,
  direct_solve_ms`.
- `h1_self_check.txt` — G1 re-run of the H1 solid-cell self-check. Must recover
  the analytic isotropic tensor to machine precision. It does (~8e-15).
- `probe_stdout_gyroid.txt` — full console log of the gyroid K = 1..7 run.
- `probe_stdout_others.txt` — full console log of the Schwarz-D / octet run.

## Root cause (one line)

`core/tests/harness/lattice_homog_probe.cpp` line 668:
`double dirE = (K <= 3) ? direct_apparent_E(grid, 2) : 0.0;`
The K = 5 direct solve was never run — it was short-circuited to a literal `0.0`
and written verbatim into `h3_convergence.csv`. Not a crash, not a solver
failure. The `cg_iters` / `solve_ms` in that CSV row belong to the *periodic*
homogenization solve, not the (skipped) direct solve. This skip is
lattice-agnostic: all three lattices got `0.0` at K > 3.

## Result (gyroid, the decisive lattice)

| K | direct E (MPa) | E/Es   | gap vs periodic bulk 419.85 |
|---|----------------|--------|------------------------------|
| 1 | 291.55         | 0.0833 | -30.56%                      |
| 2 | 353.99         | 0.1011 | -15.69%                      |
| 3 | 375.04         | 0.1072 | -10.67%  (PR 198 stopped here)|
| 5 | 392.48         | 0.1121 | **-6.52%**  (below 10%)      |
| 7 | 400.36         | 0.1144 | **-4.64%**                   |

The gap is a windowed-RVE / free-surface artifact that decays ~ 1/K
(gap·K ≈ -31 across all rows) and Richardson-extrapolates to ≈ -0.3% at
K → ∞ — i.e. the direct free-surface modulus converges onto the exact periodic
bulk. **Gyroid's 11.9% NO-GO at 3 cells was a measurement artifact of the
comparison window, not a homogenization failure. Gyroid is a GO.**

## Reproduce

From `core/` (core lib built with `-DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF`):

```bash
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_homog_probe.cpp build/libtopopt.a -o build/lattice_homog_probe
# gyroid, all cell counts (K=7 ~23 min on a 6-P-core Mac):
TOPOPT_HOMOG_ONLY=h3b TOPOPT_H3B_LATTICE=gyroid \
  TOPOPT_LATTICE_CSV_DIR=../evidence/2026-07-27-gyroid-convergence ./build/lattice_homog_probe
# other lattices capped at K=5:
TOPOPT_HOMOG_ONLY=h3b TOPOPT_H3B_KMAX=5 TOPOPT_LATTICE_CSV_DIR=<dir> ./build/lattice_homog_probe
```

`TOPOPT_H3B_LATTICE=<gyroid|schwarzD|octet>` restricts to one lattice;
`TOPOPT_H3B_KMAX=<n>` caps the cell count. H1 self-check: `TOPOPT_HOMOG_ONLY=h1`.
