#pragma once

#include <array>
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

// Maximum tensile normal stress ACROSS the print layer planes when building along
// `build_dir` (ROADMAP M4.4: "max tensile stress across layer planes"). Layers are
// perpendicular to the build direction, so tension across them (carried by the
// weak inter-layer bond) is the normal traction n.sigma.n on a plane whose normal
// is n = unit(build_dir). Returns the maximum over all solid voxels of
// max(0, n.sigma.n) — the worst inter-layer tensile stress in the part for that
// orientation; 0 if no solid voxel is in inter-layer tension.
//
// `stress` is a per-voxel Cauchy stress field, grid-indexed exactly like the grid
// (size grid.voxel_count()), each entry Voigt-ordered [xx, yy, zz, xy, yz, zx] with
// TRUE (not doubled) shear stresses — i.e. the `sigma` array hex8_stress returns.
// Empty voxels are ignored (their stress entry is not read). `build_dir` need not
// be unit (normalized internally).
//
// Throws std::invalid_argument if `build_dir` is (near) zero length or
// stress.size() != grid.voxel_count().
double max_interlayer_tension(const VoxelGrid& grid,
                              const std::vector<std::array<double, 6>>& stress,
                              const Vec3& build_dir);

// One scored candidate build direction (ROADMAP M4.4). Lower `score` is better.
struct OrientationScore {
  Vec3 build_dir;                  // the unit build direction scored
  int support_voxels = 0;          // support proxy (support_overhang_voxels), M4.3
  double interlayer_tension = 0.0; // max tensile stress across layer planes (raw)
  double stress_penalty = 0.0;     // interlayer_tension * (1/z_knockdown - 1)
  double score = 0.0;              // combined normalized score; LOWER is better
};

// Score and rank candidate build directions (ROADMAP M4.4 / ARCHITECTURE §7 Gate
// V5). Each candidate combines two terms, lower = better:
//   * support term  = support_overhang_voxels(grid, dir)              (M4.3 proxy)
//   * stress term   = max_interlayer_tension(grid, stress, dir) knocked down by
//                     `z_knockdown` = k: stress_penalty = tension * (1/k - 1).
// The factor (1/k - 1) is the EXTRA inter-layer failure risk of an FDM material
// (layer-normal strength k*S) over an isotropic one; it vanishes at k = 1 (resins),
// so for an isotropic material the stress term carries NO orientation preference
// (§7 V5 mechanism: tension across layer planes is penalized BY z_knockdown) and
// ranking falls back to the support proxy alone. Each term is scaled by its maximum
// over `candidates` (both become dimensionless in [0, 1]; a term whose max is 0
// contributes 0), then combined:
//   score = support_weight * support_norm + stress_weight * stress_penalty_norm.
// Returns one OrientationScore per candidate, sorted best (lowest score) first;
// ties keep the input `candidates` order (stable).
//
// `stress` is the isotropic part-frame stress field (grid-indexed Voigt, as
// max_interlayer_tension). `z_knockdown` in (0, 1] (materials.json §6). The weights
// default to 1/1. Throws std::invalid_argument if `candidates` is empty,
// z_knockdown is not in (0, 1], either weight is negative, or stress.size() !=
// grid.voxel_count().
std::vector<OrientationScore> score_orientations(
    const VoxelGrid& grid, const std::vector<std::array<double, 6>>& stress,
    const std::vector<Vec3>& candidates, double z_knockdown,
    double support_weight = 1.0, double stress_weight = 1.0);

}  // namespace topopt
