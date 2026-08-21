#include "topopt/job.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/build_frame.hpp"
#include "topopt/cad_project.hpp"
#include "topopt/clearance.hpp"
#include "topopt/face_region.hpp"
#include "topopt/coarsen.hpp"
#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/fields.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_algorithm.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_void.hpp"
#include "topopt/organic_lattice.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/observability.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/part.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/threemf_stream.hpp"
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

// Monotonic wall-clock seconds (handoff 2026-07-28-lattice-generation-production).
// Used ONLY to time lattice generation and the whole job for the P6 fraction; a
// pure observer, never consulted on the byte-identical no-lattice path.
double wall_seconds() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
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
// face ids they match (the same locked rule fixture_faces uses: match by
// surface property, never raw index). Every selector must match >= 1 face — a
// selector that finds nothing is a user error, not an empty no-op. `what` names
// the block in the diagnostic. Shared by fixture_faces, loadcase anchors and
// load-group faces so all three resolve identically.
//
// MESH SOURCES (STL/3MF): this is UNCHANGED and it needs no branch. A cylinder
// selector matches on `StepFaceInfo::kind == Cylinder` and the FITTED radius the
// segmenter produced — a mesh has no B-rep, so the fitted radius IS the exact
// radius for the geometry the user supplied. It is compared under the same
// kJobFaceRadiusToleranceMm as a B-rep radius. The honest consequence: a
// cylinder whose tessellation is too coarse for a tight circle fit (or a fit
// that lands just outside the 1e-6 mm window) matches NOTHING and the selector
// REFUSES with the plain "matched no face of the model" message below — it never
// silently falls back to a raw index or a fuzzy match. A hand-authored mesh job
// that wants a specific bore should therefore give a radius the fit actually
// achieves (asserted for the demo L-bracket STL in test_mesh_job), or select by
// raw face id via the loads block's `anchor_face_ids` / `face_ids`, the form the
// app's interactive tap already produces for both sources.
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
// Copy the PRE-FLIGHT measurement into a RunInfo (bar P6). Separate from
// build_run_info because the pre-flight runs LATER than the config echo — and
// because the REFUSAL path has to write this same block before it throws.
void fill_run_info_preflight(RunInfo& info, const PreflightLoadPath& pf) {
  info.preflight_ran = pf.ran;
  info.preflight_decidable = pf.walk.decidable;
  info.preflight_connected = pf.walk.connected;
  info.preflight_ms = pf.wall_ms;
  info.preflight_load_voxels = static_cast<long long>(pf.walk.load_voxels);
  info.preflight_anchor_voxels = static_cast<long long>(pf.walk.anchor_voxels);
  info.preflight_unreached_load_voxels =
      static_cast<long long>(pf.walk.unreached_load_voxels);
  info.preflight_allowed_voxels = static_cast<long long>(pf.walk.printed_voxels);
  info.preflight_forbidden_voxels =
      static_cast<long long>(pf.forbidden_voxels);
  info.preflight_narrowest_separator_voxels =
      pf.walk.narrowest_separator_voxels;
  info.preflight_narrowest_separator_mm2 = pf.walk.narrowest_separator_mm2;
  info.preflight_geodesic_levels = pf.walk.geodesic_levels;
}

RunInfo build_run_info(const JobDescription& job,
                       const MinimizePlasticOptions& options,
                       const RunObservability& obs) {
  RunInfo info;
  info.cli_version = version();
  info.fingerprint = obs.fingerprint;
  info.mode = job.mode;
  info.material = job.material;
  // True source format for provenance (handoff 2026-07-26-3mf-optimize-path).
  // The job may carry an explicit override (the app normalises a 3MF import to an
  // STL working copy, then records "3mf" here); otherwise the model file IS the
  // source, so its extension is the honest answer.
  info.source_format =
      job.source_format.empty() ? format_name(part_format_for_path(job.model))
                                : job.source_format;
  info.resolution = job.resolution;
  // ★ THE CHECKBOX, ON THE RECORD (task 2026-08-13 §0.5). `info.mode` above is
  // `job.mode` — the job KIND — and reads "minimize_plastic" on every
  // optimisation run whichever way the user ticked the box, so it has never
  // answered "which ladder ran". This does. It mirrors cli/loadcase.cpp's own
  // rule (`growth = !lc.minimize_plastic`) rather than re-deriving it, and it is
  // filled in the ONE shared builder so all four run_info write sites agree by
  // construction instead of by three copies kept in step.
  //
  // A self-weight job carries no loadcase and so no checkbox; it is left empty
  // (JSON null) rather than asserting a default the user never chose.
  if (job.loads.present)
    info.ladder_direction = job.loads.minimize_plastic ? "reduce" : "grow";

  // ★ AND WHAT THAT CHOICE MEANS FOR A LATTICE — READ FROM THE MODE, never from
  // an option of its own. The maintainer's ruling: `minimize_plastic` ALREADY is
  // the question "am I chasing lightness or performance?", and a second hidden
  // convention deciding the same thing is precisely the duplication that
  // produced the probe/ladder volume mismatch. One user-facing control, one
  // meaning, no new knob.
  if (!options.frozen_lattice || options.frozen_lattice_regions.empty())
    info.lattice_budget_convention = "none";
  else if (!job.loads.present)
    info.lattice_budget_convention = "banked";  // no checkbox: the reduce default
  else
    info.lattice_budget_convention =
        job.loads.minimize_plastic ? "banked" : "spent";
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
  // Task algebraic-level1-coarsening — the ACTUAL process state, read rather
  // than inferred. The per-build numbers are filled in the post-run finalize.
  info.mg_algebraic_level1 = fea_mg_algebraic_level1_enabled();
  info.matfree_threads = fea_matfree_thread_count();
  info.krylov_recycling = fea_krylov_recycling_enabled();
  info.krylov_recycle_dim = fea_krylov_recycle_dim();
  info.krylov_recycle_wrap_multigrid = fea_krylov_recycle_wrap_multigrid();
  // Handoff 2026-07-29-geneo-arming — the armed GenEO posture (config echo: the
  // ACTUAL process-global state + the named policy constants). The lifecycle
  // counters are filled post-run (finalize below).
  info.geneo_twolevel = fea_geneo_twolevel_enabled();
  info.geneo_trigger_iters = fea_geneo_trigger_iters();
  info.geneo_rebuild_factor = fea_geneo_rebuild_factor();
  // Handoff 2026-08-02-geneo-disarm — the ENGAGEMENT GATE's two cost constants,
  // echoed beside the trigger they now govern alongside.
  info.geneo_refresh_cost_per_column = fea_geneo_refresh_cost_per_column();
  info.geneo_deflated_iter_cost = fea_geneo_deflated_iter_cost();
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
  // Task 2026-08-03-preflight-feasibility-and-divergence — the armed thresholds
  // of the two DIVERGENCE guards (config echo). Per-rung outcomes are filled
  // post-run in the finalize below; the pre-flight block is filled BEFORE the
  // solve, at the call site, because that is the one part of run_info a run
  // which never finishes still has an honest answer for.
  info.infeasible_immediate_ratio = options.simp.infeasible_immediate_ratio;
  info.infeasible_immediate_wall_ratio =
      options.simp.infeasible_immediate_wall_ratio;
  info.iteration_time_ratio = options.simp.iteration_time_ratio;
  info.iteration_time_floor_ms = options.simp.iteration_time_floor_ms;
  // active-domain phase 1 — the REQUESTED band (config echo). The per-rung
  // latch outcome is filled post-run (finalize below), like cg_multigrid.
  info.active_domain_band = options.simp.active_domain_band;
  // Handoff 2026-07-25-draft-quality — the armed draft posture (config echo). The
  // per-rung tail-k / gap / escalated vectors are filled post-run (finalize below).
  // Task 2026-08-08-semdot-does-it-come-out-smoother — the armed mode (config
  // echo). The per-rung level-set / boundary-layer vectors are filled post-run
  // (finalize below), like the draft vectors.
  info.semdot = options.simp.semdot;
  info.semdot_grid_points =
      options.simp.semdot ? options.simp.semdot_grid_points : 0;
  // Task 2026-08-10-plsm-production — the armed PARAMETRIC posture (config
  // echo). `plsm_coefficients` and `plsm_frozen_floor_occupancy` are the RUN's
  // own measurements and are filled post-run from the first evaluated variant,
  // like the semdot per-rung vectors.
  info.plsm = options.plsm.mode == PlsmMode::Parametric;
  if (info.plsm) {
    info.plsm_basis = options.plsm.basis;
    // The REQUESTED spacing; all-zero means "derive from the grid". The
    // RESOLVED spacing — the number actually in force — is overwritten post-run
    // from the variant's own knot lattice, so the receipt states what ran and
    // not what was asked for.
    info.plsm_knots_vox[0] = options.plsm.knots.dx;
    info.plsm_knots_vox[1] = options.plsm.knots.dy;
    info.plsm_knots_vox[2] = options.plsm.knots.dz;
    info.plsm_support = options.plsm.support;
    info.plsm_eta_voxels = options.plsm.eta_voxels;
    info.plsm_max_iterations = options.plsm.max_iterations;
    info.plsm_seed = options.plsm.seed;
    info.plsm_refit_every = options.plsm.refit_every;
    info.plsm_cg_tolerance_loose = options.plsm.cg_tolerance_loose;
    info.plsm_warm_start = options.plsm.warm_start;
    // Task 2026-08-13-plsm-production-settings — the ersatz posture and the
    // stopping rule's configuration. The MEASUREMENTS (stop reason, peak,
    // counters, wall clocks) are filled post-run from the first evaluated
    // variant, like the knot spacing above.
    info.plsm_ersatz = options.plsm.ersatz == PlsmErsatz::VolumeFraction
                           ? "fraction"
                           : "heaviside";
    info.plsm_frac_samples =
        options.plsm.ersatz == PlsmErsatz::VolumeFraction
            ? options.plsm.frac_samples
            : 0;
    info.plsm_sens_weight =
        options.plsm.sens_weight == PlsmSensWeight::Discrete ? "discrete"
                                                             : "continuum";
    info.plsm_frac_eps_mult = options.plsm.frac_eps_mult;
    info.plsm_frac_mollified = options.plsm.frac_mollified;
    info.plsm_frac_sens_exact = options.plsm.frac_sens_exact;
    info.plsm_frac_eps_l1 = options.plsm.frac_eps_l1;
    info.plsm_margin_probe_every = options.plsm.margin_probe_every;
    info.plsm_margin_plateau_probes = options.plsm.margin_plateau_probes;
    info.plsm_margin_plateau_tol = options.plsm.margin_plateau_tol;
  }
  info.draft_quality = options.draft_quality;
  info.draft_loose_tol = options.draft_loose_tol;
  info.draft_escalation_c_gap = options.draft_escalation_c_gap;
  info.draft_use_design_trigger = options.draft_use_design_trigger;
  info.draft_escalation_design_flip = options.draft_escalation_design_flip;
  info.min_feature_mm = options.min_feature_mm;
  info.margin_stop = options.margin_stop;
  info.infill_percent = options.infill_percent;
  info.width_aware_knockdown = options.width_aware_knockdown;
  info.wall_loops = options.wall_loops;
  info.wall_line_width_mm = options.wall_line_width_mm;
  // Echo the EFFECTIVE outer line width (< 0 mirror → inner) and the derived solid
  // wall-ring thickness t the accept gate would size — so run_info records what was
  // actually used, and the maintainer can read t off a real job (handoff
  // line-width-plumbing). The thickness comes from the ONE construction
  // (knockdown_spec_for), never a re-derived formula, so the echo can't drift from the
  // gate's own value.
  info.wall_line_width_outer_mm = options.wall_line_width_outer_mm >= 0.0
                                      ? options.wall_line_width_outer_mm
                                      : options.wall_line_width_mm;
  info.wall_thickness_mm = knockdown_spec_for(options).wall_thickness_mm;
  info.has_design_box = options.design_box.has_value();
  info.ladder = options.volume_fraction_ladder;
  // Task 2026-08-03-growth-ladder — derived from the rungs themselves (a growth
  // ladder is one whose rungs exceed 1.0), so the name and the numbers beside it
  // cannot drift apart.
  info.ladder_mode = (!info.ladder.empty() && info.ladder.front() > 1.0)
                         ? "growth"
                         : "reduction";
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

// THE rotation this variant's exported geometry is baked with, or a null option
// when the export stays in model-space coordinates (handoff
// 2026-08-01-bake-build-orientation). ONE helper, shared by the solid export, the
// latticed export and the receipt, so the file, the companion and the document
// can never be built from three different rotations.
std::optional<BuildFrameRotation> variant_bake_rotation(
    const MinimizePlasticVariant& variant) {
  if (!variant.export_baked) return std::nullopt;
  return build_frame_rotation(variant.applied_build_dir);
}

// ── THE ANALYTIC EXPORT (task 2026-08-10-plsm-production, S1(d)) ───────────
//
// ★ THE DESIGN, RATHER THAN A SAMPLING OF IT. A PLSM rung's design IS the
// coefficient vector: 685 KB on his part against `rho.f64`'s 3.75 MB, and
// re-evaluable at ANY resolution instead of only at the one it was optimised on.
// The voxel field stays the thing everything downstream reads — the certificate,
// the mesh, the lattice — because that is what makes the mode a drop-in; this is
// written BESIDE it so a later pass can re-evaluate the same design finer without
// re-running the optimisation.
//
// WHAT READS IT: `topopt::plsm_evaluate(lattice, basis, alpha, nx, ny, nz,
// factor, threads)` reconstructs phi on any lattice from `<stem>_alpha.f64` plus
// the `<stem>_alpha.meta` beside it. ★ THE ERSATZ RECIPE IS THE ONE THE `ersatz`
// KEY NAMES AND NOT A FIXED FORMULA — under `fraction` (the production default
// since 2026-08-13) there is no eta in the density at all, and the .meta writes
// the sub-cell recipe instead. `external_field_surface_probe` reads the resulting
// occupancy field directly. Nothing in the shipped pipeline consumes it yet, and
// that is stated rather than implied: it is an OUTPUT, not an input, until a
// consumer exists.
//
// A NO-OP on every SIMP rung — `plsm_alpha` is empty there and this writes
// nothing, so a default run's out_dir is byte-for-byte what it was.
std::string export_variant_alpha(const MinimizePlasticVariant& variant,
                                 const std::string& out_dir, const JobOutput& out,
                                 const VoxelGrid& sg) {
  if (variant.plsm_alpha.empty()) return {};
  char digits[8];
  std::snprintf(digits, sizeof(digits), "%03d",
                static_cast<int>(std::lround(variant.requested_volume_fraction *
                                             100.0)));
  const std::string stem =
      join_path(out_dir, out.mesh_prefix + "_" + digits + "_alpha");
  {
    std::ofstream f(stem + ".f64", std::ios::binary);
    if (!f) throw JobError("cannot open output file for writing: " + stem + ".f64");
    f.write(reinterpret_cast<const char*>(variant.plsm_alpha.data()),
            static_cast<std::streamsize>(variant.plsm_alpha.size() *
                                         sizeof(double)));
    f.flush();
    if (!f) throw JobError("failed writing output file: " + stem + ".f64");
  }
  const PlsmKnotLattice& L = variant.plsm_lattice;
  std::ostringstream m;
  m.precision(17);
  m << "# THE ANALYTIC DESIGN: phi(x) = sum_i alpha_i psi(|x - x_i|_R).\n"
    << "# alpha is " << stem << ".f64, " << variant.plsm_alpha.size()
    << " float64 in x-fastest knot order.\n"
    << "# Rebuild with topopt::plsm_make_lattice(nx, ny, nz, knots_vox..., "
       "support)\n"
    << "# then topopt::plsm_evaluate(lattice, basis, alpha, nx*F, ny*F, nz*F, F, "
       "threads);\n"
    // ★ THE RECIPE FOLLOWS THE ERSATZ THE DESIGN WAS OPTIMISED UNDER, because a
    // reader who rebuilds `rho` from `alpha` with the wrong one gets a different
    // object. Under `fraction` there is no eta in the density at all, and a line
    // that said there was would be a lie in the file that exists to be trusted.
    << (variant.plsm_ersatz == PlsmErsatz::VolumeFraction
            ? "# the ersatz is the VOLUME FRACTION of each cell inside {phi < 0}:\n"
              "#   sample frac_samples^3 points per cell at\n"
              "#     x = i + (p + 0.5)/k - 0.5   (the SAME lattice plsm_evaluate\n"
              "#     uses at factor = k, so the two nest exactly)\n"
              "#   and take the fraction with phi < 0 — mollified by the\n"
              "#   quadrature band when frac_mollified (see plsm_frac.hpp).\n"
              "#   FROZEN cells are STAMPED 1 / 0 by the mask, not sampled.\n"
              "#   eta_voxels below does NOT enter this density.\n"
            : "# the ersatz is plsm_heaviside(-phi, eta_voxels * spacing).\n")
    << "basis " << (variant.plsm_basis_kind == PlsmBasisKind::Gaussian
                        ? "gaussian" : "wendland") << "\n"
    // ★ THREE NUMBERS, PER AXIS. A reader that collapses these to one has
    // reintroduced the slab trap R4 exists to forbid.
    << "knots_vox " << L.dx << " " << L.dy << " " << L.dz << "\n"
    << "support_vox " << L.rx << " " << L.ry << " " << L.rz << "\n"
    << "counts " << L.mx << " " << L.my << " " << L.mz << "\n"
    << "pad " << L.padx << " " << L.pady << " " << L.padz << "\n"
    << "n_coeff " << variant.plsm_alpha.size() << "\n"
    << "n_voxels " << sg.voxel_count() << "\n"
    << "compression "
    << (variant.plsm_alpha.empty()
            ? 0.0
            : static_cast<double>(sg.voxel_count()) /
                  static_cast<double>(variant.plsm_alpha.size()))
    << "\n"
    << "eta_voxels " << variant.plsm_eta_voxels << "\n"
    << "nx " << sg.nx << "\nny " << sg.ny << "\nnz " << sg.nz << "\n"
    << "spacing " << sg.spacing << "\n"
    << "ox " << sg.origin.x << "\noy " << sg.origin.y << "\noz " << sg.origin.z
    << "\n"
    << "requested_vf " << variant.requested_volume_fraction << "\n"
    << "achieved_vf " << variant.optimization.volume_fraction << "\n"
    // ★ THE LOAD-PATH GUARANTEE, MEASURED. The smallest ersatz occupancy any
    // FrozenSolid voxel took under the smooth boolean. PR 324 measured that 40
    // leaked frozen voxels of 40,216 break the anchor-to-load walk and reject
    // every certification; this number being above 0.5 is why that cannot happen,
    // and plsm_optimize refuses to run when it is not.
    << "frozen_floor_occupancy " << variant.plsm_frozen_floor_occupancy << "\n"
    // ── ★ THE ERSATZ THIS DESIGN WAS OPTIMISED UNDER (task 2026-08-13) ──────
    // A reader that rebuilds phi from `alpha` must know which density the
    // optimiser saw, because the two are not the same object: `heaviside` is
    // H_eta at the cell centre, `fraction` is the exact cell volume fraction
    // inside {phi < 0} by frac_samples^3 sub-samples. The `# the ersatz is
    // plsm_heaviside(...)` line above is the HEAVISIDE recipe and is wrong for a
    // fraction design — which is why the recipe is named here rather than only
    // in a comment.
    << "ersatz "
    << (variant.plsm_ersatz == PlsmErsatz::VolumeFraction ? "fraction"
                                                          : "heaviside")
    << "\n"
    << "sens_weight "
    << (variant.plsm_sens_weight == PlsmSensWeight::Discrete ? "discrete"
                                                             : "continuum")
    << "\n"
    << "frac_samples " << variant.plsm_frac_samples << "\n"
    << "frac_cut_cells " << variant.plsm_frac_cut_cells << "\n"
    << "frac_sample_wall_s " << variant.plsm_frac_sample_wall_s << "\n"
    << "frac_sens_wall_s " << variant.plsm_frac_sens_wall_s << "\n"
    // ── ★★ THE STOPPING RULE'S RECORD. A run that hit the ceiling and one whose
    // certified margin plateaued are different objects.
    << "stop_reason " << (variant.plsm_stop_reason.empty()
                              ? std::string("unrecorded")
                              : variant.plsm_stop_reason)
    << "\n"
    << "margin_peak_iteration " << variant.plsm_margin_peak_iteration << "\n"
    << "margin_peak " << variant.plsm_margin_peak << "\n"
    << "margin_probe_wall_s " << variant.plsm_margin_probe_wall_s << "\n"
    << "# margin_probe: iteration margin load_path_ok — the CURVE the rule "
       "watched. R4: never a point.\n";
  for (std::size_t q = 0; q < variant.plsm_margin_probe_iterations.size(); ++q)
    m << "margin_probe " << variant.plsm_margin_probe_iterations[q] << " "
      << variant.plsm_margin_probe_values[q] << " "
      << (q < variant.plsm_margin_probe_load_path_ok.size()
              ? static_cast<int>(variant.plsm_margin_probe_load_path_ok[q])
              : 0)
      << "\n";
  // ── ★ THE TOPOLOGY COUNTERS, ON EVERY RUN (the constraint does NOT ship) ──
  m << "void_components " << variant.plsm_topology.components << "\n"
    << "void_chi " << variant.plsm_topology.chi << "\n"
    << "void_enclosed_solid " << variant.plsm_topology.enclosed_solid << "\n"
    << "void_sealed_pockets " << variant.plsm_topology.sealed_pockets << "\n"
    << "void_tunnels " << variant.plsm_topology.tunnels << "\n"
    << "void_sealed_voxels " << variant.plsm_topology.sealed_voxels << "\n"
    << "void_sealed_volume_mm3 " << variant.plsm_topology.sealed_volume_mm3
    << "\n"
    << "void_voxels " << variant.plsm_topology.void_voxels << "\n"
    // ★ AND THE FIELD IT IS NOT. This is the analytic design; the CERTIFIED
    // object is the voxel field in design.bin and the mesh beside it. A margin
    // computed on one is not a margin for the other — re-describing a design
    // moved its certified margin 3254 -> 1667 on one design and 2015 -> 3221 on
    // another (PR 324 §5). Re-evaluating this at a different resolution produces
    // a DIFFERENT OBJECT and it must be re-certified.
    << "# NOT CERTIFIED. The certificate in report.json belongs to the voxel "
       "field this was optimised on, at this resolution, and does NOT carry over "
       "to a re-evaluation at another one.\n";
  write_text_file(stem + ".meta", m.str());
  return stem + ".f64";
}

// Write one accepted variant's mesh into out_dir and return its path. Smooth-
// export (handoff 086): factor 1 writes v3.mesh verbatim; factor > 1 re-extracts
// the SAME iso-surface from the SAME physical density resampled finer on `sg` (the
// solved grid). Shared by the batch export loop and the streaming on_variant
// callback so both write byte-identical files.
//
// BAKED ORIENTATION (handoff 2026-08-01-bake-build-orientation): when this
// variant's orientation was chosen for the user, the vertices written here are
// ROTATED so the certified build direction is +Z in the file. Rotated vertices,
// not a build transform — a 3MF transform is advice that "place on bed" resets,
// and then the certificate would describe an object the slicer never produces.
std::string export_variant_mesh(const MinimizePlasticVariant& variant,
                                const std::string& out_dir, const JobOutput& out,
                                const VoxelGrid& sg, double printed_iso = 0.5,
                                const StepModel* cad = nullptr) {
  const std::string path = join_path(
      out_dir, mesh_file_name(out.mesh_prefix, variant.requested_volume_fraction,
                              out.mesh_format));
  const int sf = out.smooth_factor;
  TriangleMesh smooth;  // only populated when sf > 1
  if (sf > 1) {
    const TriangleMesh raw = marching_cubes_resampled(
        sg.nx, sg.ny, sg.nz, sg.spacing, sg.origin,
        variant.optimization.physical_density, printed_iso, sf,
        ResampleInterp::Tricubic);
    smooth = keep_largest_component(raw);
  }
  // CAD-FACE PROJECTION (task 2026-08-06-cad-face-projection), DEFAULT OFF.
  //
  // WHY IT HAPPENS HERE, and it is the only place it can. The exported mesh
  // carries no face ids and cannot: it is extracted by marching cubes from a
  // scalar density field (the call just above), which has no face channel, and
  // written to STL/3MF, which have no per-triangle attribute slot. So the
  // attribution has to be re-established from geometry — and this is the last
  // point in the pipeline where the imported CAD is still in hand.
  //
  // It runs BEFORE the bake rotation so the projection is done in the frame the
  // CAD's own planes and cylinder axes are stated in.
  // ★ AND ONLY WHERE THE SURFACES WERE READ, NOT FITTED (task
  // 2026-08-06-arm-projection-and-void-check, the PR 309 CI failure).
  //
  // `faces_are_fitted` is true for an STL/3MF import, whose "faces" are
  // manufactured by segmentation: segment.cpp:185 fits a plane from a patch's
  // MEAN NORMAL and :280 fits a cylinder by least squares, within a tolerance.
  // Projecting onto those is not restoring a stated surface, it is snapping
  // geometry onto an estimate of itself — the one thing this operation promised
  // never to do ("nothing is averaged, no surface is estimated", job.hpp).
  //
  // IT ALSO BREAKS AN INVARIANT, which is how it was caught. The fit is computed
  // FROM the imported vertices, so the same part imported from STL (quantised to
  // float32 by the format) and from 3MF (full double, decimal text) fits
  // slightly different surfaces and therefore exports different files. On
  // plate_bore that is ~1000 of 6972 corners differing by ~2.4e-07 mm — a
  // pervasive last-bit divergence, six orders of magnitude smaller than the
  // ~1.5 mm voxel, i.e. exactly the size of a float32 quantum in the INPUT.
  // `threemf_import`'s "STL and 3MF export byte-identical variant meshes" is the
  // assertion that says two front doors to the same part must not disagree, and
  // it is right.
  //
  // Measured, not reasoned: the fixture passes on the merge base, fails on this
  // branch, and passes again with `project_cad_faces` false — see
  // evidence/…/a1_root_cause.txt.
  TriangleMesh projected;
  if (out.project_cad_faces && cad != nullptr && !cad->faces.empty() &&
      !cad->faces_are_fitted) {
    const TriangleMesh& src = (sf > 1) ? smooth : variant.v3.mesh;
    CadProjectOptions po = cad_project_options_for_grid(sg.spacing);
    po.enabled = true;
    const CadAttribution att = attribute_to_cad_faces(src, *cad, po);
    projected = project_onto_cad_faces(src, *cad, po, att);
  }
  const TriangleMesh& model_mesh =
      !projected.vertices.empty() ? projected
                                  : ((sf > 1) ? smooth : variant.v3.mesh);
  const std::optional<BuildFrameRotation> R = variant_bake_rotation(variant);
  TriangleMesh baked;
  if (R) baked = rotate_mesh(model_mesh, *R);
  const TriangleMesh& export_mesh = R ? baked : model_mesh;
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

// --- Lattice export (handoff 2026-07-28-lattice-generation-production) --------
// Emit a LATTICED companion to an accepted variant's solid mesh: the solid shell
// (variant.v3.mesh) unioned with an octet strut lattice filling the part's solid
// interior, STREAMED to disk so peak RSS stays flat in the output size. The union
// is written as an interpenetrating triangle soup — three fresh vertices per
// facet, exactly what the harness emitted and the PR 201 print certified — so the
// slicer's boolean union resolves the overlaps. Runs wherever run_job runs (the
// Mac worker's topopt-cli); the file lands in out_dir and is fetched on demand, so
// the iPad never holds the mesh.
struct LatticeExportOutcome {
  std::vector<std::string> paths;  // files written (STL and/or 3MF)
  LatticeGenStats stats;           // generator counts (identical across formats)
  long long region_voxels = 0;     // SOLID voxels inside the latticed cells
  // SOLID COMPANION (task lattice-page-core-hookup, stages 1+4). When roles or
  // grading leave printed voxels UN-latticed (exclude regions, everything
  // outside the include union, the grading law's too-thin-stays-solid
  // fallback), the exported file must honour "kept solid": those voxels are
  // emitted as a closed marching-cubes body into the same interpenetrating
  // soup, and their volume is accounted SEPARATELY from interior/skin/rim
  // (H1c; voxel basis, count × spacing³, matching the mass accounting).
  // Emitted ONLY when roles/grading are in play — a legacy uniform whole-part
  // job writes byte-identical files.
  bool solid_companion = false;
  long long solid_region_voxels = 0;      // printed, non-keep-out, not latticed
  double solid_region_volume_mm3 = 0.0;   // voxel basis: count × spacing³
  std::uint64_t solid_region_triangles = 0;

  // ★ THE NO-PROTRUSION INVARIANT, MEASURED ON WHAT WAS WRITTEN (task
  // 2026-08-08-strut-clip-matches-shell, bar R3). Every vertex of every LATTICE
  // triangle — struts, nodes, anchor balls, skin, rim; NOT the shell's own
  // triangles and NOT the solid companion's — is evaluated against the exact
  // signed distance to the shell in the same file, and the largest amount by
  // which any of them lies OUTSIDE it is recorded here.
  //
  // MEASURED, not derived. The clip's Lipschitz certificate proves containment
  // for the spans it certified, but the generator also has a fast path that
  // skips the clip entirely (lattice_gen.cpp:344), a node/anchor ball pass, and
  // a skin pass with its own relaxed predicate — so "the clip is correct"
  // and "nothing was written outside the shell" are different claims. This is
  // the second one, and it is what the maintainer can actually see in a slicer.
  //
  // The measurement runs on the STREAM, so peak RSS stays flat in output size
  // (bar B8): the sink wrapper holds one running maximum, and a per-voxel
  // lower-bound field keeps deep-interior vertices to an array lookup.
  bool protrusion_measured = false;
  // THE ONLY GEOMETRY ALLOWED OUTSIDE THE SHELL, in mm — the clip's own crossing
  // tolerance, PLUS the freeform skin's declared sag budget when that pass ran.
  // The freeform skin deliberately buys `kLatticeSkinSagBudgetMm` of overshoot
  // against the base surface (lattice_gen.hpp says why), so a run that armed it
  // is allowed exactly that and not a micron more; every other run is allowed
  // nothing. Recorded so the receipt states the bar it was judged against rather
  // than leaving the reader to infer it.
  double protrusion_allowance_mm = 0.0;
  // WHICH SURFACE THE STRUTS WERE CLIPPED AGAINST, read from the boundary
  // itself rather than written as a constant beside it. The whole defect was two
  // surfaces that everyone believed were one, so a receipt that ASSERTS the
  // answer instead of reporting it would be repeating the mistake in prose.
  bool clipped_against_shell = false;
  double max_protrusion_mm = 0.0;   // largest distance OUTSIDE the shell
  long long protruding_vertices = 0;  // lattice vertices strictly outside it
  long long measured_vertices = 0;    // lattice vertices examined
  Vec3 worst_protrusion_at{};         // where the worst one is, model frame
  // WHICH GENERATOR PASS emitted the worst one. The generator has five of them
  // (interior struts, node balls, anchor balls, skin, rim) and they reach the
  // boundary through DIFFERENT predicates — the struts through a certified clip,
  // the node balls through a single sd >= r test, the freeform skin through a
  // deliberately relaxed one. A refusal that says only "0.8 mm somewhere" sends
  // the next reader back to the whole file; naming the pass is the difference
  // between a diagnosis and a puzzle.
  std::string worst_protrusion_pass;
};

std::string lattice_base_name(const std::string& prefix, double requested_vf) {
  char digits[8];
  std::snprintf(digits, sizeof(digits), "%03d",
                static_cast<int>(std::lround(requested_vf * 100.0)));
  return prefix + "_" + digits + "_lattice";
}

// Forward declarations of two small JSON/vec helpers defined lower in this TU, so
// the lattice certification helpers below (which precede them) can use them.
Vec3 normalized(const Vec3& v);
std::string json_num(double v);
std::string json_str(const std::string& s);
double mesh_enclosed_volume_mm3(const TriangleMesh& m);

// Shared lattice OCCUPANCY + BOUNDARY (lattice certification E2E, handoff
// 2026-07-29-lattice-certification-e2e; boundary finish, handoff
// 2026-07-29-lattice-boundary-finish). The ONE predicate is now a
// LatticeBoundary: the design's solid voxel set (physical_density >= 0.5, the
// marching-cubes iso) as the base region, minus every declared clearance
// keep-out — the EXISTING resolved ClearanceGeometry, never a second keep-out
// concept. BOTH the exported geometry (generate_lattice activates cells by
// OVERLAP with it and clips every strut solid against it) and the certification
// posture (lattice_certification_mask) are built from THIS ONE object, so the
// object the gate certifies and the file the slicer opens are the SAME region
// by construction — extended from the region to the boundary (bar B7).
// `sg`/`dens` must outlive the returned boundary.
// The job's lattice ROLE regions (task lattice-page-core-hookup stage 1),
// resolved through the SAME manual-primitive machinery a hand-placed clearance
// uses (resolve_clearance_manual) with ZERO margins — the primitive IS the
// region, there is no keep-out growth. No second geometry concept.
struct LatticeRoleRegions {
  std::vector<ClearanceGeometry> includes;
  std::vector<ClearanceGeometry> excludes;
};

// ★ RESOLVE ONE face REGION INTO A VOXEL MASK (task 2026-08-15-lattice-regions).
//
// THE VOLUME IS THE PROTECTION'S VOLUME. `region_member_voxels` + `cut_voxels`
// at `region_depth_layers(depth_mm, spacing)` layers is EXACTLY what
// `mask_step_region` walks for a protection at the same depth — same primitive,
// same rounding, same voxels. That identity is bar R5, and it is structural
// here rather than agreed: both call the same two functions with the same
// arguments.
//
// The mask carries the grid it was built on, so every later membership test
// converts the query point into THIS lattice regardless of which grid the caller
// is walking (an expanded design-box grid, the certification grid, the part
// grid).
std::shared_ptr<const ClearanceVoxelMask> region_lattice_mask(
    const VoxelGrid& grid, const StepModel& model,
    const ResolvedFaceRegion& region, double depth_mm) {
  auto m = std::make_shared<ClearanceVoxelMask>();
  m->nx = grid.nx;
  m->ny = grid.ny;
  m->nz = grid.nz;
  m->spacing = grid.spacing;
  m->origin = grid.origin;
  m->inside.assign(grid.voxel_count(), 0);
  const int layers = region_depth_layers(depth_mm, grid.spacing);
  const std::vector<int> members =
      region_member_voxels(grid, model, region, layers);
  for (int idx : cut_voxels(grid, members, region.cuts))
    if (idx >= 0 && static_cast<std::size_t>(idx) < m->inside.size())
      m->inside[static_cast<std::size_t>(idx)] = 1;
  return m;
}

// `model` / `grid` are needed ONLY by `kind == "region"`; a job with no
// region-backed lattice region may pass nullptr and takes a byte-identical path.
// A region-backed one with nothing to resolve against REFUSES rather than
// resolving to an empty mask — an empty include region silently latticing
// NOTHING is the failure this whole track exists to stop seeing.
LatticeRoleRegions lattice_role_regions_from_job(const JobDescription& job,
                                                 const StepModel* model,
                                                 const VoxelGrid* grid) {
  LatticeRoleRegions rr;
  std::vector<ResolvedFaceRegion> resolved;
  bool resolved_done = false;
  for (const JobLatticeRegion& r : job.lattice.regions) {
    if (r.kind == "region") {
      if (model == nullptr || grid == nullptr)
        throw JobError(
            "lattice region_id " + std::to_string(r.region_id) +
            ": a \"region\" lattice region needs the imported model and the "
            "run's grid to resolve its voxels, and this call site has neither. "
            "This is a wiring defect, not a job error.");
      if (!resolved_done) {
        resolved = resolve_face_regions(*model, job.loads.face_regions);
        resolved_done = true;
      }
      const ResolvedFaceRegion* found = nullptr;
      for (const ResolvedFaceRegion& rr2 : resolved)
        if (rr2.id == r.region_id) { found = &rr2; break; }
      if (found == nullptr)
        throw JobError(
            "a \"region\" lattice region names region_id " +
            std::to_string(r.region_id) +
            ", which is not declared in \"loads.face_regions\". A region must "
            "be declared once and referred to by id.");
      ClearanceGeometry g;
      g.valid = true;
      g.kind = ClearanceKind::Face;  // unread while `mask` is set; a stable default
      g.mask = region_lattice_mask(*grid, *model, *found, r.depth_mm);
      if (g.mask->set_count() == 0)
        throw JobError(
            "lattice region " + std::to_string(r.region_id) +
            (found->name.empty() ? "" : " \"" + found->name + "\"") +
            " selects NO solid voxels at " + std::to_string(r.depth_mm) +
            " mm depth on this grid (spacing " +
            std::to_string(grid->spacing) +
            " mm). It would lattice nothing and report success; it is refused "
            "instead. Use a coarser depth, a finer resolution, or a region that "
            "reaches part material.");
      (r.role == "include" ? rr.includes : rr.excludes).push_back(std::move(g));
      continue;
    }
    ManualClearanceGeometry mg;
    ClearanceParams p;  // all margins zero: the primitive is the region
    if (r.kind == "bolt") {
      mg.kind = ClearanceKind::Bolt;
      p.kind = ClearanceKind::Bolt;
      mg.axis_point = r.axis_point;
      mg.axis_dir = r.axis_dir;
      mg.radius_mm = r.radius_mm;
      mg.half_length_mm = r.half_length_mm;
    } else {  // "face" — a bounded slab; the region's own depth is the extent
      mg.kind = ClearanceKind::Face;
      p.kind = ClearanceKind::Face;
      p.slab_depth_mm = r.depth_mm;
      mg.origin = r.origin;
      mg.normal = r.normal;
      mg.half_u_mm = r.half_u_mm;
      mg.half_w_mm = r.half_w_mm;
    }
    const ClearanceGeometry g = resolve_clearance_manual(mg, p);
    if (!g.valid) continue;  // degenerate → the rasterizer's safe no-op
                             // (parse_job already refused zero extents)
    (r.role == "include" ? rr.includes : rr.excludes).push_back(g);
  }
  return rr;
}

// Copy the grading law's CELL-SIZE plan into the run_info record — ONE filler for
// both call sites (analyze_job and run_job), so the two receipts can never disagree
// about what the cell law did (handoff 2026-08-01-lattice-cell-size-sweep).
// A +inf member width is the "thicker than the EDT cap" sentinel; it is carried as a
// negative here and serialized as JSON null, matching the scalar fields above.
void fill_grading_cell_plan(RunInfo& gi, const GradedField& gf) {
  const CellSizePlan& P = gf.cell_plan;
  gi.grading_cell_mode = cell_size_mode_name(gf.cell_mode);
  gi.grading_cell_base_mm = P.base_cell_mm;
  gi.grading_cell_max_level = P.max_level;
  gi.grading_cell_latticed_cells = P.latticed_cells;
  gi.grading_cells_raised_to_floor = P.cells_raised_to_floor;
  gi.grading_cells_dropped_unprintable = P.cells_dropped_unprintable;
  gi.grading_cells_split_by_balance = P.cells_split_by_balance;
  gi.grading_cell_any_out_of_regime = P.any_out_of_regime;
  gi.grading_cell_levels.clear();
  for (const CellLevelReport& r : P.levels) {
    RunInfo::GradingCellLevel L;
    L.level = r.level;
    L.cell_size_mm = r.cell_size_mm;
    L.cells = r.cells;
    L.voxels = r.voxels;
    L.min_member_width_mm =
        std::isfinite(r.min_member_width_mm) ? r.min_member_width_mm : -1.0;
    L.min_cells_per_member =
        std::isfinite(r.min_cells_per_member) ? r.min_cells_per_member : -1.0;
    L.min_strut_diameter_mm =
        std::isfinite(r.min_strut_diameter_mm) ? r.min_strut_diameter_mm : 0.0;
    L.max_strut_diameter_mm = r.max_strut_diameter_mm;
    L.out_of_regime = r.out_of_regime;
    L.any_strut_below_min = r.any_strut_below_min;
    gi.grading_cell_levels.push_back(L);
  }
}

// THE PRINTED-SET THRESHOLD this run reads designs at (task multiscale-lattice-to).
// 0.5 — the M3.5 iso — on every classic run, so every existing path is byte-for-byte
// unchanged; below the certified band's floor on a MULTISCALE run, where a voxel at
// density 0.30 is a real 30%-dense lattice cell and not a half-empty solid voxel.
// ONE resolver, read by the mesh export, the lattice candidate set, the boundary
// base and the grading law, so the shape the file carries and the shape the gate
// certified cannot disagree. See lattice_material.hpp for the derivation.
double run_printed_iso(const MinimizePlasticOptions& o) {
  return o.multiscale_lattice ? multiscale_printed_iso(o.multiscale_topology) : 0.5;
}

// THE MULTISCALE REGION (task multiscale-lattice-to) — which voxels the OPTIMIZER
// treats as lattice material. This is the DESIGN-INDEPENDENT half of
// lattice_certification_mask: the same keep-out and role membership tests, on the
// same resolved ClearanceGeometry objects, with the density-dependent terms (the
// printed-iso test and the cell-overlap proof) deliberately left out.
//
// WHY IT MUST BE DESIGN-INDEPENDENT: this mask decides each voxel's MATERIAL LAW
// for the whole run. If it were a function of the evolving density it would flip
// voxels between the cubic and the penalized isotropic law from iteration to
// iteration, which is a discontinuous objective and a guaranteed oscillation. The
// role regions and keep-outs are pure geometry, so this is well-defined before the
// first solve and is resolved exactly once.
//
// The consequence is stated rather than hidden: a voxel in the region that the
// certification mask later drops (its cell could not be proven to overlap, or the
// grading law left its member solid) was optimized as lattice and will be printed
// SOLID — which is CONSERVATIVE (solid is stiffer than the lattice the optimizer
// assumed) and is exactly the direction the accept gate can absorb. The receipts
// report both counts so the difference is visible.
std::vector<char> multiscale_region_mask(
    const VoxelGrid& sg, const std::vector<ClearanceGeometry>& kos,
    const LatticeRoleRegions& roles) {
  LatticeBoundary members;
  for (const ClearanceGeometry& g : kos)
    members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
  for (const ClearanceGeometry& g : roles.includes) members.add_include_region(g);
  for (const ClearanceGeometry& g : roles.excludes) members.add_exclude_region(g);
  std::vector<char> mask(sg.voxel_count(), 0);
  for (int k = 0; k < sg.nz; ++k)
    for (int j = 0; j < sg.ny; ++j)
      for (int i = 0; i < sg.nx; ++i) {
        if (!sg.solid(i, j, k)) continue;
        const Vec3 c{sg.origin.x + (i + 0.5) * sg.spacing,
                     sg.origin.y + (j + 0.5) * sg.spacing,
                     sg.origin.z + (k + 0.5) * sg.spacing};
        // PRECEDENCE, identical to lattice_certification_mask: clearance beats
        // both roles; exclude beats include.
        if (members.in_keep_out(c, 0.0)) continue;
        if (members.in_exclude_region(c, 0.0)) continue;
        if (members.has_include_regions() && !members.in_include_region(c, 0.0))
          continue;
        mask[sg.index(i, j, k)] = 1;
      }
  return mask;
}


// ── FIT MODE (task 2026-08-05-lattice-cell-fit-mode) ──────────────────────────────

// ★ THE ONE PLACE `"auto"` IS RESOLVED (bar S4). Every caller that turns the job's
// cell_mode string into a CellSizeMode goes through here, so the constant that decides
// what `auto` means is read once and cannot be applied on one path and missed on
// another. `false` for an unknown name, exactly like cell_size_mode_from_name.
bool resolve_cell_mode(const std::string& name, CellSizeMode& out) {
  if (!cell_size_mode_from_name(name.c_str(), out)) return false;
  if (out == CellSizeMode::Auto && production_lattice_auto_is_fit())
    out = CellSizeMode::Fit;
  return true;
}

// The region's THINNEST declared dimension — the one that bounds how many cells can
// lie across the latticed body. Spelled ONCE: the pre-flight and the fit derivation
// must measure the same thing or they describe different jobs.
double lattice_region_thinnest_extent_mm(const JobLatticeRegion& r) {
  return r.kind == "bolt"
             ? std::min(2.0 * r.radius_mm, 2.0 * r.half_length_mm)
             : std::min(r.depth_mm,
                        std::min(2.0 * r.half_u_mm, 2.0 * r.half_w_mm));
}

// ★ THE SAME QUESTION, ASKED OF A VOXEL SET (task 2026-08-15-lattice-regions
// §1c). The analytic version above reads the region's thinnest DECLARED
// dimension. A face region declares no dimensions — it is a set — so the
// thickness has to be measured.
//
// IT IS NOT A SECOND MEASUREMENT. `local_member_thickness_mm` (voxel.hpp, PR
// 206) is the Hildebrand inscribed-sphere thickness already used by the
// width-aware knockdown gate and by the grading law's cells-per-member test:
// tau(v) is the diameter of the largest ball that fits inside the set and
// contains v. Run over a synthetic density that is 1 inside the region and 0
// outside, it measures the REGION's own local thickness — exactly what "the
// thinnest dimension of this volume" means, and by the same definition the
// grading law compares a cell against. Reused, not re-derived, as §1c asks.
//

// What FIT derived for ONE declared include region.
struct FitRegionCell {
  std::size_t job_region_index = 0;   // index into job.lattice.regions
  // ★ The density the derivation WOULD have chosen, kept alongside the one in
  // force, so a receipt can show both and the app can show the valid range
  // (§2d): [derived, rho_max] is exactly the set of densities that print at
  // this region's cell.
  double derived_relative_density = 0.0;
  double stated_relative_density = 0.0;  // 0 = none stated
  double extent_mm = 0.0;             // the thinnest declared dimension
  bool feasible = false;              // a printable AND percolating pair exists
  double cell_mm = 0.0;               // the derived cell (0 when infeasible)
  double relative_density = 0.0;      // the lightest band density printing at it
  double strut_mm = 0.0;
  double cells_per_member = 0.0;      // extent / cell
  bool out_of_regime = false;         // under the ACCURACY floor: buildable, uncertified
  double min_printable_cell_mm = 0.0; // w / phi(rho_max) — region-independent
  double min_width_certifiable_mm = 0.0;
  double min_width_buildable_mm = 0.0;
};

// ★ THE DERIVATION, PER DECLARED INCLUDE REGION. The law, in one line:
//
//     cell = max(extent / N*, the finest printable cell)
//
// N* cells across where the region can hold them (which is the LIGHTEST certified
// lattice for that member — exactly the coarse end lattice_derive_cell_for_member
// reports), and the finest printable cell where it cannot, because that is the cell
// with the MOST cells across and therefore the least inaccuracy accepted. Both ends
// come from lattice_derive_cell_for_member; nothing is invented here.
//
// The returned vector is in the SAME ORDER as LatticeRoleRegions::includes — it
// mirrors that resolver's own filtering — so a 1-based region id from the grading
// call site indexes it directly. The call sites assert the two sizes agree rather
// than trusting the mirror.
// The derivation itself, shared by the analytic and the region-backed branches
// of fit_region_cells so the two cannot describe different laws. `f.extent_mm`
// must already be set — that is the ONLY thing the two branches derive
// differently (declared half-extents vs a measured voxel-set thickness).
// ★ THE STATED DENSITY ENTERS HERE, AT THE DENSITY STEP, AND THE CELL DOES NOT
// MOVE (task 2026-08-16-per-sector-density-override §1c).
//
// The derived chain is extent -> cell = max(extent/N*, finest printable) ->
// rho = the LIGHTEST density whose strut still prints at that cell -> strut.
// A stated rho replaces the third step only. The consequences, both measured
// (evidence r0_density_range.txt):
//
//   * the strut becomes cell * phi(rho) and RISES with rho, so the region stays
//     printable and stays at exactly N* cells per member — it keeps certifying;
//   * a rho BELOW the derived one implies a strut under the profile's bead and
//     is REFUSED with the number. It is refusable rather than clampable because
//     the derived density IS the floor of the valid range at a fixed cell.
//
// ★ WHAT RE-DERIVING THE CELL WOULD HAVE DONE (cell = w / phi(rho)): the strut
// would be pinned at exactly the bead width for EVERY density, so nothing could
// ever refuse — but cells-per-member would fall with rho, and on his part a
// stated 0.25 against a 6.8211 mm body gives 3.52 cells per member, i.e. the
// region silently stops certifying. Both readings are honest; this one keeps
// certification and refuses what it cannot do, and the other trades
// certification away without the user asking. The full table for both is in
// r0_density_range.txt.
void fill_fit_region_cell(FitRegionCell& f, LatticeTopology topo,
                          double min_extrudable_width_mm, double n_star,
                          double stated_density = 0.0) {
  const LatticeCellDerivation d =
      lattice_derive_cell_for_member(topo, f.extent_mm, min_extrudable_width_mm);
  f.min_printable_cell_mm = d.min_printable_cell_mm;
  f.min_width_certifiable_mm = d.min_member_width_certifiable_mm;
  f.min_width_buildable_mm = d.min_member_width_buildable_mm;
  // FEASIBLE means a pair exists that PRINTS and PERCOLATES. The accuracy floor
  // is not part of this test — a region that clears percolation but not accuracy
  // is buildable and uncertifiable, which is a verdict, not a refusal.
  f.feasible = d.feasible_percolation;
  if (!f.feasible) return;
  f.cell_mm = std::max(f.extent_mm / n_star, d.min_printable_cell_mm);
  const double rho =
      lattice_min_density_for_strut(topo, f.cell_mm, min_extrudable_width_mm);
  f.derived_relative_density = rho >= 0.0 ? rho : lattice_rho_max(topo);
  f.stated_relative_density = stated_density;
  f.relative_density =
      stated_density > 0.0 ? stated_density : f.derived_relative_density;
  f.strut_mm = octet_strut_diameter_mm(f.relative_density, f.cell_mm);
  f.cells_per_member = f.extent_mm / f.cell_mm;
  f.out_of_regime = f.cells_per_member < n_star;
}

// ★ `roles` / `grid` are needed ONLY to price a `kind == "region"` include: its
// extent is MEASURED from its voxel mask (region_thinnest_extent_mm) rather than
// read off declared half-extents. Both default to nullptr, so every existing
// call site is unchanged and an all-analytic job takes the identical path.
//
// The extent is measured on the MASK's own grid, so no grid is passed here.
//
// A region-backed include with no `roles` supplied is DROPPED from this vector,
// which would silently break the index mirror `includes` relies on — so the
// call sites that can see a region kind pass them, and the mirror assertion at
// each call site is what catches it if one does not.
std::vector<FitRegionCell> fit_region_cells(const JobDescription& job,
                                            LatticeTopology topo,
                                            double min_extrudable_width_mm,
                                            const LatticeRoleRegions* roles = nullptr) {
  std::vector<FitRegionCell> out;
  if (!(min_extrudable_width_mm > 0.0)) return out;
  const double n_star = lattice_cells_per_member_min(topo);
  std::size_t include_index = 0;  // mirrors LatticeRoleRegions::includes order
  for (std::size_t ri = 0; ri < job.lattice.regions.size(); ++ri) {
    const JobLatticeRegion& r = job.lattice.regions[ri];
    if (r.role != "include") continue;
    if (r.kind == "region") {
      // The mask was resolved once by lattice_role_regions_from_job; its extent
      // is measured, not declared.
      if (roles == nullptr || include_index >= roles->includes.size() ||
          !roles->includes[include_index].mask)
        continue;
      FitRegionCell f;
      f.job_region_index = ri;
      f.extent_mm =
          region_thinnest_extent_mm(*roles->includes[include_index].mask);
      fill_fit_region_cell(f, topo, min_extrudable_width_mm, n_star,
                           r.relative_density);
      out.push_back(f);
      ++include_index;
      continue;
    }
    // MIRRORS lattice_role_regions_from_job's validity filter, so the indices line
    // up. A degenerate region is dropped there and must be dropped here too.
    ManualClearanceGeometry mg;
    ClearanceParams p;
    if (r.kind == "bolt") {
      mg.kind = ClearanceKind::Bolt;
      p.kind = ClearanceKind::Bolt;
      mg.axis_point = r.axis_point;
      mg.axis_dir = r.axis_dir;
      mg.radius_mm = r.radius_mm;
      mg.half_length_mm = r.half_length_mm;
    } else {
      mg.kind = ClearanceKind::Face;
      p.kind = ClearanceKind::Face;
      p.slab_depth_mm = r.depth_mm;
      mg.origin = r.origin;
      mg.normal = r.normal;
      mg.half_u_mm = r.half_u_mm;
      mg.half_w_mm = r.half_w_mm;
    }
    if (!resolve_clearance_manual(mg, p).valid) continue;
    ++include_index;

    FitRegionCell f;
    f.job_region_index = ri;
    f.extent_mm = lattice_region_thinnest_extent_mm(r);
    fill_fit_region_cell(f, topo, min_extrudable_width_mm, n_star,
                         r.relative_density);
    out.push_back(f);
  }
  return out;
}

// ★ §2(c) — THE SLIVER GUARD, ON THE LATTICE SIDE (task 2026-08-15-lattice-
// regions). PR 331's §5(a) refuses a grid split whose cells fall under the voxel
// floor, naming the number AND the arithmetic ("at most 42 sub-regions can clear
// the floor here"). The lattice side needs the same shape of refusal for the
// same reason: a sector that cannot carry a lattice at ANY legal cell should say
// so before the run, not leave a receipt to be read afterwards.
//
// ★ IT REFUSES ON `!feasible`, NOT ON `out_of_regime`, and that boundary is not
// mine to move. This file already decided, deliberately and in writing, that a
// region which "clears percolation but not accuracy is buildable and
// uncertifiable, which is a verdict, not a refusal" (fill_fit_region_cell, the
// pre-flight's case C). Refusing there would overturn an existing decision on
// every analytic job too. Infeasible is different in kind: no printable AND
// percolating pair exists at any cell, so there is nothing to build.
//
// Scoped to `kind == "region"`: an analytic include behaves exactly as it did.
// ★ §2(a) — A STATED DENSITY TOO LIGHT TO PRINT REFUSES, WITH THE NUMBER
// (task 2026-08-16-per-sector-density-override). NEVER a silent clamp: clamping
// turns the user's instruction into a different part, and this project has been
// bitten by that exact shape before.
//
// `min_extrudable_width_mm` is USER INPUT from his print profile, and core's
// convention is that 0 means UNSET, never "use a sensible number" — so a stated
// density with no profile width refuses too rather than being checked against a
// default nobody chose.
//
// ★ MEASURED: that width branch is UNREACHABLE from the CLI. The schema already
// refuses both `lattice.min_extrudable_width_mm` and
// `grading.min_extrudable_width_mm` at 0 when their block is present, so a job
// cannot arrive here with an unset width — verified by running two jobs that try
// (evidence 2026-08-16-per-sector-density-override/r4_refusals.txt). It stays as
// a guard for direct callers of this namespace, and is NOT claimed as a
// demonstrated refusal anywhere in the handoff.
void refuse_unprintable_stated_density(
    const JobDescription& job, const std::vector<FitRegionCell>& cells,
    LatticeTopology topo, double min_extrudable_width_mm) {
  for (const FitRegionCell& f : cells) {
    if (!(f.stated_relative_density > 0.0)) continue;
    if (f.job_region_index >= job.lattice.regions.size()) continue;
    const JobLatticeRegion& r = job.lattice.regions[f.job_region_index];
    if (!(min_extrudable_width_mm > 0.0))
      throw JobError(
          "lattice region " + std::to_string(r.region_id) +
          " states relative_density " + json_num(f.stated_relative_density) +
          ", but \"min_extrudable_width_mm\" is unset (0). That value is the "
          "print profile's extrusion width and there is no safe default for it: "
          "whether a stated density prints at all is a question about the "
          "nozzle. Declare it and re-run.");
    // ★ THE DECISION IS lattice_stated_density_unprintable's, not this
    // function's (bar R1'). This wrapper only builds the message. The predicate
    // is asserted in test_lattice_refusal.cpp, including the unreachability that
    // makes a no-override job inert here for EVERY region shape.
    if (!lattice_stated_density_unprintable(f.stated_relative_density, f.cell_mm,
                                            min_extrudable_width_mm))
      continue;
    const double strut =
        octet_strut_diameter_mm(f.stated_relative_density, f.cell_mm);
    throw JobError(
        "lattice region " + std::to_string(r.region_id) +
        ": a stated relative_density of " +
        json_num(f.stated_relative_density) + " puts this region's strut at " +
        json_num(strut) + " mm, under your profile's " +
        json_num(min_extrudable_width_mm) +
        " mm extrusion width, so it cannot be printed. At this region's " +
        json_num(f.cell_mm) + " mm cell the lightest printable density is " +
        json_num(f.derived_relative_density) +
        " — state that or heavier (up to " + json_num(lattice_rho_max(topo)) +
        "), or declare a deeper region so the derivation picks a larger cell. "
        "The density is NOT clamped: a part you did not ask for is worse than a "
        "refusal.");
  }
}

void refuse_infeasible_region_lattice(const JobDescription& job,
                                      const std::vector<FitRegionCell>& cells,
                                      double min_extrudable_width_mm) {
  for (const FitRegionCell& f : cells) {
    if (f.feasible) continue;
    if (f.job_region_index >= job.lattice.regions.size()) continue;
    const JobLatticeRegion& r = job.lattice.regions[f.job_region_index];
    if (r.kind != "region") continue;   // the analytic kinds keep their verdict
    throw JobError(
        "lattice region " + std::to_string(r.region_id) +
        " cannot carry a lattice at ANY legal cell: its body measures " +
        json_num(f.extent_mm) + " mm across, and this topology needs at least " +
        json_num(f.min_width_buildable_mm) +
        " mm to build a strut at the declared " +
        json_num(min_extrudable_width_mm) +
        " mm extrusion width (and " + json_num(f.min_width_certifiable_mm) +
        " mm to certify one). Declare a deeper region, run at a finer "
        "resolution, or split the parent into fewer pieces.");
  }
}

// ★ THE PER-VOXEL STATED DENSITY (task 2026-08-16-per-sector-density-override).
// Built exactly like `fit_cell_field` and by the SAME membership test, so a voxel
// gets the cell and the density of the SAME region and the two cannot disagree
// about which region owns it. 0.0 where no region states one — the law's sentinel
// for "derive", so a job with no override hands in an all-zero field that is
// behaviourally identical to handing in nothing.
std::vector<double> region_density_field(
    const VoxelGrid& grid, const std::vector<ClearanceGeometry>& includes,
    const std::vector<FitRegionCell>& cells) {
  std::vector<double> out(grid.voxel_count(), 0.0);
  if (includes.size() != cells.size()) return out;  // caller asserts; never guess
  bool any = false;
  for (const FitRegionCell& c : cells)
    if (c.stated_relative_density > 0.0) any = true;
  if (!any) return out;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        for (std::size_t ri = 0; ri < includes.size(); ++ri)
          if (point_in_clearance_region(includes[ri], c, 0.0)) {
            out[grid.index(i, j, k)] = cells[ri].stated_relative_density;
            break;
          }
      }
  return out;
}

// The per-voxel desired cell the grading law's Fit mode consumes: the derived cell of
// the include region owning each voxel, 0 elsewhere. Built from the SAME membership
// test the certification mask uses (`point_in_clearance_region`, first match wins), so
// the cell a voxel is graded at is the cell derived for the region that voxel is in.
std::vector<double> fit_cell_field(const VoxelGrid& grid,
                                   const std::vector<ClearanceGeometry>& includes,
                                   const std::vector<FitRegionCell>& cells) {
  std::vector<double> out(grid.voxel_count(), 0.0);
  if (includes.size() != cells.size()) return out;  // caller asserts; never guess
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        for (std::size_t ri = 0; ri < includes.size(); ++ri)
          if (point_in_clearance_region(includes[ri], c, 0.0)) {
            out[grid.index(i, j, k)] = cells[ri].cell_mm;  // 0 when infeasible
            break;
          }
      }
  return out;
}

// ★ WHERE THE SKIPPED VOXELS WERE (review Q2). Walks the printed set once and splits
// it by declared include region, so the receipt can say whether a voxel that got no
// derived cell was INSIDE a region the user declared (a defect in this law) or OUTSIDE
// every one of them (the candidate set reaching past the declaration — a different
// defect, and one this project has paid for twice).
//
// Uses the SAME membership test and the same first-match precedence as
// `fit_cell_field`, so the two cannot disagree about which region owns a voxel.
void fill_fit_region_voxels(RunInfo& gi, const VoxelGrid& grid,
                            const std::vector<double>& density, double iso,
                            const std::vector<ClearanceGeometry>& includes,
                            const GradedField& gf) {
  if (gi.grading_fit_regions.size() != includes.size()) return;
  long long outside = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!(density[e] > iso)) continue;      // not printed: not a candidate at all
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        std::size_t owner = includes.size();
        for (std::size_t ri = 0; ri < includes.size(); ++ri)
          if (point_in_clearance_region(includes[ri], c, 0.0)) { owner = ri; break; }
        if (owner == includes.size()) { ++outside; continue; }
        RunInfo::GradingFitRegion& R = gi.grading_fit_regions[owner];
        ++R.candidate_voxels;
        if (e < gf.posture.mask.size() && gf.posture.mask[e]) ++R.latticed_voxels;
      }
  gi.grading_fit_printed_outside_regions = outside;
}

// FIT's run_info block. Recomputed from the JOB rather than plumbed through the
// variant outcome: the derivation is pure arithmetic on core's own constants and the
// declared geometry, so recomputing it here cannot disagree with what the run used —
// while a second copy carried down the call chain could go stale.
// ★ `roles` IS NOT OPTIONAL FOR CORRECTNESS HERE, only for the analytic path
// (task 2026-08-15-lattice-regions, bar R3). A region-backed include is dropped
// from `fit_region_cells` without it, which makes this vector shorter than
// `includes` — and `fill_fit_region_voxels` then returns EARLY on the size
// mismatch, so the per-region breakdown silently vanishes for exactly the
// regions this task added. That is the "green run that measures nothing" shape,
// so every call site passes the roles it resolved.
void fill_grading_fit(RunInfo& gi, const GradedField& gf,
                      const JobDescription& job,
                      const LatticeRoleRegions* roles = nullptr) {
  gi.grading_min_printable_cell_mm = gf.min_printable_cell_mm;
  gi.grading_density_raised_for_print_voxels =
      static_cast<long long>(gf.density_raised_for_print_voxels);
  if (gf.cell_mode != CellSizeMode::Fit) return;
  gi.grading_fit_out_of_regime_voxels =
      static_cast<long long>(gf.fit_out_of_regime_voxels);
  gi.grading_fit_no_derivation_voxels =
      static_cast<long long>(gf.fit_no_derivation_voxels);
  gi.grading_fit_distinct_cells = static_cast<long long>(gf.fit_distinct_cells);
  gi.grading_fit_regions.clear();
  for (const FitRegionCell& f :
       fit_region_cells(job, gf.posture.topology,
                        job.grading.min_extrudable_width_mm, roles)) {
    RunInfo::GradingFitRegion R;
    R.region_index = static_cast<int>(f.job_region_index);
    R.extent_mm = f.extent_mm;
    R.feasible = f.feasible;
    R.cell_mm = f.cell_mm;
    R.relative_density = f.relative_density;
    R.stated_relative_density = f.stated_relative_density;
    R.derived_relative_density = f.derived_relative_density;
    R.strut_mm = f.strut_mm;
    R.cells_per_member = f.cells_per_member;
    R.out_of_regime = f.out_of_regime;
    gi.grading_fit_regions.push_back(R);
  }
}

// The FINEST lattice cell (mm) the grading law could grant any member on this job —
// the most favourable cell a member could be measured against, and therefore the
// honest denominator for any cells-per-member statement about the run.
// AUTO takes the printability floor itself; FIXED takes its target raised to the floor
// that actually binds (S2); SWEPT's finest level comes from the PLAN'S OWN LADDER (S1);
// FIT's is the finest cell any declared region derived. Mirrors grading.cpp's and
// cell_plan.cpp's own resolution — it does not invent a second rule.
//
// `swept_light_floor` selects the PRE-S1 swept answer. It exists for exactly one
// caller and that caller documents why (see `multiscale_floor_cell_mm` below); no new
// code should pass true.
double planned_cell_mm(const JobDescription& job, bool swept_light_floor) {
  const double floor_mm = lattice_cell_printability_floor_mm(
      LatticeTopology::Octet, job.grading.min_extrudable_width_mm);
  // S2: the cell below which NO density in the band prints — the bound Fixed applies.
  const double abs_floor_mm =
      job.grading.min_extrudable_width_mm /
      octet_strut_diameter_mm(lattice_rho_max(LatticeTopology::Octet), 1.0);
  CellSizeMode mode = CellSizeMode::Fixed;
  if (!resolve_cell_mode(job.grading.cell_mode, mode))
    return floor_mm;  // unknown mode is refused downstream; report the floor
  switch (mode) {
    // AUTO KEEPS THE LIGHT FLOOR, DELIBERATELY. "auto" means "the lightest lattice
    // core can print", and `lattice_cell_printability_floor_mm` — evaluated at
    // rho_MIN — is exactly the cell that claim implies. It is the mode's ANSWER, not
    // a bound on someone else's number, so S1 does not touch it and past auto runs
    // stay reproducible.
    case CellSizeMode::Auto:  return floor_mm;
    // ★ S1 (task 2026-08-07-cell-mode-fit-and-swept-floor). SWEPT'S DECLARED MINIMUM
    // IS THE USER STATING AN INTENT, and it must be bounded by what can PRINT — not
    // by what a LIGHT lattice needs. This used to be `max(cell_min_mm, floor_mm)`,
    // which silently reported a declared 1.173 mm minimum as 4.9314 mm at a 0.45 mm
    // strut line width; `plan_cell_sizes` meanwhile takes `cell_min_mm` VERBATIM as
    // its base cell (cell_plan.cpp) and climbs the dyadic ladder per base cell. The
    // forecast and the planner therefore DISAGREED — measured, in
    // evidence/2026-08-07-cell-mode-fit-and-swept-floor/s1_disagreement.txt. The
    // ladder is now read from `cell_plan_finest_printable_cell_mm`, which IS the
    // planner's own arithmetic.
    case CellSizeMode::Swept:
      return swept_light_floor
                 ? std::max(job.grading.cell_min_mm, floor_mm)
                 : cell_plan_finest_printable_cell_mm(
                       LatticeTopology::Octet, job.grading.cell_min_mm,
                       job.grading.cell_max_mm,
                       job.grading.min_extrudable_width_mm);
    case CellSizeMode::Fit: {
      double finest = 0.0;
      for (const FitRegionCell& f :
           fit_region_cells(job, LatticeTopology::Octet,
                            job.grading.min_extrudable_width_mm))
        if (f.feasible && (finest == 0.0 || f.cell_mm < finest)) finest = f.cell_mm;
      return finest > 0.0 ? finest : abs_floor_mm;
    }
    case CellSizeMode::Fixed: break;
  }
  return std::max(job.grading.cell_mm, abs_floor_mm);
}

// ★★ S1's SECOND CONSUMER, DELIBERATELY LEFT ON THE OLD RULE — BUILT + DISARMED.
//
// This is the ONE place the swept resolution reaches GEOMETRY rather than text: its
// return value becomes `options.min_feature_mm` (the density filter's length scale) on
// a `lattice.multiscale` job, so changing it changes the design.
//
// MEASURED, not assumed. evidence/2026-08-07-cell-mode-fit-and-swept-floor/
// r1_byte_identity.txt case G — a swept multiscale job declaring a 0.6 mm minimum at a
// 0.20 mm strut line width:
//     old rule : floor 5.0 cells x 2.1917 mm = 10.959 mm member => min_feature 5.479 mm
//     new rule : floor 5.0 cells x 0.6000 mm =  3.000 mm member => min_feature 2.500 mm
// and EVERY artifact moved — design.bin, both meshes, report.json, fields.bin. That is
// a verdict moving on a job that runs today, which this task's R3 makes a
// BLOCKED-STOP. So the correction stops at the refusal path (which touches no
// geometry, proven by the same script's cases A-F) and this caller keeps the old
// answer until the maintainer decides.
//
// IT IS THE SAME DEFECT. The old answer here is too COARSE in the same way and for the
// same reason: it forces a length scale derived from a cell the plan would never use,
// which forbids members the lattice could actually hold. Flipping the argument below
// to false is the whole change; what it needs is a gate table on multiscale swept jobs,
// not more code.
double multiscale_floor_cell_mm(const JobDescription& job) {
  return planned_cell_mm(job, /*swept_light_floor=*/true);
}

// Copy the SUB-FLOOR RETENTION record into run_info — ONE filler for both call sites,
// for the same reason the cell plan has one (handoff 2026-08-04-subfloor-lattice-
// unloaded-regions). Every field stays at its zero default when a job did not opt in,
// and the serializer emits no block at all then, so a run that did not arm retention
// is byte-identical (bar S1).
void fill_grading_subfloor(RunInfo& gi, const GradedField& gf) {
  gi.grading_subfloor_armed = gf.subfloor_retention_armed;
  gi.grading_subfloor_stress_fraction_ceiling = gf.subfloor_stress_fraction_max;
  gi.grading_subfloor_region_stress_fraction = gf.region_stress_fraction;
  gi.grading_subfloor_region_qualified = gf.region_qualified_unloaded;
  gi.grading_subfloor_candidate_voxels =
      static_cast<long long>(gf.subfloor_candidate_voxels);
  gi.grading_subfloor_retained_voxels =
      static_cast<long long>(gf.subfloor_retained_voxels);
  gi.grading_subfloor_recovered_voxels =
      static_cast<long long>(gf.subfloor_recovered_in_regime_voxels);
  gi.grading_subfloor_min_cells_per_member = gf.subfloor_min_cells_per_member;
  gi.grading_subfloor_max_cells_per_member = gf.subfloor_max_cells_per_member;
}

// ★ THE SHELL THE LATTICED FILE CARRIES (task 2026-08-08-strut-clip-matches-
// shell). `export_latticed_variant` pushes `variant.v3.mesh` as the solid shell,
// and `variant.v3.mesh` is
// `keep_largest_component(marching_cubes(grid, density, printed_iso))` —
// voxelize.cpp:735 + :813, from `check_v3(grid, density, kIso)` at
// analyze.cpp:389.
//
// ★★ THAT `kIso` IS THE RUN'S PRINTED ISO, NOT THE CONSTANT 0.5, and an earlier
// version of this comment said the opposite — confidently, and wrongly, in a way
// that got a follow-up task filed against a defect that does not exist (task
// 2026-08-09-shell-at-runs-printed-iso). analyze.cpp declares TWO things called
// `kIso`: a file-scope `constexpr double kIso = 0.5` at :25, and
// `const double kIso = printed_iso;` at :143 INSIDE analyze_fixed_design, whose
// body runs to :564. Line 389 is inside that body, so it binds to the SHADOWING
// LOCAL. On a multiscale run `minimize_plastic.cpp:573` resolves that argument to
// `multiscale_printed_iso()` (0.0252 for octet), and the exported shell is cut
// there — measured, and asserted by the ctest `shell_iso_provenance`.
//
// ISO IS A PARAMETER HERE FOR THAT REASON. It was a file-scope constant, which
// is what let the wrong belief be written down as fact and would silently cut the
// wrong surface the first time a caller with a non-0.5 iso appeared. A caller
// must now say which iso it means, and the only caller says
// `run_printed_iso`-equivalent explicitly.
//
// Spelled ONCE so the surface the struts are clipped against, the surface the
// invariant is measured against and the surface the file carries are the same
// object by construction rather than by three sites agreeing. The forecast path
// has no `v3.mesh` in hand and calls this to reconstruct it from the stored
// design, which is why it takes the field rather than the variant.
TriangleMesh exported_shell_for(const VoxelGrid& sg,
                                const std::vector<double>& dens,
                                double printed_iso) {
  if (!(printed_iso > 0.0 && printed_iso < 1.0))
    throw JobError("exported_shell_for: printed_iso must be in (0, 1)");
  return keep_largest_component(marching_cubes(sg, dens, printed_iso));
}

LatticeBoundary lattice_boundary_for(const VoxelGrid& sg,
                                     const std::vector<double>& dens,
                                     double cell_mm,
                                     const std::vector<ClearanceGeometry>& kos,
                                     const LatticeRoleRegions& roles,
                                     double printed_iso = 0.5,
                                     // THE EXPORTED SHELL. Non-null => the base
                                     // region is its interior (set_shell_base);
                                     // null keeps the voxel-cube union, which is
                                     // what every test that builds a boundary
                                     // without a mesh still gets.
                                     const TriangleMesh* shell = nullptr) {
  LatticeBoundary B;
  // Window: clipping needs exact distances only out to one cell of slack past
  // the largest erosion; two cells is comfortably conservative.
  B.set_voxel_base(&sg, &dens, printed_iso, 2.0 * cell_mm);
  // ★ ONE SURFACE, NOT TWO. The voxel-cube union is NOT the surface the export
  // writes: a marching-cubes vertex sits between voxel CENTRES, so the two
  // coincide on a flat face and the isosurface CHAMFERS the cube union at a
  // convex edge — measured at h/sqrt(3) = 0.984 mm on his 1.705 mm voxel
  // (evidence/2026-08-08-strut-clip-matches-shell/s1b_surface_gap.csv). Struts
  // clipped to the cube union therefore ended outside the shell at edges and
  // only at edges, which is exactly what the maintainer photographed. When the
  // shell is in hand it supersedes the cube union (set_shell_base).
  if (shell != nullptr && !shell->triangles.empty()) B.set_shell_base(shell);
  for (const ClearanceGeometry& g : kos)
    B.add_keep_out(g, /*collar=*/g.kind == ClearanceKind::Bolt);
  // Lattice roles (stage 1): activation + certification-mask terms of the SAME
  // shared predicate — never a second boundary object (H1b). Empty on a job
  // with no lattice.regions => byte-identical behaviour.
  for (const ClearanceGeometry& g : roles.includes) B.add_include_region(g);
  for (const ClearanceGeometry& g : roles.excludes) B.add_exclude_region(g);
  return B;
}

// The lattice keep-outs: the job's clearance regions resolved through the SAME
// functions the optimizer's FrozenVoid rasterization uses (handoff 100 /
// group-editing) — resolve_clearance_from_face for B-rep faces,
// resolve_clearance_manual for hand-placed primitives.
std::vector<ClearanceGeometry> lattice_keep_outs_from_job(
    const JobDescription& job, const StepModel& model) {
  std::vector<ClearanceGeometry> out;
  if (!job.loads.present) return out;
  for (const JobClearance& jc : job.loads.clearances) {
    const bool bolt = jc.kind == "bolt";
    double bore_r = 0.0;
    if (bolt) {
      if (jc.manual)
        bore_r = jc.radius_mm;
      else if (jc.face_id >= 0 && jc.face_id < model.face_count)
        bore_r =
            model.faces[static_cast<std::size_t>(jc.face_id)].cylinder_radius_mm;
    }
    ClearanceParams params = bolt ? default_bolt_clearance(bore_r)
                                  : default_face_clearance();
    if (jc.concentric_margin_mm > 0.0)
      params.concentric_margin_mm = jc.concentric_margin_mm;
    if (jc.axial_clearance_mm > 0.0)
      params.axial_clearance_mm = jc.axial_clearance_mm;
    if (jc.slab_depth_mm > 0.0) params.slab_depth_mm = jc.slab_depth_mm;
    ClearanceGeometry g;
    if (jc.manual) {
      ManualClearanceGeometry mg;
      mg.kind = bolt ? ClearanceKind::Bolt : ClearanceKind::Face;
      mg.axis_point = jc.axis_point;
      mg.axis_dir = jc.axis_dir;
      mg.radius_mm = jc.radius_mm;
      mg.half_length_mm = jc.half_length_mm;
      mg.origin = jc.origin;
      mg.normal = jc.normal;
      mg.half_u_mm = jc.half_u_mm;
      mg.half_w_mm = jc.half_w_mm;
      g = resolve_clearance_manual(mg, params);
    } else {
      if (jc.face_id < 0 || jc.face_id >= model.face_count) continue;
      g = resolve_clearance_from_face(model, jc.face_id, params);
    }
    if (g.valid) out.push_back(g);
  }
  return out;
}

// The lattice cell grid over the solved grid; activation (which cells emit) is
// decided by `boundary` (overlap, not centre — bar (a)).
LatticeRegion lattice_region_for(const VoxelGrid& sg, double cell_mm,
                                 const LatticeBoundary* boundary) {
  LatticeRegion R;
  R.origin = sg.origin;
  R.cell_mm = cell_mm;
  R.nx = std::max(1, static_cast<int>(std::ceil(sg.nx * sg.spacing / cell_mm)));
  R.ny = std::max(1, static_cast<int>(std::ceil(sg.ny * sg.spacing / cell_mm)));
  R.nz = std::max(1, static_cast<int>(std::ceil(sg.nz * sg.spacing / cell_mm)));
  R.boundary = boundary;
  return R;
}

// The skin spec a job's lattice block implies. The clamp is computed by CORE's
// law (lattice_skin_min_radius_mm) from the STATED extrudable width; a job that
// states none makes no printability claim and the skin tracks the interior.
LatticeSkinSpec lattice_skin_for(const JobLattice& lat) {
  LatticeSkinSpec S;
  S.mode = lat.skin == "none"  ? LatticeSkinMode::None
           : lat.skin == "rim" ? LatticeSkinMode::Rim
                               : LatticeSkinMode::Diagrid;
  S.min_radius_mm = lat.min_extrudable_width_mm > 0.0
                        ? lattice_skin_min_radius_mm(lat.min_extrudable_width_mm)
                        : 0.0;
  // A non-"shell" outer finish arms the FREEFORM skin (task 2026-07-30-
  // lattice-skin-freeform): the diagrid extends onto the voxel-derived outer
  // surface — as the outer finish itself ("skin") or laid on the shell
  // ("shell+skin"). Default "shell" leaves it off: byte-identical.
  S.freeform = lat.outer_finish != "shell";
  return S;
}

// Export one accepted variant's latticed companion. `cell_mm` and `radius` are
// caller-supplied (uniform: the job's cell/strut radius; graded: the law's cell
// + a per-position radius field over the graded densities). `cert_mask` is THE
// certification mask the posture will certify — passed in so the file and the
// certified object derive from the SAME flags (H1b). `cell_latticed`, when
// non-null, restricts cell activation to cells holding at least one masked voxel
// (derived from the same mask — the graded silhouette, and, under a design box,
// the uniform one; see the caller). NULL keeps the legacy uniform behaviour:
// every cell the boundary cannot prove empty.
// `emit_solid_companion` arms the solid-companion body (roles / grading only —
// see LatticeExportOutcome; a legacy job passes false and writes identical
// bytes).
LatticeExportOutcome export_latticed_variant(
    const MinimizePlasticVariant& variant, const std::string& out_dir,
    const JobOutput& out, const JobLattice& lat, const VoxelGrid& sg,
    const LatticeBoundary& boundary, double cell_mm,
    const LatticeRadiusField& radius, const std::vector<char>& cert_mask,
    const std::function<bool(int, int, int)>& cell_latticed,
    bool emit_solid_companion,
    // SWEPT cell size (handoff 2026-08-01-lattice-cell-size-sweep). Null / fewer
    // than two levels => the single-cell path below, byte-identical to a pre-sweep
    // run (bar R1). Non-null => one ordinary generator pass per dyadic level over
    // the level-0 grid at `base_cell_mm`; the levels meet at SHARED NODES because
    // the ladder is dyadic and aligned (cell_plan.hpp states why), so no bridging
    // geometry exists to get wrong.
    const std::vector<LatticeLevelSpec>* levels = nullptr,
    double base_cell_mm = 0.0, double printed_iso = 0.5,
    // ★ ORGANIC (task 2026-08-21-organic-lattice). Null on every other run, and
    // then not one line below changes. Non-null => the traced curves and
    // connectors REPLACE the octet passes entirely: there is no cell grid to
    // sweep, so `levels`, `radius` and `R.latticed` play no part. Everything
    // else — the shell, the solid companion, the boundary clip, the baked
    // frame, the no-protrusion measurement and the writers — is the same code
    // on the same terms, which is what §4(a)'s one-density contract buys.
    const OrganicLattice* organic = nullptr,
    // ★ STEPPED (§4). Null on every other run. Non-null => one ORDINARY generator
    // pass per declared region at that region's OWN cell, no ladder and no stitching
    // (lattice_gen.hpp's generate_lattice_stepped states what that gives up).
    const std::vector<LatticeSteppedPass>* stepped = nullptr) {
  // ── M4: A SKIN MODE THAT PRODUCES NO GEOMETRY MUST SAY SO, NOT RETURN ZERO.
  //
  // ★ THE PREDICATE IS THE MEASURED COUNT, NOT A PREDICTION — and the first version
  // of this guard got that wrong, in a way its own blast-radius test passed
  // vacuously. It tested `boundary.faces().empty()`, reasoning that no faces means
  // no face pairs means no rim. True but TOO NARROW: a job with a BOLT clearance has
  // faces() = {one Bore} — non-empty, so the guard stayed silent — and still emits
  // zero rim, because the dispatch at lattice_gen.cpp:944-961 pairs faces and only
  // Plane-Plane (emit_rim_line) or Plane-Bore (emit_rim_torus) produce anything;
  // "bore-bore pairs meet nowhere a rim can ride". Measured: m4_blast_radius.txt
  // case 2, base and branch both rim_triangles=0, and the guard did not fire.
  //
  // Checking the count the generator ACTUALLY produced makes the blast radius exact
  // by construction rather than by argument: it fires on precisely the set of runs
  // that emitted nothing, which cannot include any run that emitted something.
  //
  // ROOT CAUSE OF THE ZERO ITSELF (handoff §7, evidence b3_rim_root_cause.md), and
  // it is broader than that section first said. Rim geometry needs at least one
  // PLANE face. Planes enter faces_ only via LatticeBoundary::add_half_space
  // (lattice_boundary.cpp:122); add_keep_out (:160) contributes a Bore, and only for
  // ClearanceKind::Bolt. lattice_boundary_for (this file, ~:568-586) builds every
  // optimize/lattice run's boundary from set_voxel_base + keep-outs + roles and
  // NEVER calls add_half_space or add_box, and roles contribute no analytic faces
  // (lattice_boundary.hpp:242-245). So on THIS path there is never a Plane, and rim
  // and skin geometry are structurally unreachable on EVERY such run — not merely
  // on voxel-derived parts without bolt clearances.
  //
  // The maintainer's overnight run asked for skin "rim" and got rim_triangles 0,
  // skin_triangles 0, rim_volume_mm3 0, anchor_nodes 0 beside a non-zero interior
  // volume, silently. This branch's own pre-flight refusal used to offer a skin as
  // the alternative when a lattice would not fit, so it was recommending a door that
  // is painted on. That offer is gone (M2) and this is the backstop.
  //
  // ROOT CAUSE (handoff §7, evidence b3_rim_root_cause.md). The rim and the skin
  // are emitted ONLY where ANALYTIC boundary faces meet: emit_rim_edge
  // (lattice_gen.cpp:598-666) indexes `B->faces()`, and emit_rim_torus dresses a
  // PLANE against a BORE. `faces_` is filled in exactly two places —
  // lattice_boundary.cpp:122 (add_half_space) and :160 (add_keep_out, and ONLY for
  // ClearanceKind::Bolt; a slab keep-out records -1, "no wall to dress"). But
  // lattice_boundary_for (this file, ~:568-586) builds the boundary from
  // set_voxel_base + keep-outs + roles and NEVER calls add_half_space or add_box,
  // and roles are documented to contribute no analytic faces
  // (lattice_boundary.hpp:242-245).
  //
  // So on a voxel-derived design with no BOLT clearance, `faces()` is empty and the
  // rim, the skin and the anchor nodes are all structurally unreachable. The
  // maintainer's overnight run asked for skin "rim" and got rim_triangles 0,
  // skin_triangles 0, rim_volume_mm3 0, anchor_nodes 0 — silently, beside a
  // non-zero interior volume. Worse, this branch's own pre-flight refusal offers a
  // skin as the alternative when a lattice will not fit, so it was recommending a
  // door that is painted on.
  //
  // BLAST RADIUS, measured rather than argued (evidence m4_blast_radius.txt): this
  // fires if and only if `faces()` is empty, and a boundary with no faces cannot
  // execute a single line of rim or skin emission — both generators iterate face
  // PAIRS. So the set of runs it refuses is exactly the set that produces zero rim
  // and zero skin geometry today. No run that currently emits a rim can reach it.
  //
  // It is a REFUSAL and not a warning because the shell finish is always available
  // and silently shipping an undressed part is how this cost a night in the first
  // place. `skin: "none"` is the explicit way to ask for no dressing.

  // Occupancy + boundary: the shared predicate (`boundary`, built by the caller
  // from THIS variant's density + the declared clearance keep-outs + the job's
  // lattice role regions). Cells activate by OVERLAP with it; strut solids are
  // clipped against it; the skin and collar ride its analytic faces. It is the
  // SAME object the certification posture is built from, so the sliced file and
  // the certified object agree by construction (bar B7 / H1b).
  const std::vector<double>& dens = variant.optimization.physical_density;
  LatticeRegion R = lattice_region_for(sg, cell_mm, &boundary);
  R.latticed = cell_latticed;  // null => every cell (the legacy uniform path)
  const LatticeSkinSpec skin = lattice_skin_for(lat);

  const TriangleMesh& shell = variant.v3.mesh;
  auto push_shell = [&shell](TriangleSink& sink) {
    for (const auto& t : shell.triangles)
      sink.add_triangle(shell.vertices[static_cast<std::size_t>(t[0])],
                        shell.vertices[static_cast<std::size_t>(t[1])],
                        shell.vertices[static_cast<std::size_t>(t[2])]);
  };

  LatticeExportOutcome oc;

  // The SOLID COMPANION (stages 1+4): every printed voxel the certification
  // mask leaves solid — outside a keep-out (clearances keep today's collar
  // dressing and emit nothing, the H1a precedence) — becomes a closed
  // marching-cubes body pushed into the same soup. All components are kept
  // (several disjoint regions stay several bodies); no largest-component
  // cleanup, deterministic.
  TriangleMesh comp_mesh;
  if (emit_solid_companion) {
    oc.solid_companion = true;
    std::vector<double> comp(sg.voxel_count(), 0.0);
    for (int k = 0; k < sg.nz; ++k)
      for (int j = 0; j < sg.ny; ++j)
        for (int i = 0; i < sg.nx; ++i) {
          const std::size_t e = sg.index(i, j, k);
          if (!(dens[e] >= printed_iso) || cert_mask[e]) continue;
          const Vec3 c{sg.origin.x + (i + 0.5) * sg.spacing,
                       sg.origin.y + (j + 0.5) * sg.spacing,
                       sg.origin.z + (k + 0.5) * sg.spacing};
          if (boundary.in_keep_out(c, 0.0)) continue;  // clearance beats roles
          comp[e] = 1.0;
          ++oc.solid_region_voxels;
        }
    oc.solid_region_volume_mm3 =
        static_cast<double>(oc.solid_region_voxels) * sg.spacing * sg.spacing *
        sg.spacing;
    if (oc.solid_region_voxels > 0) comp_mesh = marching_cubes(sg, comp, 0.5);
    oc.solid_region_triangles =
        static_cast<std::uint64_t>(comp_mesh.triangles.size());
  }
  auto push_companion = [&comp_mesh](TriangleSink& sink) {
    for (const auto& t : comp_mesh.triangles)
      sink.add_triangle(comp_mesh.vertices[static_cast<std::size_t>(t[0])],
                        comp_mesh.vertices[static_cast<std::size_t>(t[1])],
                        comp_mesh.vertices[static_cast<std::size_t>(t[2])]);
  };

  const std::string base =
      join_path(out_dir, lattice_base_name(out.mesh_prefix,
                                           variant.requested_volume_fraction));
  // Outer finish (task 2026-07-30-lattice-skin-freeform): "skin" REPLACES the
  // solid shell with the freeform diagrid (open, see-through); "shell" and
  // "shell+skin" keep the shell exactly as before.
  const bool with_shell = lat.outer_finish != "skin";
  // ONE emission routine for both writers, so STL and 3MF can never diverge on
  // which path they took.
  const bool swept = levels && levels->size() > 1 && base_cell_mm > 0.0;
  LatticeRegion Rbase = R;
  if (swept) {
    // The multilevel pass wants the LEVEL-0 (finest) grid; it derives each coarser
    // level as an aligned coarsening (nx >> L), which is what makes coarse nodes
    // land on base-grid node positions.
    Rbase = lattice_region_for(sg, base_cell_mm, &boundary);
    Rbase.latticed = nullptr;  // each level carries its own predicate
  }
  // ── ★ THE NO-PROTRUSION MEASUREMENT (task 2026-08-08-strut-clip-matches-
  // shell, bar R3). One `MeshDistance` over the shell in this very file, plus a
  // per-voxel LOWER BOUND on the shell distance so the overwhelming majority of
  // vertices — the deep interior — cost an array lookup instead of a query.
  //
  // THE BOUND IS SOUND, not a heuristic: the exact signed distance is
  // 1-Lipschitz, so for any point p inside voxel (i,j,k) whose centre c has
  // shell distance sd(c), sd(p) >= sd(c) - |p - c| >= sd(c) - (sqrt(3)/2)*h.
  // A vertex whose owning voxel clears that bound is PROVEN inside and is
  // skipped; every other vertex is measured exactly. Nothing is sampled and
  // nothing is assumed.
  //
  // `MeasuringSink` wraps the writer, so the measurement rides the stream and
  // peak memory stays flat in output size. It wraps ONLY the lattice emission —
  // the shell's own triangles lie on the shell (distance 0 by construction) and
  // the solid companion is a different body with its own accounting, so folding
  // either in would report a number about something else.
  //
  // A "skin" outer finish drops the shell from the file entirely, and there is
  // then no shell for a strut to protrude through: the measurement is SKIPPED
  // and `protrusion_measured` stays false, rather than reporting a vacuous zero
  // against a surface the file does not carry.
  const MeshDistance shell_dist(shell);
  const bool measure_protrusion = with_shell && !shell_dist.empty();
  std::vector<float> sd_floor;  // per voxel: a lower bound on shell distance
  const double voxel_reach = 0.5 * std::sqrt(3.0) * sg.spacing;
  if (measure_protrusion) {
    sd_floor.assign(sg.voxel_count(), 0.0f);
    for (int k = 0; k < sg.nz; ++k)
      for (int j = 0; j < sg.ny; ++j)
        for (int i = 0; i < sg.nx; ++i) {
          const Vec3 c{sg.origin.x + (i + 0.5) * sg.spacing,
                       sg.origin.y + (j + 0.5) * sg.spacing,
                       sg.origin.z + (k + 0.5) * sg.spacing};
          // The bound is stored NARROWED to float (2 MB rather than 16 at his
          // grid), so it carries a guard band an order of magnitude wider than
          // float's own error at these magnitudes. Narrowing must never make
          // the bound optimistic: a skip is a claim that a vertex is provably
          // inside, and a claim that is 1e-5 mm too generous is still a claim
          // the measurement did not earn.
          constexpr double kFloatGuardMm = 1e-3;
          sd_floor[sg.index(i, j, k)] = static_cast<float>(
              shell_dist.signed_distance(c) - voxel_reach - kFloatGuardMm);
        }
  }
  struct MeasuringSink : TriangleSink {
    TriangleSink* inner = nullptr;
    const MeshDistance* dist = nullptr;
    const VoxelGrid* grid = nullptr;
    const std::vector<float>* floor = nullptr;
    double max_out = 0.0;
    long long n_out = 0;
    long long n_seen = 0;
    Vec3 worst{};
    long long worst_vertex = -1;
    void one(const Vec3& v) {
      ++n_seen;
      const VoxelGrid& g = *grid;
      const int i = static_cast<int>(std::floor((v.x - g.origin.x) / g.spacing));
      const int j = static_cast<int>(std::floor((v.y - g.origin.y) / g.spacing));
      const int k = static_cast<int>(std::floor((v.z - g.origin.z) / g.spacing));
      if (i >= 0 && j >= 0 && k >= 0 && i < g.nx && j < g.ny && k < g.nz &&
          (*floor)[g.index(i, j, k)] > 0.0f)
        return;  // PROVEN inside by the Lipschitz bound — no query needed
      const double out = -dist->signed_distance(v);
      if (out > 0.0) {
        ++n_out;
        if (out > max_out) {
          max_out = out;
          worst = v;
          worst_vertex = n_seen - 1;
        }
      }
    }
    void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
      one(a);
      one(b);
      one(c);
      inner->add_triangle(a, b, c);
    }
  };
  // ★ ORGANIC's stats, mapped onto the SAME LatticeGenStats every consumer already
  // reads (§4a: the selector is cheap because nothing downstream branches). The
  // fields that have no organic meaning stay 0 and are NOT invented: an organic run
  // has no cells, so `latticed_cells` is 0 and the receipt says which algorithm ran.
  auto organic_stats = [&](const OrganicGenStats& g) {
    LatticeGenStats st;
    st.triangles = g.triangles;
    st.strut_triangles = g.triangles - 20 * g.nodes;
    st.node_triangles = 20 * g.nodes;
    st.struts = g.struts;
    st.nodes = g.nodes;
    st.min_strut_diameter_mm = g.min_strut_diameter_mm;
    st.max_strut_diameter_mm = g.max_strut_diameter_mm;
    st.clipped_struts = g.clipped_segments;
    st.dropped_struts = g.dropped_segments;
    st.uncertified_spans_dropped = g.uncertified_spans_dropped;
    st.interior_volume_mm3 = g.volume_mm3;
    return st;
  };
  auto emit_lattice = [&](TriangleSink& w) {
    if (!measure_protrusion) {
      if (organic)
        return organic_stats(generate_organic_lattice(*organic, w, &boundary));
      if (stepped)
        return generate_lattice_stepped(LatticeGenTopology::Octet, *stepped, w,
                                        skin);
      return swept ? generate_lattice_multilevel(LatticeGenTopology::Octet,
                                                 Rbase, *levels, w, skin)
                   : generate_lattice(LatticeGenTopology::Octet, R, radius, w,
                                      skin);
    }
    MeasuringSink m;
    m.inner = &w;
    m.dist = &shell_dist;
    m.grid = &sg;
    m.floor = &sd_floor;
    // WHICH PASS emitted which vertices. `on_element` fires immediately AFTER
    // that element's triangles, so a running (vertex count, kind) ledger of one
    // entry per element lets the worst vertex be attributed exactly, without the
    // sink having to know anything about the generator. Observing never changes
    // the emitted bytes (lattice_gen.hpp), so this cannot move the file.
    std::vector<std::pair<long long, const char*>> pass_marks;
    LatticeGenObserver obs;
    obs.on_element = [&m, &pass_marks](LatticeGenElement k, const Vec3&,
                                       const Vec3&, double) {
      const char* name = "unknown";
      switch (k) {
        case LatticeGenElement::InteriorStrut: name = "interior strut"; break;
        case LatticeGenElement::Node: name = "node ball"; break;
        case LatticeGenElement::AnchorNode: name = "skin anchor ball"; break;
        case LatticeGenElement::SkinStrut: name = "skin strut"; break;
        case LatticeGenElement::RimStrut: name = "rim line"; break;
        case LatticeGenElement::RimTorusChord: name = "rim torus"; break;
      }
      pass_marks.emplace_back(m.n_seen, name);
    };
    // ORGANIC feeds the SAME observer, so a protruding vertex is attributed to
    // "interior strut" or "node ball" exactly as it is on the octet path. It was
    // "unattributed" once, and that cost a round of guessing about which primitive was
    // escaping the shell.
    const LatticeGenStats st =
        organic
            ? organic_stats(generate_organic_lattice(*organic, m, &boundary, 8, &obs))
            : (stepped ? generate_lattice_stepped(LatticeGenTopology::Octet,
                                                  *stepped, m, skin, &obs)
                       : (swept ? generate_lattice_multilevel(
                                      LatticeGenTopology::Octet, Rbase, *levels, m,
                                      skin, &obs)
                                : generate_lattice(LatticeGenTopology::Octet, R,
                                                   radius, m, skin, &obs)));
    const char* worst_pass = "unattributed";
    if (m.worst_vertex >= 0)
      for (const auto& pm : pass_marks)
        if (pm.first > m.worst_vertex) {
          worst_pass = pm.second;
          break;
        }
    // Both writers run the identical emission, so the second pass measures the
    // identical stream; take the max rather than overwrite, so a divergence
    // could only ever be reported UP.
    oc.protrusion_measured = true;
    oc.clipped_against_shell = boundary.has_shell_base();
    // The freeform skin is the ONE pass that is permitted outside the base
    // surface, and only by the budget it declares. Read from the spec that was
    // actually handed to the generator, so a run that did not arm it gets no
    // allowance at all.
    oc.protrusion_allowance_mm =
        LatticeBoundary::kClipTolMm +
        ((skin.freeform && skin.mode == LatticeSkinMode::Diagrid)
             ? kLatticeSkinSagBudgetMm
             : 0.0);
    if (m.max_out > oc.max_protrusion_mm) {
      oc.max_protrusion_mm = m.max_out;
      oc.worst_protrusion_at = m.worst;
      oc.worst_protrusion_pass = worst_pass;
    }
    oc.protruding_vertices = std::max(oc.protruding_vertices, m.n_out);
    oc.measured_vertices = std::max(oc.measured_vertices, m.n_seen);
    return st;
  };
  // ── THE BAKED BUILD FRAME, ON THE STREAM (handoff
  // 2026-08-01-bake-build-orientation). When this variant's orientation was
  // chosen for the user, every triangle — the solid shell, the kept-solid
  // companion bodies and the strut soup alike — is rotated on its way to the
  // writer by ONE sink wrapper. Three consequences worth stating:
  //   * the whole latticed file is rotated by the SAME rigid motion as the solid
  //     export, so the two describe the same placement;
  //   * peak memory stays FLAT in the output size — the wrapper is a per-triangle
  //     map, so a gigabyte of struts is still a disk cost, not a memory cost;
  //   * PR 250's zero-floating-ends and PR 253's containment are properties of
  //     the strut graph and of "inside the boundary", and a rigid motion moves
  //     the geometry and the boundary together, so both survive by construction
  //     (asserted, not assumed — test_bake_build_orientation bar V6).
  const std::optional<BuildFrameRotation> bake = variant_bake_rotation(variant);
  auto emit_all = [&](TriangleSink& out_sink) {
    if (with_shell) push_shell(out_sink);  // solid shell first, then the lattice
    push_companion(out_sink);              // then the kept-solid regions
    oc.stats = emit_lattice(out_sink);
  };
  auto write_with = [&](TriangleSink& writer) {
    if (bake) {
      RotatingTriangleSink rot(writer, *bake);
      emit_all(rot);
    } else {
      emit_all(writer);
    }
  };
  if (lat.emit_stl) {
    const std::string path = base + ".stl";
    StreamingStlWriter w(path);
    write_with(w);
    w.finish();
    oc.paths.push_back(path);
  }
  if (lat.emit_3mf) {
    const std::string path = base + ".3mf";
    StreamingThreeMfWriter w(path);
    write_with(w);
    w.finish();
    oc.paths.push_back(path);
  }

  // The latticed region's SOLID voxel count (the region actually filled): every
  // solid voxel whose owning lattice cell was latticed. A solid voxel maps to the
  // cell containing its centre, which the predicate accepts by construction, so
  // this is simply the design's solid-voxel count restricted to the grid.
  for (int k = 0; k < sg.nz; ++k)
    for (int j = 0; j < sg.ny; ++j)
      for (int i = 0; i < sg.nx; ++i)
        if (dens[sg.index(i, j, k)] >= printed_iso) ++oc.region_voxels;
  return oc;
}

// --- Lattice CERTIFICATION (handoff 2026-07-29-lattice-certification-e2e) -----
// The join PR 220 (certification) and PR 231 (generation) left open: a job with a
// lattice block generated a latticed variant but certified only the SOLID design,
// so the reported margin described a DIFFERENT object than the exported file — the
// exact conflation that closed lattice mode originally (bar E1). This re-certifies
// each accepted, latticed variant against the REAL composite: the latticed voxels
// carry the homogenized octet cubic tensor (analyze_fixed_design with a posture),
// so the displacement field, the stiffness, and the SOLID-region strength margin
// describe the composite object the slicer opens.

// The certification posture matching the exported lattice geometry EXACTLY:
// `mask` is THE certification mask (lattice_certification_mask over the SAME
// LatticeBoundary that activated cells and clipped struts — bar B7 / H1b, one
// predicate, no third rule; on a graded run additionally intersected with the
// grading law's own mask). Solid voxels the mask leaves out — inactive cells, a
// clearance keep-out, a role region, the law's too-thin fallback — stay solid,
// faithful to the exported geometry (which now carries them as the solid
// companion body). `graded_rho`, when non-null, supplies each voxel its OWN
// relative density (stage 4); null => the uniform `rho`.
LatticePosture build_lattice_posture(const VoxelGrid& sg, double cell_mm,
                                     const std::vector<char>& mask, double rho,
                                     const std::vector<double>* graded_rho) {
  LatticePosture post;
  post.topology = LatticeTopology::Octet;  // job schema restricts topology to octet
  post.cell_size_mm = cell_mm;
  const std::size_t nv = sg.voxel_count();
  post.mask.assign(nv, 0);
  post.relative_density.assign(nv, 0.0);
  for (std::size_t e = 0; e < nv; ++e) {
    if (!mask[e]) continue;
    post.mask[e] = 1;
    post.relative_density[e] = graded_rho ? (*graded_rho)[e] : rho;
  }
  return post;
}

struct LatticeCertOutcome {
  bool ran = false;
  double rho = 0.0;                    // uniform relative density certified
                                       // (graded runs: the receipt reports the
                                       // achieved range from the grading law)
  FixedDesignAnalysis lattice;         // the LATTICED certification (tensor solve)
  StressMargin solid_margin;           // the variant's SOLID margin (report line)
  double solid_margin_effective = 0.0; // the variant's SOLID gated margin
  double solid_margin_reproduced = 0.0;// null-posture re-cert (proves reconstruction)
  bool solid_reproduced = false;       // solid_margin_reproduced == solid_margin?
  // The same proof read against the band the solver's own convergence tolerance
  // justifies (analyze.hpp, kMarginReproductionResidualFactor). `solid_reproduced`
  // above stays the LITERAL bit-equality it always was — it is what the receipt's
  // long-standing `solid_reconstruction_exact` key means, and on a run whose
  // solves fall back to Jacobi-CG it is FALSE, because the ladder's certification
  // solve carried a Krylov recycle subspace this re-certification is denied.
  double solid_reproduction_relative_delta = 0.0;
  bool solid_reproduces_within_band = false;
  double cert_tolerance = 0.0;         // the solve's own relative-residual bound
};

// The exact certification inputs minimize_plastic certified the SOLID design with
// (the single-source-of-truth guarantee, analyze.hpp) — reconstructed once per
// variant and shared by the null-posture reproduction solve, the composite solve
// and (graded runs) the clamp-counterfactual solve, so all of them certify the
// identical load case.
struct LatticeCertContext {
  SimpParams params;
  Vec3 build_dir{0.0, 0.0, 1.0};
  std::vector<NodalLoad> loads;
  bool load_path_ok = false;
  KnockdownSpec knockdown;
  double part_solid = 0.0;
  double cert_tol = 0.0;
  // The printed-set threshold every solve built from this context reads the design
  // at — 0.5 on a classic run, below the certified band's floor on a multiscale
  // one. Carried on the context so the SOLID certification, the LATTICED
  // re-certification and the clamp counterfactual cannot drift apart.
  double printed_iso = 0.5;
};

// `domain` is THE domain the run solved on (resolve_design_domain, pipeline.hpp):
// under a design box its grid is the EXPANDED grid and its BCs/loads are already
// remapped onto it. `part_grid` is the ORIGINAL imported part's grid — the
// denominator minimize_plastic's ladder normalises to, which under expansion is
// NOT the solved grid's solid count.
LatticeCertContext lattice_cert_context(const MinimizePlasticVariant& variant,
                                        const VoxelGrid& part_grid,
                                        const SolvedDesignDomain& domain,
                                        const MinimizePlasticOptions& options,
                                        const Material& material) {
  const VoxelGrid& sg = domain.grid;
  LatticeCertContext cx;
  cx.params.youngs_modulus = material.youngs_modulus_mpa;
  cx.params.poisson = material.poisson;
  cx.params.penalty = 3.0;  // ARCHITECTURE §4, matching minimize_plastic's cert solve
  // THE ONE resolver (handoff 2026-08-01-build-direction-separation): the job's
  // explicit build direction when set, else the documented gravity fallback.
  // Sharing the resolver with minimize_plastic is what guarantees this lattice
  // receipt certifies against the SAME orientation the run's own report did —
  // PR 266's S5 named three independent derivations as the silent-inconsistency
  // risk, and this is one of the three.
  //
  // ONE EXCEPTION, and it is the same principle (handoff
  // 2026-08-01-bake-build-orientation): when this variant's orientation was
  // CHOSEN — no direction was declared, so the scorer picked one, the run's
  // report certifies it and the exported mesh is rotated onto it — the lattice
  // receipt must certify THAT orientation too, or the composite margin would
  // describe a differently-placed object than the latticed file beside it. The
  // variant carries the applied direction precisely so this site cannot guess.
  // Off that path `applied_build_dir` IS resolve_build_direction(options), so
  // this is byte-identical for every existing run.
  cx.build_dir = variant.build_direction_auto_applied
                     ? variant.applied_build_dir
                     : resolve_build_direction(options);
  // The SAME load minimize_plastic certified this variant under, taken from THE
  // ONE definition (design_domain_loads, pipeline.hpp) rather than reconstructed
  // here: the declared external load REMAPPED onto the solved grid, or
  // self-weight recomputed on that grid. Under a design box the solved grid is
  // the expanded one and the declared loads are node-indexed to the PART — the
  // remap that fact demands is exactly what this site used to lack, and is why
  // a design-box run refused to be latticed at all (task
  // 2026-08-03-design-box-recertification). Off the box path
  // design_domain_loads returns options.external_loads verbatim / self-weight on
  // the caller's grid, i.e. byte-identical to what this site computed before.
  cx.loads = design_domain_loads(domain, options, material.density_g_cm3);
  cx.load_path_ok =
      load_path_connected(sg, variant.optimization.physical_density,
                          run_printed_iso(options));
  cx.knockdown = knockdown_spec_for(options);
  // The part-relative denominator (analyze.cpp's printed_fraction) is the
  // ORIGINAL part's solid count — the same quantity minimize_plastic's ladder
  // normalises to (handoff 080). Without a design box part_grid IS the solved
  // grid, so this is the identical number this site computed before.
  cx.part_solid = static_cast<double>(part_grid.solid_count());
  // E4 — the certification runs at the run's EXACT tight tolerance, asserted (not
  // commented). options.simp.cg_tolerance is minimize_plastic's kCertTol; draft mode
  // only ever loosens the TRAJECTORY (draft_loose_tol), never this cert solve, so if
  // draft is armed the cert tolerance must be strictly tighter than the loose one.
  cx.cert_tol = options.simp.cg_tolerance;
  // THE PRINTED-SET THRESHOLD this certification reads the design at (task
  // multiscale-lattice-to). It MUST be the same one the optimizer, the export and
  // the grading law used: on a multiscale design the in-band voxels below 0.5 are
  // real lattice material, and re-certifying at 0.5 would certify an object with
  // that material deleted — a different object than the one the file carries.
  cx.printed_iso = run_printed_iso(options);
  assert((!options.draft_quality || cx.cert_tol < options.draft_loose_tol) &&
         "E4: latticed certification must run at the tight cert tolerance, never the "
         "draft loose tolerance");
  return cx;
}

FixedDesignAnalysis analyze_variant_with_posture(
    const MinimizePlasticVariant& variant, const VoxelGrid& sg,
    const MinimizePlasticOptions& options, const Material& material,
    const std::vector<DirichletBC>& bcs, const LatticeCertContext& cx,
    const LatticePosture* post) {
  return analyze_fixed_design(sg, cx.params,
                              variant.optimization.physical_density, bcs,
                              cx.loads, material, cx.build_dir, cx.cert_tol,
                              options.simp.cg_max_iterations, options.simp.solver,
                              options.margin_stop, cx.knockdown, cx.load_path_ok,
                              cx.part_solid, post,
                              // The lattice receipt's own ranking, on its own
                              // composite field — the latticed object's strut
                              // criteria (S-c/S-d/S-e) are only measurable here.
                              options.build_orientation_report,
                              resolve_build_direction_is_inferred(options),
                              /*auto_apply_build_orientation=*/false,
                              // Read the design at the SAME threshold the
                              // optimizer, the export and the grading law used.
                              cx.printed_iso);
}

// Re-certify one accepted variant as the LATTICED composite: once with a nullptr
// posture (must reproduce the SOLID margin — a live proof the reconstruction is
// correct) and once with `post` (the composite margin that describes the exported
// file — uniform rho, or the graded per-voxel field on stage-4 runs). The solves
// are cheap certification-scale solves on the macro grid (zero added DOF).
LatticeCertOutcome certify_latticed_variant(const MinimizePlasticVariant& variant,
                                            const VoxelGrid& sg,
                                            const MinimizePlasticOptions& options,
                                            const Material& material,
                                            const std::vector<DirichletBC>& bcs,
                                            const LatticeCertContext& cx,
                                            const LatticePosture& post,
                                            double rho_uniform) {
  LatticeCertOutcome oc;
  oc.rho = rho_uniform;

  oc.solid_margin = variant.report.margin;
  oc.solid_margin_effective = variant.report.margin_effective;
  oc.cert_tolerance = cx.cert_tol;

  // (1) Null-posture re-cert — MUST reproduce the variant's SOLID margin. This is the
  // live proof that the reconstruction above is faithful (so the latticed margin that
  // shares it is trustworthy).
  //
  // NOT bit-for-bit, and the receipt now says so with a number instead of asserting
  // a contract that does not hold (task 2026-08-08-lattice-variant-margin-tolerance,
  // S1(a)). This solve runs under `ScopedLadderSolverIsolation` — recycling and GenEO
  // OFF — while the ladder's certification of the same design ran with a warm Krylov
  // recycle subspace. Two Krylov paths, one operator, both converged to the same
  // residual tolerance: the margins agree to the band that tolerance justifies, and
  // no further. On the maintainer's own run `solid_reconstruction_exact` has been
  // FALSE on every rung since the recycler was armed, and nothing read it.
  const FixedDesignAnalysis solid_recert = analyze_variant_with_posture(
      variant, sg, options, material, bcs, cx, /*post=*/nullptr);
  oc.solid_margin_reproduced = solid_recert.margin.worst_case;
  oc.solid_reproduced =
      (solid_recert.margin.worst_case == variant.report.margin.worst_case);
  oc.solid_reproduction_relative_delta = margin_reproduction_relative_delta(
      variant.report.margin.worst_case, solid_recert.margin.worst_case);
  oc.solid_reproduces_within_band = margin_reproduces(
      variant.report.margin.worst_case, solid_recert.margin.worst_case,
      cx.cert_tol);

  // (2) Latticed cert — the octet tensor on the shared occupancy. THIS margin
  // describes the exported file. The certifiable BAND is enforced INSIDE
  // analyze_fixed_design PER VOXEL (bars E5 / H4b): any masked voxel whose rho
  // sits outside [rho_min, rho_max] throws LatticeDensityOutOfBand rather than
  // certify against a clamped tensor.
  oc.lattice =
      analyze_variant_with_posture(variant, sg, options, material, bcs, cx, &post);
  oc.ran = true;
  return oc;
}

// Per-variant receipt payloads for the two new capabilities (task
// lattice-page-core-hookup). Both are emitted ONLY when their feature is in the
// job, so a legacy receipt stays byte-identical.
struct LatticeRoleReceipt {
  bool present = false;             // job carried lattice.regions
  std::size_t include_regions = 0;  // resolved (valid) include primitives
  std::size_t exclude_regions = 0;  // resolved (valid) exclude primitives
  long long include_void_voxels = 0;  // include-region voxels the OPTIMIZER left
                                      // void — the H1a no-op, reported not errored
  // ── WHY the void (task 2026-08-04-protect-freeze-vs-solidity, item 5). The
  // aggregate above sums two situations whose meanings are opposite:
  //
  //   BY CLEARANCE — the voxel is void because a declared "Keep clear" forbids
  //     material there. Lattice on a clearance void is the genuine no-op: the
  //     user asked to lattice a hole. NOTHING can put material there, so this is
  //     what a warning should fire on, and it does (see the emission below).
  //   BY THE OPTIMIZER — the voxel is void because the optimizer removed it at
  //     this rung. That is not a conflict at all: a lighter rung carries less
  //     material, and the same include region may be full at the next one.
  //
  // Split so the receipt can say which, and so the warning cannot be aimed at
  // the wrong one.
  long long include_void_by_clearance = 0;
  long long include_void_by_optimizer = 0;
};

// ── FROZEN MATERIAL vs LATTICE (task 2026-08-04-protect-freeze-vs-solidity)
//
// "Frozen" is a constraint on the OPTIMIZER — the density of these voxels may not
// change. It is NOT a statement that the material is solid. What the material IS
// — solid or latticed — is decided by the lattice page's include / exclude roles,
// exactly as it is for any other retained material, and this receipt is the proof
// that it was: for THIS variant, how much of the run's frozen set the lattice
// left solid and how much it latticed, plus the audit that the file and the
// certificate agree over the frozen voxels specifically.
//
// The frozen set is `effective_design_mask` (simp.hpp) — the set the loop itself
// held frozen, so this cannot be a second opinion about it. It includes the
// face-protection collars, the anchor/load pad, and (under a design box) the
// imported part where the box path freezes it.
//
// Emitted only when the run HAS frozen material and a lattice, so a run with
// neither writes byte-identical files.
struct LatticeFrozenReceipt {
  bool present = false;
  long long frozen_printed = 0;   // printed voxels the effective mask pins solid
  long long frozen_latticed = 0;  //   ... the certification mask lattices
  long long frozen_kept_solid = 0;  //   ... certified + exported SOLID
  // Of `frozen_printed`, how many sit inside a declared INCLUDE region (0 when
  // the job declares none — then the whole part is the include set by default),
  // how many inside an EXCLUDE region, and — the item-4 bar — how many of THOSE
  // were latticed anyway. `frozen_in_exclude_latticed` must be 0: an exclude
  // region says "retained AND solid", and it says it about frozen material
  // exactly as it does about any other retained material.
  long long frozen_in_include = 0;
  long long frozen_in_exclude = 0;
  long long frozen_in_exclude_latticed = 0;
  // ── THE AUDIT over the frozen voxels (bar 3). Same shape as the design-box
  // audit below — the cell set the certification mask implies over FROZEN
  // voxels, and how many of those cells the generator's own activation test
  // rejects (must be 0: a certified-latticed voxel whose cell was never emitted
  // is a certificate describing geometry the file does not contain). Plus the
  // both-ways count: frozen voxels that got a strut AND companion solid (0).
  long long frozen_cells_certified = 0;
  long long frozen_cells_not_emitted = 0;
  // Frozen voxels that are companion solid AND sit inside an emitted lattice
  // cell. On the ROLE path this is NOT zero and MUST NOT be asserted to be —
  // it is the deliberate bonding overlap: roles act on activation and on the
  // certification mask but are deliberately kept OUT of the strut clip
  // (lattice_boundary.hpp), because clipping a strut short of an exclude region
  // would leave the lattice/solid interface unbonded. A cell straddling a role
  // boundary therefore writes struts across it, into material the certificate
  // calls solid — MORE material than certified, the conservative direction.
  //
  // What must be zero is the count below, which is the actual divergence.
  long long frozen_voxels_strut_and_solid = 0;
  // Of those, the ones NOT explained by a straddling cell: the voxel is
  // companion solid, its cell was emitted, and that cell owns NO certified-
  // latticed voxel at all. Then the cell is not bonding a lattice to a solid
  // interface — it is writing struts into a region the certificate says is
  // entirely solid, with no lattice there to bond to. That IS a certified-
  // object-is-not-the-exported-object divergence and it must be 0.
  long long frozen_strut_and_solid_unexplained = 0;
};
// ── ADDED MATERIAL under a design box (task 2026-08-03-design-box-recertification)
//
// *** THIS IS A PLACEHOLDER FOR A DECISION THE MAINTAINER HAS NOT MADE. ***
//
// With a design box the optimizer may grow material where the ORIGINAL part was
// not. Nothing in the generator or the gate has an opinion about what should
// happen to that new material when the variant is latticed, and the three
// answers are genuinely different objects:
//
//   KEEP SOLID (what this constant selects, and the most conservative):
//       the added voxels are dropped from the certification mask, so they are
//       certified SOLID and exported as the solid companion body. The composite
//       is stiffer and stronger than either of the alternatives at the same
//       geometry, so no margin here is optimistic. Cost: mass — the added
//       material is exactly the material the optimizer grew to carry load, so
//       on a box run it can be a large fraction of the part.
//
//   LATTICE IT (flip this to false):
//       the added voxels are latticed like every other voxel. Lightest, and
//       arguably what a user who asked for a lattice meant. But the added
//       region is new, thin, load-path material with no imported geometry
//       behind it; a lattice cell that does not fit inside it is clipped, and
//       the composite margin then rests on struts in a region the user never
//       drew. Certified honestly either way — it is a design choice, not a
//       correctness one.
//
//   EXCLUDE IT (deliberately NOT implemented):
//       omitting the added material from the exported file would export an
//       object the certification did not describe, and the design the gate
//       accepted needs that material to carry its load. It is listed here only
//       so the record shows it was considered and rejected.
//
// Flipping this constant is the whole change; the receipt reports which policy
// ran (`added_material.policy`) and how much material it governed, so the
// maintainer can price the decision from a real run rather than in the abstract.
constexpr bool kDesignBoxAddedMaterialKeptSolid = true;

// What the added material was and how it was treated — emitted ONLY on a
// design-box run, so every existing receipt is byte-identical.
struct LatticeAddedMaterialReceipt {
  bool present = false;             // the run expanded (a design box was set)
  long long printed_voxels = 0;     // printed voxels of THIS variant, total
  long long inside_part = 0;        //   ... inside the ORIGINAL part envelope
  long long outside_part = 0;       //   ... OUTSIDE it (the material grown)
  long long outside_kept_solid = 0; // of those, dropped from the lattice mask
  // ── AND OF THOSE, THE ONES THAT WERE NEVER IN THE MASK TO BEGIN WITH (task
  // 2026-08-08-strut-clip-matches-shell). The added-material policy can only
  // DROP a voxel the certification mask had already accepted, so on its own
  // `outside_kept_solid` does not account for every outside voxel — and a count
  // that silently fails to add up is how an accounting bar turns into a bar
  // about accounting.
  //
  // WHY ANY OUTSIDE VOXEL IS NOW MISSED BY THE MASK. The mask's cell-overlap
  // proof runs against the EXPORTED SHELL, which is
  // `keep_largest_component(marching_cubes(...))` — the LARGEST body only. Under
  // a design box the optimizer can grow a disconnected island, and an island the
  // shell does not include is provably outside the allowed region, so its cells
  // never enter the mask. That is the RIGHT answer: a strut there would have sat
  // in the file with no shell around it at all. Measured on
  // test_designbox_lattice_recert's fixture: 12 of 716 outside voxels.
  //
  // outside_kept_solid + outside_never_masked == outside_part, exactly, and the
  // test asserts that partition rather than the old equality that assumed the
  // second term was always zero.
  long long outside_never_masked = 0;
  // EVERY voxel the policy dropped from the mask — the added material PLUS the
  // part voxels that share a lattice cell with it. The policy acts on whole
  // cells (see kDesignBoxAddedMaterialKeptSolid), so this is the honest "how
  // much of the object is solid because of this rule" number and it is always
  // >= outside_kept_solid.
  long long kept_solid_voxels = 0;
  double outside_volume_mm3 = 0.0;    // voxel basis (count x spacing^3)
  double kept_solid_volume_mm3 = 0.0; // same basis, for kept_solid_voxels
  // ── THE AUDIT (the bar that "certified == exported" is checkable by, not
  // argued for). All three are measured AFTER the geometry is written:
  //   certified_lattice_cells — cells the certification mask implies
  //                             (|{owning cell of a masked voxel}|);
  //   emitted_lattice_cells   — cells the GENERATOR actually emitted
  //                             (LatticeGenStats::latticed_cells, its own count);
  //   voxels_strut_and_solid  — printed voxels that are BOTH inside an emitted
  //                             lattice cell AND written as companion solid.
  // On a uniform design-box run the first two must be EQUAL and the third ZERO.
  long long certified_lattice_cells = 0;
  long long emitted_lattice_cells = 0;
  long long voxels_strut_and_solid = 0;
};

struct LatticeGradedReceipt {
  bool present = false;
  const GradedField* gf = nullptr;  // the law's full report for THIS variant

  // ── PER-REGION CELL DERIVATION (task 2026-08-05-lattice-cell-size-adaptation,
  // Stage E). One entry per DECLARED lattice include region, in the job's own
  // declaration order, or a single anonymous entry (region_id 0) covering the whole
  // candidate set when no include regions are declared. EMPTY unless the job asked
  // for it (`grading.report_region_cells`), which is what keeps every other run
  // byte-identical.
  //
  // It REPORTS, it never DECIDES. Nothing in this struct feeds a mask, a cell, a
  // density or a verdict; it is read off measurements the run already made and
  // arithmetic core already owns. In particular it never substitutes a skin for a
  // lattice the user asked for — that is offered in the options text and chosen by
  // the user, per the maintainer's explicit ruling.
  struct RegionCellReport {
    int region_id = 0;              // 1-based declaration order; 0 = anonymous union
    long long candidate_voxels = 0; // printed candidates carrying this id
    long long latticed_voxels = 0;  // ...the law actually latticed
    long long solid_voxels = 0;     // ...it kept solid

    // ── MEASURED, not declared ────────────────────────────────────────────────
    // The member-thickness range over this region's candidates (mm), from the same
    // local_member_thickness_mm the law itself reads. +inf means "thicker than the
    // EDT cap", the honest sentinel, not an error.
    double min_member_width_mm = 0.0;
    double max_member_width_mm = 0.0;
    // This region's peak von Mises over the PART's peak, on the variant's own
    // recovery field — the same quantity the retention predicate measures, reported
    // whether or not retention is armed so a user can see it before opting in.
    double stress_fraction = 0.0;

    // ── DERIVED at run time from lattice_derive_cell_for_member ────────────────
    // Evaluated at BOTH ends of the measured thickness range, because a region is
    // not one member: the thickest member may be latticeable while the thinnest is
    // not, and reporting one number would hide that. `at_thinnest` is the binding
    // one for whether the WHOLE region lattices.
    LatticeCellDerivation at_thinnest;
    LatticeCellDerivation at_thickest;

    // One of the four §2 outcomes, resolved from the measurements above:
    //   "certified"       — latticed, and the certificate covers it
    //   "out_of_regime"   — can be latticed, certificate does NOT cover it (the
    //                       sub-floor retention case); `exposure_fraction` sizes it
    //   "solid_load"      — kept solid because it is carrying load
    //   "no_pair"         — no (cell, rho) in the band fits this thickness at this
    //                       nozzle; `at_thinnest.min_member_width_mm` is the width
    //                       that would change the answer
    std::string verdict;
    double exposure_fraction = 0.0;  // retained sub-floor voxels / printed set
    // The nozzle at or below which the THINNEST member would become latticeable —
    // the other lever besides thickening. 0 when the region already lattices.
    double nozzle_needed_mm = 0.0;
  };
  std::vector<RegionCellReport> region_cells;
  // Field provenance (H4a): the demand field is THIS variant's own final
  // certification-recovery von Mises field — which variant, how many optimizer
  // iterations produced its converged design.
  double requested_vf = 0.0;
  double achieved_vf = 0.0;
  int iterations = 0;
  long long mask_voxels_dropped_by_cell_overlap = 0;  // law-masked voxels the
                                                      // shared predicate dropped
  // Clamp counterfactual (H4b): one extra cert solve with the clamped voxels
  // kept SOLID instead — did clamping decide the verdict?
  bool clamp_counterfactual_ran = false;
  bool counterfactual_accepted = false;
  bool clamp_changed_verdict = false;
};

// The per-variant lattice certification RECEIPT written beside the exported mesh
// (bar E1/E6): it states, for the file the maintainer slices, WHAT the margin
// describes. Carries the solid margin (what the solid mesh certifies), the
// null-posture reproduction proving the composite reconstruction, and the latticed
// composite margin + posture + the honest "strut strength not certified" flag.
// `cell_mm` is the exported cell (the job's on a uniform run, the grading law's on
// a graded run); `roles`/`graded` append their sections only when present.
std::string lattice_cert_report_json(const MinimizePlasticVariant& variant,
                                     const JobLattice& lat,
                                     const LatticeCertOutcome& c,
                                     const LatticeExportOutcome& oc,
                                     double cell_mm,
                                     const LatticeRoleReceipt& roles,
                                     const LatticeGradedReceipt& graded,
                                     const LatticeAddedMaterialReceipt& added,
                                     const LatticeFrozenReceipt& frozen,
                                     // THE ENCLOSED-VOID RULE (task 2026-08-05-
                                     // lattice-void-reaches-exterior). Null on
                                     // every run that did not arm the check, and
                                     // then not one byte of the receipt changes.
                                     // NO WALL CLOCK PARAMETER. The check's
                                     // wall time is deliberately not in this
                                     // document — see the cost block below. It
                                     // ships in run_info instead.
                                     const LatticeVoidEscapeReport* void_escape) {
  const LatticeGenStats& gs = oc.stats;
  const FixedDesignAnalysis& a = c.lattice;
  std::string s = "{\n";
  s += "  \"topology\": \"" + std::string(lattice_topology_name(a.lattice_topology)) +
       "\",\n";
  s += "  \"cell_mm\": " + json_num(cell_mm) + ",\n";
  s += "  \"strut_radius_mm\": " +
       (graded.present ? std::string("null") : json_num(lat.strut_radius_mm)) +
       ",\n";
  // Boundary finish (bar B9 — the mass/volume accounting includes skin, rim and
  // collar; soup basis, overlaps not deducted).
  s += "  \"skin\": " + json_str(lat.skin) + ",\n";
  // Outer finish (task 2026-07-30-lattice-skin-freeform). Emitted ONLY for a
  // non-default finish so a "shell" run's receipt stays byte-identical to the
  // boundary-finish receipt (bar E1).
  if (lat.outer_finish != "shell") {
    s += "  \"outer_finish\": " + json_str(lat.outer_finish) + ",\n";
    s += "  \"skin_chords\": " + std::to_string(gs.skin_chords) + ",\n";
    s += "  \"skin_chords_rejected_band\": " +
         std::to_string(gs.skin_chords_rejected_band) + ",\n";
    s += "  \"skin_chords_rejected_projection\": " +
         std::to_string(gs.skin_chords_rejected_projection) + ",\n";
    s += "  \"skin_chords_clipped_away\": " +
         std::to_string(gs.skin_chords_clipped_away) + ",\n";
    // Shell volume on the same disclosure basis as the lattice volumes: the
    // volume the closed shell surface encloses (divergence theorem) when the
    // shell is in the file, 0 when the "skin" finish dropped it.
    s += "  \"shell_enclosed_volume_mm3\": " +
         json_num(lat.outer_finish == "skin"
                      ? 0.0
                      : mesh_enclosed_volume_mm3(variant.v3.mesh)) +
         ",\n";
  }
  // ★ THE NO-PROTRUSION INVARIANT, as a recorded number (task 2026-08-08-strut-
  // clip-matches-shell, bar R3). Not a boolean: the amount, where, and out of how
  // many vertices — because "0" is only meaningful beside the count it was taken
  // over, and because the defect this closes was invisible in every receipt the
  // run wrote while being plainly visible in a slicer.
  //
  // Absent when the run could not measure (a "skin" outer finish carries no
  // shell), so a receipt never reports a zero it did not earn.
  if (oc.protrusion_measured) {
    s += "  \"clip_base_surface\": " +
         json_str(oc.clipped_against_shell ? "exported_shell"
                                           : "voxel_cube_union") +
         ",\n";
    s += "  \"protrusion_measured_against\": \"exported_shell\",\n";
    s += "  \"max_strut_protrusion_mm\": " + json_num(oc.max_protrusion_mm) +
         ",\n";
    s += "  \"protrusion_allowance_mm\": " +
         json_num(oc.protrusion_allowance_mm) + ",\n";
    s += "  \"protruding_vertices\": " +
         std::to_string(oc.protruding_vertices) + ",\n";
    s += "  \"protrusion_vertices_measured\": " +
         std::to_string(oc.measured_vertices) + ",\n";
  }
  s += "  \"clipped_struts\": " + std::to_string(gs.clipped_struts) + ",\n";
  s += "  \"landings\": " + std::to_string(gs.landings) + ",\n";
  s += "  \"anchor_nodes\": " + std::to_string(gs.anchor_nodes) + ",\n";
  s += "  \"skin_struts\": " + std::to_string(gs.skin_struts) + ",\n";
  s += "  \"rim_elements\": " + std::to_string(gs.rim_elements) + ",\n";
  s += "  \"interior_volume_mm3\": " + json_num(gs.interior_volume_mm3) + ",\n";
  s += "  \"skin_volume_mm3\": " + json_num(gs.skin_volume_mm3) + ",\n";
  s += "  \"rim_volume_mm3\": " + json_num(gs.rim_volume_mm3) + ",\n";
  // Solid-companion accounting (H1c) — the volume kept SOLID by roles / the
  // grading law's fallback, reported SEPARATELY from interior/skin/rim (voxel
  // basis, count × spacing³ — the mass-accounting basis, unlike the analytic
  // soup sums above). Emitted only when the companion machinery was armed, so a
  // legacy receipt is byte-identical.
  if (oc.solid_companion) {
    s += "  \"solid_region_voxels\": " + std::to_string(oc.solid_region_voxels) +
         ",\n";
    s += "  \"solid_region_volume_mm3\": " + json_num(oc.solid_region_volume_mm3) +
         ",\n";
    s += "  \"solid_region_triangles\": " +
         std::to_string(oc.solid_region_triangles) + ",\n";
  }
  // Lattice role regions (stage 1, H1a) — what the roles did, and the tested
  // precedence spelled out so the receipt cannot be misread.
  if (roles.present) {
    s += "  \"regions\": {\n";
    s += "    \"include\": " + std::to_string(roles.include_regions) + ",\n";
    s += "    \"exclude\": " + std::to_string(roles.exclude_regions) + ",\n";
    s += "    \"include_void_voxels\": " +
         std::to_string(roles.include_void_voxels) + ",\n";
    s += "    \"include_void_by_clearance\": " +
         std::to_string(roles.include_void_by_clearance) + ",\n";
    s += "    \"include_void_by_optimizer\": " +
         std::to_string(roles.include_void_by_optimizer) + ",\n";
    s += "    \"include_void_note\": \"include-region voxels where the optimizer "
         "left no material — a lattice cannot conjure material there, so the "
         "include is a NO-OP on them (reported, not an error). Split by CAUSE: "
         "\\\"by_clearance\\\" is a declared keep-clear, where nothing can ever "
         "put material and the include is unsatisfiable; \\\"by_optimizer\\\" is "
         "material this rung did not need, which a heavier rung may carry\",\n";
    s += "    \"precedence\": \"clearance beats include and exclude (no material "
         "to lattice); exclude beats include (kept solid); solid-kept material "
         "is certified SOLID and exported as the solid companion body\"\n";
    s += "  },\n";
  }
  // FROZEN MATERIAL (task 2026-08-04-protect-freeze-vs-solidity). What the run
  // held frozen, and what the lattice page decided that frozen material IS.
  // Emitted only when the run has frozen material AND a lattice, so a job with
  // neither writes byte-identical bytes.
  // *** EVERY KEY IN THIS BLOCK IS PREFIXED `frozen_`, DELIBERATELY. *** The
  // receipt is read by tests (and by front-ends) with a SUBSTRING search for
  // `"key":`, so a bare `printed_voxels` here would shadow `added_material`'s
  // `printed_voxels` further down and silently answer a different question. It
  // did exactly that once, and `designbox_lattice_recert` caught it — the block
  // is prefixed so it cannot happen again to a key added later.
  if (frozen.present) {
    s += "  \"frozen_material\": {\n";
    s += "    \"frozen_printed_voxels\": " +
         std::to_string(frozen.frozen_printed) + ",\n";
    s += "    \"frozen_latticed\": " + std::to_string(frozen.frozen_latticed) +
         ",\n";
    s += "    \"frozen_kept_solid\": " +
         std::to_string(frozen.frozen_kept_solid) + ",\n";
    s += "    \"frozen_in_include_region\": " +
         std::to_string(frozen.frozen_in_include) + ",\n";
    s += "    \"frozen_in_exclude_region\": " +
         std::to_string(frozen.frozen_in_exclude) + ",\n";
    s += "    \"frozen_in_exclude_region_latticed\": " +
         std::to_string(frozen.frozen_in_exclude_latticed) + ",\n";
    s += "    \"frozen_cells_certified\": " +
         std::to_string(frozen.frozen_cells_certified) + ",\n";
    s += "    \"frozen_cells_not_emitted\": " +
         std::to_string(frozen.frozen_cells_not_emitted) + ",\n";
    s += "    \"frozen_voxels_strut_and_solid\": " +
         std::to_string(frozen.frozen_voxels_strut_and_solid) + ",\n";
    s += "    \"frozen_strut_and_solid_unexplained\": " +
         std::to_string(frozen.frozen_strut_and_solid_unexplained) + ",\n";
    s += "    \"frozen_strut_and_solid_note\": \"voxels_strut_and_solid is NOT expected "
         "to be 0 where a lattice cell straddles a role boundary: roles act on "
         "cell activation and on the certification mask but are deliberately "
         "kept out of the strut clip, so struts weld across the interface into "
         "material certified solid (more material than certified — the "
         "conservative direction, and what bonds the lattice to the solid). "
         "strut_and_solid_unexplained is the real divergence and IS 0: no cell "
         "emits struts into a region the certificate calls entirely solid.\",\n";
    s += "    \"frozen_meaning\": \"FROZEN is a constraint on the OPTIMIZER — it may not "
         "change the density of these voxels. It is NOT a claim that the "
         "material is solid. Whether frozen material is solid or latticed is "
         "decided by the lattice regions (include = retained AND latticed, "
         "exclude = retained AND solid), exactly as for any other retained "
         "material.\",\n";
    s += "    \"frozen_audit\": \"cells_not_emitted and voxels_strut_and_solid are both "
         "0 on a coherent run: every cell the certificate lattices over frozen "
         "material is a cell the file contains, and no frozen voxel receives "
         "both a strut and companion solid.\"\n";
    s += "  },\n";
  }
  // Added material (task 2026-08-03-design-box-recertification) — on a design-box
  // run, HOW MUCH of this variant sits outside the original part's envelope and
  // what was done with it. Emitted only when the run expanded, so a no-box
  // receipt is byte-identical. The maintainer cannot judge the default without
  // the number, so the number is here and the policy names itself.
  if (added.present) {
    s += "  \"added_material\": {\n";
    s += "    \"policy\": " +
         json_str(kDesignBoxAddedMaterialKeptSolid ? "keep_solid" : "lattice") +
         ",\n";
    s += "    \"printed_voxels\": " + std::to_string(added.printed_voxels) +
         ",\n";
    s += "    \"inside_original_part\": " + std::to_string(added.inside_part) +
         ",\n";
    s += "    \"outside_original_part\": " + std::to_string(added.outside_part) +
         ",\n";
    s += "    \"outside_fraction\": " +
         json_num(added.printed_voxels > 0
                      ? static_cast<double>(added.outside_part) /
                            static_cast<double>(added.printed_voxels)
                      : 0.0) +
         ",\n";
    s += "    \"outside_volume_mm3\": " + json_num(added.outside_volume_mm3) +
         ",\n";
    s += "    \"outside_kept_solid_voxels\": " +
         std::to_string(added.outside_kept_solid) + ",\n";
    // The OTHER half of the partition: outside voxels the certification mask
    // never accepted, so the policy had nothing to drop. Both terms are emitted
    // so that outside_kept_solid + outside_never_masked == outside_original_part
    // is checkable from the receipt alone.
    s += "    \"outside_never_masked_voxels\": " +
         std::to_string(added.outside_never_masked) + ",\n";
    // The WHOLE-CELL cost of the policy: the added material plus the part
    // voxels that share a lattice cell with it. Reported separately because it
    // is the number that actually describes how much of the file is solid.
    s += "    \"kept_solid_voxels\": " + std::to_string(added.kept_solid_voxels) +
         ",\n";
    s += "    \"kept_solid_volume_mm3\": " +
         json_num(added.kept_solid_volume_mm3) + ",\n";
    s += "    \"certified_lattice_cells\": " +
         std::to_string(added.certified_lattice_cells) + ",\n";
    s += "    \"emitted_lattice_cells\": " +
         std::to_string(added.emitted_lattice_cells) + ",\n";
    s += "    \"voxels_strut_and_solid\": " +
         std::to_string(added.voxels_strut_and_solid) + ",\n";
    s += "    \"audit_note\": \"certified_lattice_cells is the cell set the "
         "certification mask implies; emitted_lattice_cells is the generator's "
         "own count of the cells it wrote. On a uniform run they are EQUAL and "
         "voxels_strut_and_solid is 0 — the exported lattice and the certified "
         "lattice are the same set of cells, and no voxel carries both a strut "
         "and companion solid.\",\n";
    s += "    \"kept_solid_fraction\": " +
         json_num(added.printed_voxels > 0
                      ? static_cast<double>(added.kept_solid_voxels) /
                            static_cast<double>(added.printed_voxels)
                      : 0.0) +
         ",\n";
    s += "    \"note\": \"material the optimizer grew OUTSIDE the imported "
         "part's envelope, under the design box. Policy \\\"keep_solid\\\" "
         "drops it from the lattice mask, so it is certified SOLID and exported "
         "as the solid companion body — the conservative default, and a "
         "PLACEHOLDER: whether added material should be latticed instead is a "
         "design decision the maintainer has not made. The policy acts on WHOLE "
         "LATTICE CELLS (a cell holding any added material is kept solid "
         "entire), because a cell is the atom the generator emits — so "
         "kept_solid_voxels exceeds outside_original_part by the part voxels "
         "sharing those cells, and no voxel ever receives both a strut and "
         "companion solid.\"\n";
    s += "  },\n";
  }
  // Graded lattice (stage 4) — the grading law's full per-variant record with
  // the field's provenance (H4a) and the band-clamp accounting (H4b).
  if (graded.present && graded.gf != nullptr) {
    const GradedField& gf = *graded.gf;
    const double latticed = static_cast<double>(gf.latticed_voxels);
    s += "  \"grading\": {\n";
    // ── STAGE E: the per-region cell derivation. Emitted ONLY when the job asked
    // for it, so every other receipt is byte-identical. Every number here is
    // measured on this run or derived at run time from core's own constants —
    // there is no literal in this block and no number that came from the app.
    if (!graded.region_cells.empty()) {
      auto num_or_null = [](double x) {
        // +inf is voxel.hpp's "thicker than the EDT cap" sentinel and JSON has no
        // infinity. `null` is the honest encoding: not "zero", not "unmeasured" —
        // it means the member exceeded what was measured, which is what a reader
        // must not confuse with a thin one.
        return std::isfinite(x) ? json_num(x) : std::string("null");
      };
      auto emit_derivation = [&](const std::string& in,
                                 const LatticeCellDerivation& d) {
        std::string t = in + "{\n";
        t += in + "  \"feasible\": " + (d.feasible ? "true" : "false") + ",\n";
        t += in + "  \"min_printable_cell_mm\": " +
             json_num(d.min_printable_cell_mm) + ",\n";
        t += in + "  \"max_homogenizable_cell_mm\": " +
             num_or_null(d.max_homogenizable_cell_mm) + ",\n";
        t += in + "  \"min_member_width_mm\": " +
             json_num(d.min_member_width_mm) + ",\n";
        if (d.feasible) {
          t += in + "  \"finest\": {\"cell_mm\": " +
               json_num(d.densest_cell_size_mm) + ", \"relative_density\": " +
               json_num(d.densest_relative_density) +
               ", \"strut_diameter_mm\": " +
               json_num(d.densest_strut_diameter_mm) +
               ", \"cells_per_member\": " +
               num_or_null(d.densest_cells_per_member) + "},\n";
          t += in + "  \"coarsest\": {\"cell_mm\": " +
               json_num(d.lightest_cell_size_mm) + ", \"relative_density\": " +
               json_num(d.lightest_relative_density) +
               ", \"strut_diameter_mm\": " +
               json_num(d.lightest_strut_diameter_mm) +
               ", \"cells_per_member\": " +
               num_or_null(d.lightest_cells_per_member) + "}\n";
        } else {
          t += in +
               "  \"why_not\": \"the two bounds CROSS: no cell is both printable "
               "at this nozzle and coarse enough to homogenize across this "
               "member. Thicken the member to min_member_width_mm, or use a "
               "nozzle at or under nozzle_needed_mm.\"\n";
        }
        t += in + "}";
        return t;
      };
      s += "    \"regions\": [\n";
      for (std::size_t i = 0; i < graded.region_cells.size(); ++i) {
        const LatticeGradedReceipt::RegionCellReport& rc = graded.region_cells[i];
        s += "      {\n";
        s += "        \"region_id\": " + std::to_string(rc.region_id) + ",\n";
        s += "        \"candidate_voxels\": " +
             std::to_string(rc.candidate_voxels) + ",\n";
        s += "        \"latticed_voxels\": " +
             std::to_string(rc.latticed_voxels) + ",\n";
        s += "        \"solid_voxels\": " + std::to_string(rc.solid_voxels) +
             ",\n";
        s += "        \"member_width_mm\": {\"min\": " +
             num_or_null(rc.min_member_width_mm) + ", \"max\": " +
             num_or_null(rc.max_member_width_mm) + "},\n";
        s += "        \"stress_fraction\": " + json_num(rc.stress_fraction) +
             ",\n";
        s += "        \"verdict\": " + json_str(rc.verdict) + ",\n";
        s += "        \"exposure_fraction\": " +
             json_num(rc.exposure_fraction) + ",\n";
        s += "        \"nozzle_needed_mm\": " + json_num(rc.nozzle_needed_mm) +
             ",\n";
        s += "        \"at_thinnest_member\": " +
             emit_derivation("        ", rc.at_thinnest) + ",\n";
        s += "        \"at_thickest_member\": " +
             emit_derivation("        ", rc.at_thickest) + "\n";
        s += std::string("      }") +
             (i + 1 < graded.region_cells.size() ? "," : "") + "\n";
      }
      s += "    ],\n";
      s += "    \"regions_note\": \"MEASURED per declared include region, DERIVED "
           "from core's own band, cells-per-member floor and measured strut-"
           "diameter table at run time. The verdict states what happened; it does "
           "not choose. A region reported \\\"no_pair\\\" is not un-latticeable in "
           "principle — it names the member width and the nozzle that would make "
           "the pair exist, and a skin is an alternative the user may pick, never "
           "one this pipeline substitutes.\",\n";
    }
    s += "    \"graded_from\": {\n";
    s += "      \"variant_vf\": " + json_num(graded.requested_vf) + ",\n";
    s += "      \"achieved_vf\": " + json_num(graded.achieved_vf) + ",\n";
    s += "      \"iterations\": " + std::to_string(graded.iterations) + ",\n";
    s += "      \"field\": \"von Mises certification-recovery field of THIS "
         "variant's own converged design (the run's final field for this rung — "
         "never an earlier iteration, never another run)\"\n";
    s += "    },\n";
    s += "    \"cell_size_mm\": " + json_num(gf.cell_size_mm) + ",\n";
    s += "    \"printability_floor_mm\": " + json_num(gf.printability_floor_mm) +
         ",\n";
    s += "    \"cell_size_floored\": " +
         std::string(gf.cell_size_floored ? "true" : "false") + ",\n";
    s += "    \"band\": [" + json_num(gf.band_rho_min) + ", " +
         json_num(gf.band_rho_max) + "],\n";
    s += "    \"rho_min_used\": " + json_num(gf.rho_min_used) + ",\n";
    s += "    \"rho_max_used\": " + json_num(gf.rho_max_used) + ",\n";
    s += "    \"region_voxels\": " + std::to_string(gf.region_voxels) + ",\n";
    s += "    \"latticed_voxels\": " + std::to_string(gf.latticed_voxels) + ",\n";
    s += "    \"solid_fallback_voxels\": " +
         std::to_string(gf.solid_fallback_voxels) + ",\n";
    // WHY, PER VOXEL, WITH COUNTS (task 2026-08-03-variant-postprocessing-fix,
    // bar F1). The two predicates sum to solid_fallback_voxels and have OPPOSITE
    // remedies, so an aggregate cannot be acted on. `irrecoverable_by_cell` is the
    // subset no cell size can rescue — the honest "do not offer a bigger cell".
    s += "    \"solid_fallback_by_reason\": {\n";
    s += "      \"member_too_thin_for_cell\": " +
         std::to_string(gf.fallback_member_too_thin) + ",\n";
    s += "      \"strut_unprintable_at_every_cell\": " +
         std::to_string(gf.fallback_strut_unprintable) + ",\n";
    s += "      \"irrecoverable_by_any_cell_size\": " +
         std::to_string(gf.fallback_irrecoverable_by_cell) + ",\n";
    s += "      \"widest_rejected_member_mm\": " +
         json_num(gf.fallback_max_member_width_mm) + ",\n";
    s += "      \"member_width_needed_mm\": " +
         json_num(gf.cells_per_member_floor * gf.cell_size_mm) + ",\n";
    s += "      \"note\": \"member_too_thin_for_cell: the member cannot hold "
         "cells_per_member_floor cells across at this cell size — a SMALLER cell "
         "helps. strut_unprintable_at_every_cell: the strut this density emits is "
         "under the stated minimum extrudable width at every available cell — a "
         "BIGGER cell helps. irrecoverable_by_any_cell_size: the member is thinner "
         "than the floor times the smallest printable cell, so no cell choice can "
         "lattice it; the design itself is too thin here.\"\n";
    s += "    },\n";
    // ── SUB-FLOOR RETENTION — THE ACCEPTED INACCURACY, NAMED (handoff
    //    2026-08-04-subfloor-lattice-unloaded-regions, bar S2) ───────────────────
    // Retaining below-the-floor material is a decision to accept an error nothing
    // here can size. A receipt that only flipped `lattice_strut_out_of_regime`
    // would bury that decision in a boolean; this block says WHICH voxels, at what
    // cells-per-member, and at what measured fraction of the part's peak stress.
    // EMITTED ONLY WHEN ARMED. A run that did not opt in gets no block at all,
    // which is what keeps its receipt byte-identical to a pre-task one (bar S1) —
    // and it loses nothing, because the below-floor population it would report is
    // already in `solid_fallback_by_reason.member_too_thin_for_cell` above.
    if (gf.subfloor_retention_armed) {
    s += "    \"subfloor_retention\": {\n";
    s += "      \"armed\": true,\n";
    s += "      \"stress_fraction_ceiling\": " +
         json_num(gf.subfloor_stress_fraction_max) + ",\n";
    s += "      \"region_stress_fraction_measured\": " +
         json_num(gf.region_stress_fraction) + ",\n";
    s += "      \"region_qualified\": " +
         std::string(gf.region_qualified_unloaded ? "true" : "false") + ",\n";
    s += "      \"voxels_below_floor\": " +
         std::to_string(gf.subfloor_candidate_voxels) + ",\n";
    s += "      \"voxels_retained\": " +
         std::to_string(gf.subfloor_retained_voxels) + ",\n";
    s += "      \"voxels_recovered_in_regime\": " +
         std::to_string(gf.subfloor_recovered_in_regime_voxels) + ",\n";
    s += "      \"retained_cells_per_member\": [" +
         json_num(gf.subfloor_min_cells_per_member) + ", " +
         json_num(gf.subfloor_max_cells_per_member) + "],\n";
    s += "      \"retained_strut_diameter_mm\": [" +
         json_num(gf.subfloor_min_strut_diameter_mm) + ", " +
         json_num(gf.subfloor_max_strut_diameter_mm) + "],\n";
    s += "      \"cells_per_member_floor\": " +
         json_num(gf.cells_per_member_floor) + ",\n";
    // ── THE AGGREGATE, and the per-region breakdown that a single total hides.
    // "Each region qualified individually" and "the part is fine" are DIFFERENT
    // STATEMENTS: nothing in the certificate adds the regions up, so the receipt
    // does. `exposure_fraction_of_part` is the quantity the cap bounds.
    s += "      \"aggregate_cap_fraction\": " +
         json_num(gf.subfloor_aggregate_cap_fraction) + ",\n";
    s += "      \"part_printed_voxels\": " +
         std::to_string(gf.part_printed_voxels) + ",\n";
    s += "      \"exposure_fraction_of_part\": " +
         json_num(gf.subfloor_retained_fraction_of_part) + ",\n";
    s += "      \"would_retain_voxels\": " +
         std::to_string(gf.subfloor_would_retain_voxels) + ",\n";
    s += "      \"over_budget\": " +
         std::string(gf.subfloor_over_budget ? "true" : "false") + ",\n";
    if (gf.subfloor_over_budget)
      s += "      \"over_budget_note\": \"the total sub-floor material this job "
           "would retain across ALL regions exceeds the aggregate exposure cap, so "
           "NOTHING was retained and this run is the un-armed run exactly. It is "
           "not trimmed to fit: choosing which regions to sacrifice is a judgement "
           "nothing measures. Narrow the lattice regions, or raise "
           "grading.subfloor_aggregate_cap deliberately and own the exposure.\",\n";
    s += "      \"regions\": [\n";
    for (std::size_t ri = 0; ri < gf.subfloor_regions.size(); ++ri) {
      const GradedField::SubfloorRegion& r = gf.subfloor_regions[ri];
      s += "        {\"region_id\": " + std::to_string(r.region_id) +
           ", \"candidate_voxels\": " + std::to_string(r.candidate_voxels) +
           ", \"below_floor_voxels\": " + std::to_string(r.below_floor_voxels) +
           ", \"stress_fraction_measured\": " + json_num(r.stress_fraction) +
           ", \"qualified\": " + std::string(r.qualified ? "true" : "false") +
           ", \"retained_voxels\": " + std::to_string(r.retained_voxels) + "}";
      if (ri + 1 < gf.subfloor_regions.size()) s += ",";
      s += "\n";
    }
    s += "      ],\n";
    s += "      \"regions_note\": \"region_id is 1-based in the job's own "
         "lattice.regions declaration order (0 = no include regions declared, i.e. "
         "the whole printed set as one group). Each row's stress_fraction_measured "
         "is that region's OWN peak von Mises over the PART's peak. A region "
         "qualifying here is a statement about THAT region only — the part-level "
         "question is exposure_fraction_of_part against aggregate_cap_fraction, and "
         "the two can disagree.\",\n";
    s += "      \"note\": \"region_stress_fraction_measured is this region's PEAK "
         "von Mises over the PART's peak, measured from the variant's own field — "
         "never declared by the job. voxels_retained were kept as lattice below "
         "the cells-per-member floor because that fraction cleared the ceiling; "
         "they are the reason lattice_strut_out_of_regime is raised. The "
         "certification is STRUCTURALLY BLIND to cells-per-member (the homogenized "
         "tensor is a function of relative density alone), so a margin that did not "
         "move is NOT evidence this material is accurately certified — it is an "
         "accepted, unquantified inaccuracy. armed=false leaves every number here "
         "at zero and the run bit-identical. voxels_recovered_in_regime were "
         "latticed because retention was armed but CLEAR the floor at their own "
         "cell, so they are certified in regime and carry no accuracy claim; "
         "they are separated out precisely so voxels_retained stays the exact "
         "count of out-of-regime material.\"\n";
    s += "    },\n";
    }
    s += "    \"mask_voxels_dropped_by_cell_overlap\": " +
         std::to_string(graded.mask_voxels_dropped_by_cell_overlap) + ",\n";
    s += "    \"clamped_lo_voxels\": " + std::to_string(gf.clamped_lo_voxels) +
         ",\n";
    s += "    \"clamped_hi_voxels\": " + std::to_string(gf.clamped_hi_voxels) +
         ",\n";
    s += "    \"clamped_lo_fraction\": " +
         json_num(latticed > 0.0 ? gf.clamped_lo_voxels / latticed : 0.0) + ",\n";
    s += "    \"clamped_hi_fraction\": " +
         json_num(latticed > 0.0 ? gf.clamped_hi_voxels / latticed : 0.0) + ",\n";
    s += "    \"clamp_counterfactual_ran\": " +
         std::string(graded.clamp_counterfactual_ran ? "true" : "false") + ",\n";
    if (graded.clamp_counterfactual_ran) {
      s += "    \"counterfactual_solid_accepted\": " +
           std::string(graded.counterfactual_accepted ? "true" : "false") + ",\n";
      s += "    \"clamp_changed_verdict\": " +
           std::string(graded.clamp_changed_verdict ? "true" : "false") + ",\n";
      s += "    \"clamp_counterfactual_note\": \"one extra certification solve "
           "with every band-clamped voxel kept SOLID instead of latticed; "
           "clamp_changed_verdict is whether the accept verdict differs — i.e. "
           "whether the clamping was decisive, not cosmetic\",\n";
    }
    s += "    \"min_strut_diameter_mm\": " + json_num(gf.min_strut_diameter_mm) +
         ",\n";
    s += "    \"max_strut_diameter_mm\": " + json_num(gf.max_strut_diameter_mm) +
         ",\n";
    s += "    \"any_strut_below_min\": " +
         std::string(gf.any_strut_below_min ? "true" : "false") + ",\n";
    s += "    \"region_ungradeable\": " +
         std::string(gf.region_ungradeable ? "true" : "false") + "\n";
    s += "  },\n";
  }
  s += "  \"relative_density\": " + json_num(c.rho) + ",\n";
  s += "  \"certifiable_band\": [" +
       json_num(lattice_rho_min(a.lattice_topology)) + ", " +
       json_num(lattice_rho_max(a.lattice_topology)) + "],\n";
  s += "  \"lattice_voxels\": " + std::to_string(a.lattice_voxels) + ",\n";
  if (lat.outer_finish == "skin")
    s += "  \"describes\": \"the exported latticed mesh (octet interior + freeform "
         "2D boundary skin, NO solid shell) — the composite model below is "
         "shell-blind, see finish_note\",\n";
  else if (lat.outer_finish == "shell+skin")
    s += "  \"describes\": \"the exported latticed mesh (solid shell + octet "
         "interior + decorative freeform skin) solved with the octet homogenized "
         "cubic tensor\",\n";
  else
    s += "  \"describes\": \"the exported latticed mesh (solid shell + octet interior) "
         "solved with the octet homogenized cubic tensor\",\n";
  // What the SOLID variant mesh certifies (unchanged), and the proof the composite
  // reconstruction reproduces it exactly with a null posture.
  s += "  \"solid_margin_worst_case\": " + json_num(c.solid_margin.worst_case) + ",\n";
  s += "  \"solid_margin_reproduced\": " + json_num(c.solid_margin_reproduced) + ",\n";
  s += "  \"solid_reconstruction_exact\": " +
       std::string(c.solid_reproduced ? "true" : "false") + ",\n";
  // ADDITIVE, and the honest reading of the same proof. `..._exact` above is kept
  // verbatim (it is a shipped key and it is literally true as named), but on any
  // run whose solves fall back to Jacobi-CG it is false for a reason that has
  // nothing to do with the reconstruction — see analyze.hpp's band note. These
  // three say what actually happened: how far apart the two solves landed, the
  // band the certification tolerance justifies, and whether it cleared it.
  s += "  \"solid_reconstruction_relative_delta\": " +
       json_num(c.solid_reproduction_relative_delta) + ",\n";
  s += "  \"solid_reconstruction_band\": " +
       json_num(kMarginReproductionResidualFactor * c.cert_tolerance) + ",\n";
  s += "  \"solid_reconstruction_reproduces\": " +
       std::string(c.solid_reproduces_within_band ? "true" : "false") + ",\n";
  // What the LATTICED mesh certifies.
  s += "  \"lattice_margin_worst_case\": " + json_num(a.margin.worst_case) + ",\n";
  s += "  \"lattice_margin_effective\": " + json_num(a.margin_effective) + ",\n";
  s += "  \"margin_required\": " + json_num(variant.report.margin_required) + ",\n";
  // The receipt's verdict. The GATE's own verdict logic is untouched; a "skin"
  // finish is refused UPSTREAM of it (like the density-band fast-fail) because
  // the composite posture assumes every latticed voxel carries at least the
  // periodic octet stiffness, and the solid shell is what backstopped that
  // assumption at clipped boundary cells. Without the shell the assumption is
  // provably broken there, so an "accepted" receipt would describe a model the
  // exported file does not honour.
  const bool finish_certified = lat.outer_finish != "skin";
  s += "  \"lattice_accepted\": " +
       std::string((a.accepted && finish_certified) ? "true" : "false") + ",\n";
  if (lat.outer_finish != "shell") {
    s += "  \"finish_certified\": " +
         std::string(finish_certified ? "true" : "false") + ",\n";
    if (!finish_certified)
      s += "  \"finish_note\": \"outer_finish 'skin' drops the solid shell; the "
           "composite certification model is shell-blind (the posture never "
           "credited the shell), so the margins above describe the same model "
           "as a 'shell' run and do NOT certify the open, shell-less object: "
           "clipped boundary cells fall below the periodic-octet stiffness the "
           "posture assumes and the 2D skin's contribution is uncertified. "
           "Refused upstream of the gate; the gate's verdict logic is "
           "unchanged.\",\n";
  }
  s += "  \"lattice_mass_grams\": " + json_num(a.mass_grams) + ",\n";
  s += "  \"lattice_max_effective_von_mises_mpa\": " +
       json_num(a.lattice_max_effective_vm) + ",\n";
  s += "  \"strut_strength_uncertified\": " +
       std::string(a.lattice_strength_uncertified ? "true" : "false") + ",\n";
  // --- Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report) ----
  // The measured PR 259 de-homogenization law evaluated on THIS variant's macro
  // stress tensors. REPORT ONLY: none of these numbers feed `lattice_accepted`
  // (its verdict logic above is untouched), and `strut_strength_uncertified`
  // stays true — the maintainer asked for NUMBERS to test against, not a gate.
  if (a.lattice_strut_report) {
    const StrutStrengthReport& ss = a.lattice_strut;
    s += "  \"strut_strength\": {\n";
    s += "    \"law\": \"PR 259 kfit *_cert envelope (bulk/free-surface/cut "
         "populations), evidence/2026-07-31-lattice-dehomogenization-probe/"
         "kfit.csv; strut_vm <= Kd(rho)*vm(Sigma) + Kv(rho)*|p(Sigma)|, "
         "interlayer analogue Kild/Kilv\",\n";
    s += "    \"gated\": false,\n";
    // MARGINS — in-plane and interlayer SEPARATELY (bar L6): which one binds is
    // the point. The interlayer margin divides by the UNSOURCED z_knockdown.
    s += "    \"margin_in_plane\": " + json_num(ss.margin_in_plane) + ",\n";
    s += "    \"margin_interlayer\": " + json_num(ss.margin_interlayer) + ",\n";
    s += "    \"margin_worst_case\": " + json_num(ss.margin_worst_case) + ",\n";
    s += "    \"z_knockdown\": " + json_num(ss.z_knockdown_used) + ",\n";
    s += "    \"z_knockdown_provenance\": \"UNSOURCED — assumed FDM layer-bond "
         "knockdown (materials.json), never measured by coupon; the interlayer "
         "margin divides by it and PR 259 showed the verdict turns on it "
         "(0.377-0.394 at 0.55 vs 0.69-0.72 at 1.0). The bounds below are "
         "z_knockdown-free and survive re-sourcing.\",\n";
    // RATIOS — the z_knockdown-/yield-free part of the measurement (PR 259's
    // deliberate split): bounds in MPa + amplification vs the macro field.
    s += "    \"strut_vm_bound_max_mpa\": " + json_num(ss.vm_bound_max_mpa) +
         ",\n";
    s += "    \"strut_interlayer_bound_max_mpa\": " +
         json_num(ss.il_bound_max_mpa) + ",\n";
    s += "    \"max_lattice_macro_vm_mpa\": " + json_num(ss.max_macro_vm_mpa) +
         ",\n";
    s += "    \"amplification_vm\": " + json_num(ss.amplification_vm) + ",\n";
    s += "    \"amplification_interlayer\": " + json_num(ss.amplification_il) +
         ",\n";
    // ARGMAX voxels — where each bound peaks, with the macro invariants there.
    s += "    \"argmax_in_plane\": {\"rho\": " + json_num(ss.vm_argmax_rho) +
         ", \"macro_vm_mpa\": " + json_num(ss.vm_argmax_macro_vm_mpa) +
         ", \"macro_pressure_mpa\": " +
         json_num(ss.vm_argmax_macro_pressure_mpa) + "},\n";
    s += "    \"argmax_interlayer\": {\"rho\": " + json_num(ss.il_argmax_rho) +
         ", \"macro_vm_mpa\": " + json_num(ss.il_argmax_macro_vm_mpa) +
         ", \"macro_pressure_mpa\": " +
         json_num(ss.il_argmax_macro_pressure_mpa) + "},\n";
    // Build-direction resolution: on a lattice cube axis the interlayer bound is
    // exactly the measured envelope; off-axis it carries the conservative strut-
    // shear cross term (strut_strength.hpp).
    s += "    \"build_dir_on_lattice_axis\": " +
         std::string(ss.build_dir_on_lattice_axis ? "true" : "false") + ",\n";
    s += "    \"interlayer_off_axis_cross_factor\": " +
         json_num(ss.il_cross_factor) + ",\n";
    // Out-of-band rho accounting (bar L5): law span vs certified band, clamped
    // voxels COUNTED — never silently extrapolated.
    s += "    \"law_rho_span\": [" + json_num(strut_law_rho_min()) + ", " +
         json_num(strut_law_rho_max()) + "],\n";
    s += "    \"rho_clamped_voxels\": " +
         std::to_string(ss.rho_clamped_voxels) + ",\n";
    // Cells-per-member regime guard (bar L4): below the floor the homogenized
    // macro stress this law amplifies is itself outside the tensor's validated
    // regime — the numbers above are then labelled out-of-regime, not trusted.
    s += "    \"cells_per_member_min\": " +
         json_num(a.lattice_min_cells_per_member) + ",\n";
    s += "    \"cells_per_member_floor\": " +
         json_num(lattice_cells_per_member_min(a.lattice_topology)) + ",\n";
    s += "    \"out_of_regime\": " +
         std::string(a.lattice_strut_out_of_regime ? "true" : "false") + ",\n";
    if (a.lattice_strut_out_of_regime) {
      s += "    \"regime_note\": \"the thinnest latticed member spans fewer "
           "cells than the measured homogenization floor, so the macro stress "
           "field these strut numbers amplify is itself out of the tensor's "
           "validated regime — treat them as indicative, not certified\",\n";
      // ★ THE THING THE USER MUST SEE, not just the reviewer. Carried on EVERY
      // out-of-regime certificate — however the run got there — because the one
      // wrong inference available here is "the margin barely moved, so it must be
      // fine". It cannot move: handoff 2026-08-04-protect-freeze-vs-solidity §10's
      // control swept the cell across the floor at fixed rho and got a margin
      // identical to TEN DECIMAL PLACES.
      s += "    \"blind_spot\": \"THE CERTIFICATE CANNOT SEE THIS. The "
           "homogenized tensor is a function of relative density ALONE — cell "
           "size never enters the composite solve — so the certification is "
           "STRUCTURALLY BLIND to cells-per-member: sweeping the cell from 5.00 "
           "to 1.00 cells per member at fixed density moved the certified margin "
           "by nothing, to ten decimal places. A margin that did not move is "
           "therefore NOT evidence that this material is accurately certified. "
           "Answering that needs direct FEA of the real strut geometry, measured "
           "at a 44-276x cost ceiling. This is an accepted unknown, not a clean "
           "bill of health.\",\n";
    }
    s += "    \"resolution_note\": \"joint-peak law rows are mesh-divergent "
         "(~log in micro resolution, +10-18% per 32->48 step where measured); "
         "the band-floor row is a still-rising lower bound\"\n";
    s += "  },\n";
  }
  // WHICH FRAME THIS RECEIPT'S DIRECTION-BEARING NUMBERS ARE IN (handoff
  // 2026-08-01-bake-build-orientation). Emitted only when the latticed file was
  // rotated, so a model-space run's receipt keeps its exact bytes.
  //
  // Every number above is a rigid-motion INVARIANT and so describes both frames:
  // the interlayer bound and its margin are scalars evaluated at the build
  // direction, and `build_dir_on_lattice_axis` compares the build direction with
  // the LATTICE's own axes — and the lattice is generated on the model grid and
  // rotated with the part, so that relation travels with the geometry. Nothing
  // here needed re-deriving in the build frame; this key says so explicitly
  // rather than leaving a reader to work it out.
  if (variant.export_baked) {
    s += "  \"export_frame\": {\"baked\": true, \"build_direction_in_file\": "
         "[0, 0, 1], \"applied_build_dir_model\": [" +
         json_num(variant.applied_build_dir.x) + ", " +
         json_num(variant.applied_build_dir.y) + ", " +
         json_num(variant.applied_build_dir.z) +
         "], \"note\": \"the latticed mesh beside this receipt was ROTATED so "
         "the certified build direction is +Z in the file. Every number in this "
         "receipt is a rigid-motion invariant and reads the same in the model "
         "frame and in the file's frame, including "
         "build_dir_on_lattice_axis — the lattice is generated on the model grid "
         "and rotated WITH the part, so its relation to the build direction "
         "travels with the geometry.\"},\n";
  }
  // ── THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
  // Written whenever the check RAN, pass or refusal. A receipt that only spoke
  // when something was wrong could not be told from one where the check never
  // fired — this project has shipped that exact failure twice (a forecast-only
  // job that reported itself as a build; a rim that emitted nothing while
  // succeeding), so a PASS states what it found and how it found it.
  if (void_escape) {
    const LatticeVoidEscapeReport& ve = *void_escape;
    s += "  \"void_escape\": {\n";
    s += "    \"rule\": \"the void space inside any lattice must reach the "
         "exterior — no sealed lattice-filled cavities\",\n";
    s += "    \"ran\": true,\n";
    s += "    \"decidable\": " + std::string(ve.decidable ? "true" : "false") +
         ",\n";
    s += "    \"sealed\": " + std::string(ve.sealed() ? "true" : "false") + ",\n";
    s += "    \"connectivity\": 6,\n";
    s += "    \"connectivity_note\": \"FACE adjacency only. Two voxels meeting "
         "along an edge or at a corner share zero area, so nothing flows "
         "through the contact; a diagonal 'escape' is a staircase of corner "
         "touches through a wall that is solid everywhere a fluid could pass. "
         "The SOLID load path deliberately uses 26-connectivity (two hex8 "
         "elements touching at a corner do share a node and do pass force), and "
         "the two must be complementary — (26, 6) — or a void path and a solid "
         "path could cross the same diagonal. 6 also reaches a subset of what "
         "18 or 26 would, so this check can only ever refuse MORE, never "
         "less.\",\n";
    s += "    \"latticed_voxels\": " + std::to_string(ve.latticed_voxels) + ",\n";
    s += "    \"latticed_cells\": " + std::to_string(ve.latticed_cells) + ",\n";
    s += "    \"latticed_voxels_reached\": " +
         std::to_string(ve.latticed_reached) + ",\n";
    s += "    \"latticed_voxels_sealed\": " +
         std::to_string(ve.latticed_sealed) + ",\n";
    s += "    \"sealed_cells\": " + std::to_string(ve.sealed_cells) + ",\n";
    s += "    \"sealed_volume_mm3\": " + json_num(ve.sealed_volume_mm3) + ",\n";
    s += "    \"reachable_void_volume_mm3\": " +
         json_num(ve.reachable_escape_volume_mm3) + ",\n";
    // WHICH WAY OUT IT FOUND.
    s += "    \"escape_depth_voxels\": " +
         std::to_string(ve.lattice_escape_depth) + ",\n";
    s += "    \"escape_faces\": [";
    {
      bool first = true;
      for (int f = 0; f < 6; ++f)
        if (ve.face_escapes[f]) {
          if (!first) s += ", ";
          first = false;
          s += json_str(grid_face_name(static_cast<GridFace>(f)));
        }
    }
    s += "],\n";
    s += "    \"escape_components\": " + std::to_string(ve.open_components) +
         ",\n";
    // Enclosed voids that hold NO lattice: reported, never refused — this rule
    // is about lattice, and a check that widened its own scope in the receipt
    // would be a different check.
    s += "    \"sealed_pockets_without_lattice\": " +
         std::to_string(ve.sealed_pockets_without_lattice) + ",\n";
    s += "    \"sealed_volume_without_lattice_mm3\": " +
         json_num(ve.sealed_volume_without_lattice_mm3) + ",\n";
    // COST: the check's own work, separate from `gen_seconds` above.
    //
    // ★ `bfs_visits` IS HERE AND THE WALL CLOCK IS NOT (task
    // 2026-08-06-arm-projection-and-void-check). It used to carry both, and
    // arming the check by default is what exposed why it cannot.
    //
    // THE PER-VARIANT RECEIPT IS A DOCUMENT THIS PROJECT REQUIRES TO BE
    // BYTE-IDENTICAL ON A RERUN. Five validation tests assert exactly that —
    // test_lattice_hookup H1d/H5, test_lattice_variant Z8,
    // test_protect_freeze_vs_solidity PF6, test_designbox_lattice_recert AI7,
    // and test_bake_build_orientation V6, which compares receipts across a
    // rotation. A wall clock cannot satisfy that: two identical runs measured
    // 0.0010455 s and 0.001088709 s, and those two numbers were the ONLY
    // difference between the two documents.
    //
    // PR 305 wrote the clock here and never hit this, because the block only
    // existed when the check was explicitly armed and no armed run was ever
    // rerun-compared. Defaulting the check on makes every lattice receipt carry
    // it, so the conflict became five test failures at once.
    //
    // NOTHING IS LOST. `bfs_visits` is the DETERMINISTIC cost figure — voxel
    // pushes, a pure function of the grid and the mask, and the one that
    // actually bounds the work (O(voxel_count), asserted in
    // test_lattice_void.cpp section F). The WALL CLOCK still ships, in
    // `run_info.lattice_export.void_escape.wall_seconds`
    // (observability.cpp:974) — which is where this project already keeps
    // clocks, and which every byte-identity comparison already excludes BY NAME
    // for exactly this reason. Both figures are still reported, still
    // separately, and still outside `gen_seconds`.
    s += "    \"bfs_visits\": " + std::to_string(ve.bfs_visits) + ",\n";
    s += "    \"pockets\": [";
    for (std::size_t p = 0; p < ve.pockets.size(); ++p) {
      const SealedVoidPocket& P = ve.pockets[p];
      if (p) s += ",";
      s += "\n      {\"voxels\": " + std::to_string(P.voxels) +
           ", \"latticed_voxels\": " + std::to_string(P.latticed_voxels) +
           ", \"cells\": " + std::to_string(P.cells) +
           ", \"volume_mm3\": " + json_num(P.volume_mm3) +
           ", \"bbox_min_mm\": [" + json_num(P.bbox_min.x) + ", " +
           json_num(P.bbox_min.y) + ", " + json_num(P.bbox_min.z) +
           "], \"bbox_max_mm\": [" + json_num(P.bbox_max.x) + ", " +
           json_num(P.bbox_max.y) + ", " + json_num(P.bbox_max.z) +
           "], \"include_regions\": [";
      for (std::size_t q = 0; q < P.region_ids.size(); ++q) {
        if (q) s += ", ";
        s += std::to_string(P.region_ids[q]);
      }
      s += "]}";
    }
    s += ve.pockets.empty() ? "],\n" : "\n    ],\n";
    s += "    \"pockets_listed\": " + std::to_string(ve.pockets.size()) + ",\n";
    s += "    \"pockets_total\": " + std::to_string(ve.sealed_pockets_total) +
         ",\n";
    s += "    \"scope_note\": \"this is a statement about the DESIGN FIELD the "
         "certificate and the file are both derived from. It is not the "
         "isolated-fragment check (SOLID pieces attached to nothing — opposite "
         "polarity, not implemented here), and it does not model the exported "
         "solid shell as a barrier: the shell is the marching-cubes surface of "
         "the printed set, and whether it closes over a boundary lattice cell "
         "is what the 'skin' / 'shell+skin' outer finish exists to answer.\"\n";
    s += "  },\n";
  }
  s += "  \"note\": \"stiffness and solid-region strength are certified against the "
       "real composite; the lattice region's macro (effective) stress is recovered "
       "but strut-level strength needs de-homogenization (Phase 2) and is NOT gated. "
       "Octet tensor magnitudes carry PR 198's +-10% resolution caveat.\"\n";
  s += "}\n";
  return s;
}

// --- THE per-variant lattice pipeline, ONCE (task 2026-08-02-lattice-a-variant)
//
// Everything one variant needs to become a latticed, certified, exported object:
// grade (when armed) from THAT variant's own von Mises field, build the ONE
// shared boundary, derive the certification mask, emit the geometry, certify the
// composite against the SAME mask, and write the receipt.
//
// WHY IT IS A FUNCTION NOW. It was the body of run_job's `emit_lattice` lambda.
// The re-lattice entry point (lattice_variant_job) has to do exactly this, to a
// variant it read back from design.bin instead of one the optimizer just
// produced — and "exactly this" has to mean the same code, not a second copy
// that agrees today. Bars Z3 and Z5 are both properties of this body: the mesh
// and the certification consume ONE `mask` and ONE density, and the strut report
// rides the composite solve. A duplicate would put both bars one edit away from
// silently diverging. The extraction is mechanical — the body is unchanged and
// the caller's aggregation is unchanged, which is what the byte-identity bar
// (Z6) checks.
// ── ★ STEPPED — ONE CELL PER DECLARED REGION, NO TRANSITION HANDLING (§4) ──────
//
// ★ FIRST, WHAT PR 344 DID AND DID NOT LEAVE BEHIND. Its handoff says, under "WHAT IS
// NOT DONE, PLAINLY":
//     "§4(a) — STEPPED is not shipped. The dyadic ladder exists and is FEA-driven,
//      but no user-facing Lattice Settings option was added."
// (docs/handoffs/2026-08-20-lattice-only-grading.md.) Read exactly: the MECHANISM it
// had in mind is the ladder already in `cell_mode: "swept"`, which does vary the cell
// from the FEA; what was missing there was only the option. No algorithm code was
// written, and none is missing on that reading.
//
// ★ BUT THIS TASK'S TWO ALGORITHMS DIFFER ON EXACTLY THE THING THE LADDER IS. It
// defines DOUBLED as "the dyadic ladder" and STEPPED as "per-region cell from the FEA,
// NO TRANSITION HANDLING" — and the ladder IS the transition handling. So the two
// cannot both be `swept`, and the no-transition variant was genuinely not in the tree:
// `CellSizeMode` on PR 345's HEAD is {Fixed, Auto, Swept, Fit}, and grep for a lattice
// algorithm named "stepped" across PR 344's, 345's and 346's branches finds only
// `stair-stepped`, `steppedWidth` and a LoadFlow comment. A selector value that
// silently ran DOUBLED would be the worst of the three options, so it is built here.
//
// ★ WHAT IT IS. Each declared include region gets ONE cell, derived from the FEA:
//
//     rho_r  = the MEDIAN graded relative density over the region's own voxels
//              (the grading law's answer, so it carries the intent and the demand)
//     W_r    = the MEDIAN local member width over the same voxels
//     S_r    = max( W_r / N* ,  w / phi(rho_r) )          [VERBATIM — no dyadic snap]
//
// the same two bounds `Fit` balances — N* cells across where the member can hold them,
// the finest cell that still prints where it cannot — but evaluated at the region's own
// FEA-driven density, and TAKEN AS IT COMES OUT. That last part is the whole difference
// from DOUBLED: no snapping to S0 * 2^L, no aligned octree, no 2:1 balance.
//
// ★ AND THAT IS EXACTLY WHY IT HAS A COST NOBODY SHOULD PAY BLIND. PR 235 measured and
// REJECTED banded regions for this reason: two abutting cells of unrelated size share
// no nodes, so a strut ending on the seam ends in mid-air. DOUBLED's dyadic ladder
// exists precisely to make coarse nodes nest in the fine grid. STEPPED gives that up.
// It does not pretend otherwise — `stepped_adjacent_region_pairs` /
// `stepped_pairs_joined` MEASURE how many abutting region pairs actually have touching
// solids, and a pair that does not touch is a mechanical disconnection reported as one.
struct SteppedRegionCell {
  int region_id = 0;          // 1-based, the job's own include-region order
  std::size_t voxels = 0;
  double median_rho = 0.0;    // FEA-driven: the grading law's own answer here
  double median_width_mm = 0.0;
  double cell_mm = 0.0;       // VERBATIM, never snapped
  double strut_mm = 0.0;
  double cells_per_member = 0.0;
  bool out_of_regime = false; // below the ACCURACY floor: buildable, uncertified
};

struct SteppedOutcome {
  bool ran = false;
  std::vector<SteppedRegionCell> cells;
  std::vector<double> cell_field;   // grid-indexed, 0 off the lattice
  std::size_t regions_with_no_voxels = 0;
  double min_cell_mm = 0.0, max_cell_mm = 0.0;
  long long adjacent_region_pairs = 0;
  long long adjacent_pairs_joined = 0;
};

SteppedOutcome run_stepped_step(const VoxelGrid& grid,
                                const std::vector<double>& density,
                                const std::vector<char>& lattice_mask,
                                const std::vector<double>& relative_density,
                                const std::vector<int>& region_ids,
                                const JobGrading& jg, double printed_iso,
                                int thickness_cap_voxels) {
  SteppedOutcome so;
  const std::size_t n = grid.voxel_count();
  if (lattice_mask.size() != n || relative_density.size() != n ||
      region_ids.size() != n)
    throw JobError("stepped: the graded posture does not cover this grid");
  const LatticeTopology topo = LatticeTopology::Octet;
  const double n_star = lattice_cells_per_member_min(topo);
  const double w = jg.min_extrudable_width_mm;
  if (!(w > 0.0))
    throw JobError(
        "stepped: min_extrudable_width_mm is 0, which means UNSET — the minimum "
        "extrudable width is user input and this law will not default it");
  const std::vector<double> width =
      local_member_thickness_mm(grid, density, printed_iso, thickness_cap_voxels);

  // Gather per region, in ASCENDING region id — a fixed order (§5a). FULL SORTS for
  // both medians, never a sampled estimate (§5b).
  std::map<int, std::vector<double>> rhos, widths;
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    const int r = region_ids[e];
    rhos[r].push_back(relative_density[e]);
    if (std::isfinite(width[e]) && width[e] > 0.0) widths[r].push_back(width[e]);
  }
  so.cell_field.assign(n, 0.0);
  std::map<int, double> cell_of;
  for (auto& kv : rhos) {
    SteppedRegionCell rc;
    rc.region_id = kv.first;
    rc.voxels = kv.second.size();
    std::sort(kv.second.begin(), kv.second.end());
    rc.median_rho = kv.second[kv.second.size() / 2];
    std::vector<double>& wv = widths[kv.first];
    if (wv.empty()) { ++so.regions_with_no_voxels; continue; }
    std::sort(wv.begin(), wv.end());
    rc.median_width_mm = wv[wv.size() / 2];
    // ★ BOTH BOUNDS COME FROM CORE, never from arithmetic spelled out here. phi(rho)
    // is the measured octet diameter per unit cell, so w / phi(rho) is the finest cell
    // whose strut at THIS region's density still prints.
    const double phi = octet_strut_diameter_mm(rc.median_rho, 1.0);
    const double printable_min = phi > 0.0 ? w / phi : 0.0;
    const double homogenizable_max = rc.median_width_mm / n_star;
    rc.cell_mm = std::max(homogenizable_max, printable_min);
    if (!(rc.cell_mm > 0.0)) { ++so.regions_with_no_voxels; continue; }
    rc.strut_mm = octet_strut_diameter_mm(rc.median_rho, rc.cell_mm);
    rc.cells_per_member = rc.median_width_mm / rc.cell_mm;
    // Below the ACCURACY floor is COUNTED and reported out of regime, never hidden —
    // the same discipline sub-floor retention and the adaptive floor already hold.
    rc.out_of_regime = rc.cells_per_member < n_star;
    cell_of[rc.region_id] = rc.cell_mm;
    so.cells.push_back(rc);
  }
  if (so.cells.empty()) return so;
  so.min_cell_mm = so.max_cell_mm = so.cells.front().cell_mm;
  for (const SteppedRegionCell& rc : so.cells) {
    so.min_cell_mm = std::min(so.min_cell_mm, rc.cell_mm);
    so.max_cell_mm = std::max(so.max_cell_mm, rc.cell_mm);
  }
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    auto it = cell_of.find(region_ids[e]);
    if (it != cell_of.end()) so.cell_field[e] = it->second;
  }

  // ★ THE SEAM MEASUREMENT (the cost of "no transition handling", measured rather
  // than argued). Two regions are ADJACENT when a latticed voxel of one is 6-adjacent
  // to a latticed voxel of the other. Their lattices are JOINED only if the two cells
  // are equal — cells of unrelated size share no node positions, so their struts pass
  // each other without meeting. A pair that is adjacent and not joined is a mechanical
  // disconnection, and it is reported as one.
  std::set<std::pair<int, int>> adj;
  const int off[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!lattice_mask[e]) continue;
        for (const auto& d : off) {
          const int a = i + d[0], b = j + d[1], c = k + d[2];
          if (a >= grid.nx || b >= grid.ny || c >= grid.nz) continue;
          const std::size_t f = grid.index(a, b, c);
          if (!lattice_mask[f]) continue;
          const int ra = region_ids[e], rb = region_ids[f];
          if (ra == rb) continue;
          adj.emplace(std::min(ra, rb), std::max(ra, rb));
        }
      }
  so.adjacent_region_pairs = static_cast<long long>(adj.size());
  for (const auto& pr : adj) {
    auto ia = cell_of.find(pr.first), ib = cell_of.find(pr.second);
    if (ia == cell_of.end() || ib == cell_of.end()) continue;
    if (ia->second == ib->second) ++so.adjacent_pairs_joined;
  }
  so.ran = true;
  return so;
}

struct LatticeVariantOutcome {
  LatticeExportOutcome oc;
  LatticeCertOutcome cc;
  std::string receipt_path;
  std::string receipt_json;
  double cell_mm = 0.0;
  double gen_seconds = 0.0;
  bool graded = false;
  GradedField gf;                 // meaningful iff `graded`
  LatticeRoleReceipt role_rcpt;
  LatticeGradedReceipt grad_rcpt;  // `gf` pointer NOT retained (see below)
  // ★ WHICH ALGORITHM LAID THIS LATTICE DOWN (task 2026-08-21-organic-lattice, §4).
  // Doubled on every job that does not state one, so a legacy outcome is unchanged.
  LatticeAlgorithm algorithm = LatticeAlgorithm::Doubled;
  bool organic_ran = false;
  OrganicReport organic;  // meaningful iff `organic_ran`
  bool stepped_ran = false;
  SteppedOutcome stepped;  // meaningful iff `stepped_ran`
  LatticeAddedMaterialReceipt added_rcpt;  // design-box runs only
  LatticeFrozenReceipt frozen_rcpt;        // runs with frozen material only

  // The DESIGN the mesh was built from and the certification solved on — one
  // number, so "the certified object is the exported one" is checkable rather
  // than merely argued (bar Z3). Both consumers read the SAME `dens` reference
  // below; this fingerprints it once, at the single point they share.
  std::uint64_t design_fingerprint = 0;

  // NO LATTICE WAS PRODUCED, AND NOTHING WAS EMITTED (task
  // 2026-08-04-variant-volume-fraction-mismatch, bar B3 / L3). The grading law
  // had candidates and could grade NONE of them (`region_ungradeable`), so this
  // function returned before writing a single triangle. `why` is the whole
  // predicate — the reasons, the counts and the two widths whose relation is the
  // remedy.
  //
  // A FLAG RATHER THAN A THROW, because the two callers want opposite things
  // from the same fact. `lattice_variant_job` exists only to produce this one
  // lattice, so it refuses. The optimize path has a LADDER: one thin rung being
  // unlatticeable must not destroy the other rungs' output, so it skips that
  // rung, says so, and — critically — leaves it OUT of the run-level aggregates.
  bool ungradeable = false;
  std::string ungradeable_reason;

  // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
  // `void_check_ran` is false on every run that did not arm
  // `lattice.require_lattice_void_reaches_exterior`, and then nothing below is
  // measured, reported or written — the byte-identity bar.
  //
  // When it IS armed, `void_report` is the walk itself (topopt/lattice_void.hpp)
  // and it is reported whichever way the verdict went: a PASS records how much
  // void was reachable, how deep the drain path runs and which grid faces it
  // escapes through, because a silent pass is indistinguishable from a check
  // that did not run.
  //
  // `void_sealed` is a FLAG rather than a throw for exactly the reason
  // `ungradeable` above is: lattice_variant_job refuses (it exists to produce
  // this one object), while the optimize ladder skips the rung and keeps the
  // others. `void_check_seconds` is the check's own wall time, kept separate
  // from `gen_seconds` so its cost can be read against the run it protects.
  bool void_check_ran = false;
  LatticeVoidEscapeReport void_report;
  double void_check_seconds = 0.0;
  bool void_sealed = false;
  std::string void_sealed_reason;
};

// ★ THE LATTICE PIPELINE MUST NOT MOVE THE LADDER'S SOLVER STATE
// (task 2026-08-04-subfloor-lattice-unloaded-regions, §7).
//
// THE DEFECT THIS EXISTS TO CLOSE. On the STREAMING path this body runs from the
// `on_variant` callback — i.e. BETWEEN rung k and rung k+1 of the optimize ladder,
// not after it. It performs real FEA solves (the null-posture reproduction, the
// composite certification, and on a clamped run the clamp counterfactual). Both of
// the solver's carried accelerators are process-global / thread-local and STICKY
// across solves:
//
//   * the Krylov recycle subspace (handoff 133) — production-ARMED, and
//     `krylov_recycle_reset_per_rung` is false by default, so it is deliberately
//     carried from one rung into the next;
//   * the GenEO two-level deflation basis (handoff 2026-07-29-geneo-arming) —
//     armed by configure_production_options.
//
// So without this guard, rung k+1's optimize started from a subspace harvested
// from — or DROPPED by — rung k's LATTICE solves. That made the next rung's design
// depend on the lattice configuration of the previous rung, which is a dependency
// between two solves that have nothing to do with each other. It was measured, not
// theorised: arming sub-floor retention moved rungs 0.52 / 0.38 / 0.26 by 40 / 380
// / 416 voxel classifications on the maintainer's part while rung 0.68 — the rung
// retention actually fired on — stayed bit-identical.
//
// WHY SUPPRESS RATHER THAN RESET. Resetting after the fact would leave rung k+1
// with an EMPTY space, discarding the harvest the LADDER legitimately built at
// rung k — a different behaviour from both a no-lattice run and the batch path.
// Disabling the two accelerators for the duration preserves the carried state
// exactly: `RecycleSession::begin` returns on `!rc_enabled()` BEFORE its
// resolution-change drop, and `geneo_solve_begin` returns on `!S.enabled` BEFORE
// its structure-fingerprint drop, so a suppressed solve can neither harvest from,
// apply, nor invalidate what the ladder is carrying. Rung k+1 therefore inherits
// precisely what rung k left it, which is what a run with no lattice block does.
//
// It costs these diagnostic solves their accelerators. That is the right trade:
// they are a post-process whose wall time is reported separately, and correctness
// of the ladder is not negotiable against their speed.
//
// Applied inside THIS function rather than at the callback so the re-lattice entry
// point (lattice_variant_job) gets it too — the two must not diverge (bar Z6).
class ScopedLadderSolverIsolation {
 public:
  ScopedLadderSolverIsolation()
      : recycling_(fea_set_krylov_recycling(false)),
        geneo_(fea_set_geneo_twolevel(false)) {}
  ~ScopedLadderSolverIsolation() {
    fea_set_geneo_twolevel(geneo_);
    fea_set_krylov_recycling(recycling_);
  }
  ScopedLadderSolverIsolation(const ScopedLadderSolverIsolation&) = delete;
  ScopedLadderSolverIsolation& operator=(const ScopedLadderSolverIsolation&) = delete;

 private:
  const bool recycling_;
  const bool geneo_;
};

// ── ★ THE ORGANIC STEP, IN ONE PLACE (task 2026-08-21-organic-lattice, §4) ──────
//
// Both the analyze RECEIPT and the emitted GEOMETRY go through this function, so the
// two cannot describe different lattices. It is deliberately thin: the grading law
// still decides the DENSITY (all three algorithms honour the same intent, §4b), and
// this only turns that density into a SPACING FIELD and hands it to the tracer.
//
// ★ WHY THE DENSITY IS THE GRADING LAW'S AND NOT THE TRACER'S. Daynes' comparison —
// the one that measured +101 % stiffness — is against a uniform-cell core OF THE SAME
// DENSITY. Taking the density from the shared law is what makes the three-way
// comparison (R10) that same comparison rather than three unrelated parts.
//
// ★ THE SPACING LAW, AND IT IS THE ONE IN organic_lattice.hpp. Constant bead, spacing
// varies: d = organic_spacing_for(rho, t). That is CURVY's posture — "controls the
// spacing between adjacent streamlines LOCALLY USING THE DENSITY FIELD rather than a
// global density parameter" — and it is why the grade never has to thin a strut below
// what the nozzle lays.
struct OrganicOutcome {
  bool ran = false;
  OrganicLattice lat;
  double strut_diameter_mm = 0.0;
  // ★ R13: timed around the TRACER ALONE, so the number is a measurement of this
  // algorithm rather than of the solve it happens to sit beside.
  double trace_seconds = 0.0;
};

OrganicOutcome run_organic_step(const VoxelGrid& grid,
                                const std::vector<double>& density,
                                const std::vector<double>& stress_tensor,
                                // The candidate set and the density the GRADING LAW
                                // chose, passed explicitly rather than read off a
                                // GradedField, because the geometry path hands in the
                                // mask AFTER the shared boundary's cell-overlap proof
                                // has narrowed it — and tracing a voxel the export
                                // will not emit is exactly the certificate/file
                                // disagreement bar B7 exists to prevent.
                                const std::vector<char>& lattice_mask,
                                const std::vector<double>& relative_density,
                                double band_rho_min, double band_rho_max,
                                const JobGrading& jg,
                                const Vec3& build_dir, double printed_iso,
                                int thickness_cap_voxels) {
  OrganicOutcome oo;
  const std::size_t n = grid.voxel_count();
  // NO STRESS TENSOR, NO ORGANIC LATTICE. The whole method is the eigen-decomposition
  // of that field; without it there is nothing to trace along, and inventing an axis
  // would be worse than refusing. This is a REFUSAL rather than a fallback for the
  // same reason the printability floor is: a silent substitute is how a part gets
  // built to a rule nobody stated.
  if (stress_tensor.size() != 6 * n)
    throw JobError(
        "organic: this run carries no per-voxel stress tensor field, and the organic "
        "algorithm is the eigen-decomposition of exactly that field — refusing rather "
        "than tracing along an invented direction");
  if (lattice_mask.size() != n || relative_density.size() != n)
    throw JobError("organic: the graded posture does not cover this grid");

  // ★ THE BEAD, AND WHY THE DEFAULT IS NOT THE NOZZLE. See
  // organic_default_strut_diameter_mm: at the stated 0.42 mm the dense half of the
  // band asks for curves closer together than this grid samples the direction field,
  // every one of them is raised to the resolution floor, and the grade vanishes. The
  // default instead puts the DENSEST lattice in the band exactly on that floor, which
  // is the widest window the grid can express — and never below the user's stated
  // minimum extrudable width. A job that states `organic_strut_width_mm` overrides it.
  const double t =
      jg.organic_strut_width_mm > 0.0
          ? jg.organic_strut_width_mm
          : organic_default_strut_diameter_mm(grid.spacing, 1.0, band_rho_max,
                                              jg.min_extrudable_width_mm);
  oo.strut_diameter_mm = t;
  std::vector<char> cand(n, 0);
  std::vector<double> spacing(n, 0.0);
  std::size_t candidates = 0;
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    const double d = organic_spacing_for(relative_density[e], t);
    if (!(d > 0.0)) continue;  // a zero density has no spacing; it is not lattice
    cand[e] = 1;
    spacing[e] = d;
    ++candidates;
  }
  if (candidates == 0) return oo;  // nothing graded — the caller reports it as such

  // The SAME member-width field the grading law reads, at the law's own cap, so a
  // curves-per-member figure in the receipt and a cells-per-member figure beside it
  // are measured against the identical widths.
  const std::vector<double> width =
      local_member_thickness_mm(grid, density, printed_iso, thickness_cap_voxels);

  OrganicParams op;
  op.build_dir = build_dir;
  op.overhang_angle_deg = jg.organic_overhang_angle_deg;
  op.min_extrudable_width_mm = jg.min_extrudable_width_mm;
  op.strut_diameter_mm = t;
  op.rho_min = band_rho_min;
  op.rho_max = band_rho_max;
  const double t0 = wall_seconds();
  oo.lat = trace_organic_lattice(grid, cand, stress_tensor, spacing, &width, op);
  oo.trace_seconds = wall_seconds() - t0;
  oo.ran = true;
  return oo;
}

// Copy the tracer's report onto the receipt. ONE place, so the analyze receipt and
// the geometry receipt cannot disagree about what was traced.
void fill_stepped_run_info(RunInfo& gi, const SteppedOutcome& so) {
  gi.stepped_present = true;
  gi.stepped_regions = static_cast<long long>(so.cells.size());
  gi.stepped_min_cell_mm = so.min_cell_mm;
  gi.stepped_max_cell_mm = so.max_cell_mm;
  gi.stepped_regions_no_cell = static_cast<long long>(so.regions_with_no_voxels);
  gi.stepped_adjacent_region_pairs = so.adjacent_region_pairs;
  gi.stepped_adjacent_pairs_joined = so.adjacent_pairs_joined;
  for (const SteppedRegionCell& rc : so.cells) {
    gi.stepped_region_cell_mm.push_back(rc.cell_mm);
    gi.stepped_region_rho.push_back(rc.median_rho);
    gi.stepped_region_width_mm.push_back(rc.median_width_mm);
    gi.stepped_region_cells_per_member.push_back(rc.cells_per_member);
    gi.stepped_region_voxels.push_back(static_cast<long long>(rc.voxels));
    if (rc.out_of_regime) ++gi.stepped_regions_out_of_regime;
  }
}

void fill_organic_run_info(RunInfo& gi, const OrganicOutcome& oo) {
  const OrganicReport& r = oo.lat.report;
  gi.organic_present = true;
  gi.organic_strut_diameter_mm = r.strut_diameter_mm;
  gi.organic_trace_seconds = oo.trace_seconds;
  gi.organic_candidate_voxels = static_cast<long long>(r.candidate_voxels);
  gi.organic_degenerate_voxels = static_cast<long long>(r.degenerate_voxels);
  gi.organic_degenerate_fraction = r.degenerate_fraction;
  gi.organic_max_frame_swap_fraction = r.max_frame_swap_fraction;
  gi.organic_curves_traced = static_cast<long long>(r.curves_traced);
  gi.organic_curves_kept = static_cast<long long>(r.curves_kept);
  gi.organic_curves_thinned = static_cast<long long>(r.curves_thinned);
  gi.organic_curves_too_short = static_cast<long long>(r.curves_too_short);
  gi.organic_total_curve_length_mm = r.total_curve_length_mm;
  gi.organic_curves_per_family.assign(r.curves_per_family, r.curves_per_family + 3);
  gi.organic_curve_length_per_family_mm.assign(
      r.curve_length_per_family_mm, r.curve_length_per_family_mm + 3);
  gi.organic_stop_left_region = r.stop_left_region;
  gi.organic_stop_hit_d_test = r.stop_hit_d_test;
  gi.organic_stop_no_direction = r.stop_no_direction;
  gi.organic_stop_step_budget = r.stop_step_budget;
  gi.organic_seeds_offered = r.seeds_offered;
  gi.organic_seeds_outside_region = r.seeds_outside_region;
  gi.organic_seeds_too_close = r.seeds_too_close;
  gi.organic_seeds_traced = r.seeds_traced;
  gi.organic_connectors = static_cast<long long>(r.connectors);
  gi.organic_curves_under_two_connections =
      static_cast<long long>(r.curves_with_fewer_than_two_connections);
  gi.organic_curves_no_connection =
      static_cast<long long>(r.curves_with_no_connection);
  gi.organic_connected_components = static_cast<long long>(r.connected_components);
  gi.organic_largest_component_fraction = r.largest_component_fraction;
  gi.organic_connector_median_length_mm = r.connector_median_length_mm;
  gi.organic_connector_max_cross_deviation_deg =
      r.max_connector_cross_deviation_deg;
  gi.organic_connector_mean_cross_deviation_deg =
      r.mean_connector_cross_deviation_deg;
  gi.organic_connectors_cross_measured =
      static_cast<long long>(r.connectors_cross_measured);
  gi.organic_connectors_below_resolution =
      static_cast<long long>(r.connectors_shorter_than_strut);
  gi.organic_overhang_clamp_armed = r.overhang_clamp_armed;
  gi.organic_overhang_angle_deg = r.overhang_angle_deg_used;
  gi.organic_clamped_step_fraction = r.clamped_step_fraction;
  gi.organic_curves_touched_fraction = r.curves_touched_fraction;
  gi.organic_segments_outside_45_fraction = r.segments_outside_45_fraction;
  gi.organic_curve_segments_outside_45_fraction =
      r.curve_segments_outside_45_fraction;
  gi.organic_connectors_outside_45_fraction = r.connectors_outside_45_fraction;
  gi.organic_requested_spacing_min_mm = r.requested_spacing_min_mm;
  gi.organic_requested_spacing_max_mm = r.requested_spacing_max_mm;
  gi.organic_achieved_spacing_min_mm = r.achieved_spacing_min_mm;
  gi.organic_achieved_spacing_max_mm = r.achieved_spacing_max_mm;
  gi.organic_achieved_spacing_median_mm = r.achieved_spacing_median_mm;
  gi.organic_spacing_print_floor_mm = r.spacing_print_floor_mm;
  gi.organic_spacing_resolution_floor_mm = r.spacing_resolution_floor_mm;
  gi.organic_spacing_raised_for_print_voxels =
      static_cast<long long>(r.spacing_raised_for_print_voxels);
  gi.organic_spacing_raised_for_resolution_voxels =
      static_cast<long long>(r.spacing_raised_for_resolution_voxels);
  gi.organic_min_curves_per_member = r.min_curves_per_member;
  gi.organic_median_curves_per_member = r.median_curves_per_member;
  gi.organic_curves_per_member_floor = r.curves_per_member_floor;
  gi.organic_below_curves_per_member_floor_voxels =
      static_cast<long long>(r.below_curves_per_member_floor_voxels);
  gi.organic_curves_per_member_measured = r.curves_per_member_measured;
  gi.organic_latticed_voxels = static_cast<long long>(r.latticed_voxels);
  gi.organic_rho_min = r.rho_min_emitted;
  gi.organic_rho_max = r.rho_max_emitted;
  gi.organic_rho_median = r.rho_median_emitted;
  gi.organic_rho_clamped_lo_voxels =
      static_cast<long long>(r.rho_clamped_lo_voxels);
  gi.organic_rho_clamped_hi_voxels =
      static_cast<long long>(r.rho_clamped_hi_voxels);
  gi.organic_emitted_volume_mm3 = r.emitted_volume_mm3;
  gi.organic_tensor_out_of_regime = r.tensor_out_of_regime;
}

// ★ ORGANIC IS AESTHETIC-ONLY, AND THIS IS THE REFUSAL (§3c).
//
// A traced lattice is ANISOTROPIC BY CONSTRUCTION — aligning struts with the principal
// directions is the entire mechanism, and it is where Daynes' +101 % stiffness comes
// from. The certification library carries exactly ONE CUBIC tensor per topology,
// measured on the octet cell as a function of relative density alone (lattice.hpp).
// Nothing in this codebase has measured a tensor for traced geometry, so there is
// nothing for a STRUCTURAL density — one that means "this region is at N % of what the
// material can take" — to be certified against.
//
// §3(c) says organic "may be offered in structural intent only if you can state what it
// certifies against. If you cannot, restrict it to aesthetic intent and SAY SO." It
// cannot be stated, so this refuses.
//
// ★ IT REQUIRES THE INTENT TO BE STATED **EXPLICITLY**, and that is deliberate rather
// than fussy. The DEFAULT intent is not the same on both paths that reach the organic
// step: `analyze` applies the lattice-only job's aesthetic default (amendment §1d),
// while `lattice_one_variant` is shared with the TO+lattice path and therefore leaves
// `GradingLawParams::intent` at its Structural default so that path stays untouched. A
// refusal keyed on the RESOLVED intent would therefore mean different things on the two
// paths, and organic would be silently allowed on one of them. Keyed on the JOB's own
// stated string it means one thing everywhere.
//
// ★ THE CERTIFICATE STILL RUNS EITHER WAY (§3d). Organic changes what the density
// MEANS, never whether it is checked: an aesthetic organic run goes through the same
// analyze_fixed_design as every other lattice, and the receipt carries
// `tensor_out_of_regime` beside the verdict so the reading is never left to inference.
void refuse_organic_structural(LatticeAlgorithm alg, const JobGrading& jg) {
  if (alg != LatticeAlgorithm::Organic) return;
  if (jg.intent == "aesthetic") return;
  throw JobError(
      "organic requires \"intent\": \"aesthetic\", stated explicitly (this job "
      "says " +
      (jg.intent.empty() ? std::string("nothing") : ("\"" + jg.intent + "\"")) +
      "). The organic algorithm traces struts ALONG the principal stress directions, "
      "so the lattice it builds is anisotropic by construction — and the certification "
      "library carries exactly one CUBIC tensor per topology, measured on the octet "
      "cell as a function of relative density alone. Nothing here has measured a "
      "tensor for traced geometry, so a structural density (one that means \"this "
      "region is at N % of what the material can take\") would be certified against a "
      "material this lattice is not. The certificate still runs under aesthetic "
      "intent, and the receipt reports the lattice as out of regime for the "
      "homogenised tensor.");
}

// Resolve the job's algorithm; an ABSENT key is "doubled", which is what keeps every
// existing job byte-identical (§4d). An unknown one is refused, never defaulted.
LatticeAlgorithm resolve_lattice_algorithm(const JobGrading& jg) {
  if (jg.algorithm.empty()) return LatticeAlgorithm::Doubled;
  LatticeAlgorithm a = LatticeAlgorithm::Doubled;
  if (!lattice_algorithm_from_name(jg.algorithm.c_str(), a))
    throw JobError("run_job: unknown grading algorithm \"" + jg.algorithm + "\"");
  return a;
}

// `part_grid` is the ORIGINAL imported part's grid and `domain` is the domain the
// run SOLVED on (resolve_design_domain). Without a design box they are the same
// grid and domain.bcs are the caller's BCs verbatim, so every existing caller is
// byte-identical; with one, domain.grid is the EXPANDED grid, domain.bcs are the
// remapped BCs, and part_grid is what "outside the original part" means.
LatticeVariantOutcome lattice_one_variant(
    const MinimizePlasticVariant& v, const JobDescription& job,
    const VoxelGrid& part_grid, const SolvedDesignDomain& domain,
    const MinimizePlasticOptions& options, const Material& material,
    const std::vector<ClearanceGeometry>& lattice_kos,
    const LatticeRoleRegions& lattice_roles, const std::string& out_dir) {
  // FIRST STATEMENT IN THE BODY, so every solve below is covered and the previous
  // enable states are restored however this function returns (including by throw).
  const ScopedLadderSolverIsolation solver_isolation;
  const VoxelGrid& solved_grid = domain.grid;
  const std::vector<DirichletBC>& bcs = domain.bcs;
  LatticeVariantOutcome R;
  const std::vector<double>& dens = v.optimization.physical_density;
  // THE PRINTED-SET THRESHOLD (task multiscale-lattice-to). 0.5 on a classic run
  // — byte-for-byte the pre-multiscale path — and below the certified band's floor
  // on a multiscale one, where an in-band voxel at 0.30 is real lattice material
  // and thresholding it away would delete what the optimizer placed and the gate
  // certified. Read ONCE here so the candidate set, the boundary base, the
  // certification mask, the grading law and the exported geometry all describe the
  // SAME shape (bar B7's principle, extended to the threshold itself).
  const double printed_iso = run_printed_iso(options);
  R.design_fingerprint = design_fingerprint(dens);
  const bool graded = job.grading.present;
  R.graded = graded;
  // ★ THE ALGORITHM (task 2026-08-21-organic-lattice, §4). Resolved FIRST, so an
  // organic + structural job is refused before it spends a solve on a density it is
  // not allowed to certify. An absent key is "doubled" — §4(d)'s byte-identity.
  R.algorithm = resolve_lattice_algorithm(job.grading);
  refuse_organic_structural(R.algorithm, job.grading);
  const bool roles_present = !job.lattice.regions.empty();

  // ── Stage 4: the grading law runs FIRST, on THIS variant's own final
  // certification-recovery von Mises field (H4a — the run's own field, fresh:
  // v.von_mises_field is produced by the recovery solve on the CONVERGED
  // design of this rung, never an earlier iteration or another run). Its
  // candidate set is the role-aware membership — the SAME membership tests the
  // shared boundary predicate exposes, evaluated on a boundary view carrying
  // only the membership primitives (the cell size, which the law itself
  // chooses, plays no part in membership).
  GradedField& gf = R.gf;
  double cell = job.lattice.cell_mm;
  // Which DECLARED include region owns each candidate voxel — built inside the graded
  // block below and kept here because STEPPED derives one cell PER REGION and so needs
  // the same membership the law used, not a second reconstruction of it.
  std::vector<int> region_ids_for_stepped;
  if (graded) {
    LatticeBoundary members;
    for (const ClearanceGeometry& g : lattice_kos)
      members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
    for (const ClearanceGeometry& g : lattice_roles.includes)
      members.add_include_region(g);
    for (const ClearanceGeometry& g : lattice_roles.excludes)
      members.add_exclude_region(g);
    std::vector<char> cand(solved_grid.voxel_count(), 0);
    std::vector<int> region_ids(solved_grid.voxel_count(), 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!(dens[e] >= printed_iso)) continue;
          const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                       solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                       solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
          if (members.in_keep_out(c, 0.0)) continue;
          if (members.in_exclude_region(c, 0.0)) continue;
          if (members.has_include_regions() &&
              !members.in_include_region(c, 0.0))
            continue;
          // MULTISCALE: a voxel the OPTIMIZER decided should be SOLID is not a
          // lattice candidate. Without this the band clamp would pull its
          // density down to the ceiling and lattice it — removing material the
          // design deliberately kept, which is the loop/export disagreement this
          // task exists to end, running in the opposite direction. Measured on
          // the maintainer's part before the fix: 1,110 of 1,124 "latticed"
          // voxels (98.8 %) were voxels the projection had made solid. They
          // belong to the SOLID companion, and the counts below now say so.
          if (options.multiscale_lattice &&
              dens[e] > lattice_rho_max(options.multiscale_topology))
            continue;
          cand[e] = 1;
          // WHICH declared include region this voxel belongs to (task per-region
          // retention). 1-based, in the job's own declaration order, so a receipt
          // row maps back to the region the user selected; FIRST match wins, which
          // is the same precedence `in_include_region` applies when it short-
          // circuits. 0 means "no include regions declared" — the whole printed set
          // is one anonymous group, which is the union reading exactly.
          for (std::size_t ri = 0; ri < lattice_roles.includes.size(); ++ri)
            if (point_in_clearance_region(lattice_roles.includes[ri], c, 0.0)) {
              region_ids[e] = static_cast<int>(ri) + 1;
              break;
            }
        }
    GradingLawParams gp;
    gp.topology = LatticeTopology::Octet;  // job schema restricts to octet
    gp.target_cell_size_mm = job.grading.cell_mm;
    gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gp.demand_exponent = job.grading.demand_exponent;
    // Cell-size mode (handoff 2026-08-01-lattice-cell-size-sweep). An absent
    // "cell_mode" parses as "fixed", which is the pre-sweep path exactly. Resolved
    // through the ONE place `auto` can mean `fit` (bar S4).
    if (!resolve_cell_mode(job.grading.cell_mode, gp.cell_mode))
      throw JobError("run_job: unknown grading cell_mode \"" +
                     job.grading.cell_mode + "\"");
    // FIT — the per-region derivation, resolved into the per-voxel field the law
    // consumes (task 2026-08-05-lattice-cell-fit-mode, S1). Built ONLY in fit mode,
    // so every other mode's call is byte-identical.
    std::vector<FitRegionCell> fit_cells;
    std::vector<double> fit_field;
    std::vector<double> rho_field;
    if (gp.cell_mode == CellSizeMode::Fit) {
      fit_cells = fit_region_cells(job, gp.topology,
                                   job.grading.min_extrudable_width_mm,
                                   &lattice_roles);
      refuse_infeasible_region_lattice(job, fit_cells,
                                       job.grading.min_extrudable_width_mm);
      refuse_unprintable_stated_density(job, fit_cells, gp.topology,
                                        job.grading.min_extrudable_width_mm);
      if (fit_cells.size() != lattice_roles.includes.size())
        throw JobError(
            "run_job: fit derivation and the resolved include regions disagree on "
            "how many regions this job has — refusing rather than grading a voxel "
            "at another region's cell");
      fit_field = fit_cell_field(solved_grid, lattice_roles.includes, fit_cells);
      gp.fit_cell_size_mm = &fit_field;
      // ★ The stated densities ride the SAME membership test as the cells above.
      rho_field = region_density_field(solved_grid, lattice_roles.includes, fit_cells);
      gp.region_relative_density = &rho_field;
    }
    gp.min_cell_size_mm = job.grading.cell_min_mm;
    gp.max_cell_size_mm = job.grading.cell_max_mm;
    // MULTISCALE (task multiscale-lattice-to): the optimizer already chose this
    // variant's relative density per voxel, and PAID a compliance objective
    // evaluated at the measured tensor of that density (it is also the density the
    // certification solve ran on, after the feasible-set projection). Re-deriving
    // rho from the stress field here would print a DIFFERENT material distribution
    // than the one that was optimized and certified — the same loop/export
    // disagreement the two-step pipeline's failure was made of. So the law is
    // handed the design's own density and grades to THAT. The band clamp, the
    // cells-per-member floor, the L4 solid fallback and the cell plan are the same
    // code on the same terms; only the source of rho changes.
    if (options.multiscale_lattice) gp.prescribed_relative_density = &dens;
    // SUB-FLOOR RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions).
    // Absent => false => this call is bit-identical to the pre-task one. The demand
    // handed in below is the variant's OWN von Mises field, which is what makes the
    // region stress fraction a MEASUREMENT rather than an assertion.
    gp.retain_subfloor_in_unloaded_regions =
        job.grading.retain_subfloor_in_unloaded_regions;
    gp.subfloor_stress_fraction_max = job.grading.subfloor_stress_fraction;
    // ★ PER-REGION EVALUATION — BUILT, TESTED, AND DISARMED. IT DID NOT PASS ITS BAR.
    //
    // Handing the ids in makes the predicate answer once per DECLARED region instead
    // of once for their union, which is what the maintainer's job wants: his quiet
    // back wall stops being vetoed by a bolt hole sharing the candidate set. The
    // implementation is complete and unit-tested (test_grading 13j/13k) and the
    // aggregate exposure cap that must accompany it is implemented too.
    //
    // IT IS NOT WIRED ON, because the measurement said no. Pre-registered in
    // evidence/…/r0_preregistration.md BEFORE any of it was written: an aggregate
    // exposure cap of 3.0 % of the printed set, and a certified-margin bound of
    // 0.10 %. Measured afterwards (r2_additivity.txt), those two numbers are
    // MUTUALLY INCONSISTENT on a real part — a single region at 2.889 % exposure,
    // INSIDE the cap, moved the composite margin +0.1801 %, which is 1.8x the bound.
    // At 31 % exposure it moved +0.5479 %.
    //
    // The rule for that situation was stated in advance and is not negotiable after
    // the fact: report the number, do not adjust the threshold until it fits. So the
    // widening stays off and the shipped predicate remains the UNION reading — which
    // is the conservative one, refuses more than it admits, and is what every bar in
    // this task was measured against.
    //
    // WHAT WOULD UNBLOCK IT: an exposure cap derived from the margin evidence rather
    // than from a multiple of one verified case. The one configuration with a full
    // verified chain sits at 0.930 % exposure and +0.0853 % margin; 2.889 % gives
    // +0.1801 %. A cap near 1 % is what the evidence currently supports, and that is
    // a judgement about how much of the feature to give up — the maintainer's call,
    // not something to quietly pick here.
    //
    // WHAT CHANGED (task 2026-08-05-lattice-cell-size-adaptation, Stage B). The
    // measurement above still stands and has NOT been re-run, so the widening is
    // still off by default and every shipped retention run is byte-identical. What
    // was wrong was not the verdict but the REACHABILITY: the ids were built,
    // populated and then dropped on the floor by a `(void)`, so a maintainer who
    // read the exposure and the margin in his own receipt and decided he wanted it
    // had no way to ask for it. `grading.subfloor_per_region` is that way. It is
    // gated on retention being armed (job.cpp refuses it otherwise), it is off
    // unless asked for, and the receipt reports the aggregate exposure the cap
    // bounds so the decision is made against numbers rather than in the abstract.
    //
    // The ids are still built unconditionally so the path stays compiled and
    // exercised on every graded run, which is what the `(void)` was preserving.
    if (job.grading.subfloor_per_region) gp.region_ids = &region_ids;
    region_ids_for_stepped = region_ids;
    gp.subfloor_aggregate_cap_fraction = job.grading.subfloor_aggregate_cap;
    gf = grade_lattice(solved_grid, dens, v.von_mises_field, &cand, gp,
                       printed_iso);

    // ── STAGE E: THE PER-REGION REPORT (task 2026-08-05-lattice-cell-size-
    // adaptation). Everything below is READ-ONLY: it consumes `cand`, `region_ids`,
    // the law's own posture and the variant's own von Mises field, and writes only
    // into the receipt. No mask, cell, density or verdict depends on it, which is
    // why arming it cannot move a gate result — and why it is safe to compute after
    // the law has already decided.
    //
    // It exists because the pipeline could always say "this region stays solid" and
    // could never say AT WHAT CELL AND DENSITY it would not have to. That gap is how
    // a conditional figure — N* x the printability floor at the band's LIGHTEST
    // density, 23.0131 mm at a 0.42 mm nozzle — reached the maintainer as an
    // unconditional requirement.
    if (job.grading.report_region_cells) {
      // The SAME thickness measure the law reads, at the law's own cap, so a number
      // in this report and a decision inside the law can never disagree about how
      // thick a member is.
      const std::vector<double> tau = local_member_thickness_mm(
          solved_grid, dens, printed_iso, gp.thickness_cap_voxels);
      const std::vector<double>& vm = v.von_mises_field;

      // The PART's peak demand — over every printed voxel, region or not. This is
      // the denominator the retention predicate uses, and it is recomputed here
      // rather than read off the law so the report stands on its own.
      double part_peak = 0.0;
      long long part_printed = 0;
      for (std::size_t e = 0; e < solved_grid.voxel_count(); ++e)
        if (dens[e] >= printed_iso) {
          ++part_printed;
          if (e < vm.size() && vm[e] > part_peak) part_peak = vm[e];
        }

      // WHICH region ids to report. With include regions declared, one row per
      // DECLARED region in the user's own order — including any that ended up with
      // no candidates at all, because "your region caught nothing" is an answer a
      // user needs and an absent row is not. With none declared, one anonymous row
      // (id 0) for the whole candidate set, which is the union reading named.
      std::vector<int> ids_to_report;
      if (!lattice_roles.includes.empty())
        for (std::size_t ri = 0; ri < lattice_roles.includes.size(); ++ri)
          ids_to_report.push_back(static_cast<int>(ri) + 1);
      else
        ids_to_report.push_back(0);

      const double w_min = job.grading.min_extrudable_width_mm;
      const double n_star = lattice_cells_per_member_min(LatticeTopology::Octet);
      const double phi_hi = octet_strut_diameter_mm(
          lattice_rho_max(LatticeTopology::Octet), 1.0);

      for (int want : ids_to_report) {
        LatticeGradedReceipt::RegionCellReport rc;
        rc.region_id = want;
        double tmin = std::numeric_limits<double>::infinity();
        double tmax = 0.0;
        double peak = 0.0;
        for (std::size_t e = 0; e < solved_grid.voxel_count(); ++e) {
          if (!cand[e] || region_ids[e] != want) continue;
          ++rc.candidate_voxels;
          if (!gf.posture.mask.empty() && gf.posture.mask[e])
            ++rc.latticed_voxels;
          else
            ++rc.solid_voxels;
          if (tau[e] < tmin) tmin = tau[e];
          if (tau[e] > tmax) tmax = tau[e];
          if (e < vm.size() && vm[e] > peak) peak = vm[e];
        }
        if (rc.candidate_voxels == 0) {
          // No candidates carried this id. Report the row with its counts at zero
          // rather than dropping it — see the note above on absent rows.
          rc.verdict = "no_candidates";
          R.grad_rcpt.region_cells.push_back(std::move(rc));
          continue;
        }
        rc.min_member_width_mm = tmin;
        rc.max_member_width_mm = tmax;
        // 0 when the part carries no demand at all — the same convention the law
        // uses, and the reason retention disarms itself in that case.
        rc.stress_fraction = part_peak > 0.0 ? peak / part_peak : 0.0;
        rc.at_thinnest =
            lattice_derive_cell_for_member(LatticeTopology::Octet, tmin, w_min);
        rc.at_thickest =
            lattice_derive_cell_for_member(LatticeTopology::Octet, tmax, w_min);

        // ── THE VERDICT, resolved from measurements only, in the order §2 states.
        // A region carrying load is kept solid by the law regardless of geometry,
        // so that is tested first; then whether the geometry admits a pair at all;
        // then whether what was latticed is inside the certified regime.
        const double ceiling =
            job.grading.subfloor_stress_fraction > 0.0
                ? job.grading.subfloor_stress_fraction
                : lattice_subfloor_retention_stress_fraction();
        if (rc.latticed_voxels == 0 && !rc.at_thinnest.feasible) {
          rc.verdict = "no_pair";
          // The OTHER lever: the largest bead this member could still homogenize
          // around. cell <= W/N* and strut = cell x phi(rho_max), so any nozzle at
          // or under (W/N*) x phi(rho_max) makes the pair exist.
          if (std::isfinite(tmin))
            rc.nozzle_needed_mm = (tmin / n_star) * phi_hi;
        } else if (rc.latticed_voxels == 0) {
          // Geometry admits a pair, so what kept it solid was not thickness. On
          // this path that is the load-carrying fallback.
          rc.verdict = "solid_load";
        } else if (gf.subfloor_retained_voxels > 0 &&
                   rc.stress_fraction <= ceiling) {
          rc.verdict = "out_of_regime";
          rc.exposure_fraction = gf.subfloor_retained_fraction_of_part;
        } else {
          rc.verdict = "certified";
        }
        R.grad_rcpt.region_cells.push_back(std::move(rc));
      }
      (void)part_printed;
    }
    // ── NO SILENT DEGENERATE OUTPUT (task
    // 2026-08-04-variant-volume-fraction-mismatch, bar B3 / L3).
    //
    // `region_ungradeable` — candidates existed and the law could grade NONE of
    // them — was computed, carried through five receipts and observability, and
    // ACTED ON NOWHERE. What came out the far end was a "lattice" with zero
    // latticed cells: rho_min_used 0, rho_max_used 0, strut radius 0.00 mm, and a
    // strut-strength margin computed on no material at all — reported to the user
    // as a successful build. A lattice with no struts in it is not a lattice, and
    // this is where that stops.
    //
    // NOTHING IS EMITTED on this path — no mesh, no receipt, no aggregate
    // contribution. A silent fall-back to the solid part under a file name that
    // says "lattice" would be the same dishonesty one layer down. The reason
    // carries the predicate, the per-reason counts and the two measured widths,
    // because the whole remedy is the relation between them.
    if (gf.region_ungradeable) {
      R.ungradeable = true;
      R.ungradeable_reason =
          "the grading law could lattice NONE of this variant's " +
          std::to_string(gf.region_voxels) +
          " candidate voxels, so there is no lattice to emit — refusing rather "
          "than writing a file with zero struts in it and calling it a lattice. "
          "Reasons: member_too_thin_for_cell=" +
          std::to_string(gf.fallback_member_too_thin) +
          ", strut_unprintable_at_every_cell=" +
          std::to_string(gf.fallback_strut_unprintable) +
          ", irrecoverable_by_any_cell_size=" +
          std::to_string(gf.fallback_irrecoverable_by_cell) +
          ". The widest member the law rejected is " +
          json_num(gf.fallback_max_member_width_mm) +
          " mm; at this cell size a member must be at least " +
          json_num(gf.cells_per_member_floor * gf.cell_size_mm) +
          " mm across to hold " + json_num(gf.cells_per_member_floor) +
          " cells. A smaller cell needs a finer declared extrusion width "
          "(min_extrudable_width_mm " +
          json_num(gp.min_extrudable_width_mm) +
          " mm sets the printability floor at " +
          json_num(gf.printability_floor_mm) +
          " mm) — run the pre-flight forecast for the evaluated remedies.";
      R.gf = gf;
      return R;
    }
    cell = gf.cell_size_mm;
    // The law's cell. In Fixed/Auto this is THE cell; in Swept it is the COARSEST
    // level the plan used, which is what the boundary window, the cell-overlap
    // proof and the receipt's single scalar all want (the conservative end).
  }
  R.cell_mm = cell;

  // ── THE shared boundary for this variant: THE EXPORTED SHELL as the base,
  // the resolved clearance keep-outs subtracted, the role regions carried as
  // activation/mask terms. Geometry (a) and certification (b) below both
  // consume this ONE object (bar B7 / H1b).
  //
  // ★ THE BASE IS `v.v3.mesh` — the surface `export_latticed_variant` pushes
  // into the same file — and not the voxel-cube union it used to be (task
  // 2026-08-08-strut-clip-matches-shell). B7 said the certified region and the
  // exported region must be one region; this extends it from the REGION to the
  // SURFACE, because the two descriptions of the same solid set do not agree at
  // convex edges and the file carried both.
  const LatticeBoundary boundary =
      lattice_boundary_for(solved_grid, dens, cell, lattice_kos, lattice_roles,
                           printed_iso, &v.v3.mesh);

  // ── THE certification mask — shared by the export (companion + graded cell
  // activation) and the posture. On a graded run it is intersected with the
  // law's own mask (voxels the law kept solid drop out; law-masked voxels the
  // shared predicate's cell-overlap proof rejects are counted, not hidden).
  std::vector<char> mask = lattice_certification_mask(
      boundary, solved_grid, dens, printed_iso, solved_grid.origin, cell);
  long long dropped_by_overlap = 0;
  if (graded) {
    for (std::size_t e = 0; e < mask.size(); ++e) {
      if (mask[e] && !gf.posture.mask[e]) {
        mask[e] = 0;  // the law left it solid (too-thin fallback / not a candidate)
      } else if (!mask[e] && gf.posture.mask[e]) {
        ++dropped_by_overlap;
      }
    }
  }

  // ── ★ ORGANIC (task 2026-08-21-organic-lattice) ────────────────────────────
  // The grading law above chose the DENSITY and the shared boundary narrowed the
  // MASK; this replaces the lattice GEOMETRY with curves traced along the principal
  // stress directions, and replaces the posture's per-voxel density with the one
  // MEASURED from what was actually traced.
  //
  // ★ THE DENSITY IS STILL THE GRADING LAW'S, WHICH IS THE POINT. Daynes' +101 %
  // is measured against a uniform-cell core OF THE SAME DENSITY, so taking the
  // target density from the shared law is what makes the three-way comparison that
  // same comparison rather than three unrelated parts.
  //
  // ★ EVERY CONSUMER STILL READS A PER-VOXEL DENSITY (§4a). Nothing below this point
  // branches on the algorithm: the certification posture, the solid companion, the
  // min-feature pass, the boundary clip, the void check and the exporters all take
  // `gf.posture` exactly as they did, which is what makes the selector cheap.
  OrganicOutcome organic;
  if (graded && R.algorithm == LatticeAlgorithm::Organic) {
    organic = run_organic_step(solved_grid, dens, v.stress_tensor_field, mask,
                               gf.posture.relative_density, gf.band_rho_min,
                               gf.band_rho_max, job.grading, v.applied_build_dir,
                               printed_iso, 32);
    if (!organic.ran || organic.lat.report.latticed_voxels == 0) {
      // Same posture as the law's own L4 refusal: no object was produced, nothing
      // was written, and the caller decides whether that kills the run or skips a
      // rung. Never a file with no struts in it reported as a successful build.
      R.ungradeable = true;
      R.ungradeable_reason =
          "the organic tracer placed no material: " +
          std::to_string(organic.lat.report.candidate_voxels) +
          " candidate voxels, " +
          std::to_string(organic.lat.report.curves_traced) +
          " curves traced and " +
          std::to_string(organic.lat.report.curves_kept) +
          " kept after thinning. The usual cause is a spacing field the grid cannot "
          "resolve (separation floor " +
          json_num(organic.lat.report.spacing_resolution_floor_mm) +
          " mm against a requested " +
          json_num(organic.lat.report.requested_spacing_min_mm) + " mm).";
      R.gf = gf;
      return R;
    }
    R.organic_ran = true;
    R.organic = organic.lat.report;
    // The posture the certification consumes is now the TRACED one.
    gf.posture.mask = organic.lat.mask;
    gf.posture.relative_density = organic.lat.relative_density;
    // ★ `cell_size_field` IS LEFT EMPTY ON PURPOSE (§3a). An organic lattice has no
    // cells, and filling this with the SEPARATION would silently re-point the
    // certification's cells-per-member guard at the curve-crossing count — the exact
    // overloading §3(a) forbids. The scalar below is a PROVENANCE record (see
    // LatticePosture: "not used in the math"), and the curve-crossing count is
    // reported under its own name in the receipt.
    gf.posture.cell_size_field.clear();
    gf.posture.cell_size_mm = organic.lat.report.achieved_spacing_median_mm;
    cell = gf.posture.cell_size_mm;
    R.cell_mm = cell;
    mask = organic.lat.mask;
    // The law's own aggregate fields are re-pointed at what was TRACED, so the
    // receipt never reports the doubled lattice's counts beside organic geometry.
    gf.latticed_voxels = organic.lat.report.latticed_voxels;
    gf.rho_min_used = organic.lat.report.rho_min_emitted;
    gf.rho_max_used = organic.lat.report.rho_max_emitted;
  }

  // ── ★ STEPPED (task 2026-08-21-organic-lattice, §4) ────────────────────────
  // One cell per DECLARED region, derived from that region's own FEA-driven density
  // and its own member width, taken VERBATIM. The per-voxel cell field it produces is
  // a real cell — stepped HAS cells — so it goes into the posture and the
  // certification's cells-per-member guard reads it correctly, unlike organic where
  // that field is deliberately left empty (§3a).
  std::vector<LatticeSteppedPass> stepped_passes;
  if (graded && R.algorithm == LatticeAlgorithm::Stepped) {
    R.stepped = run_stepped_step(solved_grid, dens, mask,
                                 gf.posture.relative_density, region_ids_for_stepped,
                                 job.grading, printed_iso, 32);
    if (!R.stepped.ran || R.stepped.cells.empty()) {
      R.ungradeable = true;
      R.ungradeable_reason =
          "the stepped algorithm derived no region cell: every declared include "
          "region either holds no latticed voxel or has no measurable member width. "
          "Stepped steps BETWEEN declared regions, so a job with none has nothing "
          "for it to do — use \"algorithm\": \"doubled\".";
      R.gf = gf;
      return R;
    }
    R.stepped_ran = true;
    gf.posture.cell_size_field = R.stepped.cell_field;
    cell = R.stepped.max_cell_mm;   // the COARSEST, the conservative single scalar
    gf.posture.cell_size_mm = cell;
    R.cell_mm = cell;
  }

  // The lattice REGION's cell dimensions — pure geometry, derived here (rather
  // than below with the radius field) because the added-material policy has to
  // speak in CELLS, for the reason spelled out immediately after.
  const LatticeRegion Rdims = lattice_region_for(solved_grid, cell, &boundary);
  const int ncx = Rdims.nx, ncy = Rdims.ny, ncz = Rdims.nz;
  const std::size_t ncells = static_cast<std::size_t>(ncx) * ncy * ncz;
  auto cidx = [ncx, ncy](int ci, int cj, int ck) {
    return (static_cast<std::size_t>(ck) * ncy + cj) * ncx + ci;
  };
  auto clampi = [](int val, int hi) { return val < 0 ? 0 : (val > hi ? hi : val); };
  // The owning lattice cell of voxel (i,j,k) — the SAME keying
  // lattice_certification_mask uses (floor over `Rdims.origin`, which IS
  // solved_grid.origin), so "the cell that certifies this voxel" and "the cell
  // that emits it" are the same integer triple by construction.
  auto owner_ijk = [&](int i, int j, int k) {
    const double cx = solved_grid.origin.x + (i + 0.5) * solved_grid.spacing;
    const double cy = solved_grid.origin.y + (j + 0.5) * solved_grid.spacing;
    const double cz = solved_grid.origin.z + (k + 0.5) * solved_grid.spacing;
    return std::array<int, 3>{
        clampi(static_cast<int>(std::floor((cx - Rdims.origin.x) / cell)), ncx - 1),
        clampi(static_cast<int>(std::floor((cy - Rdims.origin.y) / cell)), ncy - 1),
        clampi(static_cast<int>(std::floor((cz - Rdims.origin.z) / cell)), ncz - 1)};
  };
  auto owner_cell = [&](int i, int j, int k) {
    const std::array<int, 3> c = owner_ijk(i, j, k);
    return cidx(c[0], c[1], c[2]);
  };

  // ── ADDED MATERIAL (task 2026-08-03-design-box-recertification). On a design-box
  // run, count this variant's printed voxels inside vs OUTSIDE the imported part's
  // envelope, and apply the declared policy to the ones outside.
  //
  // *** WHY THE POLICY ACTS ON WHOLE CELLS, NOT ON VOXELS. *** A lattice CELL is
  // the atom the generator emits: a cell is either latticed (its struts are
  // written) or it is not. Clearing a cell's added voxels from the certification
  // mask while leaving its part voxels masked would leave the cell latticed —
  // struts written straight through material the receipt calls "kept solid",
  // which is the certified-object-is-not-the-exported-object failure this whole
  // pipeline exists to prevent. So a cell that holds ANY added material is kept
  // solid WHOLE: every voxel it owns leaves the mask, the cell is not latticed,
  // and every one of those voxels is picked up by the solid companion body. That
  // is strictly more conservative than the voxel-wise rule (more solid, never
  // less), which is the direction this policy already leans, and it makes two
  // properties exact rather than approximate — asserted in
  // test_designbox_lattice_recert:
  //   * the cell set the generator lattices EQUALS the cell set the
  //     certification mask implies, cell for cell;
  //   * no voxel receives both a strut and companion solid.
  // The receipt reports BOTH counts: the added material itself, and the total
  // kept solid including the part voxels that share a cell with it.
  //
  // Off the box path `domain.expanded` is false and this whole block is skipped,
  // so the mask, the geometry and the receipt are byte-identical.
  LatticeAddedMaterialReceipt& added_rcpt = R.added_rcpt;
  if (domain.expanded) {
    const std::vector<char> in_part = original_part_voxels(part_grid, domain);
    added_rcpt.present = true;
    // Pass 1 — the counts, and WHICH CELLS hold added material.
    std::vector<char> cell_has_added(ncells, 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!(dens[e] >= printed_iso)) continue;
          ++added_rcpt.printed_voxels;
          if (in_part[e]) {
            ++added_rcpt.inside_part;
            continue;
          }
          ++added_rcpt.outside_part;
          // Recorded BEFORE pass 2 clears anything: a voxel the mask never
          // accepted cannot be "dropped" by the policy, and counting it here is
          // what makes the two terms partition `outside_part` exactly.
          if (!mask[e]) ++added_rcpt.outside_never_masked;
          if (kDesignBoxAddedMaterialKeptSolid) cell_has_added[owner_cell(i, j, k)] = 1;
        }
    // Pass 2 — clear those cells WHOLE.
    if (kDesignBoxAddedMaterialKeptSolid)
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (!mask[e] || !cell_has_added[owner_cell(i, j, k)]) continue;
            mask[e] = 0;
            ++added_rcpt.kept_solid_voxels;
            if (!in_part[e]) ++added_rcpt.outside_kept_solid;
          }
    const double vv =
        solved_grid.spacing * solved_grid.spacing * solved_grid.spacing;
    added_rcpt.outside_volume_mm3 =
        static_cast<double>(added_rcpt.outside_part) * vv;
    added_rcpt.kept_solid_volume_mm3 =
        static_cast<double>(added_rcpt.kept_solid_voxels) * vv;
  }

  // ── ★ THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
  //
  // THE VOID SPACE INSIDE ANY LATTICE MUST CONNECT TO THE EXTERIOR. A lattice is
  // a porous material; a pocket of it with no path to the outside is a pocket
  // whose powder, resin or support can never be emptied.
  //
  // HERE is where it belongs: `mask` is FINAL on this line — the certification
  // mask, intersected with the grading law's own mask on a graded run and with
  // the design box's whole-cell clearing above — and not one triangle has been
  // written yet. So the set this walks is exactly the set the file will carry
  // and the posture will certify (bar B7's principle again), and a refusal
  // happens before any output exists rather than after it.
  //
  // Off by default: `require_lattice_void_reaches_exterior` is false unless the
  // job asks, and then this whole block is skipped and nothing downstream sees a
  // difference.
  if (job.lattice.require_lattice_void_reaches_exterior) {
    // WHICH declared include region each latticed voxel belongs to (1-based, in
    // the job's own declaration order, FIRST match wins — the same precedence
    // `in_include_region` short-circuits with, and the same rule the grading
    // law's own region ids use). This is what lets a refusal name the region the
    // user drew instead of only a bounding box.
    std::vector<int> void_region_id;
    if (!lattice_roles.includes.empty()) {
      void_region_id.assign(solved_grid.voxel_count(), 0);
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (!mask[e]) continue;
            const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                         solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                         solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
            for (std::size_t ri = 0; ri < lattice_roles.includes.size(); ++ri)
              if (point_in_clearance_region(lattice_roles.includes[ri], c, 0.0)) {
                void_region_id[e] = static_cast<int>(ri) + 1;
                break;
              }
          }
    }
    // `cell` is the SAME cell `lattice_certification_mask` was keyed with above
    // — on a SWEPT run that is the plan's COARSEST level, the conservative end.
    // It affects only the CELL counts a refusal reports (the verdict itself is
    // per voxel), and using it keeps "the cell that certifies this voxel" and
    // "the cell this check calls sealed" the same integer triple.
    const auto void_t0 = std::chrono::steady_clock::now();
    R.void_report = lattice_void_escape(
        solved_grid, dens, printed_iso, mask, solved_grid.origin, cell,
        void_region_id.empty() ? nullptr : &void_region_id);
    R.void_check_seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - void_t0)
            .count();
    R.void_check_ran = true;
    if (R.void_report.sealed()) {
      R.void_sealed = true;
      R.void_sealed_reason = lattice_void_refusal(R.void_report);
      // RETURN BEFORE A SINGLE TRIANGLE IS WRITTEN. The refusal is the whole
      // point: a file that a slicer would open containing a cavity nothing can
      // be emptied from must not exist. `gf` IS `R.gf` (a reference, bound at
      // the top of this function), so what the grading law did on the way here
      // travels out with the refusal.
      return R;
    }
  }

  // ── the radius field + cell activation.
  LatticeRadiusField G;
  G.nseg = 8;
  double rho_uniform = 0.0;
  std::vector<double> cell_rho_sum;
  std::vector<long long> cell_rho_cnt;
  double gmean = 0.0;
  // Which cells the generator lattices. NULL means "every cell the boundary
  // cannot prove empty" — the legacy uniform behaviour, byte-identical on every
  // run without a design box. Non-null on a graded run (below) and on a
  // design-box run (further below), where it is DERIVED FROM THE FINAL MASK so
  // the emitted silhouette and the certified mask are the same set.
  std::function<bool(int, int, int)> cell_latticed;
  std::vector<char> uniform_cells;  // backing store for the design-box predicate
  if (graded) {
    cell_rho_sum.assign(ncells, 0.0);
    cell_rho_cnt.assign(ncells, 0);
    double gsum = 0.0;
    long long gcnt = 0;
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!mask[e]) continue;
          const double rho = gf.posture.relative_density[e];
          const double cx =
              solved_grid.origin.x + (i + 0.5) * solved_grid.spacing;
          const double cy =
              solved_grid.origin.y + (j + 0.5) * solved_grid.spacing;
          const double cz =
              solved_grid.origin.z + (k + 0.5) * solved_grid.spacing;
          (void)cx; (void)cy; (void)cz;
          const std::size_t ce = owner_cell(i, j, k);
          cell_rho_sum[ce] += rho;
          ++cell_rho_cnt[ce];
          gsum += rho;
          ++gcnt;
        }
    gmean = gcnt > 0 ? gsum / static_cast<double>(gcnt) : gf.band_rho_min;
    // Graded cell activation: a cell is latticed iff it holds >= 1 masked
    // voxel — the graded silhouette DERIVES from the same mask the posture
    // certifies, so file and certificate cannot disagree on where lattice is.
    cell_latticed = [&cell_rho_cnt, cidx](int ci, int cj, int ck) {
      return cell_rho_cnt[cidx(ci, cj, ck)] > 0;
    };
    // Per-position radius: the owning voxel's graded rho (masked), else the
    // owning cell's mean over its masked voxels (a strut midpoint can sit in
    // a fallback/solid voxel of an active cell), else the global mean —
    // deterministic fixed fallback chain, converted through core's own
    // diameter law.
    const VoxelGrid& sgr = solved_grid;
    const std::vector<char>& mref = mask;
    const std::vector<double>& rref = gf.posture.relative_density;
    G.field = [&sgr, &mref, &rref, &cell_rho_sum, &cell_rho_cnt, cidx, clampi,
               cell, gmean, ncx, ncy, ncz, Rdims](Vec3 p) {
      const int i = clampi(
          static_cast<int>(std::floor((p.x - sgr.origin.x) / sgr.spacing)),
          sgr.nx - 1);
      const int j = clampi(
          static_cast<int>(std::floor((p.y - sgr.origin.y) / sgr.spacing)),
          sgr.ny - 1);
      const int k = clampi(
          static_cast<int>(std::floor((p.z - sgr.origin.z) / sgr.spacing)),
          sgr.nz - 1);
      const std::size_t e = sgr.index(i, j, k);
      double rho;
      if (mref[e]) {
        rho = rref[e];
      } else {
        const int ci = clampi(
            static_cast<int>(std::floor((p.x - Rdims.origin.x) / cell)), ncx - 1);
        const int cj = clampi(
            static_cast<int>(std::floor((p.y - Rdims.origin.y) / cell)), ncy - 1);
        const int ck = clampi(
            static_cast<int>(std::floor((p.z - Rdims.origin.z) / cell)), ncz - 1);
        const std::size_t cc = cidx(ci, cj, ck);
        rho = cell_rho_cnt[cc] > 0
                  ? cell_rho_sum[cc] / static_cast<double>(cell_rho_cnt[cc])
                  : gmean;
      }
      return 0.5 * octet_strut_diameter_mm(rho, cell);
    };
  } else {
    G.uniform_mm = job.lattice.strut_radius_mm;
    // rho the printed geometry (cell + uniform strut radius) implies, on the
    // library basis (the E5 preflight already proved it in-band).
    rho_uniform =
        octet_relative_density(job.lattice.cell_mm, job.lattice.strut_radius_mm);
    // UNIFORM cell activation under a DESIGN BOX (task
    // 2026-08-03-design-box-recertification). The uniform path has always passed a
    // NULL predicate, which means "lattice every cell the boundary cannot prove
    // empty" — and the boundary's voxel base is the whole solved design, added
    // material included. That was correct while the mask WAS the boundary's own
    // silhouette. It stops being correct the moment the added-material policy
    // clears voxels the boundary still considers material: the certificate would
    // say solid and the generator would still write struts there. So under an
    // expanded domain the uniform path derives its cell set FROM THE FINAL MASK,
    // exactly as the graded path above does — a cell is latticed iff it holds at
    // least one masked voxel.
    //
    // Off the box path this stays NULL and the emitted geometry is byte-identical
    // to every pre-task run (bar AI3). It is armed on `domain.expanded` rather
    // than on "did the policy clear anything", so the design-box path has ONE
    // rule whichever way kDesignBoxAddedMaterialKeptSolid is set.
    //
    // ── AND ON THE ROLE PATH TOO (task 2026-08-04-protect-freeze-vs-solidity,
    // bar 3). The sentence above — "it stops being correct the moment [a policy]
    // clears voxels the boundary still considers material" — describes lattice
    // ROLES exactly: an exclude region, or anything outside the include union,
    // clears voxels from the certification mask that the boundary's voxel base
    // still sees as material. The uniform role path was still passing NULL, so
    // the generator emitted every cell `cell_may_overlap` could not PROVE empty
    // — a proof-based, conservative test — while the certification mask uses
    // exact voxel-CENTRE membership. A cell can therefore "may-overlap" an
    // include region while none of its voxel centres are inside it: struts
    // written into material the certificate calls entirely solid.
    //
    // MEASURED, on the l-bracket gate before this line existed: 48 such voxels
    // on the include run and 426 on the exclude run, every one of them in a cell
    // owning NO certified-latticed voxel — i.e. all divergence, no bonding
    // overlap. The receipt's `strut_and_solid_unexplained` is that number and it
    // is 0 with this armed.
    //
    // The certification mask is NOT touched by this: the certified object and
    // every margin it produces are unchanged, and only the exported FILE moves
    // (strictly fewer cells — it stops writing struts the certificate never
    // credited). So this cannot move a verdict, which is what makes it landable
    // under this task's bar 5.
    if (domain.expanded || roles_present) {
      uniform_cells.assign(ncells, 0);
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i)
            if (mask[solved_grid.index(i, j, k)])
              uniform_cells[owner_cell(i, j, k)] = 1;
      cell_latticed = [&uniform_cells, cidx](int ci, int cj, int ck) {
        return uniform_cells[cidx(ci, cj, ck)] != 0;
      };
    }
  }

  // ── role receipt (H1a): counts + the include-over-void no-op accounting.
  LatticeRoleReceipt& role_rcpt = R.role_rcpt;
  if (roles_present) {
    role_rcpt.present = true;
    role_rcpt.include_regions = lattice_roles.includes.size();
    role_rcpt.exclude_regions = lattice_roles.excludes.size();
    if (boundary.has_include_regions()) {
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (dens[e] >= printed_iso) continue;  // material exists — not the no-op case
            const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                         solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                         solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
            if (!boundary.in_include_region(c, 0.0)) continue;
            ++role_rcpt.include_void_voxels;
            // WHICH void this is (item 5). A clearance keep-out is the one that
            // can never be satisfied; the optimizer's own removal can.
            if (boundary.in_keep_out(c, 0.0))
              ++role_rcpt.include_void_by_clearance;
            else
              ++role_rcpt.include_void_by_optimizer;
          }
    }
  }

  // ── FROZEN MATERIAL vs LATTICE (task 2026-08-04-protect-freeze-vs-solidity).
  //
  // The frozen set is read from `effective_design_mask` — THE mask the loop
  // optimised under, not a reconstruction of it — so "frozen" here means exactly
  // what it meant to the optimizer: a density it was not allowed to move. It
  // carries no opinion about lattice, and this block is the measurement that
  // proves it: the certification mask, built from the boundary alone, is free to
  // lattice a frozen voxel (an include region over it) or to keep it solid (an
  // exclude region, or simply being outside the include union).
  //
  // Nothing here CHANGES a decision — every count is read off masks already
  // computed above. That is deliberate: the whole finding of this task is that
  // the two facts were already separate on this path and only the reporting and
  // the copy said otherwise.
  LatticeFrozenReceipt& frozen_rcpt = R.frozen_rcpt;
  const DesignMask frozen_eff =
      effective_design_mask(solved_grid, design_domain_mask(domain, options));
  auto is_frozen = [&frozen_eff, &dens, printed_iso](std::size_t e) {
    return frozen_eff[e] == MaskValue::FrozenSolid && dens[e] >= printed_iso;
  };
  for (int k = 0; k < solved_grid.nz; ++k)
    for (int j = 0; j < solved_grid.ny; ++j)
      for (int i = 0; i < solved_grid.nx; ++i) {
        const std::size_t e = solved_grid.index(i, j, k);
        if (!is_frozen(e)) continue;
        ++frozen_rcpt.frozen_printed;
        if (mask[e]) ++frozen_rcpt.frozen_latticed;
        else ++frozen_rcpt.frozen_kept_solid;
        const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                     solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                     solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
        if (boundary.has_include_regions() && boundary.in_include_region(c, 0.0))
          ++frozen_rcpt.frozen_in_include;
        if (boundary.in_exclude_region(c, 0.0)) {
          ++frozen_rcpt.frozen_in_exclude;
          if (mask[e]) ++frozen_rcpt.frozen_in_exclude_latticed;
        }
      }
  frozen_rcpt.present = frozen_rcpt.frozen_printed > 0;

  // ── SWEPT cell size: one level spec per dyadic level (handoff 2026-08-01-
  //    lattice-cell-size-sweep). Each level carries (a) its own occupancy — the
  //    octree cells assigned to it, keyed off the base cell at the block's min
  //    corner, which is exactly where the aligned octree puts the level — and (b)
  //    its OWN radius field, because the printed diameter is d(rho, cell): the same
  //    relative density at a coarser cell is a proportionally fatter strut, which is
  //    the whole printability payoff. Empty (fewer than two levels) on every
  //    non-swept run, so the export takes the single-cell path unchanged.
  std::vector<LatticeLevelSpec> levels;
  if (graded && gf.cell_plan.max_level > 0 &&
      !gf.posture.cell_size_field.empty()) {
    const CellSizePlan* pl = &gf.cell_plan;
    for (const CellLevelReport& lr : gf.cell_plan.levels) {
      if (lr.cells == 0) continue;
      LatticeLevelSpec sp;
      sp.level = lr.level;
      sp.cell_mm = lr.cell_size_mm;
      const int LV = lr.level;
      sp.latticed = [pl, LV](int ci, int cj, int ck) {
        const int bi = ci << LV, bj = cj << LV, bk = ck << LV;
        if (bi >= pl->nx || bj >= pl->ny || bk >= pl->nz) return false;
        return static_cast<int>(pl->level[pl->index(bi, bj, bk)]) == LV;
      };
      // Same fallback chain as the uniform graded field (owning voxel's graded
      // rho, else the level's own band floor) — evaluated at THIS level's cell.
      const VoxelGrid& sgr = solved_grid;
      const std::vector<char>& mref = mask;
      const std::vector<double>& rref = gf.posture.relative_density;
      const double lcell = lr.cell_size_mm;
      const double rlo = gf.band_rho_min;
      sp.radius.nseg = 8;
      sp.radius.uniform_mm = 0.5 * octet_strut_diameter_mm(rlo, lcell);
      sp.radius.field = [&sgr, &mref, &rref, lcell, rlo](Vec3 p) {
        auto cl = [](int val, int hi) { return val < 0 ? 0 : (val > hi ? hi : val); };
        const int i = cl(static_cast<int>(
            std::floor((p.x - sgr.origin.x) / sgr.spacing)), sgr.nx - 1);
        const int j = cl(static_cast<int>(
            std::floor((p.y - sgr.origin.y) / sgr.spacing)), sgr.ny - 1);
        const int k = cl(static_cast<int>(
            std::floor((p.z - sgr.origin.z) / sgr.spacing)), sgr.nz - 1);
        const std::size_t e = sgr.index(i, j, k);
        return 0.5 * octet_strut_diameter_mm(mref[e] ? rref[e] : rlo, lcell);
      };
      levels.push_back(std::move(sp));
    }
  }

  // ── ★ STEPPED: one generator pass per DISTINCT region cell ─────────────────
  // Built here, beside the dyadic `levels`, because it answers the same question in
  // the opposite way: `levels` snaps every region onto the shared ladder so the passes
  // meet at nodes, and this one does not snap at all so they do not. Each pass gets its
  // own cell grid over the WHOLE part (so cell indices are its own), an occupancy
  // predicate restricted to the regions carrying that cell, and its own radius field —
  // the printed diameter is d(rho, cell), so a region at a coarser cell prints a
  // proportionally fatter strut at the same relative density.
  std::vector<std::vector<char>> stepped_cell_active;  // backing store, per pass
  if (R.stepped_ran) {
    // Distinct cells in ASCENDING order — a fixed emission order (§5a).
    std::vector<double> distinct;
    for (const SteppedRegionCell& rc : R.stepped.cells) distinct.push_back(rc.cell_mm);
    std::sort(distinct.begin(), distinct.end());
    distinct.erase(std::unique(distinct.begin(), distinct.end()), distinct.end());
    stepped_cell_active.resize(distinct.size());
    for (std::size_t pi = 0; pi < distinct.size(); ++pi) {
      const double pcell = distinct[pi];
      LatticeRegion PR = lattice_region_for(solved_grid, pcell, &boundary);
      const int pnx = PR.nx, pny = PR.ny, pnz = PR.nz;
      std::vector<char>& active = stepped_cell_active[pi];
      active.assign(static_cast<std::size_t>(pnx) * pny * pnz, 0);
      // A pass cell is active iff it holds a masked voxel whose region carries THIS
      // pass's cell — derived from the SAME mask the posture certifies, so the file
      // and the certificate cannot disagree about where lattice is (bar B7).
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (!mask[e]) continue;
            if (R.stepped.cell_field[e] != pcell) continue;
            const int ci = static_cast<int>(
                std::floor((solved_grid.origin.x + (i + 0.5) * solved_grid.spacing -
                            PR.origin.x) / pcell));
            const int cj = static_cast<int>(
                std::floor((solved_grid.origin.y + (j + 0.5) * solved_grid.spacing -
                            PR.origin.y) / pcell));
            const int ck = static_cast<int>(
                std::floor((solved_grid.origin.z + (k + 0.5) * solved_grid.spacing -
                            PR.origin.z) / pcell));
            if (ci < 0 || cj < 0 || ck < 0 || ci >= pnx || cj >= pny || ck >= pnz)
              continue;
            active[(static_cast<std::size_t>(ck) * pny + cj) * pnx + ci] = 1;
          }
      const std::vector<char>* ap = &active;
      PR.latticed = [ap, pnx, pny, pnz](int ci, int cj, int ck) {
        if (ci < 0 || cj < 0 || ck < 0 || ci >= pnx || cj >= pny || ck >= pnz)
          return false;
        return (*ap)[(static_cast<std::size_t>(ck) * pny + cj) * pnx + ci] != 0;
      };
      LatticeSteppedPass sp;
      sp.region = PR;
      sp.radius.nseg = 8;
      sp.radius.uniform_mm = 0.5 * octet_strut_diameter_mm(gf.band_rho_min, pcell);
      const VoxelGrid& sgr = solved_grid;
      const std::vector<char>& mref = mask;
      const std::vector<double>& rref = gf.posture.relative_density;
      const double rlo = gf.band_rho_min;
      sp.radius.field = [&sgr, &mref, &rref, pcell, rlo](Vec3 pt) {
        auto cl = [](int val, int hi) { return val < 0 ? 0 : (val > hi ? hi : val); };
        const int i = cl(static_cast<int>(
            std::floor((pt.x - sgr.origin.x) / sgr.spacing)), sgr.nx - 1);
        const int j = cl(static_cast<int>(
            std::floor((pt.y - sgr.origin.y) / sgr.spacing)), sgr.ny - 1);
        const int k = cl(static_cast<int>(
            std::floor((pt.z - sgr.origin.z) / sgr.spacing)), sgr.nz - 1);
        const std::size_t e = sgr.index(i, j, k);
        return 0.5 * octet_strut_diameter_mm(mref[e] ? rref[e] : rlo, pcell);
      };
      stepped_passes.push_back(std::move(sp));
    }
  }

  // (a) geometry — timed alone, so gen_fraction (P6) stays generation-only.
  const double tg0 = wall_seconds();
  R.oc = export_latticed_variant(
      v, out_dir, job.output, job.lattice, solved_grid, boundary, cell, G,
      mask, cell_latticed,
      // The companion body must also be armed when the added-material policy
      // kept voxels solid — otherwise that material would be certified solid but
      // never written, and the file would not be the certified object.
      /*emit_solid_companion=*/graded || roles_present ||
          added_rcpt.kept_solid_voxels > 0,
      levels.empty() ? nullptr : &levels,
      levels.empty() ? 0.0 : gf.cell_plan.base_cell_mm, printed_iso,
      organic.ran ? &organic.lat : nullptr,
      stepped_passes.empty() ? nullptr : &stepped_passes);
  R.gen_seconds = wall_seconds() - tg0;

  // ── ★ THE NO-PROTRUSION INVARIANT, ASSERTED (task 2026-08-08-strut-clip-
  // matches-shell, bar R3). Not eyeballed, not derived from the clip's
  // certificate: measured on the very stream that was written, for EVERY
  // exported lattice, and refused if a single vertex came out beyond the shell
  // in the same file.
  //
  // WHY A REFUSAL. A strut end standing proud of the outer surface is the file
  // disagreeing with itself — the certificate describes the composite inside the
  // shell, and the slicer prints teeth outside it. That is the same
  // certified-object-is-not-the-exported-object class this codebase refuses
  // everywhere else, and it cost the maintainer a set of prints before anyone
  // could name it. The tolerance is the clip refinement's own crossing tolerance
  // (LatticeBoundary::kClipTolMm, 1e-4 mm), so the bar is "zero to the precision
  // the clip is able to resolve" and not a budget anybody may spend.
  //
  // THE ONE EXCEPTION IS DECLARED, NOT DISCOVERED. A freeform skin buys
  // `kLatticeSkinSagBudgetMm` (0.045 mm) of overshoot against the base surface
  // ON PURPOSE — lattice_gen.hpp states why, and keep-outs and planes stay at
  // full erosion regardless. `protrusion_allowance_mm` carries that budget only
  // when that pass actually ran, so an ordinary run is still held to zero, and
  // the receipt reports the allowance beside the measurement so the bar a run
  // was judged against is never left to inference.
  if (R.oc.protrusion_measured &&
      R.oc.max_protrusion_mm > R.oc.protrusion_allowance_mm)
    throw JobError(
        "lattice geometry escaped the exported shell: " +
        std::to_string(R.oc.protruding_vertices) + " of " +
        std::to_string(R.oc.measured_vertices) +
        " lattice vertices lie OUTSIDE the solid shell written into the same "
        "file, the worst by " + json_num(R.oc.max_protrusion_mm) +
        " mm at (" + json_num(R.oc.worst_protrusion_at.x) + ", " +
        json_num(R.oc.worst_protrusion_at.y) + ", " +
        json_num(R.oc.worst_protrusion_at.z) + "), emitted by the " +
        R.oc.worst_protrusion_pass +
        " pass (allowance " + json_num(R.oc.protrusion_allowance_mm) +
        " mm; the clip predicate reads " +
        json_num(boundary.signed_distance(R.oc.worst_protrusion_at)) +
        " mm there).\n  The file would print strut ends standing proud of the outer "
        "surface, and the certificate — which describes the composite INSIDE "
        "the shell — would not describe it. Refusing rather than writing an "
        "object that disagrees with its own receipt.");

  // ── M4: A SKIN MODE THAT PRODUCED NOTHING MUST SAY SO. The full root cause and
  // why the predicate is the MEASURED count rather than a prediction are on
  // export_latticed_variant. In short: the first version tested
  // `boundary.faces().empty()`, which is too narrow — a BOLT clearance makes
  // faces() non-empty while still emitting zero rim, because the dispatch
  // (lattice_gen.cpp:944-961) needs a PLANE and lattice_boundary_for never makes
  // one. Testing what the generator actually wrote makes the blast radius exact by
  // construction: it cannot fire on a run that emitted geometry.
  if (job.lattice.skin != "none" &&
      R.oc.stats.rim_triangles + R.oc.stats.skin_triangles == 0)
    throw JobError(
        "lattice \"skin\": \"" + job.lattice.skin +
        "\" produced NO geometry on this part (rim_triangles 0, skin_triangles "
        "0), so refusing rather than silently exporting an undressed lattice "
        "under a finish the job asked for.\n"
        "  The rim/skin finish rides pairs of ANALYTIC boundary faces, and at "
        "least one of each pair must be a PLANE. This run's lattice boundary is "
        "built from the voxel silhouette plus clearances and lattice roles, none "
        "of which contribute a plane, so there was nothing for the finish to ride "
        "and every rim/skin/anchor count came out 0.\n"
        "  This is a known gap, not a bad job: dressing a voxel silhouette needs "
        "either analytic faces fitted to it or a voxel-native rim law, and "
        "neither exists yet (handoff 2026-08-05-lattice-cell-size-adaptation §7).\n"
        "  Set \"skin\": \"none\" to export the lattice undressed, which is what "
        "this job actually produced.");

  // ── THE AUDIT (design-box runs only, so no existing receipt changes). Measure,
  // against the geometry that was just written, the two things the whole H1b
  // discipline claims: that the cell set the generator EMITTED is the cell set
  // the certification mask implies, and that no voxel got both a strut and
  // companion solid. `emitted_lattice_cells` is the GENERATOR's own count
  // (LatticeGenStats::latticed_cells — cells that passed both the predicate and
  // the boundary-overlap test), not a re-derivation of it.
  //
  // ONE predicate, TWO scopes (task 2026-08-04-protect-freeze-vs-solidity, bar 3).
  // The frozen-material audit asks the SAME two questions over the frozen voxels
  // — reusing these lambdas rather than re-deriving the rules beside them, which
  // is the only way the two audits cannot disagree about what "emitted" means.
  //
  // `cell_emitted` — does the generator lattice this cell? Exactly the generator's
  // own activation chain: the cell predicate (null = every cell) AND the
  // boundary-overlap proof.
  auto cell_emitted = [&](const std::array<int, 3>& c) {
    if (cell_latticed && !cell_latticed(c[0], c[1], c[2])) return false;
    const Vec3 cmin{Rdims.origin.x + c[0] * cell, Rdims.origin.y + c[1] * cell,
                    Rdims.origin.z + c[2] * cell};
    return boundary.cell_may_overlap(cmin, cell);
  };
  // `is_companion_solid` — a voxel is companion solid on exactly the export's own
  // rule: printed, NOT masked, and not inside a clearance keep-out
  // (export_latticed_variant).
  auto is_companion_solid = [&](int i, int j, int k) {
    const std::size_t e = solved_grid.index(i, j, k);
    if (!(dens[e] >= printed_iso) || mask[e]) return false;
    const Vec3 vc{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                  solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                  solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
    return !boundary.in_keep_out(vc, 0.0);
  };
  if (added_rcpt.present) {
    std::vector<char> certified_cells(ncells, 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i)
          if (mask[solved_grid.index(i, j, k)])
            certified_cells[owner_cell(i, j, k)] = 1;
    for (const char c : certified_cells)
      added_rcpt.certified_lattice_cells += (c ? 1 : 0);
    added_rcpt.emitted_lattice_cells = R.oc.stats.latticed_cells;
    // "Inside a strut cell" iff its owning cell is one the generator emitted —
    // the same cell_active test, asked here with the same inputs.
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i)
          if (is_companion_solid(i, j, k) && cell_emitted(owner_ijk(i, j, k)))
            ++added_rcpt.voxels_strut_and_solid;
  }

  // ── THE SAME AUDIT, SCOPED TO FROZEN MATERIAL (bar 3). Lattice-include over
  // frozen material is now a legal, expressible intent, so the guarantee that
  // held for added material has to hold here too and be CHECKABLE:
  //
  //   * every cell that owns a certified-latticed FROZEN voxel is a cell the
  //     generator emitted (`frozen_cells_not_emitted` == 0). Were it not, the
  //     certificate would describe struts through protected material that the
  //     exported file does not contain — the certified-object-is-not-the-
  //     exported-object failure, in the one place a user is least able to see it;
  //   * no frozen voxel receives both a strut and companion solid
  //     (`frozen_voxels_strut_and_solid` == 0) — PR 285's P1 failure mode.
  //
  // Measured against the geometry that was JUST written, like the block above.
  if (frozen_rcpt.present) {
    // Pass 1 — the cells the certificate lattices: over FROZEN voxels (the
    // scoped question) and over ANY voxel (which is what tells a straddling
    // bonding cell apart from a cell writing struts into a wholly-solid region).
    std::vector<char> frozen_cert_cells(ncells, 0), any_cert_cells(ncells, 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!mask[e]) continue;
          any_cert_cells[owner_cell(i, j, k)] = 1;
          if (is_frozen(e)) frozen_cert_cells[owner_cell(i, j, k)] = 1;
        }
    // Pass 2 — the both-ways counts over frozen voxels.
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!is_frozen(e) || !is_companion_solid(i, j, k)) continue;
          const std::array<int, 3> c = owner_ijk(i, j, k);
          if (!cell_emitted(c)) continue;
          ++frozen_rcpt.frozen_voxels_strut_and_solid;
          if (!any_cert_cells[cidx(c[0], c[1], c[2])])
            ++frozen_rcpt.frozen_strut_and_solid_unexplained;
        }
    // Pass 3 — the cell-set equality over frozen voxels.
    for (int ck = 0; ck < ncz; ++ck)
      for (int cj = 0; cj < ncy; ++cj)
        for (int ci = 0; ci < ncx; ++ci) {
          if (!frozen_cert_cells[cidx(ci, cj, ck)]) continue;
          ++frozen_rcpt.frozen_cells_certified;
          if (!cell_emitted({ci, cj, ck})) ++frozen_rcpt.frozen_cells_not_emitted;
        }
  }
  // (b) certification of the composite — the octet tensor on the SAME mask the
  // geometry used. The band is enforced PER VOXEL inside the solve (E5/H4b).
  const LatticeCertContext cx =
      lattice_cert_context(v, part_grid, domain, options, material);
  const LatticePosture post = build_lattice_posture(
      solved_grid, cell, mask, rho_uniform,
      graded ? &gf.posture.relative_density : nullptr);
  R.cc = certify_latticed_variant(
      v, solved_grid, options, material, bcs, cx, post,
      graded ? std::numeric_limits<double>::quiet_NaN() : rho_uniform);

  // ── graded receipt + the clamp counterfactual (H4b): one extra cert solve
  // with every band-clamped voxel kept SOLID — was the clamping decisive?
  LatticeGradedReceipt& grad_rcpt = R.grad_rcpt;
  if (graded) {
    grad_rcpt.present = true;
    grad_rcpt.gf = &gf;
    grad_rcpt.requested_vf = v.requested_volume_fraction;
    grad_rcpt.achieved_vf = v.optimization.volume_fraction;
    grad_rcpt.iterations = v.optimization.iterations;
    grad_rcpt.mask_voxels_dropped_by_cell_overlap = dropped_by_overlap;
    if (gf.clamped_lo_voxels + gf.clamped_hi_voxels > 0) {
      LatticePosture cpost = post;
      for (std::size_t e = 0; e < cpost.mask.size(); ++e)
        if (gf.clamp_flags[e] && cpost.mask[e]) {
          cpost.mask[e] = 0;
          cpost.relative_density[e] = 0.0;
        }
      const FixedDesignAnalysis cf = analyze_variant_with_posture(
          v, solved_grid, options, material, bcs, cx, &cpost);
      grad_rcpt.clamp_counterfactual_ran = true;
      grad_rcpt.counterfactual_accepted = cf.accepted;
      grad_rcpt.clamp_changed_verdict = (cf.accepted != R.cc.lattice.accepted);
    }
  }

  R.receipt_path =
      join_path(out_dir, lattice_base_name(job.output.mesh_prefix,
                                           v.requested_volume_fraction) +
                             ".report.json");
  R.receipt_json = lattice_cert_report_json(
      v, job.lattice, R.cc, R.oc, cell, role_rcpt, grad_rcpt, added_rcpt,
      frozen_rcpt, R.void_check_ran ? &R.void_report : nullptr);
  write_text_file(R.receipt_path, R.receipt_json);
  // `grad_rcpt.gf` points at R.gf, which the caller now owns; the receipt is
  // already rendered, so nothing may follow that pointer after the return. Null
  // it rather than leave a dangling-looking field on a returned value.
  grad_rcpt.gf = nullptr;
  return R;
}

// --- analyze_job helpers (handoff 2026-07-26-constrained-smooth) -------------

Vec3 normalized(const Vec3& v) {
  const double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return Vec3{v.x / n, v.y / n, v.z / n};
}

// Enclosed volume (mm^3) of a closed triangle mesh via the divergence theorem:
// V = |sum over triangles a · (b × c)| / 6. The analysed mesh's TRUE (surface-
// enclosed) mass is this * density — the honest counterpart to the voxel-count
// mass, and the pair the re-analysis discloses.
double mesh_enclosed_volume_mm3(const TriangleMesh& m) {
  double v6 = 0.0;
  for (const auto& tri : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tri[2])];
    v6 += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
          a.z * (b.x * c.y - b.y * c.x);
  }
  return std::fabs(v6) / 6.0;
}

// A finite double as a JSON number, non-finite as JSON null (matching
// job_report_json's convention for unbounded margins).
std::string json_num(double v) {
  if (!std::isfinite(v)) return "null";
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.10g", v);
  return std::string(buf);
}

std::string json_str(const std::string& s) {
  std::string out = "\"";
  for (const char ch : s) {
    if (ch == '"' || ch == '\\') out += '\\';
    out += ch;
  }
  out += '"';
  return out;
}

// The exact freeze predicates for the constrained smoother, resolved ONCE from
// the model's B-rep (handoff 2026-07-26-constrained-smooth-ui). Each named face
// becomes a ClearanceGeometry the smoother tests every mesh vertex against — a
// cylindrical face → a Bolt bore predicate (keep the hole circular), a planar
// face → a Face pad predicate (keep the mounting face flat). These predicates
// survive re-meshing (the smoothed mesh carries NO face ids), which a voxel-tag /
// face-id map does not. `params` is zero-margin for a bore (freeze the wall at the
// true radius) and a shallow slab for a pad. Non-matching faces are skipped.
std::vector<ClearanceGeometry> freeze_regions_from_faces(
    const StepModel& model, const std::vector<int>& face_ids, double spacing) {
  std::vector<ClearanceGeometry> regions;
  for (const int fid : face_ids) {
    if (fid < 0 || fid >= model.face_count) continue;
    const StepFaceInfo& face = model.faces[static_cast<std::size_t>(fid)];
    ClearanceParams p;
    if (face.kind == StepSurfaceKind::Cylinder) {
      p.kind = ClearanceKind::Bolt;  // radius = bore radius, band = through-part span
    } else if (face.kind == StepSurfaceKind::Plane) {
      p.kind = ClearanceKind::Face;
      p.slab_depth_mm = spacing;  // a one-voxel slab; the tol band catches the pad
    } else {
      continue;
    }
    const ClearanceGeometry g = resolve_clearance_from_face(model, fid, p);
    if (g.valid) regions.push_back(g);
  }
  return regions;
}

// Apply the job's optional BUILD-DIRECTION separation onto the options, for BOTH
// modes and BOTH entry points (handoff 2026-08-01-build-direction-separation).
// Called immediately after the mode branch has finished configuring `options`,
// so it overrides whatever that branch implied:
//
//   * "build_direction" absent  -> options.build_direction stays as the mode
//     branch left it (loadcase mode: the declared loads.build_dir; self-weight
//     mode: unset), and resolve_build_direction applies the documented gravity
//     fallback. BYTE-IDENTICAL to the pre-separation run — bar U1.
//   * "build_direction" present -> that vector, verbatim. In loadcase mode this
//     OVERRIDES loads.build_dir for the plate orientation while leaving the
//     service gravity loads.build_dir implied. That override is the whole point:
//     the two questions stop sharing one field.
//
// The scorer arming flag rides along here because it is the same decision — the
// job either engages with build orientation or it does not.
//
// "bake_build_orientation" rides along for the same reason (handoff
// 2026-08-01-bake-build-orientation): it is the third part of one question —
// which way up, who decides, and does the FILE carry the answer. An absent key
// is "auto", which is the enum's default, so this is a no-op for every job that
// does not mention it.
void apply_build_direction_options(MinimizePlasticOptions& options,
                                   const JobDescription& job) {
  if (job.has_build_direction) options.build_direction = job.build_direction;
  options.build_orientation_report = job.build_orientation_report;
  if (job.bake_build_orientation == "always")
    options.bake_build_orientation = BakeBuildOrientation::Always;
  else if (job.bake_build_orientation == "off")
    options.bake_build_orientation = BakeBuildOrientation::Off;
  else
    options.bake_build_orientation = BakeBuildOrientation::Auto;
}

}  // namespace

// Map a job.json "loads" block onto the front-end-neutral ProductionLoadCase the
// core builder (build_production_loadcase) consumes. This is the ONE mapping —
// run_job's optimize path AND analyze_job's re-certification path both call it, so
// a declared load case is resolved IDENTICALLY whether it is optimized or merely
// analyzed (no second schema, per the loadcase-analyze handoff). Geometric anchor/
// load-face selectors are resolved against `model` here (resolve_selectors THROWS
// a JobError naming any selector that matches nothing — the loud "face does not
// exist" failure), and compose with any raw B-rep face ids. Clearance / face-
// protection / design-box / infill / wall metadata are forwarded verbatim.
//
// Declared in job.hpp (no longer file-local) so job_loadcase_copy can assert the
// round trip AT THIS SEAM rather than on the value type.
ProductionLoadCase production_loadcase_from_job(const JobDescription& job,
                                               const StepModel& model) {
  // ★ THE FIELD LEDGER — this copy is EXHAUSTIVE BY CONSTRUCTION.
  //
  // THE DEFECT CLASS, not the defect: a hand-retyped copy block. PR #227 added
  // `lc.wall_line_width_outer_mm` on 2026-07-28 20:52 (commit 84a1350); PR #228's
  // merge-conflict resolution 71 minutes later (commit fc6e95f) hoisted this block
  // into a helper and re-typed five of its six trailing assignments, dropping the
  // sixth. Nothing failed, because a hand-written list cannot notice a field it
  // was never told about — and the next conflict here would drop a different one.
  //
  // So the body below never writes `job.loads.<field>`. It decomposes JobLoadCase
  // by STRUCTURED BINDING, which the language requires to name EVERY direct
  // non-static data member — no more, no fewer. ADD A FIELD TO JobLoadCase AND
  // THIS DECLARATION STOPS COMPILING until someone names it here and, on the line
  // that follows, states what happens to it: copied, resolved, or deliberately
  // not carried. The round-trip test (core/tests/unit/test_job_loadcase_copy.cpp)
  // then locks the VALUES; this locks the COVERAGE, which is the half that was
  // missing.
  const auto& [j_present, j_anchors, j_anchor_face_ids, j_face_regions,
               j_anchor_region_ids, j_groups, j_clearances,
               j_face_protection_face_ids, j_face_protection_depth_mm,
               j_face_protection_depths_mm, j_face_protection_region_ids,
               j_face_protection_region_depths_mm,
               // ★ ORDER IS THE DECLARATION ORDER OF JobLoadCase, NOT a list you
               // may append to. `layer_height_mm` sits between `infill_percent` and
               // `minimize_plastic` in the struct, so it binds THERE. Appending it at
               // the end instead shifted every following name by one — and because
               // each mismatched pair is implicitly convertible (double->bool,
               // bool->int, int->double) it COMPILED and silently carried wrong
               // values. test_job_loadcase_copy caught it; that is what it is for.
               j_build_dir, j_infill_percent, j_layer_height_mm,
               j_minimize_plastic, j_wall_loops,
               j_wall_line_width_mm, j_wall_line_width_outer_mm] = job.loads;
  // NOT CARRIED, on purpose: `present` answers "was a loads block given at all",
  // which is the CALLER's question (every call site gates on job.loads.present
  // before asking for a load case). ProductionLoadCase has no counterpart and
  // should not grow one. Named here so the ledger stays complete.
  (void)j_present;
  // NOT CARRIED, on purpose: `layer_height_mm` is a PRINTER profile value, not a
  // load case. Nothing in build_production_loadcase, the solve or the ladder reads
  // it — the layer height never enters the optimizer (the same reason infill does
  // not, ARCHITECTURE §2). It is read directly from `job.loads` where the grading
  // law compares it against the layer height the lattice it produced actually
  // wants. Named here so the ledger stays complete.
  (void)j_layer_height_mm;

  ProductionLoadCase lc;
  // ★ THE REGION LAYER travels verbatim (task 2026-08-14-face-regions §1): the
  // specs are RESOLVED once inside build_production_loadcase, against the model
  // it voxelizes, so the job never carries a resolved member list that could
  // disagree with the import.
  lc.face_regions = j_face_regions;
  lc.anchor_region_ids = j_anchor_region_ids;
  // Anchors: raw B-rep ids (from the app) and/or geometric selectors compose.
  lc.anchor_face_ids = j_anchor_face_ids;
  for (const int id : resolve_selectors(model, j_anchors, "anchors"))
    lc.anchor_face_ids.push_back(id);
  for (const JobLoadGroup& g : j_groups) {
    ProductionLoadCase::LoadGroup lg;
    lg.face_ids = g.face_ids;
    for (const int id : resolve_selectors(model, g.faces, "loads group faces"))
      lg.face_ids.push_back(id);
    lg.region_ids = g.region_ids;
    lg.force = g.force;
    lc.load_groups.push_back(std::move(lg));
  }
  // Clearances (handoff 100): map each job clearance to a ProductionLoadCase
  // clearance. A distance the job omitted (== 0) defaults to the same spec
  // suggestion the app prefills — for a bolt those depend on the bore radius,
  // read from the imported face geometry, so a hand-authored job need only give
  // face_id + kind.
  for (const JobClearance& jc : j_clearances) {
    ProductionLoadCase::Clearance c;
    c.face_id = jc.face_id;
    c.manual = jc.manual;
    const bool bolt = jc.kind == "bolt";
    // Default suggestions depend on the bore radius: an auto bolt reads it from
    // the imported face geometry; a manual bolt carries its own radius_mm. A
    // hand-authored job need only give face_id/geometry + kind and the same
    // spec-suggestion defaults fill the rest.
    double bore_r = 0.0;
    if (bolt) {
      if (jc.manual)
        bore_r = jc.radius_mm;
      else if (jc.face_id >= 0 && jc.face_id < model.face_count)
        bore_r = model.faces[static_cast<std::size_t>(jc.face_id)]
                     .cylinder_radius_mm;
    }
    c.params = bolt ? topopt::default_bolt_clearance(bore_r)
                    : topopt::default_face_clearance();
    if (jc.concentric_margin_mm > 0.0)
      c.params.concentric_margin_mm = jc.concentric_margin_mm;
    if (jc.axial_clearance_mm > 0.0)
      c.params.axial_clearance_mm = jc.axial_clearance_mm;
    if (jc.slab_depth_mm > 0.0) c.params.slab_depth_mm = jc.slab_depth_mm;
    if (jc.manual) {
      c.manual_geom.kind =
          bolt ? topopt::ClearanceKind::Bolt : topopt::ClearanceKind::Face;
      c.manual_geom.axis_point = jc.axis_point;
      c.manual_geom.axis_dir = jc.axis_dir;
      c.manual_geom.radius_mm = jc.radius_mm;
      c.manual_geom.half_length_mm = jc.half_length_mm;
      c.manual_geom.origin = jc.origin;
      c.manual_geom.normal = jc.normal;
      c.manual_geom.half_u_mm = jc.half_u_mm;
      c.manual_geom.half_w_mm = jc.half_w_mm;
    }
    lc.clearances.push_back(c);
  }
  // Face protections (handoff 124): the raw face ids + the ONE global depth. A
  // depth <= 0 in the job means "use the core default"; leave the
  // ProductionLoadCase field at its default so the builder derives voxels from
  // kFaceProtectionDepthDefaultMm. Empty list => byte-identical.
  lc.face_protection_face_ids = j_face_protection_face_ids;
  if (j_face_protection_depth_mm > 0.0)
    lc.face_protection_depth_mm = j_face_protection_depth_mm;
  // COPIED: the PER-FACE depths (task 2026-08-12 §0a). Empty => every protection
  // uses the global depth, byte-identical to before the task.
  lc.face_protection_depths_mm = j_face_protection_depths_mm;
  // COPIED: protections declared on a REGION, and their per-region depths (task
  // 2026-08-14-face-regions). Empty => byte-identical to before the task.
  lc.face_protection_region_ids = j_face_protection_region_ids;
  lc.face_protection_region_depths_mm = j_face_protection_region_depths_mm;
  lc.minimize_plastic = j_minimize_plastic;
  lc.build_dir = j_build_dir;
  lc.infill_percent = j_infill_percent;
  lc.wall_loops = j_wall_loops;
  lc.wall_line_width_mm = j_wall_line_width_mm;
  // ★ RESTORED. This assignment shipped in PR #227 (commit 84a1350, 2026-07-28
  // 20:52) and was dropped 71 minutes later by PR #228's merge-conflict
  // resolution (commit fc6e95f), which hoisted this block into the helper and
  // re-typed five of these six lines. From then until this commit every job.json
  // / LAN-worker run silently fell back to the "mirror inner" sentinel, so a
  // 0.42 / 0.45 job computed — and truthfully reported — an outer width of 0.45.
  // (Device runs never used this path: bridge.cpp writes the field directly.)
  lc.wall_line_width_outer_mm = j_wall_line_width_outer_mm;
  lc.has_design_box = job.has_design_box;
  if (job.has_design_box) {
    lc.design_box = to_design_box(job.design_box);
    for (const JobBox& ko : job.keep_out_boxes)
      lc.keep_out_boxes.push_back(to_design_box(ko));
  }
  return lc;
}

namespace {

// --- THE load-case RECEIPT (task 2026-08-02-lattice-a-variant, bar Z2) -------
//
// WHAT IT IS FOR. Re-lattice takes a finished variant and certifies it again.
// That is only honest if the load case it certifies under is THE SAME ONE the
// variant was optimized under — not "a load case", not "a non-zero load case",
// the same one. PR 261's lesson is that a selector resolved against the wrong
// geometry tags nothing and says nothing, so "non-zero" is not evidence.
//
// This is the evidence. It records the facts that determine the load: which
// faces anchor, how many DOF they clamp, and for every declared force group its
// resolved magnitude and the number of voxels its faces actually tagged (the
// LoadGroupReport the builder already produces). ONE emitter, written by the
// optimize run and by the re-lattice run into their own output directories, so
// the two documents are comparable BYTE FOR BYTE. Equal receipts mean the two
// runs resolved the identical load case; unequal receipts name the difference.
//
// Deliberately carries nothing environmental (no paths, no timings, no out
// dir): every field is a property of the load case itself, or the comparison
// would fail for reasons that have nothing to do with the physics.
std::string loadcase_receipt_json(const JobDescription& job,
                                  const ProductionRunSetup* setup,
                                  const std::vector<int>& face_ids,
                                  std::size_t self_weight_tagged_voxels,
                                  const std::vector<DirichletBC>& bcs) {
  std::string s = "{\n";
  s += "  \"resolution\": " + std::to_string(job.resolution) + ",\n";
  s += "  \"model\": " + json_str(job.model) + ",\n";
  s += "  \"material\": " + json_str(job.material) + ",\n";
  s += "  \"anchor_bc_dofs\": " + std::to_string(bcs.size()) + ",\n";
  if (setup != nullptr) {
    Vec3 resultant{0.0, 0.0, 0.0};
    for (const JobLoadGroup& g : job.loads.groups) {
      resultant.x += g.force.x;
      resultant.y += g.force.y;
      resultant.z += g.force.z;
    }
    s += "  \"load_source\": \"loadcase\",\n";
    s += "  \"anchor_face_ids\": [";
    for (std::size_t i = 0; i < face_ids.size(); ++i)
      s += (i ? ", " : "") + std::to_string(face_ids[i]);
    s += "],\n";
    s += "  \"external_load_nodes\": " +
         std::to_string(setup->options.external_loads.size()) + ",\n";
    s += "  \"declared_force_resultant_n\": " +
         json_num(std::sqrt(resultant.x * resultant.x +
                            resultant.y * resultant.y +
                            resultant.z * resultant.z)) +
         ",\n";
    s += "  \"build_dir\": [" + json_num(job.loads.build_dir.x) + ", " +
         json_num(job.loads.build_dir.y) + ", " +
         json_num(job.loads.build_dir.z) + "],\n";
    s += "  \"groups\": [\n";
    for (std::size_t i = 0; i < setup->load_group_reports.size(); ++i) {
      const LoadGroupReport& g = setup->load_group_reports[i];
      s += "    {\"index\": " + std::to_string(g.index) + ", \"face_ids\": [";
      for (std::size_t f = 0; f < g.face_ids.size(); ++f)
        s += (f ? ", " : "") + std::to_string(g.face_ids[f]);
      s += "]";
      // ★ AND THE REGIONS IT DECLARED (task 2026-08-14-face-regions). Written
      // only when there are some, so a pre-region run's receipt is unchanged.
      if (!g.region_ids.empty()) {
        s += ", \"region_ids\": [";
        for (std::size_t r = 0; r < g.region_ids.size(); ++r)
          s += (r ? ", " : "") + std::to_string(g.region_ids[r]);
        s += "]";
      }
      s += ", \"force_mag_n\": " + json_num(g.force_mag) +
           ", \"voxels_tagged\": " + std::to_string(g.voxels_tagged) +
           ", \"status\": \"" +
           (g.status == LoadGroupReport::Status::Ok
                ? "ok"
                : (g.status == LoadGroupReport::Status::ZeroForce
                       ? "zero_force"
                       : "zero_tagged")) +
           "\"}";
      s += (i + 1 < setup->load_group_reports.size()) ? ",\n" : "\n";
    }
    s += "  ],\n";
    s += "  \"clearances\": [\n";
    for (std::size_t i = 0; i < setup->clearance_reports.size(); ++i) {
      const ProductionRunSetup::ClearanceReport& c = setup->clearance_reports[i];
      s += "    {\"face_id\": " + std::to_string(c.face_id) +
           ", \"kind\": \"" +
           (c.kind == ClearanceKind::Bolt ? "bolt" : "face") +
           "\", \"voxels_frozen\": " + std::to_string(c.voxels_frozen) +
           ", \"in_grid\": " + (c.in_grid ? "true" : "false") + "}";
      s += (i + 1 < setup->clearance_reports.size()) ? ",\n" : "\n";
    }
    s += "  ],\n";
    s += "  \"face_protections\": [\n";
    for (std::size_t i = 0; i < setup->face_protection_reports.size(); ++i) {
      const ProductionRunSetup::FaceProtectionReport& f =
          setup->face_protection_reports[i];
      // ★ A REGION PROTECTION REPORTS ITS REGION, not `face_id: -1` (task
      // 2026-08-14-face-regions). A receipt that names a face which does not
      // exist is worse than one that says nothing.
      // ★ THE KEY IS EMITTED ONLY WHEN THERE IS A REGION. A receipt that names
      // `face_id: -1` for a region protection claims a face that does not
      // exist; a receipt that gains a `"region_id": -1` on every pre-region run
      // is no longer byte-identical to the one it produced yesterday (bar R1).
      // Both are avoided by writing the key only when it says something.
      s += "    {\"face_id\": " + std::to_string(f.face_id) +
           (f.region_id >= 0
                ? ", \"region_id\": " + std::to_string(f.region_id)
                : std::string()) +
           ", \"voxels_frozen\": " + std::to_string(f.voxels_frozen) +
           ", \"depth_voxels\": " + std::to_string(f.depth_voxels) +
           ", \"depth_requested_mm\": " + json_num(f.depth_requested_mm) +
           ", \"depth_effective_mm\": " + json_num(f.depth_effective_mm) +
           ", \"thinner_than_depth\": " +
           (f.thinner_than_depth ? "true" : "false") + "}";
      s += (i + 1 < setup->face_protection_reports.size()) ? ",\n" : "\n";
    }
    s += "  ],\n";
    // ★ WHAT EACH DECLARED REGION RESOLVED TO ON THIS IMPORT (task
    // 2026-08-14-face-regions §3c). A union is persisted as a FILTER plus a hand
    // add/remove list and re-evaluated on every import, so the receipt has to
    // carry what it found — and `filter_drift`, which is the only place a CAD
    // edit that renumbered faces becomes visible after the fact.
    //
    // The block is written ONLY when regions were declared, so a pre-region run
    // produces the run_info.json it always produced (bar R1).
    if (!setup->face_region_reports.empty()) {
      s += "  \"face_regions\": [\n";
      for (std::size_t i = 0; i < setup->face_region_reports.size(); ++i) {
        const ProductionRunSetup::FaceRegionReport& r =
            setup->face_region_reports[i];
        s += "    {\"id\": " + std::to_string(r.id) +
             ", \"name\": " + json_str(r.name) +
             ", \"parent_id\": " + std::to_string(r.parent_id) +
             ", \"member_faces\": " + std::to_string(r.member_faces) +
             ", \"cuts\": " + std::to_string(r.cuts) +
             ", \"area_mm2\": " + json_num(r.area_mm2) +
             ", \"filter_matched\": " + std::to_string(r.filter_matched) +
             (r.filter_drift_known
                  ? ", \"filter_drift\": " + std::to_string(r.filter_drift)
                  : std::string()) + "}";
        s += (i + 1 < setup->face_region_reports.size()) ? ",\n" : "\n";
      }
      s += "  ],\n";
    }
    // ★ THE ANCHOR/LOAD STRUCTURAL PAD, ON ITS OWN LINE (task 2026-08-12 §1f).
    // It freezes with the same FrozenSolid value at the same depth 3 as a
    // protection, and reading the two together is how "I protected one wall"
    // became "21 faces are frozen". `face_protections` above is now EXACTLY what
    // the user declared; this is the pad, which is core's, not the user's.
    {
      const ProductionRunSetup::AnchorPadReport& ap = setup->anchor_pad_report;
      s += "  \"anchor_pad\": {\"applied\": " +
           std::string(ap.applied ? "true" : "false") +
           ", \"depth_voxels\": " + std::to_string(ap.depth_voxels) +
           ", \"anchor_faces\": " + std::to_string(ap.anchor_faces) +
           ", \"load_faces\": " + std::to_string(ap.load_faces) +
           ", \"voxels_frozen\": " + std::to_string(ap.voxels_frozen) +
           ", \"note\": \"the structural pad the boundary conditions sit on; "
           "NOT a user face protection\"}";
    }
    // ── WHICH LADDER, AND WHAT IT NEEDED (task 2026-08-03-growth-ladder) ─────
    // `ladder_mode` is emitted in BOTH modes, deliberately: NAMING THE MODE IS
    // THE POINT (bar G7). Unticking "minimize plastic" used to change the search,
    // the ladder and the anchor pad with nothing anywhere saying so, and a
    // document that names the mode only when it is unusual is exactly the silence
    // this closes. It costs the loadcase RECEIPT one key in reduction mode; the
    // PRODUCT (report.json and the exported meshes) is byte-identical either way.
    //
    // The growth block adds the two facts that used to travel silently with the
    // checkbox: whether a design box was DERIVED for the user (material grown
    // into a domain they never drew), and whether the anchor pad was frozen (the
    // safety feature the checkbox used to drop).
    if (setup->growth_ladder) {
      s += ",\n  \"ladder_mode\": \"growth\",\n";
      s += "  \"ladder_meaning\": \"add as little plastic as possible to reach "
           "the required margin; the recommendation is the SMALLEST addition "
           "that passes\",\n";
      s += "  \"growth_design_box_auto_derived\": " +
           std::string(setup->growth_box_auto_derived ? "true" : "false") + ",\n";
      if (setup->growth_box_auto_derived) {
        const DesignBox& b = setup->growth_box;
        s += "  \"growth_design_box_mm\": {\"min\": [" + json_num(b.min.x) +
             ", " + json_num(b.min.y) + ", " + json_num(b.min.z) +
             "], \"max\": [" + json_num(b.max.x) + ", " + json_num(b.max.y) +
             ", " + json_num(b.max.z) + "]},\n";
        s += "  \"growth_design_box_note\": \"no design box was drawn, so a "
             "MINIMAL one was derived from the part's bounding box — growth "
             "needs somewhere to go. Material outside the imported part was "
             "grown into THIS volume.\",\n";
      }
      s += "  \"growth_anchor_pad\": " +
           std::string(setup->growth_anchor_pad ? "true" : "false") + "\n";
    } else {
      s += ",\n  \"ladder_mode\": \"reduction\"\n";
    }
  } else {
    s += "  \"load_source\": \"self_weight\",\n";
    s += "  \"fixture_face_ids\": [";
    for (std::size_t i = 0; i < face_ids.size(); ++i)
      s += (i ? ", " : "") + std::to_string(face_ids[i]);
    s += "],\n";
    s += "  \"fixture_voxels_tagged\": " +
         std::to_string(self_weight_tagged_voxels) + ",\n";
    s += "  \"gravity_direction\": [" + json_num(job.gravity.direction.x) +
         ", " + json_num(job.gravity.direction.y) + ", " +
         json_num(job.gravity.direction.z) + "],\n";
    s += "  \"gravity_magnitude_mm_s2\": " +
         json_num(job.gravity.magnitude_mm_s2) + "\n";
  }
  s += "}\n";
  return s;
}

// ═══ THE PRE-FLIGHT LATTICE FORECAST (task 2026-08-03-variant-postprocessing-fix,
//     bars F1–F4) ══════════════════════════════════════════════════════════════
//
// Runs the grading law and the role accounting on a STORED design, and reports
// what a lattice run would produce — before the run. No FEA: every number below
// comes from the density field and the job's own lattice block.
//
// THE ONE APPROXIMATION, stated in the output as well as here. In AUTO density
// the law maps a DEMAND field (the variant's von Mises) to a relative density,
// and that field only exists after a solve. The forecast therefore grades at the
// BAND FLOOR — the thinnest strut the band allows, which is the CONSERVATIVE end
// for printability. It changes no cells-per-member verdict (that predicate does
// not see density at all), so the mask forecast is exact; it means the forecast
// does not predict the density DISTRIBUTION, only what will and will not be
// latticed, and why.
//
// COUNTERFACTUALS ARE EVALUATED, NOT GUESSED (bar F4, PR 276's rule): each
// remedy below is a real second call to grade_lattice with that one parameter
// changed, and reports the mask it actually produces.
struct ForecastCounterfactual {
  std::string change;      // human-facing: what to change
  std::string parameter;   // the job key it moves
  double value = 0.0;
  std::size_t latticed_voxels = 0;
  std::size_t region_voxels = 0;
  // Set only by the EXTRUSION-WIDTH remedy, which is genuinely two-dimensional:
  // a finer declared width lowers the printability FLOOR, and it is the cell that
  // floor unlocks which does the work. Reported so the entry is actionable rather
  // than a number the reader has to re-derive. 0 ⇒ single-parameter remedy.
  double cell_mm = 0.0;
};

// The candidate set the law grades over: solid voxels, minus clearances, minus
// exclude regions, restricted to include regions when any are declared. The SAME
// membership `lattice_one_variant` builds — spelled once here because a forecast
// that used a different membership would be forecasting a different job.
std::vector<char> forecast_candidates(const VoxelGrid& grid,
                                      const std::vector<double>& dens,
                                      const std::vector<ClearanceGeometry>& kos,
                                      const LatticeRoleRegions& roles,
                                      LatticeBoundary& members) {
  for (const ClearanceGeometry& g : kos)
    members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
  for (const ClearanceGeometry& g : roles.includes) members.add_include_region(g);
  for (const ClearanceGeometry& g : roles.excludes) members.add_exclude_region(g);
  std::vector<char> cand(grid.voxel_count(), 0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        // THE M3.5 ISO, and a KNOWN GAP with multiscale (task
        // multiscale-lattice-to). Everywhere the optimizer's own pipeline reads a
        // design, the threshold comes from run_printed_iso: a MULTISCALE design's
        // in-band voxels legitimately sit below 0.5, and reading one at 0.5 deletes
        // real lattice material. This forecast runs in lattice_variant_job on a
        // STORED design, and a StoredDesign does not record whether the run that
        // produced it was multiscale — so the threshold cannot be resolved here.
        //
        // Correct for every design reachable today (multiscale designs come out of
        // minimize_plastic, which latticed them in the same run), and stated rather
        // than left silent: if StoredDesign ever gains that flag, this must read the
        // same resolver the rest of the pipeline does, or the forecast will describe
        // a different object than the run it is forecasting.
        if (!(dens[e] >= 0.5)) continue;
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        if (members.in_keep_out(c, 0.0)) continue;
        if (members.in_exclude_region(c, 0.0)) continue;
        if (members.has_include_regions() && !members.in_include_region(c, 0.0))
          continue;
        cand[e] = 1;
      }
  return cand;
}

GradingLawParams forecast_grading_params(const JobDescription& job) {
  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;   // the job schema restricts to octet
  gp.target_cell_size_mm = job.grading.present ? job.grading.cell_mm
                                               : job.lattice.cell_mm;
  gp.min_extrudable_width_mm = job.grading.present
                                   ? job.grading.min_extrudable_width_mm
                                   : job.lattice.min_extrudable_width_mm;
  gp.demand_exponent = job.grading.present ? job.grading.demand_exponent : 1.0;
  gp.cell_mode = CellSizeMode::Fixed;
  if (job.grading.present &&
      !resolve_cell_mode(job.grading.cell_mode, gp.cell_mode))
    throw JobError("lattice_forecast: unknown grading cell_mode \"" +
                   job.grading.cell_mode + "\"");
  gp.min_cell_size_mm = job.grading.cell_min_mm;
  gp.max_cell_size_mm = job.grading.cell_max_mm;
  if (!(gp.target_cell_size_mm > 0.0) && gp.cell_mode == CellSizeMode::Fixed)
    gp.cell_mode = CellSizeMode::Auto;   // no cell stated ⇒ the law picks the floor
  if (!(gp.min_extrudable_width_mm > 0.0))
    throw JobError("lattice_forecast: min_extrudable_width_mm must be > 0 — the "
                   "printability floor is derived from it and there is no default "
                   "that would be honest about a printer we were not told about");
  return gp;
}

// *** THE UNIFORM FORECAST (task 2026-08-04-variant-volume-fraction-mismatch,
// failure B / B2). ***
//
// A job with NO `grading` block does not run the grading law at ALL:
// `lattice_one_variant` sets `graded = job.grading.present`, and when that is
// false the cell is `job.lattice.cell_mm`, the radius is `job.lattice
// .strut_radius_mm`, and EVERY cell overlapping the boundary gets a strut. There
// is no cells-per-member floor on that path and no printability floor.
//
// The forecast, however, ran `grade_lattice` unconditionally — so for a uniform
// job it forecast a GRADED run that was never going to happen. On the
// maintainer's WallMount growth variant it therefore reported
// `would_lattice_voxels: 0` and "This configuration would lattice NOTHING",
// while the very same job, run for real, wrote a 17.6 MB latticed STL full of
// struts. A forecast of a different job is worse than no forecast: it warned him
// off the one configuration that worked.
//
// So the uniform case is forecast by running the SAME two functions the uniform
// run runs — `lattice_boundary_for` and `lattice_certification_mask` — and
// counting their mask. Not a model of the run: the run's own predicate.
struct UniformForecast {
  std::size_t region_voxels = 0;
  std::size_t latticed_voxels = 0;
  double strut_diameter_mm = 0.0;
  bool strut_below_min_extrudable = false;
};

UniformForecast forecast_uniform(const JobDescription& job,
                                 const VoxelGrid& grid,
                                 const StoredDesign& sd,
                                 const std::vector<ClearanceGeometry>& kos,
                                 const LatticeRoleRegions& roles,
                                 const std::vector<char>& cand) {
  UniformForecast u;
  for (const char c : cand) u.region_voxels += (c != 0);
  const double cell = job.lattice.cell_mm;
  if (!(cell > 0.0)) return u;   // no cell stated ⇒ nothing to forecast uniformly
  // ★ ONE RESOLVED ISO, READ ONCE, USED BY ALL THREE (task
  // 2026-08-09-shell-at-runs-printed-iso). The shell, the boundary's voxel base
  // and the certification mask must describe the SAME printed set; they were
  // three separate `0.5` literals, which is three chances to drift.
  //
  // WHY IT IS 0.5 HERE, and it is not an oversight. This forecast runs inside
  // `lattice_variant_job`, and that entry point NEVER arms `multiscale_lattice`
  // — grep it: the flag is set only in `run_job` (~:7422). So the job being
  // forecast is a classic one and its printed iso IS 0.5. Resolving it through
  // the same helper the run uses keeps that a stated fact rather than a
  // coincidence, and makes the forecast follow automatically if the re-lattice
  // path ever learns multiscale.
  //
  // The SAME base surface the run will clip and certify against (task
  // 2026-08-08-strut-clip-matches-shell). The forecast holds a stored design and
  // no variant, so it rebuilds the shell the run's export would write, through
  // the one helper. Skipping this would put the forecast back on the surface the
  // run no longer uses — the exact "forecast forecast the WRONG job" failure the
  // comment above this function is about.
  const double forecast_iso = run_printed_iso(MinimizePlasticOptions{});
  const TriangleMesh shell = exported_shell_for(grid, sd.density, forecast_iso);
  const LatticeBoundary boundary = lattice_boundary_for(
      grid, sd.density, cell, kos, roles, forecast_iso, &shell);
  const std::vector<char> mask = lattice_certification_mask(
      boundary, grid, sd.density, forecast_iso, grid.origin, cell);
  for (std::size_t e = 0; e < mask.size(); ++e)
    if (mask[e] && e < cand.size() && cand[e]) ++u.latticed_voxels;
  u.strut_diameter_mm = 2.0 * job.lattice.strut_radius_mm;
  u.strut_below_min_extrudable =
      job.lattice.min_extrudable_width_mm > 0.0 &&
      u.strut_diameter_mm > 0.0 &&
      u.strut_diameter_mm < job.lattice.min_extrudable_width_mm;
  return u;
}

std::string lattice_forecast_json(const JobDescription& job,
                                  const VoxelGrid& grid,
                                  const StoredDesign& sd,
                                  const std::vector<ClearanceGeometry>& kos,
                                  const LatticeRoleRegions& roles) {
  LatticeBoundary members;
  const std::vector<char> cand =
      forecast_candidates(grid, sd.density, kos, roles, members);
  // A UNIFORM job takes an entirely different code path in the run, so it takes
  // an entirely different forecast here. See `forecast_uniform`.
  if (!job.grading.present) {
    const UniformForecast u =
        forecast_uniform(job, grid, sd, kos, roles, cand);
    const double frac = u.region_voxels > 0
                            ? static_cast<double>(u.latticed_voxels) /
                                  static_cast<double>(u.region_voxels)
                            : 0.0;
    std::string s = "{\n";
    s += "  \"forecast\": \"what a lattice run on THIS variant would produce, "
         "computed before the run from the stored design and this job's lattice "
         "block. No FEA ran.\",\n";
    s += "  \"variant_volume_fraction\": " +
         json_num(sd.requested_volume_fraction) + ",\n";
    s += "  \"topology\": \"" + job.lattice.topology + "\",\n";
    s += "  \"cell_mode\": \"uniform\",\n";
    s += "  \"cell_size_mm\": " + json_num(job.lattice.cell_mm) + ",\n";
    s += "  \"uniform_note\": \"this job carries NO \\\"grading\\\" block, so "
         "the run applies no grading law: no cells-per-member floor, no "
         "printability floor, one declared strut radius everywhere. The counts "
         "below come from the run's OWN boundary and certification-mask "
         "predicates, not from the grading law.\",\n";
    s += "  \"strut_radius_mm\": " + json_num(job.lattice.strut_radius_mm) +
         ",\n";
    s += "  \"strut_diameter_mm\": " + json_num(u.strut_diameter_mm) + ",\n";
    s += "  \"region_voxels\": " + std::to_string(u.region_voxels) + ",\n";
    s += "  \"would_lattice_voxels\": " + std::to_string(u.latticed_voxels) +
         ",\n";
    s += "  \"would_stay_solid_voxels\": " +
         std::to_string(u.region_voxels - u.latticed_voxels) + ",\n";
    s += "  \"latticed_fraction_of_region\": " + json_num(frac) + ",\n";
    s += "  \"would_stay_solid_by_reason\": {\n";
    s += "    \"cell_does_not_overlap_the_region\": " +
         std::to_string(u.region_voxels - u.latticed_voxels) + ",\n";
    s += "    \"note\": \"on the uniform path the ONLY predicate is whether a "
         "voxel's owning lattice cell overlaps the allowed region; there is no "
         "member-width test\"\n";
    s += "  },\n";
    s += "  \"include_regions\": " + std::to_string(roles.includes.size()) +
         ",\n";
    s += "  \"exclude_regions\": " + std::to_string(roles.excludes.size()) +
         ",\n";
    s += "  \"strut_below_min_extrudable\": " +
         std::string(u.strut_below_min_extrudable ? "true" : "false") + ",\n";
    if (u.strut_below_min_extrudable)
      s += "  \"strut_printability_note\": \"the declared strut radius implies a "
           "strut thinner than the declared extrusion width — the run will emit "
           "it anyway (the uniform path applies no printability floor), but the "
           "slicer will not be able to print it\",\n";
    const bool rim_only = job.lattice.skin == "rim";
    s += "  \"boundary\": \"" + job.lattice.skin + "\",\n";
    s += "  \"boundary_can_emit\": " +
         std::string(rim_only ? "false" : "true") + ",\n";
    if (rim_only)
      s += "  \"boundary_note\": \"\\\"rim\\\" dresses the edges where ANALYTIC "
           "faces meet (plane-plane, plane-bore). An optimized variant's surface "
           "comes from the voxel grid and owns no analytic face, so a rim emits "
           "nothing at all here. Choose \\\"diagrid\\\" for a woven surface skin, "
           "or \\\"none\\\" deliberately.\",\n";
    s += "  \"counterfactuals\": [],\n";
    s += "  \"counterfactual_note\": \"none are offered on the uniform path: it "
         "has no grading law to re-run, and the only knobs are the cell size and "
         "the strut radius the job already states.\",\n";
    s += "  \"demand_field\": \"none — a uniform lattice has no demand field. "
         "Every emitted strut has the declared radius.\"\n";
    s += "}\n";
    return s;
  }
  // The band-floor demand (see the header comment): zeros ⇒ rho_of == 0 ⇒ every
  // candidate clamps to the band's low end.
  const std::vector<double> flat_demand(grid.voxel_count(), 0.0);
  GradingLawParams gp = forecast_grading_params(job);
  // FIT: the same per-region derivation the run itself will use, so the forecast
  // describes the job that would actually run (the whole point of a forecast). The
  // counterfactuals below deliberately switch to Fixed, and they clear the pointer
  // with the mode, so none of them can read a field that no longer applies.
  std::vector<FitRegionCell> fc_fit_cells;
  std::vector<double> fc_fit_field;
  std::vector<double> fc_rho_field;
  if (gp.cell_mode == CellSizeMode::Fit) {
    fc_fit_cells =
        fit_region_cells(job, gp.topology, gp.min_extrudable_width_mm, &roles);
    if (fc_fit_cells.size() != roles.includes.size())
      throw JobError(
          "lattice_forecast: fit derivation and the resolved include regions "
          "disagree on how many regions this job has");
    fc_fit_field = fit_cell_field(grid, roles.includes, fc_fit_cells);
    gp.fit_cell_size_mm = &fc_fit_field;
    fc_rho_field = region_density_field(grid, roles.includes, fc_fit_cells);
    gp.region_relative_density = &fc_rho_field;
  }
  const GradedField gf =
      grade_lattice(grid, sd.density, flat_demand, &cand, gp);

  // INCLUDE REGIONS THAT LANDED ON VOID (defect 3 / bar V2). The optimizer left
  // no material there, so a lattice cannot conjure any — a no-op the user could
  // not see until the receipt. Same rule as the run's own role receipt.
  long long include_void = 0;
  if (members.has_include_regions())
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (sd.density[e] >= 0.5) continue;
          const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                       grid.origin.y + (j + 0.5) * grid.spacing,
                       grid.origin.z + (k + 0.5) * grid.spacing};
          if (members.in_include_region(c, 0.0)) ++include_void;
        }

  // ── EVALUATED counterfactuals (bar F4). Only offered where they COULD help:
  // a remedy that moves the cell is worth evaluating only if some rejected member
  // is wide enough for a legal cell to reach it. Where every rejection is
  // irrecoverable, NO cell remedy is offered — a wrong suggestion is worse than
  // none, and this is the maintainer's case exactly.
  std::vector<ForecastCounterfactual> cfs;
  const bool cell_remedy_possible =
      gf.fallback_member_too_thin > gf.fallback_irrecoverable_by_cell ||
      gf.fallback_strut_unprintable > 0;
  if (cell_remedy_possible) {
    for (const double mult : {0.5, 2.0}) {
      GradingLawParams alt = gp;
      if (alt.cell_mode == CellSizeMode::Swept) {
        alt.min_cell_size_mm *= mult;
        alt.max_cell_size_mm *= mult;
      } else {
        alt.cell_mode = CellSizeMode::Fixed;
        alt.target_cell_size_mm = gf.cell_size_mm * mult;
        alt.fit_cell_size_mm = nullptr;  // a Fixed what-if reads no derived field
      }
      GradedField alt_gf;
      try {
        alt_gf = grade_lattice(grid, sd.density, flat_demand, &cand, alt);
      } catch (const std::exception&) {
        continue;   // an inadmissible parameter is simply not a remedy
      }
      ForecastCounterfactual cf;
      cf.change = mult < 1.0 ? "halve the cell size" : "double the cell size";
      cf.parameter = alt.cell_mode == CellSizeMode::Swept ? "grading.cell_min_mm"
                                                          : "grading.cell_mm";
      cf.value = alt.cell_mode == CellSizeMode::Swept ? alt.min_cell_size_mm
                                                      : alt.target_cell_size_mm;
      cf.latticed_voxels = alt_gf.latticed_voxels;
      cf.region_voxels = alt_gf.region_voxels;
      cfs.push_back(cf);
    }
  }
  // ── THE EXTRUSION-WIDTH remedy (task
  // 2026-08-04-variant-volume-fraction-mismatch, failure B).
  //
  // *** WHY THIS HAD TO BE ADDED. *** "irrecoverable by any cell size" is true
  // only INSIDE a fixed printability floor, and that floor is not a property of
  // the part: it is `min_extrudable_width_mm / phi(rho_lo, unit cell)` — the
  // DECLARED extrusion width divided by a constant. So the sentence this file
  // used to emit whenever the cell remedies were withheld —
  //   "An empty list means no parameter change could help"
  // — was FALSE, and it was false on exactly the maintainer's parts. MEASURED, on
  // his WallMount growth run (design.bin of worker job efa7cfd3b4e344c6, rung
  // 1.55, 70788 region voxels): at his declared 0.42 mm every cell size lattices
  // 0 voxels; at 0.30 mm with a 3.0 mm cell it lattices 6750 (9.5% of the
  // region), and at 0.25 mm, 12020 (17.0%). He had been told nothing could help
  // for a week.
  //
  // The remedy is genuinely two-dimensional (a finer width only matters through
  // the cell it unlocks), so both numbers are carried on the entry and both are
  // EVALUATED — the threshold is derived in closed form, but what it is reported
  // to produce is what the grading law actually produced when re-run with it.
  //
  // Offered whenever ANY voxel was rejected as irrecoverable-by-cell — not only
  // when the lattice is entirely empty. A partial lattice with a wall of
  // irrecoverable members is the maintainer's likely next state, and the same
  // knob is the same remedy there.
  if (gf.fallback_irrecoverable_by_cell > 0 &&
      gf.fallback_max_member_width_mm > 0.0 &&
      gp.min_extrudable_width_mm > 0.0) {
    // The widest cell the widest REJECTED member can hold, and the declared width
    // whose floor sits exactly there. phi is linear in cell size, so
    // floor(w) = w / phi(rho_lo, 1) and the threshold inverts it directly.
    const double n_star = lattice_cells_per_member_min(gp.topology);
    const double cell_needed = gf.fallback_max_member_width_mm / n_star;
    const double phi_unit = octet_strut_diameter_mm(lattice_rho_min(gp.topology), 1.0);
    const double w_threshold = cell_needed * phi_unit;
    // Only offered when it is a REDUCTION the user does not already have. A
    // "remedy" that asks for a wider nozzle than the one declared is not one.
    if (w_threshold > 0.0 && w_threshold < gp.min_extrudable_width_mm) {
      for (const double w : {w_threshold, 0.5 * gp.min_extrudable_width_mm}) {
        if (!(w > 0.0)) continue;
        GradingLawParams alt = gp;
        alt.min_extrudable_width_mm = w;
        // The cell that width unlocks: the FINEST legal one, because a finer cell
        // clears the cells-per-member floor in MORE members, so this is the most
        // the declared width can buy. At the threshold it equals `cell_needed`
        // exactly, which is what makes that entry the break-even point.
        const double new_floor =
            lattice_cell_printability_floor_mm(alt.topology, w);
        const double cell = new_floor;
        alt.cell_mode = CellSizeMode::Fixed;
        alt.target_cell_size_mm = cell;
        alt.fit_cell_size_mm = nullptr;  // a Fixed what-if reads no derived field
        GradedField alt_gf;
        try {
          alt_gf = grade_lattice(grid, sd.density, flat_demand, &cand, alt);
        } catch (const std::exception&) {
          continue;
        }
        // Not a remedy unless it lattices MORE than the job already would; the
        // app's advice list filters on the same predicate, and offering a
        // sideways move as a fix is the wrong-suggestion failure bar F4 forbids.
        if (alt_gf.latticed_voxels <= gf.latticed_voxels) continue;
        ForecastCounterfactual cf;
        cf.change =
            "declare a finer extrusion width — it lowers the printability floor, "
            "which is what makes a small enough cell legal";
        cf.parameter = "lattice.min_extrudable_width_mm";
        cf.value = w;
        cf.cell_mm = cell;
        cf.latticed_voxels = alt_gf.latticed_voxels;
        cf.region_voxels = alt_gf.region_voxels;
        // The two probes can coincide (or the second can be dominated); keep only
        // entries that say something new.
        bool dup = false;
        for (const ForecastCounterfactual& p : cfs)
          if (p.parameter == cf.parameter &&
              p.latticed_voxels == cf.latticed_voxels)
            dup = true;
        if (!dup) cfs.push_back(cf);
      }
    }
  }
  // THE REGION counterfactual, always evaluated when include regions exist: what
  // the SAME design would lattice with no region restriction at all. That is the
  // number that tells a user whether their regions are the problem.
  ForecastCounterfactual whole;
  bool whole_ran = false;
  // NOT EVALUATED UNDER FIT, and that is not an oversight: fit DERIVES the cell from
  // the declared regions, so "drop the regions" is not a setting this job can have —
  // the schema refuses fit without one. Running it anyway would grade the whole part
  // against a field that covers only the regions and report a near-empty lattice as
  // though dropping the regions had caused it.
  if (!roles.includes.empty() && gp.cell_mode != CellSizeMode::Fit) {
    LatticeRoleRegions none;
    none.excludes = roles.excludes;
    LatticeBoundary m2;
    const std::vector<char> c2 =
        forecast_candidates(grid, sd.density, kos, none, m2);
    try {
      const GradedField g2 = grade_lattice(grid, sd.density, flat_demand, &c2, gp);
      whole.change = "drop the include regions (lattice the whole part)";
      whole.parameter = "lattice.regions";
      whole.latticed_voxels = g2.latticed_voxels;
      whole.region_voxels = g2.region_voxels;
      whole_ran = true;
    } catch (const std::exception&) {
    }
  }

  const double frac = gf.region_voxels > 0
                          ? static_cast<double>(gf.latticed_voxels) /
                                static_cast<double>(gf.region_voxels)
                          : 0.0;

  std::string s = "{\n";
  s += "  \"forecast\": \"what a lattice run on THIS variant would produce, "
       "computed before the run from the stored design and this job's lattice "
       "block. No FEA ran.\",\n";
  s += "  \"variant_volume_fraction\": " +
       json_num(sd.requested_volume_fraction) + ",\n";
  s += "  \"topology\": \"" + job.lattice.topology + "\",\n";
  s += "  \"cell_mode\": \"" + std::string(cell_size_mode_name(gf.cell_mode)) +
       "\",\n";
  s += "  \"cell_size_mm\": " + json_num(gf.cell_size_mm) + ",\n";
  s += "  \"printability_floor_mm\": " + json_num(gf.printability_floor_mm) +
       ",\n";
  s += "  \"cells_per_member_floor\": " + json_num(gf.cells_per_member_floor) +
       ",\n";
  s += "  \"region_voxels\": " + std::to_string(gf.region_voxels) + ",\n";
  s += "  \"would_lattice_voxels\": " + std::to_string(gf.latticed_voxels) +
       ",\n";
  s += "  \"would_stay_solid_voxels\": " +
       std::to_string(gf.solid_fallback_voxels) + ",\n";
  s += "  \"latticed_fraction_of_region\": " + json_num(frac) + ",\n";
  s += "  \"would_stay_solid_by_reason\": {\n";
  s += "    \"member_too_thin_for_cell\": " +
       std::to_string(gf.fallback_member_too_thin) + ",\n";
  s += "    \"strut_unprintable_at_every_cell\": " +
       std::to_string(gf.fallback_strut_unprintable) + ",\n";
  s += "    \"irrecoverable_by_any_cell_size\": " +
       std::to_string(gf.fallback_irrecoverable_by_cell) + ",\n";
  s += "    \"widest_rejected_member_mm\": " +
       json_num(gf.fallback_max_member_width_mm) + ",\n";
  s += "    \"member_width_needed_mm\": " +
       json_num(gf.cells_per_member_floor * gf.cell_size_mm) + "\n";
  s += "  },\n";
  // ── SUB-FLOOR RETENTION, FORECAST AS A NAMED OUTCOME (handoff 2026-08-04-
  //    subfloor-lattice-unloaded-regions, bar S7) ────────────────────────────────
  // The user must learn BEFORE the run that a region below the cells-per-member
  // floor will be latticed anyway — not from the receipt afterwards.
  //
  // WHAT THIS FORECAST CAN AND CANNOT SAY, stated in the output too. The count of
  // voxels below the floor is exact on the uniform paths: that predicate is
  // width/cell and never sees density, so the band-floor approximation this whole
  // forecast runs under cannot move it. The PREDICATE that decides whether they are
  // retained — the region's peak von Mises as a fraction of the part's — is NOT
  // computable here, because no solve has run and there is no stress field to
  // measure. So this reports the population and the rule, and says plainly that the
  // decision needs the run. It never guesses the fraction: `grade_lattice` DISARMS
  // retention when handed a demand-less field precisely so nothing downstream can
  // read 0.0 as "unloaded".
  const bool want_subfloor = job.grading.retain_subfloor_in_unloaded_regions;
  const double subfloor_ceiling =
      job.grading.subfloor_stress_fraction > 0.0
          ? job.grading.subfloor_stress_fraction
          : lattice_subfloor_retention_stress_fraction();
  s += "  \"subfloor_retention\": {\n";
  s += "    \"requested\": " + std::string(want_subfloor ? "true" : "false") + ",\n";
  s += "    \"stress_fraction_ceiling\": " +
       json_num(want_subfloor ? subfloor_ceiling : 0.0) + ",\n";
  s += "    \"voxels_below_floor\": " +
       std::to_string(gf.subfloor_candidate_voxels) + ",\n";
  s += "    \"outcome\": \"";
  if (!want_subfloor) {
    s += gf.subfloor_candidate_voxels > 0
             ? "NOT REQUESTED. " +
                   std::to_string(gf.subfloor_candidate_voxels) +
                   " of this region's voxels are below the cells-per-member floor "
                   "and will stay SOLID. Setting grading."
                   "retain_subfloor_in_unloaded_regions would lattice them if this "
                   "region measures at or under the stress-fraction ceiling — and "
                   "would put the certificate over them out of regime."
             : std::string(
                   "NOT REQUESTED, and nothing here is below the cells-per-member "
                   "floor, so it would change nothing on this variant.");
  } else if (gf.subfloor_candidate_voxels == 0) {
    s += "REQUESTED, but nothing in this region is below the cells-per-member "
         "floor, so retention will lattice no extra material.";
  } else {
    s += "REQUESTED. " + std::to_string(gf.subfloor_candidate_voxels) +
         " of this region's voxels are below the cells-per-member floor. They will "
         "be latticed ANYWAY — at " + json_num(gf.cells_per_member_floor) +
         " cells per member or fewer, below the floor homogenization needs — IF "
         "this region's peak von Mises measures at or under " +
         json_num(subfloor_ceiling) +
         " of the part's peak. If it measures above that, they stay solid. This "
         "pre-flight CANNOT tell you which: it runs before any solve, so there is "
         "no stress field to measure. The run's receipt reports the measured "
         "fraction and every retained voxel.";
  }
  s += "\",\n";
  s += "    \"accuracy_note\": \"retaining sub-floor material is a decision to "
       "accept an inaccuracy this codebase cannot currently quantify. The "
       "certification is STRUCTURALLY BLIND to cells-per-member — the homogenized "
       "tensor is a function of relative density alone — so a certified margin that "
       "does not move is NOT evidence that a sub-floor lattice is accurate. "
       "lattice_strut_out_of_regime is raised over retained material.\"\n";
  s += "  },\n";
  s += "  \"include_regions\": " + std::to_string(roles.includes.size()) + ",\n";
  s += "  \"exclude_regions\": " + std::to_string(roles.excludes.size()) + ",\n";
  s += "  \"include_region_void_voxels\": " + std::to_string(include_void) +
       ",\n";
  s += "  \"include_region_void_note\": \"include-region voxels where this "
       "variant has no material. A lattice cannot conjure material, so the "
       "include does nothing on them.\",\n";
  // THE BOUNDARY (defect 4 / bar S1). "rim" dresses analytic plane pairs, and an
  // optimized part is voxel-derived, so it has none.
  const bool rim_only = job.lattice.skin == "rim";
  s += "  \"boundary\": \"" + job.lattice.skin + "\",\n";
  s += "  \"boundary_can_emit\": " +
       std::string(rim_only ? "false" : "true") + ",\n";
  if (rim_only)
    s += "  \"boundary_note\": \"\\\"rim\\\" dresses the edges where ANALYTIC "
         "faces meet (plane-plane, plane-bore). An optimized variant's surface "
         "comes from the voxel grid and owns no analytic face, so a rim emits "
         "nothing at all here. Choose \\\"diagrid\\\" for a woven surface skin, "
         "or \\\"none\\\" deliberately.\",\n";
  s += "  \"counterfactuals\": [";
  bool first = true;
  auto emit_cf = [&](const ForecastCounterfactual& cf) {
    if (!first) s += ",";
    first = false;
    const double f = cf.region_voxels > 0
                         ? static_cast<double>(cf.latticed_voxels) /
                               static_cast<double>(cf.region_voxels)
                         : 0.0;
    s += "\n    {\"change\": \"" + cf.change + "\", \"parameter\": \"" +
         cf.parameter + "\"";
    if (cf.value > 0.0) s += ", \"value\": " + json_num(cf.value);
    if (cf.cell_mm > 0.0) s += ", \"cell_mm\": " + json_num(cf.cell_mm);
    s += ", \"would_lattice_voxels\": " + std::to_string(cf.latticed_voxels) +
         ", \"region_voxels\": " + std::to_string(cf.region_voxels) +
         ", \"latticed_fraction_of_region\": " + json_num(f) + "}";
  };
  for (const ForecastCounterfactual& cf : cfs) emit_cf(cf);
  if (whole_ran) emit_cf(whole);
  s += first ? "],\n" : "\n  ],\n";
  s += "  \"counterfactual_note\": \"every entry above was EVALUATED — the "
       "grading law was re-run with that change and the mask it actually "
       "produced is reported. An empty list means none of the changes probed "
       "here (cell size, extrusion width, dropping the include regions) "
       "lattices anything on this design — NOT that the part is beyond "
       "help.\",\n";
  s += "  \"demand_field\": \"none (pre-flight) — densities are forecast at the "
       "certifiable band's LOW end, the conservative end for printability. The "
       "cells-per-member rule does not see density, so the latticed/solid split "
       "above is exact; the density DISTRIBUTION is not forecast.\"\n";
  s += "}\n";
  return s;
}

}  // namespace

AnalyzeJobResult analyze_job(const JobDescription& job, const std::string& job_dir,
                             const std::string& out_dir,
                             const MaterialLibrary& materials,
                             const SettingsRules& rules,
                             const std::string& analyze_mesh_path,
                             const SmoothRequest& smooth) {
  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;

  AnalyzeJobResult result;

  // ── import the ORIGINAL model (the BCs are keyed on ITS anchor/fixture faces) ─
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh =
      part_format_for_path(job.model) != PartFormat::Step;
  try {
    result.model = import_part_file_resolved(model_path);
  } catch (const std::exception& e) {
    throw JobError(std::string("analyze: cannot import model: ") + e.what());
  }
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("analyze: model tessellation is not watertight: " + job.model);

  // ── the model grid + BCs + production options, MODE-SPECIFIC ──────────────────
  // A declared "loads" block re-certifies the design under that EXTERNAL load; no
  // "loads" block is the self-weight path (unchanged). Both establish the same
  // downstream contract: `model_grid` (fixture/anchor node indices + part-solid
  // baseline), `bcs`, and `options` (production solver config + gravity/build
  // orientation + margin_stop). The single certification tail below is shared.
  VoxelGrid model_grid;
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;
  const bool loadcase = job.loads.present;
  // loadcase only: the distributed tractions from the declared force groups are
  // computed on the model faces up front (INDEPENDENT of the fixed design's
  // internal geometry — a substitute/smoothed design changes no external load)
  // and ride on `options.external_loads`; the certification below takes them from
  // design_domain_loads, which is also where they get remapped onto an expanded
  // grid. They are no longer copied aside here — one place held them, one place
  // reads them.
  // loadcase only: the LOAD faces, frozen (alongside the anchors) when smoothing so
  // the traction stays attached to bit-identical solid. Empty in self-weight mode
  // (byte-identical). Without this a smoothed load cap erodes and the traction lands
  // on a void DOF ("under-constrained system") — the S3 specimen hits exactly that.
  std::vector<int> load_freeze_face_ids;

  if (loadcase) {
    // The SAME front-end-neutral mapping + core builder the optimizer's loadcase
    // path uses (production_loadcase_from_job → build_production_loadcase), so a
    // declared load case is resolved identically whether it is optimized or merely
    // analyzed. The anchors become the Dirichlet BCs (or the min-x fallback the
    // builder applies when none are declared); each force group becomes a
    // distributed traction; the production margin (default 1.5) + gravity/build
    // orientation come back on `options`.
    const ProductionLoadCase lc =
        production_loadcase_from_job(job, result.model);
    result.fixture_face_ids = lc.anchor_face_ids;
    ProductionRunSetup setup;
    try {
      setup = build_production_loadcase(result.model, job.resolution, lc);
    } catch (const JobError&) {
      throw;  // already a clean, loud job diagnostic (e.g. a selector match miss)
    } catch (const std::exception& e) {
      // A raw anchor/load face id outside the model's face set reaches here as
      // the builder's legible out-of-range diagnostic (validate_face_id names
      // the id, the count and which selection it came from). The wrap adds the
      // ONE fact the builder cannot know: WHICH mesh the ids were resolved
      // against (L5 + N5: a declared load referencing a face that does not
      // exist must fail loudly, naming id / count / mesh).
      throw JobError(std::string("analyze: cannot build the declared load "
                                 "case against model \"") +
                     job.model + "\": " + e.what());
    }
    // L5 — NEVER silently fall back to self-weight. When the job declared load
    // groups but every one was zero-force or tagged no voxels at this resolution,
    // the builder arms require_external_loads and leaves external_loads empty.
    // The optimizer would refuse in minimize_plastic; the analyze path never runs
    // the optimizer, so it must refuse HERE — analyzing under self-weight instead
    // of the declared load is exactly the silent-degradation bug (PR 178).
    if (setup.options.require_external_loads &&
        setup.options.external_loads.empty())
      // The refusal stays as LOUD as before; the per-group reports make it
      // legible — WHICH group resolved to nothing and WHY (N4), instead of the
      // old "every force group was zero-force or tagged no voxels" that named
      // neither.
      throw JobError(
          "analyze: the declared load case produced NO external load — " +
          no_external_load_message(setup, job.resolution) +
          ". Refusing to analyze under SELF-WEIGHT instead of the declared "
          "load (that silent fallback is the PR-178 param-drop bug).");
    model_grid = std::move(setup.grid);
    bcs = std::move(setup.bcs);
    options = std::move(setup.options);
    for (const ProductionLoadCase::LoadGroup& g : lc.load_groups)
      for (const int fid : g.face_ids) load_freeze_face_ids.push_back(fid);
  } else {
    // ── SELF-WEIGHT path (unchanged): voxelize + tag the fixture faces, clamp
    // their nodes, and apply the production config + the job's gravity/margin.
    // The fixture NODE indices and the part-solid count are geometry, so we take
    // them from the model grid and reuse them for any same-geometry design.
    model_grid = voxelize(result.model.mesh, job.resolution);
    result.fixture_face_ids =
        resolve_selectors(result.model, job.fixture_faces, "fixture_faces");
    std::size_t tagged = 0;
    for (const int f : result.fixture_face_ids)
      tagged += model_is_mesh
                    ? tag_mesh_face(model_grid, result.model, f, VoxelTag::Fixture)
                    : tag_step_face(model_grid, result.model, f, VoxelTag::Fixture);
    if (tagged == 0)
      throw JobError(
          "analyze: fixture faces tagged no voxels (resolution too coarse "
          "for the selected faces?)");
    for (const int n : fea_tagged_nodes(model_grid, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    configure_production_options(options);
    options.material_catalog = &materials;  // gate diagnosis, READ ONLY (see above)
    options.margin_stop = job.margin_stop;
    options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
    options.gravity_direction = job.gravity.direction;
  }
  // The build-plate normal, separated from gravity (handoff
  // 2026-08-01-build-direction-separation). AFTER the mode branch so it governs
  // both modes; absent key => byte-identical.
  apply_build_direction_options(options, job);
  // Optional design-domain expansion. The loadcase branch already carries it on
  // `options` (build_production_loadcase forwards the job's box); the
  // self-weight branch did not, so it is set here — a re-analysis that dropped
  // the box would silently certify a TRUNCATED design (task
  // 2026-08-03-design-box-recertification, bar AI5).
  if (job.has_design_box && !options.design_box.has_value()) {
    options.design_box = to_design_box(job.design_box);
    for (const JobBox& ko : job.keep_out_boxes)
      options.keep_out_boxes.push_back(to_design_box(ko));
  }
  // THE domain the originating run solved on — the SAME core call it used, so a
  // smoothed design-box variant is re-certified on the grid it was produced on
  // and under the load case that produced it, rather than clipped back onto the
  // part grid. Without a design box `domain.grid` IS `model_grid` and
  // `domain.bcs` IS `bcs`, so every existing analyze run is byte-identical.
  const SolvedDesignDomain domain = resolve_design_domain(model_grid, bcs, options);
  // *** THE EXPANSION IS ONLY FOR A SUBSTITUTE MESH. *** The expanded grid exists
  // to hold a DESIGN that grew outside the imported part. A `--mesh` analyze is
  // handed such a design and must be voxelized onto it, or the material outside
  // the part is silently clipped away. A NO-MESH analyze is not: it certifies
  // the imported part AS DRAWN, and its occupancy comes from the grid's own tags
  // — and expand_design_domain tags the whole in-box Active region `Interior`,
  // i.e. SOLID. Certifying on the expanded grid there would certify a FILLED
  // BOX rather than the part, which is what RUN SIM and every non-smoothing
  // re-certification ask for. So the no-mesh path keeps the model grid, exactly
  // as it did before this task. Asserted, not argued: a design-box no-mesh
  // analyze must report the same solid count and mass as the same analyze with
  // no design box (test_designbox_lattice_recert, section E).
  const bool expand_for_mesh = domain.expanded && !analyze_mesh_path.empty();
  const VoxelGrid& cert_grid = expand_for_mesh ? domain.grid : model_grid;
  const std::vector<DirichletBC>& cert_bcs = expand_for_mesh ? domain.bcs : bcs;
  // The PART's solid count — the part-relative denominator, which under
  // expansion is NOT the solved grid's solid count (handoff 080).
  const double part_solid = static_cast<double>(model_grid.solid_count());

  // ── the FIXED design to analyse (its OWN occupancy grid) ─────────────────────
  // `design_grid` carries the solid tags of the geometry being certified (so the
  // stress solve's printed-voxel gate matches it and self-weight is the design's
  // own weight); `density` is that occupancy as a binary field. Same voxel geometry
  // as `cert_grid`, so the fixture node indices above stay valid.
  if (smooth.enabled && analyze_mesh_path.empty())
    throw JobError("analyze: --smooth requires a --mesh input to smooth");

  VoxelGrid design_grid = cert_grid;
  // The smoothed mesh, held until the applied build orientation is known (see
  // below). Empty unless --smooth ran.
  TriangleMesh pending_smoothed_mesh;
  if (!analyze_mesh_path.empty()) {
    StepModel edited;
    try {
      edited = import_part_file_resolved(join_path(job_dir, analyze_mesh_path));
    } catch (const std::exception& e) {
      throw JobError(std::string("analyze: cannot import analyze mesh: ") +
                     e.what());
    }

    // ── CONSTRAINED SMOOTHING (handoff 2026-07-26-constrained-smooth-ui) ───────
    // Smooth the input mesh BEFORE re-voxelizing, so everything below re-certifies
    // the SMOOTHED geometry (the honesty rule: the numbers shown always describe
    // what is exported). Frozen vertices come from the model's B-rep fixture faces
    // (bores + pads) AND — in loadcase mode — the LOAD faces, so both the clamp and
    // the traction stay attached to bit-identical solid across the re-voxelization
    // (without the load faces frozen, smoothing erodes the loaded cap and the
    // traction lands on a void DOF). The min-feature constraint is evaluated against
    // cert_grid — the run's SOLVED grid, so under a design box it covers the
    // material the optimizer grew outside the part instead of stopping at the
    // part's bounding box. Same spacing and same voxel lattice either way, so a
    // no-box run measures exactly what it measured before.
    TriangleMesh design_mesh = edited.mesh;
    if (smooth.enabled) {
      const TaubinParams params =
          taubin_params_for_strength(smooth.strength, smooth.max_pairs);
      SmoothConstraints c;
      std::vector<int> freeze_face_ids = result.fixture_face_ids;
      freeze_face_ids.insert(freeze_face_ids.end(),
                             load_freeze_face_ids.begin(),
                             load_freeze_face_ids.end());
      c.freeze_regions = freeze_regions_from_faces(
          result.model, freeze_face_ids, cert_grid.spacing);
      c.freeze_tol_mm = smooth.freeze_tol_mm;
      c.min_feature_grid = &cert_grid;
      c.enforce_min_feature = smooth.enforce_min_feature;
      SmoothResult sr = constrained_taubin_smooth(edited.mesh, params, c);
      design_mesh = std::move(sr.mesh);
      result.smoothed = true;
      result.smooth_strength = smooth.strength;
      result.smooth_stats = sr.stats;
      // Export the smoothed mesh (task item 5): <analyze_mesh basename>_smoothed.stl.
      {
        std::error_code ec;
        std::filesystem::create_directories(out_dir, ec);
        if (ec)
          throw JobError("analyze: cannot create output directory " + out_dir +
                         ": " + ec.message());
      }
      const std::string stem =
          std::filesystem::path(analyze_mesh_path).stem().string();
      result.smoothed_mesh_path = join_path(out_dir, stem + "_smoothed.stl");
      // DEFERRED (handoff 2026-08-01-bake-build-orientation). This file is the
      // geometry this run certifies, so it is an EXPORT and must carry the
      // certified orientation like every other one — and the applied orientation
      // is not known until the analysis below has run. The mesh is held and
      // written after it; the path and (off the bake path) the bytes are
      // unchanged.
      pending_smoothed_mesh = design_mesh;
    }

    // Re-voxelize the (smoothed) mesh onto the MODEL's grid geometry, then carry the
    // model's Fixture (clamp) and Load (traction) tags over. The Fixture clamp is
    // carried only where the substitute still has material. The LOAD surface is
    // FORCED solid — the declared traction is applied to a mounting interface that is
    // implicitly FrozenSolid the same way the optimizer retains load faces, so the
    // force always has stiffness even where an aggressive smooth eroded the loaded
    // cap (otherwise the solve hits a void DOF — no equilibrium). This restores
    // exactly the loaded face the traction was declared on; the load-bearing BODY
    // (the ribs) still erodes and still lowers the margin. In self-weight mode
    // `cert_grid` carries no Load tags, so this is byte-identical to carrying
    // Fixture alone. The quantization gap (mesh surface vs this voxelization) is
    // disclosed below.
    //
    // The target is `cert_grid`, the run's SOLVED grid: under a design box the
    // mesh being re-certified EXTENDS BEYOND the imported part, and voxelizing it
    // onto the part grid would silently CLIP the material the optimizer grew and
    // certify a smaller object than the file it describes. expand_design_domain
    // preserves the part's Fixture/Load tags at the domain offset, so the tag
    // carry-over below reads the same tags it always did.
    design_grid = voxelize_onto_grid(design_mesh, cert_grid);
    for (std::size_t i = 0; i < design_grid.tags.size(); ++i) {
      if (cert_grid.tags[i] == VoxelTag::Load) {
        // When WE smoothed, the loaded cap is restored solid (see above). For a raw
        // substitute mesh (no smoothing) keep 228's contract — certify what was
        // handed in, carrying the Load tag only where the mesh has material — so the
        // non-smoothed loadcase analyze stays byte-identical (bar S6).
        if (smooth.enabled) design_grid.tags[i] = VoxelTag::Load;
        else if (design_grid.tags[i] != VoxelTag::Empty)
          design_grid.tags[i] = VoxelTag::Load;
      } else if (design_grid.tags[i] != VoxelTag::Empty &&
                 cert_grid.tags[i] == VoxelTag::Fixture) {
        design_grid.tags[i] = VoxelTag::Fixture;
      }
    }
    result.analyzed_mesh = true;
    result.analyzed_mesh_path = analyze_mesh_path;
    result.mesh_mass_grams =
        material.density_g_cm3 * mesh_enclosed_volume_mm3(design_mesh) / 1000.0;
  }
  std::vector<double> density(design_grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < density.size(); ++i)
    if (design_grid.tags[i] != VoxelTag::Empty) density[i] = 1.0;

  // ── the certification load case (production config already on `options`) ─────
  // The production solver config + margin + gravity/build orientation were set on
  // `options` in the mode branch above (build_production_loadcase in loadcase mode,
  // configure_production_options in self-weight mode). Here we only pick the loads:
  //   * loadcase   — the declared EXTERNAL tractions, fixed on the model faces
  //                  (independent of the fixed design's internal geometry);
  //   * self-weight — the DESIGN's own weight, recomputed on `design_grid` so a
  //                  substitute/smoothed design carries its own mass.
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ARCHITECTURE §4 (density_min stays the 1e-3 default)

  // THE ONE resolver (handoff 2026-08-01-build-direction-separation) — the third
  // and last of the sites that used to derive this from gravity independently.
  // A standalone re-analysis of a part now certifies against the orientation the
  // originating run used, because both ask the same function.
  const Vec3 build_dir = resolve_build_direction(options);
  // THE ONE BAKE DECISION for this re-analysis (handoff
  // 2026-08-01-bake-build-orientation) — the same function the optimize path
  // asks, so a part re-certified later is placed the same way the run that
  // produced it placed it.
  const BuildOrientationBakePlan bake_plan = resolve_bake_plan(options);
  const bool score_orientations =
      options.build_orientation_report || bake_plan.needs_scorer;
  // loadcase: THE ONE definition (design_domain_loads), which returns the
  // declared tractions REMAPPED onto the solved grid — the remap this path also
  // lacked under a design box. self-weight: DELIBERATELY the design's OWN weight
  // on `design_grid` (a substitute/smoothed design carries its own mass), which
  // is why this branch is not design_domain_loads — that would weigh the run's
  // occupancy, not this design's.
  const std::vector<NodalLoad> loads =
      loadcase ? (expand_for_mesh
                      // the declared tractions REMAPPED onto the expanded grid
                      // the substitute mesh was voxelized onto
                      ? design_domain_loads(domain, options,
                                            material.density_g_cm3)
                      // no mesh (or no box): the analysis runs on the MODEL grid,
                      // where the declared tractions are already correctly
                      // indexed — remapping them here would point them at nodes
                      // of a grid this branch never uses
                      : options.external_loads)
               : self_weight_loads(design_grid, material.density_g_cm3,
                                   options.gravity, options.gravity_direction);
  const bool load_path_ok = load_path_connected(design_grid, density, 0.5);
  // The gate knockdown posture (handoff 2026-07-26-width-aware-knockdown), built
  // from the SAME options the originating run used so a standalone re-analysis gates
  // on the identical rule. THE ONE builder (knockdown_spec_for) — shared with the
  // optimizer's per-rung gate and the on-device bridge so all three agree by
  // construction. width_aware defaults false → the scalar f^1.5 gate.
  const KnockdownSpec knockdown = knockdown_spec_for(options);

  // ── THE single analysis solve — no optimization ─────────────────────────────
  result.analysis = analyze_fixed_design(
      design_grid, params, density, cert_bcs, loads, material, build_dir,
      options.simp.cg_tolerance, options.simp.cg_max_iterations,
      options.simp.solver, options.margin_stop, knockdown, load_path_ok,
      part_solid, /*lattice=*/nullptr,
      // The re-analysis ranks the SAME candidate set the originating run did
      // (build_orientation_candidates is derived inside analyze_fixed_design),
      // so a part's recommendation cannot change just because it was re-analysed.
      score_orientations, resolve_build_direction_is_inferred(options),
      bake_plan.auto_apply);
  const FixedDesignAnalysis& a = result.analysis;
  // The orientation this re-analysis certifies, and the rotation the exported
  // geometry carries (empty when the export stays in model coordinates).
  const Vec3 applied_build_dir = a.applied_build_dir;
  std::optional<BuildFrameRotation> analyze_bake;
  if (bake_plan.bake) analyze_bake = build_frame_rotation(applied_build_dir);
  result.voxel_mass_grams = a.mass_grams;

  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("analyze: cannot create output directory " + out_dir + ": " +
                     ec.message());
  }

  // ── the SMOOTHED mesh export, now that the certified orientation is known ────
  // (handoff 2026-08-01-bake-build-orientation.) This is the geometry the run
  // certifies, so it is baked exactly like the optimize path's variant meshes.
  // Off the bake path the bytes are what write_stl_file produced before.
  if (!result.smoothed_mesh_path.empty())
    write_stl_file(result.smoothed_mesh_path,
                   analyze_bake ? rotate_mesh(pending_smoothed_mesh, *analyze_bake)
                                : pending_smoothed_mesh);

  // ── the LATTICE GRADING LAW (handoff 2026-07-29-lattice-grading-law) ─────────────
  // When a "grading" block is present, feed the certification's von Mises field to the
  // grading law: it produces a per-voxel density + one uniform cell size, clamped to
  // the certifiable band and the cells-per-member floor it READS from core, and leaves
  // members too thin to grade SOLID (bar L4). The full report is written to run_info's
  // "grading" object. Absent -> this block is skipped, no run_info is written, and the
  // analyze path is byte-identical (bar L1).
  if (job.grading.present) {
    GradingLawParams gp;
    gp.topology = LatticeTopology::Octet;  // job schema restricts topology to octet
    gp.target_cell_size_mm = job.grading.cell_mm;
    gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gp.demand_exponent = job.grading.demand_exponent;
    // Cell-size mode; an absent "cell_mode" parses as "fixed" — the pre-sweep path.
    if (!resolve_cell_mode(job.grading.cell_mode, gp.cell_mode))
      throw JobError("analyze: unknown grading cell_mode \"" +
                     job.grading.cell_mode + "\"");
    gp.min_cell_size_mm = job.grading.cell_min_mm;
    gp.max_cell_size_mm = job.grading.cell_max_mm;
    // ── ★ ABSOLUTE UTILISATION, ARMED ON THE LATTICE-ONLY PATH (task
    //    2026-08-20-lattice-only-grading, §0 / §2 / §3) ──────────────────────────
    // ★ THIS BLOCK IS WHY §5(a) HOLDS STRUCTURALLY. `analyze` is the LATTICE-ONLY
    // path — a part latticed with NO topology optimisation, which is what RUN SIM
    // drives. The TO+lattice path is `minimize_plastic`, a different function, and
    // it never reaches this code: `demand_allowable_mpa` is left at its 0.0 default
    // there, which is the peak-relative law byte-for-byte. The scoping is therefore
    // a property of WHERE the field is set, not a promise in a comment.
    //
    // ★ WHICH ALLOWABLE (bar R9): the IN-PLANE one, yield / margin_stop, with the
    // z knockdown NOT in it. The demand field is von Mises — an in-plane measure —
    // and the gate's in-plane margin is yield / von Mises, so utilisation 1.0 means
    // exactly "in-plane margin == margin_stop". The knockdown belongs to the
    // interlayer mode, priced from a different field, and folding an unsourced
    // constant into every density would be worse than leaving it where the gate
    // already applies it. The interlayer check is untouched.
    gp.demand_allowable_mpa = material.yield_strength_mpa / options.margin_stop;
    // ★ THE GOAL IS THE USER'S EXISTING CHECKBOX (§3c) — no second control.
    // ON  = "use as little plastic as possible" -> work the whole allowable.
    // OFF = "make a sturdy model regardless of extra plastic" -> stop at a stated
    //       fraction of it, so the same field buys more material.
    gp.utilisation_target = job.loads.present && !job.loads.minimize_plastic
                                ? kSturdyUtilisationTarget
                                : 1.0;
    gp.unloaded_utilisation_max = kUnloadedUtilisationMax;
    // ── ★ THE INTENT (amendment §1d) ─────────────────────────────────────────
    // ★ AESTHETIC IS THE DEFAULT **HERE**, on the lattice-only job — not in
    // GradingLawParams, where every caller would inherit it and the TO+lattice and
    // multiscale paths would silently change. An absent "intent" key means the
    // common case: a lattice the user wants to SEE, on a part that usually does not
    // need one structurally.
    if (job.grading.intent.empty()) {
      gp.intent = GradingIntent::Aesthetic;
    } else if (!grading_intent_from_name(job.grading.intent.c_str(), gp.intent)) {
      throw JobError("analyze: unknown grading intent \"" + job.grading.intent + "\"");
    }
    gp.aesthetic_percentile = job.grading.aesthetic_percentile;
    gp.aesthetic_rho_min = job.grading.aesthetic_rho_min;
    gp.aesthetic_rho_max = job.grading.aesthetic_rho_max;
    gp.aesthetic_adaptive_cells_per_member =
        job.grading.aesthetic_adaptive_cells_per_member;
    gp.aesthetic_error_budget = job.grading.aesthetic_error_budget;
    // FIT needs the per-region derivation here too, or the analyze receipt would
    // describe a cell law the run never used. `nullptr` region below means the
    // candidate set is the whole printed design, so voxels outside every declared
    // include region get no derived cell and stay solid — which grade_lattice counts
    // as `fit_no_derivation_voxels` rather than guessing a cell for them.
    std::vector<FitRegionCell> fit_cells;
    std::vector<double> fit_field;
    std::vector<double> an_rho_field;
    LatticeRoleRegions an_roles;
    if (gp.cell_mode == CellSizeMode::Fit) {
      an_roles = lattice_role_regions_from_job(job, &result.model, &model_grid);
      fit_cells = fit_region_cells(job, gp.topology,
                                   job.grading.min_extrudable_width_mm,
                                   &an_roles);
      if (fit_cells.size() != an_roles.includes.size())
        throw JobError(
            "analyze: fit derivation and the resolved include regions disagree on "
            "how many regions this job has");
      fit_field = fit_cell_field(design_grid, an_roles.includes, fit_cells);
      gp.fit_cell_size_mm = &fit_field;
      an_rho_field = region_density_field(design_grid, an_roles.includes, fit_cells);
      gp.region_relative_density = &an_rho_field;
    }
    // ★ THE ALGORITHM (task 2026-08-21-organic-lattice, §4). Resolved BEFORE the law
    // runs, so an organic + structural job is refused before it spends a solve on a
    // density it is not allowed to certify.
    const LatticeAlgorithm an_alg = resolve_lattice_algorithm(job.grading);
    refuse_organic_structural(an_alg, job.grading);
    const GradedField gf =
        grade_lattice(design_grid, density, a.von_mises_field, nullptr, gp);

    // ★ ORGANIC. The grading law above chose the DENSITY (all three algorithms honour
    // the same intent, §4b); this turns that density into a spacing field and traces.
    // Doubled and stepped skip it entirely, so their receipts are unchanged.
    // STEPPED needs the per-voxel region membership; on the analyze path the
    // candidate set is the whole printed design (region == nullptr above), so the ids
    // are built here from the same declared regions the geometry path uses.
    SteppedOutcome an_step;
    if (an_alg == LatticeAlgorithm::Stepped) {
      const LatticeRoleRegions sr =
          lattice_role_regions_from_job(job, &result.model, &model_grid);
      std::vector<int> ids(design_grid.voxel_count(), 0);
      for (int k = 0; k < design_grid.nz; ++k)
        for (int j = 0; j < design_grid.ny; ++j)
          for (int i = 0; i < design_grid.nx; ++i) {
            const std::size_t e = design_grid.index(i, j, k);
            if (!gf.posture.mask[e]) continue;
            const Vec3 c{design_grid.origin.x + (i + 0.5) * design_grid.spacing,
                         design_grid.origin.y + (j + 0.5) * design_grid.spacing,
                         design_grid.origin.z + (k + 0.5) * design_grid.spacing};
            for (std::size_t ri = 0; ri < sr.includes.size(); ++ri)
              if (point_in_clearance_region(sr.includes[ri], c, 0.0)) {
                ids[e] = static_cast<int>(ri) + 1;
                break;
              }
          }
      an_step = run_stepped_step(design_grid, density, gf.posture.mask,
                                 gf.posture.relative_density, ids, job.grading, 0.5,
                                 gp.thickness_cap_voxels);
    }
    OrganicOutcome an_org;
    if (an_alg == LatticeAlgorithm::Organic)
      an_org = run_organic_step(design_grid, density, a.stress_tensor_field,
                                gf.posture.mask, gf.posture.relative_density,
                                gf.band_rho_min, gf.band_rho_max, job.grading,
                                applied_build_dir, 0.5, gp.thickness_cap_voxels);

    RunInfo gi = build_run_info(job, options, RunObservability{});
    gi.grading_present = true;
    gi.grading_algorithm = lattice_algorithm_name(an_alg);
    // ★ THE COMPARABLE NUMBER (bar R10): the solid volume THIS algorithm's own
    // per-voxel density implies. Read from the algorithm's own field, never from
    // another's, so the three-way table compares one quantity three times.
    {
      const std::vector<double>& rho_used =
          an_org.ran ? an_org.lat.relative_density : gf.posture.relative_density;
      const std::vector<char>& msk_used =
          an_org.ran ? an_org.lat.mask : gf.posture.mask;
      const double vox = design_grid.spacing * design_grid.spacing *
                         design_grid.spacing;
      double sum = 0.0;
      long long cnt = 0;
      for (std::size_t e = 0; e < msk_used.size(); ++e)
        if (msk_used[e]) { sum += rho_used[e]; ++cnt; }
      gi.grading_lattice_solid_volume_mm3 = sum * vox;
      gi.grading_algorithm_latticed_voxels = cnt;
    }
    if (an_org.ran) fill_organic_run_info(gi, an_org);
    if (an_step.ran) fill_stepped_run_info(gi, an_step);
    gi.grading_topology = lattice_topology_name(gf.posture.topology);
    gi.grading_band_rho_min = gf.band_rho_min;
    gi.grading_band_rho_max = gf.band_rho_max;
    gi.grading_cells_per_member_floor = gf.cells_per_member_floor;
    gi.grading_cell_size_mm = gf.cell_size_mm;
    gi.grading_printability_floor_mm = gf.printability_floor_mm;
    gi.grading_cell_size_floored = gf.cell_size_floored;
    gi.grading_min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gi.grading_rho_min_used = gf.rho_min_used;
    gi.grading_rho_max_used = gf.rho_max_used;
    gi.grading_region_voxels = static_cast<long long>(gf.region_voxels);
    gi.grading_latticed_voxels = static_cast<long long>(gf.latticed_voxels);
    gi.grading_demand_allowable_mpa = gf.demand_allowable_mpa_used;
    gi.grading_utilisation_target = gf.utilisation_target_used;
    gi.grading_max_utilisation = gf.max_utilisation;
    gi.grading_median_utilisation = gf.median_utilisation;
    gi.grading_over_allowable_voxels =
        static_cast<long long>(gf.over_allowable_voxels);
    gi.grading_unloaded_voxels = static_cast<long long>(gf.unloaded_voxels);
    gi.grading_clamped_lo_voxels = static_cast<long long>(gf.clamped_lo_voxels);
    gi.grading_clamped_hi_voxels = static_cast<long long>(gf.clamped_hi_voxels);
    gi.grading_density_at_floor_voxels =
        static_cast<long long>(gf.density_at_floor_voxels);
    gi.grading_density_at_ceiling_voxels =
        static_cast<long long>(gf.density_at_ceiling_voxels);
    // ── ★ RE-CERTIFY THE LATTICED OBJECT — STRUCTURAL INTENT ONLY ─────────────
    // ★ THE GAP THIS CLOSES. Until now the lattice-only path solved ONCE, on the
    // SOLID part, and graded from that field afterwards. Nothing ever certified the
    // object that would actually be PRINTED: the certificate described the part
    // BEFORE it was hollowed out. In structural intent the density IS a strength
    // claim, so that is exactly the claim nobody was checking.
    //
    // ★ STRUCTURAL ONLY, as scoped. An aesthetic density is not a strength claim
    // (`density_meaning` says so on the receipt), so re-solving for it would spend a
    // second FEA to certify a number that is not making a promise. NOTE THE RESIDUAL
    // RISK, because it does not disappear: latticing removes material whatever the
    // intent, so an aesthetic lattice through a load path still weakens the part and
    // is still not re-certified here. That is a KNOWN, STATED gap, not an oversight.
    //
    // Costs a second solve. It runs only when a grading block asked for a structural
    // lattice, so no existing path pays for it.
    if (gf.intent_used == GradingIntent::Structural && gf.latticed_voxels > 0) {
      const FixedDesignAnalysis relat = analyze_fixed_design(
          design_grid, params, density, cert_bcs, loads, material, build_dir,
          options.simp.cg_tolerance, options.simp.cg_max_iterations,
          options.simp.solver, options.margin_stop, knockdown, load_path_ok,
          part_solid, &gf.posture);
      gi.grading_recertified = true;
      gi.grading_recertified_margin = relat.margin_effective;
      gi.grading_recertified_accepted = relat.accepted;
      gi.grading_recertified_non_convergent = relat.non_convergent;
      gi.grading_recertified_max_von_mises = relat.max_von_mises;
      gi.grading_solid_margin = a.margin_effective;
      // ★ SAY IT OUT LOUD WHEN THE LATTICE CHANGES THE VERDICT. A part that passed
      // solid and fails latticed is the entire reason this solve exists, and it must
      // not be something a reader has to derive by comparing two numbers.
      gi.grading_recertify_changed_verdict = (a.accepted != relat.accepted);
    }
    gi.grading_recommended_layer_height_mm = gf.recommended_layer_height_mm;
    gi.grading_layer_height_bound_strut_mm = gf.layer_height_bound_strut_mm;
    gi.grading_layer_height_bound_overhang_mm = gf.layer_height_bound_overhang_mm;
    gi.grading_declared_layer_height_mm = job.loads.layer_height_mm;
    gi.grading_intent = grading_intent_name(gf.intent_used);
    gi.grading_aesthetic_percentile = gf.aesthetic_percentile_used;
    gi.grading_aesthetic_percentile_mpa = gf.aesthetic_percentile_mpa;
    gi.grading_aesthetic_rho_min = gf.aesthetic_rho_min_used;
    gi.grading_aesthetic_rho_max = gf.aesthetic_rho_max_used;
    gi.grading_aesthetic_weight_exponent = gf.aesthetic_weight_exponent_used;
    gi.grading_above_percentile_voxels =
        static_cast<long long>(gf.above_percentile_voxels);
    gi.grading_adaptive_cells_armed = gf.aesthetic_adaptive_cells_armed;
    gi.grading_adaptive_error_budget = gf.aesthetic_error_budget_used;
    gi.grading_adaptive_min_cells_allowed =
        gf.aesthetic_min_cells_per_member_allowed;
    gi.grading_below_accuracy_floor_voxels =
        static_cast<long long>(gf.aesthetic_below_accuracy_floor_voxels);
    if (gf.intent_used == GradingIntent::Aesthetic)
      gi.grading_density_meaning = kAestheticDensityMeaning;
    gi.grading_density_histogram.assign(
        gf.density_histogram, gf.density_histogram + GradedField::kDensityBins);
    gi.grading_solid_fallback_voxels =
        static_cast<long long>(gf.solid_fallback_voxels);
    gi.grading_min_member_width_mm = gf.min_member_width_mm;
    gi.grading_min_cells_per_member = gf.min_cells_per_member;
    gi.grading_min_strut_diameter_mm = gf.min_strut_diameter_mm;
    gi.grading_max_strut_diameter_mm = gf.max_strut_diameter_mm;
    gi.grading_any_strut_below_min = gf.any_strut_below_min;
    gi.grading_region_ungradeable = gf.region_ungradeable;
    fill_grading_cell_plan(gi, gf);
    fill_grading_fit(gi, gf, job, &an_roles);
    if (gp.cell_mode == CellSizeMode::Fit)
      fill_fit_region_voxels(gi, design_grid, density, 0.5, an_roles.includes, gf);
    fill_grading_subfloor(gi, gf);

    result.grading_run_info_path = join_path(out_dir, "run_info.json");
    write_run_info(result.grading_run_info_path, gi);
    result.graded = true;
  }

  // ── report.json (VariantReport schema — the NEW, re-analysed numbers) ────────
  const double part_dim_mm =
      std::max({static_cast<double>(design_grid.nx),
                static_cast<double>(design_grid.ny),
                static_cast<double>(design_grid.nz)}) *
      design_grid.spacing;
  VariantReport vr;
  vr.volume_fraction = a.printed_fraction;
  vr.printed_fraction = a.printed_fraction;
  vr.max_stress_mpa = a.max_von_mises;
  vr.max_interlayer_tension_mpa = a.max_interlayer_tension;
  vr.margin = a.margin;
  // The build direction IN THE FRAME OF THE EXPORTED MESH (handoff
  // 2026-08-01-bake-build-orientation) — see VariantReport::orientation. Off the
  // bake path this is `applied_build_dir` == `build_dir`, byte-identical.
  vr.export_baked = analyze_bake.has_value();
  vr.orientation_model = applied_build_dir;
  vr.orientation =
      vr.export_baked ? Vec3{0.0, 0.0, 1.0} : applied_build_dir;
  vr.settings =
      recommend_settings(rules, material.family, a.margin.worst_case, part_dim_mm);
  vr.min_feature_violations = a.v3.min_feature_violations;
  vr.min_feature_warning =
      min_feature_warning_text(rules, a.v3.min_feature_violations);
  vr.accepted = a.accepted;
  // The REQUIRED margin is the one the gate actually used (options.margin_stop):
  // job.margin_stop in self-weight mode (identical), the production default in
  // loadcase mode (the loads schema rejects a margin_stop key, so job.margin_stop
  // is unset there — reporting it would falsely show 0). Surfaced on the result so
  // the CLI prints the threshold the verdict was made against.
  const double margin_required = options.margin_stop;
  result.margin_required = margin_required;
  vr.margin_required = margin_required;
  vr.margin_effective = a.margin_effective;
  if (!a.accepted)
    vr.rejection_reason =
        load_path_ok ? kMarginBelowRequiredReason : kLoadPathNotConnectedReason;
  JobReport report;
  report.material = job.material;
  (a.accepted ? report.variants : report.rejected).push_back(vr);
  result.report_json = job_report_json(report);
  result.report_path = join_path(out_dir, "analysis_report.json");
  write_text_file(result.report_path, result.report_json);

  // The BUILD-ORIENTATION RECEIPT for this re-analysis — the same document the
  // optimize path writes, from the same emitter, so a part's ranking reads the
  // same whether it was just optimized or merely re-certified. Only when armed.
  if (a.build_orientation.evaluated) {
    result.build_orientation_path = join_path(out_dir, "build_orientation.json");
    // The receipt reports the APPLIED direction (the one the verdict and the
    // file both describe) and carries the export rotation, so every vector in
    // the document names its frame.
    result.build_orientation_json = build_orientation_report_json(
        a.build_orientation, applied_build_dir,
        analyze_bake ? &*analyze_bake : nullptr);
    write_text_file(result.build_orientation_path,
                    result.build_orientation_json);
  }

  // ── fields.bin (one analysed "variant", so app overlays light up) ────────────
  MinimizePlasticResult fields_result;
  fields_result.report.material = job.material;
  MinimizePlasticVariant fv;
  fv.requested_volume_fraction = a.printed_fraction;
  fv.accepted = a.accepted;
  fv.von_mises_field = a.von_mises_field;
  fv.stress_tensor_field = a.stress_tensor_field;
  fv.displacement_field = a.displacement_field;
  fv.mass_grams = a.mass_grams;
  fv.support_volume_voxels = a.support_volume_voxels;
  fv.report = vr;
  fields_result.evaluated.push_back(std::move(fv));
  result.fields_path = join_path(out_dir, "fields.bin");
  // accepted_only = false: the analyze field is served REGARDLESS of the margin
  // verdict (task analyze-loadcase-resolution, N3). Under the default filter a
  // REJECTED analyze wrote an empty container — the overlay went flat exactly
  // when the part was overstressed. The verdict still travels in the receipt.
  write_fields_file(result.fields_path, fields_result, design_grid,
                    /*accepted_only=*/false);

  // ── analysis.json — the PROVENANCE record (task items 3–5) ───────────────────
  // "smoothed / re-analyzed": analyzed=true, the source, the resolution, BOTH mass
  // figures, and the quantization footnote. The pre-analysis numbers NEVER appear.
  std::string prov;
  prov += "{\n";
  prov += "  \"provenance\": \"smoothed / re-analyzed\",\n";
  prov += "  \"analyzed\": true,\n";
  prov += "  \"optimization\": false,\n";
  // Stage 3 (task lattice-page-core-hookup) — the analyze route's honest label
  // (H3b/H3c): ONE linear analysis solve, no design loop, no variant meshes;
  // and the field's SCOPE, so the "this is the SOLID part's field — optimizing
  // invalidates it" statement travels WITH the result and cannot be lost in
  // transit (the app's RUN SIM gate states the same thing UI-side).
  prov += "  \"analysis_solves\": 1,\n";
  prov += "  \"variant_meshes_written\": 0,\n";
  prov += "  \"field_scope\": " +
          json_str(result.analyzed_mesh ? "substitute_mesh" : "solid_part") +
          ",\n";
  if (!result.analyzed_mesh)
    prov +=
        "  \"field_scope_note\": \"this stress/displacement field describes the "
        "SOLID part under the declared load case; a topology-optimized design "
        "has different geometry, so optimization INVALIDATES this field\",\n";
  prov += "  \"source\": " +
          json_str(result.analyzed_mesh ? ("mesh:" + analyze_mesh_path)
                                        : "model_solid") +
          ",\n";
  prov += "  \"model\": " + json_str(job.model) + ",\n";
  prov += "  \"resolution\": " + std::to_string(job.resolution) + ",\n";
  // Design box (task 2026-08-03-design-box-recertification) — emitted ONLY when
  // the run expanded, so a no-box provenance is byte-identical. It says which
  // grid this re-certification actually ran on, because "the part grid" and "the
  // solved grid" are different objects here and a reader must not have to guess:
  // a smoothed design-box variant is re-certified on the EXPANDED grid, so the
  // material the optimizer grew outside the part is certified, not clipped away.
  if (expand_for_mesh) {
    prov += "  \"design_box\": {\n";
    prov += "    \"expanded\": true,\n";
    prov += "    \"part_grid\": [" + std::to_string(model_grid.nx) + ", " +
            std::to_string(model_grid.ny) + ", " +
            std::to_string(model_grid.nz) + "],\n";
    prov += "    \"solved_grid\": [" + std::to_string(cert_grid.nx) + ", " +
            std::to_string(cert_grid.ny) + ", " + std::to_string(cert_grid.nz) +
            "],\n";
    prov += "    \"part_offset\": [" + std::to_string(domain.offset_i) + ", " +
            std::to_string(domain.offset_j) + ", " +
            std::to_string(domain.offset_k) + "],\n";
    prov += "    \"note\": \"the analysed geometry is voxelized onto the SOLVED "
            "grid and the declared load case is remapped onto it, so material "
            "grown outside the imported part is certified rather than clipped "
            "at the part's bounding box\"\n";
    prov += "  },\n";
  }
  prov += "  \"voxel_mass_grams\": " + json_num(result.voxel_mass_grams) + ",\n";
  prov += "  \"mesh_mass_grams\": " +
          (result.analyzed_mesh ? json_num(result.mesh_mass_grams)
                                : std::string("null")) +
          ",\n";
  // Load-case receipt (loadcase-analyze handoff) — emitted ONLY in loadcase mode,
  // so the self-weight provenance is byte-identical to before (L1). Records that
  // this re-analysis ran under a DECLARED external load (never self-weight), the
  // declared force groups + their resultant, the anchor count, and the number of
  // nodal loads the tractions produced — the honest counterpart to the self-weight
  // path's implicit "load_source": self_weight.
  if (loadcase) {
    Vec3 resultant{0.0, 0.0, 0.0};
    for (const JobLoadGroup& g : job.loads.groups) {
      resultant.x += g.force.x;
      resultant.y += g.force.y;
      resultant.z += g.force.z;
    }
    const double resultant_mag =
        std::sqrt(resultant.x * resultant.x + resultant.y * resultant.y +
                  resultant.z * resultant.z);
    prov += "  \"load_source\": \"loadcase\",\n";
    prov += "  \"load_groups\": " + std::to_string(job.loads.groups.size()) +
            ",\n";
    prov += "  \"anchor_faces\": " +
            std::to_string(result.fixture_face_ids.size()) + ",\n";
    prov += "  \"external_load_nodes\": " + std::to_string(loads.size()) + ",\n";
    prov += "  \"declared_force_resultant_n\": " + json_num(resultant_mag) + ",\n";
  }
  // Smoothing receipt (task items 1, 5; bars S2/S4) — emitted ONLY when smoothing
  // ran, so the analyse-only provenance is byte-identical to before (bar S6). Both
  // mass figures above already describe the SMOOTHED mesh in this branch.
  if (result.smoothed) {
    const SmoothStats& s = result.smooth_stats;
    prov += "  \"smoothed\": true,\n";
    prov += "  \"smooth_strength\": " + json_num(result.smooth_strength) + ",\n";
    prov += "  \"smooth_pairs_requested\": " +
            std::to_string(s.requested_pairs) + ",\n";
    prov += "  \"smooth_pairs_applied\": " + std::to_string(s.applied_pairs) +
            ",\n";
    prov += "  \"frozen_vertices\": " + std::to_string(s.frozen_vertices) + ",\n";
    prov += "  \"total_vertices\": " + std::to_string(s.total_vertices) + ",\n";
    prov += "  \"volume_before_mm3\": " + json_num(s.volume_before_mm3) + ",\n";
    prov += "  \"volume_after_mm3\": " + json_num(s.volume_after_mm3) + ",\n";
    prov += "  \"volume_drift_fraction\": " + json_num(s.volume_drift_fraction) +
            ",\n";
    prov += "  \"volume_drift_bound\": " + json_num(s.volume_drift_bound) + ",\n";
    prov += "  \"min_feature_baseline\": " +
            std::to_string(s.min_feature_baseline) + ",\n";
    prov += "  \"min_feature_after\": " + std::to_string(s.min_feature_after) +
            ",\n";
    prov += "  \"min_feature_limited\": " +
            std::string(s.min_feature_limited ? "true" : "false") + ",\n";
    prov += "  \"smoothed_mesh\": " + json_str(result.smoothed_mesh_path) + ",\n";
  }
  prov += "  \"max_stress_mpa\": " + json_num(a.max_von_mises) + ",\n";
  prov += "  \"margin_worst_case\": " + json_num(a.margin.worst_case) + ",\n";
  prov += "  \"margin_required\": " + json_num(margin_required) + ",\n";
  prov += "  \"margin_effective\": " + json_num(a.margin_effective) + ",\n";
  prov += "  \"accepted\": " + std::string(a.accepted ? "true" : "false") + ",\n";
  prov += "  \"min_feature_violations\": " +
          std::to_string(a.v3.min_feature_violations) + ",\n";
  prov +=
      "  \"quantization_note\": \"Re-analysis runs on the "
      "voxelization of the analyzed mesh at the grid resolution, so the analyzed "
      "and printed geometry differ by up to ~half a voxel. The stress margin and "
      "voxel mass describe the voxel proxy; the mesh mass is the surface-enclosed "
      "volume.\"\n";
  prov += "}\n";
  result.provenance_path = join_path(out_dir, "analysis.json");
  write_text_file(result.provenance_path, prov);

  return result;
}

// ---------------------------------------------------------------------------
// lattice_variant_job — LATTICE A FINISHED VARIANT (task
// 2026-08-02-lattice-a-variant). See job.hpp for the contract.
LatticeVariantJobResult lattice_variant_job(const JobDescription& job,
                                            const std::string& job_dir,
                                            const std::string& out_dir,
                                            const MaterialLibrary& materials,
                                            const SettingsRules& rules) {
  const double t_start = wall_seconds();
  // ★ TWO MODES, ONE PIPELINE (task 2026-08-17-lattice-stage-repair).
  // "lattice_variant" lattices a FINISHED design read from a design.bin;
  // "lattice_part" lattices the IMPORTED PART with no optimization at all
  // (maintainer: "a 'Lattice This' button ... which only lattices the selection
  // and does not optimize"). Everything below is shared — the load case, the
  // certification solves, the grading law, the mesh emission. The ONLY
  // difference is where the density field comes from, and it is one branch.
  const bool lattice_the_part = (job.mode == "lattice_part");
  if (job.mode != "lattice_variant" && !lattice_the_part)
    throw JobError(
        "lattice_variant_job: mode must be \"lattice_variant\" or "
        "\"lattice_part\" (got \"" +
        job.mode + "\")");
  if (!lattice_the_part && !job.variant.present)
    throw JobError("lattice_variant_job: the job carries no \"variant\" block");
  if (!job.lattice.present)
    throw JobError("lattice_variant_job: the job carries no \"lattice\" block");
  // The SAME pre-flight refusals the optimize path applies to a lattice job, for
  // the same reasons (E5, and grading-with-a-box). Stated here too rather than
  // inherited by accident: this entry point never calls run_job. The blanket
  // design-box refusal that used to sit here is gone — the remap it named now
  // exists, ONCE, in core (resolve_design_domain), and this entry point calls it
  // below like every other site (task 2026-08-03-design-box-recertification).
  if (job.grading.present && job.has_design_box)
    throw JobError(
        "lattice_variant: a \"grading\" block is not yet supported together with "
        "a \"design_box\" — the grading law chooses its cell plan before the "
        "added-material policy runs, so a graded design-box run could emit struts "
        "into cells the certificate calls solid. Re-lattice with a uniform cell + "
        "strut radius instead.");
  if (!job.grading.present) {
    const double lat_rho =
        octet_relative_density(job.lattice.cell_mm, job.lattice.strut_radius_mm);
    const double lo = lattice_rho_min(LatticeTopology::Octet);
    const double hi = lattice_rho_max(LatticeTopology::Octet);
    if (lat_rho < lo || lat_rho > hi)
      throw JobError(
          "lattice cell_mm " + std::to_string(job.lattice.cell_mm) +
          " / strut_radius_mm " + std::to_string(job.lattice.strut_radius_mm) +
          " implies octet relative density " + std::to_string(lat_rho) +
          ", outside the certifiable band [" + std::to_string(lo) + ", " +
          std::to_string(hi) + "].");
  }
  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;
#ifndef TOPOPT_HAVE_3MF
  if (job.lattice.emit_3mf)
    throw JobError(
        "this build has no 3MF support (lib3mf was not available): "
        "lattice.emit_3mf cannot be written, use emit_stl");
#endif

  LatticeVariantJobResult result;

  // ── import the ORIGINAL model. The BCs are keyed on ITS faces — which is the
  // whole reason this job takes the original model plus a stored design rather
  // than the variant's exported mesh (a TO surface has no faces to select).
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh = part_format_for_path(job.model) != PartFormat::Step;
  try {
    result.model = import_part_file_resolved(model_path);
  } catch (const std::exception& e) {
    throw JobError(std::string("lattice_variant: cannot import model: ") +
                   e.what());
  }
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("lattice_variant: model tessellation is not watertight: " +
                   job.model);

  // ── the load case, rebuilt from THIS JOB — which is the original run's job
  // (the schema requires the variant block to live in it). Same mapping, same
  // core builder, same receipt emitter as the optimize path.
  VoxelGrid model_grid;
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;
  const bool loadcase = job.loads.present;
  std::vector<NodalLoad> external_loads;
  std::string loadcase_receipt;

  if (loadcase) {
    const ProductionLoadCase lc = production_loadcase_from_job(job, result.model);
    result.fixture_face_ids = lc.anchor_face_ids;
    ProductionRunSetup setup;
    try {
      setup = build_production_loadcase(result.model, job.resolution, lc);
    } catch (const JobError&) {
      throw;
    } catch (const std::exception& e) {
      throw JobError(std::string("lattice_variant: cannot build the declared "
                                 "load case against model \"") +
                     job.model + "\": " + e.what());
    }
    if (setup.options.require_external_loads &&
        setup.options.external_loads.empty())
      throw JobError(
          "lattice_variant: the declared load case produced NO external load — " +
          no_external_load_message(setup, job.resolution) +
          ". Refusing to lattice under SELF-WEIGHT instead of the declared "
          "load (that silent fallback is the PR-178 param-drop bug).");
    model_grid = setup.grid;
    bcs = setup.bcs;
    options = setup.options;
    external_loads = options.external_loads;
    loadcase_receipt =
        loadcase_receipt_json(job, &setup, result.fixture_face_ids, 0, bcs);
  } else {
    model_grid = voxelize(result.model.mesh, job.resolution);
    result.fixture_face_ids =
        resolve_selectors(result.model, job.fixture_faces, "fixture_faces");
    std::size_t tagged = 0;
    for (const int f : result.fixture_face_ids)
      tagged += model_is_mesh
                    ? tag_mesh_face(model_grid, result.model, f, VoxelTag::Fixture)
                    : tag_step_face(model_grid, result.model, f, VoxelTag::Fixture);
    if (tagged == 0)
      throw JobError(
          "lattice_variant: fixture faces tagged no voxels (resolution too "
          "coarse for the selected faces?)");
    for (const int n : fea_tagged_nodes(model_grid, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    configure_production_options(options);
    options.margin_stop = job.margin_stop;
    options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
    options.gravity_direction = job.gravity.direction;
    loadcase_receipt =
        loadcase_receipt_json(job, nullptr, result.fixture_face_ids, tagged, bcs);
    // Optional design-domain expansion (the "add material" feature) — the
    // SELF-WEIGHT branch's counterpart of what build_production_loadcase already
    // put on `options` in the loadcase branch. Without this the box would be
    // silently dropped on this path and the stored design's grid check below
    // would report a mismatch it could not explain.
    if (job.has_design_box) {
      options.design_box = to_design_box(job.design_box);
      for (const JobBox& ko : job.keep_out_boxes)
        options.keep_out_boxes.push_back(to_design_box(ko));
    }
  }
  apply_build_direction_options(options, job);

  // ── THE domain the ORIGINAL run solved on, rebuilt through the SAME core call
  // that run used (resolve_design_domain, pipeline.hpp): the expanded grid and
  // the BCs/loads remapped onto it under a design box, the caller's inputs
  // verbatim without one. This is what makes a design-box run re-latticeable —
  // the refusal this entry point used to carry existed precisely because this
  // reconstruction had no remap (task 2026-08-03-design-box-recertification).
  const SolvedDesignDomain domain = resolve_design_domain(model_grid, bcs, options);
  const VoxelGrid& cert_grid = domain.grid;

  // ── the STORED DESIGN. Read before any solve, so a bad reference costs
  // nothing.
  DesignStore store;
  if (lattice_the_part) {
    // ★ THE PART IS THE DESIGN. Every voxel the part occupies is solid; nothing
    // was optimized away because nothing was optimized. Built on `cert_grid`, so
    // the grid check below is satisfied BY CONSTRUCTION rather than by luck —
    // and every voxel-indexed thing after it (the BCs, the tags, the mask, the
    // field) refers to the same geometry it would on a real design.
    //
    // ★ THE VOLUME FRACTION IS MEASURED, NOT ASSUMED: it is the part's own
    // occupancy of its grid. Reporting 1.0 would claim the bounding box is
    // solid, and every downstream mass and saving would be wrong by that ratio.
    store.nx = cert_grid.nx;
    store.ny = cert_grid.ny;
    store.nz = cert_grid.nz;
    store.spacing = cert_grid.spacing;
    store.origin = cert_grid.origin;
    StoredDesign d;
    d.density.assign(cert_grid.voxel_count(), 0.0);
    std::size_t solid = 0;
    for (int k = 0; k < cert_grid.nz; ++k)
      for (int j = 0; j < cert_grid.ny; ++j)
        for (int i = 0; i < cert_grid.nx; ++i)
          if (cert_grid.solid(i, j, k)) {
            d.density[cert_grid.index(i, j, k)] = 1.0;
            ++solid;
          }
    if (solid == 0)
      throw JobError(
          "lattice_part: the part occupies no voxels at this resolution — there "
          "is nothing to lattice");
    d.achieved_volume_fraction =
        static_cast<double>(solid) / static_cast<double>(cert_grid.voxel_count());
    d.requested_volume_fraction = d.achieved_volume_fraction;
    d.accepted = true;
    d.fingerprint = design_fingerprint(d.density);
    store.variants.push_back(std::move(d));
  } else {
    const std::string design_path = join_path(job_dir, job.variant.design);
    try {
      store = read_design_file(design_path);
    } catch (const std::exception& e) {
      throw JobError(std::string("lattice_variant: cannot read the stored design "
                                 "\"") +
                     job.variant.design + "\": " + e.what());
    }
    if (store.variants.empty())
      throw JobError("lattice_variant: \"" + job.variant.design +
                     "\" contains no variant designs");
  }
  // The stored design must index to THIS job's SOLVED grid, or every
  // voxel-indexed thing below (the BCs, the tags, the mask, the field) refers to
  // a different geometry. Compared exactly — a grid that is merely close is a
  // different grid. design.bin's header names the grid the run SOLVED on
  // (write_design_file takes solved_grid), which under a design box is the
  // EXPANDED grid — so the comparison is against `cert_grid`, rebuilt through the
  // same expansion. Off the box path cert_grid IS model_grid, byte-identical.
  if (store.nx != cert_grid.nx || store.ny != cert_grid.ny ||
      store.nz != cert_grid.nz || store.spacing != cert_grid.spacing ||
      store.origin.x != cert_grid.origin.x ||
      store.origin.y != cert_grid.origin.y ||
      store.origin.z != cert_grid.origin.z)
    throw JobError(
        "lattice_variant: the stored design's grid does not match this job's. "
        "Stored " + std::to_string(store.nx) + "x" + std::to_string(store.ny) +
        "x" + std::to_string(store.nz) + " @ spacing " +
        std::to_string(store.spacing) + "; this job builds " +
        std::to_string(cert_grid.nx) + "x" + std::to_string(cert_grid.ny) +
        "x" + std::to_string(cert_grid.nz) + " @ spacing " +
        std::to_string(cert_grid.spacing) +
        (domain.expanded ? " (the design box's EXPANDED grid; the part grid is " +
                               std::to_string(model_grid.nx) + "x" +
                               std::to_string(model_grid.ny) + "x" +
                               std::to_string(model_grid.nz) + ")"
                         : "") +
        ". The model, resolution and design box must be the ones the design was "
        "produced from.");

  // Select the variant. NO nearest-rung matching: latticing a rung the user did
  // not name is exactly the silent surprise this whole job exists to remove.
  //
  // ★ `lattice_part` SELECTS NOTHING — the store it built holds exactly one
  // design, the part itself, and there is no rung to name. The selection below
  // (and the achieved-fraction cross-check after it, which compares against a
  // number the front-end read from a report that does not exist here) applies
  // only to the variant path.
  // -1 is the NOT-FOUND sentinel the fingerprint and fraction branches below
  // test against; it must stay -1 here or a non-match would silently lattice
  // variant 0 instead of refusing.
  int pick = -1;
  if (lattice_the_part) {
    pick = 0;                       // the single synthesised design
  } else if (job.variant.has_index) {
    if (job.variant.index >= static_cast<int>(store.variants.size()))
      throw JobError("lattice_variant: variant index " +
                     std::to_string(job.variant.index) + " but \"" +
                     job.variant.design + "\" holds only " +
                     std::to_string(store.variants.size()) + " design(s)");
    pick = job.variant.index;
  } else if (job.variant.has_fingerprint) {
    // BY IDENTITY (task 2026-08-04-variant-volume-fraction-mismatch). The design
    // fingerprint is the hash of the density field itself, so this asks "the
    // design that hashes to X", not "whatever sits at position/rung X" — the
    // only form of the question that is well posed on BOTH ladders, and the same
    // number bar Z3 uses to tie the certified object to the exported one.
    for (std::size_t i = 0; i < store.variants.size(); ++i)
      if (store.variants[i].fingerprint == job.variant.fingerprint) {
        pick = static_cast<int>(i);
        break;
      }
    if (pick < 0) {
      std::string have;
      for (std::size_t i = 0; i < store.variants.size(); ++i)
        have += (i ? ", " : "") +
                std::to_string(store.variants[i].fingerprint) + " (rung " +
                json_num(store.variants[i].requested_volume_fraction) + ")";
      throw JobError(
          "lattice_variant: no stored design with fingerprint " +
          std::to_string(job.variant.fingerprint) + " in \"" +
          job.variant.design + "\" (it holds: " + have +
          "). The design container is not the one that produced this variant.");
    }
  } else {
    for (std::size_t i = 0; i < store.variants.size(); ++i)
      if (store.variants[i].requested_volume_fraction ==
          job.variant.volume_fraction) {
        pick = static_cast<int>(i);
        break;
      }
    if (pick < 0) {
      std::string have;
      for (std::size_t i = 0; i < store.variants.size(); ++i)
        have += (i ? ", " : "") +
                json_num(store.variants[i].requested_volume_fraction);
      throw JobError("lattice_variant: no stored design at volume fraction " +
                     json_num(job.variant.volume_fraction) + " in \"" +
                     job.variant.design + "\" (it holds: " + have + ")");
    }
  }
  const StoredDesign& sd = store.variants[static_cast<std::size_t>(pick)];
  // BAR A3, ENFORCED (task 2026-08-04-variant-volume-fraction-mismatch). When
  // the job carries the variant's own achieved fraction, it must be the one the
  // design actually achieved. A front-end that showed the user one number and
  // latticed a design with another is the certified-object-is-not-the-exported-
  // object failure in its cheapest-to-catch form, so it is caught here rather
  // than trusted.
  //
  // *** WHY THIS IS NOT AN EXACT COMPARISON, WHEN THE MARGIN REPRODUCTION BELOW
  // IS. *** The margin reproduction compares two f64s that both exist at full
  // precision: one read from design.bin, one just computed. This compares a
  // design.bin f64 against a number that reached the front-end THROUGH
  // report.json, and `json_num` writes 10 significant digits — the app is handed
  // 0.6686514886 for a design that achieved 0.6686514886164624. An exact
  // comparison here would refuse every honest job on the shipping path while
  // catching nothing. The wire's own precision is therefore the bar: 1e-9
  // relative is ~20x the worst truncation error and ~8 orders of magnitude
  // tighter than the gap between two adjacent ladder rungs, so it cannot confuse
  // one variant with another — which is the whole thing it exists to catch.
  const double kAchievedWireTolerance = 1e-9;   // relative; report.json is 10 s.f.
  if (!lattice_the_part && job.variant.has_achieved_volume_fraction &&
      std::abs(job.variant.achieved_volume_fraction -
               sd.achieved_volume_fraction) >
          kAchievedWireTolerance * std::abs(sd.achieved_volume_fraction))
    throw JobError(
        "lattice_variant: the job says this variant achieved volume fraction " +
        json_num(job.variant.achieved_volume_fraction) +
        ", but the stored design achieved " +
        json_num(sd.achieved_volume_fraction) +
        " (rung " + json_num(sd.requested_volume_fraction) +
        "). The job is describing a different variant than the one it selected.");
  result.variant_index = pick;
  result.requested_volume_fraction = sd.requested_volume_fraction;
  result.achieved_volume_fraction = sd.achieved_volume_fraction;
  result.optimizer_iterations = sd.iterations;
  result.design_fingerprint = sd.fingerprint;
  result.recorded_margin_worst_case = sd.margin_worst_case;

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ARCHITECTURE §4, matching the run's cert solve

  // The certification grid is the run's SOLVED grid (`cert_grid` — the model
  // grid, or the design box's expanded grid), with the design carried entirely
  // by the density field (analyze_fixed_design's printed set is density > 0.5).
  // Using a re-tagged occupancy grid instead would change the part-solid
  // denominator and the self-weight assembly, i.e. would not reproduce the run.
  //
  // The orientation is the one the run APPLIED to this variant, read from the
  // store rather than re-derived: the recorded margin is a margin AT an
  // orientation (see design_store.hpp).
  const Vec3 build_dir = sd.applied_build_dir;
  // THE ONE load-case definition, shared with minimize_plastic and with the
  // optimize path's lattice certification: the declared external load REMAPPED
  // onto the solved grid, else self-weight on that grid. Off the design-box path
  // this is `external_loads`, else self-weight over `model_grid`, exactly as
  // before; on it, this is the remap whose absence forced the old refusal.
  // (Spelled in prose, not as a call: test_selfweight_clearance_void SW2 reads
  // this file and requires exactly ONE self_weight_loads call to survive in it.)
  const std::vector<NodalLoad> loads =
      design_domain_loads(domain, options, material.density_g_cm3);
  const bool load_path_ok = load_path_connected(cert_grid, sd.density, 0.5);
  const KnockdownSpec knockdown = knockdown_spec_for(options);
  // The PART's solid count — minimize_plastic's ladder denominator (handoff
  // 080), which under expansion is NOT cert_grid.solid_count().
  const double part_solid = static_cast<double>(model_grid.solid_count());

  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("lattice_variant: cannot create output directory " +
                     out_dir + ": " + ec.message());
  }
  result.loadcase_receipt_path = join_path(out_dir, "loadcase.json");
  result.loadcase_receipt_json = loadcase_receipt;
  write_text_file(result.loadcase_receipt_path, loadcase_receipt);

  // ══ THE PRE-FLIGHT FORECAST (task 2026-08-03-variant-postprocessing-fix,
  //    defect 2 / bar F3) ═══════════════════════════════════════════════════════
  //
  // Everything a user needs to decide whether latticing this variant is worth a
  // run is computable HERE, from the stored design and the job's own lattice
  // block, with NO FEA at all: the grading law is pure geometry over the density
  // field. Before this task those same numbers existed only in the receipt of a
  // run that had already happened — which is how the maintainer came to spend an
  // hour of Mac time to be told that 10,403 of 10,485 region voxels stayed solid.
  //
  // `forecast_only` runs exactly the front half of this function and stops before
  // the first solve. What it reports is what the real run WOULD report, because
  // it is the same call on the same inputs — with ONE stated approximation, the
  // demand field (see below).
  if (job.lattice.forecast_only) {
    result.forecast_json = lattice_forecast_json(
        job, cert_grid, sd, lattice_keep_outs_from_job(job, result.model),
        lattice_role_regions_from_job(job, &result.model, &model_grid));
    result.forecast_path = join_path(out_dir, "lattice_forecast.json");
    write_text_file(result.forecast_path, result.forecast_json);
    return result;
  }

  // ── SOLVE 1: the null-posture (SOLID) certification of the restored design.
  //
  // This is the reproduction PROOF. analyze_fixed_design is the same function
  // minimize_plastic's per-rung certification calls (analyze.hpp's
  // single-source-of-truth contract), so handed this variant's OWN density on
  // the SAME grid, BCs, loads, params and solver, it must return the margin the
  // run RECORDED. If it does not, something in the chain — the load case, the
  // grid, the material, the stored field — is not the one that produced the
  // variant, and every number after this point would describe a different
  // object. So this is ENFORCED, not reported.
  result.solid = analyze_fixed_design(
      cert_grid, params, sd.density, domain.bcs, loads, material, build_dir,
      options.simp.cg_tolerance, options.simp.cg_max_iterations,
      options.simp.solver, options.margin_stop, knockdown, load_path_ok,
      part_solid, /*lattice=*/nullptr, options.build_orientation_report,
      resolve_build_direction_is_inferred(options),
      /*auto_apply_build_orientation=*/false);
  ++result.analysis_solves;
  result.reproduced_margin_worst_case = result.solid.margin.worst_case;
  result.reproduction_exact =
      (result.solid.margin.worst_case == sd.margin_worst_case);
  // ★ THE RELAXATION, AND WHAT IT IS FOR (task
  //   2026-08-08-lattice-variant-margin-tolerance, S1(b)). This comparison was a
  //   bare `==` on a double, and under it this entry point REFUSED all four rungs
  //   of the maintainer's own run — the run it was built to re-lattice. The cause
  //   is not the design and not the load case: the RECORDED margin was produced by
  //   a ladder certification solve carrying a warm Krylov recycle subspace, and
  //   every re-certification — this one included — is denied that subspace by
  //   ScopedLadderSolverIsolation. Two Krylov paths, one operator, both stopped at
  //   the same relative residual. The band is a multiple of THAT tolerance, so it
  //   is derived from the cause rather than fitted to the symptom; analyze.hpp
  //   carries the derivation and the measured separation from a real corruption.
  //
  //   The protection is unchanged in kind: a mismatch still means the load case,
  //   the grid or the design is not the one that produced this variant, and it
  //   still refuses. The smallest such change measured moves the margin two orders
  //   of magnitude further than the band.
  result.reproduction_band =
      kMarginReproductionResidualFactor * options.simp.cg_tolerance;
  result.reproduction_relative_delta = margin_reproduction_relative_delta(
      sd.margin_worst_case, result.solid.margin.worst_case);
  result.reproduction_within_band =
      margin_reproduces(sd.margin_worst_case, result.solid.margin.worst_case,
                        options.simp.cg_tolerance);
  if (result.solid.non_convergent)
    throw JobError(
        "lattice_variant: the certification solve of the stored design did not "
        "converge (iteration " +
        std::to_string(result.solid.non_convergent_iteration) + ", residual " +
        json_num(result.solid.non_convergent_residual) +
        "). A design whose certification solve the CG cannot resolve is never "
        "certified, and so is never latticed.");
  // ★ THE REPRODUCTION CHECK IS A VARIANT-PATH GUARD, AND ONLY THAT (task
  // 2026-08-17-lattice-stage-repair). It asks "does the design I read back still
  // produce the margin its run RECORDED" — a question about a stored record. A
  // `lattice_part` design was synthesised from the part a moment ago and has no
  // recorded margin to disagree with, so the comparison would be against 0 and
  // would refuse every honest job. The certification solve above still RUNS and
  // its non-convergence refusal above still applies: what is skipped is the
  // comparison to a record that does not exist, not the certification.
  if (!lattice_the_part && !result.reproduction_within_band)
    throw JobError(
        "lattice_variant: the restored design does NOT reproduce the margin the "
        "run recorded for this variant (recorded " +
        json_num(sd.margin_worst_case) + ", reproduced " +
        json_num(result.solid.margin.worst_case) + ", relative difference " +
        json_num(result.reproduction_relative_delta) + " against a band of " +
        json_num(result.reproduction_band) +
        "). That means the load case, the grid or the design is not the one "
        "that produced this variant — refusing to lattice it, because the "
        "certificate would describe a different object than the run's.");

  // ── the synthetic variant the shared pipeline consumes. Every field is
  // either the STORED design's own record or the reproduction solve's output —
  // nothing invented. The shell mesh the export pushes is `v3.mesh`, which the
  // reproduction solve extracted from this very density field, so the solid
  // shell in the latticed file is this design's own iso-surface.
  MinimizePlasticVariant v;
  v.requested_volume_fraction = sd.requested_volume_fraction;
  v.optimization.physical_density = sd.density;
  v.optimization.volume_fraction = sd.achieved_volume_fraction;
  v.optimization.iterations = sd.iterations;
  v.v3 = result.solid.v3;
  v.accepted = result.solid.accepted;
  v.von_mises_field = result.solid.von_mises_field;
  v.stress_tensor_field = result.solid.stress_tensor_field;
  v.displacement_field = result.solid.displacement_field;
  v.mass_grams = result.solid.mass_grams;
  v.support_volume_voxels = result.solid.support_volume_voxels;
  // The orientation and the export frame are the RUN's, carried in the store —
  // so the latticed file this job writes is placed exactly the way the run
  // placed that variant's solid mesh, and the two describe the same object.
  v.applied_build_dir = sd.applied_build_dir;
  v.build_direction_auto_applied = sd.build_direction_auto_applied;
  v.export_baked = sd.export_baked;

  const double part_dim_mm =
      // The SOLVED grid's largest bounding-box edge — the same quantity
      // minimize_plastic derives its settings size class from (it uses `G`, the
      // expanded grid under a design box), so the recommended settings this job
      // reports are the run's own. Identical to model_grid off the box path.
      std::max({static_cast<double>(cert_grid.nx),
                static_cast<double>(cert_grid.ny),
                static_cast<double>(cert_grid.nz)}) *
      cert_grid.spacing;
  VariantReport vr;
  vr.volume_fraction = result.solid.printed_fraction;
  vr.printed_fraction = result.solid.printed_fraction;
  vr.max_stress_mpa = result.solid.max_von_mises;
  vr.max_interlayer_tension_mpa = result.solid.max_interlayer_tension;
  vr.margin = result.solid.margin;
  // The build direction IN THE FRAME OF THE EXPORTED MESH (the same convention
  // the optimize and analyze paths use): +Z when the file is baked, the model
  // direction otherwise.
  vr.export_baked = sd.export_baked;
  vr.orientation_model = sd.applied_build_dir;
  vr.orientation = sd.export_baked ? Vec3{0.0, 0.0, 1.0} : sd.applied_build_dir;
  vr.settings = recommend_settings(rules, material.family,
                                   result.solid.margin.worst_case, part_dim_mm);
  vr.min_feature_violations = result.solid.v3.min_feature_violations;
  vr.min_feature_warning =
      min_feature_warning_text(rules, result.solid.v3.min_feature_violations);
  vr.accepted = result.solid.accepted;
  vr.margin_required = options.margin_stop;
  vr.margin_effective = result.solid.margin_effective;
  if (!result.solid.accepted)
    vr.rejection_reason =
        load_path_ok ? kMarginBelowRequiredReason : kLoadPathNotConnectedReason;
  v.report = vr;

  // ── the SHARED per-variant lattice pipeline. Same body the optimize path
  // runs, so the mask that certifies and the mask that emits are the same
  // object (Z3) and the strut-strength report rides the composite solve (Z5).
  const std::vector<ClearanceGeometry> lattice_kos =
      lattice_keep_outs_from_job(job, result.model);
  const LatticeRoleRegions lattice_roles =
      lattice_role_regions_from_job(job, &result.model, &model_grid);
  const LatticeVariantOutcome R =
      lattice_one_variant(v, job, model_grid, domain, options, material,
                          lattice_kos, lattice_roles, out_dir);
  // BAR B3 / L3 (task 2026-08-04-variant-volume-fraction-mismatch). This entry
  // point exists to produce ONE latticed object. If the grading law could
  // lattice nothing, there is no object — and the alternative the optimize path
  // takes (skip this rung, keep the others) has no meaning here. So it refuses,
  // with the predicate and the counts, rather than writing a file with zero
  // struts in it and reporting a successful build.
  if (R.ungradeable)
    throw JobError("lattice_variant: " + R.ungradeable_reason);
  // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
  // Same shape, same reason: this entry point exists to produce ONE latticed
  // object, and the object it would produce is one nothing can ever be emptied
  // from. Nothing was written — `lattice_one_variant` returned before the
  // generator ran — so there is no half-object to clean up.
  if (R.void_sealed)
    throw JobError("lattice_variant: " + R.void_sealed_reason);
  // The pipeline's own solve count: the null-posture reproduction it runs as
  // its internal proof, the composite, and (when band clamping happened) the
  // clamp counterfactual. Counted, never assumed.
  result.analysis_solves += 2;
  if (R.grad_rcpt.clamp_counterfactual_ran) ++result.analysis_solves;
  result.lattice = R.cc.lattice;
  result.mesh_paths = R.oc.paths;
  result.lattice_receipt_path = R.receipt_path;
  result.lattice_receipt_json = R.receipt_json;
  result.cell_size_mm = R.cell_mm;
  result.graded = R.graded;
  result.latticed_voxels = static_cast<long long>(R.cc.lattice.lattice_voxels);
  if (R.graded) {
    result.rho_min_used = R.gf.rho_min_used;
    result.rho_max_used = R.gf.rho_max_used;
  } else {
    result.rho_min_used = R.cc.rho;
    result.rho_max_used = R.cc.rho;
  }

  // THE DESIGN IDENTITY CHECK (bar Z3), stated as an equation rather than an
  // argument: the field the pipeline fingerprinted — the one it built the mesh
  // from AND handed to the composite certification — is the field that was
  // stored, which is the field the null-posture solve above reproduced the
  // recorded margin from. One number, three roles.
  if (R.design_fingerprint != sd.fingerprint)
    throw JobError(
        "lattice_variant: internal inconsistency — the design the lattice "
        "pipeline exported and certified does not hash to the stored design. "
        "Refusing to write a certificate for an object that is not the one on "
        "record.");

  // ── run_info.json carrying the grading record, from the SAME filler the
  // analyze path uses so the two receipts cannot drift.
  {
    RunInfo gi = build_run_info(job, options, RunObservability{});
    if (R.graded) {
      gi.grading_present = true;
      gi.grading_topology = lattice_topology_name(R.gf.posture.topology);
      gi.grading_band_rho_min = R.gf.band_rho_min;
      gi.grading_band_rho_max = R.gf.band_rho_max;
      gi.grading_cells_per_member_floor = R.gf.cells_per_member_floor;
      gi.grading_cell_size_mm = R.gf.cell_size_mm;
      gi.grading_printability_floor_mm = R.gf.printability_floor_mm;
      gi.grading_cell_size_floored = R.gf.cell_size_floored;
      gi.grading_min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
      gi.grading_rho_min_used = R.gf.rho_min_used;
      gi.grading_rho_max_used = R.gf.rho_max_used;
      gi.grading_region_voxels = static_cast<long long>(R.gf.region_voxels);
      gi.grading_latticed_voxels = static_cast<long long>(R.gf.latticed_voxels);
      gi.grading_solid_fallback_voxels =
          static_cast<long long>(R.gf.solid_fallback_voxels);
      gi.grading_min_member_width_mm = R.gf.min_member_width_mm;
      gi.grading_min_cells_per_member = R.gf.min_cells_per_member;
      gi.grading_min_strut_diameter_mm = R.gf.min_strut_diameter_mm;
      gi.grading_max_strut_diameter_mm = R.gf.max_strut_diameter_mm;
      gi.grading_any_strut_below_min = R.gf.any_strut_below_min;
      gi.grading_region_ungradeable = R.gf.region_ungradeable;
      fill_grading_cell_plan(gi, R.gf);
      fill_grading_fit(gi, R.gf, job, &lattice_roles);
      if (R.gf.cell_mode == CellSizeMode::Fit)
        fill_fit_region_voxels(gi, model_grid, sd.density,
                               run_printed_iso(options), lattice_roles.includes,
                               R.gf);
      fill_grading_subfloor(gi, R.gf);
    }
    result.run_info_path = join_path(out_dir, "run_info.json");
    write_run_info(result.run_info_path, gi);
  }

  // ── the report line: the LATTICED composite's numbers, never the solid
  // design's. The file this job writes is the latticed one, so the report
  // describes that one (the honesty rule).
  {
    VariantReport lvr = vr;
    lvr.volume_fraction = result.lattice.printed_fraction;
    lvr.printed_fraction = result.lattice.printed_fraction;
    lvr.max_stress_mpa = result.lattice.max_von_mises;
    lvr.max_interlayer_tension_mpa = result.lattice.max_interlayer_tension;
    lvr.margin = result.lattice.margin;
    lvr.margin_effective = result.lattice.margin_effective;
    lvr.accepted =
        result.lattice.accepted && job.lattice.outer_finish != "skin";
    lvr.min_feature_violations = result.lattice.v3.min_feature_violations;
    lvr.min_feature_warning = min_feature_warning_text(
        rules, result.lattice.v3.min_feature_violations);
    if (!lvr.accepted)
      lvr.rejection_reason = load_path_ok ? kMarginBelowRequiredReason
                                          : kLoadPathNotConnectedReason;
    JobReport report;
    report.material = job.material;
    (lvr.accepted ? report.variants : report.rejected).push_back(lvr);
    result.report_json = job_report_json(report);
    result.report_path = join_path(out_dir, "lattice_variant_report.json");
    write_text_file(result.report_path, result.report_json);
  }

  // ── fields.bin — the COMPOSITE solve's fields, so an app overlay drawn over
  // the latticed result describes the latticed object.
  {
    MinimizePlasticResult fr;
    fr.report.material = job.material;
    MinimizePlasticVariant fv;
    fv.requested_volume_fraction = sd.requested_volume_fraction;
    fv.accepted = result.lattice.accepted;
    fv.von_mises_field = result.lattice.von_mises_field;
    fv.stress_tensor_field = result.lattice.stress_tensor_field;
    fv.displacement_field = result.lattice.displacement_field;
    fv.mass_grams = result.lattice.mass_grams;
    fv.support_volume_voxels = result.lattice.support_volume_voxels;
    fr.evaluated.push_back(std::move(fv));
    result.fields_path = join_path(out_dir, "fields.bin");
    // accepted_only = false, for the reason the analyze route documents: the
    // field describes the object either way, and withholding it when the
    // verdict is REJECTED blanks the overlay exactly when it matters.
    // Indexed to the grid the fields were SOLVED on (`cert_grid` — the expanded
    // grid under a design box), which is also the grid design.bin and the run's
    // own fields.bin name. model_grid would be the PART grid, a different size.
    write_fields_file(result.fields_path, fr, cert_grid,
                      /*accepted_only=*/false);
  }

  result.wall_seconds = wall_seconds() - t_start;

  // ── the PROVENANCE record: what was latticed, from where, and — the bar this
  // job is measured against — that NO LADDER RAN.
  std::string prov = "{\n";
  prov += "  \"provenance\": \"latticed a finished variant\",\n";
  prov += "  \"optimization\": false,\n";
  prov += "  \"design_iterations\": 0,\n";
  prov += "  \"optimizer_iterations_run\": 0,\n";
  prov += "  \"variant_meshes_written\": 0,\n";
  prov += "  \"analysis_solves\": " + std::to_string(result.analysis_solves) +
          ",\n";
  prov +=
      "  \"analysis_solves_note\": \"certification solves only, no design "
      "loop: (1) the null-posture solve that reproduces this variant's RECORDED "
      "margin — the proof the load case and design are the originals; (2) the "
      "lattice pipeline's own null-posture reproduction; (3) the COMPOSITE "
      "certification; plus (4) the band-clamp counterfactual when any voxel "
      "was clamped\",\n";
  // The WALL TIME is deliberately NOT in this file. It is on the result and on
  // the CLI's own summary line, where it belongs; putting a measured duration
  // in a written artifact would make every output of this job differ between
  // two identical runs, and every file this job writes being byte-identical on
  // a rerun is the determinism bar (Z8).
  prov += "  \"source\": {\n";
  prov += "    \"design\": " + json_str(job.variant.design) + ",\n";
  prov += "    \"variant_index\": " + std::to_string(result.variant_index) +
          ",\n";
  prov += "    \"requested_volume_fraction\": " +
          json_num(result.requested_volume_fraction) + ",\n";
  prov += "    \"achieved_volume_fraction\": " +
          json_num(result.achieved_volume_fraction) + ",\n";
  prov += "    \"optimizer_iterations_originally\": " +
          std::to_string(result.optimizer_iterations) + ",\n";
  prov += "    \"design_fingerprint\": \"" +
          std::to_string(result.design_fingerprint) + "\",\n";
  prov +=
      "    \"field_provenance\": \"the demand field this lattice is graded "
      "from is THIS variant's own certification von Mises field, recovered by "
      "the reproduction solve below from the stored design — not a simulation "
      "of the solid part, and not another run's field\"\n";
  prov += "  },\n";
  prov += "  \"reproduction\": {\n";
  prov += "    \"recorded_margin_worst_case\": " +
          json_num(result.recorded_margin_worst_case) + ",\n";
  prov += "    \"reproduced_margin_worst_case\": " +
          json_num(result.reproduced_margin_worst_case) + ",\n";
  // Was hard-coded `"exact": true` under the old bare-`==` gate. It is now the
  // measured fact, and it is usually FALSE — see the band note in analyze.hpp.
  prov += "    \"exact\": " +
          std::string(result.reproduction_exact ? "true" : "false") + ",\n";
  prov += "    \"relative_delta\": " +
          json_num(result.reproduction_relative_delta) + ",\n";
  prov += "    \"band\": " + json_num(result.reproduction_band) + ",\n";
  prov +=
      "    \"note\": \"ENFORCED, not reported: a reproduction outside `band` "
      "throws and nothing is written. `band` is a multiple of the certification "
      "solve's own relative-residual tolerance, because the recorded margin came "
      "from a solve carrying a warm Krylov recycle subspace and this one is "
      "denied it by ScopedLadderSolverIsolation — two Krylov paths on one "
      "operator, so `exact` is false on any run whose solves fall back to "
      "Jacobi-CG\"\n";
  prov += "  },\n";
  prov += "  \"model\": " + json_str(job.model) + ",\n";
  prov += "  \"resolution\": " + std::to_string(job.resolution) + ",\n";
  prov += "  \"load_source\": " +
          json_str(loadcase ? "loadcase" : "self_weight") + ",\n";
  prov += "  \"loadcase_receipt\": \"loadcase.json\",\n";
  prov += "  \"lattice\": {\n";
  prov += "    \"topology\": " + json_str(job.lattice.topology) + ",\n";
  prov += "    \"graded\": " + std::string(result.graded ? "true" : "false") +
          ",\n";
  prov += "    \"cell_mm\": " + json_num(result.cell_size_mm) + ",\n";
  prov += "    \"rho_min_used\": " + json_num(result.rho_min_used) + ",\n";
  prov += "    \"rho_max_used\": " + json_num(result.rho_max_used) + ",\n";
  prov += "    \"latticed_voxels\": " + std::to_string(result.latticed_voxels) +
          ",\n";
  prov += "    \"solid_margin_worst_case\": " +
          json_num(result.solid.margin.worst_case) + ",\n";
  prov += "    \"lattice_margin_worst_case\": " +
          json_num(result.lattice.margin.worst_case) + ",\n";
  prov += "    \"lattice_margin_effective\": " +
          json_num(result.lattice.margin_effective) + ",\n";
  prov += "    \"lattice_accepted\": " +
          std::string((result.lattice.accepted &&
                       job.lattice.outer_finish != "skin")
                          ? "true"
                          : "false") +
          ",\n";
  // File names, NOT paths: every artifact named here is a sibling of this file,
  // and an absolute path would make two identical runs into two different
  // documents purely because they were told to write somewhere else.
  auto base_name = [](const std::string& p) {
    return std::filesystem::path(p).filename().string();
  };
  prov += "    \"receipt\": " + json_str(base_name(result.lattice_receipt_path)) +
          "\n";
  prov += "  },\n";
  prov += "  \"meshes\": [";
  for (std::size_t i = 0; i < result.mesh_paths.size(); ++i)
    prov += (i ? ", " : "") + json_str(base_name(result.mesh_paths[i]));
  prov += "]\n";
  prov += "}\n";
  result.provenance_path = join_path(out_dir, "lattice_variant.json");
  write_text_file(result.provenance_path, prov);

  return result;
}

namespace {

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
      tagged += model_is_mesh
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
  return S;
}

}  // namespace

PreflightJobResult preflight_job(const JobDescription& job,
                                 const std::string& job_dir,
                                 const MaterialLibrary& materials) {
  const double t0 = steady_clock_ms();
  PreflightJobResult out;
  if (job.mode != "minimize_plastic")
    throw JobError("preflight: unsupported mode: " + job.mode);
  if (materials.find(job.material) == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh = part_format_for_path(job.model) != PartFormat::Step;
  try {
    out.model = import_part_file_resolved(model_path);
  } catch (const PartError& e) {
    throw JobError(std::string("cannot import model \"") + job.model +
                   "\": " + e.what());
  }
  if (!check_watertight(out.model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);
  // THE ONE setup — the identical call run_job makes.
  JobSetup setup = build_job_setup(job, out.model, model_is_mesh, materials);
  out.fixture_face_ids = setup.fixture_face_ids;
  const SolvedDesignDomain domain =
      resolve_design_domain(setup.grid, setup.bcs, setup.options);
  out.preflight = preflight_load_path(domain, setup.options);
  out.would_refuse =
      out.preflight.walk.decidable && !out.preflight.walk.connected;
  if (out.would_refuse)
    out.refusal = preflight_refusal_report(out.model, setup.grid, domain,
                                           setup.options, setup.lc,
                                           out.preflight,
                                           out.fixture_face_ids);
  out.wall_ms = steady_clock_ms() - t0;
  return out;
}

RunJobResult run_job(const JobDescription& job, const std::string& job_dir,
                     const std::string& out_dir,
                     const MaterialLibrary& materials,
                     const SettingsRules& rules, bool emit_progress,
                     const RunObservability& obs) {
  // Fail fast on everything checkable before heavy work: the mode, the
  // material, and whether this build can write the requested mesh format.
  // MODE VALIDATION STAYS STRICT (H3a): run_job optimizes minimize_plastic jobs
  // and NOTHING else — an "analyze" job is one fixed-design solve and must go
  // through analyze_job (`topopt-cli analyze`; the LAN worker routes on the
  // job's mode), never be optimized here.
  if (job.mode != "minimize_plastic")
    throw JobError(
        job.mode == "analyze"
            ? std::string(
                  "unsupported mode for `run`: \"analyze\" is one fixed-design "
                  "analysis solve, not an optimization — run it with "
                  "`topopt-cli analyze <job.json>`")
            : "unsupported mode: " + job.mode);
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

  // The pre-flight region forecast's numbers (task 2026-08-04-protect-freeze-vs-
  // solidity, item 6), carried to run_info far below. Declared here because the
  // forecast runs BEFORE the import — that is the whole point of it.
  int fc_region_too_thin = 0, fc_include_regions = 0;
  double fc_required_mm = 0.0, fc_thinnest_mm = 0.0;

  // ──▶ Lattice pre-flight (handoff 2026-07-29-lattice-certification-e2e). Refuse
  // BEFORE any import / voxelize / solve — nothing is written — on the condition
  // the E2E certification cannot honor:
  //   * A density OUTSIDE the certifiable band (read from CORE — lattice_rho_min/max,
  //     not hardcoded). The band is a hard gate at certification (bar E5):
  //     analyze_fixed_design also throws LatticeDensityOutOfBand mid-run, but failing
  //     up front wastes no solve and names the band in the message.
  // Stage 4 (task lattice-page-core-hookup): grading on the OPTIMIZE path
  // requires a lattice block — without one there is nothing to grade into, and
  // silently ignoring the block is exactly the reported gap this closes.
  if (job.grading.present && !job.lattice.present)
    throw JobError(
        "a \"grading\" block on the optimize path requires a \"lattice\" block: "
        "run_job grades each accepted variant's lattice from that variant's own "
        "final stress field, so without a lattice there is nothing to grade "
        "into. Add a \"lattice\" block (without cell_mm/strut_radius_mm — the "
        "graded run derives those) or drop \"grading\".");
  // GRADING + a DESIGN BOX is refused, and this is a NARROWER refusal than the
  // one that stood before this task (which refused the whole design-box + lattice
  // combination). Reason, precisely: a graded run's cell PLAN comes from
  // grade_lattice, which runs before the added-material policy can speak, and the
  // SWEPT multilevel emission takes its per-level cell occupancy from that plan
  // rather than from the final certification mask. So on a graded design-box run
  // the generator could still write struts into cells the certificate calls
  // solid — the exact certified-object-is-not-the-exported-object failure the
  // uniform path just closed. Rather than ship a second shape of it, refuse until
  // the law's candidate set is made added-material-aware. Uniform lattice + a
  // design box is supported and tested.
  if (job.grading.present && job.has_design_box)
    throw JobError(
        "a \"grading\" block is not yet supported together with a \"design_box\": "
        "the grading law chooses its cell plan before the added-material policy "
        "runs, and the swept multilevel emission takes its cell occupancy from "
        "that plan rather than from the final certification mask — so a graded "
        "design-box run could emit struts into cells the certificate calls "
        "solid. Run the design-box lattice job WITHOUT grading (uniform cell + "
        "strut radius), or run the graded job without a design box.");
  if (job.lattice.present) {
    // A DESIGN BOX no longer refuses (task 2026-08-03-design-box-recertification).
    // The refusal existed because the latticed re-certification reconstructed the
    // load case at run_job level with NO remap onto the expanded grid — it was
    // protecting against a second reconstruction written on the assumption that
    // the grid never expands, not against something impossible. There is now ONE
    // remap (resolve_design_domain / design_domain_loads, pipeline.hpp) and both
    // the optimize path and this certification call it, so the load case cannot
    // be a different one. Material grown OUTSIDE the imported part is governed by
    // kDesignBoxAddedMaterialKeptSolid and reported per variant.
    //
    // The uniform-density band fast-fail. A GRADED run has no uniform
    // cell/radius (the schema rejects them); its per-voxel densities are
    // in-band by the grading law's construction (bar L2), and the band is
    // still enforced per voxel inside analyze_fixed_design (E5 / H4b).
    if (!job.grading.present) {
      const double lat_rho =
          octet_relative_density(job.lattice.cell_mm, job.lattice.strut_radius_mm);
      const double lo = lattice_rho_min(LatticeTopology::Octet);
      const double hi = lattice_rho_max(LatticeTopology::Octet);
      if (lat_rho < lo || lat_rho > hi)
        throw JobError(
            "lattice cell_mm " + std::to_string(job.lattice.cell_mm) +
            " / strut_radius_mm " + std::to_string(job.lattice.strut_radius_mm) +
            " implies octet relative density " + std::to_string(lat_rho) +
            ", outside the certifiable band [" + std::to_string(lo) + ", " +
            std::to_string(hi) +
            "]. The gate refuses to certify against a clamped tensor (bar E5); choose a "
            "strut radius whose density lands in the band.");
    }
    // ── PRE-FLIGHT FORECAST: CAN THIS REGION HOLD A LATTICE AT ALL? (task
    // 2026-08-04-protect-freeze-vs-solidity, item 6)
    //
    // THE SECOND REASON the maintainer's include regions produced nothing, and it
    // is PHYSICS, not a bug: his include regions are 4 mm-deep face slabs, and
    // the cells-per-member floor demands 5 cells × 4.6026 mm = 23.0 mm of member.
    // Separating "frozen" from "solid" does not touch that — a 4 mm slab cannot
    // hold a certifiable lattice at any depth he would want, and no rung, cell
    // size or tag change alters it.
    //
    // He should learn it BEFORE the run, so it is stated here: before any import,
    // voxelize or solve, from the declared geometry and the two constants alone.
    //
    // *** WHY THE REGION'S OWN EXTENT IS THE RIGHT THING TO MEASURE. *** The
    // certification mask lattices ONLY voxels inside the include union; material
    // outside it stays solid (the companion body). So the latticed body is a
    // SUBSET of the region, and its thinnest dimension is at most the region's
    // thinnest dimension. If that is under n* × cell, nothing inside the region
    // can hold n* cells across.
    //
    // *** AND WHY THIS IS A FORECAST, NOT A GATE. *** The grading law's own
    // too-thin test reads `local_member_thickness_mm`, which measures the
    // DESIGN's printed solid — it does not know the region restriction. On a
    // thick wall with a thin include slab the two disagree: the law sees the
    // wall's width and admits the voxel, while the body actually latticed is only
    // as deep as the slab. That is a real coherence gap (FILED, with the
    // reproduction, in the handoff §item-7b) and closing it MOVES the latticed
    // mask on existing paths, which this task's bar 5 makes a blocked-stop. So
    // this states the number and changes nothing.
    if (!job.lattice.regions.empty()) {
      const LatticeTopology topo = LatticeTopology::Octet;
      const double n_star = lattice_cells_per_member_min(topo);
      // The cell this run will actually use, by the SAME rules the law applies:
      // AUTO takes the printability floor, FIXED the target raised to the floor that
      // actually binds (S2), SWEPT the finest rung its OWN dyadic ladder can print
      // (S1, task 2026-08-07); a uniform job states its cell. FIT has NO single
      // planned cell — it derives one per region — so the scalar below carries the
      // FINEST derived cell and every table row uses that region's own.
      //
      // ★ THIS IS `planned_cell_mm`, CALLED — not copied. The two used to be duplicate
      // switches, and the duplication is exactly how the defect survived: task
      // 2026-08-05-lattice-cell-fit-mode's S2 corrected FIXED in both copies and left
      // SWEPT unchanged in both (commit 4032ce8, diff context lines 245/431).
      //
      // `swept_light_floor=false` is the S1 CORRECTION and it is the refusal path's
      // answer. `multiscale_floor_cell_mm` — the other caller — passes true and says
      // at length why: its value reaches geometry, and moving it flips a design on a
      // job that runs today. Nothing here reaches geometry, so nothing here is gated
      // on that decision.
      CellSizeMode pf_mode = CellSizeMode::Fixed;
      const bool pf_mode_known =
          !job.grading.present ||
          resolve_cell_mode(job.grading.cell_mode, pf_mode);
      (void)pf_mode_known;  // an unknown mode is refused by the grading call itself
      const bool pf_fit = job.grading.present && pf_mode == CellSizeMode::Fit;
      double cell_mm = job.lattice.cell_mm;
      double floor_mm = 0.0;
      std::vector<FitRegionCell> pf_fit_cells;
      if (job.grading.present) {
        floor_mm = lattice_cell_printability_floor_mm(
            topo, job.grading.min_extrudable_width_mm);
        if (pf_fit)
          // ★ NO `roles` HERE, AND THAT IS A REAL LIMIT, NOT AN OVERSIGHT: the
          // pre-flight runs BEFORE the import and before the grid exists, so a
          // region-backed include has no mask yet and no derivable extent. Such
          // regions are omitted from the forecast table below (and counted), and
          // the run's own per-region verdicts report them for real. See the
          // handoff §2(a) — closing this means voxelizing inside the pre-flight.
          pf_fit_cells = fit_region_cells(job, topo,
                                          job.grading.min_extrudable_width_mm);
        cell_mm = planned_cell_mm(job, /*swept_light_floor=*/false);
      }
      const double required_mm = n_star * cell_mm;
      // The stated bead width the derivation is evaluated at. A uniform job carries
      // it on the lattice block; a graded job on the grading block. 0 means the job
      // never stated one, and then no derivation is possible — the refusal below
      // does not fire and the forecast is all that is reported.
      const double w_min_fc = job.grading.present
                                  ? job.grading.min_extrudable_width_mm
                                  : job.lattice.min_extrudable_width_mm;
      // ── A SWEPT WINDOW WHOSE TOP IS UNDER THE PRINTABLE FRONTIER (found by this
      // task's own R3 table, case S_underfrontier).
      //
      // Every rung of the ladder is `cell_min_mm * 2^L <= cell_max_mm`, so if
      // `cell_max_mm` itself is below `w / phi(rho_max)` then NO rung prints at any
      // density in the band. The plan drops every base cell as unprintable, the run
      // emits no lattice, and the solve is spent for nothing — which is exactly the
      // outcome this pre-flight exists to predict.
      //
      // ★ REPORTED, NOT REFUSED, and the distinction is deliberate. Refusing it would
      // be a NEW refusal on jobs that run today: before S1 the planned cell here was
      // the LIGHT floor, so a job whose regions cleared percolation against that
      // number ran to completion (emitting nothing). This task's R3 makes a new
      // refusal on such a job a blocked-stop, so the pre-flight says the sentence and
      // changes no verdict. Turning it into a refusal is a one-line change behind its
      // own gate table.
      std::string swept_unprintable_note;
      if (job.grading.present && pf_mode == CellSizeMode::Swept && w_min_fc > 0.0) {
        const double frontier_mm =
            w_min_fc / octet_strut_diameter_mm(lattice_rho_max(topo), 1.0);
        if (job.grading.cell_max_mm < frontier_mm)
          swept_unprintable_note =
              "\n     ★ AND SEPARATELY: your whole swept window (" +
              json_num(job.grading.cell_min_mm) + " to " +
              json_num(job.grading.cell_max_mm) +
              " mm) is FINER than the smallest cell that prints at a " +
              json_num(w_min_fc) + " mm strut line width, which is " +
              json_num(frontier_mm) +
              " mm. No level of the ladder can carry a strut, so this run will "
              "solve and then emit NO LATTICE AT ALL. Raise \"cell_max_mm\" to at "
              "least that value.";
      }
      // ── S3: PER-REGION OUTPUT IS ONE TABLE ROW, AND THE EXPLANATION APPEARS ONCE
      // (task 2026-08-07-cell-mode-fit-and-swept-floor).
      //
      // WHAT WAS WRONG, in the maintainer's words: "Nothing is clear. This is a
      // *horrible* way to help the user." Nine declared regions produced NINE
      // near-identical paragraphs — each one restating the same floor, the same cell
      // and the same physics — and the single sentence telling him what to TYPE came
      // last, below the fold on an iPad, cut off mid-word. The completeness bar (every
      // number, every remedy) was met; readability was never specified, so it was not
      // met at all.
      //
      // The shape is now fixed and it is the same for every case below:
      //     HEADLINE — what happened, with the count and the planned cell
      //     ACTION   — the number to type, FIRST, before any explanation
      //     TABLE    — one row per declared region, and nothing else per region
      //     Why:     — the explanation, ONCE
      //
      // Nothing here decides anything. The three-case machine below is untouched: the
      // same jobs refuse, for the same reasons, with the same arithmetic. Only the
      // composition of the text changed.
      struct PfRow {
        std::size_t ri = 0;
        std::string kind;
        double extent_mm = 0.0;
        const FitRegionCell* fit = nullptr;  // FIT only; null on every other mode
        bool thin = false;                   // counted against `thin_regions`
      };
      std::vector<PfRow> pf_rows;
      int thin_regions = 0, include_regions = 0;
      // Region-backed includes the pre-flight cannot price (see above).
      int unforecastable_regions = 0;
      double thinnest_mm = std::numeric_limits<double>::infinity();
      for (std::size_t ri = 0; ri < job.lattice.regions.size(); ++ri) {
        const JobLatticeRegion& r = job.lattice.regions[ri];
        if (r.role != "include") continue;
        ++include_regions;
        // The region's THINNEST dimension — the one that bounds how many cells
        // can lie across the latticed body. ONE definition, shared with the fit
        // derivation, so the two cannot describe different regions.
        // ★ A REGION-BACKED INCLUDE HAS NO DECLARED EXTENT (task
        // 2026-08-15-lattice-regions). Reading half-extents that are all zero
        // gives 0, and the derivation then throws "member_width_mm must be > 0"
        // — which is exactly how this bit on the FIRST §4 run: the pre-flight
        // reached the analytic reader before the fit path ever ran. Its extent
        // is MEASURED from its mask, the same number fit_region_cells uses.
        // ★ A REGION-BACKED INCLUDE HAS NO DECLARED EXTENT (task
        // 2026-08-15-lattice-regions). Reading half-extents that are all zero
        // gives 0, and the derivation then throws "member_width_mm must be > 0"
        // — which is exactly how this bit on the FIRST §4 run: the pre-flight
        // reached the analytic reader on a kind that has nothing for it to read.
        // Its extent is only knowable after the import, so it is skipped here
        // and counted; the run's per-region verdicts carry the real numbers.
        if (r.kind == "region") { ++unforecastable_regions; continue; }
        const double extent_mm = lattice_region_thinnest_extent_mm(r);
        if (extent_mm < thinnest_mm) thinnest_mm = extent_mm;
        PfRow row;
        row.ri = ri;
        row.kind = r.kind;
        row.extent_mm = extent_mm;
        // ── FIT reports what this region DERIVED, not what one part-wide cell
        // demands of it. That is the whole difference the mode makes, and it is
        // the row the maintainer reads to see his own region.
        if (pf_fit) {
          // Matched by the region's OWN job index rather than by a running counter:
          // fit_region_cells drops a degenerate region (mirroring the role resolver)
          // and this loop does not, so a counter would silently misalign the rest of
          // the list behind one bad region.
          const FitRegionCell* f = nullptr;
          for (const FitRegionCell& c : pf_fit_cells)
            if (c.job_region_index == ri) { f = &c; break; }
          if (f == nullptr) continue;   // degenerate region, dropped by the resolver
          row.fit = f;
          row.thin = !f->feasible || f->out_of_regime;
        } else {
          row.thin = extent_mm < required_mm;
        }
        if (row.thin) ++thin_regions;
        pf_rows.push_back(row);
      }
      if (include_regions > 0) {
        fc_region_too_thin = thin_regions;
        fc_include_regions = include_regions;
        fc_required_mm = required_mm;
        fc_thinnest_mm = thinnest_mm;
      }

      // THE TABLE. Fixed-width columns so nine rows read as nine rows and not as a
      // wall; the header names the cell every "cells across" number is measured at,
      // so that cell appears ONCE rather than on every line.
      auto pf_table = [&]() {
        std::string t;
        char line[320];
        for (const PfRow& row : pf_rows) {
          const std::string label =
              "  " + std::to_string(row.ri) + " (" + row.kind + ")";
          if (t.empty())
            t += pf_fit ? "  region        thinnest      cell   density    strut  "
                          "cells\n"
                        : "  region        thinnest   cells\n";
          if (pf_fit && row.fit != nullptr && !row.fit->feasible) {
            std::snprintf(line, sizeof(line),
                          "%-14s %7.3f        —        —        —      —  SOLID: "
                          "no (cell, density) pair prints AND percolates\n",
                          label.c_str(), row.extent_mm);
          } else if (pf_fit && row.fit != nullptr) {
            std::snprintf(line, sizeof(line),
                          "%-14s %7.3f %9.4f %8.4f %8.4f %6.2f  %s\n",
                          label.c_str(), row.extent_mm, row.fit->cell_mm,
                          row.fit->relative_density, row.fit->strut_mm,
                          row.fit->cells_per_member,
                          row.fit->out_of_regime ? "OUT OF REGIME"
                                                 : "certifiable");
          } else if (pf_fit) {
            continue;
          } else {
            std::snprintf(line, sizeof(line), "%-14s %7.3f %7.2f  %s\n",
                          label.c_str(), row.extent_mm,
                          cell_mm > 0.0 ? row.extent_mm / cell_mm : 0.0,
                          row.thin ? "SOLID: under the floor" : "certifiable");
          }
          t += line;
        }
        // The cell every "cells" number is measured at, named ONCE under the table
        // instead of on every row — which is what the nine paragraphs were doing.
        if (!t.empty() && !pf_fit) {
          std::snprintf(line, sizeof(line),
                        "  (\"cells\" = the region's thinnest extent across the "
                        "planned %.4f mm cell)\n", cell_mm);
          t += line;
        }
        return t;
      };

      // ONE composer for every message this pre-flight can produce — refusal or
      // forecast. The order is the bar: action before explanation, always.
      auto pf_compose = [&](const std::string& headline, const std::string& action,
                            const std::string& why) {
        std::string s = headline;
        if (!action.empty()) s += "\n" + action;
        s += "\n\n" + pf_table();
        if (!why.empty()) s += "\nWhy: " + why;
        // Appended to EVERY shape rather than to one branch: the window being
        // unprintable is a fact about the job, not about which of the three cases
        // the regions landed in, and it is the sentence that saves the solve.
        s += swept_unprintable_note;
        return s;
      };
      // Printing a composed block to stderr keeps the existing "[lattice] " prefix on
      // every line, so a log grep for the tag still finds the whole message.
      auto pf_print = [&](const std::string& block) {
        std::string out = "[lattice] ";
        for (char c : block) {
          out += c;
          if (c == '\n') out += "[lattice] ";
        }
        out += "\n";
        std::fwrite(out.data(), 1, out.size(), stderr);
        std::fflush(stderr);
      };

      // ── THE REFUSAL (task 2026-08-05-lattice-cell-size-adaptation, B1).
      //
      // WHAT WAS WRONG. Everything above is a FORECAST: it computes the exact
      // arithmetic, prints it, records it in run_info — and returns. Nothing
      // consumes it as a stop. The maintainer's overnight run (fingerprint
      // b3abcf880554) declared seven include regions, every one 4 mm across its
      // thinnest dimension, against an 8 mm cell whose floor needs 5 x 8 = 40 mm.
      // It forecast `7 of 7 include regions are thinner than the 40.000 mm the
      // floor requires`, then solved four rungs overnight, marked all four
      // lattice_accepted, and shipped a part with 1131 lattice cells — none of them
      // able to be where he asked. A forecast that says NOTHING you declared can
      // hold a lattice is not a warning; it is a description of a useless run.
      //
      // WHY *ALL* AND NOT *ANY*. Refusing when SOME region is too thin would break
      // every legitimate mixed job — a user may knowingly declare a thin rib
      // alongside a thick boss and want the boss latticed. When EVERY declared
      // region fails there is no such reading left: the run cannot honour a single
      // thing the user asked for. So the condition is exactly `thin == include`,
      // and a job with one admissible region is untouched (bar R3 — this cannot
      // flip a verdict on a path that produces usable lattice, because it does not
      // fire on one).
      //
      // WHAT IT SAYS. Per §2's rule, a region is never reported un-latticeable
      // without the cell and density at which it WOULD be latticeable, or the
      // statement that no such pair exists WITH the arithmetic. Both come from
      // lattice_derive_cell_for_member (lattice.hpp), evaluated at the thinnest
      // declared extent — the same core law, read at run time, no literal here.
      //
      // ── WHAT REVIEW CHANGED (M1 / M8c). The trigger above USED TO BE
      // `thin_regions == include_regions`, where `thin` meant "thinner than N* x
      // the planned cell" and the planned cell on a graded AUTO job is
      // lattice_cell_printability_floor_mm — evaluated at rho_MIN. That is exactly
      // the hidden condition §3 of this task took apart, used as a refusal trigger.
      // It refused a graded AUTO job whose regions were 6 mm while this task's own
      // derivation says 5.4748 mm is feasible: a NEW refusal, on a path that
      // previously ran, on a job Stage A calls fine.
      //
      // THE TRIGGER IS NOW THE DERIVATION, and it distinguishes THREE cases that
      // the single test collapsed. Two floors govern, and they are different
      // failure modes with different remedies (lattice.hpp):
      //   PERCOLATION (~1 cell) — below it there is no connected strut network.
      //     The generator emits debris. His shipped mesh ran at 0.4263 cells per
      //     member and carried 123 isolated fragments.
      //   ACCURACY (5 cells)    — below it the homogenized tensor stops describing
      //     the member. The part still PRINTS; the certificate is out of regime.
      //
      //   (A) No (cell, rho) pair clears PRINTABILITY and PERCOLATION.
      //       Genuinely un-latticeable at any setting -> REFUSE.
      //   (B) A pair exists, but the PLANNED cell does not percolate in these
      //       regions -> REFUSE, with a DISTINCT message: the cell is wrong, not
      //       the part. Chosen over proceeding because proceeding is precisely
      //       what shipped him debris — 0.5 cells per member, 123 loose
      //       fragments, a night of solve. A run that can be fixed by one number
      //       in the job should say that number, not print rubble.
      //   (C) The planned cell percolates but sits below the ACCURACY floor.
      //       Buildable and uncertifiable — the regime sub-floor retention exists
      //       for. NOT refused: reported loudly and left to the opt-in. This is
      //       the case that was wrongly refused, and it is where his 4 mm back
      //       wall actually sits.
      // ── HOW FIT ENTERS THE SAME THREE CASES (task
      // 2026-08-05-lattice-cell-fit-mode, S1). It reuses this machine rather than
      // adding a second refusal, with two scoped differences that follow from what
      // fit does:
      //   * (A) fires only when NO declared region is feasible. Under one part-wide
      //     cell the thinnest region decides the run; under fit each region gets its
      //     own cell, so a job with one thin region and six good ones can still
      //     honour the six. Refusing it would be refusing work fit can do.
      //   * (B) CANNOT fire. The derived cell is chosen at or below extent /
      //     percolation floor by construction, so a feasible region's planned cell
      //     percolates. That is the defect this mode removes, and the assertion
      //     below states it rather than leaving it implied.
      const bool fit_any_feasible =
          pf_fit && std::any_of(pf_fit_cells.begin(), pf_fit_cells.end(),
                                [](const FitRegionCell& f) { return f.feasible; });
      const bool pf_decidable =
          include_regions > 0 && w_min_fc > 0.0 && !(pf_fit && fit_any_feasible);
      if (pf_decidable) {
        const double perc_floor = lattice_percolation_cells_per_member_min(topo);
        const LatticeCellDerivation d =
            lattice_derive_cell_for_member(topo, thinnest_mm, w_min_fc);
        // Does the PLANNED cell percolate across the thinnest declared region?
        const double planned_cpm = thinnest_mm / cell_mm;
        const bool planned_percolates = planned_cpm >= perc_floor;

        std::string msg;
        if (!d.feasible_percolation) {
          // (A) — nothing can be built here at any setting.
          //
          // S3 SHAPE: headline, then the action (what to change and to what), then the
          // per-region table, then the explanation ONCE. Every number the old
          // paragraph-per-region form carried is still here — the region indices,
          // kinds and extents in the table, the floors and the bead in the prose.
          const std::string headline =
              std::to_string(include_regions) + " of " +
              std::to_string(include_regions) +
              " declared lattice include regions are too thin to hold a CONNECTED "
              "lattice at any cell size or density — refusing before spending a "
              "solve.";
          std::string action =
              "THICKEN the region to at least " +
              json_num(d.min_member_width_buildable_mm) +
              " mm for a connected lattice, or " +
              json_num(d.min_member_width_certifiable_mm) +
              " mm for a CERTIFIED one — or use a strut line width of at most " +
              json_num((thinnest_mm / perc_floor) *
                       octet_strut_diameter_mm(lattice_rho_max(topo), 1.0)) +
              " mm. Your thinnest region has " + json_num(thinnest_mm) +
              " mm. Both are your call, not this pipeline's.";
          std::string why =
              "at a " + json_num(w_min_fc) +
              " mm strut line width the smallest cell any certifiable strut prints "
              "at is " + json_num(d.min_printable_cell_mm) +
              " mm, and a connected strut network needs " + json_num(perc_floor) +
              " cell(s) across it — so " +
              json_num(d.min_member_width_buildable_mm) +
              " mm of material is the least a lattice can live in, whatever the "
              "cell size or density. Nothing printable can go where you asked.\n";
          // ── M2: EVERY REMEDY A REFUSAL NAMES MUST CHANGE THE OUTCOME.
          // A SKIN is deliberately NOT offered here. It was, and it should not
          // have been: the rim/skin finish dresses only ANALYTIC boundary faces,
          // and a voxel-derived part with no bolt clearance has none, so a skin
          // produces exactly zero geometry there (handoff §7). Recommending it
          // sent the user to a door that is painted on. It is named as
          // UNAVAILABLE rather than omitted, so nobody re-adds it.
          why += "     NOT AVAILABLE as an alternative on this part: a SKIN / RIM "
                 "finish. It dresses analytic faces (flat planes, bolt bores) "
                 "and this part's boundary comes from the voxel grid, so it "
                 "would emit nothing at all. The export refuses it rather than "
                 "producing an undressed part silently.";
          msg = pf_compose(headline, action, why);
        } else if (!planned_percolates) {
          // (B) — the CELL is wrong, and a working range exists. Name it FIRST.
          const std::string headline =
              std::to_string(thin_regions) + " of " +
              std::to_string(include_regions) +
              " declared lattice include regions are too thin for the planned " +
              json_num(cell_mm) +
              " mm cell — refusing before spending a solve.";
          // ── WHICH KEY, FOR THIS JOB. The old copy said `Set "cell_mm" in the
          // GRADING block` on EVERY graded path — and the schema REFUSES "cell_mm"
          // alongside both "auto" and "swept" (job.cpp: "a target cell alongside a
          // ladder is a CONFLICT, not a hint"). So the remedy it named was a job core
          // would reject, on the two modes the app can actually send. Named per mode
          // now; the range itself is unchanged.
          std::string action =
              "SET cell size between " + json_num(d.min_printable_cell_mm) +
              " mm and " + json_num(thinnest_mm / perc_floor) + " mm";
          if (job.grading.present) {
            if (pf_mode == CellSizeMode::Swept)
              action += " — lower \"cell_min_mm\" in the GRADING block into that "
                        "range (\"cell_mm\" is refused alongside a swept ladder).";
            else if (pf_mode == CellSizeMode::Auto)
              action += " — set \"cell_mode\": \"fixed\" with \"cell_mm\" in that "
                        "range (\"auto\" takes core's own floor, which is how you "
                        "got here).";
            else
              action += " — set \"cell_mm\" in the GRADING block to a value in "
                        "that range.";
            action += " Or set \"cell_mode\": \"fit\" and core derives it per "
                      "region.";
          } else {
            action += " — set \"cell_mm\" in the lattice block to a value in that "
                      "range.";
          }
          // THE EXPLANATION, ONCE. Every number the nine paragraphs carried is here
          // or in the table: the region indices, kinds and extents are rows; the
          // planned cell heads the "cells across" column and the headline; the
          // floors, the bead and the admissible window are stated once.
          std::string why =
              "a strut network only connects when at least " +
              json_num(perc_floor) +
              " cell(s) lie across the member. The planned " + json_num(cell_mm) +
              " mm cell puts " + json_num(planned_cpm) +
              " across your thinnest region (" + json_num(thinnest_mm) +
              " mm), so this run would emit loose fragments rather than a lattice. "
              "At a " + json_num(w_min_fc) +
              " mm strut line width that region admits cells from " +
              json_num(d.min_printable_cell_mm) + " mm (printability) up to " +
              json_num(thinnest_mm / perc_floor) + " mm (percolation).\n";
          // ── WHAT S2 CHANGED HERE (task 2026-08-05-lattice-cell-fit-mode).
          // This message used to say that setting "cell_mm" on a GRADED job WILL
          // NOT WORK, and it was correct: grading.cpp took max(target,
          // lattice_cell_printability_floor_mm), a floor evaluated at rho_MIN, so
          // a 1.2 mm target was silently raised to 4.6026 mm at a 0.42 bead and
          // landed straight back in this refusal (measured on his own geometry:
          // "planned cell 4.602619932 mm gives 0.8690702381 cells across").
          //
          // The override is FIXED (grading.cpp, the `abs_floor_mm` bound): a Fixed
          // target is now raised only to the cell below which NO density in the
          // band prints, and the density is raised with the cell. So the remedy
          // this message names is a remedy the code path no longer overrides.
          if (job.grading.present)
            why += "     A graded cell is raised only to " +
                   json_num(w_min_fc / octet_strut_diameter_mm(
                                           lattice_rho_max(topo), 1.0)) +
                   " mm (the cell below which no density in the band prints), and "
                   "the density is raised with it so the strut still clears your "
                   "strut line width.\n";
          if (thinnest_mm < d.min_member_width_certifiable_mm) {
            // ── N1/N2: say what the region will actually DO on this path, and
            // lead with the remedy the user can actually reach.
            why += "     Separately: a CERTIFIED lattice needs " +
                   json_num(d.min_member_width_certifiable_mm) +
                   " mm of member and your thinnest region has " +
                   json_num(thinnest_mm) + " mm. What that means here:\n";
            if (job.grading.present) {
              why += "       * GRADED run: the grading law falls sub-floor "
                     "candidates back to SOLID, so setting the cell alone will "
                     "get you past this refusal and STILL leave those regions "
                     "solid with no lattice in them.\n";
              // ★ CORRECTED (task 2026-08-07). This bullet used to read "THAT SWITCH
              // IS NOT EXPOSED IN THE APP … from the iPad this region cannot be
              // latticed at all today". Task 2026-08-05-lattice-retention-app-control
              // shipped the control; the sentence has been telling the maintainer to
              // give up on a switch that is on his own lattice page.
              why += "       * To lattice them anyway, arm "
                     "\"retain_subfloor_in_unloaded_regions\" (the app's \"Keep "
                     "lattice in thin members\" control, or the job-JSON key). The "
                     "lattice is then built and the certificate over it is OUT OF "
                     "REGIME — read the exposure the receipt reports before arming "
                     "it.\n";
              why += "       * OR set \"cell_mode\": \"fit\", which derives a "
                     "cell from each region's own extent, lattices it, and "
                     "reports the out-of-regime material it emitted — no "
                     "retention switch involved. Use fit when the regions differ "
                     "in thickness; use retention when they do not. They are "
                     "mutually exclusive, and core refuses a job that arms both.\n";
            } else {
              why += "       * UNIFORM run: no cells-per-member floor is applied "
                     "on this path, so a lattice in the range above WILL be built "
                     "here — CONNECTED but NOT CERTIFIED. The margin over it is "
                     "out of regime and lattice_strut_out_of_regime is raised.\n";
            }
          }
          msg = pf_compose(headline, action, why);
        } else {
          // (C) — percolates. Not a refusal. Report and continue.
          //
          // TWO SUB-CASES, and the second is the one M3 is about. The planned cell
          // still comes from lattice_cell_printability_floor_mm (rho_MIN); the
          // derivation is REPORTING-ONLY and feeds no cell selection. So a region
          // can be comfortably above the certifiable minimum and STILL have every
          // voxel rejected, because the planned cell is far coarser than the one
          // the derivation would pick. Saying so here costs a printf and saves a
          // whole solve — which is the entire point of a pre-flight.
          if (thinnest_mm >= d.min_member_width_certifiable_mm &&
              planned_cpm < n_star) {
            char n1[1024];
            std::snprintf(
                n1, sizeof(n1),
                "A cell of %.4f mm at relative density %.4f (strut %.4f mm) puts "
                "%.2f cells across your thinnest region and certifies — set it, or "
                "set \"cell_mode\": \"fit\" and core derives exactly that, per "
                "region.",
                d.lightest_cell_size_mm, d.lightest_relative_density,
                d.lightest_strut_diameter_mm, d.lightest_cells_per_member);
            char n1why[1024];
            std::snprintf(
                n1why, sizeof(n1why),
                "your thinnest declared region (%.3f mm) IS thick enough for a "
                "CERTIFIED lattice — it needs %.3f mm — but the planned %.4f mm "
                "cell puts only %.2f cells across it, under the %.2f-cell accuracy "
                "floor, so the grading law will reject it and emit no lattice. The "
                "cell is what is wrong, not the part. (\"cell_mode\": \"auto\" will "
                "NOT fix it: it selects the printability floor at the band's "
                "LIGHTEST density, %.4f mm, which is how you got here.)",
                thinnest_mm, d.min_member_width_certifiable_mm, cell_mm,
                planned_cpm, n_star, cell_mm);
            pf_print(pf_compose(
                std::to_string(thin_regions) + " of " +
                    std::to_string(include_regions) +
                    " declared lattice include regions will come back SOLID at the "
                    "planned " + json_num(cell_mm) + " mm cell.",
                std::string(n1), std::string(n1why)));
          }
          if (thinnest_mm < d.min_member_width_certifiable_mm) {
            // ── N1: WHAT ACTUALLY HAPPENS HERE DEPENDS ON THE PATH, and an
            // earlier version of this note said "the lattice will be built"
            // unconditionally. That is FALSE on a graded run and it set up
            // exactly the failure this branch exists to stop: clear pre-flight,
            // spend the solve, get a solid wall.
            //
            // GRADED — grade_lattice enforces the accuracy floor
            // (src/simp/grading.cpp:102 reads lattice_cells_per_member_min, and
            // note_member_too_thin at :20-28 records the fallback). A sub-floor
            // candidate is graded back to SOLID. That is the DEFAULT, and
            // flipping it is the entire purpose of
            // retain_subfloor_in_unloaded_regions.
            //
            // UNIFORM — no cells-per-member floor is applied anywhere on this
            // path. Every `cells_per_member` reference in this file outside the
            // grading receipt and this pre-flight is reporting only, and
            // lattice_strut_out_of_regime (src/simp/analyze.cpp:458-460) is a
            // FLAG, not a gate. That is why the maintainer's own uniform run
            // emitted 1131 cells at 0.4263 cells per member with
            // strut_out_of_regime true and strut_gated false.
            char n2why[1400];
            std::snprintf(
                n2why, sizeof(n2why),
                "your thinnest declared region (%.3f mm) percolates at the planned "
                "%.4f mm cell (%.2f cells across, percolation floor %.2f) but is "
                "BELOW the %.2f-cell accuracy floor, which needs %.3f mm. %s",
                thinnest_mm, cell_mm, planned_cpm, perc_floor, n_star,
                d.min_member_width_certifiable_mm,
                job.grading.present
                    ? "The grading law falls sub-floor candidates back to solid, "
                      "SO THOSE REGIONS WILL COME BACK SOLID and no lattice will "
                      "be emitted in them unless retention is armed — in which "
                      "case they are latticed and the certificate over them is "
                      "OUT OF REGIME."
                    : "The uniform path applies NO cells-per-member floor, so the "
                      "lattice WILL be built here and the certificate over it will "
                      "be OUT OF REGIME (lattice_strut_out_of_regime is raised; it "
                      "is a flag, not a gate). This is reported, not refused.");
            // ★ CORRECTED (task 2026-08-07): the graded arm used to end "That switch
            // is a job-JSON key and is NOT exposed in the app today, so on the iPad
            // this region cannot be latticed at all." Retention SHIPPED to the app in
            // task 2026-08-05-lattice-retention-app-control.
            pf_print(pf_compose(
                std::to_string(thin_regions) + " of " +
                    std::to_string(include_regions) +
                    " declared lattice include regions are under the accuracy "
                    "floor at the planned " + json_num(cell_mm) + " mm cell.",
                job.grading.present
                    ? std::string(
                          "ARM \"retain_subfloor_in_unloaded_regions\" (the app's "
                          "\"Keep lattice in thin members\" control) to lattice "
                          "them OUT OF REGIME — or set \"cell_mode\": \"fit\", "
                          "which derives a cell per region instead. The two are "
                          "mutually exclusive and core refuses a job arming both.")
                    : std::string(
                          "Nothing to set: this uniform run builds the lattice "
                          "anyway and stamps the certificate OUT OF REGIME."),
                std::string(n2why)));
          }
          std::fflush(stderr);
        }
        if (!msg.empty()) {
          msg += "\n     To proceed anyway with lattice OUTSIDE your declared "
                 "regions, remove the include regions from the lattice block — but "
                 "read the receipt first: this run would have put every cell in "
                 "material you did not select.";
          throw JobError(msg);
        }
      } else if (include_regions > 0) {
        // ── THE PATHS THE THREE-CASE MACHINE DOES NOT DECIDE, reported in the SAME
        // shape (S3). Two of them:
        //   * FIT with at least one feasible region. It never refuses — each region
        //     gets its own cell — but it must still SAY what each region derived, and
        //     that is exactly one table row per region.
        //   * A job that stated no strut line width. No derivation is possible, so
        //     there is no action to name; the table still reports what was declared.
        // This is where the old "FORECAST: N of M include regions are thinner than …"
        // summary lived, and it is the line that must not be lost: with no refusal and
        // no per-region paragraphs, silence would read as "everything is fine".
        std::string headline, action, why;
        if (pf_fit) {
          const double cert_mm =
              pf_fit_cells.empty() ? 0.0
                                   : pf_fit_cells.front().min_width_certifiable_mm;
          headline =
              thin_regions == 0
                  ? ("all " + std::to_string(include_regions) +
                     " declared lattice include regions certify at the cell FIT "
                     "derived for them (finest " + json_num(cell_mm) + " mm).")
                  : (std::to_string(thin_regions) + " of " +
                     std::to_string(include_regions) +
                     " declared lattice include regions cannot reach the " +
                     json_num(n_star) +
                     "-cell accuracy floor at the cell FIT derived for them "
                     "(thinnest region " + json_num(thinnest_mm) +
                     " mm; finest derived cell " + json_num(cell_mm) + " mm).");
          if (thin_regions > 0 && cert_mm > 0.0)
            action = "NOTHING TO SET — fit already picked the finest cell each "
                     "region can print. To CERTIFY a row marked OUT OF REGIME, "
                     "thicken that region to " + json_num(cert_mm) +
                     " mm; otherwise the part is buildable and the certificate "
                     "does not cover that material.";
          why = "fit derives cell = max(region extent / " + json_num(n_star) +
                ", the finest printable cell) per declared region, then raises the "
                "density with it so the strut still clears your strut line width. A "
                "region with fewer than " + json_num(n_star) +
                " cells across is BUILDABLE and its homogenized tensor stops "
                "describing the member, so the certificate over it is OUT OF REGIME "
                "— reported, never silently certified. A row marked SOLID has no "
                "(cell, density) pair that both prints and percolates at any "
                "setting.";
        } else {
          headline =
              std::to_string(thin_regions) + " of " +
              std::to_string(include_regions) +
              " declared lattice include regions are thinner than the " +
              json_num(required_mm) + " mm the accuracy floor requires at the "
              "planned " + json_num(cell_mm) + " mm cell (thinnest " +
              json_num(thinnest_mm) + " mm).";
          action = "This job states no strut line width, so core cannot derive a "
                   "cell that would work — state \"min_extrudable_width_mm\" and "
                   "this pre-flight will name the range.";
          why = "the cells-per-member floor needs " + json_num(n_star) +
                " x " + json_num(cell_mm) + " mm = " + json_num(required_mm) +
                " mm of material across a member before its homogenized tensor "
                "describes it. That is a property of the region's geometry and the "
                "printability floor (nozzle-derived), not of the optimizer and not "
                "of any Protect setting.";
        }
        pf_print(pf_compose(headline, action, why));
      }
    }
  }

  RunJobResult result;

  // §5 pipeline: import the part into the face-carrying StepModel every
  // downstream stage consumes. The FRONT DOOR is the ONLY format-aware line —
  // import_part_file dispatches on the extension (handoff 134):
  //   .step/.stp  ──OCCT B-rep──▶ StepModel  (REAL faces; the identical code
  //                                            path it always took, byte for byte)
  //   .stl / .3mf ──read+repair+segment──▶ StepModel  (PSEUDO-faces)
  // Everything after this point — the watertight check, voxelize, tag,
  // build_production_loadcase, the ladder, the report, the export — is written
  // against `StepModel` + `face_id` and does not know or care which door the
  // model came through. `model_is_mesh` is used ONLY to name the tagging call
  // honestly (tag_mesh_face vs tag_step_face); the two are identical.
  const std::string model_path = join_path(job_dir, job.model);
  const bool model_is_mesh =
      part_format_for_path(job.model) != PartFormat::Step;
  // import_part_file_resolved throws PartError on a read/parse failure, an
  // unavailable format (STEP without OCCT, 3MF without lib3mf), or a mesh REFUSED
  // by the Phase-1 inspection (non-manifold, open, non-orientable, zero-thickness).
  // Any of those is a job-level failure, so surface it as a JobError with the
  // core's own plain-language reason rather than letting PartError escape
  // run_job's documented JobError contract.
  //
  // `_resolved` (vs the bare `import_part_file`) applies a face-overrides sidecar
  // sitting next to the model if the app wrote one: the tuned segmentation
  // threshold and any PAINTED pseudo-faces (handoff 2026-07-24). With no sidecar
  // it is byte-for-byte the old import, so STEP jobs and un-painted mesh jobs are
  // unchanged. This is why the run reproduces exactly the faces the user saw and
  // painted — the load/anchor/clearance/protect face ids below resolve against
  // the SAME partition.
  try {
    result.model = import_part_file_resolved(model_path);
  } catch (const PartError& e) {
    throw JobError(std::string("cannot import model \"") + job.model +
                   "\": " + e.what());
  }

  // ──▶ watertight check (both modes AND both sources). For a STEP part this is
  // the unchanged tessellation check. For a mesh part the Phase-1 importer has
  // already REFUSED an open surface (OpenBoundary), so a mesh that reaches here
  // is watertight; the check is kept as a belt-and-suspenders guard that also
  // covers the (rare) tessellation that welds to a hole no defect scan caught.
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);

  // Two modes, both driving the SAME production optimizer configuration as the
  // iPad app (handoff 093). THE ONE setup: build_job_setup above — the same call
  // preflight_job makes, so a pre-flight can never describe a different job than
  // the one that then runs (task 2026-08-03-preflight-feasibility-and-divergence).
  JobSetup setup = build_job_setup(job, result.model, model_is_mesh, materials);
  VoxelGrid grid = std::move(setup.grid);
  std::vector<DirichletBC> bcs = std::move(setup.bcs);
  MinimizePlasticOptions options = std::move(setup.options);
  ProductionLoadCase lc = std::move(setup.lc);
  std::string loadcase_receipt = std::move(setup.loadcase_receipt);
  result.fixture_face_ids = std::move(setup.fixture_face_ids);

  // ──▶ output dir (created before the run so streamed artifacts can land in it).
  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("cannot create output directory " + out_dir + ": " +
                     ec.message());
  }
  // The load-case receipt (bar Z2), beside the artifacts it describes. A new,
  // separate document — report.json / fields.bin / the meshes are untouched.
  result.loadcase_receipt_path = join_path(out_dir, "loadcase.json");
  result.loadcase_receipt_json = loadcase_receipt;
  write_text_file(result.loadcase_receipt_path, loadcase_receipt);

  // THE domain the run solves on — the expanded grid AND the BCs/loads remapped
  // onto it under a design box (resolve_design_domain, pipeline.hpp), verbatim
  // inputs without one. Needed up front so a streamed variant's mesh is resampled
  // on the right grid, and so the latticed re-certification below certifies under
  // the SAME load case minimize_plastic solves under — it is literally the same
  // object, not a second reconstruction of it (task
  // 2026-08-03-design-box-recertification).
  const SolvedDesignDomain domain = resolve_design_domain(grid, bcs, options);
  const VoxelGrid& solved_grid = domain.grid;
#ifndef NDEBUG
  // The two derivations agreed before this task by discipline; now they are the
  // same call. Asserted rather than commented (pure geometry, no solve).
  {
    const VoxelGrid mp = minimize_plastic_solved_grid(grid, options);
    assert(solved_grid.nx == mp.nx && solved_grid.ny == mp.ny &&
           solved_grid.nz == mp.nz && solved_grid.spacing == mp.spacing &&
           "the solved grid resolve_design_domain reports must be the grid "
           "minimize_plastic solves on");
  }
#endif

  // ──▶ PRE-FLIGHT LOAD-PATH CONNECTIVITY (task 2026-08-03-preflight-feasibility-
  // and-divergence, guard 1). BEFORE ANY SOLVE, with the clearances frozen and
  // the design domain resolved: can the load-tagged voxels reach the anchors
  // through voxels the optimizer is ALLOWED to fill? A flood fill — milliseconds
  // against the ten hours a severed job otherwise spends discovering it.
  //
  // REFUSE ONLY ON DISCONNECTION. Connectivity is necessary, not sufficient; a
  // connected-but-hopeless path still diverges, which is what guards 2 and 3 are
  // for. The narrowest-cross-section reading is reported as INFORMATION and never
  // refuses anything.
  const PreflightLoadPath preflight = preflight_load_path(domain, options);
  result.preflight = preflight;
  if (preflight.walk.decidable) {
    char buf[512];
    std::snprintf(
        buf, sizeof(buf),
        "[preflight] load path %s: %zu load voxels, %zu anchor voxels, %zu of "
        "%zu voxels allowed to hold material; narrowest separating "
        "cross-section %d voxels (%.4g mm^2) at %d/%d steps from the anchor; "
        "%.2f ms",
        preflight.walk.connected ? "CONNECTED" : "SEVERED",
        preflight.walk.load_voxels, preflight.walk.anchor_voxels,
        preflight.walk.printed_voxels, solved_grid.voxel_count(),
        preflight.walk.narrowest_separator_voxels,
        preflight.walk.narrowest_separator_mm2,
        preflight.walk.narrowest_separator_level, preflight.walk.geodesic_levels,
        preflight.wall_ms);
    std::fprintf(stderr, "%s\n", buf);
    std::fflush(stderr);
  }
  if (preflight.walk.decidable && !preflight.walk.connected) {
    const std::string why = preflight_refusal_report(
        result.model, grid, domain, options, lc, preflight,
        result.fixture_face_ids);
    // THE GUARDS ARE OBSERVABLE (bar P6) even when the guard REFUSES: write
    // run_info.json with the pre-flight block before throwing, so the refusal
    // leaves a machine-readable record beside the load-case receipt and not only
    // a line in a log.
    if (emit_progress) {
      RunInfo refused = build_run_info(job, options, obs);
      fill_run_info_preflight(refused, preflight);
      result.run_info_path = join_path(out_dir, "run_info.json");
      write_run_info(result.run_info_path, refused);
    }
    throw JobError(why);
  }

  // LOUD PARITY GATE (task: multigrid-odd-axis-cliff, O1/O2). Say at RUN START
  // what geometric multigrid will do on this grid. The motivating run solved
  // 128x31x118 — one odd axis — for six hours on Jacobi-CG, discoverable only
  // in run_info.json afterwards. Now: a grid the solver's parity pad rescues
  // gets a NOTE naming the odd axes and the padded shape; a grid that will
  // still reject its hierarchy gets a WARNING naming the offending axes, the
  // achievable level count and the concrete remedy shape. Coarsenable grids
  // stay silent. Pure prediction from the same rule the solver enforces
  // (topopt/coarsen.hpp); the post-run observed warning below is unchanged.
  if (options.simp.solver == SolverKind::MultigridCG ||
      options.simp.solver == SolverKind::MultigridCG_Matfree) {
    char banner[512];
    if (mg_startup_banner(solved_grid.nx, solved_grid.ny, solved_grid.nz,
                          fea_mg_parity_pad_mode() != 0, banner,
                          sizeof(banner)) != 0) {
      std::fprintf(stderr, "%s\n", banner);
      std::fflush(stderr);
    }
  }

  // Job wall clock start (lattice P6: generation time as a fraction of the whole
  // job). Captured here, after import/voxelize, so it spans the solve + export the
  // lattice generation competes with. An observer — never affects output bytes.
  const double job_t0 = wall_seconds();

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
    fill_run_info_preflight(run_info, preflight);
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

  // Lattice-export accumulator (handoff 2026-07-28-lattice-generation-production).
  // Summed over accepted variants so run_info records ONE posture for the run.
  // `wall_s` is the generation time only — its fraction of total job time is the
  // P6 bar (finalized after the run). Untouched when no lattice block is present.
  struct LatticeAgg {
    bool any = false;
    long long cells = 0, voxels = 0, tris = 0;
    int variants = 0;
    // Rungs the grading law could lattice NOTHING of, so nothing was emitted for
    // them and nothing of theirs entered the aggregates below (bar B3 / L3).
    // Counted rather than dropped silently: "3 of 4 rungs latticed" is a fact the
    // receipt has to carry, or the missing files look like a transport failure.
    int ungradeable_variants = 0;
    double r_min = 1e30, r_max = 0.0;
    double wall_s = 0.0;
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // All zero and `void_check_ran` false unless the job armed
    // `require_lattice_void_reaches_exterior`, so a run that did not arm it
    // writes no key. `void_wall_s` is the CHECK's own time, kept out of `wall_s`
    // (which is generation) so the two costs are never conflated. Rungs the rule
    // REFUSED are counted like ungradeable ones and, like them, contribute
    // nothing to the aggregates below.
    bool void_check_ran = false;
    int void_sealed_variants = 0;
    long long void_sealed_cells = 0, void_sealed_voxels = 0;
    double void_sealed_volume_mm3 = 0.0;
    long long void_latticed_reached = 0, void_latticed_cells = 0;
    double void_reachable_volume_mm3 = 0.0;
    long long void_bfs_visits = 0;
    int void_escape_depth_max = -1;
    bool void_face_escapes[6] = {false, false, false, false, false, false};
    long long void_sealed_pockets_without_lattice = 0;
    double void_wall_s = 0.0;
    // Boundary finish (handoff 2026-07-29-lattice-boundary-finish): what the
    // clip/skin passes did, summed over variants — B9's volume accounting.
    long long clipped = 0, landings = 0, anchors = 0;
    long long skin_tris = 0, rim_tris = 0;
    double interior_vol = 0.0, skin_vol = 0.0, rim_vol = 0.0;
    // Freeform skin (task 2026-07-30-lattice-skin-freeform): chord accounting,
    // summed over variants. All zero on the default "shell" finish.
    long long chords = 0, chords_band = 0, chords_proj = 0, chords_clipped = 0;
    // Certification posture (E2E bars E1/E3), summed over accepted latticed variants
    // so run_info records ONE posture. rho is uniform (same for every variant) so its
    // range is a point; the margins are the WORST (min) over the variants — the
    // conservative run-level summary — while each variant's receipt carries its exact
    // numbers.
    bool cert_ran = false;
    double rho_lo = 1e30, rho_hi = 0.0;
    long long cert_voxels = 0;
    double lat_margin_min = 1e300, lat_margin_eff_min = 1e300;
    bool lat_accepted_all = true;
    bool strut_uncertified = false;
    // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report):
    // run-level worst (min over latticed variants) of the report-only margins —
    // like the certified margins above, conservative summary here, exact numbers
    // in each variant's receipt. NEVER a gate input.
    bool strut_report = false;
    double strut_in_plane_min = 1e300, strut_il_min = 1e300,
           strut_worst_min = 1e300;
    double strut_zk = 0.0, strut_cpm_min = 1e300;
    bool strut_oor = false;  // any variant out of the cells-per-member regime
    long long strut_clamped = 0;  // summed law-span rho clamps (bar L5)
    // Lattice roles + solid companion (task lattice-page-core-hookup stage 1),
    // summed over variants like the counters above. All zero/false on a job
    // with no lattice.regions and no grading — run_info stays byte-identical.
    bool roles_present = false;
    long long include_regions = 0, exclude_regions = 0;
    long long solid_voxels = 0, solid_tris = 0, include_void = 0;
    double solid_vol = 0.0;
    // Include-void by CAUSE, and the frozen-material split (task 2026-08-04-
    // protect-freeze-vs-solidity). Summed over variants like everything above.
    long long include_void_clearance = 0;
    long long frozen_printed = 0, frozen_latticed = 0, frozen_solid = 0;
    long long frozen_not_emitted = 0, frozen_both = 0;
    long long frozen_unexplained = 0, frozen_excl_latticed = 0;
    // Graded run (stage 4): run_info's "grading" object records the LAST graded
    // variant's law report (each variant's own full record — including field
    // provenance and clamp counts — lives in its receipt). Scalars only.
    bool graded = false;
    double g_cell = 0.0, g_floor = 0.0;
    bool g_floored = false;
    double g_band_lo = 0.0, g_band_hi = 0.0, g_cpm_floor = 0.0;
    double g_rho_lo = 0.0, g_rho_hi = 0.0;
    long long g_region = 0, g_latticed = 0, g_fallback = 0;
    double g_min_width = 0.0, g_min_cpm = 0.0, g_min_d = 0.0, g_max_d = 0.0;
    bool g_below_min = false, g_ungradeable = false;
    // The CELL-SIZE plan record, carried verbatim from the last graded variant
    // (handoff 2026-08-01-lattice-cell-size-sweep). Held as a RunInfo so the ONE
    // filler used by analyze_job serves this path too — the two receipts cannot
    // drift.
    RunInfo g_cell_ri;
  } lat_agg;
  std::vector<std::string> lattice_paths;  // merged into result.mesh_paths at end
  // Emit ONE accepted variant's latticed companion: generate the mesh, RE-CERTIFY it
  // against the octet tensor (bar E1 — the margin then describes the exported file,
  // not the solid design), write the per-variant certification receipt, fold both into
  // the accumulator, and (streaming path) print a machine-parseable LATTICE checkpoint
  // carrying the LATTICED margin so the worker forwards the right verdict.
  // The lattice keep-outs (protected features): resolved ONCE per job from the
  // declared clearances via the existing clearance machinery. Empty when no
  // loads/clearances are declared — the boundary is then just the solid design.
  const std::vector<ClearanceGeometry> lattice_kos =
      job.lattice.present
          ? lattice_keep_outs_from_job(job, result.model)
          : std::vector<ClearanceGeometry>{};
  // The job's lattice ROLE regions (stage 1), resolved once — empty on a job
  // with no lattice.regions (byte-identical path).
  const LatticeRoleRegions lattice_roles =
      job.lattice.present
          // `grid` here IS the part grid build_production_loadcase voxelized
          // (the solved domain expands it later); a region's voxels live on the
          // part, so that is the lattice the mask is built in.
          ? lattice_role_regions_from_job(job, &result.model, &grid)
          : LatticeRoleRegions{};

  // ★ REFUSE HERE, BEFORE THE SOLVE (task 2026-08-16-per-sector-density-override).
  // Both region refusals — infeasible geometry and an unprintable stated density —
  // also run inside the grading step below, which is where they were born. But
  // that step runs PER VARIANT, AFTER minimize_plastic: on his part that is over
  // an hour of solving before the user is told a number they typed cannot print.
  // A refusal that arrives after the work is nearly worthless.
  //
  // Everything both checks read is already known at this point: the job, and the
  // regions resolved against the part grid one statement above. Nothing here
  // needs the solved design. The pre-flight is EARLIER still and cannot host
  // this — it runs before the import, so a "region" kind has no body to measure
  // there (that is exactly why the pre-flight skips-and-counts them).
  //
  // ★ The copies below stay. This is a duplicate guard, not a move: the grading
  // step is reached by other callers, and a refusal must not depend on which
  // entry point ran. Identical inputs, identical predicate, so the two cannot
  // disagree — the first one to see the job wins, and that is this one.
  if (job.lattice.present && !lattice_roles.includes.empty()) {
    CellSizeMode preflight_mode = CellSizeMode::Fixed;
    if (resolve_cell_mode(job.grading.cell_mode, preflight_mode) &&
        preflight_mode == CellSizeMode::Fit) {
      const std::vector<FitRegionCell> early_cells = fit_region_cells(
          job, LatticeTopology::Octet, job.grading.min_extrudable_width_mm,
          &lattice_roles);
      refuse_infeasible_region_lattice(job, early_cells,
                                       job.grading.min_extrudable_width_mm);
      refuse_unprintable_stated_density(job, early_cells, LatticeTopology::Octet,
                                        job.grading.min_extrudable_width_mm);
    }
  }

  // ── MULTISCALE LATTICE TO (task multiscale-lattice-to) ─────────────────────
  // Arm the optimizer's lattice material law for THIS job, if the job asked and
  // production permits. Absent `lattice.multiscale` => nothing here runs and the
  // ladder below is the two-step pipeline, byte-for-byte.
  //
  // REFUSALS ARE LOUD. A job that asks for multiscale on a mode with no optimizer,
  // or while production withholds the permission, is refused with a message that
  // says which — it is never silently downgraded to the two-step, because the whole
  // point of the flag is that the two-step does not work here.
  if (job.lattice.present && job.lattice.multiscale) {
    if (!production_multiscale_lattice_to())
      throw JobError(
          "run_job: lattice.multiscale was requested but this build withholds the "
          "permission (production_multiscale_lattice_to() is false)");
    options.multiscale_lattice = true;
    options.multiscale_topology = LatticeTopology::Octet;  // schema restricts to octet
    options.multiscale_region =
        multiscale_region_mask(solved_grid, lattice_kos, lattice_roles);
    options.multiscale_floor_cell_mm = multiscale_floor_cell_mm(job);
    // The floor is measured every iteration: the whole reason it is reported is to
    // make a design starving its members visible AS IT HAPPENS. The measurement is
    // an EDT over the design; it is charged honestly in the cost table rather than
    // hidden behind a coarse stride.
    options.multiscale_floor_stride = 1;
    // ── LENGTH-SCALE CONTROL FROM THE FLOOR (task multiscale-lattice-to) ─────
    // THE MEASURED REASON THIS EXISTS. Multiscale legalizes intermediate
    // density, and the optimizer exploits that by SPREADING material into thin
    // diffuse webs — which is exactly what the cells-per-member floor forbids.
    // Measured on a control fixture whose region was fully reachable and whose
    // ceiling admitted 10,002 of 10,040 voxels: the two-step latticed 19.0 % and
    // multiscale latticed 0.8 %, with 71 % of the multiscale design's members
    // spanning under 5 cells. SIMP's rho^3 was accidentally PROTECTING
    // latticeability by forcing consolidation; removing the penalization removed
    // that protection with nothing put back.
    //
    // The fix is length-scale control, not a constraint fighting the objective:
    // the density filter's radius sets the smallest member the design can
    // EXPRESS, so a radius derived from the floor makes a sub-floor member
    // inexpressible rather than merely unrewarded. This is standard minimum-
    // length-scale practice and it is a reparametrization — the objective, the
    // gate and the tolerance are untouched.
    //
    // THE ARITHMETIC. A member must span floor_cells * cell_mm to be latticeable.
    // The filter's length parameter in this codebase is a RADIUS (physical_filter
    // _radius divides min_feature_mm by the spacing), and a cone filter of radius
    // R yields a minimum member half-width ~R, so the member width it enforces is
    // ~2R. Hence min_feature_mm = floor_cells * cell_mm / 2.
    //
    // NEVER LOWERS what the job already asked for: max() with the incoming value,
    // so a job demanding a coarser feature size keeps it.
    {
      const double floor_cells =
          lattice_cells_per_member_min(options.multiscale_topology);
      const double implied_mm =
          0.5 * floor_cells * options.multiscale_floor_cell_mm;
      const double was = options.min_feature_mm;
      if (implied_mm > options.min_feature_mm) options.min_feature_mm = implied_mm;
      run_info.multiscale_min_feature_implied_mm = implied_mm;
      run_info.multiscale_min_feature_used_mm = options.min_feature_mm;
      std::fprintf(stderr,
                   "[multiscale] length scale: floor %.1f cells x %.4f mm = "
                   "%.3f mm member => min_feature %.3f mm (was %.3f mm)%s\n",
                   floor_cells, options.multiscale_floor_cell_mm,
                   2.0 * implied_mm, options.min_feature_mm, was,
                   implied_mm > was ? " RAISED" : " (job already coarser)");
    }
    // ── IS THE REGION EVEN OPTIMIZABLE? ──────────────────────────────────────
    // A lattice region is only reachable by the optimizer where the design mask
    // leaves it ACTIVE. A voxel the mask pinned FrozenSolid — a declared load or
    // fixture face, or a face-protection collar — is held at density 1 for the
    // whole run and can never become lattice, in ANY formulation. Counted and
    // reported here because it is the difference between "the optimizer chose
    // not to lattice this" and "nothing could have", and because a job that
    // declares its lattice region ON a protected face is asking for two
    // incompatible things and should be told so at the start rather than shown
    // an empty receipt at the end.
    {
      const DesignMask dm = design_domain_mask(domain, options);
      std::size_t active = 0, frozen_solid = 0, frozen_void = 0, empty = 0;
      for (std::size_t e = 0; e < options.multiscale_region.size(); ++e) {
        if (!options.multiscale_region[e]) continue;
        switch (dm[e]) {
          case MaskValue::Active: ++active; break;
          case MaskValue::FrozenSolid: ++frozen_solid; break;
          case MaskValue::FrozenVoid: ++frozen_void; break;
          default: ++empty; break;
        }
      }
      const std::size_t total = active + frozen_solid + frozen_void + empty;
      std::fprintf(stderr,
                   "[multiscale] region reachability: active=%zu frozen_solid=%zu "
                   "frozen_void=%zu empty=%zu (of %zu)\n",
                   active, frozen_solid, frozen_void, empty, total);
      if (total > 0 && active * 2 < total)
        std::fprintf(stderr,
                     "[multiscale] WARNING: %.1f%% of the declared lattice region "
                     "is NOT optimizable (pinned by the design mask — a declared "
                     "load/fixture face or a face-protection collar). Material "
                     "there is held SOLID for the whole run and can never become "
                     "lattice, in this or any formulation. If a latticed interior "
                     "is the goal, the lattice region and the protected faces are "
                     "asking for incompatible things.\n",
                     100.0 * static_cast<double>(total - active) /
                         static_cast<double>(total));
      run_info.multiscale_region_active = static_cast<long long>(active);
      run_info.multiscale_region_frozen_solid =
          static_cast<long long>(frozen_solid);
      run_info.multiscale_region_frozen_void = static_cast<long long>(frozen_void);
    }
    std::fprintf(stderr,
                 "[multiscale] armed: topology=octet region_voxels=%zu "
                 "floor_cell=%.4f mm floor_cells=%.1f\n",
                 static_cast<std::size_t>(
                     std::count_if(options.multiscale_region.begin(),
                                   options.multiscale_region.end(),
                                   [](char c) { return c != 0; })),
                 options.multiscale_floor_cell_mm,
                 lattice_cells_per_member_min(LatticeTopology::Octet));
    std::fflush(stderr);
  }

  auto emit_lattice = [&](const MinimizePlasticVariant& v, bool stream_lines) {
    if (!job.lattice.present) return;
    const bool roles_present = !job.lattice.regions.empty();
    // THE per-variant lattice pipeline — grade, boundary, mask, geometry,
    // composite certification, receipt — lives in ONE function (see
    // lattice_one_variant), shared with the re-lattice entry point so a variant
    // latticed later goes through the identical body. This lambda is now only
    // the run-level AGGREGATION and the streaming checkpoint line.
    const LatticeVariantOutcome R =
        lattice_one_variant(v, job, grid, domain, options, material,
                            lattice_kos, lattice_roles, out_dir);
    // ── THIS RUNG PRODUCED NO LATTICE (task
    // 2026-08-04-variant-volume-fraction-mismatch, bar B3 / L3).
    //
    // Skipped BEFORE the aggregation, and that is the point. The aggregates take
    // a MIN over rungs — `lat_agg.r_min = min(r_min, min_strut_diameter/2)`,
    // `lat_agg.rho_lo = min(rho_lo, gf.rho_min_used)` — and an ungradeable rung
    // carries both of those as 0, because grading.cpp only assigns them when
    // `latticed_voxels > 0`. One thin rung therefore dragged the WHOLE run's
    // report to zero. That is the "filled at 0% density … strut radius
    // 0.00–0.65 mm" the maintainer read: MEASURED in worker run
    // 4dabe3b8512d4d59, whose other rungs latticed 132 cells at radii up to
    // 0.645 mm perfectly well. Nothing was wrong with those rungs; the run-level
    // minimum was reading a rung that had no struts at all.
    if (R.ungradeable) {
      std::fprintf(stderr, "[lattice] vf=%.2f NO LATTICE EMITTED — %s\n",
                   v.requested_volume_fraction, R.ungradeable_reason.c_str());
      std::fflush(stderr);
      // `any` is still set: a lattice WAS requested and attempted, and a run
      // whose every rung was ungradeable must still write a lattice_export
      // record saying so. Silence there would read as a transport failure.
      lat_agg.any = true;
      ++lat_agg.ungradeable_variants;
      return;
    }
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // Aggregated FIRST, and unconditionally on `void_check_ran`, so a PASS is
    // recorded too — a run whose receipt only spoke when something was wrong
    // would be indistinguishable from a run where the check never fired.
    if (R.void_check_ran) {
      const LatticeVoidEscapeReport& vr = R.void_report;
      lat_agg.void_check_ran = true;
      lat_agg.void_wall_s += R.void_check_seconds;
      lat_agg.void_bfs_visits += vr.bfs_visits;
      lat_agg.void_latticed_reached += vr.latticed_reached;
      lat_agg.void_latticed_cells += vr.latticed_cells;
      lat_agg.void_reachable_volume_mm3 += vr.reachable_escape_volume_mm3;
      lat_agg.void_sealed_pockets_without_lattice +=
          vr.sealed_pockets_without_lattice;
      if (vr.lattice_escape_depth > lat_agg.void_escape_depth_max)
        lat_agg.void_escape_depth_max = vr.lattice_escape_depth;
      for (int f = 0; f < 6; ++f)
        if (vr.face_escapes[f]) lat_agg.void_face_escapes[f] = true;
      if (R.void_sealed) {
        lat_agg.void_sealed_cells += vr.sealed_cells;
        lat_agg.void_sealed_voxels += vr.latticed_sealed;
        lat_agg.void_sealed_volume_mm3 += vr.sealed_volume_mm3;
      }
    }
    // The REFUSAL, on the ladder: skip this rung, say so, and — exactly as for
    // an ungradeable rung — leave it OUT of the aggregates below, which take
    // MINs that a rung with no geometry would drag to zero. The other rungs are
    // unaffected; one unlatticeable rung must not destroy the run's output.
    if (R.void_sealed) {
      std::fprintf(stderr, "[lattice] vf=%.2f NO LATTICE EMITTED — %s\n",
                   v.requested_volume_fraction, R.void_sealed_reason.c_str());
      std::fflush(stderr);
      lat_agg.any = true;
      ++lat_agg.void_sealed_variants;
      return;
    }
    lat_agg.wall_s += R.gen_seconds;
    const LatticeExportOutcome& oc = R.oc;
    const LatticeCertOutcome& cc = R.cc;
    const GradedField& gf = R.gf;
    const bool graded = R.graded;
    const double cell = R.cell_mm;
    const LatticeRoleReceipt& role_rcpt = R.role_rcpt;
    const std::string& rcpt_path = R.receipt_path;

    lat_agg.any = true;
    // Role / companion / grading aggregation (stages 1+4).
    if (roles_present) {
      lat_agg.roles_present = true;
      lat_agg.include_regions =
          static_cast<long long>(lattice_roles.includes.size());
      lat_agg.exclude_regions =
          static_cast<long long>(lattice_roles.excludes.size());
      lat_agg.include_void += role_rcpt.include_void_voxels;
      lat_agg.include_void_clearance += role_rcpt.include_void_by_clearance;
    }
    // ── FROZEN MATERIAL, PER VARIANT, ON STDERR (task 2026-08-04-protect-freeze-
    // vs-solidity). The maintainer's whole case was invisible because nothing
    // ever said it: 91.5 % of his declared lattice region was frozen, and the
    // receipt he read had no word for that. This line says it at the moment it
    // becomes true, in the same place every other per-variant fact is logged.
    //
    // *** IT IS NOT A WARNING, AND MUST NOT BECOME ONE. *** Lattice over frozen
    // material is a legitimate, now-expressible intent ("do not reshape this
    // wall, but DO lattice inside it"). Warning on it would train users away
    // from the thing they are supposed to be able to do. The warning below
    // fires on the case that IS unsatisfiable: an include region over a
    // clearance void, where there is no material to lattice and never will be.
    const LatticeFrozenReceipt& fz = R.frozen_rcpt;
    if (fz.present) {
      lat_agg.frozen_printed += fz.frozen_printed;
      lat_agg.frozen_latticed += fz.frozen_latticed;
      lat_agg.frozen_solid += fz.frozen_kept_solid;
      lat_agg.frozen_not_emitted += fz.frozen_cells_not_emitted;
      lat_agg.frozen_both += fz.frozen_voxels_strut_and_solid;
      lat_agg.frozen_unexplained += fz.frozen_strut_and_solid_unexplained;
      lat_agg.frozen_excl_latticed += fz.frozen_in_exclude_latticed;
      std::fprintf(stderr,
                   "[lattice] vf=%.2f frozen material: printed=%lld latticed=%lld "
                   "solid=%lld in_include=%lld in_exclude=%lld/%lld latticed "
                   "(audit: cells_not_emitted=%lld strut_and_solid=%lld "
                   "unexplained=%lld)\n",
                   v.requested_volume_fraction, fz.frozen_printed,
                   fz.frozen_latticed, fz.frozen_kept_solid,
                   fz.frozen_in_include, fz.frozen_in_exclude_latticed,
                   fz.frozen_in_exclude, fz.frozen_cells_not_emitted,
                   fz.frozen_voxels_strut_and_solid,
                   fz.frozen_strut_and_solid_unexplained);
    }
    // THE WARNING, AIMED AT THE THING THAT CANNOT WORK: an include region over a
    // declared keep-clear. There is no material there and no rung, cell size or
    // formulation can put any there — unlike frozen material (which is material,
    // and can be latticed) or optimizer-removed material (which a heavier rung
    // may carry). This is the ONLY lattice-region overlap that is a real
    // conflict, so it is the only one that warns.
    if (role_rcpt.include_void_by_clearance > 0)
      std::fprintf(stderr,
                   "[lattice] WARNING: vf=%.2f — %lld voxels of the declared "
                   "lattice INCLUDE region fall inside a declared \"Keep clear\" "
                   "region. A keep-clear is a hole: there is no material there "
                   "to lattice, and no rung or cell size can create any. Move "
                   "the include region off the keep-clear, or drop the "
                   "keep-clear.\n",
                   v.requested_volume_fraction,
                   role_rcpt.include_void_by_clearance);
    if (oc.solid_companion) {
      lat_agg.solid_voxels += oc.solid_region_voxels;
      lat_agg.solid_vol += oc.solid_region_volume_mm3;
      lat_agg.solid_tris += static_cast<long long>(oc.solid_region_triangles);
    }
    if (graded) {
      lat_agg.graded = true;
      lat_agg.g_cell = gf.cell_size_mm;
      lat_agg.g_floor = gf.printability_floor_mm;
      lat_agg.g_floored = gf.cell_size_floored;
      lat_agg.g_band_lo = gf.band_rho_min;
      lat_agg.g_band_hi = gf.band_rho_max;
      lat_agg.g_cpm_floor = gf.cells_per_member_floor;
      lat_agg.g_rho_lo = gf.rho_min_used;
      lat_agg.g_rho_hi = gf.rho_max_used;
      lat_agg.g_region = static_cast<long long>(gf.region_voxels);
      lat_agg.g_latticed = static_cast<long long>(gf.latticed_voxels);
      lat_agg.g_fallback = static_cast<long long>(gf.solid_fallback_voxels);
      lat_agg.g_min_width = gf.min_member_width_mm;
      lat_agg.g_min_cpm = gf.min_cells_per_member;
      lat_agg.g_min_d = gf.min_strut_diameter_mm;
      lat_agg.g_max_d = gf.max_strut_diameter_mm;
      lat_agg.g_below_min = gf.any_strut_below_min;
      lat_agg.g_ungradeable = gf.region_ungradeable;
      fill_grading_cell_plan(lat_agg.g_cell_ri, gf);
      fill_grading_fit(lat_agg.g_cell_ri, gf, job, &lattice_roles);
      if (gf.cell_mode == CellSizeMode::Fit)
        fill_fit_region_voxels(lat_agg.g_cell_ri, solved_grid,
                               v.optimization.physical_density,
                               run_printed_iso(options), lattice_roles.includes, gf);
      fill_grading_subfloor(lat_agg.g_cell_ri, gf);
    }
    lat_agg.cells += oc.stats.latticed_cells;
    lat_agg.voxels += oc.region_voxels;
    lat_agg.tris += static_cast<long long>(oc.stats.triangles);
    lat_agg.clipped += static_cast<long long>(oc.stats.clipped_struts);
    lat_agg.landings += static_cast<long long>(oc.stats.landings);
    lat_agg.anchors += static_cast<long long>(oc.stats.anchor_nodes);
    lat_agg.skin_tris += static_cast<long long>(oc.stats.skin_triangles);
    lat_agg.rim_tris += static_cast<long long>(oc.stats.rim_triangles);
    lat_agg.interior_vol += oc.stats.interior_volume_mm3;
    lat_agg.skin_vol += oc.stats.skin_volume_mm3;
    lat_agg.rim_vol += oc.stats.rim_volume_mm3;
    lat_agg.chords += static_cast<long long>(oc.stats.skin_chords);
    lat_agg.chords_band +=
        static_cast<long long>(oc.stats.skin_chords_rejected_band);
    lat_agg.chords_proj +=
        static_cast<long long>(oc.stats.skin_chords_rejected_projection);
    lat_agg.chords_clipped +=
        static_cast<long long>(oc.stats.skin_chords_clipped_away);
    ++lat_agg.variants;
    lat_agg.r_min = std::min(lat_agg.r_min, oc.stats.min_strut_diameter_mm / 2.0);
    lat_agg.r_max = std::max(lat_agg.r_max, oc.stats.max_strut_diameter_mm / 2.0);
    lat_agg.cert_ran = true;
    // Graded runs have no uniform rho — the certified range is the law's
    // achieved band; uniform runs keep the point value.
    lat_agg.rho_lo =
        std::min(lat_agg.rho_lo, graded ? gf.rho_min_used : cc.rho);
    lat_agg.rho_hi =
        std::max(lat_agg.rho_hi, graded ? gf.rho_max_used : cc.rho);
    lat_agg.cert_voxels += static_cast<long long>(cc.lattice.lattice_voxels);
    lat_agg.lat_margin_min =
        std::min(lat_agg.lat_margin_min, cc.lattice.margin.worst_case);
    lat_agg.lat_margin_eff_min =
        std::min(lat_agg.lat_margin_eff_min, cc.lattice.margin_effective);
    // The run-level verdict uses the same upstream finish refusal as the
    // receipt: a "skin" finish is never reported accepted (finish_note there).
    const bool eff_accepted =
        cc.lattice.accepted && job.lattice.outer_finish != "skin";
    lat_agg.lat_accepted_all = lat_agg.lat_accepted_all && eff_accepted;
    lat_agg.strut_uncertified =
        lat_agg.strut_uncertified || cc.lattice.lattice_strength_uncertified;
    // Strut-strength report roll-up (report-only; min = worst variant).
    if (cc.lattice.lattice_strut_report) {
      const StrutStrengthReport& ss = cc.lattice.lattice_strut;
      lat_agg.strut_report = true;
      lat_agg.strut_in_plane_min =
          std::min(lat_agg.strut_in_plane_min, ss.margin_in_plane);
      lat_agg.strut_il_min = std::min(lat_agg.strut_il_min, ss.margin_interlayer);
      lat_agg.strut_worst_min =
          std::min(lat_agg.strut_worst_min, ss.margin_worst_case);
      lat_agg.strut_zk = ss.z_knockdown_used;
      lat_agg.strut_cpm_min = std::min(lat_agg.strut_cpm_min,
                                       cc.lattice.lattice_min_cells_per_member);
      lat_agg.strut_oor =
          lat_agg.strut_oor || cc.lattice.lattice_strut_out_of_regime;
      lat_agg.strut_clamped += static_cast<long long>(ss.rho_clamped_voxels);
    }
    lattice_paths.insert(lattice_paths.end(), oc.paths.begin(), oc.paths.end());
    if (stream_lines)
      for (const std::string& p : oc.paths) {
        if (graded) {
          // Graded line (NEW with stage 4 — no pre-existing consumer): the
          // uniform strut_r/rho keys would be lies here, so the line carries
          // graded=1 + the achieved rho RANGE instead. Key=value tokens, same
          // discipline as the uniform line.
          std::printf(
              "LATTICE vf=%.6f topology=%s cell_mm=%.6g graded=1 rho_min=%.6g "
              "rho_max=%.6g cells=%lld tris=%llu lattice_margin=%.6g "
              "lattice_accepted=%d report=%s mesh=%s\n",
              v.requested_volume_fraction, job.lattice.topology.c_str(), cell,
              gf.rho_min_used, gf.rho_max_used, oc.stats.latticed_cells,
              (unsigned long long)oc.stats.triangles,
              cc.lattice.margin.worst_case, eff_accepted ? 1 : 0,
              rcpt_path.c_str(), p.c_str());
        } else {
          std::printf(
              "LATTICE vf=%.6f topology=%s cell_mm=%.6g strut_r_mm=%.6g rho=%.6g "
              "cells=%lld tris=%llu lattice_margin=%.6g lattice_accepted=%d "
              "report=%s mesh=%s\n",
              v.requested_volume_fraction, job.lattice.topology.c_str(),
              job.lattice.cell_mm, job.lattice.strut_radius_mm, cc.rho,
              oc.stats.latticed_cells, (unsigned long long)oc.stats.triangles,
              cc.lattice.margin.worst_case, eff_accepted ? 1 : 0,
              rcpt_path.c_str(), p.c_str());
        }
        std::fflush(stdout);
      }
  };

  // Fold the summed lattice EXPORT + CERTIFICATION postures into run_info. Called
  // from the mid-run finalize (streaming path, lat_agg complete by then) AND after
  // the batch export loop (batch path generates the lattice later). Idempotent — a
  // no-lattice run (lat_agg.any == false) touches nothing, so run_info.json stays
  // byte-for-byte the pre-lattice record (bar E2).
  // THE EXPORTED GEOMETRY'S FRAME (handoff 2026-08-01-bake-build-orientation).
  // Recorded from the rung the user actually exports — the lightest ACCEPTED
  // one, the same rung the build-orientation receipt describes — so run_info and
  // that receipt can never name different orientations. A run that writes
  // model-space coordinates sets nothing and its run_info stays byte-identical.
  auto finalize_export_frame_run_info = [&]() {
    const MinimizePlasticVariant* v = nullptr;
    for (const MinimizePlasticVariant& c : result.pipeline.evaluated)
      if (c.accepted) v = &c;
    if (v == nullptr || !v->export_baked) return;
    run_info.export_baked = true;
    run_info.export_build_direction_auto_applied = v->build_direction_auto_applied;
    run_info.export_rotation_exact =
        build_frame_rotation(v->applied_build_dir).axis_permutation;
    run_info.applied_build_dir_x = v->applied_build_dir.x;
    run_info.applied_build_dir_y = v->applied_build_dir.y;
    run_info.applied_build_dir_z = v->applied_build_dir.z;
  };

  auto finalize_lattice_run_info = [&]() {
    if (!lat_agg.any) return;
    const double job_wall = std::max(1e-9, wall_seconds() - job_t0);
    // Geometry (handoff 2026-07-28-lattice-generation-production).
    run_info.lattice_export_present = true;
    run_info.lattice_export_topology = job.lattice.topology;
    // Graded runs: the cell is the LAW's (per the last graded variant; each
    // variant's own cell is in its receipt). Uniform runs: the job's.
    run_info.lattice_export_cell_mm =
        lat_agg.graded ? lat_agg.g_cell : job.lattice.cell_mm;
    // A run where EVERY rung was ungradeable emitted no geometry at all, so the
    // "smallest strut" sentinel (1e30) is not an answer — there were no struts.
    // Zeroed explicitly rather than leaked, and `ungradeable_variants` beside it
    // is what says why (bar B3 / L3).
    run_info.lattice_export_strut_radius_min_mm =
        lat_agg.variants > 0 ? lat_agg.r_min : 0.0;
    run_info.lattice_export_strut_radius_max_mm = lat_agg.r_max;
    run_info.lattice_export_latticed_cells = lat_agg.cells;
    run_info.lattice_export_region_voxels = lat_agg.voxels;
    run_info.lattice_export_triangles = lat_agg.tris;
    run_info.lattice_export_variant_count = lat_agg.variants;
    run_info.lattice_export_ungradeable_variants = lat_agg.ungradeable_variants;
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // Only when the check actually ran; otherwise every field stays at its zero
    // default and the serializer writes no key at all (bar R1).
    if (lat_agg.void_check_ran) {
      run_info.lattice_void_check_ran = true;
      run_info.lattice_void_sealed_variants = lat_agg.void_sealed_variants;
      run_info.lattice_void_sealed_cells = lat_agg.void_sealed_cells;
      run_info.lattice_void_sealed_voxels = lat_agg.void_sealed_voxels;
      run_info.lattice_void_sealed_volume_mm3 = lat_agg.void_sealed_volume_mm3;
      run_info.lattice_void_latticed_reached = lat_agg.void_latticed_reached;
      run_info.lattice_void_latticed_cells = lat_agg.void_latticed_cells;
      run_info.lattice_void_reachable_volume_mm3 =
          lat_agg.void_reachable_volume_mm3;
      run_info.lattice_void_bfs_visits = lat_agg.void_bfs_visits;
      run_info.lattice_void_escape_depth_max = lat_agg.void_escape_depth_max;
      run_info.lattice_void_sealed_pockets_without_lattice =
          lat_agg.void_sealed_pockets_without_lattice;
      run_info.lattice_void_wall_seconds = lat_agg.void_wall_s;
      std::string faces;
      for (int f = 0; f < 6; ++f)
        if (lat_agg.void_face_escapes[f]) {
          if (!faces.empty()) faces += ",";
          faces += grid_face_name(static_cast<GridFace>(f));
        }
      run_info.lattice_void_escape_faces = faces;
    }
    run_info.lattice_export_emit_stl = job.lattice.emit_stl;
    run_info.lattice_export_emit_3mf = job.lattice.emit_3mf;
    run_info.lattice_export_interpenetrating_soup = true;
    run_info.lattice_export_gen_seconds = lat_agg.wall_s;
    run_info.lattice_export_gen_fraction = lat_agg.wall_s / job_wall;
    // Boundary finish (bar B9): the skin/rim/collar are part of the printed
    // object, so their triangle and volume shares are recorded, not folded in
    // silently. Volumes are the analytic per-primitive sums (soup basis).
    run_info.lattice_export_skin = job.lattice.skin;
    run_info.lattice_export_clipped_struts = lat_agg.clipped;
    run_info.lattice_export_landings = lat_agg.landings;
    run_info.lattice_export_anchor_nodes = lat_agg.anchors;
    run_info.lattice_export_skin_triangles = lat_agg.skin_tris;
    run_info.lattice_export_rim_triangles = lat_agg.rim_tris;
    run_info.lattice_export_interior_volume_mm3 = lat_agg.interior_vol;
    run_info.lattice_export_skin_volume_mm3 = lat_agg.skin_vol;
    run_info.lattice_export_rim_volume_mm3 = lat_agg.rim_vol;
    // Outer finish (task 2026-07-30-lattice-skin-freeform); the serializer
    // writes these keys only for a non-"shell" finish (byte-identity).
    run_info.lattice_export_outer_finish = job.lattice.outer_finish;
    run_info.lattice_export_skin_chords = lat_agg.chords;
    run_info.lattice_export_skin_chords_rejected_band = lat_agg.chords_band;
    run_info.lattice_export_skin_chords_rejected_projection = lat_agg.chords_proj;
    run_info.lattice_export_skin_chords_clipped_away = lat_agg.chords_clipped;
    run_info.lattice_export_finish_certified = job.lattice.outer_finish != "skin";
    // Lattice roles + solid companion (task lattice-page-core-hookup stage 1;
    // keys emitted only when roles/companion were in play — byte-identity).
    run_info.lattice_export_role_regions_present =
        lat_agg.roles_present || lat_agg.solid_voxels > 0 ||
        lat_agg.graded;  // graded runs emit the companion too
    run_info.lattice_export_include_regions = lat_agg.include_regions;
    run_info.lattice_export_exclude_regions = lat_agg.exclude_regions;
    run_info.lattice_export_solid_region_voxels = lat_agg.solid_voxels;
    run_info.lattice_export_solid_region_volume_mm3 = lat_agg.solid_vol;
    run_info.lattice_export_solid_region_triangles = lat_agg.solid_tris;
    run_info.lattice_export_include_void_voxels = lat_agg.include_void;
    run_info.lattice_export_include_void_by_clearance =
        lat_agg.include_void_clearance;
    run_info.lattice_forecast_present = fc_include_regions > 0;
    run_info.lattice_forecast_include_regions = fc_include_regions;
    run_info.lattice_forecast_region_too_thin = fc_region_too_thin;
    run_info.lattice_forecast_required_mm = fc_required_mm;
    run_info.lattice_forecast_thinnest_region_mm = fc_thinnest_mm;
    run_info.lattice_export_frozen_present = lat_agg.frozen_printed > 0;
    run_info.lattice_export_frozen_printed = lat_agg.frozen_printed;
    run_info.lattice_export_frozen_latticed = lat_agg.frozen_latticed;
    run_info.lattice_export_frozen_solid = lat_agg.frozen_solid;
    run_info.lattice_export_frozen_cells_not_emitted = lat_agg.frozen_not_emitted;
    run_info.lattice_export_frozen_voxels_strut_and_solid = lat_agg.frozen_both;
    run_info.lattice_export_frozen_strut_and_solid_unexplained =
        lat_agg.frozen_unexplained;
    run_info.lattice_export_frozen_in_exclude_latticed =
        lat_agg.frozen_excl_latticed;
    // Graded run (stage 4): the "grading" object — the same record the analyze
    // path writes, filled from the LAST graded variant (per-variant records live
    // in the receipts).
    if (lat_agg.graded) {
      run_info.grading_present = true;
      run_info.grading_topology = job.lattice.topology;
      run_info.grading_band_rho_min = lat_agg.g_band_lo;
      run_info.grading_band_rho_max = lat_agg.g_band_hi;
      run_info.grading_cells_per_member_floor = lat_agg.g_cpm_floor;
      run_info.grading_cell_size_mm = lat_agg.g_cell;
      run_info.grading_printability_floor_mm = lat_agg.g_floor;
      run_info.grading_cell_size_floored = lat_agg.g_floored;
      run_info.grading_min_extrudable_width_mm =
          job.grading.min_extrudable_width_mm;
      run_info.grading_rho_min_used = lat_agg.g_rho_lo;
      run_info.grading_rho_max_used = lat_agg.g_rho_hi;
      run_info.grading_region_voxels = lat_agg.g_region;
      run_info.grading_latticed_voxels = lat_agg.g_latticed;
      run_info.grading_solid_fallback_voxels = lat_agg.g_fallback;
      run_info.grading_min_member_width_mm = lat_agg.g_min_width;
      run_info.grading_min_cells_per_member = lat_agg.g_min_cpm;
      run_info.grading_min_strut_diameter_mm = lat_agg.g_min_d;
      run_info.grading_max_strut_diameter_mm = lat_agg.g_max_d;
      run_info.grading_any_strut_below_min = lat_agg.g_below_min;
      run_info.grading_region_ungradeable = lat_agg.g_ungradeable;
      // SUB-FLOOR RETENTION carried through the same aggregate carrier the cell
      // plan uses, so the optimize-path receipt cannot disagree with the
      // lattice-variant one about what was retained (handoff 2026-08-04-subfloor-
      // lattice-unloaded-regions).
      run_info.grading_subfloor_armed = lat_agg.g_cell_ri.grading_subfloor_armed;
      run_info.grading_subfloor_stress_fraction_ceiling =
          lat_agg.g_cell_ri.grading_subfloor_stress_fraction_ceiling;
      run_info.grading_subfloor_region_stress_fraction =
          lat_agg.g_cell_ri.grading_subfloor_region_stress_fraction;
      run_info.grading_subfloor_region_qualified =
          lat_agg.g_cell_ri.grading_subfloor_region_qualified;
      run_info.grading_subfloor_candidate_voxels =
          lat_agg.g_cell_ri.grading_subfloor_candidate_voxels;
      run_info.grading_subfloor_retained_voxels =
          lat_agg.g_cell_ri.grading_subfloor_retained_voxels;
      run_info.grading_subfloor_recovered_voxels =
          lat_agg.g_cell_ri.grading_subfloor_recovered_voxels;
      run_info.grading_subfloor_min_cells_per_member =
          lat_agg.g_cell_ri.grading_subfloor_min_cells_per_member;
      run_info.grading_subfloor_max_cells_per_member =
          lat_agg.g_cell_ri.grading_subfloor_max_cells_per_member;
      run_info.grading_cell_mode = lat_agg.g_cell_ri.grading_cell_mode;
      run_info.grading_cell_base_mm = lat_agg.g_cell_ri.grading_cell_base_mm;
      run_info.grading_cell_max_level = lat_agg.g_cell_ri.grading_cell_max_level;
      run_info.grading_cell_latticed_cells =
          lat_agg.g_cell_ri.grading_cell_latticed_cells;
      run_info.grading_cells_raised_to_floor =
          lat_agg.g_cell_ri.grading_cells_raised_to_floor;
      run_info.grading_cells_dropped_unprintable =
          lat_agg.g_cell_ri.grading_cells_dropped_unprintable;
      run_info.grading_cells_split_by_balance =
          lat_agg.g_cell_ri.grading_cells_split_by_balance;
      run_info.grading_cell_any_out_of_regime =
          lat_agg.g_cell_ri.grading_cell_any_out_of_regime;
      run_info.grading_cell_levels = lat_agg.g_cell_ri.grading_cell_levels;
      // FIT, through the same carrier for the same reason.
      run_info.grading_min_printable_cell_mm =
          lat_agg.g_cell_ri.grading_min_printable_cell_mm;
      run_info.grading_density_raised_for_print_voxels =
          lat_agg.g_cell_ri.grading_density_raised_for_print_voxels;
      run_info.grading_fit_out_of_regime_voxels =
          lat_agg.g_cell_ri.grading_fit_out_of_regime_voxels;
      run_info.grading_fit_no_derivation_voxels =
          lat_agg.g_cell_ri.grading_fit_no_derivation_voxels;
      run_info.grading_fit_distinct_cells =
          lat_agg.g_cell_ri.grading_fit_distinct_cells;
      run_info.grading_fit_printed_outside_regions =
          lat_agg.g_cell_ri.grading_fit_printed_outside_regions;
      run_info.grading_fit_regions = lat_agg.g_cell_ri.grading_fit_regions;
    }
    // Certification (handoff 2026-07-29-lattice-certification-e2e, bars E1/E3) — WHAT
    // the composite gate certified, so a variant's provenance is recoverable.
    if (lat_agg.cert_ran) {
      run_info.lattice_present = true;
      run_info.lattice_topology = job.lattice.topology;
      run_info.lattice_cell_size_mm =
          lat_agg.graded ? lat_agg.g_cell : job.lattice.cell_mm;
      run_info.lattice_rho_min = lat_agg.rho_lo;
      run_info.lattice_rho_max = lat_agg.rho_hi;
      run_info.lattice_region_voxels = lat_agg.cert_voxels;
      run_info.lattice_margin_worst_case = lat_agg.lat_margin_min;
      run_info.lattice_margin_effective = lat_agg.lat_margin_eff_min;
      run_info.lattice_accepted = lat_agg.lat_accepted_all;
      run_info.lattice_strength_uncertified = lat_agg.strut_uncertified;
      // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report):
      // the run-level worst of the report-only de-homogenized margins. Keys are
      // emitted only when a report ran, so older latticed records (and every
      // non-lattice record) stay byte-identical.
      if (lat_agg.strut_report) {
        run_info.lattice_strut_report_present = true;
        run_info.lattice_strut_margin_in_plane = lat_agg.strut_in_plane_min;
        run_info.lattice_strut_margin_interlayer = lat_agg.strut_il_min;
        run_info.lattice_strut_margin_worst_case = lat_agg.strut_worst_min;
        run_info.lattice_strut_z_knockdown = lat_agg.strut_zk;
        run_info.lattice_strut_min_cells_per_member = lat_agg.strut_cpm_min;
        run_info.lattice_strut_out_of_regime = lat_agg.strut_oor;
        run_info.lattice_strut_rho_clamped_voxels = lat_agg.strut_clamped;
      }
    }
  };

  std::vector<std::string> streamed_paths;
  // ── THE DESIGN CONTAINER, PUBLISHED AS THE LADDER GOES (task
  //    2026-08-03-variant-postprocessing-fix, defect 1) ────────────────────────
  // design.bin used to be written ONCE, after the whole ladder (see the write at
  // the end of this function). A streaming client shows each variant the moment
  // its VARIANT line arrives, so for the entire length of a run — and forever
  // after, for a run that ends any way other than "ran to completion" — the
  // variants on screen had no design container and could not be latticed or
  // smoothed. That is exactly what the maintainer hit: his M2_verticalStand run
  // streamed three variants, was killed on rung 4 of 4, and its out/ has the
  // three meshes and NO design.bin, report.json or fields.bin at all.
  //
  // So the container is now flushed after EVERY variant the driver reports. The
  // flush carries the SAME blocks the final write would for those variants (one
  // writer, one rule: every evaluated variant with a density field), and the
  // final write is unchanged — so a run that does complete produces the identical
  // file it produced before. Publication is atomic (design_store.cpp renames),
  // because the worker may serve this file mid-rewrite.
  //
  // Scoped to the STREAMING path deliberately: only a run someone is watching can
  // be observed part-way, and a batch `topopt-cli run` writes exactly what it did.
  //
  // ── …AND THE FIELD CONTAINER WITH IT (task
  //    2026-08-03-variant-postprocessing-concurrency, bar 3) ───────────────────
  // A four-rung ladder takes hours. Rung 1's OWN von Mises field is what the
  // lattice page's AUTO density grades from and what the results overlays draw,
  // and it exists in memory the moment rung 1 finishes — but `fields.bin` was
  // written only at final assembly, so for the whole rest of the run (and forever,
  // if the run died) rung 1 had a design and no field. Both halves of "the
  // artifacts a variant carries" are now published together, per rung.
  //
  // BORROWED, NOT COPIED — AND BORROWED ONLY WITHIN ONE CALL. A per-rung flush
  // must serialise every rung so far, and copying them would cost ~50 MB per rung
  // of duplication at 128³ (PR 291's first cut copied a trimmed variant per rung;
  // adding the fields to that was not affordable). So it borrows.
  //
  // What it does NOT do is ACCUMULATE the borrowed pointers. An earlier cut kept a
  // `std::vector<const MinimizePlasticVariant*>` alive across calls, which is
  // correct exactly as long as `result.evaluated` never reallocates. It does not —
  // minimize_plastic.cpp reserves it to the ladder length, states the invariant out
  // loud and asserts it, and this repo -UNDEBUGs the `topopt` target so that assert
  // survives Release. But the invariant lived in a different file from the code
  // depending on it, and the cost of someone deleting that reserve() is
  // use-after-free, not a wrong number. So `on_variant` now hands over the live
  // container and the pointers are built and consumed INSIDE this lambda. They
  // cannot outlive a reallocation because they do not outlive the call, and the
  // reserve is an optimisation again rather than a correctness requirement.
  const std::string design_stream_path = join_path(out_dir, "design.bin");
  const std::string fields_stream_path = join_path(out_dir, "fields.bin");
  auto publish_artifacts_so_far =
      [&](const std::vector<MinimizePlasticVariant>& evaluated_so_far) {
    // ACCEPTED only, which is exactly what the accumulating version held:
    // `on_variant` fires only for accepted rungs, so every pointer it ever pushed
    // was an accepted one. Filtering here says so directly instead of depending on
    // the ladder stopping at the first rejection, and keeps the streamed
    // containers byte-identical to what they carried before.
    std::vector<const MinimizePlasticVariant*> so_far;
    so_far.reserve(evaluated_so_far.size());
    for (const MinimizePlasticVariant& e : evaluated_so_far)
      if (e.accepted) so_far.push_back(&e);
    // Best-effort BOTH: an artifact that cannot be written must never take a run
    // down. The final writes still throw — those are the contract.
    try {
      write_design_file(design_stream_path, so_far, solved_grid);
    } catch (const std::exception&) {
    }
    try {
      write_fields_file(fields_stream_path, so_far, solved_grid);
    } catch (const std::exception&) {
    }
  };
  if (emit_progress) {
    options.progress = [](std::size_t rung, std::size_t rungs, int iter) {
      std::printf("PROGRESS rung=%zu rungs=%zu iter=%d\n", rung, rungs, iter);
      std::fflush(stdout);
    };
    options.on_variant = [&](const MinimizePlasticVariant& v,
                             const std::vector<MinimizePlasticVariant>&
                                 evaluated_so_far) {
      // `on_variant` fires ONLY for ACCEPTED rungs (minimize_plastic.cpp guards
      // the call with `if (result.evaluated.back().accepted)`), so the running
      // containers hold exactly the rungs that have streamed — which is exactly
      // the set a client can see. The FINAL writes add any rejected rungs
      // design.bin also carries, and are unchanged, so a completed run ships the
      // identical files it always did.
      publish_artifacts_so_far(evaluated_so_far);
      if (!v.accepted) return;
      const std::string p =
          export_variant_mesh(v, out_dir, job.output, solved_grid,
                              run_printed_iso(options), &result.model);
      streamed_paths.push_back(p);
      // The analytic design, written BESIDE the mesh into out_dir (S1(d)).
      // ★ AND DELIBERATELY NOT PUSHED INTO THE PATH LIST. `mesh_paths` means
      // "one exported MESH per accepted variant" — test_cli asserts exactly
      // that, by count and by filename pattern, and then re-imports each entry
      // as a mesh. An `alpha.f64` in that list breaks all three, which is what
      // it did until this line changed. The file still lands in out_dir and the
      // worker still serves out_dir; it simply is not a mesh and does not claim
      // to be one.
      (void)export_variant_alpha(v, out_dir, job.output, solved_grid);
      // `achieved` is the optimizer-achieved (continuous) fraction — the stream's
      // join key against the report's volume_fraction; `printed` is the printed/count
      // basis the app's savings uses (handoff 104, additive — a new field; older
      // readers ignore it). Both come from the same variant.
      std::printf(
          "VARIANT vf=%.6f achieved=%.6f printed=%.6f margin=%.6g accepted=1 mesh=%s\n",
          v.requested_volume_fraction, v.optimization.volume_fraction,
          v.report.printed_fraction, v.report.margin.worst_case, p.c_str());
      std::fflush(stdout);
      // Latticed companion (streaming path): generated + checkpointed as the
      // variant completes, alongside the solid mesh.
      emit_lattice(v, /*stream_lines=*/true);
    };
  }

  // ★ THE THREAD OVERRIDE, APPLIED HERE AND NOWHERE EARLIER (task
  // 2026-08-10-plsm-production). `configure_production_options` sets the
  // matrix-free apply's thread count to the performance-core pin, so a caller
  // that set it before run_job would have been silently overwritten. 0 (the
  // default) leaves the production rule alone and this line does nothing. It is
  // a pure performance control — fea.hpp guarantees the apply is BIT-IDENTICAL
  // for any thread count, because it colours the grid deterministically — so it
  // cannot move a number, only how much of the machine the run takes.
  if (obs.matfree_threads > 0) {
    fea_set_matfree_threads(obs.matfree_threads);
    if (options.plsm.mode == PlsmMode::Parametric)
      options.plsm.threads = obs.matfree_threads;
  }
  // ★ AND THE SOLVER POSTURE OVERRIDES, HERE FOR THE SAME REASON AND NOT ONE
  // LINE EARLIER (task solver-speed-arm-and-diagnose). See RunObservability in
  // job.hpp: `configure_production_options` re-asserts both of these globals at
  // the start of the run — deliberately, so a thread that ran a harness earlier
  // cannot carry an armed solver into a production run — which means the ONLY
  // correct place to override them is after it and before the first solve.
  // -1 is the default on both and applies nothing, so the CLI's runs and every
  // existing caller are byte-identical.
  if (obs.mg_algebraic_level1 >= 0)
    fea_set_mg_algebraic_level1(obs.mg_algebraic_level1 != 0);
  if (obs.matfree_mixed_precision >= 0)
    fea_set_matfree_mixed_precision(obs.matfree_mixed_precision != 0);
  // The latch re-arm is NOT re-asserted by configure_production_options (it has
  // no production writer at all), but it IS zeroed by the run-start latch reset
  // in minimize_plastic, so it is applied here alongside the other two rather
  // than relying on a caller having set it at the right moment.
  if (obs.mg_rearm_period > 0)
    fea_matfree_set_mg_rearm_period(obs.mg_rearm_period);
  // The run_info written up front recorded the PRE-override posture; re-read it
  // now so the artifact says what the run actually did. Without this an armed
  // arm reports `mg_algebraic_level1: false` and reads as a null result.
  run_info.mg_algebraic_level1 = fea_mg_algebraic_level1_enabled();
  run_info.mixed_precision = fea_matfree_mixed_precision_enabled();
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
    // ★ ACHIEVED MASS AS A FRACTION OF THE SOLID PART (task 2026-08-13 §0.5).
    // The rung is a fraction of the ACTIVE envelope, so a frozen region that
    // stopped costing its envelope moves what the rung MEANS — and a latticed
    // ladder then cannot be compared with an unlatticed one at all. This is the
    // one number that survives that: the same denominator either way.
    //
    // The denominator is the PART grid, not the design box. The numerator is the
    // RECOMMENDED variant, i.e.
    // the last accepted rung, which is the recommendation under BOTH ladders.
    // Mass here is analyze.cpp's own formula, not a re-derivation: density_g_cm3
    // x voxel-equivalents x voxel_volume / 1000.
    {
      // `grid` here is `setup.grid` — the PART grid, BEFORE design-box
      // expansion (`resolve_design_domain` derives the solved grid from it), so
      // the box's empty space is correctly not part of "the solid part".
      const double solid_voxels = static_cast<double>(grid.solid_count());
      const double solid_mass_g = material.density_g_cm3 * solid_voxels *
                                  grid.voxel_volume() / 1000.0;
      const MinimizePlasticVariant* rec = nullptr;
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
        if (v.accepted) rec = &v;
      // Left unobserved (JSON null) when nothing was accepted or the part has no
      // solid voxels — a 0.0 would read like a measured weightless part.
      if (rec != nullptr && solid_mass_g > 0.0) {
        run_info.achieved_solid_fraction = rec->mass_grams / solid_mass_g;
        run_info.achieved_solid_fraction_observed = true;
      }
    }
    // Lattice CERTIFICATION posture (handoff 2026-07-29-lattice-certification-e2e,
    // bars E1/E3). When the job declared a lattice block, each accepted variant was
    // re-certified against the octet tensor (emit_lattice → certify_latticed_variant),
    // and the run-level posture is summed here — like lattice_export. The serializer
    // emits the "lattice" key ONLY when lattice_present, so a NON-lattice run writes no
    // key and run_info.json stays byte-for-byte the pre-lattice record (bar E2). This
    // records WHAT was certified: the composite object's worst strength margin, the
    // density and the certifiable band the gate enforced (E5), and the honest
    // strut-strength-uncertified flag — so a variant's provenance is recoverable. It is
    // populated by finalize_lattice_run_info (called just before write_run_info below),
    // which covers BOTH the streaming and batch generation paths.
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
    // Handoff 2026-08-02-warm-start-coarse-experiment — finalize the coarse
    // pre-solve's own cost (0/0 when it was never armed), so the run record
    // carries the price beside the posture and no speedup read off this run can
    // omit it.
    run_info.warm_start_coarse_iterations =
        result.pipeline.warm_start_coarse_iterations;
    run_info.warm_start_coarse_ms = result.pipeline.warm_start_coarse_ms;
    run_info.warm_start_coarse_matvecs =
        result.pipeline.warm_start_coarse_matvecs;
    // The DOF-weighted cost and BOTH its denominators. solved_grid_dofs is
    // filled even when the cascade was never armed: it is the denominator any
    // DOF-weighted reading of this run needs, and a record that only carries it
    // when a feature fired cannot be used to compare against a run where it
    // didn't.
    run_info.warm_start_coarse_dof_touches =
        result.pipeline.warm_start_coarse_dof_touches;
    run_info.warm_start_coarse_grid_dofs =
        result.pipeline.warm_start_coarse_grid_dofs;
    run_info.solved_grid_dofs = result.pipeline.solved_grid_dofs;
    // Handoff 123 — finalize the conditional-projection outcome: which rungs fired
    // and the grayscale Mnd measured on each (empty when the gate was disarmed).
    run_info.conditional_projection_fired.assign(
        result.pipeline.conditional_projection_fired.begin(),
        result.pipeline.conditional_projection_fired.end());
    run_info.conditional_projection_rung_mnd =
        result.pipeline.rung_grayscale_mnd;
    // Task 2026-08-08-semdot-does-it-come-out-smoother — finalize the per-rung
    // SEMDOT outcome from each rung's own SimpOptimizeResult. Empty when the mode
    // was off, so an unarmed run claims nothing about it.
    if (options.simp.semdot) {
      run_info.semdot_rung_level_set.clear();
      run_info.semdot_rung_fractional_voxels.clear();
      run_info.semdot_rung_design_voxels.clear();
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
        run_info.semdot_rung_level_set.push_back(v.optimization.semdot_level_set);
        run_info.semdot_rung_fractional_voxels.push_back(
            static_cast<long long>(v.optimization.semdot_fractional_voxels));
        run_info.semdot_rung_design_voxels.push_back(
            static_cast<long long>(v.optimization.semdot_design_voxels));
      }
    }
    // Task 2026-08-10-plsm-production — finalize the PARAMETRIC posture from the
    // run's own first evaluated rung: the RESOLVED knot spacing (three numbers,
    // per axis), the coefficient count, and the measured load-path floor. The
    // resolved spacing overwrites the requested one, because a receipt has to
    // state what ran; a job that left the knots at zero asked for the derived
    // rule, and this is what the rule gave. Untouched (and zero) when the mode
    // was off, so an unarmed run claims nothing about it.
    if (options.plsm.mode == PlsmMode::Parametric &&
        !result.pipeline.evaluated.empty()) {
      const MinimizePlasticVariant& v0 = result.pipeline.evaluated.front();
      run_info.plsm_knots_vox[0] = v0.plsm_lattice.dx;
      run_info.plsm_knots_vox[1] = v0.plsm_lattice.dy;
      run_info.plsm_knots_vox[2] = v0.plsm_lattice.dz;
      run_info.plsm_coefficients =
          static_cast<long long>(v0.plsm_lattice.count());
      run_info.plsm_frozen_floor_occupancy = v0.plsm_frozen_floor_occupancy;
      // Task 2026-08-13 — WHAT ACTUALLY HAPPENED, from the first evaluated
      // rung. `plsm_stop_reason` is the one that cannot be omitted: a run that
      // hit the iteration ceiling and a run whose certified margin plateaued
      // are different objects, and reading the second as the first is what made
      // a 60-iteration cap look like a converged setting for three tasks.
      run_info.plsm_stop_reason = v0.plsm_stop_reason;
      run_info.plsm_margin_peak_iteration = v0.plsm_margin_peak_iteration;
      run_info.plsm_margin_peak = v0.plsm_margin_peak;
      run_info.plsm_margin_probe_wall_s = v0.plsm_margin_probe_wall_s;
      run_info.plsm_frac_cut_cells =
          static_cast<long long>(v0.plsm_frac_cut_cells);
      run_info.plsm_frac_sample_wall_s = v0.plsm_frac_sample_wall_s;
      run_info.plsm_frac_sens_wall_s = v0.plsm_frac_sens_wall_s;
      run_info.plsm_void_components = v0.plsm_topology.components;
      run_info.plsm_void_chi = v0.plsm_topology.chi;
      run_info.plsm_void_enclosed_solid = v0.plsm_topology.enclosed_solid;
      run_info.plsm_void_sealed_pockets = v0.plsm_topology.sealed_pockets;
      run_info.plsm_void_tunnels = v0.plsm_topology.tunnels;
      run_info.plsm_void_sealed_voxels = v0.plsm_topology.sealed_voxels;
      run_info.plsm_void_sealed_volume_mm3 = v0.plsm_topology.sealed_volume_mm3;
    }
    // Handoff 131 — finalize the per-rung infeasibility outcome (one entry per
    // evaluated rung; all-false is the positive statement "no rung lost its load
    // path"). Written only now, like cg_multigrid, so an unfinished run claims
    // nothing either way.
    run_info.rung_infeasible.assign(result.pipeline.rung_infeasible.begin(),
                                    result.pipeline.rung_infeasible.end());
    // Handoff 2026-07-27-nonconvergence-rejection — finalize the per-rung
    // non-convergence outcome (which rungs a linear solve failed to converge on,
    // with the iteration and residual each reached), same finalize-only discipline.
    run_info.rung_non_convergent.assign(
        result.pipeline.rung_non_convergent.begin(),
        result.pipeline.rung_non_convergent.end());
    run_info.rung_non_convergent_iteration.assign(
        result.pipeline.rung_non_convergent_iteration.begin(),
        result.pipeline.rung_non_convergent_iteration.end());
    run_info.rung_non_convergent_residual.assign(
        result.pipeline.rung_non_convergent_residual.begin(),
        result.pipeline.rung_non_convergent_residual.end());
    // Task 2026-08-03-preflight-feasibility-and-divergence — finalize the two
    // DIVERGENCE guards' per-rung outcomes, each with the numbers it fired on
    // (bar P6). All-false is the positive statement "no guard fired".
    run_info.rung_diverged.assign(result.pipeline.rung_diverged.begin(),
                                  result.pipeline.rung_diverged.end());
    run_info.rung_diverged_iteration =
        result.pipeline.rung_diverged_iteration;
    run_info.rung_diverged_c_ratio = result.pipeline.rung_diverged_c_ratio;
    run_info.rung_diverged_cg_ratio = result.pipeline.rung_diverged_cg_ratio;
    run_info.rung_diverged_wall_ratio =
        result.pipeline.rung_diverged_wall_ratio;
    run_info.rung_time_budget.assign(result.pipeline.rung_time_budget.begin(),
                                     result.pipeline.rung_time_budget.end());
    run_info.rung_time_budget_iteration =
        result.pipeline.rung_time_budget_iteration;
    run_info.rung_time_budget_ms = result.pipeline.rung_time_budget_ms;
    run_info.rung_time_budget_elapsed_ms =
        result.pipeline.rung_time_budget_elapsed_ms;
    run_info.rung_time_budget_baseline_ms =
        result.pipeline.rung_time_budget_baseline_ms;
    run_info.rung_time_budget_phase = result.pipeline.rung_time_budget_phase;
    run_info.rung_time_budget_phase_ms =
        result.pipeline.rung_time_budget_phase_ms;
    // active-domain phase 1 — finalize the per-rung latch outcome. All-false
    // (with a band > 0) is the positive statement "the band held for every
    // rung"; a true entry names the rung that fell back to the full domain and
    // why, so a run that bought nothing SAYS so instead of silently costing.
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
      // The DERIVED k this rung ran with (what the AUTO sentinel resolved to), so
      // a run armed with active_domain_band = -1 records the concrete width beside
      // the request.
      run_info.active_domain_band_resolved.push_back(
          v.optimization.active_domain_band);
      run_info.active_domain_latched.push_back(
          v.optimization.active_domain_latched ? 1 : 0);
      run_info.active_domain_latch_iteration.push_back(
          v.optimization.active_domain_latch_iteration);
      run_info.active_domain_escape_count.push_back(
          v.optimization.active_domain_escape_count);
      run_info.active_domain_latch_reason.push_back(
          v.optimization.active_domain_latch_reason);
      run_info.active_domain_fraction_mean.push_back(
          v.optimization.active_fraction_mean);
    }
    // Handoff 2026-07-25-draft-quality — finalize the per-rung draft outcome (empty
    // when draft was off): the measured tightening tail k, the certified-vs-
    // trajectory compliance gap, and which rungs escalated. Same finalize-only
    // discipline as cg_multigrid, so an unfinished run asserts nothing about draft.
    run_info.draft_rung_tail_k.assign(result.pipeline.draft_rung_tail_k.begin(),
                                      result.pipeline.draft_rung_tail_k.end());
    run_info.draft_rung_c_gap = result.pipeline.draft_rung_c_gap;
    run_info.draft_rung_escalated.assign(
        result.pipeline.draft_rung_escalated.begin(),
        result.pipeline.draft_rung_escalated.end());
    // Handoff 2026-07-26-draft-quality-phase2 — the design-space probe outcome.
    run_info.draft_rung_probe_flip = result.pipeline.draft_rung_probe_flip;
    run_info.draft_rung_probe_cg = result.pipeline.draft_rung_probe_cg;
    // Handoff 2026-07-29-geneo-arming — finalize the GenEO deflation lifecycle:
    // basis builds / coarse refreshes / preconditioned fallback solves this run,
    // and the coarse dimension + stored MB held at run end. All 0 when the
    // feature is off or no solve ever reached the stagnation trigger.
    // Task algebraic-level1-coarsening — finalize what the LAST algebraic
    // hierarchy build produced (aggregates, level-1 dimension, depth, added
    // bytes) and whether it REFUSED and fell back to the geometric builder.
    // All 0 / false when the path is off, which is every reference run.
    {
      const MgAlgebraicLevel1Info a = fea_mg_algebraic_level1_info();
      run_info.mg_algebraic_aggregates = a.aggregates;
      run_info.mg_algebraic_coarse_dim = a.coarse_dim;
      run_info.mg_algebraic_levels = a.levels;
      run_info.mg_algebraic_added_mb =
          static_cast<double>(a.bytes) / (1024.0 * 1024.0);
      run_info.mg_algebraic_level1_refused = a.refused;
      run_info.mg_algebraic_refuse_reason = a.refuse_reason;
    }
    // MULTISCALE LATTICE TO (task multiscale-lattice-to) — the receipt for "the
    // optimizer placed the lattice". Filled from the per-variant reports the
    // driver produced, in ladder order, so every EVALUATED rung is described,
    // not only the shipped one. Absent entirely on a non-multiscale run.
    if (options.multiscale_lattice) {
      run_info.multiscale_armed = true;
      run_info.multiscale_topology =
          lattice_topology_name(options.multiscale_topology);
      run_info.multiscale_floor_cell_mm = options.multiscale_floor_cell_mm;
      run_info.multiscale_floor_stride = options.multiscale_floor_stride;
      run_info.multiscale_floor_cells =
          lattice_cells_per_member_min(options.multiscale_topology);
      for (const MinimizePlasticVariant& v : result.pipeline.evaluated) {
        const MinimizePlasticVariant::MultiscaleReport& m = v.multiscale;
        if (!m.multiscale) continue;
        run_info.multiscale_region_voxels =
            static_cast<long long>(m.region_voxels);
        run_info.multiscale_fit_rows = static_cast<long long>(m.fit_rows);
        run_info.multiscale_rho_lo = m.rho_lo;
        run_info.multiscale_rho_hi = m.rho_hi;
        run_info.multiscale_floor_ceiling_measured =
            static_cast<long long>(m.floor_ceiling_measured);
        run_info.multiscale_floor_ceiling_eligible =
            static_cast<long long>(m.floor_ceiling_eligible);
        run_info.multiscale_floor_ceiling_min_cells = m.floor_ceiling_min_cells;
        RunInfo::MultiscaleRung R;
        R.volume_fraction = v.requested_volume_fraction;
        R.voxels_void = static_cast<long long>(m.voxels_void);
        R.voxels_band = static_cast<long long>(m.voxels_band);
        R.voxels_solid = static_cast<long long>(m.voxels_solid);
        R.voxels_lower_gap = static_cast<long long>(m.voxels_lower_gap);
        R.voxels_upper_gap = static_cast<long long>(m.voxels_upper_gap);
        R.band_rho_min = m.band_rho_min;
        R.band_rho_max = m.band_rho_max;
        R.projected_lower = static_cast<long long>(m.projected_lower);
        R.projected_upper = static_cast<long long>(m.projected_upper);
        R.projection_volume_delta = m.projection_volume_delta;
        R.projection_max_density_move = m.projection_max_density_move;
        R.volume_fraction_before_projection = m.volume_fraction_before_projection;
        R.volume_fraction_after_projection = m.volume_fraction_after_projection;
        R.volume_fraction_target = m.volume_fraction_target;
        R.volume_constraint_violation = m.volume_constraint_violation;
        R.floor_measured_voxels = static_cast<long long>(m.floor_measured_voxels);
        R.floor_below_voxels = static_cast<long long>(m.floor_below_voxels);
        R.floor_min_cells_per_member = m.floor_min_cells_per_member;
        for (std::size_t b : m.floor_histogram)
          R.floor_histogram.push_back(static_cast<long long>(b));
        for (const auto& fs : m.floor_history) {
          RunInfo::MultiscaleRung::FloorSample S;
          S.iteration = fs.iteration;
          S.measured = static_cast<long long>(fs.measured);
          S.below = static_cast<long long>(fs.below);
          S.min_cells_per_member = fs.min_cells_per_member;
          R.floor_history.push_back(S);
        }
        run_info.multiscale_rungs.push_back(std::move(R));
      }
    }
    run_info.geneo_basis_builds = fea_geneo_basis_builds();
    run_info.geneo_coarse_refreshes = fea_geneo_coarse_refreshes();
    run_info.geneo_armed_solves = fea_geneo_armed_solves();
    run_info.geneo_basis_dim = fea_geneo_basis_dim();
    run_info.geneo_basis_mb =
        static_cast<double>(fea_geneo_basis_bytes()) / (1024.0 * 1024.0);
    // Handoff 2026-08-02-geneo-disarm — the engagement gate's decisions: how many
    // fallback solves a held basis was offered to and declined, and the event log
    // of every arm/disarm transition with the numbers it fired on (bar AA5).
    run_info.geneo_declined_solves = fea_geneo_declined_solves();
    run_info.geneo_decisions_dropped = fea_geneo_decisions_dropped();
    run_info.geneo_decisions.clear();
    for (int gi = 0; gi < fea_geneo_decision_count(); ++gi)
      run_info.geneo_decisions.push_back(fea_geneo_decision_at(gi));
    // Lattice EXPORT + CERTIFICATION posture — finalized via the shared lambda so the
    // streaming and batch paths agree; a no-lattice run writes NO key (P1 / bar E2).
    // On the batch path lat_agg is still empty here (emit_lattice runs after the mesh
    // loop below); the post-export re-write catches it.
    finalize_lattice_run_info();
    finalize_export_frame_run_info();
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

  // Handoff 2026-07-27-nonconvergence-rejection — LOUD NON-CONVERGENCE. A rung whose
  // linear solve did not converge is a rejected rung, not a quiet one, and — unlike
  // before this change — it no longer takes the whole run down with it. Say so on
  // stderr, once per rung, with the iteration and residual the solve reached, in the
  // same spirit as the loud infeasibility warning above.
  for (std::size_t i = 0; i < result.pipeline.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = result.pipeline.evaluated[i];
    if (!v.non_convergent) continue;
    const int nc_iter = i < result.pipeline.rung_non_convergent_iteration.size()
                            ? result.pipeline.rung_non_convergent_iteration[i]
                            : 0;
    const double nc_resid =
        i < result.pipeline.rung_non_convergent_residual.size()
            ? result.pipeline.rung_non_convergent_residual[i]
            : 0.0;
    std::fprintf(stderr,
                 "WARNING: rung %zu (vf %.2f) was REJECTED — %s. A linear solve did "
                 "not reach the CG tolerance %.3g: it stalled at residual %.3g after "
                 "%d iterations. This rung was NOT certified and no mesh, stress "
                 "analysis or margin is reported for it; the run completed and every "
                 "already-accepted variant is unaffected. See report.json "
                 "rejected_variants and run_info.json rung_non_convergent.\n",
                 i, v.requested_volume_fraction, kRungNonConvergentReason,
                 options.simp.cg_tolerance, nc_resid, nc_iter);
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

  // ──▶ the BUILD-ORIENTATION RECEIPT (handoff 2026-08-01-build-direction-
  // separation). A SEPARATE document, written only when the scorer was armed, so
  // report.json above and the meshes below are byte-identical whether it ran or
  // not (bar U1). It carries the RECOMMENDATION for the rung the run itself
  // recommends — the LIGHTEST ACCEPTED variant, i.e. the design the user is
  // actually going to print. Ranking the heavier rungs too would publish
  // recommendations for designs nobody exports.
  {
    const MinimizePlasticVariant* rec_variant = nullptr;
    for (const MinimizePlasticVariant& v : result.pipeline.evaluated)
      if (v.accepted && v.build_orientation.evaluated) rec_variant = &v;
    if (rec_variant != nullptr) {
      result.build_orientation_path =
          join_path(out_dir, "build_orientation.json");
      // The receipt reports the direction in the MODEL frame (every candidate
      // vector in the document is a model-frame vector) and carries the export
      // rotation beside it, so the reader is told which frame is which rather
      // than left to infer it. Off the bake path the rotation is absent and the
      // document is byte-identical to PR 271's.
      const std::optional<BuildFrameRotation> R =
          variant_bake_rotation(*rec_variant);
      result.build_orientation_json = build_orientation_report_json(
          rec_variant->build_orientation, rec_variant->applied_build_dir,
          R ? &*R : nullptr);
      write_text_file(result.build_orientation_path,
                      result.build_orientation_json);
    }
  }

  // ──▶ meshes: already written progressively when streaming; otherwise one
  // exported mesh per accepted variant now (byte-identical to the streamed files).
  if (emit_progress) {
    result.mesh_paths = std::move(streamed_paths);
    // Lattice companions were generated in the on_variant callback (streaming).
  } else {
    for (const MinimizePlasticVariant& variant : result.pipeline.evaluated) {
      if (!variant.accepted) continue;
      result.mesh_paths.push_back(export_variant_mesh(
          variant, out_dir, job.output, result.pipeline.solved_grid,
          run_printed_iso(options), &result.model));
      // The analytic design, written beside the mesh (S1(d)) and NOT added to
      // `mesh_paths` — see the streaming branch above for why.
      (void)export_variant_alpha(variant, out_dir, job.output,
                                 result.pipeline.solved_grid);
      emit_lattice(variant, /*stream_lines=*/false);  // batch: no stdout lines
    }
  }
  // Latticed companions land AFTER the solid meshes in mesh_paths (both paths), so
  // the worker serves them as ordinary out_dir artifacts (item 3: the iPad fetches
  // the file, never holds the mesh).
  result.mesh_paths.insert(result.mesh_paths.end(), lattice_paths.begin(),
                           lattice_paths.end());

  // Batch path (no streaming): emit_lattice ran in the loop just above, AFTER the
  // mid-run run_info write, so lat_agg is only now complete. Re-finalize the lattice
  // posture and re-write so a batch lattice run records its certification/export
  // provenance too (handoff 2026-07-29-lattice-certification-e2e). A streaming run
  // already recorded it; this re-write is identical there. Gated on lat_agg.any, so a
  // no-lattice run never touches run_info here (byte-identical, bar E2).
  if (wrote_run_info && !emit_progress && lat_agg.any) {
    finalize_lattice_run_info();
    finalize_export_frame_run_info();
    write_run_info(result.run_info_path, run_info);
  }

  // ──▶ *** THE ORIENTATION WAS CHOSEN FOR YOU — SAID OUT LOUD ***
  // (handoff 2026-08-01-bake-build-orientation, bar V7.) A run that picks the
  // orientation and rotates the exported geometry onto it has made a decision
  // the user did not make, and one that can change the verdict. The receipt says
  // so and the app says so; a CLI user who reads neither still gets told here,
  // on stderr, beside the other WARNINGs — the same channel that already
  // announces a rejected rung. Silence is the one thing this must never be.
  {
    // The rung the user actually exports — the LIGHTEST accepted one, the same
    // rung build_orientation.json describes, so the two cannot name different
    // orientations.
    const MinimizePlasticVariant* v = nullptr;
    for (const MinimizePlasticVariant& c : result.pipeline.evaluated)
      if (c.accepted && c.build_direction_auto_applied) v = &c;
    if (v != nullptr) {
    const bool rescued = v->build_orientation.auto_apply_changed_verdict;
    std::fprintf(
        stderr,
        "%s: no build_direction was declared, so this run CHOSE one "
        "(%.4g, %.4g, %.4g) and ROTATED the exported geometry onto it — in the "
        "file the build direction is +Z. The verdict describes that "
        "orientation.%s Declare \"build_direction\" to use your own instead "
        "(the export is then left in model coordinates). See "
        "build_orientation.json.\n",
        // `+ 0.0` clears NEGATIVE ZEROS before printing: unit(-gravity) of
        // (0,0,-1) is (-0,-0,1), and "(-0, -0, 1)" reads like a bug in a line
        // whose whole job is to be trusted at a glance.
        rescued ? "*** IMPORTANT" : "NOTE", v->applied_build_dir.x + 0.0,
        v->applied_build_dir.y + 0.0, v->applied_build_dir.z + 0.0,
        rescued ? " *** THIS PART PASSES BECAUSE OF THAT CHOICE: printed the "
                  "way this run would otherwise have assumed (the opposite of "
                  "gravity) it FAILS its strength check. ***"
                : "");
    std::fflush(stderr);
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

  // ──▶ the DESIGN container (task 2026-08-02-lattice-a-variant): each evaluated
  // variant's own density field, the thing "lattice this variant" needs and the
  // one artifact a run never kept. A SEPARATE file, deliberately: report.json,
  // fields.bin and every mesh above stay byte-for-byte what they were, so the
  // whole existing optimize path is unchanged (bar Z6) and this is purely
  // additive. Older readers ignore it. See design_store.hpp for why the field is
  // stored at full double precision.
  result.design_path = join_path(out_dir, "design.bin");
  result.design_variant_count =
      write_design_file(result.design_path, result.pipeline,
                        result.pipeline.solved_grid);

  return result;
}

}  // namespace topopt
