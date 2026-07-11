# Handoff 046 — user load-case optimization: core + bridge engine

## Task (maintainer-directed, interactive)
Resolve the "self-weight only" gap: make the optimize use the **user's declared
load case** (M7.6 anchors/loads/directions/weights) instead of the part's own
weight, so the reported margins/stresses reflect the forces the user actually set
(ARCHITECTURE §1 mode (a): "user-defined loads"). This was the Blocked item from
handoff 044 ("minimize_plastic ignores the tagged load case"); the maintainer
ruled to do it. Sequencing chosen: **real loads first, recommendation-driven
variants next** (see "Remaining"). NOT a listed ROADMAP task — no box to check.

## Why it was self-weight-only (for the record)
`minimize_plastic` (M5.3) is the mode-(b) self-weight driver; the app's run path
(M7.7) plugged into it. Mode (a) was scaffolded — M7.6 `LoadCaseTagger` tags the
faces (anchor→Fixture, load→Load, frozen shells) and `ForceModel` computes the
force vectors — but the last mile (feeding them to the solver) was deferred. The
core already supported it: `simp_optimize` takes an arbitrary load vector, and
`traction_loads` (M7.6-core) turns a load face + force into consistent nodal loads.

## Scope of THIS run: the verified ENGINE (core + bridge + Swift wrapper)
Everything here is headlessly verified. The app wiring (Optimize → this path) and
the "minimize plastic" checkbox UI are the next run (device-QA); the engine is
built so they are mechanical.

### Core (allowed — /core/ is not M7-gated; tests-first; V-gates re-run green)
- `MinimizePlasticOptions` gains `std::vector<NodalLoad> external_loads`
  (`pipeline.hpp`). When NON-EMPTY it REPLACES self-weight as the design load; when
  empty (all existing callers) the driver is unchanged (self-weight).
- `minimize_plastic.cpp`: the single `loads` line now picks `external_loads` when
  provided, else `self_weight_loads`. `gravity` is only validated in the
  self-weight case (it's the self-weight magnitude; unused under external loads);
  `gravity_direction` is still required (it defines the reported build orientation
  + interlayer axis). `loads` flows unchanged into the optimize, the stress
  recovery, and the margins — so the whole pipeline reports for the user's forces.

### Bridge (`/app/`, M7-scoped)
- `run_minimize_plastic_loadcase(...)` (new): voxelizes the STEP part once, tags
  anchors Fixture (clamped) + each load group's faces Load, assembles per-group
  tractions (each on a clean anchors-only grid copy so a group's force covers only
  ITS faces) into the external load, builds Dirichlet BCs from the Fixture voxels'
  nodes, and runs. `minimize_plastic` on → ladder {0.7,0.5,0.3}; off → one
  conservative variant {0.9}. Well-posed fallbacks: no load groups → self-weight;
  no anchors → auto min-x clamp. The load case crosses the interop boundary as
  `BridgeLoadCase` (only scalar vectors — no nested struct vectors — so Swift
  builds it member-wise via `push_back`). Result population factored into a shared
  `to_optimize_result` helper (both run entry points now use it — one source of
  truth for the M7.0b/M7.8 fields).

### Swift wrapper (`TopOptKit.swift`)
- `TopOptKit.minimizePlasticLoadCase(stepPath:material:…:anchorFaceIDs:loadGroups:
  minimizePlastic:buildDirection:progress:)` + `LoadGroupSpec {faceIDs, force}`.
  Same M7.0a progress/cancel trampoline as `minimizePlastic`. Outcome conversion
  factored into a shared `convertOutcome`.

## Test evidence (raw, pasted, unedited)

### Core `ctest` — full suite (V-gate regression; the core change is backward-compatible)
```
26/26 Test #26: cli_demo .........................   Passed  437.84 sec

100% tests passed, 0 tests failed out of 26

Total Test time (real) = 632.28 sec
```

### App package — `xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`
(OCCT-free-iOS manifest per runs 039–045; benign OCCT `ld` warnings filtered)
```
Test Suite 'TopOptDesignTests.xctest' passed at 2026-07-10 20:54:43.063.
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-10 20:55:36.162.
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-10 20:55:40.323.
** TEST SUCCEEDED **
```
(199 = 17 design + 161 flows + 21 kit [+1 load-case].) Both iOS slices
`** BUILD SUCCEEDED **`. Ran `./app/scripts/build_core.sh` first (the vendored
xcframework had to be rebuilt so the app links the new external-load core).

New tests:
- Core `test_minimize_plastic` scenario **J** (external load case): a tip traction
  REPLACES self-weight; the tip nodal loads sum EXACTLY to the applied force; the
  run evaluates + accepts the ladder; stresses/margins finite + positive; the peak
  stress DIFFERS from the self-weight run (proves the load drives it); the gravity
  relaxation is external-load-only (self-weight with gravity 0 still throws).
- `TopOptKitTests.testMinimizePlasticLoadCaseUsesDeclaredForces`: real bridge on
  l-bracket.step — anchor one taggable face, hang a force on another, run with
  `minimizePlastic:false`; asserts one conservative variant, finite/positive
  stress, non-empty variant mesh, and `vonMisesField.count == nx*ny*nz`.

### Test-honesty check (throwaway, nothing committed)
Forced `minimize_plastic` to always use self-weight (ignore `external_loads`):
scenario J FAILED (`0% tests passed, 1 failed`). Restored; re-ran green
(`100% tests passed`).

## What I did NOT do (this is the engine, not the whole feature)
- **Did NOT wire the app's Optimize button to this path.** `RunModel.bridgeRunner`
  still calls the self-weight `minimizePlastic`. So on-device the run is STILL
  self-weight until the next run wires `minimizePlasticLoadCase` (building
  `anchorFaceIDs`/`loadGroups` from `project.selection` + `project.force`, which
  `LoadCaseTagger`/`ForceModel` already expose). **The user will not see real-load
  results until that wiring lands.**
- **Did NOT add the "minimize plastic" checkbox UI** (import sheet + top-right by
  the gravity chip). The engine already takes the flag; the UI + the on/off × loads
  matrix is the next run. Agreed semantics: on+no-forces → self-weight removal;
  on+forces → removal under the forces; off+forces → one conservative force-
  adequate variant; off+no-forces → nothing (Optimize disabled).
- **Did NOT make variants recommendation-driven** (still the fixed ladder / single
  {0.9}). "Lightest that stays safe for your loads" is the follow-on the maintainer
  sequenced after real loads.
- **Did NOT combine self-weight WITH external loads** — external loads REPLACE
  self-weight when present. Adding the part's own weight as a baseline body force is
  a refinement (usually negligible for a loaded structural part).
- **Did NOT add a "grow material / more plastic" path** — that's M7.dom (design-
  domain expansion), a separate parked milestone.
- **Load case is STEP-only** (face selection needs OCCT); STL parts fall back to
  the self-weight path. Consistent with M7.5 face selection being STEP-only.

## Warnings for the next run
- **Rebuild the xcframework** (`./app/scripts/build_core.sh`) is REQUIRED after this
  run before app tests — the core changed, and the app links the vendored core.
- **`DECISIONS.md` carries the maintainer's uncommitted 2026-07-11 print-time entry**
  (unstaged; not part of my commit), same as handoff 045.
- **This is not a ROADMAP task.** Consider adding ROADMAP entries for: (1) app load-
  case wiring + the minimize-plastic checkbox, (2) recommendation-driven variants,
  so the loop tracks them.
- The bridge re-voxelizes + re-imports the STEP per run (stateless, like the other
  bridge calls); the app's `LoadCaseTagger` tags via separate calls — the wiring
  should pass raw face ids + force vectors straight to `minimizePlasticLoadCase`,
  not pre-tag.

## Blocked
None.
