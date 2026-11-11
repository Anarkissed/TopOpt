# Lattice rebuild — the rules (stage A)

Working draft 4, 2026-11-10, LatticeReview. Companion to `00-proposal.md`.

Each rule below is something the layout must do. Where the rule is the maintainer's, his words and the date are given, with the place in today's code where they are recorded. A ledger of every dated ruling comment in the lattice code (526 entries, verbatim) has been read in full; this draft holds every rule in it that decides geometry for cell lattices. Rulings about organic lattices are listed in section 10 and wait for the organic proposal. Rules about the look of panels and legends are not in scope here.

Status of each rule: **his** (a ruling of his), **agreed** (settled on 2026-11-10 for the rebuild), **proposed** (mine, for him to accept or change).

Section 8 held seven places where two rulings pulled against each other. He settled all seven on 2026-11-10; the answers are written into the rules and kept in section 8.

---

## 1. Where lattice goes

| # | Rule | Status and source |
|---|---|---|
| D1 | Lattice goes wherever it is asked for. Whether a wall is latticed never depends on whether a stress result has arrived. | his, 2026-08-21: "The rule is we lattice *WHEREVER* it is asked of us" (`LatticeSDFMetal.swift:2263`) |
| D2 | A prism under a face turns existing solid into lattice. It never adds material. | his: "the face-prism only makes what's solid into lattice, it cannot make walls thicker" (`LatticeRegionMask.swift:70`) |
| D3 | The lattice is laid out past the prism and then cut by it, so cells at the edge are whole cells cut, not cells left out. | his, 2026-08-27: "extend the lattices out beyond the face-prism, then use the prism to cut off the excess" (`LatticePreviewOccupancy.swift:808`) |
| D4 | Start from All lattice: one layout for the whole part. | his, 2026-11-10 (ruling 2) |
| D5 | **Protect skin** is a solid face, at exactly the depth stated, with the lattice right behind it. At 0 mm it is the thinnest face that prints (two line widths). It is for faces that must stay a real surface: mounting, contact. It is a different thing from the Finish called Skin (S3). The cells start at the skin's inner side and divide what is left of the wall (C15): the skin never cuts through a cell. A skin on the far face ends the lattice the same way. Built for flat regions; under a curved region or the whole part a skin still cuts the cells where it falls. | his, 2026-10-26 ("exact Protect"), 2026-11-10 (ruling 3), and 2026-11-10 16:41: "Protect skin is a solid sheet. The skin I mentioned is the Lattice Finish. Two different things." |
| D6 | Where two prisms overlap, the nearer face owns the space; on the same face plane the deeper one; then the earlier one. No lattice beats Lattice. | reviewer's ruling 4, 2026-10-07, and plan note 22 (`stepped_plan.hpp`) |
| D7 | Nothing is ever built inside a pocket to close it: no wall, plate, cap or beam. The far end of a prism inside material is the part's own solid. | his, 2026-09-23, rule R7 (`LatticeSDFMetal.swift:2712`) |
| D8 | Where a wall cannot hold lattice it goes solid. It is never left as a hole. | his, 2026-08-20: "Go solid" (`LatticeMeasuredRegionWidth.swift:113`) |
| D9 | The edge of the lattice is the part's true surface, measured on the mesh. | agreed, 2026-11-10 |
| D10 | A latticed region has the shape of the face it came from, never the rectangle around it. Laying less than was marked, and saying so, beats laying more in silence. | his, 2026-08-18 and 2026-08-21 (`LatticeFaceOutline.swift:2`, `LatticeRegionEmission.swift:189`) |
| D11 | Expand grows or shrinks a region in the face's plane only, either sign; 0 is exactly the face. It never changes the depth. | his, 2026-08-17: "an expand handle for all the other axis *except* the depth"; "also take a negative value" (`LatticeSlabExpand.swift:2`, `:37`) |
| D12 | Only what is set to Lattice is latticed. Everything else stays solid. | his, 2026-08-18 (`LatticeRegionMask.swift:310`) |
| D13 | Each cell has one owner, decided by where its centre is, never by the order the regions were made. Reordering walls never changes the lattice. A cell that loses a contest steps down one size on its own region's grid. | his, 2026-10-03 ("order-dependent ownership would change the lattice when he reorders walls"); reviewer's ruling 6, 2026-10-07 (`LatticeOctreeBake.swift:962`, `:1028`) |
| D14 | Space inside a region that no cell covers is solid, and is drawn solid, so a slit never looks like a hole the print does not have. The rule is applied by whoever draws or builds: a cut cell is exactly the part of its cube that is lattice of its own region and its own wall, and lattice space in no cell's shape is solid. The layout's own list of such places is complete only to its sample points (strips under about a millimetre can be unlisted). | reviewer, 2026-10-11, item 2 (`LatticeSettings.swift:1026`) |
| D15 | Protect skin and Lattice on the same face are one slab with one depth. | his, 2026-09-30, ruling 2 (`ProjectModel.swift:836`) |
| D16 | Nothing is printed inside a Keep clear. The part's own solid wins over a Keep clear. | reviewer, 2026-11-03 19:55 (`run_job.cpp:770`) |
| D17 | Material a design box added is solid. The lattice is laid around it, not through it. | reviewer, 2026-11-03 23:05 (`run_job.cpp:7273`) |
| D18 | The same part and settings give the same layout, byte for byte, on every launch. | his, 2026-09-30, ruling 1 (`LatticeFaceOutline.swift:46`) |
| D19 | Start from is the rule for everything a zone, a face-prism or a protection does not cover. Under All lattice a face-prism only changes solid to lattice settings; shrinking it with a negative Expand leaves lattice behind, not solid. Only a No lattice region makes solid inside a lattice. | his, 2026-11-10: "The base setting is always the rule for anything NOT covered by a zone or face-prism or protection." |
| D20 | A face-prism works on a curved face, and on several faces joined into one. Curved: the region follows the face inward by the depth and stops at the face's own outline. Joined: one region, one depth, one outline, no seam between the faces. | his, 2026-11-10: "We definitely need to implement curved face-prisms - as well as unioned ones." |

## 2. Cell size

| # | Rule | Status and source |
|---|---|---|
| C1 | Largest cells, fewest cells, everywhere. The smallest cells go only where no larger cell fits, and as few of them as possible. | his, 2026-09-14: "Always aim for the largest possible cell size because we want to use as FEW CELLS AS POSSIBLE … The smallest cells go in the areas none of the larger cells can go … and as little as possible." (`LatticeOctreeBake.swift:5`) |
| C2 | A cell is never wider than the wall it sits in. On a 12 mm wall the cell is 12 mm, not 13. | his, 2026-08-24: "I'd rather it never overshoot — that a 13mm cell never be on a 12mm wall; instead have a 12mm cell on the 12mm wall" (`LatticeRegionCells.swift:92`) |
| C3 | Aesthetic with single-cell walls switched off: a wall holds lattice at 2 cells across, always, whatever the stress. | his, 2026-08-21: "always lattice at 2 cells/member max" (`LatticeStageMode.swift:112`); confirmed 2026-11-10 (ruling 1) |
| C4 | Allow single-cell members (Aesthetic only), on unless he switches it off: a wall may hold one cell across, and that cell is the largest that fits. It does not force a finish: Finish None stays allowed (S4), with the warning of U13. A project saved with the switch off keeps it off. | his, 2026-08-22 and 2026-08-26: "single-cell/member means make the largest single cell across the entire model" (`LatticeSettings.swift:2255`, `:2285`); on by default, his, 2026-11-11: "Yes, set single-cell on" |
| C5 | Structural: the engine's certified number of cells across a wall (5 today). Below it the wall is solid. | reviewer, 2026-11-10 |
| C6 | Stepped packs a base cell S with cells of any whole fraction of it, not only halves: every k × (S/n) for n = 2 to 6, plus S itself. A 12 mm cell may go 9 + 3 or 3 + 3 + 3 + 3. Default Grade stays halves (C7), so the two never look the same. | his, 2026-08-26 (`LatticePreviewOccupancy.swift:1040`) and 2026-11-10: "Stepped is ANY denomination. So if the cell size is 12, it can go 10/2 or 9/3 or 3/3/3/3." The menu is `stepped_plan.hpp` (ruling 2026-09-17). |
| C6a | A fraction is allowed only if its smallest tile prints open (C14: 5.27 × bead, 2.37 mm at 0.45). At a 0.45 mm bead a 12 mm cell may use halves, thirds, quarters and fifths (2.4 mm); sixths (2.0 mm) are out, and with them 10 + 2. A wider base or a finer bead lets them back in. | reviewer, 2026-10-10 and 2026-11-02 (c) (`stepped_plan.hpp:16`) |
| C6b | A cell at the face leaves the rest of the wall to tiles of the same fraction, which fill it exactly. No solid strip is laid to make up a depth. | his, 2026-09-17 (`stepped_plan.hpp:10`) |
| C6c | One base cell is packed from one family: a smallest tile and the sizes that are whole numbers of it, each started on a multiple of it. Of the families that fit, the one covering most of the space wins, then the one with fewest cells. | reviewer, 2026-10 (`LatticeOctreeBake.swift:1480`); his rule C1 |
| C7 | Default Grade halves: S, S/2, S/4 … down to the printable floor. | his, 2026-10-02, ruling 4 (`LatticeSettings.swift:2366`) |
| C8 | A leftover smaller than the printable floor is a cut piece of the larger cell beside it. It is solid only where that cut piece is itself too small to print. | his, 2026-08-28: "Once you hit the printability floor go solid." (`LatticeSDFMetal.swift:2781`); narrowed by him 2026-11-10 (section 8, item 4) |
| C9 | The layout is centred on the part, so a symmetric part gets a symmetric layout. | proposed |
| C10 | Manual: minimum cells across a wall, cell size per zone or region, layout anchor and angle, and the largest size step between neighbours can each be set. | agreed, 2026-11-10 (Manual controls 2 to 4) |
| C11 | A wall's width is the thickness of the material at that spot, measured along the region's own direction. It is never the region's depth, and a corner where two walls meet is not a thick wall. | his, 2026-08-20 ("the walls here are *exactly* 20mm wide. That's 4mm cells 5x wide"), 2026-08-23, 2026-08-24: "it should read the actual depth of that area. so preferably per voxel" (`LatticeMeasuredRegionWidth.swift:4`, `:345`, `:414`) |
| C11a | The number of cells a wall must hold (1, 2 or 5 across: C3 to C5) is counted across the wall's NARROWEST width, whichever way that lies. The width along the region's own direction (C11) only divides the cells. A rib one cell wide across the face and two deep is one across, not two. An inside corner, where a step or a rib meets a wall, is not a narrow place. | reviewer's ruling, 2026-11-11 08:04Z: "the cells-per-member FLOOR, the 1/2/5 across, must use the member's NARROWEST width: the inscribed ball ... Otherwise a rib one cell wide across the face but two deep passes as two across, and in Structural that certifies a thin member as thick." Read today with the layout's own thickness measure; LatticeTypes' `lattice_member_width_mm` is on no pushed branch yet. |
| C12 | Stepped: the cell at each spot fits the smaller of the region's depth and the material there, in both directions. A thinner spot gets a smaller cell; a thicker spot gets a larger one, but only where the material is thick over a full cell in every direction. A corner takes the cell of the walls that meet there. | his, 2026-08-25 (`LatticePreviewOccupancy.swift:1439`); corners settled 2026-11-10 (section 8, item 7) |
| C13 | Stepped: a space the outline cuts is packed, not halved. Several sizes, largest first; the finest fills what is left. The sizes offered always fill the depth exactly, so no solid strip is laid to make up a depth. | his, 2026-09-17 (`stepped_plan.hpp:5`) |
| C14 | The printable floor follows the print settings. The thinnest strut is one line width. The smallest cell that still prints open is 5.27 line widths (2.37 mm at 0.45 mm). | his, 2026-08-19: "It should be based on the printing parameters"; reviewer, 2026-10-10 and 2026-11-02 (c) (`LatticeType.swift:162`, `stepped_plan.hpp:61`) |
| C15 | A face cuts the cells on a cell boundary, which leaves open cells, never through the middle of a cell, which leaves a quilt of strut ends. | his, 2026-08-23 (`LatticeSDFMetal.swift:3256`). Done per wall: the cells divide each wall exactly, so both its faces land on boundaries; transition struts (S5) join walls with different divisions. Settled 2026-11-10 (section 8, item 6). |
| C16 | Cell size Auto means any size the stress asks for, place by place. Only Manual forces one size through the whole lattice. | his, 2026-08-19 and 2026-08-20: "Auto should also mean GRADED" (`LatticeSettings.swift:2876`, `LatticeAutoPosture.swift:63`) |
| C17 | Default Grade: the starting cell is the largest whole-number fit whose halves end at the printable floor, and it is taken only if it covers at least as much of the wall as the plain fit. | reviewer with his approval, 2026-10-11 (`LatticeRegionCells.swift:153`, `LatticeOctreeBake.swift:408`) |
| C18 | Structural: a wall too thin for the certified count keeps its lattice if it is barely loaded (Unloaded walls). This switch is not shown in Aesthetic. | his, 2026-08-20: "Why does that rule exist for a wall that does not need to certify?"; 2026-08-24 (`LatticePreviewOccupancy.swift:2254`, `LatticeSetupWizard.swift:268`) |

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
| R9 | What a lattice looks like is set by one number, strut width over cell size. At 0.20 the windows are half open (the ceiling of R2). At 0.354 neighbouring struts touch: the quilt. The top of the density range is the quilt, never solid. | his, 2026-08-24: "saying the max is solid is wrong. The max is the quilt"; 2026-09-12 (`LatticeType.swift:182`, `:247`) |
| R10 | The density dial is even steps of strut width, not of density. 1% is the thinnest strut that prints, 100% is the quilt (the open look of R2 unless Allow quilt is on, so no part of the dial is dead). It is read on the largest cell; smaller cells keep the same strut ÷ cell, never thinner than one line. Auto sits at 45%. | his, 2026-08-25: "Make 1% be the printability floor. Make 100% be the quilt" (`ProjectModel.swift:1131`) |
| R11 | A strut width that was typed in is the width everywhere a cell can hold it. A cell too small for it takes the widest strut it can (R2, R9), and the app says how many. | his, 2026-08-19 and 2026-09-10 (`LatticeSettings.swift:2022`, `run_job.cpp:6216`) |
| R12 | Under By stress the stress decides every strut. Hand-set densities are greyed, and a number the app derived never overrides the stress. | his, 2026-08-20 ("That 17% and 25% was automatically input, I never typed it") and 2026-08-25 (`LatticeSDFMetal.swift:572`, `WorkspacePlaceholder.swift:11897`) |
| R13 | The strut written to the file holds the same material as the round strut the strength numbers were measured on. | reviewer, 2026-11-02 (b) (`lattice_gen.cpp:433`) |

## 4. Grade to shape

| # | Rule | Status and source |
|---|---|---|
| G1 | Cells get smaller as they approach the outline, so the lattice fits the shape of the face. Distance is measured to the edge of the region being latticed, not to the part's outside. | his, 2026-08-22: "Distance to the boundary, getting smaller as it gets closer to the boundary to be able to create the shape of the lattice that perfectly fits the face/prism." (`LatticeBoundaryDistance.swift:6`) |
| G2 | The Band is how far in from the outline the cells take to climb from the finest cell back to the region's own cell. At 0 the outline stays and whatever cells fit are laid. | his, 2026-09-14 (`LatticePreviewOccupancy.swift:1647`) |
| G3 | With Grade to shape on, the lattice goes down to the smallest printable cell at its edge. With it off, G7 applies. Grade to shape grades cells only; it brings no outline bar of its own. The bar is the Rim (Finish: Rim). | his, 2026-09-14 (same place); settled 2026-11-10 (section 8, items 1 and 2) |
| G4 | Strength scales how much the band thickens its struts toward the quilt (2 to the power of Strength, −1 to 1). 0 is the default. It moves no cell. | reviewer's ruling 2, 2026-11-06 |
| G5 | The distance is measured in the plane of the face, to the face's outline. The thickness direction is left out. | his, 2026-08-23: "in-plane distance to the face outline. I mean the shape of the face not the thickness as that is already covered by the floor" (`LatticeBoundaryDistance.swift:35`) |
| G6 | With Grade to shape on, the cells break down to the smallest printable cell before anything goes solid. No other limit on the number of steps. | his, 2026-08-27: "It needs to break into smaller cells before it can become solid." (`LatticePreviewOccupancy.swift:851`) |
| G7 | With Grade to shape off, a cell at the edge is simply cut where the region ends. | his, 2026-08-27: "if it's not applied, the cell should just be cut off where it ends" (`LatticeRegionMask.swift:54`) |
| G8 | As the cells shrink toward the outline the strut keeps at least its thickness, and is raised toward the quilt as it nears the outline (the run's band law of 2026-11-06, in whole lines), so the lattice gets denser until it meets solid. The strut never gets thinner toward the edge. | his, 2026-09-05: "why aren't they the same thing?" (grade to shape and grade to solid; `run_job.cpp:6396`); reviewer's ruling 2, 2026-11-06 (`grading.hpp:506`) |
| G9 | The fit reads the whole outline, open edges included. Only the rim is limited to edges backed by solid (S2). | his, 2026-08-24 (`LatticePreviewOccupancy.swift:960`) |
| G10 | With Grade to shape on, only the smallest cell may be cut by the outline. A larger cell that the outline would cut is replaced by smaller ones. The region's own cell keeps its centre a whole Band inside the outline, the sizes between a proportional share, the smallest at the outline; within one base cell the larger cells take the places farthest from the outline. | his, 2026-09-15: "if a larger cell has 1/2 its body in the graded area it is ok, anything more than 1/2 it needs to be split up" (`LatticeOctreeBake.swift:1367`, cells stay whole: `:1032`); his, 2026-11-11: "The large cells are cut off, themselves, rather than having some amount of space where it allows smaller cells to replace the cell if a full cell isn't going to fit." |
| G11 | OPEN, his to pick (asked 2026-11-11): how many sizes the band may use. Today the smallest cell in a band is the smallest that prints open (C14), so a 7 mm cell on a 0.45 mm line has two sizes (7 and 3.5; a third, 2.33, misses the floor of 2.37 by 0.04 mm). Built as a switch that is off: inside the band only, cells may go down to the smallest cell one line draws without closing it (2.83 line widths, 1.27 mm at 0.45). He asked for "multiple size differences ... the more the better". | his, 2026-11-11; R3; G3; G6 |

## 5. Rim, skin and cut ends

| # | Rule | Status and source |
|---|---|---|
| S1 | A rim is one smooth bar bent around the whole outline of the latticed face. Not a stack of blocks. | his, 2026-09-16: "a singular beam bent around the entirety of the face-prism outline; something *inherently* smooth" (`LatticeOutlineRibbon.swift:4`); 2026-11-10: "a rim is one bar" |
| S2 | The rim runs only where the part's solid backs it, never facing air, and not along a seam between two latticed regions. | his, 2026-09-23 (`LatticeRegionMask.swift:168`) |
| S3 | **Finish: Skin** is many bars across the face joining the cut strut ends: a flat lattice over the lattice. It is open and does not seal. It is a different thing from Protect skin (D5), which is solid. | his, 2026-11-10: "a skin is multiple bars connecting the lattice struts, creating a 2D lattice across the outer wall" |
| S4 | Finish None: a cut strut is kept only if its end lands on another strut or on solid; a stub shorter than one strut width is dropped. Where a stepped edge is left, the app points at it and says "Rim or Skin will fix this". | agreed, 2026-11-10 |
| S5 | Where two cell sizes meet, transition struts join them so every fine node has a partner. | agreed, 2026-11-10 (section 8, item 6) |
| S6 | The file is one watertight solid: struts, joints, rim, skin bars and the part's solid merged. | proposed |
| S7 | Manual: skin bar width, spacing and pattern, rim width, joint fillet and overhang limit can each be set. | agreed, 2026-11-10 (Manual controls 7 to 10) |
| S8 | Finish defaults to None. A rim or a skin is something the user adds. | his, 2026-08-14: "it should default to 'none'" (`LatticeSettings.swift:2472`) |
| S9 | Finish: Covered is a solid outer shell over the lattice, for anyone who does not care to see it. | his, 2026-08-19 (`LatticeSettings.swift:30`) |
| S10 | By default the rim is only as thick as the printable floor. Everything before it is graded. | his, 2026-09-08: "the rim should only ever be as thick as the printability floor" (`LatticeSettings.swift:1613`); for cell lattices the bar is two line widths (reviewer's ruling B, 2026-09-18, `job.hpp:639`) |
| S11 | Struts run on into the solid they meet and are trimmed by the part, so nothing stops short of the wall and nothing sticks out of it. | his, 2026-09-08: "boolean them together and then just remove anything that goes beyond the solid" (`organic_lattice.hpp:1899`); reviewer, 2026-10-10: the outline cuts the struts (`lattice_boundary.hpp:323`) |

## 6. What the app says

| # | Rule | Status and source |
|---|---|---|
| U1 | One line per setting. Anything blocked says why in one line with a one-tap fix. | his, standing |
| U2 | Never a face number. Faces are named, or shown coloured on the part. | his, standing |
| U3 | A setting either changes the layout or is not on the page. | agreed, 2026-11-10 |
| U4 | Trapped lattice: a notice that highlights where. No drain-hole setting for now. | his, 2026-11-10 |
| U5 | Auto shows what a maker needs; Manual shows every value the layout uses. | his, 2026-11-10: "Auto is for makers. Manual is for engineers." |
| U6 | A lattice type the engine cannot build is refused by name. It is never drawn or built as another type. | his, 2026-10-02 (`LatticeType.swift:368`) |
| U7 | A wall the job leaves out is named. Never a silent drop. | reviewer's ruling V1, 2026-09-29 (`LatticeRegionEmission.swift:732`) |
| U8 | A setting that is hidden does not act. | his, 2026-09-29, ruling 2 (`LatticeSettings.swift:2122`) |
| U9 | Aesthetic never shows a strength warning. | his, 2026-08-25: "'Won't certify — tap for the fix' must not show in aesthetic" (`WorkspacePlaceholder.swift:10715`) |
| U10 | Nothing on screen covers the lattice being looked at. | his, 2026-09-07: "NEVER OBSTRUCT THE VIEW OF THE LATTICE" (`LatticeSDFMetal.swift:1466`) |
| U11 | Structural or Aesthetic is chosen once, when the Lattice stage opens. | his, 2026-08-21 (`LatticeStageMode.swift:2`) |
| U12 | Every number can be typed on a keypad as well as dragged. | his, standing (`WorkspacePlaceholder.swift:10966`) |
| U13 | Finish None is allowed everywhere but the app strongly recommends against it, most of all on a single-cell wall. One plain line says so, with a one-tap switch to Rim or Skin. | his, 2026-11-10: "I think it should be strongly recommended not to use finish: none." |

## 6b. What a run may claim

| # | Rule | Status and source |
|---|---|---|
| V1 | The strength check judges the lattice that is in the file, after every cut and repair. It never counts material the file does not have. | his, 2026-09-11 ("fix the timing first"; `run_job.cpp:10697`); reviewer, 2026-11-02 (`lattice_volume_check.hpp:2`, `:121`) |
| V2 | A check that did not run is not named in the job or the result. | his, 2026-10-02, ruling 3 (`LatticeSettings.swift:1363`) |
| V3 | A run that ends with no lattice refuses. It does not report success over nothing. | reviewer, 2026-10-07 (`run_job.cpp:9223`) |

## 7. Speed

| # | Rule | Status and source |
|---|---|---|
| P1 | The preview never waits for a run. The layout runs on the device. | agreed, 2026-11-10 |
| P2 | Dragging a slider stays smooth. A one-time wait when a part opens or a region changes is acceptable if that is all that can be managed. | his, 2026-11-10 |
| P3 | The user's own part is shown on the Lattice page only if the layout follows every setting instantly; otherwise the sample. | his, 2026-11-10 |
| P4 | The picture is never half updated: new geometry is not drawn with the old cells. | his, 2026-08-23: "can you make it so the quilt *never* comes up?" (`LatticeSDFMetal.swift:2672`) |
| P5 | If a change cannot be shown at once, something on screen shows that it is working. | his, 2026-08-19 (`WorkspacePlaceholder.swift:139`) |
| P6 | For cell size, anchor and angle on fine cells, the layout is rebuilt when the finger lifts or a typed number is confirmed, within about a second. Density and strut-width sliders stay smooth (P2). | his, 2026-08-21 and 2026-08-25 (`WorkspacePlaceholder.swift:3200`, `:789`); confirmed 2026-11-10 on the stage 0 numbers: "Yes, acceptable" |

## 8. Where rulings pulled against each other — settled by him, 2026-11-10

1. **The outline under Grade to shape.** The solid outline of 2026-09-14 is withdrawn. His words: "Disregard this. I was thinking too narrow and couldn't think beyond my specific use case." Grade to shape grades the cells; the bar is the Rim and appears only when Finish is Rim (G3). *My reading of "disregard"; to be corrected if he meant otherwise.*
2. **Fine cells at the edge.** Agreed: only when Grade to shape is on. With it off, large cells are cut at the surface (G3, G7).
3. **"A finish is a look, not a repair."** Agreed: retired. Rim and skin bars hold the cut ends and the certificate counts them as members.
4. **Solid at the printable floor.** Agreed: solid only where the cut piece is itself too small to print; otherwise the larger cell is cut (C8).
5. **Single-cell walls and Skin.** A single-cell wall does not force Skin. Finish None is strongly recommended against (C4, U13). Single-cell walls are on by default in Aesthetic (2026-11-11).
6. **Faces on cell boundaries.** Agreed: each wall's cells divide that wall exactly; transition struts join walls with different divisions; the layout is centred per wall (C15, S5).
7. **Thick spots and corners.** Agreed: a corner takes the cell of the walls that meet there; a larger cell only where the material is thick over a full cell in every direction (C12).

Stepped against Default Grade (the C6 check): settled the same day. Default Grade is halves; Stepped is any fraction (C6 to C6c).

## 9. Still to do in stage A

- Done in `02-tests.md`: a test statement with numbers for each rule.
- The reference cases: settings and expected layout for the stand, Base, Top Motor Mount and Pressing Plate Mount, with a picture for each.

## 10. Set aside for the organic proposal

The ledger holds about 60 rulings on organic lattices (2026-09-02 to 2026-10-08). They are not rules for cell lattices and are not written out here. The ones that will carry over as they stand:

- Without a simulation an organic lattice can only fit the shape (2026-09-05).
- "Fit to shape means grade to solid at the edges. Always. And always on the sides" (2026-09-06).
- Struts continue through into the solid and blend into it "as though they are being wetted by a liquid layer" (2026-09-08).
- A stated strut width is the width everywhere (2026-09-10).
- A wall is dead or it is not, as a whole; the engine decides which, never the app (2026-09-18, 2026-09-29).
- Synthetic stresses only on unloaded walls, Aesthetic only, simulation on (2026-09-05, 2026-09-29).
- Repairs that add or remove material to help printing are off unless asked for (2026-09-08).
