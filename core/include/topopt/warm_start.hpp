#ifndef TOPOPT_WARM_START_HPP
#define TOPOPT_WARM_START_HPP

// Warm-start restrict / prolong utilities (handoff 110, Part B — coarse-to-fine
// cascade). These build a HALF-RESOLUTION copy of an optimize problem (grid, BCs,
// loads, mask) and move density fields between the fine and coarse lattices, so a
// cheap res/2 solve can seed the fine solve. They are pure geometry — no FEA, no
// optimizer — and are platform-agnostic (no Eigen), so they build and unit-test
// on any toolchain.
//
// COARSENING CONVENTION: each axis dim n -> (n + 1) / 2 (so an even/align-8 fine
// grid halves exactly, and an odd grid rounds up to still cover the domain);
// spacing doubles; origin is preserved. Coarse voxel (I,J,K) is the block of the
// up-to-8 fine voxels {2I, 2I+1} x {2J, 2J+1} x {2K, 2K+1} that lie in range. The
// resample uses the SAME centre convention as marching_cubes / resample_field:
// fine index i maps to the continuous coarse coordinate u = (i + 0.5)/2 - 0.5.

#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// The half-resolution grid of `fine`: dims (n+1)/2 (>= 1), spacing doubled,
// origin preserved. A coarse voxel takes the HIGHEST-PRIORITY tag among its
// in-range fine children — Load > Fixture > solid (Interior/Surface/UserTagged)
// > Empty — so the load/fixture faces and the solid domain survive coarsening
// (the BCs attach to the frozen Load/Fixture skin exactly as at fine res).
VoxelGrid coarsen_grid(const VoxelGrid& fine);

// Block-average a fine density field onto `coarse` (each coarse voxel = the mean
// of its in-range fine children). Size of the returned field is
// coarse.voxel_count(). Throws std::invalid_argument if fine_density.size() !=
// fine.voxel_count() or the two grids are not a 2x coarsening pair.
std::vector<double> restrict_density(const VoxelGrid& fine,
                                     const VoxelGrid& coarse,
                                     const std::vector<double>& fine_density);

// Trilinear upsample a coarse density field onto `fine`. Fine voxel i samples the
// continuous coarse coordinate u = (i + 0.5)/2 - 0.5 and interpolates the 8
// surrounding coarse voxel centres (coordinates clamped into [0, nc-1] at the
// boundary). This is the inverse direction of restrict_density; it approximately
// conserves the mean (exactly in the interior; small boundary bias from the
// clamp). Size of the returned field is fine.voxel_count(). Throws
// std::invalid_argument if coarse_density.size() != coarse.voxel_count() or the
// two grids are not a 2x coarsening pair.
std::vector<double> prolong_density(const VoxelGrid& coarse,
                                    const VoxelGrid& fine,
                                    const std::vector<double>& coarse_density);

// Coarsen homogeneous / arbitrary Dirichlet BCs: each fine constrained node
// (a,b,c) maps to coarse node (a/2, b/2, c/2), keeping component and value;
// duplicate (node, component) pairs are removed. A contiguous fine face coarsens
// to the corresponding coarse face.
std::vector<DirichletBC> coarsen_bcs(const VoxelGrid& fine,
                                     const VoxelGrid& coarse,
                                     const std::vector<DirichletBC>& bcs);

// Restrict nodal loads: each fine load node (a,b,c) accumulates its force onto
// coarse node (a/2, b/2, c/2), summed per (coarse node, component). Total applied
// force per component is conserved, so the coarse compliance problem is the same
// load at res/2 (its optimal topology — scale-invariant in the load magnitude —
// matches the fine problem's, which is all a warm start needs).
std::vector<NodalLoad> restrict_loads(const VoxelGrid& fine,
                                      const VoxelGrid& coarse,
                                      const std::vector<NodalLoad>& loads);

// Coarsen a design mask: a coarse voxel is FrozenSolid if ANY child is
// FrozenSolid (keep-in wins — preserve pinned material), else Active if any child
// is Active (design freedom wins over keep-out), else FrozenVoid. An all-Active
// fine mask coarsens to an all-Active coarse mask. Size == coarse.voxel_count().
DesignMask coarsen_mask(const VoxelGrid& fine, const VoxelGrid& coarse,
                        const DesignMask& mask);

}  // namespace topopt

#endif  // TOPOPT_WARM_START_HPP
