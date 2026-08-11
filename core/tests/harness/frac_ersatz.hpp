// frac_ersatz.hpp — ★ THE ERSATZ DENSITY AS THE EXACT VOLUME FRACTION OF THE
// CELL THAT LIES INSIDE {φ < 0}, AND THE SENSITIVITY THAT MATCHES IT.
//
// ── WHAT THIS REPLACES ──────────────────────────────────────────────────────
//
// Every level-set arm in PR 322/323/324/325/326 built its ersatz density by
// SAMPLING A SMOOTHED HEAVISIDE AT THE CELL CENTRE:
//
//     ρ_e = ρ_min + (1 − ρ_min) · H_η(−φ(x_centre)),   η = 2 voxels
//
// That is a smeared stand-in for the quantity below, and PR 326 §3(e) swept η
// for the first time in this line of work and found the OPTIMISATION strongly
// sensitive to it — halving η removed a further 11.7% of the internal surface.
// Every one of those sweeps was tuning a proxy. This header computes the thing
// itself:
//
//     ρ_e = ρ_min + (1 − ρ_min) · f_v,
//     f_v = (1/|C_v|) ∫_{C_v} 1[φ(x) < 0] dx
//
// ★ ONLY ρ_e CHANGES. For an isotropic ersatz the cell stiffness is ρ_e·K0, so
// the 24×24 reference block, the matrix-free stencil, the geometric multigrid,
// GenEO, Krylov recycling and the Galerkin block cache are all untouched: no
// per-cell Ke, no O(cut cells) storage, no cache-key change. What is bought is
// that ρ_e now carries SUB-VOXEL BOUNDARY POSITION — it varies continuously as
// the interface moves inside a cell, instead of jumping when the boundary
// crosses the cell centre.
//
// ── (a) HOW f_v IS COMPUTED: SUB-CELL SAMPLING, NOT AN ANALYTIC INTEGRAL ────
//
// φ is a sum of compactly-supported RBFs; the exact polyhedral intersection of
// its zero set with a cube is not worth writing. f_v is the fraction of a k×k×k
// lattice of points inside the cell with φ < 0. Sample (p,q,r) of cell (i,j,k)
// sits at voxel coordinate
//
//     x = i + (p + 0.5)/k − 0.5
//
// which is EXACTLY where `plsm_evaluate(..., factor = k)` puts its sample, and
// exactly where `resample_field`/`marching_cubes_resampled` put theirs. The
// sub-cell lattice and the export lattice are the same lattice; there is no
// second convention in this file.
//
// ── (b) ONLY THE CELLS THAT CAN BE CUT ARE SAMPLED ──────────────────────────
//
// A cell that is `Empty`, `FrozenSolid` or `FrozenVoid` is stamped 0 or 1 by the
// mask and the optimiser never had any say over it. On his part that is 397,536
// of 468,224 voxels, so only the 70,688 ACTIVE cells are ever sampled — and of
// those, the ones actually CUT (mixed sample signs) are counted and reported
// every iteration rather than estimated. `n_boundary` is that count.
//
// ── (c) ★ THE SENSITIVITY, WHICH IS THE PART THAT CAN WASTE THE RUN ─────────
//
// The old density's derivative was DH_η(φ)·|∇φ|·ψ_i. Leaving that in place
// against this density would be a mismatched gradient: it would look like slow
// convergence and would be believed. The derivative of f_v is a SURFACE
// integral over the part of the interface inside the cell,
//
//     ∂f_v/∂α_i = −(1/|C_v|) ∫_{Γ ∩ C_v} ψ_i / |∇φ| dS
//               = −(1/|C_v|) ∫_{C_v} δ(φ(x)) ψ_i(x) dx          [co-area]
//
// and the second form is what is discretised, on the SAME sub-cell lattice:
//
//     ∂f_v/∂α_i ≈ −(1/k³) Σ_s δ_q(φ_s) ψ_i(x_s)
//
// with δ_q a NORMALISED tent, ∫δ_q = 1, of half-width
//
//     ★ ε_q = eps_mult · |∇φ|_v · h/k        THE QUADRATURE BANDWIDTH
//
// ── ★ WHY ε_q IS NOT η WEARING A DIFFERENT HAT, WHICH IS THE OBVIOUS OBJECTION
//
// η is a PHYSICAL smearing of the material: it is fixed at 2 voxels, it appears
// in the density the solver sees, and it does not shrink with anything. ε_q
// appears in NO density — f_v is a hard count of sample signs — and it is tied
// to the sample spacing, so it shrinks like 1/k. It is the width of a quadrature
// mollifier, chosen so the sum is neither aliased nor blurred:
//
//   * φ changes by about |∇φ|·h/k between adjacent samples along the normal, so
//     a tent of exactly that half-width is the NARROWEST one that still has a
//     sample in it wherever the interface is. Narrower aliases (the sum jumps as
//     the interface passes between two samples); wider blurs.
//   * at eps_mult = 1 and a locally planar interface the tent is a partition of
//     unity along the normal — Σ_m (1 − |t − mΔ|/Δ)/Δ = 1/Δ EXACTLY, for every
//     offset of the interface — so the estimator is smooth in α by construction
//     rather than by averaging.
//
// It is a knob only in the sense that `eps_mult` exists to be swept; the default
// is derived, and R4's finite-difference check is run at several values so the
// choice is a measurement.
//
// ── ★ AND THE WART THAT IS NOT SOLVED, STATED HERE RATHER THAN FOUND LATER ──
//
// f_v is a HARD count of sample signs, so it is PIECEWISE CONSTANT in α: it
// jumps by 1/k³ whenever one sample crosses. Its derivative is therefore zero
// almost everywhere and the analytic sensitivity above is the derivative of the
// CONTINUUM quantity f_v approximates, not of the number the solver is handed.
// That is exactly the shape of PR 326's P2 (a hard-count volume constraint with
// a smoothed derivative). It is measured, not argued: R4's finite differences
// are run at several step sizes so the staircase is visible, and the
// consistently-mollified variant that removes it is built beside this one
// (`--frac-soft`) and compared.
//
// ── WHAT IS DELIBERATELY NOT IN HERE ────────────────────────────────────────
//
// No basis. `plsm_support_of` is core's, invoked at arbitrary points, so the φ
// sampled here is the same function `plsm_evaluate` extracts and the fit fits.
// No FEA, no MMA, no export. This header samples a field and projects a measure
// onto the basis; everything else stays in `levelset_probe.cpp`.
//
// Included INSIDE an anonymous namespace, like `levelset_kernel.hpp`; the guard
// below is the ordinary double-inclusion one.

#ifndef TOPOPT_TESTS_HARNESS_FRAC_ERSATZ_HPP_
#define TOPOPT_TESTS_HARNESS_FRAC_ERSATZ_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <thread>
#include <vector>

// ── the normalised quadrature mollifier ─────────────────────────────────────
//
// A tent of half-width eps, ∫ = 1. Linear rather than the raised cosine `H_η`
// differentiates to, BECAUSE of the partition-of-unity property above: the
// cosine bell is not a partition of unity at any sampling and would leave a
// ripple in the sum as the interface slides between samples.
inline double frac_delta_q(double t, double eps) {
  const double a = std::fabs(t);
  if (a >= eps) return 0.0;
  return (1.0 - a / eps) / eps;
}

// ── the sample cache ────────────────────────────────────────────────────────
//
// Built ONCE per iteration, after the volume offset has been folded into α and
// φ resynced, and read by the density, by the volume diagnostics, by the band
// and by the sensitivity. The two arrays are φ and Σ_i ψ_i at every sample; the
// second is what a rigid offset of the level set moves φ by in the parametric
// mode (`off_shape`), so an offset can be applied to the cache without
// re-evaluating the basis.
struct FracCache {
  int k = 0;
  std::size_t ncell = 0;                 // ACTIVE cells sampled
  std::vector<int> cell;                 // slot -> voxel index
  std::vector<int> slot;                 // voxel index -> slot, or -1
  std::vector<double> phis;              // ncell * k^3, φ at the sample
  std::vector<double> psis;              // ncell * k^3, Σ_i ψ_i at the sample
  // ── the statistics S1(b) asks for, counted rather than bounded
  std::size_t n_boundary = 0;            // cells with MIXED sample signs
  std::size_t n_full = 0, n_empty = 0;   // all samples in / all out
  double build_s = 0.0;                  // wall clock of the last build

  int per_cell() const { return k * k * k; }
};

// A plain chunked parallel-for that hands the body its THREAD INDEX, which
// `plsm_parallel_for` does not. The scatter below needs per-thread accumulators
// over the 85,680 coefficients and an atomic per knot would serialise it.
template <typename F>
void frac_parallel(std::size_t n, int threads, F&& body) {
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
inline void frac_build(const Dims& d, const topopt::PlsmKnotLattice& L,
                       topopt::PlsmBasisKind basis,
                       const std::vector<double>& alpha,
                       const std::vector<char>& sample, int k, int threads,
                       FracCache& C) {
  const double t0 = now_s();
  const std::size_t n = d.count();
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

  frac_parallel(C.ncell, threads, [&](std::size_t s, int) {
    const std::size_t v = static_cast<std::size_t>(C.cell[s]);
    const int i = static_cast<int>(v % static_cast<std::size_t>(d.nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(d.nx)) %
                                   static_cast<std::size_t>(d.ny));
    const int kz = static_cast<int>(v / (static_cast<std::size_t>(d.nx) *
                                         static_cast<std::size_t>(d.ny)));
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
          topopt::plsm_support_of(L, basis, x, y, z, idx, w);
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
  C.build_s = now_s() - t0;
}

// A rigid offset of the level set, applied to the cache in place. φ = Ψα, so
// α_i += c for every i moves φ by c·Σψ EXACTLY — which is the `off_shape` the
// volume bisection already uses. Applying it here costs one pass and saves a
// rebuild.
inline void frac_shift(FracCache& C, double offset) {
  if (offset == 0.0) return;
  for (std::size_t o = 0; o < C.phis.size(); ++o)
    C.phis[o] += offset * C.psis[o];
}

// f_v — the fraction of the cell inside {φ < 0}. Cells outside the cache are
// not this header's: the caller stamps them.
inline double frac_of(const FracCache& C, std::size_t v) {
  const int s = C.slot[v];
  if (s < 0) return -1.0;
  const int kk = C.per_cell();
  const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
  int in = 0;
  for (int m = 0; m < kk; ++m) in += C.phis[o + m] < 0.0 ? 1 : 0;
  return static_cast<double>(in) / static_cast<double>(kk);
}

// ★ THE CONSISTENTLY-MOLLIFIED VARIANT (`--frac-soft`). The same sub-cell
// quadrature with the hard indicator replaced by H_{ε_q} at the SAME bandwidth
// the sensitivity uses. It is the exact volume fraction to the same O(1/k) as
// the hard count, its derivative is the analytic one to machine precision, and
// it removes the piecewise-constant wart named at the top. ε_q shrinks like 1/k,
// so this is NOT a return to η: it converges to the indicator, which η never
// does.
// The per-sample smoothed step. It is EXACTLY the antiderivative of the tent
// δ_q the sensitivity uses, reflected: S(t) = ∫_t^∞ δ_q. Deriving it from the
// mollifier rather than picking a second smoothing law is the whole point —
// dS/dt = −δ_q(t) identically, so the value and the gradient are two facts about
// ONE function and the finite difference has nothing to reveal.
//
//     S(t) = 1                      t ≤ −ε
//            0.5 − u + u|u|/2       |t| < ε,  u = t/ε
//            0                      t ≥ ε
inline double frac_soft_step(double t, double eps) {
  if (t <= -eps) return 1.0;
  if (t >= eps) return 0.0;
  const double u = t / eps;
  return 0.5 - u + 0.5 * u * std::fabs(u);
}

inline double frac_of_soft(const FracCache& C, std::size_t v, double eps) {
  const int s = C.slot[v];
  if (s < 0) return -1.0;
  const int kk = C.per_cell();
  const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
  double acc = 0.0;
  for (int m = 0; m < kk; ++m) acc += frac_soft_step(C.phis[o + m], eps);
  return acc / static_cast<double>(kk);
}

// The per-cell quadrature bandwidth, in the same units as φ (mm).
//
// ★ CLAMPED FROM BELOW, and the clamp is not cosmetic. |∇φ| is a central
// difference and it is small on the medial axis, where the exact distance
// function of any solid has a kink (PR 324 documents the same statistic
// saturating at 1.0 for exactly that reason). A vanishing ε_q there would make
// the mollifier a spike between samples and the sum would alias badly. The floor
// is a tenth of the isotropic sample spacing.
// ★ AND `gradscale` IS THE L1 NORM OF grad phi, NOT THE L2 NORM, WHEN
// `--frac-eps-l1` IS ARMED — WHICH IS A DEFECT IN THE FIRST VERSION OF THIS
// FILE THAT THE LITERATURE FOUND FOR ME. ARM 2, §5 M5.
//
// The partition-of-unity argument at the top of this file is exactly right for
// an interface whose normal is a GRID AXIS, and only then: along the axis the
// sample spacing in phi is |grad phi| * h/k, the tent at that half-width tiles,
// and the estimator is exact for every position of the interface. For an
// OBLIQUE interface the k^3 samples project onto the normal at spacings that are
// not the axis spacing, the tent no longer tiles, and the error does not vanish
// with refinement.
//
// Engquist, Tornberg & Tsai (JCP 207(1):28-51, 2005) prove exactly this and give
// the fix. Their §3-4: an implicit mollifier delta_eps(phi) whose bandwidth
// scales with |grad phi|_2 is NOT CONVERGENT in two or more dimensions — their
// closed-form counterexample is a straight line at 45 degrees, where the narrow
// hat at eps = h leaves a 12.1% error that does not decrease with h. Scaling
// instead by the L1 norm,
//
//     eps_q = eps_0 * (h/k) * (|phi_x| + |phi_y| + |phi_z|)
//
// makes it FIRST ORDER, and their Theorem 4 is the reason it is the right norm
// rather than a tuned one: for a plane orthogonal to a relatively prime (p,q,r),
// the hat with half-width (p+q+r)/sqrt(p^2+q^2+r^2) sample spacings gives the
// EXACT area, invariant under translation of the interface relative to the
// lattice. That ratio IS |n|_1 / |n|_2, and multiplying through by |grad phi|_2
// to get back into phi-units leaves |grad phi|_1 exactly.
//
// The two norms coincide on an axis-aligned interface and differ by up to
// sqrt(3) on a diagonal one, so the original choice was systematically NARROW,
// worst on exactly the oblique surfaces this part is mostly made of.
//
// ★ IT IS A FLAG AND IT DEFAULTS OFF, so ARM 1's arithmetic is unchanged by
// inspection and the arms that were already running are still the arms that were
// finite-differenced. Its cost is measured against the L2 version on the same
// design, with the same probe, in §5 M5.
inline double frac_eps(double gradscale, double h, int k, double eps_mult) {
  const double sp = h / static_cast<double>(k);
  return std::max(0.1 * sp, eps_mult * gradscale * sp);
}

// |grad phi|_1, central differences, the same stencil `grad_mag` uses for the
// L2 norm. Held beside it rather than replacing it: the L2 norm is still what
// converts the quadrature band into an interface AREA (co-area), and only the
// BANDWIDTH moves to L1.
inline double frac_grad_l1(const Dims& d, const std::vector<double>& phi, int i,
                           int j, int k, double h) {
  auto P = [&](int A, int B, int C) {
    A = std::min(std::max(A, 0), d.nx - 1);
    B = std::min(std::max(B, 0), d.ny - 1);
    C = std::min(std::max(C, 0), d.nz - 1);
    return phi[d.at(A, B, C)];
  };
  const double gx = (P(i + 1, j, k) - P(i - 1, j, k)) / (2.0 * h);
  const double gy = (P(i, j + 1, k) - P(i, j - 1, k)) / (2.0 * h);
  const double gz = (P(i, j, k + 1) - P(i, j, k - 1)) / (2.0 * h);
  return std::fabs(gx) + std::fabs(gy) + std::fabs(gz);
}

// ── the band: dfrac[v] = (1/k³) Σ_s δ_q(φ_s) ───────────────────────────────
//
// This is ∂f_v/∂(rigid shift of φ), up to sign, and it is what the sensitivity
// projects and what λ is weighted by. Units are 1/mm, the same as the old
// `DH_η(φ)·|∇φ|`, so ell = C·λ·h and every downstream scale is unchanged.
inline void frac_band(const FracCache& C, const std::vector<double>& gradmag,
                      double h, double eps_mult, std::vector<double>& dfrac,
                      int threads) {
  std::fill(dfrac.begin(), dfrac.end(), 0.0);
  const int kk = C.per_cell();
  frac_parallel(C.ncell, threads, [&](std::size_t s, int) {
    const std::size_t v = static_cast<std::size_t>(C.cell[s]);
    const double eps = frac_eps(gradmag[v], h, C.k, eps_mult);
    const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
    double acc = 0.0;
    for (int m = 0; m < kk; ++m) acc += frac_delta_q(C.phis[o + m], eps);
    dfrac[v] = acc / static_cast<double>(kk);
  });
}

// ── ★ THE PROJECTION, AND WHY IT IS A SCATTER AND NOT Ψᵀ ────────────────────
//
//     out_i += Σ_v w_v (1/k³) Σ_s δ_q(φ_s) ψ_i(x_s)
//
// Ψ is built on the CELL-CENTRE lattice, so Ψᵀ(w·dfrac) evaluates ψ_i at the
// centre and factors it out of the sub-cell sum. That is the ONLY difference
// between the two, and it is an approximation of exactly the kind this task
// exists to remove — so the exact form is the default and the centre form is
// kept reachable (`--frac-sens centre`) as an ablation with a measured cost.
//
// Two weight vectors are projected in one pass because the compliance and the
// volume sensitivities ride the SAME measure and differ only in w — the identity
// the whole level-set formulation rests on — so walking the samples twice would
// double the cost to compute the same δ_q.
inline void frac_scatter(const FracCache& C, const Dims& d,
                         const topopt::PlsmKnotLattice& L,
                         topopt::PlsmBasisKind basis,
                         const std::vector<double>& gradmag, double h,
                         double eps_mult, const std::vector<double>& wA,
                         std::vector<double>& outA, const std::vector<double>& wB,
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

  frac_parallel(C.ncell, t, [&](std::size_t s, int tid) {
    const std::size_t v = static_cast<std::size_t>(C.cell[s]);
    const double a = wA[v], b = wB[v];
    if (a == 0.0 && b == 0.0) return;
    const double eps = frac_eps(gradmag[v], h, C.k, eps_mult);
    const std::size_t o = static_cast<std::size_t>(s) * static_cast<std::size_t>(kk);
    // Cheap rejection: no sample of this cell is within the mollifier.
    bool any = false;
    for (int mm = 0; mm < kk && !any; ++mm)
      any = std::fabs(C.phis[o + mm]) < eps;
    if (!any) return;

    const int i = static_cast<int>(v % static_cast<std::size_t>(d.nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(d.nx)) %
                                   static_cast<std::size_t>(d.ny));
    const int kz = static_cast<int>(v / (static_cast<std::size_t>(d.nx) *
                                         static_cast<std::size_t>(d.ny)));
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
          const double dq = frac_delta_q(C.phis[oo], eps);
          if (dq == 0.0) continue;
          const double x = i + (p + 0.5) * inv - 0.5;
          idx.clear();
          ww.clear();
          topopt::plsm_support_of(L, basis, x, y, z, idx, ww);
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

// ── ★ THE EXPORT CONVENTION, AS A SEPARATE AND NAMED AXIS ───────────────────
//
// The emitted occupancy at refinement F is `H_eta(-phi)` sampled at the fine
// cell CENTRE, and that is what every arm since PR 322 has been extracted from.
// It is kept as the row of record (R5) — but it is the same substitution this
// task removed from the density, made in the export instead, and it deserves the
// same treatment. This writes the FRACTION of each FINE cell (side h/F) inside
// {phi < 0}, by k sub-samples per axis of the analytic phi.
//
// ★ AND THE PREDICTION IS WRITTEN DOWN BEFORE IT IS MEASURED, because it is not
// the obvious one. Marching cubes interpolates LINEARLY between adjacent sampled
// values to place a vertex on an edge. `H_eta` at eta = 2 voxels is a ramp four
// voxels wide, so its values carry sub-voxel position over a wide neighbourhood.
// A volume fraction SATURATES at 0 and 1 within about a half-cell of the
// interface, so on a crossing edge both endpoints are more often near 0 and 1 —
// which is exactly the condition PR 324 §3's band control showed MANUFACTURES a
// staircase. So the fraction is the more faithful field and may well be the
// WORSE one to hand marching cubes. That is worth measuring rather than assuming
// in either direction.
//
// No cache: this is a one-off at the end of a run and the fine lattices are
// large (F=2, k=4 is 240 million evaluations), so nothing is stored.
inline void frac_export_field(const topopt::PlsmKnotLattice& L,
                              topopt::PlsmBasisKind basis,
                              const std::vector<double>& alpha, int fx, int fy,
                              int fz, int F, int k, std::vector<double>& out,
                              int threads) {
  out.assign(static_cast<std::size_t>(fx) * static_cast<std::size_t>(fy) *
                 static_cast<std::size_t>(fz),
             0.0);
  const double invF = 1.0 / static_cast<double>(F);
  const double invFk = 1.0 / static_cast<double>(F * k);
  const int kk = k * k * k;
  frac_parallel(out.size(), threads, [&](std::size_t v, int) {
    const int i = static_cast<int>(v % static_cast<std::size_t>(fx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(fx)) %
                                   static_cast<std::size_t>(fy));
    const int kz = static_cast<int>(v / (static_cast<std::size_t>(fx) *
                                         static_cast<std::size_t>(fy)));
    // The COARSE-voxel coordinate of this FINE cell's centre, then of each of
    // its sub-samples. `plsm_evaluate` puts fine sample m at (m+0.5)/F - 0.5;
    // sub-sample p of it sits at (m*k + p + 0.5)/(F*k) - 0.5, which is the same
    // rule one level down and is why the two lattices nest exactly.
    std::vector<int> idx;
    std::vector<double> w;
    int in = 0;
    for (int r = 0; r < k; ++r) {
      const double z = (kz * k + r + 0.5) * invFk - 0.5;
      for (int q = 0; q < k; ++q) {
        const double y = (j * k + q + 0.5) * invFk - 0.5;
        for (int p = 0; p < k; ++p) {
          const double x = (i * k + p + 0.5) * invFk - 0.5;
          idx.clear();
          w.clear();
          topopt::plsm_support_of(L, basis, x, y, z, idx, w);
          double s = 0.0;
          for (std::size_t m = 0; m < idx.size(); ++m)
            s += alpha[static_cast<std::size_t>(idx[m])] * w[m];
          in += s < 0.0 ? 1 : 0;
        }
      }
    }
    (void)invF;
    out[v] = static_cast<double>(in) / static_cast<double>(kk);
  });
}

#endif  // TOPOPT_TESTS_HARNESS_FRAC_ERSATZ_HPP_
