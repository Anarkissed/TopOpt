// F3 + F10 of task 2026-09-28-flexible-squish-maths: the squish lookup (σ(ε; ρ)),
// its inverse, the soft and rigid forward solves, and tiers/bands.
//
// ★ The spot values below are typed from Iacob et al. 2024, Polymer Testing 137,
// 108517, TABLE 2 (papers/1-s2.0-S0142941824001946-main.pdf), not copied from the
// data file: they check the file AND the lookup against the paper in one pass.

#include "topopt/flexible/squish.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt::flexible;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static bool near(double a, double b, double rel) {
  return std::fabs(a - b) <= rel * std::max(std::fabs(a), std::fabs(b)) + 1e-15;
}

// Iacob 2024 Table 2: specimen "temp–infill", then E10 and E20 (MPa) for G(yroid)
// and H(oneycomb).
struct Table2Row { int temp; int infill; double g10, g20, h10, h20; };
static const Table2Row kTable2[] = {
    {190, 35, 5.17, 4.88, 8.56, 9.08}, {220, 35, 1.68, 1.59, 2.6, 3.02},
    {240, 35, 1.82, 1.75, 2.94, 3.19}, {190, 30, 4.35, 3.91, 8.18, 8.54},
    {220, 30, 1.45, 1.33, 2.38, 2.76}, {240, 30, 1.47, 1.41, 2.82, 3.0},
    {190, 25, 3.2, 2.57, 6.87, 7.14},  {220, 25, 1.13, 0.97, 1.96, 2.26},
    {240, 25, 1.19, 1.11, 2.25, 2.42}, {190, 20, 2.19, 1.46, 5.95, 5.79},
    {220, 20, 0.77, 0.59, 1.62, 1.79}, {240, 20, 0.84, 0.75, 1.7, 1.84},
    {190, 15, 1.19, 0.71, 4.06, 3.26}, {220, 15, 0.43, 0.31, 1.47, 1.59},
    {240, 15, 0.51, 0.4, 1.36, 1.46},  {190, 10, 0.42, 0.27, 1.65, 1.28},
    {220, 10, 0.2, 0.14, 0.64, 0.54},  {240, 10, 0.18, 0.14, 0.74, 0.69},
};
// 02 §2's printed-core axis (190 °C mapping), by infill 10..35.
static const double kGyroidCore[] = {0.143, 0.180, 0.226, 0.271, 0.316, 0.362};
static const double kHoneyCore[] = {0.165, 0.236, 0.286, 0.341, 0.396, 0.446};

static const FlexibleData& data() {
  static FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  return d;
}

static CurveSet set_of(double temp, const char* topo) {
  CurveSetResult r = curve_set(data(), "varioshore_tpu", temp, topo);
  CHECK(!r.refusal.refused(), "curve set builds");
  return r.set;
}

static void test_spot_values() {
  int checked = 0;
  for (const Table2Row& t : kTable2) {
    const int idx = (t.infill - 10) / 5;
    for (int topo = 0; topo < 2; ++topo) {
      const CurveSet s = set_of(t.temp, topo == 0 ? "gyroid" : "honeycomb");
      const double rho = topo == 0 ? kGyroidCore[idx] : kHoneyCore[idx];
      const double e10 = topo == 0 ? t.g10 : t.h10;
      const double e20 = topo == 0 ? t.g20 : t.h20;
      const StressResult a = stress_at(s, 0.10, rho);
      const StressResult b = stress_at(s, 0.20, rho);
      CHECK(a.ok && near(a.stress_mpa, 0.10 * e10, 1e-9), "σ(0.10) = 0.10 × E10 (Table 2)");
      CHECK(b.ok && near(b.stress_mpa, 0.20 * e20, 1e-9), "σ(0.20) = 0.20 × E20 (Table 2)");
      CHECK(!a.extrapolated && !b.extrapolated, "tabulated strains are measured");
      checked += 2;
    }
  }
  CHECK(checked == 72, "all 36 rows x 2 strains checked");
  // The task's own example: nominal 20 % gyroid at 190 °C, ε = 0.20 → 0.292 MPa.
  const CurveSet g190 = set_of(190, "gyroid");
  const StressResult ex = stress_at(g190, 0.20, 0.226);
  CHECK(ex.ok && near(ex.stress_mpa, 0.292, 1e-12), "20 % gyroid 190 °C at 0.20 = 0.292 MPa");
  CHECK(g190.density_basis == "estimated_core (190 \xC2\xB0""C mapping)",
        "every set records its density basis");
  CHECK(set_of(220, "gyroid").density_basis == g190.density_basis,
        "220 °C uses the 190 °C mapping, and says so");
}

static void test_interpolation() {
  const CurveSet s = set_of(190, "gyroid");
  // Piecewise linear through the origin below the first point.
  const StressResult half = stress_at(s, 0.05, 0.226);
  CHECK(half.ok && near(half.stress_mpa, 0.5 * 0.219, 1e-12), "linear from (0,0) to (0.1,σ10)");
  const StressResult mid = stress_at(s, 0.15, 0.226);
  CHECK(mid.ok && near(mid.stress_mpa, 0.5 * (0.219 + 0.292), 1e-12), "linear between points");
  // Linear in ρ between rows (the 15 % and 20 % rows at 0.10).
  const double r = 0.180 + 0.25 * (0.226 - 0.180);
  const StressResult q = stress_at(s, 0.10, r);
  CHECK(q.ok && near(q.stress_mpa, 0.119 + 0.25 * (0.219 - 0.119), 1e-12),
        "linear in ρ between bracketing rows");
  CHECK(stress_at(s, 0.0, 0.2).ok && stress_at(s, 0.0, 0.2).stress_mpa == 0.0,
        "zero strain is zero stress");
  // Extrapolation zone (R8): 0.20 < ε <= 0.25.
  const StressResult x = stress_at(s, 0.25, 0.226);
  CHECK(x.ok && x.extrapolated, "ε = 0.25 is 'extrapolated'");
  CHECK(near(x.stress_mpa, 0.292 + 0.5 * (0.292 - 0.219), 1e-12),
        "extrapolation extends the last segment linearly");
  CHECK(stress_at(s, 0.2000001, 0.226).extrapolated, "just past 0.20 is extrapolated");
  CHECK(!stress_at(s, 0.2, 0.226).extrapolated, "0.20 exactly is measured");
  CHECK(s.strain_measured_max() == 0.20 && s.strain_limit() == 0.25, "zone limits");
}

static void test_refusals() {
  const CurveSet s = set_of(190, "gyroid");
  StressResult r = stress_at(s, 0.2500001, 0.226);
  CHECK(!r.ok && r.refusal.code == "strain_beyond_data", "ε > 0.25 refused (R8)");
  r = stress_at(s, 0.1, 0.1429);
  CHECK(!r.ok && r.refusal.code == "density_below_range", "ρ below the table refused");
  r = stress_at(s, 0.1, 0.3621);
  CHECK(!r.ok && r.refusal.code == "density_above_range", "ρ above the table refused");
  r = stress_at(s, -0.01, 0.2);
  CHECK(!r.ok && r.refusal.code == "negative_strain", "negative strain refused");
  CHECK(!r.refusal.reason.empty(), "every refusal carries a sentence");
  // Gates: never across temperatures, topologies, materials (R10, 02 §3).
  CurveSetResult c = curve_set(data(), "varioshore_tpu", 205, "gyroid");
  CHECK(c.refusal.code == "temperature_not_tested", "205 °C is between tested temps: refused");
  CHECK(c.refusal.reason.find("190") != std::string::npos, "the refusal names the offered temps");
  c = curve_set(data(), "varioshore_tpu", 190, "octet");
  CHECK(c.refusal.code == "topology_no_data", "no octet table");
  c = curve_set(data(), "tpu95a_generic", 220, "gyroid");
  CHECK(c.refusal.code == "calibrate_first", "calibrate_first predicts nothing");
  c = curve_set(data(), "ninjaflex_85a", 230, "gyroid");
  CHECK(c.refusal.code == "calibrate_first", "proxy_candidate is calibrate_first until Q4");
  c = curve_set(data(), "no_such", 190, "gyroid");
  CHECK(c.refusal.code == "unknown_material", "unknown material");
  const std::vector<double> temps = tested_temperatures(data(), "varioshore_tpu");
  CHECK(temps.size() == 3 && temps[0] == 190 && temps[2] == 240, "tested temperatures");
  CHECK(tested_temperatures(data(), "tpu95a_generic").empty(), "calibrate_first offers none");
}

static void test_monotone() {
  for (double temp : {190.0, 220.0, 240.0})
    for (const char* topo : {"gyroid", "honeycomb"}) {
      const CurveSet s = set_of(temp, topo);
      bool rho_ok = true, eps_ok = true;
      for (int i = 1; i <= 25; ++i) {
        const double e = 0.01 * i;
        double prev = -1.0;
        for (int k = 0; k <= 40; ++k) {
          const double rho = s.density_min() + (s.density_max() - s.density_min()) * k / 40.0;
          const double v = stress_at(s, e, rho).stress_mpa;
          if (!(v > prev)) rho_ok = false;
          prev = v;
        }
      }
      for (int k = 0; k <= 40; ++k) {
        const double rho = s.density_min() + (s.density_max() - s.density_min()) * k / 40.0;
        double prev = 0.0;
        for (int i = 1; i <= 250; ++i) {
          const double v = stress_at(s, 0.001 * i, rho).stress_mpa;
          if (!(v > prev)) eps_ok = false;
          prev = v;
        }
      }
      CHECK(rho_ok, "σ strictly increasing in ρ at fixed ε");
      CHECK(eps_ok, "σ strictly increasing in ε at fixed ρ");
    }
}

static void test_round_trip() {
  double worst_rho = 0.0, worst_eps = 0.0;
  for (double temp : {190.0, 220.0, 240.0})
    for (const char* topo : {"gyroid", "honeycomb"}) {
      const CurveSet s = set_of(temp, topo);
      for (int k = 0; k <= 20; ++k)
        for (int i = 1; i <= 25; ++i) {
          const double rho = s.density_min() + (s.density_max() - s.density_min()) * k / 20.0;
          const double eps = 0.01 * i;
          const double sig = stress_at(s, eps, rho).stress_mpa;
          const InverseResult inv = density_for(s, eps, sig);
          CHECK(inv.ok && inv.status == "ok", "inverse reaches a tabulated point");
          worst_rho = std::max(worst_rho, std::fabs(inv.core_density - rho) / rho);
          const StrainResult fw = strain_under(s, sig, inv.core_density);
          CHECK(fw.ok, "forward solves");
          worst_eps = std::max(worst_eps, std::fabs(fw.strain - eps) / eps);
          CHECK(inv.extrapolated == (eps > 0.2 + 1e-12), "inverse flags the extrapolated zone");
        }
    }
  std::printf("  round trip worst relative error: rho %.3g, strain %.3g\n", worst_rho, worst_eps);
  CHECK(worst_rho <= 1e-6, "inverse -> ρ within 1e-6 relative");
  CHECK(worst_eps <= 1e-6, "inverse -> forward -> ε within 1e-6 relative");
}

static void test_unreachable() {
  const CurveSet s = set_of(190, "gyroid");
  // 0.001 MPa at ε = 0.20: even the softest row (σ ≈ 0.054) is far too firm.
  InverseResult r = density_for(s, 0.20, 0.001);
  CHECK(!r.ok && r.status == "too_firm", "a load too light to squish the softest -> too_firm");
  const StrainResult soft = strain_under(s, 0.001, s.density_min());
  CHECK(r.nearest_known && near(r.nearest_strain, soft.strain, 1e-12) &&
            r.nearest_density == s.density_min(),
        "nearest achievable = the softest lattice at this force");
  // 0.9 MPa at ε = 0.05: firmer than the firmest can hold.
  r = density_for(s, 0.05, 0.9);
  CHECK(!r.ok && r.status == "too_soft", "a load that squishes even the firmest too far");
  const StrainResult firm = strain_under(s, 0.9, s.density_max());
  CHECK(r.nearest_known == firm.ok, "nearest known iff the forward is inside the data");
  // 5 MPa: the firmest runs out of data before carrying it.
  r = density_for(s, 0.05, 5.0);
  CHECK(r.status == "too_soft" && !r.nearest_known, "nearest beyond the data is flagged unknown");
  r = density_for(s, 0.30, 0.2);
  CHECK(!r.ok && r.status == "beyond_data" && r.refusal.code == "strain_beyond_data",
        "target strain past 0.25 is refused");
  r = density_for(s, 0.1, 0.0);
  CHECK(!r.ok && r.status == "no_pressure", "no pressure: no density to choose");
  r = density_for(s, 0.0, 0.05);
  CHECK(!r.ok && r.status == "too_soft", "zero depth under load: nothing is stiff enough");
  StrainResult f = strain_under(s, 5.0, 0.2);
  CHECK(!f.ok && f.refusal.code == "beyond_data", "forward past the data refused");
  f = strain_under(s, -1.0, 0.2);
  CHECK(!f.ok && f.refusal.code == "negative_pressure", "negative pressure refused");
}

static void test_rigid() {
  const CurveSet s = set_of(220, "gyroid");
  // Four identical columns: the common depth equals the soft solve at F / A.
  RigidResult r = rigid_press(s, {25, 25, 25, 25}, {20, 20, 20, 20}, {0.2, 0.2, 0.2, 0.2}, 2.0);
  const StrainResult e = strain_under(s, 2.0 / 100.0, 0.2);
  CHECK(r.ok && near(r.depth_mm, e.strain * 20.0, 1e-9), "uniform columns: rigid == soft");
  // Mixed columns: equilibrium holds.
  const std::vector<double> a{10, 20, 30}, h{10, 20, 15}, rho{0.15, 0.25, 0.33};
  r = rigid_press(s, a, h, rho, 3.0);
  CHECK(r.ok, "mixed rigid press solves");
  double f = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i)
    f += a[i] * stress_at(s, r.depth_mm / h[i], rho[i]).stress_mpa;
  CHECK(near(f, 3.0, 1e-9), "Σ aᵢσᵢ(d/hᵢ) = F");
  CHECK(r.strain.size() == 3 && near(r.strain[0], r.depth_mm / 10.0, 1e-15), "per-column strain");
  r = rigid_press(s, a, h, rho, 1e4);
  CHECK(!r.ok && r.refusal.code == "beyond_data", "a force past the data is refused");
}

static void test_tiers_and_cells() {
  const ErrorBands& b = data().catalogue.error_bands;
  TierBand t = tier_band(b, "literature", false, 1);
  CHECK(t.tier == "literature" && t.band == 0.40, "literature ±40 %");
  t = tier_band(b, "calibrated", false, 1);
  CHECK(t.tier == "calibrated" && t.band == 0.20, "calibrated ±20 %");
  t = tier_band(b, "proxy", false, 1);
  CHECK(t.tier == "proxy" && t.band == 0.50, "proxy ±50 %");
  t = tier_band(b, "literature", true, 1);
  CHECK(t.tier == "estimated" && t.band == 0.50, "side stack -> estimated, proxy band");
  t = tier_band(b, "calibrated", false, 2);
  CHECK(t.tier == "estimated" && t.band == 0.50, "2-bead wall -> estimated, proxy band");
  CHECK(!t.why.empty(), "the tier says why");
  // 03 §2's table: ρ 0.20, 1 bead of 0.42 mm -> L 6.49 mm; 2 beads -> 12.98 mm.
  CHECK(near(cell_size_mm("gyroid", 0.20, 1, 0.42), 3.0915 * 0.42 / 0.20, 1e-15) &&
            std::fabs(cell_size_mm("gyroid", 0.20, 1, 0.42) - 6.49) < 0.005,
        "gyroid L = 3.0915 t / ρ");
  CHECK(std::fabs(cell_size_mm("gyroid", 0.20, 2, 0.42) - 12.98) < 0.005, "2 beads double t");
  CHECK(near(cell_size_mm("honeycomb", 0.20, 1, 0.42), 4.2, 1e-15), "honeycomb d = 2t / ρ");
}

int main() {
  test_spot_values();
  test_interpolation();
  test_refusals();
  test_monotone();
  test_round_trip();
  test_unreachable();
  test_rigid();
  test_tiers_and_cells();
  std::printf("test_flexible_squish: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
