# Mesh selection safety net — paint mode + tighter segmentation (2026-07-24)

## The problem

On a shelf bracket, tapping a bolt hole also selected unrelated faces —
**including the top face the user meant to make the Load**. The 35° dihedral
segmentation (handoff 134) had merged regions a human reads as distinct, and the
only escape was to abandon the model. Auto-segmentation being wrong must never be
a dead end.

Root cause, reproduced and committed as a fixture
(`core/tests/fixtures/mesh/filleted_bore_plate.stl`): a **rounded** hole rim. Over
the fillet's 90° turn each facet step is well under 35°, so pure dihedral region
growing walks the chain `top face → fillet → bore` as ONE pseudo-face. A single
tap on the hole then grabs the flat top face too. `evidence/.../filleted_bore_before.png`
shows the whole top + rim + bore as one red region.

This handoff ships two things: **paint mode** (the guarantee — a brush selection
that overrides a bad segmentation) and a **tighter default segmentation** (the
"usually right" that reduces how often paint is needed). Everything is keyed on
the SAME `triangle_face` → `face_id` contract, so nothing downstream changed.

---

## 1. Paint mode — the safety net (primary deliverable)

A painted selection is **just a set of triangles → a pseudo-face id**. Brush over
the surface to add triangles to the active group; the erase modifier removes
them. The painted face is minted ABOVE the imported face count, so it is a face id
like any other — tagging, clearance, the design box and the optimizer are
untouched.

### How a painted face crosses the STATELESS bridge

The bridge re-imports the STL from disk on every tag / mask / clearance / run
call and re-segments it — nothing is held in memory. So paint (and a tuned
threshold) must travel WITH the file. The mechanism is a **self-describing
sidecar**, exactly the trick the unit handling already uses (bake it into the
app-owned working copy once; every stateless call re-reads a file that is already
correct):

- `core/include/topopt/face_overrides.hpp` + `src/io/face_overrides.cpp` — a
  `FaceOverrides { dihedral_threshold_deg, planar_region_cone_deg, paint_faces }`
  and a deterministic **line-based text sidecar** (`<model>.stl.faces`, no JSON
  dependency). `apply_face_overrides(StepModel&, ov)` appends each painted
  triangle set as a new pseudo-face (reassign `triangle_face`, append a
  `fit_pseudo_face` StepFaceInfo, bump `face_count`).
- `import_part_file_resolved(path)` = `import_part_file` + sidecar. It is the ONE
  choke point every stateless consumer now routes through:
  - `core/src/cli/run_job.cpp` (the RUN),
  - `bridge.cpp` `tag_step_face` / `mask_step_face` / the load-case import (live
    tagging + keep-clear),
  - `bridge.cpp` `import_part` (the display import — the faces the app draws and
    picks are the ones the run will resolve).
  With no sidecar it is byte-for-byte the old import, so STEP jobs and un-painted
  mesh jobs are unchanged.
- `bridge.cpp` `write_face_overrides` + `TopOptKit.writeFaceOverrides` persist the
  sidecar (an empty/default call DELETES it, so cleared paint leaves nothing
  stale). `fit_pseudo_face` was factored out of `segment_mesh_faces` so a painted
  region gets the same plane/cylinder classification a native one does.

**Proven end-to-end** (`test_face_overrides.cpp` + `PaintTests`): a painted face
tags the exact same voxels as the equivalent native face ("painted == tapped"),
and a painted face survives a resolved re-import through the real bridge with the
same triangles — i.e. it optimizes through the mesh path identically to a tapped
group. This is the BAR.

### App side (all pure / headlessly tested)

- `PaintModel.swift` — the triangle→painted-id overlay: `apply(.add/.erase)`
  returns an exactly-invertible `PaintEdit`; deterministic (ascending, no-op
  strokes elided); `effectiveFaceIDs(base:)` for the highlight/picker;
  `exportRemap` packs live painted ids (which may gap after a full erase) to the
  dense ids a re-import assigns.
- `PaintHistory.swift` — the undo/redo stack of `PaintEdit`s. This is the seam the
  undo/redo task adopts: a painted stroke IS one undo step, already invertible.
- `PaintInteraction.swift` — `BrushHitTest` (front-facing triangles under the
  brush disc, deterministic) and `TapSelection` (see §3).
- `WorkspaceInteraction.swift` `WorkspacePaint.stroke` — the pure router (mirrors
  `WorkspaceTap.route`): add mints/uses the active group's one painted face; erase
  drops it from the group when emptied.
- `PaintController.swift` — the `ObservableObject` the viewer binds to (brush
  radius, erase/active flags, undo/redo, `persist()`).

**Remaining (needs the simulator, deprioritized this pass):** the SwiftUI
`DragGesture` + Metal tint glue in `WorkspacePlaceholder`/`MetalMeshView` —
`DragGesture → BrushHitTest.triangles → PaintController.stroke(triangles:selection:)
→ persist()`, and feed `effectiveFaceIDs` into the highlight tint. The decision
layer it calls is done and tested; only the gesture recogniser + tint buffer +
toolbar toggle remain, and those need on-device QA to trust.

---

## 2. Segmentation quality — the "usually right" default

The 35° threshold is now **tunable** (`SegmentOptions::dihedral_threshold_deg`,
persisted in the sidecar), and a second-stage **planar-cone guard**
(`planar_region_cone_deg`, default 40°) cuts the specific leak:

> When a region's maximal coplanar patch (grown at `plane_tolerance`) is a real
> flat FACE — at least 3 triangles AND walled by at least one genuine crease
> (≥ 8°, not just the shallow facet steps of a curved surface) — the region may
> only absorb further triangles within the cone of that plane's normal. A flat
> face grows to its fillet and stops; a barrel or blob (curved patch, no crease
> wall) never arms the guard and is never fragmented.

Deciding from the coplanar PATCH, not the seed triangle, makes it independent of
which triangle happens to seed the region.

**Measured** (`evidence/.../segment_sweep.txt`):

| mesh | before (cone off) | after (default) |
|---|---|---|
| filleted-bore fixture | **3 regions, top+bore ONE region (leak)** | **4 regions, top & bore SEPARATE** |
| ref1 L-bracket (CAD STL) | 10 | 10 (unchanged) |
| ref2 printables bracket | 7 | 7 (unchanged) |
| ref3 organic blob | 1 | 1 (unchanged) |
| 12-gon / 8-gon / chamfer bounds | 3 / 10 / 7 | 3 / 10 / 7 (unchanged) |

Because it changes NO reference id, existing sharp-edged mesh projects keep their
persisted pseudo-faces; only a part that WAS leaking (already unusable)
re-segments. Before/after renders: `filleted_bore_before.png` (all red) vs
`filleted_bore_after.png` (**red top = Load face, blue hole**). This is the
"Load face selectable alone" bar, met by the default segmentation via a normal tap
— paint is the guarantee if a part still segments wrong.

Not chasing perfection: a fillet smoother than ~2× the crease threshold per facet
is geometrically indistinguishable from intended curvature and won't arm the
guard — that's what paint mode and the tunable threshold are for.

---

## 3. Selection feedback — pre-highlight before commit

`TapSelection.preview(mesh:camera:aspect:point:)` returns the EXACT faces a tap
would select (the picked pseudo-face expanded by the hole face-loop), using the
SAME resolution the commit uses, so the viewer can pre-highlight exactly what will
be added and the user is never surprised by an over-select. `triangles(forFaces:)`
gives the triangle set to paint as the pending highlight. (Wiring the pending
highlight into the Metal tint is part of the SwiftUI seam in §1.)

---

## Evidence & self-run

- **Headless renders**: `evidence/2026-07-24-mesh-selection-paint/` —
  `filleted_bore_before.png`, `filleted_bore_after.png`, `ref1/2/3.png`,
  `segment_sweep.txt` (reproduce: `cmake --build core/build --target
  segment_evidence && ./core/build/segment_evidence <out> core/tests/fixtures`).
- **Committed fixture**: `core/tests/fixtures/mesh/filleted_bore_plate.stl`.
- **ctest**: `67/67` (was 66; +`face_overrides`). `test_segment` +9 checks
  (planar-cone no-op on references, leak/fix on the fixture, determinism);
  `test_face_overrides` 20 checks (sidecar round-trip, painted==tapped voxel
  tagging, resolved re-import determinism).
- **swift test**: `714/714` (3 skipped), incl. `14` new `PaintTests` (PaintModel/History
  determinism, brush hit-test, tap preview, WorkspacePaint routing, and the
  paint→sidecar→resolved-reimport end-to-end through the real bridge). No
  regressions.

## Files

Core: `segment.{hpp,cpp}` (tunable threshold + planar cone + `fit_pseudo_face`),
`face_overrides.{hpp,cpp}` (new), `part.cpp`/`run_job.cpp` (resolved import),
`test_segment.cpp`, `test_face_overrides.cpp` (new), `segment_evidence.cpp`
(fixture + before/after), `CMakeLists.txt`.
Bridge: `bridge.cpp`, `TopOptBridge.hpp` (resolved import + `write_face_overrides`),
`TopOptKit.swift` (`writeFaceOverrides`).
App: `PaintModel/PaintHistory/PaintInteraction/PaintController.swift` (new),
`WorkspaceInteraction.swift` (`WorkspacePaint`), `PaintTests.swift` (new).
