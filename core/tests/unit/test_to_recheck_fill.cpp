// TO rebuild stage 2, "ONE JUDGE" (the reviewer's ruling 2026-11-27, evidence (a)).
//
// The re-check of a finished file will analyse each voxel's FILL of the file
// (file_fill.hpp) in place of all-or-nothing voxels. Evidence asked: the textbook
// shapes taken THROUGH that path (a closed mesh of the shape -> its fills -> the
// analysis) give the certificate's numbers (the same analysis on the shape's
// exact fills) within 1 %; and the sub-sampling k is chosen where the number
// moves under 0.5 % when k doubles.
//
// Shapes: the plate with a round hole (tests E) and the plate with an elliptical
// hole a / b = 2 (the third shape), each as an extruded mesh with the hole a
// 360-sided polygon, the pull tilted 30 degrees, four resolutions. Printed per
// shape and resolution: the certificate's peak (exact fills, today's stiffness
// E x fill^3, one voxel), the all-or-nothing peak (today's re-check), and the
// peak through the fills at k = 1, 2, 4, 8, each as a percent off the
// certificate. MEASURES by default; --gate fails when k = kRecheckSub misses 1 %.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/file_fill.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

constexpr double kFarStress = 10.0;  // MPa
constexpr double kTiltDeg = 30.0;
constexpr int kThickness = 2;        // voxels
constexpr int kSub = 8;
constexpr int kSides = 360;

std::vector<NodalLoad> edge_tractions(const VoxelGrid& g, double sxx, double syy,
                                      double sxy) {
  // Each boundary element face carries traction * area, a quarter to each node.
  const double q = 0.25 * g.spacing * g.spacing;
  std::vector<NodalLoad> loads;
  auto push = [&](int i, int j, int k, double fx, double fy) {
    const int n = topopt::fea_node_index(g, i, j, k);
    loads.push_back({n, 0, fx});
    loads.push_back({n, 1, fy});
  };
  for (int k = 0; k < g.nz; ++k) {
    for (int j = 0; j < g.ny; ++j)      // faces x = 0 (normal -x) and x = W (+x)
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj) {
          push(g.nx, j + dj, k + dk, q * sxx, q * sxy);
          push(0, j + dj, k + dk, -q * sxx, -q * sxy);
        }
    for (int i = 0; i < g.nx; ++i)      // faces y = 0 (normal -y) and y = W (+y)
      for (int dk = 0; dk < 2; ++dk)
        for (int di = 0; di < 2; ++di) {
          push(i + di, g.ny, k + dk, q * sxy, q * syy);
          push(i + di, 0, k + dk, -q * sxy, -q * syy);
        }
  }
  return loads;
}

struct Shape {
  const char* name;
  double a_over_b;  // long semi-axis (across the pull) / short (along it); 1 = round
  double short_mm;  // the short semi-axis in mm
  int width_in_long_axes;
};

// The plate of `w` voxels with the hole, as a closed mesh in VOXEL units scaled by
// the spacing: the hole a polygon of kSides sides, the outer boundary the same
// number of points on the square along the same rays (45 degrees is one of them,
// so the corners are points and every strip is flat and inside the square).
topopt::TriangleMesh plate_mesh(int w, double h, double cx, double cy, double a, double b,
                                double tilt) {
  topopt::TriangleMesh m;
  const double pi = std::acos(-1.0), c = std::cos(tilt), s = std::sin(tilt);
  auto on_square = [&](double ang) {
    // from the square's own centre, so the corners fall on 45 degrees exactly
    const double ox = 0.5 * w, oy = 0.5 * w, dx = std::cos(ang), dy = std::sin(ang);
    const double t = 0.5 * w / std::max(std::fabs(dx), std::fabs(dy));
    return Vec3{(ox + t * dx) * h, (oy + t * dy) * h, 0.0};
  };
  auto on_hole = [&](double ang) {
    // the hole's own centre and axes: u along the pull (short axis b), v across (a)
    const double ang0 = ang - tilt, u = b * std::cos(ang0), v = a * std::sin(ang0);
    return Vec3{(cx + u * c - v * s) * h, (cy + u * s + v * c) * h, 0.0};
  };
  const double top = kThickness * h;
  for (int i = 0; i < kSides; ++i) {
    const double ang = 2.0 * pi * i / kSides;
    const Vec3 o = on_square(ang), q = on_hole(ang);
    m.vertices.push_back(Vec3{q.x, q.y, 0.0});   // 4 i     hole, bottom
    m.vertices.push_back(Vec3{o.x, o.y, 0.0});   // 4 i + 1 outer, bottom
    m.vertices.push_back(Vec3{q.x, q.y, top});   // 4 i + 2 hole, top
    m.vertices.push_back(Vec3{o.x, o.y, top});   // 4 i + 3 outer, top
  }
  auto quad = [&](int p0, int p1, int p2, int p3) {
    m.triangles.push_back({p0, p1, p2});
    m.triangles.push_back({p0, p2, p3});
  };
  for (int i = 0; i < kSides; ++i) {
    const int j = (i + 1) % kSides, A = 4 * i, B = 4 * j;
    quad(A + 2, A + 3, B + 3, B + 2);  // top, normal +z
    quad(A, B, B + 1, A + 1);          // bottom, normal -z
    quad(A + 1, B + 1, B + 3, A + 3);  // outer wall, outward
    quad(A, A + 2, B + 2, B);          // hole wall, into the hole
  }
  return m;
}

// The peak von Mises / far stress of `density` on the plate's grid, by today's
// certificate form (E x fill^3, one voxel).
double peak(const VoxelGrid& g, const std::vector<double>& density, bool* ok) {
  const int w = g.nx;
  const double t = kTiltDeg * std::acos(-1.0) / 180.0;
  const double c = std::cos(t), s = std::sin(t);
  const std::vector<NodalLoad> loads =
      edge_tractions(g, kFarStress * c * c, kFarStress * s * s, kFarStress * s * c);
  std::vector<DirichletBC> bcs;
  const int n0 = topopt::fea_node_index(g, 0, 0, 0);
  const int n1 = topopt::fea_node_index(g, w, 0, 0);
  const int n2 = topopt::fea_node_index(g, 0, w, 0);
  bcs.push_back({n0, 0, 0.0});
  bcs.push_back({n0, 1, 0.0});
  bcs.push_back({n0, 2, 0.0});
  bcs.push_back({n1, 1, 0.0});
  bcs.push_back({n1, 2, 0.0});
  bcs.push_back({n2, 2, 0.0});
  topopt::Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 1.0;
  m.poisson = 0.33;
  m.family = "fdm";
  topopt::SimpParams params;
  params.youngs_modulus = m.youngs_modulus_mpa;
  params.poisson = m.poisson;
  params.penalty = 3.0;
  topopt::KnockdownSpec knockdown;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-8, 20000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  *ok = !res.non_convergent && res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  return res.max_von_mises / kFarStress;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  const Shape shapes[2] = {{"round hole", 1.0, 6.0, 20}, {"ellipse a/b = 2", 2.0, 3.0, 10}};
  const int kKs[4] = {1, 2, 4, 8};
  constexpr int kRecheckSub = 4;
  int failures = 0;
  const double tilt = kTiltDeg * std::acos(-1.0) / 180.0;
  std::printf("[one judge] the peak through the file's fills against the certificate's (exact fills), percent\n");
  std::printf("%-18s %6s %12s %10s %8s %8s %8s %8s\n", "shape", "b vox", "certificate", "all-or-0", "k = 1",
              "k = 2", "k = 4", "k = 8");
  for (const Shape& sh : shapes)
    for (int bv : {3, 4, 5, 6}) {
      const double b = bv, a = sh.a_over_b * bv;
      const int w = sh.width_in_long_axes * static_cast<int>(a);
      VoxelGrid g;
      g.nx = w;
      g.ny = w;
      g.nz = kThickness;
      g.spacing = sh.short_mm / bv;
      g.origin = Vec3{0.0, 0.0, 0.0};
      g.tags.assign(static_cast<std::size_t>(w) * w * kThickness, topopt::VoxelTag::Interior);
      const double cx = 0.5 * w + 0.29, cy = 0.5 * w - 0.41, c = std::cos(tilt), s = std::sin(tilt);
      auto solid = [&](double x, double y) {
        const double dx = x - cx, dy = y - cy, u = dx * c + dy * s, v = -dx * s + dy * c;
        return (u * u) / (b * b) + (v * v) / (a * a) > 1.0;
      };
      std::vector<double> exact(g.tags.size(), 1.0), binary(g.tags.size(), 1.0);
      for (int j = 0; j < w; ++j)
        for (int i = 0; i < w; ++i) {
          int in = 0;
          for (int q = 0; q < kSub; ++q)
            for (int p = 0; p < kSub; ++p)
              if (solid(i + (p + 0.5) / kSub, j + (q + 0.5) / kSub)) ++in;
          for (int k = 0; k < kThickness; ++k) {
            const std::size_t v = (static_cast<std::size_t>(k) * w + j) * w + i;
            exact[v] = static_cast<double>(in) / (kSub * kSub);
            binary[v] = solid(i + 0.5, j + 0.5) ? 1.0 : 0.0;
          }
        }
      bool ok = false;
      const double cert = peak(g, exact, &ok);
      if (!ok) ++failures;
      const double bin = peak(g, binary, &ok);
      if (!ok) ++failures;
      std::printf("%-18s %6d %12.3f %+9.1f%%", sh.name, bv, cert, 100.0 * (bin / cert - 1.0));
      const topopt::TriangleMesh mesh = plate_mesh(w, g.spacing, cx, cy, a, b, tilt);
      for (int k : kKs) {
        const std::vector<double> fill = topopt::file_fill_fractions(mesh, g, k);
        const double v = peak(g, fill, &ok);
        if (!ok) ++failures;
        const double off = 100.0 * (v / cert - 1.0);
        std::printf(" %+7.1f%%", off);
        if (gate && k == kRecheckSub && std::fabs(off) > 1.0) ++failures;
        std::fflush(stdout);
      }
      std::printf("\n");
    }
  std::printf("[one judge] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
