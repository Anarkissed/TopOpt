# Strut-strength laws of BCC, Diamond and SC, down to the struts the new engine lays

The maintainer's decision, 2026-11-24 23:17 EST: "STRENGTH: YES, MEASURE." BCC's, Diamond's and SC's strut laws and
stiffness rows started where the new lattice engine barely lays struts, so the strength check credited none of them.
They are now measured down to its thinnest struts, each type on its own cell. Nothing is borrowed from another type
or from a textbook.

## Why: the floors, read from core

| | bcc | diamond | sc |
|---|---|---|---|
| 11-09 band (tensor and strut law) | 0.2105 - 0.5929 | 0.1571 - 0.5920 | 0.0866 - 0.4964 |
| its floor as strut / cell | 0.2192 | 0.1861 | 0.2044 |

These are `lattice_rho_min` through `lattice_density_from_strut`, exactly as the type matrix
(`lattice_types_matrix`) computes them.

What the engine lays:

- **The widest strut** is the open look, 0.1898 (`lattice_width_bounds`; wider only with the quilt).
- **The thinnest strut** is two lines (`kMinStrutLines`) of 0.45 mm (`bead_mm`), so 0.90 mm.
- **The largest cell** is 8 mm by default (`CellSpec::cell_max_mm`), so the thinnest strut is 0.90 / 8 = **0.1125** of
  the cell. SC's Auto cap is 10 mm (0.090).

So BCC's and SC's bands started past the open look, and Diamond's 2 % under it.

**The new floors** are 0.079 / 0.088 / 0.085 (strut/cell):

- that is two 0.45 mm lines on an 11.3 / 10.2 / 10.6 mm cell;
- or two 0.40 mm lines on a 10.1 / 9.1 / 9.4 mm cell.

## What was measured (and what core now carries)

**1. Tensor rows** (`tensor/`). The probe and the rule are octet's own LOW/HIGH blocks (ruling 2026-11-02 (c)):
`tensor_library_nine_probe sweep`.

- **Blocks.** Each block's rows are checked against its own finer reference curve:
  - `low`: vpc 80 against 120;
  - `high`: vpc 64 against 96;
  - `floor`: vpc 96 against 144 (Diamond and SC only).
- **A row lands when all of these hold:**
  - |drift| < 2.4 % at its own rho;
  - at least 6 voxels across the strut;
  - CG converged;
  - inside its reference curve;
  - under the old floor.
- **Rows left out.** Rows that failed the rule are left out, as octet's 0.18522 was: bcc 1 (vpc 64's 0.10736,
  +4.7 %), diamond 4 (0.02948, 0.03188, 0.05162, and vpc 64's 0.10718), sc 2 (0.01364 and 0.02083, outside their
  curve). `assemble.py` lists every row with its verdict and prints the C++ rows.
- **Rows replaced.** The new rows replace the old unresolved vpc48 rows that sat under the floors.

| type | new rows (rho) | new band |
|---|---|---|
| bcc | 0.03194 0.04188 0.05172 0.06128 0.07703 0.09241 0.10750 (vpc 80) 0.13483 0.15259 0.19141 (vpc 64) | 0.03194 - 0.59288 |
| diamond | 0.03874 (vpc 96) 0.04181 0.06119 0.07694 0.09231 0.10737 (vpc 80) 0.13464 0.15234 (vpc 64) | 0.03874 - 0.59201 |
| sc | 0.01606 (vpc 96) 0.01945 0.02630 0.02962 0.03295 0.03798 (vpc 80) 0.03516 0.04541 0.05045 0.05807 0.06293 (vpc 64) | 0.01606 - 0.49638 |

Worst |drift| of a landed row: bcc 2.32 % (its floor row, 6.5 vox), diamond 1.56 %, sc 0.56 %.

A thin strut's voxel distance spectrum has gaps, so two targets can land on the same solid (SC 0.014, 0.016 and 0.019
at vpc 80). This is why a finer floor block was run for Diamond and SC.

**2. Diameter law under 0.05** (`diameter/`). The density-to-diameter tables started at rho 0.05 and clamp below
their first row. Rows 0.015 to 0.045 were added with the same probe (`lattice_types_probe law`, the converged solid
fraction of the canonical cell). Without them, every reader of the diameter at a new low density would read the
0.05 strut.

**3. Strut laws** (`<type>/`, `run_laws.sh`). These use `lattice_dehomog_probe` and the 11-09 recipe:

- selfcheck S1 to S6: all pass on the new bands;
- K_dev exact, K_vol, and the interlayer pair;
- the envelope of the bulk with the free-surface and cut-cell populations;
- the aliasing guard and its automatic re-measure ladder;
- `kfit.csv`'s `*_cert` columns are what `strut_strength.cpp` carries, verbatim, under the 11-09 rows, which are
  unchanged. `test_lattice_type_strut_law` pins both files.

Four probe options were added, all off by default, so the 11-09 run is unchanged:

- `TOPOPT_DEHOMOG_RHOS`: the new rows only;
- `TOPOPT_DEHOMOG_MIN_VOX=6`: the law row has at least 6 voxels across the strut (PR 198);
- `TOPOPT_DEHOMOG_BND_MIN_VOX=4`: the boundary fixtures start on the first ladder rung with at least 4 voxels across.
  At the 11-09 starting rung, N3 vpc24, these struts would be 2-3 voxels;
- `TOPOPT_DEHOMOG_LADDER_TOP=64`: the ladder carries on past vpc40.

Two rows needed the ladder:

- Diamond's floor was aliased at N3 vpc48 (-21 %) and re-measured at vpc56.
- SC's 0.05 cut block was aliased at vpc32 (-15.5 %) and re-measured at vpc40.

The `blocks` phase (KUBC N-convergence at 0.20 and 0.45) was not re-run: it measures no new row.

| type | rho | strut/cell | law vpc | vox across (wall_vox) | boundary fixtures | Kd | Kv | Kild | Kilv | bulk Kd, last 16-vpc step |
|---|---|---|---|---|---|---|---|---|---|---|
| bcc | 0.03194 | 0.079 | 80 | 6.4 (7) | N3 vpc56, 4.4 vox | 9894.21 | 141.42 | 5657.57 | 119.94 | 64->80 -10.9 % |
| bcc | 0.05 | 0.100 | 64 | 6.4 (7) | N3 vpc40, 4.0 | 2965.86 | 73.97 | 1867.38 | 73.28 | 48->64 +23.1 % |
| bcc | 0.07 | 0.119 | 64 | 7.6 (8) | N3 vpc40, 4.8 | 1711.55 | 61.34 | 936.40 | 59.40 | 48->64 +42.5 % |
| bcc | 0.10 | 0.145 | 48 | 7.0 (7) | N3 vpc32, 4.7 | 784.50 | 42.25 | 413.55 | 41.04 | 32->48 +50.5 % |
| bcc | 0.157 | 0.186 | 48 | 8.9 (9) | N3 vpc24, 4.5 | 276.19 | 28.12 | 153.04 | 25.32 | 32->48 +10.4 % |
| diamond | 0.03874 | 0.088 | 80 | 7.0 (7) | N3 vpc56, 4.9 (vpc48 aliased) | 2201.79 | 159.85 | 1444.32 | 104.34 | 64->80 +18.7 % |
| diamond | 0.05 | 0.100 | 64 | 6.4 (7) | N3 vpc40, 4.0 | 1014.85 | 96.65 | 586.03 | 66.57 | 48->64 +19.2 % |
| diamond | 0.07 | 0.119 | 64 | 7.6 (8) | N3 vpc40, 4.8 | 569.49 | 76.73 | 356.84 | 59.29 | 48->64 +13.4 % |
| diamond | 0.10 | 0.145 | 48 | 7.0 (7) | N3 vpc32, 4.7 | 280.40 | 50.89 | 170.53 | 40.80 | 32->48 +54.2 % |
| diamond | 0.125 | 0.164 | 48 | 7.8 (8) | N3 vpc32, 5.2 | 197.05 | 48.74 | 122.26 | 29.87 | 32->48 -4.7 % |
| sc | 0.01606 | 0.085 | 80 | 6.8 (3) | N3 vpc48, 4.1 | 23636.02 | 241.72 | 4755.03 | 277.51 | 64->80 -17.7 % |
| sc | 0.025 | 0.107 | 64 | 6.8 (3) | N3 vpc40, 4.3 | 8637.75 | 152.39 | 3273.99 | 181.38 | 48->64 -24.7 % |
| sc | 0.035 | 0.127 | 48 | 6.1 (3) | N3 vpc32, 4.1 | 4397.54 | 107.02 | 1335.24 | 119.70 | 32->48 +23.1 % |
| sc | 0.05 | 0.153 | 48 | 7.3 (3) | N3 vpc32 / cut vpc40 | 2067.52 | 84.15 | 939.29 | 87.73 | 32->48 +49.1 % |
| sc | 0.065 | 0.175 | 48 | 8.4 (3) | N3 vpc24, 4.2 | 1077.49 | 57.14 | 456.94 | 59.62 | 32->48 +1.3 % |

How to read the table:

- **"vox across"** is the strut's diameter in voxels, 2 r vpc. The bracket is the probe's `wall_vox`, a median solid
  run along x. SC's struts lie on the cell edges and are split by the periodic boundary, so its `wall_vox` reads
  about half the true width.
- **Kd and Kild** come from the boundary population at every new row. The one exception is SC 0.065's Kild, which comes
  from the bulk. `summary.csv` has every source.

Each table falls monotonically into its 11-09 floor row:

- bcc: 276.19 at 0.157, then 124.90 at 0.2105;
- diamond: 197.05, then 108.33;
- sc: 1077.49, then 593.33.

## Caveats

1. **Lower bounds, still rising** (11-09's caveat, carried). These are voxelised joint peaks. Over the last 16-voxel
   step, bulk Kd moved -25 % to +54 %. At three floor-side rows the finest pitch read lower than the one before:
   - bcc 0.032: -11 %;
   - sc 0.016: -18 %;
   - sc 0.025: -25 %.

   The 11-09 rule reads the finest pitch, so those rows take the lower number. In each of them the boundary envelope,
   not the bulk, sets every column but sc 0.065's Kild. The parked ruling 11-09 (1) growth rule (0f66f76c, on the
   local branch lattice-growth-PARKED) is not on claude/organic-1 and is not applied here either.
2. **Each type's cells-per-member floor**: bcc 10, diamond 10, sc 4. The finite blocks are 3 cells across. A member
   under its floor is not certified from the law, and the receipt says so. All three cube cases below read "0.2 cells
   across, below the 10 (sc: 4)".
3. **The layer factor z_knockdown is unsourced**: 0.55, from materials.json, unchanged.
4. **New: the cut-layer population is the grip population** (`gripcheck.py`). The probe classifies the cut layer
   before the grip. So the cut layer's two end cells sit against the gripped x faces, and its envelope reads the
   grip's.
   - In every 11-09 row of these three types, and in every new row, the cut layer's exact K_dev equals the grip's to
     within 11 %.
   - At the 11-09 densities that was 1.1 to 2.3x the free surface.
   - At the new densities it is 1.7 to 5.5x, the largest at the floors (bcc 0.032: 9894 against 1786; sc 0.016:
     23636 against 4344).
   - It sets every new Kd_cert, so the new rows are conservative by that much.

   The method was not changed: it is the 11-09 one. Whether a cut layer away from the grips should be its own
   population is a ruling.
5. **Not re-measured at the new floors**:
   - the percolation floor (0.75 cells, measured at the 11-09 band floors);
   - the bending floor (cells per member), measured at one density.

## What else moves with the band (core reads `lattice_rho_min` in many places)

The band floor is one number, and every reader of it moves with the measurement. None of these was changed by hand.

| What | Before | After |
|---|---|---|
| The new engine's credit (`lattice_credit`, V4) and the strength check's density gate | no strut it lays without the quilt in band (bcc, sc); diamond only at 0.186-0.190 | every strut down to strut/cell 0.079 / 0.088 / 0.085; `structural_note` clears itself |
| **Finding 6** (`lattice_type_aesthetic`: Structural only when the R11 ceiling lies under the band) | BCC and SC Structural only | **BCC and SC offered in Aesthetic too**: the rule's premise ("its thinnest certifiable strut is wider than a fifth of the cell") no longer holds. `test_lattice_types` now reads the rule from core. |
| **The old engine's LIGHT cell floor** (`lattice_cell_printability_floor_mm` = line / strut-per-cell at the band floor: the old Lattice page's slider start and the cell a graded run is raised to), at a 0.45 mm line | bcc 2.05, diamond 2.42, sc 2.20 mm | **bcc 5.66, diamond 5.12, sc 5.32 mm** |
| The old engine's graded density (variants) | from the 11-09 floor | from the new floor |
| `docs/strength-check/variables.json` (`rho_min`, `strut_law_span`) and `cell-types.md` | the 11-09 floors | the new ones (the app's bundled copy too) |

For the light cell floor, the cell must be coarser so that the thinnest strut in band still prints. This is how octet's
own floor moved with ruling 2026-11-02 (c), from 4.93 to 7.03 mm.

## Cross-check against the published laws (only a cross-check: no row comes from them)

`crosscheck.py` and `crosscheck.log`. The sources:

- Gibson & Ashby, *Cellular Solids*, 2nd ed., CUP 1997, doi:10.1017/CBO9781139878326;
- Ashby, *Phil. Trans. R. Soc. A* 364 (2006) 15-30, doi:10.1098/rsta.2005.1678;
- Lumpe & Stankovic, *PNAS* 118 (2021) e2003504118, doi:10.1073/pnas.2003504118.

**Stiffness.** Each type scales as its class, with E100 from the new tensor rows:

| type | class | log-log slope | ratio to the published law | trend |
|---|---|---|---|---|
| bcc | bending (expect 2) | 2.38 | 0.13 to 0.25x Gibson-Ashby's rho^2 | the textbook law overestimates it 4-8x |
| diamond | bending (expect 2) | 2.13 | 0.47 to 0.56x | |
| sc | stretch along its bars (expect 1) | 1.06 | 1.08 to 1.18x Ashby's rho/3 | the bars hold a little more than a third of the solid: node overlap |

Lumpe & Stankovic class BCC and Diamond as bending-dominated and SC as stretch-dominated along its bars, and the
measured slopes agree.

**Strength.** The law certifies a uniaxial stress in any direction of 1 / (Kd + Kv/3) of yield. That is first yield at
the hottest voxel, in the worst direction, so it sits below a plastic-collapse law:

| type | against | the new rows | the 11-09 rows | trend |
|---|---|---|---|---|
| bcc | Gibson-Ashby 0.3 rho^1.5 | 0.06 to 0.19x | 0.26 to 0.49x | |
| diamond | Gibson-Ashby 0.3 rho^1.5 | 0.19 to 0.35x | 0.45 to 0.59x | |
| sc | Ashby's axial 0.3 rho | 0.009 to 0.047x | 0.06 to 0.28x | falls with rho |

SC's comparison is not like for like. Its worst direction is shear, carried by bending, which the axial law does not
see.

## Before and after (`margins/`, `matrix/`)

`margins.cpp` runs the type matrix's own job:

- the new engine's file job with the CLI strength check;
- two 0.45 mm lines, held on the bottom and loaded 20 N;
- resolution 40.

It runs on core's cube (`core/tests/fixtures/step/cube.step`) and on the filleted bore plate
(`core/tests/fixtures/mesh/filleted_bore_plate.stl`). The before run uses claude/organic-1 f82ac0b8 with this
branch's probe commit and no law changes.

| case | type | before: cells credited, strut margin | after: cells credited, strut margin |
|---|---|---|---|
| cube, a typed 5 mm cell, whole part (strut/cell 0.184) | bcc | 0 of 8, no number | 8 of 8, 0.0787 |
| | diamond | 0 of 8, no number | 8 of 8, 0.2557 |
| | sc | 0 of 8, no number | 8 of 8, 0.0175 |
| | (octet) | 8 of 8, 1.2483 | 8 of 8, 1.2483 |
| plate, a typed 6 mm cell, whole part (strut/cell 0.168) | bcc | 0 of 48, no number (part 53.54) | 28 of 48, 9.10 (part 53.41) |
| | diamond | 0 of 48, no number (part 53.54) | 28 of 48, 31.55 (part 53.44) |
| | sc | 0 of 48, no number (part 53.54) | 28 of 48, 10.83 (part 53.52) |
| | (octet) | 28 of 48, 56.55 | 28 of 48, 56.55 |
| plate, 6 mm, the thinnest strut (dial 1 %, 0.90 mm: strut/cell 0.150) | bcc | 0 of 48, no number | 28 of 48, 7.95 |
| | diamond | 0 of 48, no number | 28 of 48, 32.07 |
| | sc | 0 of 48, no number | 28 of 48, 8.44 |

Notes on the cases:

- **The cube.** No solid carries the load, so its part margin is none, before and after. Its strut margins sit under 1
  at 20 N on struts 0.92 mm thick, and they are out of regime: 2 cells across against a floor of 10 (sc: 4).
- **The plate.** The 20 uncredited cells are cut cells.
- **The rest.** The Auto face region on the cube, and Auto on the plate, credit no cell for any type, the octet
  included: every cell is cut.

`matrix/before.log` is the type matrix before the laws (six XFAIL). `matrix/after_with_d_list.log` is the same test,
builder D's `kExpected` unchanged, after the laws: exactly those six report XPASS, and nothing else fails (149
checks, 6 failed = the six XPASS, 2 known failures). That run was linked before the diameter rows under 0.05 went in.
Those rows change a cell's density only under rho 0.05 (strut/cell 0.100 for bcc and diamond, 0.153 for sc), by
linear reading of the measured rows in place of integration. The six checks' case (strut/cell 0.184) is above that. The six then came off `kExpected` in their
own commit, and `tests/ctest.log` runs the matrix on the final library.

## Tests (`tests/`, on the tree of the kExpected commit)

**ctest** (`ctest.log`, `ctest_LastTest.log`) ran ten suites:

- passed: strut_strength, lattice_strength (44,329 checks), lattice_type_strut_law, lattice_types, strut_diameter_per_type,
  lattice_width_bounds, stepped_plan, grading;
- lattice_types_matrix: 149 checks, 0 failed, the 2 other known failures;
- lattice_certification: failed on a July pin, "diamond rho_min > 0.10". The pin now names the measured floor, and the
  suite passes (`lattice_certification.log`).

**Also run**, each touching bcc, diamond or sc:

- strut_cell, multiscale_material, job_schema, lattice_layout (116,944 checks) and lattice_layout_file (3,897): all pass;
- lattice_material_model: its harness model transcribes the library's rows and failed until they were added, then
  passed.

**The long half of lattice_type_strut_law** (TOPOPT_LONG_TESTS=1, one process per type): the 44 mm bar,
lattice_part, the old engine.

- For each of bcc, diamond and sc: the receipt is written, the type's own law is in the gate, and the margin is finite.
- The margins are 0.0271, 0.1728 and 0.0040; none is accepted.
- The old engine now grades into the new band: "21 / 12 voxels held at the band floor 0.0319 / 0.0387".

## Files

- `tensor/`: `run_tensor.sh`, `run_tensor_floor.sh`, `assemble.py`, `low|high|floor/<type>_sweep.{csv,log}`.
- `diameter/`: `run_diameter.sh`, `<type>_law.{csv,log}`.
- `<type>/`: the probe's CSVs (`kfit.csv` is the law) and a log per phase.
- `run_laws.sh`, `summary.py` -> `summary.csv`, `gripcheck.py`, `crosscheck.py` -> `crosscheck.{csv,log}`.
- `margins/`: `margins.cpp`, `before.csv`, `after.csv`.
- `matrix/`: `before.log`, `after_with_d_list.log`.
- `tests/`: the suites run on the law commit.
- `reproduce.sh` reruns everything.
