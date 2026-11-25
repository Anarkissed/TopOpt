# Cell types: one table per type

The strut types the new lattice engine lays (the owner, 2026-11-24: all nine strut types, plus the octet), with every
number each one is laid, printed and checked by, where it comes from, and its valid range. For TOReview's Stage 8 and
builder F (claude/notes28-strut-laws). Kept by builder D (claude/notes28-celltypes-core); every number below is read from
core, the file and line named, and the matrix test `lattice_types_matrix`
(core/tests/validation/test_lattice_types_matrix.cpp) prints the derived ones on every run.

**Measured** means taken from core's own measurement of that type's own cell, with its evidence. **Geometry** means
exact, from the type's canonical cell (core/src/fea/strut_cell.cpp). **Ruled** means a reviewer's or the owner's rule.
**Assumed** means a number nobody has measured for this type; each is named as such. Nothing here is extrapolated: a
density outside a type's measured band gets no strength credit (V4; ruling 11-09: ship as measured).

## What every strut type shares

| Number | Value | Source |
|---|---|---|
| Strut width over cell, the open look ("Allow quilt" off) | 0.7592 / 4 = 0.1898 | Ruled: R11, ruling 2026-11-02 (c) (`kLatticeOpenLookStrutPerCell`, lattice.hpp). One geometry for every strut type; the same openness as the octet's for the types whose face view is the octet's (diamond, kelvin, rhombic), more open for the rest. |
| The thinnest strut | two line widths: 0.90 mm at a 0.45 mm line | Ruled: R14, reviewer 2026-11-12 (`kMinStrutLines`), from his prints. |
| The smallest cell (the two-line floor) | 0.90 / 0.1898 = 4.74 mm, every strut type | Ruled (follows from the two rows above, C14). |
| A strut counted as a bridge (printed flat, square, level underside) | under 30 degrees above level | Ruled (`bar_is_bridge`, the 11-12 flat-bridge rule). |
| A bridge's reach (print rule e) | at most 5 mm past what holds it | Ruled: reviewer 2026-11-14 (`kBridgeReachLimitMm`, lattice_layout.hpp). |
| Interlayer strength factor (z_knockdown) | 0.55 | **Assumed** (core/src/materials/materials.json). Unsourced; Bembenek 2022 (Polymers 14:2446) measured 0.44 for PLA. A vertical strut is a stack of layers, so a type whose load runs up its columns (sc, and bccz / fccz if they are ever certified) reads about 25 % optimistic across layers on today's 0.55. Not changed here. |

## Per type

Strength laws are `*_cert` columns of `evidence/2026-11-09-lattice-type-strut-laws/<type>/kfit.csv` (octet:
`evidence/2026-11-17-octet-full-strut-law`), core/src/fea/strut_strength.cpp: per density, the worst strut von Mises
per unit macro von Mises (Kd) and per unit macro pressure (Kv), and the interlayer pair (Kild, Kilv). Stiffness is the
cubic tensor (C11, C12, C44, MPa on PLA's modulus) of core/src/fea/lattice.cpp, measured by
`tensor_library_nine_probe.cpp` (octet: PR 198/246). Both are **measured**, on each type's own cell, over the band
shown, and only there.

"Credited up to" is the largest cell whose two-line (0.90 mm) strut is still inside the band: past it, the thinnest
strut's cells get no strength credit (they are void in the check's solve). "Auto's cap" is the largest cell Auto lays
for the type (`auto_cell_cap_mm`): a level strut spans its share of the cell, and held at both ends reaches half of it
as a bridge, which must stay within 5 mm.

| | octet | fcc | kelvin | rhombic | diamond | bcc | sc |
|---|---|---|---|---|---|---|---|
| Measured band (density) | 0.0496 - 0.9003 | 0.0951 - 0.5909 | 0.0938 - 0.5052 | 0.1724 - 0.5133 | 0.1571 - 0.5920 | 0.2105 - 0.5929 | 0.0866 - 0.4964 |
| Stiffness at the band's ends, C11 / C12 / C44 (MPa) | 36.3/18.4/17.2 - 3862/1765/1076 | 79.1/38.2/34.1 - 1345/444/392 | 69.6/44.6/8.76 - 1157/376/315 | 134/101/40.7 - 998/449/378 | 119/83.5/47.9 - 1223/557/521 | 156/127/113 - 1126/522/471 | 124/7.47/2.65 - 1122/234/201 |
| Strut law at the band's ends, Kd / Kv | 108/57.1 (bulk only, a lower bound; no pass under 0.10) - 6.39/3.74 | 76.3/42.0 - 9.67/6.68 | 194/38.4 - 11.9/7.73 | 137/25.9 - 12.0/8.50 | 108/32.7 - 11.7/7.08 | 125/21.2 - 12.0/8.52 | 593/47.5 - 20.9/9.15 |
| Interlayer law at the ends, Kild / Kilv | 68.8/46.0 - 2.37/2.11 | 66.4/42.9 - 8.67/7.76 | 170/44.9 - 8.37/6.37 | 95.9/25.5 - 12.9/7.85 | 64.3/23.8 - 6.45/4.27 | 91.9/20.1 - 14.2/8.04 | 333/46.7 - 19.4/8.78 |
| Density at the open look (strut/cell 0.1898) | 0.3487 | 0.1937 | 0.1889 | 0.2920 | 0.1630 | 0.1630 | 0.0756 |
| Strut/cell at the band's floor | 0.0640 | 0.1279 | 0.1281 | 0.1394 | 0.1861 | **0.2192 (past the open look)** | **0.2044 (past the open look)** |
| Two-line strut credited up to | 14.1 mm cell | 7.04 mm | 7.03 mm | 6.46 mm | 4.84 mm | never (4.11 mm < the 4.74 mm floor) | never (4.40 mm < 4.74 mm) |
| Touch (where neighbouring struts meet: "Allow quilt" on) | 1/(2 sqrt 2) = 0.3536 | 1/sqrt 3 = 0.5774 | 0.3536 | 0.3536 | 0.3536 | 1/sqrt 2 = 0.7071 | 1 |
| Smallest cell with the quilt (0.90 mm / touch) | 2.55 mm | 1.56 mm | 2.55 mm | 2.55 mm | 2.55 mm | 1.27 mm | 0.90 mm |
| Strut angles above level, cell upright (+Z up) | 0 (face diagonals: bridges, 0.71 x cell between nodes) and 45 | 0 (top-face diagonals: bridges, 0.71 x cell) and 45 | 0 (square windows: bridges, 0.35 x cell) and 45 | 35.26 (<111>) | 35.26 (<111>) | 35.26 (<111>) | 0 (edges: bridges, a full cell) and 90 |
| Self-support | 45 degree struts self-supporting; bridges level and short | as octet | as octet, its bridges half as long | every strut a round bar over the 30 degree cut-off, self-supporting | as rhombic | as rhombic | columns stand; every level edge is a bridge a whole cell long |
| Auto's cap | none applied (14.1 mm by its geometry; the octet's layouts stay as they were, R9) | 14.1 mm | 28.3 mm | none (no level strut) | none | none | **10 mm** |
| Structural | yes | yes | yes | yes | yes; only its heaviest struts (strut/cell 0.186 - 0.190) are in band | allowed; no strut it lays is in band: no credit until F's laws (`structural_note`) | as bcc |

| | bccz | fccz | reentrant |
|---|---|---|---|
| Cell (geometry, the family study's) | bcc + the corner z columns: 9 struts, 2 nodes | fcc's legs + the corner z columns: 13 struts, 4 nodes | S 4: four waists pulled in from the four side faces, each joined to its face's four corners, + the corner z columns: 17 struts, 5 nodes |
| Measured band, stiffness, strut law | none in core: tetragonal (C33 differs from C11), refused by the cubic certification (PR 246 measured their tetragonal constants; `hex8_stiffness_transverse` has no caller) | none (as bccz) | none (as bccz) |
| Structural | **refused**, one line (`structural_refusal`, type_not_supported) | refused | refused |
| Touch | 1/sqrt 2 (bcc's; geometry) | 1/2 (3D; geometry) | 1/3 (3D; geometry; face view 1/sqrt 5) |
| Smallest cell with the quilt | 1.27 mm | 1.80 mm | 2.70 mm |
| Strut angles, cell upright | 35.26 and 90 | 0 (bridges, 0.71 x cell), 45 and 90 | 41.81 and 90 |
| Self-support | as bcc; its columns stand | as fcc; its columns stand | the waist struts lean 41.8 degrees, over the 30 degree cut-off: round bars; the struts below a waist hold it up, the ones above lean out from it; a waist whose lower struts a wall cuts (they would start in the air) is not laid (lay_bars, 2026-11-25); its coupon prints clean |
| Auto's cap | none | 14.1 mm | none |
| Special axis | its z (the columns) is laid along the frame axis nearest up, so the columns stand up on any face (`cell_struts`) | as bccz | as bccz (its waists' axis) |

## Measured or assumed, in one list

- Measured on each type's own cell: the density band, the stiffness tensor, the strut law and the interlayer law
  (octet, fcc, kelvin, rhombic, diamond, bcc, sc). Not measured: anything outside each band (no credit there), and
  all three for bccz, fccz and reentrant (no certification).
- Geometry: each cell, its touch, its strut angles, its level struts' spans, Auto's caps.
- Ruled: the open look 0.1898, two lines, the 30 degree bridge cut-off, the 5 mm bridge reach.
- Assumed: the interlayer factor 0.55 (above).
- Not yet printed (his rule, "Not print-tested"): every type but the octet (8 mm, 2026-11-11) and bccz (8 mm,
  2026-07-29). Each type's print coupon: `topopt-cli lattice-coupon --topology <type> --out <folder>`
  (make_type_coupon: the 8 mm rim coupon's outline, two-line struts, a flat 2 mm plate fused in, print-checked).

## Sheets (gyroid, Schwarz-D): the law per member width

Builder D of the sheets design, section 3.2. Today a Structural sheet is credited only from 10 cells across
(gyroid) or 9 (Schwarz-D), by the law of `evidence/2026-11-09-lattice-type-strut-laws`. The same
measurement, made per member width N, is in `evidence/2026-11-25-sheet-laws-thin-members` (README).
Core carries it in `core/include/topopt/sheet_width_law.hpp` (tables generated from that folder's CSVs;
`test_sheet_width_law` pins every row). It is not wired into the check yet: builder B joins it once the lead
and TOReview set the floor.

**Strength, Kd per density.** Every coefficient (Kd, Kv, Kild, Kilv) is in
`<type>/kfit_widths.csv` and in core.

- **Today** is the law from 10 / 9 cells.
- **Measured at N** is 11-09's envelope for a member N cells across: the bulk, plus the free-surface and
  cut-layer blocks cut at 0.25, 0.5, 0.6 and 0.75, at 11-09's pitch.
- **Law for N = 2..8** is the max over the widths >= N and today's row.
- **Off the grips** is the same envelope with the cut layer's cells next to the gripped faces left out.
  It is for TOReview, not the law.

| gyroid rho | today | measured at N = 2 / 3 / 4 / 5 / 6 / 8 | law for N = 2..8 | off the grips |
|---|---|---|---|---|
| 0.150 (vpc 24) | 59.60 | 95.1 / 105.5 / 120.6 / 133.8 / 145.5 / 166.0 | 166.0 | 39.0 |
| 0.200 | 34.04 | 43.7 / 48.7 / 55.6 / 61.6 / 66.9 / 76.2 | 76.2 | 38.1 |
| 0.313 | 23.87 | 24.6 / 27.4 / 31.1 / 34.3 / 37.1 / 42.1 | 42.1 | 17.0 |
| 0.450 | 14.28 | 14.4 / 15.9 / 18.0 / 19.9 / 21.6 / 24.5 | 24.5 | 9.84 |
| 0.601 | 9.45 | 11.1 / 12.4 / 13.9 / 15.3 / 16.5 / 18.5 | 18.5 | 7.27 |

| Schwarz-D rho | today | measured at N = 2 / 3 / 4 / 5 / 6 / 8 | law for N = 2..8 | off the grips |
|---|---|---|---|---|
| 0.200 (vpc 24) | 36.70 | 47.0 / 52.5 / 58.6 / 63.8 / 68.4 / 76.4 | 76.4 | 24.7 |
| 0.313 | 21.72 | 20.6 / 22.9 / 25.4 / 27.5 / 29.3 / 32.6 | 32.6 | 13.2 |
| 0.450 | 14.87 | 11.7 / 13.2 / 14.9 / 16.3 / 17.5 / 19.7 | 19.7 | 9.78 |
| 0.600 | 9.24 | 7.6 / 8.2 / 9.3 / 10.2 / 11.0 / 12.4 | 12.4 | 5.87 |

- **Measured, and opposite to the expected direction:** Kd rises as the member WIDENS, at every density.
  - So the narrow rows do not come from the narrow blocks. Every row is the 8-cell block's value, 1.3 to
    2.8 x today's.
  - The cut layer sets every row. Its peak sits in the cut cells next to the gripped faces, a corner of
    the test block that rises with pitch. 11-09's population includes those cells; the grip population
    itself is left out of the law.
  - Off the grips every row is below today's.
  - So by its own method with the added cuts, today's row reads low. Whether the grip-adjacent cut cells
    belong in the law is TOReview's call (README, findings 1-3).
- **Pitch:** the rows are read at 11-09's pitch. The median wall run is 2-5 voxels, the true wall 1.0-3.3
  voxels: lower bounds, as 11-09's boundary rows were. The 6-voxel checks are in the README.

**Stiffness:** the C2b guided cantilever, resolved against the averaged material (vpc 24). A positive
error means the averaged member is too stiff; core scales the tensor by 1 / (1 + error) there.

| | rho | N = 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| gyroid | 0.146 | +55.4 % | +26.2 | +15.5 | +10.3 | +7.5 | +5.7 | +4.5 |
| gyroid | 0.405 | +43.6 % | +20.8 | +12.4 | +8.2 | +5.9 | +4.4 | +3.5 |
| gyroid | 0.600 | +39.8 % | +19.4 | +11.7 | +7.9 | +5.7 | +4.3 | +3.4 |
| Schwarz-D | 0.208 | +20.1 % | +11.6 | +7.8 | +5.6 | +4.2 | +3.3 | +2.6 |
| Schwarz-D | 0.407 | +20.5 % | +11.5 | +7.7 | +5.6 | +4.2 | +3.3 | +2.6 |
| Schwarz-D | 0.588 | +20.7 % | +11.4 | +7.6 | +5.5 | +4.1 | +3.2 | +2.6 |

- **Gyroid:** the error grows as the density falls.
- **Schwarz-D:** the error does not depend on the density.
- The 0.40 rows reproduce the 11-01 record (`lattice.cpp`'s curves): every error to the printed digit;
  the resolved stiffness within one unit of its last digit (the record solved 2-6 cells assembled, these
  matrix-free).

**Floor: the 2-cell rows came out steady for both sheets** (README, `steady.csv`; criteria fixed before
the long runs), so the measurement supports a Structural floor of 2 cells. That is 8.7 mm (gyroid) and
10.8 mm (Schwarz-D) at the smallest cells. The lead and TOReview set the number.
`sheet_width_floor_measured` returns 2 for both.

**Caveats, carried:**
- The rows are still rising with pitch, so they are lower bounds.
- The interlayer factor 0.55 is unsourced (above). The interlayer law was measured with the build
  direction on a cube axis.
