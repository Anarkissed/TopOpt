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

}  // namespace topoptbridge
