# Stage 3: smooth surfaces (TOSurface)

Branch `claude/topopt-stage-3-surfaces-7f58fd`, from 2b40bcf4. Status: IN PROGRESS (2026-11-26 03:30 EST). Nothing here is released.

## Where I stopped (read this first)

- **11-27 ~11:25:** TOReview (16:18Z) clarified the lock rule: the 5-min empty wait is only for the agent that JUST released the lock. A queued script takes an empty lock after about 1 min. My batch had waited 19 h behind B8, SA1 and B9 under the old reading. I replaced launch_ref6, measure_hold and c_after (all still waiting, none holding) with ONE chain, `agent-scratch/tosurface/queue2.sh`:
  - test P's remaining pairs (pOn1, pOff2, pOn2), on the same frozen bin/topopt-cli-night as pOff1;
  - then the knot measure;
  - then a 5.5-min gap after each of my releases (TOSolver's queued job needs 4+ min empty);
  - then the stand re-runs and C's four parts on b92e3bd0.
  ref.sh and measure_hold.sh now wait 4 empty checks (the old ones are kept as *.5min).

- **11-27 ~08:35:** TOReview's pre-review of 789135df: no conflict, no PDFs, switch-off reads byte-identical. All four small items are folded in (compile-checked only):
  - (1) the re-fit move measurement now runs only with the stage 3 switch on (its one reader is the [plsm] line);
  - (2) StepModel's never-filled export_mesh/export_triangle_face are dropped, drawn_mesh() is `mesh` (step.cpp already keeps the 0.01 mm mesh there), and make_frozen_bodies' dead whole-face branch is gone (same bodies);
  - (3) **a step-back iteration records nothing**: no iterations.csv row (its number is skipped), no keyframe or observe call, and done_iters is not set by it, so r.iterations can count one short when a rung ends on a step-back (under TOPOPT_CONNECTION=support only);
  - (4) plsm_frac_grad_l1 is reached only when a job sets frac_eps_l1 (off by default) and from the FD probe, so its P-17 border-span edit changes nothing today.

- **11-27 07:20:** the knot measure (measure_hold.sh) gave up after its 12 h lock wait. TOReview's B7 lock line was untouched: the script takes the lock with noclobber and exited on 'file exists'. Re-queued with the same 4-try retry the batch scripts use. Still queued: launch_ref6 (test P pairs) and c_after (re-runs).

- **11-27 ~04:20:** step-back WRITTEN while the batch waits on TOReview's B7 lock: TOReview's tip merged (a7e8523b, no new PDFs, the test list kept both sides) and the step-back put in plsm.cpp (cf6f1eac). It runs only under the connection rule, and TOPOPT_STEP_BACK=off switches it off for the off/on runs. It compiles, but is not yet built (disk at 25.3 GB) or measured. Asked TOReview for demo solve 10's folder. **Answer (TOSolver via TOReview, 09:24Z):** demo solve 10 = a RUN of `core/tests/fixtures/demo/job.json` (read in place; `topopt-cli run job.json --out <elsewhere>`), originally on cb9e305b with no TOPOPT_* set. Solve 10 = the 10th fea_solve_mgcg_matfree call (the [loose] lines; [mg-safe] counts one lower), where 8 loaded pieces had no path to a support. Check that run's solve-10 [loose] line on today's tree first. Run it THREE ways, and the hook (pad auto:1.0, drawn-face loads) the same three: (1) switches unset; (2) TOPOPT_CONNECTION=support TOPOPT_STEP_BACK=off; (3) TOPOPT_CONNECTION=support with the step-back on. Report versions made, versions refused and seconds. KEEP RULE: more versions in no more than 10 % more time, or it comes out. stop_cause_load_unheld set in plsm.cpp (33759c26, on TOReview c4d5e24a).

- **11-27 ~03:00:** report draft filled where the batch allows (items 3, 5, 7 and hold C's interim; item 1 and the reference table wait for the measure hold, test P for its pairs). Stand v4 at 96 in the batch was stopped by the OLD guard ("free 44 %, swapouts rising on 2 checks", before the reviewer's 06:34Z amendment); its re-run is in `c_after.sh` (b92e3bd0). The step-back task needs TOReview's connection-rule code (TOPOPT_CONNECTION, fea_matfree_load_unheld_count), which is NOT on this branch: merge their tip first (check for PDFs), after the batch and the report, as TOReview queued it.
- **QUEUED AFTER THE BATCH AND THE STAGE 3 REPORT (TOReview 2026-11-27 01:26Z, from the reviewer's ruling 00:22Z, TOSolver-Group item 2):** a step-back in plsm.cpp's loop (around lines 690-712), only under to_connection_rule_on(), today's bytes otherwise. Keep the design of the last state solve that succeeded (alpha plus the MMA state and frac cache that go with it). In the SolverNonConvergence catch, tell an unheld load (`fea_matfree_load_unheld_count()` grew since the solve began; `fea_matfree_last_load_unheld(&pieces, &voxels)` for the log) from a real non-convergence. On an unheld load with fewer than 3 step-backs used in the rung: restore the kept design, halve the move limit, log "[step-back] rung vf X: the load lost its path at iteration N; back to iteration M, move limit halved (k of 3)", continue without counting it non-convergent. On the fourth, break as today. Measure on the hook at pad auto:1.0 with TOPOPT_CONNECTION=support (`agent-scratch/toreview/opt15/hook_rule`), step-back off and on (versions made, refused, seconds), and on TOSolver's "demo solve 10" (ask TOSolver for the job folder); one thread, through the gate. Keep only if it makes more versions within 10 % more time. Table to TOReview.
- **16:17, batch hold 2 (d0c5b557, no design box so the keep-layer fix does not apply):** Top Motor Mount at 96 wrote 0.68, 0.52 and 0.38; 0.26 cut by the 4800 s limit in its last rung. Surface mesh times 58.8 / 313.2 / 305.3 s: the 0.52 and 0.38 meshes took 5 minutes each, a cost to explain before the flip (the Mac was shared; test P's pairs measure it cleanly). Hold 3 (Top Motor Mount at 64, knots 2 then 1.5) running.
- **17:17:** Top Motor Mount at 64, knots 2: ALL FOUR versions written (the first batch's were all refused "could not be re-checked": the one fine import mesh of 733d46c6 holds on the real part). Mesh 29.6 / 111.2 / 125.8 / 119.5 s. TOSolver had its turn before my knots-1.5 hold (yield rule, TOReview 21:35Z); that hold took the lock at 17:11.
- **18:17:** knots 1.5 at 64: all four versions too; run 1543 s against knots 2's 1531 s; mesh 30.0 / 115.7 / 107.7 / 119.5 s. The surface comparison (measure_area, CUT / SEAM / DRAWN) decides the spacing at table time. TOSolver holds the lock (17:42, up to 150 min); test P waits.
- **15:00-15:40, a second design-box bug (found through the STEP side hustle's step A), MINE, fixed (not committed yet):** frozen bodies were two-sided (unsigned distance to the protected faces minus the depth); frozen_sets.hpp defines them as "everything OF THE PART within this true distance". On a design-box run the box kept the air-side half: the stand's rounded caps over the bolts' keep layers, proud of his slanted face (`agent-scratch/tosurface/stepA/stage1_vs_stage3_128.png`: stage 1 alone stops at the face). Three forms tried: (1) the band cut by the whole part's signed distance through the lattice cache: test B's layer face 1 mm off at the bore; (2) one-sided by the body's own faces (pseudonormal sign): caps gone but a countersink's rim cannot be told (the patch's edge), the stand at 64 then had 168 stamped voxels and ragged boss tops (`stage-3-pics/stand_keepfix_64.png`, first version); (3) KEPT: the band held to the part exactly per point, max(band, -sd_part), only where the band is solid and ONLY on a design-box run (without a box the one cut by the drawn part trims the band exactly, as before; a band ending on the part's other faces leaves its corner to the mesher, which rounds it by a cell: that was form 1's 1 mm). Test B unchanged (0.0033 / 0.0007 mm); new test B case (4 mm layer, design box): 3592.8 mm3 in the part, 0.0000 past the face; gates A, B/F/J pass. Binary `bin/topopt-cli-keep`. The stand at 64 on form 3: a file, vf 0.68 accepted (finished margin 4.34), 87.32 g (stage 1 alone at 128: 87.99 g; before the fix 89.18 g at 64), 0 stamped solid voxels, 0 thin spots left (before: 4), boss tops end in his slanted face (`stage-3-pics/stand_keepfix_64.png`); mesh 5.4 s, run 130 s. The batch's stand and Stand v4 (pre-fix) re-run after the batch; Top Motor Mount (no box) unaffected.
- **14:20, batch hold 1 (binary frozen 14:06 = d0c5b557, lock taken 14:06):** the stand at 128 WROTE ITS FILE: vf 0.68 accepted (margin 7.31; finished file 2.98 against 1.5), 89.21 g (stage 1 alone 87.99 g: +1.4 %), nothing cut from its Keep clears, none sealed; printed slope 0.87 / 1.16 / 1.55; 590 s, 1.25 GB peak. Open: 5 thin spots left (stage 1 alone: 0), the neck item. Stand v4 at 96 running.
- **Side hustle, STEP step 0 (his yes ~14:10):** the stand at 64 as ONE valid faceted solid STEP, 10,046 faces, 25 MB (details in `step-export-scope.md`); sent to him for Shapr3D.
- **13:49, test P's import cost (reviewer 18:37Z):** `topopt-cli preflight` (import + load case + load-path check, no solve), Release build d0c5b557, switch off / on, two repeats each (`p_import.sh`): stand 0.87, 0.85 s / 1.86, 1.94 s, peak 74-78 / 171-173 MB; Top Motor Mount 0.94, 0.97 s / 2.09, 2.35 s, peak 110-111 / 197-198 MB; Stand v4 0.71, 0.78 s / 1.13, 1.09 s, peak 60-64 / 123-126 MB. The 0.01 mm mesh adds about 0.4-1.4 s and 60-100 MB per import: small against a run (minutes), and far under the run's own peak. Measured while TOSolver held the lock (a loaded Mac): the run-time half of test P comes from the batch's off/on pairs.
- **13:45 (after the app crash ~13:15, Mac overloaded):** nothing of mine was running at the crash (two queue scripts waiting on the lock; the batch never started). New rules (maintainer via reviewer, 18:37Z): gate free >= 30 % and swapouts flat over 30 s; every long job self-guards (free < 15 %, 20 % in the lock, or swapouts rising two checks running); outside the lock one job per agent, one thread, -j2. `ref.sh` carries both. Restart line posted; the batch (`launch_ref6.sh`, binary `topopt-cli-b` = d0c5b557) re-queued on the lock behind TOSolver (13:38, up to 240 min). `c_strengthen.sh` (pressing_box + the growth parts, lock holds) is NOT re-queued yet: restart it only after the batch's first hold has run 5 min with the gate green. Reviewer's ruling 18:37Z: keep steps 3 and 4 (knots 2 vs 1.5; test P); test P must carry import time and peak memory (the 0.01 mm mesh changes import for every part), and test K (same bytes twice) must pass on it: compare pOn1 vs pOn2 files.
- **NIGHT QUEUE 2026-11-26 (his yes ~03:50 to A, B, C; main track first):** (1) the design-box fix: gates pass (test J's new case: without the cut 630 mm3 in the keep-out and 320 mm3 in a keep region's air; with it 0 and 0), stand at 64 check, commit + push by file name; (2) the full batch in the lock queue after TOReview's two holds (stand + Stand v4; Top Motor Mount at 96; at 64, knots 2 and 1.5; test P), on ONE binary frozen when its first hold starts; (3) B: bolt Keep clears exact in the design-box cut, test first, lands before (2) starts or waits for the next batch; (4) C: res-64 no-lock runs of his design-box parts; (5) A: the STEP scope draft, writing only; (6) the table, pictures, report with the open items first, report to TOReview. Builds and short checks run beside the lock holder (his 11-25 rule); never block on a question tonight.
- **03:50, B and a slip of mine:** B is in (`to_export.inc`: each declared Keep clear's solid, `clearance_solid` grown 0.01 mm, joins the box cut). Test J's design-box case now carries a bolt's Keep clear through the slab: without the cut 377 mm3 in it, with it 0; the box's volume 3023.9 against 3024.4 mm3; gates A, B/F/J pass. The slip: the CLI's CMake target is `topopt_cli`; my `--target topopt-cli` relinked nothing (rc 0), so the 03:30 "box" binary was 22bb0e22 and its stand check (stopped by the swap guard anyway: 9.99 -> 11.58 GB, others' Xcode, VM and xctest held about 13 GB) proved nothing. Rebuilt with the right target at 03:48 (`strings` shows the new message); the night batch's binary now points at it and was not yet frozen. Then C on that build: the stand at 64 first (both fixes), then base_strengthen, carriage_strengthen128, pressing_box, pressing_strengthen and Stand v4 at 64, no lock.
- **04:20, the stand at 64 on the fixed build (C, first part):** a file. vf 0.68 accepted, margin 11.7 (finished file 4.79), 89.18 g (stage 1 alone at 128: 87.99 g), nothing cut out of its Keep clears and none sealed (before: 3.7e4 mm3 cut, 2 sealed). Printed slope 1.11 / 1.81 / 1.88. Open: the finish left 4 thin spots (stage 1 alone at 128: 1 fixed, 0 left); read again at 128 in the batch.
- **05:00, C re-planned (my default, noted for him):** base_strengthen hit the 40 min limit at res 64 still in its coarse search: the strengthen (GROWTH) parts are not short jobs on a busy Mac. They now run in lock holds after the main batch, 2 h limit each (`c_strengthen.sh`, queued); C's no-lock runs keep the reduction parts (pressing_box, Stand v4 at 64; `c_check2.sh`). Pushed d0c5b557 (the fix, test J's case, docs).
- **05:55:** the Mac is over-full (kernel_task at 280 % CPU, others' lattice jobs): pressing_box at 64 used its 40 min for 13 iterations. My default: no more unlocked runs while it is like this; my Stand v4 check stopped (Stand v4 runs at 96 in the batch); pressing_box joins the growth parts in `c_strengthen.sh`, lock holds after the batch.
- **09:27, TOReview's finding (bracket, res 64, their scratch merge with d0c5b557):** vf 0.26 refused "After finishing, a piece is loose". Its report: pieces 1 (one body in the mesh), loose_pieces 2 (on the re-check's voxels), thin_joints 0: a neck of the function's surface thinner than a voxel, which the centre-inside re-check splits (the finish left 4 thin spots; the stand at 64 also left 4). Open, mine; options sent: (a) the surface holds a one-voxel minimum where phi necks (my lean: print and check agree), (b) the re-check counts connection on the mesh. Not tuned tonight.
- **A:** the STEP scope draft is `step-export-scope.md` (writing only; his three questions held for his morning message).
- **2026-11-26 03:30, the batch on the merged build (22bb0e22), hold 1:** the stand (128) was refused again, "A Keep clear is sealed inside the part": the file carried 3.7e4 mm3 in its Keep clears (stage 1 alone: 0.57 mm3) and 136.6 g against stage 1 alone's 88.0 g. Mine, and not the cause fixed in 733d46c6: the stand is a design-box run, and the surface was cut by "drawn part OR design box". Inside the box, (a) the keep-out (x within 20.1 mm of the middle, the box's full y and z) is Empty on the grid, so no stamp corrects the function there and whatever value it carried across printed; (b) the keep regions were joined whole, so their air (in front of protected faces, inside protected holes) printed too. Today's export keeps only the part's own shape inside each keep region. Fixed (not yet committed): the box joins the domain less its keep-outs (grown 0.01 mm) and the keep regions (grown 0.02 mm, past keep_solid's 0.01, so no faces coincide); `to_export.inc` carries the run's keep-out boxes (`RunFinish::keep_outs`). New gate case in test J: a solid-everywhere design in a box with a keep-out and a straddling keep region; the keep-out and the air must hold 0 mm3 and the rest of the box 12,176.8 mm3. Build and gates queued behind TOReview's runs (the lock left empty 4 min between my holds, at their request). The printed slope on this stand file: 0.86 / 1.29 / 2.22 (min / median / max over the printed corners).
- Same hold: Stand v4 was stopped by my swap guard (swap 7.6 -> 9.7 GB), but the guard killed only the timer process, so the run went on inside my hold until 03:12, when I stopped it. `ref.sh` now stops the run itself. The rest of the batch (Top Motor Mount at 96; at 64, knots 2 and 1.5; test P) is withdrawn until the fix passes, then re-queued.

- Code: committed; pushed up to 7316214a, later commits local until the report. Tests A, B, F, J pass their gates (`--gate` in ctest) on 733d46c6. Off path byte-identical (M); switch-on runs repeat byte for byte (K).
- The stage 1 + 3 batch (frozen build 6f2b3dac, 2026-11-25 19:55-21:39) wrote NO files. Three causes, read from each report's `rejection_reason`:
  1. Stand (128): "A Keep clear is sealed inside the part". Mine: a stamped VOID (a bolt's Keep clear) stopped at its own smoothed edge, so a skin of the function closed it off where it met the drawn bolt hole. Solid stamps were already carried two voxels past the drawn faces; void stamps now are too (733d46c6).
  2. Top Motor Mount at 64: every version "could not be re-checked" (`fea_solve_mgcg_matfree: under-constrained system`, a load on a void DOF). Mine: the grid, tags and loads came from the part meshed at 0.1 mm, the file was cut by the 0.01 mm copy; a 0.1 mm chord lies up to 0.1 mm inside a bolt hole, so a loaded voxel whose centre sat in that sliver was solid in the solve and empty in the re-check. With the switch on, ONE 0.01 mm mesh now makes the grid, the tags, the loads and the cut (733d46c6). Consequence for the flip: the import tessellation changes for every part.
  3. Base, Pressing Plate Mount, PillowBlock stands: the drawn part itself fails stage 1's face loads (as-drawn margin 0.51 / 0.35 / 1.11 / 0.80 against 1.5 required; stage 1 as of be77631b, old clamp): not stage 3. Base and Pressing Plate Mount fail with today's loads too (ledger D: 1.14, 0.995), so no path writes a file for them; not re-run.
  Also my script: a part that hit its time limit ended hold A (Top Motor Mount and Stand v4 at 96 never ran); fixed.
- Merged TOReview's tip aa4175cc (stage 1 as reviewed: anchors hold the drawn face's own nodes, bolt bearings take the drawn area, depth zero floors at one voxel; stage 2 behind `TOPOPT_STRENGTH`, left unset), so the final table's margins and grams are today's stage 1. Next batch on that build: stand + Stand v4; Top Motor Mount at 96; Top Motor Mount at 64, knots 2 and 1.5; test P.
- Re-fit, measured: the narrow-band re-fit (warm-started; only the knots whose reach touches the surface band are solved for) leaves the re-fits at about 40 % of the loop's time; the CG "cap" is a tolerance artefact (1e-10 asked, about 1e-6 reached in 2,000 iterations). Slope of phi at the surface: the "median 3-5" on Top Motor Mount was mostly my measure: it read phi's whole zero set, including the part the cut by the drawn part throws away (outside the part phi is only carried across the faces). On the printed file's own corners (`stages/slope_at_file.py`, phi rebuilt from the saved coefficients):

  | file | corners on phi = 0 | slope p5 / p25 / median / p75 / p95 |
  |---|---|---|
  | Top Motor Mount res 32, narrow-band build, vf 0.68 | 1,427 | 0.80 / 1.17 / 1.63 / 2.15 / 5.45 |
  | Top Motor Mount res 96 (hold 1 build), vf 0.68 / 0.52 / 0.38 / 0.26 | 10,860 / 13,039 / 11,390 / 8,973 | medians 2.37 / 1.97 / 2.50 / 2.62; p95 3.8 / 3.6 / 10.1 / 11.8 |
  | Stand 128, vf 0.68 | 626 | 0.84 / 1.37 / 1.74 / 2.47 / 3.54 |
  | Stand v4, vf 0.68 | 802 | 1.35 / 1.72 / 2.10 / 2.49 / 3.20 |

  So the slope sits near 2, not 1, with a tail. What the band rule protects ("the mesher and the fill count see the same wall") is met where it is measured: the file's own re-check against the certified design, Top Motor Mount res 32: margin 15.29 -> 15.34, 15.05 -> 15.16, 14.73 -> 14.92, 14.40 -> 14.45 (0.3-1.3 %, limit 2 %). From 733d46c6 the run's own `[surface]` line reads the slope on the printed corners.
- Then: fill the before/after table with `measure_area.py` (before = ledger D's STLs, same ruler); decide the knot spacing from hold C; test P; pictures; report.
- Not started: close-out (delete the switch and the old path) waits for the gate and his OK.

## Report (04-tests.md "What a stage report contains"; numbers filled from the final batch)

**Open, first (TOReview 11-26):**
1. Top Motor Mount 0.68: with stage 3 ALONE its cut surface read worse than today (area measure, cut patches: median 0.112 against 0.022 mm, 56 % against 25 % over 0.05). Stage 1 + 3 (the batch, d0c5b557, at 64, knots 2; `knots_compare.txt`): cut patches median 0.000 mm (p90 0.205, max 0.319), 30 % over 0.05 (23 patches). The other three versions: medians 0.000-0.018, 27-44 % over 0.05. So the median is cured, but the share over 0.05 mm is not: 30 % against today's 25 %. It stays open; no further tuning before the reviewer reads it. The seams, where the cut meets the function's surface, sit at median 0.13-0.16 mm on every version, because that edge is the mesher's, not the drawn part's (item 6).
2. The re-fit's CG at its 2,000-iteration cap: a tolerance artefact (it asks 1e-10 and reaches about 1e-6 on every part measured with the switch on; the switch-off path makes the same call, not measured); the warm start and the narrow band did not change it. The re-fits take about 40 % of the optimiser loop. Not changed.
3. The slope of phi "median about 3" at shipped designs: mostly my measure (it read the zero set the cut throws away). On the printed corners: median 1.6-2.6, not 1; the file's margin against the certified one is within 2 % (Top Motor Mount res 32: 0.3-1.3 %). Stage 1 + 3 (the batch, build d0c5b557; min / median / max on the printed corners): the stand at 128, 0.87 / 1.16 / 1.55; Top Motor Mount at 96, 0.41 / 1.17 / 5.90 (0.68), 0.39 / 1.33 / 10.86 (0.52), 0.41 / 1.26 / 7.37 (0.38); at 64 with knots 2, medians 1.10-1.43, maxima 6.5-22.3; with knots 1.5, medians 1.31-1.65, maxima 21-119. So the median now sits near 1.2-1.4; the maxima are local (a few corners), largest with the finer knots.
4. A neck thinner than a voxel (TOReview's bracket, res 64, `agent-scratch/toreview/best_runs/a/all`): vf 0.26 refused "After finishing, a piece is loose": one body in the mesh, two on the re-check's voxels; the finish left 4 thin spots (the stand at 64 too). Ruling (TOReview 11-26 09:27, corrected 13:01 by the maintainer's word): the surface holds a minimum width where phi necks, stated in mm and tied to the print: for a SOLID part ONE wall-line width (0.45 mm on his jobs; "we can go as low as 0.4"), one voxel only where the voxel is larger. Two lines is the lattice's rule only. Not built before this report; TOReview re-runs the bracket folder on the fix.
5. A design-box run printed its keep-outs, keep regions' air and Keep clears (his stand: refused "A Keep clear is sealed inside the part"). FIXED (d0c5b557): the box joins the domain less those; test J's case; the stand at 64 then wrote its file.
7. A design-box run printed the air-side half of every keep layer (frozen bodies were two-sided): rounded caps over the stand's bolt keep layers, proud of his slanted face, part of its +1.4 % over stage 1 alone. FIXED (b92e3bd0): on a design-box run the band is held to the part by its exact signed distance; runs without a box unchanged. The stand at 64: 87.32 g (stage 1 alone at 128: 87.99 g), 0 thin spots. The batch's stand (128) and Stand v4 (96) ran on d0c5b557, before this fix; both re-run after the batch (queued, b92e3bd0).
6. Fold-backs where a rounded surface meets one of his flat faces (seen by him in Shapr3D on the STEP export, 11-27: tiny spikes and notches along the bosses' rims, and long thin slivers). They are in the PRINT file, not added by the export: edges whose two triangles turn back by more than 120 degrees, counted on the stand (`agent-scratch/tosurface/folds.py`): today's export (stage 1 alone, 128) 711 with 2,437 triangles under 1e-4 mm2; stage 3 before the keep-layer fix 535 (128) and 444 (64); after it 298 (64) with 732. Fewer than today, but the mesher still makes a saw-tooth at the grid's size where a body meets a drawn face at a sharp angle. Open: a sharper junction (the face of the cut, not the mesher, should make that edge).

- **Repo tests, failing -> passing:** A (known shapes: 0.12-0.24 mm -> worst 0.049, the 5 mm hole; walls 0.002) now `--gate`; B (drawn faces: flats 0.0000, bores 0.0007, a protected layer's face 0.003), F (ripple 0.015), J (one clean solid; also the edge-touching cases the stand forced) new and `--gate`. Held: M (switch off byte-identical to the tip build). K passes (switch on, same job twice, identical bytes). P (run time within 10 %) FAILS: +120 % and +167 % (table below).
- **Open choice settled:** basis = cubic B-spline (reach 2 by its degree) with a band-weighted fit; measured against Gaussian (today), Wendland C2 and C4 at reach 2/3/4, at knot spacings 1, 1.5 and 2 voxels (test A matrix, below). Knot spacing: 2 voxels (today's rule) unless hold C (1.5 against 2 on Top Motor Mount) says otherwise. Hold C: both write all four versions with margins within 1 % of each other (6.61-6.69); run time 1,531 s (2) against 1,543 s (1.5); 1.5 makes the slope wilder at its extremes (maxima up to 119 against 22). **Settled: 2.** The surface measure (11-27, `knots_compare.txt`, every version) shows no steady gain from 1.5. Drawn-face p90 0.029-0.045 against 0.038-0.051 mm. Cut patches' p90 is better on two versions (0.185 / 0.089 against 0.257 / 0.182), worse on one (0.295 against 0.205) and level on one. The seams' p90 is worse on two (0.245 / 0.279 against 0.208 / 0.188). The plan's 2-4 line widths are under one voxel at every resolution he runs; one voxel made the re-fit unstable (surface moved up to 10 mm).
- **Reference table:** stage 1 + stage 3 (the configuration that ships: without stage 1 the protections are voxels), before = ledger D on the same ruler (`measure_area.py`). [to fill]
- **Refused:** nothing (the neck floor, item 4, waits for this report by ruling).
- **Known and handed on:** the device preview and the `.meta` basis name (#362's files, lines below); the slope of phi at the printed surface sits near 2, not 1 (the margin it protects is within 2 %).

## What is built (all behind ONE switch, `TOPOPT_SURFACE`, default off = today)

| item | what | where |
|---|---|---|
| X-01, X-04 | The print surface is the zero surface of the optimiser's own function, meshed directly (marching tetrahedra on a body-centred grid, every vertex root-found to 1 um on the true zero set; Manifold::LevelSet). No fill fractions, no resample. | `mesh/level_surface.cpp` `mesh_level_surface`, `function_surface_mesh` |
| C-01, C-02, C-03, B (rule 9) | Drawn faces exact: the function's surface is CUT BY THE DRAWN PART (exact boolean), so every drawn face the design keeps is the drawn face itself, any surface type (fillets, cones, splines too). The CAD snap is not called. | `function_surface_mesh`, `to_export.inc` |
| I-02 | The STEP part is tessellated at 0.01 mm / 0.1 rad (was 0.1 mm / 0.5 rad) so its triangles meet the 0.02 mm target; that one mesh makes the grid, the tags, the loads and the cut, so the file's re-check sees the voxels the solve saw. | `io/step.cpp` |
| F-01 | The curvature flow does not run (`FinishContext::flow`). The thin-spot cleanup still runs (stage 4). | `finish.cpp` |
| B-01 | Crease-free bases: Wendland C4 and the cubic B-spline (tensor product; reproduces any flat wall exactly) beside today's Gaussian and Wendland C2. | `plsm_basis.hpp` |
| V-02 (optimiser side) | Outside the part nothing acted on the function, so its zero set floated between the last part voxel and the drawn face (a smoothed staircase). Each Empty voxel within the basis reach now takes its nearest part voxel's value before every re-distance and fit, so the design's own decision reaches the drawn face. | `plsm.cpp` `extend_into_empty` |
| P-04 (part) | The frozen voxels the function does not already explain are recovered from the shipped density, sample for sample on the optimiser's own sub-cell lattice, so the file holds exactly what was certified. Still voxel-shaped inside the part: see "not done". | `function_surface_mesh` |
| P-11 | Every re-fit's move of the surface is measured and reported (max, RMS). | `plsm.cpp` |
| P-05 | Volume offset: warm bracket, about 40 passes instead of 100. | `plsm.cpp` |
| P-16, P-17 | Hard 1/64 count off under the switch; border stencil fixed. | `plsm.cpp`, `plsm_frac.hpp` |

Switch values: `on` (the chosen basis), or a measurement arm `on:<basis>:<reach>:<knot line widths>`.

## Tests

Run on a Release build of this branch (2026-11-25).

| test | target | before (today's export) | after (switch on) | ctest |
|---|---|---|---|---|
| A known shapes, voxel 1.7 mm (vertices AND triangle interiors) | 0.05 mm | 0.12 to 0.24 mm (walls 0.12-0.19, holes 0.22-0.24, sphere 0.20) | walls 0.001-0.003, hole 10 mm 0.011, sphere 0.015, hole 5 mm 0.049 | `--gate` |
| B drawn faces (block with a bore, 17/9 deg to the grid; a 4 mm protected layer with a cavity cut into it) | 0.02 mm | (CAD snap: planes and cylinders only, within one voxel; ledger C-02) | flats 0.0000, bore 0.0001 (mean radius 4.9999 of 5.0), protected layer's inner face 0.015 | `--gate` |
| F ripple at 1-10 mm (a 40 mm wave tilted 13/7 deg) | 0.05 mm | not measured on the old path | 0.016 | `--gate` |
| J one clean solid | no bad edge, no point contact | | 0 / 0 / 0, one body (after welding as written: the exact cut can leave a float-coincident sliver) | `--gate` |
| K same job twice | same bytes | | PASS (11-27, test P's runs, frozen d0c5b557 Release): switch on, the stand at 64 and Top Motor Mount at 32 each run twice through the CLI, every STL identical (md5 a291591b, 8be33153); switch off twice identical too | |
| M off path unchanged | same bytes as before | | stand at res 64, switch off, against TOReview's tip build (same TO sources as 2b40bcf4) (below) | |
| P Release time | within 10 % | | **FAIL.** Switch on against off, same frozen Release build, real seconds (two runs each): the stand at 64, 112 / 145 against 51 / 81 (+120 %); Top Motor Mount at 32, 352 / 384 against 132 / 164 (+167 %). Peak memory 0.39 against 0.19-0.21 GB, and 1.07-1.58 against 0.24-0.28 GB. Where it goes, Top Motor Mount: the optimiser 137 s against 97 (250 iterations against 200); meshing the surface 87 s; about 90 s not in any log line (a profile is running). The stand: same 40 iterations, but the optimiser outside the solve takes 55 s against 16, of which the re-fits are 9 s. **Profiled (11-27, `sample`, the stand at 64, `--threads 1`, same build):** on ONE thread the switch costs +18 % wall (150 against 127 s) and +9 % busy CPU, and the optimiser takes the same time either way (110 against 108 s). So the work the switch adds is small; what it loses is PARALLEL SPEED. Outside the solve, the optimiser goes 3.6 times faster on 6 threads with the switch off, and only 1.4 times with it on: code under the switch runs on one thread. Candidates: the re-fit move measure (a serial whole-grid loop and a sort on every re-fit), `extend_into_empty`, the band weights of the re-fit, and in the export the frozen bodies' distance queries and the keep regions' union (Manifold, 12 s on one thread). Next: a profile on all threads, in a lock hold, to name them. Not fixed. | |

## The open choice: basis, reach, knot spacing

Test A's worst distance over all eight shapes (mm), the shape fitted the way the optimiser's own re-fit fits it, its zero surface meshed directly:

| basis, reach | knots 1 voxel | 1.5 voxels | 2 voxels (today's rule at 1.7 mm) |
|---|---|---|---|
| Gaussian, 2 (today) | 0.029 | 0.076 | 0.134 |
| Gaussian, 3 / 4 | 0.094 / 0.106 | | |
| Wendland C2, 2 / 3 / 4 | 0.032 / 0.020 / 0.020 | - / 0.077 / 0.108 | - / 0.138 / 0.138 |
| Wendland C4, 2 / 3 / 4 | 0.098 / 0.025 / 0.020 | - / 0.083 / 0.079 | - / 0.134 / 0.136 |
| cubic B-spline (reach 2 by degree) | 0.022 | 0.075 | 0.119 |
| **cubic B-spline, band-weighted fit** | 0.022 (more knots than voxels: the fit interpolates, the weight cannot act) | **0.040** | **0.049** |

The band-weighted fit puts weight 1 on the voxels within 1.5 voxels of the surface and 0.01 elsewhere (plsm_solve_normal's W, which existed and was never armed): only the surface carries geometry, so the fit spends its accuracy there. Flat walls go from 0.02 to 0.002 mm with it. Reading: the B-spline is the best basis at every spacing, and the cheapest (64 knots per point; Wendland reach 4 at one voxel touches about 270). Settled for the switch: **cubic B-spline, band-weighted fit**. The knot spacing is set by the real-part runs below.

## Reference table, before and after

### 2040 Extrusion Stand at res 64 (quick part; 77 % of it frozen, so this rung keeps only the frozen set and the design barely moves)

Release build, same job; "before" is TOReview's tip build (same TO sources as 2b40bcf4). Wall patches = TOReview's measure_surface.py, 3 mm patches on sloped and curved walls (the drawn flats and sharp edges are counted apart).

| run | margin (certified -> file re-check) | grams (file) | wall patches: median / 90th pct / worst | share over 0.05 mm |
|---|---|---|---|---|
| before (today's export) | 4.696 -> 4.731 | 90.5 | 0.092 / 0.32 / 0.56 mm | 68 % |
| switch off (this branch) | byte-identical to before (test M) | | | |
| stage 3 on | 4.679 -> 5.014 | 84.5 | 0.000 / 0.09 / 0.17 mm | 37 % |
| stage 3 on, run twice | byte-identical files (test K) | | | |
| stage 1 (TOReview's, face loads) alone | 4.896 | 90.5 | 0.104 / 0.32 / 0.57 | 71 % |
| stage 1 + stage 3 | 4.884 -> 4.979 | 87.3 | 0.023 / 0.32 / 0.85 | 39 % |

Why the file is 6 g lighter: it follows his 211 keep regions EXACTLY, where today's file keeps every frozen voxel whole (half a 3.4 mm voxel past a keep region's boundary) plus the Catmull-Rom overshoot into empty neighbours (probed point by point). Without stage 1 the frozen faces come from stamped voxels (smoothed as today's export does); with stage 1 they come from the drawn faces by true distance.

What the real part forced (all fixed, all inside the switch): the design-box check read the grid's margin as a design box (the export silently fell back); 91 frozen bodies queried one by one (47 s; merged by depth: 11 s); a body list that moved its meshes under the distance finders (crash with two or more bodies); keep regions joined by a second, nudged union along faces that are now exactly the part's (bad edges: now joined before the one cut); two voxels or two keep regions that share only an edge (now fused 0.01 mm); pinch points where the mesher snapped a saddle onto a grid point (two sheets at one float position: each copy moves 1 um into its own solid).

### Hold 1 of the reference batch (2026-11-25, Release, frozen binary 157609bc, switch on; stage 1 off)

"Before" is ledger D (TOReview's runs of the released worker CLI). Wall patches as above; their count n changes because the drawn flats are now exact and counted apart.

| part (res) | before: versions, margin, grams | after: versions, margin (certified -> file), grams | wall patches before: median / p90 / worst, share > 0.05 | after |
|---|---|---|---|---|
| Stand (128) | 1; 2.40; 86.6 g | 1; 2.39 -> 2.65; 84.8 g | 0.160 / 0.33 / 0.40, 98 % (n 145) | 0.000 / 0.15 / 0.25, 38 % (n 16) |
| Top Motor Mount (96), rung 0.68 | 4 versions; 1.64; 105.3 g | 4 versions; 1.64 -> 1.61; 104.5 g | 0.011 / 0.26 / 0.57, 35 % | **0.083 / 0.32 / 0.78, 64 % (worse)** |
| Top Motor Mount, rung 0.38 | 1.67; 100.6 g | 1.67 -> 1.64; 99.7 g | 0.037 / 0.28 / 0.61, 46 % | **0.057 / 0.30 / 0.81, 56 % (worse)** |
| Stand v4 (96) | NO version (file not one clean solid, X-05) | 1; 1.84 -> 1.88; 77.2 g (through the VOXEL export: design-box runs fell back; fixed since, not yet re-run) | - | 0.198 / 0.30 / 0.59, 93 % (voxel export) |

Pictures (depth-tested, same camera: as drawn | today | stage 3): `stage-3-pics/stand128_drawn_today_stage3.png`, `stage-3-pics/topmotor_drawn_today_stage3.png`. On Top Motor Mount the stage 3 file is visibly cleaner: round cut-outs where today's are voxel-stepped, exact countersinks, no stepped bumps at the joints. The side "lumps" on the stand are frozen pads that, with stage 1 off, can only come from voxels: they look alike in both.

**The 3 mm patch measure misread exact files; replaced by an area-sampled one.** TOReview's script finds its patches around mesh CORNERS, so an exact drawn face (a few large triangles) barely counts, and the two files are not sampled alike. `measure_area.py` (beside this file) samples both surfaces evenly by AREA and classes each 3 mm patch as DRAWN (on the drawn part within 0.05 mm), CUT (the optimiser's own surface) or SEAM (both), leaving sharp patches apart as before. Worst residual per patch, mm:

| file | cut surface: n, median / p90 / worst, share > 0.05 | seams: n, median / worst, share > 0.05 | drawn: worst, share > 0.05 |
|---|---|---|---|
| Stand 128, today | 22, 0.010 / 0.158 / 0.231, 41 % | 0 | 0.41, 5 % |
| Stand 128, stage 3 | 100, 0.006 / 0.008 / **0.009, 0 %** | 0 | 0.45, 3 % |
| Top Motor Mount 0.68, today | 4, 0.022 / 0.107 / 0.142, 25 % | 49, 0.238 / 0.568, 73 % | 0.40, 5 % |
| Top Motor Mount 0.68, stage 3 | 23, 0.112 / 0.249 / 0.299, **56 % (worse)** | 11, 0.168 / **0.190**, 100 % | 0.52, 9 % |
| Top Motor Mount 0.26, today | 25, 0.062 / 0.139 / 0.175, 56 % | 55, 0.228 / 0.625, 67 % | 0.39, 4 % |
| Top Motor Mount 0.26, stage 3 | 45, **0.000 / 0.053 / 0.129, 11 %** | 13, 0.149 / **0.277**, 100 % | 0.44, 8 % |

Sampling, fixed so the numbers repeat: the drawn part at one point per 0.05 mm x 0.05 mm (400 per mm2), each file at one per 0.25 mm x 0.25 mm (16 per mm2), 4,000 patch centres, 3 mm patches of 30 points or more, random seed 1. The BEFORE files are ledger D's own STLs (agent-scratch/toreview/baseline), read in place.

Old ruler against new, one row per part (wall patches, the old tool's single class; the new tool's cut surface):

| part | old tool, today -> stage 3: median / worst, share > 0.05 | new tool (cut surface), today -> stage 3: median / worst, share > 0.05 |
|---|---|---|
| Stand 128 | 0.160 / 0.40, 98 % -> 0.000 / 0.25, 38 % | 0.010 / 0.23, 41 % -> 0.006 / 0.009, 0 % |
| Top Motor Mount 0.68 | 0.011 / 0.57, 35 % -> 0.083 / 0.78, 64 % | 0.022 / 0.14, 25 % -> 0.112 / 0.30, 56 % |
| Top Motor Mount 0.26 | (not run on the old tool) | 0.062 / 0.18, 56 % -> 0.000 / 0.13, 11 % |

Why they differ: the old tool centres its patches on mesh corners, so it samples each file by its tessellation (today's voxel files have corners everywhere, stage 3's exact faces have few) and mixes drawn faces, cut walls and seams in one class; the new one samples by area and keeps them apart.

The "drawn" worst (0.4-0.5 in every file) is his own countersinks and small fillets, which no quadric fits at 3 mm. Reading: cut walls and seams are clearly better except the cut surface of Top Motor Mount's 0.68 version, where the rough chunk beside the box sits; at res 32 that roughness is already in the unfinished function surface, where this run has stamped voxels, so the stage 1 + stage 3 run decides whether the exact protection depths remove it.

 Two causes are being separated (runs at res 64, stage 1 on and off): (1) without stage 1 its protected faces come as stamped voxels (2,000-6,600 per version), now without the curvature flow that used to sand them; (2) between re-fits the optimiser's steps leave bumps at the knot spacing (about 3 mm) in the function itself, which the old export's fill, resample and flow low-passed and the exact surface shows. The re-fit now runs just before each margin probe so every certified design is re-normalised (the slope band), and its move is measured only where phi has a slope.

## Not done yet

- V-02's part-in step (`voxel/voxelize.cpp`): the analysis grid is still yes/no voxels by centre. What stage 3 does instead: the print file is cut by the EXACT drawn part, and the optimiser's function is carried across the drawn faces (so the design's decision reaches the face). Giving boundary voxels their true part fraction would change every margin at the part's skin, lattice certificate included (rule 26), and interacts with stage 2's stiffness law (A-01, E x fill against E x fill^3); it belongs with stage 2's certificate, through TOReview.
- The function's slope at the printed surface sits near 2, not 1 ("Where I stopped" has the table); what the band rule protects, the file's margin against the certified one, is within 2 %. Holding it nearer 1 (a penalty on |grad phi|, Noël 2020) is not built.

- B-02, B-03, P-10 (single-pass basis build, a thread pool, per-iteration allocations): priced, not done. About 50 thread start-ups and six vector allocations per iteration cost milliseconds against a 1-28 s solve per iteration; the basis is built once per run. Worth doing only in the stage 10 clean-out.
- X-03 (the file re-check writes an STL and re-runs the whole analysis): the re-check is stage 1's R-07 (TOReview's to_run.inc); unchanged here.

## Research behind it (2026-11-25)

Read for this stage: 01-research.md section 3a; Swierstra 2020 section 4.3 (slope bound); Noël 2020 sections 1 and 7.1 (B-splines "promote smooth designs", slope held by a penalty on |grad phi|). Searched for newer work:

- Adaptive immersed isogeometric level-set topology optimisation (Struct Multidisc Optim 2025; free copy at par.nsf.gov/servlets/purl/10655130): higher-order B-spline level sets give smoother designs, and the analysis follows the smooth boundary. Supports the B-spline choice here, and idea 3 below.
- Smooth geometry extraction from SIMP results by a signed-distance RBF with volume preservation (arXiv 2512.06976, Dec 2025), and a sequential SIMP-to-level-set refinement (arXiv 2605.04735, 2026): both take the surface from a smooth function and then refine the SHAPE by optimisation, not by mesh smoothing (our candidate 6).
- 3MF Volumetric extension v1.0 (published 2025-11-13): a 3MF file can carry a level-set function instead of triangles (idea 1).
- Not found free: Sotola et al. 2024 on surface-based smoothing of optimisation results (title and DOI still to pin down).

## Ideas beyond the plan (for discussion with him; NOT acted on)

1. ~~Ship the design, not a mesh.~~ DROPPED 2026-11-25: no consumer slicer reads 3MF's implicit/level-set extension (his earlier check, confirmed: PrusaSlicer, Orca and Bambu import STEP and 3MF meshes and triangulate everything at import; nothing found for implicit 3MF).
2. **A CAD file for engineers (STEP)** (he likes this one; discussion 2026-11-25). What blocks a STEP that edits in every CAD program: (a) a solid is a jigsaw of smooth patches stitched at about 0.001 mm, and cutting an organic, many-holed surface into a clean patch layout automatically is the hard part (nTop's own route, quad mesh to CAD body, "works reliably only on fairly simple models"); (b) patches that miss each other by more than the CAD kernel's tolerance import as loose surfaces, not a solid; (c) the seams with his drawn faces must be cut exactly on both sides, and each kernel (Parasolid: SolidWorks, NX, Onshape; ShapeManager: Fusion, Inventor; CGM: CATIA; OCCT: FreeCAD) re-checks with its own tolerances; (d) thousands of patches are slow; (e) "editable" means direct edits (holes, cuts, fillets, shell), never a feature history. What we have for it: his drawn faces stay his exact B-rep faces (only trimmed), our shape is already one smooth cubic B-spline (fitting is well posed), and OCCT, already in core, can build NURBS faces, sew, fix, check validity and write STEP. Proven route elsewhere: quad remesh, then a subdivision surface, then NURBS patches (Rhino, Fusion). Next step if he wants it: a one-part prototype, checked valid in OCCT and FreeCAD, opened by him in his CAD program, before any estimate.
3. **Certify the smooth surface itself.** Today the strength check reads voxels and the file is smooth. An analysis that cuts the voxels at the true surface (Andreasen 2020; the 2025 immersed paper) would make "certified = printed" true by construction and steady the stress number across resolutions (stage 2's A-02). Large; joint with stage 2.
4. **Auto and engineer controls for smoothness.** Auto: the knot spacing follows the printer's line width and the resolution; nothing on screen. Engineer: one "Detail (mm)" control, the smallest feature the shape may have, with an (i).
5. **A last polish on the real surface.** After the ladder, a short shape pass with the analysis on the smooth surface (Swierstra 2020 stage 3; the 2026 preprint). The "designed" look, possibly some margin back. Cost: about one more optimisation.

## For #362 (carried by TOReview with the switch flip; not edited here)

Known until then: with the switch on, the `.meta` beside the coefficients names the basis "wendland" for the new bases, and the device preview is still meshed from the voxels, so it differs from the print file (rule 12) until the second change lands.

1. `core/src/cli/run_job.cpp:480`, the `.meta` writer. Replace the two lines

        << "basis " << (variant.plsm_basis_kind == PlsmBasisKind::Gaussian
                            ? "gaussian" : "wendland") << "\n"

   with

        << "basis " << plsm_basis_name(variant.plsm_basis_kind) << "\n"

2. `app/TopOptKit/Sources/TopOptBridge/bridge.cpp:348-360`, `export_display_mesh`. Give it the imported part (`const topopt::TriangleMesh* part`, the STEP's `StepModel::drawn_mesh()` or the STL's mesh) and, when the run has them, `const std::vector<topopt::FrozenFaceSet>* frozen` and `const topopt::StepModel* model`; then, before the resample:

        if (topopt::to_surface_on() && part != nullptr) {
          std::string why;
          topopt::TriangleMesh m = topopt::function_surface_mesh(
              v, solved_grid, *part, factor, /*printed_iso=*/0.5, &why, nullptr, frozen, model);
          if (!m.triangles.empty()) { scratch = std::move(m); return scratch; }
        }

   (`#include "topopt/level_surface.hpp"`). The display then IS the print file's surface (before the finish's thin-spot cleanup and the Keep clear cut, which the CLI applies after).
