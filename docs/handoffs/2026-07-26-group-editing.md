# Group editing — manual primitives, deletion, group lock

**Date:** 2026-07-26
**Scope:** core (C++) + bridge (C++/Swift) + app (SwiftUI). The manual-geometry path
travels end to end: `clearance.hpp` → job schema → `BridgeLoadCase` → `ClearanceSpec`
→ the Selections UI.
**Evidence:** `evidence/2026-07-26-group-editing/`

## The problem (user, testing an STL on device)

The hole finder OVER-finds and MISSES in the same session: one group came back
"8 primitives · synced" sprawling far past a small bracket; another showed Bore rows
reading blank "— mm Auto". The user needed a manual escape hatch in BOTH directions
and could not get back into a group to fix anything.

## The real work: a manual-geometry path (BLOCKED-STOP resolution)

`core/include/topopt/clearance.hpp` already defined the two shapes needed
(`ClearanceKind::Bolt`, `ClearanceKind::Face`), but the header's contract said the
geometry is "derived exactly from the B-rep". Confirmed at every layer: a clearance
was `{face_id, kind, distances}` and the axis/radius/normal/outline came ONLY from
`model.faces[face_id]` + that face's tessellation triangles. **The schema could not
express user-supplied geometry, and could not express "this auto-found primitive was
deliberately removed."**

Per the BLOCKED-STOP clause, here is exactly what was missing and the change made
(the BUILD section mandates the manual path, so this is resolved by *extending* the
schema, not stopping — no side channel):

1. **Manual geometry.** A clearance entry may now carry a `geometry` object INSTEAD
   of a `face_id`. Exactly one of the two (an XOR the parser enforces):
   - bolt: `{ axis_point:[x,y,z], axis_dir:[x,y,z], radius_mm, half_length_mm }`
   - face: `{ origin:[x,y,z], normal:[x,y,z], half_u_mm, half_w_mm }`
   The `kind` and all editable distance fields (`concentric_margin_mm`,
   `axial_clearance_mm`, `slab_depth_mm`) are unchanged and shared by both sources.
2. **Deletion.** A deleted auto-found primitive is expressed *by omission* — the app
   simply does not list that face's clearance — and the decision persists in a
   sidecar so it stays deleted across re-import (below).

### Core: resolve / rasterize split (what makes B2 provable)

`mask_clearance_region` was split into (`core/src/voxel/clearance.cpp`):
- `resolve_clearance_from_face(model, face_id, params) → ClearanceGeometry` — the
  AUTO path (derives axis/radius/span or origin/normal/extent from the B-rep).
- `resolve_clearance_manual(ManualClearanceGeometry, params) → ClearanceGeometry` —
  the MANUAL path (same growth math applied to user-supplied base geometry).
- `rasterize_clearance(grid, part, offsets, ClearanceGeometry, out)` — the shared
  rasterizer both paths funnel through.
- `mask_clearance_region(...)` is now a byte-identical wrapper = resolve_from_face +
  rasterize, so every existing caller/test is untouched (**BAR B4**).

Because an auto and a manual primitive of identical geometry resolve to the same
predicate and take the same rasterizer, they produce an identical mask *by
construction* (**BAR B2**). The masks are asserted bit-for-bit equal in
`test_clearance.cpp`.

Threaded through: `ProductionLoadCase::Clearance` (+`manual`/`manual_geom`),
`JobClearance` (+geometry fields), `job.cpp` parse (XOR rule), `run_job.cpp`,
`loadcase.cpp` (manual → resolve_manual + rasterize; auto path's out-of-range skip
preserved verbatim).

### Bridge

- `BridgeLoadCase` (on-device POD) gained parallel `clearance_manual` +
  stride-3 geometry arrays; `bridge.cpp` unflattens them into
  `ProductionLoadCase::Clearance`.
- Swift `ClearanceSpec` gained `manual: ManualGeometry?` + `.manualBolt`/`.manualFace`
  factories; `minimizePlasticLoadCase` flattens them into the POD;
  `RemoteRunner.buildJobJSON` emits the `geometry` object (or `face_id`), matching the
  core XOR rule.

## App

- **`ManualPrimitive`** (`ManualPrimitive.swift`): a user-placed primitive in model
  space, stored per-group in `ForceModel.manualPrimitives` (Codable, part of
  `EditSnapshot`, so undo/redo is automatic — **BAR B5**). `ProjectModel.clearanceSpecs`
  emits them unconditionally as manual specs; `resolvedClearances` renders them through
  the same `ClearanceVolume` path via a synthetic `StepFaceGeometry`.
- **Deletion** (`ForceModel.suppressedClearanceFaces`): the "−" on an auto row
  suppresses that face's keep-out (dropped from the run by omission) WITHOUT removing
  the face from its group — it may still anchor. Works on auto-found primitives (the
  more-used half). Undo covered (it's in `ForceModel`).
- **Magnetic detents** (`ManualPrimitiveDetent`, pure): moving a primitive snaps its
  AXIS to the world principal axes or a nearby primitive/bore axis (within 8°), and
  its CENTRE onto a bore axis point / another primitive / co-axial with a parallel
  axis line (within 3 mm). Each snap is reported with a label ("world Z axis",
  "bore axis", …) so the UI states what it snapped to and why.
- **Group lock + name-only rename** (`WorkspacePlaceholder.swift`): tapping the group
  BODY locks into it (`setActive`) and never starts a rename; rename fires only from
  the group NAME (`groupNameControl`). The "+" appears under the trash icon once
  locked and asks Cylinder/Plane; each primitive row (auto and manual) gets a "−".
  Tapping empty Selections-area space leaves the group. (**BAR B6**.)

## B3 — deletion sticks (where the decision persists, and why this pattern)

Deletions + manual primitives persist in `ForceModel` (the session/project copy) AND
in a **sidecar** written next to the working-copy file:
`<model>.clearances.json` (`ClearanceSidecar.swift`), auto-applied on import — the
paint `model.faces.json` pattern.

**Deviation from paint, deliberately:** paint's sidecar is written *core-side* because
it must re-segment geometry. The clearance sidecar is **app-authored JSON, read/written
directly** — because the RUN already receives the correct resolved set through job.json
(a suppressed face is simply not listed; a manual primitive ships its inline geometry),
so the CLI/worker never read this file. It exists ONLY so the APP remembers the user's
edits across a re-import — a pure app concern, no core coupling. This is the "show a
better one" the bar invites. A deletion survives a re-derive / resolution change (the
decision lives in `ForceModel`, and `clearanceSpecs` is resolution-independent) and a
re-import of the same file (the sidecar re-suppresses on import).

## Bars

| Bar | Status | Where |
|-----|--------|-------|
| B1 field equivalence | ✅ | `test_job.cpp::test_clearances_manual` (core dict), `ManualPrimitiveJobTests` (app job.json diff) |
| B2 identical mask | ✅ | `test_clearance.cpp` — manual vs auto masks BIT-identical (bolt + face) |
| B3 deletion sticks | ✅ | `ManualPrimitiveTests` (suppression persists across re-derive; sidecar round-trip) |
| B4 byte-identical untouched | ✅ | wrapper unchanged; all pre-existing core + app tests green; auto job emits no `geometry` key |
| B5 undo/redo add/move/delete | ✅ | `ManualPrimitiveTests` — through the existing `UndoHistory`, not a parallel one |
| B6 group lock | ✅ | model invariants in `ManualPrimitiveTests`; UI gating in `WorkspacePlaceholder` (device-verified below) |
| B7 device-real | ⏳ | **maintainer step** — see below |

## Tests (all green)

- Core: `test_clearance` 28 checks, `test_job` 106 checks (`evidence/…/core-*.txt`).
- App: `ManualPrimitiveTests` (17) + `ManualPrimitiveJobTests` (4); the related
  suites (Clearance/Force/Project/Undo/Selection/JobJSON = 95 tests) stay green.

## B7 — device-real evidence (the maintainer's step)

Nothing here is done until the maintainer watches it work. Build the iPad app
(`app/scripts/build_core.sh` has already refreshed the vendored core), import the
STL that misbehaved, and check:
1. Tap a group → it locks in (highlight); tapping the body does NOT open a rename.
2. Tap the group NAME → rename field opens; edit + return commits.
3. "+" under the trash → Cylinder/Plane → a red keep-out appears at the model centre;
   drag it onto the part and confirm it snaps to a hole/axis (label shows the snap).
4. "−" on an over-found bore row → its red volume disappears; re-import the file →
   it stays gone.
5. Two-finger double-tap (undo) reverts add/move/delete; redo re-applies.
6. Tap empty Selections space → the group unlocks.

## Known follow-ups (not blocking)

- The results applied-clearances card reports a manual primitive's face id as `-1`
  (the sentinel). A friendlier label ("manual bolt") is a small display-only follow-up.
- Manual primitives are shown/edited inside the locked group; the compact (unlocked)
  summary still counts only auto primitives. Surfacing a manual count there is cosmetic.
