# Handoff 069 — Print-params presets + lock-at-creation + infill-aware physics

## Task
TRACK app (`/app/` only; never `/core/`, `tests/fixtures/**`, `ROADMAP.md`). Three
changes to the M7.params print-parameters surface:

1. **Presets (the "save" the user wanted).** Keep the shipped "Default" values; add
   a **Save** button that names + persists the sheet's current values as an app-wide
   preset (available to every project, surviving relaunch). Turn the old single
   "Default" reset into a **picker/dropdown** listing Default + every saved preset;
   selecting one loads its values into the sheet.
2. **Lock print params at project creation.** Print parameters are set ONCE, on the
   sheet that auto-presents after import, then LOCKED for the life of the project.
   Post-creation the sheet is read-only with a note; to use different params the user
   creates a new project. The chosen params (incl. infill %) are immutable on the
   project.
3. **Infill-aware physics everywhere.** Because infill is now FIXED per project, every
   displayed physics figure reflects the ACTUAL printed part at that infill —
   consistently: the failure load, the stress-scale/legend, the hot-spot "% of
   yield", and the strength/margin readouts (worst-case margin, layer shear). Uses the
   SAME Gibson-Ashby `f^1.5` knockdown the core uses (M7.infill-margin). The failure
   readout is now ONE honest value (infill-adjusted), not the old solid-vs-infill pair.
   The FEA/core physics is UNTOUCHED — the solver still computes the solid field; the
   knockdown is applied only at the DISPLAY layer.

Everything is under `/app/TopOptKit`. Nothing in `/core/`, `tests/fixtures/`, or
`ROADMAP.md` was touched. The ROADMAP box is left for the maintainer.

## Worktree
`/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/angry-hopper-17ee5e`
(branch `claude/funny-ritchie-a84719`).

## What I did

### 1. App-wide named presets
- **New `PrintParamsPreset`** (`Sources/TopOptFlows/PrintParamsPreset.swift`) — a
  `Codable`/`Identifiable` value: `id` + `name` + `params: PrintParams`. The built-in
  `builtInDefault` (name "Default", `PrintParams.fdmDefault`, a fixed reserved id) is
  SYNTHESIZED, never stored — so it always exists on a fresh install and can't be
  deleted/renamed.
- **New `PrintParamsPresetStore`** (`…/PrintParamsPresetStore.swift`) — a tiny sibling
  of `ProjectStore`: writes the user's presets to ONE app-level file,
  `<AppSupport>/TopOpt/print-presets.json`, a sibling of the per-project `Projects/`
  tree (so deleting a project never touches presets). Injectable `rootDir` for tests.
- **`AppModel`** gained: an injected `presetStore` (default real one), `@Published
  savedPresets` (loaded from the store in `init`), computed `allPresets` = `[Default]
  + savedPresets`, `savePreset(named:params:)` (trims the name, clamps the params,
  appends + persists, toasts on IO failure), and `applyPreset(_:)` (loads a preset's
  values into the open project — **no-op once locked**, presets are a setup-time
  convenience, not a lock bypass).
- **`PrintParamsSheet`** header, editable mode: the old single "Default" capsule is
  replaced by a **Presets** `Menu` (lists `model.allPresets`; tap → `applyPreset`) +
  a **Save** button that raises an `.alert` with a name `TextField` → `savePreset`.

### 2. Lock at creation
- **`ProjectModel`** gained `@Published paramsLocked: Bool` and an init param
  `paramsLocked: Bool = true`. In-memory only (a restored project is ALWAYS locked, so
  there's nothing to persist): the `restoring:` convenience + the legacy `open()` path
  default to `true`; only `AppModel.continueToWorkspace` (a fresh import) passes
  `false`, so the auto-presented creation sheet is editable exactly once.
- **`AppModel.closePrintParams`** now also sets `project.paramsLocked = true` after the
  clamp+persist — the creation sheet's Done/scrim-dismiss COMMITS and LOCKS. Reopening
  a locked project's sheet is read-only, so a Done there is a harmless re-persist.
- **`PrintParamsSheet`** branches on `project.paramsLocked`: unlocked → the editable
  grid + infill/pattern controls + preset controls; locked → a read-only value grid
  (`readOnlyField`) + a "Fixed" lock chip + an info note ("locked when the project was
  created … create a new project to print at different settings"). The subtitle copy
  also swaps to the fixed-for-this-project message when locked.

### 3. Infill-aware physics at the display layer
Confirmed from `core/src/simp/minimize_plastic.cpp` (lines ~361-366) that the core
reports the **SOLID** margins / stress and applies its `infill_margin_knockdown`
**only at the acceptance gate** — never to the reported/displayed values. So the app
must (and now does) knock the DISPLAYED figures down itself, with **no double-count**.

In **`ResultsModel`**:
- New inputs `infillPattern` (for labels) + derived `infillKnockdown`
  (`FailureLoad.infillKnockdown(percent:)`, the same `f^1.5` curve as the core) and
  `effectiveYieldStrengthMPa = yieldStrengthMPa × infillKnockdown` — the single limit
  every readout keys to. Solid (100 %) → knockdown 1 → unchanged (no regression).
- **Stress scale + legend** key to `effectiveYieldStrengthMPa` (was raw yield); the
  legend caption annotates the infill (e.g. "PLA · scaled to 5 MPa yield at 20%
  gyroid"). `peakToRedMultiplier` (= scale/peak) therefore stays coupled to the
  failure multiple, so the flex flush-to-red still matches failure.
- **Hot spot** "% of yield" is measured against `effectiveYieldStrengthMPa`.
- **`FailurePrediction`** rewritten to ONE honest value: `multiplier = effectiveYield
  / peak`, `failureLoadKg = multiplier × appliedLoad`, `valueLabel`, `headline`
  ("Holds ~157 lb at 20% gyroid", or no suffix when solid), `subtitle`
  ("At 20% gyroid infill · yields at the marker" / "Solid-print estimate · …"),
  `effectiveYieldMPa`, `infillPercent`, `infillKnockdown`. Removed the old
  `solidValueLabel` / `infillFailureLoadKg` / `infillValueLabel` / `infillNote` pair.
- **`buildTabs`** takes a `knockdown` param; the per-variant **worst-case margin** and
  the **layer-shear** classification (via interlayer margin) are knocked down to the
  printed infill. `maxStressMPa` (raw von Mises, the no-material fallback scale) is
  left solid — only the LIMIT is knocked down.

Call-site + view updates: `ResultsScreen` threads `infillPattern`, drops the separate
infill-note line (the headline now carries it), and the failure-marker callout reads
`fp.valueLabel`. `WorkspacePlaceholder` passes `project.printParams.infillPattern`.

## Tests (headless, macOS `swift test`)
- **`ResultsModelTests`** (75, green): rewrote the failure tests for the single-value
  semantics (`testFailureIsOneInfillAdjustedValue`,
  `testFailureSolidHasNoInfillSuffixAndFullStrength`, `testInfillWeakensFailureLoadVsSolid`,
  and `valueLabel` renames). Added consistency tests proving the SAME knockdown reaches
  every readout: `testInfillKnocksDownEveryDisplayedStrengthFigureConsistently`
  (scale = legend = hot-spot-margin = failure-multiplier = peak-to-red, all vs
  effective yield), `testSolidProjectLeavesPhysicsFiguresUnknockedDown` (no
  regression), `testInfillKnocksDownLayerShearClassification`.
- **`PrintParamsTests`** (24, green): preset round-trip (`testPresetStoreRoundTrip`),
  app-wide persistence across launches (`testSavePresetPersistsAppWideAcrossLaunches`),
  Default-leads (`testAllPresetsAlwaysLeadsWithBuiltInDefault`), blank-name guard,
  apply-into-project, and lock enforcement
  (`testNewProjectStartsUnlockedThenLocksOnCreationSheetDone`,
  `testApplyPresetIsNoOpOnceLocked`, `testRestoredProjectIsLocked`).

`swift build` clean (pre-existing Swift-6 concurrency warnings only). Full suite:
**318/323 pass**; the **5 failures are PRE-EXISTING and unrelated** — core-bridge
`minimize_plastic` tests failing with "gravity_direction is (near) zero length"
(`TopOptKitTests` + `RunModelTests`), which I confirmed also fail on a clean `main`
(`git stash` → same failure). Not app-track code; not touched here.

## Notes / decisions
- **Preset picker label** is a static "Presets" (not the last-selected name): once a
  preset's values are loaded the user can edit them, so a persistent "current preset"
  name would go stale/misleading. Selecting is one-shot load; presentation is device QA.
- **0 % infill** now knocks to the core's floor (`1e-3`) like any sparse value (honest:
  a 0 % part is very weak), rather than the old code's "treat 0 as solid" for the note.
  100 % (and any ≥100) stays exactly solid.
- Kept using `FailureLoad.infillKnockdown` (already the in-sync app copy of the core
  curve — see the memory note on the duplicated app/core knockdown), so no new
  duplication was introduced.
- **Device QA left for the maintainer** (M7 /app/ standard): the preset picker + Save
  dialog, the locked read-only sheet + note, and the infill-annotated failure/legend
  copy on device. The ROADMAP box is intentionally left unchecked.
