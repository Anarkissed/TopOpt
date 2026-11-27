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

// THE SWITCH POINT (the reviewer's ruling 2026-11-26, items 2 and 4). A reading
// over a size holds its bar (never more than 5 % under its own true value, within
// 10 % across resolutions) only when the size spans enough voxels; under that the
// ball is mostly voxels the surface cuts and reads high and unsteady, and under
// one voxel it cannot be resolved at all. So a job reads over its size only when
// size >= kStressSizeSwitchVoxels x the check voxel; otherwise it keeps TODAY'S
// solve and one-voxel reading whole (judged against the peak). Measured on the
// plate and the ring by tests E's "[switch]" tables (2026-11-26): both shapes are
// inside the bar at every span from 1.5 voxels up (lowest -4.9 %); at 1.5 the
// reading still sits about 7 % high where at 2.0 it sits up to 4.9 % low, so a
// fixed size seen at 1.5 voxels on one grid and 2.0 on another would differ by
// more than the 10 % allowed. From 1.75 up the whole range is -4.9 to +8.2 %.
inline constexpr double kStressSizeSwitchVoxels = 1.75;
// THE THIN-MEMBER RULE (the reviewer's ruling 2026-11-27, item 2): a ball wider than
// the member it sits in reaches across it (in bending, across the neutral line)
// and reads low. Where the member is thinner than this many sizes, that voxel is
// read at one voxel by today's form instead.
inline constexpr double kStressThinMemberSizes = 2.0;
inline bool stress_is_read_over_size(double reading_mm, double voxel_mm) {
  return reading_mm > 0.0 && voxel_mm > 0.0 && reading_mm >= kStressSizeSwitchVoxels * voxel_mm;
}

// `field` and `density` are per voxel (grid.voxel_count()). A voxel is printed
// when its density is at least `iso`; only printed voxels are averaged and only
// printed voxels get a reading (others return 0). `diameter_mm` <= 0 returns the
// field itself on the printed voxels. Throws std::invalid_argument on a size
// mismatch.
std::vector<double> stress_over_size(const VoxelGrid& grid,
                                     const std::vector<double>& field,
                                     const std::vector<double>& density, double iso,
                                     double diameter_mm);

// THE SAME AVERAGE WITH THE BALL CENTRED ON THE PART'S SURFACE NODES (found on the
// beam in bending, 2026-11-27; the reviewer's ruling 07:38Z). On a face that lies on
// voxel boundaries no voxel is cut, so a voxel-centred ball cannot sit on the
// surface: it sits half a voxel inside and reads 11 % low at twice the size on a
// bending beam (5 % with the ball on the surface). Here the ball is centred on
// every NODE (voxel corner) at which FULL voxels meet air or the grid's edge (a
// node touching a voxel the surface cuts is left to the voxel-centred ball, which
// already sits on the edge there; with such nodes counted the textbook plate and
// ring read 10 to 68 % high), and
// averages the material inside it (weight = the voxel's share inside the ball x its
// fill, voxels of at least `material_floor` fill). Returned PER VOXEL: the largest
// such reading among the voxel's own eight corner nodes that are surface nodes, 0
// where it has none, so a caller can take max(voxel-centred, this) voxel by voxel.
// A ball that does not reach past a voxel (diameter under one voxel) returns zeros.
std::vector<double> stress_over_size_on_surface(const VoxelGrid& grid,
                                                const std::vector<double>& field,
                                                const std::vector<double>& density,
                                                double material_floor, double diameter_mm);

// THE SIZE FORM'S READING, whole: the largest average with the ball centred on a
// voxel centre OR on a surface node (the two functions above), material of at
// least `material_floor` fill. What analyze.cpp takes voxel by voxel.
inline double peak_stress_over_size_edge_and_surface(const VoxelGrid& grid,
                                                     const std::vector<double>& field,
                                                     const std::vector<double>& density,
                                                     double material_floor, double diameter_mm) {
  double peak = 0.0;
  for (double s : stress_over_size(grid, field, density, material_floor, diameter_mm))
    if (s > peak) peak = s;
  for (double s : stress_over_size_on_surface(grid, field, density, material_floor, diameter_mm))
    if (s > peak) peak = s;
  return peak;
}

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
