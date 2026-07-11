# Handoff 053 — persist optimize results across launches (persist-c)

## Task (maintainer-directed, interactive)
Make the optimize variations survive an app relaunch ("if I close the app and
re-open, the variations will still be there"). Maintainer chose **full fidelity —
everything incl. playback** (variant meshes + stress + orientation + the
optimization-history keyframes). Not a ROADMAP task — no box.

## The gap this closes
Before this, `ProjectSnapshot` persisted only the SETUP (model file, anchors/loads,
material, gravity, minimize-plastic, quality) + the `optimized` flag. The actual
`OptimizeOutcome` (variant meshes, stress fields, keyframes) was never serialized —
`restoreFromDisk` rebuilt the project with a fresh idle run. So an "Optimized" card
reopened to the ORIGINAL part and forced a re-run. (The `optimized` chip from
handoff 052 was therefore over-promising across launches — this fixes that.)

## What I did (all `/app/`; no core change → no xcframework rebuild, V-gates stand)
- **`OutcomeStore.swift` (new) — `OutcomeCodec`**: converts `OptimizeOutcome`
  ⇄ Codable DTOs where the heavy `[Float]`/`[Int32]` arrays (variant mesh, von
  Mises field, every keyframe mesh) are packed as raw little-endian `Data` blobs,
  encoded as a **binary property list** (stores `Data` natively — no base64
  bloat). Near-minimal on-disk size; array↔Data is memcpy (alignment-safe via
  `copyBytes`). DTOs are `Sendable` so encode/decode cross to a background queue.
- **`ProjectStore`**: `resultsURL(id:)` (`results.plist` in the project folder) +
  `saveResults(_:id:)` / `loadResultsData(id:)`.
- **`RunModel.restoreOutcome(_:)`**: drops a persisted outcome into an **idle** run
  (guarded: no-op if a run is active or results already loaded). No side effects —
  phase stays `.idle`, no notifier; a later Optimize resets + re-runs normally.
- **`AppModel`**: on `persist(...)` when `hasResults`, builds the DTO on main (fast)
  then **encodes + writes off-main** on a serial `resultsQueue`. In
  `restoreFromDisk`, if the snapshot was `optimized`, **loads + decodes off-main**
  and calls `restoreOutcome` on main — results reopen without blocking the UI.
- **Latent-bug fix in `ProjectModel`**: the workspace observes the ProjectModel, not
  the nested `RunModel`, so `run.outcome` changes (streaming results AND the new
  restore) previously only re-rendered incidentally (on a camera/projection tick).
  ProjectModel now forwards the run's `$outcome` + `$phase` (NOT per-iteration
  `$progress`, to avoid re-uploading the mesh every tick) to its own
  `objectWillChange`, so results appear deterministically.

## Test evidence (raw, pasted, unedited) — full macOS package suite
```
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-11 01:41:02.217.
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-11 01:41:23.563.
** TEST SUCCEEDED **
```
(223 = 17 design + 185 flows [+3 new: OutcomeStoreTests] + 21 kit.) Both iOS slices
build (`iphonesimulator` + `iphoneos`). Core `ctest` NOT re-run (no `/core/`
change; 26/26 stands from handoff 050).

New tests (`OutcomeStoreTests`):
- `testOutcomeRoundTripsThroughEncodeDecode`: a 2-variant outcome (accepted rung
  with mesh + stress + 2 keyframes, and an empty/rejected rung) survives
  encode → binary plist → decode with every scalar, SIMD, and array byte-exact.
- `testStoreSavesAndLoadsResultsBlob`: `ProjectStore` writes + reads the blob and it
  re-decodes.
- `testRestoreOutcomeSetsOutcomeOnIdleRunOnce`: sets outcome on an idle run, leaves
  phase `.idle`, and the second call is a no-op.

## What I did NOT do
- **Did NOT verify on device** — the reopen-shows-results flow, timing of the async
  load, and disk footprint at Fine (128³) are maintainer device QA.
- **No compression** — arrays are stored raw. At Fine 128³ with full playback, a
  project's `results.plist` can be sizable (many MB; the keyframes dominate). If
  that's a problem on device, the drop-in options are `Compression`-framework
  (Apple, no 3rd-party dep) around the blob, or persisting fewer/no keyframes.
- **No migration / cleanup** — a re-optimize overwrites `results.plist` atomically;
  a stale file from a deleted project goes with its folder. There's no cap on total
  results storage.
- **Restore is best-effort** — a decode failure (corrupt/old file) degrades to "no
  results" (card still reads Optimized, opening shows the original). No user-facing
  error.

## Warnings for the next run (and device QA)
- **The snapshot (sync) and results.plist (async) are written in the same
  `persist`** — if the app is killed in the ~ms between, the card can say
  "Optimized" with no results file yet; reopen then shows the original. Rare;
  acceptable. Tightening would mean writing results synchronously (janky) or a
  two-phase flag.
- **`ProjectModel` now re-renders the workspace on every outcome/phase change** —
  intended (fixes streaming + restore). Progress ticks are deliberately excluded so
  the Metal mesh isn't re-uploaded each iteration. If a future change routes results
  through `progress`, revisit.
- **Endianness**: raw `Data` packing assumes little-endian (ARM64 + x86 both are).
  Fine for iPad/Mac; don't reuse the blob format cross-platform without a guard.
- **`DECISIONS.md`** still carries the maintainer's uncommitted 2026-07-11
  print-time entry (not part of my commits), as in handoffs 045–052.

## Blocked
None.
