# 075 — STEP import on the iOS Simulator (OCCT simulator slice)

**Status:** DONE. STEP import runs on an `iphonesimulator` destination and returns a
real tessellated B-rep (l-bracket.step → **236 triangles**, watertight). The simulator
core slice is built **WITH OCCT**, the OCCT frameworks carry a valid `ios-arm64-simulator`
slice, and a headless `xcodebuild test` on the simulator proves the exact `import_step`
call that used to throw now succeeds. macOS + device slices unaffected.

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/animations-stress-coupling-redo-a8d83b`
**Branch:** `claude/step-import-ios-simulator-9a914e`

---

## STEP 1 — Root cause (which of the two cases)

**Neither of the two cases the task anticipated — the more favorable third case.**
The task expected either (a) the 47 OCCT xcframeworks lack an `ios-arm64-simulator` slice
entirely, or (b) they have one but the sim core build skips them.

Reality: **the OCCT-for-iOS cross-build source already produces a complete, valid
`ios-arm64-simulator` slice, and the build scripts have always built both slices.**

- `app/scripts/build_occt_ios.sh` has built `SLICES=("iphoneos" "iphonesimulator")`
  since its first commit (`7c12bba`). The simulator slice was always intended.
- The simulator OCCT cross-build **had already succeeded** on this machine. In
  `app/.build-occt-ios/` (git-ignored, per-machine):
  - `install/occt-iphonesimulator/` — 141 dylibs, 98 MB, **toolkit list identical to
    device**, includes `TKDESTEP` (the STEP importer) + `OpenCASCADEConfig.cmake`.
  - `frameworks/iphonesimulator/` — **47 wrapped frameworks, set identical to device**.
  - `vtool -show-build` on the sim binaries reports `platform IOSSIMULATOR`, arch
    `arm64`, `minos 16.0` — genuine simulator binaries, not device ones re-labeled.

**Why handoff 075's precursor saw "sim OCCT-free":** `build_core.sh` prints "OCCT-free"
for a slice exactly when `.build-occt-ios/install/occt-<sdk>/` is absent.
`build_occt_ios.sh` builds device *first* under `set -e`, so a **failed simulator OCCT
compile** leaves the device tree present and the sim tree absent — precisely the
"device WITH OCCT / sim OCCT-free" asymmetry that was reported. That compile has since
been resolved; the sim OCCT now installs cleanly (toolchain resolves the sim SDK via
`xcrun --sdk iphonesimulator`, so it is reproducible).

**Homebrew note (task 1b):** Homebrew OCCT (`/opt/homebrew/opt/opencascade`) is
macOS-only and cannot yield simulator binaries — correct, and it is *not* the iOS source.
The iOS slices are cross-built from OCCT github source by `build_occt_ios.sh`, which
**does** emit an `arm64-simulator` slice. So the feared bulk of the task — building OCCT
for `arm64-simulator` — **was already done** and did not need redoing.

**What actually remained** (packaging + linkage + proof, not physics, not app logic):
1. Package the existing sim+device frameworks into `vendor/occt-ios/*.xcframework` and
   write the git-ignored `occt-frameworks.generated.json` (both were unbuilt — a fresh
   worktree ships neither).
2. Run `build_core.sh` → `TopOptCore.xcframework` whose **simulator slice is WITH OCCT**.
   (**No change to `build_core.sh` was needed** — it already builds the sim slice with
   OCCT symmetrically once the install tree exists; see STEP 3a output.)
3. Link the OCCT frameworks into the **package test targets** on iOS. This was the one
   real wiring gap: the package's test bundles never linked the `TopOptOCCT` product
   (only the app does), so STEP-on-sim failed at **link time** with undefined OCCT
   symbols even though the core slice had STEP compiled in.

---

## What changed (two source files, +30 lines; no /core/, no app view code)

```
app/TopOptKit/Package.swift                             | 17 ++++++++++++++--
app/TopOptKit/Tests/TopOptKitTests/TopOptKitTests.swift | 15 +++++++++++++
```

`git diff --stat -- core/` is **empty**. No physics, no bridge logic, no app screens.

### 1. `Package.swift` — link OCCT into the iOS test bundles (build config only)

The core slice on iOS pulls in OCCT symbols (STEP import). On macOS those are satisfied by
`TopOptKit`'s Homebrew `-L/-l` flags (`.when(platforms: [.macOS])`); on iOS by the
cross-built OCCT frameworks, which the **app** links via the `TopOptOCCT` product. A
package unit-test bundle does not link that product, so the two test targets that
transitively link the core (`TopOptKitTests`, and `TopOptFlowsTests` via
`TopOptFlows → TopOptKit`) now depend on the iOS OCCT binary targets, **iOS-gated**:

```swift
dependencies: ["TopOptKit"]
    + iosBinaryNames.map { .target(name: $0, condition: .when(platforms: [.iOS])) },
```

`iosBinaryNames` is empty on macOS / OCCT-free checkouts (the M7.1c disk-gate), so macOS
build/tests and CI are **unaffected**. This mirrors the app's link+embed path for the
simulator exactly — Xcode links + embeds the 47 OCCT frameworks into the `.xctest` bundle,
which is why STEP import both **links** and **runs** on the sim.

### 2. `TopOptKitTests.swift` — explicit simulator proof test

`testStepImportProducesMeshOnThisPlatform()` calls the real `import_step` on
`core/tests/fixtures/demo/l-bracket.step` and logs the triangle count so the raw test
output carries the proof number. This is the exact call that threw
"STEP import requires OpenCASCADE, which is not available on this platform" when the sim
slice was OCCT-free.

### Regenerated, git-ignored (never committed) — produced by the scripts

- `app/TopOptKit/vendor/occt-ios/*.xcframework` — 47, each with **both** `ios-arm64` and
  `ios-arm64-simulator` slices.
- `app/TopOptKit/vendor/TopOptCore.xcframework` — macos-arm64 + ios-arm64 +
  ios-arm64-simulator, all three **WITH OCCT**.
- `app/TopOptKit/occt-frameworks.generated.json` — 47 OCCT names (disk-gated).

---

## STEP 3a — raw `build_core.sh` output (sim slice now WITH OCCT)

```
==> OCCT:  /opt/homebrew/opt/opencascade
==> Eigen: /opt/homebrew/opt/eigen
==> building macOS slice (Eigen + OCCT, arm64)
==> building iOS simulator slice (Eigen + OCCT, arm64)
==> building iOS device slice (Eigen + OCCT, arm64)
==> created .../vendor/TopOptCore.xcframework
==> vendored:
    .../vendor/TopOptCore.xcframework (macos-arm64, ios-arm64-simulator, ios-arm64)
    .../vendor/occt-ios  (47 OCCT xcframeworks, iOS device+sim — linked+embedded on iOS)
    iOS slices built WITH OCCT: STEP import is available on iPad/simulator.
```

The simulator line reads **"Eigen + OCCT, arm64"** — no "OCCT-free". Verified the symbol
is really in the binary (not just the label):

```
$ nm TopOptCore.xcframework/ios-arm64-simulator/libtopopt.a | grep -c import_step_file   → 2
$ nm TopOptCore.xcframework/ios-arm64-simulator/libtopopt.a | grep -c STEPControl_Reader  → 2
```

---

## STEP 3b — raw STEP-import-on-SIMULATOR proof (triangle count > 0)

Command:

```
cd app/TopOptKit
xcodebuild test -scheme TopOptKit-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TopOptKitTests/TopOptKitTests/testStepImportProducesMeshOnThisPlatform
```

Raw output:

```
Test Case '-[TopOptKitTests.TopOptKitTests testStepImportProducesMeshOnThisPlatform]' started.
STEP-IMPORT-PROOF l-bracket.step triangleCount=236 vertexCount=116 faceCount=10 watertight=true
Test Case '-[TopOptKitTests.TopOptKitTests testStepImportProducesMeshOnThisPlatform]' passed (0.048 seconds).
** TEST SUCCEEDED **
```

Full simulator suite (all OCCT paths: import, face tagging/masking, load-case optimize):

```
Test Suite 'TopOptKitTests' passed
	 Executed 23 tests, with 0 failures (0 unexpected) in 26.612 seconds
** TEST SUCCEEDED **
```

Before the linkage fix, the same command failed at **link** time with ~40 undefined OCCT
symbols (`STEPControl_Reader::ReadFile`, `BRepMesh_IncrementalMesh`, `TopExp_Explorer`,
…), confirming the sim core slice had STEP compiled in but nothing linked the frameworks.

---

## STEP 3c — existing suite still green; macOS + device unaffected

- **macOS** (`swift test --filter TopOptKitTests`): **21 tests pass**, incl. all STEP
  tests via Homebrew OCCT + the new proof test. Green.
- **Device slice**: `xcodebuild build -scheme TopOptOCCT -destination 'generic/platform=iOS'`
  → **BUILD SUCCEEDED**; the `ios-arm64` OCCT slice + device core slice link intact.
  (No physical-device run — no hardware — but the device slice is byte-for-byte unchanged
  from the prior device-with-OCCT build; only packaging/test-linkage changed.)
- **Simulator TopOptOCCT**: BUILD SUCCEEDED.

### macOS caveat (pre-existing, not introduced here)

`xcodebuild test -scheme TopOptKit-Package -destination platform=macOS` **fails** while
building the `TopOptOCCT` target: its product line is
`["TopOptOCCTShim"] + iosBinaryNames`, so once OCCT is vendored it lists 47 **iOS-only**
xcframeworks, and building that target for macOS errors with "no library for this platform".
This is a property of the existing disk-gated design (unchanged by this task — that line
was not touched) and only bites a dev machine that has *built* the iOS OCCT; a fresh
checkout / CI has no `vendor/occt-ios`, gates to empty, and stays green. The package's
macOS tests are therefore run with **`swift test`** (which builds only the test closure,
excluding the iOS-only `TopOptOCCT` target) — that is the green run reported above.

---

## STEP 4 — binary toll (honest)

The core slice itself barely grows — OCCT is dynamically linked, so the weight is the
**embedded OCCT frameworks**, not the static core lib:

| Artifact | Size |
|---|---|
| `TopOptCore` ios-arm64-simulator slice (static lib, WITH OCCT) | **872 KB** (vs 836 KB device; ~a few KB over OCCT-free) |
| Embedded OCCT frameworks, **simulator** (47 dylibs) | **~54.6 MiB** |
| Embedded OCCT frameworks, device (47 dylibs, for reference) | ~55.8 MiB |
| `vendor/occt-ios` on disk (both slices) | 111 MB |

So a **Simulator** build of the app grows by **~55 MiB** of embedded OCCT dylibs
(Release, unstripped). Largest contributors: `TKDESTEP` 6.7 MiB, `TKGeomBase` 4.2,
`TKGeomAlgo` 3.9, `TKBool` 3.5, `TKDEIGES` 3.4. This is comparable to the device toll
that already ships, so it is not a new order-of-magnitude cost — it just now also applies
to Simulator builds. Simulator size is a dev-only concern (never shipped); the device App
Store download is thinned/compressed below the raw dylib total.

**Simulator-only caveats:** none functional — STEP import, tessellation, face
tagging/masking, and load-case optimize all run identically to device on the sim. The only
sim-specific note is the macOS-scheme caveat above (unrelated to running *on* the sim).

---

## Reproduce

```
# once, if the OCCT install trees are absent (multi-hour cross-compile):
./app/scripts/build_occt_ios.sh          # builds BOTH ios slices (device + simulator)
# every core rebuild:
./app/scripts/build_core.sh              # sim slice built WITH OCCT (see STEP 3a)
cd app/TopOptKit && xcodebuild test -scheme TopOptKit-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TopOptKitTests/TopOptKitTests/testStepImportProducesMeshOnThisPlatform
```

**Provenance / honesty:** the OCCT simulator+device install trees and wrapped frameworks
were **already present and valid** on this machine (a prior successful `build_occt_ios.sh`
run); I did **not** re-run the multi-hour OCCT cross-compile. I reused those valid
artifacts (via a per-worktree `app/.build-occt-ios` symlink into the main checkout),
packaged the vendored xcframeworks + JSON from them, and ran `build_core.sh` normally —
its raw output (STEP 3a) is from that normal run. Nothing about STEP import was faked or
stubbed; the proof is a real `STEPControl_Reader` parse on the booted simulator.

## Not done / notes
- ROADMAP box **not** checked (per instructions).
- No physical-device run (no hardware); device slice verified by build + unchanged binary.
- The pre-existing macOS `-Package`-scheme caveat (above) is worth a future cleanup —
  e.g. give `TopOptOCCT` a tiny macOS-empty slice or platform-gate the product — but it is
  out of scope here and does not affect iOS device/simulator or CI.
