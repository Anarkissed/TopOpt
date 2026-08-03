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

**The forecast's CALL SITE was missing until the review caught it** (§10f, blocker
1): every layer existed, every test passed, and nothing invoked it, so the user saw
nothing. `LatticeForecastCallSiteTests` now drives the invocation itself — the tests
above could not have caught it, because each of them calls the parser or the copy
directly, which is exactly what production did not do.

## The boundary (bar S2)

`s2_skin_rim_vs_diagrid.txt` — `none` / `rim` / `diagrid` on the same design.

## The bars that are arithmetic (P5 / P6)

`p5_byte_identity.txt`, `p6_determinism.txt`.

---

# FOLLOW-UP · work the ladder while the ladder runs

## Bar 1 — on-device re-certification at 128³

`bar1_ondevice_recert_128.txt` — `topopt-cli analyze` (the same
`topopt::analyze_fixed_design` call `bridge.cpp:1297` makes in-process) on the
maintainer's OWN `variant_038.stl` at his 128³, under his declared load case:
**101.2 s wall, 310 MB peak RSS / 369 MB peak footprint, ACCEPTED, converged**,
reproducing his run's recorded margin (3291 vs 3290.86).

Reproduce:

```bash
topopt-cli analyze analyze128.json --out out128 \
  --mesh ~/.topopt-worker/95f4130119414636/out/variant_038.stl \
  --materials core/src/materials/materials.json
```

## Bar 2 — contention · **NOT MEASURED, and the 1.09x is WITHDRAWN**

`bar2_contention.txt` now records a withdrawal, not a number. The review asked for
the control's ACTUAL value instead of an asserted 1.00x; the raw data was gone, so
the measurement was re-run on a quiet machine, unrounded — and it does not hold up.

* the two runs do **bit-identical work** (compliance / `cg_iters` / `matvecs` all
  170/170), so the method is sound and the ratios are pure timing;
* control **0.9919**, effect window **0.9411** — *below* the control, i.e. run B ran
  faster while carrying the extra workload, which no contention can cause;
* over the same 170 indices run B carried an extra 90.6 s of re-certification and
  still finished **41.5 s faster** (B/A **0.8953**). Run-to-run offset ~10%, larger
  than the 9% claimed and opposite in sign.

One A/B pairing cannot resolve the effect. No number is claimed in its place. It
costs nothing here: the maintainer's app and worker are different computers, so
one-machine contention is structurally zero for him.

`bar2_contention_discarded_designs.txt` records **two earlier designs that were
wrong**, and why — kept deliberately, because silently dropping a measurement is how
a wrong number gets published later.

* **Design 1** compared iterations-per-window before vs after. A ladder's iteration
  rate is not constant across RUNGS, so it compared ladder phases. It would have
  reported a ~5x "speedup" from adding a second workload.
* **Design 2** fixed that with a single-rung job and the worker's timestamped log —
  and was still wrong, because per-iteration wall is not stationary WITHIN a rung
  either. Its `after` window came out slower than its `during` window in **both**
  runs, including on a quiet machine, which rules out background load and points
  straight at the ramp.
* **Design 3**, matched indices across two runs, is the one reported — correct in
  construction, and the re-run confirms it compares identical arithmetic. It is
  simply not powerful enough for a single pairing.

The re-run also strengthens why 1 and 2 were hopeless: the within-rung ramp is not
even consistently SIGNED. At res 96 it climbs (0.41 -> 2.54 s/iter); at res 64 it
FALLS (3092 -> 2138 ms/iter, 0.69x).

## Bars 3 and 4 — per-rung artifacts, and an interrupted ladder

`core/tests/validation/test_design_stream.cpp` (21 checks). Run it:

```bash
cmake --build core/build --target test_design_stream && core/build/test_design_stream
```

It asserts, from OUTSIDE the process: at the instant rung N streams, `design.bin`
AND `fields.bin` each hold a block for **rung N's own** volume fraction; the two
containers stay in lockstep; and a ladder ABANDONED after rung 1 still leaves rung 1
fully post-processable with no `report.json` (so it really is the interrupted case).
With the per-rung field flush disabled, 5 of those checks fail.
