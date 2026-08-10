// plsm_mma.hpp — ONE MMA DESIGN UPDATE IN RBF-COEFFICIENT SPACE, for ARM 2 of
// task 2026-08-10-parametric-level-set.
//
// ★ WHY THIS FILE EXISTS AT ALL, STATED PLAINLY. The task says "drive alpha with
// MMA — the production optimiser, not a hand-rolled step." Core HAS an MMA:
// `mma_update` in `core/src/simp/simp.cpp`. It cannot be called here, and the
// reason is structural rather than a matter of visibility:
//
//   std::vector<double> mma_update(MmaState&, int, const VoxelGrid&,
//                                  const DensityFilter&, const std::vector<double>&,
//                                  const std::vector<double>&, double, double,
//                                  double);
//
// It takes a `VoxelGrid` and a `DensityFilter`, enumerates its design set with
// `grid.solid(i,j,k)`, filters both sensitivities through H, and bounds the
// design to [density_min, 1]. Every one of those is a statement about VOXEL
// DENSITIES. An RBF coefficient is not a density, has no voxel, is not filtered,
// and is not bounded by 1 — it is signed and scaled like a distance in mm. There
// is no argument list that makes that call.
//
// ★ SO THIS IS A TRANSCRIPTION, NOT A NEW ALGORITHM, AND IT IS SAID OUT LOUD.
// Every step below is `mma_update`'s step, in its order, with ITS constants —
// asyinit 0.5, asyincr 1.2, asydecr 0.7, albefa 0.1, raa0 1e-5, the 1.001/0.001
// split, the closed-form primal minimiser and the bisection on the dual for the
// single volume constraint. What changed is the DESIGN SET and nothing else:
//
//   voxel densities x_e in [rho_min, 1]   ->   coefficients beta_i in [lo, hi]
//   sensitivities filtered through H      ->   sensitivities already in
//                                              coefficient space by Psi^T
//   design set = grid.solid(i,j,k)        ->   all coefficients
//
// If core's MMA is ever lifted out of simp.cpp to take a plain design vector,
// this file should be deleted and that one called.
//
// ── THE SIGN CONVENTION, WHICH IS THE ONE THING EASY TO GET WRONG ───────────
//
// The ersatz is rho = H_eta(-phi): phi UP means material OUT. Core's MMA assumes
// the design variable UP means material IN (dc <= 0, dv >= 0, constraint
// V(x) <= target). The two are reconciled by optimising
//
//     beta = -alpha
//
// so beta up is phi down is material in, and core's signs carry over unchanged.
// The caller passes dc = dJ/dbeta and dv = dV/dbeta and gets beta back.

#ifndef TOPOPT_TESTS_HARNESS_PLSM_MMA_HPP_
#define TOPOPT_TESTS_HARNESS_PLSM_MMA_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

struct PlsmMmaState {
  std::vector<double> xold1;
  std::vector<double> xold2;
  std::vector<double> low;
  std::vector<double> upp;
};

// One update. `x` is beta, `dc` = dJ/dbeta (<= 0 where material helps), `dv` =
// dV/dbeta (>= 0), `g0` = V(x) - target. `move` is a fraction of xrange.
inline std::vector<double> plsm_mma_update(PlsmMmaState& st, int mma_iter,
                                           const std::vector<double>& x,
                                           const std::vector<double>& dc_in,
                                           const std::vector<double>& dv,
                                           double g0, double xmin, double xmax,
                                           double move) {
  const std::size_t N = x.size();
  std::vector<double> dc = dc_in;

  // Scale-invariance, for the reason core's copy gives: raa0 is a FIXED 1e-5 and
  // the compliance sensitivity here is ~1e-8 in absolute terms, so without this
  // the regulariser drives p0/q0 instead of the objective.
  double dc_scale = 0.0;
  for (double v : dc) dc_scale = std::max(dc_scale, std::fabs(v));
  if (dc_scale > 0.0)
    for (double& v : dc) v /= dc_scale;

  const double xrange = xmax - xmin;
  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes.
  for (std::size_t e = 0; e < N; ++e) {
    const double xe = x[e];
    if (mma_iter <= 2 || st.xold1.size() != N || st.xold2.size() != N) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      const double s = (xe - st.xold1[e]) * (st.xold1[e] - st.xold2[e]);
      const double gamma = (s < 0.0) ? asydecr : (s > 0.0) ? asyincr : 1.0;
      double L = xe - gamma * (st.xold1[e] - st.low[e]);
      double U = xe + gamma * (st.upp[e] - st.xold1[e]);
      L = std::min(L, xe - 0.01 * xrange);
      L = std::max(L, xe - 10.0 * xrange);
      U = std::max(U, xe + 0.01 * xrange);
      U = std::min(U, xe + 10.0 * xrange);
      st.low[e] = L;
      st.upp[e] = U;
    }
  }

  // 2. Separable convex coefficients and the move box.
  std::vector<double> p0(N, 0.0), q0(N, 0.0), p1(N, 0.0), q1(N, 0.0);
  std::vector<double> alo(N, 0.0), bhi(N, 0.0);
  double b = -g0;
  for (std::size_t e = 0; e < N; ++e) {
    const double xe = x[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dc[e], 0.0), dcm = std::max(-dc[e], 0.0);
    const double dvp = std::max(dv[e], 0.0), dvm = std::max(-dv[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    p1[e] = ux1 * ux1 * (1.001 * dvp + 0.001 * dvm + raa0 / xrange);
    q1[e] = xl1 * xl1 * (0.001 * dvp + 1.001 * dvm + raa0 / xrange);
    b += p1[e] / ux1 + q1[e] / xl1;
    alo[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    bhi[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
    if (bhi[e] < alo[e]) bhi[e] = alo[e];
  }

  // 3. Dual solve for the single constraint.
  auto candidate = [&](double lambda) {
    std::vector<double> xnew(N, 0.0);
    for (std::size_t e = 0; e < N; ++e) {
      const double pl = std::sqrt(p0[e] + lambda * p1[e]);
      const double ql = std::sqrt(q0[e] + lambda * q1[e]);
      double xt = (pl + ql) > 0.0
                      ? (pl * st.low[e] + ql * st.upp[e]) / (pl + ql)
                      : x[e];
      if (xt < alo[e]) xt = alo[e];
      if (xt > bhi[e]) xt = bhi[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  auto gval = [&](const std::vector<double>& xx) {
    double s = 0.0;
    for (std::size_t e = 0; e < N; ++e)
      s += p1[e] / (st.upp[e] - xx[e]) + q1[e] / (xx[e] - st.low[e]);
    return s - b;
  };
  double lambda = 0.0;
  if (gval(candidate(0.0)) > 0.0) {
    double l1 = 0.0, l2 = 1.0;
    while (l2 < 1e30 && gval(candidate(l2)) > 0.0) l2 *= 2.0;
    for (int it = 0; it < 100 && (l2 - l1) > 1e-9 * (1.0 + l1 + l2); ++it) {
      const double lmid = 0.5 * (l1 + l2);
      if (gval(candidate(lmid)) > 0.0) l1 = lmid; else l2 = lmid;
    }
    lambda = 0.5 * (l1 + l2);
  }
  std::vector<double> xnew = candidate(lambda);

  st.xold2 = st.xold1;
  st.xold1 = x;
  return xnew;
}

#endif  // TOPOPT_TESTS_HARNESS_PLSM_MMA_HPP_
