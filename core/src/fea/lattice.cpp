#include "topopt/lattice.hpp"

#include <array>
#include <stdexcept>

namespace topopt {

namespace {

// The solid modulus PR 198's library was measured at (materials.json PLA E).
// Effective stiffness is exactly linear in the solid modulus (linear elasticity),
// so a query at any Es scales these rows by Es / kLibraryEs.
constexpr double kLibraryEs = 3500.0;

struct Row {
  double rho, C11, C12, C44;  // MPa at Es = 3500
  bool resolved;              // wall >= 4 voxels at vpc48
};

// OCTET — copied VERBATIM from PR 198's octet rows in
// evidence/2026-07-26-lattice-homog-phase0/tensor_library.csv (L=5 mm, vpc=48,
// Es=3500). Ordered by relative density. The first row (rho 0.103) is the
// under-resolved (wall < 4 vox) row PR 198 flagged and excluded from its fits; it
// is kept here for provenance but the interpolation range is the resolved rows only.
constexpr std::array<Row, 8> kOctet = {{
    {0.10308, 88.2389, 41.9795, 37.3012, false},
    {0.14764, 136.9621, 64.0645, 56.6726, true},
    {0.20414, 213.7779, 94.5363, 83.3612, true},
    {0.25297, 295.1031, 124.0143, 109.1889, true},
    {0.29731, 374.2029, 151.9733, 135.0535, true},
    {0.39786, 611.4884, 226.3148, 204.0181, true},
    {0.50644, 974.8665, 328.8413, 297.3223, true},
    {0.59093, 1344.7034, 443.6894, 392.1883, true},
}};

const std::array<Row, 8>& rows_of(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:
      return kOctet;
  }
  return kOctet;
}

// Index range [lo, hi] of the RESOLVED rows (the interpolation domain).
void resolved_span(const std::array<Row, 8>& rows, int& lo, int& hi) {
  lo = 0;
  while (lo < static_cast<int>(rows.size()) && !rows[lo].resolved) ++lo;
  hi = static_cast<int>(rows.size()) - 1;
  while (hi > lo && !rows[hi].resolved) --hi;
}

}  // namespace

const char* lattice_topology_name(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:
      return "octet";
  }
  return "?";
}

double lattice_rho_min(LatticeTopology topo) {
  const std::array<Row, 8>& rows = rows_of(topo);
  int lo, hi;
  resolved_span(rows, lo, hi);
  return rows[lo].rho;
}

double lattice_rho_max(LatticeTopology topo) {
  const std::array<Row, 8>& rows = rows_of(topo);
  int lo, hi;
  resolved_span(rows, lo, hi);
  return rows[hi].rho;
}

CubicTensor lattice_cubic_tensor(LatticeTopology topo, double rho,
                                 double youngs_modulus_solid, bool* rho_clamped) {
  if (!(youngs_modulus_solid > 0.0))
    throw std::invalid_argument(
        "lattice_cubic_tensor: youngs_modulus_solid must be > 0");
  const std::array<Row, 8>& rows = rows_of(topo);
  int lo, hi;
  resolved_span(rows, lo, hi);

  bool clamped = false;
  double r = rho;
  if (r <= rows[lo].rho) {
    r = rows[lo].rho;
    clamped = (rho < rows[lo].rho);
  } else if (r >= rows[hi].rho) {
    r = rows[hi].rho;
    clamped = (rho > rows[hi].rho);
  }
  if (rho_clamped) *rho_clamped = clamped;

  // Piecewise-linear interpolation in rho between the two bracketing resolved rows.
  int a = lo;
  while (a < hi && rows[a + 1].rho < r) ++a;
  const Row& r0 = rows[a];
  const Row& r1 = rows[a + 1 <= hi ? a + 1 : hi];
  double t = 0.0;
  if (r1.rho > r0.rho) t = (r - r0.rho) / (r1.rho - r0.rho);
  const double scale = youngs_modulus_solid / kLibraryEs;

  CubicTensor out;
  out.C11 = (r0.C11 + t * (r1.C11 - r0.C11)) * scale;
  out.C12 = (r0.C12 + t * (r1.C12 - r0.C12)) * scale;
  out.C44 = (r0.C44 + t * (r1.C44 - r0.C44)) * scale;
  return out;
}

}  // namespace topopt
