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
// Cost: one voxelisation at `sub` times the resolution: sub^3 one-byte tags per
// voxel while it runs (sub 4 at 128 x 96 x 64 voxels is 50 MB).
// NOT WIRED INTO ANY JOB YET: the reviewer's ruling on "one judge" comes first.
#pragma once

#include <stdexcept>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

inline std::vector<double> file_fill_fractions(const TriangleMesh& file, const VoxelGrid& grid,
                                               int sub = 4) {
  if (sub < 1) throw std::invalid_argument("file_fill_fractions: sub must be >= 1");
  VoxelGrid fine;
  fine.nx = grid.nx * sub;
  fine.ny = grid.ny * sub;
  fine.nz = grid.nz * sub;
  fine.spacing = grid.spacing / sub;
  fine.origin = grid.origin;
  fine.tags.assign(static_cast<std::size_t>(fine.nx) * fine.ny * fine.nz, VoxelTag::Empty);
  const VoxelGrid occ = voxelize_onto_grid(file, fine);
  std::vector<double> fill(grid.voxel_count(), 0.0);
  const double each = 1.0 / (static_cast<double>(sub) * sub * sub);
  for (int k = 0; k < fine.nz; ++k)
    for (int j = 0; j < fine.ny; ++j)
      for (int i = 0; i < fine.nx; ++i)
        if (occ.tags[occ.index(i, j, k)] != VoxelTag::Empty)
          fill[grid.index(i / sub, j / sub, k / sub)] += each;
  return fill;
}

}  // namespace topopt
