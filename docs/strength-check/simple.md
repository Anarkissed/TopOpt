## What the check does

When you make a Structural lattice file, the computer tests whether the part, with its lattice exactly as printed, can carry your load. It runs on the Mac after the file is made. Aesthetic lattices are never checked. A few numbers in it were picked by us rather than measured; each is shown with its value, and those can be changed in Settings.

## The part, loads, supports and material

It uses your part, your loads, your supports and your material. Bolts can be glued (hold every way) or only push back. If you set several load scenarios, each is tested and the worst one counts.

## The safety margin

The part must carry your load times the safety margin, now {{safety_margin}}. It can't go below {{safety_margin_floor}}.

## The small cubes

The part is cut into small cubes, {{resolution}} along its longest side. More cubes give a sharper answer and take longer.

## Which cells count

A cube is lattice when its centre sits inside a lattice cell. Each cell's density comes from its size and strut width. Some cells count as empty, to stay on the safe side:
- cells the part's surface cuts through;
- cells that lost a strut the file left out;
- cells too light or too dense for our measurements.

Everything else counts as solid.

## The computer model

The computer works out how every cube stretches under the load. Solid cubes have the plastic's stiffness. Lattice cubes have a measured, softer stiffness for their type and density.

## Is the load connected

The load must reach the supports through material that counts. If it doesn't, the part fails, however strong the rest is.

## The solid's margin

For the solid parts, the strength of the plastic is compared with the highest stress. Layers bond weaker than the plastic itself, so stress pulling layers apart is judged against {{z_knockdown}} of the strength. Infill under 100 % lowers this margin.

## The struts' margin

A lattice cube only shows a smeared stress. Measured tables turn it into the peak stress in the struts, which is much higher. That gives the struts' margin. For the octet, the table was measured on 17 November 2026 on the octet cell we actually print. Its lightest row was measured only inside the lattice, so octet cells lighter than 10 % of solid can't give the struts a pass; the result says so.

## Too few cells across

The lattice model holds only when a member is at least {{cells_per_member_min}} cells across. Thinner, the strut numbers are only a guide.

## The verdict

- **Pass:** the load is connected, and both the solid and the struts keep the safety margin.
- **Solid passes, struts don't:** the solid is fine, but the struts fall short of the safety margin, or the type has no strut rule (BCCZ, FCCZ, re-entrant). The struts' margin is shown.
- **Fail:** the load has no path to the supports, or the solid falls short. It says which, and how much load lands on lattice that counts as empty.

The file is made in every case. If the check can't run, no file is made and it says why.

## Organic: the frame of beams

An Organic lattice has no cells, so it is checked another way: as a frame of round beams, one for each strut, exactly as the file holds them.

First the whole part is cut into small cubes and each cube is read at {{frame_material_subdiv}} points along each edge: how much of it is your solid, and how much is strut. The computer works out how every cube moves under your load. A cube with nothing in it keeps {{frame_void_floor}} of the plastic's stiffness.

Then the struts are joined where their ends meet (ends closer than {{frame_node_weld_mm}} mm are one joint), and a strut that stops on the middle of another is joined there ({{frame_tjoin_off_line_mm}} mm). A joint inside the solid moves as the solid around it moves: the average of the material cubes within {{frame_drive_ball_voxels}} cubes of it that are at least {{frame_drive_share}} full. Where your load lands, the share carried by lattice (rather than solid) is worked out over the whole loaded area; that share of the whole load is shared equally among the strut joints near any loaded point. If that share is more than {{load_unheld_share}} and no strut joint is near the loaded area at all, the part fails: the load is on open lattice.

The short joiners where two strands cross (links) are made {{frame_link_stiffness}} times stiffer than a strut of their size, so the two strands move as one. A link is never judged.

Each strut, from one real joint to the next, is judged at both ends of every piece: pulling, pushing and bending together. Pulling across the layers is judged against the weaker across-layer strength, by its slope; level struts get the full strength. A strut being pushed is also judged for buckling, as if pinned at its ends. Its margin is the smallest of these. A piece shorter than {{frame_min_piece}} times its width does not count for the stress, and a strut shorter than it is wide gets no margin.

The verdict: **pass** when the solid passes and no strut is under the safety margin; **fail** when the solid fails, the load is on open lattice, or a strut is under the safety margin; **solid only** when the solid passes but the frame could not be solved (in {{frame_solve_memory_gb}} GB) or more than {{frame_unjudged_share}} of the strut length is in pieces that touch no solid. The {{frame_weakest}} weakest struts are listed, and every strut's margin is written beside the file.

## Organic: strengthen

The strengthen job checks the lattice, then lays it again where it was weak, and checks again, up to {{strengthen_rounds}} times (0 means 2 for Traced and 3 for Grown). It stops as soon as nothing is under the safety margin.

In each round, every strut with a margin under {{strengthen_watch_margin}} raises the stress the lattice is laid from, within {{strengthen_reach}} times the weave's mean spacing of it, by up to {{strengthen_boost_max}} times (more for a weaker strut, by the power {{strengthen_boost_power}}), so the next lay puts more, wider struts there. It also sets a least width there (over the same reach), aimed at a margin of {{strengthen_target_margin}}, never wider than your own widest strut. Your own files are never changed: each round writes its own copy.

If nothing in the job follows the stress (one spacing, one strut width), there is nothing to vary, and the job says so after the first check.

## What it does not cover

- Struts that buckle, wear out from repeated loads, or creep.
- Print flaws, layer gaps and supports left on.
- Heat, sunlight and moisture.
- Bolt friction, and cracks starting at sharp corners.
- How tough the material is: we use one strength value per material.
- Every strut individually: we use measured averages per cell.
