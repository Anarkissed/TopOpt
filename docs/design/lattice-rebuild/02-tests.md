# Lattice rebuild — the tests (stage A)

Working draft 1, 2026-11-10, LatticeReview. Companion to `01-rules.md` (draft 4). One test statement per rule, with the number it must meet. A stage is done when the tests named for it pass on every reference part.

## How things are measured

- **The layout** is the one object the engine returns: cells (centre, size, owning region, strut width), struts (two end points, width), solid pieces, rim bars, skin bars. Every test below reads the layout, or the file built from it. No test reads a picture.
- **The part's surface** is its mesh. "On the surface" means within **0.01 mm** of the mesh.
- **Exact numbers** (cell sizes, cell boundaries, fractions of a base cell) hold to **1e-6 mm**.
- **Printed widths** (strut, bar, face thickness) hold to **0.01 mm**, measured across the flats of what is written to the file.
- **Bead** is the line width from the print settings. Examples use 0.45 mm.
- **Floor cell** is 5.268704 × bead (2.3709 mm at 0.45).
- **Open ceiling** is strut ÷ cell = 0.1898. **Quilt** is strut ÷ cell = 0.354.
- A **wall's width** at a point is the mesh thickness there along the region's direction (C11).
- Every test runs twice with the regions listed in reverse order and must give the same answer (D13).

Kind of test: **L** reads the layout, **F** reads the file, **A** is an app test (what the page shows), **T** is a timing.

## 1. Where lattice goes

| Rule | Kind | Test |
|---|---|---|
| D1 | L | The layout with no stress result and the layout with one have the same set of latticed walls. |
| D2 | F | Every point of the file is inside the part's mesh, within 0.01 mm. Volume of the file ≤ volume of the part. |
| D3 | L | At an edge with Grade to shape off, every cut cell has the size of its uncut neighbour; no cell position inside the region is empty. A cut cell's shape is exact: the part of its cube that is lattice of its own region and its own wall (`cell_holds`). Where two walls meet off a cell boundary their cut cells overlap as cubes and never as that shape: every lattice point is held by exactly one cell. |
| D4 | L | With All lattice, one layout holds every wall; no cell is listed twice and no two cells overlap by more than 1e-6 mm. |
| D5 | F | Along a Protect skin face, solid thickness measured inward from the face is the stated depth ± 0.01 mm at every sample (1 mm spacing). At 0 mm it is 2 × bead ± 0.01. The first strut starts at that depth. |
| D5 | L | A 12 mm slab under a protected face, skin 1.2 mm: the first cell starts 1.2 mm below the face to 1e-5, the last ends at 12, every cell is (12 − 1.2) ÷ 2, nothing is solid, in Uniform, Default Grade and Stepped. At 0 mm the start is two line widths. A 6 mm plate protected 1 mm on both faces: one 4 mm cell between the skins; the wall rule (D8) reads those 4 mm, not the plate's 6. A skin on half a face: two walls, each divided on its own, and the seam between them left bare by no cell. |
| D6 | L | In the overlap of two prisms every cell belongs to the region with the nearer face; same plane, the deeper; then the earlier. Overlap of Lattice and No lattice holds no cell. |
| D7 | F | Inside every pocket of the part the file has no material: zero volume within the pocket's mesh, shrunk by 0.01 mm. |
| D8 | F | A wall refused lattice is solid over its whole width: no void inside it larger than 0.01 mm. |
| D9 | F | Every cut strut end lies on the part's surface within 0.01 mm. |
| D10 | L | No cell centre lies outside the face's outline carried through the depth, even where the outline's bounding rectangle covers it. |
| D11 | L | Expand of +e and −e moves the region's outline by e ± 0.01 mm in the face's plane; the region's depth is unchanged to 1e-6. Expand 0 gives the same layout as no Expand, byte for byte. |
| D12 | F | Outside every Lattice region the file equals the part: volume difference under 0.01 mm³ per cm³. |
| D13 | L | Reversing the region order gives the same layout, byte for byte. |
| D14 | L, A | Space in a region covered by no cell is listed as solid in the layout, and the preview draws it solid. Whoever draws or builds from the layout applies the rule itself: lattice space that `cell_holds` is true for in no cell is solid. The list is what the laying found, to within its own sample points and the face map's 1 mm nodes: a strip narrower than that can be unlisted. Measured on the stand (0.25 mm grid, 2026-11-11): unlisted space 0.03% of the front face's lattice (was 0.36%), 0.18% of the back face's. |
| D15 | L | A face with both Protect skin and Lattice has one region with one depth: the skin's depth is part of the region's, and the cells divide what is left (the D5 slab above ends at 12, not 13.2). |
| D16 | F | Zero volume of lattice inside a Keep clear. Where the part's own solid enters a Keep clear, the solid is present. |
| D17 | L | No cell centre lies in material a design box added; that material is solid in the file. |
| D18 | L | Two launches, same part and settings: the layout's bytes are identical. |
| D19 | L | All lattice with one Lattice prism at Expand −3: every point of the 3 mm strip is lattice owned by the whole part. The same strip under All solid is solid. |
| D20 | L | A region from a curved face holds a point only if the nearest point of the face is inside the face's outline and within the depth ± 0.01 mm. A region from two faces that share an edge holds the points under that edge, and has one outline. |

## 2. Cell size

| Rule | Kind | Test |
|---|---|---|
| C1 | L | On a plain block the layout uses one cell size. On each reference part, no cell can be merged with its neighbours into an allowed larger cell that fits. |
| C2 | L | Every cell's size ≤ the wall's width at its centre + 1e-6. A 12.000 mm wall gets 12.000 mm cells, a 12.999 mm wall does not get a 13 mm cell. Behind a pocket (a 4 mm wall, a 5 mm pocket, solid from 9 mm, region 13 deep): the wall behind reads start 9, width 4, and no cell in it is wider than 4 mm (built 2026-11-11; it read 11 and took 6.5 mm cells). A 2 mm wall, a 2 mm pocket and solid behind, all in one base cell: the 2 mm wall is listed solid and the wall behind keeps its cells. The wall behind a pocket is a wall of its own (C15): one layer of 4 mm cells starting 9 mm below the face, nothing solid, covered up to the pocket's end. A fin 0.6 mm wide hanging into the pocket is listed solid from its tip down (D14: found under the face map's nodes, read at its own depths). |
| C3 | L | Aesthetic, single-cell walls off: every wall at least 2 floor cells wide (4.742 mm at 0.45) holds lattice, with stress on or off; a narrower wall is solid. |
| C4 | L, A | With nothing set, single-cell walls are on: a 4.2 mm wall at 0.45 holds one cell across and no solid. A wall between 1 and 2 floor cells wide holds one cell across, sized to the wall. Finish is unchanged by the switch. A new project shows the switch on; a saved project keeps what it saved. |
| C5 | L | Structural: a wall holds lattice only if it takes 5 cells across at or above the floor cell; otherwise solid. |
| C6 | L | Stepped: every cell in a base slot of size S has size k × S ÷ n, n from 2 to 6, or S. |
| C6a | L | Stepped at 0.45: a 12 mm base uses only 12, 9.6, 9, 8, 7.2, 6, 4.8, 4, 3, 2.4 mm cells. No 10 mm and no 2 mm cell. At a 0.35 mm bead (floor cell 1.844 mm) the 2 mm and 10 mm cells are allowed. |
| C6b | L | Behind any cell at the face, the rest of the wall is filled by cells of the same smallest tile with no gap and no solid strip: depth covered = wall width to 1e-6. |
| C6c | L | Within one base slot every cell size is a whole number of that slot's smallest tile, and every cell starts on a multiple of it. |
| C7 | L | Default Grade: every cell size is S ÷ 2^m, and no cell is smaller than the floor cell. |
| C8 | L, F | A leftover narrower than the floor cell is part of the neighbouring cell, cut. It is solid only where the cut piece is narrower than 2 × bead. |
| C9 | L | Mirror a symmetric part across its plane of symmetry: the layout maps onto itself, cell for cell, to 1e-6. |
| C10 | L | Each Manual value changes the layout to match: minimum cells across ≥ the value; cell size per zone = the value; anchor moves every cell by the offset; angle turns them by the angle ± 0.01°; neighbours differ by no more than the stated step. |
| C11 | L | On an L-shaped part with two 20 mm walls, both walls get the cell a 20 mm wall gets; the corner gets no cell larger than that. On a 10 mm wall in a 40 mm deep region the wall width read is 10 ± 0.05 mm. |
| C11a | L | A rib 40 long, 3 wide across the face and 6 deep, lattice from its top. Two across at a 0.45 mm line: no cell, solid. Two across at a 0.2 mm line: cells of at most 1.5 mm. Single-cell walls: 3 mm cells, nothing solid. Five across: no cell, solid. The same rib 6 mm wide, two across: 3 mm cells, nothing solid. A wall with a step behind it (12 mm beside 6 mm) keeps its own cells right up to the step. Any number of threads gives the same layout. A 12 mm plate with grooves in its face (teeth 1.9 mm wide, 1.5 tall): all cells are 6 mm, none solid; the width read inside a tooth is 1.9, at the column's middle 12. |
| C12 | L | On a wall stepping from 12 to 6 mm, the 6 mm part gets cells ≤ 6 mm and the 12 mm part cells ≤ 12 mm. A larger cell appears only where the material is at least that cell's size in all three directions. |
| C13 | L | Stepped: a base slot cut by the outline holds at least two sizes when a larger allowed cell fits beside the cut. No solid strip in the depth. |
| C14 | L, F | Changing the bead from 0.45 to 0.60 moves the floor cell from 2.371 to 3.161 mm and the thinnest strut from 0.45 to 0.60 mm. |
| C15 | L | In every wall both faces lie on a cell boundary to 1e-6 (wall width ÷ cell size is a whole number). Where two walls with different cells meet, every node of the finer side on the shared plane is the end of a strut. |
| C16 | L | Auto with stress on a part loaded at one end holds more than one cell size. Manual with one size holds exactly one. |
| C17 | L | Default Grade: the base cell's halves reach a size within one halving of the floor cell, and the wall's covered width is ≥ that of the plain fit. |
| C18 | L, A | Structural with Unloaded walls on: a wall under 5 cells across and under the load threshold keeps lattice. The switch is absent in Aesthetic. |

## 3. Density and strut width

| Rule | Kind | Test |
|---|---|---|
| R1 | F | Each cell's strut width in the file equals the layout's for that cell ± 0.01 mm. |
| R2 | L | Octet without Allow quilt: strut ÷ cell ≤ 0.1898 in every cell, at every dial setting and with a typed width. With Allow quilt, up to 0.354. |
| R3 | L | Inside the Grade to shape band, strut ÷ cell may pass 0.1898 and never passes 0.354. |
| R4 | L | Minimize plastic on and off give the same layout, byte for byte. |
| R5 | F | No strut in the file is narrower than the bead − 0.01 mm across its flats. |
| R6 | L | Uniform: every cell outside a grade band has the same strut ÷ cell to 1e-6, except where that would be thinner than one line: there the strut is one line. Per-region dials change nothing in Uniform; in Per region each region takes its own dial, and a region with none takes the main one. |
| R7 | L | By stress: the lowest strut ÷ cell in the layout matches "Grade from" and the highest matches "Grade to", each ± 1 dial step, on a part with both an idle and a loaded wall. |
| R8 | L | Each Manual value reaches the layout: strut widths lie between the two stated mm values ± 0.01; changing the response, the target stress or the load set changes the widths. |
| R9 | L | No cell has strut ÷ cell above 0.354. No cell is solid because of density alone. |
| R10 | L | Read on the largest cell. Dial at 1%: strut = bead. Dial at 100%: strut = 0.354 × cell with Allow quilt, 0.1898 × cell without. Dial at 50.5%: exactly halfway between. Auto is 45%. Moving the dial moves no cell. |
| R11 | L, F | A typed strut width w: every cell that can hold it has w exactly, inside grade bands too, and every strut in the file is w ± 0.01 mm. A cell too small for w (w over 0.1898 × cell, or 0.354 with Allow quilt) takes the widest it can, and the layout reports how many such cells there are. |
| R12 | L, A | By stress: changing a hand-set density does not change the layout, and the control is greyed. |
| R13 | F | A strut's cross-section area in the file equals π × (width ÷ 2)² of the round strut the law uses, ± 1%. |

## 4. Grade to shape

| Rule | Kind | Test |
|---|---|---|
| G1 | L | With Grade to shape on, cell size never grows as the in-plane distance to the region's outline shrinks (checked along 20 lines from centre to outline per face). Every cell obeys the centre rule: a cell of size S stands only where its centre is at least Band × (S − f) / (S_own − f) inside the outline, f the finest cell and S_own the region's own. |
| G2 | L | Beyond the Band (plus half the difference to the region's own cell, for the inner cells of a divided base cell), every cell is the region's own cell. At Band 0 the layout holds only the region's cell and its cut pieces. |
| G3 | L | Grade to shape on: the cells at the outline are the smallest cells in the layout there (on a 0.2 mm line and 8 mm cells, 2 mm). No bar is in the layout unless Finish is Rim. One size (Manual) keeps its cells and grades struts only. |
| G4 | L | Strength 0 is the default raise. A higher Strength gives every strut in the band at least the same width and some more; a lower one never more. Struts outside the band do not move. Strength moves no cell. |
| G5 | L | A region 16 mm deep with 8 mm cells: both layers hold the same cells, and beyond the Band every cell is the region's own at every depth. Cells do not shrink toward the region's floor. |
| G6 | L | Grade to shape on: the band makes nothing solid. A place that was lattice with it off is in a cell with it on. |
| G7 | L | Grade to shape off: the cells touching the outline have the region's own size and are cut by it. |
| G8 | L | In the band no strut is thinner than the region's own strut (or the quilt of its cell, if that is less), strut ÷ cell is higher than outside the band in every band cell, never above 0.354, and each strut is a whole number of lines or the quilt. A typed width (R11) holds in the band too. |
| G9 | L | An outline with an edge facing air: the cells still shrink toward that edge; the rim is absent on it (S2). |
| G10 | L | Grade to shape on, at Band 12 and at Band 2 (too narrow to hold a large cell off the outline by itself): no cell larger than the finest crosses the outline; the finest may; nothing goes solid and every place is still in a cell. |
| G11 | L | (Switch off by default, awaiting his pick.) On a 0.45 mm line with the switch on: the band holds cells below the open look's floor and none that one line would close; none of them lies outside the band; nothing goes solid; every strut is at least one line and at most the quilt of its cell. With no band the switch moves no cell. The guards that keep such cells inside the band each have a part that tempts them: a 2 mm wall 15 mm from the outline stays solid with the band on (Default Grade and Stepped), and a 2.6 mm strip beside a 12.8 mm wall is laid the same with the switch on or off when there is no band. Stepped fills a thin wall's rim inside the band with the finer cells; Default Grade does so only where the band itself asks for a smaller cell. |

## 5. Rim, skin and cut ends

| Rule | Kind | Test |
|---|---|---|
| S1 | L, F | Finish Rim: one bar per closed outline, a single path with no step larger than 0.01 mm between its segments. Built 2026-11-11 in the layout (`DomainSpec::rim_mm`, `Why::Rim`, `test_rim`): the rim is the band of the region within its width of the region's own edge, as deep as the lattice, so the Domain's one reading answers it and it is exactly as smooth as the outline. On a block with the region pulled 3 mm in: points 0.5 and 0.85 mm inside the edge are rim, 0.95 mm is lattice, round the corners too; along a straight edge its inner side is straight to 0.001 mm; no cell holds a rim point; every cut strut end runs on into the rim (S11), none is cut by air or left loose. Not built: the rim as one path in the file (F). |
| S2 | L | No rim segment lies where the outline faces air or runs between two latticed regions. Built: with the region reaching the block's own sides there is no rim (the edge faces air); two regions side by side have none along the seam and one round the rest. Four deliberate breaks fail (air ignored, seam ignored, half width, no step past the edge). On his stand (band 6, 0.42 line, default rim): 2,065 cells, 29,515 bars after joining and dropping. |
| S3 | L, F | Finish Skin: every cut strut end on the face is the end of at least one skin bar. The skin's open area is above 0 (it does not seal). |
| S4 | L | Finish None: every strut ends on another strut, on solid, or is absent. No strut shorter than its own width remains. Each stepped edge left is listed in the layout's notices with its place. Built 2026-11-11 (`lay_bars`, `drop_loose_bars`; `test_bars`): a 12 mm cube of 2 x 2 x 2 whole cells is 240 bars, each strut once; on a 20 mm block the cells cut by its sides give pieces whose cut ends are marked; after dropping, no end is in the air or loose and no bar holds a node alone; a 13 mm block leaves stubs, counted and not kept; a hand-made chain from solid out to a cut end goes entirely, a triangle standing on solid stays. Not built: the notices that list each stepped edge. |
| S5 | L | On every plane where two cell sizes meet, each node of the finer side is the end of at least two struts. Built 2026-11-11 for the line where two walls with different cells meet (`join_loose_bars`, `test_bars_join`): each side's cut struts are run straight on until they end inside a bar of the other side, or in solid, or have gone one cell of their own. A 12 mm wall (6 mm cells) beside a 5 mm wall (5 mm cells): more than half the loose ends land; each landed end is inside another bar; none runs farther than one cell, out of the part, or moves an end that was not loose; struts of each wall end in the other's; nothing loose is left after dropping. Five deliberate breaks fail. On his stand (band 6, 0.42 line): of 6,763 loose ends 4,745 land (4,716 in a bar, 29 in solid), 1,049 reach the part's surface first and 969 meet nothing within a cell; the gap along the wing and centre plate closes. Not built: struts added where two WHOLE cells of different sizes share a face (their face struts cross in that plane and are joined there already, but a finer node has no partner of its own on the coarser side); a joined bar is not yet dropped when the bar it ends in is. |
| S6 | F | The file is one closed solid: every edge shared by exactly two triangles, one connected piece, no self-crossing. |
| S7 | L | Each Manual value reaches the layout: skin bar width, spacing and pattern, rim width ± 0.01 mm; joint fillet radius; no strut steeper past the overhang limit ± 0.5°. |
| S8 | A | A new lattice has Finish None. |
| S9 | F | Finish Covered: the outside of the file equals the part's surface within 0.01 mm; no strut is visible from outside. |
| S10 | F | Default rim bar width = 2 × bead ± 0.01 mm. In the layout: `rim_mm < 0` is two line widths (0.9 mm at a 0.45 mm line gives the same answers as 0.9 asked for); 0 is no rim (S8). |
| S11 | F | Where a strut meets solid there is no gap (distance 0 within 0.01 mm) and nothing of it lies outside the part (D2). In the layout (L), built 2026-11-11: no bar end lies outside the part (to a millionth of a millimetre); a bar the part's surface cuts ends on the surface; the struts lying in the latticed face of the 20 mm block total 192.33 mm, the exact length of its two families of diagonals; with the region pulled 2 mm in from the outline, each bar cut at the region's edge ends in solid, 0.6 to 1 width past the edge. Seven deliberate breaks fail. |

## 6. What the app says

| Rule | Kind | Test |
|---|---|---|
| U1 | A | Every row on the Lattice page is one line. Every blocked control shows one line and one button that clears it. |
| U2 | A | No text on the page matches "face" followed by a number. |
| U3 | L | For every control on the page, some value of it changes the layout's bytes on at least one reference part. |
| U4 | L, A | A lattice space with no path to the outside is listed in the layout's notices with its place; the page highlights it. |
| U5 | A | Auto shows the maker's set of controls; Manual shows every value the layout takes as input. |
| U6 | L | A type the engine cannot build returns a refusal that names it. No layout comes back under another type. |
| U7 | L, A | Every wall the layout leaves out is in its notices by name. |
| U8 | L | A control that is hidden: changing its stored value does not change the layout. |
| U9 | A | Aesthetic: no strength warning text on the page. |
| U10 | A | No panel or label overlaps the part's picture. |
| U11 | A | The Structural or Aesthetic choice is asked once per stage opening. |
| U12 | A | Every number field opens a keypad. |
| U13 | A | Finish None shows one line recommending Rim or Skin, with a one-tap switch; on a single-cell wall the line names that wall. |

## 6b. What a run may claim

| Rule | Kind | Test |
|---|---|---|
| V1 | F | The strength check's member list equals the struts and bars in the file: same count, same widths ± 0.01 mm. |
| V2 | F | Each check named in the result has a record that it ran. |
| V3 | F | A run whose file holds no strut returns a refusal. |

## 7. Speed

Timed on the Mac first (stage 0), then on the iPad (stage E).

| Rule | Kind | Test |
|---|---|---|
| P1 | T | The preview shows a layout with no worker reachable. |
| P2 | T | Dragging any slider: the layout is ready within 33 ms of each change on the stand (two frames). If not, P6 applies and the wait after the finger lifts is under 1 s. First layout when a part opens: under 5 s. In core, built 2026-11-11 (`lattice_layout::Session`, `test_session`): the app holds one session per part; a cell or strut setting re-lays without reading the part again, a region, depth, Expand, Protect skin, rim or line-width setting reads it again once, and either way the layout equals a fresh session's. Four deliberate breaks fail. Measured on a Mac, his stand: first layout 0.26 s, each cell-setting change 44 ms for the cells (above the 33 ms on all cores, 0.2 s on one) plus about 0.2 s for the bars. Not measured on the iPad: the bridge entry is proposed, not built. After a second round on the struts (2026-11-12: the line that reads a wall also says whether the point is inside; squares of a face wholly inside or outside a region's edge are answered without measuring to the outline, `test_region_squares`; a strut is read closely only when a quick five-point test and its own line say it is cut; joining runs on all cores): cells 39 ms, struts 81 ms, joining 48 ms, dropping 17 ms on all cores (struts were 433 ms in all); cells and, to a few thousandths of a millimetre, bars unchanged. |
| P3 | T | The user's part is shown on the Lattice page only if P2's 33 ms is met for it; otherwise the sample. |
| P4 | A | No frame draws geometry from one layout with cells from another: each frame carries one layout id. |
| P5 | A | Any wait over 0.3 s shows a working indicator. |
| P6 | T | Plan B only: one layout per finger lift or confirmed number. |

**How the layout reads the part, 2026-11-11 (speed).** The layout used to find a wall's far side by walking through the part by the distance to its surface; deep inside a thick wall that is slow, and it steps over air thinner than 0.01 mm. It now reads a straight line against the part's own triangles, and reads "inside or outside" the same way. The answers a layout is built from did not change. Checks (`test_measure_by_line`):

| What | Test |
|---|---|
| A line never slips between two triangles | Round-number lines through triangle edges and corners of the L: each reads its exact length. |
| A line that only touches the surface has reached it | Through the L's inside corner with material either side: stops at the corner; a thousandth to either side it runs on, or ends in the notch. |
| Line and walk agree | 4,000 lines from points inside the L: equal to 0.00001 mm, or the line is shorter and the point just past it is air. |
| Inside by more than a micron | Every point of a grid over the L, on faces, edges and corners and a hair either side: the same answer as the distance gives. A point in a notch whose line only brushes the part's edge is not inside. |
| "No narrower than" | On a box, for five points and six widths, the width a caller acts on is the same as the full measure gives; beside an upright edge the 2.83 mm line across the corner is still not the wall. |
| Far from a surface | A point the coarse map rules out is farther from the surface than the distance asked. |

Each has a deliberate break that fails it (seven in all). On his stand (two faces, Stepped, 0.45 mm line, band 6): 2,201 cells and 136 solid pieces before and after, every cell the same to half a micron; laid in 0.22 s on all cores of the Mac (was 9.4 s) and 0.74 s on one core. With a 1.2 mm Protect skin: 0.24 s (was 4.3 s), identical. With finer cells in the band: 1.6 s (was 47.6 s). Not yet timed on the iPad.

After the two changes that followed (the wall is the lattice's own column; the narrowest width read once per column): 0.12 s on all cores and 0.27 s on one; finer cells 0.38 s and 1.6 s. On the stand's back face this changed the cells behind its pockets only (118 cells of 3.25 mm that stood in under 3.25 mm of material are now solid; 56 pieces wrongly solid are now cells); the front face and the Protect skin case are unchanged, cell for cell.

**Kept with the domain (P2).** What a layout reads under each flat face (every stretch of material under each node, the stretches' exact starts, widths and edges) depends on the part, the regions and the Protect skins only, so it is made by the first layout of a domain and reused by every later one. `test_kept_readings`: a layout after any other layouts of the same domain equals the layout of a fresh domain, for four cell settings in two rounds and on one thread; each region keeps its own. Four deliberate breaks fail (no reading through a pocket; a fin read at the wrong depths; edges not searched; one kept reading for every region). On his stand: first layout 0.26 s on all cores (0.43 s on one); each layout after it, which is what dragging a cell-size or band slider costs, 44 ms on all cores (0.2 s on one); with a Protect skin 15 ms (66 ms on one). The stand has no wall-sized material behind its pockets, so its cells did not change.

The 33 ms, 1 s and 5 s are my starting numbers. Stage 0 measures what the stand actually takes; the go or no-go at stage E is his.

## Reference cases

Four parts: the 2040 extrusion stand, Base, Top Motor Mount, Pressing Plate Mount. The model files and their setups stay out of the repo. For each part the case records the settings by name, the counts the layout must give (cells by size, struts, solid pieces, notices), and a picture he approves. The cases are added here once stage 0 gives a first layout to count.
