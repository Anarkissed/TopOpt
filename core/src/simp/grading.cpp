#include "topopt/grading.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

#include "topopt/lattice.hpp"  // lattice_rho_min/max, lattice_cells_per_member_min,
                               // octet_strut_diameter_mm
#include "topopt/voxel.hpp"    // local_member_thickness_mm

namespace topopt {

namespace {

// BAR F1 — record ONE voxel rejected because its member cannot hold N* cells
// across. `floor_mm` is the printability floor: below n_star * floor_mm no LEGAL
// cell exists for this member at all, so the voxel is irrecoverable by any cell
// choice and any remedy naming a cell size would be a guess.
void note_member_too_thin(GradedField& out, double width_mm, double n_star,
                          double floor_mm) {
  ++out.fallback_member_too_thin;
  if (std::isfinite(width_mm)) {
    if (width_mm > out.fallback_max_member_width_mm)
      out.fallback_max_member_width_mm = width_mm;
    if (width_mm < n_star * floor_mm) ++out.fallback_irrecoverable_by_cell;
  }
}

}  // namespace

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
  const bool swept = params.cell_mode == CellSizeMode::Swept;
  if (params.cell_mode == CellSizeMode::Fixed && !(params.target_cell_size_mm > 0.0))
    throw std::invalid_argument("grade_lattice: target_cell_size_mm must be > 0");
  if (swept) {
    if (!(params.min_cell_size_mm > 0.0))
      throw std::invalid_argument(
          "grade_lattice: swept mode needs min_cell_size_mm > 0");
    if (!(params.max_cell_size_mm >= params.min_cell_size_mm))
      throw std::invalid_argument(
          "grade_lattice: swept mode needs max_cell_size_mm >= min_cell_size_mm");
  }
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
  const double floor_mm = lattice_cell_printability_floor_mm(
      topo, params.min_extrudable_width_mm);
  // AUTO takes the floor itself — the finest cell every strut still prints at, and
  // therefore the uniform cell that leaves the most of the part latticed (the
  // cells-per-member rule is an UPPER bound, so finer is always more latticed).
  // FIXED takes the caller's target, raised to that same floor. SWEPT's cell is
  // per-region and comes from the plan below; the scalar it reports is the coarsest
  // level the plan actually used.
  const double uniform_cell = params.cell_mode == CellSizeMode::Auto
                                  ? floor_mm
                                  : std::max(params.target_cell_size_mm, floor_mm);
  const double cell = uniform_cell;
  out.printability_floor_mm = floor_mm;
  out.cell_size_floored =
      params.cell_mode == CellSizeMode::Fixed && params.target_cell_size_mm < floor_mm;
  out.cell_size_mm = cell;
  out.cell_mode = params.cell_mode;

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
  out.clamp_flags.assign(n, 0);

  const double kInf = std::numeric_limits<double>::infinity();
  double rho_min_used = kInf, rho_max_used = 0.0;
  double min_width = kInf, min_cpm = kInf;
  double min_d = kInf, max_d = 0.0;
  const double gamma = params.demand_exponent;

  // The demand -> density map (requirement 1 / L2), identical in every cell mode:
  // density depends on DEMAND alone, never on cell size. That is exactly what lets
  // the cell-size plan consume it without circularity.
  auto rho_of = [&](std::size_t e) {
    const double frac =
        demand_max > 0.0 ? std::min(1.0, std::max(0.0, demand[e] / demand_max))
                         : 0.0;
    return rho_hi * std::pow(frac, gamma);
  };
  // Band-clamp accounting (H4b): count voxels the demand placed outside the
  // certifiable band before the clamp. (rho > rho_hi is unreachable with the
  // rho_hi * frac^gamma map, frac <= 1 — counted anyway so a future demand map
  // cannot clamp silently.)
  auto clamp_rho = [&](std::size_t e, double rho) {
    if (rho < rho_lo) {
      ++out.clamped_lo_voxels;
      out.clamp_flags[e] = 1;
      return rho_lo;
    }
    if (rho > rho_hi) {
      ++out.clamped_hi_voxels;
      out.clamp_flags[e] = 2;
      return rho_hi;
    }
    return rho;
  };
  // The per-voxel cell each latticed voxel ended up with. Left EMPTY on the uniform
  // paths, where the scalar `cell` is the whole truth — and an empty field is what
  // keeps the posture byte-identical to a pre-sweep run (bar R1).
  std::vector<double> voxel_cell;

  if (!swept) {
    // ── FIXED / AUTO: ONE cell for the part. Unchanged from the pre-sweep law. ────
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
        // BAR F1: the reason, per voxel. On a uniform cell there is exactly ONE
        // predicate that can reject — this one — because the cell is at or above
        // the printability floor by construction (`uniform_cell` above), so no
        // voxel can be rejected for an unprintable strut. A receipt reading
        // `unprintable: 0` on this path means "impossible here", not "none today".
        note_member_too_thin(out, width[e], n_star, floor_mm);
        continue;
      }

      const double rho = clamp_rho(e, rho_of(e));

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
    // A trivial one-level plan, so every consumer reads the same report shape in all
    // three modes and a receipt never has to branch on the mode.
    out.cell_plan.mode = params.cell_mode;
    out.cell_plan.origin = grid.origin;
    out.cell_plan.base_cell_mm = cell;
    out.cell_plan.max_level = 0;
    out.cell_plan.cells_per_member_floor = n_star;
    out.cell_plan.printability_floor_mm = floor_mm;
  } else {
    // ── SWEPT: cell size follows demand on a dyadic octree (cell_plan.hpp) ────────
    // Pass 1 — the density grade over every candidate. No cell size is involved here,
    // so this is the same map the uniform paths apply; the plan then reads it.
    std::vector<char> cand(n, 0);
    std::vector<double> rho_raw(n, 0.0);
    for (std::size_t e = 0; e < n; ++e) {
      if (!(density[e] > iso && (!region || (*region)[e] != 0))) continue;
      cand[e] = 1;
      ++out.region_voxels;
      // The plan needs the BAND-CLAMPED density, because that is the density whose
      // strut actually gets printed. Clamp COUNTS are taken in pass 2, over the
      // voxels that end up latticed, so the accounting means what it means on the
      // uniform paths.
      rho_raw[e] = std::min(rho_hi, std::max(rho_lo, rho_of(e)));
    }

    CellPlanParams pp;
    pp.topology = topo;
    pp.mode = CellSizeMode::Swept;
    pp.min_cell_size_mm = params.min_cell_size_mm;
    pp.max_cell_size_mm = params.max_cell_size_mm;
    pp.min_extrudable_width_mm = params.min_extrudable_width_mm;
    pp.thickness_cap_voxels = params.thickness_cap_voxels;
    out.cell_plan = plan_cell_sizes(grid, rho_raw, cand, width, pp);
    voxel_cell = cell_size_field(grid, out.cell_plan);

    // Pass 2 — assign. A candidate whose base cell got no admissible level STAYS
    // SOLID: the per-cell form of the L4 fallback the uniform law applies per part.
    double coarsest = 0.0;
    for (std::size_t e = 0; e < n; ++e) {
      if (!cand[e]) continue;
      const double ce = voxel_cell[e];
      if (!(ce > 0.0)) {
        ++out.solid_fallback_voxels;
        // BAR F1 — which of the plan's TWO limits bound this voxel's base cell.
        // Both can occur in swept mode and their remedies are opposite (a finer
        // cell for a thin member, a coarser one for an unprintable strut), so the
        // receipt reports them separately or reports nothing useful.
        // Voxel -> base cell, by the voxel CENTRE — the SAME convention
        // plan_cell_sizes used to build the aggregates, so the attribution reads
        // the reason of the cell that actually decided this voxel.
        const int vi = static_cast<int>(e % static_cast<std::size_t>(grid.nx));
        const int vj = static_cast<int>((e / static_cast<std::size_t>(grid.nx)) %
                                        static_cast<std::size_t>(grid.ny));
        const int vk = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) *
                                             static_cast<std::size_t>(grid.ny)));
        const double S0 = out.cell_plan.base_cell_mm;
        const int ci = std::min(out.cell_plan.nx - 1, std::max(0,
            static_cast<int>(std::floor((vi + 0.5) * grid.spacing / S0))));
        const int cj = std::min(out.cell_plan.ny - 1, std::max(0,
            static_cast<int>(std::floor((vj + 0.5) * grid.spacing / S0))));
        const int ck = std::min(out.cell_plan.nz - 1, std::max(0,
            static_cast<int>(std::floor((vk + 0.5) * grid.spacing / S0))));
        const std::size_t c = out.cell_plan.index(ci, cj, ck);
        const signed char why =
            c < out.cell_plan.reject_reason.size()
                ? out.cell_plan.reject_reason[c] : 0;
        if (why == 2) ++out.fallback_strut_unprintable;
        else note_member_too_thin(out, width[e], n_star, floor_mm);
        continue;
      }
      const double rho = clamp_rho(e, rho_of(e));
      post.mask[e] = 1;
      post.relative_density[e] = rho;
      ++out.latticed_voxels;

      const double cpm = width[e] / ce;
      if (rho < rho_min_used) rho_min_used = rho;
      if (rho > rho_max_used) rho_max_used = rho;
      if (width[e] < min_width) min_width = width[e];
      if (cpm < min_cpm) min_cpm = cpm;
      const double d = octet_strut_diameter_mm(rho, ce);
      if (d < min_d) min_d = d;
      if (d > max_d) max_d = d;
      if (d < params.min_extrudable_width_mm) out.any_strut_below_min = true;
      if (ce > coarsest) coarsest = ce;
    }
    // The scalar a legacy reader sees is the COARSEST cell the plan used — the
    // conservative one for a cells-per-member question asked at part scale. The
    // honest per-region numbers are cell_plan.levels; the per-voxel truth is the
    // field carried on the posture.
    if (coarsest > 0.0) {
      out.cell_size_mm = coarsest;
      post.cell_size_mm = coarsest;
    }
    post.cell_size_field = voxel_cell;
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
    // The floor is checked at THIS voxel's OWN cell — per cell, never per part, which
    // is the whole point of a swept posture (bar R3/R5). On the uniform paths
    // voxel_cell is empty and this is the scalar test, unchanged.
    const double ce = voxel_cell.empty() ? cell : voxel_cell[e];
    if (!(width[e] / ce >= n_star))
      throw std::logic_error(
          "grade_lattice: emitted lattice below the cells-per-member floor");
    if (!(octet_strut_diameter_mm(rho, ce) >= params.min_extrudable_width_mm) &&
        swept)
      throw std::logic_error(
          "grade_lattice: swept plan emitted a strut under the stated minimum "
          "extrudable width");
  }

  return out;
}

}  // namespace topopt
