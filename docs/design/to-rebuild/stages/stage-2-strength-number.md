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

## What it does to the lattice strength check

Steps 1 and 2 change the solid part's reading only if applied in the shared code path; the lattice check reads strut stresses through its own laws. To be confirmed with LatticeReview before any edit: which branches of `analyze.cpp` the lattice posture takes, and that its numbers are byte-identical with the switch off.
