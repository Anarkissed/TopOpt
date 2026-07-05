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

// ---------------------------------------------------------------------------
// Density filter (ROADMAP M3.3). Precompute the convolution weights
// H_ei = max(0, radius - dist(e,i)) over solid voxels within `radius` (voxel
// units) and store them in CSR form keyed by grid voxel index.
DensityFilter make_density_filter(const VoxelGrid& grid, double radius) {
  if (!(radius > 0.0))
    throw std::invalid_argument("make_density_filter: radius must be > 0");

  DensityFilter f;
  f.voxel_count = grid.voxel_count();
  f.row_start.assign(f.voxel_count + 1, 0);
  f.weight_sum.assign(f.voxel_count, 0.0);

  // Scan a cube of integer offsets large enough to contain every positive
  // weight (dist < radius). ceil(radius) never misses one and only over-scans
  // by offsets whose weight is 0 (dist >= radius), which are skipped below.
  const int R = static_cast<int>(std::ceil(radius));

  // The triple loop visits voxels in ascending grid.index() order (i fastest),
  // so row_start[e] can be filled in place as the CSR rows are appended.
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        f.row_start[e] = f.neighbor.size();
        if (!grid.solid(i, j, k)) continue;  // Empty voxel: empty row, Hs = 0
        double hs = 0.0;
        for (int dk = -R; dk <= R; ++dk)
          for (int dj = -R; dj <= R; ++dj)
            for (int di = -R; di <= R; ++di) {
              const int ii = i + di, jj = j + dj, kk = k + dk;
              if (ii < 0 || ii >= grid.nx || jj < 0 || jj >= grid.ny ||
                  kk < 0 || kk >= grid.nz)
                continue;
              if (!grid.solid(ii, jj, kk)) continue;  // design voxels only
              const double dist = std::sqrt(
                  static_cast<double>(di * di + dj * dj + dk * dk));
              const double h = radius - dist;
              if (h <= 0.0) continue;
              f.neighbor.push_back(grid.index(ii, jj, kk));
              f.weight.push_back(h);
              hs += h;
            }
        f.weight_sum[e] = hs;
      }
  f.row_start[f.voxel_count] = f.neighbor.size();
  return f;
}

std::vector<double> DensityFilter::filter_density(
    const std::vector<double>& x) const {
  if (x.size() != voxel_count)
    throw std::invalid_argument("DensityFilter::filter_density: size mismatch");
  std::vector<double> out(voxel_count, 0.0);
  for (std::size_t e = 0; e < voxel_count; ++e) {
    if (!(weight_sum[e] > 0.0)) continue;  // Empty voxel -> 0
    double acc = 0.0;
    for (std::size_t p = row_start[e]; p < row_start[e + 1]; ++p)
      acc += weight[p] * x[neighbor[p]];
    out[e] = acc / weight_sum[e];
  }
  return out;
}

std::vector<double> DensityFilter::filter_sensitivity(
    const std::vector<double>& dfdxphys) const {
  if (dfdxphys.size() != voxel_count)
    throw std::invalid_argument(
        "DensityFilter::filter_sensitivity: size mismatch");
  // Transpose of filter_density: out[j] = sum_e (H_ej / Hs_e) * dfdxphys[e].
  std::vector<double> out(voxel_count, 0.0);
  for (std::size_t e = 0; e < voxel_count; ++e) {
    if (!(weight_sum[e] > 0.0)) continue;
    const double se = dfdxphys[e] / weight_sum[e];
    for (std::size_t p = row_start[e]; p < row_start[e + 1]; ++p)
      out[neighbor[p]] += weight[p] * se;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Optimality-Criteria update (ROADMAP M3.3). Standard bisection on the Lagrange
// multiplier of the volume constraint; the constraint is enforced on the
// filtered (physical) density, matching the classic density-filter OC updater.
std::vector<double> oc_update(const VoxelGrid& grid, const DensityFilter& filter,
                              const std::vector<double>& density,
                              const std::vector<double>& dcompliance,
                              double volume_fraction, double move,
                              double density_min) {
  const std::size_t N = grid.voxel_count();
  if (density.size() != N || dcompliance.size() != N)
    throw std::invalid_argument("oc_update: vector size != voxel_count");
  if (filter.voxel_count != N)
    throw std::invalid_argument("oc_update: filter voxel_count != grid");
  if (!(volume_fraction > 0.0 && volume_fraction <= 1.0))
    throw std::invalid_argument("oc_update: volume_fraction must be in (0, 1]");
  if (!(move > 0.0)) throw std::invalid_argument("oc_update: move must be > 0");
  if (!(density_min > 0.0 && density_min <= 1.0))
    throw std::invalid_argument("oc_update: density_min must be in (0, 1]");

  // Chain rule: filter the physical-space compliance sensitivity and the unit
  // volume sensitivity back into design space.
  const std::vector<double> dc = filter.filter_sensitivity(dcompliance);
  std::vector<double> ones(N, 0.0);
  std::size_t n_design = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) {
          ones[grid.index(i, j, k)] = 1.0;
          ++n_design;
        }
  const std::vector<double> dv = filter.filter_sensitivity(ones);
  const double target = volume_fraction * static_cast<double>(n_design);

  // Candidate design for a trial multiplier lambda (OC step + move + box bounds).
  auto candidate = [&](double lambda) {
    std::vector<double> xnew(N, 0.0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!grid.solid(i, j, k)) continue;
          const std::size_t e = grid.index(i, j, k);
          const double xe = density[e];
          double be = 0.0;
          if (dv[e] > 0.0) be = -dc[e] / (lambda * dv[e]);
          if (be < 0.0) be = 0.0;  // -dc >= 0 physically; guard rounding
          double xt = xe * std::sqrt(be);
          const double lo = std::max(density_min, xe - move);
          const double hi = std::min(1.0, xe + move);
          if (xt < lo) xt = lo;
          if (xt > hi) xt = hi;
          xnew[e] = xt;
        }
    return xnew;
  };

  // Physical (filtered) volume of a candidate, summed over design voxels.
  auto phys_vol = [&](const std::vector<double>& xnew) {
    const std::vector<double> xp = filter.filter_density(xnew);
    double v = 0.0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i)
          if (grid.solid(i, j, k)) v += xp[grid.index(i, j, k)];
    return v;
  };

  // Physical volume is monotonically decreasing in lambda. Bracket the root:
  // lambda -> 0 gives the max-volume candidate, so l1 = 0; grow l2 until the
  // candidate volume drops to/below the target.
  double l1 = 0.0, l2 = 1.0;
  while (l2 < 1e30 && phys_vol(candidate(l2)) > target) l2 *= 2.0;
  for (int it = 0; it < 100 && (l2 - l1) > 1e-6 * (l1 + l2); ++it) {
    const double lmid = 0.5 * (l1 + l2);
    if (phys_vol(candidate(lmid)) > target)
      l1 = lmid;
    else
      l2 = lmid;
  }
  return candidate(0.5 * (l1 + l2));
}

}  // namespace topopt
