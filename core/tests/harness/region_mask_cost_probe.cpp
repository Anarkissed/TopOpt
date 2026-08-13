// region_mask_cost_probe — WHAT THE MASK-BACKED PREDICATE COSTS
// (task 2026-08-15-lattice-regions §3, bar R6).
//
//   ./build/region_mask_cost_probe <part.step> <resolution>
//
// §3(a) predicted the mask MIGHT be faster: a ClearanceGeometry test is
// arithmetic per point, a mask lookup is an array index. This measures it
// rather than assuming either way, in the shape the three call sites use:
//
//   1. FIT-CELL FIELD          one point-in-region per solid voxel, first match
//   2. MULTISCALE REGION MASK  the same sweep through LatticeBoundary
//   3. CELL ACTIVATION         cell_may_overlap per lattice cell
//
// Both arms cover the SAME volume — the analytic slab is fitted to the region's
// own bounding box — so the comparison is per-call cost and not per-region-size.

#include "topopt/clearance.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/face_region.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/observability.hpp"
#include "topopt/part.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: region_mask_cost_probe <part.step> <res>\n");
    return 2;
  }
  StepModel model = import_part_file_resolved(argv[1]);
  const VoxelGrid grid = voxelize(model.mesh, std::atoi(argv[2]));

  // The region: the part's largest face, one voxel deep — a realistic sector.
  const std::vector<double> areas = face_areas_mm2(model);
  int big = 0;
  for (int f = 1; f < model.face_count; ++f)
    if (areas[(std::size_t)f] > areas[(std::size_t)big]) big = f;
  FaceRegionSpec spec;
  spec.id = 0;
  spec.add = {big};
  const ResolvedFaceRegion r = resolve_face_regions(model, {spec})[0];

  auto mk = std::make_shared<ClearanceVoxelMask>();
  mk->nx = grid.nx; mk->ny = grid.ny; mk->nz = grid.nz;
  mk->spacing = grid.spacing; mk->origin = grid.origin;
  mk->inside.assign(grid.voxel_count(), 0);
  for (int idx : region_member_voxels(grid, model, r, 1))
    mk->inside[(std::size_t)idx] = 1;

  ClearanceGeometry gm;  // the MASK arm
  gm.valid = true;
  gm.mask = mk;

  // The ANALYTIC arm: a slab over the region's own bounding box, so both arms
  // answer about the same volume and the timing is per-call, not per-size.
  Vec3 lo{1e30, 1e30, 1e30}, hi{-1e30, -1e30, -1e30};
  for (std::size_t i = 0; i < mk->inside.size(); ++i) {
    if (!mk->inside[i]) continue;
    const int ii = (int)(i % grid.nx), jj = (int)((i / grid.nx) % grid.ny),
              kk = (int)(i / ((std::size_t)grid.nx * grid.ny));
    const Vec3 c = grid.voxel_center(ii, jj, kk);
    lo = Vec3{std::min(lo.x, c.x), std::min(lo.y, c.y), std::min(lo.z, c.z)};
    hi = Vec3{std::max(hi.x, c.x), std::max(hi.y, c.y), std::max(hi.z, c.z)};
  }
  ManualClearanceGeometry mg;
  ClearanceParams p;
  mg.kind = ClearanceKind::Face;
  p.kind = ClearanceKind::Face;
  p.slab_depth_mm = std::max(1e-3, hi.z - lo.z);
  mg.origin = lo;
  mg.normal = Vec3{0, 0, 1};
  mg.half_u_mm = std::max(1e-3, 0.5 * (hi.x - lo.x));
  mg.half_w_mm = std::max(1e-3, 0.5 * (hi.y - lo.y));
  const ClearanceGeometry ga = resolve_clearance_manual(mg, p);

  std::printf("part        %s\n", argv[1]);
  std::printf("grid        %dx%dx%d  spacing %.5g mm  voxels %zu\n", grid.nx,
              grid.ny, grid.nz, grid.spacing, grid.voxel_count());
  std::printf("region      face %d, %zu voxels one layer deep\n", big,
              mk->set_count());
  std::printf("mask memory %zu bytes (1 byte/voxel) = %.1f KB; ten of them "
              "%.1f MB\n\n",
              mk->inside.size(), mk->inside.size() / 1024.0,
              10.0 * mk->inside.size() / (1024.0 * 1024.0));

  auto sweep = [&](const ClearanceGeometry& g, int reps) {
    long long hits = 0;
    const double t0 = steady_clock_ms();
    for (int rep = 0; rep < reps; ++rep)
      for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
          for (int i = 0; i < grid.nx; ++i) {
            if (!grid.solid(i, j, k)) continue;
            if (point_in_clearance_region(g, grid.voxel_center(i, j, k), 0.0))
              ++hits;
          }
    return std::pair<double, long long>{(steady_clock_ms() - t0) / reps, hits};
  };

  const int reps = 5;
  const auto A = sweep(ga, reps);
  const auto M = sweep(gm, reps);
  std::printf("=== 1+2. POINT MEMBERSHIP over every solid voxel (the fit-cell "
              "field and multiscale sweeps) ===\n");
  std::printf("analytic slab   %8.2f ms/sweep   (%lld inside)\n", A.first, A.second);
  std::printf("voxel mask      %8.2f ms/sweep   (%lld inside)\n", M.first, M.second);
  std::printf("mask / analytic %8.3f x  -> the mask is %s\n\n",
              M.first / std::max(A.first, 1e-9),
              M.first < A.first ? "FASTER" : "SLOWER");

  // 3. CELL ACTIVATION through LatticeBoundary, at a realistic cell.
  auto cells = [&](const ClearanceGeometry& g) {
    LatticeBoundary b;
    b.add_include_region(g);
    const double cell = 8.0 * grid.spacing;
    long long active = 0;
    const double t0 = steady_clock_ms();
    for (double z = grid.origin.z; z < grid.origin.z + grid.nz * grid.spacing; z += cell)
      for (double y = grid.origin.y; y < grid.origin.y + grid.ny * grid.spacing; y += cell)
        for (double x = grid.origin.x; x < grid.origin.x + grid.nx * grid.spacing; x += cell)
          if (b.cell_may_overlap(Vec3{x, y, z}, cell)) ++active;
    return std::pair<double, long long>{steady_clock_ms() - t0, active};
  };
  const auto CA = cells(ga);
  const auto CM = cells(gm);
  std::printf("=== 3. CELL ACTIVATION (cell_may_overlap, cell = 8 voxels) ===\n");
  std::printf("analytic slab   %8.2f ms   (%lld cells active)\n", CA.first, CA.second);
  std::printf("voxel mask      %8.2f ms   (%lld cells active)\n", CM.first, CM.second);
  std::printf("mask / analytic %8.3f x  -> the mask is %s\n",
              CM.first / std::max(CA.first, 1e-9),
              CM.first < CA.first ? "FASTER" : "SLOWER");
  return 0;
}
