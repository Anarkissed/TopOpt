// TO rebuild, repo test A (docs/design/to-rebuild/04-tests.md).
//
// The exported surface of shapes whose true surface is known: flat walls tilted
// 11, 18, 27 and 45 degrees and one along (1,2,3); round holes of 5 and 10 mm
// radius; a sphere. Each shape is handed to the export's own surface step as the
// EXACT fill fraction of every voxel (what a perfect optimiser would hand over),
// at a 1.7 mm voxel, and the test measures how far the surface the file would
// carry sits from the true shape.
//
// Rule 9 asks for at most 0.05 mm. Today the export step alone misses that
// (ledger C-1: about 0.2 mm), so:
//   no argument : MEASURE. Prints the table, fails only on a broken run (no
//                 surface, or an error above one voxel). This is what ctest runs
//                 until stage 3.
//   --gate      : also fails when any shape is worse than 0.05 mm. Stage 3
//                 switches ctest to this.
//
// Pure C++/std; no OCCT, no Eigen.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"

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

Measured measure(const Shape& s) {
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

  int failures = 0;
  std::printf("[test A] exported surface against the true shape, voxel %.1f mm, "
              "smooth_factor %d\n",
              kVoxel, kSmoothFactor);
  std::printf("%-24s %10s %10s %9s\n", "shape", "worst mm", "rms mm", "points");
  for (const Shape& s : shapes) {
    const Measured r = measure(s);
    const bool broken = r.count < 100 || r.worst > kVoxel;
    const bool over = r.worst > kGateMm;
    std::printf("%-24s %10.4f %10.4f %9zu %s\n", s.name.c_str(), r.worst, r.rms,
                r.count, broken ? "BROKEN" : (over ? "over 0.05" : "ok"));
    if (broken || (gate && over)) ++failures;
  }
  std::printf("[test A] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
