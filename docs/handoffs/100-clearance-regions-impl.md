# 100 — Shape-aware clearance regions ("Keep clear"): IMPLEMENTATION

**Status:** Implemented end-to-end (core + shared seam + CLI + bridge + app),
tested, and gated. Follows the merged design in
[095-clearance-regions.md](095-clearance-regions.md), which stays authoritative;
this handoff records what shipped, the one design correction, and the evidence.

## TL;DR

A "clearance" is user-declared EMPTY space the optimizer must not grow material
into — the swept volume a bolt head/washer/driver occupies through a fastener
hole, or a shallow slab in front of a mounting face. It is *shape-aware keep-out*:
it feeds the SAME `FrozenVoid` path the design-box `keep_out` boxes do, but the
region is derived from the EXACT B-rep geometry (bore axis/radius, plane normal)
the STEP importer captures — the app carries only an opaque `face_id` + role +
editable mm numbers, exactly as 095 STEP 0 concluded.

- **AUTO for anchored bores, EXPLICIT for planes** (095's call). An anchored hole
  is unambiguously a fastener hole → it gets a bolt clearance automatically. A
  mounting plane may want a wrap-around gusset (M7.dom), so its clearance is an
  opt-in "Keep clear" role and a **bounded slab**, never an infinite half-space.
- **THE ONE RULE holds:** no clearance declared → byte-identical to the pre-100
  path, proven by `clearance_parity` (empty list ⇒ empty overlay ⇒ the
  minimize_plastic OR-step is skipped ⇒ bit-identical density).

## The one design correction to 095

095 STEP 1c argued precedence as "FrozenSolid (part) WINS over FrozenVoid
(clearance)" and cited `expand_design_domain`'s keep-out rule. That reasoning is
correct for the **add-material** path (`freeze_imported_part=true`, part is
FrozenSolid) but has a GAP on the **default production path**: handoff 080 made
the design-box path *whole-domain* (`freeze_imported_part=false`), where the
imported part is **Active/removable**, not FrozenSolid. A purely mask-FrozenSolid
guard would therefore NOT protect part material there — a concentric margin
overlapping the material around a bore would carve a moat through the part.

**Correction:** the rasterizer's precedence guard is **part-membership based**, not
mask-based. `mask_clearance_region` takes the part grid + the part's voxel offset
inside the solved grid and NEVER voids a voxel that maps to solid part material —
in either freeze mode. The minimize_plastic OR-step *additionally* guards
`mask != FrozenSolid` (covers the anchor pad + frozen box). Both guards are
proven: `test_clearance` asserts a part-solid voxel inside the margin ring stays
un-voided while its void neighbour at the same radius is cleared.

## Architecture (one builder, both front-ends)

1. **`core/src/io/step.cpp` / `step.hpp`** — `StepFaceInfo` gained the cylinder
   `axis_point`/`axis_dir` and the plane `plane_normal`/`plane_origin` (outward,
   respecting `TopAbs_REVERSED`). ~15 lines of OCCT reads next to the existing
   `Cylinder().Radius()`. Pinned on the cube/cylinder fixtures (exact known
   geometry) AND the demo l-bracket (2 bolt holes r=2.5, axis∥Z at (−17,0)/(9,0);
   8 axis-aligned planes with correct outward normals).

2. **`core/include/topopt/clearance.hpp` + `core/src/voxel/clearance.cpp`** (NEW,
   OCCT-free) — `mask_clearance_region(solved_grid, part, offset, model, face_id,
   params, out)` rasterizes the swept cylinder (Bolt) or bounded slab (Face) as
   `FrozenVoid`, skipping part-solid voxels (the precedence guard). Semantics per
   095 STEP 1: radial ≤ `bore_r + margin`, axial `[t_lo − clr, t_hi + clr]` from
   the face's own tessellation span; slab = the plane-outline bounding rectangle
   extruded outward by `depth`. Cost is O(voxels) per clearance — **named ceiling:
   trivial next to a solve, deliberately un-optimized.**

3. **Shared seam** — `ProductionLoadCase` gained `clearances[]` (face id +
   `ClearanceParams`); `build_production_loadcase` rasterizes them onto
   `minimize_plastic_solved_grid` and stores the overlay in the new
   `MinimizePlasticOptions::clearance_void` (solved-grid-indexed) plus honest
   per-clearance `clearance_reports`. `minimize_plastic` ORs the overlay into the
   effective mask where it is not already FrozenSolid. **The bridge shrank to the
   flat mapping** (per the prompt's stale-assumption update): bridge.cpp only
   unflattens `BridgeLoadCase` clearance fields → `ProductionLoadCase`.

4. **CLI job schema** — `loads.clearances[]` (`face_id`, `kind` "bolt"/"face",
   editable mm distances). run_job maps them to the SAME builder, so a Mac/LAN
   worker honours protected holes identically (production_parity philosophy).
   RemoteRunner serialises the same block for the offload path.

5. **App** — a `.clearance` `GroupKind` ("Keep clear" chip beside Anchor|Load),
   per-group editable overrides (`ForceModel`), `Project.clearanceSpecs()` derives
   the run's clearance list (auto bolt for anchored bores via the `isCurved`
   heuristic; explicit slab for keep-clear planes), threaded through
   `RunRequest`→bridge. The stale `SelectionTagger.frozenUnsupported` throw is
   gone — `.frozen` now routes through `mask_step_face` (the bridge exposes it).

## Clearance defaults — validated vs ISO 4762 + DIN 125

095 flagged its default numbers as heuristics to verify before shipping. Done.
The GEOMETRY is exact; these are the editable, judgement-call distances, prefilled
as **suggestions** (`default_bolt_clearance` / `default_face_clearance` in
clearance.hpp). Shipped defaults:

- **Concentric margin = bore radius** ⇒ keep-out **Ø = 2 × bore Ø**. A bolt's
  keep-out must clear the larger of the socket-head OD and the washer OD.
  Clearance-fit bore ≈ 1.1 × nominal d (ISO 273 medium). Checked against ISO 4762
  head Ø (dk,max) and DIN 125 washer OD:

  | Screw | bore Ø | keep-out Ø (2×) | ISO 4762 head dk | DIN 125 washer OD | clears? |
  |------:|-------:|----------------:|-----------------:|------------------:|:-------:|
  | M3 | 3.4 | 6.8 | 5.5 | 7.0 | head ✓, washer −0.2 (marginal) |
  | M4 | 4.5 | 9.0 | 7.0 | 9.0 | ✓ (= washer) |
  | M5 | 5.5 | 11.0 | 8.5 | 10.0 | ✓ |
  | M6 | 6.6 | 13.2 | 10.0 | 12.0 | ✓ |
  | M8 | 9.0 | 18.0 | 13.0 | 16.0 | ✓ |
  | M10 | 11.0 | 22.0 | 16.0 | 20.0 | ✓ |

  "2 × bore Ø" brackets head + washer across M4–M10; **M3 is ~0.2 mm under the
  DIN 125 washer OD** (that washer is a relatively larger 2.33 × d). The margin is
  editable, so an M3 washer job bumps it; the default stays bore-radius as a sound
  general bracket. Numbers cited so the next maintainer can re-check.

- **Axial clearance = bore diameter each side** (driver/socket access + fastener
  protrusion, ≈ one nominal-d each side). A judgement minimum; editable.

- **Slab depth = 3.0 mm** — the genuine judgement call (095 said default shallow
  and conservative). A DIN 125 washer is 0.5–2 mm thick and a mating flange a few
  mm; 3 mm represents "the wall is there" without eating the box or silently
  killing a gusset. **Shipped 3.0 mm, editable, labelled a suggestion.**

An un-overridden bolt margin/axial is sent as 0, which the core reads as "use the
bore-radius-derived suggestion" — so the app never DISPLAYS a fabricated mm it
doesn't actually know (it can't recover the exact bore radius); the field shows
"auto", and any number the user types IS the number the run uses.

## Honesty

Clearance changes the DESIGN, so the UI states what it did:
- **Bridge/CLI logs** one `[loadcase] clearance face=… kind=… voxels_frozen=… …`
  line per region (SKIP flag when a region lands outside the solved grid).
- **Results screen** shows a "Keep clear applied" note listing each face, its kind,
  and how much was reserved — and explicitly flags a region that fell **outside the
  solved area** ("no effect … add a design box") rather than silently no-opping.
- The numbers shown are the numbers used.

## Evidence

- **Core `ctest` (raw):** all gates green — `clearance` (rasterizer + precedence),
  `clearance_parity` (THE ONE RULE + bore-stays-open effect), `production_parity`,
  `load_retention_connectivity`, `gate_v2`, `design_domain`, `designbox_*`,
  `savings_part_relative`, `ladder_rung_count`, `step_import`, `job_schema`. The
  only red is `cli_demo` (3/84, `achieved volume fraction within 0.01` — the
  pre-existing lib3mf-absent local failure, unrelated to clearance; CI has lib3mf).
- **CLI end-to-end:** `topopt-cli run` on the l-bracket with two bolt clearances +
  a design box froze 40 and 54 voxels and completed the ladder (log lines above).
- **App:** `swift test` = 443 tests, 0 failures (1 skipped). `xcodebuild build`
  green for the TopOptKit package (macOS, incl. the bridge C++) AND the TopOpt iOS
  app (simulator). New model tests: ForceModel clearance role/overrides/Codable,
  ResultsModel honesty notes, SelectionTagging masks-not-throws.
- **Screenshot description (Keep-clear chip + editable numbers):** with a STEP part
  imported and gravity set, tapping a face floats the role chip at its centroid —
  now three pills: **Anchor** (green), **Load** (accent), and **Keep clear**
  (`nosign` icon, muted fill). Choosing Keep clear tags the group and shows it in
  the Selections list as "Keep clear"; anchored bores show automatically. Each
  clearance group's row carries a compact editable sub-row under its kind label — a
  `nosign` glyph then small underlined fields **margin / axial** (bolt) or **slab**
  (face) with a trailing "mm", each placeholdered **"auto"** (= the core
  suggestion). After a run, the results overlay shows a "Keep clear applied" card
  listing the faces kept clear and voxels reserved.

## Deferred / limitations (restated, with why)

- **Edges — deferred** (095 STEP 0d): no use case bore + face clearance don't
  already cover, and an edge control is semantically ambiguous (preserve vs
  keep-out) on one gesture. Unchanged.
- **Cone faces (counterbores)** — a counterbore's cone should extend the bore
  clearance; `StepSurfaceKind::Other` today, so a Bolt clearance on a counterbore's
  cone face no-ops. Out of scope for v1 (095 noted it); the app's `isCurved`
  auto-detection still catches the cylindrical part of a counterbored hole.
- **Slab depth default (3.0 mm)** — a judgement call, not a standard; shipped
  shallow-and-editable so it never silently kills a legitimate gusset. If a real
  mating-flange case wants deeper, the user types it.
- **Face outline = bounding rectangle** — the slab uses the face tessellation's
  in-plane bounding rectangle, not the exact polygon. Conservative-enough for a
  bounded slab; an L/T-shaped mounting face's slab is slightly larger than its
  outline. Exact-polygon extrusion is a follow-up if a real case needs it.
- **App bore detection** is the `isCurved` triangle-normal heuristic (095's
  sanctioned menu-shaping use). A false positive is a **safe no-op**: the core
  rasterizer requires the actual `StepSurfaceKind::Cylinder`, so a Bolt clearance
  on a non-cylinder marks nothing and is honestly reported (`voxels_frozen=0`).

## Files touched

Core: `step.hpp/.cpp`, `clearance.hpp` (new), `voxel/clearance.cpp` (new),
`pipeline.hpp`, `simp/minimize_plastic.cpp`, `loadcase.hpp/.cpp`, `job.hpp`,
`cli/job.cpp`, `cli/run_job.cpp`, `CMakeLists.txt`; tests `test_step`,
`test_clearance` (new), `test_clearance_parity` (new), `test_job`.
Bridge: `TopOptBridge.hpp`, `bridge.cpp` (flat mapping only).
App: `TopOptKit.swift`, `ForceModel.swift`, `ProjectModel.swift`, `RunModel.swift`,
`AppModel.swift`, `RemoteRunner.swift`, `SelectionTagging.swift`,
`ResultsModel.swift`, `ResultsScreen.swift`, `WorkspacePlaceholder.swift`;
tests `ForceModelTests`, `ResultsModelTests`, `SelectionTaggingTests`.
