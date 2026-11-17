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

## What it does not cover

- Struts that buckle, wear out from repeated loads, or creep.
- Print flaws, layer gaps and supports left on.
- Heat, sunlight and moisture.
- Bolt friction, and cracks starting at sharp corners.
- How tough the material is: we use one strength value per material.
- Every strut individually: we use measured averages per cell.
