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
std::vector<double> reduction_ladder() { return {0.68, 0.52, 0.38, 0.26}; }

// M7.anchor-integrity (FIX 1) — depth, in voxels, of the FrozenSolid structural
// pad frozen behind each anchor/load face on the loadcase run path. tag_step_face
// freezes only a ~1-voxel BC skin (thr2 = 0.25*h*h; step.cpp), so the material
// behind it is a free design variable the optimizer carves away, leaving the
// anchor boss a paper-thin film that then gets isolated and discarded (diagnosis
// 064). Freezing a pad this many voxels deep (via mask_step_face, FrozenSolid)
// ties the boundary condition into the body so the optimizer must route load
// through a real structural region. 3 is a conservative default: deep enough to
// be a structural pad (> the 2-voxel min-feature size, §7 V3) without pinning a
// large fraction of a small part. Tunable — raise for chunkier anchors.
constexpr int kAnchorPadDepthVoxels = 3;

// M7.anchor-integrity (FIX 2) — the ladder-floor multiple handed to
// minimize_plastic on the loadcase path (MinimizePlasticOptions::margin_floor_
// multiple). The ladder stops stripping once an accepted rung's worst-case margin
// is >= this multiple of margin_stop (1.5), i.e. >= 3.0 here — so a rung that
// clears 2x the margin_stop comfort floor is the terminal accepted variant. This
// keeps a lightly-loaded part from being walked to the lightest rung (0.26 VF)
// just because it can survive there. Conservative seed; the maintainer can tune it
// after seeing results (one-line change). Setting it to +infinity (or removing the
// opts.margin_floor_multiple assignment) reverts to the legacy walk-to-the-
// lightest-safe-rung behavior exactly (minimize_plastic asserts that equivalence).
constexpr double kAnchorMarginFloorMultiple = 2.0;   // stop the ladder once a rung
                                                     // clears 2x the margin_stop
                                                     // comfort floor

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
  // TEMPORARY (Option B): the Heaviside projection schedule is OC-only. The
  // M7.mma.4 switchover made MMA the production default (MinimizePlasticOptions::
  // updater), and simp_optimize rejects MMA + a non-empty projection schedule
  // (the projected chain is the OC-locked Gate-V2 formulation) — so enabling
  // projection unconditionally makes every real MMA run throw. Gate it on the
  // updater: apply the projection schedule only when the run uses OC. When MMA
  // drives the ladder we skip projection, so the run completes cleanly at the
  // cost of slightly softer density boundaries. Crisp-density projection on MMA
  // is a deferred future task (Option A). The physical min-feature length scale
  // is set for BOTH updaters — it is a filter radius, not projection, and keeps
  // the OC + projection Gate-V2 chain byte-identical.
  if (topopt::projection_supported(opts.updater))
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
    // Production runs use the MATRIX-FREE geometric-multigrid accelerator (handoff
    // 072/073/078 + design-box on-device fix): it solves the identical system to
    // the same tolerance and falls back to exact Jacobi-CG if a hierarchy is not
    // applicable, so the result is always correct. Matrix-free never assembles the
    // fine stiffness K, whose ~7 GB peak was the design-box std::bad_alloc; the
    // design-box grid is padded to coarsening-friendly dims so multigrid actually
    // engages (an odd axis otherwise falls back to an effectively-hung Jacobi-CG).
    // The library default stays JacobiCG so Gate-V2 and the locked reference are
    // untouched. This is the flip.
    opts.simp.solver = topopt::SolverKind::MultigridCG_Matfree;
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
    bridge_log("loadcase: STEP imported; voxelizing");
    topopt::VoxelGrid grid = topopt::voxelize(model.mesh, resolution);
    bridge_log("loadcase: voxelized " + grid_summary(grid));

    // Anchors -> Fixture (clamped + retained). Snapshot the anchors-only grid as
    // the clean base for per-group traction, so each group's traction covers ONLY
    // its own faces (traction_loads spreads a force over every Load voxel it sees).
    for (int32_t fid : load_case.anchor_face_ids)
      topopt::tag_step_face(grid, model, fid, topopt::VoxelTag::Fixture);
    const topopt::VoxelGrid base_grid = grid;

    std::vector<topopt::NodalLoad> external;
    // M7.anchor-integrity (FIX 1): the load faces actually retained on the main
    // grid (the non-zero groups), collected so their structural pad is frozen
    // alongside the anchors' below. Mirrors exactly the faces tagged Load at the
    // "retain the load faces" step, so no zero-force / empty group is padded.
    std::vector<int32_t> retained_load_faces;
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
      for (int32_t fid : faces) {
        topopt::tag_step_face(grid, model, fid, topopt::VoxelTag::Load);
        retained_load_faces.push_back(fid);
      }
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
    // Production runs use the MATRIX-FREE geometric-multigrid accelerator (handoff
    // 072/073/078 + design-box on-device fix): it solves the identical system to
    // the same tolerance and falls back to exact Jacobi-CG if a hierarchy is not
    // applicable, so the result is always correct. Matrix-free never assembles the
    // fine stiffness K, whose ~7 GB peak was the design-box std::bad_alloc; the
    // design-box grid is padded to coarsening-friendly dims so multigrid actually
    // engages (an odd axis otherwise falls back to an effectively-hung Jacobi-CG).
    // The library default stays JacobiCG so Gate-V2 and the locked reference are
    // untouched. This is the flip.
    opts.simp.solver = topopt::SolverKind::MultigridCG_Matfree;
    opts.external_loads = external;  // the user's load case (mode a); empty => self-weight
    // gravity_direction defines the reported build orientation = its unit negation.
    opts.gravity_direction =
        topopt::Vec3{-build_dir.x, -build_dir.y, -build_dir.z};
    opts.gravity = 9810.0 * 1e-9;  // self-weight magnitude, used only if external is empty
    opts.volume_fraction_ladder = load_case.minimize_plastic
                                      ? reduction_ladder()
                                      : std::vector<double>{0.9};

    // M7.anchor-integrity (FIX 1): freeze an N-voxel structural PAD behind every
    // anchor and (retained) load face, not just the 1-voxel BC skin tag_step_face
    // produces. mask_step_face marks the first kAnchorPadDepthVoxels solid layers
    // FrozenSolid; minimize_plastic pins them to density 1 and keeps them out of
    // the design, so the anchor boss + hole bosses are tied into the body and the
    // optimizer must route load through them instead of carving them away
    // (diagnosis 064). Composes with the M1.6 Load/Fixture tags (still forced
    // FrozenSolid by the core), so the mask only ADDS keep-in pad voxels. Only the
    // loadcase (recommendation-ladder) path pads; the fixed single-fraction
    // preview (minimize_plastic == false) is left untouched.
    //
    // M7.anchor-integrity on the box path (handoff 082): build the pad on BOTH the
    // no-box AND the design-box path. The old code skipped it under a design box on
    // the assumption that "expand_design_domain freezes EVERY imported-part solid
    // voxel as FrozenSolid, so the bosses are already tied into the frozen body."
    // Handoff 080 (whole-domain optimize, freeze_imported_part == false — now the
    // box default) made the imported part Active/REMOVABLE: only the 1-voxel
    // Load/Fixture BC skin is pinned, and the optimizer can carve the boss behind an
    // anchor thin. So that assumption is FALSE and the pad IS needed here. The pad is
    // built on the PART grid (mask_step_face walks the part's solid layers); the core
    // remaps it onto the expanded grid by the same offset it applies to the BCs/loads
    // and merges it into the effective mask (minimize_plastic, design_box +
    // design_mask are now compatible on the whole-domain path). The ladder floor
    // (FIX 2) is orthogonal and applies either way.
    if (load_case.minimize_plastic) {
      topopt::DesignMask pad = topopt::make_active_mask(grid);
      for (int32_t fid : load_case.anchor_face_ids)
        topopt::mask_step_face(grid, model, fid, topopt::MaskValue::FrozenSolid,
                               kAnchorPadDepthVoxels, pad);
      for (int32_t fid : retained_load_faces)
        topopt::mask_step_face(grid, model, fid, topopt::MaskValue::FrozenSolid,
                               kAnchorPadDepthVoxels, pad);
      opts.design_mask = std::move(pad);
      // M7.anchor-integrity (FIX 2): floor the reduction ladder so a lightly-
      // loaded part is not stripped to the lightest rung once it is comfortably
      // strong. Only meaningful when the ladder actually walks (minimize_plastic).
      opts.margin_floor_multiple = kAnchorMarginFloorMultiple;
    }

    // M7.dom-app: the design-domain expansion. When the app defined a design box,
    // hand it (and any keep-outs) to the core so the optimizer voxelizes onto the
    // larger grid and grows material into the box beyond the frozen import
    // (dom-core expand_design_domain). Model space matches the voxel/mesh frame, so
    // the box coordinates pass straight through. Left unset → BYTE-IDENTICAL to the
    // pre-M7.dom-app run (the default no-box path).
    if (load_case.has_design_box) {
      topopt::DesignBox db;
      db.min = topopt::Vec3{load_case.design_box_min_x, load_case.design_box_min_y,
                            load_case.design_box_min_z};
      db.max = topopt::Vec3{load_case.design_box_max_x, load_case.design_box_max_y,
                            load_case.design_box_max_z};
      opts.design_box = db;
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
        opts.keep_out_boxes.push_back(ko);
      }
    }

    enable_projection(opts);   // M6.3 crisp density
    opts.keyframe_count = 12;   // optimization-history playback
    // M7.infill-margin — feed the user's infill-density override into the ladder
    // acceptance-gate knockdown. load_case.infill_percent is a PERCENT in [0, 100],
    // or < 0 for "no override" (use the M5.1 recommendation, i.e. no knockdown).
    // The core defaults opts.infill_percent to 100 (solid => knockdown 1.0 =>
    // current behavior EXACTLY), so only forward an actual override; a negative
    // value leaves the default untouched. This scales ONLY the acceptance margin —
    // infill never enters the FEA (ARCHITECTURE §2 unchanged); see
    // minimize_plastic infill_margin_knockdown().
    if (load_case.infill_percent >= 0)
      opts.infill_percent = static_cast<double>(load_case.infill_percent);
    opts.progress = [&](std::size_t r, std::size_t rc, int iter) {
      if (progress != nullptr)
        progress(ctx, static_cast<uint64_t>(r), static_cast<uint64_t>(rc), iter);
      if (cancel_flag != nullptr && *cancel_flag) cancelled.store(true);
    };

    // M7.dom-app: which grid the RESULT arrays live on. minimize_plastic takes the
    // PART grid and (when design_box is set) expands INTERNALLY, so every variant's
    // mesh, von-Mises/displacement field and playback are indexed to the EXPANDED
    // grid. The reported grid metadata (dims/origin/spacing — used by the app to
    // sample the grid-indexed fields at a mesh vertex) must therefore describe that
    // grid, not the part grid. Ask the solver which grid it will solve on rather
    // than re-deriving the expansion here: minimize_plastic_solved_grid runs the
    // SAME expand_design_domain call the driver runs (options.freeze_imported_part,
    // kDesignBoxCoarsenAlign — no defaults to drift out of sync), and the value it
    // returns equals the mp.solved_grid the driver reports below, voxel-for-voxel.
    // We need it up front because the progressive-variant stream is registered on
    // `opts` (below) BEFORE minimize_plastic returns, so it must carry the correct
    // grid at registration time. With no design box the solved grid IS the part
    // grid (byte-identical default). Held in a named local: set_variant_stream
    // captures it by reference for the duration of the solve.
    const topopt::VoxelGrid result_grid =
        topopt::minimize_plastic_solved_grid(grid, opts);

    set_variant_stream(opts, result_grid, variant_fn, variant_ctx);  // progressive results

    // The last checkpoint before the solve: if the device log stops here, the
    // stall is INSIDE minimize_plastic (the first FEA solve runs before the first
    // progress tick), not in the app-side setup. Report the exact system size and
    // BC/load counts handed to the solver — an empty external set means the run
    // fell back to self-weight + a min-x clamp (see any_fixture above).
    //
    // When a design box is set, minimize_plastic solves on the EXPANDED grid
    // (`result_grid`), not the part grid — and that expanded grid is the diagnosed
    // trigger (odd dims force the Jacobi-CG fallback over a large soft-void domain).
    // Log both so the device console shows the grid that actually hangs.
    bridge_log(std::string("loadcase: entering minimize_plastic (solver=MultigridCG_Matfree)")
               + " design_box=" + std::to_string(load_case.has_design_box ? 1 : 0)
               + " part " + grid_summary(grid)
               + (load_case.has_design_box ? " | SOLVED-ON expanded " + grid_summary(result_grid)
                                           : std::string(" | SOLVED-ON part grid"))
               + " nodal_loads=" + std::to_string(external.size())
               + " dirichlet_bcs=" + std::to_string(bcs.size()));
    topopt::MinimizePlasticResult mp = topopt::minimize_plastic(
        grid, it->second, material_name, bcs, rules, opts);
    // Report the grid the driver ACTUALLY solved on (mp.solved_grid), not the
    // up-front derivation: they are equal by construction, but sourcing the final
    // metadata straight from the result closes any remaining gap between the grid
    // the fields are indexed to and the grid metadata the app samples them with.
    result = to_optimize_result(mp, mp.solved_grid);
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
