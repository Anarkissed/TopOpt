// C2 B0, item 1 of the Flexible core list (2026-10-24): SEAM HOLES ("rods") along a
// diagonal two triangles share.
//
// The column test used to be "boundary-inclusive" on each triangle's OWN edge functions.
// A column centre lying on the diagonal that two triangles of one face share was judged by
// two independently rounded expressions of the same line, so it could come out a hair
// outside BOTH triangles. That face then added no crossing, and the winding fill read the
// whole column as Empty: his pad at Balanced had 6 such columns on x = y (114 voxels), each
// one empty through every layer.
//
// VoxelTies::Watertight (the reviewer's ruling of 2026-10-24, option C: a MODE, used by
// the Flexible stage; every other stage keeps VoxelTies::Legacy byte-identical). Every edge
// function is evaluated from a CANONICAL vertex order, so the two triangles that share an
// edge compute exactly negated values, and a top-left tie rule gives a centre lying exactly
// on the edge to exactly one of them.
//
// The test sweeps boxes (top and bottom split along a diagonal, as his pad's are) with
// origins and sizes that are not round numbers, over many resolutions. It checks that every
// column whose centre is inside the footprint is solid through the box's height. Before the
// fix, the sweep finds empty columns. A box at round coordinates (the existing goldens'
// case) must voxelize the same as before.

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

// A box [x0, x0+sx] × [y0, y0+sy] × [z0, z0+sz], outward-wound, top and bottom each split
// into two triangles along the diagonal (anti = false: from (x0, y0) to the far corner;
// true: the other diagonal).
static TriangleMesh box(double x0, double y0, double z0, double sx, double sy, double sz, bool anti) {
  TriangleMesh m;
  const double x1 = x0 + sx, y1 = y0 + sy, z1 = z0 + sz;
  m.vertices = {{x0, y0, z0}, {x1, y0, z0}, {x1, y1, z0}, {x0, y1, z0},
                {x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}};
  if (!anti) {
    m.triangles = {{0, 2, 1}, {0, 3, 2},   // bottom (-Z), split 0-2
                   {4, 5, 6}, {4, 6, 7}};  // top (+Z), split 4-6
  } else {
    m.triangles = {{0, 3, 1}, {1, 3, 2},   // bottom, split 1-3
                   {4, 5, 7}, {5, 6, 7}};  // top, split 5-7
  }
  const std::vector<std::array<int, 3>> sides = {{0, 1, 5}, {0, 5, 4}, {1, 2, 6}, {1, 6, 5},
                                                 {2, 3, 7}, {2, 7, 6}, {3, 0, 4}, {3, 4, 7}};
  for (const auto& t : sides) m.triangles.push_back(t);
  return m;
}

// Columns whose centre is inside the footprint (by more than `margin`) but which are not
// solid through every layer whose centre lies inside the box's height.
static int holed_columns(const TriangleMesh& m, int res, double x0, double y0, double z0, double sx,
                         double sy, double sz, int* first_i = nullptr, int* first_j = nullptr,
                         VoxelTies ties = VoxelTies::Watertight) {
  const VoxelGrid g = voxelize(m, res, ties);
  int holed = 0;
  const double margin = 1e-9 * std::max(sx, sy);
  for (int j = 0; j < g.ny; ++j)
    for (int i = 0; i < g.nx; ++i) {
      const Vec3 c = g.voxel_center(i, j, 0);
      if (!(c.x > x0 + margin && c.x < x0 + sx - margin && c.y > y0 + margin && c.y < y0 + sy - margin))
        continue;
      bool full = true;
      for (int k = 0; k < g.nz; ++k) {
        const double cz = g.voxel_center(i, j, k).z;
        if (!(cz > z0 + margin && cz < z0 + sz - margin)) continue;
        if (g.tags[g.index(i, j, k)] == VoxelTag::Empty) full = false;
      }
      if (!full) {
        if (holed == 0 && first_i != nullptr) {
          *first_i = i;
          *first_j = j;
        }
        ++holed;
      }
    }
  return holed;
}

int main() {
  // (1) THE SWEEP: offsets and sizes that are not round, so the shared diagonal's two
  // expressions round differently. Square footprints, so the diagonal passes through column
  // centres (i, i), as on his pad.
  const double offsets[] = {0.1, 1.0 / 3.0, 7.77, -12.345, 1e3 / 7.0, -0.0123456789};
  const double sizes[] = {100.0, 100.0000001, 99.9999999, 20.0 + 1.0 / 3.0, 63.7};
  int total_holed = 0, legacy_holed = 0, cases = 0;
  std::string where;
  for (double o : offsets)
    for (double s : sizes)
      for (bool anti : {false, true})
        for (int res = 20; res <= 160; res += 7) {
          const double sz = 0.2 * s;
          const TriangleMesh m = box(o, o, -o, s, s, sz, anti);
          int fi = -1, fj = -1;
          const int h = holed_columns(m, res, o, o, -o, s, s, sz, &fi, &fj);
          ++cases;
          if (h > 0 && where.empty()) {
            char b[200];
            std::snprintf(b, sizeof(b), "origin %.10g size %.10g %s res %d: first column (%d, %d)", o, s,
                          anti ? "anti" : "diag", res, fi, fj);
            where = b;
          }
          total_holed += h;
          legacy_holed += holed_columns(m, res, o, o, -o, s, s, sz, nullptr, nullptr, VoxelTies::Legacy);
        }
  std::printf("  sweep: %d boxes, %d holed columns (Legacy: %d)%s%s\n", cases, total_holed, legacy_holed,
              where.empty() ? "" : "; ", where.c_str());
  CHECK(total_holed == 0, "item 1: no column inside the footprint is holed, over the whole sweep");
  CHECK(legacy_holed > 0, "item 1: the CONTROL: Legacy holes the same sweep (the bug the mode fixes)");

  // (2) ROUND COORDINATES (the goldens' case): the shared diagonal's edge function is EXACTLY
  // 0 on the centres (i, i). Exactly one triangle claims each such centre, and the result is
  // a full box, as before.
  {
    const TriangleMesh m = box(0, 0, 0, 100, 100, 20, false);
    CHECK(holed_columns(m, 50, 0, 0, 0, 100, 100, 20) == 0, "item 1: a round box at res 50 is full");
    const VoxelGrid g = voxelize(m, 50, VoxelTies::Watertight);
    long long solid = 0;
    for (VoxelTag t : g.tags) solid += t != VoxelTag::Empty;
    CHECK(solid == 50LL * 50 * 10, "item 1: the round box has exactly 50 x 50 x 10 solid voxels");
  }

  // (3) NOTHING OUTSIDE: a centre exactly on the footprint's own BOUNDARY edge (one triangle,
  // no neighbour in the projection) is claimed by that triangle under the top-left rule, or by
  // nobody. Either way, no voxel outside the box becomes solid.
  {
    // Two unused vertices widen the bbox to [-1.5, 101.5]: at res 103 the voxel is 1 mm and
    // the centres are the integers -1 … 101, so centres lie exactly ON the box's boundary
    // (x, y = 0 and 100) and one voxel past it.
    TriangleMesh m = box(0, 0, 0, 100, 100, 20, false);
    m.vertices.push_back({-1.5, -1.5, -1.5});
    m.vertices.push_back({101.5, 101.5, 21.5});
    const VoxelGrid g = voxelize(m, 103, VoxelTies::Watertight);
    long long outside = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const Vec3 c = g.voxel_center(i, j, k);
          const bool in = c.x >= 0 && c.x <= 100 && c.y >= 0 && c.y <= 100 && c.z >= 0 && c.z <= 20;
          if (!in && g.tags[g.index(i, j, k)] != VoxelTag::Empty) ++outside;
        }
    CHECK(outside == 0, "item 1: no voxel outside the box is solid when centres lie on its boundary");
  }

  // (4) NO FMA CONTRACTION in the tie rule's edge function. At p = t the value is a·b − b·a,
  // which is exactly 0 only when both products are rounded. The library's function must
  // return 0 there for every edge. The positive control computes the same expression
  // CONTRACTED (std::fma, what a fused multiply-add compiles to) and must find nonzero
  // values, so the check can see a contraction.
  {
    unsigned long long x = 0x9E3779B97F4A7C15ULL;
    auto rnd = [&]() {
      x ^= x << 13;
      x ^= x >> 7;
      x ^= x << 17;
      return (static_cast<double>(x >> 11) / 9007199254740992.0 - 0.5) * 200.0;
    };
    int lib_nonzero = 0, fused_nonzero = 0;
    for (int n = 0; n < 20000; ++n) {
      const Vec3 s{rnd(), rnd(), 0}, t{rnd(), rnd(), 0};
      if (voxel_tie_edge_function(s, t, t.x, t.y) != 0.0) ++lib_nonzero;
      if (voxel_tie_edge_function(s, t, s.x, s.y) != 0.0) ++lib_nonzero;
      const double a = t.x - s.x, b = t.y - s.y;
      if (std::fma(a, b, -(b * a)) != 0.0) ++fused_nonzero;
    }
    std::printf("  edge function at its own vertices: %d nonzero (a contracted copy: %d of 20000)\n", lib_nonzero,
                fused_nonzero);
    CHECK(lib_nonzero == 0, "item 1: the tie rule's edge function is exactly 0 at both of its vertices");
    CHECK(fused_nonzero > 0, "item 1: the CONTROL: a contracted copy is not (the check can see FMA)");
  }

  std::printf("test_voxelize_ties: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
