// FlexibleBridge — the Flexible stage's slice of the bridge (task
// 2026-09-29-flexible-screens, step A1 of docs/design/flexibles/07-roadmap.md).
//
// ★ ONE DEFINITION (DECISIONS 2026-09-27 item 4, M9). Every number the Flexible
// screens show comes through here from core's `topopt::flexible` (C1): the filament
// catalogue, the pen curves, the face frames and stacks, the squish maps, the
// designs, the stamps, the density field and Auto. Nothing here computes a squish
// number of its own; each function is a thin copy of core's result into POD vectors
// the Swift importer can read (the same rule as TopOptBridge.hpp: no core type in
// this header).
//
// Two failure channels, as core's: malformed input fills `BridgeError` (core threw
// FlexibleError / JobError); input the DATA does not cover comes back as a refusal
// code + sentence inside the result, never as an error.
//
// A SCENE is the part, its voxel grid, the Flexible lattice mask and the resolved
// face regions, opened once from a job document and kept (the stacks built on it are
// cached per face and frame rotation): they do not change while the user draws, so
// dragging a curve point only re-runs the squish map and the design.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "TopOptBridge.hpp"  // BridgeError

namespace topoptbridge {

// Named vector types so Swift can build inputs (a template cannot be spelled there).
using FlexDoubles = std::vector<double>;
using FlexInts = std::vector<int32_t>;
using FlexStrings = std::vector<std::string>;

// ---------------------------------------------------------------------------
// The filament catalogue (F1). `materials_path` is flexible_materials.json; the
// curve tables are read from flexible_curves/ beside it. Loaded once per path and
// kept.
struct FlexMaterial {
  std::string id;
  std::string display_name;
  std::string family;
  std::string tier;  // literature | proxy_candidate | calibrate_first
  bool foaming = false;
  bool shore_a_known = false;
  double shore_a = 0.0;
  bool nozzle_range_known = false;
  double nozzle_range_lo = 0.0;
  double nozzle_range_hi = 0.0;
  // ★ R10: the ONLY temperatures to offer (core's tested_temperatures). Empty ⇒
  // the filament predicts nothing.
  std::vector<double> tested_temps_c;
  std::string offered_temps_note;
  std::string note;
  std::vector<std::string> sources;
  // the reason a calibrate_first / proxy_candidate filament predicts nothing
  // (core's curve_set refusal sentence); "" for a filament with data
  std::string no_prediction_code;
  std::string no_prediction_reason;
};
std::vector<FlexMaterial> flexible_materials(const std::string& materials_path,
                                             BridgeError& err);

struct FlexErrorBands {
  double literature = 0.0;
  double calibrated = 0.0;
  double proxy = 0.0;
  std::string status;
  std::string note;
};
FlexErrorBands flexible_error_bands(const std::string& materials_path, BridgeError& err);

// "" or core's note, e.g. "below the manufacturer's range 195-260 °C; tested by
// iacob2024" (H5: shown next to the temperature, never hiding it).
std::string flexible_temperature_note(const std::string& materials_path,
                                      const std::string& material_id, double temp_c,
                                      BridgeError& err);

// ---------------------------------------------------------------------------
// Pen curves (F4, R12). The curve on screen is core's curve.
std::string flexible_pen_curve_error(const std::vector<double>& x,
                                     const std::vector<double>& y);
std::vector<double> flexible_pen_curve_values(const std::vector<double>& x,
                                              const std::vector<double>& y,
                                              const std::vector<double>& t, BridgeError& err);

// ---------------------------------------------------------------------------
// The squish table (F3, F10).
struct FlexCurveSet {
  bool refused = false;
  std::string refusal_code;
  std::string refusal_reason;
  double density_min = 0.0;
  double density_max = 0.0;
  double strain_measured_max = 0.0;
  double strain_limit = 0.0;
  std::string density_basis;
  std::string tier;
  std::string strain_convention;
  std::vector<double> row_density;  // ascending core density
  std::vector<std::string> row_entry_id;
  std::vector<std::string> row_source;
};
FlexCurveSet flexible_curve_set(const std::string& materials_path,
                                const std::string& material_id, double temp_c,
                                const std::string& topology, BridgeError& err);

struct FlexStress {
  bool ok = false;
  double stress_mpa = 0.0;
  bool extrapolated = false;
  std::string refusal_code;
  std::string refusal_reason;
};
FlexStress flexible_stress_at(const std::string& materials_path, const std::string& material_id,
                              double temp_c, const std::string& topology, double strain,
                              double core_density, BridgeError& err);

struct FlexInverse {
  bool ok = false;
  std::string status;  // ok | too_firm | too_soft | beyond_data | no_pressure
  double core_density = 0.0;
  bool extrapolated = false;
  double nearest_density = 0.0;
  double nearest_strain = 0.0;
  bool nearest_known = false;
  std::string refusal_code;
  std::string refusal_reason;
};
FlexInverse flexible_density_for(const std::string& materials_path,
                                 const std::string& material_id, double temp_c,
                                 const std::string& topology, double target_strain,
                                 double pressure_mpa, BridgeError& err);

struct FlexStrain {
  bool ok = false;
  double strain = 0.0;
  bool extrapolated = false;
  std::string refusal_code;
  std::string refusal_reason;
};
FlexStrain flexible_strain_under(const std::string& materials_path,
                                 const std::string& material_id, double temp_c,
                                 const std::string& topology, double pressure_mpa,
                                 double core_density, BridgeError& err);

// σ(ε) at one density, sampled by core's stress_at at `strains` (the physics
// panel's curve). Entries past the data carry ok == 0 and no number.
struct FlexCurveSamples {
  std::vector<double> strain;
  std::vector<double> stress_mpa;
  std::vector<int32_t> ok;            // 1 = a number
  std::vector<int32_t> extrapolated;  // 1 = past the last tabulated strain
};
FlexCurveSamples flexible_curve_samples(const std::string& materials_path,
                                        const std::string& material_id, double temp_c,
                                        const std::string& topology, double core_density,
                                        const std::vector<double>& strains, BridgeError& err);

struct FlexTierBand {
  std::string tier;
  double band = 0.0;
  std::string why;
};
FlexTierBand flexible_tier_band(const std::string& materials_path, const std::string& set_tier,
                                bool side_stack, int32_t beads_per_wall, BridgeError& err);

double flexible_cell_size_mm(const std::string& topology, double core_density,
                             int32_t beads_per_wall, double bead_width_mm, BridgeError& err);

// ---------------------------------------------------------------------------
// Stamps (F8): the APP rasterises; core checks and uses the grid as-is (M14).
struct FlexStampGrid {
  bool present = false;
  std::string name;
  double origin_u_mm = 0.0;
  double origin_v_mm = 0.0;
  double cell_mm = 0.0;
  int32_t nu = 0;
  int32_t nv = 0;
  std::vector<double> values_mpa;  // nu*nv, row-major in v
  double force_n = 0.0;
  bool rigid = false;
};
std::string flexible_stamp_grid_error(const FlexStampGrid& s);
double flexible_stamp_force_n(const FlexStampGrid& s);
double flexible_stamp_width_mm(const FlexStampGrid& s);

// ---------------------------------------------------------------------------
// The squish map (F6) and build parameters.
struct FlexSquishMap {
  std::string mode;  // both | either | centre_edge
  std::vector<double> x_x, x_y, y_x, y_y, c_x, c_y;
  double deepest_squish_mm = 0.0;
};
struct FlexBuild {
  std::string topology;  // gyroid | honeycomb
  int32_t beads_per_wall = 1;
  double bead_width_mm = 0.0;
};

// ---------------------------------------------------------------------------
// THE SCENE. `job_json` is a job document with a `flexible` block (the app's own
// encoder writes it); its `model` is read relative to `job_dir` (an absolute path is
// used as is). Returns a handle > 0, or 0 with `err` filled.
int64_t flexible_scene_open(const std::string& job_json, const std::string& job_dir,
                            BridgeError& err);
void flexible_scene_close(int64_t scene);

struct FlexSceneInfo {
  int32_t nx = 0, ny = 0, nz = 0;
  double spacing = 0.0;
  double origin[3] = {0, 0, 0};
  int64_t lattice_voxels = 0;
  double build_dir[3] = {0, 0, 1};
  std::vector<int32_t> region_ids;  // the job's resolved face regions
  std::vector<std::string> region_names;
  // per region, its member B-rep face ids, flattened with offsets (size regions+1)
  std::vector<int32_t> region_face_offsets;
  std::vector<int32_t> region_faces;
};
FlexSceneInfo flexible_scene_info(int64_t scene, BridgeError& err);

// A face region's frame and stack (F5), cached per (region, rotation).
struct FlexStack {
  // frame
  bool frame_valid = false;
  std::string frame_reason;
  double load[3] = {0, 0, -1};
  double x_axis[3] = {1, 0, 0};
  double y_axis[3] = {0, 1, 0};
  double centroid[3] = {0, 0, 0};
  int32_t rotation_deg = 0;
  double u_min = 0.0, v_min = 0.0;
  double u_extent_mm = 0.0, v_extent_mm = 0.0;
  double area_mm2 = 0.0, projected_area_mm2 = 0.0;
  double normal_spread_deg = 0.0;
  bool normal_spread_flag = false;
  double build_angle_deg = 0.0;
  bool side = false;
  bool principal_axis_tied = false;
  // columns
  double pitch_mm = 0.0;
  int32_t nu = 0, nv = 0;
  std::vector<int32_t> cell;  // nu*nv -> column or -1
  std::vector<double> col_u_mm, col_v_mm, col_area_mm2, col_entry_t, col_exit_t, col_lattice_mm;
  std::vector<int32_t> col_iu, col_iv, col_exit_face;
  // the linked other end (M13)
  std::vector<int32_t> exit_face_ids;
  std::vector<double> exit_face_fractions;
  std::vector<int32_t> exit_region_ids;
  std::vector<double> exit_region_fractions;
  double exit_unresolved_fraction = 0.0;
  double footprint_area_mm2 = 0.0;
  int32_t latticed_columns = 0;
  double lattice_mm_min = 0.0, lattice_mm_mean = 0.0, lattice_mm_max = 0.0;
  double stack_mm_max = 0.0;
};
FlexStack flexible_scene_stack(int64_t scene, int32_t face_region_id, int32_t rotation_deg,
                               BridgeError& err);

// Core's FaceFrame::from_uv for every (u, v) pair in `uv` (flattened) → xyz
// flattened. The app places everything it draws on a face through this.
std::vector<double> flexible_scene_from_uv(int64_t scene, int32_t face_region_id,
                                           int32_t rotation_deg, const std::vector<double>& uv,
                                           BridgeError& err);

// Core's FaceFrame::to_uv for every xyz point (flattened) → (u, v, t) flattened, t
// the distance along the load from the frame plane (the column's entry_t / exit_t axis).
std::vector<double> flexible_scene_to_uvt(int64_t scene, int32_t face_region_id,
                                          int32_t rotation_deg, const std::vector<double>& xyz,
                                          BridgeError& err);

// S per column (the fast path while a curve point is dragged) and the
// centre→edge t per column.
std::vector<double> flexible_scene_squish_fraction(int64_t scene, int32_t face_region_id,
                                                   int32_t rotation_deg,
                                                   const FlexSquishMap& map, BridgeError& err);
std::vector<double> flexible_scene_edge_fraction(int64_t scene, int32_t face_region_id,
                                                 int32_t rotation_deg, BridgeError& err);

// The per-column design (F6, F7). Kept on the scene for the density field.
struct FlexFaceDesign {
  bool refused = false;  // the curve set refused (calibrate_first, untested temp ...)
  std::string refusal_code;
  std::string refusal_reason;
  // per column (parallel to FlexStack's columns)
  std::vector<double> s, pressure_mpa, height_mm, target_depth_mm, target_strain,
      target_density, nearest_depth_mm, clamped_density, clamped_depth_mm, buildable_density,
      buildable_depth_mm, cell_mm, sigma_mm;
  std::vector<std::string> status;  // ok | too_firm | too_soft | beyond_data | no_lattice
  std::vector<int32_t> target_extrapolated, nearest_known, buildable_ok, buildable_extrapolated;
  // tier (F10)
  std::string tier;
  double band = 0.0;
  std::string tier_why;
  // counts
  int32_t ok = 0, too_firm = 0, too_soft = 0, beyond_data = 0, no_lattice = 0,
          solid_under_map = 0, target_extrapolated_count = 0, buildable_extrapolated_count = 0,
          buildable_beyond_data = 0, near_edge = 0;
  double design_pressure_even_mpa = 0.0;
  bool design_stamp_used = false;
  bool design_stamp_rigid_averaged = false;
  bool design_stamp_off_face = false;
  double design_stamp_off_face_n = 0.0;
  double max_smoothing_change_mm = 0.0;
  double material_volume_mm3 = 0.0;
  double target_depth_min = 0.0, target_depth_max = 0.0;
  double buildable_depth_min = 0.0, buildable_depth_max = 0.0;
  double buildable_density_min = 0.0, buildable_density_max = 0.0;
  double cell_min = 0.0, cell_max = 0.0;
  double sigma_min = 0.0, sigma_max = 0.0;
};
FlexFaceDesign flexible_scene_design(int64_t scene, const std::string& materials_path,
                                     const std::string& material_id, double temp_c,
                                     int32_t face_region_id, int32_t rotation_deg,
                                     const FlexSquishMap& map, double weight_n,
                                     const FlexStampGrid& design_stamp, const FlexBuild& build,
                                     BridgeError& err);

// Check mode (F8): press `stamp` on the designed column densities.
struct FlexStampCheck {
  bool ok = false;
  std::string refusal_code;
  std::string refusal_reason;
  std::vector<double> depth_mm;        // per column; < 0 = not pressed
  std::vector<std::string> status;     // "" | ok | extrapolated | beyond_data
  int32_t pressed_columns = 0, extrapolated_columns = 0, beyond_data_columns = 0,
          rigid_unlatticed_columns = 0;
  double max_depth_mm = 0.0;
  double rigid_depth_mm = 0.0;
  double stamp_width_mm = 0.0;
  double local_cell_mm = 0.0;
  bool narrow = false;
  double force_off_face_n = 0.0;
  bool off_face = false;
  std::string tier;
  double band = 0.0;
  std::string tier_why;
};
FlexStampCheck flexible_scene_check_stamp(int64_t scene, const std::string& materials_path,
                                          const std::string& material_id, double temp_c,
                                          int32_t face_region_id, int32_t rotation_deg,
                                          const std::vector<double>& column_density,
                                          const FlexStampGrid& stamp, const FlexBuild& build,
                                          BridgeError& err);

// One profile per stack (M13): conflicts among the loaded faces' stacks.
struct FlexConflict {
  int32_t face_a = -1, face_b = -1;
  double overlap_mm3 = 0.0;
  double axis_angle_deg = 0.0;
};
std::vector<FlexConflict> flexible_scene_conflicts(int64_t scene,
                                                   const std::vector<int32_t>& face_region_ids,
                                                   const std::vector<int32_t>& rotations,
                                                   BridgeError& err);

// The 3D density field (F6 + R11) from the designs last computed on this scene for
// the given faces, and one axis-aligned slice of it: `axis` 0/1/2 = x/y/z, `index`
// the voxel layer. density: -1 not lattice, 0 lattice under no loaded stack, else ρ.
struct FlexFieldSlice {
  int32_t width = 0, height = 0;  // the slice's two in-plane axes, in voxel order
  double spacing = 0.0;
  std::vector<double> density;
  std::vector<int32_t> owner;
  int64_t lattice_voxels = 0, assigned_voxels = 0, unassigned_voxels = 0;
  std::vector<int32_t> handover_a, handover_b;
  std::vector<double> handover_overlap_mm3, handover_blended_mm3;
};
FlexFieldSlice flexible_scene_density_slice(int64_t scene,
                                            const std::vector<int32_t>& face_region_ids,
                                            const std::vector<int32_t>& rotations,
                                            const FlexBuild& build, int32_t axis, int32_t index,
                                            BridgeError& err);

// The whole field (same cache as the slice): density per voxel, x fastest, and the
// owner face per voxel. The lattice preview builds its walls from this.
struct FlexField {
  int32_t nx = 0, ny = 0, nz = 0;
  double spacing = 0.0;
  double origin[3] = {0, 0, 0};
  std::vector<float> density;  // -1 not lattice, 0 unassigned, else rho
  std::vector<int32_t> owner;
};
FlexField flexible_scene_density_field(int64_t scene, const std::vector<int32_t>& face_region_ids,
                                       const std::vector<int32_t>& rotations, const FlexBuild& build,
                                       BridgeError& err);

// ---------------------------------------------------------------------------
// Auto (F9).
struct FlexFaceRequest {
  int32_t face_region_id = -1;
  int32_t rotation_deg = 0;
  FlexSquishMap map;
  double weight_n = 0.0;
  FlexStampGrid design_stamp;
};
struct FlexRecommendation {
  bool chosen = false;
  bool reachable = false;
  std::string topology;
  double temp_c = 0.0;
  std::string feel;
  std::string sentence;
  std::vector<std::string> reason_code, reason_text;
  std::vector<int32_t> reason_face;
  // candidates
  std::vector<std::string> cand_topology;
  std::vector<double> cand_temp_c;
  std::vector<int32_t> cand_eligible, cand_has_data, cand_reachable, cand_unreachable_columns,
      cand_near_edge_columns, cand_mass_known;
  std::vector<double> cand_mass_g;
  std::vector<std::string> cand_refusal_code, cand_refusal_reason;
  // the choice's failures (nothing reachable)
  std::vector<int32_t> fail_face;
  std::vector<std::string> fail_text;
  std::vector<double> fail_u_min, fail_u_max, fail_v_min, fail_v_max;
  std::vector<int32_t> fail_nearest_known;
  std::vector<double> fail_nearest_min_mm, fail_nearest_max_mm;
  std::vector<int32_t> fail_too_firm, fail_too_soft, fail_beyond_data;
};
using FlexFaceRequests = std::vector<FlexFaceRequest>;
FlexRecommendation flexible_scene_recommend(int64_t scene, const std::string& materials_path,
                                            const std::string& material_id,
                                            const std::vector<double>& temps,
                                            const std::vector<std::string>& topologies,
                                            const std::string& feel, int32_t beads_per_wall,
                                            double bead_width_mm,
                                            const std::vector<FlexFaceRequest>& faces,
                                            BridgeError& err);

// ---------------------------------------------------------------------------
// The job block (F11), read back through core's own parser (parse_job) — the
// round-trip proof that the app writes the block exactly as core reads it.
struct FlexJobFace {
  int32_t face_region_id = -1;
  std::string role;
  int32_t frame_rotation_deg = 0;
  double weight_n = 0.0;
  double deepest_squish_mm = 0.0;
  std::string mode;
  std::vector<double> x_x, x_y, y_x, y_y, c_x, c_y;
  FlexStampGrid design_stamp;
  bool skin_on = true;
};
struct FlexJobBlock {
  std::string material_id;
  bool nozzle_temp_auto = false;
  double nozzle_temp_c = 0.0;
  std::string topology;
  std::string feel;
  int32_t beads_per_wall = 1;
  double min_extrudable_width_mm = 0.0;
  int32_t region_count = 0;
  std::vector<FlexJobFace> faces;
  std::vector<int32_t> check_face_ids;
  std::vector<FlexStampGrid> check_stamps;
};
FlexJobBlock flexible_parse_job_block(const std::string& job_json, BridgeError& err);

// ---------------------------------------------------------------------------
// THE RUN (round 4, batch C2 — maintainer: "when Lattice Ready shows, tapping it should send
// to Core and the export path"). Core's own Flexible runner, `run_flexible_job` (the one
// `topopt-cli flexible` calls; run_job / lattice_variant_job REFUSE a job with a `flexible`
// block): the job document is parsed by core's `parse_job`, its `model` read relative to
// `job_dir`, and every receipt, heat map and CSV written into `out_dir`. A stage refusal
// (calibrate-first filament, two loaded faces on one stack, …) comes back in the result with
// core's code and sentence; malformed input fills `err`.
struct FlexRunResult {
  bool refused = false;
  std::string refusal_code;
  std::string refusal_reason;
  std::string receipt_json;        // the `flexible` block of run_info.json
  std::vector<std::string> files;  // written, relative to out_dir
};
FlexRunResult flexible_run_job(const std::string& job_json, const std::string& job_dir,
                               const std::string& out_dir, const std::string& materials_path,
                               const std::string& fingerprint, BridgeError& err);

// ---------------------------------------------------------------------------
// ── BATCH G: the squish as ONE 3D displacement field — the app's setup, core's solver ──
// (round 5, batch G; maintainer: "is there a way to ensure that the squish sim also squeezes
// out the sides of the object? I'd like it to actually bend and move and squish like it would
// in real life"). One squeeze group's force on its pressed faces (core's column pressures,
// sector cuts respected), resting faces held — BONDED where a pressed stack of the group exits
// through them (an anvil grips under load), sliding (the normal only) elsewhere — and whatever
// rigid modes that leaves free (all six for a pinch or a hand squeeze with nothing resting)
// relieved by inertia relief and pinned by one DOF each, their rigid motion removed afterwards;
// the sides free — solved by core's EXISTING heterogeneous matrix-free MG-CG (fea_solve_mgcg_matfree) on
// the scene's own voxel grid (coarsened by one rule, flexible_squish_coarsen), each voxel's
// modulus the SECANT of core's tested squish curve at its own density and operating strain
// (flexible_squish_modulus). Linear small-strain physics, a DISPLAY field: the app scales it so
// its deepest zone moves exactly core's deepest squish. Core itself is not edited; the setup
// lives in the app's private flexible_squish_fe.cpp.
using FlexFloats = std::vector<float>;
using FlexBytes = std::vector<uint8_t>;
struct FlexSquishPress {                // one pressed face of the squeeze group
  int32_t face_region_id = -1;
  int32_t rotation_deg = 0;
  std::vector<double> column_pressure_mpa;  // parallel to the stack's columns (core's design)
};
using FlexSquishPresses = std::vector<FlexSquishPress>;
struct FlexSquishLaw {
  std::string materials_path, material_id, topology;  // gyroid | honeycomb
  double temp_c = 0.0;
  bool shape_only = false;               // calibrate-first: E = max(rho, 0.05)^2 (relative units)
};
struct FlexSquishRequest {
  FlexSquishPresses pressed;
  std::vector<int32_t> resting_region_ids;
  FlexFloats rho;        // per SCENE voxel (x fastest): < 0 not lattice; else the printed core rho
  FlexFloats strain_op;  // per scene voxel: its column's strain under THIS group; 0 = none
  FlexFloats skin_frac;  // per scene voxel: the share inside the skin, 0..1
  FlexSquishLaw law;
  double poisson = 0.3, tolerance = 1e-4, deadline_ms = 20000;
  int32_t coarsen = 0;   // 0 = the rule (flexible_squish_coarsen)
  int32_t control = 0;   // TESTS ONLY (bits: 1 nu=0 . 2 anchor patch . 4 ignore cuts .
                         // 8 uniform pressure . 16 uniform E . 32 lattice=solid . 64 no extension
                         // . 128 every rest slides . 256 nominal-strain law . 512 other pins
                         // . 1024 unprojected traction . 2048 every rest bonded — the app's one
                         // retry when a solve whose rests slide does not converge) . 4096 the
                         // iteration budget lifted (a reference solve) . 8192 the old fixed 600
                         // iterations . 16384 core's GenEO + Krylov recycling left as found
                         // . 32768 a pressed stack's far end NOT held when other faces rest —
                         // batch G's rule, the red control of the far anvil); else the app sends 0
};
struct FlexSquishSolution {
  bool ok = false;
  std::string failure;
  std::string bc_mode;                   // rest | exit | free | patch (control 2)
  int32_t free_modes = 0;                // rigid modes the rests leave free (6: nothing rests), each
                                         // relieved (inertia relief) and pinned by one DOF
  int32_t far_anvils = 0;                // pressed stacks' far ends held along their normal beside
                                         // the rests (neither resting nor pressed by the group)
  int32_t coarsen = 1;
  int32_t nx = 0, ny = 0, nz = 0;        // FE NODE counts
  double spacing = 0.0;
  double origin[3] = {0, 0, 0};          // node (0,0,0) = the grid's corner
  FlexFloats u;                          // 3 per node, mm, RAW (uncalibrated), extended to every node
  FlexBytes solved;                      // per node: 1 = a node the solver owned (a solid element's)
  FlexFloats element_e;                  // ★ batch M: per FE ELEMENT ((nx-1)(ny-1)(nz-1), x fastest), the
                                         // modulus it was solved with (MPa; relative units under
                                         // shape_only), 0 = no solid — the app's stress view (sigma = C : eps)
  int32_t elements = 0, iterations = 0, mg_levels = 0;
  int32_t max_iterations = 0;            // the solve's cap: a WORK budget (elements x iterations)
  bool used_multigrid = false;
  double residual = 0, setup_ms = 0, solve_ms = 0, e_min_mpa = 0, e_max_mpa = 0;
  double wait_ms = 0;                    // waiting for another sim to leave the solver (the
                                         // deadline starts after it)
  double applied_force_n[3] = {0, 0, 0};  // the presses' loads, summed (before inertia relief)
  double applied_force_abs_n = 0;         // sum of the presses' force magnitudes
  double held_reaction_n[3] = {0, 0, 0};  // K u - f summed over the held (rest / exit) DOFs
  double anchor_reaction_n = 0;           // |K u - f| over the pinned DOFs (free: the six 3-2-1 pins)
  int32_t threads_before = 0, threads_during = 0, threads_after = 0;  // posture receipt
  bool geneo_before = false, geneo_during = false, geneo_after = false;  // core's GenEO deflation
  bool recycling_during = false;         // core's Krylov recycling while the sim solved
  // receipts the tests read: each press's nodal loads (flattened per press) and its force
  std::vector<int32_t> press_load_offsets;  // size presses + 1, into press_load_nodes
  std::vector<int32_t> press_load_nodes;
  std::vector<double> press_load_xyz;       // 3 per entry of press_load_nodes, N
  std::vector<double> press_force_n;        // the design force each press was normalised to
  std::vector<double> press_raw_force_n;    // sum of p * projected area before normalising
  std::vector<int32_t> held_nodes;          // rest / exit: the held sole nodes
  std::vector<int32_t> pinned_dofs;         // 3 * node + component, every Dirichlet DOF
  std::vector<int32_t> resting_missing;     // resting ids the scene does not declare
  // ★ BATCH N: the STEPPED solve's receipt (a linear solve: one solve, load factor 1)
  int64_t session = 0;                      // step_begin: the session to step (0: none — see failure)
  double load_factor = 1.0;                 // x the design force this field is at
  int32_t fixed_point_iterations = 0;       // core solves this step took (secant iterations)
  bool fixed_point_converged = false;       // the last iterate moved <= tolerance x max|u|
  double fixed_point_change = 0;            // that last relative change
  int32_t cg_iterations_total = 0;          // CG iterations over this step's solves
  bool mg_skipped = false;                  // the session's multigrid stagnated: Jacobi-CG directly
  double step_ms = 0;                       // the whole step (waits, solves, the receipt, the finish)
  double strain_p50 = 0, strain_p99 = 0, strain_max = 0;  // the solid elements' principal
                                            // compressive strain (the curves' axis) at this field
  int32_t beyond_data_elements = 0;         // elements past the curves' last tested strain
  int32_t stress_updates = 0;               // elements the last iterate updated by their STRESS
                                            // (where the curve stiffens) rather than their strain
};
FlexSquishSolution flexible_scene_squish_solve(int64_t scene, const FlexSquishRequest& req,
                                               BridgeError& err);
// ── BATCH N: the squish solved in STEPS (material-nonlinear; maintainer: "Is there no way to
// fold realistically instead?") ──
// The SAME problem as flexible_scene_squish_solve (grid, loads, rests, pins, inertia relief),
// built once; each step solves it at `load_factor` x the design force with every voxel's modulus
// the SECANT of core's tested curve at the voxel's OWN principal compressive strain — damped
// fixed-point iterations u <- K(E(eps(u)))^-1 (lambda f), warm-started (core's initial_guess) from
// the last step's field scaled to the new load, until max|du| <= tolerance x max|u| or
// `max_iterations` solves. Skin and solid voxels keep their moduli. Same posture, mutex, deadline
// (per step) and work budget (per solve) as the linear solve.
struct FlexSquishStepOptions {
  int32_t law_past_data = 1;        // past the curves' last tested strain: 0 = the curve held at its
                                    // last tested secant (no stiffening — the red control); 1 =
                                    // densification (Gibson & Ashby: sigma -> infinity at
                                    // eps_D = 1 - c rho, joined C1 to the curve)
  double densification_coeff = 1.4;  // c in eps_D = 1 - c rho
};
FlexSquishSolution flexible_scene_squish_step_begin(int64_t scene, const FlexSquishRequest& req,
                                                    const FlexSquishStepOptions& opt, BridgeError& err);
FlexSquishSolution flexible_squish_step(int64_t session, double load_factor, int32_t max_iterations,
                                        double tolerance, BridgeError& err);
void flexible_squish_step_end(int64_t session);
// TESTS: sessions not yet ended (a cancelled refine must end its own).
int64_t flexible_squish_live_sessions();
// One voxel's modulus by the STEPPED law (MPa) at its own strain — the tests' reading of the curve
// and of the densification past it.
double flexible_squish_step_modulus(const FlexSquishLaw& law, double rho, double strain, double skin_frac,
                                    const FlexSquishStepOptions& opt, BridgeError& err);
// One scene voxel's modulus (MPa; relative units under shape_only) by the law above: the secant
// of core's curve at clamp(strain, 0.02, the strain limit) (0.05, the initial modulus, when
// strain == 0), mixed with the solid modulus by the skin share; rho < 0 = solid.
double flexible_squish_modulus(const FlexSquishLaw& law, double rho, double strain,
                               double skin_frac, int32_t control, BridgeError& err);
// The coarsening factor of the FE grid for an nx x ny x nz scene grid: 1 up to 120 000 voxels,
// 2 up to 960 000, else 4 (FlexibleFE.coarsen is its Swift twin; a test holds them together).
int32_t flexible_squish_coarsen(int32_t nx, int32_t ny, int32_t nz);
// TESTS: arm (or disarm) core's GenEO two-level deflation process-wide, as a topology run's
// configure_production_options leaves it. Returns the previous setting.
bool flexible_squish_set_geneo_for_tests(bool enable);

}  // namespace topoptbridge
