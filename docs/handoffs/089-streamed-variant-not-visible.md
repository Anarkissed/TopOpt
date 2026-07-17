# 089 — a streamed variant doesn't appear until you leave the project and re-enter

DIAGNOSE-FIRST task. Symptom (device, 64³ design-box run, reproduced): rung 2 finished
and did NOT show on the results screen; navigating away and back made it appear.
Concurrently the readout showed "Est. remaining: estimating…" at 1h21m elapsed with two
variants completed.

## STEP 1 — the end-to-end trace, and the answer to "one bug or two"

**TWO bugs, not one** — but they are the SAME MISTAKE made twice, in two views: *streamed
state is copied out of the model into view-local storage, and the copy misses updates.*
Both are in the view layer. Every model on the path is innocent; each was checked
directly, not by inspection.

### What is NOT broken (checked, with evidence)

- **(a) `appendStreamed` mutates a `@Published` correctly.** `RunModel.outcome` is a
  `@Published OptimizeOutcome?` (a struct), and `appendStreamed` REASSIGNS it
  ([RunModel.swift](../../app/TopOptKit/Sources/TopOptFlows/RunModel.swift)) rather than
  mutating through a reference. A probe streaming two variants through a live `RunModel`
  measured `outcome.variants.count == [1, 2]` and `ProjectModel.objectWillChange` firing
  6 times. The hypothesis in the task brief — variants behind a reference type, or a path
  that never reassigns — is **FALSE**.
- **The `ProjectModel` → workspace forwarding works.** `ProjectModel.runForwarding`
  (`Merge(run.$outcome, run.$phase) → objectWillChange`) fires on every streamed variant,
  and `WorkspacePlaceholder` (`@ObservedObject var project`) re-renders. Confirmed by
  hosting the real view graph: the workspace body ran with `liveCount=2` and rebuilt
  `ResultsScreen` with the 2-variant outcome.
- **(b) `ResultsScreen` reads a snapshot passed at construction, but that is fine** — the
  workspace re-creates the view VALUE on each pass, so `liveOutcome` is fresh in `body`.
  The staleness is one level deeper (below).
- **The bridge/core stream is fine.** `set_variant_stream` → `variantTrampoline` →
  `runOnMain` → `appendStreamed` delivered both variants. Proof from the device itself:
  leaving and re-entering shows the variant, so it was in `run.outcome` all along.
- **(d) Why leave→reopen fixes it.** `AppModel.open` takes the **cache HIT** path
  (`projectsById`, same launch) and reuses the SAME live `ProjectModel` — it rebuilds
  NOTHING from disk. What the reopen actually rebuilds is the **view**: `screen =
  .workspace` re-creates `WorkspacePlaceholder`, which re-creates `ResultsScreen`, whose
  `@StateObject ResultsModel` is then **constructed from the current outcome** —
  `ResultsModel.init(outcome:)`. So the difference between the rebuild and the live update
  is exactly `init(outcome:)` vs. `update(from:)`-via-`.onChange`. **That hinge is the
  bug.**

### Bug A — `ResultsScreen`'s merge runs against a STALE `self` (the headline symptom)

Named site: `ResultsScreen.body`'s
`.onChange(of: liveOutcome.variants.count) { _ in model.update(from: liveOutcome) }`
([ResultsScreen.swift](../../app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift)).

SwiftUI runs the `onChange` **action closure captured by the PREVIOUS body evaluation**.
The observed *value* handed to the action is fresh; `self` inside it is not. So
`model.update(from: liveOutcome)` re-applied the outcome the screen ALREADY had.

Measured directly, by instrumenting the real screen under a hosted view graph:

```
INSTR ResultsScreen.body liveCount=2 tabs=1
INSTR onChange n=2 selfLiveOutcome.count=1 accepted=1     <- n is fresh, self is STALE
INSTR tabs now=1                                          <- the merge re-applied the OLD outcome
```

Consequence: the results screen sits **permanently one variant behind** the run. Rung 2
lands and nothing changes; rung 3 landing would finally reveal rung 2. The last variant
never appears at all until something rebuilds the screen — which is precisely what
leaving the project and re-entering does. This matches the report exactly.

### Bug B — the readout LATCHES progress, and the latch can never take (the ETA symptom)

Named sites: `RunProgressReadout`'s `@State private var held: RunProgress?` +
`.onChange(of: model.progress)`
([RunProgressReadout.swift](../../app/TopOptKit/Sources/TopOptFlows/RunProgressReadout.swift)),
together with `RunModel.appendStreamed`'s `progress = nil`.

`snapshot` read `held ?? model.progress ?? RunProgress(rung: 0, rungCount: 1, iteration: 0)`.
`held` existed only to paper over `appendStreamed` nil-ing `progress` at every rung
boundary. But a latch fed by `.onChange` only updates when SwiftUI **observes** the
change: when a progress tick and the following `appendStreamed` land in the SAME runloop
turn (both are `DispatchQueue.main.async` hops — they batch whenever the main thread is
busy, e.g. while SwiftUI rebuilds the new variant's mesh), SwiftUI only ever sees
`nil → nil`. `onChange` never fires, `held` stays nil, `snapshot` falls back to the
**default rung-0 snapshot**, and `remainingEstimate` — which returns nil until
`rung >= 1` — reads "estimating…" for the rest of the run. The elapsed clock keeps
ticking regardless because `TimelineView` drives it independently of any observation,
which is why the readout looked alive while the ETA was frozen.

Reproduced headlessly (`held=nil` forever, ETA nil), and note what it is NOT:
`RunProgress.rung` **does** advance in the payload, and the readout does latch correctly
when SwiftUI gets a render pass between the tick and the append. So the honest statement
is: the ETA symptom is this fragility, and I reproduced it under a legitimate delivery
ordering — but I could not confirm from the app side that the maintainer's 1h21m instance
was that ordering rather than something in the payload. The fix removes the latch, so the
ETA is now correct under EVERY ordering. (One alternative I could not rule out from /app/:
if the core ever reported `rung_count == 1`, `RunProgress.init` clamps `rung` to 0 and the
ETA would read "estimating…" forever with the variant line showing "Optimizing". That is
/core/ territory and out of scope here; the app-side fix is independent of it.)

## STEP 2 — did 106 regress anything? NO

106's fix stands and is not implicated. Its two `DispatchQueue.main.async` hops
(`MetalMeshView.Coordinator.apply`'s camera `adopt` write-back and `publishProjection`)
were checked for exactly the failure mode the brief suspected — an async hop landing after
a view pass with no further trigger, or a `[weak self]` / `[weak model]` capture going nil:

- Neither hop is on the streamed-variant path. `appendStreamed` and `publish` reach the
  view through `RunModel.$outcome` / `$progress`, not through the renderer.
- `adopt` is guarded by `sig != appliedSignature`, so it fires only on a real mesh change
  and cannot loop or starve.
- What 106 DID remove was an *incidental* re-render (a synchronous publish during the view
  update, one per mesh change) that used to mask Bug A intermittently. Bug A predates 106
  — the same stale-closure merge is in the pre-106 code — so this is **not a 106
  regression**; 106 removed a coincidence that sometimes hid it. Restoring that publish
  would reintroduce the UB and would not fix the merge.

## STEP 3 — headless reproduction (both FAIL against pre-089 code)

[StreamedVariantVisibilityTests.swift](../../app/TopOptKit/Tests/TopOptFlowsTests/StreamedVariantVisibilityTests.swift) —
the only tests in the package that HOST SwiftUI (`NSHostingView` in a window, runloop
pumped by hand). That is deliberate and is the point of this handoff: **no model-level
test can see this bug**, because no model is wrong. The tests drive the REAL
`ResultsScreen` behind a real `ProjectModel`/`RunModel`, with variants streamed from a
runner gated by semaphores so each lands in its own render pass.

- `testSecondStreamedVariantAppearsWithoutLeavingTheProject` — pre-fix: `tabs.count == 1`,
  expected 2.
- `testETAResolvesToANumberOnceARungHasCompleted` — pre-fix: `XCTUnwrap(run.progress)`
  fails (the append erased the rung the readout needed).
- `testStreamedVariantsStillSurviveLeavingAnInFlightRun` — 088's guard, passes throughout.

The screen owns its `ResultsModel` as a `@StateObject`, so the tests inject one through a
new `resultsModel:` seam on `ResultsScreen.init` (the M7 /app/ house style — the run is
already tested through an injected scheduler / runner / notifier). Production passes nil.

## STEP 4 — the fix (minimal, per the named causes)

- **Bug A** — `.onChange(of: mergeTrigger) { trigger in model.update(from: trigger.outcome) }`.
  `MergeTrigger` is a small `Equatable` wrapper that compares on the variant COUNT only
  (the outcome carries meshes and per-voxel fields — comparing those every body pass would
  cost far more than the merge it guards) but CARRIES the outcome, so the action gets the
  fresh value SwiftUI passes it and never reads the stale `self`.
- **Bug B** — `appendStreamed` no longer nils `progress` (that clear bought nothing: the
  running card yields on `outcome` having variants, not on progress — see `RunScreen`),
  and the readout's `held` latch is deleted: `snapshot` now reads `model.progress`
  directly. `rungStartedAt` still anchors per rung, now keyed on `model.progress?.rung`.

Neither fix forces periodic refreshes, and neither publishes inside a view update
(`onChange` actions run after the update pass, as before) — 106's UB is not reintroduced.
The variant appears when it lands.

## Guards

- The three tests above. Raw count: **421 tests, 0 failures** (418 baseline + 3 new);
  pre-fix the two new repro tests failed as quoted.
- ETA produces a number once ≥1 rung has completed, driven by real progress payloads
  through a live run (`testETAResolvesToANumberOnceARungHasCompleted`).
- Streamed variants still survive leaving an in-flight run — 088's guard, re-asserted.
- No "Publishing changes from within view updates" regression: `MetalMeshView` is
  untouched and nothing added here publishes during a view-update pass. A clean device
  console remains device QA (the M7 /app/ standard) — **not verifiable headlessly**;
  stated honestly.

## Deferred / not done

- On-device confirmation of the ETA under the maintainer's exact 1h21m conditions, and
  whether the core ever reports `rung_count == 1` on a design-box ladder (that would clamp
  `rung` to 0 and read "estimating…" independently of anything here). /core/ territory.
- The `.onChange`-stale-`self` pattern is not audited repo-wide; only the two sites the
  symptom named are fixed. Any other `.onChange` action that reads `self` rather than its
  passed value has the same latent defect.
- No ROADMAP box checked (per task).
