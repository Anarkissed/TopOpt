# Stage 1: true loads, anchors and protection depth (TOReview)

Branch `claude/topopt-review-rebuild-3c317f`. Status: IN PROGRESS. Nothing here is released; everything is behind ONE switch, `TOPOPT_FACE_LOADS` (`to_stage_switch.hpp`): unset or `voxel` = today, unchanged; `face` = loads, anchors and depths from the drawn face; `face_spring` = the same with anchors held by springs in proportion to area. `TOPOPT_PAD_MM` sets the pad depth (default 3 mm).

## THE STAGE REPORT (draft, 2026-11-25 23:10; sent to the reviewer when the three lock runs marked OWED are in)

**What changes for him.** A force lands on the face he picked, over that face's real area, wherever the grid falls; a face he fixed is held on that face; a protected skin is as deep as the millimetres he typed. Today all three depend on where the voxel grid happens to sit.

**The evidence, one line each (tables below).**
1. Loaded area and centre, 18 grid alignments: today up to 13 % off and nothing loaded at all in 6 of 18; new, exact in 18 of 18. Protection depth: today up to a whole voxel off; new within 0.05 voxel.
2. Base as drawn, res 48 to 192: today 0.67 / 0.18 / 0.40 / 0.17 / 0.30 / 0.08 (a factor of eight, up and down); new 0.79 / 0.66 / 0.45 / 0.37 / 0.37 / 0.32. Pressing and Top Motor Mount, whose faces sit well in the grid, do not move (the control). PillowBlock reads LOWER than today at every resolution: today's one-voxel-thick clamp flattered it.
3. Bolt bearings on Base: today 0.56 / 0.04 / 0.27 at res 48 / 64 / 96; new 0.64 / 0.50 / 0.33.
4. The stand optimised: OWED on the corrected clamp (with the old clamp: 2.40 / 86.6 g today, 2.68 / 88.0 g new, the same work to 2 % in solver cycles). Top Motor Mount optimised: OWED. Pad 2 / 3 / 4.5 mm: OWED.
5. The same job twice gives the same bytes, switch off and on (test K).
6. The lattice strength check (LatticeReview's final statement): the laid lattice never moves; solid and regular lattice sound; Organic steadier or no worse and stricter or equal on its jobs; stage 1 may flip for Organic as for the rest.

**What it does NOT fix, said plainly.** The margin still falls as the grid gets finer (Base 0.79 to 0.32): that is the stress READING, stage 2. A design in many pieces can still stall the solver and lose a version (demo part, 17 pieces): stage 5 and the optimiser.

**Mistakes of mine on the way, all corrected and re-measured.** The `face` path in a job still clamped whole voxels until LatticeReview caught it (every `face` number before 2026-11-25 19:45 was "new loads, old clamp"); the simple-job path ignored the switch at first; a first control table described my test, not a job.

**What must land in the same release as the flip (ruling 2d).**
- #362: hand-over items 1 to 3 below (the bridge's tag and depth previews; the two self-weight tagging sites of the lattice strength check in run_job.cpp).
- `lattice_depth_tie` section 0a and `test_print_frame.cpp:721` in their `face` forms; 721 moves because of the frame's load rule, not the loader.
- LatticeReview's interim guard (13b28529 on claude/organic-engine): a structural Organic job whose load lands on bare lattice is refused with one pop-up offering Skin or Solid.
- Scenario jobs: since 2026-11-25 23:50 their anchors follow the same rule (the drawn face's own nodes are held when the anchor is on in a scenario, and carry the weak springs when it is off), so the voxel path can be deleted for them too. Run 2026-11-26 00:08 (build 6bfb8151) on the repository's two scenario tests, switch off and `face`: `test_scenario_fields` passes both ways (54 checks off, 40 on) and `test_scenarios_strengthen` passes both ways (20 off, 18 on). With `face` each scenario holds one node plane where today holds two ("both pushed": 162 clamped nodes for 324; "B off": 81 clamped and 81 weak-spring nodes for 162 and 162), and the test's own independent re-check of every scenario (its supports, its weak springs, its loads, on the stored design) agrees with the run. Fewer checks run with `face` (40 for 54, 18 for 20) because one version fewer is made: on the plain growth run the smallest addition (rung 1.10) is REFUSED with `face` ("anchored piece detached: 1 anchored piece (128 voxels) holds no load in this design"), where today's path ships it (margin 127.9 -> 126.5). The two larger additions ship both ways. So with the anchors held on their faces, the lightest bridge between the two blocks did not form at that rung, and the run said so and refused it, which is the rule working, not a fault; but it is a version he would get today and not after the flip on this made part. Not yet looked at: whether the bridge fails to form because the anchor's pad is now 3 mm of true distance (a different frozen shape for the bridge to start from) or because of the thinner clamp.
- Rule P (run time within 10 %): to be re-read on a quiet machine; on a shared one the two stand runs did the same solver work and differed 40 % on the clock.

**Asked of the reviewer.** Flip the default to `face` (glued anchors on the face's own nodes; bearings by drawn area) and delete the voxel path and the switch, in the release that carries the list above. `face_spring` (every anchor an area spring) is NOT proposed as the default: it changes what "fixed" means and has only the as-drawn tables behind it; keep it as a later option or drop it, his call.

## What is built

| item | what | where |
|---|---|---|
| V-01 | A face hands its own area to the voxels it lies on; a load is force x each node's share of that area. Total force and its centre are the drawn face's, whatever the grid alignment. A face that touches the part never comes back with nothing loaded. | `face_loads.hpp/.cpp`, `loadcase.cpp` |
| L-03 | Protection and pad depth by true distance in mm from the drawn face, not whole voxel layers. | `mask_face_depth_mm`, `mask_region_depth_mm` |
| P-04 (for stage 3) | The same freezes handed on as geometry: triangles, cuts, depth in mm. | `frozen_sets.hpp`, `MinimizePlasticOptions::frozen_sets` |
| P-15 | The stop rule watches the margin of the DESIGN, without the Load and Fixture voxels. | `plsm.cpp`, `minimize_plastic.cpp` |
| R-07 | A version's file is checked BEFORE the app is told about it; a refused file is never announced. | `to_run.inc` |
| A-05 | When no version passes, the report says how the part as drawn stands: `"as_drawn": {margin, required, passes}`. | `to_run.inc`, `report.cpp` |
| simple jobs | The self-weight path (`job.fixture_faces`) goes through the same switch. | `tag_face_by_stage`, `to_setup.inc`, `to_analyze.inc` |

Moved to stage 2: R-08 (one accept rule for loop, certificate and file check).

## Tests

| test | rule | today | with the switch on | ctest |
|---|---|---|---|---|
| C loaded area and centre, 18 alignments | exact | up to 13 % off; nothing loaded in 6 of 18 | exact in 18 of 18 | measures (gate for the new path inside) |
| D protection depth | 0.05 voxel | up to 1 voxel off | within 0.05 voxel (per-voxel share) | same |
| K same job twice, demo part | same bytes | 14 files, 0 differ | 11 files, 0 differ (the 0.30 version is refused, see below) | `ctest -C Long`, gate |
| E ring under pressure (needs this loader) | 5 % of textbook, 10 % across resolutions | cannot be loaded | loaded area exact (0.00 % off); stress 6 to 7 % under the textbook, 4 to 7 % across resolutions; today's cut-voxel rule reads 76 % high (stage 2) | measures |

## Measured: the part as drawn (strength check only, no optimisation)

Effective margin; same binary, same job, only the switch changed.

| part | res | today | drawn face | drawn face + springs |
|---|---|---|---|---|
| Base | 48 / 64 / 96 / 128 / 160 / 192 | 0.67 / 0.18 / 0.40 / 0.17 / 0.30 / 0.08 | 0.97 / 0.81 / 0.51 / 0.39 / 0.38 / 0.33 | 1.07 / 0.87 / 0.56 / 0.41 / 0.40 / 0.35 |
| Pressing | 48 / 64 / 96 / 128 | 0.75 / 0.51 / 0.35 / 0.35 | 0.75 / 0.51 / 0.35 / 0.35 | 0.75 / 0.51 / 0.36 / 0.35 |
| PillowBlock (left) | 48 / 64 / 96 / 128 | 1.85 / 1.48 / 1.07 / 0.78 | 1.80 / 1.39 / 1.11 / 0.91 | 1.85 / 1.47 / 1.18 / 0.92 |
| Original stand | 96 / 128 | 4.47 / 2.93 | 4.59 / 3.15 | 4.71 / 3.15 |
| Top Motor Mount | 96 / 128 | 1.64 / 1.33 | 1.65 / 1.33 | 1.65 / 1.33 |
| Stand v4 | 96 / 128 | 1.94 / 2.12 | 2.46 / 2.02 | 2.18 / 2.11 |

Reading: Base is the part V-01 hurts. Today its margin jumps up and down by a factor of four with the resolution (0.67, 0.18, 0.40, 0.17, 0.30, 0.08), because where the grid falls decides how much of the loaded face is loaded. From the drawn face it falls steadily as the grid resolves the stress (0.97 to 0.33). Parts whose loaded faces happen to sit well in the grid (Pressing, Top Motor Mount) do not change, which is the control: the new loader changes the answer only where the old one was wrong. The remaining fall with resolution is the stress reading itself (stage 2), not the loads.

### The same table RE-MADE with the corrected clamp (build 4d495dd6, 2026-11-25 19:45 to 20:25; `face`, a glued anchor holds the drawn face's own nodes)

| part | res | today | drawn face, corrected |
|---|---|---|---|
| Base | 48 / 64 / 96 / 128 / 160 / 192 | 0.67 / 0.18 / 0.40 / 0.17 / 0.30 / 0.08 | 0.79 / 0.66 / 0.45 / 0.37 / 0.37 / 0.32 |
| Pressing | 48 / 64 / 96 / 128 | 0.75 / 0.51 / 0.35 / 0.35 | 0.75 / 0.51 / 0.36 / 0.35 |
| PillowBlock (left) | 48 / 64 / 96 / 128 | 1.85 / 1.48 / 1.07 / 0.78 | 1.32 / 1.10 / 0.90 / 0.74 |
| Original stand | 96 / 128 | 4.47 / 2.93 | 4.83 / 3.15 |
| Top Motor Mount | 96 / 128 | 1.64 / 1.33 | 1.65 / 1.33 |
| Stand v4 | 96 / 128 | 1.94 / 2.12 | 2.32 / 1.96 |

The reading stands: Base stops jumping with resolution (a factor of eight today; a steady fall here), and the parts whose faces sit well in the grid do not move. What the corrected clamp changed against the first, wrong table: the coarse-resolution margins are lower (Base 0.79 for 0.97 at res 48; PillowBlock 1.32 for 1.80), because a face held on its own nodes concentrates the reaction where a slab one voxel thick spread it; from res 128 up the two agree within 5 %. PillowBlock now reads LOWER than today at every resolution: today's one-voxel-thick clamp was flattering it.

### Bolt-bearing anchors (`loads.anchor_model` = "bearing"), the part as drawn (build 5e671a24, 2026-11-25 20:40)

The first run of the bearing branch (bf4aa356). Springs / effective margin / peak MPa.

| part | res | today | drawn face |
|---|---|---|---|
| Base | 48 | 24 springs / 0.56 / 23.9 | 90 / 0.64 / 20.9 |
| Base | 64 | 64 / **0.04 / 309** | 156 / 0.50 / 26.8 |
| Base | 96 | 100 / 0.27 / 49.4 | 290 / 0.33 / 40.6 |
| PillowBlock | 48 | 488 / 1.39 / 9.7 | 950 / 1.62 / 8.3 |
| PillowBlock | 64 | 803 / 1.09 / 12.3 | 1,501 / 1.30 / 10.4 |
| PillowBlock | 96 | 1,669 / 0.90 / 14.9 | 2,955 / 1.02 / 13.2 |

Reading: V-01 in its bearing form. On Base at res 64 today's path reads a margin of 0.04 (a 309 MPa peak) between 0.56 at res 48 and 0.27 at res 96: the bolt's springs land on the few voxel faces the alignment happens to tag. From the drawn face the same part reads 0.64 / 0.50 / 0.33, a steady fall. The drawn-face path carries two to four times as many springs (every node the face has a share of, where today takes only the exposed voxel faces within reach) and reads 12 to 22 % higher on these parts. One difference from today is left and stated: a node under a Load voxel is not skipped.

## Measured: optimised

| run | today | drawn face |
|---|---|---|
| Demo part (self-weight), version 0.70 / 0.50 / 0.30 margin | 965 / 301 / 70 | 1,176 / 437 / refused |
| Original stand, res 128 (one lock hold, same binary 956766db) | 1 version at 74.3 % material: margin 2.40 (file re-check 2.41), 86.6 g, peak 5.61 MPa, 885 s | 1 version at 75.6 %: margin 2.68 (file 2.68), 88.0 g, peak 5.02 MPa, 1,238 s |

The stand: the same single version either way, as in the baseline (ledger D: 1 version, 2.40, 86.6 g, so today's path is unchanged to the digit). With the drawn-face path the margin is 12 % higher and the part 1.4 g heavier: the loaded and held faces now carry their true area, so the peak beside them is lower (5.02 against 5.61 MPa), and the pad is 3 mm of true distance where it was three voxel layers. The run took 40 % longer on the clock (1,238 s against 885 s), but did the same work: 47 solves each, 8,343 multigrid cycles against 8,197 (+2 %), 40 design steps each. The same cycles took 750 s where they had taken 458 s, so the difference is the shared machine during the second run, not the method. Rule P (time within 10 %) is to be re-read on a quiet machine before the stage report. No solve fell back to the slow solver in either run.

The refused 0.30 version: at solve 19 the design is in 17 separate pieces; the multigrid solve grows its error and the Jacobi-CG fallback hits its cap at residual 0.092. Today's path goes through 8 to 11 pieces and lands inside the cap. Not the loader: the optimiser breaks the part up (stage 3/4 boundary) and the solver cannot settle a broken part quickly (stage 5). Which side of the cap a run lands on is luck until those land.

## Reviewer's rulings on stage 1 (TORebuildGroup, 2026-11-26 01:37Z)

- The lattice region mask follows the mm depth through the same function as the protection: APPROVED. The protected skin keeps the distance band; the old lattice mask is not reshaped (its path is retiring).
- Cubes that are both or neither at a skin's inner boundary: recorded for stage 7, not stage 1.
- The FLIP is ruled on the stage 1 report, which must carry: hand-over item 3 for #362 in the same release; `lattice_depth_tie` 0a and `test_print_frame.cpp:721` in their `face` forms, each with a note naming the frame's load rule as the cause of 721's move; and LatticeReview's interim guard (a structural Organic job whose load lands on bare lattice is refused with one plain pop-up offering Skin or Solid on that face, until the reference study lands).
- The env switch never makes anything he is shown and never makes a release.

For the stage report (ruling 2d), from LatticeReview 2026-11-26 02:27Z: the interim guard is on `claude/organic-engine` at 13b28529 (one commit on the released b393d12b; #362 takes it into organic-1). An Organic strength check fails with the reason "load_on_bare_lattice" when the vines would get more than 1 % of the load, and no strengthening round follows. Expected on the jobs here: the turned-box C and the bare-top job refused; the chamfered C unchanged (its share is 0.001 to 0.006).

## Still owed before the stage report

- The original stand optimised both ways (queued), then Top Motor Mount; three settings; pad 2 / 3 / 4.5 mm.
- DONE (see "LatticeReview's FINAL statement" below). Kept for the record: the lattice strength check before and after (reviewer), on the set LatticeReview named (TORebuildGroup, 2026-11-25), three MADE jobs, none of his files:
  - A. All-lattice box, axis-aligned, loads and anchors on whole flat faces, a depth that is a whole number of voxels. The control: no change beyond rounding.
  - B. A block whose loaded face is not on the grid (tilted or cylindrical, part of a face), protected skin 1.3 mm, regular cells.
  - C. Job B with Organic (Traced), so the frame-of-beams check runs.
  - Per job, switch off against `face`: per load group the applied force summed over nodes and the reaction (both must equal the job's force), loaded and anchored area; the verdict and its reason; load connected; load landing on lattice; the solid's margin and where its worst cube is; the worst strut's margin and place and how many struts are under the margin; cubes protected / lattice / solid; infill to certify; the bar count and the lay hash, which must be IDENTICAL off and on (the switch must not move the laid lattice).
  - His stand, run in place on his real project, is a welcome fourth, not a substitute.
- `region_lattice_mask` now follows the mm depth with the switch on, through the SAME function the protection is frozen with (`mask_region_by_stage`), so bar R5 stays structural (LatticeReview's position; for the reviewer to rule; LatticeReview reviews the diff). Proof owed on job B: no cube both protected and lattice, none that is neither along the inner boundary; job A unchanged. Not mine: `flexible/job_block.cpp:374` also calls `region_depth_layers` (#362's).
- Test K again with the switch on once stage 5 removes the solver luck.

## Measured: the lattice strength check, switch off against `face` (LatticeReview's jobs A to C)

`core/tests/validation/test_to_stage1_lattice_check.cpp` (`ctest -C Long -R to_stage1_lattice_check`), run 2026-11-25 on a side build of the tip, 37 s. 20 N on each job.

| job | laid lattice (bars; file bytes) | verdict | worst-case margin | what else moved |
|---|---|---|---|---|
| A, box on the grid, whole faces (the control) | 480 / 480; IDENTICAL | accepted / accepted | 790.5 -> 891.6 | peak stress 0.0439 -> 0.0330 MPa; the re-solve's solid margin 1,223 -> 1,519. 5 of 20 values. |
| B, box turned 17 / 9 degrees, loaded side face with a 1.3 mm protected skin | 356 / 356; IDENTICAL | not accepted / not accepted (same reason both ways) | 134.1 -> 166.5 | interlayer margin 551 -> 628; load landing on cells with no credit 9.63 -> 9.32 N; re-solve solid margin 212 -> 386. 12 of 246 values. |
| C, job B with a weave (frame-of-beams check), a made uniform stress result | 902 / 902; IDENTICAL | accepted / accepted | 51.9 -> 58.1 | weakest strut 44.6 -> 67.8; frame nodes loaded 15 -> 31; load on the frame 1.19 -> 1.41 N of 20; the list of weakest struts reorders. 123 of 477 values. |

Reading:
- The rule held: the switch does not move the laid lattice. Bars and file bytes are identical in all three.
- The control is NOT unchanged: 13 % on the margin with everything on the grid. So the difference is not grid alignment. Likely cause, not yet shown: today's path holds every node of the bottom layer of VOXELS (two node planes, a one-voxel-thick clamp) and spreads the load over every exposed face of the tagged voxels, sides included; the drawn-face path holds and loads the nodes of the face itself. To be confirmed by printing the held and loaded node counts both ways before the stage report.
- Every margin rises, by 9 to 24 % (52 % for the weakest strut in C). These jobs carry tiny loads, so the margins are in the hundreds; the direction and size are what matter.
- Not yet counted, from LatticeReview's list: applied force and reaction summed per load group, loaded and anchored area, cubes protected / lattice / solid, and on job B "no cube both protected and lattice, none that is neither along the inner boundary". The test prints the strength block only; these need the masks, which the block does not carry.

### The control explained, and the jobs remade (2026-11-25, later)

Job A's box, res 40 (`test_to_true_loads`, table "[control]"):

| path | nodes held | node planes | nodes loaded | of them on the sides | force on the sides | total |
|---|---|---|---|---|---|---|
| today | 3,362 | 2 (the whole bottom voxel layer) | 1,841 | 160 | 0.909 N of 20 | -20.000 N |
| drawn face | 1,681 | 1 (the face's own nodes) | 1,681 | 0 | 0 | -20.000 N |

So the control moves for a real reason: today's path clamps a slab one voxel thick and pushes 4.5 % of the load onto the side faces of the loaded voxels. Found on the way: the new clamp left a face's four corner nodes out (the quarter-area threshold was met exactly); the default is now 0.2 and the count is 41 x 41.

Jobs B and C remade on a 56 x 56 x 24 mm box (seven cells across) at LatticeReview's word. Laid lattice identical again (B 1,240 bars; C 3,053 bars, compared on the bar list: a weave writes a 3MF with random ids, so the first run's "bytes identical" for C compared nothing). B: margin 379.1 -> 537.5, interlayer margin 1,254 -> 5,577, still no credited cell (0 of 64), asked. C: margin 474.4 -> 503.1, but the weakest strut 84.5 -> 47.5: LOWER on the face path, the opposite of the small box. The direction is not the same everywhere.

### Jobs B and C as LatticeReview asked for them (2026-11-25, 19:45; side build of bf4aa356 plus the test's own fixes)

A 56 x 56 x 32 mm box ON the grid with one top edge chamfered (9 in, 7 down, about 38 degrees; the mesh importer joins faces under 35 degrees, so a shallower chamfer merges into the top). The chamfer is loaded (20 N) and carries a 1.3 mm protected skin; the lattice region is the top face, three 8 mm cells deep.

| job | laid lattice | verdict | worst-case margin | what else moved |
|---|---|---|---|---|
| A (unchanged) | 480 / 480, identical | accepted / accepted | 790.5 -> 891.6 | as before |
| B, regular cells: 126 cells credited, none without credit | 2,978 / 2,978 bars, bytes identical | pass / pass | 709.6 -> 933.6 | peak stress 0.0484 -> 0.0148 MPa; interlayer margin 24,573 -> 24,056; re-solve solid margin 735 -> 1,319. 7 of 20 values. |
| C, the same with a weave | 7,692 / 7,692 bars, bar list identical | accepted / accepted | 618.2 -> 948.9 | weakest strut 888.7 -> 886.9 (the load is on the solid chamfer, not on the weave, so the frame's load rule hardly acts here). 87 of 477 values. |

Reading: with the loaded face a real off-grid face, the peak stress beside it falls to a third (0.048 to 0.015 MPa) and the margin rises 32 to 54 %. Today's path, on a 38-degree face, tags a staircase of voxels and loads their exposed faces, sides included; the drawn-face path loads the chamfer's own area along its own outline. The earlier turned-box versions of B and C (above) stay on record: they are where the frame's load rule was seen to move the weakest strut both ways.

### CORRECTION (LatticeReview, 2026-11-25 19:40): what a job held on the `face` path

The "[control]" table above counts the TEST's own call to `face_clamp_bcs`. No job called it: on `face`, a glued anchor still clamped all eight corners of every voxel the face lies on (two node planes on job A). So every `face` number above (the as-drawn tables, the stand, jobs A to C) was made with today's one-voxel-thick clamp and the new LOADS only, and the 13 % on job A is the loads alone (the 4.5 % of the force that today lands on the side faces), not the thinner clamp. Fixed in the commit after 3d13ced9: with `face`, a glued anchor holds the drawn face's own nodes (scenario jobs keep the voxel clamp). EVERY `face` measurement in this file is to be re-made on that build before the stage report; until then read them as "new loads, old clamp". `face_spring` rows were already held by the face's own nodes.

### Jobs A to C re-made with the corrected clamp (build 4d495dd6, 2026-11-25 19:43)

Laid lattice identical in all three (480, 2,978 and 7,692 bars). Worst-case margin, off -> `face`: A 790.5 -> 895.1 (was 891.6 with the old clamp); B 709.6 -> 941.2 (was 933.6); C 618.2 -> 971.9 (was 948.9), weakest strut 888.7 -> 870.0. So on these jobs the clamp's own share of the change is small (under 3 %) and the loads carry the rest. On a part held on a small face it is not small: Base as drawn at res 48 reads 0.79 with the face's own nodes held, against 0.97 with the old clamp and the new loads (table being re-made).

### LatticeReview's FINAL statement on stage 1 and the lattice strength check (TORebuildGroup, 2026-11-25 20:14; measured on tip 4d495dd6, strength grid 40, made jobs)

1. The laid lattice never moves: bars identical in every run, switch off or on, at five grid resolutions.
2. Solid and regular lattice: sound. The check reads the held nodes and the loads only, never the frozen mask.
3. Organic (frame of beams): the frame's number is ALREADY unsteady today, before stage 1. Weakest strut at grid 36 / 38 / 40 / 42 / 44, switch off: turned-box C 45.4 / 95.5 / 84.5 / 63.2 / 78.7 (a factor 2.10); a job loaded on a bare lattice top 1.88 / 1.80 / 3.43 / 1.10 (fail) / refused. With `face`: turned C 54.0 / 52.8 / 47.5 / 41.2 / 53.7 (factor 1.31, at or below today's reading at four of five); the bare-top job 1.88 / 1.80 / 3.43 / 1.18 (fail) / 1.48 (fail), no refusal. So the switch makes the Organic number steadier or no worse on these, and stricter or equal. LatticeReview withdrew its own by-force rule (it failed its own pass marks) and WITHDREW ITS HOLD: stage 1 need not wait on it. How load gets from the grid onto the vines has no checked basis; that is a separate, older fault in the lattice check, for the reviewer (a reference solve of printed struts on one coupon, about 2 days).
4. Two lattice tests go red with the switch on and need their `face` form at the flip: `lattice_depth_tie` section 0a (it pins effective depth = layers x spacing; with `face` the run reports the mm asked, by design) and `test_print_frame.cpp:721` (the same job turned: weakest strut 5.904 against 3.283, outside its 25 %; the frame's load rule again).
5. Protected against lattice cubes on chamfered job B (`test_to_stage1_lattice_masks.cpp`, LatticeReview's test, cherry-picked): cubes that are BOTH protected and lattice 40 with the switch off and the same 40 on; NEITHER along the inner boundary 400 off, 240 on. So "none both, none neither" holds on neither path and the switch did not cause it; no strength number reads it; it is stage 7's. Job A: no change.

LatticeReview's position: stage 1 may flip for Organic as for the rest, with the two tests in 4 and hand-over item 3 for #362 landing in the same release.

## Measured: the sideways lip (LatticeReview's question)

A face that is PART of a flat side (a 20 x 20 mm patch in a 60 x 40 mm top; `test_to_true_loads`, table "[lip]"). Frozen voxels with their centre outside the prism under the patch:

| res (voxel mm) | depth mm | today, by layers: inside / outside | by true distance: inside / outside, farthest reach |
|---|---|---|---|
| 48 (1.25) | 2 / 4 / 10 | 512 / 170, 768 / 461, 2,048 / 4,038 | 512 / 188 (1.9 mm), 1,024 / 674 (4.0), 2,048 / 4,486 (10.0) |
| 96 (0.625) | 2 / 4 / 10 | 2,048 / 572, 5,120 / 3,179, 15,360 / 31,300 | 3,072 / 1,055 (1.95), 6,144 / 4,460 (3.96), 16,384 / 33,643 (9.98) |

Reading: the lip is NOT new. Today's layer walk already spreads sideways under the neighbouring face (at 10 mm deep, twice as many voxels outside the prism as inside). True distance adds 7 to 85 % more outside voxels and reaches exactly the depth. Whether a region should be a prism under its outline (as the new lattice engine lays it) or a distance band is a question for the reviewer, for both paths.

## For #362 (handed over with the switch flip; not edited by me)

Until these land, with the switch on, the app's previews count voxels the old way while the run freezes by true distance.

1. `app/TopOptKit/Sources/TopOptBridge/bridge.cpp`, `tag_step_face` (about line 1013). Replace

        return static_cast<int64_t>(topopt::tag_step_face(g, model, face_id, tag));

   with

        return static_cast<int64_t>(topopt::tag_face_by_stage(g, model, face_id, tag));

2. Same file, `mask_step_face` (about line 1029) and `face_slab_preview` (about line 1057). The bridge passes voxel layers only; the run now needs the depth in mm. In `face_slab_preview` replace the `mask_step_face(g, model, fid, FrozenSolid, depth_vox, one)` call with

        topopt::mask_face_by_stage(g, model, fid, topopt::MaskValue::FrozenSolid,
                                   depth_vox, depths_mm[i], one)

   and in `mask_step_face` pass `depth_voxels * g.spacing` as the mm depth the same way. (`#include "topopt/loadcase.hpp"`.)

3. `core/src/cli/run_job.cpp`, the two fixture-face tagging sites in the lattice strength-check code (about lines 11337 and 12647): replace the `model_is_mesh ? tag_mesh_face(...) : tag_step_face(...)` expression with `tag_face_by_stage(<same grid>, <same model>, f, VoxelTag::Fixture)`.

4. The report key `"as_drawn"` (top level, present only when no version passed on a reduction run): the app shows its centred pop-up offering Strengthen (agreed 2026-11-25).

5. Two lattice tests go red with the switch on and need their `face` form in the same release (LatticeReview, 2026-11-25): `lattice_depth_tie` section 0a (it pins effective depth = layers x spacing; with `face` the run reports the mm asked, by design) and `test_print_frame.cpp:721` (the same job turned; the frame's load rule). The first is LatticeReview's to re-pin, the second waits on its ruling about the frame's load.

When the switch flips and the old path is deleted, `tag_face_by_stage` / `mask_face_by_stage` keep their names and lose the old branch, so these lines do not change again.
