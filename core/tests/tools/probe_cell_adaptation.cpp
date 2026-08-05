// R2 PROBE — the defect this task fixes, demonstrated on UNFIXED code.
//
// A wall of measured thickness W is handed to the grading law with a 0.42 mm nozzle.
// Today the law's cell comes from lattice_cell_printability_floor_mm, which is
// evaluated at the band's LIGHTEST density (lattice.cpp:394-404) — so the cell is the
// one that keeps a rho_min strut printable, and NOTHING thinner than N* times that
// cell can be latticed. That is the "23 mm member" number, and its condition (rho at
// the band floor) has never been surfaced.
//
// The probe prints, for a ladder of wall thicknesses, whether the shipped law
// lattices the wall — and what the derivation in this task says instead.

#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <vector>

using namespace topopt;

// A slab `tv` voxels thick in x, spanning y/z, with an Empty margin on every side so
// the local-thickness measure sees free surfaces (same helper shape as test_grading).
static VoxelGrid slab(int tv, int span, double h, int pad = 4) {
  VoxelGrid g;
  g.nx = tv + 2 * pad; g.ny = span + 2 * pad; g.nz = span + 2 * pad; g.spacing = h;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  for (int k = 0; k < span; ++k)
    for (int j = 0; j < span; ++j)
      for (int i = 0; i < tv; ++i)
        g.set_tag(i + pad, j + pad, k + pad, VoxelTag::Interior);
  return g;
}

int main() {
  const LatticeTopology topo = LatticeTopology::Octet;
  const double w_min = 0.42;  // the maintainer's nozzle
  const double n_star = lattice_cells_per_member_min(topo);
  const double rho_lo = lattice_rho_min(topo);
  const double rho_hi = lattice_rho_max(topo);
  const double phi_lo = octet_strut_diameter_mm(rho_lo, 1.0);
  const double phi_hi = octet_strut_diameter_mm(rho_hi, 1.0);

  std::printf("band rho [%.4f, %.4f]   N* = %.2f   w_min = %.2f mm\n", rho_lo, rho_hi,
              n_star, w_min);
  std::printf("phi(rho_min) = %.6f mm of strut per mm of cell\n", phi_lo);
  std::printf("phi(rho_max) = %.6f mm of strut per mm of cell\n", phi_hi);
  std::printf("SHIPPED floor cell  = w_min/phi(rho_min) = %.4f mm  -> N* cells span %.4f mm\n",
              w_min / phi_lo, n_star * w_min / phi_lo);
  std::printf("DERIVED floor cell  = w_min/phi(rho_max) = %.4f mm  -> N* cells span %.4f mm\n\n",
              w_min / phi_hi, n_star * w_min / phi_hi);

  std::printf("%-10s %-8s %10s %12s %12s %10s\n", "wall_mm", "voxels", "tau_mm",
              "latticed", "solid_back", "cell_mm");
  // Voxel edge 0.5 mm; the slab spans 60 mm in y and z so the largest INSCRIBED
  // SPHERE is pinned by the wall thickness and not by the span (tau = min extent).
  const double h = 0.5;
  for (int tv : {4, 8, 11, 12, 16, 24, 32, 46, 48, 56}) {
    VoxelGrid g = slab(tv, 120, h);
    std::vector<double> dens(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (g.tags[e] != VoxelTag::Empty) dens[e] = 1.0;
    std::vector<double> demand(g.voxel_count(), 1.0);

    GradingLawParams p;
    p.topology = topo;
    p.cell_mode = CellSizeMode::Auto;  // core picks the cell — no user number
    p.min_extrudable_width_mm = w_min;
    p.demand_exponent = 1.0;

    // The measured member width the law itself reads, at the law's own cap.
    const std::vector<double> tau =
        local_member_thickness_mm(g, dens, 0.5, p.thickness_cap_voxels);
    double tau_mid = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (dens[e] >= 0.5 && tau[e] > tau_mid) tau_mid = tau[e];

    const GradedField gf = grade_lattice(g, dens, demand, nullptr, p);
    std::printf("%-10.2f %-8d %10.2f %12zu %12zu %10.4f\n", tv * h, tv, tau_mid,
                gf.latticed_voxels, gf.solid_fallback_voxels, gf.cell_size_mm);
  }

  // ── STAGE A: the same ladder, answered PER MEMBER. Pure arithmetic on core's own
  // constants — no grid, no solve.
  std::printf("\nSTAGE A derivation (topology octet, w_min = %.2f mm, N* = %.2f):\n",
              w_min, n_star);
  std::printf("  the thinnest member that can hold a certified lattice = %.4f mm\n\n",
              lattice_derive_cell_for_member(topo, 1e9, w_min).min_member_width_mm);
  std::printf("%-9s %-9s | %-9s %-8s %-8s %-6s | %-9s %-8s %-8s %-6s\n", "wall_mm",
              "feasible", "fine_cell", "fine_rho", "fine_d", "fine_n", "coarse_cl",
              "coar_rho", "coarse_d", "coar_n");
  for (double W : {2.0, 4.0, 5.0, 5.4748, 5.5, 6.0, 8.0, 10.0, 12.0, 16.0, 23.0,
                   24.0, 30.0}) {
    const LatticeCellDerivation d = lattice_derive_cell_for_member(topo, W, w_min);
    if (!d.feasible) {
      std::printf("%-9.4f %-9s | NO (cell, rho) PAIR: printable cell >= %.4f mm but "
                  "homogenizable cell <= %.4f mm — thicken to %.4f mm\n",
                  W, "no", d.min_printable_cell_mm, d.max_homogenizable_cell_mm,
                  d.min_member_width_mm);
      continue;
    }
    std::printf("%-9.4f %-9s | %-9.4f %-8.4f %-8.4f %-6.2f | %-9.4f %-8.4f %-8.4f %-6.2f\n",
                W, "yes", d.densest_cell_size_mm, d.densest_relative_density,
                d.densest_strut_diameter_mm, d.densest_cells_per_member,
                d.lightest_cell_size_mm, d.lightest_relative_density,
                d.lightest_strut_diameter_mm, d.lightest_cells_per_member);
  }
  return 0;
}
