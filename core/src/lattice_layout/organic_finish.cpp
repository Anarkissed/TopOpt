// Lattice rebuild, Organic: the net skin (O16), Finish Skin on a weave region. See lattice_layout_organic.hpp.
// The old finish step (organic_lattice.cpp, "THE NET-SKIN") is read for its rules and numbers only; nothing of it is
// called. Its constants are the old header's own, so the numbers cannot drift.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <set>
#include <utility>

#include "topopt/organic_lattice.hpp"

namespace topopt::lattice_layout {
namespace {

constexpr int kNetDegree = 3;            // the old OrganicLattice::net_skin_degree
constexpr double kNetFallbackReach = 1.5;  // the old fallback's partner reach, in reaches
constexpr double kHair = 0.02;           // mm: a point a hair inside the surface (as finish_bar_ends reads past an end)

double dist(const Vec3& a, const Vec3& b) {
  return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z));
}
Vec3 lerp(const Vec3& a, const Vec3& b, double t) {
  return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t};
}
double to_segment2(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t =
      l2 > 0.0 ? std::clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  const Vec3 q = lerp(a, b, t);
  return (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z);
}
using Key = std::array<double, 3>;
Key key_of(const Vec3& p) { return {p.x, p.y, p.z}; }

}  // namespace

std::size_t lay_net_skin(Bars& bars, const Domain& domain, const std::vector<std::pair<int, double>>& reach_of,
                         double width_mm) {
  const Domain::Probe probe = domain.probe();
  const PartMeasure::Probe& part = probe.part();
  // The surface's inward normal at `p`: the depth's gradient, read `h` either side (the old sdf_normal at 2 r).
  auto normal_in = [&](const Vec3& p, double h) {
    const Vec3 g{part.depth({p.x + h, p.y, p.z}) - part.depth({p.x - h, p.y, p.z}),
                 part.depth({p.x, p.y + h, p.z}) - part.depth({p.x, p.y - h, p.z}),
                 part.depth({p.x, p.y, p.z + h}) - part.depth({p.x, p.y, p.z - h})};
    const double n = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
    return n > 1e-12 ? Vec3{g.x / n, g.y / n, g.z / n} : Vec3{0.0, 0.0, 0.0};
  };
  // Is the part's surface nearest `p` an open face of `region`: a hair inside it, lattice of the region?
  auto open_face = [&](const Vec3& p, double depth, const Vec3& n, int region) {
    if (!(n.x * n.x + n.y * n.y + n.z * n.z > 0.25)) return false;
    const Vec3 q{p.x - n.x * (depth - kHair), p.y - n.y * (depth - kHair), p.z - n.z * (depth - kHair)};
    const Where w = probe.where(q);
    return w.lattice() && w.id == region;
  };
  // Every bar's two ends, as joined already; and the bars by place, for "buried".
  std::set<std::pair<Key, Key>> joined;
  auto pair_of = [](const Vec3& a, const Vec3& b) {
    Key ka = key_of(a), kb = key_of(b);
    if (kb < ka) std::swap(ka, kb);
    return std::make_pair(ka, kb);
  };
  for (const Bar& b : bars.bars) joined.insert(pair_of(b.a, b.b));
  std::size_t made = 0;
  for (const std::pair<int, double>& asked : reach_of) {
    const int region = asked.first;
    const double reach = asked.second;
    if (!(reach > 0.0)) continue;
    const double band = kOrganicFinishBandRatio * reach;
    // The landings: each place once, its thinnest width, and the cut ends on the surface that are there.
    struct Landing { Vec3 p; double width; Vec3 n; std::vector<std::pair<std::size_t, int>> surface; };
    std::map<Key, Landing> at;
    const std::size_t laid = bars.bars.size();
    for (std::size_t i = 0; i < laid; ++i) {
      const Bar& b = bars.bars[i];
      if (b.region != region || b.net) continue;
      for (int e = 0; e < 2; ++e) {
        const Vec3& p = e ? b.b : b.a;
        auto it = at.find(key_of(p));
        if (it == at.end()) {
          const double r = 0.5 * b.width;
          const double d = part.depth(p);
          if (d > r + band) continue;
          const Vec3 n = normal_in(p, std::max(r, 1e-4));
          if (!open_face(p, d, n, region)) continue;
          it = at.emplace(key_of(p), Landing{p, b.width, n, {}}).first;
        }
        it->second.width = std::min(it->second.width, b.width);
        if ((e ? b.end_b : b.end_a) == Bar::End::Surface) it->second.surface.push_back({i, e});
      }
    }
    std::vector<Landing> L;
    L.reserve(at.size());
    for (auto& kv : at) L.push_back(std::move(kv.second));   // in place order (x, then y, then z), as the old sorted them
    if (L.size() < 2) continue;
    // The bars by place, for "buried" (the old test: every one of 7 points along the join inside an existing bar).
    const double cell = std::max(reach, 0.5);
    auto slot = [&](double x) { return static_cast<long long>(std::floor(x / cell)); };
    std::map<std::array<long long, 3>, std::vector<std::size_t>> bar_grid;
    for (std::size_t i = 0; i < laid; ++i) {
      const Bar& b = bars.bars[i];
      const double r = 0.5 * b.width;
      for (long long x = slot(std::min(b.a.x, b.b.x) - r); x <= slot(std::max(b.a.x, b.b.x) + r); ++x)
        for (long long y = slot(std::min(b.a.y, b.b.y) - r); y <= slot(std::max(b.a.y, b.b.y) + r); ++y)
          for (long long z = slot(std::min(b.a.z, b.b.z) - r); z <= slot(std::max(b.a.z, b.b.z) + r); ++z)
            bar_grid[{x, y, z}].push_back(i);
    }
    auto inside_a_bar = [&](const Vec3& p) {
      const auto it = bar_grid.find({slot(p.x), slot(p.y), slot(p.z)});
      if (it == bar_grid.end()) return false;
      for (std::size_t i : it->second) {
        const Bar& b = bars.bars[i];
        if (to_segment2(p, b.a, b.b) <= 0.25 * b.width * b.width) return true;
      }
      return false;
    };
    auto buried = [&](const Vec3& a, const Vec3& b) {
      for (int k = 0; k <= 6; ++k)
        if (!inside_a_bar(lerp(a, b, k / 6.0))) return false;
      return true;
    };
    // It stays on the region: each inner point is lattice of the region, or within the join's half width of the
    // region's open face.
    auto on_region = [&](const Vec3& a, const Vec3& b, double r) {
      for (int k = 1; k <= 5; ++k) {
        const Vec3 s = lerp(a, b, k / 6.0);
        const Where w = probe.where(s);
        if (w.lattice() && w.id == region) continue;
        const double d = part.depth(s);
        if (std::fabs(d) <= r && open_face(s, d, normal_in(s, std::max(r, 1e-4)), region)) continue;
        return false;
      }
      return true;
    };
    auto fits = [&](std::size_t i, std::size_t j, double lo, double hi) {
      const double d = dist(L[i].p, L[j].p);
      if (d < lo || d > hi) return false;
      if (joined.count(pair_of(L[i].p, L[j].p))) return false;
      const Vec3 &ni = L[i].n, &nj = L[j].n;
      if (ni.x * nj.x + ni.y * nj.y + ni.z * nj.z < kOrganicFinishCoplanarCos) return false;   // would cut the corner
      if (buried(L[i].p, L[j].p)) return false;
      return on_region(L[i].p, L[j].p, 0.5 * std::min(L[i].width, L[j].width));
    };
    std::map<std::array<long long, 3>, std::vector<std::size_t>> land_grid;
    auto lslot = [&](double x) { return static_cast<long long>(std::floor(x / reach)); };
    for (std::size_t i = 0; i < L.size(); ++i) land_grid[{lslot(L[i].p.x), lslot(L[i].p.y), lslot(L[i].p.z)}].push_back(i);
    auto near = [&](std::size_t i, int span) {
      std::vector<std::size_t> out;
      const Vec3& p = L[i].p;
      for (long long x = lslot(p.x) - span; x <= lslot(p.x) + span; ++x)
        for (long long y = lslot(p.y) - span; y <= lslot(p.y) + span; ++y)
          for (long long z = lslot(p.z) - span; z <= lslot(p.z) + span; ++z) {
            const auto it = land_grid.find({x, y, z});
            if (it == land_grid.end()) continue;
            for (std::size_t j : it->second)
              if (j != i) out.push_back(j);
          }
      std::sort(out.begin(), out.end());
      return out;
    };
    std::vector<int> deg(L.size(), 0);
    std::vector<int> into(L.size(), -1);   // the first net strut at each landing
    auto join = [&](std::size_t i, std::size_t j) {
      Bar net;
      net.a = L[i].p;
      net.b = L[j].p;
      net.width = width_mm > 0.0 ? width_mm : std::min(L[i].width, L[j].width);
      net.cell = reach;
      net.region = region;
      net.net = true;
      net.end_a = net.end_b = Bar::End::Node;
      const int at_bar = static_cast<int>(bars.bars.size());
      bars.bars.push_back(net);
      joined.insert(pair_of(L[i].p, L[j].p));
      for (std::size_t k : {i, j}) {
        ++deg[k];
        if (into[k] < 0) into[k] = at_bar;
      }
      ++made;
    };
    // Each landing's own shortlist: its 3 nearest partners, nearest first (ties by place order).
    std::vector<std::vector<std::size_t>> want(L.size());
    for (std::size_t i = 0; i < L.size(); ++i) {
      std::vector<std::pair<double, std::size_t>> cand;
      for (std::size_t j : near(i, 1))
        if (fits(i, j, kOrganicFinishMinSpanRatio * reach, reach)) cand.push_back({dist(L[i].p, L[j].p), j});
      std::sort(cand.begin(), cand.end());
      if (cand.size() > static_cast<std::size_t>(kNetDegree)) cand.resize(kNetDegree);
      for (const auto& c : cand) want[i].push_back(c.second);
    }
    // Mutual: a pair wanted both ways.
    for (std::size_t i = 0; i < L.size(); ++i)
      for (std::size_t j : want[i]) {
        if (j < i) continue;
        if (std::find(want[j].begin(), want[j].end(), i) == want[j].end()) continue;
        if (joined.count(pair_of(L[i].p, L[j].p))) continue;
        join(i, j);
      }
    // Every landing short of one join, then of two, takes its nearest partner within 1.5 reach.
    for (int need = 1; need <= 2; ++need)
      for (std::size_t i = 0; i < L.size(); ++i) {
        if (deg[i] >= need) continue;
        double best_d = 0.0;
        std::size_t best = L.size();
        for (std::size_t j : near(i, 2)) {
          if (!fits(i, j, kOrganicFinishMinSpanRatio * reach, kNetFallbackReach * reach * (1.0 - 1e-12))) continue;
          const double d = dist(L[i].p, L[j].p);
          if (best == L.size() || d < best_d) { best = j; best_d = d; }
        }
        if (best < L.size()) join(i, best);
      }
    // A cut end on the surface that a net strut reaches has landed.
    for (std::size_t i = 0; i < L.size(); ++i) {
      if (into[i] < 0) continue;
      for (const auto& [bar, end] : L[i].surface) {
        (end ? bars.bars[bar].end_b : bars.bars[bar].end_a) = Bar::End::Joined;
        (end ? bars.bars[bar].into_b : bars.bars[bar].into_a) = into[i];
      }
    }
  }
  return made;
}

}  // namespace topopt::lattice_layout
