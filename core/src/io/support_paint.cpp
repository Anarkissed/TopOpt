// PAINTED SUPPORTS (support_paint.hpp; his print orientation, spec 1.5, P3).
#include "topopt/support_paint.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_map>

namespace topopt {
namespace {

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }

// The closest point of triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
Vec3 closest_on_triangle(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) return a;
  const Vec3 bp = sub(p, b);
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) return b;
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) return add(a, mul(ab, d1 / (d1 - d3)));
  const Vec3 cp = sub(p, c);
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) return c;
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) return add(a, mul(ac, d2 / (d2 - d6)));
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) return add(b, mul(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
  const double den = 1.0 / (va + vb + vc);
  return add(a, add(mul(ab, vb * den), mul(ac, vc * den)));
}

}  // namespace

SupportPaint paint_supports(const TriangleMesh& mesh, const SupportPaintAsk& ask) {
  SupportPaint out;
  const std::size_t nt = mesh.triangles.size();
  out.painted.assign(nt, 0);
  if (nt == 0 || mesh.vertices.empty()) return out;
  const std::size_t np = ask.part_triangles > 0 ? std::min(ask.part_triangles, nt) : nt;
  const double layer = ask.layer_mm > 0.0 ? ask.layer_mm : 0.2;
  double z_bed = std::numeric_limits<double>::infinity();
  for (const Vec3& v : mesh.vertices) z_bed = std::min(z_bed, v.z);
  out.z_bed = z_bed;
  const double down = std::cos(ask.down_deg * M_PI / 180.0), grow = std::cos(ask.grow_deg * M_PI / 180.0);
  std::vector<Vec3> nrm(np), cen(np);
  std::vector<double> area(np, 0.0);
  std::vector<char> cand(np, 0);
  for (std::size_t t = 0; t < np; ++t) {
    const auto& tri = mesh.triangles[t];
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 n = cross(sub(b, a), sub(c, a));
    const double l = std::sqrt(dot(n, n));
    if (!(l > 0.0)) continue;
    nrm[t] = mul(n, 1.0 / l);
    area[t] = 0.5 * l;
    cen[t] = {(a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0, (a.z + b.z + c.z) / 3.0};
    if (!(-nrm[t].z >= down)) continue;                 // faces down more than the threshold
    if (!(cen[t].z > z_bed + 0.5 * layer)) continue;    // on the bed
    if (ask.outside && !ask.outside({cen[t].x, cen[t].y, cen[t].z - layer})) continue;   // over the part or the lattice
    cand[t] = 1;
  }
  std::vector<int> seeds;
  if (ask.places) {
    const double reach = 1.5 * layer + ask.line_mm;
    for (const Vec3& p : *ask.places) {
      bool any = false;
      for (std::size_t t = 0; t < np; ++t) {
        if (!cand[t]) continue;
        const auto& tri = mesh.triangles[t];
        const Vec3 q = closest_on_triangle(p, mesh.vertices[static_cast<std::size_t>(tri[0])],
                                           mesh.vertices[static_cast<std::size_t>(tri[1])],
                                           mesh.vertices[static_cast<std::size_t>(tri[2])]);
        const Vec3 d = sub(p, q);
        if (dot(d, d) <= reach * reach) {
          seeds.push_back(static_cast<int>(t));
          any = true;
        }
      }
      if (any) {
        ++out.places;
        out.at.push_back(p);
      } else {
        ++out.places_unpainted;
      }
    }
  } else {
    for (std::size_t t = 0; t < np; ++t)
      if (cand[t]) seeds.push_back(static_cast<int>(t));
  }
  // Grow over shared edges to candidates turned at most grow_deg from the triangle grown from.
  std::unordered_map<std::uint64_t, std::vector<int>> edges;
  if (ask.places && !seeds.empty()) {
    for (std::size_t t = 0; t < np; ++t) {
      if (!cand[t]) continue;
      const auto& tri = mesh.triangles[t];
      for (int e = 0; e < 3; ++e) {
        const std::uint64_t u = static_cast<std::uint32_t>(tri[e]), v = static_cast<std::uint32_t>(tri[(e + 1) % 3]);
        edges[std::min(u, v) << 32 | std::max(u, v)].push_back(static_cast<int>(t));
      }
    }
  }
  std::vector<int> stack;
  for (const int s : seeds)
    if (!out.painted[static_cast<std::size_t>(s)]) {
      out.painted[static_cast<std::size_t>(s)] = 1;
      stack.push_back(s);
    }
  while (!stack.empty()) {
    const int t = stack.back();
    stack.pop_back();
    if (!ask.places) continue;
    const auto& tri = mesh.triangles[static_cast<std::size_t>(t)];
    for (int e = 0; e < 3; ++e) {
      const std::uint64_t u = static_cast<std::uint32_t>(tri[e]), v = static_cast<std::uint32_t>(tri[(e + 1) % 3]);
      const auto it = edges.find(std::min(u, v) << 32 | std::max(u, v));
      if (it == edges.end()) continue;
      for (const int w : it->second) {
        if (out.painted[static_cast<std::size_t>(w)]) continue;
        if (dot(nrm[static_cast<std::size_t>(t)], nrm[static_cast<std::size_t>(w)]) < grow) continue;
        out.painted[static_cast<std::size_t>(w)] = 1;
        stack.push_back(w);
      }
    }
  }
  // The counts, and the support under them: the area seen from below times the drop to the first material below (or
  // the bed), read every millimetre.
  for (std::size_t t = 0; t < np; ++t) {
    if (!out.painted[t]) continue;
    ++out.triangles;
    out.area_mm2 += area[t];
    double stop = z_bed;
    if (ask.outside)
      for (double z = cen[t].z - layer; z > z_bed; z -= 1.0)
        if (!ask.outside({cen[t].x, cen[t].y, z})) {
          stop = z;
          break;
        }
    out.est_volume_mm3 += area[t] * -nrm[t].z * std::max(0.0, cen[t].z - stop);
  }
  return out;
}

}  // namespace topopt
