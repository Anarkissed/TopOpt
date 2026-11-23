// Lattice rebuild, Organic: the net skin (O16), Finish Skin on a weave region. See lattice_layout_organic.hpp.
// The old finish step (organic_lattice.cpp, "THE NET-SKIN") is read for its rules and numbers only; nothing of it is
// called. Its constants are the old header's own, so the numbers cannot drift.
#include "topopt/lattice_layout_organic.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
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
                         double width_mm, const std::vector<double>* widths, const std::vector<double>* gaps,
                         bool keep_apart, std::size_t* kept_apart, const std::vector<int>* densities,
                         const std::vector<double>* sinks, NetSkinReport* report) {
  if (kept_apart) *kept_apart = 0;
  NetSkinReport rep_local;
  NetSkinReport& rep = report ? *report : rep_local;
  rep = NetSkinReport{};
  int next_strand = -1;
  for (const Bar& b : bars.bars) next_strand = std::max(next_strand, b.strand);
  ++next_strand;
  const std::size_t first_net = bars.bars.size();
  std::set<std::size_t> stem_ids;   // OJ8: the stems (not crossed by the net's joints)
  double thinnest_net = 0.0;
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
  for (std::size_t ri = 0; ri < reach_of.size(); ++ri) {
    const std::pair<int, double>& asked = reach_of[ri];
    const double width_here = widths && ri < widths->size() ? (*widths)[ri] : width_mm;   // leg J item 1
    const double gap = gaps && ri < gaps->size() ? (*gaps)[ri] : domain.spec().bead_mm;   // OJ7
    const int degree = densities && ri < densities->size() ? std::clamp((*densities)[ri], 1, 6) : kNetDegree;   // OJ8
    const double sink = sinks && ri < sinks->size() ? std::clamp((*sinks)[ri], 0.0, 1.0) : 0.0;                 // OJ8
    // OJ8 (the lead's ruling 2): density scales the joins asked per landing AND the partner window's upper end:
    // reach x (1 + (density - 3) / 6) up to 3 and x (1 + (density - 3) / 2) above (density 3: the old engine's window,
    // 1 reach; 1: two thirds of it; 6: 2.5 reaches).
    const double span_scale = degree <= 3 ? 1.0 + (static_cast<double>(degree) - 3.0) / 6.0 : 1.0 + (static_cast<double>(degree) - 3.0) / 2.0;
    const int region = asked.first;
    const double reach = asked.second;
    if (!(reach > 0.0)) continue;
    const double band = kOrganicFinishBandRatio * reach;
    // The landings: each place once, its thinnest width, and the cut ends on the surface that are there.
    struct Landing { Vec3 p; double width; Vec3 n; double depth; std::vector<std::pair<std::size_t, int>> surface; };
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
          it = at.emplace(key_of(p), Landing{p, b.width, n, d, {}}).first;
        }
        it->second.width = std::min(it->second.width, b.width);
        if ((e ? b.end_b : b.end_a) == Bar::End::Surface) it->second.surface.push_back({i, e});
      }
    }
    std::vector<Landing> L;
    L.reserve(at.size());
    for (auto& kv : at) L.push_back(std::move(kv.second));   // in place order (x, then y, then z), as the old sorted them
    if (L.size() < 2) continue;
    // OJ8 (leg M; the owner: "the cutting along the plane ... That's what gives it's unique feel"): the net lies ON the
    // open face. Each landing's FOOT: its nearest point of the face (along the face's normal there), sunk by `sink` x the
    // net's radius (0: the centre line on the face, the tube's outer half cut flat by the face's plane in the file; 1:
    // one radius in, the tube touching the face, the old engine's geometry).
    std::vector<Vec3> foot(L.size());
    for (std::size_t i = 0; i < L.size(); ++i) {
      const double w = width_here > 0.0 ? width_here : L[i].width;
      const double down = L[i].depth - sink * 0.5 * w;   // from the node to its foot, along -n
      foot[i] = Vec3{L[i].p.x - L[i].n.x * down, L[i].p.y - L[i].n.y * down, L[i].p.z - L[i].n.z * down};
    }
    // Landings one above another share ONE foot (within a quarter of the thinner width): the shallower landing's (the
    // first in place order among equals); a join between two landings of one foot is not laid.
    {
      std::map<std::array<long long, 3>, std::vector<std::size_t>> fg;
      const double fc = 0.5;
      auto fk = [&](const Vec3& q) {
        return std::array<long long, 3>{static_cast<long long>(std::floor(q.x / fc)), static_cast<long long>(std::floor(q.y / fc)),
                                        static_cast<long long>(std::floor(q.z / fc))};
      };
      std::vector<std::size_t> order(L.size());
      for (std::size_t i = 0; i < L.size(); ++i) order[i] = i;
      std::stable_sort(order.begin(), order.end(), [&](std::size_t x, std::size_t y) { return L[x].depth < L[y].depth; });
      for (std::size_t i : order) {
        const auto k = fk(foot[i]);
        bool merged = false;
        for (long long dx = -1; dx <= 1 && !merged; ++dx)
          for (long long dy = -1; dy <= 1 && !merged; ++dy)
            for (long long dz = -1; dz <= 1 && !merged; ++dz) {
              const auto it = fg.find({k[0] + dx, k[1] + dy, k[2] + dz});
              if (it == fg.end()) continue;
              for (std::size_t j : it->second)
                if (dist(foot[i], foot[j]) < 0.25 * std::min(L[i].width, L[j].width)) { foot[i] = foot[j]; merged = true; break; }
            }
        if (!merged) fg[k].push_back(i);
      }
    }
    // OJ8 (the lead, 2026-11-19): a net strut and a stem stay within the region's own open face and a line width off
    // every PROTECTED face. `clear(a, b, w, n_in)`: every point of the centre line a to b (each 0.1 mm), read a hair
    // inside the face along `n_in`, is lattice of the region, and the tube (half of `w`) stays a line width from the
    // nearest protected face (by the distance to its own triangles). A landing whose stem is not clear is not used
    // (its foot is not); a join that is not clear is not laid.
    const double line = domain.spec().bead_mm;
    // Speed (his 11-23 "Finishing" wait; the same answer): the distance to the protected faces cannot change by more
    // than the way walked (it is a distance), so a point found clear by a margin m answers for every later point within
    // m of it along the line (less a micrometre for rounding): those are not measured again. A point that is not clear
    // is still found, at the same 0.1 mm points, so every stem and join is judged exactly as before.
    auto clear = [&](const Vec3& a, const Vec3& b, double w, const Vec3& n_in) {
      const double len = dist(a, b);
      const int n = std::max(1, static_cast<int>(std::ceil(len / 0.1)));
      const double floor_gap = line - 1e-9 + 0.5 * w;   // clear: the distance at least this
      double known_to = -1.0;                          // along the line (mm): the distance test passes up to here
      for (int k = 0; k <= n; ++k) {
        const double t = static_cast<double>(k) / n;
        const Vec3 s = lerp(a, b, t);
        const Vec3 q{s.x + n_in.x * kHair, s.y + n_in.y * kHair, s.z + n_in.z * kHair};
        const Where wq = probe.where(q);
        if (!(wq.lattice() && wq.id == region)) return false;
        const double along = t * len;
        if (along <= known_to) continue;
        const double d = probe.protect_face_distance(s);
        if (d - 0.5 * w < line - 1e-9) return false;
        known_to = along + (d - floor_gap) - 1e-6;
      }
      return true;
    };
    std::vector<char> usable(L.size(), 1);
    for (std::size_t i = 0; i < L.size(); ++i) {
      const double w = L[i].width;
      if (!clear(L[i].p, foot[i], w, L[i].n)) { usable[i] = 0; ++rep.landings_not_used; }
    }
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
      if (!usable[i] || !usable[j]) return false;          // OJ8: its stem would not be clear
      if (dist(foot[i], foot[j]) < 1e-9) return false;   // one foot (OJ8)
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
    std::set<std::pair<Key, Key>> feet_joined;   // OJ8: the feet already joined
    rep.landings += L.size();
    // OJ7: the net struts laid in this region, by place, and whether a new join would come too near one of them.
    std::map<std::array<long long, 3>, std::vector<std::size_t>> net_grid;
    const double ncell = std::max(reach, 0.5);
    auto nslot = [&](double x) { return static_cast<long long>(std::floor(x / ncell)); };
    auto seg_dist = [](const Vec3& p1, const Vec3& q1, const Vec3& p2, const Vec3& q2) {
      const Vec3 d1{q1.x - p1.x, q1.y - p1.y, q1.z - p1.z}, d2{q2.x - p2.x, q2.y - p2.y, q2.z - p2.z}, r{p1.x - p2.x, p1.y - p2.y, p1.z - p2.z};
      const double a = d1.x * d1.x + d1.y * d1.y + d1.z * d1.z, e = d2.x * d2.x + d2.y * d2.y + d2.z * d2.z;
      const double f2 = d2.x * r.x + d2.y * r.y + d2.z * r.z, c = d1.x * r.x + d1.y * r.y + d1.z * r.z, b = d1.x * d2.x + d1.y * d2.y + d1.z * d2.z;
      double s = 0.0, t = 0.0;
      const double den = a * e - b * b;
      if (den > 1e-12) s = std::clamp((b * f2 - c * e) / den, 0.0, 1.0);
      t = e > 0.0 ? (b * s + f2) / e : 0.0;
      if (t < 0.0) { t = 0.0; s = a > 0.0 ? std::clamp(-c / a, 0.0, 1.0) : 0.0; }
      else if (t > 1.0) { t = 1.0; s = a > 0.0 ? std::clamp((b - c) / a, 0.0, 1.0) : 0.0; }
      const Vec3 x{p1.x + d1.x * s - p2.x - d2.x * t, p1.y + d1.y * s - p2.y - d2.y * t, p1.z + d1.z * s - p2.z - d2.z * t};
      return std::sqrt(x.x * x.x + x.y * x.y + x.z * x.z);
    };
    auto too_near = [&](std::size_t i, std::size_t j, double w) {
      if (!keep_apart) return false;
      const Vec3 &P = foot[i], &Q = foot[j];
      const Vec3 pq{Q.x - P.x, Q.y - P.y, Q.z - P.z};
      const double lpq = std::sqrt(pq.x * pq.x + pq.y * pq.y + pq.z * pq.z);
      std::set<std::size_t> seen;
      const int n = std::max(1, static_cast<int>(std::ceil(dist(P, Q) / (0.5 * ncell))));   // samples half a cell apart
      for (int k = 0; k <= n; ++k) {
        const Vec3 s = lerp(P, Q, static_cast<double>(k) / n);
        for (long long x = nslot(s.x) - 1; x <= nslot(s.x) + 1; ++x)
          for (long long y = nslot(s.y) - 1; y <= nslot(s.y) + 1; ++y)
            for (long long z = nslot(s.z) - 1; z <= nslot(s.z) + 1; ++z) {
              const auto it = net_grid.find({x, y, z});
              if (it == net_grid.end()) continue;
              for (std::size_t m : it->second) {
                if (!seen.insert(m).second) continue;
                const Bar& o = bars.bars[m];
                const bool shares = key_of(o.a) == key_of(P) || key_of(o.a) == key_of(Q) || key_of(o.b) == key_of(P) || key_of(o.b) == key_of(Q);
                if (!shares && !(seg_dist(P, Q, o.a, o.b) < 0.5 * (w + o.width) + gap - 1e-9)) continue;
                // (two struts leaving one foot within 20 degrees of each other would lie one in the other: skipped too)
                // OJ8: a crossing becomes a joint (after); only a run near-parallel (under 20 degrees) within the gap
                // of a net strut it does not join is skipped.
                const Vec3 od{o.b.x - o.a.x, o.b.y - o.a.y, o.b.z - o.a.z};
                const double lo = std::sqrt(od.x * od.x + od.y * od.y + od.z * od.z);
                // (from one foot, above density 3 the angle narrows as 20 x 3 / density: the denser web)
                const double deg_lim = shares && degree > 3 ? 20.0 * 3.0 / degree : 20.0;
                if (lpq > 0.0 && lo > 0.0 &&
                    std::fabs(pq.x * od.x + pq.y * od.y + pq.z * od.z) / (lpq * lo) > std::cos(deg_lim * 3.14159265358979323846 / 180.0))
                  return true;
              }
            }
      }
      return false;
    };
    auto join = [&](std::size_t i, std::size_t j) {
      if (feet_joined.count(pair_of(foot[i], foot[j]))) return false;   // OJ8: one net strut per two feet
      Bar net;
      net.a = foot[i];   // OJ8: between the landings' feet on the face
      net.b = foot[j];
      net.face_skin = true;
      net.strand = next_strand++;
      feet_joined.insert(pair_of(foot[i], foot[j]));
      net.width = width_here > 0.0 ? width_here : std::min(L[i].width, L[j].width);
      net.cell = reach;
      net.region = region;
      net.net = true;
      net.end_a = net.end_b = Bar::End::Node;
      {   // OJ8: the join stays within the region's outline on the face and a line off every protected face
        Vec3 nm{L[i].n.x + L[j].n.x, L[i].n.y + L[j].n.y, L[i].n.z + L[j].n.z};
        const double nl = std::sqrt(nm.x * nm.x + nm.y * nm.y + nm.z * nm.z);
        if (nl > 1e-12) nm = {nm.x / nl, nm.y / nl, nm.z / nl};
        if (!clear(foot[i], foot[j], net.width, nm)) {
          ++rep.joins_not_clear;
          return false;
        }
      }
      if (too_near(i, j, net.width)) {   // OJ7: kept a gap apart from the net already laid
        if (kept_apart) ++*kept_apart;
        return false;
      }
      const int at_bar = static_cast<int>(bars.bars.size());
      bars.bars.push_back(net);
      if (keep_apart) {
        const int n = std::max(1, static_cast<int>(std::ceil(dist(net.a, net.b) / (0.5 * ncell))));
        std::set<std::array<long long, 3>> cells;
        for (int k = 0; k <= n; ++k) {
          const Vec3 s = lerp(net.a, net.b, static_cast<double>(k) / n);
          cells.insert({nslot(s.x), nslot(s.y), nslot(s.z)});
        }
        for (const auto& cl : cells) net_grid[cl].push_back(static_cast<std::size_t>(at_bar));
      }
      joined.insert(pair_of(L[i].p, L[j].p));
      for (std::size_t k : {i, j}) {
        ++deg[k];
        if (into[k] < 0) into[k] = at_bar;
      }
      ++made;
      return true;
    };
    // Each landing's own shortlist: its 3 nearest partners, nearest first (ties by place order).
    std::vector<std::vector<std::size_t>> want(L.size());
    for (std::size_t i = 0; i < L.size(); ++i) {
      std::vector<std::pair<double, std::size_t>> cand;
      for (std::size_t j : near(i, span_scale > 1.0 ? 4 : 1))
        if (fits(i, j, kOrganicFinishMinSpanRatio * reach, reach * span_scale)) cand.push_back({dist(L[i].p, L[j].p), j});
      std::sort(cand.begin(), cand.end());
      if (cand.size() > static_cast<std::size_t>(degree)) cand.resize(static_cast<std::size_t>(degree));   // OJ8: skin_density
      for (const auto& c : cand) want[i].push_back(c.second);
    }
    // Mutual: a pair wanted both ways (OJ7: shortest first when kept apart).
    {
      std::vector<std::pair<std::size_t, std::size_t>> mutual;
      for (std::size_t i = 0; i < L.size(); ++i)
        for (std::size_t j : want[i]) {
          if (degree <= 3 && j < i) continue;
          // (above density 3, a pair wanted by either landing is joined: the denser web the owner's variable asks for)
          if (degree <= 3 && std::find(want[j].begin(), want[j].end(), i) == want[j].end()) continue;
          mutual.push_back({i, j});
        }
      if (keep_apart)
        std::stable_sort(mutual.begin(), mutual.end(), [&](const auto& x, const auto& y) {
          return dist(L[x.first].p, L[x.second].p) < dist(L[y.first].p, L[y.second].p);
        });
      for (const auto& [i, j] : mutual) {
        if (joined.count(pair_of(L[i].p, L[j].p))) continue;
        join(i, j);
      }
    }
    // Every landing short of one join, then of two, takes its nearest partner within 1.5 reach.
    for (int need = 1; need <= 2; ++need)
      for (std::size_t i = 0; i < L.size(); ++i) {
        if (deg[i] >= need) continue;
        std::vector<std::pair<double, std::size_t>> cands;
        for (std::size_t j : near(i, span_scale > 1.0 ? 5 : 2)) {
          if (!fits(i, j, kOrganicFinishMinSpanRatio * reach, kNetFallbackReach * reach * span_scale * (1.0 - 1e-12))) continue;
          cands.push_back({dist(L[i].p, L[j].p), j});
        }
        std::stable_sort(cands.begin(), cands.end(), [](const auto& x, const auto& y) { return x.first < y.first; });
        // The nearest; kept apart (OJ7): the nearest that does not come too near the net already laid.
        for (const auto& cj : cands) {
          if (join(i, cj.second)) break;
          if (!keep_apart) break;
        }
      }
    // OJ8: each joined landing's STEM, from the node to its foot along the face's normal, as wide as the node's strut
    // (none when the node is its own foot: a vine end already at the face, with no sink).
    for (std::size_t i = 0; i < L.size(); ++i) {
      if (deg[i] == 0) continue;
      const double l = dist(L[i].p, foot[i]);
      if (!(l > 1e-6)) continue;
      Bar stem;
      stem.a = L[i].p;
      stem.b = foot[i];
      stem.width = L[i].width;
      stem.cell = reach;
      stem.region = region;
      stem.net = true;
      stem.face_skin = true;
      stem.stem = true;
      stem.strand = next_strand++;
      stem.end_a = stem.end_b = Bar::End::Node;
      into[i] = static_cast<int>(bars.bars.size());
      stem_ids.insert(bars.bars.size());
      bars.bars.push_back(stem);
      ++rep.stems;
      rep.stem_longest_mm = std::max(rep.stem_longest_mm, l);
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
  // OJ8: every crossing of two net struts becomes a JOINT: both cut there on their own lines (coplanar on a flat face,
  // so the cut points are one point); a crossing within one width of an end of either strut uses that end (the other
  // strut is cut there). Stems (along the face's normal) are not crossed by the net.
  // (Run again while a pass cut anything: a cut at an end moves a piece off its line, which can make a new crossing.)
  for (int pass = 0; pass < 1 && bars.bars.size() > first_net; ++pass) {
    const std::size_t joints_before = rep.joints_at_crossings;
    std::vector<std::size_t> ids;
    for (std::size_t i = first_net; i < bars.bars.size(); ++i) {
      const Bar& b = bars.bars[i];
      if (!b.face_skin || b.link || stem_ids.count(i)) continue;
      ids.push_back(i);
    }
    // Stems out: a bar whose two ends are a landing node and its foot runs along the normal; the net struts' ends are
    // all feet, so a stem is a bar with an end at no other face_skin bar's end but one.
    std::map<Key, int> end_count;
    for (std::size_t i : ids) { ++end_count[key_of(bars.bars[i].a)]; ++end_count[key_of(bars.bars[i].b)]; }
    const double gc = 2.0;
    auto gk = [&](const Vec3& q) {
      return std::array<long long, 3>{static_cast<long long>(std::floor(q.x / gc)), static_cast<long long>(std::floor(q.y / gc)),
                                      static_cast<long long>(std::floor(q.z / gc))};
    };
    std::map<std::array<long long, 3>, std::vector<std::size_t>> grid;
    for (std::size_t k = 0; k < ids.size(); ++k) {
      const Bar& b = bars.bars[ids[k]];
      const int n = std::max(1, static_cast<int>(std::ceil(dist(b.a, b.b) / (0.5 * gc))));
      std::set<std::array<long long, 3>> cells;
      for (int q = 0; q <= n; ++q) {
        const auto c0 = gk(lerp(b.a, b.b, static_cast<double>(q) / n));
        for (long long dx = -1; dx <= 1; ++dx)
          for (long long dy = -1; dy <= 1; ++dy)
            for (long long dz = -1; dz <= 1; ++dz) cells.insert({c0[0] + dx, c0[1] + dy, c0[2] + dz});
      }
      for (const auto& c : cells) grid[c].push_back(k);
    }
    std::vector<std::vector<Vec3>> cuts(ids.size());
    std::set<std::pair<std::size_t, std::size_t>> tried;
    for (const auto& [cell, list] : grid)
      for (std::size_t u = 0; u < list.size(); ++u)
        for (std::size_t v = u + 1; v < list.size(); ++v) {
          std::size_t ka = std::min(list[u], list[v]), kb = std::max(list[u], list[v]);
          if (!tried.insert({ka, kb}).second) continue;
          const Bar &A = bars.bars[ids[ka]], &B = bars.bars[ids[kb]];
          if (key_of(A.a) == key_of(B.a) || key_of(A.a) == key_of(B.b) || key_of(A.b) == key_of(B.a) || key_of(A.b) == key_of(B.b)) continue;
          // closest points of the two segments
          const Vec3 d1{A.b.x - A.a.x, A.b.y - A.a.y, A.b.z - A.a.z}, d2{B.b.x - B.a.x, B.b.y - B.a.y, B.b.z - B.a.z};
          const Vec3 r{A.a.x - B.a.x, A.a.y - B.a.y, A.a.z - B.a.z};
          const double aa = d1.x * d1.x + d1.y * d1.y + d1.z * d1.z, ee = d2.x * d2.x + d2.y * d2.y + d2.z * d2.z;
          const double ff = d2.x * r.x + d2.y * r.y + d2.z * r.z, cc = d1.x * r.x + d1.y * r.y + d1.z * r.z, bb = d1.x * d2.x + d1.y * d2.y + d1.z * d2.z;
          const double den = aa * ee - bb * bb;
          if (!(den > 1e-12 * aa * ee)) continue;   // parallel: no crossing point
          double sA = std::clamp((bb * ff - cc * ee) / den, 0.0, 1.0);
          double tB = ee > 0.0 ? (bb * sA + ff) / ee : 0.0;
          if (tB < 0.0) { tB = 0.0; sA = std::clamp(-cc / aa, 0.0, 1.0); }
          else if (tB > 1.0) { tB = 1.0; sA = std::clamp((bb - cc) / aa, 0.0, 1.0); }
          const Vec3 pa = lerp(A.a, A.b, sA), pb = lerp(B.a, B.b, tB);
          if (dist(pa, pb) > 0.5 * std::min(A.width, B.width)) continue;   // they do not touch
          // The joint: the crossing itself (one point: the two lie in the face's plane), each cut on its own line; a
          // crossing at an end of one cuts only the other there.
          const Vec3 J{0.5 * (pa.x + pb.x), 0.5 * (pa.y + pb.y), 0.5 * (pa.z + pb.z)};
          // (an end within 0.05 mm of the crossing is the joint: the other is cut there)
          const double te = 0.05;
          const bool atA = dist(J, A.a) < te || dist(J, A.b) < te, atB = dist(J, B.a) < te || dist(J, B.b) < te;
          if (atA && atB) continue;   // end to end: they meet already
          if (pass > 0 && (atA || atB)) continue;   // later passes: only crossings well inside both (left by the first)
          const Vec3 eA = dist(J, A.a) < dist(J, A.b) ? A.a : A.b, eB = dist(J, B.a) < dist(J, B.b) ? B.a : B.b;
          if (atA) cuts[kb].push_back(eA);
          else if (atB) cuts[ka].push_back(eB);
          else { cuts[ka].push_back(pa); cuts[kb].push_back(pa); }
        }
    std::vector<Bar> pieces;
    std::vector<char> gone(bars.bars.size(), 0);
    for (std::size_t k = 0; k < ids.size(); ++k) {
      if (cuts[k].empty()) continue;
      const Bar X = bars.bars[ids[k]];
      std::vector<std::pair<double, Vec3>> at;
      const Vec3 dx{X.b.x - X.a.x, X.b.y - X.a.y, X.b.z - X.a.z};
      const double l2 = dx.x * dx.x + dx.y * dx.y + dx.z * dx.z;
      for (const Vec3& c : cuts[k]) at.push_back({l2 > 0 ? ((c.x - X.a.x) * dx.x + (c.y - X.a.y) * dx.y + (c.z - X.a.z) * dx.z) / l2 : 0.0, c});
      std::sort(at.begin(), at.end(), [](const auto& x, const auto& y) { return x.first < y.first; });
      Vec3 from = X.a;
      for (const auto& c : at) {
        if (dist(from, c.second) < 1e-9) continue;
        Bar piece = X;
        piece.a = from;
        piece.b = c.second;
        piece.end_b = Bar::End::Node;
        if (dist(from, X.a) > 1e-9) piece.end_a = Bar::End::Node;
        pieces.push_back(piece);
        from = c.second;
        ++rep.joints_at_crossings;
      }
      if (dist(from, X.b) > 1e-9) {
        Bar piece = X;
        piece.a = from;
        piece.end_a = Bar::End::Node;
        pieces.push_back(piece);
      }
      gone[ids[k]] = 1;
    }
    if (!pieces.empty()) {
      // Every bar's place in the new list (a cut bar: its first piece), so the Joined ends still point at their bar.
      std::vector<int> where(bars.bars.size(), -1);
      Bars kept;
      for (std::size_t i = 0; i < bars.bars.size(); ++i)
        if (!gone[i]) { where[i] = static_cast<int>(kept.bars.size()); kept.bars.push_back(bars.bars[i]); }
      std::size_t pi = 0;
      for (std::size_t k = 0; k < ids.size(); ++k) {
        if (cuts[k].empty()) continue;
        where[ids[k]] = static_cast<int>(kept.bars.size() + pi);
        const Bar& X = bars.bars[ids[k]];
        while (pi < pieces.size() && !(dist(pieces[pi].b, X.b) < 1e-9)) ++pi;   // this bar's pieces end at its b
        ++pi;
      }
      for (const Bar& b : pieces) kept.bars.push_back(b);
      std::set<std::size_t> moved_stems;
      for (std::size_t sidx : stem_ids) if (where[sidx] >= 0) moved_stems.insert(static_cast<std::size_t>(where[sidx]));
      stem_ids.swap(moved_stems);
      for (Bar& b : kept.bars) {
        if (b.into_a >= 0 && static_cast<std::size_t>(b.into_a) < where.size()) b.into_a = where[static_cast<std::size_t>(b.into_a)];
        if (b.into_b >= 0 && static_cast<std::size_t>(b.into_b) < where.size()) b.into_b = where[static_cast<std::size_t>(b.into_b)];
      }
      bars.bars.swap(kept.bars);
    }
    (void)thinnest_net;
    (void)end_count;
    if (rep.joints_at_crossings == joints_before) break;
  }
  // OJ8 (the lead's ruling 3): no two net struts may cross mid-bar without a joint. A crossing the cut left (two pieces
  // whose centre lines meet more than 0.05 mm from every end of either) takes the later join out whole (all its pieces).
  for (int pass = 0; pass < 6; ++pass) {
    std::vector<std::size_t> ids;
    for (std::size_t i = first_net; i < bars.bars.size(); ++i)
      if (bars.bars[i].face_skin && !bars.bars[i].link && !stem_ids.count(i)) ids.push_back(i);
    std::set<int> out_strands;
    for (std::size_t u = 0; u < ids.size(); ++u)
      for (std::size_t v = u + 1; v < ids.size(); ++v) {
        const Bar &A = bars.bars[ids[u]], &B = bars.bars[ids[v]];
        const double lo = 0.6;   // (two pieces of one join may cross too, where a cut moved a piece off its line)
        if (std::max(A.a.x, A.b.x) + lo < std::min(B.a.x, B.b.x) || std::max(B.a.x, B.b.x) + lo < std::min(A.a.x, A.b.x) ||
            std::max(A.a.y, A.b.y) + lo < std::min(B.a.y, B.b.y) || std::max(B.a.y, B.b.y) + lo < std::min(A.a.y, A.b.y) ||
            std::max(A.a.z, A.b.z) + lo < std::min(B.a.z, B.b.z) || std::max(B.a.z, B.b.z) + lo < std::min(A.a.z, A.b.z))
          continue;
        double least = 1e300;
        Vec3 at{};
        for (int q = 0; q <= 40; ++q) {
          const Vec3 p = lerp(A.a, A.b, q / 40.0);
          const double d2 = to_segment2(p, B.a, B.b);
          if (d2 < least) { least = d2; at = p; }
        }
        if (!(std::sqrt(least) < 0.01)) continue;
        if (dist(at, A.a) <= 0.05 || dist(at, A.b) <= 0.05 || dist(at, B.a) <= 0.05 || dist(at, B.b) <= 0.05) continue;
        out_strands.insert(std::max(A.strand, B.strand));
      }
    if (out_strands.empty()) break;
    Bars kept;
    std::set<std::size_t> new_stems;
    for (std::size_t i = 0; i < bars.bars.size(); ++i) {
      if (i >= first_net && bars.bars[i].face_skin && !stem_ids.count(i) && out_strands.count(bars.bars[i].strand)) {
        ++rep.skipped_parallel;   // (counted with the joins not laid)
        continue;
      }
      if (stem_ids.count(i)) new_stems.insert(kept.bars.size());
      kept.bars.push_back(bars.bars[i]);
    }
    bars.bars.swap(kept.bars);
    stem_ids.swap(new_stems);
  }
  // The vine ends the net reaches (Joined): each points at a net bar ending there, found again after the cuts above; one
  // whose net is gone is a Surface end again (the drop after the net then takes it).
  {
    std::map<Key, int> net_at;
    for (std::size_t i = first_net; i < bars.bars.size(); ++i)
      if (bars.bars[i].face_skin) { net_at.emplace(key_of(bars.bars[i].a), static_cast<int>(i)); net_at.emplace(key_of(bars.bars[i].b), static_cast<int>(i)); }
    for (std::size_t i = 0; i < first_net && i < bars.bars.size(); ++i) {
      Bar& b = bars.bars[i];
      for (int e = 0; e < 2; ++e) {
        Bar::End& kind = e ? b.end_b : b.end_a;
        if (kind != Bar::End::Joined) continue;
        int& into = e ? b.into_b : b.into_a;
        if (into < static_cast<int>(first_net) && into >= 0) continue;   // joined to an older bar: not the net's
        const auto it = net_at.find(key_of(e ? b.b : b.a));
        if (it != net_at.end()) into = it->second;
        else { into = -1; kind = Bar::End::Surface; }
      }
    }
  }
  for (const Bar& b : bars.bars) rep.struts += b.net && b.face_skin && !b.link;
  rep.struts -= std::min(rep.struts, rep.stems);
  rep.skipped_parallel += kept_apart ? *kept_apart : 0;
  return made;
}

}  // namespace topopt::lattice_layout
