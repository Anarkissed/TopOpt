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

#include <array>
#include <vector>

#include "topopt/mesh.hpp"   // Vec3
#include "topopt/voxel.hpp"

namespace topopt {

// THE EDGE OF THE PART (found 2026-11-26 on the plate with a hole; the reviewer's
// ruling, item 3). The largest average sits with the ball centred ON the part's
// edge, at the notch's root, half of it in air. A ball that may only be centred
// on a voxel at least half full sits half a voxel inside the material and reads
// 7 to 11 % low on a 3.6 mm size. So a size is read with `iso` set to this small
// floor: the ball is centred on ANY voxel that holds material, and every cut
// voxel's material is counted (weight = its fill). The field handed in must then
// carry the stress of those cut voxels too (analyze.hpp
// FixedDesignAnalysis::von_mises_material_field).
inline constexpr double kStressMaterialFloor = 0.02;

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

// The tension ACROSS the layers in each voxel, max(0, n . sigma . n) for the
// unit build direction n: the same quantity max_interlayer_tension (orient.hpp)
// takes the maximum of, kept per voxel so it can be read over a size like the
// in-plane stress (the maintainer's decision, 2026-11-25: the same size across
// the layers as in the plane). `stress` is per voxel, Voigt [xx, yy, zz, xy, yz,
// zx] with true shear stresses; voxels that are not solid read 0. Throws
// std::invalid_argument on a size mismatch or a zero build direction.
std::vector<double> interlayer_tension_field(
    const VoxelGrid& grid, const std::vector<std::array<double, 6>>& stress,
    const Vec3& build_dir);

}  // namespace topopt
