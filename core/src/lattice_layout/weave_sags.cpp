// Lattice rebuild, Organic: what happens to a weave strand that sags (rules O17, O18; the owner's OR29, 2026-11-15:
// "Let's try yours. I liked the zigzag legs that were created - so if there is a deeper sag, maybe implement that? And
// let's start at 0.9mm and see where that goes."). The rules in full: lattice_layout_mesh.hpp, lift_weave_sags.
//
// The leg is the SHAPE of the old engine's branched support (core/src/mesh/organic_lattice.cpp, "BRANCHED SUPPORT",
// read only, never called): a tip at the unsupported low point steps down one layer at a time, leaning toward the
// nearest lattice material in the layer below within 8 raster cells of the thinnest radius, by at most tan(40 degrees)
// of a layer per layer; a lean that would breach the part goes straight down, and if that breaches too the tip dies; it
// stops where it lands on material. Its width there was the thinnest strut's. Not copied: its merging of two tips (one
// leg per sag here; a leg laid before is material for the next), its raster (points are read exactly here), its cut
// of what a dead tip could not hold (a sag with no leg is left to the layer check, as before).
#include <algorithm>
#include <cmath>
#include <set>
#include <utility>
#include <vector>

#include "topopt/lattice_layout_mesh.hpp"

namespace topopt::lattice_layout {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kLegTiltDeg = 40.0;   // the old kOrganicBranchMaxTiltDeg: at most this far from plumb per layer
constexpr int kLegReachCells = 8;      // the old R = 8 cells (of the thinnest radius) round the tip
constexpr double kSameHeight = 1e-9;   // a neighbour at the low node's height is passed over

double dist2(const Vec3& p, const Vec3& q) {
  return (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z);
}
// From p to the segment of bar x, and where along it (0 .. 1).
double to_line(const Vec3& p, const Bar& x, double* at = nullptr) {
  const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0.0 ? std::clamp(((p.x - x.a.x) * d.x + (p.y - x.a.y) * d.y + (p.z - x.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  if (at) *at = t;
  return std::sqrt(dist2(p, Vec3{x.a.x + d.x * t, x.a.y + d.y * t, x.a.z + d.z * t}));
}

// The bars as nodes, read again after every change (the bars are the only truth).
struct Graph {
  std::vector<std::size_t> joint;                              // per bar end, 2 i + e
  std::vector<std::vector<std::pair<std::size_t, int>>> at;    // per node: (bar, end)
  std::vector<Vec3> pos;                                       // per node: its point (the first end seen there)
  std::vector<char> weave, shallow;                            // per bar
  std::vector<char> held;                                      // per node: held from below
  std::vector<char> standing;                                  // per bar
};

Graph read_graph(const Bars& bars, const std::vector<int>& regions, double layer) {
  Graph g;
  const std::size_t n = bars.bars.size();
  g.joint = end_joints(bars);
  std::size_t nodes = 0;
  for (std::size_t j : g.joint) nodes = std::max(nodes, j + 1);
  g.at.assign(nodes, {});
  g.pos.assign(nodes, Vec3{});
  std::vector<char> seen(nodes, 0);
  g.weave.assign(n, 0);
  g.shallow.assign(n, 0);
  for (std::size_t i = 0; i < n; ++i) {
    const Bar& x = bars.bars[i];
    g.weave[i] = std::find(regions.begin(), regions.end(), x.region) != regions.end();
    g.shallow[i] = g.weave[i] && bar_is_bridge(x);
    for (int e = 0; e < 2; ++e) {
      const std::size_t j = g.joint[2 * i + static_cast<std::size_t>(e)];
      g.at[j].push_back({i, e});
      if (!seen[j]) { seen[j] = 1; g.pos[j] = e == 0 ? x.a : x.b; }
    }
  }
  // Where Joined ends land: per bar, the (bar, end) that land in it.
  std::vector<std::vector<std::pair<std::size_t, int>>> landed(n);
  for (std::size_t i = 0; i < n; ++i)
    for (int e = 0; e < 2; ++e) {
      const Bar& x = bars.bars[i];
      if ((e == 0 ? x.end_a : x.end_b) != Bar::End::Joined) continue;
      const int into = e == 0 ? x.into_a : x.into_b;
      if (into >= 0 && static_cast<std::size_t>(into) < n && static_cast<std::size_t>(into) != i)
        landed[static_cast<std::size_t>(into)].push_back({i, e});
    }
  // Held from below, walking upward from the solid (and from every bar that is not a weave's).
  g.held.assign(nodes, 0);
  g.standing.assign(n, 0);
  std::vector<std::size_t> queue;
  auto hold = [&](std::size_t j) {
    if (!g.held[j]) { g.held[j] = 1; queue.push_back(j); }
  };
  auto low_node = [&](std::size_t i) { return g.joint[2 * i + (bars.bars[i].b.z < bars.bars[i].a.z ? 1 : 0)]; };
  auto stand = [&](std::size_t i) {
    if (g.standing[i]) return;
    const std::size_t ja = g.joint[2 * i], jb = g.joint[2 * i + 1];
    if (g.weave[i] && !(g.held[low_node(i)] && (!g.shallow[i] || (g.held[ja] && g.held[jb])))) return;
    g.standing[i] = 1;
    const Bar& y = bars.bars[i];
    const double low = std::min(y.a.z, y.b.z);
    for (const auto& [k, e] : landed[i]) {
      const Vec3& p = e == 0 ? bars.bars[k].a : bars.bars[k].b;
      if (low < p.z + layer) hold(g.joint[2 * k + static_cast<std::size_t>(e)]);
    }
  };
  for (std::size_t i = 0; i < n; ++i) {
    const Bar& x = bars.bars[i];
    if (!g.weave[i]) {
      hold(g.joint[2 * i]);
      hold(g.joint[2 * i + 1]);
      continue;
    }
    if (x.end_a == Bar::End::Solid) hold(g.joint[2 * i]);
    if (x.end_b == Bar::End::Solid) hold(g.joint[2 * i + 1]);
  }
  for (std::size_t i = 0; i < n; ++i)
    if (!g.weave[i]) stand(i);
  for (std::size_t q = 0; q < queue.size(); ++q) {
    const std::size_t k = queue[q];
    for (const auto& [i, e] : g.at[k]) {
      const std::size_t o = g.joint[2 * i + static_cast<std::size_t>(1 - e)];
      if (o != k && g.pos[o].z > g.pos[k].z - layer) hold(o);
      stand(i);
    }
  }
  return g;
}

constexpr std::size_t kNone = static_cast<std::size_t>(-1);

// The weave bars with an end at node j (each once; a bar with both ends there is not one).
std::vector<std::size_t> weave_at(const Graph& g, std::size_t j) {
  std::vector<std::size_t> out;
  for (const auto& be : g.at[j])
    if (g.weave[be.first] && g.joint[2 * be.first] != g.joint[2 * be.first + 1] &&
        std::find(out.begin(), out.end(), be.first) == out.end())
      out.push_back(be.first);
  return out;
}

// Come to node `at` by bar `bar`: the bar an arm goes on along. The one bar there of the same strand, else the one
// other weave bar there; none (kNone) when neither is one bar.
std::size_t go_on(const Graph& g, const Bars& bars, std::size_t at, std::size_t bar) {
  std::vector<std::size_t> others = weave_at(g, at);
  others.erase(std::remove(others.begin(), others.end(), bar), others.end());
  const int s = bars.bars[bar].strand;
  if (s >= 0) {
    std::vector<std::size_t> same;
    for (std::size_t i : others)
      if (bars.bars[i].strand == s) same.push_back(i);
    if (same.size() == 1) return same[0];
  }
  return others.size() == 1 ? others[0] : kNone;
}

// From node j along bar `via` and on (go_on): the nodes met, until one is held from below (`end_held` true: it is the
// last of the list), or the arm ends or comes back on itself (false).
std::vector<std::size_t> walk_arm(const Graph& g, const Bars& bars, std::size_t j, std::size_t via, bool* end_held) {
  std::vector<std::size_t> out;
  std::set<std::size_t> seen{j};
  std::size_t cur = j, bar = via;
  *end_held = false;
  for (;;) {
    const std::size_t nxt = g.joint[2 * bar] == cur ? g.joint[2 * bar + 1] : g.joint[2 * bar];
    if (!seen.insert(nxt).second) return out;
    out.push_back(nxt);
    if (g.held[nxt]) { *end_held = true; return out; }
    bar = go_on(g, bars, nxt, bar);
    if (bar == kNone) return out;
    cur = nxt;
  }
}

// The height of the first node from j along bar `via` and on that is not at j's height.
bool first_other_height(const Graph& g, const Bars& bars, std::size_t j, std::size_t via, double* z) {
  std::set<std::size_t> seen{j};
  std::size_t cur = j, bar = via;
  for (;;) {
    const std::size_t nxt = g.joint[2 * bar] == cur ? g.joint[2 * bar + 1] : g.joint[2 * bar];
    if (!seen.insert(nxt).second) return false;
    if (std::fabs(g.pos[nxt].z - g.pos[j].z) > kSameHeight) { *z = g.pos[nxt].z; return true; }
    bar = go_on(g, bars, nxt, bar);
    if (bar == kNone) return false;
    cur = nxt;
  }
}

// A low node and the weave bars leaving it (its arms, in bar order).
struct LowNode { std::size_t node; std::vector<std::size_t> arms; };

// Every low node, lowest first (then in node order): a node not held from below, every bar there a weave's, two or
// more of them, and lower than every node they join it to (one at exactly its height passed over).
std::vector<LowNode> low_nodes(const Graph& g, const Bars& bars) {
  std::vector<LowNode> out;
  for (std::size_t j = 0; j < g.at.size(); ++j) {
    if (g.held[j]) continue;
    bool all_weave = true;
    for (const auto& be : g.at[j]) all_weave = all_weave && g.weave[be.first];
    if (!all_weave) continue;
    const std::vector<std::size_t> arms = weave_at(g, j);
    if (arms.size() < 2) continue;
    bool low = true;
    for (std::size_t i : arms) {
      double z = 0.0;
      low = low && first_other_height(g, bars, j, i, &z) && z > g.pos[j].z;
    }
    if (low) out.push_back({j, arms});
  }
  std::stable_sort(out.begin(), out.end(), [&](const LowNode& a, const LowNode& b) { return g.pos[a.node].z < g.pos[b.node].z; });
  return out;
}

// Material at p for a leg: inside a bar of `near` (the first within its half width of p; with `standing`, only a
// standing bar); -1 when none.
int bar_at(const Bars& bars, const Graph& g, const Vec3& p, const std::vector<std::size_t>& near, bool standing) {
  for (std::size_t i : near) {
    const Bar& x = bars.bars[i];
    const double r = 0.5 * x.width;
    if ((standing && !g.standing[i]) || p.z < std::min(x.a.z, x.b.z) - r || p.z > std::max(x.a.z, x.b.z) + r) continue;
    if (to_line(p, x) <= r) return static_cast<int>(i);
  }
  return -1;
}

}  // namespace

SagReport lift_weave_sags(const Domain& domain, const Layout& layout, Bars& bars, double lift_mm, bool legs, double layer_mm) {
  SagReport rep;
  std::vector<int> regions;
  for (const Layout::Weave& w : layout.weave) regions.push_back(w.region);
  if (regions.empty() || (!(lift_mm > 0.0) && !legs)) return rep;
  const double layer = layer_mm > 0.0 ? layer_mm : 0.2;
  const SolidAt solid_at(layout);
  const Domain::Probe probe = domain.probe();
  auto solid = [&](const Vec3& p) { return solid_at(probe, p); };
  // A low node once tried (by its strand's first bar there and that bar's end) is never tried again: the bars keep
  // their order (legs are added after them), so the key outlives a new reading of the graph.
  std::set<std::pair<std::size_t, int>> tried;
  bool counted = false;
  for (;;) {
    const Graph g = read_graph(bars, regions, layer);
    const std::vector<LowNode> lows = low_nodes(g, bars);
    if (!counted) { rep.low_nodes = lows.size(); counted = true; }
    LowNode low{};
    bool found = false;
    for (const LowNode& l : lows) {
      const std::pair<std::size_t, int> key{l.arms[0], g.joint[2 * l.arms[0]] == l.node ? 0 : 1};
      if (!tried.insert(key).second) continue;
      low = l;
      found = true;
      break;
    }
    if (!found) break;
    const std::size_t j = low.node;
    // Each arm to its nearest held node.
    std::vector<std::vector<std::size_t>> arm;
    bool all_held = true;
    for (std::size_t i : low.arms) {
      bool held = false;
      arm.push_back(walk_arm(g, bars, j, i, &held));
      all_held = all_held && held;
    }
    // The two arms the line runs along: the only two, or of more, the two of the one strand that passes through it
    // (the others, its ties, ride with the low point as any bar end there does).
    std::size_t pa = 0, pb = 1;
    bool pair = arm.size() == 2;
    for (std::size_t x = 0; !pair && x < low.arms.size(); ++x) {
      const int st = bars.bars[low.arms[x]].strand;
      if (st < 0) continue;
      std::vector<std::size_t> same;
      for (std::size_t y = 0; y < low.arms.size(); ++y)
        if (bars.bars[low.arms[y]].strand == st) same.push_back(y);
      if (same.size() == 2) { pa = same[0]; pb = same[1]; pair = true; }
    }
    if (!all_held) ++rep.open_arm;            // no line to lift it onto: a leg (O18)
    else if (!pair) ++rep.not_covered;
    // ── O17: lifted onto the straight line between its two held nodes, when no node moves more than lift_mm ──
    if (lift_mm > 0.0 && all_held && pair) {
      const std::vector<std::size_t>& arm0 = arm[pa];
      const std::vector<std::size_t>& arm1 = arm[pb];
      const Vec3 h0 = g.pos[arm0.back()], h1 = g.pos[arm1.back()];
      // The sag's nodes in order from h0 to h1 (both excluded), and how far along the arms in plan each lies.
      std::vector<std::size_t> run(arm0.rbegin() + 1, arm0.rend());
      run.push_back(j);
      run.insert(run.end(), arm1.begin(), arm1.end() - 1);
      std::vector<double> s(run.size());
      double total = 0.0;
      Vec3 prev = h0;
      for (std::size_t q = 0; q < run.size(); ++q) {
        total += std::hypot(g.pos[run[q]].x - prev.x, g.pos[run[q]].y - prev.y);
        s[q] = total;
        prev = g.pos[run[q]];
      }
      total += std::hypot(h1.x - prev.x, h1.y - prev.y);
      std::vector<double> to(g.at.size(), 0.0);
      std::vector<char> moved(g.at.size(), 0);
      double most = 0.0;
      for (std::size_t q = 0; q < run.size() && total > 1e-9; ++q) {
        const double z = h0.z + (h1.z - h0.z) * (s[q] / total);
        most = std::max(most, std::fabs(z - g.pos[run[q]].z));
        to[run[q]] = z;
        moved[run[q]] = 1;
      }
      if (!(total > 1e-9)) ++rep.not_covered;
      else if (most > lift_mm) ++rep.too_far;   // a node would move more than lift_mm: a leg (O18)
      else {
      rep.lift_largest_mm = std::max(rep.lift_largest_mm, most);
      // Every weave bar end at a moved node; then each Joined end landing in a bar that moved, with the bar.
      const std::vector<Bar> before = bars.bars;
      for (std::size_t i = 0; i < bars.bars.size(); ++i) {
        if (!g.weave[i]) continue;
        Bar& x = bars.bars[i];
        if (moved[g.joint[2 * i]]) x.a.z = to[g.joint[2 * i]];
        if (moved[g.joint[2 * i + 1]]) x.b.z = to[g.joint[2 * i + 1]];
      }
      for (std::size_t i = 0; i < bars.bars.size(); ++i) {
        if (!g.weave[i]) continue;
        for (int e = 0; e < 2; ++e) {
          Bar& x = bars.bars[i];
          if ((e == 0 ? x.end_a : x.end_b) != Bar::End::Joined || moved[g.joint[2 * i + static_cast<std::size_t>(e)]]) continue;
          const int into = e == 0 ? x.into_a : x.into_b;
          if (into < 0 || static_cast<std::size_t>(into) >= bars.bars.size()) continue;
          const Bar &was = before[static_cast<std::size_t>(into)], &now = bars.bars[static_cast<std::size_t>(into)];
          if (was.a.z == now.a.z && was.b.z == now.b.z) continue;
          Vec3& p = e == 0 ? x.a : x.b;
          double t = 0.0;
          (void)to_line(p, was, &t);
          p.z += (now.a.z - was.a.z) * (1.0 - t) + (now.b.z - was.b.z) * t;
        }
      }
      ++rep.lifted;
      continue;
      }
    }
    if (!legs) continue;
    // ── O18: a zig-zag leg from the material below up to the low point ──
    const Vec3 top = g.pos[j];
    const int region = bars.bars[low.arms[0]].region;
    double width = 0.0;
    for (std::size_t i = 0; i < bars.bars.size(); ++i)
      if (g.weave[i] && bars.bars[i].region == region && bars.bars[i].width > 0.0)
        width = width > 0.0 ? std::min(width, bars.bars[i].width) : bars.bars[i].width;
    width = std::max(width, layout.min_strut_mm);
    const double r = 0.5 * width;
    // The bars a leg may land on or lean toward: those that come within its reach anywhere on its way down (it drifts
    // at most tan 40 degrees of its drop from the plumb line).
    double widest = 0.0;
    for (const Bar& x : bars.bars) widest = std::max(widest, x.width);
    std::vector<std::size_t> near;
    for (std::size_t i = 0; i < bars.bars.size(); ++i) {
      if (std::find(low.arms.begin(), low.arms.end(), i) != low.arms.end()) continue;   // its own arms are not under it
      const Bar& x = bars.bars[i];
      const double low_z = std::min(x.a.z, x.b.z);
      if (low_z - widest > top.z) continue;
      const double drift = std::tan(kLegTiltDeg * kPi / 180.0) * (top.z - low_z + widest) + kLegReachCells * r + widest;
      if (std::max(x.a.x, x.b.x) < top.x - drift || std::min(x.a.x, x.b.x) > top.x + drift ||
          std::max(x.a.y, x.b.y) < top.y - drift || std::min(x.a.y, x.b.y) > top.y + drift)
        continue;
      near.push_back(i);
    }
    // Material straight below the low point, before the plumb line leaves the part.
    bool below = false;
    for (double z = top.z - layer;; z -= layer) {
      const Vec3 p{top.x, top.y, z};
      if (solid(p) || bar_at(bars, g, p, near, false) >= 0) { below = true; break; }
      if (probe.where(p).why == Why::Outside) break;
    }
    if (!below) { ++rep.unsupported; continue; }
    // Grown downward, as the old tips grew.
    const double tilt = std::tan(kLegTiltDeg * kPi / 180.0) * layer;
    std::vector<Vec3> pts{top};
    Vec3 tip = top;
    Bar::End foot_end = Bar::End::Loose;
    int foot_into = -1;
    auto breach = [&](const Vec3& p) { return !solid(p) && probe.part().depth(p) < r; };
    for (;;) {
      const double zn = tip.z - layer;
      // The nearest material of a standing bar in the layer below, on a grid of r round the tip.
      double best = 1e300, bx = tip.x, by = tip.y;
      for (int dj = -kLegReachCells; dj <= kLegReachCells; ++dj)
        for (int di = -kLegReachCells; di <= kLegReachCells; ++di) {
          const double d = (di * r) * (di * r) + (dj * r) * (dj * r);
          if (d >= best || bar_at(bars, g, Vec3{tip.x + di * r, tip.y + dj * r, zn}, near, true) < 0) continue;
          best = d;
          bx = tip.x + di * r;
          by = tip.y + dj * r;
        }
      double dx = bx - tip.x, dy = by - tip.y;
      const double dl = std::hypot(dx, dy);
      if (dl > tilt) { dx *= tilt / dl; dy *= tilt / dl; }
      Vec3 np{tip.x + dx, tip.y + dy, zn};
      if (breach(np)) {
        np = Vec3{tip.x, tip.y, zn};
        if (breach(np)) break;   // no leg
      }
      if (solid(np)) {
        // Cut where the solid begins, run on into it by the leg's own width (S11).
        Vec3 in = tip, out = np;
        for (int k = 0; k < 30; ++k) {
          const Vec3 m{0.5 * (in.x + out.x), 0.5 * (in.y + out.y), 0.5 * (in.z + out.z)};
          if (solid(m)) out = m; else in = m;
        }
        const Vec3 d{np.x - tip.x, np.y - tip.y, np.z - tip.z};
        const double l = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        pts.push_back(Vec3{in.x + d.x / l * width, in.y + d.y / l * width, in.z + d.z / l * width});
        foot_end = Bar::End::Solid;
        break;
      }
      const int y = bar_at(bars, g, np, near, false);   // the first bar it meets, standing or not
      pts.push_back(np);
      if (y >= 0) {
        foot_end = Bar::End::Joined;
        foot_into = y;
        break;
      }
      tip = np;
    }
    if (foot_end == Bar::End::Loose) { ++rep.unsupported; continue; }
    // The steps going on in one direction are one bar; laid from the foot up.
    std::vector<Vec3> corner{pts.back()};
    for (std::size_t q = pts.size() - 1; q-- > 1;) {
      const Vec3 &lo = corner.back(), &p = pts[q], &up = pts[q - 1];
      const Vec3 u{p.x - lo.x, p.y - lo.y, p.z - lo.z}, v{up.x - p.x, up.y - p.y, up.z - p.z};
      const double lu = std::sqrt(u.x * u.x + u.y * u.y + u.z * u.z), lv = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
      const double c = lu > 0.0 && lv > 0.0 ? (u.x * v.x + u.y * v.y + u.z * v.z) / (lu * lv) : 1.0;
      if (c < 1.0 - 1e-12) corner.push_back(p);
    }
    corner.push_back(top);
    const double cell = bars.bars[low.arms[0]].cell;
    rep.leg_at.push_back({bars.bars.size(), corner.size() - 1});
    for (std::size_t q = 0; q + 1 < corner.size(); ++q) {
      Bar leg;
      leg.a = corner[q];
      leg.b = corner[q + 1];
      leg.width = width;
      leg.cell = cell;
      leg.region = region;
      leg.end_a = q == 0 ? foot_end : Bar::End::Node;
      leg.into_a = q == 0 && foot_end == Bar::End::Joined ? foot_into : -1;
      leg.end_b = Bar::End::Node;
      rep.legs_mm += std::sqrt(dist2(leg.a, leg.b));
      ++rep.leg_bars;
      bars.bars.push_back(leg);
    }
    ++rep.legs;
  }
  return rep;
}

}  // namespace topopt::lattice_layout
