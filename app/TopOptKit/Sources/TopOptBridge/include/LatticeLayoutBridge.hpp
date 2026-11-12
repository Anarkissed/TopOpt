// LatticeLayoutBridge.hpp — the lattice rebuild's stage E entry (362, from LatticeReview's proposal of 2026-11-11 22:21Z with
// the reviewer's comments of 23:52Z): the app opens a part ONCE while its Lattice page is open, lays the lattice as often as a
// setting moves (core's lattice_layout::Session keeps what the change does not touch, rule P2), and asks "what is here" of a
// batch of points. A thin pass-through: every rule is core's.
//
// The bridge's own convention (BridgeLoadCase): only scalar vectors cross, so the Swift C++ importer builds every input
// member-wise with push_back — lists of lists are FLATTENED (a count per item, then the items' entries in order).
//
// Threads: a session lays one layout at a time (its own lock). The app calls from one large-stack worker thread, never main
// (his 10-28 iPad crash: the main thread's stack is small). `lattice_layout_cancel` makes the layout running now, and any
// asked before it, come back `cancelled` with nothing in it; core's own lay() is not stopped mid-way yet (a cancel flag inside
// Session::lay is asked of LatticeReview).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "TopOptBridge.hpp"  // BridgeError

namespace topoptbridge {

// Why a place is solid, or that it is lattice: core's lattice_layout::Why, in its order, and one more.
enum LatticeLayoutWhy : uint8_t {
  kLayoutLattice = 0,      // lattice goes here
  kLayoutOutside = 1,      // not inside the part
  kLayoutNotAsked = 2,     // solid: All solid, and no Lattice region covers it (D12)
  kLayoutNoLattice = 3,    // solid: a No lattice region (D6)
  kLayoutProtectSkin = 4,  // solid: inside a Protect skin's depth (D5)
  kLayoutWallTooThin = 5,  // solid: lattice was asked for but the wall cannot hold it (D8)
  kLayoutRim = 6,          // solid: the rim round a flat Lattice region's outline (S1, S2, S10)
  kLayoutCover = 7,        // solid: Finish Covered's shell (S9)
  kLayoutNoCellFits = 8,   // solid: lattice space inside a region where no allowed cell fits (D14)
};

struct LatticeLayoutSettings {
  // ── where lattice goes (a change here reads the part again: a one-time wait) ──
  bool all_lattice = false;         // false: lattice only where a Lattice region asks (D12)
  double bead_mm = 0.45;
  double min_strut_lines = 1.0;     // the thinnest strut, in line widths (R5); 2 for an all-smallest test piece
  double min_wall_mm = 0.0;         // D8; 0 = off
  double rim_mm = 0.0;              // Finish Rim: 0 none, < 0 two line widths
  double cover_mm = 0.0;            // Finish Covered: 0 none, < 0 two line widths
  // Regions, flattened: region r is region_ids[r] (> 0), region_no_lattice[r] (1 = No lattice), region_depth_mm[r],
  // region_expand_mm[r]; its faces are region_face_counts[r] entries of region_faces, after the earlier regions' faces.
  // Face numbers are the model's own (the app's FaceIDs for STEP, STL and 3MF alike).
  std::vector<int32_t> region_ids;
  std::vector<uint8_t> region_no_lattice;
  std::vector<double> region_depth_mm;
  std::vector<double> region_expand_mm;
  std::vector<int32_t> region_face_counts;
  std::vector<int32_t> region_faces;
  // Protect skins, flattened the same way. Depth 0 = two line widths (D5).
  std::vector<int32_t> protect_ids;
  std::vector<double> protect_depth_mm;
  std::vector<int32_t> protect_face_counts;
  std::vector<int32_t> protect_faces;
  // ── the cells (a change here re-lays without reading the part) ──
  std::string topology = "octet";            // core's ids (lattice_topology_from_id)
  std::string algorithm = "default_grade";   // uniform | default_grade | stepped
  double cell_mm = 0.0;                      // 0 = Auto
  double cell_max_mm = 8.0;
  double cell_min_mm = 0.0;
  int32_t min_cells_across = 1;
  bool grade_to_shape = false;
  double band_mm = 0.0;
  double band_cell_mm = 0.0;                 // Manual smallest cell in a Grade to shape band; 0 = the floor
  // ── the struts (no cell moves) ──
  bool per_region = false;                   // false: one dial for the part (R6)
  double dial = 0.45;
  std::vector<int32_t> dial_region;          // per_region: region ids, with their dials
  std::vector<double> dial_value;
  double strut_width_mm = 0.0;               // > 0: this width everywhere (R11)
  bool allow_quilt = false;                  // R2, G11: the one switch
  double strength = 0.0;                     // G4, -1 .. 1
  // ── finish ──
  bool bars = true;                          // false: cells and strut widths only
  bool join_loose = true;                    // S5
  bool skin = false;                         // Finish Skin (S3)
  double skin_width_mm = 0.0;                // 0 = as wide as the thinner strut it joins
  double skin_reach_cells = 1.2;
  bool drop_loose = true;                    // Finish None's rule (S4); pieces adrift go too
};

struct LatticeLayoutResult {
  bool cancelled = false;                    // lattice_layout_cancel came first: nothing below is filled
  // The bars, in the part's own coordinates.
  std::vector<float> bars;                   // 7 per bar: ax ay az bx by bz width_mm
  std::vector<uint8_t> bar_ends;             // 2 per bar: 0 node, 1 solid, 2 surface, 3 loose, 4 joined
  std::vector<uint8_t> bar_flags;            // 1 per bar: 1 a piece of a cut strut, 2 a skin bar
  std::vector<int32_t> bar_region;           // 1 per bar: its region, 0 = the whole part
  // The solid pieces the layout lists (D14: a cube tried and not fitted), each with its reason. Cubes sit on frames.
  std::vector<float> frames;                 // 12 per frame: origin xyz, then its three axes (unit) xyz each
  std::vector<float> solid_cubes;            // 4 per piece: low corner a b c (frame mm), size mm
  std::vector<int32_t> solid_frame;          // 1 per piece
  std::vector<int32_t> solid_region;         // 1 per piece
  std::vector<uint8_t> solid_why;            // 1 per piece: a LatticeLayoutWhy
  // What Finish None left ragged (S4): where to point.
  std::vector<float> stepped_edges;          // 4 per edge: at xyz, ends
  std::vector<int32_t> stepped_region;
  std::vector<int32_t> empty_regions;        // asked-for regions none of whose faces has triangles
  // Counts.
  int32_t cells = 0, solid_pieces = 0, at_one_line = 0, at_widest = 0;
  int32_t stubs = 0, joined = 0, dropped = 0, pieces = 0, adrift = 0;
  double floor_cell_mm = 0.0, min_strut_mm = 0.0, open_look = 0.0, touch = 0.0;
  // The rebuild's rules (a) and (b) of 2026-11-12, as they land in core: -1 = not measured yet.
  double bed_contact_mm2 = -1.0;
  int32_t midair_starts = -1;
  bool read_again = false;                   // the part was read for this layout
  double ms_read = 0.0, ms_cells = 0.0, ms_bars = 0.0, ms_bridge = 0.0;
};

// What is at each of a batch of points (the drawer's "is this lattice, rim or solid"; the blue glow's reasons): one
// LatticeLayoutWhy and its region id (0 = the whole part) per point, for the LAST layout laid. Empty before the first.
struct LatticeLayoutWhere {
  std::vector<uint8_t> why;
  std::vector<int32_t> id;
};

struct LatticeLayoutOpenInfo {
  int64_t session = 0;                       // > 0 when it opened
  int32_t faces = 0;                         // the model's face count
  int32_t open_edges = 0;                    // 0 for a part that can be measured
  double ms_open = 0.0;
};

// Opens the imported model at `path` — STEP, STL or 3MF, the faces the app sees (core's import_part_file_resolved: the
// face sidecar applied) — and measures it once. `linear_deflection` <= 0: core's default (STEP only).
LatticeLayoutOpenInfo lattice_layout_open(const std::string& path, double linear_deflection, BridgeError& err);
LatticeLayoutResult lattice_layout(int64_t session, const LatticeLayoutSettings& settings, BridgeError& err);
// The points asked about: 3 per point, the part's own coordinates (a struct, so Swift fills it with push_back).
struct LatticeLayoutPoints {
  std::vector<float> xyz;
};
LatticeLayoutWhere lattice_layout_where(int64_t session, const LatticeLayoutPoints& points, BridgeError& err);
// Every layout of `session` running now or waiting comes back cancelled. Safe from any thread.
void lattice_layout_cancel(int64_t session);
void lattice_layout_close(int64_t session);

}  // namespace topoptbridge
