// TO rebuild, repo test A (docs/design/to-rebuild/04-tests.md).
//
// The exported surface of shapes whose true surface is known: flat walls tilted
// 11, 18, 27 and 45 degrees and one along (1,2,3); round holes of 5 and 10 mm
// radius; a sphere. Each shape is handed to the export's own surface step as the
// EXACT fill fraction of every voxel (what a perfect optimiser would hand over),
// at a 1.7 mm voxel, and the test measures how far the surface the file would
// carry sits from the true shape.
//
// Rule 9 asks for at most 0.05 mm. Two columns per shape:
//   today : the voxel-fill export (marching cubes on the fill fractions,
//           resampled), measured at its vertices (ledger C-1: about 0.2 mm).
//   new   : stage 3 -- the shape handed over as the OPTIMISER'S OWN FUNCTION
//           (the basis fitted to the true distance by the same least squares the
//           optimiser's re-fit runs) and its zero surface meshed directly
//           (level_surface.hpp). Measured at every vertex AND inside every
//           triangle, so the chord between vertices counts.
//   no argument : MEASURE; fails only on a broken run.
//   --gate      : also fails when a shape's NEW error is over 0.05 mm.
//   --matrix    : the stage 3 open choice: every basis x reach x knot spacing
//                 (slow; a heavy job).
//   --arm B:R:K : one arm (basis, reach in knot spacings, knot spacing in voxels).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "topopt/level_surface.hpp"
#include "topopt/mesh.hpp"
#include "topopt/plsm_basis.hpp"

using topopt::Vec3;

namespace {

constexpr double kVoxel = 1.7;      // mm
constexpr int kN = 36;              // voxels per axis (61.2 mm cube)
constexpr int kSub = 8;             // sub-samples per axis for the fill fraction
constexpr int kSmoothFactor = 2;    // the app's export setting
constexpr double kIso = 0.5;
constexpr double kGateMm = 0.05;
constexpr double kEdgeMarginMm = 4.0 * kVoxel;  // ignore the grid's own border

struct Shape {
  std::string name;
  // Signed distance to the true surface, negative inside the solid.
  std::function<double(const Vec3&)> sd;
};

Vec3 unit(double x, double y, double z) {
  const double n = std::sqrt(x * x + y * y + z * z);
  return {x / n, y / n, z / n};
}

Shape tilted_wall(const std::string& name, const Vec3& n) {
  const double c = 0.5 * kN * kVoxel;
  // Offset by an irrational fraction of a voxel so the wall is not grid-aligned.
  const double off = 0.37 * kVoxel;
  return {name, [n, c, off](const Vec3& p) {
            return (p.x - c) * n.x + (p.y - c) * n.y + (p.z - c) * n.z - off;
          }};
}

Shape round_hole(const std::string& name, double radius) {
  const double cx = 0.5 * kN * kVoxel + 0.29 * kVoxel;
  const double cy = 0.5 * kN * kVoxel - 0.41 * kVoxel;
  // A block with a hole along z: solid outside the cylinder.
  return {name, [cx, cy, radius](const Vec3& p) {
            return radius - std::hypot(p.x - cx, p.y - cy);
          }};
}

Shape sphere(const std::string& name, double radius) {
  const double c = 0.5 * kN * kVoxel;
  const Vec3 o{c + 0.23 * kVoxel, c - 0.31 * kVoxel, c + 0.11 * kVoxel};
  return {name, [o, radius](const Vec3& p) {
            return std::sqrt((p.x - o.x) * (p.x - o.x) + (p.y - o.y) * (p.y - o.y) +
                             (p.z - o.z) * (p.z - o.z)) -
                   radius;
          }};
}

std::vector<double> fill_fractions(const Shape& s) {
  std::vector<double> f(static_cast<std::size_t>(kN) * kN * kN, 0.0);
  const double h = kVoxel / kSub;
  const double reach = 0.9 * kVoxel;  // beyond this a voxel is all in or all out
  for (int k = 0; k < kN; ++k)
    for (int j = 0; j < kN; ++j)
      for (int i = 0; i < kN; ++i) {
        const Vec3 c{(i + 0.5) * kVoxel, (j + 0.5) * kVoxel, (k + 0.5) * kVoxel};
        const double d = s.sd(c);
        double v;
        if (d < -reach) {
          v = 1.0;
        } else if (d > reach) {
          v = 0.0;
        } else {
          int in = 0;
          for (int c3 = 0; c3 < kSub; ++c3)
            for (int b = 0; b < kSub; ++b)
              for (int a = 0; a < kSub; ++a) {
                const Vec3 p{i * kVoxel + (a + 0.5) * h, j * kVoxel + (b + 0.5) * h,
                             k * kVoxel + (c3 + 0.5) * h};
                if (s.sd(p) < 0.0) ++in;
              }
          v = static_cast<double>(in) / (kSub * kSub * kSub);
        }
        f[(static_cast<std::size_t>(k) * kN + j) * kN + i] = v;
      }
  return f;
}

struct Measured {
  double worst = 0.0;
  double rms = 0.0;
  std::size_t count = 0;
};

Measured measure_today(const Shape& s) {
  const std::vector<double> f = fill_fractions(s);
  const topopt::TriangleMesh m = topopt::marching_cubes_resampled(
      kN, kN, kN, kVoxel, Vec3{0, 0, 0}, f, kIso, kSmoothFactor,
      topopt::ResampleInterp::Tricubic);
  Measured r;
  const double lo = kEdgeMarginMm, hi = kN * kVoxel - kEdgeMarginMm;
  double sum2 = 0.0;
  for (const Vec3& v : m.vertices) {
    if (v.x < lo || v.x > hi || v.y < lo || v.y > hi || v.z < lo || v.z > hi) continue;
    const double d = std::fabs(s.sd(v));
    // A vertex on the grid's own closing wall, not on the shape under test.
    if (d > 2.0 * kVoxel) continue;
    r.worst = std::max(r.worst, d);
    sum2 += d * d;
    ++r.count;
  }
  if (r.count > 0) r.rms = std::sqrt(sum2 / static_cast<double>(r.count));
  return r;
}

struct Arm {
  topopt::PlsmBasisKind basis = topopt::PlsmBasisKind::BSpline3;
  double reach = 2.0;   // knot spacings (bspline: fixed at 2)
  double knot = 2.0;    // voxels
  std::string name() const {
    char b[96];
    std::snprintf(b, sizeof b, "%s r%.0f k%.1f", topopt::plsm_basis_name(basis), reach, knot);
    return b;
  }
};

// The shape as the optimiser would hold it: the basis fitted to the true signed
// distance at the voxel centres, clamped at 6 voxels, ridge 1e-6 -- the
// optimiser's own re-fit (plsm.cpp) -- then its zero surface meshed directly.
Measured measure_new(const Shape& s, const Arm& arm, double cell_mm) {
  using namespace topopt;
  const double sup = plsm_effective_support(arm.basis, arm.reach);
  const PlsmKnotLattice L = plsm_make_lattice(kN, kN, kN, arm.knot, arm.knot, arm.knot, sup);
  const PlsmCsr A = plsm_build_A(kN, kN, kN, L, arm.basis, 1);
  const PlsmCsr At = plsm_transpose(A, 1);
  const std::size_t n = static_cast<std::size_t>(kN) * kN * kN;
  std::vector<double> tgt(n), w(n, 1.0);
  for (int k = 0; k < kN; ++k)
    for (int j = 0; j < kN; ++j)
      for (int i = 0; i < kN; ++i) {
        const Vec3 c{(i + 0.5) * kVoxel, (j + 0.5) * kVoxel, (k + 0.5) * kVoxel};
        tgt[(static_cast<std::size_t>(k) * kN + j) * kN + i] =
            std::max(-6.0 * kVoxel, std::min(6.0 * kVoxel, s.sd(c)));
      }
  const PlsmFitResult fr = plsm_solve_normal(A, At, tgt, w, 1e-6, 4000, 1e-10, 1);
  PlsmFieldView fv;
  fv.lattice = &L;
  fv.basis = arm.basis;
  fv.alpha = &fr.alpha;
  fv.origin = Vec3{0, 0, 0};
  fv.h = kVoxel;
  const double top = kN * kVoxel;
  const TriangleMesh m = mesh_level_surface([&](const Vec3& p) { return fv.value(p); },
                                            Vec3{0, 0, 0}, Vec3{top, top, top}, cell_mm,
                                            1e-4);
  const SurfaceError e = surface_error(
      m, s.sd, Vec3{kEdgeMarginMm, kEdgeMarginMm, kEdgeMarginMm},
      Vec3{top - kEdgeMarginMm, top - kEdgeMarginMm, top - kEdgeMarginMm}, 2.0 * kVoxel);
  Measured r;
  r.worst = e.worst;
  r.rms = e.rms;
  r.count = static_cast<std::size_t>(e.points);
  return r;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  const double deg = std::acos(-1.0) / 180.0;
  std::vector<Shape> shapes;
  for (int a : {11, 18, 27, 45})
    shapes.push_back(tilted_wall("wall tilted " + std::to_string(a) + " deg",
                                 unit(std::sin(a * deg), 0.0, std::cos(a * deg))));
  shapes.push_back(tilted_wall("wall along (1,2,3)", unit(1, 2, 3)));
  shapes.push_back(round_hole("hole radius 5 mm", 5.0));
  shapes.push_back(round_hole("hole radius 10 mm", 10.0));
  shapes.push_back(sphere("sphere radius 12 mm", 12.0));

  // The arm that ships when the stage 3 switch is on (level_surface.hpp).
  Arm ship;
  {
    const topopt::SurfaceSwitch sw = topopt::to_surface_switch();
    if (sw.basis_set) ship.basis = sw.basis;
    if (sw.basis_set) ship.reach = sw.reach;
  }
  const double cell = 0.5 * kVoxel;  // the export's tessellation, smooth_factor 2
  bool matrix = false;
  std::vector<Arm> arms;
  for (int a = 1; a < argc; ++a) {
    if (std::strcmp(argv[a], "--matrix") == 0) matrix = true;
    if (std::strcmp(argv[a], "--arm") == 0 && a + 1 < argc) {
      char b[64] = {0};
      Arm x;
      double r = 0, k = 0;
      if (std::sscanf(argv[a + 1], "%63[^:]:%lf:%lf", b, &r, &k) == 3 &&
          topopt::plsm_parse_basis(b, x.basis)) {
        x.reach = r;
        x.knot = k;
        arms.push_back(x);
      }
    }
  }
  if (matrix) {
    using topopt::PlsmBasisKind;
    for (double k : {1.0, 1.5, 2.0}) {
      for (PlsmBasisKind b : {PlsmBasisKind::Gaussian, PlsmBasisKind::Wendland,
                              PlsmBasisKind::WendlandC4})
        for (double r : {2.0, 3.0, 4.0}) arms.push_back(Arm{b, r, k});
      arms.push_back(Arm{PlsmBasisKind::BSpline3, 2.0, k});
    }
  }
  if (!arms.empty()) {
    std::printf("[test A matrix] new path, worst / rms mm per shape, voxel %.1f mm, cell %.2f mm\n",
                kVoxel, cell);
    for (const Arm& arm : arms) {
      double worst = 0.0;
      std::string row;
      for (const Shape& s : shapes) {
        const Measured r = measure_new(s, arm, cell);
        worst = std::max(worst, r.worst);
        char b[48];
        std::snprintf(b, sizeof b, " %.3f/%.3f", r.worst, r.rms);
        row += b;
      }
      std::printf("%-24s worst %.4f |%s\n", arm.name().c_str(), worst, row.c_str());
      std::fflush(stdout);
    }
    return 0;
  }

  int failures = 0;
  std::printf("[test A] exported surface against the true shape, voxel %.1f mm; today = "
              "smooth_factor %d fill export; new = %s, cell %.2f mm\n",
              kVoxel, kSmoothFactor, ship.name().c_str(), cell);
  std::printf("%-24s %10s %10s %10s %10s %9s\n", "shape", "today", "today rms",
              "new", "new rms", "points");
  for (const Shape& s : shapes) {
    const Measured t = measure_today(s);
    const Measured r = measure_new(s, ship, cell);
    const bool broken = r.count < 100 || r.worst > kVoxel || t.count < 100;
    const bool over = r.worst > kGateMm;
    std::printf("%-24s %10.4f %10.4f %10.4f %10.4f %9zu %s\n", s.name.c_str(), t.worst, t.rms,
                r.worst, r.rms, r.count, broken ? "BROKEN" : (over ? "over 0.05" : "ok"));
    if (broken || (gate && over)) ++failures;
  }
  std::printf("[test A] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
