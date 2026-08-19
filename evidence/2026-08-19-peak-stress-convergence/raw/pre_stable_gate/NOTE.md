# The second pass: the distance gate measured on each solve grid

These nine runs are S1 as first measured — same design, same replicate
construction, same three arms, same three rungs — with one difference: the
distance gate that isolates the CUT population from the voxel-specified pads was
a chamfer computed **on each solve grid** rather than on the base grid.

They are kept because they are what forced the change, and because every other
number in them (the global peak, the FROZEN peak, the volumes, the margins, the
compliance control) is reproduced exactly by the top-level `s1_replicate.csv` —
only the four gated columns move.

**What was wrong with it.** A chamfer computed per grid is quantised to that
grid's own `h`, so the gate's band EDGE moves by O(h) between rungs. Where the
stress gradient across that edge is steep — and on this part it is, because the
load is introduced through the pads — the gated peak inherits the movement. The
symptom was unmistakable once the three gates were read together, on the `frac`
arm:

| gate | q | R^2 | spread |
|---|---|---|---|
| CUT >5 mm  | −0.0331 | 0.219 | 7.7 % |
| **CUT >10 mm** | **+1.4834** | **0.983** | **101 %** |
| CUT >20 mm | +0.0058 | 0.020 | 4.5 % |

An exponent of +1.48 sandwiched between two flat ones is not a physical rate —
+1.48 is steeper than any corner singularity in two or three dimensions, and the
5 mm gate's population CONTAINS the 10 mm gate's. It is the band edge sweeping
across a steep gradient: 63 → 220 → 455 cut cells at 10 mm, admitting cells at
each rung that the coarser chamfer had placed just outside.

**The fix** is to compute the distance field on the BASE grid and read it through
the parent index, so the gate is the same physical region at every rung to the
base grid's own voxel. That is what the top-level results use.

★ It is written down rather than quietly corrected because the failure mode is
general: *any* post-hoc spatial filter re-derived per rung is itself a function
of `h`, and a convergence study that filters its population per rung is measuring
the filter as well as the physics.
