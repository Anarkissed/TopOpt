# Handoff — 2026-09-29-flexible-screens (TRACK app, A1): the Flexible screens

## In plain words

**What you can do on screen now** (simulator, on the 100 × 100 × 20 pad and on the M2 stand):

- **Open the Lattice stage.** Three cards now sit side by side: Structural, Aesthetic and
  **Flexible**, in the same style. Flexible's text says it is for squishy filaments, you draw
  how far each face gives, there is no strength certificate, and every number shows where it
  comes from.
- **Choose Flexible.** The Lattice stage shows a green "Flexible" title chip. Tapping it opens
  the same limitations sheet with the same two-tap "Delete … and choose again". The
  **Settings** button opens the Flexible page instead of the octet wizard. Placement is the
  existing region tools, unchanged.
- **Filament.** Filaments with data are listed first, then the calibrate-first ones. Each has
  its tier badge. varioShore offers only its tested temperatures (190 / 220 / 240 °C). A
  calibrate-first filament shows "Calibrate first — geometry only" with core's own reason, and
  its squish fields stay empty.
- **Squish.**
  - Tap a face on the part to load it. The panel says "Face 2 of 4" and names the linked
    other end with its area share ("Other end: face 15 43 %, face 1 30 %, …").
  - You can set the weight in kg (the N value is shown underneath), the deepest squish in mm,
    the frame rotation in 90° steps, and skin on/off. Every number opens the number pad.
  - A side face says "Side face · gyroid only · estimated".
  - The **X curve is drawn on the model**, along the face's own X edge, rising out of the
    part. Drag its points and the map on the face recolours as you drag. "+ point" adds a
    point; a double-tap deletes one. The Y curve works the same way. Centre → edge uses a
    single curve.
  - The **3D view** colours the face by depth and dents it. It has a "What you drew / What can
    be built" toggle and a legend with the tier and ± band. The clamped columns are counted in
    plain words.
  - A **density cross-section** (X / Y / Z, with a slider) shows either density or the
    **owner map** where faces hand over, with core's handover volumes.
  - Two faces on the same stack give **core's conflict sentence with both face ids**.
- **Auto.**
  - Springy or damped?
  - Core's one-line sentence and its reasons.
  - Where it cannot be met: which face, the u/v range, and the nearest achievable squish.
  - Every candidate core weighed (family × tested temperature), with mass where it is known.
  - An override that shows "no data here" for a pick core has no data for.
- **Physics.**
  - The three tested temperatures side by side on one scale.
  - The curve in use at each loaded face's density, with that face's operating point.
  - Source, tier, band, the tested density and strain limits, and core's strain convention.
  - Both honesty notes (after break-in; sharper dents).
- **Stamps.**
  - The 10 built-ins, and an SVG or image import.
  - Check mode takes any number of stamps and shows each dent on the model. Design mode takes
    one stamp and re-designs the face under it.
  - Size, rotation and weight use the number pad. Soft or rigid. Drag the stamp's handle on
    the part to move it.
  - Each stamp is laid on the face at half the column pitch; the panel prints the grid.
  - Flags shown: narrow stamp, force off the face, and the note about a rigid design stamp.
- **Everything is saved and undoable.** Every edit reaches `project.json` within 0.8 s. Undo
  and Redo are on the page.

**Overnight round (below).** Added since the first handoff:

- the dent reads through a 30 % body;
- split faces are loaded faces;
- **Generate lattice** with the squish on repeat;
- **Export** (STL; G-code "not ready yet").

Three things need you: the STL size (1.3 GB for the pad at Standard), whether the lattice
should be occluded by the body, and a look on the device. The simulator launch was refused
tonight, so none of it has been seen on a screen.

**What is next.**

- **Maintainer look.** Please check the curve editor's feel, the 3D dent (see "Not done" §2),
  and whether the panel layout is right for you.
- **A2 (bead-path preview)** waits on C2.
- **Full app suite:** the result is pasted below.

## Task
A1 of docs/design/flexibles/07-roadmap.md: the Flexible stage's screens in `/app/`, drawing every
number from C1's core through the bridge.

## Synced commits (merge-only, nothing pushed to those branches)

| branch | last synced commit |
|---|---|
| #361 `claude/flexible-squish-maths` (base) | `592d9155` Restore four evidence PNGs the running app suite rewrote |
| #354 `claude/topopt-holes-quilting-298212` | `8105522b` #358 follow-up (maintainer's answers): over-air spans are PRINTED … |
| #358 `claude/raster-receipt-fields` | `5be7862a` unsupported_spans_seen: the comment said "not printed" and they are printed |
| `main` | `f932266f` Merge pull request #360 (lattice types setup) |

- **Merges.** `ee3cd779` (Sync: merge #354) and `8c666f6c` (Sync: merge #358) merged with no
  conflicts. #361 and main were already contained.
- **After the sync.** `build_core.sh` exited 0, `swift build` finished, and the 62 targeted
  tests passed.

## Per-stage status

| Stage | Status | Evidence (docs/handoffs/evidence/2026-09-29-flexible-screens/) |
|---|---|---|
| S0 baseline look | Topology, Lattice (Aesthetic), Settings wizard and the two-card modal captured before any change | `s0_before_*.png` |
| S1 entry + setup | **done**: third card, chip, delete-and-re-ask sheet, once-only rule, filament list with tiers and tested temperatures, calibrate-first empty fields with reason, placement unchanged | `s1_pad_modal_three_cards`, `s1_m2_modal_three_cards`, `s1_pad_lattice_stage_flexible_chip_placement`, `s1_m2_filament_varioshore_tested_temps`, `s1_pad_calibrate_first_filament_reason`, `s1_pad_calibrate_first_geometry_only` |
| S2 squish screen | **done**: face stepper, linked other end + fractions, kg→N, deepest mm, 90° frame, skin, side label, pen curves on the model (X, Y, centre→edge) validated and drawn by core, 3D view with drew / buildable, legend, clamp counts, density slice with owner map, conflict | `s2_m2_squish_x_curve_on_model`, **`s2_m2_curve_mid_drag`** (taken during a drag), `s2_pad_3d_what_you_drew`, **`s2_pad_3d_what_can_be_built`**, `s2_m2_3d_what_you_drew`, `s2_pad_side_face_gyroid_only_estimated`, `s2_pad_density_slice_owner_map_handover`, `s2_pad_three_faces_owner_map`, **`s2_pad_same_stack_conflict`** |
| S3 Auto + physics | **done** | `s3_pad_auto`, `s3_m2_auto`, `s3_pad_physics`, `s3_m2_physics` |
| S4 stamps | **done**: library, import (SVG / image, unit-tested; not yet driven on the simulator, see Not done), size / rotation / weight / soft-rigid / drag, several per face, design vs check, narrow / off-face / rigid-design notes | **`s4_pad_stamp_check_mode_heel`**, **`s4_pad_stamp_design_mode_thumb_with_heel_check`**, `s4_m2_stamp_check_mode_thumb`, `s4_m2_stamp_off_face_flag` |
| S5 persistence + job | **done**: settings in `LatticeSettings.flexible` (saved, undoable, cleared by delete-and-re-ask); `FlexibleJob` writes the `flexible` block; the round trip goes through core's `parse_job` | tests below |

## What I did

**Bridge.** Two new files:

- `app/TopOptKit/Sources/TopOptBridge/flexible_bridge.cpp`
- `app/TopOptKit/Sources/TopOptBridge/include/FlexibleBridge.hpp`

Each function copies a `topopt::flexible` result into POD vectors; none computes a squish number
itself. The functions, grouped by contract item:

- **F1**: `flexible_materials` (catalogue + `tested_temperatures`, plus core's `curve_set`
  refusal as the no-prediction reason), `flexible_error_bands`, `flexible_temperature_note`.
- **F4**: `flexible_pen_curve_error`, `flexible_pen_curve_values`.
- **F3 and F10**: `flexible_curve_set`, `flexible_stress_at`, `flexible_density_for`,
  `flexible_strain_under`, `flexible_curve_samples` (σ(ε) sampled with core's `stress_at`),
  `flexible_tier_band`, `flexible_cell_size_mm`.
- **F8**: `flexible_stamp_grid_error`, `flexible_stamp_force_n`, `flexible_stamp_width_mm`.
- **Scene**: `flexible_scene_open` / `close` / `info`. It parses the job with `parse_job`,
  imports with `import_part_file_resolved`, then calls `voxelize`, `flexible_region_mask` and
  `resolve_face_regions`, and keeps the results.
- **F5**: `flexible_scene_stack` (cached per face and rotation), `flexible_scene_from_uv`,
  `flexible_scene_to_uvt` (core's `to_uv`, plus t along the load).
- **F6–F8 on the scene**: `flexible_scene_squish_fraction`, `flexible_scene_edge_fraction`,
  `flexible_scene_design` (the design is cached for the field),
  `flexible_scene_check_stamp` (densities come from the cached design, exactly as
  `run_flexible_job` reads them), `flexible_scene_conflicts`,
  `flexible_scene_density_slice` (`assemble_density_field`, cached, one axis slice + owner +
  handovers).
- **F9**: `flexible_scene_recommend`.
- **F11**: `flexible_parse_job_block` (core's `parse_job`, read back).

The Swift wrappers are in `app/TopOptKit/Sources/TopOptKit/FlexibleKit.swift`
(`FlexibleCore` and `FlexibleScene`).

★ **Swift/C++ interop trap.** Reading `s.col_u_mm[k]` in a loop copies the whole
`std::vector` on each access. `stack()` took 3.1 s and `design()` 6.9 s until every vector was
converted with `Array(...)` once (`FLEX_TIMING` probe). After the fix:

- scene open: 4 ms
- stack: 19 ms (15 ms cached)
- squish map: 0.9 ms
- design: 92 ms (Debug, macOS, 4,096-column pad)

**App (all new files):**

- `FlexibleSettings.swift`: inputs only, never a prediction.
- `FlexibleJob.swift`: the run and scene job writer. Face region id = face id, so core's
  sentences name the face the app shows.
- `FlexibleStageChrome.swift`: card, chip and sheet, copied from the mode modal and sheet;
  accent `DS.Color.accentGreen`.
- `FlexibleStageModel.swift`: an actor worker off the main thread. It opens the scene once
  per placement, and caches stacks and geometry per (face, rotation). A dragged point re-runs
  only the squish map at once and the designs 120 ms after the drag rests (coalesced).
  Auto, the field slice and the stamp checks follow.
- `FlexibleStagePage.swift`: layout from the Settings wizard (Exit top-left, one notice,
  one bottom-left panel with `PageChrome.edge` / `DS.Surface.panel` / `DS.Radius.panel`).
- `FlexiblePanes.swift`: Auto, Physics, the slice, Stamps and the stamp handles.
- `FlexibleCurveEditor.swift`: the curve is projected from world points every frame. Only
  the handles take touches, so the rest of the screen still orbits the part.
- `FlexibleOverlay.swift`: column quads on the face at core's `from_uv` + `entry_t`, with the
  02 §6 linear ramp for the dent.
- `FlexibleStamps.swift`: library, rasteriser, SVG/image import.

**Data bundling.** The Xcode Resources phase references core's own files (`../core/src/materials/flexible_materials.json`, `../core/src/materials/flexible_curves` as a folder, `../docs/design/flexibles/data/stamps.json`), the way `materials.json` is bundled. No copy is committed.

### Every hook line in #354's files

| file | lines | what |
|---|---|---|
| `LatticeSettings.swift` | +5 | `public var flexible: FlexibleStageSettings? = nil` (L1178–1179), `case flexible` in CodingKeys (L1917), `decodeIfPresent` (L1988), `encodeIfPresent` (L2168). Absent ⇒ nil ⇒ an untouched project's file is byte-identical (test). |
| `LatticeStageModeModal.swift` | +9 −2 | `onChooseFlexible: (() -> Void)?` (default nil) + `flexibleFocused` state + init parameter (L25–32); one `FlexibleStageCard` line in the card HStack (L75); max width 980 when three cards (L80). `LatticeStageMode` is **not** touched. |
| `WorkspacePlaceholder.swift` | +33 −3 | `showFlexiblePage` state (L673); joins `fullScreenPageUp` (L617); `latticeStageModeNeeded` also requires `flexible == nil` (L624); the modal call gains `onChooseFlexible:` (L1373–1376); `FlexibleStageSheet` + `FlexibleStagePage` presented next to the mode sheet (L1384–1394); `FlexibleStageChip` in the title slot (L2790–2792); one `.onChange(of: showLatticeWizard)` on the always-mounted background that sends the Settings door to the Flexible page under Flexible (L729–732). |
| `project.pbxproj` | +12 | three file refs, three build files, group entries, Resources entries (IDs `F1E0…`). |
| `TopOptBridge/include/module.modulemap` | +2 | `header "FlexibleBridge.hpp"`; overnight: `header "FlexibleLattice.hpp"`. |
| `MetalMeshView.swift` (overnight) | +4 −1 | the dent's opaque flag: `float solid;` in `VOut` (L426), `o.solid = in.flags.y;` (L487), fragment alpha `in.solid > 0.5 ? 1.0 : bodyAlpha` (L683–684). |

## Test evidence (raw, pasted, unedited)

**Targeted tests** (`swift test --filter "FlexibleBridgeTests|FlexibleStageTests"`, after the last commit):
```
	 Executed 32 tests, with 0 failures (0 unexpected) in 3.928 (3.940) seconds
```

After the sync, with the hook-adjacent suites
(`FlexibleBridgeTests|FlexibleStageTests|LatticeStageModeTests|LatticeSettingsPersistTests|ProjectStoreTests|UndoHistoryTests`):
```
	 Executed 62 tests, with 0 failures (0 unexpected) in 3.877 (3.890) seconds
```

**Full app suite:** see "Full suite" below; it was started on `dcae9a03`.

**New tests**

- `FlexibleBridgeTests` (17), each checked against core:
  - catalogue: varioShore offers exactly [190, 220, 240]; every calibrate_first filament
    predicts nothing, with core's reason;
  - temperature note;
  - **0.292 MPa** for 20 % gyroid (core ρ 0.226) at 190 °C at the last tabulated strain,
    read through the bridge; the strain comes from `curveSet.strainMeasuredMax`, not a typed
    number;
  - 205 °C is refused as `temperature_not_tested`;
  - the inverse round-trips through the forward to 1e-9;
  - σ(ε) samples: none past the data;
  - **the pen curve passes through its points** and never overshoots its neighbours;
  - core's refusal sentence;
  - the stamp force rule;
  - **the box face's frame**: load −Z, 100 × 100, tied, Y = load × X, and the linked end is
    region 100 at 100 %;
  - rotation 90° is orthogonal;
  - design target = S × deepest (from core's own squish map);
  - tier band = core's literature band;
  - the density slice is owned by 101;
  - calibrate_first is refused with no columns;
  - **same-stack conflict names 100 and 101**;
  - check stamp: depth or beyond-data, never both; a heavy press leaves the data;
  - Auto: sentence + reasons + 6 candidates;
  - the job block reads back through `parse_job`.
- `FlexibleStageTests` (15):
  - **run job → core's `parse_job` round trip**: material, temperature, topology, feel,
    beads, bead width 0.42, rotation, kg→N at 9.80665, deepest, both curves, skin, resting
    face;
  - auto temperature + centre→edge round trip;
  - design + check stamps round-trip as core grids;
  - refusals: no filament, no loaded face;
  - the scene job opens a real scene;
  - **every library stamp at 3 pitches passes core's `stamp_grid_error`**, with cell ≤ ½
    pitch;
  - stamp size and rotation;
  - whole-face stamp stays on the face;
  - image: darker presses harder;
  - SVG outline filled;
  - settings round trip inside `LatticeSettings`;
  - **an untouched project is byte-identical**;
  - delete-and-re-ask clears Flexible;
  - **undo / redo through the project's history**;
  - kg→N.
- Probes (skipped unless an environment variable is set): `FlexibleTimingProbe`
  (`FLEX_TIMING=1`) and `FlexibleSliceProbe` (`FLEX_SLICE=1`).

**Known pre-existing failures** (#354's list, as quoted in C1's handoff):
- `AppModelTests`: the three 3MF tests (no lib3mf in a worktree macOS slice; this worktree's
  core was built with `LIB3MF_PREFIX=/nonexistent`, as the memory recommends);
- `OrganicSampleCubeTests.testThickerIsLive…`;
- `OrganicVariantCacheTests.testTheKeyIgnoresThickness…`;
- `LatticeCellGradingTests.testGradingChangesTheRenderedLattice`: reproduced on #354's
  head `8105522b` with its own core (see the overnight round).

PR (draft): https://github.com/Anarkissed/TopOpt/pull/362 · CI: the PR's checks tab.

## Overnight round (2026-09-29, while you slept)

### In plain words

- **The dent reads through the part.** While a dent is shown, the part drops to 30 %
  opacity and the dented face map stays at 100 %.
- **Split faces work as loaded faces.** A face you split on the Surface stage offers each
  half as its own loaded face. A tap picks the half you touched, using the Surface stage's
  own rule. Core frames each half from its own triangles, so a half of the pad's top is
  50 × 100, not 100 × 100. The names read "face 1 · top A".
- **Generate lattice.** When every loaded face has a design core accepted, a **Generate
  lattice** button appears at the bottom right. If it can't run yet, the button says why
  in one sentence (no filament, calibrate-first, a shared stack, or a face core refused).
  - Generating builds the lattice from core's assembled density field. The part becomes a
    ghost (18 %), the lattice is drawn inside it, and **the squish plays on repeat**:
    rest → full design load → rest, every 2.4 s. The dent and the lattice move together.
  - **Hide / Show lattice** and **Generate again** sit beside it. "Out of date" shows
    when you change a face after generating.
- **Export.** The Export button opens a modal with two cards:
  - **STL:** the part with its lattice as one closed solid. Draft / Standard / Fine set the
    sampling. The card shows the size before you export, a progress bar, Cancel (which
    deletes the partial file), and then the share sheet. Above 500 MB it warns that a
    slicer may be slow to open the file.
  - **G-code:** greyed out, with the reason: "TopOpt does not slice (ARCHITECTURE §2)".
    What comes next (DECISIONS 2026-09-27 item 6) is post-processing your sliced G-code
    for foaming filaments.

**Please look at these three things:**

1. **The STL is big.** The 100 × 100 × 20 mm pad, gyroid, with one 0.42 mm bead per wall:
   | quality | pitch | triangles | size |
   |---|---|---|---|
   | Draft | 0.210 mm | ~17 M | 824 MB |
   | Standard | 0.168 mm | ~27 M | 1.3 GB |
   | Fine | 0.140 mm | ~40 M | 1.9 GB |

   A whole-part lattice meshed finely enough to keep a 0.42 mm wall closed is simply that
   large. The honeycomb is about 60 % of these sizes. Options are yours:
   - decimate flat regions;
   - export only the lattice region and let the slicer fill the rest;
   - go the G-code route sooner.
2. **The lattice is a layer drawn over the part, not occluded by it.** You see every wall
   through the ghost body. That is on purpose for an x-ray look, but the part's near side
   does not hide the far walls.
   - The composed frame (`page_composite_pad_gyroid_{rest,full}.png`) shows the cost: the
     lattice also covers the dent's colour map. Only the map's rim and a few deepest
     (yellow) spots show through the pores.
   - The squish still reads as a sunken centre.
   - If you want the map on top, or the walls hidden where the body is in front, the
     follow-up is folding the march into MetalMeshView's passes. The octet did this.
3. **I could not run it on the simulator tonight.** Launching the app on my simulator
   (147E56A1, not yours) was refused by the permission check, and I did not work around
   that. The new build is installed there, but none of the overnight screens has been
   seen on a device. The evidence below is the preview's own shader rendering offscreen,
   not screenshots.

### Your rulings this round, and where they live

| ruling | where |
|---|---|
| "the dent to show via an opacity drop in the model (but the dent is full 100% opacity)" | `FlexibleStagePage.dentBodyAlpha = 0.3`. The dented quads carry tint `flags.y = 1` (`FlexibleOverlayMesh.tints`), and `MetalMeshView` keeps those fragments at alpha 1 (hook below). |
| "work on the split faces" | `FlexibleRegions.swift` |
| "the lattice generated when everything is done and then an animation showing the squishing of the model playing on repeat with an 'export' button that will pull up a modal to either export gcode or an stl" | the Generate / Export pills, `FlexibleLatticeGeneration.swift`, `FlexibleExportSheet.swift` |
| "there is no core yet for Flexibles, so your preview will be the source of truth" | `FlexibleLatticeField.swift` defines the geometry once. The renderer (MSL) and the exporter (C++) are held to it by tests. |
| G-code: "STL now, G-code next" | the G-code card says "Not ready yet" and why |
| Generate: "Button + design load" | the loop plays each face's own design load |

### The lattice, defined once (`FlexibleLatticeField.swift`)

- **Input.** Core's assembled density field for the faces' current designs
  (`FlexibleScene.densityField` → `assemble_density_field`).
- **Gyroid.** Walls are whole beads (R1), t = beads × bead width. The cell follows ρ
  continuously, with L = 3.0915 t/ρ (03-generators §3), clamped to ρ ∈ [0.05, 0.9].
- **Honeycomb.** One cell for the whole part, d = 2t/ρ̄ (03 §4, uniform d in v1), as prisms
  along the build direction.
- **Skin.** Default 0.8 mm of solid under every face. A loaded face with skin off lets the
  lattice run to its surface.
- **What the preview draws:** the walls only,
  `F = max(wall, dRegion, dPart, dSkin)`. The body and skin are the ghosted mesh.
- **What the STL writes:** the body plus the walls,
  `S = min(max(dPart, −max(dRegion, dSkin)), F)`.
  - ★ The spec first said `min(dRegion, dSkin)`, which made every skin air and the part
    outside the region hollow. Both my tests and the exporter's builder caught it
    independently; it is fixed, and the change is recorded in the file's header.
- **Three copies of the field, held together:**
  - **Swift reference.**
  - **C++ exporter (`flexible_lattice.cpp`):** bit-identical at 4,000 points on each of five
    fields (graded ρ from 0.01 to 1.0, a region edge, four build directions).
    - Controls: the old π rounding gives 1,220 differing values, and a wall one ulp
      thicker moves ~1,000.
    - To get there, the C++ now uses Swift's `Float.pi` (rounded toward zero) and
      `simd_normalize`, both found by the verifier.
  - **Metal shader:** within 1.2e-4 mm (gyroid) and 2.4e-6 mm (honeycomb) at 256 points.
    The GPU's own sin/cos is the gap.

### The preview renderer (`FlexibleLatticeRenderer.swift`, `FlexibleLatticeShader.swift`)

- **Technique.** Built on the octet preview's approach: a per-pixel sphere-tracer of the
  field on a transparent layer above MetalMeshView. It takes no touches, so orbiting still
  reaches the part.
- **Rays.** Unprojected in double on the CPU. Inverting in single precision is what cost
  the octet preview 1–4 px of swim.
- **Squish.** The shader inverts 02-squish-model §6's ramp per sample: a point at t in a
  column moves s·d·(exit − t)/(exit − entry) along the load. The depths are core's
  buildable depths (`FlexibleSquishFace(stack:design:)`). One page clock drives both the
  dent and the lattice, so they stay in phase.
- **Frame time at 1024² on the M2 Pro** (median):
  | | rest | squished |
  |---|---|---|
  | gyroid | 15–18 ms | 25–26 ms |
  | honeycomb | 4–5 ms | 8–9 ms |

  The drawable is capped at 1152 px, as for the octet.
- **March cap.** The gyroid step cap is 0.1 cell. At 0.25, 2,203 px disagreed with a fine
  reference march at 768²; at 0.1, 95 px did.

### The STL exporter (`flexible_lattice.cpp`, `FlexibleLatticeExport.swift`)

- **Streaming.** Marching cubes over `solid`, streamed: two sample layers in memory and a
  1 MiB write buffer. The triangle count is patched in at the end.
- **Test box (30 × 30 × 12 mm).**
  - The mesh is closed: every directed edge is matched once each way, and a flipped facet
    shows as a failure.
  - It winds outward.
  - Its volume is within 0.9 % (gyroid) and 1.4 % (honeycomb) of a Monte-Carlo integral of
    the Swift field.
  - It is deterministic.
- **Cancel** deletes the partial file.
- **Off the main thread.** The page runs the export off the main actor and caches the size
  estimate per lattice and pitch.

### Hook lines added this round (in #354's files)

| file | lines | what |
|---|---|---|
| `MetalMeshView.swift` | +4 −1 | `float solid;` in `VOut` (L426), `o.solid = in.flags.y;` (L487), and in the fragment `float a = in.solid > 0.5 ? 1.0 : bodyAlpha; return float4(rgb * a, a);` (L683–684). No other tint writer uses slot 5 (checked: SurfaceTint writes slot 4 only), so every other screen is unchanged. |
| `TopOptBridge/include/module.modulemap` | +1 | `header "FlexibleLattice.hpp"`, the exporter's POD API. |

All other work this round is in new files:

- `FlexibleRegions`
- `FlexibleLatticeField`, `FlexibleLatticeGeneration`, `FlexibleLatticeGlue`
- `FlexibleExportSheet`
- `FlexibleLatticeRenderer`, `FlexibleLatticeShader`
- `FlexibleLatticeExport`
- `flexible_lattice.cpp` and `FlexibleLattice.hpp`
- five test files

### Evidence (`docs/handoffs/evidence/2026-09-29-flexible-screens/`)

- **Lattice layer, drawn offscreen by the preview's own shader.** These are not device
  screenshots. The part is settled as the page draws it, and the dent is ×3.
  - C1's pad designed at 30 kg: `lattice_pad_gyroid_{rest,half,full}_x3.png` and
    `lattice_pad_honeycomb_{rest,half,full}_x3.png`.
  - The pad split at x = 50, halves at 10 kg and 25 kg (buildable deepest 2.25 mm and
    2.90 mm): `lattice_split_pad_10kg_25kg_{rest,full}_x3.png`.
- **The page's frame, composed offscreen from its own two renderers:**
  `page_composite_pad_gyroid_{rest,full}.png`. MeshRenderer draws the settled overlay mesh
  at the 18 % ghost, with the dented map opaque and dented ×3 × amplitude. The lattice layer
  is laid over it with the page's projection. This is the closest I could get to the screen
  without a launch.
- **Regenerate** with
  `FLEX_EVIDENCE_DIR=<dir> swift test --filter FlexibleLatticeEvidenceProbe`.
- **Dent through a 30 % body** (on the device, before this round's launch refusal):
  `s5_pad_dent_body_30pct_map_opaque.png`.

### Tests

`swift test --filter Flexible`, after the last commit:
```
Test Suite 'FlexibleLatticeFieldTests' passed at 2026-09-29 04:42:37.324.
	 Executed 4 tests, with 0 failures (0 unexpected) in 3.668 (3.669) seconds
Test Suite 'FlexibleLatticeRendererCoverageTests' passed at 2026-09-29 04:42:38.358.
	 Executed 2 tests, with 0 failures (0 unexpected) in 1.033 (1.033) seconds
Test Suite 'FlexibleLatticeRendererTests' passed at 2026-09-29 04:42:44.725.
	 Executed 11 tests, with 1 test skipped and 0 failures (0 unexpected) in 6.366 (6.367) seconds
Test Suite 'FlexibleRegionsTests' passed at 2026-09-29 04:42:44.775.
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.050 (0.050) seconds
Test Suite 'FlexibleSliceProbe' passed at 2026-09-29 04:42:44.775.
Test Suite 'FlexibleStageTests' passed at 2026-09-29 04:42:46.536.
	 Executed 15 tests, with 0 failures (0 unexpected) in 1.760 (1.762) seconds
Test Suite 'FlexibleTimingProbe' passed at 2026-09-29 04:42:46.537.
	 Executed 63 tests, with 4 tests skipped and 0 failures (0 unexpected) in 18.180 (18.186) seconds
	 Executed 63 tests, with 4 tests skipped and 0 failures (0 unexpected) in 18.180 (18.187) seconds
```

New this round:

- **`FlexibleRegionsTests` (3):**
  - sectors are declared, named and picked by the side of the tap;
  - core frames a sector from its own half;
  - the overlay replaces only the sector's triangles.
- **`FlexibleLatticeFieldTests` (4):**
  - core's field becomes filled grids;
  - walls exist inside and the skin is solid;
  - skin off reaches the face;
  - the honeycomb is a prism along the build axis.
- **`FlexibleLatticeExportTests` (8):**
  - C++ = Swift, both to 1e-4 and bit-exact;
  - skin and body are solid;
  - closed, wound, and the right volume;
  - deterministic;
  - cancel;
  - two layers held (self-reported);
  - refusals.
- **`FlexibleLatticeRendererTests` (11):**
  - the shader compiles;
  - the uniform layout matches the MSL, field by field;
  - the GPU matches Swift, and the squish probe matches the Swift pullback;
  - the pullback inverts the ramp;
  - coverage, and the two topologies differ;
  - s = 0 draws exactly the rest lattice;
  - the march matches a fine reference march, with controls that go red;
  - frame time;
  - frames run only while the squish loops.

Each comparison has a control that goes red.

**Full app suite.** It was started on `dcae9a03`, before this round. The raw result is
under "Full suite" below.

- **Tonight's MetalMeshView hook.** I ran the 111 tests that draw through MetalMeshView's
  fragment shader on HEAD `fe9dc359`, and all passed:
  - `LatticePreviewBodyAlphaTests`, `UnifiedShadingTests`, `ViewerVisibilityRegressionTests`
  - `StageBackdropTests`, `SurfaceStageTests`, `SurfaceRound7Tests`
  - `FaceSelectionTests`, `ContactShadingTests`, `ViewerTests`
  - `FaceProtectionTests`, `LatticeGBufferMaskTests`
  ```
  	 Executed 111 tests, with 0 failures (0 unexpected) in 81.290 (81.299) seconds
  ```
  They rewrite `docs/handoffs/assets/120_*.png`; I restored those with git.
- **`LatticeCellGradingTests.testGradingChangesTheRenderedLattice` is PRE-EXISTING.** It
  fails identically on #354's head `8105522b` built with its own core
  (`GRADING lit uniform=3720 graded=3719 moved=298 noiseFloor=0 levels=[0.0, 1.0, 2.0]`,
  so 298 against a threshold of 500). It sits in #354's octet renderer, which this branch
  does not touch.
- **`0191aa6a` (the renderer, as cherry-picked) does not build on its own.** It declares two
  names the branch already had; the next commit, `e5247c45`, reconciles them. The tip builds.
  Keep this in mind if you bisect.

### What I did NOT do (this round)

1. **No on-device check of the overnight screens.** The simulator launch was refused
   (above).
2. **The lattice is not occluded by the body** (above).
3. **No decimation**, so the STL sizes are as in the table above.
4. **The G-code card is informational only**, as ruled.
5. **Draw-order limitation with the translucent body.** The body is drawn without depth
   writes while it is translucent. So an opaque dented quad drawn after a nearer
   translucent wall can overwrite it. From normal angles it reads correctly.
6. **The squish is the 02 §6 linear ramp.** It is a picture of the design, not a
   simulation.

## What I did NOT do

1. **Simulator-driven SVG/image import.** The file picker is wired, and the import and
   rasterisation are unit-tested. I did not put a file into the simulator's Files app to drive
   it end to end.
2. **The dent reads only from a low angle.**
   - On the pad, ×3 on a 3 mm squish is subtle from above.
   - On the M2 stand, the 02 §6 ramp moves the part's own vertices through the whole stack,
     and at ×8 that visibly distorted the cradle. The exaggeration is now capped at ×4.
   - Whether the part's vertices should move at all, or only the face, is your call.
3. **The centre→edge baseline is a drawing aid.** It runs from the face's boundary to the
   column core's `edge_fraction` calls most-inside, along the frame's X. The curve's values are
   core's.
4. **No skin geometry.** `skin_on` is saved and sent, and core records it only (C1 #9).
5. **No bead-path preview or print settings.** Those are A2 and C5. (An STL export of the
   app's own lattice now exists: see the overnight round.)
6. ~~**Face picking uses the importer's faces (one region per face).**~~ Done in the
   overnight round: split sectors are loaded faces (`FlexibleRegions`).
7. **Undo is the project's snapshot history.** A curve drag is one step once it rests.

## Warnings for the next run

- **Taps on the simulator need a short press** (`duration` 0.1–0.15 s); instant taps were
  sometimes dropped. The screenshot → points factor depends on the image size: 1032 pt ÷
  image width.
- **Interop copies.** Never index a C++ vector member in a Swift loop; convert it with
  `Array(...)` once (see the timing above).
- **`swift test` rewrites other tasks' evidence.** Check `git status` after the full suite.
- **Seeded test projects.** My simulator is a separate device, "iPad Pro 13 Flexible-A1"
  (`147E56A1-…`). The three test projects on it were seeded by copying your M2 project and
  C1's pad STL. Your device was not touched.

## Full suite

`swift test` (whole package), started 02:30 on `dcae9a03`, with its own scratch path. It is
slow tonight because other sessions' suites are running on the same machine.

**Status at the time of writing: STILL RUNNING.** 690 test cases have passed. The failures so
far are all known pre-existing ones:
```
TopOptFlowsTests.AppModelTests testReopenedThreeMFProjectReimportsTheStlWorkingCopy
TopOptFlowsTests.AppModelTests testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance
TopOptFlowsTests.AppModelTests testThreeMFImportOptimisesOnDeviceEndToEnd
TopOptFlowsTests.LatticeCellGradingTests testGradingChangesTheRenderedLattice
```
The three `AppModelTests` 3MF tests fail because a worktree's macOS core has no lib3mf.
`LatticeCellGradingTests` also fails on #354's own head (see above).

## Blocked
None. No core brief was needed: every number on screen comes from the C1 bridge contract.
