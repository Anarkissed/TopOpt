#pragma once

#include <string>
#include <vector>

#include "topopt/flexible/error.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/squish.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace flexible {

// What the lattice is made of: the topology and the wall in whole beads (R1). The
// bead width is the job's `min_extrudable_width_mm` — the key the lattice strut
// floor already reads (03 §1: "do not invent a parallel field").
struct BuildParams {
  std::string topology;        // "gyroid" | "honeycomb"
  int beads_per_wall = 1;      // 1 | 2
  double bead_width_mm = 0.0;  // > 0
};

// ════════════════════════════════════════════════════════════════════════════════
// F8 — STAMPS (02 §11, M14): a PRESSURE GRID in the face frame. The app rasterises
// the SVG/image/built-in shape; core never reads one (M14).
// ════════════════════════════════════════════════════════════════════════════════
struct StampGrid {
  std::string name;
  double origin_u_mm = 0.0;  // the grid's minimum corner, in the face's (u, v) mm
  double origin_v_mm = 0.0;
  double cell_mm = 0.0;      // square cells
  int nu = 0, nv = 0;
  std::vector<double> values_mpa;  // nu*nv, index iv*nu + iu, each >= 0
  double force_n = 0.0;            // the stated force
  bool rigid = false;              // soft: pressure as given; rigid: sinks evenly
};

// Σ value × cell area (N).
double stamp_force_n(const StampGrid& s);
// "" when valid, else one sentence: sizes, finite non-negative values, at least one
// pressed cell, and Σ value × cell area within 0.5 % of force_n.
std::string stamp_grid_error(const StampGrid& s);
inline constexpr double kStampForceTolerance = 0.005;

// The stamp's pressure on every column: the stamp averaged over the column's
// square (exact overlap areas), so the force it puts on the face is conserved.
struct StampOnColumns {
  std::vector<double> pressure_mpa;  // per column
  std::vector<char> covered;         // per column: any pressed stamp cell overlaps it
  std::vector<double> covered_area_mm2;  // per column: the pressed area inside it
  double force_on_face_n = 0.0;
  double force_off_face_n = 0.0;     // stamp force landing outside every column
};
StampOnColumns stamp_on_columns(const StampGrid& s, const Stack& stack);

// Narrowest width of the pressed shape: twice the largest inscribed distance (mm).
double stamp_width_mm(const StampGrid& s);

// ════════════════════════════════════════════════════════════════════════════════
// F6 — SQUISH MAPS (02 §12, M11)
//   both:        S = X(u)·Y(v)
//   either:      S = max(X(u), Y(v))
//   centre_edge: S = C(t),  t = distance to the face boundary ÷ its largest value
// u, v are normalised by the face extents; X, Y, C are pen curves (curve.hpp).
// ════════════════════════════════════════════════════════════════════════════════
struct SquishMap {
  std::string mode;  // "both" | "either" | "centre_edge"
  std::vector<double> x_x, x_y;  // the X curve's control points
  std::vector<double> y_x, y_y;  // the Y curve's
  std::vector<double> c_x, c_y;  // the centre->edge curve's
  double deepest_squish_mm = 0.0;
};

// S per column (in [0, 1]). Throws FlexibleError for a bad mode or curve.
std::vector<double> squish_fraction(const Stack& stack, const SquishMap& map);
// t per column (0 at the face boundary, 1 at the most-inside column).
std::vector<double> edge_fraction(const Stack& stack);

// ════════════════════════════════════════════════════════════════════════════════
// F6 + F7 — TARGET, CLAMPED AND BUILDABLE (02 §4, §12, §13, R14)
//
//   target depth    = S · deepest squish
//   design pressure = the design stamp where it presses, else weight ÷ footprint
//   target density  = the F3 inverse at (target depth ÷ latticed height, pressure)
//   clamped         = the target pulled into what the table can reach at that
//                     pressure (too_firm -> the softest row, too_soft -> the
//                     firmest, beyond_data -> the strain limit)
//   buildable       = the clamped density smoothed by a Gaussian of σ = half the
//                     local cell size (gyroid L = 3.0915 t/ρ, honeycomb d = 2t/ρ),
//                     then the forward solve under the design pressure.
//
// ★ "Buildable" is a LABELLED HEURISTIC (R14): C2's realised lattice replaces it.
// ════════════════════════════════════════════════════════════════════════════════
struct ColumnDesign {
  double s = 0.0;
  double pressure_mpa = 0.0;
  double height_mm = 0.0;         // latticed length
  double target_depth_mm = 0.0;
  double target_strain = 0.0;
  // "ok" | "too_firm" | "too_soft" | "beyond_data" | "no_lattice"
  std::string status;
  bool target_extrapolated = false;
  double target_density = 0.0;    // meaningful when status == "ok"
  double nearest_depth_mm = 0.0;  // the unreachable column's nearest achievable depth; NaN = unknown
  bool nearest_known = false;
  double clamped_density = 0.0;
  double clamped_depth_mm = 0.0;  // NaN when the nearest achievable depth is past the data (H1)
  double buildable_density = 0.0;
  double buildable_depth_mm = 0.0;
  bool buildable_ok = false;      // false: the forward solve left the data
  bool buildable_extrapolated = false;
  double cell_mm = 0.0;           // at the buildable density
  double sigma_mm = 0.0;          // the smoothing σ used at this column
};

struct Range1 {
  bool any = false;
  double min = 0.0, max = 0.0, mean = 0.0;
};

struct FaceDesign {
  int face_region_id = -1;
  std::vector<ColumnDesign> columns;  // parallel to stack.columns
  TierBand tier;
  double design_pressure_even_mpa = 0.0;
  bool design_stamp_used = false;
  bool design_stamp_rigid_averaged = false;  // a rigid design stamp is read as its
                                             // average pressure over its footprint
  double design_stamp_off_face_n = 0.0;
  bool design_stamp_off_face = false;  // some of the design stamp's force misses the face
  int ok = 0, too_firm = 0, too_soft = 0, beyond_data = 0, no_lattice = 0;
  int solid_under_map = 0;  // no_lattice columns with squish drawn over them (B2)
  int target_extrapolated = 0, buildable_extrapolated = 0, buildable_beyond_data = 0;
  int near_edge = 0;  // buildable density within 10 % of the table's span of an end
  double max_smoothing_change_mm = 0.0;
  double material_volume_mm3 = 0.0;  // Σ ρ_buildable × area × height
  Range1 target_depth, buildable_depth, buildable_density, cell;
  Range1 sigma;  // the smoothing σ used (mm), R14 / F7
};

FaceDesign design_face(const CurveSet& set, const Stack& stack, const SquishMap& map,
                       double weight_n, const StampGrid* design_stamp,
                       const BuildParams& build, const TierBand& tier);

// ════════════════════════════════════════════════════════════════════════════════
// F8 — CHECK MODE: press a stamp on the designed lattice and read the dent.
// ════════════════════════════════════════════════════════════════════════════════
struct StampCheck {
  std::string name;
  bool rigid = false;
  bool ok = false;           // false: refused (see refusal) — e.g. a rigid press past the data
  Refusal refusal;
  std::vector<double> depth_mm;     // per column; < 0 where the stamp does not press
  std::vector<std::string> status;  // per column: "" | "ok" | "extrapolated" | "beyond_data"
  int pressed_columns = 0, extrapolated_columns = 0, beyond_data_columns = 0;
  int rigid_unlatticed_columns = 0;  // under a rigid stamp but solid: the press is refused
  double max_depth_mm = 0.0;
  double rigid_depth_mm = 0.0;
  double stamp_width_mm = 0.0;
  double local_cell_mm = 0.0;        // the largest cell under the stamp
  bool narrow = false;               // narrower than 3 local cells (R9)
  double force_off_face_n = 0.0;
  bool off_face = false;             // some of the stamp's force lands off the face (B1)
  TierBand tier;
};

// `column_density` is parallel to stack.columns (<= 0 = no lattice there).
StampCheck check_stamp(const CurveSet& set, const Stack& stack,
                       const std::vector<double>& column_density, const StampGrid& stamp,
                       const BuildParams& build, const TierBand& tier);

// ════════════════════════════════════════════════════════════════════════════════
// THE 3D DENSITY FIELD + HANDOVER (02 §10, R11)
// ════════════════════════════════════════════════════════════════════════════════
struct LoadedStack {
  const Stack* stack = nullptr;
  const FaceDesign* design = nullptr;
};

// Two loaded faces pushing the SAME material along the SAME axis (M13): refused.
struct StackConflict {
  int face_a = -1, face_b = -1;
  double overlap_mm3 = 0.0;
  double axis_angle_deg = 0.0;
};
// Stacks on DIFFERENT axes that overlap: nearest loaded face, blended over one cell.
struct Handover {
  int face_a = -1, face_b = -1;
  double overlap_mm3 = 0.0;
  double blended_mm3 = 0.0;  // where neither face's weight is 0 or 1
};

// Stack conflicts, found from the stacks alone (before any design is run).
std::vector<StackConflict> find_stack_conflicts(const VoxelGrid& grid,
                                                const std::vector<char>& lattice_mask,
                                                const std::vector<const Stack*>& stacks);

struct DensityField {
  int nx = 0, ny = 0, nz = 0;
  double spacing = 0.0;
  Vec3 origin{0, 0, 0};
  // per voxel: -1 = not lattice; 0 = lattice under no loaded stack (NO density is
  // chosen there — C2 decides, and the receipt counts it); else the core density.
  std::vector<double> density;
  std::vector<int> owner;  // face_region_id with the larger weight; -1 = none
  // A6 (reviewer 2026-10-08): the owner's blend weight (1 where one stack reaches, in
  // [0.5, 1) inside a handover's blend, 0 where there is no owner) and the RUNNER-UP:
  // the face_region_id of the other stack under the voxel (-1 = none). The density is
  // owner_weight · ρ_owner + (1 − owner_weight) · ρ_runner_up.
  std::vector<double> owner_weight;
  std::vector<int> runner_up;
  long long lattice_voxels = 0, assigned_voxels = 0, unassigned_voxels = 0;
  std::vector<Handover> handovers;
};

// Assemble the field over the lattice voxels. Throws FlexibleError when a conflict
// exists (call find_stack_conflicts first to report it properly).
DensityField assemble_density_field(const VoxelGrid& grid, const std::vector<char>& lattice_mask,
                                    const std::vector<LoadedStack>& stacks,
                                    const BuildParams& build);

}  // namespace flexible
}  // namespace topopt
