// Implementation of the TopOptBridge facade (ROADMAP M7.1). All heavy includes
// — the topopt core headers, and through them OCCT/Eigen — live here, never in
// the header the Swift importer sees. Core exceptions are caught and converted
// to BridgeError so nothing throws across the language boundary.
#include "TopOptBridge.hpp"

#include "topopt/grading.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <exception>
#include <functional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <os/log.h>
#endif

#include "topopt/analyze.hpp"
#include "topopt/build_orientation.hpp"
#include "topopt/clearance.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/gate_diagnosis.hpp"
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/version.hpp"
#include "topopt/voxel.hpp"

namespace topoptbridge {
namespace {

// M7.diag (on-device optimize silent-failure): a run that stalls in the core
// setup/solve emits NO C++ exception, so the app has nothing to surface and the
// run appears to "hang at 0%". These checkpoints trace each setup step to the
// unified log (os_log on Apple → Console.app + Xcode; stderr elsewhere) so the
// LAST line printed before a stall pinpoints where the run is stuck, and the
// per-step counts (loads/anchors/grid dims/bbox) capture the exact load case the
// solver was handed on device. Cheap: a handful of lines per run, not per
// iteration. Prefix is greppable in a noisy device log.
void bridge_log(const std::string& msg) {
#if defined(__APPLE__)
  os_log(OS_LOG_DEFAULT, "[TopOptBridge] %{public}s", msg.c_str());
#else
  std::fprintf(stderr, "[TopOptBridge] %s\n", msg.c_str());
  std::fflush(stderr);
#endif
}

// One-line summary of a voxel grid: dims, spacing, min/max corners (bbox) and
// solid-voxel count — the STEP-2 "grid dims + bbox" the diagnosis asks be logged.
std::string grid_summary(const topopt::VoxelGrid& g) {
  const double mx = g.origin.x + g.nx * g.spacing;
  const double my = g.origin.y + g.ny * g.spacing;
  const double mz = g.origin.z + g.nz * g.spacing;
  return "grid " + std::to_string(g.nx) + "x" + std::to_string(g.ny) + "x" +
         std::to_string(g.nz) + " spacing=" + std::to_string(g.spacing) +
         " bbox=[" + std::to_string(g.origin.x) + "," + std::to_string(g.origin.y) +
         "," + std::to_string(g.origin.z) + "]..[" + std::to_string(mx) + "," +
         std::to_string(my) + "," + std::to_string(mz) + "] solid=" +
         std::to_string(g.solid_count());
}

// TriangleMesh -> ImportedMesh (flattened buffers + watertight flag). `faces`
// (optional) is the STEP's per-B-rep-face geometry (StepModel::faces, size
// face_count); when present it is flattened into the additive per-face geometry
// arrays so the app can draw clearance volumes from the exact axis/radius/normal
// the core rasterizer uses. Null (STL) → those arrays stay empty.
ImportedMesh to_imported(const topopt::TriangleMesh& m,
                         const std::vector<int>* face_ids, int face_count,
                         const std::vector<topopt::StepFaceInfo>* faces = nullptr) {
  ImportedMesh out;
  out.vertices.reserve(m.vertices.size() * 3);
  for (const auto& v : m.vertices) {
    out.vertices.push_back(static_cast<float>(v.x));
    out.vertices.push_back(static_cast<float>(v.y));
    out.vertices.push_back(static_cast<float>(v.z));
  }
  out.indices.reserve(m.triangles.size() * 3);
  for (const auto& t : m.triangles) {
    out.indices.push_back(t[0]);
    out.indices.push_back(t[1]);
    out.indices.push_back(t[2]);
  }
  if (face_ids) out.face_ids.assign(face_ids->begin(), face_ids->end());
  out.vertex_count = static_cast<int32_t>(m.vertices.size());
  out.triangle_count = static_cast<int32_t>(m.triangle_count());
  out.face_count = face_count;
  out.watertight = topopt::check_watertight(m).watertight;

  // Additive per-face geometry (keep-clear v2). Kind int matches
  // topopt::StepSurfaceKind (Plane=0, Cylinder=1, Other=2); vec3 fields are xyz
  // triples indexed by face id. No behaviour change: purely extra output.
  if (faces) {
    const std::size_t n = faces->size();
    out.face_kinds.reserve(n);
    out.face_cyl_radius.reserve(n);
    out.face_axis_point.reserve(n * 3);
    out.face_axis_dir.reserve(n * 3);
    out.face_plane_normal.reserve(n * 3);
    out.face_plane_origin.reserve(n * 3);
    auto push3 = [](std::vector<double>& dst, const topopt::Vec3& v) {
      dst.push_back(v.x);
      dst.push_back(v.y);
      dst.push_back(v.z);
    };
    for (const auto& f : *faces) {
      int kind = 2;  // Other
      switch (f.kind) {
        case topopt::StepSurfaceKind::Plane: kind = 0; break;
        case topopt::StepSurfaceKind::Cylinder: kind = 1; break;
        case topopt::StepSurfaceKind::Other: kind = 2; break;
      }
      out.face_kinds.push_back(kind);
      out.face_cyl_radius.push_back(f.cylinder_radius_mm);
      push3(out.face_axis_point, f.axis_point);
      push3(out.face_axis_dir, f.axis_dir);
      push3(out.face_plane_normal, f.plane_normal);
      push3(out.face_plane_origin, f.plane_origin);
    }
  }
  return out;
}

// ImportedMesh -> TriangleMesh (for export).
topopt::TriangleMesh from_imported(const ImportedMesh& mesh) {
  topopt::TriangleMesh tm;
  tm.vertices.reserve(mesh.vertices.size() / 3);
  for (std::size_t i = 0; i + 2 < mesh.vertices.size(); i += 3) {
    tm.vertices.push_back(topopt::Vec3{mesh.vertices[i], mesh.vertices[i + 1],
                                       mesh.vertices[i + 2]});
  }
  tm.triangles.reserve(mesh.indices.size() / 3);
  for (std::size_t i = 0; i + 2 < mesh.indices.size(); i += 3) {
    tm.triangles.push_back(
        {mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]});
  }
  return tm;
}

// (handoff 134 removed the local extension sniffing here — the core's
// `part_format_for_path` is the single place that classifies a path now.)

// Import any supported geometry by file extension (handoff 134: this is now
// the core's own adapter, so STEP / STL / 3MF all arrive here through ONE
// code path and a mesh gets the same weld + normal-unification repair the
// face-carrying import does). The core reports STEP-without-OCCT and
// 3MF-without-lib3mf itself, with the message the app surfaces.
topopt::TriangleMesh import_any(const std::string& path) {
  return topopt::import_part_file(path).mesh;
}

// The recommendation ladder (recommendation-driven variants): finer + lower than
// the old fixed {0.7, 0.5, 0.3}, so minimize_plastic's margin-SAFE prefix ADAPTS
// to the part + load case (a stronger part keeps lighter rungs, a weaker one shows
// fewer/heavier ones) and the lightest safe rung is the recommendation the app
// surfaces. minimize_plastic stops at the first rung below margin_stop, so this
// never returns an unsafe variant — it just walks further down for strong parts.
// The literal lives in ONE place (production_reduction_ladder) so the bridge and
// the CLI cannot drift; this wrapper keeps the call sites/local name unchanged.
std::vector<double> reduction_ladder() {
  return topopt::production_reduction_ladder();
}

// M7.anchor-integrity (FIX 1) — the FrozenSolid structural pad behind each
// anchor/load face is now built inside build_production_loadcase (core), so the
// depth constant lives there too (kProductionAnchorPadDepthVoxels). See the
// shared builder in core/loadcase.hpp.

// M7.anchor-integrity (FIX 2) — WITHDRAWN (diagnosis 084-ladder-collapse-diagnosis). The
// "ladder floor" halted the walk at the first accepted rung whose worst-case margin
// cleared `margin_floor_multiple * margin_stop` (2 * 1.5 = 3.0). Because the ladder
// walks HEAVIEST -> lightest and margin is highest at rung 0 (the heaviest, most
// material), that test fires at rung 0 for any comfortably-strong part — collapsing
// the savings ladder to a SINGLE rung and hiding exactly the lighter, higher-savings
// variants the product recommends (the lightest safe rung). It stripped material
// removal precisely when the part was safest to continue: backwards for a savings
// ladder. It was domain-independent (set on BOTH the no-box and box loadcase paths),
// so it regressed the no-box ladder too (PR #64), not just the design-box path; the
// no-box collapse was masked only because the historical 4-rung runs predate it.
// Anchor integrity is served by FIX 1 (the frozen structural pad), not by truncating
// the ladder. margin_floor_multiple stays in the core API defaulting to +infinity
// (disabled); the bridge no longer turns it on, restoring walk-to-lightest-safe-rung.
// If a "don't over-recommend an aggressive strip" behavior is ever wanted, it belongs
// at the recommendation-SELECTION layer (which rung to highlight), never as a walk
// terminator that deletes the other rungs. See docs/handoffs/084-ladder-collapse-diagnosis-*.

// The solver, projection, physical min-feature length scale and Galerkin block
// cache that used to be set inline here (M6.3 projection + M7.rmin min-feature +
// the handoff 079/091 matrix-free solver + cache) now live in ONE shared place,
// topopt::configure_production_options (core/production.hpp), which BOTH this
// bridge and topopt-cli call — see the divergence audit in handoff 093. The
// bridge sets the load case (loads, ladder, box, anchor pad, gravity, keyframes)
// and then calls configure_production_options for the shared solver config.

// Smooth-export tessellation factor (handoff 087-wire-smooth-export, building on
// core handoff 086-surface-resample). The optimizer's physical density is a
// GRAYSCALE ramp ~1 min-feature radius wide (~4.7 mm at 64^3 / 3.125 mm); native
// marching cubes tessellates that smooth ramp with ~3.1 mm facets, so the curved
// iso-surface reads as terracing. Re-extracting the SAME 0.5 iso-surface from the
// SAME field resampled `factor`x finer (tricubic Catmull-Rom, ~6x more faithful
// than trilinear per 086) is PURE GEOMETRY — no new design detail, no ML — and
// removes the faceting. 2x is 086's recommendation: it clears the terracing at
// ~100 ms / variant and a triangle count the iPad viewer handles comfortably.
//
// SEAM (STEP 1): the app has ONE mesh per variant — the bridge sends v.mesh()
// (v3.mesh) as mesh_vertices/mesh_indices, and it is the ONLY geometry the app
// has: the viewer renders it and the (M7.9) export will write it. File export is
// still a placeholder today, so the DISPLAYED mesh is the only thing visible on
// device — smoothing it is the only way the fix reaches the maintainer's screen.
// So we smooth the single shared mesh (display + future export) rather than add a
// separate export-only buffer that nothing would render. factor 1 sends v.mesh()
// verbatim (byte-identical to today); factor > 1 re-extracts from solved_grid.
constexpr int kSmoothExportFactor = 2;

// The mesh the bridge hands the app for a variant: v.mesh() (v3.mesh) at factor 1,
// or the SAME iso-surface re-extracted `factor`x finer at factor > 1. Mirrors the
// CLI seam (run_job.cpp): resample variant.optimization.physical_density on the
// SOLVED grid (NOT a re-derived one — handoff 082 grid-mismatch guard) and keep
// the largest component, exactly the call the CLI export uses. Falls back to
// v.mesh() when the variant has no displayed mesh (a cancelled rung, whose per-
// rung analysis — hence physical_density-as-a-surface — was skipped) or when the
// field does not match the grid, so cancelled/edge cases stay byte-identical.
const topopt::TriangleMesh& export_display_mesh(
    const topopt::MinimizePlasticVariant& v, const topopt::VoxelGrid& solved_grid,
    int factor, topopt::TriangleMesh& scratch) {
  const topopt::TriangleMesh& raw_display = v.mesh();
  if (factor <= 1 || raw_display.vertices.empty() ||
      v.optimization.physical_density.size() != solved_grid.voxel_count())
    return raw_display;
  scratch = topopt::keep_largest_component(topopt::marching_cubes_resampled(
      solved_grid.nx, solved_grid.ny, solved_grid.nz, solved_grid.spacing,
      solved_grid.origin, v.optimization.physical_density, /*iso=*/0.5, factor,
      topopt::ResampleInterp::Tricubic));
  return scratch;
}

// One core variant -> the flat bridge OptimizeVariant (M7.0b/M7.8 fields). Shared
// by the result builder AND the progressive-results stream, so there is one source
// of truth for the mapping. `solved_grid` is the grid the variant's fields are
// indexed to (mp.solved_grid) and `smooth_factor` the export/display tessellation.
OptimizeVariant to_optimize_variant(const topopt::MinimizePlasticVariant& v,
                                    const topopt::VoxelGrid& solved_grid,
                                    int smooth_factor) {
  OptimizeVariant ov;
  ov.requested_volume_fraction = v.requested_volume_fraction;
  // Handoff 104: the app's savings basis is the PRINTED/count fraction, so it stays
  // in lock-step with the reported mass (savings = 1 - achieved can never disagree
  // with mass). Read it from v.report.printed_fraction rather than
  // v.optimization.volume_fraction — the latter reverted to the optimizer's
  // CONTINUOUS achieved fraction on the no-box path (102/104), which would silently
  // change the displayed savings. On the box path the two are equal (080), so this
  // is byte-identical there. `printed_fraction` carries the same value by name.
  ov.achieved_volume_fraction = v.report.printed_fraction;
  ov.printed_fraction = v.report.printed_fraction;
  ov.mass_grams = v.mass_grams;
  ov.support_volume_voxels = v.support_volume_voxels;
  // The exported/displayed surface: smoothed at smooth_factor > 1, else v.mesh().
  topopt::TriangleMesh smoothed_scratch;
  const topopt::TriangleMesh& vm =
      export_display_mesh(v, solved_grid, smooth_factor, smoothed_scratch);
  ov.mesh_triangle_count = static_cast<int32_t>(vm.triangle_count());
  ov.worst_case_margin = v.report.margin.worst_case;
  ov.accepted = v.accepted;
  ov.v3_passes = v.v3.passes;
  ov.min_feature_violations =
      static_cast<int32_t>(v.report.min_feature_violations);
  ov.min_feature_warning = v.report.min_feature_warning;
  ov.orientation_x = v.report.orientation.x;
  ov.orientation_y = v.report.orientation.y;
  ov.orientation_z = v.report.orientation.z;
  // WHY the verdict is what it is (handoff 2026-08-02-gate-diagnosis-
  // recommendations). Emitted through the CORE's ONE emitter, so the on-device
  // dialog and a LAN run's report.json carry the identical document. Empty when
  // the run did not arm the diagnosis.
  if (v.report.diagnosis.evaluated)
    topopt::emit_gate_diagnosis(ov.diagnosis_json, v.report.diagnosis, "");
  // WHERE THIS VARIANT'S PLASTIC IS (task 2026-08-03-growth-ladder) — the core's
  // own AddedMaterialReport, carried across verbatim. Unevaluated (all zeros) on
  // every reduction run, so nothing about the existing results screen moves.
  {
    const topopt::AddedMaterialReport& a = v.report.added_material;
    ov.added_material_evaluated = a.evaluated;
    ov.added_printed_voxels = a.printed_voxels;
    ov.added_inside_part = a.inside_part;
    ov.added_outside_part = a.outside_part;
    ov.added_part_solid_voxels = a.part_solid_voxels;
    ov.added_outside_fraction = a.outside_fraction;
    ov.added_outside_volume_mm3 = a.outside_volume_mm3;
    ov.added_net_volume_mm3 = a.net_added_volume_mm3;
    ov.added_outside_mass_grams = a.outside_mass_grams;
    ov.added_net_mass_grams = a.net_added_mass_grams;
    ov.growth_target_saturated = v.report.growth_target_saturated;
  }
  ov.max_stress_mpa = v.report.max_stress_mpa;
  ov.max_interlayer_tension_mpa = v.report.max_interlayer_tension_mpa;
  ov.in_plane_margin = v.report.margin.in_plane;
  ov.interlayer_margin = v.report.margin.interlayer;
  ov.mesh_vertices.reserve(vm.vertices.size() * 3);
  for (const auto& p : vm.vertices) {
    ov.mesh_vertices.push_back(static_cast<float>(p.x));
    ov.mesh_vertices.push_back(static_cast<float>(p.y));
    ov.mesh_vertices.push_back(static_cast<float>(p.z));
  }
  ov.mesh_indices.reserve(vm.triangles.size() * 3);
  for (const auto& t : vm.triangles) {
    ov.mesh_indices.push_back(t[0]);
    ov.mesh_indices.push_back(t[1]);
    ov.mesh_indices.push_back(t[2]);
  }
  ov.von_mises_field.assign(v.von_mises_field.begin(), v.von_mises_field.end());
  // Per-voxel Cauchy stress tensor, same mechanism as von Mises (double -> float
  // narrowing). Flattened Voigt [xx,yy,zz,xy,yz,zx], TRUE shear; size
  // 6*voxel_count, empty for a cancelled rung.
  ov.stress_tensor_field.assign(v.stress_tensor_field.begin(),
                                v.stress_tensor_field.end());
  // M7.disp: the per-node displacement field, same mechanism as von Mises
  // (double -> float narrowing for the Metal vertex animation, M7.viz.3).
  ov.displacement_field.assign(v.displacement_field.begin(),
                               v.displacement_field.end());
  // Playback keyframes, flattened (scalar vectors only).
  for (const topopt::TriangleMesh& km : v.keyframe_meshes) {
    ov.keyframe_vertex_counts.push_back(static_cast<int32_t>(km.vertices.size()));
    for (const auto& p : km.vertices) {
      ov.keyframe_vertices.push_back(static_cast<float>(p.x));
      ov.keyframe_vertices.push_back(static_cast<float>(p.y));
      ov.keyframe_vertices.push_back(static_cast<float>(p.z));
    }
    ov.keyframe_index_counts.push_back(
        static_cast<int32_t>(km.triangles.size() * 3));
    for (const auto& t : km.triangles) {
      ov.keyframe_indices.push_back(t[0]);
      ov.keyframe_indices.push_back(t[1]);
      ov.keyframe_indices.push_back(t[2]);
    }
  }
  return ov;
}

// Set the run's grid metadata (dims/origin/spacing/voxel-volume) on `result`.
void set_grid_metadata(OptimizeResult& result, const topopt::VoxelGrid& grid) {
  result.voxel_volume_mm3 = grid.voxel_volume();
  result.grid_nx = grid.nx;
  result.grid_ny = grid.ny;
  result.grid_nz = grid.nz;
  result.grid_origin_x = grid.origin.x;
  result.grid_origin_y = grid.origin.y;
  result.grid_origin_z = grid.origin.z;
  result.spacing = grid.spacing;
}

// MinimizePlasticResult + grid -> the flat OptimizeResult the Swift side reads.
OptimizeResult to_optimize_result(const topopt::MinimizePlasticResult& mp,
                                  const topopt::VoxelGrid& grid) {
  OptimizeResult result;
  result.stopped_on_margin = mp.stopped_on_margin;
  // WHICH LADDER RAN (task 2026-08-03-growth-ladder) — the core's own flag, not an
  // inference from the rung numbers, so the results screen can NAME the mode.
  result.growth_ladder = mp.growth_ladder;
  result.cancelled = mp.cancelled;
  result.accepted_count = static_cast<int32_t>(mp.report.variants.size());
  set_grid_metadata(result, grid);
  // `grid` here is mp.solved_grid (the caller passes it, loadcase path) or the
  // no-box selfweight grid, which equals solved_grid — the grid every variant's
  // physical_density is indexed to. Smooth the export/display mesh against it.
  for (const auto& v : mp.evaluated)
    result.variants.push_back(
        to_optimize_variant(v, grid, kSmoothExportFactor));
  // The BUILD-ORIENTATION RECEIPT (handoff 2026-08-01-build-direction-separation)
  // for the rung the run itself recommends — the LIGHTEST ACCEPTED variant, i.e.
  // the design the user is actually going to print. Produced by the CORE's ONE
  // emitter, so the iPad shows exactly the document topopt-cli writes to disk.
  // Empty (default) unless the load case armed the ranking, so an un-armed run
  // returns byte-identically what it always did.
  for (const auto& v : mp.evaluated)
    if (v.accepted && v.build_orientation.evaluated)
      result.build_orientation_json = topopt::build_orientation_report_json(
          v.build_orientation, v.report.orientation);
  return result;
}

// Wire the core on_variant callback to a C VariantFn: package each streamed
// variant as a one-variant OptimizeResult (carrying the run's grid metadata, which
// the Swift side needs to build a live results view) and hand it across.
void set_variant_stream(topopt::MinimizePlasticOptions& opts,
                        const topopt::VoxelGrid& grid, VariantFn variant_fn,
                        void* variant_ctx) {
  if (variant_fn == nullptr) return;
  // The second parameter (every rung so far) is unused here: this callback
  // packages the ONE variant that just completed and hands it across immediately.
  opts.on_variant = [variant_fn, variant_ctx,
                     &grid](const topopt::MinimizePlasticVariant& v,
                            const std::vector<topopt::MinimizePlasticVariant>&) {
    OptimizeResult one;
    one.accepted_count = 1;
    // A streamed variant carries the ladder mode too — a live results view must
    // not read a growth rung's numbers as reduction numbers while the run is
    // still going (task 2026-08-03-growth-ladder). Derived from the rung itself,
    // which is all this callback has, and equal to mp.growth_ladder by
    // construction (the ladder is all-growth or all-reduction; minimize_plastic
    // refuses a mixed one).
    one.growth_ladder = v.requested_volume_fraction > 1.0;
    set_grid_metadata(one, grid);
    // `grid` is the solved grid (minimize_plastic_solved_grid, captured by ref):
    // the same grid the streamed variant's physical_density is indexed to.
    one.variants.push_back(to_optimize_variant(v, grid, kSmoothExportFactor));
    variant_fn(variant_ctx, &one);
  };
}

// Unflatten a BridgeLoadCase into the front-end-neutral ProductionLoadCase that
// build_production_loadcase consumes. The ONE mapping shared by the optimize path
// (run_minimize_plastic_loadcase) and the re-certification path (analyze_loadcase),
// so a smoothed part is re-certified under EXACTLY the load case it was optimized
// under — no second, drifting copy ([[knockdown-spec-shared-builder]]). `model`
// supplies the bore radius an auto-bolt clearance reads from the STEP.
topopt::ProductionLoadCase production_loadcase_from_bridge(
    const BridgeLoadCase& load_case, const topopt::StepModel& model) {
  topopt::ProductionLoadCase lc;
  lc.anchor_face_ids.assign(load_case.anchor_face_ids.begin(),
                            load_case.anchor_face_ids.end());
  // ── THE REGION LAYER, UNFLATTENED (task 2026-08-14-face-regions §1) ────────
  // The on-device run reads the SAME ProductionLoadCase::face_regions the LAN
  // job.json produces, so a union or a split behaves identically wherever the
  // user taps Optimize. Empty arrays => no regions => byte-identical.
  {
    const std::size_t n = load_case.region_ids.size();
    std::size_t add_off = 0, rem_off = 0, cut_off = 0;
    auto at_i = [](const std::vector<int32_t>& v, std::size_t i, int fallback) {
      return i < v.size() ? v[i] : fallback;
    };
    auto at_d = [](const std::vector<double>& v, std::size_t i, double fallback) {
      return i < v.size() ? v[i] : fallback;
    };
    for (std::size_t r = 0; r < n; ++r) {
      topopt::FaceRegionSpec spec;
      spec.id = load_case.region_ids[r];
      spec.parent_id = at_i(load_case.region_parent_ids, r, -1);
      spec.filter_matched_at_author =
          at_i(load_case.region_filter_matched_at_author, r, -1);
      spec.filter.max_area_mm2 = at_d(load_case.region_filter_max_area_mm2, r, 0.0);
      spec.filter.min_area_mm2 = at_d(load_case.region_filter_min_area_mm2, r, 0.0);
      spec.filter.min_larger_neighbours =
          at_i(load_case.region_filter_min_larger_neighbours, r, 0);
      spec.filter.larger_ratio = at_d(load_case.region_filter_larger_ratio, r, 2.0);
      switch (at_i(load_case.region_filter_kind, r, -1)) {
        case 0: spec.filter.kind = "plane"; break;
        case 1: spec.filter.kind = "cylinder"; break;
        case 2: spec.filter.kind = "other"; break;
        default: break;  // -1 = unset
      }
      spec.filter.cylinder_radius_mm =
          at_d(load_case.region_filter_cyl_radius_mm, r, 0.0);
      spec.filter.cylinder_radius_tol_mm =
          at_d(load_case.region_filter_cyl_tol_mm, r, 0.05);
      const std::size_t na =
          static_cast<std::size_t>(std::max(0, at_i(load_case.region_add_sizes, r, 0)));
      for (std::size_t k = 0; k < na && add_off + k < load_case.region_add_faces.size(); ++k)
        spec.add.push_back(load_case.region_add_faces[add_off + k]);
      add_off += na;
      const std::size_t nr = static_cast<std::size_t>(
          std::max(0, at_i(load_case.region_remove_sizes, r, 0)));
      for (std::size_t k = 0; k < nr && rem_off + k < load_case.region_remove_faces.size(); ++k)
        spec.remove.push_back(load_case.region_remove_faces[rem_off + k]);
      rem_off += nr;
      const std::size_t nc =
          static_cast<std::size_t>(std::max(0, at_i(load_case.region_cut_sizes, r, 0)));
      for (std::size_t k = 0; k < nc; ++k) {
        const std::size_t b = 3 * (cut_off + k);
        if (b + 2 >= load_case.region_cut_normal_xyz.size()) break;
        topopt::RegionCut cut;
        cut.point = topopt::Vec3{load_case.region_cut_point_xyz[b],
                                 load_case.region_cut_point_xyz[b + 1],
                                 load_case.region_cut_point_xyz[b + 2]};
        cut.normal = topopt::Vec3{load_case.region_cut_normal_xyz[b],
                                  load_case.region_cut_normal_xyz[b + 1],
                                  load_case.region_cut_normal_xyz[b + 2]};
        cut.strict = cut_off + k < load_case.region_cut_strict.size() &&
                     load_case.region_cut_strict[cut_off + k] != 0;
        spec.cuts.push_back(cut);
      }
      cut_off += nc;
      lc.face_regions.push_back(std::move(spec));
    }
  }
  lc.anchor_region_ids.assign(load_case.anchor_region_ids.begin(),
                              load_case.anchor_region_ids.end());
  {
    const std::size_t group_count = load_case.load_group_sizes.size();
    std::size_t face_off = 0;
    std::size_t region_off = 0;
    for (std::size_t g = 0; g < group_count; ++g) {
      topopt::ProductionLoadCase::LoadGroup lg;
      lg.force = topopt::Vec3{
          3 * g + 0 < load_case.load_forces.size() ? load_case.load_forces[3 * g + 0] : 0.0,
          3 * g + 1 < load_case.load_forces.size() ? load_case.load_forces[3 * g + 1] : 0.0,
          3 * g + 2 < load_case.load_forces.size() ? load_case.load_forces[3 * g + 2] : 0.0};
      const std::size_t n = static_cast<std::size_t>(load_case.load_group_sizes[g]);
      for (std::size_t f = 0; f < n && face_off + f < load_case.load_face_ids.size(); ++f)
        lg.face_ids.push_back(load_case.load_face_ids[face_off + f]);
      face_off += n;
      const std::size_t rn =
          g < load_case.load_group_region_sizes.size()
              ? static_cast<std::size_t>(std::max(0, load_case.load_group_region_sizes[g]))
              : 0;
      for (std::size_t k = 0; k < rn && region_off + k < load_case.load_region_ids.size(); ++k)
        lg.region_ids.push_back(load_case.load_region_ids[region_off + k]);
      region_off += rn;
      lc.load_groups.push_back(std::move(lg));
    }
  }
  lc.minimize_plastic = load_case.minimize_plastic;
  lc.build_dir = topopt::Vec3{load_case.build_dir_x, load_case.build_dir_y,
                              load_case.build_dir_z};
  // The build-plate normal as its OWN input (handoff 2026-08-01-build-direction-
  // separation). (0,0,0) => the app declared none => the core's documented
  // gravity fallback => byte-identical to before this field existed.
  lc.plate_dir = topopt::Vec3{load_case.plate_dir_x, load_case.plate_dir_y,
                              load_case.plate_dir_z};
  lc.build_orientation_report = load_case.build_orientation_report;
  lc.infill_percent = static_cast<double>(load_case.infill_percent);
  lc.wall_loops = load_case.wall_loops;
  if (load_case.wall_line_width_mm > 0.0)
    lc.wall_line_width_mm = load_case.wall_line_width_mm;
  if (load_case.wall_line_width_outer_mm > 0.0)
    lc.wall_line_width_outer_mm = load_case.wall_line_width_outer_mm;
  lc.has_design_box = load_case.has_design_box;
  if (load_case.has_design_box) {
    lc.design_box.min = topopt::Vec3{load_case.design_box_min_x,
                                     load_case.design_box_min_y,
                                     load_case.design_box_min_z};
    lc.design_box.max = topopt::Vec3{load_case.design_box_max_x,
                                     load_case.design_box_max_y,
                                     load_case.design_box_max_z};
    const std::size_t kn =
        std::min(load_case.keep_out_min.size(), load_case.keep_out_max.size()) / 3;
    for (std::size_t b = 0; b < kn; ++b) {
      topopt::DesignBox ko;
      ko.min = topopt::Vec3{load_case.keep_out_min[3 * b + 0],
                            load_case.keep_out_min[3 * b + 1],
                            load_case.keep_out_min[3 * b + 2]};
      ko.max = topopt::Vec3{load_case.keep_out_max[3 * b + 0],
                            load_case.keep_out_max[3 * b + 1],
                            load_case.keep_out_max[3 * b + 2]};
      lc.keep_out_boxes.push_back(ko);
    }
  }
  {
    const std::size_t cn = load_case.clearance_face_ids.size();
    for (std::size_t c = 0; c < cn; ++c) {
      topopt::ProductionLoadCase::Clearance cl;
      cl.face_id = load_case.clearance_face_ids[c];
      const bool bolt =
          c < load_case.clearance_kinds.size() && load_case.clearance_kinds[c] == 0;
      const bool manual =
          c < load_case.clearance_manual.size() && load_case.clearance_manual[c];
      cl.manual = manual;
      double bore_r = 0.0;
      if (bolt) {
        if (manual && c < load_case.clearance_radius_mm.size())
          bore_r = load_case.clearance_radius_mm[c];
        else if (!manual && cl.face_id >= 0 && cl.face_id < model.face_count)
          bore_r = model.faces[static_cast<std::size_t>(cl.face_id)]
                       .cylinder_radius_mm;
      }
      cl.params = bolt ? topopt::default_bolt_clearance(bore_r)
                       : topopt::default_face_clearance();
      if (c < load_case.clearance_margin_mm.size() &&
          load_case.clearance_margin_mm[c] > 0.0)
        cl.params.concentric_margin_mm = load_case.clearance_margin_mm[c];
      if (c < load_case.clearance_axial_mm.size() &&
          load_case.clearance_axial_mm[c] > 0.0)
        cl.params.axial_clearance_mm = load_case.clearance_axial_mm[c];
      if (c < load_case.clearance_slab_mm.size() &&
          load_case.clearance_slab_mm[c] > 0.0)
        cl.params.slab_depth_mm = load_case.clearance_slab_mm[c];
      if (manual) {
        auto xyz = [&](const std::vector<double>& v) {
          return (3 * c + 2 < v.size())
                     ? topopt::Vec3{v[3 * c + 0], v[3 * c + 1], v[3 * c + 2]}
                     : topopt::Vec3{0.0, 0.0, 0.0};
        };
        auto scalar = [&](const std::vector<double>& v) {
          return c < v.size() ? v[c] : 0.0;
        };
        cl.manual_geom.kind =
            bolt ? topopt::ClearanceKind::Bolt : topopt::ClearanceKind::Face;
        cl.manual_geom.axis_point = xyz(load_case.clearance_axis_point_xyz);
        cl.manual_geom.axis_dir = xyz(load_case.clearance_axis_dir_xyz);
        cl.manual_geom.radius_mm = scalar(load_case.clearance_radius_mm);
        cl.manual_geom.half_length_mm = scalar(load_case.clearance_half_len_mm);
        cl.manual_geom.origin = xyz(load_case.clearance_origin_xyz);
        cl.manual_geom.normal = xyz(load_case.clearance_normal_xyz);
        cl.manual_geom.half_u_mm = scalar(load_case.clearance_half_u_mm);
        cl.manual_geom.half_w_mm = scalar(load_case.clearance_half_w_mm);
      }
      lc.clearances.push_back(cl);
    }
  }
  lc.face_protection_face_ids.assign(load_case.face_protection_face_ids.begin(),
                                     load_case.face_protection_face_ids.end());
  if (load_case.face_protection_depth_mm > 0.0)
    lc.face_protection_depth_mm = load_case.face_protection_depth_mm;
  lc.face_protection_depths_mm.assign(load_case.face_protection_depths_mm.begin(),
                                      load_case.face_protection_depths_mm.end());
  // Protections declared on a REGION, and their per-region depths (task
  // 2026-08-14-face-regions). Empty => byte-identical.
  lc.face_protection_region_ids.assign(load_case.face_protection_region_ids.begin(),
                                       load_case.face_protection_region_ids.end());
  lc.face_protection_region_depths_mm.assign(
      load_case.face_protection_region_depths_mm.begin(),
      load_case.face_protection_region_depths_mm.end());
  return lc;
}

}  // namespace

std::vector<MaterialInfo> load_materials(const std::string& path,
                                         BridgeError& err) {
  std::vector<MaterialInfo> out;
  try {
    topopt::MaterialLibrary lib = topopt::load_materials_file(path);
    for (const auto& kv : lib) {
      const topopt::Material& m = kv.second;
      out.push_back(MaterialInfo{kv.first, m.youngs_modulus_mpa,
                                 m.yield_strength_mpa, m.density_g_cm3,
                                 m.z_knockdown, m.poisson, m.family});
    }
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    out.clear();
  }
  return out;
}

ImportedMesh import_stl(const std::string& path, BridgeError& err) {
  try {
    topopt::StlMesh sm = topopt::read_stl_file(path);
    return to_imported(sm.mesh, nullptr, 0);
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return ImportedMesh{};
  }
}

ImportedMesh import_step(const std::string& path, double linear_deflection,
                         BridgeError& err) {
#ifdef TOPOPT_BRIDGE_HAS_OCCT
  try {
    topopt::StepTessellation tess;
    if (linear_deflection > 0.0) tess.linear_deflection = linear_deflection;
    topopt::StepModel model = topopt::import_step_file(path, tess);
    return to_imported(model.mesh, &model.triangle_face, model.face_count,
                       &model.faces);
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return ImportedMesh{};
  }
#else
  (void)path;
  (void)linear_deflection;
  err.ok = false;
  err.message =
      "STEP import requires OpenCASCADE, which is not available on this platform";
  return ImportedMesh{};
#endif
}

// --- handoff 134: the one part-import entry point ---------------------------

ImportedMesh import_part(const std::string& path, double linear_deflection,
                         BridgeError& err) {
  try {
    // Resolve the face-overrides sidecar (handoff 2026-07-24): segment at the
    // user's tuned threshold and append their painted pseudo-faces, so the faces
    // the app draws and picks are EXACTLY the ones a re-import (live tagging, the
    // run) will resolve. With no sidecar this is byte-for-byte the plain import.
    const topopt::FaceOverrides ov =
        topopt::load_face_overrides(topopt::face_overrides_sidecar_path(path));
    topopt::PartOptions opts;
    opts.segmentation = topopt::segment_options_from(ov);
    if (linear_deflection > 0.0) opts.tessellation.linear_deflection = linear_deflection;
    topopt::PartModel p = topopt::import_part(path, opts);
    topopt::apply_face_overrides(p.model, ov);
    ImportedMesh out = to_imported(p.model.mesh, &p.model.triangle_face,
                                   p.model.face_count, &p.model.faces);
    out.pseudo_faces = p.pseudo_faces;
    return out;
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return ImportedMesh{};
  }
}

PartDiagnostics inspect_part(const std::string& path, BridgeError& err) {
  PartDiagnostics d;
  try {
    const topopt::PartInspection insp = topopt::inspect_part_file(path);
    d.checked = insp.checked;
    d.acceptable = insp.acceptable;
    for (const auto defect : insp.defects) {
      int code = 0;
      switch (defect) {
        case topopt::PartDefect::EmptyMesh: code = 0; break;
        case topopt::PartDefect::NonManifoldEdges: code = 1; break;
        case topopt::PartDefect::OpenBoundary: code = 2; break;
        case topopt::PartDefect::NonOrientable: code = 3; break;
        case topopt::PartDefect::ZeroThickness: code = 4; break;
      }
      d.defects.push_back(static_cast<int32_t>(code));
      d.defect_text.push_back(topopt::describe_defect(defect));
    }
    d.boundary_edges = static_cast<int32_t>(insp.boundary_edges);
    d.non_manifold_edges = static_cast<int32_t>(insp.non_manifold_edges);
    d.degenerate_triangles = static_cast<int32_t>(insp.degenerate_triangles);
    d.welded_vertices = static_cast<int32_t>(insp.welded_vertices);
    d.flipped_triangles = static_cast<int32_t>(insp.flipped_triangles);
    d.removed_duplicate_triangles =
        static_cast<int32_t>(insp.removed_duplicate_triangles);
    d.filled_holes = static_cast<int32_t>(insp.filled_holes);
    d.filled_hole_triangles = static_cast<int32_t>(insp.filled_hole_triangles);
    d.volume = insp.volume;
    d.bbox_min[0] = insp.bbox_min.x;
    d.bbox_min[1] = insp.bbox_min.y;
    d.bbox_min[2] = insp.bbox_min.z;
    d.bbox_max[0] = insp.bbox_max.x;
    d.bbox_max[1] = insp.bbox_max.y;
    d.bbox_max[2] = insp.bbox_max.z;
    return d;
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return PartDiagnostics{};
  }
}

void write_face_overrides(const std::string& model_path,
                          const FaceOverridesInput& input, BridgeError& err) {
  try {
    topopt::FaceOverrides ov;
    ov.dihedral_threshold_deg = input.dihedral_deg;
    ov.planar_region_cone_deg = input.cone_deg;
    // Unflatten paint_indices by paint_sizes into one triangle set per face.
    std::size_t cursor = 0;
    for (const int32_t sz : input.paint_sizes) {
      if (sz <= 0) throw std::invalid_argument("write_face_overrides: bad paint size");
      std::vector<int> set;
      set.reserve(static_cast<std::size_t>(sz));
      for (int32_t k = 0; k < sz; ++k) {
        if (cursor >= input.paint_indices.size())
          throw std::invalid_argument(
              "write_face_overrides: paint_indices shorter than paint_sizes");
        set.push_back(static_cast<int>(input.paint_indices[cursor++]));
      }
      ov.paint_faces.push_back(std::move(set));
    }
    const std::string path = topopt::face_overrides_sidecar_path(model_path);
    if (ov.empty())
      std::remove(path.c_str());  // cleared paint: don't leave a stale sidecar
    else
      topopt::save_face_overrides(path, ov);
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
  }
}

void rescale_part(const std::string& in_path, const std::string& out_path,
                  double scale, BridgeError& err) {
  try {
    topopt::rescale_part_file(in_path, out_path, scale);
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
  }
}

void export_stl(const std::string& path, const ImportedMesh& mesh,
                BridgeError& err) {
  try {
    topopt::write_stl_file(path, from_imported(mesh));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
  }
}

VoxelSummary voxelize_mesh(const std::string& path, int resolution,
                           BridgeError& err) {
  VoxelSummary s;
  try {
    topopt::TriangleMesh mesh = import_any(path);
    topopt::VoxelGrid g = topopt::voxelize(mesh, resolution);
    s.nx = g.nx;
    s.ny = g.ny;
    s.nz = g.nz;
    s.spacing = g.spacing;
    s.solid_voxels = static_cast<int64_t>(g.solid_count());
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    s = VoxelSummary{};
  }
  return s;
}

// Handoff 134: no longer OCCT-gated. `import_part_file` serves STEP, STL and
// 3MF alike, and the core's tag_step_face is OCCT-free (src/io/face_tag.cpp),
// so a mesh part can be tagged on a slice with no OCCT at all. A .step path on
// such a slice still fails — with the core's own "requires OpenCASCADE"
// message, raised from import_part_file and surfaced through `err`.
int64_t tag_step_face(const std::string& step_path, int face_id,
                      bool as_fixture, int resolution, BridgeError& err) {
  try {
    topopt::StepModel model = topopt::import_part_file_resolved(step_path);
    topopt::VoxelGrid g = topopt::voxelize(model.mesh, resolution);
    const topopt::VoxelTag tag =
        as_fixture ? topopt::VoxelTag::Fixture : topopt::VoxelTag::Load;
    return static_cast<int64_t>(topopt::tag_step_face(g, model, face_id, tag));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return 0;
  }
}

// Handoff 134: no longer OCCT-gated — same reasoning as tag_step_face above.
int64_t mask_step_face(const std::string& step_path, int face_id,
                       int mask_value, int depth_voxels, int resolution,
                       BridgeError& err) {
  try {
    if (mask_value < 0 || mask_value > 2)
      throw std::invalid_argument(
          "mask_value must be 0 (Active), 1 (FrozenSolid), or 2 (FrozenVoid)");
    topopt::StepModel model = topopt::import_part_file_resolved(step_path);
    topopt::VoxelGrid g = topopt::voxelize(model.mesh, resolution);
    topopt::DesignMask mask = topopt::make_active_mask(g);
    const auto mv = static_cast<topopt::MaskValue>(mask_value);
    return static_cast<int64_t>(
        topopt::mask_step_face(g, model, face_id, mv, depth_voxels, mask));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return 0;
  }
}

bool face_slab_preview(const std::string& step_path, FaceSlabPreview& io,
                       int resolution, BridgeError& err) {
  const std::vector<int32_t>& face_ids = io.face_ids;
  const std::vector<double>& depths_mm = io.depths_mm;
  std::vector<int64_t>& voxels_out = io.voxels;
  voxels_out.clear();
  io.spacing_mm = 0.0;
  try {
    if (face_ids.size() != depths_mm.size())
      throw std::invalid_argument(
          "face_slab_preview: depths_mm must be parallel to face_ids");
    topopt::StepModel model = topopt::import_part_file_resolved(step_path);
    topopt::VoxelGrid g = topopt::voxelize(model.mesh, resolution);
    io.spacing_mm = g.spacing;
    voxels_out.reserve(face_ids.size());
    for (std::size_t i = 0; i < face_ids.size(); ++i) {
      const int fid = face_ids[i];
      if (fid < 0 || fid >= model.face_count) { voxels_out.push_back(0); continue; }
      // The SAME conversion build_production_loadcase uses — round to layers,
      // floor at 1 — so the previewed number is the number the run will freeze.
      const int depth_vox = std::max(
          1, static_cast<int>(std::lround(depths_mm[i] / g.spacing)));
      topopt::DesignMask one = topopt::make_active_mask(g);
      voxels_out.push_back(static_cast<int64_t>(topopt::mask_step_face(
          g, model, fid, topopt::MaskValue::FrozenSolid, depth_vox, one)));
    }
    return true;
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    voxels_out.clear();
    return false;
  }
}

OptimizeResult run_minimize_plastic(const std::string& stl_path,
                                    const std::string& material_name,
                                    const std::string& materials_path,
                                    const std::string& rules_path,
                                    int resolution, ProgressFn progress,
                                    void* ctx, const bool* cancel_flag,
                                    VariantFn variant_fn, void* variant_ctx,
                                    BridgeError& err) {
  OptimizeResult result;
  try {
    bridge_log("selfweight: ENTER res=" + std::to_string(resolution) +
               " path='" + stl_path + "'");
    // Part -> voxel grid.
    topopt::TriangleMesh mesh = import_any(stl_path);
    topopt::VoxelGrid grid = topopt::voxelize(mesh, resolution);
    bridge_log("selfweight: voxelized " + grid_summary(grid));

    // Mounting face: the minimum-x boundary. Tag its solid voxels Fixture and
    // clamp every node on the i == 0 plane in all three DOFs (the same clamped-
    // root cantilever the M3/M5.3 optimizer tests build in code).
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        if (grid.solid(0, j, k)) grid.set_tag(0, j, k, topopt::VoxelTag::Fixture);

    std::vector<topopt::DirichletBC> bcs;
    for (int c = 0; c <= grid.nz; ++c)
      for (int b = 0; b <= grid.ny; ++b) {
        const int n = topopt::fea_node_index(grid, 0, b, c);
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }

    // Material + rules.
    topopt::MaterialLibrary lib = topopt::load_materials_file(materials_path);
    auto it = lib.find(material_name);
    if (it == lib.end()) {
      err.ok = false;
      err.message = "material not found: " + material_name;
      return OptimizeResult{};
    }
    topopt::SettingsRules rules = topopt::load_settings_rules_file(rules_path);

    // Progress + cancellation wiring (M7.0a). The forwarder mirrors the caller's
    // bool flag into an atomic the driver polls, and relays the payload to the
    // Swift function pointer.
    std::atomic<bool> cancelled{cancel_flag != nullptr && *cancel_flag};
    topopt::MinimizePlasticOptions opts;
    opts.cancel = &cancelled;
    // Shared production solver config (matrix-free multigrid + Galerkin cache +
    // physical min-feature + projection): ONE place the bridge and topopt-cli
    // both call, so they cannot drift into producing different parts (handoff
    // 093). The self-weight LOAD CASE (gravity, ladder, keyframes) is set below.
    topopt::configure_production_options(opts);
    // ── ★ THE PARAMETRIC LEVEL SET IS THE APP'S OPTIMISER (task
    // 2026-08-10-plsm-production, maintainer request) ───────────────────────
    //
    // The FRONT-END runs the parametric level set and nothing else: the design
    // variable is a vector of RBF coefficients and the voxel field is a value of
    // the analytic function they define (topopt/plsm.hpp). PR 324 measured it
    // from a plain array of holes, with SIMP nowhere in the pipeline, beating
    // his shipped rung 0.68 on margin and peak stress and certifying.
    //
    // ★ THIS IS AN APP DECISION, NOT A CORE DEFAULT, AND THE DISTINCTION IS
    // LOAD-BEARING. `MinimizePlasticOptions::plsm.mode` defaults to Off and
    // `configure_production_options` does NOT touch it, so `topopt-cli` and
    // every existing job document still run SIMP and are byte-for-byte what they
    // were — which is what that task's R1 checks by stash-rebuild checksum. The
    // front-end opts IN, here.
    //
    // ★ AND IT IS MIRRORED IN RemoteRunner.buildJobJSON, WHICH SENDS
    // "plsm": {"enabled": true} TO THE WORKER. The two MUST move together: the
    // on-device path and the LAN path have to produce the same part, and this
    // codebase has already paid for one drift between them. If you change this
    // line, change that one in the same commit — the same rule
    // `bake_build_orientation` below carries.
    //
    // Everything else is left at PlsmOptions' own defaults ON PURPOSE. The knot
    // spacing in particular is NOT set: leaving it at zero is what asks for
    // `plsm_knots_for_grid`, the production rule that derives the spacing from
    // the grid's own voxel size, PER AXIS. Naming three numbers here would pin
    // the feature scale to one resolution and would be a second opinion about a
    // rule core already owns.
    opts.plsm.mode = topopt::PlsmMode::Parametric;
    // ── BAKING IS OFF ON THE ON-DEVICE PATH, DELIBERATELY (handoff
    // 2026-08-01-bake-build-orientation) ────────────────────────────────────
    // The core's default is "auto": with no declared build direction it CHOOSES
    // one and rotates the EXPORTED geometry onto it. This bridge does not write
    // an exported file — it hands `variant.v3.mesh` back to Swift in MODEL
    // coordinates, to be drawn under the model-frame gravity arrow, design box,
    // clearances and field overlays. Inheriting "auto" here would certify an
    // orientation while returning geometry that does not carry it: the exact
    // "the number describes a different object than the file" failure this
    // project has spent weeks eliminating, reintroduced from the other side.
    // So the on-device path asks for the pre-bake pipeline explicitly and stays
    // byte-identical to PR 271. It matches what RemoteRunner sends, so the iPad
    // and the LAN worker still agree by construction. The fix is the same one:
    // make the viewer frame-aware, then drop this line in both places at once.
    opts.bake_build_orientation = topopt::BakeBuildOrientation::Off;
    // Self-weight body load in mm-MPa-consistent units. The material density from
    // materials.json is g/cm^3 and lengths are mm, so density*gravity must be in
    // N/mm^3: fold the g/cm^3 -> t/mm^3 factor (1e-9) into standard gravity in
    // mm/s^2, exactly as the CLI does (core/src/cli/run_job.cpp:
    // options.gravity = magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3; job.hpp §109).
    // Without this the default opts.gravity (9.81, unconverted) makes the body
    // force ~1e6x too large, so every rung's margin collapses to ~0 and the whole
    // ladder is (wrongly) rejected on strength. Direction: gravity pulls -Z.
    constexpr double kGramPerCm3ToTonnePerMm3 = 1e-9;
    opts.gravity = 9810.0 * kGramPerCm3ToTonnePerMm3;
    opts.gravity_direction = topopt::Vec3{0.0, 0.0, -1.0};
    opts.volume_fraction_ladder = reduction_ladder();  // recommendation-driven variants
    opts.keyframe_count = 12;   // optimization-history playback (viz only)
    // The forwarder relays the payload to the caller's function pointer FIRST,
    // then mirrors the caller's bool flag into the atomic the driver polls at
    // the start of the next OC iteration. Calling progress first means a cancel
    // raised from within the callback is honoured on the very next iteration.
    opts.progress = [&](std::size_t rung_index, std::size_t rung_count,
                        int iteration) {
      if (progress != nullptr)
        progress(ctx, static_cast<uint64_t>(rung_index),
                 static_cast<uint64_t>(rung_count), iteration);
      if (cancel_flag != nullptr && *cancel_flag) cancelled.store(true);
    };

    set_variant_stream(opts, grid, variant_fn, variant_ctx);  // progressive results
    // Gate diagnosis material lever (READ ONLY); `lib` outlives the call below.
    opts.material_catalog = &lib;

    bridge_log("selfweight: entering minimize_plastic (solver=MultigridCG_Matfree) " +
               grid_summary(grid) + " dirichlet_bcs=" + std::to_string(bcs.size()));
    topopt::MinimizePlasticResult mp =
        topopt::minimize_plastic(grid, it->second, material_name, bcs, rules, opts);
    result = to_optimize_result(mp, grid);
    bridge_log("selfweight: minimize_plastic returned variants=" +
               std::to_string(result.variants.size()) +
               " accepted=" + std::to_string(result.accepted_count));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("selfweight: THREW: ") + e.what());
    return OptimizeResult{};
  }
  return result;
}

// ── ★ A STANDALONE CERTIFICATION MUST NOT DEPEND ON WHAT SOLVED BEFORE IT ──
// (task 2026-08-10-plsm-production.)
//
// THE BUG THIS FIXES, which CI caught and which is a genuine correctness defect
// rather than a test artefact: `ProjectStoreSidecarTests.testQ3...` runs the SAME
// analysis twice in one process and asserts the results are bit-identical. They
// were not — 1.4e-09 on max stress, 5.7e-10 on margin.
//
// THE CAUSE. The Krylov recycle basis is THREAD-LOCAL AND STICKY ACROSS SOLVES
// (fea.hpp: "the driver resets it at each run/rung boundary with
// fea_reset_krylov_recycle_space()"). `minimize_plastic` does exactly that at run
// start (minimize_plastic.cpp:538), so the OPTIMIZE path is protected. The
// STANDALONE ANALYSIS path had no such reset and no solver isolation, so the
// second analysis in a process starts from the subspace the first one harvested,
// takes a different Krylov route, and lands somewhere else inside the same
// tolerance. In a fresh process the first analysis has no basis to inherit, which
// is why the test passes in isolation and fails in a full suite.
//
// ★ WHY THE RESET IS HERE AND NOT IN `analyze_fixed_design`. That function serves
// BOTH the standalone analysis and the per-rung certification inside
// minimize_plastic, and the per-rung one runs while the trajectory is deliberately
// BUILDING a recycle basis across iterations. Resetting there would throw away
// the basis the optimiser is paying for and change the optimize path's numbers and
// speed — a much larger blast radius than the defect. The app's contract is that
// pressing RUN SIM twice gives the same answer; this is the narrowest place that
// makes it true.
//
// ★ WHY A RESET AND NOT `ScopedLadderSolverIsolation`'s disable-and-restore. In a
// fresh process the first analysis already runs with an EMPTY basis, so a reset
// makes every analysis behave like that first one — no change to the reference
// behaviour, only the removal of cross-call carry-over. Disabling recycling
// outright would change the first call too, and with it every pinned expectation
// in the app suite, for no gain.
void isolate_standalone_certification() {
  topopt::fea_reset_krylov_recycle_space();
}

AnalyzeResult analyze_selfweight(const std::string& model_path,
                                 const std::string& analyze_mesh_path,
                                 const std::string& material_name,
                                 const std::string& materials_path,
                                 const std::string& rules_path, int resolution,
                                 double margin_stop, BridgeError& err) {
  isolate_standalone_certification();
  AnalyzeResult result;
  try {
    bridge_log("analyze: ENTER res=" + std::to_string(resolution) + " model='" +
               model_path + "' mesh='" + analyze_mesh_path + "'");
    // Model -> grid; the minimum-x boundary slab is the mount (SAME clamp as
    // run_minimize_plastic, so the re-analysis and the run agree on the fixture).
    topopt::TriangleMesh model_mesh = import_any(model_path);
    topopt::VoxelGrid grid = topopt::voxelize(model_mesh, resolution);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        if (grid.solid(0, j, k)) grid.set_tag(0, j, k, topopt::VoxelTag::Fixture);
    std::vector<topopt::DirichletBC> bcs;
    for (int c = 0; c <= grid.nz; ++c)
      for (int b = 0; b <= grid.ny; ++b) {
        const int n = topopt::fea_node_index(grid, 0, b, c);
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }
    const double part_solid = static_cast<double>(grid.solid_count());

    topopt::MaterialLibrary lib = topopt::load_materials_file(materials_path);
    auto it = lib.find(material_name);
    if (it == lib.end()) {
      err.ok = false;
      err.message = "material not found: " + material_name;
      return AnalyzeResult{};
    }
    topopt::SettingsRules rules = topopt::load_settings_rules_file(rules_path);
    const topopt::Material& material = it->second;

    // The FIXED design to analyse: the model solid, or an edited/smoothed mesh
    // re-voxelized onto the model's grid (so the clamp above still applies). The
    // occupancy carries the model's fixture tags forward.
    topopt::VoxelGrid design_grid = grid;
    if (!analyze_mesh_path.empty()) {
      topopt::TriangleMesh edited = import_any(analyze_mesh_path);
      design_grid = topopt::voxelize_onto_grid(edited, grid);
      for (std::size_t i = 0; i < design_grid.tags.size(); ++i)
        if (grid.tags[i] == topopt::VoxelTag::Fixture &&
            design_grid.tags[i] != topopt::VoxelTag::Empty)
          design_grid.tags[i] = topopt::VoxelTag::Fixture;
      result.analyzed_mesh = true;
      double v6 = 0.0;  // enclosed volume via the divergence theorem
      for (const auto& tri : edited.triangles) {
        const topopt::Vec3& a = edited.vertices[static_cast<std::size_t>(tri[0])];
        const topopt::Vec3& b = edited.vertices[static_cast<std::size_t>(tri[1])];
        const topopt::Vec3& c = edited.vertices[static_cast<std::size_t>(tri[2])];
        v6 += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
              a.z * (b.x * c.y - b.y * c.x);
      }
      result.mesh_mass_grams =
          material.density_g_cm3 * (std::fabs(v6) / 6.0) / 1000.0;
    }
    std::vector<double> density(design_grid.voxel_count(), 0.0);
    for (std::size_t i = 0; i < density.size(); ++i)
      if (design_grid.tags[i] != topopt::VoxelTag::Empty) density[i] = 1.0;

    // Self-weight load case + params in the same mm-MPa units run_minimize_plastic
    // uses. The production solver config supplies the cert tolerance / solver, so
    // the numbers match the optimizer's own certification path.
    constexpr double kGramPerCm3ToTonnePerMm3 = 1e-9;
    const double gravity = 9810.0 * kGramPerCm3ToTonnePerMm3;
    const topopt::Vec3 gdir{0.0, 0.0, -1.0};
    const topopt::Vec3 build_dir{0.0, 0.0, 1.0};
    const std::vector<topopt::NodalLoad> loads = topopt::self_weight_loads(
        design_grid, material.density_g_cm3, gravity, gdir);
    topopt::SimpParams params;
    params.youngs_modulus = material.youngs_modulus_mpa;
    params.poisson = material.poisson;
    params.penalty = 3.0;
    topopt::MinimizePlasticOptions opts;
    topopt::configure_production_options(opts);
    // ── BAKING IS OFF ON THE ON-DEVICE PATH, DELIBERATELY (handoff
    // 2026-08-01-bake-build-orientation) ────────────────────────────────────
    // The core's default is "auto": with no declared build direction it CHOOSES
    // one and rotates the EXPORTED geometry onto it. This bridge does not write
    // an exported file — it hands `variant.v3.mesh` back to Swift in MODEL
    // coordinates, to be drawn under the model-frame gravity arrow, design box,
    // clearances and field overlays. Inheriting "auto" here would certify an
    // orientation while returning geometry that does not carry it: the exact
    // "the number describes a different object than the file" failure this
    // project has spent weeks eliminating, reintroduced from the other side.
    // So the on-device path asks for the pre-bake pipeline explicitly and stays
    // byte-identical to PR 271. It matches what RemoteRunner sends, so the iPad
    // and the LAN worker still agree by construction. The fix is the same one:
    // make the viewer frame-aware, then drop this line in both places at once.
    opts.bake_build_orientation = topopt::BakeBuildOrientation::Off;
    // The gate knockdown posture (handoff 2026-07-26-post-merge-build-fix), built by
    // THE ONE builder (knockdown_spec_for) the CLI/worker uses (run_job.cpp) off the
    // SAME configure_production_options object, so the iPad and the Mac certify a part
    // under the IDENTICAL rule instead of by hand-copied field assignments that drift
    // (this call site is exactly where the post-merge break was: it kept passing a
    // bare scalar). width_aware defaults false (kProductionWidthAwareKnockdown OFF) →
    // the scalar f^1.5 gate, byte-identical to the pre-width bridge; if arming ever
    // flips, the bridge picks it up here because it reads the shared options object.
    const topopt::KnockdownSpec knockdown = topopt::knockdown_spec_for(opts);
    const bool load_path_ok =
        topopt::load_path_connected(design_grid, density, 0.5);

    const topopt::FixedDesignAnalysis a = topopt::analyze_fixed_design(
        design_grid, params, density, bcs, loads, material, build_dir,
        opts.simp.cg_tolerance, opts.simp.cg_max_iterations, opts.simp.solver,
        margin_stop, knockdown, load_path_ok, part_solid);

    result.accepted = a.accepted;
    result.non_convergent = a.non_convergent;
    result.margin_worst_case = a.margin.worst_case;
    result.margin_in_plane = a.margin.in_plane;
    result.margin_interlayer = a.margin.interlayer;
    result.margin_effective = a.margin_effective;
    result.margin_required = margin_stop;
    result.max_stress_mpa = a.max_von_mises;
    result.max_interlayer_tension_mpa = a.max_interlayer_tension;
    result.voxel_mass_grams = a.mass_grams;
    result.support_volume_voxels = a.support_volume_voxels;
    result.min_feature_violations = a.v3.min_feature_violations;
    result.grid_nx = design_grid.nx;
    result.grid_ny = design_grid.ny;
    result.grid_nz = design_grid.nz;
    result.grid_origin_x = design_grid.origin.x;
    result.grid_origin_y = design_grid.origin.y;
    result.grid_origin_z = design_grid.origin.z;
    result.spacing = design_grid.spacing;
    result.voxel_volume_mm3 = design_grid.voxel_volume();
    result.von_mises_field.assign(a.von_mises_field.begin(),
                                  a.von_mises_field.end());
    result.displacement_field.assign(a.displacement_field.begin(),
                                     a.displacement_field.end());
    bridge_log("analyze: verdict=" +
               std::string(a.accepted ? "ACCEPTED" : "REJECTED") + " margin=" +
               std::to_string(a.margin.worst_case) + " minfeat=" +
               std::to_string(a.v3.min_feature_violations));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("analyze: THREW: ") + e.what());
    return AnalyzeResult{};
  }
  return result;
}

AnalyzeResult smooth_and_recertify_selfweight(
    const std::string& model_path, const std::string& input_mesh_path,
    const std::string& smoothed_out_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, double margin_stop, double strength, bool enforce_min_feature,
    const BridgeFreezeRegions& freeze, BridgeError& err) {
  isolate_standalone_certification();
  try {
    bridge_log("smooth+recertify: ENTER strength=" + std::to_string(strength) +
               " mesh='" + input_mesh_path + "'");
    // The reference grid the smoother's min-feature constraint voxelizes against —
    // the SAME model grid analyze_selfweight re-certifies on (min-x mount slab).
    topopt::TriangleMesh model_mesh = import_any(model_path);
    topopt::VoxelGrid grid = topopt::voxelize(model_mesh, resolution);

    // Freeze regions: the mount slab (the clamped min-x face, always frozen) plus
    // every app-supplied bore / pad primitive, resolved to the exact predicate via
    // PR 190's ManualClearanceGeometry. These survive re-meshing (the smoothed mesh
    // carries no face ids).
    std::vector<topopt::ClearanceGeometry> regions;
    {
      topopt::ManualClearanceGeometry mount;
      mount.kind = topopt::ClearanceKind::Face;
      mount.origin = topopt::Vec3{grid.origin.x,
                                  grid.origin.y + 0.5 * grid.ny * grid.spacing,
                                  grid.origin.z + 0.5 * grid.nz * grid.spacing};
      mount.normal = topopt::Vec3{1.0, 0.0, 0.0};  // into the part
      mount.half_u_mm = grid.ny * grid.spacing;
      mount.half_w_mm = grid.nz * grid.spacing;
      topopt::ClearanceParams mp;
      mp.kind = topopt::ClearanceKind::Face;
      mp.slab_depth_mm = grid.spacing;
      const topopt::ClearanceGeometry mg =
          topopt::resolve_clearance_manual(mount, mp);
      if (mg.valid) regions.push_back(mg);
    }
    for (std::size_t g = 0; g < freeze.kind.size(); ++g) {
      topopt::ManualClearanceGeometry mgeo;
      topopt::ClearanceParams p;  // zero margins: freeze the true bore / pad
      const bool bolt = freeze.kind[g] == 0;
      mgeo.kind = p.kind =
          bolt ? topopt::ClearanceKind::Bolt : topopt::ClearanceKind::Face;
      auto tri = [&](const std::vector<double>& v) {
        return topopt::Vec3{v[3 * g], v[3 * g + 1], v[3 * g + 2]};
      };
      if (bolt) {
        mgeo.axis_point = tri(freeze.axis_point);
        mgeo.axis_dir = tri(freeze.axis_dir);
        mgeo.radius_mm = freeze.radius_mm[g];
        mgeo.half_length_mm = freeze.half_length_mm[g];
      } else {
        mgeo.origin = tri(freeze.origin);
        mgeo.normal = tri(freeze.normal);
        mgeo.half_u_mm = freeze.half_u_mm[g];
        mgeo.half_w_mm = freeze.half_w_mm[g];
        p.slab_depth_mm = grid.spacing;
      }
      const topopt::ClearanceGeometry cg =
          topopt::resolve_clearance_manual(mgeo, p);
      if (cg.valid) regions.push_back(cg);
    }

    topopt::TriangleMesh input = import_any(input_mesh_path);
    topopt::TaubinParams params = topopt::taubin_params_for_strength(strength);
    topopt::SmoothConstraints c;
    c.freeze_regions = std::move(regions);
    c.min_feature_grid = &grid;
    c.enforce_min_feature = enforce_min_feature;
    const topopt::SmoothResult sr =
        topopt::constrained_taubin_smooth(input, params, c);
    topopt::write_stl_file(smoothed_out_path, sr.mesh);

    // Re-certify the SMOOTHED mesh (single source of truth: same path the plain
    // analyze uses, so the numbers are the smoothed geometry's).
    AnalyzeResult result = analyze_selfweight(
        model_path, smoothed_out_path, material_name, materials_path, rules_path,
        resolution, margin_stop, err);
    if (!err.ok) return result;

    const topopt::SmoothStats& s = sr.stats;
    result.smoothed = true;
    result.smooth_strength = strength;
    result.smooth_pairs_requested = s.requested_pairs;
    result.smooth_pairs_applied = s.applied_pairs;
    result.frozen_vertices = static_cast<int64_t>(s.frozen_vertices);
    result.total_vertices = static_cast<int64_t>(s.total_vertices);
    result.volume_before_mm3 = s.volume_before_mm3;
    result.volume_after_mm3 = s.volume_after_mm3;
    result.volume_drift_fraction = s.volume_drift_fraction;
    result.volume_drift_bound = s.volume_drift_bound;
    result.min_feature_baseline = s.min_feature_baseline;
    result.min_feature_limited = s.min_feature_limited;
    result.smoothed_mesh_path = smoothed_out_path;
    bridge_log("smooth+recertify: pairs=" + std::to_string(s.applied_pairs) + "/" +
               std::to_string(s.requested_pairs) + " frozen=" +
               std::to_string(s.frozen_vertices) + " drift=" +
               std::to_string(s.volume_drift_fraction));
    return result;
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("smooth+recertify: THREW: ") + e.what());
    return AnalyzeResult{};
  }
}

namespace {
// Exact freeze predicates for the smoother from a model's B-rep faces (bridge twin
// of run_job's freeze_regions_from_faces): a cylindrical face → a Bolt bore (keep
// the hole circular), a planar face → a Face pad (keep the mounting face flat).
// Used to freeze the loadcase's anchor and load faces so the clamp and the traction
// stay attached to bit-identical solid across the re-voxelization. Non-plane/-cyl
// (or pseudo-)faces that do not resolve are simply skipped — the app's own `freeze`
// primitives plus the Fixture/Load retag below still keep the surfaces attached.
std::vector<topopt::ClearanceGeometry> freeze_regions_from_model_faces(
    const topopt::StepModel& model, const std::vector<int>& face_ids, double spacing) {
  std::vector<topopt::ClearanceGeometry> regions;
  for (const int fid : face_ids) {
    if (fid < 0 || fid >= model.face_count) continue;
    const topopt::StepFaceInfo& face = model.faces[static_cast<std::size_t>(fid)];
    topopt::ClearanceParams p;
    if (face.kind == topopt::StepSurfaceKind::Cylinder) {
      p.kind = topopt::ClearanceKind::Bolt;
    } else if (face.kind == topopt::StepSurfaceKind::Plane) {
      p.kind = topopt::ClearanceKind::Face;
      p.slab_depth_mm = spacing;
    } else {
      continue;
    }
    const topopt::ClearanceGeometry g =
        topopt::resolve_clearance_from_face(model, fid, p);
    if (g.valid) regions.push_back(g);
  }
  return regions;
}

// THE ONE freeze-region set for the loadcase smoothing path (handoff
// 2026-08-02-smoothing-page). Factored out of smooth_and_recertify_loadcase so
// that the mask the page asks for BEFORE painting and the mask the smoother
// applies WHILE smoothing are literally the same list, resolved by the same code
// — not two implementations that agree today. The structural regions (the load
// case's anchors and load faces) come first, then every app-supplied
// bore/pad/protect primitive, all as exact predicates that survive re-meshing.
std::vector<topopt::ClearanceGeometry> loadcase_freeze_regions(
    const topopt::StepModel& model, const topopt::ProductionLoadCase& lc,
    const BridgeFreezeRegions& freeze, double spacing) {
  std::vector<topopt::ClearanceGeometry> regions;
  {
    std::vector<int> structural = lc.anchor_face_ids;
    for (const auto& g : lc.load_groups)
      for (const int fid : g.face_ids) structural.push_back(fid);
    for (auto& r : freeze_regions_from_model_faces(model, structural, spacing))
      regions.push_back(std::move(r));
  }
  for (std::size_t g = 0; g < freeze.kind.size(); ++g) {
    topopt::ManualClearanceGeometry mgeo;
    topopt::ClearanceParams p;  // zero margins: freeze the true bore / pad
    const bool bolt = freeze.kind[g] == 0;
    mgeo.kind = p.kind =
        bolt ? topopt::ClearanceKind::Bolt : topopt::ClearanceKind::Face;
    auto tri = [&](const std::vector<double>& v) {
      return topopt::Vec3{v[3 * g], v[3 * g + 1], v[3 * g + 2]};
    };
    if (bolt) {
      mgeo.axis_point = tri(freeze.axis_point);
      mgeo.axis_dir = tri(freeze.axis_dir);
      mgeo.radius_mm = freeze.radius_mm[g];
      mgeo.half_length_mm = freeze.half_length_mm[g];
    } else {
      mgeo.origin = tri(freeze.origin);
      mgeo.normal = tri(freeze.normal);
      mgeo.half_u_mm = freeze.half_u_mm[g];
      mgeo.half_w_mm = freeze.half_w_mm[g];
      p.slab_depth_mm = spacing;
    }
    const topopt::ClearanceGeometry cg =
        topopt::resolve_clearance_manual(mgeo, p);
    if (cg.valid) regions.push_back(cg);
  }
  return regions;
}

// The freeze tolerance the smoother itself derives (smooth.cpp): 0.75 × the
// reference grid spacing. Named here so the mask the page shows and the mask the
// smoother applies cannot drift apart.
double smoother_freeze_tol(double spacing) { return 0.75 * spacing; }
}  // namespace

AnalyzeResult analyze_loadcase(const std::string& model_path,
                               const std::string& analyze_mesh_path,
                               const std::string& material_name,
                               const std::string& materials_path,
                               const std::string& rules_path, int resolution,
                               const BridgeLoadCase& load_case, BridgeError& err) {
  isolate_standalone_certification();
  AnalyzeResult result;
  try {
    bridge_log("analyze_loadcase: ENTER res=" + std::to_string(resolution) +
               " model='" + model_path + "' mesh='" + analyze_mesh_path + "'");
    topopt::StepModel model = topopt::import_part_file_resolved(model_path);
    const topopt::ProductionLoadCase lc =
        production_loadcase_from_bridge(load_case, model);
    topopt::ProductionRunSetup setup =
        topopt::build_production_loadcase(model, resolution, lc);
    // Baking OFF on the on-device path, for the reason stated at the optimize
    // site above: this bridge returns MODEL-frame geometry and writes no
    // exported file, so a chosen-and-baked orientation would certify something
    // the returned mesh does not carry (handoff 2026-08-01-bake-build-orientation).
    setup.options.bake_build_orientation = topopt::BakeBuildOrientation::Off;
    if (setup.options.external_loads.empty()) {
      err.ok = false;
      // Composed from the per-group reports (core, PR 261) so the refusal names
      // WHICH group resolved to nothing and WHY (zero force / zero tagged /
      // unresolvable), instead of the old generic one-liner. Same loudness,
      // same condition — only the sim framing is the bridge's own.
      err.message = "analyze: the declared load case produced NO external load — " +
                    topopt::no_external_load_message(setup, resolution) +
                    " — nothing to certify under";
      return AnalyzeResult{};
    }
    topopt::VoxelGrid& model_grid = setup.grid;
    const double part_solid = static_cast<double>(model_grid.solid_count());

    topopt::MaterialLibrary lib = topopt::load_materials_file(materials_path);
    auto it = lib.find(material_name);
    if (it == lib.end()) {
      err.ok = false;
      err.message = "material not found: " + material_name;
      return AnalyzeResult{};
    }
    const topopt::Material& material = it->second;

    // The FIXED design to analyse: the model solid, or an edited/smoothed mesh
    // re-voxelized onto the model grid (so the anchors' clamp and the traction's
    // node set still apply). Carry both Fixture AND Load tags forward.
    topopt::VoxelGrid design_grid = model_grid;
    if (!analyze_mesh_path.empty()) {
      topopt::TriangleMesh edited = import_any(analyze_mesh_path);
      design_grid = topopt::voxelize_onto_grid(edited, model_grid);
      for (std::size_t i = 0; i < design_grid.tags.size(); ++i) {
        if (model_grid.tags[i] == topopt::VoxelTag::Fixture &&
            design_grid.tags[i] != topopt::VoxelTag::Empty)
          design_grid.tags[i] = topopt::VoxelTag::Fixture;
        else if (model_grid.tags[i] == topopt::VoxelTag::Load)
          design_grid.tags[i] = topopt::VoxelTag::Load;
      }
      result.analyzed_mesh = true;
      double v6 = 0.0;
      for (const auto& tri : edited.triangles) {
        const topopt::Vec3& a = edited.vertices[static_cast<std::size_t>(tri[0])];
        const topopt::Vec3& b = edited.vertices[static_cast<std::size_t>(tri[1])];
        const topopt::Vec3& c = edited.vertices[static_cast<std::size_t>(tri[2])];
        v6 += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
              a.z * (b.x * c.y - b.y * c.x);
      }
      result.mesh_mass_grams =
          material.density_g_cm3 * (std::fabs(v6) / 6.0) / 1000.0;
    }
    std::vector<double> density(design_grid.voxel_count(), 0.0);
    int64_t solid_voxels = 0;
    for (std::size_t i = 0; i < density.size(); ++i)
      if (design_grid.tags[i] != topopt::VoxelTag::Empty) {
        density[i] = 1.0;
        ++solid_voxels;
      }
    result.solid_voxels = solid_voxels;

    topopt::SimpParams params;
    params.youngs_modulus = material.youngs_modulus_mpa;
    params.poisson = material.poisson;
    params.penalty = 3.0;
    const topopt::Vec3 gdir = setup.options.gravity_direction;
    const double gn =
        std::sqrt(gdir.x * gdir.x + gdir.y * gdir.y + gdir.z * gdir.z);
    const topopt::Vec3 build_dir =
        gn > 0.0 ? topopt::Vec3{-gdir.x / gn, -gdir.y / gn, -gdir.z / gn}
                 : topopt::Vec3{0.0, 0.0, 1.0};
    const topopt::KnockdownSpec knockdown =
        topopt::knockdown_spec_for(setup.options);
    const bool load_path_ok =
        topopt::load_path_connected(design_grid, density, 0.5);

    const topopt::FixedDesignAnalysis a = topopt::analyze_fixed_design(
        design_grid, params, density, setup.bcs, setup.options.external_loads,
        material, build_dir, setup.options.simp.cg_tolerance,
        setup.options.simp.cg_max_iterations, setup.options.simp.solver,
        setup.options.margin_stop, knockdown, load_path_ok, part_solid);

    result.accepted = a.accepted;
    result.non_convergent = a.non_convergent;
    result.margin_worst_case = a.margin.worst_case;
    result.margin_in_plane = a.margin.in_plane;
    result.margin_interlayer = a.margin.interlayer;
    result.margin_effective = a.margin_effective;
    result.margin_required = setup.options.margin_stop;
    result.max_stress_mpa = a.max_von_mises;
    result.max_interlayer_tension_mpa = a.max_interlayer_tension;
    result.voxel_mass_grams = a.mass_grams;
    result.support_volume_voxels = a.support_volume_voxels;
    result.min_feature_violations = a.v3.min_feature_violations;
    result.grid_nx = design_grid.nx;
    result.grid_ny = design_grid.ny;
    result.grid_nz = design_grid.nz;
    result.grid_origin_x = design_grid.origin.x;
    result.grid_origin_y = design_grid.origin.y;
    result.grid_origin_z = design_grid.origin.z;
    result.spacing = design_grid.spacing;
    result.voxel_volume_mm3 = design_grid.voxel_volume();
    result.von_mises_field.assign(a.von_mises_field.begin(),
                                  a.von_mises_field.end());
    result.displacement_field.assign(a.displacement_field.begin(),
                                     a.displacement_field.end());
    bridge_log("analyze_loadcase: verdict=" +
               std::string(a.non_convergent ? "NON_CONVERGENT"
                                            : (a.accepted ? "ACCEPTED" : "REJECTED")) +
               " margin=" + std::to_string(a.margin.worst_case) + " required=" +
               std::to_string(setup.options.margin_stop));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("analyze_loadcase: THREW: ") + e.what());
    return AnalyzeResult{};
  }
  return result;
}

// THE LIVE BRUSH PREVIEW — see the header for what it deliberately leaves out
// and why (task 2026-08-04-variant-volume-fraction-mismatch, failure C).
//
// ONE BODY, TWO DOORS (task 2026-08-08, S1b). The path-taking entry point and
// the in-memory one differ ONLY in where the input mesh comes from; everything
// after that is this function. Written this way on purpose: two copies of the
// smoothing call would be two places for the preview the page draws and the
// preview a test takes to drift apart.
static BridgeSmoothPreview smooth_brush_preview_impl(
    const topopt::TriangleMesh& input, double strength,
    const BridgeVertexWeights& brush, double import_seconds, BridgeError& err) {
  BridgeSmoothPreview out;
  try {
    const auto t0 = std::chrono::steady_clock::now();
    out.seconds_import = import_seconds;
    if (!brush.weight.empty() && brush.weight.size() != input.vertices.size()) {
      err.ok = false;
      err.message =
          "smooth preview: the brush has " +
          std::to_string(brush.weight.size()) + " weights but the mesh has " +
          std::to_string(input.vertices.size()) +
          " vertices — refusing rather than weighting the wrong vertices";
      return BridgeSmoothPreview{};
    }
    topopt::SmoothConstraints c;
    // No freeze REGIONS and no grid: the caller has already resolved the freeze
    // mask (smooth_freeze_mask) and hands frozen vertices in as weight 0, which
    // the smoother copies verbatim on the identical code path. Re-resolving the
    // predicates here would mean importing the model and voxelizing it on every
    // stroke, which is exactly the cost this seam exists to avoid.
    c.enforce_min_feature = false;
    c.min_feature_grid = nullptr;
    c.vertex_weight = brush.weight;
    const topopt::SmoothResult sr = topopt::constrained_taubin_smooth(
        input, topopt::taubin_params_for_strength(strength), c);

    out.total_vertices = static_cast<int64_t>(sr.mesh.vertices.size());
    out.vertices.reserve(sr.mesh.vertices.size() * 3);
    for (std::size_t v = 0; v < sr.mesh.vertices.size(); ++v) {
      const topopt::Vec3& p = sr.mesh.vertices[v];
      out.vertices.push_back(static_cast<float>(p.x));
      out.vertices.push_back(static_cast<float>(p.y));
      out.vertices.push_back(static_cast<float>(p.z));
      if (v < input.vertices.size()) {
        const topopt::Vec3& q = input.vertices[v];
        const double dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z;
        const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (d > 0.0) ++out.moved_vertices;
        if (d > out.max_displacement_mm) out.max_displacement_mm = d;
      }
    }
    out.indices.reserve(sr.mesh.triangles.size() * 3);
    for (const auto& t : sr.mesh.triangles) {
      out.indices.push_back(static_cast<int32_t>(t[0]));
      out.indices.push_back(static_cast<int32_t>(t[1]));
      out.indices.push_back(static_cast<int32_t>(t[2]));
    }
    out.seconds_smooth = std::chrono::duration<double>(
                             std::chrono::steady_clock::now() - t0).count();
    out.seconds = out.seconds_import + out.seconds_smooth;
    bridge_log("smooth preview: " + std::to_string(out.total_vertices) +
               " vertices, moved " + std::to_string(out.moved_vertices) +
               ", max " + std::to_string(out.max_displacement_mm) + " mm, " +
               std::to_string(out.seconds) + " s (import " +
               std::to_string(out.seconds_import) + " s, smooth " +
               std::to_string(out.seconds_smooth) + " s)");
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return BridgeSmoothPreview{};
  }
  return out;
}

BridgeSmoothPreview smooth_brush_preview(const std::string& input_mesh_path,
                                         double strength,
                                         const BridgeVertexWeights& brush,
                                         BridgeError& err) {
  topopt::TriangleMesh input;
  double import_seconds = 0.0;
  try {
    const auto t0 = std::chrono::steady_clock::now();
    input = import_any(input_mesh_path);
    import_seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
            .count();
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return BridgeSmoothPreview{};
  }
  return smooth_brush_preview_impl(input, strength, brush, import_seconds, err);
}

// ★ THE IN-MEMORY DOOR (task 2026-08-08, S1b). No file is opened.
BridgeSmoothPreview smooth_brush_preview_mesh(const BridgeMeshGeometry& mesh,
                                              double strength,
                                              const BridgeVertexWeights& brush,
                                              BridgeError& err) {
  const std::vector<float>& vertices = mesh.vertices;
  const std::vector<int32_t>& indices = mesh.indices;
  if (vertices.size() % 3 != 0 || indices.size() % 3 != 0) {
    err.ok = false;
    err.message =
        "smooth preview: geometry is not triangles — " +
        std::to_string(vertices.size()) + " floats and " +
        std::to_string(indices.size()) +
        " indices, both of which must be multiples of 3";
    return BridgeSmoothPreview{};
  }
  topopt::TriangleMesh input;
  input.vertices.reserve(vertices.size() / 3);
  for (std::size_t i = 0; i + 2 < vertices.size(); i += 3)
    input.vertices.push_back(topopt::Vec3{vertices[i], vertices[i + 1],
                                          vertices[i + 2]});
  const auto nverts = static_cast<int32_t>(input.vertices.size());
  input.triangles.reserve(indices.size() / 3);
  for (std::size_t i = 0; i + 2 < indices.size(); i += 3) {
    // An out-of-range corner would index past the vertex array inside the
    // operator. Refuse it here, where the message can say which value was wrong.
    for (std::size_t k = 0; k < 3; ++k) {
      if (indices[i + k] < 0 || indices[i + k] >= nverts) {
        err.ok = false;
        err.message = "smooth preview: triangle corner " +
                      std::to_string(indices[i + k]) + " is outside the " +
                      std::to_string(nverts) + " vertices supplied";
        return BridgeSmoothPreview{};
      }
    }
    input.triangles.push_back({static_cast<int>(indices[i]),
                               static_cast<int>(indices[i + 1]),
                               static_cast<int>(indices[i + 2])});
  }
  // import_seconds is 0 BY CONSTRUCTION here — nothing was read.
  return smooth_brush_preview_impl(input, strength, brush, 0.0, err);
}

BridgeFreezeMask smooth_freeze_mask(const std::string& model_path,
                                    const std::string& mesh_path,
                                    int resolution,
                                    const BridgeLoadCase& load_case,
                                    const BridgeFreezeRegions& freeze,
                                    BridgeError& err) {
  BridgeFreezeMask out;
  try {
    topopt::StepModel model = topopt::import_part_file_resolved(model_path);
    const topopt::ProductionLoadCase lc =
        production_loadcase_from_bridge(load_case, model);
    topopt::ProductionRunSetup setup =
        topopt::build_production_loadcase(model, resolution, lc);
    setup.options.bake_build_orientation = topopt::BakeBuildOrientation::Off;
    const double spacing = setup.grid.spacing;

    const std::vector<topopt::ClearanceGeometry> regions =
        loadcase_freeze_regions(model, lc, freeze, spacing);
    const topopt::TriangleMesh mesh = import_any(mesh_path);
    out.freeze_tol_mm = smoother_freeze_tol(spacing);
    // THE SAME CALL the smoother makes on the same regions and the same tolerance.
    const std::vector<char> frozen =
        topopt::compute_freeze_mask(mesh, regions, out.freeze_tol_mm);
    out.frozen.reserve(frozen.size());
    for (const char f : frozen) {
      out.frozen.push_back(f ? 1 : 0);
      if (f) ++out.frozen_count;
    }
    out.total_vertices = static_cast<int64_t>(mesh.vertices.size());
    bridge_log("smooth freeze mask: " + std::to_string(out.frozen_count) + "/" +
               std::to_string(out.total_vertices) + " frozen, tol=" +
               std::to_string(out.freeze_tol_mm));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("smooth freeze mask: THREW: ") + e.what());
    return BridgeFreezeMask{};
  }
  return out;
}

AnalyzeResult smooth_and_recertify_loadcase(
    const std::string& model_path, const std::string& input_mesh_path,
    const std::string& smoothed_out_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, double strength, bool enforce_min_feature,
    const BridgeLoadCase& load_case, const BridgeFreezeRegions& freeze,
    BridgeError& err) {
  isolate_standalone_certification();
  // The uniform seam IS the brush seam with no brush — one implementation, so the
  // two can never diverge (and PR 200's callers stay byte-identical).
  return smooth_brush_and_recertify_loadcase(
      model_path, input_mesh_path, smoothed_out_path, material_name,
      materials_path, rules_path, resolution, strength, enforce_min_feature,
      load_case, freeze, BridgeVertexWeights{}, err);
}

AnalyzeResult smooth_brush_and_recertify_loadcase(
    const std::string& model_path, const std::string& input_mesh_path,
    const std::string& smoothed_out_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, double strength, bool enforce_min_feature,
    const BridgeLoadCase& load_case, const BridgeFreezeRegions& freeze,
    const BridgeVertexWeights& brush, BridgeError& err) {
  isolate_standalone_certification();
  try {
    bridge_log("smooth+recertify(loadcase): ENTER strength=" +
               std::to_string(strength) + " mesh='" + input_mesh_path +
               "' brush=" + std::to_string(brush.weight.size()));
    // The reference grid the min-feature constraint voxelizes against — the SAME
    // grid analyze_loadcase re-certifies on. Build it through build_production_
    // loadcase so the anchors/load faces are tagged and their B-rep geometry is
    // available for the freeze predicates.
    topopt::StepModel model = topopt::import_part_file_resolved(model_path);
    const topopt::ProductionLoadCase lc =
        production_loadcase_from_bridge(load_case, model);
    topopt::ProductionRunSetup setup =
        topopt::build_production_loadcase(model, resolution, lc);
    // Baking OFF on the on-device path, for the reason stated at the optimize
    // site above: this bridge returns MODEL-frame geometry and writes no
    // exported file, so a chosen-and-baked orientation would certify something
    // the returned mesh does not carry (handoff 2026-08-01-bake-build-orientation).
    setup.options.bake_build_orientation = topopt::BakeBuildOrientation::Off;
    topopt::VoxelGrid& grid = setup.grid;

    // Freeze regions: the anchors and the load faces (structural — keep the clamp
    // and the traction attached), PLUS every app-supplied bore/pad/protect
    // primitive. All resolve to the exact predicate that survives re-meshing —
    // and through the SAME helper `smooth_freeze_mask` answers from, so what the
    // page paints against and what the smoother protects are one list.
    std::vector<topopt::ClearanceGeometry> regions =
        loadcase_freeze_regions(model, lc, freeze, grid.spacing);

    topopt::TriangleMesh input = import_any(input_mesh_path);
    if (!brush.weight.empty() && brush.weight.size() != input.vertices.size()) {
      err.ok = false;
      err.message =
          "smooth: the brush has " + std::to_string(brush.weight.size()) +
          " weights but the mesh has " + std::to_string(input.vertices.size()) +
          " vertices — refusing rather than weighting the wrong vertices";
      return AnalyzeResult{};
    }
    topopt::TaubinParams params = topopt::taubin_params_for_strength(strength);
    topopt::SmoothConstraints c;
    c.freeze_regions = std::move(regions);
    c.min_feature_grid = &grid;
    c.enforce_min_feature = enforce_min_feature;
    c.vertex_weight = brush.weight;
    const topopt::SmoothResult sr =
        topopt::constrained_taubin_smooth(input, params, c);
    topopt::write_stl_file(smoothed_out_path, sr.mesh);

    // Re-certify the SMOOTHED mesh under the SAME load case (single source of
    // truth: analyze_loadcase), so every returned number describes the smoothed
    // geometry — the honesty rule.
    AnalyzeResult result =
        analyze_loadcase(model_path, smoothed_out_path, material_name,
                         materials_path, rules_path, resolution, load_case, err);
    if (!err.ok) return result;

    const topopt::SmoothStats& s = sr.stats;
    result.smoothed = true;
    result.smooth_strength = strength;
    result.smooth_pairs_requested = s.requested_pairs;
    result.smooth_pairs_applied = s.applied_pairs;
    result.frozen_vertices = static_cast<int64_t>(s.frozen_vertices);
    result.total_vertices = static_cast<int64_t>(s.total_vertices);
    result.volume_before_mm3 = s.volume_before_mm3;
    result.volume_after_mm3 = s.volume_after_mm3;
    result.volume_drift_fraction = s.volume_drift_fraction;
    result.volume_drift_bound = s.volume_drift_bound;
    result.min_feature_baseline = s.min_feature_baseline;
    result.min_feature_limited = s.min_feature_limited;
    result.smoothed_mesh_path = smoothed_out_path;
    result.brush_weighted = s.brush_weighted;
    result.brushed_vertices = static_cast<int64_t>(s.brushed_vertices);
    result.unbrushed_vertices = static_cast<int64_t>(s.unbrushed_vertices);
    result.max_vertex_weight = s.max_vertex_weight;
    // H3 — the certified object is the RE-VOXELIZATION, not the mesh. Report both
    // volume fractions against the SAME denominator (the analysis grid's bounding
    // volume) so the gap between what was printed and what was certified is a
    // number on the receipt instead of an assumption.
    {
      const double grid_volume =
          static_cast<double>(result.grid_nx) *
          static_cast<double>(result.grid_ny) *
          static_cast<double>(result.grid_nz) * result.voxel_volume_mm3;
      if (grid_volume > 0.0) {
        result.mesh_volume_fraction = s.volume_after_mm3 / grid_volume;
        result.voxel_volume_fraction =
            static_cast<double>(result.solid_voxels) * result.voxel_volume_mm3 /
            grid_volume;
      }
    }
    bridge_log("smooth+recertify(loadcase): pairs=" +
               std::to_string(s.applied_pairs) + "/" +
               std::to_string(s.requested_pairs) + " frozen=" +
               std::to_string(s.frozen_vertices) + " drift=" +
               std::to_string(s.volume_drift_fraction) + " margin=" +
               std::to_string(result.margin_worst_case) + " accepted=" +
               std::to_string(result.accepted ? 1 : 0));
    return result;
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("smooth+recertify(loadcase): THREW: ") + e.what());
    return AnalyzeResult{};
  }
}

LatticeJobResult run_lattice_job(const std::string& job_path,
                                 const std::string& job_dir,
                                 const std::string& out_dir,
                                 const std::string& materials_path,
                                 const std::string& rules_path,
                                 BridgeError& err) {
  LatticeJobResult out;
  try {
    bridge_log("lattice_job: ENTER job='" + job_path + "' out='" + out_dir + "'");
    // ★ CORE'S OWN PARSER, ON THE SAME DOCUMENT THE LAN PATH SENDS. Nothing is
    // re-authored here: the anchors, the loads, the clearances, the protections,
    // the resolution, the material and the lattice block are the bytes the app
    // already knows how to write. That is what makes an on-device lattice and a
    // worker lattice the same run rather than two mappings kept in step.
    const topopt::JobDescription job = topopt::load_job_file(job_path);
    if (job.mode != "lattice_part" && job.mode != "lattice_variant") {
      err.ok = false;
      err.message = "run_lattice_job: mode must be \"lattice_part\" or "
                    "\"lattice_variant\" (got \"" + job.mode + "\")";
      return out;
    }
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(materials_path);
    const topopt::SettingsRules rules =
        topopt::load_settings_rules_file(rules_path);
    const topopt::LatticeVariantJobResult r =
        topopt::lattice_variant_job(job, job_dir, out_dir, materials, rules);
    out.mesh_paths = r.mesh_paths;
    out.report_path = r.report_path;
    out.lattice_receipt_path = r.lattice_receipt_path;
    out.latticed_voxels = r.latticed_voxels;
    out.achieved_volume_fraction = r.achieved_volume_fraction;
    out.reproduced_margin_worst_case = r.reproduced_margin_worst_case;
    out.graded = r.graded;
    out.cell_size_mm = r.cell_size_mm;
    out.rho_min_used = r.rho_min_used;
    out.rho_max_used = r.rho_max_used;
    out.analysis_solves = r.analysis_solves;
    out.wall_seconds = r.wall_seconds;
    bridge_log("lattice_job: DONE latticed_voxels=" +
               std::to_string(out.latticed_voxels) + " meshes=" +
               std::to_string(out.mesh_paths.size()) + " solves=" +
               std::to_string(out.analysis_solves));
    return out;
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("lattice_job: THREW: ") + e.what());
    return LatticeJobResult{};
  }
}

OptimizeResult run_minimize_plastic_loadcase(
    const std::string& step_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, const BridgeLoadCase& load_case, ProgressFn progress,
    void* ctx, const bool* cancel_flag, VariantFn variant_fn, void* variant_ctx,
    BridgeError& err) {
  // Handoff 134: no longer OCCT-gated. `build_production_loadcase` never used an
  // OCCT symbol — it needed tag/mask_step_face, which now live in the core's
  // always-built src/io/face_tag.cpp — so the whole load-case pipeline runs for
  // an STL/3MF part on a slice without OCCT. `step_path` keeps its name because
  // it is the wire contract with the Swift side; it is a PART path now.
  OptimizeResult result;
  try {
    bridge_log("loadcase: ENTER res=" + std::to_string(resolution) +
               " anchors=" + std::to_string(load_case.anchor_face_ids.size()) +
               " load_groups=" + std::to_string(load_case.load_group_sizes.size()) +
               " load_faces=" + std::to_string(load_case.load_face_ids.size()) +
               " minimize_plastic=" + std::to_string(load_case.minimize_plastic ? 1 : 0) +
               " design_box=" + std::to_string(load_case.has_design_box ? 1 : 0));
    bridge_log("loadcase: importing part '" + step_path + "'");
    topopt::StepModel model = topopt::import_part_file_resolved(step_path);
    bridge_log("loadcase: part imported (faces=" +
               std::to_string(model.face_count) +
               "); building shared production setup");

    // Map the flat BridgeLoadCase to the front-end-neutral ProductionLoadCase and
    // hand it to build_production_loadcase — the SINGLE grid/BC/options builder the
    // CLI also calls, so the app and topopt-cli produce the same design for the
    // same STEP + load case + resolution (handoff 093). The flattened load groups
    // (group g's faces are the load_group_sizes[g] entries of load_face_ids after
    // the earlier groups', its force load_forces[3g..3g+2]) unflatten here.
    const topopt::ProductionLoadCase lc =
        production_loadcase_from_bridge(load_case, model);

    topopt::ProductionRunSetup setup =
        topopt::build_production_loadcase(model, resolution, lc);
    // Baking OFF on the on-device path, for the reason stated at the optimize
    // site above: this bridge returns MODEL-frame geometry and writes no
    // exported file, so a chosen-and-baked orientation would certify something
    // the returned mesh does not carry (handoff 2026-08-01-bake-build-orientation).
    setup.options.bake_build_orientation = topopt::BakeBuildOrientation::Off;
    // ── ★ THE PARAMETRIC LEVEL SET, ON THE LOAD-CASE PATH TOO ───────────────
    // (task 2026-08-10-plsm-production.)
    //
    // ★ THIS IS THE SECOND OF TWO ON-DEVICE OPTIMISE ENTRY POINTS AND IT IS THE
    // ONE HIS REAL JOBS USE. `run_minimize_plastic` above is the SELF-WEIGHT
    // path; this is the DECLARED LOAD CASE path. They are separate functions
    // with separate option objects, and arming only the first would have given
    // the front-end a parametric optimiser for self-weight parts and SIMP for
    // every part with a declared load — silently, with both reporting success.
    // Caught by grepping for the entry points rather than by reading the one I
    // had already edited.
    //
    // Mirrored in `run_minimize_plastic` above and in
    // RemoteRunner.buildJobJSON. ALL THREE MOVE TOGETHER.
    setup.options.plsm.mode = topopt::PlsmMode::Parametric;
    for (const auto& pr : setup.face_protection_reports)
      bridge_log("loadcase: face-protection " +
                 (pr.region_id >= 0 ? "region=" + std::to_string(pr.region_id)
                                    : "face=" + std::to_string(pr.face_id)) +
                 " voxels_frozen=" + std::to_string(pr.voxels_frozen) +
                 " depth=" + std::to_string(pr.depth_voxels) +
                 (pr.thinner_than_depth ? " thinner-than-depth" : ""));
    for (const auto& cr : setup.clearance_reports)
      bridge_log("loadcase: clearance face=" + std::to_string(cr.face_id) +
                 " kind=" + (cr.kind == topopt::ClearanceKind::Bolt ? "bolt" : "face") +
                 " voxels_frozen=" + std::to_string(cr.voxels_frozen) +
                 (cr.in_grid ? "" : " OUTSIDE-GRID"));
    bridge_log("loadcase: setup built; part " + grid_summary(setup.grid));

    // Front-end wiring the shared builder deliberately leaves to the caller:
    // cancellation, playback keyframes (viz only), the progress relay and the
    // progressive-variant stream. None of these change the design.
    std::atomic<bool> cancelled{cancel_flag != nullptr && *cancel_flag};
    setup.options.cancel = &cancelled;
    setup.options.keyframe_count = 12;  // optimization-history playback (viz only)
    setup.options.progress = [&](std::size_t r, std::size_t rc, int iter) {
      if (progress != nullptr)
        progress(ctx, static_cast<uint64_t>(r), static_cast<uint64_t>(rc), iter);
      if (cancel_flag != nullptr && *cancel_flag) cancelled.store(true);
    };
    set_variant_stream(setup.options, setup.solved_grid, variant_fn, variant_ctx);

    topopt::MaterialLibrary lib = topopt::load_materials_file(materials_path);
    auto it = lib.find(material_name);
    if (it == lib.end()) {
      err.ok = false;
      err.message = "material not found: " + material_name;
      return OptimizeResult{};
    }
    topopt::SettingsRules rules = topopt::load_settings_rules_file(rules_path);
    // The material catalog the GATE DIAGNOSIS prices its material lever against
    // (handoff 2026-08-02-gate-diagnosis-recommendations). READ ONLY, and `lib`
    // outlives the minimize_plastic call below. Without it the material lever
    // reports itself NOT EVALUABLE instead of guessing.
    setup.options.material_catalog = &lib;

    // The last checkpoint before the solve: if the device log stops here, the
    // ──▶ PRE-FLIGHT LOAD-PATH CONNECTIVITY (task 2026-08-03-preflight-
    // feasibility-and-divergence, guard 1) — the SAME check topopt-cli runs, at
    // the same point (domain resolved, clearances frozen, before any solve), and
    // reporting through the SAME message builder, so a refusal reads identically
    // on the iPad and on the CLI. Milliseconds; it can only refuse a job whose
    // load path is PROVABLY severed, never a merely marginal one.
    {
      const topopt::SolvedDesignDomain domain = topopt::resolve_design_domain(
          setup.grid, setup.bcs, setup.options);
      const topopt::PreflightLoadPath pf =
          topopt::preflight_load_path(domain, setup.options);
      if (pf.walk.decidable) {
        bridge_log(std::string("loadcase: preflight load path ") +
                   (pf.walk.connected ? "CONNECTED" : "SEVERED") +
                   " load_voxels=" + std::to_string(pf.walk.load_voxels) +
                   " anchor_voxels=" + std::to_string(pf.walk.anchor_voxels) +
                   " unreached=" +
                   std::to_string(pf.walk.unreached_load_voxels) +
                   " narrowest_separator_voxels=" +
                   std::to_string(pf.walk.narrowest_separator_voxels) +
                   " ms=" + std::to_string(pf.wall_ms));
      }
      if (pf.walk.decidable && !pf.walk.connected) {
        err.ok = false;
        err.message = topopt::preflight_refusal_report(
            model, setup.grid, domain, setup.options, lc, pf,
            lc.anchor_face_ids);
        bridge_log("loadcase: PRE-FLIGHT REFUSED — " + err.message);
        return OptimizeResult{};
      }
    }

    // stall is INSIDE minimize_plastic. Report the grid the solver actually runs
    // on (the expanded domain when a design box is set) plus BC/load counts.
    bridge_log(std::string("loadcase: entering minimize_plastic (solver=MultigridCG_Matfree)")
               + " design_box=" + std::to_string(load_case.has_design_box ? 1 : 0)
               + " part " + grid_summary(setup.grid)
               + (load_case.has_design_box ? " | SOLVED-ON expanded " + grid_summary(setup.solved_grid)
                                           : std::string(" | SOLVED-ON part grid"))
               + " nodal_loads=" + std::to_string(setup.options.external_loads.size())
               + " dirichlet_bcs=" + std::to_string(setup.bcs.size()));
    topopt::MinimizePlasticResult mp = topopt::minimize_plastic(
        setup.grid, it->second, material_name, setup.bcs, rules, setup.options);
    // Report the grid the driver ACTUALLY solved on (mp.solved_grid).
    result = to_optimize_result(mp, mp.solved_grid);
    // Handoff 100 — surface what each clearance forbade so the results screen can
    // state it honestly (which faces, how many voxels, whether it reached the grid).
    for (const auto& cr : setup.clearance_reports) {
      result.clearance_face_ids.push_back(cr.face_id);
      result.clearance_kinds.push_back(
          cr.kind == topopt::ClearanceKind::Bolt ? 0 : 1);
      result.clearance_voxels_frozen.push_back(
          static_cast<int32_t>(cr.voxels_frozen));
      result.clearance_in_grid.push_back(cr.in_grid ? 1 : 0);
    }
    // Handoff 124 — surface what each Face protection preserved so the results
    // screen can state it honestly (which faces, how many voxels, and whether the
    // face's own solid was thinner than the requested depth).
    for (const auto& pr : setup.face_protection_reports) {
      result.protection_face_ids.push_back(pr.face_id);
      result.protection_region_ids.push_back(pr.region_id);
      result.protection_voxels_frozen.push_back(
          static_cast<int32_t>(pr.voxels_frozen));
      result.protection_depth_voxels.push_back(
          static_cast<int32_t>(pr.depth_voxels));
      result.protection_thinner.push_back(pr.thinner_than_depth ? 1 : 0);
    }
    bridge_log("loadcase: minimize_plastic returned variants=" +
               std::to_string(result.variants.size()) +
               " accepted=" + std::to_string(result.accepted_count));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    bridge_log(std::string("loadcase: THREW: ") + e.what());
    return OptimizeResult{};
  }
  return result;
}

SmokeResult bridge_smoke(const std::string& materials_path,
                         const std::string& mesh_path) {
  SmokeResult s;
  try {
    topopt::MaterialLibrary lib = topopt::load_materials_file(materials_path);
    topopt::TriangleMesh mesh = import_any(mesh_path);
    s.material_count = static_cast<int32_t>(lib.size());
    s.triangle_count = static_cast<int32_t>(mesh.triangle_count());
    s.watertight = topopt::check_watertight(mesh).watertight;
    s.ok = true;
  } catch (const std::exception& e) {
    s.ok = false;
    s.message = e.what();
  }
  return s;
}

std::string core_version() { return std::string(topopt::version()); }

// --- lattice certification limits (handoff 2026-07-29-lattice-mode-ui) --------
namespace {
// Map a job-schema topology name to the core certification enum. ONLY names the
// core library actually covers map — everything else is "not certifiable", which
// is exactly what the UI needs to grey a preview-only topology. Keyed off core's
// own lattice_topology_name so it can never drift from the enum.
bool lattice_topology_from_name(const std::string& name,
                                topopt::LatticeTopology& out) {
  // Map a name to the enum ONLY if core carries a validated (certifiable) tensor for
  // it — the tetragonal variants (bccz/fccz/reentrant) are generate-but-not-certify, so
  // they never map here and the UI greys them (handoff 2026-07-29-tensor-library-nine).
  for (topopt::LatticeTopology t :
       {topopt::LatticeTopology::Octet, topopt::LatticeTopology::SimpleCubic,
        topopt::LatticeTopology::Bcc, topopt::LatticeTopology::Fcc,
        topopt::LatticeTopology::Diamond, topopt::LatticeTopology::Kelvin,
        topopt::LatticeTopology::Rhombic, topopt::LatticeTopology::Bccz,
        topopt::LatticeTopology::Fccz, topopt::LatticeTopology::Reentrant}) {
    if (topopt::lattice_topology_certifiable(t) &&
        name == topopt::lattice_topology_name(t)) {
      out = t;
      return true;
    }
  }
  return false;
}
}  // namespace

LatticeLimits lattice_limits(const std::string& topology) {
  LatticeLimits lim;
  topopt::LatticeTopology topo;
  if (!lattice_topology_from_name(topology, topo)) {
    // certifiable stays false, band stays zero — the UI greys this topology.
    return lim;
  }
  lim.certifiable = true;
  lim.rho_min = topopt::lattice_rho_min(topo);
  lim.rho_max = topopt::lattice_rho_max(topo);
  // Forwarded from core's own scale-separation floor. (The earlier stub returned
  // 0.0 claiming core exposed no accessor; topopt::lattice_cells_per_member_min
  // exists — the stale claim is fixed, the number is still never invented here.)
  lim.min_cells_per_member = topopt::lattice_cells_per_member_min(topo);
  return lim;
}

LatticeCellBounds lattice_cell_bounds(const std::string& topology,
                                      double min_extrudable_width_mm) {
  LatticeCellBounds b;
  topopt::LatticeTopology topo;
  if (!lattice_topology_from_name(topology, topo)) return b;  // valid stays false
  if (!(min_extrudable_width_mm > 0.0)) return b;
  // BOTH numbers are core's, never invented here (bar R6): the printability floor is
  // core's own one law (topopt::lattice_cell_printability_floor_mm — the same
  // function the grading law and the dyadic cell plan call), and the cells-per-member
  // floor is core's scale-separation number. The app's cell-size control reads its
  // lower bound and its per-member ceiling from these, so a re-measurement in core
  // moves the UI with no app change.
  b.printability_floor_mm =
      topopt::lattice_cell_printability_floor_mm(topo, min_extrudable_width_mm);
  b.cells_per_member_floor = topopt::lattice_cells_per_member_min(topo);
  // THE DENSEST-END FLOOR, from core's own strut-diameter law rather than an
  // app-side mirror of it (task 2026-08-05-lattice-retention-app-control, S3).
  // The first cut of this derived it in Swift from `LatticeType.strutRadiusMM` and
  // got 1.64 mm at a 0.45 mm bead where core's own arithmetic gives 1.17 — the app
  // copy of the octet law is 1.4x off. Reading it here means the control's bound
  // and core's refusal quote the SAME number by construction.
  if (topo == topopt::LatticeTopology::Octet) {
    const double phi_hi =
        topopt::octet_strut_diameter_mm(topopt::lattice_rho_max(topo), 1.0);
    if (phi_hi > 0.0) b.printability_floor_densest_mm = min_extrudable_width_mm / phi_hi;
  }
  b.percolation_cells_per_member_floor =
      topopt::lattice_percolation_cells_per_member_min(topo);
  b.valid = true;
  return b;
}

LatticeRegionDerivation lattice_region_derivation(
    const std::string& topology, double member_width_mm,
    double min_extrudable_width_mm, double stated_relative_density) {
  LatticeRegionDerivation d;
  topopt::LatticeTopology topo;
  if (!lattice_topology_from_name(topology, topo)) return d;
  if (!(member_width_mm > 0.0) || !(min_extrudable_width_mm > 0.0)) return d;
  d.valid = true;
  d.rho_max = topopt::lattice_rho_max(topo);
  const topopt::LatticeCellDerivation w = topopt::lattice_derive_cell_for_member(
      topo, member_width_mm, min_extrudable_width_mm);
  // FEASIBLE is percolation, not accuracy — the same boundary run_job draws, and
  // for the same reason: buildable-and-uncertifiable is a verdict, not a refusal.
  d.feasible = w.feasible_percolation;
  if (!d.feasible) return d;
  const double n_star = topopt::lattice_cells_per_member_min(topo);
  d.cell_mm = std::max(member_width_mm / n_star, w.min_printable_cell_mm);
  const double rho = topopt::lattice_min_density_for_strut(topo, d.cell_mm,
                                                           min_extrudable_width_mm);
  d.derived_relative_density = rho >= 0.0 ? rho : d.rho_max;
  d.relative_density = stated_relative_density > 0.0 ? stated_relative_density
                                                     : d.derived_relative_density;
  if (topo == topopt::LatticeTopology::Octet)
    d.strut_mm = topopt::octet_strut_diameter_mm(d.relative_density, d.cell_mm);
  d.cells_per_member = member_width_mm / d.cell_mm;
  d.out_of_regime = d.cells_per_member < n_star;
  d.prints = d.strut_mm + 1e-12 >= min_extrudable_width_mm;
  return d;
}

std::vector<std::string> lattice_certifiable_topologies() {
  // The core certification library's covered set, in core order — mirrored directly
  // from core so it can never drift from the enum (handoff
  // 2026-07-29-tensor-library-nine widened this from octet-only to the seven cubic
  // topologies; the three tetragonal ones are deliberately absent — not certifiable).
  return topopt::lattice_certifiable_topology_names();
}

// ---------------------------------------------------------------------------
// SUB-FLOOR RETENTION — asking core's own parser what it accepts (task
// 2026-08-05-lattice-retention-app-control).
namespace {

// A job document valid all the way down to the `grading` block, so the probe key
// reaches `reject_unknown_keys` — the FIRST statement inside that block. Nothing
// here runs: `parse_job` is pure schema validation over a string (core/CMakeLists
// puts src/cli/job.cpp in the always-built library for exactly this reason), so
// the probe costs a parse and touches no file, no solver and no geometry.
// A lattice include region, for the probes whose mode REQUIRES one. Core refuses
// `cell_mode: "fit"` on a job that declares no include region ("a job that declares
// none states no requirement to fit", job.cpp) — so a probe without one measures that
// rule instead of whether the core knows the mode at all. Found by the probe's own
// two-sided control failing against a core that does carry fit.
const char* kProbeIncludeRegion =
    ", \"regions\": [{\"role\": \"include\", \"kind\": \"bolt\", \"geometry\": "
    "{\"axis_point\": [0.0, 0.0, 0.0], \"axis_dir\": [1.0, 0.0, 0.0], "
    "\"radius_mm\": 4.0, \"half_length_mm\": 4.0}}]";

std::string probe_job_json(const std::string& grading_body,
                           const std::string& lattice_extra = std::string()) {
  return std::string(
             "{\n"
             "  \"model\": \"probe.step\",\n"
             "  \"material\": \"PLA\",\n"
             "  \"mode\": \"minimize_plastic\",\n"
             "  \"resolution\": 16,\n"
             "  \"fixture_faces\": [{\"kind\": \"cylindrical\", \"radius_mm\": 1.0}],\n"
             "  \"gravity\": {\"direction\": [0.0, 0.0, -1.0], "
             "\"magnitude_mm_s2\": 9810.0},\n"
             "  \"ladder\": [0.5],\n"
             "  \"margin_stop\": 1.5,\n"
             "  \"output\": {\"report\": \"report.json\", \"mesh_format\": "
             "\"stl\", \"mesh_prefix\": \"variant\"},\n"
             "  \"lattice\": {\"topology\": \"octet\", \"emit_stl\": true") +
         lattice_extra + "},\n  \"grading\": {" + grading_body + "}\n}\n";
}

// The grading block a probe submits: the keys every core since the grading law
// has required, retention ARMED (the two PR-298 keys are schema-gated on it), and
// the key under test last.
std::string probe_grading_body(const std::string& key) {
  return "\n"
         "    \"topology\": \"octet\",\n"
         "    \"cell_mm\": 4.0,\n"
         "    \"min_extrudable_width_mm\": 0.45,\n"
         "    \"retain_subfloor_in_unloaded_regions\": true,\n"
         "    \"" +
         key + "\": true\n  ";
}

// Did core refuse THIS key by name? `reject_unknown_keys` throws
// `unknown key "<key>" in grading`, so the answer is unambiguous and does not
// depend on any other diagnostic staying stable.
bool schema_refused_key_by_name(const std::string& key) {
  try {
    topopt::parse_job(probe_job_json(probe_grading_body(key)));
    return false;  // parsed clean: the key is accepted
  } catch (const std::exception& e) {
    const std::string msg = e.what();
    return msg.find("unknown key \"" + key + "\"") != std::string::npos;
  }
}

// THE TWO-SIDED CONTROL. A probe that silently stopped reaching the grading block
// would report every key as "accepted" — the direction that emits a key core
// refuses and kills the job. So the probe proves itself both ways before it is
// believed: a key core has carried since the grading law landed must come back
// ACCEPTED, and a key no core will ever carry must come back REFUSED.
//
// ★ THE NEGATIVE CONTROL MUST NOT START WITH AN UNDERSCORE. Core's parser treats
// a leading-underscore key as a maintainer COMMENT and ignores it at every level
// (`is_comment_key`, core/src/cli/job.cpp) — so the first version of this control
// used "__topopt_bridge_probe_key_no_core_accepts", core cheerfully accepted it,
// the control failed, and the probe reported itself unreliable on a core it could
// read perfectly well. The control caught it, which is the point of having one.
bool probe_reliable() {
  static const bool ok =
      !schema_refused_key_by_name("demand_exponent") &&
      schema_refused_key_by_name("topopt-bridge-probe-key-no-core-accepts");
  return ok;
}

}  // namespace

bool grading_schema_probe_is_reliable() { return probe_reliable(); }

std::string job_schema_error(const std::string& job_json) {
  try {
    topopt::parse_job(job_json);
    return std::string();
  } catch (const std::exception& e) {
    return std::string(e.what());
  }
}

bool grading_schema_accepts(const std::string& key) {
  if (key.empty()) return false;
  if (!probe_reliable()) return false;  // cannot tell => do not emit
  return !schema_refused_key_by_name(key);
}

bool grading_schema_accepts_cell_mode(const std::string& mode) {
  if (mode.empty()) return false;
  if (!probe_reliable()) return false;  // cannot tell => do not offer
  // "auto" and "fit" REFUSE a target cell alongside them and "swept" needs its two
  // ladder ends instead, so the probe body cannot be one shape for every mode. It
  // states the mode and exactly the companion keys that mode requires; anything
  // else and the probe would measure the companion rule rather than the mode.
  std::string body =
      "\n"
      "    \"topology\": \"octet\",\n"
      "    \"min_extrudable_width_mm\": 0.45,\n"
      "    \"cell_mode\": \"" + mode + "\"";
  if (mode == "fixed")
    body += ",\n    \"cell_mm\": 4.0";
  else if (mode == "swept")
    body += ",\n    \"cell_min_mm\": 4.0,\n    \"cell_max_mm\": 8.0";
  body += "\n  ";
  try {
    // The include region is present for EVERY mode, not only fit: it is legal on all
    // four (a region-scoped lattice), so one document shape keeps the probe answering
    // the same question each time.
    topopt::parse_job(probe_job_json(body, kProbeIncludeRegion));
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

double lattice_subfloor_stress_fraction_default() {
  return topopt::lattice_subfloor_retention_stress_fraction();
}

std::vector<std::string> lattice_generatable_topologies() {
  // The geometry generator's covered set, READ from core's own enumerator
  // (topopt::lattice_gen_topology_names — added by task lattice-page-core-hookup,
  // closing the gap handoff 2026-07-30-lattice-page reported). No mirrored case
  // list remains here: when core grows the enum, this picks it up with zero app
  // changes, and core's enum-probe test (test_lattice_gen) fails if the core list
  // itself ever drifts from the enum.
  return topopt::lattice_gen_topology_names();
}

}  // namespace topoptbridge

namespace topoptbridge {

namespace {

// The denominator the intent selects. AESTHETIC uses a FULL SORT — deterministic by
// construction (amendment §1b / bar R16), never a sampled estimate — of the same
// samples core sorts.
double demand_reference_impl(const float* vm, std::size_t n, int intent,
                             double allowable_mpa, double percentile) {
  if (intent == 0) return allowable_mpa;          // structural
  if (vm == nullptr || n == 0) return 0.0;
  std::vector<double> d;
  d.reserve(n);
  for (std::size_t i = 0; i < n; ++i)
    if (std::isfinite(vm[i]) && vm[i] > 0.0f) d.push_back(static_cast<double>(vm[i]));
  if (d.empty()) return 0.0;
  std::sort(d.begin(), d.end());
  const double q = percentile > 0.0 ? percentile : topopt::kAestheticPercentile;
  std::size_t k = static_cast<std::size_t>(q * (d.size() - 1));
  if (k >= d.size()) k = d.size() - 1;
  return d[k];
}

}  // namespace

double grading_demand_reference(const float* von_mises, std::size_t n, int intent,
                                double allowable_mpa, double percentile) {
  return demand_reference_impl(von_mises, n, intent, allowable_mpa, percentile);
}

void grading_demand_fraction_into(const float* von_mises, std::size_t n, int intent,
                                  double allowable_mpa, double percentile,
                                  double utilisation_target, float* out) {
  if (von_mises == nullptr || out == nullptr) return;
  const double ref =
      demand_reference_impl(von_mises, n, intent, allowable_mpa, percentile);
  const topopt::GradingIntent gi = intent == 0 ? topopt::GradingIntent::Structural
                                               : topopt::GradingIntent::Aesthetic;
  for (std::size_t i = 0; i < n; ++i) {
    const double v = std::isfinite(von_mises[i]) ? von_mises[i] : 0.0;
    // ★ CORE'S OWN FUNCTION. Not a Swift or bridge restatement of it.
    out[i] = static_cast<float>(
        topopt::grading_demand_fraction(gi, v, ref, utilisation_target));
  }
}

}  // namespace topoptbridge
