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
// It measures to the SURFACE, taken at the voxel FACE between the boundary layer and its
// neighbour -- which is where marching cubes puts it on a near-binary density field, so
// this field's zero and the solid companion's mesh describe one wall. It measured to the
// voxel CENTRES until 2026-09-20, and that was wrong twice over: the nearest value it
// could report was a whole voxel (0.85 mm of disagreement with the companion mesh on the
// maintainer's grid, under a 0.80 mm bead), and the field crossed the wall with a
// GRADIENT OF 2, so a consumer whose profile is written in millimetres -- the wetted
// join -- had that profile compressed into half its intended width. See voxel_sdf.cpp
// for the measurements, including the refinement that was tried and rejected.
//
// It remains voxel-accurate, not surface-accurate: the face is exactly right for a
// locally planar wall and approximate where the surface curves inside one voxel. Where
// an exact surface distance is needed instead, that is what
// LatticeBoundary::signed_distance is for.

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
