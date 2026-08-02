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
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/build_frame.hpp"
#include "topopt/clearance.hpp"
#include "topopt/coarsen.hpp"
#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/fields.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
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
  const TriangleMesh& model_mesh = (sf > 1) ? smooth : variant.v3.mesh;
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

LatticeRoleRegions lattice_role_regions_from_job(const JobDescription& job) {
  LatticeRoleRegions rr;
  for (const JobLatticeRegion& r : job.lattice.regions) {
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

LatticeBoundary lattice_boundary_for(const VoxelGrid& sg,
                                     const std::vector<double>& dens,
                                     double cell_mm,
                                     const std::vector<ClearanceGeometry>& kos,
                                     const LatticeRoleRegions& roles) {
  LatticeBoundary B;
  // Window: clipping needs exact distances only out to one cell of slack past
  // the largest erosion; two cells is comfortably conservative.
  B.set_voxel_base(&sg, &dens, 0.5, 2.0 * cell_mm);
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
    double base_cell_mm = 0.0) {
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
          if (!(dens[e] >= 0.5) || cert_mask[e]) continue;
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
  auto emit_lattice = [&](TriangleSink& w) {
    return swept ? generate_lattice_multilevel(LatticeGenTopology::Octet, Rbase,
                                               *levels, w, skin)
                 : generate_lattice(LatticeGenTopology::Octet, R, radius, w, skin);
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
        if (dens[sg.index(i, j, k)] >= 0.5) ++oc.region_voxels;
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
      load_path_connected(sg, variant.optimization.physical_density, 0.5);
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
                              resolve_build_direction_is_inferred(options));
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

  // (1) Null-posture re-cert — MUST reproduce the variant's SOLID margin. This is the
  // live proof that the reconstruction above is faithful (so the latticed margin that
  // shares it is trustworthy). Bit-for-bit by the single-source-of-truth contract.
  const FixedDesignAnalysis solid_recert = analyze_variant_with_posture(
      variant, sg, options, material, bcs, cx, /*post=*/nullptr);
  oc.solid_margin_reproduced = solid_recert.margin.worst_case;
  oc.solid_reproduced =
      (solid_recert.margin.worst_case == variant.report.margin.worst_case);

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
                                     const LatticeAddedMaterialReceipt& added) {
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
    s += "    \"include_void_note\": \"include-region voxels where the optimizer "
         "left no material — a lattice cannot conjure material there, so the "
         "include is a NO-OP on them (reported, not an error)\",\n";
    s += "    \"precedence\": \"clearance beats include and exclude (no material "
         "to lattice); exclude beats include (kept solid); solid-kept material "
         "is certified SOLID and exported as the solid companion body\"\n";
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
    if (a.lattice_strut_out_of_regime)
      s += "    \"regime_note\": \"the thinnest latticed member spans fewer "
           "cells than the measured homogenization floor, so the macro stress "
           "field these strut numbers amplify is itself out of the tensor's "
           "validated regime — treat them as indicative, not certified\",\n";
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
  LatticeAddedMaterialReceipt added_rcpt;  // design-box runs only
  // The DESIGN the mesh was built from and the certification solved on — one
  // number, so "the certified object is the exported one" is checkable rather
  // than merely argued (bar Z3). Both consumers read the SAME `dens` reference
  // below; this fingerprints it once, at the single point they share.
  std::uint64_t design_fingerprint = 0;
};

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
  const VoxelGrid& solved_grid = domain.grid;
  const std::vector<DirichletBC>& bcs = domain.bcs;
  LatticeVariantOutcome R;
  const std::vector<double>& dens = v.optimization.physical_density;
  R.design_fingerprint = design_fingerprint(dens);
  const bool graded = job.grading.present;
  R.graded = graded;
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
  if (graded) {
    LatticeBoundary members;
    for (const ClearanceGeometry& g : lattice_kos)
      members.add_keep_out(g, g.kind == ClearanceKind::Bolt);
    for (const ClearanceGeometry& g : lattice_roles.includes)
      members.add_include_region(g);
    for (const ClearanceGeometry& g : lattice_roles.excludes)
      members.add_exclude_region(g);
    std::vector<char> cand(solved_grid.voxel_count(), 0);
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!(dens[e] >= 0.5)) continue;
          const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                       solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                       solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
          if (members.in_keep_out(c, 0.0)) continue;
          if (members.in_exclude_region(c, 0.0)) continue;
          if (members.has_include_regions() &&
              !members.in_include_region(c, 0.0))
            continue;
          cand[e] = 1;
        }
    GradingLawParams gp;
    gp.topology = LatticeTopology::Octet;  // job schema restricts to octet
    gp.target_cell_size_mm = job.grading.cell_mm;
    gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gp.demand_exponent = job.grading.demand_exponent;
    // Cell-size mode (handoff 2026-08-01-lattice-cell-size-sweep). An absent
    // "cell_mode" parses as "fixed", which is the pre-sweep path exactly.
    if (!cell_size_mode_from_name(job.grading.cell_mode.c_str(), gp.cell_mode))
      throw JobError("run_job: unknown grading cell_mode \"" +
                     job.grading.cell_mode + "\"");
    gp.min_cell_size_mm = job.grading.cell_min_mm;
    gp.max_cell_size_mm = job.grading.cell_max_mm;
    gf = grade_lattice(solved_grid, dens, v.von_mises_field, &cand, gp);
    cell = gf.cell_size_mm;
    // The law's cell. In Fixed/Auto this is THE cell; in Swept it is the COARSEST
    // level the plan used, which is what the boundary window, the cell-overlap
    // proof and the receipt's single scalar all want (the conservative end).
  }
  R.cell_mm = cell;

  // ── THE shared boundary for this variant: its solid density as the base,
  // the resolved clearance keep-outs subtracted, the role regions carried as
  // activation/mask terms. Geometry (a) and certification (b) below both
  // consume this ONE object (bar B7 / H1b).
  const LatticeBoundary boundary = lattice_boundary_for(
      solved_grid, dens, cell, lattice_kos, lattice_roles);

  // ── THE certification mask — shared by the export (companion + graded cell
  // activation) and the posture. On a graded run it is intersected with the
  // law's own mask (voxels the law kept solid drop out; law-masked voxels the
  // shared predicate's cell-overlap proof rejects are counted, not hidden).
  std::vector<char> mask = lattice_certification_mask(
      boundary, solved_grid, dens, 0.5, solved_grid.origin, cell);
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
          if (!(dens[e] >= 0.5)) continue;
          ++added_rcpt.printed_voxels;
          if (in_part[e]) {
            ++added_rcpt.inside_part;
            continue;
          }
          ++added_rcpt.outside_part;
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
    if (domain.expanded) {
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
            if (dens[e] >= 0.5) continue;  // material exists — not the no-op case
            const Vec3 c{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                         solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                         solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
            if (boundary.in_include_region(c, 0.0))
              ++role_rcpt.include_void_voxels;
          }
    }
  }

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
      levels.empty() ? 0.0 : gf.cell_plan.base_cell_mm);
  R.gen_seconds = wall_seconds() - tg0;

  // ── THE AUDIT (design-box runs only, so no existing receipt changes). Measure,
  // against the geometry that was just written, the two things the whole H1b
  // discipline claims: that the cell set the generator EMITTED is the cell set
  // the certification mask implies, and that no voxel got both a strut and
  // companion solid. `emitted_lattice_cells` is the GENERATOR's own count
  // (LatticeGenStats::latticed_cells — cells that passed both the predicate and
  // the boundary-overlap test), not a re-derivation of it.
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
    // A voxel is "companion solid" on exactly the export's own rule: printed,
    // NOT masked, and not inside a clearance keep-out (export_latticed_variant).
    // It is "inside a strut cell" iff its owning cell is one the generator
    // emitted — the same cell_active test, asked here with the same inputs.
    for (int k = 0; k < solved_grid.nz; ++k)
      for (int j = 0; j < solved_grid.ny; ++j)
        for (int i = 0; i < solved_grid.nx; ++i) {
          const std::size_t e = solved_grid.index(i, j, k);
          if (!(dens[e] >= 0.5) || mask[e]) continue;
          const Vec3 vc{solved_grid.origin.x + (i + 0.5) * solved_grid.spacing,
                        solved_grid.origin.y + (j + 0.5) * solved_grid.spacing,
                        solved_grid.origin.z + (k + 0.5) * solved_grid.spacing};
          if (boundary.in_keep_out(vc, 0.0)) continue;  // no companion emitted
          const std::array<int, 3> c = owner_ijk(i, j, k);
          if (cell_latticed && !cell_latticed(c[0], c[1], c[2])) continue;
          const Vec3 cmin{Rdims.origin.x + c[0] * cell,
                          Rdims.origin.y + c[1] * cell,
                          Rdims.origin.z + c[2] * cell};
          if (!boundary.cell_may_overlap(cmin, cell)) continue;
          ++added_rcpt.voxels_strut_and_solid;
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
  R.receipt_json = lattice_cert_report_json(v, job.lattice, R.cc, R.oc, cell,
                                            role_rcpt, grad_rcpt, added_rcpt);
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

// Map a job.json "loads" block onto the front-end-neutral ProductionLoadCase the
// core builder (build_production_loadcase) consumes. This is the ONE mapping —
// run_job's optimize path AND analyze_job's re-certification path both call it, so
// a declared load case is resolved IDENTICALLY whether it is optimized or merely
// analyzed (no second schema, per the loadcase-analyze handoff). Geometric anchor/
// load-face selectors are resolved against `model` here (resolve_selectors THROWS
// a JobError naming any selector that matches nothing — the loud "face does not
// exist" failure), and compose with any raw B-rep face ids. Clearance / face-
// protection / design-box / infill / wall metadata are forwarded verbatim.
ProductionLoadCase production_loadcase_from_job(const JobDescription& job,
                                               const StepModel& model) {
  ProductionLoadCase lc;
  // Anchors: raw B-rep ids (from the app) and/or geometric selectors compose.
  lc.anchor_face_ids = job.loads.anchor_face_ids;
  for (const int id : resolve_selectors(model, job.loads.anchors, "anchors"))
    lc.anchor_face_ids.push_back(id);
  for (const JobLoadGroup& g : job.loads.groups) {
    ProductionLoadCase::LoadGroup lg;
    lg.face_ids = g.face_ids;
    for (const int id : resolve_selectors(model, g.faces, "loads group faces"))
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
  lc.face_protection_face_ids = job.loads.face_protection_face_ids;
  if (job.loads.face_protection_depth_mm > 0.0)
    lc.face_protection_depth_mm = job.loads.face_protection_depth_mm;
  lc.minimize_plastic = job.loads.minimize_plastic;
  lc.build_dir = job.loads.build_dir;
  lc.infill_percent = job.loads.infill_percent;
  lc.wall_loops = job.loads.wall_loops;
  lc.wall_line_width_mm = job.loads.wall_line_width_mm;
  lc.has_design_box = job.has_design_box;
  if (job.has_design_box) {
    lc.design_box = to_design_box(job.design_box);
    for (const JobBox& ko : job.keep_out_boxes)
      lc.keep_out_boxes.push_back(to_design_box(ko));
  }
  return lc;
}

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
      s += "], \"force_mag_n\": " + json_num(g.force_mag) +
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
      s += "    {\"face_id\": " + std::to_string(f.face_id) +
           ", \"voxels_frozen\": " + std::to_string(f.voxels_frozen) +
           ", \"depth_voxels\": " + std::to_string(f.depth_voxels) +
           ", \"thinner_than_depth\": " +
           (f.thinner_than_depth ? "true" : "false") + "}";
      s += (i + 1 < setup->face_protection_reports.size()) ? ",\n" : "\n";
    }
    s += "  ]\n";
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
      !cell_size_mode_from_name(job.grading.cell_mode.c_str(), gp.cell_mode))
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

std::string lattice_forecast_json(const JobDescription& job,
                                  const VoxelGrid& grid,
                                  const StoredDesign& sd,
                                  const std::vector<ClearanceGeometry>& kos,
                                  const LatticeRoleRegions& roles) {
  LatticeBoundary members;
  const std::vector<char> cand =
      forecast_candidates(grid, sd.density, kos, roles, members);
  // The band-floor demand (see the header comment): zeros ⇒ rho_of == 0 ⇒ every
  // candidate clamps to the band's low end.
  const std::vector<double> flat_demand(grid.voxel_count(), 0.0);
  const GradingLawParams gp = forecast_grading_params(job);
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
  // THE REGION counterfactual, always evaluated when include regions exist: what
  // the SAME design would lattice with no region restriction at all. That is the
  // number that tells a user whether their regions are the problem.
  ForecastCounterfactual whole;
  bool whole_ran = false;
  if (!roles.includes.empty()) {
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
    s += ", \"would_lattice_voxels\": " + std::to_string(cf.latticed_voxels) +
         ", \"region_voxels\": " + std::to_string(cf.region_voxels) +
         ", \"latticed_fraction_of_region\": " + json_num(f) + "}";
  };
  for (const ForecastCounterfactual& cf : cfs) emit_cf(cf);
  if (whole_ran) emit_cf(whole);
  s += first ? "],\n" : "\n  ],\n";
  s += "  \"counterfactual_note\": \"every entry above was EVALUATED — the "
       "grading law was re-run with that one parameter changed and the mask it "
       "actually produced is reported. An empty list means no parameter change "
       "could help.\",\n";
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
    if (!cell_size_mode_from_name(job.grading.cell_mode.c_str(), gp.cell_mode))
      throw JobError("analyze: unknown grading cell_mode \"" +
                     job.grading.cell_mode + "\"");
    gp.min_cell_size_mm = job.grading.cell_min_mm;
    gp.max_cell_size_mm = job.grading.cell_max_mm;
    const GradedField gf =
        grade_lattice(design_grid, density, a.von_mises_field, nullptr, gp);

    RunInfo gi = build_run_info(job, options, RunObservability{});
    gi.grading_present = true;
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
    gi.grading_solid_fallback_voxels =
        static_cast<long long>(gf.solid_fallback_voxels);
    gi.grading_min_member_width_mm = gf.min_member_width_mm;
    gi.grading_min_cells_per_member = gf.min_cells_per_member;
    gi.grading_min_strut_diameter_mm = gf.min_strut_diameter_mm;
    gi.grading_max_strut_diameter_mm = gf.max_strut_diameter_mm;
    gi.grading_any_strut_below_min = gf.any_strut_below_min;
    gi.grading_region_ungradeable = gf.region_ungradeable;
    fill_grading_cell_plan(gi, gf);

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
  if (job.mode != "lattice_variant")
    throw JobError(
        "lattice_variant_job: mode must be \"lattice_variant\" (got \"" +
        job.mode + "\")");
  if (!job.variant.present)
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
  const std::string design_path = join_path(job_dir, job.variant.design);
  DesignStore store;
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
  int pick = -1;
  if (job.variant.has_index) {
    if (job.variant.index >= static_cast<int>(store.variants.size()))
      throw JobError("lattice_variant: variant index " +
                     std::to_string(job.variant.index) + " but \"" +
                     job.variant.design + "\" holds only " +
                     std::to_string(store.variants.size()) + " design(s)");
    pick = job.variant.index;
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
        lattice_role_regions_from_job(job));
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
  if (result.solid.non_convergent)
    throw JobError(
        "lattice_variant: the certification solve of the stored design did not "
        "converge (iteration " +
        std::to_string(result.solid.non_convergent_iteration) + ", residual " +
        json_num(result.solid.non_convergent_residual) +
        "). A design whose certification solve the CG cannot resolve is never "
        "certified, and so is never latticed.");
  if (!result.reproduction_exact)
    throw JobError(
        "lattice_variant: the restored design does NOT reproduce the margin the "
        "run recorded for this variant (recorded " +
        json_num(sd.margin_worst_case) + ", reproduced " +
        json_num(result.solid.margin.worst_case) +
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
  const LatticeRoleRegions lattice_roles = lattice_role_regions_from_job(job);
  const LatticeVariantOutcome R =
      lattice_one_variant(v, job, model_grid, domain, options, material,
                          lattice_kos, lattice_roles, out_dir);
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
  prov += "    \"exact\": true,\n";
  prov +=
      "    \"note\": \"ENFORCED, not reported: an inexact reproduction throws "
      "and nothing is written\"\n";
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
  // iPad app (handoff 093): a "loads" block => the shared build_production_loadcase
  // (anchors + declared forces, the app's mode a); otherwise the self-weight +
  // fixture_faces path, now also carrying the production solver config + optional
  // design box so it matches what the app produces for the same input.
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  MinimizePlasticOptions options;
  // The load-case RECEIPT (bar Z2) — built here, where the resolution facts are
  // still in scope, and written once the output directory exists. See
  // loadcase_receipt_json: this is the document a later re-lattice run is
  // compared against to prove it certified under the SAME load case.
  std::string loadcase_receipt;

  if (job.loads.present) {
    // ── LOADCASE mode: resolve the geometric selectors to face ids, build the
    // front-end-neutral ProductionLoadCase, and hand it to the SAME core builder
    // the bridge calls. The CLI and app therefore produce the same design for the
    // same STEP + load case + resolution.
    const ProductionLoadCase lc =
        production_loadcase_from_job(job, result.model);
    result.fixture_face_ids = lc.anchor_face_ids;

    ProductionRunSetup setup;
    try {
      setup = build_production_loadcase(result.model, job.resolution, lc);
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
      loadcase_receipt = loadcase_receipt_json(job, &echo,
                                               result.fixture_face_ids, 0, bcs);
    }
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
    loadcase_receipt = loadcase_receipt_json(
        job, nullptr, result.fixture_face_ids, tagged, bcs);

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
  if (job.has_warm_start) options.warm_start_coarse = job.warm_start_coarse;

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
    double r_min = 1e30, r_max = 0.0;
    double wall_s = 0.0;
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
      job.lattice.present ? lattice_role_regions_from_job(job)
                          : LatticeRoleRegions{};
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
    }
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
    run_info.lattice_export_strut_radius_min_mm = lat_agg.r_min;
    run_info.lattice_export_strut_radius_max_mm = lat_agg.r_max;
    run_info.lattice_export_latticed_cells = lat_agg.cells;
    run_info.lattice_export_region_voxels = lat_agg.voxels;
    run_info.lattice_export_triangles = lat_agg.tris;
    run_info.lattice_export_variant_count = lat_agg.variants;
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
  const std::string design_stream_path = join_path(out_dir, "design.bin");
  std::vector<MinimizePlasticVariant> design_so_far;
  auto publish_design_so_far = [&](const MinimizePlasticVariant& v) {
    // A TRIMMED copy — only what design_store reads — so holding the ladder's
    // designs alongside the pipeline's own costs one density field per rung.
    MinimizePlasticVariant d;
    d.requested_volume_fraction = v.requested_volume_fraction;
    d.optimization.volume_fraction = v.optimization.volume_fraction;
    d.optimization.physical_density = v.optimization.physical_density;
    d.optimization.iterations = v.optimization.iterations;
    d.report.margin.worst_case = v.report.margin.worst_case;
    d.report.margin_effective = v.report.margin_effective;
    d.report.max_stress_mpa = v.report.max_stress_mpa;
    d.accepted = v.accepted;
    d.applied_build_dir = v.applied_build_dir;
    d.build_direction_auto_applied = v.build_direction_auto_applied;
    d.export_baked = v.export_baked;
    design_so_far.push_back(std::move(d));
    // Best-effort: a design container that cannot be written must never take a
    // run down. The final write still throws — that one is the contract.
    try {
      write_design_file(design_stream_path, design_so_far, solved_grid);
    } catch (const std::exception&) {
    }
  };
  if (emit_progress) {
    options.progress = [](std::size_t rung, std::size_t rungs, int iter) {
      std::printf("PROGRESS rung=%zu rungs=%zu iter=%d\n", rung, rungs, iter);
      std::fflush(stdout);
    };
    options.on_variant = [&](const MinimizePlasticVariant& v) {
      // BEFORE the accepted guard: the final container holds every evaluated
      // variant that carries a field, so the running one must too, or a rejected
      // rung would appear and disappear depending on when you looked.
      publish_design_so_far(v);
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
      // Latticed companion (streaming path): generated + checkpointed as the
      // variant completes, alongside the solid mesh.
      emit_lattice(v, /*stream_lines=*/true);
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
          variant, out_dir, job.output, result.pipeline.solved_grid));
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
