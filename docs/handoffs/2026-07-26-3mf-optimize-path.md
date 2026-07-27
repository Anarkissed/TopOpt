# A 3MF that imports must also optimize

**Date:** 2026-07-26
**Branch:** `claude/3mf-optimize-lib3mf-2e0c29`
**Evidence:** `evidence/2026-07-26-3mf-optimize-path/`

## TL;DR

The maintainer imported a `.3mf` on the iPad (it showed), pressed **Optimize**,
and got:

```
topopt-cli: cannot import model "model.3mf": 3MF import requires lib3mf, which
is not available in this build; export the part as STL and import that instead
```

**Which binary?** The **Mac worker's `topopt-cli`**, built from a `core/build`
that was configured **without lib3mf** — candidate (b). The `topopt-cli:` prefix
is emitted *only* by the CLI binary's `main.cpp`; the on-device bridge sets
`err.message = e.what()` with no prefix and never routes through `run_job`'s
`cannot import model "…"` wrapping. Reproduced **bit-for-bit** with a lib3mf-less
`topopt-cli` (`evidence/DIAGNOSIS_reproduction.txt`).

**Fix chosen: option (ii)** — stop requiring lib3mf twice. The app now normalises a
3MF import to an **STL working copy** at import time; the optimize path (on-device
bridge *and* the LAN worker) reads that STL, so it **never re-parses 3MF**. lib3mf is
needed in exactly **one** place — the initial import — where a build lacking it
already refuses **at file-pick** (M3, by construction). Provenance is preserved: the
original name/format survive, and the worker's `run_info` records the true
`source_format: "3mf"` even though it imported an STL.

We *also* keep the worker honest (M5): `build_cli_macos.sh` now clears a stale
`core/build` cache automatically, and the gotcha is documented — so a raw `.3mf`
handed straight to the CLI works too.

Every bar is met with raw evidence, including a **real optimization on both
targets**.

## Why option (ii), not (i)

The maintainer already parsed this 3MF successfully. Making the optimizer re-parse
it means 3MF support must live in **two** binaries (the iOS slice *and* the worker's
separate cmake build) and stay in sync forever — and the failure mode is exactly
what was hit: the worker's `lib3mf_FOUND` is a **configure-time cached** decision, so
a `core/build` first configured without lib3mf keeps `lib3mf_DIR-NOTFOUND` and
silently drops 3MF even after lib3mf is provisioned.

- **(i) put lib3mf in both binaries** keeps that fragility, and can still fail
  **late**: if the import binary has lib3mf but the optimize binary doesn't, the user
  finds out only after setting up anchors/loads/box and pressing Optimize. M3 (“refuse
  at import”) would then need a separate worker-capability preflight — more surface,
  same class of bug.
- **(ii) normalise 3MF → STL at import** deletes the whole class: the optimize path is
  format-agnostic, lib3mf is consumed once (at import, early), and the reported failure
  is structurally impossible. The one cost — provenance — is paid explicitly (below).

Correctness is not hand-waved: a 3MF and its STL twin voxelise identically, so they
optimize to a **byte-identical** result (`evidence/M2_and_deeper_fix.txt`; also the
core `threemf_import` test). Normalising loses nothing.

## What changed

**Core (provenance plumbing, testable via the CLI):**
- `core/include/topopt/job.hpp` — optional `source_format` job key.
- `core/src/cli/job.cpp` — parse/allow it (empty ⇒ derive from the model extension).
- `core/include/topopt/part.hpp`, `core/src/io/part.cpp` — `format_name(PartFormat)`.
- `core/src/cli/run_job.cpp` — `run_info.source_format = job.source_format` else the
  model's extension.
- `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` —
  `RunInfo.source_format` + serialize it.

**App (the deeper fix):**
- `AppModel.resolveUnits` — a 3MF import always writes an STL working copy (even in
  mm; a non-mm import already did). The display name keeps `.3mf`.
- `FlowModels.ImportedFile.sourceFormat` — derived from name-vs-path extension
  divergence (`.3mf` name + `.stl` path ⇒ `"3mf"`).
- `RunModel.RunRequest.sourceFormat` + `AppModel.makeRunRequest` threads it.
- `RemoteRunner.buildJobJSON` — emits `source_format` only when non-empty (a plain
  STL/STEP job.json is byte-identical to before — M2).
- `ProjectModel.snapshot` — the stored model's extension follows the working file's
  **content** (`.stl`), not the display name, so a reopened 3MF project re-imports the
  STL working copy (and no longer mis-dispatches — a latent bug this also fixes).

**Worker build (M5):**
- `app/scripts/build_cli_macos.sh` — clears a stale `core/build` cache that doesn't
  point at the provisioned lib3mf, and passes `-Dlib3mf_DIR` explicitly.
- `tools/topopt-worker/README.md` — documents the stale-cache gotcha and the fix.

## Bars

- **M1 — end to end on BOTH targets, real optimization.**
  - **iPad (on-device):** `AppModelTests.testThreeMFImportOptimisesOnDeviceEndToEnd`
    imports `plate_bore.3mf` through the **real bridge**, normalises to STL, and runs
    the **actual on-device optimizer** (`run_minimize_plastic`, the iPad's Optimize
    button) to accepted variants — **passed in 178.9 s** (a real res-32 solve).
    `evidence/app_ondevice_optimize_3mf.txt`.
  - **Mac worker:** the **live HTTP worker** (`topopt_worker.py` → lib3mf `topopt-cli`)
    ran a multipart `.3mf` job to `state: done, variants: 2`; the result zip carries
    `report.json`, two variant meshes, and `run_info.json` with
    `source_format: "3mf"`. `evidence/live_worker_result.zip`,
    `evidence/live_worker_raw_3mf.run_info.json`.
- **M2 — STL unaffected.** For an STL part, `report.json` and every variant mesh are
  **byte-identical** pre- vs post-change; the job.json is unchanged (no `source_format`
  key). `run_info.json` differs only by the honest new `source_format:"stl"` line and
  the always-varying `created_wall_ms`. `evidence/M2_and_deeper_fix.txt`,
  `JobJSONEquivalenceTests` (4 passed).
- **M3 — refuse at IMPORT, not after setup.** lib3mf is consumed only at import
  (`inspect_part`/`rescale_part`, called from `AppModel.pickedFile` *before* the
  workspace). A build lacking lib3mf therefore refuses at file-pick. Demonstrated at
  the binary level: a `topopt-cli` built from current source **without** lib3mf still
  refuses a raw `.3mf`, yet runs the app-normalised STL job to a byte-identical result.
  `evidence/M2_and_deeper_fix.txt`.
- **M4 — run_info records the true source format.** `source_format: "3mf"` in every
  worker run (raw 3MF, app-normalised STL, and the lib3mf-less normalised run).
  `evidence/worker_*.run_info.json`.
- **M5 — the Mac worker's core/build.** **Yes, it needed a clean reconfigure.**
  `lib3mf_FOUND`/`TOPOPT_HAVE_3MF` are cached at configure time; a `core/build` first
  configured without lib3mf keeps the miss and re-running the build does not
  re-search. This session did a clean configure (`rm -rf core/build`); the script now
  clears a stale cache automatically and the README documents it.

## Notes & scope

- **Provenance on-device.** `run_info.json` is a CLI/worker artifact (handoff 114); the
  on-device bridge does not write one. There, the true source is preserved in the
  project record (`ImportedFile.name` = `plate_bore.3mf`, `sourceFormat` = `"3mf"`,
  persisted as `originalFileName`). The original file is never destroyed — the STL is a
  *copy* in the temp/working area.
- **The worker no longer needs lib3mf for the app flow** (it receives STL). It still
  needs it only if someone hands the CLI a raw `.3mf` directly; that path is kept
  working and proven (raw-3MF CLI + live HTTP worker above).
- **Verification standard.** Core: `ctest` **70/70 passed** (incl. `threemf_import`,
  `job_schema`) — `evidence/core_ctest.log`. App: `swift test` on the touched suites
  (`AppModelTests`, `JobJSONEquivalenceTests`, `ProjectModelTests`) all pass; the full
  app suite is `xcodebuild test` on this package (not on Linux CI) and carries the
  known intermittent GPU-test SIGTRAP under parallel xctest workers (unrelated).
- **lib3mf version** on macOS is vcpkg `2.5.0#1` (CI-matched via `2026.06.24`),
  provisioned by `build_lib3mf_macos.sh`; iOS slices are untouched by this change.
