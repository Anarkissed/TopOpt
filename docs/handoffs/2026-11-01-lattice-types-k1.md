# Handoff — 2026-11-01-lattice-types-k1: the strut and sheet generators, one type at a time (TRACK core)

Branch `claude/lattice-types-k1`, from `origin/claude/flexible-screens` at `da6cbd9f` (K0's
`0a5f86df` is in it). Plan: `docs/design/lattice-types/`. Previous core handoff:
`docs/handoffs/2026-09-28-lattice-types-core.md` (K0). Evidence:
`docs/handoffs/evidence/2026-11-01-lattice-types-k1/`.

## Where this stands, in plain language

**Live: FCC, Kelvin, Rhombic dodecahedron, Diamond, BCC, Simple cubic**: every strut type of K1
(rhombic without Doubled cells: measured, its struts do not meet across a halving). Two rulings are
asked of the maintainer (Findings 6 and 7); either could send BCC or SC back.

**Live (K2, the sheets): Gyroid, Schwarz-D**, with one cell size for the whole part (Doubled and
Stepped refused, R5) and a Rim or no skin (Diagrid refused, R8). A 4 mm sheet needs members
36-40 mm across and costs 15-19 times octet's triangles a cell (Findings 8 and 9). Not
print-tested.

Parked: none.

<!-- STATUS -->

## What changed in core, once, for every strut type (and, 9-10, for the sheets)

1. **One canonical cell per type** (`topopt/strut_cell.hpp`). Octet, SC, BCC, FCC, Diamond,
   Kelvin, Rhombic as `(S, struts, nodes)` on an integer grid. `test_strut_cell` compiles the
   tensor probe's own source (`tensor_library_nine_probe.cpp`, its `main` renamed) and asserts the
   production table equals its `make_lattice()` element for element, and that the production
   voxeliser reproduces the probe's `build_cell` voxel for voxel. So the certified cell and the
   generated cell are one cell (go-live item 1), by test.
2. **The generator builds any of them through octet's machinery** (`lattice_gen.cpp`). Octet keeps
   its hand-written PR 201 tables; every other type gets a generic table from its canonical cell:
   every strut and node inside the closed cell, ownership by the cell holding the midpoint, else
   the lexicographically smallest ACTIVE cell sharing it (octet's node rule, applied to struts).
   Clipping, Rim, Diagrid (plain and freeform), the outline, streaming, determinism, Doubled and
   Stepped are the same code. Node balls are decided among the cells that hold one of the node's
   struts — diamond's cell corners are reached by no strut of the cell they cap, and without this
   a holed region emits floating balls (found by `test_strut_cell`'s first run).
3. **The run path reads the job's type** (`run_job.cpp`, `job.cpp`, `lattice_density_field.cpp`):
   the six generator calls, the certification posture, the three grading-law topologies, the
   receipts' cell reports, the uniform-lattice band, the Fit pre-flight, multiscale. K0 listed 24
   `Octet`s in `run_job.cpp`; none remain. Three new parse-time refusals, each naming its reason:
   organic with a non-octet type (it builds no cell), a region density outside the TYPE's band,
   Doubled/Stepped for a type whose R4 verdict is not PASS.
4. **Each type's own numbers in one place** (`lattice.cpp`, `type_measured`): the diameter table,
   the bending / percolation / aesthetic floors and the bending error curve, each beside the run
   that produced it. `lattice_strut_diameter_mm`, `lattice_density_from_strut`,
   `lattice_aesthetic_density_ceiling`, the floors and the adaptive aesthetic floor read it.
   `lattice_type_numbers_measured(topo)` says whether a type has them.
5. **The facts struct for the app** (`topopt/lattice_types.hpp`), **the print-tests loader**
   (`topopt/lattice_print_tests.hpp`, K4) and **the sample block** (`topopt-cli lattice-sample`,
   `topopt/lattice_sample.hpp`). See the BRIDGE CONTRACT below.
6. **The measurement harness** `core/tests/harness/lattice_types_probe.cpp` (`law`, `bend`,
   `perc`, `step`): every per-type number in this round comes out of it.
7. **The R3 note is on every receipt that names SC or BCC** (`lattice_type_directional_note`,
   one source; the facts read it too). run_info's `lattice`, `lattice_export`, `grading` and
   `multiscale` blocks, the per-variant lattice receipt and its two forecasts, and the sample
   block's receipt add `"directional_note"` right after the topology. Every other type writes no
   key, so octet's receipts are byte-identical (02-core-spec §2.5).
8. **Diagrid's link radius follows each type's own geometry** (`crossing_node_gap`,
   `diagrid_skin_connectivity.txt`). Near a plane of nodes a face's landings bunch around the
   nodes that send a strut across it, and octet's 0.72-cell radius is 1.8 % over octet's gap
   between those nodes (0.7071 cell). FCC's, BCC's and SC's are a full cell apart, so on a face
   just off a node plane their skins broke into 9-25 islands (FCC from 0.75 cell, BCC at
   0.20-0.45 and 0.70-0.95, SC everywhere). The radius now scales by gap / 0.7071 when the gap is
   larger (sqrt 2 for those three). Octet, Kelvin, Rhombic and Diamond have octet's gap and are
   byte-identical (hashed against Diamond's gate build); FCC's skin changes, and it is live, so
   this is a change to a pushed type: the gate on SC's commit covers it. `test_lattice_types`
   holds every live type to one skin piece on such a face (RED without the scaling: FCC 12
   pieces, BCC 16).

9. **The sheets (K2): Gyroid and Schwarz-D** (02-core-spec §3), from the K2 work merged in
   at `13ef314c`, live at `ccf0e03b`:
   - `LatticeTopology` gains `Gyroid` and `SchwarzD`; the planned-ids list is gone.
   - **Rows re-measured on the production wall** (`topopt/tpms.hpp`, the gradient-normalised
     band |f|/|grad f| <= t/2, R7), by the strut rows' periodic homogenisation
     (`tpms_probe rows`): VALID rows only, each resolution-checked against a finer grid
     (vpc96 against vpc128 up to rho 0.35, vpc48 against vpc64 from 0.40; every drift under
     2.4 %), the first unresolved row kept as `resolved = false`. Bands: gyroid
     0.15010-0.60069, Schwarz-D 0.20038-0.60012 (`<sheet>_rows_vpc{48,96}.*`).
   - **The wall law** (`<sheet>_wall_law.*`): the field parameter t bisected on the converged
     solid fraction, and the TRUE normal wall measured on 4,000 points of the sheet (uniform
     to 1-3 % over the sheet; it runs below t as the wall thickens, -16 % at rho 0.60). The
     true wall is the sheet's "diameter" everywhere core reads one: printability
     (wall >= bead, R6) reads it unchanged, and `lattice_sheet_wall_param_mm` turns it into
     the field's parameter for the generator.
   - **The generator** `generate_tpms` (`tpms_gen.hpp`): dual contouring of the field's
     distance estimate (`lattice_dc.hpp`), clipped by the same boundary the struts use (eroded
     by one DC cell, as the strut clip erodes by the radius), streamed, deterministic. DC cell
     = a third of the thinnest wall laid (-0.4 % volume against the exact solid fraction).
     The run's export lays it for a sheet job; Rim is the strut generator's rim pass alone.
   - **At the parse** (R5, R8): Doubled, Stepped, swept, fit and stepped cells are refused for
     a sheet with the R5 reason; Diagrid, stated or the default, with the R8 reason (a sheet
     job states `"skin": "rim"` or `"none"`); organic as for every non-octet type. One cell and
     one grid for the whole part, so two sheet regions that touch always share cell size and
     phase.
   - **The harness** `core/tests/harness/tpms_probe.cpp`: `law`, `rows`, `perc`, `bend`, `tris`,
     and `mesh` (go-live item 7 on an emitted sheet: its pieces, and which touch or sit inside
     the solid body the run writes beside it).
   - **Each sheet's numbers** in `type_measured` (bending 10 / 9, percolation 0.5, aesthetic
     2), facts with `family: "sheet"` and the measured triangle cost, and the sample block.
10. **The C2b bend can run matrix-free** (`TOPOPT_BEND_MATFREE=1`, `07ffbfda`): the sheets'
    floors lie at 9-10 cells, where the resolved block is ~20-25M dof and its assembled K
    peaked at a 39.5 GB footprint and was killed on a 16 GB machine. `fea_solve_cg_matfree`
    solves the same reduced system to the same criterion; it reproduced both sheets' 3-cell
    runs to every printed digit (643.4300, 745.4677). Unset, the probe is unchanged.

## Findings that reach past this round (measured; nothing about them is changed here)

1. **The density law is measured on the CONVERGED solid fraction, not on vpc48 voxels.**
   On a lattice-aligned voxel grid the solid fraction of a strut cell is a staircase in r,
   and it does not shrink smoothly with resolution (`law_resolution.txt`): rhombic at
   r/L 0.045 reads 0.059 at vpc48 and 0.0785 at vpc256 (-24 %); FCC at r/L 0.0667 reads
   0.0951 against 0.1026. So octet's B3 method (bisect r on the vpc48 voxels) sizes a strut
   to wherever a step falls. The tensor rows are resolution-checked AS A FUNCTION OF
   DENSITY (vpc48 vs vpc64 at matched rho), so the strut that realises a density is the
   one whose true solid fraction is that density. Each type's table is therefore bisected
   on `strut_cell_solid_fraction` (2^20 Halton points, deterministic, converged to ~0.2 %
   against 2^22), and the B3 table is reported beside it. Within the band the two differ by
   at most: FCC 2.7 %, Kelvin 3.9 %, rhombic 5.0 %, diamond 4.9 %, BCC 4.9 %, SC 4.0 %
   (`<type>_law.txt`, column "B3 gap"). **Octet's shipped table is the B3 table and is
   unchanged (R9).** FCC's B3 table equals it to four digits, which confirms octet's law
   was measured on the legs-only cell.
2. **The printed struts are lighter than the certified ones, for every type including
   octet.** The generator emits an 8-gon prism with circumradius r (area 2*sqrt(2)/pi =
   0.900 of the circle) and an icosahedral node of circumradius r; the tensor rows were
   measured on round capsules of radius r. At the same r the production solid is 6-10 %
   lighter (`<type>_law.txt`, column "as-built gap"; e.g. FCC -9.4 % at rho 0.05, -6.9 % at
   0.60). For a stretch-dominated strut that is roughly the same fraction less stiffness
   than certified. It is a property of PR 201's emitter, shared by octet, and changing it
   would move octet's bytes and the app's preview, so it is reported, not touched. A
   prism fix exists (scale the 8-gon to equal area: r x 1.0539) if the maintainer wants
   it, as its own change with its own R9 break.
3. **Q2, octet's legs-only tensor** (`octet_legs_only_report.txt`, measure only): the full
   octet is SOFTER along the cell axes than the legs-only tensor says (E100 -10.6 / -13.6 /
   -18.2 % at rho 0.25 / 0.35 / 0.45) and STIFFER along the diagonal and in shear (E111
   +13 to +16 %, C44 +15 to +19 %). So the shipped certificate over-states octet's axial
   stiffness by 12-22 % and under-states its diagonal and shear stiffness. The maintainer
   rules; nothing changed.
4. **The bending floor is far above 5 for the bending-dominated types**, as
   tensor-library-nine's T4 predicted: at 6 cells across Kelvin is still +4.6 %, rhombic
   +5.5 %, diamond +7.1 %, BCC +5.8 % (PR 235's C2b cantilever, vpc12, the same method as
   octet's). FCC crosses between 4 and 5 (5, octet's own number), SC between 3 and 4.
5. **Analyze mode records no recertified margin under aesthetic intent**, for octet too
   (byte-identical to the reference binary): `run_info.grading` has `recertified_*` only
   under structural. The `run` and `lattice-variant` paths certify the composite in both
   modes. Pre-existing; noted because "the certificate runs in both modes" is only true on
   those paths.
6. **BCC's and SC's R11 aesthetic ceiling lies BELOW their certifiable band** (BCC 0.1791 vs
   0.2105; SC 0.0831 vs 0.0866). R11 is octet's rule per type: a strut no wider than a fifth of
   its cell. The thinnest strut either type certifies is already wider than that (BCC 0.219,
   SC 0.204 of the cell), so by R11 no certifiable BCC or SC "prints open". Core's runs do not
   read the ceiling; the app's Aesthetic cap does, and min(band top, ceiling) is below the band
   bottom for these two. The bridge contract says what the app should do; whether R11 should
   read differently for 3- and 8-strut cells is the maintainer's ruling.
7. **A graded run lattices ONE cell per masked solve voxel when the cell is smaller than the
   voxel**, octet included (`bcc_stand_percolation.txt`, measured on the M2 stand). `cell_latticed`
   (`run_job.cpp`) activates a cell iff it holds a masked voxel's CENTRE. The stand solves on
   3.41 mm voxels and the swept ladder picks 2 mm cells, so each masked voxel activates exactly one
   cell: the receipts say latticed cells = latticed voxels (92 = 92 on BCC's rung 0.52, 112 = 112 on
   octet's rung 0.38), and about 80 % of every pocket voxel is left empty. Two consequences. (a) The
   certificate (the posture) reads every masked voxel at its graded density over the whole voxel, so
   in those voxels the exported lattice holds about a fifth of the material it counts. (b) In a pocket
   one voxel thick the lone cells reach no wall and float: BCC's rung 0.52 has 12 such pieces, octet's
   own stand run 2 in the same place, and SC's rung 0.38 has 3 there (its receipt says 154 = 154;
   two of them have exactly the bounding boxes of octet's two; `sc_stand_percolation.txt`). FCC's run left two lone cells in that pocket too; they count as
   held only because its solid companion comes within 0.05 mm of a node. Kelvin's, Rhombic's and
   Diamond's runs latticed nothing there. The generators emit exactly the cells they are given. A fix belongs in
   the activation (every cell that overlaps a masked voxel, or a cell never finer than the solve
   voxel) and moves octet's bytes (R9), so nothing is changed here: the maintainer rules.


8. **A sheet costs an order of magnitude more triangles than a strut lattice.** On the stand's rung 0.52, on one fixed 4 mm cell, Gyroid laid 33 cells in 527,072
   triangles and Schwarz-D 33 in 634,768, where octet laid 78 in 80,316: 15,972 and 19,235
   triangles a cell against octet's 1,030 (15.5x and 18.7x; `gyroid_stand_certificate.txt`).
   The cost is the wall resolution: a DC cell a third of the thinnest wall, and per interior
   cell 19.44 (gyroid) / 24.00 (Schwarz-D) x (cell / DC cell)^2 triangles
   (`sheet_triangle_cost.txt`). The sample blocks are 1.39M and 2.32M triangles (69 and 116 MB
   STL; not committed, their receipts are). The app's budget reads `sheet_triangles_coeff`.
9. **Fine sheet cells do not print.** With the 0.42 mm bead a gyroid wall reaches one bead
   only from rho 0.42 at a 3 mm cell and 0.32 at 4 mm, and no density in the band does below
   2.03 mm (4.84 beads); Schwarz-D needs 0.51 / 0.39 and 2.52 mm (6.01 beads)
   (`sheet_printability.txt`, which core's own inverse reproduces). So the fixed-cell runs
   raise the density to suit (the stand's 4 mm gyroid runs start at 0.319, the 1-bead density),
   and with the bending floors of 10 / 9 cells a 4 mm sheet needs members 36-40 mm across.
   Justino Netto 2024 saw holes at overhangs with 1-bead PLA gyroid walls (R6, Q3): the print
   test decides whether the floor should be two beads.

## FCC — LIVE

Go-live checklist (02-core-spec §4), each with its evidence in
`docs/handoffs/evidence/2026-11-01-lattice-types-k1/`:

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell`: FCC's table equals `tensor_library_nine_probe.cpp`'s `make_lattice("fcc")` element for element (S 2, 12 struts, 4 nodes, phase 0); the production voxeliser reproduces the probe's `build_cell` exactly |
| 2 | Generates on a block and on the M2 stand; octet byte-identical; deterministic | PASS | `test_lattice_types` (ownership on a holed region, two runs same bytes, clipped + Diagrid run same bytes); the M2 stand `run` at res 64 laid and certified FCC on all four rungs (`lattice_margin` 1782 / 1717 / 1678 / 1640, accepted); octet: `r9_octet_fcc_commit.txt` (below) |
| 3 | Own density law, diameter table, printability floor | PASS | `fcc_law.{csv,txt}` (converged solid fraction; B3 beside it); `lattice_cell_printability_floor_mm` / `lattice_min_density_for_strut` read it (no octet table is read: `test_strut_diameter_per_type` 3b) |
| 4 | Own bending, percolation and aesthetic floors, with conditions | PASS | bending **5** (`fcc_bend.txt`: +54.0 / +8.9 / +4.2 / +2.6 / **+1.8** / +1.3 % at 1-6 cells; C2b cantilever, S 5 mm, vpc12, 6 cells long, cell rho 0.1991); percolation **0.75** (`fcc_perc.txt`: spanning at every placement 0 / .25 / .5 / .75 and rho 0.095 / 0.343 / 0.591 from 0.75 cells; 0.5 fails at the .25 placement); aesthetic hard floor **2** (+8.9 % and percolates; no finish relaxation, since octet's skinned 1-cell measurement is octet's) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `fcc_step.txt`: S\|S/2 block 1 component, 0 dangling of 2,208 ends; S\|2S/3 interface 1 component, 0 of 1,152; octet control `octet_step.txt` the same |
| 6 | Certificate end to end, both modes; receipts name the type | PASS | M2 stand `run` Structural (4 rungs) and Aesthetic (2 rungs latticed: margins 1678 / 1639), every receipt `"topology": "fcc"` (`run_info.grading`, `.lattice`, `.lattice_export`, each `*_lattice.report.json`); the analyze path too (`fcc_stand_certificate.txt`: FCC's band 0.095-0.591 and floors read, recertified margin 66.19 against octet's 239.65 on the same job) |
| 7 | Percolation on the emitted mesh | PASS | 3x3x3 block, Doubled block and Stepped interface each one solid (`test_lattice_types`); on the M2 stand (`stand_percolation.txt`, `lattice-variant` of the FCC run's own design, rung 0.38): 48 pockets, **0 floating** (every piece reaches a cut, the solid companion or the shell); octet control on the same rung: 82 pockets, 2 the same test cannot place |
| 8 | Bridge-facing functions in the contract | PASS | BRIDGE CONTRACT below; `lattice_type_facts("fcc")` asserted field by field |

Numbers FCC now carries (all its own): band 0.09505-0.59093 (PR 246's rows, unchanged);
cells per member 5; percolation 0.75; aesthetic floor 2; aesthetic ceiling 0.2126 (strut =
20 % of the cell through FCC's law; octet's is 0.2189); smallest printable cell 2.620 x the bead at the band top;
464 triangles per cell; strut strength not measured (R10, refused in words). Print status:
not print-tested.

**FCC changed after it went live**: its Diagrid skin (`9118402c`, What changed item 8). On a face
just off a node plane (from 0.75 cell) the skin broke into islands (12 pieces in
`test_lattice_types`'s case); it is now one piece. The change is in the Diagrid link radius only,
so no-skin and Rim output are unchanged.
SC's gate, on the commit that carries the change, covers it (`ctest_sc.txt`, octet identical).

**Print it** (40 mm cube, 8 mm cells, band-middle density 0.343, 2.13 mm struts, 1.5 mm plate,
70,932 triangles; deterministic, `fcc_sample_40mm.stl` beside this handoff's evidence):

```bash
core/build/topopt-cli lattice-sample --topology fcc --out fcc_sample.stl
```

## Kelvin — LIVE

The same harness, conditions and checks as FCC; evidence `kelvin_*` beside FCC's.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 24 struts, 12 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand `run` laid and certified Kelvin on all four Structural rungs (12-16 cells each: the 8-cell floor keeps cells coarse) and three Aesthetic ones (`kelvin_stand_certificate.txt`); octet `r9_octet_kelvin_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` (the job builder writes the model path absolute) |
| 3 | Own law, diameter table, printability floor | PASS | `kelvin_law.{csv,txt}` (B3 within 3.9 %) |
| 4 | Own floors, with conditions | PASS | bending **8** (`kelvin_bend*.txt`: +62.3 / +32.9 / +18.1 / +11.0 / +7.1 / +4.6 / +3.0 / **+1.9** % at 1-8 cells, C2b vpc12, cell rho 0.1944); percolation **0.75**; aesthetic hard floor **2** (+32.9 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `kelvin_step.txt`: S\|S/2 1 component, 0 dangling of 3,936 ends; S\|2S/3 1 component, 0 of 1,992 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"kelvin"`; analyze Structural recertified margin 99.66, accepted, on Kelvin's band 0.094-0.505 and floor 8 |
| 7 | Percolation on the emitted mesh | PASS | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 14 pockets, **0 floating** (`kelvin_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("kelvin")` |

Numbers: band 0.09375-0.50521; cells per member 8; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.2065; smallest printable cell 2.793 x the bead; 1,008 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.300, 2.00 mm struts, 1.5 mm plate, 141,612 triangles;
`kelvin_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology kelvin --out kelvin_sample.stl
```

## Rhombic dodecahedron — LIVE (Doubled refused, measured; Stepped allowed)

The same harness, conditions and checks as FCC; evidence `rhombic_*`. The one difference from FCC
and Kelvin is the size-step verdict: across a cell-size halving its struts do not meet, so core
refuses Doubled for it by name, everywhere a job can ask for it (`cell_mode` swept or fit,
`stepped_cells`). Stepped (S | 2S/3) joins and is allowed.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 32 struts, 12 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs use the swept (Doubled) ladder, which core now refuses for rhombic at parse time (`rhombic_stand_swept_refused.txt`), so the stand ran on one fixed 4 mm cell (`make_stand_jobs.py rhombic <dir> --fixed 4`): it laid and certified rhombic on two Structural rungs (0.52: 33 cells; 0.38: 4) and the same two Aesthetic ones. The other two rungs carry no lattice for reasons core gives for any type: 0.26's widest member is 20.5 mm, under the 40 mm a 10-cell floor needs at 4 mm, and 0.68 holds a sealed 595 mm³ cavity (the void-reaches-exterior check) (`rhombic_stand_certificate.txt`); octet `r9_octet_rhombic_commit.txt`: the one differing leaf is `/model`, as before |
| 3 | Own law, diameter table, printability floor | PASS | `rhombic_law.{csv,txt}` (B3 within 5.0 %; the vpc48 staircase is why the law is bisected on the converged solid fraction, Finding 1) |
| 4 | Own floors, with conditions | PASS | bending **10** (`rhombic_bend*.txt`: +119.6 / +32.0 / +16.3 / +10.4 / +7.3 / +5.5 / +4.3 / +3.4 / +2.8 / **+2.3** % at 1-10 cells, C2b vpc12, cell rho 0.2963; +1.7 % at 12); percolation **0.75**; aesthetic hard floor **2** (+32.0 % at 2 cells, percolates) |
| 5 | Size-step verdict | **Doubled REFUSED**, Stepped allowed | `rhombic_step.txt`: S\|S/2 comes out as **2 components** (0 dangling of 4,608 ends: each side is whole, the two never touch); S\|2S/3 1 component, 0 of 2,240. `lattice_type_doubled("rhombic")` carries the reason, and `test_lattice_types` holds the generator to it both ways |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"rhombic"`; analyze Structural recertified margin 98.43, accepted, on rhombic's band 0.172-0.513 and floor 10 |
| 7 | Percolation on the emitted mesh | PASS | block and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 2 pieces, both with a cut end into the solid, **0 floating** (`rhombic_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("rhombic")`: `doubled.allowed` false with the reason, `stepped.allowed` true |

Numbers: band 0.17245-0.51331; cells per member 10; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.3181; smallest printable cell 3.650 x the bead; 1,264 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.343, 1.68 mm struts, 1.5 mm plate, 161,312 triangles;
`rhombic_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology rhombic --out rhombic_sample.stl
```

## Diamond — LIVE

The same harness, conditions and checks as FCC; evidence `diamond_*`. Diamond's cell corners are
reached by no strut of the cell they cap, which is why node balls are decided among the cells that
hold one of the node's struts (What changed, 2).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 16 struts, 8 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs (the swept ladder, which Diamond allows) laid and certified Diamond on three Structural rungs (0.68, 0.52: 16 cells; 0.26: 17) and the same three Aesthetic ones (18-112 cells); rung 0.38 carries no lattice in either mode because the void-reaches-exterior check, on by default, found one sealed cavity (39.7 / 79.3 mm^3), core's standing refusal, not a Diamond fault; `lattice-variant` of rung 0.52 reproduced its recorded margin exactly and was ACCEPTED (`diamond_stand_certificate.txt`); octet `r9_octet_diamond_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` (the job builder writes the model path absolute) |
| 3 | Own law, diameter table, printability floor | PASS | `diamond_law.{csv,txt}` (B3 within 4.9 %) |
| 4 | Own floors, with conditions | PASS | bending **10** (`diamond_bend*.txt`: +907.9 / +98.2 / +37.4 / +19.0 / +11.1 / +7.1 / +4.8 / +3.4 / +2.42 / **+1.77** % at 1-10 cells, C2b vpc12, cell rho 0.2685; 9 cells misses the 2.4 % band by 0.02); percolation **0.75**; aesthetic hard floor **2** (+98.2 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `diamond_step.txt`: S\|S/2 1 component, 0 dangling of 2,304 ends; S\|2S/3 1 component, 0 of 1,120 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"diamond"`; analyze Structural recertified margin 184.53, accepted, on Diamond's band 0.157-0.592 and floor 10 |
| 7 | Percolation on the emitted mesh | PASS | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.52: 15 pockets, **0 floating** (every piece reaches a cut, the solid companion or the shell) (`diamond_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("diamond")` |

Numbers: band 0.15712-0.59201; cells per member 10; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.1790; smallest printable cell 2.395 x the bead; 672 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.375, 2.47 mm struts, 1.5 mm plate, 87,252 triangles; `diamond_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology diamond --out diamond_sample.stl
```

## BCC — LIVE (strongly directional, R3)

The same harness, conditions and checks as FCC; evidence `bcc_*`. BCC is strongly directional
(R3): `lattice_type_facts("bcc").directional` is true with the note "best when the load runs
along the cell axes". Two things found while putting it and SC live are fixed in the commits
after it, so they reach the branch with SC's push, gated there: every receipt that names BCC
carries that note (`af9b60a2`), and its Diagrid skin no longer breaks into islands on a face just
off a node plane (`9118402c`, `diagrid_skin_connectivity.txt`: 16-25 pieces before, 1 after).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 2, 8 struts, 2 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs (the swept ladder, which BCC allows) laid and certified BCC on three Structural rungs (0.68: 112 cells; 0.52: 92; 0.26: 18) and the same three Aesthetic ones; rung 0.38 carries no lattice in either mode because the void-reaches-exterior check, on by default, found one sealed cavity (79.3 mm^3, the one Diamond's Aesthetic run hit), core's standing refusal, not a BCC fault; `lattice-variant` of rung 0.52 reproduced its recorded margin exactly and was ACCEPTED (1765 -> 1772) (`bcc_stand_certificate.txt`); octet `r9_octet_bcc_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` |
| 3 | Own law, diameter table, printability floor | PASS | `bcc_law.{csv,txt}` (B3 within 4.9 %) |
| 4 | Own floors, with conditions | PASS | bending **10** (`bcc_bend*.txt`: +220.1 / +49.7 / +22.6 / +13.0 / +8.4 / +5.8 / +4.2 / +3.2 / +2.48 / **+1.98** % at 1-10 cells, +1.32 % at 12, C2b vpc12 with the cell axes along the member, cell rho 0.2778; 9 cells misses the 2.4 % band by 0.08); percolation **0.75**; aesthetic hard floor **2** (+49.7 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `bcc_step.txt`: S\|S/2 1 component, 0 dangling of 1,152 ends; S\|2S/3 1 component, 0 of 560 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"bcc"`; analyze Structural recertified margin 79.40, accepted, on BCC's band 0.2105-0.5929 and floor 10 (`bcc_stand_certificate.txt`) |
| 7 | Percolation on the emitted mesh | PASS for the generator; the stand shows core's Finding 7 | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.52: 64 pockets, **12 floating** (356 of 1,381 primitives). Every one is 1, 2 or 4 whole 2 mm cells (24 in all) that the run's graded activation lattices alone: it activates the cell holding each masked voxel's centre, and the solve voxel is 3.41 mm, so each pocket voxel gets one cell; in a pocket one voxel thick those cells stop 0.24 mm short of the wall. Octet's own stand run floats the same way in the same place (2 pieces); FCC's left two lone cells there that touch its solid companion only by 0.05 mm (`bcc_stand_percolation.txt`; Finding 7) |
| 8 | Bridge contract | PASS | `lattice_type_facts("bcc")`, `directional` true |

Numbers: band 0.21050-0.59288; cells per member 10; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.1791 (below the band: Finding 6); smallest printable cell 2.392 x the bead; 296
triangles per cell; strut strength not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.402, 2.58 mm struts, 1.5 mm plate, 38,832 triangles; `bcc_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology bcc --out bcc_sample.stl
```

## Simple cubic — LIVE (strongly directional, R3; its bending floor is on-axis only)

The same harness, conditions and checks as FCC; evidence `sc_*`. SC is strongly directional (R3):
its facts and every receipt that names it carry "best when the load runs along the cell axes"
(`af9b60a2`). Its bending floor, **4** cells, was measured with the cell axes ALONG the member
(C2b's orientation) and says nothing about an off-axis member. Its Diagrid skin links because the
link radius now scales to each type's own gap between the nodes that cross a face (`9118402c`;
before it, SC's skin was 9 separate anchors on every face).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 2, 3 struts, 1 node) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand's own jobs (the swept ladder, which SC allows) laid and certified SC on all four rungs in both modes (Structural 672 / 464 / 154 / 167 cells, margins 1643 / 1624 / 1671 / 1632; Aesthetic 1249 / 811 / 476 / 474 cells, margins 1656 / 1653 / 1664 / 1626; all accepted); `lattice-variant` of rung 0.38 reproduced its recorded margin exactly and was ACCEPTED (1686 -> 1671) (`sc_stand_certificate.txt`); octet `r9_octet_sc_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` |
| 3 | Own law, diameter table, printability floor | PASS | `sc_law.{csv,txt}` (B3 within 4.0 %) |
| 4 | Own floors, with conditions | PASS | bending **4**, on-axis (`sc_bend*.txt`: -3.72 / +12.49 / +6.03 / **+2.08** % at 1-4 cells, -0.12 at 5, -1.48 at 6, C2b vpc12, cell rho 0.2593); percolation **0.75**; aesthetic hard floor **2** (+12.5 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `sc_step.txt`: S\|S/2 1 component, 0 dangling of 708 ends; S\|2S/3 1 component, 0 of 396 |
| 6 | Certificate, both modes; receipts name it | PASS | all nine run receipts `"sc"`, each with the directional note; analyze Structural recertified margin 63.91, accepted, on SC's band 0.0866-0.4964 and floor 4 (`sc_stand_certificate.txt`) |
| 7 | Percolation on the emitted mesh | PASS for the generator; the stand shows core's Finding 7 | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 107 pockets, **3 floating** (115 of 2,415 primitives). Each is 2 or 4 whole 2 mm cells (8 in all) that the graded activation lattices alone, in the pocket one solve voxel thick where octet's own run floats 2 (two of SC's have exactly octet's bounding boxes); they stop 0.13-0.17 mm short of the wall (`sc_stand_percolation.txt`; Finding 7) |
| 8 | Bridge contract | PASS | `lattice_type_facts("sc")`, `directional` true |

Numbers: band 0.08659-0.49638; cells per member 4 (on-axis); percolation 0.75; aesthetic floor 2;
aesthetic ceiling 0.0831 (below the band: Finding 6); smallest printable cell 1.771 x the bead;
116 triangles per cell; strut strength not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.291, 3.23 mm struts, 1.5 mm plate, 21,612 triangles; `sc_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology sc --out sc_sample.stl
```

## Gyroid — LIVE (sheet, K2)

The sheet harness (`tpms_probe.cpp`) on the production wall; evidence `gyroid_*`, `sheet_*`.
Its stand runs use a fixed 4 mm cell (`make_stand_jobs.py --fixed 4`): a sheet refuses the
committed jobs' swept ladder (R5), as rhombic's Doubled verdict did.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | the rows were re-measured on `tpms.hpp`'s production wall, the one `generate_tpms` contours (`gyroid_rows_vpc{48,96}.*`); `test_tpms` §1 holds the field, its gradient and the wall distance |
| 2 | Generates on a block and on the M2 stand; octet byte-identical; deterministic | PASS | `test_tpms` §2 (a clipped, holed, graded block: closed and manifold, two runs one hash, inside the part); the M2 stand on a fixed 4 mm cell laid and certified Gyroid on two Structural rungs (0.52: 33 cells, margin 1766; 0.38: 4, margin 1686) and the same two Aesthetic ones, all accepted; 0.68 holds the sealed 595 mm³ cavity (core's void-reaches-exterior refusal, as for Rhombic on this cell) and 0.26's widest member (20.5 mm) is under the 40 mm a 10-cell floor needs; `lattice-variant` of rungs 0.38 and 0.52 reproduced their recorded margins exactly and was ACCEPTED both times (`gyroid_stand_certificate.txt`); octet `r9_octet_gyroid_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` |
| 3 | Own density law, wall table, printability floor | PASS | `gyroid_wall_law.{csv,txt}` (the TRUE wall, rho 0.05-0.60); printability is wall >= bead (`sheet_printability.txt`, R6); no octet table is read (`test_strut_diameter_per_type`) |
| 4 | Own floors, with conditions | PASS | bending **10** (`gyroid_bend.txt` + `gyroid_bend_wide.txt`: +227.08 / +43.56 / +20.84 / +12.39 / +8.25 / +5.90 / +4.43 / +3.45 / +2.76 / **+2.24** % at 1-10 cells; C2b, S 5 mm, vpc24, 6 cells long, cell rho 0.4051; from 7 cells matrix-free); percolation **0.5** (`gyroid_perc.txt`: spans at every placement and rho 0.15 / 0.35 / 0.60 from 0.5 cells, the smallest measured); aesthetic hard floor **2** (+43.56 %, percolates) |
| 5 | Size-step: refusal with a reason | PASS: Doubled and Stepped refused (R5) | "A sheet lattice grades by wall thickness at one cell size per region (R5): a change of cell size leaves its sheets unjoined, and no measured method joins them yet." `test_tpms` §4 (Stepped refused at the parse) |
| 6 | Certificate, both modes; receipts name it | PASS | analyze certified Structural (margin 352.9, accepted, at rho 0.319: core raised the density to the 1-bead wall at 4 mm) and ran Aesthetic (rho 0.319-0.519); every run report says `"topology": "gyroid"` and carries no directional note (`gyroid_stand_certificate.txt`) |
| 7 | Percolation on the emitted mesh | PASS | the sample block's lattice is one piece (`test_tpms` §5, with the cell-line cut as its control: that cut leaves a stray corner cap); on the stand's emitted lattice STL (rungs 0.38 and 0.52) 0 pieces float: each pocket's sheet is one piece, cut where it meets the solid, and the 12-72-triangle caps cut off at cell corners lie wholly inside the solid body (0.135-4.6 mm in), so they print as solid; no edge is open, and the non-manifold edges are all in the solid body the run writes beside the lattice (SC's run has the same body) (`gyroid_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("gyroid")`, `family` "sheet" (BRIDGE CONTRACT, Sheets) |

Numbers: band 0.15010-0.60069; cells per member 10; percolation 0.5; aesthetic floor 2;
aesthetic ceiling = the band top (a wall has no strut-per-cell reading; Q1's default);
smallest printable cell 4.841 x the bead (the true wall at the band top is 0.2066 of the cell);
19.44 x (cell / DC cell)^2 triangles per cell (11,347 for an 8 mm cell at the band middle); sheet strength not measured (R10, refused in words). Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.375, 0.993 mm wall, 1.5 mm plate, 1,385,948
triangles, about 69 MB; the sheet is shifted an eighth of a cell so no corner of the cube cuts
off a cap; receipt `gyroid_sample_40mm.stl.json`, the STL is not committed):

```bash
core/build/topopt-cli lattice-sample --topology gyroid --out gyroid_sample.stl
```

## Schwarz-D — LIVE (sheet, K2)

The same harness, conditions and checks as Gyroid; evidence `schwarz_d_*`, `sheet_*`; stand
on the same fixed 4 mm cell, with the binary of Gyroid's gate (one commit carries both).

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | rows re-measured on the production wall (`schwarz_d_rows_vpc{48,96}.*`); `test_tpms` §1 |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_tpms` §2; the stand on the same fixed 4 mm cell laid and certified Schwarz-D on the same two rungs in both modes (0.52: 33 cells, margin 1765; 0.38: 4, margin 1686), all accepted; 0.68 and 0.26 carry none for Gyroid's reasons (the 9-cell floor needs 36 mm); `lattice-variant` of rungs 0.38 and 0.52 reproduced their margins exactly and was ACCEPTED both times (`schwarz_d_stand_certificate.txt`); octet: Gyroid's gate (the same commit) |
| 3 | Own law, wall table, printability floor | PASS | `schwarz_d_wall_law.{csv,txt}`; `sheet_printability.txt` |
| 4 | Own floors, with conditions | PASS | bending **9** (`schwarz_d_bend.txt` + `schwarz_d_bend_wide.txt`: +65.60 / +20.48 / +11.53 / +7.71 / +5.56 / +4.20 / +3.26 / +2.59 / **+2.09** % at 1-9 cells; cell rho 0.4074); percolation **0.5**; aesthetic hard floor **2** (+20.48 %, percolates) |
| 5 | Size-step: refusal with a reason | PASS: refused (R5) | as Gyroid |
| 6 | Certificate, both modes; receipts name it | PASS | analyze certified Structural (margin 467.1, accepted, at rho 0.393, the 1-bead wall at 4 mm) and ran Aesthetic (rho 0.393-0.600); receipts say `"topology": "schwarz_d"`, no directional note |
| 7 | Percolation on the emitted mesh | PASS | the sample block's lattice is one piece (`test_tpms` §5); 0 pieces float on rungs 0.38 and 0.52; the corner caps (12-36 triangles) lie inside the solid body (0.135-4.6 mm in) (`schwarz_d_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("schwarz_d")` |

Numbers: band 0.20038-0.60012; cells per member 9; percolation 0.5; aesthetic floor 2;
aesthetic ceiling = the band top; smallest printable cell 6.008 x the bead (the true wall at
the band top is 0.1665 of the cell); 24.00 x (cell / DC cell)^2 triangles per cell (18,865 at an 8 mm cell, band middle); sheet
strength not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.400, 0.856 mm wall, 1.5 mm plate, 2,319,684
triangles, about 116 MB; receipt `schwarz_d_sample_40mm.stl.json`):

```bash
core/build/topopt-cli lattice-sample --topology schwarz_d --out schwarz_d_sample.stl
```

<!-- PER TYPE -->

## BRIDGE CONTRACT (02-core-spec §5) — what the app calls, and what each answer means

Everything below is in core today. The app keeps a type hidden until its own preview is
built (A2); nothing here forces a type onto the screen.

### Which types exist, and which are live
| call | header | answer |
|---|---|---|
| `lattice_type_ids()` | `lattice_types.hpp` | the picker's order: `octet` first (M4), then `sc`, `bcc`, `fcc`, `diamond`, `kelvin`, `rhombic`, `gyroid`, `schwarz_d` |
| `lattice_gen_topology_names()` | `lattice_gen.hpp` | the GENERATABLE ids; grows by one per type that goes live |
| `lattice_certifiable_topology_names()` | `lattice.hpp` | the CERTIFIABLE ids (unchanged by this round for struts; the two sheets join, 9 in all) |
| `lattice_type_readiness(id, gen, cert)` + `lattice_type_readiness_plain(r)` | `lattice.hpp` | `Live` = offer it; anything else = grey it with core's plain words |

### One plain struct per type: `LatticeTypeFacts lattice_type_facts(id)` (`lattice_types.hpp`)
| field | meaning |
|---|---|
| `id`, `display_name`, `family` | core id; Q5's default name; `"strut"` or `"sheet"` |
| `readiness`, `readiness_plain` | as above |
| `numbers_measured` | true only when every number below is THIS type's own measurement; when false they are NaN, never octet's (R1) |
| `rho_min`, `rho_max` | the certifiable band |
| `cells_per_member_min` | bending accuracy floor (cells across a member) |
| `percolation_cells_per_member_min` | below it the struts do not hold together |
| `aesthetic_hard_floor_cells` | the aesthetic floor; no "with a finish" relaxation for the new types |
| `printable_cell_per_bead` | smallest printable cell = this × bead width (at the band top) |
| `aesthetic_density_ceiling` | R11 "prints open": strut diameter = 20 % of the cell, through the type's own law. **It can lie below `rho_min`** (BCC: 0.1791 < 0.2105; SC: 0.0831 < 0.0866; Finding 6): then no certifiable density prints open by R11 and an Aesthetic cap of min(`rho_max`, ceiling) is empty, so the app must not offer that cap as a range for such a type |
| `outline`, `rim`, `diagrid` | `{allowed, reason}` (R8) |
| `uniform`, `doubled`, `stepped` | `{allowed, reason}` (R4 measured; R5 for sheets) |
| `directional`, `directional_note` | R3 (SC, BCC): show the note on the picker and the receipt. Core's receipts carry the same words under `"directional_note"` (What changed item 7); for every other type the key is absent |
| `triangles_per_cell` | the per-cell emitted cost of the infinite tiling (8-gon prism 32, node 20) |
| `strut_strength_measured`, `strut_strength_note` | R10: false + "Strut strength is not measured for this type." for every new type |
| `cell_denominator` | S of the canonical cell (struts) |

Print status is maintainer data, joined by id:
`load_lattice_print_tests_file(path)` + `lattice_print_status(tests, id)` (`lattice_print_tests.hpp`):
`{listed, print_tested, date, note}`. **An id with no row reads as not print-tested.** The
loader refuses a malformed file by name; it accepts every core topology id plus `gyroid`
and `schwarz_d`.

### Struts: the geometry the preview draws (R12, M5)
| call | answer |
|---|---|
| `lattice_strut_cell(topo)` (`strut_cell.hpp`) | `{S, struts, nodes}`: integer coordinates in units of L/S, phase 0 at the cell's min corner. Canonical: a strut belongs to the cell holding its midpoint (half-open), a node to the cell holding it. |
| `strut_cell_closed_struts(cell)`, `strut_cell_closed_nodes(cell)` | every translate inside the CLOSED cell, for a renderer that draws cell by cell |
| `lattice_strut_diameter_mm(topo, rho, cell)` | the strut diameter core builds (the prism's circumradius is half of it) |
| `lattice_density_from_strut(topo, cell, radius)` | the other direction |
| `lattice_gen_topology_from_id(id)` | refuses an id core cannot build, by name |

The generator's ownership rule (so the preview places exactly what the run builds):
a strut is emitted by the cell whose half-open box holds its midpoint when that cell is
active; otherwise by the lexicographically smallest ACTIVE cell (i, then j, then k) that
shares it. A node ball is emitted the same way, but only among the cells that hold one of
its struts — a node no active cell's strut reaches is not emitted (diamond's cell corners
are the case that needs this).

### Sheets (`family: "sheet"`): what differs from a strut type
| call / key | answer |
|---|---|
| `tpms_eval`, `tpms_wall_distance`, `tpms_in_wall` (`tpms.hpp`) | the field the preview draws: period = the cell, phase 0 at the cell grid's anchor (the same anchor the app sends), the wall = |f|/|grad f| <= t/2 |
| `lattice_strut_diameter_mm(sheet, rho, cell)` | the TRUE wall thickness (what printability reads: wall >= bead) |
| `lattice_sheet_wall_param_mm(sheet, wall, cell)` | the field's t for that true wall (what `tpms_in_wall` takes) |
| `lattice_density_from_strut(sheet, cell, wall / 2)` | the density of that wall (the table; off it, the sheet's own solid fraction) |
| `sheet_triangles_coeff` | triangles per interior cell = coeff x (cell / DC cell)^2, DC cell = a third of the thinnest wall laid; `triangles_per_cell` is that at the band middle with an 8 mm cell |
| `doubled`, `stepped` | refused with the R5 reason; the job refuses `swept`, `fit`, `stepped` and stepped cells. Only `fixed` and `auto` lay a sheet, one cell for the part |
| `diagrid` | refused with the R8 reason; a sheet job must state `"skin": "rim"` or `"none"` (the default Diagrid is refused) |
| `aesthetic_density_ceiling` | the band top (a wall has no strut-per-cell "prints open" reading) |
| the sample block | shifted an eighth of a cell from the run's phase, so no corner of the cube cuts off a cap; the run keeps phase 0 at the grid anchor |
| R6 (wall >= one bead) | `sheet_printability.txt`: the density at which each cell size reaches one and two beads |
| the sample receipt (`<file.stl>.json`) | `strut_diameter_mm` is the true wall; `struts` and `nodes` are 0 |

### Every existing per-topology call accepts the new ids
`lattice_derive_cell_for_member`, `lattice_rho_min/max`, `lattice_cells_per_member_min`,
`lattice_percolation_cells_per_member_min`, `aesthetic_cells_per_member_hard_floor`,
`aesthetic_cells_per_member_floor`, `lattice_cell_printability_floor_mm`,
`lattice_min_printable_cell_mm`, `lattice_min_density_for_strut`,
`lattice_aesthetic_density_ceiling`, `stepped_size_menu`, `lattice_prints_open` — each
answers from the type's own measurement for a live type and refuses (never borrows) for
one that is not.

### The job (unchanged keys)
`lattice.topology` / `grading.topology` take any live id (they must agree, as before).
New refusals, each naming the reason: `algorithm: "organic"` with a non-octet type; a
region `relative_density` outside the TYPE's band; Doubled/Stepped for a type whose R4
verdict is not PASS. Multiscale refuses every type but octet (its material model needs
octet's upper rows), with core's existing reason. Receipts name the type:
`run_info.grading.topology`, `lattice_topology`, `lattice_export_topology`. For SC and BCC each of
those blocks, the per-variant lattice receipt and the sample block's receipt also carry
`"directional_note"`, right after the topology; no other type writes the key.

### The sample block
`topopt-cli lattice-sample --topology <id> [--cell 8] [--rho <band middle>] [--size 40]
[--plate 1.5] [--bead <mm>] --out <file.stl>` writes the STL and `<file.stl>.json`.
`topopt-cli --version` now ends with `lattice_sample=1`, so a worker can tell without a
trial run (brief item g).


## Octet stays byte-identical (R9) — how it was proved

- **Reference binary**: `topopt-cli` built from a `git archive` of the base `da6cbd9f`, copied to a
  directory and `chmod a-w` before any run (K0's warning: rebuilding under a measurement voided
  its evidence twice). The new binary is frozen the same way.
- **The M2 stand, both paths, both modes** (`r9_octet_fcc_commit.txt`, by `r9_compare.py`): analyze
  Structural and Aesthetic (res 128) and `run` Structural (res 64, four rungs, both exported lattice
  STLs) — every file byte-identical except the leaves that name the binary or the clock
  (`fingerprint`, `build_time`, `created_wall_ms`, `*_ms`, `*_s`, `gen_fraction`, the output path
  inside `*_alpha.meta`). The comparison script was proved able to fail: octet against FCC goes RED
  with 33 real differences.
- **The named test binaries, base vs HEAD** (`identity_<type>.txt`; the reviewer has not yet said
  which 17 make "the 17-test", so this is the superset of every lattice / grading / cell-plan /
  stepped / job / analyze / orientation binary, 21 of them, stdout and stderr with the `[mg] S7`,
  `[mg-safe]` and `[loose] flood fill` lines dropped). See each type's line below for the count and
  what the differing ones differ in.

### Gate per type (one full ctest + cli_demo + the identity diff before each push)

| type | ctest | cli_demo | identity diff (21 binaries) |
|---|---|---|---|
| FCC | 165 / 165 passed, 4,347 s (`ctest_fcc.txt`) | passed, 1,994 s | 18 identical; 3 differ only in: `test_lattice_gen` 29 -> 30 checks (its enum tripwire checks one name per generatable type, and `fcc` is one more), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build directory's path inside two output lines (`identity_fcc.txt`) |
| Kelvin | 163 / 165 in the gate's archive copy; the two that failed (`app_core_capability_mirror`, `smooth_brush`) read `../app` and `../docs`, which a `git archive` of `core/` does not carry, and both pass re-run in that same build with the trees linked (`ctest_kelvin.txt`); the pipeline now links them | passed, 1,965 s | 19 identical; `test_lattice_gen` (one more tripwire name) and `test_lattice_void_exterior` (build path) as before (`identity_kelvin.txt`) |
| Rhombic | 165 / 165 passed, 4,174 s (`ctest_rhombic.txt`) | passed, 1,881 s | 18 identical; `test_lattice_gen` 29 -> 32 checks (one tripwire name each for fcc, kelvin, rhombic), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_rhombic.txt`) |
| Diamond | 165 / 165 passed, 4,210 s (`ctest_diamond.txt`) | passed, 1,903 s | 18 identical; `test_lattice_gen` 29 -> 33 checks (one tripwire name each for fcc, kelvin, rhombic, diamond), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_diamond.txt`) |
| BCC | 165 / 165 passed, 4,178 s (`ctest_bcc.txt`) | passed, 1,869 s | 18 identical; `test_lattice_gen` 29 -> 34 checks (one tripwire name each for fcc, kelvin, rhombic, diamond, bcc), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_bcc.txt`) |
| SC | 165 / 165 passed, 4,151 s (`ctest_sc.txt`; the commit also carries `af9b60a2` and `9118402c`) | passed, 1,866 s | 18 identical; `test_lattice_gen` 29 -> 35 checks (one tripwire name each for fcc, kelvin, rhombic, diamond, bcc, sc), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_sc.txt`) |
| Gyroid + Schwarz-D (one commit, `ccf0e03b`) | 165 / 166 passed, 4,141 s; the one failure, `lattice_certification`, held the certifiable count at 7 and the sheets make 9: fixed in `472b5632` (test only) and re-run in the same build, passed (`ctest_gyroid.txt`) | passed, 1,849 s | 17 identical; `test_lattice_gen` 29 -> 37 checks (one tripwire name each for the six strut types and the two sheets), `test_lattice_certification` the two lines of that fix, `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build path (`identity_gyroid.txt`) |

Tests added for the round: `test_strut_cell` (237 checks), `test_lattice_types` (85 at FCC). Edited, each
because it was built to flip when a type goes live: `test_strut_diameter_per_type` (FCC leaves the
"must refuse" loops, which now skip every type with its own law; section 3's certifiable-but-no-law
example moves from FCC to Kelvin; new section 3b pins FCC's law), `test_job` (FCC moves from
"known but not live" to "live parses on both keys"). Each later type moved the same way. Since SC
(the last strut type) no certifiable type is left without a law or a generator, so both tests now
hold the converse: every certifiable type has its own law and parses (`7ae8eea7`). At SC's gate
`test_lattice_types` has 195 checks (every live type, the Diagrid skin on a face just off a node
plane, and the R3 note on the receipts).

K2: `test_tpms` (34 checks: the field and its wall distance, the generator on a clipped, holed,
graded block, Stepped refused at the parse, the sample block one piece with the cell-line cut as its
control); `test_lattice_types` 208 (each sheet's facts, floors, R5/R8 reasons and off-table inverse);
`test_job` 302 (a sheet job states `"skin": "rim"`); `test_strut_diameter_per_type` 191 (the sheets
have their own law); `test_lattice_certification` (9 certifiable, `472b5632`).

<!-- TESTS -->
