// segment.cpp — dihedral-angle mesh segmentation into pseudo-faces (handoff
// 134). See segment.hpp for the contract and the determinism rules; this file
// is the implementation of them.
//
// Deliberately Eigen-free and OCCT-free: it is compiled into every slice of the
// core, including the dependency-free iOS slices, because an STL/3MF import
// must produce selectable faces on device even where STEP import cannot exist.

#include "topopt/segment.hpp"

#include <algorithm>
#include <cmath>
#include <deque>
#include <map>
#include <stdexcept>
#include <utility>

namespace topopt {
namespace {

struct V3 {
  double x = 0.0, y = 0.0, z = 0.0;
};

V3 sub(const Vec3& a, const Vec3& b) { return V3{a.x - b.x, a.y - b.y, a.z - b.z}; }
V3 cross(const V3& a, const V3& b) {
  return V3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double dot(const V3& a, const V3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double norm(const V3& a) { return std::sqrt(dot(a, a)); }

// Twice-area normal of a triangle (length == 2 * area, direction == winding
// normal). A degenerate triangle yields the zero vector.
V3 face_normal_2a(const TriangleMesh& mesh, std::size_t t) {
  const auto& tri = mesh.triangles[t];
  const Vec3& p0 = mesh.vertices[static_cast<std::size_t>(tri[0])];
  const Vec3& p1 = mesh.vertices[static_cast<std::size_t>(tri[1])];
  const Vec3& p2 = mesh.vertices[static_cast<std::size_t>(tri[2])];
  return cross(sub(p1, p0), sub(p2, p0));
}

// Solve a 3x3 dense system by Gaussian elimination with partial pivoting.
// Returns false if the matrix is numerically singular. `a` is row-major.
bool solve3(double a[9], double b[3], double out[3]) {
  int perm[3] = {0, 1, 2};
  for (int col = 0; col < 3; ++col) {
    int pivot = col;
    double best = std::fabs(a[perm[col] * 3 + col]);
    for (int r = col + 1; r < 3; ++r) {
      const double v = std::fabs(a[perm[r] * 3 + col]);
      if (v > best) {
        best = v;
        pivot = r;
      }
    }
    if (best < 1e-14) return false;
    std::swap(perm[col], perm[pivot]);
    for (int r = col + 1; r < 3; ++r) {
      const double f = a[perm[r] * 3 + col] / a[perm[col] * 3 + col];
      if (f == 0.0) continue;
      for (int c = col; c < 3; ++c) a[perm[r] * 3 + c] -= f * a[perm[col] * 3 + c];
      b[perm[r]] -= f * b[perm[col]];
    }
  }
  for (int col = 2; col >= 0; --col) {
    double s = b[perm[col]];
    for (int c = col + 1; c < 3; ++c) s -= a[perm[col] * 3 + c] * out[c];
    out[col] = s / a[perm[col] * 3 + col];
  }
  return true;
}

// Give a direction a deterministic sign: the component of largest magnitude is
// made positive (ties broken by axis order x, y, z). Two runs over the same
// mesh therefore agree on the axis SENSE, not just the line.
V3 canonical_sign(V3 d) {
  int best = 0;
  for (int i = 1; i < 3; ++i) {
    const double* c = &d.x;
    if (std::fabs(c[i]) > std::fabs(c[best]) + 1e-15) best = i;
  }
  const double* c = &d.x;
  if (c[best] < 0.0) {
    d.x = -d.x;
    d.y = -d.y;
    d.z = -d.z;
  }
  return d;
}

}  // namespace

void symmetric_eigen3(const double a_in[9], double values[3], double vectors[9]) {
  double a[9];
  for (int i = 0; i < 9; ++i) a[i] = a_in[i];
  // V accumulates the rotations; its COLUMNS are the eigenvectors.
  double v[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};

  // Fixed sweep count (not a tolerance-driven loop): cyclic Jacobi on a 3x3
  // converges far inside this, and a fixed count keeps the result identical
  // across runs and platforms.
  for (int sweep = 0; sweep < 24; ++sweep) {
    const int pq[3][2] = {{0, 1}, {0, 2}, {1, 2}};
    for (int k = 0; k < 3; ++k) {
      const int p = pq[k][0], q = pq[k][1];
      const double apq = a[p * 3 + q];
      if (std::fabs(apq) < 1e-300) continue;
      const double theta = (a[q * 3 + q] - a[p * 3 + p]) / (2.0 * apq);
      const double sign = theta >= 0.0 ? 1.0 : -1.0;
      const double t = sign / (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
      const double c = 1.0 / std::sqrt(t * t + 1.0);
      const double s = t * c;
      for (int i = 0; i < 3; ++i) {
        const double aip = a[i * 3 + p], aiq = a[i * 3 + q];
        a[i * 3 + p] = c * aip - s * aiq;
        a[i * 3 + q] = s * aip + c * aiq;
      }
      for (int i = 0; i < 3; ++i) {
        const double api = a[p * 3 + i], aqi = a[q * 3 + i];
        a[p * 3 + i] = c * api - s * aqi;
        a[q * 3 + i] = s * api + c * aqi;
      }
      for (int i = 0; i < 3; ++i) {
        const double vip = v[i * 3 + p], viq = v[i * 3 + q];
        v[i * 3 + p] = c * vip - s * viq;
        v[i * 3 + q] = s * vip + c * viq;
      }
    }
  }

  int order[3] = {0, 1, 2};
  const double diag[3] = {a[0], a[4], a[8]};
  // Insertion sort ascending — three elements, and stable on ties so equal
  // eigenvalues keep their axis order.
  for (int i = 1; i < 3; ++i)
    for (int j = i; j > 0 && diag[order[j]] < diag[order[j - 1]]; --j)
      std::swap(order[j], order[j - 1]);

  for (int i = 0; i < 3; ++i) {
    values[i] = diag[order[i]];
    // Eigenvectors are the COLUMNS of v; emit them as ROWS of `vectors`.
    for (int r = 0; r < 3; ++r) vectors[i * 3 + r] = v[r * 3 + order[i]];
  }
}

MeshSegmentation segment_mesh_faces(const TriangleMesh& mesh,
                                    const SegmentOptions& opts) {
  if (!(opts.dihedral_threshold_deg > 0.0) || !(opts.dihedral_threshold_deg < 180.0))
    throw std::invalid_argument(
        "segment_mesh_faces: dihedral_threshold_deg must be in (0, 180)");

  MeshSegmentation seg;
  const std::size_t nt = mesh.triangles.size();
  if (nt == 0) return seg;

  // --- per-triangle normals -------------------------------------------------
  std::vector<V3> unit_n(nt);
  std::vector<double> area(nt, 0.0);
  for (std::size_t t = 0; t < nt; ++t) {
    const V3 n2 = face_normal_2a(mesh, t);
    const double len = norm(n2);
    area[t] = 0.5 * len;
    if (len > 0.0) unit_n[t] = V3{n2.x / len, n2.y / len, n2.z / len};
  }

  // --- shared-edge adjacency ------------------------------------------------
  // std::map (ordered) rather than a hash map: the iteration order of the
  // adjacency structure must not depend on a hash seed. Triangles are inserted
  // in ascending index order, so every incidence list is already ascending.
  std::map<std::pair<int, int>, std::vector<int>> edge_tris;
  for (std::size_t t = 0; t < nt; ++t) {
    const auto& tri = mesh.triangles[t];
    for (int e = 0; e < 3; ++e) {
      int a = tri[e], b = tri[(e + 1) % 3];
      if (a > b) std::swap(a, b);
      edge_tris[std::make_pair(a, b)].push_back(static_cast<int>(t));
    }
  }

  // --- region growing -------------------------------------------------------
  const double cos_thr = std::cos(opts.dihedral_threshold_deg * M_PI / 180.0);
  seg.triangle_face.assign(nt, -1);
  int next_id = 0;
  std::deque<int> frontier;

  for (std::size_t seed = 0; seed < nt; ++seed) {
    if (seg.triangle_face[seed] != -1) continue;
    const int id = next_id++;
    seg.triangle_face[seed] = id;
    frontier.clear();
    frontier.push_back(static_cast<int>(seed));

    while (!frontier.empty()) {
      const int cur = frontier.front();
      frontier.pop_front();
      const auto& tri = mesh.triangles[static_cast<std::size_t>(cur)];
      for (int e = 0; e < 3; ++e) {  // fixed edge order (v0v1, v1v2, v2v0)
        int a = tri[e], b = tri[(e + 1) % 3];
        if (a > b) std::swap(a, b);
        const auto it = edge_tris.find(std::make_pair(a, b));
        if (it == edge_tris.end()) continue;
        for (const int nb : it->second) {  // ascending triangle index
          if (nb == cur) continue;
          const std::size_t n = static_cast<std::size_t>(nb);
          if (seg.triangle_face[n] != -1) continue;
          // A degenerate triangle has no normal; let it join whatever reaches
          // it first so `triangle_face` stays total over the triangle list.
          const bool cur_ok = area[static_cast<std::size_t>(cur)] > 0.0;
          const bool nb_ok = area[n] > 0.0;
          const bool join =
              (!cur_ok || !nb_ok) ||
              dot(unit_n[static_cast<std::size_t>(cur)], unit_n[n]) >= cos_thr;
          if (!join) continue;
          seg.triangle_face[n] = id;
          frontier.push_back(nb);
        }
      }
    }
  }
  seg.face_count = next_id;

  // --- per-region surface fit ----------------------------------------------
  seg.faces.assign(static_cast<std::size_t>(seg.face_count), StepFaceInfo{});
  std::vector<std::vector<int>> region_tris(static_cast<std::size_t>(seg.face_count));
  for (std::size_t t = 0; t < nt; ++t)
    region_tris[static_cast<std::size_t>(seg.triangle_face[t])].push_back(
        static_cast<int>(t));

  const double plane_cos = std::cos(opts.plane_tolerance_deg * M_PI / 180.0);
  const double cyl_sin = std::sin(opts.cylinder_tolerance_deg * M_PI / 180.0);

  // The part's own size, for the physical bound on a fitted cylinder radius.
  Vec3 bb_lo, bb_hi;
  bounding_box(mesh, bb_lo, bb_hi);
  const double bb_diag = std::sqrt((bb_hi.x - bb_lo.x) * (bb_hi.x - bb_lo.x) +
                                   (bb_hi.y - bb_lo.y) * (bb_hi.y - bb_lo.y) +
                                   (bb_hi.z - bb_lo.z) * (bb_hi.z - bb_lo.z));
  const double max_radius = opts.max_cylinder_radius_span * bb_diag;

  for (std::size_t f = 0; f < region_tris.size(); ++f) {
    const std::vector<int>& tris = region_tris[f];
    StepFaceInfo info;

    // Area-weighted mean normal. For the outward-wound mesh the importer
    // guarantees, this is the OUTWARD direction — what a face clearance
    // extrudes along.
    V3 mean{0, 0, 0};
    double total_area = 0.0;
    for (const int t : tris) {
      const std::size_t u = static_cast<std::size_t>(t);
      mean.x += unit_n[u].x * area[u];
      mean.y += unit_n[u].y * area[u];
      mean.z += unit_n[u].z * area[u];
      total_area += area[u];
    }
    const double mean_len = norm(mean);
    if (mean_len > 0.0) {
      mean.x /= mean_len;
      mean.y /= mean_len;
      mean.z /= mean_len;
    }

    // Plane test: every facet normal parallel to the mean, within tolerance.
    bool planar = mean_len > 0.0 && total_area > 0.0;
    if (planar) {
      for (const int t : tris) {
        const std::size_t u = static_cast<std::size_t>(t);
        if (area[u] <= 0.0) continue;  // degenerate: no opinion
        if (dot(unit_n[u], mean) < plane_cos) {
          planar = false;
          break;
        }
      }
    }

    if (planar) {
      info.kind = StepSurfaceKind::Plane;
      info.plane_normal = Vec3{mean.x, mean.y, mean.z};
      // Area-weighted centroid of the region: a point ON the plane.
      V3 c{0, 0, 0};
      for (const int t : tris) {
        const std::size_t u = static_cast<std::size_t>(t);
        const auto& tri = mesh.triangles[u];
        for (int k = 0; k < 3; ++k) {
          const Vec3& p = mesh.vertices[static_cast<std::size_t>(tri[k])];
          c.x += p.x * area[u] / 3.0;
          c.y += p.y * area[u] / 3.0;
          c.z += p.z * area[u] / 3.0;
        }
      }
      if (total_area > 0.0) {
        c.x /= total_area;
        c.y /= total_area;
        c.z /= total_area;
      }
      info.plane_origin = Vec3{c.x, c.y, c.z};
      seg.faces[f] = info;
      continue;
    }

    // Cylinder test. On a cylinder every facet normal is perpendicular to the
    // axis, so the area-weighted normal covariance sum(area * n n^T) is
    // (nearly) singular along the axis: take its smallest eigenvector.
    double cov[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    for (const int t : tris) {
      const std::size_t u = static_cast<std::size_t>(t);
      if (area[u] <= 0.0) continue;
      const double n[3] = {unit_n[u].x, unit_n[u].y, unit_n[u].z};
      for (int r = 0; r < 3; ++r)
        for (int c2 = 0; c2 < 3; ++c2) cov[r * 3 + c2] += area[u] * n[r] * n[c2];
    }
    double ev[3];
    double evec[9];
    symmetric_eigen3(cov, ev, evec);
    V3 axis = canonical_sign(V3{evec[0], evec[1], evec[2]});
    const double axis_len = norm(axis);
    bool cylindrical = tris.size() >= 3 && axis_len > 0.0 && total_area > 0.0;
    if (cylindrical) {
      axis.x /= axis_len;
      axis.y /= axis_len;
      axis.z /= axis_len;
      for (const int t : tris) {
        const std::size_t u = static_cast<std::size_t>(t);
        if (area[u] <= 0.0) continue;
        if (std::fabs(dot(unit_n[u], axis)) > cyl_sin) {
          cylindrical = false;
          break;
        }
      }
    }

    if (cylindrical) {
      // Build an orthonormal (u, v) basis of the plane perpendicular to axis.
      V3 helper = std::fabs(axis.x) < 0.9 ? V3{1, 0, 0} : V3{0, 1, 0};
      V3 uu = cross(axis, helper);
      const double ul = norm(uu);
      uu = V3{uu.x / ul, uu.y / ul, uu.z / ul};
      const V3 vv = cross(axis, uu);

      // Collect the region's distinct vertices (ascending index => the sums are
      // accumulated in a fixed order).
      std::vector<int> verts;
      for (const int t : tris) {
        const auto& tri = mesh.triangles[static_cast<std::size_t>(t)];
        for (int k = 0; k < 3; ++k) verts.push_back(tri[k]);
      }
      std::sort(verts.begin(), verts.end());
      verts.erase(std::unique(verts.begin(), verts.end()), verts.end());

      // Algebraic (Kasa) circle fit in the (u, v) plane: minimise
      // sum (x^2 + y^2 + D x + E y + F)^2 over D, E, F.
      double m[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
      double rhs[3] = {0, 0, 0};
      double along_sum = 0.0;
      std::vector<double> xs(verts.size()), ys(verts.size());
      for (std::size_t i = 0; i < verts.size(); ++i) {
        const Vec3& p = mesh.vertices[static_cast<std::size_t>(verts[i])];
        const V3 pv{p.x, p.y, p.z};
        const double x = dot(pv, uu), y = dot(pv, vv);
        xs[i] = x;
        ys[i] = y;
        along_sum += dot(pv, axis);
        const double z = x * x + y * y;
        m[0] += x * x; m[1] += x * y; m[2] += x;
        m[3] += x * y; m[4] += y * y; m[5] += y;
        m[6] += x;     m[7] += y;     m[8] += 1.0;
        rhs[0] -= z * x;
        rhs[1] -= z * y;
        rhs[2] -= z;
      }
      double sol[3] = {0, 0, 0};
      bool fit_ok = !verts.empty() && solve3(m, rhs, sol);
      double cx = 0.0, cy = 0.0, radius = 0.0;
      if (fit_ok) {
        cx = -0.5 * sol[0];
        cy = -0.5 * sol[1];
        const double r2 = cx * cx + cy * cy - sol[2];
        fit_ok = r2 > 0.0;
        if (fit_ok) radius = std::sqrt(r2);
      }
      if (fit_ok) {
        double resid = 0.0;
        for (std::size_t i = 0; i < verts.size(); ++i) {
          const double dx = xs[i] - cx, dy = ys[i] - cy;
          const double d = std::sqrt(dx * dx + dy * dy) - radius;
          resid += d * d;
        }
        resid = std::sqrt(resid / static_cast<double>(verts.size()));
        fit_ok = radius > 0.0 && resid / radius <= opts.cylinder_radius_tolerance;
        // Physical bound: a cylinder bigger than the part is not a feature of
        // the part, it is a flat region fitted by an enormous circle.
        if (fit_ok && max_radius > 0.0 && radius > max_radius) fit_ok = false;
      }
      if (fit_ok) {
        const double along = along_sum / static_cast<double>(verts.size());
        info.kind = StepSurfaceKind::Cylinder;
        info.cylinder_radius_mm = radius;
        info.axis_dir = Vec3{axis.x, axis.y, axis.z};
        info.axis_point = Vec3{cx * uu.x + cy * vv.x + along * axis.x,
                               cx * uu.y + cy * vv.y + along * axis.y,
                               cx * uu.z + cy * vv.z + along * axis.z};
        seg.faces[f] = info;
        continue;
      }
    }

    // Neither a plane nor a cylinder: Other. Selection, tagging and the design
    // box all work on an Other face (they only need triangle_face); only the
    // shape-aware clearance derivations need the fitted geometry.
    seg.faces[f] = info;
  }

  return seg;
}

}  // namespace topopt
