# Handoff: 2026-10-25-topology-core-bolts (TO-core, core only)

Agent: TO-core. Reviewer: "reviewer" on agent-comms #TO-core; #362 on #CoreGroup owns the solver files.
Branch: `claude/topology-core-bolts`, made from `origin/claude/flexible-screens` at `322b1c78` (the solver cure
included), plus a docs-only merge of `origin/claude/topology-core`. Merge only, never force.

## The item: REAL BOLTS (the reviewer's brief of 2026-10-25 20:10, approved by him)

Anchored holes were glued rigid. The stress at a glued edge is infinite in theory, so the margin fell as the grid
refined (his Carriage Arms: 3.94 / 3.94 / 2.84 / 2.48 at res 48 / 64 / 96 / 128). Now, behind the job key
`loads.anchor_model: "bearing"` (absent or "glued" = today's clamp, byte for byte):

- Every anchor (a bore or a flat face) holds only where the part PRESSES on it: a penalty spring along the CAD normal
  at each node of the anchor's voxel surface, compression-only.
- Stiffness: a Winkler support of steel, E 200 GPa acting through 1 mm, per mm² of the node's TRUE area. That area is
  the node's share of the anchor's exposed voxel faces, divided by the staircase factor |n|₁, so the total is the
  face's CAD area and an edge row gets half. It is fixed in mm, so it doesn't stiffen toward a clamp as h shrinks.
- Across the normal, a pressing node has 1e-4 of that per-area stiffness (nearly frictionless; see "The stick ruling").
  A released node has nothing at all.
- The contact set: solve, release the springs in tension, re-engage the ones pressing again, re-solve. A hysteresis
  band of 1e-3 × the largest |u·n| stops the contact edge from chattering. The certification runs at most 6 solves
  and reports the count; the optimizers (both simp_optimize loops and PLSM) re-read the set every 10 iterations.

### The seam (agreed with #362, 20:18; approved by the reviewer, 20:37)

A spring travels in the existing `bcs` vector: `DirichletBC` grew trailing defaulted fields (`spring`,
`spring_tangent`, `spring_tangent_rel`, `normal`, `released`). An entry with `spring > 0` is NOT a constraint, so no
solver signature changed. The springs enter:
- the assembled K (`add_contact_springs`, both `assemble_reduced` paths); the cached `PenalizedSolver` declines spring
  systems and falls back;
- the matrix-free matvec (FP64 and FP32), its diagonal, the λ probe (`UncountedFineApply`), the level-1 Galerkin
  product (Pᵀ S P), the point-block and l1 smoothers;
- the coarse warm start (`coarsen_bcs`) and the design-box remap carry them.

### #362's six conditions

1. A contact-set change drops the caches built on the old operator: the Krylov recycling space, the GenEO basis and
   the safe retry's consecutive-failure count (`fea_matfree_reset_mg_safe_failures`; the latch keeps its rule). The
   Galerkin block cache lives inside one A1 build, and the springs are added after the element pass, so it needs
   nothing. Test: `test_bearing` (c), a set change mid-run with recycling on gives the cold solve's field exactly.
2. Released springs aren't anchors: `scan_islands` skips them. A release that would leave no spring engaged is not
   applied (`ContactUpdate::kept_last`, reported). Preflight reads voxel tags before any solve, when nothing is
   released yet.
3. Tangential stiffness: see "The stick ruling".
4. The l1 smoother adds the springs' absolute row sums, so λ_max(D_l1⁻¹A) ≤ 1 by construction. Test:
   `test_mg_safe_retry` S3 + springs, λ 0.9990 / 0.9533.
5. Bit-identity: see "Bit-identity".
6. An unsettled certification is reported in report.json (`"bearing": {"contact_rounds", "settled", "engaged",
   "released", "load_share", "kept_last"}`, only when bearing ran) and on the CLI's line.

## Findings while building (each measured on the committed plate with a bore, 100 N side pull)

- Stabilisation tied to the node's diagonal (#362's first sizing): its stiffness per mm² grows as E/h, so at fine grids
  it clamps the released half. The peak went there and grew from 9.0 to 14.8 MPa between res 48 and 96.
- Any stiffness on the released half acts as glue: the steel barely compresses (~2e-5 mm), while the half pulling away
  moves by the part's own stretch (~1e-3 mm). An isotropic 1e-3 per-area stabilisation carried 23–44% of the load.
- Equal stiffness per node over-stiffened the bore's edge rows, which have half the area, and drew the load to the top
  and bottom edges. Area weighting fixed it: 7.53 / 6.48 / 6.50 at res 48 / 64 / 96, with the peak in the bearing zone.
- Without the hysteresis band, his arms' contact set was still changing after 6 solves (chatter).

## The stick ruling (20:37) and why it is pending

The reviewer ruled a STICK spring on engaged contacts, sized from the node's element stiffness. Measured on the plate,
any linear stick stiff enough to hold the part makes the stuck / released boundary a new singular edge:

| tangential | res 48 / 64 / 96 (/ 128) | 64 → 96 |
|---|---|---|
| 1e-4 per mm² (nearly frictionless) | 7.53 / 6.48 / 6.50 | +0.4 % |
| 1 × diagonal | 6.70 / 4.67 / 4.24 | −9 % |
| 0.1 × diagonal | 7.88 / 6.39 / 5.27 | −17.5 % |
| 0.01 × diagonal | 8.14 / 7.50 / 7.08 | −5.5 % |
| 1 / 0.3 / 0.1 × the normal, per mm² | 6.32 → 3.12, 6.51 → 3.56, 6.79 → 4.05 (48 → 128) | — |

Asked on #CoreGroup (20:48): (A) nearly frictionless (recommended for this batch), (B) the ruled stick at 0.01 ×
diagonal, or (C) Coulomb stick-slip (stick up to μ × pressure; a third contact state, a separate batch). The solver
supports both forms of tangent (`spring_tangent` N/mm + `spring_tangent_rel` × diagonal), so (A) or (B) only changes
the load case's constant.

## The bar: his Carriage Arms (copy 4), bearing (nearly frictionless), res 48 / 64 / 96 / 128

Margin = the certification's margin_effective (knockdown 0.354 at 50 % infill). PA12-CF: Y 60 MPa, z_knockdown 0.4.
The glued column is the morning's measurement (`~/dev/TopOpt/reviewer-inbox/2026-10-25-singularity/`, a pre-cure
build). Re-run glued on this branch at res 48, it matched exactly (3.939 / 7.165).

| res | h mm | what | margin (bearing) | margin (glued) | VM peak MPa @ (x, y, z), at an anchor? | σzz peak MPa @ (x, y, z) | governs | solves (settled?) | s |
|---|---|---|---|---|---|---|---|---|---|
| 48 | 2.549 | as drawn | 2.423 | 3.939 | 5.45 @ (19.1, 50.4, 133.6) yes | 3.50 @ (16.6, 55.5, 136.1) | σzz | 6 (no) | 16 |
| 48 | 2.549 | box filled | 3.875 | 7.165 | 2.92 @ (16.6, 50.4, 103.0) yes | 2.19 @ (16.6, 55.5, 136.1) | σzz | 6 (no) | 21 |
| 64 | 1.912 | as drawn | 1.922 | 3.940 | 7.78 @ (−16.2, 48.1, 103.9) yes | 4.42 @ (16.2, 55.8, 138.3) | σzz | 6 (no) | 28 |
| 64 | 1.912 | box filled | 3.170 | 8.054 | 6.05 @ (16.2, 48.1, 103.9) yes | 2.68 @ (16.2, 55.8, 138.3) | σzz | 6 (no) | 57 |
| 96 | 1.274 | as drawn | 1.779 | 2.844 | 7.80 @ (17.2, 49.7, 132.9) yes | 4.77 @ (−17.2, 56.1, 138.0) | σzz | 6 (no) | 131 |
| 96 | 1.274 | box filled | 2.837 | 5.209 | 4.98 @ (15.9, 48.4, 103.6) yes | 2.99 @ (−17.2, 56.1, 138.0) | σzz | 6 (no) | 381 |
| 128 | 0.956 | as drawn | 1.274 | 2.481 | 9.80 @ (17.7, 48.6, 134.0) yes | 6.66 @ (17.7, 56.3, 136.9) | σzz | 6 (no) | 334 |
| 128 | 0.956 | box filled | 1.868 | 3.196 | 7.32 @ (16.7, 48.6, 103.4) yes | 4.54 @ (−17.7, 56.3, 136.9) | σzz | 6 (no) | 539 |

- FAIL against the bar: from res 96 to 128 the margin changes −28 % (as drawn) and −34 % (box), and the VM peak still
  sits at an anchor's edge.
- What drives it: at every resolution the margin is set by INTERLAYER tension (zk·Y/σzz < Y/vm), not by the von
  Mises peak. The σzz peak is at one outer corner of each arm, about (±17, 56, 137) mm. There faces 130 (normal +y),
  104 (the top, +z) and 112 (+x) meet through a small curved blend (129, or 141 on the mirror arm). It touches no
  anchor and no load. It grows 3.50 → 6.66 MPa (as drawn) from res 48 to 128: a sharp-corner effect the grid keeps
  resolving. Glued is governed by the same corner in the box at fine grids. Bearing raises the stress there, because
  frictionless pins let the arms bend more, so bearing margins are LOWER than glued (as drawn at 128: 1.27 vs 2.48).
- The VM peak (not governing) is at the mouth of an x-axis bolt hole (r 3 mm, axis through (5, 45.3, 130) and
  (9, 45.3, 101)). There the anchored mouth face (62 / 66, curved: a chamfer or fillet) meets the free outer face
  112, about 1 mm from face 17. That's the end of the bearing contact, still an anchor edge.
- The anchors: 44 faces = 22 bolt holes (22 cylinders + 22 curved mouth faces), no flat faces; 980 springs at res 48.
- The contact set did not settle within 6 solves at any resolution. At res 48 it settled in 8 (as drawn) and 10
  (box) solves, and the 6-solve margins were within 0.25 % / 0.5 % of the settled ones. The springs carry 97.5–99.1 %
  of the load.

## Solver cost, noted for #362

On the spring systems the shipped MG-CG smoother (damped Jacobi, ω 0.6) stalls: a steel spring with a tilted normal is
a strongly coupled 3×3 block, and scalar Jacobi is unsafe on it. The cure's l1 retry converges every solve
(365–481 cycles, about 1 s at res 48 on his arms), and the latch then skips the shipped attempt.
