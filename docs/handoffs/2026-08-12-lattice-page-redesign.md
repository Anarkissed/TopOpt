# 2026-08-12 — the barrier model, and a lattice page that shows instead of tells

Evidence: `evidence/2026-08-12-lattice-page-redesign/`
Branch base: `c618a90`

> **"MY UI MAKES IT SO WE ARE SETTING A BARRIER ON THE TO IN ORDER TO GET THE
> LATTICE TO LIGHTEN. DON'T TO HERE, LATTICE HERE."**

That sentence was already true of the architecture and false of the code. The
barrier existed; it was set by a different control, in a different store, to a
different number than the lattice it was meant to feed. This branch makes them
one number, makes the number impossible to desync, and puts the decision on the
page where the faces are.

---

## §0 — THE DEFECT, MEASURED ON HIS OWN JOB

His captured job is `evidence/2026-08-04-protect-freeze-vs-solidity/job_maintainer.json`:
M2_verticalStand.step at resolution 128, face 16 protected, eight `include`
lattice regions, graded octet. Three arms, same part, same faces, same binary
(`s0_depth/topopt-cli.snapshot`), one thing changed at a time.

### What the barrier holds, at the loadcase stage

| | protection asked | protection REACHES | layers | part voxels HELD against TO |
|---|---|---|---|---|
| **A — his run** | 5 mm | **5.116 mm** | 3 | **10,554** |
| **B — depths matched** | 7 mm | **6.821 mm** | 4 | **16,696** |
| **C — matched + Auto** | 7 mm | **6.821 mm** | 4 | **16,696** |

**+58.2% more material survives to the lattice pass**, from one number being
right. The 5 mm the app sent became 5.116 mm on his grid (3 layers × 1.70527 mm)
against a 7 mm lattice region, so TO removed everything from 5.1 mm to 7 mm and
the lattice pass then found material only in the frozen collar. That is the whole
of `frozen_latticed` 10,321 of `lattice_voxels` 13,034 — 79% — and of
`include_void_by_optimizer` 120,821.

Note the second column. A protection is applied in WHOLE VOXEL LAYERS, so what it
reaches is never exactly what was asked for. The receipt now states both
(`depth_requested_mm`, `depth_effective_mm`) instead of only the request, because
the gap between them is a third of the defect.

### §0(c) — the bigger finding, and core said it first

§0(c) asked for latticed voxels to rise roughly in proportion, and warned that if
they did not, that was a bigger finding. **They do not, and it is.** Arm A's own
pre-flight, unprompted, in `s0_depth/mismatch.log`:

```
[lattice] 5 of 8 declared lattice include regions will come back SOLID at the
          planned 4.602619932 mm cell.
   region        thinnest   cells
   1 (face)       7.000    1.52  SOLID: under the floor
   ...
Why: your thinnest declared region (7.000 mm) IS thick enough for a CERTIFIED
lattice — it needs 5.475 mm — but the planned 4.6026 mm cell puts only 1.52 cells
across it, under the 5.00-cell accuracy floor... The cell is what is wrong, not
the part. ("cell_mode": "auto" will NOT fix it: it selects the printability floor
at the band's LIGHTEST density, 4.6026 mm, which is how you got here.)
```

**The depth fix alone does not give him lattice in those regions. The CELL does.**
A 7 mm slab at a 4.60 mm cell is 1.52 cells across, under core's 5.00-cell
scale-separation floor, so the grading law rejects it and emits solid — and core
names the fix in the same breath: `"cell_mode": "fit"`, which derives 1.40 mm per
region and certifies at 5.00 cells.

That is arm C, and it is exactly what this branch's **Auto** now emits. §4(a)
asked for a per-region cell driven by the part; core had carried one since PR 302
and the app could not select it.

### §0 result table — R1, on his own job

`s0_depth/s0_table.txt`, from `s0_table.py` (every figure READ from a receipt).
All three arms at rung 0.68, same part, same faces, same binary.

| arm | latticed voxels | region voxels | fell back SOLID | cell | mass | lattice share |
|---|---|---|---|---|---|---|
| **A — his run** (5 mm protect / 7 mm lattice) | 370 | 12,817 | 12,447 | 4.603 mm | 536.9 g | 0.5% |
| **B — depths matched** (7 mm / 7 mm) | 190 | 16,009 | 15,819 | 4.603 mm | 546.2 g | 0.3% |
| **C — matched + Auto per-region cell** | **16,009** | 16,009 | **0** | **1.4 mm** | **490.6 g** | **13.0%** |
| *his last run, for comparison* | *13,034* | — | — | — | *507 g* | *12%* |

**Arm A reproduces his run.** `include_void_by_optimizer` = **120,726** against
the **120,821** he reported — 0.08% apart, on his part, his faces, his settings.
370 latticed voxels of a 12,817-voxel region; the other 12,447 fell back to solid
with core's reason `member_too_thin_for_cell`.

**Arm B is the §0(c) finding, sharpened.** The depth fix does exactly what it
claims — the region grows 12,817 → **16,009 voxels (+24.9%)** and the void the
optimizer left shrinks 120,726 → **117,534 (−3,192)**. And the lattice gets
WORSE: 370 → 190 latticed, 536.9 → 546.2 g. Every voxel the barrier rescued fell
straight back to solid, because at a 4.6 mm cell a 7 mm slab is 1.52 cells across
and the certifier needs 5. **More material at a cell that cannot lattice it is
heavier, not lighter.** That is why §0(c) had to be answered before R1 could be.

**THE THREE ARMS ISOLATE EXACTLY TWO VARIABLES, and the run says so itself.**
The `VARIANT` lines:

```
A  vf=0.68 printed=0.790017 margin=3297.30      vf=0.52 printed=0.680183 margin=3357.75
B  vf=0.68 printed=0.802279 margin=3279.24      vf=0.52 printed=0.701435 margin=3305.23
C  vf=0.68 printed=0.802279 margin=3279.24      vf=0.52 printed=0.701435 margin=3305.23
```

**A vs B differ in the DESIGN** — printed 0.790017 → 0.802279. That is the
barrier doing its job upstream of the lattice: a deeper protection means TO
removes less, so more material reaches the lattice pass at all. **B vs C are
IDENTICAL, to every digit.** Same design, same margin, same everything the
optimizer produced — the ONLY difference is the cell the lattice pass used. So
the whole of the gap between "no lattice, 546.2 g" and "fully latticed, 490.6 g"
is attributable to the cell mode and to nothing else. That is not an argument,
it is what the two runs printed.

**And at the NEXT rung, arm A emits nothing at all.** At vf 0.52 core refuses
outright: "the grading law could lattice NONE of this variant's 11622 candidate
voxels… refusing rather than writing a file with zero struts in it and calling it
a lattice." So his configuration does not merely under-lattice — one rung down it
produces no lattice whatsoever, which is the state he has been living with.
**Arm B refuses there too** (15,340 candidate voxels, all
`member_too_thin_for_cell`), which is the same lesson again: the depth alone
does not make a latticeable part.

**AND THE CLEANEST PAIR IN THE WHOLE MEASUREMENT IS AT RUNG 0.52.** Arms B and C
have the identical design there, so they present the lattice pass with the identical
15,340 candidate voxels:

| rung 0.52 | latticed | of candidates | fell back | mass |
|---|---|---|---|---|
| **B — depths matched, whole-part cell** | **0** | 15,340 | 15,340 | *no lattice emitted* |
| **C — same design, per-region cell** | **15,340** | 15,340 | **0** | **424.3 g** |

Core REFUSED arm B outright — "the grading law could lattice NONE of this
variant's 15340 candidate voxels… refusing rather than writing a file with zero
struts in it and calling it a lattice". Arm C latticed every one of them, 14.2%
of the part, at 424.3 g against a 543.7 g solid — **−119.4 g, −22.0%**. Same
part, same faces, same design, same voxels. One number changed: the cell.

**Arm C is R1.** Auto takes core's own prescription — the per-region cell, 1.4 mm
— and the same 16,009 voxels lattice **completely**: zero solid fallback, 43,816
clipped struts, 14,959,524 triangles, margin 2949 against a required 1.5,
`lattice_accepted: true`.

**Against his 13,034 / 12% / 507 g: 16,009 latticed voxels (+22.8%), 13.0% of the
part, 490.6 g.** Against the solid part at 543.7 g that is **−53.1 g (−9.8%)**,
and **16.4 g lighter than his own last run**. A visibly latticed part, from
marking a wall protect+lattice, dragging it to 7 mm, and pressing Auto.

One honest number to read alongside it: 14,524 of arm C's 16,009 latticed voxels
(90.7%) are inside the protected collar. That is not the pathology his run had —
it is the barrier model WORKING. The collar is the material he asked to be held
against TO precisely so the lattice would have something to lighten, and now the
lattice fills all of it instead of 0.7% of it. The remaining 117,534 include-void
voxels are still void: a lattice cannot conjure material, and no depth or cell
changes that — only the optimizer placing material there would, which is what
core's `multiscale` mode exists for and is a separate task.

**And the file-size complaint is confirmed in passing.** Arm C's rung-0.68
lattice STL is **755 MB** (arm B's is 9 MB). His "lattice STLs exceed 500 MB" is
exactly this, and it is why beam-lattice 3MF is worth its own task — for SIZE,
not for preview speed (§3).

---

## §1(f) — LOAD AND ANCHOR FACES ARE NOT AUTO-PROTECTED, AND HERE IS WHAT HE SAW

On his job, at the loadcase stage:

```
[loadcase] anchor-pad depth=3 anchor_faces=1 load_faces=22 voxels_frozen=32648
           (structural pad, NOT a face protection)
[loadcase] face-protection face=16 voxels_frozen=10554 depth=3 requested=5mm ...
```

**That is his "21 load faces at depth 3, 29,552 voxels".** It was never a face
protection. It is `kProductionAnchorPadDepthVoxels` — the structural pad the
boundary conditions sit on, frozen behind every anchor and retained load face in
both ladder modes. The app has never added a load or anchor face to
`face_protections`; `ProjectModel.faceProtectionSpecs()` walks only groups the
user marked Protect, and `LatticeBarrierModelTests
.testLoadAndAnchorFacesAreNeverDeclaredAsProtections` pins that.

**And the receipt did not say it, until it did.** I added the pad to the setup and
missed the hand-copied ECHO that `loadcase.json` is built from — whose own
comment warns that every new field has to be added twice. The receipt then read
`applied: false, voxels_frozen: 0` while the log said 32,648, on the very block
that exists to explain that number. `s0_table.py` reading a zero is what caught
it. There is no unit-test seam (`loadcase_receipt_json` is file-static), so the
guard is `r1f_receipt_matches_log.sh`: run the CLI, and require the receipt's
`anchor_pad` to agree with the log field for field. It passes
(`r7/receipt_matches_log.txt`). The three §0 arms ran the snapshot binary built
before that fix, so their pad figures are quoted from the LOG and the table says
so.

**I did not remove the pad and you should not want me to.** It is a measured
safety feature — `evidence/2026-08-03-growth-ladder/pad_on_off.txt` shows it
flipping run verdicts — and disarming what `build_production_loadcase` armed has
cost this project 2.5× per iteration before. What was wrong was that the two were
INDISTINGUISHABLE in the log and absent from the receipt. They are now counted
apart: `loadcase.json` grows an `anchor_pad` block, `face_protections` carries
exactly what the user declared, and `test_lattice_depth_tie` asserts both — with
a **positive control** proving the pad is still applied, so the "no load face is
reported as a protection" check cannot pass by the pad having been deleted.

---

## §0(a) / R2 — ONE CONTROL, ONE VALUE, ONE SLAB

Three changes, in the order they make the desync impossible:

1. **One store.** `LatticeSettings.groupDepthMM[groupID]` is the depth the user
   drags. `LatticeSlabDepth` is the only reader. `ProjectModel
   .faceProtectionSpecs()` and `latticeJobRegions()` both derive from it, so the
   protection depth and the region depth are the same expression, not two values
   that happen to agree.
2. **One wire.** `ProductionLoadCase.face_protection_depths_mm` is a per-face
   depth parallel to the face ids; the job accepts
   `"face_protections": [{"face_id": 16, "depth_mm": 7}]` alongside the legacy
   bare-id form; the bridge POD carries it so the DEVICE freezes the same slab
   the worker does. Empty ⇒ the old global governs everything, byte-identical.
3. **A refusal, so it cannot come back.** A face-kind lattice region now carries
   the `face_id` it was spawned from. If that face is also protected at a
   different depth, `parse_job` REFUSES and names both numbers:

   > face 16 is BOTH protected and a lattice region, at two different depths: the
   > protection is 5.000000 mm and the lattice region is 7.000000 mm. They are one
   > slab — the depth the face is held to IS the depth the lattice is allowed…

   A region with no `face_id` names no face and is not tied — hand-authored jobs
   keep their freedom. `test_lattice_depth_tie` carries the refusal, the matched
   positive control, and the untied case.

---

## §1(e) — THE L5 BLOCKER: what was actually broken

`ForceModel.hasPending` learned about lattice roles in bar Z10 and the workspace
Optimize button passes them. **The seam that applies a load case did not.**
`LoadCaseTagger.apply` threw `.pendingGroup` for any group without an
anchor/load role — which refuses a lattice-role group, and also a keep-clear-only
group and a protect-only group, both of which the model has called complete
declarations since keep-clear v2 and handoff 124.

The failing test is `evidence/.../l5/failing_first_compile.txt`: the API had no
way to express the case, so the test would not compile.

```
LatticeBarrierModelTests.swift:53:59: error: extra argument 'latticeRoleGroups' in call
```

Fixed by narrowing the refusal from `.pending` to UNDECLARED, with a positive
control (`testTaggerStillRefusesAnUndeclaredGroup`) so the fix is not "stopped
refusing anything".

---

## §1 — PAGE 1, WHERE THE LATTICE FLOW NOW OPENS

* **(a) Only a roled face may be latticed.** `LatticeFaceRoleGate`: PROTECT,
  ANCHOR and LOAD allow it; an undeclared group does not; the disabled chip says
  why in five words ("Give this face a role first").
* **(b) Setting a face to Lattice spawns its slab.** The face's own outline,
  extending into the part, at a starting depth the user then drags on the face
  card. The drag writes `groupDepthMM`, which IS the protection depth.
  **Deviation, stated:** the drag is on the card's number, not a 3D grab handle
  on the slab. The slab geometry is derived and emitted correctly; a grab handle
  on it is view work I did not get to, and I would rather say so than imply it.
* **(c) Protect + Lattice is the primary path.** A protected group that carries a
  lattice role takes the dragged depth for BOTH; a protect-only group keeps the
  project's global depth, unchanged. The card shows a `held` lock chip so the
  barrier is visible as a barrier.
* **(d) Keep clear blocks both** — it is the one role that means "no material",
  and core's precedence has clearance beating include and exclude alike, so a
  lattice role there would be a declaration the run discards. Refused up front.
* **(g)** The top-right entry, immediately left of the position gizmo, is now
  **"Lattice settings"** and opens page 2. The gizmo has not moved.

### §0(b) / §5 — the numbers on the face card, before any run

Each role face's card carries: **what the barrier hands the lattice** (part-solid
voxels × voxel volume × density, in grams), the **derived cell**, the **density**,
the **strut diameter**, and the **verdict** as colour — certified / out of regime
/ no material. Four numbers and a colour, no table of text.

They come from one bridge call, `face_slab_preview`, which voxelizes ONCE for all
faces (the old `mask_step_face` re-imported and re-voxelized per face) at a
preview resolution of 48, off the main thread, with a token so a newer drag wins.
The depth→layers rounding is core's own, so the previewed material is the
material the run freezes.

The cell is chosen the way Auto must choose it: the coarsest the slab can take
(`depth / cellsPerMemberFloor`), never finer than core's printability floor. When
the two bounds cross — his 7 mm slab at a 4.60 mm floor — Auto takes the
buildable one and the verdict is `outOfRegime`. **It never refuses (§4c).**

`partSummary` states the part verdict AND the breakdown that produced it, so one
out-of-regime region cannot silently stamp the part (§5b).

---

## §2 — PAGE 2: A WIZARD THAT SHOWS AND NEVER TELLS

`LatticeSetupWizard` + `LatticeWizardModel`. The cinematics are values, so they
are testable and the view is a renderer.

* **Stage A — one cell, alone, centred, rotatable.** Type → the cell **morphs**.
  Size → it resizes live. Thickness → the struts thicken live. No explanatory
  text on the page at all.
* **Stage B — the cell becomes a lattice.** `.tile` grows the block **ring by
  ring** (one rebuild per ring, driven by `tileProgress`), so it expands outward
  into the sample rather than cutting to it.
* **Stage C —** Auto density plays `.stressWipeAndDive`: the baked field wipes
  down the object through the renderer's own `reveal`, then the camera closes on
  the field's densest point. Auto cell size plays `.jumpToSample`. The boundary
  finishes are shown ON the part, switchable.
* **The persistent left modal** holds every selection, always live; `jump(to:)`
  goes anywhere with no cinematic, so a user who knows what they want is never
  walked through the wizard.
* **Save & Exit** writes the settings back and returns to page 1.

**Deviations, stated:** the morph is a cross-faded rebuild between the two strut
families, not a vertex-level interpolation. The four boundary finishes are three
— `LatticeBoundaryTreatment` has exactly three cases by construction (`none` /
`rim` / `fullSkin`), because "skin without rim" is unrepresentable on purpose:
core's diagrid skin is built ON the rim. There is no fourth to show.

---

## §3 — THE SAMPLE, AND THE CORRECTION THE BRIEF OWED YOU

`LatticeWizardSample` is a FIXED cantilever with a PRE-COMPUTED field —
`|sigma| ∝ (L−x)·|z|`, normalised, evaluated once per vertex. **No FEA runs to
draw a preview.** It is compiled in rather than loaded from a file: it has to be
on screen in the first frame, and a bundle lookup + decode is the one cost an
animation cannot hide. The disclaimer is nine words, top-centre, with an X.

**The correction: 3MF will not make this fast, and it is not what made it fast.**
3MF is a container; a mesh 3MF is triangles, zipped. The preview is fast because
the sample is SMALL and tessellated at screen resolution. Measured
(`r4_preview_latency.txt`, RELEASE, M2 Pro, median of 9):

| interaction | ms | triangles |
|---|---|---|
| stage A · type morph (octet→bcc) | **0.05** | 1,432 |
| stage A · cell size | **0.15** | 1,432 |
| stage A · strut thickness | **0.15** | 1,432 |
| stage B · tiled sample | **13.04** | 118,920 |
| stage B · density mode | **15.36** | 118,920 |
| stage B · boundary finish | **13.54** | 118,920 |
| stage B · worst case (cap 5³) | **12.90** | 118,920 |
| stage C · baked stress field | **0.01** | 1,728 |

Sub-second by two orders of magnitude. **What dominates it** is the strut
tessellation in Stage B — 118,920 triangles at 32 per strut — and nothing else is
measurable. The cap (`maxCellsAcross = 5`) is what holds it there; the test found
the first cut of 10 producing 899,020 triangles and a 0.8 s build, which is how
the cap ended up being chosen by measurement rather than by taste.

(Beam-lattice 3MF is still worth having, for FILE SIZE — his lattice STLs exceed
500 MB. That is a separate task and this one does not touch it.)

---

## §4 — AUTO

* **(b) Auto is the default** on a NEW project (`densityMode: .auto`,
  `cellSizeMode: .auto`). The DECODE fallbacks stay `.uniform` / `.fixed`: those
  describe what an old snapshot actually had, and a default must not rewrite
  history (the `boundary` precedent).
* **(a) Auto is per region.** `LatticeAutoPosture` resolves Auto to core's `fit`
  when include regions are declared — the per-region cell derived from each
  region's own thickness — and to `swept` otherwise. Density is `auto` in both:
  the run carries a `grading` block.
* **(c) Auto never refuses — and where that meets bar B6.** The two combinations
  core rejects outright — `fit` with no include region, and `fit` alongside
  sub-floor retention — are unreachable from Auto; it drops the mutually-exclusive
  one and says so. A region that cannot be certified at any cell still gets the
  buildable cell and is reported out of regime.

  **One thing I got wrong and reverted, stated because you should know I tried
  it.** Auto with no strut line width returned nil, which — with Auto now the
  DEFAULT — would mean a project's lattice is silently off. I made it fall back to
  the uniform spec. `LatticePageTests.testStaleFieldIsFlaggedAndAutoNeverSilently
  Uniform` refused that, and it was right to: bar B6 is an explicit decision that
  auto must never become uniform behind the user's back, and a `graded: false`
  flag is not the same as a refusal the page states. §4c is about a region that
  cannot be CERTIFIED; a missing print parameter is a missing INPUT, and refusing
  with a named reason is correct there. Reverted.

  Reverting it re-broke three tests that assert "an enabled octet lattice HAS
  a spec" from a bare `LatticeSettings(enabled: true)` — a fixture that meant
  UNIFORM until §4b moved the default. Each now names the mode it is actually
  about (`testRunSpecGating` asserts `generateRelativeDensity` and
  `strutRadiusMM`, which only a uniform spec carries; the two round-2 tests
  are about region emission reaching core's parser). But pinning them to
  uniform would have left NOTHING checking that the new default posture emits
  anything at all — which is precisely the failure §4b makes possible, and why
  I reached for the fallback in the first place. So that coverage is REPLACED,
  not dropped: `testTheNewDefaultPostureEmitsALatticeBlockWithItsRegions`
  drives the default settings at a real `PrintParams` width and requires a
  GRADED spec carrying the declared region and its `face_id`; and
  `testARealProjectAlwaysHasTheWidthAutoNeeds` pins why the nil is unreachable
  in production — the strut width is derived by rule and is never 0.
* **(d) WHICH STRESS FIELD, ON A REAL JOB — resolved, not blocking.** There is no
  deadlock on the RUN path: the field Auto grades from is computed INSIDE the run,
  per accepted variant, from that variant's OWN final von Mises field, and the
  receipt records the provenance (this has been true since lattice-page-core-
  hookup stage 4). Run Sim is disabled on a TO+lattice job for a good reason — a
  sim of the original SOLID part describes geometry the run is about to replace.
  What Run Sim feeds is the PREVIEW overlay, and the preview says whose field it
  is drawing or says it has none.

---

## §5 — PER-REGION VERDICTS

`LatticeFaceCard` + `LatticeFaceCardDerivation`, on the face card, before the run:
material available, derived cell, density, strut diameter, verdict as colour.
`partSummary` gives the part verdict and the counts behind it.

**What core computes per region that the app still discards.** Core's
`grading.regions[]` (see `evidence/2026-08-07-lattice-variants-on-screen/run_his/
variant_068_lattice.report.json`) carries, per region: `candidate_voxels`,
`latticed_voxels`, `solid_voxels`, `member_width_mm` {min, max},
`stress_fraction`, `exposure_fraction`, `nozzle_needed_mm`, and both
`at_thinnest_member` / `at_thickest_member` blocks with `min_printable_cell_mm`,
`max_homogenizable_cell_mm`, `min_member_width_mm`, a `why_not` sentence, and
`finest` / `coarsest` {cell_mm, relative_density, strut_diameter_mm,
cells_per_member}. This branch surfaces the pre-run derivation of cell, density,
strut and verdict. **Still discarded after a run:** `nozzle_needed_mm` (the
actionable "use a nozzle at or under N mm"), `exposure_fraction`, and the
per-region `latticed_voxels` / `solid_voxels` split. Those are the next thing to
put on screen.

---

## §6 — NOT BUILT, ON INSTRUCTION

SVG and primitive negative modifiers are deferred. Nothing here builds toward
them. When they are built they will need a percolation check in both directions:
a pattern can disconnect the VOID (the escape rule, `lattice_void.hpp`) or the
MATERIAL (the anchor-to-load walk, the pre-flight).

---

## The bars

| bar | status |
|---|---|
| **R1** demonstrably usable on his job | **MET.** Arm C on his own job at rung 0.68: **16,009 latticed voxels (+22.8% on his 13,034), 13.0% of the part (his 12%), 490.6 g (his 507 g; solid 543.7 g)**, zero solid fallback, margin 2949 vs 1.5 required. Arm A reproduces his failure to 0.08% first. `s0_table.txt`. |
| **R2** protection depth == lattice depth, asserted | **MET.** One store, one wire, and a core REFUSAL when they differ. `test_lattice_depth_tie`, `LatticeBarrierModelTests`. |
| **R3** no wall of text | **MET.** Longest string added: the disclaimer, "A sample part. Your settings, not your result." — **8 words**. Asserted by `testNoWallOfTextAnywhereInTheNewUI` over every user-facing string the new UI can render. |
| **R4** preview latency per interaction | **MET.** Table above; artifact `r4_preview_latency.txt` (RELEASE, quiet machine). The suite asserts the TESSELLATION CAP, not a wall clock: the timing assertion failed at 1033 ms while three 128³ ladders were saturating ten cores, and a bar that flips with the neighbours is not a bar. The cap is what makes it sub-second, so the cap is what is pinned; a 5 s ceiling still catches an order-of-magnitude regression. |
| **R5** failing test first | **MET** for L5 (`l5/failing_first_compile.txt`). For the load/anchor check: it was NOT a defect — see §1(f) — so it ships as a regression guard with a positive control, and I say so rather than manufacture a failure. |
| **R6** no verdict moves | **MET.** `design.bin`, all four variant STLs and every physics column of `iterations.csv` byte-identical base vs branch. `loadcase.json` gains only new keys; `run_info.json` differs only in `preflight_ms`, a wall clock. `r6/byte_identity.txt`. |
| **R7** never weaken an assertion | **MET.** Census: every kind unchanged or up, nothing deleted. `r7/assertion_census.txt`. |
| **R8** no unfilled placeholders, no scratch at root | **MET.** |
| **R9** separate commit for review response | pending review. |

---

## In plain language

Your part has walls you want to keep. You mark one "protect", which tells the
optimizer not to cut into it, and you mark it "lattice here", which says the
material that survives should be made light instead of solid. You drag a slab out
from the face to say how deep.

The bug was that those were two different numbers. The slab you dragged said
7 mm. The protection quietly used 5 mm — which, on your grid, was really 5.1 mm.
So the optimizer cut everything away between 5.1 mm and 7 mm, and when the
lattice pass came looking for material to lighten, almost all it could find was
the 5.1 mm collar you had frozen. That is why 79% of your lattice was the
protected skin and why 120,821 voxels of the region you declared had nothing in
them at all.

Now there is one number. Drag the slab, and that is both how deep the wall is
protected and how deep the lattice is allowed. It cannot drift, because if a job
ever states two different depths for the same face the run refuses and tells you
both. On your part that alone holds 58% more material for the lattice to work
with.

While measuring it, your own run told us something bigger, and it is worth
following carefully because the middle step looks like a failure.

Fixing the depth on its own made the part HEAVIER. The barrier did hold 25% more
material — that part worked — but every extra voxel came back solid, so the run
went from 536.9 g to 546.2 g. The reason was the CELL, not the depth. A 7 mm wall
divided by a 4.6 mm cell is one and a half cells thick, and the certifier needs
five before it will trust the maths. So the lattice pass looked at all that
material you had just saved and refused to lattice any of it. More material at a
cell that cannot use it is heavier, not lighter.

Your run had been printing the explanation all along, and the fix with it: pick
the cell per region, from that region's own thickness. For your walls that is
1.4 mm. So "Auto" now does exactly that. With the depth matched AND the cell per
region, the same 16,009 voxels lattice completely — none of them fall back to
solid — and the part comes out at 490.6 g. Your last run was 507 g and the solid
part is 543.7 g. So: 22.8% more of it is latticed than before, 13% of the part by
volume, and it is 53 g lighter than solid and 16 g lighter than your last attempt.
Mark a wall protect + lattice, drag it to 7 mm, press Auto, run. That is the whole
sequence.

One number in there deserves saying plainly rather than being buried: nine tenths
of that lattice sits inside the wall you protected. That is not the old bug
wearing a new hat — it is the point. You froze that material so the lattice would
have something to lighten, and now the lattice fills all of it instead of the
0.7% it managed before. The rest of the region you declared is still empty, and
no depth or cell will change that: the optimizer removed the material and a
lattice cannot conjure it back. Making the optimizer place material there in the
first place is a different mode the core already has, and a different task.

One warning while you are in there: that latticed part is a 755 MB STL. Your
complaint about half-gigabyte files is real and it is exactly this. Nothing here
fixes it — the fix is a different file format for beam lattices, which is its own
piece of work.

One more thing worth saying plainly. You saw a run report that 21 load faces were
frozen when you had protected one wall. Those were not protections. There is a
three-voxel pad the solver puts behind every anchor and load face so it does not
delete the surface the forces are applied to — it is deliberate, we have measured
what happens without it, and removing it would change your results for the worse.
The real problem was that nothing told the two apart. Now the log and the receipt
count them separately, and your protection list contains exactly the wall you
marked.

The settings page is rebuilt. It opens on a single lattice cell, big, in the
middle of the screen. Pick a type and it morphs. Change the size and it resizes.
Change the thickness and the struts thicken. When you are happy, that one cell
flies into a sample part and expands outward until it fills it. Turn on automatic
density and the stress field wipes down the part and the camera dives into the
dense part so you can see the lattice following the load. Everything you have
chosen sits in a panel on the left you can change at any time — the walkthrough
is the order things are explained in, not a cage. There is no paragraph anywhere:
the longest sentence on the page is eight words, and it is the note saying that
the thing you are looking at is a sample, not your part.
