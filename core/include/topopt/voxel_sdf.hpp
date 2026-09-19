#pragma once
// ── AN EXACT SIGNED DISTANCE FIELD OVER A VOXEL SET ───────────────────────────
//
// WHY THIS EXISTS. The wetted join (organic_wet_join.hpp) gates on "is there material
// here to wet", and that gate is a DISTANCE IN MILLIMETRES -- the preview samples an SDF
// texture for it. Core had no such field: run_job carries a two-pass chamfer over the
// 6-neighbourhood, which is used as a length cap and is not a distance (it over-estimates
// diagonals by up to 41 %, because it can only step along axes). Feeding that to a
// smoothstep whose whole shape is set in millimetres would put the bead in the wrong
// place, at a size that depended on the direction the wall happened to face.
//
// So this is the EXACT Euclidean transform (Felzenszwalb & Huttenlocher, "Distance
// Transforms of Sampled Functions", Theory of Computing 8:415-428, 2012): a
// lower-envelope-of-parabolas sweep along each axis in turn, O(n) per row, exact for the
// squared Euclidean distance rather than any chamfer approximation of it. Three sweeps,
// no iteration, no tolerance to tune.
//
// SIGN: NEGATIVE INSIDE the set, positive outside, which is the convention the preview's
// shader samples and therefore the one the fillet's arithmetic is written against.
//
// It measures to the VOXEL CENTRES of the boundary layer, so it is a voxel-accurate field
// and not a surface-accurate one -- the same thing the preview samples, built the same
// way, which is the point. Where an exact surface distance is needed instead, that is
// what LatticeBoundary::signed_distance is for.

#include <cstddef>
#include <vector>

#include "topopt/voxel.hpp"

namespace topopt {

// `inside[e] != 0` marks the set. Returns a grid-indexed field in MILLIMETRES, negative
// inside. Returns empty when `inside` does not match the grid.
std::vector<double> voxel_signed_distance_mm(const VoxelGrid& grid,
                                             const std::vector<char>& inside);

// Trilinear sample of a grid-indexed field at a point, clamped at the grid's edges.
// Matches how the preview samples its SDF texture, so the two read the same number
// between voxel centres and not merely at them.
double voxel_field_sample(const VoxelGrid& grid, const std::vector<double>& field,
                          const Vec3& p);

}  // namespace topopt
