# Handoff 049 — progressive (streaming) results

## Task (maintainer-directed, interactive)
Show the first optimized variant as soon as it's done, then add each later variant
to the results as it completes — instead of waiting for the whole run. Follows the
Play-button fix (handoff 048b / commit 66e625a). Not a ROADMAP task — no box.

## What I did — the solver now streams each variant as it finishes
End-to-end (core → bridge → Swift → RunModel → results), tested where verifiable.

### Core (backward-compatible; V-gates re-run 26/26 green)
- `MinimizePlasticOptions.on_variant` (new, optional `std::function`): the driver
  invokes it once per ACCEPTED rung, right after that rung's full analysis and
  BEFORE the next lighter rung is optimized. Absent by default (all existing
  callers unchanged). Forward-declared `MinimizePlasticVariant` since the options
  precede it.

### Bridge (`/app/`)
- A C `VariantFn(void* ctx, const OptimizeResult* partial)` threaded through both
  run entry points. `set_variant_stream` wires the core `on_variant` to it,
  packaging each streamed variant as a ONE-variant `OptimizeResult` carrying the
  run's grid metadata. Extracted `to_optimize_variant` (one source of truth for the
  per-variant field mapping, shared by the result builder + the stream).

### Swift wrapper (`TopOptKit`)
- `minimizePlastic` / `minimizePlasticLoadCase` gain an `onVariant:
  (OptimizeOutcome) -> Void` closure (a one-variant partial outcome per call).
  Refactored the callback plumbing into `withRunCallbacks` + shared non-capturing
  C trampolines (progress + variant), so both entry points manage the closure
  boxes' lifetimes identically.

### RunModel
- The `Runner` gains an `onVariant` arg. `outcome` is now `@Published` and grows
  INCREMENTALLY as variants stream (`appendStreamed`), then is replaced by the
  authoritative final outcome on `finish`. `isStreaming` flags "more may arrive".
  `finish` keeps streamed variants on cancel (cancel-with-accepted → succeeded) and
  on a late solver error (earlier variants survive rather than a failure sheet).

### Results UI
- `ResultsModel` is now live-updatable: `update(from:)` re-derives tabs/scale/
  recommendation, preserving the user's tab pick + scrub + stress toggle. Until the
  user manually picks, the selection FOLLOWS the recommendation, so a freshly-
  arrived lighter variant becomes the default.
- `ResultsScreen` merges `liveOutcome` on `variants.count` change and shows an
  "Optimizing more variants…" chip while `streaming`.
- The workspace shows the results overlay as soon as the FIRST variant lands
  (`outcome` non-empty), not only on `.succeeded`; the run's progress card yields
  once results appear; Back cancels any still-running variants.

## Test evidence (raw, pasted, unedited)

### Core `ctest` — full V-gate suite (the core change is backward-compatible)
```
26/26 Test #26: cli_demo .........................   Passed  529.09 sec

100% tests passed, 0 tests failed out of 26

Total Test time (real) = 762.18 sec
```

### App package — `xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`
```
Test Suite 'TopOptDesignTests.xctest' passed ...
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-10 22:35:09.702.
	 Executed 169 tests, with 0 failures (0 unexpected) in 85.940 (86.010) seconds
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-10 22:35:14.704.
	 Executed 21 tests, with 0 failures (0 unexpected) in 4.408 (4.415) seconds
** TEST SUCCEEDED **
```
(207 = 17 design + 169 flows [+2] + 21 kit.) Both iOS slices `** BUILD SUCCEEDED **`.
Ran `./app/scripts/build_core.sh` first (core changed → the app links the new lib).

New tests:
- Core scenario **K**: `on_variant` fires once per accepted variant, heaviest-first,
  each fully analysed (margin + mesh) when streamed. Honesty-checked (disabling the
  emit fails K).
- `RunModelTests.testStreamedVariantsAppearBeforeFinish`: `outcome` grows during the
  run (results available after variant 1); `isStreaming` clears on resolve.
- `ResultsModelTests.testUpdateAppendsStreamedVariantsAndFollowsRecommendation`:
  appends streamed variants, moves the recommendation/selection to the newest
  lightest — until the user manually picks, then the pick sticks.

## What I did NOT do
- **Did NOT verify on device** — the live tab-appearance, the "optimizing more"
  chip, and the progress-card→results handoff are maintainer device QA (M7
  standard). `./app/scripts/build_core.sh` is REQUIRED first (core changed).
- **Did NOT add a Cancel affordance on the streaming results screen** — Back
  cancels + returns to the workspace; there's no "stop the rest but keep variant 1"
  button yet (a small follow-up).
- **Progress bar within a streaming run**: once results show, the per-iteration
  progress bar is hidden (replaced by the "optimizing more…" chip). The bar only
  drives the pre-first-variant wait.
- **Did NOT change the optimization animation** — still the reveal of the final
  shape (the "show the real optimization + video" feature is the other big ask,
  not started).

## Warnings for the next run
- **on_variant fires on the OPTIMIZING (background) thread.** The Swift trampoline
  converts + hops to main (`scheduler.runOnMain`); keep any new consumer main-safe.
- **The final authoritative outcome replaces the streamed one** in `finish`; if it
  has the same accepted-variant count, `ResultsScreen.onChange(variants.count)`
  won't refire — that's fine (same data). A rejected terminal bumps the count and
  triggers a harmless re-merge (filtered out).
- **`DECISIONS.md`** still carries the maintainer's uncommitted 2026-07-11
  print-time entry (not part of my commit), as in handoffs 045–048.

## Blocked
None.
