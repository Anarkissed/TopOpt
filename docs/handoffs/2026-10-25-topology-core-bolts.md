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

## NEXT BATCH (the integrator's ruling, 2026-10-26 06:54 EDT; not tonight: rewording now would change the release fingerprint)

Plain wording for core's scenario refusals, which he reads verbatim in the app's failure sheet (354 adds the same lines
as a pre-flight block on Optimize; both halves ship together):
- no anchor ON: "Scenario “<name>” has no anchor switched on"
- no load: "Scenario “<name>” has no load"
- with bearing anchors: "Load scenarios can't be combined with bolt bearings yet"
- with strengthen: "Load scenarios can't be combined with Redesign to strengthen yet"
Where they are today: job.cpp (the schema: no anchor ON, no load, bearing, strengthen) and loadcase.cpp (the same
checks, plus "its load tagged nothing at this resolution").

## LOAD SCENARIOS WITH "REDESIGN TO STRENGTHEN" (the reviewer's ruling of 2026-10-26 12:46, his "it needs to work together!")

Branch `claude/topology-core-scen-strengthen`, from the release (`origin/claude/flexible-screens` 5cf6773b).

- One certification for scenarios everywhere: `certify_scenarios` (pipeline.hpp / minimize_plastic.cpp) runs a given
  certify on every scenario's supports and loads, picks the worst (a non-convergent one first, else the lowest
  margin), reports each scenario's margin, peak and weak-spring share, and marks the first unheld one. The rung gate
  (minimize_plastic), `analyze_job` and strengthen all use it. `sized_scenarios` sizes the weak springs (1e-6 × E ×
  h per node).
- `analyze_job` certifies every scenario on the analysed design (on the design box's grid when a mesh was voxelized
  onto it). `AnalyzeJobResult::scenarios` / `unheld_scenario`; its report line carries "scenarios" and the reason.
- Strengthen, every step on the worst scenario:
  - **reference:** max(as-drawn worst, required). If the part as drawn can't carry a scenario at all
    (`as_drawn_unheld`), the reference is the requirement alone.
  - **targets:** × 1/(1 − cut), as before.
  - **ceiling:** the worst scenario's. If the box filled solid can't carry a scenario (`ceiling_unheld`), every
    version is unreachable: "Scenario “X”'s load has no path to its anchors, even with the box filled solid".
  - **search and fine runs:** the coarse search and the fine runs solve all scenarios (the smooth max).
  - **verify:** checks EVERY scenario on the export.
  - **acceptance:** every scenario held, and the worst verified margin meets the target. Repairs, the 1.05× step,
    IoU and specks are unchanged.
  - **report:** `versions[].scenarios`; the version's margin is the worst's. When 42-B's straight bridge fires in a
    scenario run, the note says so.
- Plain refusals: "Scenario “<name>” has no anchor switched on", "Scenario “<name>” has no load", "Load scenarios
  can't be combined with bolt bearings yet"; the unheld line is "Scenario “<name>”'s load has no path to its anchors".
- Test: `test_scenarios_strengthen` 13/13, red first. Two blocks with a gap: v1 (target 2.0) verified at 9.11 and v2
  (target 9.57) at 11.16, each ONE body, both scenarios held on the export, "B free" governing. v3 is unreachable,
  above 0.95 × the ceiling of 11.29. 21 narrow tests pass.
- Evidence jobs (his Carriage Arms copy 4, res 48), in scratch `evid/`. Scenario 2 = the left plate's 22 anchor
  faces off, 20 N down + 5 N sideways (outward, −x) on the left drum's top (face 34). Scenario 3 = the mirror (face 18,
  +x). The sideways direction is my reading of "sideways".

## STEP 2, THE CORNER FIX (the reviewer's ruling of 2026-10-26 13:12): the Theory of Critical Distances

- **Method:** the VOLUME method. Every margin reads the stress TENSOR averaged over the SOLID voxels within
  `kTcdRadiusMm` of each voxel (`analyze_fixed_design`, analyze.cpp; a sphere, whose solid part at a surface hot
  spot is the method's hemisphere). Von Mises and the interlayer tension (every build direction, the orientation
  scorer included) both come from the averaged tensor. Solid only (printed, not latticed, not loose), so a uniform
  stress averages to itself and a thin member is averaged only over itself. The fields (`von_mises_field`,
  `stress_tensor_field`) stay raw for display, and `peak_von_mises_raw` / `peak_interlayer_raw` keep the raw peaks.
  A voxel coarser than the radius averages each voxel over itself alone, byte for byte the old margin. One place
  reads stress for a verdict, so the certification and strengthen's export-verify (analyze_job) both get it. The
  optimizer's own loop optimises compliance, not stress, so it needs nothing.
- **L:** 0.934 mm, the critical distance Ahmed & Susmel 2017 (FIS 41:252, doi 10.3221/IGF-ESIS.41.34) measured on
  printed PLA: E 3296 MPa, σ_UTS 42.5 MPa, σ0 = 2 σ_UTS = 85 MPa, and the point method at L/2 = 0.467 mm predicted
  notched strength within 20 % for every notch sharpness. Radius = 1.54 L = 1.438 mm (the volume method's
  hemisphere, as the paper describes it). It is used for every FDM material: none of ours carries a fracture
  toughness to derive its own L = (1/π)(K_Ic/σ0)², and this is the only measured L for a printed polymer.
  Ahmed & Susmel 2019 (FFEMS 42:883, doi 10.1111/ffe.12958) backs reading infill as a homogenised linear-elastic
  material plus the TCD, within ±20 %, which is our infill knockdown.
- **Tests:** `test_tcd` 8/8.
  - Plain tension reads yield/(F/A) exactly (8.80 = 8.80): nothing forgiven.
  - An L-bracket's re-entrant corner settles: 0.917 / 0.744 / 0.707 / 0.689 at h 1 / 0.5 / 0.25 / 0.125 mm, 2.6 % at
    the last step, while the raw single-voxel margin falls 0.683 → 0.248 (25 % at the last step).
  - A grid coarser than the radius reads its raw margin exactly.
- **The bore plate:** it converges at the fine end. Bearing 13.17 / 12.87 / 11.99 / 11.91 at res 48 / 64 / 96 / 128
  (0.7 % from 96 to 128); glued 25.63 / 26.43 / 25.36 / 24.33 (4.1 %). The step from 64 to 96 is 6.8 %, at h 0.375 →
  0.25 mm against a 1.44 mm radius, so `test_bearing` (d) checks 96 → 128 now. The averaged bearing peak sits in the
  bearing zone (r ≈ 3.0, ±141–148°): the contact, not a corner.
- **His arms (bar a), MISSED.** Glued certification at res 48 / 64 / 96 / 128 (2026-10-26 13:56, the scratchpad
  `tcd_probe`):

  | | 48 | 64 | 96 | 128 | 96 → 128 |
  |---|---|---|---|---|---|
  | as drawn, old (single voxel) | 3.939 | 3.940 | 2.844 | 2.481 | −12.8 % |
  | as drawn, new (TCD) | 3.939 | 3.940 | 4.661 | 4.083 | −12.4 % |
  | box filled, old | 7.165 | 8.054 | 5.209 | 3.196 | −38.6 % |
  | box filled, new | 7.165 | 8.054 | 6.550 | 5.297 | −19.1 % |

  The voxel is 2.55 / 1.91 / 1.27 / 0.96 mm, so the radius is 0.6 / 0.75 / 1.1 / 1.5 voxels: at 48 / 64 it reads the
  single voxel (by design), and at 96 / 128 the critical volume is the voxel plus its neighbours. The bracket
  settles only from h ≈ radius / 6, so on the arms this would need res ~500–950. No radius up to 5 mm settles both
  rows (2.5 mm: +1.7 % / −5.2 %; 4 mm: −4.0 % / −11.8 %; 5 mm: −2.3 % / −9.3 %, scalar average). The proposed fix:
  re-solve a fine local box (~15 mm, h ≈ radius / 8) around the worst spots, its cut faces driven by the global
  displacements. Posted to the reviewer 2026-10-26 14:07 EDT with three options for the bundle; awaiting the ruling.
- **#362's tweaks** (claude/core-loose-pieces eb470de7: coarse seeding 269ca010, cold first window 6cb055c9, plain
  [mg-safe] wording e49838d2) merged clean at 599636ca. The coarse seed carries across versions with the sequential
  ladder.

## STEP 3, THE NEW STRENGTHEN LADDER (his decision of 2026-10-26)

- **Key:** `loads.safety_margin` (a number: 1.5 = 150 %, also the minimum; below → "The safety margin can't be below
  150% of the load"). It sets the required margin (`margin_stop`) of every loadcase run. Absent = 1.5, byte for byte.
- **Targets:** version 1 = the safety margin. Versions 2 and 3 = 1.10 × the previous version's VERIFIED margin
  (`kStrengthenLadderStep`; the 1.05 step-over is kept as a floor). A version after an unbuilt one is unreachable,
  and its note says so. The drawing is measured as information only: `reference_margin` is the safety margin.
- **report.json:** `strengthen.safety_margin`; `versions[].target_rule` ("your safety margin" / "10% over version N's
  verified margin"); `stress_cut` stays in the schema, always 0. test_strengthen's (a) / (d) pin the new ladder (a
  ruled change), and (b) adds the 10 % rule: 23/23. test_scenarios_strengthen adds the safety-margin refusal: 15/15.
