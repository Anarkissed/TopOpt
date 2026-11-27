# TO path: file map

Code at `30292f31`. Lines are total lines (code lines in brackets where counted).
"Runs for him" = the app's normal optimize (on device through bridge.cpp, or on the Mac through the worker and `topopt-cli`).
Read: FULL = every code line read; CODE = code read with comments stripped; FLOW = control flow and callers only; OUTLINE = function list and callers only; NOT = not opened.

## The path in one line

app (RemoteRunner.buildJobJSON / bridge `run_minimize_plastic_loadcase`) -> job.cpp (parse) -> run_job.cpp `run_job` -> loadcase.cpp `build_production_loadcase` -> minimize_plastic.cpp `minimize_plastic` (ladder) -> plsm.cpp `plsm_optimize` (per rung) -> simp.cpp `simp_compliance` -> fea matrix-free multigrid -> analyze.cpp `analyze_fixed_design` (strength check) -> run_job.cpp `variant_export_model_mesh` (mesh.cpp marching cubes, cad_project.cpp, finish.cpp) -> re-check through `analyze_job` -> STL + report.

## core/src/simp

| file | lines | what it does | called by | runs for him | read |
|---|---|---|---|---|---|
| plsm.cpp | 1184 (612) | The level-set optimiser loop: RBF coefficients, exact voxel fill fractions, MMA step, margin stop rule | minimize_plastic.cpp:2241 | YES, every rung | FULL |
| minimize_plastic.cpp | 3386 (1974) | The ladder driver: design domain, masks, per-rung optimise, certify, accept/reject; also old-lattice couplings | run_job.cpp, bridge.cpp | YES | CODE |
| production.cpp | 873 (183) | Production switches and the two ladders | loadcase.cpp, run_job.cpp, bridge.cpp | YES | CODE |
| analyze.cpp | 803 (479) | The strength check on a fixed design (margin, interlayer, orientation scoring, old-lattice certificate) | minimize_plastic.cpp, run_job.cpp `analyze_job` | YES | CODE |
| simp.cpp | 4501 (3035) | SIMP optimiser (3 overloads), its MMA/OC, filters, projections; ALSO the shared pieces PLSM uses: `simp_compliance` (572), `simp_scenarios_compliance` (1839), `effective_design_mask` (2758); a stress-constrained optimiser (3892-4460, tests only) | plsm.cpp (shared pieces), minimize_plastic.cpp (SIMP path) | shared pieces YES; the SIMP loop itself NO (only `topopt-cli` jobs with no `plsm` block, and the coarse warm start) | OUTLINE + `simp_compliance` CODE |
| observability.cpp | 2308 (1891) | Writes run_info.json and per-iteration CSVs | run_job.cpp | YES (receipts) | OUTLINE |
| gate_diagnosis.cpp | 751 (573) | "Why did this rung fail and what one change would pass it" | minimize_plastic.cpp:3289 | YES | OUTLINE |
| warm_start.cpp | 246 | Coarsen grid/BCs/mask, prolong a design | minimize_plastic.cpp:1657 | only on a job `warm_start` block | OUTLINE |
| semdot.cpp | 283 | SEMDOT smooth-edge densities | simp.cpp | NO (job flag, SIMP only) | OUTLINE |
| mma_joint.cpp/.hpp | 308 | MMA for solid + lattice-density jointly (Mode 2) | simp.cpp | NO (never armed) | OUTLINE |
| lattice_density_field.cpp | 598 | Old-lattice density per region, beta field (Mode 2) | minimize_plastic.cpp | NO (frozen_lattice never armed) | OUTLINE |
| grading.cpp | 1763 | OLD lattice grading law | run_job.cpp lattice export, app preview | old lattice: ask LatticeReview | NOT |
| cell_plan.cpp | 901 | OLD lattice cell-size planning | run_job.cpp, bridge | old lattice: ask LatticeReview | NOT |
| lattice_algorithm.cpp | 68 | OLD lattice algorithm names | run_job.cpp | old lattice | NOT |

## core/include/topopt (TO headers)

| file | lines | what | read |
|---|---|---|---|
| plsm.hpp | 440 (112) | PLSM options and result | CODE |
| plsm_basis.hpp | 397 (300) | The two bases (Gaussian default, Wendland C2), knot lattice, sparse matrix, least-squares fit | CODE |
| plsm_mma.hpp | 176 | One-constraint MMA on coefficients | CODE |
| plsm_frac.hpp | 515 | Fill fraction per cut voxel (4x4x4 point samples of phi) and its sensitivity | CODE |
| plsm_kernel.hpp | 222 | Heaviside, gradient magnitude, fast-sweep reinitialisation | CODE |
| plsm_topology.hpp | 345 | Counts sealed voids / drainability of the result (report only) | CODE |
| pipeline.hpp | 1998 (361) | `MinimizePlasticOptions` / result / variant structs | grep only |
| simp.hpp | 2028 (345) | SIMP options, shared solve types | grep only |
| production.hpp, analyze.hpp, loadcase.hpp, job.hpp, finish.hpp, cad_project.hpp, surface_operator.hpp, smooth.hpp, mesh.hpp, fea.hpp, voxel.hpp, observability.hpp, report.hpp, gate_diagnosis*.hpp, warm_start.hpp, semdot.hpp, strengthen_accept.hpp | - | declarations for the files in this map | grep only |

## core/src/cli

| file | lines | what | runs for him | read |
|---|---|---|---|---|
| run_job.cpp | 21635 (15173) | Everything a job does. TO parts: export mesh + finish + re-check (900-1380), `production_loadcase_from_job` (12031), `analyze_job` (13076), `build_job_setup` (17570), `strengthen_versions` (18065), `run_job` (18600-21413), `refinish_job` (21413). The rest (about 1640-11870, 14120-17550) is old-lattice export, organic, forecasts and the lattice strength-file job | YES | export, `strengthen_versions`, `run_job` CODE (not its lattice forecast, lattice export lambdas, receipt writer); lattice parts NOT |
| loadcase.cpp | 1502 (1071) | Loads, anchors, pads, protections, keep-clears, scenarios -> optimiser options | YES | 690-1075 CODE; rest OUTLINE |
| job.cpp | 3250 (2615) | Job JSON schema and parsing (171 keys) | YES | key census + plsm block |
| main.cpp | 1057 | `topopt-cli` commands | YES (worker) | OUTLINE |

## core/src/mesh (TO files only)

| file | lines | what | runs for him | read |
|---|---|---|---|---|
| mesh.cpp | 803 | Marching cubes, tricubic resample, component cleanup | YES (export) | resample CODE; rest OUTLINE |
| finish.cpp | 1288 (1145) | The finish: thin-spot cleanup, curvature flow with guards, weld, audits | YES | `surface_finish`, `finish_shape`, thickness, thin-spot cleanup CODE; audits and weld OUTLINE |
| surface_operator.cpp | 972 | Mean-curvature flow with trust limits; `ramp_reconstruction` (dead) | YES (flow) | OUTLINE |
| cad_project.cpp | 950 | Snap mesh vertices onto the CAD's planes and cylinders | YES when the CAD is a STEP with real faces | CODE |
| smooth.cpp | 265 | Constrained Taubin smoothing | YES: smooth brush and `analyze` smoothing only | OUTLINE |
| feature_edges.cpp, mesh_simplify.cpp, mesh_distance.cpp | 224 / 774 / 415 | sharp-edge chains, bounded simplify, distance queries | lattice export and checks | OUTLINE |
| organic_lattice, lattice_gen, lattice_dc, lattice_boundary, stepped_plan, lattice_lslt, lattice_coupon, lattice_void, lattice_volume_check, tpms_gen, lattice_union_volume, lattice_sample | 15,800 | OLD lattice engine | ask LatticeReview which survive stage G | NOT (out of scope) |

## core/src/fea

| file | lines | what | runs for him | read |
|---|---|---|---|---|
| multigrid.cpp, matfree.cpp, fea_matfree.hpp | 6008 | Matrix-free multigrid CG (the production solver) | YES | hot path CODE (element product, V-cycle, CG loop); rest OUTLINE |
| geneo.cpp/.hpp, recycle.cpp/.hpp | 2594 | Two-level coarse space; Krylov recycling (both armed) | YES | OUTLINE |
| hex_element.cpp | 765 | Element stiffness and stress recovery | YES | grep only |
| contact.cpp | 63 | Bearing-anchor contact update | YES with bolt bearings | OUTLINE |
| assembly.cpp | 1027 | Assembled CG solver, `PenalizedSolver` | tests / non-production | OUTLINE |
| algebraic_coarsen.cpp/.hpp | 1150 | Algebraic coarse level | NO (compiled off) | OUTLINE |
| lattice.cpp, lattice_material.cpp, lattice_types.cpp, strut_cell.cpp, strut_strength.cpp, beam_network.cpp, sparse_ldlt.cpp | 6500 | Lattice material laws and beam solver (old and new engines) | lattice | NOT (LatticeReview's area) |

## core/src/voxel, io, orient, settings

| folder | lines | what | read |
|---|---|---|---|
| voxel/ (voxelize, clearance, voxel_sdf) | 2018 | Part -> voxel grid, min feature, printed bodies, bridges, V3 check, keep-clear geometry | voxelize.cpp 1-470 and 969-1420 CODE; rest OUTLINE |
| io/ (step, stl, 3mf, part, face_region, fields, design_store...) | 3821 | File import/export, face regions | face_tag.cpp CODE; rest OUTLINE |
| orient/ | 1254 | Build-direction scoring and baking | OUTLINE |
| settings/ (report.cpp, settings.cpp, gate_diagnosis_report.cpp) | 1740 | report.json, print-settings rules, the margin formula | `recommend_settings`, `compute_stress_margin` CODE; rest OUTLINE |

## App side (inputs and outputs only)

| file | what | read |
|---|---|---|
| app/.../TopOptFlows/RemoteRunner.swift:676-1086 | Builds the job the Mac worker runs. Sends `"plsm": {"enabled": true}` | CODE |
| app/.../TopOptBridge/bridge.cpp:1124-1152, 2055-2110 | On-device optimise; sets PLSM on. :550 has its own copy of the load-case mapping | FLOW |
| tools/topopt-worker/topopt_worker.py:549 | Worker: runs `topopt-cli` on the job and streams events | FLOW |

## core/tests

unit 109 files / 63k lines; validation 92 / 37k; harness 141 probes / 79k lines (experiment code; 44 mentions in CMakeLists). TO unit tests: plsm, plsm_topology_drainability, simp, semdot, analyze_fixed_design, finish, surface_operator, cad_project, smooth, warm_start, strengthen_accept.

## Read coverage (2026-11-21)

Phase 1 reading is closed at the coverage in the tables above. Outline only, by choice (none decides a shape): the SIMP optimiser bodies (proposed for removal, ledger S-08), observability.cpp, io/ except face_tag.cpp, orient/, main.cpp, job.cpp beyond the key census, finish.cpp's audits and weld, and the solver outside its hot path. Old-lattice files stay with LatticeReview.
