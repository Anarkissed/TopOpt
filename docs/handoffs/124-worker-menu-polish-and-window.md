# 124 — Worker/menu telemetry polish + the WorkerApp becomes a real Apple-style app

Builds on **097** (LAN offload: the Python worker + the macOS menu-bar supervisor),
**121** (the worker became human-facing: job queue, `GET /jobs`, the menu job list,
webhooks), **122** (remote result fields), and the iPad design overhaul **109/112**
(the Liquid Glass system this app now shares). **No core, no bridge.** Territory:
`tools/topopt-worker` (Python), `tools/TopOptWorkerApp` (the menu app), the app's new
`WorkerKit` SwiftPM package, and a **single surgical line** in the iPad app's
`RemoteRunner.swift` (see item 2).

Handoff number: **124** — `docs/handoffs/` had two 121s + two 122s (cross-lane
collisions) and 123 is the open conditional-Heaviside PR (#152 lane), so 124 was the
next free number.

**Shared-worktree note:** the checkout's worktree is named for the design-overhaul
lane; commit only this lane's files (the worker, `WorkerKit`, the WorkerApp sources +
`.xcodeproj`, the one `RemoteRunner.swift` line, the e2e additions, and this doc +
assets).

---

## What the maintainer asked for, and what shipped

### Part A — worker/menu polish (restore the lost telemetry + courtesies)

**1. The regression — the rung/iter readout froze the moment the menu opened.** The A4
(handoff 121) job list rendered `<name> — Solving · rung R/N · iter I · started <ago>`
in each row, but two things starved it: the poll `Timer` ran in the run loop's
`.default` mode (**starved during native-menu tracking**), and a native `.menu`
MenuBarExtra **cannot reflow while open**. So the readout the maintainer used daily went
stale the instant they looked at it. Fix, two parts:
  - the poll timer is now added in **`.common`** run-loop modes (`WorkerSupervisor.startPolling`), so it keeps firing while the menu is up; and
  - the MenuBarExtra moved to **`.window` style** — the compact face is now real SwiftUI that reflows live (and gained the glass treatment, Part B).

  The row string is unchanged in intent: `MenuJobRow.detail` = `[stateWord, progressWord, startedWord]` → e.g. **"L-Bracket v3 — Solving · rung 1/2 · iter 21 · started just now"** (see `assets/124_worker_menu_dark.png`).

**2. "Untitled" — the project name never left the iPad.** Diagnosed all three candidate
sides. The worker parse is correct (it reads a top-level `project` / `project_name` from
job.json, or a multipart `project` field — proven by the golden e2e), and the menu render
was only a symptom. **The drop is the app POST**: `RemoteRunner.buildJobJSON()` builds the
job.json from `request` but never included `request.projectName` (a populated non-optional
`String`, `RunModel.swift:33`, set at `AppModel.swift:188`). Fixed **end-to-end** — the
requirement explicitly names "app POST" as a fix site, so this is the one deliberate
app-side line in an otherwise app-free task:
  ```swift
  let projectName = request.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
  if !projectName.isEmpty { job["project"] = projectName }
  ```
  And defense in depth on the menu side: `WorkerJob.displayName` now falls back to the
  job id's short form (`"Job \(id.prefix(8))"`), **never** the old `"Untitled"`.

**3. Port courtesy.** On `EADDRINUSE` the worker now prints
`port 8757 in use — is another worker already running? (lsof -i :8757)` (with the *real*
port) and exits `1` — no naked traceback. Banked from tonight's bootloop diagnosis.

**4. Startup identity line.** The worker logs one line on boot naming its version, the
core fingerprint it serves, and its workdir:
  `topopt-worker 1.1.0  ·  core b9d0a2fb03e4  ·  workdir /Users/…/.topopt-worker`
  A supervisor log now answers "which worker is this?" with no archaeology.

### Part B — the WorkerApp becomes a real Apple-style app

**5. Architecture.** The MenuBarExtra stays the compact face (the live glass job rows from
item 1). A **main `Window`** (`WorkerWindow`, id `"main"`) opens from the menu's "Open
TopOpt Worker" and from a click on any job row (which also sets `focusedJobID` so the
window scrolls to it). Closing the window returns the app to the menu bar — LSUIElement
lifecycle unchanged (no Dock icon, `.accessory` policy). A standard **`Settings` scene**
(⌘, and the menu's "Settings…") backs the same settings pane.

**6. Design language.** One small self-contained layer, `WorkerGlass.swift`, mirrors the
iPad's 109/112 tokens (accent `#0A84FF`, the red keep-out language, a near-black stage,
restrained rounded typography). It's a *mirror*, not an import — the WorkerApp is a
standalone Xcode target and deliberately doesn't link `TopOptDesign`. Real
`.glassEffect` on **macOS 26** with an `.ultraThinMaterial` + dark-base + tint fallback
below, the same specular hairline both ways. **Static per the 108 rule**: no timer,
display-link, or per-frame work drives any chrome; the only motion is a number changing
when a poll delivers a new one (the `HonestBar` is a fractional fill, never an animated
indeterminate shimmer).

**7. Window content.** Header (worker identity: status dot + live/paused/unreachable word,
port, core fingerprint + version, uptime, Start/Stop) · **Queue** (jobs as glass cards
with a real progress bar, rung/iter, a heuristic `~Xm left` ETA, per-card
pause/resume · move-to-front · cancel · Show-in-Finder) · **History** (finished runs with
a real outcome summary — accepted-variant count + duration — and Finder jumps) ·
**Settings** (port, max concurrency, webhook URL with the ntfy caption, Launch at Login,
topopt-cli path — absorbs the old sheet) · **Log** (an on-demand tail of the newest job's
`worker.log`, read on a Refresh, no timer touching the file).

**8. Honesty in the chrome.** Every number is a real readout. The fingerprint/version come
from the CLI probe; rung/iter/variants from `/jobs`; the ETA is a real extrapolation from
elapsed × remaining fraction (prefixed `~`, and `nil` until there's an honest fraction).
A worker that's up but not answering flips `reachable=false` after two missed polls and
the window shows the honest **Unreachable** state, not a frozen green light. To surface a
real accepted-variant count in History, the worker snapshot gained a `variants` field
(counted from accepted `VARIANT` events) — a real number, not a placeholder.

---

## The unified action layer (the load-bearing refactor)

Two faces that drive the same worker must never diverge. So `WorkerClient.swift` (in the
new **Foundation-only** `WorkerKit` SwiftPM package) is the single source of the job model
(`WorkerJob`), the per-state control list (`JobControls.actions(for:)`), and every request
(`WorkerClient.request(_:job:)` + `jobsRequest`/`healthRequest`). Both `MenuContent` and
`WorkerWindow` render controls from `JobControls` and fire them through
`WorkerSupervisor.perform(_:on:)` → `WorkerClient` — so a "Cancel" is the **same DELETE**
on either face. The package exists so `swift test` proves this without Xcode or a GUI.

The app target compiles `WorkerClient.swift` directly (a file reference into
`WorkerKit/Sources/…`); the SwiftPM package compiles the same file for its tests. One
physical file, two compile contexts, no duplication.

---

## Evidence

- **`swift test`** (`tools/TopOptWorkerApp/WorkerKit`): 10 tests green, incl.
  `testMenuAndWindowDriveIdenticalRequests` (the unification invariant),
  `testActionRequestsMatchTheWorkerRouting`, `testDisplayNameFallsBackToShortIDNeverUntitled`,
  `testProgressWordRendersRungAndIter`, and the /jobs + /health decode goldens.
- **Worker e2e** (`tools/topopt-worker/e2e/queue_http_e2e.py`, run via `run_e2e.sh queue`):
  the existing golden/webhook/pause-resume checks plus new coverage — name round-trip +
  live integer progress in `/jobs`, the port-in-use courtesy (exit 1, lsof hint, no
  traceback), and the startup identity line. All green.
- **Screenshots** (`docs/handoffs/assets/`, dark): `124_worker_menu_dark.png`,
  `124_worker_window_dark.png`, `124_worker_history_dark.png`.

### Screenshot caveat (read this)

The screenshots are **`ImageRenderer` rasterizations of the real view tree with the real
supervisor's live polled data** — every string in them (fingerprint, port, uptime, project
names, `rung 1/2 · iter 21`, `~35s left`, `2 variants · 0s`) is a genuine readout from a
running worker (the stub CLI, so the fingerprint is the app's default and durations are ~0s).
This environment **cannot `screencapture`** (no Screen Recording permission / framebuffer),
so a live on-screen capture wasn't possible here. `ImageRenderer` does **not** composite the
live backdrop blur, so the **glass frost reads flatter than on device** — panels look like
dark translucent fills with the specular hairline rather than the full Liquid Glass blur.
On a real macOS 26 display the `.glassEffect` path gives the full material. **Maintainer QA
should confirm the frost on-device** (the `/app/` pixels-are-device-QA rule applies here too).

### QA harness (gated, inert in normal use)

To make the screenshots reproducible, the app has an env-gated QA path (no effect without
the var):
- `TOPOPT_WORKER_QA=render` [`TOPOPT_WORKER_QA_SECTION=history`] `TOPOPT_WORKER_QA_OUT=<dir>`
  — rasterize the window + menu (or the history pane) to PNGs and exit.
- `TOPOPT_WORKER_QA=1` — present the window + menu as on-screen AppKit windows (for
  `screencapture` on a machine that grants Screen Recording).

Reproduce: launch the app binary directly with `TOPOPT_STUB_MODE=slow` and the app pointed
at `e2e/stub_cli.py` (Settings → topopt-cli path), POST a few named jobs (see the e2e
`submit`), and the render writes to `TOPOPT_WORKER_QA_OUT`. The `qaFlatten` environment flag
+ `FlexScroll` drop the pane ScrollViews for rasterization (ImageRenderer collapses
ScrollView content) — also inert in normal use.

---

## Manual QA list (MouseTool-style open/close lifecycle)

1. Launch → menu-bar `cpu` icon appears, **no Dock icon**, no window.
2. Open the menu → live job rows; watch a running job's **iter advance while the menu
   stays open** (item 1 — the regression).
3. Click "Open TopOpt Worker" (or a job row) → the main window opens and takes focus.
4. **Close the window → the app stays in the menu bar** (does not quit); reopen works.
5. Header shows the real fingerprint/version/uptime; Stop → header goes Stopped, Start →
   back to Solving/Idle.
6. Per-card pause/resume/cancel/move-to-front + Show in Finder all act (same endpoints as
   the menu — they *are* the same requests).
7. Kill the Python worker out from under the app (`kill` the child) → window shows
   **Unreachable**, not a frozen UI; it recovers on the supervisor's auto-restart.
8. Settings (⌘, and menu) → change port/concurrency/webhook → Apply & Restart takes effect.
9. Confirm the **glass frost on-device** (see the screenshot caveat).

---

## What was deliberately NOT done / risks

- **The iPad app was not compiled here.** The one `RemoteRunner.swift` line uses an existing
  non-optional `String` property in a guarded dict insert; it parses clean (`swiftc -parse`)
  and is type-trivial, but the TopOptKit package links the vendored core (`build_core.sh`,
  ~48s) so a full app build/test wasn't run in this worker/menu lane. Low risk; flag for the
  next app-touching lane if paranoid.
- **ETA is a heuristic** (`elapsed × (1−f)/f`, `itersPerRung` assumed 60 — the ladder's
  real iters-per-rung isn't on the wire). It's honest-but-approximate and labelled `~`;
  it's never shown without a real fraction to extrapolate from.
- **Cross-lane collisions expected**: this lane touches the worker + `RemoteRunner`, as did
  121/122. Built against current `main`; nothing here depends on unmerged lanes. The
  worker's `/jobs` gained a `variants` field — additive, and the golden e2e was updated.
