// mma_joint.hpp — MMA over a HETEROGENEOUS design vector.
// Task 2026-08-13-lattice-as-a-material §3, Mode 2.
//
// The shipped `mma_update` is written against one block of variables: the voxel
// densities, all sharing one box [density_min, 1]. Mode 2 adds a second block —
// the beta coefficients of the lattice density field — whose box is different,
// whose sensitivity arrives through `lattice_beta_chain` rather than the density
// filter, and which is NOT grid-indexed. Both blocks are governed by the SAME
// single volume constraint, so they cannot be updated independently: MMA's dual
// multiplier lambda is shared, and a staggered update would let each block spend
// the same budget twice.
//
// ★ MMA IS ALREADY SEPARABLE, which is the whole reason this is a generalisation
// and not a new algorithm. Every variable has its own asymptotes, its own p/q
// pair and its own move box; the only coupling is the scalar lambda found by
// bisection. So the honest way to add a block is to widen the variable vector
// and leave the mathematics alone.
//
// The caller FLATTENS its blocks into one vector and supplies a per-variable box.
// Nothing here knows about voxels, coefficients, filters or lattices — which is
// what lets `mma_update` delegate to it and keeps ONE implementation of the
// subproblem rather than two that must be kept in step by hand.

#ifndef TOPOPT_SIMP_MMA_JOINT_HPP
#define TOPOPT_SIMP_MMA_JOINT_HPP

#include <cstddef>
#include <vector>

namespace topopt {

// Asymptotes and the two previous iterates, over the FLATTENED variable vector.
// The caller owns one of these per run; its vectors are resized on first use.
struct MmaJointState {
  std::vector<double> xold1;  // x at iteration k-1
  std::vector<double> xold2;  // x at iteration k-2
  std::vector<double> low;    // lower asymptotes L_j
  std::vector<double> upp;    // upper asymptotes U_j
};

// One MMA design update over an arbitrary variable vector.
//
//   st        asymptote/history state, carried across calls
//   mma_iter  1-based MMA iteration (asymptotes are initialised for iter <= 2)
//   x         the current point (size N)
//   dof       indices that may MOVE; everything else is returned unchanged at 0,
//             exactly as `mma_update` leaves non-solid voxels
//   dobj      dF/dx, the objective sensitivity, already in DESIGN space (filtered
//             for a density block, chained for a beta block)
//   dcon      dV/dx, the single constraint's sensitivity, likewise
//   xmin/xmax the per-variable box (size N). Per-variable, because the two blocks
//             do not share one: a density lives in [density_min, 1] and a beta
//             coefficient in a symmetric box around 0
//   g0        the constraint value V(x) - target at the current point. Passed in
//             rather than recomputed, because only the caller knows how the
//             blocks contribute to V — for the lattice block a voxel costs `rho`
//             of a solid one, which is the whole point of the feature
//   move      move limit, as a fraction of each variable's own xrange
//
// Returns the new point (size N).
//
// ★ With a single uniformly-boxed block this is BIT-FOR-BIT the shipped
// `mma_update`: same operations, same order, same values. `mma_update` delegates
// here, so the whole existing suite is the guard on that claim rather than one
// bespoke comparison test.
std::vector<double> mma_update_joint(MmaJointState& st, int mma_iter,
                                     const std::vector<double>& x,
                                     const std::vector<std::size_t>& dof,
                                     const std::vector<double>& dobj,
                                     const std::vector<double>& dcon,
                                     const std::vector<double>& xmin,
                                     const std::vector<double>& xmax, double g0,
                                     double move);

}  // namespace topopt

#endif  // TOPOPT_SIMP_MMA_JOINT_HPP
