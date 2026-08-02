# Evidence — post-processing must reach the variants

Handoff: `docs/handoffs/2026-08-03-variant-postprocessing-fix.md`

## The maintainer's own run (defect 1, bar R1)

Read off his live worker (`/Users/nadim/.topopt-worker/95f4130119414636`, CLI
fingerprint `2b8b715fd347`) — not reproduced, not inferred.

| file | what it is |
|---|---|
| `r1_his_job.json` | the job document the app submitted: `minimize_plastic`, res 128, octet, **swept** grading (`cell_min_mm 4.602619931809993`, `cell_max_mm 16`), 8 include + 1 exclude region, **`skin: "rim"`** |
| `r1_receipt_038.json` / `_052` / `_068` | the three per-variant lattice receipts he attached |
| `r1_run_info.json`, `r1_loadcase.json` | written at run START, hence present |
| `r1_worker_out_listing.txt` | **the directory listing — no `report.json`, no `fields.bin`, no `design.bin`** |
| `r1_worker_log_bookends.txt` | launch line `16:07:49`; last progress `17:03:46 rung=3 rungs=4 iter=106`. The run was killed on its last rung. |

## Why the worker ended the run (§1b)

`r1b_why_the_worker_died.txt` — the Worker app never restarted (PID 74031, up since
Jul 22); only its Python child did (PID 16871, 17:04:20). The keep-awake assertion
for his job was released at 17:04:18 after 00:56:28 held, and 16:07:49 + 56:28 =
17:04:17. The 2 s gap to the new child is exactly `WorkerSupervisor`'s restart
backoff, which only runs on an UNEXPECTED exit. No crash report, no jetsam event.

**Which exception killed it is unrecoverable** — the worker's stdout+stderr were
drained into `_ = h.availableData` and the exit code was overwritten 2 s later.
That is defect 6, and it is fixed.

## The reproduction and the fix (bars R2 / R3 / P4)

`r2_r3_retain_dies_before_after.txt` — the new `retain_dies` E2E case (real
`RemoteRun`, real worker, real HTTP), with the eager retention producers disabled
(BEFORE) and enabled (AFTER). Reproduce with:

```bash
./tools/topopt-worker/e2e/run_e2e.sh retain_dies
```

## The forecast (bars F1–F5, V2, P2)

`f3_forecast_vs_run.txt` — five configurations of the same design, forecast vs the
real `lattice_variant` run. Every count EXACT, including a configuration that
forecasts zero lattice. Per-reason counts, include-region-void counts and the
evaluated counterfactuals are all in the table.

`f3_forecast_A_auto_w042.json` … `f3_forecast_E_include.json` — core's own forecast
documents, verbatim. `LatticeForecastTests` runs against these files.

## The boundary (bar S2)

`s2_skin_rim_vs_diagrid.txt` — `none` / `rim` / `diagrid` on the same design.

## The bars that are arithmetic (P5 / P6)

`p5_byte_identity.txt`, `p6_determinism.txt`.
