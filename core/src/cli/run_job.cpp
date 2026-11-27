#include "topopt/job.hpp"
#include "topopt/lattice_file_strength.hpp"  // Install 3 (V4)
#include "topopt/lattice_layout_frame.hpp"   // brief E2: the Organic check, a frame of beams
#include "topopt/lattice_layout_break.hpp"   // C2: the Organic break check
#include "topopt/gate_diagnosis_eval.hpp"     // diagnose_gate, for the check's diagnosis
#include "topopt/strut_strength.hpp"
#include "../flexible/json.hpp"   // the strength settings (Install 3), read by the always-built reader
#include <sstream>
#include "topopt/flexible/job_block.hpp"  // refuse_flexible_job
#include "topopt/lattice_dc.hpp"
#include "topopt/lattice_union_volume.hpp"
#include "topopt/lattice_volume_check.hpp"
#include "topopt/organic_wet_join.hpp"
#include "topopt/voxel_sdf.hpp"
#include "topopt/stepped_plan.hpp"

#include <algorithm>
#include <cstdint>
#include <deque>
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
#include <queue>
#include <set>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>
#include <unistd.h>

#include "topopt/analyze.hpp"
#include "topopt/build_frame.hpp"
#include "topopt/cad_project.hpp"
#include "topopt/finish.hpp"
#include "topopt/clearance.hpp"
#include "topopt/face_region.hpp"
#include "topopt/coarsen.hpp"
#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/fields.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_algorithm.hpp"
#include "topopt/print_frame.hpp"   // P2: his print orientation, the door
#include "topopt/print_orientation.hpp"   // P4, P5: the candidates, the bed
#include "topopt/support_paint.hpp"   // P3, P5: painted supports
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_types.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/feature_edges.hpp"
#include <unordered_set>
#include "topopt/tpms_gen.hpp"
#include "topopt/lattice_void.hpp"
#include "topopt/beam_network.hpp"
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
#include "topopt/orient.hpp"
#include "topopt/settings.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/threemf_stream.hpp"
#include "topopt/version.hpp"
#include "topopt/voxel.hpp"
#ifdef TOPOPT_HAVE_MANIFOLD
#include "manifold/manifold.h"
#endif
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
  info.build_time = obs.build_time;
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
// The variant's exported solid in MODEL coordinates (before any build-frame bake):
// the shell the file carries, so a caller can certify exactly what is exported
// (CORE LIST item 50 verifies it). export_variant_mesh writes it.
// CORE LIST item KEEP — inside each keep region the export carries the PART's own
// geometry, exactly: (export - K) + (part ^ K), one merged shell, by Manifold. The
// optimizer froze the part there, so the two meet. Without Manifold in this build, or
// on a mesh Manifold cannot take as a closed manifold, the voxel surface stays and a
// WARNING says so (the kept material is still frozen, only not exact).
// The voxel surface pokes up to half a voxel PAST the part's own faces, and outside a
// region it stays: a region that sits flush on a face keeps those bumps just above it
// (measured 0.29 mm over a 30-degree face at 1.1 mm voxels). So a region meant to make
// a face exact reaches at least one voxel out past it, into the air, where the part
// has nothing to restore (test_keep_oriented).
// E1 (reviewer's ruling 2026-11-03 02:46): THE WRITTEN FILE IS CLEAN. Manifold's
// output is manifold in its own indices, but two of its vertices can be distinct and
// round to ONE float: a zero-area sliver on them puts its long edge on four triangles
// once the file is read (his squish rig: 4 such edges where a Protect cylinder's end
// met the voxel surface). And where Protect boxes meet the voxel surface the boolean
// leaves loose slivers of voxel bump in the air above the face (68 on that rig, 0.00
// to 0.25 mm3, beside a 99,842 mm3 part). Every shell under one solve voxel
// (`min_piece_mm3`) goes, in the boolean's own indices first and then welded as
// written (clean_cut_as_written), never one of the export's own bodies; a result
// still not clean is tried again with the voxel surface nudged another way, and said
// if none is.
#ifdef TOPOPT_HAVE_MANIFOLD
manifold::Manifold mesh_manifold(const TriangleMesh& m) {
  manifold::MeshGL g;
  g.numProp = 3;
  g.vertProperties.reserve(3 * m.vertices.size());
  for (const Vec3& v : m.vertices) {
    g.vertProperties.push_back(static_cast<float>(v.x));
    g.vertProperties.push_back(static_cast<float>(v.y));
    g.vertProperties.push_back(static_cast<float>(v.z));
  }
  for (const auto& t : m.triangles)
    for (int k = 0; k < 3; ++k) g.triVerts.push_back(static_cast<uint32_t>(t[k]));
  return manifold::Manifold(g);
}

TriangleMesh manifold_mesh(const manifold::MeshGL& g) {
  TriangleMesh out;
  out.vertices.reserve(g.NumVert());
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

// A keep region as a solid, grown by `grow` mm. Its round side is a 128-gon; `cover`
// CIRCUMSCRIBES it (the polygon's edges touch the circle from outside, so the solid
// holds all of the true region), as a cutter must.
manifold::Manifold keep_region_solid(const KeepRegion& k, double grow, bool cover = false) {
  constexpr int kSeg = 128;
  const double rs = cover ? 1.0 / std::cos(3.14159265358979323846 / kSeg) : 1.0;
  if (k.oriented) {  // centred primitive, then the region's own (right-handed) frame
    const manifold::Manifold prim =
        k.cylinder ? manifold::Manifold::Cylinder(2.0 * (k.half.z + grow), rs * (k.half.x + grow),
                                                  -1.0, kSeg, true)
                   : manifold::Manifold::Cube({2.0 * (k.half.x + grow),
                                               2.0 * (k.half.y + grow),
                                               2.0 * (k.half.z + grow)},
                                              true);
    auto col = [](const Vec3& v) { return manifold::vec3{v.x, v.y, v.z}; };
    return prim.Transform(manifold::mat3x4(col(k.axes[0]), col(k.axes[1]), col(k.axes[2]),
                                           col(k.center)));
  }
  const manifold::vec3 lo{k.min.x - grow, k.min.y - grow, k.min.z - grow};
  const manifold::vec3 ext{k.max.x - k.min.x + 2 * grow, k.max.y - k.min.y + 2 * grow,
                           k.max.z - k.min.z + 2 * grow};
  manifold::Manifold prim;
  if (!k.cylinder) {
    prim = manifold::Manifold::Cube(ext).Translate(lo);
  } else {
    const double len = k.axis == 0 ? ext.x : k.axis == 1 ? ext.y : ext.z;
    const double r = rs * 0.5 * (k.axis == 0 ? ext.y : ext.x);
    prim = manifold::Manifold::Cylinder(len, r, r, kSeg);  // along +Z from 0
    if (k.axis == 0) prim = prim.Rotate(0.0, 90.0, 0.0);   // +Z -> +X
    if (k.axis == 1) prim = prim.Rotate(-90.0, 0.0, 0.0);  // +Z -> +Y
    const manifold::vec3 c{lo.x + 0.5 * ext.x, lo.y + 0.5 * ext.y, lo.z + 0.5 * ext.z};
    prim = prim.Translate({k.axis == 0 ? lo.x : c.x, k.axis == 1 ? lo.y : c.y,
                           k.axis == 2 ? lo.z : c.z});
  }
  return prim;
}

// A Keep clear primitive as a solid (clearance.hpp's region, grown by `grow` mm), in its
// own right-handed frame: the bolt's swept cylinder about its axis (circumscribed, as
// above), the face's slab on its plane. A voxel-set or outlined region (an include's,
// never a Keep clear's) has no primitive: empty.
manifold::Manifold clearance_solid(const ClearanceGeometry& g, double grow) {
  if (!g.valid || g.mask != nullptr || !g.outline_uv.empty()) return manifold::Manifold();
  auto col = [](const Vec3& v) { return manifold::vec3{v.x, v.y, v.z}; };
  auto add = [](const Vec3& a, const Vec3& b) { return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}; };
  auto mul = [](const Vec3& a, double k) { return Vec3{a.x * k, a.y * k, a.z * k}; };
  auto dot = [](const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
  auto cross = [](const Vec3& a, const Vec3& b) {
    return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
  };
  auto normalize = [&](const Vec3& a) { return mul(a, 1.0 / std::sqrt(dot(a, a))); };
  // ★ E4 (j): a cut piece's Keep clear is trimmed to its clips' half-spaces, each
  // pushed out by `grow` as the primitive is. No clips: the primitive, as before E4.
  auto clip = [&](manifold::Manifold m) {
    for (const ClearanceClip& c : g.clips) {
      const Vec3 n = normalize(c.normal);
      m = m.TrimByPlane(col(n), dot(c.point, n) - grow);
    }
    return m;
  };
  if (g.kind == ClearanceKind::Bolt) {
    constexpr int kSeg = 128;
    const Vec3 a = normalize(g.axis_dir);
    const Vec3 e1 = normalize(cross(a, std::fabs(a.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0}));
    const Vec3 e2 = cross(a, e1);  // e1 x e2 = a
    const manifold::Manifold prim = manifold::Manifold::Cylinder(
        g.t_hi - g.t_lo + 2.0 * grow,
        (g.radius + grow) / std::cos(3.14159265358979323846 / kSeg), -1.0, kSeg);
    return clip(prim.Transform(manifold::mat3x4(col(e1), col(e2), col(a),
                                                col(add(g.axis_point, mul(a, g.t_lo - grow))))));
  }
  Vec3 u = g.u, w = g.w;
  double u_lo = g.u_lo, u_hi = g.u_hi, w_lo = g.w_lo, w_hi = g.w_hi;
  if (dot(cross(u, w), g.normal) < 0.0) {  // the frame (u, w, normal) right-handed
    std::swap(u, w);
    std::swap(u_lo, w_lo);
    std::swap(u_hi, w_hi);
  }
  const manifold::Manifold prim = manifold::Manifold::Cube(
      {u_hi - u_lo + 2.0 * grow, w_hi - w_lo + 2.0 * grow, g.depth + 2.0 * grow});
  const Vec3 o = add(add(add(g.origin, mul(u, u_lo - grow)), mul(w, w_lo - grow)),
                     mul(g.normal, -grow));
  return clip(prim.Transform(manifold::mat3x4(col(u), col(w), col(g.normal), col(o))));
}
#endif

TriangleMesh keep_regions_exact(const TriangleMesh& exported, const TriangleMesh& part,
                                const std::vector<KeepRegion>& keeps,
                                double min_piece_mm3 = 0.0) {
  if (keeps.empty()) return exported;
#ifdef TOPOPT_HAVE_MANIFOLD
  const auto to_manifold = mesh_manifold;
  // The part side is taken with each region GROWN by kFuse, so the two pieces
  // overlap by that much and fuse across a volume: cut exactly at K, they touched
  // along lines on K's boundary (his plate: 22 four-way edges at r = 7.0).
  constexpr double kFuse = 0.05;  // mm, below any print resolution
  // The export side is cut with each region grown by kCut. Two regions that meet only
  // along an edge (diagonal neighbours on a face) otherwise leave the export's two
  // other quadrants touching along that edge wherever the export stands proud of the
  // part, where no part solid fuses them: his stand v4, 2 four-way edges 0.06 mm tall
  // above the top face, and every version refused as "not one clean solid". Grown,
  // the regions overlap there. kCut stays under kFuse so the two pieces still fuse
  // across a volume.
  constexpr double kCut = 0.01;  // mm
  manifold::Manifold K, K_part;
  for (const KeepRegion& k : keeps) {
    K = K + keep_region_solid(k, kCut);
    K_part = K_part + keep_region_solid(k, kFuse);
  }
  // The voxel surface is NUDGED 1 um along a slanted direction first. A part face on
  // a voxel plane (his flat bottom at z = 0) is otherwise exactly where the voxel
  // surface is, and in the kFuse overlap the two coplanar sheets left edges on four
  // triangles once written as floats (2 on the tilted test); 1 um apart they fuse
  // cleanly, far below any print resolution. The part side is never moved.
  constexpr double kNudge = 1e-3;  // mm
  // The nudges tried, in order: the first is the one every earlier export used.
  constexpr double kNudges[3][3] = {
      {0.5377, 0.8326, 0.1327}, {-0.4103, 0.2311, 0.8821}, {0.7071, -0.5513, 0.4428}};
  const manifold::Manifold E0 = to_manifold(exported);
  const manifold::Manifold E = E0.Translate(
      {kNudge * kNudges[0][0], kNudge * kNudges[0][1], kNudge * kNudges[0][2]});
  const manifold::Manifold P = to_manifold(part);
  if (E.Status() != manifold::Manifold::Error::NoError ||
      P.Status() != manifold::Manifold::Error::NoError) {
    std::fprintf(stderr,
                 "WARNING: KEEP regions: the %s mesh is not a closed manifold "
                 "(Manifold status %d), so the kept regions are exported from the "
                 "voxels, not exactly.\n",
                 E.Status() != manifold::Manifold::Error::NoError ? "exported" : "part",
                 static_cast<int>(E.Status() != manifold::Manifold::Error::NoError
                                      ? E.Status()
                                      : P.Status()));
    return exported;
  }
  const int bodies = audit_as_written(exported).bodies;
  const manifold::Manifold PK = P ^ K_part;
  TriangleMesh out;
  int dropped = 0;
  for (int n = 0; n < 3; ++n) {
    const manifold::Manifold En =
        n == 0 ? E
               : E0.Translate({kNudge * kNudges[n][0], kNudge * kNudges[n][1],
                               kNudge * kNudges[n][2]});
    out = manifold_mesh(((En - K) + PK).GetMeshGL());
    out = clean_cut_as_written(out, min_piece_mm3, bodies, &dropped);
    const WrittenAudit w = audit_as_written(out);
    if (w.non_manifold_edges == 0 && w.non_manifold_vertices == 0 && w.boundary_edges == 0) break;
    if (n == 2)
      std::fprintf(stderr,
                   "WARNING: KEEP regions: the exact export still has %d edge(s) on more than "
                   "two triangles and %d point contact(s) after three tries.\n",
                   w.non_manifold_edges, w.non_manifold_vertices);
  }
  if (dropped > 0)
    std::fprintf(stderr, "[keep] %d loose sliver(s) under one solve voxel dropped from the "
                 "exact export\n", dropped);
  return out;
#else
  (void)part;
  std::fprintf(stderr,
               "WARNING: KEEP regions: this build has no Manifold, so the kept "
               "regions are exported from the voxels, not exactly (they are still "
               "frozen).\n");
  return exported;
#endif
}

// KEEP CLEAR, EXACTLY (reviewer's ruling 2026-11-03 19:55, FINDING 1): a file prints
// NOTHING inside a Keep clear. The exports put material there on 7 of his jobs (a band
// up to half a voxel deep where the design meets a Keep clear: 418 to 838 mm3 on
// efe18e33 and e5909008), though no design voxel is in one. Every file is cut by
// Manifold, as exact Protect is: file - (Keep clears - part). The Keep clears are every
// declared primitive (a bolt's swept cylinder, a face's slab, in any orientation) and
// every Protect region's reach, whose air the optimizer keeps clear too
// (build_clearance_overlay). The part's own solid wins over a Keep clear, as in
// rasterize_clearance, so the material around a bore is never cut.
//
// THE CUTTER NEVER LIES ON THE FILE. The file's surface is the part's own wherever the
// CAD projection or exact Protect made it so, and a cutter whose boundary is that same
// surface re-cuts it: cut against the part itself, efe18e33 lost 13,151 vertices of the
// part's own surface and gained 6 edges on more than two triangles. So the part is
// GROWN by `eps` before it is taken away (the union of the part and its 26 copies moved
// eps along the 3 x 3 x 3 stencil: every face of it stands at least eps / sqrt(3) off the
// part's, edges and corners included), and a Protect region, which exact Protect has
// already cut the file at, is cut `eps` inside its own boundary. A declared Keep clear's
// round side is CIRCUMSCRIBED (no sliver of the true region stays uncut). eps is 2 um, a
// skin far below any print resolution and two orders above a float's rounding here.
struct KeepClearCut {
  bool any = false;  // a cutter to cut with
  bool part_ok = true;
  double eps_mm = 0.0;
#ifdef TOPOPT_HAVE_MANIFOLD
  manifold::Manifold cutter;
#endif
};

// The cutter for try `n` (0, 1, 2): eps 2, 4, 8 um, a declared Keep clear grown n um.
KeepClearCut make_keep_clear_cut(const TriangleMesh& part,
                                 const std::vector<ClearanceGeometry>& clears,
                                 const std::vector<KeepRegion>& keeps, int n = 0) {
  KeepClearCut c;
  if ((clears.empty() && keeps.empty()) || part.empty()) return c;
#ifdef TOPOPT_HAVE_MANIFOLD
  const manifold::Manifold P = mesh_manifold(part);
  if (P.Status() != manifold::Manifold::Error::NoError) {
    c.part_ok = false;
    return c;
  }
  c.eps_mm = 2e-3 * static_cast<double>(1 << n);
  const double grow = 1e-3 * n;
  std::vector<manifold::Manifold> grown{P};
  for (int i = -1; i <= 1; ++i)
    for (int j = -1; j <= 1; ++j)
      for (int k = -1; k <= 1; ++k) {
        if (i == 0 && j == 0 && k == 0) continue;
        const double s = c.eps_mm / std::sqrt(static_cast<double>(i * i + j * j + k * k));
        grown.push_back(P.Translate({s * i, s * j, s * k}));
      }
  std::vector<manifold::Manifold> K;
  for (const ClearanceGeometry& g : clears) K.push_back(clearance_solid(g, grow));
  for (const KeepRegion& k : keeps) {
    const double h = k.oriented ? std::min({k.half.x, k.half.y, k.half.z})
                                : 0.5 * std::min({k.max.x - k.min.x, k.max.y - k.min.y,
                                                  k.max.z - k.min.z});
    if (h > 2.0 * c.eps_mm) K.push_back(keep_region_solid(k, -c.eps_mm));
  }
  c.cutter = manifold::Manifold::BatchBoolean(K, manifold::OpType::Add) -
             manifold::Manifold::BatchBoolean(grown, manifold::OpType::Add);
  c.any = !c.cutter.IsEmpty();
#else
  (void)n;
  c.any = true;  // reported as not cut, below
#endif
  return c;
}

// `file` cut out of its Keep clears with `cut` (try 0, made once per run); a result not
// clean as written is cut again with tries 1 and 2. A file that reaches into none is
// returned as it is, byte for byte; `cut_mm3` (may be null) is the volume cut.
// A piece the cut leaves loose goes under one voxel (`min_piece_mm3`) or, given the
// printable minimum `thin_mm`, under that across (his efe18e33 at 1.10: 0.89 mm3, 0.72
// mm thin, a voxel being 0.87 mm3) — never one of the file's own bodies.
TriangleMesh keep_clear_exact(const TriangleMesh& file, const KeepClearCut& cut,
                              const TriangleMesh& part,
                              const std::vector<ClearanceGeometry>& clears,
                              const std::vector<KeepRegion>& keeps, double min_piece_mm3,
                              double* cut_mm3 = nullptr, double thin_mm = 0.0) {
  if (cut_mm3) *cut_mm3 = 0.0;
  if (!cut.part_ok)
    std::fprintf(stderr, "WARNING: KEEP CLEAR: the part mesh is not a closed manifold, so the "
                         "file is not cut out of its Keep clears.\n");
  if (!cut.any) return file;
#ifdef TOPOPT_HAVE_MANIFOLD
  // Below this the two only touch.
  constexpr double kTouchMm3 = 1e-6;
  const manifold::Manifold E = mesh_manifold(file);
  if (E.Status() != manifold::Manifold::Error::NoError) {
    std::fprintf(stderr, "WARNING: KEEP CLEAR: the exported mesh is not a closed manifold "
                         "(Manifold status %d), so it is not cut out of its Keep clears.\n",
                 static_cast<int>(E.Status()));
    return file;
  }
  const double v0 = (E ^ cut.cutter).Volume();
  if (!(v0 > kTouchMm3)) return file;
  const int bodies = audit_as_written(file).bodies;
  TriangleMesh out = file;
  for (int n = 0; n < 3; ++n) {
    const KeepClearCut retry = n == 0 ? KeepClearCut{} : make_keep_clear_cut(part, clears, keeps, n);
    const manifold::Manifold& C = n == 0 ? cut.cutter : retry.cutter;
    if (cut_mm3) *cut_mm3 = n == 0 ? v0 : (E ^ C).Volume();
    int dropped = 0;
    out = clean_cut_as_written(manifold_mesh((E - C).GetMeshGL()), min_piece_mm3, bodies,
                               &dropped, thin_mm);
    const WrittenAudit w = audit_as_written(out);
    if (w.non_manifold_edges == 0 && w.non_manifold_vertices == 0 && w.boundary_edges == 0) break;
    if (n == 2)
      std::fprintf(stderr,
                   "WARNING: KEEP CLEAR: the cut file still has %d edge(s) on more than two "
                   "triangles and %d point contact(s) after three tries.\n",
                   w.non_manifold_edges, w.non_manifold_vertices);
  }
  return out;
#else
  (void)part;
  (void)clears;
  (void)keeps;
  (void)min_piece_mm3;
  std::fprintf(stderr, "WARNING: KEEP CLEAR: this build has no Manifold, so the file is not "
                       "cut out of its Keep clears.\n");
  return file;
#endif
}

std::vector<ClearanceGeometry> lattice_keep_outs_from_job(const JobDescription& job,
                                                         const StepModel& model);

#include "to_export.inc"  // TO rebuild stage 0: moved unchanged

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
    const std::vector<LatticeSteppedPass>* stepped = nullptr,
    // ★ Drive free organic strut ends this far into the solid, then intersect the
    // welded field with the part (organic_weld). 0 = neither. A grading key, so it
    // arrives separately from JobLattice.
    double organic_strut_embed_mm = 0.0,
    // ★ Mesh the lattice by dual contouring its own SDF, into <prefix>_DC.stl beside the
    // welded pair. Grading keys, so they arrive separately from JobLattice.
    bool organic_dual_contour = false, double organic_dc_cell_mm = 0.0,
    double organic_dc_tolerance_mm = 0.0,
    // ★ Solve the bead factor against the spans this function EMITS, rather than against
    // the curves the tracer drew. See the calibration loop below.
    bool organic_calibrate_on_shipped = true,
    // ★ K4: EVERY EMITTED ELEMENT, FOR THE CALLER'S OWN LEDGER. The generator already
    // reports each one through LatticeGenObserver, and lattice_gen.hpp states that
    // observing never changes the emitted bytes -- but the observer is built INSIDE this
    // function, so a caller that wants to attribute struts to the plan's cells could not
    // reach it. This chains onto whichever observer the run already uses, so arming it
    // adds a callback and nothing else. Null on every run that does not ask.
    const std::function<void(LatticeGenElement, const Vec3&, const Vec3&, double)>*
        laid_tap = nullptr,
    // ★ Finding 7: THE EMITTED SOLID, FOR THE VOLUME CHECK. Non-null => every element of
    // the FIRST emission is rebuilt into it (the second writer emits the same stream), and
    // a sheet pass hands it the field its mesh is contoured from. Observing only, so the
    // bytes cannot move. Null on organic runs, which rebuild their own shipped density.
    LatticeSolidProbe* solid_probe = nullptr,
    // ★ Finding 8: the bead a sheet's wall must keep after its mesh is simplified (the
    // grading's stated minimum extrudable width). 0 = no floor to protect.
    double sheet_bead_mm = 0.0,
    // ★ E2.4 per region: the shell re-meshed around the design minus an open pocket
    // (null: the design's own, variant.v3.mesh).
    const TriangleMesh* shell_override = nullptr,
    // ★ Skin per zone (ruling 11-08 (1)): each anchor ball and chord asks its zone. Null:
    // the lattice's own skin everywhere, byte for byte.
    const LatticeSkinZones* skin_zones = nullptr,
    // ★ The rim on a real part (ruling 11-08 (A)): the chains it rides, already chosen
    // (the caller found them on the shipped surface and kept those its skin asks for).
    // Null: no rim, byte for byte.
    const LatticeMeshRimSpec* mesh_rim = nullptr,
    // ★ The part's own surface, when the part itself is latticed (ruling 11-09): the
    // solid companion is built on it (solid_on_part_surface). Null: the voxel body, byte
    // for byte.
    const TriangleMesh* solid_surface = nullptr) {
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
  // ★ Per zone, the passes open for the most any zone asks: a Woven zone arms the diagrid
  // and its freeform chords, and each element then asks its own zone (lattice_gen.cpp).
  const LatticeSkinSpec skin = [&] {
    LatticeSkinSpec sk = lattice_skin_for(lat);
    if (skin_zones != nullptr) {
      sk.zones = skin_zones;
      for (const LatticeSkinHere h : skin_zones->here) {
        if (h != LatticeSkinHere::Off && sk.mode == LatticeSkinMode::None)
          sk.mode = LatticeSkinMode::Diagrid;
        if (h == LatticeSkinHere::Woven) {
          sk.mode = LatticeSkinMode::Diagrid;
          sk.freeform = true;
        }
      }
    }
    return sk;
  }();

  const TriangleMesh& shell = shell_override != nullptr ? *shell_override : variant.v3.mesh;
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
    if (oc.solid_region_voxels > 0 && solid_surface != nullptr &&
        !solid_surface->triangles.empty()) {
      oc.solid_on_part_surface_asked = true;
      SolidOnSurface ss = solid_on_part_surface(sg, comp, dens, printed_iso, *solid_surface);
      if (ss.ok) {
        comp_mesh = std::move(ss.mesh);
        oc.solid_on_part_surface = true;
      } else {
        oc.solid_on_part_surface_refused = ss.why;
      }
    }
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
  const bool with_shell = shell_override != nullptr || lattice_shell_written(lat);
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
  // ★ E2.4 per region: measured against the DESIGN's surface, never a re-meshed shell that
  // leaves an open pocket outside it on purpose (the same mesh on every other run).
  const MeshDistance shell_dist(variant.v3.mesh);
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
    long long n_out = 0;          // triangle CORNERS outside (kept: the old number)
    long long n_seen = 0;         // triangle corners seen
    Vec3 worst{};
    long long worst_vertex = -1;
    // ★ CORNERS ARE NOT VERTICES, AND THE DIFFERENCE MATTERED. `one()` runs per
    // triangle CORNER, so a single escaping point is counted once per incident
    // triangle. The receipt read "5 of 980892 lattice vertices" for what was ONE
    // vertex of valence five -- it looked like a tolerance population and it was a
    // single strut end cap. Count distinct points, and the elements they sit on.
    std::set<std::array<long long, 3>> unique_out;   // quantised to 1 nm
    long long elements_out = 0;
    bool this_element_out = false;
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
        unique_out.insert({static_cast<long long>(std::llround(v.x * 1e6)),
                           static_cast<long long>(std::llround(v.y * 1e6)),
                           static_cast<long long>(std::llround(v.z * 1e6))});
        this_element_out = true;
        // ★ NAME EVERY ESCAPING VERTEX, NOT JUST THE WORST. Both observed runs put
        // EXACTLY FIVE vertices outside the shell -- 5 of 237,996 at 0.0318 mm and
        // 5 of 980,892 at 0.0017 mm. The magnitude scales with the cell and the count
        // does not, which is the signature of a FIXED SET of points rather than a
        // tolerance population. A single worst-vertex report cannot show that; the
        // whole set can.
        if (std::getenv("TOPOPT_PROTRUSION_TRACE"))
          std::fprintf(stderr,
                       "[protrusion] #%lld vertex %lld at (%.9g, %.9g, %.9g) out by "
                       "%.9g mm\n",
                       n_out, n_seen - 1, v.x, v.y, v.z, out);
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
  // The POST-CLIP spans, kept so the welded single-body file can be built from what
  // was actually written rather than from the traced intent.
  std::vector<OrganicSpan> organic_spans;
  // ★ WHERE THE BASE WAS CUT, so the WELD can cut the solid at the same plane. The
  // span trim and the marched body must agree on it or the file disagrees with itself.
  double organic_base_trim_z = 0.0;
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
    st.anchor_nodes = g.anchor_nodes;
    st.skin_triangles = g.skin_triangles;
    st.landings = g.anchor_nodes;
    oc.organic_spans_out = organic_spans;
    oc.organic_census_components.assign(
        g.census_components, g.census_components + OrganicGenStats::kCensusStages);
    oc.organic_census_len_mm.assign(g.census_len_mm,
                                    g.census_len_mm + OrganicGenStats::kCensusStages);
    oc.organic_census_grown_len_mm = g.census_grown_len_mm;
    oc.organic_support_components_before = g.support_components_before;
    oc.organic_support_components_after = g.support_components_after;
    oc.organic_support_fragments_dropped =
        static_cast<long long>(g.support_fragments_dropped);
    oc.organic_support_fragment_length_mm = g.support_fragment_length_mm;
    oc.organic_base_mat_stitches = static_cast<long long>(g.base_mat_stitches);
    oc.organic_base_mat_clusters = static_cast<long long>(g.base_mat_clusters);
    oc.organic_fill_mat_cells_outside_region =
        static_cast<long long>(g.fill_mat_cells_outside_region);

    oc.organic_emitted_components = static_cast<long long>(g.emitted_components);
    oc.organic_floating_before = g.floating_voxels_before;
    oc.organic_floating_after = g.floating_voxels_after;
    oc.organic_repair_legs = g.repair_legs_added;
    oc.organic_repair_rounds = g.repair_rounds;
    oc.organic_free_ends = static_cast<long long>(g.free_ends);
    oc.organic_free_end_len = g.free_end_length_mm;
    oc.organic_free_before = static_cast<long long>(g.free_ends_before_tie);
    oc.organic_ties = static_cast<long long>(g.ties_added);
    oc.organic_tie_len = g.tie_length_mm;
    oc.organic_free_unresolved = static_cast<long long>(g.free_ends_unresolved);
    oc.organic_pruned = static_cast<long long>(g.pruned_spans);
    oc.organic_pruned_len = g.pruned_length_mm;
    oc.organic_prune_rounds = g.prune_rounds;
    oc.organic_plate_contacts = static_cast<long long>(g.plate_contacts);
    oc.organic_net_landings = static_cast<long long>(g.net_skin_landings);
    oc.organic_net_members = static_cast<long long>(g.net_skin_members);
    oc.organic_net_length = g.net_skin_length_mm;
    oc.organic_net_joined = static_cast<long long>(g.net_skin_landings_joined);
    oc.organic_net_fallback = static_cast<long long>(g.net_skin_fallback_members);
    oc.organic_net_edge_landings = static_cast<long long>(g.net_skin_edge_landings);
    oc.organic_stranded_comps = static_cast<long long>(g.stranded_components_dropped);
    oc.organic_stranded_spans = static_cast<long long>(g.stranded_spans_dropped);
    oc.organic_stranded_len = g.stranded_length_dropped_mm;
    oc.organic_nodes_merged = static_cast<long long>(g.nodes_merged);
    oc.organic_merge_clusters = static_cast<long long>(g.merge_clusters);
    oc.organic_merge_degenerate = static_cast<long long>(g.merge_degenerate_spans);
    oc.organic_net_pruned = static_cast<long long>(g.net_skin_members_pruned);
    oc.organic_net_deg1 = static_cast<long long>(g.net_skin_degree_one);
    oc.organic_unsupported_found = static_cast<long long>(g.unsupported_islands_found);
    oc.organic_unsupported_left = static_cast<long long>(g.unsupported_islands_remaining);
    // ★ SPANS OVER OPEN AIR. This copy was missing, so run_info.json reported 0 on
    // every organic run no matter how many the pass had actually seen -- and this is
    // the metric that REPLACED the overhang fillet when that repair was removed for
    // depositing blobs up to nine times the strut. The repair went; the measurement
    // was supposed to remain, and instead the receipt read a clean zero on a part
    // where the old repair had fired on 3,720 spans. A printability condition
    // reported as absent is worse than one reported loudly.
    oc.organic_unsupported_spans = static_cast<long long>(g.unsupported_spans_seen);
    oc.organic_support_legs = static_cast<long long>(g.support_legs_added);
    oc.organic_support_leg_len = g.support_leg_length_mm;
    oc.organic_support_rounds = g.support_rounds;
    oc.organic_support_rounds_converged = g.support_rounds_converged;
    oc.organic_fp_rounds = g.fixed_point_rounds;
    oc.organic_fp_converged = g.fixed_point_converged;
    oc.organic_mutations = static_cast<long long>(g.mutations);
    oc.organic_support_impossible = static_cast<long long>(g.support_legs_impossible);
    oc.organic_unsupported_cells = static_cast<long long>(g.unsupported_cells_remaining);
    oc.organic_unsupported_mm3 = g.unsupported_volume_mm3;
    oc.organic_support_diagonal = static_cast<long long>(g.support_legs_diagonal);
    oc.organic_support_cut = static_cast<long long>(g.support_spans_cut);
    oc.organic_support_cleanup = static_cast<long long>(g.support_cleanup_pruned);
    oc.organic_base_trim_z = g.base_trim_z_mm;
    organic_base_trim_z = g.base_trim_found ? g.base_trim_z_mm : 0.0;
    oc.organic_base_trim_cut = static_cast<long long>(g.base_trim_spans_cut);
    oc.organic_base_trim_clipped = static_cast<long long>(g.base_trim_spans_clipped);
    oc.organic_base_trim_len = g.base_trim_length_mm;
    oc.organic_base_trim_found = g.base_trim_found;
    oc.organic_base_mat_struts = static_cast<long long>(g.base_mat_struts);
    oc.organic_base_mat_touchdowns = static_cast<long long>(g.base_mat_touchdowns);
    oc.organic_slenderness_violating = static_cast<long long>(g.slenderness_violating);
    oc.organic_slenderness_propped = static_cast<long long>(g.slenderness_propped);
    oc.organic_slenderness_impossible =
        static_cast<long long>(g.slenderness_impossible);
    oc.organic_slenderness_props = static_cast<long long>(g.slenderness_props_added);
    oc.organic_cantilever_reach = g.cantilever_max_reach_mm;
    oc.organic_cantilever_islands = static_cast<long long>(g.cantilever_islands);
    oc.organic_arched_spans = static_cast<long long>(g.arched_spans);
    oc.organic_arch_rise = g.arch_max_rise_mm;
    oc.organic_base_mat_len = g.base_mat_length_mm;
    oc.organic_base_mat_z = g.base_mat_z_mm;
    oc.organic_fill_cells = static_cast<long long>(g.fill_mat_cells);
    oc.organic_fill_struts = static_cast<long long>(g.fill_mat_struts);
    oc.organic_fill_len = g.fill_mat_length_mm;
    oc.organic_branch_seeds = static_cast<long long>(g.branch_seeds);
    oc.organic_branch_merges = static_cast<long long>(g.branch_merges);
    oc.organic_branch_trunks = static_cast<long long>(g.branch_trunks);
    oc.organic_branch_anchored = static_cast<long long>(g.branch_anchored_on_model);
    oc.organic_branch_len = g.branch_length_mm;
    oc.organic_support_cut_len = g.support_cut_length_mm;
    oc.organic_unsupported_found_cells = static_cast<long long>(g.unsupported_cells_found);
    oc.organic_support_layer_mm = g.support_layer_height_mm;
    oc.organic_support_grid_too_large = g.support_grid_too_large;
    oc.organic_emitted_largest_fraction = g.emitted_largest_length_fraction;
    oc.organic_emitted_stranded_mm = g.emitted_stranded_length_mm;
    st.interior_volume_mm3 = g.volume_mm3;
    return st;
  };
  // ★ THE SAME SPAN LEDGER FOR THE OCTET PASSES, so the WELDED body is available to
  // ALL THREE algorithms and not just organic. `on_element` fires once per emitted
  // solid with its segment and radius — a ball reports a == b — which is exactly what
  // the weld rasteriser needs, and observing never changes the emitted bytes
  // (lattice_gen.hpp). Without this, doubled and stepped still ship a soup of
  // thousands of closed shells and still trigger the floating-body misread.
  // ── ★★ THE BEAD IS CALIBRATED ON THE SPANS THAT SHIP ────────────────────────
  // (maintainer, 2026-09-17: "go ahead with the calibration rewrite".) It used to be
  // solved inside the tracer, against the CURVES. That is not the geometry that ships and
  // not even a shrunken version of it: measured on the M2 stand, the tracer's basis was
  // 23,173 spans over 35,068.9 mm holding 63,324 mm3, while the file holds 11,638 spans
  // over 30,457.5 mm and 41,955 mm3 -- the median strut diameter agrees to 4 %, the
  // length differs by 13 %, and the VOLUME by 34 %. The emitter is not a filter: the node
  // merge welds endpoints and the run collapse replaces each chain with fewer, straighter
  // spans carrying that run's LARGEST radius, so the shipped set has its own overlap
  // structure (51.5 % against the basis's 61.6 %). Scaling a radius derived from the
  // first network can only be a guess about the second.
  //
  // So the factor is solved against the emitter's own output. Each trial runs the FULL
  // emission -- clip to the part, node merge, support, prune, stranded drop, finish -- at
  // a trial radius and measures the union of what comes out. That also removes the reason
  // this could not simply be done afterwards: scaling radii on already-clipped spans
  // would fatten every strut through the part's surface, whereas re-emitting clips at the
  // radius it will ship with. Triangles are discarded during the trials, so a trial costs
  // the emission and not the mesh.
  OrganicLattice calibrated_lat;
  if (organic && organic_calibrate_on_shipped &&
      organic->report.bead_calibration_target_mm3 > 0.0 && !organic->curves.empty()) {
    struct DiscardSink : TriangleSink {
      void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {}
    };
    const double target = organic->report.bead_calibration_target_mm3;
    calibrated_lat = *organic;
    std::vector<double> base_r(calibrated_lat.curves.size());
    for (std::size_t q = 0; q < calibrated_lat.curves.size(); ++q)
      base_r[q] = calibrated_lat.curves[q].radius_mm;
    std::vector<double> base_c(calibrated_lat.connectors.size());
    for (std::size_t q = 0; q < calibrated_lat.connectors.size(); ++q)
      base_c[q] = calibrated_lat.connectors[q].radius_mm;
    auto set_k = [&](double k) {
      for (std::size_t q = 0; q < base_r.size(); ++q)
        calibrated_lat.curves[q].radius_mm = base_r[q] * k;
      for (std::size_t q = 0; q < base_c.size(); ++q)
        calibrated_lat.connectors[q].radius_mm = base_c[q] * k;
    };
    std::size_t trial_spans = 0;
    double trial_emitted_mm = 0.0, trial_merged_mm = 0.0, trial_written_mm = 0.0;
    auto shipped_union = [&](double k) {
      set_k(k);
      DiscardSink ds;
      std::vector<OrganicSpan> sp;
      const OrganicGenStats gs =
          generate_organic_lattice(calibrated_lat, ds, &boundary, 8, nullptr, &sp);
      trial_spans = sp.size();
      trial_emitted_mm = gs.census_len_mm[OrganicGenStats::CensusEmitted];
      trial_merged_mm = gs.census_len_mm[OrganicGenStats::CensusNodeMerge];
      trial_written_mm = gs.census_len_mm[OrganicGenStats::CensusWritten];
      return sp.empty()
                 ? 0.0
                 : lattice_union_volume(sp, kOrganicBeadCalibrationSamples).volume_mm3;
    };
    const double t0cal = wall_seconds();
    const double lt = std::log(target);
    // ★ EVERY TRIAL IS PRINTED, because the first version of this ran the factor to
    // 5.7e9 and emitted nothing, and the trial log is what showed why: the shipped union
    // barely responds to the bead. A secant on a flat function extrapolates to infinity,
    // so the search is BRACKETED and each step reported.
    double lk0 = 0.0, lv0 = std::log(std::max(shipped_union(1.0), 1e-12));
    const double v_at_one = std::exp(lv0);
    std::fprintf(stderr,
                 "[bead]   trial x1.0000 -> %.1f mm3 (%zu spans) | length emitted %.0f "
                 "-> node_merge %.0f -> written %.0f mm\n",
                 v_at_one, trial_spans, trial_emitted_mm, trial_merged_mm,
                 trial_written_mm);
    // The shipped union grows a little slower than the square of the radius, because a
    // fatter strut is also a more overlapped one; 2.0 is the opening guess and the secant
    // measures the real exponent from the next point.
    // The bracket is a hard limit on what a calibration may do to a part, not a numerical
    // convenience: a factor outside it is not a bead that needs adjusting, it is a
    // grading target the emitter cannot deliver, and the run must SAY so rather than
    // quietly shipping a part four times the intended thickness.
    const double lk_lo = std::log(kOrganicCalibrationFactorMin);
    const double lk_hi = std::log(kOrganicCalibrationFactorMax);
    double lk1 = lk0 + (lt - lv0) / 2.0;
    lk1 = std::min(std::max(lk1, lk_lo), lk_hi);
    int steps = 0;
    bool converged = false;
    double v_final = v_at_one;
    for (; steps < kOrganicCalibrationShippedSteps; ++steps) {
      v_final = shipped_union(std::exp(lk1));
      std::fprintf(stderr,
                   "[bead]   trial x%.4f -> %.1f mm3 (%zu spans) | length emitted %.0f "
                   "-> node_merge %.0f -> written %.0f mm\n",
                   std::exp(lk1), v_final, trial_spans, trial_emitted_mm,
                   trial_merged_mm, trial_written_mm);
      const double lv1 = std::log(std::max(v_final, 1e-12));
      if (std::fabs(lv1 - lt) < kOrganicBeadCalibrationTol) { converged = true; break; }
      double slope = (lk1 != lk0) ? (lv1 - lv0) / (lk1 - lk0) : 2.0;
      if (!std::isfinite(slope) || slope < 0.25) slope = 0.25;
      if (slope > 4.0) slope = 4.0;
      double lk2 = lk1 + (lt - lv1) / slope;
      lk2 = std::min(std::max(lk2, lk_lo), lk_hi);
      if (std::fabs(lk2 - lk1) < 1e-6) break;        // pinned at a bracket: no more to do
      lk0 = lk1; lv0 = lv1; lk1 = lk2;
      if (!std::isfinite(lk1)) { lk1 = lk0; break; }
    }
    double k = std::exp(lk1);
    if (!(k > 0.0) || !std::isfinite(k)) k = 1.0;
    const bool bracketed = k <= kOrganicCalibrationFactorMin * 1.001 ||
                           k >= kOrganicCalibrationFactorMax * 0.999;
    // Never below the machine: the printable floor is user input and outranks this, the
    // same rule the tracer's own calibration was held to.
    double kmin = 0.0;
    for (std::size_t q = 0; q < base_r.size(); ++q)
      if (base_r[q] > 0.0)
        kmin = std::max(kmin, 0.5 * organic->report.min_extrudable_width_mm / base_r[q]);
    const bool floored = k < kmin;
    if (floored) k = kmin;
    // ★★ AND IF THE TARGET IS OUT OF REACH, SHIP THE UNCALIBRATED PART, NOT A RUINED
    // ONE. Measured on the M2 stand, the emitter does not merely resist a thicker bead,
    // it DESTROYS the network under one: at x2.0 the node merge collapsed 25,515 mm of
    // emitted centreline to 493 mm, 27 spans survived of 13,128, and the run still
    // reported ACCEPTED. A calibration that cannot reach its target must hand back the
    // part it started with and say why -- never the one it wrecked reaching for it.
    if (!converged) {
      std::fprintf(stderr,
                   "[bead] TARGET OUT OF REACH: the grading law asks for %.1f mm3 and the "
                   "emitter delivers %.1f at x1. Thickening does not close it -- the node "
                   "merge welds a polyline finer than its own bead, so a fatter strut "
                   "COLLAPSES the curve it belongs to. Shipping the uncalibrated bead.\n",
                   target, v_at_one);
      k = 1.0;
    }
    set_k(k);
    std::fprintf(stderr,
                 "[bead] calibrated ON WHAT SHIPS: x%.4f in %d trial(s)%s%s | target "
                 "%.1f mm3, shipped union %.1f at x1 -> %.1f at the factor (%+.2f %%), "
                 "%zu span(s) | %.1f s\n",
                 k, steps + 1,
                 converged ? "" : (bracketed ? " (PINNED at the factor bracket -- the "
                                               "emitter cannot reach this target)"
                                             : " (NOT converged)"),
                 floored ? " (FLOORED at the extrudable width)" : "", target, v_at_one,
                 v_final, target > 0.0 ? 100.0 * (v_final - target) / target : 0.0,
                 trial_spans, wall_seconds() - t0cal);
    organic = &calibrated_lat;
  }

  // ★ THE TYPE THE JOB NAMED, and only that (lattice types round 1). The schema
  // admits a live type only, and lattice_gen_topology_from_id refuses anything core
  // cannot build -- never octet in its place.
  const LatticeGenTopology gen_topo = lattice_gen_topology_from_id(lat.topology);
  // ★ SHEETS (K2): the same region, boundary and grade, built as the TPMS wall by
  // generate_tpms instead of struts. The radius field carries HALF THE TRUE WALL (the sheet
  // reading of "strut diameter", lattice.hpp), which the type's wall law turns into the
  // field's parameter; the DC cell is a third of the thinnest wall this pass lays. No struts, so no landings and no Diagrid (refused at the parse); Rim is the rim
  // pass alone. Doubled and Stepped never reach here for a sheet (refused at the parse, R5).
  const bool sheet = lattice_gen_is_sheet(gen_topo);
  bool probe_live = solid_probe != nullptr;  // the first emission only
  auto sheet_pass = [&](TriangleSink& w) {
    const LatticeTopology ct = lattice_gen_certificate_topology(gen_topo);
    TpmsRegion TR;
    TR.anchor = R.origin;
    TR.nx = R.nx; TR.ny = R.ny; TR.nz = R.nz;
    TR.cell_mm = R.cell_mm;
    TR.latticed = R.latticed;
    TR.boundary = R.boundary;
    TpmsWallField W;
    W.field = [&radius, ct, &R](const Vec3& p) {
      return lattice_sheet_wall_param_mm(ct, 2.0 * radius.radius_at(p), R.cell_mm);
    };
    // The thinnest wall laid: the field at each latticed cell's corners, edge and face
    // midpoints and centre (it is graded per voxel), never below the band's own minimum.
    // Sizing the DC cell from the band's minimum instead costs (wall ratio)^2 triangles
    // for nothing: 4x on a 4 mm gyroid graded from 0.30 (sheet_triangle_cost.txt).
    const double band_min_wall = lattice_strut_diameter_mm(ct, lattice_rho_min(ct), R.cell_mm);
    double min_wall = std::numeric_limits<double>::infinity();
    for (int k = 0; k < R.nz; ++k)
      for (int j = 0; j < R.ny; ++j)
        for (int i = 0; i < R.nx; ++i) {
          if (R.latticed && !R.latticed(i, j, k)) continue;
          for (int c = 0; c < 27; ++c) {
            const Vec3 p{R.origin.x + (i + 0.5 * (c % 3)) * R.cell_mm,
                         R.origin.y + (j + 0.5 * (c / 3 % 3)) * R.cell_mm,
                         R.origin.z + (k + 0.5 * (c / 9)) * R.cell_mm};
            min_wall = std::min(min_wall, 2.0 * radius.radius_at(p));
          }
        }
    TpmsGenOptions o;
    o.min_wall_mm = std::isfinite(min_wall) ? std::max(min_wall, band_min_wall) : band_min_wall;
    // ★ Finding 8: simplified to within kSheetMaxDeviationMm of the true surface, no wall
    // cut below the bead.
    o.max_deviation_mm = kSheetMaxDeviationMm;
    o.bead_mm = sheet_bead_mm;
    o.true_wall_mm = [&radius](const Vec3& p) { return 2.0 * radius.radius_at(p); };
    // The wall is the owning voxel's (or its cell's mean): it steps at their faces.
    o.true_wall_steps = true;
    {
      const double wcell = R.cell_mm;
      o.wall_param_of = [ct, wcell](double wall_mm) {
        return lattice_sheet_wall_param_mm(ct, wall_mm, wcell);
      };
    }
    const TpmsKind tk =
        gen_topo == LatticeGenTopology::Gyroid ? TpmsKind::Gyroid : TpmsKind::SchwarzD;
    const TpmsGenStats ts = generate_tpms(tk, TR, W, w, o);
    if (solid_probe && probe_live) {
      // The probe outlives this pass, so it holds copies (the wall reads the caller's
      // radius field, which outlives the run's export and certification).
      // The wall the mesh was CONTOURED from (thickened near the bead), which the written
      // mesh follows to within the bound; the true wall would read it a few % light there.
      TpmsWallField PW;
      const double pcell = R.cell_mm, pbead = o.bead_mm, pdev = o.max_deviation_mm;
      PW.field = [&radius, ct, pcell, pbead, pdev](const Vec3& p) {
        return lattice_sheet_wall_param_mm(
            ct, tpms_contoured_wall_mm(2.0 * radius.radius_at(p), pbead, pdev), pcell);
      };
      const double ph = ts.dc_cell_mm;
      solid_probe->set_inside([tk, TR, PW, ph](const Vec3& p) {
        return tpms_clipped_field(tk, TR, PW, ph, p) < 0.0;
      });
    }
    LatticeGenStats st;
    if (R.boundary && skin.mode == LatticeSkinMode::Rim)
      st = generate_lattice_rims(R, radius, w, skin, nullptr);
    st.latticed_cells = ts.latticed_cells;
    st.triangles += ts.simplified ? ts.simplify.triangles_out : ts.dc.triangles;
    if (ts.simplified) {
      oc.sheet_simplified = true;
      oc.sheet_triangles_contoured = ts.simplify.triangles_in;
      oc.sheet_triangles = ts.simplify.triangles_out;
      oc.sheet_max_deviation_mm =
          std::max(ts.simplify.max_out_measured_mm, ts.simplify.max_in_measured_mm);
      oc.sheet_cut_max_deviation_mm =
          std::max(ts.simplify.cut_max_out_mm, ts.simplify.cut_max_in_mm);
      oc.sheet_samples_past_floor = ts.simplify.samples_past_max_in;
      oc.sheet_step_max_deviation_mm =
          std::max(ts.simplify.step_max_out_mm, ts.simplify.step_max_in_mm);
      oc.sheet_step_samples = ts.simplify.step_samples;
      oc.sheet_step_samples_outside_band = ts.simplify.step_samples_outside_band;
      oc.sheet_step_worst_outside_band_mm = ts.simplify.step_worst_outside_band_mm;
      oc.sheet_samples = ts.simplify.samples;
    }
    return st;
  };
  LatticeGenObserver weld_obs;
  auto feed_probe = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double r) {
    if (!solid_probe || !probe_live) return;
    const bool ball = (k == LatticeGenElement::Node || k == LatticeGenElement::AnchorNode);
    if (ball) solid_probe->add_ball(a, r);
    else if (k == LatticeGenElement::InteriorStrut) solid_probe->add_strut(a, b, r, radius.nseg);
    else solid_probe->add_prism(a, b, r, radius.nseg);  // a skin or rim edge: raw (b)
  };
  weld_obs.on_element = [&organic_spans, &lat, laid_tap, &feed_probe](
                            LatticeGenElement k, const Vec3& a, const Vec3& b, double r) {
    if (lat.emit_welded_stl) organic_spans.push_back({a, b, r});
    if (laid_tap && *laid_tap) (*laid_tap)(k, a, b, r);
    feed_probe(k, a, b, r);
  };
  // ★ K4: the tap arms the observer on its own, so a run that wants the ledger but not
  // the welded body still gets one. The welded push is now inside the callback and gated
  // on its own key, so the body cannot change because the ledger was asked for.
  const LatticeGenObserver* weld_tap =
      (lat.emit_welded_stl || (laid_tap && *laid_tap) || solid_probe) ? &weld_obs : nullptr;
  // ★ THE RIM ON A REAL PART (ruling 11-08 (A)): laid after the lattice, once per
  // emission, into the same sink. It is DRESSING: its elements reach the welded body and
  // the protrusion measurement, never the solid probe (the shipped-volume certificate, so
  // no strength credit) and never the plan's ledger.
  // ★ (A), the OPEN finish (no shell holds the cut ends): the cut strut ends within one
  // cell of a sharp edge are recorded as the lattice is laid, and the rim ties each to its
  // centre line after it. The cells within reach of an edge are marked first, so the
  // recorder asks the boundary only about ends that could need a tie.
  const bool rim_ties = mesh_rim != nullptr && !with_shell;
  std::vector<LatticeRimTieEnd> tie_ends;
  std::unordered_set<long long> near_edge_cells;
  const double tie_reach = R.cell_mm;
  auto cell_key = [tie_reach](const Vec3& p, int di, int dj, int dk) {
    const long long i = static_cast<long long>(std::floor(p.x / tie_reach)) + di + (1LL << 20);
    const long long j = static_cast<long long>(std::floor(p.y / tie_reach)) + dj + (1LL << 20);
    const long long k = static_cast<long long>(std::floor(p.z / tie_reach)) + dk + (1LL << 20);
    return (i << 42) | (j << 21) | k;
  };
  if (rim_ties)
    for (const LatticeMeshRimChain& c : mesh_rim->chains)
      for (std::size_t i = 0; i < c.points.size(); ++i) {
        const Vec3& a = c.points[i];
        const Vec3& b = c.points[(i + 1) % c.points.size()];
        const double l = std::sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) +
                                   (b.z - a.z) * (b.z - a.z));
        const int n = std::max(1, static_cast<int>(std::ceil(2.0 * l / tie_reach)));
        for (int t = 0; t <= n; ++t) {
          const double u = static_cast<double>(t) / n;
          const Vec3 q{a.x + u * (b.x - a.x), a.y + u * (b.y - a.y), a.z + u * (b.z - a.z)};
          for (int dk = -1; dk <= 1; ++dk)
            for (int dj = -1; dj <= 1; ++dj)
              for (int di = -1; di <= 1; ++di) near_edge_cells.insert(cell_key(q, di, dj, dk));
        }
      }
  auto record_tie_end = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double r) {
    if (!rim_ties || k != LatticeGenElement::InteriorStrut) return;
    for (const Vec3* p : {&a, &b}) {
      if (!near_edge_cells.count(cell_key(*p, 0, 0, 0))) continue;
      // a CUT end lies on the clip's offset surface, sd = r (to its tolerance)
      if (boundary.signed_distance(*p) > r + 0.05) continue;
      tie_ends.push_back({*p, r});
    }
  };
  auto lay_mesh_rim = [&](TriangleSink& w, const LatticeGenObserver* o, LatticeGenStats& st) {
    if (mesh_rim == nullptr) return;
    oc.mesh_rim_ran = true;
    const LatticeGenStats rs = generate_mesh_rims(R, radius, w, skin, *mesh_rim, &oc.rim, o,
                                                  rim_ties ? &tie_ends : nullptr);
    tie_ends.clear();
    st.rim_elements += rs.rim_elements;
    st.rim_triangles += rs.rim_triangles;
    st.triangles += rs.triangles;
    st.rim_volume_mm3 += rs.rim_volume_mm3;
    st.uncertified_spans_dropped += rs.uncertified_spans_dropped;
    if (rs.max_strut_diameter_mm > 0.0) {
      st.min_strut_diameter_mm = st.max_strut_diameter_mm > 0.0
                                     ? std::min(st.min_strut_diameter_mm, rs.min_strut_diameter_mm)
                                     : rs.min_strut_diameter_mm;
      st.max_strut_diameter_mm = std::max(st.max_strut_diameter_mm, rs.max_strut_diameter_mm);
    }
  };
  LatticeGenObserver rim_obs_plain;
  rim_obs_plain.on_element = [&organic_spans, &lat](LatticeGenElement, const Vec3& a,
                                                    const Vec3& b, double r) {
    if (lat.emit_welded_stl) organic_spans.push_back({a, b, r});
  };
  LatticeGenObserver tie_obs;   // the recorder in front of whatever tap the run uses
  tie_obs.on_element = [&weld_tap, &record_tie_end](LatticeGenElement k, const Vec3& a,
                                                    const Vec3& b, double r) {
    record_tie_end(k, a, b, r);
    if (weld_tap && weld_tap->on_element) weld_tap->on_element(k, a, b, r);
  };
  const LatticeGenObserver* lattice_tap = rim_ties ? &tie_obs : weld_tap;
  LatticeGenObserver tie_only_obs;   // organic keeps its own span ledger: the recorder alone
  tie_only_obs.on_element = [&record_tie_end](LatticeGenElement k, const Vec3& a,
                                              const Vec3& b, double r) {
    record_tie_end(k, a, b, r);
  };
  auto emit_lattice = [&](TriangleSink& w) {
    if (!measure_protrusion) {
      LatticeGenStats st;
      if (sheet)
        st = sheet_pass(w);
      else if (organic)
        st = organic_stats(generate_organic_lattice(*organic, w, &boundary, 8,
                                                    rim_ties ? &tie_only_obs : nullptr,
                                                    &organic_spans));
      else if (stepped)
        st = generate_lattice_stepped(gen_topo, *stepped, w, skin, lattice_tap);
      else
        st = swept ? generate_lattice_multilevel(gen_topo, Rbase, *levels, w, skin, lattice_tap)
                   : generate_lattice(gen_topo, R, radius, w, skin, lattice_tap);
      lay_mesh_rim(w, &rim_obs_plain, st);
      return st;
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
    // ★ NAME THE ELEMENT THAT ESCAPED, not just the pass. on_element fires straight
    // after its own triangles, so a rise in n_out across one element attributes the
    // escape to THAT strut -- endpoints and radius -- which is what a clip fix needs.
    long long prev_n_out = 0;
    LatticeGenObserver obs;
    obs.on_element = [&m, &pass_marks, &organic_spans, &lat, &prev_n_out, laid_tap,
                      &feed_probe, &record_tie_end](LatticeGenElement k, const Vec3& ea,
                                                    const Vec3& eb, double er) {
      feed_probe(k, ea, eb, er);
      record_tie_end(k, ea, eb, er);   // ★ (A) the open finish's cut ends near an edge
      if (m.this_element_out) { ++m.elements_out; m.this_element_out = false; }
      if (m.n_out > prev_n_out && std::getenv("TOPOPT_PROTRUSION_TRACE")) {
        std::fprintf(stderr,
                     "[protrusion] ^ emitted by element kind=%d  a=(%.9g, %.9g, %.9g)"
                     "  b=(%.9g, %.9g, %.9g)  r=%.9g  len=%.9g\n",
                     static_cast<int>(k), ea.x, ea.y, ea.z, eb.x, eb.y, eb.z, er,
                     std::sqrt((eb.x-ea.x)*(eb.x-ea.x) + (eb.y-ea.y)*(eb.y-ea.y) +
                               (eb.z-ea.z)*(eb.z-ea.z)));
        prev_n_out = m.n_out;
      }
      // Same ledger as the non-measuring path above, so the welded body does not
      // depend on whether the protrusion measurement happened to be armed.
      if (lat.emit_welded_stl) organic_spans.push_back({ea, eb, er});
      if (laid_tap && *laid_tap) (*laid_tap)(k, ea, eb, er);   // ★ K4
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
    LatticeGenStats st =
        organic
            // ★ THE GUARD'S OWN MeshDistance GOES TO THE CLIP. `shell` is
            // `variant.v3.mesh` by const reference and nothing mutates it between
            // shell_dist's construction and export, so this IS the shell as written.
            // Passing it makes the generator and the export guard measure ONE
            // surface; before, the clip eroded the analytic boundary and the guard
            // measured the meshed shell, and a 1.75 um disagreement between them
            // refused the file over a single strut cap.
            ? organic_stats(generate_organic_lattice(
                  *organic, m, &boundary, 8, &obs, &organic_spans,
                  measure_protrusion ? &shell_dist : nullptr))
            : sheet ? sheet_pass(m)
            : (stepped ? generate_lattice_stepped(gen_topo, *stepped, m, skin, &obs)
                       : (swept ? generate_lattice_multilevel(gen_topo, Rbase,
                                                              *levels, m, skin, &obs)
                                : generate_lattice(gen_topo, R, radius, m, skin,
                                                   &obs)));
    {
      // ★ the rim, measured and attributed like every other pass
      LatticeGenObserver rim_obs;
      rim_obs.on_element = [&m, &pass_marks, &organic_spans, &lat](
                               LatticeGenElement, const Vec3& ea, const Vec3& eb, double er) {
        if (m.this_element_out) { ++m.elements_out; m.this_element_out = false; }
        if (lat.emit_welded_stl) organic_spans.push_back({ea, eb, er});
        pass_marks.emplace_back(m.n_seen, "rim along a sharp edge");
      };
      lay_mesh_rim(m, &rim_obs, st);
    }
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
    oc.protruding_unique_vertices =
        std::max(oc.protruding_unique_vertices,
                 static_cast<long long>(m.unique_out.size()));
    oc.protruding_elements = std::max(oc.protruding_elements, m.elements_out);
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
    probe_live = false;                    // a second writer emits the same stream
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

  // ── ★ THE WELDED, SINGLE-BODY FILE (organic only for now) ──────────────────
  // Built from the spans that were ACTUALLY WRITTEN, so it describes the file and not
  // the intent. See organic_lattice.hpp for why this is not cosmetic: the soup is
  // thousands of separate closed shells and a mesh-analysing slicer calls every one
  // that misses the plate a FLOATING BODY.
  //
  // ★ NOT ROTATED BY THE BAKE. `write_with` applies the build-frame rotation to the
  // streamed soup; this body is marched from the UNROTATED spans, so it is rotated
  // here by the same rigid motion, or the two files would describe different
  // placements of the same object.
  // ── ★★ THE EMITTED SPANS, AS A FILE ────────────────────────────────────────
  // These are the spans AFTER every pass — clip, node merge, support, prune,
  // stranded drop, the finish, and the endpoint-clearance fit — i.e. exactly the
  // geometry written into the STL. Two things need them and neither can get them
  // today:
  //
  //   * comparing core's tracer against the gc2 coupon, which is the only way to
  //     know whether the contiguity numbers measured on gc2 describe core at all;
  //   * certifying organic structurally, which reads a welded beam network and
  //     already speaks this format.
  //
  // gc2's own writer is NOT a substitute: it writes at its line 1924, BEFORE the
  // region-net drop and the prune rounds, so it describes the traced network and not
  // the shipped part. This writes what ships.
  //
  // Format is the one the beam-network solver already reads: GRID, then the skin's
  // designed thickness, then one SEG per span.
  if (lat.emit_organic_spans && !organic_spans.empty()) {
    const std::string spath = base + "_SPANS.txt";
    std::ofstream sf(spath);
    if (sf) {
      sf.setf(std::ios::fmtflags(0), std::ios::floatfield);
      sf.precision(10);
      sf << "GRID " << sg.origin.x << ' ' << sg.origin.y << ' ' << sg.origin.z << ' '
         << sg.spacing << ' ' << sg.nx << ' ' << sg.ny << ' ' << sg.nz << '\n';
      // No SKIN line: this job carries no declared rim thickness on `lat`, and a
      // number invented here would be read downstream as a design value. The
      // consumer falls back to its own rim argument when the line is absent.
      for (const OrganicSpan& sp : organic_spans)
        sf << "SEG " << sp.a.x << ' ' << sp.a.y << ' ' << sp.a.z << ' '
           << sp.b.x << ' ' << sp.b.y << ' ' << sp.b.z << ' ' << sp.r << '\n';
      std::printf("organic spans: %zu written to %s\n", organic_spans.size(),
                  spath.c_str());
    }
  }
  if (lat.emit_welded_stl && !organic_spans.empty()) {
    OrganicWeldStats ws;
    // 40 million voxels is ~320 MB of field — the cap exists so a fine lattice in a
    // big part coarsens the pitch instead of allocating without bound, and the pitch
    // actually used is reported rather than assumed.
    // ★ THE BASE PLANE IS CUT HERE, ON THE SOLID. The span-level trim removes the
    // scatter below the base, but each clipped capsule still carries a hemispherical
    // cap a radius under the plane — 0.5 mm of it on the cube — and those caps ARE
    // the dots. Only the marched field can be cut flat.
    // ★ THE PART, HANDED TO THE WELD so it can drive free ends into the solid and then
    // cut back everything that leaves. The density field is the same one the solid's own
    // surface is built from, which is why the trim lands on that surface rather than a
    // voxel boundary; see OrganicWeldPart.
    OrganicWeldPart wpart;
    wpart.origin = sg.origin; wpart.h = sg.spacing;
    wpart.nx = sg.nx; wpart.ny = sg.ny; wpart.nz = sg.nz;
    wpart.density = &dens; wpart.iso = printed_iso;
    wpart.embed_mm = organic_strut_embed_mm;
    TriangleMesh welded =
        organic_weld(organic_spans, lat.welded_pitch_mm, 40000000LL, ws,
                     organic_base_trim_z > 0.0 ? organic_base_trim_z : -1e30, wpart);
    if (std::getenv("TOPOPT_ORGANIC_TRACE"))
      std::fprintf(stderr,
                   "[weld] embed %.2f mm: %lld free ends driven into the solid; "
                   "part clip %s, %lld raster voxels removed for leaving the part\n",
                   ws.embed_mm, ws.ends_embedded, ws.part_clip_ran ? "RAN" : "did not run",
                   ws.trimmed_voxels);
    // The SAME rigid motion the streamed soup is rotated by, from the same helper —
    // vertex order and winding preserved (det +1), so the two files describe one
    // placement of one object.
    if (bake && !welded.vertices.empty()) welded = rotate_mesh(welded, *bake);
    const std::string path = base + "_WELDED.stl";
    write_stl_file(path, welded);
    oc.paths.push_back(path);
    oc.weld = ws;
    oc.welded = true;
    // ★ THE SOLID COMPANION, BESIDE THE WELDED LATTICE (maintainer, 2026-09-08).
    // The welded file is the lattice ALONE and the interpenetrating soup is the solid
    // and the lattice fused into one unusable-for-inspection body, so neither file on
    // its own shows a strut meeting material. This writes the SAME companion body the
    // soup already contains, unmodified and separately, so the two can be opened
    // together and the junction judged without anyone reconstructing anything. It is
    // the same `comp_mesh` and the same rigid motion, so the pair is one placement of
    // one object.
    if (!comp_mesh.vertices.empty()) {
      TriangleMesh solid_out = bake ? rotate_mesh(comp_mesh, *bake) : comp_mesh;
      const std::string spath = base + "_SOLID.stl";
      write_stl_file(spath, solid_out);
      oc.paths.push_back(spath);
    }
  }

  // ── ★ THE LATTICE, DUAL CONTOURED FROM ITS OWN SDF ─────────────────────────
  // Additive and off unless asked for: the welded pair above is untouched. The weld
  // marches a sampled field and its enclosed volume came out 67 % under the true union;
  // this contours the exact capsule union instead, and reproduces that volume to within
  // 1 % while staying watertight. It costs minutes rather than seconds, which is why it
  // is a key and not the default. See topopt/lattice_dc.hpp.
  if (organic_dual_contour && !organic_spans.empty()) {
    LatticeDcOptions dopt;
    dopt.cell_mm = organic_dc_cell_mm;
    dopt.simplify_tolerance_mm = organic_dc_tolerance_mm;
    // The SAME base plane the weld cuts on, so the two files describe one object rather
    // than differing by a hemispherical cap under the plate on every clipped strut.
    if (organic_base_trim_z > 0.0) dopt.clip_below_z = organic_base_trim_z;
    // ── ★★ THE WETTED JOIN, ON, because this file exists to be the preview's ────
    // The carver is the only mesher that can express it (organic_wet_join.hpp), and the
    // whole reason a job asks for this file is that it should look like the picture. The
    // scale is hard-coded at the maintainer's instruction (2026-09-18), so there is no
    // number here for the two codebases to drift on.
    //
    // The part field is built ONCE for the whole grid: an exact Euclidean transform is
    // three linear sweeps, which is nothing beside the contouring it feeds.
    std::vector<char> part_solid(sg.voxel_count(), 0);
    for (std::size_t e = 0; e < sg.voxel_count(); ++e)
      part_solid[e] = dens[e] >= printed_iso ? 1 : 0;
    const std::vector<double> part_sdf = voxel_signed_distance_mm(sg, part_solid);
    // ★ AND THE LATTICED SET, which is where the joints are. The certified mask is the
    // lattice; everything else inside the part is the solid the struts weld into.
    const std::vector<double> lat_sdf = voxel_signed_distance_mm(sg, cert_mask);
    dopt.wet.grid = &sg;
    dopt.wet.part_sdf_mm = &part_sdf;
    dopt.wet.lattice_sdf_mm = &lat_sdf;
    dopt.wet.scale = kOrganicWetScale;
    LatticeDcStats dst;
    TriangleMesh dc = lattice_dual_contour(organic_spans, dopt, dst);
    std::printf(
        "[dc] cell %.4f mm (asked %.4f) tol %.4f | leaves %zu (%zu merged, %zu split) | "
        "%zu tris | boundary %zu nonmanifold %zu dropped %zu | %s | volume %.1f mm3 | "
        "%.1f s\n",
        dst.cell_mm, dst.cell_mm_requested, dst.simplify_tolerance_mm, dst.cells_active,
        dst.cells_merged, dst.cells_split, dst.triangles, dst.boundary_edges,
        dst.nonmanifold_edges, dst.quads_dropped,
        dst.manifold ? "MANIFOLD" : (dst.watertight ? "closed" : "OPEN"),
        dst.volume_mm3, dst.seconds);
    if (bake && !dc.vertices.empty()) dc = rotate_mesh(dc, *bake);
    const std::string dpath = base + "_DC.stl";
    write_stl_file(dpath, dc);
    oc.paths.push_back(dpath);
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
LatticePosture build_lattice_posture(LatticeTopology topo, const VoxelGrid& sg,
                                     double cell_mm, const std::vector<char>& mask,
                                     double rho, const std::vector<double>* graded_rho) {
  LatticePosture post;
  post.topology = topo;  // the JOB's type: the tensor certifies what was built
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

// ★ E3: one include region's latticed voxels and the density range the grading law
// gave them (LatticeVariantOutcome::region_graded).
struct LatticeRegionGraded {
  long long voxels = 0;
  double rho_lo = 0.0, rho_hi = 0.0;
  double cell_lo = 0.0, cell_hi = 0.0;  // ★ E3: the cells it got (swept; 0 otherwise)
  // ★ E3 "off" with no density: the lightest one density that certified (the search).
  bool searched = false;
  bool search_certified = false;
  double search_rho = 0.0, search_floor = 0.0, search_peak = 0.0, search_margin = 0.0;
  int search_trials = 0;
  double search_law_rho = 0.0;    // the law search's answer (before the shipped one)
  int search_shipped_trials = 0;  // whole passes the shipped search ran (0: none needed)
};

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
  // ★ E2.1: per scenario the lattice uses (empty without scenarios), in the run's
  // order: the LATTICED margin and verdict, and the solid re-certification's margin.
  // `lattice` above is the governing one of these.
  std::vector<ScenarioReport> scenarios;
  std::vector<char> scenario_accepted;
  std::vector<ScenarioReport> solid_scenarios;
  // ★ E2.4: the OPEN finish (outer_finish "none"). `lattice` above was certified with
  // the latticed voxels in cells the part's free surface cuts given NO credit.
  bool open_finish = false;
  long long open_cut_voxels = 0;        // latticed voxels given no credit
  long long open_latticed_voxels = 0;   // all latticed voxels in the posture
  bool open_load_path_ok = true;        // the load path through what keeps credit
  std::string open_refusal;             // plain words, by region label; "" if certified
  // ★ E2.4 per region: each open region beside covered ones, and the wall closing it
  std::vector<std::string> open_region_notes;
  double region_wall_mm = 0.0;
  long long region_wall_voxels = 0;
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
  // ★ E2.1: THE SCENARIOS THIS LATTICE IS CERTIFIED UNDER, each with its own
  // supports and loads on the solved grid. Empty on a job without scenarios: then
  // `loads` with the caller's bcs is the one load case, exactly as before. Sized on
  // the run's WHOLE list and only then filtered to lattice.scenarios, because
  // sized_scenarios scales each scenario's weak springs by the heaviest load in the
  // list it is given: sizing a subset would certify different springs than the run.
  std::vector<SimpScenario> scenarios;
  // Install 3 (the new engine's strength check, its strength_settings): which neighbours the load-path walk joins,
  // the share over which a scenario is unheld, and the analysis knobs. The defaults are every other caller's.
  int connectivity = 26;
  double unheld_share = kScenarioUnheldShare;
  const AnalysisKnobs* knobs = nullptr;
};

// ── ★ E2.1: WHICH OF THE RUN'S SCENARIOS THE LATTICE USES ─────────────────────
// One flag per entry of `scenarios` (the run's own list, in its order): 1 when the
// lattice is graded and certified on it. lattice.scenarios not stated = all of them.
// Matched by name, which parse_job has already checked against loads.scenarios.
std::vector<char> lattice_scenario_flags(const JobDescription& job,
                                         const std::vector<SimpScenario>& scenarios) {
  std::vector<char> on(scenarios.size(), job.lattice.scenarios_stated ? 0 : 1);
  if (job.lattice.scenarios_stated)
    for (std::size_t s = 0; s < scenarios.size(); ++s)
      for (const std::string& name : job.lattice.scenarios)
        if (scenarios[s].name == name) on[s] = 1;
  return on;
}

// ── ★ E2.1: THE FIELD THE LATTICE IS GRADED FROM ──────────────────────────────
// Per voxel, the WORST von Mises over the scenarios the lattice uses (raw MPa: a
// light scenario never drives the grade). The governing scenario's field is the
// variant's own double field, the one the grade always read; the others come from
// `scenario_fields`, the float32 copies the views carry. So a lattice on the
// governing scenario alone grades from exactly the field it always did, and a job
// without scenarios gets `v.von_mises_field` itself, by reference.
//
// `source`, when given, receives per voxel the index (in the run's scenario order)
// of the scenario whose stress the grade read there: -1 without scenarios.
const std::vector<double>& lattice_grading_stress(
    const std::vector<double>& governing_field, const std::vector<ScenarioReport>& reps,
    const std::vector<ScenarioFields>& fields, const std::vector<char>& on,
    std::vector<double>& storage, std::vector<int>* source) {
  if (source) source->assign(governing_field.size(), -1);
  if (reps.empty()) return governing_field;
  if (on.size() != reps.size() || fields.size() != reps.size())
    throw JobError(
        "internal: the analysis carries " + std::to_string(reps.size()) +
        " scenario reports and " + std::to_string(fields.size()) +
        " scenario fields, and the lattice was given " + std::to_string(on.size()) +
        " scenario flags. They are one list in one order; grading from a mismatched "
        "pair would follow the wrong scenario's stress.");
  std::size_t gov = reps.size();
  for (std::size_t s = 0; s < reps.size(); ++s)
    if (reps[s].governs) gov = s;
  const std::size_t n = governing_field.size();
  bool others = false;
  for (std::size_t s = 0; s < reps.size(); ++s)
    if (on[s] && s != gov) others = true;
  if (!others && gov < reps.size() && on[gov]) {
    if (source) source->assign(n, static_cast<int>(gov));
    return governing_field;
  }
  if (gov < reps.size() && on[gov]) {
    storage = governing_field;
    if (source) source->assign(n, static_cast<int>(gov));
  } else {
    storage.assign(n, -1.0);
  }
  for (std::size_t s = 0; s < reps.size(); ++s) {
    if (!on[s] || s == gov) continue;
    const std::vector<float>& f = fields[s].von_mises;
    if (f.size() != n)
      throw JobError("internal: scenario \"" + reps[s].name + "\" carries a stress field "
                     "of " + std::to_string(f.size()) + " voxels on a grid of " +
                     std::to_string(n) + ".");
    for (std::size_t e = 0; e < n; ++e)
      if (static_cast<double>(f[e]) > storage[e]) {
        storage[e] = static_cast<double>(f[e]);
        if (source) (*source)[e] = static_cast<int>(s);
      }
  }
  return storage;
}

const std::vector<double>& lattice_grading_stress(const MinimizePlasticVariant& v,
                                                  const std::vector<char>& on,
                                                  std::vector<double>& storage,
                                                  std::vector<int>* source) {
  return lattice_grading_stress(v.von_mises_field, v.report.scenarios, v.scenario_fields, on,
                                storage, source);
}

// `domain` is THE domain the run solved on (resolve_design_domain, pipeline.hpp):
// under a design box its grid is the EXPANDED grid and its BCs/loads are already
// remapped onto it. `part_grid` is the ORIGINAL imported part's grid — the
// denominator minimize_plastic's ladder normalises to, which under expansion is
// NOT the solved grid's solid count.
LatticeCertContext lattice_cert_context(const MinimizePlasticVariant& variant,
                                        const VoxelGrid& part_grid,
                                        const SolvedDesignDomain& domain,
                                        const MinimizePlasticOptions& options,
                                        const Material& material,
                                        const JobDescription& job) {
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
  // ★ E2.1: the scenarios, the way minimize_plastic certified them (sized on the
  // whole list, on the solved grid), then only those the lattice uses.
  if (!domain.scenarios.empty()) {
    const std::vector<SimpScenario> sized =
        sized_scenarios(domain.scenarios, material.youngs_modulus_mpa, sg.spacing);
    const std::vector<char> on = lattice_scenario_flags(job, sized);
    for (std::size_t s = 0; s < sized.size(); ++s)
      if (on[s]) cx.scenarios.push_back(sized[s]);
  }
  assert((!options.draft_quality || cx.cert_tol < options.draft_loose_tol) &&
         "E4: latticed certification must run at the tight cert tolerance, never the "
         "draft loose tolerance");
  return cx;
}

FixedDesignAnalysis analyze_variant_with_posture(
    const MinimizePlasticVariant& variant, const VoxelGrid& sg,
    const MinimizePlasticOptions& options, const Material& material,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads,
    const LatticeCertContext& cx, const LatticePosture* post) {
  return analyze_fixed_design(sg, cx.params,
                              variant.optimization.physical_density, bcs,
                              loads, material, cx.build_dir, cx.cert_tol,
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
                              cx.printed_iso, /*gate_on_strut_strength=*/false, cx.knobs);
}

// The one load case of a job without scenarios: the caller's bcs with cx.loads.
FixedDesignAnalysis analyze_variant_with_posture(
    const MinimizePlasticVariant& variant, const VoxelGrid& sg,
    const MinimizePlasticOptions& options, const Material& material,
    const std::vector<DirichletBC>& bcs, const LatticeCertContext& cx,
    const LatticePosture* post) {
  return analyze_variant_with_posture(variant, sg, options, material, bcs, cx.loads, cx,
                                      post);
}

// ── ★ E2.1: ONE POSTURE CERTIFIED UNDER EVERY SCENARIO THE LATTICE USES ───────
// Without scenarios: the one load case (`bcs` with cx.loads), exactly as before.
// With them: each scenario's own supports and loads (cx.scenarios), the WORST
// governs by certify_scenarios' own rule (a non-convergent solve first, then the
// lowest effective margin), and the verdict is ACCEPTED only if every scenario's own
// analysis is accepted and none is unheld. Before E2.1 a scenario job's lattice was
// certified under scenario 1 alone, whichever governed.
struct PostureCertification {
  FixedDesignAnalysis governing;
  std::vector<ScenarioReport> reports;  // empty without scenarios
  std::vector<char> accepted;           // per scenario, in `reports` order
};
PostureCertification certify_posture(const MinimizePlasticVariant& variant,
                                     const VoxelGrid& sg,
                                     const MinimizePlasticOptions& options,
                                     const Material& material,
                                     const std::vector<DirichletBC>& bcs,
                                     const LatticeCertContext& cx,
                                     const LatticePosture* post,
                                     // Install 3: each scenario's own fields, when given (none without
                                     // scenarios). Null, every caller before it: nothing kept, as before.
                                     std::vector<ScenarioFields>* fields_out = nullptr) {
  PostureCertification pc;
  if (cx.scenarios.empty()) {
    pc.governing = analyze_variant_with_posture(variant, sg, options, material, bcs, cx, post);
    return pc;
  }
  // ★ Ruling 11-06 2(a): a scenario whose lattice is NOT CERTIFIED reads an unbounded
  // margin, so it never governs by the worse rule; its words go on the governing one.
  std::string not_certified;
  ScenarioCertification sc = certify_scenarios(
      sg, cx.scenarios,
      [&](const std::vector<DirichletBC>& b, const std::vector<NodalLoad>& l) {
        FixedDesignAnalysis a =
            analyze_variant_with_posture(variant, sg, options, material, b, l, cx, post);
        pc.accepted.push_back(a.accepted ? 1 : 0);
        if (a.lattice_not_certified && not_certified.empty())
          not_certified = "Under \"" + cx.scenarios[pc.accepted.size() - 1].name + "\": " +
                          a.lattice_not_certified_reason;
        return a;
      },
      /*keep_fields=*/fields_out != nullptr, cx.unheld_share);
  if (fields_out) *fields_out = std::move(sc.fields);
  pc.governing = std::move(sc.governing);
  pc.reports = std::move(sc.reports);
  for (const char a : pc.accepted)
    if (!a) pc.governing.accepted = false;
  if (!not_certified.empty()) {
    pc.governing.lattice_not_certified = true;
    pc.governing.lattice_not_certified_reason = not_certified;
  }
  return pc;
}

// ★ E2.1: the organic certificates' load cases: one per scenario the lattice uses,
// each with its own supports, or the job's one load case when it has none.
std::vector<OrganicLoadCase> organic_load_cases(const LatticeCertContext& cx,
                                                const std::vector<DirichletBC>& bcs) {
  std::vector<OrganicLoadCase> ocs;
  if (cx.scenarios.empty()) {
    ocs.push_back({"job", bcs, cx.loads});
    return ocs;
  }
  for (const SimpScenario& sc : cx.scenarios) ocs.push_back({sc.name, sc.bcs, sc.loads});
  return ocs;
}

// ── ★ E2.4: THE OPEN LATTICE'S SURFACE CELLS (outer_finish "none", ruling 11-06 (1)) ─
// Under a solid shell, a cell the part's surface cuts lands its struts on the shell. Open,
// it does not: Onck, Andrews & Gibson 2001 ("Size effects in ductile cellular solids",
// Int. J. Mech. Sci. 43(3), Part I modelling doi:10.1016/S0020-7403(00)00042-4, Part II
// experiments doi:10.1016/S0020-7403(00)00043-6) show the cells cut by a free surface form
// a weaker boundary layer, and stiffness and strength fall when the part is only a few
// cells thick. The posture's periodic tensor overstates that layer. So it gets NO credit,
// the safe floor: no measured knockdown for the layer exists in core, and a reduced credit
// without one would be a guess.
//
// A cell is AT THE FREE SURFACE when any voxel whose centre lies in its box, or one voxel
// beyond any face of it (the lattice's cell grid: origin at the grid's, the voxel's own
// cell size on a swept posture), is FREE: outside the grid, outside the part, or not
// printed (a hole, a keep-clear, a void the optimizer left). That is a cell the surface
// cuts AND a cell flush against it: neither has the neighbour cell the periodic tensor
// assumes on that side (measured: on a bar whose 4 mm cells meet its faces flush, a
// cut-only test found none). A cell touching only solid or latticed material is not:
// its struts land on material. Returns, per voxel, latticed AND in such a cell.
std::vector<char> open_finish_cut_cells(const VoxelGrid& g, const std::vector<double>& dens,
                                        double iso, const LatticePosture& post) {
  const std::size_t n = g.voxel_count();
  std::vector<char> cut(n, 0);
  const double h = g.spacing;
  const bool per_voxel = post.cell_size_field.size() == n;
  std::map<std::array<long long, 4>, char> cell_cut;  // (cell um, ix, iy, iz) -> cut
  auto free_at = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) return true;
    return !g.solid(i, j, k) || !(dens[g.index(i, j, k)] > iso);
  };
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (e >= post.mask.size() || !post.mask[e]) continue;
        const double c = per_voxel ? post.cell_size_field[e] : post.cell_size_mm;
        if (!(c > 0.0)) continue;
        // The cell holding this voxel's centre, in voxel-index units along each axis.
        const long long ix = static_cast<long long>(std::floor((i + 0.5) * h / c));
        const long long iy = static_cast<long long>(std::floor((j + 0.5) * h / c));
        const long long iz = static_cast<long long>(std::floor((k + 0.5) * h / c));
        const std::array<long long, 4> key{std::llround(c * 1e6), ix, iy, iz};
        auto it = cell_cut.find(key);
        if (it == cell_cut.end()) {
          // Voxels whose centre (v + 0.5) h lies in [ix c, (ix + 1) c), and one beyond.
          auto lo = [&](long long q) { return static_cast<int>(std::ceil(q * c / h - 0.5)); };
          bool any = false;
          for (int kk = lo(iz) - 1; kk <= lo(iz + 1) && !any; ++kk)
            for (int jj = lo(iy) - 1; jj <= lo(iy + 1) && !any; ++jj)
              for (int ii = lo(ix) - 1; ii <= lo(ix + 1) && !any; ++ii)
                if (free_at(ii, jj, kk)) any = true;
          it = cell_cut.emplace(key, any ? 1 : 0).first;
        }
        cut[e] = it->second;
      }
  return cut;
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
                                            double rho_uniform,
                                            const std::vector<char>* open_cut = nullptr,
                                            // Install 3: the latticed solve's per-scenario fields, when
                                            // given (scenario_fields.bin). Null: none kept, as before.
                                            std::vector<ScenarioFields>* lattice_fields = nullptr) {
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
  //
  // ★ E2.1: with scenarios, each one the lattice uses is re-certified, and each must
  // reproduce the margin the run recorded for THAT scenario (its effective margin,
  // the number ScenarioReport carries). The governing one's worst case is the
  // reported reproduction.
  const PostureCertification solid =
      certify_posture(variant, sg, options, material, bcs, cx, /*post=*/nullptr);
  const FixedDesignAnalysis& solid_recert = solid.governing;
  oc.solid_margin_reproduced = solid_recert.margin.worst_case;
  oc.solid_scenarios = solid.reports;
  if (solid.reports.empty() || variant.report.scenarios.empty()) {
    oc.solid_reproduced =
        (solid_recert.margin.worst_case == variant.report.margin.worst_case);
    oc.solid_reproduction_relative_delta = margin_reproduction_relative_delta(
        variant.report.margin.worst_case, solid_recert.margin.worst_case);
    oc.solid_reproduces_within_band = margin_reproduces(
        variant.report.margin.worst_case, solid_recert.margin.worst_case,
        cx.cert_tol);
  } else {
    oc.solid_reproduced = true;
    oc.solid_reproduces_within_band = true;
    for (const ScenarioReport& got : solid.reports) {
      const ScenarioReport* rec = nullptr;
      for (const ScenarioReport& r : variant.report.scenarios)
        if (r.name == got.name) rec = &r;
      if (rec == nullptr) {
        oc.solid_reproduced = oc.solid_reproduces_within_band = false;
        continue;
      }
      if (got.margin != rec->margin) oc.solid_reproduced = false;
      oc.solid_reproduction_relative_delta =
          std::max(oc.solid_reproduction_relative_delta,
                   margin_reproduction_relative_delta(rec->margin, got.margin));
      if (!margin_reproduces(rec->margin, got.margin, cx.cert_tol))
        oc.solid_reproduces_within_band = false;
    }
  }

  // (2) Latticed cert — the octet tensor on the shared occupancy. THIS margin
  // describes the exported file. The certifiable BAND is enforced INSIDE
  // analyze_fixed_design PER VOXEL (bars E5 / H4b): any masked voxel whose rho
  // sits outside [rho_min, rho_max] throws LatticeDensityOutOfBand rather than
  // certify against a clamped tensor.
  //
  // ★ E2.4: an OPEN finish certifies with its cut cells given no credit: void in the
  // design this solve reads and out of the posture, and the load path re-walked on what
  // is left (a load on cut cells alone has no path). The solid re-cert above read the
  // design as the run certified it.
  const MinimizePlasticVariant* lat_variant = &variant;
  const LatticePosture* lat_post = &post;
  const LatticeCertContext* lat_cx = &cx;
  MinimizePlasticVariant floored;
  LatticePosture floored_post;
  LatticeCertContext floored_cx;
  if (open_cut) {
    oc.open_finish = true;
    for (std::size_t e = 0; e < post.mask.size(); ++e)
      if (post.mask[e]) {
        ++oc.open_latticed_voxels;
        if (e < open_cut->size() && (*open_cut)[e]) ++oc.open_cut_voxels;
      }
    if (oc.open_cut_voxels > 0) {
      floored = variant;
      floored_post = post;
      for (std::size_t e = 0; e < open_cut->size(); ++e)
        if ((*open_cut)[e]) {
          floored.optimization.physical_density[e] = 0.0;
          floored_post.mask[e] = 0;
        }
      floored_cx = cx;
      floored_cx.load_path_ok =
          load_path_connected(sg, floored.optimization.physical_density, cx.printed_iso, cx.connectivity);
      oc.open_load_path_ok = floored_cx.load_path_ok;
      lat_variant = &floored;
      lat_post = &floored_post;
      lat_cx = &floored_cx;
    }
  }
  PostureCertification lat =
      certify_posture(*lat_variant, sg, options, material, bcs, *lat_cx, lat_post, lattice_fields);
  oc.lattice = std::move(lat.governing);
  oc.scenarios = std::move(lat.reports);
  oc.scenario_accepted = std::move(lat.accepted);
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
  //                             (|{cell covering a masked voxel}|, Finding 7);
  //   emitted_lattice_cells   — cells the GENERATOR actually emitted
  //                             (LatticeGenStats::latticed_cells, its own count);
  //   voxels_strut_and_solid  — printed voxels that are BOTH inside an emitted
  //                             lattice cell that covers NO certified voxel AND
  //                             written as companion solid;
  //   voxels_strut_and_solid_bond — the same, inside a cell that DOES cover a
  //                             certified voxel: the lattice reaching into the solid
  //                             beside its pocket (the bond), by design since Finding 7.
  // On a uniform design-box run the first two must be EQUAL and the third ZERO.
  long long certified_lattice_cells = 0;
  long long emitted_lattice_cells = 0;
  long long voxels_strut_and_solid = 0;
  long long voxels_strut_and_solid_bond = 0;
  // A graded design-box run laying more than one grid (a swept plan's levels, or
  // passes): the audit is asked of every grid, and these are written only then.
  //   emitted_cells_covering_no_certified — cells a level or pass emits while
  //                             covering no voxel of the final mask: struts in a cell
  //                             the certificate calls solid. Must be 0.
  bool multi_grid = false;
  long long emitted_cells_covering_no_certified = 0;
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
// ★ SKIN PER ZONE (ruling 11-08 (1)): a lattice_regions row's skin -- the zone's own or
// the part's, and what the diagrid pass laid in it. A zone that asks for Skin and gets no
// skin strut says so in a plain line: no silent no-op.
std::string zone_skin_json(const JobLatticeRegion& r, const JobLattice& lat, std::size_t i,
                           const LatticeGenStats& gs) {
  const std::size_t z = i + 1;
  std::string s = ", \"skin\": " + json_str(r.skin.empty() ? lat.skin : r.skin) +
                  ", \"skin_source\": " + json_str(r.skin.empty() ? "lattice" : "region") +
                  ", \"skin_laid\": {\"anchor_nodes\": " + std::to_string(gs.zone_anchor_nodes[z]) +
                  ", \"skin_chords\": " + std::to_string(gs.zone_skin_chords[z]) +
                  ", \"skin_struts\": " + std::to_string(gs.zone_skin_struts[z]) + "}";
  if (r.skin == "diagrid" && gs.zone_skin_struts[z] == 0)
    s += ", \"skin_note\": " +
         json_str("Skin laid nothing in " +
                  (r.label.empty() ? "region " + std::to_string(z) : "\"" + r.label + "\"") +
                  ": no chord of the outer surface has its midpoint in this zone.");
  return s;
}

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
                                     const LatticeVoidEscapeReport* void_escape,
                                     // ★ Finding 7: the volume check, when it ran.
                                     const LatticeVolumeCheck* volume = nullptr,
                                     const LatticeVolumeCheck* volume_law = nullptr,
                                     const long long* shipped_counts = nullptr,
                                     // ★ E2.1: per voxel, the scenario the grade
                                     // read (LatticeVariantOutcome::grade_source).
                                     const std::vector<int>* grade_source = nullptr,
                                     // ★ E3: the include regions and their owner map.
                                     const std::vector<JobLatticeRegion>* region_jobs = nullptr,
                                     const std::vector<int>* region_owner = nullptr,
                                     const std::vector<LatticeRegionGraded>*
                                         region_graded = nullptr) {
  const LatticeGenStats& gs = oc.stats;
  const FixedDesignAnalysis& a = c.lattice;
  std::string s = "{\n";
  s += "  \"topology\": \"" + std::string(lattice_topology_name(a.lattice_topology)) +
       "\",\n";
  {
    const std::string note = lattice_type_directional_note(lattice_topology_name(a.lattice_topology));
    if (!note.empty()) s += "  \"directional_note\": \"" + note + "\",\n";
  }
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
         json_num(!lattice_shell_written(lat)
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
  // ★ K6 PART 2: WHAT THE STUB GUARD TOOK, never silently. Emitted only when the guard
  // was raised (an owner-clipped plan pass), so a legacy receipt is byte-identical. A
  // piece shorter than its own strut diameter prints as a bump and carries no load; the
  // count and the length say how much of that the ownership clip created.
  if (gs.stub_fragments_dropped > 0) {
    s += "  \"stub_fragments_dropped\": " +
         std::to_string(gs.stub_fragments_dropped) + ",\n";
    s += "  \"stub_fragment_length_mm\": " +
         json_num(gs.stub_fragment_length_mm) + ",\n";
  }
  s += "  \"landings\": " + std::to_string(gs.landings) + ",\n";
  s += "  \"anchor_nodes\": " + std::to_string(gs.anchor_nodes) + ",\n";
  s += "  \"skin_struts\": " + std::to_string(gs.skin_struts) + ",\n";
  // ★ Skin per zone: what the diagrid pass laid outside every zone (each zone's own is in
  // its lattice_regions row). Written only when a zone states its own skin.
  if (!gs.zone_skin_struts.empty())
    s += "  \"skin_outside_zones\": {\"anchor_nodes\": " +
         std::to_string(gs.zone_anchor_nodes[0]) +
         ", \"skin_chords\": " + std::to_string(gs.zone_skin_chords[0]) +
         ", \"skin_struts\": " + std::to_string(gs.zone_skin_struts[0]) + "},\n";
  s += "  \"rim_elements\": " + std::to_string(gs.rim_elements) + ",\n";
  // ★ THE RIM ON A REAL PART (ruling 11-08 (A)). Written only when a rim was asked for.
  if (oc.mesh_rim_ran) {
    const FeatureEdgeStats& fe = oc.rim_edges;
    const LatticeMeshRimReport& rr = oc.rim;
    s += "  \"rim\": {\"rides\": \"the sharp edges of " + oc.rim_rides +
         ", seated in the shell the struts are clipped to\", "
         "\"angle_threshold_deg\": " + json_num(fe.angle_threshold_deg) +
         ", \"min_piece_mm\": " + json_num(fe.min_piece_mm) +
         ", \"feature_edges\": " + std::to_string(fe.feature_edges) +
         ", \"open_edges_skipped\": " + std::to_string(fe.open_edges) +
         ", \"nonmanifold_edges_skipped\": " + std::to_string(fe.nonmanifold_edges) +
         ", \"pieces\": " + std::to_string(fe.pieces) +
         ", \"pieces_dropped_short\": " + std::to_string(fe.pieces_dropped_short) +
         ", \"length_dropped_mm\": " + json_num(fe.length_dropped_mm) +
         ", \"chains\": " + std::to_string(fe.chains) +
         ", \"chains_other_skin\": " + std::to_string(oc.rim_chains_other_skin) +
         ", \"chains_laid\": " + std::to_string(rr.chains_laid) +
         ", \"chains_clipped_away\": " + std::to_string(rr.chains_clipped_away) +
         ", \"chains_on_solid\": " + std::to_string(rr.chains_on_solid) +
         ", \"length_laid_mm\": " + json_num(rr.length_laid_mm) +
         ", \"length_on_solid_mm\": " + json_num(rr.length_on_solid_mm) +
         ", \"spans\": " + std::to_string(rr.spans) +
         ", \"joints\": " + std::to_string(rr.joints) +
         ", \"stations\": " + std::to_string(rr.stations) +
         ", \"stations_seated\": " + std::to_string(rr.stations_seated) +
         ", \"stations_unseated\": " + std::to_string(rr.stations_unseated) +
         ", \"seat_max_mm\": " + json_num(rr.seat_max_mm) +
         ", \"tie_ends\": " + std::to_string(rr.tie_ends) +
         ", \"ties_laid\": " + std::to_string(rr.ties_laid) +
         ", \"ties_touching\": " + std::to_string(rr.ties_touching) +
         ", \"ties_out_of_reach\": " + std::to_string(rr.ties_out_of_reach) +
         ", \"ties_clipped_away\": " + std::to_string(rr.ties_clipped_away) +
         ", \"tie_length_mm\": " + json_num(rr.tie_length_mm) +
         ", \"line_width_mm\": " + json_num(oc.rim_line_width_mm) +
         ", \"diameter_mm\": [" + json_num(rr.diameter_min_mm) + ", " +
         json_num(rr.diameter_max_mm) + "], \"line_widths\": [" +
         std::to_string(rr.line_widths_min) + ", " + std::to_string(rr.line_widths_max) +
         "], \"strength\": \"rim: not counted in strength\"" +
         (rr.chains_laid == 0
              ? std::string(", \"note\": \"Rim laid nothing: no sharp edge of the shipped surface "
                            "longer than one cell lies where the rim was asked for, or none had "
                            "room inside the part.\"")
              : std::string()) +
         "},\n";
  }
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
    // ★ Ruling 11-09: where the SOLID's outer faces come from, said only when the part
    // itself was latticed (a legacy receipt keeps its bytes).
    if (oc.solid_on_part_surface_asked) {
      s += "  \"solid_faces\": " +
           json_str(oc.solid_on_part_surface ? "the part's own surface" : "voxel steps") +
           ",\n";
      if (!oc.solid_on_part_surface)
        s += "  \"solid_faces_why\": " + json_str(oc.solid_on_part_surface_refused) + ",\n";
    }
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
    s += "    \"voxels_strut_and_solid_bond\": " +
         std::to_string(added.voxels_strut_and_solid_bond) + ",\n";
    if (added.multi_grid)
      s += "    \"emitted_cells_covering_no_certified\": " +
           std::to_string(added.emitted_cells_covering_no_certified) + ",\n";
    s += "    \"audit_note\": \"certified_lattice_cells is the cell set the "
         "certification mask implies (every cell covering a latticed voxel); "
         "emitted_lattice_cells is the generator's own count of the cells it wrote. "
         "On a uniform run they are EQUAL and voxels_strut_and_solid is 0 — the "
         "exported lattice and the certified lattice are the same set of cells, and "
         "no cell that covers no certified voxel writes struts into companion solid. "
         "voxels_strut_and_solid_bond counts solid voxels a covering cell reaches "
         "into beside its pocket: the lattice's bond to the solid.\",\n";
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
    // ★ RULING 2: the shape-grade band, written only when one was built.
    if (gf.band_voxels > 0 || gf.band_solid_voxels > 0) {
      const double* bx = gf.band_solid_box;
      s += "    \"shape_band\": {\"band_voxels\": " + std::to_string(gf.band_voxels) +
           ", \"struts_raised\": " + std::to_string(gf.band_raised_voxels) +
           ", \"snapped_to_line_width\": " + std::to_string(gf.band_snapped_voxels) +
           ", \"off_line_width\": " + std::to_string(gf.band_off_line_voxels) +
           ", \"cells_capped\": " + std::to_string(gf.band_capped_voxels) +
           ", \"quilt_rho\": " + json_num(gf.band_quilt_rho) +
           ", \"solid_where_unprintable\": " + std::to_string(gf.band_solid_voxels) +
           (gf.band_solid_voxels > 0
                ? ", \"solid_box_mm\": [" + json_num(bx[0]) + ", " + json_num(bx[1]) + ", " +
                      json_num(bx[2]) + ", " + json_num(bx[3]) + ", " + json_num(bx[4]) + ", " +
                      json_num(bx[5]) + "]"
                : std::string()) +
           (lattice_topology_is_sheet(a.lattice_topology)
                ? ", \"note\": \"a sheet grades its wall thickness only: no published method "
                  "grades a TPMS's cell size (04-references R5)\""
                : std::string()) +
           "},\n";
    }
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
    // ★ Rulings 11-09: the convex corners joined to the member they are a corner of.
    if (gf.corner_residue_voxels > 0)
      s += "      \"convex_corners\": {\"residue_voxels\": " +
           std::to_string(gf.corner_residue_voxels) + ", \"joined_to_their_member\": " +
           std::to_string(gf.corner_joined_voxels) + ", \"reach_mm\": " +
           json_num(gf.corner_reach_mm) +
           ", \"note\": \"a voxel under the floor whose residue ends within reach_mm of "
           "material that holds the floor is a convex corner of that member and is latticed "
           "with it; where the thin material runs on (a member joining another) it stays solid\"},\n";
    s += "      \"note\": \"member_too_thin_for_cell: the member cannot hold "
         "cells_per_member_floor cells across at this cell size — a SMALLER cell "
         "helps. strut_unprintable_at_every_cell: the strut this density emits is "
         "under the stated minimum extrudable width at every available cell — a "
         "BIGGER cell helps. irrecoverable_by_any_cell_size: the member is thinner "
         "than the floor times the smallest printable cell, so no cell choice can "
         "lattice it; the design itself is too thin here.\"\n";
    s += "    },\n";
    // ★ SLIVERS (reviewer's ruling 11-09): solid the law left that is in no block 2 line
    // widths across. Emitted only when the pass ran (2 line widths span more than one
    // voxel), so a coarse run's receipt keeps its bytes.
    if (gf.sliver_pass_block_voxels >= 2) {
      s += "    \"slivers\": {\"block_voxels\": " + std::to_string(gf.sliver_pass_block_voxels) +
           ", \"latticed_with_neighbours\": " + std::to_string(gf.sliver_voxels_latticed) +
           ", \"kept_solid\": " + std::to_string(gf.sliver_voxels_kept_solid) +
           ", \"latticed_min_cells_per_member\": " +
           json_num(gf.sliver_voxels_latticed > 0 ? gf.sliver_min_cells_per_member : 0.0) +
           ", \"note\": \"a solid piece under 2 line widths in any direction is latticed with "
           "its neighbours (their density and cell); one with no lattice beside it, or kept "
           "solid for a reason no cell answers, stays solid. The reason counts above are "
           "after this pass; widest_rejected_member_mm is the law's, before it.\"},\n";
    }
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
    s += "    \"min_strut_diameter_mm\": " +

         (std::isfinite(gf.min_strut_diameter_mm) ? json_num(gf.min_strut_diameter_mm) : std::string("null")) +
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
  // The type's own name where these strings said "octet" (lattice types round 1): an
  // octet receipt is byte-identical, an FCC receipt no longer claims octet's tensor.
  const std::string tn = lattice_topology_name(a.lattice_topology);
  if (lat.outer_finish == "skin")
    s += "  \"describes\": \"the exported latticed mesh (" + tn + " interior + freeform "
         "2D boundary skin, NO solid shell) — the composite model below is "
         "shell-blind, see finish_note\",\n";
  else if (lat.outer_finish == "none")
    s += "  \"describes\": \"the exported latticed mesh (" + tn + " interior, OPEN: no "
         "solid shell, no freeform skin) solved with the " + tn + " homogenized cubic "
         "tensor, the cells the part's free surface cuts given no credit (open_finish)\",\n";
  else if (lat.outer_finish == "shell+skin")
    s += "  \"describes\": \"the exported latticed mesh (solid shell + " + tn + " "
         "interior + decorative freeform skin) solved with the " + tn + " homogenized "
         "cubic tensor\",\n";
  else
    s += "  \"describes\": \"the exported latticed mesh (solid shell + " + tn + " interior) "
         "solved with the " + tn + " homogenized cubic tensor\",\n";
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
  // ★ E2.1: THE SCENARIOS, when the job has them (absent otherwise, so no other
  // receipt changes). The lattice is graded from the worst stress over `graded_on`
  // and certified under each; `lattice_margin_*` above is the governing one's.
  // `stress_share` is, per scenario, the share of latticed voxels whose grade read
  // that scenario's stress.
  if (!c.scenarios.empty()) {
    std::string gov;
    for (const ScenarioReport& r : c.scenarios)
      if (r.governs) gov = r.name;
    s += "  \"scenarios\": {\n    \"graded_on\": [";
    for (std::size_t i = 0; i < c.scenarios.size(); ++i)
      s += std::string(i ? ", " : "") + json_str(c.scenarios[i].name);
    s += "],\n    \"governing\": " + json_str(gov) + ",\n    \"per_scenario\": [";
    for (std::size_t i = 0; i < c.scenarios.size(); ++i) {
      const ScenarioReport& r = c.scenarios[i];
      double solid = std::numeric_limits<double>::quiet_NaN();
      for (const ScenarioReport& q : c.solid_scenarios)
        if (q.name == r.name) solid = q.margin;
      s += std::string(i ? ", " : "") + "{\"name\": " + json_str(r.name) +
           ", \"lattice_margin\": " + json_num(r.margin) + ", \"accepted\": " +
           ((i < c.scenario_accepted.size() && c.scenario_accepted[i]) ? "true" : "false") +
           ", \"unheld\": " + (r.unheld ? "true" : "false") +
           ", \"solid_margin\": " + json_num(solid) + "}";
    }
    s += "]";
    if (grade_source && graded.gf && !variant.report.scenarios.empty()) {
      const std::vector<char>& lm = graded.gf->posture.mask;
      std::vector<long long> n(variant.report.scenarios.size(), 0);
      long long total = 0;
      for (std::size_t e = 0; e < lm.size() && e < grade_source->size(); ++e) {
        if (!lm[e]) continue;
        ++total;
        const int src = (*grade_source)[e];
        if (src >= 0 && static_cast<std::size_t>(src) < n.size()) ++n[static_cast<std::size_t>(src)];
      }
      s += ",\n    \"stress_share\": [";
      bool first = true;
      for (std::size_t k = 0; k < n.size(); ++k) {
        bool used = false;
        for (const ScenarioReport& r : c.scenarios)
          if (r.name == variant.report.scenarios[k].name) used = true;
        if (!used) continue;
        s += std::string(first ? "" : ", ") + "{\"name\": " +
             json_str(variant.report.scenarios[k].name) + ", \"share\": " +
             json_num(total > 0 ? static_cast<double>(n[k]) / static_cast<double>(total) : 0.0) +
             "}";
        first = false;
      }
      s += "]";
    }
    s += "\n  },\n";
  }
  // ★ E3: EACH INCLUDE REGION, with its own grading and where each value came from
  // ("region" = its own, "grading" = the part's). Written only when a region states a
  // grading of its own, so no other receipt changes.
  if (region_jobs && region_owner && !region_owner->empty() && region_graded &&
      region_graded->size() == region_jobs->size()) {
    s += "  \"lattice_regions\": [";
    for (std::size_t i = 0; i < region_jobs->size(); ++i) {
      const JobLatticeRegion& r = (*region_jobs)[i];
      const long long nlat = (*region_graded)[i].voxels;
      const double lo = (*region_graded)[i].rho_lo, hi = (*region_graded)[i].rho_hi;
      auto src = [](bool own) { return std::string(own ? "\"region\"" : "\"grading\""); };
      s += std::string(i ? ", " : "") + "{\"id\": " + std::to_string(i + 1) +
           ", \"label\": " + json_str(r.label) + ", \"kind\": " + json_str(r.kind) +
           ", \"latticed_voxels\": " + std::to_string(nlat) +
           ", \"rho_min_graded\": " + json_num(nlat ? lo : 0.0) +
           ", \"rho_max_graded\": " + json_num(nlat ? hi : 0.0) +
           ", \"grading\": {\"mode\": " + json_str(r.grading.empty() ? "" : r.grading) +
           ", \"rho_min\": " + json_num(r.rho_min) + ", \"rho_max\": " + json_num(r.rho_max) +
           ", \"demand_exponent\": " + json_num(r.demand_exponent) +
           ", \"shape_grade\": " + std::to_string(r.shape_grade) +
           ", \"shape_grade_band_mm\": " + json_num(r.shape_grade_band_mm) +
           (r.cell_min_mm > 0.0 || r.cell_max_mm > 0.0
                ? ", \"cell_min_mm\": " + json_num(r.cell_min_mm) +
                      ", \"cell_max_mm\": " + json_num(r.cell_max_mm)
                : std::string()) +
           // ★ E3 "off" with no density: the search for its lightest one density
           ((*region_graded)[i].searched
                ? ", \"one_density\": {\"rho\": " + json_num((*region_graded)[i].search_rho) +
                      ", \"law_search_rho\": " + json_num((*region_graded)[i].search_law_rho) +
                      ", \"shipped_passes\": " +
                      std::to_string((*region_graded)[i].search_shipped_trials) +
                      ", \"printable_floor\": " + json_num((*region_graded)[i].search_floor) +
                      ", \"upper_bound_graded_peak\": " +
                      json_num((*region_graded)[i].search_peak) +
                      ", \"law_margin\": " + json_num((*region_graded)[i].search_margin) +
                      ", \"trials\": " + std::to_string((*region_graded)[i].search_trials) +
                      ", \"law_certified\": " +
                      ((*region_graded)[i].search_certified ? "true" : "false") +
                      ((*region_graded)[i].search_certified
                           ? std::string()
                           : ", \"refusal\": " +
                                 json_str(std::string("Region ") +
                                          (r.label.empty() ? std::to_string(i + 1)
                                                           : "\"" + r.label + "\"") +
                                          " (grading off, one density): the lattice does "
                                          "not certify even with it at its graded peak " +
                                          json_num((*region_graded)[i].search_peak) +
                                          " (margin " +
                                          json_num((*region_graded)[i].search_margin) +
                                          "), so no lighter one density was searched. Give "
                                          "it a density, or let it grade.")) +
                      "}"
                : std::string()) +
           // ★ E3: the cells the region got, where the plan sized cells per voxel (swept)
           (nlat && (*region_graded)[i].cell_hi > 0.0
                ? ", \"cell_mm_graded\": [" + json_num((*region_graded)[i].cell_lo) + ", " +
                      json_num((*region_graded)[i].cell_hi) + "]"
                : std::string()) +
           "}" +
           // ★ Skin per zone: the zone's skin (its own, or the part's) and what it laid
           (!gs.zone_skin_struts.empty() && i + 1 < gs.zone_skin_struts.size()
                ? zone_skin_json(r, lat, i, gs)
                : std::string()) +
           ", \"source\": {\"mode\": " + src(!r.grading.empty()) +
           ", \"band\": " + src(r.rho_max > 0.0) +
           ", \"demand_exponent\": " + src(r.demand_exponent > 0.0) +
           ", \"shape_grade\": " + src(r.shape_grade >= 0) +
           ", \"shape_grade_band_mm\": " + src(r.shape_grade_band_mm >= 0.0) + "}}";
    }
    s += "],\n";
  }
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
  // ★ Ruling 11-06 2(a): no solid voxel carries the load and the strut law cannot
  // certify the lattice (analyze.hpp lattice_not_certified). Written only then.
  if (a.lattice_not_certified)
    s += "  \"lattice_not_certified\": true,\n  \"lattice_not_certified_reason\": " +
         json_str(a.lattice_not_certified_reason) + ",\n";
  // ★ E2.4: the OPEN finish's certificate (outer_finish "none"), written only then.
  if (c.open_finish) {
    s += "  \"open_finish\": {\"cut_cell_voxels\": " + std::to_string(c.open_cut_voxels) +
         ", \"latticed_voxels\": " + std::to_string(c.open_latticed_voxels) +
         ", \"cut_cell_credit\": \"none\", \"load_path_after\": " +
         (c.open_load_path_ok ? "true" : "false") +
         ", \"basis\": \"the cells at the part's free surface (cut by it or flush against it) form a weaker boundary "
         "layer (Onck, Andrews & Gibson 2001, Int. J. Mech. Sci. 43(3), Parts I and II, "
         "doi:10.1016/S0020-7403(00)00042-4 and -00043-6); no measured knockdown for it exists, so they get no strength or "
         "stiffness: the safe floor. The margins above are that solve's.\"";
    if (!c.open_refusal.empty()) s += ", \"refusal\": " + json_str(c.open_refusal);
    if (!c.open_region_notes.empty()) {
      s += ", \"regions\": [";
      for (std::size_t i = 0; i < c.open_region_notes.size(); ++i)
        s += std::string(i ? ", " : "") + json_str(c.open_region_notes[i]);
      s += "], \"wall_mm\": " + json_num(c.region_wall_mm) +
           ", \"wall_voxels\": " + std::to_string(c.region_wall_voxels) +
           ", \"wall_basis\": \"the slicer's wall (loops x line widths, else two line "
           "widths) in whole voxel layers rounded up: solid in the file and counted by the "
           "certificate\"";
    }
    s += "},\n";
  }
  if (lat.outer_finish != "shell") {
    s += "  \"finish_certified\": " +
         std::string(finish_certified ? "true" : "false") + ",\n";
    if (!finish_certified)
      s += "  \"finish_note\": \"outer_finish 'skin' drops the solid shell; the "
           "composite certification model is shell-blind (the posture never "
           "credited the shell), so the margins above describe the same model "
           "as a 'shell' run and do NOT certify the open, shell-less object: "
           "clipped boundary cells fall below the periodic-" + tn + " stiffness the "
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
  // ★ Except where no solid voxel carries the load (ruling 11-06 2(a)): there the
  // analysis folded the worst-case margin into the gate, and "gated" says so.
  if (a.lattice_strut_report) {
    const StrutStrengthReport& ss = a.lattice_strut;
    s += "  \"strut_strength\": {\n";
    // ★ The type's OWN law (ruling 11-08 (B)): octet's text is PR 259's, unchanged.
    s += "    \"law\": \"" + strut_law_source(a.lattice_topology) + "\",\n";
    // ★ Ruling 11-06 2(a): gated where no solid voxel carries the load.
    s += "    \"gated\": " + std::string(a.strut_gated ? "true" : "false") + ",\n";
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
    s += "    \"law_rho_span\": [" + json_num(strut_law_rho_min(a.lattice_topology)) +
         ", " + json_num(strut_law_rho_max(a.lattice_topology)) + "],\n";
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
    s += "    \"resolution_note\": \"" + strut_law_resolution_note(a.lattice_topology) +
         "\"\n";
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
  if (oc.sheet_simplified) {
    s += "  \"sheet_mesh\": {\n";
    s += "    \"max_deviation_limit_mm\": " + json_num(kSheetMaxDeviationMm) + ",\n";
    s += "    \"triangles_contoured\": " + std::to_string(oc.sheet_triangles_contoured) + ",\n";
    s += "    \"triangles\": " + std::to_string(oc.sheet_triangles) + ",\n";
    s += "    \"max_deviation_mm\": " + json_num(oc.sheet_max_deviation_mm) + ",\n";
    s += "    \"cut_max_deviation_mm\": " + json_num(oc.sheet_cut_max_deviation_mm) + ",\n";
    s += "    \"samples_past_bead_floor\": " + std::to_string(oc.sheet_samples_past_floor) + ",\n";
    s += "    \"step_max_deviation_mm\": " + json_num(oc.sheet_step_max_deviation_mm) + ",\n";
    s += "    \"step_samples\": " + std::to_string(oc.sheet_step_samples) + ",\n";
    s += "    \"step_samples_outside_band\": " +
         std::to_string(oc.sheet_step_samples_outside_band) + ",\n";
    s += "    \"step_worst_outside_band_mm\": " +
         json_num(oc.sheet_step_worst_outside_band_mm) + ",\n";
    s += "    \"sheet_samples\": " + std::to_string(oc.sheet_samples) + ",\n";
    s += "    \"note\": \"bounded edge collapse (Garland & Heckbert 1997) checked against the "
         "true surface; max_deviation is measured on every written triangle of the sheet's "
         "own surface, cut_max_deviation where it is cut (kept as contoured, under solid); "
         "where the wall steps between voxels no collapse leaves the band the walls in reach "
         "span (no wall below the bead), step_max_deviation is the distance from the "
         "sample's own voxel's surface there, and step_*_outside_band what the contouring "
         "left outside that band, kept as contoured\"\n";
    s += "  },\n";
  }
  // ── ★ THE VOLUME CHECK (Finding 7): per latticed pocket, the lattice the file holds
  // against what the certificate reads there. No wall clock (byte-identity comparisons).
  if (volume && volume->ran) {
    const LatticeVolumeCheck& vc = *volume;
    s += "  \"volume_check\": {\n";
    s += "    \"rule\": \"per latticed pocket (face-connected latticed voxels) of at least one "
         "cell's volume, the exported lattice volume no more than 10 % BELOW the certified "
         "density times the pocket's volume; above is reported, never refused\",\n";
    s += "    \"limit\": " + json_num(kLatticeVolumeGapLimit) + ",\n";
    s += "    \"pockets\": " + std::to_string(vc.pockets.size()) + ",\n";
    s += "    \"certified_mm3\": " + json_num(vc.certified_mm3) + ",\n";
    s += "    \"exported_mm3\": " + json_num(vc.exported_mm3) + ",\n";
    s += "    \"gap\": " +
         json_num(vc.certified_mm3 > 0.0 ? vc.exported_mm3 / vc.certified_mm3 - 1.0 : 0.0) +
         ",\n";
    s += "    \"worst_gap\": " + json_num(vc.worst_gap) + ",\n";
    s += "    \"highest_gap\": " + json_num(vc.highest_gap) + ",\n";
    {
      char hb[96];
      std::snprintf(hb, sizeof hb, "file %+.1f %% over certified",
                    100.0 * (vc.highest >= 0 ? vc.highest_gap : 0.0));
      s += "    \"high_side\": \"" + std::string(hb) + "\",\n";
    }
    s += "    \"refused\": " + std::string(vc.refused() ? "true" : "false") + ",\n";
    s += "    \"judged_from_mm3\": " + json_num(vc.judge_min_mm3) + ",\n";
    if (volume_law && volume_law->ran) {
      // (3): the certificate above is rebuilt from the file; this is the law against it.
      s += "    \"certified_from\": \"min(the law's density, the file's measured solid "
           "fraction) per voxel, held at the band floor below it\",\n";
      s += "    \"law_certified_mm3\": " + json_num(volume_law->certified_mm3) + ",\n";
      s += "    \"law_gap\": " +
           json_num(volume_law->certified_mm3 > 0.0
                        ? volume_law->exported_mm3 / volume_law->certified_mm3 - 1.0
                        : 0.0) +
           ",\n";
      s += "    \"law_lightest_pocket_gap\": " + json_num(volume_law->worst_gap) + ",\n";
      s += "    \"law_heaviest_pocket_gap\": " + json_num(volume_law->highest_gap) + ",\n";
      if (shipped_counts) {
        s += "    \"voxels_lowered_to_file\": " + std::to_string(shipped_counts[0]) + ",\n";
        s += "    \"voxels_held_at_band_floor\": " + std::to_string(shipped_counts[1]) + ",\n";
      }
    }
    s += "    \"small_pockets_not_judged\": " + std::to_string(vc.small_pockets) + ",\n";
    s += "    \"small_pockets_certified_mm3\": " + json_num(vc.small_certified_mm3) + ",\n";
    s += "    \"small_pockets_exported_mm3\": " + json_num(vc.small_exported_mm3) + ",\n";
    s += "    \"points\": " + std::to_string(vc.points) + ",\n";
    // The eight JUDGED pockets lightest against their certificate, lightest first.
    std::vector<std::size_t> order;
    for (std::size_t i = 0; i < vc.pockets.size(); ++i)
      if (vc.pockets[i].judged) order.push_back(i);
    std::stable_sort(order.begin(), order.end(), [&vc](std::size_t a, std::size_t b) {
      return vc.pockets[a].gap < vc.pockets[b].gap;
    });
    if (order.size() > 8) order.resize(8);
    s += "    \"worst_pockets\": [";
    for (std::size_t n = 0; n < order.size(); ++n) {
      const LatticePocketVolume& P = vc.pockets[order[n]];
      if (n) s += ",";
      s += "\n      {\"voxels\": " + std::to_string(P.voxels) +
           ", \"certified_mm3\": " + json_num(P.certified_mm3) +
           ", \"exported_mm3\": " + json_num(P.exported_mm3) +
           ", \"gap\": " + json_num(P.gap) +
           ", \"points_per_voxel\": " + std::to_string(P.points_per_voxel) +
           ", \"bbox_min_mm\": [" + json_num(P.lo.x) + ", " + json_num(P.lo.y) + ", " +
           json_num(P.lo.z) + "], \"bbox_max_mm\": [" + json_num(P.hi.x) + ", " +
           json_num(P.hi.y) + ", " + json_num(P.hi.z) + "]}";
    }
    s += "\n    ]\n  },\n";
  }
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
       "but strut-level strength needs de-homogenization (Phase 2) and is NOT gated. " +
       std::string(a.lattice_topology == LatticeTopology::Octet
                       ? "Octet tensor magnitudes carry PR 198's +-10% resolution caveat."
                       : "The " + tn + " tensor rows are PR 246's (vpc48, drift under "
                         "2.4 % against vpc64).") +
       "\"\n";
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
  // ★ WHY a refusal happened, so the message can say it. A refusal that cannot name
  // its own cause sent me chasing the region resolution when the fault was here.
  std::size_t masked_voxels = 0;
  std::size_t distinct_ids = 0;
  std::size_t voxels_with_id_zero = 0;
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
  const LatticeTopology topo = lattice_topology_from_id(jg.topology);
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
  // ★ +inf IS A MEASUREMENT, NOT A MISSING ONE. `local_member_thickness_mm` returns
  // +inf where the member is THICKER than the EDT cap can measure — and the centre of
  // a 40 mm cube at a 0.625 mm voxel sits exactly at the 32-voxel cap. Filtering those
  // out discarded every interior voxel, so a solid block reported "no measurable member
  // width" and STEPPED REFUSED TO LATTICE IT. The cap is a LOWER BOUND on the width
  // (grading.hpp says so at `min_member_width_mm`), so it is used as one: a member at
  // least this thick, which is the conservative reading and is never wrong in the
  // direction that matters — a wider member only ever permits a COARSER cell.
  const double width_cap_mm =
      static_cast<double>(thickness_cap_voxels) * grid.spacing;
  std::map<int, std::vector<double>> rhos, widths;
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    const int r = region_ids[e];
    rhos[r].push_back(relative_density[e]);
    const double w = std::isfinite(width[e]) ? width[e] : width_cap_mm;
    if (w > 0.0) widths[r].push_back(w);
  }
  for (const auto& kv : rhos) {
    so.masked_voxels += kv.second.size();
    if (kv.first == 0) so.voxels_with_id_zero = kv.second.size();
  }
  so.distinct_ids = rhos.size();
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
    const double phi = lattice_strut_diameter_mm(topo, rc.median_rho, 1.0);
    const double printable_min = phi > 0.0 ? w / phi : 0.0;
    const double homogenizable_max = rc.median_width_mm / n_star;
    rc.cell_mm = std::max(homogenizable_max, printable_min);
    if (!(rc.cell_mm > 0.0)) { ++so.regions_with_no_voxels; continue; }
    rc.strut_mm = lattice_strut_diameter_mm(topo, rc.median_rho, rc.cell_mm);
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
  // ★ E2.1: per voxel, the index (in the run's scenario order) of the scenario whose
  // stress the grade read there; -1 everywhere on a job without scenarios.
  std::vector<int> grade_source;
  // ★ E3: the include regions (declared order) and per voxel the one that owns it,
  // for the receipt's lattice_regions. Empty when no region states its own grading.
  std::vector<JobLatticeRegion> region_jobs;
  std::vector<int> region_owner;
  // Per region (declared order): its latticed voxels and the density range the GRADING
  // LAW gave them, taken before the certificate's as-built rebuild (which reads each laid
  // cell, and a cell straddling a region's edge carries its neighbour's density).
  std::vector<LatticeRegionGraded> region_graded;
  std::string one_density_refusal;  // ★ E3: a searched region no density certified
  // ★ E2.4 per region: the open regions (name, latticed voxels) and the wall closing them
  struct OpenRegion { std::string name; long long voxels = 0; };
  std::vector<OpenRegion> open_regions;
  double region_wall_mm = 0.0;
  long long region_wall_voxels = 0;
  // ★ the ORGANIC structural certificate (beam network), when one was run
  OrganicCertificate organic_cert;
  OrganicRecommendation organic_recommendation;   // organic_recommend != off
  OrganicRecommendBand organic_recommend_band;
  bool organic_recommend_ran = false;
  // ★ shape fit is ON by default for organic; the receipt must prove it RAN, from the
  // outcome's own counters rather than the default echoed back.
  bool organic_shape_fit_on = false;
  long long organic_shape_fit_candidates = 0;
  long long organic_shape_fit_voxels_shrunk = 0;
  double organic_shape_fit_min_ratio = 1.0;
  SyntheticStressReport organic_synthetic;   // synthetic stress laid into dead walls
  double organic_solid_rim_mm = 0.0;
  long long organic_solid_rim_voxels = 0;
  // ★ RULING B: the octet's solid outline beam, as DERIVED and as applied.
  double outline_beam_mm = 0.0;
  double outline_bleed_mm = 0.0;
  long long outline_beam_voxels = 0;
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
  // ★ the any-step plan as laid down, and the seam census the certificate stands on
  long long anystep_cells = 0, anystep_regions = 0, anystep_passes = 0;
  std::string anystep_histogram;
  // ★ §3: "size=rho/radius_mm", descending by size, beside the histogram.
  std::string anystep_rho_by_size;
  // ★ K3 (3): per include region, the volume the PLAN left solid -- printed voxels the
  // region owns that no plan cell covers. "r1=1234.567, r2=0.000" in mm3.
  std::string plan_solid_remainder_mm3;
  double plan_latticed_mm3 = 0.0;
  // ★ ruling 1's condition: latticed voxels per region whose density came from core's
  // own grading because the covering cell sent none. "r1=0, r2=0" on a plan that sent
  // a rho with every cell.
  std::string plan_rho_fallback_by_region;
  // ★ ruling 2: how many include regions the outline clip applies to, and how many it
  // CANNOT apply to (mask-backed: no analytic distance, so no clip term).
  long long clip_includes_outlined = 0, clip_includes_mask_backed = 0;
  // ★ ruling 2: per region, the volume its own plan cells cover that the region does
  // not reach -- the set the outline clip stops struts from filling. "r1=5097.656".
  std::string clip_outside_region_mm3;
  // ★ ruling 3b: the same volume split by cause, per region.
  std::string clip_outside_by_cause_mm3;
  // ★ K5: where the generator's strut and node radius queries got their density.
  long long plan_rho_queries_plan = 0, plan_rho_queries_posture = 0,
            plan_rho_queries_floor = 0;
  // ★ K4: the plan as laid, per region and per group, and the generator's own ledger.
  std::vector<RunInfo::PlanRegion> plan_by_region;
  long long plan_laid_unattributed = 0;
  // ★ whether the ledger tap ran at all (lattice.emit_plan_laid): without it the laid
  // counts are not measured and must not be reported as zeros.
  bool plan_laid_measured = false;
  // ★ the law graded nothing and the run carried on anyway, because the plan is the
  // design and carries its own density (ruling of 2026-10-11). Reported, never silent.
  bool law_ungradeable_reported = false;
  std::string law_ungradeable_note;
  double outline_inward_mm = 0.0;
  long long seam_spans_before = 0, seam_spans_after = 0;
  double seam_piece_mm = 0.0, seam_longest_before_mm = 0.0;
  long long seam_welded_nodes = 0, seam_t_junction_ends = 0, seam_floating_ends = 0;
  SteppedOutcome stepped;  // meaningful iff `stepped_ran`
  double organic_trace_seconds = 0.0;
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
  // ★ Finding 7: the volume check (lattice_volume_check.hpp) on what was just written,
  // per latticed pocket. A pocket off by more than 10 % refuses the rung exactly as a
  // sealed cavity does: the ladder skips it, lattice_variant refuses, and the written
  // lattice files are removed.
  LatticeVolumeCheck volume_check;      // judged on the certificate rebuilt from the file
  LatticeVolumeCheck volume_check_law;  // the same file against the law's own density
  long long shipped_lowered = 0, shipped_at_floor = 0;
  double shipped_law_mm3 = 0.0, shipped_certified_mm3 = 0.0;
  bool volume_refused = false;
  std::string volume_refused_reason;
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
  OrganicGenStats growth;
  // ★ TRUE IFF grow_organic_lattice WAS CALLED. Never inferred from a counter: a run
  // that grew and produced nothing is a different fact from a traced run, and the
  // counters above are meaningless in the second case.
  bool growth_ran = false;
  // ★ The job stated organic_strut_width_mm, so the bead is that number everywhere and
  // neither the mass coupling nor the calibration touched it.
  bool bead_is_stated = false;
  // ★ the rho band the tracer clamped to, carried out so the density can be REBUILT
  // from the shipped spans on exactly the same terms.
  double rho_min_used = 0.0, rho_max_used = 0.0;
  // ★★ SHAPE-FIT REPORTING. Reported whether or not the feature is on, so "it did
  // nothing" and "it was never asked to run" are distinguishable in the receipt — a
  // zero that was never measured is not a passing zero.
  std::size_t shape_fit_voxels_shrunk = 0;
  std::size_t shape_fit_candidates = 0;
  double shape_fit_min_ratio = 1.0;
  bool net_skin_wanted = false;   // bare lattice only — see run_organic_step
  bool ran = false;
  OrganicLattice lat;
  double strut_diameter_mm = 0.0;
  // Did the job's swept window govern the separation, or the constant-bead fallback?
  bool window_governed = false;
  // ★ R13: timed around the TRACER ALONE, so the number is a measurement of this
  // algorithm rather than of the solve it happens to sit beside.
  double trace_seconds = 0.0;
};

// ── ★ SYNTHETIC STRESS FOR DEAD WALLS (maintainer, 2026-09-05) ──────────────────
// Per-region opt-in (lattice.regions[].synthetic_stress, aesthetic organic only, the
// schema refuses anything else). The include-region id a voxel carries is its
// 1-based position among the job's INCLUDE regions in declaration order -- exactly
// how lattice_role_regions_from_job pushes them -- so the config is built by the
// same count. Returns the tensor the organic step should read: the real one, or a
// copy with the synthetic field laid into the configured regions.
static std::vector<double> stress_tensor_for_organic(
    const JobDescription& job, const VoxelGrid& grid,
    const std::vector<char>& candidate, const std::vector<int>& voxel_region_id,
    const std::vector<double>& real, SyntheticStressReport* rep_out) {
  std::vector<SyntheticStressRegion> cfg;
  int include_index = 0;
  for (const JobLatticeRegion& r : job.lattice.regions) {
    if (r.role != "include") continue;
    ++include_index;
    if (!r.synthetic_stress) continue;
    SyntheticStressRegion c;
    c.region_id = include_index;
    c.face_id = r.face_id;
    c.foci = r.synthetic_foci;
    c.soft_mm = r.synthetic_soft_mm;
    cfg.push_back(c);
  }
  if (cfg.empty() || voxel_region_id.size() != grid.voxel_count()) {
    if (!cfg.empty())
      std::fprintf(stderr, "[synthetic] %zu region(s) asked for synthetic stress but "
                           "this path has no per-voxel region ids -- NOT applied\n",
                   cfg.size());
    return real;
  }
  std::vector<double> out = real;
  const SyntheticStressReport rep =
      synthesize_focal_stress(grid, candidate, voxel_region_id, cfg, 0.02, out,
                              kOrganicSyntheticDeadFloorMPa);
  if (rep_out) *rep_out = rep;
  std::fprintf(stderr, "[synthetic] %zu region(s): %zu voxels, %zu fully synthetic, "
                       "%zu blended; dead threshold %.4g (peak %.4g, %s rule)\n",
               rep.regions, rep.voxels_in_regions, rep.voxels_fully_synthetic,
               rep.voxels_blended, rep.dead_threshold, rep.peak_von_mises,
               rep.dead_floor_bound ? "ABSOLUTE 0.005 MPa" : "2% of peak");
  // ★ RULING H: one line per region saying whether the WALL was judged dead, and on
  // what measurement. A flagged wall that is carrying load is left alone, and this is
  // where the user finds out that their flag did nothing.
  for (const SyntheticStressRegionReport& rr : rep.per_region)
    std::fprintf(stderr,
                 "[synthetic] region %d (face %d): p99 %.4g vs threshold %.4g -> %s"
                 "%s\n", rr.region_id, rr.face_id, rr.p99_von_mises, rep.dead_threshold,
                 rr.whole_region ? "DEAD, synthesised WHOLE" : "carrying load, UNTOUCHED",
                 rr.whole_region ? "" : " (the synthetic_stress flag did nothing here)");
  return out;
}

// ── ★ RULING H: WHICH VOXELS TOOK A MANUFACTURED FIELD ───────────────────────
// One flag per voxel, from the synthesis report's own region list, so the spacing
// window can exclude them. Regions the report did not mark whole contribute nothing,
// and an empty report gives an all-zero mask -- which is byte-identical to the
// behaviour before this ruling.
static std::vector<char> organic_synthesised_whole_voxels(
    const SyntheticStressReport& rep, const std::vector<int>& voxel_region_id,
    std::size_t n) {
  std::vector<char> whole(n, 0);
  if (voxel_region_id.size() != n) return whole;
  std::set<int> ids;
  for (const SyntheticStressRegionReport& r : rep.per_region)
    if (r.whole_region) ids.insert(r.region_id);
  if (ids.empty()) return whole;
  for (std::size_t e = 0; e < n; ++e)
    if (ids.count(voxel_region_id[e])) whole[e] = 1;
  return whole;
}

OrganicOutcome run_organic_step(bool shell_is_written,
                                const VoxelGrid& grid,
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
                                // ★ THE USER'S OWN CHECKBOX (job.loads.minimize_plastic).
                                // For organic it means LARGEST CELLS POSSIBLE — see the
                                // exponent below. No second control is invented.
                                bool minimize_plastic,
                                const Vec3& build_dir, double printed_iso,
                                int thickness_cap_voxels,
                                // ★ The machine's layer height, needed by the GROWTH
                                // path: it advances a tip one layer at a time and asks
                                // its support question in that discretisation. 0 = not
                                // stated, and growth falls back to half a voxel.
                                double layer_height_mm = 0.0,
                                bool probe_only = false,
                                // ★ RULING H (2026-09-18): the voxels of every region
                                // that was synthesised WHOLE. Such a wall has no real
                                // stress left to grade by, so it is excluded from the
                                // window statistics and takes the window's MIDDLE
                                // spacing. null / empty = nothing was synthesised.
                                const std::vector<char>* synthesised_whole = nullptr) {
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

  // ── ★ THE SPACING WINDOW IS THE JOB'S OWN SWEPT LADDER ─────────────────────
  //
  // ★ THIS IS THE CONTROL THAT WAS MISSING, AND ITS ABSENCE WAS THE 2.76 GB FILE.
  // `cell_min_mm` / `cell_max_mm` mean "the range of cell sizes I want" for DOUBLED.
  // Organic has no cells — but it has a SEPARATION, which is the same quantity under
  // another name, and the first version simply IGNORED the window: it derived the
  // separation from the mass coupling at a constant nozzle-width bead. A job asking
  // for 5-10 mm cells got 0.6-2.0 mm separation, and on a 40 mm cube that emitted
  // 55 million triangles carrying 27x the part's own volume in overlapping struts.
  // The user asked for a spacing range and was handed a different one.
  //
  // So the window IS the spacing range. The grading law's own density decides WHERE in
  // it each voxel sits, and the BEAD falls out of the mass coupling instead of being
  // fixed — the same three quantities (rho, d, t) related the same way, read in the
  // direction the user's control actually points.
  // ★★ THE SCALE, APPLIED TO THE REQUESTED WINDOW AND NOWHERE ELSE. Multiplying the
  // cell window is what carries a pattern onto a bigger part: the weave keeps its
  // proportions and simply gets coarser. It is applied HERE, before anything reads the
  // window, so the shape-fit cap, the grading law and the mass coupling all see the one
  // scaled window rather than each applying the factor for themselves.
  //
  // ★ THE FLOORS ARE NOT SCALED. min_extrudable_width_mm is the nozzle, and the VDI
  // density floor is the standard; neither knows how big the part is. Scaling DOWN
  // therefore stops at what will print rather than going through it, and the tracer
  // counts the voxels it had to raise.
  const double lat_scale = jg.organic_scale > 0.0 ? jg.organic_scale : 1.0;
  const double cell_min_mm = jg.cell_min_mm * lat_scale;
  const double cell_max_mm = jg.cell_max_mm * lat_scale;
  if (lat_scale != 1.0 && std::getenv("TOPOPT_ORGANIC_TRACE"))
    std::fprintf(stderr, "[scale] x%.3f: cell window %.2f-%.2f -> %.2f-%.2f mm\n",
                 lat_scale, jg.cell_min_mm, jg.cell_max_mm, cell_min_mm, cell_max_mm);
  const bool have_window = cell_min_mm > 0.0 && cell_max_mm >= cell_min_mm;

  // ★ WHERE IN THE WINDOW: the grading law's OWN density, normalised over the band it
  // actually used — so §4(b) still holds and all three algorithms take their density
  // from one law. f = 1 at the busiest material (tightest spacing, cell_min), f = 0 at
  // the quietest (widest, cell_max). A UNIFORM field gives f = 0 everywhere, i.e. the
  // LARGEST cells, which is the right degenerate answer for "nothing is working hard".
  // ★ RULING H, SECOND HALF: A WHOLE-SYNTHESISED WALL IS NOT EVIDENCE ABOUT THE PART.
  // Its field was manufactured and then scaled so its PEAK lands on the dead threshold,
  // so every voxel in it reads near-zero against a real wall. Left in these statistics
  // it drags rho_lo down and takes the coarsest spacing in the window -- which is what
  // put his dead wall at the wide end. It is excluded here and given the window's
  // MIDDLE below. (`whole` empty = nothing was synthesised, and this is the old code.)
  const bool have_synth =
      synthesised_whole && synthesised_whole->size() == n;
  auto is_synth = [&](std::size_t e) {
    return have_synth && (*synthesised_whole)[e] != 0; };
  double rho_lo = 0.0, rho_hi = 0.0;
  bool any_rho = false;
  std::size_t synth_voxels = 0;
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    if (is_synth(e)) { ++synth_voxels; continue; }
    const double r = relative_density[e];
    if (!any_rho) { rho_lo = rho_hi = r; any_rho = true; }
    rho_lo = std::min(rho_lo, r);
    rho_hi = std::max(rho_hi, r);
  }
  // Every latticed voxel synthesised: there is no real wall to normalise against, so
  // the window statistics are empty and EVERYTHING takes the middle. Better than
  // normalising a manufactured field against itself.
  if (!any_rho)
    for (std::size_t e = 0; e < n; ++e)
      if (lattice_mask[e]) {
        const double r = relative_density[e];
        if (!any_rho) { rho_lo = rho_hi = r; any_rho = true; }
        rho_lo = std::min(rho_lo, r);
        rho_hi = std::max(rho_hi, r);
      }
  const double rho_span = rho_hi - rho_lo;
  if (synth_voxels && std::getenv("TOPOPT_ORGANIC_TRACE"))
    std::fprintf(stderr,
                 "[spacing] %zu voxel(s) in whole-synthesised wall(s) excluded from the "
                 "window statistics; they take the middle, %.3f mm\n",
                 synth_voxels, 0.5 * (cell_min_mm + cell_max_mm));

  // ★ `minimize_plastic`, AND IT MEANS WHAT HE ASKED IT TO MEAN: ON = THE LARGEST
  // CELLS POSSIBLE. Applied as an exponent on f, so BOTH ENDS OF THE WINDOW ARE
  // PRESERVED EXACTLY — the busiest voxel still gets cell_min, the quietest still gets
  // cell_max — and only the bulk moves. Same shape and the same two named constants
  // the aesthetic band position already uses (grading.hpp), so there is one vocabulary
  // for "which end of the range does the material sit at", not two.
  //   ON  (least plastic) -> exponent > 1 pushes f DOWN -> spacing toward cell_max.
  //   OFF (sturdy)        -> exponent < 1 pushes f UP   -> spacing toward cell_min.
  const double f_exponent =
      minimize_plastic ? kAestheticOpenExponent : kAestheticTightExponent;

  // The constant-bead law still stands when there is NO window (fixed/auto/fit cell
  // modes): see organic_default_strut_diameter_mm for why its default is not the
  // nozzle width.
  // ★ A STATED STRUT WIDTH IS THE WIDTH, EVERYWHERE (maintainer, 2026-09-10). It used
  // to be honoured only when there was NO cell window: under a swept window the bead was
  // re-derived per voxel from the mass coupling and the stated number was never read at
  // all. Measured on the M2 stand asking for 0.8 mm: the quiet wall came out at a 0.760
  // mm median and the loaded one at 1.209 -- a 59 % spread around a number the job had
  // stated exactly. The preview has always taken a stated width as a constant and turned
  // the bead grading off; core now does the same, so the two describe one object. The
  // CELL is still graded by the window -- only the strut thickness is pinned.
  const bool bead_is_stated = jg.organic_strut_width_mm > 0.0;
  const double t_fixed =
      bead_is_stated ? jg.organic_strut_width_mm
                     : organic_default_strut_diameter_mm(grid.spacing, 1.0, band_rho_max,
                                                         jg.min_extrudable_width_mm);
  oo.strut_diameter_mm = t_fixed;
  oo.bead_is_stated = bead_is_stated;
  oo.window_governed = have_window;
  std::vector<char> cand(n, 0);
  std::vector<double> spacing(n, 0.0);
  std::vector<double> bead(n, 0.0);
  std::size_t candidates = 0;
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    const double rho = relative_density[e];
    if (!(rho > 0.0)) continue;  // a zero density has no spacing; it is not lattice
    double d;
    if (have_window) {
      // ★ RULING H: the middle of the window, stated as a spacing and not as an f, so
      // the minimize_plastic exponent cannot pull a manufactured wall to one end.
      double f = rho_span > 0.0 ? (rho - rho_lo) / rho_span : 0.0;
      f = std::pow(std::min(1.0, std::max(0.0, f)), f_exponent);
      d = is_synth(e) ? 0.5 * (cell_min_mm + cell_max_mm)
                      : cell_max_mm - (cell_max_mm - cell_min_mm) * f;
      if (bead_is_stated) {
        // Asked for by name: no coupling, no floor, no grading. The number is the number.
        bead[e] = t_fixed;
      } else {
        // The bead the mass coupling asks for at this (rho, d) — floored, always, at the
        // stated minimum extrudable width. Printability is user input and outranks the
        // coupling; voxels the floor raised are counted by the tracer.
        bead[e] = organic_strut_diameter_for(d, rho);
        if (!(bead[e] > jg.min_extrudable_width_mm))
          bead[e] = jg.min_extrudable_width_mm;
      }
    } else {
      d = organic_spacing_for(rho, t_fixed);
      bead[e] = t_fixed;
    }
    if (!(d > 0.0)) continue;
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

  // ══════════════════════════════════════════════════════════════════════════════
  // ★★★ SHAPE-FIT GRADING — THE CELL ALSO FITS THE MEMBER, NOT ONLY THE STRESS ★★★
  //
  // ★ WHAT IT IS FOR, MEASURED. On the 40 mm cube the missing material is not spread
  // through the part, it sits in the SHELL: of 79 empty 4 mm cells, 68 were on the
  // outer layer and 3 were interior — 13.9 % of the shell against 0.6 % of the
  // interior, a 24x concentration. That is the truncated-boundary-cell signature the
  // conformal-lattice literature describes: tessellate at a size chosen without
  // reference to the wall, then TRIM, and the cells the trim catches are left as stubs
  // the prune removes. It also explains why aiming fill struts at those cells never
  // cleared them — the clip will not accept material there, so the fill re-fired on the
  // same ~58 cells every round without resolving one.
  //
  // ★★ TWO DRIVERS, BECAUSE THEY CATCH DIFFERENT DEFECTS. This was measured the hard
  // way: keyed on member width ALONE the pass was completely inert on the cube — the
  // span dump came back byte-identical with the flag on and off. The reason is that a
  // 40 mm cube's local member IS the whole 40 mm block, so W/N* is about 20 mm against
  // a 4-6 mm spacing and the cap never binds. Member width cannot see boundary
  // truncation at all, and an earlier revision of this block deleted the driver that
  // could, on the mistaken view that the two were the same law wearing two names.
  //
  //   W / N*      — "this MEMBER is too thin to hold the cell". Thin walls. This is
  //                 exactly `CellSizeMode::Fit`'s coarsest admissible cell, and using
  //                 the same measured width field and the same N* is deliberate: the
  //                 codebase has already paid for a second copy of a lattice law
  //                 drifting from the first (the app's strut law sat 1.4x off core's).
  //   2 * dist    — "this CELL straddles the surface". A cell of size d centred dist
  //                 inside the boundary is truncated when dist < d/2. Independent of
  //                 member thickness: it fires on a solid cube, where W/N* never does.
  //
  // The cap is the MIN of the two. Neither subsumes the other.
  // Fit derives the cell from the member it must fit into — S_want(W) = max(W/N*,
  // S_print_min), exactly N* cells across where the member can hold them — and that
  // mode has shipped for the doubled and stepped paths since 2026-08-05. Organic was
  // the algorithm WITHOUT it. Keying this on the same measured member-width field, and
  // on the same N*, is deliberate: an earlier iteration of this block keyed on distance
  // to the boundary instead, which is a different rule wearing the same name, and this
  // codebase has already paid for a second copy of a lattice law drifting from the
  // first (the app's strut law sat 1.4x off core's).
  //
  // ★ IT ONLY EVER SHRINKS. `std::min` against the stress-driven size means no voxel is
  // ever coarsened, so the cells-per-member floor cannot be breached from above; and the
  // tracer RAISES anything below its print and resolution floors (dsep clamping in
  // organic_lattice.cpp), so it cannot go below printable from below. A member too thin
  // to hold even the finest printable cell is left to those floors, which is the same
  // place Fit sends it — graded back towards solid rather than left as a hole.
  if (jg.organic_shape_fit) {
    // (organic runs only with octet: the job schema refuses it for any other type)
    const double n_star =
        lattice_cells_per_member_min(lattice_topology_from_id(jg.topology));
    // Distance in voxels to the nearest NON-candidate — the boundary of the region the
    // lattice may occupy, not the part outline, since a role or keep-clear narrows it.
    // Two-pass chamfer over the 6-neighbourhood; consumed as a length cap, not as a
    // geometric construction, so 6-connected is precise enough here.
    const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
    const long long BIG = 1LL << 30;
    std::vector<long long> dist(static_cast<std::size_t>(nx) * ny * nz, BIG);
    auto at = [&](int i, int j, int k) {
      return (static_cast<std::size_t>(k) * ny + j) * nx + i;
    };
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t e = at(i, j, k);
          if (!cand[e]) { dist[e] = 0; continue; }
          if (i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1)
            dist[e] = 1;   // on the grid face: the wall it sits in ends here
        }
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t e = at(i, j, k);
          if (i) dist[e] = std::min(dist[e], dist[at(i - 1, j, k)] + 1);
          if (j) dist[e] = std::min(dist[e], dist[at(i, j - 1, k)] + 1);
          if (k) dist[e] = std::min(dist[e], dist[at(i, j, k - 1)] + 1);
        }
    for (int k = nz - 1; k >= 0; --k)
      for (int j = ny - 1; j >= 0; --j)
        for (int i = nx - 1; i >= 0; --i) {
          const std::size_t e = at(i, j, k);
          if (i + 1 < nx) dist[e] = std::min(dist[e], dist[at(i + 1, j, k)] + 1);
          if (j + 1 < ny) dist[e] = std::min(dist[e], dist[at(i, j + 1, k)] + 1);
          if (k + 1 < nz) dist[e] = std::min(dist[e], dist[at(i, j, k + 1)] + 1);
        }
    std::size_t shrunk = 0;
    double worst_ratio = 1.0;

    // ══════════════════════════════════════════════════════════════════════════════
    // ★★★ SHAPE-FIT ONLY — THE CELL IS PURE GEOMETRY, THE STRESS FIELD IS NOT READ ★★★
    // The maintainer's call, and it is a different thing from the cap below rather
    // than a stronger version of it. The capped form still starts from the
    // stress-driven size and only shrinks it, so what the part looks like still
    // depends on where the load happened to fall. This form ignores the stress map
    // entirely and derives the cell from the SHAPE alone: biggest cells deepest
    // inside, grading down to the smallest at the faces, edges and corners.
    //
    // ★ IT IS NO LONGER AN AESTHETIC-ONLY MODE (maintainer's call). The cell is
    // still pure geometry and still does not answer to demand — that much is
    // unchanged. What changed is that the structural claim is no longer INFERRED from
    // how the cell was chosen: certify_organic_structural solves the finished struts
    // as frame elements and measures what they carry. A shape-driven lattice that
    // cannot carry the load is refused by that certificate, by name and by strut,
    // rather than by a rule about which knob produced the geometry.
    if (jg.organic_shape_fit_only && have_window) {
      long long dmax = 0;
      for (std::size_t e = 0; e < cand.size(); ++e)
        if (cand[e] && dist[e] < BIG) dmax = std::max(dmax, dist[e]);
      if (dmax > 0) {
        for (std::size_t e = 0; e < cand.size(); ++e) {
          if (!cand[e]) continue;
          // t = 0 at the boundary, 1 at the deepest interior point.
          const double t = std::min(1.0, static_cast<double>(dist[e]) /
                                             static_cast<double>(dmax));
          const double before = spacing[e];
          spacing[e] = cell_min_mm + (cell_max_mm - cell_min_mm) * t;
          if (spacing[e] < before) {
            ++shrunk;
            worst_ratio = std::min(worst_ratio, spacing[e] / before);
          }
          // ★ GRADE TO SHAPE IS GRADE TO SOLID (maintainer, 2026-09-05: "why aren't
          // they the same thing?"). Recomputing the bead from the SHRUNK cell at the
          // same relative density made the strut THINNER as the lattice approached
          // the outline -- measured: shape fit OFF certified at 18.37 against 12.53
          // ON, on the M2 stand -- and then a hard rim cliff to solid. A grade that
          // ends in solid must RAISE the relative density as the cell closes, so the
          // strut keeps the thickness the stress gave it while the cell shrinks
          // around it; the rim is then where that ramp reaches density one. The bead
          // stays as computed from the stress-driven cell; only the cell shrinks. A
          // STATED bead is not touched here at all -- not even by the printable floor.
          if (!bead_is_stated && !(bead[e] > jg.min_extrudable_width_mm))
            bead[e] = jg.min_extrudable_width_mm;
        }
        oo.shape_fit_voxels_shrunk = shrunk;
        oo.shape_fit_candidates = candidates;
        oo.shape_fit_min_ratio = shrunk ? worst_ratio : 1.0;
        if (std::getenv("TOPOPT_ORGANIC_TRACE"))
        std::fprintf(stderr,
                     "[shape-fit] ONLY-mode: cell %.2f mm at the faces to %.2f mm at "
                     "the core (depth %lld voxels), stress map NOT read\n",
                     cell_min_mm, cell_max_mm, dmax);
      }
    } else if (n_star > 0.0) {
      for (std::size_t e = 0; e < cand.size(); ++e) {
        if (!cand[e]) continue;
        const double w = width[e];
        // Fit's coarsest admissible cell. An unmeasured or "thicker than we measured"
        // width bounds nothing from above, which is the honest reading of the sentinel.
        const double cap_member = (w > 0.0 && std::isfinite(w))
                                      ? w / n_star
                                      : std::numeric_limits<double>::infinity();
        const double cap_boundary = 2.0 * static_cast<double>(dist[e]) * grid.spacing;
        double cap = std::min(cap_member, cap_boundary);
        // ★★ THE LOWER LIMIT. Shape fit GRADES within the range the job declared; it
        // does not get to leave it. `cell_min_mm` is the user's own stated smallest
        // cell, and printability is user input — the same rule that already makes the
        // bead floor outrank the mass coupling. Without this the boundary cap reaches
        // two voxels at the outermost shell, every shell voxel lands on the tracer's
        // resolution floor, and the "grade" is not a grade at all but a solid skin.
        const double floor_mm = have_window
                                    ? cell_min_mm
                                    : kOrganicShapeFitMinCellRatio * spacing[e];
        if (cap < floor_mm) cap = floor_mm;
        if (!(cap > 0.0) || !(cap < spacing[e])) continue;
        const double before = spacing[e];
        spacing[e] = cap;
        ++shrunk;
        worst_ratio = std::min(worst_ratio, cap / before);
        // ★ THE BEAD MUST FOLLOW THE SPACING. The mass coupling ties strut diameter to
        // (rho, d); leaving the bead at the value computed for the OLD d would emit a
        // strut sized for a cell it is no longer in — the same class of defect as a
        // census measuring one representation while the pass measures another.
        if (have_window) {
          // ★ GRADE TO SHAPE IS GRADE TO SOLID (maintainer, 2026-09-05: "why aren't
          // they the same thing?"). Recomputing the bead from the SHRUNK cell at the
          // same relative density made the strut THINNER as the lattice approached
          // the outline -- measured: shape fit OFF certified at 18.37 against 12.53
          // ON, on the M2 stand -- and then a hard rim cliff to solid. A grade that
          // ends in solid must RAISE the relative density as the cell closes, so the
          // strut keeps the thickness the stress gave it while the cell shrinks
          // around it; the rim is then where that ramp reaches density one. The bead
          // stays as computed from the stress-driven cell; only the cell shrinks. A
          // STATED bead is not touched here at all -- not even by the printable floor.
          if (!bead_is_stated && !(bead[e] > jg.min_extrudable_width_mm))
            bead[e] = jg.min_extrudable_width_mm;
        }
      }
    }
    oo.shape_fit_voxels_shrunk = shrunk;
    oo.shape_fit_candidates = candidates;
    oo.shape_fit_min_ratio = shrunk ? worst_ratio : 1.0;
    if (std::getenv("TOPOPT_ORGANIC_TRACE"))
      std::fprintf(stderr,
                 "[shape-fit] shrunk %zu of %zu candidates, smallest cell %.3fx the "
                 "stress-driven size (floor %s)\n",
                 shrunk, candidates, shrunk ? worst_ratio : 1.0,
                 have_window ? "cell_min_mm" : "ratio");
  }

  OrganicParams op;
  op.build_dir = build_dir;
  op.overhang_angle_deg = jg.organic_overhang_angle_deg;
  op.transfer_ties = jg.organic_transfer_ties;
  op.tie_swirl = jg.organic_tie_swirl;
  // ★ A curve end that ran out of region is an ANCHOR only if a shell is written for
  // it to land on. `outer_finish: "skin"` drops the shell, and then the same end is a
  // cantilever into air — which is what the maintainer found at the face of a bare
  // cube. run_job knows which file it is writing; the tracer does not.
  // ★ ...UNLESS THE BOUNDARY IS SOLID ANYWAY (maintainer, 2026-09-05: "there should be
  // SOLID chamfers all the way around it"). A pocket cut into a wall has the part's
  // own solid beyond the region on every side but the open face; a curve end that
  // runs out of region there lands on that solid and is held, shell or no shell.
  // The bare-coupon rule above was written for a region with NOTHING beyond it.
  // Measure it: of the candidate voxels on the region's boundary, how many have a
  // solid non-candidate neighbour. Backed on more than half -> anchor.
  double boundary_solid_fraction = 0.0;
  {
    std::size_t on_boundary = 0, backed = 0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (!lattice_mask[e]) continue;
          // ★ MEASURED 2026-09-05 on the M2 stand: counting every boundary voxel put the
          // pocket's OPEN FACE -- 59 % of the boundary, air by definition -- in the
          // denominator, and a pocket with a solid rim on every side wall read "40.7 %
          // backed", anchors OFF. A boundary voxel whose only non-lattice neighbours
          // are AIR is the open face, and it says nothing about whether the walls are
          // solid; it is left out of the count. Side walls and floor decide.
          bool edge = false, solid_nb = false;
          const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0}, dk[6] = {0, 0, 0, 0, 1, -1};
          for (int d = 0; d < 6; ++d) {
            const int i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d];
            if (i2 < 0 || j2 < 0 || k2 < 0 || i2 >= grid.nx || j2 >= grid.ny || k2 >= grid.nz) continue;
            const std::size_t e2 = grid.index(i2, j2, k2);
            if (lattice_mask[e2]) continue;
            if (density[e2] > printed_iso) { edge = true; solid_nb = true; }
            else if (!edge) { /* air: the open face, not counted */ }
          }
          // a voxel touching only air is not on a wall; one touching solid is, and is backed
          if (edge) { ++on_boundary; if (solid_nb) ++backed; }
          else {
            // does it touch a non-lattice voxel at all (air)? then it is on the open face
            // and is deliberately not counted
          }
        }
    boundary_solid_fraction = on_boundary ? double(backed) / double(on_boundary) : 0.0;
  }
  op.anchor_at_region_boundary = shell_is_written || boundary_solid_fraction > 0.5;
  if (std::getenv("TOPOPT_ORGANIC_TRACE"))
    std::fprintf(stderr, "[anchor] region boundary backed by solid on %.1f%% of its voxels -> anchors %s (shell %s)\n",
                 100.0 * boundary_solid_fraction, op.anchor_at_region_boundary ? "ON" : "OFF",
                 shell_is_written ? "written" : "not written");
  // ★ THE NET-SKIN IS FOR THE BARE LATTICE, AND ONLY FOR IT. With a shell written,
  // every clipped end lands ON that shell and is held; with `outer_finish: "skin"`
  // there is nothing there and the landings are the hanging struts Aremu et al.
  // describe. The reach is ONE SEPARATION — the surface's own spacing — so a join is
  // never longer than the gap it is closing.
  oo.net_skin_wanted = !shell_is_written;
  op.min_extrudable_width_mm = jg.min_extrudable_width_mm;
  op.strut_diameter_mm = t_fixed;
  op.strut_diameter_field = &bead;
  op.bead_is_stated = bead_is_stated;
  // ★★ THE VDI FLOOR OUTRANKS THE LIBRARY BAND. The library's floor (0.0496; 0.05047 on
  // octet's legs-only rows before ruling 2026-11-02 (c)) is a
  // CERTIFIABILITY limit — the lightest lattice the tensor library can describe. It
  // says nothing about whether the bar can be BUILT, and at that density the slenderness
  // is l/D = 6.8 against the standard's 5. Printability is user input and outranks a
  // modelling limit, so the floor is the larger of the two.
  op.rho_min = std::max(band_rho_min, kOrganicVdiDensityFloor);
  op.rho_max = band_rho_max;
  op.defer_bead_calibration = jg.organic_calibrate_on_shipped && !bead_is_stated;
  oo.rho_min_used = op.rho_min;
  oo.rho_max_used = op.rho_max;
  const double t0 = wall_seconds();
  op.layer_hint_mm = jg.organic_growth ? layer_height_mm : 0.0;
  // ★★ GROW OR TRACE. The growth path is a different ARCHITECTURE, not a different
  // parameter: it refuses to lay material whose underside is unsupported, so the six
  // repair passes have nothing left to repair. Off by default — the traced path stays
  // byte-identical until a job asks.
  oo.growth_ran = jg.organic_growth;
  oo.lat = jg.organic_growth
               ? grow_organic_lattice(grid, cand, stress_tensor, spacing, &width, op,
                                      &oo.growth)
               : trace_organic_lattice(grid, cand, stress_tensor, spacing, &width, op);
  oo.trace_seconds = wall_seconds() - t0;
  // ★ THE PART'S OWN SOLID IS SUPPORT. Hand the emission stage the voxels that are
  // solid material OUTSIDE the lattice region, so a column standing on the arch
  // underside, a wall top, or any solid floor above the build plate is not an island
  // at its own base. See OrganicLattice::part_solid for the measurement.
  oo.lat.part_solid.assign(n, 0);
  for (std::size_t e = 0; e < n; ++e)
    if (!lattice_mask[e] && density[e] > printed_iso) oo.lat.part_solid[e] = 1;
  if (std::getenv("TOPOPT_ORGANIC_TRACE")) {
    std::size_t ns = 0; for (char c : oo.lat.part_solid) ns += c ? 1 : 0;
    std::fprintf(stderr, "[part-solid] %zu solid voxels outside the region (of %zu), iso %.4f\n", ns, n, printed_iso);
  }
  // ★ THE PROBE STOPS HERE: the curves and the part's solid are what it measures.
  if (probe_only) { oo.ran = true; return oo; }
  if (oo.net_skin_wanted) {
    oo.lat.net_skin_reach_mm = oo.lat.report.achieved_spacing_median_mm;
    oo.lat.net_skin_finish =
        jg.organic_boundary_finish == "clean" ? OrganicLattice::Finish::Clean
        : jg.organic_boundary_finish == "rim" ? OrganicLattice::Finish::Rim
                                              : OrganicLattice::Finish::Skin;
  }
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
  // ★ THE CALIBRATION IS NOW VISIBLE. It reached no receipt and no log at all, so for
  // every organic run to date there was no way to see what factor had been applied to
  // every strut in the part, nor what volume it was aiming at. Printed on the same terms
  // as [synthetic] and [dc]: the target the grading law asked for, the volume the lattice
  // really occupies, and how much of the naive sum of its parts was double-counted
  // overlap -- which is the error the old model was solving against.
  if (r.bead_calibration_skipped_stated) {
    std::fprintf(stderr,
                 "[bead] %.4f mm stated by the job: no calibration, no coupling, "
                 "no floor -- every strut is that diameter\n", r.strut_diameter_mm);
  } else if (r.bead_calibration_iterations > 0) {
    std::fprintf(stderr,
                 "[bead] calibration x%.4f in %d step(s)%s: target %.1f mm3, union "
                 "%.1f mm3 (%+.2f %%), naive sum %.1f mm3 (%.1f %% of it overlap); "
                 "measured on %zu span(s), %.1f mm of centreline, median dia %.4f mm "
                 "BEFORE the factor\n",
                 r.bead_calibration, r.bead_calibration_iterations,
                 r.bead_calibration_floored ? " (FLOORED at the extrudable width)" : "",
                 r.bead_calibration_target_mm3, r.bead_calibration_union_mm3,
                 r.bead_calibration_target_mm3 > 0.0
                     ? 100.0 * (r.bead_calibration_union_mm3 - r.bead_calibration_target_mm3) /
                           r.bead_calibration_target_mm3
                     : 0.0,
                 r.bead_calibration_naive_mm3,
                 100.0 * r.bead_calibration_overlap_fraction,
                 r.bead_calibration_spans, r.bead_calibration_length_mm,
                 r.bead_calibration_median_dia_mm);
  }
  gi.organic_trace_seconds = oo.trace_seconds;
  copy_growth_stats(gi, oo.growth, oo.growth_ran);
  gi.organic_candidate_voxels = static_cast<long long>(r.candidate_voxels);
  gi.organic_degenerate_voxels = static_cast<long long>(r.degenerate_voxels);
  gi.organic_degenerate_fraction = r.degenerate_fraction;
  gi.organic_max_frame_swap_fraction = r.max_frame_swap_fraction;
  gi.organic_curves_traced = static_cast<long long>(r.curves_traced);
  gi.organic_curves_kept = static_cast<long long>(r.curves_kept);
  gi.organic_curves_thinned = static_cast<long long>(r.curves_thinned);
  gi.organic_curves_too_short = static_cast<long long>(r.curves_too_short);
  gi.organic_curves_kept_for_coverage =
      static_cast<long long>(r.curves_kept_for_coverage);
  gi.organic_dangling_ends_trimmed = static_cast<long long>(r.dangling_ends_trimmed);
  gi.organic_curves_dropped_dangling =
      static_cast<long long>(r.curves_dropped_dangling);
  gi.organic_dangling_length_removed_mm = r.dangling_length_removed_mm;
  gi.organic_dangling_rounds = r.dangling_rounds;
  gi.organic_total_curve_length_mm = r.total_curve_length_mm;
  gi.organic_curves_per_family.assign(r.curves_per_family, r.curves_per_family + 3);
  gi.organic_curve_length_per_family_mm.assign(
      r.curve_length_per_family_mm, r.curve_length_per_family_mm + 3);
  gi.organic_stop_left_region = r.stop_left_region;
  gi.organic_stop_hit_d_test = r.stop_hit_d_test;
  gi.organic_stop_no_direction = r.stop_no_direction;
  gi.organic_stop_step_budget = r.stop_step_budget;
  gi.organic_stop_turned_too_far = r.stop_turned_too_far;
  gi.organic_stop_self_revisit = r.stop_self_revisit;
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
  gi.organic_solid_components = static_cast<long long>(r.solid_components);
  gi.organic_solid_largest_fraction = r.solid_largest_component_length_fraction;
  gi.organic_solid_stranded_length_mm = r.solid_stranded_length_mm;
  gi.organic_solid_segments = static_cast<long long>(r.solid_segments);
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
  // ★ THE BLANKET REFUSAL IS GONE, AND WHAT REPLACED IT IS NARROWER, NOT ABSENT.
  // The refusal above this line existed for one stated reason: organic traced struts
  // follow the principal stress directions, so the lattice is anisotropic by
  // construction, and the only tensor this codebase owns is the CUBIC one measured on
  // the octet cell. A structural density would have been certified against a material
  // this lattice is not.
  //
  // That reason is answered — not argued away — by certify_organic_structural: it does
  // not consult the homogenised tensor AT ALL. It solves the strut network directly as
  // Timoshenko frame elements, so the anisotropy is not approximated, it is simply the
  // geometry being solved. The refusal therefore now keys on whether that instrument
  // was ASKED FOR, and refuses a structural organic job that did not ask for it.
  //
  // job.cpp enforces the same pairing at PARSE time; this is the second lock, so a
  // caller that reaches lattice_one_variant without going through the schema cannot
  // obtain a structural organic density with nothing behind it.
  if (jg.organic_structural_certification == "beam_network") return;
  throw JobError(
      "organic under \"intent\": \"structural\" requires "
      "\"organic_structural_certification\": \"beam_network\" (this job says " +
      (jg.organic_structural_certification.empty()
           ? std::string("nothing")
           : ("\"" + jg.organic_structural_certification + "\"")) +
      "). Traced struts follow the principal stress directions, so the lattice is "
      "anisotropic by construction and the homogenised CUBIC tensor does not describe "
      "it. The beam-network certificate does not use that tensor: it solves the struts "
      "themselves as frame elements. A structural organic density is therefore "
      "available, but only with that instrument named explicitly, so that no run "
      "carries a structural density certified against nothing.");
}

// ── ★ AND ANY-STEP STEPPED IS REFUSED ON THE SAME TERMS, FOR A DIFFERENT REASON ──
// (brief of 2026-09-17 §3.) Organic is refused the cubic tensor because its struts follow
// the principal directions. Stepped's struts are octet and axis-aligned, so that argument
// does not apply -- but the tensor assumes SHARED NODES, and any-step seams break exactly
// that: a 9's face centre lands mid-strut on an 8's face, so neighbouring families share
// no nodes at all. A tensor certificate would over-claim at every seam, and there are
// thousands of them. The beam network has no such assumption: it welds ON CONTACT, so a
// strut ending on the middle of another is fused precisely as the print fuses it and the
// seam is just geometry being solved.
//
// So the tensor certificate is not offered for any-step Stepped AT ALL -- not defaulted,
// not warned about. A stepped job that packs a plan and asks for a structural density
// must name the instrument.
void refuse_stepped_structural(LatticeAlgorithm alg, const JobGrading& jg,
                               const JobLattice& jl) {
  if (alg != LatticeAlgorithm::Stepped) return;
  // The same test organic's gate uses, and deliberately not `intent == "structural"`: an
  // UNSTATED intent must not be the one reading that reaches a tensor certificate.
  if (jg.intent == "aesthetic") return;
  if (jl.stepped_cells.empty()) return;      // legacy one-cell-per-region: unchanged
  if (jg.organic_structural_certification == "beam_network") return;
  throw JobError(
      "any-step \"stepped\" under \"intent\": \"structural\" requires "
      "\"structural_certification\": \"beam_network\" (this job says " +
      (jg.organic_structural_certification.empty()
           ? std::string("nothing")
           : ("\"" + jg.organic_structural_certification + "\"")) +
      "). This plan places " + std::to_string(jl.stepped_cells.size()) +
      " cells of several families, and cells of DIFFERENT families share no nodes -- a "
      "9's face centre lands mid-strut on an 8's face. The homogenised cubic tensor "
      "assumes shared nodes, so it would over-claim at every seam, and a plan like this "
      "is nothing but seams. The beam-network certificate makes no such assumption: it "
      "solves the struts as frame elements and welds on contact, exactly as the print "
      "fuses them. The tensor certificate is therefore not offered for any-step Stepped "
      "at all.");
}

// Resolve the job's algorithm; an ABSENT key is "doubled", which is what keeps every
// existing job byte-identical (§4d). An unknown one is refused, never defaulted.
// The one graded lattice a design box still refuses (lattice_variant_job, run_job).
const char* const kOrganicDesignBoxRefusal =
    "The organic lattice can't be used with a design box yet: it lays its struts before "
    "the material the design box added is kept solid, so it could put struts where the "
    "certificate counts solid. Use the doubled or stepped lattice with the design box, "
    "or the organic lattice without one.";

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
// ── ★ THE SOLID RIM: grade to solid at the outline (JobGrading::organic_solid_rim_mm)
// Seeds are lattice voxels with a solid, non-lattice 6-neighbour in a direction that
// is IN the region's face plane (|dir . normal| < 0.5): the pocket's side walls.
// The pocket floor (along the normal) and the open face are not seeds. From the
// seeds a 6-connected flood walks inward through lattice voxels up to `rim_mm`
// (voxel steps x spacing); everything it reaches leaves the mask and prints solid.
// Returns the voxels turned solid.
// ★ `density` and `printed_iso` USED TO BE ARGUMENTS. They were only ever read by the
// seed's "the neighbour must be solid" test, which is the bug fixed below; with the seed
// keyed on the lattice mask alone the rim no longer consults the density field at all.
// ★★ IT RETURNS THE BAND; IT NO LONGER DELETES IT (maintainer, 2026-09-18, ruling G).
// Clearing the band from the mask before the tracer ran did two things at once: it made
// the band print solid, which is the point, AND it took the band out of the tracer's
// candidates, which was not. The preview keeps the band as candidate, so its curves run
// THROUGH the band and weld into the solid; the run cut every strut back at the band's
// inner face. That was the one geometric divergence between the two in source. The caller
// now traces with the band IN and turns it solid afterwards, so the struts end up embedded
// in the solid exactly as the picture shows.
// ★ (d), ruling 11-06: `unowned_from_surface` seeds a lattice voxel NO region owns
// (id 0: a lattice with no regions, or lattice.whole_part outside its includes) from any
// non-lattice 6-neighbour. It has no face, so no direction is the open one: its outline
// is wherever the lattice ends, the part's own surface included. Off (the default, and
// the organic rim's call) such a voxel seeds nothing, as before, and a shape grade on a
// lattice with no regions turned 0 voxels solid.
static std::vector<char> organic_solid_rim_band(const VoxelGrid& grid,
                                                const std::vector<char>& mask,
                                                const std::vector<int>& region_ids,
                                                const std::vector<Vec3>& region_normals,
                                                double rim_mm,
                                                bool unowned_from_surface = false) {
  const std::size_t n = grid.voxel_count();
  std::vector<char> band(n, 0);
  if (!(rim_mm > 0.0) || mask.size() != n || region_ids.size() != n) return band;
  const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0}, dk[6] = {0, 0, 0, 0, 1, -1};
  std::vector<int> dist(n, -1);
  std::vector<std::size_t> q;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!mask[e]) continue;
        const int rid = region_ids[e];
        const bool unowned = rid <= 0 && unowned_from_surface;
        if (!unowned && (rid <= 0 || static_cast<std::size_t>(rid) > region_normals.size()))
          continue;
        const Vec3 nrm = unowned ? Vec3{0.0, 0.0, 0.0}  // no face: every direction seeds
                                 : region_normals[static_cast<std::size_t>(rid - 1)];
        const double nl = std::sqrt(nrm.x * nrm.x + nrm.y * nrm.y + nrm.z * nrm.z);
        for (int d = 0; d < 6; ++d) {
          const double dot = nl > 0.0 ? (di[d] * nrm.x + dj[d] * nrm.y + dk[d] * nrm.z) / nl : 0.0;
          if (std::fabs(dot) >= 0.5) continue;   // along the normal: the open faces
          const int i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d];
          const bool outside_grid =
              i2 < 0 || j2 < 0 || k2 < 0 || i2 >= grid.nx || j2 >= grid.ny || k2 >= grid.nz;
          // ★ THE OUTLINE ENDS WHEREVER THE LATTICE ENDS -- NOT ONLY AGAINST MATERIAL.
          // (maintainer, 2026-09-08.) This used to require the neighbour to be SOLID
          // (`density[e2] > printed_iso`), which works for a pocket cut into a wall and
          // silently refuses every edge where the region runs out at the PART'S OWN
          // SURFACE, because the neighbour there is air. On a face prism asked for with
          // only its front and back open, that is precisely the top and bottom edges:
          // they got no band at all, so the "outline" was three-sided at best. The seed
          // now asks only whether the neighbour is outside the lattice, with the face
          // normal as the single exemption so the open faces stay open. Air off the end
          // of the grid counts too -- it is the same situation.
          if (!outside_grid && mask[grid.index(i2, j2, k2)]) continue;   // still lattice
          dist[e] = 0; q.push_back(e); break;
        }
      }
  const int max_steps = static_cast<int>(std::floor(rim_mm / grid.spacing + 1e-9));
  for (std::size_t head = 0; head < q.size(); ++head) {
    const std::size_t e = q[head];
    if (dist[e] >= max_steps) continue;
    const int i = static_cast<int>(e % static_cast<std::size_t>(grid.nx));
    const int j = static_cast<int>((e / static_cast<std::size_t>(grid.nx)) % static_cast<std::size_t>(grid.ny));
    const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * static_cast<std::size_t>(grid.ny)));
    for (int d = 0; d < 6; ++d) {
      const int i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d];
      if (i2 < 0 || j2 < 0 || k2 < 0 || i2 >= grid.nx || j2 >= grid.ny || k2 >= grid.nz) continue;
      const std::size_t e2 = grid.index(i2, j2, k2);
      if (!mask[e2] || dist[e2] >= 0) continue;
      dist[e2] = dist[e] + 1; q.push_back(e2);
    }
  }
  for (std::size_t e : q) band[e] = 1;
  return band;
}

// Clear a band out of a mask, and say how many voxels it took. Separated from the walk so
// the caller chooses WHEN the band stops being lattice -- which for organic is after the
// tracer has run through it, not before.
static std::size_t clear_band_from_mask(std::vector<char>& mask, const std::vector<char>& band) {
  std::size_t turned = 0;
  for (std::size_t e = 0; e < mask.size() && e < band.size(); ++e)
    if (band[e] && mask[e]) { mask[e] = 0; ++turned; }
  return turned;
}

// ★ THE SHAPE-GRADE BAND'S DISTANCE (ruling 2): per lattice voxel, mm from the lattice's
// outline -- seeded exactly as organic_solid_rim_band seeds its walk (a region's in-plane
// side walls; with `unowned_from_surface`, every edge of a voxel no region owns), the
// seed voxel's centre half a voxel in -- then a 26-neighbour chamfer walk through the
// lattice (steps h, h*sqrt2, h*sqrt3). -1 off the lattice or out of reach of any seed.
static std::vector<double> lattice_outline_distance_mm(const VoxelGrid& grid,
                                                       const std::vector<char>& mask,
                                                       const std::vector<int>& region_ids,
                                                       const std::vector<Vec3>& region_normals,
                                                       bool unowned_from_surface) {
  const std::size_t n = grid.voxel_count();
  std::vector<double> dist(n, -1.0);
  if (mask.size() != n || region_ids.size() != n) return dist;
  // The seeds: one voxel-step walk of organic_solid_rim_band is its seed layer.
  const std::vector<char> seeds =
      organic_solid_rim_band(grid, mask, region_ids, region_normals, 0.5 * grid.spacing,
                             unowned_from_surface);
  const double h = grid.spacing;
  using Item = std::pair<double, std::size_t>;
  std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pq;
  for (std::size_t e = 0; e < n; ++e)
    if (seeds[e]) {
      dist[e] = 0.5 * h;
      pq.push({dist[e], e});
    }
  while (!pq.empty()) {
    const auto [d, e] = pq.top();
    pq.pop();
    if (d > dist[e]) continue;
    const int i = static_cast<int>(e % static_cast<std::size_t>(grid.nx));
    const int j = static_cast<int>((e / static_cast<std::size_t>(grid.nx)) % static_cast<std::size_t>(grid.ny));
    const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) * static_cast<std::size_t>(grid.ny)));
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          if (!di && !dj && !dk) continue;
          const int i2 = i + di, j2 = j + dj, k2 = k + dk;
          if (i2 < 0 || j2 < 0 || k2 < 0 || i2 >= grid.nx || j2 >= grid.ny || k2 >= grid.nz) continue;
          const std::size_t e2 = grid.index(i2, j2, k2);
          if (!mask[e2]) continue;
          const double nd = d + h * std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk));
          if (dist[e2] < 0.0 || nd < dist[e2] - 1e-12) {
            dist[e2] = nd;
            pq.push({nd, e2});
          }
        }
  }
  return dist;
}

// quotes, backslashes and newlines out of a string headed into a JSON literal
static std::string json_safe(std::string t) {
  for (char& c : t) if (c == '"' || c == '\\' || c == '\n' || c == '\r') c = c == '"' ? '\'' : ' ';
  return t;
}

// ── ★ E3: THE INCLUDE REGIONS, IN DECLARED ORDER, AND THEIR OWN GRADING ───────
// The includes of `lattice.regions`, or lattice.whole_part's regions when the job
// lattices the whole part: the same list, in the same order, that numbers the owner map.
std::vector<JobLatticeRegion> lattice_include_regions(const JobDescription& job) {
  if (!job.lattice.whole_part_includes.empty()) return job.lattice.whole_part_includes;
  std::vector<JobLatticeRegion> out;
  for (const JobLatticeRegion& r : job.lattice.regions)
    if (r.role == "include") out.push_back(r);
  return out;
}
// One override per region; EMPTY when no region states a grading of its own, so the
// grading law is handed nothing and runs exactly as before. (A region that states only
// a shape grade gets the part's band and curve, which grade exactly as the part's.)
std::vector<GradingRegionOverride> lattice_region_overrides(
    const std::vector<JobLatticeRegion>& regions) {
  std::vector<GradingRegionOverride> out(regions.size());
  bool any = false;
  for (std::size_t i = 0; i < regions.size(); ++i) {
    const JobLatticeRegion& r = regions[i];
    GradingRegionOverride& o = out[i];
    o.rho_min = r.rho_min;
    o.rho_max = r.rho_max;
    o.demand_exponent = r.demand_exponent;
    o.flat = r.grading == "off" || r.grading == "shape";
    o.flat_rho = o.flat ? r.relative_density : 0.0;
    o.cell_min_mm = r.cell_min_mm;  // ★ E3: its own cell window
    o.cell_max_mm = r.cell_max_mm;
    // A region's own shape grade needs the owner map too, so it arms the table.
    if (r.rho_max > 0.0 || r.demand_exponent > 0.0 || o.flat || r.shape_grade >= 0 ||
        r.shape_grade_band_mm >= 0.0 || r.cell_min_mm > 0.0 || r.cell_max_mm > 0.0 ||
        r.shape_grade_strength >= -1.0 || !r.outer_finish.empty() || !r.skin.empty())
      any = true;
  }
  if (!any) out.clear();
  return out;
}

// One lattice pass. `fixed_search` (null on the first pass) carries each "off" region's
// one density chosen by lattice_one_variant's shipped search, laid as is, unsearched.
LatticeVariantOutcome lattice_one_variant_pass(
    const MinimizePlasticVariant& v, const JobDescription& job,
    const VoxelGrid& part_grid, const SolvedDesignDomain& domain,
    const MinimizePlasticOptions& options, const Material& material,
    const std::vector<ClearanceGeometry>& lattice_kos,
    const LatticeRoleRegions& lattice_roles, const std::string& out_dir,
    const std::vector<LatticeRegionGraded>* fixed_search,
    // ★ (A) the surface a rim rides when the part ITSELF is latticed: its own mesh. Null:
    // the design's exported surface, made from `cad` (CAD-projected); with neither, the
    // design's shell (v3.mesh).
    const TriangleMesh* part_surface = nullptr, const StepModel* cad = nullptr) {
  // FIRST STATEMENT IN THE BODY, so every solve below is covered and the previous
  // enable states are restored however this function returns (including by throw).
  const ScopedLadderSolverIsolation solver_isolation;
  // ★ THE JOB'S TOPOLOGY FOR THIS VARIANT, RESOLVED ONCE
  // (task 2026-09-28-lattice-types-core). Every strut size below -- the receipt's,
  // the emitters' radius fields, the forecast -- read octet's measured diameter
  // table directly. They now read the JOB's type. Captured BY VALUE into each
  // radius lambda beside the other scalars, never by reference: those lambdas are
  // stored in the emit params and a reference to a local here is a lifetime the
  // next refactor can break silently.
  const LatticeTopology lat_topo =
      lattice_topology_from_id(job.grading.topology);
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
  refuse_stepped_structural(R.algorithm, job.grading, job.lattice);
  const bool roles_present = !job.lattice.regions.empty();
  // ★ E2.1: the scenarios this lattice uses, and the field it is GRADED from: per
  // voxel the worst von Mises over them (lattice_grading_stress). A job without
  // scenarios grades from v.von_mises_field itself, by reference.
  const std::vector<char> lat_scen_on = lattice_scenario_flags(job, domain.scenarios);
  std::vector<double> vm_grade_storage;
  const std::vector<double>& vm_grade =
      lattice_grading_stress(v, lat_scen_on, vm_grade_storage, &R.grade_source);
  // ★ E3: each include region's own grading, and per voxel the region that owns it
  // (ruling 4's owner over the includes, or over lattice.whole_part's regions). Empty
  // when no region states any: the part's grading everywhere, byte for byte.
  const std::vector<JobLatticeRegion> e3_jobs = lattice_include_regions(job);
  const std::vector<ClearanceGeometry>& e3_regions =
      lattice_roles.includes.empty() ? lattice_roles.carriers : lattice_roles.includes;
  const std::vector<GradingRegionOverride> e3_overrides = lattice_region_overrides(e3_jobs);
  std::vector<int> e3_owner;
  // ★ the shape-grade band's per-voxel inputs (grade_lattice reads them by pointer)
  std::vector<double> band_distance, band_mm, band_amount;

  // ── Stage 4: the grading law runs FIRST, on THIS variant's own final
  // certification-recovery von Mises field (H4a — the run's own field, fresh:
  // v.von_mises_field is produced by the recovery solve on the CONVERGED
  // design of this rung, never an earlier iteration or another run). Its
  // candidate set is the role-aware membership — the SAME membership tests the
  // shared boundary predicate exposes, evaluated on a boundary view carrying
  // only the membership primitives (the cell size, which the law itself
  // chooses, plays no part in membership).
  GradedField& gf = R.gf;
  // ★ what the certificate WOULD have been handed on an organic run: the traced
  // network's material. Kept so the re-measure after the export can print BOTH, and the
  // change of basis is auditable rather than silent.
  double organic_traced_material_mm3 = 0.0;
  double cell = job.lattice.cell_mm;
  // Which DECLARED include region owns each candidate voxel — built inside the graded
  // block below and kept here because STEPPED derives one cell PER REGION and so needs
  // the same membership the law used, not a second reconstruction of it.
  std::vector<int> region_ids_for_stepped;
  // ── ★ K3: THE PLAN IS READ BEFORE CORE'S OWN LAW DECIDES ANYTHING ───────────
  // (Reviewer's ruling: on a plan job the plan IS the design.) This work used to sit
  // AFTER the law's mask, the certification mask and the empty-mask refusal, so core's
  // own grading gated the plan: on 3418E167 the law left nothing and the run refused
  // before it had ever looked at the plan. My own D10/E3 commit introduced that ordering
  // while closing a false acceptance, and under the standing rule it is the wrong way
  // round for a plan job.
  //
  // It can move because K1 severed the dependency: the plan's frame now comes from the
  // job alone (the sent base), where it used to come from `R.stepped.cells` and so could
  // not be built until the law had run. Nothing below needs the solve beyond the grid.
  std::vector<SteppedCellGroup> plan_groups;
  std::vector<SteppedPlanRegion> plan_regions;
  SteppedPlanCheck plan_chk;
  std::vector<char> plan_mask;            // the plan's latticed voxels, K3's own mask
  if (!job.lattice.stepped_cells.empty()) {
    // ── ★ K1: THE BASE PER REGION IS THE APP'S, FOR BOTH MENUS ──────────────────
    // (#354's map of 2026-10-08, reviewer's ruling of the same day.) This had TWO paths.
    // Doubled took the region's LARGEST SENT CELL -- the app's own rule. Any-step took
    // `R.stepped.cells`, the cell core's stepped step derives from that region's FEA
    // density and member width. So every app-sent any-step plan was validated against a
    // number the app never used, and #354 expected "not on that region's menu" on every
    // project.
    //
    // There is now ONE path, and it is the app's: the largest cell the region placed IS
    // the top of the ladder it halved, so the ladder is checked against the list's own
    // evidence and core still validates rather than re-plans. A region that placed only
    // fine cells simply has a lower top, and its cells still have to be steps of it.
    //
    // AND IT SEVERS A DEPENDENCY K3 NEEDS. Built from `R.stepped.cells`, the plan could
    // not be read until core's grading had produced a mask and the stepped step had run
    // on it -- which is exactly the gating K3 removes. Built from the job, the plan's
    // frame depends on nothing but the job.
    {
      // ★ K1 CORRECTED (reviewer, 2026-10-09). An earlier cut INFERRED the base as the
      // region's largest sent cell. That is a silent substitute: a region need not contain
      // a base-size cell at all. Measured on 3418E167's Aesthetic Stepped plan, region 1
      // sends only 3.5 mm and 4.6667 mm cells while the app's base is 7 mm -- so the
      // inference guessed 4.6667 and every menu, alignment and grouping check below ran
      // against a ladder the app never used. (It also put the sizes a hair off: 3/4 of a
      // rounded 4.6667 is 3.500025, not the 3.5 the plan sends.)
      //
      // The base now travels on the wire, per region, and a region the plan places cells
      // in MUST carry it. Refused by name otherwise -- production sends no plans yet, so
      // nothing in the field breaks, and a plan without it would otherwise be checked
      // against a guess.
      std::set<int> planned_regions;
      for (const SteppedCell& c : job.lattice.stepped_cells)
        planned_regions.insert(c.region_id);
      int include_index = 0;
      for (const JobLatticeRegion& jr : job.lattice.regions) {
        if (jr.role != "include") continue;
        ++include_index;
        SteppedPlanRegion pr;
        pr.region_id = include_index;
        if (planned_regions.count(include_index) && !(jr.plan_base_cell_mm > 0.0))
          throw JobError(
              "lattice region " + std::to_string(include_index) + " (face " +
              std::to_string(jr.face_id) +
              ") carries " + std::to_string(std::count_if(
                                 job.lattice.stepped_cells.begin(),
                                 job.lattice.stepped_cells.end(),
                                 [&](const SteppedCell& c) {
                                   return c.region_id == include_index;
                                 })) +
              " planned cell(s) but no \"plan_base_cell_mm\". That is the slot size the "
              "ladder was built on, and core cannot infer it: a region need not contain a "
              "base-size cell, so the largest cell sent is a guess and every menu, "
              "alignment and grouping check would be run against a ladder you never used. "
              "State it on the region.");
        pr.base_cell_mm = jr.plan_base_cell_mm > 0.0 ? jr.plan_base_cell_mm
                                                     : job.grading.cell_mm;
        // ★ R1: THE SENT SLOT ORIGIN WINS. Where the app states the grid it packed on,
        // that grid is what every check and the laying measure from -- alignment, depth,
        // overlap, grouping (stepped_group_cells walks back from this point) and the
        // region the run lays. Absent, the region origin stands, which is what every
        // existing job gets. Its in-plane-ness is settled at parse time (job.cpp).
        pr.slot_origin = jr.slot_origin_stated ? jr.slot_origin_mm : jr.origin;
        pr.slot_origin_stated = jr.slot_origin_stated;
        // ★ K2: the region's own plane, which DEPTH is measured from -- the slot origin
        // above is only the grid phase and may stand off the plane on a tilted facet.
        pr.plane_origin = jr.origin;
        pr.plane_origin_stated = true;
        pr.normal = jr.normal;
        pr.depth_mm = jr.depth_mm;
        plan_regions.push_back(pr);
      }
    }
    // ── ★ D5: WHICH PLANS GET THE OPEN BOUND (reviewer's ruling, 2026-10-10) ─────
    // This was `intent == "aesthetic"` alone, and a DOUBLED job carries no intent at all
    // (job.cpp refuses the key), so Default Grade plans were checked WITHOUT the bound its
    // own packer applies. #354's ladder applies it with no intent gate
    // (LatticeOctreeBake.swift:491-511), so core now does the same for a doubled plan under
    // either intent.
    //
    // Under Stepped it stays aesthetic-only, as before: structural uses the floor alone,
    // because the beam-network certificate solves every strut rather than averaging them
    // and nothing structural depends on a cell looking open.
    const bool prints_open = R.algorithm == LatticeAlgorithm::Doubled
                                 ? true
                                 : job.grading.intent == "aesthetic";
    // ★ D5: THE TILE FLOOR IS THE SMALLEST CELL THAT PRINTS, not the bead. A tile wider
    // than one bead is not therefore printable: the strut it carries at the densest
    // density the job allows still has to clear that bead, which is exactly
    // lattice_min_printable_cell_mm (E1). A doubled job cannot carry
    // `stepped_min_tile_mm` at all (job.cpp refuses the key), so its floor WAS just over
    // the bead -- 0.45 mm where the real floor is 2.25 mm at the job's cap.
    const double printable_floor = lattice_min_printable_cell_mm(
        lat_topo, job.grading.min_extrudable_width_mm, job.grading.max_relative_density);
    const double tile_floor = std::max(printable_floor,
                                       job.grading.stepped_min_tile_mm > 0.0
                                           ? job.grading.stepped_min_tile_mm
                                           : 0.0);
    // ★ RULING A: which MENU the plan is validated against. Doubled admits only the
    // halving ladder; any-step admits every k*(S/n). Same validator, same grid, prism
    // and overlap checks -- the menu is the only difference, and it is the difference
    // that stops a doubled job quietly accepting an any-step plan.
    const SteppedMenu plan_menu =
        R.algorithm == LatticeAlgorithm::Doubled ? SteppedMenu::Halves
                                                 : SteppedMenu::AnyStep;
    const SteppedPlanCheck chk =
        stepped_validate_plan(lat_topo, job.lattice.stepped_cells, plan_regions,
                              job.grading.min_extrudable_width_mm, tile_floor,
                              prints_open, plan_menu,
                              // ★ the include geometry, so a cross-region overlap at a
                              // mitre can be told from a real collision: each cell's
                              // centre must be owned by its own region (ruling 4).
                              &lattice_roles.includes,
                              job.grading.max_relative_density);  // D5: the cap
    if (!chk.ok)
      throw JobError("lattice \"stepped_cells\": " + chk.error +
                     ". Core validates the plan and does not repack it -- the run lays "
                     "down the arrangement the preview showed, or it stops here.");
    const std::vector<SteppedCellGroup> groups =
        stepped_group_cells(job.lattice.stepped_cells, plan_regions);
    std::fprintf(stderr, "[stepped] %s plan: %zu cell(s) over %zu region(s) in %zu "
                         "pass(es) | %s\n",
                 plan_menu == SteppedMenu::Halves ? "doubled (halves)" : "any-step",
                 chk.cells, chk.regions, groups.size(), chk.histogram_line.c_str());
    R.anystep_cells = static_cast<long long>(chk.cells);
    R.anystep_regions = static_cast<long long>(chk.regions);
    R.anystep_passes = static_cast<long long>(groups.size());
    R.anystep_histogram = chk.histogram_line;
    plan_groups = groups;
    plan_chk = chk;
  }

  if (graded) {
    LatticeBoundary members;
    for (const ClearanceGeometry& g : lattice_kos)
      members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
    if (!e3_overrides.empty()) e3_owner.assign(solved_grid.voxel_count(), 0);
    for (const ClearanceGeometry& g : lattice_roles.includes)
      members.add_include_region(g);
    for (const ClearanceGeometry& g : lattice_roles.excludes)
      members.add_exclude_region(g);
    std::vector<char> cand(solved_grid.voxel_count(), 0);
    std::vector<int> region_ids(solved_grid.voxel_count(), 0);
    // ★ GRADING + A DESIGN BOX (reviewer's ruling 2026-11-03 23:05, option (b)): the law
    // plans its cells from what the certificate can lattice. Material the design box
    // added (printed, outside the imported part) is certified SOLID by the added-material
    // policy below, so it is never a candidate: the plan is laid around it, not through
    // it. Off the box path this is empty and the candidate set is unchanged.
    const std::vector<char> cand_in_part =
        domain.expanded ? original_part_voxels(part_grid, domain) : std::vector<char>{};
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!(dens[e] >= printed_iso)) continue;
          if (!cand_in_part.empty() && !cand_in_part[e]) continue;
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
          // retention). The id is 1-based in the job's own declaration order, so a
          // receipt row still maps back to the region the user selected -- but WHICH
          // region a shared voxel gets is no longer decided by that order. Where prisms
          // overlap the owner is the region whose FACE PLANE is nearest, with an exact
          // tie to the lower id (stepped_region_owner, ruling 4, 2026-10-07). 0 means the
          // voxel is in no include prism at all: no owner, not "region 1".
          region_ids[e] = stepped_region_owner(c, lattice_roles.includes);
          if (!e3_overrides.empty()) e3_owner[e] = stepped_region_owner(c, e3_regions);
        }
    GradingLawParams gp;
    if (!e3_overrides.empty()) {   // ★ E3: each region's own grading
      gp.region_override_ids = &e3_owner;
      gp.region_overrides = &e3_overrides;
    }
    // ★ THE PART'S OWN SURFACE (reviewer's ruling 11-09, the rim coupon's SOLID): when the
    // part itself is latticed, its members are measured on its mesh, not on the voxel
    // staircase, which read the steps of the coupon's arch as a rod and a comb of fins.
    std::unique_ptr<MeshDistance> part_md;
    if (part_surface != nullptr && !part_surface->triangles.empty()) {
      part_md = std::make_unique<MeshDistance>(*part_surface);
      gp.member_surface = part_md.get();
    }
    gp.topology = lat_topo;  // the job's type
    gp.target_cell_size_mm = job.grading.cell_mm;
    gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gp.demand_exponent = job.grading.demand_exponent;
    gp.organic_geometry =
        resolve_lattice_algorithm(job.grading) == LatticeAlgorithm::Organic;
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
    // ── ★ THE INTENT AND THE AESTHETIC RANGE, ON THE GEOMETRY PATH ─────────────
    // ★ THEY WERE NEVER PASSED HERE, AND THAT IS WHY A STATED BAND DID NOTHING.
    // PR 344/345 wired the intent into `analyze_job` only. `lattice_one_variant` is
    // the path that WRITES GEOMETRY, and it left `GradingLawParams::intent` at its
    // Structural default with no aesthetic range at all — so a job stating
    // `aesthetic_rho_min/max` had them silently ignored and rho ran over the whole
    // certifiable band. Measured on a 40 mm cube asking for [0.0505, 0.12]: the
    // emitted lattice came out 49.2 % solid against the 6 % the band implies,
    // because the BEAD follows rho (t = 2 d sqrt(rho/3pi)) and rho was reaching 0.9.
    //
    // ★ GATED ON THE JOB SAYING SO, which is what keeps the TO+lattice and multiscale
    // paths byte-identical: an absent "intent" leaves the Structural default exactly
    // as before, and an absent range leaves both zeros, which grading.hpp documents
    // as "the certifiable band". Only a job that ASKS gets anything different.
    if (!job.grading.intent.empty() &&
        !grading_intent_from_name(job.grading.intent.c_str(), gp.intent))
      throw JobError("run_job: unknown grading intent \"" + job.grading.intent + "\"");
    gp.aesthetic_percentile = job.grading.aesthetic_percentile;
    gp.aesthetic_rho_min = job.grading.aesthetic_rho_min;
    gp.aesthetic_rho_max = job.grading.aesthetic_rho_max;
    gp.max_relative_density = job.grading.max_relative_density;
    gp.aesthetic_adaptive_cells_per_member =
        job.grading.aesthetic_adaptive_cells_per_member;
    gp.aesthetic_error_budget = job.grading.aesthetic_error_budget;
    // ★★ IS A BOUNDARY FINISH WRITTEN? This is what lets the adaptive floor reach ONE
    // cell per member (lattice.hpp states the measurement). A finish exists unless the
    // export is the BARE lattice — `outer_finish: "skin"` drops the solid shell, and
    // for organic `grading.organic_boundary_finish: "clean"` then emits nothing at all
    // on the surface either. Any other combination writes a shell, a skin, a rim or a
    // diagrid, and any of those re-ties the struts trimming severed.
    {
      const bool shell_written = lattice_shell_written(job.lattice);
      const bool surface_net =
          job.grading.algorithm == "organic"
              ? job.grading.organic_boundary_finish != "clean"
              : job.lattice.skin != "none";
      gp.boundary_finish_written = shell_written || surface_net;
    }
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
    // ── ★ THE SHAPE-GRADE BAND (ruling 2, 2026-11-06): the doubled lattice's shape grade
    // is the preview's graded band, built by the law (GradingLawParams::band_*), not a
    // solid outline. Stepped keeps its beam (its cells arrive graded from the app) and
    // organic has its own rim. Per voxel: the owner's switch, band and strength (a
    // region's own, else the part's), and the distance to the outline the beam walked.
    if (R.algorithm == LatticeAlgorithm::Doubled) {
      auto own = [&](std::size_t e) -> const JobLatticeRegion* {
        const int id = !e3_owner.empty() ? e3_owner[e] : region_ids[e];
        return id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size()
                   ? &e3_jobs[static_cast<std::size_t>(id - 1)]
                   : nullptr;
      };
      bool any = false;
      band_mm.assign(cand.size(), 0.0);
      band_amount.assign(cand.size(), 1.0);
      for (std::size_t e = 0; e < cand.size(); ++e) {
        if (!cand[e]) continue;
        const JobLatticeRegion* r = own(e);
        const bool on = r != nullptr && r->shape_grade >= 0 ? r->shape_grade == 1
                                                             : job.grading.shape_grade;
        if (!on) continue;
        const double b = r != nullptr && r->shape_grade_band_mm >= 0.0 ? r->shape_grade_band_mm
                                                                        : job.grading.shape_grade_band_mm;
        const double st = r != nullptr && r->shape_grade_strength >= -1.0
                              ? r->shape_grade_strength
                              : job.grading.shape_grade_strength;
        band_mm[e] = b;
        band_amount[e] = std::pow(2.0, std::min(1.0, std::max(-1.0, st)));
        if (b > 0.0) any = true;
      }
      if (any) {
        std::vector<Vec3> nrms;
        for (const JobLatticeRegion& r : e3_jobs) nrms.push_back(r.normal);
        band_distance = lattice_outline_distance_mm(
            solved_grid, cand, !e3_owner.empty() ? e3_owner : region_ids, nrms,
            e3_jobs.empty() || job.lattice.whole_part);
        gp.band_distance_mm = &band_distance;
        gp.band_mm = &band_mm;
        gp.band_amount = &band_amount;
        gp.band_line_width_mm = job.grading.min_extrudable_width_mm;
      }
    }
    gf = grade_lattice(solved_grid, dens, vm_grade, &cand, gp,
                       printed_iso);
    // ★ No solid sliver (ruling 11-09): a solid piece under 2 line widths is latticed with
    // its neighbours, before anything reads the posture.
    absorb_solid_slivers(gf, solved_grid, dens, &cand, gp.min_extrudable_width_mm,
                         printed_iso);
    // ★ ruling 2: where the band stays SOLID, which is only where no cell prints.
    if (gp.band_distance_mm != nullptr) {
      double* bx = gf.band_solid_box;
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (!cand[e] || gf.posture.mask[e] || !(band_mm[e] > 0.0) ||
                !(band_distance[e] >= 0.0 && band_distance[e] < band_mm[e]))
              continue;
            const Vec3 c = solved_grid.voxel_center(i, j, k);
            if (gf.band_solid_voxels++ == 0) {
              bx[0] = bx[3] = c.x; bx[1] = bx[4] = c.y; bx[2] = bx[5] = c.z;
            }
            bx[0] = std::min(bx[0], c.x); bx[1] = std::min(bx[1], c.y); bx[2] = std::min(bx[2], c.z);
            bx[3] = std::max(bx[3], c.x); bx[4] = std::max(bx[4], c.y); bx[5] = std::max(bx[5], c.z);
          }
      // Evidence, behind an env var like the beam band's dump: every band voxel the law
      // latticed, with what the preview's curve is checked against.
      if (const char* bp = std::getenv("TOPOPT_SHAPE_BAND_DUMP")) {
        std::ofstream bf(bp);
        bf.precision(10);
        bf << "# BAND <distance_mm> <band_mm> <amount> <cell_mm> <rho> <strut_mm> <rho_before_band> <finest_printable_cell_mm>\n";
        for (std::size_t e = 0; e < cand.size(); ++e) {
          if (!gf.posture.mask[e] || !(band_mm[e] > 0.0) || band_distance[e] < 0.0) continue;
          const double S = e < gf.posture.cell_size_field.size() && gf.posture.cell_size_field[e] > 0.0
                               ? gf.posture.cell_size_field[e]
                               : gf.posture.cell_size_mm;
          const double r = gf.posture.relative_density[e];
          bf << "BAND " << band_distance[e] << ' ' << band_mm[e] << ' ' << band_amount[e] << ' '
             << S << ' ' << r << ' ' << lattice_strut_diameter_mm(lat_topo, r, S) << ' '
             << (e < gf.band_rho0.size() ? gf.band_rho0[e] : 0.0) << ' '
             << (e < gf.band_finest_mm.size() ? gf.band_finest_mm[e] : 0.0) << '\n';
        }
      }
    }
    // ── ★ THE ORGANIC CELL-SIZE PROBE (see JobLattice::organic_probe_cells_mm) ──
    // Runs here because everything it needs is in scope and already paid for: the
    // one base solve (v.stress_tensor_field), the law's input candidates (`cand`),
    // the law's params (`gp`) and the per-voxel include-region ids. Per candidate
    // window: grade, trace/grow, weld, measure rooting. No emission, no support
    // pass, no certificate. The normal run continues afterwards unchanged.
    const std::string recommend_mode =
        job.lattice.organic_recommend == "auto" ? job.grading.intent : job.lattice.organic_recommend;
    const bool recommend_on = R.algorithm == LatticeAlgorithm::Organic && recommend_mode != "off";
    if (R.algorithm == LatticeAlgorithm::Organic &&
        (recommend_on || !job.lattice.organic_probe_cells_mm.empty() ||
         !job.lattice.organic_probe_grades_mm.empty())) {
      struct Cand { double lo, hi; std::string src = "user"; };
      std::vector<Cand> cands;
      for (double c : job.lattice.organic_probe_cells_mm) cands.push_back({c, c});
      for (const auto& g : job.lattice.organic_probe_grades_mm) cands.push_back({g.first, g.second});
      // ★ THE RECOMMENDATION'S OWN CANDIDATES, from the model's band: the floors from
      // the bead and the voxel, the ceilings from the walls and the faces, the look
      // cell from how many cells the eye should read across the shortest face, its
      // grade from the stress range. Pure and unit-tested (organic_recommend_band).
      if (recommend_on) {
        std::vector<OrganicRecommendRegion> rr;
        int inc = 0;
        for (const JobLatticeRegion& jr : job.lattice.regions) {
          if (jr.role != "include") continue;
          ++inc;
          OrganicRecommendRegion q;
          q.face_id = jr.face_id;
          q.depth_mm = jr.depth_mm;
          q.extent_short_mm = 2.0 * std::min(jr.half_u_mm, jr.half_w_mm);
          if (jr.kind == "bolt") { q.depth_mm = 2.0 * jr.radius_mm; q.extent_short_mm = 2.0 * jr.half_length_mm; }
          std::vector<double> vm;
          for (std::size_t e = 0; e < region_ids.size() && e < vm_grade.size(); ++e)
            if (region_ids[e] == inc && vm_grade[e] > 0.0) vm.push_back(vm_grade[e]);
          if (!vm.empty()) {
            std::sort(vm.begin(), vm.end());
            q.stress_p50 = vm[vm.size() / 2];
            q.stress_p99 = vm[static_cast<std::size_t>(0.99 * static_cast<double>(vm.size() - 1))];
          }
          rr.push_back(q);
        }
        // The organic tracer's own floors (organic_lattice.cpp: d_print_floor_mm and
        // d_res_floor_mm), not the octet law's: the strut is the bead.
        R.organic_recommend_band = organic_recommend_band(
            rr, 0.5 * job.grading.min_extrudable_width_mm * std::sqrt(3.0 * 3.14159265358979323846),
            solved_grid.spacing, OrganicParams{}.resolution_floor_voxels,
            kOrganicRecommendCellsAcrossMember,
            job.lattice.organic_look_cells_across, job.lattice.organic_recommend_steps);
        const OrganicRecommendBand& B = R.organic_recommend_band;
        std::fprintf(stderr, "[recommend] %s: band %.3g-%.3g mm (bead floor %.3g, resolution floor %.3g, member ceiling %.3g, "
                     "extent ceiling %.3g)%s look %.3g grade x%.2f, %zu candidates\n",
                     recommend_mode.c_str(), B.lo_mm, B.hi_mm, B.printability_floor_mm, B.resolution_floor_mm,
                     B.member_ceiling_mm, B.extent_ceiling_mm, B.collapsed ? "  COLLAPSED: no cell fits, solid" : "",
                     B.look_cell_mm, B.grade_ratio, B.candidates.size());
        for (const OrganicRecommendCandidate& c : B.candidates) cands.push_back({c.lo, c.hi, c.source});
      }
      std::vector<OrganicRecommendRow> rec_rows;
      std::string pj = "{\n  \"organic_probe_version\": 1,\n  \"algorithm\": \"organic\",\n";
      pj += "  \"growth\": " + std::string(job.grading.organic_growth ? "true" : "false") + ",\n";
      pj += "  \"transfer_ties\": " + std::string(job.grading.organic_transfer_ties ? "true" : "false") + ",\n";
      pj += "  \"rooted_gate\": 0.95, \"curves_per_family_gate\": 2, \"cells_across_advisory\": 4.0,\n";
      // ★★ THE PROBE'S CALIBRATION, STATED IN ITS OWN RECEIPT (reviewer follow-up,
      // 2026-09-06). The forecast is NOT within 20 % of the run, and it is NOT always
      // conservative. Measured probe margin / run margin on five configurations of the
      // STAND, all Release, all under the per-strut interlayer knockdown:
      //     grown 4.5-4.5  27.12 / 35.64 = 0.76      grown 5.5-5.5  14.79 / 13.61 = 1.09
      //     grown 6.5-6.5  13.97 / 27.01 = 0.52      grown 4.5-5.5  15.04 / 20.78 = 0.72
      //     traced 3-5     15.67 / 35.59 = 0.44
      // (Before the probe's certificate mask was fixed to the post-rim mask the same
      // five read 0.27-0.63.) What remains is the NETWORK: the run's support pass,
      // transfer ties, fill mat and re-seeding certify higher with FEWER members than
      // the probe's raw curves plus its synthetic scaffolding. So: a probe approval at
      // margin m means the run's margin is somewhere in [m/1.09, m/0.44]; requiring
      // m >= 1.09 x the target is what makes an approval safe on this sample, and the
      // recommendation's default target (1.5) already clears it.
      pj += "  \"calibration\": {\"measured\": \"2026-09-06\", \"configurations\": 5, "
            "\"probe_over_run_min\": 0.44, \"probe_over_run_max\": 1.09, "
            "\"conservative_always\": false, \"safe_approval_factor\": 1.09, "
            "\"note\": \"the forecast is not calibrated to 20 %: it may refuse a window the run "
            "certifies (0.44x) and may read above the run (1.09x); require margin >= 1.09 x target "
            "for an approval to imply the run certifies\"},\n";
      pj += "  \"candidates\": [\n";
      // ★ THE SYNTHESIS MOVED INTO THE LOOP, AND ONTO THE POSTURE MASK (#354's
      // audit, 2026-09-29). It used to happen ONCE here over `cand` -- the candidate
      // set -- and without `synthesised_whole`. Two things were wrong with that, and
      // they are NOT equally serious; the honest split, measured 2026-09-29:
      //
      //   (1) THE DOMAIN MOVE IS A NO-OP TODAY, and saying otherwise would be wrong.
      //       For organic, `grade_lattice` masks EVERY candidate voxel -- all three
      //       `params.organic_geometry` branches in grading.cpp set `post.mask[e] = 1`
      //       and `continue` before any octet refusal -- so `cand` and
      //       `agf.posture.mask` are the SAME SET on every organic run. Measured on
      //       the cli_organic_dead_parity fixture across cell 3-10 mm, uniform and
      //       swept windows, min_extrudable_width 0.45-3 mm, three rho bands, a
      //       manual clearance keep-out and all three outer finishes: cand == posture
      //       == the run's mask, every time, and the two dead sets were identical
      //       with `cand` in place. It is written this way for the CONTRACT (the
      //       probe must name the domain it means), not because it moved a number.
      //
      //   (2) `synthesised_whole` WAS MISSING, and that half is real: ruling H hands
      //       a whole-synthesised wall the window's MIDDLE spacing, so without it the
      //       probe sized a dead wall against a lattice the run would not build.
      //
      //   ★ AND WHAT IS STILL NOT ALIGNED. The run's domain is not the posture: it
      //   is `lattice_certification_mask(boundary, ...) ∩ gf.posture.mask` (see the
      //   organic block below), and the probe has no certification mask -- it runs
      //   before the variant's shell boundary is built. Nothing measurable separated
      //   the two on the fixture above, so the gap is UNMEASURED rather than closed,
      //   and it is the one that could still move a verdict on a part whose
      //   cell-overlap proof or shell clip rejects posture voxels.
      //
      // The domain is that candidate's own PRE-RIM posture mask: the run synthesises
      // before its rim band is cleared (ruling G applies the band after the tracer),
      // so the probe must too -- and a post-rim domain here IS observable, which is
      // what cli_organic_dead_parity's positive control uses to go red. Per candidate
      // this costs one O(n) pass plus a p99 sort beside a full trace and certificate.
      // ★ THE STRESS HALF (2026-09-05). Rooting alone saturates at 100 % on a wall
      // whose every welded network touches the solid, and the certificate's margin
      // is what "approved for structural" has to mean. So each candidate's RAW trace
      // -- curves decimated to beam segments, no emission, no support pass -- goes
      // through the same certificate the run will use, with the same loads, material
      // and knockdown. It is a prediction: the support pass and the fill will change
      // the network; its agreement with the run's certificate is the calibration.
      const LatticeCertContext pcx = lattice_cert_context(v, part_grid, domain, options, material, job);
      for (std::size_t ci = 0; ci < cands.size(); ++ci) {
        const Cand& cc = cands[ci];
        const double t0 = wall_seconds();
        GradingLawParams alt = gp;
        alt.min_cell_size_mm = cc.lo; alt.max_cell_size_mm = cc.hi;
        // ★ NOT alt.target_cell_size_mm = cc.hi. A target pins the law to one cell and
        // one density, so every probe strut got the same bead (measured 2026-09-06:
        // min == max radius in every window) while the run's struts grade with stress
        // (0.27-0.73 mm on the same window). The run leaves the target as the job set
        // it; so does the probe now. (Reviewer follow-up: the probe's under-forecast
        // was its RADIUS, not its legs.)
        JobGrading jg2 = job.grading;
        jg2.cell_min_mm = cc.lo; jg2.cell_max_mm = cc.hi; jg2.cell_mm = cc.hi;
        GradedField agf = grade_lattice(solved_grid, dens, vm_grade, &cand, alt, printed_iso);
        absorb_solid_slivers(agf, solved_grid, dens, &cand, alt.min_extrudable_width_mm,
                             printed_iso);
        // ★ THE RUN'S DOMAIN, NOT THE POSTURE (reviewer, 2026-09-30). The run builds
        // its lattice on lattice_certification_mask INTERSECT the posture; the probe
        // used the posture alone, so it forecast for a set the run does not build.
        // Same function, same terms, this candidate's own coarsest cell. The boundary
        // is per candidate because the cell-overlap proof is a function of the cell --
        // measured cost is stated in the commit; v.v3.mesh is already in hand here.
        const double pcell = agf.cell_size_mm > 0.0 ? agf.cell_size_mm : cc.hi;
        const LatticeBoundary pbnd =
            lattice_boundary_for(solved_grid, dens, pcell, lattice_kos, lattice_roles,
                                 printed_iso, &v.v3.mesh);
        const std::vector<char> pdomain = lattice_synthesis_domain(
            pbnd, solved_grid, dens, printed_iso,
            solved_grid.origin, pcell, agf.posture.mask);
        std::vector<char> pmask = pdomain;
        // the run's order: synthesise over the domain, THEN clear the rim
        SyntheticStressReport prep;
        const std::vector<double> probe_stress = stress_tensor_for_organic(
            job, solved_grid, pdomain, region_ids, v.stress_tensor_field, &prep);
        // ★ AND THE SAME GRADING INPUT: ruling H hands a whole-synthesised wall the
        // window's MIDDLE spacing, because its manufactured field has no real stress
        // to grade by. The probe used to skip this and take the coarsest end, so it
        // sized a dead wall against a lattice the run would never build.
        const std::vector<char> probe_synth_whole =
            organic_synthesised_whole_voxels(prep, region_ids, solved_grid.voxel_count());
        {
          const double rim = job.grading.organic_solid_rim_mm < 0.0 ? cc.lo : job.grading.organic_solid_rim_mm;
          std::vector<Vec3> nrms;
          for (const JobLatticeRegion& r : job.lattice.regions) if (r.role == "include") nrms.push_back(r.normal);
          // The probe forecasts a cell size; it ships no geometry, so the band comes out
          // of its candidate set as before -- ruling G is about what the RUN draws.
          clear_band_from_mask(
              pmask, organic_solid_rim_band(solved_grid, pmask, region_ids, nrms, rim));
        }
        OrganicOutcome po = run_organic_step(lattice_shell_written(job.lattice), solved_grid, dens,
                                             probe_stress, pmask, agf.posture.relative_density,
                                             agf.band_rho_min, agf.band_rho_max, jg2,
                                             job.loads.present && job.loads.minimize_plastic,
                                             v.applied_build_dir, printed_iso, 32,
                                             job.loads.layer_height_mm, /*probe_only=*/true,
                                             &probe_synth_whole);
        // ★ ONE welded polyline set feeds BOTH measures: thin to 2 mm keeping shared
        // vertices, insert crossing junctions, then root and certify the same curves.
        OrganicLattice plat = po.lat;
        std::size_t crossings = 0;
        {
          std::unordered_map<long long, int> seen0;
          auto vkey0 = [](const Vec3& q) {
            const long long ix = static_cast<long long>(std::llround(q.x * 1e4));
            const long long iy = static_cast<long long>(std::llround(q.y * 1e4));
            const long long iz = static_cast<long long>(std::llround(q.z * 1e4));
            return (ix * 73856093LL) ^ (iy * 19349663LL) ^ (iz * 83492791LL);
          };
          for (const OrganicCurve& cv : plat.curves) for (const Vec3& q : cv.points) ++seen0[vkey0(q)];
          for (OrganicCurve& cv : plat.curves) {
            if (cv.points.size() < 2) continue;
            std::vector<Vec3> thin{cv.points.front()};
            for (std::size_t k = 1; k < cv.points.size(); ++k) {
              const bool end = (k + 1 == cv.points.size());
              const bool weld = seen0[vkey0(cv.points[k])] > 1;
              const double dx = cv.points[k].x - thin.back().x, dy = cv.points[k].y - thin.back().y, dz = cv.points[k].z - thin.back().z;
              const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
              if (!end && !weld && d < 2.0) continue;
              if (d > 1e-6) thin.push_back(cv.points[k]);
            }
            cv.points.swap(thin);
            cv.seg_kind.clear();
          }
          crossings = weld_curve_crossings(plat.curves);
        }
        // the emission's free-end tie, at its reach (kOrganicTieReachRatio x the window)
        const std::size_t n_before_ties = plat.curves.size();
        const std::size_t free_ties = tie_curve_free_ends(plat.curves, kOrganicTieReachRatio * cc.hi);
        // the support pass's legs: a vertical drop from every end onto the lattice below
        const std::size_t n_before_legs = plat.curves.size();
        const std::size_t legs = drop_curve_legs(plat.curves, 1.5 * cc.hi);
        if (free_ties || legs) crossings += weld_curve_crossings(plat.curves);
        const OrganicProbeResult pr = probe_organic_rooting(plat, region_ids);
        const double secs = wall_seconds() - t0;
        std::vector<BeamSegment> psegs;
        // ★ TAG THE PROBE'S SCAFFOLDING: curves appended by the free-end tie (2) and by
        // the legs (1) are the probe's, not the run's; the certificate reports the p99
        // with and without them (reviewer follow-up, 2026-09-06).
        for (std::size_t ci2 = 0; ci2 < plat.curves.size(); ++ci2) {
          const OrganicCurve& cv = plat.curves[ci2];
          const int tag = ci2 >= n_before_legs ? 1 : ci2 >= n_before_ties ? 2 : 0;
          for (std::size_t k = 1; k < cv.points.size(); ++k) {
            const double dx = cv.points[k].x - cv.points[k - 1].x, dy = cv.points[k].y - cv.points[k - 1].y, dz = cv.points[k].z - cv.points[k - 1].z;
            if (dx * dx + dy * dy + dz * dz > 1e-12) psegs.push_back({cv.points[k - 1], cv.points[k], cv.radius_mm, tag});
          }
        }
        if (false) {
          // ★ KEEP THE WELDS. A tie's vertex at a pillar IS that pillar's vertex; the
          // beam network welds node-to-node, so thinning a pillar past that vertex
          // leaves the tie landing mid-segment and unwelded -- the first probe
          // predicted 0.46 where the run certified 1.55 for exactly this reason.
          // Every vertex shared by two curves (exact match) is kept; the rest are
          // thinned to 2 mm.
          std::unordered_map<long long, int> seen;
          auto vkey = [](const Vec3& q) {
            const long long ix = static_cast<long long>(std::llround(q.x * 1e4));
            const long long iy = static_cast<long long>(std::llround(q.y * 1e4));
            const long long iz = static_cast<long long>(std::llround(q.z * 1e4));
            return (ix * 73856093LL) ^ (iy * 19349663LL) ^ (iz * 83492791LL);
          };
          for (const OrganicCurve& cv : po.lat.curves)
            for (const Vec3& q : cv.points) ++seen[vkey(q)];
          auto dist = [](const Vec3& a, const Vec3& b) {
            const double dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
            return std::sqrt(dx * dx + dy * dy + dz * dz);
          };
          for (const OrganicCurve& cv : po.lat.curves) {
            if (cv.points.size() < 2) continue;
            Vec3 last = cv.points.front();
            for (std::size_t k = 1; k < cv.points.size(); ++k) {
              const bool end = (k + 1 == cv.points.size());
              const bool weld = seen[vkey(cv.points[k])] > 1;
              const double d = dist(cv.points[k], last);
              if (!end && !weld && d < 2.0) continue;
              if (d > 1e-6) psegs.push_back({last, cv.points[k], cv.radius_mm});
              last = cv.points[k];
            }
          }
        }
        // ★ DIAGNOSIS DUMP (reviewer follow-up): the probe's spans in the run's own
        // ledger format, so radius and length can be compared with <prefix>_SPANS.txt.
        if (const char* pd = std::getenv("TOPOPT_PROBE_SPANS_DUMP")) {
          char pn[512];
          std::snprintf(pn, sizeof pn, "%s/probe_%g_%g_SPANS.txt", pd, cc.lo, cc.hi);
          if (FILE* f = std::fopen(pn, "w")) {
            double rsum = 0.0, lsum = 0.0, rmin = 1e9, rmax = 0.0;
            for (const BeamSegment& sg : psegs) {
              const double dx = sg.b.x - sg.a.x, dy = sg.b.y - sg.a.y, dz = sg.b.z - sg.a.z;
              const double L = std::sqrt(dx * dx + dy * dy + dz * dz);
              rsum += sg.radius_mm * L; lsum += L; rmin = std::min(rmin, sg.radius_mm); rmax = std::max(rmax, sg.radius_mm);
              std::fprintf(f, "SEG %.6g %.6g %.6g %.6g %.6g %.6g %.6g %d\n", sg.a.x, sg.a.y, sg.a.z, sg.b.x, sg.b.y, sg.b.z,
                           sg.radius_mm, sg.tag);
            }
            std::fclose(f);
            std::fprintf(stderr, "[probe]   spans: %zu, length %.0f mm, radius length-weighted mean %.4g (min %.4g max %.4g)\n",
                         psegs.size(), lsum, lsum > 0.0 ? rsum / lsum : 0.0, rmin, rmax);
          }
        }
        std::string pred = "\"predicted\": {\"ran\": false, \"reason\": \"no segments\"}";
        bool cert_ok = false;
        double cert_margin = 0.0;
        // ★ THE CERTIFICATE IS A STRUCTURAL QUESTION. On an aesthetic job nothing reads
        // it (the aesthetic recommendation picks by look and rooting), and the probe's
        // network under an aesthetic job's loads prints refusals at zero stress -- noise
        // that cost 10 x 12 s on the M2 run. Run it only when structural intent or a
        // structural recommendation will read the answer.
        const bool want_cert = job.grading.intent == "structural" || recommend_mode == "structural";
        // ★ ONE DECISION, TESTED (organic_probe_certificate_skip). Each branch below
        // states its OWN reason and no branch may overwrite another's -- see the
        // helper for what that cost.
        constexpr std::size_t kProbeSegmentCap = 600000;
        const OrganicProbeSkip skip =
            organic_probe_certificate_skip(want_cert, psegs.size(), kProbeSegmentCap);
        switch (skip) {
          case OrganicProbeSkip::AestheticIntent:
            pred = "\"predicted\": {\"ran\": false, \"reason\": \"aesthetic intent: "
                   "nothing reads a certificate\"}";
            break;
          case OrganicProbeSkip::NoSegments:
            pred = "\"predicted\": {\"ran\": false, \"reason\": \"no segments\"}";
            break;
          case OrganicProbeSkip::SegmentCap:
            pred = "\"predicted\": {\"ran\": false, \"reason\": \"" +
                   std::to_string(psegs.size()) + " segments exceed the probe's " +
                   std::to_string(kProbeSegmentCap) + " cap\"}";
            break;
          case OrganicProbeSkip::None:
            break;   // the certificate runs below and writes its own
        }
        if (skip == OrganicProbeSkip::None) {
          const double t1 = wall_seconds();
          std::vector<char> hexm(solved_grid.voxel_count(), 0);
          for (std::size_t e = 0; e < solved_grid.voxel_count(); ++e)
            // ★ THE SOLID THE PROBE CERTIFIES AGAINST IS THE MASK ITS CURVES WERE TRACED
            // ON -- `pmask`, after the solid rim -- not the grading mask before it. With
            // the pre-rim mask the rim band was neither solid nor lattice in the probe's
            // certificate: an unsupported lattice edge the run never has. Measured
            // 2026-09-06: the probe's own network on the run's grid reads 0.80 of the run;
            // the probe's own certificate read 0.63 -- this mask was the difference.
            if (v.optimization.physical_density[e] > pcx.printed_iso && !pmask[e]) hexm[e] = 1;
          const std::vector<OrganicLoadCase> pocs = organic_load_cases(pcx, bcs);
          const OrganicCertificate pc = certify_organic_structural(
              solved_grid, hexm, psegs, pocs, material.youngs_modulus_mpa, material.poisson,
              material.yield_strength_mpa, material.z_knockdown, v.applied_build_dir, cc.hi, true);
          // ★ THE PROBE FORECASTS THE p99. Its network is the raw traced curves --
          // thinned, welded and legged, but not the run's -- so a point load at one
          // of ITS strut ends is the probe's artefact, not the run's worst strut.
          // The max rule (max_exceeds_allowable) is the RUN's gate; here it is
          // reported beside the forecast, never read as the verdict.
          cert_ok = pc.margin >= 1.0;
          cert_margin = pc.margin;
          char pb[1400];
          std::snprintf(pb, sizeof pb,
                        "\"predicted\": {\"ran\": true, \"verdict\": \"%s\", \"margin\": %.6g, "
                        "\"p99_mpa\": %.6g, \"max_mpa\": %.6g, \"allowable_mpa\": %.6g, "
                        "\"knockdown_used\": %.4g, \"knockdown_source\": \"%s\", "
                        "\"max_over_allowable\": %.4g, \"max_over_allowable_distributed\": %.4g, "
                        "\"max_exceeds_allowable\": %s, "
                        "\"margin_untagged\": %.6g, \"p99_untagged_mpa\": %.6g, \"members_tagged\": %zu, "
                        "\"tagged_p99_mpa\": %.6g, \"tagged_ratio_p99\": %.6g, "
                        "\"segments\": %zu, \"seconds\": %.3g, \"refusal\": \"%s\"}",
                        cert_ok ? "certified" : "refused", pc.margin, pc.stress_p99_mpa,
                        pc.stress_max_mpa, pc.allowable_used_mpa, pc.knockdown_used,
                        pc.knockdown_source.c_str(), pc.max_over_allowable,
                        pc.max_over_allowable_distributed,
                        pc.max_exceeds_allowable ? "true" : "false",
                        pc.margin_untagged, pc.stress_p99_untagged_mpa, pc.members_tagged,
                        pc.tagged_p99_mpa, pc.tagged_ratio_p99, psegs.size(),
                        wall_seconds() - t1, json_safe(pc.refusal.substr(0, 160)).c_str());
          pred = pb;
          std::fprintf(stderr,
                       "[probe]   stress: %s margin %.3g p99 %.3g  (untagged: margin %.3g p99 %.3g; %zu tagged members, "
                       "tagged p99 %.3g)  kd %.3g  max/allowable %.3g point %.3g distributed (%zu segs, %.1fs)\n",
                       cert_ok ? "certified" : "REFUSED", pc.margin, pc.stress_p99_mpa,
                       pc.margin_untagged, pc.stress_p99_untagged_mpa, pc.members_tagged, pc.tagged_p99_mpa,
                       pc.knockdown_used, pc.max_over_allowable, pc.max_over_allowable_distributed,
                       psegs.size(), wall_seconds() - t1);
        }
        bool ok_s = true, ok_a = true;
        std::string regs;
        int include_index = 0;
        for (const JobLatticeRegion& jr : job.lattice.regions) {
          if (jr.role != "include") continue;
          ++include_index;
          const OrganicProbeRegion* R2 = nullptr;
          for (const OrganicProbeRegion& q : pr.regions) if (q.region_id == include_index) R2 = &q;
          const double rooted = (R2 && R2->traced_mm > 0.0) ? R2->rooted_mm / R2->traced_mm : 0.0;
          const double across = jr.depth_mm > 0.0 && cc.hi > 0.0 ? jr.depth_mm / cc.hi : 0.0;
          const std::size_t cpf_min = R2 ? std::min(R2->curves_per_family[0], R2->curves_per_family[1]) : 0;
          std::string refs;
          if (rooted < 0.95) refs += std::string("rooted ") + std::to_string(rooted) + " < 0.95";
          if (cpf_min < 2) refs += (refs.empty() ? "" : "; ") + std::string("curves_per_family min ") + std::to_string(cpf_min) + " < 2";
          const bool ok_aes = rooted >= 0.95 && cpf_min >= 2;
          // ★ cells_across is ADVISORY, not a gate (measured 2026-09-05): on a 12 mm
          // wall every candidate sits at 1.7-3.4 cells across, and the certificate
          // CERTIFIED two of them (traced 3-5 at 7.46, grown 4.5-5.5 at 1.55). The
          // four-cells rule is a continuum-stiffness criterion for periodic cells; an
          // organic lattice is judged by its beam network, not by a homogenised
          // modulus, so refusing here would refuse what the certificate certifies.
          std::string advice;
          if (across < 4.0) advice = "cells_across " + std::to_string(across) + " < 4 (advisory)";
          const bool ok_str = ok_aes;
          ok_s = ok_s && ok_str; ok_a = ok_a && ok_aes;
          // ★ THE PROBE'S OWN DEAD VERDICT, IN ITS OWN RECEIPT (2026-09-29).
          // Report-only, and the point of it: the domain fix above is only checkable
          // if BOTH sides say which walls they called dead. `run_info.json`'s
          // grading.synthetic_stress_by_region[] carries the same two keys for the
          // run, and cli_organic_dead_parity compares them. A region with no row in
          // `prep` was never flagged (or has no voxels in the domain): not dead.
          const SyntheticStressRegionReport* PS = nullptr;
          for (const SyntheticStressRegionReport& q : prep.per_region)
            if (q.region_id == include_index) PS = &q;
          char buf[800];
          std::snprintf(buf, sizeof buf,
                        "        {\"face_id\": %d, \"region_id\": %d, \"depth_mm\": %.6g, \"cells_across\": %.4g, "
                        "\"curves_per_family\": [%zu, %zu, %zu], \"components\": %zu, "
                        "\"traced_length_mm\": %.6g, \"rooted_length_fraction\": %.6g, "
                        "\"synthesised_whole\": %s, \"stress_p99\": %.6g, "
                        "\"approved_structural\": %s, \"approved_aesthetic\": %s, \"refusals\": \"%s\", \"advice\": \"%s\"}",
                        jr.face_id, include_index, jr.depth_mm, across,
                        R2 ? R2->curves_per_family[0] : 0, R2 ? R2->curves_per_family[1] : 0, R2 ? R2->curves_per_family[2] : 0,
                        R2 ? R2->components : 0, R2 ? R2->traced_mm : 0.0, rooted,
                        (PS && PS->whole_region) ? "true" : "false", PS ? PS->p99_von_mises : 0.0,
                        ok_str ? "true" : "false", ok_aes ? "true" : "false", refs.c_str(), advice.c_str());
          regs += std::string(regs.empty() ? "" : ",\n") + buf;
        }
        char head[560];
        std::snprintf(head, sizeof head,
                      "    {\"cell_min_mm\": %.6g, \"cell_max_mm\": %.6g, \"trace_seconds\": %.3g, "
                      "\"curves\": %zu, \"components\": %zu, \"traced_length_mm\": %.6g, "
                      // \"candidate_voxels\" IS the synthesis domain: it counts the same
                      // pre-rim posture mask the synthesis ran over, which is the whole
                      // point of the 2026-09-29 fix. \"dead_threshold\" is the threshold
                      // the per-region verdicts below were measured against, so a
                      // disagreement with the run is locatable rather than merely visible.
                      "\"rooted_length_fraction\": %.6g, \"candidate_voxels\": %zu, "
                      "\"dead_threshold\": %.6g,\n      \"regions\": [\n",
                      cc.lo, cc.hi, secs, pr.curves, pr.components, pr.traced_mm,
                      pr.traced_mm > 0.0 ? pr.rooted_mm / pr.traced_mm : 0.0,
                      static_cast<std::size_t>(std::count(agf.posture.mask.begin(), agf.posture.mask.end(), 1)),
                      prep.dead_threshold);
        const bool approved_structural = ok_s && cert_ok;
        pj += head + regs + "\n      ],\n      " + pred + ",\n      \"approved_structural\": " +
              (approved_structural ? "true" : "false") +
              ", \"approved_aesthetic\": " + (ok_a ? "true" : "false") + "}" + (ci + 1 < cands.size() ? ",\n" : "\n");
        {
          OrganicRecommendRow row;
          row.lo = cc.lo; row.hi = cc.hi; row.source = cc.src; row.rooted_ok = ok_a;
          row.certified = cert_ok; row.margin = cert_margin; row.traced_mm = pr.traced_mm;
          rec_rows.push_back(row);
        }
        std::fprintf(stderr, "[probe] cell %.3g-%.3g: %zu curves, %zu crossings welded, %zu free ends tied, %zu legs, rooted %.3f, %.1fs%s\n", cc.lo, cc.hi,
                     pr.curves, crossings, free_ties, legs, pr.traced_mm > 0.0 ? pr.rooted_mm / pr.traced_mm : 0.0, secs,
                     approved_structural ? "  APPROVED structural" : ok_a ? "  approved aesthetic only" : "  refused");
      }
      // ★ THE RECOMMENDATION reads the rows the probe just measured.
      std::string rj = "{\"ran\": false}";
      if (recommend_on) {
        const OrganicRecommendBand& B = R.organic_recommend_band;
        R.organic_recommendation = organic_recommend_select(rec_rows, recommend_mode,
                                                            job.lattice.organic_recommend_margin, B.look_cell_mm);
        R.organic_recommend_ran = true;
        const OrganicRecommendation& RC = R.organic_recommendation;
        char rb[1200];
        // ── ★ A MARGIN THAT WAS NEVER MEASURED IS null, NOT 0 (2026-09-29) ───────
        // fit_margin / auto_margin default to 0.0 and were written unconditionally,
        // so "margin": 0 meant three different things: certified at 0 (impossible),
        // NO CERTIFICATE RAN (every aesthetic run), or no row found. #354's
        // Recommended pills read it straight out as "· 0.00". The margin is now the
        // JSON null where it was not measured, and `certified` states it positively
        // beside it so no consumer has to infer from a sentinel.
        char fmb[40] = "null", amb[40] = "null";
        if (RC.fit_certified) std::snprintf(fmb, sizeof fmb, "%.6g", RC.fit_margin);
        if (RC.auto_certified) std::snprintf(amb, sizeof amb, "%.6g", RC.auto_margin);
        const char* fit_margin_json = fmb;
        const char* auto_margin_json = amb;
        std::snprintf(rb, sizeof rb,
                      "{\"ran\": true, \"mode\": \"%s\", \"band_lo_mm\": %.6g, \"band_hi_mm\": %.6g, "
                      "\"collapsed\": %s, \"printability_floor_mm\": %.6g, \"resolution_floor_mm\": %.6g, "
                      "\"member_ceiling_mm\": %.6g, \"extent_ceiling_mm\": %.6g, \"look_cell_mm\": %.6g, "
                      "\"grade_ratio\": %.6g, \"look_cells_across\": %.6g, \"target_margin\": %.6g,\n"
                      "    \"fit\": {\"found\": %s, \"cell_mm\": %.6g, \"certified\": %s, "
                      "\"margin\": %s, \"traced_mm\": %.6g, \"source\": \"%s\"},\n"
                      "    \"auto\": {\"found\": %s, \"cell_min_mm\": %.6g, \"cell_max_mm\": %.6g, "
                      "\"certified\": %s, \"margin\": %s, "
                      "\"traced_mm\": %.6g, \"source\": \"%s\"},\n    \"rejected\": [",
                      RC.mode.c_str(), B.lo_mm, B.hi_mm, B.collapsed ? "true" : "false", B.printability_floor_mm,
                      B.resolution_floor_mm, B.member_ceiling_mm, B.extent_ceiling_mm, B.look_cell_mm, B.grade_ratio,
                      job.lattice.organic_look_cells_across, job.lattice.organic_recommend_margin,
                      RC.fit_found ? "true" : "false", RC.fit_mm,
                      RC.fit_certified ? "true" : "false", fit_margin_json,
                      RC.fit_traced_mm, RC.fit_source.c_str(),
                      RC.auto_found ? "true" : "false", RC.auto_lo_mm, RC.auto_hi_mm,
                      RC.auto_certified ? "true" : "false", auto_margin_json,
                      RC.auto_traced_mm, RC.auto_source.c_str());
        rj = rb;
        for (std::size_t i = 0; i < RC.rejected.size(); ++i) {
          char e[300];
          std::snprintf(e, sizeof e, "%s{\"cell_min_mm\": %.6g, \"cell_max_mm\": %.6g, \"source\": \"%s\", \"reason\": \"%s\"}",
                        i ? ", " : "", RC.rejected[i].first.lo, RC.rejected[i].first.hi,
                        RC.rejected[i].first.source.c_str(), json_safe(RC.rejected[i].second).c_str());
          rj += e;
        }
        rj += "]}";
        std::fprintf(stderr, "[recommend] %s: FIT %s%.3g mm (%s, margin %.3g)  AUTO %s%.3g-%.3g mm (%s, margin %.3g, traced %.0f vs %.0f mm)  %zu rejected\n",
                     RC.mode.c_str(), RC.fit_found ? "" : "NONE ", RC.fit_mm, RC.fit_source.c_str(), RC.fit_margin,
                     RC.auto_found ? "" : "NONE ", RC.auto_lo_mm, RC.auto_hi_mm, RC.auto_source.c_str(), RC.auto_margin,
                     RC.auto_traced_mm, RC.fit_traced_mm, RC.rejected.size());
      }
      pj += "  ],\n  \"recommendation\": " + rj + "\n}\n";
      write_text_file(join_path(out_dir, "organic_probe.json"), pj);
    }

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
      const std::vector<double> tau =
          gf.member_width_mm.size() == solved_grid.voxel_count()
              ? gf.member_width_mm  // the law's own (rulings 11-09)
              : local_member_thickness_mm(solved_grid, dens, printed_iso,
                                          gp.thickness_cap_voxels);
      const std::vector<double>& vm = vm_grade;

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
      const double n_star = lattice_cells_per_member_min(lat_topo);
      // ★ D1: phi at the densest density THE JOB allows, not the band's top.
      const double phi_hi =
          w_min / lattice_min_printable_cell_mm(lat_topo, w_min, job.grading.max_relative_density);

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
        // ★ D1: with the job's cap, so the row reports the floor the run applies.
        rc.at_thinnest = lattice_derive_cell_for_member(
            lat_topo, tmin, w_min, 0.0, job.grading.max_relative_density);
        rc.at_thickest = lattice_derive_cell_for_member(
            lat_topo, tmax, w_min, 0.0, job.grading.max_relative_density);

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
      // ── ★ ON A PLAN JOB THIS IS A REPORT, NOT A REFUSAL (ruling, 2026-10-11) ──
      // The law could grade nothing. On a job that sent no plan that is the end of it:
      // there is no lattice to emit and the refusal below stands, unchanged.
      //
      // On a PLAN job it is not core's decision to make. The plan IS the design: it says
      // which cells, and with ruling C it says at what density, so core needs the law's
      // grade for neither the geometry nor the certificate. Measured on 102117B9's
      // Default Grade plan -- 12,112 cells over 177 regions, every one carrying a rho --
      // the plan validated and then this line refused the job over 66,710 candidate
      // voxels the LAW could not grade. That is core's own law gating a design it was
      // not asked to produce.
      //
      // So: reported, and the run carries on. The plan's posture certifies as usual and
      // can still refuse on its own grounds (the octet band, the strut-strength margin,
      // the void rule) -- this removes one gate, not the certificate.
      //
      // ★ THE CONDITION IS THE PLAN'S OWN DENSITY, not the mere presence of a plan. Every
      // planned cell must carry a rho; D5 has already proved each of those prints at its
      // own size. A cell with no rho would have to be sized from the law's field, and the
      // law has nothing here -- K3's refusal covers exactly that case and is unchanged.
      bool plan_rho_everywhere = !job.lattice.stepped_cells.empty();
      std::size_t cells_without_rho = 0;
      for (const SteppedCell& c : job.lattice.stepped_cells)
        if (!(c.rho > 0.0)) ++cells_without_rho;
      if (cells_without_rho > 0) plan_rho_everywhere = false;
      if (plan_rho_everywhere) {
        R.law_ungradeable_reported = true;
        R.law_ungradeable_note =
            "the grading law could lattice NONE of this variant's " +
            std::to_string(gf.region_voxels) +
            " candidate voxels, and the run carried on because the PLAN is the design: " +
            std::to_string(job.lattice.stepped_cells.size()) +
            " cell(s), every one carrying its own relative density, so core needs the "
            "law's grade for neither the geometry nor the certificate. The law's own "
            "fallbacks over the voxels it rejected: member_too_thin_for_cell=" +
            std::to_string(gf.fallback_member_too_thin) +
            ", strut_unprintable_at_every_cell=" +
            std::to_string(gf.fallback_strut_unprintable) +
            ", irrecoverable_by_any_cell_size=" +
            std::to_string(gf.fallback_irrecoverable_by_cell) +
            ". The plan's posture still certifies, and can still refuse.";
        std::fprintf(stderr, "[stepped] law ungradeable, REPORTED not refused: %s\n",
                     R.law_ungradeable_note.c_str());
        // ★ AND THE WINDOW NEEDS A CELL. `cell` below feeds the boundary's voxel-base
        // window (2 x cell) and the certification mask's own cell. The law may leave it
        // at 0 when it graded nothing, so it falls back to the PLAN's coarsest cell --
        // the plan's own number, never one core invents.
        double plan_coarsest = 0.0;
        for (const SteppedCell& c : job.lattice.stepped_cells)
          if (c.size_mm > plan_coarsest) plan_coarsest = c.size_mm;
        if (!(gf.cell_size_mm > 0.0) && plan_coarsest > 0.0)
          gf.cell_size_mm = plan_coarsest;
      } else {
      R.ungradeable = true;
      // ★ THE FLOOR IS QUOTED AT THE RUN'S OWN FINEST CELL (reviewer's ruling 11-10). It
      // used to be quoted at `cell_size_mm`, which a swept or fit run that latticed nothing
      // leaves at the smallest LEGAL cell (width / phi(rho_max): 0.79 mm at a 0.32 mm
      // bead), a cell the run never allowed -- so a 12.5 mm member beside "must be at
      // least 3.97 mm" read as a pass. The finest cell the run allows is the most lenient
      // floor it could have applied; a member under it is too thin at every cell it had.
      const double finest_cell =
          gf.finest_cell_mm > 0.0 ? gf.finest_cell_mm : gf.cell_size_mm;
      const double floor_at_finest = gf.cells_per_member_floor * finest_cell;
      const std::string widths =
          gf.fallback_max_member_width_mm < floor_at_finest
              ? ". Every member is too thin: the widest is " +
                    json_num(gf.fallback_max_member_width_mm) +
                    " mm across, under the " + json_num(floor_at_finest) + " mm that " +
                    json_num(gf.cells_per_member_floor) +
                    " cells of this run's finest cell (" + json_num(finest_cell) +
                    " mm) need"
              : ". The widest member the law rejected is " +
                    json_num(gf.fallback_max_member_width_mm) +
                    " mm across, which would hold " +
                    json_num(gf.cells_per_member_floor) +
                    " cells of this run's finest cell (" + json_num(finest_cell) +
                    " mm, " + json_num(floor_at_finest) +
                    " mm needed); it was rejected because its own cell is coarser or its "
                    "strut does not print (the reasons above)";
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
          std::to_string(gf.fallback_irrecoverable_by_cell) + widths +
          ". A smaller cell needs a finer declared extrusion width "
          "(min_extrudable_width_mm " +
          json_num(gp.min_extrudable_width_mm) +
          " mm sets the printability floor at " +
          json_num(gf.printability_floor_mm) +
          " mm) — run the pre-flight forecast for the evaluated remedies.";
      R.gf = gf;
      return R;
      }
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

  // ── ★ K3 / RULING 2: WHAT THE OUTLINE CLIP APPLIES TO, STATED ────────────────
  // The clip is scope (b) -- every job whose include carries `outline_uv` -- and it is
  // armed by the geometry itself inside LatticeBoundary::add_include_region, not by a
  // caller, so there is no switch here to get wrong. What there IS here is the report:
  // a mask-backed include has no analytic distance and takes NO clip, so its struts are
  // bounded by the shell alone exactly as before, and that has to be said rather than
  // left for someone to notice in a mesh.
  {
    std::size_t inc_outlined = 0, inc_rect = 0, inc_mask = 0;
    for (const ClearanceGeometry& g : lattice_roles.includes) {
      if (!g.valid) continue;
      if (g.mask) ++inc_mask;
      else if (!g.outline_uv.empty()) ++inc_outlined;
      else ++inc_rect;
    }
    if (inc_outlined > 0 || inc_mask > 0)
      std::fprintf(stderr,
                   "[clip] include regions: %zu clipped to their own outline, %zu "
                   "analytic without one (no clip term), %zu mask-backed (no clip term, "
                   "shell only)\n",
                   inc_outlined, inc_rect, inc_mask);
    R.clip_includes_outlined = static_cast<long long>(inc_outlined);
    R.clip_includes_mask_backed = static_cast<long long>(inc_mask);
  }

  // ── THE certification mask — shared by the export (companion + graded cell
  // activation) and the posture. On a graded run it is intersected with the
  // law's own mask (voxels the law kept solid drop out; law-masked voxels the
  // shared predicate's cell-overlap proof rejects are counted, not hidden).
  // ★ ONE DEFINITION, SHARED WITH THE SIZE PROBE (reviewer, 2026-09-30). This was
  // five lines here, so the probe -- which exists to forecast this run -- synthesised
  // over the posture ALONE and worked on a strictly larger set. Both now call
  // lattice_synthesis_domain(); an empty posture means ungraded, which is the
  // behaviour the `if (graded)` guard used to express.
  long long dropped_by_overlap = 0;
  const std::vector<char> kNoPosture;
  std::vector<char> mask;
  // ── ★ K3: ON A PLAN JOB THE DESIGN SET IS THE PLAN'S CELLS ───────────────────
  // (Reviewer's ruling, 2026-10-10: the companion is printed minus the PLAN's cells,
  // and the certificate's posture comes from the PLAN's mask, never the law's.)
  //
  // This one mask is read by the solid companion, the graded-cell activation, the
  // certification posture, the min-feature pass, the void check and the empty-mask
  // refusal. On a plan job it used to be the LAW's: core graded the part its own way
  // and that decided which voxels the companion filled and which the certificate
  // credited, while the plan decided only where struts went. The two then disagreed in
  // both directions -- a voxel the plan latticed but the law kept solid got a strut AND
  // companion solid around it, and a voxel the law latticed but the plan left bare got
  // neither, which is the partial-depth strip: the plan's cells stop short of the
  // region's depth, the law latticed the remainder, so the strip came out as air with
  // the plan's back nodes ending on nothing.
  //
  // The predicate is the same one (printed, keep-out, exclude/include precedence, the
  // cell-overlap proof); only the owning-cell question is answered by the plan, at the
  // plan's own cell per voxel rather than at the law's single cell -- see
  // lattice_certification_mask_per_cell. A printed voxel inside the include union that
  // no plan cell covers is certified SOLID, exactly like a keep-out voxel, which is what
  // makes the companion fill the remainder.
  std::vector<std::vector<char>> plan_occ;        // per group, its own cell grid
  std::vector<std::vector<double>> plan_cell_rho;  // the sent rho on the same grid
  // ── ★ K3, RULING 1'S CONDITION (reviewer, 2026-10-10) ────────────────────────
  // THE POSTURE CERTIFIES A STRUT AT A DENSITY AND THE RADIUS FIELD DRAWS IT AT ONE,
  // AND THOSE MUST BE THE SAME NUMBER. The way to guarantee that is not two
  // implementations that agree: a number re-derived can agree with the law while
  // disagreeing with the geometry, which is the failure this whole section exists to
  // make impossible. So there is ONE definition and both callers use it; the assertion
  // further down is a tripwire ON that definition, not the mechanism that makes two of
  // them line up.
  //
  // `plan_cell_rho_at` is the plan's own answer: the rho of the cell that covers the
  // point, or 0 where no cell does. The plan's groups cannot overlap -- the validator
  // proves it -- so at most one can answer, and the search order cannot matter. The
  // per-group rho grid is built once below rather than scanned per point: a linear scan
  // of the cell list would be O(voxels x cells), which is 22,344 cells on 102117B9.
  //
  // ★ IT DELIBERATELY DOES NOT RESTRICT TO ONE GROUP. The radius field used to look only
  // in its OWN group's grid, so a strut reaching past its cell into a cell of another
  // group was sized from the voxel fallback while the posture credited that other cell's
  // rho. Same point, two densities. The density now belongs to the point.
  // ── ★ K5: AND THE CLOSED BOX, BECAUSE EVERY OCTET NODE SITS ON A BOUNDARY ────
  // `node_pos` is `origin + g * 0.5 * cell` (lattice_gen.cpp), so a node with an EVEN
  // index on an axis lies exactly ON a cell plane: a cell corner is shared by eight
  // cells, an edge node by four, a face node by two. The octet's face-diagonal struts
  // lie IN the cell faces, so their midpoints -- which is where the generator samples
  // the radius -- are on a shared plane too. Exact-boundary queries are the NORM here,
  // not an edge case.
  //
  // A half-open `floor` test therefore attributed every one of them to the cell on the
  // + side, and where that cell is outside the plan -- which is exactly the plan's outer
  // face, and every pass and group boundary -- the lookup found nothing and fell through
  // to core's own field. That is K5's defect: the boundary joints, the ones that carry
  // the load into the solid, were the ones the app's density did not reach.
  //
  // So the test is the CLOSED box, and where several of the plan's cells share the
  // point the density is the LARGEST of theirs. Not an ownership rule and deliberately
  // not one: a node ball thinner than a strut meeting it is a notch at the joint, so the
  // shared geometry has to satisfy every incident cell, and `max` is the only answer that
  // does and is independent of which cell is asked first.
  auto plan_cell_rho_at = [&plan_groups, &plan_occ, &plan_cell_rho](const Vec3& p) {
    double best = 0.0;
    for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
      const SteppedCellGroup& g = plan_groups[gi];
      const double tol = 1e-9 * g.size_mm;   // the grid is built as origin + k*size
      const double fx = (p.x - g.origin.x) / g.size_mm;
      const double fy = (p.y - g.origin.y) / g.size_mm;
      const double fz = (p.z - g.origin.z) / g.size_mm;
      const int bx = static_cast<int>(std::floor(fx));
      const int by = static_cast<int>(std::floor(fy));
      const int bz = static_cast<int>(std::floor(fz));
      // On a plane, the cell on the - side shares the point: test it too.
      const bool ex = std::fabs(fx - std::round(fx)) <= tol;
      const bool ey = std::fabs(fy - std::round(fy)) <= tol;
      const bool ez = std::fabs(fz - std::round(fz)) <= tol;
      for (int sx = 0; sx >= (ex ? -1 : 0); --sx)
        for (int sy = 0; sy >= (ey ? -1 : 0); --sy)
          for (int sz = 0; sz >= (ez ? -1 : 0); --sz) {
            const int ci = bx + sx, cj = by + sy, ck = bz + sz;
            if (ci < 0 || cj < 0 || ck < 0 || ci >= g.nx || cj >= g.ny || ck >= g.nz)
              continue;
            const std::size_t at = (static_cast<std::size_t>(ck) * g.ny + cj) * g.nx + ci;
            if (plan_occ[gi][at] && plan_cell_rho[gi][at] > best)
              best = plan_cell_rho[gi][at];
          }
    }
    return best;
  };
  // ── ★ WHICH REGION'S PLAN CELL COVERS A POINT ────────────────────────────────
  // The same walk as `plan_cell_rho_at`, answering the other half: the region id the
  // covering cell was sent under, or 0 where no cell covers. Ruling 2's receipt needs it
  // -- the volume the outline clip removes struts from is exactly the volume a region's
  // own plan cell covers but the region does NOT reach.
  auto plan_cell_region_at = [&plan_groups, &plan_occ](const Vec3& p) {
    for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
      const SteppedCellGroup& g = plan_groups[gi];
      const int ci = static_cast<int>(std::floor((p.x - g.origin.x) / g.size_mm));
      const int cj = static_cast<int>(std::floor((p.y - g.origin.y) / g.size_mm));
      const int ck = static_cast<int>(std::floor((p.z - g.origin.z) / g.size_mm));
      if (ci < 0 || cj < 0 || ck < 0 || ci >= g.nx || cj >= g.ny || ck >= g.nz) continue;
      const std::size_t at = (static_cast<std::size_t>(ck) * g.ny + cj) * g.nx + ci;
      if (plan_occ[gi][at]) return g.region_id;
    }
    return 0;
  };
  // Which voxel of the solved grid holds a point (clamped, as every field here does).
  auto plan_voxel_of = [&solved_grid](const Vec3& p) {
    auto cl = [](int v, int hi) { return v < 0 ? 0 : (v > hi ? hi : v); };
    return solved_grid.index(
        cl(static_cast<int>(std::floor((p.x - solved_grid.origin.x) / solved_grid.spacing)),
           solved_grid.nx - 1),
        cl(static_cast<int>(std::floor((p.y - solved_grid.origin.y) / solved_grid.spacing)),
           solved_grid.ny - 1),
        cl(static_cast<int>(std::floor((p.z - solved_grid.origin.z) / solved_grid.spacing)),
           solved_grid.nz - 1));
  };
  // ── ★ THE DENSITY A STRUT IS DRAWN AT, ANYWHERE ──────────────────────────────
  // The plan's cell where one covers the point; off the plan's cells (a strut reaching
  // past its own cell's box) the posture's value at that voxel, which on a plan job IS
  // this function's answer at that voxel's centre -- so the fallback is self-consistent
  // rather than a second rule. Outside the mask it is the band floor, as before; those
  // voxels are not certified, so no posture value applies to them.
  // ── ★ K5: AND THE REACH IS COUNTED, NOT CLAIMED ──────────────────────────────
  // Every radius query the generator makes lands in one of three places. The third is
  // the one that must not happen on a plan that sent a rho with every cell: a strut or a
  // node sized at core's BAND FLOOR, which is the thinnest the law allows, where the
  // plan asked for something else. The generator is single-threaded (no parallel
  // construct in lattice_gen.cpp), so plain counters are sound here.
  long long rho_q_plan = 0, rho_q_posture = 0, rho_q_floor = 0;
  auto plan_strut_rho_at = [&plan_cell_rho_at, &plan_voxel_of, &mask, &gf, &rho_q_plan,
                            &rho_q_posture, &rho_q_floor](const Vec3& p) {
    const double cell = plan_cell_rho_at(p);
    if (cell > 0.0) { ++rho_q_plan; return cell; }
    const std::size_t e = plan_voxel_of(p);
    if (e < mask.size() && mask[e] && e < gf.posture.relative_density.size()) {
      ++rho_q_posture;
      return gf.posture.relative_density[e];
    }
    ++rho_q_floor;
    return gf.band_rho_min;
  };
  // ── ★ K4: WHICH PLAN CELL AN EMITTED ELEMENT BELONGS TO ──────────────────────
  // For the ledger, one element must land on exactly ONE cell -- unlike the density,
  // where a shared node takes the max of its sharers. Every octet node sits on a cell
  // plane, so the closed box finds several; the tally takes the lex-smallest sharer that
  // is in the plan (group index, then k, j, i). Deterministic, and every element that
  // touches the plan is attributed rather than filed as "unattributed".
  // Returns false when no plan cell shares the point at all.
  auto plan_cell_slot_at = [&plan_groups, &plan_occ](const Vec3& p, std::size_t* gout,
                                                     std::size_t* cout) {
    for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
      const SteppedCellGroup& g = plan_groups[gi];
      const double tol = 1e-9 * g.size_mm;
      const double fx = (p.x - g.origin.x) / g.size_mm;
      const double fy = (p.y - g.origin.y) / g.size_mm;
      const double fz = (p.z - g.origin.z) / g.size_mm;
      const int bx = static_cast<int>(std::floor(fx));
      const int by = static_cast<int>(std::floor(fy));
      const int bz = static_cast<int>(std::floor(fz));
      const bool ex = std::fabs(fx - std::round(fx)) <= tol;
      const bool ey = std::fabs(fy - std::round(fy)) <= tol;
      const bool ez = std::fabs(fz - std::round(fz)) <= tol;
      for (int sz = (ez ? -1 : 0); sz <= 0; ++sz)
        for (int sy = (ey ? -1 : 0); sy <= 0; ++sy)
          for (int sx = (ex ? -1 : 0); sx <= 0; ++sx) {
            const int ci = bx + sx, cj = by + sy, ck = bz + sz;
            if (ci < 0 || cj < 0 || ck < 0 || ci >= g.nx || cj >= g.ny || ck >= g.nz)
              continue;
            const std::size_t at = (static_cast<std::size_t>(ck) * g.ny + cj) * g.nx + ci;
            if (!plan_occ[gi][at]) continue;
            // The cells list is ascending, so find this cell's index in it.
            for (std::size_t n = 0; n < g.cells.size(); ++n)
              if (g.cells[n][0] == ci && g.cells[n][1] == cj && g.cells[n][2] == ck) {
                *gout = gi;
                *cout = n;
                return true;
              }
          }
    }
    return false;
  };
  // ── ★ K6 PART 2: ONE BOUNDARY PER REGION, CLIPPED TO WHAT THAT REGION OWNS ───
  // Where two include prisms overlap, both regions' passes used to lay a lattice through
  // the shared volume and the file carried two. Each region gets its own boundary,
  // clipped by the owner rule (clip_to_owned_region), and its passes point at that.
  //
  // ★ A DEQUE, AND AT THIS SCOPE ON PURPOSE. `stepped_passes` holds raw pointers into
  // these objects and outlives the block that builds them; an earlier cut declared them
  // inside that block and the generator read freed memory. A deque rather than a vector
  // because the pointers must stay valid as regions are added. Declared HERE, above the
  // ledger's classifier, because that classifier asks the pass's own boundary whether
  // the cell could overlap at all.
  std::deque<LatticeBoundary> owned_boundaries;
  std::map<int, const LatticeBoundary*> owned_boundary_for;

  // ── ★ WHY A PLAN CELL GOT NO STRUT (reviewer's ruling 3, 2026-10-11) ─────────
  // "152 of 4,198 cells have no strut" is a count, not a diagnosis, and the reviewer is
  // right that any cell the PICTURE draws and core leaves empty is a mismatch. These are
  // the causes core can actually distinguish, tested in this order so each cell is filed
  // once, under the FIRST thing that would have stopped it:
  //
  //   outside_rect     the centre is outside the region's in-plane rectangle;
  //   beyond_depth     in-plane but outside [0, depth] along the face normal;
  //   outside_outline  inside the rectangle and the depth, but outside `outline_uv` --
  //                    this is ruling 2's clip, and it is the app's outline deciding;
  //   owned_elsewhere  inside this region, but another region owns the centre (K6);
  //   no_material      inside and owned, but the optimizer left no printed material, or
  //                    the final mask does not lattice it (the outline beam's band lands
  //                    here, since it clears the mask);
  //   never_generated  none of the above. The cell is inside, owned, printed and masked,
  //                    and the generator still put nothing in it. THIS is the mismatch;
  //                    every other row has a reason the app can see.
  //
  // Each test is core's own exported predicate, not a re-derivation: the containment is
  // point_in_clearance_region, the outline is point_in_clearance_outline, the owner is
  // stepped_region_owner.
  enum class NoStrutCause { OutsideRect, BeyondDepth, OutsideOutline, OwnedElsewhere,
                            NoMaterial, CellOverlapDropped, NeverGenerated };
  auto classify_no_strut = [&](int region_id, const Vec3& centre, double size_mm) {
    const ClearanceGeometry* R = nullptr;
    for (std::size_t i = 0; i < lattice_roles.includes.size(); ++i) {
      const ClearanceGeometry& g = lattice_roles.includes[i];
      const int id = g.declared_region_id > 0 ? g.declared_region_id
                                              : static_cast<int>(i) + 1;
      if (g.valid && id == region_id) { R = &g; break; }
    }
    if (R == nullptr) return NoStrutCause::OutsideRect;   // no such region: not ours
    const Vec3 d{centre.x - R->origin.x, centre.y - R->origin.y, centre.z - R->origin.z};
    const double nl = std::sqrt(R->normal.x * R->normal.x + R->normal.y * R->normal.y +
                                R->normal.z * R->normal.z);
    const double sdep = nl > 0.0 ? (d.x * R->normal.x + d.y * R->normal.y +
                                    d.z * R->normal.z) / nl
                                 : 0.0;
    const double du = d.x * R->u.x + d.y * R->u.y + d.z * R->u.z;
    const double dw = d.x * R->w.x + d.y * R->w.y + d.z * R->w.z;
    if (!(du >= R->u_lo && du <= R->u_hi && dw >= R->w_lo && dw <= R->w_hi))
      return NoStrutCause::OutsideRect;
    if (nl > 0.0 && !(sdep >= 0.0 && sdep <= R->depth))
      return NoStrutCause::BeyondDepth;
    if (!point_in_clearance_outline(*R, du, dw)) return NoStrutCause::OutsideOutline;
    if (stepped_region_owner(centre, lattice_roles.includes) != region_id)
      return NoStrutCause::OwnedElsewhere;
    // ── ★ MATERIAL AND MASK, ON THE CELL'S OWN VOXELS ────────────────────────
    // Voxels whose CENTRE lies inside the cell's box, and where the cell is smaller
    // than a voxel and so contains no centre, the voxel the cell's own centre sits in.
    //
    // ★ MEASURED WRONG FIRST, and it mattered. The first cut took a +/-1 voxel
    // neighbourhood, which for 68BF7B74's 2.578 mm cells on a 3.411 mm grid is a 10.2 mm
    // box -- sixteen times the cell -- so `any_masked` was true almost everywhere and
    // `no_material` almost never fired. 645 and 965 cells on that project's two arms
    // came out as `never_generated`, i.e. as core's fault, when the question had simply
    // been asked of the wrong voxels. A classifier that over-reaches reports its own
    // reach as a defect.
    bool any_masked = false;
    const Vec3 lo{centre.x - 0.5 * size_mm, centre.y - 0.5 * size_mm,
                  centre.z - 0.5 * size_mm};
    const Vec3 hi{centre.x + 0.5 * size_mm, centre.y + 0.5 * size_mm,
                  centre.z + 0.5 * size_mm};
    auto vox_of = [&](double x, double o) {
      return static_cast<int>(std::floor((x - o) / solved_grid.spacing));
    };
    const int i0 = vox_of(lo.x, solved_grid.origin.x), i1 = vox_of(hi.x, solved_grid.origin.x);
    const int j0 = vox_of(lo.y, solved_grid.origin.y), j1 = vox_of(hi.y, solved_grid.origin.y);
    const int k0 = vox_of(lo.z, solved_grid.origin.z), k1 = vox_of(hi.z, solved_grid.origin.z);
    bool held_a_centre = false;
    for (int k = k0; k <= k1 && !any_masked; ++k)
      for (int j = j0; j <= j1 && !any_masked; ++j)
        for (int i = i0; i <= i1 && !any_masked; ++i) {
          if (i < 0 || j < 0 || k < 0 || i >= solved_grid.nx || j >= solved_grid.ny ||
              k >= solved_grid.nz)
            continue;
          const Vec3 vc{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                        solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                        solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
          if (vc.x < lo.x || vc.x > hi.x || vc.y < lo.y || vc.y > hi.y ||
              vc.z < lo.z || vc.z > hi.z)
            continue;                       // that voxel's centre is not in this cell
          held_a_centre = true;
          const std::size_t e = solved_grid.index(i, j, k);
          if (e < mask.size() && mask[e]) any_masked = true;
        }
    if (!held_a_centre) {
      // A cell smaller than a voxel holds no voxel centre at all: ask the voxel its own
      // centre sits in, which is the voxel every other reader of this cell uses.
      const int i = vox_of(centre.x, solved_grid.origin.x);
      const int j = vox_of(centre.y, solved_grid.origin.y);
      const int k = vox_of(centre.z, solved_grid.origin.z);
      if (i >= 0 && j >= 0 && k >= 0 && i < solved_grid.nx && j < solved_grid.ny &&
          k < solved_grid.nz) {
        const std::size_t e = solved_grid.index(i, j, k);
        any_masked = e < mask.size() && mask[e] != 0;
      }
    }
    if (!any_masked) return NoStrutCause::NoMaterial;
    // ── ★ AND CORE'S OWN CELL-OVERLAP PROOF ──────────────────────────────────
    // `cell_may_overlap` is the generator's activation test: a cell whose box provably
    // misses the allowed region is dropped WHOLE, before any strut is considered. That
    // is a core decision, not a plan one, and it has to be told apart from "inside,
    // owned, printed, masked and still empty" -- which is the only row that is a real
    // mismatch. Measured first without this test: 647 and 971 cells on 68BF7B74's two
    // arms came out as `never_generated`, which was true but useless.
    //
    // Asked on the boundary the PASS used -- the region's own owner-clipped copy where
    // K6 built one -- so the answer is the one the generator acted on and not an
    // approximation of it.
    {
      const Vec3 cmin{centre.x - 0.5 * size_mm, centre.y - 0.5 * size_mm,
                      centre.z - 0.5 * size_mm};
      auto ob = owned_boundary_for.find(region_id);
      const LatticeBoundary& B =
          ob != owned_boundary_for.end() ? *ob->second : boundary;
      if (!B.cell_may_overlap(cmin, size_mm)) return NoStrutCause::CellOverlapDropped;
    }
    return NoStrutCause::NeverGenerated;
  };
  // Per group, per cell (in the group's own ascending order): what the generator laid
  // there. Filled by the tap below, which fires once per emitted element.
  std::vector<std::vector<long long>> plan_laid_struts, plan_laid_nodes;
  long long plan_laid_unattributed = 0;
  // Where the plan left a voxel's density to core's own grading, per voxel -- so the
  // receipt can count the fallbacks PER REGION rather than leave them silent. A plan
  // that sent a rho with every cell shows 0 on every region.
  std::vector<char> plan_rho_from_law_flag;
  if (!plan_groups.empty()) {
    plan_occ.resize(plan_groups.size());
    plan_cell_rho.resize(plan_groups.size());
    for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
      const SteppedCellGroup& g = plan_groups[gi];
      const std::size_t n = static_cast<std::size_t>(g.nx) * g.ny * g.nz;
      plan_occ[gi].assign(n, 0);
      plan_cell_rho[gi].assign(n, 0.0);
      for (std::size_t ci = 0; ci < g.cells.size(); ++ci) {
        const std::array<int, 3>& c = g.cells[ci];
        const std::size_t at = (static_cast<std::size_t>(c[2]) * g.ny + c[1]) * g.nx + c[0];
        plan_occ[gi][at] = 1;
        if (ci < g.rho.size()) plan_cell_rho[gi][at] = g.rho[ci];
      }
    }
    plan_laid_struts.resize(plan_groups.size());
    plan_laid_nodes.resize(plan_groups.size());
    for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
      plan_laid_struts[gi].assign(plan_groups[gi].cells.size(), 0);
      plan_laid_nodes[gi].assign(plan_groups[gi].cells.size(), 0);
    }
    const std::vector<SteppedCellGroup>& pg = plan_groups;
    const std::vector<std::vector<char>>& po = plan_occ;
    mask = lattice_certification_mask_per_cell(
        boundary, solved_grid, dens, printed_iso,
        [&pg, &po](const Vec3& c, Vec3* cell_min, double* ce) {
          for (std::size_t gi = 0; gi < pg.size(); ++gi) {
            const SteppedCellGroup& g = pg[gi];
            const int ci = static_cast<int>(std::floor((c.x - g.origin.x) / g.size_mm));
            const int cj = static_cast<int>(std::floor((c.y - g.origin.y) / g.size_mm));
            const int ck = static_cast<int>(std::floor((c.z - g.origin.z) / g.size_mm));
            if (ci < 0 || cj < 0 || ck < 0 || ci >= g.nx || cj >= g.ny || ck >= g.nz)
              continue;
            if (!po[gi][(static_cast<std::size_t>(ck) * g.ny + cj) * g.nx + ci])
              continue;
            *cell_min = Vec3{g.origin.x + ci * g.size_mm, g.origin.y + cj * g.size_mm,
                             g.origin.z + ck * g.size_mm};
            *ce = g.size_mm;
            return true;
          }
          return false;   // no cell of the plan covers it: certified SOLID
        },
        &dropped_by_overlap);
    plan_mask = mask;
    // ── ★ K3 (2): THE POSTURE IS THE PLAN'S, DENSITY AND ALL ────────────────────
    // A mask without its density is half a posture. Measured on 570B38E2's Default
    // Grade plan: with the plan's mask alone the run reached the certificate and
    // `analyze_fixed_design` refused -- "lattice relative density 0.000000 is outside
    // the certifiable octet band" -- because the density still came from the LAW, which
    // had graded none of the voxels the plan latticed. So the certificate was being
    // asked to credit the plan's struts at the law's density, and where the law kept a
    // voxel solid that density is 0.
    //
    // The plan sends a rho PER CELL (ruling C), and that rho is what sizes the strut the
    // run actually lays (the pass radius field reads it). The posture now reads the same
    // number, so the certificate credits the geometry that was emitted rather than a
    // second opinion about it. A cell that sent no rho -- every job written before that
    // ruling -- falls back to the law's density for its voxels, exactly as the radius
    // field does.
    //
    // This is the same substitution the organic path makes a few hundred lines below
    // ("the posture the certification consumes is now the TRACED one"): the algorithm
    // that laid the geometry down owns the posture, and nothing downstream branches.
    std::vector<double> plan_rho(solved_grid.voxel_count(), 0.0);
    plan_rho_from_law_flag.assign(solved_grid.voxel_count(), 0);
    long long plan_rho_from_plan = 0, plan_rho_from_law = 0, plan_rho_absent = 0;
    for (std::size_t e = 0; e < plan_rho.size(); ++e) {
      if (!mask[e]) continue;
      const int i = static_cast<int>(e % static_cast<std::size_t>(solved_grid.nx));
      const int j = static_cast<int>((e / solved_grid.nx) % static_cast<std::size_t>(solved_grid.ny));
      const int k = static_cast<int>(e / (static_cast<std::size_t>(solved_grid.nx) * solved_grid.ny));
      const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                   solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                   solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
      const double rho = plan_cell_rho_at(c);   // ★ the ONE definition, above
      if (rho > 0.0) { plan_rho[e] = rho; ++plan_rho_from_plan; continue; }
      if (graded && e < gf.posture.relative_density.size() &&
          gf.posture.relative_density[e] > 0.0) {
        plan_rho[e] = gf.posture.relative_density[e];
        plan_rho_from_law_flag[e] = 1;
        ++plan_rho_from_law;
        continue;
      }
      // ★ Finding 7: the law graded it, and only the swept plan's cover rule (a cell this
      // plan does not lay) kept it solid.
      if (graded && e < gf.cover_dropped_rho.size() && gf.cover_dropped_rho[e] > 0.0) {
        plan_rho[e] = gf.cover_dropped_rho[e];
        plan_rho_from_law_flag[e] = 1;
        ++plan_rho_from_law;
        continue;
      }
      ++plan_rho_absent;
    }
    // A can't-happen still refuses, and names what it refuses (the standing rule). A
    // latticed voxel with no density on either side would reach the certificate as a
    // zero and be refused there, by a sentence about the octet band that says nothing
    // about the plan.
    if (plan_rho_absent > 0)
      throw JobError(
          "lattice \"stepped_cells\": " + std::to_string(plan_rho_absent) +
          " of the " + std::to_string(plan_rho_from_plan + plan_rho_from_law +
                                      plan_rho_absent) +
          " voxel(s) this plan lattices have no relative density on either side -- the "
          "plan sent no \"rho\" for the cell that covers them and core's own grading "
          "kept them solid, so there is no number to size the strut from or to certify "
          "it at. Send a \"rho\" with every cell (the app's own demand map is what the "
          "preview drew the struts from), or state a grading the law can apply here.");
    gf.posture.mask = plan_mask;
    gf.posture.relative_density = plan_rho;
    std::fprintf(stderr,
                 "[stepped] plan posture: %lld voxel(s) at the plan's own rho, %lld at "
                 "the law's (cells that sent none), %lld covered voxel(s) dropped by the "
                 "cell-overlap proof\n",
                 plan_rho_from_plan, plan_rho_from_law, dropped_by_overlap);
  } else {
    mask = lattice_synthesis_domain(
        boundary, solved_grid, dens, printed_iso, solved_grid.origin, cell,
        graded ? gf.posture.mask : kNoPosture, &dropped_by_overlap);
  }
  // ── ★ GRADE TO SOLID AT THE OUTLINE, for organic (see organic_solid_rim_band) ──
  // ★★ THE BAND IS COMPUTED HERE AND APPLIED AFTER THE TRACER (ruling G). It used to be
  // cleared from the mask on this line, which took it out of the tracer's candidates and
  // cut every strut back at the band's inner face. The preview keeps it as candidate, so
  // its curves run THROUGH the band and weld into the solid. Tracing with the band IN and
  // turning it solid afterwards makes the run draw what the picture shows.
  std::vector<char> organic_rim_band;
  if (graded && R.algorithm == LatticeAlgorithm::Organic) {
    const double rim = job.grading.organic_solid_rim_mm < 0.0
                           ? job.grading.cell_min_mm : job.grading.organic_solid_rim_mm;
    std::vector<Vec3> nrms;
    for (const JobLatticeRegion& r : job.lattice.regions)
      if (r.role == "include") nrms.push_back(r.normal);
    R.organic_solid_rim_mm = rim;
    organic_rim_band =
        organic_solid_rim_band(solved_grid, mask, region_ids_for_stepped, nrms, rim);
    std::size_t band_voxels = 0;
    for (char c : organic_rim_band) band_voxels += c ? 1 : 0;
    R.organic_solid_rim_voxels = static_cast<long long>(band_voxels);
    if (std::getenv("TOPOPT_ORGANIC_TRACE"))
      std::fprintf(stderr,
                   "[rim] SOLID_RIM %.3g mm: %lld voxel(s) in the band, KEPT as tracer "
                   "candidates and turned solid after the trace\n",
                   rim, R.organic_solid_rim_voxels);
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
    const std::vector<double> organic_stress = stress_tensor_for_organic(
        job, solved_grid, mask, region_ids_for_stepped, v.stress_tensor_field,
        &R.organic_synthetic);
    // ★ RULING H: mark the voxels of every region that was synthesised WHOLE, so the
    // spacing window can leave them out of its statistics and hand them the middle.
    const std::vector<char> synth_whole = organic_synthesised_whole_voxels(
        R.organic_synthetic, region_ids_for_stepped, solved_grid.voxel_count());
    organic = run_organic_step(lattice_shell_written(job.lattice),
                               solved_grid, dens, organic_stress, mask,
                               gf.posture.relative_density, gf.band_rho_min,
                               gf.band_rho_max, job.grading,
                               job.loads.present && job.loads.minimize_plastic,
                               v.applied_build_dir, printed_iso, 32,
                               job.loads.layer_height_mm, false, &synth_whole);
    // ★ THE WELD'S RASTER PITCH, so the generator can refuse to emit a base mat too
    // thin for that raster to KEEP. Set beside the layer height below for the same
    // reason: both are machine facts the generator cannot infer, and without this one
    // a mat under a voxel tall is erased silently — which is how a deliberately
    // thinned mat vanished from the slice entirely while every stat still read green.
    // ★★ AND NOW THE BAND BECOMES SOLID (ruling G). The tracer has run with it IN, so the
    // curves cross it and end inside what is about to be solid material -- welded, as the
    // preview draws them. It leaves the lattice set here so the band PRINTS solid and the
    // posture and certificate see solid, which is what the band is for. Both of the
    // band's jobs are done; they simply happen in the right order now.
    if (!organic_rim_band.empty()) {
      const std::size_t cleared = clear_band_from_mask(mask, organic_rim_band);
      clear_band_from_mask(organic.lat.mask, organic_rim_band);
      for (std::size_t e = 0; e < organic_rim_band.size() &&
                              e < organic.lat.relative_density.size(); ++e)
        if (organic_rim_band[e]) organic.lat.relative_density[e] = 0.0;
      if (std::getenv("TOPOPT_ORGANIC_TRACE"))
        std::fprintf(stderr,
                     "[rim] band applied AFTER the trace: %zu voxel(s) left the lattice "
                     "set and print solid; the curves that crossed them are embedded\n",
                     cleared);
    }
    organic.lat.weld_pitch_hint_mm = job.lattice.welded_pitch_mm;
    // ★ THE LAYER HEIGHT THE MACHINE WILL ACTUALLY USE. The mid-air-start check
    // rasters Z at this pitch; without it the check is COARSER THAN THE PRINTER
    // and passes parts that float for two real layers. 0 = not stated, and the
    // check says so on the receipt rather than inferring one.
    organic.lat.layer_height_mm = job.loads.layer_height_mm;
    // printability repairs: stated, or they do not run (see OrganicLattice)
    organic.lat.base_mat = job.grading.organic_base_mat;
    organic.lat.fill_mat = job.grading.organic_fill_mat;
    organic.lat.trim_below_base = job.grading.organic_trim_below_base;
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
    R.organic_shape_fit_on = job.grading.organic_shape_fit;
    R.organic_shape_fit_candidates = static_cast<long long>(organic.shape_fit_candidates);
    R.organic_shape_fit_voxels_shrunk = static_cast<long long>(organic.shape_fit_voxels_shrunk);
    R.organic_shape_fit_min_ratio = organic.shape_fit_min_ratio;
    R.organic_trace_seconds = organic.trace_seconds;
    // ★ THE GEOMETRY PATH REBUILDS A BARE OrganicOutcome FOR THE RECEIPT (see the
    // `tmp` below), so the growth counters cannot ride there — they travel on the
    // export outcome, which survives to the receipt intact.
    R.oc.growth = organic.growth;
    R.oc.growth_ran = organic.growth_ran;
    // The posture the certification consumes is now the TRACED one.
    gf.posture.mask = organic.lat.mask;
    gf.posture.relative_density = organic.lat.relative_density;
    // ★ AND "TRACED" MEANS BEFORE THE TRIM PASSES, WHICH IS NOT A FREE CHOICE. This
    // density is the tracer's own snapshot; the clip to the part, the node merge, the
    // support pass, the prune, the stranded drop, the finish and the base trim all run
    // AFTERWARDS and on a SEPARATE span list (`organic_spans`, "the POST-CLIP spans...
    // rather than the traced intent"), so nothing refreshes it. Whatever those passes
    // remove, the certificate still believes is there. The volume it implies is printed
    // here so it can be compared with the shipped file's own -- measured on the M2 stand,
    // and the gap is a third of the material.
    {
      double cert_vol = 0.0;
      const double vox = solved_grid.spacing * solved_grid.spacing * solved_grid.spacing;
      for (std::size_t e = 0; e < gf.posture.relative_density.size(); ++e)
        if (e < gf.posture.mask.size() && gf.posture.mask[e])
          cert_vol += gf.posture.relative_density[e];
      organic_traced_material_mm3 = cert_vol * vox;
    }
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

  // ── ★ RULING B: THE SOLID OUTLINE BEAM (brief §1.5) ────────────────────────
  // Organic grades to solid at the outline through organic_solid_rim_mm; with the
  // shape grade on, the octet does the same thing with a beam whose width is DERIVED
  // (lattice_outline_beam_mm) rather than stated, so the preview and the run cannot
  // hold different numbers for it. The beam is centred on the outline, so it reaches
  // beam/2 inward, plus the bleed at a wide band.
  //
  // The band walk is the one organic already uses: a 6-connected flood inward from
  // every lattice voxel that has a non-lattice neighbour IN THE FACE PLANE. On a voxel
  // grid that IS a true parallel offset of the outline, and unlike a polygon offset it
  // cannot self-overlap at a corner -- which is the property §1.5 asks for.
  // ── ★ D10/E3: WHAT THE GRADE LEFT, counted BEFORE anything downstream clears it ──
  // `region_ungradeable` above answers "could the law lattice anything at all". It runs
  // BEFORE the outline beam, and the beam can take every voxel the law kept. Keeping the
  // count here is what lets the refusal below name which of the two emptied the mask,
  // instead of blaming the grade for the beam's work.
  std::size_t latticed_after_grade = 0;
  if (graded)
    for (char m : mask)
      if (m) ++latticed_after_grade;

  // ★ E3: THE SHAPE GRADE PER REGION. A region's own switch and band replace the
  // part's for the voxels it owns (e3_owner); a voxel no region owns keeps the part's.
  // When no region states one, `e3_shape` is false and the block below is the part-wide
  // beam, byte for byte.
  bool e3_shape = false;
  for (const JobLatticeRegion& r : e3_jobs)
    if (r.shape_grade >= 0 || r.shape_grade_band_mm >= 0.0) e3_shape = true;
  auto shape_on = [&](int id) {
    if (id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size() &&
        e3_jobs[static_cast<std::size_t>(id - 1)].shape_grade >= 0)
      return e3_jobs[static_cast<std::size_t>(id - 1)].shape_grade == 1;
    return job.grading.shape_grade;
  };
  auto band_of = [&](int id) {
    if (id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size() &&
        e3_jobs[static_cast<std::size_t>(id - 1)].shape_grade_band_mm >= 0.0)
      return e3_jobs[static_cast<std::size_t>(id - 1)].shape_grade_band_mm;
    return job.grading.shape_grade_band_mm;
  };
  // ★ (d), ruling 11-06: where the lattice belongs to no region -- a lattice with no
  // include regions, or lattice.whole_part's -- the outline is the part's own surface, so
  // the walk seeds those voxels from it. Not otherwise: a voxel no prism owns inside a
  // job with includes (a "region"-kind include) has a face this walk cannot see.
  const bool part_outline = e3_jobs.empty() || job.lattice.whole_part;
  bool any_shape = job.grading.shape_grade;
  if (e3_shape)
    for (std::size_t i = 0; i < e3_jobs.size(); ++i)
      if (shape_on(static_cast<int>(i) + 1)) any_shape = true;
  // ★ ruling 2: the solid outline beam is STEPPED's alone now; the doubled lattice's
  // shape grade is the band grade_lattice built (band_* above).
  const bool beam_algorithm = R.algorithm == LatticeAlgorithm::Stepped;
  if (graded && beam_algorithm && e3_shape && any_shape) {
    const double beam =
        lattice_outline_beam_mm(job.grading.min_extrudable_width_mm, solved_grid.spacing);
    // The walk seeds from each region's own face plane, so it reads the E3 owner map
    // and the E3 regions' normals (the includes, or lattice.whole_part's regions).
    std::vector<Vec3> nrms;
    for (const JobLatticeRegion& r : e3_jobs) nrms.push_back(r.normal);
    // One band walk per distinct band width, each kept only where the owning region
    // (or the part, where none owns the voxel) has the shape grade on at that width.
    std::vector<double> widths;
    auto want = [&](std::size_t e) {
      const int id = e < e3_owner.size() ? e3_owner[e] : 0;
      return shape_on(id) ? band_of(id) : -1.0;
    };
    for (std::size_t e = 0; e < mask.size(); ++e)
      if (mask[e]) {
        const double b = want(e);
        if (b >= 0.0 && std::find(widths.begin(), widths.end(), b) == widths.end())
          widths.push_back(b);
      }
    std::vector<char> beam_band(mask.size(), 0);
    double inward_max = 0.0, bleed_max = 0.0;
    for (const double b : widths) {
      const double bleed = lattice_outline_bleed_mm(b);
      const double inward = beam + bleed;
      inward_max = std::max(inward_max, inward);
      bleed_max = std::max(bleed_max, bleed);
      const std::vector<char> band = organic_solid_rim_band(
          solved_grid, mask, e3_owner, nrms, inward, part_outline);
      for (std::size_t e = 0; e < band.size(); ++e)
        if (band[e] && want(e) == b) beam_band[e] = 1;
    }
    const std::size_t cleared = clear_band_from_mask(mask, beam_band);
    clear_band_from_mask(gf.posture.mask, beam_band);
    for (std::size_t e = 0; e < beam_band.size() &&
                            e < gf.posture.relative_density.size(); ++e)
      if (beam_band[e]) gf.posture.relative_density[e] = 0.0;
    R.outline_beam_mm = beam;
    R.outline_bleed_mm = bleed_max;
    R.outline_beam_voxels = static_cast<long long>(cleared);
    R.outline_inward_mm = inward_max;
    std::fprintf(stderr,
                 "[outline] per region: solid beam %.4f mm, up to %.4f mm inward over %zu "
                 "band width(s) | %zu voxel(s) turned solid\n",
                 beam, inward_max, widths.size(), cleared);
  } else if (graded && beam_algorithm && !e3_shape && job.grading.shape_grade) {
    const double beam =
        lattice_outline_beam_mm(job.grading.min_extrudable_width_mm, solved_grid.spacing);
    const double bleed = lattice_outline_bleed_mm(job.grading.shape_grade_band_mm);
    // ★ THE DEPTH, SETTLED BY THE APP'S OWN ALGEBRA (2026-09-20). The beam is a
    // ribbon lying 0..beam INWARD from the outline -- not centred on it, which is what
    // this assumed first -- and the bleed is solid fill laid over 0..beam+bleed on top
    // of the lattice. §1.5's dRegion line SHRINKS the latticed set to >= beam/2; it
    // does not extend it. So the printed union is
    //
    //     solid(0 .. beam+bleed)  U  lattice(>= beam/2)
    //   = solid(0 .. beam+bleed)  U  lattice(>= beam+bleed)
    //
    // because the solid covers everything between. The lattice the preview draws
    // inside the ribbon is BURIED, and burying it changes nothing that prints. Which
    // means core needs no separate strut clip at all: clipping the lattice at
    // beam+bleed -- which is what taking these voxels out of the mask does -- yields
    // the same union the preview yields, and certifies the same object. The app's
    // words: "Either certifies the same union."
    const double inward = beam + bleed;
    std::vector<Vec3> nrms;
    for (const JobLatticeRegion& r : job.lattice.regions)
      if (r.role == "include") nrms.push_back(r.normal);
    const std::vector<char> beam_band = organic_solid_rim_band(
        solved_grid, mask, region_ids_for_stepped, nrms, inward, part_outline);
    const std::size_t cleared = clear_band_from_mask(mask, beam_band);
    clear_band_from_mask(gf.posture.mask, beam_band);
    for (std::size_t e = 0; e < beam_band.size() &&
                            e < gf.posture.relative_density.size(); ++e)
      if (beam_band[e]) gf.posture.relative_density[e] = 0.0;
    // ── ★ THE BAND'S OWN VOXELS, EXPORTED (reviewer's ruling 4a, 2026-10-10) ────
    // #354 is measuring how many of these lie inside the PREVIEW's solid band, and the
    // two bands are not the same width: the formula takes the VOXEL, and the two sides
    // have different voxels (1.719 mm in the preview, 3.411 mm here on 570B38E2). It
    // needs the centres to do that, so here they are -- behind an env var, like every
    // other diagnostic dump in this file, because it is evidence and not an output.
    //
    // ★ AND IT STATES max_steps, which is the defect: `floor(inward / spacing)` is 0 on
    // his grid, so the flood never advances and the band is the SEED LAYER -- one voxel,
    // 3.4106 mm, where the rule computes 2.0553. Every width from just above 0 to one
    // whole voxel gives the same band, so the derived number has no effect on his part.
    if (const char* bp = std::getenv("TOPOPT_BEAM_BAND_DUMP")) {
      std::ofstream bf(bp);
      if (bf) {
        bf.setf(std::ios::fmtflags(0), std::ios::floatfield);
        bf.precision(10);
        bf << "# the outline beam's band, as core applies it\n"
           << "# GRID <origin.x> <origin.y> <origin.z> <spacing> <nx> <ny> <nz>\n"
           << "# RULE <bead_mm> <voxel_mm> <band_mm> <beam_mm> <bleed_mm> <inward_mm> "
              "<max_steps>\n"
           << "#   beam = max(2*bead, clamp(0.35*voxel, 0.10, 0.35) + 0.5*voxel)\n"
           << "#   bleed = band >= 25 ? 0.5*(band-15) : 0      inward = beam + bleed\n"
           << "#   max_steps = floor(inward/spacing): 0 means the band is the SEED LAYER\n"
           << "#   (lattice voxels with a non-lattice 6-neighbour IN the face plane,\n"
           << "#    |dir.normal| < 0.5; the two directions along the normal are exempt)\n"
           << "# BAND <i> <j> <k> <cx> <cy> <cz> <region_id>   centres in model mm\n";
        bf << "GRID " << solved_grid.origin.x << ' ' << solved_grid.origin.y << ' '
           << solved_grid.origin.z << ' ' << solved_grid.spacing << ' '
           << solved_grid.nx << ' ' << solved_grid.ny << ' ' << solved_grid.nz << '\n';
        bf << "RULE " << job.grading.min_extrudable_width_mm << ' '
           << solved_grid.spacing << ' ' << job.grading.shape_grade_band_mm << ' '
           << beam << ' ' << bleed << ' ' << inward << ' '
           << static_cast<int>(std::floor(inward / solved_grid.spacing + 1e-9)) << '\n';
        std::size_t wrote = 0;
        for (int k = 0; k < solved_grid.nz; ++k)
          for (int j = 0; j < solved_grid.ny; ++j)
            for (int i = 0; i < solved_grid.nx; ++i) {
              const std::size_t e = solved_grid.index(i, j, k);
              if (e >= beam_band.size() || !beam_band[e]) continue;
              bf << "BAND " << i << ' ' << j << ' ' << k << ' '
                 << (solved_grid.origin.x + (i + 0.5) * solved_grid.spacing) << ' '
                 << (solved_grid.origin.y + (j + 0.5) * solved_grid.spacing) << ' '
                 << (solved_grid.origin.z + (k + 0.5) * solved_grid.spacing) << ' '
                 << (e < region_ids_for_stepped.size() ? region_ids_for_stepped[e] : 0)
                 << '\n';
              ++wrote;
            }
        std::printf("beam band: %zu voxel(s) written to %s\n", wrote, bp);
      }
    }
    R.outline_beam_mm = beam;
    R.outline_bleed_mm = bleed;
    R.outline_beam_voxels = static_cast<long long>(cleared);
    R.outline_inward_mm = inward;
    std::fprintf(stderr,
                 "[outline] solid beam %.4f mm (bead %.3f, voxel %.3f) + bleed %.4f mm "
                 "(band %.3f) = %.4f mm inward | %zu voxel(s) turned solid\n",
                 beam, job.grading.min_extrudable_width_mm, solved_grid.spacing, bleed,
                 job.grading.shape_grade_band_mm, inward, cleared);
    // ★ THE ONE PLACE THIS IS NOT LITERALLY THE PREVIEW: the preview keeps lattice in
    // beam/2 .. beam+bleed and covers it with solid; core does not generate it there at
    // all. The printed union is identical by the algebra above. The difference that
    // could still matter is the CERTIFICATE: a strut buried in solid is tied to it over
    // its buried length, while a strut clipped at the solid's face touches it only at
    // the face. Core's octet certificate ties on contact, so both tie -- but if a
    // future certificate asks for embedment depth, this is the line to revisit.
  }

  // ── ★ K3 (3): THE SOLID REMAINDER PER REGION, STATED ─────────────────────────
  // What the plan left solid inside each include region: printed voxels the region owns
  // that the final mask does not lattice. The partial-depth strip -- cells that stop
  // short of the region's depth -- is exactly this number, so a run that silently
  // latticed it, or silently left it as air, is visible in the receipt instead of only
  // in the mesh. Owner is the K6 rule (nearest face plane, tie to the lower DECLARED
  // id), so a voxel in two prisms is counted once.
  //
  // MEASURED HERE, not at the mask's construction, because the mask is not final until
  // the outline beam has run: on 570B38E2 the beam turns 804 of the plan's own voxels
  // solid, and those belong in the remainder.
  if (!plan_groups.empty()) {
    const double vox_mm3 =
        solved_grid.spacing * solved_grid.spacing * solved_grid.spacing;
    std::map<int, long long> solid_vox, latticed_vox, law_rho_vox, outside_vox;
    std::map<int, long long> outside_rect_vox, outside_depth_vox, outside_outline_vox,
        outside_owned_vox, outside_other_vox;
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!(dens[e] >= printed_iso)) continue;
          const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                       solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                       solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
          const int owner = stepped_region_owner(c, lattice_roles.includes);
          // ── ★ RULING 2'S RECEIPT: WHAT THE OUTLINE CLIP TAKES, PER REGION ──────
          // A voxel its own region's plan cell covers, but which the region does NOT
          // reach -- because the outline excludes it, or because the cell overhangs the
          // prism. Before the clip, struts filled every one of these while the mask
          // certified them SOLID; measured on outline_clip_quadrant, 2502.64 mm3 of
          // lattice was drawn where 427.84 mm3 belongs. This is that set, exactly, and
          // it is the CAUSE rather than a count of the effect -- one run cannot measure
          // a counterfactual, and a number that needed two runs would not be a receipt.
          {
            const int rid = plan_cell_region_at(c);
            if (rid != 0 && owner != rid) {
              ++outside_vox[rid];
              // ★ ruling 3b: and WHY the region does not reach it, by the same test
              // order the per-cell classifier uses, so the volume is a diagnosis too.
              switch (classify_no_strut(rid, c, solved_grid.spacing)) {
                case NoStrutCause::OutsideRect:    ++outside_rect_vox[rid]; break;
                case NoStrutCause::BeyondDepth:    ++outside_depth_vox[rid]; break;
                case NoStrutCause::OutsideOutline: ++outside_outline_vox[rid]; break;
                case NoStrutCause::OwnedElsewhere: ++outside_owned_vox[rid]; break;
                default:                           ++outside_other_vox[rid]; break;
              }
            }
          }
          if (owner == 0) continue;            // outside every include region
          if (mask[e]) ++latticed_vox[owner];
          else ++solid_vox[owner];
          if (mask[e] && e < plan_rho_from_law_flag.size() && plan_rho_from_law_flag[e])
            ++law_rho_vox[owner];
          // ── ★ THE TRIPWIRE (ruling 1's condition) ──────────────────────────────
          // The certificate may never credit a strut other than the one drawn. The
          // posture's density at this voxel and the density the radius field sizes a
          // strut from AT THIS VOXEL'S CENTRE come from one function, so they are equal
          // by construction -- and this is the line that notices if a future edit makes
          // them two functions again. Bit-exact: there is no arithmetic between them to
          // justify a tolerance, and a tolerance here would hide exactly the drift it
          // is meant to catch.
          if (mask[e]) {
            const double drawn = plan_strut_rho_at(c);
            const double certified = e < gf.posture.relative_density.size()
                                         ? gf.posture.relative_density[e]
                                         : 0.0;
            if (!(drawn == certified)) {
              char buf[256];
              std::snprintf(buf, sizeof buf,
                            "region %d: the strut at (%.4f, %.4f, %.4f) is DRAWN at "
                            "relative density %.17g and CERTIFIED at %.17g",
                            owner, c.x, c.y, c.z, drawn, certified);
              throw JobError(
                  std::string("lattice \"stepped_cells\": the posture and the strut "
                              "radius disagree about one voxel's density, so the "
                              "certificate would credit a strut other than the one in "
                              "the file. ") + buf +
                  ". These are read from one function (plan_strut_rho_at) and must be "
                  "equal; refusing rather than certifying geometry that was not drawn.");
            }
          }
        }
    for (const SteppedPlanRegion& pr : plan_regions) {
      char rbuf[160];
      std::snprintf(rbuf, sizeof rbuf, "%sr%d=%.3f",
                    R.plan_solid_remainder_mm3.empty() ? "" : ", ", pr.region_id,
                    static_cast<double>(solid_vox[pr.region_id]) * vox_mm3);
      R.plan_solid_remainder_mm3 += rbuf;
      R.plan_latticed_mm3 += static_cast<double>(latticed_vox[pr.region_id]) * vox_mm3;
      // ★ RULING 1'S CONDITION: the voxels whose density the plan did NOT supply, per
      // region. A plan that sent a rho with every cell shows 0 everywhere; a non-zero
      // entry says core's own grading is sizing and certifying that many of the plan's
      // struts, which is a thing to know and not a thing to discover from a picture.
      std::snprintf(rbuf, sizeof rbuf, "%sr%d=%lld",
                    R.plan_rho_fallback_by_region.empty() ? "" : ", ", pr.region_id,
                    law_rho_vox[pr.region_id]);
      R.plan_rho_fallback_by_region += rbuf;
      std::snprintf(rbuf, sizeof rbuf, "%sr%d=%.3f",
                    R.clip_outside_region_mm3.empty() ? "" : ", ", pr.region_id,
                    static_cast<double>(outside_vox[pr.region_id]) * vox_mm3);
      R.clip_outside_region_mm3 += rbuf;
      // ★ ruling 3b: the same volume, split by what put it out of the region's reach.
      // mm3 on the same voxel basis, so the five add back to the figure above.
      std::snprintf(rbuf, sizeof rbuf,
                    "%sr%d: outline=%.3f depth=%.3f rect=%.3f owned=%.3f other=%.3f",
                    R.clip_outside_by_cause_mm3.empty() ? "" : " | ", pr.region_id,
                    static_cast<double>(outside_outline_vox[pr.region_id]) * vox_mm3,
                    static_cast<double>(outside_depth_vox[pr.region_id]) * vox_mm3,
                    static_cast<double>(outside_rect_vox[pr.region_id]) * vox_mm3,
                    static_cast<double>(outside_owned_vox[pr.region_id]) * vox_mm3,
                    static_cast<double>(outside_other_vox[pr.region_id]) * vox_mm3);
      R.clip_outside_by_cause_mm3 += rbuf;
    }
    std::fprintf(stderr,
                 "[stepped] plan solid remainder per region: %s mm3 | the plan lattices "
                 "%.3f mm3\n",
                 R.plan_solid_remainder_mm3.c_str(), R.plan_latticed_mm3);
  }

  // ── ★ D10/E3: AN EMPTY LATTICE IS A REFUSAL, ON EVERY ALGORITHM ──────────────
  // (#354's core brief 2026-10-06; reviewer's ruling 2026-10-07.) The ungradeable test
  // above fires only when the LAW could lattice nothing. When the law latticed voxels and
  // something downstream took all of them -- the outline beam does exactly that, and on
  // #354's 3418E167 it took all 4 that survived a swept grade -- the run used to carry on
  // with an empty mask and finish. Doubled then reported "over 0 voxels" and
  // "verdict: ACCEPTED" with interior_volume_mm3 0; Stepped refused a few lines below,
  // but blamed region ids and recommended the algorithm that accepts nothing.
  //
  // A refusal costs a solve. THIS costs a print, so it is the more expensive of the two
  // to get wrong, and it is checked here -- once, for every algorithm, at the point where
  // the mask is final -- rather than in each algorithm's own branch.
  //
  // NOTE on "every algorithm": the beam cannot be the cause under organic, because
  // `shape_grade` is refused at parse time for organic (job.cpp:2115). The check is still
  // unconditional, so that anything else that empties the mask is caught by the same
  // sentence rather than by nothing.
  if (graded) {
    std::size_t latticed_now = 0;
    for (char m : mask)
      if (m) ++latticed_now;
    if (latticed_now == 0) {
      R.ungradeable = true;
      const long long cleared = R.outline_beam_voxels;
      std::string why =
          "no lattice remains to emit, so there is nothing to certify or print -- "
          "refusing rather than writing a file with zero struts in it and calling it a "
          "lattice. The grading law latticed " +
          std::to_string(latticed_after_grade) + " of this variant's " +
          std::to_string(gf.region_voxels) + " candidate voxels";
      if (cleared > 0) {
        // The beam is the cause, and its reach is the number to act on.
        why += ", and then the outline beam turned " + std::to_string(cleared) +
               " voxel(s) solid -- every one that was left. Its reach is " +
               json_num(R.outline_beam_mm) + " mm of beam plus " +
               json_num(R.outline_bleed_mm) + " mm of bleed = " +
               json_num(R.outline_inward_mm) +
               " mm inward from the region outline, set by \"shape_grade_band_mm\" " +
               json_num(job.grading.shape_grade_band_mm) +
               " mm; a band of 25 mm or more adds the bleed. Either narrow the band so "
               "the beam does not reach across the region, or widen the region: a "
               "lattice needs more depth than the solid beam that frames it.";
      } else {
        why +=
            ", and nothing remained by the time the lattice was emitted. The outline beam "
            "cleared none, so the loss is upstream of it.";
      }
      why += " The law's own fallbacks over the voxels it rejected: "
             "member_too_thin_for_cell=" +
             std::to_string(gf.fallback_member_too_thin) +
             ", strut_unprintable_at_every_cell=" +
             std::to_string(gf.fallback_strut_unprintable) +
             ", irrecoverable_by_any_cell_size=" +
             std::to_string(gf.fallback_irrecoverable_by_cell) + ".";
      R.ungradeable_reason = why;
      R.gf = gf;
      return R;
    }
  }

  // ── ★ STEPPED (task 2026-08-21-organic-lattice, §4) ────────────────────────
  // One cell per DECLARED region, derived from that region's own FEA-driven density
  // and its own member width, taken VERBATIM. The per-voxel cell field it produces is
  // a real cell — stepped HAS cells — so it goes into the posture and the
  // certification's cells-per-member guard reads it correctly, unlike organic where
  // that field is deliberately left empty (§3a).
  std::vector<LatticeSteppedPass> stepped_passes;
  // ── ★ K6 PART 2: ONE BOUNDARY PER REGION, CLIPPED TO WHAT THAT REGION OWNS ───
  // Where two include prisms overlap, both regions' passes used to lay a lattice through
  // the shared volume and the file carried two. Each region now gets its own boundary,
  // clipped by the owner rule (clip_to_owned_region), and its passes point at that.
  //
  // ★ A DEQUE, AND HOISTED TO THIS SCOPE ON PURPOSE. `stepped_passes` holds raw pointers
  // into these objects and outlives the block that builds them; an earlier cut declared
  // them inside that block and the generator read freed memory. A deque rather than a
  // vector because the pointers must stay valid as regions are added.
  // (declared above the ledger's classifier, which asks the pass's own boundary)
  if (graded && R.algorithm == LatticeAlgorithm::Stepped) {
    R.stepped = run_stepped_step(solved_grid, dens, mask,
                                 gf.posture.relative_density, region_ids_for_stepped,
                                 job.grading, printed_iso, 32);
    if (!R.stepped.ran || R.stepped.cells.empty()) {
      R.ungradeable = true;
      R.ungradeable_reason =
          "the stepped algorithm derived no region cell. Measured: " +
          std::to_string(R.stepped.masked_voxels) +
          " latticed voxels carrying " + std::to_string(R.stepped.distinct_ids) +
          " distinct region ids (" +
          std::to_string(R.stepped.voxels_with_id_zero) +
          " of them with NO id), and " +
          std::to_string(R.stepped.regions_with_no_voxels) +
          " region(s) had no measurable member width. Stepped derives ONE CELL PER "
          "DECLARED REGION from that region's own FEA density and member width, so a "
          "job whose latticed voxels carry no region id has nothing for it to key "
          "on. No algorithm is recommended here: the one this sentence used to name "
          "accepts an empty lattice silently, which is the defect above.";
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
  // ★ Finding 7 (ruling 2026-11-02): EVERY cell covering voxel (i,j,k)'s volume, by the
  // cover rule (cell_plan.hpp). This is what decides which cells a latticed voxel makes;
  // `owner_cell` stays the one cell that answers "which cell certifies this voxel".
  auto for_covering_cells = [&](int i, int j, int k, const auto& fn) {
    const double s = solved_grid.spacing;
    int i0, i1, j0, j1, k0, k1;
    cells_covering_span(solved_grid.origin.x + i * s, s, Rdims.origin.x, cell, ncx, &i0, &i1);
    cells_covering_span(solved_grid.origin.y + j * s, s, Rdims.origin.y, cell, ncy, &j0, &j1);
    cells_covering_span(solved_grid.origin.z + k * s, s, Rdims.origin.z, cell, ncz, &k0, &k1);
    for (int ck = k0; ck <= k1; ++ck)
      for (int cj = j0; cj <= j1; ++cj)
        for (int ci = i0; ci <= i1; ++ci) fn(cidx(ci, cj, ck));
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
          // ★ Finding 7: every cell the voxel COVERS (the cover rule the activation uses),
          // so no cell holding added material can come back on through a neighbour.
          if (kDesignBoxAddedMaterialKeptSolid)
            for_covering_cells(i, j, k, [&](std::size_t ce) { cell_has_added[ce] = 1; });
        }
    // Pass 2 — clear those cells WHOLE: every masked voxel any such cell covers.
    if (kDesignBoxAddedMaterialKeptSolid)
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (!mask[e]) continue;
            bool covered_by_added = false;
            for_covering_cells(i, j, k,
                               [&](std::size_t ce) { covered_by_added |= cell_has_added[ce] != 0; });
            if (!covered_by_added) continue;
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
            // the OWNER rule (ruling 4): nearest face plane, tie to the lower id, never declaration order.
            void_region_id[e] = stepped_region_owner(c, lattice_roles.includes);
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

  // ── ★ E3: "OFF" WITH NO DENSITY -- THE LIGHTEST ONE DENSITY THAT CERTIFIES ───────
  // (ruling 11-06; agreed 11-04 19:31Z.) A region with grading "off" and no stated
  // density took its graded PEAK: it certifies wherever the grade does, but it is the
  // heaviest one density. Here each such region bisects its one density between the
  // lightest that still PRINTS at its cells (lattice_min_density_for_strut) and that
  // peak, the upper bound, certifying each trial with the run's own certificate
  // (certify_posture, every scenario the lattice uses). The upper end is always one that
  // certified, so the answer certifies whatever the curve's shape; regions are taken in
  // turn, each against the ones before it at their found density. A region whose peak
  // does not certify keeps it, and is named by label if the run's certificate refuses.
  // The shipped certificate below still decides: this only chooses the density.
  std::vector<LatticeRegionGraded> e3_search;
  if (fixed_search != nullptr && graded) {  // a shipped-search pass: the density is chosen
    e3_search = *fixed_search;
    for (std::size_t e = 0; e < mask.size() && e < e3_owner.size(); ++e) {
      const int id = e3_owner[e];
      if (!mask[e] || id < 1 || static_cast<std::size_t>(id) > e3_search.size()) continue;
      const LatticeRegionGraded& f = e3_search[static_cast<std::size_t>(id - 1)];
      if (f.searched && f.search_certified) gf.posture.relative_density[e] = f.search_rho;
    }
  } else if (graded && !e3_overrides.empty() && R.algorithm != LatticeAlgorithm::Organic) {
    std::vector<std::size_t> todo;
    for (std::size_t i = 0; i < e3_overrides.size(); ++i)
      if (e3_overrides[i].flat && !(e3_overrides[i].flat_rho > 0.0)) todo.push_back(i);
    if (!todo.empty()) {
      const LatticeCertContext scx =
          lattice_cert_context(v, part_grid, domain, options, material, job);
      std::vector<double> trial = gf.posture.relative_density;
      double last_margin = 0.0;
      auto certifies = [&]() {
        const LatticePosture tp =
            build_lattice_posture(lat_topo, solved_grid, cell, mask, 0.0, &trial);
        const PostureCertification pc =
            certify_posture(v, solved_grid, options, material, bcs, scx, &tp);
        last_margin = pc.governing.margin_effective;
        return pc.governing.accepted;
      };
      e3_search.assign(e3_jobs.size(), {});
      for (const std::size_t i : todo) {
        LatticeRegionGraded& rs = e3_search[i];
        std::vector<std::size_t> vox;
        double peak = 0.0, floor = lattice_rho_min(lat_topo);
        bool prints = true;
        for (std::size_t e = 0; e < mask.size() && e < e3_owner.size(); ++e) {
          if (!mask[e] || e3_owner[e] != static_cast<int>(i) + 1) continue;
          vox.push_back(e);
          peak = std::max(peak, trial[e]);
          const double S = e < gf.posture.cell_size_field.size() &&
                                   gf.posture.cell_size_field[e] > 0.0
                               ? gf.posture.cell_size_field[e]
                               : cell;
          const double pf = lattice_min_density_for_strut(
              lat_topo, S, job.grading.min_extrudable_width_mm, job.grading.max_relative_density);
          if (pf < 0.0) prints = false;
          floor = std::max(floor, pf);
        }
        if (vox.empty()) continue;
        if (!prints || floor > peak) floor = peak;
        auto set = [&](double r) { for (const std::size_t e : vox) trial[e] = r; };
        rs.searched = true;
        rs.search_peak = peak;
        rs.search_floor = floor;
        set(peak);
        ++rs.search_trials;
        if (!certifies()) {  // the peak itself does not: keep it, the run decides
          rs.search_rho = peak;
          rs.search_margin = last_margin;
          const std::string& lb = e3_jobs[i].label;
          char tail[200];
          std::snprintf(tail, sizeof tail,
                        " (grading off, one density): the lattice does not certify even "
                        "with it at its graded peak %.4g (margin %.3g), so no lighter one "
                        "density was searched. Give it a density, or let it grade.",
                        peak, last_margin);
          R.one_density_refusal += std::string(R.one_density_refusal.empty() ? "" : " ") +
                                   "Region " +
                                   (lb.empty() ? std::to_string(i + 1) : "\"" + lb + "\"") + tail;
          continue;
        }
        double good = peak, good_margin = last_margin, bad = floor;
        if (floor < peak) {
          set(floor);
          ++rs.search_trials;
          if (certifies()) {
            good = floor;
            good_margin = last_margin;
          } else {
            for (int it = 0; it < 6 && good - bad > 1e-3; ++it) {
              const double mid = 0.5 * (good + bad);
              set(mid);
              ++rs.search_trials;
              if (certifies()) {
                good = mid;
                good_margin = last_margin;
              } else {
                bad = mid;
              }
            }
          }
        }
        set(good);
        rs.search_rho = good;
        rs.search_margin = good_margin;
        rs.search_certified = true;
        std::fprintf(stderr,
                     "[one-density] region %zu: %.4f (printable floor %.4f, graded peak "
                     "%.4f) certifies at margin %.4g, %d trial(s)\n",
                     i + 1, good, floor, peak, good_margin, rs.search_trials);
      }
      gf.posture.relative_density = trial;
    }
  }

  // ── ★ E2.4 PER REGION (ruling 11-06 (A)): AN OPEN REGION BESIDE COVERED ONES ─────
  // A region's own outer_finish ("none" open | "shell" covered; "" = the part's). The
  // open set O is the latticed voxels whose owner is open. When the lattice is mixed:
  //   * the WALL: the covered latticed voxels within the slicer's wall of O (its loops x
  //     line widths, else two line widths), in whole voxel layers rounded UP, leave the
  //     lattice: the solid companion prints them and the certificate counts exactly them;
  //   * the SHELL is re-meshed around the design minus O, so it closes over the covered
  //     part and the wall, and leaves O open;
  //   * O's cells at a free surface get the open floor (open_finish_cut_cells), below.
  // A lattice all open or all covered keeps the part-wide path.
  std::vector<char> region_open;  // O
  TriangleMesh region_shell;
  bool any_region_finish = false;
  for (const JobLatticeRegion& r : e3_jobs)
    if (!r.outer_finish.empty()) any_region_finish = true;
  if (any_region_finish && !e3_owner.empty()) {
    auto finish_of = [&](std::size_t e) {
      const int id = e3_owner[e];
      if (id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size() &&
          !e3_jobs[static_cast<std::size_t>(id - 1)].outer_finish.empty())
        return e3_jobs[static_cast<std::size_t>(id - 1)].outer_finish;
      return job.lattice.outer_finish;
    };
    region_open.assign(mask.size(), 0);
    long long n_open = 0, n_cov = 0;
    for (std::size_t e = 0; e < mask.size() && e < e3_owner.size(); ++e) {
      if (!mask[e]) continue;
      if (finish_of(e) == "none") { region_open[e] = 1; ++n_open; }
      else ++n_cov;
    }
    if (n_open > 0 && n_cov > 0) {
      const double w = job.grading.min_extrudable_width_mm > 0.0 ? job.grading.min_extrudable_width_mm : 0.45;
      const double inner = job.loads.wall_line_width_mm > 0.0 ? job.loads.wall_line_width_mm : w;
      const double outer = job.loads.wall_line_width_outer_mm > 0.0 ? job.loads.wall_line_width_outer_mm : inner;
      const double wall_mm = job.loads.wall_loops > 0 ? outer + (job.loads.wall_loops - 1) * inner : 2.0 * w;
      const int layers = std::max(1, static_cast<int>(std::ceil(wall_mm / solved_grid.spacing - 1e-9)));
      // walk `layers` face-steps from O into the covered lattice
      std::vector<int> step(mask.size(), -1);
      std::vector<std::size_t> q;
      for (std::size_t e = 0; e < mask.size(); ++e)
        if (region_open[e]) { step[e] = 0; q.push_back(e); }
      const int di[6] = {1, -1, 0, 0, 0, 0}, dj[6] = {0, 0, 1, -1, 0, 0}, dk[6] = {0, 0, 0, 0, 1, -1};
      std::vector<long long> wall_by_region(e3_jobs.size() + 1, 0), open_by_region(e3_jobs.size() + 1, 0);
      for (std::size_t h = 0; h < q.size(); ++h) {
        const std::size_t e = q[h];
        if (step[e] >= layers) continue;
        const int i = static_cast<int>(e % static_cast<std::size_t>(solved_grid.nx));
        const int j = static_cast<int>((e / static_cast<std::size_t>(solved_grid.nx)) % static_cast<std::size_t>(solved_grid.ny));
        const int k = static_cast<int>(e / (static_cast<std::size_t>(solved_grid.nx) * static_cast<std::size_t>(solved_grid.ny)));
        for (int d = 0; d < 6; ++d) {
          const int i2 = i + di[d], j2 = j + dj[d], k2 = k + dk[d];
          if (i2 < 0 || j2 < 0 || k2 < 0 || i2 >= solved_grid.nx || j2 >= solved_grid.ny || k2 >= solved_grid.nz) continue;
          const std::size_t e2 = solved_grid.index(i2, j2, k2);
          if (!mask[e2] || region_open[e2] || step[e2] >= 0) continue;
          step[e2] = step[e] + 1;
          q.push_back(e2);
        }
      }
      long long wall = 0;
      for (std::size_t e = 0; e < mask.size(); ++e) {
        if (region_open[e]) {
          const int id = e3_owner[e];
          ++open_by_region[static_cast<std::size_t>(id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size() ? id : 0)];
        }
        if (step[e] < 1 || region_open[e]) continue;
        mask[e] = 0;                       // solid: the companion prints it
        gf.posture.mask[e] = 0;
        gf.posture.relative_density[e] = 0.0;
        const int id = e3_owner[e];
        ++wall_by_region[static_cast<std::size_t>(id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size() ? id : 0)];
        ++wall;
      }
      // the shell around the design minus O
      std::vector<double> minus_open = dens;
      for (std::size_t e = 0; e < minus_open.size(); ++e)
        if (region_open[e]) minus_open[e] = 0.0;
      region_shell = marching_cubes(solved_grid, minus_open, printed_iso);
      R.region_wall_mm = layers * solved_grid.spacing;
      R.region_wall_voxels = wall;
      for (std::size_t i = 0; i < e3_jobs.size(); ++i)
        if (open_by_region[i + 1] > 0) {
          const std::string& lb = e3_jobs[i].label;
          R.open_regions.push_back({lb.empty() ? "Region " + std::to_string(i + 1) : lb,
                                    open_by_region[i + 1]});
        }
      std::fprintf(stderr,
                   "[finish] %lld latticed voxel(s) open beside %lld covered: a %d-layer "
                   "(%.3f mm) wall of %lld voxel(s) closes the open part from the covered "
                   "one; the shell re-meshed around the rest\n",
                   n_open, n_cov, layers, layers * solved_grid.spacing, wall);
    } else if (n_open == 0) {
      region_open.clear();
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
          // ★ Finding 7: every cell covering the voxel, not the centre's alone.
          for_covering_cells(i, j, k, [&](std::size_t ce) {
            cell_rho_sum[ce] += rho;
            ++cell_rho_cnt[ce];
          });
          gsum += rho;
          ++gcnt;
        }
    gmean = gcnt > 0 ? gsum / static_cast<double>(gcnt) : gf.band_rho_min;
    // Graded cell activation: a cell is latticed iff it COVERS >= 1 masked
    // voxel (Finding 7's cover rule) — the graded silhouette DERIVES from the same
    // mask the posture certifies, so file and certificate cannot disagree on where
    // lattice is, and no part of a certified voxel is left without its cells.
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
    G.field = [&sgr, &mref, &rref, &cell_rho_sum, &cell_rho_cnt, cidx, clampi, lat_topo,
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
      return 0.5 * lattice_strut_diameter_mm(lat_topo, rho, cell);
    };
  } else {
    G.uniform_mm = job.lattice.strut_radius_mm;
    // rho the printed geometry (cell + uniform strut radius) implies, on the
    // library basis (the E5 preflight already proved it in-band).
    rho_uniform =
        lattice_density_from_strut(lat_topo, job.lattice.cell_mm, job.lattice.strut_radius_mm);
    // UNIFORM cell activation under a DESIGN BOX (task
    // 2026-08-03-design-box-recertification). The uniform path has always passed a
    // NULL predicate, which means "lattice every cell the boundary cannot prove
    // empty" — and the boundary's voxel base is the whole solved design, added
    // material included. That was correct while the mask WAS the boundary's own
    // silhouette. It stops being correct the moment the added-material policy
    // clears voxels the boundary still considers material: the certificate would
    // say solid and the generator would still write struts there. So under an
    // expanded domain the uniform path derives its cell set FROM THE FINAL MASK,
    // exactly as the graded path above does — a cell is latticed iff it covers at
    // least one masked voxel (Finding 7's cover rule).
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
      // ★ Finding 7: every cell COVERING a masked voxel (the cover rule).
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i)
            if (mask[solved_grid.index(i, j, k)])
              for_covering_cells(i, j, k,
                                 [&](std::size_t ce) { uniform_cells[ce] = 1; });
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
  // ★ GRADING + A DESIGN BOX (ruling 2026-11-03 23:05, option (b)): which cells of each
  // level, and of each plan pass below, cover a voxel of the FINAL certification mask --
  // the mask the added-material policy has already cleared whole cells from. A level's
  // or a pass's own occupancy comes from its plan, so without this a graded design-box
  // run would write struts into cells the certificate calls solid. Built only on an
  // expanded domain (the predicates are untouched off the box path, so the file is
  // byte-identical); a deque, because the predicates hold pointers into it.
  std::deque<std::vector<char>> certified_cover;
  auto cover_of_mask = [&](const Vec3& o, double ce, int gnx, int gny, int gnz) {
    std::vector<char> cov(static_cast<std::size_t>(gnx) * gny * gnz, 0);
    const double s = solved_grid.spacing;
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          if (!mask[solved_grid.index(i, j, k)]) continue;
          int i0, i1, j0, j1, k0, k1;
          cells_covering_span(solved_grid.origin.x + i * s, s, o.x, ce, gnx, &i0, &i1);
          cells_covering_span(solved_grid.origin.y + j * s, s, o.y, ce, gny, &j0, &j1);
          cells_covering_span(solved_grid.origin.z + k * s, s, o.z, ce, gnz, &k0, &k1);
          for (int ck = k0; ck <= k1; ++ck)
            for (int cj = j0; cj <= j1; ++cj)
              for (int ci = i0; ci <= i1; ++ci)
                cov[(static_cast<std::size_t>(ck) * gny + cj) * gnx + ci] = 1;
        }
    certified_cover.push_back(std::move(cov));
    return &certified_cover.back();
  };
  // ★ RULING A: THE DYADIC PLANNER IS NOT CONSULTED WHEN THE LIST IS PRESENT. The app
  // packed the cells and core lays THOSE down; running the ladder as well would emit a
  // second, differently-anchored set of passes over the same voxels -- two lattices in
  // one file. One code path for both algorithms means exactly this: whoever sent cells
  // owns the arrangement.
  if (graded && gf.cell_plan.max_level > 0 && job.lattice.stepped_cells.empty() &&
      !gf.posture.cell_size_field.empty()) {
    const CellSizePlan* pl = &gf.cell_plan;
    for (const CellLevelReport& lr : gf.cell_plan.levels) {
      if (lr.cells == 0) continue;
      LatticeLevelSpec sp;
      sp.level = lr.level;
      sp.cell_mm = lr.cell_size_mm;
      const int LV = lr.level;
      if (domain.expanded) {
        const int lnx = (pl->nx + (1 << LV) - 1) >> LV, lny = (pl->ny + (1 << LV) - 1) >> LV,
                  lnz = (pl->nz + (1 << LV) - 1) >> LV;
        const std::vector<char>* cov =
            cover_of_mask(pl->origin, pl->base_cell_mm * (1 << LV), lnx, lny, lnz);
        sp.latticed = [pl, LV, cov, lnx, lny](int ci, int cj, int ck) {
          const int bi = ci << LV, bj = cj << LV, bk = ck << LV;
          if (bi >= pl->nx || bj >= pl->ny || bk >= pl->nz) return false;
          return static_cast<int>(pl->level[pl->index(bi, bj, bk)]) == LV &&
                 (*cov)[(static_cast<std::size_t>(ck) * lny + cj) * lnx + ci] != 0;
        };
      } else {
        sp.latticed = [pl, LV](int ci, int cj, int ck) {
          const int bi = ci << LV, bj = cj << LV, bk = ck << LV;
          if (bi >= pl->nx || bj >= pl->ny || bk >= pl->nz) return false;
          return static_cast<int>(pl->level[pl->index(bi, bj, bk)]) == LV;
        };
      }
      // Same fallback chain as the uniform graded field (owning voxel's graded
      // rho, else the level's own band floor) — evaluated at THIS level's cell.
      const VoxelGrid& sgr = solved_grid;
      const std::vector<char>& mref = mask;
      const std::vector<double>& rref = gf.posture.relative_density;
      const double lcell = lr.cell_size_mm;
      const double rlo = gf.band_rho_min;
      sp.radius.nseg = 8;
      sp.radius.uniform_mm = 0.5 * lattice_strut_diameter_mm(lat_topo, rlo, lcell);
      sp.radius.field = [&sgr, &mref, &rref, lcell, rlo, lat_topo](Vec3 p) {
        auto cl = [](int val, int hi) { return val < 0 ? 0 : (val > hi ? hi : val); };
        const int i = cl(static_cast<int>(
            std::floor((p.x - sgr.origin.x) / sgr.spacing)), sgr.nx - 1);
        const int j = cl(static_cast<int>(
            std::floor((p.y - sgr.origin.y) / sgr.spacing)), sgr.ny - 1);
        const int k = cl(static_cast<int>(
            std::floor((p.z - sgr.origin.z) / sgr.spacing)), sgr.nz - 1);
        const std::size_t e = sgr.index(i, j, k);
        return 0.5 * lattice_strut_diameter_mm(lat_topo, mref[e] ? rref[e] : rlo, lcell);
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
  // ── ★★ ANY-STEP: THE PASSES COME FROM THE PLAN THE JOB STATED ──────────────
  // (brief of 2026-09-17 §2.1.) The legacy path below derives one cell per region and
  // anchors every pass at the SOLVED GRID's origin. Any-step cells are not on that grid:
  // each family sits on its own tile grid inside the region, so each (region, family)
  // needs its own LatticeRegion.origin. That is the whole of the change -- LatticeRegion
  // already carries an origin, a cell size and a per-cell predicate.
  //
  // ★ AND THE PLAN IS VALIDATED FIRST, WITH THE RUN REFUSED ON A BAD CELL. Core does not
  // repack: the arrangement the maintainer approved on screen is the arrangement laid
  // down, or the job stops and names the cell that broke the rule.
  std::vector<std::vector<char>> anystep_active;
  // ★ RULING C: per-pass backing store for the sent densities. A deque, not a vector:
  // the radius lambda holds a pointer into it and a vector would rehome its elements on
  // the next push_back, leaving every earlier pass reading freed memory.
  // (the per-pass rho store that used to live here is gone: the radius field reads
  //  plan_strut_rho_at, which owns the plan's rho -- ruling 1's condition)
  if (!job.lattice.stepped_cells.empty()) {
    const std::vector<SteppedCellGroup>& groups = plan_groups;   // K3: built above
    anystep_active.resize(groups.size());
    for (std::size_t gi = 0; gi < groups.size(); ++gi) {
      const SteppedCellGroup& g = groups[gi];
      LatticeRegion PR;
      PR.origin = g.origin;                  // ★ the FAMILY's grid, not the solved grid's
      PR.nx = g.nx; PR.ny = g.ny; PR.nz = g.nz;
      PR.cell_mm = g.size_mm;
      // ★ K6 part 2: this pass lays only where its own region owns the space. Built on
      // demand, once per region, and shared by that region's passes.
      const LatticeBoundary* pb = &boundary;
      if (g.region_id > 0) {
        auto it = owned_boundary_for.find(g.region_id);
        if (it == owned_boundary_for.end()) {
          owned_boundaries.push_back(boundary);
          owned_boundaries.back().clip_to_owned_region(g.region_id);
          it = owned_boundary_for.emplace(g.region_id, &owned_boundaries.back()).first;
        }
        pb = it->second;
        // ★ K6 part 2: and the stub guard, on exactly the passes the ownership clip
        // applies to. A piece left on the far side of an ownership boundary, shorter
        // than it is thick, prints as a bump and carries no load; dropped, and counted.
        // Only here, so a pass that is not owner-clipped keeps the 1 um sliver guard and
        // its file is byte-identical.
        PR.min_fragment_diameters = 1.0;
      }
      PR.boundary = pb;
      std::vector<char>& act = anystep_active[gi];
      act.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, 0);
      for (const std::array<int, 3>& c : g.cells)
        act[(static_cast<std::size_t>(c[2]) * g.ny + c[1]) * g.nx + c[0]] = 1;
      // ★ GRADING + A DESIGN BOX: a plan cell the added-material policy kept solid (it
      // covers no voxel of the final mask) is not laid. Off the box path, untouched.
      if (domain.expanded) {
        const std::vector<char>* cov = cover_of_mask(g.origin, g.size_mm, g.nx, g.ny, g.nz);
        for (std::size_t a = 0; a < act.size(); ++a) act[a] = act[a] && (*cov)[a];
      }
      const std::vector<char>* ap = &act;
      const int anx = g.nx, any = g.ny, anz = g.nz;
      PR.latticed = [ap, anx, any, anz](int ci, int cj, int ck) {
        if (ci < 0 || cj < 0 || ck < 0 || ci >= anx || cj >= any || ck >= anz) return false;
        return (*ap)[(static_cast<std::size_t>(ck) * any + cj) * anx + ci] != 0;
      };
      LatticeSteppedPass sp;
      sp.region = PR;
      sp.radius.nseg = 8;
      // A cell's own density at its OWN size: the printed diameter is d(rho, cell), so a
      // 9 and a 3 at the same relative density print proportionally different struts.
      sp.radius.uniform_mm = 0.5 * lattice_strut_diameter_mm(lat_topo, gf.band_rho_min, g.size_mm);
      const double gcell = g.size_mm;
      // ── ★ RULING C: THE DENSITY CAME WITH THE CELL ─────────────────────────────
      // When the job sent a rho per cell, the strut is sized from THAT and core adds no
      // band term of its own. The quilt raise, the coarse-cell share and the aesthetic
      // ceiling are the app's arithmetic over its own demand map; core re-deriving them
      // from a field it grades differently is precisely how the two pictures drift. The
      // LAW is still core's (octet_strut_diameter_mm) -- only the density is the app's.
      //
      // ── ★ AND RULING 1'S CONDITION (reviewer, 2026-10-10) ──────────────────────
      // This block used to carry its OWN copy of that lookup -- a per-group rho grid, a
      // per-group index, and its own voxel fallback -- beside the posture's copy a
      // thousand lines up. Two implementations of one number, with nothing holding them
      // together. It now calls `plan_strut_rho_at`, which is the same function the
      // posture was built from, so the strut the certificate credits and the strut the
      // file carries are sized from one number by construction rather than by agreement.
      // The assertion over the final mask (above) is the tripwire on that.
      sp.radius.field = [&plan_strut_rho_at, gcell, lat_topo](Vec3 pt) {
        return 0.5 * lattice_strut_diameter_mm(lat_topo, plan_strut_rho_at(pt), gcell);
      };
      stepped_passes.push_back(std::move(sp));
      // ★ §3 PARITY: the density and radius this pass ACTUALLY used, recorded as the
      // pass is built rather than re-derived for the receipt afterwards -- a number
      // re-derived can agree with the law while disagreeing with the geometry, which
      // is the failure this whole section exists to make impossible. When the job sent
      // a rho this IS that rho; when it did not, it is what core derived.
      {
        double rho_used = 0.0;
        for (double rv : g.rho) if (rv > 0.0) { rho_used = rv; break; }
        if (!(rho_used > 0.0)) rho_used = gf.band_rho_min;
        char rbuf[96];
        std::snprintf(rbuf, sizeof rbuf, "%s%.3f=%.4f/%.4f",
                      R.anystep_rho_by_size.empty() ? "" : ", ", g.size_mm, rho_used,
                      0.5 * lattice_strut_diameter_mm(lat_topo, rho_used, g.size_mm));
        R.anystep_rho_by_size += rbuf;
      }
    }
  }
  if (R.stepped_ran && job.lattice.stepped_cells.empty()) {
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
      // A pass cell is active iff it COVERS a masked voxel whose region carries THIS
      // pass's cell (Finding 7's cover rule) — derived from the SAME mask the posture
      // certifies, so the file and the certificate cannot disagree about where
      // lattice is (bar B7).
      const double s = solved_grid.spacing;
      for (int k = 0; k < solved_grid.nz; ++k)
        for (int j = 0; j < solved_grid.ny; ++j)
          for (int i = 0; i < solved_grid.nx; ++i) {
            const std::size_t e = solved_grid.index(i, j, k);
            if (!mask[e]) continue;
            if (R.stepped.cell_field[e] != pcell) continue;
            int i0, i1, j0, j1, k0, k1;
            cells_covering_span(solved_grid.origin.x + i * s, s, PR.origin.x, pcell, pnx,
                                &i0, &i1);
            cells_covering_span(solved_grid.origin.y + j * s, s, PR.origin.y, pcell, pny,
                                &j0, &j1);
            cells_covering_span(solved_grid.origin.z + k * s, s, PR.origin.z, pcell, pnz,
                                &k0, &k1);
            for (int ck = k0; ck <= k1; ++ck)
              for (int cj = j0; cj <= j1; ++cj)
                for (int ci = i0; ci <= i1; ++ci)
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
      sp.radius.uniform_mm = 0.5 * lattice_strut_diameter_mm(lat_topo, gf.band_rho_min, pcell);
      const VoxelGrid& sgr = solved_grid;
      const std::vector<char>& mref = mask;
      const std::vector<double>& rref = gf.posture.relative_density;
      const double rlo = gf.band_rho_min;
      sp.radius.field = [&sgr, &mref, &rref, pcell, rlo, lat_topo](Vec3 pt) {
        auto cl = [](int val, int hi) { return val < 0 ? 0 : (val > hi ? hi : val); };
        const int i = cl(static_cast<int>(
            std::floor((pt.x - sgr.origin.x) / sgr.spacing)), sgr.nx - 1);
        const int j = cl(static_cast<int>(
            std::floor((pt.y - sgr.origin.y) / sgr.spacing)), sgr.ny - 1);
        const int k = cl(static_cast<int>(
            std::floor((pt.z - sgr.origin.z) / sgr.spacing)), sgr.nz - 1);
        const std::size_t e = sgr.index(i, j, k);
        return 0.5 * lattice_strut_diameter_mm(lat_topo, mref[e] ? rref[e] : rlo, pcell);
      };
      stepped_passes.push_back(std::move(sp));
    }
  }

  // (a) geometry — timed alone, so gen_fraction (P6) stays generation-only.
  // ★ K5: the counters so far are the census's own tripwire queries; the generator's
  // start here.
  const long long rho_q_plan0 = rho_q_plan, rho_q_posture0 = rho_q_posture,
                  rho_q_floor0 = rho_q_floor;
  // ── ★ K4: THE LEDGER'S TAP, ARMED ONLY WHEN A PLAN RAN AND THE JOB ASKED ─────
  // One callback per emitted element, attributing it to the plan cell it belongs to.
  // Not armed on a run with no plan, and not armed without the key, so no existing
  // job's artifacts or timings change. lattice_gen.hpp: observing never changes the
  // emitted bytes.
  std::function<void(LatticeGenElement, const Vec3&, const Vec3&, double)> laid_fn;
  if (job.lattice.emit_plan_laid && !plan_groups.empty()) {
    laid_fn = [&plan_cell_slot_at, &plan_laid_struts, &plan_laid_nodes,
               &plan_laid_unattributed](LatticeGenElement k, const Vec3& a,
                                        const Vec3& b, double) {
      // A ball reports a == b and is attributed at its own centre; a strut fragment at
      // its MIDPOINT, which is where the generator sampled its radius, so the ledger and
      // the density agree about which cell a strut belongs to.
      const bool ball = (k == LatticeGenElement::Node ||
                         k == LatticeGenElement::AnchorNode);
      const Vec3 at = ball ? a
                           : Vec3{0.5 * (a.x + b.x), 0.5 * (a.y + b.y),
                                  0.5 * (a.z + b.z)};
      std::size_t gi = 0, ci = 0;
      if (!plan_cell_slot_at(at, &gi, &ci)) { ++plan_laid_unattributed; return; }
      if (ball) ++plan_laid_nodes[gi][ci];
      else ++plan_laid_struts[gi][ci];
    };
  }
  const double tg0 = wall_seconds();
  // ★ Finding 7: the emitted solid, for the volume check below (not on organic, which
  // rebuilds its certified density from its own shipped spans).
  LatticeSolidProbe solid_probe;
  // ★ SKIN PER ZONE (ruling 11-08 (1)). Built only when a zone states its own skin; each
  // anchor ball and chord then asks the zone it lies in, by the SAME membership test the
  // owner map is built with (stepped_region_owner over e3_regions), so a chord's zone is
  // the zone of its midpoint. Null otherwise: the part's skin everywhere, byte for byte.
  LatticeSkinZones skin_zones;
  bool any_zone_skin = false;
  for (const JobLatticeRegion& r : e3_jobs)
    if (!r.skin.empty()) any_zone_skin = true;
  if (any_zone_skin) {
    skin_zones.here.assign(e3_jobs.size() + 1,
                           lattice_skin_here(job.lattice.skin, job.lattice.outer_finish));
    for (std::size_t i = 0; i < e3_jobs.size(); ++i)
      if (!e3_jobs[i].skin.empty())
        skin_zones.here[i + 1] =
            e3_jobs[i].skin == "diagrid" ? LatticeSkinHere::Woven : LatticeSkinHere::Off;
    skin_zones.zone_at = [&e3_regions](const Vec3& p) {
      return stepped_region_owner(p, e3_regions);
    };
  }
  // ★ THE RIM ON A REAL PART (ruling 11-08 (A)). Built only when the part or a zone asks
  // for "rim": the sharp edges of the surface this file ships (the design's own shell,
  // v3.mesh), chains under one cell dropped, and each chain kept where its midpoint's skin
  // is "rim" (a zone's own, else the part's).
  LatticeMeshRimSpec mesh_rim;
  FeatureEdgeStats rim_edges;
  long long rim_other_skin = 0;
  bool rim_asked = job.lattice.skin == "rim";
  for (const JobLatticeRegion& r : e3_jobs)
    if (r.skin == "rim") rim_asked = true;
  std::string rim_rides;
  if (rim_asked) {
    // ★ WHICH SURFACE THE EDGES COME FROM: never the voxel grid, where every step would
    // read as an edge. The part's own mesh when the part itself is latticed; else the
    // design's finished surface (CAD-projected, as the plain export writes it) when the
    // part is in hand; the design's shell (v3.mesh) only when neither is.
    TriangleMesh finished_surface;
    const TriangleMesh* src = part_surface;
    rim_rides = "the part's own mesh";
    if (src == nullptr && cad != nullptr) {
      finished_surface =
          variant_export_model_mesh(v, job.output, solved_grid, printed_iso, cad);
      src = &finished_surface;
      rim_rides = "the design's exported surface";
    }
    if (src == nullptr) {
      src = &v.v3.mesh;
      rim_rides = "the design's shell";
    }
    const std::vector<FeatureChain> chains =
        mesh_feature_chains(*src, kRimFeatureAngleDeg, cell, &rim_edges);
    for (const FeatureChain& c : chains) {
      std::string sk = job.lattice.skin;
      if (!e3_jobs.empty()) {
        const int z = stepped_region_owner(feature_chain_midpoint(c), e3_regions);
        if (z >= 1 && static_cast<std::size_t>(z) <= e3_jobs.size() &&
            !e3_jobs[static_cast<std::size_t>(z - 1)].skin.empty())
          sk = e3_jobs[static_cast<std::size_t>(z - 1)].skin;
      }
      if (sk != "rim") {
        ++rim_other_skin;
        continue;
      }
      mesh_rim.chains.push_back({c.points, c.left_normal, c.right_normal, c.convex, c.closed});
    }
    mesh_rim.line_width_mm =
        graded ? job.grading.min_extrudable_width_mm : job.lattice.min_extrudable_width_mm;
    // Seated in the shell the struts are clipped to: it sits up to about a voxel off the
    // clean surface (half a voxel on a face, more where it chamfers a convex edge).
    mesh_rim.max_seat_mm = 1.5 * solved_grid.spacing;
    mesh_rim.station_spacing_mm = solved_grid.spacing;
  }
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
      stepped_passes.empty() ? nullptr : &stepped_passes,
      job.grading.organic_strut_embed_mm, job.grading.organic_dual_contour,
      job.grading.organic_dc_cell_mm, job.grading.organic_dc_tolerance_mm,
      job.grading.organic_calibrate_on_shipped, laid_fn ? &laid_fn : nullptr,
      organic.ran ? nullptr : &solid_probe,
      graded ? job.grading.min_extrudable_width_mm : job.lattice.min_extrudable_width_mm,
      region_shell.triangles.empty() ? nullptr : &region_shell,
      any_zone_skin ? &skin_zones : nullptr, rim_asked ? &mesh_rim : nullptr,
      part_surface);
  if (rim_asked) {
    // ★ TOPOPT_RIM_DUMP=<file>: the chains the rim was asked to ride, one "CHAIN" line each
    // (closed, points, length mm) and then its points -- evidence and tests read where the
    // rim went without a mesh parser. Never written unless asked.
    if (const char* dump = std::getenv("TOPOPT_RIM_DUMP")) {
      if (FILE* f = std::fopen(dump, "w")) {
        for (const LatticeMeshRimChain& c : mesh_rim.chains) {
          double len = 0.0;
          for (std::size_t i = 0; i + 1 < c.points.size(); ++i) {
            const Vec3& a = c.points[i];
            const Vec3& b = c.points[i + 1];
            len += std::sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) +
                             (b.z - a.z) * (b.z - a.z));
          }
          std::fprintf(f, "CHAIN %d %zu %.6f\n", c.closed ? 1 : 0, c.points.size(), len);
          for (const Vec3& p : c.points) std::fprintf(f, "%.6f %.6f %.6f\n", p.x, p.y, p.z);
        }
        std::fclose(f);
      }
    }
    R.oc.rim_edges = rim_edges;
    R.oc.rim_chains_other_skin = rim_other_skin;
    R.oc.rim_line_width_mm = mesh_rim.line_width_mm;
    R.oc.rim_rides = rim_rides;
  }
  // ★ THE EXPORT'S RETURN REPLACES THE WHOLE OUTCOME, and the growth stats copied
  // onto it above went with it -- the receipt read growth_ran: false and zero ties on
  // every grown run until 2026-09-05. Copy them again, after the replacement.
  R.oc.growth = organic.growth;
  R.oc.growth_ran = organic.growth_ran;
  R.gen_seconds = wall_seconds() - tg0;
  // ── ★ K4: THE PLAN AS LAID, PER REGION AND PER GROUP ─────────────────────────
  // The summary (anystep_cells / regions / passes / histogram) says how many. This says
  // WHICH, and it is built from `plan_groups` and the generator's own ledger rather than
  // re-derived: every number here is either the plan as validated or what the tap
  // counted, so the receipt cannot agree with the law while disagreeing with the file.
  //
  // ★ WHY THE PHASE IS HERE. `stepped_group_cells` buckets by (region, size, phase),
  // where the phase is the group origin's offset modulo its OWN size -- two cells of the
  // same size on offset grids are different passes, and nothing in the receipt said so.
  // The app packs on the slot grid, so the phase against THAT grid is the number it can
  // check its own packer against.
  if (!plan_groups.empty()) {
    R.plan_laid_unattributed = plan_laid_unattributed;
    R.plan_laid_measured = (laid_fn != nullptr);
    for (const SteppedPlanRegion& pr : plan_regions) {
      RunInfo::PlanRegion rr;
      rr.region_id = pr.region_id;
      rr.base_cell_mm = pr.base_cell_mm;
      rr.slot_origin_mm[0] = pr.slot_origin.x;
      rr.slot_origin_mm[1] = pr.slot_origin.y;
      rr.slot_origin_mm[2] = pr.slot_origin.z;
      rr.slot_origin_stated = pr.slot_origin_stated;
      rr.plane_origin_mm[0] = pr.plane_origin.x;
      rr.plane_origin_mm[1] = pr.plane_origin.y;
      rr.plane_origin_mm[2] = pr.plane_origin.z;
      rr.normal[0] = pr.normal.x;
      rr.normal[1] = pr.normal.y;
      rr.normal[2] = pr.normal.z;
      rr.depth_mm = pr.depth_mm;
      // Sizes descending, the same order as the histogram, so the two can be read
      // against each other entry for entry.
      std::map<double, long long, std::greater<double>> per_size;
      for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
        const SteppedCellGroup& g = plan_groups[gi];
        if (g.region_id != pr.region_id) continue;
        per_size[g.size_mm] += static_cast<long long>(g.cells.size());
        RunInfo::PlanGroup gg;
        gg.size_mm = g.size_mm;
        gg.origin_mm[0] = g.origin.x;
        gg.origin_mm[1] = g.origin.y;
        gg.origin_mm[2] = g.origin.z;
        const double off[3] = {g.origin.x - pr.slot_origin.x,
                               g.origin.y - pr.slot_origin.y,
                               g.origin.z - pr.slot_origin.z};
        for (int a = 0; a < 3; ++a) {
          double ph = std::fmod(off[a], g.size_mm);
          if (ph < 0.0) ph += g.size_mm;        // into [0, size)
          gg.phase_mm[a] = ph;
        }
        gg.nx = g.nx; gg.ny = g.ny; gg.nz = g.nz;
        gg.cells = static_cast<long long>(g.cells.size());
        if (gi < plan_laid_struts.size())
          for (std::size_t n = 0; n < plan_laid_struts[gi].size(); ++n) {
            gg.struts_laid += plan_laid_struts[gi][n];
            gg.nodes_laid += plan_laid_nodes[gi][n];
            if (plan_laid_struts[gi][n] != 0) continue;
            ++gg.cells_with_no_strut;
            // ★ ruling 3: and WHY, per cell, so the count is a diagnosis.
            if (laid_fn == nullptr) continue;   // nobody counted: no cause to give
            const std::array<int, 3>& c = g.cells[n];
            const Vec3 ctr{g.origin.x + (c[0] + 0.5) * g.size_mm,
                           g.origin.y + (c[1] + 0.5) * g.size_mm,
                           g.origin.z + (c[2] + 0.5) * g.size_mm};
            switch (classify_no_strut(g.region_id, ctr, g.size_mm)) {
              case NoStrutCause::OutsideRect:    ++gg.no_strut_outside_rect; break;
              case NoStrutCause::BeyondDepth:    ++gg.no_strut_beyond_depth; break;
              case NoStrutCause::OutsideOutline: ++gg.no_strut_outside_outline; break;
              case NoStrutCause::OwnedElsewhere: ++gg.no_strut_owned_elsewhere; break;
              case NoStrutCause::NoMaterial:     ++gg.no_strut_no_material; break;
              case NoStrutCause::CellOverlapDropped:
                ++gg.no_strut_cell_overlap_dropped; break;
              case NoStrutCause::NeverGenerated: ++gg.no_strut_never_generated; break;
            }
          }
        rr.groups.push_back(std::move(gg));
        rr.cells += static_cast<long long>(g.cells.size());
      }
      for (const auto& kv : per_size) {
        char sb[48];
        std::snprintf(sb, sizeof sb, "%s%.3f=%lld", rr.sizes.empty() ? "" : ", ",
                      kv.first, kv.second);
        rr.sizes += sb;
      }
      R.plan_by_region.push_back(std::move(rr));
    }
    // ── ★ THE LEDGER FILE (job key lattice.emit_plan_laid) ─────────────────────
    // One line per PLAN cell -- laid or not -- so the app's classifier has core's own
    // answer per cell instead of having to infer it from a mesh. Written only when the
    // key is set; a run without it writes nothing, so no existing artifact changes.
    if (job.lattice.emit_plan_laid) {
      // The SAME base name the meshes use (lattice_base_name), so the ledger sits
      // beside its own file and the rung is the file's rung, not one recomputed here.
      const std::string lp =
          join_path(out_dir, lattice_base_name(job.output.mesh_prefix,
                                               v.requested_volume_fraction)) +
          "_LAID.txt";
      std::ofstream lf(lp);
      if (lf) {
        lf.setf(std::ios::fmtflags(0), std::ios::floatfield);
        lf.precision(10);
        lf << "# K4 laid plan. One LAID line per plan cell, in the plan's own order\n"
              "# (region, then size descending, then cell index). CENTRE is the cell's\n"
              "# centre in part coordinates. struts/nodes are what the GENERATOR emitted\n"
              "# and attributed to that cell (a ball at its centre, a strut fragment at\n"
              "# its midpoint, which is where its radius was sampled).\n"
              "# LAID <region> <cx> <cy> <cz> <size_mm> <rho> <struts> <nodes> <why>\n"
              "#   why is \"laid\" when struts > 0, else the FIRST thing that stopped it:\n"
              "#   outside_rect | beyond_depth | outside_outline | owned_elsewhere |\n"
              "#   no_material | cell_overlap_dropped | never_generated. Only\n"
              "#   never_generated is unexplained --\n"
              "#   every other value is a reason the app can see in its own data.\n";
        lf << "PLAN " << plan_chk.cells << ' ' << plan_chk.regions << ' '
           << plan_groups.size() << ' ' << plan_laid_unattributed << '\n';
        for (std::size_t gi = 0; gi < plan_groups.size(); ++gi) {
          const SteppedCellGroup& g = plan_groups[gi];
          for (std::size_t n = 0; n < g.cells.size(); ++n) {
            const std::array<int, 3>& c = g.cells[n];
            const Vec3 ctr{g.origin.x + (c[0] + 0.5) * g.size_mm,
                           g.origin.y + (c[1] + 0.5) * g.size_mm,
                           g.origin.z + (c[2] + 0.5) * g.size_mm};
            const long long st = gi < plan_laid_struts.size()
                                     ? plan_laid_struts[gi][n] : 0;
            const char* why = "laid";
            if (st == 0) switch (classify_no_strut(g.region_id, ctr, g.size_mm)) {
              case NoStrutCause::OutsideRect:    why = "outside_rect"; break;
              case NoStrutCause::BeyondDepth:    why = "beyond_depth"; break;
              case NoStrutCause::OutsideOutline: why = "outside_outline"; break;
              case NoStrutCause::OwnedElsewhere: why = "owned_elsewhere"; break;
              case NoStrutCause::NoMaterial:     why = "no_material"; break;
              case NoStrutCause::CellOverlapDropped:
                why = "cell_overlap_dropped"; break;
              case NoStrutCause::NeverGenerated: why = "never_generated"; break;
            }
            lf << "LAID " << g.region_id << ' ' << ctr.x << ' ' << ctr.y << ' '
               << ctr.z << ' ' << g.size_mm << ' '
               << (n < g.rho.size() ? g.rho[n] : 0.0) << ' ' << st << ' '
               << (gi < plan_laid_nodes.size() ? plan_laid_nodes[gi][n] : 0) << ' '
               << why << '\n';
          }
        }
        std::printf("plan laid: %zu cell(s) written to %s\n", plan_chk.cells,
                    lp.c_str());
      }
    }
  }

  // ── ★ K5: WHERE EVERY STRUT AND NODE GOT ITS DENSITY ─────────────────────────
  // The generator samples the radius at a strut's MIDPOINT and at a node's own position
  // (lattice_gen.cpp). Both of those sit on cell planes for the octet -- a corner node is
  // shared by eight cells, a face-diagonal strut's midpoint lies in a shared face -- so
  // this is the count that says whether the plan's density actually reached them.
  // `at the band floor` is the one that must be 0 on a plan that sent a rho with every
  // cell: a boundary joint sized at the thinnest density the law allows, where the plan
  // asked for something else, is a notch exactly where the load leaves the lattice.
  if (!plan_groups.empty()) {
    R.plan_rho_queries_plan = rho_q_plan - rho_q_plan0;
    R.plan_rho_queries_posture = rho_q_posture - rho_q_posture0;
    R.plan_rho_queries_floor = rho_q_floor - rho_q_floor0;
    std::fprintf(stderr,
                 "[stepped] plan rho reach: %lld strut/node radius queries from the "
                 "plan's own cells, %lld from the posture (off every plan cell), %lld at "
                 "the band floor (outside the mask)\n",
                 R.plan_rho_queries_plan, R.plan_rho_queries_posture,
                 R.plan_rho_queries_floor);
  }

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
  // ★ BRACES. This `if` had none, and inserting the receipt write below turned the
  // write into its entire body and the throw into an UNCONDITIONAL statement — every
  // lattice run then refused with "0 vertex/vertices on 0 element(s), the worst by
  // 0 mm", and six tests aborted. A brace-less body that grows a second statement is
  // a silent behaviour change; braces make it impossible.
  if (R.oc.protrusion_measured &&
      R.oc.max_protrusion_mm > R.oc.protrusion_allowance_mm) {
    // ── ★★ A REFUSAL CARRIES A RECEIPT ─────────────────────────────────────────
    // This throw aborts before run_info.json is written, so a refused run used to be
    // undiagnosable: the organic census -- support rounds, legs, cuts, the cleanup
    // prune, unsupported cells remaining -- was measured and then thrown away with
    // the exception. Diagnosing refusal 1 needed exactly those numbers on a run that
    // refuses HERE, which is why a gate-off replay was being asked for.
    //
    // The counters exist on R.oc by this point. Write them, marked refused and with
    // the reason attached, so the next question can be answered from the run that
    // failed rather than from a second run with a guard disabled.
    write_refusal_receipt(out_dir, "lattice_protrusion", R.oc);
    throw JobError(
        // ★ UNIQUE POINTS AND THE ELEMENTS THEY SIT ON. The old wording counted
        // triangle CORNERS: "5 of 980892 lattice vertices" was ONE vertex of valence
        // five on ONE strut end cap. Reporting corners made a single escaping cap
        // read as a tolerance population and sent the diagnosis after a structure
        // that emits five endpoints, which does not exist.
        "lattice geometry escaped the exported shell: " +
        std::to_string(R.oc.protruding_unique_vertices) + " vertex/vertices on " +
        std::to_string(R.oc.protruding_elements) + " element(s), the worst by " +
        json_num(R.oc.max_protrusion_mm) +
        " mm proud, at (" + json_num(R.oc.worst_protrusion_at.x) + ", " +
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
  }

  // ── M4: A SKIN MODE THAT PRODUCED NOTHING MUST SAY SO. The full root cause and
  // why the predicate is the MEASURED count rather than a prediction are on
  // export_latticed_variant. In short: the first version tested
  // `boundary.faces().empty()`, which is too narrow — a BOLT clearance makes
  // faces() non-empty while still emitting zero rim, because the dispatch
  // (lattice_gen.cpp:944-961) needs a PLANE and lattice_boundary_for never makes
  // one. Testing what the generator actually wrote makes the blast radius exact by
  // construction: it cannot fire on a run that emitted geometry.
  // ★ Per zone: the part's "rim" is judged on its own rim, so a zone's woven skin cannot
  // stand in for it. (Rim mode lays no diagrid, so without zones this is the same test.)
  // ★ The rim on a real part (ruling 11-08 (A)): a rim that found no sharp edge to ride
  // says so in its own words, with the counts that decided it.
  if (job.lattice.skin == "rim" && R.oc.mesh_rim_ran && R.oc.stats.rim_triangles == 0) {
    const FeatureEdgeStats& fe = R.oc.rim_edges;
    throw JobError(
        "lattice \"skin\": \"rim\" laid no rim on this part: the surface it ships has " +
        std::to_string(fe.feature_edges) + " edge(s) sharper than " +
        json_num(fe.angle_threshold_deg) + " degrees, " +
        std::to_string(fe.pieces_dropped_short) + " piece(s) of them shorter than one cell (" +
        json_num(fe.min_piece_mm) + " mm, dropped), " +
        std::to_string(R.oc.rim_chains_other_skin) +
        " chain(s) in zones that ask for another skin, " +
        std::to_string(R.oc.rim.chains_on_solid) +
        " chain(s) along material the lattice leaves solid (a solid edge needs no rim), and " +
        std::to_string(R.oc.rim.chains_clipped_away) +
        " chain(s) with no room inside the part for a rim of " +
        json_num(R.oc.rim.diameter_max_mm) +
        " mm.\n  Refusing rather than exporting an undressed lattice under a finish the job "
        "asked for. Set \"skin\": \"none\" to export it undressed.");
  }
  if (job.lattice.skin != "none" &&
      R.oc.stats.rim_triangles +
              (job.lattice.skin == "rim" ? 0 : R.oc.stats.skin_triangles) ==
          0)
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
  // ★ GRADING + A DESIGN BOX: on a SWEPT run (one grid per level) or a run of passes
  // (stepped, or the app's plan), the same two questions are asked of EVERY grid the
  // generator lays, through that grid's own activation chain (its predicate AND the
  // boundary-overlap proof): a cell it emits must cover a voxel of the final mask
  // (certified == emitted, summed over the grids), and no companion-solid voxel may sit
  // in an emitted cell that covers none. The single `cell` grid below is what the
  // uniform and one-cell graded runs lay, and is audited as before.
  const bool multi_grid = (levels.size() > 1 && gf.cell_plan.base_cell_mm > 0.0) ||
                          !stepped_passes.empty();
  if (added_rcpt.present && multi_grid) {
    added_rcpt.multi_grid = true;
    struct AuditGrid {
      Vec3 o;
      double ce;
      int nx, ny, nz;
      std::function<bool(int, int, int)> pred;
      const LatticeBoundary* b;
      const std::vector<char>* cov;
    };
    std::vector<AuditGrid> grids;
    if (levels.size() > 1 && gf.cell_plan.base_cell_mm > 0.0) {
      const CellSizePlan& pl = gf.cell_plan;
      for (const LatticeLevelSpec& sp : levels) {
        const int LV = sp.level;
        const int lnx = (pl.nx + (1 << LV) - 1) >> LV, lny = (pl.ny + (1 << LV) - 1) >> LV,
                  lnz = (pl.nz + (1 << LV) - 1) >> LV;
        const double ce = pl.base_cell_mm * (1 << LV);
        grids.push_back({pl.origin, ce, lnx, lny, lnz, sp.latticed, &boundary,
                         cover_of_mask(pl.origin, ce, lnx, lny, lnz)});
      }
    }
    for (const LatticeSteppedPass& sp : stepped_passes) {
      const LatticeRegion& PR = sp.region;
      grids.push_back({PR.origin, PR.cell_mm, PR.nx, PR.ny, PR.nz, PR.latticed,
                       PR.boundary != nullptr ? PR.boundary : &boundary,
                       cover_of_mask(PR.origin, PR.cell_mm, PR.nx, PR.ny, PR.nz)});
    }
    auto at = [](const AuditGrid& g, int ci, int cj, int ck) {
      return (static_cast<std::size_t>(ck) * g.ny + cj) * g.nx + ci;
    };
    auto emitted = [&](const AuditGrid& g, int ci, int cj, int ck) {
      if (g.pred && !g.pred(ci, cj, ck)) return false;
      return g.b->cell_may_overlap(
          Vec3{g.o.x + ci * g.ce, g.o.y + cj * g.ce, g.o.z + ck * g.ce}, g.ce);
    };
    for (const AuditGrid& g : grids)
      for (int ck = 0; ck < g.nz; ++ck)
        for (int cj = 0; cj < g.ny; ++cj)
          for (int ci = 0; ci < g.nx; ++ci) {
            if (!emitted(g, ci, cj, ck)) continue;
            if ((*g.cov)[at(g, ci, cj, ck)]) ++added_rcpt.certified_lattice_cells;
            else ++added_rcpt.emitted_cells_covering_no_certified;
          }
    added_rcpt.emitted_lattice_cells = R.oc.stats.latticed_cells;
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          if (!is_companion_solid(i, j, k)) continue;
          const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                       solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                       solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
          int state = 0;  // 0 in no emitted cell, 1 the bond, 2 a cell covering none
          for (const AuditGrid& g : grids) {
            const int ci = clampi(static_cast<int>(std::floor((c.x - g.o.x) / g.ce)), g.nx - 1);
            const int cj = clampi(static_cast<int>(std::floor((c.y - g.o.y) / g.ce)), g.ny - 1);
            const int ck = clampi(static_cast<int>(std::floor((c.z - g.o.z) / g.ce)), g.nz - 1);
            if (!emitted(g, ci, cj, ck)) continue;
            state = std::max(state, (*g.cov)[at(g, ci, cj, ck)] ? 1 : 2);
          }
          if (state == 2) ++added_rcpt.voxels_strut_and_solid;
          else if (state == 1) ++added_rcpt.voxels_strut_and_solid_bond;
        }
  }
  if (added_rcpt.present && !multi_grid) {
    // ★ Finding 7: the certified cell set is every cell COVERING a masked voxel (the
    // cover rule the activation now uses), so certified == emitted still holds cell
    // for cell.
    std::vector<char> certified_cells(ncells, 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i)
          if (mask[solved_grid.index(i, j, k)])
            for_covering_cells(i, j, k,
                               [&](std::size_t ce) { certified_cells[ce] = 1; });
    for (const char c : certified_cells)
      added_rcpt.certified_lattice_cells += (c ? 1 : 0);
    added_rcpt.emitted_lattice_cells = R.oc.stats.latticed_cells;
    // "Inside a strut cell" iff its owning cell is one the generator emitted —
    // the same cell_active test, asked here with the same inputs. ★ Finding 7: a
    // cell covering a certified voxel now reaches into the solid beside it by design
    // (the bond); that is not the failure this counts. The failure is struts written
    // into solid by a cell that covers NO certified voxel at all.
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          if (!is_companion_solid(i, j, k)) continue;
          const std::array<int, 3> c = owner_ijk(i, j, k);
          if (!cell_emitted(c)) continue;
          if (certified_cells[cidx(c[0], c[1], c[2])])
            ++added_rcpt.voxels_strut_and_solid_bond;
          else
            ++added_rcpt.voxels_strut_and_solid;
        }
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
          // ★ Finding 7: the cells COVERING it, as the activation now lays them.
          const bool fr = is_frozen(e);
          for_covering_cells(i, j, k, [&](std::size_t ce) {
            any_cert_cells[ce] = 1;
            if (fr) frozen_cert_cells[ce] = 1;
          });
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
  // ── ★★ THE DENSITY THE CERTIFICATE JUDGES IS REBUILT FROM WHAT SHIPPED ───────
  // (maintainer, 2026-09-11: "fix the timing first".) It used to be the tracer's own
  // snapshot, taken BEFORE the clip to the part, the node merge, the support pass, the
  // prune, the stranded drop, the finish and the base trim -- all of which run afterwards
  // and on a SEPARATE span list, so nothing refreshed it. Whatever they removed, the
  // certificate still believed was there, and the error is in the UNSAFE direction:
  // more material reads as stiffer and stronger. MEASURED on the M2 stand: the
  // certificate was handed 77,336 mm3 where the shipped file holds 41,955 -- it was
  // judging 1.84x the lattice that exists.
  //
  // `organic_spans_out` is the post-clip set, the same one the STL and the welded body
  // are built from, so the certificate and the file now describe one object. The
  // candidate set and the local separation come from the tracer's own `spacing_used_mm`
  // (0 marks a voxel off the candidate set), and the clamp band is the one the tracer
  // used, so nothing about the MEASUREMENT changes -- only which geometry it is taken on.
  if (organic.ran && graded && !R.oc.organic_spans_out.empty() &&
      organic.lat.spacing_used_mm.size() == solved_grid.voxel_count()) {
    std::vector<char> cand(solved_grid.voxel_count(), 0);
    for (std::size_t e = 0; e < cand.size(); ++e)
      cand[e] = organic.lat.spacing_used_mm[e] > 0.0 ? 1 : 0;
    OrganicDensityField df = organic_relative_density(
        solved_grid, cand, organic.lat.spacing_used_mm, R.oc.organic_spans_out,
        organic.rho_min_used, organic.rho_max_used,
        job.grading.organic_density_union_subdiv);
    const double vox =
        solved_grid.spacing * solved_grid.spacing * solved_grid.spacing;
    double shipped = 0.0;
    for (std::size_t e = 0; e < df.relative_density.size(); ++e)
      if (df.mask[e]) shipped += df.relative_density[e];
    shipped *= vox;
    // ★ AND SOME VOXELS THE TRIM EMPTIED COMPLETELY. The certification mask is the
    // geometry's, and a voxel in it that the shipped spans never reach now measures
    // ZERO -- which the octet certifier refuses outright ("relative density 0.000000 is
    // outside the certifiable band", bar E5), and rightly: there is no lattice there to
    // homogenise. They are held at the band's FLOOR rather than dropped, because
    // dropping them would make the certified mask differ from the geometry's, which is
    // the exact conflation bar E1 exists to prevent. Counted and printed, because the
    // floor is still GENEROUS for a voxel holding nothing at all.
    std::size_t emptied = 0;
    for (std::size_t e = 0; e < df.mask.size() && e < mask.size(); ++e)
      if (mask[e] && !df.mask[e]) {
        df.mask[e] = 1;
        df.relative_density[e] = organic.rho_min_used;
        ++emptied;
      }
    std::fprintf(stderr,
                 "[posture] certified on the SHIPPED spans (%s): %.1f mm3 of lattice "
                 "material over %zu voxel(s); the traced network it used to be taken "
                 "from held %.1f mm3 (%+.1f %%). %zu voxel(s) the trim emptied "
                 "entirely, held at the band floor %.4f; %zu raised to it and %zu "
                 "capped at the ceiling by the band\n",
                 job.grading.organic_density_union_subdiv > 0 ? "UNION" : "deposit",
                 shipped, df.latticed_voxels, organic_traced_material_mm3,
                 organic_traced_material_mm3 > 0.0
                     ? 100.0 * (shipped - organic_traced_material_mm3) /
                           organic_traced_material_mm3
                     : 0.0,
                 emptied, organic.rho_min_used, df.clamped_lo_voxels,
                 df.clamped_hi_voxels);
    gf.posture.mask = df.mask;
    gf.posture.relative_density = df.relative_density;
  }

  // ── ★ THE VOLUME CHECK (Finding 7, ruling 2026-11-02) ──────────────────────────
  // Before the certificate is built: per latticed pocket, the lattice the file holds
  // against the density the certificate is about to read over the same voxels
  // (lattice_volume_check.hpp). More than 10 % off in any pocket and this rung is
  // refused, its lattice files removed, exactly as a sealed cavity refuses one.
  // ★ AND THE CERTIFICATE IS REBUILT FROM WHAT SHIPPED (ruling 2026-11-02 (3)): each
  // latticed voxel at min(the law's density, the solid fraction the file holds there,
  // measured on the same exact solids), held at the band's floor where the file holds less
  // (lattice_certify_shipped). The check then judges the REBUILT certificate: its 10 %
  // guard is the tripwire on what the floor credits. The law's own gap is kept beside it.
  std::vector<double> shipped_rho;  // the certified density, when rebuilt
  if (!organic.ran && solid_probe.has_geometry()) {
    const std::vector<double>* grho = graded ? &gf.posture.relative_density : nullptr;
    auto law_rho = [grho, rho_uniform](std::size_t e) { return grho ? (*grho)[e] : rho_uniform; };
    // A pocket is judged from one cell up: the largest cell this export lays.
    double judge_cell = cell;
    for (const LatticeLevelSpec& lv : levels) judge_cell = std::max(judge_cell, lv.cell_mm);
    for (const LatticeSteppedPass& sp : stepped_passes)
      judge_cell = std::max(judge_cell, sp.region.cell_mm);
    const double judge_mm3 = judge_cell * judge_cell * judge_cell;
    std::vector<double> frac;
    R.volume_check_law =
        lattice_volume_check(solved_grid, mask, law_rho, solid_probe, judge_mm3, &frac);
    const double vox =
        solved_grid.spacing * solved_grid.spacing * solved_grid.spacing;
    LatticeShippedPosture sp =
        lattice_certify_shipped(mask, law_rho, frac, lattice_rho_min(lat_topo), vox);
    R.shipped_lowered = sp.voxels_lowered;
    R.shipped_at_floor = sp.voxels_at_floor;
    R.shipped_law_mm3 = sp.law_mm3;
    R.shipped_certified_mm3 = sp.certified_mm3;
    shipped_rho = std::move(sp.relative_density);
    const std::vector<double>& srho = shipped_rho;
    R.volume_check = lattice_volume_judge(
        solved_grid, mask, [&srho](std::size_t e) { return srho[e]; }, frac, judge_mm3);
    R.volume_check.points = R.volume_check_law.points;
    std::fprintf(stderr,
                 "[lattice] vf=%.2f certificate from what shipped: the law counted %.1f mm3, "
                 "the file holds %.1f; certified %.1f mm3 (%lld voxel(s) lowered to the "
                 "file, %lld of them held at the band floor %.4f)\n",
                 v.requested_volume_fraction, sp.law_mm3, R.volume_check_law.exported_mm3,
                 sp.certified_mm3, sp.voxels_lowered, sp.voxels_at_floor,
                 lattice_rho_min(lat_topo));
    const LatticeVolumeCheck& vc = R.volume_check;
    if (vc.ran && !vc.pockets.empty()) {
      const long long wvox =
          vc.worst >= 0 ? vc.pockets[static_cast<std::size_t>(vc.worst)].voxels : 0;
      std::fprintf(stderr,
                   "[lattice] vf=%.2f volume check: %zu pocket(s), exported %.1f / "
                   "certified %.1f mm3 (%+.2f %%); lightest judged pocket %lld voxels %+.2f %% "
                   "(heaviest %+.2f %%); "
                   "%lld pocket(s) under one cell not judged (%.1f / %.1f mm3) "
                   "(%lld points, %.2f s)\n",
                   v.requested_volume_fraction, vc.pockets.size(), vc.exported_mm3,
                   vc.certified_mm3,
                   vc.certified_mm3 > 0.0 ? 100.0 * (vc.exported_mm3 / vc.certified_mm3 - 1.0)
                                          : 0.0,
                   wvox, 100.0 * vc.worst_gap, 100.0 * vc.highest_gap, vc.small_pockets,
                   vc.small_exported_mm3,
                   vc.small_certified_mm3, vc.points, vc.seconds);
    }
    if (vc.refused()) {
      R.volume_refused = true;
      R.volume_refused_reason = lattice_volume_refusal(vc);
      // Everything this export wrote beside the lattice goes with it: the file(s), and the
      // span and laid-cell ledgers when they were asked for.
      for (const std::string& path : R.oc.paths) {
        std::remove(path.c_str());
        const std::size_t dot = path.find_last_of('.');
        const std::string stem = dot == std::string::npos ? path : path.substr(0, dot);
        std::remove((stem + "_SPANS.txt").c_str());
        std::remove((stem + "_LAID.txt").c_str());
      }
      R.oc.paths.clear();
      return R;
    }
  }

  // (b) certification of the composite — the octet tensor on the SAME mask the
  // geometry used. The band is enforced PER VOXEL inside the solve (E5/H4b).
  const LatticeCertContext cx =
      lattice_cert_context(v, part_grid, domain, options, material, job);
  // ★ (3): the certificate reads the density REBUILT from what shipped, when it was.
  // ★ E3: each region's graded range, read before the as-built rebuild below.
  if (!e3_owner.empty()) {
    R.region_graded.assign(e3_jobs.size(), {});
    std::vector<char> seen(e3_jobs.size(), 0);
    for (std::size_t e = 0; e < gf.posture.mask.size() && e < e3_owner.size(); ++e) {
      const int id = e3_owner[e];
      if (!gf.posture.mask[e] || id < 1 || static_cast<std::size_t>(id) > e3_jobs.size()) continue;
      LatticeRegionGraded& g = R.region_graded[static_cast<std::size_t>(id - 1)];
      const double r = gf.posture.relative_density[e];
      const double cm = e < gf.posture.cell_size_field.size() ? gf.posture.cell_size_field[e] : 0.0;
      if (!seen[static_cast<std::size_t>(id - 1)]) {
        g.rho_lo = g.rho_hi = r;
        g.cell_lo = g.cell_hi = cm;
        seen[static_cast<std::size_t>(id - 1)] = 1;
      }
      g.rho_lo = std::min(g.rho_lo, r);
      g.rho_hi = std::max(g.rho_hi, r);
      g.cell_lo = std::min(g.cell_lo, cm);
      g.cell_hi = std::max(g.cell_hi, cm);
      ++g.voxels;
    }
    for (std::size_t i = 0; i < e3_search.size() && i < R.region_graded.size(); ++i)
      if (e3_search[i].searched) {
        LatticeRegionGraded& g = R.region_graded[i];
        g.searched = true;
        g.search_certified = e3_search[i].search_certified;
        g.search_rho = e3_search[i].search_rho;
        g.search_floor = e3_search[i].search_floor;
        g.search_peak = e3_search[i].search_peak;
        g.search_margin = e3_search[i].search_margin;
        g.search_trials = e3_search[i].search_trials;
        g.search_shipped_trials = e3_search[i].search_shipped_trials;
        g.search_law_rho = e3_search[i].search_law_rho > 0.0 ? e3_search[i].search_law_rho
                                                             : e3_search[i].search_rho;
      }
  }
  if (graded && !shipped_rho.empty()) gf.posture.relative_density = shipped_rho;
  const LatticePosture post = [&] {
    LatticePosture p = build_lattice_posture(
        lat_topo, solved_grid, cell, mask, rho_uniform,
        !shipped_rho.empty() ? &shipped_rho : graded ? &gf.posture.relative_density : nullptr);
    // ★ The widths measured on the part's own surface ride to the certificate's floor
    // guard (ruling 11-09); empty => it measures the staircase, as before.
    if (gf.posture.member_width_mm.size() == p.mask.size())
      p.member_width_mm = gf.posture.member_width_mm;
    return p;
  }();
  // ★ E2.4: the open lattice's cut cells, given no credit (open_finish_cut_cells).
  std::vector<char> open_cut;
  if (!region_open.empty()) {  // per region: the open part only, beside its wall
    open_cut = open_finish_cut_cells(solved_grid, dens, printed_iso, post);
    for (std::size_t e = 0; e < open_cut.size(); ++e)
      if (!region_open[e]) open_cut[e] = 0;
  } else if (job.lattice.outer_finish == "none") {
    open_cut = open_finish_cut_cells(solved_grid, dens, printed_iso, post);
  }
  R.cc = certify_latticed_variant(
      v, solved_grid, options, material, bcs, cx, post,
      graded ? std::numeric_limits<double>::quiet_NaN() : rho_uniform,
      open_cut.empty() ? nullptr : &open_cut);
  for (const LatticeVariantOutcome::OpenRegion& o : R.open_regions)
    R.cc.open_region_notes.push_back(
        o.name + (R.region_wall_voxels > 0
                      ? " open: a wall closes it from the covered part"
                      : " open: the part's own solid already closes it from the covered part"));
  R.cc.region_wall_mm = R.region_wall_mm;
  R.cc.region_wall_voxels = R.region_wall_voxels;
  // Refused by label: the regions that hold cut cells (the owner rule the grading used),
  // or "the part" where a cut cell lies in no include region.
  if (R.cc.open_finish && !R.cc.lattice.accepted) {
    const std::vector<ClearanceGeometry>& owners =
        lattice_roles.includes.empty() ? lattice_roles.carriers : lattice_roles.includes;
    std::vector<char> named(e3_jobs.size() + 1, 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!open_cut[e]) continue;
          const int id = owners.empty()
                             ? 0
                             : stepped_region_owner(solved_grid.voxel_center(i, j, k), owners);
          named[static_cast<std::size_t>(
              id >= 1 && static_cast<std::size_t>(id) <= e3_jobs.size() ? id : 0)] = 1;
        }
    std::string who;
    for (std::size_t id = 1; id < named.size(); ++id)
      if (named[id]) {
        const std::string& lb = e3_jobs[id - 1].label;
        who += std::string(who.empty() ? "" : ", ") +
               (lb.empty() ? "region " + std::to_string(id) : "\"" + lb + "\"");
      }
    if (named[0] || who.empty()) who += std::string(who.empty() ? "" : " and ") + "the part";
    char why[300];
    if (!R.cc.open_load_path_ok)
      std::snprintf(why, sizeof why,
                    "no load path is left through the rest (a load or a support sits on "
                    "those cells)");
    else if (R.cc.lattice.lattice_not_certified)
      std::snprintf(why, sizeof why, "%s", R.cc.lattice.lattice_not_certified_reason.c_str());
    else
      std::snprintf(why, sizeof why, "the margin is %.3g against %.3g needed",
                    R.cc.lattice.margin_effective, options.margin_stop);
    char counts[200];
    std::snprintf(counts, sizeof counts,
                  " does not certify open. With the %lld of %lld latticed voxels in cells "
                  "at the part's free surface given no strength (the safe floor), ",
                  R.cc.open_cut_voxels, R.cc.open_latticed_voxels);
    R.cc.open_refusal = "The open lattice in " + who + counts + why +
                        ". Covered (a solid shell) holds those cells.";
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ★★★ ORGANIC STRUCTURAL CERTIFICATION — the instrument, where the gate was ★★★
  // certify_latticed_variant above reads a DENSITY against the OCTET tensor. Organic
  // traces struts ALONG the principal stress directions, so its geometry is
  // anisotropic by construction and no tensor has ever been measured for it: that
  // number would describe a material this lattice is not. It is exactly why
  // refuse_organic_structural exists.
  //
  // This certifies the geometry DIRECTLY — the emitted spans as a welded beam
  // network, tied into the solid, solved under every load case — so no homogenised
  // tensor is involved and the objection does not apply.
  if (job.grading.algorithm == "organic" && job.grading.intent == "structural") {
    // ★ THE CENSUS MUST BE READABLE. A stage that recorded one dimension and not the
    // other is the sentinel defect (item 6): "null" then stops meaning "did not run",
    // and a lattice whose own pipeline cannot be shown to have run is not
    // certifiable. This checks CONSISTENCY, not absence -- a pass that genuinely did
    // not run reports null in BOTH and that is fine.
    bool census_ok = !R.oc.organic_census_len_mm.empty() &&
                     R.oc.organic_census_len_mm.size() ==
                         R.oc.organic_census_components.size();
    if (census_ok)
      for (std::size_t i = 0; i < R.oc.organic_census_len_mm.size(); ++i)
        if ((R.oc.organic_census_len_mm[i] >= 0.0) !=
            (R.oc.organic_census_components[i] >= 0))
          census_ok = false;

    std::vector<BeamSegment> segs;
    segs.reserve(R.oc.organic_spans_out.size());
    for (const OrganicSpan& sp : R.oc.organic_spans_out)
      segs.push_back({sp.a, sp.b, sp.r});

    // ── ★★ THE WELD'S PRECONDITION, ENFORCED HERE RATHER THAN ASSUMED ──────────
    // (brief of 2026-09-17 §3.2.) build_beam_network welds ENDPOINTS. The organic tracer
    // emits ~0.85 mm segments and satisfies that by accident of how it draws; an OCTET
    // strut is one straight member up to a whole base cell long, so a strut ending on the
    // middle of another has no vertex near the contact and is NOT fused. The failure is
    // silent -- it reports a lattice in pieces, and a lattice in pieces certifies CLEAN,
    // because nothing in it is carrying load to find fault with. So every input is cut to
    // the scale the weld can actually see: the weld joins ends within r_a + r_b, so a
    // piece no longer than the thinnest strut's DIAMETER puts an endpoint within reach of
    // any contact along a member. Already-fine input is returned untouched and pays
    // nothing.
    {
      double rmin = 0.0;
      double longest = 0.0;
      for (const BeamSegment& sg : segs) {
        if (sg.radius_mm > 0.0 && (rmin <= 0.0 || sg.radius_mm < rmin)) rmin = sg.radius_mm;
        const double dx = sg.b.x - sg.a.x, dy = sg.b.y - sg.a.y, dz = sg.b.z - sg.a.z;
        longest = std::max(longest, std::sqrt(dx * dx + dy * dy + dz * dz));
      }
      const double piece = rmin > 0.0 ? 2.0 * rmin : 0.0;
      const std::size_t before = segs.size();
      if (piece > 0.0 && longest > piece) segs = subdivide_beam_segments(segs, piece);
      const BeamNetwork seam_net = build_beam_network(segs);
      const BeamNetworkSeams seams = beam_network_seams(seam_net);
      std::fprintf(stderr,
                   "[seams] %zu span(s) -> %zu after subdivision at %.3f mm (longest was "
                   "%.2f mm) | %zu welded node(s), %zu T-junction end(s), %zu end(s) on "
                   "NOTHING\n",
                   before, segs.size(), piece, longest, seams.welded_nodes,
                   seams.t_junction_ends, seams.floating_ends);
      R.seam_spans_before = static_cast<long long>(before);
      R.seam_spans_after = static_cast<long long>(segs.size());
      R.seam_piece_mm = piece;
      R.seam_longest_before_mm = longest;
      R.seam_welded_nodes = static_cast<long long>(seams.welded_nodes);
      R.seam_t_junction_ends = static_cast<long long>(seams.t_junction_ends);
      R.seam_floating_ends = static_cast<long long>(seams.floating_ends);
      // ★ AND FOR AN ANY-STEP PLAN IT IS A GATE, NOT A REPORT. Organic legitimately has
      // free tips -- a traced curve ends where the field ran out. An any-step octet plan
      // does not: every strut belongs to a cell whose neighbours are packed against it,
      // so an end on nothing is either a seam the weld failed to find or geometry that
      // never joined, and both mean the network being solved is not the part that prints.
      if (!job.lattice.stepped_cells.empty() && seams.floating_ends > 0) {
        R.organic_cert.verdict = OrganicCertificate::Verdict::Refused;
        R.organic_cert.refusal =
            "the any-step stepped network has " + std::to_string(seams.floating_ends) +
            " strut end(s) terminating on NOTHING after the contact weld. Every strut in "
            "a packed plan belongs to a cell its neighbours are packed against, so an end "
            "on nothing is a seam the weld did not find or geometry that never joined -- "
            "and either way the network solved here is not the part that would print. A "
            "certificate over it would be a claim about a different object.";
      }
    }

    const std::vector<OrganicLoadCase> ocs = organic_load_cases(cx, bcs);

    // The solid the lattice ties into: every voxel the part keeps that the lattice
    // did not replace. `mask` is the latticed set, so the complement inside the part.
    std::vector<char> hexm(solved_grid.voxel_count(), 0);
    for (std::size_t e = 0; e < solved_grid.voxel_count(); ++e)
      if (v.optimization.physical_density[e] > cx.printed_iso && !mask[e]) hexm[e] = 1;

    // ★★ A LATTICE WHOSE SUPPORT PASS WAS SKIPPED CANNOT BE CERTIFIED. The pass
    // records `support_grid_too_large` and carries on -- "the check did not run,
    // which is NOT the same as passing", as its own comment says -- but nothing
    // downstream ever read that flag. MEASURED: a structural grown STAND certified at
    // margin 1.56 with 40,660 mm written, support_rounds 0, islands 0, cuts 0 -- the
    // whole printability pass skipped because the raster exceeded the cap, and the
    // certificate never knew. A structural claim over material no support pass has
    // seen is exactly the green-that-measured-nothing this file keeps refusing.
    if (R.oc.organic_support_grid_too_large) {
      R.organic_cert.verdict = OrganicCertificate::Verdict::Refused;
      R.organic_cert.refusal =
          "the organic support pass was SKIPPED (support raster exceeded its cell "
          "cap: support_grid_too_large), so nothing has checked this lattice for "
          "unsupported material; a structural certificate cannot stand on it. "
          "Coarsen the strut floor or raise the raster cap and re-run.";
    } else if (R.organic_cert.verdict != OrganicCertificate::Verdict::Refused)
    R.organic_cert = certify_organic_structural(
        solved_grid, hexm, segs, ocs, material.youngs_modulus_mpa,
        material.poisson, material.yield_strength_mpa,
        // ★ THE INTERLAYER KNOCKDOWN, PER STRUT, BY ORIENTATION TO THE BUILD
        // DIRECTION -- the same rule orient.cpp applies to a solid (tension across
        // the layer planes is derated by z_knockdown, in-plane stress is not). The
        // infill knockdown (f^1.5) that stood here before describes a sparse-infill
        // solid, which a strut is not.
        material.z_knockdown, v.applied_build_dir, cell, census_ok);
    // ── ★ RULING D: A REFUSAL THAT NAMES THE FIX, NOT A BARE MARGIN ────────────
    // When a structural certificate fails and the grade was already pressed against
    // the top of its density band -- and that top is the AESTHETIC CEILING rather than
    // the certifiable one -- the lattice did not fail because it cannot be built strong
    // enough. It failed because it was not allowed to get denser. That is a setting,
    // and the user owns it, so the refusal says which setting and what it is called in
    // the app instead of reporting a number the user cannot act on.
    //
    // The three conditions are all MEASURED, never assumed: the verdict, the count of
    // voxels sitting exactly on the ceiling (a grade that never reached its top was not
    // capped by it), and the top itself against core's own octet law.
    if (R.organic_cert.verdict != OrganicCertificate::Verdict::Certified &&
        R.gf.density_at_ceiling_voxels > 0) {
      const double ceiling = octet_aesthetic_density_ceiling();
      const double top = R.gf.rho_max_used > 0.0 ? R.gf.rho_max_used : R.gf.band_rho_max;
      // within 10 %: the app's own ceiling constant is 0.219 against core's 0.211733,
      // and a tolerance narrower than that gap would silently never fire.
      if (top > 0.0 && top <= 1.10 * ceiling) {
        char note[640];
        std::snprintf(
            note, sizeof note,
            " THE DENSITY BAND, NOT THE GEOMETRY, IS WHAT STOPPED THIS: %zu latticed "
            "voxel(s) are sitting exactly on the band's top of %.4f, which is the "
            "AESTHETIC CEILING (%.4f by core's octet law -- the density at which a "
            "strut is a fifth of its cell across, the point a quilt stops looking "
            "open). The lattice was not permitted to get any denser, so the certificate "
            "never saw the material this load needs. In the app this cap is the \"Allow "
            "quilt\" switch: turn it ON to lift the ceiling and re-run. If it is "
            "already on, raise \"max relative density\" -- the certifiable band goes to "
            "%.4f.",
            R.gf.density_at_ceiling_voxels, top, ceiling, R.gf.band_rho_max);
        if (R.organic_cert.refusal.empty())
          R.organic_cert.refusal =
              "the structural certificate did not pass." + std::string(note);
        else
          R.organic_cert.refusal += std::string(note);
        std::fprintf(stderr, "[cert] refused at the aesthetic ceiling: band top %.4f, "
                             "%zu voxel(s) on it -- the fix is \"Allow quilt\"\n",
                     top, R.gf.density_at_ceiling_voxels);
      }
    }
    std::printf(
        "organic structural certification: %s  margin %.4g  p99 %.4g MPa  max %.4g "
        "MPa  (%zu case(s), %zu members, %.1f s)  knockdown %.3f (%s, cos^2 %.2f)  "
        "max/allowable %.3f point, %.3f distributed (max %.4g MPa distributed)%s  "
        "rss %.0f -> %.0f MB, peak %.0f MB\n",
        R.organic_cert.verdict == OrganicCertificate::Verdict::Certified ? "CERTIFIED"
        : R.organic_cert.verdict == OrganicCertificate::Verdict::Refused ? "REFUSED"
                                                                        : "not run",
        R.organic_cert.margin, R.organic_cert.stress_p99_mpa,
        R.organic_cert.stress_max_mpa, R.organic_cert.load_cases_run,
        R.organic_cert.members, R.organic_cert.seconds, R.organic_cert.knockdown_used,
        R.organic_cert.knockdown_source.c_str(), R.organic_cert.governing_cos2,
        R.organic_cert.max_over_allowable, R.organic_cert.max_over_allowable_distributed,
        R.organic_cert.stress_max_distributed_mpa,
        R.organic_cert.max_exceeds_allowable ? "  MAX EXCEEDS ALLOWABLE" : "",
        R.organic_cert.rss_before_mb, R.organic_cert.rss_after_mb, R.organic_cert.peak_rss_mb);
    if (!R.organic_cert.refusal.empty())
      std::printf("  %s\n", R.organic_cert.refusal.c_str());
  }

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
      const FixedDesignAnalysis cf =
          certify_posture(v, solved_grid, options, material, bcs, cx, &cpost).governing;
      grad_rcpt.clamp_counterfactual_ran = true;
      grad_rcpt.counterfactual_accepted = cf.accepted;
      grad_rcpt.clamp_changed_verdict = (cf.accepted != R.cc.lattice.accepted);
    }
  }

  if (!e3_owner.empty()) {   // ★ E3: for the receipt's lattice_regions
    R.region_jobs = e3_jobs;
    R.region_owner = e3_owner;
  }
  const long long shipped_counts[2] = {R.shipped_lowered, R.shipped_at_floor};
  R.receipt_path =
      join_path(out_dir, lattice_base_name(job.output.mesh_prefix,
                                           v.requested_volume_fraction) +
                             ".report.json");
  R.receipt_json = lattice_cert_report_json(
      v, job.lattice, R.cc, R.oc, cell, role_rcpt, grad_rcpt, added_rcpt,
      frozen_rcpt, R.void_check_ran ? &R.void_report : nullptr, &R.volume_check,
      &R.volume_check_law, shipped_counts, &R.grade_source, &R.region_jobs, &R.region_owner,
      &R.region_graded);
  write_text_file(R.receipt_path, R.receipt_json);
  // `grad_rcpt.gf` points at R.gf, which the caller now owns; the receipt is
  // already rendered, so nothing may follow that pointer after the return. Null
  // it rather than leave a dangling-looking field on a returned value.
  grad_rcpt.gf = nullptr;
  return R;
}

// ── ★ E3 "OFF" WITH NO DENSITY: THE SEARCH CERTIFIES WHAT SHIPS (ruling 11-06) ──────
// The pass's own search certifies trial densities on the LAW posture, which is cheap (no
// geometry), and the law reads at or above what the file holds. The run's certificate is
// min(law, measured) on the emitted file, so the law's answer can still be refused
// (measured: 1.551 on the law, 1.159 shipped, on a whole-part bar). When it is, the
// search goes on over whole passes: each searched region's density moves from its law
// answer toward its graded peak by one shared fraction t, bisected on the shipped
// verdict (t = 1, every region at its peak, first: if even that refuses, the region is
// named). The last pass run is the one chosen, so its files are the ones on disk.
LatticeVariantOutcome lattice_one_variant(
    const MinimizePlasticVariant& v, const JobDescription& job,
    const VoxelGrid& part_grid, const SolvedDesignDomain& domain,
    const MinimizePlasticOptions& options, const Material& material,
    const std::vector<ClearanceGeometry>& lattice_kos,
    const LatticeRoleRegions& lattice_roles, const std::string& out_dir,
    const TriangleMesh* part_surface = nullptr, const StepModel* cad = nullptr) {
  LatticeVariantOutcome R = lattice_one_variant_pass(
      v, job, part_grid, domain, options, material, lattice_kos, lattice_roles, out_dir, nullptr,
      part_surface, cad);
  bool any = false;
  for (const LatticeRegionGraded& g : R.region_graded)
    if (g.searched && g.search_certified && g.search_rho < g.search_peak) any = true;
  if (!any || !R.cc.ran || R.cc.lattice.accepted) return R;
  const std::vector<LatticeRegionGraded> base = R.region_graded;
  int passes = 0;
  auto at = [&](double t) {
    std::vector<LatticeRegionGraded> f = base;
    for (LatticeRegionGraded& g : f)
      if (g.searched && g.search_certified) {
        g.search_law_rho = g.search_rho;
        g.search_rho = g.search_rho + t * (g.search_peak - g.search_rho);
        g.search_shipped_trials = passes + 1;
      }
    return f;
  };
  auto pass = [&](double t) {
    const std::vector<LatticeRegionGraded> f = at(t);
    ++passes;
    return lattice_one_variant_pass(v, job, part_grid, domain, options, material, lattice_kos,
                                    lattice_roles, out_dir, &f, part_surface, cad);
  };
  LatticeVariantOutcome top = pass(1.0);
  if (!top.cc.ran || !top.cc.lattice.accepted) {
    for (std::size_t i = 0; i < base.size() && i < top.region_jobs.size(); ++i)
      if (base[i].searched && base[i].search_certified) {
        const std::string& lb = top.region_jobs[i].label;
        char tail[220];
        std::snprintf(tail, sizeof tail,
                      " (grading off, one density): on what the file holds, the lattice does "
                      "not certify even with it at its graded peak %.4g (margin %.3g). Give it "
                      "a density, or let it grade.",
                      base[i].search_peak, top.cc.lattice.margin_effective);
        top.one_density_refusal += std::string(top.one_density_refusal.empty() ? "" : " ") +
                                   "Region " +
                                   (lb.empty() ? std::to_string(i + 1) : "\"" + lb + "\"") + tail;
      }
    return top;
  }
  double lo = 0.0, hi = 1.0, last = 1.0;
  for (int it = 0; it < 4; ++it) {
    const double mid = 0.5 * (lo + hi);
    LatticeVariantOutcome m = pass(mid);
    last = mid;
    if (m.cc.ran && m.cc.lattice.accepted) {
      hi = mid;
      top = std::move(m);
    } else {
      lo = mid;
    }
  }
  if (last != hi) top = pass(hi);  // the chosen pass's files are the ones left on disk
  std::fprintf(stderr, "[one-density] shipped search: t = %.4f after %d whole pass(es)\n", hi,
               passes);
  return top;
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

TriangleMesh fuse_keep_regions(const TriangleMesh& exported, const TriangleMesh& part,
                               const std::vector<KeepRegion>& keeps, double min_piece_mm3) {
  return keep_regions_exact(exported, part, keeps, min_piece_mm3);
}

TriangleMesh cut_keep_clears(const TriangleMesh& file, const JobDescription& job,
                             const StepModel& model, double min_piece_mm3, double* cut_mm3,
                             double thin_mm) {
  const std::vector<ClearanceGeometry> clears = lattice_keep_outs_from_job(job, model);
  return keep_clear_exact(file, make_keep_clear_cut(model.mesh, clears, job.keep_regions),
                          model.mesh, clears, job.keep_regions, min_piece_mm3, cut_mm3, thin_mm);
}

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
// ★ THE ONE PLACE THE BINARY'S IDENTITY LIVES. See job.hpp's note. A function-local
// static, so there is exactly one and its initialisation is thread-safe; the setter is
// called by main() before any work starts.
static RunObservability& mutable_build_identity() {
  static RunObservability id;
  return id;
}

void set_build_identity(const std::string& fingerprint,
                        const std::string& build_time) {
  RunObservability& id = mutable_build_identity();
  static bool stated = false;
  // ★ SET ONCE (reviewer, 2026-10-02). Stating the SAME identity twice is harmless
  // -- a second entry point in one process legitimately does it -- so that is a no-op.
  // Stating a DIFFERENT one means two binaries' identities are in flight in one
  // process, and every receipt written after the second call would carry the wrong
  // one. That is unrecoverable from the receipt afterwards, so it REFUSES here,
  // naming both. Not an assert: this must hold in Release, which is what ships.
  // ★ AN EXPLICIT FLAG, NOT A SENTINEL SNIFF. The first version asked whether the
  // identity "looked set" (fingerprint != "unknown" or a non-empty build_time), which
  // cannot tell "nobody has stated it" from "someone deliberately stated unknown" --
  // and in a process where nobody had stated anything it let a different value through
  // silently. The test caught that. One bool, one meaning.
  if (stated && (id.fingerprint != fingerprint || id.build_time != build_time))
    throw std::invalid_argument(
        "set_build_identity: the build identity is already \"" + id.fingerprint +
        "\" / \"" + id.build_time + "\" and something is now setting it to \"" +
        fingerprint + "\" / \"" + build_time +
        "\". One process is one binary: a receipt written after this would name the "
        "wrong core, and nothing downstream could tell. Set it once, before any work.");
  id.fingerprint = fingerprint;
  id.build_time = build_time;
  stated = true;
}

const RunObservability& build_identity() { return mutable_build_identity(); }

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
               j_minimize_plastic, j_redesign, j_anchor_model, j_scenarios,
               j_safety_margin, j_wall_loops,
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
  auto to_group = [&](const JobLoadGroup& g) {
    ProductionLoadCase::LoadGroup lg;
    lg.face_ids = g.face_ids;
    for (const int id : resolve_selectors(model, g.faces, "loads group faces"))
      lg.face_ids.push_back(id);
    lg.region_ids = g.region_ids;
    lg.force = g.force;
    return lg;
  };
  for (const JobLoadGroup& g : j_groups) lc.load_groups.push_back(to_group(g));
  // LOAD SCENARIOS: each scenario's groups and ON anchors; the load case's anchors
  // become their UNION, faces and regions (scenario 1's groups stay the mirror in
  // load_groups). A job that names any scenario's region anchors names them all.
  bool regions_named = false;
  for (const JobScenario& js : j_scenarios) regions_named = regions_named || js.has_anchor_region_ids;
  for (const JobScenario& js : j_scenarios) {
    ProductionLoadCase::Scenario sc;
    sc.name = js.name;
    for (const JobLoadGroup& g : js.groups) sc.groups.push_back(to_group(g));
    sc.anchor_face_ids = js.anchor_face_ids;
    for (const int f : js.anchor_face_ids)
      if (std::find(lc.anchor_face_ids.begin(), lc.anchor_face_ids.end(), f) ==
          lc.anchor_face_ids.end())
        lc.anchor_face_ids.push_back(f);
    sc.anchor_region_ids = js.anchor_region_ids;
    sc.region_anchors_named = regions_named;
    for (const int r : js.anchor_region_ids)
      if (std::find(lc.anchor_region_ids.begin(), lc.anchor_region_ids.end(), r) ==
          lc.anchor_region_ids.end())
        lc.anchor_region_ids.push_back(r);
    lc.scenarios.push_back(std::move(sc));
  }
  // Clearances (handoff 100): map each job clearance to a ProductionLoadCase
  // clearance. A distance the job omitted (== 0) defaults to the same spec
  // suggestion the app prefills — for a bolt those depend on the bore radius,
  // read from the imported face geometry, so a hand-authored job need only give
  // face_id + kind.
  // ★ E4 (j): a Keep clear on a cut piece reads its region -- resolved once, here, from
  // the same specs the load case carries, so the pre-flight's copy of `lc` has them too.
  std::vector<ResolvedFaceRegion> clear_regions;
  for (const JobClearance& jc : j_clearances)
    if (jc.region_id >= 0) {
      clear_regions = resolve_face_regions(model, j_face_regions);
      break;
    }
  for (const JobClearance& jc : j_clearances) {
    ProductionLoadCase::Clearance c;
    c.face_id = jc.face_id;
    c.manual = jc.manual;
    const bool bolt = jc.kind == "bolt";
    const ResolvedFaceRegion* piece = nullptr;
    for (const ResolvedFaceRegion& r : clear_regions)
      if (jc.region_id >= 0 && r.id == jc.region_id) piece = &r;
    // Default suggestions depend on the bore radius: an auto bolt reads it from
    // the imported face geometry; a manual bolt carries its own radius_mm. A
    // hand-authored job need only give face_id/geometry + kind and the same
    // spec-suggestion defaults fill the rest. A cut piece reads its largest bore.
    double bore_r = 0.0;
    if (bolt) {
      if (jc.manual)
        bore_r = jc.radius_mm;
      else if (piece != nullptr)
        bore_r = largest_bore_radius_mm(model, piece->member_faces);
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
    if (piece != nullptr) {
      c.region_id = jc.region_id;
      try {
        resolve_clearance_region(c, *piece, model);
      } catch (const std::invalid_argument& e) {
        throw JobError(e.what());
      }
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
  lc.strengthen = j_redesign == "strengthen";  // item 50
  lc.anchor_bearing = j_anchor_model == "bearing";  // REAL BOLTS
  lc.safety_margin = j_safety_margin;  // the user's safety margin (0 = default)
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
  lc.keep_regions = job.keep_regions;  // item KEEP
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
      // ★ E4 (j): a cut piece's row names its region (face_id -1), as a region
      // protection's row does; a face's row is unchanged.
      s += "    {\"face_id\": " + std::to_string(c.face_id) +
           (c.region_id >= 0 ? ", \"region_id\": " + std::to_string(c.region_id)
                             : std::string()) +
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
  gp.topology = lattice_topology_from_id(job.grading.topology);  // the job's type
  gp.target_cell_size_mm = job.grading.present ? job.grading.cell_mm
                                               : job.lattice.cell_mm;
  gp.min_extrudable_width_mm = job.grading.present
                                   ? job.grading.min_extrudable_width_mm
                                   : job.lattice.min_extrudable_width_mm;
  gp.demand_exponent = job.grading.present ? job.grading.demand_exponent : 1.0;
  gp.organic_geometry =
      job.grading.present &&
      resolve_lattice_algorithm(job.grading) == LatticeAlgorithm::Organic;
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
    {
      const std::string note = lattice_type_directional_note(job.lattice.topology);
      if (!note.empty()) s += "  \"directional_note\": \"" + note + "\",\n";
    }
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
    const double phi_unit = lattice_strut_diameter_mm(gp.topology, lattice_rho_min(gp.topology), 1.0);
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
  {
    const std::string note = lattice_type_directional_note(job.lattice.topology);
    if (!note.empty()) s += "  \"directional_note\": \"" + note + "\",\n";
  }
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

// E1 (f): the area of the faces that would need support printed along `b` (facing
// down more than 45 degrees from it, and not on the bed: within 0.5 mm of the lowest
// point), and the support volume under them (area x height above the bed, projected).
struct Overhang {
  double area_mm2 = 0.0;
  double support_volume_mm3 = 0.0;
};
Overhang overhang_of(const TriangleMesh& m, const Vec3& b) {
  Overhang o;
  if (m.empty()) return o;
  double lowest = std::numeric_limits<double>::infinity();
  for (const Vec3& v : m.vertices) lowest = std::min(lowest, v.x * b.x + v.y * b.y + v.z * b.z);
  for (const auto& t : m.triangles) {
    const Vec3& p0 = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& p1 = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& p2 = m.vertices[static_cast<std::size_t>(t[2])];
    const Vec3 u{p1.x - p0.x, p1.y - p0.y, p1.z - p0.z}, w{p2.x - p0.x, p2.y - p0.y, p2.z - p0.z};
    const Vec3 c{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double a2 = std::sqrt(c.x * c.x + c.y * c.y + c.z * c.z);
    if (!(a2 > 0.0)) continue;
    const double down = -(c.x * b.x + c.y * b.y + c.z * b.z) / a2;  // n . (-b)
    if (down <= std::cos(M_PI / 4.0)) continue;
    const double h = ((p0.x + p1.x + p2.x) * b.x + (p0.y + p1.y + p2.y) * b.y +
                      (p0.z + p1.z + p2.z) * b.z) / 3.0 - lowest;
    if (h < 0.5) continue;  // on the bed
    o.area_mm2 += 0.5 * a2;
    o.support_volume_mm3 += 0.5 * a2 * down * h;
  }
  return o;
}

#include "to_analyze.inc"  // TO rebuild stage 0: moved unchanged

// ---------------------------------------------------------------------------
// lattice_variant_job — LATTICE A FINISHED VARIANT (task
// 2026-08-02-lattice-a-variant). See job.hpp for the contract.
LatticeVariantJobResult lattice_variant_job(const JobDescription& job,
                                            const std::string& job_dir,
                                            const std::string& out_dir,
                                            const MaterialLibrary& materials,
                                            const SettingsRules& rules) {
  refuse_flexible_job(job, "lattice_variant_job");  // Flexible stage (flexible/job_block.hpp)
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
  // GRADING + A DESIGN BOX runs (reviewer's ruling 2026-11-03 23:05, option (b)): the
  // law plans its cells around the added material and every level and pass lays only
  // cells covering a voxel of the final mask (lattice_one_variant). The ORGANIC lattice
  // is the one graded algorithm still refused with a box: its traced network is laid
  // before the added-material policy keeps whole cells solid, and it has no cell to
  // keep solid.
  if (job.grading.present && job.has_design_box &&
      resolve_lattice_algorithm(job.grading) == LatticeAlgorithm::Organic)
    throw JobError(kOrganicDesignBoxRefusal);
  if (!job.grading.present) {
    const double lat_rho =
        lattice_density_from_strut(
            lattice_topology_from_id(job.grading.topology), job.lattice.cell_mm, job.lattice.strut_radius_mm);
    const double lo = lattice_rho_min(lattice_topology_from_id(job.grading.topology));
    const double hi = lattice_rho_max(lattice_topology_from_id(job.grading.topology));
    if (lat_rho < lo || lat_rho > hi)
      throw JobError(
          "lattice cell_mm " + std::to_string(job.lattice.cell_mm) +
          " / strut_radius_mm " + std::to_string(job.lattice.strut_radius_mm) +
          " implies " + job.lattice.topology + " relative density " + std::to_string(lat_rho) +
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
  // ★ LATTICING THE PART optimizes nothing, so a design box -- drawn, or the one a growth
  // run derives -- has nothing to grow into: the part is solved, latticed and certified
  // on its own grid, exactly as with no box. Expanded, every box voxel is solid on the
  // grid, so the "part" latticed was the BOX (LatticeTypes' finding 2026-11-04 20:24: a
  // 60 mm bar latticed as its 71 mm growth box, volume fraction 2.84).
  if (lattice_the_part) {
    options.design_box.reset();
    options.keep_out_boxes.clear();
  }

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
  auto certify_stored = [&](const std::vector<DirichletBC>& b,
                            const std::vector<NodalLoad>& l) {
    return analyze_fixed_design(
        cert_grid, params, sd.density, b, l, material, build_dir,
        options.simp.cg_tolerance, options.simp.cg_max_iterations,
        options.simp.solver, options.margin_stop, knockdown, load_path_ok,
        part_solid, /*lattice=*/nullptr, options.build_orientation_report,
        resolve_build_direction_is_inferred(options),
        /*auto_apply_build_orientation=*/false);
  };
  // ★ E2.1: A SCENARIO RUN RECORDED ITS GOVERNING SCENARIO'S MARGIN, so the stored
  // design is re-certified under every scenario, sized the way minimize_plastic sized
  // them, and the worst governs, exactly as the run did it. Before E2.1 it was
  // certified under scenario 1 alone, and every scenario job whose first scenario did
  // not govern was refused here as "not the one that produced this variant"
  // (measured on a two-scenario bar: recorded 4.95, reproduced 77.95). Each
  // scenario's own field goes to the lattice, which grades from the worst of the
  // ones it uses.
  std::vector<ScenarioReport> stored_scenarios;
  std::vector<ScenarioFields> stored_scenario_fields;
  std::string stored_unheld;
  if (domain.scenarios.empty()) {
    result.solid = certify_stored(domain.bcs, loads);
    ++result.analysis_solves;
  } else {
    ScenarioCertification sc = certify_scenarios(
        cert_grid,
        sized_scenarios(domain.scenarios, material.youngs_modulus_mpa, cert_grid.spacing),
        certify_stored, /*keep_fields=*/true);
    result.analysis_solves += static_cast<int>(sc.reports.size());
    result.solid = std::move(sc.governing);
    stored_unheld = std::move(sc.unheld);
    stored_scenarios = std::move(sc.reports);
    stored_scenario_fields = std::move(sc.fields);
  }
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
  v.scenario_fields = std::move(stored_scenario_fields);   // ★ E2.1 (empty without)
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
  vr.scenarios = stored_scenarios;   // ★ E2.1 (empty without scenarios)
  if (!result.solid.accepted)
    vr.rejection_reason = !load_path_ok           ? kLoadPathNotConnectedReason
                          : !stored_unheld.empty() ? scenario_unheld_reason(stored_unheld)
                                                   : kMarginBelowRequiredReason;
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
                          lattice_kos, lattice_roles, out_dir,
                          lattice_the_part ? &result.model.mesh : nullptr, &result.model);
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
  if (R.volume_refused)
    throw JobError("lattice_variant: " + R.volume_refused_reason);
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
    RunInfo gi = build_run_info(job, options, build_identity());
    if (R.graded) {
      gi.grading_present = true;
      gi.grading_topology = lattice_topology_name(R.gf.posture.topology);
      gi.grading_band_rho_min = R.gf.band_rho_min;
      gi.grading_band_rho_max = R.gf.band_rho_max;
      gi.grading_cells_per_member_floor = R.gf.cells_per_member_floor;
      gi.lattice_outline_beam_mm = R.outline_beam_mm;
      gi.lattice_outline_bleed_mm = R.outline_bleed_mm;
      gi.lattice_outline_inward_mm = R.outline_inward_mm;
      gi.lattice_outline_voxels = R.outline_beam_voxels;
      gi.stepped_anystep_rho_by_size = R.anystep_rho_by_size;
      gi.stepped_anystep_cells = R.anystep_cells;
      gi.stepped_anystep_regions = R.anystep_regions;
      gi.stepped_anystep_passes = R.anystep_passes;
      gi.stepped_anystep_histogram = R.anystep_histogram;
      gi.stepped_plan_solid_remainder_mm3 = R.plan_solid_remainder_mm3;
      gi.stepped_plan_latticed_mm3 = R.plan_latticed_mm3;
      gi.stepped_plan_rho_fallback_by_region = R.plan_rho_fallback_by_region;
      gi.stepped_clip_outside_region_mm3 = R.clip_outside_region_mm3;
      gi.stepped_clip_outside_by_cause_mm3 = R.clip_outside_by_cause_mm3;
      gi.stepped_plan_rho_queries_plan = R.plan_rho_queries_plan;
      gi.stepped_plan_rho_queries_posture = R.plan_rho_queries_posture;
      gi.stepped_plan_rho_queries_floor = R.plan_rho_queries_floor;
      gi.stepped_plan_by_region = R.plan_by_region;
      gi.stepped_plan_laid_unattributed = R.plan_laid_unattributed;
      gi.stepped_plan_laid_measured = R.plan_laid_measured;
      gi.stepped_law_ungradeable_reported = R.law_ungradeable_reported;
      gi.stepped_law_ungradeable_note = R.law_ungradeable_note;
      gi.stepped_seam_spans_before = R.seam_spans_before;
      gi.stepped_seam_spans_after = R.seam_spans_after;
      gi.stepped_seam_piece_mm = R.seam_piece_mm;
      gi.stepped_seam_longest_before_mm = R.seam_longest_before_mm;
      gi.stepped_seam_welded_nodes = R.seam_welded_nodes;
      gi.stepped_seam_t_junction_ends = R.seam_t_junction_ends;
      gi.stepped_seam_floating_ends = R.seam_floating_ends;
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
      // ★ AND NAME THE ALGORITHM, ON THE PATH THAT ACTUALLY WRITES GEOMETRY.
      // These fillers were wired into `analyze_job` only, so the ONE path that emits
      // an STL was the one whose receipt could not say what emitted it — which is
      // exactly what defeated the diagnosis of a 2.76 GB organic export. The file
      // existed and nothing in it said which law built it.
      gi.grading_algorithm = lattice_algorithm_name(R.algorithm);
      {
        const std::vector<double>& rho_used = R.gf.posture.relative_density;
        const std::vector<char>& msk_used = R.gf.posture.mask;
        const double vox = model_grid.spacing * model_grid.spacing *
                           model_grid.spacing;
        double sum = 0.0;
        long long cnt = 0;
        for (std::size_t e = 0; e < msk_used.size() && e < rho_used.size(); ++e)
          if (msk_used[e]) { sum += rho_used[e]; ++cnt; }
        gi.grading_lattice_solid_volume_mm3 = sum * vox;
        gi.grading_algorithm_latticed_voxels = cnt;
      }
      if (R.organic_ran) {
        OrganicOutcome tmp;
        tmp.lat.report = R.organic;
        tmp.trace_seconds = R.organic_trace_seconds;
        fill_organic_run_info(gi, tmp);
        // ★ ...and the growth counters are restored from the export outcome, which is
        // what carried them across. ONE call: `tmp` has no growth stats to contribute,
        // so there is nothing to overwrite field by field.
        copy_growth_stats(gi, R.oc.growth, R.oc.growth_ran);
        gi.organic_census_len_mm = R.oc.organic_census_len_mm;
        gi.organic_census_components = R.oc.organic_census_components;
        gi.organic_support_components_before = R.oc.organic_support_components_before;
        gi.organic_support_components_after = R.oc.organic_support_components_after;
        gi.organic_support_fragments_dropped = R.oc.organic_support_fragments_dropped;
        gi.organic_support_fragment_length_mm = R.oc.organic_support_fragment_length_mm;
        gi.organic_base_mat_stitches = R.oc.organic_base_mat_stitches;
        gi.organic_base_mat_clusters = R.oc.organic_base_mat_clusters;
        gi.organic_fill_mat_cells_outside_region = R.oc.organic_fill_mat_cells_outside_region;
        gi.organic_shape_fit_on = R.organic_shape_fit_on;
        gi.organic_shape_fit_candidates = R.organic_shape_fit_candidates;
        gi.organic_shape_fit_voxels_shrunk = R.organic_shape_fit_voxels_shrunk;
        gi.organic_shape_fit_min_ratio = R.organic_shape_fit_min_ratio;
        gi.organic_synthetic_regions = static_cast<long long>(R.organic_synthetic.regions);
        gi.organic_synthetic_voxels = static_cast<long long>(R.organic_synthetic.voxels_in_regions);
        gi.organic_synthetic_fully = static_cast<long long>(R.organic_synthetic.voxels_fully_synthetic);
        gi.organic_synthetic_blended = static_cast<long long>(R.organic_synthetic.voxels_blended);
        gi.organic_synthetic_dead_threshold = R.organic_synthetic.dead_threshold;
        gi.organic_synthetic_dead_floor_bound = R.organic_synthetic.dead_floor_bound;
        gi.organic_solid_rim_mm = R.organic_solid_rim_mm;
        gi.organic_solid_rim_voxels = R.organic_solid_rim_voxels;
        gi.organic_unsupported_spans = R.oc.organic_unsupported_spans;
        // ★ §3 PARITY: the SHIPPED span census, measured here over the very vector the
        // STL is carved from (organic_spans_out, the post-clip set) rather than taken
        // from any pass's own tally. A census computed from a counter can survive the
        // geometry it counted being deleted -- which is exactly what the node merge did
        // to a fifth of this part's material while every counter still read fine.
        {
          const std::vector<OrganicSpan>& sp = R.oc.organic_spans_out;
          gi.organic_span_count = static_cast<long long>(sp.size());
          double total = 0.0;
          std::vector<double> radii;
          radii.reserve(sp.size());
          for (const OrganicSpan& q : sp) {
            const double dx = q.b.x - q.a.x, dy = q.b.y - q.a.y, dz = q.b.z - q.a.z;
            total += std::sqrt(dx * dx + dy * dy + dz * dz);
            radii.push_back(q.r);
          }
          gi.organic_span_length_mm = total;
          if (!radii.empty()) {
            std::sort(radii.begin(), radii.end());
            gi.organic_span_radius_min_mm = radii.front();
            gi.organic_span_radius_p50_mm = radii[radii.size() / 2];
            gi.organic_span_radius_max_mm = radii.back();
          }
        }
        gi.organic_transfer_ties_on = job.grading.organic_transfer_ties;
        gi.organic_ties_seeded = static_cast<long long>(R.oc.growth.growth_ties_seeded);
        gi.organic_ties_landed = static_cast<long long>(R.oc.growth.growth_ties_landed);
        gi.organic_ties_refused_minor = static_cast<long long>(R.oc.growth.growth_ties_refused_minor);
        gi.organic_ties_refused_reach = static_cast<long long>(R.oc.growth.growth_ties_refused_reach);
        gi.organic_xfer_tie_length_mm = R.oc.growth.growth_tie_length_mm;
        gi.organic_tie_swirl = job.grading.organic_tie_swirl;
        gi.organic_support_raster_cells = R.oc.growth.support_raster_cells;
        gi.organic_support_raster_cap = R.oc.growth.support_raster_cap;
        gi.organic_recommend_ran = R.organic_recommend_ran;
        if (R.organic_recommend_ran) {
          gi.organic_recommend_mode = R.organic_recommendation.mode;
          gi.organic_recommend_band_lo_mm = R.organic_recommend_band.lo_mm;
          gi.organic_recommend_band_hi_mm = R.organic_recommend_band.hi_mm;
          gi.organic_recommend_collapsed = R.organic_recommend_band.collapsed;
          gi.organic_recommend_fit_found = R.organic_recommendation.fit_found;
          gi.organic_recommend_fit_mm = R.organic_recommendation.fit_mm;
          gi.organic_recommend_auto_found = R.organic_recommendation.auto_found;
          gi.organic_recommend_auto_lo_mm = R.organic_recommendation.auto_lo_mm;
          gi.organic_recommend_auto_hi_mm = R.organic_recommendation.auto_hi_mm;
        }
        gi.organic_synthetic_by_region.clear();
        for (const SyntheticStressRegionReport& rr : R.organic_synthetic.per_region) {
          OrganicSyntheticRegionInfo ri;
          ri.region_id = rr.region_id; ri.face_id = rr.face_id; ri.foci = rr.foci;
          ri.soft_mm = rr.soft_mm;
          ri.voxels = static_cast<long long>(rr.voxels);
          ri.fully = static_cast<long long>(rr.fully_synthetic);
          ri.blended = static_cast<long long>(rr.blended);
          ri.whole_region = rr.whole_region;
          ri.p99_von_mises = rr.p99_von_mises;
          gi.organic_synthetic_by_region.push_back(ri);
        }
        // ★ the organic structural certificate. `verdict` is never absent when one
        // was run, so "no key" and "not certified" cannot be confused.
        if (R.organic_cert.verdict != OrganicCertificate::Verdict::NotRun) {
          gi.organic_structural_verdict =
              R.organic_cert.verdict == OrganicCertificate::Verdict::Certified
                  ? "certified"
                  : "refused";
          gi.organic_structural_statistic = R.organic_cert.verdict_statistic;
          gi.organic_structural_margin = R.organic_cert.margin;
          gi.organic_structural_p50_mpa = R.organic_cert.stress_p50_mpa;
          gi.organic_structural_p95_mpa = R.organic_cert.stress_p95_mpa;
          gi.organic_structural_p99_mpa = R.organic_cert.stress_p99_mpa;
          gi.organic_structural_max_mpa = R.organic_cert.stress_max_mpa;
          gi.organic_structural_worst_strut = R.organic_cert.worst_strut;
          gi.organic_structural_governing_load_case =
              R.organic_cert.governing_load_case;
          gi.organic_structural_knockdown_used = R.organic_cert.knockdown_used;
          gi.organic_structural_knockdown_source = R.organic_cert.knockdown_source;
          gi.organic_structural_governing_cos2 = R.organic_cert.governing_cos2;
          gi.organic_structural_max_over_allowable = R.organic_cert.max_over_allowable;
          gi.organic_structural_max_over_allowable_distributed =
              R.organic_cert.max_over_allowable_distributed;
          gi.organic_structural_max_distributed_mpa = R.organic_cert.stress_max_distributed_mpa;
          gi.organic_structural_max_exceeds_allowable = R.organic_cert.max_exceeds_allowable;
          gi.organic_structural_load_cases =
              static_cast<long long>(R.organic_cert.load_cases_run);
          gi.organic_structural_seconds = R.organic_cert.seconds;
          gi.organic_structural_members = static_cast<long long>(R.organic_cert.members);
          gi.organic_structural_rss_before_mb = R.organic_cert.rss_before_mb;
          gi.organic_structural_rss_after_mb = R.organic_cert.rss_after_mb;
          gi.organic_structural_peak_rss_mb = R.organic_cert.peak_rss_mb;
          gi.organic_structural_refusal = R.organic_cert.refusal;
          gi.organic_structural_members_carrying = R.organic_cert.members_carrying;
          gi.organic_structural_zero_stress_fraction =
              R.organic_cert.zero_stress_fraction;
        }
        gi.organic_census_grown_len_mm = R.oc.organic_census_grown_len_mm;
        gi.organic_emitted_components = R.oc.organic_emitted_components;
        gi.organic_emitted_largest_fraction = R.oc.organic_emitted_largest_fraction;
        gi.organic_emitted_stranded_length_mm = R.oc.organic_emitted_stranded_mm;
        gi.organic_floating_voxels_before = R.oc.organic_floating_before;
        gi.organic_floating_voxels_after = R.oc.organic_floating_after;
        gi.organic_repair_legs = R.oc.organic_repair_legs;
        gi.organic_repair_rounds = R.oc.organic_repair_rounds;
        gi.organic_free_ends = R.oc.organic_free_ends;
        gi.organic_free_end_length_mm = R.oc.organic_free_end_len;
        gi.organic_free_ends_before_tie = R.oc.organic_free_before;
        gi.organic_ties_added = R.oc.organic_ties;
        gi.organic_tie_length_mm = R.oc.organic_tie_len;
        gi.organic_free_ends_unresolved = R.oc.organic_free_unresolved;
        gi.organic_pruned_spans = R.oc.organic_pruned;
        gi.organic_pruned_length_mm = R.oc.organic_pruned_len;
        gi.organic_prune_rounds = R.oc.organic_prune_rounds;
        gi.organic_plate_contacts = R.oc.organic_plate_contacts;
        gi.organic_net_skin_landings = R.oc.organic_net_landings;
        gi.organic_net_skin_members = R.oc.organic_net_members;
        gi.organic_net_skin_length_mm = R.oc.organic_net_length;
        gi.organic_net_skin_landings_joined = R.oc.organic_net_joined;
        gi.organic_net_skin_fallback_members = R.oc.organic_net_fallback;
        gi.organic_net_skin_edge_landings = R.oc.organic_net_edge_landings;
        gi.organic_stranded_components_dropped = R.oc.organic_stranded_comps;
        gi.organic_stranded_spans_dropped = R.oc.organic_stranded_spans;
        gi.organic_stranded_length_dropped_mm = R.oc.organic_stranded_len;
        gi.organic_nodes_merged = R.oc.organic_nodes_merged;
        gi.organic_merge_clusters = R.oc.organic_merge_clusters;
        gi.organic_merge_degenerate_spans = R.oc.organic_merge_degenerate;
        gi.organic_net_skin_members_pruned = R.oc.organic_net_pruned;
        gi.organic_net_skin_degree_one = R.oc.organic_net_deg1;
        gi.organic_unsupported_islands_found = R.oc.organic_unsupported_found;
        gi.organic_unsupported_islands_remaining = R.oc.organic_unsupported_left;
        gi.organic_support_legs_added = R.oc.organic_support_legs;
        gi.organic_support_leg_length_mm = R.oc.organic_support_leg_len;
        gi.organic_support_rounds = R.oc.organic_support_rounds;
        gi.organic_support_rounds_converged = R.oc.organic_support_rounds_converged;
        gi.organic_fixed_point_rounds = R.oc.organic_fp_rounds;
        gi.organic_fixed_point_converged = R.oc.organic_fp_converged;
        gi.organic_mutations = R.oc.organic_mutations;
        gi.organic_support_legs_impossible = R.oc.organic_support_impossible;
        gi.organic_unsupported_cells_remaining = R.oc.organic_unsupported_cells;
        gi.organic_unsupported_volume_mm3 = R.oc.organic_unsupported_mm3;
        gi.organic_support_legs_diagonal = R.oc.organic_support_diagonal;
        gi.organic_support_spans_cut = R.oc.organic_support_cut;
        gi.organic_support_cleanup_pruned = R.oc.organic_support_cleanup;
        gi.organic_base_trim_z_mm = R.oc.organic_base_trim_z;
        gi.organic_base_trim_spans_cut = R.oc.organic_base_trim_cut;
        gi.organic_base_trim_spans_clipped = R.oc.organic_base_trim_clipped;
        gi.organic_base_trim_length_mm = R.oc.organic_base_trim_len;
        gi.organic_base_trim_found = R.oc.organic_base_trim_found;
        gi.organic_base_mat_struts = R.oc.organic_base_mat_struts;
        // ★ THE THIRD HOP. A stat travels gen-stats -> oc -> gi -> JSON, and a field
        // added to the first three still reports 0 if this line is missing: the copy
        // site was measured carrying touchdowns=684 while the receipt printed 0.
        gi.organic_base_mat_touchdowns = R.oc.organic_base_mat_touchdowns;
        gi.organic_slenderness_violating = R.oc.organic_slenderness_violating;
        gi.organic_slenderness_propped = R.oc.organic_slenderness_propped;
        gi.organic_slenderness_impossible = R.oc.organic_slenderness_impossible;
        gi.organic_slenderness_props = R.oc.organic_slenderness_props;
        gi.organic_cantilever_reach = R.oc.organic_cantilever_reach;
        gi.organic_cantilever_islands = R.oc.organic_cantilever_islands;
        gi.organic_arched_spans = R.oc.organic_arched_spans;
        gi.organic_arch_rise = R.oc.organic_arch_rise;
        gi.organic_base_mat_length_mm = R.oc.organic_base_mat_len;
        gi.organic_base_mat_z_mm = R.oc.organic_base_mat_z;
        gi.organic_fill_mat_cells = R.oc.organic_fill_cells;
        gi.organic_fill_mat_struts = R.oc.organic_fill_struts;
        gi.organic_fill_mat_length_mm = R.oc.organic_fill_len;
        gi.organic_branch_seeds = R.oc.organic_branch_seeds;
        gi.organic_branch_merges = R.oc.organic_branch_merges;
        gi.organic_branch_trunks = R.oc.organic_branch_trunks;
        gi.organic_branch_anchored_on_model = R.oc.organic_branch_anchored;
        gi.organic_branch_length_mm = R.oc.organic_branch_len;
        gi.organic_support_cut_length_mm = R.oc.organic_support_cut_len;
        gi.organic_unsupported_cells_found = R.oc.organic_unsupported_found_cells;
        gi.organic_support_layer_height_mm = R.oc.organic_support_layer_mm;
        gi.organic_support_grid_too_large = R.oc.organic_support_grid_too_large;
        // ── ★★ THE REFUSAL. Same posture as the sealed-cavity check: ON by default,
        // only an explicit false disarms it, and REMOVING the key does not.
        //
        // The support pass tries a vertical leg, then a diagonal one, then CUTS the
        // span. That set is closed, so a remainder means the geometry defeated all
        // three. The maintainer watched his printer extrude a strut into open air;
        // shipping a file we KNOW does that is worse than refusing to write it.
        if (job.lattice.require_no_midair_start) {
          if (R.oc.organic_support_grid_too_large)
            throw JobError(
                "organic: the mid-air-start check COULD NOT RUN — this part needs a "
                "raster beyond the 120M-cell budget at the stated layer height, so "
                "nothing was verified. A check that did not run is not a check that "
                "passed. State a coarser \"layer_height_mm\" in \"loads\", or set "
                "\"require_no_midair_start\": false to export unverified.");
          if (R.oc.organic_unsupported_cells > 0) {
            std::ostringstream m;
            m << "organic: " << R.oc.organic_unsupported_cells
              << " raster cells of material (" << R.oc.organic_unsupported_mm3
              << " mm^3, in " << R.oc.organic_unsupported_left
              << " region(s)) would be extruded INTO OPEN AIR — they sit in a print "
                 "layer with nothing beneath them, checked at a "
              << R.oc.organic_support_layer_mm
              << " mm layer height. The algorithm added " << R.oc.organic_support_legs
              << " support leg(s) (" << R.oc.organic_support_diagonal
              << " angled in where a vertical leg would breach the surface) and CUT "
              << R.oc.organic_support_cut
              << " span(s) it could not hold up; these defeated both. TO PROCEED, "
                 "either change the geometry — a denser band or a larger cell gives "
                 "each island more neighbours to land on — or set "
                 "\"require_no_midair_start\": false in the job's \"lattice\" block "
                 "to export anyway. THIS CHECK IS ON BY DEFAULT, so REMOVING the key "
                 "does not turn it off.";
            throw JobError(m.str());
          }
        }
      }
      if (R.stepped_ran) fill_stepped_run_info(gi, R.stepped);
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
      lvr.rejection_reason = !R.cc.open_refusal.empty() ? R.cc.open_refusal  // ★ E2.4
                             : !R.one_density_refusal.empty() ? R.one_density_refusal  // ★ E3
                             : result.lattice.lattice_not_certified
                                 ? result.lattice.lattice_not_certified_reason
                             : load_path_ok ? kMarginBelowRequiredReason
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

// ══ INSTALL 3: THE STRENGTH CHECK OF THE NEW ENGINE'S LATTICE FILE (rule V4) ══════
// lattice_file_strength.hpp. The OLD check, unchanged (certify_latticed_variant: the
// null-posture solve, the composite solve, the gate), fed from the new layout: the
// part is set up exactly as the old Lattice run sets it up ("lattice_part": the part
// is the design, every voxel it occupies solid), and the lattice's density per voxel
// is the new layout's own (lattice_layout::lattice_credit). The cells it gives no
// credit go in as the old open finish's cut cells: void in the composite solve.
//
// THE SETTINGS (strength_settings, docs/strength-check/variables.json): the numbers the
// developers chose, which a job may state. Each reaches the check through a defaulted
// parameter whose default IS the constant, so a job that states none is the check as it
// was, and no other caller of the old pipeline sees any of them.
const std::vector<StrengthSettingSpec>& strength_setting_specs() {
  using K = StrengthSettingSpec::Kind;
  static const std::vector<StrengthSettingSpec> specs = {
      // key, kind, default, min, max, min_open, choices
      {"z_knockdown", K::PerMaterial, 0.0, 0.0, 1.0, true, {}},
      {"safety_margin_floor", K::Number, 1.5, 1.0, 5.0, false, {}},
      {"infill_exponent", K::Number, 1.5, 1.0, 3.0, false, {}},
      {"infill_floor", K::Number, 1e-3, 1e-5, 0.1, false, {}},
      {"width_aware_knockdown", K::Bool, 1.0, 0.0, 1.0, false, {}},   // on by default (the owner, 2026-11-18; brief E4 item 5)
      {"thickness_cap_voxels", K::Integer, 32.0, 1.0, 256.0, false, {}},
      {"load_path_connectivity", K::Choice, 26.0, 6.0, 26.0, false, {6.0, 18.0, 26.0}},
      {"printed_threshold", K::Number, 0.5, 0.01, 0.99, false, {}},
      {"void_floor", K::Number, 1e-9, 1e-11, 1e-7, false, {}},
      {"cg_tolerance", K::Number, 1e-8, 1e-10, 1e-6, false, {}},
      {"cg_max_iterations", K::Integer, 0.0, 0.0, 1e8, false, {}},
      {"contact_rounds", K::Integer, 6.0, 1.0, 60.0, false, {}},
      {"sliding_share_max", K::Number, 0.05, 0.0, 0.5, false, {}},
      {"bearing_stiffness", K::Number, 200000.0, 2000.0, 2e7, false, {}},
      {"bearing_tangent_fraction", K::Number, 1e-4, 1e-6, 1e-2, false, {}},
      {"scenario_weak_spring", K::Number, 1e-6, 1e-8, 1e-4, false, {}},
      {"scenario_weak_spring_min_scale", K::Number, 0.03, 3e-4, 1.0, false, {}},
      {"scenario_unheld_share", K::Number, 0.05, 0.0, 0.5, false, {}},
      {"part_box_tol_mm", K::Number, 0.1, 0.001, 10.0, false, {}},
      {"part_box_tol_fraction", K::Number, 0.005, 5e-5, 0.5, false, {}},
      {"min_feature_warning_threshold", K::Integer, 1.0, 1.0, 1000.0, false, {}},
      // Brief E2, Part A: the Organic check, a frame of beams (lattice_layout_frame.hpp, FrameSettings).
      {"frame_node_weld_mm", K::Number, 1e-5, 1e-7, 0.01, false, {}},
      {"frame_tjoin_reach_mm", K::Number, 0.3, 0.01, 2.0, false, {}},
      {"frame_tjoin_off_line_mm", K::Number, 1e-4, 1e-7, 0.05, false, {}},
      {"frame_zero_piece_mm", K::Number, 1e-6, 1e-9, 0.01, false, {}},
      {"frame_link_stiffness", K::Number, 1e4, 1.0, 1e8, false, {}},
      {"frame_drive_ball_voxels", K::Number, 2.0, 0.5, 6.0, false, {}},
      {"frame_drive_share", K::Number, 0.5, 0.01, 0.99, false, {}},
      {"frame_drive_reach_voxels", K::Number, 4.0, 0.5, 20.0, false, {}},   // OS4 amended (the lead, 2026-11-19)
      {"frame_collinear_tol_mm", K::Number, 1e-6, 1e-9, 0.01, false, {}},
      {"frame_collinear_max_driven", K::Integer, 50.0, 2.0, 10000.0, false, {}},
      {"frame_floor_shift_voxels", K::Number, 0.0, 0.0, 10.0, false, {}},
      {"frame_floor_free", K::Bool, 0.0, 0.0, 1.0, false, {}},
      {"load_unheld_share", K::Number, 0.01, 0.0, 0.5, false, {}},
      {"frame_unjudged_share", K::Number, 0.01, 0.0, 0.5, false, {}},
      {"frame_min_piece", K::Number, 0.1, 0.0, 2.0, false, {}},
      {"frame_material_subdiv", K::Integer, 3.0, 1.0, 4.0, false, {}},
      {"frame_void_floor", K::Number, 1e-3, 1e-9, 0.1, false, {}},
      {"frame_solve_memory_gb", K::Number, 4.0, 0.1, 64.0, false, {}},
      {"frame_weakest", K::Integer, 20.0, 0.0, 1000.0, false, {}},
      // Brief E2, Part B: the strengthen rounds.
      {"strengthen_watch_margin", K::Number, 2.0, 1.0, 10.0, false, {}},
      {"strengthen_boost_max", K::Number, 4.0, 1.0, 100.0, false, {}},
      {"strengthen_boost_power", K::Number, 2.0, 0.1, 10.0, false, {}},
      {"strengthen_target_margin", K::Number, 1.75, 1.0, 10.0, false, {}},
      {"strengthen_rounds", K::Integer, 0.0, 0.0, 20.0, false, {}},
      {"strengthen_reach", K::Number, 1.0, 0.1, 10.0, false, {}},
      // Brief E3a: strengthening by adding (the owner, 2026-11-18: both loops stay, as a choice; additive the default).
      {"strengthen_mode", K::Choice, 0.0, 0.0, 1.0, false, {0.0, 1.0}},   // 0 "additive", 1 "rebuild" (strings read too)
      {"strengthen_width_cap", K::Number, 2.0, 1.0, 10.0, false, {}},
      {"strengthen_power_axial", K::Number, 2.0, 1.0, 6.0, false, {}},
      {"strengthen_power_bending", K::Number, 3.0, 1.0, 6.0, false, {}},
      {"strengthen_power_buckling", K::Number, 4.0, 1.0, 6.0, false, {}},
      // Brief E4: the solid's weak spots (Organic results).
      {"solid_spots_max", K::Integer, 20.0, 1.0, 1000.0, false, {}},
      {"solid_spot_near_voxels", K::Number, 3.0, 0.0, 20.0, false, {}},
  };
  return specs;
}

namespace {

namespace ll = lattice_layout;
namespace sjson = topopt::flexible::json;

ll::StrengthDone strength_no(const char* code, int exit_code, const std::string& why,
                             const std::string& detail = {}) {
  ll::StrengthDone d;
  d.ok = false;
  d.code = code;
  d.exit_code = exit_code;
  d.why = why;
  d.detail = detail;
  return d;
}

constexpr const char* kStrengthJobUnreadableWhy =
    "The strength check's job sent with the lattice job could not be read, so no file was made.";

// What `before` reads: the job, and the refusals that need no solve.
std::string strength_job_problem(const JobDescription& job, const MaterialLibrary& materials) {
  if (job.mode != "lattice_part")
    return "the strength job's mode must be \"lattice_part\", not \"" + job.mode + "\"";
  if (materials.find(job.material) == materials.end())
    return "material \"" + job.material + "\" is not in the material library";
  return {};
}

// The settings a job stated, over the defaults (strength_setting_specs).
struct StrengthSettingsAsked {
  std::map<std::string, double> value;                 // every Number / Integer / Bool / Choice key, default or stated
  std::map<std::string, double> z_knockdown;           // stated per material (the rest are the materials file's)
  std::set<std::string> stated;
  double get(const std::string& k) const { return value.at(k); }
  bool has(const std::string& k) const { return stated.count(k) != 0; }
};

// Reads `strength_settings` from the strength job's own text. Empty: fine. Otherwise ONE plain line.
std::string read_strength_settings(const std::string& job_path, const MaterialLibrary& materials,
                                   StrengthSettingsAsked& out) {
  using K = StrengthSettingSpec::Kind;
  for (const StrengthSettingSpec& sp : strength_setting_specs())
    if (sp.kind != K::PerMaterial) out.value[sp.key] = sp.def;
  std::ifstream f(job_path, std::ios::binary);
  if (!f) return "The strength check's job could not be opened, so no file was made.";
  std::ostringstream all;
  all << f.rdbuf();
  sjson::Value doc;
  try {
    doc = sjson::parse(all.str(), "strength job");
  } catch (const std::exception&) {
    return {};   // the job reader says what is wrong with the text
  }
  if (!doc.is_object()) return {};
  const sjson::Value* st = sjson::find(doc, "strength_settings");
  if (!st) return {};
  if (!st->is_object()) return "The strength settings sent with the lattice job are not a list of named values, so no file was made.";
  const auto range = [](const StrengthSettingSpec& sp) {
    return std::string(sp.min_open ? "above " : "from ") + json_num(sp.min) + (sp.min_open ? " up to " : " to ") +
           json_num(sp.max);
  };
  for (const auto& [key, v] : st->obj) {
    if (sjson::is_comment_key(key)) continue;
    const StrengthSettingSpec* sp = nullptr;
    for (const StrengthSettingSpec& s : strength_setting_specs())
      if (s.key == key) sp = &s;
    if (!sp)
      return "The strength setting \"" + key + "\" is not one the check knows, so no file was made.";
    if (sp->kind == K::PerMaterial) {
      if (!v.is_object())
        return "The strength setting \"" + key + "\" must name a value per material, so no file was made.";
      for (const auto& [mat, mv] : v.obj) {
        if (materials.find(mat) == materials.end())
          return "The strength setting \"" + key + "\" names \"" + mat +
                 "\", which is not in the material library, so no file was made.";
        if (!mv.is_number() || !std::isfinite(mv.num) || !(mv.num > sp->min) || mv.num > sp->max)
          return "The strength setting \"" + key + "\" for " + mat + " must be a number " + range(*sp) +
                 ", so no file was made.";
        out.z_knockdown[mat] = mv.num;
      }
      out.stated.insert(key);
      continue;
    }
    double x = 0.0;
    if (sp->kind == K::Bool) {
      if (!v.is_bool())
        return "The strength setting \"" + key + "\" must be true or false, so no file was made.";
      x = v.boolean ? 1.0 : 0.0;
    } else if (key == "strengthen_mode" && v.is_string()) {   // brief E3a: its two choices by name
      if (v.str != "additive" && v.str != "rebuild")
        return "The strength setting \"strengthen_mode\" is \"" + v.str + "\"; it must be \"additive\" or \"rebuild\", so no file was made.";
      x = v.str == "rebuild" ? 1.0 : 0.0;
    } else {
      if (!v.is_number() || !std::isfinite(v.num))
        return "The strength setting \"" + key + "\" must be a number, so no file was made.";
      x = v.num;
      if (sp->kind == K::Choice) {
        bool ok = false;
        for (double c : sp->choices) ok = ok || c == x;
        if (!ok) {
          std::string list;
          for (std::size_t i = 0; i < sp->choices.size(); ++i)
            list += (i ? (i + 1 == sp->choices.size() ? " or " : ", ") : "") + json_num(sp->choices[i]);
          return "The strength setting \"" + key + "\" is " + json_num(x) + "; it must be " + list +
                 ", so no file was made.";
        }
      } else {
        if (sp->kind == K::Integer && x != std::floor(x))
          return "The strength setting \"" + key + "\" must be a whole number, so no file was made.";
        if ((sp->min_open ? !(x > sp->min) : x < sp->min) || x > sp->max)
          return "The strength setting \"" + key + "\" is " + json_num(x) + "; it must be " + range(*sp) +
                 ", so no file was made.";
      }
    }
    out.value[key] = x;
    out.stated.insert(key);
  }
  return {};
}

// Brief E2, item 3: what both strength checks set up the same way (Install 3's, moved here unchanged): the strength
// job, its materials, rules and settings, the part (its box the file's), the load case on the job's own grid, and the
// domain it is solved on. Not ok: the refusal, as the check returns it.
struct StrengthSetup {
  JobDescription job;
  MaterialLibrary materials;
  SettingsRules rules;
  StrengthSettingsAsked st;
  Material material;   // with the layer factor as the settings state it (a copy: the library is not changed)
  std::string job_dir;
  StepModel model;
  VoxelGrid model_grid;
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;
  SolvedDesignDomain domain;
  PrintFrame frame;   // P2: the file job's print frame (off: as before); the job and its part were turned through it
  std::vector<Vec3> ups;   // P4: the print-orientation candidates' ups (the job's frame); empty: none judged
};

ll::StrengthDone strength_setup(const ll::StrengthAsk& ask, const std::string& materials_path,
                                const std::string& rules_path, StrengthSetup& S) {
  JobDescription& job = S.job;
  MaterialLibrary& materials = S.materials;
  SettingsRules& rules = S.rules;
  StrengthSettingsAsked& st = S.st;
  try {
    materials = load_materials_file(materials_path);
    rules = load_settings_rules_file(rules_path);
  } catch (const std::exception& e) {
    return strength_no("strength_job_unreadable", 1, kStrengthJobUnreadableWhy, e.what());
  }
  if (const std::string bad = read_strength_settings(ask.job_path, materials, st); !bad.empty())
    return strength_no("strength_settings_refused", 1, bad);
  try {
    job = load_job_file(ask.job_path, st.get("safety_margin_floor"));
  } catch (const std::exception& e) {
    return strength_no("strength_job_unreadable", 1, kStrengthJobUnreadableWhy, e.what());
  }
  if (const std::string p = strength_job_problem(job, materials); !p.empty())
    return strength_no("strength_job_unreadable", 1, kStrengthJobUnreadableWhy, p);
  // P2: the strength job through the file job's door (its loads, boxes and service; its build direction the print up).
  S.frame = ask.frame;
  S.ups = ask.orientation_ups;   // P4
  if (S.frame.on && !(g_print_frame_test_skip & kSkipStrengthJob)) turn_job_description(S.frame, job);
  // The material, with its layer factor as the settings state it (a copy: the library is not changed).
  S.material = materials.at(job.material);
  Material& material = S.material;
  if (const auto it = st.z_knockdown.find(job.material); it != st.z_knockdown.end())
    material.z_knockdown = it->second;
  if (st.has("min_feature_warning_threshold"))
    rules.min_feature_warning.threshold = static_cast<int>(st.get("min_feature_warning_threshold"));
  S.job_dir = [&] {
    const std::string d = std::filesystem::path(ask.job_path).parent_path().string();
    return d.empty() ? std::string(".") : d;
  }();
  const std::string& job_dir = S.job_dir;

  // ── the part, opened as the old Lattice run opens it.
  StepModel& model = S.model;
  try {
    model = import_part_file_resolved(join_path(job_dir, job.model));
  } catch (const std::exception& e) {
    return strength_no("strength_failed", 1,
                       "The part could not be opened for the strength check, so no file was made.",
                       e.what());
  }
  if (!check_watertight(model.mesh).watertight)
    return strength_no("strength_failed", 1,
                       "The part's surface has gaps in it, so its strength could not be checked. No file was made.",
                       "the strength job's model tessellation is not watertight: " + job.model);
  // P2: its part turned as the file job's was (the same turn and the same base).
  if (S.frame.on && !(g_print_frame_test_skip & kSkipStrengthModel)) turn_step_model(S.frame, model);
  // The strength job must be of the part the file was made from: the two boxes agree.
  {
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : model.mesh.vertices) {
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
    const double dx = ask.part_hi.x - ask.part_lo.x, dy = ask.part_hi.y - ask.part_lo.y,
                 dz = ask.part_hi.z - ask.part_lo.z;
    const double tol = std::max(st.get("part_box_tol_mm"),
                                st.get("part_box_tol_fraction") * std::sqrt(dx * dx + dy * dy + dz * dz));
    const double worst = std::max({std::fabs(lo.x - ask.part_lo.x), std::fabs(lo.y - ask.part_lo.y),
                                   std::fabs(lo.z - ask.part_lo.z), std::fabs(hi.x - ask.part_hi.x),
                                   std::fabs(hi.y - ask.part_hi.y), std::fabs(hi.z - ask.part_hi.z)});
    if (!(worst <= tol))
      return strength_no("strength_job_unreadable", 1, kStrengthJobUnreadableWhy,
                         "the strength job's part is not the lattice file's part (their boxes differ by " +
                             json_num(worst) + " mm)");
  }

  // ── the load case: the SAME mapping the old Lattice run makes (lattice_variant_job).
  const bool model_is_mesh = part_format_for_path(job.model) != PartFormat::Step;
  VoxelGrid& model_grid = S.model_grid;
  std::vector<DirichletBC>& bcs = S.bcs;
  MinimizePlasticOptions& options = S.options;
  if (job.loads.present) {
    ProductionLoadCase lc = production_loadcase_from_job(job, model);
    lc.bearing_stiffness_mpa_per_mm = st.get("bearing_stiffness");
    lc.bearing_tangent_fraction = st.get("bearing_tangent_fraction");
    ProductionRunSetup setup = build_production_loadcase(model, job.resolution, lc);
    if (setup.options.require_external_loads && setup.options.external_loads.empty())
      return strength_no("strength_failed", 1,
                         "The strength job's load reaches no part of the part, so its strength could not be "
                         "checked. No file was made.",
                         no_external_load_message(setup, job.resolution));
    model_grid = setup.grid;
    bcs = setup.bcs;
    options = setup.options;
  } else {
    model_grid = voxelize(model.mesh, job.resolution);
    const std::vector<int> fixture = resolve_selectors(model, job.fixture_faces, "fixture_faces");
    std::size_t tagged = 0;
    for (const int f : fixture)
      tagged += model_is_mesh ? tag_mesh_face(model_grid, model, f, VoxelTag::Fixture)
                              : tag_step_face(model_grid, model, f, VoxelTag::Fixture);
    if (tagged == 0)
      return strength_no("strength_failed", 1,
                         "The strength job's supports hold no part of the part, so its strength could not be "
                         "checked. No file was made.",
                         "fixture faces tagged no voxels");
    for (const int n : fea_tagged_nodes(model_grid, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    configure_production_options(options);
    options.margin_stop = job.margin_stop;
    options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
    options.gravity_direction = job.gravity.direction;
  }
  apply_build_direction_options(options, job);
  // As the old Lattice run: the part is solved on its own grid, never a design box's.
  options.design_box.reset();
  options.keep_out_boxes.clear();
  // The settings that live on the options (each only when stated: the default is what the options hold).
  if (st.has("cg_tolerance")) options.simp.cg_tolerance = st.get("cg_tolerance");
  if (st.has("cg_max_iterations")) options.simp.cg_max_iterations = static_cast<int>(st.get("cg_max_iterations"));
  // Brief E4, item 5 (the owner, 2026-11-18): the walls are credited unless the job turns the setting off; one setting
  // for the Organic verdict and Install 3's cube verdict alike.
  options.width_aware_knockdown = st.get("width_aware_knockdown") != 0.0;
  S.domain = resolve_design_domain(model_grid, bcs, options);
  ll::StrengthDone ok;
  ok.ok = true;
  return ok;
}

ll::StrengthDone run_lattice_file_strength(const ll::StrengthAsk& ask,
                                           const std::string& materials_path,
                                           const std::string& rules_path) {
  const auto t_start = std::chrono::steady_clock::now();
  if (!ask.session || !ask.outcome || !ask.made || !ask.session->domain())
    return strength_no("strength_failed", 1,
                       "The lattice's strength could not be checked, so no file was made.",
                       "the strength check was asked with no laid lattice");
  StrengthSetup S;
  if (ll::StrengthDone bad = strength_setup(ask, materials_path, rules_path, S); !bad.ok) return bad;
  JobDescription& job = S.job;
  MaterialLibrary& materials = S.materials;
  SettingsRules& rules = S.rules;
  StrengthSettingsAsked& st = S.st;
  Material& material = S.material;
  VoxelGrid& model_grid = S.model_grid;
  MinimizePlasticOptions& options = S.options;
  const SolvedDesignDomain& domain = S.domain;
  const VoxelGrid& cert_grid = domain.grid;

  // ── the design: the part itself, every voxel it occupies solid (lattice_part).
  std::vector<double> density(cert_grid.voxel_count(), 0.0);
  std::vector<char> in_part(cert_grid.voxel_count(), 0);
  std::size_t solid_count = 0;
  for (int k = 0; k < cert_grid.nz; ++k)
    for (int j = 0; j < cert_grid.ny; ++j)
      for (int i = 0; i < cert_grid.nx; ++i)
        if (cert_grid.solid(i, j, k)) {
          density[cert_grid.index(i, j, k)] = 1.0;
          in_part[cert_grid.index(i, j, k)] = 1;
          ++solid_count;
        }
  if (solid_count == 0)
    return strength_no("strength_failed", 1,
                       "The part fills no voxel of the strength job's grid, so its strength could not be checked. "
                       "No file was made.",
                       "the part occupies no voxels at this resolution");

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  // An empty voxel keeps density_min^penalty of the solid's stiffness: 1e-9 at the default floor 1e-3.
  if (st.has("void_floor")) params.density_min = std::cbrt(st.get("void_floor"));
  const double printed_iso = st.get("printed_threshold");
  const int connectivity = static_cast<int>(st.get("load_path_connectivity"));
  AnalysisKnobs knobs;
  knobs.contact_rounds = static_cast<int>(st.get("contact_rounds"));
  knobs.sliding_share_max = st.get("sliding_share_max");
  knobs.thickness_cap_voxels = static_cast<int>(st.get("thickness_cap_voxels"));
  // The direction the composite solve is certified in (lattice_cert_context's); the solid solve uses the same, so
  // the null-posture solve inside certify_latticed_variant reproduces it.
  const Vec3 build_dir = resolve_build_direction(options);
  const std::vector<NodalLoad> loads = design_domain_loads(domain, options, material.density_g_cm3);
  const bool load_path_ok = load_path_connected(cert_grid, density, printed_iso, connectivity);
  KnockdownSpec knockdown = knockdown_spec_for(options);
  knockdown.infill_exponent = st.get("infill_exponent");
  knockdown.infill_floor = st.get("infill_floor");
  knockdown.infill_knockdown =
      infill_margin_knockdown(options.infill_percent, knockdown.infill_exponent, knockdown.infill_floor);
  const double part_solid = static_cast<double>(model_grid.solid_count());
  auto certify_solid = [&](const std::vector<DirichletBC>& b, const std::vector<NodalLoad>& l) {
    return analyze_fixed_design(cert_grid, params, density, b, l, material, build_dir,
                                options.simp.cg_tolerance, options.simp.cg_max_iterations,
                                options.simp.solver, options.margin_stop, knockdown, load_path_ok,
                                part_solid, /*lattice=*/nullptr, options.build_orientation_report,
                                resolve_build_direction_is_inferred(options),
                                /*auto_apply_build_orientation=*/false, printed_iso,
                                /*gate_on_strut_strength=*/false, &knobs);
  };
  const std::vector<SimpScenario> sized =
      domain.scenarios.empty()
          ? std::vector<SimpScenario>{}
          : sized_scenarios(domain.scenarios, material.youngs_modulus_mpa, cert_grid.spacing,
                            st.get("scenario_weak_spring"), st.get("scenario_weak_spring_min_scale"));
  FixedDesignAnalysis solid;
  std::vector<ScenarioReport> solid_scenarios;
  std::string solid_unheld;
  if (domain.scenarios.empty()) {
    solid = certify_solid(domain.bcs, loads);
  } else {
    ScenarioCertification sc = certify_scenarios(cert_grid, sized, certify_solid, /*keep_fields=*/false,
                                                 st.get("scenario_unheld_share"));
    solid = std::move(sc.governing);
    solid_unheld = std::move(sc.unheld);
    solid_scenarios = std::move(sc.reports);
  }
  if (solid.non_convergent)
    return strength_no("strength_failed", 1,
                       "The strength check's solve did not settle, so the lattice's strength is not known. No file "
                       "was made.",
                       "the solid certification solve did not converge (iteration " +
                           std::to_string(solid.non_convergent_iteration) + ")");

  // The variant the old pipeline consumes, as lattice_variant_job builds it for the part.
  MinimizePlasticVariant v;
  v.requested_volume_fraction = static_cast<double>(solid_count) / static_cast<double>(cert_grid.voxel_count());
  v.optimization.physical_density = density;
  v.optimization.volume_fraction = v.requested_volume_fraction;
  v.v3 = solid.v3;
  v.accepted = solid.accepted;
  v.von_mises_field = solid.von_mises_field;
  v.stress_tensor_field = solid.stress_tensor_field;
  v.displacement_field = solid.displacement_field;
  v.mass_grams = solid.mass_grams;
  v.support_volume_voxels = solid.support_volume_voxels;
  v.applied_build_dir = build_dir;
  {
    VariantReport vr;
    vr.volume_fraction = solid.printed_fraction;
    vr.printed_fraction = solid.printed_fraction;
    vr.max_stress_mpa = solid.max_von_mises;
    vr.max_interlayer_tension_mpa = solid.max_interlayer_tension;
    vr.margin = solid.margin;
    vr.accepted = solid.accepted;
    vr.margin_required = options.margin_stop;
    vr.margin_effective = solid.margin_effective;
    vr.scenarios = solid_scenarios;
    v.report = vr;
  }

  // ── the lattice the file holds, on this grid (V4).
  const ll::Outcome& out = *ask.outcome;
  ll::CreditGrid g;
  g.origin = cert_grid.origin;
  g.spacing = cert_grid.spacing;
  g.nx = cert_grid.nx;
  g.ny = cert_grid.ny;
  g.nz = cert_grid.nz;
  const ll::LatticeCredit credit = ll::lattice_credit(out.layout, *ask.session->domain(), out.bars,
                                                      ask.made->left_out_at, g, &in_part, ask.threads);
  const LatticeTopology topo = out.layout.topology;
  LatticePosture post;
  post.topology = topo;
  const std::size_t nv = cert_grid.voxel_count();
  post.mask.assign(nv, 0);
  post.relative_density.assign(nv, 0.0);
  post.cell_size_field.assign(nv, 0.0);
  std::vector<char> no_credit(nv, 0);
  const double rho_floor = lattice_rho_min(topo);
  for (std::size_t e = 0; e < nv; ++e) {
    const std::int32_t c = credit.cell[e];
    if (c < 0) continue;
    const ll::Cell& cell = out.layout.cells[static_cast<std::size_t>(c)];
    post.mask[e] = 1;
    post.cell_size_field[e] = cell.size;
    post.cell_size_mm = std::max(post.cell_size_mm, cell.size);
    if (credit.credited[e]) {
      post.relative_density[e] = credit.cell_rho[static_cast<std::size_t>(c)];
    } else {
      // Void in the composite solve (certify_latticed_variant's open_cut): its density is never read.
      post.relative_density[e] = rho_floor;
      no_credit[e] = 1;
    }
  }

  // ── THE OLD CHECK, unchanged: the null-posture solve, the composite solve, the gate. Its context is the one the
  // old run builds, with the settings laid over it (each equal to what it replaces when not stated).
  LatticeCertContext cx = lattice_cert_context(v, model_grid, domain, options, material, job);
  cx.params.density_min = params.density_min;
  cx.knockdown = knockdown;
  cx.printed_iso = printed_iso;
  cx.connectivity = connectivity;
  cx.load_path_ok = load_path_connected(cert_grid, density, printed_iso, connectivity);
  cx.unheld_share = st.get("scenario_unheld_share");
  cx.knobs = &knobs;
  if (!domain.scenarios.empty()) {
    cx.scenarios.clear();
    const std::vector<char> on = lattice_scenario_flags(job, sized);
    for (std::size_t s = 0; s < sized.size(); ++s)
      if (on[s]) cx.scenarios.push_back(sized[s]);
  }
  std::vector<ScenarioFields> lattice_fields;
  LatticeCertOutcome oc;
  {
    const ScopedLadderSolverIsolation solver_isolation;
    oc = certify_latticed_variant(v, cert_grid, options, material, domain.bcs, cx, post,
                                  std::numeric_limits<double>::quiet_NaN(), &no_credit,
                                  cx.scenarios.empty() ? nullptr : &lattice_fields);
  }
  const FixedDesignAnalysis& a = oc.lattice;
  if (a.non_convergent)
    return strength_no("strength_failed", 1,
                       "The strength check's solve did not settle, so the lattice's strength is not known. No file "
                       "was made.",
                       "the composite certification solve did not converge (iteration " +
                           std::to_string(a.non_convergent_iteration) + ")");

  ll::StrengthDone done;
  // ── fields.bin (and scenario_fields.bin), the composite solve's, as the old Lattice run writes them.
  {
    MinimizePlasticResult fr;
    fr.report.material = job.material;
    MinimizePlasticVariant fv;
    fv.requested_volume_fraction = v.requested_volume_fraction;
    fv.accepted = a.accepted;
    fv.von_mises_field = a.von_mises_field;
    fv.stress_tensor_field = a.stress_tensor_field;
    fv.displacement_field = a.displacement_field;
    fv.mass_grams = a.mass_grams;
    fv.support_volume_voxels = a.support_volume_voxels;
    fv.report.scenarios = oc.scenarios;
    fv.scenario_fields = std::move(lattice_fields);
    fr.evaluated.push_back(std::move(fv));
    write_fields_file(join_path(ask.out_dir, "fields.bin"), fr, cert_grid, /*accepted_only=*/false);
    if (std::string why; S.frame.on && !turn_fields_file_to_model(S.frame, join_path(ask.out_dir, "fields.bin"), &why))
      return strength_no("strength_failed", 1, "The lattice's strength could not be checked, so no file was made.",
                         "fields.bin could not be turned back to the part's frame: " + why);   // P2
    done.files.push_back("fields.bin");
    // P2: with a print frame the per-scenario fields are not written (their container is not turned back yet).
    if (!S.frame.on && write_scenario_fields_file(join_path(ask.out_dir, "scenario_fields.bin"), fr, cert_grid) > 0)
      done.files.push_back("scenario_fields.bin");
  }

  // ── the block (the old receipt's names, renamed: lattice_accepted -> accepted, ...).
  const bool law = a.lattice_strut_report;
  const StrutStrengthReport& ss = a.lattice_strut;
  const double nan = std::numeric_limits<double>::quiet_NaN();
  // V5 (his ruling, 2026-11-17): in Structural the lattice passes only when the solid AND the struts keep the safety
  // margin. `accepted` stays the old gate exactly; a type with no strut law cannot reach a full pass. A result, never a
  // refusal: the file is made in all three cases.
  // A credited cell lighter than where the type's law has a boundary value (octet: under 0.10, its lowest row is
  // bulk only, a lower bound) is not given a strut pass on that row alone: its strut result is out of regime.
  double lightest_credited = std::numeric_limits<double>::infinity();
  for (std::size_t c = 0; c < credit.cell_credit.size(); ++c)
    if (credit.cell_credit[c]) lightest_credited = std::min(lightest_credited, credit.cell_rho[c]);
  const double bulk_only_below = law ? strut_law_bulk_only_below(topo) : 0.0;
  const bool bulk_only = law && lightest_credited < bulk_only_below;
  const bool out_of_regime = a.lattice_strut_out_of_regime || bulk_only;
  std::string regime_note;
  if (a.lattice_strut_out_of_regime)
    regime_note = "the thinnest latticed member spans fewer cells than the measured homogenization floor, so the macro "
                  "stress field these strut numbers amplify is itself out of the tensor's validated regime: treat them "
                  "as indicative, not certified";
  if (bulk_only)
    regime_note += std::string(regime_note.empty() ? "" : "; ") + "some cells are lighter than " +
                   json_num(bulk_only_below) + " of solid, where the strut rule was measured inside the lattice only " +
                   "(not where it is cut or meets a surface, which reads about 1.6 times higher), so it cannot give "
                   "the struts a pass";
  const bool struts_pass = law && !bulk_only && ss.margin_worst_case >= options.margin_stop;
  const char* verdict = !a.accepted ? "fail" : struts_pass ? "pass" : "solid_only";
  std::string s = "{\n";
  s += "    \"accepted\": " + std::string(a.accepted ? "true" : "false") + ",\n";
  s += "    \"struts_pass\": " + std::string(struts_pass ? "true" : "false") + ",\n";
  s += "    \"verdict\": \"" + std::string(verdict) + "\",\n";
  // V5: why a fail failed, so a fine solid margin beside "fail" is never left unexplained.
  //   load_on_open_lattice  the load has no path AND some of it lands on lattice given no credit (empty in the check)
  //   no_load_path          the load has no path, for any other reason
  //   solid_margin          the path is there and the solid's margin is under the safety margin
  // (A fail for none of these, e.g. anchors that only slide, carries no fail_reason.)
  if (!a.accepted) {
    const bool path_ok = oc.open_finish ? oc.open_load_path_ok : cx.load_path_ok;
    // The load of the solve that governs: the job's one load case, or the governing scenario's.
    const std::vector<NodalLoad>* lv = &cx.loads;
    for (const ScenarioReport& r : oc.scenarios)
      if (r.governs)
        for (const SimpScenario& sc : cx.scenarios)
          if (sc.name == r.name) lv = &sc.loads;
    // Per loaded node, its force; it lands on open lattice when a voxel round it has no credit and none round it is
    // printed in the check (solid, or credited lattice).
    std::map<int, Vec3> force;
    for (const NodalLoad& l : *lv) {
      Vec3& f = force[l.node];
      (l.component == 0 ? f.x : l.component == 1 ? f.y : f.z) += l.value;
    }
    double total = 0.0, on_open = 0.0;
    if (!force.empty()) {
      for (int c = 0; c <= cert_grid.nz; ++c)
        for (int b = 0; b <= cert_grid.ny; ++b)
          for (int a2 = 0; a2 <= cert_grid.nx; ++a2) {
            const auto it = force.find(fea_node_index(cert_grid, a2, b, c));
            if (it == force.end()) continue;
            const Vec3& f = it->second;
            const double mag = std::sqrt(f.x * f.x + f.y * f.y + f.z * f.z);
            total += mag;
            bool open = false, printed = false;
            for (int dk = -1; dk <= 0; ++dk)
              for (int dj = -1; dj <= 0; ++dj)
                for (int di = -1; di <= 0; ++di) {
                  const int i = a2 + di, j = b + dj, k = c + dk;
                  if (i < 0 || j < 0 || k < 0 || i >= cert_grid.nx || j >= cert_grid.ny || k >= cert_grid.nz) continue;
                  const std::size_t e = cert_grid.index(i, j, k);
                  if (no_credit[e]) open = true;
                  else if (density[e] > printed_iso) printed = true;
                }
            if (open && !printed) on_open += mag;
          }
    }
    const char* reason = !path_ok ? (on_open > 0.0 ? "load_on_open_lattice" : "no_load_path")
                         : a.margin_effective < options.margin_stop ? "solid_margin"
                                                                    : nullptr;
    if (reason) {
      s += "    \"fail_reason\": \"" + std::string(reason) + "\",\n";
      if (std::string(reason) == "load_on_open_lattice")
        s += "    \"load_on_no_credit_n\": " + json_num(on_open) + ",\n    \"load_total_n\": " + json_num(total) + ",\n";
    }
  }
  s += "    \"margin_worst_case\": " + json_num(a.margin.worst_case) + ",\n";
  s += "    \"margin_in_plane\": " + json_num(a.margin.in_plane) + ",\n";
  s += "    \"margin_interlayer\": " + json_num(a.margin.interlayer) + ",\n";
  s += "    \"safety_margin\": " + json_num(options.margin_stop) + ",\n";
  s += "    \"not_certified\": " + std::string(a.lattice_not_certified ? "true" : "false") + ",\n";
  s += "    \"not_certified_reason\": " + json_str(a.lattice_not_certified_reason) + ",\n";
  s += "    \"mass_grams\": " + json_num(a.mass_grams) + ",\n";
  s += "    \"max_effective_von_mises_mpa\": " + json_num(a.lattice_max_effective_vm) + ",\n";
  s += "    \"max_interlayer_tension_mpa\": " + json_num(a.max_interlayer_tension) + ",\n";
  s += "    \"cells_credited\": " + std::to_string(credit.cells_credited) + ",\n";
  s += "    \"cells_no_credit\": " + std::to_string(credit.cells_no_credit) + ",\n";
  s += "    \"voxel_mm\": " + json_num(cert_grid.spacing) + ",\n";
  const Vec3 cx_up = S.frame.dir_to_model(cx.build_dir);   // P2: in the part's own coordinates
  s += "    \"build_direction\": {\"x\": " + json_num(cx_up.x) + ", \"y\": " + json_num(cx_up.y) +
       ", \"z\": " + json_num(cx_up.z) + "},\n";
  // The re-solve proof (certify_latticed_variant's step 1): the all-solid design solved again must give the margin
  // the solid solve gave, within kMarginReproductionResidualFactor x the solver tolerance. A record; not the verdict.
  s += "    \"resolve_reproduces\": " + std::string(oc.solid_reproduces_within_band ? "true" : "false") +
       ", \"resolve_margin_solid\": " + json_num(oc.solid_margin.worst_case) +
       ", \"resolve_margin_again\": " + json_num(oc.solid_margin_reproduced) + ",\n";
  s += "    \"strut\": {\"law\": " + (law ? json_str(strut_law_source(topo)) : std::string("null")) +
       // The type has no strut law to certify its struts by (brief: Bccz, Fccz, Reentrant).
       ", \"uncertified\": " + std::string(!law ? "true" : "false") +
       ", \"gated\": " + std::string(a.strut_gated ? "true" : "false") +
       ", \"margin_in_plane\": " + json_num(law ? ss.margin_in_plane : nan) +
       ", \"margin_interlayer\": " + json_num(law ? ss.margin_interlayer : nan) +
       ", \"margin_worst_case\": " + json_num(law ? ss.margin_worst_case : nan) +
       ", \"out_of_regime\": " + std::string(out_of_regime ? "true" : "false") +
       ", \"regime_note\": " + json_str(regime_note) + "},\n";
  s += "    \"fields\": \"fields.bin\",\n";
  if (done.files.size() > 1) s += "    \"scenario_fields\": \"scenario_fields.bin\",\n";
  // The old report's diagnosis (diagnose_gate), on the composite analysis, when it is not accepted.
  if (!a.accepted) {
    GateDiagnosisInputs gd;
    gd.accepted = a.accepted;
    gd.load_path_ok = oc.open_finish ? oc.open_load_path_ok : cx.load_path_ok;
    gd.margin_stop = options.margin_stop;
    gd.margin_effective = a.margin_effective;
    gd.margin = a.margin;
    gd.material = material;
    gd.material_name = job.material;
    gd.knockdown = cx.knockdown;
    gd.max_von_mises = a.max_von_mises;
    gd.max_von_mises_effective = a.max_von_mises;
    gd.max_interlayer = a.max_interlayer_tension;
    gd.infill_percent = options.infill_percent;
    gd.wall_loops = options.wall_loops;
    gd.wall_line_width_mm = options.wall_line_width_mm;
    gd.wall_line_width_outer_mm = options.wall_line_width_outer_mm;
    gd.min_feature_violations = a.v3.min_feature_violations;
    gd.min_feature_warning_threshold =
        rules.min_feature_warning.message_template.empty() ? 0 : rules.min_feature_warning.threshold;
    gd.voxel_spacing_mm = cert_grid.spacing;
    gd.materials = &materials;
    gd.poisson_locked = true;
    for (const DirichletBC& bc : domain.bcs)
      if (bc.value != 0.0) { gd.poisson_locked = false; break; }
    gd.this_volume_fraction = a.printed_fraction;
    gd.printed_von_mises = a.gate_printed_von_mises;
    gd.printed_member_width_mm = a.gate_printed_member_width_mm;
    const GateDiagnosis d = diagnose_gate(gd);
    if (d.evaluated) {
      s += "    \"diagnosis\": ";
      emit_gate_diagnosis(s, d, "    ");
      s += ",\n";
    }
  }
  // ── settings: every variable's value this check used, by its key in docs/strength-check/variables.json.
  {
    std::string t = "{";
    bool first = true;
    const auto add = [&](const char* key, const std::string& value) {
      t += std::string(first ? "\n      \"" : ",\n      \"") + key + "\": " + value;
      first = false;
    };
    const auto num = [](double x) { return json_num(x); };
    const auto yes = [](bool b) { return std::string(b ? "true" : "false"); };
    const auto per_type = [&](double x, bool known) { return known ? json_num(x) : std::string("null"); };
    const bool measured = lattice_type_numbers_measured(topo);
    // The user's (already job keys).
    add("safety_margin", num(options.margin_stop));
    add("material", json_str(job.material));
    add("resolution", std::to_string(job.resolution));
    add("build_direction", "[" + num(cx_up.x) + ", " + num(cx_up.y) + ", " + num(cx_up.z) + "]");
    add("infill_percent", num(options.infill_percent));
    add("wall_loops", std::to_string(options.wall_loops));
    add("wall_line_width_mm", num(options.wall_line_width_mm));
    add("anchor_model", json_str(has_contact_springs(domain.bcs) ? "bearing" : "glued"));
    {
      std::string names = "[";
      for (std::size_t i = 0; i < cx.scenarios.size(); ++i) names += (i ? ", " : "") + json_str(cx.scenarios[i].name);
      add("lattice_scenarios", job.lattice.scenarios_stated ? names + "]" : json_str("all"));
    }
    add("gravity_mm_s2", job.loads.present ? std::string("null") : num(job.gravity.magnitude_mm_s2));
    add("topology", json_str(lattice_topology_name(topo)));
    {
      double c_lo = 0.0, c_hi = 0.0, w_lo = 0.0, w_hi = 0.0;
      for (std::size_t i = 0; i < out.layout.cells.size(); ++i) {
        const ll::Cell& c = out.layout.cells[i];
        if (i == 0) { c_lo = c_hi = c.size; w_lo = w_hi = c.strut; }
        c_lo = std::min(c_lo, c.size); c_hi = std::max(c_hi, c.size);
        w_lo = std::min(w_lo, c.strut); w_hi = std::max(w_hi, c.strut);
      }
      add("cell_size_mm", "[" + num(c_lo) + ", " + num(c_hi) + "]");
      add("strut_width_mm", "[" + num(w_lo) + ", " + num(w_hi) + "]");
    }
    // The material file's (the layer factor as used, below).
    add("yield_strength_mpa", num(material.yield_strength_mpa));
    add("youngs_modulus_mpa", num(material.youngs_modulus_mpa));
    add("poisson", num(material.poisson));
    add("material_density_g_cm3", num(material.density_g_cm3));
    // Chosen.
    {
      std::string z = "{";
      bool f1 = true;
      for (const auto& [name, m] : materials) {
        const auto it = st.z_knockdown.find(name);
        z += std::string(f1 ? "" : ", ") + json_str(name) + ": " + num(it != st.z_knockdown.end() ? it->second : m.z_knockdown);
        f1 = false;
      }
      add("z_knockdown", z + "}");
    }
    add("safety_margin_floor", num(st.get("safety_margin_floor")));
    add("infill_exponent", num(knockdown.infill_exponent));
    add("infill_floor", num(knockdown.infill_floor));
    add("width_aware_knockdown", yes(knockdown.width_aware));
    add("thickness_cap_voxels", std::to_string(knobs.thickness_cap_voxels));
    add("load_path_connectivity", std::to_string(connectivity));
    add("printed_threshold", num(printed_iso));
    add("void_floor", num(std::pow(params.density_min, params.penalty)));
    add("cg_tolerance", num(options.simp.cg_tolerance));
    add("cg_max_iterations", std::to_string(options.simp.cg_max_iterations));
    add("contact_rounds", std::to_string(knobs.contact_rounds));
    add("sliding_share_max", num(knobs.sliding_share_max));
    add("bearing_stiffness", num(st.get("bearing_stiffness")));
    add("bearing_tangent_fraction", num(st.get("bearing_tangent_fraction")));
    add("scenario_weak_spring", num(st.get("scenario_weak_spring")));
    add("scenario_weak_spring_min_scale", num(st.get("scenario_weak_spring_min_scale")));
    add("scenario_unheld_share", num(cx.unheld_share));
    add("part_box_tol_mm", num(st.get("part_box_tol_mm")));
    add("part_box_tol_fraction", num(st.get("part_box_tol_fraction")));
    add("no_credit_cut_cells", "true");
    add("no_credit_lost_bar", "true");
    add("no_credit_out_of_band", "true");
    add("left_out_bar_z_tol", num(0.45));
    add("left_out_bar_reach", num(0.35));
    add("homogenisation_error_band", num(2.4));
    add("strut_gate_only_without_solid", "true");
    add("struts_in_verdict", "true");
    add("strut_law_clamps_density", "true");
    add("min_feature_warning_threshold",
        std::to_string(rules.min_feature_warning.message_template.empty() ? 0 : rules.min_feature_warning.threshold));
    // Measured (this type's).
    const bool band = lattice_rho_max(topo) > 0.0;
    add("rho_min", per_type(lattice_rho_min(topo), band));
    add("rho_max", per_type(lattice_rho_max(topo), band));
    add("lattice_stiffness_table", json_str(band ? "measured" : "none"));
    add("density_from_strut_table", json_str(measured ? "measured" : "none"));
    add("cells_per_member_min", per_type(lattice_cells_per_member_min(topo), measured));
    add("strut_law_table", json_str(strut_law_measured(topo) ? "measured" : "none"));
    add("strut_law_span", strut_law_measured(topo)
                              ? "[" + num(strut_law_rho_min(topo)) + ", " + num(strut_law_rho_max(topo)) + "]"
                              : std::string("null"));
    add("margin_reproduction_band", num(kMarginReproductionResidualFactor * cx.cert_tol));
    add("scenario_min_load_share", num(kScenarioMinLoadShare));
    // Physics.
    add("voxel_mm", num(cert_grid.spacing));
    add("library_modulus_scaling", num(material.youngs_modulus_mpa / 3500.0));
    add("interlayer_cross_factor", law ? num(ss.il_cross_factor) : std::string("null"));
    add("gravity_unit", num(kGramPerCm3ToTonnePerMm3));
    s += "    \"settings\": " + t + "\n    },\n";
  }
  // run_info, as the old run writes it (the core's build and the job's echo), nested.
  {
    std::string ri = run_info_json(build_run_info(job, options, build_identity()));
    while (!ri.empty() && (ri.back() == '\n' || ri.back() == ' ')) ri.pop_back();
    std::string nested;
    for (const char ch : ri) {
      nested += ch;
      if (ch == '\n') nested += "    ";
    }
    s += "    \"run_info\": " + nested + ",\n";
  }
  const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t_start).count();
  s += "    \"ms\": " + json_num(std::round(ms * 10.0) / 10.0) + "\n  }";
  done.ok = true;
  done.json = std::move(s);
  done.accepted = a.accepted;
  return done;
}

// The interim guard's plain sentence (the reviewer's ruling with the owner's approval, 2026-11-26).
constexpr double kSolidDepthNeededVoxels = 1.5;   // measured, see solid_depth_needed_mm
const char* const kLoadOnBareLatticeText =
    "A load lands on bare vines. Give the loaded face a Solid finish or a protected skin so its strength can be checked.";

// ══ BRIEF E2, PART A: THE ORGANIC CHECK, A FRAME OF BEAMS (lattice_layout_frame.hpp) ═════════════════════════════
// On the strength job's own grid and load case (strength_setup, as Install 3's): the material per voxel is the part's
// solid share plus the lattice's (frame_material, every bar the file holds), solved once at penalty 1; the frame of
// the bars is driven by that solve and judged strut by strut (check_frame).
ll::FrameSettings frame_settings_of(const StrengthSettingsAsked& st) {
  ll::FrameSettings f;
  f.node_weld_mm = st.get("frame_node_weld_mm");
  f.tjoin_reach_mm = st.get("frame_tjoin_reach_mm");
  f.tjoin_off_line_mm = st.get("frame_tjoin_off_line_mm");
  f.zero_piece_mm = st.get("frame_zero_piece_mm");
  f.link_stiffness = st.get("frame_link_stiffness");
  f.drive_ball_voxels = st.get("frame_drive_ball_voxels");
  f.drive_share = st.get("frame_drive_share");
  f.drive_reach_voxels = st.get("frame_drive_reach_voxels");
  f.collinear_tol_mm = st.get("frame_collinear_tol_mm");
  f.collinear_max_driven = static_cast<int>(st.get("frame_collinear_max_driven"));
  f.floor_shift_voxels = st.get("frame_floor_shift_voxels");
  f.floor_free = st.get("frame_floor_free") != 0.0;
  f.load_unheld_share = st.get("load_unheld_share");
  f.unjudged_share = st.get("frame_unjudged_share");
  f.min_piece = st.get("frame_min_piece");
  f.material_subdiv = static_cast<int>(st.get("frame_material_subdiv"));
  f.solve_memory_gb = st.get("frame_solve_memory_gb");
  f.weakest = static_cast<int>(st.get("frame_weakest"));
  return f;
}

struct OrganicCheckRun {
  ll::StrengthDone done;          // ok: the block (json) and the files written
  ll::FrameModel frame;
  ll::FrameCheck check;
  std::vector<int> bar_of;        // per bar the frame was built from: its place in the layout's order
  double lattice_mm3 = 0.0, lattice_open_mm3 = 0.0;
  double ms_material = 0.0, ms_voxel = 0.0, ms_frame = 0.0;
  double mb_voxel = 0.0, mb_frame = 0.0;   // the process's footprint after each (process_memory().rss_mb)
  std::string verdict, fail_reason;
  StressMargin solid_margin;              // over the voxels at least printed_threshold solid
  double solid_margin_effective = 0.0, solid_vm = 0.0, solid_tension = 0.0;
  std::size_t solid_voxels = 0;
  int passes_at_infill_percent = -1;      // the lowest whole infill percent at which the solid passes; -1: none
};

// OS16 amended (the lead, 2026-11-19): what a print check after a round did among the bars that were there before the
// round (`before`, with `before_kept` the file's of them). `added` the bars after the round's additions, `after` and
// `after_kept` the print check's (its sag pass keeps every bar's place in the list and appends what it lays). Counted:
// pieces of old bars the file kept that it now leaves out (`print_left_out`), of which those the round widened
// (`print_left_out_widened`); pieces of old bars it moved (`print_moved`); the bars it added (`print_added`); each with
// up to five places (a bar's middle, mm). As JSON keys, for a round's result. `moved_any`: set when it moved one.
// P2: a strengthening made in a print frame says which (strengthened.json's "print_up"; load_file_job refuses one made
// standing another way). Nothing with no frame (the file as before).
std::string print_up_json(const PrintFrame& f) {
  if (!f.on) return {};
  return ",\n  \"print_up\": [" + json_num(f.up.x) + ", " + json_num(f.up.y) + ", " + json_num(f.up.z) + "]";
}

std::string print_check_counts(const ll::Bars& before, const std::vector<char>& before_kept, const ll::Bars& added,
                               const ll::Bars& after, const std::vector<char>& after_kept, bool* moved_any,
                               const PrintFrame& frame = PrintFrame{}) {
  const std::vector<std::vector<std::size_t>> on = ll::pieces_on(added, before.bars);
  std::vector<int> old_of(added.bars.size(), -1);
  for (std::size_t k = 0; k < on.size(); ++k)
    for (std::size_t j : on[k]) old_of[j] = static_cast<int>(k);
  std::size_t left = 0, left_widened = 0, moved = 0;
  std::string left_at, widened_at, moved_at, added_at;
  const auto mid = [&](const ll::Bar& b0) {
    ll::Bar b = b0;   // P2: in the part's own coordinates
    b.a = frame.point_to_model(b0.a);
    b.b = frame.point_to_model(b0.b);
    return "[" + json_num(std::round(500.0 * (b.a.x + b.b.x)) / 1000.0) + ", " + json_num(std::round(500.0 * (b.a.y + b.b.y)) / 1000.0) +
           ", " + json_num(std::round(500.0 * (b.a.z + b.b.z)) / 1000.0) + "]";
  };
  const auto note = [&](std::string& list, std::size_t count, const ll::Bar& b) {
    if (count <= 5) list += std::string(list.empty() ? "" : ", ") + mid(b);
  };
  for (std::size_t j = 0; j < added.bars.size() && j < after.bars.size(); ++j) {
    const int k = old_of[j];
    if (k < 0) continue;
    const ll::Bar& x = added.bars[j];
    const ll::Bar& y = after.bars[j];
    if (x.a.x != y.a.x || x.a.y != y.a.y || x.a.z != y.a.z || x.b.x != y.b.x || x.b.y != y.b.y || x.b.z != y.b.z) {
      ++moved;
      note(moved_at, moved, x);
    }
    const bool was = static_cast<std::size_t>(k) < before_kept.size() && before_kept[static_cast<std::size_t>(k)];
    const bool now = j < after_kept.size() && after_kept[j];
    if (was && !now) {
      ++left;
      note(left_at, left, x);
      if (x.width > before.bars[static_cast<std::size_t>(k)].width + 1e-12) {
        ++left_widened;
        note(widened_at, left_widened, x);
      }
    }
  }
  const std::size_t extra = after.bars.size() > added.bars.size() ? after.bars.size() - added.bars.size() : 0;
  for (std::size_t j = added.bars.size(); j < after.bars.size() && j < added.bars.size() + 5; ++j)
    added_at += std::string(added_at.empty() ? "" : ", ") + mid(after.bars[j]);
  if (moved_any && moved > 0) *moved_any = true;
  return "\"print_left_out\": " + std::to_string(left) + ", \"print_left_out_at\": [" + left_at +
         "], \"print_left_out_widened\": " + std::to_string(left_widened) + ", \"print_left_out_widened_at\": [" + widened_at +
         "], \"print_moved\": " + std::to_string(moved) + ", \"print_moved_at\": [" + moved_at +
         "], \"print_added\": " + std::to_string(extra) + ", \"print_added_at\": [" + added_at + "]";
}

// Brief E3a, item 1: every judged strut under `watch`, what strengthening by adding reads of it: its bars in the
// layout's order (in piece order, each once), the limit that failed, its margins, the compression its buckling used,
// whether bending led its stress, its widths and length, whether it is at `cap` (its widest bar at least cap; 0: not
// told), whether it carries the load, and its two ends. The weakest first.
std::string struts_under_json(const OrganicCheckRun& cr, double watch, double cap, const std::vector<std::string>* classes = nullptr,
                              const ll::Bars* layout_bars = nullptr, const PrintFrame& frame = PrintFrame{}) {
  const ll::FrameCheck& c = cr.check;
  std::vector<int> order;
  for (std::size_t i = 0; i < c.struts.size(); ++i)
    if (c.struts[i].judged && c.struts[i].margin < watch) order.push_back(static_cast<int>(i));
  std::sort(order.begin(), order.end(), [&](int a, int b) {
    const double ma = c.struts[static_cast<std::size_t>(a)].margin, mb = c.struts[static_cast<std::size_t>(b)].margin;
    return ma != mb ? ma < mb : a < b;
  });
  const auto v3 = [&](const Vec3& q) {   // P2: in the part's own coordinates
    const Vec3 p = frame.point_to_model(q);
    return "[" + json_num(p.x) + ", " + json_num(p.y) + ", " + json_num(p.z) + "]";
  };
  std::string s = "{\n  \"watch_margin\": " + json_num(watch) + ",\n  \"cap_mm\": " + json_num(cap) + ",\n  \"struts\": [";
  for (std::size_t q = 0; q < order.size(); ++q) {
    const ll::FrameStrut& sn = c.struts[static_cast<std::size_t>(order[q])];
    std::vector<int> bars;
    for (int pi : sn.pieces) {
      const int fb = cr.frame.pieces[static_cast<std::size_t>(pi)].bar;
      const int lb = fb >= 0 && static_cast<std::size_t>(fb) < cr.bar_of.size() ? cr.bar_of[static_cast<std::size_t>(fb)] : -1;
      if (std::find(bars.begin(), bars.end(), lb) == bars.end()) bars.push_back(lb);
    }
    std::string bl;
    for (std::size_t k = 0; k < bars.size(); ++k) bl += (k ? ", " : "") + std::to_string(bars[k]);
    std::string ends;
    for (int e = 0; e < 2; ++e) {
      if (sn.end_node[e] < 0) continue;
      const char k = sn.end_kind[e];
      ends += std::string(ends.empty() ? "" : ", ") + "{\"at\": " + v3(cr.frame.nodes[static_cast<std::size_t>(sn.end_node[e])]) +
              ", \"kind\": " + json_str(k == 'd' ? "driven" : k == 'j' ? "joint" : k == 'f' ? "free" : "other") +
              ", \"floor\": " + (sn.end_floor[e] ? "true" : "false") + "}";
    }
    s += std::string(q ? "," : "") + "\n    {\"strut\": " + std::to_string(order[q]) + ", \"margin\": " + json_num(sn.margin) +
         ", \"stress_margin\": " + json_num(std::isfinite(sn.stress_margin) ? sn.stress_margin : -1.0) +
         ", \"buckling_margin\": " + json_num(std::isfinite(sn.buckling_margin) ? sn.buckling_margin : -1.0) +
         ", \"by\": " + json_str(sn.by) + ", \"bending_led\": " + (sn.bending_led ? "true" : "false") +
         ", \"n_min\": " + json_num(sn.n_min) + ", \"width_min_mm\": " + json_num(sn.width_min) +
         ", \"width_max_mm\": " + json_num(sn.width_max) + ", \"length_mm\": " + json_num(sn.length_mm) +
         ", \"at_cap\": " + (cap > 0.0 && sn.width_max >= cap - 1e-9 ? "true" : "false") +
         ", \"loaded\": " + (sn.loaded ? "true" : "false") + ", \"at\": " + v3(sn.at) + ",\n     \"ends\": [" + ends +
         "], \"bars\": [" + bl + "]" +
         (classes && static_cast<std::size_t>(order[q]) < classes->size()
              ? ", \"class\": " + json_str((*classes)[static_cast<std::size_t>(order[q])]) : std::string()) +
         (layout_bars && !bars.empty() && bars.front() >= 0 && static_cast<std::size_t>(bars.front()) < layout_bars->bars.size()
              ? ", \"region\": " + std::to_string(layout_bars->bars[static_cast<std::size_t>(bars.front())].region) : std::string()) + "}";
  }
  s += std::string(order.empty() ? "" : "\n  ") + "]\n}\n";
  return s;
}

OrganicCheckRun organic_frame_check(StrengthSetup& S, const ll::Domain& ldomain, const ll::Bars& layout_bars,
                                    const std::vector<char>* kept, double light_width_mm,
                                    const std::string& out_dir, int threads) {
  const auto t_start = std::chrono::steady_clock::now();
  OrganicCheckRun R;
  JobDescription& job = S.job;
  StrengthSettingsAsked& st = S.st;
  Material& material = S.material;
  MinimizePlasticOptions& options = S.options;
  const SolvedDesignDomain& domain = S.domain;
  const VoxelGrid& cert_grid = domain.grid;
  if (!domain.scenarios.empty()) {
    R.done = strength_no("strength_failed", 1,
                         "The Organic strength check takes the strength job's one load case, and this job has load "
                         "scenarios, so no file was made.",
                         "the frame check does not take load scenarios");
    return R;
  }
  const ll::FrameSettings fs = frame_settings_of(st);
  // The bars the file holds.
  ll::Bars bars;
  for (std::size_t i = 0; i < layout_bars.bars.size(); ++i) {
    if (kept && (i >= kept->size() || !(*kept)[i])) continue;
    bars.bars.push_back(layout_bars.bars[i]);
    R.bar_of.push_back(static_cast<int>(i));
  }
  // ── the material per voxel, and the voxel solve (penalty 1).
  auto t0 = std::chrono::steady_clock::now();
  const ll::FrameMaterial fm = ll::frame_material(bars, ldomain, cert_grid, fs, threads);
  R.lattice_mm3 = fm.lattice_mm3;
  R.lattice_open_mm3 = fm.lattice_open_mm3;
  R.ms_material = fm.ms;
  std::vector<double> density(cert_grid.voxel_count(), 0.0);
  std::vector<char> in_part(cert_grid.voxel_count(), 0);
  for (int k = 0; k < cert_grid.nz; ++k)
    for (int j = 0; j < cert_grid.ny; ++j)
      for (int i = 0; i < cert_grid.nx; ++i)
        if (cert_grid.solid(i, j, k)) {
          const std::size_t e = cert_grid.index(i, j, k);
          density[e] = std::min(1.0, static_cast<double>(fm.solid[e]) + static_cast<double>(fm.lattice[e]));
          in_part[e] = 1;
        }
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 1.0;
  params.density_min = st.get("frame_void_floor");   // at penalty 1 an empty voxel keeps this share of the stiffness
  const double printed_iso = st.get("printed_threshold");
  const int connectivity = static_cast<int>(st.get("load_path_connectivity"));
  AnalysisKnobs knobs;
  knobs.contact_rounds = static_cast<int>(st.get("contact_rounds"));
  knobs.sliding_share_max = st.get("sliding_share_max");
  knobs.thickness_cap_voxels = static_cast<int>(st.get("thickness_cap_voxels"));
  const Vec3 build_dir = resolve_build_direction(options);
  const std::vector<NodalLoad> loads = design_domain_loads(domain, options, material.density_g_cm3);
  const bool load_path_ok = load_path_connected(cert_grid, density, printed_iso, connectivity);
  KnockdownSpec knockdown = knockdown_spec_for(options);
  knockdown.infill_exponent = st.get("infill_exponent");
  knockdown.infill_floor = st.get("infill_floor");
  knockdown.infill_knockdown =
      infill_margin_knockdown(options.infill_percent, knockdown.infill_exponent, knockdown.infill_floor);
  const FixedDesignAnalysis a = analyze_fixed_design(
      cert_grid, params, density, domain.bcs, loads, material, build_dir, options.simp.cg_tolerance,
      options.simp.cg_max_iterations, options.simp.solver, options.margin_stop, knockdown, load_path_ok,
      static_cast<double>(S.model_grid.solid_count()), /*lattice=*/nullptr, /*score=*/false,
      resolve_build_direction_is_inferred(options), /*auto_apply=*/false, printed_iso,
      /*gate_on_strut_strength=*/false, &knobs);
  R.ms_voxel = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  R.mb_voxel = process_memory().rss_mb;
  if (a.non_convergent) {
    R.done = strength_no("strength_failed", 1,
                         "The strength check's solve did not settle, so the lattice's strength is not known. No file "
                         "was made.",
                         "the Organic voxel solve did not converge (iteration " +
                             std::to_string(a.non_convergent_iteration) + ")");
    return R;
  }
  // ── the frame.
  t0 = std::chrono::steady_clock::now();
  R.frame = ll::build_frame(bars, &ldomain, fs);
  ll::FrameVoxelSolve vs;
  vs.grid = &cert_grid;
  vs.displacement = &a.displacement_field;
  vs.material = &fm;
  for (const NodalLoad& l : loads) vs.loads.push_back({l.node, l.component, l.value});
  ll::FrameStrength fst;
  fst.youngs_mpa = material.youngs_modulus_mpa;
  fst.poisson = material.poisson;
  fst.level_mpa = material.yield_strength_mpa;
  fst.across_mpa = material.yield_strength_mpa * material.z_knockdown;
  fst.up = build_dir;
  fst.safety = options.margin_stop;
  fst.light_width_mm = light_width_mm;
  fst.also_up = S.ups;   // P4: the same struts, judged against each candidate up the file job asked for
  R.check = ll::check_frame(R.frame, vs, fst, fs);
  R.ms_frame = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  R.mb_frame = process_memory().rss_mb;
  const ll::FrameCheck& c = R.check;
  // ── the solid's verdict (the lead's ruling of 2026-11-18): its STRESS margin only, over the voxels whose SOLID share
  // is at least printed_threshold (the lattice's voxels are the frame's to judge), against the safety margin. Install 3's
  // load-path test of the voxel solve is not applied: it reads sparse lattice voxels as no material. The load path is
  // judged on the frame: a frame node within the load's reach on a piece with no driven node.
  // The knockdown is Install 3's (knockdown_spec_for: the infill curve, and with width_aware_knockdown the per-voxel
  // wall rescue on the member width, measured as analyze_fixed_design measures it, here on the solid share).
  double solid_vm = 0.0;
  std::size_t solid_voxels = 0;
  std::vector<double> tension_up(S.ups.size(), 0.0);   // P4: the solid's tension across the layers, per candidate up
  std::vector<double> s_vm, s_width;   // per solid voxel: von Mises, member width (width-aware only)
  std::vector<double> width;           // per voxel: the solid share's member width (width-aware, or for the spots)
  const auto measure_width = [&] {
    if (!width.empty()) return;
    const std::size_t nv = cert_grid.voxel_count();
    std::vector<double> solid_share(nv, 0.0);
    for (std::size_t e = 0; e < nv; ++e) solid_share[e] = in_part[e] ? static_cast<double>(fm.solid[e]) : 0.0;
    width = local_member_thickness_mm(cert_grid, solid_share, printed_iso, knobs.thickness_cap_voxels);
  };
  {
    const std::size_t nv = cert_grid.voxel_count();
    std::vector<std::array<double, 6>> sig(nv, std::array<double, 6>{0.0, 0.0, 0.0, 0.0, 0.0, 0.0});
    if (knockdown.width_aware) measure_width();
    for (std::size_t e = 0; e < nv; ++e) {
      if (!in_part[e] || !(static_cast<double>(fm.solid[e]) >= printed_iso)) continue;
      ++solid_voxels;
      const double vm = e < a.von_mises_field.size() ? a.von_mises_field[e] : 0.0;
      solid_vm = std::max(solid_vm, vm);
      if (knockdown.width_aware) {
        s_vm.push_back(vm);
        s_width.push_back(width[e]);
      }
      if (6 * e + 5 < a.stress_tensor_field.size())
        for (int q = 0; q < 6; ++q) sig[e][static_cast<std::size_t>(q)] = a.stress_tensor_field[6 * e + static_cast<std::size_t>(q)];
    }
    R.solid_tension = solid_voxels ? max_interlayer_tension(cert_grid, sig, build_dir) : 0.0;
    // P4: the same solid with its layers across each candidate up (exact: the solve does not read the up)
    for (std::size_t k = 0; k < S.ups.size(); ++k)
      tension_up[k] = solid_voxels ? max_interlayer_tension(cert_grid, sig, S.ups[k]) : 0.0;
  }
  R.solid_margin = compute_stress_margin(material.yield_strength_mpa, material.z_knockdown, solid_vm, R.solid_tension);
  // The effective margin at an infill percent: Install 3's gate (gate_margin_effective), the job's other print settings.
  // (P4: with the layers' tension given, the same margin for another up.)
  const auto effective_with = [&](double infill, double tension) {
    KnockdownSpec k = knockdown;
    k.infill_percent = infill;
    k.infill_knockdown = infill_margin_knockdown(infill, k.infill_exponent, k.infill_floor);
    double vm_eff = solid_vm;
    if (k.width_aware) {
      vm_eff = 0.0;
      for (std::size_t i = 0; i < s_vm.size(); ++i)
        vm_eff = std::max(vm_eff, s_vm[i] / width_aware_knockdown(infill, s_width[i], k.wall_thickness_mm,
                                                                   k.infill_exponent, k.infill_floor));
    }
    return gate_margin_effective(material.yield_strength_mpa, material.z_knockdown, solid_vm, vm_eff, tension, k);
  };
  const auto effective_at = [&](double infill) { return effective_with(infill, R.solid_tension); };
  R.solid_margin_effective = effective_at(knockdown.infill_percent);
  for (int pc = 1; pc <= 100 && R.passes_at_infill_percent < 0; ++pc)
    if (effective_at(pc) >= options.margin_stop) R.passes_at_infill_percent = pc;
  R.solid_vm = solid_vm;
  R.solid_voxels = solid_voxels;
  // ── Brief E4, item 2: the solid's weak spots. Every voxel the solid verdict judges, with its EFFECTIVE margin exactly
  // as the verdict computes it (gate_margin_effective on the voxel's own von Mises, member width and layer tension: the
  // whole solid's margin is the least of these); the voxels under the safety margin, joined by touching
  // (load_path_connectivity), are the spots.
  const std::size_t nvox = cert_grid.voxel_count();
  std::vector<float> margin_field(nvox, std::numeric_limits<float>::quiet_NaN());
  std::vector<double> margin_of(nvox, std::numeric_limits<double>::quiet_NaN());
  // OS15 (the app's certify wizard): per voxel, the id of the weak spot it belongs to (1.. in the listed order, every
  // spot numbered, the listed ones first; 0: none), fields.bin's third block.
  std::vector<float> spot_id_field(nvox, 0.0f);
  std::string spots_json;
  {
    const double Y = material.yield_strength_mpa, zk = material.z_knockdown, S_ = options.margin_stop;
    const double bl = std::sqrt(build_dir.x * build_dir.x + build_dir.y * build_dir.y + build_dir.z * build_dir.z);
    const Vec3 up{build_dir.x / bl, build_dir.y / bl, build_dir.z / bl};
    const auto spec_at = [&](double infill, bool walls) {
      KnockdownSpec k = knockdown;
      k.width_aware = walls;
      k.infill_percent = infill;
      k.infill_knockdown = infill_margin_knockdown(infill, k.infill_exponent, k.infill_floor);
      return k;
    };
    const auto vm_of = [&](std::size_t e) { return e < a.von_mises_field.size() ? a.von_mises_field[e] : 0.0; };
    const auto tension_of = [&](std::size_t e) {
      if (6 * e + 5 >= a.stress_tensor_field.size()) return 0.0;
      const double* q = &a.stress_tensor_field[6 * e];
      const double t = up.x * up.x * q[0] + up.y * up.y * q[1] + up.z * up.z * q[2] + 2.0 * up.x * up.y * q[3] +
                       2.0 * up.y * up.z * q[4] + 2.0 * up.z * up.x * q[5];
      return t > 0.0 ? t : 0.0;
    };
    // The voxel's effective in-plane and layer terms (their least is its effective margin, as the gate has it).
    const auto terms = [&](std::size_t e, const KnockdownSpec& k) {
      const double vm = vm_of(e), t = tension_of(e);
      if (k.width_aware) {
        const double vme = vm / width_aware_knockdown(k.infill_percent, width[e], k.wall_thickness_mm, k.infill_exponent,
                                                      k.infill_floor);
        return compute_stress_margin(Y, zk, vme, k.infill_knockdown > 0.0 ? t / k.infill_knockdown : t);
      }
      StressMargin m = compute_stress_margin(Y, zk, vm, t);
      m.in_plane *= k.infill_knockdown;
      m.interlayer *= k.infill_knockdown;
      m.worst_case *= k.infill_knockdown;
      return m;
    };
    const auto eff = [&](std::size_t e, const KnockdownSpec& k) {
      const double vm = vm_of(e), t = tension_of(e);
      const double vme = k.width_aware ? vm / width_aware_knockdown(k.infill_percent, width[e], k.wall_thickness_mm,
                                                                    k.infill_exponent, k.infill_floor)
                                       : vm;
      return gate_margin_effective(Y, zk, vm, vme, t, k);
    };
    const KnockdownSpec job_k = spec_at(knockdown.infill_percent, knockdown.width_aware);
    std::vector<std::size_t> judged;
    for (std::size_t e = 0; e < nvox; ++e)
      if (in_part[e] && static_cast<double>(fm.solid[e]) >= printed_iso) judged.push_back(e);
    std::vector<char> under(nvox, 0);
    for (const std::size_t e : judged) {
      const double m = eff(e, job_k);
      margin_of[e] = m;
      margin_field[e] = static_cast<float>(m);
      under[e] = m < S_;
    }
    // The spots: the voxels under, joined by touching.
    std::vector<std::array<int, 3>> nb;
    for (int dk = -1; dk <= 1; ++dk)
      for (int dj = -1; dj <= 1; ++dj)
        for (int di = -1; di <= 1; ++di) {
          const int nz = (di != 0) + (dj != 0) + (dk != 0);
          if (nz == 0 || (connectivity == 6 && nz > 1) || (connectivity == 18 && nz > 2)) continue;
          nb.push_back({di, dj, dk});
        }
    struct Spot { std::vector<std::size_t> v; std::size_t worst = 0; double worst_eff = 0.0; };
    std::vector<Spot> spots;
    std::vector<char> seen(nvox, 0);
    const int nx = cert_grid.nx, ny = cert_grid.ny, nz = cert_grid.nz;
    const auto ijk = [&](std::size_t e) {
      const int i = static_cast<int>(e % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((e / static_cast<std::size_t>(nx)) % static_cast<std::size_t>(ny));
      const int k = static_cast<int>(e / (static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny)));
      return std::array<int, 3>{i, j, k};
    };
    for (const std::size_t e0 : judged) {
      if (!under[e0] || seen[e0]) continue;
      Spot sp;
      std::vector<std::size_t> stack{e0};
      seen[e0] = 1;
      while (!stack.empty()) {
        const std::size_t e = stack.back();
        stack.pop_back();
        sp.v.push_back(e);
        const auto c = ijk(e);
        for (const auto& d : nb) {
          const int i = c[0] + d[0], j = c[1] + d[1], k = c[2] + d[2];
          if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) continue;
          const std::size_t f = cert_grid.index(i, j, k);
          if (under[f] && !seen[f]) {
            seen[f] = 1;
            stack.push_back(f);
          }
        }
      }
      std::sort(sp.v.begin(), sp.v.end());
      sp.worst = sp.v.front();
      sp.worst_eff = margin_of[sp.worst];
      for (const std::size_t e : sp.v)
        if (margin_of[e] < sp.worst_eff) { sp.worst_eff = margin_of[e]; sp.worst = e; }
      spots.push_back(std::move(sp));
    }
    std::sort(spots.begin(), spots.end(), [](const Spot& x, const Spot& y) {
      return x.worst_eff != y.worst_eff ? x.worst_eff < y.worst_eff : x.v.front() < y.v.front();
    });
    for (std::size_t q = 0; q < spots.size(); ++q)
      for (const std::size_t e : spots[q].v) spot_id_field[e] = static_cast<float>(q + 1);
    if (!spots.empty()) {
      measure_width();   // the walls credited (a measure of the grid, no new solve)
      const KnockdownSpec walls_k = spec_at(knockdown.infill_percent, true);
      bool walls_all = true;
      for (const std::size_t e : judged)
        if (eff(e, walls_k) < S_) { walls_all = false; break; }
      const std::size_t shown = std::min<std::size_t>(spots.size(), static_cast<std::size_t>(st.get("solid_spots_max")));
      const double h = cert_grid.spacing, near = st.get("solid_spot_near_voxels") * h;
      // The held and loaded voxels (a corner node held or loaded), and the open lattice's voxels.
      const std::size_t nn = static_cast<std::size_t>(nx + 1) * static_cast<std::size_t>(ny + 1) * static_cast<std::size_t>(nz + 1);
      std::vector<char> held_node(nn, 0), loaded_node(nn, 0);
      for (const DirichletBC& b : domain.bcs)
        if (!b.released && b.node >= 0 && static_cast<std::size_t>(b.node) < nn) held_node[static_cast<std::size_t>(b.node)] = 1;
      for (const NodalLoad& l : loads)
        if (l.value != 0.0 && l.node >= 0 && static_cast<std::size_t>(l.node) < nn) loaded_node[static_cast<std::size_t>(l.node)] = 1;
      std::vector<std::size_t> held_v, loaded_v, lattice_v;
      for (std::size_t e = 0; e < nvox; ++e) {
        if (!in_part[e]) continue;
        const auto c = ijk(e);
        bool hv = false, lv = false;
        for (int q = 0; q < 8; ++q) {
          const std::size_t node = static_cast<std::size_t>(
              fea_node_index(cert_grid, c[0] + (q & 1), c[1] + ((q >> 1) & 1), c[2] + ((q >> 2) & 1)));
          hv = hv || held_node[node];
          lv = lv || loaded_node[node];
        }
        if (hv) held_v.push_back(e);
        if (lv) loaded_v.push_back(e);
        if (fm.lattice[e] > 0.0f) lattice_v.push_back(e);
      }
      const auto centre = [&](std::size_t e) {
        const auto c = ijk(e);
        return cert_grid.voxel_center(c[0], c[1], c[2]);
      };
      const auto nearest = [&](const Vec3& p, const std::vector<std::size_t>& list, std::size_t* which) {
        double best = std::numeric_limits<double>::infinity();
        for (const std::size_t e : list) {
          const Vec3 q = centre(e);
          const double d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z);
          if (d < best) { best = d; if (which) *which = e; }
        }
        return std::sqrt(best);
      };
      const ll::Domain::Probe probe = ldomain.probe();
      // P2: every place in the part's own coordinates (the identity with no print frame)
      const auto v3 = [&](const Vec3& q) {
        const Vec3 p = S.frame.point_to_model(q);
        return "[" + json_num(p.x) + ", " + json_num(p.y) + ", " + json_num(p.z) + "]";
      };
      const auto box3 = [&](Vec3 lo3, Vec3 hi3) {
        S.frame.box_to_model(lo3, hi3);
        return "{\"lo\": [" + json_num(lo3.x) + ", " + json_num(lo3.y) + ", " + json_num(lo3.z) + "], \"hi\": [" +
               json_num(hi3.x) + ", " + json_num(hi3.y) + ", " + json_num(hi3.z) + "]}";
      };
      const auto dist = [](double d) { return std::isfinite(d) ? json_num(d) : std::string("null"); };
      std::string list;
      for (std::size_t q = 0; q < shown; ++q) {
        const Spot& sp = spots[q];
        Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300}, sum{0.0, 0.0, 0.0};
        double raw = std::numeric_limits<double>::infinity();
        bool walls = true;
        for (const std::size_t e : sp.v) {
          const Vec3 c = centre(e);
          sum = {sum.x + c.x, sum.y + c.y, sum.z + c.z};
          lo = {std::min(lo.x, c.x - 0.5 * h), std::min(lo.y, c.y - 0.5 * h), std::min(lo.z, c.z - 0.5 * h)};
          hi = {std::max(hi.x, c.x + 0.5 * h), std::max(hi.y, c.y + 0.5 * h), std::max(hi.z, c.z + 0.5 * h)};
          raw = std::min(raw, compute_stress_margin(Y, zk, vm_of(e), tension_of(e)).worst_case);
          walls = walls && eff(e, walls_k) >= S_;
        }
        const double nvs = static_cast<double>(sp.v.size());
        int pass_at = -1;
        for (int pc = 1; pc <= 100 && pass_at < 0; ++pc) {
          const KnockdownSpec k = spec_at(pc, knockdown.width_aware);
          bool ok = true;
          for (const std::size_t e : sp.v)
            if (eff(e, k) < S_) { ok = false; break; }
          if (ok) pass_at = pc;
        }
        const StressMargin wt = terms(sp.worst, job_k);
        const Vec3 w = centre(sp.worst);
        std::size_t lat_e = 0;
        const double d_held = nearest(w, held_v, nullptr), d_load = nearest(w, loaded_v, nullptr),
                     d_lat = nearest(w, lattice_v, &lat_e);
        std::string region = "null";
        if (std::isfinite(d_lat)) {
          const auto c = ijk(lat_e);
          const Vec3 o{cert_grid.origin.x + c[0] * h, cert_grid.origin.y + c[1] * h, cert_grid.origin.z + c[2] * h};
          for (int s3 = 0; s3 < 27 && region == "null"; ++s3) {
            const int ai = s3 == 0 ? 1 : (s3 % 3), bi = s3 == 0 ? 1 : ((s3 / 3) % 3), ci = s3 == 0 ? 1 : (s3 / 9);
            const ll::Where wh = probe.where({o.x + (ai + 0.5) * h / 3, o.y + (bi + 0.5) * h / 3, o.z + (ci + 0.5) * h / 3});
            if (wh.lattice()) region = std::to_string(wh.id);
          }
        }
        const char* kind = d_held <= near ? "beside_a_fixing"
                           : d_load <= near ? "beside_the_load"
                           : d_lat <= near ? "beside_the_lattice"
                                           : "inside_the_solid";
        const std::string k(kind);
        const char* advice = k == "beside_a_fixing" ? "Keep more solid around this fixing."
                             : k == "beside_the_load" ? "Keep more solid where the load presses here."
                             : k == "beside_the_lattice"
                                 ? "Keep the lattice further from this area: a deeper protected skin, or a keep-clear area."
                                 : "Make this part of the model thicker, or print it denser.";
        list += std::string(q ? "," : "") + "\n      {\"id\": " + std::to_string(q + 1) + ", \"issue\": " + json_str(k) +
                ", \"worst_at\": " + v3(w) + ", \"centroid\": " +
                v3({sum.x / nvs, sum.y / nvs, sum.z / nvs}) + ", \"box\": " + box3(lo, hi) +
                ", \"voxels\": " + std::to_string(sp.v.size()) + ", \"mm3\": " + json_num(nvs * h * h * h) +
                ", \"raw_margin\": " + json_num(raw) + ", \"effective_margin\": " + json_num(sp.worst_eff) +
                ", \"governs\": " + json_str(wt.in_plane <= wt.interlayer ? "in_plane" : "interlayer") +
                ", \"passes_at_infill_percent\": " + (pass_at < 0 ? std::string("null") : std::to_string(pass_at)) +
                ", \"passes_with_walls_credited\": " + (walls ? "true" : "false") +
                ",\n       \"to_held_mm\": " + dist(d_held) + ", \"to_load_mm\": " + dist(d_load) +
                ", \"to_lattice_mm\": " + dist(d_lat) + ", \"lattice_region\": " + region + ", \"kind\": " + json_str(k) +
                ", \"advice\": " + json_str(advice) + "}";
      }
      spots_json = ", \"spots_total\": " + std::to_string(spots.size()) + ", \"spots\": [" + list + "\n    ], \"text\": " +
                   json_str(organic_solid_text(knockdown.infill_percent, R.passes_at_infill_percent,
                                               !knockdown.width_aware && walls_all, shown, spots.size()));
    }
  }
  // ── the verdict (V5's three states).
  if (c.load_on_open_lattice) {
    R.verdict = "fail";
    R.fail_reason = "load_on_open_lattice";
  } else if (c.no_load_path) {   // OS9 amended: the load handed no one (unheld, or only near adrift parts) over the share
    R.verdict = "fail";
    R.fail_reason = "no_load_path";
  } else if (c.load_on_bare_lattice) {   // the interim guard (2026-11-26): the vines would carry the load
    R.verdict = "fail";
    R.fail_reason = "load_on_bare_lattice";
  } else if (R.solid_margin_effective < options.margin_stop) {
    R.verdict = "fail";
    R.fail_reason = "solid_margin";
  } else if (a.contact_held_by_sliding) {
    R.verdict = "fail";
  } else if (!c.solved) {
    R.verdict = "solid_only";
    R.fail_reason = "frame_not_solved";
  } else if (c.under_safety > 0) {
    R.verdict = "fail";
    R.fail_reason = "strut_margin";
  } else if (c.too_unjudged) {
    R.verdict = "solid_only";
    R.fail_reason = "frame_unjudged";
  } else {
    R.verdict = "pass";
  }
  ll::StrengthDone& done = R.done;
  // ── the files: fields.bin (the voxel solve's), strut_margins.bin (one float32 per bar, the layout's order).
  {
    MinimizePlasticResult fr;
    fr.report.material = job.material;
    MinimizePlasticVariant fv;
    fv.requested_volume_fraction = 1.0;
    fv.accepted = a.accepted;
    fv.von_mises_field = a.von_mises_field;
    fv.stress_tensor_field = a.stress_tensor_field;
    fv.displacement_field = a.displacement_field;
    fv.mass_grams = a.mass_grams;
    fv.support_volume_voxels = a.support_volume_voxels;
    fr.evaluated.push_back(std::move(fv));
    write_fields_file(join_path(out_dir, "fields.bin"), fr, cert_grid, /*accepted_only=*/false);
    append_fields_block(join_path(out_dir, "fields.bin"), cert_grid, -1.0, margin_field);   // brief E4: the solid's margin
    append_fields_block(join_path(out_dir, "fields.bin"), cert_grid, -2.0, spot_id_field);  // OS15: the spots' ids
    if (std::string why; S.frame.on && !(g_print_frame_test_skip & kSkipReportBack) &&
                         !turn_fields_file_to_model(S.frame, join_path(out_dir, "fields.bin"), &why)) {   // P2
      R.done = strength_no("strength_failed", 1, "The lattice's strength could not be checked, so no file was made.",
                           "fields.bin could not be turned back to the part's frame: " + why);
      return R;
    }
    done.files.push_back("fields.bin");
    std::vector<float> m(layout_bars.bars.size(), std::numeric_limits<float>::quiet_NaN());
    for (std::size_t i = 0; i < R.bar_of.size() && i < c.bar_margin.size(); ++i)
      m[static_cast<std::size_t>(R.bar_of[i])] = c.bar_margin[i];
    std::ofstream f(join_path(out_dir, "strut_margins.bin"), std::ios::binary);
    f.write(reinterpret_cast<const char*>(m.data()), static_cast<std::streamsize>(m.size() * sizeof(float)));
    if (!f) {
      R.done = strength_no("strength_failed", 1, "The lattice's strength could not be checked, so no file was made.",
                           "cannot write strut_margins.bin");
      return R;
    }
    done.files.push_back("strut_margins.bin");
    // K4 (his Results notes, 2026-11-24: the stress colours on the WHOLE model): bars.bin, every bar of strut_margins.bin
    // in the same order, so the app can draw each one coloured by its margin. "TOBARS1\0" (8 bytes), uint32 count N,
    // uint32 F, then N records of 7 float32: ax ay az bx by bz width_mm, in the part's own (model) frame.
    // notes27 (builder F's extension, the struts the strengthening changed): when the lattice was strengthened (a bar
    // the additions widened or a brace they laid), F = 1 and N bytes follow the records, one per bar in the same order:
    // bit 0 thickened by the strengthening, bit 1 a brace it added. Otherwise F = 0 and nothing follows (as before).
    std::vector<float> rec;
    rec.reserve(layout_bars.bars.size() * 7);
    for (const ll::Bar& b : layout_bars.bars) {
      const Vec3 a = S.frame.point_to_model(b.a), e = S.frame.point_to_model(b.b);   // P2
      for (const double v : {a.x, a.y, a.z, e.x, e.y, e.z, b.width}) rec.push_back(static_cast<float>(v));
    }
    std::vector<char> flags(layout_bars.bars.size(), 0);
    bool strengthened = false;
    for (std::size_t i = 0; i < layout_bars.bars.size(); ++i) {
      flags[i] = static_cast<char>(layout_bars.bars[i].strengthened & (ll::Bar::kStrengthenedThicker | ll::Bar::kStrengthenedBrace));
      strengthened = strengthened || flags[i] != 0;
    }
    std::ofstream bf(join_path(out_dir, "bars.bin"), std::ios::binary);
    const char magic[8] = {'T', 'O', 'B', 'A', 'R', 'S', '1', '\0'};
    const std::uint32_t head[2] = {static_cast<std::uint32_t>(layout_bars.bars.size()), strengthened ? 1u : 0u};
    bf.write(magic, 8);
    bf.write(reinterpret_cast<const char*>(head), sizeof head);
    bf.write(reinterpret_cast<const char*>(rec.data()), static_cast<std::streamsize>(rec.size() * sizeof(float)));
    if (strengthened) bf.write(flags.data(), static_cast<std::streamsize>(flags.size()));
    if (!bf) {
      R.done = strength_no("strength_failed", 1, "The lattice's strength could not be checked, so no file was made.",
                           "cannot write bars.bin");
      return R;
    }
    done.files.push_back("bars.bin");
  }
  // ── the block: Install 3's keys, and the frame's.
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const bool struts_pass = c.solved && c.under_safety == 0 && !c.too_unjudged && !c.load_on_open_lattice;
  const auto num = [](double x) { return json_num(x); };
  const auto smallest = c.judged ? c.smallest_margin : nan;
  std::string s = "{\n";
  s += "    \"accepted\": " + std::string(R.verdict != "fail" ? "true" : "false") + ",\n";
  s += "    \"struts_pass\": " + std::string(struts_pass ? "true" : "false") + ",\n";
  s += "    \"verdict\": \"" + R.verdict + "\",\n";
  if (!R.fail_reason.empty()) {
    s += "    \"fail_reason\": \"" + R.fail_reason + "\",\n";
    if (R.fail_reason == "load_on_open_lattice")
      s += "    \"load_on_no_credit_n\": " + num(c.load_unheld_n) + ",\n    \"load_total_n\": " + num(c.load_total_n) + ",\n";
    if (R.fail_reason == "frame_not_solved") s += "    \"fail_detail\": " + json_str(c.why_not) + ",\n";
    if (R.fail_reason == "load_on_bare_lattice") {
      const Vec3 at = S.frame.point_to_model(c.load_on_lattice_at);   // P2: the part's own coordinates
      s += "    \"load_on_frame_n\": " + num(c.load_on_frame_n) + ",\n    \"load_total_n\": " + num(c.load_total_n) +
           ",\n    \"load_share\": " + num(c.load_share) + ",\n    \"load_on_lattice_at\": [" + num(at.x) + ", " +
           num(at.y) + ", " + num(at.z) + "],\n    \"fail_text\": " + json_str(kLoadOnBareLatticeText) + ",\n";
      // The depth of solid (a Solid finish or a protected skin) under the loaded face that clears the guard and the open
      // lattice test together: 1.5 of the check's voxels, measured (organic_bare_lattice_depth, 2026-11-26: on a 24 mm
      // coupon at resolution 40 the guard cleared at 1 voxel, the open-lattice test at 1.5, with the switch off and on).
      s += "    \"solid_depth_needed_mm\": " + num(kSolidDepthNeededVoxels * cert_grid.spacing) + ",\n";
    }
  }
  s += "    \"solid_margin\": {\"worst_case\": " + num(R.solid_margin.worst_case) + ", \"in_plane\": " + num(R.solid_margin.in_plane) +
       ", \"interlayer\": " + num(R.solid_margin.interlayer) + ", \"effective\": " + num(R.solid_margin_effective) +
       ", \"von_mises_mpa\": " + num(R.solid_vm) + ", \"interlayer_tension_mpa\": " + num(R.solid_tension) +
       ", \"voxels\": " + std::to_string(R.solid_voxels) + ", \"passes_at_infill_percent\": " +
       (R.passes_at_infill_percent < 0 ? std::string("null") : std::to_string(R.passes_at_infill_percent)) +
       ", \"voxel_load_path\": " + std::string(load_path_ok ? "true" : "false") +
       ", \"field\": {\"file\": \"fields.bin\", \"block\": 2, \"requested_volume_fraction\": -1, \"spot_ids\": "
       "{\"block\": 3, \"requested_volume_fraction\": -2}}" + spots_json + "},\n";
  s += "    \"margin_worst_case\": " + num(a.margin.worst_case) + ",\n";
  s += "    \"margin_in_plane\": " + num(a.margin.in_plane) + ",\n";
  s += "    \"margin_interlayer\": " + num(a.margin.interlayer) + ",\n";
  s += "    \"safety_margin\": " + num(options.margin_stop) + ",\n";
  s += "    \"not_certified\": false,\n    \"not_certified_reason\": \"\",\n";
  s += "    \"mass_grams\": " + num(a.mass_grams) + ",\n";
  s += "    \"max_effective_von_mises_mpa\": " + num(a.max_von_mises) + ",\n";
  s += "    \"max_interlayer_tension_mpa\": " + num(a.max_interlayer_tension) + ",\n";
  s += "    \"cells_credited\": 0,\n    \"cells_no_credit\": 0,\n";
  s += "    \"voxel_mm\": " + num(cert_grid.spacing) + ",\n";
  // P2: places and directions in the part's own coordinates (the identity with no print frame).
  const auto P = [&](const Vec3& q) { return S.frame.point_to_model(q); };
  const auto D = [&](const Vec3& q) { return S.frame.dir_to_model(q); };
  const Vec3 build_dir_m = D(build_dir);
  s += "    \"build_direction\": {\"x\": " + num(build_dir_m.x) + ", \"y\": " + num(build_dir_m.y) + ", \"z\": " + num(build_dir_m.z) + "},\n";
  s += "    \"resolve_reproduces\": null, \"resolve_margin_solid\": null, \"resolve_margin_again\": null,\n";
  s += "    \"strut\": {\"law\": \"frame of beams\", \"uncertified\": false, \"gated\": true, \"margin_in_plane\": null, "
       "\"margin_interlayer\": null, \"margin_worst_case\": " + num(smallest) + ", \"out_of_regime\": false, \"regime_note\": \"\"},\n";
  s += "    \"fields\": \"fields.bin\",\n";
  s += "    \"strut_margins\": \"strut_margins.bin\",\n";
  s += "    \"bars\": \"bars.bin\",\n";   // K4: the bars of strut_margins.bin, same order, model frame
  s += "    \"struts\": {\"judged\": " + std::to_string(c.judged) + ", \"under_safety\": " + std::to_string(c.under_safety) +
       ", \"under_one\": " + std::to_string(c.under_one) + ", \"smallest_margin\": " + num(smallest) +
       ", \"buckling_failures\": " + std::to_string(c.buckling_failures) + ", \"stubs\": " + std::to_string(c.stubs) +
       ", \"unjudged_mm\": " + num(c.unjudged_mm) + ", \"load_unheld_n\": " + num(c.load_unheld_n) + "},\n";
  s += "    \"weakest\": [";
  for (std::size_t w = 0; w < c.weakest.size(); ++w) {
    const ll::FrameStrut& x = c.struts[static_cast<std::size_t>(c.weakest[w])];
    const Vec3 xat = P(x.at);
    s += std::string(w ? ",\n      " : "\n      ") + "{\"at\": [" + num(xat.x) + ", " + num(xat.y) + ", " + num(xat.z) +
         "], \"width_mm\": " + num(x.width_max) + ", \"length_mm\": " + num(x.length_mm) + ", \"margin\": " + num(x.margin) +
         ", \"by\": \"" + x.by + "\", \"axial_n\": " + num(x.axial_n) + ", \"moment_nmm\": " + num(x.moment_nmm) + ", \"ends\": [";
    for (int e = 0; e < 2; ++e) {
      if (x.end_node[e] < 0) continue;
      const Vec3 Pe = P(R.frame.nodes[static_cast<std::size_t>(x.end_node[e])]);
      const Vec3 ue = D(x.end_u[e]), re = P(x.end_read[e]);
      s += std::string(e ? ", " : "") + "{\"at\": [" + num(Pe.x) + ", " + num(Pe.y) + ", " + num(Pe.z) + "], \"kind\": \"" +
           (x.end_kind[e] == 'd' ? "driven" : x.end_kind[e] == 'j' ? "joint" : x.end_kind[e] == 'f' ? "free" : "pass") +
           "\", \"floor\": " + (x.end_floor[e] ? "true" : "false") + ", \"u\": [" + num(ue.x) + ", " +
           num(ue.y) + ", " + num(ue.z) + "]" +
           (x.end_kind[e] == 'd' ? ", \"read_at\": [" + num(re.x) + ", " + num(re.y) + ", " + num(re.z) + "]"
                                 : std::string()) + "}";
    }
    s += "]}";
  }
  s += c.weakest.empty() ? "],\n" : "\n    ],\n";
  s += "    \"frame\": {\"bars\": " + std::to_string(R.frame.bars) + ", \"nodes\": " + std::to_string(c.nodes_used) +
       ", \"pieces\": " + std::to_string(R.frame.pieces.size()) + ", \"links\": " + std::to_string(R.frame.links) +
       ", \"t_joins\": " + std::to_string(R.frame.t_joins) + ", \"zero_pieces\": " + std::to_string(R.frame.zero_pieces) +
       ", \"driven\": " + std::to_string(c.driven) + ", \"frame_parts\": " + std::to_string(c.pieces_of_frame) +
       ", \"undriven_parts\": " + std::to_string(c.undriven_pieces) + ", \"rotations_held\": " + std::to_string(c.rotations_held) +
       ", \"drive_voxels_median\": " + num(c.drive_voxels_median) + ", \"drive_fallback\": " + std::to_string(c.drive_fallback) +
       ", \"drive_normal\": " + std::to_string(c.drive_normal) + ", \"drive_trilinear\": " + std::to_string(c.drive_trilinear) + ", \"drive_grown\": " + std::to_string(c.drive_grown) +
       ", \"drive_grown_reach_voxels\": " + num(c.drive_grown_reach_voxels) + ", \"drive_no_material\": " +
       std::to_string(c.drive_no_material) + ", \"drive_no_material_at\": [" + [&] {
         std::string t;
         for (const Vec3& q : c.drive_no_material_at) {
           const Vec3 p = P(q);
           t += std::string(t.empty() ? "" : ", ") + "[" + num(p.x) + ", " + num(p.y) + ", " + num(p.z) + "]";
         }
         return t;
       }() + "]" +
       ", \"load_total_n\": " + num(c.load_total_n) + ", \"load_share\": " + num(c.load_share) + ", \"load_on_frame_n\": " + num(c.load_on_frame_n) +
       ", \"frame_nodes_loaded\": " + std::to_string(c.frame_nodes_loaded) +
       ", \"loaded_nodes_undriven\": " + std::to_string(c.loaded_nodes_undriven) +
       ", \"load_on_adrift_n\": " + num(c.load_on_adrift_n) + ", \"adrift_total\": " + std::to_string(c.adrift_total) +
       ", \"adrift_parts\": [" + [&] {
         std::string t;
         for (const ll::FrameCheck::Adrift& d : c.adrift)
           t += std::string(t.empty() ? "" : ", ") + "{\"centre\": [" + num(P(d.centre).x) + ", " + num(P(d.centre).y) + ", " + num(P(d.centre).z) +
                "], \"bars\": " + std::to_string(d.bars) + ", \"length_mm\": " + num(d.length_mm) + ", \"loaded_nodes\": " +
                std::to_string(d.loaded_nodes) + ", \"load_n\": " + num(d.load_n) + "}";
         return t;
       }() + "]" + ", \"strut_mm\": " + num(c.strut_mm) +
       ", \"solved\": " + std::string(c.solved ? "true" : "false") + ", \"dofs\": " + std::to_string(c.dofs) +
       ", \"solver\": " + json_str(c.solver) + ", \"factor_gb\": " + num(c.factor_gb) + ", \"residual\": " + num(c.residual) + "},\n";
  s += "    \"material\": {\"lattice_mm3\": " + num(fm.lattice_mm3) + ", \"lattice_outside_solid_mm3\": " + num(fm.lattice_open_mm3) +
       ", \"solid_mm3\": " + num(fm.solid_mm3) + "},\n";
  s += "    \"times_ms\": {\"material\": " + num(std::round(R.ms_material)) + ", \"voxel_solve\": " + num(std::round(R.ms_voxel)) +
       ", \"frame\": " + num(std::round(R.ms_frame)) + ", \"frame_assemble\": " + num(std::round(c.ms_assemble)) +
       ", \"frame_solve\": " + num(std::round(c.ms_solve)) + "},\n";
  s += "    \"memory_mb\": {\"after_voxel_solve\": " + num(std::round(R.mb_voxel)) + ", \"after_frame\": " + num(std::round(R.mb_frame)) +
       ", \"peak\": " + num(std::round(process_memory().peak_rss_mb)) + "},\n";
  {
    std::string t = "{";
    bool first = true;
    const auto add = [&](const char* key, const std::string& value) {
      t += std::string(first ? "\n      \"" : ",\n      \"") + key + "\": " + value;
      first = false;
    };
    add("safety_margin", num(options.margin_stop));
    add("material", json_str(job.material));
    add("resolution", std::to_string(job.resolution));
    add("build_direction", "[" + num(build_dir_m.x) + ", " + num(build_dir_m.y) + ", " + num(build_dir_m.z) + "]");
    add("anchor_model", json_str(has_contact_springs(domain.bcs) ? "bearing" : "glued"));
    add("gravity_mm_s2", job.loads.present ? std::string("null") : num(job.gravity.magnitude_mm_s2));
    add("yield_strength_mpa", num(material.yield_strength_mpa));
    add("youngs_modulus_mpa", num(material.youngs_modulus_mpa));
    add("poisson", num(material.poisson));
    add("z_knockdown", num(material.z_knockdown));
    for (const StrengthSettingSpec& sp : strength_setting_specs())
      if (sp.kind != StrengthSettingSpec::Kind::PerMaterial) add(sp.key.c_str(), num(st.get(sp.key)));
    add("voxel_mm", num(cert_grid.spacing));
    add("penalty", num(params.penalty));
    s += "    \"settings\": " + t + "\n    },\n";
  }
  {
    std::string ri = run_info_json(build_run_info(job, options, build_identity()));
    while (!ri.empty() && (ri.back() == '\n' || ri.back() == ' ')) ri.pop_back();
    std::string nested;
    for (const char ch : ri) {
      nested += ch;
      if (ch == '\n') nested += "    ";
    }
    s += "    \"run_info\": " + nested + ",\n";
  }
  const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t_start).count();
  s += "    \"ms\": " + num(std::round(ms * 10.0) / 10.0) + "\n  }";
  done.ok = true;
  done.json = std::move(s);
  done.accepted = R.verdict != "fail";
  // P4: per candidate up (print_orientation.hpp): the solid's margin with its layers across it (exact), the struts'
  // smallest (the same struts and forces, the limit by their rise: an estimate), the part's own support (voxels); and
  // the centre of mass (the solid's and the lattice's material).
  if (!S.ups.empty()) {
    OrientationStrengthsN& os = done.orientation;
    os.known = true;
    os.required_margin = options.margin_stop;
    std::vector<char> solid_mask(nvox, 0);
    double mass = 0.0;
    Vec3 com{0.0, 0.0, 0.0};
    for (int k = 0; k < cert_grid.nz; ++k)
      for (int j = 0; j < cert_grid.ny; ++j)
        for (int i = 0; i < cert_grid.nx; ++i) {
          const std::size_t e = cert_grid.index(i, j, k);
          if (!in_part[e]) continue;
          solid_mask[e] = static_cast<double>(fm.solid[e]) >= printed_iso;
          const double w = density[e];
          const Vec3 vc = cert_grid.voxel_center(i, j, k);
          mass += w;
          com = {com.x + w * vc.x, com.y + w * vc.y, com.z + w * vc.z};
        }
    if (mass > 0.0) {
      os.centre_of_mass = {com.x / mass, com.y / mass, com.z / mass};
      os.has_centre_of_mass = true;
    }
    const double nan = std::numeric_limits<double>::quiet_NaN();
    os.by_up.assign(S.ups.size(), OrientationStrength{});
    for (std::size_t q = 0; q < S.ups.size(); ++q) {
      OrientationStrength& t = os.by_up[q];
      t.solid = effective_with(knockdown.infill_percent, tension_up[q]);
      t.solid_interlayer = compute_stress_margin(material.yield_strength_mpa, material.z_knockdown, solid_vm, tension_up[q]).interlayer;
      const bool struts_known = c.solved && c.judged > 0 && q < c.by_up.size();
      t.struts = struts_known ? c.by_up[q].smallest_margin : nan;
      t.struts_under = struts_known ? c.by_up[q].under_safety : 0;
      t.support_mm3 = support_along(cert_grid, in_part, solid_mask, S.ups[q]);
    }
  }
  (void)in_part;
  return R;
}

// ── C2, Organic strength CUT 1: the break check (lattice_layout_break.hpp) on the file as written, after the rod check.
// The rod check's block is left exactly as it was; the break check ADDS "break" and "answer": "break" (the file's
// verdict is the break check's: accepted only on "pass"). A check that cannot be made says "not_checked" with the
// reason, and the file is KEPT (never the strength_failed path, which deletes it).
namespace break_c2 {

std::uint64_t fnv(std::uint64_t h, const void* p, std::size_t n) {
  const unsigned char* b = static_cast<const unsigned char*>(p);
  for (std::size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ull; }
  return h;
}
std::string g17(double v) {
  char b[40];
  std::snprintf(b, sizeof b, "%.17g", v);
  return b;
}
std::string g17v(const Vec3& v) { return g17(v.x) + "," + g17(v.y) + "," + g17(v.z); }

std::string not_checked_block(const std::string& code, const std::string& why, double pass_line) {
  return "{\"verdict\": \"not_checked\", \"reason\": " + json_str(code) + ", \"why\": " + json_str(why) + ", \"pass_line\": " +
         json_num(pass_line) + "}";
}

// Adds the break block and the answer key to the rod check's block (an object ending "\n  }").
void add_break(ll::StrengthDone& done, const std::string& block) {
  std::string& s = done.json;
  std::size_t q = s.rfind("\n  }");
  if (q == std::string::npos) q = s.rfind('}');
  if (q == std::string::npos) return;
  s.insert(q, ",\n    \"answer\": \"break\",\n    \"break\": " + block);
}

}  // namespace break_c2

ll::StrengthDone with_break_check(const ll::StrengthAsk& ask, StrengthSetup& S, ll::StrengthDone done) {
  using namespace break_c2;
  JobDescription& job = S.job;
  const double pass_line = S.options.margin_stop;
  const auto refuse = [&](const std::string& code, const std::string& why) {
    add_break(done, not_checked_block(code, why, pass_line));
    done.accepted = false;
    done.break_verdict = "not_checked";
    done.break_reason = code;
    return done;
  };
  // the job's hold and loads, as face ids of the strength job's part (the same frame as the file)
  ll::BreakAsk b;
  try {
    if (!job.loads.present) return refuse("no_load", "the strength job states no load case (anchors and forces)");
    if (!job.loads.anchor_region_ids.empty() || !job.loads.face_regions.empty())
      return refuse("no_load", "the strength job names face regions, which the break check does not read yet");
    for (const int f : resolve_selectors(S.model, job.loads.anchors, "anchors")) b.fixed_faces.push_back(f);
    for (const int f : job.loads.anchor_face_ids) b.fixed_faces.push_back(f);
    for (const JobLoadGroup& g : job.loads.groups) {
      if (!g.region_ids.empty()) return refuse("no_load", "a load names face regions, which the break check does not read yet");
      ll::BreakLoad L;
      for (const int f : resolve_selectors(S.model, g.faces, "loads")) L.faces.push_back(f);
      for (const int f : g.face_ids) L.faces.push_back(f);
      L.force = g.force;
      b.loads.push_back(L);
    }
  } catch (const std::exception& e) {
    return refuse("no_load", std::string("the strength job's faces could not be read: ") + e.what());
  }
  b.print = ask.print;
  b.part = &S.model;
  if (ask.bars)
    for (std::size_t i = 0; i < ask.bars->bars.size(); ++i)
      if (!ask.kept || (i < ask.kept->size() && (*ask.kept)[i]))
        b.bars.push_back({ask.bars->bars[i].a, ask.bars->bars[i].b, ask.bars->bars[i].width});
  if (ask.made)
    for (const ll::MeshSpec::Post& p : ask.made->posts) {
      // C3: the box the post was drawn as (post_mm at its axis, or the posts step's width and inward move)
      ll::MeshSpec spec;
      spec.post_mm = ask.post_mm;
      spec.post_wide = ask.post_wide;
      double w = 0.0, cx = 0.0, cy = 0.0;
      spec.post_box(p, w, cx, cy);
      b.posts.push_back({cx, cy, p.z_bottom, p.z_top, w});
    }
  b.youngs_mpa = S.material.youngs_modulus_mpa;
  b.poisson = S.material.poisson;
  b.yield_mpa = S.material.yield_strength_mpa;
  b.z_knockdown = S.material.z_knockdown;
  b.up = resolve_build_direction(S.options);
  b.pass_line = pass_line;
  b.frame = S.frame;
  b.other_ups = S.ups;
  b.memory_limit_bytes = ask.break_memory_limit_bytes;
  b.said = ask.said;
  b.stop = ask.stop;
  // the cache key: the file's bytes, the part, the hold and loads, the bars and posts, the material, the pass line, the
  // grid and the frame; the whole key text is kept in the entry and compared, so a changed input never reuses it
  std::string key;
  {
    std::uint64_t hf = 1469598103934665603ull;
    std::size_t nbytes = 0;
    bool read_ok = false;
    if (std::FILE* f = std::fopen(ask.print_path.c_str(), "rb")) {
      char buf[65536];
      std::size_t n;
      while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) { hf = fnv(hf, buf, n); nbytes += n; }
      read_ok = !std::ferror(f);
      std::fclose(f);
    }
    if (read_ok) {
      std::uint64_t hp = 1469598103934665603ull;
      for (const Vec3& v : S.model.mesh.vertices) hp = fnv(hp, &v, sizeof v);
      for (const auto& t : S.model.mesh.triangles) hp = fnv(hp, t.data(), sizeof(int) * 3);
      for (const int f : S.model.triangle_face) hp = fnv(hp, &f, sizeof f);
      std::uint64_t hb = 1469598103934665603ull;
      for (const ll::BreakBar& x : b.bars) hb = fnv(fnv(fnv(hb, &x.a, sizeof x.a), &x.b, sizeof x.b), &x.width, sizeof x.width);
      for (const ll::BreakPost& x : b.posts) hb = fnv(hb, &x, sizeof x);
      char h[200];
      std::snprintf(h, sizeof h, "file %016llx %zu\npart %016llx\nbars %016llx\n", static_cast<unsigned long long>(hf), nbytes,
                    static_cast<unsigned long long>(hp), static_cast<unsigned long long>(hb));
      // review C2 A4: the build's own fingerprint, not a hand-typed word (a changed law is a changed build)
      key = "break-check build " + build_identity().fingerprint + " " + build_identity().build_time + " " + __DATE__ + " " + __TIME__ + "\n" + h;
      key += "fixed";
      for (const int f : b.fixed_faces) key += " " + std::to_string(f);
      key += "\nloads";
      for (const ll::BreakLoad& L : b.loads) {
        key += " [";
        for (const int f : L.faces) key += std::to_string(f) + " ";
        key += "| " + g17v(L.force) + "]";
      }
      key += "\nmaterial " + g17(b.youngs_mpa) + " " + g17(b.poisson) + " " + g17(b.yield_mpa) + " " + g17(b.z_knockdown) + "\npass " +
             g17(b.pass_line) + "\nup " + g17v(b.up) + "\ngrid " + g17(b.voxel_mm) + " " + g17v(b.grid_shift) + " " + g17(b.smooth_mm) + " " +
             std::to_string(b.min_voxels_across) + " " + g17(b.near_post_mm) + " " + g17(b.tolerance) + " " + std::to_string(b.max_rounds) +
             " " + std::to_string(b.places_listed) + "\nframe " + (b.frame.on ? "on" : "off");
      for (double r : b.frame.R) key += " " + g17(r);
      key += " " + g17v(b.frame.t) + "\nups";
      for (const Vec3& u : b.other_ups) key += " " + g17v(u);
      key += "\n";
    }
  }
  const std::string entry = key.empty() || ask.break_cache.empty()
                                ? std::string()
                                : ask.break_cache + "/" + [&] {
                                    char n[40];
                                    std::snprintf(n, sizeof n, "%016llx.json", static_cast<unsigned long long>(fnv(1469598103934665603ull, key.data(), key.size())));
                                    return std::string(n);
                                  }();
  if (!entry.empty()) {   // a kept answer: the key text, then the verdict line, then the block; any fault: made again
    std::ifstream f(entry, std::ios::binary);
    ll::StrengthDone kept = done;
    bool reused = false;
    if (f) try {
      std::stringstream ss;
      ss << f.rdbuf();
      const std::string t = ss.str();
      if (t.size() > key.size() && t.compare(0, key.size(), key) == 0) {
        const std::size_t nl = t.find('\n', key.size());
        if (nl != std::string::npos) {
          const std::string verdict = t.substr(key.size(), nl - key.size());
          const std::size_t nl2 = t.find('\n', nl + 1);
          if (nl2 != std::string::npos) {
            bool good = true;
            {   // C3: the post readings line: "posts N" then six numbers per post
              std::istringstream in(t.substr(nl + 1, nl2 - nl - 1));
              std::string word;
              std::size_t n = 0;
              in >> word >> n;
              good = in && word == "posts" && n == b.posts.size();
              for (std::size_t q = 0; good && q < n; ++q) {
                ll::BreakPostReading pr;
                int res = 0, fb = 0;
                in >> pr.all >> res >> pr.judged >> pr.section >> pr.section_mm2 >> fb;
                good = !in.fail();
                pr.all_resolved = res != 0;
                pr.first_break = fb != 0;
                kept.break_posts.push_back(pr);
              }
            }
            std::string block = t.substr(nl2 + 1);
            // review C2 A3: the stored block must parse and carry the same verdict, else it is not used
            if (good) {
              const sjson::Value doc = sjson::parse(block, "break cache");
              const sjson::Value* v = sjson::find(doc, "verdict");
              good = v && sjson::as_string(*v, "break cache.verdict") == verdict;
            }
            if (good) {
              kept.break_verdict = verdict;
              kept.break_pass_line = pass_line;
              if (ask.said) ask.said("checking its strength: the same file was checked before");
              block.insert(1, "\"cache\": \"reused\", ");
              add_break(kept, block);
              kept.accepted = verdict == "pass";
              reused = true;
            }
          }
        }
      }
    } catch (const std::exception&) {
      reused = false;   // a faulty entry: made again
    }
    if (reused) return kept;
  }
  // C3 (a): the solver's thread count is a process-wide setting (fea_set_matfree_threads), which
  // configure_production_options sets to the machine's count; the break check honours the job's --threads while it
  // runs and puts the setting back after (the answer is bit-identical for any count, fea.hpp).
  struct ThreadsFor {
    int prev = -1;
    explicit ThreadsFor(int n) { if (n > 0) prev = fea_set_matfree_threads(n); }
    ~ThreadsFor() { if (prev >= 0) fea_set_matfree_threads(prev); }
  };
  const ll::BreakResult r = [&] {
    const ThreadsFor threads_for(ask.threads);
    return ll::organic_break_check(b);
  }();
  done.break_reason = r.not_checked;
  // C3: the posts' readings for the posts step (class "post", in the order of the file's posts)
  done.break_verdict = r.verdict;
  done.break_pass_line = pass_line;
  done.break_posts.assign(b.posts.size(), ll::BreakPostReading{});
  for (const ll::BreakClass& c : r.classes) {
    if (c.cls != "post" || c.post < 0 || static_cast<std::size_t>(c.post) >= b.posts.size()) continue;
    ll::BreakPostReading& pr = done.break_posts[static_cast<std::size_t>(c.post)];
    if (c.all.found) { pr.all = c.all.multiple; pr.all_resolved = c.all.resolved; }
    if (c.resolved.found) pr.judged = c.resolved.multiple;
    pr.section = c.section_multiple;
    pr.section_mm2 = c.section_mm2;
    pr.first_break = r.first_resolved.found && r.first_resolved.cls == "post" && r.first_resolved.post == c.post;
  }
  std::string block = r.json;
  block.insert(1, "\"cache\": \"made\", ");
  add_break(done, block);
  done.accepted = r.ok && r.verdict == "pass";
  if (r.ok && !entry.empty()) {   // only a made reading is kept (never a "not checked")
    std::error_code ec;
    std::filesystem::create_directories(ask.break_cache, ec);
    // review C2 A3: a temporary name of this process's own; the write checked before the rename
    const std::string tmp = entry + "." + std::to_string(static_cast<long long>(getpid())) + ".part";
    bool written = false;
    {
      std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
      f << key << r.verdict << "\nposts " << done.break_posts.size();
      for (const ll::BreakPostReading& pr : done.break_posts)
        f << " " << g17(pr.all) << " " << (pr.all_resolved ? 1 : 0) << " " << g17(pr.judged) << " " << g17(pr.section) << " " << g17(pr.section_mm2)
          << " " << (pr.first_break ? 1 : 0);
      f << "\n" << r.json;
      f.close();
      written = !f.fail();
    }
    if (written) std::filesystem::rename(tmp, entry, ec);
    if (!written || ec) std::filesystem::remove(tmp, ec);
  }
  return done;
}

ll::StrengthDone run_lattice_file_strength_organic(const ll::StrengthAsk& ask, const std::string& materials_path,
                                                   const std::string& rules_path) {
  if (!ask.bars || !ask.session || !ask.session->domain())
    return strength_no("strength_failed", 1, "The lattice's strength could not be checked, so no file was made.",
                       "the Organic check was asked with no bars");
  StrengthSetup S;
  if (ll::StrengthDone bad = strength_setup(ask, materials_path, rules_path, S); !bad.ok) return bad;
  const OrganicCheckRun cr = organic_frame_check(S, *ask.session->domain(), *ask.bars, ask.kept, ask.light_width_mm, ask.out_dir,
                                                 ask.threads);
  ll::StrengthDone done = cr.done;
  // review C2 A1: the file's answer, for lattice_file.json's "strength_answer" (the rod's when no break check is made)
  done.answer_by = "rod";
  done.answer_verdict = cr.verdict;
  // C2: the break check, on the file as written (a cell lattice, or a caller with no file, has none)
  if (!done.ok || !ask.print) return done;
  done.answer_by = "break";
  try {
    ll::StrengthDone d = with_break_check(ask, S, done);
    d.answer_verdict = d.break_verdict;
    d.answer_reason = d.break_reason;
    return d;
  } catch (const std::exception& e) {   // never a deleted file for a check that could not be made
    break_c2::add_break(done, break_c2::not_checked_block("error", std::string("the break check stopped on an error: ") + e.what(),
                                                          S.options.margin_stop));
    done.accepted = false;
    done.answer_verdict = "not_checked";
    done.answer_reason = "error";
    return done;
  }
}

}  // namespace

lattice_layout::StrengthCheck lattice_file_strength_check(const std::string& materials_path,
                                                          const std::string& rules_path) {
  lattice_layout::StrengthCheck check;
  check.before = [materials_path](const std::string& path) {
    try {
      const MaterialLibrary materials = load_materials_file(materials_path);
      StrengthSettingsAsked st;
      if (const std::string bad = read_strength_settings(path, materials, st); !bad.empty())
        return strength_no("strength_settings_refused", 1, bad);
      const JobDescription job = load_job_file(path, st.get("safety_margin_floor"));
      if (const std::string p = strength_job_problem(job, materials); !p.empty())
        return strength_no("strength_job_unreadable", 1, kStrengthJobUnreadableWhy, p);
    } catch (const std::exception& e) {
      return strength_no("strength_job_unreadable", 1, kStrengthJobUnreadableWhy, e.what());
    }
    lattice_layout::StrengthDone ok;
    ok.ok = true;
    return ok;
  };
  check.run = [materials_path, rules_path](const lattice_layout::StrengthAsk& ask) {
    try {
      return run_lattice_file_strength(ask, materials_path, rules_path);
    } catch (const std::exception& e) {
      return strength_no("strength_failed", 1,
                         "The lattice's strength could not be checked, so no file was made.", e.what());
    }
  };
  check.run_organic = [materials_path, rules_path](const lattice_layout::StrengthAsk& ask) {
    try {
      return run_lattice_file_strength_organic(ask, materials_path, rules_path);
    } catch (const std::exception& e) {
      return strength_no("strength_failed", 1,
                         "The lattice's strength could not be checked, so no file was made.", e.what());
    }
  };
  return check;
}

std::string organic_solid_text(double infill_percent, int passes_at, bool walls_certify, std::size_t shown,
                               std::size_t total) {
  const auto pc = [](double p) {
    char b[32];
    if (std::fabs(p - std::round(p)) < 1e-9) std::snprintf(b, sizeof b, "%.0f", p);
    else std::snprintf(b, sizeof b, "%g", p);
    return std::string(b);
  };
  const std::string areas = total == 1 ? "the marked area"
                            : shown < total ? "the " + std::to_string(shown) + " worst of " + std::to_string(total) + " marked areas"
                                            : "the " + std::to_string(total) + " marked areas";
  std::string t;
  if (passes_at < 0) {
    t = "The solid part does not certify, even printed solid. Strengthen " + areas + ".";
  } else {
    t = "The solid part does not certify at " + pc(infill_percent) + " % infill. It would certify at " +
        std::to_string(passes_at) + " % infill. The other way is to strengthen " + areas + ".";
  }
  if (walls_certify) t += " Counting the printed walls as solid, it certifies.";
  return t;
}

// ══ BRIEF E2, ITEM 12: THE STRENGTHEN ROUNDS AS ONE JOB (`topopt-cli organic-strengthen`) ══════════════════════════
// The lattice-file job (read as the file job reads it) and its strength job; no file is meshed. Check; stop when no
// judged strut is under the safety margin, or after strengthen_rounds rounds (0: additive 6; rebuild 2 Traced, 3 Grown); else a round
// (strengthen_round: the boosted copy of the stress input, the floors, strengthened.json, in r<N+1>/), lay again, check
// again. Nothing in the job follows the stress: nothing_to_vary after the first check.
OrganicStrengthenResult run_organic_strengthen(const std::string& job_path, const std::string& out_dir, int threads,
                                               const std::string& materials_path, const std::string& rules_path,
                                               void (*said)(const char*), const std::atomic<bool>* stop) {
  OrganicStrengthenResult res;
  const auto t_all = std::chrono::steady_clock::now();
  const auto say = [&](const std::string& line) {
    if (said) said(line.c_str());
  };
  const auto secs = [](std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  };
  std::string rounds_json;
  std::string summary_keys;   // K4: what the strengthening did, for the app (the additive mode's last check)
  double reference = 0.0;
  int limit = 0;
  std::string mode_name = "rebuild";
  const auto finish = [&](bool ok, const std::string& code, int exit_code, const std::string& why,
                          const std::string& detail = {}) {
    res.ok = ok;
    res.code = code;
    res.exit_code = exit_code;
    res.why = why;
    res.detail = detail;
    std::string o = "{\n  \"ok\": " + std::string(ok ? "true" : "false") + ",\n  \"code\": " + json_str(code) +
                    ",\n  \"why\": " + json_str(why) + ",\n  \"detail\": " + json_str(detail) +
                    ",\n  \"mode\": " + json_str(mode_name) + (mode_name == "additive" ? std::string(",\n  \"old_bars_kept\": ") + (res.old_bars_kept ? "true" : "false") : std::string()) +
                    ",\n  \"passing\": " + std::string(res.passing ? "true" : "false") +
                    ",\n  \"rounds_fixed\": " + std::to_string(res.rounds_fixed) + ",\n  \"rounds_limit\": " +
                    std::to_string(limit) + ",\n  \"reference_mpa\": " + [&] {
                      char b[64];
                      std::snprintf(b, sizeof b, "%.17g", reference);   // as strengthened.json states it
                      return std::string(b);
                    }() +
                    ",\n  \"strengthened\": " + (res.last_strengthened.empty() ? std::string("null") : json_str(res.last_strengthened)) +
                    summary_keys + ",\n  \"rounds\": [" + rounds_json + (rounds_json.empty() ? "" : "\n  ") + "],\n  \"seconds\": " +
                    json_num(std::round(secs(t_all) * 10.0) / 10.0) + "\n}\n";
    std::ofstream(join_path(out_dir, "strengthen.json")) << o;
    return res;
  };
  // ── the job, as the file job reads it.
  ll::FileJob job;
  StepModel model;
  {
    ll::FileResult fr;
    if (!ll::load_file_job(job_path, threads, job, model, fr, said)) return finish(false, fr.code, fr.exit_code, fr.why, fr.detail);
  }
  if (job.strength_job.empty())
    return finish(false, "strength_job_missing", 3,
                  "Strengthening needs the part's strength job (its loads and supports), and this job names none.");
  bool any_weave = false, any_cells = job.settings.regions.empty();
  for (const ll::Settings::RegionAsk& a : job.settings.regions) {
    any_weave = any_weave || a.weave;
    any_cells = any_cells || (a.role == ll::Role::Lattice && !a.weave);
  }
  if (!any_weave || any_cells || !job.tensor_field)
    return finish(false, "not_organic", 3,
                  "Strengthening is for an Organic lattice in every region, and this job is not one, so nothing was done.");
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  for (const Vec3& v : model.mesh.vertices) {
    lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
    hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
  }
  ll::Session session(std::move(model));
  if (session.open_edges() != 0)
    return finish(false, "part_not_closed", 3, "The part's surface has gaps in it, so its inside cannot be told from its outside.");
  // ── the strength job, set up once (its grid and load case do not change between rounds).
  StrengthSetup S;
  {
    ll::StrengthAsk ask;
    ask.job_path = job.strength_job;
    ask.part_lo = lo;
    ask.part_hi = hi;
    ask.threads = job.options.threads;
    ask.frame = job.print_frame;   // P2: the strength job through the same door
    ll::StrengthDone bad = strength_setup(ask, materials_path, rules_path, S);
    if (!bad.ok) return finish(false, bad.code, bad.exit_code, bad.why, bad.detail);
  }
  ll::OrganicAsk ask = job.organic;
  // OJ5 (leg J item 5): a job of several Organic groups: each group laid by its own ask; per region its group's light
  // and upper widths (the OS18 limit and the cap), gap and layer. The first group's ask stands for the job's own.
  std::vector<ll::OrganicGroup> groups = job.organic_groups;
  if (!groups.empty()) ask = groups.front().ask;
  const bool grown = ask.mode == ll::OrganicMode::Grown;
  if (groups.size() > 1 && S.st.get("strengthen_mode") != 0.0)
    return finish(false, "rebuild_one_group", 3,
                  "The rebuild mode of strengthening lays one Organic group, and this job has several; use the additive mode.");
  limit = static_cast<int>(S.st.get("strengthen_rounds"));
  // 0: the default. Additive (brief E4, item 1): six rounds (it stops as soon as nothing is under the safety margin);
  // rebuild: 2 for Traced, 3 for Grown.
  if (limit == 0) limit = S.st.get("strengthen_mode") == 0.0 ? 6 : grown ? 3 : 2;
  ll::StrengthenSettings ss;
  ss.watch_margin = S.st.get("strengthen_watch_margin");
  ss.boost_max = S.st.get("strengthen_boost_max");
  ss.boost_power = S.st.get("strengthen_boost_power");
  ss.target_margin = S.st.get("strengthen_target_margin");
  // ── Brief E3a: the additive mode (the default; strengthen_mode 0): lay ONCE, then per round check, add (braces at
  // struts failing by buckling, widening in place), check again. Nothing that exists is moved or removed.
  if (S.st.get("strengthen_mode") == 0.0) {
    mode_name = "additive";
    const double cap_x = S.st.get("strengthen_width_cap");
    const double p_axial = S.st.get("strengthen_power_axial"), p_bend = S.st.get("strengthen_power_bending"),
                 p_buckle = S.st.get("strengthen_power_buckling");
    const double E = S.material.youngs_modulus_mpa;
    const auto hash_hex = [](std::uint64_t h) {
      char b[24];
      std::snprintf(b, sizeof b, "%016llx", static_cast<unsigned long long>(h));
      return std::string(b);
    };
    say("laying the lattice (once)");
    auto t0 = std::chrono::steady_clock::now();
    // OS16 (brief E4, leg 2): the bars judged are the bars the file writes. A job laid with additions replays them with
    // the print check between rounds (as the file job does); the lay is then print-checked before the first check.
    const ll::FileOptions file_options = ll::file_options_for(job.options, true);
    if (!ask.additions.empty()) ask.print_check = ll::print_check_hook(session, file_options, stop);
    if (!groups.empty()) groups.front().ask.print_check = ask.print_check;   // OJ5
    const ll::Outcome out = groups.empty() ? session.lay_organic(job.settings, *job.tensor_field, ask, job.options.threads, stop)
                                           : session.lay_organic(job.settings, *job.tensor_field, groups, job.options.threads, stop);
    const double s_lay0 = secs(t0);
    if (out.cancelled) return finish(false, "cancelled", 1, "Stopped before the strengthening was finished.");
    if (!out.additions_refused.empty())
      return finish(false, "strengthened_mismatch", 1,
                    "The strengthening sent with the lattice job was made on a different lattice than this lay gives.",
                    out.additions_refused);
    for (const auto& [region, ref] : out.organic_references) reference = std::max(reference, ref);
    const ll::Domain& domain = *session.domain();
    double light = ask.width_mm > 0.0 ? ask.width_mm : domain.spec().bead_mm * domain.spec().min_strut_lines;
    const double upper = ask.width_heavy_mm > 0.0 ? ask.width_heavy_mm : light;
    const double cap = cap_x * upper;
    ll::AddContext ctx;
    ctx.light_mm = light;
    ctx.layer_mm = ask.layer_mm;
    ctx.link_width = ask.link_width;
    // OJ5: per region, its group's {light, upper, gap}; the check reads the thinnest light width of the job.
    std::map<int, std::array<double, 3>> per_region;
    for (const ll::OrganicGroup& g : groups) {
      const double l = g.ask.width_mm > 0.0 ? g.ask.width_mm : domain.spec().bead_mm * domain.spec().min_strut_lines;
      const double u = g.ask.width_heavy_mm > 0.0 ? g.ask.width_heavy_mm : l;
      const double gp = g.ask.gap_lines > 0.0 ? g.ask.gap_lines * domain.spec().bead_mm : domain.spec().bead_mm;
      for (int rid : g.regions) {
        per_region[rid] = {l, u, gp};
        if (groups.size() > 1) ctx.per_region[rid] = {l, g.ask.layer_mm, g.ask.link_width};
      }
      light = std::min(light, l);
    }
    const auto lim_r = [&](int region) { const auto it = per_region.find(region); return it == per_region.end() ? upper : it->second[1]; };
    const auto cap_r = [&](int region) { return cap_x * lim_r(region); };
    for (const ll::Layout::Weave& w : out.layout.weave) ctx.weave_regions.push_back(w.region);   // OG5
    ctx.line_mm = domain.spec().bead_mm;
    say("checking the lattice prints (round 0)");
    ll::PrintChecked pc = ll::print_check_bars(session, out.layout, out.bars, file_options, stop);
    if (!pc.ok) return finish(false, "print_check_failed", 1, "The lattice's file could not be put together, so its strength cannot be judged.", pc.why);
    double s_pc = secs(t0) - s_lay0;
    ll::Bars bars = pc.bars;                  // the bars the file writes, and which of them it keeps
    std::vector<char> in_file = pc.kept;
    const ll::Bars bars0 = bars;              // round 0's lattice: every round must keep it (OS12)
    bool moved_by_print = false;              // a print check after a round has moved a bar that was there before it
    ll::Additions adds = ask.additions;       // a job laid with additions goes on from them
    // Struts are known across rounds by the middle of their worst piece (to 0.25 mm).
    using StrutKey = std::array<long long, 3>;
    auto strut_key = [](const Vec3& p) {
      return StrutKey{std::llround(p.x / 0.25), std::llround(p.y / 0.25), std::llround(p.z / 0.25)};
    };
    std::map<StrutKey, double> margin_before;
    std::set<StrutKey> widened_before;
    // OS11 (the order; the owner, 2026-11-19: "we DON'T want to thicken beyond the limit. That's why it's the limit. So
    // thicken to the limit ... and only at the end if it is impossible, thicken passed the limit"): the limit is the
    // group's upper strut width; a strut goes past it once a check has judged it AT the limit and found it under the
    // safety factor (that check may be the one that first finds it).
    const double limit_w = upper;
    // Leg I (diagnosis): the bars of the check before (ends to 1e-4 mm) with their strut's margin, and the landings of
    // the vines laid in the round before (where, the strut landed on, its margin then, how far from its nearer joint).
    using EndsKey = std::array<long long, 6>;
    const auto ends_key = [](const Vec3& a, const Vec3& b) {
      EndsKey k1{std::llround(a.x * 1e4), std::llround(a.y * 1e4), std::llround(a.z * 1e4), std::llround(b.x * 1e4),
                 std::llround(b.y * 1e4), std::llround(b.z * 1e4)};
      EndsKey k2{k1[3], k1[4], k1[5], k1[0], k1[1], k1[2]};
      return std::min(k1, k2);
    };
    std::map<EndsKey, double> prev_margin_of;              // a bar of the check before: its strut's margin (judged)
    std::vector<std::pair<ll::Bar, double>> prev_bars;     // the same bars, for "a piece of which old bar"
    res.old_bars_kept = true;
    // K4 (his Results notes, 2026-11-24: "What changes were made to strengthen it?"): the struts (known across rounds by
    // their key, as OS18 knows them) widened by a widening the round kept (one taken back near a print finding is not
    // counted), and those held by braces, over every round.
    std::set<StrutKey> braced_ever;
    std::map<StrutKey, int> thickened_ever;   // notes27: each strut's region (its group's count)
    for (int n = 0;; ++n) {
      if (stop && stop->load()) return finish(false, "cancelled", 1, "Stopped before the strengthening was finished.");
      const std::string rdir = join_path(out_dir, "r" + std::to_string(n));
      std::error_code ec;
      std::filesystem::create_directories(rdir, ec);
      say("round " + std::to_string(n) + ": checking its strength");
      OrganicCheckRun cr = organic_frame_check(S, domain, bars, &in_file, light, rdir, job.options.threads);
      const auto reg = [&](const ll::FrameStrut& sn) {   // OJ5: a strut's region (its first bar's)
        if (sn.pieces.empty()) return 0;
        const int fb = cr.frame.pieces[static_cast<std::size_t>(sn.pieces.front())].bar;
        return fb >= 0 && static_cast<std::size_t>(fb) < cr.bar_of.size() ? bars.bars[static_cast<std::size_t>(cr.bar_of[static_cast<std::size_t>(fb)])].region : 0;
      };
      if (!cr.done.ok) return finish(false, cr.done.code, cr.done.exit_code, cr.done.why, cr.done.detail);
      std::ofstream(join_path(rdir, "strength.json")) << cr.done.json << "\n";
      const ll::FrameCheck& c = cr.check;
      // Leg I (diagnosis): each judged strut's class against the check before: "vine" (a relief vine's bar), "brace" (a
      // new brace bar), "cut" (a new piece of an old bar, cut by a landing or a brace), else "untouched" (its bars all
      // there before, widened or not). Under the safety factor per class, and the cut ones whose old bar's strut was at
      // or above it (under only because of new pieces).
      std::vector<std::string> strut_class(c.struts.size(), "untouched");
      std::map<std::string, std::array<std::size_t, 2>> by_class;   // judged, under
      std::size_t new_pieces_under = 0;
      {
        for (std::size_t si = 0; si < c.struts.size(); ++si) {
          const ll::FrameStrut& sn = c.struts[si];
          bool vine = false, brace = false, cut = false, newly = false;
          for (int pi : sn.pieces) {
            const int fb = cr.frame.pieces[static_cast<std::size_t>(pi)].bar;
            if (fb < 0 || static_cast<std::size_t>(fb) >= cr.bar_of.size()) continue;
            const ll::Bar& b = bars.bars[static_cast<std::size_t>(cr.bar_of[static_cast<std::size_t>(fb)])];
            if (b.relief) { vine = true; continue; }
            if (n == 0 || prev_margin_of.count(ends_key(b.a, b.b))) continue;
            if (b.brace) { brace = true; continue; }
            cut = true;
            for (const auto& [ob, om] : prev_bars) {   // the old bar it lies on
              const Vec3 d{ob.b.x - ob.a.x, ob.b.y - ob.a.y, ob.b.z - ob.a.z};
              const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
              auto off = [&](const Vec3& q) {
                const double t = l2 > 0 ? std::clamp(((q.x - ob.a.x) * d.x + (q.y - ob.a.y) * d.y + (q.z - ob.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
                const double ex = ob.a.x + d.x * t - q.x, ey = ob.a.y + d.y * t - q.y, ez = ob.a.z + d.z * t - q.z;
                return std::sqrt(ex * ex + ey * ey + ez * ez);
              };
              if (off(b.a) < 1e-4 && off(b.b) < 1e-4) { newly = newly || om >= S.options.margin_stop; break; }
            }
          }
          strut_class[si] = vine ? "vine" : brace ? "brace" : cut ? "cut" : "untouched";
          if (!sn.judged) continue;
          auto& e = by_class[strut_class[si]];
          ++e[0];
          const bool under = sn.margin < S.options.margin_stop;
          e[1] += under;
          new_pieces_under += under && !vine && !brace && cut && newly;
        }
      }
      std::ofstream(join_path(rdir, "struts_under.json")) << struts_under_json(cr, ss.watch_margin, cap, &strut_class, &bars,
                                                                                 job.print_frame);
      std::size_t at_cap_left = 0;
      for (const ll::FrameStrut& sn : c.struts) at_cap_left += sn.judged && sn.margin < S.options.margin_stop && sn.width_max >= cap_r(reg(sn)) - 1e-9;
      std::string r = std::string(rounds_json.empty() ? "\n    " : ",\n    ") + "{\"round\": " + std::to_string(n) +
                      ", \"verdict\": " + json_str(cr.verdict) + ", \"fail_reason\": " + json_str(cr.fail_reason) +
                      ", \"bars\": " + std::to_string(bars.bars.size()) + ", \"hash\": " + json_str(hash_hex(ll::bars_hash(bars))) +
                      ", \"old_bars_kept\": " + (res.old_bars_kept ? "true" : "false") +
                      ", \"gap_broken\": " + std::to_string(ll::gap_broken(bars)) +   // OG1 (brief E6)
                      ",\n     \"struts\": {\"judged\": " + std::to_string(c.judged) + ", \"under_safety\": " +
                      std::to_string(c.under_safety) + ", \"under_one\": " + std::to_string(c.under_one) +
                      ", \"smallest_margin\": " + json_num(c.judged ? c.smallest_margin : std::numeric_limits<double>::quiet_NaN()) +
                      ", \"buckling_failures\": " + std::to_string(c.buckling_failures) + ", \"stubs\": " + std::to_string(c.stubs) +
                      ", \"under_safety_at_cap\": " + std::to_string(at_cap_left) +
                      ", \"unjudged_mm\": " + json_num(c.unjudged_mm) + ", \"load_unheld_n\": " + json_num(c.load_unheld_n) + "}" +
                      ",\n     \"lattice_mm3\": " + json_num(cr.lattice_mm3) +
                      ", \"seconds\": {\"lay\": " + json_num(n == 0 ? std::round(s_lay0 * 10) / 10 : 0.0) +
                      ", \"print_check\": " + json_num(std::round(s_pc * 10) / 10) + ", \"material\": " +
                      json_num(std::round(cr.ms_material / 100) / 10) + ", \"voxel_solve\": " +
                      json_num(std::round(cr.ms_voxel / 100) / 10) + ", \"frame\": " + json_num(std::round(cr.ms_frame / 100) / 10) +
                      "}, \"memory_mb\": {\"after_voxel_solve\": " + json_num(std::round(cr.mb_voxel)) + ", \"after_frame\": " +
                      json_num(std::round(cr.mb_frame)) + ", \"peak\": " + json_num(std::round(process_memory().peak_rss_mb)) +
                      "}, \"check\": " + json_str("r" + std::to_string(n) + "/strength.json");
      {   // Leg I (diagnosis)
        r += ", \"classes\": {";
        bool first = true;
        for (const char* k : {"untouched", "cut", "brace", "vine"}) {
          const auto it = by_class.find(k);
          const std::size_t j = it == by_class.end() ? 0 : it->second[0], u = it == by_class.end() ? 0 : it->second[1];
          r += std::string(first ? "" : ", ") + "\"" + k + "\": {\"judged\": " + std::to_string(j) + ", \"under\": " + std::to_string(u) + "}";
          first = false;
        }
        r += ", \"under_only_because_of_new_pieces\": " + std::to_string(new_pieces_under) + "}";
      }
      // Leg I: remember this check's bars and their struts' margins for the next round's classes.
      prev_margin_of.clear();
      prev_bars.clear();
      for (const ll::FrameStrut& sn : c.struts)
        for (int pi : sn.pieces) {
          const int fb = cr.frame.pieces[static_cast<std::size_t>(pi)].bar;
          if (fb < 0 || static_cast<std::size_t>(fb) >= cr.bar_of.size()) continue;
          const ll::Bar& b = bars.bars[static_cast<std::size_t>(cr.bar_of[static_cast<std::size_t>(fb)])];
          const double m = sn.judged ? sn.margin : std::numeric_limits<double>::infinity();
          prev_margin_of[ends_key(b.a, b.b)] = m;
          prev_bars.push_back({b, m});
        }
      for (const ll::Bar& b : bars.bars) if (!prev_margin_of.count(ends_key(b.a, b.b))) prev_margin_of[ends_key(b.a, b.b)] = std::numeric_limits<double>::infinity();
      const bool clean = c.solved && c.under_safety == 0;
      const bool bare = cr.fail_reason == "load_on_bare_lattice";   // the interim guard: adding vines cannot cure it
      if (clean || bare || n >= limit || !c.solved) {
        rounds_json += r + "}";
        {   // K4: the summary, of this last check (the lattice the last round's strengthened.json gives)
          double widest = 0.0;
          for (std::size_t i = 0; i < bars.bars.size(); ++i)
            if (i >= in_file.size() || in_file[i]) widest = std::max(widest, bars.bars[i].width);
          // Per group (OJ5; one group for a job of one ask): its regions, its thickest setting (the upper width), and its
          // struts of this check wider than it.
          struct Group { std::vector<int> regions; double thickest = 0.0, widest = 0.0; std::size_t past = 0, thickened = 0;
                         std::string name; };
          std::vector<Group> gs;
          if (groups.empty()) {
            Group g;
            g.regions = ctx.weave_regions;
            g.thickest = upper;
            gs.push_back(g);
          } else {
            for (const ll::OrganicGroup& og : groups) {
              Group g;
              g.regions = og.regions;
              g.thickest = lim_r(og.regions.empty() ? 0 : og.regions.front());
              g.name = og.name;
              gs.push_back(g);
            }
          }
          // notes27: per group, its struts thickened (each once) and its widest bar in the file now
          const auto group_of = [&](int region) -> Group* {
            if (groups.empty()) return &gs.front();
            for (Group& g : gs)
              if (std::find(g.regions.begin(), g.regions.end(), region) != g.regions.end()) return &g;
            return nullptr;
          };
          for (const auto& [key, region] : thickened_ever)
            if (Group* g = group_of(region)) ++g->thickened;
          for (std::size_t i = 0; i < bars.bars.size(); ++i)
            if (i >= in_file.size() || in_file[i])
              if (Group* g = group_of(bars.bars[i].region)) g->widest = std::max(g->widest, bars.bars[i].width);
          std::size_t past = 0;
          for (const ll::FrameStrut& sn : c.struts) {
            const int rg = reg(sn);
            if (!(sn.width_max > lim_r(rg) + 1e-9)) continue;
            ++past;
            for (Group& g : gs)
              if (groups.empty() || std::find(g.regions.begin(), g.regions.end(), rg) != g.regions.end()) { ++g.past; break; }
          }
          summary_keys = ",\n  \"thickened_distinct\": " + std::to_string(thickened_ever.size()) +
                         ",\n  \"braced\": " + std::to_string(braced_ever.size()) + ",\n  \"widest_mm\": " + json_num(widest) +
                         ",\n  \"past_thickest\": " + std::to_string(past) + ",\n  \"groups\": [";
          for (std::size_t gi = 0; gi < gs.size(); ++gi) {
            std::string regs;
            for (std::size_t q = 0; q < gs[gi].regions.size(); ++q) regs += (q ? ", " : "") + std::to_string(gs[gi].regions[q]);
            summary_keys += std::string(gi ? ", " : "") + "{\"id\": " + std::to_string(gi) +
                            (gs[gi].name.empty() ? std::string() : ", \"name\": " + json_str(gs[gi].name)) +
                            ", \"regions\": [" + regs + "], \"thickest_setting_mm\": " + json_num(gs[gi].thickest) +
                            ", \"past_thickest\": " + std::to_string(gs[gi].past) + ", \"thickened_distinct\": " +
                            std::to_string(gs[gi].thickened) + ", \"widest_mm\": " + json_num(gs[gi].widest) + "}";
          }
          summary_keys += "]";
        }
        res.passing = cr.verdict == "pass";
        if (bare) return finish(true, "load_on_bare_lattice", 0, kLoadOnBareLatticeText);
        if (clean) return finish(true, "done", 0, "");
        if (!c.solved) return finish(true, "frame_not_solved", 0, "The frame could not be solved, so there is nothing to strengthen from.");
        return finish(true, "limit", 0, "The rounds of strengthening allowed were all done.");
      }
      // ── one round of additions.
      say("round " + std::to_string(n) + ": adding to the weak struts");
      const auto t1 = std::chrono::steady_clock::now();
      // The watched struts, each with its bars in the layout's order and its pieces chained end to end.
      struct Watched { const ll::FrameStrut* sn; std::vector<int> chain; };
      std::vector<Watched> watched;
      for (const ll::FrameStrut& sn : c.struts)
        if (sn.judged && sn.margin < ss.watch_margin) watched.push_back({&sn, {}});
      const auto layout_bar = [&](int pi) { return cr.bar_of[static_cast<std::size_t>(cr.frame.pieces[static_cast<std::size_t>(pi)].bar)]; };
      // (1) braces at struts failing by buckling: n = ceil(L / L_allow) - 1 points evenly along it, L_allow the free
      // length whose pinned Euler load is target x its compression at its thinnest width.
      ll::AddRound round;
      std::vector<std::pair<std::size_t, std::size_t>> brace_ops_of;   // per watched strut: its brace ops [from, to)
      brace_ops_of.assign(watched.size(), {0, 0});
      std::size_t struts_braced_asked = 0;
      for (std::size_t wi = 0; wi < watched.size(); ++wi) {
        const ll::FrameStrut& sn = *watched[wi].sn;
        brace_ops_of[wi] = {round.ops.size(), round.ops.size()};
        if (sn.by != "buckling" || !(sn.n_min < 0.0)) continue;
        const double I = M_PI * std::pow(0.5 * sn.width_min, 4) / 4.0;
        const double L_allow = M_PI * std::sqrt(E * I / (-sn.n_min * ss.target_margin));
        if (!(L_allow > 0.0)) continue;
        const int nb = static_cast<int>(std::ceil(sn.length_mm / L_allow)) - 1;
        if (nb < 1) continue;
        // The pieces in order from one end.
        std::vector<int> chain;
        {
          std::map<int, std::vector<int>> at;
          for (int pi : sn.pieces) {
            at[cr.frame.pieces[static_cast<std::size_t>(pi)].a].push_back(pi);
            at[cr.frame.pieces[static_cast<std::size_t>(pi)].b].push_back(pi);
          }
          int node = sn.end_node[0] >= 0 ? sn.end_node[0] : cr.frame.pieces[static_cast<std::size_t>(sn.pieces.front())].a;
          std::set<int> used;
          for (;;) {
            int next = -1;
            for (int pi : at[node]) if (!used.count(pi)) { next = pi; break; }
            if (next < 0) break;
            used.insert(next);
            chain.push_back(next);
            const ll::FramePiece& fp = cr.frame.pieces[static_cast<std::size_t>(next)];
            node = fp.a == node ? fp.b : fp.a;
          }
          if (chain.size() != sn.pieces.size()) continue;   // not one run end to end: left to widening
        }
        ++struts_braced_asked;
        double walked = 0.0;
        std::size_t k = 0;
        int node = sn.end_node[0] >= 0 ? sn.end_node[0] : cr.frame.pieces[static_cast<std::size_t>(chain.front())].a;
        for (int q = 1; q <= nb; ++q) {
          const double want = sn.length_mm * q / (nb + 1);
          while (k < chain.size()) {
            const ll::FramePiece& fp = cr.frame.pieces[static_cast<std::size_t>(chain[k])];
            const Vec3 A = cr.frame.nodes[static_cast<std::size_t>(fp.a == node ? fp.a : fp.b)];
            const Vec3 B = cr.frame.nodes[static_cast<std::size_t>(fp.a == node ? fp.b : fp.a)];
            const double l = std::sqrt((B.x - A.x) * (B.x - A.x) + (B.y - A.y) * (B.y - A.y) + (B.z - A.z) * (B.z - A.z));
            if (walked + l >= want || k + 1 == chain.size()) {
              const double t = l > 0.0 ? std::clamp((want - walked) / l, 0.0, 1.0) : 0.0;
              const Vec3 X{A.x + (B.x - A.x) * t, A.y + (B.y - A.y) * t, A.z + (B.z - A.z) * t};
              const ll::Bar& hb = bars.bars[static_cast<std::size_t>(layout_bar(chain[k]))];
              const Vec3 d{hb.b.x - hb.a.x, hb.b.y - hb.a.y, hb.b.z - hb.a.z};
              const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
              const double u = l2 > 0.0 ? ((X.x - hb.a.x) * d.x + (X.y - hb.a.y) * d.y + (X.z - hb.a.z) * d.z) / l2 : 0.5;
              round.ops.push_back({1, {hb.a.x, hb.a.y, hb.a.z, hb.b.x, hb.b.y, hb.b.z, std::clamp(u, 0.0, 1.0), hb.width}});
              break;
            }
            walked += l;
            node = fp.a == node ? fp.b : fp.a;
            ++k;
          }
        }
        brace_ops_of[wi].second = round.ops.size();
      }
      // OS11 (the order): A's factor of a watched strut (as the widening reads it below). A strut under the safety
      // factor is widened by A up to its group's limit; one checked AT the limit now and under the safety factor in the
      // check before as well goes past it, by A up to the cap (`past_now`). A strut only under the watch margin never
      // passes the limit.
      const auto a_factor = [&](const ll::FrameStrut& sn) {
        return sn.by == "buckling" ? std::pow(ss.target_margin / sn.buckling_margin, 1.0 / p_buckle)
                                   : std::pow(ss.target_margin / sn.stress_margin, 1.0 / (sn.bending_led ? p_bend : p_axial));
      };
      std::set<const ll::FrameStrut*> past_now;
      std::size_t c_within = 0;
      for (std::size_t wi = 0; wi < watched.size(); ++wi) {
        const ll::FrameStrut& sn = *watched[wi].sn;
        if (!(sn.margin < S.options.margin_stop)) continue;
        // A check has judged it AT the limit and found it under the safety factor: this one (fix 2026-11-19: a strut
        // already at the limit when first found goes past it in the same round, no round lost).
        if (sn.width_max >= lim_r(reg(sn)) - 1e-9) past_now.insert(&sn);
        else ++c_within;
      }
      const ll::Bars before_round = bars;   // the bars the check numbered
      ll::AddReport brep;
      std::string why;
      if (!round.ops.empty() && !ll::apply_add_round(bars, domain, round, ctx, &brep, &why))
        return finish(false, "strengthen_failed", 1, "A round of strengthening could not be added.", why);
      // (2) widening in place: each watched strut's own bars (as they now are, braces cut) by
      // (target / m)^(1 / p): p axial, bending (bending the larger part) or buckling (a buckling strut no brace could
      // be laid at); never thinner, never above the cap.
      std::vector<ll::Bar> olds;
      std::vector<double> factor;
      std::vector<double> ceil_of;                     // OS18 amended: per old bar, the widest it may go this round
      std::vector<double> lim_of;                      // OJ5: and its group's limit
      std::vector<const ll::FrameStrut*> strut_of;     // and its strut
      std::size_t struts_widened = 0, struts_braced = 0, struts_at_cap = 0;
      std::set<StrutKey> widened_now;   // OS18
      for (std::size_t wi = 0; wi < watched.size(); ++wi) {
        const ll::FrameStrut& sn = *watched[wi].sn;
        double f = 1.0;
        if (sn.by == "buckling") {
          bool all = brace_ops_of[wi].second > brace_ops_of[wi].first;
          for (std::size_t q = brace_ops_of[wi].first; q < brace_ops_of[wi].second; ++q) all = all && brep.braces_at[q] > 0;
          if (all) { ++struts_braced; braced_ever.insert(strut_key(sn.at)); continue; }   // K4
          f = std::pow(ss.target_margin / sn.buckling_margin, 1.0 / p_buckle);
        } else {
          f = std::pow(ss.target_margin / sn.stress_margin, 1.0 / (sn.bending_led ? p_bend : p_axial));
        }
        if (!(f > 1.0)) continue;
        bool any = false, capped = false;
        std::vector<int> seen;
        for (int pi : sn.pieces) {
          const int lb = layout_bar(pi);
          if (std::find(seen.begin(), seen.end(), lb) != seen.end()) continue;
          seen.push_back(lb);
          olds.push_back(before_round.bars[static_cast<std::size_t>(lb)]);
          factor.push_back(f);
          ceil_of.push_back(past_now.count(&sn) ? cap_r(reg(sn)) : lim_r(reg(sn)));   // OS11; OJ5
          lim_of.push_back(lim_r(reg(sn)));
          strut_of.push_back(&sn);
          capped = capped || olds.back().width * f > cap_r(reg(sn)) + 1e-12;
          any = true;
        }
        struts_widened += any;
        struts_at_cap += capped;
        if (any) widened_now.insert(strut_key(sn.at));   // OS18
      }
      ll::AddRound widen;
      std::vector<std::pair<StrutKey, int>> widen_key;   // K4: per widening op, its strut's key (and region, notes27)
      double past_widest = 0.0;   // OS18 amended: the widest a bar was made past the limit this round
      {
        const std::vector<std::vector<std::size_t>> on = ll::pieces_on(bars, olds);
        std::set<std::size_t> done;
        for (std::size_t k = 0; k < olds.size(); ++k)
          for (std::size_t j : on[k]) {
            if (done.count(j)) continue;
            const ll::Bar& b = bars.bars[j];
            const double w = std::min(ceil_of[k], std::max(b.width, b.width * factor[k]));
            if (!(w > b.width)) continue;
            done.insert(j);
            widen.ops.push_back({2, {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, w}});
            widen_key.push_back({strut_key(strut_of[k]->at), reg(*strut_of[k])});   // K4
            if (ceil_of[k] > lim_of[k] && w > lim_of[k] + 1e-12) past_widest = std::max(past_widest, w);
          }
      }
      ll::AddReport wrep;
      const ll::Bars pre_widen = bars;               // OS16 fix: the round's bars before its widenings
      const std::size_t brace_ops = round.ops.size();
      if (!widen.ops.empty() && !ll::apply_add_round(bars, domain, widen, ctx, &wrep, &why))
        return finish(false, "strengthen_failed", 1, "A round of strengthening could not be added.", why);
      round.ops.insert(round.ops.end(), widen.ops.begin(), widen.ops.end());
      margin_before.clear();
      for (const ll::FrameStrut& sn : c.struts) if (sn.judged) margin_before[strut_key(sn.at)] = sn.margin;
      std::vector<Vec3> past_at;   // OS11: the struts past the limit this round
      const std::size_t c_past = past_now.size();
      for (const ll::FrameStrut* sp : past_now) if (past_at.size() < 20) past_at.push_back(sp->at);
      // OS12, against round 0 AND against the round before (every earlier round's widenings and braces stay in force:
      // a bar widened in an earlier round is never thinner later).
      // OS16 amended (the lead, 2026-11-19): the print check may move a bar of round 0 (a sag lifted), so the additions
      // are held to OS12 against round 0 only while no print check has moved one, and always against the round before.
      std::size_t split = 0;
      std::string kept = moved_by_print ? std::string() : ll::old_bars_kept(bars0, bars, 1e-5, &split);
      if (kept.empty()) {
        const std::string since = ll::old_bars_kept(before_round, bars, 1e-5, moved_by_print ? &split : nullptr);
        if (!since.empty()) kept = "against the round before: " + since;
      }
      if (!kept.empty()) res.old_bars_kept = false;
      // OS16 (brief E4, leg 2; amended by the lead, 2026-11-19): the print check again (the new braces and wider struts
      // are new shells). It does what it does after a lay (leaves out, moves, props) and the job goes on: the next check
      // judges the bars as written. What it did among the bars that were there before the round is counted.
      // OG5 (brief E9): the round's bars guarded, as apply_additions guards them when the round is replayed.
      ll::GuardReport round_guard;
      // OS16 (fix 2026-11-19): the file job refuses a lattice its print check cannot make clean (would_not_print), so a
      // round must end clean too, one rule for both: when the round's print check is not clean, the round's widenings
      // within reach of a finding (the place within the bar's width + 1 mm of its line) are taken back, the round laid
      // again from its bars before the widenings, and checked again (at most 5 times). Still not clean: the
      // strengthening stops, and the last round written is the last that prints.
      ll::PrintChecked pc2;
      const auto tp = std::chrono::steady_clock::now();
      std::size_t widen_taken_back = 0;
      for (int pass = 0;; ++pass) {
        if (ll::guard_bars(bars, domain, ctx.weave_regions, ctx.line_mm, &round_guard, /*drop_cut_free=*/true) > 0) moved_by_print = true;
        say("round " + std::to_string(n) + ": checking the lattice prints");
        pc2 = ll::print_check_bars(session, out.layout, bars, file_options, stop);
        if (!pc2.ok)
          return finish(false, "print_check_failed", 1, "The lattice's file could not be put together, so its strength cannot be judged.", pc2.why);
        if (pc2.made.print_clean || pass >= 5 || pc2.made.findings_at.empty()) break;
        std::vector<ll::AddOp> keep;
        std::vector<std::pair<StrutKey, int>> keep_key;   // K4
        std::size_t dropped = 0;
        for (std::size_t oi = 0; oi < widen.ops.size(); ++oi) {
          const ll::AddOp& op = widen.ops[oi];
          const Vec3 a{op.v[0], op.v[1], op.v[2]}, b{op.v[3], op.v[4], op.v[5]};
          const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
          const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
          bool near = false;
          for (const Vec3& f : pc2.made.findings_at) {
            const double t = l2 > 0.0 ? std::clamp(((f.x - a.x) * d.x + (f.y - a.y) * d.y + (f.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
            const double ex = a.x + d.x * t - f.x, ey = a.y + d.y * t - f.y, ez = a.z + d.z * t - f.z;
            near = near || std::sqrt(ex * ex + ey * ey + ez * ez) <= op.v[6] + 1.0;
          }
          if (near) ++dropped;
          else { keep.push_back(op); keep_key.push_back(widen_key[oi]); }
        }
        if (dropped == 0) break;
        widen_taken_back += dropped;
        widen.ops = keep;
        widen_key = keep_key;
        bars = pre_widen;
        if (!widen.ops.empty() && !ll::apply_add_round(bars, domain, widen, ctx, &wrep, &why))
          return finish(false, "strengthen_failed", 1, "A round of strengthening could not be added.", why);
        round.ops.resize(brace_ops);
        round.ops.insert(round.ops.end(), widen.ops.begin(), widen.ops.end());
        round_guard = ll::GuardReport{};
      }
      for (const auto& [k, region] : widen_key) thickened_ever.emplace(k, region);   // K4: the widenings the round kept
      if (!pc2.made.print_clean)
        return finish(false, "would_not_print", 1,
                      "After round " + std::to_string(n + 1) + " the lattice would not print (an overhang or a start in mid-air), "
                      "and taking back that round's widenings near those places did not fix it, so the strengthening stopped. "
                      "The last round written is the last that prints.");
      const std::string printed = print_check_counts(before_round, in_file, bars, pc2.bars, pc2.kept, &moved_by_print,
                                                     job.print_frame) +
                                  ", \"print_clean\": " + (pc2.made.print_clean ? "true" : "false") +
                                  ", \"widenings_taken_back\": " + std::to_string(widen_taken_back);
      bars = std::move(pc2.bars);
      in_file = std::move(pc2.kept);
      s_pc = secs(tp);
      // OS11: the order's counts.
      std::string paths_json = "\"limit\": {\"limit_mm\": " + json_num(limit_w) + ", \"within_limit\": " + std::to_string(c_within) +
                               ", \"past_limit\": {\"struts\": " + std::to_string(c_past) + ", \"widest_mm\": " + json_num(past_widest) +
                               ", \"at\": [";
      for (std::size_t q = 0; q < past_at.size(); ++q) {
        char b[96];
        std::snprintf(b, sizeof b, "%s[%.3f, %.3f, %.3f]", q ? ", " : "", past_at[q].x, past_at[q].y, past_at[q].z);
        paths_json += b;
      }
      paths_json += "]}}";
      round.hash = ll::bars_hash(bars);
      adds.rounds.push_back(round);
      const double s_add = secs(t1);
      // The files: the additions so far and strengthened.json (version 2), in r<n+1>/.
      const std::string ndir = join_path(out_dir, "r" + std::to_string(n + 1));
      std::filesystem::create_directories(ndir, ec);
      ll::Strengthened st;
      st.version = 2;
      st.additions = "additions.bin";
      const std::string sj = join_path(ndir, "strengthened.json");
      const std::string more = "  \"round\": " + std::to_string(n + 1) + ",\n  \"rounds\": " + std::to_string(adds.rounds.size()) +
                               ",\n  \"bars_hash\": " + json_str(hash_hex(round.hash)) + ",\n  \"struts_watched\": " +
                               std::to_string(watched.size()) + ",\n  \"struts_widened\": " + std::to_string(struts_widened) +
                               ",\n  \"struts_braced\": " + std::to_string(struts_braced) + ",\n  \"braces\": " +
                               std::to_string(brep.braces) + ",\n  \"struts_at_cap\": " + std::to_string(struts_at_cap) +
                               print_up_json(job.print_frame);
      if (!ll::write_additions_file(join_path(ndir, st.additions), adds) || !ll::write_strengthened_file(sj, st, more))
        return finish(false, "cannot_write", 1, "The strengthened files could not be saved on the Mac.", ndir);
      res.last_strengthened = "r" + std::to_string(n + 1) + "/strengthened.json";
      ++res.rounds_fixed;
      rounds_json += r + ",\n     \"added\": {\"strengthened\": " + json_str(res.last_strengthened) +
                     ", \"struts_watched\": " + std::to_string(watched.size()) + ", \"struts_widened\": " +
                     std::to_string(struts_widened) + ", \"bars_widened\": " + std::to_string(wrep.widened) +
                     ", \"links_widened\": " + std::to_string(wrep.links_widened) + ", \"struts_braced\": " +
                     std::to_string(struts_braced) + ", \"buckling_struts_asked\": " + std::to_string(struts_braced_asked) +
                     ", \"brace_points\": " + std::to_string(brep.brace_points) + ", \"braces\": " + std::to_string(brep.braces) +
                     ", \"struts_at_cap\": " + std::to_string(struts_at_cap) + ", \"cap_mm\": " + json_num(cap) +
                     ", \"old_bars_split\": " + std::to_string(split) + ", \"old_bars_kept\": " + (kept.empty() ? "true" : "false") +
                     (kept.empty() ? std::string() : ", \"old_bars_broken\": " + json_str(kept)) +
                     ", " + printed + ", " + paths_json + ", \"guard_outside_cut\": " + std::to_string(round_guard.outside_cut) +
                     ", \"guard_in_solid_cut\": " + std::to_string(round_guard.in_solid_cut) +
                     ", \"guard_in_solid_removed\": " + std::to_string(round_guard.in_solid_removed) + ", \"hash\": " + json_str(hash_hex(round.hash)) + ", \"seconds\": " + json_num(std::round(s_add * 10) / 10) + "}}";
    }
  }
  // What follows the stress: a strut width on a Sweep, a spacing range, Grown's runs by stress.
  const bool varies = ask.width_heavy_mm > 0.0 || (!(ask.spacing_mm > 0.0) && ask.spacing_max_mm > ask.spacing_min_mm) ||
                      (grown && ask.auto_by_stress);
  ll::TensorField field = *job.tensor_field;
  const std::vector<ll::WidthFloor> base_floors = ask.floors;
  std::string laid_with = job.strengthened.empty() ? std::string("job") : job.strengthened;
  for (int n = 0;; ++n) {
    if (stop && stop->load()) return finish(false, "cancelled", 1, "Stopped before the strengthening was finished.");
    const std::string rdir = join_path(out_dir, "r" + std::to_string(n));
    std::error_code ec;
    std::filesystem::create_directories(rdir, ec);
    say("round " + std::to_string(n) + ": laying the lattice");
    auto t0 = std::chrono::steady_clock::now();
    const ll::Outcome out = session.lay_organic(job.settings, field, ask, job.options.threads, stop);
    const double s_lay = secs(t0);
    const double mb_lay = process_memory().rss_mb;
    if (out.cancelled) return finish(false, "cancelled", 1, "Stopped before the strengthening was finished.");
    if (n == 0)
      for (const auto& [region, ref] : out.organic_references) reference = std::max(reference, ref);
    if (stop && stop->load()) return finish(false, "cancelled", 1, "Stopped before the strengthening was finished.");
    // OS16 (brief E4, leg 2): the print check after each lay, so the bars judged are the bars the file writes.
    say("round " + std::to_string(n) + ": checking the lattice prints");
    const ll::PrintChecked pc = ll::print_check_bars(session, out.layout, out.bars, ll::file_options_for(job.options, true), stop);
    if (!pc.ok)
      return finish(false, "print_check_failed", 1, "The lattice's file could not be put together, so its strength cannot be judged.", pc.why);
    say("round " + std::to_string(n) + ": checking its strength");
    const ll::Domain& domain = *session.domain();
    const double light = ask.width_mm > 0.0 ? ask.width_mm : domain.spec().bead_mm * domain.spec().min_strut_lines;
    OrganicCheckRun cr = organic_frame_check(S, domain, pc.bars, &pc.kept, light, rdir, job.options.threads);
    if (!cr.done.ok) return finish(false, cr.done.code, cr.done.exit_code, cr.done.why, cr.done.detail);
    std::ofstream(join_path(rdir, "strength.json")) << cr.done.json << "\n";
    // Brief E3a, item 1: the struts under the watch margin, as strengthening by adding reads them.
    std::ofstream(join_path(rdir, "struts_under.json")) << struts_under_json(cr, ss.watch_margin, ask.width_heavy_mm > 0.0 ? ask.width_heavy_mm : light,
                                                                             nullptr, nullptr, job.print_frame);
    const ll::FrameCheck& c = cr.check;
    // Whether the geometry stays put: a hash of every non-link bar's two end points (rounded to 1e-4 mm, each bar's
    // ends in order, the bars sorted); and the judged struts at the upper strut width.
    std::uint64_t geometry = 1469598103934665603ull;
    {
      std::vector<std::array<long long, 6>> keys;
      for (const ll::Bar& b : out.bars.bars) {
        if (b.link) continue;
        std::array<long long, 3> p{std::llround(b.a.x * 1e4), std::llround(b.a.y * 1e4), std::llround(b.a.z * 1e4)},
            q{std::llround(b.b.x * 1e4), std::llround(b.b.y * 1e4), std::llround(b.b.z * 1e4)};
        if (q < p) std::swap(p, q);
        keys.push_back({p[0], p[1], p[2], q[0], q[1], q[2]});
      }
      std::sort(keys.begin(), keys.end());
      for (const auto& k : keys)
        for (long long v : k)
          for (int byte = 0; byte < 8; ++byte) {
            geometry ^= static_cast<std::uint64_t>(v) >> (8 * byte) & 0xffu;
            geometry *= 1099511628211ull;
          }
    }
    std::size_t at_upper = 0;
    if (ask.width_heavy_mm > 0.0)
      for (const ll::FrameStrut& st : c.struts) at_upper += st.judged && st.width_max >= ask.width_heavy_mm - 1e-9;
    char geometry_hex[17];
    std::snprintf(geometry_hex, sizeof geometry_hex, "%016llx", static_cast<unsigned long long>(geometry));
    std::string r = std::string(rounds_json.empty() ? "\n    " : ",\n    ") + "{\"round\": " + std::to_string(n) +
                    ", \"bars_geometry\": \"" + geometry_hex + "\", \"struts_at_upper_width\": " + std::to_string(at_upper) +
                    ", \"laid_with\": " + json_str(laid_with) + ", \"verdict\": " + json_str(cr.verdict) +
                    ", \"fail_reason\": " + json_str(cr.fail_reason) + ", \"bars\": " + std::to_string(out.bars.bars.size()) +
                    ", \"floors_widened\": " + std::to_string(out.floors_widened) +
                    ", \"floor_links_widened\": " + std::to_string(out.floor_links_widened) +
                    ", \"gap_broken\": " + std::to_string(ll::gap_broken(pc.bars)) +   // OG1 (brief E6)
                    ",\n     \"struts\": {\"judged\": " + std::to_string(c.judged) + ", \"under_safety\": " +
                    std::to_string(c.under_safety) + ", \"under_one\": " + std::to_string(c.under_one) +
                    ", \"smallest_margin\": " + json_num(c.judged ? c.smallest_margin : std::numeric_limits<double>::quiet_NaN()) +
                    ", \"buckling_failures\": " + std::to_string(c.buckling_failures) + ", \"stubs\": " + std::to_string(c.stubs) +
                    ", \"unjudged_mm\": " + json_num(c.unjudged_mm) + ", \"load_unheld_n\": " + json_num(c.load_unheld_n) + "}" +
                    ",\n     \"lattice_mm3\": " + json_num(cr.lattice_mm3) +
                    ", \"seconds\": {\"lay\": " + json_num(std::round(s_lay * 10) / 10) + ", \"material\": " +
                    json_num(std::round(cr.ms_material / 100) / 10) + ", \"voxel_solve\": " +
                    json_num(std::round(cr.ms_voxel / 100) / 10) + ", \"frame\": " + json_num(std::round(cr.ms_frame / 100) / 10) +
                    "}, \"memory_mb\": {\"after_lay\": " + json_num(std::round(mb_lay)) + ", \"after_voxel_solve\": " +
                    json_num(std::round(cr.mb_voxel)) + ", \"after_frame\": " + json_num(std::round(cr.mb_frame)) +
                    ", \"peak\": " + json_num(std::round(process_memory().peak_rss_mb)) + "}, \"check\": " +
                    json_str("r" + std::to_string(n) + "/strength.json");
    const bool clean = c.solved && c.under_safety == 0;
    const bool bare = cr.fail_reason == "load_on_bare_lattice";   // the interim guard: strengthening cannot cure it
    if (clean || bare || !varies || n >= limit || !c.solved) {
      rounds_json += r + "}";
      res.passing = cr.verdict == "pass";
      if (bare) return finish(true, "load_on_bare_lattice", 0, kLoadOnBareLatticeText);
      if (clean) return finish(true, "done", 0, "");
      if (!c.solved) return finish(true, "frame_not_solved", 0, "The frame could not be solved, so there is nothing to strengthen from.");
      if (!varies)
        return finish(true, "nothing_to_vary", 0,
                      "Nothing in this job follows the stress (one spacing and one strut width), so strengthening cannot "
                      "change the lattice.");
      return finish(true, "limit", 0, "The rounds of strengthening allowed were all done.");
    }
    // ── one round: the boosted copy of the stress input, the floors, strengthened.json.
    if (stop && stop->load()) return finish(false, "cancelled", 1, "Stopped before the strengthening was finished.");
    say("round " + std::to_string(n) + ": strengthening the weak struts");
    const std::string ndir = join_path(out_dir, "r" + std::to_string(n + 1));
    std::filesystem::create_directories(ndir, ec);
    ll::TensorField boosted = field;
    ss.reach_mm = S.st.get("strengthen_reach") * out.spacing_mean_mm;   // the result's spacing_used_mm.mean
    const ll::StrengthenRound sr = ll::strengthen_round(cr.frame, cr.check, [&] {
      ll::Bars b;
      for (int i : cr.bar_of) b.bars.push_back(pc.bars.bars[static_cast<std::size_t>(i)]);
      return b;
    }(), boosted, ss);
    std::vector<ll::WidthFloor> floors = base_floors;
    floors.insert(floors.end(), sr.floors.begin(), sr.floors.end());
    ll::Strengthened st;
    st.stress_input = "stress.tensor";
    st.floors = "floors.bin";
    st.reference_mpa = reference;
    const std::string sj = join_path(ndir, "strengthened.json");
    const std::string more = "  \"round\": " + std::to_string(n + 1) + ",\n  \"struts_watched\": " + std::to_string(sr.struts_watched) +
                             ",\n  \"voxels_boosted\": " + std::to_string(sr.voxels_boosted) + ",\n  \"boost_largest\": " +
                             json_num(sr.boost_largest) + ",\n  \"boosted_mm3\": " + json_num(sr.boosted_mm3) +
                             ",\n  \"floors_count\": " + std::to_string(floors.size()) + print_up_json(job.print_frame);
    if (!ll::write_tensor_file(join_path(ndir, st.stress_input), boosted) || !ll::write_floors_file(join_path(ndir, st.floors), floors) ||
        !ll::write_strengthened_file(sj, st, more))
      return finish(false, "cannot_write", 1, "The strengthened files could not be saved on the Mac.", ndir);
    // Lay again from what was written (read back: the file job given this strengthened.json lays the same).
    {
      std::string why;
      ll::OrganicAsk again = job.organic;
      again.floors.clear();
      ll::TensorField read_back;
      if (!ll::apply_strengthened(sj, read_back, again, &why))
        return finish(false, "cannot_write", 1, "The strengthened files could not be read back.", why);
      field = std::move(read_back);
      ask = again;
    }
    res.last_strengthened = "r" + std::to_string(n + 1) + "/strengthened.json";
    ++res.rounds_fixed;
    laid_with = res.last_strengthened;
    rounds_json += r + ",\n     \"wrote\": {\"strengthened\": " + json_str(res.last_strengthened) +
                   ", \"struts_watched\": " + std::to_string(sr.struts_watched) + ", \"voxels_boosted\": " +
                   std::to_string(sr.voxels_boosted) + ", \"boost_largest\": " + json_num(sr.boost_largest) +
                   ", \"floors\": " + std::to_string(floors.size()) + "}}";
  }
}

namespace {
#include "to_setup.inc"  // TO rebuild stage 0: moved unchanged

#include "to_strengthen.inc"  // TO rebuild stage 0: moved unchanged

}  // namespace

#include "to_run.inc"  // TO rebuild stage 0: moved unchanged

}  // namespace topopt
