// Implementation of the TopOptBridge facade (ROADMAP M7.1). All heavy includes
// — the topopt core headers, and through them OCCT/Eigen — live here, never in
// the header the Swift importer sees. Core exceptions are caught and converted
// to BridgeError so nothing throws across the language boundary.
#include "TopOptBridge.hpp"

#include <atomic>
#include <cctype>
#include <cmath>
#include <exception>
#include <functional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/version.hpp"
#include "topopt/voxel.hpp"

namespace topoptbridge {
namespace {

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
std::vector<double> reduction_ladder() { return {0.68, 0.52, 0.38, 0.26}; }

// Turn on the M6.3 single-field Heaviside projection + beta-continuation on a
// run's SIMP options, for crisp (near-0/1) density with a minimum length scale.
// Uses the locked continuation schedule. Non-empty `projection` makes the loop
// run the staged schedule (its own iterations/move) instead of the plain M3.4
// loop — noticeably more compute per variant, in exchange for printable,
// threshold-stable geometry.
//
// The minimum length scale is set PHYSICALLY (M7.rmin): min_feature_mm is a
// nozzle-scale FDM feature size in mm, and minimize_plastic converts it to the
// voxel-unit filter radius per rung from the grid spacing, so the minimum
// member thickness is the same in mm at every voxel resolution (a fixed voxel
// radius is not — it shrinks in mm as the grid refines, so thin members
// proliferate at high resolution: diagnosis 060). 2.5 mm reproduces the M6.3
// rmin = 2.5 voxels exactly on the 1.0 mm-spaced Gate-V2 benchmark geometry
// (DECISIONS 2026-07-10), keeping that decision numerically continuous, while
// scaling correctly for real parts voxelized at 64^3..128^3.
void enable_projection(topopt::MinimizePlasticOptions& opts) {
  opts.simp.projection = topopt::heaviside_continuation_schedule();
  opts.min_feature_mm = 2.5;  // mm; per-rung -> filter_radius = 2.5 / spacing
}

// One core variant -> the flat bridge OptimizeVariant (M7.0b/M7.8 fields). Shared
// by the result builder AND the progressive-results stream, so there is one source
// of truth for the mapping.
OptimizeVariant to_optimize_variant(const topopt::MinimizePlasticVariant& v) {
  OptimizeVariant ov;
  ov.requested_volume_fraction = v.requested_volume_fraction;
  ov.achieved_volume_fraction = v.optimization.volume_fraction;
  ov.mass_grams = v.mass_grams;
  ov.support_volume_voxels = v.support_volume_voxels;
  ov.mesh_triangle_count = static_cast<int32_t>(v.mesh().triangle_count());
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
  const topopt::TriangleMesh& vm = v.mesh();
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
  for (const auto& v : mp.evaluated)
    result.variants.push_back(to_optimize_variant(v));
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
    one.variants.push_back(to_optimize_variant(v));
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
    // Part -> voxel grid.
    topopt::TriangleMesh mesh = import_any(stl_path);
    topopt::VoxelGrid grid = topopt::voxelize(mesh, resolution);

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
    enable_projection(opts);                           // M6.3 crisp density
    opts.keyframe_count = 12;   // optimization-history playback
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

    topopt::MinimizePlasticResult mp =
        topopt::minimize_plastic(grid, it->second, material_name, bcs, rules, opts);
    result = to_optimize_result(mp, grid);
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
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
    topopt::StepModel model = topopt::import_step_file(step_path);
    topopt::VoxelGrid grid = topopt::voxelize(model.mesh, resolution);

    // Anchors -> Fixture (clamped + retained). Snapshot the anchors-only grid as
    // the clean base for per-group traction, so each group's traction covers ONLY
    // its own faces (traction_loads spreads a force over every Load voxel it sees).
    for (int32_t fid : load_case.anchor_face_ids)
      topopt::tag_step_face(grid, model, fid, topopt::VoxelTag::Fixture);
    const topopt::VoxelGrid base_grid = grid;

    std::vector<topopt::NodalLoad> external;
    const std::size_t group_count = load_case.load_group_sizes.size();
    std::size_t face_off = 0;
    for (std::size_t g = 0; g < group_count; ++g) {
      const std::size_t n = static_cast<std::size_t>(load_case.load_group_sizes[g]);
      const topopt::Vec3 force{
          3 * g + 0 < load_case.load_forces.size() ? load_case.load_forces[3 * g + 0] : 0.0,
          3 * g + 1 < load_case.load_forces.size() ? load_case.load_forces[3 * g + 1] : 0.0,
          3 * g + 2 < load_case.load_forces.size() ? load_case.load_forces[3 * g + 2] : 0.0};
      // The face ids of this group (a slice of the flattened load_face_ids).
      std::vector<int32_t> faces;
      for (std::size_t f = 0; f < n && face_off + f < load_case.load_face_ids.size(); ++f)
        faces.push_back(load_case.load_face_ids[face_off + f]);
      face_off += n;
      if (!(std::fabs(force.x) + std::fabs(force.y) + std::fabs(force.z) > 0.0))
        continue;  // a zero-force group contributes nothing
      topopt::VoxelGrid gg = base_grid;  // anchors only, no other group's Load
      bool any = false;
      for (int32_t fid : faces)
        if (topopt::tag_step_face(gg, model, fid, topopt::VoxelTag::Load) > 0)
          any = true;
      if (!any) continue;
      const std::vector<topopt::NodalLoad> tl =
          topopt::traction_loads(gg, topopt::VoxelTag::Load, force);
      external.insert(external.end(), tl.begin(), tl.end());
      // Retain the load faces on the MAIN grid (Load voxels are implicitly
      // FrozenSolid, so the surface the traction sits on is never optimized away).
      for (int32_t fid : faces)
        topopt::tag_step_face(grid, model, fid, topopt::VoxelTag::Load);
    }

    // Dirichlet BCs from the Fixture voxels (clamp all 8 corner nodes, deduped).
    std::vector<topopt::DirichletBC> bcs;
    std::set<int> clamped;
    auto clamp_node = [&](int n) {
      if (clamped.insert(n).second) {
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }
    };
    bool any_fixture = false;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i)
          if (grid.tag(i, j, k) == topopt::VoxelTag::Fixture) {
            any_fixture = true;
            for (int dk = 0; dk <= 1; ++dk)
              for (int dj = 0; dj <= 1; ++dj)
                for (int di = 0; di <= 1; ++di)
                  clamp_node(
                      topopt::fea_node_index(grid, i + di, j + dj, k + dk));
          }
    if (!any_fixture) {
      // No anchors declared: fall back to clamping the min-x boundary so the
      // system is well-posed (mirrors run_minimize_plastic).
      for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
          if (grid.solid(0, j, k))
            grid.set_tag(0, j, k, topopt::VoxelTag::Fixture);
      for (int c = 0; c <= grid.nz; ++c)
        for (int b = 0; b <= grid.ny; ++b)
          clamp_node(topopt::fea_node_index(grid, 0, b, c));
    }

    topopt::MaterialLibrary lib = topopt::load_materials_file(materials_path);
    auto it = lib.find(material_name);
    if (it == lib.end()) {
      err.ok = false;
      err.message = "material not found: " + material_name;
      return OptimizeResult{};
    }
    topopt::SettingsRules rules = topopt::load_settings_rules_file(rules_path);

    // Build direction (orientation for the interlayer margin); default +Z.
    topopt::Vec3 build_dir{load_case.build_dir_x, load_case.build_dir_y,
                           load_case.build_dir_z};
    if (!(std::fabs(build_dir.x) + std::fabs(build_dir.y) +
              std::fabs(build_dir.z) >
          0.0))
      build_dir = topopt::Vec3{0.0, 0.0, 1.0};

    std::atomic<bool> cancelled{cancel_flag != nullptr && *cancel_flag};
    topopt::MinimizePlasticOptions opts;
    opts.cancel = &cancelled;
    opts.external_loads = external;  // the user's load case (mode a); empty => self-weight
    // gravity_direction defines the reported build orientation = its unit negation.
    opts.gravity_direction =
        topopt::Vec3{-build_dir.x, -build_dir.y, -build_dir.z};
    opts.gravity = 9810.0 * 1e-9;  // self-weight magnitude, used only if external is empty
    opts.volume_fraction_ladder = load_case.minimize_plastic
                                      ? reduction_ladder()
                                      : std::vector<double>{0.9};
    enable_projection(opts);   // M6.3 crisp density
    opts.keyframe_count = 12;   // optimization-history playback
    // M7.params — the user's infill-density override arrives here as
    // load_case.infill_percent (0–100, or < 0 for "no override"). It is CAPTURED
    // at the bridge boundary but NOT yet fed to the optimizer: consuming it is the
    // M7.infill-margin ladder knockdown, which needs a field on the core's
    // MinimizePlasticOptions (a /core/ change owned by that task, out of M7.params
    // scope). When that field lands, set it here from load_case.infill_percent. See
    // the M7.params handoff. (void)-cast so the plumbed value is not flagged unused.
    (void)load_case.infill_percent;
    opts.progress = [&](std::size_t r, std::size_t rc, int iter) {
      if (progress != nullptr)
        progress(ctx, static_cast<uint64_t>(r), static_cast<uint64_t>(rc), iter);
      if (cancel_flag != nullptr && *cancel_flag) cancelled.store(true);
    };

    set_variant_stream(opts, grid, variant_fn, variant_ctx);  // progressive results

    topopt::MinimizePlasticResult mp = topopt::minimize_plastic(
        grid, it->second, material_name, bcs, rules, opts);
    result = to_optimize_result(mp, grid);
  } catch (const std::exception& e) {
    err.ok = false;
    err.message = e.what();
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
