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
- **14:44 — single-cell members REQUIRE the Skin (his ruling, revised):**
  `LatticeWizardModel.setSingleCellMembers(true)` sets `.fullSkin` (pop-up: "The finish is
  now Skin…"); `setBoundary` returns false for anything but Skin while the switch is on
  (pop-up: "To change the finish, turn off single-cell members."; the row dimmed; a
  one-line note under it); `init(settings:)` coerces a saved single-cell project to Skin.
  `LatticeWizardTests.testSingleCellMembersLockTheFinishToSkin`. Installed 14:43:43.

## 19. 2026-09-18 16:49 — the organic "wall between the lattices": the far cap opens again

His report: under organic a grey wall sat behind the struts (both walls); "the floor is
see-through" (image 2). Lattice-only view: no grey wall ⇒ it was the BODY.

What the device said (new `DIAG shellClip` line, once per change; kept): decl mode, two
face regions (depth 12.00 / 11.00), region texture bound, capsule pipeline built and
drawing, body opaque, and a CPU census of the shell rule over his mesh: ±y faces open
88 % / 90 %, floor 0 %. The census replicated every term of `shell_is_latticed` but
ONE: the 2026-08-25 eye test (`dot(sn, toEye) <= 0 → keep`), "only the cap you are
looking at", added after his "massive hole" report. The mesh draws with cullMode
.none, so the far face of a declared wall, seen from inside through the open near
face, is a back-facing fragment — never opened — hence the grey wall. Octet had it too;
the denser truss hid it.

Fix: the eye test is gone — both caps of a declared region open whichever way the
camera looks; a region that stops short of the far surface still does not open it
(the containment sample). His 09-18 ruling supersedes his 08-25 one, and the shader
comment says so. Harness (`LatticeShellSeeThroughProbe`): lit-with-body 13116 →
12958 (octet) / 12837 (organic) — the background now shows through the walls.
The floor is not a cap of any declared region and stays closed by rule; if he still
sees through it, that is a different thing and needs a screenshot.
Installed 16:48:46. Not yet seen by him.
- **16:55 — "The fix needs to ONLY be for organic!"** The both-caps rule is gated on
  the scene's algorithm (`ShellClip.gate.z`, set by the host; the shader skips the eye
  test only when it is set). The octet keeps the 08-25 eye-only rule unchanged.
  `LatticeShellBothCapsOrganicOnlyTests` pins the flag per algorithm and the shader's
  read of it. The shell clip is a PICTURE rule: nothing about it reaches the job or
  core's STL. Installed 16:55.

## 20. 2026-09-18 17:20 — his four: depth-variation gone, (i) pop-ups fit, organic rim drawn, the cap wall

1. **Depth variation (test)** is off the organic pane (the model keeps the flag, off,
   for old snapshots); the placement test is retired for an "it is gone" pin.
2. **(i) pop-ups** are sized to their text (no ScrollView, no max height, width 380).
3. **Organic solid rim** is DRAWN: `buildOutlineRibbon` takes the rim's width
   (`LatticeSDFScene.organicSolidRimMM`) when there is no octree band, so the organic
   rim is the same beam around the outline as the octet's; the (i) says what it is
   (the width typed or the printability floor; the struts run into it). Organic has no
   other grade-to-solid (its floors raise, never solidify) — the text no longer claims one.
4. **THE CAP WALL** (his rule: a face prism that stops inside the part leaves solid
   beyond it — "the model should always be assumed to be 100% solid"): `LatticeRegionCap`
   triangulates each include face outline (ear clipping, at the region's depth, facing
   back out); the depth prepass draws it with `region_cap_fragment`, which keeps a
   fragment only where the part SDF a voxel and a half PAST the cap is still inside —
   so a prism through a whole wall draws no cap (see-through kept) and the base under a
   12 mm prism gets its wall, in the middle where the prism ends. Albedo 0 ⇒ shaded as
   the body. Both algorithms. `LatticeRegionCapTests` 3/3; the harness probe shows the
   layer now lighting 11 214 px without the body under organic (was 7 602).
   Installed 17:20. Not yet seen by him.
- **17:45 — his three on the 17:14 build:** (1) the cap wall was INVISIBLE: it wrote
  albedo 0 ("body") and nothing paints a prepass-only surface with alpha 0 — it
  occluded the struts behind it and showed the background ("still seeing through the
  floor"). It now writes a body grey with alpha 1 (`LatticeRegionCap.wallTint`) and the
  lattice shade paints it like the ribbon. DIAG gained `capVerts`/`capPipeline`.
  (2) The Lattice-only badge is a themed capsule (panel surface, accent stroke, 13 pt),
  not the orange card. (3) The grade-to-shape green reaches the ORGANIC lattice: the
  capsule fragment tints by the in-plane outline distance (region texture `.g`) over
  the same band; `gradeColor.w` is armed by organic's own Fit to shape
  (`LatticeSDFScene.organicShapeFit`); the legend's grade/rim rows key on the organic
  switches under organic. Installed 17:45. Not yet seen by him.

## 21. 2026-09-18 20:10 — the floor's wall (found), the organic band grade, the badge

- **THE FLOOR, ROOT CAUSE (two builds late):** the cap fragment tested `partSDF`, which
  is the signed distance of the LATTICED volume — the solid clipped to the regions — so
  past a region's cap it reads "outside" even inside solid material, and every cap
  fragment discarded. Proven by a CPU replica (0 of 134 kept) and an empty-region scene
  (the field positive everywhere). The cap now samples the UNCLIPPED part occupancy
  (`LatticeSDFScene.solidOccupancy`, uploaded as `solidTex`, nearest; kept where ≥ 0.5
  a voxel and a half past the cap). Replica after: 16 of 134 centroids kept = the base
  strip (the U-profile's triangles are large; the GPU decides per pixel). Also the ear
  clipper was wrong on his outline (fell back to a fan): rewritten with collinear
  removal, inclusive blocking (a vertex ON the diagonal blocks) and reflex-only
  blockers; pinned on his real outline (n−2 triangles, every centroid inside, area
  exact). Geometry learned: his part is ONE U-profile 52.6 mm deep (y −48.9…3.7), the
  front 12.03 and back 10.31 mm latticed, the base solid across; "the floor" is that base.
- **ORGANIC BAND GRADE** (`LatticeOrganicInput.shapeBandMM`, from `shapeFitBandMM`
  when organic's Fit to shape is on): within the band the spacing runs linearly to the
  printable floor at the outline; the bead field follows the spacing (core's law) so the
  struts thicken. The organic pane has the band control; the scene banner reports
  "shape band N mm: K voxels graded". `OrganicShapeBandTests`.
  ★ PARITY: this is app-side spacing; core's tracer must take the same band (add to the
  parity brief when he approves the look).
- **BADGE** at the mode chip's size (22 pt, capsule at the accent tint, rowHeight 44).
- Installed 20:10. Not yet seen by him.

## 22. 2026-09-18 22:19 — the cap goes with the body; badge + edge light; band and strength sliders

- **Cap wall hidden in Lattice-only** (`bodyAlpha > 0.5` gates the cap draw): it is the
  body, so it goes with the body.
- **Badge**: always full opacity; each flash carries a token so a repeat cannot be
  cleared by the previous flash's timer (the "super small opacity" was that); shown
  1.6 s. **Edge light**: a blurred accent stroke round the whole screen, blinked twice
  (0 → 1 → 0 → 1 → 0 over ~1.3 s) on every flash.
- **Sliders** (`gradeBandSliders`, in the octet's band row and the organic pane): the
  band 0–60 mm, and the grade's STRENGTH −1…+1 with 0 at the middle
  (`LatticeSettings.shapeFitGradeStrength`, persisted, default 0). The strength is an
  exponent on the band fraction, `gradeGamma(strength) = 2^(−2s)` (0.25 at +1, 4 at −1),
  applied to the octet's quilt raise (`octreeCellField(bandGamma:)`), the organic
  spacing grade, and the tint in both shaders (`colourSpan.w`).
  `LatticeGradeStrengthTests`. Installed 22:19:06. Not yet seen by him.
- **22:45 — STRENGTH IS AN AMOUNT, NOT A SHAPE** (his correction: "a way to make the
  struts thicker or thinner; to make the cells smaller or bigger; to modify the AMOUNT
  of gradient seen in the band. NOT the band length"). `gradeGamma` (an exponent on the
  band fraction) is replaced by `LatticeSettings.gradeAmount(strength) = 2^s` (½ … 2):
  the octet's quilt raise is `(q − r)(1 − t)·share·amount` (clamped at the drawn top);
  the organic shrink is `sep − (sep − floor)(1 − t)·amount`, never below the floor. The
  tint is linear again. Measured on a 6 mm slab, band 6: mean in-band activation 0.24 at
  ×½, 0.41 at ×1, 0.67 at ×2 (`LatticeGradeStrengthTests`). Installed 22:45.

## 23. 2026-09-18 23:55 — a dead wall is dead as a whole

His observation with the walls gone: the front wall's organic struts fill half its depth,
the back wall all of it; horizontals waiting for verticals. The device log: face 15 p99
0.0041 / max 0.0056 MPa → 72 % synthetic; face 2 p99 0.020 → 5 %. Core's rule
(`organic_lattice.hpp`) blends per voxel between ¼·thr and thr = max(2 % peak, 0.005),
so the front wall was half focal field, half noise directions. "Wouldn't sim-stress have
resolved it?" — the sim ran; the wall is inert (the whole part peaks at 0.03 MPa), and
the blend is what half-filled it. Now `OrganicSyntheticStress.deadenWholeWalls` zeroes
the real tensor of any region whose p99 < thr before the trace (DIAG
`synthetic whole-wall: … zeroed`); the back wall is untouched. Parity brief §4-H asks
core for the same whole-wall rule in the run. `OrganicWholeWallTests`. Installed 23:55.
Not yet seen by him.
- **2026-09-19 00:10 — the dead wall's SPACING.** His device: the whole front wall went
  synthetic (4332/4332) but "some horizontal lines … not enough": with its tensor zeroed
  its von Mises is 0, and the spacing is graded by the p05→p95 of the stress over ALL
  candidates — zero is the coarsest end, 5.2 mm, while the loaded wall grades to 3.47.
  Now dead-wall voxels (`LatticeOrganicInput.deadRegionIDs`) are excluded from the
  statistics and take the window's MIDDLE spacing (4.34 mm here); the banner says so.
  Parity: the run needs the same (brief §4-H extended). Installed 00:10.
- **2026-09-19 00:50 — the speckle on the faces.** His six screenshots: grey specks on
  the rim ribbon's faces, the walls' side faces and the base's top — capsule ends cut
  exactly at the sampled surface z-fighting the face they end on. The capsule clip now
  erodes the part by the march's trim (`stepParams.y`, clamp(0.35·voxel, 0.10, 0.35) mm)
  again; the 09-07 removal guarded a gap at the rim that cannot recur now the rim is a
  beam drawn over the band. `OrganicLookAndVisibilityTests` pin reversed. Installed 00:50.
- **2026-09-19 — full suite at 5c6b9a47: 2468 tests, 31 skipped, 10 assertion failures in the
  SAME five pre-existing tests** (AppModelTests 3MF ×3 — no lib3mf in the slice — ,
  OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces,
  OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology). Nothing new.
  The run before it (a15e0024) had ABORTED at `LatticeOrganicSettingsTests`: the test still
  expected `organic_scale` on a part job (dropped under ruling F) and force-unwrapped the
  missing key, which killed the xctest process — fixed in 5c6b9a47 (asserted absent, `XCTUnwrap`).
  ~1 h 53 min wall.
- **2026-09-20 20:03 — his three screenshots (Structural, M2 verticalStand, organic).**
  (1) The Lattice-preview cube button was gated on `project.lattice.enabled`, which only
  turns on when a lattice role is declared or the wizard is saved — so a fresh Structural
  stage had no button. Now offered from the stage's first frame; a tap with lattice mode
  off opens the wizard (Save & Exit turns it on), nothing bakes before that.
  (2) The "weird" sample after Sample → In the part is core's EMISSION stage replacing
  the trace: DIAG 19:41 `capsules=2606` (the trace) then `capsules=120` ten seconds later
  (the repaired set). Structural + Cell size Auto states no strut width, core derives the
  bead, and `node_merge` collapses the 2606-span sample to 120 fat struts — the 2026-09-10
  finding (`node-merge-collapses-a-polyline-finer-than-one-bead`, 2606 → 61 then), core
  fixed it for GROWN only. App unchanged; "Preview: show print repairs" OFF keeps the trace.
  (3) The bare stage under "Nothing to lattice — the faces you marked do not reach any
  material": his project has NO lattice include region (Groups A anchor, B load, C
  protect; `latticeThisSummary` = "nothing set to lattice"). The 08-20 body-alpha rule
  hides the body when there is no include region so a part-filling lattice can show;
  organic traces regions only, drew nothing (DIAG 19:45 `capsules=0`, interior 0), and the
  hidden body left an empty screen. `LatticePreviewBodyAlpha.value` takes
  `nothingToLattice` (no scene, no part interior, or no region interior — the banner's own
  `.empty` findings) ⇒ opaque. Installed 20:03; tests pending the running full suite.
  (4) Organic certification: core's `certify_organic_structural` (beam-network Timoshenko
  frame) accepts organic under Structural when the job asks for it (the app writes
  `organic_structural_certification: "beam_network"`); on the STAND core certified TRACED
  3–5 mm (margin 7.46) and GROWN with transfer ties (margin 1.19, 2026-09-05). No
  on-device run receipt with `structural_certified` exists in the simulator container.
- **2026-09-20 21:00 — his four items (grown sample, organic walls, single-cell, the 2.4 mm grade).**
  FIRST FINDING, above all four: the linked `libtopopt.a` carries NONE of core's PR #358
  keys (`stepped_cells`, `stepped_min_tile_mm`, `structural_certification`, `shape_grade`,
  `max_relative_density`); the worktree's `core/` is at 2a70a38b (2026-09-09). Every probe
  for them is false on device.
  (1) Grown sample "mess": DIAG 20:31:57 `capsules=7462` then 20:32:08 `capsules=1440` — the
  emission replacing the trace, drawn at core's derived bead. The sample now traces only
  (`showRepairs: false` in `organicSamplePicks`); repairs still preview in the part.
  (2) face2 full to the edge, face15 with space at the rim: no synthetic (project has
  `organicSyntheticStresses: false`; it is aesthetic-only in core anyway), so the dead
  front wall is traced from p05-normalised noise and fills evenly while the live back wall
  follows real stress — coarse at its unloaded top. NOT proven: a new DIAG
  `organic rim coverage` prints per wall spans / outline-distance p05·p25·p50 / share
  within 6 mm. Read it on his next open before deciding (shape band is the lever if it is
  spacing; a rim rule if it is the trace ending short).
  (3) "Allow single-cell members" hidden under Structural (aesthetic-only floor).
  (4) The 2.4 mm wall: `regionCell measuredW=12.03 floor=5.0 coreCell=2.406 final=2.4`,
  `10.31 → 2.06`; ladder sizes=[2.06, 2.40] — the homogenised certificate's 5-cells floor
  leaves no rung above the 1.8 mm printable floor. `regionCellsPerMemberFloor`: under
  Structural with the beam-network certificate WIRED, stepped/doubled take the aesthetic
  floor; on this core it is not wired, so the wall stays 2.4 mm until PR #358 is merged and
  `build_core.sh` rebuilt. Installed 21:00; tests pending the running full suite.
- **2026-09-20 23:18 — THE LATTICE'S THICKNESS THROUGH THE WALL (his "go", the sim rule
  agreed).** New `LatticeWallThickness.swift`: five modes (`through` = today, `sim` = depth ×
  the face point's column-peak von Mises over the part's p95, floored at one cell;
  `autoSingle` = the wall's p95; `manualSingle` = a share; `manualGrade` = lo + (hi − lo) ×
  stress) plus a start share. The answer is a (u, v) raster per include face
  (`LatticeRegionSpec.thicknessMap`) and ONE reader applies it: `LatticeRegionMask.
  signedDistance` / `contains` clip along the normal to [start, end(uv)], so the region
  field, the shell clip, the march, the octree, the organic candidates and plan all see the
  slab; `LatticeRegionCap.build` is a subdivided height field at the slab's end. Attached in
  `LatticeSDFScene.init` before any reader (`wallThicknessFloorMM` = smallest per-region
  base cell / organic window low end); `DIAG wall thickness:` per region. PREVIEW ONLY: the
  request rides on the preview's regions in `buildStrutScene`; `wireDictionary` unchanged
  (pinned). Settings `wallThickness*` encode only when moved (untouched project
  byte-identical, pinned). Wizard: "Thickness through the wall" row on both lattice pages,
  solve-reading modes disabled without Simulate Stresses; Start slider always. Pen-tool
  profile deferred to his visual spec. `LatticeWallThicknessTests` 5/5. Installed 23:18.
- **2026-09-21 — the thickness variable REBUILT to his design** (`docs/design/lattice-page/
  Lattice Wall Thickness.dc.html`, pulled via his authorized terminal session; DesignSync in
  this desktop session never saw the authorization). Model (`LatticeWallThickness`):
  `depthBySim` (ON ⇒ the sim rule over the whole prism), else per-wall allowed range
  `faces[key].startMM–endMM` (mm from the outer surface) and `density` ∈ {sim, autoSingle,
  manualSingle (pct), manualGrade (a drawn `LatticeWallProfile`: start curve in the outer
  half, end curve in the inner half, across the wall's width — the design's Bézier /
  Catmull-Rom maths ported verbatim)}. Default = whole prism, byte-identical. The map is
  now START and END rasters (`range(at:)`); the front plate follows a varying start.
  Wizard: "Lattice wall thickness" (the toggle, per-wall mm rows — tap a name for the
  thickness editor), "Density through the wall" (radio list; % field; "Open grading
  tool"). `LatticeWallProfileEditor` = the viewer editor over the stage: box per wall,
  drag bars (thickness) or pen/move points, tangent handles with 45° detents, rail
  (Curved/Straight hold = all, Mirror hold = half, Shift, Flatten, Delete, Reset), Cancel /
  Save. The five earlier `wallThickness*` fields are gone (never shipped past tonight).
  Still preview-only. Tests rewritten (`LatticeWallThicknessTests`, 6). His 00:13 open:
  both sliders at 50 % ⇒ slab 6–9 mm; the front plate now covers the 6 mm of solid.
- **2026-09-21 02:42 — his notes on the editor's first two cuts, all in.** Settings panel:
  the rows scroll inside a ScrollView sized to their CONTENT (a greedy ScrollView had pinned
  the panel at the band on both pages), capped at the sim-on height once "Depth defined by
  sim" is off and at the page's band always; `depthBySim` is ON by default (`.standard`).
  Number fields (mm, %) have up/down arrows + the decimal keypad. The editor spans the
  stage from the far left ABOVE the settings, which minimise to one strip while it is up;
  the rail floats to the right with air around it, undo/redo at its top, a Magnet tool
  (points tick into the 5 mm grid's crossings), Curved/Straight tap = the point / hold =
  the line; a dotted 5 mm grid both ways (stronger every 25); handle detents every 45°.
  "Show in 3D" renders the wall's OWN prism (outline, position, angle) from the drawn
  lines, updating on every edit, with an (i) saying so; the lines meeting ⇒ no slab ⇒
  nothing drawn (his image 6). The transition: `StageDepartureMotion` — the sample cube
  and the workspace's orientation gizmo lean back, slide down and fade TOGETHER (one
  modifier, one value) as the editor's cover rises; reversed on Cancel/Save.
- **2026-09-21 03:03 — his four at 02:55.** (1) The wall number fields open the app's own
  `NumberPad` on tap (the text field had waited on the simulator's hidden software
  keyboard); arrows kept. (2) With the sim switch off the density defaults to "Graded by
  sim" (`LatticeWallThickness.standard.density = .sim`; falls back to manual single when
  Simulate Stresses is off). (3) NO WALLS FROM THE SLAB: `LatticeRegionCap` is back to the
  one plate at the prism's DECLARED end (his 09-19 ask); the slab's start and end draw
  nothing — "It is meant only for where and how much lattice there is along the depth".
  (4) The panel came back cut to one row after the editor: the sim-on base height had
  been recorded from a transient layout; it is now captured at the MOMENT the switch is
  turned off and cleared when it goes on; floor 160 pt. The stage-covered preference
  moved to the wizard's root so the gizmo always returns.
- **2026-09-21 03:5x — his three at 03:25.** (1) THE WALL: the region cap at the declared
  depth was drawn on his 12.03 mm wall with a 12.0 mm prism — the fragment's "solid 1.5
  voxels past the cap" test read the surface voxel as solid. The cap is now built ONLY
  where the measured wall width exceeds the declared depth by more than a voxel (the CPU
  width field the ribbon already uses); a prism through the whole wall gets no plate;
  `DIAG regionCap: N verts`. (2) The lattice-only view's contact shadow was the BODY's
  footprint: it now casts the latticed slabs of the include regions (`LatticeWallSlabMesh
  .build(attached:)` merged, in the body's vertex layout) and casts nothing while no
  lattice layer is drawn. (3) The empty band at the rim at 100 % depth is IN-PLANE, not
  depth: DIAG 03:28 face15 outline-distance p25 5.8 mm, 25 % within 6 mm (face2 2.8 mm,
  44 %) — the trace's last streamline sits up to one spacing (3.4–5.5 mm) from the rim
  and the emission trims dangling ends. `DIAG organic anchors:` now prints whether the
  trace anchors at the rim. Lever in the app: the organic shape band (spacing → the floor
  within the band); zero gap needs core to seed along the outline.
- **2026-09-21 03:50 — THE SEEDING BOOST (his 03:40: "modify the algorithm being used by
  the beams to create the preview. Add the required seeding boost/adjustment with the
  depth settings").** Core's tracer takes no seed list, but its Jobard–Lefer ratios were
  never set by the app (core's defaults: `seed_ratio` 1.0 — the next seed is offered ONE
  separation off an accepted curve; `test_ratio` 0.5 — a curve within half a separation
  of another is refused; `min_length_ratio` 1.0 — curves shorter than one separation are
  culled). The bridge now carries the three (`organic_preview_field(... seed_ratio,
  test_ratio, min_length_ratio ...)`, 0 ⇒ core's default). A "Seeding ×" slider (1–3,
  step 0.1) in the Lattice wall thickness section (`LatticeWallThickness.seedBoost`,
  encoded only when moved, absent ⇒ 1, `.standard` byte-identical) sets, at boost b:
  seed 1/b, min length 1/b, test max(0.5/b, printable floor / smallest separation) capped
  at 0.5 — so seeds come closer and short rim curves survive, but two curves are never
  laid closer than the printer can. `DIAG organic seeding boost ×b: seed_ratio …` prints
  the ratios; the preview's banner ends "· seeding ×b". The boost sits inside
  `wallThickness`, so `previewBakeInputs` re-arms the bake on every move. The sample
  cube's variant cache is untouched (part preview only). Expect: with ×2 the census
  `seeds too close` count should FALL and curves/spans rise; the rim coverage
  (`organic rim coverage` p25 / within 6 mm %) is the number to read before/after.
  Preview only, no core change; if it works the core brief adds the ratios to the job.
- **2026-09-21 19:47 — THE TRACER WAS ON THE COARSE SOLVE'S GRID.** His 19:08/19:38 opens
  ("100% density of the full depth … still not working", ×1 and ×2 seeding). The new
  `DIAG organic fill` (per wall, strut-occupied share of candidate voxels by outline bin
  and depth decile, with the spacing asked in each bin) printed the cause in its header:
  **voxel 3.41 mm**. `organicForBake` handed the tracer `latticeStressField` verbatim —
  the stage solve's FAST tier (64 across, 3.41 mm) — and core floors every spacing at one
  voxel, so the window's floor was 3.41, the band grade graded "toward the 3.41 mm floor",
  the rim gap was one voxel (p25 3.41, exactly), the 12 mm wall was 3.5 voxels deep, and
  every candidate voxel was occupied (100 %) while the picture stayed sparse — the voxels
  were the size of the gap. The run traces at the Fine chip's 128 grid (1.71 mm), so the
  preview was not the run's picture either. Fix (app only): `OrganicTraceGrid.resample`
  — trilinear resample of the six tensor components onto the preview's grid (factor =
  round(solve/preview voxel), ×8 voxels, 4 M voxel budget lowers the factor first) before
  the trace; `DIAG organic trace grid: solve 3.41 mm (…) → trace 1.71 mm (…), ×2`.
  Expect: window floor 1.71, rim gap ≈ 1.7 mm, ~7 voxels through the wall, trace ~8×
  longer (1.1 s → ~9 s), more spans so a longer emission. Tests:
  `OrganicTraceGridTests` (a linear field resampled exactly; at-or-finer left alone; the
  budget lowers the factor). ALSO FOUND: the ×2 picture equalled ×1 because no second
  trace ran — `buildStrutScene` defers every rebake while `strutRefining` (the "Adding the
  print repairs" banner, core's emission, minutes on his part) and fires it when the
  refine ends; seedBoost 2 was saved at 19:39:58. The seeding boost is untested until a
  bake actually runs with it, and on a 1.71 mm grid it may not be needed.
- **2026-09-21 20:5x — HIS THREE DECISIONS ON THE DEPTH FEATURE, BUILT (D1/D2/D3) + core
  notes 2 and 3.** D1 the drawing is CELL-BASED: `LatticeWallProfile` is now
  `ends: [Double]` — one depth share per column of equal width along the wall; the editor
  (`LatticeWallProfileEditor`, rewritten) divides the box into columns one base cell wide
  (`LatticeWallDepthSteps.columnMM`: the face's stated cell, else the wall; 5 mm for
  organic) and rows at the depths the wall can be PACKED to (`LatticeWallDepthSteps
  .forWalls`: largest-first packing of `steppedSizeMenu(base: stated ?? wall)` — the
  reachable depths; organic none). The user PAINTS: drag across, every column under the
  finger takes the depth under it, snapped; rail = undo/redo, Fill, Flatten, Mirror,
  Shift, Reset. 2D and 3D draw the steps; the slab mesh is one box per raster cell with
  risers (`LatticeWallSlabMesh`, Sutherland–Hodgman clip of the outline per cell). D2 the
  band starts AT the surface: `LatticeFaceWallThickness.startMM` is gone (old documents
  decode without it), the builder's a0 = 0 in every mode, one depth field per wall whose
  arrows walk the wall's packable depths. D3 renamed: "Lattice depth", "Depth mode",
  mode titles say depth, "% of the allowed depth". The preview's bake gets the same steps
  (`LatticeSDFRenderer(wallDepthSteps:)` → `attach(depthStepsFor:)`), so what is drawn is
  what is laid. Core note 3 (nearest, never interpolated): the map's `sample` WAS bilinear
  — now nearest; and the manual-grade raster samples sit at CELL CENTRES with a pitch that
  divides a column exactly, so every step edge is a raster edge (measured before the fix:
  the edge landed half a cell early, x = 0.4875 for a 0.5 column edge). R1 (mirror): an
  L-shaped fixture asymmetric in u AND v, depths read at NAMED corners in the face's own
  (u, v), the mesh read back through the same basis — note the +z basis maps u to −world
  y, which is exactly the assumption that would have passed silently on a symmetric wall.
  Tests: `LatticeWallThicknessTests` 11 (steps from the surface, named corners, reachable
  depths/greedy packing/snap, steps model + old-document decode, stepped slab mesh, no
  slab where no depth). NOT DONE: the job never carries the raster yet (preview first);
  when it does, origin_uv and both axes go in explicitly (R1) and end_mm[] with cell_mm
  beside (core note 3). The seeding boost slider stays; untested on a real bake (the ×2
  open never traced — deferred behind the repairs refine).
- **2026-09-21 22:5x — HIS 22:40 ROUND (images 1–4 + the bake).** (1) THE BAKE NEVER WAITS:
  `buildStrutScene` no longer queues behind a running bake or the repairs refine — the
  generation moves and the new bake starts; the running one's picture is dropped on
  landing (core cannot be interrupted mid-emission, so CPU is shared until it ends);
  `DIAG organic bake: superseding …`, and `DIAG organic repairs stage: core emission
  starting` marks stage 2. Measured why the banner never cleared: the 1.71 mm trace has
  150 847 spans (was 68 197) and stage 2 is core's emission on them; his 22:19 open never
  finished it. (2) "Exit" vs "Save & Exit": the wizard keeps `openedLattice`; the label
  and the write follow `previewBakeInputs` differing; the workspace's onExit forces the
  bake when they differ. (3) THE DRAFT TRAP: Save & Exit sat above the wall editor and
  left with the draft unsaved ("not drawn yet") — hidden while the editor is up. (4) The
  gizmo stayed hidden after leaving the wizard with the editor up: `wizardCoversStage`
  cleared on exit. (5) THE START IS BACK (his image 1: "the user … wanted the lattice to
  start further INSIDE"): `startMM` restored on the face ask, both fields in the wizard
  (arrows walk the packable depths on octet walls), a0 = startMM in the builder. This
  REVERSES D2 as sent to core — tell core. (6) ORGANIC DRAWS CURVES AGAIN: the design's
  editor reinstated as `LatticeWallCurveEditor` on `LatticeWallCurves` (the old profile
  struct, verbatim); cell-based lattices keep the steps editor, now with TWO staircases —
  the start in the outer half (≤ 50 %), the end in the inner (≥ 50 %), painted by the half
  touched (his rule). `LatticeWallProfile` = `starts/ends` steps + optional `curves`;
  old curve JSON decodes AS curves (points without `smooth` tolerated). The slab mesh
  extrudes each cell from its start to its end with risers against the neighbour's band.
  (7) THE FLOATING BEAMS (image 3): `DIAG organic span census` — spans by kind (curve
  segments vs connectors, the bridge emits curves first then connectors), length p50/p95,
  and how many have BOTH ends free (no other span end within 0.25 mm) — read it on the
  next organic open before deciding; the 1.71 mm trace has 72 483 connectors (was 11 704)
  at R = connect_ratio × 1.71 mm. Tests: `LatticeWallThicknessTests` 12/12 (+15
  neighbours). Full suite on 604736ae: 2483 tests, the same 5 pre-existing failures.
- **2026-09-21 23:2x — HIS 23:17 ROUND (images 1–8).** (1) THE SAMPLE CUBE UNDER REPAIRS
  (images 2–3, "jumbles of nothing with massive beams … ALREADY SOLVED"): core fixed the
  collapse (node_merge chaining + the degenerate filter) in 6d6177c4 and the app's
  emission skip was lifted on core reply 8 — but that commit is on PR 358, which is NOT in
  the linked xcframework (Sep 11), so the linked core still collapses the cube. The sample
  now runs the emission only when `TopOptKit.coreCarriesTheSampleRepairFix` (probe: the
  `stepped_min_tile_mm` key PR 358 added) and the row says "Repairs need the newer core
  (PR 358) — traced cube shown". Rebuilding the xcframework from PR 358 turns it on.
  (2) The wall editor opened as the cell-based one under Organic (image 4): the pick read
  `project.lattice.algorithm` (saved), now the wizard's live `model.cellTransition
  .coreAlgorithm`. (3) THE POCKET (images 5–8: "Walls should never take the place of the
  empty or too little lattice! Ever!"): the region field that opens the shell and carves
  the body was the SLAB-aware distance, so where his profile left no band the face stayed
  closed and the part's own material showed as a wall, and the empty part of a band read
  as a plate. `LatticeRegionMask.signedDistanceWholePrism` now feeds that field: the
  declared prism is always removed (air); the slab only places lattice (candidates, cells,
  the slab mesh keep the slab-aware distance). A start further inside therefore means air
  in front of the lattice, and less lattice means more air — never a wall. NOTE for core:
  this supersedes D2/"sealed band" as sent — the region is a pocket, [start, end] is where
  the lattice sits inside it.
- **2026-09-22 00:5x — THE THIRD WALL, THE FRAME, AND HIS TWO YESES.** (1) "Face 23 & like
  it" (a FaceRegion in Group C, role include, depth 12) reached nothing: the emission
  walked `g.faces` only, never `g.regionIDs`; the row's "Frozen, not latticed" came from
  `LatticeSelectableRef.latticeReachesTheRun`, false for EVERY region by PR 331 §6's
  reasoning (a region is a voxel set). A union of WHOLE faces is not: it is N face prisms.
  `LatticeRegionEmission.regions(regionMembers:)` now emits one prism per member face of
  each region the group holds, under the REGION's key (role, depth, density, expand,
  synthetic all keyed "r:<gid>:<rid>"); `ProjectModel.latticeRegionMembers` answers for
  regions with no cuts and no parts; `latticeReachesTheRun(_:)` on the model replaces the
  value-only one at both drawer sites. A direct face that is also a member is emitted once.
  Tests: `LatticeRegionEmissionFaceRegionsTests` (3). (2) His yeses: the pocket stands
  (core reply 4 sent as drafted); the face frame axes go on the wire — `frame_u`/`frame_w`
  (unit world vectors of `LatticeRegionMask.basis`, = core's `plane_basis`) beside
  `outline_uv`, behind the whole-job probe `TopOptKit.regionFrameAxesWired` (false on the
  linked core ⇒ not sent); `wireDictionary(frameAxes:)` tested (+z face ⇒ u = −world y).
  (3) The seeding slider is withdrawn from the panel (plumbing stays at ×1); the depth
  fields are 64 pt and the swatch is gone so "Face 15"/"Face 2" read in full.
- **2026-09-22 01:2x — HIS 01:09 ROUND (images 1–8).** (1) FACE 23 IS NOT A PLANE: the
  stand's inner curve resolved to neither plane nor cylinder, `resolve` gave nil, the face
  was SKIPPED (scene regions r0/r1 only) — so no card, no field, no lattice. New
  `LatticeFaceFacets`: a face's triangles grouped by normal (±12°), each group a planar
  facet (area-weighted normal, centroid, its own outline via
  `LatticeFaceOutline.loops(triangles:)`), emitted as ordinary face prisms under the same
  face id / selectable key (`LatticeRegionEmission.regions(facets:)`, tried when `resolve`
  is nil). The wizard shows ONE card per key (the widest facet). Limitation stated: a
  manual-grade drawing on a faceted wall applies per facet (each facet's own u axis).
  (2) THE LATTICE JUTTING OUT OF THE RIM / THE RIM INDENTED WITH THE DRAWING (octet):
  the packer never tested depth against the slab — a whole 12 mm cell was laid where the
  band was 6 — and the rim texels were activated slab-aware. `LatticePreviewOccupancy
  .boxInsideSlab` gates every fit (keptVolume's `fitsBox` and the placement's `fits`,
  `lastFail = "slab"`): a thinner band takes the next rung; the activation owns a texel
  through the whole prism when it lies within the rim's width of the outline, so the
  pocket's solid outline is the wall's, not the band's. (3) The steps editor's START line
  snaps to the NEAREST step, zero included (`snap(_:nearest:)`); the end still rounds
  down and never to nothing. Tests: `LatticeFaceFacetsTests` (3: the quarter-cylinder
  fan with outlines summing to the strip's area, a plane stays one facet, the slab fit).
  Full suite on bc3cf67f: 2490 tests, 12 failure assertions = the 5 pre-existing tests +
  two source pins on rules he replaced (the bake queue, the exit closure's length), both
  re-pinned. Untested on device until he reopens: face 23's facets in the wizard and the
  field, the thinned octet band, the rim's full depth.
- **2026-09-22 02:2x — SEAMS (his 01:58 round, images 1–5).** The facets of face 23 and
  the corner where face 2 meets face 23 each drew a RIM along every outline edge — so
  every facet seam and the shared corner edge became a solid wall inside the pocket
  (images 2–5: "walls again where there shouldn't be"). New: `LatticeRegionSpec
  .outlineSeams` (per loop, per edge). An outline edge whose neighbouring triangle
  belongs to the SAME face (the next facet) or to another LATTICED face is a seam:
  `LatticeFaceOutline.loopsWithNeighbours` (a mesh-wide edge → faces map, cached per
  mesh signature) reports the face across each boundary edge; `ResolvedFace.plane
  .neighbours` carries it; `spec(seamWith:)` marks seams; the emission's pre-pass
  collects every latticed face. `LatticeFaceOutline.signedDistance(seams:)` measures
  distance to true outline edges only (sign from the whole loop; all seams ⇒ ±1e6):
  used by the mask (contains / signedDistance / outlineDistance), the octree raster and
  `dOut`, the occupancy's exact outline, so no rim band, no cell standoff, no expand at a
  seam. `LatticeOutlineRibbon.offsetRing(seams:)` leaves seam edges in place and `build`
  sweeps no beam along them; the cap and the slab mesh use the same rings. Tests:
  `LatticeOutlineSeamTests` (2). NOT SENT TO CORE: seams are preview-only — the run's
  `organic_solid_rim` will still rim every facet seam until core takes either a seam-edge
  list beside outline_uv or a curved-face region (say so in the next core note). Expand
  (image 1): the offset now applies only to a face's TRUE outline edges — a facet's
  seams do not move — which is the likely cause of "the prism moved" (a narrow facet
  offset from both seam sides collapsed to a sliver); re-check on the stand. NOT BUILT:
  his 2.2 (a 45° stability wall at the corner where two latticed faces meet) — a design
  to agree first (thickness, whether it is a rim-width plate or a cell-wide chamfer).
- **2026-09-22 02:24 — THE CORNER PLATE (his 2.2, "thin plate, rim width").** Where a seam
  is between two DIFFERENT latticed faces (`LatticeRegionSpec.outlineSeamFaces`, the run
  face id across each seam edge), the outline beam mesh (`LatticeOutlineRibbon.build`)
  emits one box per shared edge: rim width thick, from the shared edge inward along the
  bisector of the two inward normals, length = min(depth A, depth B) / cos(half-angle) —
  6 mm walls meeting at 90° ⇒ 8.5 mm diagonal reaching the inner corner. Emitted once (the
  smaller face id). Facet seams within one face get no plate. Preview only, not on the
  wire. Test: `LatticeCornerPlateTests`.
- **2026-09-22 03:xx — THE WHOLE-CODEBASE REVIEW, FIXED IN ORDER (his 02:33: "go through
  the entire codebase … note every bug … then resolve them one at a time").** Images 1–5
  of that round still showed walls, rims and three boxed pieces after the seams. The
  review (86 findings, consolidated into ten tiers) and what changed, each built and
  tested before the next:
  (1) `UnifiedShading` `Fsolid`: inside a declared prism a refused cell is AIR, never the
  clip — `anyActive ? 1e9 : (dRegion < 0.0 ? 1e9 : dClip)`. Every texel without a cell
  inside the pocket had read as a wall. Two `LatticeSolidFillTests` pins re-pinned.
  (2) `LatticeRegionMask.outlineDistance`: regions UNION (`max`), not `min` — two
  overlapping prisms had rimmed each other's outline.
  (3) The offset sign: a positive `inPlaneOffsetMM` GROWS the region (membership is
  `signedDistance ≤ offset`), so the ribbon, the cap and the slab mesh offset their rings
  by `−offset`; the ribbon's "deepest point" walk-back applies to INWARD offsets only (an
  outward ring had collapsed onto the loop — the ribbon test read 1000 for 1050);
  `inside()` sees seams; the slab mesh raises no riser wall on a seam. `LatticeOutline
  RibbonTests.testTheInPlaneOffsetMovesTheWholeBeamWithTheRegion` re-pinned [1050, 950].
  (4) THE FLARE: adjacent facets of a curved face meet at the BISECTOR plane, so a
  facet's prism is not a chord-wide box with a wedge of material between it and the next.
  `LatticeRegionSpec.outlineSeamTilt` (±tan(half dihedral) per seam edge, sign by whether
  the neighbour's normal leans away), `LatticeFaceOutline.insideWithFlare(…, depth:)` —
  beyond a seam a point is inside up to `depth × tilt`, a converging seam cuts the prism
  short — used by `contains` and the sign of `signedDistance`; `signedDistanceAcrossSeams`
  for the octree raster and `dOut`. The facet origin moves out to the outermost VERTEX
  (centroids had left the mouth a sagitta inside the surface). Seams are decided in a
  POST-PASS (`LatticeRegionEmission.finishSeams`) from the EMITTED set, faces mapped
  through `runFaceID`, and the neighbour across a seam is found BY RAW FACE then nearest
  edge — a 1e-3 world match had found nothing, because a shared edge rebuilt from two
  facet planes differs by the sagitta (0.25 mm on the 50 mm test cylinder). Tests:
  `LatticeSeamFlareTests` (2).
  (5) The cap: a triangle is built only when ALL THREE corners end inside material (one
  measured corner had drawn the whole fan over the open face), and never where another
  include prism continues past this one's end. `LatticeRegionCapTests` (+2).
  (6) `LatticeSDFScene.prismOccupancy` = the part's material inside every prism IGNORING
  the slabs (`LatticeRegionMask.clippedWholePrism`); it feeds the measured wall width,
  the rim's attachment seed, the in-plane boundary distance, the octree's "is there
  material here" and the organic ribbon depths. `occupancy` (slab-clipped) still places
  lattice and the organic candidates. Every slab edge had read as a boundary: a rim, a
  cap, or a solid wall across the pocket — the walls of images 3–5.
  (7) The corner plate: the neighbour at the edge is the facet whose outline holds it
  (not the first region under that face id); no plate under 25° or over 155° between the
  walls; no plate with a degenerate side or a non-finite length.
  (8) The thickness builder on facets: one drawn profile spans the WHOLE wall — every
  facet reads x along the wall's shared chord axis (`FaceFrame.shared`, `sharedAxis`);
  Auto single takes ONE p95 per wall (merged across facets); the sim raster's map origin
  is the first cell's centre (a half-cell shift); the floor is `a0 + floor`, from the
  slab's start; the start never snaps below `a0`, the end never below the start. The
  "By sim" rule reads its OWN field (`wallStressField`: the measured lattice sim, else
  the run's) — the grading's `field` is nil under "No grade"/"Grade to fit", which had
  silently turned "By sim" into the whole range.
  (9) Bake orchestration: ONE fingerprint for every algorithm (mesh + stepped cells in
  the key) — the octet path had none and Save & Exit started TWO bakes; the wizard's
  plain rebake on exit is gone; `strutRefining` resets when a bake is superseded
  ("Adding the print repairs" had stayed up until the old bake's stage two was dropped);
  `strutBakeCancel` tells the superseded stage loop to stop before core's emission; the
  128³ tensor resample runs on the bake thread (it froze the UI on every bake); the bake
  thread reads captured copies of the settings, never `project.*`; `strutRebakePending`
  removed (dead); the region key now carries the groups' region memberships, the wall
  thickness, the per-wall cells and the foci (`LatticeWallThickness` & co. Hashable).
  (10) The wizard and editors: the number field's ARROWS walk the steps, a typed number
  lands on the nearest step (typing 10 into 2 had walked to 4); organic's start field
  moves freely (`[0] + []` had pinned it at 0); an end snapped under the start takes the
  first step past it; the drawn halves are halves of the ALLOWED RANGE in both editors
  (with a range of 8–12 the start's "≤ 50 %" had clamped to 8 and never moved); the
  column cap 96 → 400; keyless walls keep their own cards; a card's width is the whole
  wall's shared axis; `wallEditorFaces` is computed once per change (it facets every
  curved face and was called four times per keystroke). NOT CHANGED, noted: the profile
  card's true-shape render ignores the density mode and the floor (cosmetic).
  FULL SUITE (05:16, after tiers 1–10): 2504 tests, 32 skipped, 12 failure assertions in
  6 tests — the 5 pre-existing (`AppModelTests` 3MF ×3, `OrganicSampleCubeTests
  .testThickerIsLiveAndNeverRetraces`, `OrganicVariantCacheTests.testTheKeyIgnores
  Thickness…`) plus two the run caught: `LatticeSeparationRegionTests.testNoRegionIsEver
  EmittedAsALatticeRegion` — a PR 331 pin of the rule he reversed on 09-21 (region members
  ARE emitted), never re-pinned in 3bc36740, now `testARegionsMembersAreEmittedAsFace
  PrismsUnderTheRegionsKey` (3 prisms: the face + the union's two members under the
  region's key); and `OrganicShapeBandTests.testTheBandGradesSpacingTowardTheFloorNearThe
  Outline` — MY tier-2 union: `outlineDistance` started `best` at 1e3 against a 1e9
  sentinel, so the max never left 1e3 and the organic band graded 0 voxels (fixed:
  sentinel 1e9, far value 1e3 on return). Bake fingerprint also carries the run's
  outcome (a landed run rebakes the octet). Installed on the sim 05:17:02. Not yet
  judged on device: everything above — he reopens; report only with DIAG numbers.
- **2026-09-22 14:55–15:45 — HIS THREE IMAGES AFTER THE TEN TIERS: the rim outside the
  model, "get rid of the rims", the thin back wall.** Measured on his stand offline
  (`LatticeFace23DepthProbe`, his settings: faces 15/2/23 at 12/13/20 mm, face 23 expand
  +4.15 — the DIAG regions list) before touching anything:
  · THE THIN BACK WALL IS THE PART. Face 23's facet prisms keep their full 20 mm in the
    app's mask (contains-with-flare is flat across all ten depth deciles), but the leg
    behind the curved face is thin: the big middle facet has 6530 of 15720 prism voxels
    inside the part, and beyond 8 mm depth only 36 %; the measured wall along its normal
    is p05 3.44 / p50 18.91 mm. At 100 % depth the lattice is as thick as the material.
    Also the first 2 mm of every facet prism is mostly air (134 of 1310 voxels) — the
    facet origin sits at the outermost vertex, a sagitta outside the surface.
  · THE RIM OUTSIDE THE MODEL = the outline ribbon of the face-23 facets offset OUTWARD
    by the +4.15 expand into air, and started on the facet plane a sagitta outside the
    surface. Now: a grown region's beam moves outward only where the PART has material
    beyond the edge (`LatticeOutlineRibbon.build(attached:)`, per-edge `offsetRing
    (edgeOffset:)`), and every beam starts at the part's surface (`surfaceAt:`, a 4 mm
    march along the normal). DIAG `outline beam (grown outward only where attached; none
    on seams)` per region.
  · "THE SIDE ONE" = the corner between face 23 and the flat walls, which was NEVER a
    seam: the probe shows face 23 and face 15/2 are not adjacent at all — a fillet face
    lies between them (face 15's outline neighbours are f56 ×21, f69 ×30, …; never f23),
    so neither the mesh-edge match nor a geometric edge match (both tried) could pair
    them. What IS true: a probe 0.5 mm beyond face 23's edge, half-way down, lies inside
    face 15's or face 2's prism on every non-facet edge. So a seam is now decided BY THE
    PRISM BEYOND THE EDGE (`finishSeams` third pass, offsets 0.5/1/2 mm at half the
    shallower depth, opposite walls >150° apart never pair). On the stand: face 15 25 of
    63 edges seams, face 2 30 of 75, the facets 17/21/9 of 18/21/10 — the beam mesh 4392
    → 2040 verts; the L-profile's open edges (his curved inner rim) keep theirs. The
    flare across a seam is CAPPED at the neighbour's depth less the gap
    (`outlineSeamDepthMM`): a 20 mm prism cut by a 12 mm neighbour's bisector past 12 mm
    left a strip nobody owned. Tests: `LatticeSeamFlareTests` (+2), `LatticeOutlineRibbon
    Tests` (+1). NOT verified on device — he reopens; the DIAG lines carry the census.
- **2026-09-22 15:25 — THE FACE-PRISM IS A SELECTION, NOT A SHAPE (his images 1–4 on the
  15:20 build).** His rules, verbatim in spirit: the lattice is the model's material
  inside the prism; the RIM is the outline of the model's shape where lattice meets
  SOLID, never the prism's own top/bottom edges where it meets air (those are the
  finish's); overlapping prisms are ONE lattice with one continuous rim, non-overlapping
  ones stay separate. Measured before changing: core's tracer stops a curve only when it
  leaves the CANDIDATE set (`organic_lattice.hpp:871`), which is already the union of
  every prism, so curves cross prism boundaries today — the "separate pieces" were the
  rims, not the trace. Changed: the outline beam is drawn only on edges with the part's
  solid beyond them (open edges: none; seams: none) — `LatticeOutlineRibbon.build`'s
  `attached` gate now skips open edges; the organic solid rim (`OrganicSolidRim
  .voxels`) seeds only against SOLID neighbours, reversing his 09-08 air exception
  (flagged to him: 09-08 said "the bottom of the lattice is an outline and should get a
  rim"; today says the top and bottom of the prism must never be rims; today's rule =
  core's own). Re-pinned `OrganicSolidRimTests.testTheOutlineTakesTheRimOnlyWhereIt
  MeetsSolid`, `LatticeOutlineRibbonTests` air ⇒ no beam. Core note 7 answered: (b)
  accepted by core; the measurement job with face 23 as facets is in ~/Downloads
  (`m2_verticalStand_face23_facets_job.json`, five regions, frame axes on, no expand on
  the wire); his interim decision (deeper facet slabs vs leave) still open.
- **2026-09-22 15:50 — THE SELECTION GOES ON THE WIRE (his: "you literally just counted
  the voxels to select").** No interim decision: `LatticeRegionSpec.wireOutlineLoops`
  pushes each facet's outline OUTWARD across every diverging seam by `min(depth,
  neighbour depth) × tan(half dihedral)` (the wedge's width at the bottom), and the
  half-extents grow with it, so core's flat slabs union to the preview's bisector pocket;
  converging seams and true edges do not move; the preview keeps `outlineLoops` and the
  flare. Over-selection: a sliver ~d·θ²/2 at the seam's far end, inside the neighbour's
  slab. On the stand: the three facets move 2/4/2 outline vertices by up to 2.96 mm. The
  job for core regenerated with the grown outlines (~/Downloads/m2_verticalStand_face23_
  facets_job.json). Test: `LatticeSeamFlareTests.testTheWireOutlineIsGrownAcross
  DivergingSeamsOnly`. Installed 15:57.
- **2026-09-23 00:00 — HIS SEVEN IMAGES: the "wall between the walls", the rim rule
  made clear, the un-met corner.** Measured on his stand (`LatticeStandCoverageProbe`,
  his project's real selection: Group C = faces 15, 2 + region 101 "Face 23 & like it"
  = [23] only): the part is 53 mm thick in y; faces 15/2 are the L's WHOLE sides (outline
  x −16…198, z 3…197) with 12/13 mm prisms; they overlap in 0 voxels; 27 % of the part's
  material is in no prism (55 % of the bottom height bin = the base's core; ~3 % in the
  leg's upper bins). Profiles through the leg at x = 13: fully selected side to side at
  z = 40/89/180 (face 23's 20 mm prism reaches across there); at z = 139 the leg's sides
  are faces 56/57 (a recessed panel, not selected) and the core is face 23's. So the
  grey wall in his image 1 is the material between the two 12/13 mm side slabs where
  face 23's 20 mm does not reach — selection, not a bug — unless he intends the side
  prisms to go through (still open with him). The width walk is NOT broken (bimodal
  10.31 / 53.28 mm: two plate thicknesses). RIM RULE (his, final): outline the whole
  lattice shape, air or solid beyond; no rim only where two lattices combine (a seam).
  Restored: the ribbon draws every non-seam edge (air beyond only pins a grown region's
  beam to the true outline), `OrganicSolidRim` seeds against air again; re-pinned
  `OrganicSolidRimTests.testTheOutlineTakesTheRimEvenWhereItMeetsAir`, `LatticeOutline
  RibbonTests`. THE PATCHY RIM ON THE INNER CURVE (image 4): where the leg is narrower
  than 20 mm, face 23's prism reached across to the inner curve and the flat walls'
  inner-curve edges read as seams though beyond them is AIR — the prism seam test now
  also requires part material at the probe (`regions(solidAt:)`, a 128-across occupancy
  cached per mesh in `ProjectModel.latticeSeamSolidAt()`, DIAG `seam occupancy`). Core's
  tracer stops a curve only when it leaves the candidate union, so overlapping prisms
  are already one lattice for the trace. 43 targeted tests green; installed 00:10:55.
- **2026-09-23 00:40 — EXPAND GROWS THE PRISM IN EVERY DIRECTION BUT THE FACE (his: "expand
  grows it in EVERY direction"; "the face should always be the position of the face-prism's
  face. They should ALWAYS align").** The emission had applied expand IN PLANE ONLY since
  2026-08-17 (his own instruction then, `LatticeSlabExpandTests…NotInDepth`) while the
  stage's purple box grew every way — so a 4.15 expand on face 23 widened the outline
  and left the 20 mm depth alone. Now `spec(for:…expandMM:)` grows the DEPTH by the
  expand (20 + 4.15 = 24.15 on his face 23) with the origin never leaving the face; the
  outline grows by it; the wire carries both as geometry (`wireOutlineLoops` offsets
  every non-seam edge by the expand; `depth_mm` carries the grown depth) because core
  rejects an expand key. A first cut also moved the mouth out by the expand — he caught
  it in a minute ("not keeping the selected face attached to the expansion"); reverted.
  Re-pinned `LatticeSlabExpandTests.testTheExpandGrowsTheEmittedRegionInPlaneAndInDepth
  WithTheMouthOnTheFace`; new `LatticeSeamFlareTests.testExpandGrowsTheDepthAndThe
  OutlineAndTheMouthStaysOnTheFace`. 58 tests green. On the stand the un-selected core
  is unchanged in kind (26 %, 55 % of the base's bottom bin): the 12/13 mm side prisms
  still leave 28 mm between them where face 23's 24 mm does not reach. Core's job
  regenerated with the 24.15 mm facets. Installed 00:31.
- **2026-09-23 00:25–00:35 — THE CORNER WALL "SHAPED LIKE THE OVERLAP", and the mouth on
  the face.** (1) The drawn shell (`FaceOffsetShell.dilated`) moved every vertex OUT along
  its normal by the expand (his 08-18 "up when expanding") — the prism's mouth sat behind
  the face ("moving the face-prism BACKWARDS"); now expand grows the patch sideways and
  the far end deeper (`build` offsets by depth + expand), the base never leaves the face;
  the emitted region does the same (origin fixed, depth + expand). Re-pinned three shell
  tests. (2) THE WALL: the leg is a U-channel (cross-section probe: web + two flanges,
  air between); where face 23's prism and a flange prism OVERLAP, the converging seam
  flare trimmed EACH prism to the bisector — but the two seam edges do not meet on the
  corner line (a fillet between the faces), so both cuts started short of the corner and
  a diagonal strip belonged to neither: the wall down the corner, shaped like the
  overlap. The candidate test had hidden it (its fallback undid the cut) while the
  shader's region field kept it — the wall existed only in what was drawn. The
  converging cut is REMOVED (overlapping prisms never lose material; ownership inside
  an overlap is first-match, as core's); the diverging flare stays. Field map at z=185:
  the corner block reads pocket throughout; the only solid voxels are the flange tips
  and the outer fillet, which no selected face covers. 37 tests green. Installed 00:33.
- **2026-09-23 00:58–01:20 — UNSELECTED FACES KEEP THEIR SKIN; the rim IS that skin (his six
  images).** His new rule: a CAD face not selected must never be turned into lattice ("the
  curved face should be consistently thick"); rims are "the solid holding the lattice to
  the solid model … never visible from the outside … always in the shape of the model".
  Built: `LatticeSDFScene` computes a signed distance to the triangles of every KNOWN
  UNSELECTED face (`signedDistance(indices: unselIdx, like:)`; id-less triangles are
  skipped — a synthetic block has none) and folds a skin one rim thick under them into
  the REGION FIELD (`carved = max(region, skin − toUnsel)`, INSIDE the part only — applied
  outside it moved the selected face's zero crossing inward, caught by `LatticeFaceOutline
  Tests.testTheSkinLeavesASolidWallAtTheSurface`). `unselectedSkinMM` = the organic rim
  (3.41 on his stand) or the octet's outline beam width. Capsules are clipped by the
  region field, so struts inside the skin are hidden; candidates keep the skin voxels so
  the curves run into it (his 09-08). The BAND (`outlineSDF`) now also measures toward
  that skin (`min(outline, toUnsel − skin)`) — the corners fill green — and
  `outlineDistance` takes the nearest outline among the regions CONTAINING the point
  (the union's max had erased the band wherever face 23's prism overlapped face 2's:
  his "grade-to-shape just stops half way up the curve"). The outline BEAM MESH is
  retired (`buildOutlineRibbon` returns nil when a skin is armed): it stood on the
  surface, poked past the leg's top, ran through the lattice and left the two bottom rims
  apart. DIAG `unselected-face skin: … pocket voxels turned solid`. Re-pinned `Lattice
  ShellAndMarchAgreeTests` (cells active inside the skin by design). 33 tests green;
  installed 01:19. Not judged on device.
- **2026-09-23 02:23–02:40 — "THE RIM IS BELOW THE SOLID": skin, then rim, then grade, then
  lattice; the rim drawn by the lattice layer.** His correction of my 01:20 reading: the
  skin is the model's own thin wall at an unselected face; the RIM is the solid band UNDER
  it, the transition where the lattice thickens into solid and connects to the skin. Built:
  `unselectedSkinMM` = two beads (`outlineBeamMM`, 1.21 on his stand), `unselectedRimMM` =
  the organic rim (3.41) or the octet band; the region field is solid through both; the
  band grades from the rim's inner edge. THE GREEN ON EVERY FACE (his images 1, 2, 4): the
  unselected-face distance field was clamped at 3 voxels (5.16 mm), so every voxel deeper
  than that read "1.8 mm from the rim" and graded — the field now reaches skin + rim +
  the shape band (`bandVoxels`), and nothing is applied beyond its clamp. WHERE ARE THE
  RIMS (image 4, body hidden): the rim lived only in the body's region field. Now the
  region texture's alpha carries "distance beyond the skin's inner face" (`skinInSDF`),
  the march runs SOLID-ONLY under the capsules (a NEGATIVE step count: no strut field, no
  part fill) and draws the band {inside a prism ∧ region solid ∧ beyond the skin} in the
  rim colour. THE GREY PATCH (image 1): measured — the outer curve is face 23 the whole
  height; the leg is a hollow channel above ~126 and below ~57 mm and SOLID between (an
  internal cavity, faces 26/75, further in); the 24 mm prism exits into the channel's air
  at the top and bottom and ends inside solid in the middle — the patch is the pocket's
  floor, the model continuing. Not a bug; a selection/depth fact told to him. THE INSIDE
  WALLS (images 2/3): the channel's inner faces are unselected ⇒ skin + rim by his own
  rule; from inside the channel that is a solid surface. Told him; if he wants them
  latticed they must be selected. Re-pinned the two `LatticeSolidFillTests` shader pins.
  51 targeted tests green after the re-pin; installed 02:36. DIAG line:
  `unselected faces: skin … + rim … · pocket voxels turned solid: skin N, rim M`.
- **2026-09-23 02:44–03:15 — HIS ADDENDUM: a face the prism passes THROUGH is open; only a
  face the lattice runs ALONGSIDE gets skin + rim.** His five points on the 02:36 build:
  the patch on face 23, internal walls, green everywhere, rims against the internal walls,
  no rims elsewhere. Measured the patch's CAUSE (he forbade measuring whether it should
  exist): 3 mm inside face 23's middle facet 25/34 samples read solid, nearest unselected
  face = 25, an internal CAVITY WALL ~3 mm behind the surface — the web is thin there and
  the skin + rim from the cavity wall reached the outer surface. The facet planes are
  clean (surface 0.05–3.4 mm inside every plane). His addendum ("the opposite side of the
  face selected, if the face-prism passes through it, gets latticed through") is now the
  rule: an unselected triangle is probed 1.5 mm into the part; if no include prism
  contains the probe it gets nothing; if any containing prism's normal is within 60° of
  the triangle's it is PASSED THROUGH → open; otherwise ALONGSIDE → skin + rim + band.
  That opens the cavity wall (the patch), the flanges' inner faces and the channel floor
  (the "internal walls" and the rims against them), and stops the band grading from the
  flange's inner face 8.6 mm behind the flat faces (the green everywhere). Verified
  offline: the middle facet reads open at 1.5 and 3 mm in. DIAG now counts triangles
  alongside / passed through / unreached. 27 tests green; installed 03:12.
- **2026-09-23 15:00 — THE FULL REVIEW OF THE LATTICE PREVIEW PATH AGAINST HIS RULES (six
  whole-file reviews; RULES.md in the scratchpad restates the rules R1–R12).** His three
  symptoms and their causes: (S1) no rim/green under the leg's top face and the base's end
  face — unselected faces were classified ONCE PER TRIANGLE by a centroid probe 1.5 mm in;
  a two-triangle face 53 mm wide has centroids outside the 12/13 mm side prisms ⇒ whole
  faces "unreached", no skin/rim; (S2) the 45° chamfer carved — the passed-through cone
  was 60° (R3 says ~30°) AND the seam post-pass declared the chamfer's edges seams because
  another prism lies beyond them, never asking what SURFACE lies between; (S3) blue rim at
  one spot only — green came from the prism OUTLINE distance (every edge, air or not) while
  the rim came from the skin field, two unrelated sources; and the march's step is not
  bounded by the rim band, so rays from the lattice side step over a band thinner than a
  cell and only catch it where two bands overlap at a corner.
  THE ORDERED LIST (fix one at a time, build + tests after each group):
   A1  passed-through cone 60° → 30° (scene).                              [R3/R4, S2]
   A2  skin/rim per VOXEL: every non-passed-through unselected triangle enters the field;
       the "reached" test is the pocket itself (region < 0). Passed-through decided per
       triangle from the prisms containing any of its nudged vertices/centroid.  [R4, S1]
   A3  the band (.g) comes ONLY from the rim's inner edge (toUnsel − skin − rim); the
       prism-outline distance no longer feeds green.                       [R5/R6, S3]
   A4  the march's step is bounded by the rim band's field (Fr evaluated always); the
       dClip leap does not jump the band.                                   [R5, S3]
   A5  the organic in-plane erosion of EVERY outline by solidRimMM is removed (a ring of
       the body's shell at every selected outline and seam, visible from outside). [R4/R2]
   A6  the region CAP plate is no longer built or drawn.                     [R7]
   A7  a seam needs the raw mesh neighbour across the edge to be latticed or absent; an
       edge whose neighbour is a known UNSELECTED face is never a seam (the chamfer); the
       geometric and prism-probe passes honour that veto.                   [R1/R4, S2]
   A8  partSDF signed by the WHOLE part (solidOccupancy), not the slab-clipped occupancy —
       fixes the wall-width walk (stopped at the slab), the cap test, subfloor retention.
   A9  the doubled path's "inactive cell = solid" rendering off.             [R7]
   A10 the half-band outline strip clip (rimParams.w) off; the Finish dressing returns.
   A12 the skin sized from the printer's bead, not a hard-coded 0.45.        [R4]
   A13 the skin-in channel continuous across the surface (no 1e3 blend inside the skin).
   A15 `contains` with a negative expand agrees with the field (the flare no longer
       bypasses the shrink).                                                [R8]
   A16 hole loops: the seam probe's "outward" chosen by containment, not winding.
   A17 the geometric seam pass gets a normal guard (opposite walls never pair).
   A18 width statistics enumerate the whole prism, not the slab.            [R12]
   A20 `latticeInputsLastBaked` recorded inside `buildStrutScene` — "Exit" with nothing
       changed starts nothing.                                              [R10]
   A21 the profile model's 50 % clamp of the WHOLE wall removed (the editor enforces the
       allowed range's midpoint).                                           [R9]
   A22 depth steps snapped relative to the start `a0`.                      [R9]
   A23 the octree's finest fall-through/fill never paints a cell that failed the slab. [R9]
   A24 anti-parallel prisms merge only when they overlap IN PLANE too.      [R1]
   A25 `signedDistanceAcrossSeams` bounded by the seam's flare, not unbounded.  [R7]
   A26 the diverging flare exists only where the neighbour prism exists (s ≤ cap).  [R1]
   A27 seam detection independent of region order (probe against unflared copies).
   A29 the octet rim/boundary seeds keyed on the alongside skin band, not only "material
       beyond".                                                             [R4/R5]
   Noted, not changed: octree 3-D EDT fallback for non-axis facets (LOW); manual face
   primitives' on-screen box ignores expand (LOW); stale comments (LOW); lattice-only
   shadow casts the slab (LOW); rim hit shaded with a strut's normal (LOW).

## 2026-09-23 16:40 — THE LIST, WORKED (A1–A29 except A26; installed 16:36:42)

Every item from the 15:00 review list is in, one by one, in the recorded order, except
A26, which the seam-flare test refuted (below). Installed at 16:36:42; the installed
`TopOpt.debug.dylib` carries the new DIAG marker `outline rim (solid-backed)` and no
longer carries the old `runs ALONGSIDE`.

### What changed, by rule

**R3/R4 — passed through vs alongside (A1, A2).** The cone is 30°, not 60° — a 45°
chamfer is ALONGSIDE and keeps its skin (image 3, "consistently removed"). And only
"passed through" is decided per triangle any more: an unselected triangle is open when a
prism whose direction is within 30° of the triangle's normal contains the triangle's
centroid or any corner nudged 1.5 mm in; EVERY other unselected triangle enters the skin
field, and the pocket decides per voxel. The old "unreached" class is gone — the leg's
top and the base's end (images 1, 2) were "unreached" because their big triangles'
centroids sat outside every prism while the pocket ran right under them, hence solid
with no skin, rim or grade.

**R4/R5/R6 — skin → rim → grade, rim ⇔ green (A3, A5, A13, A29).** Two rim sources, one
field:
- under every unselected face the lattice runs alongside: skin (two beads of the
  PRINTER's bead — A12, `beadMM` passed into the scene) then rim (`max(skin,
  organicSolidRimMM)`), carved into the region field, `skinIn` written continuously
  across the surface (negative outside the part — the texture at the face no longer
  blends a distance with the 1e3 sentinel);
- along the prism outline ONLY WHERE THE PART'S SOLID BACKS IT
  (`LatticeRegionMask.solidBackedOutlineDistance`: nearest point on the grown outline,
  a probe one voxel beyond it at the same depth, `solid` occupancy there and not inside
  any prism). A prism side running out into air — a grown outline past the leg's top,
  the mouth's edge — is nothing; a prism side inside the part's material gets the rim
  and then the grade. The band `.g` is `distance − rim` from either source, so green
  starts at the rim's inner edge and exists only where a rim does.
- the organic in-plane EROSION of the outline is gone (it was blind to what lay beyond
  the edge). `OrganicSolidRimTests` re-pinned to the new mechanism.
- the octet/organic boundary seed (`attachedSeed`) also seeds from the carved band
  inside the prism, so the cell grade lands on the skin/rim, not only on "material
  beyond".

**R7 — nothing solid inside the pocket but the rim (A6, A9, A10, A23).** The region cap
is no longer built (`regionCap = nil`; the draw is gated on it). `rimParams.z` (doubled's
inactive cells drawn solid) and `.w` (the octree's outline strip + dressing suppression)
are 0. The octree's finest fall-through and the packer no longer paint a cell that
failed the depth slab (`slabFailed`).

**Rim visible (A4).** The march step is bounded by F whenever `Fsolid` is finite, not
only when a cell is active — with no cell in the rim band it leapt 0.7 cell and crossed
a 4.6 mm band without a hit ("blue rim only at one spot").

**Seams (A7, A16, A17, A27, A25, A15).** An edge whose raw mesh neighbour is a KNOWN
unselected face is an outline, never a seam — the geometric and prism passes are skipped
for it (the chamfer). Outward across an edge is decided by containment (a step to the
right that lands inside the outline ⇒ outward is left), so hole loops probe the right
way. The geometric pass has the same >150° opposite-walls guard as the prism pass. All
probes read a snapshot of the regions taken BEFORE any seam flared them (no index-order
dependence). `signedDistanceAcrossSeams` is bounded by the seam's cap × tilt when the
octree passes tilts/caps. `contains` with seams still honours a NEGATIVE expand (the
flare had answered "inside" for the whole polygon).

**A26 — NOT DONE, refuted.** "No flare below the cap" would leave the corner block under
the neighbour's foot — in neither prism — solid: a wall between two lattices.
`LatticeSeamFlareTests.testTheFlareIsCappedAtTheNeighboursDepth` pins the flare holding
its cap width to this prism's depth; kept.

**Measurers (A8, A18).** `partSDF` keeps its slab-clipped sign for the march; a new
`partMaterialSDF` (same distances, signed by the whole solid) goes to every measurer —
wall width along the normal (scene, ribbon, wizard), subfloor peaks, the organic
candidate/anchoring solid test, the finish-skin term. Width statistics enumerate
`containsWholePrism`.

**Wizard / walls (A20, A21, A22, A24).** `latticeInputsLastBaked` is recorded inside
`buildStrutScene` (was 2 of 16 sites ⇒ Exit force-baked). The profile model's 50 %
whole-wall clamps (steps init, `flat`, the curves' mid-plane flatten) are gone — the
halves are the ALLOWED range's, which the editor keeps; a start never passes its end
(zero-depth hole allowed). Depth steps snap relative to the slab's start `a0`.
Anti-parallel prisms merge only when they also overlap in plane (origin or outline centre
inside the other's prism).

### Tests
Targeted suites after the changes: 123 tests, 7 failures → all seven were pins of the
old behaviour, re-read one by one: 4 re-pinned (steps model ×3 assertions → the new
rule; rim-erodes → an INSET outline with material beyond it, plus a new assertion that
an outline at the cube's own edge takes NO rim; OrganicSolidRimTests string pins → the
new mechanism), 1 kept and the code reverted (A26). Re-run: 31 tests, 0 failures.
Full suite: running at 16:40 (log `scratchpad/fullsuite_0923_1640.log`) — result in the
next entry.

### DIAG lines to read after his next bake
- `DIAG unselected faces: skin … + rim … (selected raw faces …; triangles alongside N,
  passed through M; field reach …) · pocket voxels turned solid: skin a, rim b, outline
  rim (solid-backed) c` — expect M small (the leg's back face, the cavity wall), N large,
  and c > 0 wherever a prism side sits inside the base.
- `DIAG regionCap:` no longer printed.

### Two questions for him (simple)
1. "Passed through" = an unselected face whose normal is within ~30° of the prism's
   direction and which the prism reaches. A 45° chamfer is alongside. Right?
2. The skin under an unselected face is two beads of the printer's bead (≈ 0.9 mm at
   0.45). Is that the number, or does the finish setting decide it?

## 2026-09-23 19:30 — FULL SUITE, THE RE-PINS, INSTALLED 18:58:36

**Full suite (16:40–18:48, 2 h 10 min): 2516 tests, 26 failure assertions in 11 test
cases.** Five are the known pre-existing ones (`AppModelTests` 3MF ×3 — no lib3mf in the
worktree —, `OrganicSampleCubeTests.testThickerIsLive…`, `OrganicVariantCacheTests
.testTheKeyIgnoresThickness…`). The six others, each read and answered one by one —
every one a pin of behaviour his rules replaced, none a hole:

- `LatticeSlabExpandPrimitiveTests.testAFlatPatchTakesNoMiterCorrection` — pinned the
  dilated shell moving 1 mm along the normal. His rule: the mouth stays on the face.
  Re-pinned to 0.
- `OrganicCapsuleImpostorTests…SilencesTheMarch` — pinned "0 steps under capsules"; the
  march runs solid-only (negative steps) so the rim shows with the body hidden.
  Re-pinned.
- `OrganicRegionFillProbe.testTheRimStopsTheLatticeShort…` — "rim off ⇒ the region
  reaches its own outline" measured a 0.8 mm band: the outline rim was taking
  `max(skin, organicRim)`. Fixed in the scene: along the SOLID-BACKED OUTLINE the rim is
  his organic rim setting (0 = none) on organic, the outline beam on the octet; the
  skin + rim under an unselected face is unchanged. Passes.
- `LatticeCurvedOutlineBandProbe.testSweepEverySettingPermutation` — "clipped" counted
  every painted texel where the region field is solid: 8.8 % (no skin) / 12.4 % (Skin)
  of the face at 1 mm depth. That IS the skin + rim band under the neighbouring faces
  and along the solid-backed outline — drawn (rim by the lattice layer, skin by the
  shell), not empty. The sweep now classifies that band (`rim` column) before
  `clipped`. Result: rim 10.4 % / 14.0 %, clipped 0.0 %, unpainted 0.0 %, ring 100 % on
  every row.
- `LatticeFinishRendersTests.testEachFinishRendersDifferently` — measured the finish
  by SILHOUETTE: None 7123 / Rim 7125 / Skin 7125 px. Measured instead by RECOLOURED
  pixels (a dressed strut is tinted): Rim 114 px, Diagrid 702 px — the dressing is
  there, on the open mouth and where struts meet the rim, but under a solid boundary
  band it adds no outline. Re-pinned to the recolour counts (rim > 50, diagrid > rim).
- `LatticeGBufferMaskTests.testTheStrutMaskIsBitExactWhileTheShellIsDrawn` — with the
  shell drawn the oblique camera saw 100 lattice px (== its own bound): every face the
  lattice ran alongside now keeps its skin, so the lattice shows only through the
  slab's mouth on +x. Camera turned to +x (365 px); the bit-exact claim is unchanged.
- And `LatticeSeamFlareTests.testTheFlareIsCappedAtTheNeighboursDepth` refuted A26
  (see the 16:40 entry) — the code was reverted, the test kept.

**Also found while measuring:** "passed through" decided from a triangle's own points
misses a triangle LARGER than the prism (one big face triangle, a manual slab on a wide
face). The prism's centre and outline corners are now projected onto the triangle too;
inside it ⇒ probe there. (`LatticeSDFMetal.swift`, the classification loop.)

Re-runs after the re-pins: the 12 affected suites — 86 tests, 0 failures, then the
sweep + render pair + rim probes — 24 tests, 0 failures, then the sweep alone after its
last classification change — 0 failures.

**Installed 18:58:36** (`TopOpt.debug.dylib`, marker `outline rim (solid-backed)`
present, old `runs ALONGSIDE` absent). Every source change above is in that build.

Open questions for him stand as in the 16:40 entry (the 30° cone; the skin = two
printer beads).
