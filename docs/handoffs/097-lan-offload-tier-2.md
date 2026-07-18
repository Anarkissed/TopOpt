# 097 — LAN offload Tier 2: one-tap remote runs + set-and-forget Mac worker

Builds on 093 (LAN compute offload) / PR #119 (CLI == bridge parity). Delivers the
two-taps-to-running UX: a Mac menu-bar app you open once, and an iPad run screen
that shows the Mac as a compute location automatically (Bonjour, no IP typed) and
streams the SAME live progress + variant screen a local run shows.

**The one rule held:** local on-device runs are the default and stay
byte-identical. Remote is opt-in per run — a user who never taps the picker sees
zero change (`RunModel.runner` is only swapped to the remote runner when a worker
is selected + resolved; otherwise it's `bridgeRunner`). **bridge.cpp untouched.
core / Gate-V2 / fixtures / benchmarks / materials.json / ARCHITECTURE.md
untouched.**

Handoff number: 097 — checked `docs/handoffs/` on `main` (highest was 095); 096
and 097 free, took 097 per the task's "first free ≥ 097".

---

## What shipped

### Deliverable 1 — macOS menu-bar app `tools/TopOptWorkerApp/`
A SwiftUI, menu-bar-only (`LSUIElement`) app that **supervises the existing Python
worker** (`tools/topopt-worker/topopt_worker.py`, bundled into the app) — it does
NOT reimplement the HTTP server (one server implementation, the Python one).
- Launches the worker as a subprocess (`python3 topopt_worker.py --cli <cli>
  --host 0.0.0.0 --port 8757`), **restarts it on unexpected exit** (2 s backoff).
- Menu: running/port status · active job + rung/iter · core fingerprint ·
  Start/Stop/Restart · **Launch at Login (SMAppService)** · **Update core…**
  (shows the rebuild command; auto-update is OUT of scope, see limitations) ·
  Settings… (locate topopt-cli) · Quit.
- **Bonjour `_topopt._tcp`** advertised via `NetService` (the worker owns the
  socket; NetService just publishes the record) with the **core fingerprint in the
  TXT record** so the iPad can show skew before submitting.
- **Keep-awake only while a job runs**: `ProcessInfo.beginActivity(.idleSystemSleep
  Disabled)` engaged when the parsed job count > 0, released when it hits 0 — the
  Mac won't sleep mid-solve, and isn't blocked from sleeping while idle.
- **Locates topopt-cli**: bundled in the app if present, else a Settings path.
  Missing / `--version` fails → the menu says so in plain words + the build command,
  instead of a dead server.
- Buildable `TopOptWorkerApp.xcodeproj` + one-command `build_and_install.sh`.
  Signing/notarization OUT of scope (ad-hoc signed; README documents the
  right-click-Open first launch).

### Deliverable 2 — iPad integration
- **RemoteRunner.swift compiled + run for the first time** (it had never been built).
- **Discovery**: `ComputeLocation.swift` browses `_topopt._tcp` (`NWBrowser`). The
  workspace bottom bar gets a compute-location control (`ComputeLocationControl`):
  "iPad" (default, always) + each discovered worker by Bonjour name. Selection
  persists per device (UserDefaults). An "Advanced: connect by address" disclosure
  is the only manual-IP path.
- **Fingerprint automation**: `build_core.sh` now writes
  `TopOptKit/Sources/TopOptFlows/CoreFingerprint.generated.swift` with the core git
  SHA using the **same derivation the CLI's CMake uses** (`git -C core rev-parse
  --short=12 HEAD`). `RemoteRunner`/`ComputeLocation` read it; the user never sees a
  fingerprint. **Gitignored** (see below).
- **Skew UX**: a worker whose TXT fingerprint ≠ the app's shows a ⚠️ warning state
  + plain-English message pointing at the Mac app's "Update core…". The
  RemoteRunner `/health` guard is the hard refusal (before submit).

### RemoteRunner drift + review-carry fixes (every fix, per the task)
`buildJobJSON` already matched the current CLI job schema (PR #119), so the drift
was small — but real:

1. **`import TopOptKit`** — the ONLY hard compile error. RemoteRunner used
   `OptimizeOutcome` / `OptimizeVariant` (defined in the `TopOptKit` module)
   unqualified with no import → `cannot find type 'OptimizeOutcome' in scope`
   (×4). Every other reference already resolved.
2. **(review fix 1) send `smooth_factor`** — the local bridge re-extracts every
   variant's iso-surface at `kSmoothExportFactor = 2` (bridge.cpp) before handing
   it to the app; the CLI defaults to `1` (raw v3 mesh). Without sending `2` the
   remote parts would be visibly coarser than local. Added `"smooth_factor": 2` to
   the job's `output` block (a documented mirror of the C++ constexpr).
3. **(review fix 2) mesh fetch surfaces an error, never a silent empty mesh** — the
   old code did `(try? syncGET(url)).map(parse) ?? ([], [])`, so a 404/short body
   became an empty part on screen. New `fetchMesh(named:)` throws on non-200 or an
   unreadable/empty STL; a streamed-variant fetch failure fails the run with a
   clear message rather than showing a bodiless variant.
4. **authoritative streamed mesh names for final assembly** — the report's
   `volume_fraction` is the ACHIEVED fraction, but the CLI names mesh files by the
   REQUESTED fraction (`run_job.cpp` `mesh_file_name`), so the old
   `variant_%03d.stl` reconstruction from the report silently fetched the wrong /
   no file. Now each `VARIANT` event's mesh basename + geometry is recorded, and
   the final outcome reuses them (joined to the report by achieved-vf).
5. **(review fix 3) remote-unavailable fields render as n/a** — new
   `OptimizeOutcome.computedRemotely` flag (default false → local unchanged),
   threaded through `RunModel.appendStreamed` and read by `ResultsModel`:
   mass → "n/a — computed on Mac" (not "0 g"), support → n/a, and the stress
   overlay / flex / load-path / playback controls stay hidden (their fields are
   empty AND gated on `!computedRemotely`). A one-line results banner states what's
   computed on the Mac, so the gap is explicit, never a plausible-but-wrong readout.

---

## Evidence (raw)

### 1. `xcodebuild` — all four targets

```
### 1. TopOptKit package — macOS
** BUILD SUCCEEDED **
### 2. TopOptKit package — iOS Simulator
** BUILD SUCCEEDED **
### 3. iPad app (TopOpt.xcodeproj) — iOS Simulator
** BUILD SUCCEEDED **
### 4. macOS menu-bar app (TopOptWorkerApp.xcodeproj) — Release
** BUILD SUCCEEDED **
```

Menu-bar app bundle (built): `LSUIElement=true`, `NSBonjourServices=[_topopt._tcp]`,
the real `topopt_worker.py` bundled into `Contents/Resources/`. iPad app generated
`Info.plist`: `NSBonjourServices => [ _topopt._tcp ]`, `NSLocalNetworkUsage
Description => "TopOpt finds your Mac worker…"`.

### 2. End-to-end on the iOS SIMULATOR against the real worker on localhost

The `RemoteRunnerE2ETests` (gated on `TOPOPT_E2E=1`) drive the REAL `RunModel` +
`RemoteRunner` against the REAL `tools/topopt-worker` on `127.0.0.1`, which wraps a
**protocol-faithful stub `topopt-cli`** (see Limitations for why a stub, not the
real solver). Happy path — app-side event log + worker-side log together:

```
--- worker /health ---   (curl, before the run)
{"ok": true, "worker_version": "1.0.0", ... "cli_version": "stub-097",
 "fingerprint": "f0e578c0a3a3", "active_jobs": 0}

=== running E2E case=happy (stub_mode=normal) ===
  app progress: Variant 1 of 2 · SIMP iteration 3 — 2%
  app streamed: outcome now has 2 variant(s), remote=true
  app resolved: phase=succeeded
  RESULT: succeeded, 2 variants, worst margins ["2.40", "1.70"]
Test Case '-[TopOptFlowsTests.RemoteRunnerE2ETests testEndToEnd]' passed (0.203 seconds).

--- worker stdout (the STATUS lines the menu-bar app parses) ---
topopt-worker 1.0.0: topopt-cli version=stub-097 fingerprint=f0e578c0a3a3
listening on http://127.0.0.1:8778  (LAN only; no auth)
STATUS job=e11543d129a04c93 state=running rung=0 rungs=2 iter=1
STATUS job=e11543d129a04c93 state=running rung=0 rungs=2 iter=2
STATUS job=e11543d129a04c93 state=running rung=0 rungs=2 iter=3
STATUS job=e11543d129a04c93 state=running variant=variant_070.stl
STATUS job=e11543d129a04c93 state=running rung=1 rungs=2 iter=1
STATUS job=e11543d129a04c93 state=running rung=1 rungs=2 iter=2
STATUS job=e11543d129a04c93 state=running rung=1 rungs=2 iter=3
STATUS job=e11543d129a04c93 state=running variant=variant_050.stl
STATUS job=e11543d129a04c93 state=done
```

submit → live progress events → streamed variant appears (`remote=true`) → final
variants render. ✔

### 3. Negative controls (each on the simulator, raw)

```
case=mismatch:
  refused before submit: worker core mismatch: worker f0e578c0a3a3, app 0000deadbeef.
  Refusing to run — a different core produces a different part. ...
  → passed (no run started, no variant fetched)

case=offline (worker at a dead port):
  offline failure: request failed: /health: Could not connect to the server.
  → passed in 0.092 s (fast-fail, not a hang; outcome nil)

case=bad_mesh (worker announces a variant but its mesh 404s):
  mesh-fetch failure surfaced: could not fetch variant mesh "variant_070.stl" from
  the worker (HTTP 404). ... not showing an empty part.
  → passed (never returns an empty-mesh variant)

case=reject_all (report ladder, nothing accepted):
  all-rejected: acceptedCount=0, terminal margin=1.1
  → passed (carries the ladder so RunModel shows the honest "not strong enough" sheet)

case=cancel (user cancels mid-run):
  cancel: outcome.cancelled=true, error=nil  → passed
```

Worker-side cancel proof (the DELETE kills the CLI subprocess):
```
submitted job=0f368123ae024549
active_jobs BEFORE cancel: 1
stub CLI child PIDs before: 64968
--- DELETE (cancel) --- {"job_id": "...", "status": "cancelled"}
stub CLI child PIDs after: none (killed)
active_jobs AFTER cancel: 0
--- final SSE replay --- data: {"type": "cancelled"}
```

### 4. Unit tests + regression (macOS)

- `ComputeLocationTests` (5): local default / manual config / switch-back-to-local
  clears remote / per-device persistence / skew flag+message — all passed.
- `ResultsRemoteFieldsTests` (2): remote marks mass+support n/a, hides stress/flex/
  playback, shows the note, keeps savings/orientation/margin/geometry real; a local
  outcome is unchanged — both passed.
- **Full `TopOptFlowsTests` regression: `Executed 389 tests, with 1 test skipped and
  0 failures`** (the 1 skip is the E2E suite, correctly inert without a worker). No
  regression from the `RunModel` / `ResultsModel` / `TopOptKit` changes.

### 5. macOS app runtime smoke (headless)
Launched the built app with the CLI path pre-seeded → it supervised the **bundled**
worker (`…/TopOpt Worker.app/Contents/Resources/topopt_worker.py --cli … --host
0.0.0.0 --port 8757`, PID observed) and `GET /health` returned
`fingerprint=f0e578c0a3a3, active_jobs=0`. (Live Bonjour advertise/browse is device
QA — see Limitations.)

---

## Honest limitations

- **Simulator-proven vs device-unproven.** The offload run path (submit → progress
  → streamed variant → final → cancel/skew/offline/mesh-fail) is proven on the iOS
  **simulator** against the real worker on localhost — the simulator reaches
  `127.0.0.1`, no physical device needed, and the manual/localhost path needs no
  Bonjour. **Live Bonjour discovery (NWBrowser ⇄ NetService) is DEVICE QA**: modern
  macOS/iOS gate mDNS behind the interactive **Local Network** privacy permission,
  which can't be granted headlessly. The discovery code compiles on both platforms
  and its selection/persistence/skew logic is unit-tested; the mDNS handshake and
  the on-device "Mac Mini appears automatically" moment need a real iPad + Mac with
  the permission approved. The plist keys for it are in place (`NSBonjourServices`,
  `NSLocalNetworkUsageDescription`).
- **Protocol-faithful stub CLI, not the real solver.** The end-to-end used a stub
  `topopt-cli` that emits the EXACT stdout protocol the real CLI emits
  (`run_job.cpp`: `PROGRESS …` / `VARIANT …`), writes real binary STL + a
  schema-valid `report.json`, and answers `--version` with a controllable
  fingerprint. It exercises the real worker + real RemoteRunner + real RunModel
  against the real protocol, fast and controllably (needed to force the mismatch /
  bad-mesh / reject-all / cancel controls). It does NOT run a real FEA solve, so the
  transport is proven, not the numerics (numerics == the on-device bridge, unchanged
  and already covered by Gate-V2 / the existing suite). A real solve behind the
  worker is a matter of pointing `--cli` at a freshly built `topopt-cli`.
- **Result-fidelity gap (known, flagged in-UI).** The CLI serialises meshes + the
  scalar report but NOT the per-voxel von Mises / displacement / stress-tensor
  fields, the playback keyframes, or the mass. So a remote variant renders with
  geometry + savings + orientation + safety margins, but mass / stress overlay /
  flex / playback show as "computed on Mac — n/a in this build" (fix 3), never a
  0 g / blank. **Follow-up: full-result serialisation over the wire** — teach the
  CLI to emit the per-voxel fields + mass (a `result.bin` alongside `report.json`)
  and RemoteRunner to read them; that closes the gap and removes the n/a note.
- **Auto-update is out of scope.** "Update core…" shows the rebuild command +
  copies it; it does not pull/rebuild for you.
- **Signing/notarization out of scope.** The Mac app is ad-hoc signed →
  right-click-Open on first launch (README). SMAppService launch-at-login works best
  on a signed app; ad-hoc is fine for local use.

## Notes on two small, in-scope edits outside the app
- `tools/topopt-worker/topopt_worker.py`: **+15 lines**, additive only — `Job.emit`
  now echoes compact `STATUS job=… state=… rung/iter` lines to the worker's OWN
  stdout so the menu-bar supervisor can show the active job + hold keep-awake
  WITHOUT a second HTTP client. The task spec explicitly says "parse the worker's
  SSE or **stdout**"; the SSE/HTTP protocol is unchanged.
- `StreamedVariantVisibilityTests.swift`: wrapped the class in `#if canImport(AppKit)`
  — it hosts SwiftUI via `NSHostingView`/`NSWindow` (macOS-only) and never compiled
  for an iOS destination, which the simulator E2E requires. macOS behaviour
  unchanged.

## CoreFingerprint.generated.swift — gitignored, and why
Follows the repo's established convention (`vendor/`, `occt-frameworks.generated
.json` are all gitignored generated outputs, to keep `git status` clean). It is
paired with the vendored core `build_core.sh` produces, and **`build_core.sh`
already MUST run before the app builds** (it vendors the core xcframework) — so
regenerating the fingerprint is not a new step. A fresh checkout runs `build_core.sh`
as before; absent git → `"dev"`, which never equals a real worker fingerprint, so
skew fails safe (refuse).

## Files
Changed: `app/scripts/build_core.sh`, `app/.gitignore`,
`app/TopOpt.xcodeproj/project.pbxproj` (+`app/TopOpt-Info.plist`),
`RemoteRunner.swift`, `RunModel.swift`, `ResultsModel.swift`, `ResultsScreen.swift`,
`WorkspacePlaceholder.swift`, `TopOptKit.swift`, `StreamedVariantVisibilityTests.swift`,
`tools/topopt-worker/topopt_worker.py`.
Added: `ComputeLocation.swift`, `ComputeLocationControl.swift`, tests
(`ComputeLocationTests`, `ResultsRemoteFieldsTests`, `RemoteRunnerE2ETests`),
`tools/TopOptWorkerApp/` (Xcode project, 5 Swift files, Info.plist,
`build_and_install.sh`, README).
Generated (gitignored): `CoreFingerprint.generated.swift`.

## Ceiling (named before building)
Remote wall-clock is dominated by the Mac's solve; networking adds seconds. No
effort spent on transfer throughput. The win is taps-to-running (two taps: pick the
Mac once, tap Optimize) + set-and-forget reliability (launch-at-login, auto-restart,
keep-awake, fail-fast + honest messages).
```
