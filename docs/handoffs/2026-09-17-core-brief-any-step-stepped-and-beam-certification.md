# CORE BRIEF — "Stepped" is ANY STEP, and it certifies as a strut network

From the app side, 2026-09-17. The maintainer approved this design in the preview
first ("Go - exclude 10 and 11, no solid strips"; "Go with tier 2"). The preview now
draws it; this brief is what core has to do so the RUN lays down the same lattice and
a structural job can certify it. Nothing here touches DOUBLED (the dyadic ladder) or
ORGANIC.

## 1. What Stepped means now (the app's rule, to be mirrored in core)

Today core's `stepped` derives ONE cell per declared region, verbatim, and lays each
region as an independent pass (run_job.cpp `run_stepped_step`, lattice_gen.hpp
`generate_lattice_stepped`). The preview and the maintainer's ruling extend it:

**A base slot the face outline cuts is PACKED, not halved.**

- Per include region: a base cell `S` (what `run_stepped_step` derives today, or the
  user's stated cell). Base cells sit on the region's anchored grid exactly as now.
- **The size menu** for that region: every `k · (S/n)` for `n = 2…6`, `k = 1…n−1`,
  keeping only families whose tile `S/n` is (a) at or above the printable floor and
  (b) "prints open" — a bead-wide strut in a tile of that size is at or under 20 %
  relative density (`octet` law; the same bound the preview's finest rung uses). On a
  12 mm base at a 0.45 mm bead that is **12, 9.6, 9, 8, 7.2, 6, 4.8, 4, 3, 2.4** (fifths
  print open at 2.4 mm; sixths at 2.0 do not, which is exactly what excludes 10 and 11
  — "exclude 10 and 11, no solid strips").
- **Depth-clean by construction**: a `k/n` cell at the face leaves `(n−k)/n` of the
  wall behind it, which the `1/n` tiles fill exactly. No solid strip is ever laid to
  make up a depth.
- **The packer** (per failed base slot, a cube of side `S` from the face plane in):
  sizes largest first; a cell of size `k·t` may start at any multiple of its own tile
  `t = S/n` inside the slot, on all three axes; depth scanned from the FACE inward;
  a cell is placed where all eight corners are inside the outline, inside material,
  and the slot's `taken` mask is free; cells never overlap and never straddle a slot.
  The finest tile then fills whatever is left, cut by the outline where it is.
  (The app: `LatticeOctreeBake.swift` `packSlot`, `steppedSizeMenu`.)
- Consequence, stated plainly: neighbouring cells of DIFFERENT families share no
  nodes. A 9's face centre lands mid-strut on an 8's face. That is what Stepped IS
  (lattice_algorithm.hpp already says "nodes do not line up"); the print fuses those
  crossings; certification must model them, not assume them away — see §3.

## 2. Generator changes

1. **Passes per (region, family), not per distinct size.** Today `lattice_one_variant`
   groups voxels by `cell_field[e] == pcell` and builds one pass per distinct size on a
   grid from `lattice_region_for(solved_grid, pcell, &boundary)` — i.e. every pass's
   grid is anchored at the SOLVED GRID origin. Any-step cells are anchored at the
   REGION's slot grid (the face plane along the normal, the region's anchor shift
   in-plane), on their family's tile. So a pass needs its own `LatticeRegion.origin`
   per (region, tile), and its `latticed` predicate marks the cells of that family
   that were placed. `LatticeRegion` already has `origin`, `cell_mm` and the
   per-cell `latticed` predicate; nothing structural is missing.
2. **The plan comes from the job — DECIDED (maintainer, 2026-09-18: "Send the cell
   list to core").** The app sends the placed cells explicitly; core lays down exactly
   those and does not run a packer of its own. New job key, under `lattice`:

       "stepped_cells": [
         { "region_id": 1, "origin_mm": [x, y, z], "size_mm": 9.0 },
         …
       ]

   - `region_id`: 1-based, the job's own include-region order (as `SteppedRegionCell`).
   - `origin_mm`: the cell's minimum corner in MODEL space (the same frame as
     `lattice.regions[].geometry`), the face-plane side along the region normal.
   - `size_mm`: the cell edge; cubic.
   - Thousands of entries on a real part (his stand: ~14 000 texels ⇒ ~2 000 cells);
     the array is the exact picture he approved on screen.
   - Required when `algorithm: "stepped"`; refused (schema) on any other algorithm.
   - Core VALIDATES, never repairs: each cell's size on that region's menu (§1),
     origin on the family's grid relative to the region's base grid, cube inside the
     region's prism and inside material, no two cells overlapping. A failure names
     the first offending cell (index, origin, size, reason). No silent repack.
   - Byte-identity: a job without the key and without `algorithm: "stepped"` is
     unchanged.
   - The app will emit the key as soon as core's schema accepts it (job.cpp
     `reject_unknown_keys` refuses it today), from the same bake that draws the
     preview, so the RUN and the PREVIEW are one list.
3. **Strut radius** per cell as today (`radius.field` from the posture's relative
   density); a cell's own density at its own size.
4. **Receipt.** Keep `stepped_adjacent_region_pairs / pairs_joined`; ADD per-family
   seam stats: strut ends that terminate on another strut's span (T-junctions) and
   ends that terminate on nothing (floating). After §3's contact weld the second
   number must be 0 for a certified job; report both.

## 3. Structural: certify the NETWORK, not the tensor (tier 2)

The homogenised cubic tensor assumes shared nodes; any-step seams break that, so a
tensor certificate over-claims at every seam. Core already has the right
instrument: the **beam-network certificate** built for Organic
(`beam_network.hpp`, `certify_organic_structural`, job key
`organic_structural_certification: "beam_network"`). It solves the struts directly as
Timoshenko frame elements and **welds on CONTACT**, so a strut ending on the middle
of another is fused exactly as the print fuses it — the seam is just geometry being
solved.

Recommended steps:

1. **Generalise the switch.** Accept `structural_certification: "beam_network"` for
   `algorithm: "stepped"` (keep the organic key as an alias). Under
   `intent: structural`, a stepped job that does not ask for it is REFUSED with the
   same shape of message organic gets today — the tensor certificate is not offered
   for any-step Stepped at all. (`lattice_algorithm_allows_structural` in the bridge
   currently returns true for stepped; it should return true only when this key is
   present, or the app must send it whenever stepped + structural.)
2. **Subdivide before welding.** `beam_network.hpp` is explicit: the weld is
   ENDPOINT-based, so long members crossing at mid-span are NOT fused unless the input
   arrives subdivided (~0.85 mm segments from the organic tracer). Octet struts are
   straight members up to a base cell long, so the stepped generator must emit them
   subdivided (segment ≤ ~1 bead) into the network, or the seams silently read as
   disconnected. Assert it in the certificate: number of unwelded strut ends == 0.
3. **Restraint** as for organic: ties into solid, rotational restraint check, the
   interlayer per-strut knockdown already in the certificate.
4. **What "certified" means here**: the frame solve's p99 stress margin under the
   job's load cases, exactly as organic reports it. No new tensor measurement is
   needed for any family or seam — that is the reason for choosing this tier.
5. **One decision for you**: under structural, the menu's "prints open" bound (20 %
   density, an AESTHETIC quilt rule) may be the wrong lower bound for the finest
   tile; the printability floor plus the certifiable cells-per-member regime is the
   structural one. The app will send whichever core states; say which.

## 4. Tests core should add

- Menu: 12 mm base, 0.45 bead → exactly {12, 9.6, 9, 8, 7.2, 6, 4.8, 4, 3, 2.4};
  10 and 11 absent; 10.31 base → {10.31, 7.73, 6.87, 5.16, 3.44, 2.58}.
- Depth-clean: for every menu size `s` and base `S`, `S − floor(S/s)·s` is 0 or a
  multiple of a menu tile that divides `s`.
- Schema: `stepped_cells` accepted only with `algorithm: "stepped"`; a cell off the
  menu, off its family grid, outside its region, or overlapping another is refused
  with that cell named.
- Generator: a hand-written `stepped_cells` list for a 12 mm slab (a 9 at offset 3
  with 3 mm tiles behind and beside it) is laid down verbatim — every voxel inside the
  outline belongs to exactly one listed cell or the outline solid, and the receipt's
  per-size counts equal the list's.
- Certificate: a two-family seam (9 next to 8) welds on contact with 0 unwelded
  ends; the same seam UN-subdivided must FAIL the assertion (positive control).
- Byte-identity: `doubled` and `organic` jobs unchanged.

## 5. What the app already has (for reference, not to be re-done)

`LatticePreviewOccupancy.steppedSizeMenu`, `LatticeOctreeBake.packSlot`, per-texel
cell origins (`LatticeCellField.steppedOrigin`), and the shader that draws any cell
at any origin. Preview DIAG line to compare against:
`DIAG octree pitch=2.40 kept=[12.00=40 10.31=127 9.60=24 9.00=2 8.00=5 7.73=11 7.20=2 6.87=7 6.00=8 5.16=28 4.80=4 4.00=56 3.44=112 3.00=110 2.58=9802 2.40=3652] …`
