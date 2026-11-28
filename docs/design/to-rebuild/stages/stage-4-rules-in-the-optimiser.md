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

## Results

### 4a piece 1, `TOPOPT_STAGE4=wall`: a solid part's smallest wall is ONE line (2026-11-28 02:25; the 15 mm sample bracket, res 48, 0.45 mm line; built and run outside the lock)

| version | unset (floor 0.9 mm = 2 lines): thin spots fixed / left; grams before -> after | `wall` (floor 0.45 mm = 1 line) |
|---|---|---|
| 0.68 | 1 / 2 left; 0.5777 -> 0.5833 | 3 / 0 left; 0.5777 -> 0.5788 |
| 0.52 | 3 / 1 left; 0.4807 -> 0.4847 | 1 / 0 left; 0.4807 -> 0.4816 |
| 0.38 | 1 / 2 left; 0.3952 -> 0.4022 | 4 / 0 left; 0.3952 -> 0.3957 |
| 0.26 | 0 / 2 left; 0.3219 -> 0.3334 | 2 / 0 left; 0.3219 -> 0.3239 |

With the two-line floor every version is left with one or two thin spots the finish cannot thicken ("would grow outside your part": the spot is 0.31 mm and would have to reach 0.9); with the one-line floor every thin spot is brought to 0.45 mm and NONE is left, and the finish adds a fifth to a tenth of the plastic it added before. Margins are unchanged to the third digit; four versions accepted both ways. UNSET: the four files are the same bytes as today. Test G reads 0.45 mm for a solid part from here. The lattice's two-line rule is not touched (this floor is the solid body's finish).

### 4a piece 2: the optimiser's update holds m constraints (2026-11-28 03:15; `plsm_mma_update_m` in `plsm_mma.hpp`, beside the untouched one-constraint function; new test `to_stage4_mma`; a builder's code, two builds)

Today's update (`plsm_mma_update`): Svanberg's asymptotes and approximation, ONE constraint whose dual is solved by bisection. The new entry point takes m constraint values and gradients. With m = 1 it DELEGATES to today's function (bit-identical: checked on four seeds, n = 50 and 500, five iterations); with more it solves the m-dimensional dual by projected Newton with active sets and a line search, with Svanberg's artificial variables so an infeasible start still has an answer. The optimiser's loop (`plsm.cpp`, the stage 3 helper's file) is NOT changed: nothing calls the new entry point yet.

| check | result |
|---|---|
| m = 1 against today's function | the same bits (delegated); the new solver itself at m = 1 is within 5e-9 of the range |
| Svanberg's cantilever (one constraint; known optimum 1.340) | 1.33996 at iteration 5 |
| a two-constraint problem with both active (optimum derived in the test) | reached at iteration 3; multipliers 2.0000 and 4.0000 as derived |
| the same with one constraint made slack | its multiplier exactly 0; the one-constraint optimum |
| three constraints, infeasible start | violation 0.25 -> 0.126 -> 0.0025 -> 0; feasible from iteration 3 |

Not tested: nearly dependent constraints; constraints not scaled to about 1 (the artificial cost assumes it). The rules of pieces 3 to 8 plug in here; the call from the loop waits for stage 3's release.

### 4a piece 3, `TOPOPT_STAGE4=pocket`: the sealed-pocket rule (2026-11-28 03:45; a builder's code; one build; unit test `to_stage4_pocket`; NOT yet seen in a real run)

Today: `plsm_void_topology` counts sealed pockets (void walked face to face; the outside is the grid's boundary); only the FIRST version's count reaches the report; a solid version with a sealed pocket is accepted silently; a lattice is refused only when lattice cells sit inside the sealed pocket, with a long technical line.
Under the switch: every SOLID version with pockets carries `"sealed_pockets": {"count", "volume_mm3", "largest_mm3"}` in the report and one stderr line (`[pocket] version vf 0.xx: N sealed pocket(s), V mm3 in all (allowed in a solid part)`); the lattice refusal leads with the plain line "A sealed pocket has no way out", the old text kept as detail. The on-screen wording is #362's.
Detection checked on a made 24^3 cube: no cavity 0; one 4^3 cavity 1 (8.000 mm3); the same with a one-voxel channel out 0; two cavities 2, largest reported; a cavity that meets the way out only at an EDGE or a CORNER of voxels still counts as sealed (face-to-face is the rule in the code's own comments; a printed diagonal contact is not a drain).
OPEN: (1) a sealed pocket in a lattice job with NO lattice cell inside it is accepted today and still is: his decision says a lattice refuses; for the reviewer / LatticeReview; (2) the `lattice_variant` job type throws the old text from `run_job.cpp` (#362's file); (3) multiscale and frozen-lattice jobs: nothing told, not checked; (4) to run once in a real job with the switch off (the same report bytes) and on.

### Rulings and decisions, 2026-11-28

THE REVIEWER, 08:23Z, maintainer-approved (in short; the full text is in the channel): (a) the one-line wall (0.45 mm) is his printability floor and stands; the resolution does NOT chase it (8 voxels through 0.45 mm is a 0.056 mm voxel); A-06's planned answer is section-force stress once it passes the statically indeterminate test: keep that FIRST in 4a's measuring; until then a thin load-bearing member is a stated limit named in the readout; NO readability floor in voxels on the optimiser's own members without his word (if he asks: measure what a 6-voxel floor costs in grams and margin on his two parts); the long-run answer is "keep going finer" plus the hot-spot box. (b) the 4a / 4b split agreed; one piece at a time. (c) tests G and I as corrected agreed. (d) a sealed pocket with no lattice cell in a lattice job: reported, not refused; put to him.
THE MAINTAINER, the same morning, asked the literal question: "I think just reported - unless there is a technical reason it should be refused?" There is none for filament printing (the pocket's roof is the overhang rule's matter, stage 4b). DECIDED: reported. That is what piece 3 does.

### 4a piece 3 seen in a real run (2026-11-28): the 15 mm bracket has no sealed pocket; the runs with the switch unset and on are the same bytes (four files and report.json), and unset matches today.

### 4a piece 4 as a NOTICE, `TOPOPT_STAGE4=member` (2026-11-28; a builder's code; unit checks in `to_part_scale`; one real run)

`thin_member(...)` in `part_scale.hpp`, on the same member-width measure the thin-member rule reads. Per accepted version, when the thinnest member is under 8 voxels through: report block `"thin_member": {"thinnest_mm", "voxels_through", "resolved", "resolution_needed"}` and one stderr line. It changes nothing else: not the resolution, not the verdict (the ruling above). On the 15 mm bracket at res 48 every version reads: thinnest 0.625 mm = 2 voxels through; resolution 192 would resolve it. Unset: today's bytes; on: the same four files, the block added.
LIMITS OF THE NOTICE: the width measure reads even voxel counts only (3 through reads 4; 7 would read 8 and pass); and it names the thinnest member anywhere, which here is probably the finish's own wall floor, not necessarily a member that carries load. To be useful in the readout it must name thin members that are LOADED (a later step, with the section-force reading).

### Section-force stress on a STATICALLY INDETERMINATE case (the reviewer's first item for 4a's measuring); 2026-11-28 05:00; print-only rows in `to_strength_cut_skin`

Two parallel members, 2.5 and 6.5 voxels thick (cut faces off the voxel boundaries, real stiffness), joined by stiff end blocks and SHARING the load; each cut at mid-span. Percent against the same assembly 4 x finer (835 000 voxels):

| case, member | section forces, the section from the MODEL'S OWN fills | section forces, the true section handed in | the per-voxel peak | the surface carry |
|---|---|---|---|---|
| tension, 2.5 voxels | +0.0 | +1.1 | -1.4 | +0.0 |
| tension, 6.5 voxels | +0.1 | +1.4 | -2.0 | -0.1 |
| bending, 2.5 voxels | +0.4 | +5.1 | -6.6 | +0.0 |
| bending, 6.5 voxels | +0.1 | +2.9 | -4.7 | -0.6 |

The load SHARE between the members is right at the base grid (member 1 carries 0.382 of the tension against 0.383 at 4 x; axial forces within 0.5 %). Each member's own bending moment about the TRUE centroid is not (the thin member's +48 %): the coarse model's stiffness centre sits elsewhere; taking the section from the model's own fills removes it, and then the reading is within 0.4 % at 2.5 voxels through. So section-force stress with the model's own section HOLDS THE BAR on this indeterminate case, where the per-voxel peak is 1 to 7 % low. (The surface carry also holds here, within 0.6 %: these members are straight.) Still to do before it can be the reading under 8 voxels through: FINDING the members and their cut planes on a general shape (a skeleton), and a member that is curved or tapers.

### 4a piece 5, first half: the load-path check as a standalone function (2026-11-28 04:55; `load_path.hpp`, header-only; test `to_stage4_load_path`; a builder's code; not yet called from the loop, which is the stage 3 helper's file)

`load_path_check(grid, density, threshold 0.5, with_thinnest_link, connectivity 26)`: one flood fill from the anchors; a load group that reaches no anchor is unheld. It follows the rule the code already has (`voxel.hpp` 535 to 573; `walk_load_path`): printed = tag not Empty and density above 0.5, Load and Fixture voxels included; neighbours by face, EDGE or CORNER (26), on purpose: voxels that touch at a corner share a node and pass force; a Load voxel carved away counts as a broken path. Also a cheap "how near to breaking" measure: 1, 2 or 3 = the path survives no, one or two one-voxel erosions.
Checks (10 pass): a solid bar connected; a bar cut through: 1 unheld group, the stranded voxels counted; two arms, one cut: 2 groups, 1 unheld; two halves meeting only along an edge: connected at 26 and 18 neighbours, not at 6; necks of 1 x 1, 3 x 3 and a full section read 1, 2, 3. Time on 128 x 128 x 64: 22 ms, with or without the link measure: cheap enough for every iteration.

