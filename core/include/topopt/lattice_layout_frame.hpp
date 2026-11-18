#pragma once
// ── THE ORGANIC STRENGTH CHECK: A FRAME OF BEAMS (brief E2, Part A; rules OS1 to OS8) ─────────────────────────────
// A weave has no cells, so Install 3's check (cells credited on a voxel grid) cannot judge it. It is judged as what
// it is: a frame of round beams, one per bar, driven by a voxel solve of the whole part.
//   1. The frame (build_frame): bar ends welded into nodes; ends in the solid are solid nodes; a loose end lying on
//      another bar splits that bar there (a T-join); pieces of no length are left out.
//   2. The material per voxel (frame_material): the part's solid share and the lattice's share (the union of every
//      bar's capsule, links and stubs in), read at the same sub-points. The CLI solves the voxel grid with it
//      (analyze_fixed_design, penalty 1) on the strength job's own grid and load case.
//   3. The frame is driven (check_frame): each solid node takes the mean displacement of the material voxels within
//      a ball round it; the lattice's share of each load is put on the frame nodes near it; a piece of the frame with
//      no driven node is left out of the verdict.
//   4. The frame is solved (sparse_ldlt_solve) and each piece's stress read at both ends; a STRUT is the run of
//      pieces between real joints; its margin is the least of its stress margin and its buckling margin (pinned).
// Every number chosen here is a named strength setting (docs/strength-check/variables.json, "frame_*").
#include <cstdint>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/voxel.hpp"

namespace topopt::lattice_layout {

struct FrameSettings {
  double node_weld_mm = 1e-5;          // frame_node_weld_mm: bar ends this close are one node
  double tjoin_reach_mm = 0.3;         // frame_tjoin_reach_mm: a loose end is looked for on bars this near
  double tjoin_off_line_mm = 1e-4;     // frame_tjoin_off_line_mm: ... and must lie this close to the bar's line
  double zero_piece_mm = 1e-6;         // frame_zero_piece_mm: a piece shorter than this is left out
  double link_stiffness = 1e4;         // frame_link_stiffness: a link is a beam of its own section, this many times stiffer
  double drive_ball_voxels = 2.0;      // frame_drive_ball_voxels: the drive ball's radius, in voxels
  double drive_share = 0.5;            // frame_drive_share: a voxel drives when its material share is above this
  double collinear_tol_mm = 1e-6;      // frame_collinear_tol_mm: a piece of the frame lying on one line (rotations held)
  int collinear_max_driven = 50;       // frame_collinear_max_driven: ... looked for when it has fewer driven nodes
  double floor_shift_voxels = 0.0;     // frame_floor_shift_voxels: a bed-floor node reads its drive this many voxels up
  bool floor_free = false;             // frame_floor_free: bed-floor nodes are not driven (they join as any node)
  double load_unheld_share = 0.01;     // load_unheld_share: the lattice's share of the load above which, with no frame node near, it fails
  double unjudged_share = 0.01;        // frame_unjudged_share: strut length in pieces with no driven node, of the whole
  double min_piece = 0.1;              // frame_min_piece: a piece counts for its strut's stress when this x its width long
  int material_subdiv = 3;             // frame_material_subdiv: sub-points per voxel edge for the material
  double solve_memory_gb = 4.0;        // frame_solve_memory_gb: the frame's factor may not be predicted larger
  int weakest = 20;                    // frame_weakest: the weakest struts listed
};

// 1. The frame.
struct FramePiece {
  int a = 0, b = 0;      // nodes
  int bar = 0;           // its bar (in the Bars it was built from)
  double width = 0.0;
  bool link = false;
};
struct FrameModel {
  std::vector<Vec3> nodes;
  std::vector<char> solid;     // per node: an end of kind Solid, or an end the domain says is solid
  std::vector<char> floor;     // per node: an end the domain says is on the bed floor (Why::BedFloor)
  std::vector<FramePiece> pieces;
  std::size_t bars = 0, t_joins = 0, zero_pieces = 0, links = 0;
};
// `domain` null: only the ends' kinds say which nodes are solid (for made-up frames in tests).
FrameModel build_frame(const Bars& bars, const Domain* domain, const FrameSettings& settings = {});

// 2. The material per voxel of `grid` (only its solid voxels: the part's), at k^3 sub-points (k = material_subdiv):
// a sub-point is solid when the domain says solid there (neither Lattice nor Outside); it is lattice when it is not
// solid and lies in a bar's capsule (every bar, links and stubs in). Shares are of the voxel's volume.
struct FrameMaterial {
  std::vector<float> solid, lattice;   // per voxel; the material is solid + lattice (at most 1)
  double lattice_mm3 = 0.0;            // the lattice's union, all of it (in the solid too), on the part's voxels
  double lattice_open_mm3 = 0.0;       // of it, outside the solid
  double solid_mm3 = 0.0;
  double ms = 0.0;
};
FrameMaterial frame_material(const Bars& bars, const Domain& domain, const VoxelGrid& grid,
                             const FrameSettings& settings = {}, int threads = 0);

// 3 to 6. The check, from the voxel solve.
struct FrameVoxelSolve {
  const VoxelGrid* grid = nullptr;
  const std::vector<double>* displacement = nullptr;   // 3 per corner node, node (c (ny+1) + b) (nx+1) + a
  const FrameMaterial* material = nullptr;
  struct Load { int node = 0; int component = 0; double value = 0.0; };
  std::vector<Load> loads;                             // the voxel solve's loads, the whole of them
};
struct FrameStrength {
  double youngs_mpa = 0.0, poisson = 0.0;
  double level_mpa = 0.0;     // along a level bead (and every compression)
  double across_mpa = 0.0;    // across the layers (tension, by the angle from level)
  Vec3 up{0.0, 0.0, 1.0};     // the build direction: "level" is square to it
  double safety = 1.5;
  double light_width_mm = 0.0;   // the job's light strut width (item 5's reach)
};
struct FrameStrut {
  double margin = 0.0, stress_margin = 0.0, buckling_margin = 0.0;
  double length_mm = 0.0, width_min = 0.0, width_max = 0.0;
  Vec3 at{};                  // the middle of its worst piece
  std::string by;             // "tension", "compression" or "buckling"
  bool judged = false;        // driven, not a stub
  bool stub = false;
  std::vector<int> pieces;    // in FrameModel::pieces
  // What drives it (reported for the weakest): its two end nodes (-1: none, a closed loop), each end's kind
  // ('d' driven, 'j' joint of three or more, 'f' free, 'p' other), on the bed floor, its displacement as solved and,
  // for a driven end, the point its drive was read at; the worst piece's axial force (tension +) and larger end moment.
  int end_node[2] = {-1, -1};
  char end_kind[2] = {'p', 'p'};
  bool end_floor[2] = {false, false};
  Vec3 end_u[2]{}, end_read[2]{};
  double axial_n = 0.0, moment_nmm = 0.0;
  // Brief E3a, item 1 (what strengthening by adding reads): the most compressive axial force of its pieces (N, negative:
  // compression; 0: none), the force its buckling margin used; whether bending is the larger part of the stress at the
  // piece that set its stress margin (M r / I over |N| / A); whether any of its nodes carries a share of the load.
  double n_min = 0.0;
  bool bending_led = false;
  bool loaded = false;
};
struct FrameCheck {
  bool solved = false;
  std::string why_not;        // not solved: in plain words
  std::size_t nodes_used = 0, driven = 0, pieces_of_frame = 0, undriven_pieces = 0, rotations_held = 0;
  std::size_t dofs = 0;
  double factor_gb = 0.0, residual = 0.0;
  std::string solver;
  double drive_voxels_median = 0.0;
  std::size_t drive_fallback = 0;
  double load_total_n = 0.0, load_on_frame_n = 0.0, load_unheld_n = 0.0, load_share = 0.0;
  std::size_t frame_nodes_loaded = 0;
  std::size_t loaded_nodes_undriven = 0;   // nodes within the load's reach on a piece of the frame with no driven node
                                           // (Organic: the load has no path, the lead's ruling of 2026-11-18)
  bool load_on_open_lattice = false;
  double strut_mm = 0.0, unjudged_mm = 0.0;
  bool too_unjudged = false;
  std::size_t judged = 0, under_safety = 0, under_one = 0, buckling_failures = 0, stubs = 0;
  double smallest_margin = 0.0;   // +inf when nothing is judged
  std::vector<FrameStrut> struts;
  std::vector<int> weakest;       // into `struts`, the weakest first
  std::vector<float> bar_margin;  // per bar of the Bars the frame was built from: its strut's margin; NaN not judged
  std::vector<Vec3> node_u;       // per node: its displacement as solved (0 for nodes not in the solve)
  std::vector<char> node_loaded;  // per node: it carries a share of the load (step 5); brief E3a, item 1
  double ms_drive = 0.0, ms_assemble = 0.0, ms_solve = 0.0, ms_verdict = 0.0;
};
FrameCheck check_frame(const FrameModel& frame, const FrameVoxelSolve& voxels, const FrameStrength& strength,
                       const FrameSettings& settings = {});

// ── ONE STRENGTHEN ROUND (brief E2, item 10; prototype R6, R8 with the lead's changes) ──────────────────────────────
// From a check: every judged strut with margin m under `watch_margin`, at its pieces' ends and middles, each point with
// the reach r = `reach_mm` (the caller's strengthen_reach x the mean spacing in use in the weave, the lead's ruling of
// 2026-11-18):
//   (B) every voxel of `field` whose centre lies within r of a point gets b = min(boost_max, (watch / m)^boost_power),
//       the largest where several reach; all six components times b (`field` is changed: the caller's copy);
//   (A) a floor at the point, radius r, least width = the strut's widest piece x target_margin / m.
struct StrengthenSettings {
  double watch_margin = 2.0;     // strengthen_watch_margin
  double boost_max = 4.0;        // strengthen_boost_max
  double boost_power = 2.0;      // strengthen_boost_power
  double target_margin = 1.75;   // strengthen_target_margin
  double reach_mm = 0.0;         // strengthen_reach x the weave's mean spacing (Outcome::spacing_mean_mm); 0: no round
};
struct StrengthenRound {
  std::size_t struts_watched = 0, voxels_boosted = 0;
  double boost_largest = 1.0, boosted_mm3 = 0.0;
  std::vector<WidthFloor> floors;
};
StrengthenRound strengthen_round(const FrameModel& frame, const FrameCheck& check, const Bars& bars,
                                 TensorField& field, const StrengthenSettings& settings = {});

}  // namespace topopt::lattice_layout
