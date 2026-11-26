// notes30 (option D): the strut stream. See stream.hpp and lattice_layout.hpp (StrutTap).
#include "stream.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

#include "topopt/strut_cell.hpp"
#include "cell_bars.hpp"

namespace topopt::lattice_layout {

std::atomic<int>& stream_control() {
  static std::atomic<int> control{0};
  return control;
}

std::shared_ptr<LayoutMap> make_layout_map(const Layout& layout, const Domain& domain, const MapAsk& ask, int threads,
                                           const std::atomic<bool>* stop) {
  if (!ask.on()) return nullptr;
  const auto t0 = std::chrono::steady_clock::now();
  const int nx = ask.nx, ny = ask.ny, nz = ask.nz;
  const SolidAt solid_at(layout);
  const std::size_t n = static_cast<std::size_t>(nx) * ny * nz;
  std::vector<std::uint8_t> cls(n, 0);   // 0 outside, 1 solid, 2 open, 3 asked for and no cell holds it (D14: solid)
  std::atomic<int> next{0};
  std::array<std::int64_t, 5> nocell_total{};
  std::mutex nocell_mu;
  const auto stopped = [&] { return stop && stop->load(std::memory_order_relaxed); };
  auto work = [&] {
    const Domain::Probe probe = domain.probe();   // one per thread
    std::array<std::int64_t, 5> local{};
    for (int z = next++; z < nz; z = next++) {
      if (stopped()) return;
      for (int y = 0; y < ny; ++y)
        for (int x = 0; x < nx; ++x) {
          const Vec3 p = ask.at(x, y, z);
          const Where w = probe.where(p);
          std::uint8_t c = 1;
          if (w.why == Why::Outside) {
            c = 0;
          } else if (w.why == Why::Lattice) {
            c = solid_at(probe, p, w) ? 3 : 2;
            if (c == 3) ++local[std::min<std::size_t>(4, static_cast<std::size_t>(solid_at.why(probe, p).why))];
          }
          cls[(static_cast<std::size_t>(z) * ny + y) * nx + x] = c;
        }
    }
    std::lock_guard<std::mutex> g(nocell_mu);
    for (std::size_t k = 0; k < 5; ++k) nocell_total[k] += local[k];
  };
  const int nt = std::max(1, threads > 0 ? threads : static_cast<int>(std::thread::hardware_concurrency()));
  std::vector<std::thread> pool;
  for (int i = 1; i < nt; ++i) pool.emplace_back(work);
  work();
  for (std::thread& t : pool) t.join();
  if (stopped()) return nullptr;
  auto out = std::make_shared<LayoutMap>();
  out->nx = nx;
  out->ny = ny;
  out->nz = nz;
  out->rg.assign(2 * n, static_cast<std::int8_t>(-127));
  const auto at = [&](int x, int y, int z) -> std::uint8_t {
    if (x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz) return 0;
    return cls[(static_cast<std::size_t>(z) * ny + y) * nx + x];
  };
  for (int z = 0; z < nz; ++z)
    for (int y = 0; y < ny; ++y)
      for (int x = 0; x < nx; ++x) {
        const std::size_t i = (static_cast<std::size_t>(z) * ny + y) * nx + x;
        const std::uint8_t c = cls[i];
        if (c >= 2) ++out->asked;
        if (c == 3) ++out->unheld;
        bool open = c == 2;
        if (c == 0)   // an outside voxel next to open lattice reads open: the surface at the opening is cut
          open = at(x - 1, y, z) == 2 || at(x + 1, y, z) == 2 || at(x, y - 1, z) == 2 || at(x, y + 1, z) == 2 ||
                 at(x, y, z - 1) == 2 || at(x, y, z + 1) == 2;
        out->rg[2 * i] = open ? 127 : -127;
        out->rg[2 * i + 1] = c != 0 ? 127 : -127;
      }
  out->nocell = nocell_total;
  out->ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  return out;
}

// ── C3: the stream ────────────────────────────────────────────────────────────────────────────────────────────────────
namespace {
// lay_bars' own key for a point (two ends this close are one point) and for a strut (its two ends, lower first).
constexpr double kSame = 1e-5;   // mm
struct PKey {
  long long x = 0, y = 0, z = 0;
  bool operator==(const PKey& o) const { return x == o.x && y == o.y && z == o.z; }
  bool operator<(const PKey& o) const { return x != o.x ? x < o.x : (y != o.y ? y < o.y : z < o.z); }
};
PKey pkey(const Vec3& p) { return {std::llround(p.x / kSame), std::llround(p.y / kSame), std::llround(p.z / kSame)}; }
struct PKeyHash {
  std::size_t operator()(const PKey& k) const noexcept {
    std::uint64_t h = 1469598103934665603ull;
    for (long long v : {k.x, k.y, k.z}) h = (h ^ static_cast<std::uint64_t>(v)) * 1099511628211ull;
    return static_cast<std::size_t>(h);
  }
};
struct EKey {
  PKey a, b;
  bool operator==(const EKey& o) const { return a == o.a && b == o.b; }
};
EKey ekey(const Vec3& a, const Vec3& b) {
  PKey ka = pkey(a), kb = pkey(b);
  if (kb < ka) std::swap(ka, kb);   // lay_bars: `if (kb < ka) std::swap(ka, kb)`
  return {ka, kb};
}
struct EKeyHash {
  std::size_t operator()(const EKey& k) const noexcept { return PKeyHash()(k.a) * 31u + PKeyHash()(k.b); }
};
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
// `p` in the frame of `c`, as in_cube (cells.cpp) reads it; false when outside its cube.
bool in_cube(const Frame& f, const Cell& c, const Vec3& p, double q[3]) {
  const Vec3 rel{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  bool in = true;
  for (int a = 0; a < 3; ++a) {
    q[a] = rel.x * f.ax[a].x + rel.y * f.ax[a].y + rel.z * f.ax[a].z;
    in = in && q[a] >= c.lo[a] && q[a] < c.lo[a] + c.size;
  }
  return in;
}
// Within `tol` of the closed cube of `c`.
bool near_cube(const Frame& f, const Cell& c, const Vec3& p, double tol) {
  const Vec3 rel{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  for (int a = 0; a < 3; ++a) {
    const double q = rel.x * f.ax[a].x + rel.y * f.ax[a].y + rel.z * f.ax[a].z;
    if (q < c.lo[a] - tol || q > c.lo[a] + c.size + tol) return false;
  }
  return true;
}
}  // namespace

struct StrutStream::Impl {
  // What a laid cell is to the stream.
  enum State : std::uint8_t {
    kWait,      // laid; no later rule can change it once its K5 patch is safe (K5 regions)
    kSettled,   // laid, and nothing after the cells changes it (its strut aside, read when the largest cells are known)
    kFixed,     // never settled during the cells: C24's rounds, a cut cell (P8 f), near a K8 square end
    kDone,      // its bars made (cell_bars), certain
    kNoBars,    // settled, but its bars read another region's cells (D14b) or space not yet certain: left to stage 2
  };
  struct LCell {
    const Cell* c = nullptr;
    std::uint32_t lay = 0, slot = 0, j = 0;
    float lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};   // its cube's box in the layout's coordinates
    double top = 0.0;                             // its highest point along the up
    State state = kWait;
    bool k5_ok = true;                            // K5 cannot take it (its region counts fewer than 3, or its patch is safe)
  };
  // A bar one settled cell lays, kept until every cell that could lay the same strut has been read.
  struct Made {
    std::uint64_t order = 0;   // the cell's place in the layout (lay, slot, cell)
    Vec3 a{}, b{};
    double width = 0.0, cell = 0.0;
    int region = 0;
    bool whole = false;        // both ends nodes, not a piece
  };
  // A strut certain to be a bar of lay_bars' list, exactly (the 2-core and held tests then decide).
  struct Cand {
    Vec3 a{}, b{};
    double width = 0.0, cell = 0.0;
    int region = 0;
    std::uint32_t na = 0, nb = 0;
    bool handed = false;
  };

  StrutTap& tap;
  const Domain& domain;
  Vec3 up{0, 0, 1};
  StrutSpec struts;
  AreaOwnMap own;
  bool has_own = false;
  int threads = 0;
  const StrutCell* type = nullptr;
  bool reentrant = false;
  double bed_z = 0.0;
  // The plan (stage 1).
  const CellPlan* plan = nullptr;
  std::vector<std::vector<StrutCellStrut>> struts_of;   // per frame
  std::vector<std::size_t> lay_left;       // per lay: its slots not yet laid
  std::vector<std::size_t> lay_waiting;    // per lay: its cells waiting on K5
  std::map<std::pair<int, int>, double> base_of;   // per (region, frame): its lays' largest base
  std::size_t jobs_total = 0;
  double laid_max = 0.0;                   // the largest cell laid so far
  std::unordered_map<std::uint64_t, std::vector<std::uint32_t>> ends_grid;   // K8 square ends, by frame and place
  double max_base = 0.0;
  double plan_high = 0.0;
  // The streamer thread.
  std::mutex mu;
  std::condition_variable cv;
  std::size_t upto = 0;
  double line = -1e300;
  bool stop = false;
  std::thread th;
  // Stage 1 (the streamer thread's own).
  std::vector<LCell> cells;
  std::size_t jobs_taken = 0;
  double pitch = 8.0;
  std::unordered_map<std::uint64_t, std::vector<std::uint32_t>> grid;   // cells by their box, on a grid of `pitch`
  std::vector<std::uint32_t> uf;                                          // K5 patches
  struct Extent { double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300}; };
  std::unordered_map<std::uint32_t, Extent> extent;                       // per patch root
  std::unordered_map<std::uint64_t, std::vector<std::uint32_t>> k5grid;  // K5 cells by (frame, low corner) on max_base
  std::vector<std::uint32_t> waiting;                                     // cells kWait
  std::vector<std::uint32_t> settled;                                     // cells kSettled not yet made
  std::unique_ptr<StrutRule> rule;
  std::size_t rule_regions = 0;
  std::unordered_map<EKey, std::vector<Made>, EKeyHash> pending;
  // The certain struts, both stages.
  std::vector<Cand> cand;
  std::unordered_map<EKey, std::uint32_t, EKeyHash> cand_of;
  std::unordered_map<PKey, std::uint32_t, PKeyHash> node_of;
  std::vector<Vec3> node_p;
  std::vector<std::uint8_t> node_held;         // 0 not tried, 1 touches solid, 2 does not, 3 not certain yet
  std::size_t handed = 0;
  mutable std::mutex handed_mu;
  std::size_t tests_budget = 0;

  Impl(StrutTap& t, const Domain& d) : tap(t), domain(d) {}

  static std::uint64_t order_of(std::uint32_t lay, std::uint32_t slot, std::uint32_t j) {
    return (static_cast<std::uint64_t>(lay) << 44) | (static_cast<std::uint64_t>(slot) << 18) | j;
  }
  long long slot_of(double v) const { return static_cast<long long>(std::floor(v / pitch)); }
  static std::uint64_t gkey(long long x, long long y, long long z) {
    return (static_cast<std::uint64_t>(x + (1 << 20)) << 42) ^ (static_cast<std::uint64_t>(y + (1 << 20)) << 21) ^
           static_cast<std::uint64_t>(z + (1 << 20));
  }
  const Frame& frame_of(const Cell& c) const { return plan->layout->frames[static_cast<std::size_t>(c.frame)]; }
  double height(const Vec3& p) const { return dot(p, up); }

  // ── stage 1: the cells ──
  void add_cells(std::size_t to) {
    const CellPlan& P = *plan;
    for (; jobs_taken < to; ++jobs_taken) {
      const CellPlan::Job& job = P.jobs[jobs_taken];
      const CellPlan::Lay& L = P.lays[job.lay];
      --lay_left[job.lay];
      const SlotCells& sc = (*L.pieces)[job.slot];
      for (std::uint32_t j = 0; j < sc.cells.size(); ++j) {
        LCell lc;
        lc.c = &sc.cells[j];
        lc.lay = job.lay;
        lc.slot = job.slot;
        lc.j = j;
        const Cell& c = *lc.c;
        const Frame& f = frame_of(c);
        double mn[3] = {1e300, 1e300, 1e300}, mx[3] = {-1e300, -1e300, -1e300};
        lc.top = -1e300;
        for (int k = 0; k < 8; ++k) {
          const Vec3 v = f.at(c.lo[0] + ((k & 1) ? c.size : 0.0), c.lo[1] + ((k & 2) ? c.size : 0.0),
                              c.lo[2] + ((k & 4) ? c.size : 0.0));
          mn[0] = std::min(mn[0], v.x); mx[0] = std::max(mx[0], v.x);
          mn[1] = std::min(mn[1], v.y); mx[1] = std::max(mx[1], v.y);
          mn[2] = std::min(mn[2], v.z); mx[2] = std::max(mx[2], v.z);
          lc.top = std::max(lc.top, height(v));
        }
        for (int a = 0; a < 3; ++a) {
          lc.lo[a] = static_cast<float>(mn[a] - 1e-3);
          lc.hi[a] = static_cast<float>(mx[a] + 1e-3);
        }
        const std::uint32_t id = static_cast<std::uint32_t>(cells.size());
        const int k = P.k_of ? P.k_of(c.region) : 1;
        lc.k5_ok = k < 3;
        if (L.steps || c.cut || near_square_end(c)) lc.state = kFixed;
        else if (k >= 3) lc.state = kWait;
        else lc.state = kSettled;
        laid_max = std::max(laid_max, c.size);
        cells.push_back(lc);
        uf.push_back(id);
        for (long long x = slot_of(mn[0] - 1e-3); x <= slot_of(mx[0] + 1e-3); ++x)
          for (long long y = slot_of(mn[1] - 1e-3); y <= slot_of(mx[1] + 1e-3); ++y)
            for (long long z = slot_of(mn[2] - 1e-3); z <= slot_of(mx[2] + 1e-3); ++z) grid[gkey(x, y, z)].push_back(id);
        if (k >= 3) {
          k5_add(id);
          waiting.push_back(id);
          ++lay_waiting[job.lay];
        }
        if (cells[id].state == kSettled) settled.push_back(id);
      }
    }
  }
  // K8: a square end within a cell and its Max cell of the cube (frame coordinates): the stretch may change it.
  double ends_pitch() const { return std::max(1.0, 2.0 * plan->square_reach + max_base); }
  std::uint64_t ends_key(int frame, long long x, long long y, long long z) const {
    return gkey(x + 4096LL * frame, y, z);
  }
  bool near_square_end(const Cell& c) const {
    if (ends_grid.empty()) return false;
    const double r = plan->square_reach + c.size, ep = ends_pitch();
    const auto at = [&](double v) { return static_cast<long long>(std::floor(v / ep)); };
    for (long long x = at(c.lo[0] - r); x <= at(c.lo[0] + c.size + r); ++x)
      for (long long y = at(c.lo[1] - r); y <= at(c.lo[1] + c.size + r); ++y)
        for (long long z = at(c.lo[2] - r); z <= at(c.lo[2] + c.size + r); ++z) {
          const auto it = ends_grid.find(ends_key(c.frame, x, y, z));
          if (it == ends_grid.end()) continue;
          for (std::uint32_t i : it->second) {
            const CellPlan::SquareEnd& e = plan->square_ends[i];
            if (e.region != c.region) continue;
            bool in = true;
            for (int a = 0; a < 3 && in; ++a) in = e.at[a] >= c.lo[a] - r && e.at[a] <= c.lo[a] + c.size + r;
            if (in) return true;
          }
        }
    return false;
  }
  // K5: patches of one region and frame joined face to face (drop_small_patches' test, read strictly, so a patch here
  // is never larger than the one the layout finds).
  std::uint32_t find(std::uint32_t i) {
    while (uf[i] != i) { uf[i] = uf[uf[i]]; i = uf[i]; }
    return i;
  }
  void k5_add(std::uint32_t id) {
    const Cell& a = *cells[id].c;
    const double big = max_base;
    const auto key = [&](const Cell& c, int dx, int dy, int dz) {
      return gkey(static_cast<long long>(std::floor(c.lo[0] / big)) + dx + 1000LL * c.frame,
                  static_cast<long long>(std::floor(c.lo[1] / big)) + dy,
                  static_cast<long long>(std::floor(c.lo[2] / big)) + dz);
    };
    // drop_small_patches reads with 1e-6 x max(1, the layout's largest cell): between the largest laid so far and the
    // largest base. Touching is read with the smaller, sharing a face's area with the larger: never joined here unless
    // joined there.
    const double tol_lo = 1e-6 * std::max(1.0, laid_max), tol_hi = 1e-6 * std::max(1.0, big);
    Extent& e = extent[id];
    for (int ax = 0; ax < 3; ++ax) { e.lo[ax] = a.lo[ax]; e.hi[ax] = a.lo[ax] + a.size; }
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const auto it = k5grid.find(key(a, dx, dy, dz));
          if (it == k5grid.end()) continue;
          for (std::uint32_t o : it->second) {
            const Cell& b = *cells[o].c;
            if (b.region != a.region || b.frame != a.frame) continue;
            int touch = 0, overlap = 0;
            for (int ax = 0; ax < 3; ++ax) {
              const double lo = std::max(a.lo[ax], b.lo[ax]), hi = std::min(a.lo[ax] + a.size, b.lo[ax] + b.size);
              if (hi - lo > tol_hi) ++overlap;
              else if (std::fabs(hi - lo) <= tol_lo) ++touch;
            }
            if (overlap != 2 || touch != 1) continue;
            const std::uint32_t ra = find(id), rb = find(o);
            if (ra == rb) continue;
            uf[rb] = ra;
            Extent& ea = extent[ra];
            const Extent eb = extent[rb];
            for (int ax = 0; ax < 3; ++ax) { ea.lo[ax] = std::min(ea.lo[ax], eb.lo[ax]); ea.hi[ax] = std::max(ea.hi[ax], eb.hi[ax]); }
            extent.erase(rb);
          }
        }
    k5grid[key(a, 0, 0, 0)].push_back(id);
  }
  void k5_settle() {
    std::size_t w = 0;
    for (std::uint32_t id : waiting) {
      LCell& l = cells[id];
      const int k = plan->k_of(l.c->region);
      // The region's largest base on this frame: no cell of it is larger, so its patch's largest is no larger.
      const double big = base_of[{l.c->region, l.c->frame}];
      const Extent& e = extent[find(id)];
      double least = 1e300;
      for (int ax = 0; ax < 3; ++ax) least = std::min(least, e.hi[ax] - e.lo[ax]);
      if (least >= k * big) {
        l.k5_ok = true;
        if (l.state == kWait) {
          l.state = kSettled;
          settled.push_back(id);
        }
        --lay_waiting[l.lay];
      } else {
        waiting[w++] = id;
      }
    }
    waiting.resize(w);
  }
  // The largest cells (R10, R19): certain once no lay still to come, still waiting on K5 or still to be laid again
  // (C24) could hold a larger one. Then the strut rule is made (again when more regions are certain).
  void refs() {
    const CellPlan& P = *plan;
    double known_part = 0.0, bound_part = 0.0;
    std::map<int, double> known, bound;
    for (const LCell& l : cells) {
      if (!l.k5_ok || P.lays[l.lay].steps) continue;
      known_part = std::max(known_part, l.c->size);
      double& k = known[l.c->region];
      k = std::max(k, l.c->size);
    }
    for (std::size_t li = 0; li < P.lays.size(); ++li) {
      const CellPlan::Lay& L = P.lays[li];
      if (lay_left[li] == 0 && lay_waiting[li] == 0 && !L.steps) continue;
      bound_part = std::max(bound_part, L.base);
      double& b = bound[L.region];
      b = std::max(b, L.base);
    }
    if (!(known_part >= bound_part) || !(known_part > 0.0)) return;
    std::map<int, double> region_ref;
    for (const auto& [r, k] : known) {
      const auto it = bound.find(r);
      if (it == bound.end() || k >= it->second) region_ref[r] = k;
    }
    if (rule && region_ref.size() == rule_regions) return;
    rule = std::make_unique<StrutRule>(*P.layout, struts, has_own ? &own : nullptr, known_part, region_ref, nullptr);
    rule_regions = region_ref.size();
  }
  // No cell that could still change shares any space with the cell `self`: on its own frame, cubes that overlap (a cube
  // beside it, sharing a face, does not: the cell reads its own cube a hair inside); on another frame, boxes within `m`.
  bool clear(std::uint32_t self, double m) const {
    const LCell& me = cells[self];
    const Cell& c = *me.c;
    for (long long x = slot_of(me.lo[0] - m); x <= slot_of(me.hi[0] + m); ++x)
      for (long long y = slot_of(me.lo[1] - m); y <= slot_of(me.hi[1] + m); ++y)
        for (long long z = slot_of(me.lo[2] - m); z <= slot_of(me.hi[2] + m); ++z) {
          const auto it = grid.find(gkey(x, y, z));
          if (it == grid.end()) continue;
          for (std::uint32_t o : it->second) {
            if (o == self) continue;
            const LCell& l = cells[o];
            if (l.state != kWait && l.state != kFixed) continue;
            bool meet = true;
            if (l.c->frame == c.frame) {
              for (int a = 0; a < 3 && meet; ++a)
                meet = std::min(c.lo[a] + c.size, l.c->lo[a] + l.c->size) - std::max(c.lo[a], l.c->lo[a]) > 1e-9;
            } else {
              for (int a = 0; a < 3 && meet; ++a) meet = l.lo[a] <= me.hi[a] + m && l.hi[a] >= me.lo[a] - m;
            }
            if (meet) return false;
          }
        }
    return true;
  }
  // SolidAt at `p` (read as `w`) for the finished layout, answered from the cells laid so far: `sure` false when it
  // cannot be told yet (a cell that could still change, or one still to come, could hold it).
  bool solid_now(const Domain::Probe& probe, const Vec3& p, const Where& w, double now, bool* sure) const {
    if (w.why == Why::Outside) return false;
    if (!w.lattice()) return true;
    if (plan->layout->is_weave(w.id)) return false;
    if (height(p) >= now - 0.05) { *sure = false; return true; }
    const auto it = grid.find(gkey(slot_of(p.x), slot_of(p.y), slot_of(p.z)));
    bool held = false;
    if (it != grid.end())
      for (std::uint32_t o : it->second) {
        const LCell& l = cells[o];
        const Cell& d = *l.c;
        double q[3];
        if (!in_cube(frame_of(d), d, p, q)) continue;
        if (l.state == kWait || l.state == kFixed) { *sure = false; return true; }
        bool other = false;
        if (cell_owns_at(*plan->layout, probe, d, q, &other)) held = true;
        else if (plan->absorb && other) held = true;   // D14b: the first cell of another region takes it in
      }
    return !held;
  }
  // A settled cell behind the line, clear of cells that could change: its bars, by the lay's own rule.
  void make(const Domain::Probe& probe, std::uint32_t id, double now) {
    LCell& l = cells[id];
    Cell c = *l.c;
    c.strut = rule->width(c, plan->layout->frames, nullptr);
    const Frame& f = frame_of(c);
    bool other_seen = false, unsure = false;
    const auto holds = [&](double a, double b, double cc) {
      const double q[3] = {a, b, cc};
      bool other = false;
      const bool mine = cell_owns_at(*plan->layout, probe, c, q, &other);
      if (!mine && other && plan->absorb) other_seen = true;   // D14b could take it in: the layout's other cells decide
      return mine;
    };
    const auto solid = [&](const Domain::Probe& pr, const Vec3& p, const Where& w) {
      bool sure = true;
      const bool s = solid_now(pr, p, w, now, &sure);
      if (!sure) unsure = true;
      return s;
    };
    std::vector<Bar> bars;
    std::size_t stubs = 0;
    detail::cell_bars(c, f, struts_of[static_cast<std::size_t>(c.frame)], *type, reentrant, probe, solid, holds, bed_z,
                      bars, stubs);
    if (other_seen || unsure) { l.state = kNoBars; return; }
    l.state = kDone;
    const std::uint64_t order = order_of(l.lay, l.slot, l.j);
    for (const Bar& b : bars) {
      Made m;
      m.order = order;
      m.a = b.a;
      m.b = b.b;
      m.width = b.width;
      m.cell = b.cell;
      m.region = b.region;
      m.whole = !b.piece && b.end_a == Bar::End::Node && b.end_b == Bar::End::Node && !b.skin;
      pending[ekey(b.a, b.b)].push_back(m);
    }
  }
  // Every cell that could lay the strut a-b has been read (0), one will never be (1: stage 2 decides), or not yet (2).
  int producers(const Vec3& a, const Vec3& b) const {
    const auto it = grid.find(gkey(slot_of(a.x), slot_of(a.y), slot_of(a.z)));
    if (it == grid.end()) return 0;
    int worst = 0;
    for (std::uint32_t o : it->second) {
      const LCell& l = cells[o];
      const Frame& f = frame_of(*l.c);
      if (!near_cube(f, *l.c, a, 1e-3) || !near_cube(f, *l.c, b, 1e-3)) continue;
      if (l.state == kDone) continue;
      if (l.state == kNoBars || l.state == kFixed) worst = std::max(worst, 1);
      else worst = 2;
    }
    return worst;
  }
  void merge() {
    for (auto it = pending.begin(); it != pending.end();) {
      std::vector<Made>& made = it->second;
      const int p = producers(made.front().a, made.front().b);
      if (p == 2) { ++it; continue; }
      if (p == 0) {   // lay_bars' merge: the first in layout order, as wide as the widest
        std::sort(made.begin(), made.end(), [](const Made& x, const Made& y) { return x.order < y.order; });
        Made m = made.front();
        for (const Made& o : made) { m.width = std::max(m.width, o.width); m.cell = std::max(m.cell, o.cell); }
        if (m.whole) add_cand(it->first, m.a, m.b, m.width, m.cell, m.region);
      }
      it = pending.erase(it);
    }
  }
  // ── both stages: the certain struts, their 2-core, held parts ──
  std::uint32_t node(const Vec3& p, double w) {
    const auto [it, fresh] = node_of.emplace(pkey(p), static_cast<std::uint32_t>(node_p.size()));
    (void)w;
    if (fresh) { node_p.push_back(p); node_held.push_back(0); }
    return it->second;
  }
  void add_cand(const EKey& k, const Vec3& a, const Vec3& b, double width, double cell, int region) {
    if (cand_of.count(k)) return;
    Cand c;
    c.a = a; c.b = b; c.width = width; c.cell = cell; c.region = region;
    c.na = node(a, width);
    c.nb = node(b, width);
    if (c.na == c.nb) return;
    cand_of.emplace(k, static_cast<std::uint32_t>(cand.size()));
    cand.push_back(c);
  }
  // count_pieces' own test at a node: just past it, each way along the axes, by half its strut and 0.02 mm.
  template <class Solid>
  std::uint8_t touch(const Domain::Probe& probe, const Vec3& p, double width, const Solid& solid) {
    const double off = 0.5 * width + 0.02;
    bool unsure = false;
    for (int k = 0; k < 6; ++k) {
      const Vec3 q{p.x + (k == 0) * off - (k == 1) * off, p.y + (k == 2) * off - (k == 3) * off,
                   p.z + (k == 4) * off - (k == 5) * off};
      const Where w = probe.where(q);
      bool sure = true;
      if (solid(q, w, &sure) && sure) return 1;
      if (!sure) unsure = true;
    }
    return unsure ? 3 : 2;
  }
  // The 2-core of the certain struts, its parts, and those parts that hold a node touching solid: their struts are
  // handed over. `solid(q, w, &sure)`: SolidAt as the finished layout answers it.
  template <class Solid>
  void certify(const Domain::Probe& probe, const Solid& solid, std::size_t budget) {
    const std::size_t nn = node_p.size(), nc = cand.size();
    if (nc == 0) return;
    std::vector<std::uint32_t> deg(nn, 0), start(nn + 1, 0), adj(2 * nc);
    for (const Cand& c : cand) { ++deg[c.na]; ++deg[c.nb]; }
    for (std::size_t i = 0; i < nn; ++i) start[i + 1] = start[i] + deg[i];
    {
      std::vector<std::uint32_t> at(start.begin(), start.end() - 1);
      for (std::uint32_t i = 0; i < nc; ++i) { adj[at[cand[i].na]++] = i; adj[at[cand[i].nb]++] = i; }
    }
    // Peel: a strut at a node holding fewer than two of the set goes, until none does (drop_loose_bars can then take
    // none of what is left: each of its nodes keeps two of them while all of them stand).
    std::vector<std::uint8_t> alive(nc, 1);
    std::vector<std::uint32_t> work;
    for (std::uint32_t n = 0; n < nn; ++n) if (deg[n] < 2) work.push_back(n);
    while (!work.empty()) {
      const std::uint32_t n = work.back();
      work.pop_back();
      for (std::uint32_t k = start[n]; k < start[n + 1]; ++k) {
        const std::uint32_t i = adj[k];
        if (!alive[i]) continue;
        alive[i] = 0;
        for (std::uint32_t m : {cand[i].na, cand[i].nb}) {
          if (m == n) continue;
          if (deg[m]-- == 2) work.push_back(m);
        }
        --deg[n];
      }
    }
    // Its parts (shared nodes), each held when a node of it touches solid.
    std::vector<std::uint32_t> part(nn);
    for (std::uint32_t n = 0; n < nn; ++n) part[n] = n;
    const auto root = [&](std::uint32_t n) {
      while (part[n] != n) { part[n] = part[part[n]]; n = part[n]; }
      return n;
    };
    for (std::uint32_t i = 0; i < nc; ++i)
      if (alive[i]) {
        const std::uint32_t a = root(cand[i].na), b = root(cand[i].nb);
        if (a != b) part[std::max(a, b)] = std::min(a, b);
      }
    std::vector<std::uint8_t> held(nn, 0);
    std::vector<std::uint8_t> in_core(nn, 0);
    for (std::uint32_t i = 0; i < nc; ++i) if (alive[i]) in_core[cand[i].na] = in_core[cand[i].nb] = 1;
    for (std::uint32_t n = 0; n < nn; ++n) if (in_core[n] && node_held[n] == 1) held[root(n)] = 1;
    // count_pieces' test at a node, read at the end of a strut of the core there (it is in the finished lay, in the
    // node's piece): that strut's own end and width.
    for (std::uint32_t n = 0; n < nn && budget > 0; ++n) {
      if (!in_core[n] || held[root(n)] || node_held[n] == 1 || node_held[n] == 2) continue;
      std::uint32_t by = 0;
      for (std::uint32_t k = start[n]; k < start[n + 1]; ++k)
        if (alive[adj[k]]) { by = adj[k]; break; }
      const Cand& c = cand[by];
      node_held[n] = touch(probe, c.na == n ? c.a : c.b, c.width, solid);
      --budget;
      if (node_held[n] == 1) held[root(n)] = 1;
    }
    std::size_t now = 0;
    for (std::uint32_t i = 0; i < nc; ++i) {
      Cand& c = cand[i];
      if (c.handed || !alive[i] || !held[root(c.na)]) continue;
      Bar b;
      b.a = c.a;
      b.b = c.b;
      b.width = c.width;
      b.cell = c.cell;
      b.region = c.region;
      tap.strut(b);
      c.handed = true;
      ++now;
    }
    if (now) {
      tap.flush();
      std::lock_guard<std::mutex> g(handed_mu);
      handed += now;
    }
  }
  void round(const Domain::Probe& probe, std::size_t to, double now) {
    add_cells(to);
    k5_settle();
    refs();
    if (rule) {
      std::size_t w = 0;
      for (std::uint32_t id : settled) {
        LCell& l = cells[id];
        if (l.state != kSettled) continue;
        if (!rule->knows(l.c->region) || l.top >= now - 0.1 || !clear(id, 0.05)) {
          settled[w++] = id;
          continue;
        }
        make(probe, id, now);
      }
      settled.resize(w);
    }
    merge();
    certify(probe, [&](const Vec3& q, const Where& w, bool* sure) { return solid_now(probe, q, w, now, sure); }, 4000);
    tap.progress(to, now);
  }
  // A round is due when the line has risen a forty-eighth of the planned height, or a fortieth of the slots are laid.
  std::size_t last = 0;
  double last_line = -1e300;
  double step = 1.0;
  bool due(std::size_t to, double now) const {
    return to >= plan->jobs.size() || now >= last_line + step || to >= last + plan->jobs.size() / 40 + 1;
  }
  void run(const Domain::Probe& probe, std::size_t to, double now) {
    if (to <= last) return;
    round(probe, to, now);
    last = to;
    last_line = now;
  }
  void loop() {
    const Domain::Probe probe = domain.probe();
    for (;;) {
      std::size_t to;
      double now;
      bool done;
      {
        std::unique_lock<std::mutex> lock(mu);
        cv.wait_for(lock, std::chrono::milliseconds(60), [&] { return stop || due(upto, line); });
        to = upto;
        now = line;
        done = stop;
      }
      if (done) return;
      run(probe, to, now);
      if (to >= plan->jobs.size()) return;
    }
  }
  std::unique_ptr<Domain::Probe> sync_probe;   // kStreamControlSyncRounds: the laying thread's
};

StrutStream::StrutStream(StrutTap& tap, const Domain& domain, const Vec3& up, const StrutSpec& struts,
                         const AreaOwnMap* own, int threads)
    : impl_(std::make_unique<Impl>(tap, domain)), up_(up) {
  impl_->up = up;
  impl_->struts = struts;
  if (own) { impl_->own = *own; impl_->has_own = true; }
  impl_->threads = threads;
  impl_->bed_z = domain.measure().lo().z;
}

StrutStream::~StrutStream() {
  if (impl_ && impl_->th.joinable()) executed();
}

void StrutStream::planned(const CellPlan& plan) {
  Impl& m = *impl_;
  m.plan = &plan;
  const Layout& L = *plan.layout;
  m.type = &lattice_strut_cell(L.topology);
  m.reentrant = L.topology == LatticeTopology::Reentrant;
  for (const Frame& f : L.frames) m.struts_of.push_back(cell_struts(L.topology, f));
  m.lay_left.assign(plan.lays.size(), 0);
  m.lay_waiting.assign(plan.lays.size(), 0);
  m.jobs_total = plan.jobs.size();
  // The planned box: the part's, cut to the boxes the lays lay their slots in.
  const PartMeasure& part = m.domain.measure();
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  for (std::size_t i = 0; i < plan.lays.size(); ++i) {
    const CellPlan::Lay& Ly = plan.lays[i];
    m.lay_left[i] = Ly.slots();
    m.max_base = std::max(m.max_base, Ly.base);
    double& bb = m.base_of[{Ly.region, Ly.frame}];
    bb = std::max(bb, Ly.base);
    const Frame& f = L.frames[static_cast<std::size_t>(Ly.frame)];
    for (int k = 0; k < 8; ++k) {
      const Vec3 v = f.at(Ly.start[0] + ((k & 1) ? Ly.count[0] * Ly.base : 0.0),
                          Ly.start[1] + ((k & 2) ? Ly.count[1] * Ly.base : 0.0),
                          Ly.start[2] + ((k & 4) ? Ly.count[2] * Ly.base : 0.0));
      lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
      hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
    }
  }
  lo = {std::max(lo.x, part.lo().x), std::max(lo.y, part.lo().y), std::max(lo.z, part.lo().z)};
  hi = {std::min(hi.x, part.hi().x), std::min(hi.y, part.hi().y), std::min(hi.z, part.hi().z)};
  if (!(lo.x <= hi.x && lo.y <= hi.y && lo.z <= hi.z)) { lo = part.lo(); hi = part.hi(); }
  m.plan_high = -1e300;
  for (int k = 0; k < 8; ++k)
    m.plan_high = std::max(m.plan_high, dot(Vec3{(k & 1) ? hi.x : lo.x, (k & 2) ? hi.y : lo.y, (k & 4) ? hi.z : lo.z}, up_));
  m.pitch = std::max(1.0, m.max_base);
  if (!plan.square_ends.empty()) {
    const double ep = m.ends_pitch();
    for (std::size_t i = 0; i < plan.square_ends.size(); ++i) {
      const CellPlan::SquareEnd& e = plan.square_ends[i];
      m.ends_grid[m.ends_key(e.frame, static_cast<long long>(std::floor(e.at[0] / ep)),
                             static_cast<long long>(std::floor(e.at[1] / ep)),
                             static_cast<long long>(std::floor(e.at[2] / ep)))]
          .push_back(static_cast<std::uint32_t>(i));
    }
  }
  m.tap.start(up_, lo, hi, plan.jobs.size());
  started_ = true;
  m.step = std::max(1.0, (m.plan_high - (plan.jobs.empty() ? 0.0 : plan.jobs.front().h)) / 48.0);
  if (plan.jobs.empty()) return;
  if (stream_control() & kStreamControlSyncRounds) {   // T3: the rounds in the laying thread, at fixed points
    m.sync_probe = std::make_unique<Domain::Probe>(m.domain.probe());
    return;
  }
  m.th = std::thread([&m] { m.loop(); });
}

void StrutStream::retired(std::size_t upto, double line) {
  Impl& m = *impl_;
  if (m.sync_probe) {
    if (m.due(upto, line)) m.run(*m.sync_probe, upto, line);
    return;
  }
  {
    std::lock_guard<std::mutex> lock(m.mu);
    m.upto = upto;
    m.line = line;
  }
  m.cv.notify_one();
}

void StrutStream::executed() {
  Impl& m = *impl_;
  {
    std::lock_guard<std::mutex> lock(m.mu);
    m.stop = true;
  }
  m.cv.notify_one();
  if (m.th.joinable()) m.th.join();
  // The plan's cells are the lay's no longer (assembled, some laid again): what stage 1 kept of them goes.
  m.cells.clear();
  m.grid.clear();
  m.k5grid.clear();
  m.extent.clear();
  m.uf.clear();
  m.waiting.clear();
  m.settled.clear();
  m.pending.clear();
  m.plan = nullptr;
  m.sync_probe.reset();
}

void StrutStream::bars_laid(const Bars& bars, const Layout& layout) {
  Impl& m = *impl_;
  m.tap.progress(m.jobs_total, 1e300);   // every cell is laid
  if (stream_control() & kStreamControlAsMade) {   // T2's RED: every bar as lay_bars made it, no certificate
    for (const Bar& b : bars.bars) m.tap.strut(b);
    m.tap.flush();
    std::lock_guard<std::mutex> g(m.handed_mu);
    m.handed += bars.bars.size();
    return;
  }
  // Every whole strut of the bars as they stand: lay_bars' merge is done, joins and skin change no node end.
  std::unordered_map<PKey, std::uint32_t, PKeyHash> solid_end;   // a node a bar ending in solid runs from
  for (const Bar& b : bars.bars) {
    if (!b.piece && !b.skin && b.end_a == Bar::End::Node && b.end_b == Bar::End::Node)
      m.add_cand(ekey(b.a, b.b), b.a, b.b, b.width, b.cell, b.region);
  }
  // A bar with one end in solid and the other a node of the set: it stands while that node holds two of the set (it
  // is never alone there, and its solid end has landed), and it joins the node's part to the solid: held.
  for (const Bar& b : bars.bars) {
    const bool sa = b.end_a == Bar::End::Solid, sb = b.end_b == Bar::End::Solid;
    if (sa == sb) continue;
    const Bar::End other = sa ? b.end_b : b.end_a;
    if (other != Bar::End::Node) continue;
    const auto it = m.node_of.find(pkey(sa ? b.b : b.a));
    if (it != m.node_of.end()) m.node_held[it->second] = 1;
  }
  const Domain::Probe probe = m.domain.probe();
  const SolidAt solid_at(layout);
  m.certify(probe,
            [&](const Vec3& q, const Where& w, bool* sure) {
              *sure = true;
              return solid_at(probe, q, w);
            },
            20000);
}

std::size_t StrutStream::handed() const {
  std::lock_guard<std::mutex> g(impl_->handed_mu);
  return impl_->handed;
}

}  // namespace topopt::lattice_layout
