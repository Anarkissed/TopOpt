#pragma once

#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// SIMP density interpolation, compliance and sensitivities (ROADMAP M3.2).
//
// SIMP (Solid Isotropic Material with Penalization) drives each design voxel's
// density rho in [rho_min, 1] and penalizes intermediate densities so the
// optimizer converges toward black/white (solid/void) layouts. ARCHITECTURE §4
// locks the classic Sigmund 99-line interpolation with penalty p = 3:
//
//   E(rho) = clamp(rho, rho_min, 1)^p * E0
//
// The density floor rho_min keeps a "void" design voxel at a small *positive*
// stiffness. This is deliberately > 0 so such voxels are NOT dropped by the M3.1
// void-DOF safety gate (which targets genuinely Empty, out-of-design voxels that
// contribute no element at all). The isotropic Poisson ratio is density-
// independent (standard SIMP).
//
// The density filter (radius >= 1.5 voxels) and the Optimality-Criteria update
// are M3.3; the full volume-fraction-targeted loop is M3.4. This header provides
// only the objective (compliance) and its gradient (sensitivities) that those
// stages consume.

struct SimpParams {
  double youngs_modulus = 0.0;  // E0, base solid Young's modulus (> 0)
  double poisson = 0.0;         // nu, in (-1, 0.5)
  double penalty = 3.0;         // p, penalization exponent (ARCHITECTURE §4: 3)
  double density_min = 1e-3;    // rho floor, in (0, 1]
};

// SIMP Young's modulus for a design density: E(rho) = clamp(rho, rho_min, 1)^p
// * E0. Throws std::invalid_argument if the params are non-physical
// (youngs_modulus <= 0, penalty <= 0, or density_min not in (0, 1]).
double simp_youngs(const SimpParams& params, double density);

// A uniform initial design field: every solid voxel gets density `value`, every
// Empty voxel gets 0. Size = grid.voxel_count(), indexed like the grid. This is
// the "density field" a SIMP run starts from (typically value = the target
// volume fraction).
std::vector<double> simp_uniform_density(const VoxelGrid& grid, double value);

// Result of a SIMP compliance analysis.
struct SimpCompliance {
  FeaSolution solution;             // penalized displacement field
  double compliance = 0.0;          // c = f^T u  (= sum_e E(rho_e) u_e^T K_unit u_e)
  std::vector<double> dcompliance;  // dc/drho_e per voxel, 0 on Empty voxels
  CgInfo cg;                        // solver diagnostics from the penalized solve
};

// Solve the SIMP-penalized linear-elastic system for the design field `density`
// (size grid.voxel_count(); Empty-voxel entries are ignored, solid entries are
// clamped to [rho_min, 1]) and return:
//   * the displacement solution,
//   * the compliance c = f^T u = sum_e E(rho_e) * (u_e^T K_unit u_e), and
//   * the per-voxel compliance sensitivity
//        dc/drho_e = -p * rho_e^(p-1) * E0 * (u_e^T K_unit u_e)   (<= 0),
//     which is 0 on Empty voxels.
// K_unit is the unit-modulus Hex8 element stiffness hex8_stiffness(1, nu,
// spacing). The solve routes through the void-gated Jacobi-CG path
// (fea_solve_cg), so under-constrained / void-only systems are rejected per
// M3.1. `tolerance` / `max_iterations` are forwarded to the CG solver.
//
// Throws std::invalid_argument if `density` has the wrong size or the params are
// non-physical; propagates fea_solve_cg's throws (bad BC/load index, or a CG
// non-convergence std::runtime_error).
SimpCompliance simp_compliance(const VoxelGrid& grid, const SimpParams& params,
                               const std::vector<double>& density,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               double tolerance = 1e-8, int max_iterations = 0);

// ---------------------------------------------------------------------------
// Density filter + Optimality-Criteria update (ROADMAP M3.3).
//
// ARCHITECTURE §4 locks a "density filter (radius >= 1.5 voxels)" as the SIMP
// mesh-independence regularizer and an "Optimality Criteria updater" as the
// design updater. Both are provided here as reusable operators; the full
// volume-fraction-targeted loop with convergence criteria is M3.4.

// Precomputed linear density filter over a voxel grid's design (solid) voxels.
// The physical density of design voxel e is the weighted average of the design
// densities of the solid voxels i whose centre lies within `radius` voxels of e:
//     xPhys_e = ( sum_i H_ei x_i ) / ( sum_i H_ei ),
//     H_ei    = max(0, radius - dist(e,i))      (dist in voxel units)
// `radius` is in voxel units (ARCHITECTURE §4: ">= 1.5 voxels"), independent of
// the grid spacing. Empty voxels are not design variables: they are excluded
// from every neighbourhood and map to 0. The map x -> xPhys is linear (xPhys =
// M x with M_ei = H_ei / sum_k H_ek); H is symmetric, so filtering an
// objective/constraint sensitivity from physical space back to design space is
// the transpose M^T (the chain rule d/dx = M^T d/dxPhys).
//
// Weights are stored in compressed sparse row form keyed by grid voxel index.
struct DensityFilter {
  std::size_t voxel_count = 0;         // == grid.voxel_count()
  std::vector<std::size_t> row_start;  // CSR row offsets, size voxel_count + 1
  std::vector<std::size_t> neighbor;   // neighbour voxel indices (solid only)
  std::vector<double> weight;          // H_ei for each neighbour entry
  std::vector<double> weight_sum;      // Hs_e = sum_i H_ei (0 for Empty voxels)

  // Forward filter: design densities x (grid-indexed) -> physical densities
  // xPhys (grid-indexed; 0 on Empty voxels). Throws std::invalid_argument if
  // x.size() != voxel_count.
  std::vector<double> filter_density(const std::vector<double>& x) const;

  // Adjoint (transpose) filter for the chain rule: given a sensitivity in
  // physical space `dfdxphys` (grid-indexed; d f / d xPhys), return the
  // sensitivity in design space d f / d x (grid-indexed; 0 on Empty voxels).
  // Used to filter both the compliance and volume sensitivities before the OC
  // update. Throws std::invalid_argument if dfdxphys.size() != voxel_count.
  std::vector<double> filter_sensitivity(
      const std::vector<double>& dfdxphys) const;
};

// Build the density filter for `grid` with neighbourhood `radius` in voxel units
// (ARCHITECTURE §4: >= 1.5). Throws std::invalid_argument if radius <= 0.
DensityFilter make_density_filter(const VoxelGrid& grid, double radius);

// One Optimality-Criteria design update (ROADMAP M3.3) for the volume-constrained
// minimum-compliance problem. Inputs (all grid-indexed; Empty voxels ignored):
//   density       current design x_e in [density_min, 1],
//   dcompliance   the physical-space compliance sensitivity dc/dxPhys_e (<= 0),
//                 as returned by simp_compliance evaluated on the filtered field.
// The update filters dc/dxPhys and the (unit) volume sensitivity through `filter`
// (chain rule), then advances the design by the classic OC step
//     x_new_e = clamp( x_e * sqrt( -dc_e / (lambda * dv_e) ),
//                       [x_e - move, x_e + move] intersect [density_min, 1] ),
// where the Lagrange multiplier lambda is found by bisection so the *physical*
// volume sum_e xPhys(x_new)_e equals volume_fraction * (number of design voxels)
// (the constraint is enforced on the filtered density, matching the density-
// filter OC updater). Returns the grid-indexed updated design (Empty voxels 0).
//
// Throws std::invalid_argument on a size mismatch, a non-physical parameter
// (volume_fraction not in (0,1], move <= 0, density_min not in (0,1]), or a
// filter whose voxel_count does not match the grid.
std::vector<double> oc_update(const VoxelGrid& grid, const DensityFilter& filter,
                              const std::vector<double>& density,
                              const std::vector<double>& dcompliance,
                              double volume_fraction, double move = 0.2,
                              double density_min = 1e-3);

// ---------------------------------------------------------------------------
// Full volume-fraction-targeted SIMP optimization loop (ROADMAP M3.4).
//
// Ties the M3.2 penalized compliance/sensitivities together with the M3.3
// density filter and Optimality-Criteria update into the classic minimum-
// compliance SIMP loop (ARCHITECTURE §4). Starting from a uniform design at the
// target volume fraction, each iteration:
//   1. xPhys = filter.filter_density(x)         (physical/analysis density)
//   2. (c, dc/dxPhys) = simp_compliance(xPhys)  (penalized solve + gradient)
//   3. x = oc_update(x, dc/dxPhys, volfrac)     (constraint on physical volume)
// and stops when the design change max_e |x_new - x| falls below `change_tol`
// (converged) or after `max_iterations` (the iteration cap). The volume
// constraint is enforced on the physical (filtered) density by oc_update every
// step, so the achieved physical volume fraction tracks the target throughout.

struct SimpOptions {
  double volume_fraction = 0.5;  // target physical volume fraction, in (0, 1]
  double filter_radius = 1.5;    // density-filter radius, voxel units (§4: >= 1.5)
  double move = 0.2;             // OC move limit
  int max_iterations = 60;       // hard iteration cap (a convergence criterion)
  double change_tol = 0.01;      // stop when max_e |x_new - x| < change_tol
  double cg_tolerance = 1e-8;    // penalized-FEA CG tolerance (tight: §V2 gate)
  int cg_max_iterations = 0;     // 0 -> Eigen CG default (2 * n_dof)
};

// One recorded step of the SIMP trajectory.
struct SimpIteration {
  double compliance = 0.0;       // compliance of xPhys at the START of the step
  double change = 0.0;           // max_e |x_new - x| produced by this step's OC
  double volume_fraction = 0.0;  // achieved physical volume fraction after the step
};

// Result of simp_optimize. `design`, `physical_density` and `compliance` are
// mutually consistent: compliance == compliance(physical_density) (a final solve
// on the converged field), and physical_density == filter(design).
struct SimpOptimizeResult {
  std::vector<double> design;            // final design variable x (grid-indexed)
  std::vector<double> physical_density;  // final xPhys = filter(x) (grid-indexed)
  double compliance = 0.0;               // compliance of physical_density
  double initial_compliance = 0.0;       // compliance of the uniform start design
  double volume_fraction = 0.0;          // achieved physical volume fraction
  int iterations = 0;                    // OC updates performed
  bool converged = false;                // stopped on change_tol (not the cap)
  std::vector<SimpIteration> history;    // per-iteration trajectory (size iterations)
};

// Run the full SIMP loop above and return the optimized design. The initial
// design is uniform at options.volume_fraction on every solid voxel (Empty
// voxels stay 0 and are not design variables). Solves route through the M3.1
// void-gated Jacobi-CG path (fea_solve_cg via simp_compliance).
//
// Throws std::invalid_argument if the params are non-physical (simp_compliance
// rules), volume_fraction not in (0, 1], move <= 0, max_iterations < 1,
// change_tol < 0, or filter_radius <= 0 (make_density_filter). Throws
// std::runtime_error if a penalized CG solve fails to converge (so the caller
// never optimizes on a garbage field).
SimpOptimizeResult simp_optimize(const VoxelGrid& grid, const SimpParams& params,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 const SimpOptions& options);

}  // namespace topopt
