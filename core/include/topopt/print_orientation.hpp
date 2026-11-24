// THE PRINT ORIENTATION RANKING (his print orientation, 2026-11-23; spec 2e, piece P4).
//
// His words: Results offers "Print orientation recommendation", which "will then take into account the "Gravity"
// position the user put as well as the shape of the part and decide which orientation is best ... it should also take
// into account layer lines and orientation and guessed strength for the orientation recommendation!"
//
// Phase 1 (decision D5): the candidates are the part's six axes (each with a flat face square to it on the bed), in the
// frame the job ran in, its own up (+Z: as placed, or the chosen face) first. Per candidate:
//   strength  the solid's margin with its layers across that up (EXACT from the one stress solve: the solve does not
//             read the build direction) and the struts' smallest margin with the rise along it (the same forces; an
//             ESTIMATE: a lay along that up would grow other struts, decision D2); the guessed strength is the least;
//   support   the part's own support (the voxel estimate: never under the lattice, never the lattice's own);
//   height    and layers (decision D3: no print time);
//   bed       the flat face on the bed, and whether the centre of mass stands over it.
// The rule is recommend_print_orientation (build_orientation.hpp), the one rule.
#pragma once

#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

struct VoxelGrid;
struct PrintFrame;

// The six candidates, in the job's own frame: +Z (as placed) first, then -Z, +X, -X, +Y, -Y.
const std::array<Vec3, 6>& orientation_axes();

// What the strength check knows per candidate (NaN: not known).
struct OrientationStrength {
  double solid = 0.0;              // the solid's effective margin (the gate's), layers across the up
  double solid_interlayer = 0.0;   // its layer margin alone
  double struts = 0.0;             // the struts' smallest margin (estimate)
  std::size_t struts_under = 0;    // struts under the safety margin (estimate)
  double support_mm3 = 0.0;        // the part's own support (voxel estimate)
};
struct OrientationStrengths {
  bool known = false;
  double required_margin = 1.5;
  std::array<OrientationStrength, 6> by_axis{};
  Vec3 centre_of_mass{};
  bool has_centre_of_mass = false;
};

// The part's own support along a grid axis (axis 0 x, 1 y, 2 z; `up_sign` +1 or -1), mm3: under every printed-solid
// voxel (`solid`) whose voxel below is not part (`in_part`: solid or lattice) and that no part voxel holds within the
// 45 degree cone below, the voxels down to the first part voxel or the bed (the lowest part layer along that up).
double support_along_axis(const VoxelGrid& grid, const std::vector<char>& in_part, const std::vector<char>& solid,
                          int axis, int up_sign);

// What the file's mesh says per candidate: its height, its flat face on the bed (triangles facing straight down within
// 1 degree at the lowest point, to 0.01 mm) and that face's outline (the convex hull of its corners, in the two other
// axes).
struct OrientationGeometry {
  double height_mm = 0.0;
  double contact_mm2 = 0.0;
  std::vector<std::array<double, 2>> hull;   // counter-clockwise
};
std::array<OrientationGeometry, 6> orientation_geometry(const TriangleMesh& mesh);
// Whether `p` stands over candidate `k`'s face (its projection inside the hull, within `tol` mm).
bool stands_over(const OrientationGeometry& g, int k, const Vec3& p, double tol = 0.5);

// The ranking and the recommendation as the report's block ("print_orientation"); every up in the MODEL frame (`frame`
// turns the job's frame back; off: the same). `layer_mm` for the layers.
std::string print_orientation_json(const OrientationStrengths& s, const std::array<OrientationGeometry, 6>& g,
                                   const PrintFrame& frame, double layer_mm);

}  // namespace topopt
