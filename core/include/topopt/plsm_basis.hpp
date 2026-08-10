// plsm_basis.hpp — THE PARAMETRIC LEVEL-SET BASIS, in core.
//
// phi(x) = sum_i alpha_i psi(|x - x_i|_R), with the knots on a lattice COARSER
// than the voxel grid. `alpha` is the design; the voxel field is a VALUE of it.
//
// ★ THIS FILE IS A MOVE OUT OF `core/tests/harness/plsm_basis.hpp`, NOT A
// REWRITE. Every function below was cut from that header — which PR 324 had
// already verified as a move out of `plsm_probe.cpp` — and pasted here with its
// comments. `core/tests/harness/plsm_basis.hpp` is now a SHIM over this file:
// it declares no basis of its own, so `plsm_probe`, `levelset_probe --plsm` and
// the production optimiser all fit and evaluate the SAME function, and there is
// exactly one implementation of it in the repository. The move is verified
// rather than asserted: `evidence/2026-08-10-parametric-level-set/s0_basis_move`
// holds `fits.csv` from before the move, and this task's `s0_core_move` diffs
// the current tree's against it.
//
// ★ WHY IT IS HEADER-ONLY AND DEPENDS ON NOTHING BUT <vector>. The harness
// includes it from INSIDE an anonymous namespace and has its own `Dims`; core
// has `VoxelGrid`. Taking three plain ints instead of either one is what lets a
// single implementation serve both without either of them learning about the
// other. Nothing in here knows what a voxel grid, a mask or a load is.
//
// ★ R4 — EVERY LENGTH IS PER AXIS. The knot spacing is three numbers and the
// support is an ELLIPSOID R_a = support * Delta_a. There is no minimum taken
// anywhere in this file, and `plsm_knots_for_grid` (plsm.hpp) is the one place
// that derives a spacing from a grid.

#ifndef TOPOPT_PLSM_BASIS_HPP_
#define TOPOPT_PLSM_BASIS_HPP_

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <thread>
#include <vector>

namespace topopt {

// ── the two bases ───────────────────────────────────────────────────────────
//
// Both are written as functions of the NORMALISED radius r = |x - x_i|_R, where
// |·|_R is the ellipsoidal norm with per-axis radii R_a. Both vanish at r >= 1,
// so the support test is the same test for both.
enum class PlsmBasisKind { Wendland, Gaussian };

// Wendland C²: (1-r)_+^4 (4r+1). Positive definite in R³ for this form.
inline double plsm_psi_wendland(double r) {
  if (r >= 1.0) return 0.0;
  const double t = 1.0 - r;
  const double t2 = t * t;
  return t2 * t2 * (4.0 * r + 1.0);
}

// A 3σ-truncated Gaussian: exp(-(3r)²/2), so r = 1 is three standard deviations
// and ψ(1) = 0.0111. Shifted to vanish exactly at r = 1 so the support test is
// exact and the basis is continuous — without the shift the truncation is a 1.1%
// step at the support boundary, which shows up as a faint lattice-periodic ripple
// in φ and therefore in the surface.
inline double plsm_psi_gaussian(double r) {
  if (r >= 1.0) return 0.0;
  constexpr double kEdge = 0.011108996538242306;  // exp(-4.5)
  return (std::exp(-4.5 * r * r) - kEdge) / (1.0 - kEdge);
}

inline double plsm_psi(PlsmBasisKind b, double r) {
  return b == PlsmBasisKind::Wendland ? plsm_psi_wendland(r) : plsm_psi_gaussian(r);
}

// ── the knot lattice: PER AXIS, and padded so the boundary is covered ───────
//
// Knots sit at voxel coordinate u_a = (m - pad_a) * Δ_a with m = 0 .. M_a-1, so
// one full knot ring lies OUTSIDE each face. Without the ring the outermost
// voxels are covered by only the inner half of a support and the fit degrades
// exactly where the CAD faces are — the population PR 324 R4 showed never moves,
// which is the last place we want a representation artefact.
struct PlsmKnotLattice {
  double dx = 4.0, dy = 4.0, dz = 4.0;   // spacing, VOXELS, per axis
  int mx = 0, my = 0, mz = 0;            // counts, per axis
  int padx = 1, pady = 1, padz = 1;
  double rx = 8.0, ry = 8.0, rz = 8.0;   // support radii, VOXELS, per axis

  std::size_t count() const {
    return static_cast<std::size_t>(mx) * static_cast<std::size_t>(my) *
           static_cast<std::size_t>(mz);
  }
  std::size_t at(int a, int b, int c) const {
    return static_cast<std::size_t>(a) +
           static_cast<std::size_t>(mx) *
               (static_cast<std::size_t>(b) +
                static_cast<std::size_t>(my) * static_cast<std::size_t>(c));
  }
  double ux(int a) const { return (a - padx) * dx; }
  double uy(int b) const { return (b - pady) * dy; }
  double uz(int c) const { return (c - padz) * dz; }
};

inline PlsmKnotLattice plsm_make_lattice(int nx, int ny, int nz, double dx,
                                         double dy, double dz, double support) {
  PlsmKnotLattice L;
  L.dx = dx; L.dy = dy; L.dz = dz;
  L.rx = support * dx; L.ry = support * dy; L.rz = support * dz;
  // Enough padding that every voxel on the far face is inside at least a full
  // ring of supports: ceil(support) rings, never fewer than one.
  L.padx = std::max(1, static_cast<int>(std::ceil(support)));
  L.pady = std::max(1, static_cast<int>(std::ceil(support)));
  L.padz = std::max(1, static_cast<int>(std::ceil(support)));
  L.mx = static_cast<int>(std::floor((nx - 1) / dx)) + 1 + 2 * L.padx;
  L.my = static_cast<int>(std::floor((ny - 1) / dy)) + 1 + 2 * L.pady;
  L.mz = static_cast<int>(std::floor((nz - 1) / dz)) + 1 + 2 * L.padz;
  return L;
}

// ── A, in CSR, plus its transpose ───────────────────────────────────────────
struct PlsmCsr {
  std::vector<std::size_t> row;   // size rows+1
  std::vector<int> col;
  std::vector<double> val;
  std::size_t rows = 0, cols = 0;
  std::size_t nnz() const { return val.size(); }
};

inline int plsm_hw_threads(int want) {
  if (want > 0) return want;
  const unsigned hc = std::thread::hardware_concurrency();
  return hc ? static_cast<int>(hc) : 1;
}

template <typename F>
void plsm_parallel_for(std::size_t n, int threads, F&& body) {
  const int t = std::max(1, threads);
  if (t == 1 || n < 4096) {
    for (std::size_t i = 0; i < n; ++i) body(i);
    return;
  }
  std::vector<std::thread> pool;
  pool.reserve(static_cast<std::size_t>(t));
  const std::size_t chunk = (n + static_cast<std::size_t>(t) - 1) /
                            static_cast<std::size_t>(t);
  for (int q = 0; q < t; ++q) {
    const std::size_t lo = static_cast<std::size_t>(q) * chunk;
    const std::size_t hi = std::min(n, lo + chunk);
    if (lo >= hi) break;
    pool.emplace_back([lo, hi, &body] {
      for (std::size_t i = lo; i < hi; ++i) body(i);
    });
  }
  for (auto& th : pool) th.join();
}

// The knots whose support contains the point at voxel coordinate (x,y,z),
// appended to `idx`/`w`. Shared by the CSR build and by the analytic evaluation
// on a refined lattice, so the fitted function and the extracted function are
// the same function by construction and not by inspection.
inline void plsm_support_of(const PlsmKnotLattice& L, PlsmBasisKind b, double x,
                            double y, double z, std::vector<int>& idx,
                            std::vector<double>& w) {
  const int a0 = std::max(0, static_cast<int>(std::ceil((x - L.rx) / L.dx)) + L.padx);
  const int a1 = std::min(L.mx - 1,
                          static_cast<int>(std::floor((x + L.rx) / L.dx)) + L.padx);
  const int b0 = std::max(0, static_cast<int>(std::ceil((y - L.ry) / L.dy)) + L.pady);
  const int b1 = std::min(L.my - 1,
                          static_cast<int>(std::floor((y + L.ry) / L.dy)) + L.pady);
  const int c0 = std::max(0, static_cast<int>(std::ceil((z - L.rz) / L.dz)) + L.padz);
  const int c1 = std::min(L.mz - 1,
                          static_cast<int>(std::floor((z + L.rz) / L.dz)) + L.padz);
  for (int c = c0; c <= c1; ++c) {
    const double dz3 = (z - L.uz(c)) / L.rz;
    const double z2 = dz3 * dz3;
    if (z2 >= 1.0) continue;
    for (int bb = b0; bb <= b1; ++bb) {
      const double dy3 = (y - L.uy(bb)) / L.ry;
      const double y2 = dy3 * dy3;
      if (y2 + z2 >= 1.0) continue;
      for (int a = a0; a <= a1; ++a) {
        const double dx3 = (x - L.ux(a)) / L.rx;
        const double r2 = dx3 * dx3 + y2 + z2;
        if (r2 >= 1.0) continue;
        const double v = plsm_psi(b, std::sqrt(r2));
        if (v == 0.0) continue;
        idx.push_back(static_cast<int>(L.at(a, bb, c)));
        w.push_back(v);
      }
    }
  }
}

inline PlsmCsr plsm_build_A(int nx, int ny, int nz, const PlsmKnotLattice& L,
                            PlsmBasisKind b, int threads) {
  PlsmCsr A;
  A.rows = static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) *
           static_cast<std::size_t>(nz);
  A.cols = L.count();
  A.row.assign(A.rows + 1, 0);

  // Pass 1: count, in parallel, so the row pointers are exact before any
  // allocation and the build never reallocates a 10⁷-entry vector.
  std::vector<int> per_row(A.rows, 0);
  plsm_parallel_for(A.rows, threads, [&](std::size_t v) {
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    std::vector<int> idx;
    std::vector<double> w;
    plsm_support_of(L, b, i, j, k, idx, w);
    per_row[v] = static_cast<int>(idx.size());
  });
  for (std::size_t v = 0; v < A.rows; ++v)
    A.row[v + 1] = A.row[v] + static_cast<std::size_t>(per_row[v]);
  A.col.resize(A.row[A.rows]);
  A.val.resize(A.row[A.rows]);

  plsm_parallel_for(A.rows, threads, [&](std::size_t v) {
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    std::vector<int> idx;
    std::vector<double> w;
    plsm_support_of(L, b, i, j, k, idx, w);
    std::size_t p = A.row[v];
    for (std::size_t q = 0; q < idx.size(); ++q, ++p) {
      A.col[p] = idx[q];
      A.val[p] = w[q];
    }
  });
  return A;
}

// The transpose, so BOTH applies are row-parallel and neither needs an atomic.
inline PlsmCsr plsm_transpose(const PlsmCsr& A, int threads) {
  PlsmCsr T;
  T.rows = A.cols;
  T.cols = A.rows;
  T.row.assign(T.rows + 1, 0);
  std::vector<std::size_t> cnt(T.rows, 0);
  for (std::size_t p = 0; p < A.nnz(); ++p)
    ++cnt[static_cast<std::size_t>(A.col[p])];
  for (std::size_t r = 0; r < T.rows; ++r) T.row[r + 1] = T.row[r] + cnt[r];
  T.col.resize(A.nnz());
  T.val.resize(A.nnz());
  std::vector<std::size_t> head(T.row.begin(), T.row.end() - 1);
  for (std::size_t r = 0; r < A.rows; ++r)
    for (std::size_t p = A.row[r]; p < A.row[r + 1]; ++p) {
      const std::size_t c = static_cast<std::size_t>(A.col[p]);
      T.col[head[c]] = static_cast<int>(r);
      T.val[head[c]] = A.val[p];
      ++head[c];
    }
  (void)threads;
  return T;
}

inline void plsm_spmv(const PlsmCsr& M, const std::vector<double>& x,
                      std::vector<double>& y, int threads) {
  plsm_parallel_for(M.rows, threads, [&](std::size_t r) {
    double s = 0.0;
    for (std::size_t p = M.row[r]; p < M.row[r + 1]; ++p)
      s += M.val[p] * x[static_cast<std::size_t>(M.col[p])];
    y[r] = s;
  });
}

inline double plsm_dot(const std::vector<double>& a, const std::vector<double>& b) {
  // Serial and in one order, so a fit is reproducible run to run. The vectors
  // here are 10³-10⁵ long; this is not where the time goes.
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += a[i] * b[i];
  return s;
}

struct PlsmFitResult {
  std::vector<double> alpha;
  int cg_iters = 0;
  double rel_resid = 0.0;
};

// Jacobi-preconditioned CG on (AᵀWA + λI) α = AᵀW φ̃.
//
// ★ W IS NOT COSMETIC AND IT IS NOT FREE. Only the ZERO SET of φ has geometry:
// a coefficient spent matching the distance function six voxels into the void
// buys nothing the surface can see. `w` weights the band up, so the fit puts its
// error where it costs least. The band residual and the whole-domain residual are
// BOTH reported for every fit, so the trade is visible and the weight cannot hide
// inside an average. W = 1 turns it off and is the honest default.
inline PlsmFitResult plsm_solve_normal(const PlsmCsr& A, const PlsmCsr& At,
                                       const std::vector<double>& rhs_f,
                                       const std::vector<double>& w, double lambda,
                                       int max_iters, double tol, int threads) {
  const std::size_t m = A.cols;
  PlsmFitResult out;
  out.alpha.assign(m, 0.0);

  std::vector<double> diag(m, 0.0);
  for (std::size_t r = 0; r < At.rows; ++r) {
    double s = 0.0;
    for (std::size_t p = At.row[r]; p < At.row[r + 1]; ++p)
      s += At.val[p] * At.val[p] * w[static_cast<std::size_t>(At.col[p])];
    diag[r] = s + lambda;
  }
  for (std::size_t i = 0; i < m; ++i)
    if (!(diag[i] > 0.0)) diag[i] = 1.0;  // a knot no sample can see

  std::vector<double> b(m, 0.0), r(m), z(m), p(m), Ap(m), tmp(A.rows);
  {
    std::vector<double> wf(A.rows);
    for (std::size_t i = 0; i < A.rows; ++i) wf[i] = w[i] * rhs_f[i];
    plsm_spmv(At, wf, b, threads);
  }

  r = b;
  for (std::size_t i = 0; i < m; ++i) z[i] = r[i] / diag[i];
  p = z;
  const double bnorm = std::sqrt(plsm_dot(b, b));
  double rz = plsm_dot(r, z);
  const double target = tol * (bnorm > 0.0 ? bnorm : 1.0);

  for (int it = 0; it < max_iters; ++it) {
    const double rn = std::sqrt(plsm_dot(r, r));
    out.rel_resid = bnorm > 0.0 ? rn / bnorm : rn;
    if (rn <= target) { out.cg_iters = it; return out; }
    plsm_spmv(A, p, tmp, threads);
    for (std::size_t i = 0; i < tmp.size(); ++i) tmp[i] *= w[i];
    plsm_spmv(At, tmp, Ap, threads);
    for (std::size_t i = 0; i < m; ++i) Ap[i] += lambda * p[i];
    const double pAp = plsm_dot(p, Ap);
    if (!(pAp > 0.0)) { out.cg_iters = it; return out; }
    const double a = rz / pAp;
    for (std::size_t i = 0; i < m; ++i) out.alpha[i] += a * p[i];
    for (std::size_t i = 0; i < m; ++i) r[i] -= a * Ap[i];
    for (std::size_t i = 0; i < m; ++i) z[i] = r[i] / diag[i];
    const double rz1 = plsm_dot(r, z);
    const double beta = rz1 / rz;
    rz = rz1;
    for (std::size_t i = 0; i < m; ++i) p[i] = z[i] + beta * p[i];
    out.cg_iters = it + 1;
  }
  return out;
}

// φ from α, on ANY lattice — the F-refined one included. The surface is
// extracted from THIS, never from a resample of it.
inline std::vector<double> plsm_evaluate(const PlsmKnotLattice& L, PlsmBasisKind b,
                                         const std::vector<double>& alpha, int nx,
                                         int ny, int nz, int factor, int threads) {
  std::vector<double> out(static_cast<std::size_t>(nx) *
                              static_cast<std::size_t>(ny) *
                              static_cast<std::size_t>(nz),
                          0.0);
  const double inv = 1.0 / factor;
  plsm_parallel_for(out.size(), threads, [&](std::size_t v) {
    const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
    const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                   static_cast<std::size_t>(ny));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                        static_cast<std::size_t>(ny)));
    // The COARSE-voxel coordinate of this fine sample: mesh.cpp's own
    // u = (m + 0.5)/F - 0.5, which is the identity when F = 1.
    const double x = (i + 0.5) * inv - 0.5;
    const double y = (j + 0.5) * inv - 0.5;
    const double z = (k + 0.5) * inv - 0.5;
    const int a0 = std::max(0, static_cast<int>(std::ceil((x - L.rx) / L.dx)) + L.padx);
    const int a1 = std::min(L.mx - 1,
                            static_cast<int>(std::floor((x + L.rx) / L.dx)) + L.padx);
    const int b0 = std::max(0, static_cast<int>(std::ceil((y - L.ry) / L.dy)) + L.pady);
    const int b1 = std::min(L.my - 1,
                            static_cast<int>(std::floor((y + L.ry) / L.dy)) + L.pady);
    const int c0 = std::max(0, static_cast<int>(std::ceil((z - L.rz) / L.dz)) + L.padz);
    const int c1 = std::min(L.mz - 1,
                            static_cast<int>(std::floor((z + L.rz) / L.dz)) + L.padz);
    double s = 0.0;
    for (int c = c0; c <= c1; ++c) {
      const double dz3 = (z - L.uz(c)) / L.rz;
      const double z2 = dz3 * dz3;
      if (z2 >= 1.0) continue;
      for (int bb = b0; bb <= b1; ++bb) {
        const double dy3 = (y - L.uy(bb)) / L.ry;
        const double y2 = dy3 * dy3;
        if (y2 + z2 >= 1.0) continue;
        for (int a = a0; a <= a1; ++a) {
          const double dx3 = (x - L.ux(a)) / L.rx;
          const double r2 = dx3 * dx3 + y2 + z2;
          if (r2 >= 1.0) continue;
          s += alpha[L.at(a, bb, c)] * plsm_psi(b, std::sqrt(r2));
        }
      }
    }
    out[v] = s;
  });
  return out;
}

}  // namespace topopt

#endif  // TOPOPT_PLSM_BASIS_HPP_
