# Lattice rebuild — the rules (stage A)

Working draft 1, 2026-11-10, LatticeReview. Companion to `00-proposal.md`.

Each rule below is something the layout must do. Where the rule is the maintainer's, his words and the date are given, with the place in today's code where they are recorded. A ledger of every dated ruling comment in the lattice code (526 entries, verbatim) is being worked through; this draft holds the rules that decide geometry. Rules about the look of panels and legends are not in scope here.

Status of each rule: **his** (a ruling of his), **agreed** (settled on 2026-11-10 for the rebuild), **proposed** (mine, for him to accept or change).

Section 8 lists the places where two rulings pull against each other. Those need his answer before stage B.

---

## 1. Where lattice goes

| # | Rule | Status and source |
|---|---|---|
| D1 | Lattice goes wherever it is asked for. Whether a wall is latticed never depends on whether a stress result has arrived. | his, 2026-08-21: "The rule is we lattice *WHEREVER* it is asked of us" (`LatticeSDFMetal.swift:2263`) |
| D2 | A prism under a face turns existing solid into lattice. It never adds material. | his: "the face-prism only makes what's solid into lattice, it cannot make walls thicker" (`LatticeRegionMask.swift:70`) |
| D3 | The lattice is laid out past the prism and then cut by it, so cells at the edge are whole cells cut, not cells left out. | his, 2026-08-27: "extend the lattices out beyond the face-prism, then use the prism to cut off the excess" (`LatticePreviewOccupancy.swift:808`) |
| D4 | Start from All lattice: one layout for the whole part. | his, 2026-11-10 (ruling 2) |
| D5 | Protect skin keeps solid to exactly the depth stated. 0 mm means lattice right up to the skin. | his, 2026-10-26 ("exact Protect") and 2026-11-10 (ruling 3) |
| D6 | Where two prisms overlap, the nearer face owns the space; on the same face plane the deeper one; then the earlier one. No lattice beats Lattice. | reviewer's ruling 4, 2026-10-07, and plan note 22 (`stepped_plan.hpp`) |
| D7 | Nothing is ever built inside a pocket to close it: no wall, plate, cap or beam. The far end of a prism inside material is the part's own solid. | his, 2026-09-23, rule R7 (`LatticeSDFMetal.swift:2712`) |
| D8 | Where a wall cannot hold lattice it goes solid. It is never left as a hole. | his, 2026-08-20: "Go solid" (`LatticeMeasuredRegionWidth.swift:113`) |
| D9 | The edge of the lattice is the part's true surface, measured on the mesh. | agreed, 2026-11-10 |

## 2. Cell size

| # | Rule | Status and source |
|---|---|---|
| C1 | Largest cells, fewest cells, everywhere. The smallest cells go only where no larger cell fits, and as few of them as possible. | his, 2026-09-14: "Always aim for the largest possible cell size because we want to use as FEW CELLS AS POSSIBLE … The smallest cells go in the areas none of the larger cells can go … and as little as possible." (`LatticeOctreeBake.swift:5`) |
| C2 | A cell is never wider than the wall it sits in. On a 12 mm wall the cell is 12 mm, not 13. | his, 2026-08-24: "I'd rather it never overshoot — that a 13mm cell never be on a 12mm wall; instead have a 12mm cell on the 12mm wall" (`LatticeRegionCells.swift:92`) |
| C3 | Aesthetic: a wall holds lattice at 2 cells across, always, whatever the stress. | his, 2026-08-21: "always lattice at 2 cells/member max" (`LatticeStageMode.swift:112`); confirmed 2026-11-10 (ruling 1) |
| C4 | Allow single-cell members (Aesthetic only): a wall may hold one cell across, and that cell is the largest that fits. It needs a finish that ties the cut struts. | his, 2026-08-22 and 2026-08-26: "single-cell/member means make the largest single cell across the entire model" (`LatticeSettings.swift:2255`, `:2285`) |
| C5 | Structural: the engine's certified number of cells across a wall (5 today). Below it the wall is solid. | reviewer, 2026-11-10 |
| C6 | Stepped divides a wall into whole cells: the wall over 1, 2, 3 … Any divisor is allowed. | his, 2026-08-26 (`LatticePreviewOccupancy.swift:1040`). **To confirm:** his words there are "any number but 1/2 is ok"; I read this as "not only halves". |
| C7 | Default Grade halves: S, S/2, S/4 … down to the printable floor. | his, 2026-10-02, ruling 4 (`LatticeSettings.swift:2366`) |
| C8 | Once a cell would be smaller than the printable floor, that space is solid. | his, 2026-08-28: "Once you hit the printability floor go solid." (`LatticeSDFMetal.swift:2781`) |
| C9 | The layout is centred on the part, so a symmetric part gets a symmetric layout. | proposed |
| C10 | Manual: minimum cells across a wall, cell size per zone or region, layout anchor and angle, and the largest size step between neighbours can each be set. | agreed, 2026-11-10 (Manual controls 2 to 4) |

## 3. Density and strut width

| # | Rule | Status and source |
|---|---|---|
| R1 | The density belongs to the cell. The run builds each cell at the density the layout gave it and adds nothing of its own. | reviewer's ruling C, 2026-09-18 (`stepped_plan.hpp`) |
| R2 | Octet's automatic densities stay under the open-look ceiling: a strut no wider than a fifth of its cell. Allow quilt lets the hand-set densities go past it. | his, 2026-09-12 (`LatticeSettings.swift:2293`) |
| R3 | The grade to shape is exempt from that ceiling. | his: "leave the grade to shape alone" (`LatticeSDFMetal.swift:1271`) |
| R4 | Minimize plastic has no effect on the lattice. | his, 2026-09-12: "minimize_plastic on/off should not have any bearing on the lattice whatsoever" (`LatticeSDFMetal.swift:1221`) |
| R5 | A strut is never thinner than one bead, measured across the flats of the strut actually written. | agreed, 2026-11-10 |
| R6 | Uniform density is one density for the whole part. Per-region density is sent only in Per region mode. | proposed (fixes two review findings) |
| R7 | By stress: density runs between "Grade from" and "Grade to". Both ends reach the layout. | proposed (today neither end is sent) |
| R8 | Manual: strut width from → to in mm, grade response and target stress, and which loads drive the grade can each be set. | agreed, 2026-11-10 (Manual controls 1, 5, 6) |

## 4. Grade to shape

| # | Rule | Status and source |
|---|---|---|
| G1 | Cells get smaller as they approach the outline, so the lattice fits the shape of the face. Distance is measured to the edge of the region being latticed, not to the part's outside. | his, 2026-08-22: "Distance to the boundary, getting smaller as it gets closer to the boundary to be able to create the shape of the lattice that perfectly fits the face/prism." (`LatticeBoundaryDistance.swift:6`) |
| G2 | The Band is how far in from the outline the cells take to climb from the finest cell back to the region's own cell. At 0 the outline stays and whatever cells fit are laid. | his, 2026-09-14 (`LatticePreviewOccupancy.swift:1647`) |
| G3 | At its edge the lattice always goes down to the smallest printable cell. | his, 2026-09-14 (same place) |
| G4 | Strength scales how much the grade does. 0 is the default. | reviewer's ruling 2, 2026-11-06 |

## 5. Rim, skin and cut ends

| # | Rule | Status and source |
|---|---|---|
| S1 | A rim is one smooth bar bent around the whole outline of the latticed face. Not a stack of blocks. | his, 2026-09-16: "a singular beam bent around the entirety of the face-prism outline; something *inherently* smooth" (`LatticeOutlineRibbon.swift:4`); 2026-11-10: "a rim is one bar" |
| S2 | The rim runs only where the part's solid backs it, never facing air, and not along a seam between two latticed regions. | his, 2026-09-23 (`LatticeRegionMask.swift:168`) |
| S3 | A skin is many bars across the face joining the cut strut ends: a flat lattice over the lattice. It is not a solid sheet. | his, 2026-11-10 |
| S4 | Finish None: a cut strut is kept only if its end lands on another strut or on solid; a stub shorter than one strut width is dropped. Where a stepped edge is left, the app points at it and says "Rim or Skin will fix this". | agreed, 2026-11-10 |
| S5 | Where two cell sizes meet, transition struts join them so every fine node has a partner. | proposed |
| S6 | The file is one watertight solid: struts, joints, rim, skin bars and the part's solid merged. | proposed |
| S7 | Manual: skin bar width, spacing and pattern, rim width, joint fillet and overhang limit can each be set. | agreed, 2026-11-10 (Manual controls 7 to 10) |

## 6. What the app says

| # | Rule | Status and source |
|---|---|---|
| U1 | One line per setting. Anything blocked says why in one line with a one-tap fix. | his, standing |
| U2 | Never a face number. Faces are named, or shown coloured on the part. | his, standing |
| U3 | A setting either changes the layout or is not on the page. | agreed, 2026-11-10 |
| U4 | Trapped lattice: a notice that highlights where. No drain-hole setting for now. | his, 2026-11-10 |
| U5 | Auto shows what a maker needs; Manual shows every value the layout uses. | his, 2026-11-10: "Auto is for makers. Manual is for engineers." |

## 7. Speed

| # | Rule | Status and source |
|---|---|---|
| P1 | The preview never waits for a run. The layout runs on the device. | agreed, 2026-11-10 |
| P2 | Dragging a slider stays smooth. A one-time wait when a part opens or a region changes is acceptable if that is all that can be managed. | his, 2026-11-10 |
| P3 | The user's own part is shown on the Lattice page only if the layout follows every setting instantly; otherwise the sample. | his, 2026-11-10 |

## 8. Where rulings pull against each other — his to settle

1. **What sits at the outline under Grade to shape.** On 2026-09-14 grade to shape was "a solid outline wrapping the lattice", with the finest cells against it. On 2026-11-10 a rim is one bar, a skin is bars, and with Finish None struts are simply cut. So: is the solid outline of 2026-09-14 now the Rim, present only when Finish is Rim? Or does Grade to shape always bring its own outline bar whatever the Finish?
2. **G3 against C1.** "Always down to the smallest printable cell at the edge" puts a band of the finest cells along every outline. "Fewest cells, smallest only where nothing larger fits" argues against it now that struts are cut cleanly at the true surface. Proposed: fine cells at the edge only when Grade to shape is on; with it off, large cells are cut at the surface.
3. **"A finish is a look, not a repair."** That was the rule while a shell did the holding (`LatticeSettings.swift:640`). In the rebuild the rim and skin are what hold the cut ends, so the finish becomes part of the structure. Proposed: retire the old sentence; the certificate counts rim and skin bars as members.
4. **C8 against D3 and D9.** "At the printability floor go solid" was written when the alternative was a cell too small to print. With clean cuts, a leftover smaller than the floor can be a cut piece of a larger cell instead of solid. Proposed: solid only where the cut piece itself is too small to print (the sliver rule); otherwise cut.
5. **C4.** Single-cell members "automatically requires finish = skin" (2026-08-22). With Finish None now having its own cut-end rule, does a single-cell wall still force Skin?

## 9. Still to do in stage A

- Work through the rest of the ledger (about 500 entries) and add any geometry rule not yet here.
- Turn each rule into a test statement with numbers (tolerances, which points are measured).
- The reference cases: settings and expected layout for the stand, Base, Top Motor Mount and Pressing Plate Mount, with a picture for each.
