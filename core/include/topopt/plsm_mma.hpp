// plsm_mma.hpp — ONE MMA DESIGN UPDATE IN RBF-COEFFICIENT SPACE.
//
// ★ THIS FILE IS A MOVE OUT OF `core/tests/harness/plsm_mma.hpp` (PR 324, ARM 2),
// NOT A REWRITE — the same move `plsm_basis.hpp` and `plsm_kernel.hpp` are, for
// the same reason: the PRODUCTION parametric optimiser drives its coefficients
// with this step, and a production copy of it would be a second MMA. That harness
// header is now a SHIM over this one.
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

#ifndef TOPOPT_PLSM_MMA_HPP_
#define TOPOPT_PLSM_MMA_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <vector>

namespace topopt {

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

// ── STAGE 4: THE SAME STEP WITH m CONSTRAINTS AT ONCE ───────────────────────
//
// `plsm_mma_update` above holds ONE constraint and solves its dual by bisection.
// Stage 4 puts the rules INSIDE the loop (volume, smallest size, overhang,
// perimeter, connectivity), so the step must hold m inequality constraints
// g_i(x) <= 0 at once. `plsm_mma_update_m` is that step.
//
// ★ m = 1 IS DELEGATED, NOT RE-SOLVED. With one constraint the general entry
// point calls `plsm_mma_update` itself, so today's optimiser is byte-identical
// whichever entry point a caller uses. A Newton dual cannot reproduce a
// bisection to the last bit, so delegation is the only honest way to promise
// the same bytes. `plsm_mma_update_general` is the m-constraint solver with no
// delegation (tests call it at m = 1 to check it agrees with the bisection).
//
// What is the SAME as the one-constraint step: the asymptote rule (asyinit 0.5,
// asyincr 1.2, asydecr 0.7, clamps 0.01..10 xrange), albefa 0.1, raa0 1e-5, the
// 1.001/0.001 split for every function, the move box, the closed-form primal
// minimiser, and the objective rescale by its largest gradient.
//
// What is NEW, and why:
//  * the dual has m variables lambda_i >= 0 and is maximised by a PROJECTED
//    NEWTON method (Bertsekas' active set: lambda_i = 0 with a negative gradient
//    stays fixed; the rest take a Newton step on the dual Hessian, then an
//    Armijo backtracking / expanding line search on the dual value, which is
//    concave, so every accepted step goes uphill);
//  * Svanberg's artificial variables y_i >= 0 with cost c_i y_i + y_i^2 / 2
//    (d_i = 1, c_i = `c_art`, default 1e4): if the move box cannot reach
//    feasibility in one step, the subproblem is still solvable, lambda_i stops
//    at c_i + y_i instead of running to infinity, and the step moves as far
//    toward feasibility as the box allows. Constraints should be scaled to
//    order 1 so that c_art = 1e4 is "large" against the (rescaled, max |grad|
//    = 1) objective.
//
// Inputs: dg[i] is dg_i/dx (size N each), g[i] is g_i(x) (<= 0 is feasible).

struct PlsmMmaMInfo {
  std::vector<double> lambda;  // dual multipliers, in the RESCALED objective's units
  std::vector<double> y;       // artificial variables (0 when the step is feasible)
  double obj_scale = 1.0;      // max |dc|; lambda * obj_scale is the true multiplier
  int dual_iters = 0;
  double dual_proj_grad = 0.0; // largest projected dual gradient at exit
  bool delegated = false;      // true when m = 1 went to plsm_mma_update
};

namespace plsm_mma_detail {
// Dense solve A z = r (k <= ~8), partial pivoting. False on a vanishing pivot.
inline bool dense_solve(std::vector<double> A, std::vector<double> r,
                        std::size_t k, std::vector<double>& z) {
  for (std::size_t c = 0; c < k; ++c) {
    std::size_t piv = c;
    for (std::size_t i = c + 1; i < k; ++i)
      if (std::fabs(A[i * k + c]) > std::fabs(A[piv * k + c])) piv = i;
    if (!(std::fabs(A[piv * k + c]) > 0.0)) return false;
    if (piv != c) {
      for (std::size_t j = 0; j < k; ++j) std::swap(A[c * k + j], A[piv * k + j]);
      std::swap(r[c], r[piv]);
    }
    for (std::size_t i = c + 1; i < k; ++i) {
      const double f = A[i * k + c] / A[c * k + c];
      for (std::size_t j = c; j < k; ++j) A[i * k + j] -= f * A[c * k + j];
      r[i] -= f * r[c];
    }
  }
  z.assign(k, 0.0);
  for (std::size_t c = k; c-- > 0;) {
    double s = r[c];
    for (std::size_t j = c + 1; j < k; ++j) s -= A[c * k + j] * z[j];
    z[c] = s / A[c * k + c];
    if (!std::isfinite(z[c])) return false;
  }
  return true;
}
}  // namespace plsm_mma_detail

inline std::vector<double> plsm_mma_update_general(
    PlsmMmaState& st, int mma_iter, const std::vector<double>& x,
    const std::vector<double>& dc_in,
    const std::vector<std::vector<double>>& dg, const std::vector<double>& g,
    double xmin, double xmax, double move, PlsmMmaMInfo* info = nullptr,
    double c_art = 1e4) {
  const std::size_t N = x.size();
  const std::size_t m = g.size();
  if (dc_in.size() != N || dg.size() != m)
    throw std::invalid_argument("plsm_mma_update_general: size mismatch");
  for (const auto& d : dg)
    if (d.size() != N)
      throw std::invalid_argument("plsm_mma_update_general: dg size mismatch");

  std::vector<double> dc = dc_in;
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

  // 1. Moving asymptotes: the one-constraint step's rule, unchanged.
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

  // 2. Separable convex coefficients for the objective and each constraint.
  std::vector<double> p0(N, 0.0), q0(N, 0.0), alo(N, 0.0), bhi(N, 0.0);
  std::vector<std::vector<double>> pc(m, std::vector<double>(N, 0.0)),
      qc(m, std::vector<double>(N, 0.0));
  std::vector<double> b(m, 0.0);
  for (std::size_t i = 0; i < m; ++i) b[i] = -g[i];
  for (std::size_t e = 0; e < N; ++e) {
    const double xe = x[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dc[e], 0.0), dcm = std::max(-dc[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    for (std::size_t i = 0; i < m; ++i) {
      const double dp = std::max(dg[i][e], 0.0), dm = std::max(-dg[i][e], 0.0);
      pc[i][e] = ux1 * ux1 * (1.001 * dp + 0.001 * dm + raa0 / xrange);
      qc[i][e] = xl1 * xl1 * (0.001 * dp + 1.001 * dm + raa0 / xrange);
      b[i] += pc[i][e] / ux1 + qc[i][e] / xl1;
    }
    alo[e] = std::max({xmin, L + albefa * (xe - L), xe - move * xrange});
    bhi[e] = std::min({xmax, U - albefa * (U - xe), xe + move * xrange});
    if (bhi[e] < alo[e]) bhi[e] = alo[e];
  }

  // 3. The dual. For a given lambda >= 0 the primal minimiser is closed form per
  //    variable; W(lambda) is concave, its gradient is g~_i(x(lambda)) - b_i - y_i.
  const double d_art = 1.0;
  auto primal = [&](const std::vector<double>& lam, std::size_t e, double& P,
                    double& Q) {
    P = p0[e];
    Q = q0[e];
    for (std::size_t i = 0; i < m; ++i) {
      P += lam[i] * pc[i][e];
      Q += lam[i] * qc[i][e];
    }
    const double pl = std::sqrt(P), ql = std::sqrt(Q);
    double xt = (pl + ql) > 0.0 ? (pl * st.low[e] + ql * st.upp[e]) / (pl + ql)
                                : x[e];
    if (xt < alo[e]) xt = alo[e];
    if (xt > bhi[e]) xt = bhi[e];
    return xt;
  };
  auto dual = [&](const std::vector<double>& lam, std::vector<double>* grad,
                  std::vector<double>* hess) {
    double W = 0.0;
    std::vector<double> gt(m, 0.0), gp(m, 0.0);
    if (hess) hess->assign(m * m, 0.0);
    for (std::size_t e = 0; e < N; ++e) {
      double P, Q;
      const double xe = primal(lam, e, P, Q);
      const double ux = st.upp[e] - xe, xl = xe - st.low[e];
      W += P / ux + Q / xl;
      for (std::size_t i = 0; i < m; ++i)
        gt[i] += pc[i][e] / ux + qc[i][e] / xl;
      if (hess && xe > alo[e] && xe < bhi[e]) {
        const double D = 2.0 * P / (ux * ux * ux) + 2.0 * Q / (xl * xl * xl);
        if (D > 0.0) {
          for (std::size_t i = 0; i < m; ++i)
            gp[i] = pc[i][e] / (ux * ux) - qc[i][e] / (xl * xl);
          for (std::size_t i = 0; i < m; ++i)
            for (std::size_t j = 0; j < m; ++j)
              (*hess)[i * m + j] -= gp[i] * gp[j] / D;
        }
      }
    }
    for (std::size_t i = 0; i < m; ++i) {
      const double yi = std::max(0.0, (lam[i] - c_art) / d_art);
      W += -lam[i] * b[i] + c_art * yi + 0.5 * d_art * yi * yi - lam[i] * yi;
      if (grad) (*grad)[i] = gt[i] - b[i] - yi;
      if (hess && lam[i] > c_art) (*hess)[i * m + i] -= 1.0 / d_art;
    }
    return W;
  };

  std::vector<double> lam(m, 0.0), grad(m, 0.0), H;
  std::vector<double> tol(m, 0.0);
  for (std::size_t i = 0; i < m; ++i)
    tol[i] = 1e-11 * (std::fabs(b[i]) + std::fabs(g[i])) + 1e-300;
  int dual_it = 0;
  double pg_max = 0.0;
  for (; m > 0 && dual_it < 200; ++dual_it) {
    const double W = dual(lam, &grad, &H);
    // Projected gradient and the free set.
    bool done = true;
    pg_max = 0.0;
    std::vector<std::size_t> F;
    for (std::size_t i = 0; i < m; ++i) {
      const double pg = (lam[i] > 0.0) ? grad[i] : std::max(grad[i], 0.0);
      pg_max = std::max(pg_max, std::fabs(pg));
      if (std::fabs(pg) > tol[i]) done = false;
      if (lam[i] > 0.0 || grad[i] > 0.0) F.push_back(i);
    }
    if (done || F.empty()) break;
    const std::size_t k = F.size();
    std::vector<double> A(k * k, 0.0), r(k, 0.0), z;
    double dmax = 0.0;
    for (std::size_t a = 0; a < k; ++a) {
      r[a] = grad[F[a]];
      for (std::size_t c = 0; c < k; ++c) A[a * k + c] = -H[F[a] * m + F[c]];
      dmax = std::max(dmax, A[a * k + a]);
    }
    const double mu = dmax > 0.0 ? 1e-12 * dmax : 1.0;
    for (std::size_t a = 0; a < k; ++a) A[a * k + a] += mu;
    std::vector<double> dir(m, 0.0);
    bool newton = plsm_mma_detail::dense_solve(A, r, k, z);
    double slope = 0.0;
    if (newton) {
      for (std::size_t a = 0; a < k; ++a) {
        dir[F[a]] = z[a];
        slope += grad[F[a]] * z[a];
      }
    }
    if (!newton || !(slope > 0.0)) {
      for (std::size_t a = 0; a < k; ++a) dir[F[a]] = grad[F[a]];
    }
    auto trial = [&](double t) {
      std::vector<double> l2(m);
      for (std::size_t i = 0; i < m; ++i) l2[i] = std::max(0.0, lam[i] + t * dir[i]);
      return l2;
    };
    auto armijo = [&](const std::vector<double>& l2, double W2) {
      double s = 0.0;
      for (std::size_t i = 0; i < m; ++i) s += grad[i] * (l2[i] - lam[i]);
      return std::isfinite(W2) && W2 >= W + 1e-4 * s && s > 0.0;
    };
    double t = 1.0;
    std::vector<double> best = trial(t);
    double Wb = dual(best, nullptr, nullptr);
    if (armijo(best, Wb)) {
      // Expand while the dual keeps rising (a flat or regularised direction).
      for (int ex = 0; ex < 80; ++ex) {
        std::vector<double> l2 = trial(2.0 * t);
        const double W2 = dual(l2, nullptr, nullptr);
        if (!(std::isfinite(W2) && W2 > Wb)) break;
        t *= 2.0;
        best = l2;
        Wb = W2;
      }
    } else {
      bool ok = false;
      for (int bt = 0; bt < 60 && !ok; ++bt) {
        t *= 0.5;
        best = trial(t);
        Wb = dual(best, nullptr, nullptr);
        ok = armijo(best, Wb);
      }
      if (!ok) break;
    }
    double dl = 0.0, lmax = 0.0;
    for (std::size_t i = 0; i < m; ++i) {
      dl = std::max(dl, std::fabs(best[i] - lam[i]));
      lmax = std::max(lmax, std::fabs(lam[i]));
    }
    lam = best;
    if (dl <= 1e-15 * (1.0 + lmax)) break;
  }

  std::vector<double> xnew(N, 0.0);
  for (std::size_t e = 0; e < N; ++e) {
    double P, Q;
    xnew[e] = primal(lam, e, P, Q);
  }
  if (info) {
    info->lambda = lam;
    info->y.assign(m, 0.0);
    for (std::size_t i = 0; i < m; ++i)
      info->y[i] = std::max(0.0, (lam[i] - c_art) / d_art);
    info->obj_scale = dc_scale > 0.0 ? dc_scale : 1.0;
    info->dual_iters = dual_it;
    info->dual_proj_grad = pg_max;
    info->delegated = false;
  }

  st.xold2 = st.xold1;
  st.xold1 = x;
  return xnew;
}

// The general entry point. m = 1 delegates to `plsm_mma_update` (same bytes as
// today); m >= 2 (or m = 0) runs the m-dimensional dual above.
inline std::vector<double> plsm_mma_update_m(
    PlsmMmaState& st, int mma_iter, const std::vector<double>& x,
    const std::vector<double>& dc, const std::vector<std::vector<double>>& dg,
    const std::vector<double>& g, double xmin, double xmax, double move,
    PlsmMmaMInfo* info = nullptr, double c_art = 1e4) {
  if (g.size() == 1 && dg.size() == 1) {
    if (info) {
      *info = PlsmMmaMInfo{};
      info->delegated = true;
    }
    return plsm_mma_update(st, mma_iter, x, dc, dg[0], g[0], xmin, xmax, move);
  }
  return plsm_mma_update_general(st, mma_iter, x, dc, dg, g, xmin, xmax, move,
                                 info, c_art);
}

}  // namespace topopt

#endif  // TOPOPT_PLSM_MMA_HPP_
