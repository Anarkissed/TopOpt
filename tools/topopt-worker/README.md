# topopt-worker — LAN compute offload

Run the topology optimizer on a **desktop** (e.g. a Mac Mini) and drive it from
the **iPad**. This is the only path to *Fine + design box* (~5.4M voxels): that
run's peak memory (~1.5–2 GB) is set by the iteration-0 build and recurs every
rung, so it does not fit the iPad's budget. On a desktop the cap does not exist.
(See `docs/handoffs/093-lan-offload.md`.)

The worker is a small, **stdlib-only** HTTP server that wraps the existing
`topopt-cli`. Because STEP 0 made `topopt-cli` produce the **same part** the app
produces (`configure_production_options` + `build_production_loadcase` in core),
a worker that shells out to `topopt-cli` returns exactly what the app would have
computed locally.

## Requirements

- Python 3.8+ (standard library only — no `pip install`).
- A built `topopt-cli` binary (from `core/`, with OCCT + Eigen).

## Run

```sh
# point the worker at your topopt-cli binary; bind to the LAN.
TOPOPT_CLI=/path/to/topopt-cli python3 topopt_worker.py --host 0.0.0.0 --port 8757
```

or

```sh
python3 topopt_worker.py --cli /path/to/topopt-cli --port 8757
```

Options (all have env fallbacks): `--cli`/`TOPOPT_CLI`, `--workdir`/
`TOPOPT_WORKER_DIR`, `--materials`/`TOPOPT_MATERIALS`, `--rules`/`TOPOPT_RULES`,
`--host`, `--port`, `--max-concurrency`/`TOPOPT_MAX_CONCURRENCY`, `--webhook-url`/
`TOPOPT_WEBHOOK_URL`. `--materials`/`--rules` are optional — omit them to use the
values compiled into `topopt-cli`.

On start the worker prints **one identity line** (handoff 124) naming its version,
the core `fingerprint` it serves, and its workdir, e.g.
`topopt-worker 1.1.0  ·  core b9d0a2fb03e4  ·  workdir ~/.topopt-worker` — so a
supervisor log answers "which worker is this?" without archaeology. If the port is
already taken it prints `port 8757 in use — is another worker already running?
(lsof -i :8757)` and exits `1` (no traceback).

## Job queue (handoff 121)

The worker is **human-facing**: more than one job can be submitted. Because solves
on this hardware are **memory-bandwidth-bound** (handoff 113 measured 127 GB/s of
*shared* bandwidth, and the matvec is gather-bound at ~35 % of STREAM), two solves
running at once contend for the same bus and **both** run slower — N parallel jobs
are *slower* than N sequential ones. So the default `--max-concurrency` is **1**: a
second submitted job **queues** behind the running one instead of spawning a
competing solver. This is faster, not merely tidier. Raise it only on hardware with
more memory channels, where the trade-off may flip.

- A **lone** job starts immediately and streams exactly as before — the single-job
  protocol is byte-identical (no `queued` event).
- A job that has to wait emits one **`queued`** event (with its 1-based `position`),
  keeps a heartbeat, and streams normally once promoted.
- `DELETE` on a **queued** job dequeues it (no process to kill); on a **running**
  job it kills the child (unchanged).
- `POST /jobs/{id}/front` moves a queued job to the front — a 10-minute *Balanced*
  check shouldn't wait behind an 8-hour *Fine* run. Running jobs are never preempted.

## Pause / resume (handoff 121)

`POST /jobs/{id}/pause` **SIGSTOP**s the running solver child — compute stops
instantly and the Mac's cores come back to you — and `POST /jobs/{id}/resume`
**SIGCONT**s it. Nothing is lost. Honest caveats: the job's **memory stays
resident** while paused (~2 GB for a *Fine* job), the worker keeps heartbeating (so
the iPad shows the stall via its existing freshness dimming, not a fake failure),
and a paused job's ETA suspends.

## Completion webhook → phone notification (handoff 121)

Set `--webhook-url` (or `TOPOPT_WEBHOOK_URL`) and the worker **POSTs a small JSON**
on every terminal state:

```json
{"job":"ab12…","project":"Bracket","state":"done","summary":"Bracket: 3 variants ready","worker_version":"1.1.0"}
```

**Two-minute phone notifications with [ntfy.sh](https://ntfy.sh)** (zero
infrastructure of ours): pick a hard-to-guess topic, install the free ntfy app and
subscribe to it, then point the worker at it:

```sh
python3 topopt_worker.py --cli /path/to/topopt-cli \
  --webhook-url https://ntfy.sh/topopt-bracket-7f3a
```

The worker sends a `Title: TopOpt` header, so the ntfy push is titled and its body
is the summary. Any plain webhook receiver works too. We deliberately do **not**
run our own push/email service — that means credentials and delivery infrastructure
we don't want to own, and the iPad already gets in-app notice via re-attach.

## Per-job artifacts on disk (handoff 114)

Each job runs in `<workdir>/<job-id>/` and leaves a durable record there, so a
run's history survives even if the iPad client dropped (handoff 106 had to
reconstruct a 10-hour run from three STL mtimes for lack of this):

- **`worker.log`** — the child's stdout **and** stderr, tee'd here **timestamped**
  (ISO wall-clock + a `stdout`/`stderr`/`meta` tag per line). It is **rotated**
  when it reaches `TOPOPT_WORKER_LOG_MAX_BYTES` (default **8 MB**) to
  `worker.log.1` (`TOPOPT_WORKER_LOG_BACKUPS` backups, default 1), so the log is
  bounded to ~`(1 + backups) × MAX` bytes and a long run can't fill the disk. CLI
  stdout is ~1 short line/iteration, so a full production run is far under the cap;
  the cap is the backstop.
- **`out/run_info.json`** — the CLI's version + config record (fingerprint,
  solver, warm/mixed-precision/thread flags, ladder, …); never reconstruct "which
  build ran this" from inference again.
- **`out/iterations.csv`** — the per-iteration trace (rung, iter, wall_ms,
  compliance, achieved vf, plateau state, CG iters). Default ON; the CLI's
  `--no-iteration-csv` disables it. ~80 KB for a full run.
- **`out/snapshots/*.f16`** — opt-in float16 density snapshots (CLI `--snapshots`;
  **default OFF** — ~10.8 MB each at 5.4M voxels). Bounded by a per-job cap.

`run_info.json`, `iterations.csv` and `snapshots/` live in `out/`, so they are
included in the `/jobs/{id}/result` zip and fetchable via `/jobs/{id}/files/{name}`.
`worker.log` is in the job dir (not `out/`), so it stays on the desktop.

## Security

**No authentication.** This is a single-user tool for a trusted LAN. Bind it to
your local network only and do **not** expose it to the internet. If you need to
restrict it further, bind `--host` to a specific interface address. Adding a
shared-secret header is a small change if the network is not trusted.

## API

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/jobs` | multipart `step` (STEP/STL file) + `job` (job.json). **Enqueues** a `topopt-cli` run. An optional `project` multipart field (or a `project` key in job.json) names it for the job list. → `{"job_id": "..."}` |
| `GET`  | `/jobs` | **list every known job** (handoff 121): `{jobs:[{id, project, state, paused, rung, rungs, iter, variants, position, created_at, started_at, finished_at}], max_concurrency, running, queued}`. `variants` (handoff 124) is the count of accepted variant meshes so far, for the menu app's History. The menu app + iPad read this instead of inferring from one stream. |
| `GET`  | `/jobs/{id}` | one job's row (plus a `status` alias of `state` for the pre-121 liveness probe). |
| `GET`  | `/jobs/{id}/events` | Server-Sent Events: `queued`, `progress`, `variant`, `log`, `done`, `error`, `cancelled`. Replays from the start on connect. |
| `GET`  | `/jobs/{id}/result` | `application/zip` of the job's output directory (report + meshes). |
| `GET`  | `/jobs/{id}/files/{name}` | a single artifact — used to fetch each variant mesh as its `variant` event arrives. |
| `POST` | `/jobs/{id}/front` | move a **queued** job to the front of the queue. |
| `POST` | `/jobs/{id}/pause` | **SIGSTOP** a running solver child (compute stops; memory stays resident). |
| `POST` | `/jobs/{id}/resume` | **SIGCONT** a paused solver child. |
| `DELETE` | `/jobs/{id}` | cancel: dequeue a queued job, or kill a running one. |
| `GET`  | `/health` | `{ok, cli_version, fingerprint, worker_version, active_jobs, queued_jobs, max_concurrency}`. |

### Events

The worker parses `topopt-cli` stdout, which streams real checkpoints (the CLI
was given `emit_progress`; see `core` `run_job`):

```
data: {"type":"queued","position":1}        # only if the job had to wait (handoff 121)
data: {"type":"progress","rung":0,"rungs":4,"iter":7}
data: {"type":"variant","vf":0.68,"achieved":0.6799,"margin":7384.3,"accepted":true,"mesh":"variant_068.stl"}
data: {"type":"done","returncode":0,"artifacts":["report.json","variant_068.stl", ...]}
```

`progress` fires once per optimizer iteration; `variant` fires as each accepted
rung completes, **and its mesh is already written** — the client fetches it from
`/jobs/{id}/files/{mesh}` immediately, so variants stream progressively rather
than batching at the end. These are **not** fabricated — if the CLI emits no
progress, the worker emits none.

### Version skew (correctness)

`/health` returns the core build `fingerprint` (the git commit of the core the
`topopt-cli` was built from). The app **must** compare this to its own core
fingerprint and **refuse** a mismatch: two cores that differ silently produce
different parts. This is the same divergence STEP 0 fixed, in a new costume.

## Example (curl)

```sh
# submit
curl -F "step=@part.step" -F "job=@job.json" http://desktop.local:8757/jobs
# {"job_id":"ab12..."}

# stream progress
curl -N http://desktop.local:8757/jobs/ab12.../events

# download results when done
curl http://desktop.local:8757/jobs/ab12.../result -o results.zip
```

A worked `job.json` (128³ design-box run) is in
`docs/handoffs/093-lan-offload.md`.

## Failure behavior

- **Worker unreachable / dies mid-run:** the subprocess is a child of the
  worker; if the worker dies, the OS reaps it. A completed run's events + files
  persist under `--workdir` until the process exits (in-memory job registry), so
  the result survives a dropped client connection.
- **iPad sleeps:** the SSE stream drops, but events are append-only and replayed
  from the start on reconnect, and `/result` works after completion — a finished
  run is never lost to a dropped connection.
- **Bad job / disk full / solver error:** `topopt-cli` exits non-zero; the
  worker emits an `error` event carrying the CLI's stderr diagnostic.
- **Cancel:** `DELETE /jobs/{id}` dequeues a queued job or kills a running one,
  and emits `cancelled`. When a running job ends, the next queued job is promoted
  automatically.

## Liveness heartbeat (handoff 101)

While a job runs, `/jobs/{id}/events` emits an SSE keepalive comment `: ping`
every `TOPOPT_HEARTBEAT_SECONDS` (default 20) whenever no real event is ready.
SSE comments are ignored by clients except as liveness, so the typed event stream
is unchanged — but the ping lets the iPad's inactivity watchdog tell "a Fine
iteration is just slow" from "the worker died", so a long-but-live run is never
mistaken for a hang. The client treats a dropped stream as recoverable (reconnect
+ replay-dedup) and only fails when the worker is genuinely unreachable — it never
`DELETE`s a job except on an explicit user cancel.

## E2E harness (`e2e/`)

`e2e/run_e2e.sh <case>` stands up this worker wrapping a protocol-faithful
`e2e/stub_cli.py` (and, for drop/observe cases, `e2e/proxy.py`) and runs the
`RemoteRunnerE2ETests` liveness cases against it: `slow_sparse`, `stream_drop`,
`worker_dies`, `cancel`, `offline` (+ the 097 controls). `e2e/protocol_smoke.py`
is a pure-Python, HTTP-level proof of the heartbeat, the reconnect replay, and
DELETE-only cancel — no Xcode needed. See `docs/handoffs/101-remote-run-liveness.md`.

The **handoff-121 queue** harness is pure-Python too (`./run_e2e.sh queue`):
- `e2e/queue_state_machine.py` — headless proof of the `Scheduler` state machine
  (submit×2 → one running, one queued; queued-cancel dequeues; completion promotes
  the next; reorder; higher concurrency).
- `e2e/queue_http_e2e.py` — HTTP-level `GET /jobs` **golden**, the completion
  **webhook** (against a stub receiver), reorder, queued-cancel, and pause/resume
  actually freezing compute (a paused job's `iter` stops advancing, then resumes).
See `docs/handoffs/121-worker-human-facing.md`.
