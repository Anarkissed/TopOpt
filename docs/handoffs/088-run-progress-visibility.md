# 088 — Run-progress visibility

**Track:** app (presentation only). **Territory:** `/app/` — no `/core/`, no fixtures,
no ROADMAP box. **Branch:** `claude/optimization-progress-display-b61f60`.

Make an in-flight optimization VISIBLE and legible. On a design-box 64³ ladder
(~20 min/rung × 4 rungs ≈ 80 min) the only signal was a small, inert "Optimizing
more variants…" pill — no progress, no rung count, no elapsed/remaining. A live run
was indistinguishable from a dead one for over an hour.

---

## STEP 1 — Inventory: what progress data already exists

### a. What `r` / `rc` / `iter` mean, and whether they reach the app

The bridge progress callback is
`ProgressFn = void (*)(void* ctx, uint64_t rung_index, uint64_t rung_count, int iteration)`
([TopOptBridge.hpp:122](app/TopOptKit/Sources/TopOptBridge/include/TopOptBridge.hpp)):

- **`rung_index`** — 0-based index of the current volume-fraction rung of the
  material-reduction ladder.
- **`rung_count`** — total rungs in the ladder.
- **`iteration`** — 1-based SIMP/OC iteration *within the current rung* (0 before the
  first tick).

**They reach the app today.** The C trampoline
([TopOptKit.swift:308](app/TopOptKit/Sources/TopOptKit/TopOptKit.swift)) → `ProgressBox`
→ the closure in `RunModel.start` → `publish(RunProgress(rung:rungCount:iteration:))` on
the main actor, stored in `RunModel.progress`
([RunModel.swift](app/TopOptKit/Sources/TopOptFlows/RunModel.swift)). `RunProgress` also
derives `stageLabel`, `percent`, and an *asymptotic* `fractionComplete`
(`1 - exp(-iter/60)` per rung) — the last of which is a **fabricated** within-rung ramp
(there is no real sub-rung progress signal).

### b. What `RunModel` already knows

- **phase** — `idle / running / succeeded / cancelled / failed` (`@Published`).
- **rung index + ladder length** — via `progress` (rung, rungCount).
- **iteration within the rung** — via `progress.iteration`.
- **streamed variant count** — `outcome?.variants.count`, grown by `appendStreamed`
  (progressive results).
- **start time** — **did NOT exist.** Nothing recorded when the run began, so elapsed
  time / ETA were unavailable. (Added — see STEP 2.)
- **cancel** — `RunModel.cancel()` exists (backed by `CancelToken`), already public.

Nuance worth knowing: once the first variant streams, the results screen takes over and
`appendStreamed` sets `progress = nil` — but the very next OC tick calls `publish` again,
so `progress` is *live* while a rung runs, and only momentarily nil at variant
boundaries. The data was there; it just wasn't wired to the pill.

### c. Is MMA's per-iteration compliance/change history available app-side?

**No.** The callback payload is `(rung, rungCount, iteration)` only — no compliance, no
change, no per-iteration timing. So a compliance sparkline / true convergence curve is
**not** possible without a core channel change (out of territory). Any time estimate must
be built from wall-clock + rung structure alone.

### d. What the pill rendered and why it was inert

`ResultsScreen.streamingChip` rendered a spinner + the static string "Optimizing more
variants…". Inert because (1) it was a plain non-interactive `HStack`, and (2) it was
driven only by `streaming: Bool` (`run.isStreaming`) — `RunModel.progress` /
`startedAt` were **never passed into `ResultsScreen`**, so it had no rung, iteration,
count, or time to show even though the data existed on `RunModel`.

The full-screen running card (`RunScreen.runningCard`, shown only before the first
variant streams) *did* show progress, but as a big `NN%` + a bar driven by the
fabricated `fractionComplete` ramp — and it vanished once results appeared, i.e. for the
entire streaming tail (the ~80-minute part) the pill was the only indicator.

---

## STEP 2 — What was surfaced

New shared view **`RunProgressReadout`**
([RunProgressReadout.swift](app/TopOptKit/Sources/TopOptFlows/RunProgressReadout.swift))
renders the honest, live readout from `RunModel` READS, used by every surface so they
agree:

- **Variant N of M** (rung+1 of rungCount) — honest, exact.
- **SIMP iteration K** — honest, exact; ticks up = "it's alive".
- **Elapsed** — live `M:SS` / `H:MM:SS`, ticked once/second by `TimelineView(.periodic)`.
- **Est. remaining** — a **clearly-labelled** countdown ("~about 42 min left"), or
  "estimating…" until the first variant lands.
- **Discrete** rung bar (completed variants / total) — steps at boundaries, flat within a
  rung. **No fabricated fill toward a fake 100%.**

**Honesty constraint (086-mma-plateau-termination):** rung termination is ADAPTIVE
(fires ~iter 100–145, safety cap 200), so within-rung progress is unknowable in advance.
The readout therefore makes **no** sub-rung claim. The ETA is derived from *measured
seconds-per-completed-rung* — the only durations we can actually measure — and is:

- **nil until ≥1 rung completes** (no rate yet → the UI says "estimating", never invents
  a number);
- **monotone within a rung** — `currentLeft` shrinks as the current rung runs, so it
  counts DOWN and never inflates while you wait;
- **explicitly an estimate** in the copy.

The math lives in the pure, unit-tested `RunProgress.remainingEstimate(elapsed:
currentRungElapsed:)` and `RunProgress.rungFractionComplete`.

### The one non-view change: `RunModel.startedAt`

Elapsed time needs the *true* run start, which the view can't know if it was created
mid-run (the results screen appears ~20 min in). Added a single additive `@Published
public private(set) var startedAt: Date?` — set in `start()`, cleared in `reset()`.
**Presentation-only:** nothing reads/writes it except the readout; it does **not** touch
how runs persist or stream. Because `RunModel` is owned by `ProjectModel` it survives a
Home round-trip, so a backgrounded 80-minute run reopened later still shows truthful
elapsed. (This is the *only* `RunModel` state addition; see "Coordination" below.)

Surfaces updated:
- **`RunScreen.runningCard`** — replaced the fabricated `NN%` + ramped bar with
  `RunProgressReadout`. Kept the pulsing "OPTIMIZING" header + Cancel / Run-in-Background.
- **`RunScreen.minimizedChip`** — replaced "Optimizing NN%" with the compact honest line
  ("Variant N of M · M:SS").
- **`ResultsScreen.streamingChip`** — now the live, tappable pill (STEP 3).

## STEP 3 — Made inspectable

The results pill is now **tappable** (a chevron; `progressDrawerOpen` state). Tapping
opens a compact **drawer** reusing the right-rail glass-panel treatment, containing the
full `RunProgressReadout` plus a **Cancel run** affordance wired to the existing
`RunModel.cancel()` (no RunModel change needed — an 80-minute run must be stoppable).
`ResultsScreen` gained an optional `run: RunModel?` (+ `runResolution` / `runMaterialName`
for the footer), passed from `WorkspacePlaceholder`; nil in previews/tests falls back to
the old static label, so no existing caller broke.

---

## Coordination with the concurrent data-loss task

The data-loss / SwiftUI-publishing task owns `RunModel` / `AppModel` / streaming
persistence (branch `claude/swiftui-state-corruption-94b139`). At the time of writing its
worktree was **clean at main HEAD** (no committed or uncommitted RunModel changes), so
there was no live collision. This task stayed presentation-side:

- **Did NOT** touch `appendStreamed`, `finish`, `outcome`, persistence, or the streaming
  path.
- The **only** `RunModel` edit is the additive `startedAt` property (+ its set in
  `start`, clear in `reset`) — orthogonal to persistence/streaming and trivially
  mergeable. If that task also adds run-lifecycle state, the merge is a two-line
  add in the same two methods.
- Everything else is new/among presentation files: `RunProgressReadout.swift` (new),
  `RunScreen.swift`, `ResultsScreen.swift`, `WorkspacePlaceholder.swift` (one call site).

Nothing here required changing how runs persist or stream, so nothing was deferred to
that task on those grounds.

---

## Evidence (raw counts)

- `swift build` — **Build complete!** (only pre-existing warnings; none from new code).
- Fresh-worktree caveat hit as expected (stale vendored `libtopopt.a` → undefined
  `marching_cubes_resampled` / `minimize_plastic_solved_grid` at link); fixed by
  `scripts/build_core.sh` per memory `app-worktrees-need-build_core.sh`.
- `swift test` (macOS, whole package): **Executed 416 tests, with 0 failures** in ~31 s.
- `RunModelTests` alone: **Executed 32 tests, with 0 failures** (6 new):
  `testRungFractionIsDiscreteAndFlatWithinARung`,
  `testRemainingEstimateNilUntilFirstRungCompletes`,
  `testRemainingEstimateProjectsFromCompletedRungs`,
  `testRemainingEstimateCountsDownWithinARung`,
  `testRemainingEstimateNonNegativeWhenCurrentRungRunsLong`,
  `testStartSetsStartedAtAndResetClearsIt`.

Per the M7 `/app/` standard, the readout's *logic* (ETA + rung-fraction math, startedAt
lifecycle) is headlessly tested; the SwiftUI pixels, the 1 Hz tick, the drawer
animation, and the tap target are **maintainer device QA**.

## Device QA — maintainer's call

- Does the readout make an ~80-minute run tolerable — variant N/M + climbing iteration +
  live elapsed enough to know it's alive?
- Does the ETA read as **honest** (labelled estimate, counts down within a rung, shows
  "estimating…" before the first variant) rather than a fake promise?
- Pill tap target / drawer placement above the savings tabs; Cancel reachability.

## Not done / deferred

- No compliance/convergence curve — the callback carries no per-iteration compliance
  (STEP 1c); would need a core channel (out of territory).
- The fabricated `RunProgress.fractionComplete` / `percent` are now unused by the UI but
  left in place (still covered by their existing tests) to avoid touching more than
  needed; a later cleanup could remove them.
