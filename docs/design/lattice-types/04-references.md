# 04 — References (each with the specific finding it supports)

**Plain language:** everything this round relies on is either measured in the repo already, printed on the maintainer's printer, or published. Here is each source and exactly what it shows. The standing bar applies: no "not possible / not printable / not viable" verdict without naming these and saying why they don't apply.

---

## A. Physical prints (maintainer, supports on plate only)

- **Octet**, 2026-07-27 (`docs/handoffs/2026-07-27-octet-print-test.md`):
  - graded 8 mm cells;
  - 45° struts and 90° horizontal bridges across one cell, self-supporting;
  - graded struts down to about 0.96 mm on a 0.4 mm nozzle;
  - reprinted with supports on the plate only, with nothing propping the interior.
- **BCCZ**, 2026-07-29 (photos in chat; no handoff):
  - 55° diagonals and vertical columns printed clean;
  - harder on **bed adhesion** (sharp cell corners on the plate), which is why the sample block has a solid base plate (R13).

## B. Measured in this repo (read these; the numbers in this pack come from them)

| Handoff / evidence | Finding used here |
|---|---|
| `2026-07-26-lattice-homog-phase0` (PR 198); `evidence/2026-07-26-lattice-homog-phase0/tensor_library.csv`, `hr_resolution.csv` | Periodic homogenisation of **gyroid, Schwarz-D and octet**, ρ 0.10–0.60 at vpc48. Resolved rows: gyroid from 0.150, Schwarz-D from 0.202. vpc32 → 48 moves E100/Es by +1.8 % (gyroid) and +1.4 % (Schwarz-D) at ρ ≈ 0.30. **The sheet was built as \|f\| < level** (`lattice_homog_probe.cpp`); see 01-types §B. |
| `2026-07-27-gyroid-convergence` (PR 221) | Gyroid free-face gap against bulk: −30.6 / −15.7 / −10.7 / −6.5 / −4.6 % at 1 / 2 / 3 / 5 / 7 cells, so it is a **GO at 5 cells**. Schwarz-D is −0.30 % at one cell. The earlier NO-GO was a hard-coded skip. |
| `2026-07-27-strut-lattice-family` (PR 219) and its evidence (`strut_lattice_gen.cpp`, `lattices.txt`, `density.txt`, `angles.txt`, `union_character.txt`, `weaire_phelan.txt`, `files/*_40mm.stl`) | **Ten strut types as table entries** with the same generator machinery as octet: canonical cells, K, angles, the self-intersecting-soup union (which slicers accept, as octet's does), and 40 mm blocks. Weaire–Phelan needs Voronoi, so it is out of scope. |
| `2026-07-28-graded-cell-size-phase0` (PR 235); `evidence/…/b3_printability.csv`, `c2_cells_per_member.csv`, `c2b_bending.csv` | The tensor is **scale-invariant** (identical to machine precision across 4–32 mm cells). The diameter is exactly linear in cell size (B3). Bending is the binding floor: +48.5 / +8.5 / +4.1 / +2.59 / +1.78 % at 1–5 cells. The method to repeat per type. |
| `2026-07-28-density-band-extension` (PR 237) | How octet's band was widened to 0.05–0.90 (higher vpc at the low end, a validated high end). The method for pushing new types' bands. |
| `2026-07-29-tensor-library-nine` (PR 246); `evidence/2026-07-29-tensor-library-nine/` | **SC, BCC, FCC, Diamond, Kelvin and Rhombic are certifiable**, with rows landed in `lattice.cpp`. Bands and Zener are in 01-types. Finding 3: the shipped "octet" tensor is legs-only (≡ FCC); the full-octet rows are measured but not landed. T4: the bending floor is not measured for the others. BCCZ, FCCZ and Re-entrant are tetragonal and refused. |
| `2026-07-29-lattice-layer-anisotropy`, `2026-07-29-layer-anisotropy-fea` (PR 247) | Layer (interlayer) weakness is modelled for solids. Lattice voxels are excluded from the interlayer field. This is a **carried gap** for every type, octet included; it is not fixed this round. |
| `2026-07-31-lattice-dehomogenization-probe` (PR 259), `2026-07-31-lattice-strut-strength-report` | The octet strut-stress law (bulk, free-surface and cut-cell envelope) and the report-only evaluator that refuses other types. The method to repeat per type (R10). |
| `2026-07-28-lattice-generation-production`, `2026-07-29-lattice-boundary-finish`, `2026-07-30-lattice-skin-freeform`, `2026-08-08-strut-clip-matches-shell` | The production generator's streaming, determinism, clipping and skins, and the **"one surface"** rule (the lattice is clipped against the surface the shell comes from). |
| `core/include/topopt/lattice_dc.hpp`, `lattice_union_volume.hpp` | Surface-adaptive manifold dual contouring of an SDF (Schaefer, Ju & Warren, *IEEE TVCG* 13(3):610–619, 2007, doi:10.1109/TVCG.2007.1012), and a mesh-free union-volume acceptance test. The sheet generator reuses both. |
| `docs/handoffs/2026-09-18-core-brief-preview-parity.md` (on 354's branch) | The "the run's STL is exactly the preview" ruling, and every step of octet's preview (regions, cell derivation, size ladder, placement, outline beam). The new types must follow it. |

## C. Published (sheet lattices, FDM unless stated)

- **Justino Netto, Sardinha & Leite 2024.** "Influence of the cell size and wall thickness on the compressive behaviour of fused filament fabricated PLA gyroid structures", *Mechanics of Materials* 195, 105051, doi:10.1016/j.mechmat.2024.105051. PDF in `papers/1-s2.0-S0167663624001431-main.pdf`.
  - **FDM PLA gyroid prints** at 1, 1.5 and 2 bead walls (0.4 mm nozzle, 0.1 mm layers) in 4–10 mm cells.
  - At equal density, cell size and wall thickness matter separately: 2-bead/10 mm was 26 % stiffer but 36 % weaker than 1-bead/5 mm.
  - Gibson–Ashby exponents: stiffness 1.24, yield 1.78.
  - **1-bead walls had holes at overhangs; 2-bead walls were hole-free** (R6, Q3). Prints were 1.1–7.9 % lighter than designed.
- **Saleh, Anwar, Al-Ahmari & Alfaify 2022.** "Compression Performance and Failure Analysis of 3D-Printed Carbon Fiber/PLA Composite TPMS Lattice Structures", *Polymers* 14(21), 4595, doi:10.3390/polym14214595, https://pmc.ncbi.nlm.nih.gov/articles/PMC9654767/
  - **FDM (Prusa MK3S+) PLA and PLA-CF Diamond (Schwarz-D), Gyroid and Primitive** at 23–44 % relative density, with 6 / 8 / 12 mm cells.
  - Modulus 0.09–0.47 GPa; strength 2.98–13.89 MPa. **Diamond best** in modulus, strength and energy.
  - As-built density within ±8 % of design, **except small-cell, low-density Diamond** (+26 %, from overlapping walls). The authors warn that small cells at low density need attention to extrusion width.
- **Bean, Lopez-Anido & Vel 2022.** "Numerical Modeling and Experimental Investigation of Effective Elastic Properties of the 3D Printed Gyroid Infill", *Applied Sciences* 12(4), 2180, doi:10.3390/app12042180, https://www.mdpi.com/2076-3417/12/4/2180
  - Cura gyroid in toughened PLA, 25–100 %, single- and double-bead walls.
  - **Periodic homogenisation predicted the printed longitudinal modulus within 4 % at 50 % density** (test scatter 5 %).
  - Zener 0.95–1.25: gyroid is close to isotropic, which matches PR 198's 1.09–1.16.
- **Garzon, Ferrandiz Bou, Rayón Encinas, Abril & Cobos Maldonado 2026.** "Mechanical characterisation of stereolithography-printed TPMS scaffolds: geometry and density property relationships", *Progress in Additive Manufacturing*, doi:10.1007/s40964-026-01751-3.
  - **SLA, not FDM.** Gibson–Ashby modulus exponents: Diamond 1.78, Split-P 1.96, Schwarz-P 2.20, Gyroid 2.29, Lidinoid 3.68.
  - By prefactor, Schwarz-P is the most efficient. It is the natural next sheet type (01-types §C).
- **Wallat, Altschuh, Reder, Nestler & Poehler 2022.** *Materials* 15, 3730, doi:10.3390/ma15103730 (`papers/materials-15-03730.pdf`).
  - Grades gyroid by **level set / thickness at a fixed cell** (constant, linear, quadratic).
  - Stress peaks sit on the high-porosity side. Per-slice matching makes wall ripple (R5).
- **Wang, Wang, Zhao, Wu, Feng & Wu 2026.** *Composite Structures* 377, 119794, doi:10.1016/j.compstruct.2025.119794 (`papers/1-s2.0-S0263822325009596-main.pdf`).
  - Grades gyroid thickness per 5 mm cell from a load path, printed in FDM PLA-CF.
  - **Measured +15.6 % stiffness against the +71.5 % FEA predicted**, so graded gains can be far smaller than the model says. Their Eqs. 14 and 16 contain errors; don't copy them (R5).
- **Kedziora, Decker & Museyibov 2023.** *Materials* 16, 4401, doi:10.3390/ma16124401 (`papers/materials-16-04401-v2.pdf`).
  - Graded gyroid thickness in metal FFF.
  - **Walls that aren't multiples of the line width printed badly**. The Q3 and R6 print test watches for this.
- **Not found:** any published method for grading a TPMS's **cell size** at a fixed wall. A Nov 2025 "pyramid-shaped TPMS transition" method was mentioned in an earlier session; its citation was not recorded. This is why R5 exists.

## D. Further data (not needed this round)

- Lumpe & Stankovic, *PNAS* 118 (2021), doi:10.3929/ethz-b-000457598: homogenised properties of more than 17,000 lattices.
- Bastek, Kumar, Telgen, Glaesener & Kochmann, *PNAS* 119 (2022), doi:10.3929/ethz-b-000520254: an anisotropic truss-stiffness dataset. Check its licence before redistributing.
