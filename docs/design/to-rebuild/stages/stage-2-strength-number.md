# Stage 2: a strength number that holds (TOReview)

Status: PROPOSAL for discussion with the maintainer. Nothing built except a measuring tool (`stress_measure.hpp`) and two textbook tests. The certificate is shared with the lattice strength check, so whatever is agreed goes to the reviewer and LatticeReview before any change to `analyze.cpp`.

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
| weight | Printed grams at the job's walls and infill (`mass_grams`; the solid figure kept as `mass_grams_solid`) | `printed_mass.cpp`, `analyze.cpp` | unit test passes; not yet read on a job. NOT done: "saved" (needs the drawn part's printed grams at the same infill), and solid top and bottom layers |
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

## What it does to the lattice strength check

Steps 1 and 2 change the solid part's reading only if applied in the shared code path; the lattice check reads strut stresses through its own laws. To be confirmed with LatticeReview before any edit: which branches of `analyze.cpp` the lattice posture takes, and that its numbers are byte-identical with the switch off.
