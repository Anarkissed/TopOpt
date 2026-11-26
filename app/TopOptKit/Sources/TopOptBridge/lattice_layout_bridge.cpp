// lattice_layout_bridge.cpp — the lattice rebuild's stage E entry (LatticeLayoutBridge.hpp). A thin pass-through to core's
// lattice_layout::Session: every rule is core's; this file converts, keeps the sessions, and answers cancel.
#include "LatticeLayoutBridge.hpp"
#include "bridge_guard.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "topopt/face_overrides.hpp"  // import_part_file_resolved
#include "topopt/lattice.hpp"         // lattice_topology_from_id
#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"   // run_file_job: the print file on the iPad
#include "topopt/lattice_file_strength.hpp" // its strength check (Install 3)
#include "topopt/lattice_layout_organic.hpp" // ★ Organic cut 1: the weave's preview lay, its runs, the sweep limits
#include "topopt/strut_cell.hpp"            // ★ notes28: each strut type's canonical cell (lattice_layout_type_facts)

namespace topoptbridge {
namespace {
namespace ll = topopt::lattice_layout;

static_assert(static_cast<uint8_t>(ll::Why::Lattice) == kLayoutLattice && static_cast<uint8_t>(ll::Why::Outside) == kLayoutOutside &&
                  static_cast<uint8_t>(ll::Why::NotAsked) == kLayoutNotAsked &&
                  static_cast<uint8_t>(ll::Why::NoLattice) == kLayoutNoLattice &&
                  static_cast<uint8_t>(ll::Why::ProtectSkin) == kLayoutProtectSkin &&
                  static_cast<uint8_t>(ll::Why::WallTooThin) == kLayoutWallTooThin &&
                  static_cast<uint8_t>(ll::Why::Rim) == kLayoutRim && static_cast<uint8_t>(ll::Why::Cover) == kLayoutCover,
              "LatticeLayoutWhy follows core's lattice_layout::Why, in order");
static_assert(static_cast<uint8_t>(ll::Bar::End::Node) == 0 && static_cast<uint8_t>(ll::Bar::End::Solid) == 1 &&
                  static_cast<uint8_t>(ll::Bar::End::Surface) == 2 && static_cast<uint8_t>(ll::Bar::End::Loose) == 3 &&
                  static_cast<uint8_t>(ll::Bar::End::Joined) == 4,
              "bar_ends follow core's Bar::End, in order");

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

struct LayoutSession {
  std::mutex mu;                                  // one layout (or one "where") at a time
  // ★ his 11-22 (watch it grow): the tap every Organic lay of `session` hands its vines to; read WITHOUT `mu` (the lay holds
  // it for its whole length). Declared before `session`, so it outlives the session that points at it.
  ll::GrowthTap tap;
  std::unique_ptr<ll::Session> session;
  int faces = 0;
  // The last layout's outcome: "where" reads the session's domain and this layout's cells, never across the next lay().
  std::unique_ptr<ll::Outcome> last;
  std::unique_ptr<ll::SolidAt> solid_at;          // built once per layout, on the first "where"
  std::atomic<uint64_t> cancel_gen{0};
  std::atomic<bool> stop{false};                   // core's own stop (Session::lay): a running layout gives up within one cell's work
  std::shared_ptr<const ll::DemandField> demand;  // Install 2: the stress result, one pointer between lays (set_demand)
  std::shared_ptr<const ll::TensorField> tensor;  // ★ Organic cut 1: the stress tensor a weave follows (set_tensor)
  std::shared_ptr<const ll::TensorField> real_tensor;  // ★ E5: the stress as set (`tensor` may be its filled copy)
  // ★ notes29 (lattice_layout_open_framed): the print frame the part was opened standing in (off: none, and nothing below
  // is read). Set once at open, never after: read without `mu`. On, `demand`, `tensor` and `real_tensor` are in the print
  // frame (turned once, as set), and `model_tensor` is the tensor as set, in the part's own coordinates (the print file's).
  topopt::PrintFrame frame;
  std::shared_ptr<const ll::TensorField> model_tensor;
};

std::mutex& g_layout_mu = *new std::mutex;        // never destroyed (the scenes' rule, T1)
std::map<int64_t, std::shared_ptr<LayoutSession>>& g_layouts = *new std::map<int64_t, std::shared_ptr<LayoutSession>>;
int64_t g_next_layout = 1;

std::shared_ptr<LayoutSession> layout_at(int64_t id) {
  std::lock_guard<std::mutex> lock(g_layout_mu);
  auto it = g_layouts.find(id);
  if (it == g_layouts.end()) throw std::invalid_argument("lattice layout session " + std::to_string(id) + " is not open");
  return it->second;
}

void put(std::vector<float>& v, const topopt::Vec3& p) {
  v.push_back(static_cast<float>(p.x));
  v.push_back(static_cast<float>(p.y));
  v.push_back(static_cast<float>(p.z));
}

// A flattened list: item i's entries are counts[i] values of `values` after the earlier items'.
std::vector<std::vector<int>> unflatten(const std::vector<int32_t>& counts, const std::vector<int32_t>& values,
                                        const char* what) {
  std::vector<std::vector<int>> out;
  std::size_t at = 0;
  for (int32_t c : counts) {
    if (c < 0 || at + static_cast<std::size_t>(c) > values.size())
      throw std::invalid_argument(std::string(what) + ": the face counts run past the faces listed");
    out.emplace_back(values.begin() + static_cast<long>(at), values.begin() + static_cast<long>(at + c));
    at += static_cast<std::size_t>(c);
  }
  if (at != values.size()) throw std::invalid_argument(std::string(what) + ": faces listed that no count claims");
  return out;
}

ll::Algorithm algorithm_from(const std::string& s) {
  if (s == "uniform") return ll::Algorithm::Uniform;
  if (s == "default_grade") return ll::Algorithm::DefaultGrade;
  if (s == "stepped") return ll::Algorithm::Stepped;
  throw std::invalid_argument("lattice layout: unknown algorithm \"" + s + "\" (uniform | default_grade | stepped)");
}

ll::Settings settings_from(const LatticeLayoutSettings& in) {
  ll::Settings s;
  s.start = in.all_lattice ? ll::Start::AllLattice : ll::Start::AllSolid;
  s.bead_mm = in.bead_mm;
  s.min_strut_lines = in.min_strut_lines;
  s.min_wall_mm = in.min_wall_mm;
  s.rim_mm = in.rim_mm;
  s.cover_mm = in.cover_mm;
  s.bed_floor_mm = in.bed_floor_mm;   // K1 (sheet H1)
  s.bed_up = {in.bed_up_x, in.bed_up_y, in.bed_up_z};
  const std::size_t nr = in.region_ids.size();
  if (in.region_no_lattice.size() != nr || in.region_depth_mm.size() != nr || in.region_expand_mm.size() != nr ||
      in.region_face_counts.size() != nr)
    throw std::invalid_argument("lattice layout: the region lists are not all one length");
  const auto rf = unflatten(in.region_face_counts, in.region_faces, "regions");
  for (std::size_t r = 0; r < nr; ++r) {
    ll::Settings::RegionAsk a;
    a.id = in.region_ids[r];
    a.role = in.region_no_lattice[r] ? ll::Role::NoLattice : ll::Role::Lattice;
    a.faces = rf[r];
    a.depth_mm = in.region_depth_mm[r];
    a.expand_mm = in.region_expand_mm[r];
    a.weave = r < in.region_weave.size() && in.region_weave[r] != 0;   // ★ Organic cut 1: filled by the weave, not cells
    s.regions.push_back(std::move(a));
  }
  const std::size_t np = in.protect_ids.size();
  if (in.protect_depth_mm.size() != np || in.protect_face_counts.size() != np)
    throw std::invalid_argument("lattice layout: the Protect skin lists are not all one length");
  const auto pf = unflatten(in.protect_face_counts, in.protect_faces, "Protect skins");
  for (std::size_t p = 0; p < np; ++p) {
    ll::Settings::ProtectAsk a;
    a.id = in.protect_ids[p];
    a.faces = pf[p];
    a.depth_mm = in.protect_depth_mm[p];
    a.chip = p < in.protect_chip.size() && in.protect_chip[p] != 0;   // D23: a chip's answer "Solid"
    s.protect.push_back(std::move(a));
  }
  if (!in.protect_chip.empty() && in.protect_chip.size() != np)
    throw std::invalid_argument("lattice layout: protect_chip is not one per Protect skin");
  // D22: the pieces (each a list of faces and a list of cuts), handed out to the regions, then the skins, in order
  if (!in.region_piece_counts.empty() && in.region_piece_counts.size() != nr)
    throw std::invalid_argument("lattice layout: region_piece_counts is not one per region");
  if (!in.protect_piece_counts.empty() && in.protect_piece_counts.size() != np)
    throw std::invalid_argument("lattice layout: protect_piece_counts is not one per Protect skin");
  const auto piece_faces = unflatten(in.piece_face_counts, in.piece_faces, "pieces");
  if (in.piece_cut_counts.size() != piece_faces.size())
    throw std::invalid_argument("lattice layout: piece_cut_counts is not one per piece");
  std::vector<ll::FacePiece> pieces(piece_faces.size());
  std::size_t at = 0;
  for (std::size_t k = 0; k < pieces.size(); ++k) {
    pieces[k].faces = piece_faces[k];
    const int32_t c = in.piece_cut_counts[k];
    if (c < 0 || at + 7 * static_cast<std::size_t>(c) > in.piece_cuts.size())
      throw std::invalid_argument("lattice layout: the cut counts run past the cuts listed");
    for (int32_t i = 0; i < c; ++i, at += 7) {
      ll::FaceCut cut;
      cut.point = {in.piece_cuts[at], in.piece_cuts[at + 1], in.piece_cuts[at + 2]};
      cut.normal = {in.piece_cuts[at + 3], in.piece_cuts[at + 4], in.piece_cuts[at + 5]};
      cut.strict = in.piece_cuts[at + 6] != 0.0;
      pieces[k].cuts.push_back(cut);
    }
  }
  if (at != in.piece_cuts.size()) throw std::invalid_argument("lattice layout: cuts listed that no piece claims");
  std::size_t next = 0;
  const auto take = [&](int32_t n) {
    if (n < 0 || next + static_cast<std::size_t>(n) > pieces.size())
      throw std::invalid_argument("lattice layout: the piece counts run past the pieces listed");
    std::vector<ll::FacePiece> out(pieces.begin() + static_cast<long>(next), pieces.begin() + static_cast<long>(next + n));
    next += static_cast<std::size_t>(n);
    return out;
  };
  for (std::size_t r = 0; r < in.region_piece_counts.size(); ++r) s.regions[r].pieces = take(in.region_piece_counts[r]);
  for (std::size_t p = 0; p < in.protect_piece_counts.size(); ++p) s.protect[p].pieces = take(in.protect_piece_counts[p]);
  if (next != pieces.size()) throw std::invalid_argument("lattice layout: pieces listed that no region or skin claims");
  // Install 2: an area's own settings, its own Finish, zones (NaN = not stated)
  const auto stated = [](double v) { return !std::isnan(v); };
  if (!in.region_own.empty()) {
    if (in.region_own.size() != 20 * nr) throw std::invalid_argument("lattice layout: region_own is not 20 per region");
    for (std::size_t r = 0; r < nr; ++r) {
      const double* v = &in.region_own[20 * r];
      ll::AreaOwn& o = s.regions[r].own;
      if (stated(v[0])) {
        const int a = static_cast<int>(v[0]);
        if (a < 0 || a > 2) throw std::invalid_argument("lattice layout: region_own algorithm is not 0, 1 or 2");
        o.algorithm = a == 0 ? ll::Algorithm::Uniform : a == 1 ? ll::Algorithm::DefaultGrade : ll::Algorithm::Stepped;
      }
      if (stated(v[1])) o.cell_mm = v[1];
      if (stated(v[2])) o.cell_max_mm = v[2];
      if (stated(v[3])) o.cell_min_mm = v[3];
      if (stated(v[4])) o.min_cells_across = static_cast<int>(v[4]);
      if (stated(v[5])) o.grade_to_shape = v[5] != 0.0;
      if (stated(v[6])) o.band_mm = v[6];
      if (stated(v[7])) o.band_cell_mm = v[7];
      if (stated(v[8])) o.cells_by_stress = v[8] != 0.0;
      if (stated(v[9])) o.by_stress = v[9] != 0.0;
      if (stated(v[10])) o.dial = v[10];
      if (stated(v[11])) o.dial_light = v[11];
      if (stated(v[12])) o.dial_heavy = v[12];
      if (stated(v[13])) o.width_mm = v[13];
      if (stated(v[14])) o.width_light_mm = v[14];
      if (stated(v[15])) o.width_heavy_mm = v[15];
      if (stated(v[16])) o.strength = v[16];
      if (stated(v[17])) o.response = v[17];
      if (stated(v[18])) o.reference_mpa = v[18];
      if (stated(v[19])) o.max_step = v[19];
    }
  }
  if (!in.region_finish.empty()) {
    // ★ cut 2 (OJ8): 7 per region, the skin's density and sink after the five of before
    if (in.region_finish.size() != 7 * nr) throw std::invalid_argument("lattice layout: region_finish is not 7 per region");
    for (std::size_t r = 0; r < nr; ++r) {
      const double* v = &in.region_finish[7 * r];
      ll::Settings::RegionAsk& a = s.regions[r];
      if (stated(v[0])) a.rim_mm = v[0];
      if (stated(v[1])) a.cover_mm = v[1];
      if (stated(v[2])) a.skin = v[2] != 0.0;
      if (stated(v[3])) a.skin_width_mm = v[3];
      if (stated(v[4])) a.skin_reach_cells = v[4];
      if (stated(v[5])) a.skin_density = static_cast<int>(v[5]);
      if (stated(v[6])) a.skin_sink = v[6];
    }
  }
  if (!in.region_zone.empty()) {
    if (in.region_zone.size() != 16 * nr) throw std::invalid_argument("lattice layout: region_zone is not 16 per region");
    for (std::size_t r = 0; r < nr; ++r) {
      const double* v = &in.region_zone[16 * r];
      ll::Zone& z = s.regions[r].zone;
      z.kind = v[0] == 1.0 ? ll::Zone::Kind::Box : v[0] == 2.0 ? ll::Zone::Kind::Cylinder : ll::Zone::Kind::None;
      if (z.kind == ll::Zone::Kind::None) continue;
      z.centre = {v[1], v[2], v[3]};
      for (int k = 0; k < 3; ++k) z.axis[k] = {v[4 + 3 * k], v[5 + 3 * k], v[6 + 3 * k]};
      for (int k = 0; k < 3; ++k) z.half[k] = v[13 + k];
    }
  }
  s.cells.algorithm = algorithm_from(in.algorithm);
  s.cells.topology = topopt::lattice_topology_from_id(in.topology);
  s.cells.cell_mm = in.cell_mm;
  s.cells.cell_max_mm = in.cell_max_mm;
  s.cells.cell_min_mm = in.cell_min_mm;
  s.cells.min_cells_across = in.min_cells_across;
  s.cells.grade_to_shape = in.grade_to_shape;
  s.cells.band_mm = in.band_mm;
  s.cells.band_cell_mm = in.band_cell_mm;
  s.struts.mode = in.by_stress ? ll::Density::ByStress : in.per_region ? ll::Density::PerRegion : ll::Density::Uniform;
  s.struts.dial_light = in.dial_light;
  s.struts.dial_heavy = in.dial_heavy;
  s.struts.width_light_mm = in.width_light_mm;
  s.struts.width_heavy_mm = in.width_heavy_mm;
  s.cells.by_stress = in.cells_by_stress;
  s.cells.max_step = in.max_step;
#ifdef TOPOPT_CELL_SEARCH   // K7, K8 (a vendored core before notes27 has neither: the preview lays without them)
  s.cells.cell_search = in.cell_search;
  s.cells.stretch_edges = in.stretch_edges;
#endif
  s.stress.reference_mpa = in.reference_mpa;
  s.stress.percentile = in.percentile;
  s.stress.response = in.response;
  s.struts.dial = in.dial;
  if (in.dial_region.size() != in.dial_value.size())
    throw std::invalid_argument("lattice layout: dial_region and dial_value are not one length");
  for (std::size_t i = 0; i < in.dial_region.size(); ++i) s.struts.region_dial.push_back({in.dial_region[i], in.dial_value[i]});
  s.struts.width_mm = in.strut_width_mm;
  s.struts.allow_quilt = in.allow_quilt;
  s.struts.strength = in.strength;
  s.bars = in.bars;
  s.join_loose = in.join_loose;
  s.skin = in.skin;
  s.skin_spec.width_mm = in.skin_width_mm;
  s.skin_spec.reach_cells = in.skin_reach_cells;
  s.drop_loose = in.drop_loose;
  s.small_cells_in_thin_walls = in.small_cells_in_thin_walls;
  s.one_grid = in.one_grid;
  // ★ SHEETS (the contract's bridge additions): "Where regions meet" and Auto's wall by the cell (read for a sheet only)
  if (in.sheet_seam == "blend") s.sheet_seam = ll::SheetSeam::Blend;
  else if (in.sheet_seam == "solid_wall" || in.sheet_seam.empty()) s.sheet_seam = ll::SheetSeam::SolidWall;
  else throw std::invalid_argument("lattice layout: sheet_seam \"" + in.sheet_seam + "\" is not blend or solid_wall");
  s.struts.auto_by_cell = in.auto_by_cell;
  return s;
}

void fill(LatticeLayoutResult& o, const ll::Outcome& out) {
  const ll::Layout& L = out.layout;
  o.bars.reserve(out.bars.bars.size() * 7);
  o.bar_ends.reserve(out.bars.bars.size() * 2);
  for (const ll::Bar& b : out.bars.bars) {
    put(o.bars, b.a);
    put(o.bars, b.b);
    o.bars.push_back(static_cast<float>(b.width));
    o.bar_ends.push_back(static_cast<uint8_t>(b.end_a));
    o.bar_ends.push_back(static_cast<uint8_t>(b.end_b));
    o.bar_flags.push_back(static_cast<uint8_t>((b.piece ? 1 : 0) | (b.skin ? 2 : 0) | (ll::bar_is_bridge(b) ? 16 : 0)));
    o.bar_region.push_back(b.region);
    o.bar_cell.push_back(static_cast<float>(b.cell));   // ★ Install 3: the colour key's density (width against its cell)
  }
  for (const ll::Frame& f : L.frames) {
    put(o.frames, f.origin);
    for (const topopt::Vec3& a : f.ax) put(o.frames, a);
  }
  for (const ll::Cell& c : L.solid) {
    for (double v : c.lo) o.solid_cubes.push_back(static_cast<float>(v));
    o.solid_cubes.push_back(static_cast<float>(c.size));
    o.solid_frame.push_back(c.frame);
    o.solid_region.push_back(c.region);
    o.solid_why.push_back(kLayoutNoCellFits);
  }
  for (const ll::SteppedEdge& e : out.stepped_edges) {
    put(o.stepped_edges, e.at);
    o.stepped_edges.push_back(static_cast<float>(e.ends));
    o.stepped_region.push_back(e.region);
  }
  o.empty_regions.assign(out.empty_regions.begin(), out.empty_regions.end());
  o.cells = static_cast<int32_t>(L.cells.size());
  o.cell_info.reserve(5 * L.cells.size());
  o.cell_region.reserve(L.cells.size()); o.cell_wall.reserve(L.cells.size()); o.cell_frame.reserve(L.cells.size());
  o.cell_lo.reserve(3 * L.cells.size());
  for (const ll::Cell& c : L.cells) {
    o.cell_info.push_back(static_cast<float>(c.size));
    o.cell_info.push_back(static_cast<float>(c.own));
    o.cell_info.push_back(static_cast<float>(c.band));
    o.cell_info.push_back(c.finest ? 1.0f : 0.0f);
    o.cell_info.push_back(c.cut ? 1.0f : 0.0f);
    o.cell_region.push_back(c.region);   // ★ Install 3
    o.cell_wall.push_back(c.wall);
    o.cell_frame.push_back(c.frame);
    {   // its wall's width (the drawer's measured wall), 0 = the space no wall holds
      double w = 0;
      if (c.wall >= 0 && c.frame >= 0 && c.frame < static_cast<int>(L.walls.size())) {
        const auto& ws = L.walls[static_cast<size_t>(c.frame)].walls;
        if (c.wall < static_cast<int>(ws.size())) w = ws[static_cast<size_t>(c.wall)].width;
      }
      o.cell_wall_mm.push_back(static_cast<float>(w));
    }
    for (double v : c.lo) o.cell_lo.push_back(static_cast<float>(v));
  }
  o.solid_pieces = static_cast<int32_t>(L.solid.size());
  o.at_one_line = static_cast<int32_t>(out.struts.at_bead);
  o.at_widest = static_cast<int32_t>(out.struts.at_ceiling);
  o.stubs = static_cast<int32_t>(out.bars.stubs);
  o.joined = static_cast<int32_t>(out.bars.joined);
  o.dropped = static_cast<int32_t>(out.bars.dropped);
  o.pieces = static_cast<int32_t>(out.pieces.pieces);
  o.adrift = static_cast<int32_t>(out.pieces.adrift);
  o.floor_cell_mm = L.floor_cell_mm;
  o.min_strut_mm = L.min_strut_mm;
  o.open_look = L.open_look;
  o.touch = L.touch;
  o.read_again = out.read_again;
  o.no_stress = out.struts.no_stress;
  o.reference_mpa = out.struts.reference_mpa;
  o.highest_mpa = out.struts.highest_mpa;
  o.at_light = static_cast<int32_t>(out.struts.at_light);
  o.at_heavy = static_cast<int32_t>(out.struts.at_heavy);
  o.cells_by_stress = out.cells_by_stress;
  o.cells_no_stress = out.cells_no_stress;
  o.stress_reference_mpa = out.stress_reference_mpa;
  o.step_held_at = out.step_held_at;
  o.thin_solid = static_cast<int32_t>(out.thin_solid);
  o.ms_read = out.ms_read;
  o.ms_cells = out.ms_cells;
  o.ms_bars = out.ms_bars;
  // ★ SHEETS: the laid fields and their seams, in the contract's flat form (empty for a strut type)
  if (!out.sheets.empty()) {
    const ll::SheetsFlat f = ll::flatten_sheets(out.sheets, out.sheet_seams);
    o.sheet_region = f.region; o.sheet_frame = f.frame; o.sheet_kind = f.kind; o.sheet_axes = f.axes;
    o.sheet_anchor = f.anchor; o.sheet_cell_mm = f.cell_mm; o.sheet_n = f.n; o.sheet_lo = f.lo;
    o.sheet_wall_count = f.wall_count; o.sheet_wall_mm = f.wall_mm; o.sheet_wall_range = f.wall_range;
    o.sheet_seam_ab = f.seam_ab; o.sheet_seam_band_mm = f.seam_band_mm; o.sheet_seam_raise_mm = f.seam_raise_mm;
    o.sheet_seam_solid = f.seam_solid; o.sheet_seam_fell_back = f.seam_fell_back; o.sheet_seam_why = f.seam_why;
  }
}

void failed(BridgeError& err, const std::string& why) {
  err.ok = false;
  err.message = why;
}

// ★ notes29 (P8): a framed session (lattice_layout_open_framed) lays in the print frame. Its settings come in the part's
// own coordinates and go through the print file's door (core's turn_layout_inputs: the zones, the cut pieces, the bed's
// up); its stress is turned once, as set (set_demand, set_tensor). Unframed: settings_from as before, not a byte moved.
ll::Settings settings_in(const LayoutSession& s, const LatticeLayoutSettings& in) {
  ll::Settings ask = settings_from(in);
  if (s.frame.on) {
    std::shared_ptr<const ll::TensorField> none;
    ll::turn_layout_inputs(s.frame, ask, none);
  }
  return ask;
}
// What a lay gives, for the app: in the part's own coordinates (the session keeps its own, in the print frame, for "where"
// and the maps).
// ★ notes29 (H3, the cell lattices): a FLAT BRIDGE (bar_flags bit 16) is judged where it is laid, in the print frame (its +Z
// the print's up), as the file writes it (core's bar_is_bridge, the writer's own test) — never on the bars turned back,
// whose +Z is the part's own. The cells, wall maps and frames come back with their frames (turn_outcome_to_model).
void fill_shown(LatticeLayoutResult& o, const ll::Outcome& out, const topopt::PrintFrame& f) {
  if (!f.on) { fill(o, out); return; }
  ll::Outcome shown = out;
  ll::turn_outcome_to_model(f, shown);
  fill(o, shown);
  const std::vector<ll::Bar>& laid = out.bars.bars;
  for (std::size_t i = 0; i < laid.size() && i < o.bar_flags.size(); ++i)
    o.bar_flags[i] = static_cast<uint8_t>((o.bar_flags[i] & ~16u) | (ll::bar_is_bridge(laid[i]) ? 16u : 0u));
}
// The preview's drawing (its runs and the flat ends) in the part's own coordinates; its outcome stays as laid.
void turn_drawing_to_model(const topopt::PrintFrame& f, ll::OrganicPreview& pv) {
  if (!f.on) return;
  ll::OrganicPreview d;
  d.runs = std::move(pv.runs);
  d.flat_ends = std::move(pv.flat_ends);
  ll::turn_preview_to_model(f, d);
  pv.runs = std::move(d.runs);
  pv.flat_ends = std::move(d.flat_ends);
}
}  // namespace

namespace {
LatticeLayoutOpenInfo open_session(const std::string& path, double linear_deflection, const topopt::Vec3* up,
                                   BridgeError& err) {
  LatticeLayoutOpenInfo info;
  const std::string why = bridge_guard_run("lattice_layout_open", [&] {
    const auto t0 = std::chrono::steady_clock::now();
    topopt::PrintFrame frame;   // ★ notes29: off unless framed
    if (up) {
      std::string bad;
      if (!topopt::print_frame_for_up(*up, frame, &bad)) throw std::invalid_argument("lattice layout: " + bad);
    }
    topopt::StepTessellation tess;
    if (linear_deflection > 0.0) tess.linear_deflection = linear_deflection;
    topopt::StepModel model = topopt::import_part_file_resolved(path, tess);
    ll::open_in_print_frame(frame, model);   // ★ notes29: standing the way it prints, as the print file's job opens it
    auto s = std::make_shared<LayoutSession>();
    s->frame = frame;
    info.framed = frame.on;
    s->faces = model.face_count;
    s->session = std::make_unique<ll::Session>(std::move(model));
    s->session->growth_tap(&s->tap);   // ★ his 11-22: every Organic lay of this session hands its vines to the tap
    info.faces = s->faces;
    info.open_edges = static_cast<int32_t>(s->session->open_edges());
    std::lock_guard<std::mutex> lock(g_layout_mu);
    info.session = g_next_layout++;
    g_layouts[info.session] = s;
    info.ms_open = ms_since(t0);
  });
  if (!why.empty()) {
    info = LatticeLayoutOpenInfo{};
    failed(err, why);
  }
  return info;
}
}  // namespace

LatticeLayoutOpenInfo lattice_layout_open(const std::string& path, double linear_deflection, BridgeError& err) {
  return open_session(path, linear_deflection, nullptr, err);
}

LatticeLayoutOpenInfo lattice_layout_open_framed(const std::string& path, double linear_deflection, double up_x,
                                                 double up_y, double up_z, BridgeError& err) {
  const topopt::Vec3 up{up_x, up_y, up_z};
  return open_session(path, linear_deflection, &up, err);
}

LatticeLayoutResult lattice_layout(int64_t session, const LatticeLayoutSettings& settings, BridgeError& err) {
  LatticeLayoutResult o;
  const std::string why = bridge_guard_run("lattice_layout", [&] {
    auto s = layout_at(session);
    const uint64_t gen = s->cancel_gen.load();       // a cancel after this point, or one that came while it waited, wins
    ll::Settings ask = settings_in(*s, settings);   // a bad setting fails before the wait (★ notes29: framed, turned)
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;                    // Install 2: the session's stress result, the same pointer every lay
    s->stop = false;                                  // FIRST (LatticeReview's recipe), then the gen test: a cancel after this point stops it
    if (s->cancel_gen.load() != gen) { o.cancelled = true; return; }
    const auto t0 = std::chrono::steady_clock::now();
    auto out = std::make_unique<ll::Outcome>(s->session->lay(ask, 0, &s->stop));
    if (out->cancelled) {   // core gave up mid-way; what the session keeps is whole, but its domain may be the new one —
      s->solid_at.reset();  // so "where" says nothing until the next whole layout (never the old cells on a new domain)
      s->last.reset();
      o.cancelled = true;
      return;
    }
    // the old layout's SolidAt points into the old outcome: both go together
    s->solid_at.reset();
    s->last = std::move(out);
    if (s->cancel_gen.load() != gen) { o.cancelled = true; return; }
    fill_shown(o, *s->last, s->frame);   // ★ notes29: framed, turned back to the part's own coordinates
    o.ms_bridge = ms_since(t0) - (o.ms_read + o.ms_cells + o.ms_bars);
  });
  if (!why.empty()) {
    o = LatticeLayoutResult{};
    failed(err, why);
  }
  return o;
}

void lattice_layout_set_demand(int64_t session, const LatticeLayoutDemand& d, BridgeError& err) {
  const std::string why = bridge_guard_run("lattice_layout_set_demand", [&] {
    auto s = layout_at(session);
    std::shared_ptr<const ll::DemandField> field;
    if (!d.mpa.empty()) {
      auto f = std::make_shared<ll::DemandField>();
      f->origin = {d.origin_x, d.origin_y, d.origin_z};
      f->spacing = d.spacing;
      f->nx = d.nx; f->ny = d.ny; f->nz = d.nz;
      f->mpa = d.mpa;
      if (f->empty()) throw std::invalid_argument("lattice layout: the stress result is not nx*ny*nz values on a spacing above 0");
      field = std::move(f);
    }
    if (field && s->frame.on) {   // ★ notes29: turned once, through the print file's door (one pointer between lays, R17)
      ll::Settings door;
      door.stress.demand = std::move(field);
      std::shared_ptr<const ll::TensorField> none;
      ll::turn_layout_inputs(s->frame, door, none);
      field = std::move(door.stress.demand);
    }
    std::lock_guard<std::mutex> lock(s->mu);
    s->demand = std::move(field);
  });
  if (!why.empty()) failed(err, why);
}

void lattice_layout_set_tensor(int64_t session, const LatticeLayoutTensor& t, BridgeError& err) {
  const std::string why = bridge_guard_run("lattice_layout_set_tensor", [&] {
    auto s = layout_at(session);
    std::shared_ptr<const ll::TensorField> field;
    if (!t.voigt.empty()) {
      const std::size_t n = static_cast<std::size_t>(t.nx) * static_cast<std::size_t>(t.ny) * static_cast<std::size_t>(t.nz);
      if (t.nx <= 0 || t.ny <= 0 || t.nz <= 0 || !(t.spacing > 0.0) || t.voigt.size() != 6 * n)
        throw std::invalid_argument("lattice layout: the stress tensor is not 6 x nx*ny*nz values on a spacing above 0");
      auto f = std::make_shared<ll::TensorField>();
      f->origin = {t.origin_x, t.origin_y, t.origin_z};
      f->spacing = t.spacing;
      f->nx = t.nx; f->ny = t.ny; f->nz = t.nz;
      f->voigt.assign(t.voigt.begin(), t.voigt.end());
      field = std::move(f);
    }
    if (s->frame.on) {   // ★ notes29: kept as set (the print file's), and turned once through its door for the lays
      std::shared_ptr<const ll::TensorField> turned = field;
      if (turned) {
        ll::Settings door;
        ll::turn_layout_inputs(s->frame, door, turned);
      }
      std::lock_guard<std::mutex> lock(s->mu);
      s->model_tensor = std::move(field);
      s->real_tensor = turned;
      s->tensor = std::move(turned);
      return;
    }
    std::lock_guard<std::mutex> lock(s->mu);
    s->real_tensor = field;
    s->tensor = std::move(field);
  });
  if (!why.empty()) failed(err, why);
}

bool lattice_layout_write_tensor(int64_t session, const std::string& path, BridgeError& err) {
  bool ok = false;
  const std::string why = bridge_guard_run("lattice_layout_write_tensor", [&] {
    auto s = layout_at(session);
    std::shared_ptr<const ll::TensorField> field;
    {
      std::lock_guard<std::mutex> lock(s->mu);
      field = s->tensor;
      // ★ notes29: framed, the print file is sent the part's own (its job turns it through the same door): the tensor as
      // set; a filled one (E5, made in the print frame) turned back (along the six axes an exact permutation)
      if (s->frame.on && field) {
        if (field == s->real_tensor && s->model_tensor) {
          field = s->model_tensor;
        } else if (!field->empty()) {
          auto back = std::make_shared<ll::TensorField>(*field);
          const int n[3] = {field->nx, field->ny, field->nz};
          int no[3];
          back->voigt = topopt::turn_grid_values(s->frame, false, n, field->origin, field->spacing, field->voigt, 6, no,
                                                 back->origin);
          back->nx = no[0];
          back->ny = no[1];
          back->nz = no[2];
          field = std::move(back);
        }
      }
    }
    if (!field || field->empty()) throw std::invalid_argument("the session holds no stress to write");
    if (!ll::write_tensor_file(path, *field)) throw std::runtime_error("the stress file could not be written");
    ok = true;
  });
  if (!why.empty()) failed(err, why);
  return ok;
}

namespace {
std::vector<LatticeLayoutRefusal> refusals_out(const std::vector<ll::OrganicRefusal>& in) {
  std::vector<LatticeLayoutRefusal> out;
  out.reserve(in.size());
  for (const ll::OrganicRefusal& r : in) {
    LatticeLayoutRefusal o;
    o.group = r.group; o.setting = r.setting; o.code = r.code; o.text = r.text; o.given = r.given;
    o.has_min = r.has_min; o.has_max = r.has_max; o.allowed_min = r.allowed_min; o.allowed_max = r.allowed_max;
    out.push_back(std::move(o));
  }
  return out;
}
}  // namespace

static ll::OrganicAsk organic_from(const LatticeLayoutOrganic& o) {
  ll::OrganicAsk a;
  a.mode = o.mode == 1 ? ll::OrganicMode::Grown : ll::OrganicMode::Traced;
  a.spacing_mm = o.spacing_mm; a.spacing_min_mm = o.spacing_min_mm; a.spacing_max_mm = o.spacing_max_mm;
  a.spacing_exponent = o.spacing_exponent;
  a.width_mm = o.width_mm; a.width_heavy_mm = o.width_heavy_mm;
  a.reference_mpa = o.reference_mpa; a.percentile = o.percentile;
  a.shape_fit = o.shape_fit; a.member_cap = o.member_cap; a.shape_reach = o.shape_reach;
  a.build_dir = {o.build_x, o.build_y, o.build_z};
  a.walls_out = o.walls_out; a.ties = o.ties; a.tie_swirl = o.tie_swirl; a.foot_gap = o.foot_gap;
  a.stress_goal = o.stress_goal; a.void_ratio = o.void_ratio; a.reseed_rounds = o.reseed_rounds;
  a.wall_connect = o.wall_connect; a.wall_gap = o.wall_gap; a.wall_gap_heavy = o.wall_gap_heavy;
  a.wall_cross = o.wall_cross; a.cross_gap = o.cross_gap; a.cross_gap_heavy = o.cross_gap_heavy;
  a.cross_climb_max_deg = o.cross_climb_max_deg;
  a.top_run = o.top_run; a.root_run = o.root_run; a.run_max = o.run_max; a.run_gap = o.run_gap;
  a.run_follow = o.run_follow; a.run_pull = o.run_pull; a.run_seek = o.run_seek; a.run_min = o.run_min;
  a.root_gap = o.root_gap;
  a.auto_by_stress = o.auto_by_stress; a.prune = o.prune; a.bed_floor_mm = o.bed_floor_mm;
  a.hold_parts = o.hold_parts; a.part_reach_mm = o.part_reach_mm; a.part_support_mm = o.part_support_mm;
  a.part_to_floor = o.part_to_floor;
  a.link_width = o.link_width; a.unbraced_max = o.unbraced_max;
  a.tie_level = o.tie_level; a.tie_gap = o.tie_gap; a.tie_gap_heavy = o.tie_gap_heavy;
  a.follow_stress = o.follow_stress;
  a.layer_mm = o.layer_mm;   // sheet H2
  a.seed = o.seed;
  // ★ cut 2 (organic-cut2-handover.md, a)
  a.gap_lines = o.gap_lines;
  a.face_relief_mm = o.face_relief_mm;
  a.relief_exclude_faces.assign(o.relief_exclude_faces.begin(), o.relief_exclude_faces.end());
  a.strand_keep = o.strand_keep;
  a.wall_bare_mm = o.wall_bare_mm;
  a.wall_reach = o.wall_reach;
  a.sweep.on = o.sweep;
  return a;
}

LatticeLayoutOrganicResult lattice_layout_organic(int64_t session, const LatticeLayoutSettings& settings,
                                                  const LatticeLayoutOrganic& organic, BridgeError& err) {
  LatticeLayoutOrganicResult o;
  const std::string why = bridge_guard_run("lattice_layout_organic", [&] {
    auto s = layout_at(session);
    const uint64_t gen = s->cancel_gen.load();
    ll::Settings ask = settings_in(*s, settings);   // ★ notes29: framed, turned
    ll::OrganicAsk oa = organic_from(organic);
    ll::turn_organic_asks(s->frame, &oa, nullptr);   // ★ notes29: framed, it grows along the print's up (+Z there)
    ll::OrganicPreviewAsk pa;
    pa.quality = organic.quality == 1 ? ll::PreviewQuality::Draft : ll::PreviewQuality::Exact;
    pa.tolerance_mm = organic.tolerance_mm;
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;
    s->stop = false;
    if (s->cancel_gen.load() != gen) { o.cancelled = true; return; }
    if (!s->tensor) throw std::invalid_argument("Organic needs the stress check first (no stress result to follow)");
    const auto t0 = std::chrono::steady_clock::now();
    ll::OrganicPreview pv;
    try {
      pv = ll::lay_organic_preview(*s->session, ask, *s->tensor, oa, pa, 0, &s->stop);
    } catch (...) {   // sheet H17: a refused lay leaves no old outcome to be read against the new domain
      s->solid_at.reset();
      s->last.reset();
      throw;
    }
    if (pv.outcome.cancelled) { s->solid_at.reset(); s->last.reset(); o.cancelled = true; return; }
    s->solid_at.reset();
    turn_drawing_to_model(s->frame, pv);   // ★ notes29: the runs and flat ends in the part's own coordinates
    o.runs = ll::pack_weave_runs(pv.runs, 2);   // ★ cut 2: version 2 (sections, swept, proud, the file's ring)
    o.relief_flushed = static_cast<int64_t>(pv.relief_flushed);
    for (const auto& p : pv.flat_ends) { o.flat_ends.push_back(p.x); o.flat_ends.push_back(p.y); o.flat_ends.push_back(p.z); }
    o.quality = pv.quality == ll::PreviewQuality::Draft ? 1 : 0;
    o.strands = static_cast<int64_t>(pv.outcome.strands);
    o.net_struts = static_cast<int64_t>(pv.outcome.net_struts);
    o.spacing_smallest_mm = pv.outcome.spacing_smallest_mm;
    o.spacing_largest_mm = pv.outcome.spacing_largest_mm;
    o.spacing_mean_mm = pv.outcome.spacing_mean_mm;
    o.ms_trace = pv.outcome.ms_trace;
    s->last = std::make_unique<ll::Outcome>(std::move(pv.outcome));
    if (s->cancel_gen.load() != gen) { o.cancelled = true; return; }
    fill_shown(o.layout, *s->last, s->frame);   // ★ notes29
    o.ms = ms_since(t0);
  });
  if (!why.empty()) {
    o = LatticeLayoutOrganicResult{};
    failed(err, why);
  }
  return o;
}

namespace {
std::vector<ll::OrganicGroup> groups_from(const LatticeLayoutOrganicGroups& in) {
  if (in.asks.empty()) throw std::invalid_argument("lattice layout organic: no group");
  if (in.group_region_counts.size() != in.asks.size())
    throw std::invalid_argument("lattice layout organic: group_region_counts is not one per group");
  std::vector<ll::OrganicGroup> out;
  std::size_t at = 0;
  for (std::size_t g = 0; g < in.asks.size(); ++g) {
    ll::OrganicGroup og;
    og.ask = organic_from(in.asks[g]);
    const int32_t n = in.group_region_counts[g];
    if (n < 0 || at + static_cast<std::size_t>(n) > in.group_regions.size())
      throw std::invalid_argument("lattice layout organic: the group region counts run past the regions listed");
    for (int32_t k = 0; k < n; ++k) og.regions.push_back(in.group_regions[at++]);
    out.push_back(std::move(og));
  }
  if (at != in.group_regions.size()) throw std::invalid_argument("lattice layout organic: regions listed that no group claims");
  return out;
}
}  // namespace

LatticeLayoutOrganicResult lattice_layout_organic_groups(int64_t session, const LatticeLayoutSettings& settings,
                                                         const LatticeLayoutOrganicGroups& groups, BridgeError& err) {
  LatticeLayoutOrganicResult o;
  const std::string why = bridge_guard_run("lattice_layout_organic_groups", [&] {
    auto s = layout_at(session);
    const uint64_t gen = s->cancel_gen.load();
    ll::Settings ask = settings_in(*s, settings);   // ★ notes29: framed, turned
    std::vector<ll::OrganicGroup> gs = groups_from(groups);
    ll::turn_organic_asks(s->frame, nullptr, &gs);   // ★ notes29: framed, they grow along the print's up
    ll::OrganicPreviewAsk pa;
    pa.quality = groups.asks[0].quality == 1 ? ll::PreviewQuality::Draft : ll::PreviewQuality::Exact;
    pa.tolerance_mm = groups.asks[0].tolerance_mm;
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;
    s->stop = false;
    if (s->cancel_gen.load() != gen) { o.cancelled = true; return; }
    if (!s->tensor) throw std::invalid_argument("Organic needs the stress check first (no stress result to follow)");
    const auto t0 = std::chrono::steady_clock::now();
    ll::OrganicPreview pv = ll::lay_organic_preview(*s->session, ask, *s->tensor, gs, pa, 0, &s->stop);
    if (pv.outcome.cancelled) { s->solid_at.reset(); s->last.reset(); o.cancelled = true; return; }
    if (!pv.outcome.refused.empty()) {   // E1: nothing laid, the domain untouched
      o.refused = refusals_out(pv.outcome.refused);
      return;
    }
    s->solid_at.reset();
    turn_drawing_to_model(s->frame, pv);   // ★ notes29: the runs and flat ends in the part's own coordinates
    o.runs = ll::pack_weave_runs(pv.runs, 2);   // ★ cut 2: version 2 (sections, swept, proud, the file's ring)
    o.relief_flushed = static_cast<int64_t>(pv.relief_flushed);
    for (const auto& p : pv.flat_ends) { o.flat_ends.push_back(p.x); o.flat_ends.push_back(p.y); o.flat_ends.push_back(p.z); }
    o.quality = pv.quality == ll::PreviewQuality::Draft ? 1 : 0;
    o.strands = static_cast<int64_t>(pv.outcome.strands);
    o.net_struts = static_cast<int64_t>(pv.outcome.net_struts);
    o.spacing_smallest_mm = pv.outcome.spacing_smallest_mm;
    o.spacing_largest_mm = pv.outcome.spacing_largest_mm;
    o.spacing_mean_mm = pv.outcome.spacing_mean_mm;
    o.ms_trace = pv.outcome.ms_trace;
    o.notes = pv.outcome.notes;
    o.cross_group_touches = static_cast<int64_t>(pv.outcome.cross_group_touches);
    s->last = std::make_unique<ll::Outcome>(std::move(pv.outcome));
    if (s->cancel_gen.load() != gen) { o.cancelled = true; return; }
    fill_shown(o.layout, *s->last, s->frame);   // ★ notes29
    o.ms = ms_since(t0);
  });
  if (!why.empty()) {
    o = LatticeLayoutOrganicResult{};
    failed(err, why);
  }
  return o;
}

std::vector<LatticeLayoutRefusal> lattice_layout_organic_validate(int64_t session, const LatticeLayoutSettings& settings,
                                                                 const LatticeLayoutOrganicGroups& groups, BridgeError& err) {
  std::vector<LatticeLayoutRefusal> out;
  const std::string why = bridge_guard_run("lattice_layout_organic_validate", [&] {
    auto s = layout_at(session);
    const ll::Settings st = settings_in(*s, settings);   // ★ notes29: as the lay asks it
    std::vector<ll::OrganicGroup> gs = groups_from(groups);
    ll::turn_organic_asks(s->frame, nullptr, &gs);
    std::lock_guard<std::mutex> lock(s->mu);
    out = refusals_out(ll::validate_organic_groups(st, gs, s->tensor ? s->tensor.get() : nullptr));
  });
  if (!why.empty()) {
    out.clear();
    failed(err, why);
  }
  return out;
}

LatticeLayoutSweep lattice_layout_sweep_limits_for(int64_t session, const LatticeLayoutSettings& settings,
                                                   const LatticeLayoutIds& regions, double line_mm, BridgeError& err) {
  LatticeLayoutSweep o;
  const std::string why = bridge_guard_run("lattice_layout_sweep_limits_for", [&] {
    auto s = layout_at(session);
    ll::Settings ask = settings_in(*s, settings);   // ★ notes29: the domain the lay keeps
    const std::vector<int> ids(regions.ids.begin(), regions.ids.end());
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;
    const ll::SweepLimitsUnion u = s->session->sweep_limits_for(ask, ids, line_mm);
    o.region.push_back(0);
    o.measured.push_back(u.measured ? 1 : 0);
    o.d_mm.push_back(0.0);
    o.strut_lower_mm.push_back(u.strut_lower_mm); o.strut_upper_mm.push_back(u.strut_upper_mm);
    o.strut_auto_mm.push_back(u.strut_auto_mm);
    o.cell_lower_mm.push_back(u.cell_lower_mm); o.cell_upper_mm.push_back(u.cell_upper_mm);
    o.cell_auto_mm.push_back(u.cell_auto_mm);
    o.gap_mm.push_back(u.gap_mm);
  });
  if (!why.empty()) {
    o = LatticeLayoutSweep{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutSynthetic lattice_layout_synthetic(int64_t session, const LatticeLayoutSettings& settings,
                                                const LatticeLayoutOrganicGroups& groups, const LatticeLayoutIds& w,
                                                bool from_empty, BridgeError& err) {
  LatticeLayoutSynthetic o;
  const std::string why = bridge_guard_run("lattice_layout_synthetic", [&] {
    auto s = layout_at(session);
    const std::vector<int32_t>& wall_regions = w.ids;
    const std::vector<int32_t>& wall_foci = w.foci;
    if (wall_regions.size() != wall_foci.size())
      throw std::invalid_argument("lattice layout synthetic: wall_foci is not one per wall");
    ll::Settings ask = settings_in(*s, settings);   // ★ notes29: framed, the stress is filled in the print frame
    std::vector<ll::OrganicGroup> gs = groups_from(groups);
    ll::turn_organic_asks(s->frame, nullptr, &gs);
    std::vector<ll::SyntheticWall> walls;
    for (std::size_t i = 0; i < wall_regions.size(); ++i) walls.push_back({wall_regions[i], wall_foci[i]});
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;
    if (!from_empty && walls.empty()) { s->tensor = s->real_tensor; return; }   // the real stress back
    if (!from_empty && !s->real_tensor) throw std::invalid_argument("Organic needs the stress check first (no stress result to follow)");
    const ll::TensorField empty;
    ll::SyntheticStress r = ll::organic_synthetic_stress(*s->session, ask, from_empty ? empty : *s->real_tensor, walls, gs);
    if (!r.refused.empty()) { o.refused = refusals_out(r.refused); return; }
    for (const ll::SyntheticRegionReport& g : r.regions) {
      o.region.push_back(g.region);
      o.without_stress.push_back(g.without_stress ? 1 : 0);
      o.foci.push_back(g.foci);
      o.filled.push_back(static_cast<int64_t>(g.filled));
    }
    // ★ Organic cut 2 (the export): the print file's job reads this stress from core's TOTENSOR file, which holds each value
    // as a float32; the real stress arrives as float32 already, the synthetic is filled in double. The preview lays on the
    // file's own numbers (his rule: the drawing follows the print file), or a lattice this sensitive differs by a few bars
    // (measured on the sample cube: 4,647 laid, 4,645 in the file).
    for (double& v : r.field.voigt) v = static_cast<double>(static_cast<float>(v));
    s->tensor = std::make_shared<const ll::TensorField>(std::move(r.field));
    s->solid_at.reset();
  });
  if (!why.empty()) {
    o = LatticeLayoutSynthetic{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutSweep lattice_layout_sweep_limits(int64_t session, const LatticeLayoutSettings& settings, double line_mm,
                                               BridgeError& err) {
  LatticeLayoutSweep o;
  const std::string why = bridge_guard_run("lattice_layout_sweep_limits", [&] {
    auto s = layout_at(session);
    ll::Settings ask = settings_in(*s, settings);   // ★ notes29
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;
    for (const ll::SweepLimits& l : s->session->sweep_limits(ask, line_mm)) {
      o.region.push_back(static_cast<int32_t>(l.region));
      o.measured.push_back(l.measured ? 1 : 0);
      o.d_mm.push_back(l.d_mm);
      o.strut_lower_mm.push_back(l.strut_lower_mm); o.strut_upper_mm.push_back(l.strut_upper_mm);
      o.strut_auto_mm.push_back(l.strut_auto_mm);
      o.cell_lower_mm.push_back(l.cell_lower_mm); o.cell_upper_mm.push_back(l.cell_upper_mm);
      o.cell_auto_mm.push_back(l.cell_auto_mm);
      o.gap_mm.push_back(l.gap_mm);
    }
  });
  if (!why.empty()) {
    o = LatticeLayoutSweep{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutPlaces lattice_layout_places(int64_t session, const LatticeLayoutSettings& settings, BridgeError& err) {
  LatticeLayoutPlaces o;
  const std::string why = bridge_guard_run("lattice_layout_places", [&] {
    auto s = layout_at(session);
    const ll::Settings ask = settings_in(*s, settings);   // ★ notes29: the last lay's, as it was laid
    std::lock_guard<std::mutex> lock(s->mu);
    if (!s->last) return;   // before the first whole layout, or after a cancelled one: none
    const auto t0 = std::chrono::steady_clock::now();
    for (const ll::Place& p : s->session->places(ask)) {
      o.region.push_back(static_cast<int32_t>(p.region));
      o.face_counts.push_back(static_cast<int32_t>(p.faces.size()));
      for (int f : p.faces) o.faces.push_back(static_cast<int32_t>(f));
      const topopt::Vec3 at = s->frame.point_to_model(p.point), n = s->frame.dir_to_model(p.normal);   // ★ notes29 (off: as is)
      o.point.insert(o.point.end(), {static_cast<float>(at.x), static_cast<float>(at.y), static_cast<float>(at.z)});
      o.normal.insert(o.normal.end(), {static_cast<float>(n.x), static_cast<float>(n.y), static_cast<float>(n.z)});
      o.area_mm2.push_back(p.area_mm2);
      o.solid_now.push_back(p.now == "solid" ? 1 : 0);
    }
    o.ms = ms_since(t0);
  });
  if (!why.empty()) {
    o = LatticeLayoutPlaces{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutWhere lattice_layout_where(int64_t session, const LatticeLayoutPoints& points, BridgeError& err) {
  LatticeLayoutWhere o;
  const std::vector<float>& xyz = points.xyz;
  const std::string why = bridge_guard_run("lattice_layout_where", [&] {
    if (xyz.size() % 3 != 0) throw std::invalid_argument("lattice layout where: xyz is not 3 per point");
    auto s = layout_at(session);
    std::lock_guard<std::mutex> lock(s->mu);
    const ll::Domain* domain = s->session->domain();
    if (!domain || !s->last) return;                    // before the first layout: nothing to say
    if (!s->solid_at) s->solid_at = std::make_unique<ll::SolidAt>(s->last->layout);   // once per layout (LatticeReview)
    const ll::Domain::Probe probe = domain->probe();    // one probe for the whole batch, never one per point
    const std::size_t n = xyz.size() / 3;
    o.why.reserve(n);
    o.id.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
      const topopt::Vec3 p = s->frame.point_to_print({xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]});   // ★ notes29 (off: as is)
      const ll::Where w = probe.where(p);
      uint8_t why_byte = static_cast<uint8_t>(w.why);
      // D14: lattice space that no cell of the last layout holds is solid
      if (w.why == ll::Why::Lattice && (*s->solid_at)(probe, p, w)) why_byte = kLayoutNoCellFits;
      o.why.push_back(why_byte);
      o.id.push_back(w.id);
    }
  });
  if (!why.empty()) {
    o = LatticeLayoutWhere{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutGrid lattice_layout_grid(int64_t session, float origin_x, float origin_y, float origin_z, float voxel_mm,
                                      int32_t nx, int32_t ny, int32_t nz, BridgeError& err) {
  LatticeLayoutGrid o;
  const std::string why = bridge_guard_run("lattice_layout_grid", [&] {
    if (nx <= 0 || ny <= 0 || nz <= 0 || !(voxel_mm > 0.0f)) throw std::invalid_argument("lattice layout grid: an empty box");
    if (static_cast<int64_t>(nx) * ny * nz > 8'000'000) throw std::invalid_argument("lattice layout grid: too many voxels");
    const auto t0 = std::chrono::steady_clock::now();
    auto s = layout_at(session);
    std::lock_guard<std::mutex> lock(s->mu);
    const ll::Domain* domain = s->session->domain();
    if (!domain || !s->last) return;
    if (!s->solid_at) s->solid_at = std::make_unique<ll::SolidAt>(s->last->layout);
    const ll::SolidAt& solid_at = *s->solid_at;
    const std::size_t n = static_cast<std::size_t>(nx) * ny * nz;
    std::vector<uint8_t> cls(n, 0);   // 0 outside, 1 solid, 2 open
    std::atomic<int32_t> next{0};
    std::array<int64_t, 5> nocell_total{};
    std::mutex nocell_mu;
    auto work = [&] {
      const ll::Domain::Probe probe = domain->probe();   // one per thread
      std::array<int64_t, 5> local{};
      for (int32_t z = next++; z < nz; z = next++) {
        if (s->stop.load()) return;
        for (int32_t y = 0; y < ny; ++y) {
          for (int32_t x = 0; x < nx; ++x) {
            const topopt::Vec3 p = s->frame.point_to_print(
                {origin_x + voxel_mm * x, origin_y + voxel_mm * y, origin_z + voxel_mm * z});   // ★ notes29 (off: as is)
            const ll::Where w = probe.where(p);
            uint8_t c = 1;
            if (w.why == ll::Why::Outside) c = 0;
            else if (w.why == ll::Why::Lattice) {
              c = solid_at(probe, p, w) ? 3 : 2;   // 3: asked for, no cell holds it (D14: solid)
              if (c == 3) ++local[std::min<std::size_t>(4, static_cast<std::size_t>(solid_at.why(probe, p).why))];
            }
            cls[(static_cast<std::size_t>(z) * ny + y) * nx + x] = c;
          }
        }
      }
      std::lock_guard<std::mutex> g(nocell_mu);
      for (std::size_t k = 0; k < 5; ++k) nocell_total[k] += local[k];
    };
    const unsigned threads = std::max(1u, std::thread::hardware_concurrency());
    std::vector<std::thread> pool;
    auto counted = [&] {
      work();
    };
    for (unsigned i = 1; i < threads; ++i) pool.emplace_back(counted);
    counted();
    for (auto& t : pool) t.join();
    if (s->stop.load()) return;
    o.rg.assign(2 * n, static_cast<int8_t>(-127));
    auto at = [&](int32_t x, int32_t y, int32_t z) -> uint8_t {
      if (x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz) return 0;
      return cls[(static_cast<std::size_t>(z) * ny + y) * nx + x];
    };
    for (int32_t z = 0; z < nz; ++z)
      for (int32_t y = 0; y < ny; ++y)
        for (int32_t x = 0; x < nx; ++x) {
          const std::size_t i = (static_cast<std::size_t>(z) * ny + y) * nx + x;
          const uint8_t c = cls[i];
          if (c >= 2) ++o.asked;
          if (c == 3) ++o.unheld;
          bool open = c == 2;
          if (c == 0)   // an outside voxel next to open lattice reads open: the surface at the opening is cut
            open = at(x - 1, y, z) == 2 || at(x + 1, y, z) == 2 || at(x, y - 1, z) == 2 || at(x, y + 1, z) == 2 ||
                   at(x, y, z - 1) == 2 || at(x, y, z + 1) == 2;
          o.rg[2 * i] = open ? 127 : -127;
          o.rg[2 * i + 1] = c != 0 ? 127 : -127;
        }
    o.nocell.assign(nocell_total.begin(), nocell_total.end());
    o.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  });
  if (!why.empty()) {
    o = LatticeLayoutGrid{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutGridAhead lattice_layout_grid_ahead(int64_t session, const LatticeLayoutSettings& settings, float origin_x,
                                                 float origin_y, float origin_z, float voxel_mm, int32_t nx, int32_t ny,
                                                 int32_t nz, BridgeError& err) {
  LatticeLayoutGridAhead o;
  const std::string why = bridge_guard_run("lattice_layout_grid_ahead", [&] {
    if (nx <= 0 || ny <= 0 || nz <= 0 || !(voxel_mm > 0.0f)) throw std::invalid_argument("lattice layout grid: an empty box");
    if (static_cast<int64_t>(nx) * ny * nz > 8'000'000) throw std::invalid_argument("lattice layout grid: too many voxels");
    const auto t0 = std::chrono::steady_clock::now();
    auto s = layout_at(session);
    ll::Settings ask = settings_in(*s, settings);   // ★ notes29: the domain the lay keeps
    std::lock_guard<std::mutex> lock(s->mu);
    ask.stress.demand = s->demand;   // as the lay asks it (the "where" never reads it)
    s->session->prepare_domain(ask);
    const ll::Domain* domain = s->session->domain();
    if (!domain) return;
    const std::size_t n = static_cast<std::size_t>(nx) * ny * nz;
    std::vector<uint8_t> cls(n, 0);   // 0 outside, 1 solid, 2 open
    std::atomic<int32_t> next{0};
    std::atomic<bool> needs_cells{false};
    auto work = [&] {
      const ll::Domain::Probe probe = domain->probe();   // one per thread
      for (int32_t z = next++; z < nz; z = next++) {
        if (needs_cells.load(std::memory_order_relaxed)) return;
        for (int32_t y = 0; y < ny; ++y)
          for (int32_t x = 0; x < nx; ++x) {
            const topopt::Vec3 p = s->frame.point_to_print(
                {origin_x + voxel_mm * x, origin_y + voxel_mm * y, origin_z + voxel_mm * z});   // ★ notes29 (off: as is)
            const ll::Where w = probe.where(p);
            uint8_t c = 1;
            if (w.why == ll::Why::Outside) {
              c = 0;
            } else if (w.why == ll::Why::Lattice) {
              // SolidAt (bars.cpp, O1): a woven region's lattice is open; any other needs the cells laid
              const ll::Region* r = nullptr;
              for (const ll::Region& g : domain->spec().regions)
                if (g.id == w.id) { r = &g; break; }
              if (!r || !r->weave) { needs_cells.store(true); return; }
              c = 2;
            }
            cls[(static_cast<std::size_t>(z) * ny + y) * nx + x] = c;
          }
      }
    };
    const unsigned threads = std::max(1u, std::thread::hardware_concurrency());
    std::vector<std::thread> pool;
    for (unsigned i = 1; i < threads; ++i) pool.emplace_back(work);
    work();
    for (auto& t : pool) t.join();
    if (needs_cells.load()) return;
    LatticeLayoutGrid& g = o.grid;
    g.rg.assign(2 * n, static_cast<int8_t>(-127));
    auto at = [&](int32_t x, int32_t y, int32_t z) -> uint8_t {
      if (x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz) return 0;
      return cls[(static_cast<std::size_t>(z) * ny + y) * nx + x];
    };
    for (int32_t z = 0; z < nz; ++z)   // (lattice_layout_grid's own encoding)
      for (int32_t y = 0; y < ny; ++y)
        for (int32_t x = 0; x < nx; ++x) {
          const std::size_t i = (static_cast<std::size_t>(z) * ny + y) * nx + x;
          const uint8_t c = cls[i];
          if (c >= 2) ++g.asked;
          bool open = c == 2;
          if (c == 0)
            open = at(x - 1, y, z) == 2 || at(x + 1, y, z) == 2 || at(x, y - 1, z) == 2 || at(x, y + 1, z) == 2 ||
                   at(x, y, z - 1) == 2 || at(x, y, z + 1) == 2;
          g.rg[2 * i] = open ? 127 : -127;
          g.rg[2 * i + 1] = c != 0 ? 127 : -127;
        }
    g.nocell.assign(5, 0);
    g.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    o.supported = true;
  });
  if (!why.empty()) {
    o = LatticeLayoutGridAhead{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutGrowth lattice_layout_growth_read(int64_t session, int64_t from, int64_t most, BridgeError& err) {
  LatticeLayoutGrowth o;
  const std::string why = bridge_guard_run("lattice_layout_growth_read", [&] {
    auto s = layout_at(session);   // never s->mu: the lay holds it while it runs (the tap has its own lock)
    ll::GrowthTap::Read r = s->tap.read(static_cast<std::size_t>(std::max<int64_t>(0, from)),
                                        static_cast<std::size_t>(std::max<int64_t>(0, most)));
    ll::turn_growth_to_model(s->frame, r);   // ★ notes29: framed, the pieces in the part's own coordinates (off: as is)
    o.lay = r.lay;
    o.phase = static_cast<int32_t>(r.phase);
    o.next = static_cast<int64_t>(r.next);
    o.xyz = std::move(r.xyz);
    o.region.assign(r.region.begin(), r.region.end());
  });
  if (!why.empty()) {
    o = LatticeLayoutGrowth{};
    failed(err, why);
  }
  return o;
}

LatticeLayoutTypeFacts lattice_layout_type_facts(const std::string& topology) {
  LatticeLayoutTypeFacts f;
  const std::string why = bridge_guard_run("lattice_layout_type_facts", [&] {
    const topopt::LatticeTopology topo = topopt::lattice_topology_from_id(topology);
    if (ll::sheet_kind_of(topo)) {
      // ★ SHEETS (notes28 sheets SPEC 5): the engine lays a sheet on its cells, with one field per region (no struts)
      const topopt::LatticeWidthBounds b = topopt::lattice_width_bounds(topo);
      f.open_look = b.open_look;
      f.touch = b.touch;
      f.family = ll::lattice_family(topo);
      f.structural_floor_cells = ll::sheet_structural_floor_cells(topo);
      f.floor_cell_mm = ll::sheet_floor_cell_mm(topo, 2.0 * 0.45);   // two lines of a 0.45 mm line (the contract)
      f.auto_cell_cap_mm = ll::auto_cell_cap_mm(topo);
      f.lays = true;
      return;
    }
    // The engine's own two questions, in the order a lay asks them (cells.cpp: the width bounds; bars.cpp: the cell).
    const topopt::LatticeWidthBounds b = topopt::lattice_width_bounds(topo);
    if (!topopt::lattice_has_strut_cell(topo))
      throw std::invalid_argument("\"" + topology + "\" has no canonical cell in core yet");
    const topopt::StrutCell& cell = topopt::lattice_strut_cell(topo);
    f.open_look = b.open_look;
    f.touch = b.touch;
    f.s = cell.S;
    f.struts.reserve(6 * cell.struts.size());
    for (const topopt::StrutCellStrut& st : cell.struts)
      for (int v : {st.a.x, st.a.y, st.a.z, st.b.x, st.b.y, st.b.z}) f.struts.push_back(v);
    f.nodes.reserve(3 * cell.nodes.size());
    for (const topopt::StrutCellPoint& n : cell.nodes)
      for (int v : {n.x, n.y, n.z}) f.nodes.push_back(v);
    f.family = ll::lattice_family(topo);
    f.auto_cell_cap_mm = ll::auto_cell_cap_mm(topo);
    f.lays = true;
  });
  if (!why.empty()) {
    f = LatticeLayoutTypeFacts{};
    f.why = why;
  }
  // ★ notes28 (builder D's types.cpp, 362 11-24: "mirror both through the bridge instead of re-deriving them in Swift"):
  // core's own Structural verdicts for the type, asked apart so a type the engine does not lay still says them.
  bridge_guard_run("lattice_layout_type_facts structural", [&] {
    const topopt::LatticeTopology topo = topopt::lattice_topology_from_id(topology);
    f.structural_refusal = ll::structural_refusal(topo);
    f.structural_note = ll::structural_note(topo);
  });
  return f;
}

// ★ SHEETS: the wall law sampled for the GPU and the Swift field (LatticeLayoutBridge.hpp)
std::vector<double> lattice_layout_sheet_param_table(const std::string& topology, int32_t n, double max_share) {
  std::vector<double> out;
  const std::string why = bridge_guard_run("lattice_layout_sheet_param_table", [&] {
    const topopt::LatticeTopology topo = topopt::lattice_topology_from_id(topology);
    if (!ll::sheet_kind_of(topo) || n < 1 || !(max_share > 0.0)) return;
    out.reserve(static_cast<size_t>(n) + 1);
    out.push_back(0.0);   // no wall, no parameter (the law runs through the origin below its first row)
    for (int32_t i = 1; i <= n; ++i) {
      const double share = max_share * static_cast<double>(i) / static_cast<double>(n);
      out.push_back(topopt::lattice_sheet_wall_param_mm(topo, share, 1.0));   // over a 1 mm cell: the parameter's share
    }
  });
  if (!why.empty()) out.clear();
  return out;
}

namespace {
ll::SheetField sheet_from_probe(const LatticeLayoutSheetProbe& p) {
  if (p.axes.size() != 12 || p.anchor.size() != 3 || p.n.size() != 3 || p.lo.size() != 3)
    throw std::invalid_argument("sheet probe: a field needs 12 axes, 3 anchor, 3 n and 3 lo numbers");
  ll::SheetField s;
  s.kind = p.kind == 1 ? topopt::TpmsKind::SchwarzD : topopt::TpmsKind::Gyroid;
  s.axes.origin = {p.axes[0], p.axes[1], p.axes[2]};
  for (int k = 0; k < 3; ++k) s.axes.ax[k] = {p.axes[3 + 3 * k], p.axes[4 + 3 * k], p.axes[5 + 3 * k]};
  for (int k = 0; k < 3; ++k) {
    s.anchor[k] = p.anchor[k];
    s.n[k] = p.n[k];
    s.lo[k] = p.lo[k];
  }
  s.cell_mm = p.cell_mm;
  const size_t want = static_cast<size_t>(std::max(1, s.n[0])) * static_cast<size_t>(std::max(1, s.n[1])) *
                      static_cast<size_t>(std::max(1, s.n[2]));
  if (p.wall_mm.size() != want) throw std::invalid_argument("sheet probe: wall_mm is not n0 * n1 * n2 values");
  s.wall_mm.assign(p.wall_mm.begin(), p.wall_mm.end());
  return s;
}
}  // namespace

std::vector<double> lattice_layout_sheet_probe(const LatticeLayoutSheetProbe& probe, BridgeError& err) {
  std::vector<double> out;
  const std::string why = bridge_guard_run("lattice_layout_sheet_probe", [&] {
    const ll::SheetField s = sheet_from_probe(probe);
    out.reserve(probe.xyz.size() / 3);
    for (size_t i = 0; i + 2 < probe.xyz.size(); i += 3) {
      const topopt::Vec3 p{probe.xyz[i], probe.xyz[i + 1], probe.xyz[i + 2]};
      out.push_back(probe.wall ? ll::sheet_wall_at(s, p) : ll::sheet_distance_at(s, p));
    }
  });
  if (!why.empty()) {
    out.clear();
    failed(err, why);
  }
  return out;
}

LatticeSheetCells lattice_sheet_cells_read(const std::string& path) {
  LatticeSheetCells o;
  const std::string why = bridge_guard_run("lattice_sheet_cells_read", [&] {
    ll::SheetCellsFile f;
    std::string refused;
    if (!ll::read_sheet_cells_file(path, f, &refused)) {
      o.why = refused.empty() ? std::string("not a sheet_cells.bin") : refused;
      return;
    }
    for (const ll::Frame& fr : f.frames) {
      put(o.frames, fr.origin);
      for (const topopt::Vec3& a : fr.ax) put(o.frames, a);
    }
    const size_t n = f.cells.size();
    o.region.reserve(n); o.frame.reserve(n); o.lo.reserve(3 * n); o.size_mm.reserve(n); o.wall_mm.reserve(n);
    o.cells_across.reserve(n); o.margin.reserve(n); o.flags.reserve(n);
    for (const ll::SheetCellRecord& c : f.cells) {
      o.region.push_back(c.region);
      o.frame.push_back(c.frame);
      for (float v : c.lo) o.lo.push_back(v);
      o.size_mm.push_back(c.size_mm);
      o.wall_mm.push_back(c.wall_mm);
      o.cells_across.push_back(c.cells_across);
      o.margin.push_back(c.margin);
      o.flags.push_back(c.flags);
    }
    o.ok = true;
  });
  if (!why.empty()) {
    o = LatticeSheetCells{};
    o.why = why;
  }
  return o;
}

void lattice_layout_cancel(int64_t session) {
  std::shared_ptr<LayoutSession> s;
  {
    std::lock_guard<std::mutex> lock(g_layout_mu);
    auto it = g_layouts.find(session);
    if (it == g_layouts.end()) return;
    s = it->second;
  }
  s->stop = true;
  s->cancel_gen.fetch_add(1);
}

void lattice_layout_close(int64_t session) {
  std::shared_ptr<LayoutSession> s;
  {
    std::lock_guard<std::mutex> lock(g_layout_mu);
    auto it = g_layouts.find(session);
    if (it == g_layouts.end()) return;
    s = std::move(it->second);
    g_layouts.erase(it);
  }
  s->stop = true;
  s->cancel_gen.fetch_add(1);   // anything still waiting on it comes back cancelled; it is freed when the last call returns
}

LatticeFileJobResult lattice_file_job(const std::string& job_path, const std::string& out_dir,
                                      const std::string& materials_path, const std::string& rules_path, BridgeError& err) {
  LatticeFileJobResult out;
  const std::string why = bridge_guard_run("lattice_file_job", [&] {
    // ★ Install 3: the strength check, as the CLI makes it (LatticeReview's lattice_file_strength_check), with the app's
    // own materials and rules; a job with no strength_job never reads it
    const ll::StrengthCheck check = topopt::lattice_file_strength_check(materials_path, rules_path);
    const ll::FileResult r = ll::run_file_job(job_path, out_dir, 0, nullptr, &check);
    out.ok = r.ok;
    out.exit_code = static_cast<int32_t>(r.exit_code);
    out.code = r.code;
    out.why = r.why;
    out.detail = r.detail;
    out.ms_total = r.ms_total;
  });
  if (!why.empty()) {
    out = LatticeFileJobResult{};
    failed(err, why);
  }
  return out;
}

}  // namespace topoptbridge
