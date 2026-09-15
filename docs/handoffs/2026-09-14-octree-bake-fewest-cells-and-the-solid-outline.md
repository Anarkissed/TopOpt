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

(filled in below after the full package run)
