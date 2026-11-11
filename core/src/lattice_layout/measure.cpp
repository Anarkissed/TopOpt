// Lattice layout, stage B: the part measured on its real surface. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <unordered_map>
#include <utility>

namespace topopt::lattice_layout {

TriangleMesh weld_mesh(const TriangleMesh& in, double tol_mm, std::size_t* open_edges) {
  TriangleMesh out;
  struct Key {
    long long x, y, z;
    bool operator==(const Key& o) const { return x == o.x && y == o.y && z == o.z; }
  };
  struct Hash {
    std::size_t operator()(const Key& k) const {
      return std::hash<long long>()(k.x * 73856093LL ^ k.y * 19349663LL ^ k.z * 83492791LL);
    }
  };
  const double q = 1.0 / (tol_mm > 0.0 ? tol_mm : 1e-5);
  std::unordered_map<Key, int, Hash> ids;
  ids.reserve(in.vertices.size());
  auto id_of = [&](const Vec3& v) {
    const Key k{std::llround(v.x * q), std::llround(v.y * q), std::llround(v.z * q)};
    auto it = ids.find(k);
    if (it != ids.end()) return it->second;
    const int n = static_cast<int>(out.vertices.size());
    out.vertices.push_back(v);
    ids.emplace(k, n);
    return n;
  };
  std::map<std::pair<int, int>, int> edges;
  for (const auto& t : in.triangles) {
    const int a = id_of(in.vertices[t[0]]), b = id_of(in.vertices[t[1]]),
              c = id_of(in.vertices[t[2]]);
    if (a == b || b == c || a == c) continue;  // collapsed by the weld
    out.triangles.push_back({a, b, c});
    const int e[3][2] = {{a, b}, {b, c}, {c, a}};
    for (const auto& p : e) ++edges[{std::min(p[0], p[1]), std::max(p[0], p[1])}];
  }
  if (open_edges) {
    *open_edges = 0;
    for (const auto& kv : edges)
      if (kv.second != 2) ++*open_edges;
  }
  return out;
}

PartMeasure::PartMeasure(TriangleMesh mesh)
    : mesh_(std::make_shared<const TriangleMesh>(std::move(mesh))) {
  lo_ = Vec3{1e300, 1e300, 1e300};
  hi_ = Vec3{-1e300, -1e300, -1e300};
  for (const Vec3& v : mesh_->vertices) {
    lo_.x = std::min(lo_.x, v.x); lo_.y = std::min(lo_.y, v.y); lo_.z = std::min(lo_.z, v.z);
    hi_.x = std::max(hi_.x, v.x); hi_.y = std::max(hi_.y, v.y); hi_.z = std::max(hi_.z, v.z);
  }
  if (mesh_->vertices.empty()) lo_ = hi_ = Vec3{};
  diag_ = std::sqrt((hi_.x - lo_.x) * (hi_.x - lo_.x) + (hi_.y - lo_.y) * (hi_.y - lo_.y) +
                    (hi_.z - lo_.z) * (hi_.z - lo_.z));
}

// Walk from p along the direction by the exact distance to the surface: a step of that
// length can never cross it, and on a face met square-on the first step lands on it
// exactly. A ray that runs ALONG a surface a hair away from it (a cell face lying in a
// part face, which round numbers produce all the time) would crawl, so a step is never
// under 0.01 mm; the crossing it may then overshoot is found again by halving.
double PartMeasure::Probe::reach(const Vec3& p, const Vec3& d) const {
  const double kMinStep = 0.01;   // mm
  auto depth_at = [&](double t) {
    return md_.signed_distance(Vec3{p.x + d.x * t, p.y + d.y * t, p.z + d.z * t});
  };
  double t = 0.0, s = depth_at(0.0);
  if (s <= 0.0) return 0.0;
  for (int i = 0; i < 100000 && t < max_mm_; ++i) {
    const double prev = t;
    t += std::max(s, kMinStep);
    s = depth_at(t);
    if (s > 0.0) continue;
    double in = prev, out = t;          // inside at `in`, not inside at `out`
    for (int k = 0; k < 24 && out - in > 1e-6; ++k) {
      const double m = 0.5 * (in + out);
      if (depth_at(m) > 0.0) in = m; else out = m;
    }
    return 0.5 * (in + out);
  }
  return t;
}

Vec3 PartMeasure::Probe::through(const Vec3& p) const {
  // The exact distance falls fastest toward the nearest surface. Central differences
  // over a 0.05 mm stencil; on the middle of a wall both sides are equally near and
  // either answer runs straight through it.
  const double h = 0.05;
  Vec3 g{md_.signed_distance({p.x + h, p.y, p.z}) - md_.signed_distance({p.x - h, p.y, p.z}),
         md_.signed_distance({p.x, p.y + h, p.z}) - md_.signed_distance({p.x, p.y - h, p.z}),
         md_.signed_distance({p.x, p.y, p.z + h}) - md_.signed_distance({p.x, p.y, p.z - h})};
  double n = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
  if (n < 1e-9) {
    // Dead centre: step a hair off it and ask again.
    const Vec3 q{p.x + 0.013, p.y + 0.007, p.z + 0.003};
    g = Vec3{md_.signed_distance({q.x + h, q.y, q.z}) - md_.signed_distance({q.x - h, q.y, q.z}),
             md_.signed_distance({q.x, q.y + h, q.z}) - md_.signed_distance({q.x, q.y - h, q.z}),
             md_.signed_distance({q.x, q.y, q.z + h}) - md_.signed_distance({q.x, q.y, q.z - h})};
    n = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
    if (n < 1e-9) return Vec3{0, 0, 1};
  }
  return Vec3{g.x / n, g.y / n, g.z / n};
}

double PartMeasure::Probe::thickness(const Vec3& p) const {
  if (depth(p) <= 0.0) return 0.0;
  // Candidate widths: straight toward the nearest surface, and 13 fixed directions.
  const double a = std::sqrt(0.5), b = std::sqrt(1.0 / 3.0);
  Vec3 dirs[14] = {through(p), {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {a, a, 0}, {a, -a, 0},
                   {a, 0, a}, {a, 0, -a}, {0, a, a}, {0, a, -a}, {b, b, b}, {b, b, -b},
                   {b, -b, b}, {b, -b, -b}};
  struct Chord { double fwd, back; int dir; };
  Chord chords[14];
  for (int i = 0; i < 14; ++i) {
    const Vec3 n{-dirs[i].x, -dirs[i].y, -dirs[i].z};
    chords[i] = {reach(p, dirs[i]), reach(p, n), i};
  }
  std::sort(chords, chords + 14, [](const Chord& x, const Chord& y) {
    return x.fwd + x.back != y.fwd + y.back ? x.fwd + x.back < y.fwd + y.back : x.dir < y.dir;
  });
  // A width is a WALL's width only if it is measured square to one of the two surfaces
  // it joins, and does not merely graze the other. A line that clips across a corner
  // meets both at a slant and is not the wall; a line square to the back of a plate that
  // ends on a countersink is the wall there. The narrowest that qualifies is the answer.
  const double kSquare = 0.85;   // cos of about 32 degrees
  const double kGraze = 0.5;     // cos of 60 degrees
  auto squareness = [&](const Vec3& d, double t) {
    const double in = t > 0.4 ? t - 0.2 : 0.5 * t;   // a point just inside the hit
    const Vec3 n = through(Vec3{p.x + d.x * in, p.y + d.y * in, p.z + d.z * in});
    return std::fabs(n.x * d.x + n.y * d.y + n.z * d.z);
  };
  // Nor is it a wall's width if it ends on an inside corner (the edge where a step or a
  // rib meets the wall): the line toward such an edge is always "square" to it, and is
  // shorter than the wall the point sits in. An inside corner is where the depth below
  // the surface curves upward to either side; next to a flat or rounded-out face it
  // does not.
  auto ends_on_inside_corner = [&](const Vec3& d, double t) {
    const double in = t > 0.4 ? 0.2 : 0.5 * t;
    if (in <= 0.0) return false;
    const Vec3 q{p.x + d.x * (t - in), p.y + d.y * (t - in), p.z + d.z * (t - in)};
    const Vec3 ref = std::fabs(d.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
    Vec3 e1{d.y * ref.z - d.z * ref.y, d.z * ref.x - d.x * ref.z, d.x * ref.y - d.y * ref.x};
    const double l = std::sqrt(e1.x * e1.x + e1.y * e1.y + e1.z * e1.z);
    e1 = {e1.x / l, e1.y / l, e1.z / l};
    const Vec3 e2{d.y * e1.z - d.z * e1.y, d.z * e1.x - d.x * e1.z, d.x * e1.y - d.y * e1.x};
    const double s = 0.5 * in, here = depth(q);
    for (const Vec3& e : {e1, e2}) {
      const double bend = depth(Vec3{q.x + e.x * s, q.y + e.y * s, q.z + e.z * s}) +
                          depth(Vec3{q.x - e.x * s, q.y - e.y * s, q.z - e.z * s}) - 2.0 * here;
      if (bend > 0.1 * s) return true;
    }
    return false;
  };
  for (const Chord& c : chords) {
    const Vec3& d = dirs[c.dir];
    const Vec3 back{-d.x, -d.y, -d.z};
    const double s1 = squareness(d, c.fwd), s2 = squareness(back, c.back);
    if (std::max(s1, s2) >= kSquare && std::min(s1, s2) >= kGraze &&
        !ends_on_inside_corner(d, c.fwd) && !ends_on_inside_corner(back, c.back))
      return c.fwd + c.back;
  }
  // Nothing qualified (a sharp wedge, a point in a fillet): the width
  // toward the nearest surface is the honest reading.
  for (const Chord& c : chords)
    if (c.dir == 0) return c.fwd + c.back;
  return 0.0;
}

}  // namespace topopt::lattice_layout
