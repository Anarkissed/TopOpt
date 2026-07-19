# 117 — Per-iteration observability: the capture bundle (CSV + snapshots + version record + worker.log)

**Track:** core + CLI + worker. **Territory:** `/core/` (`src/simp`, `src/cli`,
`src/fea` getters, headers, tests), `tools/topopt-worker`. **NO app change, NO
solver-behavior change.** **Builds on:** 106 (the 10-hour forensic diagnosis),
110/113 (warm-gate thermal contamination), the trajectory-extrapolation ask.

## Why (the debt this pays — cite 106/110/113)

Three separate incidents all had the same root cause — **the run wrote no
per-iteration record to disk**:

1. **106** — the "10+ hour" Fine·128³ design-box run left *nothing* per-iteration
   on disk, so its cost had to be forensically rebuilt from **three STL mtimes**;
   iters/rung was only *bounded*, never known. 106 §5 asked the next run to close
   exactly this gap (a per-iteration CSV, a worker.log tee, a version stamp).
2. **110/113** — the 64-scale warm-start gate's **wall-clock was thermally
   contaminated** (self-weight warmA ran *slower* despite 19% fewer iters, purely
   from ~1 h of sustained load on the fanless-adjacent mini) and **nobody could
   tell until after**. A durable per-iteration wall-timestamped trace makes
   thermal drift visible *during* a run, not in hindsight.
3. **Trajectory extrapolation** needs **per-iteration density fields as data** —
   which never existed.

Observability is the one fix for all three. This task ships it.

## What shipped (four deliverables)

### 1. Per-iteration CSV — `out/iterations.csv` (default ON for CLI runs)

It is *observability, not solver behavior*, so it defaults ON for CLI runs;
`--no-iteration-csv` disables it. Written **incrementally, append+flush per row**
(crash-safe: a manual cancel — the 106 case — leaves every completed iteration on
disk). ~60–90 B/row, <80 KB for a full 4-rung production run.

**Schema (pinned by the golden test `test_observability`):**

```
rung,iter,wall_ms,compliance,achieved_vf,plateau,cg_iters,cg_multigrid
```

| column | meaning |
|---|---|
| `rung` | 0-based ladder index |
| `iter` | 1-based iteration within the rung (monotone) |
| `wall_ms` | wall-clock **epoch milliseconds** when the row was written — the durable timestamp 106 had to reconstruct from mtimes |
| `compliance` | objective of the analysis density at the START of the step (`%.10g`) |
| `achieved_vf` | achieved continuous (physical) volume fraction after the step |
| `plateau` | MMA objective-plateau detector verdict this iter (0/1); the iter it first reads 1 is the plateau-stop iter |
| `cg_iters` | CG iterations of this step's penalized solve |
| `cg_multigrid` | 1 if MG-CG ran, 0 if it fell back to Jacobi-CG |

The data is surfaced from the optimizer by a new **read-only** per-iteration hook
`SimpOptions::observe` (simp.hpp), forwarded with the rung index by
`MinimizePlasticOptions::on_iteration` (pipeline.hpp), and written by the CLI
(`run_job`). `achieved_vf` is the same value recorded in
`SimpOptimizeResult::history`; `plateau` is the exact `stage_should_stop`
predicate for MMA; `cg_iters` is `SimpCompliance::cg.iterations`.

### 2. Density snapshots — `out/snapshots/*.f16` + `.json` (opt-in, default OFF)

`--snapshots` turns them on. Captured **every N iterations (default 10) + every
rung boundary + terminal**, as the physical density field in **float16 raw**
(`snap_rung<r>_iter<NNNN>[_boundary].f16`, little-endian uint16, x-fastest grid
order) plus a tiny JSON sidecar (`dims`, `spacing`, `origin`, `rung`, `iter`,
`boundary`, `voxels`, `dtype`, `order`).

**Size math, stated honestly.** One snapshot of the real **5.4M-voxel** domain is
`5.4e6 × 2 B ≈ 10.8 MB`. A **500-iteration run at N=10 ≈ 50 snapshots ≈ 550 MB**.
Hence default-OFF and a **per-job cap with oldest-eviction** (`--snapshot-cap`,
default 40 ≈ ~430 MB worst case): once the retained **per-iteration** snapshots
exceed the cap the oldest is deleted; **rung-boundary snapshots are never
evicted** (they are the terminal/per-rung designs). Round-trip test
(`write→read→max abs error within f16`, ≤ 5e-4 over [0,1]) in both
`test_observability` and `test_observability_capture`.

The raw field is fed by `SimpOptions::density_observer` (the raw-field sibling of
`keyframe`); the per-iteration mask-pin COPY is built **only when a consumer is
attached**, so the default path pays no copy and is byte-identical.

### 3. Version record — `out/run_info.json` (always, on the CLI path)

The 113 lesson: **never again reconstruct "which build ran this" from
inference.** The CLI stamps its fingerprint + a config echo of the ACTUAL run:
`solver`, `galerkin_block_cache`, `mixed_precision`, `matfree_threads` (all read
from the live matrix-free state via new read-only getters
`fea_matfree_thread_count()` / `…_galerkin_block_cache_enabled()` /
`…_mixed_precision_enabled()`), `warm_start_inherit`/`warm_start_coarse`,
`projection`, `min_feature_mm`, `ladder`, `margin_stop`, `infill_percent`,
`has_design_box`, `load_source`, `resolution`, `material`, `cli_version`,
`created_wall_ms`, and the capture config. Assembled *after*
`configure_production_options` / `build_production_loadcase`, so it echoes the
real config, not the defaults.

### 4. Worker — `worker.log` in the job workdir (rotation + retention)

`topopt-worker` now tees the child's **stdout AND stderr**, **timestamped** (ISO
wall-clock + `stdout`/`stderr`/`meta` tag), to `<workdir>/<job-id>/worker.log`.
**Rotation:** at `TOPOPT_WORKER_LOG_MAX_BYTES` (default **8 MB**) it rotates to
`worker.log.1` (`TOPOPT_WORKER_LOG_BACKUPS`, default 1), bounding the log to
`~(1 + backups) × MAX` so a long run can't fill the disk. (CLI stdout is ~1 short
line/iteration, so a real run is far under the cap; the cap is the backstop.) The
tee is best-effort — a log IO failure never breaks the compute path. The SSE
protocol is untouched.

## THE ONE RULE (observability edition) — proven

**Designs are byte-identical with capture on or off.** Every hook is a pure
observer: it reads the per-iteration state (and, for snapshots, copies a pinned
field) but **never mutates the design** `x`. `test_observability_capture` runs the
real `minimize_plastic` twice — capture ON vs OFF — and asserts the physical
density, design variable and compliance of every rung are **byte-identical**
(`memcmp`), while also checking CSV rows == total iterations, the schema parses,
`on_iteration` fires once per iteration, and the terminal boundary snapshot
round-trips within f16.

## Overhead — measured (thermal protocol per 113)

Measured on this Linux CI box on a small cantilever fixture (30 MMA iters × 2
rungs), **min over 5 repeats** (min is thermal-robust — throttling only inflates
times, so the fastest run is the least-contaminated). Absolute times are this
box's, not the M2 mini; the **ratio** is the machine-independent signal:

```
576-voxel fixture, 30 MMA iters x 2 rungs, min over 5 reps:
  capture OFF        : 1.0396 s
  CSV only           : 1.0357 s   (-0.37%)   <- below run-to-run noise
  CSV + snapshots    : 1.0311 s   (-0.81%)   <- below run-to-run noise
```

The overhead is **below the run-to-run noise floor**: with capture on the min-of-
reps landed *marginally faster* than off, i.e. the added work is smaller than the
~1% variance between repeats — comfortably under the <1% target. Mechanically the
CSV path is a null-check + O(iters) plateau recompute + one flushed row per
iteration, and the snapshot path adds a per-iteration pinned-density copy
(O(voxels)) + a ~10.8 MB f16 write every N. At production scale (5.4M voxels,
~90 s/iter) the pin-copy is the largest observer term (~43 MB memcpy ≈ 5-10 ms ≈
~0.01% of the iter) and the f16 write is amortised over N; both stay far under 1%.
Default N=10 is retained. (The measurement uses the fast default JacobiCG so
iterations are cheap — a *conservative* ratio, since a cheaper solve makes the
fixed observer cost look relatively larger, not smaller.)

## Tests / gates

- **`observability`** (unit, always-built, no Eigen): float16 codec round-trip,
  the **CSV schema golden** (byte-exact header + rows), snapshot write/read
  round-trip, `SnapshotCapture` cadence + cap eviction (boundaries retained),
  run-info JSON content.
- **`observability_capture`** (Eigen-gated): THE ONE RULE byte-identity on the
  real driver + the CSV/snapshot end-to-end path.
- Worker `RotatingLog` verified (rotation caps disk, keeps 1 backup, timestamps
  lines); worker `py_compile` clean.
- Full existing suite green (no regression — all hooks default-null / gated).

## Coordination / provenance

- **Handoff number:** `docs/handoffs/` topped at **113**; **114** is the next free
  number (memory notes of larger values are PR numbers).
- **Do NOT run concurrently with the projection task** — both touch
  `minimize_plastic`. The warmA-flip task (production.cpp only) is fine in
  parallel. This task did not touch `production.cpp`.
- **No app change, no solver-behavior change, no Gate-V2 change.** ARCHITECTURE.md
  unmodified. Every new option/field is additive and default-absent (the same
  opt-in discipline as min_feature_mm==0 / infill==100 / warm_start_*).

## Files touched

- `core/include/topopt/simp.hpp` — `SimpIterationObservation`, `observe`,
  `density_observer`.
- `core/src/simp/simp.cpp` — invoke the two hooks in both optimize loops;
  `observe_plateau` helper.
- `core/include/topopt/pipeline.hpp` — `DensitySnapshotEvent`, `on_iteration`,
  `on_density_snapshot`.
- `core/src/simp/minimize_plastic.cpp` — forward the hooks (with rung context +
  rung-boundary snapshot); clear them on the coarse pre-solve.
- `core/include/topopt/observability.hpp` + `core/src/simp/observability.cpp` —
  the float16 codec, `IterationCsvWriter`, snapshot writer + `SnapshotCapture`,
  `RunInfo`. New base-library TU.
- `core/include/topopt/fea.hpp` + `core/src/fea/matfree.cpp` — read-only matfree
  getters for the version record.
- `core/include/topopt/job.hpp` + `core/src/cli/run_job.cpp` — `RunObservability`,
  run_info + CSV + snapshot wiring in `run_job`.
- `core/src/cli/main.cpp` — `--no-iteration-csv` / `--snapshots` /
  `--snapshot-every` / `--snapshot-cap` flags; fingerprint into run_info.
- `core/CMakeLists.txt` — build observability.cpp + register both tests.
- `tools/topopt-worker/topopt_worker.py` + `README.md` — `RotatingLog` tee.
- `core/tests/unit/test_observability.cpp`,
  `core/tests/validation/test_observability_capture.cpp` — new.
