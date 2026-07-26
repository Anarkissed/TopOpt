# SwiftPM packaging — macOS builds must survive vendored iOS OCCT

**Date:** 2026-07-26
**Branch:** `claude/swiftpm-macos-ios-occt-0c60c5`
**Change (2 files):** `app/TopOptKit/Package.swift`, `app/scripts/build_core.sh`
**Evidence:** `evidence/2026-07-26-spm-macos-ios-split/`

## TL;DR

`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'` on a
checkout **with `vendor/occt-ios` populated** failed with 47×
`While building for macOS, no library for this platform was found` and never
reached the tests. Root cause: the `TopOptOCCT` **product** listed the 47
iOS-only OCCT xcframework binary targets, and **SwiftPM products cannot carry a
platform condition**, so a macOS build of that product tried to build each
iOS-only framework for macOS.

**Fix:** the product now lists only the OCCT-free `TopOptOCCTShim`. The iOS binary
frameworks reach the app through the **shim's iOS-gated target dependencies**
(`.when(platforms: [.iOS])`) — a condition that *targets* (unlike products) can
carry. On macOS the product's dependency closure is just the shim; on iOS the 47
frameworks are in the closure and Xcode links + embeds them exactly as before.

All five bars pass. The **iOS embedding was proven, not asserted**: the built
`.app/Frameworks` on an iOS-simulator destination contains all 47 OCCT
frameworks (identical set before and after the fix), and STEP import actually
runs on the simulator.

## Root cause

`Package.swift` builds the iOS OCCT framework list dynamically from disk
(`occt-frameworks.generated.json` gated on `vendor/occt-ios/<name>.xcframework`
existing). Dependencies were correctly iOS-gated at the **target** level
(test targets, lines 151/176). But the **product** was:

```swift
.library(name: "TopOptOCCT", targets: ["TopOptOCCTShim"] + iosBinaryNames)
```

A SwiftPM `.library(...)` product takes no `condition:`. The `TopOptKit-Package`
scheme (which PR #186 tells the maintainer to use) builds **all** products, so on
a macOS destination it tried to build all 47 iOS-only xcframeworks for macOS →
47 errors, before any test ran. Reproduced verbatim:
`evidence/…/P0-repro-BEFORE-package-macos.log` (47 errors, target `TopOptOCCT`).

## The fix

`Package.swift`:

- **`TopOptOCCTShim` target** now depends on the binary frameworks, iOS-gated:
  ```swift
  .target(name: "TopOptOCCTShim",
          dependencies: iosBinaryNames.map {
              .target(name: $0, condition: .when(platforms: [.iOS]))
          })
  ```
- **`TopOptOCCT` product** now lists only the shim:
  ```swift
  .library(name: "TopOptOCCT", targets: ["TopOptOCCTShim"])
  ```

This is the identical iOS-gating pattern the two test targets already used
(lines 151/176) — those have compiled clean on macOS all along, which is why the
narrower `-scheme TopOptKit` used to "work." We simply applied the proven pattern
to the shim so the whole-package scheme is macOS-safe too.

**Why embedding survives:** Xcode embeds the binary (dynamic-framework)
xcframeworks in an app's `.app/Frameworks` when they are in the linked product's
**dependency closure**. Direct product membership and a transitive target
dependency both put them in that closure. On iOS the shim pulls all 47 in; the
app links `TopOptOCCT`, so they embed. Proven below (P3).

`build_core.sh`: the printed test command was `-scheme TopOptKit`, which has **no
test action** (`Scheme TopOptKit is not currently configured for the test
action.`). PR #186 (on `main`, not yet on this branch) already switched the
printed command to `-scheme TopOptKit-Package` — but PR #186 did **not** fix the
product, so on `main` that recommended command *fails* with the 47 errors. This
branch now prints the `-Package` command too, and the Package.swift fix makes it
actually work in both vendor configurations.

## Bars

Note on the reproduction environment: this branch (`ecb1b2e`) is a strict
ancestor of `main`. The heavy artifacts (`vendor/TopOptCore.xcframework`, the 47
real `vendor/occt-ios/*.xcframework`, `occt-frameworks.generated.json`) were
mirrored from the populated `main` checkout via symlink; the core sources between
this branch and `main` differ only in active-domain/production files that do not
touch the STL/STEP importer, so the vendored core produces identical import
results. All builds used arm64-only for iOS because the OCCT-linked simulator
slice is arm64-only (as `build_core.sh` documents).

### P1 — macOS tests build+run with `vendor/occt-ios` POPULATED ✅

`evidence/…/P1-AFTER-fix-package-macos-POPULATED.log` — **0**
`no library for this platform` errors (was 47). Tests build, launch, and run:
`TopOptDesignTests` pass, `TopOptKitTests` pass (30 tests incl. STEP import on
macOS). One failure, `TopOptFlowsTests/PaintModeUITests/testShelfBracketBackFacePaintedAnchorMatchesTap`
— **pre-existing and unrelated** (see caveat).

Clean confirmation excluding only that one pre-existing test:
`evidence/…/P1-CLEAN-populated-skip-preexisting-paint.log` — all three bundles
pass, `** TEST SUCCEEDED **`. My change breaks nothing else.

### P2 — macOS tests build+run with `vendor/occt-ios` ABSENT (committed default) ✅

`evidence/…/P2-AFTER-fix-package-macos-ABSENT.log` — **0**
`does not contain a binary artifact` and **0** `no library for this platform`
errors; manifest gates the framework list to empty. `TopOptDesignTests` and
`TopOptKitTests` pass; same single pre-existing paint-test failure only.

(Setup note: transitioning populated→absent required clearing SwiftPM's manifest
cache, which is keyed on `Package.swift` contents — documented in the manifest
header. A genuine fresh checkout has no such stale cache; the run used a cleared
cache + fresh DerivedData to mirror it.)

### P3 — iOS embedding still works ✅ (proven, not asserted)

Built the app for an iOS-simulator destination with the fixed manifest
(`evidence/…/P3-AFTER-fix-ios-app-build.log`, `** BUILD SUCCEEDED **`) and listed
the bundle's `Frameworks/`:

- `evidence/…/P3-AFTER-fix-app-frameworks.txt` — **47** OCCT (`TK*`) frameworks
  embedded, including `TKDESTEP.framework` (the STEP importer).
- `TKDESTEP/TKDESTEP` is a real `Mach-O 64-bit … arm64` dynamic library.
- **Identical** to the pre-fix baseline (`P3-BASELINE-before-fix-app-frameworks.txt`,
  captured against the unmodified manifest) — `diff` shows no difference.

### P4 — STEP import functions on an iOS destination ✅

`evidence/…/P4-AFTER-fix-step-import-ios.log` — ran the STEP tests on the iPad
simulator (arm64). `** TEST SUCCEEDED **`, and the proof line:

```
STEP-IMPORT-PROOF l-bracket.step triangleCount=236 vertexCount=116 faceCount=10 watertight=true
```

`testImportStepFaces`, `testStepImportProducesMeshOnThisPlatform`, and
`testTagStepFace` all pass — the embedded OCCT frameworks link *and* execute a
real B-rep tessellation on-simulator.

### P5 — build_core.sh's printed command matches what works in BOTH configs ✅

`build_core.sh` now prints
`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`, the
exact command exercised by P1 (populated) and P2 (absent). The old
`-scheme TopOptKit` was verified to error with "not currently configured for the
test action," so it never worked for `test` at all.

## Caveat — the one macOS test failure is pre-existing and independent

`TopOptFlowsTests/PaintModeUITests/testShelfBracketBackFacePaintedAnchorMatchesTap`
fails in the raw P1/P2 runs. It is **not** caused by this change:

- My change only edits the `TopOptOCCT` product and `TopOptOCCTShim`, and every
  affected dependency is `.when(platforms: [.iOS])` — inert on a macOS build. The
  `TopOptFlowsTests` bundle compiles and runs identically with or without it.
- The failure is at `PaintModeUITests.swift:144`,
  `XCTAssertFalse(backTris.isEmpty)`: this branch's version of the test finds the
  wall face with a brittle hardcoded `y == 0` vertex filter that resolves to zero
  triangles on the fixture.
- **PR #186 ("paintmode-wall-face-selection"), already merged on `main`, rewrote
  this exact test** (+68/−8) to select the wall face via mesh segmentation
  (`wallFaceTriangles(in:)`) instead of the hardcoded coordinate. This branch
  predates PR #186.
- Proof: overlaying `main`'s version of *only that test file* and rerunning it
  against the same core → all 6 `PaintModeUITests` pass, including
  `testShelfBracketBackFacePaintedAnchorMatchesTap`
  (`evidence/…/DIAG-paint-test-passes-with-PR186-fix.log`). The overlay was then
  reverted; this PR carries no test change.

When this branch is brought up to date with `main`, the `-Package` macOS run is
fully green.

## Not blocked

The macOS-safe and iOS-embedding-correct requirements are **both** satisfiable
within SwiftPM's product model — no documented workaround (parking
`vendor/occt-ios`) is needed. The BLOCKED-STOP path does not apply.

## Files

- `evidence/…/CHANGE-package-and-buildscript.diff` — the full diff.
- `P0-repro-BEFORE-package-macos.log` — the 47-error reproduction.
- `P1-AFTER-…` / `P1-CLEAN-…` / `P2-AFTER-…` — macOS `-Package` runs.
- `P3-BASELINE-…` / `P3-AFTER-…` — iOS `.app/Frameworks` listings + build log.
- `P4-AFTER-…` — STEP-import-on-simulator.
- `DIAG-paint-test-passes-with-PR186-fix.log` — pre-existing-failure proof.
