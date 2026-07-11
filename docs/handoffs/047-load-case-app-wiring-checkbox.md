# Handoff 047 — Optimize uses the real load case (app wiring) + minimize-plastic toggle

## Task (maintainer-directed, interactive)
Wire the app's Optimize button to the load-case engine (handoff 046) so on-device
results reflect the user's declared anchors/loads instead of self-weight, and add
the "minimize plastic" checkbox in two places (import sheet + top-right by the
gravity chip) with the on/off × forces behavior the maintainer specified. This is
the step that turns the feature on for the user. Not a ROADMAP task — no box.

## Semantics implemented (maintainer's matrix)
The `minimizePlastic` toggle = "pursue material reduction". Combined with the
declared forces, the engine (handoff 046) already realizes:
- **on + no forces** → self-weight reduction ladder.
- **on + forces** → reduction ladder driven by the forces.
- **off + forces** → one conservative variant that just handles the forces.
- **off + no forces** → Optimize disabled (nothing to do).

## What I did (all `/app/`, M7-scoped; tested logic headless, pixels device-QA)

### The wire (self-weight → real forces)
- `RunModel.bridgeRunner` now ROUTES: a STEP model → `minimizePlasticLoadCase`
  (anchors → clamps, load groups → tractions, the toggle → ladder vs single); an
  STL model → the self-weight `minimizePlastic` (no faces to build a load case).
- `RunRequest` carries the load case: `anchorFaceIDs`, `loadGroups`
  (`[TopOptKit.LoadGroupSpec]`), `minimizePlastic`, `buildDirection`, plus
  `isStepModel`.
- `ProjectModel.loadCase()` assembles it from `selection` + `force` + `viewerMesh`
  in the **MODEL/grid frame the solver uses** (not the settled world frame): anchor
  groups → their B-rep faces; load groups → faces + force via a NEW
  `ForceModel.loadForceVectorModel` (gravity loads point along the stored model
  gravity, NOT world −Y as the arrow-render `loadForceVectorNewtons` does;
  push/pull are ∓/± the model face normal). Build direction = −gravity (+Z default).
- `AppModel.makeRunRequest` fills the request from `project.loadCase()` +
  `project.minimizePlastic`.

### The checkbox (two places)
- **Import sheet** (`ImportSheet`): a "Minimize plastic" row (checkbox + one-line
  explainer), bound to a new `AppModel.minimizePlastic` draft flag; `newTopOpt()`
  resets it to the default (on); `continueToWorkspace()` carries it onto the project.
- **Workspace top-right** (`WorkspacePlaceholder`): a "Minimize plastic" toggle chip
  stacked under the gravity chip (new `topRightControls` VStack), bound to
  `project.minimizePlastic`.
- **Gating**: `ForceModel.canOptimize(in:minimizePlastic:)` (new, tested) — enabled
  when gravity is set, no group is pending, AND (toggle on OR a full anchor+load
  case). The Optimize sub-label reflects the mode ("minimize plastic · N anchors ·
  M loads" / "minimize plastic · self-weight" / "needs an anchor and a load").
- **Persistence**: `ProjectModel.minimizePlastic` is snapshotted (an OPTIONAL
  `ProjectSnapshot.minimizePlastic`, so pre-existing schema-1 snapshots still decode
  — nil ⇒ on); survives navigation + relaunch.

## Test evidence (raw, pasted, unedited) — full macOS package suite
```
Test Suite 'TopOptDesignTests.xctest' passed at 2026-07-10 21:12:33.790.
	 Executed 17 tests, with 0 failures (0 unexpected) in 0.013 (0.026) seconds
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-10 21:13:26.802.
	 Executed 167 tests, with 0 failures (0 unexpected) in 52.310 (52.376) seconds
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-10 21:13:31.012.
	 Executed 21 tests, with 0 failures (0 unexpected) in 3.628 (3.635) seconds
** TEST SUCCEEDED **
```
(205 = 17 design + 167 flows [+6] + 21 kit.) Both iOS slices `** BUILD SUCCEEDED **`.
Core `ctest` not re-run (no `/core/` change this run; the engine's 26/26 stands from
handoff 046).

New tests:
- `ForceModelTests.testLoadForceVectorModelFrame`: gravity load → model gravity
  (−Z), NOT world −Y; push/pull → ∓/± normal; kgf→N magnitude; nil for an anchor.
- `ForceModelTests.testCanOptimizeWithMinimizePlastic`: setup-phase off; on+no-groups
  enabled / off+no-groups not; anchor+load enabled either way; a pending group blocks.
- `ProjectModelTests.testLoadCaseAssemblesAnchorsAndLoads`: anchors + loads + model
  force + build direction from a real project.
- `ProjectModelTests.testMinimizePlasticPersistsAcrossReload`: the toggle survives
  relaunch (a fresh AppModel over the same store restores it false).
- `ProjectModelTests.testMakeRunRequestCarriesLoadCaseAndFlag`: `makeRunRequest`
  forwards the load case + flag.
- `RunModelTests.testRunRequestIsStepModel`: STEP/STP → load-case path; STL → self-weight.

### Test-honesty check (throwaway, nothing committed)
Changed `loadForceVectorModel`'s gravity case to world −Y: both
`testLoadForceVectorModelFrame` and `testLoadCaseAssemblesAnchorsAndLoads` FAILED.
Restored; re-ran green (205).

## What I did NOT do
- **Did NOT verify on device.** The checkbox pixels/placement, and that a real
  on-device run now reflects the forces, are maintainer device QA (the M7 standard).
  Run `./app/scripts/build_core.sh` first — the app links the vendored core, which
  handoff 046 changed.
- **Did NOT make variants recommendation-driven.** Still the fixed ladder
  {0.7,0.5,0.3} (on) / {0.9} (off). "Lightest that stays safe for your loads" is the
  next step (maintainer-sequenced after real loads).
- **Did NOT combine self-weight WITH the external loads** — external replaces
  self-weight when present (handoff 046 modeling choice).
- **Did NOT change orientation search.** `buildDirection` = −gravity (the settle
  direction); the M4.4 scorer is not run to pick a print orientation here.
- **STL parts** still self-weight only (no faces for a load case); off+STL leaves
  Optimize disabled (a faceless part can't declare forces). M7.Zb (STL regions) is
  the future path to give STL a real load case.

## Warnings for the next run
- **The two force-vector methods differ ON PURPOSE.** `loadForceVectorNewtons`
  (world −Y gravity) renders the settled arrow; `loadForceVectorModel` (model-frame)
  feeds the solver. Don't unify them — the frames are different.
- **`DECISIONS.md`** still carries the maintainer's uncommitted 2026-07-11 print-time
  entry (not part of my commit), as in handoffs 045–046.
- Consider ROADMAP entries for: recommendation-driven variants, and (later) M7.dom
  "grow material".

## Blocked
None.
