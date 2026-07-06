#pragma once

#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// Overhang threshold (degrees). A downward-facing surface is a support-requiring
// overhang when it dips below horizontal by MORE than this angle, measured
// against the build direction. 45 deg is the conventional FDM self-supporting
// limit (ROADMAP M4.3: "overhang voxel count > 45 deg"). A surface at exactly
// 45 deg is treated as self-supporting (not an overhang).
constexpr double kOverhangAngleDeg = 45.0;

// Distinct outward normals of the mesh's significant flat faces. Triangle
// normals are binned by direction (grouped when within ~2.5 deg of each other),
// facet area is accumulated per group, and a group is returned when its total
// area is at least `area_fraction` of the whole mesh area — so large planar faces
// are reported and curved surfaces (many small facets spread across many
// directions) are not. Each returned vector is the area-weighted unit normal of
// one such face. The order is the order the groups were first seen.
//
// Throws std::invalid_argument if the mesh has no triangles or `area_fraction` is
// not in (0, 1].
std::vector<Vec3> flat_face_normals(const TriangleMesh& mesh,
                                    double area_fraction = 0.05);

// Candidate build directions for orientation scoring (ROADMAP M4.3), as unit
// vectors pointing from the build plate up into the part. The set is the union of
//   * the 6 axis-aligned directions (+/-x, +/-y, +/-z),
//   * a coarse sphere sampling: the 26 lattice directions {-1,0,1}^3 \ {(0,0,0)}
//     normalized (which already contains the 6 axis-aligned; the "<= 26 dirs"
//     bound in ROADMAP M4.3 is on this sphere sample), and
//   * each significant flat-face normal of `mesh` and its opposite (so the part
//     can rest a real flat face on the plate either way up),
// with directions closer than ~1.8 deg deduplicated. For a purely axis-aligned
// part (e.g. a box) every flat-face normal is already a lattice direction, so the
// set is exactly the 26 sphere directions; a part with a slanted flat face adds
// that direction (and its opposite). All returned vectors are unit length.
//
// Throws std::invalid_argument if the mesh has no triangles (it has no faces to
// align to).
std::vector<Vec3> orientation_candidates(const TriangleMesh& mesh);

// Support-volume proxy for building `grid` along `build_dir` (ROADMAP M4.3): the
// number of solid voxels that would need support material — solid voxels with no
// solid voxel within the downward 45-degree support cone below them and not
// resting on the build plate. A voxel is supported when at least one of its 26
// neighbours whose offset lies within kOverhangAngleDeg of straight-down
// (-build_dir) is solid, OR the voxel sits in the lowest build-direction slab
// (on the build plate / prior layers). Voxels resting on the plate are therefore
// supported and NOT counted; only genuine unsupported overhangs are. Larger
// counts mean more support material for that orientation.
//
// `build_dir` need not be unit (it is normalized internally). Throws
// std::invalid_argument if `build_dir` is (near) zero length.
int support_overhang_voxels(const VoxelGrid& grid, const Vec3& build_dir);

}  // namespace topopt
