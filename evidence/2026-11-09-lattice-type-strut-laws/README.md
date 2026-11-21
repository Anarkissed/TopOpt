# Strut-strength laws for the other eight lattice types (ruling 11-08 (B), R10)

Each type's own law, measured exactly the PR 259 way
(`evidence/2026-07-31-lattice-dehomogenization-probe`, octet's), by
`core/tests/harness/lattice_dehomog_probe.cpp` with `TOPOPT_DEHOMOG_TYPE=<type>`.
`<type>/kfit.csv`'s `*_cert` columns are the table `core/src/fea/strut_strength.cpp`
carries, verbatim. `test_lattice_type_strut_law` pins every row. No type borrows octet's law.

## Method (PR 259's, unchanged)

- **K_dev:** exact, the 5x5 generalized eigenproblem.
- **K_vol:** the hydrostatic ratio.
- **Interlayer pair (Kild, Kilv):** build direction on a cube axis.
- **Bulk:** periodic cell, vpc 16 to 48. The law row is the finest, vpc 48.
- **Boundary populations:**
  - free faces (sandwich block);
  - cut cells (a cut layer at 0.6 of a cell).
  - At every rho of the band: N4 vpc16 blocks, and N3 vpc24 for rho under 0.19.
- **Law per rho:** the envelope (max) of bulk and boundary.
- **Aliasing guard:** a row more than 15 % off its library rho is dropped.
- **Range:** each type's whole certified band. The first and last rows are `lattice_rho_min` and `lattice_rho_max`.
- **Sheets:** gyroid and Schwarz-D are measured on the production wall (R7).

**One addition, PR 259's own remedy made automatic.** The first run dropped four boundary rows to the aliasing guard; in one of them the sheet fell apart. Those rhos were left with no boundary population, so their law read the bulk alone, below the cut cells. PR 259 re-measured its aliased low band at a finer pitch; the probe now does the same, case by case:

- the ladder is N4 vpc16, then N3 vpc24, then N3 vpc32, then N3 vpc40;
- it stops at the first case the guard keeps;
- every attempt is written to the CSVs.

| type | rho | first run | re-measured | Kd_cert before -> after |
|---|---|---|---|---|
| sc | 0.08659 | cut block -15.7 % at vpc24 | vpc32 | 316.70 -> 593.33 |
| diamond | 0.20000 | +17.2 % at vpc16 | N3 vpc24 | 56.07 -> 73.70 |
| rhombic | 0.17245 | +22.2 % at vpc24 | vpc32 | 90.61 -> 137.42 |
| schwarz_d | 0.20038 | fell apart at vpc16 (-92.7 %) | N3 vpc24 | 17.48 -> 36.70 |

For these four types:
- `kfit_first_run.csv` and `k_exact_boundary_first_run.csv` are the first run.
- `boundary2.log` and `fit2.log` are the re-measure.
- Every first-run row reproduced bit for bit; only new rows were added.

## The laws

| type | band (rho) | rows | Kd_cert at band floor -> ceiling | cells-per-member floor | selfcheck S1-S6 |
|---|---|---|---|---|---|
| sc | 0.08659 - 0.49638 | 7 | 593.33 -> 20.91 | 4 | PASS |
| bcc | 0.21050 - 0.59288 | 4 | 124.90 -> 12.01 | 10 | PASS |
| fcc | 0.09505 - 0.59093 | 6 | 76.27 -> 9.67 | 5 | PASS |
| diamond | 0.15712 - 0.59201 | 5 | 108.33 -> 11.74 | 10 | PASS |
| kelvin | 0.09375 - 0.50521 | 6 | 194.24 -> 11.87 | 8 | PASS |
| rhombic | 0.17245 - 0.51331 | 5 | 137.42 -> 11.96 | 10 | PASS |
| gyroid | 0.15010 - 0.60069 | 5 | 59.60 -> 9.45 | 10 | PASS |
| schwarz_d | 0.20038 - 0.60012 | 4 | 36.70 -> 9.24 | 9 | PASS |

For comparison, octet (PR 259) runs 0.04762 - 0.89598, with Kd 124.09 -> 3.69.

S6 checks that the dev/vol bound holds on 64 mixed states; every type passes (`<type>/selfcheck.csv`).

## Caveats (PR 259's, carried)

1. **Log growth with resolution.** The peak is a voxelized joint peak and still grows with vpc. Bulk K_dev from vpc 32 to 48:
   - strut types: -11 % to +50 %. sc reaches +50 % at 0.087, rhombic +48 % at 0.172, bcc +47 % at 0.313.
   - sheets: at most +11 %. Smooth walls have no sharp joints.

   So the strut laws are lower bounds that are still rising. The boundary blocks (vpc16 to 32) read low by that same growth.

   Rows with at most 4 wall voxels at vpc 48 are the least resolved: sc 0.087, fcc 0.095 and 0.157, gyroid 0.150, Schwarz-D 0.200. They are lower bounds, as octet's 2-voxel floor row is.
2. **Cells-per-member floor.** The finite blocks are 3-4 cells across, under every type's floor; only sc's floor of 4 is met, and only by the N4 blocks. A part whose thinnest latticed member is under its type's floor is not certified from the law. It reads "below the N the strut-strength law is valid for"; `test_strut_strength` 7c checks this, in words, for kelvin (floor 8).

   **A gap in that guard, found here and not changed.** The guard measures a member's width from the void in the design grid, and the grid's outside is not counted as void. A part that fills its own grid, such as a plain latticed bar, therefore reads as infinitely thick and is never flagged. `test_lattice_no_solid`'s bar (5 cells across) shows this for octet as well as kelvin. Octet stays byte for byte in this batch, so the fix (count the outside as void for this guard only) waits for a ruling.
3. **z_knockdown is unsourced.** It is the same material number octet's law uses (materials.json), unchanged.

## Files per type

- `selfcheck.csv`
- `bulk_tensor.csv`
- `k_exact_bulk.csv` and `k_states_bulk.csv`
- `k_exact_blocks.csv` and `k_states_blocks.csv`
- `k_exact_boundary.csv` and `k_states_boundary.csv`
- `k_cells.csv`
- `kfit.csv`
- `all.log`, plus `boundary2.log` and `fit2.log` where re-measured

`reproduce.sh` reruns everything.
