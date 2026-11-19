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

For the solid parts, the strength of the plastic is compared with the highest stress. Layers bond weaker than the plastic itself, so stress pulling layers apart is judged against {{z_knockdown}} of the strength. Infill under 100 % lowers this margin. With {{width_aware_knockdown}} on (the default), the solid within the printed wall thickness of a surface counts at full strength, and only the inside takes the infill reduction.

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

Then the struts are joined where their ends meet (ends closer than {{frame_node_weld_mm}} mm are one joint), and a strut that stops on the middle of another is joined there ({{frame_tjoin_off_line_mm}} mm). A joint inside the solid moves as the solid around it moves: the average of the material cubes within {{frame_drive_ball_voxels}} cubes of it that are at least {{frame_drive_share}} full (a joint on the solid floor laid on the bed reads it {{frame_floor_shift_voxels}} cubes higher, and with "{{frame_floor_free}}" on it is not held at all). A joint just outside the small cubes of the solid (the cubes are coarser than the part's own surface) never takes the stillness of empty space: it looks further, up to {{frame_drive_reach_voxels}} cubes, for the solid it belongs to, and if there is none it is left free; the result counts how each joint was moved. Where your load lands, the share carried by lattice (rather than solid) is worked out over the whole loaded area; that share of the whole load is shared equally among the strut joints near any loaded point. If that share is more than {{load_unheld_share}} and no strut joint is near the loaded area at all, the part fails: the load is on open lattice.

The short joiners where two strands cross (links) are made {{frame_link_stiffness}} times stiffer than a strut of their size, so the two strands move as one. A link is never judged.

Each strut, from one real joint to the next, is judged at both ends of every piece: pulling, pushing and bending together. Pulling across the layers is judged against the weaker across-layer strength, by its slope; level struts get the full strength. A strut being pushed is also judged for buckling, as if pinned at its ends. Its margin is the smallest of these. A piece shorter than {{frame_min_piece}} times its width does not count for the stress, and a strut shorter than it is wide gets no margin.

The solid is judged by its stress alone, in the cubes that are at least {{printed_threshold}} solid; the lattice's cubes are the frame's to judge. Whether the load has a path is judged on the frame: if a strut joint near your load is on a group of struts that touches no solid, the part fails (no load path). The verdict: **pass** when the solid passes and no strut is under the safety margin; **fail** when the solid fails, the load has no path, the load is on open lattice, or a strut is under the safety margin; **solid only** when the solid passes but the frame could not be solved (in {{frame_solve_memory_gb}} GB) or more than {{frame_unjudged_share}} of the strut length is in pieces that touch no solid. The {{frame_weakest}} weakest struts are listed, and every strut's margin is written beside the file.

## Organic: strengthen

The strengthen job checks the lattice, then lays it again where it was weak, and checks again, up to {{strengthen_rounds}} times (0 means six when it strengthens by adding, and 2 for Traced and 3 for Grown when it lays the lattice again). It stops as soon as nothing is under the safety margin.

In each round, every strut with a margin under {{strengthen_watch_margin}} raises the stress the lattice is laid from, within {{strengthen_reach}} times the weave's mean spacing of it, by up to {{strengthen_boost_max}} times (more for a weaker strut, by the power {{strengthen_boost_power}}), so the next lay puts more, wider struts there. It also sets a least width there (over the same reach), aimed at a margin of {{strengthen_target_margin}}, never wider than your own widest strut. Your own files are never changed: each round writes its own copy.

If nothing in the job follows the stress (one spacing, one strut width), there is nothing to vary, and the job says so after the first check.


In the Add mode ({{strengthen_mode}} 0, the default) the lattice is laid once and never laid again: nothing that is there is moved or removed. Each round widens every strut under {{strengthen_watch_margin}} where it stands, by how short it falls of {{strengthen_target_margin}}: a strut mostly pulled or pushed by (aim / margin) to the power 1 / {{strengthen_power_axial}}, a strut mostly bent by the power 1 / {{strengthen_power_bending}}, never thinner and never past {{strengthen_width_cap}} times your widest strut width. A strut that buckles gets braces from rule T's brace maker, enough of them that its free length can carry the aim at its width; only where a brace cannot be placed is it widened instead (power 1 / {{strengthen_power_buckling}}). What a round added is saved as a list, with a check number of the whole lattice after each round; the file job and the preview lay your lattice again and add the list, and refuse if the lattice they reach is not exactly the one the rounds were made on. In the Lay again mode ({{strengthen_mode}} 1) each round works as described above.

The strengthen job judges exactly the struts that the file will hold: after laying the lattice, and after each round of additions, it runs the same print check the file runs (lifting or propping sagging struts, leaving out struts that would start in mid-air, adding posts), without writing a file. The file and the preview replay the rounds the same way. If the print check after a round moves or leaves out a strut that was there before that round, strengthening goes on and each round says how many struts it left out, moved and added, and where. Overhangs of your part's own solid are the slicer's business: the check counts them and never props them.

## Organic: the solid's weak areas

When the solid part does not certify, the check says where. Every small cube of the solid that the verdict judges gets its own margin, worked out exactly as the verdict works out the solid's (the infill reduction as set, the walls counted or not as set). The cubes under the safety margin that touch each other make one weak area. Up to {{solid_spots_max}} of them are listed, the worst first, and marked on the part.

For each area you are told where its worst cube is, where its middle is and how big it is; its margin before and after the infill reduction; whether it fails along the layers or across them; the infill at which this area alone would certify; whether counting the printed walls as solid would certify it; and how far it is from the nearest fixing, the nearest place the load presses and the nearest open lattice. An area whose worst cube is within {{solid_spot_near_voxels}} cubes of a fixing is beside a fixing, then of the load, then of the lattice; otherwise it is inside the solid. Each kind has one piece of advice: keep more solid round the fixing; keep more solid where the load presses; keep the lattice further away (a deeper protected skin, or a keep-clear area); or make that part of the model thicker, or print it denser.

The result then says, in plain words, the infill at which the solid would certify (or that even printed solid it would not) and that the other way is to strengthen the marked areas. The margin of every judged cube is written beside the file, so the app can colour the weak places.

## What it does not cover

- Struts that buckle, wear out from repeated loads, or creep.
- Print flaws, layer gaps and supports left on.
- Heat, sunlight and moisture.
- Bolt friction, and cracks starting at sharp corners.
- How tough the material is: we use one strength value per material.
- Every strut individually: we use measured averages per cell.
