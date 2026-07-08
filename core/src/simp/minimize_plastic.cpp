// M5.3 — the minimize_plastic end-to-end driver (topopt/pipeline.hpp).
//
// Self-weight loading + a descending volume-fraction ladder, stopping at the
// first rung whose worst-case stress margin drops below options.margin_stop.
// See pipeline.hpp for the contract and the modeling choices. This TU drives
// simp_optimize / simp_compliance (Eigen), so it is gated on Eigen in CMake
// alongside simp.cpp.

#include "topopt/pipeline.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/orient.hpp"

namespace topopt {

namespace {

// The M3.5 iso threshold: a voxel is "printed" (solid material) when its
// physical density exceeds this.
constexpr double kIso = 0.5;

Vec3 normalized(const Vec3& v) {
  const double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return Vec3{v.x / n, v.y / n, v.z / n};
}

// Gather one element's 24 nodal displacements from the global solution, in the
// hex8_stiffness DOF order (node-major interleaved), matching the recovery in
// the V4/V5 gates.
std::array<double, 24> element_dofs(const VoxelGrid& grid, const FeaSolution& sol,
                                    int i, int j, int k) {
  const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
  std::array<double, 24> ue{};
  for (int a = 0; a < 8; ++a)
    for (int c = 0; c < 3; ++c)
      ue[static_cast<std::size_t>(3 * a + c)] = sol.at(en[a], c);
  return ue;
}

}  // namespace

MinimizePlasticResult minimize_plastic(const VoxelGrid& grid,
                                       const Material& material,
                                       const std::string& material_name,
                                       const std::vector<DirichletBC>& bcs,
                                       const SettingsRules& rules,
                                       const MinimizePlasticOptions& options) {
  // --- Argument validation (the driver's own inputs) -----------------------
  const std::vector<double>& ladder = options.volume_fraction_ladder;
  if (ladder.empty())
    throw std::invalid_argument(
        "minimize_plastic: volume_fraction_ladder is empty");
  for (std::size_t r = 0; r < ladder.size(); ++r) {
    if (!(ladder[r] > 0.0) || !(ladder[r] <= 1.0) || !std::isfinite(ladder[r]))
      throw std::invalid_argument(
          "minimize_plastic: a ladder volume fraction is not in (0, 1]");
    if (r > 0 && !(ladder[r] < ladder[r - 1]))
      throw std::invalid_argument(
          "minimize_plastic: volume_fraction_ladder is not strictly "
          "descending");
  }
  if (!std::isfinite(options.margin_stop) || options.margin_stop < 0.0)
    throw std::invalid_argument(
        "minimize_plastic: margin_stop must be finite and >= 0");
  if (!std::isfinite(options.gravity) || !(options.gravity > 0.0))
    throw std::invalid_argument(
        "minimize_plastic: gravity must be finite and > 0");
  {
    const Vec3& d = options.gravity_direction;
    if (!(std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z) > 1e-300))
      throw std::invalid_argument(
          "minimize_plastic: gravity_direction is (near) zero length");
  }

  // --- Fixed pipeline setup (shared across every rung) ---------------------
  // Self-weight as the design load, computed once on the original solid grid
  // (pipeline.hpp modeling note). self_weight_loads validates density/gravity/
  // direction and normalizes the direction internally.
  const std::vector<NodalLoad> loads = self_weight_loads(
      grid, material.density_g_cm3, options.gravity, options.gravity_direction);

  // The reported / analysed build direction is the build-plate normal: gravity
  // pulls toward the plate, so the build direction is the unit negation.
  const Vec3 build_dir = normalized(Vec3{-options.gravity_direction.x,
                                         -options.gravity_direction.y,
                                         -options.gravity_direction.z});

  // Material -> SIMP params (penalty p = 3 per ARCHITECTURE §4).
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

  // Mask-aware optimize with an all-Active mask: Fixture voxels are implicitly
  // FrozenSolid (M3.7), so the §7 V3 retention gate holds structurally.
  const DesignMask mask = make_active_mask(grid);

  // Part size for the settings size class: the largest grid bounding-box edge.
  const double part_dim_mm =
      std::max({static_cast<double>(grid.nx), static_cast<double>(grid.ny),
                static_cast<double>(grid.nz)}) *
      grid.spacing;

  MinimizePlasticResult result;
  result.report.material = material_name;

  // --- Walk the ladder -----------------------------------------------------
  for (std::size_t rung = 0; rung < ladder.size(); ++rung) {
    const double vf = ladder[rung];
    SimpOptions opt = options.simp;
    opt.volume_fraction = vf;

    // M7.0a: the driver owns the optimizer's progress/cancel hooks (any set on
    // options.simp are overridden — pipeline.hpp). Per-rung progress forwards
    // (rung index, rung count, iteration); the cancel flag is polled by the
    // optimizer once per OC iteration.
    opt.cancel = options.cancel;
    opt.progress = nullptr;
    if (options.progress) {
      const std::size_t rung_count = ladder.size();
      opt.progress = [&options, rung, rung_count](int iteration, double,
                                                  double) {
        options.progress(rung, rung_count, iteration);
      };
    }

    MinimizePlasticVariant variant;
    variant.requested_volume_fraction = vf;
    variant.optimization = simp_optimize(grid, params, bcs, loads, opt, mask);

    if (variant.optimization.cancelled) {
      // Cancelled mid-rung: report this rung as the rejected terminal rung and
      // stop. The per-rung analysis (stress solve, V3 suite, settings) is
      // skipped — the caller asked to abort, and the half-optimized field is
      // not shipped (pipeline.hpp `cancelled` contract).
      variant.accepted = false;
      result.evaluated.push_back(std::move(variant));
      result.cancelled = true;
      break;
    }

    const std::vector<double>& rho = variant.optimization.physical_density;

    // Final penalized solve on the converged density to recover the
    // displacement field (simp_optimize returns compliance/density, not u).
    const SimpCompliance sc = simp_compliance(grid, params, rho, bcs, loads,
                                              opt.cg_tolerance,
                                              opt.cg_max_iterations);

    // Peak stresses over the PRINTED material (physical density > iso), using
    // the material's solid modulus. Empty/void voxels stay at zero stress.
    std::vector<std::array<double, 6>> stress(grid.voxel_count(),
                                              std::array<double, 6>{});
    double max_von_mises = 0.0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!grid.solid(i, j, k)) continue;
          if (!(rho[grid.index(i, j, k)] > kIso)) continue;
          const std::array<double, 24> ue = element_dofs(grid, sc.solution, i, j, k);
          const Hex8Stress st = hex8_stress(params.youngs_modulus,
                                            params.poisson, grid.spacing, ue);
          stress[grid.index(i, j, k)] = st.sigma;
          if (st.von_mises > max_von_mises) max_von_mises = st.von_mises;
        }
    const double max_interlayer = max_interlayer_tension(grid, stress, build_dir);

    // Worst-case stress margin (M5.2 locked definition).
    const StressMargin margin = compute_stress_margin(
        material.yield_strength_mpa, material.z_knockdown, max_von_mises,
        max_interlayer);

    // §7 V3 property suite on this optimizer output (M3.5).
    variant.v3 = check_v3(grid, rho, kIso);

    // Assemble this rung's report line (M5.2 / M5.2b).
    VariantReport& vr = variant.report;
    vr.volume_fraction = variant.optimization.volume_fraction;
    vr.max_stress_mpa = max_von_mises;
    vr.max_interlayer_tension_mpa = max_interlayer;
    vr.margin = margin;
    vr.orientation = build_dir;
    vr.settings = recommend_settings(rules, material.family, margin.worst_case,
                                     part_dim_mm);
    vr.min_feature_violations = variant.v3.min_feature_violations;
    vr.min_feature_warning =
        min_feature_warning_text(rules, variant.v3.min_feature_violations);

    variant.accepted = margin.worst_case >= options.margin_stop;
    result.evaluated.push_back(std::move(variant));

    if (result.evaluated.back().accepted) {
      result.report.variants.push_back(result.evaluated.back().report);
    } else {
      // First too-weak rung: stop the ladder here (do not run lighter rungs).
      result.stopped_on_margin = true;
      break;
    }
  }

  return result;
}

}  // namespace topopt
