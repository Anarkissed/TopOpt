// TopOptBridge — an interoperability-clean C++ facade over the topopt core
// library (ROADMAP M7.1). The Swift TopOptKit wrapper calls these functions
// through Swift/C++ interop; the app calls the wrapper.
//
// Design rule (why this header is deliberately small): every declaration here
// is parsed by the Swift C++ importer, so it exposes ONLY std::string,
// std::vector and plain-old-data structs — never a core type (VoxelGrid,
// TriangleMesh, StepModel ...), never an OCCT/Eigen type. All of those are
// implementation details of bridge.cpp and stay out of the module the Swift
// side sees (ARCHITECTURE.md §3: OCCT is an implementation detail, not in the
// public surface). Errors are reported through a returned BridgeError value
// rather than by throwing across the language boundary.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace topoptbridge {

// Outcome of a bridge call. `ok == false` means the call failed and the other
// returned data is default/empty; `message` carries the core diagnostic (the
// what() text of the MaterialError / StlError / StepError / std::exception the
// core threw), so the app can surface it in a toast (ROADMAP M7.3).
struct BridgeError {
  bool ok = true;
  std::string message;
};

// ---------------------------------------------------------------------------
// materials.json (ARCHITECTURE §6) — the exact six fields per material.
struct MaterialInfo {
  std::string name;
  double youngs_modulus_mpa = 0.0;
  double yield_strength_mpa = 0.0;
  double density_g_cm3 = 0.0;
  double z_knockdown = 0.0;
  double poisson = 0.0;
  std::string family;  // "fdm" or "resin"
};

// Load and validate a materials.json file (core parse_materials/validate).
// Returns the materials in the core's deterministic (name-sorted) order.
std::vector<MaterialInfo> load_materials(const std::string& path,
                                         BridgeError& err);

// ---------------------------------------------------------------------------
// Imported geometry. Vertices are flattened xyz triples (size == 3 *
// vertex_count); indices are flattened triangle corner indices (size == 3 *
// triangle_count) into the vertex array — the layout a Metal vertex/index
// buffer wants (ROADMAP M7.4). `face_ids` is the per-triangle B-rep face id for
// a STEP import (size == triangle_count), empty for STL (STL has no faces).
struct ImportedMesh {
  std::vector<float> vertices;
  std::vector<int32_t> indices;
  std::vector<int32_t> face_ids;
  int32_t vertex_count = 0;
  int32_t triangle_count = 0;
  int32_t face_count = 0;   // B-rep faces (STEP); 0 for STL
  bool watertight = false;  // check_watertight on the imported mesh
};

// Import an STL (ASCII or binary, auto-detected). Geometry only — does NOT
// require watertightness, but reports it in `watertight` so the app can warn
// (ROADMAP M7.3). On failure returns an empty mesh and sets `err`.
ImportedMesh import_stl(const std::string& path, BridgeError& err);

// Import a STEP file via OCCT, tessellated at `linear_deflection` mm (<= 0 uses
// the core default). Populates `face_ids`/`face_count` for face selection
// (ROADMAP M7.5). On failure returns an empty mesh and sets `err`.
ImportedMesh import_step(const std::string& path, double linear_deflection,
                         BridgeError& err);

// Write an ImportedMesh to an STL file (core write_stl_file; binary encoding).
// This is the M6.1 STL export path exposed to the app; 3MF export (lib3mf) is
// wired in ROADMAP M7.9. On failure sets `err`.
void export_stl(const std::string& path, const ImportedMesh& mesh,
                BridgeError& err);

// ---------------------------------------------------------------------------
// Voxelization (ROADMAP M1.5). Imports the mesh at `path` (STL or STEP by
// extension), voxelizes at `resolution` voxels along the longest axis, and
// returns the grid dimensions and solid-voxel count.
struct VoxelSummary {
  int32_t nx = 0;
  int32_t ny = 0;
  int32_t nz = 0;
  double spacing = 0.0;
  int64_t solid_voxels = 0;
};
VoxelSummary voxelize_mesh(const std::string& path, int resolution,
                           BridgeError& err);

// Face tagging (ROADMAP M1.6). Imports the STEP file, voxelizes at
// `resolution`, and tags the voxels against B-rep face `face_id` as Fixture (if
// `as_fixture`) or Load. Returns the number of voxels tagged. Exposes the
// tag_step_face plumbing the app's selection groups drive (ROADMAP M7.5).
int64_t tag_step_face(const std::string& step_path, int face_id,
                      bool as_fixture, int resolution, BridgeError& err);

// Passive-region masking (ROADMAP M3.7 / M7.6-core D7). Imports the STEP file,
// voxelizes at `resolution`, and sets the design mask of the voxels within
// `depth_voxels` layers of B-rep face `face_id` to `mask_value`, returning the
// number of voxels masked. `mask_value` matches topopt::MaskValue: 0 = Active,
// 1 = FrozenSolid (keep-in), 2 = FrozenVoid (keep-out). This is how the app
// freezes load/anchor faces as an N-voxel passive shell so the optimizer cannot
// remove the surfaces the boundary conditions sit on (MOD-F1 D7). Mirrors
// tag_step_face (stateless: re-imports + re-voxelizes per call). On failure
// (bad mask_value/depth/face_id, or STEP unavailable) returns 0 and sets `err`.
int64_t mask_step_face(const std::string& step_path, int face_id,
                       int mask_value, int depth_voxels, int resolution,
                       BridgeError& err);

// ---------------------------------------------------------------------------
// minimize_plastic (ROADMAP M5.3) with M7.0a progress + cancellation.
//
// Progress callback: invoked once per completed OC iteration of every rung with
// (ctx, rung_index [0-based], rung_count, iteration [1-based within the rung]),
// exactly the M7.0a MinimizePlasticOptions::progress payload. `ctx` is the
// opaque pointer passed in (the Swift side threads its closure through it). May
// be null (no progress). It must not throw.
using ProgressFn = void (*)(void* ctx, uint64_t rung_index,
                            uint64_t rung_count, int iteration);

// Cancellation: `cancel_flag` (if non-null) is read once per OC iteration; when
// it becomes true the run stops cleanly and `cancelled` is set on the result
// (M7.0a semantics — the terminal rung is rejected, no partial output). The
// pointee must outlive the call. Reading is on the optimizing thread; flip the
// flag from the progress callback (same thread) to cancel mid-run.
struct OptimizeVariant {
  double requested_volume_fraction = 0.0;
  double achieved_volume_fraction = 0.0;
  double mass_grams = 0.0;              // M7.0b
  int32_t support_volume_voxels = 0;   // M7.0b
  int32_t mesh_triangle_count = 0;     // M7.0b variant mesh
  double worst_case_margin = 0.0;
  bool accepted = false;
  bool v3_passes = false;
};

struct OptimizeResult {
  std::vector<OptimizeVariant> variants;  // every evaluated rung, ladder order
  bool stopped_on_margin = false;
  bool cancelled = false;
  int32_t accepted_count = 0;  // report.variants.size()
};

// Run minimize_plastic on the part at `stl_path`: import (STL), voxelize at
// `resolution`, tag the minimum-x boundary slab as the Fixture/mounting face
// and clamp its nodes, then walk the self-weight volume-fraction ladder using
// `material_name` from `materials_path` and the settings table at `rules_path`.
// This is the M7.7 run seam; the app supplies the tagged grid in later tasks,
// but M7.1 proves the driver + progress path end-to-end. On failure returns an
// empty result and sets `err`.
OptimizeResult run_minimize_plastic(const std::string& stl_path,
                                    const std::string& material_name,
                                    const std::string& materials_path,
                                    const std::string& rules_path,
                                    int resolution, ProgressFn progress,
                                    void* ctx, const bool* cancel_flag,
                                    BridgeError& err);

// ---------------------------------------------------------------------------
// Bridge smoke summary — the M7.1 deliverable "material count + imported-mesh
// triangle count". Loads the materials file and imports the mesh, returning
// both counts in one call so the app's smoke screen and the headless test share
// exactly one code path.
struct SmokeResult {
  int32_t material_count = 0;
  int32_t triangle_count = 0;
  bool watertight = false;
  bool ok = false;
  std::string message;
};
SmokeResult bridge_smoke(const std::string& materials_path,
                         const std::string& mesh_path);

// The core library version string (topopt::version()), a trivial no-argument
// call used as the most basic bridge liveness check.
std::string core_version();

}  // namespace topoptbridge
