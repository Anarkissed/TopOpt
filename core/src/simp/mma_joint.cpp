// mma_joint.cpp — see mma_joint.hpp.
//
// The constants and the step structure are `mma_update`'s, unchanged: asyinit =
// 0.5, asyincr = 1.2 / asydecr = 0.7, albefa = 0.1, raa0 = 1e-5, following the
// mmasub reference and Svanberg 1987. The ONLY generalisation is that xmin, xmax
// and therefore xrange are per-variable instead of scalar.

#include "mma_joint.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace topopt {

std::vector<double> mma_update_joint(MmaJointState& st, int mma_iter,
                                     const std::vector<double>& x,
                                     const std::vector<std::size_t>& dof,
                                     const std::vector<double>& dobj,
                                     const std::vector<double>& dcon,
                                     const std::vector<double>& xmin,
                                     const std::vector<double>& xmax, double g0,
                                     double move) {
  const std::size_t N = x.size();
  if (dobj.size() != N || dcon.size() != N || xmin.size() != N ||
      xmax.size() != N)
    throw std::invalid_argument(
        "mma_update_joint: x, dobj, dcon, xmin and xmax must all be N long");

  const double asyinit = 0.5, asyincr = 1.2, asydecr = 0.7;
  const double albefa = 0.1, raa0 = 1e-5;

  if (st.low.size() != N) {
    st.low.assign(N, 0.0);
    st.upp.assign(N, 0.0);
  }

  // 1. Moving asymptotes L_j, U_j.
  for (std::size_t e : dof) {
    const double xe = x[e];
    const double xrange = xmax[e] - xmin[e];
    if (mma_iter <= 2) {
      st.low[e] = xe - asyinit * xrange;
      st.upp[e] = xe + asyinit * xrange;
    } else {
      // Oscillation detector: sign of (x^k - x^{k-1})(x^{k-1} - x^{k-2}).
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

  // 2. Separable convex approximation coefficients and the move box.
  std::vector<double> p0(N, 0.0), q0(N, 0.0), p1(N, 0.0), q1(N, 0.0);
  std::vector<double> alpha(N, 0.0), beta(N, 0.0);
  double b = -g0;
  for (std::size_t e : dof) {
    const double xe = x[e];
    const double xrange = xmax[e] - xmin[e];
    const double L = st.low[e], U = st.upp[e];
    const double ux1 = U - xe, xl1 = xe - L;
    const double dcp = std::max(dobj[e], 0.0), dcm = std::max(-dobj[e], 0.0);
    const double dvp = std::max(dcon[e], 0.0), dvm = std::max(-dcon[e], 0.0);
    p0[e] = ux1 * ux1 * (1.001 * dcp + 0.001 * dcm + raa0 / xrange);
    q0[e] = xl1 * xl1 * (0.001 * dcp + 1.001 * dcm + raa0 / xrange);
    p1[e] = ux1 * ux1 * (1.001 * dvp + 0.001 * dvm + raa0 / xrange);
    q1[e] = xl1 * xl1 * (0.001 * dvp + 1.001 * dvm + raa0 / xrange);
    b += p1[e] / ux1 + q1[e] / xl1;
    alpha[e] = std::max({xmin[e], L + albefa * (xe - L), xe - move * xrange});
    beta[e] = std::min({xmax[e], U - albefa * (U - xe), xe + move * xrange});
  }

  // 3. Dual solve for the single constraint, shared by every block. This is the
  // reason the blocks cannot be updated separately: one lambda prices the whole
  // budget, so whichever block buys stiffness more cheaply per unit mass gets it.
  auto candidate = [&](double lambda) {
    std::vector<double> xnew(N, 0.0);
    for (std::size_t e : dof) {
      const double pl = std::sqrt(p0[e] + lambda * p1[e]);
      const double ql = std::sqrt(q0[e] + lambda * q1[e]);
      double xt = (pl * st.low[e] + ql * st.upp[e]) / (pl + ql);
      if (xt < alpha[e]) xt = alpha[e];
      if (xt > beta[e]) xt = beta[e];
      xnew[e] = xt;
    }
    return xnew;
  };
  auto gval = [&](const std::vector<double>& xc) {
    double s = 0.0;
    for (std::size_t e : dof)
      s += p1[e] / (st.upp[e] - xc[e]) + q1[e] / (xc[e] - st.low[e]);
    return s - b;
  };
  double lambda = 0.0;
  if (gval(candidate(0.0)) > 0.0) {
    double l1 = 0.0, l2 = 1.0;
    while (l2 < 1e30 && gval(candidate(l2)) > 0.0) l2 *= 2.0;
    for (int it = 0; it < 100 && (l2 - l1) > 1e-9 * (1.0 + l1 + l2); ++it) {
      const double lmid = 0.5 * (l1 + l2);
      if (gval(candidate(lmid)) > 0.0)
        l1 = lmid;
      else
        l2 = lmid;
    }
    lambda = 0.5 * (l1 + l2);
  }
  std::vector<double> xnew = candidate(lambda);

  // 4. Roll the history forward.
  st.xold2 = st.xold1;
  st.xold1 = x;
  return xnew;
}

}  // namespace topopt
