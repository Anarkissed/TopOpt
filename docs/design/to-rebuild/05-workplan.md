# TO rebuild: the workplan

Status 2026-11-22: APPROVED by the reviewer (rulings 06:18Z and 06:48Z); both helper prompts below are approved as they stand. Helpers start after the stage 0 move is released and the maintainer has created their channels. The maintainer's OK on helpers: "Yes two helpers are good as long as they're Opus 5.5". Each helper gets its own small channel (reviewer, TOReview, the helper) and never posts in #TORebuildGroup.

## History rewritten 2026-11-25 20:50 EST (the maintainer: "Yes. Rewrite the history")

The lead's mistake: commit 0ee02fda added `docs/design/to-rebuild/papers/` (29 copyrighted PDFs) with a whole-folder `git add`, and it was pushed to the public repository. The branch was rewritten from that commit on, without the folder, and force-pushed; the files it ends in are identical. Commit ids written in these documents before this note are the OLD ones where they fall in that range:

| old | new |
|---|---|
| 0ee02fda | d6047d2b |
| 15ebb451 | 7173c540 |
| ca157cb7 | 6ee89639 |
| bf4aa356 | 05f33677 |
| 6c5ff9eb | ecc3ebbb |
| 33451f43 | a49fd8da |
| 4d495dd6 | 52c4d894 |
| 8b3656ba | e74b4c08 |

Rule from now on: files are added to a commit BY NAME, never by folder, and `git show --stat HEAD` is read before every push.

## Resumed 2026-11-25 19:35 EST

Paused at 94 % weekly usage for five minutes; the maintainer: "Keep going, do not stop, I will reset at 100%". The work tick is back; helpers told. First on the queue now: job B's credited cells and the frozen-mask check for LatticeReview; the reviewer's ruling on stage 2; Top Motor Mount both ways and the pad depths (lock), then the stage 1 report.

## Work queue (the lead's own; kept stocked; top item first)

THE NIGHT OF 2026-11-26 (written 03:50 EST). The maintainer is asleep. His words: "I want you working throughout the night", "I especially want you building while waiting in the queue", and on the six additions "I agree, yes to all 6", and "If anything comes up, please hold off on the question until I wake up and message - and move on to the next task." So: NO question to him tonight, no phone ping. A question goes in the list "For him in the morning" below, a provisional choice is taken where it is safe and marked provisional, and the next item starts.

Every tick: record what finished (stage file, commit by name, push), then do the next open item. Order agreed with him: B1, B3, B2, B5, B6, B4, with section A alongside.

LOCK, 08:45: FREE since 08:43 (my stage 1 hold ended early; both runs recorded; #362 told). A1 DONE: the stage 1 report went to the reviewer 08:44 (awaiting the ruling on the flip). Queue: #362's S1, then `b1_suite.sh` (waits for an "S1" lock line to come and go, or the file `b1_go`), then `b5_stage2.sh` (waits for B1's `done`, or `b5_go`). The paused no-lock runs (pad sweeps, the trial build's sample parts) were resumed at 08:43.
Running without the lock: `sample_pad.sh` (the sample bracket, six pad settings). STOPPED 04:05: `stage1_padtm.sh` after its first run (Top Motor Mount res 64, pad 3 mm: four versions, margins 2.33 to 2.35, 105.1 / 102.9 / 101.1 / 98.9 g): the Mac was in 11.6 GB of swap with the kernel at 185 % CPU, my two low-priority runs were getting 3 to 6 % of a core each, and the made parts now carry the pad question better.

DONE 08:05 beside the lock run: the too-small notice proved in a build (two faults found and fixed; stage 1 file); the stage 2 bar against the reading's own true value measured in a build (stage 2 file: real stiffness misses by a hair, E x fill^2 passes, reading high). A tip build with the cli is at `agent-scratch/toreview/build_s6` (2e9aac2e). In a report's `pads`, `thickness_mm` 0 means not measured (a fixed pad does not measure it): to tell #362 at hand-over.

NOTED 08:15 (LatticeReview): the Organic strength block now repeats byte for byte on claude/organic-engine 77c32c36 (the frame solve asks for Eigen's LDLT; Accelerate's did not repeat). OPEN ITEM: once that tip is in my base, put `test_to_same_job_twice` and the stage 1 lattice check back to exact bytes for the frame block (they compare to six digits and skip `residual` today).

A2, 08:55: the automatic pad at strength 1.0 freezes 9526 voxels on the sample bracket against 3702 at a fixed 3 mm (pads of 7.1 and 8.6 mm behind the two thick faces, 2.0 mm behind the thin tab), which is why the everything-on versions are 4 to 13 g heavier. Strength 1.0 looks too deep; `sample_pad_low.out` (opt13) is running the bracket at 0.2 and 0.4 (3.2 / 4.5 mm behind 50 mm). The 1.4 runs still in `sample_pad64.sh` matter less now.

A. Already agreed:
- A1. Stage 1 report to the reviewer once the two lock runs are recorded (draft at the top of `stages/stage-1-true-loads.md`).
- A2. The pad's one number: tables and PICTURES of the shapes around the fixed faces from the two sweeps; a recommended curve strength for him in the morning.
- A3. PARTLY DONE 05:30: the report now carries `"pads": [{face_id | region_id, thickness_mm, pad_mm, automatic}]` on the face path (syntax-checked; not yet run). NOT done, on purpose: making the automatic rule the DEFAULT. It needs the curve's strength, which waits on the sample sweeps and his word; until then the default stays a fixed 3 mm and the rule is asked for with `TOPOPT_PAD_MM=auto[:strength]`.
- A4. WRITTEN 04:50 (`part_scale.hpp`, the report's `"too_small"`, the pop-up's wording proposed in the stage-1 file); arithmetic checked; owed: one run on a made thin part.
- A5. RULE WRITTEN 05:15 (`auto_resolution`, table in the stage-1 file): one voxel per line width, capped at 192, floored at 32. Not wired into a job (the app sends the number).
- A6. DONE 04:15: `tests/unit/to_reference_reading.hpp` gives the reading's own true value on the plate and the ring (the same sums as the script: 2.809 / 2.619 / 2.306 and 2.213 / 2.104 / 1.914), and both tests E print each pairing against it; unit checks for `interlayer_tension_field` and a reading over a size pass standalone. Owed: one built run of tests E for the new lines (with B1).
- A7. TOSolver's stage 5 REVIEWED AND MERGED 05:07 (merge f79c038e of its 5b40fb2e): the solve functions in `to_solve.cpp`, one solver-settings value and a per-run solver state, the sensitivity terms on all cores, the reduced element product, the stable smoothers behind `TOPOPT_SOLVER` (default = today). Its same-bytes check passed on the stand at res 64. B1 runs the whole suite on this merged tip. TOSurface's stage 3: not yet reported for merge.

B. Approved tonight:
- B1. The WHOLE test suite on my branch (never run; lock, 1 to 3 h). Record every failure with its cause; fix mine, name the rest.
- B3. DONE 03:45: the slicer gives 138.3 g on the sample bracket; my first model read 12 % low and is replaced by a shell model within 3 % (stage-2 file). Owed: re-make the stand's printed-grams figures with it.
- B2. DONE 04:05 (parts; their runs follow): `core/tests/tools/to_sample_part.cpp` makes three. A, the L-bracket with a filled corner (as drawn 4.33 against 1.5; fixed faces with 4 mm and 10 to 70 mm behind them). B, a beam 120 x 30 x 24 mm held on both END faces (120 mm behind each) and pushed down 600 N on a mid-span boss (as drawn 5.46). C, a hook hanging from its top face (80 mm behind it), 25 N on its upturned tip, off the stem's line (as drawn 3.95; at 250 N it stood at 0.40, because printed upright the stem hangs across the layers). Not a plate with holes: the mesh maker is box-shaped only, and round holes need a different one. Pad sweeps: A running (`sample_pad.sh`), B and C queued behind it (`sample_pad_bc.sh`).
- B5. Stage 2 on optimised designs at full resolution (the stand and the sample bracket: unset / stiff / size 1.8 mm; lock, about 1.5 h).
- B6. DONE 04:30: two sources read (01-research.md, last section). Filament-printed nylon 12 gives a length of 0.13 mm, sintered PA12 0.6 to 1.0 mm. Under a voxel either way after his half rule, so his parts keep a one-voxel reading; PA12 is not added to the table until the reviewer rules on stiffness for materials whose length is under a voxel.
- B4. STARTED 06:10: the lead's branch (stages 1 and 5) and TOSurface's stage 3 (d0c5b557) merged in a private scratch clone (`agent-scratch/toreview/best`, never pushed; one conflict, in `to_rebuild_tests.cmake`, both sides kept; the main files syntax-check). `b4_best.sh` is building it and then runs the three made parts at res 64 today's way and with everything on (drawn-face loads, the automatic pad at strength 1.0, the smooth surface), with pictures. Top Motor Mount with everything on: after that, under the lock.

For him in the morning (questions held, with the provisional choice taken):
- PA12's stress-reading length: the only filament-printed value found gives 0.13 mm (0.07 after his half rule), under a voxel on every job, so stage 2's reading over a size will do nothing for his PA12 parts whatever is decided. PROVISIONAL: PA12 left out of the table (it keeps today's solve and reading). Two papers that may hold a better value are behind paywalls; titles in 01-research.md if he wants to fetch them.
- "Too small for the nozzle": PROVISIONAL rule = the part's thickest section under six line widths (two walls and a gap). Is that the right threshold, and should thin ARMS on a thick part be flagged too?
- Automatic resolution: PROVISIONAL rule = one voxel per wall-line width, capped at 192, floored at 32. Under it every part over 86 mm runs at 192 (8 times the voxels of 96). What should the cap be on the iPad and on the Mac, and should Auto aim for a coarser voxel (two line widths)?
- THE BIGGEST ONE: must every face he fixed stay joined to the part even when the part does not need it for strength? On the sample bracket the thin fixed tab is a spare support (the base already holds the part), so the optimiser removes what joins it, and the export bridges it back with a straight bar. Today this is avoided only by the pad happening to be thick enough. Options to put to him: (a) a rule that every fixed face keeps a printable path to the body (the optimiser is told, not the export); (b) leave it to the pad and the bridge; (c) warn him that a fixed face is doing no work and ask. Pictures: `stages/stage-1-pics/sample_a_res64_today_vs_face.png`. No provisional choice taken: nothing built.
- Top and bottom skin thickness for printed grams: his jobs do not carry top / bottom layer counts. PROVISIONAL: Bambu Studio's defaults (1.0 mm top, 0.6 mm bottom). Ask: should the app send his slicer's layer counts with the job?

WAITING ON OTHERS: the reviewer's ruling on which reference a reading over a length is judged against (nothing more in `analyze.cpp` until then); #362's sheet types in a base I can build (the sheet row of the stage 2 lattice table).

## Ideas beyond the plan, in discussion with the maintainer (NOT acted on)

Raised 2026-11-26 after his question "why can't the app just scale everything up proportionately, run the TO, then scale everything back down?" (he asked to discuss first; nothing below is built):

- Why scaling up and back changes nothing and breaks things: the grid is a count of voxels across the part, so it scales with the part and every grid artefact stays; the lengths that do NOT scale are the printer's and the material's (line width, smallest wall, layer height, lattice cell, the stress-reading length) and the depths he types in mm.
- What small parts really show: a fixed physical length that is large against the part (a 3 mm pad on a 10 mm block). Proposed, awaiting his word: (1) a rule that every length in the core is either physical (mm, never scaled) or relative to the part, no bare numbers; (2) the pad defined from the printer and the part (a few wall-line widths, capped at a share of the local thickness) and not a bare 3 mm; (3) resolution chosen from the part's size and the line width (Auto), with an engineer's override; (4) a test that runs one part at two sizes with loads scaled to the same stress: the same shape, and walls still at least two real line widths at both sizes; (5) a plain pop-up when a part is too small for the nozzle to leave the optimiser any printable room.

DECIDED by the maintainer, 2026-11-26 01:15 (on the pad, from the list above): "Pad in wall-line widths with a cap sounds right." and "I definitely think it should be automatic first, with a warning/notice explaining what happens when if you manually do it and get it wrong." So:
- Auto (the default, nothing on screen): the pad is a number of wall-line widths, capped at a share of the material it sits in.
- Engineers may type a pad depth; when they do, a notice says in plain words what goes wrong if it is too small (the anchor or load can tear away from the body: a version may be refused) or too large (it freezes material the optimiser could have removed, and on a small part can block the design altogether). Five words on screen at most, the rest behind the (i) (his help-text rule).
- REFINED with him, 2026-11-26 01:25: the pad follows the size of the model. His question: "Can't the number of lines adjust based on the size of the model?"; the rule put to him and "Agreed": the pad is a SHARE of the thickness of material behind that face (measured locally, so a thin tab on a big bracket gets a thin pad), never less than two wall-line widths (his print result: one line does not print). On the ceiling: "I would even place the ceiling at something crazy like 1000mm", so there is in effect NO ceiling: the share alone sets the depth on thick parts. (Consequence told to him: on a 60 mm body a quarter share freezes 15 mm behind the face, which is material the optimiser cannot remove.)
- STILL TO SETTLE WITH HIM, with numbers: the SHARE (a quarter was only an illustration). The stand at 2 / 3 / 4.5 mm (queued for the lock) and the small scenario part (3.0 refused the smallest version, 3.75 shipped all, 4.5 lost two) are the evidence to bring.
- DECIDED 2026-11-26 03:15, his answers:
  - The pad's shape: "Yes" to growing with the square root of the local thickness, a two-line floor, no ceiling. Its one number (the strength of the curve) is still to settle; he has no other part to test on ("Can you design a sample?"): a made sample part is owed.
  - "Definitely a pop-up for when a part is too small for the nozzle with a recommendation for either a different nozzle size or to switch to resin printing."
  - "The automatic resolution from part size is also great."
  - "I would also like to note that this is all during the 'Auto' settings. And that these settings (resolution/pad thickness) should be manually adjustable if in 'Manual' mode."
  - The test that runs one part at two sizes: "Not necessary. Place it in the v2 google spreadsheet". PARKED: row added to "TopOpt: ideas for v2" 2026-11-26.
  - The rule that every length is physical or relative: not answered; not adopted.
  - The area-spring anchor (`face_spring`): "Put in the v2 Spreadsheet". PARKED: row added 2026-11-26. It is not the default and is removed from v1 with the stage's switch at the flip.
  - He cleared LatticeReview's leftover local branch himself (2026-11-26), so no local ref still holds the removed PDFs' commit except TOSolver's untracked files on disk.

## 0. Where the work stands (kept current; newest first)

**2026-11-25, 19:10 EST.** Work done while the lock was held (release 20's suite since 14:44).

- Test E, second half (thick ring, pressure on its curved inner face through the drawn-face loader; textbook 2.333; 89af53d1), first run: the loaded area is the drawn face's to 0.00 % at all four resolutions. All-or-nothing 2.19 / 2.28 / 2.34 / 2.32 (worst miss 6.3 %, spread 6.9 %); fill with E x fill^3 (today) 4.10 / 3.94 / 3.54 / 3.77 (miss 75.7 %, spread 15.8 %); fill with E x fill 2.16 / 2.24 / 2.22 / 2.23 (miss 7.2 %, spread 3.7 %). Read over 0.9 / 1.8 / 3.6 mm: spread 3.7 / 8.2 / 2.1 %. So today's rule for a cut voxel (stiffness E x fill^3) reads 76 % high on a loaded curved face, where on the plate it read 16 % high; E x fill is steady and 7 % low. A-01 is confirmed twice over and is stage 2's first change.
- As-drawn check on the stand, Top Motor Mount and Stand v4 with the three load settings: in `stages/stage-1-true-loads.md` (new; the stage's running report, with the lines #362 changes at the flip).
- Material length from published values (maintainer: "use published values"): `01-research.md`, last section. Printed PLA 2.4 to 4.6 mm, printed ABS 4.1 mm.
- Read TOSurface's branch and stage file (ea406c7f): on the stand at res 128 the wall error's median goes 0.160 to 0.000 mm; Top Motor Mount got worse (0.011 to 0.083) and it is separating two causes. Nothing to correct.
- Disk fell to 13 GB (under the 15 GB floor); #362 cleared 7 GB of finished builds; 22 GB free.

**2026-11-25, 17:00 EST.** Input for stage 8 from #362 (TORebuildGroup, 21:57Z): sheet laws per member width, 2 to 8 cells, on claude/notes28-sheet-laws (e32b2c47; evidence/2026-11-25-sheet-laws-thin-members). Open decisions the report leaves to the reviewer and stage 8: the knockdown rises with block width (8-cell reads 1.6 to 1.75 times the 2-cell); every row's peak sits in the cut cells beside the gripped faces (the grip artifact already ruled on for struts); off the grips every row is below today's law; today's law reads low by its own method. Measured floor 2 cells for both sheets. Nothing is wired into a verdict. Stage 8 must not take a law from these tables before the reviewer rules on the grip question.

**2026-11-25, 09:10 EST.** The refused 0.30 version on the drawn-face path is explained (full log kept: `agent-scratch/toreview/testK_face_full.log`). It is solve 19: the design at that step is in 17 separate pieces, the multigrid solve grows its error (relative residual 136 after 2,500 cycles), and the Jacobi-CG fallback runs to its cap (122,682 iterations) at residual 0.092, so the version is refused. On today's path the same part goes through 8 to 11 pieces and its fallbacks happen to finish inside the cap. So this is not a fault of the drawn-face loader: it is the two faults already on record meeting (the optimiser breaks the part into pieces; the solver cannot settle a broken part quickly), and which side of the cap a run lands on is luck. Stage 1's report says so; the fix belongs to stage 5 (solver) and the stage 3/4 boundary (no loaded piece left unattached). Also seen: the refusal's own wording is wrong ("tolerance 1e-08 ... after 4 iterations" for a solve run at 1e-04 for 122,682 iterations); handed to TOSolver.

**2026-11-25, 07:55 EST.** Test K with stage 1's switch on (TOPOPT_FACE_LOADS=face), demo job.

- First attempt (3,626 s): 14 files, 0 differ, but the numbers were today's to the digit: the simple-job path (job.fixture_faces, `to_setup.inc`, `to_analyze.inc`) tagged the old way and never read the switch. Fixed at 7f6c9aaa (`tag_face_by_stage`, loadcase.hpp). #362's own lattice strength-check code in run_job.cpp tags the old way in two more places (near lines 11337 and 12647); those go on the replacement list handed to #362 at the flip.
- Second attempt, on the drawn-face path for real (2,927 s): 11 files compared, 0 differ; gate passes. Rule 21 holds with the switch on, on this job.
- What changed on the demo part with the drawn-face path: version 0.70 margin 1,176 (today 965), version 0.50 margin 437 (today 301), and version 0.30 is REFUSED ("linear solve did not converge ... stalled at residual 0.0922 after 4 iterations"), where today it ships with margin 70. Same in both runs. Not yet explained. Likely the same family as TOSolver's finding on this part (the design step leaves loaded pieces with no path to a support, which no solve can settle); owed: find which solve stalls and why the held voxels of the drawn-face path change it, before the stage 1 report.
- From TOSolver (stage 5 step 1, 3ed70347): the slow solves have two causes, an unstable smoother weight (0.6) and a geometric coarse grid that does not suit a part's shape; the existing disarmed algebraic level cuts Top Motor Mount from 1,584 iterations to 58-107. Its plan is with the maintainer for discussion. Mine from it: a design step must not leave a loaded piece unattached (optimiser fault, stage 3/4 boundary).

**2026-11-25, 06:20 EST.** Test K answered. The rerun (5,351 s) kept both runs and showed where they differ: the 3MF library stamps random p:UUID ids on every write (three per file); the .meta carries two wall-clock times and the output folder's own path; build_orientation.json carries one wall-clock time. With exactly those blanked, 14 files compared, 0 differ: the shape, the fields and the report are the same bytes both times, with an unrelated solve in between. Control: one changed byte in a field file and one renamed key are both caught. The test now blanks those three things and nothing else, has `--compare A B` for two kept folders, and is registered as a gate under `ctest -C Long` (over an hour while the demo part's solves fall back to the slow solver, so a plain ctest skips it). Rule 21 is met on today's path; it must be run again with stage 1's switch on before the flip.

**2026-11-25, 04:30 EST.** Measured beside #362's lock holder (build on three cores, no lock), from commit e704ba16. Both helpers started (channels TOSurface-Group, TOSolver-Group).

- Test E, plate with a hole at 30 degrees, textbook 3.03, hole radius 3 / 4 / 5 / 6 voxels, multigrid solve, 248 s: all-or-nothing 2.20 / 2.50 / 2.65 / 2.73 (worst miss 27.5 %, spread 24.4 %); fill with E x fill^3 (today) 3.42 / 3.43 / 3.15 / 3.52 (16.2 %, 11.7 %); fill with E x fill 2.48 / 2.69 / 2.66 / 2.84 (18.3 %, 14.7 %). None meets rule 5 (5 % and 10 %). Read over a fixed size on the E x fill arm, spread only: 0.9 mm 14.7 %, 1.8 mm 6.3 %, 3.6 mm 7.8 %. So a fixed-size reading does settle across resolutions; no arm yet reads the right peak.
- Test K, the demo job twice with an unrelated solve between, first run ever (7,596 s on a shared machine): 14 files compared, 7 differ: each version's .3mf and _alpha.meta (sizes differ by 0 to 8 bytes). The other 7 files are identical, and both runs print the same margins, masses and solver iteration counts, so the suspicion is a time or id written into those files, not the geometry. NOT YET SHOWN: the test deleted both runs. It now prints where each pair first differs and keeps both runs when any differ; it reruns with the next lock job. Stage 1's switch cannot flip until this test passes (reviewer).
- Seen in test K, handed to TOSolver: on the demo part (48x32x48) the multigrid solve diverges from solve 9 on (relative residual grows to 38 to 326) and every such solve falls back to Jacobi-CG for 17,000 to 70,000 iterations. The same in both runs.
- For stage 3 (TOSurface's ask): the pad and protected faces are also handed on as geometry (`frozen_sets.hpp`, `MinimizePlasticOptions::frozen_sets`, commit be77631b), filled only with the switch on.

- Owed in stage 2 (from #362, 2026-11-25): the certificate's member-width guard measures width on the voxel staircase and reads about two voxels thin (52.3 mm read as 47.8), so an all-lattice part is called "not certified" for too few cells across. #362 fixed the sheet types only, outside analyze.cpp (branch claude/notes28-sheets-strength, 2f5ac5ce, "ANALYZE GUARD (sheets):"); all-lattice STRUT parts still get the thin reading. Stage 2 is held to `core/tests/validation/test_lattice_sheets_strength.cpp`, block "THE GUARD'S CASE", line "[guard member]" (gyroid box 49 x 57.6 x 62.4 mm, 4.8 mm cells: 1.3 cells across before, 10.208 after), and must give the strut case the same true-width reading.

**2026-11-24, night.** Hold lifted by the maintainer ("Get started right away"; 24-hour wait waived; machine shared with #362 through HEAVY.lock and the channel #362_and_TOReview).

- Stage 0 move: DONE in the tree (commit d1f00b8a, on #362's 559d094b), approved by the reviewer as five included files. PROOF PENDING: `agent-scratch/toreview/stage0_proof.sh` builds a frozen copy of commit b760e6c9 (`agent-scratch/toreview/src0`) once #362's release 19 suite frees the lock, compares run_job.cpp's object before and after (as built, and with asserts off if they differ), runs the three source-reading tests and one small job. Result in `stage0_proof.out`. Then: hand b760e6c9 to #362 in #TORebuildGroup, push, report to the reviewer.
- Stage 0 tests, measuring only (`core/tests/to_rebuild_tests.cmake`): A surface of known shapes (today 0.12 to 0.24 mm against 0.05); C loaded area and D protection depth (today: area up to 13 % off, nothing loaded in 6 of 18 cases, depth up to 1 voxel off); E strength against a textbook stress (written, first numbers need the build).
- Stage 1, written AHEAD of its build, all behind the one switch `TOPOPT_FACE_LOADS` (`to_stage_switch.hpp`; default = today, unchanged): the drawn-face loader (`face_loads.hpp/.cpp`: area, centre and force exact in 18 of 18 cases standalone; protected share within 0.05 voxel), wired into `loadcase.cpp` (loads, host tags, pads in mm via `TOPOPT_PAD_MM`, protection depth in mm, regions, scenarios, optional area springs for anchors); the stop rule watches the design's own stress (P-15, `plsm.cpp` + `minimize_plastic.cpp`); a version's file is checked before it is shown (R-07, `to_run.inc`). Syntax-checked only; NOT built, NOT run on a part.
- Stage 1, not written: A-05 (the plain "too weak as drawn" line needs a report key agreed with #362); R-08 (one accept rule) moves to stage 2, where loop, certificate and file check get one number; the bridge's own copy of the tagging (#362); the lattice's region mask uses the protection's voxel layers (`to_export.inc` `region_lattice_mask`, bar R5: joint with LatticeReview before the default flips); the export's keep regions.
- Stage 2, written ahead: `stress_measure.hpp/.cpp` (stress averaged over a ball of a stated diameter in mm), read in test E beside today's peak and beside the same solve with stiffness E x fill instead of E x fill^3 (A-01). Not built.
- Next with the lock: the proof; then build the tree's tip and run tests A, C/D, E; then the stage 1 table on the reference parts with the switch at voxel / face / face_spring (three settings), pad 2 / 3 / 4.5 mm.

## 1. Who does what

Fewest helpers that save real time: two, each for ONE stage, each started only after stage 0's split is released (before that every stage would edit `run_job.cpp`).

| lane | who | work packages, in order |
|---|---|---|
| Lead | TOReview (me) | the probe build; stage 0; stages 1 and 2 (with LatticeReview in the group channel); then 4, 6, 7 to 10 |
| Surface | helper TOSurface | stage 3 only |
| Solver | helper TOSolver | stage 5 only |

Both helpers are well-specified build work, so they run on Opus 5.5 (his 11-14 order and his words above); I keep design and review. When a helper's stage is released its tree is removed with his OK and the helper ends. Whether stages 7 to 10 get a helper is asked again in the report for stage 6, with the numbers in hand; nothing is assumed now.

What changes against section 3 of the plan, so that no file has two owners: the speed items that live in the optimiser loop, the basis, export and finish (P-05, P-10, B-03, X-03, F-04) move from stage 5 to stage 3's lane, and M-04 (the margin stop rule in `minimize_plastic.cpp`) moves to my stage 6. Stage 5 keeps the solver and the shared solve file only.

## 2. File-ownership map

After stage 0 the TO code in `run_job.cpp` lives in five files of its own (moved 2026-11-24 on top of #362's 559d094b; reviewer ruling 2026-11-25 04:02Z). They are INCLUDED by `run_job.cpp` at the place the code stood, so it is still one translation unit and nothing else in #362's file changed. Each becomes a real `.cpp` with its own header in the stage that rewrites it.

| new file | holds |
|---|---|
| `core/src/cli/to_export.inc` | the print-file export chain (export mesh, finish, file re-check) |
| `core/src/cli/to_analyze.inc` | `analyze_job` |
| `core/src/cli/to_setup.inc` | `build_job_setup` |
| `core/src/cli/to_strengthen.inc` | `strengthen_versions` and its helpers |
| `core/src/cli/to_run.inc` | `preflight_job`, `run_job`, `refinish_job` |
| `core/src/simp/to_solve.cpp` | from `simp.cpp`: `simp_compliance`, `simp_scenarios_compliance`, `effective_design_mask`. NOT moved in stage 0: it is the solver helper's second commit in stage 5 (after its bridge-way test), a pure move; no one else's file. |

New repo tests live in `core/tests/unit/test_to_*.cpp` and are registered in `core/tests/to_rebuild_tests.cmake` (one include line in `core/CMakeLists.txt`); each lane adds its tests there.

| files | stages 1 and 2 | stage 3 | stage 5 | later |
|---|---|---|---|---|
| `to_run.inc`, `to_setup.inc`, `to_analyze.inc`, `loadcase.cpp`, `io/face_tag.cpp`, `fea/assembly.cpp` (`traction_loads`), new `fea/face_loads.cpp` + `face_loads.hpp`, `to_stage_switch.hpp`, new `simp/stress_measure.cpp` + header (stage 2) | Lead (1) | - | - | Lead |
| `analyze.cpp`, `gate_diagnosis.cpp`, `settings/` | Lead (2) | - | - | Lead |
| `plsm.cpp`, `plsm.hpp`, `plsm_basis.hpp`, `plsm_frac.hpp` | - | TOSurface | - | Lead (4, 6) after stage 3 is released |
| `mesh.cpp`, `finish.cpp`, `surface_operator.cpp`, `cad_project.cpp`, new `level_surface.cpp`, `to_export.inc`, `voxel/voxelize.cpp`, `io/step*` | - | TOSurface | - | Lead (4) after stage 3 |
| `fea/multigrid.cpp`, `matfree.cpp`, `fea_matfree.hpp`, `geneo.*`, `recycle.*`, `contact.cpp`, `hex_element.cpp`, `to_solve.cpp` | - | - | TOSolver | Lead |
| `minimize_plastic.cpp`, `to_strengthen.inc`, `job.cpp`, `production.*`, MMA files, `plsm_topology.hpp` | untouched until stage 4 / 6 | - | - | Lead |
| `run_job.cpp` (what is left), old lattice files, `core/src/lattice_layout`, lattice laws in `fea/` | LatticeReview / #362; never ours | | | |
| `bridge.cpp`, the app | #362 | | | |
| `core/CMakeLists.txt`, `core/tests/unit/CMakeLists` | each lane adds only its own new-file lines; I merge | | | |

**The branch point already holds stage 1's hunks in two files that are not mine afterwards** (reviewer ruling 2026-11-25 06:54Z). Both helpers branch from 2b40bcf4, which carries, switched off by default (`TOPOPT_FACE_LOADS`, `to_stage_switch.hpp`): in `plsm.cpp` the stop rule's `watched` margin and in `plsm.hpp` the field `PlsmMarginProbe::design_margin` (ledger P-15); in `minimize_plastic.cpp` the lines that fill `design_margin` in the margin probe. From the moment the helpers start I do not edit `plsm.cpp` or `plsm.hpp` until stage 3 is released; anything stage 1 or 2 still needs there I ask of TOSurface in one line. `minimize_plastic.cpp` stays mine and untouched by both helpers. No file in TOSolver's list is touched by stage 1 or 2: `fea/face_loads.cpp` (new) and `fea/assembly.cpp` (`traction_loads`) are mine, and stage 2's work is in `analyze.cpp` and `simp/stress_measure.cpp`.

Two points where lanes meet, settled now: (1) stage 2 changes the strength number in `analyze.cpp` while stage 3 changes the surface; neither edits the other's file, and the "certified shape equals exported shape" check is run by me when both are in. (2) Stage 1's exact loaded area needs the drawn face, and stage 3's part-in step produces the true distance; stage 1 ships on `face_tag.cpp` alone and takes the distance field when stage 3 lands.

## 3. Order, under one HEAVY.lock

One heavy job at a time on the Mac means lanes overlap in writing and reading code, not in building and measuring. Each lane keeps its heavy jobs short (targeted tests, two fixed jobs) and saves the full reference table for its gate.

1. **Now, me:** the "best I can do" probe (one sparse tree, never merged, only the arms that decide an open choice, reference parts at their derived resolution), and stage 0's measuring: the rest of the "today" table and tests A, E, K, M written.
2. **After the next install is on his iPad:** 24-hour notice in #TORebuildGroup, #362 and LatticeReview confirm no open branch on the ranges, then the stage 0 move in one short window, handed to #362 at once. Proof: same CLI output bytes on two reference jobs before and after, lattice ctests green.
3. **When stage 0 is released, with his OK:** TOSurface and TOSolver start. I do stage 1, then stage 2.
4. **Gates:** each stage is released on its own by #362. Order when two are ready together: 1, 2, 3, 5 (stage 5 last because it needs the reviewer's sign-off and changes no result).
5. **Then, me:** stage 4 on the released stage 3, stage 6, and on.

Lock manners for three lanes: no lane holds the lock over a wait; a full reference table (about an hour to several, by part) is announced to me first so two do not queue blind; #362's release gate always goes first.

Whole path, unchanged from the plan: about 7 weeks with these two helpers, about 11 alone; stages 0 to 3 about 2 weeks with helpers.

## 4. Merge and release path

helper branch -> I review the diff and the stage file -> I merge into `claude/topopt-review-rebuild-3c317f` -> report to the reviewer with the table -> ruling -> #362 takes the named commit (cherry-pick or merge, their choice), runs the release gate and installs. Never a new core into the release tree before phase B. Stage 5 additionally waits for the reviewer's sign-off before I merge it. After a release: helper deletes its builds; its tree is removed with his OK, plain `git worktree remove`.

## 5. Helper prompt: TOSurface (stage 3)

Paste as the first message of a new session. Branch point: commit 2b40bcf4 on origin/claude/topopt-review-rebuild-3c317f (reviewer ruling 2026-11-25 06:54Z).

````text
You are a helper agent on the TopOpt topology-optimiser (TO) rebuild. Your name is TOSurface. Your lead is the agent TOReview; the reviewer rules on its work; Nadim is the maintainer. You do ONE work package: stage 3, smooth surfaces. You report to TOReview only, on your own agent-comms channel (members: reviewer, TOReview, you; tools comms_post / comms_read). You never post in #TORebuildGroup. Until your channel exists, write your report in your stage file and stop.

SET UP
- Repo: ~/dev/TopOpt/TopOpt. Make your own SPARSE worktree from commit 2b40bcf4 (on origin/claude/topopt-review-rebuild-3c317f; `git fetch origin` first): `git worktree add --no-checkout <path> -b <your branch> 2b40bcf4`, then `git sparse-checkout set --no-cone --stdin < tools/sparse-evidence.txt`, then `git checkout`. Work only there.
- Read first, in this order, and nothing else until you need it: docs/design/to-rebuild/02-plan.md (your stage row and your modules in section 4), 03-rules.md, 04-tests.md, 05-workplan.md (the file-ownership map), then the ledger items named below in 00-review.md (search for the id, read the item, not the file), then FILES.md for where things are.
- Already in your branch point, written by the lead for stage 1 and switched off by default (core/include/topopt/to_stage_switch.hpp): in plsm.cpp the stop rule's `watched` margin and in plsm.hpp `PlsmMarginProbe::design_margin`. Keep both as they are; the lead no longer edits plsm.cpp or plsm.hpp, and asks you in one line if stage 1 or 2 needs anything there. The TO code that used to sit in run_job.cpp is now in core/src/cli/to_*.inc, files run_job.cpp includes in place (one translation unit); yours is to_export.inc.
- Your gate test exists: core/tests/unit/test_to_surface_known_shapes.cpp (test A; today 0.12 to 0.24 mm against 0.05; run with --gate). New tests go in core/tests/unit/test_to_*.cpp and are registered in core/tests/to_rebuild_tests.cmake, never in core/CMakeLists.txt.
- Heavy jobs (any build, any optimise run, any test run over a minute): one at a time on the whole Mac through ~/dev/TopOpt/HEAVY.lock. Take it only after it has stayed empty, with noclobber: `( set -C; echo "<name> <what> $(date)" > ~/dev/TopOpt/HEAVY.lock )`. Never steal it. Remove only your own line. Build in your own tree, never in the worker's cliPath.
- Commit small, push your branch, never force-push. Commit messages end with: Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
- You do not start helpers. You do not release; every release is #362's. You do not message #362, LatticeReview or the reviewer; anything for them goes to TOReview in one line.

THE GOAL, IN HIS WORDS
"I want it to look as if each result was specifically designed, with as few bumps and stairstepping as possible." Targets (rule 9): exported surface within 0.05 mm of the true shape at a 1.7 mm voxel; drawn flats within 0.02 mm; bores round within 0.02 mm; ripple at 1 to 10 mm at most 0.05 mm. "The drawing follows the print file. Always."

WHAT YOU BUILD (ledger X-01, X-04, B-01, P-03, P-04, P-11, P-16, P-17, V-02, C-01 to C-03, I-02, F-01, F-04, B-02, B-03, P-05, P-10, X-03)
1. The print surface is the zero surface of the optimiser's own function, meshed directly and joined exactly to the drawn faces. The voxel-fill resample, the CAD snap and the curvature flow go once tests A, B, F and J pass without them. The thin-spot cleanup stays (it goes in stage 4, not yours).
2. The part comes in as a true distance to the drawn part, not yes/no voxels; frozen sets are true distances; no silent refit.
3. A crease-free basis with its reach and knot spacing chosen by measurement: Wendland C2 / C4 / cubic B-spline x reach 2 / 3 / 4 knot spacings; knot spacing 2, 3, 4 line widths. The probe table TOReview gives you narrows this; you confirm it on all reference parts.
4. The slope of the function held in a band at the surface (Swierstra 2020), so the mesher and the fill count see the same wall.
5. Everything new sits behind ONE temporary switch until the gate passes; the switch and the old path are deleted in your close-out.
The shape that is certified and the shape that is exported must be the same surface (test E's part, margin within 2 % between the two).

YOUR FILES (no one else edits these while you work)
core/src/simp/plsm.cpp, core/include/topopt/plsm.hpp, plsm_basis.hpp, plsm_frac.hpp; core/src/mesh/mesh.cpp, finish.cpp, surface_operator.cpp, cad_project.cpp and their headers; a new core/src/mesh/level_surface.cpp (+ header); core/src/cli/to_export.inc; core/src/voxel/voxelize.cpp (the part-in step only); core/src/io/step*; your new tests under core/tests/unit; core/CMakeLists lines for your new files only.
NOT YOURS, do not edit: anything in core/src/fea (it includes the lead's new face_loads.cpp); core/src/simp/stress_measure.cpp; core/include/topopt/to_stage_switch.hpp, face_loads.hpp, stress_measure.hpp; core/src/simp/to_solve.cpp, analyze.cpp, minimize_plastic.cpp, gate_diagnosis.cpp; core/src/cli/to_run.inc, to_setup.inc, to_analyze.inc, to_strengthen.inc, loadcase.cpp, job.cpp, run_job.cpp; core/src/io/face_tag.cpp; core/src/settings; core/src/lattice_layout and every lattice file; bridge.cpp and the app; plsm_kernel.hpp and plsm_topology.hpp (read only). If you need a change in one of these, ask TOReview in one line.

TESTS YOU OWN (04-tests.md): A, B, F, J pass; K, M, P hold.

PAPERS (text copies in ~/dev/TopOpt/agent-scratch/toreview/research/txt/, PDFs in docs/design/to-rebuild/papers/, what each says in 01-research.md section 3a; read the section first, a paper only when you need its detail)
Surface from the function: Swierstra, Gupta, Langelaar 2020 (arXiv 2004.05448); Andreasen, Elingaard, Aage 2020; Christiansen 2014 and 2015. Basis and reach: van Dijk 2013 section 2.1; Noel 2020 (cubic B-splines); Wei 2018; Dunning 2018. Slope: Swierstra 2020 (largest slope about 2.2 x the coefficient bound). Earlier tries in this project and their numbers: 01-research.md "What this project already tried".

THE BAR FOR "NOT POSSIBLE"
You may not report that something is not possible, not printable or not viable unless: every paper named in this prompt that bears on it is answered by name; it was built and measured on ALL reference parts (04-tests.md) at three settings or more, in a table; and the report names the target that failed, by how much, and what meeting it would cost. Anything less is reported as "not done yet", with what is missing.

WHEN YOU REPORT (once, at the end, or in one line when blocked)
The reference table before and after; which repo tests moved from failing to passing; the open choice you settled, with its settings; anything you refused and the rule. Numbers and pictures in your stage file under docs/design/to-rebuild/stages/; the message itself is short.

RUN LEAN — HIS STANDING ORDER, AND IT APPLIES TO YOU AND TO EVERY HELPER
His weekly usage is limited, and this project has run it to 99% before. Every message, read and run costs him. So:
- Speak only when addressed, or when a phase or stage is finished. No acknowledgements, no "starting now", no FYIs, no progress pings.
- Keep reports short:
  - the findings, the numbers and the question for him;
  - the detail goes in the docs, not the channel;
  - never paste logs or long tables into a message.
- Read what you need, not everything twice:
  - search, then read excerpts;
  - keep FILES.md and the ledger as your memory, instead of re-reading big files.
- Use the smallest run that answers the question. Use a light probe before a full ladder, and never a full suite when a targeted test proves the point (the release gate is #362's).
- Do the work yourself unless splitting it saves real time:
  - every helper costs him a whole agent's usage;
  - propose the fewest helpers that do the job, and start none without his OK;
  - no helper of a helper.
- One heavy job at a time on the Mac, through HEAVY.lock.
- When blocked, stop and ask in one line, rather than burning cycles on guesses.
- If his usage reaches 95%, finish the step you are on, write down where you are, and stop until he says go.
- Every helper prompt you write carries this RUN LEAN section word for word.

STANDING RULES
- Disk and heavy jobs:
  - One heavy job at a time, through HEAVY.lock.
  - Start no heavy job under 15 GB free.
  - Delete your own builds after a push.
- Helpers, ONLY with his OK:
  - each in its own worktree, created SPARSE with tools/sparse-evidence.txt (on Nov 14 four full-copy helper trees, 6 GB each, took the disk to 18 GB);
  - each removed, with his OK, once its work is merged;
  - never `git worktree remove --force`;
  - never `git worktree prune` from the device VM.
- Repo hygiene:
  - Never force-push. Never touch another agent's worktree. Tests must not dirty tracked files. Deleting data needs his OK.
  - Never write in ~/.topopt-worker. Never build in the worker's cliPath.
  - His part and job files are read in place, read-only, never copied into a repo.
  - Maintainer data (materials.json, fixtures, lattice_print_tests.json, flexible_*) is never edited.
- What he sees:
  - "Preview is the spec": what the app shows is exactly what core builds. Any gap gets one plain line, never silence.
  - No warning cards for engine shortfalls.
  - Talk to him in plain words; pictures over numbers.
- Measuring:
  - Check the build configuration (Release) before quoting any time. A Debug build once inflated a 28 s figure to 590 s, and four decisions rested on it.
  - Read everything before concluding (his rule).
  - Verify every claim against the current code. Notes from August may be stale.
- Printing: every print file passes the print checks before he sees it:
  - flat footing on the bed;
  - no mid-air starts;
  - bridge reach within the limit;
  - no paper-thin open slot;
  - nothing thinner than 2 lines (0.9 mm on his 0.4 mm nozzle).
````

## 6. Helper prompt: TOSolver (stage 5)

````text
You are a helper agent on the TopOpt topology-optimiser (TO) rebuild. Your name is TOSolver. Your lead is the agent TOReview; the reviewer rules on its work; Nadim is the maintainer. You do ONE work package: stage 5, faster solves. You report to TOReview only, on your own agent-comms channel (members: reviewer, TOReview, you; tools comms_post / comms_read). You never post in #TORebuildGroup. Until your channel exists, write your report in your stage file and stop.

SET UP
- Repo: ~/dev/TopOpt/TopOpt. Make your own SPARSE worktree from commit 2b40bcf4 (on origin/claude/topopt-review-rebuild-3c317f; `git fetch origin` first): `git worktree add --no-checkout <path> -b <your branch> 2b40bcf4`, then `git sparse-checkout set --no-cone --stdin < tools/sparse-evidence.txt`, then `git checkout`. Work only there.
- Read first, in this order, and nothing else until you need it: docs/design/to-rebuild/02-plan.md (your stage row and your modules in section 4), 03-rules.md, 04-tests.md, 05-workplan.md (the file-ownership map), then the ledger items named below in 00-review.md (search for the id, read the item, not the file), then FILES.md for where things are.
- New tests go in core/tests/unit/test_to_*.cpp and are registered in core/tests/to_rebuild_tests.cmake, never in core/CMakeLists.txt. The lead's stage 1 and 2 code in your branch point (face_loads.cpp, stress_measure.cpp, loadcase.cpp, switched off by default) is not yours and touches none of your files.
- Heavy jobs (any build, any optimise run, any test run over a minute): one at a time on the whole Mac through ~/dev/TopOpt/HEAVY.lock. Take it only after it has stayed empty, with noclobber: `( set -C; echo "<name> <what> $(date)" > ~/dev/TopOpt/HEAVY.lock )`. Never steal it. Remove only your own line. Build in your own tree, never in the worker's cliPath.
- Commit small, push your branch, never force-push. Commit messages end with: Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
- You do not start helpers. You do not release; every release is #362's. You do not message #362, LatticeReview or the reviewer; anything for them goes to TOReview in one line.

THE GOAL
Run time. Today one solve takes about 1,500 CG iterations on Top Motor Mount where tens are normal for multigrid, and the solve is 65 to 77 % of a run (ledger K). Stages 4 and 6 will add solves, so this stage is not optional. Same answers, fewer iterations, less work per iteration.

WHAT YOU BUILD (ledger E-05, B-05, B-06, S-05, E-01, and the mixed-precision paragraph in section K)
1. Find why the iteration count is that high before changing anything: per-level residual drop on the two fixed jobs of test P. Report the cause in one paragraph to TOReview before the rewrite.
2. Smoother: damped Jacobi (today) against Chebyshev. Element product: per-element stored dof numbers and copies against a grid stencil. Three settings or more each, all reference parts.
3. The eleven process-wide solver setters become one settings value passed in; a result must not depend on which solve ran first (test K).
4. The sensitivity loop in the shared solve file runs on all cores.
5. The single-precision V-cycle: the switch does nothing on the production path today (guard at multigrid.cpp:2925; ledger K). Either delete that path or revive it with a looser inner tolerance and measure it; your table decides.
The solver is shared with Flexible, through the app bridge: app/TopOptKit/Sources/TopOptBridge/flexible_squish_fe.cpp calls fea_solve_mgcg_matfree, fea_solve_cg_matfree (when only Jacobi is wanted), fea_set_matfree_threads (one thread for the display solve) and fea_matfree_reset_mg_stagnation_latch. Its hard case is the M2 stand, all lattice, E from 0.16 to 34 MPa (read that file's header; do not edit the file).
- Those four entry points keep their signatures and their meaning. Any change you need is named to TOReview in one line FIRST, and goes to #362; you do not make it yourself.
- Add one core test, your first commit, that solves the bridge's way (one thread, latch reset, MG-CG, then Jacobi-only) on a soft graded E field like the M2 stand's; green before and after every change.
- The app-side Flexible tests (FlexibleBatchM2Tests, FlexibleBatchMStressTests, FlexibleBatchMVerifyTests and the other FlexibleBatchM* tests) run in #362's gate, not yours. Name them in your handoff so #362 runs them.
Nothing merges without the reviewer's sign-off, which TOReview asks for.

YOUR FILES
core/src/fea/multigrid.cpp, matfree.cpp, fea_matfree.hpp, geneo.*, recycle.*, contact.cpp, hex_element.cpp, the solver-settings declarations in core/include/topopt/fea.hpp; core/src/simp/to_solve.cpp (new: YOUR SECOND COMMIT moves simp_compliance, simp_scenarios_compliance and effective_design_mask out of core/src/simp/simp.cpp into it, unchanged, with its tests green before and after; that move is the only edit you make to simp.cpp); your new tests; core/CMakeLists lines for your new files only.
NOT YOURS, do not edit: plsm*.{cpp,hpp}, minimize_plastic.cpp, analyze.cpp, anything in core/src/mesh, core/src/cli, core/src/io, core/src/voxel, core/src/settings; core/src/fea/assembly.cpp and face_loads.cpp (the lead's), core/src/simp/stress_measure.cpp, lattice*.cpp, strut_*.cpp, beam_network.cpp, sparse_ldlt.cpp, algebraic_coarsen.*; core/src/lattice_layout; bridge.cpp and the app. If you need a change in one of these, ask TOReview in one line.

TESTS YOU OWN (04-tests.md): K and P, plus these existing unit tests, green before and after every change: test_matfree, test_matfree_cubic, test_matfree_threads, test_mgcg_matfree, test_geneo, test_recycle (the solver), and the Flexible set test_flexible_curve, _data, _faces, _field, _job, _press, _recommend, _run, _squish. Margins and printed grams in the reference table must not move beyond solver tolerance; if one does, stop and report it.

PAPERS AND LEVERS (a report of "the iteration count cannot come down" must answer every one of these by name: by measurement, or by item with the reason)
Papers (not yet in docs/design/to-rebuild/papers/; open copies exist for the arXiv ones; ask TOReview for any you cannot open, do not work around a bot check):
- Alexandersen & Lazarov 2015, Comput. Methods Appl. Mech. Engrg. 290:156-182, doi 10.1016/j.cma.2015.02.028 (arXiv 1411.3923). A spectral coarse-space preconditioner built for topology optimisation, whose quality does not depend on the solid / void stiffness contrast; one preconditioner is reused across design iterations; 26 million unknowns in 26 hours on one thread.
- Wang, de Sturler & Paulino 2007, Int. J. Numer. Meth. Engng 69:2441-2468, doi 10.1002/nme.1798. The bad conditioning of these systems is the density ratio times a constant-density problem; a rescaling removes the first factor; Krylov recycling carries information along the sequence of systems.
- Spillane, Dolean, Hauret, Nataf, Pechstein & Scheichl 2014, Numer. Math. 126:741-770, doi 10.1007/s00211-013-0576-y. GenEO: a coarse space from local eigenproblems with a bound that does not depend on the coefficients. The project's geneo.* is this; its settings were chosen once and not swept.
- Amir, Aage & Lazarov 2014, Struct. Multidisc. Optim. 49:815-829, doi 10.1007/s00158-013-1015-5. Multigrid-CG for topology optimisation, with the solve tolerance relaxed during the optimisation at no loss in the result.
- Aage, Andreassen & Lazarov 2015, Struct. Multidisc. Optim. 51:565-572, doi 10.1007/s00158-014-1157-0. Multigrid-preconditioned Krylov at large scale (the PETSc framework); the reference for what iteration counts are normal.
- Behrou, Lotfi, Carstensen, Ferrari & Guest 2021, Comput. Methods Appl. Mech. Engrg., doi 10.1016/j.cma.2021.113799 (arXiv 2012.02860). Elements below a density threshold are removed from the solve and can come back, because the design variables stay active.
- Khodak, Jung, Wynne, Chow & Kolemen 2026, Comput. Phys. Commun. 327:110304 (arXiv 2509.08765, "PCGBandit"). The solver's configuration is learned online from the run's own sequence of solves; a wrong choice costs iterations, never correctness.
Levers already in this project, as they stand in the code at 30292f31 (re-check each at your tip before you rely on it):
- Coarse warm start: exists, off unless a job carries a `warm_start` block (job.cpp:1291-1305, warm_start.cpp); the app never sends one. Nobody established why it is off. Measure it.
- Resolution continuation (solve coarse, carry the design up, finish fine): not in the code. It is well-posed now that the fill fraction has no scale parameter. Build the smallest form and measure it.
- GenEO settings: fixed constants (geneo.hpp: block size 20, eigenvalue cut 0.05, 8^3 cores, overlap 1) and an engage threshold. No sweep is recorded. Sweep the cut and the block size, three settings or more each.
- Active Domain (solve only near the surface): DISARMED today (production.cpp:97, band 0), after being measured net-negative in the stagnation regime (PR 209). Answer it by item, or re-measure once the stagnation cause in step 1 is fixed.
- Multigrid fallback: older runs on his parts logged "stagnated-latched" with 0 multigrid levels. Today's Release runs log 3 levels (Top Motor Mount) and 4 (Stand v4). Whether the hierarchy is still dropped part-way through a run is not established; step 1 must show it per solve.
History with numbers: ledger sections E, H and K in 00-review.md.

THE BAR FOR "NOT POSSIBLE"
You may not report that something is not possible, not printable or not viable unless: every paper named in this prompt that bears on it is answered by name; it was built and measured on ALL reference parts (04-tests.md) at three settings or more, in a table; and the report names the target that failed, by how much, and what meeting it would cost. Anything less is reported as "not done yet", with what is missing.

WHEN YOU REPORT (once, at the end, or in one line when blocked)
The reference table before and after; which repo tests moved from failing to passing; the open choice you settled, with its settings; anything you refused and the rule. Numbers and pictures in your stage file under docs/design/to-rebuild/stages/; the message itself is short.

RUN LEAN — HIS STANDING ORDER, AND IT APPLIES TO YOU AND TO EVERY HELPER
His weekly usage is limited, and this project has run it to 99% before. Every message, read and run costs him. So:
- Speak only when addressed, or when a phase or stage is finished. No acknowledgements, no "starting now", no FYIs, no progress pings.
- Keep reports short:
  - the findings, the numbers and the question for him;
  - the detail goes in the docs, not the channel;
  - never paste logs or long tables into a message.
- Read what you need, not everything twice:
  - search, then read excerpts;
  - keep FILES.md and the ledger as your memory, instead of re-reading big files.
- Use the smallest run that answers the question. Use a light probe before a full ladder, and never a full suite when a targeted test proves the point (the release gate is #362's).
- Do the work yourself unless splitting it saves real time:
  - every helper costs him a whole agent's usage;
  - propose the fewest helpers that do the job, and start none without his OK;
  - no helper of a helper.
- One heavy job at a time on the Mac, through HEAVY.lock.
- When blocked, stop and ask in one line, rather than burning cycles on guesses.
- If his usage reaches 95%, finish the step you are on, write down where you are, and stop until he says go.
- Every helper prompt you write carries this RUN LEAN section word for word.

STANDING RULES
- Disk and heavy jobs:
  - One heavy job at a time, through HEAVY.lock.
  - Start no heavy job under 15 GB free.
  - Delete your own builds after a push.
- Helpers, ONLY with his OK:
  - each in its own worktree, created SPARSE with tools/sparse-evidence.txt (on Nov 14 four full-copy helper trees, 6 GB each, took the disk to 18 GB);
  - each removed, with his OK, once its work is merged;
  - never `git worktree remove --force`;
  - never `git worktree prune` from the device VM.
- Repo hygiene:
  - Never force-push. Never touch another agent's worktree. Tests must not dirty tracked files. Deleting data needs his OK.
  - Never write in ~/.topopt-worker. Never build in the worker's cliPath.
  - His part and job files are read in place, read-only, never copied into a repo.
  - Maintainer data (materials.json, fixtures, lattice_print_tests.json, flexible_*) is never edited.
- What he sees:
  - "Preview is the spec": what the app shows is exactly what core builds. Any gap gets one plain line, never silence.
  - No warning cards for engine shortfalls.
  - Talk to him in plain words; pictures over numbers.
- Measuring:
  - Check the build configuration (Release) before quoting any time. A Debug build once inflated a 28 s figure to 590 s, and four decisions rested on it.
  - Read everything before concluding (his rule).
  - Verify every claim against the current code. Notes from August may be stale.
- Printing: every print file passes the print checks before he sees it:
  - flat footing on the bed;
  - no mid-air starts;
  - bridge reach within the limit;
  - no paper-thin open slot;
  - nothing thinner than 2 lines (0.9 mm on his 0.4 mm nozzle).
````

## 7. What I need from the maintainer

1. OK for two helpers, TOSurface and TOSolver, to start when stage 0 is released (not before).
2. OK to start the probe build now (the reviewer has ruled yes; it is one sparse tree and heavy jobs through the lock).
