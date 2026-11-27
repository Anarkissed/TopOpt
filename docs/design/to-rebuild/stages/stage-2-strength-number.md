# Stage 2: a strength number that holds (TOReview)

Status 2026-11-26 19:30: IN PROGRESS. Everything is behind ONE switch, `TOPOPT_STRENGTH` (unset = today, unchanged; `size` = the form below; `stiff` = a measuring arm). The certificate is shared with the lattice strength check: every change here is told to the reviewer and LatticeReview. The history below is in the order it happened; this block is where it stands.

## WHERE IT STANDS (read this first)

**In plain words, for the maintainer.** The app decides pass or fail from the stress in the single hottest little cube of the part. That number jumps when the detail level changes and is wrong at the part's edge. Stage 2 replaces it, where the detail is fine enough, with the stress averaged over a small region whose size belongs to the plastic (PLA: 1.2 mm), which is what the research says a printed part really fails by. It also shows the weight as it is printed (walls and infill), not as a solid block.

**Done and measured (all behind the switch):**
- Printed grams, checked against Bambu Studio to within 3 %; the "saved" figure against the part as drawn at the same walls and infill.
- The averaged reading, on real stiffness, with the averaging region free to sit on the part's edge. Against the textbook on two shapes at four detail levels it is never more than 4.9 % low and within 10 % across detail levels, from 1.75 voxels across upward (set as the switch point). The across-layer check is read the same way (inside the bar at 19 of 20 points; 5.4 % low at one).
- Under 1.75 voxels across, or for a material with no published length, the job keeps TODAY'S solve and reading whole, and says so (`[strength]` line, the report's `strength_reading`).
- The reviewer's rulings of 18:37Z, items 2 to 6: answered (tables below).

**Found, and not comfortable:**
- On his materials and usual detail levels the averaged reading rarely switches on (PLA needs a voxel of 0.69 mm or finer; PETG and ABS essentially never; PA6 and PA12 have no length), so for most jobs stage 2 changes the grams and not the strength number.
- Today's one-voxel reading is itself 13.9 % low on a sharp notch (the ellipse) at one detail level.
- The number he is SHOWN comes from a second judge, the re-check of the finished file on all-or-nothing voxels: 10 to 27 % optimistic on the textbook plate, and up to 2.3 times the loop's own number on the lightest carved versions. The averaged reading does not reach it.

**THE REVIEWER'S RULING of 2026-11-27 00:22Z (maintainer-approved):**
1. "One judge" APPROVED and FIRST in stage 2, because it is the number he is shown. Behind its own switch (`TOPOPT_RECHECK=fill`) so it can flip ahead of the rest. The sub-sampling k is chosen by measurement: the k at which the shown margin moves under 0.5 % when k doubles. Evidence for its flip: (a) plate, ring and ellipse through the re-check path give the certificate's numbers within 1 %; (b) his parts' shown margins before and after (expect within 1 %), and the bracket, hook and beam: shown against certificate, before and after; (c) time and peak memory of the re-check on his largest job, one thread; (d) test K; (e) lattice jobs A to D, LatticeReview told what moves first.
2. Switch point 1.75 voxels: accepted.
3. KNOWN LIMIT, stated: the across-layer reading is 5.4 % low at 2.0 voxels across where the hole is 3 voxels in radius (the in-plane reading is 4.9 % low at the same point). Accepted as a limit; no margin added ("a margin set to pass one point is tuning").
4. KNOWN LIMIT, stated: a notch whose tip radius is under 2 check voxels is OUTSIDE the bar. On the ellipse (tip radius 0.75 to 1.5 voxels) today's one-voxel reading is 13.9 % under the textbook at one resolution and 22 % apart across resolutions; E x fill^2 is 19.3 % under. No pop-up. If the check can tell cheaply that its peak sits on a feature sharper than 2 voxels, the engineer's readout may say the corner is finer than the grid and a finer resolution reads it better: measured on the ellipse first, or not built.
5. Today's E x fill^3 stays for the under-a-voxel case. Stage 1's flip items 2(b), 2(c), 2(d) received; the flip waits on 2(a) and the list.
Also ruled the same hour (stage 5): the connection-rule test on the hook PASSES; before a rung is refused for an unheld load, TRY A STEP-BACK (restore the last design whose load reached a support, halve the move limit, retry, at most 3 times), measured on the hook at pad 1.0 and on demo solve 10 with and without it, kept only if it makes more versions in no more than 10 % more time. The smoother's default is cheb:2.

**Owed, in order:**
- ONE JUDGE: the switch, k by measurement, evidence (a) to (e).
- The step-back (the optimiser's loop is in `plsm.cpp`, TOSurface's file: to agree who edits it).
- Conditions (b) to (e) again on his full-resolution parts with the size form (`b5_stage2.sh`, lock).
- The app's side (#362): show the form and the printed grams.

## The problem, in plain words

Today the app says pass or fail from ONE number: the highest stress in any single voxel. Three things are wrong with that, each measured:

1. It moves with resolution. Base as drawn: 0.97 at res 48 down to 0.33 at res 192, with the loads fixed (stage 1). PillowBlock 1.80 down to 0.91. The finer the grid, the sharper every corner looks, and the peak never settles.
2. A voxel cut by the surface is solved far too soft (stiffness = material x fill cubed), so it stretches too much and reads too much stress. On the textbook ring that reading is 76 % too high; on the textbook plate 16 % too high.
3. The margin he sees assumes his infill (x (infill/100)^1.5), while the grams he sees are for a solid part.

## What was measured (tests E, two textbook cases, four resolutions each)

| way of reading | plate with a hole: miss / spread | ring under pressure: miss / spread |
|---|---|---|
| voxel all-or-nothing, peak | 27.5 % / 24.4 % | 6.3 % / 6.9 % |
| cut voxels as today (fill cubed), peak | 16.2 % / 11.7 % | 75.7 % / 15.8 % |
| cut voxels at their real stiffness (x fill), peak | 18.3 % / 14.7 % | 7.2 % / 3.7 % |
| the same, read over 1.8 mm | - / 6.3 % | - / 8.2 % |
| the same, read over 3.6 mm | - / 7.8 % | - / 2.1 % |

"Miss" = distance from the textbook peak. "Spread" = how much the number moves between resolutions (the rule asks 5 % and 10 %). A reading over a size is below the textbook peak by design, so only its spread is judged.

## What the research says (01-research.md, last section)

A printed plastic part does not break where one point is highly stressed; it breaks when the stress over a small LENGTH of material is too high. That length belongs to the material: 2.4 to 4.6 mm for printed PLA, 4.1 mm for printed ABS (Ahmed and Susmel 2018; Susmel 2022). Reading the stress that way predicted every one of their notched test pieces within about 20 %, for sharp and blunt notches alike.

## The proposal (three steps, each behind the stage's switch, each measured before the next)

1. **Cut voxels at their real stiffness.** Removes the 16 to 76 % over-reading. Smallest change, largest error removed.
2. **Read the stress over a size, not at a point.** The size is tied to the material and the printer: a start of four line widths (1.8 mm at 0.45 mm), never above the published length for the material. One number that settles across resolutions.
3. **One judge.** The loop, the certificate and the file re-check use that same number (closes R-08: today Strengthen can overrule the loop's verdict silently). The coarse search (R-04) can then trust a coarse answer.

Not in this proposal, flagged: the smooth-surface check (certify the true surface, not voxels), which TOSurface raised and would make step 1 exact; and the infill question (item 3 above), which is a product decision.

## Questions for the maintainer

- **How cautious?** The published method predicts BREAKING against tensile strength. The app certifies against YIELD with his safety factor. Reading over a size will raise most margins (the per-voxel peak is harsh). Options: (a) take the published length as is; (b) half of it, as a cautious start until his rig can check it; (c) keep today's peak as a second, softer warning beside the new number. Recommended: (b) with (c) shown to engineers only.
- **Across layers** there is no published length. Recommended: use the same length with today's layer knockdown, and say so in the (i).
- **Auto and engineer:** Auto uses the material's own length, nothing on screen. Engineers get one control, "Stress reading size (mm)", with an (i).
- **Weight:** should "grams" and "saved" be printed grams at his infill, so they match the margin? Recommended: yes.

## Decided by the maintainer (2026-11-25)

- How cautious: start at HALF the published length, until his rig can check it; today's per-voxel peak stays as a softer second warning shown to engineers only. "Agreed."
- Across layers: the same length with today's layer knockdown, said in the (i). "agreed"
- Auto and engineer: Auto uses the material's own length with nothing on screen; engineers get one control, "Stress reading size (mm)", with an (i). "agreed"
- Weight: grams and "saved" count the plastic really used at his infill and walls, so both numbers describe the same printed part. "agreed. Never the solid unless the user set infill to 100%". (Closes M-07.)

- Which length where the papers disagree: "Let's go with the lowest published value for each." (PLA 2.4, ABS 0.46, PETG 0.7 mm; then his half rule: 1.2, 0.23, 0.35 mm.) Consequence, stated to him: 0.23 and 0.35 mm are smaller than a voxel on every job, so for ABS and PETG the new number is today's peak with cut voxels at their real stiffness; only PLA gets a reading over a size.
- Across layers, REVISED after CNC Kitchen's impact tests: the length across the layers is a FIFTH of the in-plane one. "Yes, a fifth". (Replaces "the same length" above; the layer knockdown on strength stays.)
- Across layers, REVISED AGAIN (2026-11-25 21:15) after the measurement that the across-layer term, read at one voxel, is what still climbs with resolution and decides most of his parts: the SAME size as in the plane. "Let's do same size, then." The fifth is withdrawn; the layer knockdown on strength stays.
- Still open: the nine materials with no published value.

## Reviewer's ruling (TORebuildGroup, 2026-11-26 01:37Z, approved by the maintainer)

YES: steps 1 and 2 may be written in `analyze.cpp` behind the stage switch (default = today), on these conditions:

- (a) LatticeReview reviews the diff before it merges.
- (b) A test shows the lattice check byte-identical with the switch off.
- (c) THE BAR, fixed before any run: on test E's references (the plate with a hole, the ring, at three resolutions) the shipped reading may never read MORE THAN 5 % BELOW the reference, at any resolution. Today's rule reads 16 to 76 % high (safe but wrong); real stiffness alone reads 6 to 18 % low on the plate and 7 % low on the ring (unsafe). So stiffness and reading size are judged TOGETHER against that bar, never one alone.
- (d) A material with no published length gets a plain line saying so and keeps today's reading. (In code since the commit after 372d2057: real stiffness applies only together with a reading size; `stiff` alone is a measuring arm.)
- (e) With the switch on, a before/after table of the lattice strength check (jobs A to C, plus one sheet and one Organic job) is posted in TORebuildGroup before any flip.

To tell the reviewer in the next report: after its ruling was drafted the maintainer changed two of the recorded decisions: across layers the length is a FIFTH of the in-plane one (not the same), and where sources disagree the LOWEST published value is taken.

What the bar means for the plan: a reading over a size reads BELOW the one-voxel peak by design. On test E the readings over 0.9 to 3.6 mm sat 5 to 30 % under the textbook peak. So with real stiffness the size must be SMALL enough to stay within 5 % of the reference, or the stiffness rule must read a little high to leave room. This is to be measured on test E before anything else: the pair (stiffness rule, size) that is steady across resolutions AND never more than 5 % low.

## THE BAR, measured (tests E, `[bar]` table; build e74b4c08 plus the tests, 2026-11-25 21:09)

Lowest / highest reading against the textbook peak over the four resolutions (hole or inner radius 3 to 6 voxels; voxel 2.0 to 1.0 mm, so "0.9 mm" is still one voxel), and the spread between resolutions. The bar: never more than 5 % low.

| cut voxel stiffness | read over | plate with a hole: lowest / highest / spread | ring under pressure: lowest / highest / spread | passes the bar on both? |
|---|---|---|---|---|
| E x fill (real stiffness) | one voxel | -18.3 / -6.3 / 14.7 % | -7.2 / -3.8 / 3.7 % | NO |
| E x fill | 1.8 mm | -18.3 / -13.2 / 6.3 % | -12.9 / -5.7 / 8.2 % | NO |
| E x fill | 3.6 mm | -31.9 / -26.6 / 7.8 % | -22.4 / -20.8 / 2.1 % | NO |
| **E x fill^2** | **one voxel** | **-3.8 / +4.3 / 8.4 %** | **+17.2 / +26.5 / 8.0 %** | **yes** |
| E x fill^2 | 1.8 mm | -9.8 / +0.2 / 11.2 % | +2.6 / +26.5 / 23.3 % | NO (plate) |
| E x fill^2 | 3.6 mm | -25.2 / -21.0 / 5.6 % | -11.9 / -1.0 / 12.4 % | NO |
| E x fill^3 (today) | one voxel | +4.0 / +16.2 / 11.7 % | +51.7 / +75.7 / 15.8 % | yes (safe, wrong) |
| E x fill^3 | 1.8 mm | -3.1 / +12.9 / 16.6 % | +28.9 / +75.7 / 36.3 % | yes |
| E x fill^3 | 3.6 mm | -21.9 / -12.8 / 11.6 % | -0.5 / +29.9 / 30.5 % | NO (plate) |

Reading:
1. Real stiffness (E x fill) fails the bar at every reading size on both cases, as the reviewer said it would.
2. One pair passes the bar on both cases AND holds within 10 % across resolutions on both: **stiffness E x fill^2, read at one voxel**. On the plate it is within 4.3 % of the textbook either way; on the ring it reads 17 to 27 % high (safe), against 52 to 76 % high today. It is not in the plan as written: it is a middle stiffness rule with NO reading over a size.
3. Every reading over 1.8 mm or more, with real or middle stiffness, reads 10 to 32 % under the textbook PEAK on the plate. That is what an average over a length does by design: the critical-distance method says the average, not the peak, is what breaks the part, so against the peak it must read low. The bar (measured against the peak) and the reading over a material length (the maintainer's decision, from the research) therefore cannot both hold on these cases. This is a conflict between a ruling and a decision, not a tuning problem, and it goes back to the reviewer and the maintainer before more is built.
4. The longer the reading, the steadier it is across resolutions (2 to 8 % at 3.6 mm) and the lower it reads. Steadiness and "never low against the peak" pull opposite ways.

## The reading's own true value (for the reviewer's choice between the two references)

`stages/reference_reading.py` takes the same ball average on the EXACT textbook solutions. What a reading over a size should give, against the peak:

| case | peak | over 0.9 mm | over 1.8 mm | over 3.6 mm |
|---|---|---|---|---|
| plate with a hole | 3.03 | 2.81 | 2.62 | 2.26 to 2.31 |
| ring under pressure | 2.333 | 2.21 | 2.10 | 1.89 to 1.91 |

Measured with real stiffness (E x fill), at hole radius 3 / 4 / 5 / 6 voxels (voxel 2.0 / 1.5 / 1.2 / 1.0 mm), against THAT value:

| case, size | measured | miss from the reading's true value |
|---|---|---|
| plate, 1.8 mm | 2.476 / 2.631 / 2.498 / 2.534 | -5.5 / +0.4 / -4.7 / -3.3 % |
| plate, 3.6 mm | 2.063 / 2.075 / 2.115 / 2.224 | -10.5 / -9.5 / -7.0 / -1.6 % |
| ring, 1.8 mm | 2.164 / 2.199 / 2.097 / 2.033 | +2.9 / +4.5 / -0.3 / -3.4 % |
| ring, 3.6 mm | 1.811 / 1.810 / 1.848 / 1.843 | -5.0 / -4.9 / -2.4 / -2.3 % |

So judged against what the reading is meant to measure, real stiffness with a 1.8 mm reading is within 5.5 % on the plate and 4.5 % on the ring at every resolution, including two where the voxel is larger than or close to the size; the 3.6 mm reading is up to 10 % low on the plate at the coarse end and within 2 % at the fine end. Against the PEAK the same numbers read 10 to 32 % low, which is the average doing its job. This is the case for reference (ii).

## Written so far (ahead of the gate; all behind `TOPOPT_STRENGTH`, default = today; reviewer's ruling on the shared certificate still asked)

| step | what | where | state |
|---|---|---|---|
| 1 | Cut voxels solved at their real stiffness (`stiff`, `size`) | `analyze.cpp`, the solid branch's solve only; the lattice posture's solve is untouched | syntax-checked; no effect on a part as drawn (every voxel full or empty), so it must be measured on optimised designs |
| 2 | The deciding stress read over a size (`size`): the plain maximum and the wall-aware maximum the production gate reads; the one-voxel peak kept beside it (`max_von_mises_one_voxel`) | `analyze.cpp`, `stress_measure.cpp`; the size from `material_length.hpp` or the engineers' typed size (`TOPOPT_STRESS_READING_MM` until the app carries it) | first sweep running. NOT done: the interlayer reading (a fifth of the length, under a voxel so far) |
| weight | Printed grams at the job's walls and infill (`mass_grams`; the solid figure kept as `mass_grams_solid`) | `printed_mass.cpp`, `analyze.cpp` | unit test passes. Found 2026-11-25 21:50: the grams he is shown do not come from the strength check at all but from the finished FILE's own volume (`to_export.inc`, `fb.mass_grams` = density x mesh volume), so the first wiring changed nothing he sees. Now: the file's solid grams times the printed share that the re-check's wall-and-core model gives for that same file (`voxel_mass_grams` / `voxel_mass_solid_grams`). Syntax-checked; not yet run on a job. NOT done: "saved" (needs the drawn part's printed grams at the same infill), and solid top and bottom layers |
| 3 | One judge (R-08) | `to_strengthen.inc:745`: Strengthen rewrites a version the loop rejected as accepted on its file-check margin and clears the rejection | NOT started. Proposal: the file check's margin is THE margin everywhere; the loop's own estimate is kept and shown as an estimate (a new report value), never as a second verdict. Changes what the app reads, so it goes to #362 and the reviewer first |

Found while wiring it: every reference job of his is PA12, which has no published length, so under "the lowest published value for each" the reading is the single voxel on all his parts. The sweep reads his parts over 1.2 and 2.4 mm as well, to show him what a size would do.

## Measured on his parts as drawn (build e74b4c08, 2026-11-25 20:47 to 21:05; drawn-face loads, corrected clamp)

Effective margin. "One voxel" is today's reading. The other rows are the engineers' typed size (his parts are PA12, which has no published length, so by the rule they keep today's reading; these rows show what a size WOULD do). A part as drawn has no cut voxels, so the stiffness step does not act here: this table is the reading size alone.

| part | res | one voxel | over 1.2 mm | over 2.4 mm |
|---|---|---|---|---|
| Base | 48 / 64 / 96 / 128 / 160 / 192 | 0.79 / 0.66 / 0.45 / 0.37 / 0.37 / 0.32 | 0.79 / 0.66 / 0.45 / 0.37 / 0.38 / 0.35 | 0.79 / 0.66 / 0.50 / 0.44 / 0.46 / 0.41 |
| PillowBlock | 48 / 64 / 96 / 128 | 1.32 / 1.10 / 0.90 / 0.74 | 1.32 / 1.20 / 1.03 / 0.82 | 1.35 / 1.40 / 1.03 / 0.82 |
| Pressing | 48 / 64 / 96 / 128 | 0.75 / 0.51 / 0.36 / 0.35 | 0.75 / 0.51 / 0.39 / 0.48 | 0.83 / 0.73 / 0.45 / 0.62 |
| Original stand | 96 / 128 | 4.83 / 3.15 | 4.83 / 3.19 | 5.40 / 3.77 |
| Top Motor Mount | 96 / 128 | 1.65 / 1.33 | 1.65 / 1.33 | 2.06 / 1.83 |
| Stand v4 | 96 / 128 | 2.32 / 1.96 | 2.32 / 2.03 | 2.65 / 2.66 |

Reading, honestly:
- A size smaller than the voxel reads that voxel alone, so the size only begins to act once the grid is finer than it (1.2 mm from about res 128 on these parts; 2.4 mm from about res 96).
- Where it acts it raises the margin by 10 to 40 %, as expected of an average against a peak.
- It does NOT yet make the number steady on real parts. Base from res 96 up: one voxel 0.45 to 0.32 (a 40 % fall); over 2.4 mm 0.50 to 0.41 (22 %). Better, not settled. Pressing gets LESS steady (0.45 then 0.62). Stand v4 is the one that settles (2.65 / 2.66).
- PillowBlock reads the same over 1.2 and 2.4 mm at res 96 and 128 (1.03, 0.82): another term is deciding there (likely the interlayer one, which this stage has not touched). To be confirmed.
- So the textbook result (2 to 8 % spread) does not carry over to his parts by the reading size alone. What is left varying with resolution is to be found before more is built: the interlayer term, the loads' own discretisation at a corner, or the support reaction at the held face's edge.

CONFIRMED (the reports' own numbers, same runs): what still moves with resolution is the ACROSS-LAYER term, which this stage has not touched.

| part, res | in-plane stress, one voxel -> over 2.4 mm (MPa) | across-layer tension (MPa), unchanged by the size |
|---|---|---|
| PillowBlock 96 / 128 | 14.9 -> 7.6 / 18.2 -> 8.1 | 9.8 / 12.3 |
| Base 96 / 192 | 29.9 -> 27.0 / 41.8 -> 33.1 | 9.7 / 21.1 |
| Pressing 96 / 128 | 37.7 -> 29.7 / 38.0 -> 21.6 | 10.3 / 12.5 |

On PillowBlock the in-plane stress halves when read over 2.4 mm, and the margin hardly moves, because the across-layer tension decides it; that tension is still one voxel's and climbs with the grid (Base: 9.7 at res 96, 21.1 at res 192). His decision puts the across-layer length at a fifth of the in-plane one, which is under a voxel on every job, so by that rule this term stays a one-voxel reading and stays unsteady. To put to him with these numbers: the strength number cannot settle across resolutions while the across-layer term is read at one voxel.

Two earlier sweeps of this table read "one voxel" in every column; both were wiring faults of mine (the wall-aware maximum was not read over the size; then the size was wiped when the load case replaced the options) and are not results.

## First optimised runs with the switch (the stand at res 64, drawn-face loads, build 95411b2a, 2026-11-25 22:10): little learned, two faults found

| arm | in-loop margin | file margin | grams |
|---|---|---|---|
| today | 11.77 | 4.161 -> 4.201 | 90.55 |
| real stiffness | 11.83 | 4.181 -> 4.201 | 90.55 (printed share reported 1.000) |
| real stiffness, read over 1.8 mm | 11.83 | 4.181 -> 4.201 | 90.55 (share 1.000) |

- The stiffness step moves the in-loop margin by 0.5 % here: at res 64 this part is 77 % frozen and has few cut voxels. Not a test of it.
- The 1.8 mm reading did nothing: the voxel is 3.4 mm at res 64, larger than the size. My choice of resolution was wrong for this arm; it needs res 128 or finer (under the lock).
- The printed share came out exactly 1.000 at 50 % infill and six walls. Cause: production ships with the wall-aware posture OFF (`kProductionWidthAwareKnockdown = false`: "arming is a maintainer act with a coupon behind it"), so the member widths were never measured and my condition never held. Fixed in the next commit: the widths are measured for the grams alone when the stage's switch is on. (Also corrects an earlier line of mine: the production gate does NOT read the wall-aware maximum; it reads the plain one with the scalar infill knockdown.)

Re-run after the fix (build 833697ae, 22:14): the stand at res 64 reports 85.36 g printed of 90.55 g solid, a share of 0.943 at his 50 % infill and six walls (a 2.7 mm ring, so every member under 5.4 mm wide is all wall, and most of this part is). The report's `mass_grams` and `mass_before_grams` both carry 85.36. The grams wiring works; the share is the wall-and-core model's and has not been checked against a slicer.

## Condition (b): the stage 2 switch against the lattice strength check (build 95411b2a, 2026-11-25 22:15)

Each of jobs A to C run with stage 1 off and `TOPOPT_STRENGTH=size` with a typed 1.8 mm reading, against the plain run (`test_to_stage1_lattice_check`):

- A (regular cells, on the grid): 0 strength values differ; bars and file bytes identical. UNTOUCHED.
- B (regular cells, chamfered loaded face): 0 differ; identical. UNTOUCHED.
- C (weave, frame of beams): bars and bar list identical; 13 values differ, all in the TENTH significant digit (twelve tiny bar forces, about 0.001 N, and the frame solve's residual, 7.94e-11 against 8.05e-11). That is the frame solve not repeating to the last bit between two identical runs, not the switch; the test now compares numbers to six digits. Named to LatticeReview as a rule 21 matter of its own (the same job twice does not give the same bytes in the Organic strength block).

Condition (e), the table, as far as this base can make it (build 26b8b784 plus the test, 2026-11-25 22:55). Stage 2 switch on (`size`, typed 1.8 mm), stage 1 off, against the plain run; numbers compared to six digits, timings and the frame solve's residual left out:

| job | laid lattice | strength values that differ |
|---|---|---|
| A, regular cells, on the grid | 480 bars, bytes identical | 0 |
| B, regular cells, chamfered loaded face | 2,978 bars, bytes identical | 0 |
| C, weave, load on solid | 7,692 bars, bar list identical | 0 |
| D, weave, loaded ON the lattice (box turned 17 / 9 degrees) | 3,053 bars, bar list identical | 0 |
| S, gyroid sheet on the control box | NOT MADE on this base: "This lattice type is made of sheets, and a lattice file can only be made from the types made of struts so far." | - |

So the stage 2 switch reaches no number of the lattice strength check on any strut job. The sheet row can only be filled once #362's sheet types on the new engine (claude/notes28-sheets-strength) are in this base; said to the reviewer.

For the record, stage 1's effect on job D (off -> `face`), the case LatticeReview's interim guard will refuse: margin 901 -> 1,444, weakest strut 11.0 -> 22.6, frame nodes loaded 306 -> 631.

## "Saved" against the real thing (written 2026-11-25 22:35; behind the switch; not yet run)

Today "saved" is 1 - printed voxels / part voxels: a share of SOLID volume. With printed grams it has to be read against what the drawn part itself would take on the printer at the same walls and infill. The run now writes that once per job, with no extra solve (the wall-and-core model on the part's own voxels): the report's top-level `"drawn_part": {"printed_grams", "solid_grams"}`, present only with the switch on. The saving the app should show is then `1 - version printed grams / drawn_part.printed_grams`.

Run (build 26b8b784, 22:29), the stand at res 64, 50 % infill, six walls: the drawn part 98.71 g printed of 116.39 g solid (wall share 0.696); the one version 85.36 g printed of 90.55 g solid. So the saving he is shown today, on solid volume, is 22 %; the plastic really saved is 1 - 85.36 / 98.71 = 13.5 %. Removing material from a part that is mostly walls removes mostly infill-free wall, and what is left is nearly all wall (share 0.943), so the solid figure overstates the saving by more than half here.

For #362 (to carry with the stage's flip; nothing in the app changes until then): read `drawn_part.printed_grams` and each version's finish `mass_grams` (already printed grams with the switch on) and show the saving from those two; keep `volume_saved_fraction` for nothing but the old path. One line on screen at most; the detail (walls, infill, "top and bottom layers not counted") behind the (i).

## Printed grams checked against a real slicer (B3, 2026-11-26 03:45), and the model replaced

The made sample bracket (182.4 cm3; 226.1 g solid at 1.24), sliced from the command line with the Bambu Studio installed on the Mac (bundled A1 0.4 nozzle, 0.20 mm Standard and PLA Basic presets, with 50 % sparse infill, six walls, 0.42 / 0.45 mm line widths; its own data folder in my scratch, nothing of his touched): 46.37 m of 1.75 mm filament = 111.5 cm3 = **138.3 g, a printed share of 0.612**.

| model | grams | share | against the slicer |
|---|---|---|---|
| member-width model (the first one) | 121.8 | 0.539 | 12 % LOW |
| shell model, walls only, 1.0 / 0.5 mm voxels | 138.5 / 134.5 | 0.612 / 0.595 | +0.1 / -2.7 % |
| shell model, walls and skins (1.0 mm top, 0.6 mm bottom), 1.0 / 0.5 mm voxels | 142.6 / 137.7 | 0.631 / 0.609 | +3.1 / -0.4 % |

Why the first model read low: it takes its wall share from a member-width measurement that calls any body wider than its reach (32 voxels) "too thick to measure" and gives it NO walls (the cautious choice for strength, the wrong one for grams), and it counts no top or bottom skins. The shell model (`printed_mass_shell`) counts a voxel as solid shell when it is within the wall thickness of the side surface in the layer plane, or within the skin thickness under an up-facing or over a down-facing surface, and the rest at the infill. Exact on a cube (walls only 0.360, walls and skins 0.488 of solid). It now gives the grams in the strength check and the drawn part's grams. One part, one slicer, one setting; within 3 %.

ASSUMED, for him in the morning: the skins are Bambu Studio's defaults (five top layers and three bottom at 0.2 mm, so 1.0 and 0.6 mm), because his jobs carry wall loops, line widths and layer height but no top or bottom layer counts. Skins are counted only for a part printed along the grid's z.

The earlier figures in this file from the first model (the stand at res 64: 85.4 g printed of 90.6 g; the drawn part 98.7 of 116.4 g; "13.5 % really saved") are to be re-made with the shell model.

RE-MADE with the shell model 2026-11-26 08:30 (build of tip 2e9aac2e plus the part-scale test, the stand at res 64, drawn-face loads, real stiffness): the version at 0.68 prints at 80.25 g of 90.55 g solid (share 0.886); the part as drawn prints at 92.35 g of 116.39 g solid (wall share 0.587). So the version really saves 13.1 % of the printed weight (80.25 against 92.35 g), where the solid figures say 22.2 % (90.55 against 116.39 g). The first model said 13.5 %: the saving hardly moved, the grams themselves came down about 6 %.

## What it does to the lattice strength check

Steps 1 and 2 change the solid part's reading only if applied in the shared code path; the lattice check reads strut stresses through its own laws. To be confirmed with LatticeReview before any edit: which branches of `analyze.cpp` the lattice posture takes, and that its numbers are byte-identical with the switch off.

## THE BAR against the reading's OWN true value, measured in a build (tests E, build a4ffac42, 2026-11-26 08:00)

The same matrix as above, but each reading over a size is compared with what a perfect solve would give for THAT reading (the textbook stress averaged over the same size), not with the textbook's peak. Lowest to highest over the four resolutions; "low" is the unsafe side.

Plate with a hole:

| stiffness of cut voxels | read over 0.9 mm | 1.8 mm | 3.6 mm |
|---|---|---|---|
| E x fill (real) | -11.9 to +1.1 % | -5.5 to +0.5 % | -10.5 to -1.6 % |
| E x fill^2 | +3.8 to +12.5 % | +4.3 to +16.0 % | -0.7 to +4.4 % |
| E x fill^3 (today) | +12.2 to +25.3 % | +12.1 to +30.7 % | +4.1 to +14.6 % |

Ring:

| stiffness of cut voxels | read over 0.9 mm | 1.8 mm | 3.6 mm |
|---|---|---|---|
| E x fill (real) | -2.2 to +1.4 % | -3.3 to +4.5 % | -5.4 to -2.3 % |
| E x fill^2 | +23.5 to +33.4 % | +13.8 to +40.3 % | +9.0 to +20.7 % |
| E x fill^3 (today) | +59.9 to +85.3 % | +43.0 to +94.9 % | +23.1 to +58.3 % |

What it says, plainly. Judged against its own true value, real stiffness is the most accurate (within about 5 % either way at 1.8 mm) but dips more than 5 % low on the plate at every size, so it misses the reviewer's bar by a hair to a lot. E x fill^2 is never more than 5 % low on either shape at any size (it passes the bar), at the price of reading 4 to 40 % high, the safe side. Today's E x fill^3 also passes but reads up to 95 % high. Both tests pass (rc 0); these lines are printed, not asserted. Still waiting on the reviewer: which reference the bar is judged against. Nothing more goes into analyze.cpp until then.

## A case for "one judge" (R-08), seen on the sample beam 2026-11-26 10:05

The command-line summary of the beam's run (drawn faces, pad 3 mm, res 64) reads: "vf 0.38: margin 8.22, accepted" and "vf 0.26: margin 3.55, rejected (below margin_stop)", on a job whose required margin is 1.5. Nothing is wrong with the verdict: the line prints the raw worst-case margin (`report.margin.worst_case`, `main.cpp:927`) while the verdict is taken on the margin after the print knock-down (the 0.38 version's finished margin is 2.73, a third of 8.22; by the same ratio 0.26 stands near 1.2, under 1.5). But two numbers for one version, with the verdict beside the wrong one, is exactly what R-08 is about. When "one judge" is built, this line prints the number the verdict used. Not changed now (command-line text only; the app does not show it).

## The reviewer's ruling of 2026-11-26 (18:37Z), and the first two answers

The ruling in short: for a material with a published length the reference is the reading's OWN true value (never more than 5 % under, within 10 % across resolutions); real stiffness read over the size where the size is at least the check voxel, with the switch point MEASURED; the plate's miss at 3.6 mm to be explained and fixed or the field capped; under a voxel, or with no published length, the reference is the peak and one-voxel E x fill does not ship; E x fill^2 at one voxel must first hold on a third shape (ellipse, a / b = 2); the readout says which form a job used.

### Item 3, the plate's miss at 3.6 mm: FOUND (2026-11-26 16:10). It is the ball, as the reviewer suspected, not the solve.

Method (`stages/ball_on_exact.py`, no solve at all): the EXACT Kirsch field is sampled on the test's own voxels and the reading's own ball rules are applied to it. That alone reads -11.4 / -10.8 / -8.6 / -2.6 % against the reference at hole radius 3 / 4 / 5 / 6 voxels, where the test with the solve measured -10.5 / -9.5 / -7.0 / -1.6 %. So the whole miss is there before any solving.

The cause: the reference's largest average is the ball centred ON the hole's edge (half the ball in air, only the material inside it averaged): that is where the theory of critical distances puts it, at the notch root. The reading can only centre its ball on the centre of a voxel that is at least half full, so its centre sits about half a voxel inside the material. Moving the reference's own centre half a voxel in costs -12.9 / -9.6 / -7.5 / -6.4 %: the same loss. The ball sitting a quarter of the plate's thickness off its mid-plane changes that by under 1 %.

The fix, tried on the exact field: let the ball be centred on ANY voxel that holds material (the thin rim voxels too), and count every cut voxel's material in the average, not only voxels at least half full.

| reading over | hole radius 3 voxels (2.0 mm voxel) | 4 (1.5 mm) | 5 (1.2 mm) | 6 (1.0 mm) |
|---|---|---|---|---|
| 3.6 mm, today's rules | -11.4 % | -10.8 % | -8.6 % | -2.6 % |
| 3.6 mm, fixed | -4.3 % | +1.4 % | +2.4 % | +3.4 % |
| 1.8 mm, today's rules | -14.1 % | -9.8 % | -9.4 % | -5.9 % |
| 1.8 mm, fixed | -14.1 % (the voxel is larger than the size: one voxel alone) | +0.1 % | -0.8 % | -2.1 % |

Two things this table says beyond the fix. (1) On the exact field today's rules read 1.8 mm 6 to 10 % LOW, where the test with the solve had it within 5.5 %: the solve's own error was hiding part of the ball's. The fix must therefore be measured again WITH the solve (owed). (2) The 2.0 mm voxel against a 1.8 mm size is the "size under the voxel" case of the ruling's item 4, not a miss of this form.

What the fix needs in the code (NOT written yet): `analyze.cpp` records the stress of every voxel that holds material, not only of printed ones (today a voxel under half full has no stress recorded, so the ball would average zeros), and `stress_over_size` takes its centres and its material from every such voxel. Both only when a size is read (behind `TOPOPT_STRENGTH=size`).

### Item 5, the third shape: first numbers, NOT yet usable (2026-11-26 15:45)

The ellipse test's first run (plate twenty long semi-axes wide) gave numbers at the coarsest resolution only: E x fill 3.56, E x fill^2 4.36, E x fill^3 5.04 against 5.00; at the three finer resolutions the solve returned nothing (the larger plates did not converge inside the test's limit). So one resolution says E x fill^2 reads 12.9 % LOW on a shape it was not found on, and today's E x fill^3 reads 0.8 % high. The test now uses a plate ten long semi-axes wide and says when a solve fails; its four-resolution run is in progress. No conclusion until all four are in.

### Item 5, the third shape: MEASURED at four resolutions (2026-11-26 15:51, build d5a32ae7). E x fill^2 MISSES; so does today's reading.

Elliptical hole, a / b = 2, pull tilted 30 degrees, the same plate (b = 3 mm) at b = 3 / 4 / 5 / 6 voxels; the peak over voxels against Inglis's 5.00 (the plate is ten long semi-axes wide, so the true peak is a few percent above 5.00 and every figure below is flattered by that much).

| stiffness of cut voxels | b = 3 | 4 | 5 | 6 | against 5.00 |
|---|---|---|---|---|---|
| E x fill | 3.75 | 3.59 | 4.10 | 4.23 | -28.2 to -15.4 % |
| E x fill^2 | 4.60 | 4.03 | 4.48 | 4.92 | -19.3 to -1.7 % |
| E x fill^3 (today) | 5.34 | 4.31 | 4.79 | 5.43 | -13.9 to +8.6 % |

By the ruling: E x fill^2 at one voxel does NOT replace today's reading for the size-under-a-voxel case; today's E x fill^3 stays there. But the table says more than that, and it is not comfortable: on this shape TODAY'S reading is itself 13.9 % under the textbook at one resolution and 4.2 % under at another, and swings 22 % between resolutions. The sharper the notch (tip radius b^2 / a = 1.5 mm here, 0.75 to 1.5 voxels), the less any one-voxel reading can hold it. The round hole (radius 3 to 6 voxels) flattered all three forms. For the reviewer: numbers sent; what the size-under-a-voxel case should do on sharp notches is open.

### Item 3 with the solve, and a first look at item 2's switch point (2026-11-26 16:20, build of 0a1d4286)

Two forms of "the ball may sit on the part's edge" were built and run on both shapes, real stiffness (E x fill):
- FORM A (committed, 0a1d4286): centred on any voxel holding material; every cut voxel's material counted, with the stress the solve gives in it.
- FORM B (tried, NOT kept): centred anywhere, but only printed voxels (at least half full) averaged.

The plate, against the reading's own true value, by how many VOXELS the size spans:

| size | voxel | voxels across | form A | form B | before |
|---|---|---|---|---|---|
| 1.8 mm | 1.5 mm | 1.2 | +15.6 % | +0.5 % | +0.5 % |
| 1.8 mm | 1.2 mm | 1.5 | +7.1 % | -4.6 % | -4.6 % |
| 1.8 mm | 1.0 mm | 1.8 | +2.9 % | -3.2 % | -3.2 % |
| 3.6 mm | 2.0 mm | 1.8 | -3.1 % | -10.5 % | -10.5 % |
| 3.6 mm | 1.5 mm | 2.4 | -2.0 % | -9.5 % | -9.5 % |
| 3.6 mm | 1.2 mm | 3.0 | +5.2 % | +2.3 % | -7.0 % |
| 3.6 mm | 1.0 mm | 3.6 | +5.0 % | +3.2 % | -1.6 % |

Read plainly. Form B does nothing on coarse voxels (its best ball is still one centred inside the material) and keeps the 10 % miss: dropped. Form A is never more than 3.1 % low on the plate anywhere, and from 1.8 voxels across upward it sits between -3.1 and +5.2 % (a spread of 8.3, inside the 10 % bar). Under 1.8 voxels across it reads HIGH (the safe side), up to +15.6 %, because the stress the solve gives in a nearly empty cut voxel runs high and a small ball is mostly such voxels; where the ball does not reach past its own voxel at all (size under the voxel) it would read one such voxel alone, +44 %: that is the ruling's case 4 and must take the one-voxel form on PRINTED voxels, not this. The ring with form A: 3.6 mm reads +2.9 to +5.5 % at all four resolutions; its 1.8 mm rows by voxel count are owed (the test prints only the range, +1.5 to +42.7 %, the high end being the size-under-a-voxel row).

FIRST READING of the switch point (item 2): about 1.8 voxels across on the plate. Owed before it is stated: the same table for the ring, and sizes chosen to land between 1.5 and 2.5 voxels across at each resolution, printed by the tests themselves.

### Item 2, THE SWITCH POINT, measured on both shapes (2026-11-26 16:32, build of 5f2b2fae plus the tests' "[switch]" tables)

Real stiffness (E x fill), the edge-of-part reading (form A), the size chosen to span a stated number of voxels at each resolution; percent against the reading's own true value at radius 3 / 4 / 5 / 6 voxels.

| voxels across | plate with a hole | thick ring | inside the bar on both? |
|---|---|---|---|
| 1.00 | +46.5 / +18.3 / +18.6 / +33.4 | +44.3 / +20.0 / +17.1 / +9.7 | no (unsteady, 28 to 35 % spread) |
| 1.25 | +30.6 / +16.2 / +15.2 / +21.4 | +30.6 / +14.7 / +8.2 / +7.9 | no (15 to 23 % spread) |
| 1.50 | +7.3 / +7.1 / +7.1 / +7.5 | +11.3 / +5.9 / +4.1 / +4.2 | yes |
| 1.75 | -2.9 / -0.1 / +2.6 / +2.9 | +3.0 / +2.6 / +1.3 / +1.3 | yes |
| 2.00 | -4.9 / -2.1 / +1.7 / +2.0 | +1.5 / +3.0 / +1.5 / +1.7 | yes (the lowest figure anywhere: -4.9 %) |
| 2.50 | -4.0 / -1.7 / +2.7 / +2.8 | +2.5 / +5.2 / +3.1 / +3.4 | yes |
| 3.00 | -0.8 / +0.8 / +5.2 / +4.9 | +5.5 / +8.2 / +5.5 / +5.6 | yes |
| 4.00 | +0.8 / +1.8 / +4.4 / +4.3 | +4.9 / +6.9 / +5.3 / +4.6 | yes |

THE ANSWER: the form meets the bar on both shapes at all four resolutions from 1.5 voxels across. THE VALUE SET: 1.75 (`kStressSizeSwitchVoxels`), not 1.5, for one reason: at 1.5 the reading sits about 7 % high and at 2.0 up to 4.9 % low, so one physical size seen at 1.5 voxels on one grid and 2.0 on another would differ by 12 %, over the 10 % allowed across resolutions; from 1.75 up every figure on both shapes lies between -4.9 and +8.2 %. Margin to the 5 % bar is thin at 2.0 on the coarsest plate (-4.9 %): said, not hidden.

In the code (`analyze.cpp`, behind `TOPOPT_STRENGTH=size`): a job whose reading size is at least 1.75 check voxels is solved with real stiffness and read over the size with the ball free to sit on the part's edge; any other job (a smaller size, or a material with no published length) keeps TODAY'S solve and one-voxel reading whole. `FixedDesignAnalysis::stress_read_over_mm` says which (0 = one voxel). What his materials get under his half-length rule: PLA 1.2 mm reads over a size when the check voxel is 0.69 mm or finer; PETG 0.35 mm and ABS 0.23 mm essentially never (voxels of 0.2 and 0.13 mm): for them, and for PA6 and PA12, stage 2 changes nothing but the printed grams.

### Item 6 run in a job (2026-11-26 17:05, build of 0cd653d6 plus the readout): the job says which form it used

The made sample bracket, res 64 (check voxel 1.56 mm), drawn faces, the automatic pad, one thread, `TOPOPT_STRENGTH=size`, PLA (its size, half the published length, is 1.2 mm): the run prints "[strength] one-voxel reading, as today: reading over 1.20 mm needs a check voxel of 0.69 mm or finer, and this job's is 1.56 mm." and the report carries `"strength_reading": {"size_mm": 1.2, "voxel_mm": 1.5625, "needs_voxel_mm": 0.686, "over_size": false}`. Four versions, margins 5.29 / 5.29 / 4.85 / 3.66: the strength numbers of the same job without the switch (5.29 / 5.30 / 4.85 / 3.82), as they should be under today's form (the lightest differs by 4 %: to look at); the grams are now printed grams (101.1 / 84.8 / 69.5 / 53.1 g where the solid figures were 158.6 / 125.7 / 96.7 / 72.0 g). The second run (17:22; size forced to 3.6 mm, 2.3 voxels across): "[strength] the stress is read over 3.60 mm (the material's length), on real stiffness; the check voxel is 1.56 mm.", report `"over_size": true`. The same four designs to the gram (101.1 / 84.8 / 69.5 / 53.1 g: the reading does not steer the optimiser, it judges the result), margins 6.62 / 6.63 / 5.77 / 3.66 against 5.29 / 5.29 / 4.85 / 3.66 on the one-voxel form: the first three read about 25 % higher over the size, as an average must against a peak. The lightest version's 3.661 is the SAME in both forms to four figures, so something other than this reading decides it there (the across-layer check, which is not read over a size yet, is the likely one): to confirm before the stage report. The 4 % difference from the earlier run without the switch is not evidence: that run was on all threads and an older pad floor.

`b5_stage2.sh` (lock, behind the suite) is re-pointed: the sample bracket at res 96 and the stand at res 128, switch off / size (the material's own) / size forced to 3.6 mm, the automatic pad.

### What decides the number he is SHOWN: the file re-check, on all-or-nothing voxels (found 2026-11-26 17:35)

Following the bracket's lightest version (3.661 in both forms): its report says the across-layer check governs there (5.09 against 8.88 in-plane), and that check is not read over a size, so the two forms agree. That part is as expected.

Reading the code behind it found something that matters more. The margin printed after finishing ("margin a -> b"), which is the one the app shows, comes from `recheck_file` (`to_export.inc:320`): the finished FILE is voxelised again and analysed by the analyze path, and there every voxel the file touches is given density 1 (`to_analyze.inc:420`). It is an ALL-OR-NOTHING model: no partly filled voxels at all. Two consequences, both already measured by tests E's first column:

1. TODAY, with no switch: the shown number is the all-or-nothing one-voxel reading. On the plate with a hole that reads 2.20 / 2.50 / 2.65 / 2.73 against the textbook 3.03, that is 27.5 to 9.9 % LOW (the unsafe side) and 24 % apart across resolutions; on the ring 6.3 % low at worst. The loop's own certificate (E x fill^3 on the exact fills) reads 4 to 16 % HIGH. So the two judges of one version disagree by up to 40 %, and the one that has the last word is the optimistic one. This is ledger R-08 ("one judge") with numbers on it.
2. WITH stage 2's switch: on a file's all-or-nothing voxels there are no cut voxels for the ball to sit on, so the edge-of-part fix cannot act in the re-check, and "real stiffness" changes nothing there (every voxel is full). The form measured above therefore reaches the loop's certificate but NOT the number he is shown.

What it needs (NOT built; to put to the reviewer as stage 2's remaining piece): the re-check voxelises the file with each voxel's FILL (the share of the voxel inside the file's surface, by sub-sampling as the tests do), and is then judged by the same form as the loop. Until then the stage's bar is met by the certificate and not by the shown number.

### The two judges on real jobs (from today's runs; 2026-11-26 17:50)

Every "[finish] ... margin a -> b" line of today's runs: a is the loop's certificate (the exact fills, E x fill^3), b is the file re-check (all-or-nothing), which is the number shown. Res 64 unless said.

| job | 0.68 | 0.52 | 0.38 | 0.26 |
|---|---|---|---|---|
| Top Motor Mount, today, res 96 | 1.641 -> 1.641 | 1.650 -> 1.649 | 1.672 -> 1.672 | 1.690 -> 1.686 |
| Top Motor Mount, drawn faces | 2.333 -> 2.338 | 2.334 -> 2.339 | 2.349 -> 2.355 | 2.344 -> 2.346 |
| the stand, today, res 128 | 2.397 -> 2.410 | | | |
| the stand, drawn faces, res 128 | 2.587 -> 2.597 | | | |
| sample bracket, today | 4.711 -> 4.711 | 4.723 -> 4.723 | 4.008 -> 4.823 | 1.814 -> 3.793 |
| sample bracket, drawn faces | 5.283 -> 5.285 | 5.112 -> 5.296 | 4.154 -> 4.845 | 2.048 -> 3.815 |
| sample hook, today | 4.321 -> 4.765 | 3.576 -> 4.598 | 2.703 -> 4.317 | 1.608 -> 3.752 |
| sample hook, drawn faces | 4.343 -> 4.755 | 3.681 -> 4.566 | 2.564 -> 4.173 | (not made) |
| sample beam, drawn faces | 5.649 -> 6.316 | 4.563 -> 5.064 | 2.928 -> 3.678 | 1.962 -> 1.870 |

Read plainly. On his two parts, where little is carved, the two judges agree to 1 %. On the carved made parts they part company as the version gets lighter: the shown number is up to 2.3 times the certificate's (the hook at 0.26: 1.61 against 3.75; the bracket: 1.81 against 3.79). By the loop's own judge the lightest versions stand just over the 1.5 pass mark; the screen says 3.7. The textbook tests say the truth lies between (the certificate reads the stress 4 to 16 % high on the plate, far more on the ring; the all-or-nothing re-check 10 to 27 % low), so neither figure is right, and the gap is widest exactly where a wrong pass would matter. This is the case for one judge on exact fills.

### Written ahead for "one judge" (2026-11-26 18:55; NOT wired into any job, the reviewer's ruling comes first)

`file_fill.hpp`, `file_fill_fractions(file, grid, sub = 4)`: each voxel's share inside the file's surface, counted on a grid `sub` times finer over the same voxels by the voxeliser's own rule (`voxelize_onto_grid`), so with sub = 1 it is exactly today's all-or-nothing occupancy. Test `to_file_fill` (passes): a box on voxel faces reads 0 or 1 and its exact volume; a box cutting voxels in half reads 0.5 in the cut layers; a box off the sub-grid holds its volume to 1.4 % at 4 per voxel (2.8 % at 8 on this box by where its faces fall; all-or-nothing 1.0 % by the same luck: the point of the fill is the SHAPE of the edge, not the total). Cost: one voxelisation at `sub` times the resolution (sub 4 at 128 x 96 x 64 voxels: 50 MB of one-byte tags while it runs). What is left once ruled: the re-check analyses the file's fills by the loop's form, and the report says so.

### The across-layer check read over a size, against a textbook case (2026-11-26 19:11; behind `TOPOPT_STRENGTH=size`)

Until now only the in-plane check could be read over a size; the across-layer check read one voxel (the bracket's lightest version above was decided by it in both forms). Now, when a size is read, the tension across the layers is averaged the same way and over the same size (his word: "Let's do same size, then"), with the cut voxels' stress included as for the in-plane reading (`analyze.cpp`).

Test `to_strength_across_layers`: the plate with a round hole with the layers stacked ALONG the pull, so the across-layer check reads the tension along the pull (3.03 x the far stress at the hole's edge), against the reading's own true value (the same average of Kirsch's stress along the pull, `to_reference_reading.hpp`).

| | radius 3 voxels | 4 | 5 | 6 | |
|---|---|---|---|---|---|
| one voxel (today's form), against the peak | +14.2 % | +13.7 % | +4.7 % | +18.5 % | high (safe), 14 % apart |
| over 1.75 voxels | -3.2 % | -0.4 % | +2.9 % | +3.3 % | inside the bar |
| over 2.00 voxels | -5.4 % | -2.3 % | +2.0 % | +2.3 % | OUTSIDE by 0.4 (the coarsest grid) |
| over 2.50 voxels | -4.9 % | -2.1 % | +2.7 % | +2.8 % | inside |
| over 3.00 voxels | -2.0 % | +0.4 % | +4.9 % | +4.7 % | inside |
| over 4.00 voxels | -0.6 % | +1.5 % | +4.0 % | +3.9 % | inside |

Read plainly: the across-layer reading over a size behaves like the in-plane one (which read -4.9 % at the same point) and is inside the bar at 19 of 20 points; at 2.0 voxels across on the coarsest grid, where the hole is only 3 voxels in radius, it is 5.4 % low against a 5 % bar. Not hidden and not tuned away: for the reviewer to rule (accept at a hole of 3 voxels' radius, or ask for a margin on the across-layer reading). Committed as measured, measure-only in ctest.

### The across-layer reading in a job (2026-11-26 19:43, build f7287eca): the bracket again, size forced to 3.6 mm

Shown margin and printed grams per version, the same job three ways (res 64, drawn faces, automatic pad, one thread):

| version | one-voxel form | over 3.6 mm, in-plane only (17:22) | over 3.6 mm, across the layers too |
|---|---|---|---|
| 0.68 | 5.285, 101.1 g | 6.617, 101.1 g | 6.617, 101.1 g |
| 0.52 | 5.293, 84.8 g | 6.626, 84.8 g | 6.626, 84.8 g |
| 0.38 | 4.851, 69.5 g | 5.773, 69.5 g | 6.362, 69.4 g |
| 0.26 | 3.661, 53.1 g | 3.661, 53.1 g | 3.976, 53.1 g |

The two heavier versions are decided in-plane and do not move. The lightest, decided across the layers, moves from 3.661 to 3.976 (+8.6 %) now that its check is averaged too; the 0.38 version, where the two checks are close (16.4 against 16.3 in the report), moves with it. The designs differ by a few hundredths of a gram at 0.38 and 0.26: the loop's own margin probes read the new number, so its path shifts very slightly. Runs rc 0, 912 s.

### A small part, where PLA's own size switches the reading on by itself (2026-11-26 20:04, build f7287eca)

The sample bracket at 15 % size (15 mm long, loads scaled with the area), res 48 (check voxel 0.31 mm), drawn faces, automatic pad (0.45 / 1.48 / 1.22 mm), one thread. PLA's size is 1.2 mm = 3.8 voxels, so with `TOPOPT_STRENGTH=size` the job says "[strength] the stress is read over 1.20 mm (the material's length), on real stiffness; the check voxel is 0.31 mm." Certificate -> shown margin, grams:

| version | switch off | size |
|---|---|---|
| 0.68 | 6.35 -> 6.50, 0.583 g | 8.65 -> 8.65, 0.570 g |
| 0.52 | 6.35 -> 6.51, 0.485 g | 8.53 -> 8.65, 0.489 g |
| 0.38 | 4.85 -> 5.25, 0.402 g | 6.85 -> 7.87, 0.403 g |
| 0.26 | 2.09 -> 4.24, 0.333 g | 3.68 -> 5.97, 0.329 g |

Read plainly. (1) It switches on by itself and runs clean (rc 0, four versions both ways, 631 s and 495 s). (2) On a part this small the averaged reading lifts every margin by 33 to 41 % (the shown 4.24 becomes 5.97 on the lightest): a 1.2 mm region is large against features of 1 to 3 mm, which is what the critical-distance method says about small notched parts, but it is a big step and it rests on a published length halved by his rule, not on a print of his. To be said in the stage report as it is, and worth one printed check when the rig is ready. (3) The grams hardly move (a part this small is nearly all wall, so printed grams are close to solid grams). (4) The two judges still part on the lightest version in both columns (2.09 against 4.24; 3.68 against 5.97): that is "one judge", next.

### ONE JUDGE in a job, first numbers (2026-11-26 20:05 to 21:05, build of 5392695a plus the switch; k = 8 still running)

The made sample bracket, res 64, drawn faces, automatic pad, one thread. The loop's certificate, then the number SHOWN (the file re-check) with `TOPOPT_RECHECK` unset and at k sub-samples along each voxel edge:

| version | certificate | shown today | k = 2 | k = 4 | k = 8 |
|---|---|---|---|---|---|
| 0.68 | 5.283 | 5.285 | 5.346 | 5.289 | (running) |
| 0.52 | 5.105 | 5.293 | 5.317 | 5.191 | |
| 0.38 | 4.152 | 4.851 | 4.474 | 4.265 | |
| 0.26 | 1.799 | 3.661 | 2.511 | 2.162 | |

Same designs and grams in every column (the switch only changes how the finished file is judged). The lightest version's shown margin comes down from 3.66 to 2.16 at k = 4, against the certificate's 1.80; it is still moving with k (2.51 to 2.16 is 14 %), so k is not chosen yet. The file is the FINISHED surface (stair-steps smoothed, thin spots fixed), not the loop's design, so the two need not meet exactly: the textbook test (a) is where "within 1 %" is judged. Cost on this job: the whole run 1072 s unset, 1015 s at k = 2, 991 s at k = 4 (no slower); peak memory 375 MB unset, 369 MB, 397 MB (+6 % at k = 4). About 8,000 to 10,000 cut voxels per version, 750 to 1,300 of them with their centre outside the file (the ones all-or-nothing drops altogether).
