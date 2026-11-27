// to_setup.inc -- build_job_setup: the one job setup every TO entry point shares.
//
// TO rebuild stage 0 (docs/design/to-rebuild/05-workplan.md): moved out of
// run_job.cpp unchanged, line for line. This is NOT a translation unit: it is
// included by run_job.cpp at the place the code used to stand, inside
// namespace topopt, so every name resolves exactly as before. Do not compile
// it on its own and do not include it anywhere else.


// ---------------------------------------------------------------------------
// THE ONE job setup (task 2026-08-03-preflight-feasibility-and-divergence).
//
// Everything between "the model has been imported" and "the domain can be
// resolved": the mode branch (declared load case vs self-weight), the option
// mapping (build direction, draft, warm start) and the load-case receipt. It was
// inline in run_job until the PRE-FLIGHT needed to reach the same state WITHOUT
// running the ladder — and a second, similar setup could easily pre-flight a
// different job than the one that then runs. run_job calls this; preflight_job
// calls this; there is no second derivation.
struct JobSetup {
  VoxelGrid grid;                  // the PART grid, tagged
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;
  ProductionLoadCase lc;           // empty on the self-weight path
  std::vector<int> fixture_face_ids;
  std::string loadcase_receipt;    // the bar-Z2 document, not yet written
};

JobSetup build_job_setup(const JobDescription& job, const StepModel& model,
                         bool model_is_mesh, const MaterialLibrary& materials) {
  JobSetup S;
  VoxelGrid& grid = S.grid;
  std::vector<DirichletBC>& bcs = S.bcs;
  MinimizePlasticOptions& options = S.options;
  ProductionLoadCase& lc = S.lc;
  std::string& loadcase_receipt = S.loadcase_receipt;
  // Two modes, both driving the SAME production optimizer configuration as the
  // iPad app (handoff 093): a "loads" block => the shared build_production_loadcase
  // (anchors + declared forces, the app's mode a); otherwise the self-weight +
  // fixture_faces path, now also carrying the production solver config + optional
  // design box so it matches what the app produces for the same input.
  // The load-case RECEIPT (bar Z2) — built here, where the resolution facts are
  // still in scope, and written once the output directory exists. See
  // loadcase_receipt_json: this is the document a later re-lattice run is
  // compared against to prove it certified under the SAME load case.
  // The resolved load case, hoisted out of the mode branch so the PRE-FLIGHT
  // below can name the clearance / load group a refusal is about. Left default
  // (no groups, no clearances) on the self-weight path.

  if (job.loads.present) {
    // ── LOADCASE mode: resolve the geometric selectors to face ids, build the
    // front-end-neutral ProductionLoadCase, and hand it to the SAME core builder
    // the bridge calls. The CLI and app therefore produce the same design for the
    // same STEP + load case + resolution.
    lc = production_loadcase_from_job(job, model);
    S.fixture_face_ids = lc.anchor_face_ids;

    ProductionRunSetup setup;
    try {
      setup = build_production_loadcase(model, job.resolution, lc);
    } catch (const JobError&) {
      throw;
    } catch (const std::exception& e) {
      // The builder's diagnostics name the id / count / selection (N5); add
      // the one fact it cannot know — which mesh the ids were resolved against.
      throw JobError(std::string("run: cannot build the declared load case "
                                 "against model \"") +
                     job.model + "\": " + e.what());
    }
    // Legible twin of minimize_plastic's require_external_loads guard (which
    // stays in place as the hard backstop): refuse HERE, where the per-group
    // reports can say WHICH group resolved to nothing and WHY (N4), instead of
    // the optimizer's generic "external_loads is empty".
    if (setup.options.require_external_loads &&
        setup.options.external_loads.empty())
      throw JobError(
          "run: the declared load case produced NO external load — " +
          no_external_load_message(setup, job.resolution) +
          ". Refusing to silently optimize under SELF-WEIGHT instead of the "
          "declared load.");
    grid = std::move(setup.grid);
    bcs = std::move(setup.bcs);
    options = std::move(setup.options);
    // Before `setup.options` is consumed: external_loads is still readable off
    // the moved-to `options`, and the reports were not moved.
    {
      ProductionRunSetup echo;
      echo.options.external_loads = options.external_loads;
      echo.load_group_reports = setup.load_group_reports;
      echo.clearance_reports = setup.clearance_reports;
      echo.face_protection_reports = setup.face_protection_reports;
      // Task 2026-08-12 §1f — the anchor pad, counted apart. Missing this line
      // wrote `anchor_pad: {applied: false, voxels_frozen: 0}` into the receipt
      // while the log said 32,648 on the maintainer's own job: the receipt
      // contradicting the log about the very thing the block exists to explain.
      // (The comment above says every new setup field has to be added here too;
      // it was right, and I still missed it. `s0_table.py` reading a 0 is what
      // caught it.)
      echo.anchor_pad_report = setup.anchor_pad_report;
      // ★ AND IT BIT AGAIN (task 2026-08-14-face-regions). This branch added
      // `face_region_reports`, emitted the block that writes them, watched
      // loadcase.json come out WITHOUT it, and found the missing line here —
      // three warnings deep in comments that all said "every new setup field
      // has to be added here too". A hand-copied list cannot notice a field it
      // was never told about. THE FIX IS THE ONE `production_loadcase_from_job`
      // ALREADY USES: decompose by structured binding so the language forces
      // every member to be named. It is not done here because the echo copies a
      // deliberate SUBSET (setup.options has been moved from by this point), so
      // the binding needs a `(void)` line per skipped field — worth doing, and
      // out of scope for this branch's diff.
      echo.face_region_reports = setup.face_region_reports;
      // Task 2026-08-03-growth-ladder — carry the ladder mode and what it needed
      // onto the echo too, or the receipt would silently report a growth run as a
      // reduction one (the echo is a hand-copied subset, so every new setup field
      // has to be added here as well as there).
      echo.growth_ladder = setup.growth_ladder;
      echo.growth_box_auto_derived = setup.growth_box_auto_derived;
      echo.growth_box = setup.growth_box;
      echo.growth_anchor_pad = setup.growth_anchor_pad;
      loadcase_receipt = loadcase_receipt_json(job, &echo,
                                               S.fixture_face_ids, 0, bcs);
    }
    // The CLI exports meshes, not playback: keyframe_count stays 0 (the app sets
    // 12). This is viz only and does not change the design.
  } else {
    // ── SELF-WEIGHT mode: geometric fixture-face selection (locked rule,
    // DECISIONS.md 2026-07-09).
    S.fixture_face_ids =
        resolve_selectors(model, job.fixture_faces, "fixture_faces");

    // ──▶ voxelize + tag the fixture voxels of every matched face. The tag call
    // is source-appropriate in NAME only (tag_mesh_face and tag_step_face run
    // the identical scan over `triangle_face`); a mesh pseudo-face tags exactly
    // as a B-rep face does.
    grid = voxelize(model.mesh, job.resolution);
    std::size_t tagged = 0;
    for (const int f : S.fixture_face_ids)
      tagged += to_stage1_on()
                    ? tag_face_by_stage(grid, model, f, VoxelTag::Fixture)
                    : model_is_mesh
                        ? tag_mesh_face(grid, model, f, VoxelTag::Fixture)
                        : tag_step_face(grid, model, f, VoxelTag::Fixture);
    if (tagged == 0)
      throw JobError("fixture faces tagged no voxels (resolution too coarse "
                     "for the selected faces?)");

    // Mounting BCs: every node of every Fixture voxel is fully clamped.
    const std::vector<int> fixture_nodes =
        fea_tagged_nodes(grid, VoxelTag::Fixture);
    bcs.reserve(fixture_nodes.size() * 3);
    for (const int n : fixture_nodes)
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    loadcase_receipt = loadcase_receipt_json(
        job, nullptr, S.fixture_face_ids, tagged, bcs);

    // ──▶ FEA + SIMP ladder + report assembly (the M5.3 driver). The production
    // solver config (matrix-free multigrid + Galerkin cache + physical
    // min-feature) is applied here so the CLI matches the app; the job supplies
    // the self-weight load case (ladder, margin, gravity).
    configure_production_options(options);
    // The material catalog the GATE DIAGNOSIS prices its material lever against
    // (handoff 2026-08-02-gate-diagnosis-recommendations). READ ONLY — nothing
    // downstream writes materials.json — and `materials` outlives this call, so
    // the pointer is valid for the whole run. Without it the material lever
    // reports itself NOT EVALUABLE instead of guessing.
    options.material_catalog = &materials;
    options.volume_fraction_ladder = job.ladder;
    options.margin_stop = job.margin_stop;
    options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
    options.gravity_direction = job.gravity.direction;
    if (job.simp_max_iterations > 0)
      options.simp.max_iterations = job.simp_max_iterations;
    // Optional design-domain expansion (the "add material" feature).
    if (job.has_design_box) {
      options.design_box = to_design_box(job.design_box);
      for (const JobBox& ko : job.keep_out_boxes)
        options.keep_out_boxes.push_back(to_design_box(ko));
    }
  }
  // The build-plate normal, separated from gravity (handoff
  // 2026-08-01-build-direction-separation). AFTER the mode branch so it governs
  // both modes; absent key => byte-identical.
  apply_build_direction_options(options, job);

  // Handoff 2026-07-25-draft-quality — map the optional "draft" block onto the
  // production options, for BOTH front-ends (loadcase options come from
  // build_production_loadcase; self-weight from configure_production_options). Absent
  // (has_draft == false) => the options keep their OFF defaults, byte-identical.
  if (job.has_draft) {
    options.draft_quality = job.draft_quality;
    options.draft_loose_tol = job.draft_loose_tol;
    options.draft_escalation_c_gap = job.draft_escalation_c_gap;
    options.draft_use_design_trigger = job.draft_use_design_trigger;
    options.draft_escalation_design_flip = job.draft_escalation_design_flip;
    options.draft_probe_iters = job.draft_probe_iters;
  }

  // Handoff 110 Part B — map the optional "warm_start" block onto the production
  // options, for BOTH front-ends, exactly like the "draft" block above. Absent
  // (has_warm_start == false, the default) => options.warm_start_coarse keeps
  // its OFF default and the run is byte-identical. run_info already echoes the
  // resolved value (info.warm_start_coarse), so an armed run SAYS it was armed.
  // NOTE this arms only Part B; warm_start_inherit (Part A) is resolved by
  // build_production_loadcase's own measured rule (handoff 113: load-case runs
  // warm, self-weight runs cold) and is NOT touched here.
  if (job.has_warm_start) {
    options.warm_start_coarse = job.warm_start_coarse;
    // S3(b): the matrix-free trajectory warm start. OFF unless the job says so.
    options.simp.matfree_warm_start = job.warm_start_matfree;
  }

  // Task 2026-08-08-semdot-does-it-come-out-smoother — map the optional "semdot"
  // block onto the production options, for BOTH front-ends, exactly like the
  // "draft" and "warm_start" blocks above. Absent (has_semdot == false, the
  // default) => options.simp.semdot keeps its OFF default and the run is
  // byte-identical. run_info echoes the resolved value, so an armed run SAYS it
  // was armed. This is the LAST thing applied to `options.simp`, so nothing the
  // mode subsumes can be re-armed behind it.
  if (job.has_semdot) {
    options.simp.semdot = job.semdot;
    options.simp.semdot_grid_points = job.semdot_grid_points;
  }

  // Task 2026-08-10-plsm-production — map the optional "plsm" block onto the
  // production options, for BOTH front-ends, exactly like the three blocks
  // above. Absent (has_plsm == false, the default) => options.plsm.mode keeps
  // its Off default and the run is byte-identical; R1 of that task is a
  // stash-rebuild checksum of exactly that.
  //
  // ★ THE KNOTS PASS THROUGH AS THREE NUMBERS AND ARE NEVER REDUCED TO ONE. All
  // three zero (the job's default, and what a job that omits the key gets) means
  // "derive from the grid" — plsm_optimize calls plsm_knots_for_grid, which is
  // the ONE place the production rule lives.
  if (job.has_plsm && job.plsm_enabled) {
    options.plsm.mode = PlsmMode::Parametric;
    options.plsm.basis = job.plsm_basis;
    options.plsm.knots.dx = job.plsm_knots[0];
    options.plsm.knots.dy = job.plsm_knots[1];
    options.plsm.knots.dz = job.plsm_knots[2];
    options.plsm.support = job.plsm_support;
    options.plsm.eta_voxels = job.plsm_eta_voxels;
    options.plsm.max_iterations = job.plsm_max_iterations;
    options.plsm.seed = job.plsm_seed;
    options.plsm.refit_every = job.plsm_refit_every;
    options.plsm.move = job.plsm_move;
    options.plsm.cg_tolerance_loose = job.plsm_cg_tolerance_loose;
    options.plsm.warm_start = job.plsm_warm_start;
    options.plsm.ersatz = job.plsm_ersatz == "heaviside"
                              ? PlsmErsatz::Heaviside
                              : PlsmErsatz::VolumeFraction;
    options.plsm.sens_weight = job.plsm_sens_weight == "continuum"
                                  ? PlsmSensWeight::Continuum
                                  : PlsmSensWeight::Discrete;
    options.plsm.frac_samples = job.plsm_frac_samples;
    options.plsm.frac_eps_mult = job.plsm_frac_eps_mult;
    options.plsm.frac_mollified = job.plsm_frac_mollified;
    options.plsm.frac_sens_exact = job.plsm_frac_sens_exact;
    options.plsm.frac_eps_l1 = job.plsm_frac_eps_l1;
    options.plsm.margin_probe_every = job.plsm_margin_probe_every;
    options.plsm.margin_plateau_probes = job.plsm_margin_plateau_probes;
    options.plsm.margin_plateau_tol = job.plsm_margin_plateau_tol;
    // The parametric path's own trajectory threads follow the solver's, so a
    // job that asked for three threads gets three here too rather than the
    // hardware's full count (which is what "he needs his machine" means).
    options.plsm.threads = production_matfree_thread_count();
  }
  // TO rebuild stage 2: the size the deciding stress is read over, from the job's
  // material (half the lowest published length; 0 where nothing is published).
  // Set LAST: the production load case replaces the whole options value above.
  if (strength_mode() == StrengthMode::Size || strength_mode() == StrengthMode::Surface)
    options.stress_reading_mm = reading_size_for_job_mm(job.material);
  return S;
}
