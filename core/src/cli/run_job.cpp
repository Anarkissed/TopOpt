#include "topopt/job.hpp"

#include <algorithm>
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

#include "topopt/analyze.hpp"
#include "topopt/clearance.hpp"
#include "topopt/fea.hpp"
#include "topopt/fields.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/observability.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/part.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/smooth.hpp"
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
  // Handoff 2026-07-25-draft-quality — the armed draft posture (config echo). The
  // per-rung tail-k / gap / escalated vectors are filled post-run (finalize below).
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

}  // namespace

AnalyzeJobResult analyze_job(const JobDescription& job, const std::string& job_dir,
                             const std::string& out_dir,
                             const MaterialLibrary& materials,
                             const SettingsRules& rules,
                             const std::string& analyze_mesh_path,
                             const SmoothRequest& smooth) {
  // Self-weight only for now — a declared "loads" block needs the loadcase
  // grid/BC construction (build_production_loadcase), not yet wired here.
  if (job.loads.present)
    throw JobError(
        "analyze: jobs with a \"loads\" block are not yet supported "
        "(self-weight jobs only)");

  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;

  AnalyzeJobResult result;

  // ── import the ORIGINAL model (the BCs are keyed on ITS fixture faces) ───────
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

  // ── the model grid: the fixture BCs and the printed-fraction BASELINE ────────
  // Voxelize the model and tag its fixture faces. The fixture NODE indices and the
  // part-solid count are geometry (independent of which design we analyse), so we
  // take them from the model grid and reuse them for any same-geometry design.
  VoxelGrid model_grid = voxelize(result.model.mesh, job.resolution);
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
  std::vector<DirichletBC> bcs;
  for (const int n : fea_tagged_nodes(model_grid, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
  const double part_solid = static_cast<double>(model_grid.solid_count());

  // ── the FIXED design to analyse (its OWN occupancy grid) ─────────────────────
  // `design_grid` carries the solid tags of the geometry being certified (so the
  // stress solve's printed-voxel gate matches it and self-weight is the design's
  // own weight); `density` is that occupancy as a binary field. Same voxel geometry
  // as `model_grid`, so the fixture node indices above stay valid.
  if (smooth.enabled && analyze_mesh_path.empty())
    throw JobError("analyze: --smooth requires a --mesh input to smooth");

  VoxelGrid design_grid = model_grid;
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
    // (bores + pads); the min-feature constraint is evaluated against model_grid.
    TriangleMesh design_mesh = edited.mesh;
    if (smooth.enabled) {
      const TaubinParams params =
          taubin_params_for_strength(smooth.strength, smooth.max_pairs);
      SmoothConstraints c;
      c.freeze_regions = freeze_regions_from_faces(
          result.model, result.fixture_face_ids, model_grid.spacing);
      c.freeze_tol_mm = smooth.freeze_tol_mm;
      c.min_feature_grid = &model_grid;
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
      write_stl_file(result.smoothed_mesh_path, design_mesh);
    }

    // Re-voxelize the (smoothed) mesh onto the MODEL's grid geometry, then carry
    // the model's fixture tags over so the same clamp applies. The occupancy is
    // the design; the quantization gap (mesh surface vs this voxelization) is
    // disclosed in the provenance record below.
    design_grid = voxelize_onto_grid(design_mesh, model_grid);
    for (std::size_t i = 0; i < design_grid.tags.size(); ++i)
      if (model_grid.tags[i] == VoxelTag::Fixture &&
          design_grid.tags[i] != VoxelTag::Empty)
        design_grid.tags[i] = VoxelTag::Fixture;
    result.analyzed_mesh = true;
    result.analyzed_mesh_path = analyze_mesh_path;
    result.mesh_mass_grams =
        material.density_g_cm3 * mesh_enclosed_volume_mm3(design_mesh) / 1000.0;
  }
  std::vector<double> density(design_grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < density.size(); ++i)
    if (design_grid.tags[i] != VoxelTag::Empty) density[i] = 1.0;

  // ── production solver config + self-weight load case (as run_job applies) ────
  MinimizePlasticOptions options;
  configure_production_options(options);
  options.margin_stop = job.margin_stop;
  options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
  options.gravity_direction = job.gravity.direction;

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ARCHITECTURE §4 (density_min stays the 1e-3 default)

  const Vec3 build_dir = normalized(Vec3{-options.gravity_direction.x,
                                         -options.gravity_direction.y,
                                         -options.gravity_direction.z});
  const std::vector<NodalLoad> loads =
      self_weight_loads(design_grid, material.density_g_cm3, options.gravity,
                        options.gravity_direction);
  const bool load_path_ok = load_path_connected(design_grid, density, 0.5);
  // The gate knockdown posture (handoff 2026-07-26-width-aware-knockdown), built
  // from the SAME options the originating run used so a standalone re-analysis gates
  // on the identical rule. THE ONE builder (knockdown_spec_for) — shared with the
  // optimizer's per-rung gate and the on-device bridge so all three agree by
  // construction. width_aware defaults false → the scalar f^1.5 gate.
  const KnockdownSpec knockdown = knockdown_spec_for(options);

  // ── THE single analysis solve — no optimization ─────────────────────────────
  result.analysis = analyze_fixed_design(
      design_grid, params, density, bcs, loads, material, build_dir,
      options.simp.cg_tolerance, options.simp.cg_max_iterations,
      options.simp.solver, options.margin_stop, knockdown, load_path_ok,
      part_solid);
  const FixedDesignAnalysis& a = result.analysis;
  result.voxel_mass_grams = a.mass_grams;

  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("analyze: cannot create output directory " + out_dir + ": " +
                     ec.message());
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
  vr.orientation = build_dir;
  vr.settings =
      recommend_settings(rules, material.family, a.margin.worst_case, part_dim_mm);
  vr.min_feature_violations = a.v3.min_feature_violations;
  vr.min_feature_warning =
      min_feature_warning_text(rules, a.v3.min_feature_violations);
  vr.accepted = a.accepted;
  vr.margin_required = job.margin_stop;
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
  write_fields_file(result.fields_path, fields_result, design_grid);

  // ── analysis.json — the PROVENANCE record (task items 3–5) ───────────────────
  // "smoothed / re-analyzed": analyzed=true, the source, the resolution, BOTH mass
  // figures, and the quantization footnote. The pre-analysis numbers NEVER appear.
  std::string prov;
  prov += "{\n";
  prov += "  \"provenance\": \"smoothed / re-analyzed\",\n";
  prov += "  \"analyzed\": true,\n";
  prov += "  \"optimization\": false,\n";
  prov += "  \"source\": " +
          json_str(result.analyzed_mesh ? ("mesh:" + analyze_mesh_path)
                                        : "model_solid") +
          ",\n";
  prov += "  \"model\": " + json_str(job.model) + ",\n";
  prov += "  \"resolution\": " + std::to_string(job.resolution) + ",\n";
  prov += "  \"voxel_mass_grams\": " + json_num(result.voxel_mass_grams) + ",\n";
  prov += "  \"mesh_mass_grams\": " +
          (result.analyzed_mesh ? json_num(result.mesh_mass_grams)
                                : std::string("null")) +
          ",\n";
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
  prov += "  \"margin_required\": " + json_num(job.margin_stop) + ",\n";
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
        else if (jc.face_id >= 0 && jc.face_id < result.model.face_count)
          bore_r = result.model.faces[static_cast<std::size_t>(jc.face_id)]
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
    lc.wall_loops = job.loads.wall_loops;
    lc.wall_line_width_mm = job.loads.wall_line_width_mm;
    lc.wall_line_width_outer_mm = job.loads.wall_line_width_outer_mm;
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

    // ──▶ voxelize + tag the fixture voxels of every matched face. The tag call
    // is source-appropriate in NAME only (tag_mesh_face and tag_step_face run
    // the identical scan over `triangle_face`); a mesh pseudo-face tags exactly
    // as a B-rep face does.
    grid = voxelize(result.model.mesh, job.resolution);
    std::size_t tagged = 0;
    for (const int f : result.fixture_face_ids)
      tagged += model_is_mesh
                    ? tag_mesh_face(grid, result.model, f, VoxelTag::Fixture)
                    : tag_step_face(grid, result.model, f, VoxelTag::Fixture);
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
    // Lattice certification posture (handoff 2026-07-27-lattice-certification): the
    // RunInfo record CARRIES the posture (topology / cell size / rho range / region
    // size), and the serializer emits it when `lattice_present`. It is left unset here
    // because the optimize path's certification lives inside the minimize_plastic
    // pipeline (no FixedDesignAnalysis is surfaced at this level) AND no production job
    // declares a lattice region yet — the region/grading front-end is a separate task.
    // So every current run emits NO lattice key and run_info.json is byte-identical.
    // The certification ENGINE records the full posture in FixedDesignAnalysis today;
    // surfacing it here is a mechanical copy once a posture reaches this level.
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
