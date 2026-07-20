# 119 — Cold-launch remote re-attach + long-stream memory audit

Builds on **101** (remote-run liveness: progress-based watchdog, reconnect/dedup,
`RemoteJobStore` + `remoteReattachRunner` shipped; **cross-relaunch UI re-attach was
the documented deferred sub-scope**) and **097** (LAN offload Tier 2). **No core, no
bridge.cpp, no worker/CLI.** Territory: `RemoteRunner.swift`, `RunModel.swift`,
`AppModel.swift`, `RootView.swift`, + tests.

Handoff number: **119** — checked `docs/handoffs/`, highest was 118, so first free
is 119.

The IPv6 dual-stack worker patch is a separate ten-liner the maintainer holds (not
touched here).

---

## The incident (the promotion to urgent)

A **7-hour** remote run's client was **Jetsam-killed** overnight (debugger-attached,
so iOS never suspended it and reclaimed it under memory pressure). The Mac finished
the job **correctly** — but the relaunched app had **no UI path back to it**. The
result was recoverable only by digging in the worker's workdir. Two gaps:

1. **No cold-launch re-attach.** 101 persisted the live job (`RemoteJobStore`) and
   shipped `remoteReattachRunner`, but **nothing read the record on launch** — the
   relaunched app never offered to reconnect.
2. **The long-stream client-retention path was unproven.** What does the client hold
   across a multi-HOUR stream? Never measured.

---

## Part 1 — Cold-launch re-attach

### What shipped
- **`PersistedRemoteJob`** (`RemoteRunner.swift`) gained three **optional** fields —
  `submittedAt`, `projectID`, `projectName` — so a relaunched app can (a) date the
  banner and (b) reopen the owning project. They're optional and the `.v1` store key
  is unchanged, so a **pre-119 record still decodes** (test:
  `testPre119RecordStillDecodes`). `RemoteRun.run()` now saves them; on a **re-attach**
  it **preserves the original `submittedAt`** from the stored record so the banner age
  never resets to "now".
- **`RunRequest.projectID`** (`RunModel.swift`, optional, default nil) carries the
  owning project id so a remote run persists which project it belongs to.
  `AppModel.makeRunRequest` sets it. Not part of the optimization; unused by the local
  bridge.
- **`AppModel` launch detection** (`AppModel.swift`): on init,
  `pendingReattach = RemoteJobStore.load()`. Because `RemoteRun` clears the record on
  any worker-terminal resolution or user cancel, a **leftover record means the app
  died mid-run** — exactly the case to offer.
- **`AppModel.reattach()`** reopens the owning project (via `projectID → recents →
  open`) and sets `project.run.runner = remoteReattachRunner(config, jobID:)`, then
  starts it. The worker replays `/events` from index 0 (deduped by the 101 machinery):
  a **still-running** job resumes live; a job that **COMPLETED while the app was gone**
  has its full outcome replayed and **lands directly on results**; a **dead/unknown**
  job fails with the honest 101 worker-unreachable message.
- **Clear semantics (the 101 rule):** `reattach()` does **not** clear the record — a
  client-side failure must never destroy the Mac's job, so a failed re-attach can be
  retried next launch. **`dismissReattach()` is the only user path that clears it.**
  (A worker-terminal resolution clears it from inside `RemoteRun`, unchanged.) If the
  owning project was deleted, re-attach says so honestly and leaves the record for a
  Dismiss.
- **The banner** (`RootView.swift`): a non-blocking, top-anchored panel (no scrim —
  the user can ignore it), "Run still on your Mac" + `AppModel.reattachBannerText(…)`,
  with **[Dismiss] / [Re-attach]**.

### Injection seams (for headless tests)
`AppModel.init` gained `remoteJobDefaults: UserDefaults = .standard` (scratch suite in
tests) and `reattachRunnerFactory` (nil → production `remoteReattachRunner`; a stub in
tests, since the real one streams the worker). The banner copy + age bucketing are
**pure statics** (`reattachBannerText`, `relativeAge`), unit-tested without a view or
the wall clock.

---

## Part 2 — Long-stream memory audit

**Honesty up front:** a 7-hour run cannot be reproduced in-session. This was audited
by **code inventory** + a **synthetic long-stream test** (thousands of events,
asserting bounded retention). The signposts prove it on the **next** real long run.

### Retention inventory — what the client holds across a multi-hour stream

A 7-hour run emits **thousands** of `progress` events but only **~4** `variant`
events (the ladder). Per-run retention:

| Field | Kind | What / why | Bound |
|---|---|---|---|
| `deliveredCount` | `Int` | dedup high-water mark — an event **INDEX**, not the body | **O(1)** |
| `connIndex` | `Int` | per-connection replay cursor | O(1) |
| `buffer` | `Data` | un-parsed SSE tail; each `\n\n` frame removed once parsed | O(1 frame) |
| `seenMeshes` | `Set<String>` | variant **basenames** already emitted | O(ladder ≈ 4) |
| `streamed` | `[StreamedVariant]` | accepted variants' geometry, reused by final assembly | O(ladder ≈ 4) |
| `etaEstimator`\* | RunModel | EMA + `completedRungIters[]` | O(rungs ≈ 4) |
| `outcome`\* | RunModel | accumulated accepted variants | O(ladder ≈ 4) |

\* on the `RunModel` side of the same stream.

### Finding
**The dedupe was ALREADY index/basename-based** (`deliveredCount` + `seenMeshes`) — it
never retained full event bodies, so there was **no unbounded growth to fix there**.
The only per-run growth is the accepted-variant **meshes**, and those are bounded by
the **ladder (~4), not by run length or event count**. `progress` events — the
thousands — retain **O(1)** (a single `Int` high-water mark; the ETA estimator folds
each into an EMA and discards it).

### Decision (documented, not disk-backed)
Earlier-rung meshes are **kept in memory**. The results screen shows **every** accepted
rung simultaneously for comparison, so no rung is ever "superseded"; disk-backing ≤4
meshes would add fragility for no bounded win. `streamed` and `RunModel.outcome` each
hold a copy of the same ≤4 meshes for the run's life — a **known, bounded double-hold,
not a leak.** (The Jetsam kill was the overnight debugger attachment preventing
suspension, not a client leak — but the path is now proven bounded regardless.)

### What was added
- A **retention-audit block** in `RemoteRunner.swift` (the table above, in code).
- **Per-rung `os_signpost` memory checkpoint** (`memoryCheckpoint(rung:)`, fired from
  `emitStreamedVariant`): stamps `phys_footprint` (Jetsam's yardstick, via
  `residentFootprintBytes()` / `TASK_VM_INFO`) + this run's retained sizes at each rung
  boundary, as an `OSSignposter` event **and** an `os_log` line — so the **next** long
  run measures itself in Instruments or Console.

---

## Evidence

- **`swift test` (self-run, macOS, `--no-parallel`):** 591 executed, 1 skipped
  (E2E, gated on `TOPOPT_E2E=1`), **2 failures — both pre-existing and unrelated**:
  `ClearanceDerivationTests/testBoreHandlesMatchTheRenderedVolume` (bore handles:
  expected 3, got 2). Verified identical on a **clean baseline** (my source changes
  stashed + new test files removed → same 2 failures). It's keep-clear geometry, not
  this territory; flagged as a separate task. Everything I touched is green:
  `ColdLaunchReattachTests` (10), `RemoteLongStreamMemoryTests` (4),
  `RemoteLivenessUnitTests` (7), `RunModelTests`/`AppModelTests`/`ProjectModelTests`/
  `ProjectStoreTests`/`ResultsModelTests` (158).
- **Retention inventory table:** above (also in `RemoteRunner.swift`).
- **Synthetic long-stream bounded-memory test** (`RemoteLongStreamMemoryTests`):
  drives **5,000** progress events through the real SSE parse/dedupe delegate path and
  asserts `deliveredCount == 5000` while `streamed`/`seenMeshes` stay `0` and `buffer`
  drains to `0`; a **reconnect replay** of 3,000 events is fully deduped (no
  re-delivery, no growth); a split frame is buffered-then-parsed-once;
  `residentFootprintBytes()` returns a live value.

### Device-QA list (the maintainer's ~60 seconds against a live worker)
1. Submit a real remote run; force-quit the app mid-run; relaunch → the banner
   appears with the right project name + age + worker host.
2. **[Re-attach]** on a still-running job → the run UI resumes with live progress.
3. Let a remote run FINISH while the app is force-quit; relaunch → **[Re-attach]**
   lands directly on results (full outcome).
4. Re-attach with the worker off / job gone → the honest worker-unreachable sheet;
   the banner returns next launch; **[Dismiss]** clears it for good.
5. (Optional) trace a long run in Instruments and confirm the per-rung `remote-memory`
   signposts show a flat footprint.

---

## Not done / follow-ups
- The **real** re-attach against a live worker is device QA (above) — the headless
  suite stubs the runner (the real one streams the worker's `/events`).
- Pre-existing `testBoreHandlesMatchTheRenderedVolume` failure (keep-clear geometry)
  is out of territory — flagged as a separate task.
- IPv6 dual-stack worker patch: separate, maintainer's ten-liner.
