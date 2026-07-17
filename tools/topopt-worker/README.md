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
`--host`, `--port`. `--materials`/`--rules` are optional — omit them to use the
values compiled into `topopt-cli`.

## Security

**No authentication.** This is a single-user tool for a trusted LAN. Bind it to
your local network only and do **not** expose it to the internet. If you need to
restrict it further, bind `--host` to a specific interface address. Adding a
shared-secret header is a small change if the network is not trusted.

## API

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/jobs` | multipart `step` (STEP/STL file) + `job` (job.json). Runs `topopt-cli` in a per-job temp dir. → `{"job_id": "..."}` |
| `GET`  | `/jobs/{id}/events` | Server-Sent Events: `progress`, `variant`, `log`, `done`, `error`, `cancelled`. Replays from the start on connect. |
| `GET`  | `/jobs/{id}/result` | `application/zip` of the job's output directory (report + meshes). |
| `GET`  | `/jobs/{id}/files/{name}` | a single artifact — used to fetch each variant mesh as its `variant` event arrives. |
| `DELETE` | `/jobs/{id}` | cancel (kills the subprocess). |
| `GET`  | `/health` | `{ok, cli_version, fingerprint, worker_version, active_jobs}`. |

### Events

The worker parses `topopt-cli` stdout, which streams real checkpoints (the CLI
was given `emit_progress`; see `core` `run_job`):

```
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
- **Cancel:** `DELETE /jobs/{id}` kills the subprocess and emits `cancelled`.
