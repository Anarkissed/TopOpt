# Lattice preview — the grade, the outline, and why neither worked

Branch `claude/lattice-stage-repair-97a4f9`. Everything below was measured on his own
`M2_verticalStand`, through the production bake, not through a fixture that agrees with
itself.

## What he asked for

1. **Grade to fit shape.** Cells get smaller toward a face's outline so the lattice can
   follow arcs and straight lines and actually fill the space removed from the model.
   *"It's the shape of the face, not the depth."*
2. **A solid outline.** The shape fit's LAST STEP: when a cell can no longer shrink and
   still print, the remainder becomes solid, tracing the face's outline.
3. **The main cells as large as possible** — the grade is a border, not a takeover.
4. **The quilt must never appear**, including mid-calculation.

## The bugs, in the order they were masking each other

Each one was individually sufficient to make the grade invisible, which is why fixing
any single one changed nothing on screen.

1. **The ceiling was sampled in the wrong index space.** `cellField` returns a grid at
   CELL spacing (~6 mm); the boundary-distance array is on the OCCUPANCY grid (1.72 mm).
   Indexing one with the other's `i` passed the bounds check — the cell grid is smaller —
   and read unrelated voxels. The ceiling was noise.
2. **The distance was measured in 3-D.** On an 11 mm wall the nearest boundary is the
   wall's own face almost everywhere: p50 3.44 mm, max 5.16 mm, no in-plane variation.
   In-plane it is p50 12.03, max 38.05. Graded by the 3-D field, 28 of 964 cells moved.
3. **The member floor was tested at the BASE cell.** `thickness / cell >= N*` decided
   activation with the coarse cell, so cells near the outline were switched OFF before
   grading ran — and grading only assigns sizes to survivors. The band that most needed
   fine cells was the band being deleted.
4. **The band was counted in the wrong cells** — first base cells (4 x 6.0 = 24 mm on a
   38 mm face: the fine cells took everything), then finest cells (4 x 1.5 = 6 mm: a
   border 3% of the face). It is MILLIMETRES now, his ruling, and it cannot drift when
   the cell changes.
5. **The ramp was rounded**, so with `nCap = 2` — what his printer and density band
   actually allow — `round(2 - t)` only reached 2 for `t <= 0.5`. A 10 mm band graded
   5 mm and touched 4.6% of the face.
6. **The cell size was never derived from his part.** `wallWidthAlongNormalMM` walked
   `scene.occupancy`, which is ALREADY `LatticeRegionMask.clipped(solid, to: regions)`.
   The walk stopped at the region's own cap planes and returned THE DEPTH HE TYPED.
   Every cell ever shown was `depth / floor`: 12 -> 6.00, 11 -> 5.50, 13 -> 4.33. It now
   walks `partSDF`.
7. **The solid outline was driven by the region's DEPTH.** A face region is an extrusion,
   `q = (inPlane, along)`, so `dRegion` reaches 0 at the depth caps as much as at the
   outline — it banded the wall's front and back surfaces. Four shader attempts all
   failed on this. It is now decided in the CELL FIELD from the in-plane distance, where
   an inactive cell already renders solid.
8. **The same-lattice neighbour test was vacuous on stepped.** It compared the dyadic
   LEVEL, and `steppedCellField` writes level as all zeros. Every neighbour passed
   whatever its size, so a 6 mm cell's neighbourhood pulled in 2 mm cells and evaluated
   their struts in the wrong normalised frame — mixed geometry exactly at the grade
   transitions. It compares the stepped CELL SIZE now.
9. **The mid-bake quilt is the PREVIOUS lattice** drawn against the new settings. Gated
   twice inside the renderer, where nothing looks stale (scene and cell field are
   consistent with each other during a CPU bake). The staleness is only visible at the
   app level, where `strutBakeInFlight` already exists.

## Two things that are physics, not bugs

* **The ladder depth is `cell / finest printable cell`.** At a 0.45 mm bead a 4.5 mm cell
  gives `nCap = 2` — ONE step. A 2.25 mm cell already needs ~42% density for one
  extrusion across a strut; halve again and it needs ~167%, past any band ceiling. The
  wizard now says how many sizes are available and names the levers.
* **A finer cell at fixed density is a thinner strut.** Grading the cell down without
  raising the density drew a 0.16 mm strut on his back wall. The bake now lifts each
  graded cell's demand to whatever keeps one extrusion across its struts, and backs the
  cell off if the band cannot reach it.

## Retracted

* "Inactive cells render as holes" — they render SOLID (`F = anyActive ? ... : dClip`).
* "The axis-alignment guard rejects his curved wall" — both his regions are axis-aligned
  and got in-plane fields (`nonNil=2`, `dmax=38.0`).
* The skin reader-split (region field for the shell, skinned field for the march) was
  REFUTED by `LatticeFaceOutlineTests.testTheSkinLeavesASolidWallAtTheSurface` and
  reverted: the shell discards where the field is negative, so it is the POSITIVE skin
  band that makes the shell survive, and that band IS the solid skin. Both readers want
  the skin.

## The skin asymmetry — FOUND

It was never present-or-absent. The DRESSING BAND — the width of the rim/skin work — was

    float band = max(0.12 * cellHere, 1e-4);

a fraction of the LOCAL CELL. His two walls derive different cells, so out of ONE bake a
12 mm wall got a 1.44 mm band and a 6 mm wall got 0.72 mm: half the skin, same settings,
nothing in the project differing. His two taps read "Rim & skin" at a 12.00 mm cell and
"Interior fill" at 6.00 mm — the finer wall's band was half as wide and the tap fell
outside it.

It would have got worse: the shape fit now grades the cell WITHIN a face, so the band
would breathe across a single wall too.

A finish is a physical thickness, so the band is now `faceSkinMM` (off the wall ring),
floored at two extrusions, carried in `rimParams.x` — the slot freed when the
depth-driven solid rim was removed. `LatticeDressingBandTests` pins it, matching on the
ASSIGNMENT rather than the literal, because the first cut of that test failed on the
comment explaining the defect.

★ AND THE LESSON: I spent four rounds on the geometry that GENERATES the skin. The bug
was in the band that CLASSIFIES and DRAWS it. He said from the start that identical
settings producing two results is a coding problem, and he was right.

## Where to look next

* `LatticeRegionEmission` and `LatticeType` were read and found clean; the remaining
  unaudited surface is the ORGANIC path, which nothing here touched.
