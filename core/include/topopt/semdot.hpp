// semdot.hpp — SEMDOT, the Smooth-Edged Material Distribution for Optimizing
// Topology algorithm (Fu, Rolfe, Chiu, Wang, Huang & Ghabraie, Advances in
// Engineering Software 150:102921, 2020), as a SECOND MODE beside SIMP.
//
// Task 2026-08-08-semdot-does-it-come-out-smoother.
//
// ═══ WHY THIS EXISTS ═══════════════════════════════════════════════════════
//
// Four downstream attempts to remove the exported surface's stair-stepping have
// been measured and none survived contact with the maintainer's part: Taubin
// (PR 299), SDF/RBF extraction (PR 303), mean-curvature flow (PR 314) and a
// morphological closing (PR 315). PR 315 closed the last door by measuring the
// FIELD rather than the surface: `design.bin` is ~96.6% binary at boundary
// voxels, the exported mesh already sits EXACTLY on that field's 0.5 level set
// (residual rms 0.000000 mm), and a vertex fit against it recovers 0.2%.
//
// The design variable is a per-voxel density on a fixed grid, so THE BOUNDARY
// CANNOT BE FINER THAN THE GRID. Every surface-side operator is downstream of
// that. If the staircase is to go, the optimizer has to stop producing it.
//
// ═══ WHAT SEMDOT CHANGES, IN ONE PARAGRAPH ══════════════════════════════════
//
// The stiffness of a voxel is no longer a penalized function of its own density.
// The filtered density field is interpolated to GRID POINTS (a regular n x n x n
// sub-lattice inside every voxel, trilinear from the voxel field's NODAL
// averages), a single global LEVEL-SET VALUE is chosen so the volume target is
// met exactly, and a voxel's ELEMENTAL VOLUME FRACTION is the fraction of its own
// grid points at or above that level. Interior voxels come out at 1, exterior at
// 0, and a voxel the boundary passes through carries the REAL fraction of itself
// that is inside — a number with sub-voxel content, produced by the optimizer,
// which is exactly what PR 315 measured the current path as not having.
//
// The material law over that volume fraction is LINEAR: E = V * E0 (clamped at
// the rho_min floor). There is no penalization exponent, because the
// thresholding is what keeps the design from going grey — that is the method's
// central claim and the reason it is worth measuring here.
//
// ═══ PARAMETERS: THERE IS EXACTLY ONE, AND IT IS A DISCRETIZATION ═══════════
//
// `grid_points` (n per axis per voxel) is the only number this file introduces,
// and it is a DISCRETIZATION choice of the same kind as the analysis resolution,
// not a CONTROL parameter of the kind SIMP's penalty p or BESO's evolutionary
// rate are: it does not steer the optimizer toward one answer or another, it
// only sets how finely a boundary voxel's fill fraction can be resolved. Its
// effect is a quantization of the elemental volume fraction at 1/n^3, which is a
// quantization of the exported surface's position at ~1/n^3 of a voxel. At the
// default n = 4 that is 1/64 voxel = 0.027 mm on the maintainer's 1.705 mm
// voxel — five times below the 0.1037 mm of sub-voxel placement PR 315 measured
// the field as able to support in the first place.
//
// NOTHING ELSE IS ADDED. No smoothing width, no continuation schedule, no
// stabilization weight, no second threshold. The volume constraint fixes the
// level-set value; the level-set value fixes the volume fractions.
//
// ═══ TIES, AND WHY THERE IS NO SPECIAL CASE FOR THE FIRST ITERATION ═════════
//
// The level-set value is the K-th largest grid-point sample, K = target volume in
// grid points. A UNIFORM field — which is exactly what iteration 1 of the first
// rung starts from — makes every sample equal, so a hard `>= phi` count would
// hand the whole volume to whichever voxels happened to sort first and feed the
// first FEA a solid block in a corner.
//
// So the count is not hard. Writing n_gt(e) for the samples of voxel e strictly
// above phi and n_eq(e) for those AT it — "at" being within a few ulps, not
// bit-equal, because a sample is a mean of up to eight densities blended
// trilinearly and two mathematically equal samples differ in the last bits; an
// exact test lets that rounding noise sort a uniform field into a binary pattern.
// semdot.cpp states the band and why it is a floating-point epsilon rather than a
// control parameter,
//
//     V_e = ( n_gt(e) + f * n_eq(e) ) / n^3,     f = (K - N_gt) / N_eq
//
// with N_gt / N_eq the same counts summed over the design set. f is the single
// global fraction of the tied grid points that must be inside for the volume to
// come out right, so the volume is met for any field, and on a uniform field
// N_gt = 0, f = K/N and every voxel gets V_e = the target fraction — the identity
// map, which is the passthrough the first iteration needs. It falls out of the
// arithmetic rather than being a branch, and it is not a parameter.
//
// ONE HONEST LIMIT ON "EXACT": K is a whole number of grid points, so the volume
// is met to within half a grid point — 0.5/n^3 of ONE voxel, i.e. 0.008 of a
// voxel at the default n = 4, against a budget of order 10^5 voxels. It is a
// quantization, it is bounded, and `achieved_volume` reports what was actually
// reached rather than what was asked for.
//
// ═══ THE SENSITIVITY ════════════════════════════════════════════════════════
//
// SEMDOT keeps DENSITY-BASED sensitivity analysis: the elemental sensitivity
// numbers are the classic compliance sensitivities of the (linear) material law,
// dc/dV_e = -E0 * u_e^T K_unit u_e, and they are handed to the updater as the
// sensitivity with respect to the filtered design field. The thresholding is not
// differentiated through. That is the published algorithm's own choice and it is
// what keeps the parameter count at zero: a differentiable surrogate for the
// grid-point step would need a smoothing width, which would be exactly the new
// control parameter the method claims not to need. The consequence — an
// inconsistent gradient at the boundary layer — is a property of the method, and
// it is measured (iterations to plateau) rather than argued about.
//
// ═══ DETERMINISM ═══════════════════════════════════════════════════════════
//
// Pure function of (grid, density, mask, target_volume, grid_points). Fixed
// traversal order, no RNG, no floating-point reduction whose order depends on
// anything but the grid, and the level-set selection is a histogram walk plus an
// exact sort of one bin — so re-deriving the field from the same inputs is
// BIT-IDENTICAL. test_semdot pins this.

#pragma once

#include "topopt/voxel.hpp"

#include <cstddef>
#include <vector>

namespace topopt {

// The default grid points per voxel per axis. See the parameter note above: 4
// resolves a boundary voxel's fill to 1/64, i.e. the exported surface's position
// to ~1/64 of a voxel.
inline constexpr int kSemdotDefaultGridPoints = 4;

// The smooth-edged field, and everything about how it was derived that a run
// should be able to say out loud.
struct SemdotField {
  // Grid-indexed elemental volume fractions in [0, 1]. Active voxels carry the
  // derived fraction; every non-Active voxel carries the value it was handed
  // (the caller's pins), untouched.
  std::vector<double> volume_fraction;
  // The level-set value the volume target selected, in [0, 1].
  double level_set = 0.0;
  // The tie fraction f above, in [0, 1]. 1.0 when no sample is exactly at the
  // level (the generic case); the target fraction on a uniform field.
  double tie_fraction = 1.0;
  // sum_e V_e over the design (Active) set, in voxels. Equals `target_volume` to
  // within floating-point summation error by construction.
  double achieved_volume = 0.0;
  // How many design voxels came out strictly between 0 and 1 — the boundary
  // layer, and the whole population this mode exists to give sub-voxel content.
  std::size_t fractional_voxels = 0;
  std::size_t design_voxels = 0;
  // Grid-point samples exactly at the level set (the tie population).
  std::size_t tied_samples = 0;
};

// Nodal densities: for each of the (nx+1)(ny+1)(nz+1) grid nodes, the mean of the
// voxels incident to it THAT EXIST — the divisor is the in-grid count, so a node
// on a domain face averages 4 voxels and a corner node averages 1.
//
// ★ NOT marching cubes' background-0 rule, and the reason is measured rather than
// argued. MC reads outside the grid as background 0.0, which is right for MC:
// the surface it draws is where the field crosses 0.5, and beyond the grid there
// is nothing. Applying the same rule to a nodal AVERAGE is a different act — it
// mixes a real neighbour with a fictitious empty one and DIVIDES BY BOTH. On a
// uniform field at fraction v that drives every domain-face node to v/2 and every
// corner node to v/8, so the level set the volume constraint then picks lands at
// the TOP of the field's range and the entire outer layer of the design comes back
// at V = 0. test_semdot caught exactly that: the map stopped being the identity on
// a uniform field, which is the field iteration 1 of the first rung starts from.
// It would have handed the first FEA an eroded part on every run.
//
// Averaging only what exists costs nothing at the PART boundary — the voxels
// outside the part are in-grid, tagged Empty and carry a real 0.0, so the nodal
// field still ramps to zero across the part's own surface exactly as it should.
// It differs from MC only where the part runs into its own bounding box, and
// there the pre-existing half-voxel offset of an axis-aligned face (PR 299: "a
// half-voxel offset no smoother can touch") is unchanged, not added to.
//
// Throws std::invalid_argument if density.size() != grid.voxel_count().
std::vector<double> semdot_nodal_density(const VoxelGrid& grid,
                                         const std::vector<double>& density);

// THE MAP. `density` is the pinned physical field (grid-indexed; the caller has
// already applied FrozenSolid -> 1 / FrozenVoid -> 0), `mask` the effective
// design mask, and `target_volume` the Active-set volume budget IN VOXELS
// (volume_fraction * n_active — the same budget the updater's own volume
// constraint enforces).
//
// Returns the smooth-edged field with every non-Active entry copied through
// unchanged, so the caller's pins survive and only the design set is remapped.
//
// Throws std::invalid_argument if the sizes disagree, grid_points < 1, or
// target_volume is negative / exceeds the Active voxel count.
SemdotField semdot_volume_fractions(const VoxelGrid& grid,
                                    const std::vector<double>& density,
                                    const DesignMask& mask,
                                    double target_volume,
                                    int grid_points = kSemdotDefaultGridPoints);

}  // namespace topopt
