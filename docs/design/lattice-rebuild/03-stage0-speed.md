# Lattice rebuild — stage 0, first speed numbers

2026-11-10, LatticeReview. Measured on the Mac (6 fast cores). Not yet measured on the iPad.

## What was timed

A rough layout of the 2040 extrusion stand (127 × 28 × 70 mm, 4,454 triangles), read from its STEP file in place:

1. one octet grid over the whole part, centred;
2. the wall's width measured on the mesh at every cell;
3. every strut cut at the part's true surface, to 0.05 mm.

It uses the engine's own exact mesh distance (`MeshDistance`). It is not the layout of the rules: one cell size, no grading, no rim or skin, no file written. It answers one question: how long does measuring and cutting on the mesh take.

## Once per part

| Step | Time |
|---|---|
| Read and tessellate the STEP file | 193 ms |
| Build the distance index | 1 ms |

## A full new layout (what a cell-size change costs)

| Cell | Cells | Struts kept | 1 thread | 6 threads |
|---|---|---|---|---|
| 12 mm | 216 | 2,921 | 115 ms | 31 ms |
| 8 mm | 496 | 8,466 | 328 ms | 75 ms |
| 6 mm | 1,132 | 17,720 | 385 ms | 98 ms |
| 4 mm | 3,043 | 56,124 | 1,704 ms | 396 ms |
| 2.4 mm | 11,887 | 252,479 | 3,668 ms | 956 ms |

## What it means

- **A density or strut-width slider** does not move any strut, so it needs no new layout: only the widths change. That is smooth at any cell size.
- **A cell-size, anchor or angle slider** needs a full new layout. On the Mac that is 31 to 98 ms at 6 mm and larger (10 to 30 pictures a second) and 0.4 to 1 s at the finest cells. So: close to smooth for large cells, a short wait after the finger lifts for fine ones (rule P6, plan B).
- **Opening a part** costs about 0.2 s before the first layout.

## Known ways to make it faster, not yet done

- Cells wholly inside the part need no cutting at all (one check per cell instead of one per strut). On the stand most cells at 4 mm and below are of this kind.
- The wall measurement does not depend on the cell size; it can be done once per part and kept.
- The 4 mm row is slow partly because 4 divides 28 and 70 exactly, so many struts lie in the part's faces; the real layout never puts struts there.

## Not measured

- The iPad. Fewer fast cores than this Mac, so expect slower.
- Stepped and Default Grade packing, grading, rim, skin, and drawing.
- The other three reference parts.

The program and its raw output are kept outside the repo with the reference parts' setups.
