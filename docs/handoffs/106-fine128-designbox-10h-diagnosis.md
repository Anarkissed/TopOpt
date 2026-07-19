# 106 — Fine·128³ design-box "10+ hour" remote run: expected physics, not a defect (READ-ONLY diagnosis)

**Status:** Diagnosis complete. **No code changed** — this is measure-and-advise only.
**Verdict:** **WITHIN-EXPECTED.** The run was healthy; ~10–12 h is the honest cost of a
4-rung ladder over a ~4.8–5.4 M-voxel Fine + design-box domain on an 8-core Mac mini.
The run **ended by user cancel, not by the old wall-clock timer** — proven from the
surviving artifacts. The real, fixable pain is (1) the Mac being unusable while it solves
and (2) that **the run wrote no per-iteration record to disk**, so this diagnosis had to be
reconstructed from three STL mtimes.

Handoff-number note: `docs/handoffs/` on this branch tops at 104; three in-flight worktrees
each claim **105** (orientation-gizmo, keep-clear-phase-b, stl-export). Next collision-free
number is **106**. (Memory notes referencing "119"/"125" are **PR** numbers, not handoff
numbers.)

The job under investigation: `~/.topopt-worker/6cbeb150242a464e/` (a **hidden** dot-folder;
`TopOptWorkerApp` does not override the worker's default `~/.topopt-worker`).

---

## 0. ERA CHECK — how the run ended (do not blame the solver, do not blame the timer)

**Client/worker versions are not recorded in any surviving artifact.** `job.json` carries no
version field; there is no `worker.log`; and `WORKER_VERSION` is a hard-coded `"1.0.0"`
string ([topopt_worker.py:52](tools/topopt-worker/topopt_worker.py#L52)) that does not change
between liveness eras, so even a captured `/health` snapshot could not date the worker. The
**client** was stale per the task premise (pre-PR-125: fixed `timeout = 28800` used as *both*
`timeoutIntervalForRequest` **and** `timeoutIntervalForResource`, plus
`doneSignal.wait(28800)` → `cancelRemote()` → HTTP `DELETE` → `job.proc.kill()`; confirmed by
reading the pre-125 tree at `167ae13^1:RemoteRunner.swift` lines 63/171/272–273/360). PR-125's
own header comment names this incident: *"…caps an SSE task's TOTAL lifetime even while data
flows. That killed a real 128³ run at exactly 3600s. Gone."*
([RemoteRunner.swift:23-27](app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift#L23)).

**Did either timer kill THIS run? No — decisively.** A `DELETE` kill is SIGKILL and immediate,
and the CLI writes a rung's mesh **only at that rung's completion**. Yet:

| Wall-clock cap | Would fire at | Rebutting artifact |
|---|---|---|
| 3600 s (1 h) | 05:25:49 | all three variants were written **after** it (07:04 / 10:05 / 13:05) |
| 28800 s (8 h) | 12:25:49 | **variant_038 (rung 3) written 13:05:39 — 40 min PAST the 8 h cap** |

A process killed at 12:25 cannot produce a *completed* rung-3 mesh at 13:05. So the 8 h timer
did not fire (the iPad app was almost certainly backgrounded/disconnected long before 12:25, so
its `run()` wait-thread was not even executing; **the worker keeps solving regardless of the
client — that is the whole SSE-replay design**). The 1 h cap likewise did not fire.
**Conclusion: the maintainer cancelled manually after seeing the 10+ h ETA, some time after
13:05:39.** Never attribute this to solver slowness *or* to the timer.

**Corroboration — three attempts at the same part.** The geometry is byte-identical
(`md5 8e1dcd22…`) across three workdirs:

| Attempt | Started | Output | Reading |
|---|---|---|---|
| `d81e969f…` | Jul-17 21:16 | **empty `out/`** | killed before rung 1 (~2.6 h) could finish |
| `8b8dae16…` | Jul-17 22:17 | **empty `out/`** | ditto, ~1 h after the first |
| `6cbeb150…` | Jul-18 04:25 | 3 variants | the long run; manual cancel |

The two empty-`out/` attempts are **consistent with** (not proof of) a ~1 h wall-clock/`DELETE`
kill: rung 1 needs ~2.6 h, so a 1 h cap guarantees an empty `out/`. The 04:25 attempt escaped
that (app disconnected → no wait-thread) and ran 8 h 40 m to a manual cancel.

---

## 1. THE RUN'S OWN NUMBERS (reconstructed from STL mtimes — the only durable record)

The per-iteration `PROGRESS rung=… iter=…` and per-rung compliance trace **never touched
disk** (see §5). The three accepted-variant STL mtimes are rung boundaries. Variant naming is
`variant_<vf×100>.stl` ([run_job.cpp:42-49](core/src/cli/run_job.cpp#L42)); the production
ladder is **`{0.68, 0.52, 0.38, 0.26}` — 4 rungs**
([production.cpp:36](core/src/simp/production.cpp#L36)):

| Event | Timestamp | Δ (this rung) | Rung / vf |
|---|---|---:|---|
| job start (POST) | 04:25:49 | — | — |
| `variant_068.stl` | 07:04:59 | **2 h 39 m 10 s** (9 550 s) | rung 1, vf 0.68 (incl. STEP import + voxelize + iter-0 build) |
| `variant_052.stl` | 10:05:14 | **3 h 00 m 15 s** (10 815 s) | rung 2, vf 0.52 |
| `variant_038.stl` | 13:05:39 | **3 h 00 m 25 s** (10 825 s) | rung 3, vf 0.38 |
| `variant_026.stl` | — never | — | **rung 4, vf 0.26 — in progress at cancel** |

**Seconds / iteration.** Cap is `max_iterations = 200`, MMA with plateau termination
(window 10 / tol 1e-3) ([simp.hpp:390,407](core/include/topopt/simp.hpp#L390)). The exact
iters/rung for this run is **unrecoverable** (no trace), so bound it from the steady-state
~10 820 s rungs:

| iters/rung assumption | s/iter |
|---|---:|
| ran to the 200 cap | **54 s** |
| plateau ~140 (task's planning figure) | **77 s** |
| plateau ~120 | **90 s** |

i.e. **~54–90 s/iter, centred ~70–77 s** (subtract ~1–3 min/rung for the `smooth_factor=2`
tricubic-resample + marching-cubes export that produced the 20–25 MB STLs, so pure-solve
s/iter is a touch lower). Rung 1 being *shorter* than rungs 2–3 despite one-time setup is
expected: vf 0.68 sits nearest the 0.65 infill start, so it needs the fewest MMA iterations;
lower rungs remove more material and iterate more.

**Total wall-clock projection.** 3 rungs = **8 h 40 m**. Rung 4 (vf 0.26, most material
removed → likely the longest, ≥ 3 h) → **full 4-rung ladder ≈ 11.7–12.2 h**. The maintainer's
"10+ h" ETA at ~13:05 (¾ done, 8.7 h elapsed) was accurate.

---

## 2. THE SCALING EXPECTATION — verdict: WITHIN-EXPECTED (not anomalous)

Baseline (handoffs 090/091): the maintainer's padded box **96×80×96 = 737 280 voxels,
2.29 M DOF → one solve ≈ 12.2 s** ([090:234,279](docs/handoffs/090-void-coarsening.md),
[091:215](docs/handoffs/091-galerkin-cache-production.md)). Fine + box ≈ 4.8–5.4 M voxels
(box extents **183.5 × 100.4 × 125.4 mm**; the box drives the domain expansion) → **≈ 7.3×** →
**≈ 90 s/iter expected**. Task's worst case: 4 × 140 × 90 s ≈ **14 h**.

- **Measured** steady-state **10 820 s/rung** ÷ expected **90 s/iter** ⇒ implied **~120
  iters/rung** — squarely between plateau-typical and the 200 cap. Fully consistent.
- Equivalently, measured s/iter (**54–90 s**) is **at or below** the 90 s/iter prediction: the
  matrix-free multigrid solver is tracking the linear-in-voxels scaling of the 12.2 s @ 737 k
  baseline. **No N× anomaly in either direction.**
- Projected full ladder **~11.7–12.2 h** sits **under** the 14 h worst case.

**This is physics, not a defect** — subject to the three sanity checks in §3 all passing,
which they do.

---

## 3. BUILD & CONFIG SANITY (each a look, not a theory)

| Check | Result | Evidence |
|---|---|---|
| **(a) Release build?** | ✅ `CMAKE_BUILD_TYPE=Release` | `core/build/CMakeCache.txt`; and the worker's resolved `cliPath` **is** `core/build/topopt-cli` (`~/Library/Preferences/app.topopt.worker.plist`). A Debug FEA solver (3–5× slower) is ruled out. |
| **(b) Threads = all 8 cores?** | ✅ auto = `hardware_concurrency()` | matfree threads default to 0 → `std::thread::hardware_concurrency()` ([matfree.cpp:330-332](core/src/fea/matfree.cpp#L330)). No cap was set (no CLI/worker flag exists to set one — see lever e). |
| **(c) Production solver config?** | ✅ MultigridCG_Matfree + Galerkin block cache + design-box align-8 pad | `configure_production_options` **is** called on the CLI path ([run_job.cpp:255](core/src/cli/run_job.cpp#L255)); it sets `SolverKind::MultigridCG_Matfree`, `min_feature 2.5 mm`, and `fea_set_matfree_galerkin_block_cache(true)` ([production.cpp:8-33](core/src/simp/production.cpp#L8)); the reduction-ladder path pads ([loadcase.cpp:195](core/src/cli/loadcase.cpp#L195)). |

**Honest caveat:** (c) is confirmed by **code path** (the CLI *always* configures production
options for `minimize_plastic`), **not** by a runtime echo from this run — no log survived to
echo it. This is exactly the gap §5 asks the next run to close.

---

## 4. THE LEVERS — ranked by (expected gain ÷ effort). No implementation here.

Two goals are in play; the ranking below is by gain÷effort, with the goal each serves called
out. For "**make it finish sooner**" the order is c → a → d; for the maintainer's stated pain,
"**make the Mac usable while it runs**," lever **e is first-class**, not an afterthought.

| # | Lever | Expected gain | Effort | Risk / cost | Honest uncertainty |
|---|---|---|---|---|---|
| **1** | **(c) Fewer rungs for exploratory runs.** Ladder is 4 rungs, each ~26 % of wall-clock. A custom `ladder` is already a validated job field ([job.cpp:539-548](core/src/cli/job.cpp#L539)) — **config only, zero code.** | 2 rungs `{0.52,0.26}` → **~6 h**; 1 rung → **~3 h** | ~0 | Skips intermediate savings options. The accept gate already prunes weak rungs, but here **all 3 completed rungs were accepted**, so nothing auto-pruned. | Low — arithmetic is direct from §1. |
| **2** | **(e1) Run the CLI child at `utility` QoS / `nice`.** Worker spawns `topopt-cli` at default priority ([topopt_worker.py:189](tools/topopt-worker/topopt_worker.py#L189)); add a `preexec_fn=os.nice(…)` or spawn under a background QoS. | Mac stays responsive; **~0 throughput loss when otherwise idle**, graceful degradation only under contention | ~10-line worker change | Essentially none when idle | This is the **best usability lever**: high benefit, near-zero cost, tiny effort. |
| **3** | **(a) FP32 mixed-precision V-cycle (handoff 092).** `fea_set_matfree_mixed_precision(bool)` exists, **opt-in, default-OFF**; needs a one-line flip in `configure_production_options` beside the Galerkin-cache flip, plus a validation pass. | Literature 47–83 % on the V-cycle **apply**, but apply is only part of a solve whose **build is 48 %** (091) → **~1.15× overall** ≈ 11.7 h → **~10.2 h (saves ~1.5 h)**, applies to **every** run | 1 line + validation | Low (outer CG stays FP64; coarse solve FP64) | The 1.15× is a repo estimate, not measured on this part/hardware; measure on-device before the flip (092 ran on x86, "the ratio transfers"). |
| **4** | **(d) Smaller design box.** s/iter is ~linear in voxels. This box 183.5×100.4×125.4 mm. **20 % smaller per axis** → 0.8³ = **0.51× voxels → ~half the wall-clock (~5.8 h)**; 20 % smaller *by volume* → 0.8× → ~9.4 h. **Config only** (box is a job field). | up to **~2×** | ~0 | Shrinks the **design space** — less room to route material, possibly worse compliance. A modeling decision, not a free speedup. | Which "20 %" the maintainer means changes the answer 2×; stated both. |
| **5** | **(e2) Worker/CLI thread-cap flag for daytime.** Core primitive `fea_set_matfree_threads(n)` exists ([fea.hpp:465](core/include/topopt/fea.hpp#L465)) but **no CLI/worker flag reaches it**. Wire a `--threads N` (+ a worker daytime setting). | Leaves 2–3 cores for the desktop | Small (one flag → existing primitive) | **Proportional slowdown**: 6/8 cores ≈ **1.33× longer** (11.7 h → ~15.6 h) | Scaling is near-linear in cores for this bandwidth-bound kernel; real factor slightly worse than 8/6. |
| **6** | **(b) Tighten the plateau tail.** IF rungs ran near the 200 cap with a long flat tail past the running-min, tightening `mma_plateau_window` (10→~6-8) or `margin_stop` could cut ~40–60 iters/rung ≈ **~15–25 % (~2–3 h)**. | ~2–3 h *if* the tail is flat | Small (param) + a **measured study** | **Design-quality risk**: 086 calibrated window=10 precisely so an early spike-heavy phase is **not** misread as a plateau (premature fire → near-uniform, under-crisp design); 102 shows MMA's grayscale field already under-reports achieved vf, and cutting iterations makes it grayer. | **Cannot be quantified from THIS run** — the compliance trace does not exist (§5). Lowest gain÷(effort+risk); do not blind-flip. |

---

## 5. ARTIFACTS: what survived, what never existed, what the next run must capture

**Survived** (workdir was **not** cleaned — the worker never `rmtree`s on cancel/`DELETE`):
`job.json`, `model.step`, `variant_068/052/038.stl` (3 of 4 rungs). Nothing was lost *to the
cancel*.

**Never existed on disk** (this is the real gap, not a deletion):
- **Per-iteration `PROGRESS` log and per-rung compliance/objective trace.** These live only in
  (a) the worker's stdout → forwarded to the now-gone iPad SSE client and reduced by the
  menu-bar app to a single transient `activeJobLabel` string (last value only, never persisted:
  [WorkerSupervisor.swift:186-208](tools/TopOptWorkerApp/TopOptWorkerApp/WorkerSupervisor.swift#L186)),
  and (b) the Python worker's in-memory `job.events` list (gone on worker restart/quit). **The
  worker writes nothing per-iteration to the workdir.** Hence §1 is reconstructed from mtimes
  and iters/rung is only bounded, not known.
- **`report.json`.** Written only at successful completion (run_job end); the run was cancelled
  before rung 4, so no report.
- **Unified log.** `log show` for 04:00–14:00 Jul-18 returned empty — rolled past retention
  (queried 6 days later).

**Next run must capture (one small change turns this forensic reconstruction into a direct
read):**
1. Have the worker **tee its `STATUS`/stdout lines, timestamped, to
   `<workdir>/<job-id>/worker.log`** (and keep it after cancel). Additive to
   [topopt_worker.py:106-115](tools/topopt-worker/topopt_worker.py#L106); does not touch the
   SSE protocol.
2. Persist a **per-iteration `{rung, iter, compliance, achieved_vf, stop}` CSV** to `out/` (the
   102 `TOPOPT_PLATEAU_TRACE` instrumentation, made durable). This is the exact data lever (b)
   needs and could not get here.
3. Snapshot **`topopt-cli --version` (version + fingerprint) into `job.json`** at job creation,
   so client/worker/core era is provable next time instead of inferred.
