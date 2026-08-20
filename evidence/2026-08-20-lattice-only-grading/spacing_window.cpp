// MEASUREMENT-ONLY probe, task 2026-08-20-lattice-only-grading §4(b)(i).
// "What SPACING RANGE is reachable at a 0.45 mm nozzle?" — reported as two
// numbers, computed from CORE's own strut law (octet_strut_diameter_mm), never a
// second derivation.
//
// Spacing and strut thickness are coupled through mass: the octet's strut
// diameter at unit cell, phi(rho) = octet_strut_diameter_mm(rho, 1), is monotone
// in rho, and diameter is linear in cell, so a cell S emits a strut S*phi(rho).
// Requiring S*phi(rho) >= w gives the printable cell for that density:
//     S >= w / phi(rho).
// The WINDOW's ends are therefore the two band ends:
//     finest printable cell  = w / phi(rho_max)   (densest lattice, fattest strut)
//     coarsest forced cell   = w / phi(rho_min)   (lightest lattice, thinnest strut)
#include <cstdio>
#include <cstdlib>
#include "topopt/lattice.hpp"
using namespace topopt;
int main(int argc, char** argv) {
  const double w = argc > 1 ? std::atof(argv[1]) : 0.45;
  const LatticeTopology t = LatticeTopology::Octet;
  const double rlo = lattice_rho_min(t), rhi = lattice_rho_max(t);
  const double nstar = lattice_cells_per_member_min(t);
  const double phi_lo = octet_strut_diameter_mm(rlo, 1.0);
  const double phi_hi = octet_strut_diameter_mm(rhi, 1.0);
  std::printf("nozzle / min extrudable width : %.3f mm\n", w);
  std::printf("octet band                    : rho [%.5f, %.5f]   N* = %.3f\n", rlo, rhi, nstar);
  std::printf("phi(rho) = strut diameter per unit cell: phi(rho_min)=%.6f  phi(rho_max)=%.6f\n",
              phi_lo, phi_hi);
  const double s_fine = w / phi_hi, s_coarse = w / phi_lo;
  std::printf("\nPRINTABLE CELL/SPACING WINDOW (the two numbers):\n");
  std::printf("  finest  spacing that prints (at rho_max) : %.4f mm\n", s_fine);
  std::printf("  coarsest spacing forced   (at rho_min)   : %.4f mm\n", s_coarse);
  std::printf("  => ratio %.3fx\n", s_coarse / s_fine);
  std::printf("\nAt each end, the member width needed to hold N* cells across:\n");
  std::printf("  at %.4f mm spacing : member >= %.3f mm\n", s_fine, nstar * s_fine);
  std::printf("  at %.4f mm spacing : member >= %.3f mm\n", s_coarse, nstar * s_coarse);
  return 0;
}
