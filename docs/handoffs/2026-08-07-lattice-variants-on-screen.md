# 2026-08-07 — lattice variants on screen

APP-ONLY. `core/` untouched; `tools/topopt-worker/` untouched. CI: core-linux
(unaffected) + app-macos (`swift test --package-path app/TopOptKit`, green).

Evidence: `evidence/2026-08-07-lattice-variants-on-screen/`

---

## 0. Headline

**Your four latticed variants are in the variant list now, each with its own mass,
and Export writes the latticed file.** On your own run the recommended variant now
shows two objects side by side: the solid at **360 g** and its lattice at
**246 g**. The 246 g object was on the Mac all along.

**The line that was dropping them was one line, and it was in the app.** Core
prints a `LATTICE …` checkpoint per rung naming that rung's receipt AND its mesh.
The worker has no typed event for it, so it forwards it verbatim as a `log` event.
`RemoteRun.handleEvent` had `default: break` for log lines. The announcement had
been arriving on every lattice run you have ever done; nothing read it. No
protocol change was needed, and none was made.

**Three findings you should read before deciding anything:**

1. **The recommendation now points at the heaviest of your four latticed
   objects.** Lattice mass runs *opposite* to solid mass down your ladder —
   215.16 g at rung 0.68 rising to 246.38 g at rung 0.26 — and the rule
   ("the last accepted rung") picks the lightest *solid*. Following the
   recommendation costs **31.22 g, 12.7 %**. Reported, not changed — §6.
2. **None of your four latticed meshes can be displayed on your iPad.** Measured:
   showing the 1.42 GB rung costs **6.15 GB resident**. Your iPad Pro 12.9″ (5th
   gen, 128 GB) has **8 GB of RAM total**. Three of the four need more than the
   whole device; the fourth needs 5.55 GB of it. §4.
3. **Export is unaffected by (2) and always works.** An export streams the
   worker's file to disk and never decodes it — measured at one 8 MB buffer
   against the 6.15 GB a display costs. The one object you actually want to print
   is the one that was hardest to reach and is now the easiest.

---

## 1. The gap, traced

| | path | what it fetched |
|---|---|---|
| re-lattice | `RelatticeRunner.swift:457` | `variant_<vf>_lattice.stl` — **the mesh** |
| optimize | `RemoteRunner.swift:1039` (was) | `variant_<tag>_lattice.report.json` — **the report only**, for the *last* rung, and only when the job asked for a region breakdown |

So a lattice produced by an optimize run existed as numbers on a worker's disk and
as nothing else. It could not be shown, selected, weighed or exported, and there
was no per-variant latticed alternative in the list.

**The number that shows the cost.** Your run, worker job `ca62f91cba4b422d`:

* the app displayed the recommended variant at **360 g** — `fields.bin`, rung
  0.26, `massGrams: 360.304`, read at `RemoteRunner.swift:1708`
  (`massGrams: f?.massGrams ?? 0`) and rendered at `ResultsModel.swift:2279`;
* with **"Mesh: 358 g (est.)"** — `MeshExport.meshMassGrams` over the SOLID
  mesh, `ResultsModel.selectedMassComparison`;
* while `variant_026_lattice.report.json` recorded `lattice_mass_grams:
  246.38359375`.

### The mechanism, exactly

`run_job.cpp:7379-7407` (`emit_lattice`, `stream_lines` branch) prints, per rung:

```
LATTICE vf=0.260000 topology=octet cell_mm=2 graded=1 rho_min=0.265125 \
  rho_max=0.730898 cells=18868 tris=14660132 lattice_margin=933.089 \
  lattice_accepted=1 report=…/variant_026_lattice.report.json \
  mesh=…/variant_026_lattice.stl
```

`topopt_worker.py:262` (`_line_to_event`) recognises `PROGRESS ` and `VARIANT ` and
falls through everything else to `{"type": "log", "line": …}`.
`RemoteRunner.swift:1274` had `default: break`.

Your four real lines are captured verbatim at
`evidence/.../run_his/checkpoint_lines.txt` and every test here is driven from
them.

---

## 2. R2 — the failing test

`LatticeVariantsOnScreenTests.testEveryLatticedRungIsReachableAndNoMeshWasTransferred`
drives the app's **real** `RemoteRun` over a **real** HTTP socket
(`StubWorker.swift`) against your run's captured receipts, `fields.bin` scalars and
checkpoint lines, and asserts two things: every accepted rung carries its lattice's
own mass, and not one byte of a latticed mesh crossed the wire to get there.

Run against the pre-task behaviour (the `case "log"` handler disarmed, everything
else in place) — `evidence/.../R2_red.txt`:

```
Test Case '-[TopOptFlowsTests.LatticeVariantsOnScreenTests
  testEveryLatticedRungIsReachableAndNoMeshWasTransferred]' started.
LatticeVariantsOnScreenTests.swift:194: error: XCTUnwrap failed: expected
  non-nil value of type "LatticeVariantAlternative" - rung vf=0.68 announced a
  lattice on its LATTICE checkpoint line, so the app must carry that latticed
  object — this is the gap: the optimize path fetched the report and never made
  the lattice reachable
Test Case '…' failed (0.330 seconds).
	 Executed 1 test, with 1 failure (0 unexpected) in 0.330 (0.330) seconds
```

Green after (`evidence/.../R2_green.txt`): `Executed 16 tests, with 0 failures`.
Run three times consecutively; stable.

The second half of that test — **no latticed mesh is fetched** — passed before and
must keep passing. It is not a formality: eager fetching is the obvious
implementation and it is the one §4 disqualifies.

---

## 3. S1 — what the optimize path now does

`RemoteRunner.swift`:

* `handleEvent` gains `case "log"`, parsing `LATTICE …` lines via
  `LatticeCheckpoint.parse` into `latticeCheckpoints[vf]` (parsed scalars + two
  basenames; no geometry, so the 119 retention bound is unchanged — bounded by
  the ladder at ≈4, like `streamed`).
* `fetchLatticeAlternatives(acceptedRequestedVFs:)` — at final assembly, for each
  accepted rung that announced a lattice: fetch **that rung's own receipt** (~10 kB)
  and **HEAD the mesh** for its `Content-Length`. Never GETs the mesh.
* Attached per variant as `OptimizeVariant.latticeAlternative`, additive and
  defaulted nil, so a non-lattice run is byte-identical.
* Reached from the ONE assembly point both the live-completion and the **re-attach**
  paths use, so a run force-quit and resumed the next morning gets its latticed
  variants from the replayed checkpoint lines exactly as a watched run does.

`fetchRegionCells` — the pre-existing single-receipt read for the run-level region
roll-up — is untouched. It answers a different question.

### The receipt is authoritative, and the mesh is never weighed

`LatticeVariantAlternative.massGrams` is `lattice_mass_grams` from the receipt.
It is **not** derived from the mesh, and `selectedMassComparison`,
`selectedMeshVolumeMM3` and `selectedMeshWatertight` all now return nothing for a
latticed selection. A latticed STL is an interpenetrating **soup** — struts weld
through each other and through the solid companion body — so the
divergence-theorem volume the app computes for a solid variant double-counts every
overlap. The screen says this rather than leaving it implied:

> 246 g from the lattice certification receipt (voxel basis) — a latticed mesh is
> an interpenetrating soup, so it has no enclosed volume to weigh.

### S1(c) — the refusal, which is the point

A transfer that cannot happen is stated in full, with the numbers, and the app
never falls back to the solid. `ResultsModel.selectedMesh` returns **nil** for a
latticed selection with no transferred geometry rather than returning the solid's,
and the caption is what explains the empty viewer. Silent substitution is what
cost you the night, and it is now unrepresentable rather than merely avoided.

---

## 4. R3 — measured transfer and memory

Measured with the app's own fetch and its own STL decoder
(`LatticeMeshTransferProfileTests`, release build, M2 Pro 16 GB, loopback HTTP).
Raw output: `evidence/.../R3_transfer_profile.txt`.

**Rung 0.52 — `variant_052_lattice.stl`, 1 420 059 884 bytes, 28 401 196 triangles**

| step | wall | peak footprint |
|---|---|---|
| in-memory GET (today's `fetchMesh` shape) | 2.13 s | **4.30 GB** |
| … + `MeshExport.parseBinarySTL` | 3.44 s | **6.07 GB** |
| streamed to disk (`downloadTask`) | 1.69 s | 1.45 GB |
| … + mapped decode | 9.65 s | **3.21 GB** |
| … + `ViewerMesh` (what the viewer draws) | 13.07 s | **6.15 GB** |

Three things follow.

1. **The in-memory GET is the dominant cost, not the geometry.** `URLSession`'s
   accumulating `dataTask` held **4.30 GB for a 1.42 GB body — 3.0× the payload**.
   The transfer `fetchMesh` performs is more expensive than the object it
   transfers. Streaming the same bytes to a file held 1.45 GB.
2. **Display costs ~6× the file.** The decoded soup is 48 B/triangle; `ViewerMesh`
   then adds smooth normals *and* the unshared flat render buffer — 156 B/triangle
   more.
3. Loopback ran at 666–841 MB/s. **That is a floor, not your experience.** Over a
   real Wi-Fi LAN the 1.42 GB rung is minutes, and your four are 5.17 GB.

### The iPad — and this is where it stops

Your device: **iPad Pro 12.9″ (5th generation), iPad13,8, 128 GB → 8 GB RAM**,
iPadOS 26.5.2 (read from the attached device with `devicectl`).

At the gate's 6.0× display factor plus its 25 % reserve:

| rung | mesh | display needs | + reserve | vs **8 GB total RAM** |
|---|---|---|---|---|
| 0.26 | 740 MB | 4.44 GB | 5.55 GB | 69 % of the whole device |
| 0.38 | 1.06 GB | 6.35 GB | 7.94 GB | 99 % of the whole device |
| 0.52 | 1.42 GB | 8.52 GB | 10.65 GB | **exceeds physical RAM** |
| 0.68 | 1.95 GB | 11.73 GB | 14.66 GB | **exceeds physical RAM** |

**BLOCKED-STOP, for display only: none of your four latticed meshes can be shown
on your iPad.** The argument does not depend on knowing the exact jetsam limit —
physical RAM is a hard upper bound on it, three of the four exceed physical RAM
outright, and no iOS app is granted 5.55 GB of an 8 GB device.

What I did and did not do on hardware, stated plainly:

* **Did**: identified the device; confirmed the iOS *device* build (arm64, generic
  platform=iOS) compiles and links clean with the new code, including
  `os_proc_available_memory()`.
* **Did not**: run the latticed path on the iPad and read
  `os_proc_available_memory()` back. `swift test` cannot target a device
  (`Tool-hosted testing is unavailable on device destinations` — the package has no
  host app), and reaching the path in the shipping app needs a live LAN worker run
  of your part. The app now logs the device's own figure and the decision it drove
  (`LatticeMeshBudget.logDecision`, subsystem `app.topopt`, category
  `lattice-budget`), so a device QA pass reads the hardware's answer instead of
  this table's arithmetic. **That log line is the one open device-QA item.**

### What the app does about it

`LatticeMeshBudget` asks the OS (`os_proc_available_memory()` on iOS; physical
memory less current footprint on macOS) and refuses **before** starting a transfer
that would take the app down part-way. The refusal is a *result*, not an error:
mass, margin and verdict are unaffected, and Export still works.

The 6.0× factor is derived from the layout — (50 STL + 48 soup + 156 ViewerMesh)/50
= 5.08× — then **raised** to clear both measurements (4.33× on the 1.42 GB rung,
5.17× observed in situ on the 740 MB rung). They differ because how much of the
mapped file stays resident is the kernel's call. A gate that under-predicts is a
gate that lets a crash through, so it is set above everything observed. *(The first
version of this constant was fitted to a single measurement at 4.33× and would
have under-predicted the second run by 19 %. The R1 evidence run is what caught
it.)*

---

## 5. S2 — what is on screen

`ResultsModel.buildTabs` now emits, per accepted rung, its solid tab and — right
beside it — its latticed tab. Your run: **8 tabs for 4 rungs**.

```
solid    rung −20% · 544 g        latticed rung −20% · 215 g
solid    rung −31% · 473 g        latticed rung −31% · 240 g
solid    rung −40% · 412 g        latticed rung −40% · 245 g
solid    rung −47% · 360 g        latticed rung −47% · 246 g   ← RECOMMENDED rung
```

No new page: the variant list is where you already look.

### S2(b) — every displayed mass, and where it comes from

| what | value on your run | source | file:line |
|---|---|---|---|
| solid variant mass (the tab, the chip) | 543.73 / 473.32 / 412.47 / **360.30** g | **voxel field** — `fields.bin` per-rung scalar | `RemoteRunner.swift:1708` → `ResultsModel.swift:2279` |
| "Mesh: N g (est.)" caption | 358 g on the recommended rung | **mesh-derived** — divergence theorem over the solid isosurface | `ResultsModel.selectedMassComparison` → `MeshExport.meshMassGrams` |
| **latticed variant mass** (the tab, the headline) | 215.16 / 239.93 / 244.78 / **246.38** g | **voxel basis, via the certification receipt** — `lattice_mass_grams`, core's own accounting of the object it certified (`run_job.cpp:2122`) | `LatticeVariantAlternative.receiptFacts` → `ResultsModel.latticedTab` |
| latticed mesh cross-check | **none, deliberately** | — | `selectedMassComparison` returns nil for a latticed selection |

Mesh-derived: exactly one, the solid "Mesh: N g" caption. Voxel-derived: the solid
tab mass (from the FEA field container) and the latticed tab mass (from the
certification receipt). They are different voxel accountings of different objects
and are labelled as such.

Three more things a latticed tab deliberately does **not** inherit from its solid:

* **support estimate** → `n/a`. Support is estimated from the solid's overhang
  voxels; the latticed object is a different shape.
* **layer-shear classification** → new `LayerShear.unknown`, rendering `n/a`. The
  composite certification reports one worst case, not the in-plane/interlayer split
  that classification reads.
* **savings percentage** → not shown as the headline. `1 − printedFraction` is
  measured for the solid rung only; nothing reports a latticed printed fraction. A
  latticed tab leads with its **mass** instead, which is the figure that *is*
  measured for it. Its rung is named in the sub-line (`latticed · from −47%`).

The latticed object's **own** certification verdict is a separate badge
(`latticeAccepted`), never the rung's.

### S2(d) — export

* A latticed selection exports the **latticed** file, streamed from the worker
  straight to disk. `exportSTLData()` returns nil for a latticed selection so a
  caller that forgot to branch produces *nothing* rather than the wrong object
  under the right name.
* `canExport` is true for a latticed variant **even when it cannot be displayed** —
  gating export on `meshVertices`, which a latticed variant deliberately never
  carries, would have made the one object you want to print the one you cannot get.
* The filename carries `-latticed`: `M2_vertical_stand-PLA-47pct-latticed.stl`.
  Without the tag the 246 g object overwrites the 360 g one in Files under the
  360 g one's name.
* Export is checked against **free disk**, not memory.

---

## 6. S2(c) — the finding the recommender gets backwards

**Reported. The rule is unchanged.** Full working:
`evidence/.../S2c_recommender_inversion.txt`.

| ladder position | rung | solid (g) | latticed (g) | lattice ÷ solid | mesh |
|---|---|---|---|---|---|
| 1st | 0.68 | 543.73 | **215.16** | 0.396 | 1.95 GB |
| 2nd | 0.52 | 473.32 | 239.93 | 0.507 | 1.42 GB |
| 3rd | 0.38 | 412.47 | 244.78 | 0.593 | 1.06 GB |
| 4th | 0.26 | **360.30** | 246.38 | 0.684 | 740 MB |

The rule is `recommendedIndex = variants.count - 1` — the last accepted rung, i.e.
the lightest **solid** (`ResultsModel.buildTabs`). Solid masses descend down the
ladder; latticed masses **ascend**. They are monotone in opposite directions, so
the recommendation lands on the rung whose lattice is the **heaviest of the four**:
246.38 g against 215.16 g, a **31.22 g / 12.7 %** penalty.

Mechanically: the lattice replaces printed material with 26.5–90 %-density octet.
A heavier rung has more material inside the include region to convert. A rung
already optimized down has less left to gain — the ratio column shows it directly.

Two things worth weighing before you rule:

* The four latticed objects span only **31 g** (215–246) while their solids span
  **183 g** (360–544). Most of a latticed object's mass is what the lattice does
  *not* touch — the solid companion body and the shell — which barely moves along
  the ladder.
* **The lightest lattice is on the 1.95 GB mesh; the heaviest is on the 740 MB
  one.** Ranking by latticed mass would systematically point at the least
  transferable rung.

**Do not generalise the direction.** On a uniform-lattice fixture
(`/private/tmp/m4/C1_base`, 6 mm octet, no grading) the latticed masses *rise* with
the rung, the same direction as the solid: 11.00 / 12.57 / 14.40 / 16.49 g. So the
recommendation is not reliably backwards — it is **ungrounded** once a lattice
exists. On your part it points at the heaviest; on that one it happens to point at
the lightest. Neither is because the rule considered the question.

`testTheRecommendationPointsAtTheHeaviestLatticedObject` **pins** the current
behaviour, so changing the rule later has to be done deliberately and out loud.

**The ruling I need from you** — three separable questions:

1. Should the recommendation rank latticed objects at all?
2. If so, jointly over (rung, lattice), and by what?
3. Does "Minimize plastic" mean minimum **printed** mass (the lattice) or minimum
   **optimized volume** (the solid) once both exist?

---

## 7. R1 — the path, end to end, on your own run

`LatticeVariantsHisRunEvidence` points the same stub worker at the real job
directory — real receipts, real `fields.bin`, real solid meshes, and the real
5.17 GB of latticed STLs. Raw: `evidence/.../R1_end_to_end.txt`.

```
== R1: his four-variant run, end to end ==
  worker output: /Users/nadim/.topopt-worker/ca62f91cba4b422d/out
  variant_068_lattice.stl  1954879484 bytes (1.95 GB)
  variant_052_lattice.stl  1420059884 bytes (1.42 GB)
  variant_038_lattice.stl  1058859084 bytes (1.06 GB)
  variant_026_lattice.stl   740360884 bytes (740 MB)
  [1] run completes: 4 accepted rungs in 0.50 s
  [1] latticed-mesh GETs during the run: 0 (the real files were right there)
  [2] variant list: 8 tabs
        solid    rung −20% · 544 g      latticed rung −20% · 215 g
        solid    rung −31% · 473 g      latticed rung −31% · 240 g
        solid    rung −40% · 412 g      latticed rung −40% · 245 g
        solid    rung −47% · 360 g      latticed rung −47% · 246 g
  [3] selected the RECOMMENDED rung's latticed variant: 246 g (its solid: 360 g)
      provenance: 246 g from the lattice certification receipt (voxel basis) …
      geometry:   variant_026_lattice.stl on the worker · 740 MB · 14660132 strut triangles
  [4] asking for the geometry. device headroom reported as 16.59 GB
      READY: 14807216 triangles in 1.62 s
      viewer mesh: 14807216 triangles
      footprint now 4.41 GB (was 589 MB)
  [5] export writes: M2_vertical_stand-PLA-47pct-latticed.stl (streamed: true)
      wrote M2_vertical_stand-PLA-47pct-latticed.stl (740360884 bytes) in 2.16 s
      byte-for-byte the worker's variant_026_lattice.stl ✓
```

Every step of R1: run completes → latticed variant appears → its mass is the
latticed mass → selecting it shows the latticed geometry → export writes the
latticed file, byte for byte. On the **recommended** rung — the one whose solid
you were shown at 360 g.

Step [4] ran on the Mac. On your iPad it is the refusal in §4 instead; steps
[1][2][3][5] are device-independent.

**A small discrepancy this surfaced, now labelled rather than hidden:** the
checkpoint line says `tris=14660132`; the file decodes to **14 807 216**, 1.0 %
more. The line counts what the lattice *generator* emitted; the file also carries
the solid companion body. Before the mesh arrives the caption says "strut
triangles"; once it is here, the ready state reports the file's own count.

---

## 8. Bars

| bar | status |
|---|---|
| **R1** demonstrably usable, on his own run | ✅ §7 — all five steps against the real 5.17 GB |
| **R2** failing test first | ✅ §2 — red pasted, green pasted, 3× stable |
| **R3** measured transfer + memory | ✅ §4 — wall time, peak RSS, iPad answered as far as hardware allows; the one gap named |
| **R4** no assertion weakened or deleted | ✅ message census below |
| **R5** no unfilled placeholders, no scratch at root | ✅ verified |
| **R6** separate commit for any review response | pending review |

### R4 — assertion-message census (`evidence/.../R4_assertion_census.txt`)

Not a name grep. Three sets compared between the merge base and the working tree:
test function names, every string literal in the test tree, and the assertion-kind
histogram.

```
1. TEST FUNCTIONS   before=1334  after=1354
   removed:                                    ← empty
2. ASSERTION / LITERAL MESSAGES   before=3475  after=3685
   removed:                                    ← empty
3. ASSERTION KINDS   every kind non-decreasing:
     XCTAssertEqual 2441→2483   XCTAssertTrue  948→968   XCTUnwrap 467→493
     XCTAssertFalse  500→508    XCTAssertNil   341→350   XCTFail    86→91
     XCTAssertGreaterThan 182→187   XCTAssertNotNil 136→139  … (no kind fell)
```

The script is checked in and re-runnable: `evidence/.../assertion_census.sh`.

### R5

`git status` shows nothing at the repository root. New files are under
`app/TopOptKit/{Sources,Tests}` and `evidence/2026-08-07-lattice-variants-on-screen/`.
No `TODO`/`FIXME`/`TBD`/placeholder token in the diff.

---

## 9. Files

**New**

| file | what |
|---|---|
| `Sources/TopOptKit/LatticeVariantAlternative.swift` | `LatticeCheckpoint` (the CLI line parser) + `LatticeVariantAlternative` (the rung's latticed object, mesh-free) |
| `Sources/TopOptFlows/LatticeMeshBudget.swift` | can this device hold that mesh — the measurement, encoded, and the refusal sentence |
| `Sources/TopOptFlows/LatticeMeshTransfer.swift` | on-demand streamed transfer (`downloadTask`), HEAD size probe |
| `Tests/…/StubWorker.swift` | in-process HTTP worker so `RemoteRun` can be driven under plain `swift test`, with a request log |
| `Tests/…/LatticeVariantsOnScreenTests.swift` | 16 tests, all driven from his captured run |
| `Tests/…/LatticeVariantsHisRunEvidence.swift` | bar R1, gated on `TOPOPT_LATTICE_HIS_RUN` |
| `Tests/…/LatticeMeshTransferProfileTests.swift` | bar R3, gated on `TOPOPT_LATTICE_TRANSFER_PROFILE` |

**Changed**

`RemoteRunner.swift` (log-event case, `fetchLatticeAlternatives`, HEAD probe,
mesh-source handle) · `TopOptKit.swift` (`OptimizeVariant.latticeAlternative`) ·
`ResultsModel.swift` (tab kinds, latticed selection, transfer state, streamed
export) · `ResultsScreen.swift` (latticed tab badge, the state caption, streamed
export branch, entry callbacks routed through `selectedVariantIndex`) ·
`OutcomeStore.swift` (round-trip DTO) · `RunModel.swift` + `WorkspacePlaceholder.swift`
(carrying the mesh-source handle).

### One quiet fix worth naming

`ResultsScreen` passed `model.selectedIndex` — a **tab** index — into `onSmooth`,
`onLattice`, `smoothEntry` and `latticeEntry`, which index accepted **variants**.
They coincided while there was one tab per rung. They no longer do, so all four now
go through `model.selectedVariantIndex`. Both of a rung's tabs answer with the same
variant, which is right: smoothing and re-latticing act on the rung's design field,
not on whichever mesh is on screen.

---

## 10. Open

1. **Your ruling on the recommendation** (§6, three questions). Nothing moves until
   you answer.
2. **Device QA**: read `LatticeMeshBudget.logDecision` off the iPad on a real
   lattice run (subsystem `app.topopt`, category `lattice-budget`) and confirm
   `os_proc_available_memory()` against §4's arithmetic.
3. **Displaying a latticed mesh on an iPad at all.** Nothing here makes that
   possible and §4 says why. If you want it, the object has to shrink before it
   arrives — a decimated proxy, or the existing raymarched lattice preview
   (0 triangles) driven from the density field rather than the STL. That is its own
   task; I have not started it.
4. **Streamed-in latticed variants.** A `LATTICE` line arrives *after* its rung's
   `VARIANT` line, so the alternative attaches at final assembly. A run that never
   reaches its terminal event keeps its solid variants (as before) but not its
   latticed ones. A re-attach recovers them from the replay.

---

## In plain language

Last night your Mac made eight objects, not four. For every variant it also built
a latticed version — the same shape with a lattice inside instead of solid
plastic. The app only ever showed you the four solid ones. The latticed ones were
sitting in a folder on the Mac, and the only way to know they existed was to go
and look.

That is fixed. Each variant now has a second card next to it in the list, marked
LATTICED, with its own weight. On the variant the app recommends, that reads
360 g for the solid and 246 g for the lattice — a third lighter, and it was there
all along. Tapping Export on the latticed card downloads the latticed file, not
the solid one.

Two honest limits.

The latticed files are enormous — three quarters of a gigabyte to two gigabytes
each, five gigabytes for the set. Your iPad has eight gigabytes of memory in total
and *looking at* one of these would need between five and fifteen. So on the iPad
you will see the latticed variant's weight, its safety margin and its verdict, and
you will be able to export it and print it — but you will not be able to spin it
around on screen. When you tap to view it, the app now tells you that in words,
with the numbers, instead of quietly showing you the solid one and letting you
believe it was the lattice. That silent swap is what cost you the night, and it
cannot happen any more: if there is no latticed geometry to draw, the app draws
nothing and explains why.

The second one you need to decide, not me. The app recommends a variant by picking
the one that saves the most plastic — and that has always meant the lightest
solid. But the lattice works the other way round: the *heavier* a variant is to
start with, the more material there is to hollow out, so it ends up lighter once
latticed. On your run the recommended variant's lattice is the heaviest of the
four, at 246 g, while the variant the app ranks worst has a 215 g lattice. Thirty
grams, about thirteen percent, for following the recommendation. I have not
touched the rule — that is a change to what the app tells you to print, and it is
your call. I have written down exactly what happens and added a test that will
complain loudly if anyone changes it without saying so.

One more thing worth knowing: on a different part I checked, the effect runs the
other way. So the recommendation is not simply backwards — it just was never
asking about lattices at all.
