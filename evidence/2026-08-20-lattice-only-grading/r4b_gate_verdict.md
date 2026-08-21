# ⚠ SUPERSEDED IN PART — SEE `r4b_PRINT_RESULT.md`
#
# The maintainer PRINTED the graded coupon and it came out clean. The overhang
# gate below is REFUTED BY EXPERIMENT, and with it every conclusion that depended
# on it: the self-supporting-cell requirement, the 4-16x anisotropy, the tetragonal
# tensor and the certification extension. Sections (i) spacing, and the angle
# measurements AS MEASUREMENTS OF THE STRESS FIELD, still stand.

# §4(b) — the two GATE measurements for GRADED, and what they actually say

Measured on the maintainer's own part, `M2_verticalStand.step`, lattice-only,
under his declared load case. Both probes reproduce the production run before
reporting anything: the overhang probe's peak von Mises matches the production
`analyze` run to 9.0e-09 relative, and the spacing probe reproduces
`printability_floor_mm` exactly.

★ THIS FILE WAS REVISED. Its first version concluded "graded is a no-go, and the
reason generalises." That was WRONG, and wrong in a specific way worth recording:
the measurement refutes ONE METHOD — the one §4(c) names — and I wrote it up as
though it refuted the GOAL. The maintainer supplied the counter-example:

  Wang, Feng, Yang, Li & Wang, "Topology optimization of self-supporting lattice
  structure", Additive Manufacturing 67:103507 (2023).
  https://doi.org/10.1016/j.addma.2023.103507

That paper builds self-supporting lattices and validates them experimentally. So
the honest verdict is not "graded cannot be done" but "graded CANNOT BE DONE BY
TRACING, and the published method that works does not trace."

## (i) The printable spacing window at a 0.45 mm nozzle

Computed from core's own strut law (`octet_strut_diameter_mm`), never a second
derivation. A cell/spacing `S` emits a strut `S·phi(rho)`, so `S >= w / phi(rho)`.

| | 0.45 mm nozzle | his stated 0.42 mm |
|---|---|---|
| finest spacing that prints (at `rho_max`) | **1.1732 mm** | 1.0950 mm |
| coarsest spacing forced (at `rho_min`)    | **4.9314 mm** | 4.6026 mm |
| ratio | 4.203x | 4.203x |

Reachable window **1.17 mm – 4.93 mm**. To hold the cells-per-member floor
(N* = 5) those ends need members of 5.87 mm and 24.66 mm. **This gate PASSES.**

## (ii) The fraction of TRACED struts that violate the overhang limit

Eigen-decomposition of the per-voxel stress tensor (deterministic cyclic Jacobi),
RK4 tracing along each principal family, every step scored against the
45-degrees-from-vertical rule. 1,770 seeds, 936,151 traced steps.

| family | traced steps | violating > 45 deg |
|---|---|---|
| MAJOR  (largest abs sigma) | 509,508 | **39.78 %** |
| MIDDLE                     | 345,393 | **94.76 %** |
| MINOR  (smallest abs sigma)|  81,250 | **98.09 %** |
| **all three**              | 936,151 | **65.13 %** |

### Why TRACING specifically fails

The principal directions of a symmetric stress tensor are MUTUALLY ORTHOGONAL, so
at most ONE family can be near-vertical anywhere. His part is a vertical stand
under a downward load: the major family is the vertical compression path (28.2 %
of its arc-length within 10 degrees of vertical), which FORCES the other two into
the horizontal plane. That is the 94.8 % and 98.1 % above — and those two families
are exactly the TRANSVERSE CONNECTIVITY.

You cannot repair this afterwards: tilting a strut to make it printable discards
the stress alignment that was the entire justification for tracing. So the 45-degree
rule must hold DURING tracing, and on this part that leaves about a third of the
arc-length admissible and almost none of the cross-bracing.

**Conclusion for the METHOD in §4(c): refuted, by measurement, with a structural
reason. Do not implement eigen-trace + Jobard-Lefer spacing.**

## ★ WHAT THE MEASUREMENT ACTUALLY IMPLIES — AND THE ROUTE IT OPENS

Read the orthogonality result the other way round and it stops being an obstacle
and becomes a DESIGN RULE:

  ★ A lattice cannot get its printability from ALIGNMENT TO STRESS, because stress
    directions are orthogonal and at most one of three can point up. It must get
    printability from the CELL TOPOLOGY, and then accept some misalignment.

That is precisely what the paper does. Its pipeline is:
  1. start from a coarse lattice whose UNIT CELL is self-supporting by construction;
  2. adaptively SUBDIVIDE it under density-based TO, with subdivision operators
     that PRESERVE the self-supporting property on struts;
  3. FILTER to avoid overhanging nodes;
  4. SIMPLIFY — prune redundant struts subject to a self-supporting constraint.

★ STEP 2 IS WHAT `cell_plan.hpp` ALREADY IS. Our dyadic octree, 2:1 balanced, cells
meeting at shared nodes, level chosen per region from the FEA — that IS adaptive
subdivision of a lattice under a density field. The gap between what we ship after
§4(a) and the paper's method is therefore NOT the subdivision machinery. It is:

  (a) a SELF-SUPPORTING CELL. Our octet is not one: the octahedron's mid-plane
      edges are horizontal. (Unmeasured here — the next measurement to take.)
  (b) an OVERHANGING-NODE filter.
  (c) strut-level pruning under a self-supporting constraint.

## ★ WHY STEPPED IS UNAFFECTED BY THE 65 % NUMBER

A horizontal strut INSIDE a cell spans ONE cell edge — 2 to 16 mm on our ladder —
which FDM bridges routinely. A horizontal segment of a TRACED curve spans however
far the curve runs, which is unbounded. The overhang limit bites on span, and that
is the whole difference between the two methods. §4(a) is not in question.

## Verdict

* gate (i) SPACING: **passes**, 1.17–4.93 mm.
* gate (ii) OVERHANG, for the TRACED method: **fails**, 65.13 %.
* the traced method (§4(c)) is refused on measurement.
* a self-supporting-cell + adaptive-subdivision route is NOT refused, is published
  and experimentally validated, and is ADJACENT to the dyadic ladder we already
  own. It is the version of "graded" worth scoping.

MEASUREMENT NOT YET TAKEN, and the one that should gate any next step: the angle
distribution of our OWN octet cell's struts, which decides whether (a) is a cell
swap or a cell redesign.

---

## (iii) MEASUREMENT TAKEN — is OUR octet self-supporting? (`r4b_iii_...txt`)

Exact geometry from `lattice_gen.cpp`'s own `ref_nodes()` / `ref_struts()`. No
sampling, no FEA.

| angle from vertical | struts | |
|---|---|---|
| exactly 45 deg | 24 / 36 (66.7 %) | ON the limit, zero margin |
| exactly 90 deg | **12 / 36 (33.3 %)** | **HORIZONTAL** |

**Our octet is NOT self-supporting.** A third of every cell is horizontal.

### And rotation cannot rescue it

The 36 struts reduce to **6 distinct unsigned directions** — the FCC face
diagonals. Swept over 200,000 build directions, the best achievable worst-case
strut angle is **71.63 deg**, against a 45 deg limit, and 5 of the 6 direction
classes still violate at that optimum. Six directions spread that widely simply do
not fit inside a 45 deg cone about any axis.

**So route item (a) is a CELL REDESIGN, not a cell rotation, and not a build-
orientation choice.** That is the single biggest cost item in scoping the paper's
method, and it is now a proven fact rather than an estimate.

### Why STEPPED still ships regardless

Those 12 horizontal struts span ONE cell edge — 2 to 16 mm on our ladder — which
FDM bridges routinely, and which is why the lattice we already ship prints at all.
The overhang limit bites on SPAN, and a traced curve's horizontal run is unbounded
while a cell edge's is not. §4(a) is unaffected.

---

## (iv) WHICH CELL WOULD WORK? (measured)

The constraint is one inequality. For a strut direction `(a,b,c)` to lie within
45 deg of the build axis, `|c|/||d|| >= cos45`, i.e.

    ★  c^2 >= a^2 + b^2   — the vertical component must dominate the horizontal.

### Every classical cubic cell fails, in two distinct ways

| cell | worst strut | why |
|---|---|---|
| OCTET (ours), FCC, Kelvin | **90.00 deg** | the `<110>` family contains HORIZONTAL members |
| BCC, BCC-Z, cubic diamond | **54.74 deg** | the `<111>` family is 54.74 deg, and BCC-Z's vertical columns do not rescue the BCC struts |

### The family that works: cells STRETCHED along the build axis

An "X-lattice" — nodes on a square grid of pitch `P`, each braced to the four
diagonal neighbours ONE layer up, strut direction `(+-1, +-1, k)` with
`k = layer height / P`:

| k | worst strut | self-supporting | C33/C11 |
|---|---|---|---|
| 1.000 | 54.74 deg | no | 1.0 |
| **sqrt(2) = 1.4142** | **45.00 deg** | **exactly on the limit** | **4.0** |
| 1.600 | 41.47 deg | yes, +3.5 deg | 6.6 |
| **2.000** | **35.26 deg** | **yes, +9.7 deg margin** | **16.0** |
| 3.000 | 25.24 deg | yes, +19.8 deg | 81.0 |

Equivalently as a pyramid (square base `L`, apex at centre, height `h`):
`h/L >= 1/sqrt(2) = 0.7071` is the threshold; `h/L = 1` gives the same 35.26 deg.

**Minimum: `k >= sqrt(2)`. For a 10 deg print margin: `k ~ 2`.**

### ★ THE COST, AND IT IS NOT THE CELL GEOMETRY

Self-support forces the cell to be TALLER THAN IT IS WIDE, so it is no longer
cubic. First-order axial truss estimate of the anisotropy (our shipped tensors are
MEASURED — this indicates direction and order, it does not replace them):

* our octet is transversely BALANCED, `C33/C11 = 1.00`. It is cubic.
* every self-supporting cell is not: **4x** stiffer along Z than across at the bare
  `k = sqrt(2)` threshold, **16x** at a comfortable print margin.
* adding vertical columns raises `C33` and leaves `C11` alone, so it makes the
  anisotropy WORSE. There is no way to buy transverse stiffness back: transverse
  stiffness comes from horizontal material, and horizontal material is precisely
  what cannot be printed. The 4x is a FLOOR, not a tuning choice.

### What that breaks in this codebase

1. `cell_plan.hpp` states the certification library carries **exactly one CUBIC
   tensor per topology**. A self-supporting cell is tetragonal at best — 6 elastic
   constants, not 3 — so certification must be extended before such a cell can be
   emitted at all. This is the largest cost item, and it is a CERTIFICATION change,
   not a geometry change.
2. The tensor becomes a function of `(rho, k)`, not `rho` alone: the aspect ratio
   is a new axis the measured library must cover.
3. `cells_per_member` becomes DIRECTION-DEPENDENT — the cell no longer has one
   extent.
4. ★ BUILD DIRECTION BECOMES STRUCTURAL. Today it enters only through
   `max_interlayer`, which is why one solved field prices every orientation
   (analyze.hpp says so explicitly). With a z-stretched cell the CELL ITSELF is
   defined relative to the build axis, so changing orientation changes the lattice
   and invalidates that one-solve-prices-all property.

### What SURVIVES unchanged — and it is the expensive machinery

Dyadic subdivision still works. Scaling a stretched cell by 2 preserves its aspect
ratio, so coarse nodes still nest in the fine grid and 2:1 neighbours still meet at
shared nodes. `cell_plan.hpp`'s octree, its balancing, and its per-level reporting
all transfer. The paper's step 2 is machinery we already own.
