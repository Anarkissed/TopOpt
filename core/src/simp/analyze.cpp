#include "topopt/analyze.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/orient.hpp"
#include "topopt/report.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

namespace {

// The M3.5 iso threshold: a voxel is "printed" (solid material) when its physical
// density exceeds this. Same constant the optimizer's recovery block uses.
constexpr double kIso = 0.5;

// M7.infill-margin seed curve. Kept identical to the optimizer's original
// file-local copy so the acceptance gate is byte-for-byte the pre-extraction gate.
constexpr double kKnockdownExponent = 1.5;
constexpr double kKnockdownFloor = 1e-3;

// Gather one element's 24 nodal displacements from the global solution, in the
// hex8_stiffness DOF order (node-major interleaved). Same helper the recovery
// block used; moved here with the stress loop.
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

double infill_margin_knockdown(double infill_percent) {
  const double f = infill_percent / 100.0;
  if (f >= 1.0) return 1.0;  // solid / unset: exact 1.0, byte-identical gate
  if (f <= 0.0) return kKnockdownFloor;
  return std::max(std::pow(f, kKnockdownExponent), kKnockdownFloor);
}

FixedDesignAnalysis analyze_fixed_design(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<double>& density, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, const Material& material,
    const Vec3& build_dir, double cg_tolerance, int cg_max_iterations,
    SolverKind solver_kind, double margin_stop, double infill_knockdown,
    bool load_path_ok, double part_solid) {
  FixedDesignAnalysis out;

  // Penalized solve on the FIXED density to recover the displacement field. The
  // certification solve is stateless (no warm start, no cached solver) so a
  // re-analysis of the same field is bit-identical. Solver selection matches the
  // originating run via `solver_kind`.
  const SimpCompliance sc =
      simp_compliance(grid, params, density, bcs, loads, cg_tolerance,
                      cg_max_iterations, /*initial_guess=*/nullptr,
                      /*solver=*/nullptr, solver_kind);

  // Peak stresses over the PRINTED material (density > iso), using the solid
  // modulus. Empty/void voxels stay at zero stress. The per-voxel von Mises is
  // retained grid-indexed (M7.0b field (a)); printed voxels are counted for mass.
  std::vector<std::array<double, 6>> stress(grid.voxel_count(),
                                            std::array<double, 6>{});
  out.von_mises_field.assign(grid.voxel_count(), 0.0);
  out.stress_tensor_field.assign(6 * grid.voxel_count(), 0.0);
  const int node_count = fea_node_count(grid);
  std::vector<char> node_printed(static_cast<std::size_t>(node_count), 0);
  std::size_t printed_voxels = 0;
  double max_von_mises = 0.0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        if (!(density[grid.index(i, j, k)] > kIso)) continue;
        ++printed_voxels;
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int n : en) node_printed[static_cast<std::size_t>(n)] = 1;
        const std::array<double, 24> ue = element_dofs(grid, sc.solution, i, j, k);
        const Hex8Stress st = hex8_stress(params.youngs_modulus, params.poisson,
                                          grid.spacing, ue);
        stress[grid.index(i, j, k)] = st.sigma;
        out.von_mises_field[grid.index(i, j, k)] = st.von_mises;
        const std::size_t base = 6 * grid.index(i, j, k);
        for (int c = 0; c < 6; ++c)
          out.stress_tensor_field[base + static_cast<std::size_t>(c)] =
              st.sigma[static_cast<std::size_t>(c)];
        if (st.von_mises > max_von_mises) max_von_mises = st.von_mises;
      }
  const double max_interlayer = max_interlayer_tension(grid, stress, build_dir);

  // Per-node displacement of the SAME solve — no new solve. DOF-ordered; exposed
  // on printed nodes exactly as solved, zeroed on nodes attached only to
  // non-printed voxels (mirrors von_mises_field). Model units (mm).
  out.displacement_field.assign(static_cast<std::size_t>(3 * node_count), 0.0);
  for (int n = 0; n < node_count; ++n) {
    if (!node_printed[static_cast<std::size_t>(n)]) continue;
    for (int c = 0; c < 3; ++c)
      out.displacement_field[static_cast<std::size_t>(3 * n + c)] =
          sc.solution.at(n, c);
  }

  // Printed mass = material density (g/cm^3) * printed volume. Volumes are mm^3;
  // 1 cm^3 = 1000 mm^3, so divide by 1000 to land in grams. Spacing-aware.
  out.mass_grams = material.density_g_cm3 *
                   (static_cast<double>(printed_voxels) * grid.voxel_volume()) /
                   1000.0;

  // Support-volume proxy for the analysed build direction over THIS design's
  // printed geometry: mark non-printed voxels Empty in a copy and count overhangs.
  VoxelGrid printed_grid = grid;
  for (std::size_t idx = 0; idx < printed_grid.tags.size(); ++idx)
    if (!(density[idx] > kIso)) printed_grid.tags[idx] = VoxelTag::Empty;
  out.support_volume_voxels = support_overhang_voxels(printed_grid, build_dir);

  // Printed / thresholded count basis (the SAME voxel count the reported mass is
  // built from): #{density>0.5} / part_solid.
  const double printed_fraction =
      part_solid > 0.0 ? static_cast<double>(printed_voxels) / part_solid : 0.0;

  // Worst-case stress margin (M5.2 locked definition).
  const StressMargin margin = compute_stress_margin(
      material.yield_strength_mpa, material.z_knockdown, max_von_mises,
      max_interlayer);

  // §7 V3 property suite on this fixed design (min-feature count, watertight mesh).
  out.v3 = check_v3(grid, density, kIso);

  // Gate on the INFILL-ADJUSTED worst-case margin (the stored/displayed margin
  // stays the SOLID margin; the knockdown scales ONLY what the acceptance test
  // compares). infill_knockdown == 1.0 for solid/unset infill, so this is
  // bit-for-bit the pre-M7.infill gate. THE CONNECTIVITY BELT ACTS HERE: a severed
  // design is rejected however good its (meaningless, near-zero-stress) margin.
  const double margin_effective = margin.worst_case * infill_knockdown;
  const bool margin_ok = margin_effective >= margin_stop;

  out.printed_voxels = printed_voxels;
  out.printed_fraction = printed_fraction;
  out.max_von_mises = max_von_mises;
  out.max_interlayer_tension = max_interlayer;
  out.margin = margin;
  out.margin_effective = margin_effective;
  out.accepted = load_path_ok && margin_ok;
  return out;
}

}  // namespace topopt
