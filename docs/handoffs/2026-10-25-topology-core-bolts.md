# Handoff: 2026-10-25-topology-core-bolts (TO-core, core only)

Agent: TO-core. Reviewer: "reviewer" on agent-comms #TO-core; #362 on #CoreGroup owns the solver files.
Branch: `claude/topology-core-bolts`, made from `origin/claude/flexible-screens` at `322b1c78` (the solver cure
included), plus a docs-only merge of `origin/claude/topology-core`, plus #362's core-loose-pieces (`4d67e43d`, merged
at `ec391df6`). Merge only, never force.

In the merge, analyze.cpp keeps both the loose-voxel set and the contact loop. `loose` is cleared at each contact
solve, so the stress loop reads the last solve's set (#362 agreed). simp.cpp's active-domain retry rethrows
SolverStopped (#362's ask). After the merge, his arms at res 48 give identical margins and iteration counts.

Evidence for the reviewer: `~/dev/TopOpt/reviewer-inbox/2026-10-25-real-bolts/README.md`.

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
  and bottom edges. Area weighting fixed it: 7.53 / 6.48 / 6.50 at res 48 / 64 / 96, with the peak in the bearing zone
  (7.53 / 6.55 / 6.50 with the hysteresis band, 0.76 % from 64 to 96).
- Without the hysteresis band, his arms' contact set was still changing after 6 solves (chatter).

## The stick ruling (20:37), withdrawn (21:45): option A, near-frictionless

The reviewer ruled a STICK spring on engaged contacts, sized from the node's element stiffness. Measured on the plate,
any linear stick stiff enough to hold the part makes the stuck / released boundary a new singular edge:

| tangential | res 48 / 64 / 96 (/ 128) | 64 → 96 |
|---|---|---|
| 1e-4 per mm² (nearly frictionless) | 7.53 / 6.48 / 6.50 (with the band: 7.53 / 6.55 / 6.50) | +0.4 % (−0.76 %) |
| 1 × diagonal | 6.70 / 4.67 / 4.24 | −9 % |
| 0.1 × diagonal | 7.88 / 6.39 / 5.27 | −17.5 % |
| 0.01 × diagonal | 8.14 / 7.50 / 7.08 | −5.5 % |
| 1 / 0.3 / 0.1 × the normal, per mm² | 6.32 → 3.12, 6.51 → 3.56, 6.79 → 4.05 (48 → 128) | — |

Asked on #CoreGroup (20:48). The reviewer's 21:45 ruling: (A) near-frictionless for this batch, 1e-4 of the normal
per mm². Coulomb stick-slip goes on the list as a later batch. The relative (diagonal) form was removed.

THE SLIDING GUARD (same ruling): the certification reports the share of the anchors' total reaction carried by the
weak sliding springs (`bearing.sliding_share`). Above 5 % (`kAnchorsSlidingShare`) the anchors can't hold the load in
some direction, so the design is NOT accepted. Rejection reason: "anchors cannot hold the load in some direction (held
by the sliding springs)", ordered after the belt and item 47, before the margin. `test_bearing` (e): the plate pulled
along its bore's axis puts 100 % of the reaction on the sliding springs, and the design is rejected.

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
- The sliding guard did not fire: the sliding springs carry 4.6 / 2.8 % (48), 1.5 / 1.4 % (64), 2.0 / 1.9 % (96) and
  3.8 / 2.6 % (128) of the reaction (as drawn / box), all under 5 %.
- Certification cost against glued (CG iterations, solve s; bearing = 6 contact solves):

  | res | as drawn, bearing | as drawn, glued | box, bearing | box, glued |
  |---|---|---|---|---|
  | 48 | 2413, 8.5 | 229, 2.3 | 1994, 15.1 | 267, 11.1 |
  | 64 | 2742, 25.2 | 255, 9.7 | 2988, 63.7 | 409, 14.5 |
  | 96 | 2198, 60.5 | 331, 16.4 | 4411, 304.4 | 650, 35.6 |
  | 128 | 3989, 415.9 | 589, 48.5 | 7140, 771.7 | 1144, 102.8 |

  6–11× the iterations and 1.4–8.6× the solve time; per contact solve, 1–2× glued's iterations.
- The contact set did not settle within 6 solves at any resolution. At res 48 it settled in 8 (as drawn) and 10
  (box) solves, and the 6-solve margins were within 0.25 % / 0.5 % of the settled ones. The springs carry 97.5–99.1 %
  of the load.

## Run-time cost per optimize (his live job, res 48, the same machine, run back to back)

`inputs/job.json` (growth ladder 1.55 / 1.25 / 1.10, PLSM), glued then bearing; the machine was also carrying other
sessions (load 10–14):

| | wall | solves | MG cycles (l1 retry) | per solve | fell back to Jacobi-CG | margins (3 rungs) |
|---|---|---|---|---|---|---|
| glued | 418 s | 171 | ~50 k | 180–680 cycles, 1.1–4.0 s | 0 | 20.7 / 21.6 / 21.3, all accepted |
| bearing | 4440 s (10.6×) | 245 | ~334 k | 720–1,940 cycles, 4.5–17 s | 17 | 10.8 / 10.8 / 10.7, all accepted |

The contact set didn't settle within 6 solves in any rung's certification. #362's worry about ill-conditioning is
confirmed: the sliding directions held only by the 1e-4 tangential springs are near-null modes, and the l1 smoother
needs 4–8× more cycles to resolve them.

## Solver cost, noted for #362

On the spring systems the shipped MG-CG smoother (damped Jacobi, ω 0.6) stalls: a steel spring with a tilted normal is
a strongly coupled 3×3 block, and scalar Jacobi is unsafe on it. The cure's l1 retry converges every solve
(365–481 cycles, about 1 s at res 48 on his arms), and the latch then skips the shipped attempt.

## LOAD SCENARIOS, engine (the reviewer's overnight release ruling, 2026-10-26 03:45), on top of bolts

The shared key: `loads.scenarios = [{"name", "groups": [as loads.groups], "anchor_face_ids": [its ON anchors]}]`, sent
only with 2 or more. With 0 or 1 the job is today's, byte for byte (one scenario is parsed and ignored). report.json:
each line carries `"scenarios": [{"name", "margin", "peak_mpa", "peak_mm", "governs", "unheld", "weak_share"}]`, and
the top level carries the same array for the last accepted line (else the last rejected one). Each line's margin is
the worst scenario's.

- **Optimizer** (`simp_scenarios_compliance`, simp.cpp; used by both simp_optimize loops and PLSM): every iteration
  solves every scenario, each warm-started from its own last field. I chose a SMOOTH MAX of the normalised
  compliances: J = (Σ (c_s / c_s0)^8)^(1/8), with c_s0 the scenario's first compliance; gradient Σ (r_s/J)^7 / c_s0 ×
  dc_s. The worst scenario dominates, and the gradient stays smooth. The coarse warm-start seed solves scenario 1
  alone. The active domain is bypassed (it is a single-load-case optimisation).
- **Certification** (minimize_plastic): every scenario is certified on the rung's design; the worst governs, and its
  analysis is the rung's. That is the same design-level certification the ladder always ran; strengthen's
  export-verify path is refused with scenarios tonight.
- **An anchor OFF in a scenario** is NOT removed. It's held by weak, isotropic, non-contact springs
  (`DirichletBC::contact = false`, never released): 1e-6 of the part's own element stiffness per node (E × h, what
  a clamp holds the part with), sized in minimize_plastic, since only the driver knows the material. A region anchor
  is ON in every scenario (the key names face ids). The loose-piece rule counts weak springs as supports, so it
  classifies against the union of all scenarios' anchors.
- **Guard:** a scenario whose weak springs carry more than 5 % of its load is `unheld`; the rung is rejected with
  "<scenario>'s load has no path to its anchors" (after the belt and item 47, before the sliding guard and the margin).
- **Refused tonight (the safer option):** a scenario with no anchor ON; a scenario whose load tags nothing; scenarios
  with bearing anchors; scenarios with "Redesign to strengthen".
- **Why it works:** Cool, Aage & Sigmund 2025 (SMO 68:73, doi 10.1007/s00158-025-04004-z): a load case whose only
  path is the connection is among the cheapest connectivity methods; its caveat, that it only connects loads to
  supports, is harmless here, because the push and the support sit on the two halves to be joined. A fixed load, no
  self-weight (Bruyneel & Duysinx 2005).
- **Test:** `test_scenarios` 10/10 (red first: it didn't compile before the feature). Two blocks with a gap; scenario
  1 has both anchored, scenario 2 has block B's anchor off and a push on B. Result: one body; scenario 2 held (weak
  springs 0.66 %) and governing at margin 47.2; accepted; report.json carries the key. At vf 0.70 the blocks stay
  apart, scenario 2 is unheld, and the rung is rejected: the guard fires. Finding: one scenario alone also fills the
  gap in this geometry (more material always lowers compliance, and the gap is the only free space), so that line is
  printed as context, not as a control.
- Not done (not a gate): the Carriage Arms run with three scenarios.
