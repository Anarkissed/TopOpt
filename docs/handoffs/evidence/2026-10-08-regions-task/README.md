# The Regions task (2026-10-08): union patterns, Dissolve, the scratchpad, the Region tool, the render seam

The reviewer's rulings of 2026-10-08, approved by the maintainer:

> 1. #358 adds a parts list for unions. Write unions with it once it lands; keep the strict defect
>    controls until then. Pattern on a face inside a union splits the WHOLE union.
> 2. Dissolve: the faces go back to the group they came from.
> 3. The Surface scratchpad carries groups, so Dissolve reverts cleanly.
> 4. A new "Region" tray tool: approved.
> 5. The test-only offscreen render seam: approved.

## What changed

1. **Pattern on a union.** `FaceRegionModel.splitUnion` handles it.
   - The grid is laid on the tapped face, inside the leaf of the union under the finger. Its cells'
     half-spaces cut EVERY leaf of the union.
   - Each cell becomes either:
     - a union of its pieces across the parts (it owns them), or
     - the lone piece, when the cell reaches only one part.
   - The preview prices every part, leaf ∩ cell by area. It used to price only the tapped face, so
     the ✓ was on for cells that held nothing.
   - **Meaning chosen:** the division is the tapped face's grid, extended across the union. It is
     not a grid sized to the union's whole extent. Because the grid runs through the arc/spine system
     per face, a union-wide grid would need a new grid design; I can do it if wanted.
2. **Dissolve** (`SurfaceDissolve`, shared by the Regions sheet and the Region tool):
   - The faces go to the group that held the region, or its nearest ancestor. They never go to the
     active group.
   - A union gives back its parts, under the parents recorded in `FaceRegion.partParents`.
   - No dropped id is left in any group.
   - A cut piece is refused; Undo split is the way to take a cut back.
3. **The scratchpad** (`SurfaceScratch`) now holds the whole group layer: every group's faces and
   regions, the active group, and the force model.
   - A group the session swept comes back with its role, load and protection
     (`ForceModel.restoreEntries`, which mirrors `sync`'s stores; the mirroring is pinned by a test).
4. **The Region tool** is the sixth tool in the tray.
   - A tap aims at a region. It never makes one.
   - The cluster shows the aimed region's name and count, plus three verbs, each only where it
     applies: ↖ (the region it was cut from), Undo split, and Dissolve.
   - Once aimed, a tap adds or drops a face. This works on whole face regions only, and never drops
     the last face; otherwise the tool says why.
   - A selected union of pieces now lights piece by piece (`SurfaceTint.unionLighting`, the Union
     tool's half-space chains). Before, it lit every face whole.
5. **The render seam** (`SurfaceStageRenderSeamTests`, test-only). The stage's own inputs go through
   `MeshRenderer` offscreen; there is no view and no production code for it.

## The pictures (the seam; the three-face fixture; a union of faces 1 and 2 patterned 2 × 1)

- `union_cell_0_lit.png` — cell 0 selected: 4,963 selected-blue pixels, mean x 181.
- `union_cell_1_lit.png` — cell 1 selected: 5,854 pixels, mean x 274.
- `union_cell_0_lit_WHOLE_before.png` — the old lighting (the union lit whole): 10,817 pixels.
  That is exactly the two cells together.

## Still standing

- **A union on the wire** (`SurfaceUnionDefectControlTests`, defect 2, still strict). `face_regions`
  writes no parts, so core refuses any job holding a union. Waits on #358's parts list.
  - A pattern on a union makes more unions (its cells), so this now matters sooner.
- **The shader takes four piece chains of four planes** (`MeshRenderer.setCutPlane`; the Union tool
  has the same limit). For a selected union cell:
  - a fifth piece and beyond is under-lit (it reads as unselected);
  - a piece with more than four cuts is tested on its first four only, so it can spill past its own
    edge (over-lit).
  - The fixture's cells have 1–2 cuts per piece. An arc grid's lateral bounds can exceed four.
    Raising the limit is a shader change, not done here.
