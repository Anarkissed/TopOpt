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
| D3 | L | At an edge with Grade to shape off, every cut cell has the size of its uncut neighbour; no cell position inside the region is empty. |
| D4 | L | With All lattice, one layout holds every wall; no cell is listed twice and no two cells overlap by more than 1e-6 mm. |
| D5 | F | Along a Protect skin face, solid thickness measured inward from the face is the stated depth ± 0.01 mm at every sample (1 mm spacing). At 0 mm it is 2 × bead ± 0.01. The first strut starts at that depth. |
| D6 | L | In the overlap of two prisms every cell belongs to the region with the nearer face; same plane, the deeper; then the earlier. Overlap of Lattice and No lattice holds no cell. |
| D7 | F | Inside every pocket of the part the file has no material: zero volume within the pocket's mesh, shrunk by 0.01 mm. |
| D8 | F | A wall refused lattice is solid over its whole width: no void inside it larger than 0.01 mm. |
| D9 | F | Every cut strut end lies on the part's surface within 0.01 mm. |
| D10 | L | No cell centre lies outside the face's outline carried through the depth, even where the outline's bounding rectangle covers it. |
| D11 | L | Expand of +e and −e moves the region's outline by e ± 0.01 mm in the face's plane; the region's depth is unchanged to 1e-6. Expand 0 gives the same layout as no Expand, byte for byte. |
| D12 | F | Outside every Lattice region the file equals the part: volume difference under 0.01 mm³ per cm³. |
| D13 | L | Reversing the region order gives the same layout, byte for byte. |
| D14 | L, A | Space in a region covered by no cell is listed as solid in the layout, and the preview draws it solid. |
| D15 | L | A face with both Protect skin and Lattice has one region with one depth. |
| D16 | F | Zero volume of lattice inside a Keep clear. Where the part's own solid enters a Keep clear, the solid is present. |
| D17 | L | No cell centre lies in material a design box added; that material is solid in the file. |
| D18 | L | Two launches, same part and settings: the layout's bytes are identical. |
| D19 | L | All lattice with one Lattice prism at Expand −3: every point of the 3 mm strip is lattice owned by the whole part. The same strip under All solid is solid. |
| D20 | L | A region from a curved face holds a point only if the nearest point of the face is inside the face's outline and within the depth ± 0.01 mm. A region from two faces that share an edge holds the points under that edge, and has one outline. |

## 2. Cell size

| Rule | Kind | Test |
|---|---|---|
| C1 | L | On a plain block the layout uses one cell size. On each reference part, no cell can be merged with its neighbours into an allowed larger cell that fits. |
| C2 | L | Every cell's size ≤ the wall's width at its centre + 1e-6. A 12.000 mm wall gets 12.000 mm cells, a 12.999 mm wall does not get a 13 mm cell. |
| C3 | L | Aesthetic: every wall at least 2 floor cells wide (4.742 mm at 0.45) holds lattice, with stress on or off. |
| C4 | L | With single-cell members on, a wall between 1 and 2 floor cells wide holds one cell across, sized to the wall. Finish is unchanged by the switch. |
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
| R2 | L | Octet on Auto: strut ÷ cell ≤ 0.1898 in every cell. With Allow quilt and a hand-set density, up to 0.354. |
| R3 | L | Inside the Grade to shape band, strut ÷ cell may pass 0.1898 and never passes 0.354. |
| R4 | L | Minimize plastic on and off give the same layout, byte for byte. |
| R5 | F | No strut in the file is narrower than the bead − 0.01 mm across its flats. |
| R6 | L | Uniform: every cell outside a grade band has the same strut ÷ cell to 1e-6. Per-region values are in the layout's input only in Per region mode. |
| R7 | L | By stress: the lowest strut ÷ cell in the layout matches "Grade from" and the highest matches "Grade to", each ± 1 dial step, on a part with both an idle and a loaded wall. |
| R8 | L | Each Manual value reaches the layout: strut widths lie between the two stated mm values ± 0.01; changing the response, the target stress or the load set changes the widths. |
| R9 | L | No cell has strut ÷ cell above 0.354. No cell is solid because of density alone. |
| R10 | L | Dial at 1%: strut = bead. Dial at 100%: strut = 0.354 × cell. Dial at 50%: strut is halfway between, ± 0.01 mm. |
| R11 | F | A typed strut width w: every strut in the file is w ± 0.01 mm, inside grade bands too. |
| R12 | L, A | By stress: changing a hand-set density does not change the layout, and the control is greyed. |
| R13 | F | A strut's cross-section area in the file equals π × (width ÷ 2)² of the round strut the law uses, ± 1%. |

## 4. Grade to shape

| Rule | Kind | Test |
|---|---|---|
| G1 | L | With Grade to shape on, cell size never grows as the in-plane distance to the region's outline shrinks (checked along 20 lines from centre to outline per face). |
| G2 | L | At in-plane distance ≥ Band from the outline, every cell is the region's own cell. At Band 0 the layout holds only the region's cell and its cut pieces. |
| G3 | L | Grade to shape on: the cells touching the outline are the smallest allowed cell (the floor cell, or the smallest fraction above it). No bar is in the layout unless Finish is Rim. |
| G4 | L | Strength 0 gives the default band. A higher Strength gives a band at least as wide, cell by cell no larger. |
| G5 | L | Two regions with the same outline and depths of 10 and 30 mm get the same in-plane cell sizes. |
| G6 | L | Grade to shape on: wherever the layout is solid inside a region, the neighbouring cell is the smallest allowed cell. |
| G7 | L | Grade to shape off: the cells touching the outline have the region's own size and are cut by it. |
| G8 | L | Across the band the strut width is constant to 0.01 mm while the cell shrinks; strut ÷ cell rises toward the outline. |
| G9 | L | An outline with an edge facing air: the cells still shrink toward that edge; the rim is absent on it (S2). |

## 5. Rim, skin and cut ends

| Rule | Kind | Test |
|---|---|---|
| S1 | L, F | Finish Rim: one bar per closed outline, a single path with no step larger than 0.01 mm between its segments. |
| S2 | L | No rim segment lies where the outline faces air or runs between two latticed regions. |
| S3 | L, F | Finish Skin: every cut strut end on the face is the end of at least one skin bar. The skin's open area is above 0 (it does not seal). |
| S4 | L | Finish None: every strut ends on another strut, on solid, or is absent. No strut shorter than its own width remains. Each stepped edge left is listed in the layout's notices with its place. |
| S5 | L | On every plane where two cell sizes meet, each node of the finer side is the end of at least two struts. |
| S6 | F | The file is one closed solid: every edge shared by exactly two triangles, one connected piece, no self-crossing. |
| S7 | L | Each Manual value reaches the layout: skin bar width, spacing and pattern, rim width ± 0.01 mm; joint fillet radius; no strut steeper past the overhang limit ± 0.5°. |
| S8 | A | A new lattice has Finish None. |
| S9 | F | Finish Covered: the outside of the file equals the part's surface within 0.01 mm; no strut is visible from outside. |
| S10 | F | Default rim bar width = 2 × bead ± 0.01 mm. |
| S11 | F | Where a strut meets solid there is no gap (distance 0 within 0.01 mm) and nothing of it lies outside the part (D2). |

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
| P2 | T | Dragging any slider: the layout is ready within 33 ms of each change on the stand (two frames). If not, P6 applies and the wait after the finger lifts is under 1 s. First layout when a part opens: under 5 s. |
| P3 | T | The user's part is shown on the Lattice page only if P2's 33 ms is met for it; otherwise the sample. |
| P4 | A | No frame draws geometry from one layout with cells from another: each frame carries one layout id. |
| P5 | A | Any wait over 0.3 s shows a working indicator. |
| P6 | T | Plan B only: one layout per finger lift or confirmed number. |

The 33 ms, 1 s and 5 s are my starting numbers. Stage 0 measures what the stand actually takes; the go or no-go at stage E is his.

## Reference cases

Four parts: the 2040 extrusion stand, Base, Top Motor Mount, Pressing Plate Mount. The model files and their setups stay out of the repo. For each part the case records the settings by name, the counts the layout must give (cells by size, struts, solid pieces, notices), and a picture he approves. The cases are added here once stage 0 gives a first layout to count.
