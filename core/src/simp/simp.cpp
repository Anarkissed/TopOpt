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
#include <memory>
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

// The MMA updater supports the plain compliance loop (M7.mma.1) and, since the
// switchover (M7.mma.4), the passive-region MASKED loop that minimize_plastic
// drives — but NOT a Heaviside projection schedule. The projected formulation
// is the OC-locked Gate-V2 chain (benchmarks.json "formulation_locked"); an
// MMA+projection path is a separate future task, so combining the two is
// rejected here (in both overloads) rather than silently falling back to OC.
void validate_updater_options(const SimpOptions& o) {
  if (o.updater == SimpUpdater::MMA && !o.projection.empty())
    throw std::invalid_argument(
        "simp_optimize: MMA updater does not support a Heaviside projection "
        "schedule; use OC or clear options.projection");
}

// Validate the MMA Heaviside-projection opt-in (handoff 114). This is the
// MMA-CORRECT projection path — SEPARATE from the OC-locked `projection`
// schedule (validate_updater_options above still rejects that under MMA, so the
// projection-gate contract is untouched). The two mechanisms are mutually
// exclusive and MMA-only. When mma_projection is false (default) nothing here
// fires and the run is byte-identical.
void validate_mma_projection_options(const SimpOptions& o) {
  if (!o.mma_projection) return;
  if (o.updater != SimpUpdater::MMA)
    throw std::invalid_argument(
        "simp_optimize: mma_projection requires the MMA updater");
  if (!o.projection.empty())
    throw std::invalid_argument(
        "simp_optimize: mma_projection and a Heaviside projection schedule "
        "(options.projection) are mutually exclusive; set only one");
  if (!(o.projection_eta > 0.0 && o.projection_eta < 1.0))
    throw std::invalid_argument(
        "simp_optimize: projection_eta must be in (0, 1)");
  if (!(o.mma_projection_beta0 > 0.0) || !std::isfinite(o.mma_projection_beta0))
    throw std::invalid_argument(
        "simp_optimize: mma_projection_beta0 must be finite and > 0");
  if (!(o.mma_projection_beta_max >= o.mma_projection_beta0) ||
      !std::isfinite(o.mma_projection_beta_max))
    throw std::invalid_argument(
        "simp_optimize: mma_projection_beta_max must be finite and "
        ">= mma_projection_beta0");
}

// Whether the MMA Heaviside-projection continuation path is active for this run.
// The default (mma_projection == false) is false, so every existing MMA run
// takes the unchanged grayscale branch.
bool mma_projection_active(const SimpOptions& o) {
  return o.updater == SimpUpdater::MMA && o.mma_projection;
}

// Move limit for the MMA continuation stage at sharpness `beta` (handoff 114).
// High-beta Heaviside stages OSCILLATE (structure-splitting) under an undamped
// move — the SAME failure the locked OC continuation schedule damps by dropping
// move to 0.1 at beta 16 and 0.05 at beta 32. Mirror that here:
//   move_eff = move * min(1, 8/beta)
// so beta <= 8 keeps the full move, beta = 16 halves it (0.1 from a 0.2 base)
// and beta = 32 quarters it (0.05) — the exact OC-schedule damping — with a
// smooth 1/beta taper for any intermediate/higher cap. Without this the final
// stage churns and never plateaus (measured: it runs to the iteration cap).
double mma_continuation_move(double move, double beta) {
  const double damp = beta > 8.0 ? 8.0 / beta : 1.0;
  return move * damp;
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

// Warm-start (handoff 110): build the initial design x0 from a RAW seed density
// field. (1) rescale the seed's MEAN over the design set (is_design[e] != 0) to
// `target_vf` by a uniform multiplicative factor, (2) clamp each design entry to
// [density_min, 1], (3) apply ONE pass of the loop's own `filter`, so x0 is a
// filtered field — consistent with what the optimizer expects — rather than a raw
// upsample/rescale that may carry grid- or clamp-scale steps the filter cannot
// represent. Non-design voxels contribute 0 to the pre-filter field (the filter
// excludes them anyway); the caller reapplies any solid pins afterwards. A
// (near-)zero-mean seed cannot be rescaled and falls back to a uniform design at
// `target_vf` (still filtered) so x0 is always well-defined and deterministic.
std::vector<double> warm_start_design(const std::vector<double>& seed,
                                      const DensityFilter& filter,
                                      const std::vector<char>& is_design,
                                      double target_vf, double density_min) {
  double sum = 0.0;
  std::size_t n = 0;
  for (std::size_t e = 0; e < seed.size(); ++e)
    if (is_design[e]) { sum += seed[e]; ++n; }
  const double mean = n > 0 ? sum / static_cast<double>(n) : 0.0;
  std::vector<double> raw(seed.size(), 0.0);
  if (mean > 1e-12) {
    const double scale = target_vf / mean;
    for (std::size_t e = 0; e < seed.size(); ++e)
      if (is_design[e])
        raw[e] = std::min(1.0, std::max(density_min, scale * seed[e]));
  } else {
    for (std::size_t e = 0; e < seed.size(); ++e)
      if (is_design[e]) raw[e] = target_vf;
  }
  return filter.filter_density(raw);
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
                               double tolerance, int max_iterations,
                               const FeaSolution* initial_guess,
                               PenalizedSolver* solver,
                               SolverKind solver_kind) {
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
  if (solver_kind == SolverKind::MultigridCG_Matfree) {
    // Matrix-free multigrid (handoff 078 + design-box on-device fix): the
    // memory-lean path — the assembled fine K (which OOMs on the design box) is
    // never built. Solves the identical system to the same tolerance; stateless,
    // so the cached PenalizedSolver / warm start are bypassed. out.cg.used_multigrid
    // reports whether MG ran or it fell back to the matrix-free Jacobi-CG.
    out.solution = fea_solve_mgcg_matfree(grid, elem_youngs, params.poisson, bcs,
                                          loads, tolerance, max_iterations,
                                          &out.cg);
  } else if (solver_kind == SolverKind::MultigridCG) {
    // Opt-in accelerator (handoff 073): the geometric-multigrid-preconditioned
    // CG solves the identical system to the same tolerance. It is stateless, so
    // the cached PenalizedSolver fast path and warm start are bypassed;
    // out.cg.used_multigrid reports whether MG ran or it fell back to Jacobi-CG.
    out.solution = fea_solve_mgcg(grid, elem_youngs, params.poisson, bcs, loads,
                                  tolerance, max_iterations, &out.cg);
  } else if (solver != nullptr && solver->usable()) {
    // Cached fast path: rescale the pre-reduced operator + internal warm start.
    out.solution =
        solver->solve(elem_youngs, tolerance, max_iterations, &out.cg);
  } else {
    out.solution = fea_solve_cg(grid, elem_youngs, params.poisson, bcs, loads,
                                tolerance, max_iterations, &out.cg,
                                initial_guess);
  }

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

double physical_filter_radius(double min_feature_mm, double spacing,
                              double floor_voxels) {
  if (!std::isfinite(min_feature_mm) || !(min_feature_mm > 0.0))
    throw std::invalid_argument(
        "physical_filter_radius: min_feature_mm must be finite and > 0");
  if (!std::isfinite(spacing) || !(spacing > 0.0))
    throw std::invalid_argument(
        "physical_filter_radius: spacing must be finite and > 0");
  if (!std::isfinite(floor_voxels) || !(floor_voxels > 0.0))
    throw std::invalid_argument(
        "physical_filter_radius: floor_voxels must be finite and > 0");
  const double rmin_voxels = min_feature_mm / spacing;
  return rmin_voxels < floor_voxels ? floor_voxels : rmin_voxels;
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
//
// `mma_continuation` (handoff 114) marks the SINGLE dynamic stage of the MMA
// Heaviside-projection path: unlike the fixed OC `projection` schedule (one
// StagePlan per beta stage, `iterations` fixed), the MMA path is one stage whose
// beta advances by continuation inside the loop (starting at beta0, doubling on
// a plateau up to beta_max) and whose `iterations` is the whole-run safety cap.
struct StagePlan {
  bool project = false;
  double beta = 0.0;
  double move = 0.2;
  int iterations = 0;
  bool mma_continuation = false;
};

std::vector<StagePlan> build_stage_plan(const SimpOptions& options) {
  std::vector<StagePlan> plan;
  if (mma_projection_active(options)) {
    // One continuation stage; beta is handled dynamically in the loop (starting
    // at beta0), so StagePlan::beta is unused here. `iterations` is the global
    // safety cap that backstops the plateau-driven continuation.
    plan.push_back({false, 0.0, options.move, options.max_iterations, true});
  } else if (options.projection.empty()) {
    plan.push_back({false, 0.0, options.move, options.max_iterations, false});
  } else {
    plan.reserve(options.projection.size());
    for (const ProjectionStage& ps : options.projection)
      plan.push_back({true, ps.beta, ps.move, ps.iterations, false});
  }
  return plan;
}

std::size_t total_stage_iterations(const std::vector<StagePlan>& plan) {
  std::size_t n = 0;
  for (const StagePlan& st : plan) n += static_cast<std::size_t>(st.iterations);
  return n;
}

}  // namespace

// Objective-plateau detector (handoff 086-mma-plateau). Public + non-namespaced
// so the anti-early-termination guard can unit-test it directly against a
// hand-built non-monotone compliance curve. See simp.hpp for the rationale.
bool mma_objective_plateau(const std::vector<double>& c, int window,
                           double rel_tol, double min_drop,
                           int min_flat_windows) {
  if (window <= 0) return false;
  const int n = static_cast<int>(c.size());
  if (n < window + 1) return false;
  // Running minimum over the whole history so far, and over the history
  // EXCLUDING the trailing `window` samples. Non-monotone spikes never lower a
  // running minimum, so the difference is exactly the compliance improvement the
  // last `window` iterations actually delivered.
  double best_now = c[0];
  for (int i = 1; i < n; ++i)
    if (c[i] < best_now) best_now = c[i];
  // Progress gate: require real descent from the uniform-start compliance c[0]
  // before a plateau can fire. Without this, an early spike-heavy phase (whose
  // spikes sit ABOVE c[0], so the running minimum stays pinned at c[0]) reads as
  // a plateau and fires immediately — keeping a near-uniform design. See the
  // header for the measured vf=0.20 failure this prevents.
  if (min_drop > 0.0 && !(best_now <= c[0] * (1.0 - min_drop))) {
    // FLATNESS ESCAPE (handoff 128, guarded). The gate is closed (total descent
    // < min_drop). Normally that vetoes the plateau — but a run whose objective is
    // flat almost from the start would then cap-walk forever (125). Allow the gate
    // to be bypassed IFF the running minimum has been essentially flat across the
    // last `min_flat_windows` full windows: measure the running-min improvement
    // over the trailing `min_flat_windows * window` samples and require it below
    // rel_tol. This is a strictly STRONGER flatness demand than the single-window
    // test below (a wider trailing window can only show more improvement, never
    // less, since the running minimum is monotone), so it can never fire before
    // the gated detector would once the gate opens — it only rescues the
    // gate-never-opens case. It keys purely on flatness (never a bare iteration
    // count), so the spike-heavy forming phase — where the running minimum is
    // still moving — cannot trigger it (086 fixtures stay caught).
    bool escape = false;
    if (min_flat_windows > 0) {
      const int flat_span = min_flat_windows * window;
      if (n >= flat_span + 1) {
        double best_before_flat = c[0];
        for (int i = 1; i < n - flat_span; ++i)
          if (c[i] < best_before_flat) best_before_flat = c[i];
        if (best_before_flat > 0.0) {
          const double flat_improve = (best_before_flat - best_now) / best_before_flat;
          escape = flat_improve < rel_tol;
        }
      }
    }
    if (!escape) return false;
  }
  double best_prev = c[0];
  for (int i = 1; i < n - window; ++i)
    if (c[i] < best_prev) best_prev = c[i];
  if (!(best_prev > 0.0)) return false;  // cannot form a relative ratio
  const double rel_improve = (best_prev - best_now) / best_prev;
  return rel_improve < rel_tol;
}

// Rung-infeasibility detector (handoff 131). Public + non-namespaced so it can be
// unit-tested directly against a hand-built history — including the REAL
// per-iteration rows of the 96³ run that motivated it. See simp.hpp for the
// signature, the evidence and the calibration.
bool rung_infeasible(const std::vector<double>& c, const std::vector<int>& cg,
                     double ratio, double cg_blowup, double flat_tol,
                     int window) {
  if (window <= 0) return false;  // disarmed
  if (!(std::isfinite(ratio) && ratio > 0.0)) return false;
  if (!(std::isfinite(cg_blowup) && cg_blowup > 0.0)) return false;
  if (!(std::isfinite(flat_tol) && flat_tol >= 0.0)) return false;
  if (c.size() != cg.size()) return false;
  const int n = static_cast<int>(c.size());
  // A baseline needs at least one sample BEFORE the window: the compliance
  // baseline is the rung's starting value c[0], and the CG baseline is the minimum
  // over the pre-window prefix. So the earliest possible verdict is iteration
  // window + 1.
  if (n < window + 1) return false;
  if (!(std::isfinite(c[0]) && c[0] > 0.0)) return false;  // no ratio to form

  // (2)'s baseline: the CHEAPEST solve before the window. Taking the minimum (not
  // c/cg[0]) makes the test insensitive to a first iteration that happened to be
  // expensive — on the evidence, rung 0's iteration 1 cost 11977 CG iterations
  // (a multigrid stagnation fallback) against a steady-state 4551, and keying off
  // that one sample would have hidden a real 2.6x blow-up.
  int cg_min_prefix = cg[0];
  for (int i = 1; i < n - window; ++i)
    if (cg[i] < cg_min_prefix) cg_min_prefix = cg[i];
  if (cg_min_prefix <= 0) return false;  // no CG record -> cannot judge distress

  const double c_bar = ratio * c[0];
  const double cg_bar = cg_blowup * static_cast<double>(cg_min_prefix);
  // (4): EVERY one of the trailing `window` iterations must show BOTH (1) and (2).
  // One recovering iteration inside the window clears the verdict — a rung that
  // spikes and comes back is not infeasible, it is optimizing.
  double win_lo = c[n - window];
  double win_hi = c[n - window];
  for (int i = n - window; i < n; ++i) {
    if (!std::isfinite(c[i])) return false;
    if (!(c[i] >= c_bar)) return false;
    if (!(static_cast<double>(cg[i]) >= cg_bar)) return false;
    win_lo = std::min(win_lo, c[i]);
    win_hi = std::max(win_hi, c[i]);
  }
  // (3): the objective is FROZEN across the window — the design no longer moves it
  // at all. This is what separates a severed structure from a violent forming
  // transient that is still optimizing (see simp.hpp: 3.8e-7 vs 1.2 measured).
  if (!(win_lo > 0.0)) return false;  // cannot form a relative spread
  if (!((win_hi - win_lo) / win_lo <= flat_tol)) return false;
  return true;
}

// Design-region discreteness M_nd (handoff 123). Public + non-namespaced so the
// conditional-projection gate (minimize_plastic) and its test share ONE
// definition. See simp.hpp for the design-set rationale (solid AND mask-Active).
double design_discreteness_mnd(const VoxelGrid& grid,
                               const std::vector<double>& density,
                               const DesignMask& mask) {
  if (density.size() != grid.voxel_count() ||
      mask.size() != grid.voxel_count())
    throw std::invalid_argument(
        "design_discreteness_mnd: density/mask size != grid.voxel_count()");
  double acc = 0.0;
  std::size_t n = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!grid.solid(i, j, k) || mask[e] != MaskValue::Active) continue;
        const double r = density[e];
        acc += 4.0 * r * (1.0 - r);
        ++n;
      }
  return n > 0 ? acc / static_cast<double>(n) : 0.0;
}

namespace {

// The per-iteration termination test, shared by both simp_optimize overloads.
// MMA (fixed volume) stops on an objective plateau (handoff 086-mma-plateau);
// OC / projected keeps the design-space `change_tol` test byte-identically. MMA
// rejects a projection schedule, so an MMA run is always a single non-projected
// stage and `history` is exactly that stage's contiguous compliance curve.
bool stage_should_stop(const SimpOptions& options,
                       const std::vector<SimpIteration>& history,
                       double change) {
  if (options.updater == SimpUpdater::MMA && options.mma_plateau_window > 0) {
    std::vector<double> curve;
    curve.reserve(history.size());
    for (const SimpIteration& h : history) curve.push_back(h.compliance);
    return mma_objective_plateau(curve, options.mma_plateau_window,
                                 options.mma_plateau_tol,
                                 options.mma_plateau_min_drop,
                                 options.mma_plateau_flat_windows);
  }
  return change < options.change_tol;
}

// Handoff 114 — the MMA objective-plateau detector's verdict at the current
// iteration, for the per-iteration observability record (SimpIterationObservation
// ::plateau). It is exactly the predicate stage_should_stop consults for MMA (so
// the iteration it first returns true on is the plateau-stop iteration), and
// false for the OC / projected path where plateau termination does not apply.
// Read-only: builds a throwaway compliance curve from the recorded history.
bool observe_plateau(const SimpOptions& options,
                     const std::vector<SimpIteration>& history) {
  if (options.updater != SimpUpdater::MMA || options.mma_plateau_window <= 0)
    return false;
  std::vector<double> curve;
  curve.reserve(history.size());
  for (const SimpIteration& h : history) curve.push_back(h.compliance);
  return mma_objective_plateau(curve, options.mma_plateau_window,
                               options.mma_plateau_tol,
                               options.mma_plateau_min_drop,
                               options.mma_plateau_flat_windows);
}

// Handoff 131 — the rung-infeasibility verdict at the current iteration, for both
// the per-iteration observability record (SimpIterationObservation::infeasible)
// and the loop's fast-fail stop. It is exactly the predicate `rung_infeasible`,
// fed this run's recorded compliance history and the parallel per-iteration CG
// record, so the iteration it first returns true on is the iteration the run ends
// on. Read-only: builds a throwaway compliance curve, touches nothing.
bool observe_infeasible(const SimpOptions& options,
                        const std::vector<SimpIteration>& history,
                        const std::vector<int>& cg_history) {
  if (options.infeasible_window <= 0) return false;  // disarmed: skip the scan
  std::vector<double> curve;
  curve.reserve(history.size());
  for (const SimpIteration& h : history) curve.push_back(h.compliance);
  return rung_infeasible(curve, cg_history, options.infeasible_compliance_ratio,
                         options.infeasible_cg_blowup,
                         options.infeasible_flat_tol,
                         options.infeasible_window);
}

// Adaptive early CG tolerance (handoff 128; see SimpOptions::cg_tolerance_loose).
// Returns the tolerance the INTERIOR / trajectory penalized solve should use this
// iteration, given the design's max|Δρ| from the PREVIOUS iteration (a
// deterministic function of the recorded history — no wall clock, no randomness).
// Disabled (loose <= tight) => always the tight cg_tolerance, so the default path
// is byte-identical. Enabled => geometric interpolation between loose (design
// moving at/over the move limit) and tight (design settled), so a fast-moving
// early design gets a cheap approximate solve and a settling design tightens back
// toward the certified tolerance. The accept/final solve never calls this.
double adaptive_traj_cg_tol(const SimpOptions& options, double prev_change) {
  const double tight = options.cg_tolerance;
  const double loose = options.cg_tolerance_loose;
  if (!(loose > tight)) return tight;  // disabled or degenerate -> always tight
  const double ref = options.move > 0.0 ? options.move : 0.2;
  double frac = prev_change / ref;     // 1 at/above the move limit, 0 when still
  if (frac < 0.0) frac = 0.0;
  if (frac > 1.0) frac = 1.0;
  // tight^(1-frac) * loose^frac, i.e. log-linear between the two tolerances.
  return tight * std::pow(loose / tight, frac);
}

// ---------------------------------------------------------------------------
// MMA updater (ROADMAP M7.mma.1), Svanberg, "The method of moving asymptotes -
// a new method for structural optimization", Int. J. Numer. Methods Eng. 24
// (1987) 359-373. Compliance objective + a single volume constraint, as a
// drop-in alternative to oc_update: it consumes the SAME inputs (the physical-
// space compliance sensitivity, the volume-fraction target, the move limit) and
// enforces the SAME volume constraint on the filtered density, but replaces the
// multiplicative OC step with MMA's convex separable subproblem, solved through
// its dual (1-D here since there is a single constraint, m = 1).

// Persistent MMA state across the iterations of one simp_optimize run: the
// previous two designs and the current moving asymptotes L_j, U_j. All vectors
// are grid-indexed (size voxel_count()); only design (solid) voxels carry
// meaningful values.
struct MmaState {
  std::vector<double> xold1;  // design at iteration k-1
  std::vector<double> xold2;  // design at iteration k-2
  std::vector<double> low;    // lower asymptotes L_j
  std::vector<double> upp;    // upper asymptotes U_j
};

// One MMA design update. `st` carries the asymptotes + last two iterates across
// calls; `mma_iter` is the 1-based MMA iteration number (asymptotes are
// initialised for iter <= 2 and adapted afterwards). Constants follow the
// widely-used mmasub reference and the 1987 paper: asyinit = 0.5 (initial
// asymptote half-span, as a fraction of the x-range), asyincr = 1.2 /
// asydecr = 0.7 (asymptote grow/shrink on non-oscillating / oscillating moves),
// albefa = 0.1 (fraction keeping the move box strictly inside the asymptotes),
// raa0 = 1e-5 (the small positive term guaranteeing p, q > 0). The move limit
// reuses `move` as a fraction of xrange = xmax - xmin, matching oc_update so the
// two updaters are directly comparable at the same move.
std::vector<double> mma_update(MmaState& st, int mma_iter, const VoxelGrid& grid,
                               const DensityFilter& filter,
                               const std::vector<double>& density,
                               const std::vector<double>& dcompliance,
                               double volume_fraction, double move,
                               double density_min) {
  const std::size_t N = grid.voxel_count();

  // Chain rule, exactly as oc_update: filter the physical-space compliance
  // sensitivity and the unit volume sensitivity into design space (H is
  // symmetric). dc <= 0 (more material lowers compliance); dv >= 0.
  std::vector<double> dc = filter.filter_sensitivity(dcompliance);
  std::vector<double> ones(N, 0.0);
  std::vector<std::size_t> dof;  // design (solid) voxel indices
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) {
          const std::size_t e = grid.index(i, j, k);
          ones[e] = 1.0;
          dof.push_back(e);
        }
  const std::vector<double> dv = filter.filter_sensitivity(ones);
  const double target = volume_fraction * static_cast<double>(dof.size());

  // Scale-invariance (ROADMAP M7.mma.4): normalize the compliance sensitivity to
  // O(1) so the FIXED raa0 regularizer below stays negligible regardless of the
  // LOAD magnitude. The minimum-compliance topology is invariant to the load
  // scale, but dc scales as load^2; without this, a tiny self-weight load (real
  // minimize_plastic runs have compliance ~1e-8) lets raa0 (1e-5) swamp dc, so
  // p0/q0 are driven by the regularizer, not the objective, and MMA converges to
  // a load-scale-DEPENDENT, much worse design (measured: rel > 100% vs OC at
  // production gravity, ~0.5% here). Scaling dc by a positive constant leaves the
  // MMA subproblem optimum unchanged — the dual multiplier absorbs it — so this
  // only fixes the raa0 balance; the rmin-2.5 OC parity is preserved.
  double dc_scale = 0.0;
  for (std::size_t e : dof) dc_scale = std::max(dc_scale, std::fabs(dc[e]));
  if (dc_scale > 0.0)
    for (std::size_t e : dof) dc[e] /= dc_scale;

  // Current constraint value g0 = V(x) - target. The filtered volume is linear
  // in x (V(x) = sum_e xPhys_e), so summing filter_density(x) gives V(x).
  const std::vector<double> xphys = filter.filter_density(density);
  double vol = 0.0;
  for (double v : xphys) vol += v;
  const double g0 = vol - target;

  const double xmin = density_min, xmax = 1.0, xrange = xmax - xmin;
  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes L_j, U_j.
  for (std::size_t e : dof) {
    const double xe = density[e];
    if (mma_iter <= 2) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      // Oscillation detector: sign of (x^k - x^{k-1})(x^{k-1} - x^{k-2}).
      const double s = (xe - st.xold1[e]) * (st.xold1[e] - st.xold2[e]);
      const double gamma = (s < 0.0) ? asydecr : (s > 0.0) ? asyincr : 1.0;
      double L = xe - gamma * (st.xold1[e] - st.low[e]);
      double U = xe + gamma * (st.upp[e] - st.xold1[e]);
      // Keep each asymptote within [0.01, 10] * xrange of the current point.
      L = std::min(L, xe - 0.01 * xrange);
      L = std::max(L, xe - 10.0 * xrange);
      U = std::max(U, xe + 0.01 * xrange);
      U = std::min(U, xe + 10.0 * xrange);
      st.low[e] = L;
      st.upp[e] = U;
    }
  }

  // 2. Separable convex approximation coefficients and the move box [alpha, beta].
  std::vector<double> p0(N, 0.0), q0(N, 0.0), p1(N, 0.0), q1(N, 0.0);
  std::vector<double> alpha(N, 0.0), beta(N, 0.0);
  double b = -g0;  // b = sum_j(p1/ux1 + q1/xl1) - g0
  for (std::size_t e : dof) {
    const double xe = density[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dc[e], 0.0), dcm = std::max(-dc[e], 0.0);
    const double dvp = std::max(dv[e], 0.0), dvm = std::max(-dv[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    p1[e] = ux1 * ux1 * (1.001 * dvp + 0.001 * dvm + raa0 / xrange);
    q1[e] = xl1 * xl1 * (0.001 * dvp + 1.001 * dvm + raa0 / xrange);
    b += p1[e] / ux1 + q1[e] / xl1;
    alpha[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    beta[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
  }

  // 3. Dual solve for the single volume constraint. For a trial multiplier
  // lambda >= 0 the primal minimiser of the separable subproblem is closed form:
  //   x_j(lambda) = ( sqrt(p0+lambda*p1) L_j + sqrt(q0+lambda*q1) U_j )
  //               / ( sqrt(p0+lambda*p1) + sqrt(q0+lambda*q1) )   (clamped to box).
  auto candidate = [&](double lambda) {
    std::vector<double> xnew(N, 0.0);
    for (std::size_t e : dof) {
      const double pl = std::sqrt(p0[e] + lambda * p1[e]);
      const double ql = std::sqrt(q0[e] + lambda * q1[e]);
      double xt = (pl * st.low[e] + ql * st.upp[e]) / (pl + ql);
      if (xt < alpha[e]) xt = alpha[e];
      if (xt > beta[e]) xt = beta[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  // The approximate constraint value g1(x) = sum_j(p1/(U-x) + q1/(x-L)) - b;
  // it decreases monotonically in lambda, so bisect for g1 = 0 (KKT: lambda >= 0,
  // g1 <= 0, complementarity). If the unconstrained optimum is already feasible,
  // lambda stays 0.
  auto gval = [&](const std::vector<double>& x) {
    double s = 0.0;
    for (std::size_t e : dof)
      s += p1[e] / (st.upp[e] - x[e]) + q1[e] / (x[e] - st.low[e]);
    return s - b;
  };
  double lambda = 0.0;
  if (gval(candidate(0.0)) > 0.0) {
    double l1 = 0.0, l2 = 1.0;
    while (l2 < 1e30 && gval(candidate(l2)) > 0.0) l2 *= 2.0;
    for (int it = 0; it < 100 && (l2 - l1) > 1e-9 * (1.0 + l1 + l2); ++it) {
      const double lmid = 0.5 * (l1 + l2);
      if (gval(candidate(lmid)) > 0.0)
        l1 = lmid;
      else
        l2 = lmid;
    }
    lambda = 0.5 * (l1 + l2);
  }
  std::vector<double> xnew = candidate(lambda);

  // 4. Roll the history forward (xold2 <- xold1 <- x). After iteration 1 xold2
  // stays empty; the asymptote branch only reads xold1/xold2 for mma_iter >= 3,
  // by which point both are full grid-sized vectors.
  st.xold2 = st.xold1;
  st.xold1 = density;
  return xnew;
}

// One MMA design update with a Heaviside projection (handoff 114). The MMA-
// correct analogue of oc_update_projected: it is mma_update with the projection
// chain-rule folded into the sensitivities the subproblem consumes, so the SAME
// moving-asymptote machinery, convex separable approximation and 1-D dual
// bisection run — only the gradients and the constraint VALUE change:
//   * the compliance sensitivity chains the projection derivative BEFORE the
//     filter transpose: dc/dx = H^T( (dc/drho_bar) * drho_bar/drho_tilde );
//   * the volume-constraint sensitivity is dV/dx = H^T( drho_bar/drho_tilde )
//     (the PROJECTED volume's gradient), replacing mma_update's H^T(ones);
//   * the current constraint value g0 = V_projected(x) - target, where
//     V_projected = sum_e rho_bar(filter(x)_e) over design voxels (the volume
//     constraint sees the PROJECTED density — what prints).
// `xtilde` is the current filtered design filter_density(density); `beta`/`eta`
// are this stage's projection parameters. As in mma_update the compliance
// sensitivity is normalized to O(1) so the fixed raa0 stays negligible under any
// load scale (the dual multiplier absorbs the positive scaling). With
// beta -> 0 / eta = 0.5 the projection derivative -> a constant and the update
// approaches plain mma_update; it is a strict superset, never taken unless
// mma_projection is set.
std::vector<double> mma_update_projected(
    MmaState& st, int mma_iter, const VoxelGrid& grid,
    const DensityFilter& filter, const std::vector<double>& density,
    const std::vector<double>& xtilde, const std::vector<double>& dcompliance,
    double beta, double eta, double volume_fraction, double move,
    double density_min) {
  const std::size_t N = grid.voxel_count();

  // Projection chain-rule prep: dproj = drho_bar/drho_tilde on the filtered
  // field, the compliance sensitivity times dproj, and the design set.
  std::vector<double> dc_phys(N, 0.0), dproj(N, 0.0);
  std::vector<std::size_t> dof;  // design (solid) voxel indices
  double vol_proj = 0.0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) {
          const std::size_t e = grid.index(i, j, k);
          dproj[e] = heaviside_project_derivative(xtilde[e], beta, eta);
          dc_phys[e] = dcompliance[e] * dproj[e];
          vol_proj += heaviside_project(xtilde[e], beta, eta);
          dof.push_back(e);
        }
  // Chain rule into design space (H symmetric): both sensitivities carry the
  // projection factor, then transpose through the filter.
  std::vector<double> dc = filter.filter_sensitivity(dc_phys);
  const std::vector<double> dv = filter.filter_sensitivity(dproj);
  const double target = volume_fraction * static_cast<double>(dof.size());

  // Scale-invariance (as in mma_update): normalize dc to O(1) so raa0 stays
  // negligible regardless of the load magnitude; the dual absorbs the scaling.
  double dc_scale = 0.0;
  for (std::size_t e : dof) dc_scale = std::max(dc_scale, std::fabs(dc[e]));
  if (dc_scale > 0.0)
    for (std::size_t e : dof) dc[e] /= dc_scale;

  // Constraint value on the PROJECTED density (what prints), not the filtered
  // fog: g0 = V_projected(x) - target.
  const double g0 = vol_proj - target;

  const double xmin = density_min, xmax = 1.0, xrange = xmax - xmin;
  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes L_j, U_j (identical rule to mma_update).
  for (std::size_t e : dof) {
    const double xe = density[e];
    if (mma_iter <= 2) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      const double s = (xe - st.xold1[e]) * (st.xold1[e] - st.xold2[e]);
      const double gamma = (s < 0.0) ? asydecr : (s > 0.0) ? asyincr : 1.0;
      double L = xe - gamma * (st.xold1[e] - st.low[e]);
      double U = xe + gamma * (st.upp[e] - st.xold1[e]);
      L = std::min(L, xe - 0.01 * xrange);
      L = std::max(L, xe - 10.0 * xrange);
      U = std::max(U, xe + 0.01 * xrange);
      U = std::min(U, xe + 10.0 * xrange);
      st.low[e] = L;
      st.upp[e] = U;
    }
  }

  // 2. Separable convex coefficients + move box (identical form to mma_update).
  std::vector<double> p0(N, 0.0), q0(N, 0.0), p1(N, 0.0), q1(N, 0.0);
  std::vector<double> alpha(N, 0.0), beta_box(N, 0.0);
  double b = -g0;
  for (std::size_t e : dof) {
    const double xe = density[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dc[e], 0.0), dcm = std::max(-dc[e], 0.0);
    const double dvp = std::max(dv[e], 0.0), dvm = std::max(-dv[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    p1[e] = ux1 * ux1 * (1.001 * dvp + 0.001 * dvm + raa0 / xrange);
    q1[e] = xl1 * xl1 * (0.001 * dvp + 1.001 * dvm + raa0 / xrange);
    b += p1[e] / ux1 + q1[e] / xl1;
    alpha[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    beta_box[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
  }

  // 3. Dual solve for the single volume constraint (identical to mma_update).
  auto candidate = [&](double lambda) {
    std::vector<double> xnew(N, 0.0);
    for (std::size_t e : dof) {
      const double pl = std::sqrt(p0[e] + lambda * p1[e]);
      const double ql = std::sqrt(q0[e] + lambda * q1[e]);
      double xt = (pl * st.low[e] + ql * st.upp[e]) / (pl + ql);
      if (xt < alpha[e]) xt = alpha[e];
      if (xt > beta_box[e]) xt = beta_box[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  auto gval = [&](const std::vector<double>& x) {
    double s = 0.0;
    for (std::size_t e : dof)
      s += p1[e] / (st.upp[e] - x[e]) + q1[e] / (x[e] - st.low[e]);
    return s - b;
  };
  double lambda = 0.0;
  if (gval(candidate(0.0)) > 0.0) {
    double l1 = 0.0, l2 = 1.0;
    while (l2 < 1e30 && gval(candidate(l2)) > 0.0) l2 *= 2.0;
    for (int it = 0; it < 100 && (l2 - l1) > 1e-9 * (1.0 + l1 + l2); ++it) {
      const double lmid = 0.5 * (l1 + l2);
      if (gval(candidate(lmid)) > 0.0)
        l1 = lmid;
      else
        l2 = lmid;
    }
    lambda = 0.5 * (l1 + l2);
  }
  std::vector<double> xnew = candidate(lambda);

  st.xold2 = st.xold1;
  st.xold1 = density;
  return xnew;
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
  validate_updater_options(options);  // MMA + projection rejected (M7.mma.1)
  validate_mma_projection_options(options);  // MMA Heaviside opt-in (handoff 114)

  // make_density_filter validates filter_radius > 0.
  const DensityFilter filter = make_density_filter(grid, options.filter_radius);
  const double n_design = static_cast<double>(grid.solid_count());
  const std::vector<StagePlan> plan = build_stage_plan(options);
  const double eta = options.projection_eta;

  // MMA updater state (ROADMAP M7.mma.1). Unused when updater == OC; the plain
  // (unprojected) branch below owns the single continuous MMA iteration count.
  MmaState mma_state;
  int mma_iter = 0;

  // MMA Heaviside beta-continuation state (handoff 114). `mma_beta` is the
  // current sharpness (starts at beta0, doubles on a plateau up to beta_max);
  // `mma_stage_start` marks the result.history index where the current beta
  // stage began, so the plateau detector sees only that stage's compliance
  // curve. Inert unless the plan carries the single mma_continuation stage.
  double mma_beta = options.mma_projection_beta0;
  const double mma_beta_max = options.mma_projection_beta_max;
  std::size_t mma_stage_start = 0;

  // Physical volume fraction of a grid-indexed physical density field.
  auto phys_volfrac = [&](const std::vector<double>& xphys) {
    double vol = 0.0;
    for (double v : xphys) vol += v;
    return n_design > 0.0 ? vol / n_design : 0.0;
  };

  // Initial design: uniform at the target volume fraction on every solid voxel,
  // UNLESS a warm-start seed is supplied (handoff 110). EMPTY initial_design keeps
  // the uniform start byte-for-byte identical to every pre-110 run.
  std::vector<double> x;
  if (options.initial_design.empty()) {
    x = simp_uniform_density(grid, options.volume_fraction);
  } else {
    if (options.initial_design.size() != grid.voxel_count())
      throw std::invalid_argument(
          "simp_optimize: initial_design size != grid.voxel_count()");
    std::vector<char> is_design(grid.voxel_count(), 0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i)
          if (grid.solid(i, j, k)) is_design[grid.index(i, j, k)] = 1;
    x = warm_start_design(options.initial_design, filter, is_design,
                          options.volume_fraction, params.density_min);
  }

  // Persistent solver: the grid, Poisson ratio, BCs and loads are fixed across
  // the run, so this assembles the BC-reduced operator once and per iteration
  // only rescales its values and warm-starts CG (profiling: ~40-50% of a 64^3
  // iteration was redundant reassembly). Falls back to the stateless path (with
  // an explicit warm-start guess) when the BCs are non-homogeneous.
  //
  // Only built for the JacobiCG path: the multigrid solvers bypass the cached
  // solver, and its constructor ASSEMBLES the BC-reduced fine stiffness K — the
  // very ~2 GB / ~7 GB-transient matrix that OOMs on the design box. Constructing
  // it under MultigridCG_Matfree would reintroduce the crash the matrix-free path
  // exists to avoid, so skip it entirely for both multigrid kinds.
  std::unique_ptr<PenalizedSolver> solver;
  if (options.solver == SolverKind::JacobiCG)
    solver = std::make_unique<PenalizedSolver>(grid, params.poisson, bcs, loads);
  const bool use_solver = solver && solver->usable();
  FeaSolution warm;  // fallback warm-start guess (unused when use_solver)

  SimpOptimizeResult result;
  result.history.reserve(total_stage_iterations(plan));

  // Adaptive early CG tolerance (handoff 128): the previous iteration's max|Δρ|,
  // seeded to the move limit so the FIRST trajectory solve (from the uniform/warm
  // start, where an approximate solve is plenty) is loose. Inert unless
  // cg_tolerance_loose > cg_tolerance; then it drives the trajectory tolerance.
  double last_change = options.move;

  // Handoff 131 — the per-iteration CG-iteration record, index-aligned with
  // result.history (one push per completed iteration, right beside it). It is the
  // second half of the rung-infeasibility signature; nothing else reads it.
  std::vector<int> cg_history;
  cg_history.reserve(total_stage_iterations(plan));

  for (const StagePlan& st : plan) {
    bool stage_converged = false;
    for (int it = 0; it < st.iterations; ++it) {
      // M7.0a: cancellation is polled once per OC iteration, at its start, so
      // a cancel request is honoured before the next (expensive) FEA solve.
      if (options.cancel && options.cancel->load()) {
        result.cancelled = true;
        break;
      }
      // The projecting branches (OC `projection` schedule OR the MMA
      // continuation stage) use the analysis density rho_bar = project(filter);
      // for the MMA stage the sharpness is the dynamic `mma_beta`.
      const bool projecting = st.project || st.mma_continuation;
      const double cur_beta = st.mma_continuation ? mma_beta : st.beta;
      const double cur_move =
          st.mma_continuation ? mma_continuation_move(st.move, cur_beta)
                              : st.move;
      std::vector<double> xphys = filter.filter_density(x);
      if (projecting) project_solid(grid, xphys, cur_beta, eta);
      // Trajectory solve: adaptive (loose→tight) tolerance when enabled, else the
      // tight cg_tolerance (byte-identical). The FINAL solve below stays tight.
      const double traj_tol = adaptive_traj_cg_tol(options, last_change);
      const SimpCompliance c = simp_compliance(
          grid, params, xphys, bcs, loads, traj_tol,
          options.cg_max_iterations, warm.u.empty() ? nullptr : &warm,
          use_solver ? solver.get() : nullptr, options.solver);
      if (!use_solver) warm = c.solution;
      if (!c.cg.converged)
        throw std::runtime_error(
            "simp_optimize: penalized CG solve did not converge");

      std::vector<double> x_new;
      if (st.mma_continuation) {
        // MMA + Heaviside projection (handoff 114): the projection-aware MMA
        // subproblem at the current continuation sharpness.
        const std::vector<double> xtilde = filter.filter_density(x);
        x_new = mma_update_projected(mma_state, ++mma_iter, grid, filter, x,
                                     xtilde, c.dcompliance, cur_beta, eta,
                                     options.volume_fraction, cur_move,
                                     params.density_min);
      } else if (st.project) {
        // dproj needs the UNprojected filtered field: recompute it (xphys was
        // projected in place above).
        const std::vector<double> xtilde = filter.filter_density(x);
        x_new = oc_update_projected(grid, filter, x, xtilde, c.dcompliance,
                                    st.beta, eta, options.volume_fraction,
                                    st.move, params.density_min);
      } else if (options.updater == SimpUpdater::MMA) {
        // Plain (unprojected) MMA stage.
        x_new = mma_update(mma_state, ++mma_iter, grid, filter, x, c.dcompliance,
                           options.volume_fraction, st.move, params.density_min);
      } else {
        x_new = oc_update(grid, filter, x, c.dcompliance,
                          options.volume_fraction, st.move,
                          params.density_min);
      }

      double change = 0.0;
      for (std::size_t e = 0; e < x.size(); ++e)
        change = std::max(change, std::fabs(x_new[e] - x[e]));
      last_change = change;  // handoff 128: drives next iter's trajectory CG tol

      x = x_new;
      if (result.iterations == 0) result.initial_compliance = c.compliance;
      ++result.iterations;
      std::vector<double> xafter = filter.filter_density(x);
      if (st.project) project_solid(grid, xafter, st.beta, eta);
      const double vf_now = phys_volfrac(xafter);
      result.history.push_back({c.compliance, change, vf_now});
      cg_history.push_back(c.cg.iterations);  // handoff 131 (index-aligned)
      // Handoff 131 — rung-infeasibility verdict for THIS iteration. Computed
      // before the hooks so the observed row carries the same verdict the loop
      // acts on, and acted on after them so the firing iteration is fully
      // reported (it is the rung's last row).
      const bool infeasible_now =
          observe_infeasible(options, result.history, cg_history);
      if (options.progress)
        options.progress(result.iterations, c.compliance, change);
      // Handoff 114 — per-iteration observability (read-only). The richer record
      // (achieved vf, CG iters, plateau verdict) the CLI iteration CSV needs.
      if (options.observe) {
        SimpIterationObservation obs;
        obs.iteration = result.iterations;
        obs.compliance = c.compliance;
        obs.change = change;
        obs.volume_fraction = vf_now;
        obs.cg_iterations = c.cg.iterations;
        obs.cg_used_multigrid = c.cg.used_multigrid;
        obs.cg_mg_levels = c.cg.mg_levels;
        obs.cg_hier_built = c.cg.hier_built;
        obs.cg_mg_cycles_attempted = c.cg.mg_cycles_attempted;
        obs.cg_recycle_dim = c.cg.recycle_dim;
        obs.cg_recycle_setup_matvecs = c.cg.recycle_setup_matvecs;
        obs.plateau = observe_plateau(options, result.history);
        // Handoff 123 — the continuation β active this iteration (0 when not
        // projecting), so the CSV beta column reflects the sharpening stage.
        obs.beta = projecting ? cur_beta : 0.0;
        obs.infeasible = infeasible_now;  // handoff 131
        options.observe(obs);
      }
      // Playback keyframe: the analysis density as the shape evolves (read-only).
      if (options.keyframe && options.keyframe_stride > 0 &&
          (result.iterations == 1 ||
           result.iterations % options.keyframe_stride == 0))
        options.keyframe(xafter);
      // Handoff 114 — density SNAPSHOT feed: the raw physical field every
      // iteration (the consumer applies its own cadence). No mask on this
      // overload, so xafter IS the physical density. Read-only.
      if (options.density_observer)
        options.density_observer(result.iterations, xafter);

      // Handoff 131 — FAST FAIL. The load path is provably gone (see
      // rung_infeasible): every further iteration would optimize a structure that
      // carries nothing. End the run here, honestly labelled, ahead of any stage /
      // continuation logic — a corpse must not advance beta or "converge".
      if (infeasible_now) {
        result.infeasible = true;
        result.infeasible_iteration = result.iterations;
        break;
      }

      if (st.mma_continuation) {
        // Beta continuation (handoff 114): reuse the 086 plateau detector on the
        // CURRENT beta stage's compliance curve. On a stall, advance beta
        // (double, capped) and re-arm the stage; a stall at the final beta is
        // the run's termination (composes with 086). Resetting the MMA
        // asymptote state lets each sharper stage re-converge cleanly.
        std::vector<double> curve;
        curve.reserve(result.history.size() - mma_stage_start);
        for (std::size_t hi = mma_stage_start; hi < result.history.size(); ++hi)
          curve.push_back(result.history[hi].compliance);
        // The 086 progress gate (min_drop) guards ONLY the first (beta0) stage:
        // its spike-heavy forming phase from the uniform/warm start is what the
        // gate exists to survive. Later stages start from a formed design (no
        // forming spikes) and often improve less than min_drop, so keeping the
        // gate would block their plateau and run the final stage to the cap —
        // use pure flatness (min_drop 0) there.
        const double stage_min_drop =
            (mma_stage_start == 0) ? options.mma_plateau_min_drop : 0.0;
        if (mma_objective_plateau(curve, options.mma_plateau_window,
                                  options.mma_plateau_tol, stage_min_drop,
                                  options.mma_plateau_flat_windows)) {
          if (mma_beta < mma_beta_max) {
            mma_beta = std::min(mma_beta * 2.0, mma_beta_max);
            mma_stage_start = result.history.size();
            mma_state = MmaState{};
            mma_iter = 0;
          } else {
            stage_converged = true;
            break;
          }
        }
      } else if (stage_should_stop(options, result.history, change)) {
        stage_converged = true;
        break;
      }
    }
    // The stage either re-converged (change_tol / plateau) or ran its cap;
    // continuation proceeds either way. The loop is `converged` iff its LAST
    // stage was (a cancelled stage never is).
    result.converged = stage_converged;
    if (result.cancelled || result.infeasible) break;
  }

  // Report a self-consistent final state: physical_density = filter(design)
  // (projected at the final stage's beta when projecting) and compliance =
  // compliance(physical_density) via one final solve on the converged field
  // (so callers/property checks see matching values). For the MMA continuation
  // stage the final sharpness is `mma_beta`.
  result.design = x;
  result.physical_density = filter.filter_density(x);
  if (plan.back().project)
    project_solid(grid, result.physical_density, plan.back().beta, eta);
  else if (plan.back().mma_continuation)
    project_solid(grid, result.physical_density, mma_beta, eta);
  // Handoff 131 — an INFEASIBLE run SKIPS this final recovery solve. Two reasons,
  // both load-bearing: (a) it is the run's most expensive single solve (the TIGHT
  // tolerance against the near-singular operator a severed load path leaves — 43-44k
  // CG iterations on the evidence), and a fast-fail that still pays it is not a
  // fast-fail; (b) it is precisely the solve that can miss its tolerance and THROW,
  // which would replace an honest "rung infeasible" verdict with an exception.
  // `compliance` is then the LAST RECORDED objective — the corpse's flat plateau
  // value, the same number the final CSV row carries — rather than a fresh
  // measurement of the post-step field. With `infeasible` true and `converged`
  // false no caller can read it as an achievement.
  if (result.infeasible) {
    result.compliance =
        result.history.empty() ? 0.0 : result.history.back().compliance;
  } else {
    const SimpCompliance fc = simp_compliance(
        grid, params, result.physical_density, bcs, loads, options.cg_tolerance,
        options.cg_max_iterations, nullptr, use_solver ? solver.get() : nullptr,
        options.solver);
    result.compliance = fc.compliance;
  }
  result.volume_fraction = phys_volfrac(result.physical_density);
  // Final playback keyframe: the converged shape.
  if (options.keyframe && options.keyframe_stride > 0)
    options.keyframe(result.physical_density);
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

// One MMA design update restricted to Active voxels (ROADMAP M7.mma.4 — the
// switchover). The mask-aware analogue of mma_update: FrozenSolid (x=1) and
// FrozenVoid (x=0) entries of `density` are carried through unchanged; only
// Active voxels move, under the single volume constraint on the ACTIVE physical
// density (sum_active xPhys(x_new) == volume_fraction * n_active). `filter` is
// the mask-aware (Active-only) filter, so both the compliance and volume
// sensitivities are already confined to Active voxels. The moving-asymptote
// machinery, convex separable subproblem and 1-D dual bisection are IDENTICAL
// to mma_update (same constants); this only swaps the design set (grid.solid ->
// Active) and preserves the frozen pins, exactly as oc_update_masked does for
// OC. `st`/`mma_iter` persist the asymptotes + last two iterates across calls.
// With an all-Active mask on an all-Interior grid it reproduces mma_update
// bit-for-bit (same design set, no pins), so the switchover leaves an
// all-Active driver run equivalent to the plain MMA loop.
std::vector<double> mma_update_masked(MmaState& st, int mma_iter,
                                      const VoxelGrid& grid,
                                      const DensityFilter& filter,
                                      const DesignMask& eff,
                                      const std::vector<double>& density,
                                      const std::vector<double>& dcompliance,
                                      double volume_fraction, double move,
                                      double density_min) {
  const std::size_t N = grid.voxel_count();

  // Chain rule (mask-aware transpose): filter the physical-space compliance
  // sensitivity and the unit volume sensitivity into Active design space. The
  // Active-only filter makes dc/dv nonzero only on Active voxels. dc <= 0; dv >= 0.
  std::vector<double> dc = filter.filter_sensitivity(dcompliance);
  std::vector<double> ones(N, 0.0);
  std::vector<std::size_t> dof;  // Active (design) voxel indices
  for (std::size_t e = 0; e < N; ++e)
    if (eff[e] == MaskValue::Active) {
      ones[e] = 1.0;
      dof.push_back(e);
    }
  const std::vector<double> dv = filter.filter_sensitivity(ones);
  const double target = volume_fraction * static_cast<double>(dof.size());

  // Scale-invariance (M7.mma.4): normalize the compliance sensitivity to O(1) so
  // the fixed raa0 regularizer stays negligible regardless of the load magnitude
  // (see mma_update for the full rationale — self-weight loads make dc ~1e-8, and
  // an un-normalized raa0 would swamp it and destroy scale-invariance). The
  // subproblem optimum is unchanged by this positive scaling.
  double dc_scale = 0.0;
  for (std::size_t e : dof) dc_scale = std::max(dc_scale, std::fabs(dc[e]));
  if (dc_scale > 0.0)
    for (std::size_t e : dof) dc[e] /= dc_scale;

  // Current constraint value g0 = V_active(x) - target. filter_density is 0 on
  // frozen/empty voxels, so summing the whole field sums the Active voxels only.
  const std::vector<double> xphys = filter.filter_density(density);
  double vol = 0.0;
  for (double v : xphys) vol += v;
  const double g0 = vol - target;

  const double xmin = density_min, xmax = 1.0, xrange = xmax - xmin;
  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes L_j, U_j (Active voxels only).
  for (std::size_t e : dof) {
    const double xe = density[e];
    if (mma_iter <= 2) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      const double s = (xe - st.xold1[e]) * (st.xold1[e] - st.xold2[e]);
      const double gamma = (s < 0.0) ? asydecr : (s > 0.0) ? asyincr : 1.0;
      double L = xe - gamma * (st.xold1[e] - st.low[e]);
      double U = xe + gamma * (st.upp[e] - st.xold1[e]);
      L = std::min(L, xe - 0.01 * xrange);
      L = std::max(L, xe - 10.0 * xrange);
      U = std::max(U, xe + 0.01 * xrange);
      U = std::min(U, xe + 10.0 * xrange);
      st.low[e] = L;
      st.upp[e] = U;
    }
  }

  // 2. Separable convex approximation coefficients + move box [alpha, beta].
  std::vector<double> p0(N, 0.0), q0(N, 0.0), p1(N, 0.0), q1(N, 0.0);
  std::vector<double> alpha(N, 0.0), beta(N, 0.0);
  double b = -g0;
  for (std::size_t e : dof) {
    const double xe = density[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dc[e], 0.0), dcm = std::max(-dc[e], 0.0);
    const double dvp = std::max(dv[e], 0.0), dvm = std::max(-dv[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    p1[e] = ux1 * ux1 * (1.001 * dvp + 0.001 * dvm + raa0 / xrange);
    q1[e] = xl1 * xl1 * (0.001 * dvp + 1.001 * dvm + raa0 / xrange);
    b += p1[e] / ux1 + q1[e] / xl1;
    alpha[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    beta[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
  }

  // 3. Dual solve for the single volume constraint. Frozen voxels keep their
  // pinned x (1 or 0); only Active voxels take the closed-form primal minimiser.
  auto candidate = [&](double lambda) {
    std::vector<double> xnew = density;  // preserves FrozenSolid=1, FrozenVoid=0
    for (std::size_t e : dof) {
      const double pl = std::sqrt(p0[e] + lambda * p1[e]);
      const double ql = std::sqrt(q0[e] + lambda * q1[e]);
      double xt = (pl * st.low[e] + ql * st.upp[e]) / (pl + ql);
      if (xt < alpha[e]) xt = alpha[e];
      if (xt > beta[e]) xt = beta[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  auto gval = [&](const std::vector<double>& x) {
    double s = 0.0;
    for (std::size_t e : dof)
      s += p1[e] / (st.upp[e] - x[e]) + q1[e] / (x[e] - st.low[e]);
    return s - b;
  };
  double lambda = 0.0;
  if (gval(candidate(0.0)) > 0.0) {
    double l1 = 0.0, l2 = 1.0;
    while (l2 < 1e30 && gval(candidate(l2)) > 0.0) l2 *= 2.0;
    for (int it = 0; it < 100 && (l2 - l1) > 1e-9 * (1.0 + l1 + l2); ++it) {
      const double lmid = 0.5 * (l1 + l2);
      if (gval(candidate(lmid)) > 0.0)
        l1 = lmid;
      else
        l2 = lmid;
    }
    lambda = 0.5 * (l1 + l2);
  }
  std::vector<double> xnew = candidate(lambda);

  // 4. Roll history forward (xold2 <- xold1 <- x). Frozen voxels store their
  // constant pin here too; the asymptote branch only reads xold1/xold2 for
  // Active voxels (mma_iter >= 3), so the frozen entries are inert.
  st.xold2 = st.xold1;
  st.xold1 = density;
  return xnew;
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

// MMA + Heaviside projection restricted to Active voxels (handoff 114): the
// mask-aware analogue of mma_update_projected, standing to mma_update_masked
// exactly as mma_update_projected stands to mma_update. FrozenSolid (x=1) /
// FrozenVoid (x=0) entries are carried through unchanged; only Active voxels
// move, under the single volume constraint on the PROJECTED Active density. The
// mask-aware (Active-only) filter confines dc/dv to Active voxels. `xtilde` is
// the current mask-aware filtered design; `beta`/`eta` this stage's projection.
std::vector<double> mma_update_masked_projected(
    MmaState& st, int mma_iter, const VoxelGrid& grid,
    const DensityFilter& filter, const DesignMask& eff,
    const std::vector<double>& density, const std::vector<double>& xtilde,
    const std::vector<double>& dcompliance, double beta, double eta,
    double volume_fraction, double move, double density_min) {
  const std::size_t N = grid.voxel_count();

  // Projection chain-rule prep over the Active set: dproj, dc*dproj, projected
  // Active volume, and the Active design DOFs.
  std::vector<double> dc_phys(N, 0.0), dproj(N, 0.0);
  std::vector<std::size_t> dof;
  double vol_proj = 0.0;
  for (std::size_t e = 0; e < N; ++e)
    if (eff[e] == MaskValue::Active) {
      dproj[e] = heaviside_project_derivative(xtilde[e], beta, eta);
      dc_phys[e] = dcompliance[e] * dproj[e];
      vol_proj += heaviside_project(xtilde[e], beta, eta);
      dof.push_back(e);
    }
  std::vector<double> dc = filter.filter_sensitivity(dc_phys);
  const std::vector<double> dv = filter.filter_sensitivity(dproj);
  const double target = volume_fraction * static_cast<double>(dof.size());

  // Scale-invariance (as in mma_update_masked): normalize dc to O(1).
  double dc_scale = 0.0;
  for (std::size_t e : dof) dc_scale = std::max(dc_scale, std::fabs(dc[e]));
  if (dc_scale > 0.0)
    for (std::size_t e : dof) dc[e] /= dc_scale;

  const double g0 = vol_proj - target;  // constraint on the PROJECTED density

  const double xmin = density_min, xmax = 1.0, xrange = xmax - xmin;
  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes (identical rule to mma_update_masked).
  for (std::size_t e : dof) {
    const double xe = density[e];
    if (mma_iter <= 2) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      const double s = (xe - st.xold1[e]) * (st.xold1[e] - st.xold2[e]);
      const double gamma = (s < 0.0) ? asydecr : (s > 0.0) ? asyincr : 1.0;
      double L = xe - gamma * (st.xold1[e] - st.low[e]);
      double U = xe + gamma * (st.upp[e] - st.xold1[e]);
      L = std::min(L, xe - 0.01 * xrange);
      L = std::max(L, xe - 10.0 * xrange);
      U = std::max(U, xe + 0.01 * xrange);
      U = std::min(U, xe + 10.0 * xrange);
      st.low[e] = L;
      st.upp[e] = U;
    }
  }

  // 2. Separable convex coefficients + move box.
  std::vector<double> p0(N, 0.0), q0(N, 0.0), p1(N, 0.0), q1(N, 0.0);
  std::vector<double> alpha(N, 0.0), beta_box(N, 0.0);
  double b = -g0;
  for (std::size_t e : dof) {
    const double xe = density[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dc[e], 0.0), dcm = std::max(-dc[e], 0.0);
    const double dvp = std::max(dv[e], 0.0), dvm = std::max(-dv[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    p1[e] = ux1 * ux1 * (1.001 * dvp + 0.001 * dvm + raa0 / xrange);
    q1[e] = xl1 * xl1 * (0.001 * dvp + 1.001 * dvm + raa0 / xrange);
    b += p1[e] / ux1 + q1[e] / xl1;
    alpha[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    beta_box[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
  }

  // 3. Dual solve for the single volume constraint; frozen voxels keep their
  // pinned x (candidate starts from `density`).
  auto candidate = [&](double lambda) {
    std::vector<double> xnew = density;  // preserves FrozenSolid=1, FrozenVoid=0
    for (std::size_t e : dof) {
      const double pl = std::sqrt(p0[e] + lambda * p1[e]);
      const double ql = std::sqrt(q0[e] + lambda * q1[e]);
      double xt = (pl * st.low[e] + ql * st.upp[e]) / (pl + ql);
      if (xt < alpha[e]) xt = alpha[e];
      if (xt > beta_box[e]) xt = beta_box[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  auto gval = [&](const std::vector<double>& x) {
    double s = 0.0;
    for (std::size_t e : dof)
      s += p1[e] / (st.upp[e] - x[e]) + q1[e] / (x[e] - st.low[e]);
    return s - b;
  };
  double lambda = 0.0;
  if (gval(candidate(0.0)) > 0.0) {
    double l1 = 0.0, l2 = 1.0;
    while (l2 < 1e30 && gval(candidate(l2)) > 0.0) l2 *= 2.0;
    for (int it = 0; it < 100 && (l2 - l1) > 1e-9 * (1.0 + l1 + l2); ++it) {
      const double lmid = 0.5 * (l1 + l2);
      if (gval(candidate(lmid)) > 0.0)
        l1 = lmid;
      else
        l2 = lmid;
    }
    lambda = 0.5 * (l1 + l2);
  }
  std::vector<double> xnew = candidate(lambda);

  st.xold2 = st.xold1;
  st.xold1 = density;
  return xnew;
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
  // The masked loop supports both updaters since the switchover (M7.mma.4);
  // only MMA + a Heaviside projection schedule is rejected (the projected path
  // is the OC-locked Gate-V2 formulation — see validate_updater_options).
  validate_updater_options(options);
  validate_mma_projection_options(options);  // MMA Heaviside opt-in (handoff 114)

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
  // FrozenVoid at 0, Empty at 0 — UNLESS a warm-start seed is supplied (handoff
  // 110). EMPTY initial_design keeps the uniform start byte-for-byte identical.
  std::vector<double> x(grid.voxel_count(), 0.0);
  if (options.initial_design.empty()) {
    for (std::size_t e = 0; e < x.size(); ++e) {
      if (eff[e] == MaskValue::Active) x[e] = options.volume_fraction;
      else if (eff[e] == MaskValue::FrozenSolid) x[e] = 1.0;
      // FrozenVoid / Empty stay 0
    }
  } else {
    if (options.initial_design.size() != grid.voxel_count())
      throw std::invalid_argument(
          "simp_optimize: initial_design size != grid.voxel_count()");
    std::vector<char> is_design(grid.voxel_count(), 0);
    for (std::size_t e = 0; e < x.size(); ++e)
      if (eff[e] == MaskValue::Active) is_design[e] = 1;
    x = warm_start_design(options.initial_design, filter, is_design,
                          options.volume_fraction, params.density_min);
    // Reapply the pins the uniform start carries: FrozenSolid -> 1, every
    // non-Active voxel -> 0 (the Active-only filter already yields 0 off the
    // Active set, but pin explicitly so FrozenSolid is full material).
    for (std::size_t e = 0; e < x.size(); ++e) {
      if (eff[e] == MaskValue::FrozenSolid) x[e] = 1.0;
      else if (eff[e] != MaskValue::Active) x[e] = 0.0;
    }
  }

  // MMA updater state (ROADMAP M7.mma.4). Unused when updater == OC; the masked
  // loop owns a single continuous MMA iteration count across all stages, exactly
  // like the unconstrained overload.
  MmaState mma_state;
  int mma_iter = 0;

  // MMA Heaviside beta-continuation state (handoff 114); see the unconstrained
  // overload for the contract. Inert unless the plan carries the single
  // mma_continuation stage.
  double mma_beta = options.mma_projection_beta0;
  const double mma_beta_max = options.mma_projection_beta_max;
  std::size_t mma_stage_start = 0;

  // Persistent solver over the FIXED analysis grid / BCs / loads (see the
  // unconstrained overload): assembles the reduced operator once, then per
  // iteration only rescales values and warm-starts CG. Falls back to the
  // stateless path when BCs are non-homogeneous. Only built for the JacobiCG
  // path — its constructor assembles the fine K that OOMs on the design box, so
  // the multigrid kinds (which bypass it) must not construct it. This is the
  // mask-aware MMA optimizer the design-box run uses, so the gate is what keeps
  // the on-device design-box path matrix-free (no assembled fine K).
  std::unique_ptr<PenalizedSolver> solver;
  if (options.solver == SolverKind::JacobiCG)
    solver =
        std::make_unique<PenalizedSolver>(analysis, params.poisson, bcs, loads);
  const bool use_solver = solver && solver->usable();
  FeaSolution warm;  // fallback warm-start guess (unused when use_solver)

  SimpOptimizeResult result;
  result.history.reserve(total_stage_iterations(plan));

  // Adaptive early CG tolerance (handoff 128): see the unconstrained overload.
  // Seeded to the move limit so the first trajectory solve is loose.
  double last_change = options.move;

  // Handoff 131 — per-iteration CG record, index-aligned with result.history (see
  // the unconstrained overload). This is the overload the production design-box
  // ladder runs, so this is the one the 96³ evidence was measured on.
  std::vector<int> cg_history;
  cg_history.reserve(total_stage_iterations(plan));

  for (const StagePlan& st : plan) {
    bool stage_converged = false;
    for (int it = 0; it < st.iterations; ++it) {
      // M7.0a: cancellation is polled once per OC iteration, at its start (as
      // in the unconstrained overload above).
      if (options.cancel && options.cancel->load()) {
        result.cancelled = true;
        break;
      }
      const bool projecting = st.project || st.mma_continuation;
      const double cur_beta = st.mma_continuation ? mma_beta : st.beta;
      const double cur_move =
          st.mma_continuation ? mma_continuation_move(st.move, cur_beta)
                              : st.move;
      std::vector<double> xphys = filter.filter_density(x);
      if (projecting) project_active(eff, xphys, cur_beta, eta);
      apply_mask_pins(eff, xphys);  // FrozenSolid -> 1, FrozenVoid -> 0
      // Trajectory solve: adaptive (loose→tight) tolerance when enabled, else the
      // tight cg_tolerance (byte-identical). The FINAL solve below stays tight.
      const double traj_tol = adaptive_traj_cg_tol(options, last_change);
      const SimpCompliance c =
          simp_compliance(analysis, params, xphys, bcs, loads,
                          traj_tol, options.cg_max_iterations,
                          warm.u.empty() ? nullptr : &warm,
                          use_solver ? solver.get() : nullptr, options.solver);
      if (!use_solver) warm = c.solution;
      if (!c.cg.converged)
        throw std::runtime_error(
            "simp_optimize: penalized CG solve did not converge");

      std::vector<double> x_new;
      if (st.mma_continuation) {
        // MMA + Heaviside projection (handoff 114), restricted to Active voxels.
        const std::vector<double> xtilde = filter.filter_density(x);
        x_new = mma_update_masked_projected(
            mma_state, ++mma_iter, grid, filter, eff, x, xtilde, c.dcompliance,
            cur_beta, eta, options.volume_fraction, cur_move,
            params.density_min);
      } else if (st.project) {
        // dproj needs the UNprojected filtered field: recompute it (xphys was
        // projected + pinned in place above).
        const std::vector<double> xtilde = filter.filter_density(x);
        x_new = oc_update_masked_projected(grid, filter, eff, x, xtilde,
                                           c.dcompliance, st.beta, eta,
                                           options.volume_fraction, st.move,
                                           params.density_min);
      } else if (options.updater == SimpUpdater::MMA) {
        // Passive-region MMA (M7.mma.4): the same single-volume-constraint MMA
        // subproblem as the plain overload, restricted to Active voxels.
        x_new = mma_update_masked(mma_state, ++mma_iter, grid, filter, eff, x,
                                  c.dcompliance, options.volume_fraction,
                                  st.move, params.density_min);
      } else {
        x_new = oc_update_masked(grid, filter, eff, x, c.dcompliance,
                                 options.volume_fraction, st.move,
                                 params.density_min);
      }

      double change = 0.0;
      for (std::size_t e = 0; e < x.size(); ++e)
        change = std::max(change, std::fabs(x_new[e] - x[e]));
      last_change = change;  // handoff 128: drives next iter's trajectory CG tol

      x = x_new;
      if (result.iterations == 0) result.initial_compliance = c.compliance;
      ++result.iterations;
      std::vector<double> xafter = filter.filter_density(x);
      if (st.project) project_active(eff, xafter, st.beta, eta);
      const double vf_now = active_volfrac(xafter);
      result.history.push_back({c.compliance, change, vf_now});
      cg_history.push_back(c.cg.iterations);  // handoff 131 (index-aligned)
      // Handoff 131 — rung-infeasibility verdict for THIS iteration (see the
      // unconstrained overload for the ordering rationale).
      const bool infeasible_now =
          observe_infeasible(options, result.history, cg_history);
      if (options.progress)
        options.progress(result.iterations, c.compliance, change);
      // Handoff 114 — per-iteration observability (read-only), as in the
      // unconstrained overload. `active_volfrac` is the achieved fraction over
      // the Active voxels — the same value recorded in history.
      if (options.observe) {
        SimpIterationObservation obs;
        obs.iteration = result.iterations;
        obs.compliance = c.compliance;
        obs.change = change;
        obs.volume_fraction = vf_now;
        obs.cg_iterations = c.cg.iterations;
        obs.cg_used_multigrid = c.cg.used_multigrid;
        obs.cg_mg_levels = c.cg.mg_levels;
        obs.cg_hier_built = c.cg.hier_built;
        obs.cg_mg_cycles_attempted = c.cg.mg_cycles_attempted;
        obs.cg_recycle_dim = c.cg.recycle_dim;
        obs.cg_recycle_setup_matvecs = c.cg.recycle_setup_matvecs;
        obs.plateau = observe_plateau(options, result.history);
        // Handoff 123 — the continuation β active this iteration (0 when not
        // projecting), so the CSV beta column reflects the sharpening stage.
        obs.beta = projecting ? cur_beta : 0.0;
        obs.infeasible = infeasible_now;  // handoff 131
        options.observe(obs);
      }
      // Playback keyframe: the printed-shape density (mask pins applied) as it
      // evolves. Read-only — a pinned COPY, so `x` and the optimization are
      // untouched.
      if (options.keyframe && options.keyframe_stride > 0 &&
          (result.iterations == 1 ||
           result.iterations % options.keyframe_stride == 0)) {
        std::vector<double> kf = xafter;
        apply_mask_pins(eff, kf);
        options.keyframe(kf);
      }
      // Handoff 114 — density SNAPSHOT feed: the pinned physical field (the
      // printed shape) every iteration. The pinned COPY is built ONLY when a
      // consumer is attached, so the default path pays no copy. Read-only.
      if (options.density_observer) {
        std::vector<double> pd = xafter;
        apply_mask_pins(eff, pd);
        options.density_observer(result.iterations, pd);
      }

      // Handoff 131 — FAST FAIL on a provably lost load path (see the
      // unconstrained overload). Ends the rung before any stage/continuation
      // logic can treat the corpse as a converged design.
      if (infeasible_now) {
        result.infeasible = true;
        result.infeasible_iteration = result.iterations;
        break;
      }

      if (st.mma_continuation) {
        // Beta continuation (handoff 114): 086 plateau on the current beta
        // stage; advance beta on a stall, terminate at a stall on the final
        // beta. See the unconstrained overload for the rationale.
        std::vector<double> curve;
        curve.reserve(result.history.size() - mma_stage_start);
        for (std::size_t hi = mma_stage_start; hi < result.history.size(); ++hi)
          curve.push_back(result.history[hi].compliance);
        // Progress gate on the first (beta0) stage only — see the unconstrained
        // overload for the rationale.
        const double stage_min_drop =
            (mma_stage_start == 0) ? options.mma_plateau_min_drop : 0.0;
        if (mma_objective_plateau(curve, options.mma_plateau_window,
                                  options.mma_plateau_tol, stage_min_drop,
                                  options.mma_plateau_flat_windows)) {
          if (mma_beta < mma_beta_max) {
            mma_beta = std::min(mma_beta * 2.0, mma_beta_max);
            mma_stage_start = result.history.size();
            mma_state = MmaState{};
            mma_iter = 0;
          } else {
            stage_converged = true;
            break;
          }
        }
      } else if (stage_should_stop(options, result.history, change)) {
        stage_converged = true;
        break;
      }
    }
    // Continuation proceeds stage by stage; `converged` reports the LAST one
    // (a cancelled stage never is).
    result.converged = stage_converged;
    if (result.cancelled || result.infeasible) break;
  }

  // Self-consistent final state (projected at the final stage's beta when
  // projecting, pins applied to the physical density) via one final solve on
  // the converged field. For the MMA continuation stage the final sharpness is
  // `mma_beta`.
  result.design = x;
  result.physical_density = filter.filter_density(x);
  if (plan.back().project)
    project_active(eff, result.physical_density, plan.back().beta, eta);
  else if (plan.back().mma_continuation)
    project_active(eff, result.physical_density, mma_beta, eta);
  std::vector<double> xfinal_unpinned = result.physical_density;
  apply_mask_pins(eff, result.physical_density);
  // Handoff 131 — an INFEASIBLE run skips this final recovery solve; see the
  // unconstrained overload for why (it is both the most expensive solve of the run
  // and the one that could throw instead of reporting the honest verdict).
  if (result.infeasible) {
    result.compliance =
        result.history.empty() ? 0.0 : result.history.back().compliance;
  } else {
    const SimpCompliance fc = simp_compliance(
        analysis, params, result.physical_density, bcs, loads,
        options.cg_tolerance, options.cg_max_iterations, nullptr,
        use_solver ? solver.get() : nullptr, options.solver);
    result.compliance = fc.compliance;
  }
  result.volume_fraction = active_volfrac(xfinal_unpinned);
  // Final playback keyframe: the converged printed shape.
  if (options.keyframe && options.keyframe_stride > 0)
    options.keyframe(result.physical_density);
  return result;
}

// ---------------------------------------------------------------------------
// Stress-constrained optimization (ROADMAP M7.mma.2): the aggregated von Mises
// measure + its adjoint sensitivity, a two-constraint (volume + stress) MMA
// update, and the loop tying them together. See topopt/simp.hpp for the
// formulation record (P-norm aggregation, qp relaxation, adjoint sensitivity).

namespace {

// von Mises quadratic form (Voigt [xx,yy,zz,xy,yz,zx], TRUE shear stresses):
// sigma^T Vm sigma = von_mises^2 = sxx^2+syy^2+szz^2 - sxx syy - syy szz
//   - szz sxx + 3(txy^2 + tyz^2 + tzx^2).
constexpr double kVm[6][6] = {
    {1.0, -0.5, -0.5, 0.0, 0.0, 0.0}, {-0.5, 1.0, -0.5, 0.0, 0.0, 0.0},
    {-0.5, -0.5, 1.0, 0.0, 0.0, 0.0}, {0.0, 0.0, 0.0, 3.0, 0.0, 0.0},
    {0.0, 0.0, 0.0, 0.0, 3.0, 0.0},   {0.0, 0.0, 0.0, 0.0, 0.0, 3.0}};

// Centroid stress-displacement matrix DB = D0 * B (6x24) for the SOLID isotropic
// material (E0, nu) on a cubic voxel of edge h: sigma_centroid = DB * u_elem
// (Voigt order, true shear). Identical B / D0 construction to hex8_stress at
// natural coords (0,0,0); computed once (all cubic voxels share it) and reused
// for every element's stress and stress adjoint.
struct StressMatrix {
  std::array<double, 6 * 24> DB{};
  double operator()(int r, int c) const {
    return DB[static_cast<std::size_t>(r) * 24 + c];
  }
};

StressMatrix centroid_stress_matrix(double E, double nu, double h) {
  // Isoparametric shape derivatives at the centroid: dN/dx = 0.25 * xi_a / h.
  static constexpr double kXi[8] = {-1, 1, 1, -1, -1, 1, 1, -1};
  static constexpr double kEta[8] = {-1, -1, 1, 1, -1, -1, 1, 1};
  static constexpr double kZeta[8] = {-1, -1, -1, -1, 1, 1, 1, 1};
  double dNdx[8], dNdy[8], dNdz[8];
  for (int a = 0; a < 8; ++a) {
    dNdx[a] = 0.25 * kXi[a] / h;
    dNdy[a] = 0.25 * kEta[a] / h;
    dNdz[a] = 0.25 * kZeta[a] / h;
  }
  double B[6][24] = {};
  for (int a = 0; a < 8; ++a) {
    const int cx = 3 * a, cy = 3 * a + 1, cz = 3 * a + 2;
    B[0][cx] = dNdx[a];
    B[1][cy] = dNdy[a];
    B[2][cz] = dNdz[a];
    B[3][cx] = dNdy[a];
    B[3][cy] = dNdx[a];
    B[4][cy] = dNdz[a];
    B[4][cz] = dNdy[a];
    B[5][cx] = dNdz[a];
    B[5][cz] = dNdx[a];
  }
  // Isotropic constitutive D0 (same as hex8_stress).
  const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
  double D[6][6] = {};
  D[0][0] = D[1][1] = D[2][2] = c * (1.0 - nu);
  D[0][1] = D[0][2] = D[1][0] = D[1][2] = D[2][0] = D[2][1] = c * nu;
  const double G = c * (1.0 - 2.0 * nu) / 2.0;
  D[3][3] = D[4][4] = D[5][5] = G;

  StressMatrix sm;
  for (int r = 0; r < 6; ++r)
    for (int col = 0; col < 24; ++col) {
      double s = 0.0;
      for (int m = 0; m < 6; ++m) s += D[r][m] * B[m][col];
      sm.DB[static_cast<std::size_t>(r) * 24 + col] = s;
    }
  return sm;
}

// Gather a solid voxel's 24 nodal values from a DOF-ordered field.
std::array<double, 24> gather_element(const VoxelGrid& grid,
                                      const std::vector<double>& u, int i, int j,
                                      int k) {
  const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
  std::array<double, 24> ue;
  for (int a = 0; a < 8; ++a)
    for (int comp = 0; comp < 3; ++comp)
      ue[static_cast<std::size_t>(3 * a + comp)] =
          u[static_cast<std::size_t>(3 * en[a] + comp)];
  return ue;
}

struct StressAdjoint {
  double value = 0.0;
  double max_relaxed = 0.0;
  double max_von_mises = 0.0;
  std::vector<double> dvalue;  // dg/drho (physical density space)
  CgInfo adjoint_cg;
};

// The aggregated relaxed von Mises P-norm g and its adjoint sensitivity dg/drho,
// given the penalized displacement field `u` for physical density `density`
// (the SAME field simp_compliance already solved — the adjoint reuses that
// K(rho) but not the objective's RHS). `elem_youngs` is E(rho) per voxel (the
// adjoint stiffness). One extra (adjoint) CG solve. Empty voxels contribute
// nothing; solid densities are clamped to [density_min, 1].
StressAdjoint stress_aggregate_from_solution(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<double>& density,
    const std::vector<double>& elem_youngs, const FeaSolution& u,
    const std::vector<DirichletBC>& bcs, double p_norm, double q,
    double printed_threshold, double tolerance, int max_iterations) {
  const std::size_t N = grid.voxel_count();
  const StressMatrix sm =
      centroid_stress_matrix(params.youngs_modulus, params.poisson, grid.spacing);

  // Pass 1: per-voxel true von Mises vm_e and relaxed sigma~_e = rho^q vm_e,
  // accumulate sum sigma~^P, and cache vm + the centroid stress for the adjoint.
  std::vector<double> vm(N, 0.0);
  std::vector<std::array<double, 6>> stress(N);
  double sump = 0.0, max_relaxed = 0.0, max_vm = 0.0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        const std::array<double, 24> ue = gather_element(grid, u.u, i, j, k);
        std::array<double, 6> sig{};
        for (int r = 0; r < 6; ++r) {
          double s = 0.0;
          for (int d = 0; d < 24; ++d) s += sm(r, d) * ue[static_cast<std::size_t>(d)];
          sig[static_cast<std::size_t>(r)] = s;
        }
        double vmsq = 0.0;
        for (int r = 0; r < 6; ++r)
          for (int cc = 0; cc < 6; ++cc)
            vmsq += sig[static_cast<std::size_t>(r)] * kVm[r][cc] *
                    sig[static_cast<std::size_t>(cc)];
        const double vme = vmsq > 0.0 ? std::sqrt(vmsq) : 0.0;
        const double rho = clamp_density(params, density[e]);
        const double relaxed = std::pow(rho, q) * vme;
        vm[e] = vme;
        stress[e] = sig;
        sump += std::pow(relaxed, p_norm);
        max_relaxed = std::max(max_relaxed, relaxed);
        if (rho >= printed_threshold) max_vm = std::max(max_vm, vme);
      }

  StressAdjoint out;
  out.dvalue.assign(N, 0.0);
  out.max_relaxed = max_relaxed;
  out.max_von_mises = max_vm;
  out.value = sump > 0.0 ? std::pow(sump, 1.0 / p_norm) : 0.0;
  if (!(out.value > 0.0)) {
    out.adjoint_cg.converged = true;  // no stress -> trivially "solved"
    return out;                       // dg/drho == 0 (a stress-free field)
  }
  const double gP1 = std::pow(out.value, 1.0 - p_norm);  // g^{1-P}

  // Pass 2: adjoint RHS beta = dg/du = g^{1-P} sum_e sigma~_e^{P-1} rho^q
  // (V sigma_e)^T DB / vm_e, scattered to global DOFs.
  std::vector<double> beta(static_cast<std::size_t>(3 * fea_node_count(grid)),
                           0.0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        const double vme = vm[e];
        if (!(vme > 0.0)) continue;
        const double rho = clamp_density(params, density[e]);
        const double relaxed = std::pow(rho, q) * vme;
        const double coef = gP1 * std::pow(relaxed, p_norm - 1.0) *
                            std::pow(rho, q) / vme;
        // Vs = Vm * sigma_e, then t = DB^T Vs (24-vector).
        std::array<double, 6> Vs{};
        for (int r = 0; r < 6; ++r) {
          double s = 0.0;
          for (int cc = 0; cc < 6; ++cc)
            s += kVm[r][cc] * stress[e][static_cast<std::size_t>(cc)];
          Vs[static_cast<std::size_t>(r)] = s;
        }
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int a = 0; a < 8; ++a)
          for (int comp = 0; comp < 3; ++comp) {
            const int d = 3 * a + comp;
            double t = 0.0;
            for (int r = 0; r < 6; ++r)
              t += sm(r, d) * Vs[static_cast<std::size_t>(r)];
            beta[static_cast<std::size_t>(3 * en[a] + comp)] += coef * t;
          }
      }

  // Adjoint solve K(rho) lambda = beta on the same penalized stiffness and BCs
  // (K symmetric, so the adjoint operator is K). Reuses the void-gated CG path;
  // beta becomes the RHS "load" vector.
  std::vector<NodalLoad> beta_loads;
  for (int n = 0; n < fea_node_count(grid); ++n)
    for (int comp = 0; comp < 3; ++comp) {
      const double b = beta[static_cast<std::size_t>(3 * n + comp)];
      if (b != 0.0) beta_loads.push_back({n, comp, b});
    }
  const FeaSolution lambda = fea_solve_cg(grid, elem_youngs, params.poisson, bcs,
                                          beta_loads, tolerance, max_iterations,
                                          &out.adjoint_cg);

  // Pass 3: dg/drho_e = explicit (rho^q factor) + adjoint (through u).
  const Hex8Stiffness K0 = hex8_stiffness(1.0, params.poisson, grid.spacing);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        const double vme = vm[e];
        const double rho = clamp_density(params, density[e]);
        double explicit_term = 0.0;
        if (vme > 0.0) {
          const double relaxed = std::pow(rho, q) * vme;
          explicit_term = gP1 * std::pow(relaxed, p_norm - 1.0) * q *
                          std::pow(rho, q - 1.0) * vme;
        }
        // adjoint: -p rho^{p-1} E0 (lambda_e^T K0 u_e).
        const std::array<double, 24> ue = gather_element(grid, u.u, i, j, k);
        const std::array<double, 24> le = gather_element(grid, lambda.u, i, j, k);
        double quad = 0.0;
        for (int r = 0; r < 24; ++r) {
          double kr = 0.0;
          for (int cc = 0; cc < 24; ++cc)
            kr += K0(r, cc) * ue[static_cast<std::size_t>(cc)];
          quad += le[static_cast<std::size_t>(r)] * kr;
        }
        const double adjoint_term = -params.penalty *
                                    std::pow(rho, params.penalty - 1.0) *
                                    params.youngs_modulus * quad;
        out.dvalue[e] = explicit_term + adjoint_term;
      }
  return out;
}

// Per-voxel penalized modulus E(rho)=clamp(rho)^p*E0 (Empty voxels 0), the
// graded-FEA input shared by the primal and adjoint solves.
std::vector<double> penalized_youngs(const VoxelGrid& grid,
                                     const SimpParams& params,
                                     const std::vector<double>& density) {
  std::vector<double> ey(grid.voxel_count(), 0.0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        ey[e] = std::pow(clamp_density(params, density[e]), params.penalty) *
                params.youngs_modulus;
      }
  return ey;
}

}  // namespace

StressAggregate simp_stress_aggregate(const VoxelGrid& grid,
                                      const SimpParams& params,
                                      const std::vector<double>& density,
                                      const std::vector<DirichletBC>& bcs,
                                      const std::vector<NodalLoad>& loads,
                                      double p_norm, double relaxation_q,
                                      double printed_threshold, double tolerance,
                                      int max_iterations) {
  validate_params(params);
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "simp_stress_aggregate: density vector size != voxel_count");
  if (!(p_norm > 1.0))
    throw std::invalid_argument("simp_stress_aggregate: p_norm must be > 1");
  if (!(relaxation_q > 0.0 && relaxation_q < params.penalty))
    throw std::invalid_argument(
        "simp_stress_aggregate: relaxation_q must be in (0, penalty)");

  const std::vector<double> elem_youngs = penalized_youngs(grid, params, density);
  StressAggregate out;
  out.solution = fea_solve_cg(grid, elem_youngs, params.poisson, bcs, loads,
                              tolerance, max_iterations, &out.cg);
  const StressAdjoint a = stress_aggregate_from_solution(
      grid, params, density, elem_youngs, out.solution, bcs, p_norm,
      relaxation_q, printed_threshold, tolerance, max_iterations);
  out.value = a.value;
  out.max_von_mises = a.max_von_mises;
  out.max_relaxed = a.max_relaxed;
  out.dvalue = a.dvalue;
  out.adjoint_cg = a.adjoint_cg;
  return out;
}

namespace {

// One MMA design update for the minimum-compliance problem with a volume
// constraint AND an aggregated stress constraint (ROADMAP M7.mma.2). Same
// moving-asymptote machinery and convex separable approximation as mma_update
// (Svanberg 1987), extended to m = 2 constraints. Because the objective and
// both constraints are separable-convex, the dual is concave in lambda >= 0 and
// its stationarity is solved by NESTED bisection: for a trial stress multiplier
// lambda2, solve the volume multiplier lambda1 (g1 decreasing in lambda1) to
// hold the volume constraint, then bisect lambda2 (g2 decreasing in lambda2
// along that path) to hold the stress constraint. Complementarity is honoured:
// a constraint already satisfied at lambda = 0 keeps its multiplier at 0.
//
// `dcompliance` / `dstress` are the PHYSICAL-space objective and stress
// sensitivities (dstress already scaled so that g2(x) = sum(...)-b2 measures the
// normalized constraint value/cap - 1); `g2_value` is that constraint's current
// value at x. Constants match mma_update.
std::vector<double> mma_update_stress(
    MmaState& st, int mma_iter, const VoxelGrid& grid,
    const DensityFilter& filter, const std::vector<double>& density,
    const std::vector<double>& dcompliance, const std::vector<double>& dstress,
    double g2_value, double volume_fraction, double move, double density_min) {
  const std::size_t N = grid.voxel_count();

  // Chain rule into design space (H symmetric): objective, unit-volume, stress.
  const std::vector<double> dc = filter.filter_sensitivity(dcompliance);
  std::vector<double> ones(N, 0.0);
  std::vector<std::size_t> dof;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) {
          const std::size_t e = grid.index(i, j, k);
          ones[e] = 1.0;
          dof.push_back(e);
        }
  const std::vector<double> dv1 = filter.filter_sensitivity(ones);
  const std::vector<double> dv2 = filter.filter_sensitivity(dstress);
  const double target = volume_fraction * static_cast<double>(dof.size());

  // Current constraint values. g1 = V(x) - target (filtered volume is linear).
  const std::vector<double> xphys = filter.filter_density(density);
  double vol = 0.0;
  for (double v : xphys) vol += v;
  const double g1 = vol - target;
  const double g2 = g2_value;

  const double xmin = density_min, xmax = 1.0, xrange = xmax - xmin;
  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes (identical rule to mma_update).
  for (std::size_t e : dof) {
    const double xe = density[e];
    if (mma_iter <= 2) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      const double s = (xe - st.xold1[e]) * (st.xold1[e] - st.xold2[e]);
      const double gamma = (s < 0.0) ? asydecr : (s > 0.0) ? asyincr : 1.0;
      double L = xe - gamma * (st.xold1[e] - st.low[e]);
      double U = xe + gamma * (st.upp[e] - st.xold1[e]);
      L = std::min(L, xe - 0.01 * xrange);
      L = std::max(L, xe - 10.0 * xrange);
      U = std::max(U, xe + 0.01 * xrange);
      U = std::min(U, xe + 10.0 * xrange);
      st.low[e] = L;
      st.upp[e] = U;
    }
  }

  // 2. Separable convex coefficients for the objective (p0,q0) and the two
  // constraints (p1,q1 volume; p2,q2 stress), plus the move box [alpha, beta]
  // and each constraint's b_i.
  std::vector<double> p0(N, 0.0), q0(N, 0.0);
  std::vector<double> p1(N, 0.0), q1(N, 0.0), p2(N, 0.0), q2(N, 0.0);
  std::vector<double> alpha(N, 0.0), beta(N, 0.0);
  double b1 = -g1, b2 = -g2;
  for (std::size_t e : dof) {
    const double xe = density[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double u2 = ux1 * ux1, l2 = xl1 * xl1;
    auto pj = [&](double d) { return u2 * (1.001 * std::max(d, 0.0) +
                                           0.001 * std::max(-d, 0.0) +
                                           raa0 / xrange); };
    auto qj = [&](double d) { return l2 * (0.001 * std::max(d, 0.0) +
                                           1.001 * std::max(-d, 0.0) +
                                           raa0 / xrange); };
    p0[e] = pj(dc[e]);
    q0[e] = qj(dc[e]);
    p1[e] = pj(dv1[e]);
    q1[e] = qj(dv1[e]);
    p2[e] = pj(dv2[e]);
    q2[e] = qj(dv2[e]);
    b1 += p1[e] / ux1 + q1[e] / xl1;
    b2 += p2[e] / ux1 + q2[e] / xl1;
    alpha[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    beta[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
  }

  // 3. Primal minimiser for trial multipliers (l1, l2), closed form + box clamp.
  auto candidate = [&](double l1, double l2) {
    std::vector<double> xnew(N, 0.0);
    for (std::size_t e : dof) {
      const double P = p0[e] + l1 * p1[e] + l2 * p2[e];
      const double Q = q0[e] + l1 * q1[e] + l2 * q2[e];
      const double sp = std::sqrt(P), sq = std::sqrt(Q);
      double xt = (sp * st.low[e] + sq * st.upp[e]) / (sp + sq);
      if (xt < alpha[e]) xt = alpha[e];
      if (xt > beta[e]) xt = beta[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  auto g_of = [&](const std::vector<double>& x, const std::vector<double>& pi,
                  const std::vector<double>& qi, double bi) {
    double s = 0.0;
    for (std::size_t e : dof)
      s += pi[e] / (st.upp[e] - x[e]) + qi[e] / (x[e] - st.low[e]);
    return s - bi;
  };

  // Inner: volume multiplier l1(l2) holding g1 == 0 (or 0 if already feasible).
  auto solve_l1 = [&](double l2) {
    auto g1at = [&](double l1) { return g_of(candidate(l1, l2), p1, q1, b1); };
    if (g1at(0.0) <= 0.0) return 0.0;
    double a = 0.0, b = 1.0;
    while (b < 1e30 && g1at(b) > 0.0) b *= 2.0;
    for (int it = 0; it < 80 && (b - a) > 1e-9 * (1.0 + a + b); ++it) {
      const double m = 0.5 * (a + b);
      if (g1at(m) > 0.0) a = m; else b = m;
    }
    return 0.5 * (a + b);
  };

  // Outer: stress multiplier l2 holding g2 == 0 along l1(l2) (or 0 if feasible).
  auto g2at = [&](double l2) {
    return g_of(candidate(solve_l1(l2), l2), p2, q2, b2);
  };
  double l2 = 0.0;
  if (g2at(0.0) > 0.0) {
    double a = 0.0, b = 1.0;
    while (b < 1e30 && g2at(b) > 0.0) b *= 2.0;
    for (int it = 0; it < 80 && (b - a) > 1e-9 * (1.0 + a + b); ++it) {
      const double m = 0.5 * (a + b);
      if (g2at(m) > 0.0) a = m; else b = m;
    }
    l2 = 0.5 * (a + b);
  }
  const double l1 = solve_l1(l2);
  std::vector<double> xnew = candidate(l1, l2);

  st.xold2 = st.xold1;
  st.xold1 = density;
  return xnew;
}

}  // namespace

SimpOptimizeResult simp_optimize_stress(const VoxelGrid& grid,
                                        const SimpParams& params,
                                        const std::vector<DirichletBC>& bcs,
                                        const std::vector<NodalLoad>& loads,
                                        const SimpOptions& options,
                                        const StressConstraint& stress) {
  validate_params(params);
  if (!(options.volume_fraction > 0.0 && options.volume_fraction <= 1.0))
    throw std::invalid_argument(
        "simp_optimize_stress: volume_fraction must be in (0, 1]");
  if (!(options.move > 0.0))
    throw std::invalid_argument("simp_optimize_stress: move must be > 0");
  if (options.max_iterations < 1)
    throw std::invalid_argument(
        "simp_optimize_stress: max_iterations must be >= 1");
  if (options.change_tol < 0.0)
    throw std::invalid_argument("simp_optimize_stress: change_tol must be >= 0");
  if (!options.projection.empty())
    throw std::invalid_argument(
        "simp_optimize_stress: Heaviside projection is not supported on the "
        "stress-constrained MMA path (ROADMAP M7.mma.2)");
  if (options.mma_projection)
    throw std::invalid_argument(
        "simp_optimize_stress: mma_projection is not supported on the "
        "stress-constrained MMA path (handoff 114)");
  if (!(stress.stress_cap > 0.0))
    throw std::invalid_argument("simp_optimize_stress: stress_cap must be > 0");
  if (!(stress.p_norm > 1.0))
    throw std::invalid_argument("simp_optimize_stress: p_norm must be > 1");
  if (!(stress.relaxation_q > 0.0 && stress.relaxation_q < params.penalty))
    throw std::invalid_argument(
        "simp_optimize_stress: relaxation_q must be in (0, penalty)");

  const DensityFilter filter = make_density_filter(grid, options.filter_radius);
  const double n_design = static_cast<double>(grid.solid_count());
  auto phys_volfrac = [&](const std::vector<double>& xphys) {
    double vol = 0.0;
    for (double v : xphys) vol += v;
    return n_design > 0.0 ? vol / n_design : 0.0;
  };

  MmaState st;
  int mma_iter = 0;
  double c_norm = 0.0;  // adaptive P-norm -> peak normalization (Le et al. 2010)
  bool c_norm_init = false;
  const double cap = stress.stress_cap;
  // Cap continuation: an aggressive target (peak >> cap) cannot be reached in one
  // shot without oscillation, so tighten the effective cap geometrically from the
  // starting aggregate down to `cap` (then hold), a standard stress-constrained
  // stabilizer. `cap_eff` is seeded on the first iteration.
  double cap_eff = 0.0;
  const double kCapRamp = 0.92;  // tighten ~8%/iteration until cap_eff == cap

  std::vector<double> x = simp_uniform_density(grid, options.volume_fraction);

  SimpOptimizeResult result;
  result.history.reserve(static_cast<std::size_t>(options.max_iterations));

  for (int it = 0; it < options.max_iterations; ++it) {
    if (options.cancel && options.cancel->load()) {
      result.cancelled = true;
      break;
    }
    const std::vector<double> xphys = filter.filter_density(x);
    const SimpCompliance c = simp_compliance(grid, params, xphys, bcs, loads,
                                             options.cg_tolerance,
                                             options.cg_max_iterations);
    if (!c.cg.converged)
      throw std::runtime_error(
          "simp_optimize_stress: penalized CG solve did not converge");

    // Stress aggregate + adjoint from the SAME primal displacement field.
    const std::vector<double> elem_youngs =
        penalized_youngs(grid, params, xphys);
    const StressAdjoint agg = stress_aggregate_from_solution(
        grid, params, xphys, elem_youngs, c.solution, bcs, stress.p_norm,
        stress.relaxation_q, stress.printed_threshold, options.cg_tolerance,
        options.cg_max_iterations);
    if (!agg.adjoint_cg.converged)
      throw std::runtime_error(
          "simp_optimize_stress: stress adjoint CG solve did not converge");

    // Adaptive normalization: scale the P-norm toward the true peak of the
    // relaxed field so the constraint is neither slack nor over-conservative.
    // Held constant across this subproblem, so the sensitivity below is exact.
    const double ratio = agg.value > 0.0 ? agg.max_relaxed / agg.value : 1.0;
    c_norm = c_norm_init ? 0.5 * ratio + 0.5 * c_norm : ratio;
    c_norm_init = true;
    // Effective (continuation) cap: seed just under the starting normalized
    // aggregate, then ratchet toward the true cap, never below it.
    const double normalized = c_norm * agg.value;  // ~ peak relaxed stress
    if (cap_eff <= 0.0) cap_eff = std::max(cap, normalized);
    cap_eff = std::max(cap, cap_eff * kCapRamp);
    const double g2 = normalized / cap_eff - 1.0;
    std::vector<double> dstress = agg.dvalue;
    for (double& d : dstress) d *= c_norm / cap_eff;

    const std::vector<double> x_new =
        mma_update_stress(st, ++mma_iter, grid, filter, x, c.dcompliance,
                          dstress, g2, options.volume_fraction, options.move,
                          params.density_min);

    double change = 0.0;
    for (std::size_t e = 0; e < x.size(); ++e)
      change = std::max(change, std::fabs(x_new[e] - x[e]));
    x = x_new;
    if (result.iterations == 0) result.initial_compliance = c.compliance;
    ++result.iterations;
    const std::vector<double> xafter = filter.filter_density(x);
    result.history.push_back({c.compliance, change, phys_volfrac(xafter)});
    if (options.progress) options.progress(result.iterations, c.compliance, change);
    if (options.keyframe && options.keyframe_stride > 0 &&
        (result.iterations == 1 ||
         result.iterations % options.keyframe_stride == 0))
      options.keyframe(xafter);
    if (change < options.change_tol) {
      result.converged = true;
      break;
    }
  }

  result.design = x;
  result.physical_density = filter.filter_density(x);
  const SimpCompliance fc =
      simp_compliance(grid, params, result.physical_density, bcs, loads,
                      options.cg_tolerance, options.cg_max_iterations);
  result.compliance = fc.compliance;
  result.volume_fraction = phys_volfrac(result.physical_density);
  if (options.keyframe && options.keyframe_stride > 0)
    options.keyframe(result.physical_density);
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
