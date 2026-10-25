# Core proposal: KEEP regions, exported exactly (TO-core, 2026-10-25, for a ruling)

His request (2026-10-25, after the Carriage Arms samples): "instead of considering it as 'protect', can you look at it
as 'keep'? Keep this part of the model, keep that part, leave this part empty, do whatever you want there. This way we
keep the perfect flat pieces and holes." Nothing here is built.

## What he saw, and why

- The bottom drum pocket floors (faces 4, 146) were carved in his live +10 % run and in the first strengthen sample:
  about 220 mm² of each 680 mm² floor left flat at z = 103, the rest dug up to z ≈ 112. Only Keep Clear discs covered
  them, and a Keep Clear never touches the part's own material: it neither removes it nor keeps it
  (`clearance.cpp` rasterizer guard). Protecting faces 4 and 146 fixed it (sample-2: 513 mm² flat, nothing carved).
- Holes and the rims around protected holes come out octagonal. A protection is a skin of whole voxel layers
  (`mask_step_face`), and the export is a marching-cubes surface of the voxel field, so a kept rim's inner edge is a
  voxel staircase. CAD-face projection snaps vertices onto the faces they came from, but a kept region's boundary inside
  the material is no CAD face.
- He cannot put two roles on one face in the app (Protect + Keep Clear, Keep Clear on a load or anchor). Core already
  accepts it: routed to #354's APP LIST on 2026-10-25.

## Proposal

Three roles, the classic split of a design space:

| Role | Optimizer | Export |
|---|---|---|
| KEEP | FrozenSolid, as a protection is today | the kept region's EXACT CAD geometry |
| CLEAR | FrozenVoid over air, as a Keep Clear is today | nothing |
| FREE | design space (the box / primitives) | the optimized surface |

Precedence as today: KEEP over CLEAR over FREE.

1. **A KEEP primitive.** Item 7's primitives `{shape: box | cylinder, sign, min, max, axis}` gain `sign: "keep"`:
   "keep the part's own material inside this primitive, exactly". The voxels of (part ∩ primitive) are FrozenSolid,
   like a protection.
2. **Exact export.** For each KEEP primitive, core cuts the part's B-rep with it (OCCT `BRepAlgoAPI_Common`, a box or
   cylinder against the solid) and tessellates the result at the import tolerance. That gives true flat faces and true
   cylindrical holes. The file carries these exact shells OVERLAPPING the optimized shell. The slicer unions overlapping
   bodies, as the lattice export's interpenetrating soup already relies on (PR 201 print-certified). No mesh boolean is
   needed in core.
3. **Verification** stays as item 50 built it: the exported file (soup included) is re-voxelized and certified.
   Overlapping closed shells voxelize as solid under the winding fill.
4. **Face KEEP (depth, as Protect)** keeps its voxel skin. Exporting it exactly needs the face's offset solid, which is
   harder (open question 1).

## Core work, if ruled

- `job.cpp` / `job.hpp`: `sign: "keep"` on item 7's primitives (or a `keep_regions` list until item 7 lands).
- `loadcase.cpp`: rasterize part ∩ keep primitive -> FrozenSolid, attributed in item 40's `frozen_share` sources.
- `run_job.cpp` export: the exact keep shells (OCCT, STEP parts; a mesh part keeps its own triangles clipped to the
  primitive), appended to the variant file.
- Red-first test: a plate with bolt holes and a KEEP box around them. The exported hole vertices lie on the CAD radius
  within the tessellation tolerance (today they deviate by up to half a voxel), the kept face is flat to 1e-3 mm, and a
  job without a KEEP is byte-identical.

## Related, not in this proposal

- "Stay one piece": the optimizer has no connectivity constraint. Only the belt (every load reaches an anchor) and item
  47 (no anchor joined to a load as drawn is let go) are checked. So a part can split, as his arms did. A real rule is
  item 42 (research, on hold; Li 2016's virtual temperature is the candidate). Today a KEEP between the pieces holds
  them together.

## Questions for him

1. KEEP as primitives only, or also "keep this face N mm deep" exported exactly (needs the CAD offset of the face)?
2. Should CLEAR be allowed to remove the part's own material (a true "empty"), or stay air-only?
3. Is a file with overlapping bodies fine for his slicer, or must it be one merged shell (that needs a mesh boolean)?

## APP LIST (to #354)

A KEEP role on faces, regions and primitives; several roles per face; KEEP regions drawn as exact.
