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
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "manifold/manifold.h"
#include "topopt/finish.hpp"
#include "topopt/frozen_sets.hpp"
#include "topopt/step.hpp"
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
topopt::MinimizePlasticVariant make_version(
    const topopt::VoxelGrid& g, const std::function<double(const Vec3&)>& design,
    const std::function<bool(const Vec3&)>& frozen = nullptr) {
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
    if (frozen && frozen(g.voxel_center(i, j, k))) v.optimization.physical_density[c] = 1.0;
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
  // A cavity inside the block, cut 1.5 mm into the protected bottom layer (local
  // z < -8: the bottom face frozen 4 mm deep). The layer must win, with its inner
  // face flat at z = -8 by true distance.
  const double kDepth = 4.0;
  auto cavity = [&](const Vec3& p) {  // signed distance to the cavity box, < 0 inside
    const Vec3 q = F.to_local(p);
    const double dx = std::fabs(q.x) - 15.0, dy = std::fabs(q.y) - 10.0,
                 dz = std::fabs(q.z + 5.75) - 3.75;  // z from -9.5 to -2
    const double ox = std::max(dx, 0.0), oy = std::max(dy, 0.0), oz = std::max(dz, 0.0);
    return std::sqrt(ox * ox + oy * oy + oz * oz) + std::min(std::max({dx, dy, dz}), 0.0);
  };
  auto design = [&](const Vec3& p) {  // phi: negative solid; pocket and cavity are void
    return std::max(Rp - std::sqrt(dot(sub(p, pocket), sub(p, pocket))), -cavity(p));
  };
  auto in_layer = [&](const Vec3& p) { return F.to_local(p).z + H.z <= kDepth; };
  Vec3 lo, hi;
  bounding_box(part, lo, hi);
  const double longest = std::max({hi.x - lo.x, hi.y - lo.y, hi.z - lo.z});
  const VoxelGrid g = voxelize(part, static_cast<int>(std::lround(longest / kVoxel)));
  const MinimizePlasticVariant ver = make_version(g, design, in_layer);
  // The protected bottom face as the run declares it (frozen_sets.hpp).
  StepModel model;
  model.mesh = part;
  model.triangle_face.assign(part.triangles.size(), -1);
  FrozenFaceSet bottom;
  bottom.depth_mm = kDepth;
  for (std::size_t t = 0; t < part.triangles.size(); ++t) {
    bool on = true;
    for (int c = 0; c < 3; ++c)
      on = on && std::fabs(F.to_local(part.vertices[part.triangles[t][c]]).z + H.z) < 1e-6;
    if (on) bottom.triangles.push_back(static_cast<int>(t));
  }
  const std::vector<FrozenFaceSet> sets{bottom};
  std::string why;
  FunctionSurfaceReport rep;
  const TriangleMesh file =
      function_surface_mesh(ver, g, part, 2, 0.5, &why, &rep, &sets, &model);
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
  double layer_worst = 0.0;
  long long layer_n = 0;
  Vec3 layer_at{0, 0, 0};
  for (const Vec3& w : sample_points(file)) {
    const double dp = std::sqrt(dot(sub(w, pocket), sub(w, pocket))) - Rp;
    if (std::fabs(dp) < 0.3) continue;  // on the cut wall (or its seam): not drawn
    const Vec3 q = F.to_local(w);
    // The frozen layer's inner face, inside the cavity's footprint, 3 mm from its
    // walls (the walls are the design's, rounded by the basis).
    // The rim where the bore meets that face is a sharp edge between a drawn surface
    // and a meshed one (chord up to a fraction of a cell): left out of the flatness.
    if (std::fabs(q.x) < 12.0 && std::fabs(q.y) < 7.0 && q.z > -9.0 && q.z < -7.0) {
      if (std::fabs(std::hypot(q.x, q.y) - Rb) < 0.5 && std::fabs(q.z + H.z - kDepth) < 0.5)
        continue;  // on the rim itself: an edge, in neither the face nor the bore
      if (std::fabs(q.z + H.z - kDepth) > layer_worst) layer_at = q;
      layer_worst = std::max(layer_worst, std::fabs(q.z + H.z - kDepth));
      ++layer_n;
      continue;
    }
    if (cavity(w) > -0.3 && cavity(w) < 3.0 && q.z > -9.0) continue;  // cavity walls
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
  const bool b_ok = flat_worst <= 0.02 && bore_worst <= 0.02 &&
                    std::fabs(bore_mean - Rb) <= 0.02 && layer_worst <= 0.02;
  std::printf("[test B] protected layer's inner face (true depth %.1f mm, %d body): worst %.4f mm "
              "over %lld points (at local %.2f, %.2f, %.2f); stamped voxels left %lld\n",
              kDepth, rep.frozen_sets, layer_worst, layer_n, layer_at.x, layer_at.y, layer_at.z,
              rep.stamped_solid);
  if (layer_n < 50) ++failures;
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
  // ── J, the two cases his stand forced: neighbours that touch only along an edge
  // (two stamped voxels; two keep regions) must fuse, not meet on a line. NOTE: an
  // isolated diagonal pair is already joined by the Catmull-Rom overshoot, so the
  // stamp half of this passes even without the 0.01 mm fusing; the stand's own
  // configurations (larger patterns) are checked by its reference run. ─────────────
  {
    const manifold::Manifold box = manifold::Manifold::Cube(manifold::vec3(30, 30, 30), true)
                                       .Translate(manifold::vec3(20, 20, 20));
    const TriangleMesh drawn = from_manifold(box);
    const VoxelGrid gj = voxelize(drawn, static_cast<int>(std::lround(30.0 / kVoxel)));
    // The design keeps a slab along x = low and is void elsewhere; two voxels in the
    // void are stamped solid and share only an edge, and so do two keep boxes.
    MinimizePlasticVariant vj = make_version(gj, [&](const Vec3& p) { return p.x - 12.0; });
    // The first voxel past the slab's face (x = 12) touches the slab; the second
    // touches the first only along an edge. The keep boxes likewise.
    const int i0 = static_cast<int>(std::ceil((12.0 - gj.origin.x) / gj.spacing - 0.5)),
              j0 = gj.ny / 2, k0 = gj.nz / 2;
    for (int d = 0; d < 2; ++d) {
      const std::size_t c = (static_cast<std::size_t>(k0) * gj.ny + (j0 + d)) * gj.nx + (i0 + d);
      vj.optimization.physical_density[c] = 1.0;
    }
    const double e = gj.spacing;
    const Vec3 kc = gj.voxel_center(i0, j0 - 4, k0);
    std::vector<KeepRegion> keeps(2);
    for (int d = 0; d < 2; ++d) {
      keeps[d].min = Vec3{11.5 + d * e, kc.y + d * e, kc.z - e};
      keeps[d].max = Vec3{11.5 + (d + 1) * e, kc.y + (d + 1) * e, kc.z + e};
    }
    manifold::Manifold K;
    for (const KeepRegion& k : keeps)  // as to_export.inc builds it: grown 0.01 mm
      K = K + manifold::Manifold::Cube(manifold::vec3(k.max.x - k.min.x + 0.02, k.max.y - k.min.y + 0.02,
                                                      k.max.z - k.min.z + 0.02))
                  .Translate(manifold::vec3(k.min.x - 0.01, k.min.y - 0.01, k.min.z - 0.01));
    const TriangleMesh ks = from_manifold(K);
    std::string wj;
    FunctionSurfaceReport rj;
    const TriangleMesh fj = function_surface_mesh(vj, gj, drawn, 2, 0.5, &wj, &rj, nullptr,
                                                  nullptr, &keeps, &ks);
    const WrittenAudit aj = audit_as_written(fj);
    const bool ok = !fj.triangles.empty() && aj.non_manifold_edges == 0 &&
                    aj.boundary_edges == 0 && aj.non_manifold_vertices == 0;
    std::printf("[test J] edge-touching stamps and keep regions: %lld stamped; open %d, 3+ %d, "
                "point %d, bodies %d%s%s: %s\n",
                rj.stamped_solid, aj.boundary_edges, aj.non_manifold_edges,
                aj.non_manifold_vertices, aj.bodies, wj.empty() ? "" : ", ", wj.c_str(),
                ok ? "ok" : "MISSED");
    if (gate && !ok) ++failures;
  }
  // ── J, a design-box run (his stand, stage 1 + 3): the box's keep-out is Empty on the
  // grid, where the function means nothing, and a keep region's air is the part's own
  // shape; neither may hold material, whatever the function says there. The design is
  // a slab (solid below y = 12) running through the keep-out; the keep region straddles
  // the part's +x face and the slab's top, as his protected faces sit on material.
  // Without the box cut both printed. ─────────────────────────────────────────────────
  {
    const manifold::Manifold part = manifold::Manifold::Cube(manifold::vec3(30, 30, 30), true)
                                        .Translate(manifold::vec3(20, 20, 20));  // 5..35
    const TriangleMesh drawn = from_manifold(part);
    const VoxelGrid pg = voxelize(drawn, static_cast<int>(std::lround(30.0 / kVoxel)));
    const DesignBox box{Vec3{5, 5, 5}, Vec3{55, 35, 35}};  // grows +x by 20 mm
    // The keep-out shares the box's y faces and its top: the coplanar case.
    const std::vector<DesignBox> outs{DesignBox{Vec3{42, 5, 20}, Vec3{48, 35, 35}}};
    const DesignDomain dom = expand_design_domain(pg, box, outs, false);
    MinimizePlasticVariant vb = make_version(dom.grid, [](const Vec3& p) { return p.y - 12.0; });
    std::vector<KeepRegion> keeps(1);  // x: 31..35 part, 35..39 air; y: across the slab's top
    keeps[0].min = Vec3{31, 8, 15};
    keeps[0].max = Vec3{39, 16, 25};
    auto cube = [](const Vec3& lo, const Vec3& hi, double g) {
      return manifold::Manifold::Cube(manifold::vec3(hi.x - lo.x + 2 * g, hi.y - lo.y + 2 * g,
                                                     hi.z - lo.z + 2 * g))
          .Translate(manifold::vec3(lo.x - g, lo.y - g, lo.z - g));
    };
    // A bolt's Keep clear through the slab, in the box beyond the part: radius 2 mm about
    // x = 51, y = 8, the box's whole height.
    auto bolt = [](double r) {  // as clearance_solid makes it: a circumscribed 128-gon
      return manifold::Manifold::Cylinder(30.0 + 2 * (r - 2.0), r / std::cos(kPi / 128), -1.0, 128)
          .Translate(manifold::vec3(51, 8, 5 - (r - 2.0)));
    };
    // As to_export.inc builds them: keep_solid grown 0.01 mm; the box cut is the keep
    // regions grown 0.02 mm, the keep-outs and the Keep clears grown 0.01 mm.
    const TriangleMesh ks = from_manifold(cube(keeps[0].min, keeps[0].max, 0.01));
    const TriangleMesh bc = from_manifold(cube(keeps[0].min, keeps[0].max, 0.02) +
                                          cube(outs[0].min, outs[0].max, 0.01) + bolt(2.01));
    struct Vols { double out = -1, air = -1, box = -1, bolt = -1; WrittenAudit a; std::string why; };
    auto measure = [&](const TriangleMesh* cut) {
      Vols r;
      FunctionSurfaceReport rb;
      const TriangleMesh fb = function_surface_mesh(vb, dom.grid, drawn, 2, 0.5, &r.why, &rb,
                                                    nullptr, nullptr, &keeps, &ks, &box, cut);
      r.a = audit_as_written(fb);
      if (fb.triangles.empty()) return r;
      manifold::MeshGL64 g;
      g.numProp = 3;
      for (const Vec3& q : fb.vertices) {
        g.vertProperties.push_back(q.x);
        g.vertProperties.push_back(q.y);
        g.vertProperties.push_back(q.z);
      }
      for (const auto& t : fb.triangles)
        for (int c = 0; c < 3; ++c) g.triVerts.push_back(static_cast<std::uint64_t>(t[c]));
      g.Merge();
      const manifold::Manifold F(g);
      r.out = (F ^ cube(outs[0].min, outs[0].max, 0.0)).Volume();
      r.air = (F ^ cube(Vec3{35, 8, 15}, keeps[0].max, 0.0)).Volume();
      r.box = (F ^ cube(Vec3{35, 5, 5}, box.max, 0.0)).Volume();  // the box outside the part
      r.bolt = (F ^ bolt(2.0)).Volume();
      return r;
    };
    const Vols before = measure(nullptr), after = measure(&bc);
    // Outside the part the slab holds 20 x 7 x 30 = 4200 mm3, less the keep-out's share
    // 6.02 x 7 x 15.01 = 632.5 (grown 0.01 mm), the keep region's 4.02 x 4.02 x 10.04
    // = 162.3 (grown 0.02 mm; inside a keep region only the part prints) and the bolt's
    // 12.695 x 30 = 380.8 (its 128-gon, r 2.01 mm): 3024.4 mm3.
    const bool ok = after.a.non_manifold_edges == 0 && after.a.boundary_edges == 0 &&
                    after.a.non_manifold_vertices == 0 && after.a.bodies == 1 &&
                    after.out < 1e-6 && after.air < 1e-6 && after.bolt < 1e-6 &&
                    std::fabs(after.box - 3024.4) < 10.0;
    std::printf("[test J] design box, without the box cut: keep-out %.1f mm3, keep region's air "
                "%.1f mm3, bolt's Keep clear %.1f mm3, box outside the part %.1f mm3\n", before.out,
                before.air, before.bolt, before.box);
    std::printf("[test J] design box, with it: keep-out %.4f mm3, keep region's air %.4f mm3, "
                "bolt's Keep clear %.4f mm3 (all 0); box outside the part %.1f mm3 (3024.4); open %d, "
                "3+ %d, point %d, bodies %d%s%s: %s\n", after.out, after.air, after.bolt, after.box,
                after.a.boundary_edges,
                after.a.non_manifold_edges, after.a.non_manifold_vertices, after.a.bodies,
                after.why.empty() ? "" : ", ", after.why.c_str(), ok ? "ok" : "MISSED");
    if (gate && !ok) ++failures;
  }
  // ── B, a keep layer on a design-box run (his stand, stage 1 + 3): the frozen body
  // is everything OF THE PART within its depth (frozen_sets.hpp). By distance alone it
  // was two-sided, and the box kept its outside half (caps over his bolts' keep layers).
  // The design is solid only far from the protected face; the layer must fill 4 mm
  // inside the part and nothing past the face. ──────────────────────────────────────
  {
    const manifold::Manifold cube = manifold::Manifold::Cube(manifold::vec3(30, 30, 30), true)
                                        .Translate(manifold::vec3(20, 20, 20));  // 5..35
    const TriangleMesh drawn = from_manifold(cube);
    const VoxelGrid pg = voxelize(drawn, static_cast<int>(std::lround(30.0 / kVoxel)));
    const DesignBox box{Vec3{5, 5, 5}, Vec3{55, 35, 35}};
    const DesignDomain dom = expand_design_domain(pg, box, {}, false);
    const double depth = 4.0;
    auto in_layer = [&](const Vec3& p) { return p.x >= 35.0 - depth && p.x <= 35.0; };
    MinimizePlasticVariant vk = make_version(dom.grid, [](const Vec3& p) { return p.x - 15.0; }, in_layer);
    StepModel mk;
    mk.mesh = drawn;
    mk.triangle_face.assign(drawn.triangles.size(), -1);
    FrozenFaceSet face;  // the +x face, kept 4 mm deep
    face.depth_mm = depth;
    for (std::size_t t = 0; t < drawn.triangles.size(); ++t) {
      bool on = true;
      for (int c = 0; c < 3; ++c) on = on && std::fabs(drawn.vertices[drawn.triangles[t][c]].x - 35.0) < 1e-9;
      if (on) face.triangles.push_back(static_cast<int>(t));
    }
    const std::vector<FrozenFaceSet> ks{face};
    std::string wk;
    FunctionSurfaceReport rk;
    const TriangleMesh fk = function_surface_mesh(vk, dom.grid, drawn, 2, 0.5, &wk, &rk, &ks, &mk,
                                                  nullptr, nullptr, &box, nullptr);
    double v_out = -1, v_layer = -1, proud = 0.0;
    for (const Vec3& q : fk.vertices) proud = std::max(proud, q.x - 35.0);  // past the face
    if (!fk.triangles.empty()) {
      manifold::MeshGL64 g;
      g.numProp = 3;
      for (const Vec3& q : fk.vertices) {
        g.vertProperties.push_back(q.x);
        g.vertProperties.push_back(q.y);
        g.vertProperties.push_back(q.z);
      }
      for (const auto& t : fk.triangles)
        for (int c = 0; c < 3; ++c) g.triVerts.push_back(static_cast<std::uint64_t>(t[c]));
      g.Merge();
      const manifold::Manifold Fk(g);
      auto region = [](double x0, double x1) {
        return manifold::Manifold::Cube(manifold::vec3(x1 - x0, 40, 40)).Translate(manifold::vec3(x0, 0, 0));
      };
      v_out = (Fk ^ region(35.0, 60.0)).Volume();      // past the protected face
      v_layer = (Fk ^ region(35.0 - depth, 35.0)).Volume();  // the layer: 4 x 30 x 30 = 3600
    }
    const WrittenAudit ak = audit_as_written(fk);
    // Past the face: nothing but the surface's rounding along the face's edges, where
    // the box (not the drawn part) bounds the domain and so no exact cut makes them
    // (measured 0.027 mm at the corners, the face's middle exact); before, the 4 mm band
    // stood there (3600 mm3).
    const bool ok = !fk.triangles.empty() && proud <= 0.05 && v_out < 0.5 && std::fabs(v_layer - 3600.0) < 10.0 &&
                    ak.boundary_edges == 0 && ak.non_manifold_edges == 0 && ak.non_manifold_vertices == 0;
    std::printf("[test B] keep layer on a design-box run: past the face %.4f mm3, at most %.4f mm (0.05), "
                "the layer %.1f mm3 (3600), %d frozen body; open %d, 3+ %d, point %d, bodies %d%s%s: %s\n",
                v_out, proud, v_layer, rk.frozen_sets, ak.boundary_edges, ak.non_manifold_edges,
                ak.non_manifold_vertices, ak.bodies, wk.empty() ? "" : ", ", wk.c_str(), ok ? "ok" : "MISSED");
    if (gate && !ok) ++failures;
  }
  std::printf("[test B/F/J] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
