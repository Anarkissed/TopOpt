#include "topopt/analyze.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <string>
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
    bool load_path_ok, double part_solid, const LatticePosture* lattice) {
  FixedDesignAnalysis out;

  // --- Lattice certification (handoff 2026-07-27-lattice-certification) --------
  // When a LatticePosture is supplied, the certification solve carries each latticed
  // voxel's homogenized effective cubic tensor (fea_solve_cg_lattice) instead of the
  // scalar-penalized isotropic modulus, so the solve is of the REAL composite object.
  // A null posture (the default, every current caller) skips ALL of this and the
  // function is byte-for-byte the pre-lattice path. Validate the posture arrays here.
  const bool has_lattice = (lattice != nullptr);
  std::vector<char> lat_mask;
  std::vector<double> lat_c11, lat_c12, lat_c44;
  if (has_lattice) {
    const std::size_t nv = grid.voxel_count();
    if (lattice->mask.size() != nv || lattice->relative_density.size() != nv)
      throw std::invalid_argument(
          "analyze_fixed_design: LatticePosture mask/relative_density size != "
          "voxel_count");
    lat_mask = lattice->mask;
    lat_c11.assign(nv, 0.0);
    lat_c12.assign(nv, 0.0);
    lat_c44.assign(nv, 0.0);
    // Density band enforced AT CERTIFICATION (lattice certification E2E, bar E5).
    // The band [lattice_rho_min, lattice_rho_max] is the RESOLVED span of PR 198's
    // sweep — the only densities the tensor library is trustworthy at. Outside it,
    // lattice_cubic_tensor would silently CLAMP to the endpoint and certify against
    // a tensor for a DIFFERENT density than the exported file carries. That is the
    // conflation this feature exists to prevent, so a posture asking to certify an
    // out-of-band density is REFUSED here — read from core (lattice_rho_min/max),
    // not hardcoded — rather than certified against a clamped/stale tensor. The band
    // gates the CERTIFICATION, independently of any check the generator made.
    const double rho_min = lattice_rho_min(lattice->topology);
    const double rho_max = lattice_rho_max(lattice->topology);
    for (std::size_t e = 0; e < nv; ++e) {
      if (!lat_mask[e]) continue;
      bool clamped = false;
      const CubicTensor T =
          lattice_cubic_tensor(lattice->topology, lattice->relative_density[e],
                               params.youngs_modulus, &clamped);
      if (clamped)
        throw LatticeDensityOutOfBand(
            lattice->relative_density[e], rho_min, rho_max,
            "analyze_fixed_design: lattice relative density " +
                std::to_string(lattice->relative_density[e]) +
                " is outside the certifiable " +
                std::string(lattice_topology_name(lattice->topology)) + " band [" +
                std::to_string(rho_min) + ", " + std::to_string(rho_max) +
                "] — refusing to certify against a clamped tensor (bar E5)");
      lat_c11[e] = T.C11;
      lat_c12[e] = T.C12;
      lat_c44[e] = T.C44;
    }
  }

  // Penalized solve on the FIXED density to recover the displacement field. The
  // certification solve is stateless (no warm start, no cached solver) so a
  // re-analysis of the same field is bit-identical. Solver selection matches the
  // originating run via `solver_kind`.
  //
  // Handoff 2026-07-27-nonconvergence-rejection — the certification solve runs at the
  // caller's tight `cg_tolerance`, UNCHANGED. If it fails to converge we do NOT soften
  // it, retry it, or let its throw abort the run: we record the failure and return an
  // analysis with `accepted` left FALSE. A design whose certification solve the CG
  // cannot resolve is never certified — the caller rejects that rung. Genuine
  // malformed-problem throws (bad index, void-only system) are NOT caught and still
  // propagate.
  SimpCompliance sc;
  try {
    if (has_lattice) {
      // Composite solve: solid voxels use the scalar-penalized isotropic modulus
      // E(rho) (bit-identical to what simp_compliance builds for them); latticed
      // voxels use their cubic tensor. This is the ASSEMBLED Jacobi-CG path
      // (fea_solve_cg_lattice) — the production accelerator paths (matrix-free,
      // multigrid) remain scalar-modulus, so a latticed certification is assembled
      // regardless of `solver_kind` (see the handoff's scope note). The gate still
      // runs at the caller's tight `cg_tolerance`, UNCHANGED.
      std::vector<double> elem_youngs(grid.voxel_count(), 0.0);
      for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
          for (int i = 0; i < grid.nx; ++i) {
            if (!grid.solid(i, j, k)) continue;
            const std::size_t e = grid.index(i, j, k);
            if (!lat_mask[e]) elem_youngs[e] = simp_youngs(params, density[e]);
          }
      sc.solution = fea_solve_cg_lattice(grid, elem_youngs, lat_mask, lat_c11,
                                         lat_c12, lat_c44, params.poisson, bcs,
                                         loads, cg_tolerance, cg_max_iterations,
                                         &sc.cg);
    } else {
      sc = simp_compliance(grid, params, density, bcs, loads, cg_tolerance,
                           cg_max_iterations, /*initial_guess=*/nullptr,
                           /*solver=*/nullptr, solver_kind);
    }
  } catch (const SolverNonConvergence& e) {
    out.non_convergent = true;
    out.non_convergent_iteration = e.iterations;
    out.non_convergent_residual = e.residual;
    // Invariant (asserted, not commented): a non-converged certification solve can
    // NEVER yield an accepted design. `accepted` is default-false and the early
    // return leaves it untouched, below every gate.
    assert(out.accepted == false &&
           "non-convergence rejection: a failed certification solve must never "
           "certify a design");
    return out;
  }

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

  // Lattice accounting (all inert when has_lattice is false). `effective_material`
  // is the mass-bearing volume in voxel-equivalents: a solid printed voxel counts 1,
  // a latticed printed voxel counts its relative density (the lattice fills only that
  // fraction of the envelope). A latticed voxel's stress is the EFFECTIVE (macro)
  // stress and is EXCLUDED from the solid strength maxima (max_von_mises,
  // max_von_mises_eff) and from the interlayer field — its strut-level strength is not
  // certifiable from the macro stress (Phase 2). It IS recorded in the fields.
  double effective_material = 0.0;
  std::size_t lattice_voxels = 0;
  double lat_rho_lo = 1e300, lat_rho_hi = -1e300, lat_max_vm = 0.0;

  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t idx = grid.index(i, j, k);
        if (!(density[idx] > kIso)) continue;
        ++printed_voxels;
        const bool is_lat = has_lattice && lat_mask[idx];
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int n : en) node_printed[static_cast<std::size_t>(n)] = 1;
        const std::array<double, 24> ue = element_dofs(grid, sc.solution, i, j, k);
        const std::size_t base = 6 * idx;
        if (is_lat) {
          // EFFECTIVE (macro) stress of the latticed element — its own cubic tensor.
          const Hex8Stress st = hex8_stress_cubic(lat_c11[idx], lat_c12[idx],
                                                  lat_c44[idx], grid.spacing, ue);
          out.von_mises_field[idx] = st.von_mises;
          for (int c = 0; c < 6; ++c)
            out.stress_tensor_field[base + static_cast<std::size_t>(c)] =
                st.sigma[static_cast<std::size_t>(c)];
          // `stress[idx]` stays zero -> excluded from interlayer. Excluded from the
          // solid strength maxima too. Tracked separately.
          ++lattice_voxels;
          const double rho = lattice->relative_density[idx];
          lat_rho_lo = std::min(lat_rho_lo, rho);
          lat_rho_hi = std::max(lat_rho_hi, rho);
          lat_max_vm = std::max(lat_max_vm, st.von_mises);
          effective_material += rho;
        } else {
          const Hex8Stress st = hex8_stress(params.youngs_modulus, params.poisson,
                                            grid.spacing, ue);
          stress[idx] = st.sigma;
          out.von_mises_field[idx] = st.von_mises;
          if (knockdown.width_aware) {
            // k_v in (0, 1] (wall_area_fraction in [0,1], core knockdown >= floor),
            // so vm/k_v never divides by zero and only ever inflates the stress.
            const double k_v = width_aware_knockdown(
                knockdown.infill_percent, member_width_mm[idx],
                knockdown.wall_thickness_mm);
            const double vm_eff = st.von_mises / k_v;
            if (vm_eff > max_von_mises_eff) max_von_mises_eff = vm_eff;
          }
          for (int c = 0; c < 6; ++c)
            out.stress_tensor_field[base + static_cast<std::size_t>(c)] =
                st.sigma[static_cast<std::size_t>(c)];
          if (st.von_mises > max_von_mises) max_von_mises = st.von_mises;
          effective_material += 1.0;
        }
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
  // `effective_material` is the mass-bearing volume in voxel-equivalents: a solid
  // printed voxel contributes 1, a latticed one contributes its relative density.
  // With no lattice region it equals printed_voxels exactly (a sum of 1.0's), so the
  // mass is byte-identical to the pre-lattice path.
  out.mass_grams = material.density_g_cm3 *
                   (effective_material * grid.voxel_volume()) / 1000.0;

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

  // Lattice reporting (all default when no posture was applied). `margin`/`accepted`
  // above are the SOLID region's strength over the real composite field; the lattice
  // region contributed its true (softer) stiffness to that field but its strut-level
  // strength is NOT gated here (Phase 2 de-homogenization). See FixedDesignAnalysis.
  if (has_lattice) {
    out.lattice_certified = true;
    out.lattice_topology = lattice->topology;
    out.lattice_cell_size_mm = lattice->cell_size_mm;
    out.lattice_voxels = lattice_voxels;
    out.lattice_rho_min = lattice_voxels ? lat_rho_lo : 0.0;
    out.lattice_rho_max = lattice_voxels ? lat_rho_hi : 0.0;
    out.lattice_max_effective_vm = lat_max_vm;
    out.lattice_strength_uncertified = (lattice_voxels > 0);
  }
  return out;
}

}  // namespace topopt
