# The quilt: found, measured, and partly fixed

Written 2026-08-26 by the agent that took over the holes-and-quilt investigation.
Every number here was measured. Where the previous handoff was wrong, it says so.

---

## 0. THE ONE-LINE ANSWER

**The quilt was the per-spot "never overshoot" rule dividing the region's cell by a
whole number, and firing on 260 NANOMETRES of half-float rounding.**

`halfRepresentable()` rounds his face-15 cell from `10.312240362167358` up to
`10.3125`. The per-spot rule then asks "does this cell fit the wall under it" — and
because the region cell IS the p50 of that wall, the two are the same number. The
ratio comes out `1.0000252`, the guard was an ABSOLUTE `1e-6` (25x too small), and
`ceil` answered 2. **The cell halved.**

Measured on his own part at the preview's own grid: **34,271 of 66,838 wall voxels
(51.3%) were divided by that rounding**, worst overshoot 25 parts per million. Only
9.5% were a genuinely thinner wall.

The result was a wall carrying S beside S/2 beside S/3 beside S/6 — and S/2 is the
one divisor stepped may never produce (his rule, 2026-08-26: *"Stepped grade means
NOT dyadic (any number but 1/2 is ok)"*). That patchwork is the fabric.

---

## 1. TWO THINGS THE PREVIOUS HANDOFF GOT WRONG — correct these first

### 1a. "Fine 128³ and Fast 64³ are pixel-identical, so it is not resolution"

True observation, wrong conclusion. **The lattice preview always bakes at 128³.**
`LatticeSDFScene`'s `maxDim` defaults to 128 and `WorkspacePlaceholder` never passes
one; the Fast·64³/Fine·128³ chip is the **job's** grid and never reaches this bake.
Flipping it changes nothing because it is inert here, not because resolution is
irrelevant. Measured: at 64³ the same code gives 6.2% of cells finer than S/2; at
128³ it gives 29.2%. Everything in this file is at 128³ because that is what he sees.

The tell that settles it: his tap callouts read 5.16 / 12.03 / 2.58 mm, which are
divisors of the **128³** region cells (10.312 / 12.031), not the 64³ ones
(10.394 / 13.000).

### 1b. "A harness that cannot fail the way the product fails is not a harness"

Right in spirit, and the reason both previous harnesses were useless. But the fix is
not a better camera — it is **pinning the harness to the app's own DIAG line**.
`LatticeQuiltBakeProbe.testTheHeadlessBakeMatchesTheApp` asserts the histogram
captured from the running app, verbatim. It has matched exactly at every step since.
If it ever stops matching, nothing the harness prints means anything.

Capture the app's line with:

```bash
xcrun simctl spawn <udid> log stream --level=debug --style compact \
  --predicate 'processImagePath CONTAINS "TopOpt.app"' | grep DIAG
```

**The log stream must be started as a real background task** — a `nohup ... &` inside
one shell call is killed when that call returns, which is why two attempts produced
an empty log.

---

## 2. HIS SPEC, AS HE STATED IT ON 2026-08-26

These superseded several earlier rulings. Quoted so the next agent does not have to
re-derive them.

| | rule |
|---|---|
| single-cell/member ON | *"make the largest single cell across the entire model — per voxel. So this will change based on the thickness of the area it's in. If the area is 13 mm, the cell is 13 mm, if the area next to it is 12 mm the cell next to it is 12 mm."* |
| single-cell/member OFF | largest cells the stress allows. *"For this model … we can always have 2 cell lattice. That is the floor for THIS model."* |
| Stepped grade | **NOT dyadic** — *"any number but 1/2 is ok"*. S/2 is never a size. |
| Default grade | dyadic; halving IS the step, and averages the cell out over the region. |
| Grade to shape | *"the grade is to SOLID. We want the shape to be exact to the face-prism. So as it gets closer, it is graded more and more, until it becomes a solid and connects the sides."* |
| The face prism | *"only makes what's solid into lattice, it cannot make walls thicker."* Overlap with a floor gets a bit of lattice. |
| Organic | not finished — ignore. |
| Core | *"The algo has not been updated with the needs I've created in this UI so for now, you can't just pass the algo onto the preview."* |

---

## 3. WHAT CHANGED, AND WHAT IT MEASURED

Two edits, both in `LatticePreviewOccupancy.steppedCellField`.

### 3a. The fit arithmetic uses the cell AS DERIVED, not the half-rounded one

`let exact = cellMM` beside the existing `sizes` array; `var s = exact[prime]`. What
is WRITTEN is still `halfRepresentable`, so the shader's S and the encoding are
untouched. Only the comparison changes, and comparing a number with itself is not
slack against the wall — §8's never-overshoot is untouched.

### 3b. The per-spot cell IS the material under it

The `S/n` whole-number quantisation is gone. `s = min(declaredDepth, localWall) /
cellsPerMemberFloor`. Never-overshoot is now satisfied **by construction**, with no
epsilon anywhere: `s <= wall` always.

### The numbers, on his project, from the app's own log

```
before   sizes=[1.72=13  2.01=30  3.44=12  4.01=17  5.16=82  6.02=56  10.31=197  12.03=121]
after 3a sizes=[2.01=18  3.44=34  4.01=27  6.02=9   10.31=270 12.03=170]
after 3b sizes=[3.44=29  4.00=10  4.01=15  4.33=12  10.31=188 12.00=104 12.03=68  13.00=102]
```

* S/2 (5.16 and 6.02) — **gone**.
* The body of the wall now sits at `{10.31, 12.00, 12.03, 13.00}`: the measured wall,
  capped at the depths he typed. That is his single-cell rule, literally.
* Tap callout in the app moved from `5% · 0.47 mm strut · 5.16 mm cell` to
  `5% · 0.94 mm strut · 10.31 mm cell`.
* See-through (a pixel inside the part's silhouette reading as background) measured
  **0.00% at eight azimuths plus both whole-part views**.

### The permutation sweep (bake)

```
single-cell ON  · stepped-grade  · no-grade   4 sizes  min 10.31  below-S/3    0 (0.0%)
single-cell ON  · stepped-grade  · shape      8 sizes  min  3.44  below-S/3   54 (10.2%)
single-cell ON  · default-grade  · no-grade   4 sizes  min 10.31  below-S/3    0 (0.0%)
single-cell ON  · default-grade  · shape     12 sizes  min  2.58  below-S/3   41 (7.8%)
single-cell OFF · stepped-grade  · no-grade   5 sizes  min  4.30  below-S/3    0 (0.0%)
single-cell OFF · stepped-grade  · shape     10 sizes  min  1.43  below-S/3  588 (17.9%)
single-cell OFF · default-grade  · no-grade   5 sizes  min  4.30  below-S/3    0 (0.0%)
single-cell OFF · default-grade  · shape     13 sizes  min  1.29  below-S/3  322 (9.8%)
```

`no-grade` is exactly right in all four combinations: single-cell ON gives the local
wall, OFF gives half of it (two across). **The remaining fabric is entirely the
shape grade.**

---

## 3b. THE THIRD FIX, AND THE EVIDENCE TABLE

### The band's cap is gone — the grade is a gradient again

`shapeBandMaxDivisor = 3` capped the band's divisor against the per-spot cell. The
ramp underneath it (`levels = (nCap-1)*(1-t)`, `ramp = 1 + ceil(levels)`) is a true
linear gradient from 1 at the band's inner edge to `nCap` at the outline — but the
cap flattened **86% of the band to exactly n = 3**, because `ramp >= 3` as soon as
`d <= 0.714 * reach`. One wide ring of S/3 is not "graded more and more toward the
outline"; it is a step.

The cap was added by `00af9728` to stop the fabric. The fabric it was fighting was
the spurious halving in §0 — with that fixed, the cap only flattened the grade, so
it is removed. Each rung now occupies `reach / (nCap - 1)` of the band (1.4 mm on
his 10 mm band), so the finest cells are a thin ring AT the outline.

### The evidence table — 35 combinations, on his part

Every combination of single-cell x finish x grade x step-style, plus the density
band, scored on: cells at exactly S/2 (a failure on the stepped path), the fraction
finer than S/3, and SEE-THROUGH from front and back.

```
                                            sizes  min   below-S/3     at-S/2  see-through
1-cell · fullSkin · shape    · stepped        11   2.58   57 (10.8%)      0      0.00%
1-cell · fullSkin · no-grade · stepped         4  10.31    0 ( 0.0%)      0      0.00%
1-cell · fullSkin · shape    · default        12   2.58   41 ( 7.8%)      0      0.00%
1-cell · fullSkin · no-grade · default         4  10.31    0 ( 0.0%)      0      0.00%
2-cell · fullSkin · shape    · stepped        11   1.43  591 (18.0%)      0      0.00%
2-cell · fullSkin · no-grade · stepped         5   4.30    0 ( 0.0%)      0      0.00%
   … and the same for finish none / rim / covered, and rho 0.20 / 0.50 / 0.90
FAILURES: none
```

`LatticeQuiltMatrixProbe` writes a frame per row to `$QUILT_OUT`.

**One interaction the table exposes and it is not a bug:** `1-cell · none` behaves
exactly like `2-cell`, because the app computes `boundaryFinishWritten =
singleCellMembers && boundary != .none`. Core will only allow ONE cell across a
member when a finish re-ties the struts a one-cell member severs, so single-cell
with no finish still gets a floor of 2. The toggle does not act alone.

---

## 3c. WHAT THE SIMULATOR SHOWS — build `d4342a87`, his own project

Every one of these is a `simctl io screenshot` of the running app on his project,
with the app's own DIAG histogram captured in the same session. The headless bake
matched the app's line EXACTLY on every one.

| setting | app's bake | verdict |
|---|---|---|
| single-cell ON · Stress+shape · Stepped · Skin (HIS SETTINGS) | `2.58=9 3.01=4 3.25=3 3.44=20 4.00=10 4.01=11 4.33=9 10.31=188 12.00=104 12.03=68 13.00=102` | body uniform, open truss; grade is a thin ring at the outline |
| single-cell ON · **No grade** · Stepped · Skin | `10.31=217 12.00=114 12.03=83 13.00=114` | **clean** — front AND back: large, evenly-spaced, well-separated cells. The best picture the preview has produced. |
| single-cell OFF · Stress+shape · Stepped · Skin | region cells `5.156 / 6.015`, `1.43=24 1.62=3 1.72=333 2.00=231 2.01=155 2.17=211 4.30=10 5.16=1119 6.00=423 6.02=354 6.50=422` | **STILL FABRIC** — see §4c |
| Default Grade (`algorithm: "doubled"`) | `DIAG steppedCells GUARD algo='doubled' — preview draws the ladder` | regular diamond lattice; a DIFFERENT bake, untouched by tonight's changes |

Tap callout on his own wall, before → after: `5% · 0.47 mm strut · 5.16 mm cell`
→ `5% · 0.94 mm strut · 10.31 mm cell`. Cell and strut both doubled.

★ **"Default Grade" is the DOUBLED ALGORITHM, not a step style.**
`LatticeCellTransition.defaultGrade.coreAlgorithm == "doubled"`, and
`LatticeWizardModel` derives BOTH `algorithm` and `gradeStepStyle` from
`cellTransition` on Save & Exit. So the preview bakes it through `gradedCellField`
(the dyadic ladder) and `steppedCellField` is never called. Nothing in tonight's
changes touches that path, and it has NOT been swept. The `dyadic` column in
`LatticeQuiltMatrixProbe` is the STEPPED bake's own `dyadicSteps` option — a
different thing, now labelled `dyadic-steps` to stop the confusion recurring.

---

## 4. WHAT IS STILL OPEN

### 4a. Fragments where the prism meets other material

At the bottom of the wall, where the face prism passes through the base plate, the
struts render as **disconnected blobs against the shell** rather than as lattice —
strut cross-sections sliced flush by the part surface. Captured at
`f2/00_shipped_front.png`, bottom strip.

Geometrically this is `dClip` doing what it says ("cut flush at the part surface,
like a machined section"), and he did say the floor overlap "gets a bit of lattice".
But it reads as debris, and it is a strong candidate for the grey patches his image 4
arrows point at. The grade-to-solid rule is the natural fix — the solid band is
currently `max(finestPrintableCell, oneVoxel) = 1.72 mm`, less than half a fine cell,
so it does not cover the fragments. NOT YET FIXED.

### 4b. (FIXED, 4th change) The band took its finest rung TWICE

At single-cell OFF the region cell is half the wall (5.156 / 6.015 mm — two across,
exactly what he asked for), and the shape grade was taking **18.0% of the wall** down
to 1.43–2.17 mm; in the simulator it read as fine noise with no cell structure.

Cause, measured: on the stepped path `n == 2` is bumped to 3 because S/2 is not a
size he allows. The ramp's FIRST rung asks for exactly 2 — so rungs one and two both
landed on S/3, a **double-width ring of the finest step the ladder can take**. With
`nCap` only 4 at 2-cell that ring is two thirds of the whole band.

Fix: a rung the ladder cannot express is not a rung — where the ramp asks for a
halving the cell does not step yet, and the grade starts where a THIRD is genuinely
called for. Strictly coarser, never finer, so it cannot reintroduce fabric.

```
                                   below-S/3 before -> after
2-cell · stepped · shape            591 (18.0%)  ->  122 ( 3.7%)     1.72mm x333 -> x68
1-cell · stepped · shape             57 (10.8%)  ->   36 ( 6.8%)
```

App bake at 2-cell after the fix:
`[1.62=3 1.72=68 2.00=51 2.01=25 2.17=175 4.30=34 5.16=1384 6.00=603 6.02=484 6.50=458]`
— the body is the region cell, the grade is a thin ring.

### 4c. White speckle on the chamfer

`sim/r01_speck.png`: bright specks along the chamfer band where the lattice meets the
shell — the long-standing shell/lattice interpenetration at the region's zero
crossing. Small in scale, and it predates tonight in character, but it is visible at
his zoom. NOT YET INVESTIGATED tonight.

### 4b. "EMPTY SPACE" — his image 4

He says empty space = holes, *"empty space where a lattice is meant to be"*. The
see-through metric is 0.00%, so nothing is transparent. The grey patches in his
image are therefore either the **solid rim/outline fill** (which the grade-to-solid
rule says SHOULD be solid near the boundary) or a wall where no strut was drawn.
These are different defects with different fixes and the metric to separate them —
"a pixel where the shell stood down but no strut was drawn" — is **not yet built**.
Build it before drawing a conclusion.

### 4c. Not yet swept

finish (None / Rim / Skin / Covered), density (Sim / Uniform / Per region), cell size
mode (Auto / Fit / Swept / Manual), and both walls inside and out in the simulator
for every combination. The bake sweep in §3 covers grade x single-cell only.

---

## 5. THE HARNESS, AND HOW TO DRIVE THE SIMULATOR

Three probes, all in `app/TopOptKit/Tests/TopOptFlowsTests/`:

| probe | what it is for |
|---|---|
| `LatticeQuiltBakeProbe` | reproduces his bake and **pins it to the app's DIAG histogram**. Start here; if this fails, fix it before anything else. |
| `LatticeQuiltFrameProbe` | one offscreen frame with shell + clip + struts, through `MeshRenderer` in the app's own order. Asserts a positive control (hiding the lattice must move >5% of pixels). A microscope, not a judge. |
| `LatticeHoleMetricProbe` | see-through: a pixel inside the part's silhouette that reads as background. Eight azimuths plus both whole-part views. |

`LatticeQuiltSweepProbe` runs the grade x single-cell matrix through the real bake.

### Driving the app

Simulator `A030C20C-D243-4CC4-A602-E2A90FB6CCDF`, bundle **`com.nadim.topopt`**
(there is a second bundle, `com.topopt.TopOpt`, with its own data container — check
`simctl listapps` for which one holds the project before reading `project.json`).

Tap path in device POINTS (1032 x 1376), from the project list:

```
(833, 261)  the M2 verticalStand card with the green Optimized badge
(486,  98)  See Original
(732,  80)  Lattice
(988, 288)  the box viewport icon
(943,1311)  Save & Exit          <- this is what ARMS the preview and forces a bake
(935, 748)  the "Interior fill" legend row -> explore mode, the part goes invisible
```

Waits matter: ~10 s after each navigation tap, **~35 s after Save & Exit** before the
bake lands. Screenshots with `xcrun simctl io <udid> screenshot <path>.png` (the MCP
screenshot action does not write a file). Pinch with the simulator control's
`touch2_path`; a **double-tap cannot be injected**, so explore mode is left by
relaunching the app, not by double-tapping.

---

## 6. TRAPS THAT COST TIME TONIGHT

* **The vendored core on this branch was STALE** — `core/include/topopt/job.hpp` was
  newer than `vendor/TopOptCore.xcframework/*/libtopopt.a`. `swift test` then hangs
  in `topopt::JobLatticeRegion::~JobLatticeRegion()` at `job.hpp:155` (a destructor
  walking a vector whose layout the compiled lib disagrees about). `sample` the
  `xctest` pid to see it. Fix: `./app/scripts/build_core.sh`.
* `swift test` on a long filter exceeds the 10-minute foreground cap — run it as a
  background task or it is killed with no result.
* `pgrep -f "<pattern>"` matches the shell that is running it. Find the `xctest` pid
  with `ps -Ao pid,comm | awk '/xctest$/{print $1}'`.

---

## 7. THE DIFF, AND HOW TO UNDO IT

Only ONE production file changed:

```
app/TopOptKit/Sources/TopOptFlows/LatticePreviewOccupancy.swift
```

Four edits, all inside `steppedCellField`, all reversible independently:

1. `let exact = cellMM` + `var s = exact[prime]` — the fit arithmetic uses the cell as
   derived, not the half-rounded one. **The single biggest one.**
2. `if target > 1e-6, abs(target - s) > 1e-9 { s = target }` — the per-spot cell IS the
   material under it; the `S/n` quantisation is gone.
3. `n = Swift.max(n, ramp)` — `shapeBandMaxDivisor` no longer caps the band's ramp.
4. `let rung = (!dyadicSteps && ramp == 2) ? 1 : ramp` — the band does not take its
   finest rung twice when S/2 is unavailable.

Two test files changed and one is a pre-existing red:

* `LatticePerVoxelWidthTests` — the whole-number-division assertion is REPLACED (not
  deleted) by the rules he actually stated: never-overshoot, never S/2, and the body
  of the face follows its own wall.
* `ShellClipLayoutTests` — **was already failing at `1320715f`.** `7885e3cd` added the
  `eye` field to `ShellClipUniform` (5 float4s, 80 bytes) and left the test asserting
  64. Brought in line. Nothing to do with tonight's work; it is fixed because a red
  guard on this exact boundary is worse than no guard.

`git checkout -- app/TopOptKit/Sources` reverts every behaviour change. The three new
probes and this handoff are additive.

## 8. TEST STATE

* `swift test --filter Lattice` — **740 tests, 0 failures.**
* `swift test` (full) — the only failures are three 3MF-import tests
  (`AppModelTests.testThreeMF…`), which are an environment gap in this worktree
  (`lib3mf`), not a code failure, and were failing before any change tonight.

**Beware:** `swift test` REWRITES other tasks' evidence files
(`evidence/2026-08-08-…`, `2026-08-12-…`, `2026-08-14-…`). Check `git status` after
every run and `git checkout --` them.
