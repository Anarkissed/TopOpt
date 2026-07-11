# Handoff 051 — playback video export (Save video)

## Task (maintainer-directed, interactive)
Export the optimization-history playback as a video ("download it"), and add a
download icon to the far right of the results timeline. Completes the playback
feature (history playback landed in handoff 050). Not a ROADMAP task — no box.

## What I did (all `/app/`; no core change → no xcframework rebuild, V-gates stand)
- **`VideoExporter`** (`PlaybackVideo.swift`, new): renders the variant's keyframe
  meshes (solid → carved-out) offscreen through the SAME Metal `MeshRenderer` the
  viewer uses (`renderOffscreen` → BGRA), holds each frame `framesPerKeyframe`
  ticks, and encodes an H.264 `.mp4` via `AVAssetWriter` +
  `AVAssetWriterInputPixelBufferAdaptor`. The camera is FIXED to the first
  non-empty keyframe so the part doesn't jump/zoom as material is removed; empty
  early frames render as the dark stage (material "appears"). Blocking; run off-main.
- **`VideoExportModel`** (new): the download flow's state machine
  (idle → exporting → ready(url) / failed) with injected encode + dispatch seams so
  the orchestration is unit-tested without Metal/AVFoundation. Names the file after
  the (sanitized) project.
- **`ResultsScreen`**: a **download icon at the far right of the timeline** (after
  the time label) — a spinner while encoding, disabled when the variant has no
  history. On success a `ShareSheet` (`UIActivityViewController`) presents the
  `.mp4`; on failure a design alert. `ShareSheet` is `#if canImport(UIKit)` (iOS)
  with a macOS text fallback.

## Test evidence (raw, pasted, unedited) — full macOS package suite
```
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-11 00:15:42.640.
	 Executed 176 tests, with 0 failures (0 unexpected) in 13.277 (13.388) seconds
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-11 00:16:07.921.
	 Executed 21 tests, with 0 failures (0 unexpected) in 24.761 (24.768) seconds
** TEST SUCCEEDED **
```
(214 = 17 design + 176 flows [+4 video] + 21 kit.) Both iOS slices build. Core
`ctest` NOT re-run (no `/core/` change; 26/26 stands from handoff 050).

New tests (`PlaybackVideoTests`):
- `testExporterProducesAValidMP4`: three tiny keyframes → a real `.mp4` that exists,
  is non-empty, and loads as an AVAsset with a video track + non-zero duration.
  (The offscreen render + H.264 encode both run headlessly on macOS, so this is a
  genuine end-to-end check, not a stub.)
- `testExporterRejectsEmptyKeyframes`; `testExportModelSucceeds` (state → ready,
  name sanitized); `testExportModelSurfacesFailures` (encode throw + no-frames →
  failed, no encode attempted).

## What I did NOT do
- **Did NOT verify the share sheet / the video's on-screen look on device** — the
  UIActivityViewController presentation, the button feel, and how the recording
  actually reads are maintainer device QA (M7 standard).
- **No audio, no title/end card, no per-frame easing** — a straight keyframe
  sequence at a fixed camera. Fine for a first "watch it optimize" clip.
- **Export size/length are fixed** (640², 30 fps, 6 frames/keyframe ≈ a few
  seconds). Not user-configurable.

## Warnings for the next run (and device QA)
- **The export re-renders every keyframe offscreen at 640²** — for 12 frames that's
  quick, but it spins up a second `MeshRenderer`; watch memory/time on device at
  Fine (128³ keyframes are larger meshes).
- **`MTLCreateSystemDefaultDevice()` must be non-nil** — true on device + the
  maintainer's Mac (the offscreen tests already rely on Metal); a GPU-less CI would
  fail the mp4 test.
- **`DECISIONS.md`** still carries the maintainer's uncommitted 2026-07-11
  print-time entry (not part of my commit), as in handoffs 045–050.

## Blocked
None.
