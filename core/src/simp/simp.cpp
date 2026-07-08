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
#include <utility>
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

// Shared validation of the Heaviside projection parameters (M6.3).
void validate_projection_args(double beta, double eta) {
  if (!(beta > 0.0) || !std::isfinite(beta))
    throw std::invalid_argument(
        "heaviside_project: beta must be finite and > 0");
  if (!(eta > 0.0 && eta < 1.0))
    throw std::invalid_argument("heaviside_project: eta must be in (0, 1)");
}

// Validate a SimpOptions projection schedule (empty = projection disabled; the
// eta and per-stage parameters are then never consulted).
void validate_projection_options(const SimpOptions& o) {
  if (o.projection.empty()) return;
  if (!(o.projection_eta > 0.0 && o.projection_eta < 1.0))
    throw std::invalid_argument(
        "simp_optimize: projection_eta must be in (0, 1)");
  for (const ProjectionStage& s : o.projection) {
    if (!(s.beta > 0.0) || !std::isfinite(s.beta))
      throw std::invalid_argument(
          "simp_optimize: projection stage beta must be finite and > 0");
    if (!(s.move > 0.0))
      throw std::invalid_argument(
          "simp_optimize: projection stage move must be > 0");
    if (s.iterations < 1)
      throw std::invalid_argument(
          "simp_optimize: projection stage iterations must be >= 1");
  }
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

// ---------------------------------------------------------------------------
// Single-field Heaviside projection (ROADMAP M6.3). The tanh threshold of
// Wang/Lazarov/Sigmund (2011) and its derivative, exactly as locked by
// tests/fixtures/benchmarks.json "formulation_locked" (eta = 0.5 there; the
// projected analysis chain and its use inside simp_optimize live below).

double heaviside_project(double rho_tilde, double beta, double eta) {
  validate_projection_args(beta, eta);
  const double denom =
      std::tanh(beta * eta) + std::tanh(beta * (1.0 - eta));
  return (std::tanh(beta * eta) + std::tanh(beta * (rho_tilde - eta))) / denom;
}

double heaviside_project_derivative(double rho_tilde, double beta, double eta) {
  validate_projection_args(beta, eta);
  const double denom =
      std::tanh(beta * eta) + std::tanh(beta * (1.0 - eta));
  const double ch = std::cosh(beta * (rho_tilde - eta));
  return beta / (ch * ch * denom);  // beta * sech^2(...) / denom
}

std::vector<ProjectionStage> heaviside_continuation_schedule() {
  // Locked by benchmarks.json "formulation_locked": beta doubling 1 -> 32,
  // exactly 50 OC iterations per stage, move damped to 0.1 / 0.05 at the two
  // sharpest stages. beta = 64 is excluded (measured: destroys the structure).
  return {{1.0, 0.2, 50},  {2.0, 0.2, 50}, {4.0, 0.2, 50},
          {8.0, 0.2, 50},  {16.0, 0.1, 50}, {32.0, 0.05, 50}};
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
DensityFilter make_density_filter(const VoxelGrid& grid, double radius,
                                  const DesignMask& mask) {
  if (!(radius > 0.0))
    throw std::invalid_argument("make_density_filter: radius must be > 0");
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument("make_density_filter: mask size != voxel_count");

  // A design/filter voxel is a solid voxel whose mask entry is Active. Frozen
  // (FrozenSolid/FrozenVoid) and Empty voxels are excluded from every Active
  // voxel's neighbourhood, so physical density never averages across a mask
  // boundary (ROADMAP M3.7 "no bleed"). With an all-Active mask this is exactly
  // "grid.solid()", so the plain overload below delegates here bit-for-bit.
  auto is_active = [&](int i, int j, int k) {
    return grid.solid(i, j, k) &&
           mask[grid.index(i, j, k)] == MaskValue::Active;
  };

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
        if (!is_active(i, j, k)) continue;  // non-design voxel: empty row, Hs = 0
        double hs = 0.0;
        for (int dk = -R; dk <= R; ++dk)
          for (int dj = -R; dj <= R; ++dj)
            for (int di = -R; di <= R; ++di) {
              const int ii = i + di, jj = j + dj, kk = k + dk;
              if (ii < 0 || ii >= grid.nx || jj < 0 || jj >= grid.ny ||
                  kk < 0 || kk >= grid.nz)
                continue;
              if (!is_active(ii, jj, kk)) continue;  // active design voxels only
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

DensityFilter make_density_filter(const VoxelGrid& grid, double radius) {
  // All-Active mask => is_active == grid.solid(), so this reproduces the
  // pre-M3.7 filter (same neighbour set, order and weights) bit-for-bit.
  return make_density_filter(grid, radius, make_active_mask(grid));
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

// ---------------------------------------------------------------------------
// Full volume-fraction-targeted SIMP loop (ROADMAP M3.4), staged for the M6.3
// Heaviside-projection beta continuation. Assembles the M3.2 compliance/
// gradient, the M3.3 density filter and OC update into the classic minimum-
// compliance loop with two convergence criteria: a design-change tolerance and
// a per-stage iteration cap. An empty projection schedule runs a single
// unprojected stage — exactly the pre-M6.3 loop.

namespace {

// One executed stage of the loop: the pre-M6.3 loop is a single stage with
// project == false, move/iterations from the top-level options.
struct StagePlan {
  bool project = false;
  double beta = 0.0;
  double move = 0.2;
  int iterations = 0;
};

std::vector<StagePlan> build_stage_plan(const SimpOptions& options) {
  std::vector<StagePlan> plan;
  if (options.projection.empty()) {
    plan.push_back({false, 0.0, options.move, options.max_iterations});
  } else {
    plan.reserve(options.projection.size());
    for (const ProjectionStage& ps : options.projection)
      plan.push_back({true, ps.beta, ps.move, ps.iterations});
  }
  return plan;
}

std::size_t total_stage_iterations(const std::vector<StagePlan>& plan) {
  std::size_t n = 0;
  for (const StagePlan& st : plan) n += static_cast<std::size_t>(st.iterations);
  return n;
}

// Project the design (solid) voxels of a filtered field in place; Empty
// voxels stay exactly 0.
void project_solid(const VoxelGrid& grid, std::vector<double>& x, double beta,
                   double eta) {
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) {
          const std::size_t e = grid.index(i, j, k);
          x[e] = heaviside_project(x[e], beta, eta);
        }
}

// Projected Optimality-Criteria update (M6.3). Same bisection structure as
// oc_update, with the three locked differences (benchmarks.json
// "formulation_locked" / "oc_guard_locked"):
//   * both sensitivities chain the projection derivative BEFORE the filter
//     transpose: dc/dx = H^T((dc/drho_bar * drho_bar/drho_tilde)/Hs), and the
//     volume sensitivity is H^T(drho_bar/drho_tilde / Hs);
//   * the volume constraint is enforced on the PROJECTED candidate density;
//   * the elementwise OC ratio -dc/(lambda*dv) uses UNCLAMPED dv — dc and dv
//     both carry the projection-derivative factor, so their ratio stays
//     well-conditioned where either alone underflows; where the ratio is
//     non-finite (0/0: a voxel whose whole filter neighbourhood has zero
//     projection derivative) the design variable is HELD (Be = 1). Clamping
//     dv at an absolute floor instead drags exactly the should-not-move
//     voxels to the bound at move-limit speed and destroys the design at
//     beta >= 32 (measured during fixture generation).
// `xtilde` is the current filtered design filter_density(density).
std::vector<double> oc_update_projected(
    const VoxelGrid& grid, const DensityFilter& filter,
    const std::vector<double>& density, const std::vector<double>& xtilde,
    const std::vector<double>& dcompliance, double beta, double eta,
    double volume_fraction, double move, double density_min) {
  const std::size_t N = grid.voxel_count();
  std::vector<double> dc_phys(N, 0.0), dproj(N, 0.0);
  std::size_t n_design = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        dproj[e] = heaviside_project_derivative(xtilde[e], beta, eta);
        dc_phys[e] = dcompliance[e] * dproj[e];
        ++n_design;
      }
  const std::vector<double> dc = filter.filter_sensitivity(dc_phys);
  const std::vector<double> dv = filter.filter_sensitivity(dproj);
  const double target = volume_fraction * static_cast<double>(n_design);

  auto candidate = [&](double lambda) {
    std::vector<double> xnew(N, 0.0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!grid.solid(i, j, k)) continue;
          const std::size_t e = grid.index(i, j, k);
          const double xe = density[e];
          double be = -dc[e] / (lambda * dv[e]);  // UNCLAMPED dv (locked)
          if (!std::isfinite(be)) be = 1.0;       // 0/0 -> hold this voxel
          if (be < 0.0) be = 0.0;                 // guard rounding
          double xt = xe * std::sqrt(be);
          const double lo = std::max(density_min, xe - move);
          const double hi = std::min(1.0, xe + move);
          if (xt < lo) xt = lo;
          if (xt > hi) xt = hi;
          xnew[e] = xt;
        }
    return xnew;
  };

  // PROJECTED volume of a candidate, summed over design voxels (the volume
  // constraint is on rho_bar, and the OC bisection tests the projected volume
  // of the candidate design — locked).
  auto proj_vol = [&](const std::vector<double>& xnew) {
    const std::vector<double> xp = filter.filter_density(xnew);
    double v = 0.0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i)
          if (grid.solid(i, j, k))
            v += heaviside_project(xp[grid.index(i, j, k)], beta, eta);
    return v;
  };

  double l1 = 0.0, l2 = 1.0;
  while (l2 < 1e30 && proj_vol(candidate(l2)) > target) l2 *= 2.0;
  for (int it = 0; it < 100 && (l2 - l1) > 1e-6 * (l1 + l2); ++it) {
    const double lmid = 0.5 * (l1 + l2);
    if (proj_vol(candidate(lmid)) > target)
      l1 = lmid;
    else
      l2 = lmid;
  }
  return candidate(0.5 * (l1 + l2));
}

}  // namespace

SimpOptimizeResult simp_optimize(const VoxelGrid& grid, const SimpParams& params,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 const SimpOptions& options) {
  validate_params(params);  // E0 > 0, penalty > 0, density_min in (0, 1]
  if (!(options.volume_fraction > 0.0 && options.volume_fraction <= 1.0))
    throw std::invalid_argument("simp_optimize: volume_fraction must be in (0, 1]");
  if (!(options.move > 0.0))
    throw std::invalid_argument("simp_optimize: move must be > 0");
  if (options.max_iterations < 1)
    throw std::invalid_argument("simp_optimize: max_iterations must be >= 1");
  if (options.change_tol < 0.0)
    throw std::invalid_argument("simp_optimize: change_tol must be >= 0");
  validate_projection_options(options);

  // make_density_filter validates filter_radius > 0.
  const DensityFilter filter = make_density_filter(grid, options.filter_radius);
  const double n_design = static_cast<double>(grid.solid_count());
  const std::vector<StagePlan> plan = build_stage_plan(options);
  const double eta = options.projection_eta;

  // Physical volume fraction of a grid-indexed physical density field.
  auto phys_volfrac = [&](const std::vector<double>& xphys) {
    double vol = 0.0;
    for (double v : xphys) vol += v;
    return n_design > 0.0 ? vol / n_design : 0.0;
  };

  // Initial design: uniform at the target volume fraction on every solid voxel.
  std::vector<double> x = simp_uniform_density(grid, options.volume_fraction);

  SimpOptimizeResult result;
  result.history.reserve(total_stage_iterations(plan));

  for (const StagePlan& st : plan) {
    bool stage_converged = false;
    for (int it = 0; it < st.iterations; ++it) {
      // M7.0a: cancellation is polled once per OC iteration, at its start, so
      // a cancel request is honoured before the next (expensive) FEA solve.
      if (options.cancel && options.cancel->load()) {
        result.cancelled = true;
        break;
      }
      std::vector<double> xphys = filter.filter_density(x);
      if (st.project) project_solid(grid, xphys, st.beta, eta);
      const SimpCompliance c = simp_compliance(grid, params, xphys, bcs, loads,
                                               options.cg_tolerance,
                                               options.cg_max_iterations);
      if (!c.cg.converged)
        throw std::runtime_error(
            "simp_optimize: penalized CG solve did not converge");

      std::vector<double> x_new;
      if (st.project) {
        // dproj needs the UNprojected filtered field: recompute it (xphys was
        // projected in place above).
        const std::vector<double> xtilde = filter.filter_density(x);
        x_new = oc_update_projected(grid, filter, x, xtilde, c.dcompliance,
                                    st.beta, eta, options.volume_fraction,
                                    st.move, params.density_min);
      } else {
        x_new = oc_update(grid, filter, x, c.dcompliance,
                          options.volume_fraction, st.move,
                          params.density_min);
      }

      double change = 0.0;
      for (std::size_t e = 0; e < x.size(); ++e)
        change = std::max(change, std::fabs(x_new[e] - x[e]));

      x = x_new;
      if (result.iterations == 0) result.initial_compliance = c.compliance;
      ++result.iterations;
      std::vector<double> xafter = filter.filter_density(x);
      if (st.project) project_solid(grid, xafter, st.beta, eta);
      result.history.push_back({c.compliance, change, phys_volfrac(xafter)});
      if (options.progress)
        options.progress(result.iterations, c.compliance, change);

      if (change < options.change_tol) {
        stage_converged = true;
        break;
      }
    }
    // The stage either re-converged (change_tol) or ran its cap; continuation
    // proceeds either way. The loop is `converged` iff its LAST stage was
    // (a cancelled stage never is).
    result.converged = stage_converged;
    if (result.cancelled) break;
  }

  // Report a self-consistent final state: physical_density = filter(design)
  // (projected at the final stage's beta when projecting) and compliance =
  // compliance(physical_density) via one final solve on the converged field
  // (so callers/property checks see matching values).
  result.design = x;
  result.physical_density = filter.filter_density(x);
  if (plan.back().project)
    project_solid(grid, result.physical_density, plan.back().beta, eta);
  const SimpCompliance fc =
      simp_compliance(grid, params, result.physical_density, bcs, loads,
                      options.cg_tolerance, options.cg_max_iterations);
  result.compliance = fc.compliance;
  result.volume_fraction = phys_volfrac(result.physical_density);
  return result;
}

// ---------------------------------------------------------------------------
// Passive regions: mask-aware SIMP optimization (ROADMAP M3.7).

namespace {

// The effective mask actually optimized: the caller's mask with every Load and
// Fixture voxel forced to FrozenSolid (M1.6 tags are implicitly "keep-in", so
// the §7 V3 retention gate is structural). Empty voxels are left as-is (ignored).
DesignMask effective_mask(const VoxelGrid& grid, const DesignMask& mask) {
  DesignMask eff = mask;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const VoxelTag t = grid.tag(i, j, k);
        if (t == VoxelTag::Empty) {
          // Empty voxels are never design variables — their caller-supplied
          // mask entry is ignored (voxel.hpp). Normalizing them to FrozenVoid
          // here keeps them out of the Active-voxel budget: on a part that
          // does not fill its bounding grid (e.g. an imported model), an
          // Empty-counting budget makes volume_fraction * n_active exceed the
          // reachable volume, so the OC bisection saturates and every rung
          // collapses to the same all-solid design.
          eff[grid.index(i, j, k)] = MaskValue::FrozenVoid;
        } else if (t == VoxelTag::Load || t == VoxelTag::Fixture) {
          eff[grid.index(i, j, k)] = MaskValue::FrozenSolid;
        }
      }
  return eff;
}

// The analysis grid for FEA: FrozenVoid voxels become Empty so they contribute
// no element (excluded from the stiffness); every other voxel keeps its tag. The
// M3.1 void-DOF gate then handles any node left attached only to void.
VoxelGrid analysis_grid_for_mask(const VoxelGrid& grid, const DesignMask& eff) {
  VoxelGrid a = grid;
  for (std::size_t e = 0; e < a.tags.size(); ++e)
    if (eff[e] == MaskValue::FrozenVoid) a.tags[e] = VoxelTag::Empty;
  return a;
}

// Pin the physical density of frozen voxels: FrozenSolid -> 1, FrozenVoid -> 0.
// Active/Empty entries (already the filtered value / 0) are left untouched.
void apply_mask_pins(const DesignMask& eff, std::vector<double>& xphys) {
  for (std::size_t e = 0; e < xphys.size(); ++e) {
    if (eff[e] == MaskValue::FrozenSolid) xphys[e] = 1.0;
    else if (eff[e] == MaskValue::FrozenVoid) xphys[e] = 0.0;
  }
}

// One Optimality-Criteria update restricted to Active voxels. FrozenSolid (x=1)
// and FrozenVoid (x=0) entries of `density` are carried through unchanged; only
// Active voxels move. The volume constraint is enforced on the physical density
// of the Active voxels: sum_active xPhys(x_new) == volume_fraction * n_active
// (the Active budget). `filter` is the mask-aware filter (Active-only), so both
// the compliance and volume sensitivities are already confined to Active voxels.
std::vector<double> oc_update_masked(const VoxelGrid& grid,
                                     const DensityFilter& filter,
                                     const DesignMask& eff,
                                     const std::vector<double>& density,
                                     const std::vector<double>& dcompliance,
                                     double volume_fraction, double move,
                                     double density_min) {
  const std::size_t N = grid.voxel_count();
  const std::vector<double> dc = filter.filter_sensitivity(dcompliance);
  std::vector<double> ones(N, 0.0);
  std::size_t n_active = 0;
  for (std::size_t e = 0; e < N; ++e)
    if (eff[e] == MaskValue::Active) {
      ones[e] = 1.0;
      ++n_active;
    }
  const std::vector<double> dv = filter.filter_sensitivity(ones);
  const double target = volume_fraction * static_cast<double>(n_active);

  // Candidate design for a trial multiplier: Active voxels take the OC step
  // (with move limit + box bounds); frozen voxels keep their pinned x (1 or 0).
  auto candidate = [&](double lambda) {
    std::vector<double> xnew = density;  // preserves FrozenSolid=1, FrozenVoid=0
    for (std::size_t e = 0; e < N; ++e) {
      if (eff[e] != MaskValue::Active) continue;
      const double xe = density[e];
      double be = 0.0;
      if (dv[e] > 0.0) be = -dc[e] / (lambda * dv[e]);
      if (be < 0.0) be = 0.0;
      double xt = xe * std::sqrt(be);
      const double lo = std::max(density_min, xe - move);
      const double hi = std::min(1.0, xe + move);
      if (xt < lo) xt = lo;
      if (xt > hi) xt = hi;
      xnew[e] = xt;
    }
    return xnew;
  };

  // Physical volume of the Active voxels (filter_density is 0 on frozen/empty,
  // so summing the whole field sums the Active voxels only).
  auto phys_vol = [&](const std::vector<double>& xnew) {
    const std::vector<double> xp = filter.filter_density(xnew);
    double v = 0.0;
    for (double val : xp) v += val;
    return v;
  };

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

// Project the Active voxels of a filtered field in place (M6.3). Frozen and
// Empty voxels are left untouched (their physical density is pinned / 0
// separately), mirroring the mask-aware filter's Active-only domain.
void project_active(const DesignMask& eff, std::vector<double>& x, double beta,
                    double eta) {
  for (std::size_t e = 0; e < x.size(); ++e)
    if (eff[e] == MaskValue::Active)
      x[e] = heaviside_project(x[e], beta, eta);
}

// Projected Optimality-Criteria update restricted to Active voxels (M6.3):
// oc_update_masked with the same three locked differences as
// oc_update_projected (derivative chained before the filter transpose, volume
// constraint on the projected Active density, unclamped-dv ratio with
// 0/0 -> hold). `xtilde` is the current mask-aware filtered design.
std::vector<double> oc_update_masked_projected(
    const VoxelGrid& grid, const DensityFilter& filter, const DesignMask& eff,
    const std::vector<double>& density, const std::vector<double>& xtilde,
    const std::vector<double>& dcompliance, double beta, double eta,
    double volume_fraction, double move, double density_min) {
  const std::size_t N = grid.voxel_count();
  std::vector<double> dc_phys(N, 0.0), dproj(N, 0.0);
  std::size_t n_active = 0;
  for (std::size_t e = 0; e < N; ++e)
    if (eff[e] == MaskValue::Active) {
      dproj[e] = heaviside_project_derivative(xtilde[e], beta, eta);
      dc_phys[e] = dcompliance[e] * dproj[e];
      ++n_active;
    }
  const std::vector<double> dc = filter.filter_sensitivity(dc_phys);
  const std::vector<double> dv = filter.filter_sensitivity(dproj);
  const double target = volume_fraction * static_cast<double>(n_active);

  auto candidate = [&](double lambda) {
    std::vector<double> xnew = density;  // preserves FrozenSolid=1, FrozenVoid=0
    for (std::size_t e = 0; e < N; ++e) {
      if (eff[e] != MaskValue::Active) continue;
      const double xe = density[e];
      double be = -dc[e] / (lambda * dv[e]);  // UNCLAMPED dv (locked)
      if (!std::isfinite(be)) be = 1.0;       // 0/0 -> hold this voxel
      if (be < 0.0) be = 0.0;                 // guard rounding
      double xt = xe * std::sqrt(be);
      const double lo = std::max(density_min, xe - move);
      const double hi = std::min(1.0, xe + move);
      if (xt < lo) xt = lo;
      if (xt > hi) xt = hi;
      xnew[e] = xt;
    }
    return xnew;
  };

  // PROJECTED volume of the Active voxels of a candidate (the mask-aware
  // filter is 0 on frozen/empty voxels, which are excluded from the sum).
  auto proj_vol = [&](const std::vector<double>& xnew) {
    const std::vector<double> xp = filter.filter_density(xnew);
    double v = 0.0;
    for (std::size_t e = 0; e < N; ++e)
      if (eff[e] == MaskValue::Active)
        v += heaviside_project(xp[e], beta, eta);
    return v;
  };

  double l1 = 0.0, l2 = 1.0;
  while (l2 < 1e30 && proj_vol(candidate(l2)) > target) l2 *= 2.0;
  for (int it = 0; it < 100 && (l2 - l1) > 1e-6 * (l1 + l2); ++it) {
    const double lmid = 0.5 * (l1 + l2);
    if (proj_vol(candidate(lmid)) > target)
      l1 = lmid;
    else
      l2 = lmid;
  }
  return candidate(0.5 * (l1 + l2));
}

}  // namespace

SimpOptimizeResult simp_optimize(const VoxelGrid& grid, const SimpParams& params,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 const SimpOptions& options,
                                 const DesignMask& mask) {
  validate_params(params);
  if (!(options.volume_fraction > 0.0 && options.volume_fraction <= 1.0))
    throw std::invalid_argument("simp_optimize: volume_fraction must be in (0, 1]");
  if (!(options.move > 0.0))
    throw std::invalid_argument("simp_optimize: move must be > 0");
  if (options.max_iterations < 1)
    throw std::invalid_argument("simp_optimize: max_iterations must be >= 1");
  if (options.change_tol < 0.0)
    throw std::invalid_argument("simp_optimize: change_tol must be >= 0");
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument("simp_optimize: mask size != voxel_count");
  validate_projection_options(options);

  // Load/Fixture -> FrozenSolid, then derive the Active-only filter, the FEA
  // analysis grid (FrozenVoid removed), and the Active-voxel budget.
  const DesignMask eff = effective_mask(grid, mask);
  const DensityFilter filter =
      make_density_filter(grid, options.filter_radius, eff);
  const VoxelGrid analysis = analysis_grid_for_mask(grid, eff);
  const std::vector<StagePlan> plan = build_stage_plan(options);
  const double eta = options.projection_eta;
  double n_active = 0.0;
  for (MaskValue m : eff)
    if (m == MaskValue::Active) n_active += 1.0;

  // Achieved Active-voxel physical volume fraction of a filtered field (the
  // filter is 0 on frozen/empty, so the whole-field sum is the Active sum).
  auto active_volfrac = [&](const std::vector<double>& xphys_active) {
    double vol = 0.0;
    for (double v : xphys_active) vol += v;
    return n_active > 0.0 ? vol / n_active : 0.0;
  };

  // Initial design: Active voxels at the target fraction, FrozenSolid at 1,
  // FrozenVoid at 0, Empty at 0.
  std::vector<double> x(grid.voxel_count(), 0.0);
  for (std::size_t e = 0; e < x.size(); ++e) {
    if (eff[e] == MaskValue::Active) x[e] = options.volume_fraction;
    else if (eff[e] == MaskValue::FrozenSolid) x[e] = 1.0;
    // FrozenVoid / Empty stay 0
  }

  SimpOptimizeResult result;
  result.history.reserve(total_stage_iterations(plan));

  for (const StagePlan& st : plan) {
    bool stage_converged = false;
    for (int it = 0; it < st.iterations; ++it) {
      // M7.0a: cancellation is polled once per OC iteration, at its start (as
      // in the unconstrained overload above).
      if (options.cancel && options.cancel->load()) {
        result.cancelled = true;
        break;
      }
      std::vector<double> xphys = filter.filter_density(x);
      if (st.project) project_active(eff, xphys, st.beta, eta);
      apply_mask_pins(eff, xphys);  // FrozenSolid -> 1, FrozenVoid -> 0
      const SimpCompliance c =
          simp_compliance(analysis, params, xphys, bcs, loads,
                          options.cg_tolerance, options.cg_max_iterations);
      if (!c.cg.converged)
        throw std::runtime_error(
            "simp_optimize: penalized CG solve did not converge");

      std::vector<double> x_new;
      if (st.project) {
        // dproj needs the UNprojected filtered field: recompute it (xphys was
        // projected + pinned in place above).
        const std::vector<double> xtilde = filter.filter_density(x);
        x_new = oc_update_masked_projected(grid, filter, eff, x, xtilde,
                                           c.dcompliance, st.beta, eta,
                                           options.volume_fraction, st.move,
                                           params.density_min);
      } else {
        x_new = oc_update_masked(grid, filter, eff, x, c.dcompliance,
                                 options.volume_fraction, st.move,
                                 params.density_min);
      }

      double change = 0.0;
      for (std::size_t e = 0; e < x.size(); ++e)
        change = std::max(change, std::fabs(x_new[e] - x[e]));

      x = x_new;
      if (result.iterations == 0) result.initial_compliance = c.compliance;
      ++result.iterations;
      std::vector<double> xafter = filter.filter_density(x);
      if (st.project) project_active(eff, xafter, st.beta, eta);
      result.history.push_back(
          {c.compliance, change, active_volfrac(xafter)});
      if (options.progress)
        options.progress(result.iterations, c.compliance, change);

      if (change < options.change_tol) {
        stage_converged = true;
        break;
      }
    }
    // Continuation proceeds stage by stage; `converged` reports the LAST one
    // (a cancelled stage never is).
    result.converged = stage_converged;
    if (result.cancelled) break;
  }

  // Self-consistent final state (projected at the final stage's beta when
  // projecting, pins applied to the physical density) via one final solve on
  // the converged field.
  result.design = x;
  result.physical_density = filter.filter_density(x);
  if (plan.back().project)
    project_active(eff, result.physical_density, plan.back().beta, eta);
  std::vector<double> xfinal_unpinned = result.physical_density;
  apply_mask_pins(eff, result.physical_density);
  const SimpCompliance fc =
      simp_compliance(analysis, params, result.physical_density, bcs, loads,
                      options.cg_tolerance, options.cg_max_iterations);
  result.compliance = fc.compliance;
  result.volume_fraction = active_volfrac(xfinal_unpinned);
  return result;
}

// ---------------------------------------------------------------------------
// Multi-variant runner (ROADMAP M3.6). Runs simp_optimize per requested volume
// fraction and extracts a cleaned printable mesh from each result's physical
// density (§5 "marching cubes -> mesh cleanup").

std::vector<double> MultiVariantResult::compliances() const {
  std::vector<double> out;
  out.reserve(variants.size());
  for (const SimpVariant& v : variants) out.push_back(v.optimization.compliance);
  return out;
}

MultiVariantResult simp_optimize_variants(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads,
    const SimpOptions& options, const std::vector<double>& volume_fractions,
    double iso) {
  if (volume_fractions.empty())
    throw std::invalid_argument(
        "simp_optimize_variants: volume_fractions must be non-empty");
  for (double vf : volume_fractions)
    if (!(vf > 0.0 && vf <= 1.0))
      throw std::invalid_argument(
          "simp_optimize_variants: each volume fraction must be in (0, 1]");

  MultiVariantResult result;
  result.variants.reserve(volume_fractions.size());
  for (double vf : volume_fractions) {
    SimpOptions opt = options;
    opt.volume_fraction = vf;  // each variant targets its own fraction

    SimpVariant variant;
    variant.requested_volume_fraction = vf;
    variant.optimization = simp_optimize(grid, params, bcs, loads, opt);
    // §5 pipeline: marching cubes on the final physical density, then mesh
    // cleanup (keep the largest component) down to the single printable body.
    variant.mesh = keep_largest_component(
        marching_cubes(grid, variant.optimization.physical_density, iso));
    result.variants.push_back(std::move(variant));
  }
  return result;
}

}  // namespace topopt
