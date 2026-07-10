# ROADMAP.md — Task checklist

> Agents: take the **topmost unchecked task** in the active milestone. One
> task per run. Check the box only when all CI is green. Do not reorder,
> reword, add, or remove tasks — if a task is wrong or too big, write a
> `## Blocked` handoff and stop.
>
> Active milestone: **M7**

## M1 — Import & voxelize

- [x] M1.1 Repo scaffold: CMake project, `core/` layout per ARCHITECTURE §3,
      CI workflow that builds and runs an empty ctest suite on Linux with
      OCCT + Eigen + lib3mf installed. Green pipeline is the deliverable.
- [x] M1.2 `materials/` loader: parse materials.json, strict schema
      validation per ARCHITECTURE §6, reject bad files. Unit tests incl.
      malformed inputs.
- [x] M1.2b Add loader tests: duplicate top-level material name rejected;
      on-disk load of the committed core/src/materials/materials.json succeeds.
- [x] M1.3 STL import + watertight/manifold check. Fixtures: golden cube,
      sphere, and a deliberately broken (open) mesh that must be rejected
      with a diagnostic.
- [x] M1.4 STEP import via OCCT + tessellation with controllable deflection.
      Fixtures: STEP cube (volume exact to 1e-6 relative), cylinder
      (volume within 0.1% at fine deflection, convergence shown at 3
      deflection values).
- [x] M1.5 Solid voxelizer: surface mesh → filled voxel grid at resolution N.
      Tests: cube voxel count exact; sphere volume within 2% at 128³;
      grid stores per-voxel tags (interior / surface / user-tagged).
- [x] M1.6 Face tagging: given a STEP face ID, tag its voxels as
      LOAD or FIXTURE. Test: cube fixture — tag one face, assert tagged
      voxel set is exactly the expected slab.

## M2 — FEA (isotropic)

- [x] M2.1 Hex element: 8-node stiffness matrix for given E, ν. Test against
      known reference matrix values.
- [x] M2.2 Global assembly + Dirichlet BCs + point/distributed loads on
      tagged voxels. Small hand-checkable 2×1×1 problem solved exactly.
- [x] M2.3 CG solver w/ Jacobi preconditioner over Eigen; converges on
      64³ problems in CI time budget (< 5 min).
- [x] M2.4 **Gate V1**: cantilever + simply-supported beam vs Euler–Bernoulli,
      ≤ 2% error, convergence across 3 resolutions. Von Mises stress field
      output added.

## M3 — SIMP (isotropic)

- [x] M3.1 Void-DOF safety gate (prerequisite for all SIMP FEA). Before any
      SIMP task calls fea_solve_cg on a density field: pin or filter free DOFs
      whose K_ff diagonal is zero/near-zero (nodes attached only to void/near-
      void voxels), and add a null-space / zero-pivot guard to the CG path so an
      under-constrained or singular system throws instead of silently returning
      a garbage or NaN field (Jacobi preconditioner divides by the zero
      diagonal). Test: a grid with an interior void node throws or is correctly
      filtered; a fully-solid grid is unaffected (existing fea_cg/fea_assembly
      still green). No later M3 task may call the solver until this box is checked.
- [x] M3.2 Density field + SIMP-penalized stiffness (p=3), compliance +
      sensitivities. Finite-difference check of sensitivities on a tiny grid.
- [x] M3.3 Density filter (radius ≥ 1.5 voxels) + Optimality Criteria update.
      2D-equivalent slice reproduces the classic 99-line MBB result pattern.
- [x] M3.4 Full 3D loop with volume-fraction target + convergence criteria.
      **Gate V2** on 3D MBB + cantilever vs fixtures/benchmarks.json.
- [x] M3.5 Marching cubes on final density (threshold 0.5) + cleanup.
      **Gate V3** property suite wired to run on every optimizer output in
      all future tests.
- [x] M3.6 Multi-variant runner: one job → volume fractions [0.7, 0.5, 0.3]
      → three meshes + per-variant compliance report.
- [x] M3.7 Passive regions (keep-in / keep-out). A per-voxel design mask
      (Active / FrozenSolid / FrozenVoid) as a separate array, NOT new
      VoxelTag values (a frozen voxel may also be Load/Fixture). FrozenSolid:
      rho pinned 1, excluded from OC update; FrozenVoid: rho pinned 0,
      excluded from design and from FEA stiffness. Density filter must not
      bleed across mask boundaries (frozen voxels excluded from neighbor
      averaging of active voxels' physical density). Selection plumbing:
      mask_step_face(grid, model, face_id, mask_value, depth_voxels) — the
      M1.6 slab selection generalized with a voxel depth. Tests: a cantilever
      with a FrozenVoid channel produces a design with the channel empty and
      compliance worse than unconstrained; FrozenSolid voxels end at rho=1;
      Load/Fixture voxels are implicitly FrozenSolid (V3 retention becomes
      structural, not emergent). 
      Completion requirement: property_v3 group 4 turns ON the retention
      assertion (gate_load_fixture_retained()) on real optimizer output —
      Load/Fixture pinning makes it structural, so the gate must be asserted,
      not just reported, before this box is checked.

## M4 — Anisotropy & orientation

- [x] M4.1 Transversely isotropic hex element (z_knockdown on the layer
      normal axis). Isotropic mode preserved; V1 must still pass in
      isotropic mode.
- [x] M4.2 Self-weight loading mode (gravity × density × voxel volume).
      **Gate V4** column test.
- [x] M4.3 Orientation candidates: 6 axis-aligned + face-normal-aligned +
      coarse sphere sampling (≤ 26 dirs). Support-volume proxy metric
      (overhang voxel count > 45°).
- [x] M4.4 Orientation scoring: combine support proxy + max tensile stress
      across layer planes (knocked down). **Gate V5** hook fixture ranks
      correct orientation first.

## M5 — Variants & settings

- [x] M5.1 Settings rule engine: inputs = material, worst-case stress margin,
      part size; outputs = walls, top/bottom layers, infill % + pattern name.
      Rules table lives in `settings/rules.json` (human-tunable). Unit tests
      per rule boundary.
- [x] M5.2 Job report: single JSON per run — variants, volume saved, max
      stress, margin, orientation, settings. Schema-validated in tests.
- [x] M5.2b Min-feature print warning: the per-variant job report includes
      min_feature_violations (from check_v3) and a human-readable warning
      when it is > 0 (e.g. "N features may be thinner than 2 voxels /
      reliably printable width — consider a higher volume fraction variant
      or finer resolution"). Report-only: does not gate or modify geometry.
- [x] M5.3 `minimize_plastic` end-to-end: self-weight + auto volume-fraction
      ladder, stopping when margin < 1.5. Integration test on bracket
      fixture.

## M6 — Export & CLI

- [x] M6.1 3MF export (lib3mf) + STL export. Round-trip: export → re-import →
      V3 properties hold, volume within 0.5%.
- [x] M6.2 `topopt-cli run job.json`: the canonical headless entry point
      driving the full pipeline. Integration test = the demo job checked
      into fixtures.
- [x] M6.2b Re-enable exact volume/bbox assertions in cli_demo against the corrected expected_values.json; flip marching-cubes winding to outward and tighten M6.1/M6.2 volume comparisons to sign-exact."
- [x] M6.3 (post-M6, before M7 ships) Minimum length scale via single-field
      Heaviside projection: design -> density filter -> tanh projection
      (sharpness beta) -> analysis, with the projection derivative chained
      into the sensitivities, and beta-continuation (double beta every ~50
      iterations, beta 1 → 32, move schedule per benchmarks.json, re-converging at each step). Cheap variant
      ONLY: no robust eroded/nominal/dilated three-solve formulation; thin-
      gap protection comes from M3.7 FrozenVoid regions, and M5.2b's warning
      remains the backstop for residual thresholding artifacts. BLOCKS ON:
      maintainer regenerates fixtures/benchmarks.json with the identical
      projection + beta schedule via the independent reference implementation
      BEFORE this task starts (fixture discipline). Expect 1.5-3x compute per
      optimization; measure on-device before and after.

## M7 — iPad app (design: docs/design/TopOpt_dc.html)

> M7 rules of engagement: tasks below are explicitly M7-scoped, so workers MAY
> touch /app/ for them (worker rule 9). M7.0x tasks are core/ tasks — normal
> rules, full Linux CI coverage. /app/ code is NOT covered by Linux CI: its
> verification standard is `xcodebuild test` on the maintainer's Mac (raw
> output pasted in the handoff) plus maintainer device QA; the reviewer audits
> diffs as usual. The committed design export docs/design/TopOpt_dc.html is
> the visual source of truth — match it, do not reinterpret it.

- [x] M7.0a Core: progress + cancellation. `SimpOptions` gains an optional
      progress callback (iteration, compliance, change) and a polled
      cancellation flag checked once per OC iteration; `simp_optimize` returns
      a cancelled status cleanly (no partial UB), and `minimize_plastic`
      forwards per-rung progress (rung index, rung count, iteration) and
      cancellation. Tests: callback invocation counts, monotone iteration
      numbers, cancel mid-run leaves a valid (rejected) result, zero overhead
      when callback absent. Pure core; no /app/.
- [x] M7.0b Core: visualization data exposure. `MinimizePlasticVariant` gains
      (a) the printed-voxel von Mises field (grid-indexed, zeros elsewhere),
      (b) the extracted+cleaned variant mesh (already computed inside
      check_v3 — expose, don't recompute), (c) `support_volume_voxels` for the
      analysed build direction (M4.3 proxy), and (d) `mass_grams` =
      density_g_cm3 × printed volume (spacing-aware). Tests: field/mesh
      consistency with check_v3, mass arithmetic on a known cube, support
      count matches count_overhang_voxels. Pure core; no /app/.
- [x] M7.1 App scaffold + bridge. Xcode project in /app/ (iPad SwiftUI target
      "TopOpt", Swift/C++ interop enabled), core built into the app via CMake
      (static lib or xcframework; OCCT/lib3mf dylibs handled per §10 LGPL
      dynamic-linking), plus a `TopOptKit` Swift wrapper exposing: load
      materials.json, import STEP/STL, voxelize, tag faces, run
      minimize_plastic (with M7.0a progress), export. Deliverable: app builds
      and shows a bridge smoke result (material count + imported-mesh triangle
      count); a macOS unit-test target exercises the wrapper headlessly —
      raw `xcodebuild test` output in the handoff.
- [x] M7.1b iOS dependency slice (STEP-on-device). The app currently links
      OCCT only for macOS, so STEP import fails on iOS/simulator with "requires
      OpenCASCADE"; STL works (no OCCT dependency). Build the C++ dependencies
      for iOS so STEP import (and lib3mf export, for M7.9) work on device and
      simulator. BUILD SYSTEM ONLY — iOS CMake toolchain (arm64-apple-ios
      device + arm64 simulator), cross-compile scripts under app/scripts/, and
      SwiftPM/xcodeproj binary-target wiring; no Swift view code, no /core/
      source, no fixtures. OCCT dynamically linked, LGPL §10 preserved (no
      static archive, no modified OCCT sources); package as xcframeworks. The
      existing macOS test path (app suite + 25-test core suite) must still
      build and pass — no regression to maintainer verification. NOTE: the
      agent cannot run Xcode or cross-compile iOS libs — deliverable is
      scripts + wiring + exact maintainer instructions; ending Blocked awaiting
      maintainer build output is a successful run. Gate (maintainer): build the
      iPad target, run in the simulator, import l-bracket.step, succeeds with
      no "requires OpenCASCADE" toast. Also fix the user-facing error text so a
      failed/unsupported import reads in plain language, not "requires
      OpenCASCADE."
- [x] M7.1c Harden the iOS-OCCT manifest wiring (build system only). The
      generated framework list lived inside the committed Package.swift, so a
      stray `git add -A` re-committed the per-machine populated list and broke
      macOS/CI (see run 039). Move the list OUT into a git-ignored file
      (occt-frameworks.generated.json) that Package.swift reads at manifest-eval
      time; absent file (fresh checkout/CI) → empty list → OCCT-free default,
      macOS build/tests green, no iOS binaryTargets declared. build_occt_ios.sh
      writes that git-ignored file (not Package.swift) and, because the list is no
      longer part of the manifest's content-hash cache key, explicitly
      invalidates the SwiftPM manifest cache (purge + mtime bump) so Xcode
      re-evaluates. Package.swift stays committed with no list and UNMODIFIED in
      git status after regenerating. No /core/, no Swift view code, no bridge.
- [x] M7.2 Design system. Extract the tokens from docs/design/TopOpt_dc.html
      (dark glass palette, accent, surface blur/opacity, radii, type scale,
      spacing) into DesignSystem.swift + reusable views: GlassPanel,
      GlassSheet, PillButton, SegmentedGlass, Toast, ProgressBar. SwiftUI
      previews for each; maintainer QA against the HTML side by side.
- [x] M7.3 Home + import flow. Home screen ("New TopOpt", recent projects
      grid), import sheet: UIDocumentPicker (STEP/STL), Filament(FDM)/Resin
      (SLA) segment, material dropdown populated from materials.json via the
      bridge, Cancel/Continue → workspace. Import errors (non-watertight STL
      etc.) surface the core diagnostic in a toast.
- [x] M7.4 Metal viewer v1. Render the imported tessellated mesh (bridge
      supplies vertices/normals/face ids), orbit + pinch-zoom camera matching
      the design's hint copy, matcap-style shading on the dark stage. No
      selection yet. Maintainer QA on device for feel.
- [x] M7.5 Face selection + groups. Face-pick via id buffer render pass;
      selection groups exactly per design (auto-named A/B/C…, color-coded,
      rename, remove, active-group highlight, face-count chips); "tap inside a
      hole selects the hole's face loop" (adjacent-face walk over the B-rep
      face adjacency the bridge exposes). Groups map to Fixture/Load/Frozen
      tagging via mask_step_face / tag_step_face.
- [x] M7.6-core Core/bridge: traction loads + passive BC shell (MOD-F1 D7).
      Forward mask_step_face so load/anchor faces freeze as an N-voxel passive
      shell (M3.7 design-mask); add a uniform-traction load path over a group's
      combined face area (consistent nodal loads, not a centroid point force) —
      if the core lacks a traction-assembly entry point, add it in /core/ with
      tests (known face + total force → expected nodal distribution; nodal loads
      sum to applied force). Supersedes M7.5b. Merge before M7.6-app starts.
- [x] M7.6-app Full Swift force/gravity experience (MOD-F1 D1-D6; match
      docs/design/TopOpt_force_proto.html and MOD_force_gravity_rework.md, do
      not reinterpret). Data model: gravity as a model-space unit vector from a
      tapped face normal; per-group Anchor|Load role; per-load direction
      (Gravity/Push/Pull) + weight (store kgf). UI: delete Orbit/Faces/Force
      modes (drag orbits, tap selects); post-import "which way is down?" gravity
      prompt → model settles onto a ground grid + contact shadow (reduced-motion
      = snap); persistent gravity chip w/ Change; Anchor|Load chip beside a
      selection (delete the implicit-anchor explainer); snap row
      (Gravity/Push/Pull); in-place weight pill (scrub + tap-to-type, kg/lbs);
      arrow rendering per D6; Optimize enabled only w/ ≥1 anchor + ≥1 load, label
      summarizes. Calls M7.6-core's bridge signatures. Headless tests for the
      data model; UI is maintainer device QA.
- [ ] M7.6-ring (deferred, v2) Constrained single-DOF rotation ring for custom
      load directions: 15° detents, haptic ticks, second ring after first
      commits, never a freehand drag. After M7.6-app is solid.
- [x] M7.7 Run screen. Optimize → minimize_plastic on a background queue with
      M7.0a progress driving the bar (per-rung + per-iteration); Cancel;
      "Run in Background" via BGProcessingTask with local notification on
      completion; failure states (CG non-convergence, all-rungs-rejected)
      rendered as design-consistent sheets, not alerts.
- [ ] M7.8 Results screen. Variant tabs (−% labels + mass_grams from M7.0b),
      variant mesh display with the morph/threshold scrub, stress overlay
      toggle (von Mises field → vertex colors, shared scale across variants),
      orientation sheet: M4.4 score_orientations result phrased per design,
      support estimate from support_volume_voxels (cm³ via spacing), "Layer
      shear" = the variant's max interlayer tension. PRINT TIME — maintainer
      decision required before this task starts: (a) rough heuristic
      (printed volume ÷ nominal flow rate, labelled "est."), or (b) omit in
      v1. Record in DECISIONS.md.
- [ ] M7.9 Export + share. Export .3mf sheet per design (M6.1 exporter via
      bridge), UIActivityViewController share, embed the M5.2 JSON report in
      the 3MF metadata + optional "Save report" as .json.
- [ ] M7.9b Sample model affordance + document types: import sheet offers
      "Load sample model" (imports the bundled sample_cube.stl) so a first-run
      user with no files isn't dead-ended; register .stl/.step document types
      (CFBundleDocumentTypes / UTImportedTypeDeclarations) so files open into
      TopOpt from Files/AirDrop.
- [ ] M7.10 Maintainer QA milestone (human, no agent): full-flow device pass,
      performance profile on target iPad (128³ end-to-end timing vs the M6.3
      projection cost decision), accessibility pass (Dynamic Type on sheets,
      VoiceOver labels on tools), App Store asset checklist.
- [ ] M7.11a Matcap rendering: replace the analytic clay shading with sampled
      matcap (material-capture) textures — load a matcap PNG into a Metal
      texture, sample it by the view-space normal (n.xy → UV), so shine,
      metalness, opacity-feel and rim are captured by the image. Ship 3–4
      built-in matcaps (clay, brushed metal, glossy plastic, translucent).
      Flat-normal clay from M7.4b stays the default/fallback. Tests: the
      normal→UV mapping is correct and clamped; built-in matcaps load.
- [ ] M7.11b Material picker UI: a panel to choose the active matcap from the
      built-ins and to IMPORT a user matcap PNG (UIDocumentPicker, the
      standard format other DCC apps use — Blender/ZBrush/Sketchfab matcaps
      drop straight in). Lives in the appearance surface (with M7.8). Persists
      the choice per project. Tests: import validates the image; selection
      drives the renderer.
- [ ] M7.Za STL selection honesty (small — recommend pulling forward to
      M7.1b's error-text cleanup): when a user taps a face in Faces mode on an
      STL (a mesh with no B-rep face ids), show a clear message instead of
      silently doing nothing — e.g. "Face selection needs a STEP file. STL
      models have no faces; full STL region tools are coming." Applies
      wherever face-tap returns nil for a faceless mesh. No selection logic
      change; purely the missing signpost.

- [ ] M7.Zb STL region selection (deferred to end): give STL/faceless meshes a
      real way to mark Fixture / Load / Frozen regions, feeding the SAME
      SelectionModel + tagging path M7.5 built for STEP faces (so downstream
      optimization is identical regardless of input format). Provide at least
      one of, ideally building up to all three:
        - coplanar-cluster grouping: auto-cluster adjacent triangles within an
          angle tolerance into pseudo-faces, so an STL gets face-like regions
          that tap-select like STEP faces (best default for mechanical parts);
        - paint select: drag across the surface to tag triangles into the
          active group;
        - box/volume select: position a box; triangles inside join the group.
      Maps groups to voxel tagging via the existing tag path (and mask path
      once M7.5b bridges it). Tests: coplanar clustering recovers the expected
      region count on a known STL; painted/boxed triangle sets tag the right
      voxels. This makes STL a first-class input, not just an optimize-with-
      defaults fallback.
