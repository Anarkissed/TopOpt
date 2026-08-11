// plsm_filter.hpp — ★ THE RESTRICTION OPERATOR. A HELMHOLTZ (PDE) DENSITY
// FILTER, AND THE PROJECTION THAT GOES WITH IT.
//
// ═══ WHY THIS EXISTS, AND WHY THE THREE THINGS BEFORE IT FAILED ═════════════
//
// PR 326 concluded that the excess surface and the seed-free capability were
// "the same mechanism", because hole nucleation causes both. ★ THAT IS WRONG,
// AND SIMP IS THE COUNTEREXAMPLE: SIMP's density can fall anywhere in the
// domain, so it nucleates freely and needs no seed either — and it does not
// produce three times SIMP's surface, because SIMP has a DENSITY FILTER. The
// capability and the smoothness are separable. What was missing was not a
// restriction on nucleation; it was a restriction operator on the FIELD.
//
// Three things were tried in PR 326 and none of them was a filter:
//
//   * a COARSER RBF BASIS restricted the REPRESENTATION — margin halved, peak
//     von Mises doubled (PR 324 §6(ii));
//   * a NARROW-BAND MASK restricted WHICH COEFFICIENTS MAY MOVE — 1.6% fewer
//     triangles, because it arrives after the branching it was meant to stop;
//   * the PERIMETER PENALTY is a GLOBAL SCALAR TAX — it works, and it trades
//     monotonically against strength until C=8 collapses the margin.
//
// ★★ A FILTER IS NONE OF THESE. It is applied EVERY ITERATION TO THE ERSATZ
// DENSITY THE PHYSICS SEES, so a sub-radius feature does not disappear because
// it is forbidden or taxed — it disappears because, once smeared over a radius
// r, it no longer carries the stiffness it costs. It becomes UNECONOMIC.
//
// ★ AND THE CHAIN MUST BE FILTER **THEN PROJECT**, NOT FILTER ALONE. A filtered
// density is grey, and a grey field is not a part: `analyze_fixed_design` reads
// the field this program writes, and PR 324 §5 already paid for shipping a
// roughness number measured on a field that does not certify. The composition
// here is the standard density-method one, with the ersatz standing in for the
// raw design variable:
//
//     phi  ->  rho_raw = H_eta(-phi)      the ersatz, unchanged
//          ->  rho_til = F rho_raw        THIS FILE, the restriction operator
//          ->  rho_phy = P_beta(rho_til)  THIS FILE, back to a part
//
// ── WHERE THE TRANSPLANT COMES FROM ────────────────────────────────────────
//
// Andreasen, Elingaard & Aage (2020), Struct Multidisc Optim 62(2):685-707, put
// exactly this on a level set — "the same design field representation, the same
// projection filters, the same optimizer, and the same so-called robust
// approach as used in density-based optimization for length scale control".
// Aage, Giele & Andreasen (2021), SMO 64(3):1127-1139, run it past 62 MILLION
// hexahedra with a multigrid-preconditioned Krylov solver — the same solver
// family this repository uses, at a hundred times the element count — and
// report length scale controlled "without the need for beta-continuation",
// which is why `beta` below is a fixed number and not a schedule.
//
// Lu et al., Acta Mechanica Sinica (2024) apply a Helmholtz filter directly to
// a PARAMETERISED level set to "regulate the topological complexity and the
// minimum feature size", and note it needs only mesh information — no
// neighbour-list convolution. That is the property that matters in a
// matrix-free pipeline: the filter below never builds a stencil list.
//
// ── THE PDE, AND WHY IT IS CHEAP HERE ──────────────────────────────────────
//
//     (I - r^2 grad^2) rho_til = rho_raw,     grad(rho_til).n = 0 on the box
//
// ★ ONE SCALAR UNKNOWN PER VOXEL against elasticity's THREE PER NODE, on a
// 7-point stencil, solved by Jacobi-preconditioned CG. PR 324 measured 99.5% of
// an iteration as the state solve; this is a rounding error beside it, and its
// cost is reported separately so that claim is a number and not a hope.
//
// ★ R5 — PER AXIS, NEVER A MINIMUM. The radius is three numbers, `rx, ry, rz`,
// in VOXELS. On this 128 x 31 x 118 slab a single radius derived from a minimum
// over the axes is the trap that cost PR 324 a day, and nothing here takes a
// minimum. An isotropic radius is the special case rx = ry = rz.
//
// ★ SELF-ADJOINT, WHICH IS THE ONE PROPERTY THE SENSITIVITY DEPENDS ON.
// (I - r^2 grad^2) with Neumann data is symmetric, so F^T = F and the adjoint
// of the filter is the SAME SOLVE. The chain rule therefore filters the
// sensitivity with `apply` exactly as the forward pass filters the density —
// no transpose operator exists or is needed, and getting this wrong would be
// invisible in the objective and fatal in the design.

#ifndef TOPOPT_TESTS_HARNESS_PLSM_FILTER_HPP_
#define TOPOPT_TESTS_HARNESS_PLSM_FILTER_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

// The Helmholtz filter as an operator on a scalar voxel field.
//
// Lengths are in VOXELS; the PDE is solved on the unit-spacing lattice, which
// is exact because the grid is isotropic in spacing (h = 1.705279 mm on all
// three axes here) and the radius is expressed in the same units.
struct HelmholtzFilter {
  Dims d;
  double rx = 0.0, ry = 0.0, rz = 0.0;   // VOXELS, per axis (R5)
  int max_iters = 400;
  double tol = 1e-10;
  // Reported so the "it is a rounding error beside the state solve" claim is a
  // measurement. Accumulated across every apply.
  mutable double wall_s = 0.0;
  mutable long long applies = 0;
  mutable long long cg_iters = 0;

  bool active() const { return rx > 0.0 || ry > 0.0 || rz > 0.0; }

  // y <- (I - r^2 grad^2) x, with homogeneous NEUMANN data implemented by
  // reflecting the stencil at the box face (a missing neighbour contributes
  // nothing, which is the zero-flux condition).
  void op(const std::vector<double>& x, std::vector<double>& y) const {
    const double ax = rx * rx, ay = ry * ry, az = rz * rz;
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t v = d.at(i, j, k);
          double diag = 1.0, acc = 0.0;
          if (i > 0)          { acc += ax * x[d.at(i - 1, j, k)]; diag += ax; }
          if (i + 1 < d.nx)   { acc += ax * x[d.at(i + 1, j, k)]; diag += ax; }
          if (j > 0)          { acc += ay * x[d.at(i, j - 1, k)]; diag += ay; }
          if (j + 1 < d.ny)   { acc += ay * x[d.at(i, j + 1, k)]; diag += ay; }
          if (k > 0)          { acc += az * x[d.at(i, j, k - 1)]; diag += az; }
          if (k + 1 < d.nz)   { acc += az * x[d.at(i, j, k + 1)]; diag += az; }
          y[v] = diag * x[v] - acc;
        }
  }

  // The diagonal of the operator above, for the Jacobi preconditioner. It is
  // position-dependent because the Neumann reflection drops terms at the faces.
  void diagonal(std::vector<double>& dg) const {
    const double ax = rx * rx, ay = ry * ry, az = rz * rz;
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          double x = 1.0;
          if (i > 0) x += ax;
          if (i + 1 < d.nx) x += ax;
          if (j > 0) x += ay;
          if (j + 1 < d.ny) x += ay;
          if (k > 0) x += az;
          if (k + 1 < d.nz) x += az;
          dg[d.at(i, j, k)] = x;
        }
  }

  // ★ THE FILTER, AND ITS OWN ADJOINT. `out` may alias nothing; `in` is not
  // modified. Jacobi-preconditioned CG, warm-started from `in` itself, which is
  // a good guess because the filter is close to the identity for small r.
  void apply(const std::vector<double>& in, std::vector<double>& out) const {
    const std::size_t n = in.size();
    out.assign(n, 0.0);
    if (!active()) { out = in; return; }
    const double t0 = now_s();
    std::vector<double> dg(n, 1.0), r(n), z(n), p(n), Ap(n);
    diagonal(dg);
    out = in;                       // warm start
    op(out, Ap);
    for (std::size_t v = 0; v < n; ++v) r[v] = in[v] - Ap[v];
    for (std::size_t v = 0; v < n; ++v) z[v] = r[v] / dg[v];
    p = z;
    double rz = 0.0, bn = 0.0;
    for (std::size_t v = 0; v < n; ++v) { rz += r[v] * z[v]; bn += in[v] * in[v]; }
    bn = std::sqrt(bn);
    const double target = tol * (bn > 0.0 ? bn : 1.0);
    int it = 0;
    for (; it < max_iters; ++it) {
      double rn = 0.0;
      for (std::size_t v = 0; v < n; ++v) rn += r[v] * r[v];
      if (std::sqrt(rn) <= target) break;
      op(p, Ap);
      double pAp = 0.0;
      for (std::size_t v = 0; v < n; ++v) pAp += p[v] * Ap[v];
      if (!(pAp > 0.0)) break;
      const double al = rz / pAp;
      for (std::size_t v = 0; v < n; ++v) { out[v] += al * p[v]; r[v] -= al * Ap[v]; }
      for (std::size_t v = 0; v < n; ++v) z[v] = r[v] / dg[v];
      double rz1 = 0.0;
      for (std::size_t v = 0; v < n; ++v) rz1 += r[v] * z[v];
      const double be = rz1 / rz;
      rz = rz1;
      for (std::size_t v = 0; v < n; ++v) p[v] = z[v] + be * p[v];
    }
    wall_s += now_s() - t0;
    ++applies;
    cg_iters += it;
  }
};

// ── THE PROJECTION ─────────────────────────────────────────────────────────
//
// The smoothed Heaviside of Wang, Lazarov & Sigmund (2011), which is the one
// the robust formulation is written against:
//
//     P(x) = [tanh(beta*eta) + tanh(beta*(x - eta))]
//            / [tanh(beta*eta) + tanh(beta*(1 - eta))]
//
// `eta_p` is the THRESHOLD, and it is what makes the same filtered field into
// an ERODED (eta_p > 0.5), INTERMEDIATE (0.5) or DILATED (eta_p < 0.5) design —
// Candidate B is exactly three values of this one number.
inline double project(double x, double beta, double eta_p) {
  if (!(beta > 0.0)) return x;
  const double a = std::tanh(beta * eta_p);
  const double num = a + std::tanh(beta * (x - eta_p));
  const double den = a + std::tanh(beta * (1.0 - eta_p));
  return den != 0.0 ? num / den : x;
}

// dP/dx, which the chain rule needs between the physics and the filter.
inline double project_d(double x, double beta, double eta_p) {
  if (!(beta > 0.0)) return 1.0;
  const double s = std::cosh(beta * (x - eta_p));
  const double den = std::tanh(beta * eta_p) + std::tanh(beta * (1.0 - eta_p));
  return den != 0.0 ? beta / (s * s * den) : 1.0;
}

#endif  // TOPOPT_TESTS_HARNESS_PLSM_FILTER_HPP_
