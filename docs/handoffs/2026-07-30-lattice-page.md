# Lattice page — the approved design, implemented against core truth

**Date:** 2026-07-30 · **Branch:** `claude/lattice-page-design-68d0bd`
**Scope:** `app/` only (including two read-only accessors on the app-side
`TopOptBridge`, per the lattice-mode-ui precedent). **No core change, no job-schema
change** — the schema gaps the roles exposed are REPORTED below (blocked-stop
taken), not papered over.
**Evidence:** `evidence/2026-07-30-lattice-page/`
**Design source:** `docs/design/lattice-page/latticePage.html` (direction A
"Ladder" — the prototype's default state), implemented as `LatticePage.swift`.

## What this is

The full-screen lattice page replaces the 300 pt `LatticeControlsPanel`. One glass
panel with a SINGLE flat list (Lattice infill · Topology · Cell size · Density
range · Regions & faces · Boundary & finish · Review & run), sub-panes pushed in
place, chips (Paint / Regions / Preview) on the trailing edge, a status banner, a
RUN SIM button with a stated gate, its own Optimize, and the full-bleed entry
gate. The page is CHROME ONLY over the workspace's live stage (mesh + raymarched
strut preview stay mounted beneath; the workspace hides its own chrome while the
page is open, so exactly one set of controls exists at a time).

Two entry points: the workspace's Lattice chip, and a per-variant **Lattice**
button on the results screen (`ResultsScreen.onLattice`) that carries THAT
variant's own von Mises field in as the demand field.

## The topology truth (the part that mattered most)

The prototype's TOPOS array was fabricated and is nowhere in this app. The picker
is computed at runtime from CORE's two INDEPENDENT sets:

* **certifiable** — `TopOptKit.latticeCertifiableTopologies` →
  `topopt::lattice_certifiable_topology_names()`: `octet, sc, bcc, fcc, diamond,
  kelvin, rhombic` (seven, cubic, tensor-backed).
* **generatable** — NEW `TopOptKit.latticeGeneratableTopologies` →
  `topoptbridge::lattice_generatable_topologies()` →
  `topopt::lattice_gen_topology_name(LatticeGenTopology::…)`: `octet` only.

The picker is exactly the union; `bccz/fccz/reentrant` are in neither set and do
not appear; Gyroid/Schwarz-P/Honeycomb/Voronoi never existed. Each row badges BOTH
properties (`CERTIFIABLE` / `CERTIFIES · NO GEOMETRY YET` / `PREVIEW ONLY`);
selecting a certifiable-but-not-generatable topology shows ITS band (B0b) but
gates the run with the reason ("… certifies, but core has no geometry generator
for it yet"). The default is octet — the one topology that is BOTH.

**Bridge additions (read-only forwarders, no core logic):**
1. `lattice_generatable_topologies()` — names from core's own
   `lattice_gen_topology_name`. Core has NO enumeration API for
   `LatticeGenTopology` (reported gap), so the bridge mirrors the enum's case
   list (one case today) — the names are core's, and `generate_lattice` throws on
   anything outside the enum, so a drifted list fails loudly at the generator,
   never silently. When core grows the enum, this is the one matching line.
2. **Bug fix:** `lattice_limits().min_cells_per_member` was stubbed to `0.0`
   behind a comment claiming "core exposes no accessor yet" — stale:
   `topopt::lattice_cells_per_member_min()` exists (returns 5.0). The bridge now
   forwards it, so the cells-per-member CLAMP the previous handoff promised
   ("engages the moment core returns a positive value") is now LIVE: cell size
   over `member/5` blocks a certified run with the named reason.

## Bars

* **B0 — MET.** `testPickerMatchesCoreExactly`: picker ids == certifiable ∪
  generatable (set equality — an invented entry breaks it), per-row properties
  equal core's sets, fabricated prototype names asserted absent.
  `testDefaultTopologyIsCertifiableAndGeneratable` pins the default.
  **Failure-mode confirmed by experiment:** temporarily appending a "gyroid" row
  to `LatticeTopologyPicker.rows` made the test fail on four independent
  assertions (set equality, both per-row property checks, and the explicit
  anti-gyroid check); reverted. `topology_truth_from_core.txt` records the live
  sets + bands.
* **B0b — MET.** `testDensityBandChangesWithSelectionAndMatchesCore`: the first
  two core-certifiable topologies carry DIFFERENT bands, and the displayed
  band (`LatticeBounds.bandLo/Hi`) equals core's `lattice_rho_min/max` per
  selection. (Live numbers: octet 0.050–0.900, sc 0.087–0.496, bcc 0.211–0.593,
  fcc 0.095–0.591, diamond 0.157–0.592, kelvin 0.094–0.505, rhombic 0.172–0.513.)
* **B1 — MET.** `LatticePageGate` states exactly what is missing (anchor and/or
  load rows with ✓/✗, per-item "Add anchor"/"Add load", CTA "Back to Setup — add
  a load"), the prototype's shape. `testGateStatesWhatIsMissing` covers all four
  count combinations; `testGateGovernsBothEntryPoints` proves the gate derives
  from the load case alone so neither entry (workspace / variant) bypasses it.
  Screenshots: `page_gate_landscape/portrait.png`.
* **B2 — MET.** The page's Optimize and page one's Optimize call the SAME
  `RunModel.start`, which guards `phase == .running` —
  `testExactlyOneOptimizeEverFires` holds a run in flight via a deferred
  scheduler, fires both buttons' paths, and counts ONE runner invocation.
  `testLatticeJobCarriesPageOneInputs`: the lattice job minus its `lattice` block
  is dictionary-identical to page one's job, with anchors/loads/keep-clears/
  protections/material/resolution asserted present (not vacuously equal).
* **B3 — MET at the model+job level; primitive-exclude schema gap REPORTED.**
  The three roles map to three EXISTING, distinct concepts:
  * clearance → keep-clear (`loads.clearances`, FrozenVoid — REMOVES material);
  * lattice-exclude → protect (`loads.face_protections`, FrozenSolid — KEEPS
    material solid) via painted faces;
  * lattice-include → the lattice region list (preview scope).
  `testClearanceAndExcludeProduceDifferentJobs` proves the two jobs differ and
  neither masquerades as the other; `testRoleHelpersMapToDistinctStores` proves
  the stores never bleed. **Blocked-stop taken:** an exclude PRIMITIVE has no job
  field (`face_protections` is face-id based; a primitive-shaped FrozenSolid does
  not exist in the schema), and honoring "kept solid" through the lattice
  EXPORT needs generator/cert work that is out of scope — so the exclude card's
  "+" is disabled with the reason on-surface, and paint is the exclude mechanism.
  Include primitives/faces remain preview-scope with the honest note (the
  existing "core job carries no region" gap, restated in the UI).
* **B4 — MET.** The one-voxel minimum is LIVE: `VoxelFit.spacing` = longest bbox
  extent / resolution — exactly `topopt::voxelize`'s law.
  `testVoxelMinimumIsLiveNotAConstant` drives two part sizes × two resolutions
  (1.5625 / 3.125 / 0.78125 mm) and asserts the surfaced line + lanes carry the
  same number. `testLanesSayWhoHonoursASubVoxelSize`: below one voxel the
  generator lane stays "exact" and the optimizer lane says "rounds up to
  X.XX mm" — which pipeline honours the number is CONVEYED, never silently
  accepted. "Snap to 1 voxel" appears exactly when below.
* **B5 — MET, with one deviation.** RUN SIM runs ONE linear FEA of the SOLID
  part under page one's anchors + loads at the coarse (fast-tier) resolution.
  DISABLED while lattice infill is on ("This job also runs topology optimization
  — sim runs on its result.") and while a job runs ("A job is already
  running.") — `testSimGating` covers all states. **Deviation:** the sim runs
  ON-DEVICE through the bridge's `analyze_loadcase` seam (new Swift wrapper
  `TopOptKit.analyzeSolidLoadCase`), not on the worker — the LAN worker routes
  only `run` jobs and the job schema's only mode is `minimize_plastic`, so a
  worker-dispatched analyze does not exist (gap reported below). The bridge path
  solves the identical load case via the same `build_production_loadcase`.
  Cancel ABANDONS the in-flight result (the bridge call has no cancel flag; the
  solve finishes in background and is discarded) — stated here, not hidden.
* **B6 — MET.** No field ⇒ Auto is NOT OFFERED (segment disabled, reason "No
  stress field yet…"); uniform is the only mode. On the variants entry the
  variant's own field arrives with the page ⇒ Auto available with no sim —
  tested separately (`testAutoAvailableFromVariantEntryWithNoSim`). Provenance +
  age are shown ("Solid-part sim · 64³ · 2 min ago" / "Run … · variant N");
  sim-stale is a real surface (amber banner + Re-run) keyed on a fingerprint of
  what actually determines the field. **Auto never silently means uniform:** with
  Auto selected the job carries NO lattice block and Optimize is gated with the
  stated reason — because core's grading law runs ONLY on the analyze path
  (`run_job` never reads `job.grading`; the worker can't run analyze), a lattice
  job can only fill uniform today, and shipping that under "Auto" would be the
  exact lie the bar forbids. Auto grades the raymarched PREVIEW from the field
  (the shipped `demandField` machinery). Gap reported below.
* **B7 — MET.** `LatticeBoundaryTreatment` is a THREE-case enum mapping 1:1 onto
  core's `lattice.skin` (`none | rim | diagrid`); core's diagrid is BUILT ON the
  rim (anchored landings + rim loops + collar tori), so "skin without rim" is
  unrepresentable by construction — there is no state to reach.
  `testBoundaryIsAThreeWayAndSkinWithoutRimIsUnrepresentable` (incl. an
  exhaustive tap walk) + `testBoundaryReachesTheJob` (each treatment lands in
  `job.lattice.skin`; the user's outer line width ships as
  `min_extrudable_width_mm`, arming core's OWN skin printability clamp).
* **B8 — MET, hashed.** `testTOOnlyJobByteIdenticalByHash`: SHA-256 over
  canonical (sorted-keys) job JSON is identical for (a) a fresh default project,
  (b) the same project after page state was touched with lattice left off, and
  (c) a LEGACY pre-page snapshot decoded through the new model; and the TO-only
  job contains none of the new vocabulary (`lattice`/`skin`/`grading`/
  `min_extrudable_width_mm`). The serializer diff is confined to the
  `if let lat = request.lattice` block, and the pre-existing U1 suite
  (`testLatticeOffProducesNoLatticeKey`, `testLatticeOnAddsOnlyTheLatticeBlock`,
  `JobJSONEquivalenceTests`) stays green.
* **B9 — MET.** Every prototype state is drivable and asserted:
  empty (counts at zero from real data), blocked-at-gate, sim-running
  (cancellable, progress), sim-complete (displacement/stress/safety numbers),
  sim-stale (amber + Re-run), optimizing (outranks sim states, cancellable),
  failed (run and sim variants; a non-convergent solve is FAILED with no field —
  never a fabricated one). `testBannerForEveryPageState`,
  `testSimModelDrivesRunCompleteStaleAndCancel`,
  `testSimModelSurfacesFailureAndNonConvergenceHonestly`.
* **B10 — MEASURED.** `b10_density_measurements.md` + ten captures (both
  orientations, gate, and every pane). Headlines: 16 controls at rest (vs the
  panel's 15 crammed into 300 pt), 1 non-adjacent text line (the
  prototype-defined hint bar; explanation lives behind panes — the panel had
  6–8), 2 taps from entry to a runnable job (panel: 3), smallest target 44 pt
  (panel: ≈29 pt chips), no overlapping panels in any state, portrait default
  fits without scrolling. Captures are the repo's offscreen ImageRenderer
  precedent (platform-backed Toggle/Slider render as placeholder glyphs; frames
  are exact); the live iPad frame remains the maintainer's on-device QA step.

## Deviations from the prototype (justified, not silent)

1. **Topology data replaced wholesale** — mandated; see above.
2. **Skin pattern select (Hexagonal/Square/Triangulated/Diagonal) → a fixed
   "Diagrid" descriptor.** Core has exactly one skin (the anchored diagrid);
   offering four patterns would promise exports that don't exist.
3. **Skin density Auto/Manual % → Density MODE (Uniform/Auto) on the Cell &
   density pane.** Core's skin has NO density knob at all (the skin radius law is
   core-owned: `max(local interior radius, printability clamp)`); a skin-density
   % would be a dead control. The Auto-needs-a-field semantics (bar B6) attach to
   the LATTICE density, where a real consumer exists (the graded preview).
4. **"Protect clearance regions" toggle + collar slider → a read-only truth
   card.** Core protects clearances UNCONDITIONALLY (boundary keep-outs, collars
   at the declared radius); a toggle would be a lie in both positions.
5. **Outer finish (Shell/Skin/Both) segment → dropped.** No job field; the
   export's outer treatment is core's (solid shell stays, skin per `skin` mode).
6. **Primitive shapes: Box/Cylinder/Sphere → Cylinder/Slab.** The clearance
   schema carries a swept cylinder and a bounded slab; a sphere has no carrier
   anywhere (and adding one is core geometry work). The role segment's "Solid"
   option is visible but disabled with the reason (no primitive carrier).
7. **RUN SIM on-device, not worker-dispatched** (B5 above).
8. **Sim staleness keys on what determines the field** (model/material/
   resolution/load case), not on cell size — the solid-part field does not
   depend on the lattice's cell size; the prototype staled on it.
9. **A 7th ladder row ("Review & run").** The prototype defined the review pane
   but its direction-A ladder wired no row to it (only direction C's dial did);
   every pane must be reachable.
10. **Ladder "Lattice infill" toggle also gates RUN SIM** exactly as the
    prototype's `blockSim = optimizing || lattice` did — noted because it means
    the main-entry auto-density flow is: lattice off → RUN SIM → lattice on →
    Auto. The variants entry avoids the dance entirely (field ships with entry).

## Blocked-stops taken / gaps reported (all pre-authorized paths)

* **Primitive-role job schema:** no `lattice_include`/`lattice_exclude`/primitive-
  FrozenSolid fields exist; `reject_unknown_keys` would fail any job carrying
  them, and parse-only acceptance without generator/cert honoring would be a
  silently-ignored field. NOT extended. Proposed shape when core takes it up:
  `lattice.regions: [{role: "include"|"exclude", geometry: <manual bolt|slab>}]`
  honored by `LatticeRegion.latticed` + `LatticeBoundary` + the cert mask.
* **Generatable-set enumeration:** core lacks `lattice_gen_topology_names()`;
  the bridge mirrors the enum cases (names from core). One-line core follow-up.
* **Worker analyze route:** the worker only runs `topopt-cli run`; job `mode`
  accepts only `minimize_plastic`. A worker `analyze` route would let RUN SIM
  off-device and would open per-variant graded lattice (analyze_job already
  writes `fields.bin` + honors `grading`).
* **Grading on the optimize path:** `job.grading` is consumed ONLY by
  `analyze_job`; `run_job` ignores it. Until that lands (or the worker analyze
  route does), Auto density gates Optimize rather than lying.
* **WorkspacePlaceholder was NOT restructured:** the page follows the existing
  full-bleed-overlay pattern (RunScreen/ResultsScreen precedent) — a mount +
  `if !showLatticePage` gates on the chrome groups, `handlePick` routing for the
  paint pane, and the region-gizmo gate. No second page bolted onto the view.

## Files

| File | Role |
|---|---|
| NEW `TopOptFlows/LatticePage.swift` | The page view (chrome-only; every surface from the pure models). |
| NEW `TopOptFlows/LatticePageModel.swift` | Pure surface derivation: `LatticeTopologyPicker` (B0), `LatticePageGate` (B1), `LatticePageBanner` (B9), `LatticeSimGate` (B5), `LatticeAutoDensityGate` (B6), `LatticeOptimizeSurface`, `LatticeSizingLanes` (B4), `LatticeRegionRole` (B3), + the navigation ObservableObject. |
| NEW `TopOptFlows/LatticeSimModel.swift` | RUN SIM state machine (injectable runner seam, fingerprint staleness, abandon-on-cancel). |
| NEW `TopOptKit/LoadcaseAnalyze.swift` | `analyzeSolidLoadCase` — the Swift wrapper over the bridge's existing `analyze_loadcase` seam. |
| `TopOptBridge.hpp` / `bridge.cpp` | `lattice_generatable_topologies()` + the `min_cells_per_member` forward (stub-comment bug fix). |
| `TopOptFlows/LatticeSettings.swift` | `LatticeBoundaryTreatment` (B7), `LatticeDensityMode` (B6), `includePrimitives` list (legacy `region` migrates in; `region` is now a view over it), painted include faces, hand-written back-compatible Codable, `runSpec` gains generatable + auto gating + `skin`/`min_extrudable_width_mm`. `LatticeBounds` gains `generatable`/`generatableReason`. |
| `TopOptFlows/LatticeType.swift` | `displayName(forID:)` — names for kelvin/rhombic/reentrant without the octet fallback mislabel. |
| `TopOptFlows/RemoteRunner.swift` | Lattice block gains `skin` + optional `min_extrudable_width_mm` (inside the existing conditional — U1/B8 safe). |
| `TopOptFlows/ProjectModel.swift` | Role helpers: include-primitive list ops, `addLatticeClearancePrimitive`, the dedicated protect group, `toggleLatticePaintFace`. |
| `TopOptFlows/SelectionModel.swift` | Group-targeted `addFaces(_:to:)` / `removeFaces(_:from:)` (steal semantics preserved). |
| `TopOptFlows/AppModel.swift` | `makeLatticeSimContext()`. |
| `TopOptFlows/WorkspacePlaceholder.swift` | Page mount + chrome gating + entry chip + paint-tap routing + preview demand-field source; old panel overlay removed. |
| `TopOptFlows/ResultsScreen.swift` | `onLattice` per-variant entry affordance. |
| DELETED `TopOptFlows/LatticeControlsPanel.swift` | Replaced by the page (B10 compares against it). |
| Tests | NEW `LatticePageTests.swift` (24 cases, B0–B9), NEW `LatticePageEvidenceGen.swift`; `LatticeModeTests` updated where core truth moved beneath it (below). |

## Test updates that touched existing assertions (none weakened)

* `testNonCertifiableTopologyIsPreviewOnlyWithReason`: used "bcc" as the
  non-certifiable example from when core certified octet only; core now certifies
  bcc (tensor-library-nine), so the example is "bccz" (genuinely tetragonal /
  non-certifiable). Every assertion unchanged.
* `testCellsPerMemberIsAdvisoryWhileCoreCertifiesNoCeiling` →
  `testCellsPerMemberCeilingComesFromCoreAndEngages`: the old test pinned the
  bridge STUB (`minCellsPerMember == 0`); the stub's claim was stale (core's
  accessor exists). The test now asserts the forwarded value is positive and the
  clamp — which the old test exercised via a simulated future value — engages on
  the live number too. This is the exact promotion the old test's comment
  promised.
* `testRunSpecGating`: the "bcc → nil" branch now documents the REAL reason
  (generatable gate, not certifiability) and adds a bccz branch.
* `testNoHardcodedCertifiableBandLiteralsInControlSources`: scans the page files
  instead of the deleted panel (three files now — strictly wider).

## Test / regression results

* `LatticePageTests` — 24/24 green.
* `LatticeModeTests` — green after the updates above.
* `LatticeSDFTests` + `LatticeSDFProfileTests` (the PR-251 preview regressions;
  the task's "LatticeSDFAlignmentTests" name does not exist in the repo — the
  alignment assertions live in `LatticeSDFTests`) — results recorded below.
* Full `TopOptFlowsTests` — results recorded below (known pre-existing: 3MF
  `AppModelTests` failures on a lib3mf-free macOS checkout; GPU-test SIGTRAP
  flake under parallel workers, run serially here).

Full serial `xcodebuild test` run (2026-07-30): **every TopOptFlowsTests suite
green** — including `LatticeSDFTests` (the PR-251 alignment assertions) and
`LatticeSDFProfileTests` (the raymarch cost gate), `JobJSONEquivalenceTests`,
`LatticeProxyKeepOutTests`, `ManualPrimitiveJobTests`, `LatticePageTests` (24)
and `LatticeModeTests` — EXCEPT the three documented pre-existing 3MF
`AppModelTests` cases that fail on any lib3mf-free macOS checkout
(`testThreeMFImport*`, `testReopenedThreeMFProject*` — the gotcha the
lattice-mode-ui handoff recorded; unrelated to this change and re-verified as the
ONLY failures). `TopOptKitTests` fully green.

## Plain language — what this does, and what it honestly can't do yet

This adds a full-screen "Lattice" page to the app — one place to set up a
lattice-filled part, replacing the old cramped side panel. You open it from the
workspace, or from a finished run's results with one button. If the part doesn't
have at least one anchor and one load yet, the page stops you up front with a
card that says exactly what's missing and a button that takes you back to add it
— no dead controls, no guessing.

The page shows one simple list: lattice on/off, which lattice pattern, how big
the cells are, how dense, which regions get latticed or kept solid or kept
empty, and how the lattice's outer surface is finished. Tapping a row opens just
that setting. Everything the page displays is read live from the engine — which
patterns can actually be certified (seven today), which can actually be BUILT
(one today: octet), and the safe density range for each pattern. The old
prototype invented patterns that don't exist; this page cannot do that — a test
fails if anyone ever adds a pattern the engine doesn't know.

Honesty is the theme throughout. A pattern that certifies but can't be built yet
says so on its row, and the run button explains why it won't run. A region size
smaller than the simulation can resolve isn't silently accepted — the page shows
which parts of the pipeline will honour the number and which will round it up,
with a one-tap fix. "Auto" density — grading the lattice by where the stress is
— is only offered when a real stress field exists (from the page's RUN SIM
button, or from the finished run you came from), it always shows where that
field came from and how old it is, and because today's jobs can't actually
carry a graded lattice to the engine, choosing Auto pauses the run button with a
plain explanation instead of quietly building a uniform lattice and calling it
Auto.

What it can't do yet, by design honesty rather than accident: "keep this box
solid" regions and "lattice only this box" regions don't travel to the engine
(its job format has no field for them — reported here for the next core task);
painting faces solid DOES travel (it rides the existing Protect machinery); and
the quick simulation runs on the iPad itself rather than the Mac worker, because
the worker only knows how to run full optimizations. None of this changed
anything for people who don't use lattices: a plain optimization job is
byte-for-byte identical to before, proven with a hash.
