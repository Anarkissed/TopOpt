# Stage 2: a strength number that holds (TOReview)

Status 2026-11-26 19:30: IN PROGRESS. Everything is behind ONE switch, `TOPOPT_STRENGTH` (unset = today, unchanged; `size` = the form below; `stiff` = a measuring arm). The certificate is shared with the lattice strength check: every change here is told to the reviewer and LatticeReview. The history below is in the order it happened; this block is where it stands.

## WHERE IT STANDS (read this first; rewritten 2026-11-27 04:10)

**ADDED 2026-11-27 09:10: ONE JUDGE CANNOT FLIP AS BUILT (the detail is in the last sections of this file; nothing above is withdrawn).**
In plain words: "one judge" makes the number the optimiser certifies and the number shown on the finished file ONE number. It does that: on the made hook the two agree to about 1 % with it on, where today the shown number is 10 to 46 % higher than the certified one. But on his Top Motor Mount it refused all four versions (margin 1.65 with it off, 1.07 to 1.00 with it on; the pass mark is 1.5), and on the stand the margin fell 6 %. The reason is how each check treats the small cubes that the part's surface cuts through, and BOTH are wrong, in opposite directions on different shapes:
- today's all-or-nothing check reads a thin member in bending 1 to 43 % too LOW (unsafe: the part looks stronger than it is), and is right to 6 % on a thick ring pushed on its curved face;
- one judge as built (cut cubes at stiffness E x fill^3) reads the bending member within -12 to +16 %, and the ring 52 to 76 % too HIGH.
So which margin is right for Top Motor Mount is NOT known. Measured candidate, in tests only: cut cubes at their REAL stiffness (E x fill) and the stress of the full cubes carried in a straight line to the true surface: -13 to -1 % on the beam (within 4 % from 8 cubes through), -8.6 to -0.3 % on the ring, closing as the grid refines; always slightly low; not measured at a sharp inside corner (where Top Motor Mount's peak sits), on a general surface, or across layers.
PARKED FOR THE REVIEWER (six reports, 05:08 to 07:27 EST): (1) the drawn part's faces get their fills in the LOOP too, so no part is certified and then refused late; (2) the law and the true-surface reading move both judges together, in stage 4. Evidence (b) is in for three parts; (c) time and memory in for two; beam64 and (d), (e) with the switch on are owed and not re-queued until the ruling. Ledger A-06 is measured (2 voxels through: 67 % low; 4: 32 %; 6: 20 %; 12: 9 %).

Everything is behind switches, unset = today: `TOPOPT_STRENGTH=size` (the strength reading and printed grams), `TOPOPT_RECHECK=fill` (one judge). Nothing here is released.

**In plain words, for the maintainer.** The app decides pass or fail from the stress in the single hottest little cube of the part. Stage 2 does three things about that number. (1) The weight it shows becomes the weight as printed, walls and infill, not a solid block. (2) Where the detail is fine enough for the plastic and the part is thick enough there, the stress is read as an average over a small region whose size belongs to the plastic, which is what the research says a printed part fails by; everywhere else today's reading is kept, and the job says which was used. (3) The number shown after finishing is made to come from the same kind of check as the optimiser's own ("one judge"); today a cruder second check has the last word and can be far too generous on the lightest versions.

**Measured and in the code:**
- PRINTED GRAMS: within 3 % of Bambu Studio; "saved" is against the part as drawn at the same walls and infill (the stand: 15 % really saved where the solid figures say 23.5 %; the bracket 20 / 33 / 44 %).
- THE SIZE FORM (real stiffness, its own solve; the stress averaged over the material's size with the ball free to sit on the part's edge and, where the surface lies on voxel boundaries, on its surface nodes). Against the textbook on a plate with a hole, a thick ring, the across-layer case and a beam in bending, at four detail levels: never more than 4.9 % low from 1.75 voxels across (the switch point) and from a member twice the size thick (the thin-member rule). Under either, the job keeps TODAY'S solve and reading whole and says so (`[strength]` line; report key `strength_reading`).
- ONE JUDGE (`TOPOPT_RECHECK=fill`, 8 sub-samples per voxel edge, by measurement): the re-check of the finished file analyses each voxel's fill. On textbook shapes today's re-check reads the peak 14 to 47 % under the optimiser's check; with one judge the size form agrees within 0.5 % (16 rows) and the one-voxel form within 2.5 % (12 rows). On the sample bracket the lightest version's shown margin comes down from 3.66 to about 2.2 (the optimiser's own: 1.80). No cost in time; memory flat.

**KNOWN LIMITS, stated (ruled):**
- A-06: TODAY'S one-voxel reading on a member only 2 to 4 voxels thick in bending reads 0.33 to 0.68 of the true surface stress. Not fixed here; carried to stage 4 (the smallest member in voxels through as well as mm).
- A notch with a tip radius under 2 check voxels is outside the bar (the ellipse: today's reading 13.9 % low at one detail level).
- The one-voxel form is jumpy in the fill (up to 11 % on an unlucky sliver); a fill-weighted reading is to be measured AFTER one judge flips and would go into both judges together.
- On his materials at his usual detail the size form rarely switches on (PLA needs a voxel of 0.69 mm or finer; PETG, ABS essentially never; PA6, PA12 no published length): for most of his jobs stage 2 changes the grams and the shown number's honesty (one judge), not the reading itself.
- Small parts: the size form raises margins by a quarter to two fifths on a 15 mm PLA part, on the published length halved by his rule; shipped on that by ruling, his print replaces it when the rig exists.

**Owed before the stage report goes:**
- One judge, evidence (b) to (e): running under the lock (`b7_onejudge.sh`): his parts and the made parts before and after, time and memory, test K, lattice jobs A to D.
- The size form's conditions (b) to (e) on his full-resolution parts on the CURRENT build (B5 ran before the thin-member rule).
- The app's side (#362): show the form, the printed grams; the job carries his top and bottom layers (`loads.top_solid_mm`, `loads.bottom_solid_mm`: #362's keys, to be read by printed grams once its branch is merged).
- After one judge flips: the fill-weighted one-voxel reading. For stage 4: the member rule in voxels (A-06). With TOSurface: the step-back before refusing a rung.

(The dated rulings and every table follow below in the order they happened.)

## The rulings and the maintainer's words, dated (kept whole)

**THE REVIEWER'S RULING of 2026-11-27 00:22Z (maintainer-approved):**
1. "One judge" APPROVED and FIRST in stage 2, because it is the number he is shown. Behind its own switch (`TOPOPT_RECHECK=fill`) so it can flip ahead of the rest. The sub-sampling k is chosen by measurement: the k at which the shown margin moves under 0.5 % when k doubles. Evidence for its flip: (a) plate, ring and ellipse through the re-check path give the certificate's numbers within 1 %; (b) his parts' shown margins before and after (expect within 1 %), and the bracket, hook and beam: shown against certificate, before and after; (c) time and peak memory of the re-check on his largest job, one thread; (d) test K; (e) lattice jobs A to D, LatticeReview told what moves first.
2. Switch point 1.75 voxels: accepted.
3. KNOWN LIMIT, stated: the across-layer reading is 5.4 % low at 2.0 voxels across where the hole is 3 voxels in radius (the in-plane reading is 4.9 % low at the same point). Accepted as a limit; no margin added ("a margin set to pass one point is tuning").
4. KNOWN LIMIT, stated: a notch whose tip radius is under 2 check voxels is OUTSIDE the bar. On the ellipse (tip radius 0.75 to 1.5 voxels) today's one-voxel reading is 13.9 % under the textbook at one resolution and 22 % apart across resolutions; E x fill^2 is 19.3 % under. No pop-up. If the check can tell cheaply that its peak sits on a feature sharper than 2 voxels, the engineer's readout may say the corner is finer than the grid and a finer resolution reads it better: measured on the ellipse first, or not built.
5. Today's E x fill^3 stays for the under-a-voxel case. Stage 1's flip items 2(b), 2(c), 2(d) received; the flip waits on 2(a) and the list.
Also ruled the same hour (stage 5): the connection-rule test on the hook PASSES; before a rung is refused for an unheld load, TRY A STEP-BACK (restore the last design whose load reached a support, halve the move limit, retry, at most 3 times), measured on the hook at pad 1.0 and on demo solve 10 with and without it, kept only if it makes more versions in no more than 10 % more time. The smoother's default is cheb:2.

**ONE JUDGE, where it is (2026-11-26 21:45):** the switch `TOPOPT_RECHECK=fill[:k]` is in, builds and runs in a job; the fills are counted one layer at a time. On the bracket the lightest version's shown margin comes down from 3.66 to between 2.2 and 2.5 (certificate 1.80), at no cost in time. NOT settled: the number still moves with k (the textbook test: up to 18 % between k = 4 and 8), because the one-voxel form is jumpy in the fill by its nature, in both judges ("WHY the one-voxel form is jumpy", below). Runs at k = 16 against a finer reference are in progress; the reviewer gets the table and the question it raises.

**THE MAINTAINER, 2026-11-27, on the printed check for small PLA parts:** "I will absolutely add the small PLA parts when the rig is ready. But it won't be for a while." So the averaged reading's 33 to 41 % higher margins on a 15 mm part rest on the published length alone for now. FOR THE REVIEWER to rule when stage 2's size form comes up for its flip: ship it for small parts on the published value, or hold the size form to parts above a stated size until his print exists. Not decided by me.

**THE REVIEWER'S RULING of 2026-11-27 06:34Z (maintainer-approved):**
1. One judge: k = 8 APPROVED (now the default of `TOPOPT_RECHECK=fill`). Evidence (a): the size form at 1 % (met); the one-voxel form stated as its own scatter (within 2.5 % on all 12 rows at k = 8; up to 11 % on an unlucky sliver at other k). The rows at k = 8 are PINNED as a test (`to_recheck_fill`, ctest -C Long, gated at 2.5 % and 1 %). AFTER one judge flips, not before: measure a fill-weighted one-voxel reading on all three shapes; if steadier it goes into BOTH judges together, never one alone.
2. Small PLA parts: SHIP on the published length with his half rule (his choice of safety; his prints replace it when the rig exists). ONE CONDITION FIRST: no reading over a size where the ball reaches across the member (a ball wider than a thin member in bending averages across its neutral line and reads low; Taylor 2007, The Theory of Critical Distances). Where the member under the reading is thinner than TWICE the size, read one voxel (today's form). Test: a beam in bending at thicknesses of 0.5, 1, 2 and 4 times the size: at 0.5 and 1 the reading falls back; at 2 and 4 it is judged against its own true value. Then restate the 15 mm part's 33 to 41 %. OWED, next.
3. scenario_weights: no flip on a base with an unexplained change of results. SETTLED since (TOSolver's fix on my tip, checked).
4. The memory guard amended for everyone (the swapouts clause only when free is also under 30 %).

**KNOWN LIMIT, STATED (the reviewer's ruling 2026-11-27 07:38Z: "the most important line in your report"):** TODAY'S SHIPPED one-voxel reading, on a member only 2 to 4 voxels thick in BENDING, reads 0.33 to 0.68 of the true surface stress (measured on a beam in pure bending: 0.33 with 2 voxels through the member, 0.68 with 4, 0.85 with 8, 0.93 with 16). It is the grid: a few linear elements cannot carry a bending gradient. It is in the shipped check with or without this stage, so a thin bending member can pass today with a margin up to three times too good. Stage 2 does not fix it (its size form falls back to that same reading on thin members, as ruled). It is carried to STAGE 4: the smallest member is stated in voxels THROUGH as well as in mm, the number set by measurement on the beam at 2, 3, 4, 6 and 8 voxels through, and the automatic resolution must honour it; a candidate to measure there is stress recovered at the surface from its neighbours (superconvergent patch recovery, Zienkiewicz and Zhu 1992, DOI 10.1002/nme.1620330702). Ledger: A-06.

**THE REVIEWER'S RULING of 2026-11-27 07:38Z:** (a) YES to the surface-node ball and the corner-aware width, on the beam and the three shapes, then the switch point again, then the 15 mm part restated. (b) the limit above, in the stage file and the ledger now, and in stage 4. (c) scenario_weights check (c): give it a margin the physics supports or state what it guards; low priority.

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

### ONE JUDGE in a job, first numbers (2026-11-26 20:05 to 21:13, build of 5392695a plus the switch)

The made sample bracket, res 64, drawn faces, automatic pad, one thread. The loop's certificate, then the number SHOWN (the file re-check) with `TOPOPT_RECHECK` unset and at k sub-samples along each voxel edge:

| version | certificate | shown today | k = 2 | k = 4 | k = 8 |
|---|---|---|---|---|---|
| 0.68 | 5.283 | 5.285 | 5.346 | 5.289 | 5.268 |
| 0.52 | 5.105 | 5.293 | 5.317 | 5.191 | 5.155 |
| 0.38 | 4.152 | 4.851 | 4.474 | 4.265 | 4.205 |
| 0.26 | 1.799 | 3.661 | 2.511 | 2.162 | 2.293 |

Same designs and grams in every column (the switch only changes how the finished file is judged). The lightest version's shown margin comes down from 3.66 to 2.16 at k = 4, against the certificate's 1.80; it is still moving with k (2.51 to 2.16 is 14 %), so k is not chosen yet. The file is the FINISHED surface (stair-steps smoothed, thin spots fixed), not the loop's design, so the two need not meet exactly: the textbook test (a) is where "within 1 %" is judged. Cost on this job: the whole run 1072 s unset, 1015 s at k = 2, 991 s at k = 4 (no slower); peak memory 375 MB unset, 369 MB, 397 MB (+6 % at k = 4). About 8,000 to 10,000 cut voxels per version, 750 to 1,300 of them with their centre outside the file (the ones all-or-nothing drops altogether).

k = 8 (21:13): from k = 4 to 8 the three heavier versions move 0.4 / 0.7 / 1.4 %; the lightest moves the OTHER way, 2.162 to 2.293 (+6 %), so it is not settling smoothly: its deciding stress sits in a few nearly empty cut voxels, and E x fill^3 makes their stiffness swing with small changes of fill. Not within the ruled 0.5 % at any pair yet. Peak memory at k = 8: 450 MB (+20 % on this job), which is the whole fine grid held at once: `file_fill.hpp` is being rewritten to work one layer of voxels at a time (memory nx * ny * k^3 bytes whatever the height); its check and a run at k = 16 are queued (`slab_check.sh`). If the lightest version still wanders at 16, that goes to the reviewer as it is: the rule "k where the shown margin moves under 0.5 %" may not have an answer for a version decided by a few sliver voxels, and the honest options are a floor on the fill a voxel must have to be judged, or the reading over a size where one applies.

### ONE JUDGE, evidence (a), first run (2026-11-26 21:22, build 872863aa): what it shows, and why it is not yet evidence

Test `to_recheck_fill`: a closed mesh of each textbook shape taken through the file's fills, peak stress against the certificate's (exact fills, E x fill^3, one voxel), percent, at b (or inner radius) = 3 / 4 / 5 / 6 voxels.

| shape | all-or-nothing (today's re-check) | k = 2 | k = 4 | k = 8 |
|---|---|---|---|---|
| round hole | -35.8 / -27.2 / -16.1 / -22.4 | -13.8 / -9.6 / -4.2 / -10.3 | -9.2 / -8.7 / -1.0 / -11.7 | 0.0 / 0.0 / 0.0 / 0.0 |
| ellipse a / b = 2 | -43.7 / -20.4 / -23.2 / -27.2 | -18.7 / +13.7 / -13.8 / -11.2 | -5.2 / -1.3 / +8.3 / +6.1 | 0.0 / 0.0 / -2.8 / 0.0 |
| thick ring | -46.7 / -42.1 / -33.9 / -38.5 | -26.6 / -13.8 / -18.7 / -12.8 | -13.6 / -17.7 / -2.5 / -4.3 | 0.0 / 0.0 / 0.0 / 0.0 |

1. TODAY'S RE-CHECK against the certificate, on textbook shapes: its peak stress is 16 to 47 % lower, so the margin it shows is 19 to 88 % higher than the loop's for the same shape. The two judges, on shapes with known answers.
2. k = 1 reproduces all-or-nothing exactly, as built.
3. k = 8 matching to 0.0 % PROVES NOTHING: the test's "exact" fills were themselves sampled 8 x 8 per voxel, the same points. My slip in the test, corrected: the reference is now sampled 32 x 32 and k = 16 is added (re-run queued).
4. What is real in it: from k = 4 to k = 8 the peak still moves by up to 18 %. The one-voxel peak under E x fill^3 is very sensitive to the exact fill of a few sliver voxels, which is also why the bracket's lightest version wanders (2.51 / 2.16 / 2.29). That sensitivity is in the CERTIFICATE too (its fills come from the optimiser's own sampling), not only in the re-check. If k = 16 against the finer reference does not settle, the finding for the reviewer is that "one judge" needs the judges to share not just a form but the same treatment of sliver voxels.

WHY the one-voxel form is jumpy in the fill (read from `analyze.cpp`, 21:30; the k = 16 run will say how much). Two things multiply. (1) A cut voxel is solved at E x fill^3: at half full it has an eighth of the stiffness, so a 2 % error in its fill is a 6 % error in its stiffness, and its strain moves with it. (2) Only voxels MORE than half full are read (`density > 0.5`), with the full modulus on that strain. So the hottest reading is usually a voxel just over half full, the softest one that still counts, and a voxel at 0.49 or 0.51 is out or in entirely. Finer sampling of the file does not remove either: it only decides more exactly which side of a half each sliver falls. The reading over a size has neither problem (real stiffness, and an average weighted by fill), which is why it held its bar; the one-voxel form is today's, kept as ruled, and this is its nature in BOTH judges.

### ONE JUDGE in a job at k = 16, on the layer-by-layer fill (2026-11-26 21:46)

| version | certificate | k = 4 | k = 8 | k = 16 | k = 8 to 16 |
|---|---|---|---|---|---|
| 0.68 | 5.283 | 5.289 | 5.268 | 5.259 | -0.17 % |
| 0.52 | 5.105 | 5.191 | 5.155 | 5.143 | -0.23 % |
| 0.38 | 4.152 | 4.265 | 4.205 | 4.190 | -0.36 % |
| 0.26 | 1.799 | 2.162 | 2.293 | 2.220 | -3.2 % |

By the ruled test (the shown margin moves under 0.5 % when k doubles) the three heavier versions settle at k = 8. The lightest does not: 2.51 / 2.16 / 2.29 / 2.22 at k = 2 / 4 / 8 / 16, wandering inside about 6 %. Cost at k = 16 with the fills counted a layer at a time: peak memory 383 MB against 375 MB with the switch off (the whole-grid form took 450 MB at k = 8), the finish step 5 to 11 s a version against 2 to 5 s, the whole run 1065 s against 1072 s. So k = 8 costs nothing that matters and is where three of four versions settle; the fourth is the one-voxel form's own jumpiness.

### ONE JUDGE, evidence (a) against a finer reference (2026-11-26 21:56; the certificate's fills sampled 32 x 32 per voxel; 7 of 12 rows before my memory guard stopped the run, swapouts rising under another agent's lock job)

Peak through the file's fills against the certificate's, percent:

| shape, b in voxels | all-or-nothing (today) | k = 2 | k = 4 | k = 8 | k = 16 |
|---|---|---|---|---|---|
| round hole, 3 | -34.3 | -11.7 | -7.0 | +2.4 | -0.1 |
| round hole, 4 | -26.9 | -9.3 | -8.4 | +0.4 | +1.0 |
| round hole, 5 | -14.0 | -1.8 | +1.5 | +2.5 | -0.3 |
| round hole, 6 | -22.2 | -10.0 | -11.4 | +0.3 | +0.2 |
| ellipse, 3 | -43.6 | -18.5 | -5.0 | +0.2 | +1.4 |
| ellipse, 4 | -20.2 | +14.0 | -1.1 | +0.3 | -0.1 |
| ellipse, 5 | -22.6 | -13.1 | +9.2 | -2.1 | -2.2 |

Read plainly. From k = 8 the file's fills give the certificate's peak within about 2.5 % (worst +2.5 and -2.2), where today's all-or-nothing re-check is 14 to 44 % under it. Within 1 % in 4 of 7 rows at k = 8 and at k = 16; going from 8 to 16 does not tighten it (the scatter is the one-voxel form's own, see "WHY the one-voxel form is jumpy"; the ellipse at 5 voxels also carries the 360-sided polygon against the true ellipse). So the ruled "within 1 %" is not met by the one-voxel form at any k tried, and will not be by a finer k. The remaining rows (the ellipse at 6, the ring) re-run when the gate is green.

### ONE JUDGE, evidence (a), the full table (2026-11-26 22:14; reference fills 32 x 32; the test now runs one shape at a time, `--only`)

Peak through the file's fills against the certificate's, percent:

| shape, b or inner radius in voxels | all-or-nothing (today) | k = 2 | k = 4 | k = 8 | k = 16 |
|---|---|---|---|---|---|
| round hole, 3 / 4 / 5 / 6 | -34.3 / -26.9 / -14.0 / -22.2 | -11.7 / -9.3 / -1.8 / -10.0 | -7.0 / -8.4 / +1.5 / -11.4 | +2.4 / +0.4 / +2.5 / +0.3 | -0.1 / +1.0 / -0.3 / +0.2 |
| ellipse, 3 / 4 / 5 / 6 | -43.6 / -20.2 / -22.6 / -26.8 | -18.5 / +14.0 / -13.1 / -10.6 | -5.0 / -1.1 / +9.2 / +6.8 | +0.2 / +0.3 / -2.1 / +0.6 | +1.4 / -0.1 / -2.2 / +0.7 |
| thick ring, 3 / 4 / 5 / 6 | -46.5 / -43.3 / -34.2 / -37.8 | -26.4 / -15.6 / -19.0 / -11.7 | -13.4 / -19.4 / -2.9 / -3.1 | +0.3 / -2.0 / -0.4 / +1.2 | -0.1 / -11.3 / -1.7 / -0.9 |

CORRECTION to what I told the reviewer an hour earlier ("within about 2.5 % from k = 8, k = 16 no tighter") on 7 rows: over all 12 rows, k = 8 is within 2.5 % everywhere (worst +2.5, -2.1), but k = 16 has ONE row at -11.3 % (the ring at 4 voxels, where k = 8 reads -2.0 %). A finer k is not safer: one sliver voxel falling the other side of a half moves the peak by ten percent. That is the one-voxel form's jump, seen at its plainest, and it settles the question of k for that form by showing there is no settling: k = 8 is the best measured, not a converged value.

### ONE JUDGE, evidence (a) for the SIZE form (2026-11-26 22:25; the round hole so far, the ellipse running)

The same path (a closed mesh -> the file's fills -> the analysis), but judged by the stage's size form: real stiffness, the stress read over 2 and over 3 voxels with the ball free to sit on the edge. Against the same reading on the certificate's fills (32 x 32), percent:

| round hole, radius in voxels | over | k = 2 | k = 4 | k = 8 | k = 16 |
|---|---|---|---|---|---|
| 3 | 2 voxels / 3 voxels | -5.8 / -5.3 | -2.1 / -1.0 | -0.3 / -0.1 | +0.1 / +0.1 |
| 4 | 2 / 3 | -2.3 / -1.3 | +0.4 / 0.0 | -0.3 / -0.4 | -0.1 / -0.1 |
| 5 | 2 / 3 | -2.1 / -3.0 | -1.1 / -0.6 | -0.1 / 0.0 | -0.1 / 0.0 |
| 6 | 2 / 3 | -6.7 / -5.8 | -0.4 / -0.1 | -0.5 / -0.4 | +0.1 / +0.1 |

What I claimed to the reviewer and had not measured now is: through the file's fills the size form gives the certificate's number within 0.5 % at k = 8 on every row so far, and moves by 0.5 % or less from k = 8 to 16. So for the size form the ruled tests are both met at k = 8 (within 1 %; under 0.5 % when k doubles). The contrast with the one-voxel form (2.5 % at best, 11 % on an unlucky sliver) is the two jumps that form has and this one does not.

The ellipse (22:35), the same way:

| ellipse a / b = 2, b in voxels | over | k = 2 | k = 4 | k = 8 | k = 16 |
|---|---|---|---|---|---|
| 3 | 2 voxels / 3 voxels | -11.9 / -8.7 | -1.5 / -0.4 | -0.2 / -0.2 | 0.0 / 0.0 |
| 4 | 2 / 3 | -5.8 / -3.6 | +0.2 / +0.3 | -0.2 / +0.1 | +0.1 / -0.1 |
| 5 | 2 / 3 | -7.1 / -4.4 | -0.8 / -0.3 | -0.2 / -0.1 | +0.1 / +0.1 |
| 6 | 2 / 3 | -2.3 / -7.8 | -6.6 / -9.6 | -0.4 / -0.3 | 0.0 / 0.0 |

SIZE FORM, all 16 rows on two shapes: at k = 8 within 0.5 % of the certificate's number everywhere (worst -0.5), and 0.5 % or less from k = 8 to 16. k = 4 is NOT enough (one row at -9.6 %). So for the size form k = 8 meets both ruled tests; for the one-voxel form k = 8 is the best measured (within 2.5 %) and nothing finer is better.

### B5, the bracket at FULL resolution with the switch on (2026-11-27 01:18 to 01:47, under the lock; res 96, check voxel 1.04 mm, drawn faces, automatic pad)

`TOPOPT_STRENGTH=size`, PLA: "[strength] one-voxel reading, as today: reading over 1.20 mm needs a check voxel of 0.69 mm or finer, and this job's is 1.04 mm." So the strength number is today's, as ruled, and what the switch changes on this job is the grams:

| version | shown margin | printed grams (solid grams) | saved against the part as drawn, printed (144.4 g) |
|---|---|---|---|
| 0.68 | 4.33 | 115.6 (161.3) | 20 % |
| 0.52 | 4.30 | 97.0 (127.7) | 33 % |
| 0.38 | 3.90 | 80.4 (98.3) | 44 % |

The part as drawn prints at 144.4 g of 227.5 g solid (this bracket is thick, so a large share is infill). The same three designs by solid volume would read 29 / 44 / 57 % saved: the printed figures are the ones he would weigh. 1724 s. The switch-off run of this job was stopped by my guard under the old swapouts clause and is owed again; the forced 3.6 mm run and the stand at res 128 are still running.

### THE THIN-MEMBER RULE on a beam in bending (2026-11-27 02:18, test `to_strength_thin_member`; behind `TOPOPT_STRENGTH=size`)

A straight beam in pure bending (exact stress: zero at the middle, 1 at the surface), the reading size 2.0 mm = 4 voxels, thickness 0.5 / 1 / 2 / 4 times the size.

| thickness | voxels through | what the job reads | reading (surface stress = 1) | the size reading alone | its own true value |
|---|---|---|---|---|---|
| 0.5 x the size | 2 | ONE VOXEL (fell back) | 0.33 | 0.33 | 0.97 (-66 %) |
| 1 x | 4 | ONE VOXEL (fell back) | 0.68 | 0.47 | 0.64 (-26 %) |
| 2 x | 8 | over the size, 360 edge voxels at one voxel | 0.85 | 0.73 | 0.82 (-11 %) |
| 4 x | 16 | over the size, 392 edge voxels at one voxel | 0.93 | 0.87 | 0.91 (-5 %) |

What works: the rule falls back at 0.5 and 1 times the size and reads over the size at 2 and 4, as ruled. (First run: it never fell back, MY fault: the thickness was measured with the outside of the part's box as solid, the same slip as in the too-small check; fixed.)

FOUR THINGS IT SHOWS THAT ARE NOT COMFORTABLE, for the reviewer:
1. The size reading on a FLAT, GRID-ALIGNED face in bending is low even where the rule allows it: 11 % under its own true value at 2 times the size, 5 % at 4 times. Cause (reasoned, not yet tested): the true value has the ball centred ON the surface; on a face that lies on voxel boundaries there are no cut voxels for the ball to sit on, so it sits half a voxel inside (an eighth of the size here), where the bending stress is already lower. The curved textbook shapes hid this. Proposed fix to measure: let the ball also be centred on the part's surface NODES, not only on voxel centres.
2. The job's number at 2 and 4 times is HIGHER than the size reading (0.85 against 0.73) because the beam's EDGE voxels count as thin (the "largest ball that holds the voxel" does not reach into a corner) and so are read at one voxel, where the surface voxel reads 0.85. So on any part with edges the job's reading is partly today's form. The corner-aware width measure that already exists for the lattice's cells-per-member rule is the candidate; not changed yet.
3. TODAY'S one-voxel reading on a thin bending member is itself badly low: 0.33 of the surface stress with 2 voxels through the member, 0.68 with 4. That is the grid (a few linear elements cannot carry a bending gradient), in today's shipped check, with or without this stage. It is the strongest argument yet for the wall rule of stage 4 being stated in voxels THROUGH a member, not only in mm.
4. So "fall back to today's form" on thin members is the ruled choice and is in, but on a member 2 to 4 voxels thick neither form is within 30 % in bending.

FINDING 1 TESTED (02:30, a measuring arm inside the test, not in the engine): the same ball average with the ball centred ON the top face's nodes, not on voxel centres, against the reading's own true value: 2 x the size -4.9 % (voxel-centred: -11.2 %); 4 x -1.7 % (was -4.7 %); 1 x -15.3 % (was -25.8 %; it falls back anyway). So the cause is the one reasoned: on a flat, grid-aligned face the ball could not sit on the surface. With surface-centred balls the size reading is inside the 5 % bar on this beam from 2 times the size, which is exactly where the ruled thin-member threshold hands over to it. To put into the engine (awaiting the reviewer's word): `stress_over_size` also evaluates balls centred on the nodes of the part's surface.

### B5 complete (2026-11-27 02:37): the stand at FULL resolution (res 128, check voxel 0.99 mm, PA12, drawn faces, automatic pad)

| run | what the job says | shown margin | printed grams |
|---|---|---|---|
| switch off | (today) | 2.587 -> 2.597 | 87.99 g (solid) |
| `size` | "no published stress-reading length for PA12: this material keeps today's strength reading (one voxel)" | 2.587 -> 2.597 | 84.88 g of 87.99 solid |
| `size`, forced to 3.6 mm | "the stress is read over 3.60 mm ... on real stiffness" | 4.101 -> 4.093 | 84.88 g |

The part as drawn prints at 100.13 g of 114.98 g solid, so the version really saves 15.2 % of printed weight (the solid figures say 23.5 %). With the switch on and his material the STRENGTH NUMBER DOES NOT MOVE (2.597 both ways): PA12 has no published length, as ruled. Forced to 3.6 mm the margin would read 58 % higher (4.09): shown only to say what an averaged reading would do on this part; it is not what ships for PA12, and that run was made on a build from BEFORE the thin-member rule. Runs 526 / 458 / 516 s: the switch costs no time on this job. The bracket's forced run: see the folder `opt11/sample_a/size36`.

### The two fixes IN THE ENGINE, on the beam (2026-11-27 02:48; behind `TOPOPT_STRENGTH=size`)

`stress_over_size_on_surface` (the ball also centred on the nodes where material meets air; `stress_measure.cpp`) and the corner-aware member width (`lattice_member_width_mm` with the floor at twice the size) are in `analyze.cpp`. The beam again:

| thickness | what the job reads | job's reading | own true value | off |
|---|---|---|---|---|
| 0.5 x the size | one voxel (fell back) | 0.33 | (0.97) | the grid's limit, A-06 |
| 1 x | one voxel (fell back) | 0.68 | (0.64) | the grid's limit, A-06 |
| 2 x | over the size, every voxel thick, none thin | 0.778 | 0.818 | -4.9 % |
| 4 x | over the size, every voxel thick, none thin | 0.893 | 0.909 | -1.7 % |

So the engine now gives what the measuring arm gave: inside the 5 % bar from twice the size, and the edge voxels no longer fall back (0 thin where there were 360 and 392). The margin at twice the size is thin (-4.9 %). OWED NEXT: the plate, ring, ellipse and across-layer tests still read with voxel-centred balls only; they are switched to the engine's combined reading and the switch point (1.75 voxels) and the bar are measured again on all of them; then the 15 mm part.

### The surface-node ball NARROWED, and everything measured again together (2026-11-27 03:39; behind `TOPOPT_STRENGTH=size`)

First form (every node where material meets air), on the curved shapes: WRONG the other way. The plate and the ring read 14 to 68 % HIGH at 1.75 to 2 voxels across and 10 to 23 % high at 3 to 4 (a node on a cut surface averages mostly sliver voxels, whose stress the solve reads high). Corrected the same hour: a surface node counts only where EVERY voxel at it is full, that is, where the surface lies on voxel boundaries and a voxel-centred ball cannot reach it; where the surface cuts voxels the voxel-centred ball already sits on the edge.

With that, all four tests on one build:

| test | result |
|---|---|
| the beam in bending | falls back at 0.5 and 1 x the size; -4.9 % at 2 x, -1.7 % at 4 x; no edge voxel falls back |
| plate with a hole, by voxels across | 1.50: +7.1 to +7.5; 1.75: -2.9 to +2.9; 2.00: -4.9 to +2.0; 2.50: -4.0 to +2.8; 3.00: -0.8 to +5.2; 4.00: +0.8 to +4.4 (the figures of 11-26, to the digit) |
| thick ring | 1.50: +4.1 to +11.3; 1.75: +1.3 to +3.0; 2.00: +1.5 to +3.0; 2.50: +2.5 to +5.2; 3.00: +5.5 to +8.2; 4.00: +4.6 to +6.9 (the same) |
| across the layers (plate 8 voxels thick, through analyze) | 1.75: +2.4 to +8.0; 2.00: -0.2 to +7.0; 2.50: -1.0 to +6.8; 3.00: +0.7 to +8.2; 4.00: +1.3 to +6.9 |

So: the switch point of 1.75 voxels stands (every figure on the curved shapes between -4.9 and +8.2 % from there up, none more than 5 % low), the flat-face miss is cured (-11.2 % became -4.9 %), and the thin-member rule falls back where ruled. The two thin margins, said again: -4.9 % at 2.0 voxels across on the coarsest plate, and -4.9 % on the beam at twice the size. Owed: the 15 mm part restated with all of this (needs a CLI from this tip; after B7).

### THE 15 mm PART RESTATED (2026-11-27 03:56, build eb126ecf: the thin-member rule, the surface-node ball, the corner-aware width)

The sample bracket at 15 % size, res 48 (voxel 0.31 mm), PLA's own size 1.2 mm (3.8 voxels), drawn faces, automatic pad, one thread. Shown margin:

| version | switch off | size, as first measured (11-26, no thin-member rule) | size, as ruled (now) | now against off |
|---|---|---|---|---|
| 0.68 | 6.50 | 8.65 | 8.20 | +26 % |
| 0.52 | 6.51 | 8.65 | 8.20 | +26 % |
| 0.38 | 5.25 | 7.87 | 6.64 | +26 % |
| 0.26 | 4.24 | 5.97 | 6.03 | +42 % |

So the "33 to 41 %" becomes 26 % on the three heavier versions (their thin sections now keep today's reading) and 42 % on the lightest, whose deciding spot is in a section thick enough to be read over the size. Cost with the second solve: 576 s against 631 s with the switch off (no slower on this job); peak memory 174 MB. Rests, as before, on the published length halved by his rule; his print replaces it when the rig exists (the reviewer's ruling: ship on the published value).

Unit checks for the surface-node ball (`test_to_printed_mass`, 0 failures): on a full block with stress rising to 95 at a face, the voxel-centred ball over 4 voxels reads 89.76 and the ball on the face 91.90; where the face carries a cut layer no surface node counts; a ball under one voxel reads nothing on the surface.

### ONE JUDGE ON HIS OWN PART: evidence (b) FAILS (2026-11-27 05:05, B7 under the lock; Top Motor Mount, res 96, drawn faces, automatic pad)

| version | certificate | shown, re-check off | shown, `TOPOPT_RECHECK=fill:8` |
|---|---|---|---|
| 0.68 | 1.648 | 1.648 | 1.07: REFUSED ("After finishing, the margin is 1.07x (needs 1.5x)") |
| 0.52 | 1.660 | 1.657 | 1.06: REFUSED |
| 0.38 | 1.667 | 1.666 | 1.035: REFUSED |
| 0.26 | 1.694 | 1.679 | 1.00: REFUSED |

With one judge on, EVERY version of his part is refused. The reviewer expected "within 1 %" on his parts; it is 35 to 41 % lower. Run 3845 s against 4123 s off; peak 936 MB against 803 MB (+17 %); the finish step 39 to 44 s a version against 15 to 23 s.

WHY (reasoned from what is measured; to be confirmed by reading where the peak sits): the two judges agree on this part TODAY because both see the DRAWN part's own faces as all-or-nothing voxels: the optimiser's exact fills exist only on the surface it carves, and this part is mostly as drawn. One judge gives every voxel that the drawn faces cut its fill too, bolt holes and loaded faces included, and the one-voxel form then solves those voxels at E x fill^3, which reads the stress on a curved loaded face 52 to 76 % HIGH (the thick ring, tests E: ledger A-01). 1.648 / 1.07 = 1.54: the ring's error, on his bolt holes. On the same ring all-or-nothing reads 6 % low. So on a part like this the "cruder" judge is the nearer one, and one judge as built would refuse a good part.

WHAT IT MEANS: "one judge" cannot flip in the one-voxel E x fill^3 form. The fill of a file is right; the stiffness law applied to it is what is wrong at cut faces, and that law is the certificate's too wherever the optimiser has carved (which is why the lightest carved versions read near the pass mark by the loop's own judge). The reviewer's "after the flip: a fill-weighted one-voxel reading, into both judges together" has to come BEFORE the flip. The candidates already measured on the textbook shapes at one voxel: E x fill^2 (plate -3.8 to +4.3 %, ring +17 to +26 %, ellipse -19 to -2 %) and real stiffness E x fill (plate -18 to -6 %, ring -7 to -4 %): neither holds the bar on all three. PARKED for the reviewer's morning read; nothing built on it. B7 goes on with the stand, the hook and the beam, which will show how general this is.


### Ledger A-06 measured ahead for stage 4 (2026-11-27 05:05, test `to_strength_thin_member`, no switch)

TODAY'S one-voxel reading on a beam in pure bending against the true surface stress, by voxels through the member:

| voxels through | reading / surface stress | the exact field at the voxel's centre |
|---|---|---|
| 2 | 0.33 (-67 %) | 0.50 |
| 3 | 0.56 (-44 %) | 0.67 |
| 4 | 0.68 (-32 %) | 0.75 |
| 6 | 0.80 (-20 %) | 0.83 |
| 8 | 0.85 (-15 %) | 0.88 |
| 12 | 0.91 (-9 %) | 0.92 |
| 16 | 0.93 (-7 %) | 0.94 |

Two parts to the miss: reading at the voxel's centre instead of at the surface (the right column: half a voxel in, 1 - 1 / n), and below about 6 voxels the solve itself falling short of even that. To be within 10 % of the surface stress today's reading needs 12 voxels through a bending member; within 20 %, 6. Stage 4 sets its number from this table; surface stress recovery would remove the first part.

### One judge, evidence (b) continued: the original stand (2026-11-27 05:25, B7; res 128, PA12, drawn faces, automatic pad)

| version | certificate | shown, re-check off | shown, `fill:8` |
|---|---|---|---|
| 0.68 | 2.587 | 2.597 | 2.444 (-5.9 %; accepted, the pass mark is 1.5) |

Run 620 s against 530 s; peak 1002 MB against 987 MB. So the drop is not special to Top Motor Mount's size: on the stand it is 6 %, on Top Motor Mount 35 to 41 %. Neither is "within 1 %". Top Motor Mount has about 21 000 voxels cut by the file's surface at res 96, 7 500 of them with their centre outside the file (voxels the all-or-nothing judge does not solve at all). Its re-check with the stress field kept (heaviest version, switch off and on) is running outside the lock to show WHERE the peak sits.

### WHERE Top Motor Mount's peak sits with one judge on (2026-11-27 05:45; heaviest version re-checked with the stress field kept, switch off and on; picture `stage-2-pics/one-judge-top-motor-mount-peak.png`)

CORRECTION to the "WHY" above: the peak is NOT on a bolt hole. It is ONE voxel at the INSIDE CORNER where each motor flange meets the cross bar (both sides, mirror images), a sharp corner where the true stress has no finite value and any reading rises as the picture sharpens.

| | re-check off | one judge on |
|---|---|---|
| peak stress | 8.15 MPa (at the part's outer end) | 12.55 MPa (at the inside corner; off reads 7.28 there) |
| peak ratio | | 1.54 (the margin's drop, 1.648 -> 1.07) |
| over every voxel both solve: on / off | | median 1.24; 90th percentile 1.84; 99th 3.30 |

Two things, then, not one. (1) The WHOLE part reads about 24 % higher, not only its peak: of its 38 500 solved voxels about 21 000 are cut by the file's surface (the part is a few voxels thick at res 96), and E x fill^3 makes that cut skin almost stiffness-free (a half-full voxel carries one eighth), so the inside carries the load. All-or-nothing gives the same total material (105.35 g both ways) at full stiffness. (2) On top of that the peak moves to a sharp inside corner, on a cut voxel, where the one-voxel reading is at its least steady. The 96 voxels that only one judge solves (centre outside the file) peak at 3.6 MPa: they are not the cause.

So the finding stands and is stronger: on a thin part the E x fill^3 law, applied to the file's fills, under-reads the part's stiffness everywhere. The stand (thick, 6 % drop) and this part (thin, 35 to 41 %) are the same effect at two thicknesses.

### The cut skin on a thin bending member: WHICH judge is nearer (2026-11-27 06:20, new measuring test `to_strength_cut_skin`, no switch)

A beam in pure bending, `core` full voxels through plus one skin voxel of the given fill on each face (true thickness core + 2 fill), the same end moment on every model, read at mid-span. "soft" = the model's curvature against the exact beam's (+ = too soft). "peak" = the analysis's reading against the true surface stress (- = reads LOW, the unsafe way).

| core, skin fill | all-or-nothing (re-check today): soft / peak | E x fill^3 (one judge as built): soft / peak | E x fill^2: soft / peak | E x fill: soft / peak |
|---|---|---|---|---|
| 4, 0.25 | +37 % / -8 % | +33 % / -11 % | +20 % / -20 % | -13 % / -42 % |
| 4, 0.50 | -43 % / -43 % | +46 % / -12 % | +20 % / -28 % | -13 % / -47 % |
| 4, 0.75 | -24 % / -31 % | +27 % / +16 % | +9 % / -1 % | -8 % / -16 % |
| 8, 0.25 | +19 % / -2 % | +17 % / -3 % | +12 % / -8 % | -4 % / -21 % |
| 8, 0.50 | -28 % / -27 % | +26 % / -2 % | +14 % / -11 % | -4 % / -25 % |
| 8, 0.75 | -15 % / -19 % | +19 % / +12 % | +8 % / +3 % | -3 % / -8 % |
| 16, 0.25 | +9 % / -1 % | +9 % / -1 % | +7 % / -3 % | -1 % / -10 % |
| 16, 0.50 | -16 % / -16 % | +14 % / 0 % | +8 % / -4 % | -1 % / -13 % |
| 16, 0.75 | -8 % / -11 % | +11 % / +8 % | +5 % / +2 % | -1 % / -4 % |

(core 2 is in the test's output: every model misses by 30 to 76 % there; ledger A-06.)

WHAT IT SAYS, and it CORRECTS what I wrote above ("the cruder judge is the nearer one"):
1. On STIFFNESS, E x fill^3 is the worst of the three laws (9 to 46 % too soft), E x fill the best (1 to 13 % too stiff): the "whole part reads softer" reasoning holds.
2. On the PEAK READING it is the other way round. One judge as built reads within -12 to +16 % of the true surface stress on every row from 4 voxels up. All-or-nothing reads up to 43 % LOW (whenever the skin is half full or more it solves a beam thicker than the file, and reads at a voxel centre besides). The on / off ratio on these rows is 0.96 to 1.67: Top Motor Mount's 1.24 (median) and 1.54 (peak) sit inside it WITH ONE JUDGE THE NEARER ONE.
3. So for a thin part in bending the evidence is that today's shown margin (and the loop's certificate on the drawn faces, which is all-or-nothing there) is OPTIMISTIC, and the refusal may be nearer the truth than the 1.65. Against that stands the thick ring (a curved loaded face: E x fill^3 reads 52 to 76 % high, all-or-nothing 6 % low) and the fact that Top Motor Mount's peak voxel is at a sharp inside corner.
4. Neither judge holds a +/-10 % bar on thin members. E x fill^2 is the steadiest overall here (peak -28 to +3 %, but low); none of the four is right.

Honest position: I cannot say from this which number is right for Top Motor Mount; I can say the two disagree for a measured reason on BOTH sides, and that it is the stage 4 question (surface stress recovery; a member rule in voxels) arriving early. Parked for the reviewer.

### All shapes side by side: the one-voxel peak reading against the true value, by what the cut voxels are given (2026-11-27 06:30)

| shape | all-or-nothing | E x fill^3 (one judge as built) | E x fill^2 | E x fill |
|---|---|---|---|---|
| thick ring, pressure on the curved inner face (re-run today, 4 resolutions) | -6 to 0 % | +52 to +76 % | +17 to +27 % | -7 to -4 % |
| bending beam with cut faces, 4 to 16 voxels through (today) | -43 to -1 % | -12 to +16 % | -28 to +3 % | -47 to -4 % |
| plate with a hole, ellipse (measured earlier, above) | (see its tables) | (see its tables) | plate -3.8 to +4.3 %, ellipse -19 to -2 % | plate -18 to -6 % |

No column holds +/-10 % on both the ring and the beam. All-or-nothing is right on the ring and unsafe on the beam; E x fill^3 is near on the beam and far too high on the ring; E x fill^2 misses both by less (high on the ring, low on the beam). The two shapes differ in ONE thing: on the ring the LOAD sits on the cut face (the soft skin is squeezed directly), on the beam the cut faces are free and only carry the bending. So the candidate that the measurements point at is not a different power but a different treatment of LOADED cut faces from FREE ones, or reading the stress at the true surface instead of in the cut voxel (stage 4). Not built; for the reviewer.

### Measured ahead for stage 4: the stress CARRIED OUT TO THE TRUE SURFACE, on the cut-skin beam (2026-11-27 06:45, a measuring arm in `to_strength_cut_skin`; not in the engine)

The stress of the two outermost FULL voxels carried in a straight line to where the file's surface really is (half a voxel plus the skin's fill beyond the outer full voxel's centre), against the true surface stress. Three skin fills per thickness; lowest to highest.

| voxels through (core) | all-or-nothing | E x fill^3 | E x fill^2 | E x fill (real stiffness) |
|---|---|---|---|---|
| 4 | -43 to +38 % | +27 to +46 % | +9 to +20 % | -13 to -8 % |
| 8 | -28 to +19 % | +17 to +26 % | +8 to +14 % | -4 to -3 % |
| 16 | -16 to +9 % | +9 to +14 % | +5 to +8 % | -1 % |

Read at the true surface, the reading's error IS the model's stiffness error and nothing else (each figure equals the "soft" column of the table above). So the pair that works on a free cut face is REAL STIFFNESS for the cut voxels (E x fill) with the stress read AT THE TRUE SURFACE: within 4 % from 8 voxels through, 8 to 13 % low at 4, and steady across the skin's fill (which no one-voxel reading is). On the ring, E x fill at one voxel already reads -7 to -4 %. It is the first combination measured that is inside or near the bar on both shapes. Caveats: a straight beam and a straight-line carry; a curved or loaded face and a notch are not measured; it reads slightly LOW everywhere (the unsafe side), so it would need its own small allowance. A proposal for stage 4, for the reviewer; nothing built in the engine.

### The same carry on the thick ring: a CURVED face with the LOAD on it (2026-11-27 07:05, measuring arm `[carry]` in `to_strength_known_ring`; not in the engine)

The stress of the first FULL voxels behind the inner face carried to the TRUE inner radius along 32 rays (the largest of the 32), percent against the textbook 2.333. Wall = inner radius in voxels.

| inner radius, voxels | all-or-nothing: line / curve | E x fill^3: line / curve | E x fill (real stiffness): line / curve |
|---|---|---|---|
| 3 | +150 / +302 | +18 / +44 | -8.6 / +2.7 |
| 4 | +80 / +158 | +23 / +52 | -5.2 / +12.3 |
| 5 | +131 / +245 | +18 / +43 | -2.9 / +14.9 |
| 6 | +32 / +57 | +16 / +36 | -0.3 / +13.5 |

"line" = a straight line through two voxels; "curve" = a curve through three. Real stiffness with the STRAIGHT-LINE carry reads -8.6 to -0.3 % and closes on the textbook as the grid refines (the order a rule 5 measure must show). The curve overshoots; all-or-nothing cannot be carried at all (its staircase face makes the first voxels' stresses jagged).

SO, on both shapes (free cut faces in bending; a curved face under load): real stiffness on the cut voxels + the full voxels' stress carried in a straight line to the true surface is within 9 % at 3 to 4 voxels of wall or 8 through a beam, and within 3 to 4 % from 5 of wall / 8 through. Always slightly LOW. Still not measured: a notch or sharp inside corner (where Top Motor Mount's peak sits), a general surface (this arm walks rays it is given; the engine would need the surface's normal at each cut voxel), and the across-layer reading.

### One judge, evidence (b) continued: the made sample hook, res 64, re-check OFF (2026-11-27 07:25, B7; 7131 s, peak 309 MB)

| version | certificate (the loop's) | shown (the re-check today) | shown / certificate |
|---|---|---|---|
| 0.68 | 4.341 | 4.759 | 1.10 |
| 0.52 | 3.713 | 4.556 | 1.23 |
| 0.38 | 2.664 | 3.891 | 1.46 |

Three versions made (the fourth was not). On a part the optimiser has CARVED, the two judges already disagree today with no switch: the shown margin is 10 to 46 % ABOVE what the loop certified, and the gap widens as the part gets lighter and thinner. Same direction and size as Top Motor Mount's (1.54) and the cut-skin beam's (0.96 to 1.67): today's shown number is the optimistic one on thin carved members. The switch-on half of this run will be cut by B7's 07:52 limit; it is owed, and can run outside the lock (309 MB, one thread).

### The hook's three finished files re-checked with one judge ON (2026-11-27 07:40; `analyze --mesh` on each file with `TOPOPT_RECHECK=fill:8`, outside the lock)

| version | certificate (the loop's) | shown today (off) | one judge on | on against the certificate |
|---|---|---|---|---|
| 0.68 | 4.341 | 4.759 (+9.6 %) | 4.361 | +0.5 % |
| 0.52 | 3.713 | 4.556 (+22.7 %) | 3.754 | +1.1 % |
| 0.38 | 2.664 | 3.891 (+46.1 %) | 2.673 | +0.3 % |

On a part the optimiser carved, one judge does what it was built for: the number shown after finishing is the loop's certificate to about 1 % (the reviewer's "within 1 %" holds HERE), where today's re-check shows 10 to 46 % more. So the picture is whole: one judge makes the two numbers ONE number everywhere; whether that one number is RIGHT is the cut-voxel law's question (E x fill^3: near on free faces in bending, 52 to 76 % high on a loaded curved face), and it is the certificate's question just as much as the re-check's. Top Motor Mount differs from the hook only in that its certificate was all-or-nothing on its drawn faces (the loop never had fills there), so one judge moved it; on the hook the loop had the fills already.

### The carry at a TIGHT radius: the candidate does NOT hold there (2026-11-27 09:45, measuring arm `[carry]` in `to_strength_known_ellipse`; not in the engine)

The elliptical hole (a / b = 2, the exact peak 5 x the far stress at the tips of the long axis; the tip's radius is b / 2 = 1.5 to 3 voxels): the nearest textbook case to a sharp inside corner. Percent against the exact peak, b = 3 / 4 / 5 / 6 voxels.

| cut voxels at | one-voxel reading (the test's own rows) | carried to the true tip, straight line | carried, curve through three |
|---|---|---|---|
| E x fill (real stiffness) | -25 / -28 / -18 / -15 | -33 / -37 / -32 / -19 | -27 / -24 / -26 / -8 |
| E x fill^2 | -8 / -19 / -10 / -2 | -27 / -27 / -25 / -9 | -13 / -11 / -14 / +2 |
| E x fill^3 (today's law) | +7 / -14 / -4 / +9 | -19 / -21 / -22 / -6 | -1 / -4 / -12 / +6 |

THE CANDIDATE FAILS HERE: real stiffness with the straight-line carry reads 19 to 37 % LOW at a tip whose radius is 1.5 to 3 voxels, worse than its own one-voxel reading: the stress falls away from the tip within a voxel or two, and a straight line through voxel centres half a voxel and one and a half voxels back cannot follow it. Nothing measured holds 10 % at this radius; today's E x fill^3 at one voxel is the least bad (-14 to +9 %), by the accident that its too-soft skin raises the reading about as much as the grid lowers it.

So the honest summary of the cut-voxel question, all shapes:
- gentle faces (a flat face in bending, a ring's bore of radius 3 voxels or more): real stiffness + the straight-line carry, within 9 %, closing with refinement;
- a stress raiser whose radius is under about 3 voxels: no reading is within 10 %; the grid cannot see it. That is a RESOLUTION limit to state and to detect (the radius of the drawn face against the voxel), not a law to tune; it is ledger A-06's twin for fillets, and Top Motor Mount's inside corner (radius zero as voxelised) is its extreme case.
For the reviewer with the rest; nothing built in the engine.

### Printed grams read the user's own top and bottom skins (2026-11-27 10:40)

His ruling of 2026-11-26 ("the print parameters the user set should automatically be passed"). #362's four job keys (`loads.top_solid_layers`, `bottom_solid_layers`, `top_solid_mm`, `bottom_solid_mm`; shipped by the app from release 23) taken as its core-only patch (job.hpp, job.cpp, run_job.cpp: its files, its text, unchanged). Mine: `MinimizePlasticOptions::top_skin_mm / bottom_skin_mm` and the same two on `KnockdownSpec` (-1 = not stated), set in `to_run.inc` and `to_analyze.inc` from the job, read by both printed-grams calls (a version's, and the part as drawn). Not stated = the usual 1.0 mm top and 0.6 mm bottom, as before. No solve reads them. Still behind `TOPOPT_STRENGTH=size`.

Checked on the 15 mm sample bracket (`analyze`, res 48, built outside the lock): skins not stated 0.7466564941 g; stated at the usual 1.0 / 0.6 mm 0.7466564941 g (the same to every digit); stated at 2.0 / 2.0 mm 0.7581 g (more, as it must be); the stage switch off 0.7738 g (the solid figure, untouched by the keys). `to_printed_mass` passes. Not yet run: the whole suite with this change (9 files; it builds; the default path is the old one by construction).

### THE REVIEWER'S RULING OF 2026-11-27 16:34Z (11:34 EST), maintainer-approved: one judge and the cut-voxel law (word for word)

> 1. One judge as built does not flip. E x fill^3 on drawn faces refuses his good parts (Top Motor Mount, every version) and reads loaded curved faces 52 to 76 % high.
>
> 2. Interim, small, now: the shown margin is the LOWER of the loop's certificate and the file's re-check, and the version is judged on it. The screen then never shows more than the loop certified (the hook's 3.89 becomes 2.66), and nothing he is shown gets more optimistic. Put it behind its own switch. Flip it when test K, his two parts, and the hook, bracket and beam show no version refused that the certificate passes. It goes into the next release.
>
> 3. The real fix moves from stage 4 into stage 2, because it IS the strength number. Candidate one: real stiffness (E x fill) on cut voxels, with the stress carried to the true surface. Candidate two: patch recovery with zero traction on the free surface (Nadal et al. 2013, in your 01-research.md). Measure both on the plate, ring, ellipse, beam and cut-skin beam, then his two parts and the three carved samples. Drawn faces get their fills in the loop at the same time (your order (1)), never with fill^3. Bar: never more than 5 % under the true value where the feature is resolved. If a form reads low by a steady amount, one allowance may be set on the beam and the ring, and it must hold on the plate and the ellipse, which are held out. Both judges move together, and one judge flips with this.
>
> 4. Not resolved (stress raisers under about 3 voxels of radius; members under 6 voxels through in bending): stated limits A-06 and A-08 in the ledger, detected and named in the engineer's readout. A finer resolution is the remedy (his "keep going finer"). No pop-up now.
>
> 5. scenario_weights check (c): your form is accepted (c15 >= 1.10 x c10, c20 >= 0.95 x c15).
>
> 6. The size form is complete. Run (b) to (e) on his full-resolution parts with this build when the lock allows.

WHAT I DO WITH IT, in order:
- (2) DONE IN CODE 11:45: `TOPOPT_SHOWN=lower` (to_stage_switch.hpp); in `recheck_file` (to_export.inc) the finished file's margin becomes the certificate when the certificate is lower, and the verdict is judged on that. Unset = today's bytes. Evidence owed before the flip: test K, his two parts, the hook, bracket and beam with the switch on: no version refused that the certificate passes. (By construction the switch can only LOWER the shown number to a certificate that already passed, so it cannot add a refusal; the runs are to show it.)
- (5) DONE IN CODE 11:45: `test_scenario_weights.cpp` check (c).
- (3) the stage's main work now: (a) candidate one in the engine behind a switch (real stiffness on cut voxels; the surface's normal at each cut voxel from the fill's gradient; the straight-line carry); (b) candidate two as a measuring arm first (a least-squares fit of the stress over full voxels near the surface with zero traction on it); (c) both on the five textbook shapes with the plate and the ellipse HELD OUT of any allowance; (d) the drawn faces' fills into the loop; (e) his two parts and the three carved samples.
- (4) A-06 and A-08 lose "proposed"; the readout's detection is part of (3)'s report.
- (6) queued behind TOSurface's and TOSolver's waiting jobs.

### The interim, first check: the 15 mm sample bracket, res 48, `TOPOPT_SHOWN` unset and `lower` (2026-11-27 12:10, outside the lock)

| version | certificate | shown, unset (today) | shown, `lower` |
|---|---|---|---|
| 0.68 | 6.353 | 6.499 | 6.353 |
| 0.52 | 6.350 | 6.513 | 6.350 |
| 0.38 | 4.845 | 5.249 | 4.845 |
| 0.26 | 2.091 | 4.241 (twice the certificate) | 2.091 |

Four versions made and accepted both ways; all four files are the same bytes with the switch on as off (the switch changes the number shown and judged, never the shape). One `[shown]` line a version on stderr says which was the lower. Owed before the flip (the ruling): test K, his two parts, the hook, the bracket at full size and the beam with the switch on.

### THE REAL FIX, candidate one as an engine function: `stress_carried_to_surface` (2026-11-27 12:25; stress_measure.hpp/.cpp; print-only rows in four tests; nothing in the engine calls it yet)

What it does: real stiffness on the cut voxels (the caller's solve at penalty 1); for every voxel on the part's surface it finds the surface's normal itself (from the fills' gradient; a flat face lying on voxel boundaries is carried along its own axis, and at an EDGE each face is carried on its own normal), walks inward to the first two FULL voxels and carries their stress in a straight line to where the surface really is. Where there are not two full voxels behind a surface point it says so (`unresolved`) and falls back to the nearest value. Written by a builder to my design; two corrections of mine after reading and after the first run (a divisor guard; the edge rule: the first run blended a hole's wall with the plate's flat face into one diagonal normal and read the plate 38 % low).

Percent against the exact value, real stiffness (E x fill):

| shape | resolution | reading |
|---|---|---|
| cut-skin beam, bending (free cut faces) | 4 / 8 / 16 voxels through | -13 to -8 / -4 to -3 / -1 (the same as the hand arm, to the digit) |
| thick ring, pressure on the bore | bore radius 3 / 4 / 5 / 6 voxels | -13.0 / -4.9 / -4.3 / +1.3 |
| plate with a round hole (HELD OUT) | hole radius 3 / 4 / 5 / 6 voxels | -28.9 / -13.8 / -14.4 / -9.1 |
| elliptical hole (HELD OUT) | tip radius 1.5 / 2 / 2.5 / 3 voxels | -37.2 / -36.7 / -34.7 / -15.3 |

WHERE IT STANDS AGAINST THE BAR (never more than 5 % under where the feature is resolved): the beam from 8 voxels through and the ring from 4 voxels of bore meet it; THE PLATE DOES NOT at any resolution tried (9 % low with a hole 6 voxels in radius), and it is a held-out shape, so no allowance set on the beam and ring (about 4 to 5 %) covers it. Why: beside a hole the stress falls away from the edge on a CURVE (it loses about a third within one sixth of the radius); a straight line through the first two full voxels cuts under it. The curve through three voxels over-reads the ring instead (+3 to +15 %, the hand arm). So candidate one is right in kind and too crude at a stress raiser: it needs the fit to know the surface carries no load, which is exactly candidate two (patch recovery with zero traction on the free surface). Next: candidate two as a function beside this one, the same four tests.

### THE REAL FIX, candidate two as written: `stress_recovered_at_surface` READS LOWER THAN CANDIDATE ONE (2026-11-27 12:50; print-only `[patch]` rows in the same four tests; a builder's code to my design, built and run once)

A LINEAR fit of the stress tensor over the full voxels within 2.5 (or 3.5) voxels of each surface point, with equilibrium of the fitted field and zero traction on a free surface imposed exactly (the ring's bore passed as loaded). Percent against the exact value, real stiffness:

| shape | patch 2.5 | patch 3.5 | candidate one (the carry) |
|---|---|---|---|
| ring, bore 3 / 4 / 5 / 6 voxels | -31 / -20 / -16 / -12 | -35 / -24 / -20 / -16 | -13 / -4.9 / -4.3 / +1.3 |
| plate with a round hole, 3 / 4 / 5 / 6 | -43 / -31 / -23 / -19 | -43 / -31 / -27 / -28 | -29 / -14 / -14 / -9 |
| ellipse, tip radius 1.5 to 3 | -47 to -33 | -48 to -35 | -37 to -15 |
| cut-skin beam | equal to the carry to three decimals (a full voxel sets the peak) | | |

It is WORSE on every stress raiser, and the bigger patch is worse still: a straight-line (linear) fit over two to three voxels averages away the steep rise into the raiser; the conditions imposed are right but cannot put back a curve the fit has no term for. Candidate one's rows are unchanged to the byte (the two functions now share one enumeration of the surface points). The tensor field needed is already filled by `analyze_fixed_design` (Voigt xx, yy, zz, xy, yz, zx; true shear; the material's own stress).

NEXT, one more form before reporting the pair to the reviewer: the same patch with a QUADRATIC fit (the published method uses a full polynomial; the conditions then tie the curve down instead of the curve being absent), radius 3.5. If that does not bring the held-out plate inside 5 % from a stated radius, the honest result is that at this grid no reading does, and the bar is met only by a radius-in-voxels limit (A-08) set higher than 3.

### Candidate two with a QUADRATIC fit: no better (2026-11-27 13:05; `order = 2` of `stress_recovered_at_surface`; a builder's code, built and run once)

A full quadratic per component with equilibrium (12 conditions) and zero traction (3); the pure-square term of a direction is dropped where the patch has fewer than three layers that way (the two-voxel-thick test plates: always z). Percent against the exact value, real stiffness, patch radius 3.5 / 4.5:

| shape | quadratic patch | linear patch (3.5) | candidate one (the carry) |
|---|---|---|---|
| ring, bore 3 / 4 / 5 / 6 | -35 / -35; -24 / -13; -18 / -12; -9 / -9 (60 to 90 points unresolved at bore 3, none from 5) | -35 / -24 / -20 / -16 | -13 / -4.9 / -4.3 / +1.3 |
| plate with a round hole, 3 / 4 / 5 / 6 | -43 / -43; -31 / -31; -26 / -27; -20 / -28 | -43 / -31 / -27 / -28 | -29 / -14 / -14 / -9 |
| ellipse (today's law rows) | -41 / -36 / -33 / -25 | the same | -33 / -20 / -17 / +2 |

On the plate and the ellipse the patch's value IS the hottest full voxel's own stress: every surface reading it made came out BELOW that. On the cut-skin beam it is erratic at radius 3.5 (0.50 where the carry reads 0.92). Candidate one's and the linear patch's rows are unchanged. So, of everything tried on this grid, candidate one (real stiffness, the straight-line carry, each face on its own normal) is the best reading, and it does not meet the 5 % bar beside a hole of 3 to 6 voxels of radius.

NOT OBTAINED: how large a hole must be for candidate one to be within 5 %. The plate test at radii 8, 10, 12, 16 voxels (now behind `--large`, never in the suite) returned empty fields: those solves did not converge inside the cap on plates that wide and two voxels thick. A thicker plate or another solver setting is needed to answer it.

DESK RESEARCH in hand for the next step (four researchers, 2026-11-27; `reports/Voxel stress on small thin parts.md`, local, not committed): (i) the straight line itself accounts for most of the miss beside a hole (the exact Kirsch field sampled at voxel centres and carried in a straight line reads 6.5 to 16.5 % low at 6 and 3 voxels of radius: the researcher's own calculation, to be checked); a carry that knows the surface's curvature is the indicated fix; (ii) a direction-aware stiffness for cut voxels ("laminate composite voxel", Kabel, Merkert, Schneider 2015; Lendvai and Schneider 2024, doi:10.1002/nme.7459) in place of E x fill; (iii) for thin members, membrane and bending stress from SECTION FORCES (exact by equilibrium; welded-joint practice), and an incompatible-modes hexahedron for bending with one or two voxels through; (iv) printed PLA is nearly notch-insensitive in static loading with a material length of 2.4 to 4.6 mm (Susmel and Ahmed 2018; Ahmed and Susmel 2019, read in full by the researcher), which supports the size form over any surface peak; no data found for filament-printed PA6.

### How large must a hole be for the carry to pass? Answered by arithmetic on the exact field (2026-11-27 13:30; no solve)

The exact hoop stress beside a round hole (Kirsch: 1 + a^2 / 2 r^2 + 3 a^4 / 2 r^4, peak 3), sampled at two depths behind the surface and carried to it. This is the carry's own error with a PERFECT solve; the solve adds its own. It also checks the desk researcher's figures (-16.5 % at 3 voxels, -6.5 % at 6): they are right.

| hole radius, voxels | straight line, samples 0.5 and 1.5 voxels in | straight line, 1.0 and 2.0 in | A + B / r^2, 0.5 and 1.5 in | A + B / r^2, 1.0 and 2.0 in |
|---|---|---|---|---|
| 3 | -16.5 % | -28.8 % | -7.4 % | -14.0 % |
| 4 | -11.5 % | -21.7 % | -4.9 % | -10.0 % |
| 5 | -8.5 % | -16.8 % | -3.5 % | -7.5 % |
| 6 | -6.5 % | -13.4 % | -2.7 % | -5.8 % |
| 8 | -4.2 % | -9.0 % | -1.7 % | -3.8 % |
| 10 | -2.9 % | -6.5 % | -1.1 % | -2.7 % |
| 12 | -2.1 % | -4.9 % | -0.8 % | -2.0 % |
| 16 | -1.3 % | -3.1 % | -0.5 % | -1.2 % |

Reading it: the engine's measured row (-29 / -14 / -14 / -9 % at 3 to 6) lies between the two straight-line columns, so the measured miss IS the straight line's, as the research said. For the straight-line carry a hole is "resolved" (inside 5 %) from about 8 to 12 voxels of radius, depending on how deep its two full voxels sit. A carry of the shape A + B / r^2, with r measured from the surface's centre of curvature (exact for a pressurised ring, and the leading term beside any hole), halves the miss and brings the limit down to about 4 to 7 voxels. So the next form to build and measure is that one: the same function, the surface's radius of curvature from the fills, the two full voxels fitted to A + B / r^2 (falling back to the straight line where the surface is flat). The limit A-08 then reads "under about 4 voxels of radius", and what is under it goes to the size form.

### Candidate one with a CURVATURE-SHAPED carry (`shape = 1` of `stress_carried_to_surface`): 2026-11-27 14:30, two builds

The surface's curvature from the true-surface positions of the nearby cut-face points (a quadric fit in the tangent frame, the median over 2 voxels); only on CONCAVE surfaces; the two full voxels fitted to A + B / r^2, r from the centre of curvature; a radius under 2.5 voxels is counted `tight_points` and kept on the straight line (the detection ledger A-08 asks for); never above 1.5 x the straight line (never fired). The first build, without those limits, read the ring +46 / +16 / +72 / +8 %. Percent against exact, real stiffness; (T n) = tight points:

| shape | 3 | 4 | 5 | 6 | straight line, for comparison |
|---|---|---|---|---|---|
| plate, round hole (held out), radius | -28.9 (T 22: tight, straight line) | +3.2 | -4.2 | -1.0 | -28.9 / -13.8 / -14.4 / -9.1 |
| ellipse (held out), E x fill, b | -37.2 (T 12) | -36.7 (T 18) | -11.0 | -5.5 | -37.2 / -36.7 / -34.7 / -15.3 |
| ring, pressure ON the bore, bore | +19.3 (T 32) | +14.3 | +24.2 | +19.2 | -13.0 / -4.9 / -4.3 / +1.3 |
| cut-skin beam | the straight line's values (flat) | | | | |

READING IT.
- FREE concave surfaces: the held-out plate is inside 5 % from a hole radius of 4 voxels (+3.2 / -4.2 / -1.0), where the straight line was 9 to 14 % low. The ellipse's tip is tight (straight line, flagged) at b = 3 and 4 and reads -11 and -5.5 % at tip radii of 2.5 and 3 voxels. So on free surfaces the form meets the bar from about 4 voxels of radius, nearly at 3, and says "tight" below 2.5.
- The LOADED bore of the ring reads 14 to 24 % HIGH. Arithmetic on the exact ring field (Lamé, von Mises) says a perfect solve carried this way reads within 1.3 %, and carried in a straight line reads 4 to 12 % LOW (at samples 0.5 and 1.5 voxels in). The measured straight line read only -4.9 to +1.3 %: so the SOLVE'S stress in the first full voxels behind a loaded cut face is itself too high and too steep, the straight line was hiding it by cancelling, and the better carry shows it. It is the loaded cut face again (ledger A-01's family): the fault is in how the load meets the cut voxels in the solve, not in the carry.
NEXT: the curved form on FREE surfaces only (a surface voxel tagged Load keeps the straight line, which is the measured best there), then the pair on all five shapes is the candidate to put to the reviewer; the loaded cut face is its own item (the direction-aware cut-voxel stiffness from the research is the lead).

### THE READING TO PUT TO THE REVIEWER (2026-11-27 14:35): real stiffness on the cut voxels; the stress of the first two full voxels carried to the true surface; CURVED (A + B / r^2) on free concave surfaces, a STRAIGHT LINE on flat, convex and LOADED ones; tight radii flagged

`stress_carried_to_surface(grid, field, density, shape = 1)`; a surface voxel (or its first full voxel) tagged `Load` keeps the straight line (`loaded_points`); a concave radius under 2.5 voxels keeps the straight line and is counted (`tight_points`). Print-only rows in four tests; nothing in the engine calls it yet. Percent against the exact value:

| shape | resolution | reading | bar (never more than 5 % under where resolved) |
|---|---|---|---|
| cut-skin beam, bending, free flat faces | 4 / 8 / 16 voxels through | -13 to -8 / -4 to -3 / -1 | met from 8 through; 4 through is ledger A-06 |
| thick ring, pressure on the bore (loaded: straight line) | bore 3 / 4 / 5 / 6 voxels | -13.0 / -4.9 / -4.3 / +1.3 | met from 4 |
| plate, round hole (HELD OUT; free: curved) | radius 3 / 4 / 5 / 6 | -28.9 (flagged tight) / +3.2 / -4.2 / -1.0 | met from 4; 3 is flagged |
| ellipse (HELD OUT; free: curved), real stiffness | tip radius 1.5 / 2 / 2.5 / 3 | -37.2 (flagged) / -36.7 (flagged) / -11.0 / -5.5 | flagged under 2.5; NOT met at 2.5 (-11 %) and just missed at 3 (-5.5 %) |

So: the bar is met on all four shapes for features of 4 voxels of radius or 8 voxels through and more, with no allowance set. Between 2.5 and 4 voxels of radius it reads 5 to 11 % low and is NOT flagged: the tight limit should be 4, not 2.5 (then everything unflagged is inside the bar on these shapes). Known loose ends: (a) on the loaded bore the straight line is right by cancellation (the solve behind a loaded cut face is too steep), so a loaded face is a stated limit of its own until the solve is dealt with; (b) a loaded point is counted loaded before its radius is checked, so a tight loaded radius is not counted tight; (c) at bore 3 sixteen points away from the bore take the curved form (probably outer-face points whose curvature reads with the wrong sign at that resolution); the peak is not theirs; (d) the curvature-shaped form is not in the literature read (Svärd 2015 is the straight line); it rests on these four shapes and on arithmetic on two exact fields; (e) not yet run on a real part, on a general 3D surface (a sphere-like raiser decays differently from a hole), or across layers; (f) the plate, ring and ellipse tests are two voxels thick.

### The size form against the theory's own readings, by arithmetic on the exact field beside a hole (2026-11-27 14:40; no solve; PLA, L = 2.4 mm)

The papers read today (Taylor 2006; Susmel and Taylor 2008) define the Point Method (the maximum principal stress at L / 2 from the hot spot) and the Line Method (its average along 2 L). Stage 2 reads von Mises averaged over the material in a BALL centred on the surface, of diameter HALF the published length (the maintainer's rule of 2026-11-25, until his rig checks it): 1.2 mm for PLA. Each as a multiple of the far stress (the elastic peak is 3.00):

| hole radius, mm | Point Method | Line Method | the ball today (D = L / 2): von Mises / max principal | ball D = L | ball D = 2 L |
|---|---|---|---|---|---|
| 0.25 | 1.02 | 1.05 | 1.09 / 1.06 | 1.01 | 1.00 |
| 0.5 | 1.05 | 1.10 | 1.40 / 1.45 | 1.06 | 1.01 |
| 1 | 1.17 | 1.19 | 1.85 / 1.95 | 1.45 | 1.06 |
| 2 | 1.42 | 1.35 | 2.28 / 2.37 | 1.95 | 1.45 |
| 4 | 1.82 | 1.60 | 2.59 / 2.65 | 2.37 | 1.95 |
| 8 | 2.24 | 1.94 | 2.78 / 2.82 | 2.65 | 2.37 |
| 16 | 2.56 | 2.29 | 2.89 / 2.90 | 2.82 | 2.65 |

What it says:
1. Stage 2's ball is on the SAFE side of the theory everywhere: it reads 7 to 58 % more stress than the Point Method (most beside holes of 1 to 2 mm). That is the price of his half-length rule; it is caution, not error.
2. Von Mises against maximum principal: 2 to 5 % apart on this field. The choice of quantity matters little HERE (a free surface in tension); it will matter where the stress is compressive or sheared, which this does not test.
3. A ball of diameter 2 L (4.8 mm for PLA) reads what the Point Method reads, within -9 to +7 %. So "the ball" has a calibration against the validated method: diameter 2 L is the neutral setting, L / 2 the cautious one in force. His rig decides between them.
4. A hole under about 0.5 mm in PLA reads as no notch at all by every method (1.0 to 1.1): the theory's "features much smaller than L lose their effect", and the reason ledger A-08 (raisers the grid cannot see) costs little for PLA under a single load. Under repeated load L is about 0.5 mm and that comfort is gone.
For the reviewer with the rest; nothing changed in code.

### THE REVIEWER'S RULING OF 2026-11-27 19:36Z (14:36 EST), maintainer-approved: item 3 (word for word)

> (a) Yes: this is the form for both judges. Real stiffness on cut voxels; the carry curved on free concave surfaces and straight on flat, convex and loaded ones; drawn-face fills in the loop. Build it behind the switch. "Resolved" = 4 voxels of radius and 8 through; below that, A-06 / A-08 are named in the readout. Before one judge flips, measure:
> 1. a real 3D raiser: an inside-corner fillet like Top Motor Mount's, radius 4 voxels or more, against a solve 4 times finer;
> 2. a plate several voxels thick, not 2;
> 3. across the layers;
> 4. his two parts and the three carved samples: certificate against re-check, one number, refusals listed;
> 5. test K.
> The loaded face is right by cancellation: pin it with the ring as a test, and state it as a limit.
>
> (b) Thin members: yes to (iii). Measure section-force stress (membrane and bending from the section's own forces, exact by equilibrium) on the cut-skin beam at 2 to 6 voxels through, plus one member in tension. If it holds the bar, it becomes the reading under 8 through. Until then, flagged places are named and the verdict is unchanged: no worse than today, and the remedy is close.
>
> (c) Patch recovery stopped and the laminate dropped: agreed. The enhanced-strain hexahedron changes the solve and every number. It is TOSolver's ground and his decision, so it is parked as an idea.
>
> (d) The size form: leave the ball and his half-length rule as they are, and state your calibration in the stage report (safe side of the Point Method by 7 to 58 %; a 2L ball would be neutral). Our ball is a quarter of the theory's size, so the blunt-notch caution in Taylor does not bite here. Compression and shear stay untested and are stated as such.
>
> (e) Stage 3: your ruling stands. It does not close and the switch does not flip until test P passes, and parallel fixes give the same bytes as the serial code.

HOW I READ (a), stated to the reviewer so it can correct me: the size form (the ball) stays where it applies; the surface carry on a real-stiffness solve takes the place of the ONE-VOXEL reading wherever the code falls back to it today (a material length under 1.75 voxels; thin members), in the one function both judges call (`analyze_fixed_design`). Order of work: (A1) the reading in `analyze_fixed_design` behind `TOPOPT_STRENGTH=surface`, the tight limit at 4 voxels, the counts for the readout, the ring pinned as a test; (B) section-force stress measured on the cut-skin beam and a member in tension; (A2) the drawn faces' fills in the loop; then the five measurements.

### A1 BUILT: `TOPOPT_STRENGTH=surface`, the surface reading inside the one judge function (2026-11-27 15:30; a builder's code to my design, two builds, the four tests run)

`StrengthMode::Surface` does everything `Size` does, and wherever `Size` falls back to today's solve and the one-voxel reading it reads the REAL-STIFFNESS solve with `stress_carried_to_surface(..., shape 1)`: over the thin-member voxels only (a mask) when the ball covers the rest, over the whole part when the material's size is under the switch point. Every new line in `analyze.cpp` sits under the new mode; `Today`, `Stiff` and `Size` are untouched (all earlier printed values identical). New: `kSurfaceResolvedRadiusVoxels = 4`, `kSurfaceResolvedThroughVoxels = 8`; a tight point is counted even when it is loaded; the curvature fit uses only points facing the same way (it had mixed in the far face of a thin beam); `FixedDesignAnalysis::surface_tight_points / surface_unresolved_points / surface_loaded_points / surface_read_peak / surface_thin_voxels` for the readout.

Measured with the limit at 4:
- The ring, loaded bore PINNED as a test (`--gate`: within -6 to +3 % at bores 4, 5, 6): -4.9 / -4.3 / +1.3 %, passes.
- Plate with a hole, radius 3 / 4 / 5 / 6: -28.9 (tight) / -13.8 (TIGHT: 36 points; the radius-4 hole sits on the limit and is flagged, where at a limit of 2.5 it read +3.2) / -4.2 / -1.0. Ellipse: flagged below, -5.2 % at tip radius 3.
- THE JUDGE on the cut-skin beam (the whole part, its loaded ends included) against the true surface stress: 8 voxels through 0.96 to 1.01; 16 through 0.99; 4 through 1.00 to 1.17 and 2 through 0.50 to 0.79, where the reading comes from the beam's LOADED ENDS, not the span (the span alone reads 0.87 to 0.92 at 4 and 0.24 to 0.27 at 2: ledger A-06, unchanged).

NOT DONE YET: (1) the CLI sets the stress-reading size only when the mode is `Size` (three CLI files), so `surface` does not reach a run from the command line until that one condition is widened: next; (2) `surface_thin_voxels` is filled only where member widths are already measured; (3) nothing reports the counts yet; (4) A2 (the drawn faces' fills in the loop) and the reviewer's five measurements.

### `TOPOPT_STRENGTH=surface` now reaches a command-line run (2026-11-27 16:00)

The three CLI conditions that set the stress-reading size (`to_setup.inc`, `to_analyze.inc`, `to_run.inc`) accept `Surface` as they accept `Size`. Checked on the 15 mm bracket as drawn (`analyze`, res 48, PLA): switch unset: margin 6.530, the same `analysis.json` bytes as before the change; `size`: 8.190 (stress 2.374 MPa, 0.7467 g printed); `surface`: 8.190, identical to `size`, as it should be here: PLA's ball (1.2 mm) spans 3.8 voxels at this resolution and no member is thin by the rule, so nothing falls back to the surface reading. A case that does fall back (a material with no published length, or a coarser grid) is the next check, with the reviewer's five measurements.

### B MEASURED: section-force stress on thin members (the reviewer's ruling (b)); 2026-11-27 16:45; a measuring arm in `to_strength_cut_skin`, nothing in the engine

The member cut at mid-span; the nodal forces the material on one side puts across the cut, from the solve itself (`fea_matfree_apply` on the half model); N and M from them; membrane N / A and bending M c / I on the TRUE section (the skin's fill). Against the true surface stress:

| member | section-force stress | the per-voxel peak, for comparison | the surface carry |
|---|---|---|---|
| bending, 2, 3, 4, 6, 8, 16 voxels of core, skin fills 0.25 / 0.5 / 0.75, every skin model (60 rows) | 1.000 in every row | 0.41 to 0.96 at 3 and 6 | 0.63 to 1.28 at 3 and 6 |
| tension, core 2 and 4, all-or-nothing | 1.000 | 0.750 and 0.834 | |
| tension, core 2 and 4, E x fill | 1.000 | 1.000 | |

The moment and the force measured across the cut equal the applied ones to four digits in every row. The rows at ONE voxel of core did not solve (not looked into; printed, not counted).

WHAT IT PROVES AND WHAT IT DOES NOT. It holds the bar exactly here, at 2 voxels through as at 16, because the forces across a cut are right by equilibrium whatever the element does. But this beam is STATICALLY DETERMINATE: the moment at mid-span is fixed by the load, and the true section was GIVEN. So 1.000 confirms the reading; it does not test the two things a real part adds: (1) HOW MUCH LOAD a thin member takes when stiffer paths share it, which depends on the solve's stiffness (the extrusion stand at 64 voxels is 35 % too stiff as a whole; a fine-box side measurement the same day); (2) FINDING the member, its cut plane and its true section on a general shape. Next before it can become the reading under 8 through: a statically INDETERMINATE case (two members of different thickness sharing a load, against the fine solve), and the section taken from the voxel model's own fills, not handed in.

### A2, the drawn faces' fills in the loop: the code study and the design (2026-11-27 17:00; nothing built yet)

What the loop does today (a builder's read-only study, file:line in its report): the certificate and the in-loop margin probe both call `analyze_fixed_design` on the design's density (`minimize_plastic.cpp` 2983 and 2283), built in `plsm.cpp` 524 to 537: a voxel the DRAWN surface cuts is 1.0 when its centre is inside the part and has NO element when its centre is outside (it is tagged Empty); only the carved surface has exact fills. The drawn mesh is not available inside the loop; it is in `build_job_setup` (`to_setup.inc` 135).

THE DESIGN (mine): behind `TOPOPT_STRENGTH=surface` only. (1) `to_setup.inc` computes the drawn part's fills once on the solved grid (`file_fill_fractions`, 8 per edge) and carries them on the options. (2) BOTH the probe and the certificate use them (the code's own rule, 2259 to 2261: the probe and the certificate measure the same thing), so under the switch the optimiser's PATH may change, not only its number; that is the ruling's "in the loop". (3) The combination inside the drawn part is min(drawn fill, carved fill); a voxel outside the drawn part's centres that the drawn surface cuts gets an element at its drawn fill only where it touches printed material; grown material outside the drawn faces (a design box) keeps the carved fill; Load and Fixture voxels keep what they have. (4) Only the STRESS side reads this field: the grams and the exported mesh stay on today's density, so no file changes shape and no mass moves because of it. (5) No file of another agent is touched (not `plsm.cpp`, `run_job.cpp`, `job.*`). With the switch unset: today's bytes.

