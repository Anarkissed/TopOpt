# Lattice mode in the app — the controls

**Date:** 2026-07-29
**Branch:** `claude/lattice-mode-controls-b5d09e`
**Scope:** `app/` only, plus a **read-only** accessor added to the app-side
`TopOptBridge` (app/TopOptKit/Sources/TopOptBridge). **No `core/` change, no change to
the grading law or the generator** (FORBIDDEN bar held).
**Evidence:** `evidence/2026-07-29-lattice-mode-ui/`

## What this adds

The lattice pieces already existed — generation streams worker-side (PR 231), the
viewer shows a density proxy without holding the mesh (PR 229), ten strut topologies
exist as a study (PR 219), certification understands a latticed region (PR 220), and the
manual primitives + gizmo already ARE a region picker. This task wires the **controls**:

1. **A LATTICE MODE toggle** on the project (`LatticeSettings.enabled`), persisted, undoable, off by default.
2. **Region selection reusing the existing manual primitives + gizmo** — the region is a
   `ManualPrimitive` (bolt = cylinder, face = slab) moved by the SAME transform-gizmo
   components (`TransformGizmoMetalView` render + `TransformGizmo.pick` + `PrimitiveGizmo.Drag` +
   `ManualPrimitiveDetent`). No second placement mechanism.
3. **A topology picker** over the shipped on-device family, each with a **true-geometry
   sample** rendered through the proxy's own `LatticeSamplePatch` path.
4. **Cell-size and density-range controls** on the shared `NumberPad`.
5. **The PR-229 viewer proxy as the display** — the surface density shading engages
   whenever lattice mode is on, driven from these settings.

## The ★ bars — controls bounded by CORE, read at runtime, with reasons

`TopOptBridge` gained a **read-only** accessor `lattice_limits(topology)` +
`lattice_certifiable_topologies()` that FORWARD core's own numbers
(`topopt::lattice_rho_min/max`, `lattice_topology_name`). The Swift `TopOptKit.latticeLimits`
wraps them. **The app hardcodes no band or cell limit** — `LatticeBounds.compute` takes the
core-read limits and returns the effective values plus a plain reason for each clamp:

- **Density** clamps to the core band `[0.14764, 0.59093]` (octet, read live). Below → "below
  the certifiable density range (≥ 15%)"; above → "above the certifiable density range (≤ 59%)".
- **Topology**: only a core-certifiable topology (`["octet"]` today) can RUN; the others are
  **preview-only** with the reason "… is preview-only — not yet certifiable, so a run won't
  lattice it". The set widens automatically when core's enum grows.
- **Cells-per-member**: core exposes **no** ceiling yet, so the readout is **advisory** ("… not
  yet certified by core — shown as a guide, not a limit"). The clamp machinery is present and
  engages — with the message "too few cells across this member to certify — need ≥ N across
  W mm, so cell ≤ C mm" — the moment core returns a positive `min_cells_per_member`
  (proven in `LatticeModeTests` by injecting a future value).
- **Strut printability** is an advisory computed from the user's OWN outer line width (not a
  hardcoded number): "struts reach X mm at the sparse end — thinner than one extrusion width".

## Files

| File | Role |
|---|---|
| `TopOptBridge/include/TopOptBridge.hpp`, `bridge.cpp` | **Read-only** `lattice_limits` + `lattice_certifiable_topologies`, forwarding core's `lattice_rho_min/max`. No core logic. |
| `TopOptKit/TopOptKit.swift` | `latticeLimits(topology:)` / `latticeCertifiableTopologies` Swift wrappers; `LatticeReport` (run-report echo) on `OptimizeOutcome`. |
| `TopOptFlows/LatticeSettings.swift` | **The model.** `LatticeSettings` (mode/topology/cell/density/region), the pure **`LatticeBounds`** (clamps + reasons, all from core-read limits), `runSpec` (the gated job block), `proxyParams`, region member width. |
| `TopOptFlows/LatticeControlsPanel.swift` | **The controls UI** — mode toggle, topology picker (sample per type), cell/density on the shared NumberPad, region section, clamp reasons, the proxy legend. |
| `TopOptFlows/ProjectModel.swift` | `lattice` stored + folded into the undo slice; `placeLatticeRegion` / `moveLatticeRegion` / `rotateLatticeRegion` (reuse detents). |
| `TopOptFlows/ProjectStore.swift`, `UndoHistory.swift` | `LatticeSettings` round-trips through the snapshot; rides the `EditSnapshot` slice (undo, U4). |
| `TopOptFlows/RunModel.swift`, `RemoteRunner.swift`, `AppModel.swift` | `RunRequest.lattice`; the conditional `lattice` block in `buildJobJSON`; `makeRunRequest` gating; the run_info `lattice_export` → `LatticeReport` fetch. |
| `TopOptFlows/OutcomeStore.swift`, `ResultsModel.swift`, `ResultsScreen.swift` | `LatticeReport` persists + renders as honest lattice notes on the results screen. |
| `TopOptFlows/WorkspacePlaceholder.swift` | Chip → panel; tints from `project.lattice`; the isolated **lattice-region gizmo** reusing the transform-gizmo components. |
| `Tests/…/LatticeModeTests.swift`, `LatticeModeEvidenceGen.swift` | 14 headless tests + the evidence generator. |

## The bars

- **U1 — LATTICE OFF byte-identical.** `runSpec` returns nil unless mode is on AND
  runnable-as-certified, so `buildJobJSON` adds no `lattice` key and the snapshot omits it.
  Proven: `testLatticeOffProducesNoLatticeKey`, `testLatticeOnAddsOnlyTheLatticeBlock` (ON minus
  the block == OFF), `job_off_vs_on.txt`. `JobJSONEquivalenceTests` still green.
- **U2 — bounds from core at runtime; zero hardcoded numbers.**
  `certifiable_band_from_core.txt` shows the band read live via the bridge;
  `testNoHardcodedCertifiableBandLiteralsInControlSources` greps the control sources for the band
  literals and asserts **zero**. `testCertifiableBandComesFromCore` asserts the clamp equals core's.
- **U3 — round-trips + report.** `testSettingsRoundTripThroughSnapshot`,
  `testPreLatticeSnapshotStillDecodes`, `testLatticeReportRoundTripThroughOutcomeStore`; the
  results screen renders the lattice notes.
- **U4 — existing UndoHistory.** `LatticeSettings` is in `EditSnapshot`;
  `testLatticeIsInTheUndoSlice` commits/undoes/redoes a lattice edit through the one history.
- **U5 — keep-out + gizmo.** The region reuses the existing gizmo COMPONENTS; the region gizmo is
  shown ONLY while the lattice panel is open, so it never coincides with the force gizmo or steals
  its taps. The proxy legend keeps its lowest-priority keep-out element (`LatticeProxyLayout`,
  `LatticeProxyKeepOutTests` still green).
- **U6 — chips never two rows.** Every panel chip (`LatticeValueChip`, topology cards) is a single
  HStack row, following the `GlassValuePill` one-row discipline.
- **U7 — device-real evidence.** OWED: a live iPad screenshot of the panel + the region gizmo on
  the maintainer's own part, per the PR-229 precedent (nothing on the Mac substitutes for the
  on-device frame). The component-level artifacts (band, job diff, reasons, 7 rendered topology
  samples) are the directly-comparable proxy.

## Honest scope — what this is NOT (all forced by "don't change core")

- **Only octet RUNS.** Core certifies and generates octet only; the picker previews all seven
  on-device lattices but a run uses octet (the rest are labelled *preview*). Widens with core.
- **The region scopes the PREVIEW + the report + the member estimate, not generation.** The core
  job schema carries no sub-region, so the worker lattices the whole solid interior (its existing
  behaviour). The panel + the results note say this plainly. When core's job carries a region, the
  region already captured here feeds it.
- **Generation is UNIFORM at the range's dense end.** The shipped generator has no grading law
  (held for the certifiable band), so a run fills at the clamped `maxRelativeDensity` — the
  conservative choice (never weaker than the previewed range). The report names the fill density.
- **Cells-per-member is advisory** until core certifies a ceiling (see the ★ section).
- **Lattice generation is worker-only** (the LAN/remote path); the on-device bridge solver does not
  generate lattices and ignores `request.lattice`.

## Off-switch / blast radius

`LatticeSettings.enabled` defaults false → `runSpec` nil → no `lattice` key, no proxy shading, the
snapshot omits the block. The bridge accessor is read-only and unused unless lattice mode is on. No
core, solver, generator, grading law, materials.json or rules.json touched. Pre-existing macOS
lib3mf-free 3MF `AppModelTests` failures are unrelated (documented gotcha).
