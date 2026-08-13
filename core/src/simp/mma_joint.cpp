// mma_joint.cpp — see mma_joint.hpp.
//
// The constants and the step structure are `mma_update`'s, unchanged: asyinit =
// 0.5, asyincr = 1.2 / asydecr = 0.7, albefa = 0.1, raa0 = 1e-5, following the
// mmasub reference and Svanberg 1987. The ONLY generalisation is that xmin, xmax
// and therefore xrange are per-variable instead of scalar.

#include "mma_joint.hpp"

#include "topopt/simp.hpp"

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

// ★ MODE 2 (task 2026-08-13-lattice-as-a-material §3): the masked MMA subproblem
// over BOTH design blocks — the Active voxel densities AND the lattice density
// field's beta coefficients — under ONE volume constraint.
//
// Returns the flattened new point, [density (N) ; beta (nb)].
//
// Three things differ from `mma_update_masked`, and only three:
//
//   1. THE CONSTRAINT COUNTS THE LATTICE. In Mode 1 the frozen region's mass is a
//      CONSTANT, so it is folded into the target once (`vf_target`) and never
//      thought about again. Here it MOVES, so it belongs on the left-hand side:
//      g0 = (V_active + lattice mass) - total_target. Adding it to both sides
//      would double-count the very saving the feature exists to find.
//   2. THE BETA BLOCK IS NOT FILTERED. The density filter is the regularizer for
//      a voxel field; for beta the RBF basis already is one — its support IS the
//      length scale — so filtering it would impose a second, smaller one.
//   3. ONE dc_scale ACROSS BOTH BLOCKS. The scale-invariance normalisation must
//      be a single positive constant over the WHOLE vector: scaling the blocks
//      separately would silently reprice one against the other, which is exactly
//      the trade this subproblem exists to make.
std::vector<double> mma_update_masked_lattice(
    MmaJointState& st, int mma_iter, const VoxelGrid& grid,
    const DensityFilter& filter, const DesignMask& eff,
    const std::vector<double>& density, const std::vector<double>& beta,
    const std::vector<double>& dcompliance,
    const std::vector<double>& dobj_beta, const std::vector<double>& dmass_beta,
    double lattice_mass_voxels, double total_target, double beta_min,
    double beta_max, double move, double density_min) {
  const std::size_t N = grid.voxel_count();
  const std::size_t nb = beta.size();
  if (dobj_beta.size() != nb || dmass_beta.size() != nb)
    throw std::invalid_argument(
        "mma_update_masked_lattice: beta sensitivity size != beta size");

  std::vector<double> dc_vox = filter.filter_sensitivity(dcompliance);
  std::vector<double> ones(N, 0.0);
  std::vector<std::size_t> dof;
  for (std::size_t e = 0; e < N; ++e)
    if (eff[e] == MaskValue::Active) {
      ones[e] = 1.0;
      dof.push_back(e);
    }
  const std::vector<double> dv_vox = filter.filter_sensitivity(ones);

  const std::size_t M = N + nb;
  std::vector<double> x(M, 0.0), dobj(M, 0.0), dcon(M, 0.0);
  std::vector<double> xmin_v(M, density_min), xmax_v(M, 1.0);
  for (std::size_t e = 0; e < N; ++e) {
    x[e] = density[e];
    dobj[e] = dc_vox[e];
    dcon[e] = dv_vox[e];
  }
  for (std::size_t j = 0; j < nb; ++j) {
    const std::size_t e = N + j;
    x[e] = beta[j];
    dobj[e] = dobj_beta[j];
    dcon[e] = dmass_beta[j];
    xmin_v[e] = beta_min;
    xmax_v[e] = beta_max;
    dof.push_back(e);
  }

  // One normalisation over the whole vector (point 3 above).
  double dc_scale = 0.0;
  for (std::size_t e : dof) dc_scale = std::max(dc_scale, std::fabs(dobj[e]));
  if (dc_scale > 0.0)
    for (std::size_t e : dof) dobj[e] /= dc_scale;

  // g0: the Active physical volume plus what the lattice actually occupies.
  const std::vector<double> xphys = filter.filter_density(density);
  double vol = 0.0;
  for (double v : xphys) vol += v;
  const double g0 = vol + lattice_mass_voxels - total_target;

  return mma_update_joint(st, mma_iter, x, dof, dobj, dcon, xmin_v, xmax_v, g0,
                          move);
}

}  // namespace topopt
