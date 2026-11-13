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

  // The grid for straight lines: about two cells per triangle, at most 128 a side.
  auto grid = std::make_shared<RayGrid>();
  const std::size_t nt = mesh_->triangles.size();
  const double pad = 1e-6 * std::max(diag_, 1.0);
  grid->lo = Vec3{lo_.x - pad, lo_.y - pad, lo_.z - pad};
  const double ext[3] = {hi_.x - lo_.x + 2 * pad, hi_.y - lo_.y + 2 * pad, hi_.z - lo_.z + 2 * pad};
  const double longest = std::max(ext[0], std::max(ext[1], ext[2]));
  grid->cell = std::max(std::cbrt(ext[0] * ext[1] * ext[2] / std::max<std::size_t>(1, 2 * nt)),
                        longest / 128.0);
  for (int a = 0; a < 3; ++a)
    grid->n[a] = std::max(1, static_cast<int>(std::ceil(ext[a] / grid->cell)));
  const std::size_t cells = static_cast<std::size_t>(grid->n[0]) * grid->n[1] * grid->n[2];
  auto span = [&](const std::array<int, 3>& t, int lo3[3], int hi3[3]) {
    for (int a = 0; a < 3; ++a) {
      double mn = 1e300, mx = -1e300;
      for (int k = 0; k < 3; ++k) {
        const Vec3& v = mesh_->vertices[static_cast<std::size_t>(t[k])];
        const double x = a == 0 ? v.x : a == 1 ? v.y : v.z;
        mn = std::min(mn, x); mx = std::max(mx, x);
      }
      const double g = a == 0 ? grid->lo.x : a == 1 ? grid->lo.y : grid->lo.z;
      lo3[a] = std::clamp(static_cast<int>(std::floor((mn - pad - g) / grid->cell)), 0, grid->n[a] - 1);
      hi3[a] = std::clamp(static_cast<int>(std::floor((mx + pad - g) / grid->cell)), 0, grid->n[a] - 1);
    }
  };
  grid->start.assign(cells + 1, 0);
  std::vector<std::uint32_t> at;   // while filling: the next free place of each cell
  for (int fill = 0; fill < 2; ++fill) {
    for (std::size_t i = 0; i < nt; ++i) {
      const auto& t = mesh_->triangles[i];
      int lo3[3], hi3[3];
      span(t, lo3, hi3);
      for (int z = lo3[2]; z <= hi3[2]; ++z)
        for (int y = lo3[1]; y <= hi3[1]; ++y)
          for (int x = lo3[0]; x <= hi3[0]; ++x) {
            const std::size_t c = (static_cast<std::size_t>(z) * grid->n[1] + y) * grid->n[0] + x;
            if (fill) grid->tris[at[c]++] = static_cast<std::uint32_t>(i);
            else ++grid->start[c + 1];
          }
    }
    if (!fill) {
      for (std::size_t c = 0; c < cells; ++c) grid->start[c + 1] += grid->start[c];
      grid->tris.resize(grid->start[cells]);
      at.assign(grid->start.begin(), grid->start.end() - 1);
    }
  }
  double volume6 = 0.0;
  for (const auto& t : mesh_->triangles) {
    const Vec3& a = mesh_->vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh_->vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh_->vertices[static_cast<std::size_t>(t[2])];
    volume6 += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
               a.z * (b.x * c.y - b.y * c.x);
  }
  grid->outward = volume6 >= 0.0;
  grid_ = std::move(grid);
}

// A straight line from p against the triangles, cell by cell of the grid, nearest hit
// first. Which side of a triangle's edge the line passes is worked out from that edge's
// two corners alone, in one fixed order of arithmetic, so the two triangles that share
// an edge always agree: the line can never slip between them, and it never meets a
// triangle it passes beside (Woop, Benthin and Wald's watertight test, in doubles). A
// line exactly through an edge or a corner meets both; a line that only touches the
// surface has reached it, as a point on the surface is not inside.
#pragma STDC FP_CONTRACT OFF
double PartMeasure::Probe::cast(const Vec3& p, const Vec3& d, int* facing) const {
  const RayGrid& g = *grid_;
  const double o[3] = {p.x - g.lo.x, p.y - g.lo.y, p.z - g.lo.z}, dir[3] = {d.x, d.y, d.z};
  int cell[3], step[3];
  double next[3], delta[3];
  for (int a = 0; a < 3; ++a) {
    cell[a] = static_cast<int>(std::floor(o[a] / g.cell));
    if (cell[a] < 0 || cell[a] >= g.n[a]) return -1.0;   // not in the part's own box
    step[a] = dir[a] > 0.0 ? 1 : -1;
    if (dir[a] == 0.0) {
      next[a] = delta[a] = 1e300;
    } else {
      const double edge = (cell[a] + (dir[a] > 0.0 ? 1 : 0)) * g.cell;
      next[a] = (edge - o[a]) / dir[a];
      delta[a] = g.cell / std::fabs(dir[a]);
    }
  }
  // The line's own axes: kz the one it runs most along, the other two sheared so the
  // line is straight down kz.
  int kz = std::fabs(dir[0]) > std::fabs(dir[1]) ? 0 : 1;
  if (std::fabs(dir[2]) > std::fabs(dir[kz])) kz = 2;
  if (dir[kz] == 0.0) return -1.0;
  int kx = (kz + 1) % 3, ky = (kx + 1) % 3;
  if (dir[kz] < 0.0) std::swap(kx, ky);
  const double sx = dir[kx] / dir[kz], sy = dir[ky] / dir[kz], sz = 1.0 / dir[kz];
  const double from[3] = {p.x, p.y, p.z};
  double best = 1e300;
  int seen = 0;   // of the nearest spot: 1 = a surface seen from inside, 2 = from outside
  for (;;) {
    const std::size_t c = (static_cast<std::size_t>(cell[2]) * g.n[1] + cell[1]) * g.n[0] + cell[0];
    for (std::uint32_t k = g.start[c]; k < g.start[c + 1]; ++k) {
      const auto& t = mesh_->triangles[g.tris[k]];
      double x[3], y[3], z[3];   // each corner, seen down the line
      for (int i = 0; i < 3; ++i) {
        const Vec3& v = mesh_->vertices[static_cast<std::size_t>(t[i])];
        const double q[3] = {v.x - from[0], v.y - from[1], v.z - from[2]};
        const double qx = sx * q[kz], qy = sy * q[kz];
        x[i] = q[kx] - qx;
        y[i] = q[ky] - qy;
        z[i] = sz * q[kz];
      }
      // One product per corner pair, each formed on its own: the same two corners give
      // the same two numbers whichever triangle asks.
      const double u1 = x[2] * y[1], u2 = y[2] * x[1];
      const double v1 = x[0] * y[2], v2 = y[0] * x[2];
      const double w1 = x[1] * y[0], w2 = y[1] * x[0];
      const double u = u1 - u2, v = v1 - v2, w = w1 - w2;
      if ((u < 0.0 || v < 0.0 || w < 0.0) && (u > 0.0 || v > 0.0 || w > 0.0)) continue;
      const double det = u + v + w;
      if (det == 0.0) continue;   // edge-on: the line runs in the triangle's plane
      const double at = (u * z[0] + v * z[1] + w * z[2]) / det;
      if (at < 0.0) continue;     // behind the start
      if (at > best + 1e-9) continue;
      if (at < best - 1e-9) seen = 0;
      best = std::min(best, at);
      if (!facing) continue;
      const Vec3& a = mesh_->vertices[static_cast<std::size_t>(t[0])];
      const Vec3& b = mesh_->vertices[static_cast<std::size_t>(t[1])];
      const Vec3& e = mesh_->vertices[static_cast<std::size_t>(t[2])];
      const Vec3 e1{b.x - a.x, b.y - a.y, b.z - a.z}, e2{e.x - a.x, e.y - a.y, e.z - a.z};
      const double nd = (e1.y * e2.z - e1.z * e2.y) * d.x + (e1.z * e2.x - e1.x * e2.z) * d.y +
                        (e1.x * e2.y - e1.y * e2.x) * d.z;
      seen |= (nd > 0.0) == g.outward ? 1 : 2;
    }
    const int a = next[0] <= next[1] ? (next[0] <= next[2] ? 0 : 2) : (next[1] <= next[2] ? 1 : 2);
    if (best <= next[a] + 1e-9) break;   // nothing in a farther cell can be nearer
    cell[a] += step[a];
    if (cell[a] < 0 || cell[a] >= g.n[a]) break;
    next[a] += delta[a];
  }
  if (facing) *facing = seen == 1 ? 1 : (seen == 2 ? -1 : 0);
  return best < 1e300 ? best : -1.0;
}

namespace {
// The squared distance from p to the triangle abc (Ericson, Real-Time Collision Detection).
double point_triangle_distance2(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  auto sub = [](const Vec3& x, const Vec3& y) { return Vec3{x.x - y.x, x.y - y.y, x.z - y.z}; };
  auto dot = [](const Vec3& x, const Vec3& y) { return x.x * y.x + x.y * y.y + x.z * y.z; };
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) return dot(ap, ap);
  const Vec3 bp = sub(p, b);
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) return dot(bp, bp);
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    const double v = d1 / (d1 - d3);
    const Vec3 q{ap.x - v * ab.x, ap.y - v * ab.y, ap.z - v * ab.z};
    return dot(q, q);
  }
  const Vec3 cp = sub(p, c);
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) return dot(cp, cp);
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    const double w = d2 / (d2 - d6);
    const Vec3 q{ap.x - w * ac.x, ap.y - w * ac.y, ap.z - w * ac.z};
    return dot(q, q);
  }
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    const Vec3 bc = sub(c, b);
    const Vec3 q{bp.x - w * bc.x, bp.y - w * bc.y, bp.z - w * bc.z};
    return dot(q, q);
  }
  const double denom = 1.0 / (va + vb + vc), v = vb * denom, w = vc * denom;
  const Vec3 q{ap.x - v * ab.x - w * ac.x, ap.y - v * ab.y - w * ac.y, ap.z - v * ab.z - w * ac.z};
  return dot(q, q);
}
}  // namespace

double PartMeasure::Probe::depth_up_to(const Vec3& p, double limit) const {
  const RayGrid& g = *grid_;
  const double o[3] = {p.x - g.lo.x, p.y - g.lo.y, p.z - g.lo.z};
  int lo[3], hi[3], mid[3];
  for (int a = 0; a < 3; ++a) {
    lo[a] = std::max(0, static_cast<int>(std::floor((o[a] - limit) / g.cell)));
    hi[a] = std::min(g.n[a] - 1, static_cast<int>(std::floor((o[a] + limit) / g.cell)));
    mid[a] = std::clamp(static_cast<int>(std::floor(o[a] / g.cell)), lo[a], hi[a]);
  }
  // Every triangle within `limit` of the point is listed in a cell its box reaches, and
  // so in one of the cells the point's own box of that size reaches. The point's own
  // cell first: what it finds lets most of the others be passed over unread (a cell
  // farther from the point than the nearest triangle found holds nothing nearer).
  double best2 = limit * limit;
  auto read = [&](int x, int y, int z) {
    const std::size_t c = (static_cast<std::size_t>(z) * g.n[1] + y) * g.n[0] + x;
    for (std::uint32_t k = g.start[c]; k < g.start[c + 1]; ++k) {
      const auto& t = mesh_->triangles[g.tris[k]];
      best2 = std::min(best2, point_triangle_distance2(p, mesh_->vertices[static_cast<std::size_t>(t[0])],
                                                       mesh_->vertices[static_cast<std::size_t>(t[1])],
                                                       mesh_->vertices[static_cast<std::size_t>(t[2])]));
    }
  };
  if (lo[0] <= hi[0] && lo[1] <= hi[1] && lo[2] <= hi[2]) read(mid[0], mid[1], mid[2]);
  for (int z = lo[2]; z <= hi[2]; ++z)
    for (int y = lo[1]; y <= hi[1]; ++y)
      for (int x = lo[0]; x <= hi[0]; ++x) {
        if (x == mid[0] && y == mid[1] && z == mid[2]) continue;
        const int at[3] = {x, y, z};
        double away2 = 0.0;   // from the point to this cell's box
        for (int a = 0; a < 3; ++a) {
          const double low = at[a] * g.cell, high = low + g.cell;
          const double d = o[a] < low ? low - o[a] : (o[a] > high ? o[a] - high : 0.0);
          away2 += d * d;
        }
        if (away2 >= best2) continue;
        read(x, y, z);
      }
  return std::sqrt(best2);
}

bool PartMeasure::Probe::inside_along(const Vec3& p, const Vec3& unit_dir, double* reach) const {
  const double kSkin = 1e-6;   // mm: the same micron Domain::where has always used
  const RayGrid& g = *grid_;
  const double o[3] = {p.x - g.lo.x, p.y - g.lo.y, p.z - g.lo.z};
  int cell[3];
  for (int a = 0; a < 3; ++a) {
    cell[a] = static_cast<int>(std::floor(o[a] / g.cell));
    if (cell[a] < 0 || cell[a] >= g.n[a]) return false;   // not in the part's own box
  }
  // Every triangle within a micron of the point is listed in the point's own cell (a
  // triangle is listed wherever its box, a micron larger, reaches).
  const std::size_t c = (static_cast<std::size_t>(cell[2]) * g.n[1] + cell[1]) * g.n[0] + cell[0];
  for (std::uint32_t k = g.start[c]; k < g.start[c + 1]; ++k) {
    const auto& t = mesh_->triangles[g.tris[k]];
    if (point_triangle_distance2(p, mesh_->vertices[static_cast<std::size_t>(t[0])],
                                 mesh_->vertices[static_cast<std::size_t>(t[1])],
                                 mesh_->vertices[static_cast<std::size_t>(t[2])]) <= kSkin * kSkin)
      return false;
  }
  // The first surface along any one line is seen from inside exactly when the point is
  // inside. Should the line meet an edge between a surface seen from inside and one seen
  // from outside (it only brushes the part there), the distance decides.
  int facing = 0;
  const double t = cast(p, unit_dir, &facing);
  if (t < 0.0) return false;
  if (facing < 0 || (facing == 0 && !(md_.signed_distance(p) > kSkin))) return false;
  if (reach) *reach = t;
  return true;
}

double PartMeasure::Probe::reach(const Vec3& p, const Vec3& d, double depth_at_p) const {
  if (depth_at_p <= 0.0) return 0.0;
  const double t = reach_by_line(p, d);
  // Every point nearer than the depth is material, so a surface met sooner is no surface.
  if (t >= depth_at_p - 1e-6) return t;
  return reach_by_walk(p, d, depth_at_p);
}

// Walk from p along the direction by the exact distance to the surface: a step of that
// length can never cross it, and on a face met square-on the first step lands on it
// exactly. A ray that runs ALONG a surface a hair away from it (a cell face lying in a
// part face, which round numbers produce all the time) would crawl, so a step is never
// under 0.01 mm; the crossing such a forced step may overshoot is found again by halving.
// A step of the distance itself that ends "not inside" has landed ON the surface (the
// ball it crossed is all material), so that is the answer and nothing is searched for.
// (To a nanometre: the last digits of a distance are rounding, either side of zero.)
double PartMeasure::Probe::reach_by_walk(const Vec3& p, const Vec3& d, double depth_at_p) const {
  const double kMinStep = 0.01, kOn = 1e-9;   // mm
  auto depth_at = [&](double t) {
    return md_.signed_distance(Vec3{p.x + d.x * t, p.y + d.y * t, p.z + d.z * t});
  };
  double t = 0.0, s = depth_at_p;
  if (s <= 0.0) return 0.0;
  for (int i = 0; i < 100000 && t < max_mm_; ++i) {
    const double prev = t;
    const bool forced = s < kMinStep;
    t += forced ? kMinStep : s;
    s = depth_at(t);
    if (s > (forced ? 0.0 : kOn)) continue;
    if (!forced) return t;
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

double PartMeasure::Probe::thickness_in(const Vec3& p, double at_least, Line* line) const {
  // Candidate widths: straight toward the nearest surface, and 13 fixed directions.
  const double a = std::sqrt(0.5), b = std::sqrt(1.0 / 3.0);
  Vec3 dirs[14] = {through(p), {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {a, a, 0}, {a, -a, 0},
                   {a, 0, a}, {a, 0, -a}, {0, a, a}, {0, a, -a}, {b, b, b}, {b, b, -b},
                   {b, -b, b}, {b, -b, -b}};
  struct Chord { double fwd, back; int dir; };
  Chord chords[14];
  for (int i = 0; i < 14; ++i) {
    const Vec3 n{-dirs[i].x, -dirs[i].y, -dirs[i].z};
    chords[i] = {reach_in(p, dirs[i]), reach_in(p, n), i};
  }
  std::sort(chords, chords + 14, [](const Chord& x, const Chord& y) {
    return x.fwd + x.back != y.fwd + y.back ? x.fwd + x.back < y.fwd + y.back : x.dir < y.dir;
  });
  auto answer = [&](const Chord& c) {
    if (line) *line = Line{dirs[c.dir], c.fwd, c.back};
    return c.fwd + c.back;
  };
  if (at_least > 0.0 && chords[0].fwd + chords[0].back >= at_least)
    return answer(chords[0]);   // nothing through here is narrower
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
      return answer(c);
  }
  // Nothing qualified (a sharp wedge, a point in a fillet): the width
  // toward the nearest surface is the honest reading.
  for (const Chord& c : chords)
    if (c.dir == 0) return answer(c);
  return 0.0;
}

}  // namespace topopt::lattice_layout
