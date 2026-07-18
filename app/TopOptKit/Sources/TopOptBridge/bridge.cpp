// Implementation of the TopOptBridge facade (ROADMAP M7.1). All heavy includes
// — the topopt core headers, and through them OCCT/Eigen — live here, never in
// the header the Swift importer sees. Core exceptions are caught and converted
// to BridgeError so nothing throws across the language boundary.
#include "TopOptBridge.hpp"

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

#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
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

// TriangleMesh -> ImportedMesh (flattened buffers + watertight flag).
ImportedMesh to_imported(const topopt::TriangleMesh& m,
                         const std::vector<int>* face_ids, int face_count) {
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

bool has_suffix_ci(const std::string& s, const std::string& suffix) {
  if (s.size() < suffix.size()) return false;
  for (std::size_t i = 0; i < suffix.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(s[s.size() - suffix.size() + i])) !=
        std::tolower(static_cast<unsigned char>(suffix[i])))
      return false;
  }
  return true;
}

// Import any supported geometry by file extension. STEP requires OpenCASCADE,
// which is linked only in the desktop (macOS) build (ARCHITECTURE §4/§10);
// TOPOPT_BRIDGE_HAS_OCCT is defined there. On platforms without it a .step/.stp
// path is rejected with a clear message and STL remains fully available.
topopt::TriangleMesh import_any(const std::string& path) {
  if (has_suffix_ci(path, ".step") || has_suffix_ci(path, ".stp")) {
#ifdef TOPOPT_BRIDGE_HAS_OCCT
    return topopt::import_step_file(path).mesh;
#else
    throw std::runtime_error(
        "STEP import requires OpenCASCADE, which is not available on this "
        "platform; import an STL instead");
#endif
  }
  return topopt::read_stl_file(path).mesh;
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
  result.cancelled = mp.cancelled;
  result.accepted_count = static_cast<int32_t>(mp.report.variants.size());
  set_grid_metadata(result, grid);
  // `grid` here is mp.solved_grid (the caller passes it, loadcase path) or the
  // no-box selfweight grid, which equals solved_grid — the grid every variant's
  // physical_density is indexed to. Smooth the export/display mesh against it.
  for (const auto& v : mp.evaluated)
    result.variants.push_back(
        to_optimize_variant(v, grid, kSmoothExportFactor));
  return result;
}

// Wire the core on_variant callback to a C VariantFn: package each streamed
// variant as a one-variant OptimizeResult (carrying the run's grid metadata, which
// the Swift side needs to build a live results view) and hand it across.
void set_variant_stream(topopt::MinimizePlasticOptions& opts,
                        const topopt::VoxelGrid& grid, VariantFn variant_fn,
                        void* variant_ctx) {
  if (variant_fn == nullptr) return;
  opts.on_variant = [variant_fn, variant_ctx,
                     &grid](const topopt::MinimizePlasticVariant& v) {
    OptimizeResult one;
    one.accepted_count = 1;
    set_grid_metadata(one, grid);
    // `grid` is the solved grid (minimize_plastic_solved_grid, captured by ref):
    // the same grid the streamed variant's physical_density is indexed to.
    one.variants.push_back(to_optimize_variant(v, grid, kSmoothExportFactor));
    variant_fn(variant_ctx, &one);
  };
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
    return to_imported(model.mesh, &model.triangle_face, model.face_count);
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

int64_t tag_step_face(const std::string& step_path, int face_id,
                      bool as_fixture, int resolution, BridgeError& err) {
#ifdef TOPOPT_BRIDGE_HAS_OCCT
  try {
    topopt::StepModel model = topopt::import_step_file(step_path);
    topopt::VoxelGrid g = topopt::voxelize(model.mesh, resolution);
    const topopt::VoxelTag tag =
        as_fixture ? topopt::VoxelTag::Fixture : topopt::VoxelTag::Load;
    return static_cast<int64_t>(topopt::tag_step_face(g, model, face_id, tag));
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
    return 0;
  }
#else
  (void)step_path;
  (void)face_id;
  (void)as_fixture;
  (void)resolution;
  err.ok = false;
  err.message =
      "STEP face tagging requires OpenCASCADE, which is not available on this "
      "platform";
  return 0;
#endif
}

int64_t mask_step_face(const std::string& step_path, int face_id,
                       int mask_value, int depth_voxels, int resolution,
                       BridgeError& err) {
#ifdef TOPOPT_BRIDGE_HAS_OCCT
  try {
    if (mask_value < 0 || mask_value > 2)
      throw std::invalid_argument(
          "mask_value must be 0 (Active), 1 (FrozenSolid), or 2 (FrozenVoid)");
    topopt::StepModel model = topopt::import_step_file(step_path);
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
#else
  (void)step_path;
  (void)face_id;
  (void)mask_value;
  (void)depth_voxels;
  (void)resolution;
  err.ok = false;
  err.message =
      "STEP face masking requires OpenCASCADE, which is not available on this "
      "platform";
  return 0;
#endif
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

OptimizeResult run_minimize_plastic_loadcase(
    const std::string& step_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, const BridgeLoadCase& load_case, ProgressFn progress,
    void* ctx, const bool* cancel_flag, VariantFn variant_fn, void* variant_ctx,
    BridgeError& err) {
#ifdef TOPOPT_BRIDGE_HAS_OCCT
  OptimizeResult result;
  try {
    bridge_log("loadcase: ENTER res=" + std::to_string(resolution) +
               " anchors=" + std::to_string(load_case.anchor_face_ids.size()) +
               " load_groups=" + std::to_string(load_case.load_group_sizes.size()) +
               " load_faces=" + std::to_string(load_case.load_face_ids.size()) +
               " minimize_plastic=" + std::to_string(load_case.minimize_plastic ? 1 : 0) +
               " design_box=" + std::to_string(load_case.has_design_box ? 1 : 0));
    bridge_log("loadcase: importing STEP '" + step_path + "'");
    topopt::StepModel model = topopt::import_step_file(step_path);
    bridge_log("loadcase: STEP imported; building shared production setup");

    // Map the flat BridgeLoadCase to the front-end-neutral ProductionLoadCase and
    // hand it to build_production_loadcase — the SINGLE grid/BC/options builder the
    // CLI also calls, so the app and topopt-cli produce the same design for the
    // same STEP + load case + resolution (handoff 093). The flattened load groups
    // (group g's faces are the load_group_sizes[g] entries of load_face_ids after
    // the earlier groups', its force load_forces[3g..3g+2]) unflatten here.
    topopt::ProductionLoadCase lc;
    lc.anchor_face_ids.assign(load_case.anchor_face_ids.begin(),
                              load_case.anchor_face_ids.end());
    {
      const std::size_t group_count = load_case.load_group_sizes.size();
      std::size_t face_off = 0;
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
        lc.load_groups.push_back(std::move(lg));
      }
    }
    lc.minimize_plastic = load_case.minimize_plastic;
    lc.build_dir = topopt::Vec3{load_case.build_dir_x, load_case.build_dir_y,
                                load_case.build_dir_z};
    lc.infill_percent = static_cast<double>(load_case.infill_percent);
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

    // Handoff 100 — unflatten the "Keep clear" clearances. Each region ships only
    // a face id + kind + editable distances; build_production_loadcase re-reads
    // the exact bore axis/radius or plane normal from the STEP. A distance the app
    // left at 0 defaults to the same spec suggestion the CLI uses (for a bolt,
    // derived from the bore radius). No clearance → byte-identical to today.
    {
      const std::size_t cn = load_case.clearance_face_ids.size();
      for (std::size_t c = 0; c < cn; ++c) {
        topopt::ProductionLoadCase::Clearance cl;
        cl.face_id = load_case.clearance_face_ids[c];
        const bool bolt =
            c < load_case.clearance_kinds.size() && load_case.clearance_kinds[c] == 0;
        double bore_r = 0.0;
        if (bolt && cl.face_id >= 0 && cl.face_id < model.face_count)
          bore_r = model.faces[static_cast<std::size_t>(cl.face_id)]
                       .cylinder_radius_mm;
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
        lc.clearances.push_back(cl);
      }
    }

    topopt::ProductionRunSetup setup =
        topopt::build_production_loadcase(model, resolution, lc);
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

    // The last checkpoint before the solve: if the device log stops here, the
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
#else
  (void)variant_fn;
  (void)variant_ctx;
  (void)step_path;
  (void)material_name;
  (void)materials_path;
  (void)rules_path;
  (void)resolution;
  (void)load_case;
  (void)progress;
  (void)ctx;
  (void)cancel_flag;
  err.ok = false;
  err.message =
      "Load-case optimization requires OpenCASCADE (STEP face selection), which "
      "is not available on this platform";
  return OptimizeResult{};
#endif
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

}  // namespace topoptbridge
