#pragma once

#include <string>
#include <vector>

#include "topopt/flexible/data.hpp"
#include "topopt/flexible/error.hpp"

namespace topopt {
namespace flexible {

// ════════════════════════════════════════════════════════════════════════════════
// F3 — THE SQUISH LOOKUP (02 §3–5). NOT FEA (DECISIONS 2026-09-27 item 2).
//
// ★ STRAIN CONVENTION — NOMINAL, THE SPECIMEN'S OWN. Strain is squish depth ÷ the
// column's latticed height, and stress is force ÷ loaded area, exactly as the table
// states them: Iacob's strain is nominal over the whole 12.5 mm specimen, 1.6 mm of
// skins included, and no skin-ratio correction is applied (02 §2 offers the core
// convention as the alternative; this module picked ONE and says so in every
// receipt). So R8's limits read literally: ≤ the last tabulated strain (0.20) is
// measured, up to strain_max_measured (0.25) is 'extrapolated', beyond is refused.
//
// Across density: linear in the printed-core density ρ at fixed strain, between the
// two bracketing rows. Never across temperatures, topologies or materials.
// ════════════════════════════════════════════════════════════════════════════════

// The strain convention string every receipt carries.
extern const char* const kStrainConvention;

// One row of a curve set, on the core-density axis.
struct CurveRow {
  std::string entry_id;
  double core_density = 0.0;
  double nominal = 0.0;              // the entry's own relative_density
  std::vector<CurvePoint> loading;   // strictly increasing, as loaded
  double strain_max_measured = 0.0;
  std::string tier;                  // literature | calibrated | proxy
  MaybeNumber rel_sd;
  MaybeNumber specimen_density_g_cm3;  // the tested specimen's mass density (skins included)
};

// Every row for ONE (material, tested temperature, topology), ascending in core
// density. The unit every lookup below works on.
struct CurveSet {
  std::string material_id;
  double nozzle_temp_c = 0.0;
  std::string topology;
  std::string density_basis;  // e.g. "estimated_core (190 °C mapping)"
  std::string tier;           // the rows' tier (they must agree)
  std::string strain_convention;  // how the rows' strain axis is defined (receipt)
  std::vector<CurveRow> rows;
  double density_min() const { return rows.front().core_density; }
  double density_max() const { return rows.back().core_density; }
  // The last TABULATED strain (the end of the 'measured' zone) and the refusal
  // limit. For a mixed set these are the smallest over the rows, so a strain is
  // measured/allowed only where EVERY row says so.
  double strain_measured_max() const;
  double strain_limit() const;
};

struct CurveSetResult {
  CurveSet set;
  Refusal refusal;  // refused() => `set` is empty and must not be used
};

// Build the curve set, applying every gate in order and refusing with a code:
//   "unknown_material"        — not in the catalogue
//   "calibrate_first"         — tier calibrate_first, or proxy_candidate (Q4 open)
//   "temperature_not_tested"  — foaming: not in offered_nozzle_temps_c; otherwise
//                               no table row at exactly this temperature (R10)
//   "topology_no_data"        — no rows for this topology at this temperature
//   "too_few_rows"            — fewer than two densities (no range to interpolate)
// Throws FlexibleError only when the density axis itself is malformed data.
CurveSetResult curve_set(const FlexibleData& data, const std::string& material_id,
                         double nozzle_temp_c, const std::string& topology);

// The temperatures a material may be predicted at: offered_nozzle_temps_c for a
// foaming material; for a non-foaming one, the distinct temperatures its rows were
// tested at. Empty for a material that predicts nothing.
std::vector<double> tested_temperatures(const FlexibleData& data,
                                        const std::string& material_id);

// σ(ε; ρ). ok == false with a refusal:
//   "negative_strain", "strain_beyond_data" (ε > strain_limit),
//   "density_below_range", "density_above_range".
// `extrapolated` is set when ε lies past the last tabulated strain.
struct StressResult {
  bool ok = false;
  double stress_mpa = 0.0;
  bool extrapolated = false;
  Refusal refusal;
};
StressResult stress_at(const CurveSet& set, double strain, double core_density);

// THE INVERSE (02 §4): the density whose curve passes through (ε*, σ*), by
// bisection on [ρ_min, ρ_max]. `status`:
//   "ok"          — reached (ok == true; `extrapolated` if ε* > the tabulated end)
//   "too_firm"    — σ* < σ(ε*; ρ_min): even the SOFTEST lattice will not squish
//                   that deep under this pressure
//   "too_soft"    — σ* > σ(ε*; ρ_max): even the FIRMEST lattice squishes deeper
//   "beyond_data" — ε* > strain_limit (refused, R8)
//   "no_pressure" — σ* <= 0: an unloaded column has no density to choose
// For too_firm / too_soft, `nearest_strain` is the strain the nearest achievable
// density (ρ_min / ρ_max) actually gives at this pressure — the number the user can
// act on — with `nearest_known == false` when that is itself beyond the data.
struct InverseResult {
  bool ok = false;
  std::string status;
  double core_density = 0.0;
  bool extrapolated = false;
  double nearest_density = 0.0;
  double nearest_strain = 0.0;
  bool nearest_known = false;
  bool nearest_extrapolated = false;
  Refusal refusal;
};
InverseResult density_for(const CurveSet& set, double target_strain,
                          double pressure_mpa);

// The measured specimen mass density at core density ρ, linear in ρ between the rows
// (H2: the mass tiebreak weighs grams). Unknown when a bracketing row lacks it or ρ is
// outside the table.
MaybeNumber specimen_density_g_cm3(const CurveSet& set, double core_density);

// FORWARD, SOFT (02 §5): the strain a column of density ρ takes under pressure p
// (closed form per column; solved by bisection on ε). Refusals as stress_at, plus
// "beyond_data" when p exceeds σ(strain_limit; ρ) and "negative_pressure".
struct StrainResult {
  bool ok = false;
  double strain = 0.0;
  bool extrapolated = false;
  Refusal refusal;
};
StrainResult strain_under(const CurveSet& set, double pressure_mpa,
                          double core_density);

// FORWARD, RIGID (02 §5, §11): one common depth d under the footprint with
// Σ aᵢ·σᵢ(d / hᵢ) = F, by bisection (the left side is monotone in d). Refused
// "beyond_data" when F exceeds what the columns carry at their strain limit.
struct RigidResult {
  bool ok = false;
  double depth_mm = 0.0;
  std::vector<double> strain;  // per column, d / hᵢ
  bool any_extrapolated = false;
  Refusal refusal;
};
RigidResult rigid_press(const CurveSet& set, const std::vector<double>& area_mm2,
                        const std::vector<double>& height_mm,
                        const std::vector<double>& core_density, double force_n);

// ════════════════════════════════════════════════════════════════════════════════
// F10 — TIERS AND BANDS (02 §7, R2, R7, R12 of 00-decisions)
//
// Every depth carries a tier and a ± band (a fraction of the depth). The band
// comes from error_band_defaults; nothing here invents a number.
//   literature → literature_same_material, calibrated → calibrated,
//   proxy → proxy, and ESTIMATED → the proxy band: a side-loaded stack (R6, M12)
//   or a 2-bead wall (R2, Justino Netto 2024) whatever the table's own tier.
// ════════════════════════════════════════════════════════════════════════════════
struct TierBand {
  std::string tier;   // literature | calibrated | proxy | estimated
  double band = 0.0;  // fraction of depth
  std::string why;    // one sentence
};
TierBand tier_band(const ErrorBands& bands, const std::string& set_tier,
                   bool side_stack, int beads_per_wall);

// The planning relation between density and cell size (03 §2, §3; F7):
//   gyroid     L = 3.0915·t / ρ
//   honeycomb  d = 2·t / ρ
// with t = beads_per_wall × bead width. Throws FlexibleError on a bad topology or
// a non-positive argument.
double cell_size_mm(const std::string& topology, double core_density,
                    int beads_per_wall, double bead_width_mm);

}  // namespace flexible
}  // namespace topopt
