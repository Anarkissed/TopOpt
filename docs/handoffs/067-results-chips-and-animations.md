# 067 — Results screen: compact drawers, bottom-right chips, flex↔color, animated load path

**Track:** app — `/app/` only. No `/core/`, no `tests/fixtures/**`, no `ROADMAP.md`.
Presentation + app-side coupling only: no new physics, no optimizer, no core data.
The ROADMAP box is deliberately **not** checked (per the task).

**Worktree:**
`/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/results-chips-animations-fcd354`
(branch `claude/results-chips-animations-fcd354`).

**Files touched (5):**
- `app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift`
- `app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift`
- `app/TopOptKit/Sources/TopOptFlows/MetalMeshView.swift`
- `app/TopOptKit/Tests/TopOptFlowsTests/ResultsModelTests.swift`
- `app/TopOptKit/Tests/TopOptFlowsTests/LoadPathTests.swift`

---

## The four fixes

### 1. Drawers were stretching nearly full-width → now compact, right-anchored
**Cause:** `flexDrawer` and `failureDrawer` (and the push control) contain
`HStack { label; Spacer(); value }` rows. That greedy `Spacer` has no intrinsic
width, so when the drawer VStack was offered the rail's full width (the rail frame
is `maxWidth: .infinity`), the HStack expanded to fill it — dragging the whole
card out to nearly the full screen with a big empty gap. (The Stress and Load-path
drawers only *looked* ok because their inner elements happened to carry
`.frame(width:)`.)

**Fix:** `resultsDrawerChrome()` now takes a `width:` and pins the drawer **content**
to exactly that width (`Self.drawerWidth = 150`) *before* the chrome padding, then
`.fixedSize()` so no ancestor can restretch the finished card. Every drawer is now
`content(150) + padding` wide — a slim card, no blank region. One consistent
treatment across all four drawers.

### 2. Chips moved from top-right rail → bottom-right cluster
`vizRail` was `.frame(..., alignment: .topTrailing)` with a trailing `Spacer()` and
a `.padding(.top, 76)` — i.e. the chips ran DOWN from the top-right. Now:
- the `Spacer()` is the **first** child (sinks the chips to the bottom),
- the frame aligns `.bottomTrailing`,
- horizontal padding is `xl4` (aligns the chips' right edge with the orientation
  cube), and
- `.padding(.bottom, cubeClearance)` (`xl4 + 50 + m`) lifts the cluster just above
  the bottom-right orientation cube so the two right-corner clusters never collide.

Each chip still slides its own compact drawer open to the **LEFT** (`vizRow`
unchanged: `Spacer · drawer · chip`, drawer transitions from the trailing edge).
One consistent pattern.

### 3. Flex now DRIVES the stress colors (blue→red with the wobble)
**Cause:** `stressColorMultiplier` returned the raw `flexAmplitude` (0→1) for the
flex branch. Amplitude 1 = the solved **1× field**, which for a part comfortably
below yield is mostly blue — so the wobble only ever cycled all-blue → dim-field →
all-blue, reading as "flat blue, never recolors." The failure **push** looked right
only because its multiplier climbs all the way to `yield/peak` (peak → red).

**Fix (reuse the push coupling exactly):** multiply the flex amplitude by a new
`peakToRedMultiplier` = `stressScaleMaxMPa / peak` — the multiple that drives the
peak voxel to the TOP of the shared scale (red). When the scale is keyed to yield
this equals `yield / peak`, i.e. the **same** multiple the failure push reaches at
failure (asserted in a test). So at full deflection the flex loop flushes the peak
to the identical red the push does; at rest it's blue → the body cycles
blue→red→blue with the motion. Reduced-motion pins amplitude 1 → the static
full-deflection frame shows the peak red. `peakToRedMultiplier` is cached per
selection (the `field.peak()` scan runs once per variant, not per frame).

The screen already turned the overlay ON during flex (`showStressColors =
stressOn || deflectionActive`) and already re-uploaded tints when the multiplier
moved — only the *magnitude* of the flex multiplier was wrong.

### 4. Load path: bigger, clearer, and ANIMATED (flowing dashes)
The overlay was 1px GL lines (Metal `.line` is always one pixel) and static.

- **Thickness/clarity:** a new `loadPathPipeline` + `loadPathShaderSource` renders
  each glyph as a **screen-space ribbon** — the vertex shader billboards the
  segment to a constant pixel width (`loadPathHalfWidth`) regardless of camera
  angle. `setLoadPath` expands each stride-7 segment pair into a 6-vertex ribbon
  (stride-12: `segStart, segEnd, side, endFlag, rgba`). The raw line buffer is kept
  as a **fallback** for when the ribbon pipeline can't build.
- **Animation:** a `loadPathPhase` (in `ResultsModel`, advanced by the results
  ticker via `advanceLoadPath`, `loadPathDuration = 1.6s`) is passed to the shader
  as a flow phase; the fragment shader scrolls a bright dash from `u=0 → u=1` along
  each segment over a dim steady base — force reads as travelling through the body.
  Reduced-motion never advances the phase → a static overlay (opt-out-safe). The
  phase is a cheap per-frame uniform (like `flexScale`); the ribbon geometry only
  rebuilds on selection.

The pure `LoadPath` derivation and `loadPathSegments` buffer layout are unchanged
(existing tests stay green).

---

## Tests

New/updated headless coverage (the color + flow logic; pixels are device QA):
- `ResultsModelTests`
  - `testStressColorMultiplierFollowsFlexAmplitude` — updated to the new coupling
    (full deflection → `peakToRedMultiplier`, not 1).
  - `testFlexLoopFlushesPeakVoxelToRedAtFullDeflection` — end-to-end: rest → blue,
    full deflection → the peak voxel is red.
  - `testPeakToRedMultiplierKeyedToYieldEqualsFailureMultiple` — proves flex red and
    push-to-failure red are the same point.
- `LoadPathTests`
  - `testLoadPathFlowAdvancesWrapsAndResets`, `testSelectingVariantResetsLoadPathFlow`
    — the flow phase advances only while on, wraps, and resets on toggle/select.
  - The existing GPU smoke tests (`testRendererDrawsLoadPathLines`, `…InsideTheSolid`)
    still pass, now exercising the ribbon pipeline.

### Verification run

`swift test` on `app/TopOptKit` (macOS, the M7 `/app/` standard). To build in the
worktree I symlinked the git-ignored core artifacts from the main worktree
(`vendor/TopOptCore.xcframework`) — removed afterward so `git status` is clean.

- `ResultsModelTests`: **71 passed, 0 failed**
- `LoadPathTests`: **20 passed, 0 failed**
- Full `TopOptFlowsTests`: **265 tests, 1 failure** — the sole failure is
  `RunModelTests.testRealMinimizePlasticRunReachesTerminalPhase` (the real
  minimize-plastic core run reports 0 SIMP iterations). **Pre-existing and
  environmental** — it fails identically on the untouched baseline (`git stash` →
  same failure) and lives in a file this task never touched. It reflects the
  symlinked/prebuilt core artifact on this host, not the app diff.

`swift build` is clean (only the repo's pre-existing Swift-6 concurrency warnings).

---

## Notes for the next agent
- The `RunModel` real-core test needs a freshly built `vendor/TopOptCore.xcframework`
  (via `app/scripts/build_core.sh`) to pass; the symlink-from-main shortcut is not
  enough for that one solver test.
- Perf posture unchanged from the existing device-QA note: `stressTints` /
  `peak()` are O(N) per frame while an overlay animates; `peakToRedMultiplier` is
  cached per selection, so the flex path adds no new per-frame voxel scan.
- ROADMAP box intentionally left unchecked.
