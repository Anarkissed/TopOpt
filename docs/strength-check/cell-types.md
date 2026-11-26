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
| "Allow quilt" off, the whole rule (notes29b, his notes on release 20, 2026-11-25: "limit both when 'Allow quilt' is turned off"; "Are you saying that no matter what happens, all Small cells in thin walls are going to be quilted?") | no strut at or past the QUILT: the widest is one printed line short of it, touch x cell - one line width (`lattice_quilt_off_strut_mm`; the open look where that is wider, only on cells under about 3 mm with one-line struts); equally no cell under (strut + one line) / touch (`lattice_quilt_off_cell_mm`), anywhere, every mode | Ruled (the margin: one line width of air between the closest struts, the next printable step under the touch, so every gap prints open). The open look (0.1898, 4.74 mm cells) stays what the lattice lays on its own (Auto, the dial's 1, the band's aim, every wall that is not thin); only an ask past it (the dial past 1 = the app's Density past the open look, a typed strut, the ends in mm) goes on, up to the limit. "Small cells in thin walls" acts in THIN WALLS only (a wall the open look's cells cannot divide), with its own one cell down to the limit's cell (`CellSpec::small_in_thin_walls`); nothing else is laid smaller for it. K3's quilt fallback stays withdrawn. `test_lattice_quilt_holes` §1 (10 types x 9 asks) and §4 (the thin wall), `test_lattice_width_bounds` §7, each with its RED control. |
| Where each type becomes a quilt | per type, below: touch (struts fuse), channels (the void stops running through), see-through (square-on, nothing seen through) | **Geometry**, exact (`lattice_quilt_limits`, lattice.hpp), and **measured** again on a voxel grid of each type's periodic cell, 128 a side (`test_lattice_width_bounds` §6; a grid shuts a window early, so each measured value is under its exact one by at most two voxels). Touch is always first. The open look is under all three for every type: the octet's see-through, (sqrt 2 - 1)/2 = 0.2071, is the nearest. |
| A strut counted as a bridge (printed flat, square, level underside) | under 30 degrees above level | Ruled (`bar_is_bridge`, the 11-12 flat-bridge rule). |
| A bridge's reach (print rule e) | at most 5 mm past what holds it | Ruled: reviewer 2026-11-14 (`kBridgeReachLimitMm`, lattice_layout.hpp). |
| Interlayer strength factor (z_knockdown) | 0.55 | **Assumed** (core/src/materials/materials.json). Unsourced; Bembenek 2022 (Polymers 14:2446) measured 0.44 for PLA. A vertical strut is a stack of layers, so a type whose load runs up its columns (sc, and bccz / fccz if they are ever certified) reads about 25 % optimistic across layers on today's 0.55. Not changed here. |

## Per type

Strength laws are `*_cert` columns of `evidence/2026-11-09-lattice-type-strut-laws/<type>/kfit.csv` (octet:
`evidence/2026-11-17-octet-full-strut-law`; bcc, diamond and sc under their 11-09 floor:
`evidence/2026-11-25-strut-laws-low-density/<type>/kfit.csv`, with their low tensor rows, builder F), core/src/fea/strut_strength.cpp: per density, the worst strut von Mises
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
| Measured band (density) | 0.0496 - 0.9003 | 0.0951 - 0.5909 | 0.0938 - 0.5052 | 0.1724 - 0.5133 | 0.0387 - 0.5920 (measured 2026-11-25 under 0.1571) | 0.0319 - 0.5929 (2026-11-25 under 0.2105) | 0.0161 - 0.4964 (2026-11-25 under 0.0866) |
| Stiffness at the band's ends, C11 / C12 / C44 (MPa) | 36.3/18.4/17.2 - 3862/1765/1076 | 79.1/38.2/34.1 - 1345/444/392 | 69.6/44.6/8.76 - 1157/376/315 | 134/101/40.7 - 998/449/378 | 19.1/17.4/2.54 - 1223/557/521 | 14.6/14.3/13.4 - 1126/522/471 | 20.3/0.466/0.0629 - 1122/234/201 |
| Strut law at the band's ends, Kd / Kv | 108/57.1 (bulk only, a lower bound; no pass under 0.10) - 6.39/3.74 | 76.3/42.0 - 9.67/6.68 | 194/38.4 - 11.9/7.73 | 137/25.9 - 12.0/8.50 | 2202/160 - 11.7/7.08 | 9894/141 - 12.0/8.52 | 23636/242 - 20.9/9.15 |
| Interlayer law at the ends, Kild / Kilv | 68.8/46.0 - 2.37/2.11 | 66.4/42.9 - 8.67/7.76 | 170/44.9 - 8.37/6.37 | 95.9/25.5 - 12.9/7.85 | 1444/104 - 6.45/4.27 | 5658/120 - 14.2/8.04 | 4755/278 - 19.4/8.78 |
| Density at the open look (strut/cell 0.1898) | 0.3487 | 0.1937 | 0.1889 | 0.2920 | 0.1630 | 0.1630 | 0.0756 |
| Strut/cell at the band's floor | 0.0640 | 0.1279 | 0.1281 | 0.1394 | 0.0879 | 0.0794 | 0.0846 |
| Two-line strut credited up to | 14.1 mm cell | 7.04 mm | 7.03 mm | 6.46 mm | 10.2 mm | 11.3 mm | 10.6 mm |
| Touch, THE QUILT (neighbouring struts fuse: "Allow quilt" on's top; 100 % of the app's Density) | 1/(2 sqrt 2) = 0.3536 | 1/sqrt 3 = 0.5774 | 0.3536 | 0.3536 | 0.3536 | 1/sqrt 2 = 0.7071 | 1 |
| Channels close (geometry; voxel 128: measured) | 1/sqrt 6 = 0.4082 (0.3955) | 1/sqrt 3 = 0.5774 (0.5639) | sqrt 6/4 = 0.6124 (0.5996) | 1/sqrt 6 = 0.4082 (0.3955) | 1/sqrt 2 = 0.7071 (0.6961) | 0.7071 (0.6961) | 1 (0.9922) |
| See-through closes, square-on (geometry; voxel 128) | (sqrt 2 - 1)/2 = 0.2071 (0.1990) | sqrt 2 - 1 = 0.4142 (0.4089) | 0.3536 (0.3536) | 0.3536 (0.3426) | 0.3536 (0.3426) | 0.7071 (0.6961) | 1 (0.9922) |
| Smallest cell the open look lays (0.90 mm / 0.1898) | 4.74 mm | 4.74 mm | 4.74 mm | 4.74 mm | 4.74 mm | 4.74 mm | 4.74 mm |
| Smallest cell, "Allow quilt" off: the limit ((0.90 + 0.45) mm / touch; thin walls with Small cells in thin walls) | 3.82 mm | 2.34 mm | 3.82 mm | 3.82 mm | 3.82 mm | 1.91 mm | 1.35 mm |
| Smallest cell with the quilt (0.90 mm / touch) | 2.55 mm | 1.56 mm | 2.55 mm | 2.55 mm | 2.55 mm | 1.27 mm | 0.90 mm |
| Strut angles above level, cell upright (+Z up) | 0 (face diagonals: bridges, 0.71 x cell between nodes) and 45 | 0 (top-face diagonals: bridges, 0.71 x cell) and 45 | 0 (square windows: bridges, 0.35 x cell) and 45 | 35.26 (<111>) | 35.26 (<111>) | 35.26 (<111>) | 0 (edges: bridges, a full cell) and 90 |
| Self-support | 45 degree struts self-supporting; bridges level and short | as octet | as octet, its bridges half as long | every strut a round bar over the 30 degree cut-off, self-supporting | as rhombic | as rhombic | columns stand; every level edge is a bridge a whole cell long |
| Auto's cap | none applied (14.1 mm by its geometry; the octet's layouts stay as they were, R9) | 14.1 mm | 28.3 mm | none (no level strut) | none | none | **10 mm** |
| Structural | yes | yes | yes | yes | yes (every strut it lays without the quilt is in band since 2026-11-25) | yes (since 2026-11-25; `structural_note` clears itself) | yes (as bcc) |

| | bccz | fccz | reentrant |
|---|---|---|---|
| Cell (geometry, the family study's) | bcc + the corner z columns: 9 struts, 2 nodes | fcc's legs + the corner z columns: 13 struts, 4 nodes | S 4: four waists pulled in from the four side faces, each joined to its face's four corners, + the corner z columns: 17 struts, 5 nodes |
| Measured band, stiffness, strut law | none in core: tetragonal (C33 differs from C11), refused by the cubic certification (PR 246 measured their tetragonal constants; `hex8_stiffness_transverse` has no caller) | none (as bccz) | none (as bccz) |
| Structural | **refused**, one line (`structural_refusal`, type_not_supported) | refused | refused |
| Touch, THE QUILT | 1/sqrt 2 (bcc's; geometry) | 1/2 (3D; geometry) | 1/3 (3D; geometry; face view 1/sqrt 5) |
| Channels close (geometry; voxel 128) | 1/sqrt 2 (0.6961) | 1/sqrt 3 (0.5639) | 1/sqrt 2 (0.6961) |
| See-through closes (geometry; voxel 128) | 1/sqrt 2 (0.6961) | sqrt 2 - 1 (0.4089) | 1/sqrt 2 (0.6961) |
| Smallest cell the open look lays | 4.74 mm | 4.74 mm | 4.74 mm |
| Smallest cell, "Allow quilt" off: the limit ((0.90 + 0.45) mm / touch) | 1.91 mm | 2.70 mm | 4.05 mm |
| Smallest cell with the quilt | 1.27 mm | 1.80 mm | 2.70 mm |
| Strut angles, cell upright | 35.26 and 90 | 0 (bridges, 0.71 x cell), 45 and 90 | 41.81 and 90 |
| Self-support | as bcc; its columns stand | as fcc; its columns stand | the waist struts lean 41.8 degrees, over the 30 degree cut-off: round bars; the struts below a waist hold it up, the ones above lean out from it; a waist whose lower struts a wall cuts (they would start in the air) is not laid (lay_bars, 2026-11-25); its coupon prints clean |
| Auto's cap | none | 14.1 mm | none |
| Special axis | its z (the columns) is laid along the frame axis nearest up, so the columns stand up on any face (`cell_struts`) | as bccz | as bccz (its waists' axis) |

## Measured or assumed, in one list

- Measured on each type's own cell: the density band, the stiffness tensor, the strut law and the interlayer law
  (octet, fcc, kelvin, rhombic, diamond, bcc, sc). Not measured: anything outside each band (no credit there), and
  all three for bccz, fccz and reentrant (no certification).
- Geometry: each cell, its touch (the quilt), where its channels close and its view closes (measured again by voxels),
  its strut angles, its level struts' spans, Auto's caps.
- Ruled: the open look 0.1898, two lines, the 30 degree bridge cut-off, the 5 mm bridge reach.
- Assumed: the interlayer factor 0.55 (above).
- Not yet printed (his rule, "Not print-tested"): every type but the octet (8 mm, 2026-11-11) and bccz (8 mm,
  2026-07-29). Each type's print coupon: `topopt-cli lattice-coupon --topology <type> --out <folder>`
  (make_type_coupon: the 8 mm rim coupon's outline, two-line struts, a flat 2 mm plate fused in, print-checked).
