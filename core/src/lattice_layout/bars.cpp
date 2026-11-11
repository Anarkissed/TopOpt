// Lattice rebuild, stage D: the bars (rules S4, S11). See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <map>
#include <memory>
#include <thread>

#include "topopt/strut_cell.hpp"

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

Bars lay_bars(const Layout& layout, const Domain& domain, int threads) {
  const StrutCell& type = lattice_strut_cell(layout.topology);   // throws for a type with none
  const std::vector<StrutCellStrut> struts = strut_cell_closed_struts(type);
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));

  struct Found { std::vector<Bar> bars; std::size_t stubs = 0; };
  std::vector<Found> per_cell(layout.cells.size());
  std::atomic<std::size_t> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    for (std::size_t ci = next.fetch_add(1); ci < layout.cells.size(); ci = next.fetch_add(1)) {
      const Cell& c = layout.cells[ci];
      const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
      const WallMap& walls = layout.walls[static_cast<std::size_t>(c.frame)];
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
        const Reading r = read_at(probe, f, walls, q[0], q[1], q[2]);
        const bool yes = r.where.lattice() && r.where.id == c.region && (!walls.flat || r.wall == c.wall);
        node_read.emplace(k, yes);
        return yes;
      };
      for (const StrutCellStrut& s : struts) {
        const double qa[3] = {c.lo[0] + s.a.x * unit, c.lo[1] + s.a.y * unit, c.lo[2] + s.a.z * unit};
        const double qb[3] = {c.lo[0] + s.b.x * unit, c.lo[1] + s.b.y * unit, c.lo[2] + s.b.z * unit};
        const Vec3 a = f.at(qa[0], qa[1], qa[2]), b = f.at(qb[0], qb[1], qb[2]);
        const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z};
        const double length = std::sqrt(ab.x * ab.x + ab.y * ab.y + ab.z * ab.z);
        const Vec3 dir{ab.x / length, ab.y / length, ab.z / length};
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
          const Reading r = read_at(probe, f, walls, q[0], q[1], q[2]);
          return r.where.lattice() && r.where.id == c.region && (!walls.flat || r.wall == c.wall);
        };
        Bar bar;
        bar.width = c.strut;
        bar.cell = c.size;
        bar.region = c.region;
        // A strut whose two ends and middle are the cell's, in a cell the layout found
        // whole, is whole. (The layout's own "whole" is not enough: it looks a sixth of
        // the cell in from each face, and an edge can pass nearer the face than that.)
        if (!c.cut && node_is_mine(s.a) && node_is_mine(s.b) && mine(0.5)) {
          bar.a = a;
          bar.b = b;
          out.bars.push_back(bar);
          continue;
        }
        // What lies just past a cut end, a little farther along the strut.
        auto past = [&](double t, double step) {
          double q[3];
          inward(std::clamp(t + step / length, 0.0, 1.0), q);
          const Where w = probe.where(f.at(q[0], q[1], q[2]));
          if (w.why == Why::Outside) return Bar::End::Surface;
          return w.lattice() ? Bar::End::Loose : Bar::End::Solid;
        };
        const int n = std::clamp(static_cast<int>(std::ceil(length / kStep)), 6, 24);
        std::vector<char> in(static_cast<std::size_t>(n) + 1);
        for (int i = 0; i <= n; ++i) in[static_cast<std::size_t>(i)] = mine(static_cast<double>(i) / n);
        // Between a point that is the cell's and its neighbour that is not: where it changes.
        auto edge = [&](double t_in, double t_out) {
          for (int k = 0; k < 12; ++k) {
            const double m = 0.5 * (t_in + t_out);
            if (mine(m)) t_in = m; else t_out = m;
          }
          return t_in;
        };
        for (int i = 0; i <= n; ++i) {
          if (!in[static_cast<std::size_t>(i)]) continue;
          int j = i;
          while (j < n && in[static_cast<std::size_t>(j) + 1]) ++j;
          double t0 = static_cast<double>(i) / n, t1 = static_cast<double>(j) / n;
          Bar piece = bar;
          piece.piece = i > 0 || j < n;
          // A bar the part's surface cuts ends ON the surface (S11). The cell's shape was
          // read a hair inside the cell, so the end found is within that hair of the
          // surface: the strut's own line is now followed to the surface itself, between
          // a point a tenth of a millimetre back (in the part) and one as far on (not).
          auto to_surface = [&](double t_edge, double sign) {
            auto in_part = [&](double t) {
              return probe.part().depth(Vec3{a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t}) >= -1e-7;
            };
            double in_t = std::clamp(t_edge - sign * 0.1 / length, 0.0, 1.0);
            double out_t = std::clamp(t_edge + sign * 0.1 / length, 0.0, 1.0);
            if (!in_part(in_t) || in_part(out_t)) return t_edge;
            for (int k = 0; k < 26; ++k) {
              const double m = 0.5 * (in_t + out_t);
              if (in_part(m)) in_t = m; else out_t = m;
            }
            return in_t;
          };
          if (i > 0) {
            t0 = edge(t0, static_cast<double>(i - 1) / n);
            piece.end_a = past(t0, -3.0 * kInward);
            if (piece.end_a == Bar::End::Surface) t0 = to_surface(t0, -1.0);
          }
          if (j < n) {
            t1 = edge(t1, static_cast<double>(j + 1) / n);
            piece.end_b = past(t1, 3.0 * kInward);
            if (piece.end_b == Bar::End::Surface) t1 = to_surface(t1, 1.0);
          }
          i = j;
          if ((t1 - t0) * length < c.strut) {   // S4: a stub shorter than one strut width
            if (piece.piece) { ++out.stubs; continue; }
          }
          // S11: where the solid begins the bar runs on into it by its own width.
          if (piece.end_a == Bar::End::Solid) t0 = std::max(0.0, t0 - c.strut / length);
          if (piece.end_b == Bar::End::Solid) t1 = std::min(1.0, t1 + c.strut / length);
          piece.a = Vec3{a.x + dir.x * t0 * length, a.y + dir.y * t0 * length, a.z + dir.z * t0 * length};
          piece.b = Vec3{a.x + dir.x * t1 * length, a.y + dir.y * t1 * length, a.z + dir.z * t1 * length};
          if (t0 == 0.0) piece.a = a;   // a node, exactly
          if (t1 == 1.0) piece.b = b;
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

std::size_t join_loose_bars(Bars& bars, const Domain& domain) {
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
  const Domain::Probe probe = domain.probe();
  std::size_t joined = 0;
  std::vector<std::size_t> near;
  for (std::size_t i = 0; i < before.size(); ++i)
    for (int end = 0; end < 2; ++end) {
      const Bar& me = before[i];
      if ((end ? me.end_b : me.end_a) != Bar::End::Loose) continue;
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
      for (std::size_t k : near) {
        if (k == i) continue;
        const Bar& other = before[k];
        double at = 0.0;
        const double gap = approach(p, d, limit, other.a, other.b, &at);
        if (gap > 0.5 * other.width) continue;        // its middle line stays outside that bar
        // Not the bar it is a continuation of (the next piece of the same strut touches
        // it end to end only when nothing lies between them, and that is a join too).
        if (land < 0.0 || at < land) land = at;
      }
      // What the line passes through before that: solid ends it sooner (S11); air ends it.
      const double reach = land >= 0.0 ? land : limit;
      Bar::End kind = land >= 0.0 ? Bar::End::Joined : Bar::End::Loose;
      double stop = reach;
      for (double t = 0.25; t < reach + 0.25; t += 0.25) {
        const double at = std::min(t, reach);
        const Where w = probe.where(Vec3{p.x + d.x * at, p.y + d.y * at, p.z + d.z * at});
        if (w.lattice()) continue;
        double in = at - 0.25 < 0.0 ? 0.0 : at - 0.25, out = at;   // lattice at `in`, not at `out`
        for (int k = 0; k < 12; ++k) {
          const double m = 0.5 * (in + out);
          if (probe.where(Vec3{p.x + d.x * m, p.y + d.y * m, p.z + d.z * m}).lattice()) in = m; else out = m;
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
      Bar& mine = bars.bars[i];
      const Vec3 to{p.x + d.x * stop, p.y + d.y * stop, p.z + d.z * stop};
      if (end) { mine.b = to; mine.end_b = kind; } else { mine.a = to; mine.end_a = kind; }
      if (kind != Bar::End::Surface) ++joined;
    }
  bars.joined += joined;
  return joined;
}

void drop_loose_bars(Bars& bars) {
  // A cut end that lands on nothing: in the air, or loose in the lattice.
  auto lands = [](Bar::End e) {
    return e == Bar::End::Node || e == Bar::End::Solid || e == Bar::End::Joined;
  };
  std::vector<char> keep(bars.bars.size(), 1);
  for (std::size_t i = 0; i < bars.bars.size(); ++i)
    if (!lands(bars.bars[i].end_a) || !lands(bars.bars[i].end_b)) keep[i] = 0;
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
      if (alone_a || alone_b) {
        keep[i] = 0;
        again = true;
      }
    }
  }
  std::vector<Bar> left;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    if (keep[i]) left.push_back(bars.bars[i]);
    else ++bars.dropped;
  }
  bars.bars.swap(left);
}

}  // namespace topopt::lattice_layout
