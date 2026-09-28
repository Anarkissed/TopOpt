#include "topopt/flexible/squish.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace topopt {
namespace flexible {

const char* const kStrainConvention =
    "nominal: strain = squish depth / the column's latticed height, stress = force / "
    "loaded area, exactly as the table states them (Iacob: nominal over the whole "
    "12.5 mm specimen, 1.6 mm of skins included). No skin-ratio correction is applied.";

namespace {

// Comparisons at the edges of the data: a value equal to a tabulated limit is
// inside; anything past it by more than rounding is outside.
constexpr double kEdgeTol = 1e-12;
constexpr int kBisectIterations = 200;

std::string fmt(double v) {
  char b[40];
  std::snprintf(b, sizeof(b), "%.4g", v);
  return b;
}

Refusal refuse(const std::string& code, const std::string& reason) {
  return Refusal{code, reason};
}

// σ(ε) of ONE row: piecewise linear through (0,0) and every point, then the last
// segment extended. The caller has already refused ε outside [0, limit].
double row_stress(const CurveRow& r, double e) {
  double pe = 0.0, ps = 0.0;
  for (const CurvePoint& p : r.loading) {
    if (e <= p.strain) return ps + (p.stress_mpa - ps) * (e - pe) / (p.strain - pe);
    pe = p.strain;
    ps = p.stress_mpa;
  }
  const CurvePoint& b = r.loading.back();
  const CurvePoint& a = r.loading[r.loading.size() - 2];
  return b.stress_mpa + (b.stress_mpa - a.stress_mpa) / (b.strain - a.strain) * (e - b.strain);
}

// σ(ε; ρ) with ρ ALREADY inside [ρ_min, ρ_max] and ε inside [0, limit].
double stress_raw(const CurveSet& s, double e, double rho) {
  const std::vector<CurveRow>& rows = s.rows;
  if (rho <= rows.front().core_density) return row_stress(rows.front(), e);
  if (rho >= rows.back().core_density) return row_stress(rows.back(), e);
  std::size_t i = 1;
  while (i + 1 < rows.size() && rows[i].core_density < rho) ++i;
  const CurveRow& a = rows[i - 1];
  const CurveRow& b = rows[i];
  const double w = (rho - a.core_density) / (b.core_density - a.core_density);
  return (1.0 - w) * row_stress(a, e) + w * row_stress(b, e);
}

Refusal density_gate(const CurveSet& s, double rho) {
  if (!std::isfinite(rho))
    return refuse("density_below_range", "the density is not a finite number");
  if (rho < s.density_min() - kEdgeTol)
    return refuse("density_below_range",
                  "a core density of " + fmt(rho) + " is below the softest tested row (" +
                      fmt(s.density_min()) + ", " + s.density_basis + ")");
  if (rho > s.density_max() + kEdgeTol)
    return refuse("density_above_range",
                  "a core density of " + fmt(rho) + " is above the firmest tested row (" +
                      fmt(s.density_max()) + ", " + s.density_basis + ")");
  return Refusal{};
}

double clamp_rho(const CurveSet& s, double rho) {
  return std::min(std::max(rho, s.density_min()), s.density_max());
}

}  // namespace

double CurveSet::strain_measured_max() const {
  double m = rows.front().loading.back().strain;
  for (const CurveRow& r : rows) m = std::min(m, r.loading.back().strain);
  return m;
}

double CurveSet::strain_limit() const {
  double m = rows.front().strain_max_measured;
  for (const CurveRow& r : rows) m = std::min(m, r.strain_max_measured);
  return m;
}

std::vector<double> tested_temperatures(const FlexibleData& data,
                                        const std::string& material_id) {
  std::vector<double> out;
  auto it = data.catalogue.materials.find(material_id);
  if (it == data.catalogue.materials.end() || it->second.tier != "literature") return out;
  if (it->second.foaming) return it->second.offered_nozzle_temps_c;
  std::set<double> ts;
  for (const CurveTable& t : data.tables)
    for (const CurveEntry& e : t.entries)
      if (e.material_id == material_id) ts.insert(e.nozzle_temp_c);
  out.assign(ts.begin(), ts.end());
  return out;
}

CurveSetResult curve_set(const FlexibleData& data, const std::string& material_id,
                         double nozzle_temp_c, const std::string& topology) {
  CurveSetResult out;
  auto it = data.catalogue.materials.find(material_id);
  if (it == data.catalogue.materials.end()) {
    out.refusal = refuse("unknown_material",
                         "\"" + material_id + "\" is not in flexible_materials.json");
    return out;
  }
  const Material& m = it->second;
  if (m.tier == "calibrate_first") {
    out.refusal = refuse("calibrate_first",
                         m.display_name + " has no lattice squish data. It can be built, but "
                         "no squish is predicted until in-house coupons are measured.");
    return out;
  }
  if (m.tier == "proxy_candidate") {
    out.refusal = refuse("calibrate_first",
                         m.display_name + " has solid-material data only. Scaling another "
                         "filament's table to it (a proxy) is open question Q4, so until the "
                         "maintainer rules on it, no squish is predicted.");
    return out;
  }
  if (m.tier != "literature") {
    out.refusal = refuse("calibrate_first", m.display_name + " has tier \"" + m.tier +
                                                "\", which predicts nothing");
    return out;
  }
  const std::vector<double> temps = tested_temperatures(data, material_id);
  if (std::find(temps.begin(), temps.end(), nozzle_temp_c) == temps.end()) {
    std::string list;
    for (double t : temps) list += (list.empty() ? "" : ", ") + fmt(t);
    out.refusal = refuse("temperature_not_tested",
                         m.display_name + " was tested at " + list + " \xC2\xB0""C only; " +
                             fmt(nozzle_temp_c) + " \xC2\xB0""C is not one of them, and "
                             "squish is never interpolated between temperatures (R10)");
    return out;
  }

  std::vector<const CurveEntry*> hits;
  std::set<std::string> topologies_here;
  for (const CurveTable& t : data.tables)
    for (const CurveEntry& e : t.entries) {
      if (e.material_id != material_id || e.nozzle_temp_c != nozzle_temp_c) continue;
      topologies_here.insert(e.topology);
      if (e.topology == topology) hits.push_back(&e);
    }
  if (hits.empty()) {
    std::string list;
    for (const std::string& t : topologies_here) list += (list.empty() ? "" : ", ") + t;
    out.refusal = refuse("topology_no_data",
                         "there is no " + topology + " table for " + m.display_name + " at " +
                             fmt(nozzle_temp_c) + " \xC2\xB0""C" +
                             (list.empty() ? std::string() : " (tested: " + list + ")"));
    return out;
  }
  if (hits.size() < 2) {
    out.refusal = refuse("too_few_rows", "only one " + topology + " density was tested for " +
                                             m.display_name + " at " + fmt(nozzle_temp_c) +
                                             " \xC2\xB0""C: there is no range to work in");
    return out;
  }

  const DensityAxis axis = build_density_axis(data, material_id, topology);
  CurveSet& s = out.set;
  s.material_id = material_id;
  s.nozzle_temp_c = nozzle_temp_c;
  s.topology = topology;
  s.density_basis = axis.density_basis;
  for (const CurveEntry* e : hits) {
    CurveRow r;
    r.entry_id = e->id;
    r.core_density = core_density_of(axis, *e);
    r.nominal = e->relative_density;
    r.loading = e->loading;
    r.strain_max_measured = e->strain_max_measured;
    r.tier = e->tier;
    r.rel_sd = e->rel_sd;
    s.rows.push_back(r);
  }
  std::sort(s.rows.begin(), s.rows.end(),
            [](const CurveRow& a, const CurveRow& b) { return a.core_density < b.core_density; });
  for (std::size_t i = 1; i < s.rows.size(); ++i)
    if (!(s.rows[i].core_density > s.rows[i - 1].core_density))
      throw FlexibleError("rows \"" + s.rows[i - 1].entry_id + "\" and \"" + s.rows[i].entry_id +
                          "\" sit at the same core density");
  s.tier = s.rows.front().tier;
  for (const CurveRow& r : s.rows)
    if (r.tier != s.tier)
      throw FlexibleError("one curve set mixes tiers (\"" + s.tier + "\" and \"" + r.tier +
                          "\"); a prediction must carry one tier");
  return out;
}

StressResult stress_at(const CurveSet& s, double strain, double rho) {
  StressResult out;
  if (!std::isfinite(strain) || strain < 0.0) {
    out.refusal = refuse("negative_strain", "a strain of " + fmt(strain) + " is not a squish");
    return out;
  }
  if (strain > s.strain_limit() + kEdgeTol) {
    out.refusal = refuse("strain_beyond_data",
                         "a strain of " + fmt(strain) + " is past the " + fmt(s.strain_limit()) +
                             " the tests reached (R8)");
    return out;
  }
  out.refusal = density_gate(s, rho);
  if (out.refusal.refused()) return out;
  out.ok = true;
  out.stress_mpa = stress_raw(s, strain, clamp_rho(s, rho));
  out.extrapolated = strain > s.strain_measured_max() + kEdgeTol;
  return out;
}

StrainResult strain_under(const CurveSet& s, double p, double rho) {
  StrainResult out;
  if (!std::isfinite(p) || p < 0.0) {
    out.refusal = refuse("negative_pressure", "a pressure of " + fmt(p) + " MPa is not a load");
    return out;
  }
  out.refusal = density_gate(s, rho);
  if (out.refusal.refused()) return out;
  const double r = clamp_rho(s, rho);
  const double lim = s.strain_limit();
  const double p_lim = stress_raw(s, lim, r);
  if (p > p_lim * (1.0 + kEdgeTol)) {
    out.refusal = refuse("beyond_data",
                         "a pressure of " + fmt(p) + " MPa squishes a " + fmt(r) +
                             " lattice past the " + fmt(lim) + " strain the tests reached (it "
                             "holds " + fmt(p_lim) + " MPa there)");
    return out;
  }
  double lo = 0.0, hi = lim;
  if (p >= p_lim) {
    lo = hi = lim;
  } else if (p > 0.0) {
    for (int it = 0; it < kBisectIterations && hi - lo > 1e-16 * hi; ++it) {
      const double mid = 0.5 * (lo + hi);
      if (stress_raw(s, mid, r) < p)
        lo = mid;
      else
        hi = mid;
    }
  } else {
    hi = 0.0;
  }
  out.ok = true;
  out.strain = 0.5 * (lo + hi);
  out.extrapolated = out.strain > s.strain_measured_max() + kEdgeTol;
  return out;
}

InverseResult density_for(const CurveSet& s, double eps, double sig) {
  InverseResult out;
  if (!std::isfinite(sig) || sig <= 0.0) {
    out.status = "no_pressure";
    out.refusal = refuse("no_pressure", "an unloaded column has no density to choose");
    return out;
  }
  if (!std::isfinite(eps) || eps < 0.0) {
    out.status = "beyond_data";
    out.refusal = refuse("negative_strain", "a strain of " + fmt(eps) + " is not a squish");
    return out;
  }
  if (eps > s.strain_limit() + kEdgeTol) {
    out.status = "beyond_data";
    out.refusal = refuse("strain_beyond_data",
                         "a target strain of " + fmt(eps) + " is past the " +
                             fmt(s.strain_limit()) + " the tests reached (R8)");
    return out;
  }
  const double e = std::min(eps, s.strain_limit());
  const double lo_rho = s.density_min(), hi_rho = s.density_max();
  const double s_lo = stress_raw(s, e, lo_rho);
  const double s_hi = stress_raw(s, e, hi_rho);
  auto nearest = [&](double rho) {
    out.nearest_density = rho;
    const StrainResult f = strain_under(s, sig, rho);
    out.nearest_known = f.ok;
    out.nearest_strain = f.ok ? f.strain : 0.0;
    out.nearest_extrapolated = f.ok && f.extrapolated;
  };
  if (sig < s_lo) {
    out.status = "too_firm";
    out.refusal = refuse("too_firm", "even the softest lattice (" + fmt(lo_rho) + ") needs " +
                                         fmt(s_lo) + " MPa to reach a strain of " + fmt(e) +
                                         "; this column carries " + fmt(sig) + " MPa");
    nearest(lo_rho);
    return out;
  }
  if (sig > s_hi) {
    out.status = "too_soft";
    out.refusal = refuse("too_soft", "even the firmest lattice (" + fmt(hi_rho) + ") squishes "
                                         "past a strain of " + fmt(e) + " under " + fmt(sig) +
                                         " MPa (it holds " + fmt(s_hi) + " MPa there)");
    nearest(hi_rho);
    return out;
  }
  double a = lo_rho, b = hi_rho;
  for (int it = 0; it < kBisectIterations && b - a > 1e-16 * b; ++it) {
    const double mid = 0.5 * (a + b);
    if (stress_raw(s, e, mid) < sig)
      a = mid;
    else
      b = mid;
  }
  out.ok = true;
  out.status = "ok";
  out.core_density = 0.5 * (a + b);
  out.extrapolated = e > s.strain_measured_max() + kEdgeTol;
  return out;
}

RigidResult rigid_press(const CurveSet& s, const std::vector<double>& a,
                        const std::vector<double>& h, const std::vector<double>& rho,
                        double force) {
  RigidResult out;
  if (a.empty() || a.size() != h.size() || a.size() != rho.size())
    throw FlexibleError("rigid_press: area, height and density must be non-empty and parallel");
  for (std::size_t i = 0; i < a.size(); ++i) {
    if (!(a[i] > 0.0) || !(h[i] > 0.0))
      throw FlexibleError("rigid_press: every column needs area > 0 and height > 0");
    out.refusal = density_gate(s, rho[i]);
    if (out.refusal.refused()) return out;
  }
  if (!std::isfinite(force) || force < 0.0) {
    out.refusal = refuse("negative_pressure", "a force of " + fmt(force) + " N is not a load");
    return out;
  }
  const double lim = s.strain_limit();
  double d_max = lim * h[0];
  for (double hh : h) d_max = std::min(d_max, lim * hh);
  auto total = [&](double d) {
    double f = 0.0;
    for (std::size_t i = 0; i < a.size(); ++i)
      f += a[i] * stress_raw(s, std::min(d / h[i], lim), clamp_rho(s, rho[i]));
    return f;
  };
  const double f_max = total(d_max);
  if (force > f_max * (1.0 + kEdgeTol)) {
    out.refusal = refuse("beyond_data",
                         "a rigid press of " + fmt(force) + " N sinks past the tested strain "
                         "limit under this footprint (it carries " + fmt(f_max) + " N at " +
                             fmt(d_max) + " mm)");
    return out;
  }
  double lo = 0.0, hi = d_max;
  if (force >= f_max) {
    lo = hi = d_max;
  } else if (force > 0.0) {
    for (int it = 0; it < kBisectIterations && hi - lo > 1e-16 * hi; ++it) {
      const double mid = 0.5 * (lo + hi);
      if (total(mid) < force)
        lo = mid;
      else
        hi = mid;
    }
  } else {
    hi = 0.0;
  }
  out.ok = true;
  out.depth_mm = 0.5 * (lo + hi);
  for (std::size_t i = 0; i < a.size(); ++i) {
    out.strain.push_back(out.depth_mm / h[i]);
    if (out.strain.back() > s.strain_measured_max() + kEdgeTol) out.any_extrapolated = true;
  }
  return out;
}

TierBand tier_band(const ErrorBands& b, const std::string& set_tier, bool side_stack,
                   int beads_per_wall) {
  TierBand t;
  if (side_stack || beads_per_wall == 2) {
    t.tier = "estimated";
    t.band = b.proxy;
    t.why = side_stack
                ? "a side-loaded stack: every table was pushed along build Z, so sideways is "
                  "estimated until the sideways coupons (set SW) are measured"
                : "2-bead walls: the tables are single-bead, and at equal density 2-bead "
                  "gyroid differs (Justino Netto 2024), so this is estimated until set S";
    return t;
  }
  t.tier = set_tier;
  if (set_tier == "literature") {
    t.band = b.literature_same_material;
    t.why = "a published table for this filament, printed on another machine";
  } else if (set_tier == "calibrated") {
    t.band = b.calibrated;
    t.why = "measured on the maintainer's own printer and rig";
  } else if (set_tier == "proxy") {
    t.band = b.proxy;
    t.why = "another filament's table scaled to this one";
  } else {
    throw FlexibleError("tier_band: unknown tier \"" + set_tier + "\"");
  }
  return t;
}

double cell_size_mm(const std::string& topology, double rho, int beads, double bead_w) {
  if (!(rho > 0.0) || beads < 1 || !(bead_w > 0.0))
    throw FlexibleError("cell_size_mm: density, beads and bead width must be positive");
  const double t = beads * bead_w;
  if (topology == "gyroid") return 3.0915 * t / rho;
  if (topology == "honeycomb") return 2.0 * t / rho;
  throw FlexibleError("cell_size_mm: unknown topology \"" + topology + "\"");
}

}  // namespace flexible
}  // namespace topopt
