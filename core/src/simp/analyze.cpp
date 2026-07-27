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

// Width-aware gate (handoff 2026-07-26-width-aware-knockdown): the local-thickness
// distance transform sweeps ball radii up to this many voxels. It BOUNDS the cost
// (one seeded EDT per level → O(cap · voxel_count), bar K6) and it sets the
// "thick" cutoff: a voxel still solid under the radius-`cap` opening is at least
// 2·cap·spacing mm thick, gets +inf thickness, and therefore NO wall rescue — the
// conservative treatment of envelope-scale solid regions (bar K4). At production
// spacing (1.5–3 mm on a 200 mm part) 2·32·spacing ≈ 96–192 mm comfortably spans
// 191's ~59–98 mm crossover; at finer spacing the cutoff drops, which only makes
// the thick-region gate MORE conservative.
constexpr int kWidthAwareThicknessCapVoxels = 32;

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

double wall_area_fraction(double member_width_mm, double wall_thickness_mm) {
  const double W = member_width_mm;
  // An unbounded/degenerate width (the "thicker than we measured" sentinel, or a
  // non-member) gets NO wall rescue — the conservative choice (bar K4/K5).
  if (!std::isfinite(W) || W <= 0.0) return 0.0;
  double t = wall_thickness_mm;
  if (!(t > 0.0)) return 0.0;                 // no walls → no rescue
  if (t > 0.5 * W) t = 0.5 * W;               // a ring can't exceed the half-width:
                                              // a member thinner than 2t is all wall
  const double f = 4.0 * t * (W - t) / (W * W);
  return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
}

double width_aware_knockdown(double infill_percent, double member_width_mm,
                             double wall_thickness_mm) {
  // The infill core term is the SAME Gibson-Ashby curve the scalar gate uses — ONE
  // definition of f^1.5 (bar K7). Solid infill → 1.0, so the composite is 1.0 too.
  const double core = infill_margin_knockdown(infill_percent);
  const double fw = wall_area_fraction(member_width_mm, wall_thickness_mm);
  const double k = fw + (1.0 - fw) * core;    // Voigt: walls in parallel with core
  return k > 1.0 ? 1.0 : k;                    // both terms in (0,1] → k in (0,1]
}

FixedDesignAnalysis analyze_fixed_design(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<double>& density, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, const Material& material,
    const Vec3& build_dir, double cg_tolerance, int cg_max_iterations,
    SolverKind solver_kind, double margin_stop, const KnockdownSpec& knockdown,
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

  // --- Width-aware knockdown, part 1: the local member width (handoff
  // 2026-07-26-width-aware-knockdown). When armed, measure the printed field's local
  // thickness ONCE (bar K6) so the gate can credit the slicer's solid wall loops per
  // element. The OFF path never enters here and stays byte-identical. `max_von_mises_eff`
  // is the peak of the SOLID-EQUIVALENT von Mises vm/k(W) — dividing each voxel's
  // stress by its own width-aware knockdown inflates it to the stress a solid part
  // would show, so a thin walled rib (k→1, little inflation) and a thick region
  // (k→f^1.5, large inflation) compete for the worst effective point on the SAME
  // scale. This is what keeps caution on thick sections (bar K4): a thick region
  // whose real stress is only a fraction of the rib peak can still govern once
  // inflated by its small knockdown.
  std::vector<double> member_width_mm;
  double max_von_mises_eff = 0.0;
  if (knockdown.width_aware)
    member_width_mm = local_member_thickness_mm(grid, density, kIso,
                                                kWidthAwareThicknessCapVoxels);

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
        if (knockdown.width_aware) {
          // k_v in (0, 1] (wall_area_fraction in [0,1], core knockdown >= floor),
          // so vm/k_v never divides by zero and only ever inflates the stress.
          const double k_v = width_aware_knockdown(
              knockdown.infill_percent, member_width_mm[grid.index(i, j, k)],
              knockdown.wall_thickness_mm);
          const double vm_eff = st.von_mises / k_v;
          if (vm_eff > max_von_mises_eff) max_von_mises_eff = vm_eff;
        }
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
  // compares). THE CONNECTIVITY BELT ACTS HERE: a severed design is rejected however
  // good its (meaningless, near-zero-stress) margin.
  double margin_effective;
  if (knockdown.width_aware) {
    // --- Width-aware posture (handoff 2026-07-26-width-aware-knockdown) ----------
    // In-plane: the worst SOLID-EQUIVALENT von Mises max(vm/k(W)) over the printed
    // field already folds the per-voxel wall rescue in, so the in-plane effective
    // margin is yield / max_von_mises_eff. Interlayer: 191/192 measured axial and
    // bending only — NOT z-bonding — so the interlayer term keeps the UNMODIFIED
    // f^1.5 (infill_knockdown); passing max_interlayer / infill_knockdown through
    // compute_stress_margin reproduces margin.interlayer * infill_knockdown exactly,
    // so the gate is never made LESS conservative than today on interlayer (bar K4).
    // With no walls (wall_thickness_mm == 0) k(W) == f^1.5 for every voxel, so this
    // collapses to margin.worst_case * infill_knockdown (the scalar path) to within
    // floating point — the armed-but-unconfigured run matches the default posture.
    const double il_scaled = knockdown.infill_knockdown > 0.0
                                 ? max_interlayer / knockdown.infill_knockdown
                                 : max_interlayer;
    const StressMargin me =
        compute_stress_margin(material.yield_strength_mpa, material.z_knockdown,
                              max_von_mises_eff, il_scaled);
    margin_effective = me.worst_case;
  } else {
    // Default posture: the pure scalar f^1.5 gate, byte-for-byte the pre-width gate
    // (infill_knockdown == 1.0 for solid/unset infill → the pre-M7.infill gate).
    margin_effective = margin.worst_case * knockdown.infill_knockdown;
  }
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
