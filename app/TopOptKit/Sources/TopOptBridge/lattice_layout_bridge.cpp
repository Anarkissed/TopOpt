// lattice_layout_bridge.cpp — the lattice rebuild's stage E entry (LatticeLayoutBridge.hpp). A thin pass-through to core's
// lattice_layout::Session: every rule is core's; this file converts, keeps the sessions, and answers cancel.
#include "LatticeLayoutBridge.hpp"
#include "bridge_guard.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
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
  std::unique_ptr<ll::Session> session;
  int faces = 0;
  // The last layout's outcome: "where" reads the session's domain and this layout's cells, never across the next lay().
  std::unique_ptr<ll::Outcome> last;
  std::unique_ptr<ll::SolidAt> solid_at;          // built once per layout, on the first "where"
  std::atomic<uint64_t> cancel_gen{0};
  std::atomic<bool> stop{false};                   // core's own stop (Session::lay): a running layout gives up within one cell's work
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
    s.regions.push_back(std::move(a));
  }
  const std::size_t np = in.protect_ids.size();
  if (in.protect_depth_mm.size() != np || in.protect_face_counts.size() != np)
    throw std::invalid_argument("lattice layout: the Protect skin lists are not all one length");
  const auto pf = unflatten(in.protect_face_counts, in.protect_faces, "Protect skins");
  for (std::size_t p = 0; p < np; ++p) s.protect.push_back({in.protect_ids[p], pf[p], in.protect_depth_mm[p]});
  s.cells.algorithm = algorithm_from(in.algorithm);
  s.cells.topology = topopt::lattice_topology_from_id(in.topology);
  s.cells.cell_mm = in.cell_mm;
  s.cells.cell_max_mm = in.cell_max_mm;
  s.cells.cell_min_mm = in.cell_min_mm;
  s.cells.min_cells_across = in.min_cells_across;
  s.cells.grade_to_shape = in.grade_to_shape;
  s.cells.band_mm = in.band_mm;
  s.cells.band_cell_mm = in.band_cell_mm;
  s.struts.mode = in.per_region ? ll::Density::PerRegion : ll::Density::Uniform;
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
  for (const ll::Cell& c : L.cells) {
    o.cell_info.push_back(static_cast<float>(c.size));
    o.cell_info.push_back(static_cast<float>(c.own));
    o.cell_info.push_back(static_cast<float>(c.band));
    o.cell_info.push_back(c.finest ? 1.0f : 0.0f);
    o.cell_info.push_back(c.cut ? 1.0f : 0.0f);
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
  o.ms_read = out.ms_read;
  o.ms_cells = out.ms_cells;
  o.ms_bars = out.ms_bars;
}

void failed(BridgeError& err, const std::string& why) {
  err.ok = false;
  err.message = why;
}
}  // namespace

LatticeLayoutOpenInfo lattice_layout_open(const std::string& path, double linear_deflection, BridgeError& err) {
  LatticeLayoutOpenInfo info;
  const std::string why = bridge_guard_run("lattice_layout_open", [&] {
    const auto t0 = std::chrono::steady_clock::now();
    topopt::StepTessellation tess;
    if (linear_deflection > 0.0) tess.linear_deflection = linear_deflection;
    topopt::StepModel model = topopt::import_part_file_resolved(path, tess);
    auto s = std::make_shared<LayoutSession>();
    s->faces = model.face_count;
    s->session = std::make_unique<ll::Session>(std::move(model));
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

LatticeLayoutResult lattice_layout(int64_t session, const LatticeLayoutSettings& settings, BridgeError& err) {
  LatticeLayoutResult o;
  const std::string why = bridge_guard_run("lattice_layout", [&] {
    auto s = layout_at(session);
    const uint64_t gen = s->cancel_gen.load();       // a cancel after this point, or one that came while it waited, wins
    const ll::Settings ask = settings_from(settings);   // a bad setting fails before the wait
    std::lock_guard<std::mutex> lock(s->mu);
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
    fill(o, *s->last);
    o.ms_bridge = ms_since(t0) - (o.ms_read + o.ms_cells + o.ms_bars);
  });
  if (!why.empty()) {
    o = LatticeLayoutResult{};
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
      const topopt::Vec3 p{xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]};
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
            const topopt::Vec3 p{origin_x + voxel_mm * x, origin_y + voxel_mm * y, origin_z + voxel_mm * z};
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

}  // namespace topoptbridge
