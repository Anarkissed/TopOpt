# 063 — Results screen: chip reorg + layout defect fixes (app-only, presentation)

**Track:** app — `/app/` only. No `/core/`, no fixtures, no ROADMAP. Presentation
only: no new physics, no optimizer, no data changes. Behavior of every tool is
unchanged — only *where* controls live and *how* they reveal.

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/gracious-wilson-21e9e5`
(branch `claude/results-chip-reorg-078336`).

**File touched:** `app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift` (only).
`ResultsModel.swift` and all tests are untouched — the model/behavior is the same.

---

## What changed (the four listed defects)

### 1. Variant cards no longer covered by the playbar
The `-32% / -48% / -62%` variant cards (`savingsTabs`, bottom-left) shared the
bottom band with the centered playbar (`mediaPlayer`) and overlapped on narrow
widths. `savingsTabs` now has an explicit `.padding(.bottom, 92)` (was a uniform
`xl4`) that lifts the cards clear above the playbar (which occupies ~76pt up from
the bottom). Cards sit above, slim playbar stays at the very bottom-center — no
vertical overlap. Horizontal paddings unchanged.

### 2. "See Original" no longer covered by a chip
Previously the top bar was **two independent overlays** — `topLeft` (back ·
project · See Original) growing rightward and `topRight` (Flex · Load path ·
Failure · Stress · Export) growing leftward — which collided in the middle ("Flex"
over "…inal").

Now there is a single `topBar` HStack: `back · project · See Original · Spacer ·
Export`. One flex row can't self-overlap: under width pressure the **project
capsule** is the only compressible element (its name `lineLimit(1)` truncates)
while the fixed-size buttons keep full width. The five competing chips are gone
from the top bar (moved to the rail, see #4), which is what freed the space.

### 3. Feature panels are now compact
The Deflection (flex), Failure, Load-path, and Stress-legend panels were large
floating cards (`padding(DS.Space.l)`, 180–200pt content, an 84pt top spacer each,
dropped over the model). They are now slim **drawers**: shared `resultsDrawerChrome()`
(tighter `.vertical m / .horizontal l` padding), a single `drawerWidth = 150`
content width, and `spacing: xs`. They no longer dominate the viewport.

### 4. Chip system reorganized (the core ask)
The secondary visualization toggles (**Stress, Flex, Load path, Failure**) now live
on a **right-edge vertical rail** (`vizRail`), below the top bar. One consistent
pattern for all four: a `vizChip` capsule (icon + label, accent-tinted when on) via
a `vizRow` that **slides the chip's own compact drawer open to the LEFT** when its
mode is active (`.move(edge: .trailing)` + opacity, animated with `DS.Motion.sheetIn`).
Tapping the chip toggles its mode and its drawer; the big over-the-model panels are
gone. The model viewport stays maximally unobstructed (drawers are 150pt-wide, on
the right).

Export was pulled out of the chip cluster and is now the lone right-hand item in
`topBar` (primary action).

**Mutual exclusion / "tapping another collapses the first":** flex / load-path /
failure are already mutually exclusive in `ResultsModel` (`toggleFlex/…` turn the
others off) — so opening one drawer collapses the others automatically, unchanged.
**Stress stays independently combinable** (a stress-coloured flex is a real
existing combination — `stressTints` + `flexDisplacements` render together), so the
Stress drawer can be open alongside one other. This preserves behavior exactly; I
did **not** force stress into the exclusion group, since that would change what the
tool does (out of scope).

---

## Structure map (new)

- `topBar` — back · project(Optimized ✓) · See Original · Spacer · Export. Single row.
- `vizRail` — top-right, `.padding(.top, 76)` to clear the bar; rows: Stress, then
  Flex/Load path/Failure gated on `hasFlex` / `hasLoadPath` / `hasFailurePrediction`
  exactly as before. Each row = `vizRow(open:drawer:chip:)`.
- Drawers: `stressDrawer` (ramp legend), `flexDrawer` (deflection slider),
  `loadPathDrawer` (key copy), `failureDrawer` (failure load + `pushControl`).
  All wrapped in `resultsDrawerChrome()`.
- `savingsTabs` — bottom-left, lifted (`.padding(.bottom, 92)`).
- `mediaPlayer` — bottom-center (unchanged).
- `orientationCorner` — bottom-right (unchanged).
- Hot-spot / failure markers — unchanged (they're positioned in 3D screen space).

Removed: `topLeft`, `topRight`, `stressLegendPanel`, `flexControlPanel`,
`loadPathLegendPanel`, `failureControlPanel` (their content was folded into the
drawers). Added: `topBar`, `vizRail`, `vizRow`, `vizChip`, per-mode `*Chip` +
`*Drawer` vars, `exportButton`, and a fileprivate `View.resultsDrawerChrome()`.

No public API changed: `ResultsScreen.init(...)` is byte-identical; call site in
`WorkspacePlaceholder.swift` untouched.

---

## Verification

**Build/test gate (per M7 `/app/` rules — headless view-model/layout logic via
`xcodebuild test`; pixels are maintainer device QA).**

Note: the git-ignored `vendor/` (built xcframework + symlinks, `app/.gitignore:11`)
is absent in a fresh worktree, so I symlinked it in from the main checkout to build:
`ln -s /Users/nadim/dev/TopOpt/TopOpt/app/TopOptKit/vendor app/TopOptKit/vendor`
(gitignored; not committed). The OCCT `occt-frameworks.generated.json` is absent →
OCCT-free macOS path, no manifest workaround needed. `Package.swift` stays clean.

### App package — `xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS' -only-testing:TopOptFlowsTests`
(benign `ld: warning … built for newer version 26.0` OCCT lines filtered)

```
Test Suite 'TopOptFlowsTests.xctest' started at 2026-07-12 19:51:27.107
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-12 19:51:40.823.
	 Executed 253 tests, with 0 failures (0 unexpected) in 13.629 (13.717) seconds
Test Suite 'All tests' passed at 2026-07-12 19:51:40.824.
	 Executed 253 tests, with 0 failures (0 unexpected) in 13.629 (13.717) seconds
** TEST SUCCEEDED **
```

### iOS simulator build (compiles the `#if canImport(UIKit)` path)
`xcodebuild build -project app/TopOpt.xcodeproj -scheme TopOpt -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
→ `** BUILD SUCCEEDED **`

No tests were added or changed: this is a pure view-layer relayout, and the layout
lives entirely in SwiftUI body code (no new headless-testable model logic). The
existing 253 `TopOptFlowsTests` (which compile `ResultsScreen.swift`) all pass.

---

## Notes for next run / QA to confirm on device

- **Device QA is the visual gate.** Please eyeball on the target device(s):
  1. Top bar: `See Original` and `Export` never touch; long project names truncate
     with `…` inside the capsule rather than pushing buttons off-screen.
  2. Right rail: tap each of Stress/Flex/Load path/Failure — drawer slides out to
     the left, compact, model still visible; switching flex↔load path↔failure
     collapses the previous; Stress may coexist with one (intended).
  3. Bottom: variant cards sit above the playbar with a clear gap; the tall
     "active" card and streaming pill don't reach the playbar.
- **Tunables if QA wants nudges:** rail top inset `76` (vizRail `.padding(.top,)`),
  card lift `92` (savingsTabs `.padding(.bottom,)`), `drawerWidth = 150`.
- The rail fills the screen height with a bottom `Spacer()` (like the old overlays)
  — empty space is not hit-testable, so the model and bottom controls stay
  interactive. Z-order: bottom controls + markers are layered above `vizRail`.
- Behavior is untouched — if any tool *does* something different, that's a
  regression to flag, not intended.
