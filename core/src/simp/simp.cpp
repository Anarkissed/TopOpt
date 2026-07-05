// SIMP density interpolation, penalized compliance and sensitivities (ROADMAP
// M3.2). The penalized linear solve is delegated to the FEA module's graded
// void-gated CG path (fea_solve_cg with a per-voxel modulus), so this file only
// realises the SIMP material law E(rho)=rho^p*E0 and the compliance objective +
// gradient built from the resulting displacement field. The public API
// (topopt/simp.hpp) is Eigen-free; this translation unit is compiled only when
// Eigen is available (see core/CMakeLists.txt), the same as the FEA assembly.

#include "topopt/simp.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <vector>

namespace topopt {

namespace {

void validate_params(const SimpParams& p) {
  if (!(p.youngs_modulus > 0.0))
    throw std::invalid_argument("simp: youngs_modulus (E0) must be > 0");
  if (!(p.penalty > 0.0))
    throw std::invalid_argument("simp: penalty (p) must be > 0");
  if (!(p.density_min > 0.0 && p.density_min <= 1.0))
    throw std::invalid_argument("simp: density_min must be in (0, 1]");
}

// Clamp a design density to the admissible interval [rho_min, 1].
double clamp_density(const SimpParams& p, double density) {
  return std::min(1.0, std::max(p.density_min, density));
}

}  // namespace

double simp_youngs(const SimpParams& params, double density) {
  validate_params(params);
  const double rho = clamp_density(params, density);
  return std::pow(rho, params.penalty) * params.youngs_modulus;
}

std::vector<double> simp_uniform_density(const VoxelGrid& grid, double value) {
  std::vector<double> density(grid.voxel_count(), 0.0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) density[grid.index(i, j, k)] = value;
  return density;
}

SimpCompliance simp_compliance(const VoxelGrid& grid, const SimpParams& params,
                               const std::vector<double>& density,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               double tolerance, int max_iterations) {
  validate_params(params);
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "simp_compliance: density vector size != voxel_count");

  // Per-voxel penalized Young's modulus E(rho_e) for the graded FEA solve. Empty
  // voxels contribute no element, so their entry is ignored by fea_solve_cg; we
  // still fill it (0) to keep the vector grid-indexed.
  std::vector<double> elem_youngs(grid.voxel_count(), 0.0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        elem_youngs[e] =
            std::pow(clamp_density(params, density[e]), params.penalty) *
            params.youngs_modulus;
      }

  SimpCompliance out;
  out.solution = fea_solve_cg(grid, elem_youngs, params.poisson, bcs, loads,
                              tolerance, max_iterations, &out.cg);

  // Compliance c = sum_e E(rho_e) * (u_e^T K_unit u_e) and the self-adjoint
  // sensitivity dc/drho_e = -p * rho_e^(p-1) * E0 * (u_e^T K_unit u_e). K_unit is
  // the unit-modulus element (the isotropic Hex8 is exactly linear in E), so the
  // element stiffness at modulus E is E * K_unit and its strain energy density
  // per unit modulus is q_e = u_e^T K_unit u_e.
  const Hex8Stiffness Kunit = hex8_stiffness(1.0, params.poisson, grid.spacing);
  out.dcompliance.assign(grid.voxel_count(), 0.0);
  double compliance = 0.0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        std::array<double, 24> ue;
        for (int a = 0; a < 8; ++a)
          for (int comp = 0; comp < 3; ++comp)
            ue[static_cast<std::size_t>(3 * a + comp)] =
                out.solution.at(en[a], comp);

        // q_e = u_e^T K_unit u_e (>= 0).
        double q = 0.0;
        for (int r = 0; r < 24; ++r) {
          double kr = 0.0;
          for (int c = 0; c < 24; ++c) kr += Kunit(r, c) * ue[static_cast<std::size_t>(c)];
          q += ue[static_cast<std::size_t>(r)] * kr;
        }

        const double rho = clamp_density(params, density[e]);
        compliance += std::pow(rho, params.penalty) * params.youngs_modulus * q;
        out.dcompliance[e] = -params.penalty *
                             std::pow(rho, params.penalty - 1.0) *
                             params.youngs_modulus * q;
      }
  out.compliance = compliance;
  return out;
}

}  // namespace topopt
