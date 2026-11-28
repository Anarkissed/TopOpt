# Stage 4: rules inside the optimiser

Started 2026-11-27 night by the maintainer's word ("can we start the next stage right now?"). This file is the stage's running record: the plan, then results as they come. Nothing here is built yet.

## In plain words, for the maintainer

Today the optimiser only knows one thing: keep the part as stiff as possible for a given amount of plastic. The print rules are checked or patched on AFTER it finishes: thin spots are pushed out, loose pieces are joined with straight bars, sealed pockets are only counted, overhangs and waviness are not looked at during the run at all. Stage 4 moves those rules INSIDE the optimiser, so the shape it hands back already obeys them and nothing has to be patched afterwards.

The six rules: (1) smallest wall: one print line for a solid part (your ruling of 2026-11-26; two lines is the lattice's rule); (2) smallest hole or gap; (3) sealed pockets: allowed in a solid part with one plain line telling you, refused in a lattice (your earlier decision); (4) overhang; (5) a limit on waviness; (6) the load must keep a path to its anchors (today: straight bars stamped in afterwards).

It is too big for one stage, so it is split:
- STAGE 4a, starts now, does not wait on the unfinished stages: the optimiser learns to respect several rules at once (today it can only hold one); the smallest wall becomes one line for solid parts (your ruling, not yet carried out in the code: it still says two); sealed pockets get their rule; the app picks a resolution that keeps the thinnest member thick enough in cubes to be trusted (the limit found in stage 2); and, once stage 3 is released, load paths are kept connected inside the run so the stamped bars can go.
- STAGE 4b, after stages 3 and 5: the smallest wall AND hole enforced during the run, overhang, and the waviness limit. These triple the solving work and live in the surface helper's files, so they wait for the faster solver and the finished surface.

What I need from you later (not now): the overhang angle (45 degrees is the usual value) and whether orientation is the user's or the app's to choose: you asked that orientation be discussed first.

## The six rules: today, and what the stage does (from the start study of 2026-11-27; file:line as read)

| rule | today | stage 4 |
|---|---|---|
| smallest wall | no rule in the loop (`plsm.cpp` feeds MMA only compliance and volume); enforced after the run by `thin_spot_cleanup` (`finish.cpp` 351 to 442), whose floor is still 2 x the outer line (`to_export.inc` 26) | 4a: the floor at ONE line for a solid part. 4b: the robust eroded / middle / dilated triple (Wang 2011; Andreasen 2020 for level sets), measured against explicit constraints (Dunning 2018); then `thin_spot_cleanup` is removed |
| smallest hole | nothing | 4b: the same triple (the only method that guarantees a size on solid and void alike) |
| drain / sealed pockets | counted only (`plsm_topology.hpp` 145 to 341; reported `to_run.inc` 2257); refused only for a sealed lattice void and a sealed Keep clear | 4a: the accept rule: solid = one plain line, lattice = refused |
| overhang | nothing in the loop; a count feeds the report and the orientation scorer | 4b: a layer filter along the build direction (Langelaar), on the fill fractions |
| waviness | nothing in the loop; the curvature flow after the run goes with stage 3 | 4b: a perimeter or curvature bound from the function (Haber 1996; Yamada 2010), three levels against none |
| load paths connected | detection in the loop (a severed probe is discarded); after each version `bridge_split_bodies` stamps straight bars; then a version is refused if the path is cut | 4a (after stage 3): a cheap roll-back with a flood fill per step; then the bars go. Other options to measure: a fail-safe load case per fixed face; a virtual-temperature limit (Coola, Aage, Sigmund 2025) |

Also in 4a: ONE optimiser update that holds several constraints (ledger S-06; today's MMA holds one), tested on a textbook two-constraint problem; the member rule in voxels (ledger A-06, A-08: a member under 8 voxels through in bending and a raiser under 4 voxels of radius are not resolved: the automatic resolution should keep the thinnest member thick enough, or say it cannot).

## The gate (04-tests; two lines are stale and are corrected here pending the reviewer)

G: thinnest wall at least ONE line (0.45 mm) for a solid part (the test still says 0.9 mm). H: each print check refuses a part built to fail it, with its own plain reason. I: a sealed pocket is caught: REPORTED in a solid part, REFUSED in a lattice (the test's wording predates his decision). P: no more than 10 % slower. The reference table on all parts. The two experiments (smallest-size method; perimeter bound at three levels).

## Order of work, each piece behind `TOPOPT_STAGE4=<piece>` (unset = today's bytes)

4a:
1. The thin-spot floor at one line for solid parts (`to_export.inc` 26: the stage 3 helper's file; asked 2026-11-27). Measure: test G at 0.45 mm on one part.
2. The optimiser update with m constraints (`plsm_mma.hpp` and the MMA files; mine). Measure: the textbook two-constraint problem reaches its known optimum; with one constraint, the same bytes as today.
3. The sealed-pocket accept rule (`minimize_plastic.cpp`, `plsm_topology.hpp`). Measure: test I on a made cube with a cavity.
4. The member rule in voxels (`part_scale.hpp`). Measure: the stage 2 bending beam reads within 10 % at the resolution the rule picks.
5. Connectivity by roll-back in the loop, then the bridge stamp removed (`plsm.cpp`: after stage 3 is released). Measure: the sample bracket keeps its tab with no bridge.

4b (after stages 3 and 5): 6. the overhang filter; 7. the robust triple and the hole size; 8. the perimeter bound; 9. `thin_spot_cleanup` removed.

## Open questions

For the reviewer: (a) "smallest wall = one line" against "a member needs 8 voxels through to be read": a one-line wall is about one voxel at today's resolutions; either the resolution rises with the thinnest member, or thin walls are a stated limit of the strength number (stage 2's close); (b) the split into 4a and 4b; (c) tests G and I as corrected above.
For the maintainer, later: the overhang angle; who chooses the orientation.
For #362: the plain lines the user sees for a sealed pocket and for "too thin for this resolution".
