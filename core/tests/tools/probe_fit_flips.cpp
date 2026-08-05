// probe_fit_flips.cpp — task 2026-08-05-lattice-cell-fit-mode, bar R2.
//
// THE FLIP TABLE, at the level of the LAW. Bar R2 inverts the usual rule: the flips
// this task causes ARE the deliverable, so every one of them has to be enumerated
// with the cell and density before and after and why it moved. This probe produces
// the machine-checkable half of that table — the CELL LAW's own before/after on the
// same input, so a reader can see exactly which inputs move and which do not.
//
// IT ALSO DISCHARGES A DEBT THE TEST SUITE OTHERWISE HIDES. Three shipped fixtures
// stated a Fixed target BELOW the rho_min printability floor and were therefore
// measuring the RAISED cell:
//     core/tests/unit/test_grading.cpp        p.target_cell_size_mm  = 2.0  (bead 0.4)
//     core/tests/unit/test_grading.cpp        wp.target_cell_size_mm = 2.0  (bead 0.4)
//     core/tests/validation/test_lattice_hookup.cpp  grading.cell_mm = 3.0 (bead 0.4)
// Under S2 those targets survive instead of being raised, which re-points a dozen
// unrelated bars at a different cell. Each was PINNED to the floor it used to be
// raised to, read from core. Pinning keeps those bars measuring what they were
// written to measure — and it also means the suite no longer shows what the unpinned
// value now does. THIS PROBE SHOWS IT, so the change is reported rather than
// concealed by the pin.
//
//   cmake --build core/build --target probe_fit_flips
//   ./core/build/probe_fit_flips

#include "topopt/cell_plan.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

namespace {

// A solid block with a free-surface margin, exactly as test_grading builds it: a
// fully-solid grid has no boundary, so the local-thickness measure would report every
// voxel infinitely thick and no cells-per-member question would mean anything.
VoxelGrid solid_block(int sx, int sy, int sz, double h, int pad = 3) {
  VoxelGrid g;
  g.nx = sx + 2 * pad; g.ny = sy + 2 * pad; g.nz = sz + 2 * pad; g.spacing = h;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  for (int k = 0; k < sz; ++k)
    for (int j = 0; j < sy; ++j)
      for (int i = 0; i < sx; ++i)
        g.set_tag(i + pad, j + pad, k + pad, VoxelTag::Interior);
  return g;
}

std::vector<double> density_of(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.tag(i, j, k) != VoxelTag::Empty) d[g.index(i, j, k)] = 1.0;
  return d;
}

// The PRE-S2 uniform cell law, restated here so the "before" column is computed
// rather than remembered: Auto took the rho_min floor, Fixed took max(target, that
// same floor), and the density was never raised.
double pre_s2_cell(CellSizeMode mode, double target, double bead) {
  const double floor_mm =
      lattice_cell_printability_floor_mm(LatticeTopology::Octet, bead);
  return mode == CellSizeMode::Auto ? floor_mm : std::max(target, floor_mm);
}

struct Row {
  std::string what;
  double bead = 0.0;
  double wall_mm = 0.0;
  double target = 0.0;
  CellSizeMode mode = CellSizeMode::Fixed;
};

void run_row(const Row& r) {
  const LatticeTopology topo = LatticeTopology::Octet;
  const double h = 0.5;
  const int nz = static_cast<int>(std::lround(r.wall_mm / h));
  const VoxelGrid g = solid_block(40, 40, nz, h);
  const std::vector<double> d = density_of(g);
  std::vector<double> dem(g.voxel_count(), 0.0);
  dem[g.index(3 + 20, 3 + 20, 3 + nz / 2)] = 1.0;   // one hot voxel, quiet remainder

  GradingLawParams p;
  p.topology = topo;
  p.min_extrudable_width_mm = r.bead;
  p.cell_mode = r.mode;
  p.target_cell_size_mm = r.target;

  // BEFORE: the pre-S2 cell, expressed as a Fixed target the CURRENT law cannot
  // move (it is at or above the rho_min floor by construction), which is exactly
  // what makes it a faithful replay rather than a second implementation.
  GradingLawParams before = p;
  before.cell_mode = CellSizeMode::Fixed;
  before.target_cell_size_mm = pre_s2_cell(r.mode, r.target, r.bead);
  const GradedField B = grade_lattice(g, d, dem, nullptr, before);
  const GradedField A = grade_lattice(g, d, dem, nullptr, p);

  std::printf("%-46s bead %.2f wall %6.2f target %7.4f (%s)\n", r.what.c_str(),
              r.bead, r.wall_mm, r.target, cell_size_mode_name(r.mode));
  std::printf("    BEFORE cell %8.4f  latticed %6zu  fallback %6zu  rho [%.4f, %.4f]"
              "  raised %zu\n",
              B.cell_size_mm, B.latticed_voxels, B.solid_fallback_voxels,
              B.latticed_voxels ? B.rho_min_used : 0.0,
              B.latticed_voxels ? B.rho_max_used : 0.0,
              B.density_raised_for_print_voxels);
  std::printf("    AFTER  cell %8.4f  latticed %6zu  fallback %6zu  rho [%.4f, %.4f]"
              "  raised %zu\n",
              A.cell_size_mm, A.latticed_voxels, A.solid_fallback_voxels,
              A.latticed_voxels ? A.rho_min_used : 0.0,
              A.latticed_voxels ? A.rho_max_used : 0.0,
              A.density_raised_for_print_voxels);
  const bool moved = B.latticed_voxels != A.latticed_voxels ||
                     std::fabs(B.cell_size_mm - A.cell_size_mm) > 1e-12;
  std::printf("    => %s\n\n", moved ? "MOVED" : "identical");
}

}  // namespace

int main() {
  const LatticeTopology topo = LatticeTopology::Octet;
  std::printf("band rho [%.4f, %.4f]   N* = %.2f   percolation floor = %.2f\n",
              lattice_rho_min(topo), lattice_rho_max(topo),
              lattice_cells_per_member_min(topo),
              lattice_percolation_cells_per_member_min(topo));
  for (const double bead : {0.42, 0.40, 0.20}) {
    const double f_lo = lattice_cell_printability_floor_mm(topo, bead);
    const double f_hi = bead / octet_strut_diameter_mm(lattice_rho_max(topo), 1.0);
    std::printf("bead %.2f mm: rho_min floor %.4f mm (needs %.4f mm of member); "
                "floor that BINDS %.4f mm (needs %.4f mm)\n",
                bead, f_lo, f_lo * lattice_cells_per_member_min(topo), f_hi,
                f_hi * lattice_cells_per_member_min(topo));
  }
  std::printf("\n");

  // ── the three PINNED fixtures, at their ORIGINAL (unpinned) values ─────────────
  // The TARGET and BEAD are the fixtures'; the member is this probe's own block, so
  // these rows say what the unpinned target does to the CELL LAW, not what those
  // fixtures' own geometry would produce.
  run_row({"unpinned 2.0 @ bead 0.40 (test_grading), 15 mm member", 0.40, 15.0, 2.0,
           CellSizeMode::Fixed});
  run_row({"unpinned 2.0 @ bead 0.40 (test_grading), 4 mm member",  0.40,  4.0, 2.0,
           CellSizeMode::Fixed});
  run_row({"unpinned 3.0 @ bead 0.40 (hookup), 15 mm member",       0.40, 15.0, 3.0,
           CellSizeMode::Fixed});
  // ── the maintainer's own numbers ──────────────────────────────────────────────
  run_row({"his bead, his wall, hand-set 1.2",         0.42,  4.0, 1.2,
           CellSizeMode::Fixed});
  run_row({"his bead, a 8 mm member, hand-set 1.2",    0.42,  8.0, 1.2,
           CellSizeMode::Fixed});
  run_row({"his bead, a 30 mm boss, hand-set 1.2",     0.42, 30.0, 1.2,
           CellSizeMode::Fixed});
  // ── the inertness controls: at or above the rho_min floor, nothing moves ──────
  run_row({"CONTROL target above the rho_min floor",   0.42, 30.0, 6.0,
           CellSizeMode::Fixed});
  run_row({"CONTROL auto (never redefined, bar S4)",   0.42, 30.0, 0.0,
           CellSizeMode::Auto});
  run_row({"CONTROL auto on a thin wall",              0.42,  4.0, 0.0,
           CellSizeMode::Auto});

  // ── FIT, per region extent: what the mode derives, at his bead ────────────────
  std::printf("FIT derivation at a %.2f mm bead — cell = max(extent / N*, finest "
              "printable cell)\n", 0.42);
  std::printf("  extent mm | derived cell | rho     | strut mm | cells/member | "
              "floor in force\n");
  for (const double extent : {2.0, 4.0, 5.4748, 6.0, 8.0, 12.0, 24.0, 30.0}) {
    const LatticeCellDerivation dv =
        lattice_derive_cell_for_member(topo, extent, 0.42);
    if (!dv.feasible_percolation) {
      std::printf("  %9.4f | (no printable AND percolating pair — refused; needs "
                  "%.4f mm)\n", extent, dv.min_member_width_buildable_mm);
      continue;
    }
    const double cell = std::max(extent / lattice_cells_per_member_min(topo),
                                 dv.min_printable_cell_mm);
    const double rho = lattice_min_density_for_strut(topo, cell, 0.42);
    const double r = rho >= 0.0 ? rho : lattice_rho_max(topo);
    const double cpm = extent / cell;
    std::printf("  %9.4f | %12.4f | %7.4f | %8.4f | %12.2f | %s\n", extent, cell, r,
                octet_strut_diameter_mm(r, cell), cpm,
                cpm < lattice_cells_per_member_min(topo)
                    ? "PERCOLATION (accuracy unreachable) — OUT OF REGIME"
                    : "ACCURACY");
  }
  return 0;
}
