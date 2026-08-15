// sector_density_cost_probe — WHAT THE PER-REGION DENSITY OVERRIDE COSTS
// (task 2026-08-16-per-sector-density-override, bar R7).
//
//   ./build/sector_density_cost_probe <part.step> <resolution> <regions>
//
// ★ MEASURED DIRECTLY, NEVER DIFFERENCED FROM WALL-CLOCK. Differencing two runs
// of a multi-hour solve to price a millisecond mechanism gave +26 s/iteration
// for something that actually costs 0.0074 s — 3500x wrong — on this project
// once already. So each piece is timed in isolation, in the shape the run uses
// it, with a rep count that makes the timer's resolution irrelevant.
//
// THE THREE PIECES THIS TASK ADDS, and nothing else:
//
//   1. THE PER-VOXEL STATED-DENSITY FIELD. One point-in-region test per solid
//      voxel, first match wins — the same sweep `fit_cell_field` already does,
//      so the comparison is against that existing sweep, not against zero.
//   2. THE LAW'S EXTRA BRANCH. One pointer test and one compare per latticed
//      voxel inside grade_lattice's rho_of.
//   3. THE PRE-SOLVE REFUSAL. The `fit_region_cells` call hoisted ahead of the
//      solve so an unprintable density refuses in seconds rather than in hours.
//      Its cost is dominated by measuring each region's thickness.
//
// Piece 3 calls the IDENTICAL function the run calls — region_thinnest_extent_mm
// is public. Piece 1 rebuilds region_density_field'''s loop from the same public
// pieces (region_member_voxels → ClearanceVoxelMask → point_in_clearance_region)
// because that function lives in run_job'''s anonymous namespace; the loop is
// copied line for line and the predicate is the same call.

#include "topopt/clearance.hpp"
#include "topopt/face_region.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/observability.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/part.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: sector_density_cost_probe <part.step> <res> [regions]\n");
    return 2;
  }
  const int nregions = argc > 3 ? std::atoi(argv[3]) : 2;
  StepModel model = import_part_file_resolved(argv[1]);
  const VoxelGrid grid = voxelize(model.mesh, std::atoi(argv[2]));

  // `nregions` sectors of the part's largest face, one slab deep — the shape a
  // grid split produces and the shape the override is dialled on.
  const std::vector<double> areas = face_areas_mm2(model);
  int big = 0;
  for (int f = 1; f < model.face_count; ++f)
    if (areas[(std::size_t)f] > areas[(std::size_t)big]) big = f;

  std::vector<ClearanceGeometry> includes;
  for (int r = 0; r < nregions; ++r) {
    FaceRegionSpec spec;
    spec.id = r;
    spec.add = {big};
    const ResolvedFaceRegion rr = resolve_face_regions(model, {spec})[0];
    auto mk = std::make_shared<ClearanceVoxelMask>();
    mk->nx = grid.nx; mk->ny = grid.ny; mk->nz = grid.nz;
    mk->spacing = grid.spacing; mk->origin = grid.origin;
    mk->inside.assign(grid.voxel_count(), 0);
    // Depth 4 layers, and each sector takes a different half so the regions are
    // disjoint — the first-match sweep then does real work for every region.
    const std::vector<int> vox = region_member_voxels(grid, model, rr, 4);
    std::size_t n = 0;
    for (int idx : vox)
      if ((n++ % (std::size_t)nregions) == (std::size_t)r)
        mk->inside[(std::size_t)idx] = 1;
    ClearanceGeometry g;
    g.valid = true;
    g.mask = mk;
    includes.push_back(g);
  }

  std::size_t set_total = 0;
  for (const auto& g : includes) set_total += g.mask->set_count();
  std::printf("part        %s\n", argv[1]);
  std::printf("grid        %dx%dx%d  spacing %.5g mm  voxels %zu\n", grid.nx,
              grid.ny, grid.nz, grid.spacing, grid.voxel_count());
  std::printf("regions     %d, %zu voxels between them\n\n", nregions, set_total);

  // ── 1. THE PER-VOXEL STATED-DENSITY FIELD ────────────────────────────────
  // Exactly region_density_field's loop: for each solid voxel, first region
  // whose mask contains it wins. Timed against the SAME sweep with the density
  // lookup removed, which is what fit_cell_field already costs — so the number
  // reported is the MARGINAL cost of the override, not the cost of membership.
  const int reps = 20;
  auto sweep = [&](bool write_density) {
    std::vector<double> out(grid.voxel_count(), 0.0);
    long long hit = 0;
    const double t0 = steady_clock_ms();
    for (int rep = 0; rep < reps; ++rep)
      for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
          for (int i = 0; i < grid.nx; ++i) {
            if (!grid.solid(i, j, k)) continue;
            const Vec3 c = grid.voxel_center(i, j, k);
            for (std::size_t ri = 0; ri < includes.size(); ++ri)
              if (point_in_clearance_region(includes[ri], c, 0.0)) {
                if (write_density) {
                  out[grid.index(i, j, k)] = 0.25 + 0.05 * (double)ri;
                  ++hit;
                }
                break;
              }
          }
    return std::pair<double, long long>{(steady_clock_ms() - t0) / reps, hit};
  };
  const auto membership_only = sweep(false);
  const auto with_density = sweep(true);
  std::printf("=== 1. THE PER-VOXEL STATED-DENSITY FIELD, built ONCE per run ===\n");
  std::printf("membership sweep alone      %8.3f ms   (this already happens: "
              "fit_cell_field)\n", membership_only.first);
  std::printf("+ writing the density       %8.3f ms   (%lld voxels written)\n",
              with_density.first, with_density.second);
  std::printf("MARGINAL COST               %8.3f ms  <- what this task adds "
              "here\n\n", with_density.first - membership_only.first);

  // ── 2. THE LAW'S EXTRA BRANCH ────────────────────────────────────────────
  // One null test + one compare + one load, per latticed voxel, once per graded
  // variant. Timed over the whole grid at 200 reps because a single pass is far
  // below the clock's resolution — which is the point.
  {
    std::vector<double> field(grid.voxel_count(), 0.0);
    for (std::size_t i = 0; i < field.size(); i += 3) field[i] = 0.25;
    const std::vector<double>* p = &field;
    const int branch_reps = 200;
    volatile double sink = 0.0;
    const double t0 = steady_clock_ms();
    for (int rep = 0; rep < branch_reps; ++rep)
      for (std::size_t e = 0; e < field.size(); ++e)
        if (p != nullptr && (*p)[e] > 0.0) sink += (*p)[e];
    const double per_pass = (steady_clock_ms() - t0) / branch_reps;
    std::printf("=== 2. THE LAW'S EXTRA BRANCH, once per graded variant ===\n");
    std::printf("whole grid (%zu voxels)      %8.4f ms\n", field.size(), per_pass);
    std::printf("  (the branch is evaluated only for LATTICED voxels, so this is "
                "an upper bound)\n\n");
    (void)sink;
  }

  // ── 3. THE PRE-SOLVE REFUSAL ─────────────────────────────────────────────
  // The hoisted fit_region_cells call. Its cost is the per-region thickness
  // measurement — local_member_thickness_mm over a synthetic density that is 1
  // inside the region — plus arithmetic that does not register.
  {
    const double t0 = steady_clock_ms();
    double thinnest = 1e30;
    // ★ The REAL function, not a reimplementation of it — this is exactly what
    // fit_region_cells calls for a "region" kind.
    for (const auto& g : includes)
      thinnest = std::min(thinnest, region_thinnest_extent_mm(*g.mask));
    const double ms = steady_clock_ms() - t0;
    std::printf("=== 3. THE PRE-SOLVE REFUSAL, once per run ===\n");
    std::printf("fit_region_cells for %d regions  %8.2f ms  (thinnest median "
                "extent %.4f mm)\n", nregions, ms, thinnest);
    std::printf("  ★ This is a DUPLICATE of work the grading step already does, "
                "moved ahead of\n     the solve. It buys a refusal in seconds "
                "instead of after minimize_plastic.\n\n");
  }

  std::printf("HOW TO READ THIS: every number above is one-per-run or "
              "one-per-variant, against a\nsolve that takes minutes per rung. "
              "Nothing here is inside an iteration.\n");
  return 0;
}
