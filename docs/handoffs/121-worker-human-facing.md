# 121 — TopOptWorker becomes human-facing: job queue, multi-job visibility, notifications

Builds on **097** (LAN offload Tier 2: the Python worker + the macOS menu-bar
supervisor app), **101** (remote-run liveness: heartbeat, reconnect/dedup,
`RemoteJobStore` + `remoteReattachRunner`), and **119** (cold-launch re-attach +
the optional-field decode-migration pattern). **No core, no bridge.** Territory:
`tools/topopt-worker` (Python), `tools/TopOptWorkerApp` (menu app), and the app's
`RemoteRunner.swift` / `RunModel.swift` / `AppModel.swift` / `RootView.swift` + tests.

Handoff number: **121** — checked `docs/handoffs/` (highest was 120) and open PRs
(only #146, another lane) when this lane started, so 121 was free. A concurrent
lane's `121-interaction-visual-round-4.md` later appeared in the shared worktree —
a **routine cross-lane number collision**; the maintainer deconflicts at merge (one
becomes 122). Kept this lane internally consistent at 121 (code comments included)
rather than blind-renumbering across a shared checkout. Cross-lane collision with A3
(full-result serialization) is also expected — A3 also touches the worker +
`RemoteRunner`; this lane was sequenced to land after it. Built against current
`main`; nothing here depends on A3's fields.

**Shared-worktree note:** this checkout also carried another lane's uncommitted edits
(DesignBox / ForceModel / OrbitCamera / WorkspacePlaceholder / … + their tests). Those
are **not** part of this lane — commit only this lane's files (worker, menu app,
`RemoteRunner` / `RunModel` / `AppModel` / `RootView`, the new tests + docs).

---

## The incident (the reproduction case)

Submit a run, then submit a second before the first finishes. Two bad things used to
happen: (1) the worker **spawned a competing solver**, so both runs got *slower* —
solves are memory-bandwidth-bound (113: 127 GB/s *shared*, matvec gather-bound at
~35 % of STREAM), so two-at-once contend for the bus and neither wins; and (2) the
iPad's **single-slot** `RemoteJobStore` **overwrote the first job's record with the
second**, orphaning the first run (no re-attach path — the exact 119 failure, now
triggered by ordinary use, not a Jetsam kill). The worker was a one-job tool wearing
a multi-job hat.

---

## What shipped

### 1. Worker job queue (the correctness fix) — `topopt_worker.py`

A `Scheduler` owns the job table + a FIFO queue and enforces `max_concurrency`
(**default 1**, `--max-concurrency`/`TOPOPT_MAX_CONCURRENCY`). A submitted job is
enqueued; a free slot promotes it immediately, otherwise it **queues**. On a running
job's terminal state the next queued job is promoted automatically. Rationale is
stated in code + here: parallel solves are *slower* on this hardware, so queueing is
faster, not merely tidier.

- **Single-job protocol is byte-identical**: a lone job starts at once and emits **no
  `queued` event** (`protocol_smoke.py` still passes verbatim).
- A queued job emits **one `queued` event** with its 1-based `position`, heartbeats,
  and streams normally once promoted.
- `DELETE` **dequeues** a queued job (no process to kill) or **kills** a running one;
  the running-job cancel still emits `cancelled` synchronously so the run thread
  never posts a spurious `error` for the killed child.
- The `Scheduler`'s launcher is **injected**, so the state machine is testable
  headlessly without spawning solves.

### 2. `GET /jobs` (additive) + project names

Lists **every** known job: `id, project, state (queued/running/done/error/
cancelled), paused, rung/rungs/iter, position, created_at/started_at/finished_at`,
plus `{max_concurrency, running, queued}`. `POST /jobs` now accepts a `project`
name (multipart field or a `project`/`project_name` key in job.json). `GET
/jobs/{id}` keeps a `status` alias of `state` for the 101 liveness probe.

### 3. Menu-bar app — job **list**, per-job actions, notifications

`WorkerSupervisor` no longer infers one job from stdout; it **polls `GET /jobs`**
(2 s) — the single source of truth. The menu shows a **Jobs** section (name ·
state · rung/iter · started) with a per-job submenu: **Pause/Resume**, **Move to
front** (queued only), **Show in Finder**, **Cancel/Remove from queue**; and a
**Recent** section (completions, newest first) with **Show in Finder**. On a watched
job's transition into `done`/`error` it posts a **`UserNotifications`** banner
(project + outcome); clicking reveals the job's workdir. Keep-awake is now driven by
the polled "any running job", not stdout. Settings gained a **Queue** stepper
(`--max-concurrency`) and a **Completion webhook** field.

### 4. Webhook → phone (scoped honestly) — `--webhook-url`

On any terminal state the worker POSTs a small JSON `{job, project, state, summary,
worker_version}`, best-effort on a daemon thread (a down webhook never affects the
run). Documented recipe: an **ntfy.sh** topic URL for a free, zero-infra phone push
(the worker sends a `Title: TopOpt` header). **Explicitly out:** running our own
push/email service — credentials + delivery infra we don't want to own, and the iPad
already gets in-app notice via re-attach. Said plainly in README + the menu app.

### 5. iPad **multi-slot** `RemoteJobStore` + re-attach **list** + local notify

`RemoteJobStore` is now multi-slot (keyed by jobID under `…v2`): a second submit
**upserts** instead of overwriting (the incident dies). `RemoteRun` clears **only
its own** record on resolution (`clearOwnRecord`), leaving siblings intact. A pre-121
single-slot record **migrates on decode** (the 119 pattern): folded in once, the
legacy `…v1` key dropped. The cold-launch banner becomes a **list** when >1 job is
outstanding (per-row Re-attach / Move-to-front / Dismiss + Dismiss all). A remote run
the app **observes finishing** — foreground or via the launch re-attach — fires a
**local notification** (`RunModel` now notifies when `outcome.computedRemotely`, not
only when backgrounded; a user-cancelled run stays silent). **Honest iOS limit,
stated:** local notifications require the app to have observed completion; true
remote push needs server infra and is out of scope.

### 6. Queue reorder — `POST /jobs/{id}/front`

From the menu app and the iPad re-attach list: move a **queued** job to the front so
a 10-minute *Balanced* check doesn't wait behind an 8-hour *Fine* run. Running jobs
are never preempted (`move_to_front` no-ops on a running job).

### 7. Pause / resume (stretch — shipped clean) — `POST /jobs/{id}/pause|resume`

**SIGSTOP**/**SIGCONT** the solver child: compute stops instantly, the cores come
back, nothing is lost. Honest notes carried into the UI: **memory stays resident**
(~2 GB for a *Fine* job), the worker **keeps heartbeating** (so the iPad shows the
stall via existing freshness dimming, not a fake failure), and a paused job's ETA
suspends. Signal semantics proved robust (see the E2E below), so it ships — not
Blocked-stopped. The `paused` flag is a separate axis from `state` (a paused job's
canonical state stays `running`, so the 101 liveness probe still reads it as alive).

---

## Tests + evidence

**Worker (pure-Python, no Xcode — `./e2e/run_e2e.sh queue`):**
- `e2e/queue_state_machine.py` — 10 headless cases over the real `Scheduler` with an
  injected launcher: submit×2 → one running/one queued; lone job gets no `queued`
  event; queued-cancel dequeues without touching the runner; **completion promotes**
  the next; the exact incident scenario; reorder; running-job reorder is a no-op;
  `max_concurrency=2` runs two. **All pass.**
- `e2e/queue_http_e2e.py` — HTTP-level `GET /jobs` **golden** (volatile fields
  normalized), the completion **webhook** against a stub receiver (state/project/job/
  summary), reorder, queued-cancel, and **pause/resume freezing compute** (a paused
  job's `iter` stops advancing, then resumes on SIGCONT). **All pass.**
- `e2e/protocol_smoke.py` (pre-existing) still passes verbatim — the single-job
  protocol is unchanged.

**iPad (`swift test`, headless):**
- `RemoteJobStoreMultiSlotTests` (new, 10) — round-trip, upsert-in-place,
  second-submit-doesn't-overwrite, per-job remove, **legacy single-slot migration**,
  and a relaunched `AppModel` surfacing all outstanding jobs + per-job/all dismiss.
- `RunModelTests` (+3) — a foreground **remote** completion notifies; a **local**
  foreground run still doesn't; a cancelled remote run stays silent.
- `ColdLaunchReattachTests` (pre-existing, unchanged) still green against the new
  multi-slot store (the computed `pendingReattach`/no-arg `dismissReattach` keep the
  single-banner contract).
- Full run: `RemoteJobStoreMultiSlotTests + ColdLaunchReattachTests + RunModelTests +
  AppModelTests + RemoteLivenessUnitTests + RemoteLongStreamMemoryTests` — **0
  failures.** `swift build` clean; the menu app `xcodebuild` **BUILD SUCCEEDED**.

**QA (device — the maintainer's two-job scenario):**
1. Start the worker (menu app). Submit a run for project **A** (e.g. *Fine*), then a
   run for project **B** (*Balanced*) before A finishes.
2. Menu app **Jobs** shows A *Solving* and B *Queued · position 1*; the iPad's next
   launch shows **both** in the re-attach list (no overwrite). Optionally tap **Move
   to front** on B.
3. A completes → macOS **notification** ("A — optimization finished"), click reveals
   A's workdir; **B starts automatically**.
4. Optional: pause A mid-run → its `iter` stops in the list, cores freed; resume →
   it advances again. Optional: set an ntfy.sh webhook and confirm the phone push.

---

## Notes / non-goals

- **A3 collision:** A3's full-result serialization also touches the worker +
  `RemoteRunner`; expect a merge. This lane added fields (queue/`GET /jobs`/webhook)
  and a `computedRemotely` notification gate — no change to the report/mesh transfer
  A3 owns.
- **In-session multi-job UI on iPad** stays the re-attach list; the app remains
  single-active-project *in session* (each project drives one `RunModel`). The
  multi-slot store + list is the visibility surface, which is what the incident
  needed.
- The menu app's new files were folded into the existing `WorkerSupervisor.swift` /
  `MenuContent.swift` / `TopOptWorkerApp.swift` to avoid hand-editing the
  hand-authored `project.pbxproj` (no `PBXFileSystemSynchronized` group).
