// Exact signed distance to a closed triangle mesh — see the header for why this
// exists and what it guarantees (task 2026-08-08-strut-clip-matches-shell).

#include "topopt/mesh_distance.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace topopt {
namespace {

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }

// The angle of triangle (a,b,c) at vertex a, for the angle-weighted vertex
// pseudonormal. Degenerate corners contribute 0, which is what a zero-area sliver
// should contribute.
double corner_angle(const Vec3& a, const Vec3& b, const Vec3& c) {
  const Vec3 u = sub(b, a);
  const Vec3 v = sub(c, a);
  const double nu = len(u), nv = len(v);
  if (!(nu > 0.0) || !(nv > 0.0)) return 0.0;
  double t = dot(u, v) / (nu * nv);
  t = std::max(-1.0, std::min(1.0, t));
  return std::acos(t);
}

}  // namespace

// Closest point on triangle (a,b,c) to p, with the Voronoi REGION it fell in.
// Ericson, Real-Time Collision Detection §5.1.5 — the region-returning form, so
// the caller can pick the matching pseudonormal. Region codes match
// MeshDistance::Closest: 0/1/2 = vertex a/b/c, 3/4/5 = edge ab/bc/ca, 6 = face.
static void closest_on_triangle(const Vec3& p, const Vec3& a, const Vec3& b,
                                const Vec3& c, Vec3& out, int& region) {
  const Vec3 ab = sub(b, a);
  const Vec3 ac = sub(c, a);
  const Vec3 ap = sub(p, a);
  const double d1 = dot(ab, ap);
  const double d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) {
    out = a;
    region = 0;
    return;
  }
  const Vec3 bp = sub(p, b);
  const double d3 = dot(ab, bp);
  const double d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) {
    out = b;
    region = 1;
    return;
  }
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
    const double denom = d1 - d3;
    const double v = denom != 0.0 ? d1 / denom : 0.0;
    out = add(a, mul(ab, v));
    region = 3;  // edge ab
    return;
  }
  const Vec3 cp = sub(p, c);
  const double d5 = dot(ab, cp);
  const double d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) {
    out = c;
    region = 2;
    return;
  }
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
    const double denom = d2 - d6;
    const double w = denom != 0.0 ? d2 / denom : 0.0;
    out = add(a, mul(ac, w));
    region = 5;  // edge ca
    return;
  }
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double denom = (d4 - d3) + (d5 - d6);
    const double w = denom != 0.0 ? (d4 - d3) / denom : 0.0;
    out = add(b, mul(sub(c, b), w));
    region = 4;  // edge bc
    return;
  }
  const double denom_f = va + vb + vc;
  if (!(denom_f > 0.0)) {  // degenerate triangle: fall back to vertex a
    out = a;
    region = 0;
    return;
  }
  const double v = vb / denom_f;
  const double w = vc / denom_f;
  out = add(a, add(mul(ab, v), mul(ac, w)));
  region = 6;
}

MeshDistance::MeshDistance(const TriangleMesh& mesh, double cell_mm)
    : mesh_(&mesh), tri_count_(mesh.triangles.size()) {
  if (tri_count_ == 0) return;

  // ── bounding box + a cell size. The default is the mean triangle bounding
  // extent: one surface layer per cell, so a query's 3x3x3 neighbourhood holds
  // O(1) triangles. Clamped away from zero so a degenerate mesh cannot divide by
  // it.
  lo_ = hi_ = mesh.vertices[0];
  for (const Vec3& v : mesh.vertices) {
    lo_.x = std::min(lo_.x, v.x); hi_.x = std::max(hi_.x, v.x);
    lo_.y = std::min(lo_.y, v.y); hi_.y = std::max(hi_.y, v.y);
    lo_.z = std::min(lo_.z, v.z); hi_.z = std::max(hi_.z, v.z);
  }
  if (!(cell_mm > 0.0)) {
    double sum = 0.0;
    for (const auto& t : mesh.triangles) {
      const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
      const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
      const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
      const double ex = std::max({a.x, b.x, c.x}) - std::min({a.x, b.x, c.x});
      const double ey = std::max({a.y, b.y, c.y}) - std::min({a.y, b.y, c.y});
      const double ez = std::max({a.z, b.z, c.z}) - std::min({a.z, b.z, c.z});
      sum += std::max({ex, ey, ez});
    }
    cell_mm = sum / static_cast<double>(tri_count_);
  }
  const double span = std::max({hi_.x - lo_.x, hi_.y - lo_.y, hi_.z - lo_.z});
  if (!(cell_mm > 0.0)) cell_mm = span > 0.0 ? span : 1.0;
  // Cap the grid at ~8M cells so a huge, finely tessellated mesh cannot blow up
  // the index; the shell meshes this serves are far below that.
  const double min_cell = span > 0.0 ? span / 200.0 : cell_mm;
  cell_ = std::max(cell_mm, min_cell);

  auto dim = [this](double extent) {
    return std::max<long>(1, static_cast<long>(std::floor(extent / cell_)) + 1);
  };
  nx_ = dim(hi_.x - lo_.x);
  ny_ = dim(hi_.y - lo_.y);
  nz_ = dim(hi_.z - lo_.z);

  // ── CSR index: count, prefix-sum, fill. Deterministic — triangles land in
  // ascending index order inside each cell.
  const std::size_t ncell = static_cast<std::size_t>(nx_) * ny_ * nz_;
  cell_start_.assign(ncell + 1, 0);
  auto cell_range = [this](const Vec3& a, const Vec3& b, const Vec3& c, long lo[3],
                           long hi[3]) {
    const double mn[3] = {std::min({a.x, b.x, c.x}), std::min({a.y, b.y, c.y}),
                          std::min({a.z, b.z, c.z})};
    const double mx[3] = {std::max({a.x, b.x, c.x}), std::max({a.y, b.y, c.y}),
                          std::max({a.z, b.z, c.z})};
    const double o[3] = {lo_.x, lo_.y, lo_.z};
    const long n[3] = {nx_, ny_, nz_};
    for (int ax = 0; ax < 3; ++ax) {
      lo[ax] = static_cast<long>(std::floor((mn[ax] - o[ax]) / cell_));
      hi[ax] = static_cast<long>(std::floor((mx[ax] - o[ax]) / cell_));
      lo[ax] = std::max<long>(0, std::min(lo[ax], n[ax] - 1));
      hi[ax] = std::max<long>(0, std::min(hi[ax], n[ax] - 1));
    }
  };
  auto cell_index = [this](long i, long j, long k) {
    return static_cast<std::size_t>((k * ny_ + j) * nx_ + i);
  };
  for (const auto& t : mesh.triangles) {
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
    long l[3], h[3];
    cell_range(a, b, c, l, h);
    for (long k = l[2]; k <= h[2]; ++k)
      for (long j = l[1]; j <= h[1]; ++j)
        for (long i = l[0]; i <= h[0]; ++i) ++cell_start_[cell_index(i, j, k) + 1];
  }
  for (std::size_t e = 0; e < ncell; ++e) cell_start_[e + 1] += cell_start_[e];
  cell_tris_.resize(cell_start_[ncell]);
  std::vector<std::uint32_t> fill(cell_start_.begin(), cell_start_.end() - 1);
  for (std::size_t ti = 0; ti < tri_count_; ++ti) {
    const auto& t = mesh.triangles[ti];
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
    long l[3], h[3];
    cell_range(a, b, c, l, h);
    for (long k = l[2]; k <= h[2]; ++k)
      for (long j = l[1]; j <= h[1]; ++j)
        for (long i = l[0]; i <= h[0]; ++i)
          cell_tris_[fill[cell_index(i, j, k)]++] = static_cast<std::uint32_t>(ti);
  }

  // ── pseudonormals. Face normals are UNNORMALISED area-weighted normals; only
  // their direction is ever read, and the sums below are the standard
  // angle-weighted (vertex) and two-face (edge) constructions.
  face_n_.assign(tri_count_, Vec3{});
  vert_n_.assign(mesh.vertices.size(), Vec3{});
  edge_n_.assign(tri_count_ * 3, Vec3{});
  for (std::size_t ti = 0; ti < tri_count_; ++ti) {
    const auto& t = mesh.triangles[ti];
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
    Vec3 n = cross(sub(b, a), sub(c, a));
    const double nl = len(n);
    if (nl > 0.0) n = mul(n, 1.0 / nl);  // unit: the angle weights carry the rest
    face_n_[ti] = n;
    const double ang[3] = {corner_angle(a, b, c), corner_angle(b, c, a),
                           corner_angle(c, a, b)};
    for (int w = 0; w < 3; ++w)
      vert_n_[static_cast<std::size_t>(t[w])] =
          add(vert_n_[static_cast<std::size_t>(t[w])], mul(n, ang[w]));
  }
  // Edge pseudonormal = sum of the two incident face normals. Built by pairing
  // half-edges through a sort rather than a hash, so the result does not depend
  // on any container's iteration order.
  {
    struct HE {
      std::uint64_t key;
      std::uint32_t tri;
      std::uint8_t slot;
    };
    std::vector<HE> he;
    he.reserve(tri_count_ * 3);
    for (std::size_t ti = 0; ti < tri_count_; ++ti) {
      const auto& t = mesh.triangles[ti];
      const int pair[3][2] = {{t[0], t[1]}, {t[1], t[2]}, {t[2], t[0]}};
      for (int s = 0; s < 3; ++s) {
        const std::uint64_t u = static_cast<std::uint64_t>(
            std::min(pair[s][0], pair[s][1]));
        const std::uint64_t v = static_cast<std::uint64_t>(
            std::max(pair[s][0], pair[s][1]));
        he.push_back({(u << 32) | v, static_cast<std::uint32_t>(ti),
                      static_cast<std::uint8_t>(s)});
      }
    }
    std::sort(he.begin(), he.end(), [](const HE& x, const HE& y) {
      if (x.key != y.key) return x.key < y.key;
      if (x.tri != y.tri) return x.tri < y.tri;
      return x.slot < y.slot;
    });
    for (std::size_t i = 0; i < he.size();) {
      std::size_t j = i;
      Vec3 sum{};
      while (j < he.size() && he[j].key == he[i].key) {
        sum = add(sum, face_n_[he[j].tri]);
        ++j;
      }
      // A watertight mesh gives exactly two; a boundary edge gives one and a
      // non-manifold edge more. Either way the SUM is what every incident
      // half-edge records, so the answer cannot depend on which triangle the
      // search happened to report.
      for (std::size_t q = i; q < j; ++q)
        edge_n_[he[q].tri * 3 + he[q].slot] = sum;
      i = j;
    }
  }

  // ── WHICH WAY IS OUT. Read from the mesh itself rather than assumed, because
  // the mesh this serves does NOT follow the STL convention: `marching_cubes`
  // emits triangles whose (b-a)x(c-a) normals point INTO the solid — measured,
  // `signed_volume(marching_cubes(<a solid block>)) == -58.667` for a body of
  // volume 58.667. The codebase already absorbs that silently
  // (`mesh_enclosed_volume_mm3`, run_job.cpp:3524, takes std::fabs), so a
  // utility that hardcoded either convention would be right for one caller and
  // silently inverted for the other.
  //
  // signed_volume is exact and origin-independent for a CLOSED mesh, so its sign
  // is the winding. An open or degenerate mesh gives ~0; then no flip is applied
  // and only `unsigned_distance` is meaningful — which the header states.
  if (signed_volume(mesh) < 0.0) {
    for (Vec3& n : face_n_) n = mul(n, -1.0);
    for (Vec3& n : vert_n_) n = mul(n, -1.0);
    for (Vec3& n : edge_n_) n = mul(n, -1.0);
    inward_wound_ = true;
  }

  stamp_.assign(tri_count_, 0);
}

void MeshDistance::gather_cell(long cx, long cy, long cz, const Vec3& p,
                               Closest& best) const {
  if (cx < 0 || cy < 0 || cz < 0 || cx >= nx_ || cy >= ny_ || cz >= nz_) return;
  const std::size_t e = static_cast<std::size_t>((cz * ny_ + cy) * nx_ + cx);
  for (std::uint32_t s = cell_start_[e]; s < cell_start_[e + 1]; ++s) {
    const std::uint32_t ti = cell_tris_[s];
    if (stamp_[ti] == query_) continue;
    stamp_[ti] = query_;
    const auto& t = mesh_->triangles[ti];
    Vec3 q;
    int region = 6;
    closest_on_triangle(p, mesh_->vertices[static_cast<std::size_t>(t[0])],
                        mesh_->vertices[static_cast<std::size_t>(t[1])],
                        mesh_->vertices[static_cast<std::size_t>(t[2])], q, region);
    const Vec3 d = sub(p, q);
    const double d2 = dot(d, d);
    // Strict <, so the FIRST triangle in ascending index order wins a tie —
    // deterministic, and at a tie the pseudonormals agree by construction.
    if (d2 < best.dist2 || best.tri < 0) {
      best.dist2 = d2;
      best.point = q;
      best.tri = static_cast<int>(ti);
      best.region = region;
    }
  }
}

MeshDistance::Closest MeshDistance::closest(const Vec3& p) const {
  Closest best;
  best.dist2 = std::numeric_limits<double>::infinity();
  if (++query_ == 0) {  // stamp wrap: clear once, then continue
    std::fill(stamp_.begin(), stamp_.end(), 0);
    query_ = 1;
  }
  auto clampi = [](long v, long n) { return v < 0 ? 0 : (v >= n ? n - 1 : v); };
  const long ci = clampi(static_cast<long>(std::floor((p.x - lo_.x) / cell_)), nx_);
  const long cj = clampi(static_cast<long>(std::floor((p.y - lo_.y) / cell_)), ny_);
  const long ck = clampi(static_cast<long>(std::floor((p.z - lo_.z) / cell_)), nz_);
  const long max_shell = std::max({nx_, ny_, nz_});
  for (long s = 0; s <= max_shell; ++s) {
    if (s == 0) {
      gather_cell(ci, cj, ck, p, best);
    } else {
      // The Chebyshev shell SURFACE only: two full k-faces, then the four side
      // bands of each intermediate k-slab (the same enumeration
      // LatticeBoundary::voxel_distance uses over voxel cubes).
      for (long j = cj - s; j <= cj + s; ++j)
        for (long i = ci - s; i <= ci + s; ++i) {
          gather_cell(i, j, ck - s, p, best);
          gather_cell(i, j, ck + s, p, best);
        }
      for (long k = ck - s + 1; k <= ck + s - 1; ++k) {
        for (long i = ci - s; i <= ci + s; ++i) {
          gather_cell(i, cj - s, k, p, best);
          gather_cell(i, cj + s, k, p, best);
        }
        for (long j = cj - s + 1; j <= cj + s - 1; ++j) {
          gather_cell(ci - s, j, k, p, best);
          gather_cell(ci + s, j, k, p, best);
        }
      }
    }
    if (best.tri < 0) continue;
    // ★ THE STOPPING BOUND IS TESTED AFTER SHELL s IS GATHERED, NOT BEFORE.
    //
    // Cells [ci-s, ci+s] cover the axis-aligned box below, and a triangle that
    // comes within `guaranteed` of p must intersect that box, so it has an AABB
    // overlapping one of its cells and has already been examined. The bound is
    // therefore exact — but ONLY for the shells actually gathered.
    //
    // Testing it at the TOP of the iteration (the first version of this loop)
    // uses the radius-s box while holding only shells 0..s-1, which overstates
    // the coverage by one shell and can return a distance up to `cell_` too
    // LARGE. Too large is the dangerous direction: it makes the strut clip keep
    // a span it has not proved, and the exact distance stops being 1-Lipschitz,
    // which is the property the whole certified-clip argument rests on. Measured
    // on the l-bracket at resolution 32: struts emitted 0.839 mm OUTSIDE the
    // shell they had just been clipped against, with the predicate agreeing they
    // were outside when asked again at the vertex (ctest lattice_void_exterior).
    const double bx0 = lo_.x + static_cast<double>(ci - s) * cell_;
    const double bx1 = lo_.x + static_cast<double>(ci + s + 1) * cell_;
    const double by0 = lo_.y + static_cast<double>(cj - s) * cell_;
    const double by1 = lo_.y + static_cast<double>(cj + s + 1) * cell_;
    const double bz0 = lo_.z + static_cast<double>(ck - s) * cell_;
    const double bz1 = lo_.z + static_cast<double>(ck + s + 1) * cell_;
    const double guaranteed = std::min({p.x - bx0, bx1 - p.x, p.y - by0,
                                        by1 - p.y, p.z - bz0, bz1 - p.z});
    if (guaranteed > 0.0 && best.dist2 <= guaranteed * guaranteed) break;
  }
  return best;
}

double MeshDistance::unsigned_distance(const Vec3& p) const {
  if (tri_count_ == 0) return 0.0;
  return std::sqrt(closest(p).dist2);
}

double MeshDistance::signed_distance(const Vec3& p) const {
  if (tri_count_ == 0) return 0.0;
  const Closest c = closest(p);
  const double d = std::sqrt(c.dist2);
  if (c.tri < 0) return 0.0;
  const auto& t = mesh_->triangles[static_cast<std::size_t>(c.tri)];
  Vec3 pn;
  switch (c.region) {
    case 0: pn = vert_n_[static_cast<std::size_t>(t[0])]; break;
    case 1: pn = vert_n_[static_cast<std::size_t>(t[1])]; break;
    case 2: pn = vert_n_[static_cast<std::size_t>(t[2])]; break;
    case 3: pn = edge_n_[static_cast<std::size_t>(c.tri) * 3 + 0]; break;
    case 4: pn = edge_n_[static_cast<std::size_t>(c.tri) * 3 + 1]; break;
    case 5: pn = edge_n_[static_cast<std::size_t>(c.tri) * 3 + 2]; break;
    default: pn = face_n_[static_cast<std::size_t>(c.tri)]; break;
  }
  // Positive INSIDE (LatticeBoundary's convention): the outward pseudonormal
  // points along (p - closest) when p is outside.
  const double s = dot(pn, sub(p, c.point));
  return s > 0.0 ? -d : d;
}

}  // namespace topopt
