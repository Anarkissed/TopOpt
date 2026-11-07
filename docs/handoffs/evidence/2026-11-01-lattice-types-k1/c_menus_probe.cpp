// Stepped menus per strut type, 12 mm base, 0.45 mm bead: AFTER (geometry rule, the tree)
// vs BEFORE (density 0.20 on each type's law; octet's old menu is the approved one, its
// legs-only law is gone from the tree).
#include "topopt/lattice.hpp"
#include "topopt/stepped_plan.hpp"
#include <cstdio>
#include <vector>
#include <algorithm>
#include <cmath>
#include <functional>
using namespace topopt;
int main() {
  const double base = 12.0, bead = 0.45;
  const LatticeTopology ts[] = {LatticeTopology::Octet, LatticeTopology::Fcc, LatticeTopology::Kelvin,
      LatticeTopology::Rhombic, LatticeTopology::Diamond, LatticeTopology::Bcc, LatticeTopology::SimpleCubic};
  for (LatticeTopology t : ts) {
    std::printf("%-8s after :", lattice_topology_name(t));
    for (double c : stepped_size_menu(t, base, bead)) std::printf(" %.4g", c);
    std::printf("\n%-8s before:", lattice_topology_name(t));
    // The rule admits a DIVISOR when its tile (base/n) prints open; the menu is k*tile.
    std::vector<double> m{base};
    for (int n : stepped_admitted_divisors(t, base, bead, 0.0, false)) {
      const double tile = base / n;
      bool open = tile > bead;
      try { open = open && lattice_density_from_strut(t, tile, 0.5 * bead) <= 0.20; }
      catch (...) { open = open && tile > lattice_min_printable_cell_mm(t, bead, 0.20); }
      if (open) for (int k = 1; k < n; ++k) m.push_back(k * tile);
    }
    std::sort(m.begin(), m.end(), std::greater<double>());
    m.erase(std::unique(m.begin(), m.end(), [](double a, double b) { return std::fabs(a - b) < 1e-9; }), m.end());
    for (double c : m) std::printf(" %.4g", c);
    std::printf("   tiles:");
    for (int n : stepped_admitted_divisors(t, base, bead)) std::printf(" %.4g", base / n);
    std::printf("   | rho of a bead-wide strut at 0.1898 of the tile: %.4f\n",
                lattice_density_from_strut(t, bead / kSteppedPrintsOpenMaxStrutPerCell, 0.5 * bead));
  }
  // The coarser Auto octet floor in plain words: the old 4.931378 mm floor's strut was a
  // 0.45 mm bead; what density does the full octet hold there?
  std::printf("octet at the OLD light floor 4.931378 mm, 0.45 mm strut: rho %.4f (claimed 0.05)\n",
              lattice_density_from_strut(LatticeTopology::Octet, 4.931378498, 0.225));
  std::printf("octet NEW light floor: %.4f mm\n", lattice_cell_printability_floor_mm(LatticeTopology::Octet, 0.45));
}
