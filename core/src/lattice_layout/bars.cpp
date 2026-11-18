// Lattice rebuild, stage D: the bars (rules S4, S11). See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <thread>
#include <tuple>

#include "topopt/strut_cell.hpp"
#include "bar_ends.hpp"

namespace topopt::lattice_layout {
namespace {

// Two ends this close are one point (a hundredth of a micron).
constexpr double kSame = 1e-5;   // mm
// A strut is read a hair inside its own cell: a strut lying IN the part's surface (the
// outermost layer of a face's lattice) or in the face two cells share is this cell's.
constexpr double kInward = 0.02;   // mm
// Along a strut of a cut cell, the cell's shape is read this often, and each place it
// starts or stops is then found to a ten-thousandth of a millimetre.
constexpr double kStep = 0.3;      // mm

struct PointKey {
  long long x, y, z;
  bool operator<(const PointKey& o) const {
    return x != o.x ? x < o.x : (y != o.y ? y < o.y : z < o.z);
  }
  bool operator==(const PointKey& o) const { return x == o.x && y == o.y && z == o.z; }
};
PointKey key_of(const Vec3& p) {
  return {std::llround(p.x / kSame), std::llround(p.y / kSame), std::llround(p.z / kSame)};
}

}  // namespace

SolidAt::SolidAt(const Layout& layout) : layout_(&layout) {
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch_)); };
  auto file = [&](const std::vector<Cell>& cubes, std::map<std::array<long long, 3>, std::vector<std::uint32_t>>& grid) {
    for (std::size_t ci = 0; ci < cubes.size(); ++ci) {
      const Cell& c = cubes[ci];
      const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
      double mn[3] = {1e300, 1e300, 1e300}, mx[3] = {-1e300, -1e300, -1e300};
      for (int k = 0; k < 8; ++k) {
        const Vec3 v = f.at(c.lo[0] + ((k & 1) ? c.size : 0.0), c.lo[1] + ((k & 2) ? c.size : 0.0),
                            c.lo[2] + ((k & 4) ? c.size : 0.0));
        mn[0] = std::min(mn[0], v.x); mx[0] = std::max(mx[0], v.x);
        mn[1] = std::min(mn[1], v.y); mx[1] = std::max(mx[1], v.y);
        mn[2] = std::min(mn[2], v.z); mx[2] = std::max(mx[2], v.z);
      }
      for (long long x = slot(mn[0]); x <= slot(mx[0]); ++x)
        for (long long y = slot(mn[1]); y <= slot(mx[1]); ++y)
          for (long long z = slot(mn[2]); z <= slot(mx[2]); ++z)
            grid[{x, y, z}].push_back(static_cast<std::uint32_t>(ci));
    }
  };
  file(layout.cells, grid_);
  if (layout.solid_why.size() == layout.solid.size()) file(layout.solid, solid_grid_);
}

SolidWhy SolidAt::why(const Domain::Probe& probe, const Vec3& p) const {
  const Where w = probe.where(p);
  if (!w.lattice() || !(*this)(probe, p, w)) return {};
  const auto it = solid_grid_.find({static_cast<long long>(std::floor(p.x / pitch_)),
                                    static_cast<long long>(std::floor(p.y / pitch_)),
                                    static_cast<long long>(std::floor(p.z / pitch_))});
  if (it == solid_grid_.end()) return {};
  for (std::uint32_t si : it->second) {   // in layout order
    const Cell& c = layout_->solid[si];
    if (c.region != w.id) continue;
    const Frame& f = layout_->frames[static_cast<std::size_t>(c.frame)];
    const Vec3 rel{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
    double q[3];
    bool in = true;
    for (int a = 0; a < 3 && in; ++a) {
      q[a] = rel.x * f.ax[a].x + rel.y * f.ax[a].y + rel.z * f.ax[a].z;
      in = q[a] >= c.lo[a] && q[a] < c.lo[a] + c.size;
    }
    if (!in) continue;
    // Under a flat region: the cube's own wall (the wall the pass that recorded it laid).
    const WallMap& walls = layout_->walls[static_cast<std::size_t>(c.frame)];
    if (walls.flat && read_at(probe, f, walls, q[0], q[1], q[2]).wall != c.wall) continue;
    return layout_->solid_why[si];
  }
  return {};
}

bool SolidAt::operator()(const Domain::Probe& probe, const Vec3& p) const {
  return (*this)(probe, p, probe.where(p));
}

bool SolidAt::operator()(const Domain::Probe& probe, const Vec3& p, const Where& w) const {
  if (w.why == Why::Outside) return false;
  if (!w.lattice()) return true;
  if (layout_->is_weave(w.id)) return false;   // O1: a weave's lattice is open
  const auto it = grid_.find({static_cast<long long>(std::floor(p.x / pitch_)),
                              static_cast<long long>(std::floor(p.y / pitch_)),
                              static_cast<long long>(std::floor(p.z / pitch_))});
  if (it != grid_.end())
    for (std::uint32_t ci : it->second) {
      const Cell& c = layout_->cells[ci];
      if ((c.region == w.id || layout_->absorb) && cell_holds(*layout_, probe, c, p)) return false;
    }
  return true;   // lattice was asked for here and no cell holds it: solid (D14)
}

Bars lay_bars(const Layout& layout, const Domain& domain, int threads) {
  const StrutCell& type = lattice_strut_cell(layout.topology);   // throws for a type with none
  const std::vector<StrutCellStrut> struts = strut_cell_closed_struts(type);
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));

  const SolidAt solid_at(layout);
  struct Found { std::vector<Bar> bars; std::size_t stubs = 0; };
  std::vector<Found> per_cell(layout.cells.size());
  std::atomic<std::size_t> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    for (std::size_t ci = next.fetch_add(1); ci < layout.cells.size() && !domain.stop_asked(); ci = next.fetch_add(1)) {
      const Cell& c = layout.cells[ci];
      const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
      const double unit = c.size / type.S;
      const double mid[3] = {c.lo[0] + 0.5 * c.size, c.lo[1] + 0.5 * c.size, c.lo[2] + 0.5 * c.size};
      Found& out = per_cell[ci];
      // Each node of the cell, read once (a hair toward the cell's middle): -1 not yet.
      std::map<std::array<int, 3>, bool> node_read;
      auto node_is_mine = [&](const StrutCellPoint& n) {
        const std::array<int, 3> k{n.x, n.y, n.z};
        auto it = node_read.find(k);
        if (it != node_read.end()) return it->second;
        double q[3] = {c.lo[0] + n.x * unit, c.lo[1] + n.y * unit, c.lo[2] + n.z * unit};
        double off[3], len = 0.0;
        for (int a = 0; a < 3; ++a) { off[a] = mid[a] - q[a]; len += off[a] * off[a]; }
        len = std::sqrt(len);
        if (len > 0.0)
          for (int a = 0; a < 3; ++a) q[a] += off[a] * std::min(1.0, kInward / len);
        const bool yes = cell_holds_at(layout, probe, ci, q[0], q[1], q[2]);
        node_read.emplace(k, yes);
        return yes;
      };
      for (const StrutCellStrut& s : struts) {
        const double qa[3] = {c.lo[0] + s.a.x * unit, c.lo[1] + s.a.y * unit, c.lo[2] + s.a.z * unit};
        const double qb[3] = {c.lo[0] + s.b.x * unit, c.lo[1] + s.b.y * unit, c.lo[2] + s.b.z * unit};
        const detail::BarLine line(f.at(qa[0], qa[1], qa[2]), f.at(qb[0], qb[1], qb[2]));
        const Vec3 &a = line.a, &b = line.b;
        const double length = line.length;
        // The strut's point at t (0 at a, 1 at b), a hair toward the cell's middle.
        auto inward = [&](double t, double q[3]) {
          double off[3], l = 0.0;
          for (int k = 0; k < 3; ++k) {
            q[k] = qa[k] + (qb[k] - qa[k]) * t;
            off[k] = mid[k] - q[k];
            l += off[k] * off[k];
          }
          l = std::sqrt(l);
          if (l > 0.0)
            for (int k = 0; k < 3; ++k) q[k] += off[k] * std::min(1.0, kInward / l);
        };
        // Is the strut, at t, in the cell's own shape?
        auto mine = [&](double t) {
          double q[3];
          inward(t, q);
          return cell_holds_at(layout, probe, ci, q[0], q[1], q[2]);
        };
        Bar bar;
        bar.width = c.strut;
        bar.cell = c.size;
        bar.region = c.region;
        {   // the one plane of the cell's grid the strut lies in, if there is exactly one
          const int along[3] = {s.b.x - s.a.x, s.b.y - s.a.y, s.b.z - s.a.z};
          const int none = (along[0] == 0) + (along[1] == 0) + (along[2] == 0);
          if (none == 1) bar.flat = f.ax[along[0] == 0 ? 0 : (along[1] == 0 ? 1 : 2)];
        }
        // A strut is whole when its two ends and its middle are the cell's (and, in a cell
        // the layout found cut, its quarter points too), and its own line, a hair inside
        // the cell, meets no surface of the part between its ends. That is asked of every
        // strut, in a cell the layout found whole as well: the layout looks a sixth of the
        // cell in from each face, and an edge can pass nearer the face than that. Only a
        // strut that fails it is read closely.
        const bool end_a = node_is_mine(s.a), end_b = node_is_mine(s.b);
        const bool middle = mine(0.5);
        const bool all = end_a && end_b && middle, none = !end_a && !end_b && !middle;
        // None of the five: the strut is not this cell's at all. (A piece between two of
        // them would be under a quarter of the strut long.)
        if (none && !mine(0.25) && !mine(0.75)) continue;
        if (all && (!c.cut || (mine(0.25) && mine(0.75)))) {
          double q0[3], q1[3];
          inward(0.0, q0);
          inward(1.0, q1);
          const Vec3 from = f.at(q0[0], q0[1], q0[2]), to = f.at(q1[0], q1[1], q1[2]);
          const Vec3 along{to.x - from.x, to.y - from.y, to.z - from.z};
          const double span = std::sqrt(along.x * along.x + along.y * along.y + along.z * along.z);
          const double clear = span > 0.0
              ? probe.part().reach_by_line(from, Vec3{along.x / span, along.y / span, along.z / span})
              : 0.0;
          if (clear < 0.0 || clear >= span - 1e-9) {
            bar.a = a;
            bar.b = b;
            out.bars.push_back(bar);
            continue;
          }
        }
        // The point read past a cut end at t: on the strut, a hair toward the cell's middle.
        auto at = [&](double t) {
          double q[3];
          inward(std::clamp(t, 0.0, 1.0), q);
          return f.at(q[0], q[1], q[2]);
        };
        const int n = std::clamp(static_cast<int>(std::ceil(length / kStep)), 6, 24);
        std::vector<char> in(static_cast<std::size_t>(n) + 1);
        in[0] = node_is_mine(s.a);   // the two ends are nodes, read once per cell
        in[static_cast<std::size_t>(n)] = node_is_mine(s.b);
        for (int i = 1; i < n; ++i) in[static_cast<std::size_t>(i)] = mine(static_cast<double>(i) / n);
        for (int i = 0; i <= n; ++i) {
          if (!in[static_cast<std::size_t>(i)]) continue;
          int j = i;
          while (j < n && in[static_cast<std::size_t>(j) + 1]) ++j;
          Bar piece = bar;
          piece.piece = i > 0 || j < n;
          // Its cut ends finished (S4, S11): found between the last point held and the next not, then tagged.
          const bool kept = detail::finish_bar_ends(piece, line, static_cast<double>(i) / n, static_cast<double>(j) / n,
                                                    i > 0, static_cast<double>(i - 1) / n, j < n,
                                                    static_cast<double>(j + 1) / n, probe, solid_at, mine, at);
          i = j;
          if (!kept) { ++out.stubs; continue; }
          out.bars.push_back(piece);
        }
      }
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), layout.cells.size()));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();   // cells left without their struts

  // One bar per strut: two cells that share a strut give the same two ends. The wider
  // asks wins; an end one cell saw cut and the other saw whole stays as the first saw it.
  Bars result;
  std::map<std::pair<PointKey, PointKey>, std::size_t> seen;
  for (const Found& found : per_cell) {
    result.stubs += found.stubs;
    for (const Bar& bar : found.bars) {
      PointKey ka = key_of(bar.a), kb = key_of(bar.b);
      const bool swap = kb < ka;
      if (swap) std::swap(ka, kb);
      auto [it, fresh] = seen.emplace(std::make_pair(ka, kb), result.bars.size());
      if (fresh) {
        result.bars.push_back(bar);
      } else {
        Bar& kept = result.bars[it->second];
        kept.width = std::max(kept.width, bar.width);
        kept.cell = std::max(kept.cell, bar.cell);
      }
    }
  }
  return result;
}

namespace {
// The nearest approach of the segment p + s d (0 <= s <= len, d a unit vector) to the
// segment a..b: the distance, and where along the first it happens.
double approach(const Vec3& p, const Vec3& d, double len, const Vec3& a, const Vec3& b, double* at) {
  const Vec3 e{b.x - a.x, b.y - a.y, b.z - a.z}, r{p.x - a.x, p.y - a.y, p.z - a.z};
  const double ee = e.x * e.x + e.y * e.y + e.z * e.z;
  const double de = d.x * e.x + d.y * e.y + d.z * e.z;
  const double dr = d.x * r.x + d.y * r.y + d.z * r.z, er = e.x * r.x + e.y * r.y + e.z * r.z;
  const double den = ee - de * de;   // (d.d = 1)
  double s = den > 1e-12 * ee ? std::clamp((de * er - dr * ee) / den, 0.0, len) : 0.0;
  double u = ee > 0.0 ? std::clamp((er + de * s) / ee, 0.0, 1.0) : 0.0;
  s = std::clamp(de * u - dr, 0.0, len);
  u = ee > 0.0 ? std::clamp((er + de * s) / ee, 0.0, 1.0) : 0.0;
  const Vec3 gap{r.x + d.x * s - e.x * u, r.y + d.y * s - e.y * u, r.z + d.z * s - e.z * u};
  *at = s;
  return std::sqrt(gap.x * gap.x + gap.y * gap.y + gap.z * gap.z);
}
}  // namespace

std::size_t join_loose_bars(Bars& bars, const Domain& domain, int threads, const Layout* layout) {
  const std::unique_ptr<const SolidAt> solid_at = layout ? std::make_unique<const SolidAt>(*layout) : nullptr;
  const std::vector<Bar> before = bars.bars;   // every bar is run on against the bars as laid
  if (before.empty()) return 0;
  // The bars sorted into a grid, to find those near a line.
  double longest = 0.0, widest = 0.0;
  for (const Bar& b : before) {
    longest = std::max(longest, std::max(b.cell, std::fabs(b.b.x - b.a.x) + std::fabs(b.b.y - b.a.y) + std::fabs(b.b.z - b.a.z)));
    widest = std::max(widest, b.width);
  }
  const double pitch = std::max(1.0, longest);
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
  for (std::size_t i = 0; i < before.size(); ++i) {
    const Bar& b = before[i];
    for (long long x = slot(std::min(b.a.x, b.b.x) - widest); x <= slot(std::max(b.a.x, b.b.x) + widest); ++x)
      for (long long y = slot(std::min(b.a.y, b.b.y) - widest); y <= slot(std::max(b.a.y, b.b.y) + widest); ++y)
        for (long long z = slot(std::min(b.a.z, b.b.z) - widest); z <= slot(std::max(b.a.z, b.b.z) + widest); ++z)
          grid[{x, y, z}].push_back(i);
  }
  // Each loose end on its own, against the bars as laid: shared between threads, and the
  // same result for any number of them.
  struct Result { Bar::End kind = Bar::End::Loose; Vec3 to{}; int into = -1; };
  std::vector<std::pair<std::size_t, int>> ends;
  for (std::size_t i = 0; i < before.size(); ++i)
    for (int end = 0; end < 2; ++end)
      if ((end ? before[i].end_b : before[i].end_a) == Bar::End::Loose) ends.push_back({i, end});
  std::vector<Result> results(ends.size());
  std::atomic<std::size_t> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    std::vector<std::size_t> near;
    for (std::size_t job = next.fetch_add(1); job < ends.size() && !domain.stop_asked(); job = next.fetch_add(1)) {
      const std::size_t i = ends[job].first;
      const int end = ends[job].second;
      const Bar& me = before[i];
      const Vec3 p = end ? me.b : me.a, q = end ? me.a : me.b;
      Vec3 d{p.x - q.x, p.y - q.y, p.z - q.z};
      const double own = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
      if (!(own > 0.0)) continue;
      d = Vec3{d.x / own, d.y / own, d.z / own};
      const double limit = me.cell > 0.0 ? me.cell : own;   // one cell of its own, no farther
      const Vec3 far{p.x + d.x * limit, p.y + d.y * limit, p.z + d.z * limit};
      // The nearest place along the line where it is inside another bar.
      near.clear();
      for (long long x = slot(std::min(p.x, far.x) - widest); x <= slot(std::max(p.x, far.x) + widest); ++x)
        for (long long y = slot(std::min(p.y, far.y) - widest); y <= slot(std::max(p.y, far.y) + widest); ++y)
          for (long long z = slot(std::min(p.z, far.z) - widest); z <= slot(std::max(p.z, far.z) + widest); ++z) {
            const auto it = grid.find({x, y, z});
            if (it != grid.end()) near.insert(near.end(), it->second.begin(), it->second.end());
          }
      std::sort(near.begin(), near.end());
      near.erase(std::unique(near.begin(), near.end()), near.end());
      double land = -1.0;
      int into = -1;
      for (std::size_t k : near) {
        if (k == i) continue;
        const Bar& other = before[k];
        double at = 0.0;
        const double gap = approach(p, d, limit, other.a, other.b, &at);
        if (gap > 0.5 * other.width) continue;        // its middle line stays outside that bar
        // Not the bar it is a continuation of (the next piece of the same strut touches
        // it end to end only when nothing lies between them, and that is a join too).
        if (land < 0.0 || at < land) {
          land = at;
          into = static_cast<int>(k);
        }
      }
      // What the line passes through before that: solid ends it sooner (S11); air ends it.
      // A strut lying IN the part's surface (the outermost struts of a latticed face) is
      // read a hair inside the part, as its cell read it: on the surface itself every
      // point is "not inside", and it would be stopped where it stands.
      Vec3 lift{0, 0, 0};
      if (probe.part().depth(p) < 0.01) {
        double best = 0.01;
        for (int k = 0; k < 6; ++k) {
          const Vec3 step{((k == 0) - (k == 1)) * kInward, ((k == 2) - (k == 3)) * kInward, ((k == 4) - (k == 5)) * kInward};
          const double depth = probe.part().depth(Vec3{p.x + step.x, p.y + step.y, p.z + step.z});
          if (depth > best) { best = depth; lift = step; }
        }
      }
      auto read = [&](double at) {
        return probe.where(Vec3{p.x + d.x * at + lift.x, p.y + d.y * at + lift.y, p.z + d.z * at + lift.z});
      };
      // Still lattice a bar may run through? Not where no cell holds it: that is solid (D14).
      auto open_at = [&](double at, const Where& w) {
        if (!w.lattice()) return false;
        if (!solid_at) return true;
        return !(*solid_at)(probe, Vec3{p.x + d.x * at + lift.x, p.y + d.y * at + lift.y, p.z + d.z * at + lift.z}, w);
      };
      const double reach = land >= 0.0 ? land : limit;
      Bar::End kind = land >= 0.0 ? Bar::End::Joined : Bar::End::Loose;
      double stop = reach;
      for (double t = 0.25; t < reach + 0.25; t += 0.25) {
        const double at = std::min(t, reach);
        const Where w = read(at);
        if (open_at(at, w)) continue;
        double in = at - 0.25 < 0.0 ? 0.0 : at - 0.25, out = at;   // lattice at `in`, not at `out`
        for (int k = 0; k < 12; ++k) {
          const double m = 0.5 * (in + out);
          if (open_at(m, read(m))) in = m; else out = m;
        }
        if (w.why == Why::Outside) {
          kind = Bar::End::Surface;
          stop = in;
        } else {
          kind = Bar::End::Solid;
          stop = in + me.width;   // S11: on into the solid by its own width
        }
        break;
      }
      if (kind == Bar::End::Loose) continue;   // met nothing within a cell: left as it was
      results[job].kind = kind;
      results[job].to = Vec3{p.x + d.x * stop, p.y + d.y * stop, p.z + d.z * stop};
      if (kind == Bar::End::Joined) results[job].into = into;
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(
        std::max(1, threads > 0 ? threads : static_cast<int>(std::thread::hardware_concurrency())),
        std::max<std::size_t>(1, ends.size() / 64)));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();   // loose ends left unlooked at: no bar is changed
  std::size_t joined = 0;
  for (std::size_t job = 0; job < ends.size(); ++job) {
    if (results[job].kind == Bar::End::Loose) continue;
    Bar& mine = bars.bars[ends[job].first];
    if (ends[job].second) { mine.b = results[job].to; mine.end_b = results[job].kind; mine.into_b = results[job].into; }
    else { mine.a = results[job].to; mine.end_a = results[job].kind; mine.into_a = results[job].into; }
    if (results[job].kind != Bar::End::Surface) ++joined;
  }
  bars.joined += joined;
  return joined;
}

std::size_t lay_skin(Bars& bars, const Domain& domain, const SkinSpec& spec) {
  // The cut ends, each once per plane (two bars can be cut at the same point). `plane` is
  // -1 for the end of a strut that lies in no single plane of its cells' grid.
  // `skin_width` and `reach`: what its regions ask of a skin bar (S13), the least of them.
  struct Tip {
    Vec3 p; double cell, width; int plane; std::vector<std::pair<std::size_t, int>> of;
    double skin_width, reach;
  };
  // S13: each region's own Skin; a region not listed takes the part's.
  auto skin_of = [&](int region) {
    for (const SkinSpec::RegionSkin& r : spec.regions)
      if (r.region == region) return r;
    return SkinSpec::RegionSkin{region, spec.on, spec.width_mm, spec.reach_cells};
  };
  struct PlaneKey {
    long long n[3], d;
    bool operator<(const PlaneKey& o) const {
      for (int k = 0; k < 3; ++k) if (n[k] != o.n[k]) return n[k] < o.n[k];
      return d < o.d;
    }
  };
  std::vector<Tip> tips;
  // A weave region's skin is its net skin (O16): its bars are not read here.
  std::vector<int> weave;
  for (const Region& r : domain.spec().regions)
    if (r.weave) weave.push_back(r.id);
  {
    std::map<PlaneKey, int> planes;
    std::map<std::pair<PointKey, int>, std::size_t> at;
    for (std::size_t i = 0; i < bars.bars.size(); ++i)
      for (int end = 0; end < 2; ++end) {
        const Bar& b = bars.bars[i];
        if ((end ? b.end_b : b.end_a) != Bar::End::Surface || b.skin) continue;
        const SkinSpec::RegionSkin own = skin_of(b.region);
        if (!own.on) continue;   // S13: only ends of bars whose region has Skin on
        if (!weave.empty() && std::find(weave.begin(), weave.end(), b.region) != weave.end()) continue;
        const Vec3& p = end ? b.b : b.a;
        int plane = -1;
        Vec3 n = b.flat;
        if (n.x * n.x + n.y * n.y + n.z * n.z > 0.25) {
          // One way round, so the two sides of a plane are one plane.
          const double lead = std::fabs(n.x) > 1e-9 ? n.x : (std::fabs(n.y) > 1e-9 ? n.y : n.z);
          if (lead < 0.0) n = Vec3{-n.x, -n.y, -n.z};
          const PlaneKey key{{std::llround(n.x * 1e6), std::llround(n.y * 1e6), std::llround(n.z * 1e6)},
                             std::llround((p.x * n.x + p.y * n.y + p.z * n.z) * 1e4)};
          plane = planes.emplace(key, static_cast<int>(planes.size())).first->second;
        }
        auto [it, fresh] = at.emplace(std::make_pair(key_of(p), plane), tips.size());
        const double skin_width = own.width_mm > 0.0 ? own.width_mm : b.width;
        if (fresh) tips.push_back({p, b.cell, b.width, plane, {}, skin_width, own.reach_cells});
        Tip& t = tips[it->second];
        t.cell = std::max(t.cell, b.cell);
        t.width = std::min(t.width, b.width);
        t.skin_width = std::min(t.skin_width, skin_width);
        t.reach = std::min(t.reach, own.reach_cells);
        t.of.push_back({i, end});
      }
  }
  if (tips.size() < 2) return 0;
  double reach_most = 0.0;
  for (const Tip& t : tips) reach_most = std::max(reach_most, t.reach * t.cell);
  const double pitch = std::max(0.5, reach_most);
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
  for (std::size_t i = 0; i < tips.size(); ++i)
    grid[{slot(tips[i].p.x), slot(tips[i].p.y), slot(tips[i].p.z)}].push_back(i);
  const Domain::Probe probe = domain.probe();
  std::vector<int> landed(tips.size(), 0);
  std::size_t made = 0;
  std::vector<std::size_t> near;
  for (std::size_t i = 0; i < tips.size(); ++i) {
    const Vec3& p = tips[i].p;
    near.clear();
    for (long long x = slot(p.x) - 1; x <= slot(p.x) + 1; ++x)
      for (long long y = slot(p.y) - 1; y <= slot(p.y) + 1; ++y)
        for (long long z = slot(p.z) - 1; z <= slot(p.z) + 1; ++z) {
          const auto it = grid.find({x, y, z});
          if (it == grid.end()) continue;
          for (std::size_t k : it->second)
            if (tips[k].plane == tips[i].plane) near.push_back(k);   // its own plane's ends only
        }
    std::sort(near.begin(), near.end());
    for (std::size_t j : near) {
      if (j <= i) continue;   // each pair once
      const Vec3& q = tips[j].p;
      const Vec3 d{q.x - p.x, q.y - p.y, q.z - p.z};
      const double len2 = d.x * d.x + d.y * d.y + d.z * d.z, len = std::sqrt(len2);
      if (len < 10 * kSame || len > std::min(tips[i].reach, tips[j].reach) * std::max(tips[i].cell, tips[j].cell))
        continue;
      // No other cut end of the plane in the ball between them, or on it: along a line the
      // next one is joined and the one after is not; four at the corners of a square are
      // joined round the square, and neither diagonal crosses it.
      const Vec3 mid{0.5 * (p.x + q.x), 0.5 * (p.y + q.y), 0.5 * (p.z + q.z)};
      bool empty = true;
      for (std::size_t k : near) {
        if (k == i || k == j) continue;
        const Vec3& r = tips[k].p;
        const double e2 = (r.x - mid.x) * (r.x - mid.x) + (r.y - mid.y) * (r.y - mid.y) + (r.z - mid.z) * (r.z - mid.z);
        if (e2 <= 0.25 * len2 * (1.0 + 1e-6)) { empty = false; break; }
      }
      if (!empty) continue;
      // On the surface: its middle neither in the air (across a notch) nor deep in the part.
      // Round a curved wall a straight bar between two points of the surface leaves it by the
      // bow of the curve (SkinSpec::bow).
      const double depth = probe.part().depth(mid);
      const double bow = std::max(0.0, spec.bow) * len;
      if (depth < -(bow + 1e-6) || depth > std::max(bow, 0.05 * len) + 0.02) continue;
      Bar skin;
      skin.a = p;
      skin.b = q;
      skin.skin = true;
      skin.width = std::min(tips[i].skin_width, tips[j].skin_width);
      skin.cell = std::max(tips[i].cell, tips[j].cell);
      skin.region = bars.bars[tips[i].of.front().first].region;
      skin.flat = bars.bars[tips[i].of.front().first].flat;
      if (!landed[i]) landed[i] = static_cast<int>(bars.bars.size()) + 1;   // the bar it ends in, + 1
      if (!landed[j]) landed[j] = static_cast<int>(bars.bars.size()) + 1;
      bars.bars.push_back(skin);
      ++made;
    }
  }
  for (std::size_t i = 0; i < tips.size(); ++i) {
    if (!landed[i]) continue;
    for (const auto& [bar, end] : tips[i].of) {
      (end ? bars.bars[bar].end_b : bars.bars[bar].end_a) = Bar::End::Joined;
      (end ? bars.bars[bar].into_b : bars.bars[bar].into_a) = landed[i] - 1;
    }
  }
  return made;
}

namespace {
// Keep the flagged bars, in order, and renumber what the Joined ends point at.
void keep_only(Bars& bars, const std::vector<char>& keep) {
  std::vector<int> now(bars.bars.size(), -1);
  std::vector<Bar> left;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    if (!keep[i]) { ++bars.dropped; continue; }
    now[i] = static_cast<int>(left.size());
    left.push_back(bars.bars[i]);
  }
  for (Bar& b : left) {
    if (b.into_a >= 0) b.into_a = b.into_a < static_cast<int>(now.size()) ? now[static_cast<std::size_t>(b.into_a)] : -1;
    if (b.into_b >= 0) b.into_b = b.into_b < static_cast<int>(now.size()) ? now[static_cast<std::size_t>(b.into_b)] : -1;
  }
  bars.bars.swap(left);
}
double length_of(const Bar& b) {
  return std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) +
                   (b.b.z - b.a.z) * (b.b.z - b.a.z));
}
// The nearest approach of the two bars' middle lines.
double apart(const Bar& x, const Bar& y) {
  const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
  const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  if (!(len > 0.0)) return 1e300;
  double at = 0.0;
  return approach(x.a, Vec3{d.x / len, d.y / len, d.z / len}, len, y.a, y.b, &at);
}
}  // namespace

Pieces count_pieces(const Bars& bars, const Domain& domain, std::vector<char>* adrift_bar,
                    std::vector<int>* piece_of, const Layout* layout) {
  const std::unique_ptr<const SolidAt> solid_at = layout ? std::make_unique<const SolidAt>(*layout) : nullptr;
  const std::vector<Bar>& all = bars.bars;
  const std::size_t n = all.size();
  Pieces out;
  if (adrift_bar) adrift_bar->assign(n, 0);
  if (piece_of) piece_of->assign(n, -1);
  if (n == 0) return out;
  std::vector<std::size_t> parent(n);
  for (std::size_t i = 0; i < n; ++i) parent[i] = i;
  auto find = [&](std::size_t i) {
    while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
    return i;
  };
  auto join = [&](std::size_t i, std::size_t j) {
    i = find(i); j = find(j);
    if (i != j) parent[std::max(i, j)] = std::min(i, j);
  };
  // Shared ends first: nearly every join is one of these.
  {
    std::map<PointKey, std::size_t> first;
    for (std::size_t i = 0; i < n; ++i)
      for (const Vec3& p : {all[i].a, all[i].b}) {
        auto [it, fresh] = first.emplace(key_of(p), i);
        if (!fresh) join(i, it->second);
      }
  }
  // Then bars that touch along their length: sorted into a grid, each against its neighbours.
  double widest = 0.0;
  for (const Bar& b : all) widest = std::max(widest, b.width);
  const double pitch = 2.0;
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
  for (std::size_t i = 0; i < n; ++i) {
    const Bar& b = all[i];
    for (long long x = slot(std::min(b.a.x, b.b.x) - widest); x <= slot(std::max(b.a.x, b.b.x) + widest); ++x)
      for (long long y = slot(std::min(b.a.y, b.b.y) - widest); y <= slot(std::max(b.a.y, b.b.y) + widest); ++y)
        for (long long z = slot(std::min(b.a.z, b.b.z) - widest); z <= slot(std::max(b.a.z, b.b.z) + widest); ++z)
          grid[{x, y, z}].push_back(i);
  }
  for (const auto& cell : grid) {
    const std::vector<std::size_t>& in = cell.second;
    // Nearly every square of the grid holds bars of one piece already: nothing to test.
    bool one = true;
    for (std::size_t a = 1; a < in.size() && one; ++a) one = find(in[a]) == find(in[0]);
    if (one) continue;
    for (std::size_t a = 0; a < in.size(); ++a)
      for (std::size_t b = a + 1; b < in.size(); ++b) {
        const std::size_t i = in[a], j = in[b];
        if (find(i) == find(j)) continue;
        const Bar &x = all[i], &y = all[j];
        const double gap = apart(x, y);
        bool touch = gap <= 0.25 * std::max(x.width, y.width);
        // An end of one inside the other (a joined end; a T).
        if (!touch && gap <= 0.5 * std::max(x.width, y.width)) {
          double at = 0.0;
          const Vec3 zero{1, 0, 0};
          for (const Vec3& p : {x.a, x.b})
            touch = touch || approach(p, zero, 0.0, y.a, y.b, &at) <= 0.5 * y.width;
          for (const Vec3& p : {y.a, y.b})
            touch = touch || approach(p, zero, 0.0, x.a, x.b, &at) <= 0.5 * x.width;
        }
        if (touch) join(i, j);
      }
  }
  // Each piece: its length, and whether it is joined to the part.
  struct Group { double mm = 0.0; std::size_t bars = 0; bool held = false; std::vector<std::size_t> members; };
  std::map<std::size_t, Group> groups;
  for (std::size_t i = 0; i < n; ++i) {
    Group& g = groups[find(i)];
    g.mm += length_of(all[i]);
    ++g.bars;
    g.held = g.held || all[i].end_a == Bar::End::Solid || all[i].end_b == Bar::End::Solid;
    g.members.push_back(i);
  }
  // A piece with no bar ending in solid may still stand on it: a node on the plane where
  // the lattice stops. Look just past each of its ends, each way along the axes.
  const Domain::Probe probe = domain.probe();
  for (auto& [root, g] : groups) {
    if (g.held) continue;
    for (std::size_t i : g.members) {
      const double off = 0.5 * all[i].width + 0.02;
      for (const Vec3& p : {all[i].a, all[i].b})
        for (int k = 0; k < 6 && !g.held; ++k) {
          const Vec3 q{p.x + (k == 0) * off - (k == 1) * off, p.y + (k == 2) * off - (k == 3) * off,
                       p.z + (k == 4) * off - (k == 5) * off};
          const Where w = probe.where(q);
          g.held = solid_at ? (*solid_at)(probe, q, w) : (!w.lattice() && w.why != Why::Outside);
        }
      if (g.held) break;
    }
  }
  out.pieces = groups.size();
  if (piece_of) {
    int number = 0;
    for (const auto& [root, g] : groups) {   // roots are each piece's first bar, in order
      for (std::size_t i : g.members) (*piece_of)[i] = number;
      ++number;
    }
  }
  bool any_held = false;
  std::size_t largest = 0;
  double largest_mm = -1.0;
  for (const auto& [root, g] : groups) {
    any_held = any_held || g.held;
    if (g.mm > largest_mm) { largest_mm = g.mm; largest = root; }
  }
  for (const auto& [root, g] : groups) {
    if (g.held || (!any_held && root == largest)) continue;
    ++out.adrift;
    out.adrift_bars += g.bars;
    out.adrift_mm += g.mm;
    out.largest_adrift_mm = std::max(out.largest_adrift_mm, g.mm);
    if (adrift_bar)
      for (std::size_t i : g.members) (*adrift_bar)[i] = 1;
  }
  return out;
}

Pieces drop_adrift_bars(Bars& bars, const Domain& domain, const Layout* layout) {
  std::vector<char> adrift;
  const Pieces found = count_pieces(bars, domain, &adrift, nullptr, layout);
  if (found.adrift == 0) return found;
  std::vector<char> keep(adrift.size());
  for (std::size_t i = 0; i < adrift.size(); ++i) keep[i] = !adrift[i];
  keep_only(bars, keep);
  return found;
}

std::vector<SteppedEdge> stepped_edges(const Bars& bars) {
  const std::vector<Bars::CutEnd>& ends = bars.cut_in_air;
  std::vector<SteppedEdge> out;
  if (ends.empty()) return out;
  double largest = 0.0;
  for (const Bars::CutEnd& e : ends) largest = std::max(largest, e.cell);
  const double reach = 1.5 * std::max(largest, 1.0);
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / reach)); };
  std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
  for (std::size_t i = 0; i < ends.size(); ++i)
    grid[{slot(ends[i].at.x), slot(ends[i].at.y), slot(ends[i].at.z)}].push_back(i);
  std::vector<std::size_t> parent(ends.size());
  for (std::size_t i = 0; i < ends.size(); ++i) parent[i] = i;
  auto find = [&](std::size_t i) {
    while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
    return i;
  };
  for (std::size_t i = 0; i < ends.size(); ++i) {
    const Vec3& p = ends[i].at;
    for (long long x = slot(p.x) - 1; x <= slot(p.x) + 1; ++x)
      for (long long y = slot(p.y) - 1; y <= slot(p.y) + 1; ++y)
        for (long long z = slot(p.z) - 1; z <= slot(p.z) + 1; ++z) {
          const auto it = grid.find({x, y, z});
          if (it == grid.end()) continue;
          for (std::size_t j : it->second) {
            if (j <= i || ends[j].region != ends[i].region) continue;
            const Vec3& q = ends[j].at;
            const double d2 = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z);
            const double near = 1.5 * std::max(ends[i].cell, ends[j].cell);
            if (d2 > near * near) continue;
            const std::size_t a = find(i), b = find(j);
            if (a != b) parent[std::max(a, b)] = std::min(a, b);
          }
        }
  }
  std::map<std::size_t, SteppedEdge> groups;
  for (std::size_t i = 0; i < ends.size(); ++i) {
    const Vec3& p = ends[i].at;
    auto [it, fresh] = groups.emplace(find(i), SteppedEdge{});
    SteppedEdge& g = it->second;
    if (fresh) { g.region = ends[i].region; g.lo = g.hi = p; }
    g.lo = Vec3{std::min(g.lo.x, p.x), std::min(g.lo.y, p.y), std::min(g.lo.z, p.z)};
    g.hi = Vec3{std::max(g.hi.x, p.x), std::max(g.hi.y, p.y), std::max(g.hi.z, p.z)};
    g.at = Vec3{g.at.x + p.x, g.at.y + p.y, g.at.z + p.z};
    ++g.ends;
  }
  for (auto& [root, g] : groups) {
    if (g.ends < 3) continue;
    g.at = Vec3{g.at.x / g.ends, g.at.y / g.ends, g.at.z / g.ends};
    out.push_back(g);
  }
  std::stable_sort(out.begin(), out.end(),
                   [](const SteppedEdge& x, const SteppedEdge& y) { return x.ends > y.ends; });
  return out;
}

void drop_loose_bars(Bars& bars, const std::vector<int>* arrived) {
  // A cut end that lands on nothing: in the air, or loose in the lattice.
  auto lands = [](Bar::End e) {
    return e == Bar::End::Node || e == Bar::End::Solid || e == Bar::End::Joined;
  };
  // G11: a Grown vine's upper Surface end on a steep bar has arrived.
  auto arrived_at = [&](const Bar& b, bool end_b) {
    if (!arrived || (end_b ? b.end_b : b.end_a) != Bar::End::Surface || bar_is_bridge(b)) return false;
    if (std::find(arrived->begin(), arrived->end(), b.region) == arrived->end()) return false;
    return end_b ? b.b.z > b.a.z : b.a.z > b.b.z;
  };
  std::vector<char> keep(bars.bars.size(), 1);
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar& b = bars.bars[i];
    const bool in_a = arrived_at(b, false), in_b = arrived_at(b, true);
    if (!(lands(b.end_a) || in_a) || !(lands(b.end_b) || in_b)) keep[i] = 0;
    if (b.end_a == Bar::End::Surface && !in_a) bars.cut_in_air.push_back({b.a, b.region, b.cell});
    if (b.end_b == Bar::End::Surface && !in_b) bars.cut_in_air.push_back({b.b, b.region, b.cell});
  }
  // A node end lands on another bar only while another bar is still there: take away
  // bars that hold a node alone, until none does. (A Solid end has landed already.)
  for (bool again = true; again;) {
    again = false;
    std::map<PointKey, int> at;
    for (std::size_t i = 0; i < bars.bars.size(); ++i) {
      if (!keep[i]) continue;
      ++at[key_of(bars.bars[i].a)];
      ++at[key_of(bars.bars[i].b)];
    }
    for (std::size_t i = 0; i < bars.bars.size(); ++i) {
      if (!keep[i]) continue;
      const Bar& b = bars.bars[i];
      const bool alone_a = b.end_a == Bar::End::Node && at[key_of(b.a)] < 2;
      const bool alone_b = b.end_b == Bar::End::Node && at[key_of(b.b)] < 2;
      // A joined end lands on the bar it ends in only while that bar is still there.
      auto gone = [&](Bar::End e, int into) {
        return e == Bar::End::Joined && into >= 0 && into < static_cast<int>(keep.size()) &&
               !keep[static_cast<std::size_t>(into)];
      };
      if (alone_a || alone_b || gone(b.end_a, b.into_a) || gone(b.end_b, b.into_b)) {
        keep[i] = 0;
        again = true;
      }
    }
  }
  keep_only(bars, keep);
}

// ── ORGANIC: A WEAVE (O1, O2) ─────────────────────────────────────────────────

Bars weave_bars(const Domain& domain, const std::vector<Strand>& strands, int threads) {
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
  struct Found { std::vector<Bar> bars; std::size_t stubs = 0; };
  std::vector<Found> per_strand(strands.size());
  // No layout is read here: inside the part, lattice of any region is open and anything else is solid. (A strand
  // that reaches a cube region's lattice ends Loose there; joining, which reads the layout, finds what holds it.)
  auto solid = [](const Domain::Probe&, const Vec3&, const Where& w) { return !w.lattice(); };
  std::atomic<std::size_t> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    for (std::size_t si = next.fetch_add(1); si < strands.size() && !domain.stop_asked(); si = next.fetch_add(1)) {
      const Strand& st = strands[si];
      Found& out = per_strand[si];
      if (st.points.size() < 2 || st.width_mm.size() != st.points.size()) continue;
      const std::size_t last = st.points.size() - 2;   // the last segment
      for (std::size_t k = 0; k + 1 < st.points.size(); ++k) {
        const Vec3& p = st.points[k];
        const Vec3& q = st.points[k + 1];
        if (!((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z) > 0.0)) continue;
        const detail::BarLine line(p, q);
        // The point at t (the two ends exactly), and t past either end along the line.
        auto at = [&](double t) {
          if (t == 0.0) return p;
          if (t == 1.0) return q;
          return Vec3{p.x + line.ab.x * t, p.y + line.ab.y * t, p.z + line.ab.z * t};
        };
        auto held = [&](double t) {
          const Where w = probe.where(at(t));
          return w.lattice() && w.id == st.region;
        };
        Bar bar;
        bar.width = 0.5 * (st.width_mm[k] + st.width_mm[k + 1]);
        bar.cell = st.spacing_mm;
        bar.region = st.region;
        bar.strand = static_cast<int>(si);
        bar.level_tie = st.level_tie;   // S (brief G28)
        const int n = std::max(2, static_cast<int>(std::ceil(line.length / kStep)));
        std::vector<char> in(static_cast<std::size_t>(n) + 1);
        for (int i = 0; i <= n; ++i) in[static_cast<std::size_t>(i)] = held(static_cast<double>(i) / n);
        for (int i = 0; i <= n; ++i) {
          if (!in[static_cast<std::size_t>(i)]) continue;
          int j = i;
          while (j < n && in[static_cast<std::size_t>(j) + 1]) ++j;
          Bar piece = bar;
          piece.piece = i > 0 || j < n;
          // A cut end is found and tagged; so is the strand's own free end (nothing to find: it is the end).
          const bool free_a = i == 0 && k == 0, free_b = j == n && k == last;
          const double none = std::nan("");
          const bool kept = detail::finish_bar_ends(
              piece, line, static_cast<double>(i) / n, static_cast<double>(j) / n, i > 0 || free_a,
              i > 0 ? static_cast<double>(i - 1) / n : none, j < n || free_b, j < n ? static_cast<double>(j + 1) / n : none,
              probe, solid, held, at);
          i = j;
          if (!kept) { ++out.stubs; continue; }
          out.bars.push_back(piece);
        }
      }
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), std::max<std::size_t>(1, strands.size())));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();
  Bars result;
  for (const Found& found : per_strand) {
    result.stubs += found.stubs;
    result.bars.insert(result.bars.end(), found.bars.begin(), found.bars.end());
  }
  return result;
}

namespace {
// The closest approach of segments p0..p1 and q0..q1: where along each (0 .. 1), and the distance.
double closest(const Vec3& p0, const Vec3& p1, const Vec3& q0, const Vec3& q1, double* s, double* t) {
  const Vec3 d1{p1.x - p0.x, p1.y - p0.y, p1.z - p0.z}, d2{q1.x - q0.x, q1.y - q0.y, q1.z - q0.z};
  const Vec3 r{p0.x - q0.x, p0.y - q0.y, p0.z - q0.z};
  const double a = d1.x * d1.x + d1.y * d1.y + d1.z * d1.z, e = d2.x * d2.x + d2.y * d2.y + d2.z * d2.z;
  const double f = d2.x * r.x + d2.y * r.y + d2.z * r.z;
  double sc = 0.0, tc = 0.0;
  if (a <= 1e-24 && e <= 1e-24) {
    sc = tc = 0.0;
  } else if (a <= 1e-24) {
    tc = std::clamp(f / e, 0.0, 1.0);
  } else {
    const double c = d1.x * r.x + d1.y * r.y + d1.z * r.z;
    if (e <= 1e-24) {
      sc = std::clamp(-c / a, 0.0, 1.0);
    } else {
      const double b = d1.x * d2.x + d1.y * d2.y + d1.z * d2.z;
      const double den = a * e - b * b;
      sc = den > 1e-12 * a * e ? std::clamp((b * f - c * e) / den, 0.0, 1.0) : 0.0;
      tc = (b * sc + f) / e;
      if (tc < 0.0) { tc = 0.0; sc = std::clamp(-c / a, 0.0, 1.0); }
      else if (tc > 1.0) { tc = 1.0; sc = std::clamp((b - c) / a, 0.0, 1.0); }
    }
  }
  *s = sc;
  *t = tc;
  const Vec3 g{p0.x + d1.x * sc - q0.x - d2.x * tc, p0.y + d1.y * sc - q0.y - d2.y * tc, p0.z + d1.z * sc - q0.z - d2.z * tc};
  return std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
}
}  // namespace

std::size_t split_at_crossings(Bars& bars, double light_mm, double layer_mm, CrossingCutStats* stats, double link_width) {
  if (stats) *stats = CrossingCutStats{};
  const std::vector<Bar> before = bars.bars;
  const std::size_t n = before.size();
  if (n < 2) return 0;
  // S1 (brief G28): ONE light width for every distance (0 or less: the thinnest bar here).
  double light = light_mm;
  if (!(light > 0.0)) {
    light = std::numeric_limits<double>::infinity();
    for (const Bar& b : before) light = std::min(light, b.width);
    if (!std::isfinite(light)) light = 0.0;
  }
  // The bars sorted into a grid, to find the pairs that may come close.
  const double pitch = 2.0;
  auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
  std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
  for (std::size_t i = 0; i < n; ++i) {
    const Bar& b = before[i];
    for (long long x = slot(std::min(b.a.x, b.b.x) - light); x <= slot(std::max(b.a.x, b.b.x) + light); ++x)
      for (long long y = slot(std::min(b.a.y, b.b.y) - light); y <= slot(std::max(b.a.y, b.b.y) + light); ++y)
        for (long long z = slot(std::min(b.a.z, b.b.z) - light); z <= slot(std::max(b.a.z, b.b.z) + light); ++z)
          grid[{x, y, z}].push_back(i);
  }
  std::vector<std::pair<std::size_t, std::size_t>> pairs;
  for (const auto& cell : grid)
    for (std::size_t a = 0; a < cell.second.size(); ++a)
      for (std::size_t b = a + 1; b < cell.second.size(); ++b) pairs.push_back({cell.second[a], cell.second[b]});
  std::sort(pairs.begin(), pairs.end());
  pairs.erase(std::unique(pairs.begin(), pairs.end()), pairs.end());
  // The joints, each once: two found within a hundredth of a micron of each other are one.
  std::map<PointKey, Vec3> joints;
  auto joint_at = [&](const Vec3& p) {
    const PointKey k = key_of(p);
    for (long long dx = -1; dx <= 1; ++dx)
      for (long long dy = -1; dy <= 1; ++dy)
        for (long long dz = -1; dz <= 1; ++dz) {
          const auto it = joints.find({k.x + dx, k.y + dy, k.z + dz});
          if (it == joints.end()) continue;
          const Vec3& q = it->second;
          if ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z) <= kSame * kSame) return q;
        }
    joints.emplace(k, p);
    return p;
  };
  auto d3 = [](const Vec3& a, const Vec3& b) {
    return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z));
  };
  // Where p projects onto bar b's own line (0 at a, 1 at b; not held to 0 .. 1), and its distance from the bar.
  auto along = [](const Bar& b, const Vec3& p) {
    const Vec3 d{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
    const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
    return l2 > 0.0 ? ((p.x - b.a.x) * d.x + (p.y - b.a.y) * d.y + (p.z - b.a.z) * d.z) / l2 : 0.0;
  };
  auto off_bar = [&](const Bar& b, const Vec3& p) {
    const double u = std::clamp(along(b, p), 0.0, 1.0);
    return d3(p, Vec3{b.a.x + (b.b.x - b.a.x) * u, b.a.y + (b.b.y - b.a.y) * u, b.a.z + (b.b.z - b.a.z) * u});
  };
  auto tie_h = [](const Bar& b) { return 0.5 * (b.a.z + b.b.z); };   // a level tie's height (build direction +z)
  struct Cut { double s; Vec3 at; };
  std::vector<std::vector<Cut>> cuts(n);
  std::map<PointKey, int> ends_at;   // how many bars end at each point, as found
  for (const Bar& b : before) { ++ends_at[key_of(b.a)]; ++ends_at[key_of(b.b)]; }
  // S7 (brief G28, the lead's ruling): ONE connection per pair of strands. The contacts (S1; links never; two bars of
  // one strand never) are grouped by the unordered pair of their strands; within a group, smallest closest approach
  // first (ties: lower bar numbers first), a contact is kept only more than 10 x the light width (straight line, from
  // the middle of its two closest points) from every contact already kept for that pair.
  struct Contact { std::size_t i, j; double s, t, d; Vec3 at; };
  std::map<std::pair<int, int>, std::vector<Contact>> by_strands;
  std::size_t found = 0;
  for (const auto& [i, j] : pairs) {
    const Bar &x = before[i], &y = before[j];
    if (x.link || y.link) continue;   // S6: a link is never cut here and takes no part in the pair test
    if (x.strand >= 0 && x.strand == y.strand) continue;   // S7: a strand touching itself is left alone
    const PointKey xa = key_of(x.a), xb = key_of(x.b), ya = key_of(y.a), yb = key_of(y.b);
    if (xa == ya || xa == yb || xb == ya || xb == yb) continue;   // they share an end already
    double s = 0.0, t = 0.0;
    const double d = closest(x.a, x.b, y.a, y.b, &s, &t);
    if (d > light) continue;   // S1
    if (x.level_tie && y.level_tie && std::fabs(tie_h(x) - tie_h(y)) > 0.25 * layer_mm) continue;   // S2
    const Vec3 px{x.a.x + (x.b.x - x.a.x) * s, x.a.y + (x.b.y - x.a.y) * s, x.a.z + (x.b.z - x.a.z) * s};
    const Vec3 py{y.a.x + (y.b.x - y.a.x) * t, y.a.y + (y.b.y - y.a.y) * t, y.a.z + (y.b.z - y.a.z) * t};
    by_strands[{std::min(x.strand, y.strand), std::max(x.strand, y.strand)}].push_back(
        {i, j, s, t, d, Vec3{0.5 * (px.x + py.x), 0.5 * (px.y + py.y), 0.5 * (px.z + py.z)}});
    ++found;
  }
  std::vector<Contact> kept;
  for (auto& kv : by_strands) {
    std::vector<Contact>& g = kv.second;
    std::sort(g.begin(), g.end(), [](const Contact& p, const Contact& q) {
      return std::tie(p.d, p.i, p.j) < std::tie(q.d, q.i, q.j);
    });
    const std::size_t first = kept.size();
    for (const Contact& c : g) {
      bool far = true;
      for (std::size_t k = first; k < kept.size() && far; ++k) far = d3(c.at, kept[k].at) > 10.0 * light;
      if (far) kept.push_back(c);
    }
  }
  std::sort(kept.begin(), kept.end(), [](const Contact& p, const Contact& q) { return std::tie(p.i, p.j) < std::tie(q.i, q.j); });
  if (stats) { stats->contacts = found; stats->strand_pairs = by_strands.size(); stats->kept = kept.size(); }
  int next_strand = -1;   // S7: each link its own strand number, above every strand number here
  for (const Bar& b : before) next_strand = std::max(next_strand, b.strand);
  ++next_strand;
  std::vector<Bar> links;   // S6
  for (const Contact& c : kept) {
    const std::size_t i = c.i, j = c.j;
    const Bar &x = before[i], &y = before[j];
    const PointKey xa = key_of(x.a), xb = key_of(x.b), ya = key_of(y.a), yb = key_of(y.b);
    // S6: each bar is cut at its OWN closest point; S3 per bar: onto one of its own ends that is a strand vertex (two or
    // more bars end there) when within 0.1 x the light width, along that bar only.
    auto own_cut = [&](const Bar& b, const PointKey& ka, const PointKey& kb, double& u) {
      Vec3 p{b.a.x + (b.b.x - b.a.x) * u, b.a.y + (b.b.y - b.a.y) * u, b.a.z + (b.b.z - b.a.z) * u};
      if (u <= 0.0) { u = 0.0; return b.a; }
      if (u >= 1.0) { u = 1.0; return b.b; }
      const double reach = 0.1 * light;
      const double da = d3(p, b.a), db = d3(p, b.b);
      const auto ma = ends_at.find(ka), mb = ends_at.find(kb);
      const bool va = ma != ends_at.end() && ma->second >= 2 && da <= reach;
      const bool vb = mb != ends_at.end() && mb->second >= 2 && db <= reach;
      if (va && (!vb || da <= db)) { u = 0.0; return b.a; }
      if (vb) { u = 1.0; return b.b; }
      return p;
    };
    double sx = c.s, sy = c.t;
    const Vec3 cx = own_cut(x, xa, xb, sx), cy = own_cut(y, ya, yb, sy);
    const Vec3 jx = joint_at(cx), jy = joint_at(cy);   // within 1e-5 mm of each other: one joint
    cuts[i].push_back({sx, jx});
    cuts[j].push_back({sy, jy});
    if (!(key_of(jx) == key_of(jy)) && d3(jx, jy) > kSame) {   // S6: one straight link between the two cut points
      Bar l = x;
      l.a = jx; l.b = jy;
      // S8: link_width x the thinner of the two (their widths after width by stress), between light and the thicker.
      l.width = std::max(light, std::min(link_width * std::min(x.width, y.width), std::max(x.width, y.width)));
      l.end_a = l.end_b = Bar::End::Node;
      l.into_a = l.into_b = -1;
      l.piece = false; l.skin = false; l.net = false; l.support = false; l.level_tie = false;
      l.link = true;
      l.strand = next_strand++;   // S7: its own strand (the region is the lower-numbered bar's)
      links.push_back(l);
      if (stats) {
        const double len = d3(jx, jy);
        ++stats->links;
        stats->links_mm += len;
        stats->link_max_mm = std::max(stats->link_max_mm, len);
        if (l.width <= light + 1e-9) ++stats->links_light; else ++stats->links_wider;
        stats->link_width_max_mm = std::max(stats->link_width_max_mm, l.width);
      }
    }
  }
  if (joints.empty()) return 0;
  std::vector<Bar> out;
  out.reserve(n + 2 * joints.size());
  auto backwards = [&](const Bar& piece, const Bar& own) {
    const double d = (piece.b.x - piece.a.x) * (own.b.x - own.a.x) + (piece.b.y - piece.a.y) * (own.b.y - own.a.y) +
                     (piece.b.z - piece.a.z) * (own.b.z - own.a.z);
    // beyond rounding: a piece square to its bar (two joints at one place along it) is not backwards
    return d < -1e-9 * std::sqrt(d3(piece.a, piece.b) * d3(piece.a, piece.b) * d3(own.a, own.b) * d3(own.a, own.b));
  };
  for (std::size_t i = 0; i < n; ++i) {
    Bar bar = before[i];
    std::vector<Cut>& c = cuts[i];
    std::stable_sort(c.begin(), c.end(), [](const Cut& p, const Cut& q) { return p.s < q.s; });
    // A joint at (or past) the bar's own end moves that end onto it: it lands there.
    std::vector<Vec3> inner;
    for (const Cut& k : c) {
      if (k.s <= 0.0) { bar.a = k.at; bar.end_a = Bar::End::Node; bar.into_a = -1; continue; }
      if (k.s >= 1.0) { bar.b = k.at; bar.end_b = Bar::End::Node; bar.into_b = -1; continue; }
      if (!inner.empty() && key_of(inner.back()) == key_of(k.at)) continue;
      inner.push_back(k.at);
    }
    const std::size_t first = out.size();
    std::size_t made = 0;
    Vec3 from = bar.a;
    Bar::End from_end = bar.end_a;
    int from_into = bar.into_a;
    for (const Vec3& p : inner) {
      if (key_of(p) == key_of(from)) continue;
      Bar piece = bar;
      piece.a = from; piece.end_a = from_end; piece.into_a = from_into;
      piece.b = p; piece.end_b = Bar::End::Node; piece.into_b = -1;
      out.push_back(piece);
      ++made;
      from = p;
      from_end = Bar::End::Node;
      from_into = -1;
    }
    if (key_of(from) == key_of(bar.b) && made > 0) {   // the last joint fell on the far end
      out.back().b = bar.b; out.back().end_b = bar.end_b; out.back().into_b = bar.into_b;
    } else {
      bar.a = from; bar.end_a = from_end; bar.into_a = from_into;
      out.push_back(bar);
    }
    if (stats)   // S5: a piece that runs backwards along its own bar; a piece's end off its own bar's line
      for (std::size_t q = first; q < out.size(); ++q) {
        stats->backwards += backwards(out[q], before[i]) ? 1 : 0;
        const double off = std::max(off_bar(before[i], out[q].a), off_bar(before[i], out[q].b));
        stats->off_line_max_mm = std::max(stats->off_line_max_mm, off);
        stats->off_line += off > 1e-6 ? 1 : 0;
      }
  }
  out.insert(out.end(), links.begin(), links.end());   // S6: the links, after every cut bar
  bars.bars.swap(out);
  return joints.size();
}


std::size_t merge_repeated_bars(Bars& bars, const std::vector<int>& regions) {
  const std::size_t n = bars.bars.size();
  auto ours = [&](const Bar& b) { return std::find(regions.begin(), regions.end(), b.region) != regions.end(); };
  // Each end of a bar of `regions` to one point id: ends within kSame of a point already seen are that point.
  std::map<PointKey, std::vector<std::pair<Vec3, std::size_t>>> seen;
  std::size_t points = 0;
  auto point_of = [&](const Vec3& p) {
    const PointKey k = key_of(p);
    for (long long dx = -1; dx <= 1; ++dx)
      for (long long dy = -1; dy <= 1; ++dy)
        for (long long dz = -1; dz <= 1; ++dz) {
          const auto it = seen.find({k.x + dx, k.y + dy, k.z + dz});
          if (it == seen.end()) continue;
          for (const auto& [q, id] : it->second)
            if ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z) <= kSame * kSame) return id;
        }
    seen[k].push_back({p, points});
    return points++;
  };
  std::map<std::pair<std::size_t, std::size_t>, std::vector<std::size_t>> by_ends;   // in list order
  std::vector<std::size_t> id_a(n, 0);
  for (std::size_t i = 0; i < n; ++i) {
    const Bar& b = bars.bars[i];
    if (!ours(b)) continue;
    const std::size_t pa = point_of(b.a), pb = point_of(b.b);
    id_a[i] = pa;
    if (pa == pb) continue;
    by_ends[{std::min(pa, pb), std::max(pa, pb)}].push_back(i);
  }
  std::vector<int> into_kept(n, -1);   // a repeat merged away: the bar kept in its place
  std::size_t merged = 0;
  for (const auto& kv : by_ends) {
    const std::vector<std::size_t>& g = kv.second;
    if (g.size() < 2) continue;
    for (std::size_t q = 1; q < g.size(); ++q) into_kept[g[q]] = static_cast<int>(g[0]);
    merged += g.size() - 1;
  }
  if (merged == 0) return 0;
  // The bar kept: the widest width; at each of its ends the best-landed tag of the repeats there.
  auto rank = [](Bar::End e) {
    switch (e) {
      case Bar::End::Solid: return 0;
      case Bar::End::Joined: return 1;
      case Bar::End::Node: return 2;
      case Bar::End::Surface: return 3;
      case Bar::End::Loose: return 4;
    }
    return 5;
  };
  for (const auto& kv : by_ends) {
    const std::vector<std::size_t>& g = kv.second;
    if (g.size() < 2) continue;
    Bar kept = bars.bars[g[0]];
    auto in_group = [&](int into) {
      return into >= 0 && std::find(g.begin(), g.end(), static_cast<std::size_t>(into)) != g.end();
    };
    for (int e = 0; e < 2; ++e) {
      Bar::End best = e == 0 ? kept.end_a : kept.end_b;
      int best_into = e == 0 ? kept.into_a : kept.into_b;
      if (best == Bar::End::Joined && in_group(best_into)) best = Bar::End::Node, best_into = -1;
      for (std::size_t q = 1; q < g.size(); ++q) {
        const Bar& r = bars.bars[g[q]];
        // r's end at the kept bar's end e: the same point, whichever way round r runs.
        const bool r_a = (e == 0) == (id_a[g[q]] == id_a[g[0]]);
        Bar::End te = r_a ? r.end_a : r.end_b;
        int ti = r_a ? r.into_a : r.into_b;
        if (te == Bar::End::Joined && in_group(ti)) te = Bar::End::Node, ti = -1;
        if (rank(te) < rank(best)) { best = te; best_into = ti; }
      }
      (e == 0 ? kept.end_a : kept.end_b) = best;
      (e == 0 ? kept.into_a : kept.into_b) = best == Bar::End::Joined ? best_into : -1;
    }
    for (std::size_t q = 1; q < g.size(); ++q) kept.width = std::max(kept.width, bars.bars[g[q]].width);
    bars.bars[g[0]] = kept;
  }
  std::vector<char> keep(n, 1);
  for (std::size_t i = 0; i < n; ++i) keep[i] = into_kept[i] < 0;
  // A Joined end that landed in a repeat lands in the bar kept in its place (keep_only then renumbers it).
  for (Bar& b : bars.bars) {
    if (b.into_a >= 0 && static_cast<std::size_t>(b.into_a) < n && into_kept[static_cast<std::size_t>(b.into_a)] >= 0)
      b.into_a = into_kept[static_cast<std::size_t>(b.into_a)];
    if (b.into_b >= 0 && static_cast<std::size_t>(b.into_b) < n && into_kept[static_cast<std::size_t>(b.into_b)] >= 0)
      b.into_b = into_kept[static_cast<std::size_t>(b.into_b)];
  }
  const std::size_t dropped = bars.dropped;
  keep_only(bars, keep);
  bars.dropped = dropped;   // not drop_loose_bars' count
  bars.repeats += merged;
  return merged;
}

}  // namespace topopt::lattice_layout
