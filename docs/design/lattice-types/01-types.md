# 01 — The eight types: what is measured and what is owed

**Plain language:** for each new type, this page says what core already knows and what still has to be measured before it can be picked. The good news: the hardest numbers (how stiff each type is at each density) were measured in July for all eight. What's missing is mostly the practical side. How thick does a strut come out at a given density? How small can a cell get before the certificate stops being trustworthy? Do the struts still join up when cells change size?

All numbers below come from the repo's evidence folders (paths in `04-references.md`). "L" is the cell edge. "ρ" is relative density (the solid fraction).

## A. Strut lattices

| Type | Struts / cell | ρ ≈ K·(r/L)², K = | Strut angles from vertical | Certifiable band (ρ) | Zener (anisotropy) | Notes |
|---|---|---|---|---|---|---|
| **Octet** (reference, shipped) | 24 | 48.0 | 45° ×16, 90° ×8 (a third are horizontal bridges) | 0.05–0.90 | same rows as FCC (legs-only) | **Printed** 2026-07-27 (8 mm graded block, supports on plate only). Tensor is legs-only (see Q2). |
| **SC** Simple cubic | 3 | 8.4853 | 0° ×1, 90° ×2 (two thirds are horizontal bridges) | 0.087–0.496 | 0.045–0.60 | **Strongly directional** (near-zero shear). R3 note. |
| **BCC** Body-centred cubic | 8 | 19.5959 | 55° ×8 | 0.210–0.593 | 1.56–34.7 | **Strongly directional** (bending-dominated). R3 note. |
| **FCC** Face-centred cubic | 12 | 24.0 | 45° ×8, 90° ×4 | 0.095–0.591 | 0.87–1.74 | Octet's legs without the braces. **Its tensor is the shipped "octet" tensor** (Q2). |
| **Diamond** | 16 | 19.5959 | 55° ×16 | 0.157–0.592 | 1.57–2.92 | 4 struts meet at each node. |
| **Kelvin** (truncated octahedron) | 24 | 24.0 | 45° ×16, 90° ×8 | 0.094–0.505 | 0.68–0.89 | Closest to isotropic. One interior node reads −3.2 %; all others ≤ 2.0 %. |
| **Rhombic dodecahedron** | 32 | 39.1918 | 55° ×32 | 0.172–0.513 | 1.23–2.78 | Narrower band (thin struts at low ρ). |

**Printability of the angles, not the types:**
- The octet print proved 45° struts and 90° bridges across an 8 mm cell with no internal support.
- The BCCZ print (2026-07-29) proved 55° diagonals and vertical columns.

So every strut angle in the six types has been printed in *some* lattice. That does not make the types proven: node shapes, strut counts and densities differ. Hence the "Not print-tested" tag (M2).

**Already measured, for all six:**
- the tensor rows (the certificate can run);
- the low-density K;
- the canonical cell tables (`evidence/2026-07-27-strut-lattice-family/strut_lattice_gen.cpp`);
- 40 mm test blocks from the harness generator (not production).

**Owed per type (R1):**
1. **Production generation**: in `core/src/mesh/lattice_gen.cpp`, which is octet-only today.
2. **Density ↔ diameter law**, measured by voxelising, the way octet's was:
   - `octet_relative_density` is measured at vpc48;
   - `kOctetDia` comes from PR 235's B3 table.

   K·(r/L)² holds only at low density, where the nodes don't overlap.
3. **Printability floor** from the type's own diameter table. Today `lattice_cell_printability_floor_mm` and `lattice_min_density_for_strut` read **octet's** table for every type.
4. **Bending cells-per-member floor**, by PR 235's guided-cantilever study. Octet crosses 2.4 % between 4 and 5 cells. For the other types, 5 is a forwarded placeholder, expected to be **too low** for SC, BCC, Diamond and Kelvin (tensor-library-nine T4).
5. **Percolation floor.** Octet's 1.0 was measured axially at ρ ≈ 0.199 only.
6. **Aesthetic hard floor check.** The "2 cells" rule rests on octet's +8.5 % at 2 cells in bending. Re-measure it per type.
7. **Size-step connectivity** (R4).
8. **Strut-strength law**, the PR 259 method (R10). This is report-only.
9. **Aesthetic density ceiling** from the type's own diameter table (R11).

## B. Sheet lattices (TPMS)

Rows are from `evidence/2026-07-26-lattice-homog-phase0/tensor_library.csv`: one periodic cell, L = 5 mm, vpc48. Only rows flagged `resolved = 1` are usable.

| Type | Usable band (ρ) | E100/Es at ρ ≈ 0.20 / 0.30 / 0.40 / 0.50 / 0.60 | Zener | Scale separation (PR 221) |
|---|---|---|---|---|
| **Gyroid** | 0.150–0.600 (the 0.10 row is unresolved) | 0.069 / 0.114 / 0.170 / 0.244 / 0.334 | 1.09–1.16 (nearly isotropic) | Free-face vs bulk gap: −30.6 % at 1 cell, −15.7 % at 2, −10.7 % at 3, −6.5 % at 5, −4.6 % at 7. Clears 10 % at 5 cells (axial). |
| **Schwarz-D** | 0.202–0.600 (the 0.10 and 0.15 rows are unresolved) | 0.084 / 0.136 / 0.198 / 0.269 / 0.363 | 0.72–1.02 | −0.30 % at **one** cell (axial). It separates almost at once. |

**For comparison**, the shipped octet library row reads E100/Es 0.082 at ρ ≈ 0.30. At equal weight along an axis, gyroid is about **1.4×** as stiff and Schwarz-D about **1.7×**. Resolution check (`hr_resolution.csv`): vpc32 → vpc48 moves E100/Es by +1.8 % for gyroid and +1.4 % for Schwarz-D at ρ ≈ 0.30.

**Two traps in the evidence.**
1. **The July sheet is not the production sheet.** The probe built the wall as \|f(x)\| < level (`lattice_homog_probe.cpp`, `is_solid`). That wall is thick where the field is flat and thin where it is steep. Production needs one uniform thickness, the gradient-normalised band (R7), because printing is in whole beads. The two are different geometry, so **the rows must be re-measured on the production wall** with the same probe before a sheet type can be certified.
2. **`wall_mm` is not a wall thickness.** It is the probe's construction parameter. A thin gyroid sheet has ρ ≈ 3.09·t/L (surface area 3.09/L per unit volume), so the 0.30 row's `wall_mm` of 0.729 would give ρ ≈ 0.45, not 0.30. Measure the true normal wall thickness against ρ.

The July rows remain good for **ranking and planning**: the stiffness ratios above, and the scale-separation numbers.

**Owed per type (R1):**
1. The tensor rows **re-measured on the production wall** (the PR 198 probe with R7's wall), resolution-checked the PR 198/237 way, then landed. Low end as far as the resolution allows.
2. The **true wall-thickness ↔ ρ law**, measured.
3. **Printability floor**: wall ≥ one bead (R6).
4. **Production generation**:
   - the shared field (R7);
   - the existing dual-contouring mesher (`core/include/topopt/lattice_dc.hpp`);
   - clipped by the same surface as the skin ("one surface", the PR 316 lesson);
   - streamed.
5. The **triangle count** per region against octet on the same region. The reviewer's guess of 3–8× per cell was never measured.
6. **Bending cells-per-member floor** and **percolation floor**, measured. PR 221's numbers are axial only.
7. The sheet-stress report: the PR 259 method adapted to sheets, or a stated refusal (R10).
8. Grading by thickness only; Doubled and Stepped refused (R5). Diagrid refused (R8).

## C. Not in this round

- **BCCZ, FCCZ, Re-entrant**: tetragonal. Their constants are measured (`evidence/2026-07-29-tensor-library-nine/csv/*_sweep.csv` carries C33 and C44_yz), but certification needs the tetragonal path (Q4). BCCZ was **printed** on 2026-07-29 and is recorded in `lattice_print_tests.json` for when it arrives.
- **Weaire–Phelan, Voronoi**: need a seed-Voronoi generator (`evidence/2026-07-27-strut-lattice-family/weaire_phelan.txt`).
- **Schwarz-P, Lidinoid, Split-P, Neovius**: sheet types with no homogenised rows in the repo. Schwarz-P is the natural next sheet: Garzon 2026 ranks it the most efficient in stiffness per density.
- **Honeycomb**: Flexible-only (DECISIONS 2026-09-27).
