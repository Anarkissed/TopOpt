// stress_measure.hpp -- a stress read over a fixed physical size (TO rebuild
// stage 2; ledger A-02; docs/design/to-rebuild/03-rules.md rule 5).
//
// Today's strength number is the single hottest voxel. On a stair-stepped surface
// that reading rises as the grid gets finer and never settles (01-research.md:
// a peak at a sharp corner does not converge; a stress read over a material
// length does, Taylor 2008). Here each printed voxel's reading is the average of
// the stress over the MATERIAL inside a ball of a stated diameter in mm centred
// on it: every voxel counts by its own fill and by the share of it that lies in
// the ball. The diameter is a physical size, so the same part gives the same
// number at any resolution fine enough to resolve it; a ball smaller than a voxel
// reads that voxel alone.
//
// Pure C++/std.
#pragma once

#include <vector>

#include "topopt/voxel.hpp"

namespace topopt {

// `field` and `density` are per voxel (grid.voxel_count()). A voxel is printed
// when its density is at least `iso`; only printed voxels are averaged and only
// printed voxels get a reading (others return 0). `diameter_mm` <= 0 returns the
// field itself on the printed voxels. Throws std::invalid_argument on a size
// mismatch.
std::vector<double> stress_over_size(const VoxelGrid& grid,
                                     const std::vector<double>& field,
                                     const std::vector<double>& density, double iso,
                                     double diameter_mm);

// The largest reading of stress_over_size (0 when nothing is printed).
double peak_stress_over_size(const VoxelGrid& grid, const std::vector<double>& field,
                             const std::vector<double>& density, double iso,
                             double diameter_mm);

}  // namespace topopt
