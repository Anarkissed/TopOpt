// lattice_material_model.hpp — HARNESS-SIDE lattice material model C(rho) for
// the multiscale-lattice-feasibility PROBE (2026-07-31-multiscale-lattice-
// feasibility). NOTHING here is production: this header is included only by
// core/tests/harness/lattice_material_probe.cpp, lattice_gap_probe.cpp and
// core/tests/unit/test_lattice_material_model.cpp. The production library
// (lattice.cpp / lattice_cubic_tensor) is linked UNMODIFIED and is the ground
// truth this model is verified against.
//
// WHAT THIS IS. SIMP penalises intermediate density because it is physically
// unrealisable; a lattice voxel at relative density rho IS realisable and has a
// MEASURED homogenized cubic tensor. This model replaces E(rho) = rho^p * E0
// with a tensor-valued curve C(rho) = (C11, C12, C44)(rho) over the FULL design
// range [0, 1], in three regimes:
//
//   void    rho in [0, rho_lo)   — cubic-Hermite bridge from the zero tensor
//                                  (value 0, slope 0 at rho = 0) to the fitted
//                                  tensor at the band floor, C1 at the joint.
//   lattice rho in [rho_lo, hi]  — an origin-anchored polynomial fit through the
//                                  MEASURED resolved rows of the production
//                                  tensor library: C(rho) = sum_k a_k rho^k,
//                                  k = 1..nterms, weighted least squares in
//                                  RELATIVE error (each row weighted 1/C_row).
//                                  nterms = 4 when >= 6 resolved rows, else 3.
//   solid   rho in (rho_hi, 1]   — quadratic bridge from the fitted tensor at
//                                  the band ceiling (matching value AND slope,
//                                  C1 at the joint) to the exact isotropic solid
//                                  triplet at rho = 1
//                                  (C11 = c(1-nu), C12 = c nu, C44 = E/2(1+nu),
//                                  c = E/((1+nu)(1-2nu)) — the triplet
//                                  hex8_stiffness_cubic reduces to isotropic).
//
// So the optimizer can REACH 0 and 1, the curve is C1 everywhere in (0, 1),
// and inside the certified band it carries the measured physics. The band
// endpoints are READ FROM CORE (lattice_rho_min/lattice_rho_max), never
// hardcoded. The row tables below are a transcription of lattice.cpp's tables;
// the unit test pins every row against lattice_cubic_tensor at the row's rho
// (interpolation weight 0 at an anchor -> the library returns the row exactly),
// so the transcription cannot drift from core.
//
// WHY origin-anchored polynomials: measured on the actual rows (see the
// handoff's G1 prototype table), a log-log polynomial needs degree >= 3 for
// comparable accuracy and cannot reach C = 0 at rho = 0; the origin-anchored
// form reaches 0 exactly, is C-infinity inside the band, and at 4 terms fits
// octet's 19 rows to <= 3.1% max row error with <= 5.1% leave-one-out error
// (C12 is the weakest component — reported per bar G1).

#ifndef TOPOPT_HARNESS_LATTICE_MATERIAL_MODEL_HPP
#define TOPOPT_HARNESS_LATTICE_MATERIAL_MODEL_HPP

#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <vector>

#include "topopt/lattice.hpp"

namespace lmm {

// One measured resolved row at the library's Es = 3500 MPa basis.
struct MRow {
  double rho;
  double C[3];  // C11, C12, C44 (MPa at Es = 3500)
};

// The RESOLVED rows of the production tensor library, transcribed from
// core/src/fea/lattice.cpp (kOctet and the nine-topology tables), Es = 3500
// basis. ONLY the rows inside the contiguous validated block (resolved == true)
// appear — those are the rows lattice_cubic_tensor interpolates and the band
// [lattice_rho_min, lattice_rho_max] spans. The unit test asserts each row
// reproduces lattice_cubic_tensor(topo, rho_row, 3500) exactly and that the
// first/last rho equal the core band endpoints, so a core table change breaks
// the test rather than silently skewing the fit.
inline std::vector<MRow> resolved_rows(topopt::LatticeTopology topo) {
  using T = topopt::LatticeTopology;
  switch (topo) {
    case T::Octet:
      return {{0.05047, {37.0649, 18.3510, 16.8552}},
              {0.06355, {48.3025, 23.7203, 21.6214}},
              {0.08109, {64.4784, 31.2998, 28.2686}},
              {0.09882, {81.7907, 39.2954, 35.2762}},
              {0.11908, {102.9136, 48.7092, 43.5388}},
              {0.14764, {136.9621, 64.0645, 56.6726}},
              {0.20414, {213.7779, 94.5363, 83.3612}},
              {0.25297, {295.1031, 124.0143, 109.1889}},
              {0.29731, {374.2029, 151.9733, 135.0535}},
              {0.39786, {611.4884, 226.3148, 204.0181}},
              {0.50644, {974.8665, 328.8413, 297.3223}},
              {0.59093, {1344.7034, 443.6894, 392.1883}},
              {0.61509, {1464.0552, 485.7181, 423.7420}},
              {0.65502, {1677.7877, 562.6095, 480.4917}},
              {0.69871, {1975.2811, 676.0779, 550.7189}},
              {0.75210, {2351.3476, 842.3622, 650.7516}},
              {0.79753, {2720.7120, 1018.8917, 743.9973}},
              {0.85120, {3276.6604, 1312.7907, 878.5398}},
              {0.89988, {3832.0119, 1640.8200, 1011.6316}}};
    case T::SimpleCubic:
      return {{0.08659, {124.1566, 7.4660, 2.6536}},
              {0.10749, {158.5235, 10.8871, 4.4241}},
              {0.15184, {234.9730, 19.8418, 9.6988}},
              {0.20095, {328.7364, 33.6360, 19.3835}},
              {0.30107, {549.8922, 75.8114, 54.8253}},
              {0.40271, {820.7973, 142.6197, 117.1334}},
              {0.49638, {1122.1090, 233.9830, 201.3808}}};
    case T::Bcc:
      return {{0.21050, {156.4198, 127.3111, 113.1794}},
              {0.30729, {288.2758, 205.7559, 182.7549}},
              {0.38932, {447.0414, 281.7155, 252.5690}},
              {0.50043, {754.6963, 399.8495, 361.9060}},
              {0.59288, {1125.8347, 522.3899, 470.7912}}};
    case T::Fcc:
      return {{0.09505, {79.1299, 38.1537, 34.1013}},
              {0.15524, {147.2712, 67.8645, 59.9030}},
              {0.19611, {205.2342, 90.3098, 79.2466}},
              {0.29731, {374.2029, 151.9733, 135.0535}},
              {0.40958, {645.8690, 235.1929, 212.4952}},
              {0.49732, {933.7064, 317.7636, 288.2518}},
              {0.59093, {1344.7034, 443.6894, 392.1883}}};
    case T::Diamond:
      return {{0.15712, {119.1238, 83.4693, 47.9097}},
              {0.21007, {185.0863, 118.3592, 84.1557}},
              {0.30671, {339.7180, 190.8679, 167.0811}},
              {0.38860, {522.8239, 268.4643, 256.3348}},
              {0.49971, {843.5858, 401.4833, 390.5869}},
              {0.59201, {1222.7132, 557.3286, 520.9273}}};
    case T::Kelvin:
      return {{0.09375, {69.5508, 44.6326, 8.7574}},
              {0.15191, {144.1969, 73.4013, 23.9669}},
              {0.20660, {234.3606, 102.4685, 45.4661}},
              {0.30469, {470.5138, 159.9250, 104.8460}},
              {0.39149, {734.2983, 229.6667, 177.5998}},
              {0.50521, {1157.2768, 376.2459, 314.8977}}};
    case T::Rhombic:
      return {{0.17245, {134.1116, 100.7815, 40.7273}},
              {0.28299, {299.5816, 184.9281, 115.2281}},
              {0.39236, {556.9667, 290.3696, 223.0394}},
              {0.51331, {998.3655, 448.7741, 377.5713}}};
    default:
      return {};  // tetragonal / not certifiable — no rows, no model
  }
}

// The library's measurement basis modulus (lattice.cpp kLibraryEs).
constexpr double kLibraryEs = 3500.0;

// C(rho) = sum_{k=1..nterms} a[k-1] * rho^k  — anchored at C(0) = 0 exactly.
constexpr int kMaxTerms = 4;
struct PolyFit {
  int nterms = 0;
  double a[kMaxTerms] = {0, 0, 0, 0};
};

inline double poly_eval(const PolyFit& p, double rho) {
  double v = 0.0, rk = rho;
  for (int k = 0; k < p.nterms; ++k) {
    v += p.a[k] * rk;
    rk *= rho;
  }
  return v;
}
inline double poly_deriv(const PolyFit& p, double rho) {
  double v = 0.0, rk = 1.0;
  for (int k = 0; k < p.nterms; ++k) {
    v += (k + 1) * p.a[k] * rk;
    rk *= rho;
  }
  return v;
}

// Weighted least squares of the origin-anchored polynomial through (rho_i, C_i)
// minimising sum_i ( P(rho_i)/C_i - 1 )^2 (relative error, so a 40 MPa row
// counts as much as a 3800 MPa row). Normal equations solved by Gaussian
// elimination with partial pivoting (nterms <= 4, condition is benign on
// rho in [0.05, 0.9]). Throws std::invalid_argument if rows < nterms.
inline PolyFit fit_origin_poly(const std::vector<double>& rho,
                               const std::vector<double>& c, int nterms) {
  const std::size_t n = rho.size();
  if (n < static_cast<std::size_t>(nterms) || c.size() != n)
    throw std::invalid_argument("fit_origin_poly: too few rows for nterms");
  double ata[kMaxTerms][kMaxTerms] = {};
  double atb[kMaxTerms] = {};
  for (std::size_t i = 0; i < n; ++i) {
    double col[kMaxTerms];
    double rk = rho[i];
    for (int k = 0; k < nterms; ++k) {
      col[k] = rk / c[i];
      rk *= rho[i];
    }
    for (int r = 0; r < nterms; ++r) {
      for (int s = 0; s < nterms; ++s) ata[r][s] += col[r] * col[s];
      atb[r] += col[r];  // target is 1 for every row
    }
  }
  // Gaussian elimination, partial pivot.
  int idx[kMaxTerms] = {0, 1, 2, 3};
  for (int p = 0; p < nterms; ++p) {
    int best = p;
    for (int r = p + 1; r < nterms; ++r)
      if (std::fabs(ata[idx[r]][p]) > std::fabs(ata[idx[best]][p])) best = r;
    std::swap(idx[p], idx[best]);
    const double piv = ata[idx[p]][p];
    if (piv == 0.0) throw std::invalid_argument("fit_origin_poly: singular system");
    for (int r = p + 1; r < nterms; ++r) {
      const double f = ata[idx[r]][p] / piv;
      for (int s = p; s < nterms; ++s) ata[idx[r]][s] -= f * ata[idx[p]][s];
      atb[idx[r]] -= f * atb[idx[p]];
    }
  }
  PolyFit out;
  out.nterms = nterms;
  for (int p = nterms - 1; p >= 0; --p) {
    double v = atb[idx[p]];
    for (int s = p + 1; s < nterms; ++s) v -= ata[idx[p]][s] * out.a[s];
    out.a[p] = v / ata[idx[p]][p];
  }
  return out;
}

// The fixed model-order rule (stated BEFORE measuring, bar G1/G4): 4 terms when
// the topology has at least 6 resolved rows, else 3. Deterministic — no
// per-component selection on the held-out numbers.
inline int model_order(std::size_t resolved_row_count) {
  return resolved_row_count >= 6 ? 4 : 3;
}

// The three-regime tensor-valued material curve. Built per topology by
// build_lattice_material_model below; evaluate with value() / derivative().
struct LatticeMaterialModel {
  topopt::LatticeTopology topo{};
  double Es = 0.0, nu = 0.0;
  double scale = 1.0;             // Es / kLibraryEs applied to the fitted rows
  double rho_lo = 0.0, rho_hi = 0.0;  // band endpoints READ FROM CORE
  PolyFit fit[3];                 // C11, C12, C44 fits (library-basis MPa)
  double solid[3] = {0, 0, 0};    // exact isotropic triplet at rho = 1 (at Es)
  // cached joint values/slopes AT Es scale (bridge coefficients)
  double v_lo[3] = {0, 0, 0}, d_lo[3] = {0, 0, 0};
  double v_hi[3] = {0, 0, 0}, d_hi[3] = {0, 0, 0};

  topopt::CubicTensor value(double rho) const {
    topopt::CubicTensor t;
    double c[3];
    eval_components(rho, c, nullptr);
    t.C11 = c[0]; t.C12 = c[1]; t.C44 = c[2];
    return t;
  }
  topopt::CubicTensor derivative(double rho) const {
    topopt::CubicTensor t;
    double d[3];
    eval_components(rho, nullptr, d);
    t.C11 = d[0]; t.C12 = d[1]; t.C44 = d[2];
    return t;
  }

  // One evaluation of all three components (and/or their rho-derivatives).
  void eval_components(double rho, double* c, double* d) const {
    if (!(std::isfinite(rho)))
      throw std::invalid_argument("LatticeMaterialModel: rho must be finite");
    if (rho <= 0.0) {
      for (int i = 0; i < 3; ++i) {
        if (c) c[i] = 0.0;
        if (d) d[i] = 0.0;  // bridge slope at 0 is 0 by construction
      }
      return;
    }
    if (rho >= 1.0) {
      for (int i = 0; i < 3; ++i) {
        if (c) c[i] = solid[i];
        if (d) d[i] = upper_slope_at_1(i);
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
        if (d)
          d[i] = (v * (6 * t - 6 * t * t) + s * (3 * t * t - 2 * t)) / rho_lo;
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
    // Upper bridge: quadratic on [rho_hi, 1] matching value AND slope at the
    // band ceiling (C1 joint) and the exact solid triplet at rho = 1.
    const double L = 1.0 - rho_hi;
    const double t = (rho - rho_hi) / L;
    for (int i = 0; i < 3; ++i) {
      const double v = v_hi[i], s = d_hi[i] * L;
      const double q2 = solid[i] - v - s;  // t^2 coefficient
      if (c) c[i] = v + s * t + q2 * t * t;
      if (d) d[i] = (s + 2 * q2 * t) / L;
    }
  }

  double upper_slope_at_1(int i) const {
    const double L = 1.0 - rho_hi;
    const double s = d_hi[i] * L;
    return (s + 2 * (solid[i] - v_hi[i] - s)) / L;
  }
};

// Build the model for one certifiable topology at solid modulus Es / Poisson nu.
// Band endpoints come from lattice_rho_min/lattice_rho_max (CORE, not this
// header); the fit runs over resolved_rows() scaled by Es/3500 exactly like
// lattice_cubic_tensor scales its rows. Throws std::invalid_argument for a
// topology with no rows (tetragonal / not certifiable) or a non-physical Es/nu.
inline LatticeMaterialModel build_lattice_material_model(
    topopt::LatticeTopology topo, double Es, double nu) {
  if (!(Es > 0.0) || !(nu > -1.0 && nu < 0.5))
    throw std::invalid_argument("build_lattice_material_model: bad Es/nu");
  const std::vector<MRow> rows = resolved_rows(topo);
  if (rows.empty())
    throw std::invalid_argument(
        "build_lattice_material_model: topology has no validated cubic rows");
  LatticeMaterialModel m;
  m.topo = topo;
  m.Es = Es;
  m.nu = nu;
  m.scale = Es / kLibraryEs;
  m.rho_lo = topopt::lattice_rho_min(topo);
  m.rho_hi = topopt::lattice_rho_max(topo);
  const double c = Es / ((1 + nu) * (1 - 2 * nu));
  m.solid[0] = c * (1 - nu);
  m.solid[1] = c * nu;
  m.solid[2] = Es / (2 * (1 + nu));
  std::vector<double> r(rows.size());
  for (std::size_t i = 0; i < rows.size(); ++i) r[i] = rows[i].rho;
  const int nterms = model_order(rows.size());
  for (int comp = 0; comp < 3; ++comp) {
    std::vector<double> cv(rows.size());
    for (std::size_t i = 0; i < rows.size(); ++i) cv[i] = rows[i].C[comp];
    m.fit[comp] = fit_origin_poly(r, cv, nterms);
    m.v_lo[comp] = m.scale * poly_eval(m.fit[comp], m.rho_lo);
    m.d_lo[comp] = m.scale * poly_deriv(m.fit[comp], m.rho_lo);
    m.v_hi[comp] = m.scale * poly_eval(m.fit[comp], m.rho_hi);
    m.d_hi[comp] = m.scale * poly_deriv(m.fit[comp], m.rho_hi);
  }
  return m;
}

// The certifiable topologies, in enum order (the set carrying resolved rows).
inline std::vector<topopt::LatticeTopology> certifiable_topologies() {
  using T = topopt::LatticeTopology;
  return {T::Octet, T::SimpleCubic, T::Bcc, T::Fcc,
          T::Diamond, T::Kelvin, T::Rhombic};
}

}  // namespace lmm

#endif  // TOPOPT_HARNESS_LATTICE_MATERIAL_MODEL_HPP
