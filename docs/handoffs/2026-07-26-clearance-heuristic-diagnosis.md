# Auto-clearance heuristic — diagnosis (READ-ONLY, no fix)

**Date:** 2026-07-26
**Status:** Diagnostic complete. No heuristic change made (by design — a fix
written before the cause is understood is how the 5° curved-face bug shipped).
**Evidence:** `evidence/2026-07-26-clearance-heuristic-diagnosis/`

## The complaint

On a small `WallMount_ShelfBracket` STL the auto-clearance heuristic
over-found and under-found *in the same session*:

- one anchor group came back with **8 bore primitives**, margins/axials
  (reported ≈ 12.25 mm / 33.75 mm) sprawling far past the part;
- another group's Bore rows rendered **blank — "— mm  Auto"**.

The heuristic was already suspect (previously produced 135 mm axials).

## What the part actually is

`core/tests/fixtures/mesh/WallMount_ShelfBracket.stl` — 2224 triangles, bbox
**201 × 207 × 20 mm** (diag 289.6 mm). It is a triangular truss shelf bracket
(see `bracket_shaded_a/b.png`):

- **2–3 real fastener holes** — small round through-holes on the left flange
  (Ø4 and Ø9). `analyze_output.txt` confirms exactly **2** full-360°-wrap,
  small-radius, concave cylinders (a 3rd Ø9 hole is split into two arcs by
  segmentation, faces 19+20).
- **Large lightening pockets** — the big triangular voids. Their walls are flat
  runs joined by **rounded corners**. They are not holes.

The heuristic proposed **24 bore primitives** for this part (whole-mesh census;
the user's "8" is the subset that landed in one anchor group). Against 2–3 real
holes.

## Measurement (probe_output.txt, all mesh fixtures)

| fixture | tris | bbox diag | real holes | primitives proposed | with radius | **blank-Auto** |
|---|---|---|---|---|---|---|
| **WallMount_ShelfBracket** | 2224 | 289.6 | **2–3** | **24** | 16 | **8** |
| plate_bore (clean bore) | 416 | 29.1 | 1 | 1 | 1 | 0 |
| filleted_bore_plate | 1440 | 62.5 | 1 | 3 | 1 | **2** |
| l-bracket (CAD export) | 236 | 93.8 | 2 | 2 | 2 | 0 |
| hook | 212 | 54.4 | 0 | 2 | 0 | **2** |
| sphere_r10mm | 320 | 34.6 | 0 | 1 | 0 | **1** |
| cube_10mm / sample_cube | 12 | 17.3 | 0 | 0 | 0 | 0 |
| bracket_clean | 416 | 72.4 | 1 | 1 | 1 | 0 |
| bracket_small_hole | 418 | 72.4 | 1 | 1 | 1 | 0 |

**Clean, small parts with a genuine cylindrical bore are correct** (plate_bore,
l-bracket, bracket_clean → exactly the real hole count, no blanks). The
heuristic fails on **(a) large parts** and **(b) parts whose curved geometry is
not a fastener hole** (pockets, fillets, spheres, hooks).

Selected shelf-bracket rows (full table in `probe_output.txt` / `analyze_output.txt`):

| face | kind | fitR (mm) | margin | axial | wrap° | r/bbox% | what it really is |
|---|---|---|---|---|---|---|---|
| 0 | Cyl | 221.6 | 221.6 | **443.2** | 53 | 76% | outer edge misfit |
| 17 | Cyl | 199.2 | 199.2 | **398.5** | 31 | 69% | outer edge misfit |
| 26 | Cyl | 58.0 | 58.0 | 116.0 | 47 | 20% | pocket-corner wall |
| 21 | Cyl | 55.8 | 55.8 | 111.6 | 198 | 19% | pocket-corner wall |
| 1 | Cyl | 16.7 | 16.7 | 33.4 | 32 | 6% | pocket-corner wall (≈ the reported 33.75) |
| 28 | Cyl | 17.1 | 17.1 | 34.2 | 73 | 6% | pocket-corner wall |
| **14** | **Cyl** | **2.0** | **2.0** | **4.0** | **353** | 0.7% | **REAL Ø4 hole** |
| **15** | **Cyl** | **4.5** | **4.5** | **9.0** | **354** | 1.6% | **REAL Ø9 hole** |
| 6 | Other | — | **BLANK** | **BLANK** | — | — | curved, fit rejected |
| 12 | Other | — | **BLANK** | **BLANK** | — | — | curved, fit rejected |

The reported ≈ 12.25 / 33.75 pair was not reproduced bit-for-bit (the user's
session had its own selection/scale) but the **signature is exact**: pocket-corner
walls fitting radii of tens of mm → margins/axials in the tens-to-hundreds of mm,
far past the part. Faces 0/17 (axial 443/398 mm) are the same failure that once
produced "135 mm axials," now worse because the part is bigger.

## The four questions

### Q1 — Where do the axial and margin numbers come from?

Traced end-to-end. They are **not** a constant and **not** a bounding dimension —
they are derived from the **per-pseudo-face fitted cylinder radius**:

1. `core/src/io/segment.cpp` fits each pseudo-face; a region accepted as a
   Cylinder gets `StepFaceInfo::cylinder_radius_mm` from a Kasa circle fit.
2. The radius crosses the bridge into
   `StepFaceGeometry.cylinderRadiusMM` (`TopOptKit.swift:1015`).
3. The Auto distances are pure functions of that radius
   (`ClearanceGeometry.swift:41,44`):
   - `boltMarginMM(r) = r`
   - `boltAxialMM(r) = 2·r`
4. They are attached per bore face in
   `ProjectModel.resolvedClearances()` (`ProjectModel.swift:438–446`) and
   labelled on the chips in
   `WorkspacePlaceholder.clearanceHandleChip` (`WorkspacePlaceholder.swift:1384–1390`).

So `margin` and `axial` are **only ever the fitted radius and twice it**. When
the fitted radius is a misfit (a flat wall or a pocket corner fitting a huge
circle), the margin/axial are correspondingly huge. There is no absolute sanity
bound anywhere on the resulting distance.

### Q2 — Why eight primitives on a bracket with far fewer holes?

Two independent inflators, both visible in the data:

1. **The bore predicate is geometry-blind.** A face counts as a "bore" via
   `FaceTopology.isCurved` (`FaceSelection.swift:141`): *any* pair of its
   triangle normals differ by > 5°. That fires on **every** curved region —
   pocket-corner blends, outer rounded edges, fillets, a whole sphere — not just
   holes. On the bracket, 24 faces trip it; only 2–3 are holes. This is
   *independent of* the segmenter's own Cylinder/Plane/Other classification.
2. **The cylinder fit is over-permissive.** `segment.cpp` accepts a region as a
   Cylinder if the circle fit is tight *and* the radius is below
   `max_cylinder_radius_span · bbox_diagonal` (`segment.hpp:130`, default 1.0).
   On a 289 mm part that ceiling is 289 mm, so a nearly-flat outer edge fits a
   **221 mm** "cylinder" and passes (faces 0, 17). The bound is *relative to the
   whole-part bbox*; the comment that motivated it ("a 60 mm plate's side fit as
   a 140 mm cylinder") was calibrated on a small part and does not scale. 16 of
   the 24 bores are these Cylinder misfits.

**Pseudo-face fragmentation (the PR-167 8-gon caveat) is a real but secondary
contributor**, not the main driver: e.g. one Ø9 hole splits into faces 19+20
(both r = 4.5). It doubles a count here and there but does not explain 24-vs-3.
The dominant cause is that the part is *full of non-hole curved geometry* that
both predicates happily accept.

### Q3 — What makes a Bore row render blank "Auto"?

Not a serialization gap, and not a legitimate "unknown." It is a **failed fit
surfaced as a bore.** A face is shown as a Bore (with Margin/Axial rows) iff
`isCurved` is true — but the Auto *number* comes from
`WorkspacePlaceholder.faceBoreRadius` (`:1404`), which returns `nil` unless
`geo.isCylinder` (`kind == .cylinder && radius > 0`, `TopOptKit.swift:63`). So a
face that is **curved but whose cylinder fit was rejected** (segmented as
`Other`, radius 0 — a cone, a sphere patch, a pocket blend, a coarse strip)
becomes a bore chip with `autoMM == nil`. `GlassValuePill.displayedMM`
(`GlassValuePill.swift:62`) is `valueMM ?? autoMM` → `nil` → renders `"—"`
(`:177`) with the "Auto" badge still lit.

Confirmed on the shelf bracket (8 blank rows: faces 6, 10, 12, 13, 18, 22, 25,
27 — all `kind = Other`), on `filleted_bore_plate` (2), `hook` (2), and
`sphere_r10mm` (1 — the entire sphere offered as a blank bore).

### Q4 — Does the mesh path differ from the STEP path?

Yes, by design, and the divergence is the amplifier (confirms the PR-171 note).

- **STEP path** (`part.cpp:487`, `import_step_file`): real OCCT B-rep faces —
  one face per physical hole, a reliable `cylinder_radius_mm`, and
  `StepSurfaceKind` straight from the B-rep. `pseudo_faces = false`. A real
  fastener hole is one Cylinder face with the true radius; there is no
  flat-wall-fits-a-giant-circle failure mode.
- **Mesh path** (`part.cpp:505`, `segment_mesh_faces`): faces are *fitted* from
  the triangle soup with **no B-rep metadata**. A flat/gently-curved wall can
  least-squares-fit a huge circle (Defect 2); a coarse or filleted barrel
  fragments (PR-167 caveat); non-cylinder curves land as `Other` (Defect 1).

**Important:** the *bore predicate* (`isCurved`, 5° fan) and the
*isCurved→isCylinder decoupling* live in the app and run on **both** paths — so
Defect 1 (blank-Auto) can occur on a STEP part too (a cone/torus/spline face is
`Other` yet trips `isCurved`). But Defect 2 (giant-radius misfits) is
**mesh-only**. The mesh path does not merely "diverge"; it removes the one thing
that made the numbers trustworthy (the B-rep radius) and substitutes a fit with
a bbox-relative acceptance bound.

## Bars

### C1 — Every number traced

Done — table above; each derivation cited to a line
(`segment.cpp` fit → `TopOptKit.swift:1015` → `ClearanceGeometry.swift:41,44` →
`ProjectModel.swift:438` / `WorkspacePlaceholder.swift:1384`). Real hole counts
are measured (`analyze_output.txt`) and visually verifiable (`*.png`), not
asserted.

### C2 — One root cause, or two?

**Two.** Do not collapse them.

- **Defect 1 — geometry-blind bore predicate.** `isCurved` (5° normal fan) is
  decoupled from the surface classification. Causes **all** the blank-Auto rows
  *and* part of the over-finding (the 8 `Other` faces offered as bores).
- **Defect 2 — over-permissive cylinder fit.** The `max_cylinder_radius_span`
  bound scales with the whole-part bbox diagonal and there is no
  wrap/concavity/absolute-radius gate. Causes the **absurd magnitudes**
  (12.25 / 33.75 / 135 / 443 mm) *and* the majority of the over-finding (the 16
  Cylinder misfits).

So over-finding is the **sum of both** defects; blank-Auto is Defect 1 only; the
bad magnitudes are Defect 2 only. They share Defect 1 partially but are not one
bug — a fix that only addresses the `isCurved` decoupling would still leave the
221 mm-radius misfits, and a fix that only tightens the radius bound would still
leave the sphere/hook/fillet blank rows.

### C3 — Recommended fix (NOT implemented) + how to know it worked

**Recommendation — make "is this a fastener bore?" a single geometric predicate,
applied consistently, gated on real hole geometry:**

1. **Gate bore-clearance on `isCylinder`, not `isCurved`.** Offer a bolt
   clearance only for faces the segmenter actually classified `Cylinder` with a
   radius. This deletes the blank-Auto class entirely (no radius → not offered)
   and drops non-cylinder curved faces (fillets, spheres, pocket blends). Kills
   Defect 1's contribution to both symptoms.
2. **Add a fastener-hole gate to the Cylinder classification** (or to the
   app-side bore test), requiring all of: (a) **full ~360° wrap** around the
   axis — a through-hole, not a corner arc; (b) **concave** — normals point
   toward the axis, not a boss/outer edge; (c) an **absolute radius bound** (or
   one relative to the part's *smallest* dimension, not the bbox diagonal). The
   `analyze.cpp` discriminators (wrap, concavity, r/bbox) are exactly this test
   and cleanly separate the 2 real holes from the 22 misfits.
3. **Tighten / rescope `max_cylinder_radius_span`.** A Ø443 "cylinder" on a
   290 mm part must not pass. Bbox-diagonal scaling is the specific loose bound.
4. **Merge coaxial same-radius fragments** (faces 19+20) into one primitive so a
   split hole is one bolt, addressing the PR-167 fragmentation without moving the
   35° threshold.
5. Keep the manual add/remove escape hatch as the way to force a clearance on a
   face the tightened predicate rejects — so the predicate can be strict without
   being a dead end. It must **not** be the excuse for leaving the detector wrong.

**To know the fix worked, measure (re-run `probe.cpp` + `analyze.cpp`):**

- **Primitive count == real hole count** on every fixture: shelf bracket → 2–3
  (today 24), l-bracket → 2 (ok today), plate_bore / bracket_clean /
  bracket_small_hole → 1 (ok today), cube → 0 (ok today), sphere → 0 (today 1),
  hook → 0 (today 2).
- **Zero blank-Auto rows** on any fixture (today: 8 + 2 + 2 + 1).
- **No proposed margin/axial exceeds a sane absolute bound** (e.g. < the part's
  min dimension). Today the max is 443 mm on a 20 mm-thick plate.
- **Byte-identical regression guard:** the parts the heuristic already gets
  right (`plate_bore`, `l-bracket`, `bracket_clean`) must produce the *same*
  clearance specs after the fix — proving it tightened the false positives
  without dropping a true positive.
- **Escape-hatch check:** a manual clearance forced onto a rejected face still
  serializes and runs.

## Reproduce

See `evidence/2026-07-26-clearance-heuristic-diagnosis/README.md`. Three
standalone C++ probes compile against the OCCT/Eigen-free core slice and run the
real `import_part` + `segment_mesh_faces` pipeline.
