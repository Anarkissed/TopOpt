# 2026-09-14 — The octree bake: fewest cells, every region on its own ladder, a solid outline, whole cells

App only; no core change. Branch `claude/quilt-lattice-preview-m2-39c5dd`, on top of
`7f2cd62c`. Revert switch: `LatticeSDFRenderer.octreeBake = false` puts the stepped
bake of `f462a39b` back (its ring rules are gone from `steppedCellField` too — the
last ring build is `a0392dd2`).

## 1. His rulings (verbatim, 2026-09-14)

- "Always aim for the largest possible cell size because we want to use as FEW CELLS AS
  POSSIBLE … The grading area is specifically made to create room for a smooth gradient
  between those largest possible cells and the solid outline. The smallest cells go in
  the areas none of the larger cells can go … and as little as possible."
- "grade to shape: solid outline that wraps the lattice in the shape of the face-prism's
  outline … If 0mm then have a solid outline and fill in the empty space with any lattice
  cells you can. Get rid of your ring rules entirely."
- Solid thickness: "definitely a minimum of a bead". Smallest cell: "as low as the REAL
  printability floor ~1.8mm … if there isn't space, then the 2.58mm one is ok".
- "NO CELLS SHOULD BE CUT INTO PARTS! … It should be a singular cell or not. No cuts.
  ever." / "Think of it as a vectored outline with a pixel internal."
- Process: "what I tell you is fucking real - and your job is to figure out WHY not try
  to convince me otherwise." Do not drive the simulator; tell him what to check.

## 2. The three things he kept reporting, and their causes

Measured with a temporary probe on his `M2_verticalStand` (single-cell 12 mm, band 5,
faces 2 and 15; the probe file was deleted before the commit, numbers below).

**A. "The back wall's internal face has 2 mm cells throughout."** Face 15's wall is
**10.00 mm** thick by ray-casting his mesh (SDF zero crossing 9.95, voxel occupancy 10.45);
its region cell is 10.31. The first octree cut used ONE ladder for every region, from
the largest region cell — 12 → 6 → 2 — so that wall got a 6 mm layer and two 2 mm layers
(probe, before: depth 1–4 mm `6.00=3168`, depth 5–10 mm `2.00=3982`). The shared ladder
existed because two ladders with unrelated rungs (12/6/2 and 10.31/5.16/2.58) cannot
share one texel pitch — that is fixed differently now (C).

**B. "Jagged edges on the outline — those are the empty spaces."** Cut texels were
painted only when the texel's MIDDLE was within a bead of the outline; a 2 mm texel whose
middle sits a bead outside still holds up to 1.5 mm of polygon interior. Probe, face 2 at
2 mm depth, 0.25 mm bins from the outline inward: texels with a corner inside 100 %,
painted **89 % / 95 % / 99 %** in the first three bins (100 % only from 0.75 mm). The
unpainted ones draw nothing: the march's solid for an unpainted texel is `dClip`, the
voxel-eroded part clip, which is positive there.

**C. "A BUNCH of 12 mm cells are split in half."** All 26 kept 12 mm slots were whole
in the bake (216 texels each, no other size inside any box). The cut is in the shader:
the octet's canonical struts are the FCC bonds with their midpoint in `[0, S)³`
(`LatticeType.build`), so every +x/+y/+z FACE diagonal is owned by the neighbour on that
side, and `lsdf_march`'s prefetch skipped any neighbour that was not the same cell size
(`sameLattice`) or was unpainted. A 12 mm cell beside 6 mm cells lost three faces; on
the wall whose normal runs −y (face 15) every cell's face on the plate itself is a +y
face owned by the empty outside, so the whole face lost its X.

**And the cut he photographed earlier ("the blue 6mm cell is cut off"):** face 15's
plane sits 0.296 texels (0.59 mm) off the texel grid; slots along the normal are
anchored at the face plane by design, and texels were painted by their START, so the
last 1.4 mm of every 6 mm cell was painted as the 2 mm layer below it.

## 3. What changed

`TopOptKit/Sources/TopOptFlows/LatticeOctreeBake.swift`
- One ladder PER REGION from that region's own cell (`ladderSizes(base:)`: halve while
  the half is a multiple of the finest rung, else a third; finest = smallest
  `base/(2^a·3^b)` ≥ the real floor). The texel pitch is the finest rung of ALL ladders.
- A texel belongs to the cell its MIDDLE is in (`paint`: bounds from `(lo − origin)/pitch
  − 0.5`; the middle is `origin + (i + 0.5)·pitch`).
- Cut (solid) texels: painted when the middle OR any of the four in-plane corners is
  inside the polygon; the material test is taken 1.5 voxels inside the outline along
  the polygon's inward gradient (`inward`), because the occupancy is eroded ~0.6 mm at
  the wall (probe: `occ%` 57 / 81 / 91 / 98 in the first four bins) and would refuse the
  texels the outline needs. Along the depth that point still leaves the wall where the
  wall ends, so a prism deeper than the plate paints no skin.

`TopOptKit/Sources/TopOptFlows/UnifiedShading.swift`
- `LCell.home`: the block of the READ texel's own cell. `lsdf_cell_frame_at` computes the
  frame from the texel's `(size, phase)`, and if the point's block differs from `home`
  re-reads the texel on the point's side (its middle is past the boundary, so its cell
  holds the point — every cell is at least a texel wide). The march re-fetches when the
  point crosses a cell boundary inside the same texel, and the neighbour cache is keyed
  on phase as well as block and size.
- Prefetch: a neighbour that is a different lattice, unpainted or off the grid no longer
  removes this cell's own face — the entry falls back to THIS cell's activation
  (`v = LC.act`). The finer cells on the other side draw theirs; the rungs nest, so
  where the two share a strut they coincide.
- The solid outline is clipped by `max(dBox, prism.b, dPart − delta − 0.3·voxel)`: the
  prism's exact lateral wall, the ray box, and the RAW part surface let out by a third
  of a voxel. Probe: the part SDF is −0.72 mm at the outline at 2 mm depth and −1.20 at
  5 mm (the plate widens under the face), so the outline loses nothing; at the back
  faces the SDF is eroded 0.05–0.45 mm, so a prism deeper than the plate (face 15: 11 vs
  10.00) can no longer draw a lip there.

`LatticeSDFMetal.swift`: `bakedCellMMAt` / `bakedActivationAt` read the texel by
`floor` on stepped fields (texels span `[i, i+1)`), as the shader does.
`LatticeSetupWizard.swift`: the band caption no longer mentions a ring.
`LatticeGradeToSolidBandTests.swift`: rewritten against `octreeCellField` (7 tests:
largest-cell-wherever-it-fits + outline painted + cut remainder solid; no cell cut by
its neighbour, at band 0 / 5 / two regions; the band steps to the finest rung and
thickens toward the quilt; point-span widening; real span left alone; each region on its
own ladder with a face plane 0.7 mm off the grid and a 2.5 mm pitch under 3 mm cells).

Also in this diff (from the same day, uncommitted until now): the octree bake itself
and its call in `LatticeSDFRenderer` (`octreeBake`, DIAG `octree pitch=… kept=[…]`),
`LatticeRegionMask.outlineDistance`, the region texture's `g` (in-plane outline
distance) and `b` (prism-only SDF) channels, `LatticeCellField.solidDepthMM` /
`drawnDensityHi`, and the **lattice-only view**: tap the lattice preview button =
preview on/off; hold 3 s = lattice only (body alpha 0, orange button, "LATTICE ONLY"
badge), which stays after release (the release's tap is swallowed for 1.5 s); tap =
back to the preview (`WorkspacePlaceholder.viewModeButton`, `latticeOnly`).

## 4. Verified

Probe on his mesh after the change (bake 18.5 s Debug on the Mac):
- `octree pitch=2.0 kept=[12.00=26 10.31=86 6.00=194 5.16=248 2.58=11168 2.00=5766]
  cut=6212` (before: `12=26 6=546 2=20154 cut=6504`).
- Face 15, every 1 mm depth layer: `10.31=2313 5.16=828 2.58=711 solid=610` — one cell
  through the wall.
- Face 2 outline, 0.25 mm bins inward from the polygon: painted **100 %** from the
  outline (was 89/95/99); solid 100 % in the first half millimetre, 97/91 to 1 mm, then
  tapering to 0 at 3 mm (the cut 2 mm cells).
- 26 kept 12 mm slots, 216 texels each, none with another size inside.
- `swift test --filter LatticeGradeToSolidBandTests` 7/7; `UnifiedShadingTests`
  (the shader sources compile on macOS) 11/11; `LatticeSteppedGradeProbe`,
  `LatticeSteppedCapPhaseAndDepthProbe` pass.
- Installed on the iPad Pro 13-inch (M5) simulator 23:37; the installed
  `TopOpt.debug.dylib` carries the new shader (marker strings present).

The face-ownership fix (C) and the straddle re-read are shader-side and were NOT
measured on the CPU; his simulator check is the verification. What to look at: the 12 mm
cells beside 6 mm cells (whole X on every face), face 15's plate face (X present), the
stem outline in lattice-only view (smooth, no stair steps), and the back wall's inner
face (one 10.31 mm cell).

## 5. Open — his call

- **How much finest cell.** Cut slots go solid only at the finest rung, so along every
  outline there is a band of finest cells (2 / 2.58 mm) up to one rung wide before the
  solid. He asked for "as little as possible"; a cut at a coarser rung could go solid
  instead when the remainder is under, say, half a rung.
- **Ladder base and step.** The rungs are halves/thirds of the region cell (12 → 6 → 2,
  10.31 → 5.16 → 2.58). He asked "can it go 6 → 5" — no, rungs must nest so cells never
  cut each other; a 10 → 5 → 2.5 ladder needs a 10 mm region cell.
- **Region depth vs wall.** Face 15 is declared 11 mm deep on a 10.00 mm wall (the
  region cell 10.31 came from `measuredW`). The prism therefore overruns the plate by
  1 mm; the solid is now clipped by the raw part so it does not show, but the honest fix
  is the region depth itself.
- **The solid's part clip** lets the raw SDF out by 0.3 voxel (0.5 mm on this part).
  If a lip shows at a back face, lower it; if the outline solid ever loses its skin
  where the outline IS the part's lateral surface, raise it.
- Callouts on a straddling texel report the texel's cell, not the point's (CPU lookups
  do not do the shader's re-read). Only a 10.31 / 5.16 / 2.58 region on a 2 mm grid.

## 6. Suite

`swift test` in `app/TopOptKit`, Debug, macOS, on `5910110f`: **2434 tests, 31 skipped,
10 failing test cases** (103 min). Five are the known pre-existing ones (`AppModelTests`
3MF ×3 — lib3mf in a worktree; `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces`;
`OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology`). Five
were lattice tests pinned to rules this change replaced, all re-pinned in the follow-up
commit and green individually:
- `LatticeCurvedOutlineBandProbe.testTheSolidTerminusIsARingNotADottedLine` and
  `.testSweepEverySettingPermutation`: measured the OLD stepped bake's ring
  (`level == 0`). Now bake through `LatticeQuiltBakeProbe.bakeOctree` (the app's bake),
  solid = `solidDepthMM`, texels by `floor`. On the octree: ring **98 %** on every
  permutation (face 2 100 %, face 15 95 %), unpainted 0.0 %, not-owned 0.0 %; the Skin
  rows measure 0.3 / 0.6 / 0.3 % painted-but-clipped (the 0.9 mm skin clipping whole cells
  the octree places against the outline with the grade off — the shell's skin on screen,
  not empty space), so Skin rows get a 1 % bound; every other row 0.0 % against 0.5 %.
- `LatticePerVoxelWidthTests.testASliverNoLongerPinsTheWholeFace`: rewritten on the
  octree — the 12.03 mm cell is kept over the 12 mm bulk (`slotsKept` > 10), never over
  the 8.59 mm sliver, every size ≤ 13.0 and a rung of the region's own ladder
  (12.03 → 6.015 → 2.005). Its S/2 ban is gone: he accepted nesting halves on
  2026-09-14.
- `LatticeSolidFillTests.testTheSolidUsesTheSameClipTheStrutsDo`: pinned the outline's
  solid to `dClip`; now pins it to the prism ∩ raw part clip and asserts `dClip` is NOT
  used there.
- `LatticeSteppedPhaseTests.testTheShaderSourceDerivesTheSteppedBlockFromTheUnroundedCoord`:
  source pins updated to `blkP` / `o.blk = blkP` and the two `LC.phase` derivations.

`LatticeGradeToSolidBandTests` 7/7, `UnifiedShadingTests` 11/11. The stepped bake
(`steppedCellField`) still runs before the octree in `LatticeSDFRenderer` and is then
discarded — a bake-time cost worth removing once the octree is accepted.

## 7. 2026-09-15 afternoon: his three notes on the octree build, and the answers

Screenshots at 1:14 AM (band 5, lattice-only), 3:35 PM (his red 12 mm cells drawn
inside the band), 3:42 PM (top view, "solid barely visible between the steps"), 3:50 PM
(band 0, "quilted" cells circled at the part's edges).

**1. "Still quite a bit of stepping; the solid should be on top of the steps too."** The
outline's solid skin exists (`dOutV < depth`), but `dOutV` is the region texture's `g`
channel, baked per VOXEL from `LatticeRegionMask.outlineDistance`, which answered 1e3 for
any voxel outside the region's slab. A voxel centre just above the face plane is outside
the slab, the trilinear sample in the first voxel UNDER the face blends with 1e3, and the
skin was never drawn in the very layer he looks at face-on. The cut texels are solid
through their whole depth, so they showed as steps with nothing between them. Now
`outlineDistance(…, slabMarginMM:)` is evaluated two voxels past the caps, and the skin
is never thinner than one texel plus two beads (`S0 + 4·overlayParams.z`) so it sits on
top of the stair steps with a smooth inner face — the "two printed top layers".

**2. "I am still seeing the 12 mm cells cut up … these sections are available."** They
were not cut; they were never placed. The band capped the cell size
(`capAt(nearest) = f·(s/f)^(nearest/band)`): a 12 mm cell had to sit 5 mm from the
outline to be kept, so two rows of 6 mm cells stood where 12 mm cells fit whole. His
reading — "the grade is meant to be a grade from largest to smallest, so this is still
allowed … they connect the two sizes via the walls" — is now the rule: the band never
caps a cell; the largest cell that fits stands anywhere, sizes step down only where the
geometry forces them, and the band drives the thickening toward the solid (`bandT`) and
the solid's bleed. `LatticeGradeToSolidBandTests.testTheBandOnlyThickensAndNeverCapsTheCell`
pins placement at band 5 == placement at band 0 (sizes and solid texels identical) with
the thickening inside the band only.

**3. "Quilted areas at band 0 — quilting should only be in the smallest printable
cells."** Both circled spots are at the part's edges (the stem's top-left corner, the
base's right end). That is the Rim & skin DRESSING: `edge = (1 − |dPart|/band)(1 −
|dRegion|/band)` fattens boundary struts 1.6×, and with the band at 0 the 12 mm cells
stand right against the outline, so their boundary struts are dressed — on a 1.39 mm
strut that reads as a quilted cell. On the stepped path the dressing is now applied
only to cells at the finest rung (`LC.S ≤ 1.01·S0`); the solid outline is the rim for
the rest. This one is a reading of the picture, not a measurement — if the circled
cells are still fat on the 18:21 build, it is something else.

Also: the wizard's band caption says the band thickens and never sizes.
Subset after the change: `LatticeGradeToSolidBandTests` 7/7, `UnifiedShadingTests`
11/11 (shader compiles), `LatticeCurvedOutlineBandProbe.testTheSolidTerminusIsARingNotADottedLine`
100 % / 95 %, `LatticePerVoxelWidthTests`, `LatticeSolidFillTests`,
`LatticeSteppedPhaseTests`, `LatticeSteppedGradeProbe` pass. Installed 18:21.

## 8. 2026-09-15 evening: "all three persist", read off the DIAG, and the anchor

His 6:25–6:28 PM screenshots, band 0 (the DIAG line for that bake: `kept=[12.00=32
10.31=106 6.00=222 5.16=232 2.58=10024 2.00=3915] band=0.0`). What §7 fixed was
reasoned from the picture; this round was measured first:

**Quilted large cells (note 3) were the shader's own per-cell cut test**, not the
dressing. `lsdf_march` sampled the voxel outline distance at a KEPT cell's four in-plane
corners and, where a corner sat a hair inside the outline (the bake let cells touch it
within a bead), drew the whole 6 or 12 mm cell solid in the region tint — the isolated
tinted X cells along the curve and the column at the base's right end. Removed: the bake
decides what is solid (`solidDepthMM`), the shader only draws it.

**The steps (note 1) were the cut texels' own boxes.** The solid was drawn as a test
(`if (dOutV < depth) Fsolid = …prism…`), so the march hit whichever texel face it entered.
Now: a **solid band of one width** `W = max(2 beads, trim + ½ voxel)` (1.18 mm on this
part) — the bake keeps every cell corner `W` clear of the outline (`solidBandMM`, in
`LatticeCellField.solidBandMM`, uploaded as `rimParams.w`), and the shader draws the band
as a field, `max(dOutV − depth, prism, raw part)`, so its inner face is the outline offset
by `depth` (the band, a cut cell's full depth, or the grade's bleed) — smooth, and on top
of the cut texels.

**"Look how far the 12 mm cells could have gone" (his 6:28 PM drawing).** Base slots sit
on a grid anchored at the voxel grid's corner. Along the base's bottom edge and the
slanted edge the last row that fit left an 8–11 mm strip of 6 and 2 mm cells where a 12 mm
row fit a few millimetres lower. **The in-plane anchor is now searched** within one base
cell (eighths along every in-plane axis of the ladders, 64 candidates here) for the
offset that fits the most base-cell VOLUME whole, with the next rung's children breaking
ties (so an anchor leaving one 4 mm remainder beats one leaving two 2 mm slivers of
solid). The outline distance is rasterised at 0.5 mm per region for the search only; the
bake keeps the exact polygon. `cellField`'s extent grows by the shift so the far side
stays covered. On his stand at band 0 (probe, since deleted): anchor (6.0, 0, 6.0) mm —
**12 mm: 32 → 43 whole cells; 10.31 mm: 106 → 120; 6 mm: 222 → 104; 2 mm: 3915 → 3339;
cut 6003 → 8065** (the band `W` cuts what used to touch the outline). Cost on the Mac,
Debug: raster 3.1 s (1 mm step; 0.5 mm cost 10 s), search 0.24 s (two passes: base slots
for all 64, children for the ties), whole bake 20.5 s against 18.3 s before. Base-slot failures
are now in the DIAG: `why=[r0/kept=43 r0/occupancy=19 r0/outline=85 r1/kept=120
r1/occupancy=163 r1/outline=169]` — the 19 and 163 are slots that fit the outline but not
the WALL (face 2 is 8.6–12.0 mm thick; face 15's region is 11 mm on a 10.0 mm wall), which
is the other reason 12 mm cells stop short along the arm; that is the CAD, not the bake.

**Only the finest rung quilts** (note 3's rule): the band's thickening toward the quilt is
applied to finest-rung texels only (`isFinest`); coarser cells in the band keep their own
density, the solid's bleed still applies to every band texel.

Tests: `LatticeGradeToSolidBandTests` (7, now passing `solidBandMM: bead` so the fixture's
geometry holds; the 60 mm slab's outline moved in to 52.9 mm because the anchor fits
nine 6 mm cells into 55 mm exactly), `LatticeSolidFillTests` source pin updated to the
field form.

## 9. 2026-09-15 night: his rules for the outline and the band, stated plainly

His words: *"I want a singular flat outline around the entire lattice that curves and
has no 'pixels' (cells). I want it to be a completely separate thing from the lattice —
an outline that always appears to hold things together and connect it to the rest of
the body; only when the shape grade is on."* And on the band: *"if a larger cell has 1/2
its body in the graded area it is to be ok, but anything more than 1/2 it needs to be
split up into smaller cells"* — accepted with the scaling below, and *"I'm fine with band
5 not changing the sizes of a 12mm lattice."* The widening solid *"couldn't be the ONLY
thing changing."*

**The outline** is the shader's band of one width (`solidBandMM`, `rimParams.w`),
drawn as a field over everything, shape grade on only. **Nothing in the bake is solid
any more**: a finest cell the outline cuts is painted as a plain cell wherever any of its
extent lies inside the outline (`edge` in `paint`), its struts end inside the band, and
the band's inner face is the outline offset by its width — no 2 mm blocks (§8's
"stepping", his 7:00 PM image 1). `solidDepthMM` now carries only the bleed.

**The centre rule, scaled by size** (`centreOK` in `place`): a cell of size S is kept
only if its centre sits at least `band · (S − f)/(base − f)` from the outline; the finest
rung is never held back. Literal half-body would be one test for every size and let a
12 mm cell nearer the outline than a 2 mm one. On 12 → 6 → 2: band 5 moves nothing;
band 10 holds 12 mm cells to a nearest edge 4 mm in and 6 mm cells to 1 mm; band 13 to
7 and 2.2; band 20 to 14 and 5.8. DIAG `why=[…/band=n]` counts base slots the rule
split.

**The bleed** is zero under a 15 mm band and half the excess above it (his "20–30 mm"
rule); it used to be 0.44 × band, which is what he saw as the only thing moving.

Tests: `LatticeGradeToSolidBandTests` gains
`testTheCentreRuleGradesTheBandAndHalfABaseCellChangesNothing` (band 10 on 6 → 3 holds
6 mm cells to 8.5 mm texel middles, band 5 == band 0, no bleed at 10, 2.5 mm at 20); the
outline test asserts nothing solid in the bake and no 6 mm cell inside the band; the
curved-outline probes' "solid" is now a point within the band (`isSolid(cf, k, dOut:)`).

**Suite on `b95956d1`** (`swift test`, Debug, macOS, 114 min): **2435 tests, 31 skipped,
6 failing test cases** — the five known pre-existing ones (`AppModelTests` 3MF ×3,
`OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces`,
`OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology`) and
`LatticeCurvedOutlineBandProbe.testSweepEverySettingPermutation`, whose Skin rows measured
2.9 % "painted but clipped" against the 1 % bound set the day before: with nothing solid
in the bake, the finest cells run up to the outline and the 0.9 mm skin's strip beyond
the 1.2 mm band counts as clipped — the shell's skin on screen, not empty space. Re-pinned
to 3.5 % for Skin rows (0.5 % elsewhere, measured 0.0); the sweep then passes with the
solid terminus a ring at **100 % on every row**, unpainted 0.0 %, drawn 97.5 %, band
1.9 % of the face.

## 10. 2026-09-15, 11:30 PM: "FOR THE LOVE OF GOD, FINISH THE OUTLINE"

His three points on the 19:24 build (grades 0/5/10/15/20 side by side):

**1. "There is no smooth, single outline … I don't want it to be an SDF like the rest of
the lattice."** What he saw was not the band. The thin bright strip at the edge IS the
1.2 mm band; the wide blue strip with holes beside it was the Rim & skin FINISH: it
fattens 1.6× and tints every strut within its reach of the boundary, and since §9 the
finest cells run right up to the outline, so their dressed struts read as one ragged
blue band. Now: no dressing at all on the stepped path wherever the band exists
(`rimParams.w > 0` — the band is the rim), and the band hit is reported as
`out.solid = 2` and shaded FLAT in the rim colour (`lsdf_albedo`: no printed-layer
banding). It is still the SDF band (its outer face is the prism wall, its inner face
the offset outline); a mesh ribbon was not needed for what was wrong.

**2. "Quilting all along the 2 mm cells … 0 should mean ZERO quilting."** Not the grade:
by core's measured law a 0.45 mm bead in a 2 mm octet cell is **26.5 %** dense with
half-millimetre windows (2.58 mm: 17 %, 3 mm: 13 %; probed with
`printabilityDensityFloor`), so the finest rung was a quilt before any band. New bound
`finestRungMaxDensity = 0.20`: a rung whose bead-wide strut is denser is not a rung. His
ladders become **12 → 6 → 3 and 10.31 → 5.16 → 2.58** (his "if there isn't space, the
2.58 one is ok"); the texel pitch 2.58; `LatticePerVoxelWidthTests` rungs
12.03 → 6.015 → 3.0075.

**3. "Use the quilting as a secondary means to extend the gradient … 0 = zero quilting,
5 should look like what 0 does now, 15 an extra band of quilted cells inwards."** With
(2) this is what the existing band thickening does: only the finest rung is raised, by
`1 − nearest/band`, so at 0 nothing is raised (open 3 mm cells straight into the band),
at 5 the finest cells within 5 mm ramp to the quilt against the outline, at 15 the ramp
runs 15 mm in while the centre rule also holds the larger cells back. No new rule.

**And a defect the probe caught on the way:** with the 2.58 mm pitch, the texel that
contains face 15's plane has its middle ABOVE the plane, so the slot against the face
owned no texel there and the outer 1.3 mm of that wall had no band and no cells
(`testTheSolidTerminusIsARingNotADottedLine`: 0 of 62 outline points painted). `paint`
now gives the face-plane texel to the slot against the face and tests its material just
inside the plane: 62/62 and 69/69 painted and solid.

## 11. 2026-09-16, 00:19: "DO SOMETHING DIFFERENT" — the outline is a mesh

His words: *"I'd prefer the outline be a singular beam bent around the entirety of the
face-prism outline; something inherently smooth — not something with definitive pixel
sizes! DO SOMETHING DIFFERENT!!!"* He was right that a field sampled from 1.67 mm voxels
can only ever be as smooth as its voxels: the band's outer face was the trilinear prism
wall, its inner face the trilinear outline distance, the struts ended ±0.3 mm around it
(the voxel-sampled region wall) and studded its face, and it existed only in painted
texels.

**`LatticeOutlineRibbon`** (new, pure): one beam of rectangular section — `solidBandMM`
wide in-plane, as deep as the wall at each outline vertex (the measured width field,
the region depth as fallback) — swept round each include face's outline polygon
(offset in by `inPlaneOffsetMM`, mitred corners clamped to 2×), as triangles with
position + normal in the depth-prepass layout; smooth per-vertex normals along the
sweep. Built by `LatticeSDFRenderer.buildOutlineRibbon` after every bake that hands out
a band (`outlineRibbon`, `outlineRibbonVersion`).

**Drawn by `MetalMeshView.encodeDepthPrepass`** with a second prepass pipeline
(`depth_vertex` + new `depth_fragment_flat`: no shell clip — the beam lies inside the
declared region on purpose — and a flat albedo, `DUniforms.tint`, in the rim colour so
the shade pass lights it like lattice material). Drawn whenever the lattice is, shell or
no shell, so the lattice-only view keeps it. Depth-tested against the lattice's G-buffer
like everything else.

**The march no longer draws any band.** The struts are clipped half a band inside the
outline (`dRegion = max(dRegion, 0.5·rimParams.w − dOutV)`) so every strut ends inside
the beam. The bleed for large bands (half the excess over 15 mm) is now extra WIDTH of
the beam (`band = max(solidBandMM, bead) + bleed` in the bake; `solidBandMM` carries
it); `solidDepthMM` is no longer written.

**His point 2 — 0/5/10/15 indistinguishable:** coarser cells inside the band now
thicken a third of the way to the quilt at the outline, fading to nothing at the band's
inner edge (`coarseCellBandRaise = 0.35`), on top of the finest rung's full ramp and the
centre rule. So 5 mm shows as a thickened edge; 10 mm steps the 12 mm cells back 4 mm
with the thickening 10 mm deep; 15 mm 9 mm back; 20 mm widens the beam by 2.5 mm.

Tests: `LatticeOutlineRibbonTests` (4: the section, the in-plane offset, the depth
following the wall, nothing without a band); `LatticeSolidFillTests` pins the strut
clip; the band tests pin the bleed as width and the coarse cells' mild thickening.

**Suite on `4c4e275a`** (`swift test`, Debug, macOS, 104 min): **2439 tests, 31 skipped,
6 failing test cases** — the five known pre-existing ones and
`LatticeCurvedOutlineBandProbe.testSweepEverySettingPermutation`, whose Skin rows
measured 0.059 % of the face "unpainted" against a 0.05 % bound: points where a sharp
polygon corner cuts a texel between its corners and its middle, all within the 1.2 mm
band — inside the beam on screen. The probe now counts an unpainted point within the
band as the beam (it would still read as a hole outside it); the sweep then passes,
ring 100 % on every row, unpainted 0.0 %.

## 12. 2026-09-16 evening: "no quilting … a void between the solid and the lattice"

The outline accepted ("now that we finally have a good solid surrounding the lattice").
His 0/5/10/15/20/25 mm screenshots: no quilt anywhere, and at 25 mm a dark strip
between the widened beam and the lattice.

**Measured first** (probe on his mesh, deleted after): at band 5 the 3 mm cells within
3 mm of the outline carry activation 0.91–0.98 (the quilt), every texel painted; at band
25 every cell within 10 mm is raised (0.66–1.00), 100 % painted, 3 mm cells out to
10 mm, 6 mm from 8 mm. The bake was doing exactly what he asked. **The dark strip IS
the quilt**: the density colour ramp ran over the DRAWN span (widened to the quilt, 0.6),
so a raised 60 % cell sat at the ramp's deep end — a closed 3 mm cell with half-millimetre
windows drawn in the deepest hue reads as a slab, a void. At 5 mm the quilt is a 1.8 mm
fringe past the 1.2 mm beam, invisible at that depth of colour.

**Fix:** a new `colourSpan` uniform (appended last on both sides: xy = the STATED span,
z = 1) — the albedo's ramp reads it instead of `gradeParams`, so the grade's raise keeps
its neighbours' colour and shows as what it is: dense pale struts. For his point span
everything is one hue, and the quilt is the tight mesh he saw two days ago. Also: the
outline beam exists only when the shape grade is on (`solidBandMM` 0 otherwise).

His two requests read against the numbers: (1) "5 mm should have a small line of
quilted cells" — it does (0–3 mm, 1.8 mm visible past the beam), and each step widens it
(10: ~5 mm, 15: ~7, 25: ~10) while the centre rule steps the sizes back; (2) "from 25 mm
the solid should extend inwards to fill the empty area" — the beam already widens by half
the excess over 15 (6.2 mm at 25), and the "empty area" beyond it is the quilt, now
visible. If he wants the solid wider still, `bleed` in `octreeCellField` is one line.

**19:13, "There should be some quilting here. There isn't. Stop measuring and look at
the actual values from the app."** He was right that the CPU numbers were not the
picture. The march reads per-cell density only when `shadeParams.y` (`hasDemand`) is
set, and that flag came from `scene.demand != nil` — a stress/demand field. His project
has no optimisation, so the flag was 0 and every strut drew at the one uniform density
(`shadeParams.x`); the quilt the bake wrote never reached the screen on this project,
at any band, in any build since the octree. Now the flag follows the FIELD: on whenever
the cell field carries per-texel densities (`steppedCellMM` non-empty). Installed 19:15.
Lesson for the file: a baked value that does not show is a rendering gate, and the
gate to check first is the one that decides whether the shader reads the bake at all.

**19:17–19:22, on the 19:15 build.** The 25 mm grade: "Perfect" — quilt visible, and
the beam "overlapping itself at the bottom-left and top-right corners. That can never
happen." Then 15 and 5 mm wearing the 25 mm beam, and his rule: *"the growing solid
inwards is SDF — the outline stays the way it is, clean and thin."*

- **Corners:** the inner ring was a clamped bisector offset per vertex; at an acute
  corner, or where the outline has segments shorter than the offset swallows, the two
  strips crossed. `offsetRing` is now a true parallel offset: each inner corner is the
  intersection of its two offset edges, an edge whose offset copy runs backwards is
  eaten and its vertices collapse to the corner its neighbours make (decided on the
  RAW intersections — the tip of a 20° spike is 30 mm in), and a corner the region is
  too thin to hold takes the deepest point on the way. Test: a 20° spike with a 2 mm
  tip flat and a nicked square, at a 6 mm offset — no inner edge runs backwards and
  every inner vertex is ≥ 6 mm inside the polygon.
- **The stale beam:** `outlineRibbonVersion` restarted at 0 per layer, so after a
  settings change rebuilt the layer the view's remembered version matched and it kept
  the previous layer's buffer. A static serial now.
- **Thin beam + SDF bleed:** `solidBandMM` (the beam) is `max(2 beads, trim + ½ voxel)`
  always; cells keep clear of beam + bleed; for bands over 15 mm the bake writes
  `solidDepthMM = beam + bleed` on the band's texels and the march draws solid where the
  voxel's in-plane outline distance is under it (`bleedHit`, `out.solid = 2`, rim colour
  flat), clipped by the prism and the raw part. Under 15 mm nothing is written.

**19:30: "No, the rule was 25mm and up is when solid gets thicker."** The bleed
starts at a 25 mm band (`bleedStartsAtBandMM`), none below; the amount stays half of the
band over 15 (5 mm at 25 — what he called perfect — 7.5 at 30). 15 and 20 mm keep the
thin beam and no SDF solid. Test pins 10/20 = none, 25 = beam + 5 mm.

## 13. 2026-09-16, 19:42: the finish that came back, and the grade's own colour

**"I've selected 'no' finish … go back to the settings, the setting goes back to
'skin'. Can you confirm whether the setting is actually being set/saved?"** It was
saved as None and then OVERWRITTEN: `LatticeWizardModel.singleCellMembers`'s `didSet`
and the save path both rewrote `boundary` to `.fullSkin` whenever single-cell members
was on, because core only allows one cell across a member when a skin re-ties the
struts it severs (the caption even said "it has been set"). Now the setting keeps his
choice; the skin core needs is resolved for the JOB alone (`jobSkinResolved` answers
"diagrid" when single-cell is on and the finish is None or Rim), the wizard's sample
and `LatticeAutoPosture` gate the one-cell floor on the toggle alone, and the caption
says the run adds the skin and his choice is kept.

**"The purple colour is already part of the legend as interior fill … we require a new
colour specifically for the gradient — and it should be a gradient, itself … only when
the gradient is set and above 0mm."** Two things: (a) with his POINT span (lo == hi) the
colour ramp divided by `max(1e-4, 0)`, so any raised cell was the deep end — a point
span is now one lightness; (b) `LatticeStructureColour.grade` (teal) is a third
structure class: the shader ramps the interior hue toward it by the cell's raise above
the stated span (`gradeColor` uniform, appended last; `t = (rho − statedHi)/(drawnHi −
statedHi)`), so the tint IS the gradient — no raise, interior; the quilt against the
outline, full teal. The legend shows a "Grade to shape" row with a gradient swatch
(`LatticeLegendGroup.gradientFrom`) only when the shape grade is on and the band > 0.

## 14. 2026-09-17, 00:22: the legend and the tap

His three: the Rim & skin row vanished (it was omitted whenever the FINISH was None,
and his choice now persists as None — but the outline beam is on screen); the row
sentences should live behind an (i); a tapped green strut read "Interior fill"; and the
green "bled too far" at 5 mm.

- **Rim row** shows whenever there is boundary work on screen: a finish OR the shape
  grade's outline beam; its sentence now names the outline first.
- **(i)**: each row is name + an info button; the sentence appears under the name only
  while the (i) is on (`LatticeLegendPanel.infoOpen`).
- **The tint is SPATIAL now**, not the raise: the hit carries `grade = 1 − dOut/band`
  from the voxel's in-plane outline distance (`LSDFHit.grade`, `gradeColor.w` = the band
  in mm), and the albedo mixes the interior hue toward the grade colour by that. The
  colour stops exactly at the band's inner edge — a coarse cell that only pokes into the
  band is tinted only where it does — and it cannot bleed, because it no longer follows
  the raised density (which reached the whole of a 12 mm cell whose corner touched the
  band).
- **The tap** classifies by the same distances: on the beam (`outlineBeamMM`, one
  formula shared with the bake) ⇒ Rim & skin; inside the band ⇒ Grade to shape; else the
  dressing/interior test as before.
- **And a build that shipped with a dead shader for 18 minutes:** `lsdf_albedo` gained
  a parameter and a THIRD call site — in `LatticeSDFMetal.swift`'s own MSL, not in
  `UnifiedShading.swift` — was missed; the 00:47 install's lattice shader did not
  compile (the pipeline is built with `try?`, so nothing said so on screen).
  `UnifiedShadingTests.testTheShaderSourcesActuallyCompile` caught it; fixed and
  re-installed. The note at that call site says exactly this would happen.
- **01:10:** legend rows are name on ONE line, a one-line `brief` under it with the (i)
  at its end (`LatticeStructureClass.brief`: "The outline and any finish" / "Ordinary
  fill" / "Thickens toward the outline"), the full sentence under that while the (i)
  is on.
- **01:24 — the panel did not widen for the briefs.** The rows' column was a guessed
  140 pt, so "Thickens toward the outline ⓘ" (178 pt at 12 pt) and the 34 pt swatch
  overflowed it — the same failure as the 2026-08-20 cut-off, from the other side. Now
  `LatticeLegendPanel.rowsCol` is MEASURED: every class's name (15 pt, bold standing in
  for semibold) and brief + (i) (12 pt) set with CoreText, the widest taken, plus the
  swatch and a gap either side. Rows column 229 pt; overview 253 pt; overview with the
  stress block 414 pt (limit 620). `LatticeLegendColourTests` re-does the measurement
  and refuses to pass on the old guess.
- **03:08 — full package suite on `4d818f27`** (the legend widening): 2440 tests, 31
  skipped, 6 failing cases (11 assertions) in 1 h 43 min. Five are the known
  pre-existing ones (AppModelTests 3MF ×3, `OrganicSampleCubeTests.testThickerIsLive…`,
  `OrganicVariantCacheTests.testTheKeyIgnoresThickness…`). The SIXTH was new:
  `StrutLineWidthTests.testNoLatticeLineWidthSiteReadsAWallBead` counted 14 lattice
  line-width sites against a pinned 13 — the tap attribution's `outlineBeamMM(lineWidthMM:)`
  call in `WorkspacePlaceholder` (added with the legend/tap work at 00:47). Audited: it
  reads the STRUT bead, and must, because the bake sizes the outline beam from that same
  bead. Re-pinned 13 → 14 with the note; the 12 `StrutLineWidthTests` pass on the fix.
  (That rerun was the subset only; the full suite ran on `4d818f27`, before this
  test-only change.)

## 15. 17:49 — Default Grade goes through the octree bake; banners centre; Organic leaves the picker

His 17:31 report (Default Grade, Auto·Sim, Sim density, Rim, band 5): no gradient at
all, both walls on 10.31 mm (the front should be 12), no solid outline. The app's own
log at 17:30:43: `DIAG steppedCells GUARD algo='doubled' — preview draws the ladder`.
`latticePreviewSteppedCells` (and `…Stated`, and the renderer's deferred-bake guard)
were gated on `algorithm == "stepped"` ALONE, so Default Grade — core's "doubled" —
went round the whole per-region bake to the old periodic ladder, which has no
per-region base cell, no band and no outline beam. All three symptoms, one gate.

- **"doubled" now takes the same road as "stepped"** (`WorkspacePlaceholder.
  perRegionCellAlgorithms`); the renderer's deferred guard holds for both; the octree
  bake gained `dyadicSteps` — under Default Grade the ladder is halves only (a third is
  never taken; 9 → 4.5 at a 2.6 floor where Stepped goes 9 → 3). On his part both
  ladders are already halves (12 → 6 → 3, 10.31 → 5.16 → 2.58), so his picture should
  match Stepped's exactly. Tests: `LatticeGradeToSolidBandTests` +2 (the dyadic ladder
  bake; the routing pins), 10/10.
- **Banner placement** (his: "'rebuilding the lattice' should be in the centre … The
  only time it should be to the right should be when there is another chip meant to be
  in the middle"): the banners were pushed right by `secondRowSplit` whenever the mode
  chip was up, See Results or not. Now `seeResultsShown` / `topBannerShown` each step
  aside only when the other is on screen — See Results left, the banner right —
  otherwise both sit dead centre under the mode.
- **Organic Grade** removed from the Grade style picker (`cellTransitions` = Stepped,
  Default Grade); it stays the Organic lattice switch under the cell types, and the
  grade-style row is already replaced by the organic row while that is on.
- Installed 17:48:59. Not yet seen by him.

## 16. 18:52 — Stepped is ANY STEP; Default Grade stays halves; the cell origin is stored

His 17:58: Stepped and Default Grade drew the same picture (both of his ladders happen
to be halves, so "thirds allowed" changed nothing). His ruling after the research:
"To me that's what stepped means: taking ANY step" and "Go - exclude 10 and 11, no solid
strips."

- **The menu** (`LatticePreviewOccupancy.steppedSizeMenu`): every k·(base/n) for n ≤ 6
  whose 1/n tile is at or above the floor AND prints open (the dyadic finest rung's
  bead-density bound). On a 12 mm base at a 0.45 bead: 12, 9.6, 9, 8, 7.2, 6, 4.8, 4,
  3, 2.4 (fifths print open at 2.4 mm, just under the 20 % ceiling; sixths at 2.0 do
  not, which is exactly what drops 10 and 11). Depth-clean by construction: a k/n cell
  at the face leaves (n−k)/n behind it, which the 1/n tiles fill — no solid strip.
- **The packer** (`packSlot` in `LatticeOctreeBake`): a failed base slot is packed, not
  halved — sizes largest first, each at any multiple of its own tile inside the slot
  (a 9 sits at 0 or 3 in a 12), depth from the face inward, a `taken` mask so nothing
  overlaps; then a fill pass paints the finest tile on its nested grid into any texel
  no cell claimed. Default Grade (`dyadicSteps`) never enters it: nested halves.
- **The cell origin is STORED, per texel, all three axes** (`LatticeCellField.
  steppedOrigin`): the old `axis + fraction` carried one shift along the face normal
  and derived the in-plane origin from the size — a 9 on a 3 grid would have drawn in
  the wrong place. The cell texture is now `rgba32Float`; `.a` packs axis + three 7-bit
  fractions (`LatticeSDFRenderer.packCellOrigin`, one encoder; `lsdf_cell_frame_at`
  the one decoder; ≤ 1/256 cell error, 47 µm at 12 mm). The old scalar phase stays
  written for the non-octree path and its tests.
- Tests: `LatticeGradeToSolidBandTests` 10/10 (the 9-base case is now 9, 6, 4.5, 3 vs
  9, 4.5), `LatticePerVoxelWidthTests` 3/3 (menu pins: 9.02 and 8.02 present, 10.03 /
  11.03 / 2.0 absent), `LatticePhaseChannelReadbackProbe` rewritten 3/3, stepped phase
  / solid fill / shader-compile suites green. Installed 18:52:18. Not yet seen by him.
- **What to look for**: Stepped should now show 9.6 / 9 / 8 / 7.2 / 6 … cells between
  the 12 mm cells and the outline, a staircase, with seams where families meet;
  Default Grade 12 / 6 / 3 nested. The 10.31 wall: 10.31, 7.73, 6.87, 5.16, 3.44, 2.58.
- **Full suite on `ebc7aa19` (in progress) found one of mine:**
  `LatticeThreeAlgorithmsDrawTests.testAllThreeAlgorithmsDraw` — "doubled draws
  nothing". §15 had widened the renderer's deferred-bake guard to doubled, so a doubled
  scene with NO per-region cells (that test renders one) hid its layer instead of
  falling through to the dyadic ladder. The ladder IS doubled at a coarser plan, so the
  guard is stepped's alone again; the routing pin in `LatticeGradeToSolidBandTests`
  says so.
- **Full suite on `ebc7aa19`: 2443 tests, 31 skipped, 8 failing cases** (1 h 56 min).
  Five known (AppModelTests 3MF ×3, OrganicSampleCubeTests thicker-is-live,
  OrganicVariantCacheTests key). Three mine, fixed in the commit after it:
  `LatticeThreeAlgorithmsDrawTests` ×2 (doubled with no cells hid itself — the guard is
  stepped's alone again) and `SmoothingPageRound2Tests.testWhileAPageIsUp…` (the
  page-chrome audit reads `!fullScreenPageUp` on the chip's own line; spelled out).
  The three classes rerun green (34 tests). A full suite runs again on the fix.
- **22:45 — full suite on `c468d87a`: 2443 tests, 31 skipped, 5 failing cases**
  (1 h 51 min) — exactly the five known pre-existing ones (AppModelTests 3MF ×3,
  `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces`,
  `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology`).
  Nothing of this branch's work fails. Installed build = this commit (20:54:04).
  Core brief for the run + structural certification:
  `docs/handoffs/2026-09-17-core-brief-any-step-stepped-and-beam-certification.md`.

## 17. 2026-09-18 02:48 — the cell list goes to core; Stepped under Structural

Core's reply (PR #358, branch claude/raster-receipt-fields) accepted the brief and
handed the app four items. All four are done here; the keys are gated on core's
schema so nothing is sent to an older core.

- **The plan travels.** The octree bake records every placed cell
  (`LatticeCellField.steppedCells`, `OctreeBakeStats.cellsPlaced`); the renderer
  publishes them after each rebake (`onSteppedCellsBaked`, with the scene's regions);
  the view forwards (`onLatticeCellsBaked`); the workspace stores the WIRE form on the
  project (`ProjectModel.latticePreviewSteppedCells`, transient, never persisted);
  both run paths attach it to `LatticeSpec.steppedCells`; both runners write
  `lattice.stepped_cells` through ONE encoder (`LatticeSteppedCellWire.blockValue`)
  — only for `algorithm: "stepped"`, only a non-empty plan, only when
  `TopOptKit.steppedCellsWired` (a whole-job probe with one cell). Region index →
  `region_id` = 1-based position among the INCLUDE regions in emission order
  (`LatticeSteppedCellWire.wire`). Origins are the bake's model-space minimum corners.
- **Structural keys** in `gradingDictionary` for stepped: `intent` always (core keys
  the refusal on intent != aesthetic, unstated included); `structural_certification:
  "beam_network"` under Structural when `steppedStructuralCertificationWired`;
  `min_cell_mm` = the printability floor (4 beads) under Structural when the grading
  schema accepts the key.
- **The menu under Structural** is bounded by the printability floor ALONE
  (`steppedSizeMenu(printsOpenBound: false)`, `octreeCellField(finestPrintsOpen:)`,
  `scene.stageMode != .structural`): sixths of a 12 at 2.0 mm, and with them 10.
- **Bridge gate** untouched: the app now sends the certificate key whenever core
  can take it, so core never sees stepped + structural without it.
- Tests: `LatticeSteppedCellListTests` (wire numbering, block gating through the real
  builder, the structural menu) 3/3; `LatticeGradeToSolidBandTests` +1 (recorded cells
  = the picture, no overlaps) 11/11. Both probes print FALSE on this worktree's core,
  as expected until PR #358 is merged and the xcframework rebuilt.
- Open with core (in the reply): packSlot places a multi-family size on its COARSEST
  family's grid only, so their looser acceptance is a superset; the exact `min_cell_mm`
  key name; the "inside material" check is not needed (the bake tests occupancy at
  placement); their reading of "required" is the intended one.
- **04:37 — full suite on `2ffa46a6`: 2447 tests, 31 skipped, 5 failing cases**
  (1 h 48 min) — exactly the five known pre-existing ones (AppModelTests 3MF ×3,
  OrganicSampleCubeTests thicker-is-live, OrganicVariantCacheTests key). Nothing of
  this branch's work fails. Installed build = this commit (02:47:50).
- **Core reply 2 (2026-09-18):** the structural floor's key is `stepped_min_tile_mm`
  (new; `min_cell_mm` never existed as a key — it was a C++ parameter name; `cell_min_mm`
  is the swept window). Switched, pinned on the source in `LatticeSteppedCellListTests`.
  Core keeps multi-family acceptance loose (a superset of packSlot's coarsest-family
  placement); B and C agreed; their un-subdivided margin control still solving. PR #358
  also carries the organic bead calibration (+44 % organic mass), certified-density
  fixes (margins ~43 % lower on the M2 stand) and the dual contourer — the maintainer's
  merge call, and worth a look before the xcframework rebuild flips the probes.
- **Core correction (2026-09-18):** the "un-subdivided control still solving, worse
  conditioned" report is RETRACTED — the control never started (a `pgrep -f` wait loop
  matched its own command line; see memory `pgrep-waiter-self-matches`). What stands,
  measured independently: the weld defect (4,270 welded junctions as emitted vs 14,202
  subdivided, longest member 28.94 mm against an 0.817 mm reach, from `lslt_probe
  --seams` on a real spans file) and the subdivided arm (CERTIFIED, margin 210.1, p99
  0.1145 MPa, 61,401 members, reproduced twice). The control's margin is still owed.
- **Core reply 3 (2026-09-18) — the paired margin landed.** Same job, same binary but
  the subdivision, both CERTIFIED: un-subdivided 4,270 welded nodes / 784 ends on
  nothing / 15,650 members / p99 0.1691 MPa / margin 146.3; subdivided 14,202 / 442 /
  61,401 / 0.1145 / 210.1. The old behaviour was PESSIMISTIC: fusing the seams raises
  the margin +43.6 % and drops p99 32 %. No part was certified that should not have
  been; margins were understated by about a third, so re-runs after this lands report
  HIGHER margins than their earlier records (the receipt's [seams] line says why).
  Solve times comparable (45.5 s vs 41.5 s). Core at `32ecc22a` on
  claude/raster-receipt-fields, 130/130 Release, parses exactly what `d932ec71` emits.
  Nothing further needed from the app.

## 18. 2026-09-18 14:20 — one-line captions with an (i); only the Octet truss offered

His three final items, the first two here (the third is the core parity brief,
`docs/handoffs/2026-09-18-core-brief-preview-parity.md`).

- **Captions** (`LatticeSetupWizard.captionLine`): every lattice-stage caption is ONE
  line that never wraps (lineLimit 1, min scale 0.85) with the (i) at its end opening
  the former paragraph — Simulate Stresses, Grade the lattice, Grade type, Grade
  style, band + steps note, single-cell members, density sim note, per-region gap,
  Allow quilt, Covered/Skin facts, Auto cell note, subfloor retention. A caption with
  nothing more to say has no (i). Pinned by `LatticeWizardOneLineCaptionTests`.
- **Types**: `offeredTypeIDs = ["octet"]`; the other six chips stay visible, greyed and
  inert (the preview's density law, quilt ceiling and octree bake are octet-measured).
- Installed 14:20. Not yet seen by him.
- **Parity rulings applied app-side (2026-09-18 14:50):** each `stepped_cells` entry carries
  `rho` (the cell's densest texel's drawn ρ; ruling C); the list is sent for "doubled" too
  (ruling A); `organic_scale` is no longer written for part jobs (ruling F); the single-cell
  caption says the run adds a skin (ruling E). Brief rewritten in full:
  `docs/handoffs/2026-09-18-core-brief-preview-parity.md`.
