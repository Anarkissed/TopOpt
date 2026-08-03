#include "topopt/lattice_material.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <utility>

namespace topopt {
namespace {

double poly_eval(const LatticePolyFit& p, double rho) {
  double v = 0.0, rk = rho;
  for (int k = 0; k < p.nterms; ++k) {
    v += p.a[k] * rk;
    rk *= rho;
  }
  return v;
}

double poly_deriv(const LatticePolyFit& p, double rho) {
  double v = 0.0, rk = 1.0;
  for (int k = 0; k < p.nterms; ++k) {
    v += (k + 1) * p.a[k] * rk;
    rk *= rho;
  }
  return v;
}

// Weighted least squares of the origin-anchored polynomial through (rho_i, C_i),
// minimising sum_i ( P(rho_i)/C_i - 1 )^2 — RELATIVE error, so a 40 MPa row counts
// as much as a 3800 MPa row. Normal equations by Gaussian elimination with partial
// pivoting (nterms <= 4; the system is benign on rho in [0.05, 0.9]).
LatticePolyFit fit_origin_poly(const std::vector<double>& rho,
                               const std::vector<double>& c, int nterms) {
  const std::size_t n = rho.size();
  if (n < static_cast<std::size_t>(nterms) || c.size() != n)
    throw std::invalid_argument(
        "build_lattice_material_model: too few resolved rows for the model order");
  double ata[kLatticeFitMaxTerms][kLatticeFitMaxTerms] = {};
  double atb[kLatticeFitMaxTerms] = {};
  for (std::size_t i = 0; i < n; ++i) {
    if (!(c[i] > 0.0))
      throw std::invalid_argument(
          "build_lattice_material_model: a measured row has a non-positive modulus");
    double col[kLatticeFitMaxTerms];
    double rk = rho[i];
    for (int k = 0; k < nterms; ++k) {
      col[k] = rk / c[i];
      rk *= rho[i];
    }
    for (int r = 0; r < nterms; ++r) {
      for (int s = 0; s < nterms; ++s) ata[r][s] += col[r] * col[s];
      atb[r] += col[r];  // the target is 1 for every row
    }
  }
  int idx[kLatticeFitMaxTerms] = {0, 1, 2, 3};
  for (int p = 0; p < nterms; ++p) {
    int best = p;
    for (int r = p + 1; r < nterms; ++r)
      if (std::fabs(ata[idx[r]][p]) > std::fabs(ata[idx[best]][p])) best = r;
    std::swap(idx[p], idx[best]);
    const double piv = ata[idx[p]][p];
    if (piv == 0.0)
      throw std::invalid_argument(
          "build_lattice_material_model: singular normal equations");
    for (int r = p + 1; r < nterms; ++r) {
      const double f = ata[idx[r]][p] / piv;
      for (int s = p; s < nterms; ++s) ata[idx[r]][s] -= f * ata[idx[p]][s];
      atb[idx[r]] -= f * atb[idx[p]];
    }
  }
  LatticePolyFit out;
  out.nterms = nterms;
  for (int p = nterms - 1; p >= 0; --p) {
    double v = atb[idx[p]];
    for (int s = p + 1; s < nterms; ++s) v -= ata[idx[p]][s] * out.a[s];
    out.a[p] = v / ata[idx[p]][p];
  }
  return out;
}

// The FIXED model-order rule, stated before measuring (probe bar G1/G4): 4 terms
// when the topology has at least 6 resolved rows, else 3. Deterministic — never
// selected per component on held-out numbers.
int model_order(std::size_t resolved_row_count) {
  return resolved_row_count >= 6 ? 4 : 3;
}

}  // namespace

void LatticeMaterialModel::eval(double rho, double* c, double* d) const {
  if (!std::isfinite(rho))
    throw std::invalid_argument("LatticeMaterialModel: rho must be finite");
  if (c == nullptr && d == nullptr) return;
  if (rho <= 0.0) {
    for (int i = 0; i < 3; ++i) {
      if (c) c[i] = 0.0;
      if (d) d[i] = 0.0;  // the lower bridge's slope at 0 is 0 by construction
    }
    return;
  }
  if (rho >= 1.0) {
    const double L = 1.0 - rho_hi;
    for (int i = 0; i < 3; ++i) {
      if (c) c[i] = solid[i];
      if (d) {
        const double s = d_hi[i] * L;
        d[i] = (s + 2 * (solid[i] - v_hi[i] - s)) / L;
      }
    }
    return;
  }
  if (rho < rho_lo) {
    // Lower bridge: cubic Hermite on [0, rho_lo] with h(0) = 0, h'(0) = 0,
    // h(rho_lo) = v_lo, h'(rho_lo) = d_lo. C1 at the joint by construction.
    const double t = rho / rho_lo;
    for (int i = 0; i < 3; ++i) {
      const double v = v_lo[i], s = rho_lo * d_lo[i];
      if (c) c[i] = v * (3 * t * t - 2 * t * t * t) + s * (t * t * t - t * t);
      if (d) d[i] = (v * (6 * t - 6 * t * t) + s * (3 * t * t - 2 * t)) / rho_lo;
    }
    return;
  }
  if (rho <= rho_hi) {
    for (int i = 0; i < 3; ++i) {
      if (c) c[i] = scale * poly_eval(fit[i], rho);
      if (d) d[i] = scale * poly_deriv(fit[i], rho);
    }
    return;
  }
  // Upper bridge: quadratic on [rho_hi, 1] matching value AND slope at the band
  // ceiling (C1 joint) and the exact solid triplet at rho = 1.
  const double L = 1.0 - rho_hi;
  const double t = (rho - rho_hi) / L;
  for (int i = 0; i < 3; ++i) {
    const double v = v_hi[i], s = d_hi[i] * L;
    const double q2 = solid[i] - v - s;  // t^2 coefficient
    if (c) c[i] = v + s * t + q2 * t * t;
    if (d) d[i] = (s + 2 * q2 * t) / L;
  }
}

CubicTensor LatticeMaterialModel::value(double rho) const {
  double c[3];
  eval(rho, c, nullptr);
  CubicTensor t;
  t.C11 = c[0];
  t.C12 = c[1];
  t.C44 = c[2];
  return t;
}

CubicTensor LatticeMaterialModel::derivative(double rho) const {
  double d[3];
  eval(rho, nullptr, d);
  CubicTensor t;
  t.C11 = d[0];
  t.C12 = d[1];
  t.C44 = d[2];
  return t;
}

LatticeMaterialModel build_lattice_material_model(LatticeTopology topo, double Es,
                                                  double nu) {
  if (!(Es > 0.0) || !(nu > -1.0 && nu < 0.5))
    throw std::invalid_argument(
        "build_lattice_material_model: Es must be > 0 and nu in (-1, 0.5)");
  const std::vector<LatticeResolvedRow> rows = lattice_resolved_rows(topo);
  if (rows.empty())
    throw LatticeTopologyNotCertifiable(
        std::string("build_lattice_material_model: topology '") +
        lattice_topology_name(topo) +
        "' carries no validated cubic rows — there is nothing to fit (the same "
        "refusal lattice_cubic_tensor gives)");

  LatticeMaterialModel m;
  m.topo = topo;
  m.Es = Es;
  m.nu = nu;
  m.scale = Es / lattice_library_youngs_modulus();
  m.rho_lo = lattice_rho_min(topo);
  m.rho_hi = lattice_rho_max(topo);
  m.rows = rows.size();
  // The exact isotropic triplet at rho = 1 — what hex8_stiffness_cubic reduces to.
  const double c = Es / ((1 + nu) * (1 - 2 * nu));
  m.solid[0] = c * (1 - nu);
  m.solid[1] = c * nu;
  m.solid[2] = Es / (2 * (1 + nu));

  std::vector<double> r(rows.size());
  for (std::size_t i = 0; i < rows.size(); ++i) r[i] = rows[i].rho;
  const int nterms = model_order(rows.size());
  for (int comp = 0; comp < 3; ++comp) {
    std::vector<double> cv(rows.size());
    for (std::size_t i = 0; i < rows.size(); ++i)
      cv[i] = comp == 0 ? rows[i].C11 : (comp == 1 ? rows[i].C12 : rows[i].C44);
    m.fit[comp] = fit_origin_poly(r, cv, nterms);
    m.v_lo[comp] = m.scale * poly_eval(m.fit[comp], m.rho_lo);
    m.d_lo[comp] = m.scale * poly_deriv(m.fit[comp], m.rho_lo);
    m.v_hi[comp] = m.scale * poly_eval(m.fit[comp], m.rho_hi);
    m.d_hi[comp] = m.scale * poly_deriv(m.fit[comp], m.rho_hi);
  }
  return m;
}

bool lattice_material_model_trustworthy(LatticeTopology topo, std::string* reason) {
  if (reason) reason->clear();
  const std::vector<LatticeResolvedRow> rows = lattice_resolved_rows(topo);
  if (rows.empty()) {
    if (reason)
      *reason = std::string("topology '") + lattice_topology_name(topo) +
                "' carries no validated cubic rows (tetragonal or unmeasured)";
    return false;
  }
  // THE TWO BARS the probe measured (handoff 2026-07-31-multiscale-lattice-
  // feasibility, G4 and G4b), applied as stated rather than re-derived:
  //  * the UPPER GAP (1 - rho_hi) must be narrow enough that a design pushing a
  //    stress concentration toward solid does not cross a wide unmeasured stretch.
  //    Octet's is 0.100 with a 1.36x C11 jump; the six analysis-only topologies sit
  //    at 0.407-0.504 with 3.9-5.2x jumps. The cut is placed at 0.15 — comfortably
  //    above octet's, far below every other topology's, and NOT a value any
  //    topology sits near (the nearest is 2.7x away), so it is not a knife edge.
  //  * the MODEL-ORDER CLIFF: at <= 5 resolved rows the fixed rule drops to 3 terms
  //    and the C12 derivative reaches ~35% error against the 19-row fit. Six rows is
  //    the first count that carries the 4-term fit.
  constexpr double kMaxUpperGap = 0.15;
  constexpr std::size_t kMinRowsForLoop = 6;
  const double upper_gap = 1.0 - lattice_rho_max(topo);
  if (rows.size() < kMinRowsForLoop) {
    if (reason)
      *reason = std::string("topology '") + lattice_topology_name(topo) +
                "' has only " + std::to_string(rows.size()) +
                " resolved rows, below the 6-row model-order cliff where the "
                "fitted C12 derivative reaches ~35% error — an optimizer would "
                "steer on a fiction";
    return false;
  }
  if (upper_gap > kMaxUpperGap) {
    if (reason) {
      char buf[320];
      std::snprintf(buf, sizeof(buf),
                    "topology '%s' has an upper gap of %.3f (band ceiling %.3f); "
                    "above %.2f the stretch from the last measured row to solid is "
                    "pure interpolation across a large stiffness swing, too wide to "
                    "steer a design loop across — it needs measured rows above ~0.6",
                    lattice_topology_name(topo), upper_gap, lattice_rho_max(topo),
                    kMaxUpperGap);
      *reason = buf;
    }
    return false;
  }
  return true;
}

double multiscale_printed_iso(LatticeTopology topo) {
  const double lo = lattice_rho_min(topo);
  if (!(lo > 0.0))
    throw LatticeTopologyNotCertifiable(
        std::string("multiscale_printed_iso: topology '") +
        lattice_topology_name(topo) + "' has no certified band");
  return 0.5 * lo;
}

LatticeDensityClass lattice_density_class(const LatticeMaterialModel& m, double rho,
                                          double void_below, double solid_above) {
  if (rho <= void_below) return LatticeDensityClass::Void;
  if (rho >= solid_above) return LatticeDensityClass::Solid;
  if (rho >= m.rho_lo && rho <= m.rho_hi) return LatticeDensityClass::Band;
  return rho < m.rho_lo ? LatticeDensityClass::LowerGap
                        : LatticeDensityClass::UpperGap;
}

double lattice_project_density(const LatticeMaterialModel& m, double rho,
                               double void_below, double solid_above) {
  switch (lattice_density_class(m, rho, void_below, solid_above)) {
    case LatticeDensityClass::Void:
      return 0.0;
    case LatticeDensityClass::Solid:
      return 1.0;
    case LatticeDensityClass::Band:
      return rho;
    case LatticeDensityClass::LowerGap:
      // Nearest of {0, rho_lo}. A tie (exactly mid-gap) goes DOWN — the lighter
      // choice, and deterministic, so a rerun snaps identically.
      return (rho - 0.0) <= (m.rho_lo - rho) ? 0.0 : m.rho_lo;
    case LatticeDensityClass::UpperGap:
      return (rho - m.rho_hi) <= (1.0 - rho) ? m.rho_hi : 1.0;
  }
  return rho;
}

LatticeProjectionReport lattice_project_field(const LatticeMaterialModel& m,
                                              std::vector<double>& density,
                                              const std::vector<char>* mask,
                                              double void_below, double solid_above,
                                              double n_counted,
                                              double target_fraction) {
  if (mask != nullptr && mask->size() != density.size())
    throw std::invalid_argument("lattice_project_field: mask size != density size");
  LatticeProjectionReport rep;
  for (std::size_t e = 0; e < density.size(); ++e) {
    if (mask != nullptr && (*mask)[e] == 0) continue;
    ++rep.voxels_considered;
    const double before = density[e];
    rep.volume_before += before;
    const LatticeDensityClass cls =
        lattice_density_class(m, before, void_below, solid_above);
    const double after = lattice_project_density(m, before, void_below, solid_above);
    rep.volume_after += after;
    if (after != before) {
      if (cls == LatticeDensityClass::LowerGap) ++rep.projected_lower;
      if (cls == LatticeDensityClass::UpperGap) ++rep.projected_upper;
      if (after == 0.0) ++rep.snapped_to_void;
      else if (after == 1.0) ++rep.snapped_to_solid;
      else if (after == m.rho_lo) ++rep.snapped_to_band_lo;
      else if (after == m.rho_hi) ++rep.snapped_to_band_hi;
      rep.max_density_move = std::max(rep.max_density_move, std::fabs(after - before));
      density[e] = after;
    }
  }
  rep.volume_delta = rep.volume_after - rep.volume_before;
  const double n = n_counted > 0.0 ? n_counted
                                   : static_cast<double>(rep.voxels_considered);
  if (n > 0.0) {
    rep.volume_fraction_before = rep.volume_before / n;
    rep.volume_fraction_after = rep.volume_after / n;
  }
  if (target_fraction > 0.0) {
    rep.volume_fraction_target = target_fraction;
    // THE CHARGE, stated as a fraction of the target the optimizer was held to.
    // The volume constraint was satisfied by the optimizer and then BROKEN by the
    // projection; this is how much, signed, and it is reported, never absorbed.
    rep.volume_constraint_violation =
        (rep.volume_fraction_after - target_fraction) / target_fraction;
  }
  return rep;
}

}  // namespace topopt
