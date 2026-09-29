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
| `TopOptBridge/include/module.modulemap` | +1 | `header "FlexibleBridge.hpp"`. |

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
- `OrganicVariantCacheTests.testTheKeyIgnoresThickness…`.

PR (draft): https://github.com/Anarkissed/TopOpt/pull/362 · CI: the PR's checks tab.

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
5. **No bead-path preview, export or print settings.** Those are A2, C3 and C5.
6. **Face picking uses the importer's faces (one region per face).** Split sectors from the
   Surface stage (`FaceRegionModel` cuts) are not yet offered as loaded faces.
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

## Blocked
None. No core brief was needed: every number on screen comes from the C1 bridge contract.
