# 088 — SwiftUI state corruption / optimize-result data loss

DIAGNOSE-FIRST task. Symptom (device, reproduced): the console floods with
"Publishing changes from within view updates is not allowed…" during an optimize
run; separately, an in-flight run's results VANISH — the maintainer sees rung 0
(-32%, 587 g) with "Optimizing more variants…" still showing, leaves the project,
returns, and the ENTIRE optimization is gone; a 96³ run that FINISHED before he left
persisted correctly; "See Original" appears to clear the optimization.

## STEP 1 / STEP 2 findings FIRST — the named mechanisms

**The publishing violation and the data loss are TWO SEPARATE bugs.** The hypothesis
that they are the same (streamed variants appended during a view body never commit)
is FALSE: in production the streamed-variant append runs on `DispatchQueue.main.async`
(`GCDRunScheduler.runOnMain`), i.e. on a fresh runloop turn, NOT during a view-body
evaluation — so the publishing violation does not drop the variant. The variant is
dropped by an explicit cancel. Evidence for each below.

### Bug A — the publishing violation (UB flood, render path)

Named site: `MetalMeshView.Coordinator.apply(_:to:)`
([MetalMeshView.swift](../../app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift)),
which runs inside `updateUIView` / `updateNSView` — a SwiftUI view-update pass. It
mutated observed state synchronously in two places:

1. `model.adopt(renderer.camera)` (was ~line 1469) writes the freshly-framed camera
   back to the shared `OrbitCameraModel`. That model is a `@StateObject` the live
   `ResultsScreen` / `WorkspacePlaceholder` body observes, and `adopt` sets its
   `@Published camera` — so this is precisely **"Publishing changes from within view
   updates."** It fires whenever the displayed mesh signature changes: every streamed
   variant during a run (the flood), and on the ResultsScreen↔Workspace swap that
   "See Original" performs.
2. `publishProjection(from:)` (was the synchronous call at ~line 1626) calls
   `onProjection` → the host view's `@State projection` — "Modifying state during view
   update" (same class of UB; an async copy of this call already existed alongside it).

How many distinct violations: effectively ONE call site (`apply`) with two publishing
lines, firing repeatedly (once per mesh change) — that is the flood, not many sites.

This is a rendering-consistency UB. It does NOT corrupt `RunModel.outcome` (which is
updated on `main.async`, off the view-update pass), so it is not the data-loss cause.
It plausibly makes "See Original" *look* like it cleared results (a dropped/inconsistent
update as the overlay swaps), but the variant data is intact underneath.

### Bug B — the data loss (the real result destruction)

Named mechanism: **the results Back chevron cancelled the in-flight run, and the
cancelled-outcome path in `RunModel.finish` wiped the already-streamed, already-shown
accepted variants.**

- STEP 2a — persistence: streamed variants are held IN MEMORY on `RunModel.outcome`
  (`appendStreamed`), written to disk only when `AppModel.persist` runs (on
  `backHome()` and scene-phase→background), gated on `project.hasResults`. So `backHome`
  *does* write the streamed variant to disk. The loss is not a missing write.
- The trigger: `WorkspacePlaceholder` passed `onClose: { run.cancel(); model.backHome() }`
  to the results screen's Back chevron. `run.cancel()` sets the cancel token; the core
  returns a cancelled outcome; `RunModel.finish`'s `o.cancelled` branch did
  `outcome = nil` — wiping the variant the user was looking at, IN MEMORY.
- STEP 2b — reopen: `AppModel.open` hits the `projectsById` cache (same launch → cache
  HIT, ~line 474) and reuses the SAME live `ProjectModel`, whose `run.outcome` is now
  nil. `restoreFromDisk` (which would have found the on-disk copy) is only consulted on
  a cache MISS (relaunch). So the on-disk variant is never read and the workspace shows
  nothing — "the entire optimization is gone."
- Why the 96³ finished run survived: a finished run has `phase == .succeeded`, and
  `cancel()` guards `phase == .running`, so the Back chevron's `cancel()` was a no-op —
  its outcome stayed. Exactly matches the report.
- STEP 2c — the stale-result guard (076) is NOT implicated here: the reopen is a cache
  HIT on the same model/token, so nothing is dropped as "stale."
- STEP 2d — "See Original": `onSeeOriginal: { viewOriginal = true }` is a pure `@State`
  toggle in `WorkspacePlaceholder`; it hides the results overlay and shows the workspace
  with a "See Results" chip, KEEPING `run.outcome`. It does not clear, replace, or
  rebuild — it toggles the displayed view. It is NOT the rebuild path of (b) and does
  not destroy data. The "appears to clear" perception is the vanished overlay (the
  return chip is easy to miss) aggravated by Bug A's UB on the view swap.

## STEP 3 — headless reproduction (failed against pre-fix code)

`RunModelTests.testStreamedAcceptedVariantSurvivesLeavingAnInFlightRun`
([RunModelTests.swift](../../app/TopOptKit/Tests/TopOptFlowsTests/RunModelTests.swift)):
streams one accepted variant, then does what the Back chevron did (`model.cancel()` +
the core returning a cancelled outcome), and asserts the variant SURVIVES. Against
pre-fix code it failed (`outcome == nil`, `phase == .cancelled`). A companion test
`testCancelBeforeAnyVariantStillDiscardsCleanly` pins the unchanged clean-cancel case
(cancel before any variant → empty, `.cancelled`).

## STEP 4 — the fix (minimal, per the named causes)

- **Bug B, mechanism** — `RunModel.finish` cancelled branch now KEEPS already-streamed
  accepted variants (resolving `.succeeded`, identical to the existing mid-run
  solver-throw handling); it only discards to `.cancelled` when nothing was shown.
- **Bug B, trigger** — the results Back chevron is now `onClose: { model.backHome() }`
  (no `run.cancel()`), so an in-flight ladder KEEPS OPTIMIZING when the user leaves —
  leaving and returning shows MORE variants. (Did NOT fix this by preventing the user
  from leaving.) With the run kept alive, the reopen cache-HIT shows the growing
  outcome; a relaunch (cache MISS) restores the persisted copy as before.
- **Bug A** — `MetalMeshView.Coordinator.apply` now hops both published-state
  side-effects (the camera `adopt` write-back and `publishProjection`) to the next
  runloop via `DispatchQueue.main.async`, so nothing publishes during the view-update
  pass. The renderer still holds the framed camera for the current draw; the model /
  projection update one runloop later (the async projection publish already existed).

## Guards

- Regression tests above (`swift test`, TopOptFlows). Raw count: **412 tests, 0
  failures** (410 baseline + 2 new); pre-fix the new survival test failed with 3
  assertions.
- Completed-run persistence (the 96³ path) is unchanged — `cancel()` was already a
  no-op off `.running`, and `finish`'s success/succeeded path is untouched.
- "See Original" never destroyed data in code (a `@State` toggle that keeps
  `run.outcome`); the fix does not regress that.
- The publishing warning: the two synchronous publishes inside the view-update pass are
  gone, which is the mechanism of the warning. A clean console is device QA (the M7
  /app/ standard) — **not verifiable headlessly here**; stated honestly.

## Deferred / not done

- On-device console confirmation that the "Publishing changes…" flood is gone (device
  QA; the code no longer mutates observed state during a view update).
- Persisting each streamed variant to disk AS IT ARRIVES (belt-and-suspenders for a
  mid-run CRASH before any `persist`) — not needed for the reported same-launch bug,
  which is fixed by keeping the live run/outcome alive; left as a future robustness item.
- A background-execution assertion when leaving results to Home (so a long ladder
  survives iOS SUSPENDING the app, not just in-app navigation) — separate lifecycle
  concern, out of scope; the in-app leave→return path is fixed.
- No ROADMAP box checked (per task).
