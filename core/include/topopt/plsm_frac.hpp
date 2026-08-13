// plsm_frac.hpp — ★ THE ERSATZ DENSITY AS THE EXACT VOLUME FRACTION OF THE CELL
// THAT LIES INSIDE {phi < 0}, AND THE SENSITIVITY THAT MATCHES IT — IN CORE.
//
// ★ THIS FILE IS A MOVE OUT OF `core/tests/harness/frac_ersatz.hpp`, NOT A
// REWRITE — the same move `plsm_basis.hpp` and `plsm_kernel.hpp` are, for the
// same reason: the PRODUCTION optimiser needs these functions and a production
// copy of them would be a second quadrature law in the repository. Every
// function below is that header's, with its comments, re-signed to take three
// plain ints instead of the harness's `Dims` so one implementation serves both.
// The harness header is now a SHIM over this one.
//
// ── WHAT THIS REPLACES, AND WHY IT IS A CORRECTNESS FIX ─────────────────────
//
// Every level-set arm in PR 322/323/324/325/326 — AND the shipped `--plsm` job
// mode — built its ersatz density by SAMPLING A SMOOTHED HEAVISIDE AT THE CELL
// CENTRE:
//
//     rho_e = rho_min + (1 - rho_min) * H_eta(-phi(x_centre)),   eta = 2 voxels
//
// ★ PR 327 §4 MEASURED THAT THE GRADIENT BELONGING TO THAT DENSITY IS WRONG BY
// UP TO 23%, FLAT ACROSS TWO DECADES OF STEP SIZE. Flatness is what makes it a
// gradient error rather than noise: a finite difference that has not converged
// moves with the step, one that has converged to the wrong number does not. The
// cause is named rather than guessed — `DH_eta(phi)*|grad phi|` is the SURFACE
// measure `dS`, correct for the CONTINUUM shape derivative, while the derivative
// of the DISCRETE ersatz `rho_v = H_eta(-phi_v)` carries no `|grad phi|` at all.
// The two agree exactly when phi is a signed distance; this one is not
// (‖grad phi‖−1 runs 0.35–0.39 rms through every arm), so the difference is real.
//
// ★ AND A 20%-WRONG DESCENT DIRECTION DOES NOT FAIL — IT CONVERGES SLOWLY. Both
// of PR 327's fraction arms hit the shipped convergence criterion in 57 and 61
// iterations while the Heaviside control never reached it in 120, at the same
// compliance within 0.9%.
//
// This header computes the thing the Heaviside was standing in for:
//
//     rho_e = rho_min + (1 - rho_min) * f_v,
//     f_v   = (1/|C_v|) INT_{C_v} 1[phi(x) < 0] dx
//
// ★ AND ONLY `rho_e` CHANGES. For an isotropic ersatz the cell stiffness is
// `rho_e * K0`, so the 24x24 reference block, the matrix-free stencil, the
// geometric multigrid, GenEO, the Krylov recycler and the Galerkin block cache
// are all untouched: no per-cell `Ke`, no O(cut cells) storage, no cache-key
// change. What is bought is that `rho_e` now carries SUB-VOXEL BOUNDARY POSITION
// — it varies continuously as the interface moves inside a cell instead of
// stepping when the boundary crosses the centre.
//
// ── (a) HOW f_v IS COMPUTED: SUB-CELL SAMPLING, NOT AN ANALYTIC INTEGRAL ────
//
// phi is a sum of compactly-supported RBFs; the exact polyhedral intersection of
// its zero set with a cube is not worth writing. `f_v` is the fraction of a
// k x k x k lattice of points inside the cell with phi < 0. Sample (p,q,r) of
// cell (i,j,k) sits at voxel coordinate
//
//     x = i + (p + 0.5)/k - 0.5
//
// which is EXACTLY where `plsm_evaluate(..., factor = k)` puts its sample and
// exactly where `resample_field` / `marching_cubes_resampled` put theirs. ★ The
// sub-cell lattice and the export lattice are the SAME lattice; there is no
// second convention anywhere in this file.
//
// ── (b) ONLY THE CELLS THAT CAN BE CUT ARE EVER SAMPLED ─────────────────────
//
// A cell that is `Empty`, `FrozenSolid` or `FrozenVoid` is stamped 0 or 1 by the
// mask and the optimiser never had any say over it. On his part that is 397,536
// of 468,224 voxels, so only the 70,688 ACTIVE cells are sampled at all — and of
// those the ones actually CUT (mixed sample signs) are COUNTED every iteration
// rather than bounded by a classifier. A classifier would need a margin and a
// margin is one more thing that can be wrong; the count is exact.
//
// ── (c) ★ THE SENSITIVITY, WHICH IS THE PART THAT CAN WASTE THE RUN ─────────
//
// Leaving `DH_eta(phi)*|grad phi|` in place against a volume-fraction density
// would be a MISMATCHED GRADIENT: it converges, just slowly and to somewhere
// else, and it would be believed. The derivative of `f_v` is a surface integral
// over the part of the interface inside the cell, which the co-area formula
// turns into a volume integral of a Dirac:
//
//     d f_v / d alpha_i = -(1/|C|) INT_{Gamma cap C} psi_i / |grad phi| dS
//                       = -(1/|C|) INT_C delta(phi) psi_i dx
//                      ~= -(1/k^3) SUM_s delta_q(phi_s) psi_i(x_s)
//
// with `delta_q` a NORMALISED TENT of half-width
//
//     ★ eps_q = eps_mult * |grad phi|_v * h/k        THE QUADRATURE BANDWIDTH
//
// Two things about that expression are load-bearing and neither is obvious:
//
// ★ THE `|grad phi|` IS GONE FROM THE MEASURE, AND ITS ABSENCE IS THE
// CORRECTION. The old measure is `dS`; this one is `dS/|grad phi|`, and the
// second is what the derivative of a VOLUME FRACTION actually is.
//
// ★ `psi_i` IS EVALUATED AT THE SAMPLES, NOT AT THE CELL CENTRE. `Psi` is built
// on the cell-centre lattice, so `Psi^T` would factor `psi_i` out of the sub-cell
// sum — the same substitution this file exists to remove, made one level down,
// and it would have been INVISIBLE (the result is still a descent direction and
// the run still converges). PR 327 §4(c)(i) priced it rather than assuming it:
// the sub-cell psi is worth about 15 PERCENTAGE POINTS of gradient accuracy on a
// general direction, the same order as the `|grad phi|` error the whole change
// turns on — and NOTHING on a single coefficient, so a single-coefficient check
// would have said the scatter was unnecessary. Building a `Psi` on the sample
// lattice is 64x bigger and would be rebuilt every iteration, so the projection
// is a SCATTER instead: the knot walk that evaluates phi at a sample already
// holds the `(index, psi)` list, and the sensitivity re-walks it into per-thread
// coefficient accumulators.
//
// ── ★ WHY eps_q IS NOT eta WEARING A DIFFERENT HAT ──────────────────────────
//
// This is the obvious objection to a task whose headline is "eta leaves the
// density path", so it is answered here rather than left to be found:
//
//   * eps_q APPEARS IN NO DENSITY under the hard count — `f_v` is a count of
//     sample signs — and under the mollified value it appears as the exact
//     ANTIDERIVATIVE of the gradient's own mollifier, which is a different
//     relationship from eta's (see `plsm_frac_soft_step`).
//   * it is TIED TO THE SAMPLE SPACING — `eps_mult * |grad phi| * h/k` — so it
//     shrinks like 1/k and converges to the exact surface delta as `k` refines.
//     eta is fixed at a length in voxels and shrinks with nothing; refining
//     anything at all never made `H_eta` converge to the indicator.
//   * at `eps_mult = 1` and a locally planar interface the tent is a PARTITION
//     OF UNITY along the normal — SUM_m (1 - |t - m*D|/D)/D = 1/D exactly, for
//     every offset of the interface — so the estimator is smooth in alpha BY
//     CONSTRUCTION rather than by averaging. That property is why a tent was
//     chosen over the raised cosine `H_eta` differentiates to: the cosine bell
//     is a partition of unity at no sampling, and would leave a ripple as the
//     interface slides between samples.
//
// ── ★ AND THE WART, STATED HERE RATHER THAN FOUND LATER ─────────────────────
//
// The HARD `f_v` is a count of sample signs, so it is PIECEWISE CONSTANT in
// alpha: it jumps by 1/k^3 whenever one sample crosses. Its derivative is
// therefore zero almost everywhere, and the analytic sensitivity above is the
// derivative of the CONTINUUM quantity `f_v` approximates rather than of the
// number the solver is handed. ★ PR 327 §4(c)(ii) measured exactly what that
// costs — the hard variant's volume finite difference reads +182% at step 0.001
// and −45.7% at 0.01, and its compliance difference is noise-dominated at every
// step two state solves can afford — and measured that the CONSISTENTLY
// MOLLIFIED value removes it: sub-1% on the volume at the same steps, and
// 1.3–5.2% on the COMPLIANCE, the only formulation in that study whose gradient
// could be verified on both functionals at all.
//
// ★ SO THE MOLLIFIED VALUE IS THE PRODUCTION DEFAULT AND THE HARD COUNT IS KEPT
// REACHABLE. The two agree on the volume they measure to 0.037% (34,972.3
// against 34,959.5 active-cell voxels), so the mollification buys the
// differentiability WITHOUT MOVING THE GEOMETRY.

#ifndef TOPOPT_PLSM_FRAC_HPP_
#define TOPOPT_PLSM_FRAC_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <thread>
#include <vector>

#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_kernel.hpp"

namespace topopt {

// ── the normalised quadrature mollifier ─────────────────────────────────────
//
// A tent of half-width eps, INT = 1. Linear rather than the raised cosine
// `H_eta` differentiates to, BECAUSE of the partition-of-unity property in the
// file header.
inline double plsm_frac_delta_q(double t, double eps) {
  const double a = std::fabs(t);
  if (a >= eps) return 0.0;
  return (1.0 - a / eps) / eps;
}

// ★ THE CONSISTENTLY-MOLLIFIED PER-SAMPLE STEP. It is EXACTLY the antiderivative
// of the tent `plsm_frac_delta_q` the sensitivity uses, reflected:
// S(t) = INT_t^inf delta_q. Deriving it from the mollifier rather than picking a
// second smoothing law is the whole point — dS/dt = -delta_q(t) IDENTICALLY, so
// the value and the gradient are two facts about ONE function and the finite
// difference has nothing to reveal.
//
//     S(t) = 1                      t <= -eps
//            0.5 - u + u|u|/2       |t| < eps,  u = t/eps
//            0                      t >= eps
inline double plsm_frac_soft_step(double t, double eps) {
  if (t <= -eps) return 1.0;
  if (t >= eps) return 0.0;
  const double u = t / eps;
  return 0.5 - u + 0.5 * u * std::fabs(u);
}

// The per-cell quadrature bandwidth, in the same units as phi (mm).
//
// ★ CLAMPED FROM BELOW, and the clamp is not cosmetic. |grad phi| is a central
// difference and it is small on the medial axis, where the exact distance
// function of any solid has a kink. A vanishing eps_q there would make the
// mollifier a spike between samples and the sum would alias badly. The floor is
// a tenth of the isotropic sample spacing.
inline double plsm_frac_eps(double gradscale, double h, int k, double eps_mult) {
  const double sp = h / static_cast<double>(k);
  return std::max(0.1 * sp, eps_mult * gradscale * sp);
}

// |grad phi|_1, central differences, the SAME stencil `plsm_grad_mag` uses for
// the L2 norm.
//
// ★ WHY IT EXISTS AND WHY IT IS NOT THE DEFAULT. Engquist, Tornberg & Tsai (JCP
// 207(1):28-51, 2005) prove that an implicit mollifier whose bandwidth scales
// with |grad phi|_2 is NOT CONVERGENT in two or more dimensions — their
// closed-form counterexample is a straight line at 45 degrees, where the narrow
// hat at eps = h leaves a 12.1% error that does not decrease with h — and that
// scaling by the L1 norm makes it first order. So the L1 bandwidth is the
// theoretically correct one, and it is REACHABLE.
//
// ★ IT IS NOT ARMED BY DEFAULT BECAUSE IT WAS MEASURED AND IT LOST. PR 327 §5 M5
// finite-differenced each mechanism alone on the same design: the mollified value
// ALONE verifies at −1.33 / +3.18% on the compliance, and adding the L1 bandwidth
// takes it to −2.32 / +7.61%. The theory is about the asymptotic rate of a
// quadrature; what ships is chosen on the measurement at k = 4 on this part.
inline double plsm_frac_grad_l1(int nx, int ny, int nz,
                                const std::vector<double>& phi, int i, int j,
                                int k, double h) {
  auto P = [&](int A, int B, int C) {
    A = std::min(std::max(A, 0), nx - 1);
    B = std::min(std::max(B, 0), ny - 1);
    C = std::min(std::max(C, 0), nz - 1);
    return phi[plsm_at(nx, ny, A, B, C)];
  };
  const double gx = (P(i + 1, j, k) - P(i - 1, j, k)) / (2.0 * h);
  const double gy = (P(i, j + 1, k) - P(i, j - 1, k)) / (2.0 * h);
  const double gz = (P(i, j, k + 1) - P(i, j, k - 1)) / (2.0 * h);
  return std::fabs(gx) + std::fabs(gy) + std::fabs(gz);
}

// ── the sample cache ────────────────────────────────────────────────────────
//
// Built ONCE per iteration, after the volume offset has been folded into alpha
// and phi resynced, and read by the density, by the volume constraint, by the
// band and by the sensitivity. The two arrays are phi and SUM_i psi_i at every
// sample; the second is what a rigid offset of the level set moves phi by, so an
// offset can be applied to the cache — or evaluated THROUGH it, which is what the
// volume bisection does — without re-evaluating the basis.
struct PlsmFracCache {
  int k = 0;
  std::size_t ncell = 0;                // ACTIVE cells sampled
  std::vector<int> cell;                // slot -> voxel index
  std::vector<int> slot;                // voxel index -> slot, or -1
  std::vector<double> phis;             // ncell * k^3, phi at the sample
  std::vector<double> psis;             // ncell * k^3, SUM_i psi_i at the sample
  // ── the statistics, COUNTED rather than bounded
  std::size_t n_boundary = 0;           // cells with MIXED sample signs
  std::size_t n_full = 0, n_empty = 0;  // all samples in / all out
  double build_s = 0.0;                 // wall clock of the last build

  int per_cell() const { return k * k * k; }
};

// A plain chunked parallel-for that hands the body its THREAD INDEX, which
// `plsm_parallel_for` does not. The scatter below needs per-thread accumulators
// over the coefficients and an atomic per knot would serialise it.
template <typename F>
void plsm_frac_parallel(std::size_t n, int threads, F&& body) {
  const int t = std::max(1, threads);
  if (t == 1 || n < 1024) {
    for (std::size_t i = 0; i < n; ++i) body(i, 0);
    return;
  }
  std::vector<std::thread> pool;
  pool.reserve(static_cast<std::size_t>(t));
  const std::size_t chunk =
      (n + static_cast<std::size_t>(t) - 1) / static_cast<std::size_t>(t);
  for (int q = 0; q < t; ++q) {
    const std::size_t lo = static_cast<std::size_t>(q) * chunk;
    const std::size_t hi = std::min(n, lo + chunk);
    if (lo >= hi) break;
    pool.emplace_back([lo, hi, q, &body] {
      for (std::size_t i = lo; i < hi; ++i) body(i, q);
    });
  }
  for (auto& th : pool) th.join();
}

// ── the build ───────────────────────────────────────────────────────────────
//
// `sample` marks the cells that need it — the ACTIVE ones. Everything else is
// stamped by the mask and is not this header's business.
inline void plsm_frac_build(int nx, int ny, int nz, const PlsmKnotLattice& L,
                            PlsmBasisKind basis,
                            const std::vector<double>& alpha,
                            const std::vector<char>& sample, int k, int threads,
                            PlsmFracCache& C) {
  const std::size_t n = static_cast<std::size_t>(nx) *
                        static_cast<std::size_t>(ny) *
                        static_cast<std::size_t>(nz);
  if (C.slot.size() != n || C.k != k) {
    C.slot.assign(n, -1);
    C.cell.clear();
    C.k = k;
    for (std::size_t v = 0; v < n; ++v)
      if (sample[v]) {
        C.slot[v] = static_cast<int>(C.cell.size());
        C.cell.push_back(static_cast<int>(v));
      }
    C.ncell = C.cell.size();
    C.phis.assign(C.ncell * static_cast<std::size_t>(C.per_cell()), 0.0);
    C.psis.assign(C.ncell * static_cast<std::size_t>(C.per_cell()), 0.0);
  }
  const int kk = C.per_cell();
  const double inv = 1.0 / static_cast<double>(k);

  plsm_frac_parallel(C.ncell, threads, [&](std::size_t s, int) {
    const std::size_t v = static_cast<std::size_t>(C.cell[s]);
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int kz = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                         static_cast<std::size_t>(ny)));
    std::vector<int> idx;
    std::vector<double> w;
    std::size_t o = s * static_cast<std::size_t>(kk);
    for (int r = 0; r < k; ++r) {
      const double z = kz + (r + 0.5) * inv - 0.5;
      for (int q = 0; q < k; ++q) {
        const double y = j + (q + 0.5) * inv - 0.5;
        for (int p = 0; p < k; ++p, ++o) {
          const double x = i + (p + 0.5) * inv - 0.5;
          idx.clear();
          w.clear();
          plsm_support_of(L, basis, x, y, z, idx, w);
          double sp = 0.0, sw = 0.0;
          for (std::size_t m = 0; m < idx.size(); ++m) {
            sp += alpha[static_cast<std::size_t>(idx[m])] * w[m];
            sw += w[m];
          }
          C.phis[o] = sp;
          C.psis[o] = sw;
        }
      }
    }
  });

  C.n_boundary = C.n_full = C.n_empty = 0;
  for (std::size_t s = 0; s < C.ncell; ++s) {
    const std::size_t o = s * static_cast<std::size_t>(kk);
    int in = 0;
    for (int m = 0; m < kk; ++m) in += C.phis[o + m] < 0.0 ? 1 : 0;
    if (in == 0) ++C.n_empty;
    else if (in == kk) ++C.n_full;
    else ++C.n_boundary;
  }
}

// A rigid offset of the level set, applied to the cache IN PLACE. phi = Psi
// alpha, so alpha_i += c for every i moves phi by c * SUM psi EXACTLY — which is
// the same `offset * psi_sum` the volume bisection already uses on the coarse
// lattice. Applying it here costs one pass and saves a rebuild.
inline void plsm_frac_shift(PlsmFracCache& C, double offset) {
  if (offset == 0.0) return;
  for (std::size_t o = 0; o < C.phis.size(); ++o)
    C.phis[o] += offset * C.psis[o];
}

// f_v — the HARD fraction of the cell inside {phi < 0}, at a rigid offset.
// Cells outside the cache are not this header's: the caller stamps them.
// `offset == 0` is the cache as built and costs no extra arithmetic worth
// naming; the offset form exists so the volume bisection can evaluate a
// candidate WITHOUT mutating the cache it will need again.
inline double plsm_frac_of(const PlsmFracCache& C, std::size_t v,
                           double offset = 0.0) {
  const int s = C.slot[v];
  if (s < 0) return -1.0;
  const int kk = C.per_cell();
  const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
  int in = 0;
  if (offset == 0.0) {
    for (int m = 0; m < kk; ++m) in += C.phis[o + m] < 0.0 ? 1 : 0;
  } else {
    for (int m = 0; m < kk; ++m)
      in += (C.phis[o + m] + offset * C.psis[o + m]) < 0.0 ? 1 : 0;
  }
  return static_cast<double>(in) / static_cast<double>(kk);
}

// ★ THE MOLLIFIED VALUE — the production default. The same sub-cell quadrature
// with the hard indicator replaced by the antiderivative of the mollifier the
// SENSITIVITY uses, at the SAME bandwidth. It is the exact volume fraction to
// the same O(1/k) as the hard count, its derivative is the analytic one to
// machine precision, and it removes the piecewise-constant wart named in the
// file header. eps_q shrinks like 1/k, so this is NOT a return to eta: it
// converges to the indicator, which eta never does.
inline double plsm_frac_of_soft(const PlsmFracCache& C, std::size_t v, double eps,
                                double offset = 0.0) {
  const int s = C.slot[v];
  if (s < 0) return -1.0;
  const int kk = C.per_cell();
  const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
  double acc = 0.0;
  if (offset == 0.0) {
    for (int m = 0; m < kk; ++m) acc += plsm_frac_soft_step(C.phis[o + m], eps);
  } else {
    for (int m = 0; m < kk; ++m)
      acc += plsm_frac_soft_step(C.phis[o + m] + offset * C.psis[o + m], eps);
  }
  return acc / static_cast<double>(kk);
}

// ── the band: dfrac[v] = (1/k^3) SUM_s delta_q(phi_s) ───────────────────────
//
// This is d f_v / d(rigid shift of phi), up to sign, and it is what the
// sensitivity projects and what the constraint's measure rides. Units are 1/mm,
// the same as the old `DH_eta(phi)*|grad phi|`, so every downstream scale is
// unchanged.
inline void plsm_frac_band(const PlsmFracCache& C,
                           const std::vector<double>& gradscale, double h,
                           double eps_mult, std::vector<double>& dfrac,
                           int threads) {
  std::fill(dfrac.begin(), dfrac.end(), 0.0);
  const int kk = C.per_cell();
  plsm_frac_parallel(C.ncell, threads, [&](std::size_t s, int) {
    const std::size_t v = static_cast<std::size_t>(C.cell[s]);
    const double eps = plsm_frac_eps(gradscale[v], h, C.k, eps_mult);
    const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
    double acc = 0.0;
    for (int m = 0; m < kk; ++m) acc += plsm_frac_delta_q(C.phis[o + m], eps);
    dfrac[v] = acc / static_cast<double>(kk);
  });
}

// ── ★ THE PROJECTION, AND WHY IT IS A SCATTER AND NOT Psi^T ─────────────────
//
//     out_i += SUM_v w_v (1/k^3) SUM_s delta_q(phi_s) psi_i(x_s)
//
// `Psi` is built on the CELL-CENTRE lattice, so `Psi^T(w * dfrac)` evaluates
// psi_i at the centre and factors it out of the sub-cell sum. That is the ONLY
// difference between the two, and it is an approximation of exactly the kind
// this file exists to remove — so the exact form is the default and the centre
// form is kept reachable as an ablation with a MEASURED cost (§4(c)(i): 15
// percentage points on a general direction, nothing on a single coefficient).
//
// Two weight vectors are projected in ONE pass because the compliance and the
// volume sensitivities ride the SAME measure and differ only in `w` — the
// identity the whole level-set formulation rests on — so walking the samples
// twice would double the cost to compute the same delta_q.
inline void plsm_frac_scatter(const PlsmFracCache& C, int nx, int ny, int nz,
                              const PlsmKnotLattice& L, PlsmBasisKind basis,
                              const std::vector<double>& gradscale, double h,
                              double eps_mult, const std::vector<double>& wA,
                              std::vector<double>& outA,
                              const std::vector<double>& wB,
                              std::vector<double>& outB, int threads) {
  const std::size_t m = L.count();
  std::fill(outA.begin(), outA.end(), 0.0);
  std::fill(outB.begin(), outB.end(), 0.0);
  const int t = std::max(1, threads);
  std::vector<std::vector<double>> accA(static_cast<std::size_t>(t)),
      accB(static_cast<std::size_t>(t));
  for (int q = 0; q < t; ++q) {
    accA[static_cast<std::size_t>(q)].assign(m, 0.0);
    accB[static_cast<std::size_t>(q)].assign(m, 0.0);
  }
  const int kk = C.per_cell();
  const double invk3 = 1.0 / static_cast<double>(kk);
  const double inv = 1.0 / static_cast<double>(C.k);

  plsm_frac_parallel(C.ncell, t, [&](std::size_t s, int tid) {
    const std::size_t v = static_cast<std::size_t>(C.cell[s]);
    const double a = wA[v], b = wB[v];
    if (a == 0.0 && b == 0.0) return;
    const double eps = plsm_frac_eps(gradscale[v], h, C.k, eps_mult);
    const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
    // Cheap rejection: no sample of this cell is within the mollifier.
    bool any = false;
    for (int mm = 0; mm < kk && !any; ++mm)
      any = std::fabs(C.phis[o + mm]) < eps;
    if (!any) return;

    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int kz = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                         static_cast<std::size_t>(ny)));
    std::vector<double>& ga = accA[static_cast<std::size_t>(tid)];
    std::vector<double>& gb = accB[static_cast<std::size_t>(tid)];
    std::vector<int> idx;
    std::vector<double> ww;
    std::size_t oo = o;
    for (int r = 0; r < C.k; ++r) {
      const double z = kz + (r + 0.5) * inv - 0.5;
      for (int q2 = 0; q2 < C.k; ++q2) {
        const double y = j + (q2 + 0.5) * inv - 0.5;
        for (int p = 0; p < C.k; ++p, ++oo) {
          const double dq = plsm_frac_delta_q(C.phis[oo], eps);
          if (dq == 0.0) continue;
          const double x = i + (p + 0.5) * inv - 0.5;
          idx.clear();
          ww.clear();
          plsm_support_of(L, basis, x, y, z, idx, ww);
          const double ca = a * dq * invk3, cb = b * dq * invk3;
          for (std::size_t e = 0; e < idx.size(); ++e) {
            const std::size_t c = static_cast<std::size_t>(idx[e]);
            ga[c] += ca * ww[e];
            gb[c] += cb * ww[e];
          }
        }
      }
    }
  });

  for (int q = 0; q < t; ++q)
    for (std::size_t c = 0; c < m; ++c) {
      outA[c] += accA[static_cast<std::size_t>(q)][c];
      outB[c] += accB[static_cast<std::size_t>(q)][c];
    }
}

}  // namespace topopt

#endif  // TOPOPT_PLSM_FRAC_HPP_
