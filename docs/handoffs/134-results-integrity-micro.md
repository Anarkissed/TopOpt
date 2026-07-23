# 134 — Results-integrity micro: duration truth, re-attach fields, viewer profile

**Track:** app only. **Territory:** `/app/TopOptKit/` (`TopOptKit`, `TopOptFlows`,
tests) + the LAN worker's E2E harness (`tools/topopt-worker/e2e/`). **NO core, NO
bridge, NO solver.** The worker server itself (`topopt_worker.py`) is unchanged —
only its test stub and harness script are touched.

**Handoff number:** `docs/handoffs/` tops at **133**. This takes **134**.

**Gates (all green):** `swift test` on the package — **678 tests, 0 failures, 3
skipped** (the two opt-in profile tests + the gated E2E case), 76 s; the iOS app
target builds. The re-attach QA repro runs as a new E2E case against the real
worker over HTTP: `tools/topopt-worker/e2e/run_e2e.sh reattach` — **passed**. Full
evidence in §4.

---

## 0. What each item turned out to be

| item | what it was | what shipped |
|---|---|---|
| 1 duration | REAL. The app had no carried duration at all; every duration it could show was measured against `now()` or against the moment of re-attach. | `RunTiming` carried on `OptimizeOutcome`, sourced from the worker's own `created_at`/`started_at`/`finished_at`; shown on the results chrome; persisted. |
| 2 re-attach fields | Already structurally correct — and **unproven**, because the E2E stub never wrote a `fields.bin`, so every harness case only ever exercised the degraded path. | The stub now writes a real v1 `fields.bin`; a new `reattach` E2E case runs the QA repro over HTTP; an app-side regression pins what the re-attached results screen must show; the fetch now logs WHICH failure it hit. |
| 3 viewer profile | Measurement. | A repeatable, opt-in profile harness + the table in §3. The device GPU frame time is the one cell I could not fill — see §3.3. |

---

## 1. Duration truth

### 1.1 The finding

There was no results-side duration in the app to fix. Grepping every time
formatter in `/app/` finds exactly three, and none of them describes a finished
run: the in-flight `Elapsed` clock (`RunProgressReadout`, anchored at
`RunModel.startedAt`), the re-attach banner's age (`AppModel.relativeAge`, "started
about 11 hours ago"), and the ETA. So the reported "11 hours" was necessarily one
of the two `now()`-anchored numbers — both truthful about the OBSERVER, neither
about the run. The worker's menu read 40m53s the whole time because it reads
`finished_at - started_at` off its own record.

### 1.2 The shape

A duration is now **carried, never recomputed**:

* `RunTiming { queuedSeconds, solveSeconds }` (`TopOptKit.swift`) with
  `fromWorker(createdAt:startedAt:finishedAt:)` and a `summary` — `"solved 40m 53s"`,
  or `"waited 4m 12s · solved 40m 53s"` when the job queued first. No `finished_at`
  → **nil**, never a `now()`-derived stand-in.
* `OptimizeOutcome.timing` (optional, default nil → local runs byte-identical).
* Remote: `RemoteRun.fetchTiming()` reads `GET /jobs/{id}` at final assembly — the
  same worker record the Mac's menu shows. Best-effort like `fetchFields`.
* Local: `RunModel` stamps its own measured start→finish. `finish` applies it ONLY
  when the outcome carries none AND the run was not remote — a remote run with an
  unreadable worker record gets **no duration at all** rather than the client's
  attach window.
* Persisted through `OutcomeCodec` (optional fields; pre-134 blobs decode to nil).
  This follows the 108 rule: a DTO that drops a field forces the screen to
  re-derive it, and by reopen time the only clock left is `now()` again.
* Shown in the results top chrome next to "Optimized ✓", absent when nil.

### 1.3 The other half of the same lie

A re-attached run's in-flight `Elapsed` clock restarted at 0:00 — a run ten hours
into its solve read "0:03" because `start` anchors the clock to now.
`RunModel.anchorElapsed(to:)` + a call in `AppModel.reattach` anchor it to the
persisted submit time, so the readout describes the run, not the viewing session.
(Presentation-only; the durable duration still comes from the worker.)

### 1.4 Carried fix in the same family

`RemoteRun.run()` looked the prior submit time up with `RemoteJobStore.load()` —
the most-recently-saved record, which since the multi-slot store (121) need not be
the job being re-attached. Re-attaching an older job while a newer one was
outstanding stamped the newer job's submit time onto it, and the banner then
reported the wrong age. Now looked up by job id.

---

## 2. Re-attach fetches fields

### 2.1 What was actually true

The re-attach path and the live-completion path are the **same code**: both build a
`RemoteRun` (the re-attach one only skips `/health` + `POST /jobs`), both stream
the worker's `/events`, and both resolve through `assembleFinalOutcome`, which
fetches `report.json` and then `fields.bin` once. There was no second, thinner
path to fix.

What was missing was any evidence. `e2e/stub_cli.py` never wrote a `fields.bin`, so
**every** E2E case — including the happy path — asserted the fetch-FAILED branch
(`massGrams == 0`, `vonMisesField.isEmpty`). The 122 wire format had been live for
twelve handoffs with no end-to-end coverage of its success case, on either path.

### 2.2 What shipped

* `stub_cli.py` now writes a structurally exact v1 `fields.bin` (tiny 4³ grid,
  non-zero masses), written LAST like the real CLI does.
* The `happy` case now asserts the fields ARRIVE (mass > 0, von Mises and
  displacement present, grid metadata carried).
* New E2E case **`reattach`** = the QA repro at the HTTP level: the harness submits
  a job and waits for it to finish **with no client attached** (the force-quit
  window), then hands the finished job id to a fresh `RunModel` driven by
  `remoteReattachRunner` — exactly what `AppModel.reattach` does after a relaunch.
  It asserts fields present, `ResultsModel.hasStress/hasFlex/hasLoadPath` true, mass
  not `n/a`, and that the duration is the worker's, not the client's attach window.
* `ColdLaunchReattachTests` gained the app-side half: a re-attached outcome carrying
  fields reaches results with the overlays live and the "computed on Mac" note
  naming only the playback (the one thing genuinely still Mac-only).
* `fetchFields` now logs WHICH failure it hit — transport / HTTP status / unparseable
  body / success with byte + block counts. "n/a — computed on Mac" is only honest
  when the fields are genuinely absent, and the device Console can now say which.

Measured output of the new case (real worker, real HTTP, client attached 0.1 s to a
job the worker solved in 3 s):

```
== E2E case=reattach port=54333 grace=3.0s appFingerprint=c6c7af7c5b1c ==
  re-attaching to completed job 5c9564d458ae49c3 (client was 'force-quit')
  results: stress=true flex=true mass=42 g note=This variant was optimized on your
           Mac. The optimization playback is computed there and isn't available …
  duration: solved 3s (client was attached only 0.1s)
Test Case '-[TopOptFlowsTests.RemoteRunnerE2ETests testEndToEnd]' passed
```

### 2.3 Harness footgun fixed

`/tmp/topopt-e2e.json` is what ARMS the otherwise-skipped E2E test, and the harness
left it behind. Every later plain `swift test` on that machine then ran the gated
case against a worker that was no longer listening — a green suite going red for no
code reason. (It bit this task: the first full run failed exactly that way.) The
harness now deletes it on exit.

### 2.4 Still device QA

The on-device repro (submit → force-quit → let it finish → relaunch → banner →
results) is the maintainer's 60 seconds. This task cannot run it: it needs a real
iPad and a real overnight-scale job. What it CAN now do is fail loudly if the
mechanism regresses, on both the network side (E2E `reattach`) and the app side.

---

## 3. Viewer profile (measure only — no fix)

### 3.1 The meshes

Three REAL bracket variants: `core/tests/fixtures/demo/l-bracket.step` through
`topopt-cli` at **resolution 64**, ladder 0.70 / 0.50 / 0.30, all three accepted
(margins 2.86e3 / 2.73e3 / 2.26e3; the run took 15m37s on the M2 Pro). The res-48
demo set (`build/cli_out1`) is included as a second point.

Reproduce:

```bash
TOPOPT_VIEWER_PROFILE_DIR=<topopt-cli --out dir> swift test --filter ViewerProfileTests
```

### 3.2 The numbers (Apple M2 Pro — see §3.3 for why these are not iPad numbers)

Resolution 64:

| variant | tris | raw verts (uploaded) | welded verts | ratio | pos+nrm | tint | flex | total GPU | frame @1024² | frame @2048² |
|---|---|---|---|---|---|---|---|---|---|---|
| 0.70 | 36,628 | 109,884 | 18,294 | 6.01× | 2,575 KB | 1,717 KB | 1,288 KB | **5,580 KB** | 0.167 / 0.496 ms | 0.342 / 1.044 ms |
| 0.50 | 29,100 | 87,300 | 14,528 | 6.01× | 2,046 KB | 1,364 KB | 1,023 KB | **4,433 KB** | 0.146 / 0.436 ms | 0.322 / 0.990 ms |
| 0.30 | 21,652 | 64,956 | 10,782 | 6.02× | 1,522 KB | 1,015 KB | 761 KB | **3,299 KB** | 0.127 / 0.382 ms | 0.301 / 0.930 ms |

The two timing figures are the machine's two stable **GPU clock regimes**, not
noise: `a` is what the same binary measures right after sustained GPU work (clocks
up), `b` is what it measures on an idle machine (clocks parked). Each reproduced
identically across three consecutive runs; the file
`docs/handoffs/evidence/134/viewer_profile.txt` holds the three idle-clock runs
verbatim. **The ratios are invariant across both regimes** — 0.70 costs 1.30–1.31×
the 0.30 variant at either clock — which is why the shape below is the finding and
the absolute milliseconds are only a scale.

Resolution 48 (the committed demo set), mesh census only — its timings were taken
in a different clock regime from the table above, so quoting them side by side
would invite a false comparison:

| variant | tris | raw verts | welded verts | ratio | total GPU |
|---|---|---|---|---|---|
| 0.70 | 15,684 | 47,052 | 7,840 | 6.00× | 2,389 KB |
| 0.50 | 13,964 | 41,892 | 6,960 | 6.02× | 2,127 KB |
| 0.30 | 9,208 | 27,624 | 4,588 | 6.02× | 1,403 KB |

**Method.** The census columns are exact and deterministic (parse the STL, weld by
exact position identity, size the buffers the way `MetalMeshView` does). The timing
is min-of-40 frames measured by Metal itself (`gpuEndTime - gpuStartTime`) with no
pixel readback in the timed region — `renderOffscreen` is NOT a frame-time proxy,
it copies a megabyte back to the CPU per call. All variants share one renderer, so
no variant pays for pipeline compilation (that alone made a first-measured variant
read 3× its neighbours before it was fixed).

Draw calls per frame, measured through the renderer's own counter
(`MeshRenderer.lastFrameDrawCalls`), for the results screen:

| state | render passes | draw calls | vertices/frame |
|---|---|---|---|
| results, at rest | 1 | **2** (stage backdrop + body) | tris×3 + 3 |
| results, orbiting | 1 | **2** — identical | identical |
| offscreen (thumbnail / video) | 1 | 1 (body only) | tris×3 |
| workspace with a design box or clearance volume | 2 (depth prepass + main) | 2 + 2 per volume + 1 prepass | — |

Orbiting changes nothing about a frame's CONTENT; the same encode runs. What it
changes is HOW OFTEN: the MTKView is on-demand (`isPaused = true`,
`enableSetNeedsDisplay = true`), so at rest the viewer draws **no frames at all**
unless something invalidates it, and while dragging it draws one frame per camera
change. That makes "frame time at rest" a question about *invalidation*, not about
the draw — which is exactly what the device capture in §3.3 has to answer.

### 3.3 What these numbers do and do not say

**They say:** the body draw is not expensive. The frame is **fill-bound, not
geometry-bound**. Within one clock regime, 69% more triangles (0.30 → 0.70) costs
+0.040 ms @1024², while doubling the raster edge on the SAME mesh costs +0.175 ms —
four times as much for no extra geometry, and the implied 0-triangle intercept is
most of the frame. Indexing would not buy frame time here.

**Where the real cost is:** memory, not milliseconds. Every per-vertex buffer is
sized to the unshared soup, and **each welded vertex is shared by ~6 triangles** —
a ratio that is nearly constant (6.00–6.02×) because a marching-cubes surface is
regular. Welding the 0.70 variant would take pos+nrm from 2,575 KB to ~429 KB plus
a ~429 KB index buffer, and tint + flex (which are re-uploaded on every stress /
flex / flow tick — see `setStressTints`) from 3,005 KB to ~500 KB. That is ~5.6 MB
→ ~1.4 MB per variant, and the re-upload traffic falls with it.

**They do NOT say** what the iPad does. These are Apple M2 Pro numbers from a
headless offscreen render. Two things nothing here can measure:

1. **Device GPU frame time.** An iPad's tile-based GPU with a different fill rate
   and memory bandwidth will not scale from these linearly.
2. **At-rest frames on device.** Everything above assumes the at-rest viewer draws
   nothing. Whether that holds in the shipping app depends on whether some state
   keeps invalidating the view — precisely the "frame collapse" the 112/120
   signposts were added to chase.

To close both, this handoff adds the missing instrument: the viewer now emits an
os_signpost INTERVAL per drawn frame — `com.topopt.results` / **`ViewerFrame`** /
`viewer_frame`, carrying `draws=` and `verts=` — next to the existing
`ResultsFrame` (`body_eval`, `playback_tick`) and `GizmoFrame` tracks. A device
capture is then: open results on a bracket variant, record Instruments (Metal
System Trace + os_signpost), sit still 10 s, orbit 10 s. At-rest frame count and
per-frame span come straight off the `ViewerFrame` track; if at-rest intervals
appear at all, the `ResultsFrame` `body_eval` events beside them name the state
source driving them. **That capture is the fix task's first step**, and the one
cell of this table it must fill in.


---

## 4. Evidence

| gate | result |
|---|---|
| `swift test` (package, macOS) | **678 tests, 0 failures, 3 skipped**, 76 s. Skips = the gated E2E case + the two opt-in profile tests. |
| E2E `reattach` (new) | **passed** — real worker, real HTTP; output quoted in §2.2 |
| E2E `happy` (now asserts fields PRESENT) | **passed** — `duration: solved 0s`, 2 variants, margins 2.40 / 1.70 |
| E2E `reject_all` / `bad_mesh` / `stream_drop` / `cancel` | **passed** (the stub's new `fields.bin` breaks nothing) |
| iOS app build | `xcodebuild -scheme TopOpt -destination 'generic/platform=iOS Simulator'` → **BUILD SUCCEEDED** |
| Viewer profile | §3.2, from a real 15m37s l-bracket ladder at resolution 64 |

Raw output in `docs/handoffs/evidence/134/`:
`swift_test_summary.txt`, `e2e_reattach.txt` (including the WORKER's own record —
`started=1784845727.816767 finished=1784845730.885132`, i.e. 3.068 s, which the
client reported as `solved 3s` while attached for 0.0 s), `viewer_profile.txt`
(three consecutive runs), and the profiled ladder's `bracket64_report.json` +
`bracket64_job.json`.

Local runs with no remote involvement are unchanged: `timing` defaults to nil
everywhere it is not set, `computedRemotely` is untouched, and no core, bridge or
solver file is modified.

### Still maintainer QA (cannot be done from here)

1. The on-device re-attach repro (§2.4) — needs a real iPad and an overnight-scale
   job.
2. The `ViewerFrame` device capture (§3.3) — the one cell of the profile table this
   task could not fill.
3. Eyes on the duration in the results chrome: it is asserted headlessly
   (`ResultsModel.runDurationLabel`) and the layout is a `Text` in an existing
   capsule, but pixels are device QA per the M7 standard.

---

## 5. Files touched

| file | why |
|---|---|
| `TopOptKit/TopOptKit.swift` | `RunTiming`; `OptimizeOutcome.timing` + `withTiming` |
| `TopOptFlows/RemoteRunner.swift` | `fetchTiming`; timing on the assembled outcome; per-failure fields diagnostics; submit-time lookup by job id |
| `TopOptFlows/RunModel.swift` | local solve stamp + injected clock; `stamp` in `finish`; `anchorElapsed` |
| `TopOptFlows/AppModel.swift` | anchor the elapsed clock on re-attach |
| `TopOptFlows/OutcomeStore.swift` | persist the duration (optional, back-compatible) |
| `TopOptFlows/ResultsModel.swift` | `runTiming` / `runDurationLabel` |
| `TopOptFlows/ResultsScreen.swift` | the duration in the top chrome |
| `TopOptFlows/MetalMeshView.swift` | `countedDraw` + per-frame counters; `measureFrameGPUSeconds` (instrumentation only) |
| `Tests/…/RunDurationTests.swift` | new — the duration contract |
| `Tests/…/ViewerProfileTests.swift` | new — the opt-in profile |
| `Tests/…/ColdLaunchReattachTests.swift` | re-attached results carry fields + the worker's duration |
| `Tests/…/RemoteRunnerE2ETests.swift` | fields asserted present; the `reattach` case |
| `e2e/stub_cli.py` | writes a real v1 `fields.bin` |
| `e2e/run_e2e.sh` | the `reattach` case; config cleanup on exit |
| `tools/topopt-worker/README.md` | documents the `reattach` case |
| `docs/handoffs/evidence/134/` | raw gate output + the profiled ladder's report/job |
