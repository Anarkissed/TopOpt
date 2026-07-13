# ROADMAP.md — Task checklist

> Agents: take the **topmost unchecked task in your track** (see the TRACK
> header in your worker prompt). One task per run. Do NOT check the box —
> report completion in your handoff; the maintainer checks it at merge (see
> DECISIONS 2026-07-11, concurrent mode). Do not reorder, reword, add, or
> remove tasks — if a task is wrong or too big, write a `## Blocked` handoff
> and stop.
>
> Active milestone: **M7**
>
> CONCURRENT TWO-TRACK MODE (per DECISIONS 2026-07-11). Two lanes run in
> parallel, each in its own worktree, each touching only its own tree:
>   • TRACK core  → M7-OPT block. Modifies /core/ ONLY.
>   • TRACK app   → M7-VIZ block. Modifies /app/ ONLY.
> A track's "topmost unchecked task" is the first `[ ]` WITHIN THAT BLOCK, not
> the global topmost. The two blocks share no files and no interfaces while
> live (interface freeze, DECISIONS 2026-07-11 rule 6). Tasks OUTSIDE these two
> blocks (M7-SHIP, M7-ML, parked) are single-track work — do not start them in
> concurrent mode; they run after a track closes and the maintainer re-points
> it. Some app tasks are DEPENDENCY-GATED (marked "GATED: waits on <task>") and
> are NOT eligible as a track's topmost until their gate is merged; skip a
> gated task and stop if it is the only thing left in the block.

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
- [x] M7.7 Run screen. Optimize → minimize_plastic on a background queue with
      M7.0a progress driving the bar (per-rung + per-iteration); Cancel;
      "Run in Background" via BGProcessingTask with local notification on
      completion; failure states (CG non-convergence, all-rungs-rejected)
      rendered as design-consistent sheets, not alerts.
- [x] M7.8 Results screen. Variant tabs (−% labels + mass_grams from M7.0b),
      variant mesh display with the morph/threshold scrub, stress overlay
      toggle (von Mises field → vertex colors, shared scale across variants),
      orientation sheet: M4.4 score_orientations result phrased per design,
      support estimate from support_volume_voxels (cm³ via spacing), "Layer
      shear" = the variant's max interlayer tension. PRINT TIME — maintainer
      decision required before this task starts: (a) rough heuristic
      (printed volume ÷ nominal flow rate, labelled "est."), or (b) omit in
      v1. Record in DECISIONS.md.
## Completed in PR #46 (record; do not re-task)

> The load-case + results work is DONE, merged/pending in PR #46. Recorded here
> so no agent re-opens finished work:
> - Self-weight gravity-units bug: FIXED (bridge sets opts.gravity = 9810 * 1e-9,
>   mirroring run_job.cpp). The core/CLI path was never buggy; gravity is
>   pre-scaled by the caller (g/cm^3 -> t/mm^3, 1e-9). DO NOT add any density
>   conversion inside /core/ (minimize_plastic / self_weight_loads) — it would
>   double-convert and re-break the other way (weak parts silently accepted).
> - Real load case: DONE. Core minimize_plastic now accepts options.external_loads;
>   self-weight is the fallback. The bridge tags the user's anchor faces as
>   clamped Fixture BCs and turns each Load group into distributed traction_loads
>   (per-group kgf->N). The hardcoded min-x clamp is now only the no-anchors
>   fallback. Tested (core scenario J + real-bridge l-bracket; 199 green).
> - Recommendation-driven variants: DONE (recommend the lightest safe design;
>   RECOMMENDED badge on the results screen) — replaces the fixed 30/50/70 ladder.
> - M7.8 results screen: DONE (variant tabs, mass, stress overlay, morph scrub,
>   recommended-orientation sheet), plus progressive streaming, history playback,
>   video export, and cross-launch persistence.
> MERGE NIT: PR #46's docs/ROADMAP.md contains a stray leftover conflict marker
> line (">>>>>>> Stashed changes"). Strip it before merge.
>
> STILL OPEN below: the honesty/confidence surface (M7.8b), which did NOT land in
> PR #46 — the results screen shows the recommended variant but not the explicit
> verified/margin/"test-print before safety-critical" recommendation. And "MORE
> plastic" (additive growth) is correctly still M7.dom, not in this PR.

## M7-OPT — optimizer capability track (ACTIVE: this is the current work)

> Ordering is deliberate. MMA lands and becomes the default engine BEFORE
> M7.dom, so the domain-expansion fixture is authored once against the final
> engine and fixtures/benchmarks.json is regenerated exactly once (at
> M7.mma.4). ML comes last and is gated on a maintainer decision: ML saves
> iterations; it does not add capability the physics tasks haven't already
> delivered. Task order is positional, top to bottom; identifiers are labels,
> not sequence.

- [x] M7.mma.1 MMA updater (Svanberg 1987), compliance objective + volume
      constraint only, as a drop-in alternative to Optimality Criteria behind
      `SimpOptions.updater = {OC, MMA}`. Default stays OC — NO fixture changes
      in this task. Asymptote init/adaptation and move limits per the paper;
      document constants in code comments. Tests: existing FD sensitivity
      checks pass unchanged; MMA reproduces the existing MBB + cantilever
      benchmark compliance within 2% of the OC references at the same volume
      fraction; iteration counts reported in the test log (informational).
      Pure core; no /app/.
- [x] M7.disp Expose the per-node displacement field on MinimizePlasticVariant
      (bridge visualization data — the M7.0b sibling of von_mises_field).
      WHY: M7.viz.3 (flex animation) needs the solved displacement to move mesh
      vertices; the app currently gets only the von Mises SCALAR (M7.0b), which
      cannot drive motion. The physics ALREADY EXISTS — SimpCompliance.solution
      (simp.hpp) carries the penalized FeaSolution (nodal displacements,
      DOF-ordered, size 3*fea_node_count). This task EXPOSES it; it computes no
      new physics and runs no new solve.
      ADD to MinimizePlasticVariant (pipeline.hpp), populated in
      minimize_plastic.cpp from the SAME final penalized solve that already
      produces von_mises_field (reuse the sc = simp_compliance(...) result's
      sc.solution, do not re-solve):
        std::vector<double> displacement_field;  // per-NODE, DOF-ordered
          (size 3*fea_node_count(grid)); [3n,3n+1,3n+2] = (ux,uy,uz) of node n
          in model units (mm). Zero on nodes attached only to void/non-printed
          voxels, mirroring how von_mises_field is zero off the printed set.
      Populate it beside the existing von_mises_field assignment in the
      per-variant stress loop; on the cancelled/aborted path leave it empty,
      exactly as von_mises_field is (pipeline.hpp cancel contract).
      BRIDGE: forward displacement_field through the TopOptKit bridge to Swift
      as the app-facing companion to the von Mises field, same mechanism.
      Additive field only — changes no existing signature, so the interface
      freeze holds; M7.viz.3 consumes it, no other bridge change.
      TESTS (Linux CI, pure core): displacement_field has size 3*node_count on
      an accepted variant; nonzero on loaded/printed nodes, zero on void-only
      nodes; matches sc.solution element-for-element (assert equality with the
      solve, not an independent value — this is exposure, not recomputation);
      empty on the cancelled path. Pure exposure of an existing field: no new
      fixture, no benchmark change, do NOT touch tests/fixtures/**.
- [x] M7.mma.2 Stress-constrained optimization on the MMA path: aggregated
      von Mises constraint (p-norm or KS — record the choice and the
      aggregation parameter/tolerance in DECISIONS.md) with adjoint
      sensitivities and stress relaxation for the singularity problem (qp or
      epsilon-relaxation; record which). Tests: finite-difference check of the
      aggregated constraint sensitivity on a tiny grid; PLUS the L-bracket
      stress case. The reference fixture is COMMITTED at
      core/tests/fixtures/demo/mma2_stress_fixture.json (maintainer-authored,
      independent NumPy FEA — this task is UNBLOCKED, consume it, do not
      regenerate). Assert its BEHAVIORAL INVARIANTS: (a) an unconstrained run
      leaves peak von Mises above stress_cap_mpa; (b) the constrained run
      satisfies the cap within the aggregation tolerance you record; (c) the
      constrained design's compliance >= the unconstrained design's at the same
      volume fraction (the constraint costs stiffness). Do NOT pin or assert an
      absolute von Mises value — the re-entrant corner is a mesh-dependent
      singularity (see the fixture's _why_no_pinned_stress note). Pure core;
      no /app/.
- [ ] M7.mma.3a Weighted-sum multi-load-case (OC path — do first). Objective
      C = Σ w_i·c_i over N load cases sharing grid/material/BCs/volume
      constraint; each c_i is one FEA solve against the same penalized K with a
      different RHS; gradient is the weighted sum of the per-case compliance
      sensitivities. STAYS ON THE OC PATH — the summed sensitivity feeds the
      existing oc_update/oc_update_masked unchanged, so it works through
      minimize_plastic with NO MMA and NO masked-MMA change (does not touch the
      M7.mma.4 boundary). MinimizePlasticOptions gains a load-case list
      (self-weight stays the empty-list fallback, as external_loads does now);
      minimize_plastic reports the WORST-case margin over the cases; job.json
      gains an additive `load_cases` array (a job without it parses exactly as
      today). BACK-COMPAT IS A HARD REQUIREMENT: N=1, w=1 must be byte-identical
      to today's single-load path — assert == physical_density and == compliance
      element-for-element against the current single-load call (mirroring the
      M7.disp exposure-equality test). Two-load test is an IN-CODE comparative
      invariant (optimize under load-1, show it's worse under load-2, show the
      multi-case optimum's worst-case is lower) — NO maintainer fixture, no
      tests/fixtures/** change. Keep any viz-field/stress reporting additive
      (interface freeze); if a bridge signature would change, STOP with a
      Blocked handoff. Pure core; no /app/.
- [ ] M7.mma.3b Worst-case / min-max multi-load-case (MMA — do second, after
      3a). min_rho max_i c_i(rho) s.t. the volume constraint, via the MMA bound
      formulation: auxiliary scalar z, min z s.t. c_i(rho)−z ≤ 0 for all i and
      V(rho)−V* ≤ 0 (m = N+1 constraints + the z variable). Requires a GENERAL
      m-constraint MMA dual solver — the existing m=1 single-bisection and m=2
      nested-bisection do NOT generalize to arbitrary N; implement the dual over
      the simplex×{μ≥0} (z-stationarity gives Σλ_i = 1) with proper projected
      ascent/Newton, plus the auxiliary-z handling. ROUTING (maintainer-decided):
      ship as a STANDALONE unmasked simp_optimize_minmax (the
      simp_optimize_stress precedent), tested directly — do NOT lift the masked-
      MMA rejection or wire into minimize_plastic's driver; the masked switchover
      is M7.mma.4's job. Convergence risk is real (per M7.mma.2): the test is a
      BEHAVIORAL invariant (multi-case optimum's worst-case compliance across the
      loads < the single-case optimum's worst-case), NEVER a pinned value; may
      need GCMMA-style conservative approximations to converge — if it can't be
      made to converge reliably in one run, STOP with a Blocked handoff rather
      than shipping a flaky solver. Pure core; no /app/.
- [x] M7.rmin Physical (mm-based) density-filter radius. BUG (diagnosis 060):
      the SIMP density-filter radius is hardcoded at 2.5 VOXELS
      (bridge.cpp:114, opts.simp.filter_radius; default 1.5 at simp.hpp:239)
      and never scales to physical size — so the minimum member thickness is a
      fixed voxel count regardless of resolution (~12% of the part at 20^3,
      ~2% at 128^3). Large/fine parts therefore proliferate thin members
      (the internal fin/ridge artifact). FIX: derive the voxel radius from a
      target minimum feature size in MILLIMETERS divided by grid spacing —
      rmin_voxels = min_feature_mm / grid.spacing — clamped to a sane floor
      (never below ~1.5 voxels, which is what suppresses checkerboarding).
      Pick a sensible default min_feature_mm (document the choice + reasoning
      in the handoff; a nozzle-scale value in the ~1.5-3mm range is reasonable
      for FDM). The physical length scale must be resolution-INDEPENDENT: the
      same part at different resolutions should yield the same minimum member
      thickness in mm. TEST: assert that for a fixed part at two different
      resolutions, the effective filter radius in mm is equal (within
      tolerance) — i.e. rmin_voxels scales with resolution such that
      rmin_voxels * spacing is constant. Also assert the checkerboarding floor
      holds (radius never drops below the suppression threshold). Do NOT change
      the optimizer, the objective, or the marshaling path (separate tasks).
      Pure core; the only bridge touch is replacing the hardcoded 2.5 with the
      physical derivation.
- [x] M7.infill-margin (core) Apply an infill knockdown to the ladder
      acceptance margin. Per DECISIONS 2026-07-11: the reduction-ladder
      acceptance test (minimize_plastic, the margin_stop gate ~line 270) must
      compare margin_stop against an INFILL-ADJUSTED worst-case margin =
      margin.worst_case * knockdown(infill_percent), not the raw solid margin.
      Add the infill % (and wall count if used) to MinimizePlasticOptions,
      threaded from the job/bridge; default to a value that reproduces CURRENT
      behavior when infill is unset/100% (knockdown = 1.0) so existing tests and
      benchmarks are byte-unaffected. The knockdown function is seeded
      conservative (document the curve + reasoning in the handoff; maintainer
      tunes later). Do NOT touch the FEA, the element stiffness, or the stress
      field — infill does NOT enter the solver (ARCHITECTURE §2). Tests:
      knockdown=1.0 (unset) reproduces current ladder behavior exactly; a low
      infill % produces a smaller adjusted margin and stops the ladder earlier
      (retains more material) than solid on a fixture where the raw margin is
      large. Pure core; the bridge threads the infill value.
- [x] M7.mma.4 Switchover: MMA becomes the default updater in
      minimize_plastic; OC stays available behind the option (retained, not
      deleted). BLOCKS ON: maintainer regenerates fixtures/benchmarks.json
      under MMA via the independent reference implementation BEFORE this task
      starts. All V-gates rerun green against the regenerated references;
      per-benchmark iteration count and wall time vs the OC baseline recorded
      in the handoff.
- [ ] M7.dom-core Design-domain expansion (additive optimization) — PHYSICS,
      NOT ML. Let the optimizer add material beyond the imported part so it
      grows ribs/gussets/buttresses a user wouldn't draw. The mechanism
      already exists (M3.7 masks: FrozenSolid=keep, FrozenVoid=exclude,
      Active=optimizer's choice). Add: voxelize a user-defined design volume
      (axis-aligned box in model space for v1) larger than the import, with
      imported-part voxels tagged FrozenSolid, caller-supplied keep-out boxes
      FrozenVoid, and the remaining volume Active. Acceptance test (Linux CI
      fixture): a THIN L-bracket wrapped in a corner design box grows a
      gusset along the inner-corner load path; keep-out stays empty; the
      original part is never removed. This is the "discovers structure the
      user couldn't" feature — fully FEA-verified, no ML. Pure core; no /app/.
- [ ] M7.dom-app Design-domain UI: size/position the design box in the viewer
      (per the design language — no new interaction paradigms); keep-out
      marked via the existing face-selection → FrozenVoid path (STEP input;
      STL keep-out arrives with M7.Zb — do NOT invent a painting UI here).
      Calls M7.dom-core through the bridge. Headless tests for the data model
      (box + keep-outs → expected mask counts on a fixture grid); UI is
      maintainer device QA.
      GATED: waits on M7.dom-core. Not eligible as TRACK app's topmost until
      M7.dom-core is merged; it is a core-dependent app task, run after the
      viz lane or once dom-core lands.
- [ ] M7.mma-projection Implement Heaviside projection support ON the MMA path
      (restores crisp-density boundaries for MMA runs; removes the Option-B
      temporary skip). Requires threading the projection derivative through the
      MMA sensitivities (projection chain rule) — MMA is gradient-based and
      sensitive to this, so validate convergence carefully (per the M7.mma.4
      scale-sensitivity precedent). Until this lands, MMA runs skip projection
      (softer boundaries). Pure core.

## M7-VIZ — result visualization track (TRACK app; ACTIVE, concurrent with M7-OPT)

> This lane draws fields the SHIPPED core already produces (displacement from
> the FEA solve, the von Mises field from M7.0b/M7.8) — it does NOT call the
> optimizer and does NOT depend on any in-flight M7-OPT task, which is exactly
> why it can run concurrently. /app/ only; Metal + SwiftUI. No Blender / no
> external render engine (the physics is already solved in core; this renders
> the existing solution — see the design conversation). Verification standard
> is xcodebuild test + maintainer device QA per DECISIONS 2026-07-09. Task
> order is positional. If a task needs a core field that does not yet exist,
> STOP with a Blocked handoff (interface freeze — do not add it to /core/
> yourself, and do not reach into the core track's work).

- [x] M7.viz.1 Stress map, scaled-to-limit (the honest heatmap). Replace any
      data-range auto-scaling with a color scale keyed to the material limit:
      green = comfortably below yield, through to red = at/above yield
      (worst-case per-variant, using the M7.0b von Mises field + the material
      yield already in the report). Shared scale across variants so colors mean
      the same thing everywhere. Include a legend that states the material and
      the yield value it is scaled to. This is the visual twin of the M7.8b
      honesty surface. Consumes existing fields only. xcodebuild tests for the
      value→color mapping (clamped, monotonic, yield boundary correct); visual
      QA on device.
- [x] M7.viz.2 Hot-spot callout. Find and label the single highest-stress
      point on the displayed variant with its actual value and its margin
      (value ÷ yield). A tappable marker that frames the worst point, so the
      user is not left hunting the red zone. Consumes the same von Mises field.
      xcodebuild test: the located max matches the field's max index; margin
      arithmetic correct. Visual QA on device.
- [x] M7.viz.3 Flex animation (the "wow"). Animate the FEA displacement
      solution: scale the per-vertex displacement 50–100x (user-adjustable
      exaggeration, default chosen for phone legibility) and animate the mesh
      from rest to full deflection and back. This is NOT a physics simulation —
      the displacement field is already solved; this only draws it. REQUIRES a
      per-vertex (or per-node) displacement field exposed through the bridge:
      if M7.0b / the current bridge exposes only the von Mises scalar and not
      the displacement vectors, STOP and file a Blocked handoff requesting the
      core field (interface freeze — the core track adds it, not you). Metal
      vertex animation; reduced-motion setting disables the loop and shows the
      full-deflection frame statically. xcodebuild tests where assertable
      (exaggeration scale, reduced-motion path); device QA for feel.
- [x] M7.viz.4 Load-path visualization. Show how force travels from the loaded
      region to the anchors, derived from the existing stress tensor field (the
      same data as the heatmap) — this is what reveals WHY the optimizer grew a
      rib where it did. v1 may be a principal-stress-direction / stress-flow
      overlay; if it needs a tensor field the bridge does not currently expose,
      STOP with a Blocked handoff rather than adding to /core/. /app/ only.
      Device QA for legibility; xcodebuild tests for any pure-data derivation.
- [ ] M7.viz.5 Progressive-disclosure tiers (Beginner / Intermediate /
      Advanced). ONE surface, not three modes: the tier sets DEFAULTS and how
      much is revealed, over identical underlying data (the Shapr3D pattern).
      Beginner: safe/unsafe map (M7.viz.1) + flex animation (M7.viz.3), no
      jargon. Advanced: raw von Mises values, displacement magnitude, the
      hot-spot table (M7.viz.2), load-path (M7.viz.4), and a toggle for the
      color-scale reference. Persist the tier per project. Build LAST in this
      lane — it composes the other viz tasks, so it depends on them landing
      first. Tests: tier selection drives which surfaces show; persistence
      round-trips. Device QA.
- [x] M7.viz.6 Failure-load prediction ("push it till it breaks"). Show the
      user how much load the part can take before it yields, and WHERE it fails
      first. This is a pure derivation from ALREADY-COMPUTED data — linear FEA
      means stress scales linearly with load, so no new solve: the failure
      multiplier = yield / current_peak_von_mises, the failure LOAD = that
      multiplier x the load the user applied, and the failure LOCATION = the
      hot-spot the M7.viz.2 callout already finds. Surface: (a) the predicted
      failure load in the user's units (lb/kg/N), (b) a marker at the failure
      location (reuse the viz.2 hot-spot marker), and (c) an OPTIONAL "push"
      interaction — a slider/scrub from 1x up to the failure multiplier that
      drives the EXISTING flex animation (M7.viz.3) at proportional
      exaggeration, so as the user pushes toward failure the part visibly
      deflects more and the failure point lights up. At/above the multiplier,
      indicate failure (the hot-spot region turns red / a "yields here" label).
      HONESTY (required, ties to the infill finding): the predicted failure load
      is a SOLID-PART prediction — the FEA models solid material (ARCHITECTURE
      §2). Label it as such ("solid-print estimate") and, if an infill % is set
      (M7.params), show the infill-adjusted estimate alongside using the same
      knockdown family as M7.infill-margin. Never present it as a guaranteed
      real-print strength. Consumes existing fields only (von Mises scalar +
      the applied load magnitude + material yield); if the applied-load
      magnitude is not already available to the results screen, STOP with a
      Blocked handoff requesting it rather than guessing. /app/ only.

## M7-SHIP — v1 ship block (small tasks; deliberately between M7.dom and the
   ML track so the app is shippable end-to-end while ML work runs long)

- [x] M7.params (app) Print-parameters input screen on import. Build from the
      Claude Design source (design HTML is the visual source of truth, DECISIONS
      2026-07-09) [DESIGN PATH TBD]. After import, before the workspace, present
      a sheet capturing walls / top layers / bottom layers / infill %, with FDM
      defaults. Persist on the project (survives relaunch, per the persist-c
      pattern). Feed the values to the M5.1 settings engine as user overrides AND
      pass infill % through the bridge to the core (consumed by M7.infill-margin).
      /app/ UI + persistence + bridge threading of the infill value; no FEA
      change. xcodebuild tests for capture + persistence round-trip; layout is
      device QA.
- [ ] M7.8b Honesty & confidence UI (was M7.trust — deferred to here to pair with
      export, since that's when a result leaves the app and goes toward a real
      print). Did NOT land in PR #46. Every result surfaces: (a) it was
      FEA-verified against modeled material properties at the chosen orientation;
      (b) a confidence/margin indicator (worst-case stress margin from the M5.2
      report); (c) the load-bearing recommendation: "Verified against modeled
      properties. Real prints vary (layer adhesion, moisture, printer) —
      test-print and load-test before relying on this part for safety-critical
      use." Applies to ALL results (OC, MMA, ML-warm-started). Surface it on the
      existing M7.8 results screen AND in the export/share flow (M7.9), so the
      caveat travels with the file, not just the on-screen view. This is honesty,
      not a disclaimer to bury. Headless tests where data can be asserted (margin
      value present and correct per variant, verified flag set); copy/layout is
      maintainer device QA.
- [ ] M7.9 Export + share. Export sheet per variant: .3mf via the M6.1
      exporter through the bridge, UIActivityViewController share; embed the
      M5.2 JSON report in the 3MF metadata; optional "Save report" as .json.
      Headless test: bridge-driven export → re-import round-trip holds V3
      properties (the M6.1 path exercised through the bridge).
- [ ] M7.9b Sample model affordance + document types: import sheet offers
      "Load sample model" (imports the bundled sample_cube.stl) so a first-run
      user with no files isn't dead-ended; register .stl/.step document types
      (CFBundleDocumentTypes / UTImportedTypeDeclarations) so files open into
      TopOpt from Files/AirDrop.
- [ ] M7.Za STL selection honesty (small): when a user taps a face in Faces
      mode on an STL (a mesh with no B-rep face ids), show a clear message
      instead of silently doing nothing — e.g. "Face selection needs a STEP
      file. STL models have no faces; full STL region tools are coming."
      Applies wherever face-tap returns nil for a faceless mesh. No selection
      logic change; purely the missing signpost.

## M7-ML — ML acceleration (ML PROPOSES, PHYSICS CERTIFIES)

> NON-NEGOTIABLE, NON-REMOVABLE CONSTRAINT for every task in this track:
> every design shown to a user is certified by a real FEA pass against real
> material properties BEFORE display. The ML output is NEVER the source of
> truth — it only saves iterations. A design that fails its certifying FEA is
> rejected/re-refined, never shipped. The safety net is tested, not assumed.

- [ ] M7.ml.0 MAINTAINER DECISION (human, no agent): after reviewing
      M7.mma/M7.dom output, confirm speed/friction is the real limiter and ML
      is warranted; set the dataset budget (sample count, resolution,
      randomization ranges) and the target warm-start iteration savings.
      Record in DECISIONS.md. Agents: if this is the topmost unchecked task,
      write a handoff noting the decision is pending and stop.
- [ ] M7.ml.1 Warm-start + certification plumbing (pure core, NO ML yet).
      simp_optimize accepts an optional initial density field (validated:
      grid-shaped, clamped to [0,1], mask-consistent); add a certify(result)
      step — full FEA at final densities + the V3 property suite — and a
      rejection path: a warm-started run whose certified result misses the
      cold-start reference compliance tolerance is REJECTED (status code, not
      exception) and automatically re-refined from cold start. Tests: warm
      start from the known converged solution passes certification in fewer
      iterations than cold; an INTENTIONALLY BAD warm start (e.g. inverted
      density field) is caught by the certifying pass and the fallback
      reproduces the reference result. This makes the track constraint
      structural before any model exists. Pure core; no /app/.
- [ ] M7.ml.2 Dataset harness: `topopt-cli dataset` batch-runs randomized
      problems (domain proportions, BCs, load placement/direction, volume
      fraction — all seeded and reproducible) and serializes (problem
      encoding, converged density field) pairs in a documented compact format
      under a manifest. Tests: schema validation, determinism per seed, a
      3-sample smoke dataset generated within the CI time budget. Pure
      core/tooling; no /app/.
- [ ] M7.ml.3 MAINTAINER RUN (human, no agent): generate the real dataset per
      the M7.ml.0 budget on the Mac; commit the manifest + storage location
      (not the data). Agents: handoff and stop if topmost.
- [ ] M7.ml.4 Surrogate training + export (tools/ml/, Python, out of core CI):
      3D U-Net (or a justified alternative — record in DECISIONS.md)
      predicting the density field from the problem encoding. Loss: L2 on
      density + volume-fraction penalty; physics-informed equilibrium terms
      are OPTIONAL for v1 — document what shipped. Deliverables: training
      script, eval metrics on a held-out split, exported .mlpackage. The
      agent writes and smoke-tests the pipeline on tiny synthetic data; the
      maintainer runs the real training.
- [ ] M7.ml.5 App integration: run the .mlpackage on-device (Core ML, Neural
      Engine), feed the prediction through the bridge as the M7.ml.1 warm
      start; graceful fallback to cold start when the model is absent or
      inference fails. Verify on benchmark parts: the ML-warm-started result
      matches pure-physics compliance within tolerance AND passes the same
      V-gates; iteration savings vs cold start recorded. Results screen keeps
      the M7.8b verified/margin surface — certification status is what the
      user sees, never raw model output. xcodebuild tests for the fallback
      and plumbing; maintainer device QA.

- [ ] M7.10 Maintainer QA milestone (human, no agent): full-flow device pass,
      performance profile on target iPad (128³ end-to-end timing vs the M6.3
      projection cost decision), accessibility pass (Dynamic Type on sheets,
      VoiceOver labels on tools), App Store asset checklist. Agents: if this
      is the topmost unchecked task, write a handoff noting QA is pending and
      stop — do not skip ahead into the parked section.

## Parked — cosmetics & STL region tools (do not start until everything above
   is closed)

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
- [ ] M7.Zb STL region selection: give STL/faceless meshes a real way to mark
      Fixture / Load / Frozen regions, feeding the SAME SelectionModel +
      tagging path M7.5 built for STEP faces (so downstream optimization is
      identical regardless of input format), via the existing tag path and
      the M7.6-core mask bridge. Acceptance floor for THIS box:
      coplanar-cluster grouping — auto-cluster adjacent triangles within an
      angle tolerance into pseudo-faces that tap-select like STEP faces (best
      default for mechanical parts). Paint select (drag to tag triangles) and
      box/volume select are follow-on tasks to be added to this list when
      this box closes — do not attempt all three in one run. Tests: coplanar
      clustering recovers the expected region count on a known STL; clustered
      groups tag the right voxels. This makes STL a first-class input, not
      just an optimize-with-defaults fallback.
- [ ] M7.zz-ring Constrained single-DOF rotation ring for custom load
      directions: 15° detents, haptic ticks, second ring after the first
      commits, never a freehand drag. MAINTAINER DECISION REQUIRED before
      start: is this needed at all, given the snap directions cover the
      common cases? Record in DECISIONS.md.
