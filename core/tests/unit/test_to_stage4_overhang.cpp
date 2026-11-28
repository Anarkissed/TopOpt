// TO rebuild stage 4b: overhang_measure and overhang_filter (topopt/overhang_rule.hpp)
// on made 24^3 grids (1 mm voxels), each count compared with today's
// support_overhang_voxels (orient.cpp). Plain main, PASS / FAIL, non-zero on failure.

#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <string>
#include <vector>

#include "topopt/orient.hpp"
#include "topopt/overhang_rule.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

int failures = 0;

void expect(bool ok, const std::string& what) {
  std::printf("%s  %s\n", ok ? "PASS" : "FAIL", what.c_str());
  if (!ok) ++failures;
}

VoxelGrid make_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

using Shape = std::function<bool(int, int, int)>;

std::vector<double> fill(const VoxelGrid& g, const Shape& s) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (s(i, j, k)) d[g.index(i, j, k)] = 1.0;
  return d;
}

// Today's count on the printed design, as analyze.cpp feeds it.
int today(const VoxelGrid& g, const std::vector<double>& d, bool up) {
  VoxelGrid p = g;
  for (std::size_t idx = 0; idx < p.tags.size(); ++idx)
    if (!(d[idx] > 0.5)) p.tags[idx] = VoxelTag::Empty;
  return support_overhang_voxels(p, Vec3{0.0, 0.0, up ? 1.0 : -1.0});
}

std::string line(const OverhangMeasure& m, int t) {
  return " (ours " + std::to_string(m.unsupported_voxels) + ", area " +
         std::to_string(m.unsupported_area_mm2) + " mm2, largest patch " +
         std::to_string(m.largest_patch_mm2) + " mm2; today " + std::to_string(t) + ")";
}

std::size_t printed_count(const std::vector<double>& d, const Shape& where, const VoxelGrid& g) {
  std::size_t n = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (where(i, j, k) && d[g.index(i, j, k)] > 0.5) ++n;
  return n;
}

double max_diff(const std::vector<double>& a, const std::vector<double>& b) {
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}

}  // namespace

int main() {
  const int N = 24;
  const VoxelGrid g = make_grid(N, N, N);

  // Shapes. Block: 12 x 12 x 10 on the plate.
  const Shape block = [](int i, int j, int k) { return i >= 6 && i < 18 && j >= 6 && j < 18 && k < 10; };
  // T: a 4 x 4 column (x, y 10..13, z 0..11) under a 16 x 16 slab two layers thick
  // (x, y 4..19, z 12..13), 6 voxels wider than the column on each side.
  const Shape column = [](int i, int j, int k) { return i >= 10 && i <= 13 && j >= 10 && j <= 13 && k <= 11; };
  const Shape slab = [](int i, int j, int k) { return i >= 4 && i <= 19 && j >= 4 && j <= 19 && (k == 12 || k == 13); };
  const Shape tee = [&](int i, int j, int k) { return column(i, j, k) || slab(i, j, k); };
  const Shape tee_flipped = [&](int i, int j, int k) { return tee(i, j, N - 1 - k); };
  // Staircases: 6 x 6 layers, shifted one (c) or two (d) voxels in x per layer.
  const Shape stair1 = [](int i, int j, int k) { return k <= 17 && i >= k && i <= k + 5 && j >= 9 && j <= 14; };
  const Shape stair2 = [](int i, int j, int k) { return k <= 9 && i >= 2 * k && i <= 2 * k + 5 && j >= 9 && j <= 14; };

  const std::vector<double> dA = fill(g, block), dT = fill(g, tee), dF = fill(g, tee_flipped),
                            dC = fill(g, stair1), dD = fill(g, stair2);

  // (a) solid block on the plate.
  {
    const OverhangMeasure m = overhang_measure(g, dA, true);
    const int t = today(g, dA, true);
    expect(m.unsupported_voxels == 0 && t == 0, "a block on the plate: 0 unsupported" + line(m, t));
  }
  // (b) T. Today's rule supports a voxel from the one below and that one's four face
  // neighbours (45 degrees exactly; the corners are 54.7). Slab underside z = 12:
  // 16 x 16 = 256 voxels; supported = the column's 4 x 4 footprint grown by one in
  // the four face directions = 16 + 4 x 4 = 32; unsupported 256 - 32 = 224. The upper
  // slab layer sits on the lower one: 0. The column's base is the plate: 0. Total
  // 224, one ring-shaped patch of 224 mm2.
  {
    const OverhangMeasure m = overhang_measure(g, dT, true);
    const int t = today(g, dT, true);
    expect(m.unsupported_voxels == 224 && t == 224 && m.largest_patch_mm2 == 224.0,
           "b T: 224 unsupported, one patch of 224 mm2" + line(m, t));
  }
  // (c) 45-degree staircase: each layer's leading voxel has the previous layer's
  // leading voxel one step back as a face neighbour below.
  {
    const OverhangMeasure m = overhang_measure(g, dC, true);
    const int t = today(g, dC, true);
    expect(m.unsupported_voxels == 0 && t == 0, "c staircase by 1: 0 unsupported" + line(m, t));
  }
  // (d) Staircase by 2: in each of layers 1..9 the leading column x = 2k+5 has the
  // nearest voxel below at x = 2k+3, two away: unsupported; x = 2k+4 is held by
  // x = 2k+3. So 6 voxels (the y width) in each of 9 layers = 54; patches of 6.
  {
    const OverhangMeasure m = overhang_measure(g, dD, true);
    const int t = today(g, dD, true);
    expect(m.unsupported_voxels == 54 && t == 54 && m.largest_patch_mm2 == 6.0,
           "d staircase by 2: 54 unsupported, patches of 6 mm2" + line(m, t));
  }
  // (e) the filter on the T: the slab keeps only what grows from the column one
  // face step per layer: z = 12 keeps 32 (as above), z = 13 keeps the footprint
  // grown by two in the face (L1) sense = 16 + 32 + 4 = 52; 84 in all. The column
  // passes unchanged, and the filtered field measures 0 unsupported.
  {
    const std::vector<double> f = overhang_filter(g, dT, true);
    const OverhangMeasure m = overhang_measure(g, f, true);
    const std::size_t slab_kept = printed_count(f, slab, g);
    double col = 0.0;
    for (int k = 0; k < N; ++k)
      for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i)
          if (column(i, j, k)) col = std::max(col, std::fabs(f[g.index(i, j, k)] - 1.0));
    expect(m.unsupported_voxels == 0 && slab_kept == 84 && col < 1e-12,
           "e filter on T: 0 unsupported after, slab kept " + std::to_string(slab_kept) +
               " (expect 84), column change " + std::to_string(col) + line(m, today(g, f, true)));
  }
  // (f) the filter leaves self-supporting shapes alone.
  {
    const double ea = max_diff(overhang_filter(g, dA, true), dA);
    const double ec = max_diff(overhang_filter(g, dC, true), dC);
    expect(ea < 1e-6 && ec < 1e-6, "f filter on block and staircase: unchanged (max change " +
                                       std::to_string(ea) + ", " + std::to_string(ec) + ")");
  }
  // (g) build_up = false flips everything.
  {
    const OverhangMeasure t_down = overhang_measure(g, dT, false);
    const OverhangMeasure f_up = overhang_measure(g, dF, true);
    const OverhangMeasure f_down = overhang_measure(g, dF, false);
    expect(t_down.unsupported_voxels == 0 && today(g, dT, false) == 0,
           "g T built downward (slab on the plate): 0" + line(t_down, today(g, dT, false)));
    expect(f_up.unsupported_voxels == 0, "g flipped T built upward: 0" + line(f_up, today(g, dF, true)));
    expect(f_down.unsupported_voxels == 224 && today(g, dF, false) == 224,
           "g flipped T built downward (hanging): 224" + line(f_down, today(g, dF, false)));
    const std::vector<double> ff = overhang_filter(g, dF, false);
    expect(overhang_measure(g, ff, false).unsupported_voxels == 0 &&
               printed_count(ff, [&](int i, int j, int k) { return slab(i, j, N - 1 - k); }, g) == 84,
           "g filter on flipped T downward: 0 unsupported, slab kept 84");
    const OverhangMeasure sideways = overhang_measure(g, dT, Vec3{1.0, 0.0, 0.0});
    expect(!sideways.direction_supported && overhang_filter(g, dT, Vec3{0.0, 1.0, 0.0}).empty(),
           "g build along x or y: not supported");
  }
  // (h) timing on 128 x 128 x 64, random blobs at a fixed seed (printed only).
  {
    const VoxelGrid G = make_grid(128, 128, 64);
    std::vector<double> d(G.voxel_count(), 0.0);
    std::mt19937 rng(12345u);
    for (int b = 0; b < 400; ++b) {
      const int cx = static_cast<int>(rng() % 128), cy = static_cast<int>(rng() % 128),
                cz = static_cast<int>(rng() % 64), r = 3 + static_cast<int>(rng() % 8);
      for (int k = cz - r; k <= cz + r; ++k)
        for (int j = cy - r; j <= cy + r; ++j)
          for (int i = cx - r; i <= cx + r; ++i) {
            if (i < 0 || j < 0 || k < 0 || i >= 128 || j >= 128 || k >= 64) continue;
            const int dx = i - cx, dy = j - cy, dz = k - cz;
            if (dx * dx + dy * dy + dz * dz <= r * r) d[G.index(i, j, k)] = 1.0;
          }
    }
    using clk = std::chrono::steady_clock;
    const auto t0 = clk::now();
    const OverhangMeasure m = overhang_measure(G, d, true);
    const auto t1 = clk::now();
    const std::vector<double> f = overhang_filter(G, d, true);
    const auto t2 = clk::now();
    const int t = today(G, d, true);
    std::printf("TIME  128x128x64 measure %.2f ms, filter %.2f ms%s\n",
                std::chrono::duration<double, std::milli>(t1 - t0).count(),
                std::chrono::duration<double, std::milli>(t2 - t1).count(), line(m, t).c_str());
    expect(m.unsupported_voxels == static_cast<std::size_t>(t), "h blobs: ours equals today's");
    (void)f;
  }

  std::printf("%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASSED", failures,
              failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}
