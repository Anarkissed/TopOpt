#include "topopt/grading.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

#include "topopt/lattice.hpp"  // lattice_rho_min/max, lattice_cells_per_member_min,
                               // octet_strut_diameter_mm
#include "topopt/voxel.hpp"    // local_member_thickness_mm

namespace topopt {

GradedField grade_lattice(const VoxelGrid& grid,
                          const std::vector<double>& density,
                          const std::vector<double>& demand,
                          const std::vector<char>* region,
                          const GradingLawParams& params, double iso) {
  const std::size_t n = grid.voxel_count();
  if (density.size() != n)
    throw std::invalid_argument("grade_lattice: density.size() != voxel_count");
  if (demand.size() != n)
    throw std::invalid_argument("grade_lattice: demand.size() != voxel_count");
  if (region && region->size() != n)
    throw std::invalid_argument("grade_lattice: region->size() != voxel_count");
  if (!(params.target_cell_size_mm > 0.0))
    throw std::invalid_argument("grade_lattice: target_cell_size_mm must be > 0");
  if (!(params.min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "grade_lattice: min_extrudable_width_mm must be > 0");
  if (!(params.demand_exponent > 0.0))
    throw std::invalid_argument("grade_lattice: demand_exponent must be > 0");
  if (params.thickness_cap_voxels < 1)
    throw std::invalid_argument("grade_lattice: thickness_cap_voxels must be >= 1");

  const LatticeTopology topo = params.topology;

  GradedField out;
  // ── the limits, READ from core (never hardcoded here) ──────────────────────────
  const double rho_lo = lattice_rho_min(topo);
  const double rho_hi = lattice_rho_max(topo);
  const double n_star = lattice_cells_per_member_min(topo);
  out.band_rho_min = rho_lo;
  out.band_rho_max = rho_hi;
  out.cells_per_member_floor = n_star;

  // ── the printability floor (requirement 3) ──────────────────────────────────────
  // The thinnest strut at any cell occurs at rho_lo (diameter is monotone in rho), so
  // the floor is the cell that prints the rho_lo strut at exactly the stated minimum
  // width. Diameter is linear in cell, so phi_lo = diameter at a unit cell and the
  // floor is min_width / phi_lo.
  const double phi_lo = octet_strut_diameter_mm(rho_lo, 1.0);
  const double floor_mm = params.min_extrudable_width_mm / phi_lo;
  const double cell = std::max(params.target_cell_size_mm, floor_mm);
  out.printability_floor_mm = floor_mm;
  out.cell_size_floored = params.target_cell_size_mm < floor_mm;
  out.cell_size_mm = cell;

  // ── the local member width field (PR 206) ───────────────────────────────────────
  const std::vector<double> width =
      local_member_thickness_mm(grid, density, iso, params.thickness_cap_voxels);

  // ── normalise demand over the candidate set ─────────────────────────────────────
  double demand_max = 0.0;
  for (std::size_t e = 0; e < n; ++e) {
    const bool candidate =
        density[e] > iso && (!region || (*region)[e] != 0);
    if (candidate && std::isfinite(demand[e]) && demand[e] > demand_max)
      demand_max = demand[e];
  }

  // ── grade ───────────────────────────────────────────────────────────────────────
  LatticePosture& post = out.posture;
  post.topology = topo;
  post.cell_size_mm = cell;
  post.mask.assign(n, 0);
  post.relative_density.assign(n, 0.0);

  const double kInf = std::numeric_limits<double>::infinity();
  double rho_min_used = kInf, rho_max_used = 0.0;
  double min_width = kInf, min_cpm = kInf;
  double min_d = kInf, max_d = 0.0;
  const double gamma = params.demand_exponent;

  for (std::size_t e = 0; e < n; ++e) {
    const bool candidate =
        density[e] > iso && (!region || (*region)[e] != 0);
    if (!candidate) continue;
    ++out.region_voxels;

    // Cells-per-member ceiling (requirement 2): a +inf width (thicker than the EDT
    // cap) yields +inf cells-across and always clears the floor.
    const double cpm = width[e] / cell;
    if (cpm < n_star) {
      // L4 — no printable cell holds the floor in this member: it STAYS SOLID.
      ++out.solid_fallback_voxels;
      continue;
    }

    // Density map, clamped into the certifiable band (requirement 1 / L2).
    const double frac =
        demand_max > 0.0 ? std::min(1.0, std::max(0.0, demand[e] / demand_max))
                         : 0.0;
    double rho = rho_hi * std::pow(frac, gamma);
    if (rho < rho_lo) rho = rho_lo;
    if (rho > rho_hi) rho = rho_hi;

    post.mask[e] = 1;
    post.relative_density[e] = rho;
    ++out.latticed_voxels;

    if (rho < rho_min_used) rho_min_used = rho;
    if (rho > rho_max_used) rho_max_used = rho;
    if (width[e] < min_width) min_width = width[e];
    if (cpm < min_cpm) min_cpm = cpm;
    const double d = octet_strut_diameter_mm(rho, cell);
    if (d < min_d) min_d = d;
    if (d > max_d) max_d = d;
    if (d < params.min_extrudable_width_mm) out.any_strut_below_min = true;
  }

  if (out.latticed_voxels > 0) {
    out.rho_min_used = rho_min_used;
    out.rho_max_used = rho_max_used;
    out.min_member_width_mm = min_width;  // +inf iff every latticed member exceeds cap
    out.min_cells_per_member = min_cpm;
    out.min_strut_diameter_mm = min_d;
    out.max_strut_diameter_mm = max_d;
  }
  // L4 at region scale: candidates existed but the law could grade none of them.
  out.region_ungradeable =
      out.region_voxels > 0 && out.latticed_voxels == 0;

  // ── bar L2: the certifiability invariant, asserted before returning ─────────────
  // Every voxel the posture marks latticed MUST sit inside the band and at/above the
  // floor. This is the bug the bar exists to prevent; a violation is a logic error in
  // the law, not bad input, so it throws rather than returning a poisoned posture.
  for (std::size_t e = 0; e < n; ++e) {
    if (!post.mask[e]) continue;
    const double rho = post.relative_density[e];
    if (!(rho >= rho_lo && rho <= rho_hi))
      throw std::logic_error(
          "grade_lattice: emitted density outside the certifiable band");
    if (!(width[e] / cell >= n_star))
      throw std::logic_error(
          "grade_lattice: emitted lattice below the cells-per-member floor");
  }

  return out;
}

}  // namespace topopt
