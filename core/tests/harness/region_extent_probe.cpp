// region_extent_probe — WHY DOES A DEEPER SECTOR MEASURE THE SAME THICKNESS?
// (task 2026-08-15-lattice-regions.)
//
// Two hypotheses have now failed on the maintainer's part: the MINIMUM of the
// inscribed-sphere thickness, and its MEDIAN. Both returned 3.4106 mm — exactly
// two voxels — for sectors declared 3.0 / 4.5 / 6.0 / 7.5 mm, even though the
// sectors' voxel COUNTS rise 308 -> 781. Guessing a third statistic without
// looking would be the same mistake a third time.
//
// This prints, per sector: the mask's own bounding box, and the FULL tau
// distribution (min / p25 / median / p75 / p90 / max). If the mask is genuinely
// only two voxels thick at every depth, the statistic was never the problem and
// the SELECTION is.
#include "topopt/clearance.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/face_region.hpp"
#include "topopt/part.hpp"
#include "topopt/voxel.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>
using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: <part.step> <res> [face|-1=largest cylinder] [n] [m] [d0 d1 ...]\n");
    return 2;
  }
  const int want_face = argc > 3 ? std::atoi(argv[3]) : -1;
  const int NN = argc > 4 ? std::atoi(argv[4]) : 1;
  const int MM = argc > 5 ? std::atoi(argv[5]) : 4;
  StepModel model = import_part_file_resolved(argv[1]);
  const VoxelGrid grid = voxelize(model.mesh, std::atoi(argv[2]));
  const std::vector<double> areas = face_areas_mm2(model);
  int f4 = -1;
  if (want_face >= 0) {
    f4 = want_face;
  } else if (want_face == -2) {   // largest face of ANY kind
    f4 = 0;
    for (int f = 1; f < model.face_count; ++f)
      if (areas[(std::size_t)f] > areas[(std::size_t)f4]) f4 = f;
  } else {
    for (int f = 0; f < model.face_count; ++f)
      if (model.faces[(std::size_t)f].kind == StepSurfaceKind::Cylinder &&
          (f4 < 0 || areas[(std::size_t)f] > areas[(std::size_t)f4])) f4 = f;
  }
  FaceRegionSpec parent; parent.id = 100; parent.add = {f4};
  const ResolvedFaceRegion whole = resolve_face_regions(model, {parent})[0];
  const std::vector<GridSplitCell> cells =
      grid_split_cells(region_frame(model, whole), NN, MM);
  const int NC = NN * MM;
  std::vector<double> depths;
  for (int i = 0; i < NC; ++i)
    depths.push_back(argc > 6 + i ? std::atof(argv[6 + i]) : 3.0 + 1.5 * i);

  std::printf("part face %d (%.4g mm^2, %s)  spacing %.5f mm  split %dx%d\n", f4,
              areas[(std::size_t)f4],
              region_frame(model, whole).cylindrical ? "CYLINDRICAL" : "PCA",
              grid.spacing, NN, MM);
  std::printf("%-7s %-9s %-7s %-26s %s\n", "sector", "declared", "layers",
              "mask bbox (voxels, i x j x k)", "tau: min p25 med p75 p90 max (mm)");
  for (int s = 0; s < NC; ++s) {
    FaceRegionSpec sp; sp.id = 200 + s; sp.add = {f4};
    sp.cuts = cells[(std::size_t)s].cuts;
    const ResolvedFaceRegion r = resolve_face_regions(model, {sp})[0];
    const int layers = region_depth_layers(depths[(std::size_t)s], grid.spacing);
    const std::vector<int> vox =
        cut_voxels(grid, region_member_voxels(grid, model, r, layers), r.cuts);
    ClearanceVoxelMask m;
    m.nx = grid.nx; m.ny = grid.ny; m.nz = grid.nz;
    m.spacing = grid.spacing; m.origin = grid.origin;
    m.inside.assign(grid.voxel_count(), 0);
    int i0 = 1 << 30, i1 = -1, j0 = 1 << 30, j1 = -1, k0 = 1 << 30, k1 = -1;
    for (int idx : vox) {
      m.inside[(std::size_t)idx] = 1;
      const int i = idx % grid.nx, j = (idx / grid.nx) % grid.ny,
                k = idx / (grid.nx * grid.ny);
      i0 = std::min(i0, i); i1 = std::max(i1, i);
      j0 = std::min(j0, j); j1 = std::max(j1, j);
      k0 = std::min(k0, k); k1 = std::max(k1, k);
    }
    // The tau distribution over the mask, computed exactly as
    // region_thinnest_extent_mm does.
    VoxelGrid g; g.nx = m.nx; g.ny = m.ny; g.nz = m.nz;
    g.spacing = m.spacing; g.origin = m.origin;
    g.tags.assign(m.inside.size(), VoxelTag::Empty);
    std::vector<double> dens(m.inside.size(), 0.0);
    for (std::size_t i = 0; i < m.inside.size(); ++i)
      if (m.inside[i]) { g.tags[i] = VoxelTag::Interior; dens[i] = 1.0; }
    const std::vector<double> tau = local_member_thickness_mm(g, dens, 0.5, 64);
    std::vector<double> b;
    for (std::size_t i = 0; i < m.inside.size(); ++i)
      if (m.inside[i] && tau[i] > 0.0) b.push_back(tau[i]);
    std::sort(b.begin(), b.end());
    auto q = [&](double p) {
      return b.empty() ? 0.0 : b[(std::size_t)(p * (b.size() - 1))];
    };
    char bbox[40];
    std::snprintf(bbox, sizeof(bbox), "%dx%dx%d (%zu vox)", i1 - i0 + 1,
                  j1 - j0 + 1, k1 - k0 + 1, vox.size());
    std::printf("%-7d %-9.1f %-7d %-26s %.3f %.3f %.3f %.3f %.3f %.3f\n", s,
                depths[(std::size_t)s], layers, bbox, q(0.0), q(0.25), q(0.5), q(0.75),
                q(0.9), b.empty() ? 0.0 : b.back());
  }
  return 0;
}
