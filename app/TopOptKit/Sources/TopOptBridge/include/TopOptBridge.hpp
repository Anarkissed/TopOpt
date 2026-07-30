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

  // Handoff (keep-clear v2) — per-B-rep-FACE surface geometry, ADDITIVE: the
  // EXACT numbers topopt::StepFaceInfo captured, so the app can render a
  // clearance volume from the SAME axis/radius/normal the core rasterizer
  // freezes (never an app-side tessellation fit that draws a different object).
  // Flat arrays INDEXED BY FACE ID (parallel to face_ids' values), size
  // face_count for the vec1 arrays and 3*face_count for the vec3 arrays (xyz
  // triples). Empty for STL (no B-rep). The 0-sentinel wire protocol to the core
  // is UNCHANGED — this only lets the app DISPLAY real numbers and draw volumes.
  //   face_kinds[f]        0 = Plane, 1 = Cylinder, 2 = Other (topopt::StepSurfaceKind)
  //   face_cyl_radius[f]   cylinder radius (mm); 0 unless kind == Cylinder
  //   face_axis_point[3f..] point on the cylinder axis (mm); (0,0,0) unless Cylinder
  //   face_axis_dir[3f..]   UNIT cylinder axis direction; (0,0,0) unless Cylinder
  //   face_plane_normal[3f..] OUTWARD unit plane normal; (0,0,0) unless Plane
  //   face_plane_origin[3f..] point on the plane (mm); (0,0,0) unless Plane
  std::vector<int32_t> face_kinds;
  std::vector<double> face_cyl_radius;
  std::vector<double> face_axis_point;
  std::vector<double> face_axis_dir;
  std::vector<double> face_plane_normal;
  std::vector<double> face_plane_origin;

  // Handoff 134 — true when `face_ids`/`faces` were MANUFACTURED by the core's
  // dihedral segmenter from a mesh (STL/3MF) rather than read from a B-rep.
  // For honest UI copy only: nothing in the app branches its BEHAVIOUR on this,
  // because the whole point is that a pseudo-face and a B-rep face are the same
  // contract downstream.
  bool pseudo_faces = false;
};

// Import an STL (ASCII or binary, auto-detected). Geometry only — does NOT
// require watertightness, but reports it in `watertight` so the app can warn
// (ROADMAP M7.3). On failure returns an empty mesh and sets `err`.
//
// NOTE (handoff 134): this is the RAW reader and produces NO face ids, so a
// mesh imported through it cannot be tapped. `import_part` is what the app
// uses; this remains for callers that want geometry without inspection or
// repair.
ImportedMesh import_stl(const std::string& path, BridgeError& err);

// ---------------------------------------------------------------------------
// Part import (handoff 134) — the ONE entry point the app uses for every
// supported format.
//
//   .step/.stp -> OCCT B-rep faces (unchanged)
//   .stl/.3mf  -> mesh + dihedral segmentation -> PSEUDO-faces
//
// Both fill `face_ids`, `face_count` and the per-face geometry arrays, so tap
// selection, keep-clear, protect, the design box and the optimizer all behave
// identically regardless of which file the user picked.

// Why a mesh was refused. Mirrors topopt::PartDefect one-for-one; the app turns
// these into the plain-language refusal sheet.
//   0 EmptyMesh  1 NonManifoldEdges  2 OpenBoundary  3 NonOrientable  4 ZeroThickness
struct PartDiagnostics {
  bool checked = false;      // false for STEP (the B-rep path is not inspected)
  bool acceptable = false;
  std::vector<int32_t> defects;  // empty iff acceptable
  std::vector<std::string> defect_text;  // core's one-line description, parallel

  int32_t boundary_edges = 0;
  int32_t non_manifold_edges = 0;
  int32_t degenerate_triangles = 0;
  // Repairs the importer applied. Reported so the sheet can say what changed —
  // ALL of them, including the Phase-2 repairs (duplicate-facet removal and
  // small-hole capping), which change the user's geometry just as much as a weld
  // and must not be dropped on the way to the app.
  int32_t welded_vertices = 0;
  int32_t flipped_triangles = 0;
  int32_t removed_duplicate_triangles = 0;  // redundant coincident facets dropped
  int32_t filled_holes = 0;                 // small boundary loops capped
  int32_t filled_hole_triangles = 0;        // triangles added by hole caps

  // Measured in FILE units — STL carries no unit, so the app uses the bounding
  // box to sanity-check the user's mm/inch answer.
  double volume = 0.0;
  double bbox_min[3] = {0.0, 0.0, 0.0};
  double bbox_max[3] = {0.0, 0.0, 0.0};
};

// Import any supported part. `linear_deflection` applies to STEP only (<= 0
// uses the core default). On failure returns an empty mesh and sets `err` with
// the core diagnostic; call `inspect_part` for the structured reason.
ImportedMesh import_part(const std::string& path, double linear_deflection,
                         BridgeError& err);

// Inspect a part WITHOUT throwing on a quality refusal: this is what builds the
// refusal sheet. A file that cannot be read at all still sets `err`.
PartDiagnostics inspect_part(const std::string& path, BridgeError& err);

// The paint-mode / segmentation-tuning sidecar (handoff 2026-07-24). The app
// fills this and calls `write_face_overrides` to persist it next to its
// working-copy STL; every later import (the display import, live tagging, the
// run) then reproduces the SAME faces. `paint_indices` is the flattened triangle
// indices of the painted pseudo-faces, `paint_sizes` the per-face counts (face i
// takes the next `paint_sizes[i]` entries). `dihedral_deg <= 0` and
// `cone_deg < 0` mean "leave the core default".
struct FaceOverridesInput {
  double dihedral_deg = 0.0;
  double cone_deg = -1.0;
  std::vector<int32_t> paint_indices;
  std::vector<int32_t> paint_sizes;
};

// Write (or, with an empty/default input, DELETE) the face-overrides sidecar for
// `model_path`. Deleting on empty keeps a cleared paint state from leaving a
// stale sidecar that a re-import would resurrect. On failure sets `err`.
void write_face_overrides(const std::string& model_path,
                          const FaceOverridesInput& input, BridgeError& err);

// Apply a unit choice by writing a rescaled binary-STL working copy. STL has no
// unit, so the app asks; the answer is baked into the app-owned copy ONCE and
// every later stateless call re-reads a file already in millimetres. Rejects a
// STEP input (STEP carries its own unit). On failure sets `err`.
void rescale_part(const std::string& in_path, const std::string& out_path,
                  double scale, BridgeError& err);

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
  // The printed/count basis #{ρ>0.5}/part_solid the app's savings% is built from
  // (savings = 1 - achieved_volume_fraction). Handoff 104 split the core report into
  // two bases; `achieved_volume_fraction` here carries the PRINTED/count basis (its
  // historical meaning — it feeds savings, which must stay the count basis so it can
  // never disagree with mass), and `printed_fraction` names that basis explicitly.
  double achieved_volume_fraction = 0.0;
  // Handoff 104 (additive): the printed/count basis by its canonical name. Equal to
  // achieved_volume_fraction; carried so consumers can reference it distinctly from
  // the core's optimizer-achieved (continuous) volume_fraction. #{ρ>0.5}/part_solid.
  double printed_fraction = 0.0;
  double mass_grams = 0.0;              // M7.0b
  int32_t support_volume_voxels = 0;   // M7.0b
  int32_t mesh_triangle_count = 0;     // M7.0b variant mesh
  double worst_case_margin = 0.0;
  bool accepted = false;
  bool v3_passes = false;
  // M5.2b min-feature: REPORT-ONLY (DECISIONS 2026-07-06). Carried so the app can
  // surface the same advisory warning the JobReport does; it never gates
  // acceptance (`accepted` is strength-margin only).
  int32_t min_feature_violations = 0;
  std::string min_feature_warning;  // empty when violations == 0
  // M7.8 results screen. The chosen build orientation (VariantReport.orientation,
  // the M4.4 winning unit build direction) for the orientation sheet; the peak
  // stresses (max von Mises / max interlayer tension, MPa) for the stress legend's
  // shared scale and the "Layer shear" readout; and the two margin components
  // (StressMargin.in_plane / .interlayer — worst_case is `worst_case_margin`).
  double orientation_x = 0.0;
  double orientation_y = 0.0;
  double orientation_z = 0.0;
  double max_stress_mpa = 0.0;
  double max_interlayer_tension_mpa = 0.0;
  double in_plane_margin = 0.0;
  double interlayer_margin = 0.0;
  // M7.8 variant-mesh display + stress overlay. `mesh_vertices` is the extracted
  // + cleaned variant isosurface (v.mesh(), flattened xyz, size 3*vertex_count);
  // `mesh_indices` its triangle corners. `von_mises_field` is the M7.0b per-voxel
  // von Mises stress over the printed material, grid-indexed (size
  // grid.voxel_count(), see OptimizeResult grid_* / spacing), MPa — sampled at a
  // mesh vertex to color it. All empty for a cancelled rung.
  std::vector<float> mesh_vertices;
  std::vector<int32_t> mesh_indices;
  std::vector<float> von_mises_field;
  // Per-voxel Cauchy stress tensor (v.stress_tensor_field), grid-indexed and
  // flattened: voxel idx occupies entries [6*idx .. 6*idx+5] in Voigt order
  // [xx, yy, zz, xy, yz, zx] with TRUE shear stresses (tau, not doubled), MPa;
  // size 6*grid.voxel_count() (see OptimizeResult grid_*). The tensor the trusted
  // von_mises_field is derived from, exposed per voxel for load->anchor flux
  // streamlines. Zero on non-printed voxels (companion to von_mises_field);
  // empty for a cancelled rung.
  std::vector<float> stress_tensor_field;
  // M7.disp — the per-node displacement field (v.displacement_field), DOF-ordered
  // and grid-node-indexed: entries [3n, 3n+1, 3n+2] are (ux, uy, uz) of node n in
  // model units (mm). Node n is corner (a,b,c) of the run's grid at global index
  // (c*(grid_ny+1) + b)*(grid_nx+1) + a; size 3*(grid_nx+1)*(grid_ny+1)*(grid_nz+1).
  // Zero on nodes attached only to non-printed voxels (companion to
  // von_mises_field). M7.viz.3's flex animation moves mesh vertices by this;
  // empty for a cancelled rung.
  std::vector<float> displacement_field;
  // Optimization-history keyframes for playback (M7): the isosurface at snapshots
  // from ~solid to optimized. Flattened so only scalar vectors cross the importer:
  // for keyframe f, its vertices are the `keyframe_vertex_counts[f]` xyz triples of
  // `keyframe_vertices` after the earlier frames' vertices, and its triangle-corner
  // indices (LOCAL to that frame) are the `keyframe_index_counts[f]` entries of
  // `keyframe_indices` after the earlier frames'. Empty when playback is disabled.
  std::vector<float> keyframe_vertices;
  std::vector<int32_t> keyframe_vertex_counts;
  std::vector<int32_t> keyframe_indices;
  std::vector<int32_t> keyframe_index_counts;
};

struct OptimizeResult {
  std::vector<OptimizeVariant> variants;  // every evaluated rung, ladder order
  bool stopped_on_margin = false;
  bool cancelled = false;
  int32_t accepted_count = 0;  // report.variants.size()
  // M7.8: the run's voxel volume (grid.voxel_volume(), mm^3 == spacing^3), so the
  // app can turn a variant's support_volume_voxels count into a cm^3 estimate
  // (voxels * voxel_volume_mm3 / 1000). One grid per run, so it lives here.
  double voxel_volume_mm3 = 0.0;
  // M7.8: the run's voxel grid, so the app can sample a variant's grid-indexed
  // von_mises_field at a mesh vertex position `p`: the voxel is
  // i = floor((p - origin)/spacing) clamped to [0, n), field index
  // (k*grid_ny + j)*grid_nx + i (VoxelGrid::index). One grid per run.
  int32_t grid_nx = 0;
  int32_t grid_ny = 0;
  int32_t grid_nz = 0;
  double grid_origin_x = 0.0;
  double grid_origin_y = 0.0;
  double grid_origin_z = 0.0;
  double spacing = 0.0;  // == cbrt(voxel_volume_mm3); carried explicitly for sampling

  // Handoff 100 — what each declared clearance actually did, so the results
  // screen can state HONESTLY that clearance was applied and to which faces, and
  // flag a region that fell entirely outside the solved grid. Parallel arrays,
  // one entry per applied clearance (in BridgeLoadCase order):
  //   clearance_face_ids[c]        the B-rep face the region came from
  //   clearance_kinds[c]           0 = bolt, 1 = face
  //   clearance_voxels_frozen[c]   voxels the region forbade (set FrozenVoid)
  //   clearance_in_grid[c]         1 iff the region reached the solved grid (0 =
  //                                a silent no-op the UI must SURFACE)
  // Empty when no clearance was declared.
  std::vector<int32_t> clearance_face_ids;
  std::vector<int32_t> clearance_kinds;
  std::vector<int32_t> clearance_voxels_frozen;
  std::vector<uint8_t> clearance_in_grid;

  // Handoff 124 — what each declared Face protection actually froze, so the results
  // screen states HONESTLY that preservation was applied and to which faces (the
  // applied-clearances card pattern, opposite polarity). One entry per protection
  // (in BridgeLoadCase order):
  //   protection_face_ids[p]       the B-rep face whose skin was preserved
  //   protection_voxels_frozen[p]  part voxels pinned FrozenSolid behind it
  //   protection_depth_voxels[p]   the depth (layers) used on the run's grid
  //   protection_thinner[p]        1 iff the face's own solid was thinner than the
  //                                depth (froze what exists — no silent over-claim)
  // Empty when no protection was declared.
  std::vector<int32_t> protection_face_ids;
  std::vector<int32_t> protection_voxels_frozen;
  std::vector<int32_t> protection_depth_voxels;
  std::vector<uint8_t> protection_thinner;
};

// Progressive results: invoked once per ACCEPTED variant as it completes (before
// the next lighter rung is optimized), so the app can show the first optimized
// variant while the rest still run. `partial` is a ONE-variant OptimizeResult
// carrying that variant + the run's grid metadata; it (and its buffers) are valid
// only for the duration of the call — copy what you need. Runs on the optimizing
// thread. `ctx` is the opaque pointer passed in. May be null (no streaming).
using VariantFn = void (*)(void* ctx, const OptimizeResult* partial);

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
                                    VariantFn variant_fn, void* variant_ctx,
                                    BridgeError& err);

// ---------------------------------------------------------------------------
// analyze_selfweight — the re-certification "receipt" (handoff
// 2026-07-26-constrained-smooth). ONE FEA analysis solve on a FIXED design, no
// optimization: the app hands over an EDITED / smoothed mesh and gets back the
// NEW stress / mass / margin / gate verdict for that geometry. The pre-edit
// numbers never come back — the result IS the re-analysed geometry's, tagged as
// such by the caller. This is the seam a smoothing UI calls after Taubin; it does
// NOT yet have a Swift caller (the UI is deferred), but the seam is here so that
// when it lands there is one place, sharing analyze_fixed_design with the CLI and
// the optimizer's own per-rung certification.

// The re-certification result. Scalars the results screen shows, plus the run's
// grid metadata and the re-analysed von Mises / displacement fields (float, same
// layout as OptimizeVariant) so the "smoothed - re-analyzed" stress/flex overlay
// draws the NEW field, never the pre-edit one.
struct AnalyzeResult {
  bool accepted = false;
  // The certification solve did NOT converge (handoff 2026-07-27-nonconvergence-
  // rejection): the re-voxelized field was too ill-conditioned for the production
  // multigrid-CG at the tight cert tolerance. When true EVERY number below is
  // meaningless (the solve never finished) and `accepted` is forced false — this is
  // NOT a genuine "weaker, rejected" verdict, it is "could not certify". The UI must
  // distinguish the two: a non-convergent re-cert shows "couldn't re-certify at this
  // strength — try lower", never a fabricated margin. The re-cert reports this rather
  // than emitting a false receipt (the honesty rule at the solver boundary).
  bool non_convergent = false;
  double margin_worst_case = 0.0;      // the SOLID margin (displayed value)
  double margin_effective = 0.0;       // infill-adjusted margin the gate compares
  double margin_required = 0.0;
  double max_stress_mpa = 0.0;
  double max_interlayer_tension_mpa = 0.0;
  double voxel_mass_grams = 0.0;       // re-analysed voxel-count mass
  double mesh_mass_grams = 0.0;        // analysed mesh's surface-enclosed mass (0 if solid)
  int32_t support_volume_voxels = 0;
  int32_t min_feature_violations = 0;  // the melt detector on the re-voxelized geometry
  bool analyzed_mesh = false;          // true iff an edited mesh was re-voxelized (vs solid)
  // Re-analysis runs on the mesh's VOXELIZATION at `resolution`; the analysed and
  // printed geometry differ by up to ~half a voxel (the quantization footnote the
  // provenance tag must disclose).
  int32_t grid_nx = 0, grid_ny = 0, grid_nz = 0;
  double grid_origin_x = 0.0, grid_origin_y = 0.0, grid_origin_z = 0.0;
  double spacing = 0.0;
  double voxel_volume_mm3 = 0.0;
  std::vector<float> von_mises_field;    // grid-indexed, MPa (0 off the printed set)
  std::vector<float> displacement_field; // DOF-ordered (3*node), mm

  // Constrained-smoothing receipt (handoff 2026-07-26-constrained-smooth-ui).
  // Populated only by smooth_and_recertify_selfweight; on the plain analyze path
  // `smoothed` stays false and these are zero. When true, EVERY scalar above
  // describes the SMOOTHED geometry — the pre-smoothing numbers never come back
  // (the honesty rule). The results screen renders the "smoothed · re-analyzed"
  // provenance tag from these, and the quantization footnote from `spacing`.
  bool smoothed = false;
  double smooth_strength = 0.0;          // the strength knob used (0,1]
  int32_t smooth_pairs_requested = 0;
  int32_t smooth_pairs_applied = 0;
  int64_t frozen_vertices = 0;           // vertices held bit-identical (bores/pads)
  int64_t total_vertices = 0;
  double volume_before_mm3 = 0.0;
  double volume_after_mm3 = 0.0;
  double volume_drift_fraction = 0.0;    // |Δ vol| / vol
  double volume_drift_bound = 0.0;       // Taubin's stated transfer-function bound
  int32_t min_feature_baseline = -1;
  bool min_feature_limited = false;      // the constraint stopped smoothing early
  std::string smoothed_mesh_path;        // the exported smoothed STL (task item 5)
};

// Freeze regions for the constrained smoother, supplied by the app as the SAME
// manual-primitive geometry PR 190 already threads through the job schema
// (ManualClearanceGeometry: keep-clear bores, protected/anchor faces). Flattened
// to scalar vectors so the Swift C++ importer builds it member-wise (no nested
// struct vectors), exactly like BridgeLoadCase. Region g is a Bolt when
// kind[g]==0 (a swept cylinder: axis_point + axis_dir, radius, half_length) and a
// Face when kind[g]==1 (a bounded slab: origin + normal, half_u × half_w). Every
// vector is indexed by g; the point/dir triples are 3*g. A vertex within the
// smoother's tolerance of ANY region is FROZEN (bit-identical). Empty => only the
// mount slab is frozen.
struct BridgeFreezeRegions {
  std::vector<int32_t> kind;         // 0 = Bolt (bore), 1 = Face (pad/protect)
  std::vector<double> axis_point;    // 3*g (Bolt)
  std::vector<double> axis_dir;      // 3*g (Bolt)
  std::vector<double> radius_mm;     // g   (Bolt)
  std::vector<double> half_length_mm;// g   (Bolt)
  std::vector<double> origin;        // 3*g (Face)
  std::vector<double> normal;        // 3*g (Face)
  std::vector<double> half_u_mm;     // g   (Face)
  std::vector<double> half_w_mm;     // g   (Face)
};

// Re-certify a FIXED design under self-weight. Imports `model_path` (the geometry
// the fixture/mount is defined on: the minimum-x boundary slab is clamped, exactly
// as run_minimize_plastic), builds the self-weight load case, then runs ONE
// analyze_fixed_design solve and returns the NEW numbers. The design analysed is:
//   * `analyze_mesh_path` empty — the model as a SOLID part; else
//   * `analyze_mesh_path` set   — that mesh (e.g. the smoothed variant) re-voxelized
//     onto the model's grid via voxelize_onto_grid, so the model's clamp still
//     applies. NEVER optimizes. On failure returns an empty result and sets `err`.
AnalyzeResult analyze_selfweight(const std::string& model_path,
                                 const std::string& analyze_mesh_path,
                                 const std::string& material_name,
                                 const std::string& materials_path,
                                 const std::string& rules_path, int resolution,
                                 double margin_stop, BridgeError& err);

// Constrained-smooth `input_mesh_path` then re-certify the RESULT (handoff
// 2026-07-26-constrained-smooth-ui) — the seam a smoothing UI calls after the
// user picks a strength. Taubin-smooths the mesh under `freeze` (plus the mount
// slab, always frozen) with the min-feature hard constraint, writes the smoothed
// mesh to `smoothed_out_path`, then runs analyze_selfweight on THAT — so the
// returned numbers describe the smoothed geometry and share analyze_fixed_design
// with the CLI and the optimizer's own certification. `strength` ∈ (0,1];
// `enforce_min_feature` gates the melt constraint. On failure returns an empty
// result and sets `err`. (Like analyze_selfweight, this has no Swift caller yet —
// the UI is deferred — but the seam and its provenance fields are here so the tag
// has one source of truth when it lands.)
AnalyzeResult smooth_and_recertify_selfweight(
    const std::string& model_path, const std::string& input_mesh_path,
    const std::string& smoothed_out_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, double margin_stop, double strength, bool enforce_min_feature,
    const BridgeFreezeRegions& freeze, BridgeError& err);

// ---------------------------------------------------------------------------
// Optimize under the user's DECLARED load case (ARCHITECTURE §1 mode (a)),
// instead of self-weight. This is the path the app's M7.6 anchors/loads drive so
// the reported margins/stresses reflect the forces the user actually set — not
// the part's own weight.

// The user's declared load case. Laid out with only scalar vectors so the Swift
// C++ importer builds it member-wise (push_back) — no nested struct vectors.
//   * `anchor_face_ids`: the anchor B-rep faces (tagged Fixture + clamped).
//   * Load groups are flattened: group g's face ids are the `load_group_sizes[g]`
//     entries of `load_face_ids` starting at the sum of earlier sizes, and its
//     total force (newtons) is (load_forces[3g], load_forces[3g+1],
//     load_forces[3g+2]). Each group's force is spread as a consistent,
//     distributed traction over its exposed faces (topopt::traction_loads) —
//     never a lumped point force.
//   * `minimize_plastic`: on → the reduction ladder; off → one conservative variant.
//   * `build_dir_*`: the print/build direction (the interlayer-margin orientation).
struct BridgeLoadCase {
  std::vector<int32_t> anchor_face_ids;
  std::vector<int32_t> load_face_ids;
  std::vector<int32_t> load_group_sizes;
  std::vector<double> load_forces;  // 3 per group (fx, fy, fz)
  bool minimize_plastic = true;
  double build_dir_x = 0.0;
  double build_dir_y = 0.0;
  double build_dir_z = 1.0;
  // M7.params — the user's infill-density override (0–100 %), or < 0 when the user
  // set no override (use the M5.1 recommendation). ADDITIVE + DEFAULTED so this is
  // source-compatible: `run_minimize_plastic_loadcase`'s signature is unchanged
  // (BridgeLoadCase is passed by const ref) and existing callers keep the default.
  // The app captures it from the print-parameters sheet; M7.infill-margin (the
  // ladder knockdown) is what CONSUMES it in the core. That consumption needs a
  // field on the core's MinimizePlasticOptions, which is OUT OF SCOPE for M7.params
  // (a /core/ change M7.infill-margin owns) — so today this value reaches the bridge
  // and stops there. See the M7.params handoff.
  int infill_percent = -1;

  // Width-aware knockdown slicer metadata (handoff 2026-07-27-wall-loops-plumbing +
  // line-width-plumbing). The user's perimeter wall-loop count and the INNER / OUTER
  // wall LINE WIDTHS from the Print Parameters sheet (0 loops = none). The shell+core
  // composite accept gate sizes the solid wall ring around each member as
  // t = outer + (wall_loops - 1)·inner; without these the bridge left the geometry at
  // the POD defaults, so the LAN worker's run_info showed the modelling assumption
  // rather than the user's real settings the moment the width-aware gate is armed.
  // ADDITIVE + DEFAULTED, so a caller that omits them is byte-identical to before AND
  // (because the shipped gate is OFF) to a run that sets them.
  //
  // The line widths are BEAD widths (a slicer setting, ~1.0–1.2× nozzle), NOT the
  // nozzle diameter. `wall_line_width_mm` is the inner loops' width and
  // `wall_line_width_outer_mm` the single outer loop's; a value < 0 means "unset" —
  // inner falls back to the core default (0.45 mm), outer mirrors inner — so both paths
  // collapse to the old t = loops·inner. The CLI job schema's
  // `loads.{wall_loops, wall_line_width_mm, wall_line_width_outer_mm}` are the LAN twins
  // of these fields (asserted equal in JobJSONEquivalenceTests).
  int wall_loops = 0;
  double wall_line_width_mm = -1.0;          // inner; < 0 = core default (0.45 mm)
  double wall_line_width_outer_mm = -1.0;    // outer; < 0 = mirror inner

  // M7.dom-app — the design-domain expansion (the "ADD MATERIAL" feature). When
  // `has_design_box` is true the run voxelizes the part onto a LARGER grid spanning
  // the union of the part and this design box (model-space mm, axis-aligned), and
  // the optimizer may GROW material into the box beyond the import (dom-core's
  // expand_design_domain: imported part → FrozenSolid, kept forever; design box →
  // Active growable region; keep-out boxes → FrozenVoid, left empty). The box may
  // extend BEYOND the part's bounds — that empty space is the grow room.
  //
  // ADDITIVE + DEFAULTED: `has_design_box` defaults false, so an unset box means the
  // fields are ignored and the run is BYTE-IDENTICAL to today (the default no-box
  // path — see MinimizePlasticOptions::design_box). The whole feature is opt-in.
  //
  // Model space matches the voxelizer/mesh frame (mm), the same coordinates the
  // anchors/loads use, so no transform is needed. `min` must be <= `max`
  // componentwise (the app enforces this before the call).
  bool has_design_box = false;
  double design_box_min_x = 0.0, design_box_min_y = 0.0, design_box_min_z = 0.0;
  double design_box_max_x = 0.0, design_box_max_y = 0.0, design_box_max_z = 0.0;
  // Keep-out boxes (model space, mm), flattened as one (x,y,z) triple per box:
  // keep-out box b spans (keep_out_min[3b], keep_out_min[3b+1], keep_out_min[3b+2])
  // to (keep_out_max[3b], …). Only consulted when `has_design_box` is true. A
  // keep-out never carves into the imported part (part voxels stay FrozenSolid).
  std::vector<double> keep_out_min;
  std::vector<double> keep_out_max;

  // Handoff 100 — "Keep clear" clearance regions, flattened POD (one entry per
  // region, so the Swift C++ importer builds it member-wise). The app derives a
  // clearance's exact geometry NOWHERE — it ships only the face id + kind + the
  // editable mm distances, and the bridge/core re-read the bore axis/radius or
  // plane normal from the STEP (design 095 STEP 0c). Region c is:
  //   clearance_face_ids[c]     the B-rep face the region is built from
  //   clearance_kinds[c]        0 = bolt (swept cylinder), 1 = face (bounded slab)
  //   clearance_margin_mm[c]    bolt: keep-out radius = bore_radius + this
  //   clearance_axial_mm[c]     bolt: sweep this far past the bore each side
  //   clearance_slab_mm[c]      face: extrude the outline outward this far
  // Empty (the default) → no clearance → byte-identical to today. Independent of
  // has_design_box: a bolt clearance keeps a hole open on any run.
  std::vector<int32_t> clearance_face_ids;
  std::vector<int32_t> clearance_kinds;
  std::vector<double> clearance_margin_mm;
  std::vector<double> clearance_axial_mm;
  std::vector<double> clearance_slab_mm;

  // Handoff group-editing — MANUAL (user-placed) primitive geometry. The finder
  // OVER-finds and MISSES; the user hand-places a keep-out primitive that has NO
  // B-rep face, so its geometry can NOT be re-read from the STEP and must ship
  // here. `clearance_manual[c] == 1` means region c is manual: for a bolt the
  // axis_point/axis_dir (stride-3 into the *_xyz arrays), radius_mm and half_len_mm
  // are read; for a face the origin/normal (stride-3), half_u_mm and half_w_mm.
  // For an AUTO region (`clearance_manual[c] == 0`, or the arrays empty) these are
  // ignored and the face-id path runs exactly as before. All-empty / all-zero =>
  // byte-identical to today (BAR B4). Same model/voxel frame + mm as the geometry
  // the core re-reads from the STEP.
  std::vector<uint8_t> clearance_manual;         // N  (1 = manual, 0 = auto)
  std::vector<double> clearance_axis_point_xyz;  // 3N (bolt)
  std::vector<double> clearance_axis_dir_xyz;    // 3N (bolt)
  std::vector<double> clearance_radius_mm;       // N  (bolt: bore radius)
  std::vector<double> clearance_half_len_mm;     // N  (bolt: half axial extent)
  std::vector<double> clearance_origin_xyz;      // 3N (face)
  std::vector<double> clearance_normal_xyz;      // 3N (face)
  std::vector<double> clearance_half_u_mm;       // N  (face)
  std::vector<double> clearance_half_w_mm;       // N  (face)

  // Handoff 124 — Face protections (preserve-skin), flattened POD. Each id is a
  // B-rep face whose OWN material the optimizer may not touch: the core freezes the
  // part-solid skin behind it FrozenSolid (footprint-only, never frees void — the
  // opposite polarity of a keep-clear). ONE global depth (mm) governs all of them;
  // `face_protection_depth_mm <= 0` means "use the core default". Empty (the
  // default) → no protection → byte-identical to today. Independent of
  // has_design_box: a protection preserves a face's skin on any run.
  std::vector<int32_t> face_protection_face_ids;
  double face_protection_depth_mm = -1.0;  // <= 0 => core default
};

// Voxelize the STEP part once, tag the anchor faces Fixture (clamped) and each
// load group's faces Load, assemble the load groups' tractions as the design load
// (ARCHITECTURE §1 mode (a)), and walk the ladder. `minimize_plastic` on → the
// reduction ladder {0.7,0.5,0.3} (save material while staying strong under the
// forces); off → a single conservative variant (mostly-solid, just strong enough
// — "handle the forces, minimal removal"). Degenerate fallbacks that keep a run
// well-posed: with NO load groups the design load falls back to self-weight; with
// NO anchor faces the minimum-x boundary is auto-clamped (mirroring
// run_minimize_plastic). `build_dir_*` (0,0,0) defaults to +Z. Needs OCCT (STEP
// face selection); on a platform without it, sets `err`.
OptimizeResult run_minimize_plastic_loadcase(
    const std::string& step_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, const BridgeLoadCase& load_case, ProgressFn progress,
    void* ctx, const bool* cancel_flag, VariantFn variant_fn, void* variant_ctx,
    BridgeError& err);

// Re-certify a FIXED design under the user's DECLARED LOAD CASE (anchors + tractions),
// the loadcase twin of analyze_selfweight (handoff 2026-07-28-constrained-smooth-ui).
// Builds the grid / BCs / traction through the SAME build_production_loadcase the
// optimizer and the CLI use, so the re-certification runs under the identical load the
// run did. A declared external load is what lets the receipt LOWER a margin when
// smoothing removes load-bearing material (bar S3) — self-weight can only ever raise
// it. `analyze_mesh_path` empty => the model solid; set => that mesh re-voxelized. On
// failure returns an empty result and sets `err`; a certification that cannot converge
// returns `non_convergent = true` with `accepted = false` (never a false receipt).
AnalyzeResult analyze_loadcase(const std::string& model_path,
                               const std::string& analyze_mesh_path,
                               const std::string& material_name,
                               const std::string& materials_path,
                               const std::string& rules_path, int resolution,
                               const BridgeLoadCase& load_case, BridgeError& err);

// Constrained-smooth `input_mesh_path` then re-certify the RESULT under the DECLARED
// LOAD CASE — the seam the smoothing UI calls for a load-bearing part (handoff
// 2026-07-28-constrained-smooth-ui). Taubin-smooths under `freeze` PLUS the anchor and
// load faces of `load_case` (both structural — kept bit-identical so the clamp and the
// traction stay attached) with the min-feature hard constraint, writes the smoothed
// mesh to `smoothed_out_path`, then runs analyze_loadcase on THAT — so the returned
// numbers describe the smoothed geometry and can drop below the gate. `strength` ∈
// (0,1]; `enforce_min_feature` gates the melt constraint. On failure returns an empty
// result and sets `err`.
AnalyzeResult smooth_and_recertify_loadcase(
    const std::string& model_path, const std::string& input_mesh_path,
    const std::string& smoothed_out_path, const std::string& material_name,
    const std::string& materials_path, const std::string& rules_path,
    int resolution, double strength, bool enforce_min_feature,
    const BridgeLoadCase& load_case, const BridgeFreezeRegions& freeze,
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

// ---------------------------------------------------------------------------
// Lattice certification limits (lattice mode UI, handoff 2026-07-29-lattice-mode-
// ui). The app's lattice controls MUST be bounded by what the core actually
// certifies, read at RUNTIME — never a number hardcoded in the app — so the UI
// widens automatically the moment core's measurement widens. These accessors
// FORWARD core's own values (topopt::lattice_rho_min/max, lattice_topology_name);
// they add no logic and touch neither the grading law nor the generator.
struct LatticeLimits {
  // The certifiable relative-density band for the queried topology, straight from
  // topopt::lattice_rho_min / lattice_rho_max. Meaningful only when `certifiable`.
  double rho_min = 0.0;
  double rho_max = 0.0;
  // True iff the core certification library carries a homogenized tensor (and thus
  // a band) for the topology — i.e. a run may lattice + certify it. Octet is the
  // only true value today; the set widens as core's LatticeTopology enum grows, and
  // this accessor reflects that with no app change.
  bool certifiable = false;
  // The minimum number of cells that must span a member for the homogenized
  // certification to hold (the scale-separation ceiling: max printable cell =
  // member_width / this). 0.0 == the core does NOT yet expose a certified value
  // (that measurement is landing in a parallel task) — the UI then treats
  // cells-per-member as ADVISORY (a readout, not a hard clamp) and the clamp
  // engages automatically once core returns a positive value here. This is NOT an
  // app-side limit: it is exactly whatever the core reports.
  double min_cells_per_member = 0.0;
};

// The certifiable limits for a lattice topology named as the job schema names it
// ("octet"). An unknown / not-yet-certified name returns `certifiable == false`
// with a zero band (the UI greys that topology and says why). Never throws.
LatticeLimits lattice_limits(const std::string& topology);

// The topology names the core certification library covers (can be RUN and
// certified), in the core's own order — the seven cubic topologies today. The UI
// reads this to know which picker entries are certifiable rather than assuming a
// set. Never throws.
std::vector<std::string> lattice_certifiable_topologies();

// The topology names the core GEOMETRY GENERATOR can emit (topopt::
// LatticeGenTopology) — ["octet"] today. Certifiability and generatability are
// INDEPENDENT properties: core certifies seven topologies but can generate
// geometry for only this set, so a picker must read BOTH and never infer one
// from the other. Read directly from core's own enumerator
// (topopt::lattice_gen_topology_names) — no mirrored list remains app-side, so
// core enum growth reaches the picker with zero app changes. Never throws.
std::vector<std::string> lattice_generatable_topologies();

}  // namespace topoptbridge
