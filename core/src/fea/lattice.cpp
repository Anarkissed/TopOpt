#include "topopt/lattice.hpp"

#include <array>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace topopt {

namespace {

// --- Octet unit-cell geometry (rho basis) ----------------------------------
// The octet strut segments of a UNIT cell (edge 1), copied operation-for-operation
// from PR 198's homogenization probe (lattice_homog_probe.cpp `octet_struts`): the
// 6 face-centre nodes each join the 4 cube corners of their face. This is the SAME
// geometry the tensor library rows were measured on, so voxelizing it recovers the
// library's rho scale exactly. Struts are cylinders of radius r (the point-segment
// distance field), matching `octet_dist2 < r*r`.
std::vector<std::array<std::array<double, 3>, 2>> octet_unit_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0},
                                                    {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5},
                                                    {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5},
                                                    {1.0, 0.5, 0.5}}};
  std::vector<std::array<double, 3>> all(nodes);
  for (const auto& f : fc) all.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  for (std::size_t fi = 8; fi < all.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0.0;
      for (int k = 0; k < 3; ++k) {
        const double v = all[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (all[ci][k] - v) * (all[ci][k] - v);
      }
      if (d2 < 1e-9) segs.push_back({all[fi], all[ci]});
    }
  return segs;
}

// Squared distance from unit-cell point (x,y,z) to the nearest strut segment.
double octet_point_dist2(
    double x, double y, double z,
    const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  double best = 1e30;
  for (const auto& s : segs) {
    const double ax = s[0][0], ay = s[0][1], az = s[0][2];
    const double bx = s[1][0], by = s[1][1], bz = s[1][2];
    const double ex = bx - ax, ey = by - ay, ez = bz - az;
    const double len2 = ex * ex + ey * ey + ez * ez;
    double t = 0.0;
    if (len2 > 0.0)
      t = ((x - ax) * ex + (y - ay) * ey + (z - az) * ez) / len2;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const double dx = x - (ax + t * ex), dy = y - (ay + t * ey),
                 dz = z - (az + t * ez);
    const double d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < best) best = d2;
  }
  return best;
}

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

double octet_relative_density(double cell_mm, double strut_radius_mm) {
  if (!(cell_mm > 0.0) || !std::isfinite(cell_mm))
    throw std::invalid_argument(
        "octet_relative_density: cell_mm must be finite and > 0");
  if (!(strut_radius_mm > 0.0) || !std::isfinite(strut_radius_mm))
    throw std::invalid_argument(
        "octet_relative_density: strut_radius_mm must be finite and > 0");

  // Voxelize ONE cell on the library's basis (vpc48). The field depends only on
  // the ratio r/L (a unit cell with unit-cell radius), so cell_mm cancels and the
  // result is cell-size invariant — the whole reason a homogenized cell adds no DOF.
  const double r_unit = strut_radius_mm / cell_mm;
  const auto segs = octet_unit_struts();
  const int vpc = kLatticeLibraryVpc;
  const double r2 = r_unit * r_unit;
  long long solid = 0;
  const long long total = static_cast<long long>(vpc) * vpc * vpc;
  for (int k = 0; k < vpc; ++k)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        // Voxel centre in unit-cell coordinates (matches build_lattice's
        // voxel_center on a cell of edge 1).
        const double x = (i + 0.5) / vpc;
        const double y = (j + 0.5) / vpc;
        const double z = (k + 0.5) / vpc;
        if (octet_point_dist2(x, y, z, segs) < r2) ++solid;
      }
  const double rho = static_cast<double>(solid) / static_cast<double>(total);
  if (!(rho > 0.0) || rho >= 1.0)
    throw std::invalid_argument(
        "octet_relative_density: strut radius produced a degenerate cell "
        "(rho outside (0,1)) — check cell_mm / strut_radius_mm");
  return rho;
}

}  // namespace topopt
