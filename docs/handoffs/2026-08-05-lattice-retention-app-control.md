# The iPad can finally ask for a sub-floor lattice — and see what each region got

Task: `lattice-retention-app-control`
Evidence: `evidence/2026-08-05-lattice-retention-app-control/`
Branch: `claude/lattice-retention-app-control-3f7186`

## Build ritual — APP ONLY

**Nothing in `core/` changed.** `git diff HEAD -- core/` is empty on this branch.

```bash
./app/scripts/build_core.sh && swift test --package-path app/TopOptKit
```

`build_core.sh` is needed because the app package links a vendored xcframework and
this branch adds bridge functions — but it rebuilds the SAME core sources that are
on `main`. **No core source rebuild is required of you beyond that, and the worker
does not need restarting.** CI: `core-linux` (untouched) + `app-macos`.

### ★ MERGE ORDER, AND IT IS NOW A HARD BUILD DEPENDENCY

**PR 298 (`lattice-cell-size-adaptation`) must be in `main` before this branch. It
is** — it merged as `207482b`, and this branch has been REBASED onto it, so the
ordering is resolved rather than merely documented.

Two of this branch's four grading keys (`subfloor_per_region`,
`report_region_cells`) are PR 298's, and core's schema refuses an unknown grading
key outright. Since the review, one more dependency became a COMPILE-time one: the
per-region messages read core's PERCOLATION floor
(`topopt::lattice_percolation_cells_per_member_min`, review P2), and that function
arrives with PR 298. **The app package no longer builds against a pre-298 core.**
That is stated rather than worked around: 298 is in `main`, the worker and the app
must run the same core anyway (the fingerprint guard), and adding compile-time
gymnastics for a core that no longer exists on `main` would be waste.

The capability probe (§2) is therefore now a SAFETY NET rather than a live gate —
against a stale vendored xcframework — not the mechanism that makes two of the keys
optional. On any core this branch can build against, all four probe true.

---

## 0. WHAT CHANGES FOR YOU

**Four things core could already do, that your iPad could not ask for, it can now
ask for. And the receipt you have been asking for since your overnight run reaches
your screen.**

1. **A switch on the Lattice page: "Keep the lattice where the part is too thin to
   certify it."** Off by default. It sends
   `grading.retain_subfloor_in_unloaded_regions`, which core has parsed since PR 295
   and which no device has ever been able to set.

2. **Before you commit, the control tells you the size of what you are accepting.**
   On a 1,257-voxel lattice with 822 voxels under the cells-across floor it reads:
   *"Up to 822 voxels — 65.4% of the 1,257 voxels this lattice covers would be
   latticed with no certificate over them."* That number comes from core's own
   pre-flight, before the run, not from a receipt afterwards.

3. **A "Report what each region got" switch.** With it on, **on a graded (Auto
   density) run**, the results screen says region by region: voxels latticed, voxels
   left solid, and why. **A region that received nothing is named FIRST**, in a
   headline: *"5 of 7 regions received NO lattice: Region 1, Region 2, Region 3,
   Region 4, Region 5."*

   ★ **IT WOULD NOT HAVE FIRED ON YOUR OVERNIGHT RUN, AND THE FIRST VERSION OF THIS
   HANDOFF CLAIMED IT WOULD.** That run was UNIFORM — its `run_info.json` carries a
   `lattice` block with `rho_min == rho_max == 0.3631365741` at an 8 mm cell and no
   `grading` block at all, which is exactly the run PR 298's own N1 analysis uses to
   show the uniform path applies no accuracy floor (1131 cells at 0.4263 cells per
   member, `strut_gated` false). Core's per-region report exists only on the graded
   path, so there would have been nothing to render.

   **What it would have taken to catch YOUR run is a per-region emitted-cell receipt
   on the UNIFORM path.** That does not exist in core. PR 298 flags it as its own
   largest remaining gap (§8 of that handoff: *"the number that would have told him
   instantly what was wrong is 'region k received 0 cells; 1131 cells went
   elsewhere', and that number still does not exist"*). **That is the dependency,
   named**: this PR makes the graded receipt reachable; the uniform one is core
   work, and it is the next thing worth building (§7).

4. **★ THE CELL-SIZE CONTROL COULD NOT REACH THE NUMBER YOUR OWN REFUSALS NAME, AND
   NOW IT CAN.** PR 298's pre-flight tells you to set `cell_mm` to about 1.2 mm on
   your part. At your 0.45 mm line width the control's minimum was **4.93 mm** and
   typing was quantised to half a millimetre, so 1.2 became 1.0 and then clamped to
   4.93. Two independent walls, neither of them core's: core accepts any positive
   cell (`lattice "cell_mm" must be > 0`, `job.cpp:851`). The minimum is now
   **1.173 mm** — core's own arithmetic at the same bead — and typed values are
   exact to two decimals. **This is a defect this task found, not one it was told
   about.**

**The default path does not move.** With every new control untouched, the job
document your worker receives is byte-for-byte what it was. Proven by comparing
built dictionaries, not by reading the code (§R1).

**One honest limit up front.** The per-region breakdown counts **voxels, not emitted
cells**, and exists only on a graded (Auto density) run — that is what core measures
today, and PR 298 flags the emitted-cell counts and the uniform path as its own
largest remaining gap. The app says so on screen rather than relabelling voxels as
cells.

---

## 1. THE DEFECT, WITH FILE AND LINE

`RemoteRunner.swift`'s grading dictionary emitted exactly six keys — `topology`,
`min_extrudable_width_mm`, `cell_mode`, `cell_min_mm`, `cell_max_mm`, `cell_mm`.
`RelatticeRunner.swift` built its own copy of the same six. Neither emitted
`retain_subfloor_in_unloaded_regions`.

The consequence ran further than "the switch is missing". Core echoes the request
back into its pre-flight forecast as `subfloor_retention.requested`
(`run_job.cpp:3391`, `const bool want_subfloor =
job.grading.retain_subfloor_in_unloaded_regions`). Because the app never sent the
key, that field was **always false on every device path**, and the branch at
`LatticeForecast.swift:202` — three paragraphs explaining to the user exactly what
retention buys and what it costs — was **dead code**. The app was rendering the
receipt of a thing it could not request.

---

## 2. S1 — SEND THEM

### Failing test first (bar R2)

`app/TopOptKit/Tests/TopOptFlowsTests/LatticeRetentionControlTests.swift` drives the
REAL job-building paths — `RemoteRun.buildJobJSON()` and
`RelatticeJobBuilder.build` — never a hand-assembled dictionary.

Run against the unfixed serializer (data model present, emission absent):

```
Executed 24 tests, with 16 failures (0 unexpected)
```

Full output: `evidence/.../s1_failing_before.txt`. The five failing cases and the
shape of their failure:

```
testArmedRetentionReachesTheOptimizeJob : XCTAssertEqual failed: ("nil") is not
  equal to ("Optional(true)") - the switch itself must reach the worker
testArmedRetentionReachesTheRelatticeJob : XCTAssertEqual failed: ("nil") is not
  equal to ("Optional(true)") - a re-lattice must carry the same posture as the
  optimize run
testTheCeilingIsOmittedWhenTheUserHasNotMovedIt : ("nil") is not equal to
  ("Optional(true)")
testAPartiallyCapableCoreGetsExactlyWhatItAccepts : ("nil") is not equal to
  ("Optional(true)")
testTheForecastRetentionBranchIsReachableThroughTheRealSerializer :
  XCTAssertTrue failed - the job must carry the key, or core can never echo it
  back and the branch stays dead
```

That last one printed the forecast's actual reason lines, and they are the
not-requested branch — the dead-branch defect reproduced directly.

After the fix, and after the review's P2 rewrite: **45 tests, 0 failures**.

### What ships

`LatticeSettings` gained four raw choices (`retainSubfloorInUnloadedRegions`,
`subfloorStressFraction`, `subfloorPerRegion`, `reportRegionCells`), all off /
absent by default and all `decodeIfPresent` so every older project snapshot decodes
unchanged. `runSpec` resolves them onto `LatticeSpec`; both serializers emit.

**ONE grading-block builder, not two.** `RemoteRunner` and `RelatticeRunner` each
wrote the block out key for key. That is two chances to drift, and a re-lattice that
silently drops the posture is the same class of bug as the
ladder-position-in-a-fraction-shaped-key failure that killed every re-lattice in
48 ms. Both now call `LatticeSpec.gradingDictionary()`
(`LatticeSettings.swift`). A one-sided edit is no longer expressible, and
`testBothSerializersEmitTheSameGradingBlock` asserts the two blocks are equal — with
a **positive control first**, because an equality bar between two empty dictionaries
passes vacuously and this project has shipped exactly that.

**The three rules the task set, each with its test:**

* `subfloor_stress_fraction` is sent **only when you have moved it off core's
  number**. `nil` means "core takes its own constant at call time", which is a
  different document from one restating 0.20 — and restating it would make the app
  the author of a number it merely read. The control shows *"core's 20%"*, read from
  core through the bridge (`lattice_subfloor_retention_stress_fraction()`), and only
  becomes a sent key once you type one.
* `subfloor_per_region` is **never armed while retention is off**. Core's schema
  refuses that combination ("a job that means one thing and says another",
  `job.cpp`), and the app now refuses to build it — structurally, by nesting the
  emission inside the retention branch, and again in the UI, which clears the
  dependents when you switch retention off.
* **Everything defaults off, and the untouched job is byte-identical.** §R1.

### ★ A key the linked core does not know is NEVER sent

`reject_unknown_keys` fails the **whole job** on one unrecognised grading key. That
is not a degraded run; it is a dead one. Two of the four keys
(`subfloor_per_region`, `report_region_cells`) arrive with PR 298 and do not exist
on `main`.

So the app **asks core's parser** rather than mirroring a boolean:
`topoptbridge::grading_schema_accepts` hands `topopt::parse_job` a document carrying
the key and reads whether the schema refused it **by name**. A hardcoded "core
supports this" constant is the failure `LatticeCoreCapability` already carries its
own scar for — PR 284 wrote one, PR 285 made it false the same evening, and the app
spent two PRs quoting a core rule that no longer existed. When PR 298 lands and you
rebuild, the two extra controls light up on their own, with no constant for anyone
to remember to flip.

**The probe proves itself both ways before it is believed** (`probe_reliable()`): a
key core has carried since the grading law landed must come back ACCEPTED, and a key
no core carries must come back REFUSED. If either control fails, every capability
answer is a conservative `false` and the UI says the app could not ask.

★ **The negative control caught its own bug on the first run.** It was
`__topopt_bridge_probe_key_no_core_accepts`, and core treats a leading-underscore
key as a maintainer COMMENT and ignores it at every level (`is_comment_key`,
`core/src/cli/job.cpp`). Core accepted it, the control failed, and the probe reported
itself unreliable on a core it could read perfectly. Renaming it to
`topopt-bridge-probe-key-no-core-accepts` fixed it. That is what a two-sided control
is for.

### ★ The strongest form of the bar: core's own parser accepts what the app builds

`testEveryJobTheAppBuildsIsAcceptedByCoresOwnParser` hands the **actual bytes** from
both serializers to `topopt::parse_job` (via a new
`topoptbridge::job_schema_error`) and asserts core accepts them — untouched, armed,
and armed-with-a-moved-ceiling, on both the optimize and re-lattice documents. A job
can carry exactly the right key names and still die on a value's SHAPE, which is
precisely how every re-lattice of a growth variant died. It has a positive control
(a deliberately broken document must be refused) and a companion test measuring the
converse: one unknown grading key kills the whole job.

---

## 3. S2 — THE CONTROL, AND ITS COPY

One card on the Lattice page's cell/density pane. **Off by default.** The copy, as
it renders:

> **Keep the lattice where the part is too thin to certify it**
> This region's members are thinner than a certified lattice needs. Turn this on and
> the lattice is built anyway — the strength certificate will not cover it, and the
> part is stamped out of regime.

A test asserts the strings "advanced", "expert" and "unsafe" appear in neither the
title nor the body.

**Retention rides the graded path only**, because the keys live in the `grading`
block and a uniform lattice run carries no grading block for core to read. The
control says exactly that rather than greying in silence: *"Set Density mode to Auto
— retention is part of the grading law, and a uniform lattice run carries no grading
block for it to ride."*

### The dead branch is live, proven through the real serializer

`testTheForecastRetentionBranchIsReachableThroughTheRealSerializer` builds the job
through `RelatticeJobBuilder`, reads
`grading["retain_subfloor_in_unloaded_regions"]` back out of those bytes, and feeds
**that value** — core's own rule, `want_subfloor = job.grading.retain_...` — into a
forecast document shaped as `run_job.cpp` writes it. The branch's reachability is
therefore a function of what the serializer emitted, not a constant the test chose.
It asserts all three paragraphs appear, including the 20% ceiling core echoed back.

### The exposure, before you commit

Core's pre-flight already reports `subfloor_retention.voxels_below_floor` (exact —
the cells-per-member predicate never sees density, so the forecast's band-floor
approximation cannot move it) and `region_voxels`. The control shows both, live,
against the settings currently on screen — `LatticeForecastModel.forecast(for:)`
returns nil the moment the job document moves, so a stale forecast can never be
shown as if it described what you are looking at.

Armed:

> Up to 822 voxels — 65.4% of the 1,257 voxels this lattice covers would be latticed
> with no certificate over them. It is an upper bound: they are kept only where the
> region's own peak stress measures at or under the ceiling below, and the run
> reports which.

Off:

> 822 voxels here — 65.4% of the 1,257 voxels this lattice covers are below the
> cells-across floor and will stay SOLID. Turning this on is what would lattice them.

**The denominator is named** ("the voxels this lattice covers") rather than left to
read as "the part", because with include regions declared that is the candidate set,
not the printed part. **It is an upper bound and says so**: the predicate that
decides retention needs a stress field, and the pre-flight runs before any solve.

---

## 4. S3 — AUDIT: IS THE REMEDY THE REFUSALS NAME REACHABLE?

**Status: it was NOT. It is now. The fix was a bound.**

### The cell-size control, as it stood

| property | value | source |
|---|---|---|
| minimum | `bounds.cellFloorMM ?? 2.0` → **4.93 mm** at 0.45 mm line width | `LatticePage.swift` `cellSliderRange` |
| maximum | 20 mm | `cellSliderMaxMM` |
| step | **0.5 mm — on typed input as well as drag** | `clampCell`, `(v * 2).rounded() / 2` |
| 1.2 mm reachable? | **No**, for two independent reasons | |

Typing 1.2 quantised to 1.0, then clamped up to 4.93. Even without the
quantisation, the floor alone was 4× the value the refusal names.

### Root cause, with file and line

`LatticeBounds.compute` set `cellFloorMM` from
`TopOptKit.latticeCellBounds(...).printabilityFloorMM`
(`LatticeSettings.swift`), which forwards core's
`lattice_cell_printability_floor_mm` — and **that number is evaluated at the band's
LIGHTEST density** (rho_min = 0.05047). It is the smallest cell at which even a
rho_min lattice prints. Nothing forces anyone to lattice at the lightest density,
which is the same point PR 298 makes from the other side about the "23 mm member"
you were told you needed.

Core itself refuses no such cell: `lattice "cell_mm" must be > 0` (`job.cpp:851`),
and a *graded* target is raised to the floor, never refused. **The app was the only
thing in the way.**

### The fix

* **A second floor, READ FROM CORE.** `LatticeCellBounds` gained
  `printability_floor_densest_mm` — the same core law, `w / phi(rho, 1)` with
  `phi = topopt::octet_strut_diameter_mm`, evaluated at `lattice_rho_max`. Below it
  nothing prints at any density; between it and the light floor a cell prints at the
  dense end, which is the range a refusal tells you to type in.

  ★ **The first cut of this derived it in Swift** from `LatticeType.strutRadiusMM`
  and got **1.643 mm** at a 0.45 mm bead where core's own arithmetic gives
  **1.173 mm** — the app's copy of the octet strut law is 1.4× off core's. A bound
  that disagrees with the refusal quoting it is no better than the bound it
  replaced, so it is read from core. (Measured: PR 298 quotes 1.09496 mm at a
  0.42 mm bead; 1.09496 × 0.45/0.42 = 1.1732, which is what the bridge returns.)

* **Typed input is exact to two decimals**; dragging keeps its half-millimetre
  detents, so the shipped gesture is unchanged. The display shows two decimals when
  the value needs them, so a cell typed as 1.17 mm does not read back as "1.2 mm".

* **The envelope moved out of the SwiftUI view** into `LatticeCellEntry`, a pure
  value type. The audit's question — can the user type the number a refusal names? —
  previously lived in two `private` functions on a view where no test could reach it.
  Six tests now pin it.

* **A cell under the LIGHT floor is legal and says what actually happens on each
  path**, because the two paths differ: *"A graded run has its cell raised to that
  number; a uniform run builds the cell you typed, and its struts print because it
  fills at the dense end."* A cell under the DENSE floor gets a different message —
  nothing prints at all. `runnableAsCertified` is unchanged: a sub-floor cell was
  never a run gate and still is not.

### Measured envelope, after

```
cell control @0.45 mm: light floor = 4.931378 mm
                       densest floor = 1.173173 mm
                       range = 1.173173 … 20.0 mm
                       typed(1.2) = 1.2      typed(1.25) = 1.25
                       dragged(8.3) = 8.5    dragged(8.1) = 8.0
                       typed(0.9) = 1.173173   (still clamped — to core's number)
```

Both floors move with your own line width (0.4 → 4.383 / 1.043; 0.6 → 6.575 / 1.564).

### `min_extrudable_width_mm` — where the app gets it

It is **`PrintParams.wallLineWidthOuterMM`**, your OUTER wall line width, taken
straight from print settings and passed into `LatticeSettings.runSpec(lineWidthMM:)`
at every call site. It is the single input every derivation in PR 298's messages is
computed from.

* Default: **0.42 mm** (`PrintParams.fdmDefault` — the Bambu/Orca 0.4-nozzle system
  profile; the INNER wall defaults to 0.45 mm).
* Settable range: **0.1 – 2.0 mm**, in 0.02 mm steps.
* **Your 0.45 mm is reachable and is the value that flows through** —
  `testTheExtrusionWidthTheGradingLawReadsIsTheUsersOuterWallWidth` sets it, drives
  the real serializer, and asserts `grading.min_extrudable_width_mm == 0.45`.

One thing worth knowing: the app arms core's grading floor with the **outer** wall
width while the knockdown work is calibrated against the **inner** one. That is
pre-existing, unchanged here, and not something this task measured — flagged, not
fixed.

---

## 5. S4 — THE PER-REGION RECEIPT REACHES THE SCREEN

Sending `report_region_cells` is half of it. The other half was a fetch and a read.

### Where the receipt lives, and the second defect found on the way

Core writes the per-region block into the **per-variant graded lattice receipt**
(`variant_XXX_lattice.report.json`, `lattice_cert_report_json`), not into
`run_info.json` — so it needs its own fetch. `RemoteRun` now makes it, **only when
the job asked for the report**, so no run that did not ask pays an extra round trip.

★ **On the re-lattice path the receipt was already being fetched and thrown away.**
`RelatticeRun.run` has always returned `RelatticeResult.receiptJSON`, and
`WorkspacePlaceholder.swift:2053` read `.outcome` and dropped the rest on the floor.
That is the path the Lattice page actually drives, so a re-lattice showed **no
lattice record at all**. Root cause with file and line; fixed.

The bytes ride `LatticeReport.regionCellsJSON` (raw, because the reader lives above
`TopOptKit`), and **the OutcomeStore DTO mirrors it** — a reopened run that forgot
which of its regions got nothing would silently lose the one number this task exists
to surface, which is the exact class of drop that store has shipped before. Round
trip asserted.

### What it says

`LatticeRegionCellReceipt` reads core's rows and renders them with **empty regions
first**, because declaration order is not the order someone scanning for what went
wrong needs.

★ **THE OUTPUT BELOW IS A CONSTRUCTED GRADED FIXTURE, NOT YOUR RUN.** Seven include
regions, 4 mm members, a 0.45 mm bead — modelled on your job to exercise the
rendering. Your overnight run was uniform (§0 item 3), so this receipt would not
have fired on it. Every number in it is one core would have produced from those
inputs; none of them is a measurement of your run:

```
• Per region — 5 of 7 regions received NO lattice: Region 1, Region 2, Region 3,
  Region 4, Region 5.
• Region 1: 0 of 1,257 voxels latticed · 1,257 left solid · members 4.00–4.00 mm.
  No cell size can CERTIFY this member: nothing is both printable at your nozzle
  and coarse enough for the homogenized model to describe it. It CAN still be
  built: at core's finest printable cell (1.17 mm) this member spans 3.4 cells,
  above the 1 cell the struts need to connect. That lattice would print and its
  certificate would be out of regime — which is what the "keep the lattice where
  the part is too thin to certify it" switch is for. To CERTIFY it the member
  would need 5.47 mm. A nozzle of 0.31 mm or finer would also do it. Retention was
  on and this region did NOT qualify: its peak stress measures 44.0% of the part's
  peak, above the 20% ceiling, so its 1,257 below-floor voxels stayed solid.
  Raising the ceiling above 44.0% would keep them.
  … (Regions 2–5 identical)
• Region 6: 1,257 of 1,257 voxels latticed · 0 left solid · members 4.00–4.00 mm.
  Latticed, and the certificate does NOT cover it: this is the sub-floor material
  you asked to keep. 1,257 voxels here were kept below the floor. Across the whole
  run, 2.89% of the printed part is sub-floor lattice. Cell size never enters the
  certification maths, so the margin reads the same whether that lattice is fine
  or badly wrong.
• Region 7: 900 of 1,257 voxels latticed · 357 left solid · members 4.00–4.00 mm.
  The lattice here is inside the certified regime.
• Counted in VOXELS, not emitted cells, and only on a graded (Auto density) run —
  that is what core measures per region today. A uniform lattice run still has no
  per-region breakdown.
```

Every number there is core's. All five of core's verdicts are covered
(`certified`, `out_of_regime`, `solid_load`, `no_pair`, `no_candidates`), and a
`null` member width — core's honest encoding of "thicker than the distance
transform's cap" — stays unmeasured rather than flattening to 0, which a reader
would take for a vanishingly thin member.

Note that regions 1–5 and region 6 have the SAME 4.00 mm members and are given the
same geometric fact; what separates them is named as the stress measurement it
actually is. The first version of these messages did not do that — see §6.

★ **The breakdown also shows on the run that needed it most.** `latticeNotes` takes
an early return on the "NO LATTICE WAS PRODUCED" path. Appending the region lines at
the bottom only would have hidden them on exactly the run you would be reading them
for. They are appended at **both** exits, with a test.

---

## 6. REVIEW P2 — THE REASON GIVEN MUST BE THE REASON THE CODE ACTED ON

**Status: root cause found, three of five messages were wrong, all five rewritten.**

### The contradiction, in one receipt

From the same fixture, same run:

```
Region 1: 0 of 1,257 voxels latticed · members 4.00–4.00 mm
          "No cell size works here…  The member would need 5.47 mm."
Region 6: 1,257 of 1,257 voxels latticed · members 4.00–4.00 mm
          "Latticed, and the certificate does NOT cover it…"
```

Identical members. One told nothing could be latticed there; the other latticed in
full — which is the entire point of the switch this PR ships.

### Root cause, with file and line — and it is NOT cell size

`no_pair` is set at `core/src/cli/run_job.cpp:2323`:

```cpp
if (rc.latticed_voxels == 0 && !rc.at_thinnest.feasible) rc.verdict = "no_pair";
```

`at_thinnest.feasible` comes from `lattice_derive_cell_for_member`
(`core/src/fea/lattice.cpp:479`) and is `max_homogenizable_cell_mm >=
min_printable_cell_mm` — **a pure function of (member width, nozzle)**. Two regions
with the same member and the same bead therefore get the SAME feasibility. It cannot
be what separated them.

What separated them is `latticed_voxels`, i.e. the posture mask, and for a
below-the-floor voxel that is decided by the retention predicate at
`core/src/simp/grading.cpp:367` and `:502`:

```cpp
if (retain_subfloor && region_qualified(e) && !out.subfloor_over_budget) { …keep… }
```

with `qualified` set at `core/src/simp/grading.cpp:205`:

```cpp
r.qualified = part_demand_max > 0.0 && r.stress_fraction <= subfloor_frac_max;
```

**A STRESS MEASUREMENT, NEVER A THICKNESS ONE.** The message named the wrong
quantity entirely.

### And `feasible == false` does not mean un-latticeable

Core carries TWO floors and its own header says so in as many words
(`core/include/topopt/lattice.hpp:125-130`):

> …this one (1) protects the OBJECT. Below it there is no connected strut network to
> print, and what comes out of the generator is debris. A member between them is
> BUILDABLE AND UNCERTIFIABLE. …a pipeline that refuses both with one message is
> collapsing two verdicts that need different answers.

`feasible` is the ACCURACY test (5 cells). `feasible_percolation` is the BUILDABLE
test (1 cell). At a 0.45 mm bead a 4 mm member spans **3.4 cells** at core's finest
printable cell — comfortably buildable, well short of certifiable. The app was
refusing both with one message, which is precisely what core's header forbids.

### What changed

* **The percolation floor is now READ FROM CORE** through the bridge
  (`lattice_percolation_cells_per_member_min` → `LatticeCellBounds
  .percolationCellsPerMemberFloor`). Nothing about the split is authored app-side,
  and with no floor to read the buildable sentence is OMITTED rather than guessed
  in either direction (`testWithoutCoresPercolationFloorTheBuildableClaimIsNotMade`).
* **The app now reads BOTH per-region blocks from the same receipt and joins them by
  `region_id`.** `grading.subfloor_retention.regions[]` — which core has emitted
  since PR 295 whenever retention is armed — carries the measured stress fraction,
  whether that region qualified, how many voxels were below the floor and how many
  were kept. Without it a row can say what the GEOMETRY allows but never what the
  RUN decided.
* **`no_pair` now says the three things separately**: no cell CERTIFIES this member;
  whether it can still be BUILT, with the span in cells at core's finest printable
  cell; and what the run actually decided, with the number to act on — *"its peak
  stress measures 44.0% of the part's peak, above the 20% ceiling… Raising the
  ceiling above 44.0% would keep them."*

### P2(d) — every per-region string audited on the same standard

| verdict | code condition | was it the reason the code acted on? |
|---|---|---|
| `no_candidates` | `candidate_voxels == 0` (`run_job.cpp:2298`) | **NO.** Said "the optimizer left nothing there" — one of three possible causes asserted as fact. An exclude region covering it, or the region falling outside the solved area, produce the same zero. Now names the measurement and lists the three. |
| `no_pair` | `latticed == 0 && !feasible` (`:2323`) | **NO.** Above. |
| `solid_load` | `latticed == 0`, pair feasible (`:2331`) | **NO.** Said "Kept solid because it is carrying load". Core's own comment at that line calls it an inference — *"On this path that is the load-carrying fallback"* — not a measurement. Now states the measurement (geometry admits a certified cell, so thickness is not the reason; peak stress measures X%) and the inference apart. |
| `out_of_regime` | `latticed > 0 && retained > 0 && stress <= ceiling` (`:2334`) | **NO — a mis-attribution.** `exposure_fraction` is `gf.subfloor_retained_fraction_of_part`, the WHOLE RUN's retained share, written onto every out-of-regime row. The copy read as if 2.89% were this region's own share of the part. Now says "Across the whole run, 2.89% of the printed part", and reports this region's own retained count separately. |
| `certified` | else (`:2338`) | **Nearly.** "Latticed, and the certificate covers it" over-reads a row that can still hold solid voxels. Now "The lattice here is inside the certified regime", with the counts line beside it saying how much. |

Three of five said something the code did not act on. All five now name the measured
quantity, and six tests pin them — including
`testTwoRegionsWithIdenticalMembersGetNonContradictoryReasons`, which asserts the
un-latticed row does NOT claim a geometric impossibility that the row beside it
disproves.

### The fixture was part of the cause

The R4 fixture gave all seven regions the same `stress_fraction` (0.04) and still had
five of them un-latticed and one latticed — **a state no run can reach**, since with
identical geometry and identical stress the predicate cannot diverge. It is now
internally coherent: regions 1–5 measure 44% (above the ceiling, did not qualify),
region 6 measures 4% (qualified, kept). A fixture that cannot occur will happily
produce copy that cannot be true.

---

## 7. BARS

**R1 — DEFAULT PATH BYTE-IDENTICAL. PASS, three ways.**
A project decoded from a snapshot written before these controls existed and a
project through the new code with the controls untouched produce the **identical
job document, byte for byte** (`options: [.sortedKeys]`, compared as data), on both
the optimize and re-lattice serializers — with a positive control asserting both
sides really are graded lattice jobs, so it is not two empty documents agreeing. The
serialized text contains none of the four key names at all, not merely `false`. A
NON-lattice job mentions neither `grading` nor `subfloor`.

**R2 — FAILING TEST FIRST. PASS.** §2, output pasted, `s1_failing_before.txt`.

**R3 — ROOT CAUSE WITH FILE AND LINE.** Six, all above: the six-key grading
dictionary in both serializers (§1); the light-floor bound and the 0.5 mm
quantisation in `LatticePage.swift` (§4); the app's octet strut law being 1.4× off
core's (§4); the discarded receipt at `WorkspacePlaceholder.swift:2053` (§5); and
from the review — the `no_pair` verdict's separator being `at_thinnest.feasible`
(`run_job.cpp:2323`, a pure function of member width and nozzle) while what actually
diverged was the retention predicate at `grading.cpp:367`/`:502`, qualified at
`grading.cpp:205` (§6); plus `exposure_fraction` being the run's share written onto
every region row (§6).

**R4 — DEMONSTRABLY USABLE. PASS.**

End to end, on the core this branch builds against (merged `main`, PR 298 in):
control off ⇒ no keys in the emitted document; armed ⇒ keys present in the bytes the
worker receives, and **core's own parser accepts those bytes**; the forecast branch
that explains retention fires on the flag read back out of them; the control shows
the exposure before the run; the run's receipt is fetched, parsed and rendered into
the results screen's lattice lines, with zero-lattice regions named first.
`evidence/.../r4_core_with_all_four_keys.txt`.

```
R4 probe reliable = true
R4 core accepts: retention=true stressFraction=true perRegion=true regionCells=true
R4 core default ceiling = 0.2
```

**The two-core comparison from the first round is no longer reproducible, and that
is stated rather than left as a stale file.** It was run before PR 298 merged, on a
core that lacked two of the keys, and showed the gate withholding exactly those two.
Since the review, the per-region messages read core's percolation floor, which
arrives with PR 298 — so the package no longer compiles against a pre-298 core and
that capture cannot be regenerated. The gate's withholding behaviour is instead
pinned by tests that INJECT the capability (`testAKeyTheCoreDoesNotAcceptIsNever
Emitted`, `testAPartiallyCapableCoreGetsExactlyWhatItAccepts`), which do not depend
on which core is vendored, plus `testACoreThatDoesNotKnowAKeyRefusesTheWholeJob`,
which measures against the real parser that one unknown grading key kills the job.

Full suite on merged `main`: **1,312 tests, 19 skipped, 0 failures**
(`evidence/.../full_suite_after.txt`).

**R5 — NOTHING WEAKENED OR DELETED. PASS, re-run after the rebase and the P2
rewrite, with every line accounted for.**

```
$ git diff $(git merge-base HEAD origin/main) HEAD -- app/TopOptKit/Tests \
    | grep -E '^-\s*func test'
(no output)

$ git diff $(git merge-base HEAD origin/main) HEAD -- app/ \
    | grep -E '^-\s*(XCTAssert|XCTUnwrap|XCTSkip|#expect|func test)'
(no output)
```

**A rename reads as a deletion, so the diff against the FIRST ROUND was also swept,
and it is not empty — three removals show up:**

```
-    func testPaintedRegionsTintByTheirOwnStrengthAndFrozenStillWins()
-    func testTheTintDarkensWithEachStroke()
-    func testThePortraitPanelClearsTheTwoRowActionCluster()
```

**All three belong to PR 300 (`smoothing-page-brush-panel`, commit `fc59177`), which
merged into `main` between round 1 and this rebase, and all three were RENAMED there,
not dropped** — `testPaintedAreasTintByTheirPassCountAndFrozenStillWins`,
`testTheTintStrengthensWithEachStroke`, `testThePortraitPanelClearsTheActionCluster`
are in the same file. None is present at this branch's merge-base, so none was mine
to delete. Verified with `git log -S` per name.

**My own renames in this round:** `ZZReachabilityEvidence` →
`LatticeRetentionEvidenceGen` (the file and its one method), before it was ever
pushed. Two assertions were STRENGTHENED in round 1 (positive controls), and the P2
rewrite ADDED six tests and tightened four existing ones — every changed assertion
now checks a stricter property than before, and two of them additionally assert the
OLD wording is absent.

**R6 — NO UNFILLED PLACEHOLDERS.** No `<<…>>`, no TBD, no "filled in with the
results". Every number here was measured on this branch.

---

## 8. WHAT I DID NOT DO

Stated plainly rather than buried.

* **★ Per-region EMITTED CELL counts on the UNIFORM path — the one that would have
  caught the maintainer's actual overnight run.** Core reports VOXELS, and only on
  the graded path. His run was uniform, so nothing this PR ships would have fired on
  it (§0 item 3). PR 298 names this as its own largest remaining gap and names the
  missing line exactly: *"region k received 0 cells; 1131 cells went elsewhere"*.
  **It is core work, not app work**, and it is the next thing worth building. The app
  says "VOXELS, not emitted cells, and only on a graded (Auto density) run" on
  screen rather than relabelling.
* **The breakdown is run-level, for the run's LAST accepted rung**, matching every
  other lattice note on that screen. A per-rung breakdown would need the results
  screen's variant selection plumbed through, which is a bigger change than this
  task's scope.
* **The outer-vs-inner line-width question** (§4) is flagged, not measured.
* **No live worker run.** Every serialization bar is exercised against core's real
  parser in-process; nothing here has been through an actual LAN job. The first real
  run is yours. The per-region rendering in §5 is a CONSTRUCTED GRADED FIXTURE, not a
  measurement of any run.
* **The percolation floor's own caveat, carried from core.** Core's header says its
  measurement conditions are rho ≈ 0.199, AXIAL, octet only, and "must not be quoted
  unconditionally". The app quotes it as a cells-per-member comparison, which is how
  core itself uses it — but a member that clears it is *connected*, not *strong*.
* **`subfloor_aggregate_cap`** — core carries a fifth retention key. It was not in
  the task's list of four and it is not exposed. It stays core-side, at core's
  default.

---

## 9. IN PLAIN LANGUAGE

**What was wrong.** Your iPad could set up a lattice but could not tell the solver
"keep the lattice even where the wall is too thin to certify". The solver has been
able to do that since PR 295; the app just never sent the instruction. Worse, the
app already had the text explaining that trade-off written and ready to show you —
and it could never appear, because it only appears when the solver confirms you
asked, and you could never ask.

Separately, when the solver refused a run and told you "set the cell size to about
1.2 mm", the cell-size control on the page could not go below about 4.9 mm, and
typing was rounded to the nearest half-millimetre. The advice named a number you
physically could not enter.

And when a run finished, nothing told you which of your regions actually got a
lattice. That is what cost you a night: your run put 1,131 lattice cells somewhere,
and no file said where.

**What I changed.** All of it is in the app; the solver is untouched.

* A switch on the Lattice page, off by default: *keep the lattice where the part is
  too thin to certify it*. Turning it on sends the instruction, and the page tells
  you — before you spend the run — roughly how much material would end up
  uncertified. On the example numbers that reads "up to 822 voxels, 65.4% of what
  this lattice covers".
* A second switch: *report what each region got*. With it on, the results screen
  lists every region — how much was latticed, how much stayed solid, and why — and
  puts the regions that got **nothing** at the top, by name.

  **★ Which kind of run this works on, and which kind yours was.** It works on a
  GRADED run — the one where Density mode is Auto and the solver grades the lattice
  from the part's own stress field. **Your overnight run was UNIFORM**: one density
  everywhere, one cell size, no grading. The solver only counts things per region on
  the graded path, so this receipt would not have appeared on your run at all. To
  catch a run like yours the solver would have to count EMITTED CELLS per region on
  the uniform path, and it cannot do that yet — that is solver work, and it is the
  next thing I would build.
* The cell-size control now goes down to 1.17 mm at your line width (the solver's own
  number, read from the solver, not guessed by the app) and accepts two decimal
  places when typed. Dragging the slider feels the same as before.
* Two smaller things found along the way and fixed: a re-lattice was fetching its
  own report from the worker and throwing it away, and the two places in the app
  that build a lattice job were writing the same block of settings out twice, which
  is how one of them ends up quietly missing a setting. There is one now.
* **After review, the per-region explanations were rewritten.** Three of the five
  sentences the screen could show said something the code had not actually done. The
  worst told you "no cell size works here" about a 4 mm wall — while the line
  directly beneath it showed another 4 mm wall latticed in full. The real difference
  was never thickness: it was how much load the solver measured in each region. Each
  sentence now names the number the solver actually used, and separates two things
  that had been collapsed into one — *this cannot be CERTIFIED* (true of your 4 mm
  wall) and *this cannot be BUILT* (not true of it: at a 1.17 mm cell it spans 3.4
  cells, and it prints).

**What it costs you.** Nothing, unless you turn a switch on. With everything left
alone the app sends the worker exactly the same job it always did — checked by
comparing the actual documents, not by reading the code.

**The one caveat.** Turning retention on buys you the lattice, not a guarantee about
it. The certificate cannot see how coarse a lattice is — only how dense — so the
margin will read the same whether that thin lattice is fine or badly wrong. The app
says this in three places now: on the control, in the pre-flight, and on the
results. It is an accepted unknown, not a clean bill of health.

**Next steps, in the order I would take them.**

1. **Rebuild the app and run one job with both switches on**, on the part with the
   seven regions. Everything here is proven against the solver's own document
   parser, but nothing has been through a real worker run yet.
2. **PR 298 has merged, and this branch now sits on top of it.** All four settings
   are live. It is no longer optional: the app will not build against a solver older
   than PR 298, because the per-region explanations read a number that arrives with
   it. Build core, then the app, in that order.
3. **Then take the cell-size advice literally.** With the control's floor fixed you
   can now type the 1.2 mm the refusal names and see whether a connected lattice
   actually comes out of your 4 mm wall. That is the experiment the old bound was
   preventing.
4. If the breakdown proves useful, the next thing worth building is **emitted-cell
   counts per region on the uniform path** — that is the number that names where
   your 1,131 cells actually went, and it lives in the solver, not the app.
