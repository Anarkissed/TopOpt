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
// asked before it, come back `cancelled` with nothing in it — core's own stop flag (Session::lay's `stop`) gives the running
// one up within one cell's work.
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
  double min_strut_lines = 2.0;     // the thinnest strut, in line widths (R5): core's kMinStrutLines (sheet H16)
  double min_wall_mm = 0.0;         // D8; 0 = off
  double rim_mm = 0.0;              // Finish Rim: 0 none, < 0 two line widths
  double cover_mm = 0.0;            // Finish Covered: 0 none, < 0 two line widths
  // K1, the flat floor on the bed under a weave region (core's Settings::bed_floor_mm, bed_up); 0 = none (sheet H1)
  double bed_floor_mm = 0.0;
  double bed_up_x = 0.0, bed_up_y = 0.0, bed_up_z = 1.0;
  // Regions, flattened: region r is region_ids[r] (> 0), region_no_lattice[r] (1 = No lattice), region_depth_mm[r],
  // region_expand_mm[r]; its faces are region_face_counts[r] entries of region_faces, after the earlier regions' faces.
  // Face numbers are the model's own (the app's FaceIDs for STEP, STL and 3MF alike).
  std::vector<int32_t> region_ids;
  std::vector<uint8_t> region_no_lattice;
  std::vector<double> region_depth_mm;
  std::vector<double> region_expand_mm;
  std::vector<int32_t> region_face_counts;
  std::vector<int32_t> region_faces;
  // ★ Organic cut 1: per region, 1 when the Organic weave fills it (core's RegionAsk::weave), not cells. Empty: none.
  std::vector<uint8_t> region_weave;
  // Protect skins, flattened the same way. Depth 0 = two line widths (D5).
  std::vector<int32_t> protect_ids;
  std::vector<double> protect_depth_mm;
  std::vector<int32_t> protect_face_counts;
  std::vector<int32_t> protect_faces;
  // D23 (his 11-17 "add a chip to ask what it should be"): per Protect skin, 1 when it is a chip's answer "Solid" (its place
  // stays listed, now "solid"); 0 his own skin. Empty: none.
  std::vector<uint8_t> protect_chip;
  // Face cuts (core's rule D22, his ask 11-14: every Edit faces cut respected): pieces of faces in place of whole faces,
  // flattened. Region r has region_piece_counts[r] pieces (0: its faces as listed), Protect skin p protect_piece_counts[p];
  // either list may be empty (no pieces there). The pieces, the regions' first and then the skins', in order: piece k has
  // piece_face_counts[k] faces of piece_faces, and piece_cut_counts[k] cuts of piece_cuts at 7 numbers each: point xyz,
  // normal xyz, strict (1 or 0). A point p is kept when (p - point) . normal >= 0, or > 0 when strict.
  std::vector<int32_t> region_piece_counts;
  std::vector<int32_t> protect_piece_counts;
  std::vector<int32_t> piece_face_counts;
  std::vector<int32_t> piece_faces;
  std::vector<int32_t> piece_cut_counts;
  std::vector<double> piece_cuts;
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
  bool cell_search = false;                  // K7: Auto's base cell searched for the fewest slivers at square faces
  bool stretch_edges = false;                // K8: a sliver left at a square face taken in by the row beside it
  double strength = 0.0;                     // G4, -1 .. 1
  // ── finish ──
  bool bars = true;                          // false: cells and strut widths only
  bool join_loose = true;                    // S5
  bool skin = false;                         // Finish Skin (S3)
  double skin_width_mm = 0.0;                // 0 = as wide as the thinner strut it joins
  double skin_reach_cells = 1.2;
  bool small_cells_in_thin_walls = false;   // his per-part choice (core Settings::small_cells_in_thin_walls), default off
  bool one_grid = false;   // "Let walls cut cells" (his 11-14, Aesthetic only): one grid the walls cut (core Settings::one_grid)
  bool drop_loose = true;                    // Finish None's rule (S4); pieces adrift go too
  // ── Install 2 (core's install-2 engine): stress, an area's own settings, zones, the size step ──
  // The stress result itself is the session's (lattice_layout_set_demand); these say how it grades.
  bool by_stress = false;                    // struts By stress (R7, R8, R12, R16): per_region is then not read
  double dial_light = 0.01;                  // By stress, "Grade to": the dial where the stress is nothing
  double dial_heavy = 1.0;                   // By stress, "Grade from": the dial at or over the reference
  double width_light_mm = 0.0;               // both > 0: the two ends in mm (Manual 1), the dials not read
  double width_heavy_mm = 0.0;
  bool cells_by_stress = false;              // C22: cell size by stress
  double reference_mpa = 0.0;                // > 0: stated; 0 = the part's own (R17: the percentile below)
  double percentile = 0.95;
  double response = 1.0;                     // the exponent on stress / reference, held to 0.25 .. 4
  double max_step = 0.0;                     // C24: the largest size step between neighbours; 0 = none
  // An area's own cells and struts (C23, R19): 20 numbers per region, in this order, NaN = not stated (the part's):
  //   algorithm (0 uniform, 1 default_grade, 2 stepped), cell_mm, cell_max_mm, cell_min_mm, min_cells_across,
  //   grade_to_shape (0/1), band_mm, band_cell_mm, cells_by_stress (0/1), by_stress (0/1), dial, dial_light,
  //   dial_heavy, width_mm, width_light_mm, width_heavy_mm, strength, response, reference_mpa, max_step.
  // Empty: no region states anything.
  std::vector<double> region_own;
  // An area's own Finish (S13): 7 per region, NaN = the part's: rim_mm, cover_mm, skin (0/1), skin_width_mm,
  // skin_reach_cells, skin_density (cut 2, OJ8: 1 to 6), skin_sink (OJ8: 0 to 1). Empty: none.
  std::vector<double> region_finish;
  // A zone in place of a region's faces (D21): 16 per region: kind (0 none, 1 box, 2 cylinder), centre xyz, axis 0 xyz,
  // axis 1 xyz, axis 2 xyz, half xyz (core's Zone: a cylinder's axis is axis 2, its radius half x, its half length
  // half z). Empty: no zones.
  std::vector<double> region_zone;
  // ── ★ notes30 (his 2026-11-26: "The strut engine hands over its struts while it works"): the strut stream ──
  // On: the lay hands its CERTAIN struts to the session's strut tap while it works (lattice_layout_strut_read): each one
  // exactly a bar of the finished lay (the print file's), never one that later vanishes. Not a "where" setting; changes
  // nothing the lay makes. OFF for Live preview, the nozzle check, places and the sample's Skip all.
  bool stream = false;
  // The floors' up, in the part's own coordinates (the timelapse's `up`: the world's up in model coordinates, or the print's
  // up of a framed session). The cells are laid lowest first along it. Not a direction: +Z.
  double stream_up_x = 0.0, stream_up_y = 0.0, stream_up_z = 1.0;
  // ★ notes30 C4: THE SOLID VIEW'S MAP made by the lay itself and returned with it (LatticeLayoutResult::map), the same box
  // and encoding as lattice_layout_grid: voxel (x, y, z)'s centre at origin + voxel_mm * (x, y, z), the part's own
  // coordinates. map_nx = 0: none (ask lattice_layout_grid after the lay, as before).
  float map_origin_x = 0.0f, map_origin_y = 0.0f, map_origin_z = 0.0f, map_voxel_mm = 0.0f;
  int32_t map_nx = 0, map_ny = 0, map_nz = 0;
};

// THE SOLID VIEW's map (his ask 11-13: the everyday view solid, not X-ray): what is at every voxel centre of a box, for the
// LAST layout laid, on every core. Two bytes per voxel, x fastest then y then z, as rg8Snorm: OPEN (+127: lattice a cell
// holds, also on an outside voxel next to one so a surface right at the opening reads it; -127 otherwise) and INSIDE the part
// (+127 / -127). Empty before the first layout.
struct LatticeLayoutGrid {
  std::vector<int8_t> rg;
  double ms = 0.0;
  // Voxels of lattice asked for (where(p).lattice()), and of those the ones no cell holds (D14: solid). His 0.2 mm nozzle
  // line (11-14) compares their share between two line widths.
  int64_t asked = 0;
  int64_t unheld = 0;
  // The unheld voxels by core's reason (SolidAt::why, NoCell): Other, WallNarrow, TooFewAcross, Sliver, RegionShallow (his
  // ruling 11-14: solid where lattice was asked is never silent — the line says why and offers fixes).
  std::vector<int64_t> nocell;
};
struct LatticeLayoutResult {
  bool cancelled = false;                    // lattice_layout_cancel came first: nothing below is filled
  // The bars, in the part's own coordinates.
  std::vector<float> bars;                   // 7 per bar: ax ay az bx by bz width_mm
  std::vector<uint8_t> bar_ends;             // 2 per bar: 0 node, 1 solid, 2 surface, 3 loose, 4 joined
  std::vector<uint8_t> bar_flags;            // 1 per bar: 1 a piece of a cut strut, 2 a skin bar,
                                             // 16 (bit 4) a BRIDGE: it lies flatter than 30 degrees, and the file writes it
                                             // as a square bar, as wide and as tall as its width, its underside level
                                             // (core's bar_is_bridge, the writer's own test); every other bar is round.
                                             // ★ notes29: a framed session judges it in the print frame (up: the print's)
  std::vector<int32_t> bar_region;          // 1 per bar: its region, 0 = the whole part
  std::vector<float> bar_cell;               // ★ Install 3: 1 per bar: the size of the cell it is a strut of, mm (core's Bar::cell)
  // The solid pieces the layout lists (D14: a cube tried and not fitted), each with its reason. Cubes sit on frames.
  std::vector<float> frames;                 // 12 per frame: origin xyz, then its three axes (unit) xyz each
  std::vector<float> solid_cubes;            // 4 per piece: low corner a b c (frame mm), size mm
  // Per laid cell, 5 each (LatticeReview's test 2, 11-13: what set this cell's size): size mm, own mm (the wall's or
  // region's own cell here), band (0 at the outline, 1 at the band's inner edge and beyond), finest (1/0), cut (1/0).
  std::vector<float> cell_info;
  // ★ Install 3 (LatticeReview's answer 11-17, core's Cell): per laid cell, aligned with cell_info — its region (0 = the
  // whole part), its wall (index into its frame's WallMap walls, -1 = the space no wall holds), its frame and its cube's low
  // corner (a b c, frame mm; its size is cell_info's first). What the old engine's bake gave the drawer and the probe.
  std::vector<int32_t> cell_region;
  std::vector<int32_t> cell_wall;
  std::vector<int32_t> cell_frame;
  std::vector<float> cell_lo;                // 3 per cell
  std::vector<float> cell_wall_mm;           // 1 per cell: its wall's width, mm (core's WallMap::Wall::width); 0 = no wall
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
  // Install 2. By stress (core's StrutReport): no field or no reference (R18), the reference used, the highest stress a
  // cell read, the cells at each end. Cell size by stress applied / asked with no stress; the one resolved reference;
  // the size step kept (C24); cut cells made solid by P8 (f).
  bool no_stress = false;
  double reference_mpa = 0.0, highest_mpa = 0.0;
  int32_t at_light = 0, at_heavy = 0;
  bool cells_by_stress = false, cells_no_stress = false;
  double stress_reference_mpa = 0.0, step_held_at = 0.0;
  int32_t thin_solid = 0;
  double ms_read = 0.0, ms_cells = 0.0, ms_bars = 0.0, ms_bridge = 0.0;
  // ★ notes30: the strut stream (settings.stream). Per bar, 1 when the stream handed it over mid-lay (the bar itself, byte
  // for byte); `streamed` how many were; `streamed_missing` struts handed over that are NOT in these bars (expected 0: one
  // is a broken promise; the app logs it).
  std::vector<uint8_t> bar_streamed;
  int64_t streamed = 0, streamed_missing = 0;
  // ★ notes30 C4: the solid view's map (settings.map_nx > 0), as lattice_layout_grid would give it for this lay (its `rg`
  // empty otherwise).
  LatticeLayoutGrid map;
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
  bool framed = false;                       // ★ notes29: opened standing in a print frame (lattice_layout_open_framed)
};

// Opens the imported model at `path` — STEP, STL or 3MF, the faces the app sees (core's import_part_file_resolved: the
// face sidecar applied) — and measures it once. `linear_deflection` <= 0: core's default (STEP only).
LatticeLayoutOpenInfo lattice_layout_open(const std::string& path, double linear_deflection, BridgeError& err);
// ★ notes29 (P8, his print orientation: after Keep, the Organic preview still grew along the model's +Z): the same part
// opened STANDING THE WAY IT PRINTS, as the print file's job opens it for "print_frame": {"up": [up_x, up_y, up_z]} (the up
// in the part's own coordinates; core's print_frame.hpp and open_in_print_frame). Every call of such a session takes and
// gives the part's OWN coordinates, as an unframed one does: core lays in the print frame (its settings, stress and tensor
// turned through the file job's door, every Organic ask growing along the print's up) and every place it gives back — the
// bars, frames, runs, flat ends, growth pieces, chips' places — is turned back (turn_preview_to_model and its kin); the
// points "where" and the maps ask about are turned in. The tensor written for the print file is the one set (the part's
// own: the file job turns it itself). An up that is not a direction is refused (err).
LatticeLayoutOpenInfo lattice_layout_open_framed(const std::string& path, double linear_deflection, double up_x,
                                                 double up_y, double up_z, BridgeError& err);
LatticeLayoutResult lattice_layout(int64_t session, const LatticeLayoutSettings& settings, BridgeError& err);
// The points asked about: 3 per point, the part's own coordinates (a struct, so Swift fills it with push_back).
struct LatticeLayoutPoints {
  std::vector<float> xyz;
};
LatticeLayoutWhere lattice_layout_where(int64_t session, const LatticeLayoutPoints& points, BridgeError& err);
LatticeLayoutGrid lattice_layout_grid(int64_t session, float origin_x, float origin_y, float origin_z, float voxel_mm,
                                      int32_t nx, int32_t ny, int32_t nz, BridgeError& err);
// ★ his 11-23 (the walls taken away FIRST, then the vines grow): the same map for these settings BEFORE the lay, when every
// lattice region is Organic (a woven region's lattice is open whatever is laid in it: SolidAt O1). The session's domain for
// these settings is made now (the lay then keeps it: the same "where"). `supported` false (and `grid.rg` empty) when a voxel
// would need the laid cells (a cube lattice region): then the map comes after the lay, as before.
struct LatticeLayoutGridAhead {
  LatticeLayoutGrid grid;
  bool supported = false;
};
LatticeLayoutGridAhead lattice_layout_grid_ahead(int64_t session, const LatticeLayoutSettings& settings, float origin_x,
                                                 float origin_y, float origin_z, float voxel_mm, int32_t nx, int32_t ny,
                                                 int32_t nz, BridgeError& err);
// THE STRESS RESULT the session grades by (Install 2): von Mises, MPa, x fastest then y then z, on a grid whose low corner
// is `origin` and whose voxel edge is `spacing` (core's DemandField). Kept by the session (one pointer between lays: core
// keeps the part's own reference by it) until set again; an empty `mpa` clears it (no stress yet).
struct LatticeLayoutDemand {
  std::vector<float> mpa;
  double origin_x = 0.0, origin_y = 0.0, origin_z = 0.0, spacing = 0.0;
  int32_t nx = 0, ny = 0, nz = 0;
};
void lattice_layout_set_demand(int64_t session, const LatticeLayoutDemand& demand, BridgeError& err);
// ★ THE CHIPS' PLACES (rule D23; his 11-17 "add a chip to ask what it should be"): the faces each region's prism runs into
// that no rule decides, of the LAST layout — call it after `lattice_layout` with the SAME settings (other settings: none).
// A separate call: it costs about as much as a layout. Place i: region[i], face_counts[i] raw faces of `faces` (seeds
// first), point / normal (3 each, outward), area_mm2[i], solid_now[i] (1: a chip entry makes it solid now).
struct LatticeLayoutPlaces {
  std::vector<int32_t> region;
  std::vector<int32_t> face_counts;
  std::vector<int32_t> faces;
  std::vector<float> point;
  std::vector<float> normal;
  std::vector<double> area_mm2;
  std::vector<uint8_t> solid_now;
  double ms = 0.0;
};
LatticeLayoutPlaces lattice_layout_places(int64_t session, const LatticeLayoutSettings& settings, BridgeError& err);
// ★ ORGANIC, CUT 1 (his 11-18: "I'd like to get going to be able to VIEW things on the ipad ASAP"; "Preview PLUS settings
// simultaneously"): the weave's preview on the iPad, from LatticeReview's engine (lattice_layout_organic.hpp, brief L2).
// Every field of core's OrganicAsk, under its own name and default, so any of his controls can reach it.
struct LatticeLayoutOrganic {
  int32_t mode = 0;               // 0 Traced, 1 Grown
  int32_t quality = 0;            // 0 Exact (what will be made), 1 Draft (for a dragged slider; NOT what will be made)
  double tolerance_mm = 0.1;      // the runs' thinning
  double spacing_mm = 0.0, spacing_min_mm = 3.0, spacing_max_mm = 8.0, spacing_exponent = 1.0;
  double width_mm = 0.0, width_heavy_mm = 0.0;
  double reference_mpa = 0.0, percentile = 0.95;
  bool shape_fit = true, member_cap = true;
  double shape_reach = 1.0;
  double build_x = 0.0, build_y = 0.0, build_z = 1.0;
  bool walls_out = false, ties = true;
  double tie_swirl = 1.0, foot_gap = 2.5;
  bool stress_goal = false;
  double void_ratio = 1.5;
  int32_t reseed_rounds = 1;
  bool wall_connect = false;
  double wall_gap = 0.0, wall_gap_heavy = 0.0;
  int32_t wall_cross = 0;
  double cross_gap = 2.5, cross_gap_heavy = 0.0, cross_climb_max_deg = 45.0;
  double top_run = 0.0, root_run = 0.0;
  int32_t run_max = 1;
  double run_gap = 0.5, run_follow = 1.0, run_pull = 0.0, run_seek = 0.0, run_min = 0.5, root_gap = -1.0;
  bool auto_by_stress = false, prune = false;
  double bed_floor_mm = 0.0;
  bool hold_parts = false;
  double part_reach_mm = 8.0, part_support_mm = 0.0;
  bool part_to_floor = false;
  double link_width = 1.0, unbraced_max = 0.0;
  bool tie_level = false;
  double tie_gap = 1.0, tie_gap_heavy = 0.0;
  bool follow_stress = true;   // OP6 (his 11-18): true stress and shape, false shape only
  double layer_mm = 0.2;       // the printer's layer: Grown's step, level ties, braces, supports (sheet H2)
  uint64_t seed = 1;
  // ★ CUT 2 (organic-cut2-handover.md, a): core's defaults; the app sends face_relief_mm (his "Depth variation": on 1, off
  // 0), relief_exclude_faces (the loaded and fixed faces: always flush) and strand_keep (his "Extra spacing between vines":
  // on 0.9, off 0.5).
  double gap_lines = 1.5;          // OG1: the gap between struts, in line widths (0 off)
  double face_relief_mm = 1.0;     // OG2/OG2b: depth variation, 0 to 1 mm
  std::vector<int32_t> relief_exclude_faces;   // OG2: faces kept flush
  double strand_keep = 0.9;        // OG3, Traced: 0.5 to 1 x the local spacing
  double wall_bare_mm = 1.5;       // OG6, Grown
  double wall_reach = 4.0;         // OG6, Grown: local spacings, 0 = no branches
  bool sweep = true;               // OV1: the vines swept as curves (the file's), at core's limits
};
// ★ E1 (LatticeReview's C2): one refusal, as core gives it — the group (its index in the list; -1 the list itself or the
// stress), the OrganicAsk field (`setting`), a code, and a plain sentence to show whole; the allowed numbers where a number
// applies.
struct LatticeLayoutRefusal {
  int32_t group = -1;
  std::string setting, code, text;
  double given = 0.0;
  bool has_min = false, has_max = false;
  double allowed_min = 0.0, allowed_max = 0.0;
};
// ★ E7, Organic per group (his 11-18: "whole part ONLY if the whole part is latticed. Otherwise, it is per Group"): group g
// holds group_region_counts[g] region ids of group_regions (after the earlier groups') and lays with asks[g]; the preview's
// quality and tolerance are asks[0]'s. One group of every weave region = the whole part.
struct LatticeLayoutOrganicGroups {
  std::vector<LatticeLayoutOrganic> asks;
  std::vector<int32_t> group_region_counts;
  std::vector<int32_t> group_regions;
};
// The weave's preview: the lay's counts (its bars are the weave's — draw `runs`), the runs packed as core packs them
// (pack_weave_runs version 2, cut 2: "WRN2", u32 2, per run 28 bytes, then 20 per point, float32, little-endian), what
// was laid, and the weave's numbers.
struct LatticeLayoutOrganicResult {
  LatticeLayoutResult layout;
  std::vector<uint8_t> runs;
  int32_t quality = 0;
  int64_t strands = 0, net_struts = 0;
  double spacing_smallest_mm = 0.0, spacing_largest_mm = 0.0, spacing_mean_mm = 0.0, ms_trace = 0.0, ms = 0.0;
  bool cancelled = false;
  std::vector<LatticeLayoutRefusal> refused;   // ★ E1: not empty = nothing laid (no throw); show each `text` whole
  std::vector<std::string> notes;              // ★ E2: plain sentences (equal cell ends)
  int64_t cross_group_touches = 0;             // ★ E7: struts of different groups that touch (not joined)
  int64_t relief_flushed = 0;                  // ★ cut 2, OJ6: bulges the print check made flush (say it when above 0)
  std::vector<double> flat_ends;               // ★ OS1 B (leg U): x, y, z per rounded end the print check held flat (Exact)
};
LatticeLayoutOrganicResult lattice_layout_organic_groups(int64_t session, const LatticeLayoutSettings& settings,
                                                         const LatticeLayoutOrganicGroups& groups, BridgeError& err);
// ★ E1: every refusal of these groups' asks (and of the stress set, when one is), before a lay; empty = valid.
std::vector<LatticeLayoutRefusal> lattice_layout_organic_validate(int64_t session, const LatticeLayoutSettings& settings,
                                                                 const LatticeLayoutOrganicGroups& groups, BridgeError& err);
LatticeLayoutOrganicResult lattice_layout_organic(int64_t session, const LatticeLayoutSettings& settings,
                                                  const LatticeLayoutOrganic& organic, BridgeError& err);
// The stress TENSOR a weave follows (Voigt, 6 per voxel, x fastest; low corner `origin`, voxel edge `spacing`), kept by the
// session until set again; an empty `voigt` clears it (a weave then lays nothing: core's no_stress_result).
struct LatticeLayoutTensor {
  std::vector<float> voigt;
  double origin_x = 0.0, origin_y = 0.0, origin_z = 0.0, spacing = 0.0;
  int32_t nx = 0, ny = 0, nz = 0;
};
void lattice_layout_set_tensor(int64_t session, const LatticeLayoutTensor& tensor, BridgeError& err);
// ★ Organic cut 2 (the export, handover f and g): the stress the session's next lay follows — as set, or as the synthetic
// stress filled it ("Simulate stresses on unstressed walls") — written to `path` as core's TOTENSOR file, the lattice file
// job's `tensor`. False (err set) when the session holds none.
bool lattice_layout_write_tensor(int64_t session, const std::string& path, BridgeError& err);
// The Auto Sweep limits per weave region of the domain `settings` lay in, before any lay (Session::sweep_limits, OP5; the
// domain is kept for the next lay; LatticeReview's rule, its four fractions core's named constants). `measured` 0: a region core cannot measure (a curved shell): no Auto there.
struct LatticeLayoutSweep {
  std::vector<int32_t> region;
  std::vector<uint8_t> measured;
  std::vector<double> d_mm, strut_lower_mm, strut_upper_mm, strut_auto_mm, cell_lower_mm, cell_upper_mm, cell_auto_mm;
  // ★ Cut 2, OG1: the gap between struts (gap_lines x the line; 0 when off). A cell under the thin strut + the gap is
  // refused (under_gap_cell); the limits' own lower end already respects it.
  std::vector<double> gap_mm;
};
LatticeLayoutSweep lattice_layout_sweep_limits(int64_t session, const LatticeLayoutSettings& settings, double line_mm,
                                               BridgeError& err);
// Region ids (and, for the synthetic call, each one's number of foci): a struct, so Swift fills it member by member.
struct LatticeLayoutIds {
  std::vector<int32_t> ids;
  std::vector<int32_t> foci;
};
// ★ E4 per group: the union of `regions.ids`' limits as ONE entry (region 0); `measured` 0 when none was measured.
LatticeLayoutSweep lattice_layout_sweep_limits_for(int64_t session, const LatticeLayoutSettings& settings,
                                                   const LatticeLayoutIds& regions, double line_mm, BridgeError& err);
// ★ E5, "Simulate stresses on unstressed walls" and the samples' one focus: core fills the stress the session holds (the
// last real one set) — or, `from_empty`, makes one with no solve — for the walls (region ids, their number of foci), and
// keeps the filled field as the tensor the next Organic lay follows. An empty wall list (not from_empty) puts the real
// stress back. Per weave region: whether core found it without stress, the foci used, the voxels filled.
struct LatticeLayoutSynthetic {
  std::vector<int32_t> region;
  std::vector<uint8_t> without_stress;
  std::vector<int32_t> foci;
  std::vector<int64_t> filled;
  std::vector<LatticeLayoutRefusal> refused;   // not empty: nothing made, the stress unchanged
};
LatticeLayoutSynthetic lattice_layout_synthetic(int64_t session, const LatticeLayoutSettings& settings,
                                                const LatticeLayoutOrganicGroups& groups, const LatticeLayoutIds& walls,
                                                bool from_empty, BridgeError& err);
// ★ WATCH IT GROW (his 11-22: "Could the user literally *watch* the lattice grow from nothing?"): what the session's Organic
// lay has laid so far (core's GrowthTap; the session owns one, every Organic lay hands it its vines): the pieces from `from`
// on (at most `most`; 0 = all), the index to read from next time, the phase (0 none yet, 1 growing, 2 pruning, 3 re-seeding
// the bare places, 4 reaching the walls, 5 finishing) and the lay's number (a new lay starts again at 0). It NEVER waits on
// the lay (the lay holds the session's own lock for its whole length): call it from any thread while the lay runs. After a
// lay, its pieces stay until the next one starts. Traced hands each region's strands whole.
struct LatticeLayoutGrowth {
  uint64_t lay = 0;
  int32_t phase = 0;
  int64_t next = 0;
  std::vector<float> xyz;        // 6 per piece: a xyz, b xyz (the part's own coordinates)
  std::vector<int32_t> region;   // 1 per piece
};
LatticeLayoutGrowth lattice_layout_growth_read(int64_t session, int64_t from, int64_t most, BridgeError& err);

// ★ notes30 — THE STRUT STREAM (his 2026-11-26: "The strut engine hands over its struts while it works, the way Organic's
// engine does, so the floors rise in step with the real work."): what the session's strut lay (settings.stream on) has
// handed over so far: each strut is CERTAIN to be a bar of the finished lay, byte for byte (the same floats as the landed
// LatticeLayoutResult's bar: a, b, width, ends, flags, region, cell) — never one that later vanishes. The struts from `from`
// on (at most `most`; 0 = all), the index to read from next time, and the lay's number (a new lay starts again at 0).
// It NEVER waits on the lay (call it from any thread while the lay runs, as lattice_layout_growth_read). After a lay its
// struts stay until the next one starts.
//   phase: 0 no strut lay yet; 1 laying the cells; 2 the bars; 3 the pieces (the drop, the joins, the adrift test); 4 landed
//   (lattice_layout has returned this lay's result); 5 given up (cancelled or failed): nothing more of this lay comes.
//   The PLAN, fixed when the lay starts (the floors are set from it, never moved at landing): `up` (unit, the part's own
//   coordinates: settings' stream_up), the planned box lo..hi (the part's own coordinates, axis-aligned: the part's box cut
//   to where the lay's passes lay cells) and `low_mm`..`high_mm`, that box's lowest and highest along `up`; `slots` the base
//   cells to lay.
//   PROGRESS: `slots_laid`; `line_mm` THE FINISHED LINE, a height along `up` (the part's own coordinates, as low_mm):
//   everything of the lay below it is laid and settled. Rises only. Before the first floor: -1e300. A strut below the line
//   that is not handed over yet comes later (its piece found held) or lands with the lay (cut pieces, skin bars).
//   `missing` (phase 4): struts handed over that are not in the finished lay — expected 0; anything else is a broken
//   promise (log it: GenerationTimingLog).
//   THE MAP (settings.map_nx > 0): `map_state` 0 not made yet, 1 made (every voxel final except those of cells the lay
//   closes at its very end — none on the fixtures), 2 the finished lay's; read it with lattice_layout_strut_map.
//   `map_slabs_done`: per z slab of the map's grid, 1 when that slab is final (empty: all as map_state says).
struct LatticeLayoutStruts {
  uint64_t lay = 0;
  int32_t phase = 0;
  int64_t next = 0;
  float up[3] = {0.0f, 0.0f, 1.0f};
  float lo[3] = {0.0f, 0.0f, 0.0f}, hi[3] = {0.0f, 0.0f, 0.0f};
  double low_mm = 0.0, high_mm = 0.0;
  int64_t slots = 0, slots_laid = 0;
  double line_mm = -1e300;
  int64_t total = 0;                // struts handed over so far (all of them, not only from `from`)
  int64_t missing = 0;
  // The struts, as LatticeLayoutResult gives bars (the part's own coordinates):
  std::vector<float> bars;          // 7 per strut: ax ay az bx by bz width_mm
  std::vector<uint8_t> bar_ends;    // 2 per strut: always 0 0 (both ends nodes)
  std::vector<uint8_t> bar_flags;   // 1 per strut: 16 a BRIDGE (judged where it is laid, the print frame when framed); never 1 or 2
  std::vector<int32_t> bar_region;  // 1 per strut
  std::vector<float> bar_cell;      // 1 per strut: the size of its cell, mm
  std::vector<float> bar_ms;        // 1 per strut: when it was handed over, ms since the lay started (its plan)
  std::vector<int32_t> bar_laid;    // 1 per strut: the slots laid when it was handed over (of `slots`)
  int32_t map_state = 0;
  std::vector<uint8_t> map_slabs_done;
};
LatticeLayoutStruts lattice_layout_strut_read(int64_t session, int64_t from, int64_t most, BridgeError& err);
// ★ notes30 C4: the stream's map as it stands (LatticeLayoutStruts::map_state >= 1), lattice_layout_grid's box and encoding
// for the settings the lay was asked with; `rg` empty before it is made. Never waits on the lay.
LatticeLayoutGrid lattice_layout_strut_map(int64_t session, BridgeError& err);

// ★ notes28 (his 11-24: all nine strut types on the new engine): what the engine knows of a strut type, asked without a
// part. `lays`: the engine lays it — core has the type's canonical cell (lattice_has_strut_cell) and its two width limits
// (lattice_width_bounds); else false, with core's own words in `why`. `open_look`, `touch`: those two limits, strut width
// over cell size. The canonical cell exactly as the engine lays it (core's lattice_strut_cell; R12 "the app draws every
// type from core"): `s` (node coordinates are integers in units of cell / s), its struts, 6 per strut (a xyz, b xyz), and
// its nodes, 3 per node. A sheet type, or an id core does not know, never lays. Never throws (the one guard).
// Core's two Structural verdicts for the type (lattice_layout.hpp, PER TYPE; builder D 2026-11-24), each "" or ONE plain
// line: `structural_refusal` — Structural can never take it (the tetragonal three; the file job refuses such a job,
// type_not_supported); `structural_note` — its measured strength law credits none of the struts the engine lays (today
// bcc and sc; it clears by itself when the law is measured down to them).
struct LatticeLayoutTypeFacts {
  bool lays = false;
  std::string why;
  double open_look = 0.0, touch = 0.0;
  int32_t s = 0;
  std::vector<int32_t> struts;
  std::vector<int32_t> nodes;
  std::string structural_refusal;
  std::string structural_note;
};
LatticeLayoutTypeFacts lattice_layout_type_facts(const std::string& topology);

// Every layout of `session` running now or waiting comes back cancelled. Safe from any thread.
void lattice_layout_cancel(int64_t session);
void lattice_layout_close(int64_t session);

// ★ THE PRINT FILE ON THE iPAD (his 11-17: "Not everyone will have a mac, definitely include an iPad only option"): the
// SAME lattice_file job the Mac's worker runs (`topopt-cli lattice-file`), through core's own `run_file_job` — one job
// document, two executors, as the old Lattice run's `run_lattice_job`. `job_path` is the job.json, beside the model (its
// `model`, `demand` and `strength_job` are bare names resolved there); `out_dir` (must exist) receives the STL and
// lattice_file.json whatever happened. Blocking: call it off the main thread. `materials_path` / `rules_path` feed the
// strength check once the linked core has one. A refusal is not an error: `ok` false with its code and plain line.
struct LatticeFileJobResult {
  bool ok = false;
  int32_t exit_code = 1;
  std::string code;   // "ok", or core's refusal word
  std::string why;    // not ok: one plain line
  std::string detail; // not ok: the technical message behind it (for the log)
  double ms_total = 0.0;
};
LatticeFileJobResult lattice_file_job(const std::string& job_path, const std::string& out_dir,
                                      const std::string& materials_path, const std::string& rules_path, BridgeError& err);

}  // namespace topoptbridge
