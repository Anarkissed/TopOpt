# Post-processing must reach the variants — and say what it can do before you spend a run

Slug: `variant-postprocessing-fix` ·
Evidence: `evidence/2026-08-03-variant-postprocessing-fix/`

Scope: `core/` + `app/` + `tools/topopt-worker/e2e/` + CI. No fixture,
`materials.json`, `ARCHITECTURE.md` or `DECISIONS.md` was touched. No assertion was
weakened or deleted. The gate's verdict logic and tolerance are untouched. The SIMP
loop, the material interpolation, the cells-per-member floor and the certifiable
band are untouched (the concurrent `multiscale-lattice-to` task owns those).

---

## 0. C2 up front — THE APP PACKAGE IS NOW IN CI

`.github/workflows/ci.yml` gains an `app-macos` job: `brew install opencascade
eigen` → `./app/scripts/build_core.sh` → `swift test --package-path app/TopOptKit`.
It is **not** out of scope and it is done.

One gap, stated loudly rather than hidden: the E2E cases in
`tools/topopt-worker/e2e/run_e2e.sh` are **not** run in CI. They stand up a live
worker plus a CLI on the same host; wiring that into a hosted runner is its own
piece of work. They stay a local gate. `swift test` covers everything that does not
need a worker — which is where all four of the defects behind green checks lived.

---

## 1. DEFECT 1 — R1: the artifact traced, every hop, and the one that drops it

**The maintainer's own worker was still running, and his run's directory is still on
disk.** Nothing below is inferred; it is read off his artifacts. He was right not to
rebuild.

The run is worker job `95f4130119414636`, `/Users/nadim/.topopt-worker/`, submitted
`2026-08-02T16:07:49`, CLI fingerprint `2b8b715fd347`.

| Hop | What is there for HIS run | Verdict |
|---|---|---|
| app dispatch | `job.json` on the worker: `minimize_plastic`, res 128, octet lattice, swept grading, 8 include + 1 exclude region, `skin: "rim"` | present |
| worker → CLI | `topopt-cli run job.json --out out/` (launch line, 16:07:49) | present |
| `topopt-cli` | **still solving rung 3 of 4** at 17:03:46 (iter 106) — the log ends there; its parent (the Python worker) exited at 17:04:17–18, proven in §1b | **KILLED MID-LADDER** |
| outputs dir | `variant_068/052/038.stl` + their three lattice receipts + `iterations.csv`, `loadcase.json`, `run_info.json` | present |
| outputs dir | **`report.json`, `fields.bin`, `design.bin`, `build_orientation.json` — NONE OF THEM EXIST** | **ABSENT** |
| fetch | nothing to fetch | — |
| store | nothing to store | — |
| variant gate | `artifacts == nil` ⇒ both entries greyed, with exactly the two sentences he photographed | correct, given the above |

`evidence/…/r1_worker_out_listing.txt` is that directory listing;
`r1_worker_log_bookends.txt` is the launch line and the last three progress lines;
`r1_his_job.json` and `r1_receipt_0{38,52,68}.json` are his own documents.

### The hop that drops it — file and line

**Core wrote `design.bin` only after the whole ladder.** `run_job.cpp`'s final
assembly did `result.design_path = join_path(out_dir, "design.bin");
write_design_file(...)` at the end of the function — the same place `fields.bin` and
`report.json` are written. A run killed on its last rung has streamed every variant
it produced and written **none** of those three.

**And the app fetched the retention pair only at final assembly.**
`RemoteRunner.swift`'s `assembleFinalOutcome()` held the one
`onArtifacts(...)` call, and `assembleFinalOutcome` is reached from exactly one
place: the `terminal` branch of `driveEvents()`. His run never produced a terminal
event.

When the worker process was replaced (§1b), `GET /jobs/{id}` 404'd (a new process
has an empty scheduler), `probeStatus()` returned nil three times, and `RemoteRun` threw
`workerUnreachableMessage`. `RunModel.finish`'s `.failure` branch then did the right
thing — the three streamed accepted variants are real output, so it **keeps** them
and reports `.succeeded` — and `adoptPendingArtifacts()` found `pendingArtifacts ==
nil`, because nothing had ever reported one.

**Three variants on screen, phase succeeded, `retainedArtifacts == nil`.** That is
the state, exactly.

### 1b. AND WHY DID THE WORKER END THE RUN? He did not stop it.

Asked, and correctly: "the worker was restarted" was my inference from a `.DS_Store`
timestamp, which is not evidence. Here is what the artifacts actually say.

| Fact | How it is known |
|---|---|
| The Worker **app** never restarted | PID 74031, running since **Jul 22** |
| Only its **Python child** restarted | PID 16871, started **17:04:20** |
| The child exited at **17:04:17–18** | `pmset -g log`: the keep-awake assertion *"TopOpt optimize running on this Mac"* was RELEASED at 17:04:18 after **00:56:28** held — and 16:07:49 + 56:28 = 17:04:17, so that assertion WAS his job |
| It was an **unexpected** exit, not a stop | the restart came exactly **2 s** later, which is `workerTerminated`'s backoff. A deliberate `stop()` sets `shouldRun = false` and never restarts |
| Not a crash | no report in `~/Library/Logs/DiagnosticReports` at 17:04 |
| Not an OOM kill | no jetsam / memorystatus event in the window |
| The job is genuinely forgotten | `SCHED.jobs` is in-memory and **never pruned** — an empty `/jobs` proves the process is new |

So the Python worker **exited on its own**, and I cannot tell you which exception —
**because the reason was written to a pipe that is deliberately discarded.**

`WorkerSupervisor.start()`:

```swift
outPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
```

The worker's entire stdout AND stderr are drained and thrown away. And the one
record of the exit — `state = .failed("Worker exited (code N) — restarting…")` — is
a `@Published` UI string that `start()` overwrites with `.running` **two seconds
later**. Nothing durable, anywhere.

**That is not a missing detail in the diagnosis. It IS a defect, and it is mine.**
Three, in fact, and they are fixed:

**DEFECT 6 — the worker's death left no record.**
Everything the worker prints now lands in `~/.topopt-worker/worker-app.log`
(4 MB cap, tail-trimmed). Every unexpected exit appends a `[supervisor]` line naming
the exit code, **which jobs were running or queued when it happened**, and the last
40 lines the worker printed. `lastUnexpectedExit` holds that record **across** the
auto-restart, so the UI can say "the worker restarted at 17:04:18 (code N) — a run
may have been lost" instead of flicking back to green. Only a deliberate stop clears
it. The `lost` list is captured BEFORE `jobs` is cleared, because a restarted worker
forgets everything and that line is then the only surviving statement of what the
exit cost.

**DEFECT 7 — a restarted worker 404s artifacts that are sitting on disk.**
`SCHED` is in-memory, so the new worker knew nothing about job `95f4130119414636` —
while `<workdir>/95f4130119414636/out/` held three variant meshes and their receipts,
intact. Every request for them 404'd against a directory that was right there.
`GET /jobs/{id}/files/{name}` now falls back to `<workdir>/<id>/out/<name>`, confined
to the workdir by `basename` on both components plus a realpath containment check.

Verified **against his actual forgotten job**: a fresh worker reporting `jobs: []`
serves `variant_038.stl` — **HTTP 200, 16,498,484 bytes**. Path-escape attempts 404.
`/jobs/{id}` and `/events` still 404, deliberately: a job's live STATE and its event
replay are facts about a running child, and inventing them from a directory listing
would be a guess. Covered by `queue_http_e2e.py` case 9 (8 checks).

**Together with the incremental `design.bin`, this is what would have saved his run**
— the design would have existed on disk when the worker died, and the app's fetch
would have found it after the restart instead of a 404.

**What I still cannot tell you:** which exception killed the Python process on
2026-08-02. That information no longer exists. The next occurrence will be one
`tail ~/.topopt-worker/worker-app.log` away, and I would rather say that plainly
than offer a theory dressed as a finding.

### So: PR 284 is not contradicted. It is INCOMPLETE.

PR 284's Mechanism 0 was real and its producer works — for a run that reaches its
terminal event. It wired the producer to the **one path a run can end on that his
run did not take**. Every other way a run ends up displaying variants —
streamed-and-kept after a client-side abort, streamed-and-kept after a user cancel,
and **the entire duration of any live run** — had no pair. PR 288 read the code and
found the producer present; it was present, and unreachable for his run.

### What changed

1. **Core publishes `design.bin` after EVERY variant** (`run_job.cpp`,
   `publish_design_so_far` in the `on_variant` callback; `design_store.cpp` gains a
   variant-list overload). Publication is a **rename** (`design.bin.part` →
   `design.bin`) because the worker now serves this file while later rungs rewrite
   it. The final write is unchanged, so a completed run ships the identical file.
2. **The app retains the job document at SUBMIT** (`RemoteRunner.run()`,
   `onArtifacts?(.jobOnly(jobJSON))`). Those are the bytes it just posted; smoothing
   needs nothing else. Tying it to `design.bin`'s fate is why a run whose design
   never arrived also reported it had kept no **load case**.
3. **The app fetches the pair after EVERY streamed variant**
   (`RemoteRunner.emitStreamedVariant` → `reportRetentionPair()`). A variant is
   workable from the moment it appears; its design is now there from the same
   moment. The terminal report stays as the last, most complete one (it carries
   rejected rungs, which never stream).
4. **The two halves are no longer all-or-nothing.** `RelatticeArtifacts.designBin`
   may be empty; `hasDesign` says so. Smoothing reads `retainedJob`; latticing reads
   both. `ProjectStore` persists a design-less pair (and REMOVES a stale design file
   rather than writing zero bytes).
5. **The gate reads the design container's own index.** `DesignContainerIndex`
   parses the v1 header and each block's prologue — striding over the density
   payload, so a 50 MB container is indexed without materialising a field — and
   `VariantEntry` disables a variant the container does not cover, with its own
   sentence, instead of letting core refuse it by name later.
6. **`RelatticeUnavailable.designNotTransferred` finally has a producer.** It always
   had a sentence and nothing that could emit it; a current run whose job was kept
   but whose design was not used to borrow *"this run finished before results kept
   their design file"* — telling the maintainer his build was old about a build he
   had just rebuilt.

### R2 — the failing test, on the shipping path, first

`tools/topopt-worker/e2e/run_e2e.sh retain_dies` (new case) + `stub_cli.py`'s new
`retain_dies` mode stream two variants — each publishing a real v1 `design.bin`,
fingerprint and all — and then **kill the worker before the terminal event**. His
sequence. `RemoteRunnerE2ETests.runRetentionSurvivesAWorkerThatDiesMidLadder` drives
the real `RemoteRun` over real HTTP into a real `RunModel`, wired to `onArtifacts`
exactly the way `WorkspacePlaceholder.startRun` wires it.

With the two eager producers disabled (the HEAD mechanism, everything else
unchanged):

```
XCTUnwrap failed: expected non-nil value of type "RelatticeArtifacts" —
the run kept its variants but no retention pair — the exact state that greyed out both entries
```

### R3 — after the fix

```
retained: job 440 B, design 1272 B, blocks [0.7, 0.5]
variant 0 vf=0.7: smooth=true lattice=true
variant 1 vf=0.5: smooth=true lattice=true
```

Both entries **ENABLED**, for every variant on screen, on a run that never finished.
Raw before/after: `evidence/…/r2_r3_retain_dies_before_after.txt`.

Core's half is proven separately and from outside the process:
`core/tests/validation/test_design_stream.cpp` runs the real `topopt-cli`, reads its
stdout, and opens `design.bin` at the moment each `VARIANT` line arrives —
`blocks observed per VARIANT: 1 2`, with `report.json` not yet written.

---

## 2. DEFECT 5 — C1: what the shipping path does that the tested path did not

For retention, specifically:

* **Every retention test injected a stub `runner` closure.** `VariantRetentionTests`
  builds `RunModel(runner: { _,_,_ in … })` and calls `noteRetainedArtifacts` itself.
  The producer — `RemoteRun` fetching `design.bin` and reporting it — was **never
  executed by any test**, at HEAD or before.
* **The one E2E that drives `RemoteRun` for real never passed `onArtifacts`.**
  `RemoteRunnerE2ETests` built `RunModel.remoteRunner(config())` with the argument
  omitted, so the closure was nil and the whole branch was dead in test.
* **`stub_cli.py` never wrote a `design.bin` at all.** So even had the closure been
  passed, `fetchDesign()` would have 404'd and the test would have exercised only
  the degraded path — indistinguishable from the bug. (This is the same shape as the
  handoff-134 finding that the stub never wrote `fields.bin`.)
* **No test ever ended a run any way other than cleanly.** The `worker_dies` case
  asserts no DELETE is sent; nothing asserted what the kept variants still have.
* **CI never compiled the package**, so even a red app test reached nobody. PR 284
  armed a source-reading test to go red when core dropped its design-box refusal;
  PR 285 dropped it the same evening; the test went red and the app shipped a
  refusal quoting a rule core no longer had.

All five are closed: the stub writes a real container, the E2E passes the closure,
the new case ends a run the way his ended, and CI builds the package.

---

## 3. DEFECT 2 — F1/F2: why, per voxel, with counts

### F1 — the exact predicate, and the count for each

In the uniform (`fixed`/`auto`) grading path there is exactly **one** predicate that
can reject a candidate voxel (`grading.cpp`):

```cpp
const double cpm = width[e] / cell;
if (cpm < n_star) { ++out.solid_fallback_voxels; … }   // MEMBER TOO THIN
```

In `swept` mode there is a second, from the cell plan (`cell_plan.cpp`): a base cell
whose **strut would be unprintable** at every level in the ladder (`need[c] > L`),
as distinct from one **too thin to homogenize** at even the finest level
(`cap[c] < 0`). The two have **opposite remedies** — a smaller cell for a thin
member, a bigger one for an unprintable strut — which is exactly why summing them
into `solid_fallback_voxels` made the number unactionable.

Both are now counted per voxel and reported, in the run receipt and in the forecast:

```json
"solid_fallback_by_reason": {
  "member_too_thin_for_cell": …,
  "strut_unprintable_at_every_cell": …,
  "irrecoverable_by_any_cell_size": …,
  "widest_rejected_member_mm": …,
  "member_width_needed_mm": …
}
```

**For his variant 052, all 10,403 fall under `member_too_thin_for_cell`, and all
10,403 are `irrecoverable_by_any_cell_size`.** That is derivable from his own
receipt without re-running his hour:

* his `cell_min_mm` is `4.602619931809993`, which **is** `printability_floor_mm`
  for octet at his 0.42 mm line width — the finest legal cell. The swept plan's
  `need[c]` is therefore 0 for every cell (a strut at the band floor and the floor
  cell prints at exactly 0.42 mm), so **no voxel can be rejected as unprintable**.
* the remaining predicate needs `width ≥ n* × cell = 5 × 4.602619932 =
  **23.0131 mm**` of member thickness. Coarsening only raises that bar.

So: the fallback was not a tuning problem. The material his optimizer left is
thinner than 23 mm nearly everywhere in the region, and **no cell size on that page
could ever have changed it.**

### F2 — why 038 is entirely ungradeable while 052 and 068 are not

`region_ungradeable = region_voxels > 0 && latticed_voxels == 0`. It is not a
separate threshold: it is the case where the **same** predicate rejected everything.

The threshold that flips is the one above — **the minimum member width inside a base
cell must reach 23.0131 mm**. At vf 0.38 no base cell in the include region clears
it (0 latticed); at 0.52, twelve cells do (82 voxels); at 0.68, more (472 voxels).
Only the volume fraction differs, and a thinner rung leaves thinner members. The
number that flips is a property of his *design*, not of his settings.

---

## 4. F3 — THE PRE-FLIGHT FORECAST (the headline)

`job.lattice.forecast_only: true` makes `lattice_variant_job` run the grading law
and the role accounting on the stored design, write `lattice_forecast.json`, and
**return before the first solve**. It is the same law on the same inputs, so what it
reports is what the run reports.

It answers every question the brief asks, before the run:

* voxels that would be latticed / would stay solid, and the fraction;
* **why each fallback voxel fell back**, per reason, with counts;
* how many are irrecoverable by any cell size;
* **include-region voxels that are void** (defect 3);
* **whether the boundary choice can produce geometry at all** (defect 4);
* **EVALUATED counterfactuals** — each is a real second call to `grade_lattice`
  with one parameter changed, never a guess (PR 276's rule).

### P2 — the forecast matches the result. Five configurations, EXACT.

Same design (l-bracket demo, res 48, variant vf 0.50), forecast vs the real
`lattice_variant` job (`evidence/…/f3_forecast_vs_run.txt`):

| config | fc region | fc lattice | fc solid | run region | run lattice | run solid | |
|---|---|---|---|---|---|---|---|
| A auto w=0.42 | 7652 | **0** | 7652 | 7652 | **0** | 7652 | EXACT |
| B auto w=0.10 | 7652 | 3854 | 3798 | 7652 | 3854 | 3798 | EXACT |
| C swept w=0.10 | 7652 | 3854 | 3798 | 7652 | 3854 | 3798 | EXACT |
| D fixed 2 mm | 7652 | 2742 | 4910 | 7652 | 2742 | 4910 | EXACT |
| E D + include region | 7652 | 2742 | 4910 | 7652 | 2742 | 4910 | EXACT |

Per-reason counts match on both sides for all five. Config **A forecasts zero
lattice** — the brief's "one that forecasts almost no lattice" — and is exact there
too. `include_region_void_voxels` matches the run's own receipt exactly: **59,932**
on config E.

Cost: **0.09–0.55 s** for the forecast against **4–39 s** for the run at this size
(his was an hour).

### The one stated approximation

In AUTO density the law maps a **demand** field (the variant's von Mises) to a
density, and that field only exists after a solve. The forecast grades at the
**band's low end** — the thinnest strut the band allows, the conservative end for
printability. The cells-per-member rule does not see density at all, so **the
latticed/solid split is exact**; what the forecast does not predict is the density
*distribution*. The output says so in its own `demand_field` key.

### F4 — a refusal, with verified remedies

`LatticeForecast.isRefused` fires below 50% of the region latticed, before the run.
Advice is drawn **only** from remedies core measured to help, best first, each
labelled *"Measured, not estimated."* Config D:

```
Halve the cell size → 75% latticed (5,768 voxels), grading.cell_mm = 1.00 mm. Measured, not estimated.
```

Core also evaluated *doubling* (→ 0 latticed) and reports it; the app does not offer
it as advice, because a change that lattices less is not advice.

### F5 — when nothing on the page can help, say so and name the real cause

Config A is the maintainer's shape. Core offers **no** cell remedy, because every
rejection is irrecoverable. The app says:

> No cell size can lattice this design: the material the optimizer left is thinner
> than 23.01 mm almost everywhere, and the finest cell your line width allows is
> 4.60 mm. Nothing on this page will change that.
>
> The variant was optimized assuming SOLID material, so it was never asked to leave
> latticeable members. Latticing it afterwards can only work where the optimizer
> happened to leave thick enough material.

The second paragraph switches to *"Run the combined topology + lattice path
instead"* only when `combinedPathAvailable` is true. **It is false today** — until
`multiscale-lattice-to` lands, the limitation is stated and no path is offered.
Offering a path that does not exist is the same failure as guessing a remedy.

---

## 5. DEFECT 3 — V1/V2: include regions landing on void

### V1 — could he have known? No, and here is the line

`WorkspacePlaceholder.swift`'s viewer call read

```swift
clearanceVolumes: (force.phase == .edit && !fullScreenPageUp) ? clearanceRenderItems : []
```

`!fullScreenPageUp` — **the lattice page is a full-screen page.** The moment it
opened, every region volume stopped being drawn. The page whose entire subject is
those regions was the one page that hid them. And in the workspace the volumes were
only ever drawn over the **original imported part**, before any optimization, so
they never showed the relationship to optimized material either.

He could not have known. The answer to V1 is a flat no.

### V2 — now it shows, and it counts

The condition now includes `showLatticePage`. On the variants entry the stage mesh
is the **variant's own** geometry (`stageMesh` → `latticeVariantMesh`), so a region
sitting in empty space is visibly sitting in empty space, tinted with the existing
lattice-role indigo. And the count is folded into the forecast
(`include_region_void_voxels`) with its own sentence in `reasonLines`.

---

## 6. DEFECT 4 — S1/S2: "Rim only" can never emit, and it was the default

### S1 — it cannot. Structurally, not statistically.

Core emits rim geometry from exactly two places, and **both need an analytic PLANE
face** on the `LatticeBoundary`: `emit_rim_line` dresses a plane–plane edge and
`emit_rim_torus` dresses a plane–collar-bore pair (`lattice_gen.cpp`'s skin pass).

A Plane face can only enter through `LatticeBoundary::add_half_space` (or
`add_box`, which is six of them). **Nothing in `core/src` calls either.** The only
callers in the repo are two test harnesses. The production builder,
`lattice_boundary_for`, adds a voxel base (no face), keep-outs (a Bore face for a
bolt, nothing for a slab) and include/exclude regions (no faces at all).

So on every run the app can produce, `faces()` holds bores or nothing, no
plane–plane or plane–bore pair exists, and rim output is **identically zero**. His
three receipts read `rim_elements: 0` because zero is the only value that line can
take.

It **must not be the default**, and it now is not: `LatticeSettings.boundary`
defaults to `.fullSkin` (core's job schema has always defaulted to `"diagrid"` — the
app was overriding it with the choice that does nothing). Choosing it warns, at the
control, before the run. The claim is pinned to core by a source-reading test
(`testRimOnlyProducesNothingBecauseCoreAddsNoPlaneFaceOnAnyProductionPath`) that
goes red the day core adds a plane on a production path — one constant to change.

An old snapshot with no `boundary` key still decodes to `.rim`: that is the faithful
restore of what such a project actually had. It opens with the warning showing.

### S2 — what "Full skin" would have produced

Honest answer, in two parts.

**On the exact variants: it cannot be measured, and the reason is defect 1.** His
`design.bin` does not exist — the run was killed on rung 4 — so there is nothing to
re-lattice. Re-running his 128³ ladder is the hour this whole task exists to avoid
spending blindly.

**On a comparable run it is measured, and the answer is zero, for a reason that
generalises to his variants.** `lattice-variant` on the l-bracket design at
`skin = rim / diagrid / none` (`AUTO` cell, w = 0.42 — the closest available analogue
of his configuration):

| skin | rim_elements | skin_struts | landings | interior volume | mass |
|---|---|---|---|---|---|
| rim | 0 | 0 | 0 | 0 mm³ | 18.53 g |
| diagrid | 0 | 0 | 0 | 0 mm³ | 18.53 g |
| none | 0 | 0 | 0 | 0 mm³ | 18.53 g |

All three identical, because **nothing was latticed at all** (`latticed_voxels: 0`,
`region_ungradeable`) — the same failure as his variant 038. A diagrid anchors at
the **landings** of clipped interior struts; with no interior struts there are no
landings and no skin. So on his 038 "Full skin" would also have produced nothing;
on his 052 and 068 it would have had 82 and 472 latticed voxels' worth of clipped
ends to anchor to, and the honest thing to say is that the number is small and I
have not measured it, because the design that would let me measure it was destroyed
by defect 1.

The forecast is what closes this properly: `boundary_can_emit` is reported **before**
the run, and where the lattice itself is empty the forecast says so first.

---

## 7. The bars

| Bar | Verdict | Evidence |
|---|---|---|
| **R1** every hop traced, the dropping one named | MET | §1; `r1_*` |
| **R2** failing test on the shipping path, first | MET | `r2_r3_retain_dies_before_after.txt` |
| **R3** fresh run → job + design retained, both entries enabled | MET | same file |
| **F1** why, per voxel, with counts | MET | §3; `f3_forecast_vs_run.txt` |
| **F2** the threshold that flips 038 | MET | §3 |
| **F3** pre-flight forecast | MET in core (5 configs EXACT); **the page does not call it yet** — §10 | §4 |
| **F4** refusal + VERIFIED counterfactuals | MET (value + Optimize sub-line); same trigger gap | §4; `LatticeForecastTests` |
| **F5** point at the path that can | MET (stated, not offered) | §4 |
| **V1** could he have known | MET — **no**, with the line | §5 |
| **V2** show regions against actual material | MET | §5 |
| **S1** can rim ever emit | MET — **no**, structurally | §6 |
| **S2** what Full skin would produce | PARTIAL, stated | §6 |
| **C1** shipping vs tested path | MET | §2 |
| **C2** app package in CI | MET | §0 |
| **why did the worker end the run** | ANSWERED as far as the artifacts allow, + 2 defects fixed | §1b |
| **P1** his run end to end | PARTIAL, stated | §8 |
| **P2** forecast matches result, ≥3 configs | MET (5) | §4 |
| **P3** no silent fallback, reported BEFORE with per-reason counts | MET | `testAConfigurationThatTurnsMostOfItsRegionSolidIsRefusedBeforeTheRun`, `testTheOptimizeButtonStatesTheRefusalAndTheMeasuredRemedy` |
| **P4** Smooth reachable | MET | §1 R3 |
| **P5** byte-identical, full ctest | MET | `p5_byte_identity.txt`; §9 |
| **P6** determinism | MET | `p6_determinism.txt` |
| **D6** the worker's death leaves a record | MET | §1b; `WorkerSupervisor` builds clean |
| **D7** artifacts survive a worker restart | MET | §1b; `queue_http_e2e.py` case 9, and his real job over HTTP |

---

## 8. P1 — honestly: what I could and could not run

**What I ran end to end:** a fresh remote run whose worker dies mid-ladder, over
real HTTP through the real `RemoteRun` and `RunModel`, landing on **both entries
enabled**; and forecast → run agreement on five real configurations of a real
optimized design.

**What I could not run:** `M2_verticalStand.step` itself. It is **not in this
repository** — it lives only in his worker's job directory, and it is his part, not a
fixture I may add (fixtures are forbidden by this brief in any case). So P1's
"fresh run → variants page → Lattice ENABLED → configure → forecast → run → receipt
matches forecast" is proven on `l-bracket.step` and on the E2E harness, not on his
STEP file. Every number in this handoff that describes **his** run is read from his
own artifacts; every number that describes a run **I** made says which part it was.

**One thing worth his ten minutes:** re-run M2_verticalStand on the rebuilt worker.
It will now keep its design from the first variant onward, so even if it is
interrupted again both entries stay live — and the forecast will tell him, in under
a second, that his 4.60 mm cell needs 23.01 mm of material and his design does not
have it.

---

## 9. Test results

**Core:** full `ctest` — **100% tests passed, 104 of 104** (1623 s wall).

**App package:** `swift test` — **1147 tests, 13 skipped, 0 failures**, run after
the last change in this task (`evidence/…/p5_app_suite.txt`).
For comparison PR 284's handoff recorded 1061 tests with 8 failures across 3
pre-existing 3MF cases. Those three now RUN and PASS here
(`testThreeMFImportOptimisesOnDeviceEndToEnd` takes 164 s), because this worktree's
`build_core.sh` provisioned the vcpkg lib3mf — the worktree lib3mf gap, closed by
provisioning, not by a code change in this task.

**New suites:** `LatticeForecastTests` (9), `test_design_stream` (12 checks),
plus the new cases in `VariantEntryGatingTests` (19 total) and the `retain_dies`
E2E case.

**Byte identity (P5):** same optimize job, pre- and post-change CLI —
`design.bin`, `report.json`, `fields.bin` and all three variant meshes **identical**,
`loadcase.json` identical. `run_info.json` / `build_orientation.json` carry
deliberate wall-clock stamps and are excluded, as the existing determinism bars do.

**Determinism (P6):** each forecast run three times → byte-identical documents;
`design.bin` byte-identical across the pre- and post-change binaries.

---

## 10. Scope honestly stated, and what was deliberately NOT done

* **The forecast runs on a FINISHED VARIANT, not before the very first Optimize.**
  It grades a stored design, and before any run there is no design to grade. The
  "Lattice this variant" flow — the one his three receipts came from — is fully
  covered. Forecasting the *first* ladder would mean grading the solid part as a
  ceiling, which is a different and weaker claim; I did not build it rather than
  build it half-way.
* **The forecast is computed, carried and rendered into the Optimize sub-line —
  but nothing on the page CALLS it yet.** `RelatticeRun.forecast(...)`,
  `LatticeForecast` and `LatticeOptimizeSurface.compute(forecast:)` are built and
  tested against core's real documents (`testTheOptimizeButtonStatesTheRefusalAndThe
  MeasuredRemedy`), so a forecast handed to the page reaches the button with its
  counts and its measured remedy. The missing link is the **trigger**: a call site
  that runs `RelatticeRun.forecast` off-main when the configuration settles and
  publishes the result. That is the named remaining step, and it is small — one
  debounced call plus a `@Published` property — but it is not written, so the user
  does not see the forecast in the app yet. I am not calling F3 fully done on the
  app side. What IS on the page today: the "Rim only emits nothing" warning at the
  control, and the region volumes drawn against the variant's own material.
* **The forecast returns BEFORE the reproduction proof.** `lattice_variant_job`
  normally refuses outright if the restored design does not reproduce the margin the
  run recorded — the guarantee that the certificate describes the right object. The
  forecast exits before that solve, so it can answer for a design the real job would
  refuse. That is deliberate: the forecast makes no certification claim, it answers a
  geometry question, and declining to answer it because a later certification would
  fail would be unhelpful. It is stated here because it means **a forecast is not a
  promise that the run will be accepted** — only a statement of what the lattice
  itself would cover.
* **The per-variant design fetch costs bandwidth.** At 128³ with three accepted
  rungs the app now pulls ~17 MB, then ~34 MB, then ~50 MB over the LAN instead of
  ~50 MB once. On a LAN that is seconds; it is the price of a variant being workable
  the moment it appears, and it is stated rather than hidden.
* **The incremental flush is scoped to the STREAMING path** (`emit_progress`). Only
  a run someone is watching can be observed part-way; a batch `topopt-cli run`
  writes exactly what it always did.
* **A re-attached run still has no pair.** PR 284's disclosed limit, unchanged: the
  app no longer holds the document it sent and the worker does not serve `job.json`.
  Making the worker serve it is the obvious follow-up and was not done half-way.
* **On-device runs still cannot be smoothed or latticed.** PR 274's disclosed limit,
  unchanged.
* **I did not touch the optimizer.** The root cause of "99% fell back to solid" is
  that `minimize_plastic` optimizes assuming solid material and leaves tendrils
  thinner than the cells-per-member floor. That is `multiscale-lattice-to`'s. What
  this task owns is that you now learn it in under a second instead of after an hour.

---

## 11. In plain language

**What went wrong.**

You started a run on the Mac. It produced three variants and was still working on a
fourth when, about an hour in, the worker process died and restarted itself. You
didn't stop it — I checked, and the app that supervises it has been running since
July 22nd; only the Python process underneath it was replaced, at 17:04:18, and the
restart came exactly two seconds later, which is what that supervisor does when
something exits unexpectedly. The app did the right thing with the three variants —
it kept them. But both buttons under them were greyed out, saying the run hadn't
kept the files they need.

They were telling the truth. Those files did not exist. The program only wrote them
at the very end of the whole job, and your job never got to the end. Your worker's
folder still has your three shapes in it and nothing else — no report, no fields, no
design file. And the app only ever went looking for them at the very end too, so
even if they had been there, it would not have asked.

That is why the last fix didn't help. It put the collection step in the one place
your run never reached.

**What it does now.**

The design file is written after *every* variant, not once at the end. The app grabs
the job description the moment it submits the run, and the design the moment each
variant appears. So a variant is workable from the second you can see it — and if
the run dies later, everything it already produced stays usable. If a design does
arrive but doesn't cover a particular variant, that button says so specifically
rather than pretending.

**And the other half — knowing before you spend the hour.**

Your receipts said variant 038 latticed nothing, 052 latticed 82 voxels out of
10,485, all eight of your include regions covered about 99,558 voxels with no
material in them, and your boundary setting produced zero geometry. All four of
those are now computed *before* the run, in under a second, from the design and your
settings.

And they come with the reason, not just the number. In your case the reason is one
sentence: a lattice needs five cells across a piece of material, your cell is 4.6 mm,
so it needs 23 mm of thickness — and the shapes the optimizer left are thinner than
that almost everywhere. **No setting on that page could have changed it.** So the app
will not suggest a bigger cell; it will tell you that. Where a change *would* help,
it says by how much, because it actually tried it.

Two more things you couldn't have known. Your include regions were drawn in the
workspace but vanished the moment the lattice page opened — the one page about them
was the one page that hid them. They're drawn now, over the variant's real material,
so a region floating in empty space looks like a region floating in empty space.

And "Rim only", which was the default, can never produce anything on an optimized
part. It decorates the edges where flat faces meet, and an optimized part hasn't got
any — its surface comes from the voxel grid. Zero was the only number that line
could ever have shown you. The default is now "Full skin", and picking "Rim only"
warns you.

**Why did it die? I can't tell you — and that's a bug of its own.**

I chased it properly: no crash report, no out-of-memory kill, and the app that
supervises the worker never restarted. The Python process just exited. The reason it
printed on its way out went straight into a line of code that reads the worker's
output and throws it away, and the one status message that said "Worker exited (code
N)" was overwritten two seconds later by the restart. So the answer genuinely no
longer exists. I'd rather say that than give you a theory.

Two things now make sure that never happens again. Everything the worker prints goes
to a file (`~/.topopt-worker/worker-app.log`), and every unexpected exit writes a
line there naming the exit code, which jobs it killed, and the last forty lines the
worker said — and that record survives the restart instead of being wiped by it.

And the second one would have saved this run outright: when the worker came back it
had forgotten your job entirely, so every request for its files got "no such job" —
while the folder with your three shapes was sitting right there on disk. It now
serves them from disk. Combined with writing the design file after every variant,
your run would have been recoverable even after the worker died.

**One thing that is NOT finished, so you don't go looking for it.**

The forecast itself works and is proven — I ran it against five real configurations
and it matched what the actual job produced, exactly, every time. The wording that
would appear under the Optimize button is written and tested. But nothing on the
lattice page *asks* for it yet: there is no code that runs the forecast when you
change a setting. So today you can get those numbers from the solver, and the app
knows what to do with them, and the two are not yet joined up. It is a small piece —
one call and one property — and I would rather name it than let you find it.

The two things you WILL see on that page today: "Rim only" now warns you it emits
nothing, and it is no longer the default; and your include/exclude regions are drawn
over the variant's own shape instead of vanishing when the page opens.

Lastly: the app is now built and tested by CI. Four changes in a row shipped
app-side bugs behind a green tick because CI only ever built the solver.
