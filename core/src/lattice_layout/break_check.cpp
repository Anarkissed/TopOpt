// Organic strength, CUT 1 stage C1: the break check on the printed shape (see lattice_layout_break.hpp).
#include "topopt/lattice_layout_break.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <stdexcept>

#include "topopt/fea.hpp"
#include "topopt/observability.hpp"
#include "topopt/segment.hpp"
#include "topopt/voxel.hpp"

namespace topopt::lattice_layout {
namespace {

constexpr double kBytesPerMaterialVoxel = 3200.0;   // the plan's estimate (section 4), to be measured in M1
constexpr double kBytesPerBoxVoxel = 40.0;

struct Grid {
  Vec3 lo{};
  double h = 0.0;
  int nx = 0, ny = 0, nz = 0;
  std::size_t index(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) * static_cast<std::size_t>(nx) +
           static_cast<std::size_t>(i);
  }
  Vec3 centre(int i, int j, int k) const { return {lo.x + (i + 0.5) * h, lo.y + (j + 0.5) * h, lo.z + (k + 0.5) * h}; }
};

Grid grid_of(const BreakAsk& ask) {
  if (!ask.print || ask.print->vertices.empty() || !(ask.voxel_mm > 0.0)) throw std::invalid_argument("break check: no print or no voxel size");
  Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
  for (const Vec3& v : ask.print->vertices) {
    mn = {std::min(mn.x, v.x), std::min(mn.y, v.y), std::min(mn.z, v.z)};
    mx = {std::max(mx.x, v.x), std::max(mx.y, v.y), std::max(mx.z, v.z)};
  }
  // The grid is anchored to the PART's box (its low corner, plus grid_shift voxels), so the same part gives the same
  // voxels whatever the lay adds a hair outside it; it is then extended by whole voxels to hold the whole print.
  Vec3 an = mn;
  if (ask.part && !ask.part->mesh.vertices.empty()) {
    an = {1e300, 1e300, 1e300};
    for (const Vec3& v : ask.part->mesh.vertices) an = {std::min(an.x, v.x), std::min(an.y, v.y), std::min(an.z, v.z)};
  }
  Grid g;
  g.h = ask.voxel_mm;
  const double ax = an.x + ask.grid_shift.x * g.h, ay = an.y + ask.grid_shift.y * g.h, az = an.z + ask.grid_shift.z * g.h;
  auto below = [&](double anchor, double lo) { return anchor - std::max(0.0, std::ceil((anchor - lo) / g.h - 1e-9)) * g.h; };
  g.lo = {below(ax, mn.x), below(ay, mn.y), below(az, mn.z)};
  // up to the print's high side: the last voxel's centre no further than half a voxel past it
  g.nx = std::max(1, static_cast<int>(std::lround((mx.x - g.lo.x) / g.h)));
  g.ny = std::max(1, static_cast<int>(std::lround((mx.y - g.lo.y) / g.h)));
  g.nz = std::max(1, static_cast<int>(std::lround((mx.z - g.lo.z) / g.h)));
  return g;
}

std::vector<char> material_of(const BreakAsk& ask, const Grid& g) {
  VoxelGrid ref;
  ref.nx = g.nx;
  ref.ny = g.ny;
  ref.nz = g.nz;
  ref.spacing = g.h;
  ref.origin = g.lo;
  const VoxelGrid v = voxelize_onto_grid(*ask.print, ref);
  std::vector<char> mat(v.tags.size(), 0);
  for (std::size_t e = 0; e < v.tags.size(); ++e) mat[e] = v.tags[e] != VoxelTag::Empty;
  return mat;
}

double seg_dist(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z}, ap{p.x - a.x, p.y - a.y, p.z - a.z};
  const double L2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
  double t = L2 > 0.0 ? (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / L2 : 0.0;
  t = std::min(1.0, std::max(0.0, t));
  const Vec3 q{a.x + t * ab.x - p.x, a.y + t * ab.y - p.y, a.z + t * ab.z - p.z};
  return std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
}

double tri_dist(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  // the closest point on triangle abc (Ericson, Real-Time Collision Detection 5.1.5)
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z}, ac{c.x - a.x, c.y - a.y, c.z - a.z}, ap{p.x - a.x, p.y - a.y, p.z - a.z};
  auto dot = [](const Vec3& u, const Vec3& v) { return u.x * v.x + u.y * v.y + u.z * v.z; };
  auto dist = [&](const Vec3& q) { return std::sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z)); };
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) return dist(a);
  const Vec3 bp{p.x - b.x, p.y - b.y, p.z - b.z};
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) return dist(b);
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) { const double v = d1 / (d1 - d3); return dist({a.x + v * ab.x, a.y + v * ab.y, a.z + v * ab.z}); }
  const Vec3 cp{p.x - c.x, p.y - c.y, p.z - c.z};
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) return dist(c);
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) { const double w = d2 / (d2 - d6); return dist({a.x + w * ac.x, a.y + w * ac.y, a.z + w * ac.z}); }
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return dist({b.x + w * (c.x - b.x), b.y + w * (c.y - b.y), b.z + w * (c.z - b.z)});
  }
  const double denom = 1.0 / (va + vb + vc), v = vb * denom, w = vc * denom;
  return dist({a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w, a.z + ab.z * v + ac.z * w});
}

// The exposed voxel faces of the material that lie on the part's faces `faces`: a voxel face whose neighbour across it
// is not material, whose outward axis agrees with the part face's outward normal (cos > 0.7), and whose centre lies
// within one voxel of one of the face's triangles. Each entry: the voxel and its axis (0 -x, 1 +x, 2 -y, 3 +y, 4 -z, 5 +z).
std::vector<std::array<int, 4>> faces_on(const BreakAsk& ask, const Grid& g, const std::vector<char>& mat, const std::vector<int>& faces) {
  std::vector<std::array<int, 4>> out;
  if (!ask.part) return out;
  const TriangleMesh& pm = ask.part->mesh;
  std::vector<int> tris;
  for (std::size_t t = 0; t < pm.triangles.size() && t < ask.part->triangle_face.size(); ++t)
    if (std::find(faces.begin(), faces.end(), ask.part->triangle_face[t]) != faces.end()) tris.push_back(static_cast<int>(t));
  if (tris.empty()) return out;
  Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
  std::vector<Vec3> nrm(tris.size());
  for (std::size_t q = 0; q < tris.size(); ++q) {
    const auto& t = pm.triangles[static_cast<std::size_t>(tris[q])];
    const Vec3 &A = pm.vertices[static_cast<std::size_t>(t[0])], &B = pm.vertices[static_cast<std::size_t>(t[1])],
               &C = pm.vertices[static_cast<std::size_t>(t[2])];
    for (const Vec3* v : {&A, &B, &C}) {
      mn = {std::min(mn.x, v->x), std::min(mn.y, v->y), std::min(mn.z, v->z)};
      mx = {std::max(mx.x, v->x), std::max(mx.y, v->y), std::max(mx.z, v->z)};
    }
    const Vec3 u{B.x - A.x, B.y - A.y, B.z - A.z}, w{C.x - A.x, C.y - A.y, C.z - A.z};
    Vec3 n{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    nrm[q] = l > 0.0 ? Vec3{n.x / l, n.y / l, n.z / l} : Vec3{};
  }
  const double h = g.h;
  const int ax[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}};
  const int i0 = std::max(0, static_cast<int>(std::floor((mn.x - g.lo.x) / h)) - 2), i1 = std::min(g.nx - 1, static_cast<int>(std::floor((mx.x - g.lo.x) / h)) + 2);
  const int j0 = std::max(0, static_cast<int>(std::floor((mn.y - g.lo.y) / h)) - 2), j1 = std::min(g.ny - 1, static_cast<int>(std::floor((mx.y - g.lo.y) / h)) + 2);
  const int k0 = std::max(0, static_cast<int>(std::floor((mn.z - g.lo.z) / h)) - 2), k1 = std::min(g.nz - 1, static_cast<int>(std::floor((mx.z - g.lo.z) / h)) + 2);
  for (int k = k0; k <= k1; ++k)
    for (int j = j0; j <= j1; ++j)
      for (int i = i0; i <= i1; ++i) {
        if (!mat[g.index(i, j, k)]) continue;
        for (int a = 0; a < 6; ++a) {
          const int ii = i + ax[a][0], jj = j + ax[a][1], kk = k + ax[a][2];
          if (ii >= 0 && jj >= 0 && kk >= 0 && ii < g.nx && jj < g.ny && kk < g.nz && mat[g.index(ii, jj, kk)]) continue;
          const Vec3 c0 = g.centre(i, j, k);
          const Vec3 fc{c0.x + 0.5 * h * ax[a][0], c0.y + 0.5 * h * ax[a][1], c0.z + 0.5 * h * ax[a][2]};
          bool on = false;
          for (std::size_t q = 0; q < tris.size() && !on; ++q) {
            if (nrm[q].x * ax[a][0] + nrm[q].y * ax[a][1] + nrm[q].z * ax[a][2] <= 0.7) continue;
            const auto& t = pm.triangles[static_cast<std::size_t>(tris[q])];
            on = tri_dist(fc, pm.vertices[static_cast<std::size_t>(t[0])], pm.vertices[static_cast<std::size_t>(t[1])],
                          pm.vertices[static_cast<std::size_t>(t[2])]) <= h;
          }
          if (on) out.push_back({i, j, k, a});
        }
      }
  return out;
}

// The four nodes of voxel (i, j, k)'s face on axis a.
std::array<int, 4> face_nodes(const VoxelGrid& vg, int i, int j, int k, int a) {
  const int s = a % 2;   // 0 low side, 1 high side
  if (a < 2) {
    const int x = i + s;
    return {fea_node_index(vg, x, j, k), fea_node_index(vg, x, j + 1, k), fea_node_index(vg, x, j + 1, k + 1), fea_node_index(vg, x, j, k + 1)};
  }
  if (a < 4) {
    const int y = j + s;
    return {fea_node_index(vg, i, y, k), fea_node_index(vg, i + 1, y, k), fea_node_index(vg, i + 1, y, k + 1), fea_node_index(vg, i, y, k + 1)};
  }
  const int z = k + s;
  return {fea_node_index(vg, i, j, z), fea_node_index(vg, i + 1, j, z), fea_node_index(vg, i + 1, j + 1, z), fea_node_index(vg, i, j + 1, z)};
}

std::string num(double v) {
  char b[40];
  std::snprintf(b, sizeof b, "%.9g", v);
  return b;
}
std::string point_json(const BreakPoint& p) {
  if (!p.found) return "null";
  return "{\"multiple\": " + num(p.multiple) + ", \"at\": [" + num(p.at.x) + ", " + num(p.at.y) + ", " + num(p.at.z) + "], \"class\": \"" +
         p.cls + "\"" + (p.post >= 0 ? ", \"post\": " + std::to_string(p.post) : std::string()) + ", \"thickness_voxels\": " +
         num(p.thickness_voxels) + ", \"resolved\": " + (p.resolved ? "true" : "false") + ", \"by\": \"" + p.by + "\"}";
}

}  // namespace

double break_multiple(const double s[6], double yield_mpa, double z_knockdown, const Vec3& up, std::string* by) {
  const double a[9] = {s[0], s[3], s[5], s[3], s[1], s[4], s[5], s[4], s[2]};
  double val[3], vec[9];
  symmetric_eigen3(a, val, vec);   // ascending; vectors as rows
  double m = std::numeric_limits<double>::infinity();
  const char* gov = "tension";
  if (val[2] > 0.0) {
    const double ul = std::sqrt(up.x * up.x + up.y * up.y + up.z * up.z);
    const double rise = ul > 0.0 ? std::fabs(vec[6] * up.x + vec[7] * up.y + vec[8] * up.z) / ul : 0.0;
    const double lim = yield_mpa * (1.0 - rise * rise) + yield_mpa * z_knockdown * rise * rise;
    m = lim / val[2];
  }
  if (val[0] < 0.0 && yield_mpa / -val[0] < m) {
    m = yield_mpa / -val[0];
    gov = "compression";
  }
  if (by) *by = gov;
  return m;
}

double break_member_thickness(const std::vector<char>& mat, int nx, int ny, int nz, int pi, int pj, int pk, int reach) {
  auto at = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz &&
           mat[(static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) * static_cast<std::size_t>(nx) + static_cast<std::size_t>(i)];
  };
  double best = 0.0;
  for (int ck = pk - reach; ck <= pk + reach; ++ck)
    for (int cj = pj - reach; cj <= pj + reach; ++cj)
      for (int ci = pi - reach; ci <= pi + reach; ++ci) {
        if (!at(ci, cj, ck)) continue;
        const double dp = std::sqrt(static_cast<double>((ci - pi) * (ci - pi) + (cj - pj) * (cj - pj) + (ck - pk) * (ck - pk)));
        double d = 1e300;
        const int T = reach + 2;
        for (int qk = ck - T; qk <= ck + T; ++qk)
          for (int qj = cj - T; qj <= cj + T; ++qj)
            for (int qi = ci - T; qi <= ci + T; ++qi)
              if (!at(qi, qj, qk))
                d = std::min(d, std::sqrt(static_cast<double>((qi - ci) * (qi - ci) + (qj - cj) * (qj - cj) + (qk - ck) * (qk - ck))));
        const double dt = d - 0.5;
        if (dp <= dt + 1e-9) best = std::max(best, 2.0 * dt);
      }
  return best;
}

BreakSize organic_break_size(const BreakAsk& ask) {
  const Grid g = grid_of(ask);
  BreakSize s;
  s.nx = g.nx;
  s.ny = g.ny;
  s.nz = g.nz;
  s.box_voxels = static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny) * static_cast<std::size_t>(g.nz);
  const std::vector<char> mat = material_of(ask, g);
  for (char c : mat) s.material_voxels += c != 0;
  s.bytes = static_cast<double>(s.material_voxels) * kBytesPerMaterialVoxel + static_cast<double>(s.box_voxels) * kBytesPerBoxVoxel;
  return s;
}

BreakResult organic_break_check(const BreakAsk& ask) {
  BreakResult R;
  const auto t0 = std::chrono::steady_clock::now();
  if (!ask.print || !ask.part || !(ask.yield_mpa > 0.0) || !(ask.youngs_mpa > 0.0)) {
    R.why = "no print, no part or no material";
    return R;
  }
  const Grid g = grid_of(ask);
  const double h = g.h;
  const std::vector<char> mat = material_of(ask, g);
  R.size.nx = g.nx;
  R.size.ny = g.ny;
  R.size.nz = g.nz;
  R.size.box_voxels = mat.size();
  for (char c : mat) R.size.material_voxels += c != 0;
  R.size.bytes = static_cast<double>(R.size.material_voxels) * kBytesPerMaterialVoxel + static_cast<double>(R.size.box_voxels) * kBytesPerBoxVoxel;
  auto M = [&](int i, int j, int k) { return i >= 0 && j >= 0 && k >= 0 && i < g.nx && j < g.ny && k < g.nz && mat[g.index(i, j, k)]; };
  // 1. the grid for the solve: material only
  VoxelGrid vg;
  vg.nx = g.nx;
  vg.ny = g.ny;
  vg.nz = g.nz;
  vg.spacing = h;
  vg.origin = g.lo;
  vg.tags.assign(mat.size(), VoxelTag::Empty);
  for (std::size_t e = 0; e < mat.size(); ++e) if (mat[e]) vg.tags[e] = VoxelTag::Interior;
  const std::vector<double> E(mat.size(), ask.youngs_mpa);
  // 2. the part's fixed and loaded faces on this grid
  std::vector<DirichletBC> bcs;
  {
    std::vector<char> held(static_cast<std::size_t>(fea_node_count(vg)), 0);
    for (const auto& f : faces_on(ask, g, mat, ask.fixed_faces))
      for (int n : face_nodes(vg, f[0], f[1], f[2], f[3])) {
        if (held[static_cast<std::size_t>(n)]) continue;
        held[static_cast<std::size_t>(n)] = 1;
        for (int q = 0; q < 3; ++q) bcs.push_back({n, q, 0.0});
      }
  }
  if (bcs.empty()) {
    R.why = "the fixed faces meet no material of the print";
    return R;
  }
  std::map<int, std::array<double, 3>> nodal;
  for (const BreakLoad& L : ask.loads) {
    const auto fs = faces_on(ask, g, mat, L.faces);
    if (fs.empty()) {
      R.why = "a load's faces meet no material of the print";
      return R;
    }
    const double share = 1.0 / (4.0 * static_cast<double>(fs.size()));
    for (const auto& f : fs)
      for (int n : face_nodes(vg, f[0], f[1], f[2], f[3])) {
        auto& v = nodal[n];
        v[0] += L.force.x * share;
        v[1] += L.force.y * share;
        v[2] += L.force.z * share;
      }
  }
  std::vector<NodalLoad> loads;
  for (const auto& [n, v] : nodal)
    for (int q = 0; q < 3; ++q)
      if (v[static_cast<std::size_t>(q)] != 0.0) loads.push_back({n, q, v[static_cast<std::size_t>(q)]});
  // 3. one solve at the working load
  CgInfo info;
  FeaSolution u;
  try {
    u = fea_solve_mgcg_matfree(vg, E, ask.poisson, bcs, loads, ask.tolerance, ask.max_rounds, &info);
  } catch (const std::exception& ex) {
    R.why = std::string("the solve did not settle: ") + ex.what();
    R.rounds = info.iterations;
    return R;
  }
  R.rounds = info.iterations;
  R.converged = info.converged;
  // 4. stresses
  std::vector<std::array<float, 6>> sig(mat.size(), std::array<float, 6>{});
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!M(i, j, k)) continue;
        const std::array<int, 8> nd = fea_element_nodes(vg, i, j, k);
        std::array<double, 24> ue{};
        for (int q = 0; q < 8; ++q)
          for (int d = 0; d < 3; ++d) ue[static_cast<std::size_t>(3 * q + d)] = u.at(nd[static_cast<std::size_t>(q)], d);
        const Hex8Stress st = hex8_stress(ask.youngs_mpa, ask.poisson, h, ue);
        for (int q = 0; q < 6; ++q) sig[g.index(i, j, k)][static_cast<std::size_t>(q)] = static_cast<float>(st.sigma[static_cast<std::size_t>(q)]);
      }
  // 5. classes: posts (the laid square, clipped to the print's box, between its ends), vines (within half a width plus a
  // voxel of a kept bar's axis), solid within near_post_mm of a post's end, the rest of the solid
  const std::size_t np = ask.posts.size();
  Vec3 bmn{g.lo.x, g.lo.y, g.lo.z}, bmx{g.lo.x + g.nx * h, g.lo.y + g.ny * h, g.lo.z + g.nz * h};
  {
    Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
    for (const Vec3& v : ask.print->vertices) {
      mn = {std::min(mn.x, v.x), std::min(mn.y, v.y), std::min(mn.z, v.z)};
      mx = {std::max(mx.x, v.x), std::max(mx.y, v.y), std::max(mx.z, v.z)};
    }
    bmn = mn;
    bmx = mx;
  }
  std::vector<std::array<double, 4>> pbox(np);
  for (std::size_t q = 0; q < np; ++q) {
    const BreakPost& p = ask.posts[q];
    pbox[q] = {std::max(bmn.x, p.x - 0.5 * p.width), std::min(bmx.x, p.x + 0.5 * p.width), std::max(bmn.y, p.y - 0.5 * p.width),
               std::min(bmx.y, p.y + 0.5 * p.width)};
  }
  std::vector<int> cls(mat.size(), -1);   // 0..np-1 posts, np vines, np+1 solid near a post, np+2 the rest
  {
    std::vector<char> vine(mat.size(), 0);
    for (const BreakBar& b : ask.bars) {
      const double r = 0.5 * b.width + h;
      const int i0 = std::max(0, static_cast<int>(std::floor((std::min(b.a.x, b.b.x) - r - g.lo.x) / h)));
      const int i1 = std::min(g.nx - 1, static_cast<int>(std::floor((std::max(b.a.x, b.b.x) + r - g.lo.x) / h)));
      const int j0 = std::max(0, static_cast<int>(std::floor((std::min(b.a.y, b.b.y) - r - g.lo.y) / h)));
      const int j1 = std::min(g.ny - 1, static_cast<int>(std::floor((std::max(b.a.y, b.b.y) + r - g.lo.y) / h)));
      const int k0 = std::max(0, static_cast<int>(std::floor((std::min(b.a.z, b.b.z) - r - g.lo.z) / h)));
      const int k1 = std::min(g.nz - 1, static_cast<int>(std::floor((std::max(b.a.z, b.b.z) + r - g.lo.z) / h)));
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            if (M(i, j, k) && seg_dist(g.centre(i, j, k), b.a, b.b) <= r) vine[g.index(i, j, k)] = 1;
    }
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!M(i, j, k)) continue;
          const Vec3 c = g.centre(i, j, k);
          int c2 = -1;
          for (std::size_t q = 0; q < np && c2 < 0; ++q)
            if (c.x >= pbox[q][0] && c.x <= pbox[q][1] && c.y >= pbox[q][2] && c.y <= pbox[q][3] && c.z >= ask.posts[q].z_bottom &&
                c.z <= ask.posts[q].z_top)
              c2 = static_cast<int>(q);
          if (c2 < 0 && vine[g.index(i, j, k)]) c2 = static_cast<int>(np);
          if (c2 < 0) {
            c2 = static_cast<int>(np) + 2;
            for (std::size_t q = 0; q < np; ++q) {
              const double dx = std::max({pbox[q][0] - c.x, 0.0, c.x - pbox[q][1]}), dy = std::max({pbox[q][2] - c.y, 0.0, c.y - pbox[q][3]});
              const double dz = std::min(std::fabs(c.z - ask.posts[q].z_bottom), std::fabs(c.z - ask.posts[q].z_top));
              if (std::hypot(dx, dy) <= ask.near_post_mm && dz <= ask.near_post_mm) c2 = static_cast<int>(np) + 1;
            }
          }
          cls[g.index(i, j, k)] = c2;
        }
  }
  // 6. judged (resolved): some material voxel within `min_voxels_across` voxels whose inscribed ball (radius DT, at
  // least min/2 voxels) holds the point; DT read within that reach (enough to decide)
  const int W = std::max(1, ask.min_voxels_across);
  const double need = 0.5 * static_cast<double>(ask.min_voxels_across);
  std::vector<char> res(mat.size(), 0);
  {
    std::vector<float> dt(mat.size(), 0.0f);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!M(i, j, k)) continue;
          double d = W + 1.0;
          for (int dk = -W; dk <= W; ++dk)
            for (int dj = -W; dj <= W; ++dj)
              for (int di = -W; di <= W; ++di)
                if (!M(i + di, j + dj, k + dk)) d = std::min(d, std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk)));
          dt[g.index(i, j, k)] = static_cast<float>(d - 0.5);
        }
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!M(i, j, k)) continue;
          bool thick = false;
          for (int dk = -W; dk <= W && !thick; ++dk)
            for (int dj = -W; dj <= W && !thick; ++dj)
              for (int di = -W; di <= W && !thick; ++di) {
                if (!M(i + di, j + dj, k + dk)) continue;
                const double c2 = dt[g.index(i + di, j + dj, k + dk)];
                thick = c2 >= need - 1e-9 && std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk)) <= c2 + 1e-9;
              }
          res[g.index(i, j, k)] = thick;
        }
  }
  // 7. the smoothed multiple per material voxel
  std::vector<std::array<int, 3>> ball;
  const int RB = static_cast<int>(std::ceil(ask.smooth_mm / h)) + 1;
  for (int dk = -RB; dk <= RB; ++dk)
    for (int dj = -RB; dj <= RB; ++dj)
      for (int di = -RB; di <= RB; ++di)
        if (std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk)) * h <= ask.smooth_mm + 1e-9) ball.push_back({di, dj, dk});
  std::vector<float> mult(mat.size(), std::numeric_limits<float>::infinity());
  std::vector<char> tens(mat.size(), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!M(i, j, k)) continue;
        double s6[6] = {0, 0, 0, 0, 0, 0};
        int n = 0;
        for (const auto& o : ball) {
          if (!M(i + o[0], j + o[1], k + o[2])) continue;
          const auto& v = sig[g.index(i + o[0], j + o[1], k + o[2])];
          for (int q = 0; q < 6; ++q) s6[q] += v[static_cast<std::size_t>(q)];
          ++n;
        }
        for (double& x : s6) x /= n;
        std::string by;
        const double m = break_multiple(s6, ask.yield_mpa, ask.z_knockdown, ask.up, &by);
        mult[g.index(i, j, k)] = static_cast<float>(m);
        tens[g.index(i, j, k)] = by == "tension";
      }
  auto point = [&](std::size_t e) {
    BreakPoint p;
    p.found = true;
    p.multiple = mult[e];
    const int i = static_cast<int>(e % static_cast<std::size_t>(g.nx)), j = static_cast<int>((e / static_cast<std::size_t>(g.nx)) % static_cast<std::size_t>(g.ny)),
              k = static_cast<int>(e / (static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny)));
    p.at = g.centre(i, j, k);
    const int c = cls[e];
    p.cls = c < static_cast<int>(np) ? "post" : c == static_cast<int>(np) ? "vine" : c == static_cast<int>(np) + 1 ? "solid_near_post" : "solid";
    p.post = c < static_cast<int>(np) ? c : -1;
    p.thickness_voxels = break_member_thickness(mat, g.nx, g.ny, g.nz, i, j, k);
    p.resolved = res[e] != 0;
    p.by = tens[e] ? "tension" : "compression";
    return p;
  };
  // 8. per class, first breaks, the post sections, places too thin to judge under the pass line
  std::vector<double> cm(np + 3, std::numeric_limits<double>::infinity()), cmr(np + 3, std::numeric_limits<double>::infinity());
  std::vector<std::size_t> cw(np + 3, 0), cwr(np + 3, 0);
  for (std::size_t e = 0; e < mat.size(); ++e) {
    if (!mat[e] || cls[e] < 0) continue;
    const std::size_t c = static_cast<std::size_t>(cls[e]);
    if (mult[e] < cm[c]) { cm[c] = mult[e]; cw[c] = e; }
    if (res[e] && mult[e] < cmr[c]) { cmr[c] = mult[e]; cwr[c] = e; }
  }
  double fa = std::numeric_limits<double>::infinity(), fr = fa;
  for (std::size_t c = 0; c < np + 3; ++c) {
    BreakClass bc;
    bc.cls = c < np ? "post" : c == np ? "vine" : c == np + 1 ? "solid_near_post" : "solid";
    bc.post = c < np ? static_cast<int>(c) : -1;
    if (std::isfinite(cm[c])) bc.all = point(cw[c]);
    if (std::isfinite(cmr[c])) bc.resolved = point(cwr[c]);
    if (c < np) {   // the force across the post's mid-height over its file section (the laid square clipped to the box)
      const BreakPost& p = ask.posts[c];
      const double zm = 0.5 * (p.z_bottom + p.z_top);
      const int km = std::max(0, std::min(g.nz - 1, static_cast<int>(std::floor((zm - g.lo.z) / h))));
      double f = 0.0;
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const Vec3 cc = g.centre(i, j, km);
          if (!M(i, j, km) || cc.x < pbox[c][0] - 0.5 * h || cc.x > pbox[c][1] + 0.5 * h || cc.y < pbox[c][2] - 0.5 * h || cc.y > pbox[c][3] + 0.5 * h) continue;
          // the force along the post's axis (the build direction)
          const auto& s = sig[g.index(i, j, km)];
          const Vec3& U = ask.up;
          const double ul = std::sqrt(U.x * U.x + U.y * U.y + U.z * U.z);
          const Vec3 n{U.x / ul, U.y / ul, U.z / ul};
          const double sn = s[0] * n.x * n.x + s[1] * n.y * n.y + s[2] * n.z * n.z + 2.0 * (s[3] * n.x * n.y + s[4] * n.y * n.z + s[5] * n.z * n.x);
          f += sn * h * h;
        }
      bc.section_mm2 = (pbox[c][1] - pbox[c][0]) * (pbox[c][3] - pbox[c][2]);
      bc.section_force_n = f;
      if (bc.section_mm2 > 0.0 && f != 0.0) {
        const double st = f / bc.section_mm2;
        bc.section_multiple = st < 0.0 ? ask.yield_mpa / -st : ask.yield_mpa * ask.z_knockdown / st;
      }
    }
    if (bc.all.found && bc.all.multiple < fa) { fa = bc.all.multiple; R.first_all = bc.all; }
    if (bc.resolved.found && bc.resolved.multiple < fr) { fr = bc.resolved.multiple; R.first_resolved = bc.resolved; }
    R.classes.push_back(bc);
  }
  {   // places too thin to judge under the pass line: seeds in order of multiple, at least 2 mm apart
    std::vector<std::size_t> cand;
    for (std::size_t e = 0; e < mat.size(); ++e)
      if (mat[e] && !res[e] && mult[e] < ask.pass_line) cand.push_back(e);
    std::sort(cand.begin(), cand.end(), [&](std::size_t a, std::size_t b) { return mult[a] < mult[b]; });
    for (std::size_t e : cand) {
      if (R.not_judged_under.size() >= ask.places_listed) break;
      const BreakPoint p0 = [&] {
        BreakPoint p;
        const int i = static_cast<int>(e % static_cast<std::size_t>(g.nx)), j = static_cast<int>((e / static_cast<std::size_t>(g.nx)) % static_cast<std::size_t>(g.ny)),
                  k = static_cast<int>(e / (static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny)));
        p.at = g.centre(i, j, k);
        return p;
      }();
      bool far = true;
      for (const BreakPoint& q : R.not_judged_under)
        far = far && std::hypot(std::hypot(q.at.x - p0.at.x, q.at.y - p0.at.y), q.at.z - p0.at.z) > 2.0;
      if (far) R.not_judged_under.push_back(point(e));
    }
  }
  // 9. the verdict
  bool post_section_under = false;
  for (const BreakClass& bc : R.classes)
    if (bc.cls == "post" && bc.all.found && !bc.all.resolved && bc.section_multiple > 0.0 && bc.section_multiple < ask.pass_line)
      post_section_under = true;   // a post too thin to judge whose file section reads under the pass line
  if (!R.first_resolved.found) R.verdict = "not_proven";
  else if (R.first_resolved.multiple < ask.pass_line) R.verdict = "fail";
  else if (!R.not_judged_under.empty() || post_section_under) R.verdict = "not_proven";
  else R.verdict = "pass";
  R.ok = true;
  R.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  R.peak_mb = process_memory().peak_rss_mb;
  // 10. the JSON block
  std::string j = "{\"verdict\": \"" + R.verdict + "\", \"pass_line\": " + num(ask.pass_line) + ", \"first_break\": " + point_json(R.first_resolved) +
                  ", \"first_break_all_points\": " + point_json(R.first_all) + ", \"classes\": [";
  for (std::size_t q = 0; q < R.classes.size(); ++q) {
    const BreakClass& bc = R.classes[q];
    j += std::string(q ? ", " : "") + "{\"class\": \"" + bc.cls + "\"" + (bc.post >= 0 ? ", \"post\": " + std::to_string(bc.post) : std::string()) +
         ", \"all\": " + point_json(bc.all) + ", \"judged\": " + point_json(bc.resolved) +
         (bc.cls == "post" ? ", \"section_mm2\": " + num(bc.section_mm2) + ", \"section_force_n\": " + num(bc.section_force_n) +
                                 ", \"section_multiple\": " + num(bc.section_multiple)
                           : std::string()) +
         "}";
  }
  j += "], \"not_judged_under_pass_line\": [";
  for (std::size_t q = 0; q < R.not_judged_under.size(); ++q) j += std::string(q ? ", " : "") + point_json(R.not_judged_under[q]);
  j += "], \"limit\": {\"yield_mpa\": " + num(ask.yield_mpa) + ", \"z_knockdown\": " + num(ask.z_knockdown) + ", \"up\": [" + num(ask.up.x) + ", " +
       num(ask.up.y) + ", " + num(ask.up.z) + "]}, \"grid\": {\"voxel_mm\": " + num(h) + ", \"nx\": " + std::to_string(g.nx) + ", \"ny\": " +
       std::to_string(g.ny) + ", \"nz\": " + std::to_string(g.nz) + ", \"material_voxels\": " + std::to_string(R.size.material_voxels) +
       ", \"bytes_estimate\": " + num(R.size.bytes) + ", \"smooth_mm\": " + num(ask.smooth_mm) + ", \"min_voxels_across\": " +
       std::to_string(ask.min_voxels_across) + "}, \"solve\": {\"rounds\": " + std::to_string(R.rounds) + ", \"converged\": " +
       (R.converged ? "true" : "false") + ", \"tolerance\": " + num(ask.tolerance) + ", \"seconds\": " + num(R.seconds) + ", \"peak_mb\": " +
       num(R.peak_mb) + "}}";
  R.json = j;
  return R;
}

}  // namespace topopt::lattice_layout
