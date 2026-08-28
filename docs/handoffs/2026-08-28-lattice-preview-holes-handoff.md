# Lattice preview: the holes — full handoff

**Branch:** `claude/topopt-holes-quilting-298212`
**Worktree:** `.claude/worktrees/face-regions-union-split-grid-c52969`
**Installed build at time of writing:** `631330e6` (Debug, iOS Simulator)
**Suite at that build:** `swift test --filter 'Lattice|ShellClip'` → **768 tests, 13 skipped, 0 failures**

---

## 0. THE BAR — read this section before touching anything

These are the maintainer's standing requirements. The previous round of this task
went badly because they were skimmed. They are not style preferences.

1. **Judge every result in the SIMULATOR, on his screen, zoomed in.** Never from your
   own offscreen renders. Offscreen frames are for *searching*; the simulator is the
   only place a verdict is taken.
2. **When he is offline, verify it yourself on the simulator.** When he is online,
   *also* ask him to look — his eye finds in seconds what has cost hours to measure.
   Do not sit waiting on him for something you can check.
3. **Verify the binary three ways every time you install:** hash of the build product,
   hash of the installed bundle, and that the running process is that bundle. A stale
   Debug build beside a fresh one has burned a night before.
4. **Never claim something is fixed without both** (a) a zoomed simulator screenshot
   and (b) a number that moved. One without the other is not evidence.
5. **Do not stop at "better".** The bar is no holes and no quilt across *every setting
   permutation*, checked from both sides of the part.
6. **Re-pin tests, never loosen them.** When a guard goes red because behaviour changed
   on purpose, re-pin it to the new contract and say why in the test. If you cannot
   justify the new pin in writing, the change is probably wrong.
7. **Restore his project settings** if you change them to test. `project.json` must
   diff clean against a backup you took before you started.
8. **Do not touch the Organic algorithm.** It is unfinished and out of scope.
9. **Do not run `swift test` and assume evidence files are untouched** — it rewrites
   other tasks' `evidence/` files. `git checkout --` them afterwards.

---

## 1. What is still wrong

**Holes along the sides of the latticed walls, concentrated where the face outline is
curved.** They survive every grade setting (Stress + shape, Shape, Stress, and Grade
off) and both single-cell states, which rules out the grading path.

The maintainer's own diagnosis, which has been right every time so far:

> "Basically, the issue is curves. And curves are a problem due to resolution. So for
> stress grade alone, you need to extend the lattices out *beyond* the face-prism, then
> use the prism to cut off the excess. For the grade to fit: you need to make the
> lattices get smaller to fit in between the areas as much as possible, then ONLY WHEN
> NO MORE CAN FIT can you make the rest solid."

Both halves of that are now implemented (§4.12–§4.15). Holes on the curved sides remain.

### The one clean observation about the remaining band

Hiding the body via the legend, at the **outer silhouette edge** (background behind it,
so the far wall cannot show through) the band **fills in with struts**. That points to:
*the material is there, and something in front of it is dark.*

**It is not yet proven.** Five attempts to quantify that band came back confounded —
see §6. Do not build on it without a clean measurement.

### If it IS the shell covering real lattice

The fix lives in `shell_is_latticed` (`MetalMeshView.swift`, in `shellClipMSL`). Two
constraints that must both hold:

- **The 30° normal gate is the only thing keeping the chamfer alive.** The maintainer
  has complained four separate times about the lattice eating chamfers and top faces
  ("Why is it breaking the top faces??? They are just gone"). Do not widen the gate.
- **The shell's cut and the lattice's clip must move together.** The lattice is clipped
  at `dRegion <= 0`. If you relax the shell's containment past the outline without
  giving the lattice the same reach, you trade this band for a genuine hole.

---

## 2. How to reach the lattice preview

The navigation is not obvious and one wrong tap starts a run.

1. **Home → the tile named `M2 verticalStand` that is marked `Ready`** (not the one
   marked `Optimized`). That is project `102117B9-DDD2-4597-9BDE-49DD47EBF393`. The
   `Optimized` one opens straight to Results and its Lattice entry is *disabled*
   (solved on-device, so it writes no certification document).
   Tiles are ordered most-recent-first, so the position moves — read the labels.
2. **Top-right stage pill → `Lattice`.** The page title becomes `Aesthetic`.
3. **The third of the three round icons under the orientation gizmo** — the one that is
   a cube with a lattice inside. This opens the lattice Settings sheet.
4. **`In the part`** (bottom-left of the sheet) — switches the sheet from the one-cell
   sample to the whole part, and expands the full settings panel.
5. **`Save & Exit`** (bottom-right) — returns to the part with the strut preview armed.
   The caption `LATTICE PREVIEW — live strut geometry, not the exported mesh` confirms it.

### Traps

- **The blue `Lattice · 2 regions` button in the bottom bar RUNS a lattice job.** It does
  not open the preview. Cancelling it is unreliable; terminate the app instead. (It does
  write a real `lattice_job.json` into the project folder, which is a genuinely useful
  artefact if you ever want the job document.)
- **Tapping the part in normal mode selects a face and creates a group.** Undo with the
  arrow at top-left, and check the `Selections` count went back to 3.
- **Bake times are 30–50 s** after any settings change. Screenshotting early gives you
  the previous frame or a black one.
- **A fresh install resets navigation to the project list;** a plain relaunch restores
  the last page.

### The diagnostics he uses

- **Tap a legend row** in the `TAP TO EXPLORE` panel → hides the body so you can see the
  struts alone. **Double-tap the viewport** to go back.
  *This is a diagnostic, not a verdict:* the part is a channel with two parallel latticed
  skins ~27 mm apart, so with the body hidden you see BOTH at once and any pixel count
  is confounded. Only trust it where nothing is behind the surface you are looking at.
- **Tap a strut** in explore mode → callout with relative density, strut width and cell
  size. A tap that returns the *neighbouring* strut means the march found no hit there.

---

## 3. Vocabulary — what the settings mean

His definitions, in his words where possible.

| Setting | Meaning |
|---|---|
| **Stepped** (Grade style) | One cell size per declared region, arbitrary divisors. *"Stepped grade means NOT dyadic (any number but 1/2 is ok)."* S/2 is the one divisor it may never produce. |
| **Default Grade** | Dyadic — halving. Every graded cell's nodes land on its parent's. |
| **Organic Grade** | Unfinished. **Ignore it.** |
| **Grade the lattice — off** | *"the cell should just be cut off where it ends."* No subdivision; full cells clipped at the outline. Verified: `n = [n1 = 3369]`, `gradedToSolid = 0`. |
| **Grade: Stress + shape** | Density follows the FEA solve **and** the cells fit the outline. |
| **Grade: Shape** | Cells fit the outline only. |
| **Grade: Stress** | Density follows the solve only. |
| **Grade to shape band (mm)** | How far in from the face's outline the cells keep stepping down. His part: 10 mm. |
| **Grade to shape terminus** | *"as it gets closer, it is graded more and more, until it becomes a solid and connects the sides."* And: *"ONLY WHEN NO MORE CAN FIT can you make the rest solid."* So: step down to the finest **printable** cell, then solid — never a jump straight to solid. |
| **single-cell/member = ON** | *"make the largest single cell across the entire model - per voxel. So this will change based on the thickness of the area it's in. If the area is 13mm, the cell is 13mm, if the area next to it is 12mm the cell next to it is 12mm."* **Also auto-sets the Skin finish** — the panel says so. Treat it as two settings. |
| **single-cell/member = OFF** | Two cells across a member; the local thickness is averaged rather than followed per voxel. |
| **Cell size** | `Auto·Sim` / `Swept·Sim` / `Manual` / `Fit`. |
| **Density** | `Sim` / `Uniform` / `Per region`. |
| **Finish** | `None` / `Rim` / `Skin` / `Covered`. |
| **Face prism** | *"the face-prism only makes what's solid into lattice, it cannot make walls thicker. If it overlaps with a floor, that floor overlap gets a bit of lattice."* |
| **Fast·64³ / Fine·128³ chip** | **The JOB's grid, not the preview's.** The preview always bakes at 128³ (`LatticeSDFScene`'s default; `WorkspacePlaceholder` never passes `maxDim`). Flipping the chip and seeing an identical picture does NOT rule resolution out. |

---

## 4. Everything fixed, in order, with the number that moved

Each of these was measured, not argued. The headline two are **#10** (the interior
holes) and **#1** (the quilt).

**1. The quilt was a density lie.** `proxyParams` set `uniformRelativeDensity` to the
*midpoint* of the density band, so with no demand field the march drew the whole part at
**47.5%** — where an octet's struts merge into a sheet with periodic holes — while the tap
callout computed `lo + (hi−lo)·activation^gamma` with `activation = 0` and reported **5%**.
Renderer and callout disagreed by 10×, which is why every measurement aimed at the quilt
missed it. *(`LatticeSDFMetal.swift`, `shadeParams`.)*

**2. Half-float rounding halved the cell.** `halfRepresentable` turned a 4.3333 mm cell
into 4.332; against an unrounded floor that rounded down to "no subdivision permitted",
and 51.3% of wall voxels took S/2. 260 nanometres. Fixed with a relative epsilon sized
to half precision (2e-3).

**3. `S/n` quantisation** prevented "cell = local wall", so a 10.31 mm wall under a
12.03 mm region cell had no permitted size between overshoot and half — and took half.

**4. `shapeBandMaxDivisor`** flattened 86% of the band to exactly S/3 — one wide ring,
not a grade.

**5. The band took its finest rung twice**, because S/2 is banned and the `n == 2 → 3`
bump turned the ramp's first rung into a third as well.

**6. `singleCellMembers && boundary != .none`** silently overrode the toggle whenever
Finish was None. Four sites in `WorkspacePlaceholder`.

**7. The attached seed leaked down the depth.** The rim BFS drops the thickness axis, so
one seed voxel anywhere in a depth column zeroed that whole in-plane column.
**33,257 of 46,764 seed voxels (71.1%)** were in-plane inside a region.

**8. The rim band was pinned to the grid.** `max(finestPrintableCell, oneVoxel)` = 1.719 mm,
and the field's own floor is also one voxel — the same number, sampled once per 10.31 mm
cell. A 6:1 lottery makes a scatter, not a ring. Now `0.33 × local cell`.

**9. Grade-to-shape had never fired, at all.** `boundaryAt` maxes over the cell's
footprint, so the fit distance was systematically half a cell too large: `d[min] = 6.87`
against `dCentre[min] = 1.72`, and the half-extent for a 10.31 mm cell on a 1.72 mm grid
is exactly 3 voxels = 5.16 mm. `1.72 + 5.16 = 6.88`. With `d ≥ 6.87` and `s ≤ 12`,
`n_fit = ceil(s/2d)` is 1 everywhere on the part.

```
before   n = [n1=339  n3=17  n4=20]
after    n = [n1=229  n3=44  n4=17  n5=23  n6=20  n7=28  n8=12  n9=3]
```

**10. THE INTERIOR HOLES — the march lost each cell's own struts.**
`lsdf_march`'s 3×3×3 prefetch resolved **every** neighbour, self included, by the
covering block's *centre* base cell:

```
float3 cc = floor((nb + 0.5) * LC.m + LC.phase);
bool sameLattice = abs(rgb.b - LC.S) <= 1e-3 * max(LC.S, 1.0);
```

but `LC.S` was read at `bi = round(cb)` — the base cell the ray is actually in. Over most
of a block's extent those are different texels; a per-spot cell rule gives them different
**sizes**; `sameLattice` fails for **self**; `rnCache[13]` goes to −1; and the strut loop
skips every segment self owns. `anyActive` still comes back true off a neighbour, so
nothing is flagged and the ray marches on — a thinned, grid-aligned, cell-shaped patch
that returns no hit when tapped.

Measured by replaying the arithmetic on the baked field (`LatticeSelfNeighbourProbe`):

```
single-cell OFF   1415 / 2649  =  53.4%   of painted cells lose their own struts
single-cell ON     308 /  376  =  81.9%
all-27-miss             0              ← why it never showed up as a dark cell
```

The 53.4 / 81.9 ordering is exactly what the maintainer reported ("more holes than with
it off") — derived from the bake before anything was rendered. Fixed by carrying the
demand out of the *same* texture read that produced `LC.S` (`LCell.act`), so the self
entry cannot disagree with the frame it belongs to. He confirmed: *"you've gotten rid of
the holes in middle of the lattice COMPLETELY."*

**11. `out.solid` was a stale proxy** — `out.solid = anyActive ? 0.0 : 1.0`. That held
only while the sole route to solid was a cell being inactive, and #10 broke it: every
painted cell now reports `anyActive`, so the grade's solid band at the outline was shaded
as a strut. Now `out.solid = (Fsolid <= Fstrut)` — the hit names the field that produced
it. `F` was split into `Fstrut`/`Fsolid`; the behaviour is unchanged (check by hand: with
`anyActive` false, `Fstrut = 1e9`, `Fsolid = dClip`, `F = dClip`).

**12. Region ownership was a centre test.** A base cell straddling the outline — centre
just outside, most of its volume inside — was owned by nobody and emitted nothing, leaving
a band up to half a cell wide with no struts. Now `LatticeRegionMask.contains(_:region:
inPlaneReachMM:)`, reaching **one full cell** past the outline. In-plane only: the depth
slab is untouched, because a prism may not make a wall thicker.

**13. The aesthetic ladder cap was truncating the grade.** A cap of 3 meant
`full → S/3 → solid`, so the border came out two cells of flat solid. Removed on his
ruling. The printability cap `nCap` is the real floor.

```
before   n = [1851, 1101 × S/3]                gradedToSolid = 449
after    n = [1851,  652 × S/3, 449 × S/4]     gradedToSolid =  49
```

**14. The overshoot ring was being subdivided, so it never joined.** A cell whose centre
is outside the outline has no fit distance, and the code read that as "no room — take the
finest printable cell". So the ring outside carried 1.29 mm while the wall inside carried
5.16, `sameLattice` rejected it as a different lattice, and its struts were never
evaluated in its neighbours' neighbourhood. **That is the "lattices with single-cell
members that don't fully connect".** The ring now keeps the region's own cell and `dClip`
trims it at the prism — extend, then cut. It also never terminates in solid: solid is for
a cell *inside* the face that cannot fit, not for excess.

**15. THE OCCUPANCY GATE WAS A CENTRE TEST TOO** — and it was the one that bound.

```
if grid.values[i] >= 0 {          // material at the base cell's CENTRE
```

Along a curved outline a straight cell grid necessarily straddles the material boundary,
those centres fall off it, and the cells emit nothing. This is why widening the *region's*
ownership alone changed almost nothing (**6,288 pixels of 2.4 M**). Now an overlap test
(`occupancyNear`). `painted 2952 → 3369`, all 417 on the curves.

**16. Solid was drawn paler than the sparsest strut.** `mix(denseColor, white, 0.55)` —
55% of the way to white — inverting the legend the page states in words (*"pale is thin,
deep is thick"*), so 100%-dense material read as a gap. Now the deep end of its own class:
rim hue at a boundary, fill hue inside.

**17. Chamfer artifacts were z-fighting.** Where the shell survives it owns the boundary
and the lattice is held inside by `clamp(0.25·voxel, 0.2, 0.6)` = **0.43 mm** on the Fine
128 grid. On-screen depth separation is the offset times the cosine of the view angle, so
on a chamfer seen edge-on that collapses and the two surfaces trade pixels. Now
`clamp(0.75·voxel, 0.6, 1.8)` = **1.29 mm**. Free: that branch only runs where the shell
already hides everything behind it. *(Pre-existing, not introduced by #15 — verified
against frames from before that change.)*

---

## 5. Instrumentation you have

### DIAG lines (NSLog, visible via `xcrun simctl spawn <udid> log stream`)

```
DIAG steppedGrade painted=… d[min/p25/p50/max] finest=… bandMM=… solidRim=…
                  gradedToSolid=… ring=… ladderCap=… fitOff=… dCentre[…] n=[n1=… n3=…] w[…]
DIAG steppedSolid decided=… written=… painted=…      ← the solid marker survives the write
DIAG stepped regions=… stated=[…] finest=… printableFloor=… nCap=… sizes=[…]
DIAG rim dressing=… outlineFrac=… lineWidth=… steppedDrawn=…
```

### Environment switches (`SIMCTL_CHILD_<VAR>=… xcrun simctl launch …`)

| Variable | Effect |
|---|---|
| `TOPOPT_LATTICE_FIT_OFF=1` | restores the pre-fix fit distance (the raw footprint max, which never fires) |
| `TOPOPT_LATTICE_SHAPE_CAP=n` | caps the aesthetic ladder at n rungs (default: uncapped) |
| `TOPOPT_LATTICE_SOLID_RING=1\|2` | how many cell rings terminate in solid |
| `TOPOPT_LATTICE_OVERSHOOT=x` | how far past the outline ownership reaches, in cells (default 1.0) |

These exist so two behaviours can be compared **on the device, at one camera, from one
binary**. Judging a render of yours against a memory of his screen is how the worst
regression of this task shipped.

### Probes

- `LatticeQuiltBakeProbe` — **pins the headless bake to the app's own DIAG histogram.**
  Re-pinned three times, never loosened. If this is red, fix the harness before believing
  any number it prints.
- `LatticeSelfNeighbourProbe` — replays the march's self-neighbour lookup on the baked field.
- `LatticeEdgeBandProbe` — renders with `latticeDebugShadeMode = 2` and classifies pixels
  into lattice / solid / shell. **Set the debug mode AFTER `setLatticeScene`** — it
  forwards to `latticeLayer`, which does not exist until the scene creates it, so setting
  it in the `tweak` hook is a silent no-op and the "debug" frame comes back identical.

---

## 6. What was tried and did NOT work — do not repeat these

### A fix that made it worse and was reverted on his instruction

`wFit = wLocal + walkStep` — a whole voxel of slack against the wall, to stop a sliver
pinning the face. It quilted the entire part. His response: *"It said NOT TO DO THE THING
YOU JUST FUCKING DID! UNDO IT!"* The lesson recorded at the time: **judged from a
histogram instead of his screen, and traded away a binding rule for a prettier number.**

### Five confounded measurements of the side band

Every one of these produced a number that looked meaningful and was not:

1. **body-alpha 0 pixel counts** — the part is a channel; the far wall's struts show
   through the near one, so every count is inflated.
2. **A no-lattice control frame** — hiding the lattice also changes the shell's AO
   *everywhere*, so only 62 pixels of 362,142 matched and the comparison said nothing.
3. **Declaring only the near face** — `hisFaces[0]` is the far one at that camera.
4. **A colour scan of the "outer edge"** — the crop started at x=0, which is the ground
   plane, not the part.
5. **A band-width scanline metric** — picks up the shell's own edge highlight; gave
   `+10/+0/+30 px` against `+3/+18/+49 px` across three scanlines, no consistent sign.

**If you measure this band, state your confound control first.**

### Dead theories, killed by measurement

- Refused cells (member floor): 0 of 376.
- Coplanar faces: 100% agree.
- Wall deeper than prism: 0 voxels.
- Bake/march region agreement: 100%.
- `anyActive` failing: **0 of 2,649 and 0 of 376** cells lose all 27 neighbours.
- Resolution (Fast vs Fine): the preview always bakes at 128³ — the chip is the job's.

---

## 7. State of the tests

`swift test --filter 'Lattice|ShellClip'` → **768 tests, 13 skipped, 0 failures.**

Four guards went red during this work and all four were re-pinned to the *stronger*
contract, never loosened:

- `LatticeQuiltBakeProbe.testTheHeadlessBakeMatchesTheApp` — re-pinned 3× to the running
  app's histogram.
- `LatticeSolidFillTests` ×3 — the shader restructure moved the literals. One of them
  pinned `out.solid = anyActive ? 0.0 : 1.0` under the comment *"so the picture and the
  field cannot disagree"* — that line **was** the disagreement, so the guard now pins the
  field comparison instead.
- `LatticeSteppedGradeProbe.testWhatTheSteppedBakeWrote` — its predicate filtered
  `outline > 0` and so went blind to the solid marker, which is exactly `0`. It now
  accepts either a fine graded cell or solid, which is strictly stronger.
- `LatticePerVoxelWidthTests.testASliverNoLongerPinsTheWholeFace` — was red because the
  ladder cap was sending half that fixture's face to solid. **Removing the cap fixed it
  with no change to the test.**

---

## 8. Not done

- **The permutation sweep.** Verified on the device: Grade off; Stress + shape with
  single-cell off; single-cell on. Not verified: Shape-only, Stress-only, Finish
  Rim/Skin/Covered, Density Uniform/Per region, Cell size Swept/Manual/Fit, Default Grade
  (dyadic), and none of it from the back side.
- **The side holes on curved outlines** — §1.
- Whether the coarse open truss at single-cell ON reads as "green holes" to him at
  working zoom, or is simply what a 5% octet at a 10–12 mm cell looks like.

---

## 9. His project

`102117B9-DDD2-4597-9BDE-49DD47EBF393` — `M2 verticalStand`, marked `Ready`.
Two face regions: face 2 at 12 mm, face 15 at 11 mm. Stepped, Auto·Sim, Density Sim,
Finish None, Grade on / Stress + shape, band 10.00 mm, single-cell **off**.

A backup was taken before any settings were touched and the file has been restored to it
byte-identical. **Take your own backup before you change anything**, and note that
toggles do not always take through synthetic taps — restoring by terminating the app and
replacing `project.json` is deterministic where the UI is not.
