# Gravity direction — round 2: face detents, movable magnetic base, stubby arrow, edit-only

Branch `claude/gravity-direction-face-detents-e925c5` (app-only). Fixes the four ways PR 199's
gravity-direction widget was unusable on a real part. Extends the round-1 widget
(`docs/handoffs/2026-07-26-gravity-direction.md`) and reuses the PR 205 transform gizmo.

**Forbidden dirs untouched:** no `core/`, no solver, no solver default. `git status` shows only
`app/TopOptKit/Sources/TopOptFlows/{ForceModel,GravityDirectionGizmo,ViewerMesh,WorkspacePlaceholder}.swift`,
the test file, one dev-only seed helper, and this evidence dir.

## The four changes

### 1 — Detents snap to the PART'S OWN FACES, not the model axes  ★
PR 199 snapped to the six signed principal axes, on the theory that in model space those *are*
the bounding-box normals. On the maintainer's imported bracket that never engaged — its large
seating faces are ~44° off every axis (measured: two flat faces of area ≈4438 mm² at 43.9° off
axis), so pointing at one landed >12° from every axis → no snap → "Gravity set · custom".

Now the tip snaps to the part's actual flat-face normals.
- **Candidate selection** (`ViewerMesh.flatFaceNormals`): group the tessellation by per-triangle
  face id (STL pseudo-faces *or* STEP B-rep faces). For each face accumulate `Σ(cross)` — a vector
  whose length is 2× the *flat-projected* area and whose direction is the area-weighted normal —
  and `Σ|cross|` (2× total triangle area). Their ratio is a **flatness** score: 1 for planar,
  →0 as the face curves (opposing facet normals cancel in the vector sum), so bores/fillets are
  rejected. Keep faces with flatness ≥ **0.9** and area ≥ **2%** of the largest flat face; merge
  near-parallel normals within **6°** (keep the larger); cap to 32. A mesh with no face ids (an
  optimized result) yields none → axes-only fallback.
- **Snap tolerance: 12°** (unchanged from round 1). Principal axes are kept as *additional* cheap
  detents, listed FIRST so a face that happens to be axis-aligned reports the clean axis label.
- **Exactness (V2):** a snapped direction is the EXACT candidate vector — bit-for-bit the face
  normal, or bit-exactly `(0,-1,0)` for an axis — never `0.9999…`.

### 2 — The arrow BASE is movable via the transform gizmo, and magnetically attaches to any face
The round-1 arrow was pinned at the mesh centre. Now the arrow's base carries the SAME 3D
raymarched liquid-glass transform gizmo the manual primitives use (`TransformGizmoMetalView` +
`TransformGizmo.pick`, PR 205). A drag SDF-picks a translate handle and slides the base; while the
magnet is on the base snaps to the nearest mesh surface point within `radius·0.4`
(`ViewerMesh.nearestSurfacePoint` → `MeshGeometry.closestPointOnTriangle`, pure/tested), releasing
for free placement when pulled farther. A miss on the gizmo box orbits the camera (the
primitive-gizmo non-fighting rule).

### 3 — Much shorter and thicker
Arrow length `radius·1.25 → radius·0.55` (stubby), and a dedicated thick draw (`drawArrow` gained
`w0/w1/headMax` params, defaulted to the slim force-arrow look so the D6 force arrows are
unchanged). Reads as a solid direction indicator, not a long thin line past the part.

### 4 — Visible ONLY while gravity is being edited
The persistent dim arrow + "↓ down" tag (`gravityIndicatorOverlay`, `gravityDownTag`) are DELETED.
The interactive arrow + base gizmo draw only in the setup phase ("being edited"). The rest of the
time the **"Gravity set · <axis>" chip** is the at-a-glance readout (unchanged).

## Verification bars

| Bar | How it's met | Evidence |
|-----|--------------|----------|
| **V1** direction shown == direction that reaches the job | Both routes funnel to `ForceModel.storeGravity` (round 1 invariant, unchanged). `testWidgetAndFaceTapProduceIdenticalJob` diffs the whole job.json set by widget vs face-tap → byte-equal. | headless |
| **V2** snapping is EXACT | `snap` returns the exact target vector. `testSnapToFaceNormalIsExact`, `testAxesOnlyMissesTheFaceThatFaceTargetsCatch`, `testSnapReturnsExactAxisNotApproximate`, `testFaceSnapEngagesOnTheRealBracket` (exact face normal). | headless |
| **V3** proves it snaps on a REAL part | `testFaceSnapEngagesOnTheRealBracket` imports `WallMount_ShelfBracket.stl`, finds a >20°-off-axis flat face, asserts axes-only returns **nil** (reproduces the "custom" failure) while face-targets snap EXACTLY to it. | headless + device (`02-…`) |
| **V4** base position round-trips / reaches job | Base is **purely visual** — it is stored (`gravityBaseModel`, optional, encodeIfPresent) so it round-trips (`testBasePositionRoundTrips`) but is read by NO run/serializer path, so it never changes the job (`testBasePositionDoesNotChangeTheJob` — job byte-identical across two far-apart bases). | headless |
| **V5** registers in the existing UndoHistory | Both direction + base commit through `@Published force` on ✓, one debounced round-6 step. `testWidgetGravityWithBaseIsSingleUndo`. | headless + device (undo arrow armed, `01-…`) |
| **V6** pre-change projects load unchanged | New key is optional + only-emitted-when-set → byte-identical when unused. `testPreRound2SnapshotHasNilBaseAndUnchangedGravity` (key absent → nil, gravity intact) + round-1 `testPreChangeSnapshotDecodesGravityUnchanged`. | headless |
| **V7** arrow ↔ gizmo don't move each other | Separate overlays / gestures: the arrow canvas is `allowsHitTesting(false)`, the tip knob only aims, the base gizmo only translates. `testBaseAndDirectionAreIndependent` proves the model-level independence both directions. | headless + device (both coexist in `02-…`) |
| **V8** device-real evidence | Clean iOS build → real iPad Pro 11" simulator. See evidence. | device |

All 22 `GravityDirectionTests` pass; 68 tests across the touched neighbours
(`ViewerMeshTests`/`TransformGizmoTests`/`PrimitiveGizmoTests`/`ProjectModel`/`ForceModel`) pass.

## Device evidence (`evidence/2026-07-27-gravity-round2/`)
- `02-gravity-setup-stubby-arrow-and-base-gizmo.png` — setup phase on the maintainer's real
  gusseted shelf bracket: the **stubby thick arrow** (item 3), the **3D transform gizmo at its
  base** (item 2), the magnet + confirm cluster, and the new banner ("it snaps to the part's own
  faces", item 1). Arrow + gizmo coexist (V7).
- `01-edit-phase-no-persistent-arrow-chip-only.png` — after ✓: the viewport is clean, **no
  persistent arrow / no "down" tag** (item 4); only "Gravity set · −Y", and the undo arrow is now
  armed (V5).

**Note on device import:** the in-app document picker does not present in this headless-driven
simulator, so the bracket project was seeded onto the device through the app's own `ProjectStore`
(the env-gated `GravityDeviceSeed` helper writes exactly what a real import writes — it `XCTSkip`s
without `TOPOPT_SEED_DIR`, so it is inert in CI). Also note DerivedData is content-shared across
worktrees; a clean `-derivedDataPath` build was needed to avoid a stale gizmo-lab root from another
branch — worth remembering for future device QA here.

## Files
- `ViewerMesh.swift` — `MeshGeometry.closestPointOnTriangle`; `ViewerMesh.FlatFace`,
  `flatFaceNormals`, `nearestSurfacePoint`.
- `GravityDirectionGizmo.swift` — `faceSnapTargets`; `snap` gains `extraTargets` (axes first,
  strict-greater so the first target wins a tie).
- `ForceModel.swift` — purely-visual `gravityBaseModel` + `setGravityBase` + optional Codable key.
- `WorkspacePlaceholder.swift` — stubby thick arrow with a movable magnetic base gizmo, face-normal
  tip snap, edit-only visibility; removed the persistent indicator.
