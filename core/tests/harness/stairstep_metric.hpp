// stairstep_metric.hpp — THE MEASUREMENT of task 2026-08-05-
// smoothing-must-actually-smooth (PR 299), lifted VERBATIM out of
// `stairstep_probe.cpp` so a second probe can be judged by LITERALLY THE SAME
// CODE rather than by a re-implementation that agrees "in spirit".
//
// Task 2026-08-05-smoothing-sdf-geometry-extraction bar R3 requires its numbers
// to be directly comparable with PR 299's. Re-typing point-to-triangle distance,
// the oblique classification threshold or the p99 index would put a silent
// discrepancy exactly where the comparison lives, so nothing here is retyped:
// this file is a MOVE. `stairstep_probe.cpp` now includes it and defines none of
// these symbols itself, and its output is byte-identical across the move (see
// evidence/2026-08-05-smoothing-sdf-geometry-extraction/r3_metric_move.txt).
//
// Everything below is PR 299's text and code, unedited.

#pragma once

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <map>
#include <utility>
#include <vector>

namespace topopt {
namespace stairstep {

using Clock = std::chrono::steady_clock;
double secs_since(const Clock::time_point& t) {
  return std::chrono::duration<double>(Clock::now() - t).count();
}

// ── point-to-triangle distance, and a uniform grid to make it affordable ─────

double dist2_point_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                            const Vec3& c) {
  // Ericson, Real-Time Collision Detection §5.1.5 — closest point on a triangle.
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 ac{c.x - a.x, c.y - a.y, c.z - a.z};
  const Vec3 ap{p.x - a.x, p.y - a.y, p.z - a.z};
  const double d1 = ab.x * ap.x + ab.y * ap.y + ab.z * ap.z;
  const double d2 = ac.x * ap.x + ac.y * ap.y + ac.z * ap.z;
  auto d2_to = [&](const Vec3& q) {
    const double dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z;
    return dx * dx + dy * dy + dz * dz;
  };
  if (d1 <= 0.0 && d2 <= 0.0) return d2_to(a);

  const Vec3 bp{p.x - b.x, p.y - b.y, p.z - b.z};
  const double d3 = ab.x * bp.x + ab.y * bp.y + ab.z * bp.z;
  const double d4 = ac.x * bp.x + ac.y * bp.y + ac.z * bp.z;
  if (d3 >= 0.0 && d4 <= d3) return d2_to(b);

  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    const double v = d1 / (d1 - d3);
    return d2_to(Vec3{a.x + v * ab.x, a.y + v * ab.y, a.z + v * ab.z});
  }

  const Vec3 cp{p.x - c.x, p.y - c.y, p.z - c.z};
  const double d5 = ab.x * cp.x + ab.y * cp.y + ab.z * cp.z;
  const double d6 = ac.x * cp.x + ac.y * cp.y + ac.z * cp.z;
  if (d6 >= 0.0 && d5 <= d6) return d2_to(c);

  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    const double w = d2 / (d2 - d6);
    return d2_to(Vec3{a.x + w * ac.x, a.y + w * ac.y, a.z + w * ac.z});
  }

  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return d2_to(Vec3{b.x + w * (c.x - b.x), b.y + w * (c.y - b.y),
                      b.z + w * (c.z - b.z)});
  }

  const double denom = 1.0 / (va + vb + vc);
  const double v = vb * denom, w = vc * denom;
  return d2_to(Vec3{a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w,
                    a.z + ab.z * v + ac.z * w});
}

// Uniform grid over the reference triangles. Exact (not approximate): the query
// grows a Chebyshev box until the best distance found is no larger than the box
// half-width, at which point no triangle outside the box can beat it.
class TriGrid {
 public:
  explicit TriGrid(const TriangleMesh& m) : mesh_(&m) {
    if (m.triangles.empty()) return;
    Vec3 lo = m.vertices[0], hi = m.vertices[0];
    for (const Vec3& v : m.vertices) {
      lo.x = std::fmin(lo.x, v.x); hi.x = std::fmax(hi.x, v.x);
      lo.y = std::fmin(lo.y, v.y); hi.y = std::fmax(hi.y, v.y);
      lo.z = std::fmin(lo.z, v.z); hi.z = std::fmax(hi.z, v.z);
    }
    origin_ = lo;
    const double ex = hi.x - lo.x, ey = hi.y - lo.y, ez = hi.z - lo.z;
    const double vol = std::fmax(ex * ey * ez, 1e-12);
    // ~1 triangle per cell on average, clamped so the grid stays sane.
    cell_ = std::cbrt(vol / static_cast<double>(m.triangles.size()));
    cell_ = std::fmax(cell_, 1e-6);
    nx_ = std::clamp(static_cast<int>(ex / cell_) + 1, 1, 256);
    ny_ = std::clamp(static_cast<int>(ey / cell_) + 1, 1, 256);
    nz_ = std::clamp(static_cast<int>(ez / cell_) + 1, 1, 256);
    cell_ = std::fmax(std::fmax(ex / nx_, ey / ny_), ez / nz_);
    cell_ = std::fmax(cell_, 1e-6);
    bins_.assign(static_cast<std::size_t>(nx_) * ny_ * nz_, {});
    for (std::size_t t = 0; t < m.triangles.size(); ++t) {
      const auto& tr = m.triangles[t];
      Vec3 tlo = m.vertices[static_cast<std::size_t>(tr[0])], thi = tlo;
      for (int k = 1; k < 3; ++k) {
        const Vec3& v = m.vertices[static_cast<std::size_t>(tr[k])];
        tlo.x = std::fmin(tlo.x, v.x); thi.x = std::fmax(thi.x, v.x);
        tlo.y = std::fmin(tlo.y, v.y); thi.y = std::fmax(thi.y, v.y);
        tlo.z = std::fmin(tlo.z, v.z); thi.z = std::fmax(thi.z, v.z);
      }
      const int i0 = clampi(cellof(tlo.x - origin_.x), nx_);
      const int i1 = clampi(cellof(thi.x - origin_.x), nx_);
      const int j0 = clampi(cellof(tlo.y - origin_.y), ny_);
      const int j1 = clampi(cellof(thi.y - origin_.y), ny_);
      const int k0 = clampi(cellof(tlo.z - origin_.z), nz_);
      const int k1 = clampi(cellof(thi.z - origin_.z), nz_);
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            bins_[idx(i, j, k)].push_back(static_cast<int>(t));
    }
  }

  // Unsigned distance from `p` to the nearest point on the reference surface.
  double distance(const Vec3& p) const { return distance_and_tri(p).first; }

  // The distance AND the index of the reference triangle that carried it, so a
  // caller can ask what KIND of surface this vertex was supposed to sit on.
  std::pair<double, int> distance_and_tri(const Vec3& p) const {
    if (!mesh_ || mesh_->triangles.empty()) return {0.0, -1};
    int best_t = -1;
    double best2 = std::numeric_limits<double>::infinity();
    double r = cell_;
    for (int iter = 0; iter < 64; ++iter) {
      const int i0 = clampi(cellof(p.x - r - origin_.x), nx_);
      const int i1 = clampi(cellof(p.x + r - origin_.x), nx_);
      const int j0 = clampi(cellof(p.y - r - origin_.y), ny_);
      const int j1 = clampi(cellof(p.y + r - origin_.y), ny_);
      const int k0 = clampi(cellof(p.z - r - origin_.z), nz_);
      const int k1 = clampi(cellof(p.z + r - origin_.z), nz_);
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            for (const int t : bins_[idx(i, j, k)]) {
              const auto& tr = mesh_->triangles[static_cast<std::size_t>(t)];
              const double d2 = dist2_point_triangle(
                  p, mesh_->vertices[static_cast<std::size_t>(tr[0])],
                  mesh_->vertices[static_cast<std::size_t>(tr[1])],
                  mesh_->vertices[static_cast<std::size_t>(tr[2])]);
              if (d2 < best2) { best2 = d2; best_t = t; }
            }
      if (best2 <= r * r) break;  // nothing outside the box can beat it
      r *= 2.0;
    }
    return {std::sqrt(best2), best_t};
  }

  // Unit normal of reference triangle `t`.
  Vec3 tri_normal(int t) const {
    const auto& tr = mesh_->triangles[static_cast<std::size_t>(t)];
    const Vec3& a = mesh_->vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = mesh_->vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = mesh_->vertices[static_cast<std::size_t>(tr[2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
    const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
    Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    const double L = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (L > 0.0) { n.x /= L; n.y /= L; n.z /= L; }
    return n;
  }

 private:
  int cellof(double d) const { return static_cast<int>(std::floor(d / cell_)); }
  static int clampi(int v, int n) { return v < 0 ? 0 : (v >= n ? n - 1 : v); }
  std::size_t idx(int i, int j, int k) const {
    return static_cast<std::size_t>(k) * ny_ * nx_ +
           static_cast<std::size_t>(j) * nx_ + static_cast<std::size_t>(i);
  }
  const TriangleMesh* mesh_ = nullptr;
  Vec3 origin_;
  double cell_ = 1.0;
  int nx_ = 1, ny_ = 1, nz_ = 1;
  std::vector<std::vector<int>> bins_;
};

// ── the two readings ─────────────────────────────────────────────────────────

struct Deviation {
  double max_mm = 0.0;
  double rms_mm = 0.0;
  double p99_mm = 0.0;
  double mean_mm = 0.0;
};

// `only` empty ⇒ every vertex. Otherwise entry v selects vertex v — used to
// restrict the reading to the OBLIQUE surface, where stair-stepping lives.
Deviation deviation_from_cad(const TriangleMesh& m, const TriGrid& ref,
                             const std::vector<char>& only = {}) {
  Deviation d;
  if (m.vertices.empty()) return d;
  std::vector<double> all;
  all.reserve(m.vertices.size());
  double sum2 = 0.0, sum = 0.0;
  for (std::size_t i = 0; i < m.vertices.size(); ++i) {
    if (!only.empty() && !only[i]) continue;
    const double x = ref.distance(m.vertices[i]);
    all.push_back(x);
    sum2 += x * x;
    sum += x;
    if (x > d.max_mm) d.max_mm = x;
  }
  if (all.empty()) return d;
  const double n = static_cast<double>(all.size());
  d.rms_mm = std::sqrt(sum2 / n);
  d.mean_mm = sum / n;
  std::size_t k = static_cast<std::size_t>(0.99 * (n - 1.0));
  std::nth_element(all.begin(), all.begin() + static_cast<long>(k), all.end());
  d.p99_mm = all[k];
  return d;
}

// RMS dihedral angle (degrees) across every shared edge. A voxel staircase is
// 90-degree risers joined by 45-degree marching-cubes chamfers; a smooth surface
// is a few degrees. Corroboration only — see the header note.
double dihedral_rms_deg(const TriangleMesh& m) {
  std::map<std::pair<int, int>, std::vector<std::size_t>> edges;
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tr = m.triangles[t];
    for (int e = 0; e < 3; ++e) {
      int a = tr[e], b = tr[(e + 1) % 3];
      if (a > b) std::swap(a, b);
      edges[{a, b}].push_back(t);
    }
  }
  std::vector<Vec3> nrm(m.triangles.size());
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tr = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
    const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
    Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    const double L = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (L > 0.0) { n.x /= L; n.y /= L; n.z /= L; }
    nrm[t] = n;
  }
  double sum2 = 0.0;
  std::size_t cnt = 0;
  for (const auto& kv : edges) {
    if (kv.second.size() != 2) continue;
    const Vec3& a = nrm[kv.second[0]];
    const Vec3& b = nrm[kv.second[1]];
    double c = a.x * b.x + a.y * b.y + a.z * b.z;
    c = std::fmax(-1.0, std::fmin(1.0, c));
    const double deg = std::acos(c) * 180.0 / 3.14159265358979323846;
    sum2 += deg * deg;
    ++cnt;
  }
  return cnt ? std::sqrt(sum2 / static_cast<double>(cnt)) : 0.0;
}

double max_shift_mm(const TriangleMesh& a, const TriangleMesh& b) {
  double m = 0.0;
  const std::size_t n = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t i = 0; i < n; ++i) {
    const double dx = a.vertices[i].x - b.vertices[i].x;
    const double dy = a.vertices[i].y - b.vertices[i].y;
    const double dz = a.vertices[i].z - b.vertices[i].z;
    m = std::fmax(m, std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  return m;
}

int min_feature_now(const TriangleMesh& m, const VoxelGrid& ref) {
  try {
    const VoxelGrid g = voxelize_onto_grid(m, ref);
    std::vector<double> d(g.voxel_count(), 0.0);
    for (std::size_t i = 0; i < d.size(); ++i)
      if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
    return min_feature_violations(g, d, 0.5);
  } catch (const std::exception&) {
    return -1;
  }
}

// ── THE ANALYTIC CONTROL ─────────────────────────────────────────────────────
//
// The bracket's "CAD" is itself a 2224-triangle tessellation, so a slice of the
// deviation measured against it is the REFERENCE's own faceting rather than the
// voxelizer's staircase. A sphere has no such ambiguity: the exact surface is
// known in closed form, so the deviation |‖v−c‖ − R| is the voxelization error
// and nothing else. Run at the SAME voxel spacing as his part, so the staircase
// is the same physical size. This is the fixture the S1 assertion uses.
struct SphereReading {
  double max_mm = 0.0;
  double rms_mm = 0.0;
};

SphereReading sphere_deviation(const TriangleMesh& m, const Vec3& c, double R) {
  SphereReading s;
  if (m.vertices.empty()) return s;
  double sum2 = 0.0;
  for (const Vec3& v : m.vertices) {
    const double dx = v.x - c.x, dy = v.y - c.y, dz = v.z - c.z;
    const double e = std::fabs(std::sqrt(dx * dx + dy * dy + dz * dz) - R);
    sum2 += e * e;
    if (e > s.max_mm) s.max_mm = e;
  }
  s.rms_mm = std::sqrt(sum2 / static_cast<double>(m.vertices.size()));
  return s;
}

// An occupancy grid holding a solid sphere, at `spacing`, sampled at voxel
// centres exactly as the voxelizer decides occupancy.
VoxelGrid sphere_grid(double R, double spacing, Vec3& centre_out) {
  const int n = static_cast<int>(std::ceil(2.4 * R / spacing));
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
  // NOT voxel_count() — that reads tags.size(), which is still 0 here.
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  const double half = 0.5 * static_cast<double>(n) * spacing;
  centre_out = Vec3{half, half, half};
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        const Vec3 p = g.voxel_center(i, j, k);
        const double dx = p.x - centre_out.x, dy = p.y - centre_out.y,
                     dz = p.z - centre_out.z;
        if (dx * dx + dy * dy + dz * dz <= R * R)
          g.tags[g.index(i, j, k)] = VoxelTag::Interior;
      }
  return g;
}
}  // namespace stairstep
}  // namespace topopt
