# The sheet law on the off-grip envelope (gyroid, Schwarz-D)

notes30, builder S1. The reviewer's ruling of 2026-11-26 01:37Z, item 3 (sheets), as recorded:

> (a) off-grip cut population + sweep cut fraction (>=0.5, 0.6), envelope, monotone rule on the envelope;
> (b) NO Structural sheet credit until (a); Aesthetic may ship; (c) 2-cell floor for the law, but measure
> bending error at 3/4/6 cells (reviewer puts floor-vs-knockdown to him); (d) batch B after (a) only if
> floor still 2; (e) DONE a4fa78c3.

This folder builds on notes28's record, `../2026-11-25-sheet-laws-thin-members` (builder D; its README has
the method, the fixtures and the caveats). Nothing there is re-measured; this folder adds fixtures beside it.

## What "the off-grip cut population" is, in the probe's own terms (written before the runs)

`lattice_dehomog_probe widths` (core/tests/harness/lattice_dehomog_probe.cpp; line numbers at f1a6cfae,
unchanged by the merge of organic-1):

- **The cut fixture** (`solve_finite`, lines 455-468): notes28's block, N cells across in y and z, `lx` =
  max(N, 3) cells long in x, gripped on its two x faces (u = eps x prescribed there), its lateral faces free,
  with a PARTIAL top layer: the block is `lround((N + cut_frac) vpc)` voxels tall, so the top layer holds
  `cut_frac` of a cell, cut where a part's wall would cut the grid.
- **The populations** (`classify`, lines 398-409): a solid voxel's cell is Cut if it lies in that partial
  layer (line 400), else Grip if its x cell is the first or last (line 405), else Free if on a lateral face,
  else Interior. **Line 400 returns Cut before the grip test**, so 11-09's `cut_layer` population holds the
  cut cells in the two grip columns too, and its peak sits there (notes28's finding 2: the corner where a
  gripped face meets the cut face rises with pitch and does not settle, like the grip population the law
  already leaves out).
- **The off-grip cut population** (`cut_off_grip`, lines 1678-1708 of the merged file; notes28 wrote it as
  a diagnostic, "not in the law"): the Cut voxels whose x cell is neither 0 nor lx - 1, i.e. **the cut
  layer's cells away from the test grips**: x columns 1 .. lx-2, every y column, the cells on the free
  lateral faces included. For N = 2 (lx = 3) that is the middle column, 2 cells; for N = 8, 6 x 8 = 48 cells.
  Its K is the same exact K_dev (the 5x5 generalized eigenproblem), K_vol and interlayer pair as every
  population.
- Since this ruling it is **the law's cut population**. The law's populations: the bulk, the free surface
  (every placement) and the off-grip cut population. 11-09's `cut_layer` stays in the CSVs, out of the law;
  the grip population stays out, as on 11-09.

The probe changes for this folder are bookkeeping only: the exact CSV writes `cut_frac` to 4 decimals and a
`cut_layers` column (the partial layer's voxel layers as built). The solve is untouched: the rebuilt probe
reproduces notes28's gyroid 0.313, N 2, vpc 16, cut 0.6 to every printed digit (off-grip 12.5769, free
surface 9.5163, cut layer 19.6305), and tpms_probe reproduces the 11-01 bending record (gyroid 0.40, 2 cells,
+43.56 %).

## The sweep (a), fixed before the runs

**What the sweep is.** "Sweep cut fraction (>= 0.5, 0.6)": every cut the law pitch can build from half a cell
up, i.e. every voxel layer k / vpc for k = vpc/2 .. vpc-1:

- vpc 16 (seven rows): 8 .. 15 layers, 0.5000 .. 0.9375. notes28 has 8 (0.5), 10 (its "0.6") and 12
  (0.75); new: 9, 11, 13, 14, 15.
- vpc 24 (gyroid 0.150, Schwarz-D 0.200): 12 .. 23 layers. notes28 has 12, 14 ("0.6") and 18; new: 13, 15,
  16, 17, 19, 20, 21, 22, 23.
- notes28's 0.25 (4 / 16, 6 / 24) and the sandwich stay in as placements.

**Where.** Every density row of both bands (gyroid 0.150 / 0.200 / 0.313 / 0.450 / 0.601, Schwarz-D 0.200 /
0.313 / 0.450 / 0.600), at notes28's law pitch (vpc 16; vpc 24 for the two thin rows).

- **Screen:** every new layer at N = 2, 3, 4 (`jobs_1_screen.txt`, 31 jobs).
- **Wide:** N = 5, 6, 8 at the screen's worst new layers per row: the two with the highest off-grip Kd at
  N = 4 (ties: N = 3) at the vpc 16 rows, the one at the vpc 24 rows (`make_jobs.py wide` writes
  `jobs_2_wide.txt` and `wide_selection.txt` from the screen's own CSVs). The full sweep at every width
  would be about 66 process-hours (the vpc 24 8-cell blocks are 1.6-1.9 h each); this is about 16. Its
  premise, that the worst cut layer of a row does not change with the width, is what notes28's four cuts
  show at 8 of 9 rows (at Schwarz-D 0.200 the cuts are within 5 % of each other); the wide runs check it.

**The envelope and the rule** (`envelope.py`), each coefficient (Kd, Kv, Kild, Kilv) on its own, per row:

- env(N) = the max over the bulk and every law-population point of width N at its law pitch, across the
  whole sweep: the weakest result per case.
- law(N) = max(today's row, max over N' >= N of env(N')): a narrower member is never credited more than a
  wider one, nor more than any sweep point at its width or wider; never under today's law (from 10 / 9
  cells), which is the same rule read at the widest member.
- The law pitch is notes28's: per fixture the coarsest pitch the aliasing guard keeps.

**(a) passes** (`kenv_checks.csv`, per type) when every one holds: every listed sweep fixture is kept at
its law pitch; every width of every row has 0.5 and 0.6; the law is monotone; it is at least every sweep
point at its width or wider; it is never under today's row. Core carries the verdict
(`sheet_envelope_law_passes`), and `test_sheet_width_law` checks the rule against every point, with RED
controls.

## (b) Structural sheet credit stays off

`sheet_credit_law_at` (core/include/topopt/sheet_width_law.hpp) is the only door to a Structural sheet's
law. It gives no law, at any width, until BOTH keys turn: the envelope law passes (generated), and
`kSheetStructuralCreditReviewed` (false: the reviewer opens it after reading this folder). Aesthetic sheets
make no strength claim and are not touched.

## (c) Bending at 3, 4 and 6 cells

The vpc 24 record (notes28, 2-8 cells, three densities) is tabulated in `bending_346.txt`; `jobs_3_bend.txt`
measures 2, 3, 4 and 6 cells again at a finer pitch (vpc 36 at the band floor, whose wall is 1.13 / 1.26
voxels at vpc 24; vpc 32 at 0.40 and the ceiling), so the table says whether the numbers are the voxels'.

## (d) Batch B

Only if the floor is still 2 after (a): notes28's five criteria, applied unchanged with every sweep placement
as a placement (`steady_env.py`). `jobs_4_B.txt` is notes28's batch B less what already ran.

## Cost, before the runs (from notes28's logs)

- Screen 4.2 process-hours (largest block 0.4 GB); wide 11.6 (the vpc 24 8-cell blocks about 2.8 GB, 1.6-1.9
  h each; vpc 16 8-cell blocks about 1 GB, 15-28 min); bending about 3 h of 2-thread jobs (about 2.4-3.4 GB
  at 6 cells). About 3.5 h wall at 6 side by side, as memory allows.
- Batch B about 21 process-hours (2 cells at vpc 48, 1.2-1.5 GB each): about 3.5 h wall.
- Every job starts behind a memory gate (its estimated peak plus 3 GB must fit in what macOS reports free).
