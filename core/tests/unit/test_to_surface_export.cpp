// TO rebuild, repo tests B, F and J (docs/design/to-rebuild/04-tests.md), on the
// stage 3 export: the zero surface of the optimiser's function cut by the drawn
// part (level_surface.hpp, function_surface_mesh).
//
// The drawn part is a block 48 x 36 x 24 mm with a 5 mm radius through bore,
// turned 17 and 9 degrees to the grid, so no drawn face lies on a voxel plane. The
// design keeps the block and cuts a ball-shaped pocket through its top face (an
// optimised wall meeting a drawn face). Voxel 1.7 mm, smooth_factor 2.
//
//   B  drawn faces after export: every point of the file on a drawn plane within
//      0.02 mm of it, every point on the bore within 0.02 mm of its radius, and the
//      bore's mean radius within 0.02 mm of the drawn one. Points are taken at the
//      vertices AND inside every triangle, so the chord counts.
//   J  the file is one clean solid: no open edge, no edge on more than two
//      triangles, no point contact, one body.
//   F  ripple: a slab whose top is a long smooth wave (40 mm), tilted to the grid;
//      the deviation of the exported top from the true one, band-passed to 1 to
//      10 mm wavelengths, at most 0.05 mm.
//
//   no argument : MEASURE (fails only on a broken run).  --gate : also fails on a
//   missed target. Needs Manifold (the drawn part is built with it, and the export
//   cuts with it).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "manifold/manifold.h"
#include "topopt/finish.hpp"
#include "topopt/level_surface.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/voxel.hpp"

using topopt::Vec3;

namespace {

constexpr double kVoxel = 1.7;
constexpr double kPi = 3.14159265358979323846;

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

// A rotation (about x by ax, then about y by ay), applied about a centre.
struct Frame {
  double R[3][3];
  Vec3 c;
  Vec3 to_world(const Vec3& p) const {
    return {c.x + R[0][0] * p.x + R[0][1] * p.y + R[0][2] * p.z,
            c.y + R[1][0] * p.x + R[1][1] * p.y + R[1][2] * p.z,
            c.z + R[2][0] * p.x + R[2][1] * p.y + R[2][2] * p.z};
  }
  Vec3 to_local(const Vec3& w) const {
    const Vec3 d = sub(w, c);
    return {R[0][0] * d.x + R[1][0] * d.y + R[2][0] * d.z,
            R[0][1] * d.x + R[1][1] * d.y + R[2][1] * d.z,
            R[0][2] * d.x + R[1][2] * d.y + R[2][2] * d.z};
  }
  Vec3 axis(int k) const { return {R[0][k], R[1][k], R[2][k]}; }
};
Frame make_frame(double ax_deg, double ay_deg, const Vec3& c) {
  const double a = ax_deg * kPi / 180.0, b = ay_deg * kPi / 180.0;
  const double Rx[3][3] = {{1, 0, 0}, {0, std::cos(a), -std::sin(a)}, {0, std::sin(a), std::cos(a)}};
  const double Ry[3][3] = {{std::cos(b), 0, std::sin(b)}, {0, 1, 0}, {-std::sin(b), 0, std::cos(b)}};
  Frame f;
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) {
      f.R[i][j] = 0.0;
      for (int k = 0; k < 3; ++k) f.R[i][j] += Ry[i][k] * Rx[k][j];
    }
  f.c = c;
  return f;
}

topopt::TriangleMesh from_manifold(const manifold::Manifold& M) {
  const manifold::MeshGL64 g = M.GetMeshGL64();
  topopt::TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

manifold::Manifold place(const manifold::Manifold& m, const Frame& f) {
  return m.Transform(manifold::mat3x4(manifold::vec3(f.R[0][0], f.R[1][0], f.R[2][0]),
                                      manifold::vec3(f.R[0][1], f.R[1][1], f.R[2][1]),
                                      manifold::vec3(f.R[0][2], f.R[1][2], f.R[2][2]),
                                      manifold::vec3(f.c.x, f.c.y, f.c.z)));
}

// A version the way the optimiser would ship it: the basis fitted to the design's
// true signed distance at every voxel centre (clamped at 6 voxels, ridge 1e-6:
// the optimiser's own re-fit), the density the fill count of that function on the
// optimiser's 4 x 4 x 4 sub-cell lattice.
topopt::MinimizePlasticVariant make_version(const topopt::VoxelGrid& g,
                                            const std::function<double(const Vec3&)>& design) {
  using namespace topopt;
  MinimizePlasticVariant v;
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  const std::size_t n = g.voxel_count();
  const PlsmBasisKind B = PlsmBasisKind::BSpline3;
  v.plsm_lattice = plsm_make_lattice(nx, ny, nz, 2.0, 2.0, 2.0, plsm_effective_support(B, 2.0));
  v.plsm_basis_kind = B;
  v.plsm_frac_samples = 4;
  const PlsmCsr A = plsm_build_A(nx, ny, nz, v.plsm_lattice, B, 1);
  const PlsmCsr At = plsm_transpose(A, 1);
  std::vector<double> tgt(n), w(n, 1.0);
  for (std::size_t c = 0; c < n; ++c) {
    const int i = static_cast<int>(c % nx), j = static_cast<int>((c / nx) % ny),
              k = static_cast<int>(c / (static_cast<std::size_t>(nx) * ny));
    tgt[c] = std::max(-6.0 * g.spacing, std::min(6.0 * g.spacing, design(g.voxel_center(i, j, k))));
  }
  v.plsm_alpha = plsm_solve_normal(A, At, tgt, w, 1e-6, 4000, 1e-10, 1).alpha;
  v.optimization.physical_density.assign(n, 0.0);
  for (std::size_t c = 0; c < n; ++c) {
    if (g.tags[c] == VoxelTag::Empty) continue;
    const int i = static_cast<int>(c % nx), j = static_cast<int>((c / nx) % ny),
              k = static_cast<int>(c / (static_cast<std::size_t>(nx) * ny));
    int in = 0;
    for (int r = 0; r < 4; ++r)
      for (int q = 0; q < 4; ++q)
        for (int p = 0; p < 4; ++p)
          in += plsm_value_grad(v.plsm_lattice, B, v.plsm_alpha, i + (p + 0.5) / 4 - 0.5,
                                j + (q + 0.5) / 4 - 0.5, k + (r + 0.5) / 4 - 0.5,
                                nullptr) < 0.0;
    v.optimization.physical_density[c] = 1e-3 + (1.0 - 1e-3) * in / 64.0;
  }
  return v;
}

// Every point of the file the measures read: vertices, centroids, edge midpoints.
std::vector<Vec3> sample_points(const topopt::TriangleMesh& m) {
  std::vector<Vec3> p(m.vertices.begin(), m.vertices.end());
  for (const auto& t : m.triangles) {
    const Vec3 &a = m.vertices[t[0]], &b = m.vertices[t[1]], &c = m.vertices[t[2]];
    p.push_back({(a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3, (a.z + b.z + c.z) / 3});
    p.push_back({(a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2});
    p.push_back({(b.x + c.x) / 2, (b.y + c.y) / 2, (b.z + c.z) / 2});
  }
  return p;
}

}  // namespace

int main(int argc, char** argv) {
  using namespace topopt;
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  int failures = 0;

  // ── B and J: the block with a bore and a pocket ──────────────────────────
  const Vec3 H{24.0, 18.0, 12.0};  // half sizes
  const double Rb = 5.0, Rp = 8.0;
  const Frame F = make_frame(17.0, 9.0, Vec3{40.0, 40.0, 40.0});
  const manifold::Manifold block =
      manifold::Manifold::Cube(manifold::vec3(2 * H.x, 2 * H.y, 2 * H.z), true) -
      manifold::Manifold::Cylinder(4 * H.z, Rb, -1.0, 512, true);
  const TriangleMesh part = from_manifold(place(block, F));
  const Vec3 pocket_local{8.0, -4.0, H.z + 3.0};  // centre above the top face
  const Vec3 pocket = F.to_world(pocket_local);
  auto design = [&](const Vec3& p) {  // phi: negative solid; the pocket is void
    return Rp - std::sqrt(dot(sub(p, pocket), sub(p, pocket)));
  };
  Vec3 lo, hi;
  bounding_box(part, lo, hi);
  const double longest = std::max({hi.x - lo.x, hi.y - lo.y, hi.z - lo.z});
  const VoxelGrid g = voxelize(part, static_cast<int>(std::lround(longest / kVoxel)));
  const MinimizePlasticVariant ver = make_version(g, design);
  std::string why;
  FunctionSurfaceReport rep;
  const TriangleMesh file = function_surface_mesh(ver, g, part, 2, 0.5, &why, &rep);
  std::printf("[test B/J] voxel %.3f mm, grid %d x %d x %d, file %zu triangles%s%s\n",
              g.spacing, g.nx, g.ny, g.nz, file.triangles.size(), why.empty() ? "" : ": ",
              why.c_str());
  if (file.triangles.empty()) {
    std::printf("[test B/J] BROKEN: no file\n");
    return 1;
  }
  // B: each point near a drawn surface, attributed to the nearest one.
  double flat_worst = 0.0, bore_worst = 0.0, bore_sum = 0.0;
  long long flat_n = 0, bore_n = 0;
  for (const Vec3& w : sample_points(file)) {
    const double dp = std::sqrt(dot(sub(w, pocket), sub(w, pocket))) - Rp;
    if (std::fabs(dp) < 0.3) continue;  // on the cut wall (or its seam): not drawn
    const Vec3 q = F.to_local(w);
    const double planes[6] = {std::fabs(q.x - H.x), std::fabs(q.x + H.x), std::fabs(q.y - H.y),
                              std::fabs(q.y + H.y), std::fabs(q.z - H.z), std::fabs(q.z + H.z)};
    double dmin = *std::min_element(planes, planes + 6);
    const double r = std::hypot(q.x, q.y);
    const double db = std::fabs(r - Rb);
    if (db < dmin && db < 0.3) {
      bore_worst = std::max(bore_worst, db);
      bore_sum += r;
      ++bore_n;
    } else if (dmin < 0.3) {
      flat_worst = std::max(flat_worst, dmin);
      ++flat_n;
    }
  }
  const double bore_mean = bore_n > 0 ? bore_sum / bore_n : 0.0;
  const bool b_ok = flat_worst <= 0.02 && bore_worst <= 0.02 && std::fabs(bore_mean - Rb) <= 0.02;
  std::printf("[test B] flats: worst %.4f mm over %lld points; bore: worst %.4f mm, mean "
              "radius %.4f (drawn %.1f) over %lld points: %s\n",
              flat_worst, flat_n, bore_worst, bore_mean, Rb, bore_n, b_ok ? "ok" : "MISSED");
  if (flat_n < 100 || bore_n < 100) ++failures;
  if (gate && !b_ok) ++failures;
  // J: one clean solid.
  const WrittenAudit a = audit_as_written(file);
  const bool j_ok = a.non_manifold_edges == 0 && a.boundary_edges == 0 &&
                    a.non_manifold_vertices == 0 && a.bodies == 1;
  std::printf("[test J] open edges %d, edges on 3+ triangles %d, point contacts %d, bodies %d: %s\n",
              a.boundary_edges, a.non_manifold_edges, a.non_manifold_vertices, a.bodies,
              j_ok ? "ok" : "MISSED");
  if (gate && !j_ok) ++failures;

  // ── F: ripple on a long smooth wave ──────────────────────────────────────
  {
    const Frame S = make_frame(13.0, 7.0, Vec3{35.0, 35.0, 20.0});
    const double A = 2.0, lam = 40.0;
    // A slab |z| < 8 in its own frame with the top at z = 8 + A sin(2 pi x / lam).
    auto top = [&](double x) { return 8.0 + A * std::sin(2.0 * kPi * x / lam); };
    auto slab = [&](const Vec3& w) {  // negative inside; true distance near the top
      const Vec3 q = S.to_local(w);
      const double s = 2.0 * kPi * A / lam * std::cos(2.0 * kPi * q.x / lam);
      return std::max((q.z - top(q.x)) / std::sqrt(1.0 + s * s), -8.0 - q.z);
    };
    const manifold::Manifold box = manifold::Manifold::Cube(manifold::vec3(60, 40, 30), true);
    const TriangleMesh drawn = from_manifold(place(box, S));
    const VoxelGrid gs = voxelize(drawn, static_cast<int>(std::lround(60.0 / kVoxel)));
    const MinimizePlasticVariant vs = make_version(gs, slab);
    std::string w2;
    const TriangleMesh fs = function_surface_mesh(vs, gs, drawn, 2, 0.5, &w2);
    // Deviation of every top point from the true top, in the slab's own frame,
    // gathered on 0.25 mm bins along x (the wave runs along x), then band-passed:
    // a 1 mm mean minus a 10 mm mean.
    const int nb = 240;  // x in [-30, 30)
    std::vector<double> sum(nb, 0.0), cnt(nb, 0.0);
    for (const Vec3& wpt : sample_points(fs)) {
      const Vec3 q = S.to_local(wpt);
      if (std::fabs(q.y) > 15.0 || q.z < 4.0) continue;  // the top, away from the ends
      const int b = static_cast<int>(std::floor((q.x + 30.0) / 0.25));
      if (b < 0 || b >= nb) continue;
      sum[b] += q.z - top(q.x);
      cnt[b] += 1.0;
    }
    auto mean_win = [&](int b, int half) {
      double s = 0.0, c = 0.0;
      for (int k = std::max(0, b - half); k <= std::min(nb - 1, b + half); ++k) {
        s += sum[k];
        c += cnt[k];
      }
      return c > 0 ? s / c : 0.0;
    };
    double ripple = 0.0, worst = 0.0;
    long long used = 0;
    for (int b = 40; b < nb - 40; ++b) {  // 10 mm in from each end
      if (cnt[b] == 0) continue;
      ripple = std::max(ripple, std::fabs(mean_win(b, 2) - mean_win(b, 20)));
      worst = std::max(worst, std::fabs(sum[b] / cnt[b]));
      ++used;
    }
    const bool f_ok = ripple <= 0.05;
    std::printf("[test F] wave 40 mm tilted 13/7 deg: ripple at 1-10 mm %.4f mm, worst "
                "deviation %.4f mm over %lld bins%s%s: %s\n",
                ripple, worst, used, w2.empty() ? "" : ", ", w2.c_str(), f_ok ? "ok" : "MISSED");
    if (used < 100) ++failures;
    if (gate && !f_ok) ++failures;
  }
  std::printf("[test B/F/J] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
