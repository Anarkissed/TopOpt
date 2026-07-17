# 095 — Shape-aware clearance regions: feasibility + design (STEP 0 STOP)

**Status:** Feasibility report. Implementation intentionally NOT started.
**Reason for stopping:** COLLISION. The implementation must edit `bridge.cpp`
`run_minimize_plastic_loadcase` (the anchor-pad + `keep_out_boxes` plumbing, lines ~806–846),
which is the exact "shared production setup" the concurrent LAN-offload / `galerkin-cache-production`
stream owns. Per the task's guard — *"If bridge.cpp is in flight, STOP after STEP 0 and deliver
the feasibility report — that is a complete, valuable outcome"* — this is that deliverable. The
design below is complete enough to implement in one sitting once `bridge.cpp` is free.

---

## TL;DR

- **The feature is real and cheap in the right place, blocked in the wrong one.** Shape-aware
  clearance is *shape-aware keep-out* — it feeds the EXISTING `FrozenVoid` path
  (`expand_design_domain` → `keep_out`), not a new mechanism.
- **STEP 0's blocker is resolved, not fatal.** The app does NOT carry face type/geometry — but it
  doesn't need to. The bridge re-imports the STEP via OCCT every call and holds the exact
  `TopoDS_Face`. Derive axis/radius/normal **bridge/core-side from the face id**; the app ships
  only `face_id` + role + editable clearance numbers.
- **Naming: "Clearance"** (region/feature) with the UI verb **"Keep clear"**. Disambiguates from
  082's "Preserve" (keep material). Justified below.
- **Edges: DEFER.** No use case the bore + face cases don't already cover; the control would be
  semantically ambiguous (preserve vs keep-out). A well-argued "not yet."
- **Auto vs manual: AUTO for bores, EXPLICIT for planes.** A bore tagged as an anchor is
  unambiguously a fastener hole; a planar mounting face may legitimately want a wrap-around
  gusset (M7.dom), so its clearance must be opt-in and a *bounded slab*, not a half-space.

---

## STEP 0 — THE DATA ANSWER (this decides everything)

### (a) What does the app carry at face-selection time?

**Only an opaque per-triangle B-rep `face_id` plus the welded tessellation.** Nothing else.

- The single geometry struct crossing the language boundary is `ImportedMesh`
  ([TopOptBridge.hpp:53](../../app/TopOptKit/Sources/TopOptBridge/include/TopOptBridge.hpp)):
  `vertices`, `indices`, `face_ids` (per-triangle B-rep id), counts, `watertight`. **No surface
  kind, no axis, no radius, no plane normal.**
- The app's selection unit *is* that `face_id`
  ([SelectionModel.swift:22](../../app/TopOptKit/Sources/TopOptFlows/SelectionModel.swift)).
- The app *derives* curved-vs-planar from **triangle-normal spread**
  ([FaceSelection.swift:142 `isCurved`](../../app/TopOptKit/Sources/TopOptFlows/FaceSelection.swift)) —
  a 5° heuristic used to walk a hole's face loop. Its own header (lines 20–23) says the exact
  `StepSurfaceKind` "the bridge does not forward today." So the app has **no** reliable
  bore-vs-flat classifier and **no** exact axis/radius/normal — it can approximate a plane normal
  by averaging triangle normals, but it cannot recover a cylinder's true axis or a hole's true
  radius from the tessellation alone with the fidelity a keep-out volume needs.

### (b) Is OCCT type/axis/radius/normal plumbed through today?

**Partially in core, not at all to the app.**

- Core `import_step_file` already reads the surface class via `BRepAdaptor_Surface::GetType()`
  and captures **`kind` + `cylinder_radius_mm`** into `StepFaceInfo`
  ([step.cpp:105–116](../../core/src/io/step.cpp),
  [step.hpp `StepFaceInfo`](../../core/include/topopt/step.hpp)).
- It does **NOT** capture: the **cylinder axis** (`surf.Cylinder().Axis()` → position + direction),
  the **plane normal/origin** (`surf.Plane()`), or the cone/other params.
- The bridge **drops `StepFaceInfo` entirely** — `import_step` returns only `face_ids`, and
  `StepModel.faces` never crosses into the app.

So today: type is derivable in `step.cpp` (radius yes, axis/normal no); **none** of type/axis/
radius/normal reaches the app.

### (c) Is that a fatal blocker? — No. The geometry belongs bridge-side.

The task's worry — *"if face type is NOT available where the mask is built, the app cannot
distinguish a bore from a flat face and NONE of this works"* — assumes the mask is built app-side.
**It isn't.** The FrozenVoid mask is built in `bridge.cpp` / core, and `bridge.cpp` **re-imports
the STEP with OCCT on every optimize call** (it already does, to voxelize + tag). At that point it
holds the full `TopoDS_Face` and can read the exact axis/radius/normal directly.

**Therefore the app never needs the geometry.** It ships `face_id` + `role = clearance` + the
editable clearance numbers; the bridge derives the precise swept-cylinder / slab from the face id.
This is the minimal-plumbing answer:

1. **Core (`step.cpp` / `step.hpp`):** extend `StepFaceInfo` with the cylinder **axis** (a point +
   unit direction) and the plane **normal + origin**. ~10 lines of OCCT reads next to the existing
   `Cylinder().Radius()` call. *Non-colliding* (core/src/io).
2. **Core (new rasterizer):** a function that, given the grid, `StepModel`, a `face_id`, and
   clearance params, writes the derived region as `FrozenVoid` into a mask on the **expanded**
   grid. *Non-colliding* (core/src/voxel or core/src/simp). **NOTE:** this is NOT `mask_step_face`
   — that only marks part-**SOLID** layers; clearance lives in **VOID** space (the bore interior,
   the space in front of a face), often outside the part grid.
3. **Bridge (`BridgeLoadCase` + `run_minimize_plastic_loadcase`):** carry the clearance face ids +
   params, derive the regions, OR them into the effective mask. **← THE COLLISION.** This is
   exactly the code region (~lines 806–846) the production-setup task is factoring.
4. **App:** a `.frozen`/clearance `GroupRole` (already exists,
   [SelectionModel.swift:34](../../app/TopOptKit/Sources/TopOptFlows/SelectionModel.swift)) wired
   through `SelectionTagger` (today it throws `.frozenUnsupported`,
   [SelectionTagging.swift:11](../../app/TopOptKit/Sources/TopOptFlows/SelectionTagging.swift)).

**"Plumbing it IS the bulk of the work" — verdict:** true, but the bulk is *core-side and
non-colliding* (steps 1–2, cheap and independently testable). Only step 3 collides. The core
geometry work can be sequenced FIRST, in parallel with the production factoring, with no conflict.

### (d) Edges — RECOMMEND DEFER

Technically possible: sample `BRepAdaptor_Curve`, mark voxels within a tube radius (a swept
capsule). But **what would it mean?** A protected edge is ambiguous:
- *Preserve* reading (keep a mating edge crisp): already served by the 082 FrozenSolid pad on the
  two faces meeting at the edge — no new control needed.
- *Keep-out* reading (clearance along a groove/channel): better and less ambiguously expressed as
  clearance on the cylindrical/planar face(s) that bound the groove — the cases we already handle.

There is no concrete use case that bore-clearance + face-clearance don't already cover, and an
edge control would force the user to pick between two opposite meanings on the same gesture.
**Defer.** Revisit only if a real groove/channel case appears that neither face type expresses.

---

## STEP 1 — SEMANTICS (what becomes `FrozenVoid`)

### (a) Cylindrical face (a bolt hole) → swept-cylinder keep-out

Region: the bore interior **extended along the cylinder axis** through the part and **out both
sides** by a *clearance length*, at radius = **bore radius + a concentric margin**. Bounded by the
design box. This is the maintainer's "distance concentric to it" = bolt-head / washer / driver
clearance.

Derived from OCCT: `surf.Cylinder().Axis()` (point + direction) and `.Radius()`. A voxel centre
`p` is in the region iff, with `a` = axis point, `d̂` = axis unit direction, `t = (p−a)·d̂`:
- radial: `‖(p−a) − t·d̂‖ ≤ bore_radius + concentric_margin`, and
- axial: `t_lo − clearance_length ≤ t ≤ t_hi + clearance_length`, where `[t_lo, t_hi]` is the
  bore's axial extent through the part (from the face's tessellation bounds along `d̂`).

**Proposed defaults (DO NOT SHIP AS-IS — confirm against a fastener standard):**
- `concentric_margin = bore_radius` → clearance diameter ≈ 2× hole diameter. Rationale: a socket-
  head cap screw head is ≈1.5× nominal Ø; a plain washer OD (DIN 125) is ≈2.2× nominal Ø. `2×`
  brackets head+washer for a clearance-fit hole. **Heuristic — validate against ISO 4762 head /
  DIN 125 washer tables before shipping.**
- `clearance_length = bore_diameter` out each side. Rationale: driver/socket axial access +
  fastener protrusion. **Heuristic.**

These are *derived* geometry but *judgement-call* numbers → **editable in the UI** (STEP 2).

### (b) Planar face (a mounting face) → BOUNDED SLAB, not a half-space

**Risk (as the task flags): an infinite outward half-space is too blunt.** It would forbid a
gusset that wraps around the mounting face — and M7.dom exists precisely to grow gussets
(GUARD c). An infinite half-space keep-out directly fights the feature it's meant to guard.

**Choice: a bounded slab.** The face's outline (its tessellation triangles' projected extent in
the face plane) extruded outward along the plane normal by a *clearance depth*, bounded by the
design box. This blocks material growing straight out past the mounting surface into the wall,
while leaving the surrounding empty space Active so a gusset can still wrap in from the sides.

Derived from OCCT: `surf.Plane()` → outward normal `n̂` (respect `TopAbs_REVERSED`, as `step.cpp`
already does at line 148) + a plane point; the in-plane outline from the face's triangles.
- **Proposed default `clearance_depth`:** enough to represent "the wall is there" without eating
  the whole box — propose `max(fastener protrusion estimate, a few voxels)`, **editable**, default
  on the order of the concentric-margin scale. Flag for maintainer confirmation; a slab depth is a
  genuine judgement call and should default conservative (shallow) so it never silently kills
  legitimate growth.

### (c) Precedence — FrozenSolid (preserve) WINS over FrozenVoid (clearance). Proven, not overlapping.

- The 082 anchor pad sits **behind** an anchor face (FrozenSolid, on part-solid layers,
  [bridge.cpp:806–814](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp)). Clearance sits **in
  front** (FrozenVoid, in void space). Geometrically disjoint — opposite sides of the face.
- **If they ever overlap**, `expand_design_domain` already resolves it correctly: *"a keep-out box
  never carves into the part regardless of `freeze_part`"* — part voxels stay FrozenSolid
  ([voxel.hpp:177–179](../../core/include/topopt/voxel.hpp)). So **FrozenSolid > FrozenVoid** is the
  existing, correct rule: clearance forbids only NEW growth, never removes declared/preserved
  material. The concentric margin harmlessly overlapping part material around a bore is fine — the
  part wins and stays solid; only the *void* voxels become FrozenVoid.
- **The new rasterizer must honour this:** OR clearance FrozenVoid into the mask only where the
  voxel is not already FrozenSolid (part or pad). One guard clause.

---

## STEP 2 — THE UI

Reuse the existing Selections grouping + chip-drawer chrome
([SelectionModel.swift](../../app/TopOptKit/Sources/TopOptFlows/SelectionModel.swift)). No new
panel. Clearance is a third `GroupRole` alongside `.fixture` / `.load` — and `.frozen` already
exists in the enum, so the state machine, chips, colours, rename/remove, and face-count labels all
come for free.

- **Selecting a face opens a secondary menu whose options depend on the picked geometry**
  (maintainer spec). Bore → "Bolt clearance" with {concentric margin, axial length}; planar face →
  "Face clearance" with {slab depth}. The menu's shape is driven by the geometry the bridge
  derives (surfaced back to the app as a lightweight per-selected-face descriptor, or inferred
  from the existing `isCurved` heuristic for menu-shaping only — the *precise* geometry stays
  bridge-side).
- **Show the derived numbers and let them be edited** — geometry is derived, the CLEARANCE is a
  judgement call (task requirement). Each clearance appears in the Selections library like Group A
  / Group B today.

### Naming — chosen: **"Clearance"** (verb "Keep clear")

The maintainer's "Protect" is ambiguous (protect from removal, or from filling?) — and 082 already
owns the *keep-material* concept under "Preserve." Candidates weighed:
- **"Obstacle"** — good physical model (the bolt head is an obstacle) but implies something is
  *present*; ours is user-declared empty space.
- **"Keep clear"** — unambiguous direction (keep it empty), plain language. Good UI *verb*.
- **"Clearance"** — the DFM/assembly term of art users already know ("bolt clearance", "driver
  clearance"). Names the *intent* (space reserved for assembly hardware), and is unambiguous vs.
  "Preserve".

**Decision:** noun **"Clearance"** for the region/feature; action label **"Keep clear"**. Together
they say *which* protection this is (keep the space empty), cleanly distinct from Preserve (keep
the material).

### Auto vs manual — chosen: **AUTO for bores, EXPLICIT for planes**

This is the product question. The recommendation and its justification:

- **Bore → automatic on anchor-tag.** A cylindrical face tagged as an anchor is unambiguously a
  fastener hole: a bolt passes through it, so the space along the axis is occupied *by definition*.
  There is no case where you tag a hole as an anchor and want it filled. Deriving bore clearance
  automatically removes a step and makes GUARD (a) — holes stay open — the default behaviour users
  expect. (The numbers stay editable; only the *existence* of the clearance is automatic.)
- **Planar face → explicit second action.** "The wall is there… usually." A mounting face
  sometimes wants a wrap-around gusset (M7.dom). Auto half-space/slab keep-out on every anchored
  plane would silently forbid legitimate growth. So plane clearance is opt-in, with an editable
  slab depth, defaulting to a *shallow bounded slab* — never an infinite half-space.

This matches the task's own "defensible answer" and is the safest default: it can't surprise a
user by killing growth, and it can't leave an obvious bore filled.

---

## STEP 3 — IMPLEMENTATION PLAN (sequenced; do NOT start until bridge.cpp is free)

Feeds the EXISTING FrozenVoid path — no parallel mechanism.

**Phase A — core geometry (NON-colliding; can start now, in parallel with production factoring):**
1. `StepFaceInfo` (+ `step.cpp`): add cylinder `axis_point`/`axis_dir` and plane `normal`/`origin`
   from OCCT. Extend the existing `switch` at [step.cpp:105](../../core/src/io/step.cpp).
2. New `mask_clearance_region(const VoxelGrid& expanded_grid, const StepModel&, int face_id,
   ClearanceParams, DesignMask& mask)` — rasterize the swept-cylinder (bore) or bounded slab
   (plane) as `FrozenVoid`, skipping any voxel already `FrozenSolid`. Unit-test headlessly against
   a synthetic cylinder + plane (no OCCT needed for the rasterizer math).

**Phase B — bridge (COLLIDING; sequence AFTER production factoring lands, then rebase):**
3. `BridgeLoadCase`: add `clearance_face_ids` + per-face `ClearanceParams` (flattened scalars, per
   the header's Swift-importer POD rule).
4. In `run_minimize_plastic_loadcase`, after `expand_design_domain` builds the effective mask,
   derive each clearance region on the expanded grid and OR it in — right beside the existing
   keep_out plumbing (~[bridge.cpp:827–846](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp)).

**Phase C — app UI:**
5. Route `.frozen`/clearance groups through `SelectionTagger` (remove the `.frozenUnsupported`
   throw); add the geometry-dependent secondary menu + editable params; list clearances in the
   Selections library.

---

## GUARDS / TEST PLAN (to run at implementation time)

- **(a) Holes stay open:** design-box optimize on the real L-bracket with holes tagged →
  every bore interior at/near void density. **MUST FAIL on today's code** (bore voxels are Active
  and fill). This is the acceptance test.
- **(b) Nothing beyond a tagged mounting face** after optimize (bounded-slab region stays void).
- **(c) Growth still works:** an M7.dom gusset case still grows into legitimate empty space — the
  bounded slab (not a half-space) is what preserves this.
- **(d) THE ONE RULE:** no-box path byte-identical (clearance only touches the design-box/expanded
  path — the bore interior is Empty on the no-box path already); Gate-V2 GREEN;
  `designbox_anchor_pad` (082), `designbox_reduction` (080), `design_domain`, and
  `savings_part_relative` (094) all green.

---

## DEFERRED / OPEN

- **Edges** — deferred (STEP 0d), no unambiguous use case.
- **Clearance default numbers** — proposed as heuristics; **must be validated against a fastener
  standard (ISO 4762 head Ø, DIN 125 washer OD) before shipping.** Do not ship invented mm.
- **Menu-shaping geometry descriptor** — decide whether the app gets a small per-face
  `{kind, radius}` descriptor from the bridge (clean) or keeps using the `isCurved` heuristic for
  menu-shaping only (no bridge widening, precise geometry still bridge-side). Recommend the former
  if the bridge is being widened anyway in Phase B.
- **Cone faces** (counterbores) — `StepSurfaceKind::Other` today; a counterbored hole's cone
  should extend the bore clearance. Out of scope for v1; note for follow-up.

## Files read (evidence)
- `core/src/io/step.cpp`, `core/include/topopt/step.hpp` — face geometry capture
- `core/include/topopt/voxel.hpp` (`expand_design_domain`), `pipeline.hpp`, `simp.hpp` — FrozenVoid path + precedence
- `app/.../TopOptBridge/include/TopOptBridge.hpp`, `bridge.cpp` — bridge surface + collision zone
- `app/.../TopOptFlows/FaceSelection.swift`, `SelectionModel.swift`, `SelectionTagging.swift` — app selection path
