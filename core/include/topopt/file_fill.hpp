// file_fill.hpp -- how full of a file each voxel is (TO rebuild stage 2, "one
// judge", ledger R-08).
//
// The file re-check voxelises the finished file and gives every voxel whose
// centre is inside it density 1: an all-or-nothing model. Tests E measured what
// that costs on a textbook plate (the stress read 10 to 27 % low) and today's
// runs showed the two judges of one version up to 2.3 times apart on the lightest
// versions. To judge the file by the same form as the loop's certificate, the
// re-check needs what the loop has: each voxel's FILL, the share of the voxel
// inside the surface.
//
// Here that share is counted on a grid `sub` times finer laid over the same
// voxels (the same origin, spacing / sub), by the same +Z winding rule the
// voxeliser uses, so a voxel wholly inside reads 1 and one wholly outside 0, and
// with sub = 1 the result is exactly today's all-or-nothing occupancy.
//
// Cost: the fine grid is never held whole. It is voxelised one layer of voxels at
// a time (a slab nx*sub by ny*sub by sub), so the memory is nx * ny * sub^3 bytes
// whatever the part's height (192 x 192 voxels at sub 8: 19 MB), and the time is
// one voxelisation of the file per layer.
#pragma once

#include <stdexcept>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

inline std::vector<double> file_fill_fractions(const TriangleMesh& file, const VoxelGrid& grid,
                                               int sub = 4) {
  if (sub < 1) throw std::invalid_argument("file_fill_fractions: sub must be >= 1");
  std::vector<double> fill(grid.voxel_count(), 0.0);
  const double each = 1.0 / (static_cast<double>(sub) * sub * sub);
  VoxelGrid slab;
  slab.nx = grid.nx * sub;
  slab.ny = grid.ny * sub;
  slab.nz = sub;
  slab.spacing = grid.spacing / sub;
  for (int kz = 0; kz < grid.nz; ++kz) {
    slab.origin = Vec3{grid.origin.x, grid.origin.y, grid.origin.z + kz * grid.spacing};
    slab.tags.assign(static_cast<std::size_t>(slab.nx) * slab.ny * slab.nz, VoxelTag::Empty);
    const VoxelGrid occ = voxelize_onto_grid(file, slab);
    for (int k = 0; k < slab.nz; ++k)
      for (int j = 0; j < slab.ny; ++j)
        for (int i = 0; i < slab.nx; ++i)
          if (occ.tags[occ.index(i, j, k)] != VoxelTag::Empty)
            fill[grid.index(i / sub, j / sub, kz)] += each;
  }
  return fill;
}

}  // namespace topopt
