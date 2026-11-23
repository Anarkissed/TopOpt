# TO review ledger (Phase 1, read-only)

Lead: TOReview. Code reviewed at `30292f31` (release 11 evidence tip, 2026-11-20).
Status: IN PROGRESS. Rows are added as files are read; nothing in the code has been changed.

Columns: id | file:line | kind | severity (H/M/L) | evidence | action | size (S/M/L).

## A. Leads from the history, checked against today's code

| lead | verdict today | evidence |
|---|---|---|
| Which optimizer does production run? | PLSM, but only because the APP asks for it. Core's default is still SIMP. | `PlsmOptions::mode = Off` (plsm.hpp:125); `configure_production_options` never sets it (production.cpp:545-812); armed in bridge.cpp:1152 and :2110 (on-device) and RemoteRunner.swift:726 (`"plsm": {"enabled": true}` to the worker); run_job.cpp:17773 maps the job block. `topopt-cli` with no `plsm` block runs SIMP. |
| PLSM basis | The app runs the GAUSSIAN basis, support 2.0 knot spacings, not Wendland C2. | plsm.hpp:129 `basis = "gaussian"`, :139 `support = 2.0`; the app sends only `enabled`. (plsm_basis.hpp still to read.) |
| Exact volume fraction shipped; anything read eta_voxels? | Fraction is the default (plsm.hpp:142). `eta_voxels` is live only on the Heaviside control arm (plsm.cpp:262, 529, 579, 802) plus a `> 0` validation and receipts. | grep of plsm.cpp; job.hpp:1256,1266 |
| Stopping rule | LIVE: a certification probe every 10 iterations; stops after 3 probes without a 0.5 % gain and SHIPS THE MARGIN PEAK, not the last iterate. Off for multiscale runs. Ceiling 120 iterations. | plsm.cpp:740-767, 1050, 1116-1126; minimize_plastic.cpp:2217; plsm.hpp:255-272 |

| Export straight from PLSM's analytic phi? | NOT done. The coefficients (`plsm_alpha`) are only written to a `.f64` receipt file. The print file is rebuilt from the per-voxel occupancy. | run_job.cpp:437-491 (receipt), :1051-1117 (export reads `physical_density` only); grep `plsm_alpha` has no other reader. |
| Today's export chain | voxel occupancy -> marching cubes, tricubic resample at `smooth_factor` -> CAD-face projection -> `finish_shape` (thin-spot cleanup + mean-curvature flow) -> weld -> exact keep-clear cut -> file re-voxelised and re-certified, with a fallback to a safer finish. | run_job.cpp:1019-1118, :1281-1349; finish.cpp:576,626 |
| Mean-curvature flow (surface_operator) | LIVE, inside the finish. | finish.cpp:576, 626 |
| Taubin brush (smooth.hpp) | LIVE: the app's smooth brush / smooth-and-recertify and `analyze_job`'s smoothing. Not in the automatic export. | bridge.cpp:1459,1751,1945; run_job.cpp:13344-13355 |
| cad_project | LIVE when `output.project_cad_faces` and the CAD faces are real (not fitted). | run_job.cpp:958, 1108-1115 |
| SEMDOT | Reachable only from a job's `semdot` block on the SIMP path; the app never sends it. Dead for the app. | job.cpp:1325; run_job.cpp:17758; simp.cpp:3368-3800; RemoteRunner sends no `semdot` |
| Robust erode/dilate triple | NOT in the tree. No `robust`, `erode`, `dilat` in src/simp or plsm headers. Lost (lives only in PR branches / evidence). | grep |
| Mode 2 (PR 334, beta field) | In the tree but UNREACHABLE: `frozen_lattice_*` options, `LatticeFieldCoupling` (lattice_density_field.cpp), `mma_joint.cpp`, wired in minimize_plastic.cpp:1125-1425, 1879 and simp.cpp:98, 3389. Nothing in core/src, the bridge or the app ever sets `options.frozen_lattice = true`; only tests do. And the coupling is read only by the SIMP loop, so the app's PLSM run would ignore it even if armed. | grep for assignments; plsm.cpp has no `lattice_coupling` |
| `multiscale` (PR 293) | Permission compiled ON; runs only when a job says `lattice.multiscale` (job.cpp:2060). The app's job builder never writes that key, so it is dead for him. | production.cpp:220; run_job.cpp:19743; RemoteRunner.swift:759-829 |
| minimize_plastic = off today | Means GROW: ladder {1.55, 1.25, 1.10} of the part's weight inside a design box (auto-derived when none is drawn). It adds plastic. With `redesign = strengthen` it runs the strengthen-versions route instead. Both live. | loadcase.cpp:718-720, 913-937, 967-969; run_job.cpp:20626 |
| Strengthen ladder (2026-10-26) | LIVE on `loads.redesign = "strengthen"`: `strengthen_versions` (run_job.cpp:18065). (Body still to read.) | run_job.cpp:17827-18560, 20626 |
| Stress-constrained optimiser | EXISTS but unused: `simp_optimize_stress` with a stress aggregate and adjoint (simp.cpp:3892-4460). Called only by 4 tests. | caller trace |
| width_aware_knockdown | Still OFF. | production.cpp:183, 803 |
| Reduction ladder | {0.68, 0.52, 0.38, 0.26}; walks down, stops at the first rung that fails the margin; no search between rungs, nothing lighter than 0.26. | production.cpp:814; minimize_plastic.cpp:3301-3362 |

(Remaining leads: robust triple, wider support / C4, PLSM vs SIMP gap, multiscale / Mode 2, ladders, width_aware_knockdown, SEMDOT, Taubin, mean-curvature flow, cad_project, analytic-phi export. To be filled.)

## B. Findings

| id | file:line | kind | sev | evidence | action | size |
|---|---|---|---|---|---|---|
| P-01 | src/simp/production.cpp (whole) | unnecessary code | L | 873 lines, 183 of code; the rest is history in comments. Same pattern in production.hpp (426 / 35), simp.hpp (2028 / 345), pipeline.hpp (1998 / 361), job.hpp (1787 / 448), plsm.cpp (1184 / 612). Counted with grep. | clean: move history to docs, keep one line of "why" per constant | M |
| P-02 | src/simp/production.cpp:97,183,244,344 + getters | dead code | M | Four switches compiled OFF with full machinery behind them: active_domain_band=0, width_aware_knockdown=false, lattice_auto_is_fit=false, mg_algebraic_level1=false. (Callers still to trace.) | decide per switch in the plan: delete or arm | M |
| P-03 | src/simp/plsm.cpp:156 | unclear contract | M | `kPlsmKnotMm = 3.410558` is "two voxels at HIS production resolution" for one part. On any other part or resolution the knot spacing in voxels differs (floored at 2), so feature size and smoothness change with the part. Read. | rewrite: derive from print profile (bead width) and part size | S |
| P-04 | src/simp/plsm.cpp:172-206, 523-540 | unclear contract (G2) | H | The frozen set (protected faces, pads, keep-outs) enters as a per-voxel stamp (occupancy 1 / 0); its boundary is a voxel staircase, reinitialised from a half-voxel step. The optimiser never sees the true CAD surface. Read. | rewrite: frozen sets as true signed distances from the CAD | L |
| P-05 | src/simp/plsm.cpp:591-600 | slow | L | Volume offset by 100 bisections every iteration on a fixed ±400 bracket; each evaluation is a full pass over the cut cells × 64 samples. ~50 halvings reach double precision; a warm bracket would need ~15. Read. | clean | S |
| P-06 | src/simp/plsm.cpp:668-669, 873-888 | duplicate | L | Volume is enforced twice: exactly by the rigid offset each iteration, and again as the MMA constraint g0. Read. | keep, document (or drop the MMA constraint) | S |
| P-07 | src/simp/plsm.cpp:639-1078 | missing feature (G2, G3) | H | The loop minimises compliance at a fixed volume only. No stress in the objective or constraints, no print constraint (overhang, minimum wall), no smoothness term. The margin enters only through the stop rule. Read. | rewrite / new (see research 3a, 3b) | L |
| P-08 | src/simp/plsm.cpp:709-710 | bug (to verify) | M | Bearing-anchor contact is refreshed from `sc.solution.u` on `contact_bcs`, but when load scenarios exist the solve uses `options.scenarios` and never reads `contact_bcs`. Contact state may never update under scenarios. Needs a trace through simp_scenarios_compliance. | verify, then fix | S |
| P-09 | src/simp/plsm.cpp:943-1026 | duplicate | L | ~80 lines copying solver counters into the observer, the same block simp.cpp has. Read. | clean: one shared function | S |
| P-10 | src/simp/plsm.cpp:838-869, 900-903 | slow | L | Six voxel-sized vectors allocated every iteration. Read. | clean | S |
| P-11 | src/simp/plsm.cpp:899-912 | unclear contract (G2) | M | Every 5 iterations the field is re-distanced and RE-FITTED by least squares (ridge 1e-6, clamp 6 voxels). The fit moves the surface; how much is not recorded per run. Read. | measure in Phase 2 | S |
| P-12 | src/simp/minimize_plastic.cpp:801-~3300 | unclear contract | H | `minimize_plastic()` is one function of about 2,500 lines holding the ladder, both optimisers, drafts, escalation, certification and export prep. Outline by grep. | rewrite into stages | L |
| P-13 | src/cli/run_job.cpp (whole) | unclear contract | H | 21,635 lines; holds the TO run, the old lattice export, organic, the strength-file job, strengthen versions and forecasts in one file. Outline by grep. | split by job kind | L |
| X-01 | src/cli/run_job.cpp:1051-1117, 437-491 | unnecessary work / design gap (G2) | H | The optimiser holds a smooth analytic surface (RBF coefficients) and throws it away: export re-derives the surface from one number per voxel, then needs tricubic resampling and curvature flow to hide the voxel grid. Traced readers of `plsm_alpha`. | rewrite: mesh the analytic field directly (research 3a) | M |
| X-02 | src/cli/run_job.cpp:1019-1118 | unclear contract | M | `variant_export_model_mesh` calls itself three ways (finish / keeps / plain) through nine optional arguments. Read. | rewrite as explicit stages | S |
| X-03 | src/cli/run_job.cpp:1281-1349, 21432-21524 | unnecessary work | M | The finish is checked by writing an STL to disk and running the whole `analyze_job` on it (voxelise + solve), up to twice (slim, then safe). Diagnostic line at 21520-21524 builds the export mesh four more times. Read; cost to be timed in Phase 2. | clean | M |
| M-01 | src/simp/minimize_plastic.cpp:2529, 2603, 2998 | duplicate | L | The printed-voxel count and rejected-rung bookkeeping are written out three times. Read. | clean | S |
| M-02 | src/simp/minimize_plastic.cpp:1769, 2282-2470, 795-799 | dead code for the app | M | Draft tolerance, draft escalation probes and conditional MMA projection are all gated on `plsm.mode != Parametric`. The app always runs PLSM, so these never run for him. Read. | delete with SIMP, or keep SIMP as a test-only reference (plan decides) | M |
| M-03 | src/simp/minimize_plastic.cpp:1648-1708 | unclear contract | L | `warm_start_coarse` seeds a PLSM run from a coarse SIMP run. Armed only by a job's `warm_start` block. Read. | decide with SIMP | S |
| M-04 | src/simp/minimize_plastic.cpp:2217-2236 | slow | M | The margin stop rule runs a full certification (`analyze_fixed_design`, tight solve) every 10 iterations, up to 12 per rung, on top of the final one. Read; cost to be timed in Phase 2. | keep the rule, make the probe cheaper | M |
| M-05 | src/simp/minimize_plastic.cpp:3301-3362; production.cpp:814 | design gap (G3) | H | "Lightest part that is strong enough" is approximated by four fixed weights. The answer can sit anywhere between two rungs, and never below 26 %. Read. | rewrite (research 3b) | L |
| M-06 | src/simp/minimize_plastic.cpp:1024-1425, 2657-2805 | old-lattice coupling | M | About 600 lines of the driver serve the OLD lattice paths (multiscale, frozen lattice, beta field, posture). They price lattices with the old homogenised model, not the new engine's laws. Read. | delete or replace under G4 (ask LatticeReview what stage G removes) | L |
| S-01 | src/simp/simp.cpp:3892-4460 | dead code in production (G3 asset) | M | `simp_optimize_stress`, `simp_stress_aggregate`, the stress adjoint: no caller outside tests. Caller trace with grep. | keep the maths, move it under the new stress-constrained loop (research 3b) | M |
| S-02 | src/simp/simp.cpp:4470-4501 | dead code | L | `simp_optimize_variants`: one test only. Caller trace. | delete | S |
| S-03 | src/simp/lattice_density_field.cpp:427-598, minimize_plastic.cpp:1111-1425, simp.cpp:3503-3550 | dead code | M | Mode 2 (joint solid + lattice-density optimisation). Never armed outside tests (see leads). CORRECTED after the reviewer's ruling and a grep: `mma_joint.cpp` itself is NOT dead; it is the MMA subproblem the SIMP loop calls on every optimisation (simp.cpp:1523, 2930). Only the beta-field use at simp.cpp:3503-3550 is Mode 2. S-06's count of MMA copies is to be re-checked against this. | keep as reference for G4a research, then delete or rebuild on the new engine's laws | M |
| S-04 | src/simp/semdot.cpp, simp.cpp:195-230, 3368-3800 | dead code for the app | L | SEMDOT: SIMP-only, job-flag-only. | delete with SIMP decision | S |
| L-01 | src/cli/loadcase.cpp:233-1113 | unclear contract | M | `build_production_loadcase` is one 880-line function. Outline. | rewrite into steps | M |
| L-02 | src/cli/loadcase.cpp:818-888 | duplicate | L | Face-protection by face and by region are the same 35 lines written twice. Read. | clean | S |
| L-03 | src/cli/loadcase.cpp:821-826, 864-867 | unclear contract (G3: "protected faces and their depths are respected") | H | A protection depth is rounded to whole voxels (`region_depth_layers`), so a 2 mm depth at a 1.7 mm voxel becomes 1.7 or 3.4 mm. The effective depth is reported, but the part does not get the depth he typed. Read. | rewrite with P-04 (true distances) | M |
| L-04 | src/cli/loadcase.cpp:718-720, 916-937 | design gap (G3) | H | Generative mode today can only ADD material at three fixed weights; it cannot return a lighter part. His G3 goal needs the opposite search. Read. | rewrite (research 3b) | L |
| P-08 | (update) | refuted | - | Load scenarios with bolt bearings are refused up front (loadcase.cpp:1014), so the contact refresh never meets scenarios. No bug. | none | - |
| A-01 | src/simp/analyze.cpp:313, 428, 458 | unclear contract / likely bias (G2, G3) | H | The strength check solves with the SIMP modulus `E * rho^3` on the grey field, then reports stress with the FULL modulus in every voxel above 0.5. A boundary voxel at 60 % fill is solved at 22 % stiffness, so its strain, and the stress reported from it, is inflated several times. PLSM's exact-fraction field has partly filled voxels along the whole surface by construction; SIMP's projected field does not. This is a candidate cause of "PLSM 27.6 % weaker than SIMP" and of the margin peaking then falling. Read; NOT yet measured. | measure in Phase 2: density of the voxel that sets the margin, on every reference part | S to measure |
| A-02 | src/simp/analyze.cpp:482, 521 | unclear contract (G3) | H | The margin is yield over the single highest voxel stress. One voxel decides pass or fail, on a stair-stepped surface where corner voxels read high. Nothing is averaged or aggregated. Read. | research 3b: aggregated stress measure (Le 2010) for the optimiser; keep a peak check for the certificate, on a smooth boundary | M |
| A-03 | src/simp/analyze.cpp:162-801 | unclear contract | M | `analyze_fixed_design` is one 640-line function with 21 positional arguments (seven booleans/doubles in a row at every call site). Read. | rewrite: options struct, split lattice / orientation / contact | M |
| A-04 | src/simp/analyze.cpp:195-238, 551-640, 727-796 | old-lattice coupling | M | About 200 lines certify the OLD homogenised lattice posture inside the solid certificate. | follows M-06 | M |
| R-01 | src/cli/run_job.cpp:18065-18557 | asset for G3 (and slow) | H | `strengthen_versions` ALREADY searches for the lightest design that meets a strength target: per version it brackets the weight on a half-resolution grid (up to 6 runs: halve while it passes, double while it fails, bisect to 8 %), runs once at full resolution, verifies the exported file by re-analysis, and repairs up to twice. Targets: his safety margin, then x1.10, x1.10. So the generative goal has a working, compliance-based baseline today; it only runs on `redesign = strengthen` inside a design box. Control flow read; body not yet read line by line. Cost: up to 3 x (6 coarse + 3 fine) optimisations plus file checks. | keep as the Phase 2 baseline for G3; research 3b decides whether a stress-constrained loop replaces the bracket | L |
| R-02 | src/cli/run_job.cpp:17836-17865 | unclear contract | L | `append_rung` concatenates 25 parallel per-rung vectors by hand; `MinimizePlasticResult` keeps per-rung facts as parallel arrays instead of one record per rung. Read. | clean: one struct per rung | S |
| B-01 | core/include/topopt/plsm_basis.hpp:59-63; plsm.hpp:129 | bug-class defect (G2) | H | The basis the app ships ("gaussian", the default) is a Gaussian cut off at 3 sigma and shifted so its VALUE is zero at the edge. Its SLOPE is not zero there (d/dr = -9 e^-4.5, about 10 % of its scale), so the level-set field has a crease on a sphere around every knot, 2 knot spacings out. The file's own comment says an unshifted cut "shows up as a faint lattice-periodic ripple in the surface"; the shift fixed the step, not the crease. Wendland C2 (already in the file) has zero slope and curvature at the edge. Derived by hand from the formula; the size of the ripple on a real part is NOT yet measured. | measure in Phase 2 (same job, basis = wendland vs gaussian); then fix or replace (research 3a: C2/C4 Wendland, B-splines) | S |
| B-02 | core/include/topopt/plsm_basis.hpp:187-230 | unnecessary work | L | `plsm_build_A` runs the support search twice per voxel (count, then fill) and stores the full voxel x knot matrix and its transpose in memory. Read. | clean (single pass; or tensor-product evaluation) | S |
| B-03 | core/include/topopt/plsm_basis.hpp:122-148 | slow | L | `plsm_parallel_for` creates and joins fresh threads on every call; it is called several times per iteration (and 100x per iteration through the volume bisection's sibling `plsm_frac_parallel`, to verify). Read. | clean: one pool | S |
| F-01 | core/src/mesh/finish.cpp:444-648, 1166-1286 | design gap (G2) | H | The shipped "finish" is a fifth downstream mesh filter: mean-curvature flow with each vertex allowed to move at most half a mesh cell, guard rounds for thin members, a volume-restoring nudge, and a keep-clear walk-back. By construction it cannot move the surface more than half a cell, so it cannot remove anything the optimiser's field put there at a longer wavelength (the bumps). Its own "stair-step removed %" compares the mesh to a low-passed copy of itself, not to a designed surface. Read. | replace after 3a decides the representation; keep the guards (thin member, keep clear, pins) as checks | L |
| F-02 | core/src/mesh/surface_operator.cpp:686-972 | dead code | L | `ramp_reconstruction` (about 290 lines): no caller in core/src or the app. Caller trace. | delete | S |
| F-03 | core/src/mesh/{finish,surface_operator,cad_project,feature_edges,mesh_simplify,mesh_distance}.cpp, cli/run_job.cpp:17870 | duplicate | L | Vec3 add/sub/dot/cross/len are redefined in six files; closest-point-on-triangle is implemented four times (finish.cpp:30, cad_project.cpp:32, mesh_distance.cpp:41, run_job.cpp:17870). Outline by grep. | clean: one vec3 header | S |
| F-04 | core/src/mesh/finish.cpp:1226-1277, run_job.cpp:1180-1224 | slow | M | Keep-clear checks call `mesh_encloses` (a ray test against every triangle) per voxel centre, per round, with no spatial index; the "near the part" test at run_job.cpp:1195 is a brute-force loop over all triangles. Read; to time in Phase 2. | clean: reuse MeshDistance / a grid | S |
| P-14 | core/src/simp/plsm.cpp:538; simp.cpp:661, 857; minimize_plastic.cpp:1017 | likely bias (G2, G3) | H | PLSM hands the solver `rho = exact volume fraction` and the solver uses `E * rho^3` (SIMP penalty 3, fixed at minimize_plastic.cpp:1017). A half-filled boundary voxel therefore carries 12.5 % of solid stiffness instead of about 50 %. Every surface is modelled softer than it is, by roughly a third of a voxel per side, which hits thin members hardest. Level-set methods normally use a linear ersatz (Allaire 2004; Wei 2018). The file's own comment (plsm.cpp:79-86) records the p = 3 choice as inherited from SIMP, not as measured against a linear law. Read; NOT yet measured. | measure in Phase 2: same design certified with p = 3, p = 1 and on a 2x finer binary grid | S to measure |
| X-04 | core/src/mesh/mesh.cpp:392-494; run_job.cpp:1054-1057 | stair-step mechanism (G2) | H | The export interpolates per-voxel FILL FRACTIONS with a Catmull-Rom tricubic and takes the 0.5 surface. A fill fraction is not linear in distance to the surface, so on any wall that is tilted to the grid the 0.5 surface wobbles once per voxel: the stair-step. Catmull-Rom also overshoots next to saturated 0/1 voxels. Read and reasoned; amplitude to be measured in Phase 2 on a known tilted plane and a known cylinder (cheap, no solve). | rewrite with X-01 (mesh the analytic field) | M |
| S-05 | core/src/simp/simp.cpp:776-861 | slow | M | The compliance sensitivity is a single-threaded loop over every voxel doing a dense 24x24 multiply, every iteration, although the solver beside it is multithreaded and matrix-free. Read; to time in Phase 2. | clean: thread it / reuse the matrix-free element kernel | S |
| S-06 | core/src/simp/simp.cpp:1587, 3048, 4194; mma_joint.cpp:32; include/topopt/plsm_mma.hpp:88 | duplicate | M | Five hand-written copies of the MMA update. The one PLSM uses takes exactly ONE constraint (volume) and rescales the objective by its largest gradient every iteration. Stress constraints (G3) and a second field (G4a) need several constraints. grep + read of plsm_mma.hpp. | rewrite: one MMA with m constraints, shared | M |
| E-01 | core/include/topopt/fea.hpp:677-1697; production.cpp:586-811 | unclear contract | M | The solver is configured through eleven process-wide setters (threads, recycling, GenEO, block cache, lattice kernel...). `configure_production_options` flips them as a side effect, so a result depends on which caller ran before; analyze.cpp:244-256 already records one consequence ("not a pure function of its arguments"). Read. | rewrite: a solver-settings struct passed in | M |
| E-02 | core/src/fea/algebraic_coarsen.cpp/.hpp (1,150 lines); multigrid.cpp:1537-1551, 2117-2210 | dead code | M | Algebraic level-1 coarse space: compiled OFF with a static_assert that it ships disarmed (multigrid.cpp:382). Caller trace. | delete, or measure and arm (plan decides) | M |
| E-03 | core/src/fea/assembly.cpp (`fea_solve_cg`, `PenalizedSolver`), multigrid.cpp (`fea_solve_mgcg`) | dead code for the app | L | Production always selects `MultigridCG_Matfree` (production.cpp:550). The assembled Jacobi-CG and assembled multigrid solvers are reachable only from tests and non-production CLI jobs. Caller trace; bodies not read. | keep one small reference solver for tests; delete the rest | M |
| E-04 | core/src/fea/{multigrid,matfree,geneo,recycle}.cpp (7,050 lines) | coverage note | - | Solver internals were NOT read line by line in this pass: only entry points, switches and callers. They are shared with the Flexible stage (flexible_squish_fe.cpp calls `fea_solve_mgcg_matfree`). Ask the reviewer whether a line-by-line solver review is wanted; it does not bear on G1-G4 unless Phase 2 shows the solve dominates run time. | ask | - |
| I-01 | app/.../bridge.cpp:550 vs core/src/cli/run_job.cpp:12031 | duplicate | M | The on-device path and the worker path each map the user's loads, anchors, protections and keep-clears onto the optimiser through their own function (`production_loadcase_from_bridge`, `production_loadcase_from_job`); PLSM is likewise switched on in two places that "MUST move together" (bridge.cpp:1140). Outline + comments. bridge.cpp is #362's file. | one mapper in core; ask #362 through the reviewer | M |
| T-01 | core/tests/harness (141 files, 79,436 lines) | unnecessary code | L | One-off experiment probes from past investigations; CMakeLists mentions `harness/` 44 times, so many are not built. wc + grep. | delete the unbuilt ones after his OK (deleting needs his OK); keep the gates | M |
| T-02 | core/tests/unit | missing test | H | No test measures the smoothness of an exported surface against a known shape (plane, cylinder, sphere), and none checks the certificate against a known stress solution on a tilted or curved boundary. grep for roughness/quadric/ripple in tests/unit finds only self-referential roughness. | new (04-tests.md) | M |
| C-01 | core/src/io/step.cpp:197-221; core/src/mesh/cad_project.cpp:319-431 | design gap (G2) | M | CAD projection knows two surface types: plane and cylinder. Every fillet, cone, sphere and spline face is typed `Other` and stays as the voxel mesher left it, so a designed fillet that survives optimisation comes out stair-stepped. Also only for STEP input with real faces (`faces_are_fitted == false`); an STL part gets no projection at all. Read. | extend (research 3a: fillets = torus, cones, spheres) | M |
| P-15 | core/src/simp/plsm.cpp:740-767, 1050 | logic defect | H | The stop rule watches the certified margin. When the margin is set by a frozen region (a load or anchor voxel), it is flat from the first probe, so the rule fires after 3 stale probes and every run ends at iteration 40 and ships iteration 10's design. Seen on 4 of 4 baseline runs (run_info: `plsm_margin_peak_iteration = 10`, `plsm_stop_reason = margin-plateau`). | rewrite: stop on the design's own stress measure, excluding boundary-condition voxels; keep a convergence test | S |
| A-05 | app result page / report.json | missing plain line | H | A run whose first rung fails returns zero versions and the reason "margin below required"; nothing tells him the part as drawn is too weak for the load (Base 0.40, Pressing Plate Mount 0.35 against 1.5). He took it to mean no optimisation was needed. Reproduced with `topopt-cli analyze` on both jobs. App side is #362's. | one plain line + offer the strengthen route; through the reviewer | S |
| E-05 | core/src/fea (multigrid / matfree hot path) | slow | H | Measured on today's Release CLI: the solve is 77 % of the optimisation loop on Top Motor Mount and Stand v4, at about 1,500 CG iterations per solve (iterations.csv, `cg_iters`). The preconditioner is not doing its job on these parts (the history calls it "stagnated-latched"). | read the earlier solver handoffs, then review the hot path only (ruling 2) | L |
| S-07 | core/src/simp/lattice_density_field.cpp:265-598; mma_joint.cpp; minimize_plastic.cpp:1111-1425; simp.cpp:98, 3389 | candidate review for G4a (ruling 1) | M | What Mode 2 is: a second RBF coefficient field (beta, on the PLSM basis code) gives each voxel of a marked region a lattice density between a band's low and high through a smooth step; a Jacobian chains sensitivities back to the coefficients; stiffness comes from a homogenised cubic tensor of the old lattice model; a joint MMA moves solid and beta together. What it cannot do for his G4a: (1) it is wired to the SIMP loop only, PLSM ignores it; (2) it prices the lattice with the old homogenised law, not the new engine's measured strut laws or its two-line minimum; (3) the lattice lives only inside regions the user marked AND that are frozen solid, so it treats his placement as fixed, where he asked for guidance it may extend, shrink or move; (4) strength is not in the objective (the measured -78 % margin); (5) one cell type per run. Read (code only). | keep the field + chain-rule idea; rebuild on PLSM with the new engine's laws and a stress measure (research 3c) | L |
| V-01 | core/src/voxel (face -> voxel tagging: `mask_step_face`, anchor / load tagging); loadcase.cpp:773-789 | bug | H | The set of voxels that carry an anchor or a load depends on grid alignment. On Base (a thin plate) the anchor-and-load pad captures 3.0x more voxels from res 64 to 96 and only 1.2x more from 96 to 128; the as-drawn margin swings 0.67 / 0.18 / 0.40 / 0.17 / 0.30 / 0.08 with it. Measured (section F-2). The tagging code itself is NOT yet read. | read voxel/, then fix: apply loads and supports on the true face (area-weighted), independent of the grid | M |
| X-05 | core/src/cli/run_job.cpp: `keep_clear_exact` (called at :1038) and its retry / warning (about :880-912); finish_and_recheck :1312-1327 | bug | H | On his Stand v4 at res 96 the exact keep-clear cut leaves a non-manifold file ("2 edge(s) on more than two triangles and 4 point contact(s) after three tries"). The re-check cannot import it, both the slim and the safe finish fail the same way, and a version whose strength passed (1.89 against 1.5) is refused. Result after 58 minutes: no versions. Reproduced once with the released CLI; the cut code itself is NOT yet read. | read the cut, then fix or fall back to the uncut finished mesh with a plain line | M |

## C. Probes run during the review (no project code run or changed)

**C-1. Stair-step made by the export step alone** (script: `~/dev/TopOpt/agent-scratch/toreview/export_chain_probe.py`, a line-for-line emulation of mesh.cpp:392-494 at the app's `smooth_factor = 2`). Input: the exact fill fractions of a PERFECT shape. Output: distance of the exported 0.5 surface from that shape, before the finish runs.

| true shape | max error | RMS | at his 1.705 mm voxel |
|---|---|---|---|
| flat wall on the grid axes, 0.3 voxel off a voxel face | 0.096 voxel (a constant shift) | 0.096 | 0.16 mm shift |
| wall tilted 45 deg (1,1,0) | 0.014 | 0.013 | 0.02 mm |
| wall tilted 26.6 deg (1,2,0) | 0.088 | 0.066 | 0.15 mm max, 0.11 mm RMS |
| wall tilted 18.4 deg (1,3,0) | 0.091 | 0.070 | 0.16 / 0.12 mm |
| wall tilted 11.3 deg (1,5,0) | 0.094 | 0.070 | 0.16 / 0.12 mm |
| wall on (1,1,1) | 0.053 | 0.034 | 0.09 / 0.06 mm |
| wall on (1,2,3) | 0.074 | 0.052 | 0.13 / 0.09 mm |
| round hole, 5.1 mm radius | 0.113 | 0.066 | 0.19 / 0.11 mm |
| round hole, 10.2 mm radius | 0.111 | 0.065 | 0.19 / 0.11 mm |
| sphere, 13.6 mm radius | 0.115 | 0.061 | 0.20 / 0.10 mm |

Reading: with a perfect design behind it, today's export still ripples a sloped or curved wall by up to 0.2 mm, once per voxel. His target is 0.05 mm. The finish then moves vertices by at most a quarter voxel; how much of this it removes is measured on real runs in Phase 2. This confirms X-04 and makes X-01 (mesh the optimiser's own smooth field) the first fix to test.

## D. Phase 2 baseline (IN PROGRESS)

Engine: the released worker CLI, core `34c39df96ffd`, `CMAKE_BUILD_TYPE=Release` (`-O3 -DNDEBUG`), 6 threads. Jobs are his own worker jobs, read in place; outputs go to `~/dev/TopOpt/agent-scratch/toreview/baseline/`. Surface numbers: `measure_surface.py` (quadric fit over 3 mm and 6 mm patches; patches that hold a sharp edge are counted apart).

| part / job | res | time | result | margin (needs 1.5) | mass | surface, sloped and curved walls |
|---|---|---|---|---|---|---|
| 2040 Extrusion Stand (original), minimise plastic, his job of 10-29 | 64 | 64 s | ONE version; 77.3 % of the part is frozen (protected faces at 5 mm, pads, keeps), so every lighter rung is skipped | 4.70 (file re-check 4.73) | 90.5 g | 3 mm patches: median 0.10 mm, 90th pct 0.33 mm, worst 0.57 mm; 69 % of patches over his 0.05 mm target. 6 mm patches: median 0.38 mm. Finish reports 21.7 % of stair-step removed. |
| same, res 128 (voxel about 1.7 mm) | 128 | 508 s | ONE version; 74.2 % frozen; no sealed void | 2.40 (file re-check 2.41) | 86.6 g | 3 mm patches: median 0.16 mm, 90th pct 0.33 mm, worst 0.40 mm; 98 % of patches over 0.05 mm. Finish reports 16.3 % of stair-step removed. |
| Base, minimise plastic, his job of 11-20 (1,000 N) | 96 | 119 s | NO version. The first lighter version (68 %) failed: margin 0.40 | as drawn, solid: 0.40 (peak 33.4 MPa) | - | no file |
| Pressing Plate Mount, his job of 11-20 (1,000 N) | 96 | 340 s | NO version. 68 % failed: margin 0.35 | as drawn, solid: 0.35 (peak 38.0 MPa) | - | no file |
| Base, STRENGTHEN, his jobs of 11-20 (two design boxes) | 96 | 109 s / 146 s | REFUSED, no version: even the design box filled solid reads margin 1.41 / 1.38, under 0.95 x the 1.5 target | as drawn 0.40; box solid 1.41 / 1.38 | as drawn 97.7 g | no file |
| PillowBlock Block Stand (Left), minimise plastic (500 N) | 96 | 246 s | NO version. 68 % failed: margin 1.07 | as drawn: to run | - | no file |
| Top Motor Mount, his job of 11-20 (2 x 24.5 N) | 96 | over 50 min (my 45 min limit cut the last file write; all four rungs solved) | FOUR versions, all pass: 68 / 52 / 38 / 26 % | 1.64 / 1.65 / 1.67 / 1.69 (file re-checks equal) | 105.3 / 103.0 / 100.6 / 98.9 g | 68 %: 3 mm patches median 0.01 mm, 90th pct 0.26, worst 0.57; 35 % of patches over 0.05 mm. 38 %: median 0.04, 90th pct 0.28, worst 0.61; 46 % over. Finish removed 5-15 %. No sealed void. |
| 2040 Extrusion Stand v4, his job of 11-20 (402 N) | 96 | 3,454 s (58 min) | NO version. 68 %: strength passed, then REFUSED because the finished file was not one clean solid (2 edges shared by more than two triangles and 4 point contacts left by the exact keep-clear cut, after three tries, slim and safe finish both). 52 %: margin 1.477, just under 1.5. One sealed pocket, 127 mm3. | 68 %: 1.89; 52 %: 1.48 | - | no file |

Facts these runs add:
- Base and Pressing Plate Mount came back with no version because the part AS DRAWN fails the strength check at his load (0.40 and 0.35 against 1.5), not because there was nothing to remove. He read the empty result as "barely needs optimisation". The app gave him no plain line saying so. On these two parts minimise-plastic can never return anything; they need the opposite (add or move material), which is the G3 case.
- The optimised 68 % design and the solid part read the SAME margin to three digits (Base 0.4017 against 0.4019; Pressing 0.3519 against 0.3532). So the peak sits where the design cannot change it: at a frozen load or anchor region. One voxel at a boundary condition decides the verdict (A-02).
- Every run so far (stand at 64 and 128, Base, Pressing) stopped by "margin-plateau" with the peak at iteration 10, the FIRST probe. When a frozen region sets the margin it never improves, so the rule ends every run at iteration 40 whatever the design is doing (new row P-15).
- The margin is not stable across resolution on the same job: 4.70 at res 64, 2.40 at res 128 (peak stress 2.86 MPa against 5.61 MPa). A single-voxel peak on a finer grid reads higher (A-02).
- The stop rule fired at the first probe: margin peak at iteration 10, stop by "margin-plateau".
- On his stand "minimise plastic" has almost nothing to work with: 77 % frozen. The strengthen route's earlier results (11-03, older core) sit at its 2 % floor with margin about 3.1 against 1.5. So on this part the answer is set by what is protected, not by the optimiser.
- Top Motor Mount: four rungs, 12 to 18 minutes each, move the mass from 105.3 g to 98.9 g (6 %) and the margin from 1.64 to 1.69. Most of the part is frozen, so the ladder spends 50 minutes for 6 g.
- Run time is the SOLVE: Top Motor Mount 77 % of loop time (2,325 of 3,001 s), Stand v4 77 % (2,015 of 2,615 s). The solver takes about 1,500 CG iterations per solve on Top Motor Mount (59,169 over 40 solves in rung 0) and about 530 multigrid cycles per solve on Stand v4. A healthy multigrid-preconditioned solve needs tens. Per the reviewer's ruling 2 this puts the solver's hot path in scope (new row E-05).
- Stand v4: 58 minutes for zero versions. The solve is 76 % of the loop (2,495 of 3,278 s) at about 500 CG iterations per solve. The stop rule's peak was at iteration 20 here, not 10.

Limits of the surface script today: it has no CAD reference, so it cannot yet tell a designed fillet from a ripple or check CAD faces to 0.02 mm; at res 64 the voxel is about as large as the 3 mm patch. Both are fixed before the full table.

BLOCKED for the other reference parts: the Mac holds his worker jobs only for the original 2040 Extrusion Stand (and Carriage Arms). There is no job with his loads for Stand v2 / v3 / v4, Base, Pressing Plate Mount, Top Motor Mount or WallMount; those live in his iPad projects.

## E. Reviewer rulings (2026-11-20 22:08Z, id 2026-11-20T22-08-40.389Z-reviewer-908089)

1. Old lattice files stay out of scope; LatticeReview's file-by-file stage G list is coming. BUT `multiscale` and `frozen_lattice` / Mode 2 are IN scope as prior art for G4a (review as candidates; keep or delete is a Phase 4 decision). Where a surviving old-lattice file is called from the TO path, review only the TO-facing calls.
2. No line-by-line solver review. Phase 2 splits Release run time into solve and everything else on each reference part; if the solve is over half, review only its hot path, after reading the earlier solver work (multigrid "stagnated-latched", GenEO, Krylov recycling).
3. Added to Phase 2: does the margin converge? Margin at 3+ resolutions on at least two reference parts, plotted against voxel size (PR 320 measured peak von Mises growing like h^-0.44 to h^-0.49 at staircase corners). Research 3a/3b must name a strength measure that converges for the certificate: smooth analytic boundary; aggregated normalised stress (Le 2010); stress at a critical distance (Taylor 2008, Eng. Fract. Mech. 75:1696-1705, DOI to verify). Tell him in plain words what this means for the margins he has seen.

Owed from this ruling: read lattice_density_field.cpp, mma_joint.cpp and the multiscale / frozen_lattice blocks properly (S-03, M-06 were outline only); the resolution sweep; the solve-time split.

### Ruling 2026-11-20 23:23Z (id 2026-11-20T23-23-49.309Z-reviewer-d2502b): LatticeReview's stage G answer

Stage G has not started and names no files. References traced at claude/organic-engine 73363bf9.

OUT of scope (review only TO-facing calls):
- survive for samples / new engine / Flexible: lattice_gen, lattice_boundary, lattice_coupon, tpms_gen, lattice_union_volume, lattice_sample;
- survive until the optimiser's lattice VARIANTS move to the new engine: cell_plan, lattice_algorithm, lattice_void, lattice_volume_check;
- split, part kept: organic_lattice, lattice_dc, stepped_plan, grading;
- deleted at stage G: lattice_lslt.

IN scope:
- mma_joint (called from simp.cpp on every SIMP optimisation; corrects S-03, which called it dead);
- lattice_density_field and minimize_plastic.cpp 1019-1094 (multiscale arm), 1096-1425 (lattice as a material over the frozen region, tests only), 2639-2805 (projection, posture, frozen merge), hooks 1862-1879, 2093, 2150-2245: they live or die with the two G4a candidate features;
- the CERTIFICATE IS SHARED: analyze.cpp lattice-posture branches and run_job.cpp 3976-6081 are called by the new engine's strength check (Install 3, run_job.cpp:15735/15753). Any change to how the margin is computed (A-01, A-02, convergence) must say what it does to the lattice strength check and be planned with LatticeReview through the reviewer;
- mine, unchecked by LatticeReview: run_job.cpp 915-2817 (shared helpers) and 13076-14119 (analyze_job).

For the plan:
- G4b today runs through the OLD `lattice_one_variant_pass` (run_job.cpp 7487-11868). Moving variants to the new engine is a JOINT package with LatticeReview; size it in Phase 4.
- lattice_void / lattice_volume_check are not wired into the new engine. `lattice_void_escape` is production's drainability predicate; the robust triple and G4 both need it in the loop.
- Almost nothing can be deleted outright today: mark deletions "after the variants move" where that applies.

## F. Does the margin converge? (ruling 3) First answer: NO

`topopt-cli analyze` on the part AS DRAWN (solid, no optimisation), his loads, same job with only `resolution` changed. Release CLI, core 34c39df96ffd. Needs 1.5 to pass.

| resolution | Base (1,000 N): margin / peak MPa | Pressing Plate Mount (1,000 N) | PillowBlock Stand Left (500 N) |
|---|---|---|---|
| 48 | 0.67 / 20.2 | 0.73 / 18.5 | 1.85 / 7.3 (PASS) |
| 64 | 0.18 / 75.1 | 0.49 / 27.7 | 1.48 / 9.1 |
| 96 | 0.40 / 33.4 | 0.35 / 38.0 | 1.07 / 12.6 |
| 128 | 0.17 / 79.9 | 0.35 / 38.6 | 0.78 / 17.2 |
| 160 | 0.30 / 44.6 | - | - |
| 192 | 0.08 / 164.4 | - | - |

(From the optimised stand, section D: 4.70 at 64, 2.40 at 128.)

Reading:
- PillowBlock: the same solid part passes at 48 and reads half as strong at 128. The peak grows steadily as the voxel shrinks (about h^-0.9 here, steeper than PR 320's h^-0.45), with no sign of levelling off.
- Base: the number does not even move in one direction; it jumps up to 4x between neighbouring resolutions (20 -> 75 -> 33 -> 80 -> 45 -> 164 MPa). Base is a thin plate (10 voxels thick at res 96). This is not a smooth corner singularity; something depends on how the voxel grid happens to fall on the part (load face, anchor, or a thin feature). Cause NOT yet located.
- Pressing Plate Mount: falls, then holds at 0.35 between 96 and 128. Two points are not proof of convergence.
- So the 1.5 threshold is being applied to a number that depends on the resolution he picked. Every pass / fail verdict so far, including "no versions" on Base, Pressing Plate Mount and PillowBlock, carries this.

Next for this section: find WHERE the peak voxel is on Base at 64 against 96 (fields.bin), and whether it is at a load or anchor face; then the same sweep with the peak read away from boundary-condition voxels and with an aggregated measure.

### F-2. Where the peak is, and what does converge (script: `agent-scratch/toreview/peak_where.py` on each run's fields.bin)

| run | voxel mm | peak MPa | volume above half the peak | 99th percentile MPa | mean of the hottest 0.5 cm3 |
|---|---|---|---|---|---|
| PillowBlock 48 / 64 / 96 / 128 | 1.13 / 0.85 / 0.56 / 0.42 | 7.3 / 9.1 / 12.6 / 17.2 | 89 / 43 / 15 / 6 mm3 | 3.4 / 3.5 / 3.7 / 4.0 | 3.1 / 3.3 / 3.5 / 3.7 |
| Pressing 48 / 64 / 96 / 128 | 1.73 / 1.30 / 0.87 / 0.65 | 18.5 / 27.7 / 38.0 / 38.6 | 259 / 124 / 32 / 17 mm3 | 8.2 / 11.4 / 10.9 / 10.6 | 10.1 / 13.0 / 13.7 / 12.7 |
| Base 48 / 64 / 96 / 128 / 160 / 192 | 2.85 ... 0.71 | 20 / 75 / 33 / 80 / 45 / 164 | 744 ... 108 mm3 | 9.3 / 28.6 / 10.7 / 20.6 / 11.2 / 38.8 | 14.5 / 47.4 / 18.2 / 35.9 / 19.4 / 70.9 |

- PillowBlock and Pressing: the peak stays at the SAME spot (PillowBlock at about (29, 55.5, 4.8) mm) and climbs as the voxel shrinks, while the hot volume shrinks towards nothing: a point singularity. Measures taken over a fixed physical volume (99th percentile, hottest 0.5 cm3) hold within about 15-30 % over a 2.7x change in voxel size. So a converging strength measure exists in this data; the single-voxel peak is not it.
- Base is a different defect. Its WHOLE stress field rises and falls 2-4x with resolution (the 99th percentile too), alternating low at 48 / 96 / 160 and high at 64 / 128 / 192. The frozen anchor-and-load pad follows the same pattern: 3,602 / 6,583 / 19,839 / 24,057 / 50,891 / 50,612 voxels, i.e. it grows by 3.0x, 1.2x, 2.1x, 1.0x where even growth would be 2.25x, 1.78x, 1.56x, 1.44x. How many voxels a face on a thin plate captures depends on where the grid happens to fall, and that changes how the part is held and loaded. New row V-01.

## G. V-01 traced (reviewer ruling 2026-11-21 00:15Z: goes first, reported on its own, change nothing)

**Cause.** `tag_face_impl` (core/src/io/face_tag.cpp:105-148, threshold at :121) gives a face to every SOLID voxel whose CENTRE lies within half a voxel of the face. A voxel is solid when its centre is inside the part (voxelize.cpp:290-420), and the grid starts at the part's bounding-box corner (voxelize.cpp:248-268). So the first solid layer under a flat face has its centres anywhere from 0 to 1 voxel below that face, depending on where the face falls in the grid. If that distance is over half a voxel, NO voxel of the flat face is tagged; only stragglers near edges and rounds are. For a flat face it is all or almost nothing, about a coin toss per face per resolution. Faces on the grid's own origin planes are always caught.

`mask_step_face` (face_tag.cpp:162-211, threshold `(depth - 0.5) * h` at :183) has the same rule, so pads and protections are one layer short on the same alignments.

**What the load does then.** `traction_loads` (core/src/fea/assembly.cpp:160-206) spreads the TOTAL force evenly over the exposed faces of whatever voxels were tagged. The force is conserved; the area is not.

**Measured on Base (1,000 N on one flat face), same job, resolution only changed:**

| res | voxel mm | load voxels tagged | loaded area = voxels x h^2 | share of the face | as-drawn margin |
|---|---|---|---|---|---|
| 48 | 2.854 | 1,458 | 11,877 mm2 | whole face | 0.67 |
| 64 | 2.141 | 58 | 266 mm2 | 2.3 % | 0.18 |
| 96 | 1.427 | 5,624 | 11,453 mm2 | whole face | 0.40 |
| 128 | 1.070 | 278 | 318 mm2 | 2.8 % | 0.17 |
| 160 | 0.856 | 15,460 | 11,335 mm2 | whole face | 0.30 |
| 192 | 0.714 | 180 | 92 mm2 | 0.8 % | 0.08 |

Total force in every row: 1,000.28 N (analysis.json `declared_force_resultant_n`).

**The other parts** (loaded area = tagged voxels x h^2):
- PillowBlock Left: 482 / 478 / 465 / 454 mm2 at 48 / 64 / 96 / 128. Stable.
- Pressing Plate Mount: 2,443 / 2,346 / 2,459 / 2,416 mm2. Stable.
- Original stand: load voxels 420 at res 64, 1,846 at 128 (4.4x where 4.0x is even): about 10 % more area at 128. Anchor voxels 556 -> 2,219 (3.99x): stable.
- Top Motor Mount, Stand v4: one resolution only, not yet comparable.
So on those parts the falling margin is the single-voxel peak (A-02), not this.

**Anchored area:** NOT measured separately (no per-face anchor count in the logs), but anchors use the same function (loadcase.cpp:361, 372), so the same coin toss applies. Anchors also clamp every node of each tagged voxel, so the held layer is one voxel thick: its depth shrinks with resolution.

**Two more resolution dependences in the same code:**
- The anchor/load pad is 3 VOXELS deep (`kProductionAnchorPadDepthVoxels`, loadcase.hpp:27): 8.6 mm at res 48, 2.1 mm at res 192 on Base.
- Protection depth is rounded to whole voxels (L-03): Base asked 5 mm, got 5.708 mm at res 96.

**Who else calls this code:** bridge.cpp (9 uses), run_job.cpp (10), face_region.cpp (3), minimize_plastic.cpp (3). So the on-device path, analyze, the lattice strength check and keep/protect masks all share it.

**Size of the fix.** Code: small. (a) Tag the first solid layer under a face whatever the alignment (centre within ONE voxel along the inward normal, not half), or better (b) put the force on the true face: area-weighted from the face's own triangles onto the nearest surface nodes, and clamp the first node layer for anchors. (a) is about 20 lines in face_tag.cpp; (b) is a new function of about 150 lines plus tests. Either changes loads on every job, so every stored reference number in the tests and gates moves once. Also state pad and protection depths in mm.

**What the fix should do to the margins (prediction, not measured):**
- Base: the swings go; the margin follows its "whole face" rows (0.67 / 0.40 / 0.30). It still fails 1.5 and still falls with resolution, because the single-voxel peak (A-02) remains.
- PillowBlock, Pressing Plate Mount: no change (their areas were already stable).
- Original stand: small change (about 10 % area).
- Any part whose loaded or anchored flat face is not on a bounding-box plane can be hit; which of his past results were is unknown without re-running them.

**HIS DECISION on V-01 (2026-11-20, his words): "Keep it in the plan".** No fix ahead of the rebuild. V-01 becomes an early stage of 02-plan.md; the strength-measure comparison is judged after it lands.

## H. Solver: what the earlier work already established (read before the hot path, ruling 2)

From the project's own records (solver hub notes; task `solver-speed-arm-and-diagnose`, 2026-08-14; evidence/2026-08-10-plsm-production):
- The operator sees a MODULUS contrast of 1e9 on the PLSM path, not 1e3: `rho` runs from 1e-3 to 1 and the solver uses `E * rho^3` (plsm.cpp:538, simp.cpp:661). That contrast is what defeats the multigrid preconditioner; earlier production runs took 3,986 to 4,567 CG iterations per solve, today's Top Motor Mount about 1,500.
- GenEO's gate declining is correct by its own cost rule (refresh is 71 % of its threshold); the algebraic coarse space, RBM deflation, void-DOF elimination, a multigrid component sweep, mixed precision and a Metal V-cycle were each measured and rejected. Not to be repeated.
- A level-set probe on this solver (2026-08-09) cost 25 s per iteration against SIMP's 13.6 s, for the same reason.

LINK TO P-14 (hypothesis, not measured): the cube law on PLSM's fill fraction is the same line that (a) makes every boundary voxel read too soft, and (b) creates the 1e9 contrast. A linear ersatz (the normal level-set choice) with the same floor gives a contrast of 1e3. One change may improve both the accuracy of the strength check and the solve time. This is the first thing to measure when the hot path is opened: same design, p = 3 against p = 1, CG iterations per solve and margin.

## I. X-05 traced (reviewer ruling 2026-11-21 02:48Z: next, reported on its own, change nothing)

**What happens, in order.**
1. `keep_clear_exact` (core/src/cli/run_job.cpp:864-903) subtracts the Keep-clear solids from the finished mesh with the Manifold library (`E - C`, :893).
2. The result is then judged "as written" (`audit_as_written`, core/src/mesh/finish.cpp:694-): every vertex is rounded to the 32-bit float an STL stores, and vertices that land on the same float are treated as one. Where the cut surface runs along, or within rounding of, an existing edge or vertex, two separate sheets become joined along that edge: "edge on more than two triangles" and "point contact".
3. It retries twice with a slightly different cutter (`make_keep_clear_cut(..., n)`, :819-856): grown by 0.001 and 0.002 mm, part offset 0.004 and 0.008 mm (:830-831). All three tries left bad edges on his part. WHY the retries do not clear it is NOT established: a 32-bit float near 100 mm steps by 0.0000076 mm, a thousand times finer than the nudges, so float rounding of the nudge is not the reason (I checked and rule it out). The candidate is surfaces that coincide by construction: the finished mesh is snapped onto the CAD's planes and cylinders (cad_project) and the Keep-clear solids are built from the same CAD faces, so the cutter can share a plane or a tangent line with the mesh, and a micron of growth does not change that contact. To confirm it needs the bad mesh kept and its two edges inspected.
4. After the third try it prints the warning and RETURNS THE BAD MESH anyway (:897-903).
5. `finish_and_recheck` (:1281-1349) writes it to an STL and calls `analyze_job`; the importer refuses a non-manifold file (core/src/io/part.cpp:169), which is caught and reported as "not one clean solid" (:1319-1326).
6. `finish_with_fallback` (core/include/topopt/finish.hpp:196-209) then tries the safe finish, which runs the SAME cut on almost the same mesh and fails the same way. The version is refused although its strength passed (1.89 against 1.5).

**Can it hit any job with a Keep clear?** Yes: any job whose finished mesh actually reaches into a Keep clear or keep region (the cut is skipped when nothing is removed, :885). Today: Stand v4 (12 Keep clears, 63 keep regions, 201.9 mm3 cut) failed; Top Motor Mount (39 Keep clears, 82 mm3 cut) succeeded. Two jobs is not a rate.

**Could it fall back to a usable file?** Yes, three ways, cheapest first:
- larger retry nudges (0.01 / 0.02 / 0.05 mm of extra clearance), which costs him at most 0.05 mm around a Keep clear; whether that clears a shared plane or tangent is untested;
- a local repair of the few bad edges (split the shared edge and move the two sheets apart by one float step) instead of discarding the file;
- last resort, hand back the uncut finished file with one plain line. Not recommended on its own: on Stand v4 that file has 201.9 mm3 of material inside his Keep clears, which the re-check would refuse anyway ("A Keep clear has material in it").

**Fix size.** Small: about 30-60 lines in run_job.cpp for the nudges and the repair, plus one test with a cutter that touches a mesh edge. No stored strength numbers move.

**Not verified:** what geometry produces the two bad edges on his file, and whether larger nudges or the local repair clear it. Both need one probe run that keeps the bad mesh.

**HIS DECISION on X-05 (2026-11-20, his words): "Fix it now".** Work on branch claude/topopt-review-rebuild-3c317f, only the Keep-clear cut in core/src/cli/run_job.cpp plus one test. Steps: (1) probe build in this tree that replays Stand v4's export from its stored design (`refinish_job` path, no optimisation) and keeps the bad mesh; (2) confirm the geometry of the two bad edges; (3) fix (wider retry schedule and/or local repair, never return a non-manifold file silently); (4) test in tests/validation/test_keep_clear_exact.cpp; (5) rerun Stand v4; (6) report the diff to the reviewer for #362 to merge and release. The run did not keep `finish_check/v.stl`, so step 1 needs a build, which waits for HEAVY.lock (#362's whole-app suite, from 20:39 EST).

### X-05 CAUSE CONFIRMED and fixed on branch (2026-11-21)

Replayed Stand v4's export from its stored design with a temporary probe build (65 s; probe code removed again). The two bad edges are already in the mesh BEFORE the Keep-clear cut. They come from `keep_regions_exact` (core/src/cli/run_job.cpp:716-787), the step that replaces each KEEP REGION with the part's own solid: `(export - regions) + (part within regions grown 0.05 mm)`.
- His job has two keep boxes that meet only along one edge: x in [-21.525, 21.525], y in [-12.086, -11.395] and x in [21.525, 22.220], y in [-11.395, 12.106] (and the mirror pair at x = -21.525), both reaching above the part's top face (z 69 to 71.98; top at 70).
- The exported mesh stands 0.06-0.07 mm proud of the top face there. Subtracting both boxes leaves the proud skin's other two quadrants touching along the shared edge, and above z = 70 there is no part solid to fuse them. Result: an edge 0.061 / 0.074 mm tall on four triangles at (+-21.5253, -11.3946, 70.0). Measured on the dumped mesh.
- The step's own three retries move the export by 1 micron, which cannot change that contact; the Keep-clear cut's retries act on a later stage. So section I's steps 2-3 named the wrong stage; the rest of the chain (bad mesh returned, re-check cannot import, fallback fails the same way) stands.

FIX (3 files, +45 lines): the regions are grown by 0.01 mm (`kCut`) on the side that is cut out of the export, so neighbours that meet along an edge overlap; the part side is still grown 0.05 mm, so the two pieces still fuse across a volume. New public `fuse_keep_regions` (job.hpp) so a test can reach the step. New test case (k) in tests/validation/test_keep_clear_exact.cpp: two diagonal keep boxes under a 0.07 mm proud skin.
- With the fix off: (k) reads 1 edge on four triangles, 2 point contacts. With it on: 0 / 0 / 0, one body; all 30 checks pass.
- Stand v4 export replay with the fix: "keep" and "finished" stages 0 bad edges, 0 point contacts, on both the 68 % and 52 % designs.
- Effect on other jobs: 0.01 mm more of the export is replaced by the part's own solid around every keep region. No strength numbers involved.
Still running: the other five keep / finish tests and a full Stand v4 run on the fixed build.

## J. Phase 1 second reading pass (2026-11-21): new findings

Same columns as section B.

| id | file:line | kind | sev | evidence | action | size |
|---|---|---|---|---|---|---|
| P-16 | include/topopt/plsm_frac.hpp:284-402; plsm.hpp:148,163 | unclear contract (G2) | M | A cut voxel's fill is the average of 4x4x4 point samples of phi. Default is the softened count (`frac_mollified = true`, `plsm_frac_of_soft`), with a band from an L1 gradient estimate. The hard count (`plsm_frac_of`) steps in 1/64ths and is still reachable by a job key. The exported surface is contoured from this per-voxel number, not from phi. | Rebuild: contour phi itself (ties to P-01/X-01); drop the hard-count path | S |
| P-17 | include/topopt/plsm_frac.hpp:217-230 vs plsm_kernel.hpp:67-82 | bug (small) | L | `plsm_frac_grad_l1` divides by 2h at the grid border where the clamped stencil spans only h, so the band is half-width on border voxels; `plsm_grad_mag` handles the border correctly. | Fix when the fraction code is rewritten | S |
| P-18 | include/topopt/plsm_topology.hpp:145-341 | report only | M | Sealed pockets, tunnels and enclosed solids are counted per result and reported; nothing in the loop or the accept rule acts on them (Stand v4: one sealed pocket of 127 mm3 shipped in a passing version). | Plan: sealed pocket becomes a rule (03-rules), enforced in the optimiser or refused at accept | M |
| C-02 | src/mesh/cad_project.cpp:216-241, 244-345 | wrong contract (G2) | M | A mesh vertex is tied to the nearest CAD triangle within ONE voxel and moved up to one voxel onto that face. No check that the vertex's surface faces the same way as the CAD face. An optimised wall that runs within a voxel of a drawn face is pulled onto it; only the fold guard objects. At res 64 on the stand that is 1.7 mm. | Rebuild: decide "this surface IS the drawn face" from the frozen/part mask in the optimiser, not by distance after the fact | M |
| C-03 | src/mesh/cad_project.cpp:501-565 | bump source (G2) | M | Vertices next to a snapped patch get a linearly fading share of the move over a few rings. That leaves a crease where the fade ends; curvature flow then has to remove it. | Goes away with C-02 | - |
| C-04 | src/mesh/cad_project.cpp:644-745 | slow | L | The fold guard rebuilds a std::map of every vertex (float keys) on each of up to 64+64 passes. | Rewrite with a hash grid if the step survives | S |
| C-05 | src/mesh/cad_project.cpp:864-948 | useful | - | `measure_flats` and `measure_bores` already report, per drawn face, flatness and bore roundness of the exported mesh. | Use as the Phase 2 "CAD faces flat within 0.02 mm" measure and in 04-tests | - |
| F-05 | src/mesh/finish.cpp:351-442 | bump source (G2) | M | Thin-spot cleanup pushes each thin vertex outward along its own normal by 0.51 x the shortfall, up to a fixed number of passes, with no smoothing of the neighbours. It thickens after the strength check and leaves a local bulge. | Rebuild: minimum wall as an optimiser rule (two lines), not a mesh patch | M |
| R-03 | src/cli/run_job.cpp:18078-18571 | prior art (G3) | H | "Strengthen" is already "lightest part that reaches a target margin": a search on material fraction, each probe a full optimise. Per version: up to kStrengthenCoarseRuns coarse runs at half resolution, then up to kStrengthenRepairs+1 fine runs, each fine run verified on the exported file. Three versions, each 10% over the last. | G3 design starts from this; replace the outer search by a strength constraint inside one run | L |
| R-04 | src/cli/run_job.cpp:18170-18171, 18304-18316 | logic (G3) | H | The coarse search picks the material fraction from the margin at half resolution. Section F shows the margin does not hold between resolutions (PillowBlock 1.85 at 48, 1.07 at 96), so the coarse answer is not the fine answer. | Needs the converging margin measure (after V-01) | - |
| R-05 | src/cli/run_job.cpp:18504-18505 | unnecessary mass (G3) | M | A fine run that misses the target is retried with at least 25% more material (`max(1.25, ratio^(1/gamma))`). A miss by 2% costs 25% mass. | Replace with a bracket on the fine grid, or the in-run constraint | S |
| R-06 | src/cli/run_job.cpp:18275 | arbitrary | L | First guess of material fraction is (target / solid-box margin)^(1/1.5). | Document or replace | S |
| R-07 | src/cli/run_job.cpp:20552-20600, 21136-21271 | logic | H | On the normal (not Strengthen) path each version is streamed to the app with its STL as soon as the loop accepts it, but the check of the exported file runs only after the whole ladder ends. A version can appear, then be deleted an hour later (`FINISH status=refused`). Stand v4 before the X-05 fix did exactly this. | Check each version's file when it is made; never stream an unchecked file | M |
| R-08 | src/cli/run_job.cpp:18557-18564 | unclear contract | M | Strengthen overwrites the loop's own "rejected" verdict with accepted when the file check passes (`shown.accepted = true`, rejected list cleared). Two judges, the second silently wins. | One accept rule in the rebuild (03-rules) | S |
| R-09 | src/cli/run_job.cpp:19756-19869 | prior art (G4a) | M | The multiscale block: refuses unless `production_multiscale_lattice_to()`; builds a region mask from the lattice include regions, raises `min_feature_mm` to half the lattice's cells-per-member floor times the floor cell size, and warns when under half the region is free to optimise. The app never sends `multiscale`. | Read with minimize_plastic's multiscale couplings for 3c | - |
| M-07 | src/simp/analyze.cpp:65-74, 112-130; settings/report.cpp:574-599 | contract (G3) | H | The margin he sees is (yield / peak stress of the SOLID part) x (infill/100)^1.5, floor 0.001. Stand v4: 5.35 x 0.354 = 1.89 at 50% infill. The reported mass and "saved" are the solid volume. So strength assumes his infill, weight does not. The 52% rung failed at 1.477 and the diagnosis itself says 51% infill would pass. | G3 must state what "weight" is (printed grams at his settings) and treat infill as a lever beside shape | M |
| V-02 | src/voxel/voxelize.cpp:240-416 | contract (G2) | M | The part grid is yes/no per voxel (centre inside the mesh), origin at the bounding-box corner, spacing = longest side / resolution. Every drawn face that is not on the box is a staircase to the optimiser from the start. Same root as V-01 and P-04. | Part of the V-01 stage: partial-fill voxels (or a signed distance) for the drawn part | M |
| V-03 | src/voxel/voxelize.cpp:431-465, 1413 | weak rule | M | "Minimum feature" = every printed voxel sits in some fully printed 2x2x2 block. It is in voxels, so it means 3.4 mm at res 64 and 1.1 mm at res 192, and it only counts (Stand v4's rejected rung: 3,687). His rule is two lines / 0.9 mm. | 03-rules: wall rule in mm, enforced | M |
| V-04 | src/voxel/voxelize.cpp:1164-1296 | bump source (G2) | M | When the design splits a load from its anchor, a straight voxel path of fixed radius is stamped to density 1 after the optimiser has finished (up to 64 bridges). It is a square bar, not optimised, and the strength check then judges it. | Rebuild: connectivity kept inside the optimiser; no post-stamp | M |
| V-05 | src/voxel/voxelize.cpp:969-1134 | duplicate | L | Connected pieces are computed three ways for one result: 26-connected voxels (`printed_bodies`), mesh components (`count_components`), and the level-set topology count (P-18, 6- and 26-connected). | One piece count in the rebuild | S |
| S-08 | src/simp/simp.cpp:2139-3890, 4113-4500; minimize_plastic.cpp:798, 1633-2010, 2266 | not run for him (G1) | H | The SIMP optimiser (two `simp_optimize` overloads, the stress-constrained one, `simp_optimize_variants`) and the ladder driver's SIMP-only machinery (warm start, projection escalation, draft, SEMDOT refusal) run only when a job has no `plsm` block. The app always sends one. The code's own default is still SIMP (`PlsmMode::Off`, "the entire existing world"). About 2,300 lines in simp.cpp plus a large share of `minimize_plastic`. Only `simp_compliance`, `simp_scenarios_compliance`, `effective_design_mask` are shared. Not read line by line, on purpose: it is proposed for removal. | Plan: split the three shared pieces out; delete the SIMP loop after stage G (Mode 2 prior art is read first) | L |
| J-01 | src/cli/job.cpp:1356-1470 (plsm block), whole file | experiment knobs (G1) | M | The job schema reads 171 distinct keys. The `plsm` block alone takes 21; the app sends one (`enabled`). The rest are experiment switches that only a hand-written job reaches. | Rebuild: one small TO block; knobs that never shipped are removed with their code | M |
| B-04 | src/fea/matfree.cpp:365, multigrid.cpp:1338-1363; run_info of Stand v4 | switch off | M | A single-precision V-cycle exists (`mixed_precision`) and is off in his runs. Stand v4's receipt: `mixed_precision false`, 6 threads (the Mac has 6 fast + 4 slow cores, 16 GB), 4 multigrid levels, GenEO armed but never built (`geneo_basis_builds 0`, trigger 500 iterations), Krylov recycling on (dim 16). | Measure in the p=3 / p=1 probe tree: mixed precision on/off, same answers | S |
| B-05 | src/fea/fea_matfree.hpp:56-59, matfree.cpp:111-124, 536-554, 596-610 | slow by design | M | Every matrix-vector product walks one 104-byte record per element (24 stored dof numbers + modulus), does a dense 24x24 product, and copies the vector into and out of a full-size scratch. On a regular voxel grid the dof numbers follow from (i,j,k). One CG iteration costs pre + post + 2 such products. The iteration COUNT (500 to 1,500 per solve, section H) is still the bigger lever. | Research 3 (speed): fewer iterations first (stiffness contrast), then a leaner product | M |
| B-06 | src/fea/multigrid.cpp:1283-1296 | weak method | M | The fine smoother is damped Jacobi (plain, point-block or l1). Section H lists what was tried before; a Chebyshev smoother on the same product is not in that list. | Research 3: check the earlier notes, then one measurement | S |

**S-06 re-checked (2026-11-21):** stands. Five separate MMA solvers: `mma_update_joint` (mma_joint.cpp, called by `mma_update` simp.cpp:1470 and `mma_update_masked` :2884), `mma_update_projected` (:1546), `mma_update_masked_projected` (:3015), `mma_update_stress` (:4163), `plsm_mma_update` (plsm_mma.hpp). Only the last runs for him.

**Phase 1 reading status (2026-11-21):** read as code: plsm_frac/kernel/topology headers, cad_project.cpp, finish.cpp thickness and thin-spot code, `strengthen_versions`, `run_job` (all but the old-lattice forecast 18640-19390, the lattice export lambdas 19600-20465 and the receipt writer 20662-20968), voxelize.cpp (voxelise, min-feature, bodies, bridges, V3), settings (recommend, margin formula), the solver's product, V-cycle and CG loop. Outline only, by choice: SIMP optimiser bodies (S-08, proposed for removal), observability.cpp (receipts), io/ (import/export), orient/ (build-direction scoring), main.cpp (command list), job.cpp (schema: key census only). None of those decide a shape.

| id | file:line | kind | sev | evidence | action | size |
|---|---|---|---|---|---|---|
| I-02 | include/topopt/step.hpp:29-30; src/io/step.cpp:86-87, 231 | contract (G2) | M | A STEP part is turned into triangles once, at 0.1 mm chord error and 0.5 rad. Everything after uses those triangles: the voxel grid, and the Keep-region step that puts "the original part" back into the export. A drawn bore therefore comes back as flats up to 0.1 mm off round, twice his 0.05 mm target, before the optimiser has done anything. Only the CAD snap (planes and cylinders) corrects it, and only where it attributes the vertex. | 03-rules: state the tolerance for drawn curved faces; tessellate finer (or per face) for the export side | S |

## K. Stiffness rule: cubed against linear (reviewer-approved measurement, 2026-11-21)

Probe tree `toreview-probe-p1` (local branch, never merged): two environment switches at minimize_plastic.cpp:1017 and run_job.cpp:13447 set the exponent and the void floor for the optimiser, its in-loop check and the file re-check. Unset = today's engine. Release build, 6 threads.

Arms: p3 = today (stiffness = fill^3, floor 1e-3, so empty = 1e-9 of full); p1 = stiffness = fill, empty = 1e-3; p1lo = stiffness = fill, empty = 1e-6.

| part | arm | wall s | solver s | CG iterations (40 design steps) | margin (shown) | file re-check | mass g |
|---|---|---|---|---|---|---|---|
| Original stand, res 128 | p3 | 496 | 235 | 6,106 | 2.397 | 2.410 | 86.55 |
| | p1 | 536 | 272 | 7,420 | 2.413 | 2.412 | 86.56 |
| | p1lo | 361 | 63 | 318 | 2.395 | 2.407 | 86.47 |
| PillowBlock Left, res 96 | p3 | 214 | 73 | 4,167 | 1.067 (refused) | - | - |
| | p1 | 213 | 73 | 4,162 | 1.070 (refused) | - | - |
| | p1lo | 214 | 74 | 4,179 | 1.065 (refused) | - | - |

What it says:

1. The switch works (first-step compliance differs: stand 52.128 / 51.998, PillowBlock 14.950 / 13.504).
2. Solve time does NOT fall with the linear rule on these parts: same on PillowBlock, 21% MORE iterations on the stand. The hypothesis in section H (linear stiffness cuts solver work) is not supported here.
3. The margin moves by under 1% (P-14's suspected boundary bias from cubing is not visible on these parts).
4. Stand p1lo is not a speed-up: the design did not move at all (compliance 52.12767 at step 1 and at step 40), so the warm-started solves were nearly free. Not explained yet; PillowBlock p1lo moved normally.
5. LIMIT: both parts ran one rung only (74% and 68% material) and are mostly frozen, so few voxels are partly filled. A heavily carved part is needed before concluding: Top Motor Mount below.

Second half, Top Motor Mount res 96 (4 rungs, 68% to 26%; about 1,500 CG iterations per solve):

| arm | wall s | solver s by rung | CG iterations by rung | design steps by rung | shown margin by rung | file re-check by rung | mass g by rung |
|---|---|---|---|---|---|---|---|
| p3 | 3,260 | 451 / 468 / 480 / 728 | 59,169 / 63,120 / 64,806 / 98,214 | 40 / 40 / 40 / 60 | 1.641 / 1.650 / 1.672 / 1.690 | 1.641 / 1.649 / 1.671 / 1.686 | 105.33 / 103.03 / 100.65 / 98.86 |
| p1 | 3,592 | 457 / 475 / 479 / 979 | 59,004 / 62,678 / 64,591 / 131,671 | 40 / 40 / 40 / 80 | 1.641 / 1.643 / 1.657 / 1.685 | 1.641 / 1.643 / 1.659 / 1.676 | 105.21 / 102.95 / 100.86 / 98.76 |

6. Per solve the two rules cost the same (1,480 to 1,640 CG iterations either way). The linear arm is 10% slower overall only because its last rung took 80 design steps instead of 60.
7. Margins agree within 1% on every rung, masses within 0.2 g. All four versions accepted in both arms.
8. CONCLUSION on three parts: the cubed rule is not what makes the solves slow and it does not bias the margin measurably. The exponent stays; P-14's bias worry is closed as "not measurable"; the section H hypothesis is withdrawn. The solver cost itself stands: 65% of this run is solve time at about 1,500 iterations per solve (S-items in section D).
9. Seen in passing: on this part the ladder's 68% to 26% changes the printed mass by only 6% (105 to 99 g) and the margin rises as material falls (1.64 to 1.69), so the rung percentage says little about the weight saved (ties to M-07).

Mixed precision (reviewer-approved, same probe tree, Top Motor Mount res 96, 2026-11-21): with the switch on (run_info echoes `mixed_precision: true`) the run is BIT-IDENTICAL to the cubed arm: same CG iterations on every rung (59,169 / 63,120 / 64,806 / 98,214), same margins, same STL bytes; wall 3,504 s against 3,260 s (rung 0 solve 644 s against 451 s, rungs 1 to 3 equal, so machine load, not the switch). So the single-precision V-cycle never ran on the production path: the guard at multigrid.cpp:2925 (`fine_dinv_f.size() == m.ng && !m.has_cubic`) or the route to it is not met on this job (no lattice, so not the cubic guard; which condition is not traced). Reading: the capability is dead as wired, and handoff 132 (production.cpp:604) measured 20% MORE iterations when it did run, with a mechanical reason (CG tolerance 1e-8 is at single precision's limit). NOT a "not possible" finding: it is "not measured, switch inert". Plan entry: either delete the FP32 path (clean-up) or revive it only together with a looser inner tolerance; no further measurement until the solver stage.

## L. Today's print files against the CAD (stage 0, 2026-11-23)

Tool: `cad_project_probe` (Release, built at 13c6a7fd), on files already in the baseline. Each vertex within one voxel of a drawn flat or bore is measured against that face's own plane, axis and radius from the CAD. Target (rule 9): flats within 0.02 mm, bores round within 0.02 mm.

| part (lightest version, 0.68) | voxel | drawn flats: typical / worst distance from the plane | flats within 0.02 mm | bores: typical / worst out-of-round | bores round within 0.02 mm |
|---|---|---|---|---|---|
| Top Motor Mount, res 96 | 1.41 mm | 0.24 / 1.39 mm | 12 of 45 | 0.19 / 1.70 mm | 16 of 61 |
| 2040 Stand (original), res 128 | 0.99 mm | 0.89 / 0.99 mm | 0 of 11 | 0.94 / 1.44 mm | 2 of 24 |
| 2040 Stand v4, res 96 | 1.32 mm | 1.19 / 1.32 mm | 1 of 19 | 0.26 / 2.59 mm | 0 of 7 |

"Typical" is the median over faces of each face's worst vertex. Faces with fewer than 50 vertices are left out.

What this can and cannot claim:
- It is an UPPER bound. The tool counts every vertex within one voxel of a drawn face as belonging to it, so a wall the optimiser legitimately cut close to a face is counted as drift. The worst figures sit at almost exactly one voxel for that reason.
- What is solid: where a face is untouched (16 bores and 12 flats on Top Motor Mount) the file is exact to the triangle chord (0.02 mm); everywhere a cut wall meets a drawn face, the file leaves the face by up to a voxel. That is the seam the plan's stage 3 removes (C-02, C-03).
- A clean number needs membership ("this vertex is on face N") from the part-in step, not nearness. Test B is written that way in stage 0.

Base, Pressing Plate Mount and PillowBlock (Left) give no print file today (section D table: the part as drawn fails the strength check, so no version is returned), so they have no row here. Re-run 2026-11-23 on the Release build at 13c6a7fd with the same outcome: Pressing 335 s, Base 121 s, Pressing strengthen 325 s (as drawn 0.35, ceiling 0.40 against 1.5), no version.

Stand v2, Stand v3 and WallMount are left out of the "today" table by the maintainer ("Skip those parts", 2026-11-23); they are measured after the rebuild stages only.

Still owed for the "today" table: slicer pictures.
