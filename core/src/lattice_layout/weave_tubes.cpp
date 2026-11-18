// Organic cut 2 (brief E1): a weave's bars as closed shells beside the solid, never joined (OF2, OF3).
// See lattice_layout_mesh.hpp, weave_shells.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <thread>

#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"

namespace topopt::lattice_layout {
namespace {

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 unit(const Vec3& a) { const double l = len(a); return l > 0.0 ? mul(a, 1.0 / l) : Vec3{0, 0, 0}; }
// `v` turned by the rotation that takes unit `a` to unit `b` (parallel transport of a frame along a polyline).
Vec3 turn(const Vec3& v, const Vec3& a, const Vec3& b) {
  const Vec3 c = cross(a, b);
  const double s = len(c), d = dot(a, b);
  if (s < 1e-12) return v;
  const Vec3 k = mul(c, 1.0 / s);
  return add(add(mul(v, d), mul(cross(k, v), s)), mul(k, dot(k, v) * (1.0 - d)));
}

// The signed volume of triangles [t0, t1) of `m`.
double volume_of(const TriangleMesh& m, std::size_t t0, std::size_t t1) {
  double v = 0.0;
  for (std::size_t t = t0; t < t1; ++t) {
    const auto& q = m.triangles[t];
    const Vec3 &a = m.vertices[static_cast<std::size_t>(q[0])], &b = m.vertices[static_cast<std::size_t>(q[1])],
               &c = m.vertices[static_cast<std::size_t>(q[2])];
    v += dot(a, cross(b, c)) / 6.0;
  }
  return v;
}

// One tube to sweep: its centre line, the radius at each point, and how each end is closed.
enum class Cap { Flat, Round };
struct Piece {
  std::vector<Vec3> p;
  std::vector<double> r;   // per point (already the polygon's equal-area radius)
  Cap cap_a = Cap::Round, cap_b = Cap::Round;
};

// Appends the closed tube of `pc` to `out` (its own vertices), outward. False when it has no length.
bool sweep(const Piece& pc, int sides, TriangleMesh& out, std::vector<std::size_t>& first_tri) {
  const std::size_t n = pc.p.size();
  if (n < 2) return false;
  const std::size_t m = n - 1;
  std::vector<Vec3> T(m);
  for (std::size_t k = 0; k < m; ++k) {
    T[k] = unit(sub(pc.p[k + 1], pc.p[k]));
    if (len(T[k]) == 0.0) return false;
  }
  const double kPi = 3.14159265358979323846;
  std::vector<double> ca(static_cast<std::size_t>(sides)), sa(static_cast<std::size_t>(sides));
  for (int s = 0; s < sides; ++s) {
    ca[static_cast<std::size_t>(s)] = std::cos(2.0 * kPi * s / sides);
    sa[static_cast<std::size_t>(s)] = std::sin(2.0 * kPi * s / sides);
  }
  const int lat = std::max(1, sides / 4);   // a half-sphere's rings between its rim and its pole
  const Vec3 ref = std::fabs(T[0].z) < 0.9 ? Vec3{0, 0, 1} : Vec3{1, 0, 0};
  Vec3 u = unit(cross(T[0], ref)), v = cross(T[0], u);
  const Vec3 u0 = u, v0 = v;
  std::vector<std::vector<Vec3>> rings;
  auto ring_at = [&](const Vec3& c, double r, const Vec3& a, const Vec3& b) {
    std::vector<Vec3> ring(static_cast<std::size_t>(sides));
    for (int s = 0; s < sides; ++s)
      ring[static_cast<std::size_t>(s)] = add(c, add(mul(a, r * ca[static_cast<std::size_t>(s)]), mul(b, r * sa[static_cast<std::size_t>(s)])));
    return ring;
  };
  Vec3 pole_a{}, pole_b{};
  if (pc.cap_a == Cap::Round) {
    const double r = pc.r[0];
    for (int i = lat; i >= 1; --i) {
      const double phi = 0.5 * kPi * i / (lat + 1);
      rings.push_back(ring_at(sub(pc.p[0], mul(T[0], r * std::sin(phi))), r * std::cos(phi), u0, v0));
    }
    pole_a = sub(pc.p[0], mul(T[0], r));
  }
  for (std::size_t j = 0; j <= m; ++j) {
    if (j == 0 || j == m) { rings.push_back(ring_at(pc.p[j], pc.r[j], u, v)); continue; }
    // The mitre: the ring of the incoming tube carried along its own line onto the bisecting plane.
    const Vec3 tin = T[j - 1], tout = T[j];
    const Vec3 nb = unit(add(tin, tout));
    const double r = pc.r[j];
    std::vector<Vec3> ring(static_cast<std::size_t>(sides));
    for (int s = 0; s < sides; ++s) {
      const Vec3 d = add(mul(u, ca[static_cast<std::size_t>(s)]), mul(v, sa[static_cast<std::size_t>(s)]));
      ring[static_cast<std::size_t>(s)] = sub(add(pc.p[j], mul(d, r)), mul(tin, r * dot(d, nb) / dot(tin, nb)));
    }
    rings.push_back(std::move(ring));
    u = turn(u, tin, tout);
    v = turn(v, tin, tout);
  }
  if (pc.cap_b == Cap::Round) {
    const double r = pc.r[m];
    for (int i = 1; i <= lat; ++i) {
      const double phi = 0.5 * kPi * i / (lat + 1);
      rings.push_back(ring_at(add(pc.p[m], mul(T[m - 1], r * std::sin(phi))), r * std::cos(phi), u, v));
    }
    pole_b = add(pc.p[m], mul(T[m - 1], r));
  }
  const int base = static_cast<int>(out.vertices.size());
  const std::size_t t0 = out.triangles.size();
  for (const auto& ring : rings) out.vertices.insert(out.vertices.end(), ring.begin(), ring.end());
  const int nr = static_cast<int>(rings.size());
  auto at = [&](int ring, int s) { return base + ring * sides + (s % sides); };
  for (int j = 0; j + 1 < nr; ++j)
    for (int s = 0; s < sides; ++s) {
      out.triangles.push_back({at(j, s), at(j, s + 1), at(j + 1, s + 1)});
      out.triangles.push_back({at(j, s), at(j + 1, s + 1), at(j + 1, s)});
    }
  if (pc.cap_a == Cap::Round) {
    const int pa = static_cast<int>(out.vertices.size());
    out.vertices.push_back(pole_a);
    for (int s = 0; s < sides; ++s) out.triangles.push_back({pa, at(0, s + 1), at(0, s)});
  } else {
    for (int s = 1; s + 1 < sides; ++s) out.triangles.push_back({at(0, 0), at(0, s + 1), at(0, s)});
  }
  if (pc.cap_b == Cap::Round) {
    const int pb = static_cast<int>(out.vertices.size());
    out.vertices.push_back(pole_b);
    for (int s = 0; s < sides; ++s) out.triangles.push_back({pb, at(nr - 1, s), at(nr - 1, s + 1)});
  } else {
    for (int s = 1; s + 1 < sides; ++s) out.triangles.push_back({at(nr - 1, 0), at(nr - 1, s), at(nr - 1, s + 1)});
  }
  // Outward: a positive volume (flipped when the frame came out left-handed).
  if (volume_of(out, t0, out.triangles.size()) < 0.0)
    for (std::size_t t = t0; t < out.triangles.size(); ++t) std::swap(out.triangles[t][1], out.triangles[t][2]);
  first_tri.push_back(t0);
  return true;
}

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

}  // namespace

WeaveShells weave_shells(const PartMeasure& part, const Domain& domain, const Layout& layout, const Bars& bars,
                         const std::vector<char>& kept, const Carved& carved, const MeshSpec& spec, bool trim) {
  const auto t0 = std::chrono::steady_clock::now();
  WeaveShells out;
  std::vector<int> regions;
  for (const Layout::Weave& w : layout.weave) regions.push_back(w.region);
  auto in_file = [&](std::size_t i) {
    return (kept.empty() || (i < kept.size() && kept[i])) &&
           std::find(regions.begin(), regions.end(), bars.bars[i].region) != regions.end();
  };
  // The shallow bars (O14) are shells of their own; the rest are read as runs.
  Bars round;
  std::vector<std::size_t> from;   // per bar of `round`, its place in `bars`
  std::vector<char> strut(bars.bars.size(), 0), feet(bars.bars.size(), 0);
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    if (!in_file(i)) continue;
    feet[i] = 1;
    if (bar_is_bridge(bars.bars[i], spec.bridge_rise)) { strut[i] = 1; continue; }
    round.bars.push_back(bars.bars[i]);
    from.push_back(i);
  }
  std::vector<std::vector<std::size_t>> bar_of;
  const std::vector<WeaveRun> runs = weave_runs(round, regions, 0.0, &bar_of);
  const int sides = std::max(3, spec.tube_sides);
  const double kPi = 3.14159265358979323846;
  const double k_round = std::sqrt(2.0 * kPi / (sides * std::sin(2.0 * kPi / sides)));   // equal area
  const double run_on = strut_run_on_mm(carved, spec);
  const double sharp = std::cos(60.0 * kPi / 180.0);   // a turn sharper than 60 degrees ends the tube
  std::vector<Piece> pieces;   // kept for OF3's rebuild
  for (std::size_t q = 0; q < runs.size(); ++q) {
    const std::vector<std::size_t>& segs = bar_of[q];
    // The centre line, with each segment's bar width; zero-length segments dropped.
    std::vector<Vec3> pts{round.bars[segs[0]].a};
    std::vector<double> w;   // per segment
    for (std::size_t s : segs) {
      const Bar& b = round.bars[s];
      if (len(sub(b.b, pts.back())) < 1e-9) continue;
      pts.push_back(b.b);
      w.push_back(b.width);
    }
    if (pts.size() < 2) continue;
    const Bar::End ea = round.bars[segs.front()].end_a, eb = round.bars[segs.back()].end_b;
    std::size_t start = 0;
    for (std::size_t k = 1; k <= w.size(); ++k) {
      const bool last = k == w.size();
      const bool split = !last && dot(unit(sub(pts[k], pts[k - 1])), unit(sub(pts[k + 1], pts[k]))) < sharp;
      if (!last && !split) continue;
      Piece pc;
      pc.p.assign(pts.begin() + static_cast<std::ptrdiff_t>(start), pts.begin() + static_cast<std::ptrdiff_t>(k) + 1);
      for (std::size_t j = start; j <= k; ++j) {
        const double wj = j == start ? w[start] : j == k ? w[k - 1] : std::max(w[j - 1], w[j]);
        pc.r.push_back(0.5 * wj * k_round);
      }
      // Ends: in solid, run on and flat; on the surface, flat there; else (a joint, a free end, a split) round.
      auto end_kind = [&](bool first) {
        const bool outer = first ? start == 0 : last;
        const Bar::End e = first ? ea : eb;
        if (!outer) return Cap::Round;
        return e == Bar::End::Solid || e == Bar::End::Surface ? Cap::Flat : Cap::Round;
      };
      pc.cap_a = end_kind(true);
      pc.cap_b = end_kind(false);
      if (start == 0 && ea == Bar::End::Solid) pc.p.front() = sub(pc.p.front(), mul(unit(sub(pc.p[1], pc.p[0])), run_on));
      if (last && eb == Bar::End::Solid) {
        const std::size_t e = pc.p.size() - 1;
        pc.p[e] = add(pc.p[e], mul(unit(sub(pc.p[e], pc.p[e - 1])), run_on));
      }
      out.sharp_splits += split;
      pieces.push_back(std::move(pc));
      start = k;
    }
  }
  // Every shell on its own, to be trimmed (OF3) on any number of threads; joined into one list at the end.
  std::vector<TriangleMesh> shells;
  std::vector<int> made_from;   // per shell: its piece, or -1 (a shape of build_mesh's)
  auto split_off = [&](TriangleMesh& all, std::vector<std::size_t>& firsts, int piece) {
    firsts.push_back(all.triangles.size());
    for (std::size_t s = 0; s + 1 < firsts.size(); ++s) {
      TriangleMesh one;
      int lo = 1 << 30, hi = -1;
      for (std::size_t t = firsts[s]; t < firsts[s + 1]; ++t)
        for (int k = 0; k < 3; ++k) { lo = std::min(lo, all.triangles[t][static_cast<std::size_t>(k)]); hi = std::max(hi, all.triangles[t][static_cast<std::size_t>(k)]); }
      if (hi < 0) continue;
      one.vertices.assign(all.vertices.begin() + lo, all.vertices.begin() + hi + 1);
      for (std::size_t t = firsts[s]; t < firsts[s + 1]; ++t)
        one.triangles.push_back({all.triangles[t][0] - lo, all.triangles[t][1] - lo, all.triangles[t][2] - lo});
      shells.push_back(std::move(one));
      made_from.push_back(piece);
    }
  };
  for (std::size_t i = 0; i < pieces.size(); ++i) {
    TriangleMesh one;
    std::vector<std::size_t> firsts;
    if (!sweep(pieces[i], sides, one, firsts)) continue;
    ++out.tubes;
    split_off(one, firsts, static_cast<int>(i));
  }
  // build_mesh's own shapes: the shallow struts, the feet, the posts.
  {
    MeshReport counts;
    TriangleMesh all;
    std::vector<std::size_t> firsts;
    weave_bar_shells(domain, layout, bars, strut, feet, carved, spec, all, firsts, counts);
    out.bridges = counts.bridges;
    out.feet = counts.feet;
    out.posts = counts.posts;
    split_off(all, firsts, -1);
  }
  // OF3: trimmed to the part.
  std::vector<char> keep(shells.size(), 1);
  if (trim && !shells.empty()) {
    const double over = 0.02;
    // Nothing below the bed (the part's lowest z): a vertex left within `over` of the part but under the bed would
    // become the file's lowest point and lift the bed off the solid's flat underside; it is raised onto the bed.
    double bed = 1e300;
    for (const Vec3& v : part.mesh().vertices) bed = std::min(bed, v.z);
    std::vector<double> moved_most(shells.size(), 0.0), outside_most(shells.size(), 0.0);
    std::vector<std::size_t> moved(shells.size(), 0);
    std::vector<char> rebuilt(shells.size(), 0);
    // Trims one shell in place; true when it is still closed (by index, untouched) with a positive volume of at
    // least 5 % of what it was.
    auto trim_one = [&](const PartMeasure::Probe& pr, TriangleMesh& m, std::size_t s) {
      const double before = volume_of(m, 0, m.triangles.size());
      std::size_t n = 0;
      double most = 0.0, outside = 0.0;
      for (Vec3& v : m.vertices) {
        if (v.z < bed) { v.z = bed; ++n; }
        if (pr.inside(v)) continue;
        double d = pr.depth(v);
        if (d >= -over) { outside = std::max(outside, -d); continue; }
        const Vec3 was = v;
        for (int it = 0; it < 4 && d < -1e-4; ++it) {
          v = add(v, mul(pr.through(v), -d));
          d = pr.depth(v);
        }
        if (v.z < bed) v.z = bed;
        ++n;
        most = std::max(most, len(sub(v, was)));
        outside = std::max(outside, std::max(0.0, -d));
      }
      const double after = volume_of(m, 0, m.triangles.size());
      moved[s] = n;
      moved_most[s] = most;
      outside_most[s] = outside;
      return after > 0.0 && after >= 0.05 * before;
    };
    // A tube made again from its run cut back where its line leaves the part: the longest stretch of its centre line
    // inside the part, ends found to a micron, flat there; an end that was inside keeps its own cap.
    auto cut_back = [&](const PartMeasure::Probe& pr, const Piece& pc, Piece& cut) {
      const std::size_t n = pc.p.size();
      std::vector<char> in(n);
      for (std::size_t j = 0; j < n; ++j) in[j] = pr.inside(pc.p[j]);
      // Each segment sampled at 0.1 mm for where the line is inside: the longest inside stretch, as (segment, t).
      struct At { std::size_t seg; double t; };
      std::vector<std::pair<At, At>> stretches;
      bool open = false;
      At from{0, 0.0};
      auto edge = [&](std::size_t k, double ta, double tb) {   // the place between ta (in) and tb (out) or back
        const bool a_in = pr.inside(add(pc.p[k], mul(sub(pc.p[k + 1], pc.p[k]), ta)));
        for (int it = 0; it < 30; ++it) {
          const double tm = 0.5 * (ta + tb);
          (pr.inside(add(pc.p[k], mul(sub(pc.p[k + 1], pc.p[k]), tm))) == a_in ? ta : tb) = tm;
        }
        return a_in ? ta : tb;
      };
      for (std::size_t k = 0; k + 1 < n; ++k) {
        const double L = len(sub(pc.p[k + 1], pc.p[k]));
        const int steps = std::max(1, static_cast<int>(std::ceil(L / 0.1)));
        double tp = 0.0;
        bool ip = pr.inside(pc.p[k]);
        if (k == 0 && ip) { open = true; from = {0, 0.0}; }
        for (int q = 1; q <= steps; ++q) {
          const double t = static_cast<double>(q) / steps;
          const bool i2 = pr.inside(add(pc.p[k], mul(sub(pc.p[k + 1], pc.p[k]), t)));
          if (i2 != ip) {
            const double te = edge(k, tp, t);
            if (i2) { open = true; from = {k, te}; }
            else if (open) { stretches.push_back({from, {k, te}}); open = false; }
          }
          ip = i2;
          tp = t;
        }
      }
      if (open) stretches.push_back({from, {n - 2, 1.0}});
      double best = 0.0;
      const std::pair<At, At>* pick = nullptr;
      auto along = [&](const At& a) {
        double l = 0.0;
        for (std::size_t k = 0; k < a.seg; ++k) l += len(sub(pc.p[k + 1], pc.p[k]));
        return l + a.t * len(sub(pc.p[a.seg + 1], pc.p[a.seg]));
      };
      for (const auto& st : stretches) {
        const double l = along(st.second) - along(st.first);
        if (l > best) { best = l; pick = &st; }
      }
      if (!pick || best < 1e-3) return false;
      auto point = [&](const At& a) { return add(pc.p[a.seg], mul(sub(pc.p[a.seg + 1], pc.p[a.seg]), a.t)); };
      auto radius = [&](const At& a) { return pc.r[a.seg] + (pc.r[a.seg + 1] - pc.r[a.seg]) * a.t; };
      cut = Piece{};
      cut.p.push_back(point(pick->first));
      cut.r.push_back(radius(pick->first));
      for (std::size_t j = pick->first.seg + 1; j <= pick->second.seg; ++j) {
        if (len(sub(pc.p[j], cut.p.back())) < 1e-6) continue;
        cut.p.push_back(pc.p[j]);
        cut.r.push_back(pc.r[j]);
      }
      const Vec3 e = point(pick->second);
      if (len(sub(e, cut.p.back())) > 1e-6) { cut.p.push_back(e); cut.r.push_back(radius(pick->second)); }
      if (cut.p.size() < 2) return false;
      const bool a_whole = pick->first.seg == 0 && pick->first.t == 0.0 && in[0];
      const bool b_whole = pick->second.seg == n - 2 && pick->second.t == 1.0 && in[n - 1];
      cut.cap_a = a_whole ? pc.cap_a : Cap::Flat;
      cut.cap_b = b_whole ? pc.cap_b : Cap::Flat;
      return true;
    };
    std::atomic<std::size_t> next{0};
    auto work = [&] {
      const PartMeasure::Probe pr = part.probe();
      for (std::size_t s = next.fetch_add(1); s < shells.size() && !(spec.stop && spec.stop->load()); s = next.fetch_add(1)) {
        if (trim_one(pr, shells[s], s)) continue;
        keep[s] = 0;
        if (made_from[s] < 0) continue;
        Piece cut;
        if (!cut_back(pr, pieces[static_cast<std::size_t>(made_from[s])], cut)) continue;
        TriangleMesh again;
        std::vector<std::size_t> firsts;
        if (!sweep(cut, sides, again, firsts)) continue;
        if (!trim_one(pr, again, s)) continue;
        shells[s] = std::move(again);
        keep[s] = 1;
        rebuilt[s] = 1;
      }
    };
    const int nt = std::max(1, std::min<int>(spec.threads > 0 ? spec.threads : static_cast<int>(std::thread::hardware_concurrency()),
                                            static_cast<int>(shells.size())));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    if (spec.stop && spec.stop->load()) throw LayCancelled{};
    for (std::size_t s = 0; s < shells.size(); ++s) {
      out.rebuilt += rebuilt[s];
      if (!keep[s]) { ++out.left_out; continue; }
      out.trimmed_vertices += moved[s];
      out.trimmed_largest_mm = std::max(out.trimmed_largest_mm, moved_most[s]);
      out.outside_largest_mm = std::max(out.outside_largest_mm, outside_most[s]);
    }
  }
  for (std::size_t s = 0; s < shells.size(); ++s) {
    if (!keep[s]) continue;
    const int base = static_cast<int>(out.mesh.vertices.size());
    out.first_tri.push_back(out.mesh.triangles.size());
    out.mesh.vertices.insert(out.mesh.vertices.end(), shells[s].vertices.begin(), shells[s].vertices.end());
    for (const auto& t : shells[s].triangles) out.mesh.triangles.push_back({t[0] + base, t[1] + base, t[2] + base});
    out.mm3 += volume_of(shells[s], 0, shells[s].triangles.size());
  }
  out.first_tri.push_back(out.mesh.triangles.size());
  out.ms = ms_since(t0);
  return out;
}

}  // namespace topopt::lattice_layout
