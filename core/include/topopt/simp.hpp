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

}  // namespace topopt
