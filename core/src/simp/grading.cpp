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
  // SUB-FLOOR RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions). The
  // ceiling is READ FROM CORE when the caller leaves it at 0, the same way every other
  // limit in this law is (bar ★) — a caller that wants the measured number does not
  // have to know it.
  const double subfloor_frac_max =
      params.subfloor_stress_fraction_max > 0.0
          ? params.subfloor_stress_fraction_max
          : lattice_subfloor_retention_stress_fraction();
  if (params.retain_subfloor_in_unloaded_regions &&
      !(subfloor_frac_max > 0.0 && subfloor_frac_max <= 1.0))
    throw std::invalid_argument(
        "grade_lattice: subfloor_stress_fraction_max must be in (0, 1]");

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

  // ── THE MEASURED REGION STRESS FRACTION (sub-floor retention) ───────────────────
  // `demand_max` above is the REGION's peak — it is what the density grade normalises
  // by, and it is deliberately left alone here so the grade is untouched. What the
  // retention predicate needs is that peak as a fraction of the PART's, so a separate
  // pass takes the peak over every PRINTED voxel, region membership ignored. Where
  // there is no region the two are equal, the fraction is 1.0, and retention can never
  // arm: latticing the whole part below the floor is not "an unloaded region".
  double part_demand_max = 0.0;
  for (std::size_t e = 0; e < n; ++e) {
    if (density[e] > iso && std::isfinite(demand[e]) && demand[e] > part_demand_max)
      part_demand_max = demand[e];
  }
  out.subfloor_retention_armed = params.retain_subfloor_in_unloaded_regions;
  out.subfloor_stress_fraction_max =
      params.retain_subfloor_in_unloaded_regions ? subfloor_frac_max : 0.0;
  out.region_stress_fraction =
      part_demand_max > 0.0 ? std::min(1.0, demand_max / part_demand_max) : 0.0;
  // NO DEMAND FIELD, NO RETENTION. An all-zero demand — which is exactly what the
  // pre-flight forecast passes, because no solve has run — makes the fraction 0.0,
  // and 0.0 reads as "carries nothing" when what it actually means is "nothing was
  // measured". Retention is a measurement-backed relaxation or it is nothing, so the
  // absence of a field DISARMS it rather than satisfying it. (A region genuinely at
  // zero stress inside a part that does carry load still qualifies: there
  // part_demand_max > 0 and the ratio is a real measurement.)
  out.region_qualified_unloaded =
      params.retain_subfloor_in_unloaded_regions && part_demand_max > 0.0 &&
      out.region_stress_fraction <= subfloor_frac_max;
  // Retention is a REGION-scoped decision, taken once, before any voxel is graded.
  const bool retain_subfloor = out.region_qualified_unloaded;
  // Allocated ONLY when retention can actually fire. An empty vector is what keeps a
  // disarmed run byte-identical, and it is the flag the invariant below reads.
  if (retain_subfloor) out.subfloor_flags.assign(n, 0);
  const double kInfinity = std::numeric_limits<double>::infinity();
  double sub_min_cpm = kInfinity, sub_max_cpm = 0.0;
  double sub_min_d = kInfinity, sub_max_d = 0.0;

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
        // THE VOXELS SUB-FLOOR RETENTION IS ABOUT. Counted whether or not retention
        // is armed, so a forecast can say how much is at stake before anyone opts in.
        ++out.subfloor_candidate_voxels;
        // RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions). The region
        // was MEASURED to carry at most `subfloor_frac_max` of the part's peak demand,
        // so this voxel is kept as lattice at the part's own cell rather than falling
        // back to solid. It is the SAME cell every other latticed voxel here uses —
        // a uniform posture stays uniform, and the retained material joins one lattice
        // instead of meeting it at a cell-size discontinuity.
        //
        // Printability is NOT relaxed with it: on this path `cell >= floor_mm` by
        // construction, so the strut at any density in the band prints at or above the
        // stated minimum width, and the unconditional assertion at the end re-proves it.
        if (retain_subfloor) {
          const double rho_r = clamp_rho(e, rho_of(e));
          post.mask[e] = 1;
          post.relative_density[e] = rho_r;
          ++out.latticed_voxels;
          out.subfloor_flags[e] = 1;
          ++out.subfloor_retained_voxels;
          const double d_r = octet_strut_diameter_mm(rho_r, cell);
          if (rho_r < rho_min_used) rho_min_used = rho_r;
          if (rho_r > rho_max_used) rho_max_used = rho_r;
          if (width[e] < min_width) min_width = width[e];
          if (cpm < min_cpm) min_cpm = cpm;
          if (d_r < min_d) min_d = d_r;
          if (d_r > max_d) max_d = d_r;
          if (d_r < params.min_extrudable_width_mm) out.any_strut_below_min = true;
          if (cpm < sub_min_cpm) sub_min_cpm = cpm;
          if (cpm > sub_max_cpm) sub_max_cpm = cpm;
          if (d_r < sub_min_d) sub_min_d = d_r;
          if (d_r > sub_max_d) sub_max_d = d_r;
          continue;
        }
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
        // `solid_fallback_voxels` is incremented at each terminal fallback below
        // rather than here, because a voxel sub-floor retention keeps did not fall
        // back at all and must not be counted as though it had (bar S2: the receipt's
        // latticed/solid split has to add up).
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
        if (why == 2) {
          // An unprintable strut is a fact about the PRINTER, not about load. Sub-floor
          // retention has nothing to say about it and never rescues one.
          ++out.solid_fallback_voxels;
          ++out.fallback_strut_unprintable;
          continue;
        }
        ++out.subfloor_candidate_voxels;
        // RETENTION, SWEPT FORM. The plan rejected this voxel's base cell because no
        // level cleared the cells-per-member CEILING. Retention drops that ceiling for
        // a measured-unloaded region — and nothing else: the voxel takes the FINEST
        // dyadic level of the plan's own ladder at which ITS OWN density still prints
        // at the stated minimum width. Finest is the right end twice over: it is the
        // level with the MOST cells per member, so it minimises the inaccuracy being
        // accepted, and it is a real level of the ladder, so the retained material
        // still meets its neighbours at shared dyadic nodes.
        if (retain_subfloor) {
          const double rho_r = std::min(rho_hi, std::max(rho_lo, rho_of(e)));
          double ce_r = 0.0;
          for (int L = 0; L <= out.cell_plan.max_level; ++L) {
            const double S = out.cell_plan.cell_mm_at_level(L);
            if (octet_strut_diameter_mm(rho_r, S) >= params.min_extrudable_width_mm) {
              ce_r = S;
              break;
            }
          }
          if (ce_r > 0.0) {
            const double rho_c = clamp_rho(e, rho_of(e));
            voxel_cell[e] = ce_r;
            post.mask[e] = 1;
            post.relative_density[e] = rho_c;
            ++out.latticed_voxels;
            const double cpm_r = width[e] / ce_r;
            const double d_r = octet_strut_diameter_mm(rho_c, ce_r);
            // IS THIS VOXEL ACTUALLY BELOW THE FLOOR? Not necessarily, and the
            // difference matters. The plan rejects a base cell using the THINNEST
            // member anywhere in it, so a cell can be rejected while individual
            // voxels inside it sit on material wide enough to clear the floor at
            // the finest level. Those voxels are latticed here too — they are in
            // the qualified region and they are fully certifiable — but they are
            // NOT out of regime, so they are neither flagged nor counted as
            // retained. Only genuinely sub-floor material carries the accuracy
            // claim, and only that material is what the receipt names.
            // (The law's own invariant caught this: flagging them made the
            // retained count disagree with the posture, and it threw.)
            if (cpm_r < n_star) {
              out.subfloor_flags[e] = 1;
              ++out.subfloor_retained_voxels;
            } else {
              ++out.subfloor_recovered_in_regime_voxels;
            }
            if (rho_c < rho_min_used) rho_min_used = rho_c;
            if (rho_c > rho_max_used) rho_max_used = rho_c;
            if (width[e] < min_width) min_width = width[e];
            if (cpm_r < min_cpm) min_cpm = cpm_r;
            if (d_r < min_d) min_d = d_r;
            if (d_r > max_d) max_d = d_r;
            if (d_r < params.min_extrudable_width_mm) out.any_strut_below_min = true;
            if (cpm_r < n_star) {
              if (cpm_r < sub_min_cpm) sub_min_cpm = cpm_r;
              if (cpm_r > sub_max_cpm) sub_max_cpm = cpm_r;
              if (d_r < sub_min_d) sub_min_d = d_r;
              if (d_r > sub_max_d) sub_max_d = d_r;
            }
            if (ce_r > coarsest) coarsest = ce_r;
            continue;
          }
          // No level in the ladder prints this voxel's strut. It is unprintable, not
          // sub-floor-retainable, and it is recorded as what it actually is.
          ++out.solid_fallback_voxels;
          ++out.fallback_strut_unprintable;
          continue;
        }
        ++out.solid_fallback_voxels;
        note_member_too_thin(out, width[e], n_star, floor_mm);
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
  // The regime the RETAINED material actually landed in — the size of the claim being
  // accepted, not just the fact that one was.
  if (out.subfloor_retained_voxels > 0) {
    out.subfloor_min_cells_per_member = sub_min_cpm;
    out.subfloor_max_cells_per_member = sub_max_cpm;
    out.subfloor_min_strut_diameter_mm = sub_min_d;
    out.subfloor_max_strut_diameter_mm = sub_max_d;
  } else {
    // Nothing was retained, so there is nothing to flag. Dropping the vector keeps a
    // no-op arming byte-identical to a disarmed run in everything a consumer reads.
    out.subfloor_flags.clear();
  }
  // L4 at region scale: candidates existed but the law could grade none of them.
  out.region_ungradeable =
      out.region_voxels > 0 && out.latticed_voxels == 0;

  // ── bar L2: the certifiability invariant, asserted before returning ─────────────
  // Every voxel the posture marks latticed MUST sit inside the band and at/above the
  // floor. This is the bug the bar exists to prevent; a violation is a logic error in
  // the law, not bad input, so it throws rather than returning a poisoned posture.
  std::size_t seen_subfloor = 0;
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
    if (!(width[e] / ce >= n_star)) {
      // THE ONE ADMISSIBLE EXCEPTION, and it is a NARROWING of what may pass here, not
      // a widening: a sub-floor voxel is legal ONLY if retention was armed, ONLY if the
      // region's MEASURED stress fraction cleared the ceiling, and ONLY if this exact
      // voxel is individually flagged. An unflagged sub-floor voxel still throws — so
      // a bug that latticed a thin member outside the relaxation is caught exactly as
      // it was before.
      const bool retained = out.region_qualified_unloaded &&
                            e < out.subfloor_flags.size() &&
                            out.subfloor_flags[e] != 0;
      if (!retained)
        throw std::logic_error(
            "grade_lattice: emitted lattice below the cells-per-member floor");
      ++seen_subfloor;
    }
    if (!(octet_strut_diameter_mm(rho, ce) >= params.min_extrudable_width_mm) &&
        swept)
      throw std::logic_error(
          "grade_lattice: swept plan emitted a strut under the stated minimum "
          "extrudable width");
  }
  // THE RECEIPT MUST ACCOUNT FOR EXACTLY THE MATERIAL THE POSTURE CARRIES. The count
  // reported as retained and the sub-floor voxels actually emitted have to be the same
  // set — otherwise a run could carry out-of-regime material the receipt under-reports,
  // which is the one failure mode this whole task exists to prevent.
  if (seen_subfloor != out.subfloor_retained_voxels)
    throw std::logic_error(
        "grade_lattice: sub-floor retained voxel count disagrees with the posture");
  // Sub-floor material may exist ONLY where the relaxation was armed AND the region
  // measured under the ceiling. A retained voxel outside that is a logic error.
  if (out.subfloor_retained_voxels > 0 &&
      !(out.subfloor_retention_armed && out.region_qualified_unloaded))
    throw std::logic_error(
        "grade_lattice: sub-floor material retained without an armed, qualified "
        "region");
  // And the floor still holds EVERYWHERE ELSE: the thinnest latticed member outside
  // the retained set can never be under it. (min_cells_per_member is the thinnest
  // INCLUDING retained material — deliberately, because that is the number
  // analyze_fixed_design compares to the floor to raise lattice_strut_out_of_regime.)
  if (out.subfloor_retained_voxels == 0 && out.latticed_voxels > 0 &&
      !(out.min_cells_per_member >= n_star))
    throw std::logic_error(
        "grade_lattice: thinnest latticed member is below the floor with no "
        "retention in force");

  return out;
}

}  // namespace topopt
