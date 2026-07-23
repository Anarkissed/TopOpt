# 129 — Guard modernization (micro): queue-aware setup-stall watchdog, project→multipart, real-CLI parse smoke, honest stall sheet

Four small, independent hardening changes across the **app** (`RunModel`,
`RemoteRunner`, `RunScreen`, the two run-wiring sites) and the **worker/e2e**
(`topopt_worker.py`, `stub_cli.py`, `queue_http_e2e.py`, a new `real_cli_smoke.py`).
**No core.** Builds on **076/101** (the on-device stall watchdog + the remote
heartbeat/probe liveness loop), **121/124** (the human-facing worker + project name),
and **122** (remote fields). Parallel-legal with the tolerance lane.

Handoff number **129** — next free (`docs/handoffs/` runs …124, 125, 127, 128).

---

## 1. Setup-stall watchdog is now queue- and heartbeat-aware (LOCAL-only)

**The bug the `1800s` grace hid.** `RunModel`'s setup-stall watchdog (076) armed at
`start`, for BOTH local and remote runs, on a fixed grace. But a REMOTE run shares that
watchdog, and a remote run legitimately produces no progress tick for a long time — it
can sit QUEUED behind other jobs (121) or grind through a long first FEA solve. When the
grace expired, `watchdogFired` called `token.cancel()`; for a remote run that makes the
next progress callback return `false`, which `RemoteRun` reads as an **explicit user
cancel → DELETE the Mac's job**. The `1800s` value was a band-aid to make that race rare,
not a fix.

**The fix.** The setup-stall watchdog is now a **LOCAL guard only**:

- `RunModel.start(_:remote:)` gained a `remote` flag. A local run arms the watchdog as
  before (a local run is already solving, so a 0%-forever hang is the core
  MultigridCG→Jacobi stall). A **remote run does NOT arm it** — its liveness is
  `RemoteRun`'s job, which already consumes the worker's queued/solving state (the
  `POST /jobs` 202 response + `GET /jobs/{id}` probes: a `queued`/`running`/finished
  status is a reachable worker → keep waiting) and defers to the SSE heartbeat, failing
  loudly only when heartbeats AND probes are BOTH absent (a live worker with no progress
  is a long first solve — the freshness UI communicates that). A queued remote job now
  holds fire indefinitely.
- With remote excluded, the local grace is restored to the honest **~150s** (from the
  `1800s` band-aid). `TimerRunWatchdog` default and its doc-comment updated.
- The two production wiring sites pass the flag: `WorkspacePlaceholder` (`remote:
  compute.activeRemote != nil`) and `AppModel.reattach` (`remote: true`).

## 2. Project name travels as a MULTIPART FIELD, not a job.json key

`RemoteRunner.buildJobJSON` no longer writes `job["project"]` — the CLI's job schema is
strict (`reject_unknown_keys`), so a stray `project` key **fails the run on a device**.
The name now travels as a dedicated multipart `project` field (no filename) in `postJob`,
which the worker already prefers (`topopt_worker._create_job`). The worker keeps its
job.json strip as **belt-and-suspenders** for older clients (comment de-garbled). Net:
the job.json handed to the CLI carries only physics.

## 3. Real-CLI parse smoke (schema-drift guard)

New `tools/topopt-worker/e2e/real_cli_smoke.py` feeds a **representative** job.json
(the exact shape `buildJobJSON` emits — every optional block populated) to the ACTUAL
`topopt-cli` when present (**skip-if-absent**), and asserts the CLI accepts the schema
(any failure is past parse, i.e. model import). Paired positive control: the same job
WITH a stray `project` key MUST be rejected — proving the item-2 strip is load-bearing.
Wired into `run_e2e.sh`'s `queue` target. This is the one place app→worker→CLI schema
drift is caught in the worker suite before it can reach a device.

## 4. The stall sheet admits its own timeout

`RunScreen`'s failure sheet, for a stall, now names the grace it actually waited (the
`RunFailure.stalled*` copy is grace-parameterised — "…stopped after 2 minutes 30 seconds
with no progress…") and offers **"Keep waiting"** alongside Close / Try Again.
`watchdogFired` no longer cancels the token, so the still-running background solve can be
resumed: `keepWaiting()` re-arms the guard and returns to the running card; Close / Try
Again (`dismissFailure`) cancel the token to abandon the stuck run.

---

## Evidence (all run in this worktree)

- **`swift test`** (macOS, after `app/scripts/build_core.sh`): `RunModelTests`
  **47/47**; `ColdLaunchReattachTests` + `StreamedVariantVisibilityTests` +
  `RemoteRunnerE2ETests` **14/14** (1 env-gated skip). New tests: remote-run-doesn't-arm,
  local-run-arms, keep-waiting-re-arms-and-resumes, dismiss-cancels-the-background-run,
  and the stall sheet naming the 150s grace.
- **Worker HTTP e2e** (`queue_http_e2e.py`): **all green**, including the two new checks —
  project via multipart round-trips into `/jobs` AND the job.json handed to the CLI has NO
  project key (inspected over the wire via a stub-echoed `received_job.json`); a QUEUED job
  heartbeats past a representative grace and emits no terminal (holds fire indefinitely).
- **Real-CLI parse smoke**: built `topopt-cli` locally (OCCT+Eigen present) and RAN it —
  representative job passes the schema (fails later at STEP import), stray `project` key is
  rejected (`job.json: unknown key "project" in the job`). Skips cleanly when no binary.
- **Remote happy-path E2E** (`run_e2e.sh happy`, real worker + real `RunModel`,
  `remote: true`, multipart project): resolves `phase=succeeded`, 2 variants, `remote=true`.

## Device QA (unautomatable here)

- On-device: a genuine setup stall now shows a sheet that names ~2.5 min and a **Keep
  waiting** button; Keep waiting keeps the card up and re-arms; Close/Try Again free
  Optimize.
- A remote run that sits QUEUED behind another job on the Mac never trips the local stall
  sheet and never DELETEs the Mac's job; the freshness cue ("last update Xs ago") carries a
  long first solve.
- A remote run's project name appears on the Mac's menu/`GET /jobs` (multipart path).

## Shared-worktree note

The checkout is named for the guard-modernization lane; commit only this lane's files
(the four app sources + two test files, the worker + three e2e files + the new
`real_cli_smoke.py`, and this doc). `app/TopOptKit/vendor/` and `core/build/` are
gitignored build outputs — do not commit.
