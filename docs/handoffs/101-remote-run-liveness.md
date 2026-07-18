# 101 — Remote-run liveness: kill the wall clock, add reconnect, stop destroying the Mac's work

Builds on 093 (LAN compute offload) and 097 (LAN offload Tier 2 — RemoteRunner
compiled + E2E'd for the first time). **No core, no bridge.cpp.** Territory:
`RemoteRunner.swift`, `RunModel.swift`, `tools/topopt-worker/topopt_worker.py`
(heartbeat only), and the E2E harness + tests.

Handoff number: 101 — checked `docs/handoffs/` (highest was 100; 096/098 are
reserved for pending renames), so the first free ≥ 100 is 101.

---

## The incident

A real 128³ four-rung remote run was killed at **exactly 3600s** by
`RemoteRunnerConfig.timeout`. That single value did double duty: the run-loop
semaphore wait **and** URLSession's `timeoutIntervalForResource`, which caps an SSE
task's TOTAL lifetime even while data is flowing. When it fired, the client also
`DELETE`d the job — **destroying an hour of the Mac's solve.** A fixed wall clock
is categorically wrong for a feature whose entire purpose is runs too big for the
iPad. Liveness must be progress-based.

## What shipped

### 1. Liveness = progress, not elapsed time  (`RemoteRunner.swift`)
- **The wall-clock ceiling is gone.** `RemoteRunnerConfig.timeout` (a fixed 28800s
  that also set `timeoutIntervalForResource`) is deleted. The events stream's
  resource timeout is now **effectively unbounded** (1 year); a provably-
  progressing run can take 10+ hours.
- **Inactivity watchdog.** If NO SSE traffic — a typed event OR the worker's
  keepalive ping — arrives for `inactivityGrace` (default **180s**), the client
  does NOT fail. It **probes `GET /jobs/{id}`** (the status endpoint):
  - reachable → reconnect the events stream and keep going (the replay drains any
    terminal event it missed);
  - unreachable after `maxProbeFailures` (3) short-timeout probes → fail with a
    message that says the **WORKER became unreachable** and that **the Mac keeps
    solving** — never "timed out".
- **URLSession split.** A dedicated events session (idle/request timeout 120s,
  resource ~unbounded) for the long stream; a short-timeout **control session**
  (12s, default) for `/health`, `POST /jobs`, status probes and mesh fetches — so
  the offline fast-fail negative control stays fast.

### 2. Worker heartbeat  (`topopt_worker.py`, +~20 lines, additive)
`_events` now emits an SSE comment `: ping\n\n` every `HEARTBEAT_SECONDS`
(default 20, env-overridable) whenever no real event was ready while a job runs.
SSE comments are ignored by every client except as liveness, so the typed event
stream (progress/variant/log/done/error) is byte-for-byte unchanged. This is the
signal the inactivity watchdog needs when one Fine iteration takes minutes.

### 3. Reconnect + dedup  (`RemoteRunner.swift`)
A dropped/ended events stream is **not terminal**. On `didCompleteWithError`
without a terminal event (or on an inactivity probe that finds the worker alive),
the client reopens `/events` with backoff (1, 2, 4 … cap 30s). The worker already
replays every event from index 0 on reconnect (093); the client **dedupes by event
index** (a per-connection replay counter vs a persisted high-water mark) **and** by
**variant mesh basename** (the belt-and-suspenders guard the task asked for), so
progress and variants are never double-emitted. Superseded event tasks are tracked
by identity, so a deliberate reconnect never masquerades as an unexpected drop.

### 4. Never cancel the Mac's job except on explicit user cancel
The `DELETE` now fires from **exactly one place**: the user-cancel path (the
progress callback returned `false`). Watchdog-unreachable, stream loss, a mesh-
fetch failure, and app death all fail/abort the *client* **without** a `DELETE` —
the worker keeps solving, its result persists in its workdir, and `/result` works
after completion. (The old timeout-path `DELETE` and the old `failStream` `DELETE`
are removed.)

### 5. Persist active job + re-attach  (`RemoteRunner.swift`)
- `RemoteJobStore` persists `{host, port, fingerprint, jobID}` (UserDefaults) on
  submit and clears it **only** on a terminal resolution or user cancel — never on
  a client-side liveness failure, so a slept/relaunched iPad can still find the
  Mac's live run.
- `RunModel.remoteReattachRunner(config, jobID:)` streams an **existing** job
  (skips `/health` + `POST`); the worker's replay rebuilds the streamed variants,
  and the same final outcome is assembled.
- **Foreground-within-a-live-process is automatic**: when iOS tears down the
  backgrounded stream and the app returns to foreground, the still-alive run loop
  sees the ended/stale stream, probes, and reconnects — the exact path the
  `stream_drop` case exercises. See Limitations for the across-relaunch UI scope.

### 6. UX honesty — freshness cue  (`RunModel.swift`)
`RunModel.lastProgressAt` records the last live signal (progress tick or streamed
variant). `RunModel.remoteFreshnessNote(lastUpdate:now:heartbeat:)` is a pure,
unit-tested helper that returns `"last update Xs ago"` once the gap exceeds ~2× the
heartbeat (else nil — no crying wolf at a healthy cadence). This is the USER-facing
"is it still alive?" cue, distinct from the client's inactivity watchdog (which is
keyed off SSE pings). The RunScreen binds it for a remote run; the binding is the
same device-QA tier as the rest of the progress readout (097).

---

## Evidence (raw)

### A. Heartbeat visible in a captured SSE stream + replay + DELETE-only
`tools/topopt-worker/e2e/protocol_smoke.py` — pure-Python, HTTP-level, no Xcode
(worker + stub CLI on localhost, heartbeat=1s, progress gap=2s):

```
== worker up on 127.0.0.1:51365 (stub cli, heartbeat=1s, gap=2s) ==
submitted job=1a82122667ef4857

== (1) RAW /events SSE stream — heartbeat ': ping' interleaved with events ==
   data: {"type": "progress", "rung": 0, "rungs": 2, "iter": 1}
   : ping
   data: {"type": "progress", "rung": 0, "rungs": 2, "iter": 2}
   : ping
   data: {"type": "progress", "rung": 0, "rungs": 2, "iter": 3}
   : ping
   data: {"type": "variant", "vf": 0.7, "achieved": 0.7, "margin": 2.4, "accepted": true, "mesh": "variant_070.stl"}
   data: {"type": "progress", "rung": 1, "rungs": 2, "iter": 1}
   : ping
   data: {"type": "progress", "rung": 1, "rungs": 2, "iter": 2}
   -> 4 heartbeat pings, 6 data events in the first 8s

== (2) RECONNECT REPLAY — a fresh /events re-delivers every event from the start ==
   data: {"type": "progress", "rung": 0, "rungs": 2, "iter": 1}
   ... (all 8 progress/variant events) ...
   data: {"type": "done", "returncode": 0, "artifacts": ["report.json", "variant_050.stl", "variant_070.stl"]}
   -> replay re-delivered 9 events (client dedupes these by index)

== (3) DELETE-only cancel — a NEW running job is killed only by DELETE ==
   status before DELETE: {"job_id": "cd0868f1d87e456b", "status": "running"}
   DELETE response:       {"job_id": "cd0868f1d87e456b", "status": "cancelled"}
   status after DELETE:   {"job_id": "cd0868f1d87e456b", "status": "cancelled"}
```

### B. App-side E2E through the real RunModel + RemoteRunner (macOS destination)
`tools/topopt-worker/e2e/run_e2e.sh <case>` stands up the real worker (stub CLI),
optionally a recording proxy, and runs `RemoteRunnerE2ETests` against it.

**(a) slow_sparse** — PROGRESS gap (2.5s) > inactivity grace (2s); only the 1s
heartbeat keeps the stream fresh. The run OUTLIVES the grace and completes:
```
== E2E case=slow_sparse port=51522 grace=2.0s appFingerprint=b9d0a2fb03e4 ==
  slow_sparse: elapsed=15.1s streamed=2 progress=6 error=nil
Test Case '…testEndToEnd' passed (15.121 seconds).
```
(15.1s elapsed vs a 2s grace — with the old wall clock / no heartbeat this would
have false-failed; it does not.)

**(b) stream_drop** — the recording proxy severs the SSE mid-run; the client
reconnects and dedupes the from-the-start replay:
```
proxy: DROPPING /jobs/283cc80361da4430/events after 4 data frames
== E2E case=stream_drop port=51472 grace=3.0s appFingerprint=b9d0a2fb03e4 ==
  stream_drop: streamed=2 progress=6 error=nil
Test Case '…testEndToEnd' passed (2.528 seconds).
```
`streamed=2` (not 3): `onVariant` fired exactly once per variant — the replayed
first variant was deduped, not re-emitted.

**(c) worker_dies_midrun** — the worker PROCESS is killed mid-run (the stub SIGKILLs
its parent right after the first variant). The watchdog probes, fails with the
worker-unreachable message, and **no DELETE crosses the wire** (the proxy logged
every client request):
```
== E2E case=worker_dies port=51503 grace=3.0s appFingerprint=b9d0a2fb03e4 ==
  worker_dies: failure=The Mac worker became unreachable, so this run can’t be followed
    from the iPad any more. This is NOT a timeout — the run was not stopped: the Mac keeps
    solving and its result is saved on the Mac, available when it finishes. …
  proxy saw 7 request(s); DELETEs: 0
Test Case '…testEndToEnd' passed (4.995 seconds).
```

**(d) explicit cancel** — still kills the subprocess (control stays green):
```
== E2E case=cancel port=51529 grace=3.0s appFingerprint=b9d0a2fb03e4 ==
  cancel: outcome.cancelled=true, error=nil
Test Case '…testEndToEnd' passed (0.057 seconds).
```

**(e) offline fast-fail** — stays fast (<2s):
```
== E2E case=offline port=1 grace=3.0s appFingerprint=b9d0a2fb03e4 ==
  offline failure: request failed: /health: Could not connect to the server.
Test Case '…testEndToEnd' passed (0.018 seconds).
```

**Existing controls (no regression)** — happy / mismatch / bad_mesh / reject_all:
```
happy:      RESULT: succeeded, 2 variants, worst margins ["2.40", "1.70"]  (remote=true)
mismatch:   refused before submit: worker core mismatch: worker b9d0a2fb03e4, app 0000deadbeef …
bad_mesh:   mesh-fetch failure surfaced: could not fetch variant mesh "variant_070.stl" … HTTP 404 …
reject_all: all-rejected: acceptedCount=0, terminal margin=1.1
```

### C. Full app suite (macOS) — green
```
Test Suite 'TopOptFlowsTests.xctest' — Executed 410 tests, with 1 test skipped and 0 failures
Test Suite 'TopOptKitTests.xctest'  — Executed 23 tests, with 0 failures
** TEST SUCCEEDED **
```
The 1 skip is `RemoteRunnerE2ETests` (correctly inert without a worker). The new
pure-logic unit tests (`RemoteLivenessUnitTests`: freshness cue thresholds +
`RemoteJobStore` round-trip/overwrite/clear + no-wall-clock config) run in the
normal suite. No core / CI / Gate-V2 changes.

---

## Honest limitations

- **Re-attach: what ships vs what's deferred.** Foreground-reconnect **within a
  live process** ships and is proven — it IS the reconnect machinery (`stream_drop`
  is exactly a dropped connection recovered by probe + reopen + dedup). The
  MECHANISM for **across-relaunch** re-attach also ships: `RemoteJobStore` persists
  the active job, and `remoteReattachRunner` streams an existing job without
  re-POSTing (both unit-tested). What is **deferred** is the workspace UI wiring
  that, on cold launch, reads the store and rebuilds a full `RunModel` run screen
  from it — that is a SwiftUI/ProjectModel integration in the same device-QA tier
  as the existing RunScreen, and is left as a Blocked-stop with the building blocks
  in place rather than a half-wired cold-launch path.
- **iOS will still kill a backgrounded stream.** A suspended app's URLSession
  stream is torn down by the OS; there is no way around that on iOS. That is
  *precisely why reconnect-on-foreground is the mechanism* — the run loop survives
  the suspension, and on return to foreground the ended/stale stream is probed and
  reconnected. Battery/thermal state can also suspend sooner; the Mac keeps solving
  regardless, and the run resumes when the iPad comes back. (`beginBackgroundTask`,
  wired in `LocalRunNotifier`, buys the usual short grace but is not a substitute.)
- **Protocol-faithful stub CLI, not the real solver.** The E2E drives the real
  worker + real RemoteRunner + real RunModel against the exact CLI stdout protocol
  (`PROGRESS …` / `VARIANT …`), real binary STL + a schema-valid `report.json`, and
  a controllable `--version` fingerprint. It proves the TRANSPORT + liveness, not
  the numerics (numerics == the on-device bridge, unchanged, covered by Gate-V2 /
  the existing suite). A real solve is a matter of pointing `--cli` at a built
  `topopt-cli`. The E2E runs on a **macOS test destination** (`RemoteRunnerE2ETests`
  is platform-agnostic); the on-device Bonjour handshake remains device QA (097).
- **The recording proxy is test infrastructure**, not a code path any real run
  takes — it exists so "the stream dropped" is a real severed socket and "was a
  DELETE sent?" is answered by watching the wire, keeping the worker itself pristine
  (the only worker change this task ships is the heartbeat).

## Files
Changed: `app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift` (liveness rewrite),
`app/TopOptKit/Sources/TopOptFlows/RunModel.swift` (freshness cue),
`app/TopOptKit/Tests/TopOptFlowsTests/RemoteRunnerE2ETests.swift` (new cases +
proxy-log assertion), `tools/topopt-worker/topopt_worker.py` (heartbeat).
Added: `app/TopOptKit/Tests/TopOptFlowsTests/RemoteLivenessUnitTests.swift`,
`tools/topopt-worker/e2e/` (`stub_cli.py`, `proxy.py`, `run_e2e.sh`,
`protocol_smoke.py`, `.gitignore`).

## Ceiling (named before building)
The redesign trades a simple wall clock for a small state machine (probe/reconnect/
dedup). The risk it introduces is a *degenerate* worker that answers `GET /jobs/{id}`
but whose `/events` never delivers — the client would keep reattaching (backoff-
capped) forever rather than fail, by deliberate choice: a job the worker reports as
running must never be killed from the iPad. That is the correct bias (never destroy
the Mac's work); it is called out here so a future maintainer knows it is a choice,
not an oversight.
