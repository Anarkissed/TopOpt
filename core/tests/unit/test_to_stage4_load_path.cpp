// TO rebuild stage 4: load_path_check (topopt/load_path.hpp) on made grids.
// Plain main, PASS / FAIL lines, non-zero on any failure.

#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "topopt/load_path.hpp"
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

// Anchor face at x = 0, load face at x = nx-1.
void tag_ends(VoxelGrid& g) {
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j) {
      g.set_tag(0, j, k, VoxelTag::Fixture);
      g.set_tag(g.nx - 1, j, k, VoxelTag::Load);
    }
}

std::string counts(const LoadPathCheck& c) {
  return " (connected " + std::to_string(c.connected) + ", groups " +
         std::to_string(c.load_groups) + ", unheld " + std::to_string(c.unheld_groups) +
         ", unheld voxels " + std::to_string(c.unheld_voxels) +
         ", unprinted loads " + std::to_string(c.unprinted_load_voxels) + ", link " +
         std::to_string(c.thinnest_link_voxels) + ")";
}

}  // namespace

int main() {
  const int NX = 24, NY = 12, NZ = 6;

  // (1) solid bar.
  {
    VoxelGrid g = make_grid(NX, NY, NZ);
    tag_ends(g);
    std::vector<double> d(g.voxel_count(), 1.0);
    const LoadPathCheck c = load_path_check(g, d);
    expect(c.connected && c.load_groups == 1 && c.unheld_groups == 0,
           "1 solid bar: connected, 1 load group" + counts(c));
  }

  // (2) a one-voxel slab of density 0.1 across the middle.
  {
    VoxelGrid g = make_grid(NX, NY, NZ);
    tag_ends(g);
    std::vector<double> d(g.voxel_count(), 1.0);
    for (int k = 0; k < NZ; ++k)
      for (int j = 0; j < NY; ++j) d[g.index(12, j, k)] = 0.1;
    const LoadPathCheck c = load_path_check(g, d);
    const std::size_t half = static_cast<std::size_t>(NX - 13) * NY * NZ;  // x = 13..23
    expect(!c.connected && c.load_groups == 1 && c.unheld_groups == 1 &&
               c.unheld_voxels == half,
           "2 slab cut: not connected, 1 unheld group, unheld voxels = " +
               std::to_string(half) + counts(c));
  }

  // (3) two arms from one anchored base, a load on each, arm B cut.
  {
    VoxelGrid g = make_grid(NX, NY, NZ);
    std::vector<double> d(g.voxel_count(), 1.0);
    for (int k = 0; k < NZ; ++k)
      for (int j = 0; j < NY; ++j) {
        g.set_tag(0, j, k, VoxelTag::Fixture);
        for (int i = 8; i < NX; ++i)
          if (j == 5 || j == 6) d[g.index(i, j, k)] = 0.0;  // the gap between the arms
        if (j != 5 && j != 6) g.set_tag(NX - 1, j, k, VoxelTag::Load);
        if (j >= 7) d[g.index(15, j, k)] = 0.1;  // arm B cut
      }
    const LoadPathCheck c = load_path_check(g, d);
    expect(!c.connected && c.load_groups == 2 && c.unheld_groups == 1,
           "3 two arms, one cut: 2 load groups, 1 unheld" + counts(c));
  }

  // (4) the two halves joined only along a voxel EDGE (diagonal contact).
  {
    VoxelGrid g = make_grid(NX, NY, NZ);
    tag_ends(g);
    std::vector<double> d(g.voxel_count(), 0.0);
    for (int k = 0; k < NZ; ++k)
      for (int j = 0; j < NY; ++j)
        for (int i = 0; i < NX; ++i)
          if ((i <= 11 && j <= 5) || (i >= 12 && j >= 6)) d[g.index(i, j, k)] = 1.0;
    // The end faces only where the halves are: a Load face over empty space would be
    // carved-away load voxels (unheld by the belt's rule), not what this case asks.
    for (int k = 0; k < NZ; ++k)
      for (int j = 0; j < NY; ++j) {
        if (j >= 6) g.set_tag(0, j, k, VoxelTag::Interior);
        if (j <= 5) g.set_tag(NX - 1, j, k, VoxelTag::Interior);
      }
    const LoadPathCheck c26 = load_path_check(g, d);
    const LoadPathCheck c18 = load_path_check(g, d, 0.5, false, 18);
    const LoadPathCheck c6 = load_path_check(g, d, 0.5, false, 6);
    expect(c26.connected, "4 edge contact, default 26 (the belt's rule): connected" + counts(c26));
    expect(c18.connected, "4 edge contact, 18: connected" + counts(c18));
    expect(!c6.connected && c6.unheld_groups == 1 &&
               c6.unheld_voxels == static_cast<std::size_t>(12 * 6 * NZ),
           "4 edge contact, 6 (faces only): not connected, 432 unheld" + counts(c6));
  }

  // (5) thinnest link: a neck two voxels long in the middle.
  {
    auto necked = [&](int lo_j, int hi_j, int lo_k, int hi_k) {
      VoxelGrid g = make_grid(NX, NY, NZ);
      tag_ends(g);
      std::vector<double> d(g.voxel_count(), 1.0);
      for (int k = 0; k < NZ; ++k)
        for (int j = 0; j < NY; ++j)
          for (int i = 11; i <= 12; ++i)
            if (j < lo_j || j > hi_j || k < lo_k || k > hi_k) d[g.index(i, j, k)] = 0.0;
      return load_path_check(g, d, 0.5, true);
    };
    const LoadPathCheck n1 = necked(5, 5, 2, 2);
    const LoadPathCheck n3 = necked(4, 6, 1, 3);
    const LoadPathCheck nf = necked(0, NY - 1, 0, NZ - 1);
    expect(n1.connected && n1.thinnest_link_voxels == 1, "5 neck 1 x 1: link 1" + counts(n1));
    expect(n3.connected && n3.thinnest_link_voxels == 2, "5 neck 3 x 3: link 2" + counts(n3));
    expect(nf.connected && nf.thinnest_link_voxels == 3, "5 full 6 x 12: link 3" + counts(nf));
  }

  // (6) timing: 128 x 128 x 64, random blobs at a fixed seed (no pass/fail on time).
  {
    const int X = 128, Y = 128, Z = 64;
    VoxelGrid g = make_grid(X, Y, Z);
    for (int j = 0; j < Y; ++j)
      for (int i = 0; i < X; ++i) {
        g.set_tag(i, j, 0, VoxelTag::Fixture);
        g.set_tag(i, j, Z - 1, VoxelTag::Load);
      }
    std::vector<double> d(g.voxel_count(), 0.0);
    std::mt19937 rng(12345u);
    for (int b = 0; b < 400; ++b) {
      const int cx = static_cast<int>(rng() % X), cy = static_cast<int>(rng() % Y),
                cz = static_cast<int>(rng() % Z), r = 3 + static_cast<int>(rng() % 8);
      for (int k = cz - r; k <= cz + r; ++k)
        for (int j = cy - r; j <= cy + r; ++j)
          for (int i = cx - r; i <= cx + r; ++i) {
            if (i < 0 || j < 0 || k < 0 || i >= X || j >= Y || k >= Z) continue;
            const int dx = i - cx, dy = j - cy, dz = k - cz;
            if (dx * dx + dy * dy + dz * dz <= r * r) d[g.index(i, j, k)] = 1.0;
          }
    }
    using clk = std::chrono::steady_clock;
    const auto t0 = clk::now();
    const LoadPathCheck a = load_path_check(g, d);
    const auto t1 = clk::now();
    const LoadPathCheck b = load_path_check(g, d, 0.5, true);
    const auto t2 = clk::now();
    const double ms_a = std::chrono::duration<double, std::milli>(t1 - t0).count();
    const double ms_b = std::chrono::duration<double, std::milli>(t2 - t1).count();
    std::printf("TIME  128x128x64 plain %.2f ms, with link %.2f ms%s | link run%s\n", ms_a,
                ms_b, counts(a).c_str(), counts(b).c_str());
  }

  std::printf("%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASSED", failures,
              failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}
