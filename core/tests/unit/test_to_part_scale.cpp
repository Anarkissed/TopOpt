// TO rebuild: too small for the nozzle, and the automatic resolution (part_scale.hpp).
#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/part_scale.hpp"

static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

namespace {
// A block of nx x ny x nz voxels that FILLS its grid (as an imported part does:
// the grid is the part's bounding box).
topopt::VoxelGrid block(int nx, int ny, int nz, double spacing) {
  topopt::VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = spacing;
  g.origin = topopt::Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, topopt::VoxelTag::Interior);
  return g;
}
}  // namespace

int main() {
  using namespace topopt;

  // The arithmetic. A 0.45 mm line needs 3 x 0.45 = 1.35 mm (two one-line walls
  // and a gap). Nozzles offered: 0.6, 0.4, 0.2 mm (line = 1.125 x nozzle).
  {
    const PartScale a = part_scale(2.0, 0.45);
    CHECK(!a.too_small && std::fabs(a.needed_mm - 1.35) < 1e-12);
    const PartScale b = part_scale(1.2, 0.45);  // a 0.2 mm nozzle needs 0.675 mm
    CHECK(b.too_small && b.nozzle_that_fits_mm == 0.2);
    const PartScale c = part_scale(1.3, 0.675); // a 0.6 nozzle's line: 0.4 fits (1.35? no: 1.3 < 1.35), so 0.2
    CHECK(c.too_small && c.nozzle_that_fits_mm == 0.2);
    const PartScale c2 = part_scale(1.5, 0.675); // needs 2.025; a 0.4 mm nozzle needs 1.35
    CHECK(c2.too_small && c2.nozzle_that_fits_mm == 0.4);
    const PartScale d = part_scale(0.5, 0.45);  // nothing fits: resin
    CHECK(d.too_small && d.nozzle_that_fits_mm == 0.0);
    const PartScale e = part_scale(1.0, 0.0);   // no line width given: 0.45
    CHECK(e.line_width_mm == 0.45 && e.too_small);
  }

  // The measure on a part that fills its own grid. A 1 mm thick plate (the fault
  // of 2026-11-26: with the outside of the grid taken as solid it read as thick
  // and was never flagged).
  {
    const VoxelGrid plate = block(40, 30, 4, 0.25);  // 10 x 7.5 x 1 mm
    const double t = thickest_section_mm(plate, 32);
    std::printf("plate 10 x 7.5 x 1 mm: thickest section %.3f mm\n", t);
    CHECK(std::isfinite(t) && t > 0.7 && t < 1.3);
    CHECK(part_scale(t, 0.45).too_small);
  }
  // A 5 mm cube: measured, and big enough.
  {
    const VoxelGrid cube = block(20, 20, 20, 0.25);
    const double t = thickest_section_mm(cube, 32);
    std::printf("cube 5 mm: thickest section %.3f mm\n", t);
    CHECK(std::isfinite(t) && t > 4.0 && t < 6.0);
    CHECK(!part_scale(t, 0.45).too_small);
  }
  // A cube thicker than the measure reaches reads as +infinity: never too small
  // (the other fault: those voxels were skipped, so it would have read as 0 mm).
  {
    const VoxelGrid big = block(24, 24, 24, 1.0);
    const double t = thickest_section_mm(big, 4);
    std::printf("cube 24 mm, reach 4 voxels: thickest section %g mm\n", t);
    CHECK(t > 8.0);
    CHECK(!part_scale(t, 0.45).too_small);
  }

  // Automatic resolution: one voxel per line width, capped and floored.
  {
    const AutoResolution a = auto_resolution(45.0, 0.45);   // 100 voxels
    CHECK(a.resolution == 100 && !a.capped && !a.floored && std::fabs(a.voxel_mm - 0.45) < 1e-12);
    const AutoResolution b = auto_resolution(200.0, 0.45);  // 445 -> the cap
    CHECK(b.resolution == 192 && b.capped && b.voxel_mm > 1.0);
    const AutoResolution c = auto_resolution(8.0, 0.45);    // 18 -> the floor
    CHECK(c.resolution == 32 && c.floored && std::fabs(c.voxel_mm - 0.25) < 1e-12);
    CHECK(auto_resolution(0.0, 0.45).resolution == 0);
  }

  std::printf(g_fail ? "FAILED (%d)\n" : "PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
