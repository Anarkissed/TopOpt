#include "topopt/grading.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <stdexcept>

#include "topopt/lattice.hpp"  // lattice_rho_min/max, lattice_cells_per_member_min,
                               // octet_strut_diameter_mm
#include "topopt/voxel.hpp"    // local_member_thickness_mm

namespace topopt {

const char* grading_intent_name(GradingIntent i) {
  switch (i) {
    case GradingIntent::Structural: return "structural";
    case GradingIntent::Aesthetic: return "aesthetic";
  }
  // A new case must be NAMED here before anything can serialize it — never a silent
  // fallback, the same posture cell_size_mode_name takes.
  throw std::logic_error("grading_intent_name: unnamed GradingIntent");
}

bool grading_intent_from_name(const char* name, GradingIntent& out) {
  const std::string n = name ? name : "";
  if (n == "structural") { out = GradingIntent::Structural; return true; }
  if (n == "aesthetic") { out = GradingIntent::Aesthetic; return true; }
  return false;   // a job schema never silently falls back to an intent nobody asked for
}

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
  if (params.region_relative_density != nullptr &&
      params.region_relative_density->size() != n)
    throw std::invalid_argument(
        "grade_lattice: region_relative_density->size() != voxel_count");
  if (params.prescribed_relative_density != nullptr &&
      params.prescribed_relative_density->size() != n)
    throw std::invalid_argument(
        "grade_lattice: prescribed_relative_density->size() != voxel_count");
  const bool swept = params.cell_mode == CellSizeMode::Swept;
  const bool fit = params.cell_mode == CellSizeMode::Fit;
  if (params.cell_mode == CellSizeMode::Fixed && !(params.target_cell_size_mm > 0.0))
    throw std::invalid_argument("grade_lattice: target_cell_size_mm must be > 0");
  if (fit) {
    if (params.fit_cell_size_mm == nullptr)
      throw std::invalid_argument(
          "grade_lattice: fit mode needs fit_cell_size_mm — the per-voxel cell "
          "derived from the declared include regions (see grading.hpp)");
    if (params.fit_cell_size_mm->size() != n)
      throw std::invalid_argument(
          "grade_lattice: fit_cell_size_mm->size() != voxel_count");
    // REFUSED RATHER THAN IGNORED. Sub-floor retention exists to keep material the
    // ACCURACY floor rejected at the part's ONE cell; fit already fits a cell to each
    // region and already emits below that floor where the region cannot hold it, with
    // its own accounting. Running both would leave two mechanisms deciding the same
    // voxel with two different receipts, and silently dropping one would hide which.
    if (params.retain_subfloor_in_unloaded_regions)
      throw std::invalid_argument(
          "grade_lattice: cell_mode \"fit\" and retain_subfloor_in_unloaded_regions "
          "are mutually exclusive — fit already derives a cell per region and reports "
          "the out-of-regime material itself (fit_out_of_regime_voxels)");
  }
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
  // ★ ABSOLUTE UTILISATION (§0). Validated only when armed, so the peak-relative
  // path cannot start throwing on values it never reads.
  if (params.demand_allowable_mpa < 0.0 ||
      !std::isfinite(params.demand_allowable_mpa))
    throw std::invalid_argument(
        "grade_lattice: demand_allowable_mpa must be finite and >= 0 (0 = the "
        "peak-relative law)");
  if (params.demand_allowable_mpa > 0.0) {
    if (!(params.utilisation_target > 0.0 && params.utilisation_target <= 1.0))
      throw std::invalid_argument(
          "grade_lattice: utilisation_target must be in (0, 1] — it is the "
          "utilisation at which the lattice reaches rho_max");
    if (!(params.unloaded_utilisation_max >= 0.0 &&
          params.unloaded_utilisation_max <= 1.0))
      throw std::invalid_argument(
          "grade_lattice: unloaded_utilisation_max must be in [0, 1] (0 disarms)");
  }
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
  if (params.region_ids != nullptr && params.region_ids->size() != n)
    throw std::invalid_argument("grade_lattice: region_ids->size() != voxel_count");
  // THE AGGREGATE EXPOSURE CAP. 0 (the DEFAULT) means NO CAP — the caller must ask
  // for one, and `lattice_subfloor_aggregate_cap_fraction()` is what it should ask
  // for. It is opt-in rather than defaulted because the cap DID NOT PASS ITS BAR:
  // measured on a real part, a single region at 2.889 % exposure (inside the 3.0 %
  // constant) moved the certified margin 1.8x further than the 0.10 % bound
  // pre-registered alongside it. Defaulting an unsound refusal ON would change
  // already-verified behaviour on the strength of a number now known to be wrong.
  // See evidence/2026-08-04-subfloor-lattice-unloaded-regions/r3_verdict.md.
  const double subfloor_cap = params.subfloor_aggregate_cap_fraction;
  if (params.retain_subfloor_in_unloaded_regions && subfloor_cap != 0.0 &&
      !(subfloor_cap > 0.0 && subfloor_cap <= 1.0))
    throw std::invalid_argument(
        "grade_lattice: subfloor_aggregate_cap_fraction must be 0 (no cap) or in "
        "(0, 1]");

  // ★ §0 / §3 — resolved once, up here, because the sub-floor qualification (§2)
  // below reads `allowable` and it runs before the density map.
  const double allowable = params.demand_allowable_mpa;
  const double u_target = params.utilisation_target;
  // ── ★ AESTHETIC (amendment §1/§2/§3), resolved once ──────────────────────────
  const bool aesthetic = params.intent == GradingIntent::Aesthetic;
  const double aes_q = params.aesthetic_percentile > 0.0
                           ? params.aesthetic_percentile
                           : kAestheticPercentile;
  if (aesthetic && !(aes_q > 0.0 && aes_q <= 1.0))
    throw std::invalid_argument(
        "grade_lattice: aesthetic_percentile must be in (0, 1]");
  if ((params.aesthetic_rho_min > 0.0) != (params.aesthetic_rho_max > 0.0))
    throw std::invalid_argument(
        "grade_lattice: aesthetic_rho_min and aesthetic_rho_max must be given "
        "together (both 0 = the certifiable band)");
  if (params.aesthetic_rho_min > 0.0 &&
      !(params.aesthetic_rho_max > params.aesthetic_rho_min))
    throw std::invalid_argument(
        "grade_lattice: aesthetic_rho_max must exceed aesthetic_rho_min");

  const LatticeTopology topo = params.topology;

  GradedField out;
  // ── the limits, READ from core (never hardcoded here) ──────────────────────────
  const double rho_lo = lattice_rho_min(topo);
  const double rho_hi = lattice_rho_max(topo);
  const double n_star = lattice_cells_per_member_min(topo);
  out.band_rho_min = rho_lo;
  out.band_rho_max = rho_hi;
  out.cells_per_member_floor = n_star;
  // ── ★ THE ADAPTIVE FLOOR (aesthetic only) ────────────────────────────────────
  // Disarms itself without an allowable: utilisation is what it is a function of.
  const bool adaptive_cpm = aesthetic &&
                            params.aesthetic_adaptive_cells_per_member &&
                            params.demand_allowable_mpa > 0.0;
  const double err_budget = params.aesthetic_error_budget > 0.0
                                ? params.aesthetic_error_budget
                                : kAestheticHomogenisationErrorBudget;
  out.aesthetic_adaptive_cells_armed = adaptive_cpm;
  out.aesthetic_error_budget_used = adaptive_cpm ? err_budget : 0.0;
  out.aesthetic_min_cells_per_member_allowed = adaptive_cpm ? n_star : 0.0;
  // The floor THIS voxel must clear. Constant everywhere unless the adaptive rule is
  // armed, so every other path is bit-identical.
  // The loosest floor the adaptive rule permits over the candidate set — what the
  // per-CELL planner is allowed to consider. Computed in a fixed voxel order.
  double adaptive_plan_floor = n_star;
  if (adaptive_cpm) {
    for (std::size_t e = 0; e < n; ++e) {
      if (!(density[e] > iso && (!region || (*region)[e] != 0))) continue;
      const double f = aesthetic_cells_per_member_floor(
          topo, demand[e] / params.demand_allowable_mpa, err_budget);
      if (f < adaptive_plan_floor) adaptive_plan_floor = f;
    }
  }
  auto n_req = [&](std::size_t e) -> double {
    if (!adaptive_cpm) return n_star;
    const double u = demand[e] / params.demand_allowable_mpa;
    const double f = aesthetic_cells_per_member_floor(topo, u, err_budget);
    if (f < out.aesthetic_min_cells_per_member_allowed)
      out.aesthetic_min_cells_per_member_allowed = f;
    return f;
  };

  // ── the printability floor (requirement 3) ──────────────────────────────────────
  // The thinnest strut at any cell occurs at rho_lo (diameter is monotone in rho), so
  // the floor is the cell that prints the rho_lo strut at exactly the stated minimum
  // width. Diameter is linear in cell, so phi_lo = diameter at a unit cell and the
  // floor is min_width / phi_lo.
  const double floor_mm = lattice_cell_printability_floor_mm(
      topo, params.min_extrudable_width_mm);
  // ★ S2 — THE FLOOR IS A BOUND AGAIN, NOT AN ANSWER (task
  // 2026-08-05-lattice-cell-fit-mode). `floor_mm` above is
  // `min_extrudable_width / phi(rho_min)`: the smallest cell at which the band's
  // LIGHTEST strut still prints. Raising a user's target to it guards against a
  // density NOBODY SELECTED — at a 0.42 mm bead it raises a hand-set 1.2 mm cell to
  // 4.6026 mm, which then needs 23.0131 mm of member and rejects the very region the
  // user was trying to reach. Measured, on the maintainer's own geometry: cell_mm 1.2
  // graded ⇒ "planned cell 4.602619932 mm gives 0.8690702381 cells across".
  //
  // The cell that is genuinely illegal is the one at which NO density in the band
  // prints — `min_extrudable_width / phi(rho_max)`, 1.0950 mm at the same bead. That
  // is the bound Fixed now applies, and the density is raised WITH the cell below
  // (`print_rho_floor`) so the pair is legal jointly rather than the cell alone being
  // legal at an assumed density.
  //
  // WHY THIS CANNOT MOVE A RUN WHOSE CELL WAS NEVER OVERRIDDEN: for any target at or
  // above `floor_mm` the max() picks the target either way, AND the density raise is
  // inert, because a cell at or above `floor_mm` already prints at rho_min and the
  // grade is clamped to rho_min from below. So every such run is byte-identical, by
  // construction and measured (bar R1).
  const double abs_floor_mm =
      params.min_extrudable_width_mm /
      octet_strut_diameter_mm(rho_hi, 1.0);  // = w / phi(rho_max)
  // AUTO takes `floor_mm` itself — UNCHANGED, deliberately (bar S4): past runs stay
  // reproducible and the default path stays byte-identical. FIXED takes the caller's
  // target, raised only to the floor that actually binds. SWEPT's cell is per-region
  // and comes from the plan below; FIT's likewise.
  const double uniform_cell =
      params.cell_mode == CellSizeMode::Auto
          ? floor_mm
          : std::max(params.target_cell_size_mm, abs_floor_mm);
  const double cell = uniform_cell;
  out.printability_floor_mm = floor_mm;
  out.min_printable_cell_mm = abs_floor_mm;
  out.cell_size_floored = params.cell_mode == CellSizeMode::Fixed &&
                          params.target_cell_size_mm < abs_floor_mm;
  // The lightest band density whose strut prints at cell `S`. At or above `floor_mm`
  // this is at or below rho_min and the raise below is a no-op; under it, it is what
  // makes the smaller cell legal instead of forbidden.
  // A NEGATIVE return means "no density in the band prints at this cell". At exactly
  // `abs_floor_mm` that can happen by one ULP (the frontier cell is defined by the
  // reciprocal of the same phi), so it resolves to the band ceiling — the true answer
  // in the limit — rather than to 0, which would silently emit an under-width strut.
  // The same resolution lattice_derive_cell_for_member applies, for the same reason.
  auto print_rho_floor = [&](double S) {
    const double r = lattice_min_density_for_strut(topo, S,
                                                   params.min_extrudable_width_mm);
    return r >= 0.0 ? r : rho_hi;
  };
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
  std::size_t part_printed = 0;   // the aggregate cap's denominator
  for (std::size_t e = 0; e < n; ++e) {
    if (!(density[e] > iso)) continue;
    ++part_printed;
    if (std::isfinite(demand[e]) && demand[e] > part_demand_max)
      part_demand_max = demand[e];
  }
  out.subfloor_retention_armed = params.retain_subfloor_in_unloaded_regions;
  out.subfloor_stress_fraction_max =
      params.retain_subfloor_in_unloaded_regions ? subfloor_frac_max : 0.0;
  out.subfloor_aggregate_cap_fraction =
      params.retain_subfloor_in_unloaded_regions ? subfloor_cap : 0.0;
  out.part_printed_voxels = part_printed;
  out.region_stress_fraction =
      part_demand_max > 0.0 ? std::min(1.0, demand_max / part_demand_max) : 0.0;

  // ── PER-REGION QUALIFICATION ────────────────────────────────────────────────────
  // The predicate is evaluated once per DECLARED region rather than once for their
  // union. `region_of` is the voxel's group: its id when the caller supplied one,
  // else 0 — and with no ids at all every candidate lands in group 0, which IS the
  // union reading, so the null default is the shipped law exactly.
  //
  // Each group's peak is taken over its OWN candidates; the denominator stays the
  // PART's peak, because "quiet" only means anything relative to the whole part.
  auto region_of = [&](std::size_t e) -> int {
    return params.region_ids ? (*params.region_ids)[e] : 0;
  };
  std::vector<int> region_order;             // first-seen order => deterministic
  std::map<int, std::size_t> region_slot;
  if (params.retain_subfloor_in_unloaded_regions) {
    for (std::size_t e = 0; e < n; ++e) {
      if (!(density[e] > iso && (!region || (*region)[e] != 0))) continue;
      const int id = region_of(e);
      auto it = region_slot.find(id);
      if (it == region_slot.end()) {
        region_slot.emplace(id, out.subfloor_regions.size());
        region_order.push_back(id);
        GradedField::SubfloorRegion r;
        r.region_id = id;
        out.subfloor_regions.push_back(r);
        it = region_slot.find(id);
      }
      GradedField::SubfloorRegion& r = out.subfloor_regions[it->second];
      ++r.candidate_voxels;
      if (std::isfinite(demand[e]) && demand[e] > r.stress_fraction)
        r.stress_fraction = demand[e];   // holds the raw PEAK until normalised below
    }
    for (GradedField::SubfloorRegion& r : out.subfloor_regions) {
      const double region_peak = r.stress_fraction;   // still the raw peak, in MPa
      r.stress_fraction =
          part_demand_max > 0.0 ? std::min(1.0, r.stress_fraction / part_demand_max)
                                : 0.0;
      // NO DEMAND FIELD, NO RETENTION — the same guard the union path applies, per
      // region: an all-zero demand makes every fraction 0.0, which READS as "carries
      // nothing" and MEANS "nothing was measured".
      r.qualified = part_demand_max > 0.0 && r.stress_fraction <= subfloor_frac_max;

      // ── ★ §1(c) CHECKED DELIBERATELY, AND §2 ADDED HERE ────────────────────────
      // ★ WHAT §0 DID **NOT** CHANGE. This predicate is a ratio of TWO PEAKS OF THE
      // SAME FIELD (region peak / part peak). It never read the density
      // normalisation, so moving that normalisation from `demand_max` to the
      // allowable leaves it BIT-IDENTICAL. That is the answer to bar R5, and it is
      // checked here rather than assumed: `demand_max` is still computed, still the
      // candidate-set peak, and still what `region_stress_fraction` divides by.
      //
      // ★ WHAT IS WRONG WITH IT ANYWAY, and why §2 needs a second test. Being a
      // ratio, it is SCALE-FREE: a region at 5 % of the part's peak is at 5 %
      // whether the part carries 22 N or 48 kN. It therefore inherits exactly the
      // defect §0 removed from the density grade — it cannot tell "quiet" from
      // "the whole part is quiet". On the maintainer's part EVERY region is
      // unloaded in absolute terms (peak utilisation 0.000463), and this predicate
      // cannot say so, because relative to the part's own peak something is always
      // at 100 %.
      //
      // ★ SO §2 IS AN ABSOLUTE TEST, ADDED, NOT A REPLACEMENT. When an allowable is
      // supplied and a threshold is armed, a region ALSO qualifies as unloaded when
      // its own peak sits below `unloaded_utilisation_max` of the allowable — a
      // statement about the MATERIAL, which is what "this wall need only hold itself
      // up" actually means. The relative test is kept because it is the shipped
      // behaviour and it is the conservative one; qualifying under EITHER is a
      // widening, and every retained voxel is still counted, flagged and reported
      // out of regime exactly as before.
      r.utilisation = allowable > 0.0 ? region_peak / allowable : 0.0;
      r.qualified_unloaded_absolute =
          allowable > 0.0 && params.unloaded_utilisation_max > 0.0 &&
          r.utilisation <= params.unloaded_utilisation_max;
      if (r.qualified_unloaded_absolute) r.qualified = true;
    }
  }
  auto region_qualified = [&](std::size_t e) -> bool {
    if (!params.retain_subfloor_in_unloaded_regions) return false;
    const auto it = region_slot.find(region_of(e));
    return it != region_slot.end() && out.subfloor_regions[it->second].qualified;
  };
  auto region_record = [&](std::size_t e) -> GradedField::SubfloorRegion* {
    const auto it = region_slot.find(region_of(e));
    return it == region_slot.end() ? nullptr : &out.subfloor_regions[it->second];
  };
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
  // ── ★ THE AESTHETIC RANGE AND THE PERCENTILE (amendment §1b, §2) ────────────
  // The range defaults to the certifiable band, so the mechanism works unconfigured.
  // ★ IT IS STILL CLAMPED INTO THE CERTIFIABLE BAND: an aesthetic run may choose
  // WHERE within the band to grade, never to leave it — the band is what makes every
  // emitted density certifiable by construction (bar L2), and §2(e) keeps the
  // certificate running over whatever is emitted.
  const double aes_lo = aesthetic ? std::max(rho_lo, params.aesthetic_rho_min > 0.0
                                                         ? params.aesthetic_rho_min
                                                         : rho_lo)
                                  : rho_lo;
  const double aes_hi = aesthetic ? std::min(rho_hi, params.aesthetic_rho_max > 0.0
                                                         ? params.aesthetic_rho_max
                                                         : rho_hi)
                                  : rho_hi;
  if (aesthetic && !(aes_hi > aes_lo))
    throw std::invalid_argument(
        "grade_lattice: the aesthetic range does not intersect the certifiable band");

  // ★ DETERMINISTIC PERCENTILE (bar R16 / PR 344 §1b): a FULL SORT of the candidate
  // demands in voxel order, never a sampled estimate. The same discipline the density
  // histogram already keeps.
  double aes_ref = 0.0;
  if (aesthetic) {
    std::vector<double> d;
    d.reserve(out.region_voxels ? out.region_voxels : 1024);
    for (std::size_t e = 0; e < n; ++e) {
      const bool candidate = density[e] > iso && (!region || (*region)[e] != 0);
      if (candidate && std::isfinite(demand[e])) d.push_back(demand[e]);
    }
    if (!d.empty()) {
      std::sort(d.begin(), d.end());
      std::size_t k = static_cast<std::size_t>(aes_q * (d.size() - 1));
      if (k >= d.size()) k = d.size() - 1;
      aes_ref = d[k];
      for (double v : d)
        if (v > aes_ref) ++out.above_percentile_voxels;
    }
  }
  out.intent_used = params.intent;
  out.aesthetic_percentile_used = aesthetic ? aes_q : 0.0;
  out.aesthetic_percentile_mpa = aes_ref;
  out.aesthetic_rho_min_used = aesthetic ? aes_lo : 0.0;
  out.aesthetic_rho_max_used = aesthetic ? aes_hi : 0.0;
  // §3 — the band POSITION. `utilisation_target` doubles as the carrier of the
  // maintainer's existing checkbox: 1.0 is minimize_plastic ON, below 1.0 is OFF.
  const double aes_w = aesthetic ? (u_target >= 1.0 ? kAestheticOpenExponent
                                                    : kAestheticTightExponent)
                                 : 0.0;
  out.aesthetic_weight_exponent_used = aes_w;

  out.demand_allowable_mpa_used = allowable;
  out.utilisation_target_used = allowable > 0.0 ? u_target : 0.0;
  if (allowable > 0.0) {
    out.max_utilisation = demand_max / allowable;
    // §0(b): count every CANDIDATE the field puts over the allowable, before any
    // clamp — an over-allowable region must never read as "dense and fine".
    for (std::size_t e = 0; e < n; ++e) {
      const bool candidate = density[e] > iso && (!region || (*region)[e] != 0);
      if (candidate && std::isfinite(demand[e]) && demand[e] > allowable)
        ++out.over_allowable_voxels;
    }
  }

  // The demand -> density map (requirement 1 / L2), identical in every cell mode:
  // density depends on DEMAND alone, never on cell size. That is exactly what lets
  // the cell-size plan consume it without circularity.
  auto rho_of = [&](std::size_t e) {
    // MULTISCALE (task multiscale-lattice-to): the optimizer already chose this
    // voxel's relative density and paid a compliance objective evaluated at the
    // measured tensor of it. Use THAT, not a second derivation from stress —
    // otherwise the printed material distribution is not the one that was
    // optimized and certified. Everything after this point (clamp, floor, plan,
    // L2 assertion) is unchanged.
    if (params.prescribed_relative_density != nullptr)
      return (*params.prescribed_relative_density)[e];
    // ★ A PER-REGION STATED DENSITY (task 2026-08-16-per-sector-density-override).
    // Checked AFTER `prescribed` so multiscale is untouched, and gated on > 0 so a
    // voxel no override covers derives exactly as before.
    if (params.region_relative_density != nullptr &&
        (*params.region_relative_density)[e] > 0.0)
      return (*params.region_relative_density)[e];
    // ★ THE LAW (task 2026-08-20-lattice-only-grading, §0). Two normalisations,
    // one arithmetic. The DENOMINATOR is the whole difference:
    //   * ABSOLUTE  — the material allowable. `frac` is UTILISATION, a real
    //     statement about the material, comparable between parts and between runs,
    //     and it RESPONDS TO LOAD MAGNITUDE.
    //   * PEAK      — the candidate set's own peak. `frac` is a ratio to whatever
    //     the loudest voxel happens to be, so scaling the load changes NOTHING
    //     (measured: 2161.5x, byte-identical) and a stress concentration compresses
    //     the whole part toward the floor.
    // `utilisation_target` (§3) is the utilisation at which the lattice reaches
    // rho_max: 1.0 works the material to its whole allowable, below 1.0 keeps a
    // stated margin and therefore spends more plastic.
    // ★ AESTHETIC (amendment §1): relative, but against a HIGH PERCENTILE rather
    // than the max, and graded onto the GIVEN RANGE. The stress decides WHERE in
    // the range, not how much of it.
    if (aesthetic) {
      // ONE definition, shared with the app bridge (grading.hpp).
      const double f = grading_demand_fraction(GradingIntent::Aesthetic, demand[e],
                                               aes_ref, 1.0);
      return aes_lo + (aes_hi - aes_lo) * std::pow(f, gamma * aes_w);
    }
    double frac;
    if (allowable > 0.0) {
      // ONE definition, shared with the app bridge (grading.hpp). §0(b)'s clamp at
      // 1.0 lives inside it, and the over-allowable count is taken separately above.
      frac = grading_demand_fraction(GradingIntent::Structural, demand[e],
                                     allowable, u_target);
    } else {
      frac = demand_max > 0.0
                 ? std::min(1.0, std::max(0.0, demand[e] / demand_max))
                 : 0.0;
    }
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

  // NO DEMAND FIELD, NO RETENTION. An all-zero demand — which is exactly what the
  // pre-flight forecast passes, because no solve has run — makes the fraction 0.0,
  // and 0.0 reads as "carries nothing" when what it actually means is "nothing was
  // measured". Retention is a measurement-backed relaxation or it is nothing, so the
  // absence of a field DISARMS it rather than satisfying it. (A region genuinely at
  // zero stress inside a part that does carry load still qualifies: there
  // part_demand_max > 0 and the ratio is a real measurement.)
  // The UNION summary, kept because every existing consumer reads it: true when the
  // candidate set as a whole would have qualified. With per-region ids armed it is no
  // longer the thing that decides retention — `subfloor_regions[].qualified` is —
  // so it is reported as "any region qualified" to stay honest about what happened.
  out.region_qualified_unloaded =
      params.retain_subfloor_in_unloaded_regions && part_demand_max > 0.0 &&
      (params.region_ids
           ? std::any_of(out.subfloor_regions.begin(), out.subfloor_regions.end(),
                         [](const GradedField::SubfloorRegion& r) { return r.qualified; })
           : out.region_stress_fraction <= subfloor_frac_max);
  // Retention is a REGION-scoped decision, taken per region before any voxel is
  // graded. `retain_subfloor` is now "SOME region qualified"; whether a given voxel
  // is retained is `region_qualified(e)`.
  const bool retain_subfloor = out.region_qualified_unloaded;

  // SWEPT retention's cell choice, in ONE place. The dry-run that applies the
  // aggregate cap and the assignment that acts on it must agree exactly about which
  // voxels would be retained; two copies of this search would put the cap one edit
  // away from bounding a different set than the one actually emitted.
  auto finest_printable_cell = [&](std::size_t e) -> double {
    const double rho_r = std::min(rho_hi, std::max(rho_lo, rho_of(e)));
    for (int L = 0; L <= out.cell_plan.max_level; ++L) {
      const double S = out.cell_plan.cell_mm_at_level(L);
      if (octet_strut_diameter_mm(rho_r, S) >= params.min_extrudable_width_mm)
        return S;
    }
    return 0.0;
  };
  // ── THE AGGREGATE EXPOSURE CAP (lattice.hpp ★★★), applied as a DRY RUN before a
  // single voxel is committed. Counts what retention WOULD keep across every
  // qualifying region and, if that exceeds the cap, disarms retention WHOLESALE.
  //
  // Wholesale, not "as much as fits": trimming to the cap would mean choosing which
  // regions to sacrifice, and nothing measures that choice. Refusing everything is
  // the only outcome that needs no unmeasured judgement — and it leaves the user a
  // clear action (narrow the regions) instead of a silently truncated result.
  auto apply_aggregate_cap = [&](bool swept_mode) {
    if (!retain_subfloor) return;
    std::size_t would = 0;
    for (std::size_t e = 0; e < n; ++e) {
      if (!(density[e] > iso && (!region || (*region)[e] != 0))) continue;
      if (!region_qualified(e)) continue;
      if (swept_mode) {
        if (voxel_cell[e] > 0.0) continue;          // the plan already latticed it
        const double ce_r = finest_printable_cell(e);
        if (!(ce_r > 0.0)) continue;                // unprintable: never retained
        if (width[e] / ce_r < n_star) ++would;      // genuinely sub-floor
      } else {
        if (width[e] / cell < n_star) ++would;
      }
    }
    out.subfloor_would_retain_voxels = would;
    if (subfloor_cap <= 0.0) return;      // no cap asked for => nothing to enforce
    const double allowed = subfloor_cap * static_cast<double>(part_printed);
    out.subfloor_over_budget = static_cast<double>(would) > allowed;
  };
  // Allocated ONLY when retention can actually fire. An empty vector is what keeps a
  // disarmed run byte-identical, and it is the flag the invariant below reads.
  if (retain_subfloor) out.subfloor_flags.assign(n, 0);
  const double kInfinity = std::numeric_limits<double>::infinity();
  double sub_min_cpm = kInfinity, sub_max_cpm = 0.0;
  double sub_min_d = kInfinity, sub_max_d = 0.0;

  // The density floor the UNIFORM cell imposes, hoisted: one cell for the part means
  // one floor. At or above `floor_mm` it is at or below rho_lo and every use of it is
  // a no-op (S2).
  const double uniform_rho_floor = swept || fit ? 0.0 : print_rho_floor(cell);

  if (!swept && !fit) {
    apply_aggregate_cap(/*swept_mode=*/false);
    // ── FIXED / AUTO: ONE cell for the part. Unchanged from the pre-sweep law. ────
    for (std::size_t e = 0; e < n; ++e) {
      const bool candidate =
          density[e] > iso && (!region || (*region)[e] != 0);
      if (!candidate) continue;
      ++out.region_voxels;

      // Cells-per-member ceiling (requirement 2): a +inf width (thicker than the EDT
      // cap) yields +inf cells-across and always clears the floor.
      const double cpm = width[e] / cell;
      if (cpm < n_req(e)) {
        // THE VOXELS SUB-FLOOR RETENTION IS ABOUT. Counted whether or not retention
        // is armed, so a forecast can say how much is at stake before anyone opts in.
        ++out.subfloor_candidate_voxels;
        if (GradedField::SubfloorRegion* rr = region_record(e)) ++rr->below_floor_voxels;
        // RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions). The region
        // was MEASURED to carry at most `subfloor_frac_max` of the part's peak demand,
        // so this voxel is kept as lattice at the part's own cell rather than falling
        // back to solid. It is the SAME cell every other latticed voxel here uses —
        // a uniform posture stays uniform, and the retained material joins one lattice
        // instead of meeting it at a cell-size discontinuity.
        //
        // Printability is NOT relaxed with it: the density is raised to whatever this
        // cell needs (`uniform_rho_floor`, S2) before the band clamp, so the strut
        // prints at or above the stated minimum width, and the unconditional assertion
        // at the end re-proves it. Before S2 the cell was at or above `floor_mm` by
        // construction and the raise was inert; it still is on every path that does
        // not hand-set a finer cell.
        if (retain_subfloor && region_qualified(e) && !out.subfloor_over_budget) {
          const double rho_clamped_r = clamp_rho(e, rho_of(e));
          const double rho_r = std::max(rho_clamped_r, uniform_rho_floor);
          if (rho_r > rho_clamped_r) ++out.density_raised_for_print_voxels;
          post.mask[e] = 1;
          post.relative_density[e] = rho_r;
          ++out.latticed_voxels;
          out.subfloor_flags[e] = 1;
          ++out.subfloor_retained_voxels;
          if (GradedField::SubfloorRegion* rr = region_record(e)) ++rr->retained_voxels;
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

      // S2 — the density is raised WITH the cell, so a Fixed target under the
      // rho_min floor is legal instead of being overridden upward.
      //
      // ★ THE RAISE HAPPENS AFTER THE BAND CLAMP, NOT BEFORE IT, and the ordering is
      // load-bearing. Raising first swallows the clamp: a voxel whose demand density
      // is under rho_lo would arrive at the clamp already AT rho_lo, so
      // `clamped_lo_voxels` would read 0 and the CLAMP COUNTERFACTUAL — a whole extra
      // certification solve — would stop running. Bar R1 case C caught exactly that:
      // identical mesh, identical design, identical run_info, and a lattice receipt
      // that differed in `clamped_lo_voxels` 40 -> 0 and `clamp_counterfactual_ran`
      // true -> false. Clamping first keeps every counter and every solve identical,
      // and the raise then does nothing at all wherever the cell already prints at
      // rho_lo — which is every cell at or above `floor_mm`.
      const double rho_clamped_u = clamp_rho(e, rho_of(e));
      const double rho = std::max(rho_clamped_u, uniform_rho_floor);
      if (rho > rho_clamped_u) ++out.density_raised_for_print_voxels;

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
  } else if (fit) {
    // ── FIT: the cell is DERIVED PER DECLARED REGION and handed in ───────────────
    // (task 2026-08-05-lattice-cell-fit-mode, S1.) The caller resolved each include
    // region's requirement into a per-voxel desired cell; this law lands those cells
    // on ONE aligned dyadic ladder (so two regions with different cells meet at
    // shared nodes and the existing multilevel emitter can carry them), grades the
    // density jointly with the cell, and reports what came out.
    //
    // WHAT IT ENFORCES AND WHAT IT DELIBERATELY DOES NOT. It never emits a strut
    // under the stated width (the density is raised with the cell) and it never
    // emits below the PERCOLATION floor (below that there is no connected network to
    // print — the voxel stays solid). It DOES emit below the ACCURACY floor where
    // the region cannot hold it, counted in `fit_out_of_regime_voxels` and reported
    // out of regime. That is the case the pre-flight names (C): buildable and
    // uncertifiable, which is a different verdict from un-latticeable.
    const double perc_floor = lattice_percolation_cells_per_member_min(topo);
    std::vector<char> cand(n, 0);
    std::vector<double> rho_raw(n, 0.0);
    const std::vector<double>& want = *params.fit_cell_size_mm;
    double s_min = kInf, s_max = 0.0;
    for (std::size_t e = 0; e < n; ++e) {
      if (!(density[e] > iso && (!region || (*region)[e] != 0))) continue;
      ++out.region_voxels;
      if (!(want[e] > 0.0)) {
        // No declared region covers this voxel, so nothing states what its cell has
        // to fit into. It stays SOLID rather than being handed a guessed cell —
        // guessing is the defect this mode exists to remove.
        ++out.solid_fallback_voxels;
        ++out.fit_no_derivation_voxels;
        continue;
      }
      cand[e] = 1;
      rho_raw[e] = std::min(rho_hi, std::max(rho_lo, rho_of(e)));
      if (want[e] < s_min) s_min = want[e];
      if (want[e] > s_max) s_max = want[e];
    }

    if (s_max > 0.0) {
      CellPlanParams pp;
    // ★ The planner chooses the CELL; relaxing only grade_lattice's post-hoc check
    // would change nothing (measured: +0 voxels). It receives the LOOSEST floor the
    // adaptive rule permits anywhere; each voxel is still held to its OWN requirement
    // by `n_req` below, so this widens what may be CONSIDERED, never what is emitted.
    if (adaptive_cpm) pp.cells_per_member_floor_override = adaptive_plan_floor;
      pp.topology = topo;
      pp.mode = CellSizeMode::Fit;
      // The ladder's base is the FINEST cell any region asked for — never finer, so
      // every emitted cell still has a printable density in the band.
      pp.min_cell_size_mm = s_min;
      pp.max_cell_size_mm = s_max;
      pp.min_extrudable_width_mm = params.min_extrudable_width_mm;
      pp.thickness_cap_voxels = params.thickness_cap_voxels;
      out.cell_plan =
          plan_cell_sizes_fit(grid, rho_raw, cand, width, want, pp);
      voxel_cell = cell_size_field(grid, out.cell_plan);
    } else {
      out.cell_plan.mode = CellSizeMode::Fit;
      out.cell_plan.origin = grid.origin;
      out.cell_plan.cells_per_member_floor = n_star;
      out.cell_plan.printability_floor_mm = floor_mm;
      voxel_cell.assign(n, 0.0);
    }

    double coarsest = 0.0;
    for (std::size_t e = 0; e < n; ++e) {
      if (!cand[e]) continue;
      const double ce = voxel_cell[e];
      if (!(ce > 0.0)) {
        // The octree left this base cell unlatticed (it is not wholly inside the
        // candidate set at any level). Same terminal fallback the swept path takes.
        // ★ The "irrecoverable by any cell" test inside note_member_too_thin is given
        // `abs_floor_mm`, not `floor_mm`: on this path the finest legal cell IS the
        // band-top one, so measuring irrecoverability against the rho_min floor would
        // call a member irrecoverable that fit can in fact reach.
        ++out.solid_fallback_voxels;
        note_member_too_thin(out, width[e], n_star, abs_floor_mm);
        continue;
      }
      // ★ THE PERCOLATION FLOOR, measured against the DESIGN's own member width
      // rather than the region's declared extent. The declaration is what the cell
      // was derived from; this is what the printed material actually is. Below the
      // percolation floor the generator emits debris, so the voxel stays SOLID.
      const double cpm = width[e] / ce;
      if (cpm < perc_floor) {
        ++out.solid_fallback_voxels;
        note_member_too_thin(out, width[e], n_star, abs_floor_mm);
        continue;
      }
      // Clamp FIRST, raise second — see the ordering note on the uniform path: the
      // band-clamp counters are part of the receipt and a raise that pre-empts them
      // silently deletes both the count and the counterfactual solve it triggers.
      const double rho_clamped = clamp_rho(e, rho_of(e));
      const double rho = std::max(rho_clamped, print_rho_floor(ce));
      if (rho > rho_clamped) ++out.density_raised_for_print_voxels;
      post.mask[e] = 1;
      post.relative_density[e] = rho;
      ++out.latticed_voxels;
      if (cpm < n_star) ++out.fit_out_of_regime_voxels;

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
    if (coarsest > 0.0) {
      out.cell_size_mm = coarsest;
      post.cell_size_mm = coarsest;
    }
    post.cell_size_field = voxel_cell;
    {
      std::size_t distinct = 0;
      for (const CellLevelReport& r : out.cell_plan.levels)
        if (r.cells > 0) ++distinct;
      out.fit_distinct_cells = distinct;
    }
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
    // ★ The planner chooses the CELL; relaxing only grade_lattice's post-hoc check
    // would change nothing (measured: +0 voxels). It receives the LOOSEST floor the
    // adaptive rule permits anywhere; each voxel is still held to its OWN requirement
    // by `n_req` below, so this widens what may be CONSIDERED, never what is emitted.
    if (adaptive_cpm) pp.cells_per_member_floor_override = adaptive_plan_floor;
    pp.topology = topo;
    pp.mode = CellSizeMode::Swept;
    pp.min_cell_size_mm = params.min_cell_size_mm;
    pp.max_cell_size_mm = params.max_cell_size_mm;
    pp.min_extrudable_width_mm = params.min_extrudable_width_mm;
    pp.thickness_cap_voxels = params.thickness_cap_voxels;
    out.cell_plan = plan_cell_sizes(grid, rho_raw, cand, width, pp);
    voxel_cell = cell_size_field(grid, out.cell_plan);
    apply_aggregate_cap(/*swept_mode=*/true);

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
        if (GradedField::SubfloorRegion* rr = region_record(e)) ++rr->below_floor_voxels;
        // RETENTION, SWEPT FORM. The plan rejected this voxel's base cell because no
        // level cleared the cells-per-member CEILING. Retention drops that ceiling for
        // a measured-unloaded region — and nothing else: the voxel takes the FINEST
        // dyadic level of the plan's own ladder at which ITS OWN density still prints
        // at the stated minimum width. Finest is the right end twice over: it is the
        // level with the MOST cells per member, so it minimises the inaccuracy being
        // accepted, and it is a real level of the ladder, so the retained material
        // still meets its neighbours at shared dyadic nodes.
        if (retain_subfloor && region_qualified(e) && !out.subfloor_over_budget) {
          const double ce_r = finest_printable_cell(e);
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
              if (GradedField::SubfloorRegion* rr = region_record(e))
                ++rr->retained_voxels;
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
  out.subfloor_retained_fraction_of_part =
      part_printed > 0 ? static_cast<double>(out.subfloor_retained_voxels) /
                             static_cast<double>(part_printed)
                       : 0.0;
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
    // ★ THE FLOOR THIS VOXEL HAD TO CLEAR. Constant unless the adaptive rule is
    // armed; the assertion is NOT weakened — a voxel below its OWN required floor
    // still throws, and the admissible set is stated exactly rather than widened.
    const double need = n_req(e);
    // ★ NAME THE RELAXATION. A voxel the adaptive rule let through below the ACCURACY
    // floor is buildable and NOT describable by the homogenised tensor. Counted here
    // so a certificate over it is reported out of regime rather than quietly trusted.
    if (adaptive_cpm && width[e] / ce < n_star)
      ++out.aesthetic_below_accuracy_floor_voxels;
    if (!(width[e] / ce >= need)) {
      // THE ONE ADMISSIBLE EXCEPTION, and it is a NARROWING of what may pass here, not
      // a widening: a sub-floor voxel is legal ONLY if retention was armed, ONLY if the
      // region's MEASURED stress fraction cleared the ceiling, and ONLY if this exact
      // voxel is individually flagged. An unflagged sub-floor voxel still throws — so
      // a bug that latticed a thin member outside the relaxation is caught exactly as
      // it was before.
      const bool retained = out.region_qualified_unloaded &&
                            e < out.subfloor_flags.size() &&
                            out.subfloor_flags[e] != 0;
      // ★ THE SECOND ADMISSIBLE EXCEPTION, and it is likewise a narrowing. FIT emits
      // below the ACCURACY floor on purpose where the declared region cannot hold it
      // — that material is buildable and uncertifiable, and it is counted. What it
      // may NEVER do is emit below the PERCOLATION floor: there is no connected
      // network there, so anything emitted is debris and a bug in this law.
      if (fit) {
        if (!(width[e] / ce >= lattice_percolation_cells_per_member_min(topo)))
          throw std::logic_error(
              "grade_lattice: fit emitted lattice below the percolation floor");
      } else if (!retained) {
        throw std::logic_error(
            "grade_lattice: emitted lattice below the cells-per-member floor");
      }
      if (retained) ++seen_subfloor;
    }
    if (!(octet_strut_diameter_mm(rho, ce) >= params.min_extrudable_width_mm) &&
        (swept || fit))
      throw std::logic_error(
          "grade_lattice: plan emitted a strut under the stated minimum "
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
  // FIT is the other way material may legally sit under the floor, and it is not an
  // exemption from the accounting: every such voxel is counted in
  // `fit_out_of_regime_voxels`, so the same demand — that sub-floor material be
  // NAMED, not merely permitted — is met. What is asserted here instead is that the
  // count and the posture agree.
  if (fit) {
    std::size_t seen_oor = 0;
    for (std::size_t e = 0; e < n; ++e) {
      if (!post.mask[e]) continue;
      const double ce = voxel_cell.empty() ? cell : voxel_cell[e];
      if (width[e] / ce < n_star) ++seen_oor;
    }
    if (seen_oor != out.fit_out_of_regime_voxels)
      throw std::logic_error(
          "grade_lattice: fit's out-of-regime count disagrees with the posture");
  } else if (out.subfloor_retained_voxels == 0 && out.latticed_voxels > 0 &&
             !(out.min_cells_per_member >= (adaptive_cpm ? adaptive_plan_floor
                                                         : n_star))) {
    // ★ NOT A WEAKENING — the bound is the floor that GOVERNED. Without the adaptive
    // rule this is the accuracy floor, exactly as before. With it, the admissible
    // bound is the floor the rule computed from the measured error curve and what the
    // material carries, and anything under it still throws.
    throw std::logic_error(
        "grade_lattice: thinnest latticed member is below the floor with no "
        "retention in force");
  }
  // ★ AND THE RELAXATION MUST BE NAMED. If the adaptive rule let material through
  // below the ACCURACY floor, that material has to be counted — a silent relaxation
  // would leave a certificate trusting a tensor that no longer describes the member.
  if (adaptive_cpm && out.latticed_voxels > 0 &&
      out.min_cells_per_member < n_star &&
      out.aesthetic_below_accuracy_floor_voxels == 0)
    throw std::logic_error(
        "grade_lattice: material sits below the accuracy floor but none was counted "
        "as out of regime");

  // ── ★ THE DENSITY DISTRIBUTION (bar R1) ─────────────────────────────────────
  // One pass in voxel order over the LATTICED set, into fixed bins spanning the
  // band. Deterministic by construction (bar §1b): no sampling, no RNG, and the
  // bin edges depend only on the band, which is read from core.
  //
  // WHY THIS EXISTS. `rho_min_used` / `rho_max_used` are the ENDS, and on the
  // maintainer's part they spanned the whole band while 19.07 % of the voxels sat on
  // the floor — the aggregate said "the full band is in use" and the distribution
  // said "a fifth of it is pinned". R1 asks for the fraction at the floor, so the
  // law reports the shape, not just the extremes.
  {
    const double span = rho_hi - rho_lo;
    const double eps = 1e-9;
    std::vector<double> util;                 // for the median, if armed
    if (allowable > 0.0) util.reserve(out.latticed_voxels);
    for (std::size_t e = 0; e < n; ++e) {
      if (!post.mask[e]) continue;
      const double r = post.relative_density[e];
      if (r <= rho_lo + eps) ++out.density_at_floor_voxels;
      if (r >= rho_hi - eps) ++out.density_at_ceiling_voxels;
      int b = span > 0.0
                  ? static_cast<int>((r - rho_lo) / span * GradedField::kDensityBins)
                  : 0;
      if (b < 0) b = 0;
      if (b >= GradedField::kDensityBins) b = GradedField::kDensityBins - 1;
      ++out.density_histogram[b];
      if (allowable > 0.0 && std::isfinite(demand[e]))
        util.push_back(demand[e] / allowable);
    }
    // ── ★ §2: WHICH LATTICED MATERIAL IS CERTIFIED ON SELF-WEIGHT ALONE ───────
    // A region below `unloaded_utilisation_max` of the allowable need not certify
    // against the LOAD — only hold itself up. Counted here so the claim is visible:
    // material in this set carries a WEAKER claim than the rest, and §2(d) requires
    // that to be said in plain words on the card rather than buried.
    //
    // Evaluated over the CANDIDATE SET as one group when the caller supplied no
    // region ids — which is the union reading, and is exactly what the lattice-only
    // path passes (analyze grades the whole printed design). With ids, a region
    // qualifies on its own peak, which is the per-region reading the sub-floor
    // breakdown already uses.
    if (allowable > 0.0 && params.unloaded_utilisation_max > 0.0 &&
        out.max_utilisation <= params.unloaded_utilisation_max)
      out.unloaded_voxels = out.latticed_voxels;

    // A FULL SORT, never a sampled estimate (bar §1b). The median utilisation is
    // what makes "most of this part sits at 4 % of allowable" a reportable fact
    // rather than an impression from tapping the preview.
    if (!util.empty()) {
      std::sort(util.begin(), util.end());
      out.median_utilisation = util[util.size() / 2];
    }
  }

  return out;
}

}  // namespace topopt
