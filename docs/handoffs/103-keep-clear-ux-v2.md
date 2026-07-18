# 103 — Keep-clear UX v2: visible, draggable clearance volumes + the attribute model

**Status:** Phase A shipped complete (attribute model + true-geometry red volumes +
live "Auto · N mm" labels + inline numeric editing that updates the volume live).
Phase B (drag-handle gesture layer) is **Blocked-stopped by design** — the handle
MATH ships as pure, headless-tested value types, but the gesture WIRING is not
shipped (see "Phase B" below). This is a maintainer-directed redesign of handoff
[100](100-clearance-regions-impl.md)'s app layer; the core rasterizer,
`ProductionLoadCase` schema, and the results honesty card are UNCHANGED.

## Why v2 (the design failure being retired)

A keep-out is a spatial judgement — "does the bolt-head volume collide with that
boss?" — and handoff 100 presented it as two unlabelled mm text fields and "Keep
clear" as a fourth role competing with Anchor/Load. In a tool whose interaction
language is *tapping geometry*, a clearance you cannot SEE is a clearance you
cannot reason about, and a keep-out modelled as a role you can't also anchor is a
category error. v2 makes the clearance a **visible red volume** and "Keep clear"
an **attribute** that rides alongside a selection's real role.

## THE ONE RULE still holds

No clearance declared → byte-identical to the pre-100 path. The wire format to the
bridge/CLI is UNCHANGED (the 0-sentinel: an un-overridden distance is sent as 0 and
the core re-derives it; a suppressed auto clearance is simply omitted). Proven:
`clearance_parity`, `production_parity`, and `clearance` core gates all green
(re-run this branch), and the app derivation test `testNoKeepClearMeansEmptySpecs`.

## Part 1 — expose the true geometry (bridge, additive)

The exact `topopt::StepFaceInfo` numbers the core rasterizer freezes now cross the
bridge so the app draws from the SAME axis/radius/normal the run uses — never an
app-side tessellation fit that would picture a *different* object.

- `TopOptBridge.hpp` `ImportedMesh` gained flat per-face arrays (indexed by face
  id): `face_kinds` (0=Plane, 1=Cylinder, 2=Other), `face_cyl_radius`,
  `face_axis_point`, `face_axis_dir`, `face_plane_normal`, `face_plane_origin`.
  Empty for STL. `bridge.cpp` `to_imported` populates them from `model.faces`
  (`import_step` passes `&model.faces`; STL passes nullptr). Purely additive — no
  behaviour change to import.
- Swift: `TopOptKit.StepFaceGeometry` (kind + radius + axis/normal), carried on
  `ImportedMesh.faceGeometry` and threaded onto `ViewerMesh.faceGeometry` +
  `ViewerMesh.faceGeometry(_ faceID:)`. `ViewerMesh` also gained `faceAxialSpan`
  (bore through-part span from the SAME tessellation the core reads) and
  `facePlaneOutline` (the slab footprint).
- With the radius exposed, "Auto" labels show the REAL derived numbers
  (`ClearanceSuggestion`, mirroring `clearance.hpp`: margin = bore radius, axial =
  bore diameter, slab = 3 mm) — e.g. **"Auto · 2.5 mm"** instead of the word "auto".
  The 0-sentinel to the core is untouched; only the DISPLAY upgrades.

## Part 2 — the attribute model (app)

"Keep clear" is an ADD-ON, not a role. `ForceModel.GroupKind` keeps only
`.pending/.anchor/.load` as roles; a new `KeepClearAffix` (`.on` / `.suppressed`)
map stores only DEVIATIONS from the default (an anchored bore auto-clears; nothing
else does). Absence follows the auto rule.

- `keepClearIsOn(_:autoDefault:)` / `keepClearOrigin` / `setKeepClear(_:on:autoDefault:)`
  are the effective-state API; the auto rule (anchor + bore) lives in
  `ProjectModel.autoClearanceApplies` (it needs the mesh). `isKeepClearOnly` marks a
  bare selection that has only the affix — a complete declaration that never blocks
  Optimize (`hasPending` excludes it).
- **Auto-suppression override:** toggling an auto bore OFF stores `.suppressed`, so
  `clearanceSpecs()` omits it — "sent as such" by absence, wire format unchanged.
- **Migration:** a pre-v2 snapshot stored "Keep clear" as the `.clearance` ROLE.
  `ForceModel`'s custom `Codable` migrates it on decode (role → pending, affix →
  on), so old projects keep behaving. New snapshots never carry `.clearance`.
- UI: every Selections row gains a **nosign affix toggle** in its role line (shows
  "Auto" when auto-derived; tap to suppress/affix); the face-tap **Keep clear chip**
  now `setKeepClearAffix(.on)` (affixes, never re-roles — bare face → keep-clear-only);
  the Selections header gained a **Keep clear quick-action** for the active group.
  The mm editor shows **"Auto · N mm"** with a ↺ reset-to-Auto affordance.

## Part 3 — the visual volume (app)

- `ClearanceVolume` (pure value type): a swept `.cylinder` (radius = bore + margin,
  axial band from the tessellation span) or a bounded `.slab` (outline extruded by
  depth), or `.degenerate` (a Bolt on a non-cylinder face — the same safe no-op the
  core produces). Built by `ProjectModel.clearanceVolumes()` from the exact bridge
  geometry + the SAME resolved distances the run freezes (an un-overridden distance
  resolves to the Auto suggestion, never 0, so the drawn cylinder IS the run's).
- `MetalMeshView.setClearanceVolumes` tessellates them into translucent RED faces
  (~50% opacity, selected brightens to ~60%) + bright edges, in MODEL space under
  the mesh MVP so they settle with the part — the same blended, depth-tested
  `groundPipeline` pass the design box uses (the part occludes far faces; no depth
  write, so the volume never hides the part). Degenerate volumes draw nothing filled
  — an honest hollow; the row carries the existing "no effect" wording.
- Live: the affix toggle and the numeric field change the `ClearanceRenderItem` set,
  which re-tessellates immediately (Equatable-gated in the coordinator).

### Phase B (drag handles) — Blocked-stopped, by the phasing rule

The prompt authorised: "if the full drag-handle gesture layer is too deep for one
run, Blocked-stop Phase B with a design note and ship Phase A complete … Do not
ship handles that half-work." Taken:

- **Shipped:** `ClearanceDragMath` — pure screen-ray → mm-parameter math
  (`radialMargin`, `axialClearance`, `slabDepth`, built on line-line closest-approach
  primitives), with headless unit tests. This is the Phase B foundation.
- **Not shipped:** the gesture WIRING (hit-testing which handle a touch is on,
  per-frame camera-ray construction, the live drag label, writing the override
  mid-drag). It is device-QA-only (no simulator/headless way to verify the touch
  path), and a half-wired handle is worse than none. A follow-up wires
  `ClearanceDragMath` to a `UIPanGestureRecognizer` on the projected handle anchors
  (cylinder wall / end caps / slab face), flipping the field from Auto → explicit on
  first drag. Numeric editing already covers the same value path in Phase A.

## Evidence

- **`xcodebuild` app:** `** BUILD SUCCEEDED **` (TopOpt iOS app, iPad Pro 11" sim).
  **Package:** `swift build` clean. **Runtime:** app boots to Home with no crash
  (validates the custom `ForceModel` decoder + SwiftUI changes at launch).
- **Headless tests:** package suite **467 tests, 0 logic failures, 1 skipped**. New:
  `ClearanceGeometryTests` (14 — suggestions match `clearance.hpp`; the bolt volume
  uses the exact radius + tessellation span; slab extrusion; degenerate honesty;
  drag-math on synthetic rays), `ClearanceDerivationTests` (7 — auto rule,
  auto-suppression override drops the spec, explicit plane slab, empty = no specs,
  override threading, volume uses the resolved Auto numbers), and the rewritten
  `ForceModelTests` keep-clear block (attribute-not-role, effective state +
  suppression, minimal-deviation storage, sync pruning, Codable, legacy-role
  migration).
  - Note: the macOS suite has an INTERMITTENT SIGTRAP in a GPU-touching test under
    parallel xctest workers — the crashing test WANDERS between runs (seen in
    PrintParamsTests, RemoteRunnerE2ETests) and every one passes in isolation and on
    a clean re-run (467/0). Environmental Metal/headless flakiness, not a keep-clear
    regression: the clearance render path is a no-op for those clearance-free tests.
- **Core gates (this branch):** `clearance`, `clearance_parity`, `production_parity`
  all PASS. No `core/` files changed (bridge reads the already-captured
  `model.faces`).

### Screenshot descriptions

Home renders clean (captured). The clearance-specific views below are described from
the shipped code + the exact-geometry unit tests; the Metal render pass itself is
device-QA-pending (built to the proven design-box pattern, not visually confirmed on
device this run, and the full STEP-import + face-tap flow isn't reliably automatable
in the simulator):

- **Bore with its red swept cylinder + "Auto · 2.5 mm":** an anchored Ø5 bore shows
  a translucent red cylinder filling the hole and protruding a bore-diameter past
  each face (radius = 2.5 + margin 2.5 = 5.0; unit-tested). Its Selections row reads
  **Anchor**, a red nosign **"Auto"** affix beside it, and under it
  **margin Auto · 2.5 mm · axial Auto · 5 mm**.
- **Dragged margin showing the live value:** Phase B — NOT shipped (design above).
  The same value is set today by typing in the margin field, which flips it from
  "Auto · 2.5 mm" to the explicit number and grows the red cylinder immediately.
- **Slab on a mounting face:** an explicit Keep-clear on a planar face draws a red
  slab the size of the face outline, extruded 3 mm outward along the outward normal;
  row shows **Keep clear** with **slab Auto · 3 mm**.
- **Affixed anchor row:** an anchored bore row shows **Anchor** + the red **Auto**
  nosign affix; tapping the affix turns it grey (suppressed) and the red cylinder
  disappears from the viewport — the auto clearance is dropped from the run.

## Deferred / honest limitations

- **Phase B gesture layer** — Blocked-stopped (above). Numeric editing is the shipped
  value path.
- **Metal render** — device-QA-pending; mirrors the shipped `setDesignBoxes` pattern.
- **Auto label for a multi-bore group** — uses the group's FIRST cylindrical face's
  radius as the representative number (one override applies to the whole group, as in
  100). Multi-radius groups are rare (a group is usually one hole).
- **Slab footprint** — the face tessellation's in-plane bounding RECTANGLE (100's
  choice), not the exact polygon.

## Files touched

Bridge: `TopOptBridge.hpp`, `bridge.cpp` (additive only). App:
`TopOptKit.swift` (StepFaceGeometry + convert), `ViewerMesh.swift`,
`ProjectModel.swift`, `ForceModel.swift`, `ClearanceGeometry.swift` (new),
`MetalMeshView.swift`, `WorkspacePlaceholder.swift`. Tests:
`ClearanceGeometryTests.swift` (new), `ClearanceDerivationTests.swift` (new),
`ForceModelTests.swift`. No `core/`, fixtures, ROADMAP, or ARCHITECTURE changes.
