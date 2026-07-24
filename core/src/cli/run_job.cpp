#include "topopt/job.hpp"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/fields.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/observability.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/version.hpp"
#include "topopt/voxel.hpp"
#ifdef TOPOPT_HAVE_3MF
#include "topopt/threemf.hpp"
#endif

namespace topopt {
namespace {

// materials.json density is g/cm^3; the job's units are mm and mm/s^2 with
// material moduli in MPa (N/mm^2). The mm-MPa-consistent mass-density unit is
// t/mm^3, and 1 g/cm^3 = 1e-9 t/mm^3, so folding the 1e-9 into the gravity
// magnitude passed to minimize_plastic (which multiplies density_g_cm3 *
// gravity * voxel_volume) makes the load come out in N and every reported
// stress in MPa. The margin is a ratio, so only this PRODUCT matters.
constexpr double kGramPerCm3ToTonnePerMm3 = 1e-9;

std::string join_path(const std::string& dir, const std::string& name) {
  if (std::filesystem::path(name).is_absolute()) return name;
  return dir + "/" + name;
}

// <prefix>_<fraction*100, 3 digits>.<format>, per the demo fixture's
// _output_note (0.7 -> variant_070.3mf).
std::string mesh_file_name(const std::string& prefix, double requested_vf,
                           const std::string& format) {
  char digits[8];
  std::snprintf(digits, sizeof(digits), "%03d",
                static_cast<int>(std::lround(requested_vf * 100.0)));
  return prefix + "_" + digits + "." + format;
}

void write_text_file(const std::string& path, const std::string& text) {
  std::ofstream out(path, std::ios::binary);
  if (!out) throw JobError("cannot open output file for writing: " + path);
  out << text;
  out.flush();
  if (!out) throw JobError("failed writing output file: " + path);
}

// Resolve a list of GEOMETRIC face selectors against an imported model to the
// B-rep face ids they match (the same locked rule fixture_faces uses: match by
// surface property, never raw index). Every selector must match >= 1 face — a
// selector that finds nothing is a user error, not an empty no-op. `what` names
// the block in the diagnostic. Shared by fixture_faces, loadcase anchors and
// load-group faces so all three resolve identically.
std::vector<int> resolve_selectors(const StepModel& model,
                                   const std::vector<JobFaceSelector>& selectors,
                                   const std::string& what) {
  std::vector<int> ids;
  for (const JobFaceSelector& sel : selectors) {
    if (sel.kind != "cylindrical")
      throw JobError("unsupported " + what + " selector kind: " + sel.kind);
    bool matched = false;
    for (int f = 0; f < model.face_count; ++f) {
      const StepFaceInfo& info = model.faces[static_cast<std::size_t>(f)];
      if (info.kind == StepSurfaceKind::Cylinder &&
          std::fabs(info.cylinder_radius_mm - sel.radius_mm) <=
              kJobFaceRadiusToleranceMm) {
        ids.push_back(f);
        matched = true;
      }
    }
    if (!matched)
      throw JobError(what + " selector (cylindrical, radius_mm " +
                     std::to_string(sel.radius_mm) + ") matched no face of the model");
  }
  return ids;
}

// Handoff 114 — the resolved solver name for the version record.
const char* solver_name(SolverKind k) {
  switch (k) {
    case SolverKind::JacobiCG: return "JacobiCG";
    case SolverKind::MultigridCG: return "MultigridCG";
    case SolverKind::MultigridCG_Matfree: return "MultigridCG_Matfree";
  }
  return "unknown";
}

// Handoff 114 — assemble the run version record from the ACTUAL configuration
// (options after configure_production_options / build_production_loadcase, plus
// the live matrix-free thread-global state) so run_info.json is provable, not
// inferred. Never again reconstruct "which build ran this" (the 113 lesson).
RunInfo build_run_info(const JobDescription& job,
                       const MinimizePlasticOptions& options,
                       const RunObservability& obs) {
  RunInfo info;
  info.cli_version = version();
  info.fingerprint = obs.fingerprint;
  info.mode = job.mode;
  info.material = job.material;
  info.resolution = job.resolution;
  info.load_source = job.loads.present ? "loadcase" : "self_weight";
  info.solver = solver_name(options.simp.solver);
  // cg_multigrid / mg_levels are an OBSERVED outcome, unknown until the run
  // finishes. Leave cg_multigrid_observed false so the up-front write emits null
  // for both (Amendment 1): we do NOT write the requested-solver INTENT here — a
  // multigrid solver can silently fall back, and a run that never reaches the
  // post-run finalize must assert NOTHING rather than the optimistic `true` that
  // misdiagnosed the res-128 fallback. The finalize below records the real values.
  info.galerkin_block_cache = fea_matfree_galerkin_block_cache_enabled();
  info.mixed_precision = fea_matfree_mixed_precision_enabled();
  info.matfree_threads = fea_matfree_thread_count();
  info.krylov_recycling = fea_krylov_recycling_enabled();
  info.krylov_recycle_dim = fea_krylov_recycle_dim();
  info.krylov_recycle_wrap_multigrid = fea_krylov_recycle_wrap_multigrid();
  info.warm_start_inherit = options.warm_start_inherit;
  info.warm_start_coarse = options.warm_start_coarse;
  info.projection = !options.simp.projection.empty();
  // Handoff 123 — the armed conditional-projection threshold (config echo). The
  // per-rung fired/Mnd vectors are filled post-run (finalize below), like
  // cg_multigrid, since they are an OBSERVED outcome of the ladder.
  info.conditional_mma_projection_mnd_threshold =
      options.conditional_mma_projection_mnd_threshold;
  // Handoff 131 — the armed rung-infeasibility thresholds (config echo). The
  // per-rung outcome vector is filled post-run (finalize below).
  info.infeasible_compliance_ratio = options.simp.infeasible_compliance_ratio;
  info.infeasible_cg_blowup = options.simp.infeasible_cg_blowup;
  info.infeasible_flat_tol = options.simp.infeasible_flat_tol;
  info.infeasible_window = options.simp.infeasible_window;
  // active-domain phase 1 — the REQUESTED band (config echo). The per-rung
  // latch outcome is filled post-run (finalize below), like cg_multigrid.
  info.active_domain_band = options.simp.active_domain_band;
  info.min_feature_mm = options.min_feature_mm;
  info.margin_stop = options.margin_stop;
  info.infill_percent = options.infill_percent;
  info.has_design_box = options.design_box.has_value();
  info.ladder = options.volume_fraction_ladder;
  info.created_wall_ms = wall_clock_ms();
  info.iteration_csv = obs.iteration_csv;
  info.density_snapshots = obs.density_snapshots;
  info.snapshot_every = obs.snapshot_every;
  info.snapshot_cap = obs.snapshot_cap;
  return info;
}

// A job.json box -> the core DesignBox it describes.
DesignBox to_design_box(const JobBox& b) {
  DesignBox d;
  d.min = b.min;
  d.max = b.max;
  return d;
}

// Write one accepted variant's mesh into out_dir and return its path. Smooth-
// export (handoff 086): factor 1 writes v3.mesh verbatim; factor > 1 re-extracts
// the SAME iso-surface from the SAME physical density resampled finer on `sg` (the
// solved grid). Shared by the batch export loop and the streaming on_variant
// callback so both write byte-identical files.
std::string export_variant_mesh(const MinimizePlasticVariant& variant,
                                const std::string& out_dir, const JobOutput& out,
                                const VoxelGrid& sg) {
  const std::string path = join_path(
      out_dir, mesh_file_name(out.mesh_prefix, variant.requested_volume_fraction,
                              out.mesh_format));
  const int sf = out.smooth_factor;
  TriangleMesh smooth;  // only populated when sf > 1
  if (sf > 1) {
    const TriangleMesh raw = marching_cubes_resampled(
        sg.nx, sg.ny, sg.nz, sg.spacing, sg.origin,
        variant.optimization.physical_density, /*iso=*/0.5, sf,
        ResampleInterp::Tricubic);
    smooth = keep_largest_component(raw);
  }
  const TriangleMesh& export_mesh = (sf > 1) ? smooth : variant.v3.mesh;
  if (out.mesh_format == "3mf") {
#ifdef TOPOPT_HAVE_3MF
    write_3mf_file(path, export_mesh);
#else
    throw JobError("3MF support unavailable in this build");  // unreachable
#endif
  } else {
    write_stl_file(path, export_mesh);
  }
  return path;
}

}  // namespace

RunJobResult run_job(const JobDescription& job, const std::string& job_dir,
                     const std::string& out_dir,
                     const MaterialLibrary& materials,
                     const SettingsRules& rules, bool emit_progress,
                     const RunObservability& obs) {
  // Fail fast on everything checkable before heavy work: the mode, the
  // material, and whether this build can write the requested mesh format.
  if (job.mode != "minimize_plastic")
    throw JobError("unsupported mode: " + job.mode);
  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;
#ifndef TOPOPT_HAVE_3MF
  if (job.output.mesh_format == "3mf")
    throw JobError(
        "this build has no 3MF support (lib3mf was not available): "
        "output.mesh_format \"3mf\" cannot be written, use \"stl\"");
#endif

  RunJobResult result;

  // §5 pipeline: STEP ──OCCT──▶ tessellated surface.
  result.model = import_step_file(join_path(job_dir, job.model));

  // ──▶ watertight check (both modes).
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);

  // Two modes, both driving the SAME production optimizer configuration as the
  // iPad app (handoff 093): a "loads" block => the shared build_production_loadcase
  // (anchors + declared forces, the app's mode a); otherwise the self-weight +
  // fixture_faces path, now also carrying the production solver config + optional
  // design box so it matches what the app produces for the same input.
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;

  if (job.loads.present) {
    // ── LOADCASE mode: resolve the geometric selectors to face ids, build the
    // front-end-neutral ProductionLoadCase, and hand it to the SAME core builder
    // the bridge calls. The CLI and app therefore produce the same design for the
    // same STEP + load case + resolution.
    ProductionLoadCase lc;
    // Anchors: raw B-rep ids (from the app) and/or geometric selectors compose.
    lc.anchor_face_ids = job.loads.anchor_face_ids;
    for (const int id : resolve_selectors(result.model, job.loads.anchors, "anchors"))
      lc.anchor_face_ids.push_back(id);
    result.fixture_face_ids = lc.anchor_face_ids;
    for (const JobLoadGroup& g : job.loads.groups) {
      ProductionLoadCase::LoadGroup lg;
      lg.face_ids = g.face_ids;
      for (const int id : resolve_selectors(result.model, g.faces, "loads group faces"))
        lg.face_ids.push_back(id);
      lg.force = g.force;
      lc.load_groups.push_back(std::move(lg));
    }
    // Clearances (handoff 100): map each job clearance to a ProductionLoadCase
    // clearance. A distance the job omitted (== 0) defaults to the same spec
    // suggestion the app prefills — for a bolt those depend on the bore radius,
    // read from the imported face geometry, so a hand-authored job need only give
    // face_id + kind.
    for (const JobClearance& jc : job.loads.clearances) {
      ProductionLoadCase::Clearance c;
      c.face_id = jc.face_id;
      const bool bolt = jc.kind == "bolt";
      double bore_r = 0.0;
      if (bolt && jc.face_id >= 0 && jc.face_id < result.model.face_count)
        bore_r = result.model.faces[static_cast<std::size_t>(jc.face_id)]
                     .cylinder_radius_mm;
      c.params = bolt ? topopt::default_bolt_clearance(bore_r)
                      : topopt::default_face_clearance();
      if (jc.concentric_margin_mm > 0.0)
        c.params.concentric_margin_mm = jc.concentric_margin_mm;
      if (jc.axial_clearance_mm > 0.0)
        c.params.axial_clearance_mm = jc.axial_clearance_mm;
      if (jc.slab_depth_mm > 0.0) c.params.slab_depth_mm = jc.slab_depth_mm;
      lc.clearances.push_back(c);
    }
    // Face protections (handoff 124): the raw face ids + the ONE global depth.
    // A depth <= 0 in the job means "use the core default"; leave the
    // ProductionLoadCase field at its default so the builder derives voxels from
    // kFaceProtectionDepthDefaultMm. Empty list => byte-identical.
    lc.face_protection_face_ids = job.loads.face_protection_face_ids;
    if (job.loads.face_protection_depth_mm > 0.0)
      lc.face_protection_depth_mm = job.loads.face_protection_depth_mm;
    lc.minimize_plastic = job.loads.minimize_plastic;
    lc.build_dir = job.loads.build_dir;
    lc.infill_percent = job.loads.infill_percent;
    lc.has_design_box = job.has_design_box;
    if (job.has_design_box) {
      lc.design_box = to_design_box(job.design_box);
      for (const JobBox& ko : job.keep_out_boxes)
        lc.keep_out_boxes.push_back(to_design_box(ko));
    }

    ProductionRunSetup setup =
        build_production_loadcase(result.model, job.resolution, lc);
    grid = std::move(setup.grid);
    bcs = std::move(setup.bcs);
    options = std::move(setup.options);
    // The CLI exports meshes, not playback: keyframe_count stays 0 (the app sets
    // 12). This is viz only and does not change the design.
  } else {
    // ── SELF-WEIGHT mode: geometric fixture-face selection (locked rule,
    // DECISIONS.md 2026-07-09).
    result.fixture_face_ids =
        resolve_selectors(result.model, job.fixture_faces, "fixture_faces");

    // ──▶ voxelize + tag the fixture voxels of every matched face.
    grid = voxelize(result.model.mesh, job.resolution);
    std::size_t tagged = 0;
    for (const int f : result.fixture_face_ids)
      tagged += tag_step_face(grid, result.model, f, VoxelTag::Fixture);
    if (tagged == 0)
      throw JobError("fixture faces tagged no voxels (resolution too coarse "
                     "for the selected faces?)");

    // Mounting BCs: every node of every Fixture voxel is fully clamped.
    const std::vector<int> fixture_nodes =
        fea_tagged_nodes(grid, VoxelTag::Fixture);
    bcs.reserve(fixture_nodes.size() * 3);
    for (const int n : fixture_nodes)
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});

    // ──▶ FEA + SIMP ladder + report assembly (the M5.3 driver). The production
    // solver config (matrix-free multigrid + Galerkin cache + physical
    // min-feature) is applied here so the CLI matches the app; the job supplies
    // the self-weight load case (ladder, margin, gravity).
    configure_production_options(options);
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

  // ──▶ output dir (created before the run so streamed artifacts can land in it).
  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("cannot create output directory " + out_dir + ": " +
                     ec.message());
  }

  // The grid the run solves on (the expanded domain under a design box), needed
  // up front so a streamed variant's mesh is resampled on the right grid.
  const VoxelGrid solved_grid = minimize_plastic_solved_grid(grid, options);

  // Streaming (topopt-cli binary): print machine-parseable checkpoints and export
  // each accepted variant's mesh AS IT COMPLETES, so a wrapper can forward live
  // progress + progressive artifacts. Pure observers — the design/report/mesh
  // bytes are unchanged, so run_job stays deterministic (the default, false, is
  // the exact batch path the tests exercise). See job.hpp.
  // Handoff 114 — observability capture (CLI path only). run_info.json is written
  // now (config is finalized); the per-iteration CSV + density snapshots are wired
  // as read-only observers on `options`. Declared here so they outlive the
  // synchronous minimize_plastic call below. All artifacts land in out_dir.
  std::unique_ptr<IterationCsvWriter> csv;
  std::unique_ptr<SnapshotCapture> snaps;
  // Held across the run so its cg_multigrid / mg_levels can be finalized from the
  // OBSERVED solver outcome after minimize_plastic returns (below).
  RunInfo run_info;
  bool wrote_run_info = false;
  if (emit_progress) {
    run_info = build_run_info(job, options, obs);
    result.run_info_path = join_path(out_dir, "run_info.json");
    write_run_info(result.run_info_path, run_info);
    wrote_run_info = true;
    if (obs.iteration_csv) {
      result.iteration_csv_path = join_path(out_dir, "iterations.csv");
      csv = std::make_unique<IterationCsvWriter>(result.iteration_csv_path);
      options.on_iteration = [&csv](std::size_t rung, std::size_t /*rungs*/,
                                    const SimpIterationObservation& o) {
        csv->append(rung, o);
      };
    }
    if (obs.density_snapshots) {
      snaps = std::make_unique<SnapshotCapture>(
          join_path(out_dir, "snapshots"), obs.snapshot_every, obs.snapshot_cap);
      options.on_density_snapshot = [&snaps](const DensitySnapshotEvent& ev) {
        snaps->capture(*ev.grid, *ev.density, ev.rung_index, ev.iteration,
                       ev.boundary);
      };
    }
  }

  std::vector<std::string> streamed_paths;
  if (emit_progress) {
    options.progress = [](std::size_t rung, std::size_t rungs, int iter) {
      std::printf("PROGRESS rung=%zu rungs=%zu iter=%d\n", rung, rungs, iter);
      std::fflush(stdout);
    };
    options.on_variant = [&](const MinimizePlasticVariant& v) {
      if (!v.accepted) return;
      const std::string p =
          export_variant_mesh(v, out_dir, job.output, solved_grid);
      streamed_paths.push_back(p);
      // `achieved` is the optimizer-achieved (continuous) fraction — the stream's
      // join key against the report's volume_fraction; `printed` is the printed/count
      // basis the app's savings uses (handoff 104, additive — a new field; older
      // readers ignore it). Both come from the same variant.
      std::printf(
          "VARIANT vf=%.6f achieved=%.6f printed=%.6f margin=%.6g accepted=1 mesh=%s\n",
          v.requested_volume_fraction, v.optimization.volume_fraction,
          v.report.printed_fraction, v.report.margin.worst_case, p.c_str());
      std::fflush(stdout);
    };
  }

  result.pipeline =
      minimize_plastic(grid, material, job.material, bcs, rules, options);

  // LOUD FALLBACK (handoff: multigrid-coarsenability-padding). Record the OBSERVED
  // multigrid outcome now the run is done (the up-front write left it null), and —
  // if a multigrid solver was requested but silently fell back to Jacobi-CG — print
  // a WARNING. A silent slowdown violates the honesty principle exactly like a
  // wrong number does, so it must be reported, not swallowed.
  const bool solver_is_multigrid =
      options.simp.solver == SolverKind::MultigridCG ||
      options.simp.solver == SolverKind::MultigridCG_Matfree;
  if (wrote_run_info) {
    run_info.cg_multigrid = result.pipeline.used_multigrid;
    run_info.mg_levels = result.pipeline.mg_levels;
    run_info.cg_multigrid_observed = true;  // outcome now known -> emit real values
    // Handoff 128 — the run-level fallback mode. Only meaningful for a multigrid
    // solver; for JacobiCG leave mg_mode empty (serialized null). "carried" when
    // MG carried the run; otherwise "stagnated-latched" if a hierarchy ever built
    // (built-but-never-carried == stagnation, the 127 latch may have engaged) or
    // "build-rejected" if none ever did (never coarsenable).
    if (solver_is_multigrid) {
      run_info.mg_mode =
          result.pipeline.used_multigrid
              ? "carried"
              : (result.pipeline.mg_hierarchy_ever_built ? "stagnated-latched"
                                                         : "build-rejected");
      run_info.mg_mode_observed = true;
    }
    // Handoff 123 — finalize the conditional-projection outcome: which rungs fired
    // and the grayscale Mnd measured on each (empty when the gate was disarmed).
    run_info.conditional_projection_fired.assign(
        result.pipeline.conditional_projection_fired.begin(),
        result.pipeline.conditional_projection_fired.end());
    run_info.conditional_projection_rung_mnd =
        result.pipeline.rung_grayscale_mnd;
    // Handoff 131 — finalize the per-rung infeasibility outcome (one entry per
    // evaluated rung; all-false is the positive statement "no rung lost its load
    // path"). Written only now, like cg_multigrid, so an unfinished run claims
    // nothing either way.
    run_info.rung_infeasible.assign(result.pipeline.rung_infeasible.begin(),
                                    result.pipeline.rung_infeasible.end());
    // active-domain phase 1 — finalize the per-rung latch outcome. All-false
    // (with a band > 0) is the positive statement "the band held for every
    // rung"; a true entry names the rung that fell back to the full domain and
    // why, so a run that bought nothing SAYS so instead of silently costing.
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
      run_info.active_domain_latched.push_back(
          v.optimization.active_domain_latched ? 1 : 0);
      run_info.active_domain_latch_reason.push_back(
          v.optimization.active_domain_latch_reason);
      run_info.active_domain_fraction_mean.push_back(
          v.optimization.active_fraction_mean);
    }
    write_run_info(result.run_info_path, run_info);
  }
  // A recovery solve (which sets used_multigrid) runs only for a non-cancelled
  // rung; without one, used_multigrid is its unobserved default and must not warn.
  bool any_solve = false;
  for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
    if (!v.optimization.cancelled) { any_solve = true; break; }
  if (solver_is_multigrid && any_solve && !result.pipeline.used_multigrid) {
    const VoxelGrid& sg = result.pipeline.solved_grid;
    std::fprintf(stderr,
                 "WARNING: multigrid solver \"%s\" fell back to Jacobi-CG on the "
                 "%dx%dx%d solved grid (the hierarchy could not be built, OR the "
                 "V-cycle stagnated on a high-contrast field) — expect a large "
                 "slowdown. Linear solves ran Jacobi-CG; run_info.json records "
                 "cg_multigrid=false. See iterations.csv for the per-solve record.\n",
                 solver_name(options.simp.solver), sg.nx, sg.ny, sg.nz);
    std::fflush(stderr);
  }

  // Handoff 131 — LOUD INFEASIBILITY. A rung whose load path was severed is a
  // failed rung, not a quiet one: say so on stderr, once per rung, in the same
  // spirit as the multigrid loud fallback above. Silence here is what let the
  // motivating run ship a corpse as an accepted variant.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (!v.infeasible) continue;
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) is INFEASIBLE — %s. The optimizer "
                 "severed the load path: compliance stayed >= %.4gx this rung's "
                 "starting value, flat to within %.4g, with a >= %.4gx CG blow-up, "
                 "for %d consecutive iterations, and the rung was ended at "
                 "iteration %d. No mesh, no "
                 "stress analysis and no margin are reported for it, and no later "
                 "rung inherits its design. See report.json rejected_variants and "
                 "run_info.json rung_infeasible.\n",
                 i, v.requested_volume_fraction, kRungInfeasibleReason,
                 options.simp.infeasible_compliance_ratio,
                 options.simp.infeasible_flat_tol,
                 options.simp.infeasible_cg_blowup,
                 options.simp.infeasible_window,
                 v.optimization.infeasible_iteration);
    std::fflush(stderr);
  }

  // active-domain phase 1 — LOUD LATCH. A band that switched itself off cost the
  // derivation and bought nothing; say so, in the same spirit as the multigrid
  // loud fallback above. Unreachable from a plain `topopt-cli run` today (the
  // band is deliberately NOT a job.json key — it is a solver-internal
  // accelerator, not a user knob), and deliberately written anyway so it is live
  // the moment any front-end arms it.
  if (options.simp.active_domain_band != 0) {
    for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
      const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
      if (!v.optimization.active_domain_latched) continue;
      std::fprintf(stderr,
                   "WARNING: rung %zu (vf %.2f) LATCHED the active domain off at "
                   "iteration %d — %s. Every solve from there ran the FULL "
                   "domain: the design is unaffected, the run is simply not "
                   "accelerated. run_info.json records active_domain_latched.\n",
                   i, v.requested_volume_fraction,
                   v.optimization.active_domain_latch_iteration,
                   v.optimization.active_domain_latch_reason.c_str());
      std::fflush(stderr);
    }
  }

  // Handoff 2026-07-23-gate-honesty-connectivity-rejection — LOUD DISCONNECTION,
  // the same discipline for the connectivity belt's verdict, once per rung. A rung
  // the belt rejected has, almost always, an EXCELLENT-looking margin (no load path
  // => no stress), so the one thing that must not happen is for it to be dropped
  // quietly and leave those numbers to speak for themselves.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (v.report.rejection_reason != kLoadPathNotConnectedReason) continue;
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) was REJECTED — %s. No printed "
                 "material connects the anchor (Fixture) voxels to the load "
                 "(Load) voxels, so this design carries nothing: its measured "
                 "margin %.4g describes a SEVERED structure and is not a strength "
                 "result. No mesh is exported for it and no later rung inherits "
                 "its design; the ladder continues. See report.json "
                 "rejected_variants.\n",
                 i, v.requested_volume_fraction, kLoadPathNotConnectedReason,
                 v.report.margin_effective);
    std::fflush(stderr);
  }

  // Handoff 114 — record how many density snapshots were written (0 unless
  // opt-in snapshots ran). The CSV/run_info paths are already set above.
  if (snaps) result.snapshot_count = snaps->written();

  // ──▶ report (both paths).
  result.report_json = job_report_json(result.pipeline.report);
  result.report_path = join_path(out_dir, job.output.report);
  write_text_file(result.report_path, result.report_json);

  // ──▶ meshes: already written progressively when streaming; otherwise one
  // exported mesh per accepted variant now (byte-identical to the streamed files).
  if (emit_progress) {
    result.mesh_paths = std::move(streamed_paths);
  } else {
    for (const MinimizePlasticVariant& variant : result.pipeline.evaluated) {
      if (!variant.accepted) continue;
      result.mesh_paths.push_back(export_variant_mesh(
          variant, out_dir, job.output, result.pipeline.solved_grid));
    }
  }

  // ──▶ per-voxel result fields (handoff 122): one versioned container for the
  // accepted variants' von Mises / displacement fields + voxel mass & support,
  // so a LAN remote run lights up the same overlays a local run does. Indexed to
  // the grid the run actually solved on (the expanded domain under a design box).
  // Additive: older readers ignore it; the meshes/report above are unchanged.
  result.fields_path = join_path(out_dir, "fields.bin");
  result.fields_variant_count =
      write_fields_file(result.fields_path, result.pipeline,
                        result.pipeline.solved_grid);

  return result;
}

}  // namespace topopt
