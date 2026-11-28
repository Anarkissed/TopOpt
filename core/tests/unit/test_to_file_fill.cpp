// TO rebuild stage 2: how full of a file each voxel is (file_fill.hpp).
#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/file_fill.hpp"

static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

namespace {
// A closed box from (x0, y0, z0) to (x1, y1, z1), outward winding.
topopt::TriangleMesh box(double x0, double y0, double z0, double x1, double y1, double z1) {
  topopt::TriangleMesh m;
  for (int k = 0; k < 2; ++k)
    for (int j = 0; j < 2; ++j)
      for (int i = 0; i < 2; ++i)
        m.vertices.push_back(topopt::Vec3{i ? x1 : x0, j ? y1 : y0, k ? z1 : z0});
  const int q[6][4] = {{0, 2, 3, 1}, {4, 5, 7, 6}, {0, 1, 5, 4},
                       {2, 6, 7, 3}, {0, 4, 6, 2}, {1, 3, 7, 5}};
  for (const auto& f : q) {
    m.triangles.push_back({f[0], f[1], f[2]});
    m.triangles.push_back({f[0], f[2], f[3]});
  }
  return m;
}
topopt::VoxelGrid grid(int n, double spacing) {
  topopt::VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = topopt::Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, topopt::VoxelTag::Empty);
  return g;
}
double total(const std::vector<double>& f) {
  double s = 0.0;
  for (double v : f) s += v;
  return s;
}
}  // namespace

int main() {
  using namespace topopt;
  const VoxelGrid g = grid(10, 1.0);

  // A box whose faces lie on voxel faces: every voxel is 0 or 1 and the volume is exact.
  {
    const std::vector<double> f = file_fill_fractions(box(2, 2, 2, 7, 6, 5), g, 4);
    CHECK(std::fabs(total(f) - 5.0 * 4.0 * 3.0) < 1e-9);
    for (double v : f) CHECK(v == 0.0 || v == 1.0);
  }
  // A box whose faces cut the voxels in half along x: the cut layers read 0.5, and
  // the volume is still the box's.
  {
    const std::vector<double> f = file_fill_fractions(box(2.5, 2, 2, 6.5, 6, 5), g, 4);
    CHECK(std::fabs(f[g.index(2, 3, 3)] - 0.5) < 1e-9);
    CHECK(std::fabs(f[g.index(6, 3, 3)] - 0.5) < 1e-9);
    CHECK(f[g.index(4, 3, 3)] == 1.0 && f[g.index(1, 3, 3)] == 0.0);
    CHECK(std::fabs(total(f) - 4.0 * 4.0 * 3.0) < 1e-9);
  }
  // A box off the sub-grid too (faces at thirds): the volume is held to the
  // sub-grid's own step, and no voxel reads over 1.
  {
    const TriangleMesh b = box(2.3, 2.1, 1.9, 7.4, 6.6, 5.2);
    const double truth = 5.1 * 4.5 * 3.3;
    const double v4 = total(file_fill_fractions(b, g, 4)), v8 = total(file_fill_fractions(b, g, 8));
    std::printf("[file fill] box 5.1 x 4.5 x 3.3 mm: volume %.2f true, %.2f at 4 per voxel, %.2f at 8; "
                "all-or-nothing %.2f\n", truth, v4, v8, total(file_fill_fractions(b, g, 1)));
    CHECK(std::fabs(v4 / truth - 1.0) < 0.06 && std::fabs(v8 / truth - 1.0) < 0.03);
    for (double v : file_fill_fractions(b, g, 4)) CHECK(v >= 0.0 && v <= 1.0 + 1e-12);
  }
  // sub = 1 is today's occupancy: the voxeliser's own answer.
  {
    const TriangleMesh b = box(2.3, 2.1, 1.9, 7.4, 6.6, 5.2);
    const VoxelGrid occ = voxelize_onto_grid(b, g);
    const std::vector<double> f = file_fill_fractions(b, g, 1);
    bool same = true;
    for (std::size_t i = 0; i < f.size(); ++i)
      same = same && ((occ.tags[i] != VoxelTag::Empty) == (f[i] == 1.0));
    CHECK(same);
  }

  std::printf(g_fail ? "FAILED (%d)\n" : "PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
