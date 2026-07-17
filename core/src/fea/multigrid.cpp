// Geometric-multigrid-preconditioned Conjugate Gradient solver for the voxel
// FEA linear system Ku=f (handoff 072). The Jacobi-preconditioned CG in
// assembly.cpp averages ~550 iterations at 64^3; the profile (handoff 071)
// named geometric multigrid as the 10-100x lever. This file implements a
// standard V-cycle multigrid used as the CG preconditioner (MG-preconditioned
// CG), the robust choice for SIMP FEA.
//
// Design (justified in docs/handoffs/072-geometric-multigrid-solver.md):
//   * Hierarchy — vertex (node) coarsening by 2x per axis: a coarse node
//     coincides with every other fine node. Trilinear interpolation is the
//     prolongation P (coarse -> fine); restriction is its transpose R = P^T
//     (full weighting) — the variational pair.
//   * Coarse operator — GALERKIN A_c = P^T A P (rediscretisation is cheaper but
//     less robust under the SIMP soft-void modulus contrast rho_min^p; Galerkin
//     inherits the density-graded stiffness automatically, which is why it is
//     the standard robust choice and the one the task calls for).
//   * Smoother — damped Jacobi (omega=0.6, 2 pre + 2 post sweeps). Symmetric
//     smoother + equal pre/post sweeps + R=P^T + SPD coarse solve => the V-cycle
//     is a symmetric positive-definite operator, so it is a valid CG
//     preconditioner.
//   * Dirichlet BCs and void DOFs — the hierarchy is built on the SAME BC-reduced,
//     void-gated operator the Jacobi-CG path solves (fea_detail::assemble_reduced
//     + void_dof_survivors). A coarse node-DOF is active iff its coincident fine
//     node-DOF is active, so fixed/void DOFs propagate up every level.
//   * Coarsest level — solved exactly with a cached SimplicialLDLT factorisation.
//
// CORRECTNESS: MG-CG solves the identical reduced system Kgg u = rg as
// fea_solve_cg, to the same relative-residual tolerance, so it converges to the
// same u. If the hierarchy cannot be built (grid not 2x-divisible, coarsest too
// large) or MG-CG fails to converge / produces a non-finite field, the solver
// FALLS BACK to the exact Jacobi-CG path rather than return a wrong or
// unconverged answer.

#include "topopt/fea.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <memory>
#include <stdexcept>
#include <utility>
#include <vector>

#include <Eigen/IterativeLinearSolvers>
#include <Eigen/SparseCholesky>
#include <Eigen/SparseCore>

#include "fea_matfree.hpp"
#include "fea_reduced.hpp"

namespace topopt {

namespace {

using fea_detail::ReducedSystem;
using fea_detail::SpMat;
using fea_detail::Vec;
using Trip = Eigen::Triplet<double>;

// --- Multigrid tuning constants ------------------------------------------
constexpr double kJacobiOmega = 0.6;   // damped-Jacobi smoother weight
constexpr int kPreSmooth = 1;          // pre-smoothing sweeps (== post: SPD V-cycle)
constexpr int kPostSmooth = 1;         // 1+1 is the most wall-efficient on these grids
constexpr int kMinCoarseElems = 2;     // stop coarsening below this many elems/axis
constexpr int kCoarseDofCap = 6000;    // coarsest solved directly; cap its size
constexpr int kMinLevels = 2;          // < 2 usable levels -> not worth MG, fall back

// MG-CG iteration budget before giving up and falling back to Jacobi-CG. On
// well-conditioned / coherent SIMP fields MG-CG converges in ~10-30 iterations;
// under adversarial random high-contrast coefficients geometric MG degrades and
// can need thousands of iterations (much SLOWER than Jacobi). Rather than grind
// through that, bail after this budget and let the exact Jacobi-CG fallback
// finish. A well-posed V-cycle either converges fast (mesh-independent, ~15-30
// iterations on these grids) or stagnates; there is no legitimate "needs 100+"
// regime, so this bounds the wasted work before the fallback to ~100 cheap
// V-cycles while never bailing on a case multigrid would actually have solved.
constexpr int kMgIterBudget = 100;

// One grid level of the hierarchy. Active DOFs are the free, non-void DOFs at
// this level, numbered 0..n-1 (matching the rows/cols of A).
struct Level {
  int nx = 0, ny = 0, nz = 0;  // node dims (elements + 1)
  int n = 0;                   // number of active DOFs
  SpMat A;                     // operator (n x n), SPD
  Vec Dinv;                    // 1/diag(A) for the Jacobi smoother (0 where guarded)
  SpMat P;                     // prolongation coarse(level+1) -> this (n x n_coarse)
  std::vector<int> active;     // (node*3+comp) -> local dof id, or -1
  bool coarsest = false;
  // coarsest-level exact solve; held by pointer so Level stays movable in a
  // std::vector (Eigen's factorisation objects are not moveable).
  std::shared_ptr<Eigen::SimplicialLDLT<SpMat>> chol;

  int node_index(int a, int b, int c) const { return (c * ny + b) * nx + a; }
};

// Trilinear (vertex-coarsening) interpolation weights along one axis: which
// coarse indices contribute to fine index f, and with what weight. A fine node
// at an even index coincides with a coarse node (weight 1); an odd fine node is
// the average of its two coarse neighbours (0.5 each).
inline int axis_weights(int f, int (&ci)[2], double (&cw)[2]) {
  if ((f & 1) == 0) {
    ci[0] = f / 2;
    cw[0] = 1.0;
    return 1;
  }
  ci[0] = (f - 1) / 2;
  cw[0] = 0.5;
  ci[1] = (f + 1) / 2;
  cw[1] = 0.5;
  return 2;
}

// Compute 1/diag(A), guarding non-positive diagonals (shouldn't occur on an SPD
// operator, but a zero would poison the Jacobi smoother — leave it at 0 so that
// DOF is simply not relaxed).
Vec inverse_diagonal(const SpMat& A) {
  const Vec d = A.diagonal();
  Vec dinv(d.size());
  for (int i = 0; i < d.size(); ++i)
    dinv[i] = (d[i] > 0.0) ? 1.0 / d[i] : 0.0;
  return dinv;
}

// Memory-frugal Galerkin coarse operator A_c = P^T A P, computed one COLUMN BLOCK
// of P at a time so the A*P intermediate is only a block wide instead of the full
// (peak-doubling) product. Each coarse column A_c[:,j] = P^T A P[:,j] is computed
// independently, so the result equals P.transpose()*(A*P) to summation roundoff.
// Used by the matrix-free path, where the level-1 operator A1 (~O(voxels) nnz) is
// large enough that the full A1*P intermediate is a couple hundred MB on the
// design box; blocking cuts that transient to tens of MB. (The assembled path
// keeps the plain product, byte-for-byte.)
SpMat galerkin_pt_a_p_frugal(const SpMat& A, const SpMat& P) {
  const int nc = static_cast<int>(P.cols());
  constexpr int kBlockCols = 4096;
  const SpMat Pt = P.transpose();
  std::vector<Trip> trips;
  for (int c0 = 0; c0 < nc; c0 += kBlockCols) {
    const int w = std::min(kBlockCols, nc - c0);
    const SpMat APblk = A * P.middleCols(c0, w);   // A.rows x w
    const SpMat Acblk = Pt * APblk;                 // nc x w (block of A_c columns)
    for (int j = 0; j < w; ++j)
      for (SpMat::InnerIterator it(Acblk, j); it; ++it)
        trips.emplace_back(static_cast<int>(it.row()), c0 + j, it.value());
  }
  SpMat Ac(nc, nc);
  Ac.setFromTriplets(trips.begin(), trips.end());
  return Ac;
}

// Build the multigrid hierarchy from the finest active operator A0 whose active
// DOFs sit on the node grid (nx0,ny0,nz0) with the given active map. Returns the
// levels finest-first, or an empty vector if a usable hierarchy (>= kMinLevels
// with a small enough coarsest level) cannot be built — the caller then falls
// back to Jacobi-CG. `frugal` selects the column-blocked coarse Galerkin product
// (matrix-free path, lower peak); default false keeps the plain product the
// assembled path has always used, byte-for-byte.
std::vector<Level> build_hierarchy(const SpMat& A0, int nx0, int ny0, int nz0,
                                   std::vector<int> active0, bool frugal = false) {
  std::vector<Level> levels;
  Level fine;
  fine.nx = nx0;
  fine.ny = ny0;
  fine.nz = nz0;
  fine.n = static_cast<int>(A0.cols());
  fine.A = A0;
  fine.Dinv = inverse_diagonal(A0);
  fine.active = std::move(active0);
  levels.push_back(std::move(fine));

  while (true) {
    const Level& f = levels.back();
    const int fex = f.nx - 1, fey = f.ny - 1, fez = f.nz - 1;  // fine element dims
    // Coarsen only while every axis is even and stays >= kMinCoarseElems.
    if ((fex & 1) || (fey & 1) || (fez & 1)) break;
    const int cex = fex / 2, cey = fey / 2, cez = fez / 2;
    if (cex < kMinCoarseElems || cey < kMinCoarseElems || cez < kMinCoarseElems)
      break;
    const int cnx = cex + 1, cny = cey + 1, cnz = cez + 1;

    // Coarse active DOFs: a coarse node-DOF is active iff its coincident fine
    // node-DOF (2a,2b,2c) is active. Number them 0..nc-1.
    std::vector<int> cactive(static_cast<std::size_t>(cnx) * cny * cnz * 3, -1);
    int nc = 0;
    for (int c = 0; c < cnz; ++c)
      for (int b = 0; b < cny; ++b)
        for (int a = 0; a < cnx; ++a) {
          const int fnode = f.node_index(2 * a, 2 * b, 2 * c);
          const int cnode = (c * cny + b) * cnx + a;
          for (int comp = 0; comp < 3; ++comp)
            if (f.active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
              cactive[static_cast<std::size_t>(cnode) * 3 + comp] = nc++;
        }
    if (nc == 0) break;

    // Prolongation P (fine active rows x coarse active cols): each fine active
    // DOF interpolates from up to 8 coarse nodes (same component). Coarse nodes
    // that are inactive (fixed/void) are dropped from the stencil (weight 0), the
    // standard Dirichlet/void treatment; the coincident-node identity rows keep P
    // full column rank, so A_c = P^T A P stays SPD.
    std::vector<Trip> ptrips;
    ptrips.reserve(static_cast<std::size_t>(f.n) * 8);
    for (int fc = 0; fc < f.nz; ++fc)
      for (int fb = 0; fb < f.ny; ++fb)
        for (int fa = 0; fa < f.nx; ++fa) {
          const int fnode = f.node_index(fa, fb, fc);
          int hasActive = 0;
          for (int comp = 0; comp < 3; ++comp)
            if (f.active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
              hasActive = 1;
          if (!hasActive) continue;
          int ia[2], ib[2], ic[2];
          double wa[2], wb[2], wc[2];
          const int na = axis_weights(fa, ia, wa);
          const int nb = axis_weights(fb, ib, wb);
          const int ncz = axis_weights(fc, ic, wc);
          for (int comp = 0; comp < 3; ++comp) {
            const int row =
                f.active[static_cast<std::size_t>(fnode) * 3 + comp];
            if (row < 0) continue;
            for (int x = 0; x < na; ++x)
              for (int y = 0; y < nb; ++y)
                for (int z = 0; z < ncz; ++z) {
                  const int cnode = (ic[z] * cny + ib[y]) * cnx + ia[x];
                  const int col =
                      cactive[static_cast<std::size_t>(cnode) * 3 + comp];
                  if (col < 0) continue;  // inactive coarse node -> weight 0
                  ptrips.emplace_back(row, col, wa[x] * wb[y] * wc[z]);
                }
          }
        }
    SpMat P(f.n, nc);
    P.setFromTriplets(ptrips.begin(), ptrips.end());
    P.makeCompressed();

    // Galerkin coarse operator A_c = P^T A P. The assembled path materialises the
    // product stepwise (plain Eigen sparse*sparse, byte-for-byte unchanged); the
    // matrix-free path uses the column-blocked frugal form to bound the A*P peak.
    SpMat Ac;
    if (frugal) {
      Ac = galerkin_pt_a_p_frugal(f.A, P);
    } else {
      const SpMat AP = f.A * P;        // n x nc
      Ac = P.transpose() * AP;         // nc x nc, symmetric
    }
    Ac.makeCompressed();

    levels.back().P = std::move(P);

    Level coarse;
    coarse.nx = cnx;
    coarse.ny = cny;
    coarse.nz = cnz;
    coarse.n = nc;
    coarse.A = std::move(Ac);
    coarse.Dinv = inverse_diagonal(coarse.A);
    coarse.active = std::move(cactive);
    levels.push_back(std::move(coarse));

    if (nc <= kCoarseDofCap) break;  // small enough for a direct coarse solve
  }

  // Reject a hierarchy too shallow to help, or whose coarsest level is still too
  // big for a direct factorisation (the caller falls back to Jacobi-CG).
  if (static_cast<int>(levels.size()) < kMinLevels) return {};
  if (levels.back().n > kCoarseDofCap) return {};

  // Factor the coarsest operator for the exact bottom solve.
  Level& bottom = levels.back();
  bottom.coarsest = true;
  bottom.chol = std::make_shared<Eigen::SimplicialLDLT<SpMat>>();
  bottom.chol->compute(bottom.A);
  if (bottom.chol->info() != Eigen::Success) return {};  // fall back
  return levels;
}

// One damped-Jacobi sweep: x <- x + omega * Dinv .* (b - A x).
inline void jacobi_sweep(const Level& L, const Vec& b, Vec& x) {
  const Vec r = b - L.A * x;
  x += kJacobiOmega * (L.Dinv.array() * r.array()).matrix();
}

// Recursive symmetric V-cycle: return an approximate solution of A_l x = b.
// Equal pre/post damped-Jacobi (a self-adjoint smoother) + R = P^T + an SPD
// coarse solve make the cycle a symmetric positive-definite operator — a valid
// CG preconditioner.
Vec v_cycle(const std::vector<Level>& levels, int l, const Vec& b) {
  const Level& L = levels[static_cast<std::size_t>(l)];
  if (L.coarsest) return L.chol->solve(b);

  Vec x = Vec::Zero(L.n);
  for (int s = 0; s < kPreSmooth; ++s) jacobi_sweep(L, b, x);

  const Vec r = b - L.A * x;
  const Vec bc = L.P.transpose() * r;              // restrict residual (R = P^T)
  const Vec ec = v_cycle(levels, l + 1, bc);       // coarse-grid correction
  x += L.P * ec;                                    // prolongate + correct

  for (int s = 0; s < kPostSmooth; ++s) jacobi_sweep(L, b, x);
  return x;
}

// MG-preconditioned CG on A x = b (A == levels[0].A). Stops on relative residual
// ||b - A x|| / ||b|| <= tol (matching Eigen's CG criterion). Returns false and
// leaves diagnostics in *iters/*resid if it does not converge within max_it or
// the iterate goes non-finite (the caller then falls back).
bool mgpcg(const std::vector<Level>& levels, const Vec& b, double tol,
           int max_it, Vec& x, int& iters, double& resid) {
  const SpMat& A = levels[0].A;
  const double bnorm = b.norm();
  iters = 0;
  resid = 0.0;
  if (!(bnorm > 0.0)) {          // zero RHS -> zero solution, trivially converged
    x = Vec::Zero(A.cols());
    return true;
  }
  const double threshold = tol * bnorm;

  x = Vec::Zero(A.cols());
  Vec r = b;                              // r = b - A*0
  Vec z = v_cycle(levels, 0, r);          // z = M^{-1} r
  Vec p = z;
  double rz = r.dot(z);
  if (!std::isfinite(rz)) return false;

  for (int k = 1; k <= max_it; ++k) {
    const Vec Ap = A * p;
    const double pAp = p.dot(Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) return false;  // breakdown -> fall back
    const double alpha = rz / pAp;
    x += alpha * p;
    r -= alpha * Ap;
    iters = k;
    const double rn = r.norm();
    resid = rn / bnorm;
    if (rn <= threshold) return x.allFinite();
    Vec znew = v_cycle(levels, 0, r);
    const double rznew = r.dot(znew);
    if (!std::isfinite(rznew)) return false;
    const double beta = rznew / rz;
    p = znew + beta * p;
    rz = rznew;
    z.swap(znew);
  }
  return false;  // hit the iteration cap without converging
}

// Jacobi-preconditioned CG on the survivor system (Kgg, rg) — the exact fallback,
// numerically identical to fea_solve_cg's inner solve. Throws std::runtime_error
// on non-convergence (same guard as fea_solve_cg).
Vec jacobi_cg_fallback(const SpMat& Kgg, const Vec& rg, double tolerance,
                       int max_iterations, CgInfo* info) {
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper,
                           Eigen::DiagonalPreconditioner<double>>
      cg;
  cg.setTolerance(tolerance);
  if (max_iterations > 0) cg.setMaxIterations(max_iterations);
  cg.compute(Kgg);
  if (cg.info() != Eigen::Success)
    throw std::runtime_error("fea_solve_mgcg: preconditioner setup failed on K_ff");
  const Vec xg = cg.solve(rg);
  if (info) {
    info->iterations = static_cast<int>(cg.iterations());
    info->residual = cg.error();
    info->converged = (cg.info() == Eigen::Success) && xg.allFinite();
    info->used_multigrid = false;
    info->mg_levels = 0;
  }
  if (cg.info() != Eigen::Success || !xg.allFinite())
    throw std::runtime_error(
        "fea_solve_mgcg: CG did not reach the requested tolerance within "
        "max_iterations");
  return xg;
}

// Solve the assembled, BC-reduced system with MG-preconditioned CG, falling back
// to Jacobi-CG when a multigrid hierarchy is not applicable or does not converge.
// Mirrors solve_reduced_cg's void-gate + scatter so the result matches
// fea_solve_cg exactly.
FeaSolution solve_reduced_mgcg(const ReducedSystem& s, const VoxelGrid& grid,
                               double tolerance, int max_iterations,
                               CgInfo* info) {
  const int nf = static_cast<int>(s.freedofs.size());

  CgInfo diag;
  diag.converged = true;  // no free DOFs -> trivially converged

  Vec u = s.up;
  if (nf > 0) {
    // --- M3.1 void-DOF safety gate (identical to the Jacobi-CG path) ---------
    std::vector<int> kept;
    try {
      kept = fea_detail::void_dof_survivors(s.Kff, s.rf, "fea_solve_mgcg");
    } catch (...) {
      diag.converged = false;
      diag.iterations = 0;
      diag.residual = 0.0;
      if (info) *info = diag;
      throw;
    }
    const int ng = static_cast<int>(kept.size());

    // Reduce onto the surviving (non-void) free DOFs -> SPD operator Kgg, rg.
    SpMat Kgg;
    Vec rg;
    if (ng != nf) {
      SpMat Q(ng, nf);
      std::vector<Trip> qtrips;
      qtrips.reserve(static_cast<std::size_t>(ng));
      for (int r = 0; r < ng; ++r) qtrips.emplace_back(r, kept[r], 1.0);
      Q.setFromTriplets(qtrips.begin(), qtrips.end());
      const SpMat KQt = s.Kff * Q.transpose();
      Kgg = Q * KQt;
      Kgg.makeCompressed();
      rg = Q * s.rf;
    } else {
      Kgg = s.Kff;
      rg = s.rf;
    }

    // Active-DOF map on the fine node grid: (node*3+comp) -> survivor id (== row
    // of Kgg). The survivor id r maps back to global DOF s.freedofs[kept[r]], from
    // which the node and component are recovered.
    const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
    std::vector<int> active(static_cast<std::size_t>(nnx) * nny * nnz * 3, -1);
    for (int r = 0; r < ng; ++r) {
      const int gdof = s.freedofs[static_cast<std::size_t>(kept[r])];
      const int node = gdof / 3;
      const int comp = gdof % 3;
      active[static_cast<std::size_t>(node) * 3 + comp] = r;
    }

    const int cap = max_iterations > 0 ? max_iterations
                                       : std::max(1000, 2 * ng);

    std::vector<Level> levels =
        build_hierarchy(Kgg, nnx, nny, nnz, std::move(active));

    bool solved = false;
    Vec xg;
    if (!levels.empty()) {
      // Cap MG-CG at a modest budget: if it hasn't converged by then, geometric
      // multigrid is not helping on this operator (adversarial contrast) and the
      // Jacobi-CG fallback below will be faster. Never exceed the caller's cap.
      const int mg_cap = std::min(cap, kMgIterBudget);
      int it = 0;
      double res = 0.0;
      const bool ok = mgpcg(levels, rg, tolerance, mg_cap, xg, it, res);
      if (ok) {
        diag.iterations = it;
        diag.residual = res;
        diag.converged = true;
        diag.used_multigrid = true;
        diag.mg_levels = static_cast<int>(levels.size());
        solved = true;
      }
      // MG did not converge / broke down -> fall through to the Jacobi-CG fallback.
    }

    if (!solved) {
      // Exact fallback: numerically identical to fea_solve_cg's inner solve.
      // Reports the Jacobi attempt in *info (used_multigrid=false); throws on
      // non-convergence just like fea_solve_cg.
      try {
        xg = jacobi_cg_fallback(Kgg, rg, tolerance, cap, &diag);
      } catch (...) {
        if (info) *info = diag;
        throw;
      }
    }

    for (int r = 0; r < ng; ++r) u[s.freedofs[static_cast<std::size_t>(kept[r])]] = xg[r];
  }

  if (info) *info = diag;

  FeaSolution sol;
  sol.u.assign(u.data(), u.data() + s.ndof);
  return sol;
}

// ===========================================================================
// Matrix-free geometric multigrid (handoff: matrix-free multigrid).
//
// The FINEST level is MATRIX-FREE: its matvecs, residuals and damped-Jacobi
// smoother use fea_detail's element-by-element apply (mf_apply_full via
// MatfreeReduced::apply_kgg) and matrix-free Jacobi diagonal — the assembled
// fine operator A0 (the sparse K that OOMs on the ~623k-voxel design box) is
// NEVER built. Only the (>=8x smaller) COARSE operators are assembled.
//
// STEP 0 coarse-operator strategy (see docs/handoffs/078): matrix-free GALERKIN
// via an element-local triple product. The level-1 operator A1 = P0^T A0 P0 is
// formed by projecting each solid element's reference block factor*Ke through
// the trilinear prolongation restricted to that element's <=24 local coarse
// DOFs, then scattering the small projected block. This reproduces the assembled
// Galerkin A1 DOF-for-DOF (to summation roundoff) WITHOUT ever assembling A0, so
// it keeps Galerkin's robustness under the SIMP soft-void modulus contrast
// (rho_min^p high contrast) — the documented reason Galerkin was chosen over
// rediscretisation — while removing the fine matrix. Levels 2.. are the ordinary
// assembled Galerkin products on the (small) A1 via the shared build_hierarchy.
// The V-cycle structure (equal pre/post damped-Jacobi, R = P0^T, exact coarse
// solve) is preserved, so the preconditioner stays SPD and CG-valid.
// ===========================================================================

using fea_detail::MatfreeReduced;
using fea_detail::MfElem;

// A matrix-free multigrid hierarchy: level 0 is the matrix-free fine operator
// `m`; levels 1.. are the assembled `coarse` Levels (coarse[0] == level 1).
struct MfHierarchy {
  const MatfreeReduced* m = nullptr;  // fine (level 0), matrix-free
  Vec fine_dinv;                      // 1/diag(A0) at the fine level
  SpMat P0;                           // prolongation level1 -> fine (ng x nc1)
  std::vector<Level> coarse;          // assembled levels 1..L (coarse[0]==lvl 1)
  int levels() const { return 1 + static_cast<int>(coarse.size()); }
};

// Preallocated scratch for the matrix-free V-cycle + MG-CG, sized once per solve
// and reused across every iteration so the numerically-hot path performs NO
// per-iteration heap allocation (handoff 079's named lever). Every buffer is
// written in full before it is read, so reuse is bit-for-bit identical to the
// previous allocate-fresh-each-call code — the arithmetic and its ordering are
// unchanged; only the storage is recycled.
struct MfScratch {
  // Fine-level (ng) work vectors.
  Vec Ax;    // A0 * x from the fine matvec / jacobi sweep
  Vec vr;    // V-cycle fine residual b - A0 x
  Vec prol;  // P0 * ec (prolongated coarse correction)
  Vec Ap;    // MG-CG: A0 * p
  Vec zc;    // MG-CG: preconditioned residual (z / znew are ping-ponged here)
  // Coarse (nc) work vectors.
  Vec bc;    // restricted residual P0^T r
  Vec ec;    // coarse-grid correction

  void resize(int ng, int nc) {
    Ax.resize(ng); vr.resize(ng); prol.resize(ng); Ap.resize(ng); zc.resize(ng);
    bc.resize(nc); ec.resize(nc);
  }
};

// Fine-level matrix-free matvec y = A0 x (restricted to the kept DOFs), writing
// into the caller-owned `y` (reused across calls). Eigen vectors store their
// entries contiguously, so apply_kgg_raw drives the element apply straight off
// x.data()/y.data() with NO marshalling copies (the previous version allocated
// two std::vectors and an output Vec every call).
inline void mf_fine_matvec(const MfHierarchy& H, const Vec& x, Vec& y) {
  const int n = H.m->ng;
  y.resize(n);
  H.m->apply_kgg_raw(x.data(), y.data());
}

// One fine-level damped-Jacobi sweep, matrix-free: x <- x + omega*Dinv.*(b-A0 x).
inline void mf_jacobi_sweep(const MfHierarchy& H, MfScratch& S, const Vec& b,
                            Vec& x) {
  mf_fine_matvec(H, x, S.Ax);
  x += kJacobiOmega * (H.fine_dinv.array() * (b - S.Ax).array()).matrix();
}

// Symmetric V-cycle with a matrix-free finest level, writing the result into the
// caller-owned `x` (reused). The coarse-grid correction reuses the assembled
// v_cycle on the coarse hierarchy, so this is a valid SPD preconditioner (equal
// pre/post smoothing, R = P0^T, exact coarse solve).
void mf_v_cycle(const MfHierarchy& H, MfScratch& S, const Vec& b, Vec& x) {
  x.setZero(H.m->ng);
  for (int s = 0; s < kPreSmooth; ++s) mf_jacobi_sweep(H, S, b, x);

  mf_fine_matvec(H, x, S.Ax);
  S.vr = b - S.Ax;                            // fine residual
  S.bc.noalias() = H.P0.transpose() * S.vr;   // restrict (R = P0^T)
  S.ec = v_cycle(H.coarse, 0, S.bc);          // coarse-grid correction
  S.prol.noalias() = H.P0 * S.ec;             // prolongate + correct
  x += S.prol;

  for (int s = 0; s < kPostSmooth; ++s) mf_jacobi_sweep(H, S, b, x);
}

// MG-preconditioned CG with the matrix-free finest level. Identical algorithm
// and stopping criterion to mgpcg (||b - A x|| / ||b|| <= tol), only the fine
// matvec and preconditioner are matrix-free. Returns false (with diagnostics) on
// non-convergence within max_it or a non-finite iterate -> caller falls back.
// All work vectors come from `S` (sized once), so the loop heap-allocates nothing.
bool mf_mgpcg(const MfHierarchy& H, MfScratch& S, const Vec& b, double tol,
              int max_it, Vec& x, int& iters, double& resid) {
  const int n = H.m->ng;
  const double bnorm = b.norm();
  iters = 0;
  resid = 0.0;
  if (!(bnorm > 0.0)) {          // zero RHS -> zero solution, trivially converged
    x = Vec::Zero(n);
    return true;
  }
  const double threshold = tol * bnorm;

  x = Vec::Zero(n);
  Vec r = b;                              // r = b - A*0
  Vec z(n);
  mf_v_cycle(H, S, r, z);                 // z = M^{-1} r
  Vec p = z;
  double rz = r.dot(z);
  if (!std::isfinite(rz)) return false;

  for (int k = 1; k <= max_it; ++k) {
    mf_fine_matvec(H, p, S.Ap);
    const double pAp = p.dot(S.Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) return false;  // breakdown
    const double alpha = rz / pAp;
    x += alpha * p;
    r -= alpha * S.Ap;
    iters = k;
    const double rn = r.norm();
    resid = rn / bnorm;
    if (rn <= threshold) return x.allFinite();
    mf_v_cycle(H, S, r, S.zc);            // znew = M^{-1} r (reused buffer)
    const double rznew = r.dot(S.zc);
    if (!std::isfinite(rznew)) return false;
    const double beta = rznew / rz;
    p = S.zc + beta * p;
    rz = rznew;
  }
  return false;  // hit the iteration cap without converging
}

// Build the matrix-free multigrid hierarchy from the matrix-free fine operator
// `m` whose kept DOFs sit on the node grid (nnx,nny,nnz). Returns false (leaving
// `out` unusable) if a usable hierarchy cannot be built (fine not 2x-divisible,
// or the coarse operator not factorable) — the caller then falls back to the
// matrix-free Jacobi-CG. The FINE operator A0 is never assembled: A1 is formed
// by an element-local Galerkin triple product, all coarser levels by build_hierarchy.
bool build_mf_hierarchy(const MatfreeReduced& m, int nnx, int nny, int nnz,
                        MfHierarchy& out) {
  const int fex = nnx - 1, fey = nny - 1, fez = nnz - 1;  // fine element dims
  if ((fex & 1) || (fey & 1) || (fez & 1)) return false;
  const int cex = fex / 2, cey = fey / 2, cez = fez / 2;
  if (cex < kMinCoarseElems || cey < kMinCoarseElems || cez < kMinCoarseElems)
    return false;
  const int cnx = cex + 1, cny = cey + 1, cnz = cez + 1;

  // Fine active map: global DOF (node*3+comp) -> kept id (0..ng-1), or -1.
  std::vector<int> active(static_cast<std::size_t>(m.ndof), -1);
  for (int kg = 0; kg < m.ng; ++kg)
    active[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(kg)])] =
        kg;

  auto fnode_index = [&](int a, int b, int c) { return (c * nny + b) * nnx + a; };

  // Coarse (level-1) active DOFs: active iff the coincident fine node-DOF is.
  std::vector<int> cactive(static_cast<std::size_t>(cnx) * cny * cnz * 3, -1);
  int nc = 0;
  for (int c = 0; c < cnz; ++c)
    for (int b = 0; b < cny; ++b)
      for (int a = 0; a < cnx; ++a) {
        const int fnode = fnode_index(2 * a, 2 * b, 2 * c);
        const int cnode = (c * cny + b) * cnx + a;
        for (int comp = 0; comp < 3; ++comp)
          if (active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
            cactive[static_cast<std::size_t>(cnode) * 3 + comp] = nc++;
      }
  if (nc == 0) return false;

  // Prolongation P0 (fine kept rows x coarse cols) + per-kept-DOF coarse weight
  // list `prolong` (the rows of P0, used by the element-local Galerkin below).
  // Identical trilinear stencil to build_hierarchy's fine-level P.
  std::vector<Trip> ptrips;
  ptrips.reserve(static_cast<std::size_t>(m.ng) * 8);
  std::vector<std::vector<std::pair<int, double>>> prolong(
      static_cast<std::size_t>(m.ng));
  for (int fc = 0; fc < nnz; ++fc)
    for (int fb = 0; fb < nny; ++fb)
      for (int fa = 0; fa < nnx; ++fa) {
        const int fnode = fnode_index(fa, fb, fc);
        int hasActive = 0;
        for (int comp = 0; comp < 3; ++comp)
          if (active[static_cast<std::size_t>(fnode) * 3 + comp] >= 0)
            hasActive = 1;
        if (!hasActive) continue;
        int ia[2], ib[2], ic[2];
        double wa[2], wb[2], wc[2];
        const int na = axis_weights(fa, ia, wa);
        const int nb = axis_weights(fb, ib, wb);
        const int ncz = axis_weights(fc, ic, wc);
        for (int comp = 0; comp < 3; ++comp) {
          const int row = active[static_cast<std::size_t>(fnode) * 3 + comp];
          if (row < 0) continue;
          for (int x = 0; x < na; ++x)
            for (int y = 0; y < nb; ++y)
              for (int z = 0; z < ncz; ++z) {
                const int cnode = (ic[z] * cny + ib[y]) * cnx + ia[x];
                const int col = cactive[static_cast<std::size_t>(cnode) * 3 + comp];
                if (col < 0) continue;  // inactive coarse node -> weight 0
                const double w = wa[x] * wb[y] * wc[z];
                ptrips.emplace_back(row, col, w);
                prolong[static_cast<std::size_t>(row)].emplace_back(col, w);
              }
        }
      }
  SpMat P0(m.ng, nc);
  P0.setFromTriplets(ptrips.begin(), ptrips.end());
  P0.makeCompressed();
  std::vector<Trip>().swap(ptrips);  // P0 is built; free the triplet scratch

  // Element-local Galerkin A1 = P0^T A0 P0, formed WITHOUT assembling A0. Per
  // element: gather its <=24 distinct local coarse DOFs, build the 24 x mloc
  // local prolongation W (rows of P0 for the element's kept fine DOFs), and
  // scatter W^T (factor*Ke) W. Summing these over all elements yields exactly
  // P0^T A0 P0 (A0 = sum_e factor_e S_e^T Ke S_e).
  //
  // ASSEMBLY — TWO-PASS CSR (handoff 085 follow-up). Naively streaming each
  // element's <=kDof^2 = 576 (i,j,v) triplets into a single array is ~576*elements
  // ~= 359M triplets ~= 5.5 GB at the design box (the measured OOM 079 avoided). 079
  // instead accumulated in place via A1.coeffRef, which is memory-bounded but pays an
  // insert cost: the FIRST touch of each (i,j) inserts into a sorted sparse column
  // and shifts its tail, and the column is pre-reserved at the full 81-wide stencil.
  // The two-pass CSR keeps 079's bounded memory, drops that over-reservation, and
  // removes the insert-shifting:
  //   Pass 0  cache each element's distinct coarse DOFs (cds) once (CSR ecds).
  //   Pass 1  SYMBOLIC: build the exact CSC structure (colptr + row-sorted rowidx)
  //           via an inverse map (coarse DOF -> elements) and a column mark, so each
  //           (i,j) is discovered once with O(1) dedup — no triplet array, no insert.
  //           A1 is then created at EXACTLY this structure (values 0), and the scratch
  //           colptr/rowidx freed, so no second nnz-sized array is copied into Eigen.
  //   Pass 2  NUMERIC: recompute each element's block (same W/KW/W^T KW as before) and
  //           add v straight into A1's OWN value array by BINARY SEARCH over A1's
  //           sorted inner indices — a pure search, never an insertion.
  // Pass 2 loops elements in the same order and adds the same nonzero v's to each
  // (i,j) in the same order coeffRef did, so A1 is BIT-FOR-BIT identical to 079's —
  // same values, and the same pattern (every structural (i,j) receives a nonzero
  // contribution; verified by the unchanged nnz). The 078 iteration-count parity
  // (18 == 18) is thus preserved by construction, not merely to roundoff. NOTE: the
  // build is dominated by the element block arithmetic below (~73% of build time,
  // measured), which this assembly change does not touch; coeffRef was ~2 s of it.
  constexpr int kDof = Hex8Stiffness::kDof;  // 24
  const int nelems = static_cast<int>(m.elems.size());

  // Pass 0: per-element distinct coarse DOFs (CSR ecds_off/ecds), same discovery
  // order the old per-element loop used, so the projected blocks are identical.
  std::vector<int> ecds_off;
  ecds_off.reserve(static_cast<std::size_t>(nelems) + 1);
  ecds_off.push_back(0);
  std::vector<int> ecds;
  ecds.reserve(static_cast<std::size_t>(nelems) * 8);
  {
    std::vector<int> cds;
    cds.reserve(kDof);
    for (const MfElem& el : m.elems) {
      cds.clear();
      for (int r = 0; r < kDof; ++r) {
        const int kgr = active[static_cast<std::size_t>(el.edof[r])];
        if (kgr < 0) continue;
        for (const auto& pr : prolong[static_cast<std::size_t>(kgr)]) {
          bool found = false;
          for (int t : cds)
            if (t == pr.first) { found = true; break; }
          if (!found) cds.push_back(pr.first);
        }
      }
      for (int c : cds) ecds.push_back(c);
      ecds_off.push_back(static_cast<int>(ecds.size()));
    }
  }

  // Pass 1a: inverse map coarse DOF -> elements touching it (CSR inv_off/inv), the
  // column view the symbolic dedup needs.
  std::vector<int> inv_off(static_cast<std::size_t>(nc) + 1, 0);
  for (int e = 0; e < nelems; ++e)
    for (int k = ecds_off[static_cast<std::size_t>(e)];
         k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k)
      ++inv_off[static_cast<std::size_t>(ecds[static_cast<std::size_t>(k)]) + 1];
  for (int j = 0; j < nc; ++j) inv_off[static_cast<std::size_t>(j) + 1] += inv_off[static_cast<std::size_t>(j)];
  std::vector<int> inv(ecds.size());
  {
    std::vector<int> cur(inv_off.begin(), inv_off.end());
    for (int e = 0; e < nelems; ++e)
      for (int k = ecds_off[static_cast<std::size_t>(e)];
           k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k)
        inv[static_cast<std::size_t>(cur[static_cast<std::size_t>(ecds[static_cast<std::size_t>(k)])]++)] = e;
  }

  // Pass 1b: symbolic structure. A column mark (monotone j needs no per-column
  // reset within a sweep) discovers each distinct row once. First sweep counts
  // nnz/col -> colptr; second fills rowidx, then sorts each column's rows.
  std::vector<int> colptr(static_cast<std::size_t>(nc) + 1, 0);
  std::vector<int> mark(static_cast<std::size_t>(nc), -1);
  for (int j = 0; j < nc; ++j) {
    int cnt = 0;
    for (int p = inv_off[static_cast<std::size_t>(j)]; p < inv_off[static_cast<std::size_t>(j) + 1]; ++p) {
      const int e = inv[static_cast<std::size_t>(p)];
      for (int k = ecds_off[static_cast<std::size_t>(e)];
           k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k) {
        const int i = ecds[static_cast<std::size_t>(k)];
        if (mark[static_cast<std::size_t>(i)] != j) { mark[static_cast<std::size_t>(i)] = j; ++cnt; }
      }
    }
    colptr[static_cast<std::size_t>(j) + 1] = cnt;
  }
  for (int j = 0; j < nc; ++j) colptr[static_cast<std::size_t>(j) + 1] += colptr[static_cast<std::size_t>(j)];
  const int a1nnz = colptr[static_cast<std::size_t>(nc)];
  std::vector<int> rowidx(static_cast<std::size_t>(a1nnz));
  std::fill(mark.begin(), mark.end(), -1);
  for (int j = 0; j < nc; ++j) {
    int w = colptr[static_cast<std::size_t>(j)];
    for (int p = inv_off[static_cast<std::size_t>(j)]; p < inv_off[static_cast<std::size_t>(j) + 1]; ++p) {
      const int e = inv[static_cast<std::size_t>(p)];
      for (int k = ecds_off[static_cast<std::size_t>(e)];
           k < ecds_off[static_cast<std::size_t>(e) + 1]; ++k) {
        const int i = ecds[static_cast<std::size_t>(k)];
        if (mark[static_cast<std::size_t>(i)] != j) {
          mark[static_cast<std::size_t>(i)] = j;
          rowidx[static_cast<std::size_t>(w++)] = i;
        }
      }
    }
    std::sort(rowidx.begin() + colptr[static_cast<std::size_t>(j)],
              rowidx.begin() + w);
  }
  std::vector<int>().swap(inv);       // symbolic done; free the column view
  std::vector<int>().swap(inv_off);
  std::vector<int>().swap(mark);

  // Build A1's STRUCTURE from the symbolic CSC (row-sorted, all values 0), then
  // free the scratch colptr/rowidx and accumulate straight into A1's OWN value
  // storage in Pass 2 — no second nnz-sized values array, so peak stays near the
  // final operator (unlike a separate CSC that is then copied into Eigen). Insertion
  // is in increasing (col, row) order into an exact per-column reservation, so it is
  // O(1) amortised (no shifting — the very cost the coeffRef path paid).
  SpMat A1(nc, nc);
  {
    Eigen::VectorXi cnt(nc);
    for (int j = 0; j < nc; ++j)
      cnt[j] = colptr[static_cast<std::size_t>(j) + 1] - colptr[static_cast<std::size_t>(j)];
    A1.reserve(cnt);
    for (int j = 0; j < nc; ++j)
      for (int k = colptr[static_cast<std::size_t>(j)];
           k < colptr[static_cast<std::size_t>(j) + 1]; ++k)
        A1.insert(rowidx[static_cast<std::size_t>(k)], j) = 0.0;
  }
  A1.makeCompressed();
  std::vector<int>().swap(rowidx);   // structure now lives in A1; free the scratch
  std::vector<int>().swap(colptr);

  // Pass 2: numeric. Recompute each element block (W/KW/W^T KW, unchanged) and add v
  // into A1's value array by binary search over A1's (sorted) inner indices — a pure
  // search, never an insertion. The element loop order and the per-(i,j) add order
  // match the old coeffRef path exactly, so A1 is BIT-IDENTICAL to 079's. Every
  // structural (i,j) receives a nonzero contribution (verified: the resulting nnz
  // equals the coeffRef path's), so no explicit zeros are introduced.
  //
  // GALERKIN BLOCK CACHE (handoff 090, opt-in via fea_set_matfree_galerkin_block
  // _cache, default OFF). The block S = W^T Ke W formed here is purely GEOMETRIC:
  // W comes from the trilinear prolongation stencil and Ke is the single reference
  // element stiffness — the element's modulus enters only below, as `el.factor *
  // S`. Since axis_weights is parity-based and translation-invariant, every
  // element whose 24 fine DOFs are all free AND whose 8 coarse nodes are all
  // active (mloc == kDof; see below) has the SAME W — and hence the same S — as
  // any other element of the same (i,j,k) parity, i.e. of the same COLOUR (the key
  // m.elems is already sorted by). Such elements are the interior majority, and on
  // the design box ~94% of them are the soft void the optimizer may grow into: the
  // build was recomputing a handful of identical blocks ~638,000 times. Measured
  // (090): this pass 6.32 s -> 2.25 s, the build 7.81 s -> 3.73 s, on the real
  // 96x80x96 case; what is left of the pass is the scatter, not the arithmetic.
  //
  // mloc == kDof is exactly the genericity test. An element's 8 nodes span 2 coarse
  // indices per axis whatever its parity (an even fine index maps to 1 coarse node,
  // an odd one to 2, and the union over {i, i+1} is 2 either way), so its coarse
  // support is always 2x2x2 nodes x 3 components = 24 coarse DOFs. mloc is the
  // count of DISTINCT coarse DOFs actually discovered, so mloc < kDof iff some
  // coarse DOF was inactive (dropped by `col < 0` in the P0 build); mloc == kDof
  // therefore certifies that no stencil entry was dropped. Combined with every
  // kg[r] >= 0 (no fine row zeroed by a fixed/void DOF), W is fully determined by
  // the colour. Elements failing either test — the BC-fixed and void-gated ones at
  // the boundary — take the unchanged full per-element path.
  //
  // BIT-IDENTICAL: the cached S is the same arithmetic on the same inputs, each
  // element still scales by its OWN el.factor, and the element loop order and the
  // per-(i,j) add order are untouched — so A1, the V-cycle and the iteration count
  // are unchanged. This saves compute; it does not approximate. Nothing is skipped
  // or frozen, so growth into the void is entirely unaffected.
  {
    const int* Aouter = A1.outerIndexPtr();
    const int* Ainner = A1.innerIndexPtr();
    double* Aval = A1.valuePtr();
    double W[kDof][kDof];   // fine-local (24) x coarse-local (<=24)
    double KW[kDof][kDof];  // Ke * W
    double S[kDof][kDof];   // W^T Ke W (the geometric block)
    int kg[kDof];

    const bool use_cache = fea_detail::mf_galerkin_block_cache_enabled() &&
                           static_cast<int>(m.color_offsets.size()) ==
                               fea_detail::kNumColors + 1;
    std::vector<double> cacheS;
    std::vector<char> cache_valid;
    if (use_cache) {
      cacheS.assign(static_cast<std::size_t>(fea_detail::kNumColors) * kDof * kDof,
                    0.0);
      cache_valid.assign(static_cast<std::size_t>(fea_detail::kNumColors), 0);
    }
    int color = 0;  // m.elems is colour-sorted; walk the colour ranges alongside e

    for (int e = 0; e < nelems; ++e) {
      if (use_cache)
        while (color + 1 < fea_detail::kNumColors &&
               e >= m.color_offsets[static_cast<std::size_t>(color) + 1])
          ++color;
      const int cb = ecds_off[static_cast<std::size_t>(e)];
      const int mloc = ecds_off[static_cast<std::size_t>(e) + 1] - cb;
      if (mloc == 0) continue;
      const MfElem& el = m.elems[static_cast<std::size_t>(e)];
      for (int r = 0; r < kDof; ++r)
        kg[r] = active[static_cast<std::size_t>(el.edof[r])];

      bool generic = use_cache && mloc == kDof;
      if (generic)
        for (int r = 0; r < kDof; ++r)
          if (kg[r] < 0) { generic = false; break; }

      const bool hit = generic && cache_valid[static_cast<std::size_t>(color)] != 0;
      if (hit) {
        const double* src =
            &cacheS[static_cast<std::size_t>(color) * kDof * kDof];
        for (int cl = 0; cl < mloc; ++cl)
          for (int dl = 0; dl < mloc; ++dl) S[cl][dl] = src[cl * kDof + dl];
      } else {
        for (int r = 0; r < kDof; ++r)
          for (int cl = 0; cl < mloc; ++cl) W[r][cl] = 0.0;
        for (int r = 0; r < kDof; ++r) {
          if (kg[r] < 0) continue;
          for (const auto& pr : prolong[static_cast<std::size_t>(kg[r])]) {
            int idx = 0;
            while (ecds[static_cast<std::size_t>(cb + idx)] != pr.first) ++idx;
            W[r][idx] += pr.second;
          }
        }
        for (int r = 0; r < kDof; ++r)
          for (int cl = 0; cl < mloc; ++cl) {
            double s = 0.0;
            for (int c = 0; c < kDof; ++c) s += m.Ke(r, c) * W[c][cl];
            KW[r][cl] = s;
          }
        for (int cl = 0; cl < mloc; ++cl)
          for (int dl = 0; dl < mloc; ++dl) {
            double s = 0.0;
            for (int r = 0; r < kDof; ++r) s += W[r][cl] * KW[r][dl];
            S[cl][dl] = s;
          }
        if (generic) {  // first generic element of this colour seeds the cache
          double* dst = &cacheS[static_cast<std::size_t>(color) * kDof * kDof];
          for (int cl = 0; cl < mloc; ++cl)
            for (int dl = 0; dl < mloc; ++dl) dst[cl * kDof + dl] = S[cl][dl];
          cache_valid[static_cast<std::size_t>(color)] = 1;
        }
      }

      for (int cl = 0; cl < mloc; ++cl) {
        const int i = ecds[static_cast<std::size_t>(cb + cl)];
        for (int dl = 0; dl < mloc; ++dl) {
          const double v = el.factor * S[cl][dl];
          if (v == 0.0) continue;
          const int j = ecds[static_cast<std::size_t>(cb + dl)];
          int lo = Aouter[j], hi = Aouter[j + 1];
          while (lo < hi) {  // binary search: Ainner[.] sorted, i present
            const int mid = (lo + hi) >> 1;
            if (Ainner[mid] < i) lo = mid + 1; else hi = mid;
          }
          Aval[lo] += v;
        }
      }
    }
  }
  std::vector<std::vector<std::pair<int, double>>>().swap(prolong);  // done with W

  // Coarser levels 2.. via the shared assembled Galerkin builder, seeded at A1.
  // Frugal (column-blocked) coarse products keep the design-box peak in budget.
  std::vector<Level> coarse =
      build_hierarchy(A1, cnx, cny, cnz, cactive, /*frugal=*/true);
  if (coarse.empty()) {
    // A1 alone could not seed a >=2-level sub-hierarchy. Use A1 as the sole
    // (directly factored) coarse level if small enough, giving a 2-level
    // matrix-free cycle (fine matrix-free + A1 direct); else no usable hierarchy.
    if (static_cast<int>(A1.cols()) > kCoarseDofCap) return false;
    Level only;
    only.nx = cnx;
    only.ny = cny;
    only.nz = cnz;
    only.n = static_cast<int>(A1.cols());
    only.A = A1;
    only.Dinv = inverse_diagonal(A1);
    only.active = cactive;
    only.coarsest = true;
    only.chol = std::make_shared<Eigen::SimplicialLDLT<SpMat>>();
    only.chol->compute(only.A);
    if (only.chol->info() != Eigen::Success) return false;
    coarse.push_back(std::move(only));
  }

  out.m = &m;
  out.fine_dinv = Eigen::Map<const Vec>(m.invdiag.data(),
                                        static_cast<Eigen::Index>(m.invdiag.size()));
  out.P0 = std::move(P0);
  out.coarse = std::move(coarse);
  return true;
}

// Matrix-free MG-CG solve, falling back to the exact matrix-free Jacobi-CG when
// a hierarchy is not applicable or MG does not converge. Mirrors
// solve_reduced_mgcg's fallback discipline and scatter, but the FINE level is
// never assembled. `elem_youngs` selects the graded path when non-null.
FeaSolution solve_mgcg_matfree(const VoxelGrid& grid, double youngs_modulus,
                               double poisson,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               double tolerance, int max_iterations, CgInfo* info,
                               const std::vector<double>* elem_youngs) {
  // Build the reduced, void-gated matrix-free system (throws + sets *info on a
  // void-gate rejection, exactly like solve_reduced_mgcg's gate).
  MatfreeReduced m = fea_detail::mf_build_reduced(
      grid, youngs_modulus, poisson, bcs, loads, elem_youngs,
      "fea_solve_mgcg_matfree", info);

  CgInfo diag;
  diag.converged = true;  // no free DOFs -> trivially converged

  std::vector<double> u = m.up;
  if (m.ng > 0) {
    const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
    const int cap =
        max_iterations > 0 ? max_iterations : std::max(1000, 2 * m.ng);

    MfHierarchy H;
    const bool have_h = build_mf_hierarchy(m, nnx, nny, nnz, H);

    std::vector<double> xkept(static_cast<std::size_t>(m.ng), 0.0);
    bool solved = false;
    if (have_h) {
      Vec rgv = Eigen::Map<const Vec>(m.rg.data(),
                                      static_cast<Eigen::Index>(m.ng));
      const int mg_cap = std::min(cap, kMgIterBudget);
      Vec xg;
      int it = 0;
      double res = 0.0;
      MfScratch scratch;
      scratch.resize(m.ng, static_cast<int>(H.P0.cols()));
      const bool ok = mf_mgpcg(H, scratch, rgv, tolerance, mg_cap, xg, it, res);
      if (ok) {
        for (int k = 0; k < m.ng; ++k) xkept[static_cast<std::size_t>(k)] = xg[k];
        diag.iterations = it;
        diag.residual = res;
        diag.converged = true;
        diag.used_multigrid = true;
        diag.mg_levels = H.levels();
        solved = true;
      }
      // MG did not converge / broke down -> fall through to the exact fallback.
    }

    if (!solved) {
      // Exact matrix-free fallback (Jacobi-CG). Reports the Jacobi attempt in
      // *info (used_multigrid=false); throws on non-convergence, parity with
      // fea_solve_cg and the assembled fea_solve_mgcg fallback.
      fea_detail::mf_cg_solve(m, tolerance, cap, xkept, diag.iterations,
                              diag.residual, diag.converged);
      diag.used_multigrid = false;
      diag.mg_levels = 0;
      if (info) *info = diag;
      if (!diag.converged)
        throw std::runtime_error(
            "fea_solve_mgcg_matfree: CG did not reach the requested tolerance "
            "within max_iterations");
    }

    for (int k = 0; k < m.ng; ++k)
      u[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])] =
          xkept[static_cast<std::size_t>(k)];
  }

  if (info) *info = diag;

  FeaSolution sol;
  sol.u = std::move(u);
  return sol;
}

// --- Memory evidence (diagnostic) ------------------------------------------
// Total nonzeros stored across the ASSEMBLED operators of the multigrid
// hierarchy each solver builds, for a solid or graded grid. For the assembled
// fea_solve_mgcg this INCLUDES the fine operator A0 (the big one); for the
// matrix-free path only the coarse operators are assembled (the fine level
// stores just the 576-double reference Ke). The gap — and how it widens with
// grid size — demonstrates the fine matrix is absent on the matrix-free path.
std::size_t assembled_hierarchy_nonzeros(const VoxelGrid& grid,
                                         double youngs_modulus, double poisson,
                                         const std::vector<DirichletBC>& bcs,
                                         const std::vector<NodalLoad>& loads,
                                         const std::vector<double>* elem_youngs) {
  ReducedSystem s = fea_detail::assemble_reduced(
      grid, elem_youngs != nullptr ? 1.0 : youngs_modulus, poisson, bcs, loads,
      "assembled_hierarchy_nonzeros", elem_youngs);
  const int nf = static_cast<int>(s.freedofs.size());
  if (nf == 0) return 0;
  std::vector<int> kept =
      fea_detail::void_dof_survivors(s.Kff, s.rf, "assembled_hierarchy_nonzeros");
  const int ng = static_cast<int>(kept.size());

  SpMat Kgg;
  if (ng != nf) {
    SpMat Q(ng, nf);
    std::vector<Trip> qtrips;
    qtrips.reserve(static_cast<std::size_t>(ng));
    for (int r = 0; r < ng; ++r) qtrips.emplace_back(r, kept[r], 1.0);
    Q.setFromTriplets(qtrips.begin(), qtrips.end());
    Kgg = Q * s.Kff * Q.transpose();
    Kgg.makeCompressed();
  } else {
    Kgg = s.Kff;
  }

  const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
  std::vector<int> active(static_cast<std::size_t>(nnx) * nny * nnz * 3, -1);
  for (int r = 0; r < ng; ++r) {
    const int gdof = s.freedofs[static_cast<std::size_t>(kept[r])];
    active[static_cast<std::size_t>(gdof)] = r;
  }
  std::vector<Level> levels = build_hierarchy(Kgg, nnx, nny, nnz, active);
  if (levels.empty())
    return static_cast<std::size_t>(Kgg.nonZeros());  // fallback: only Kgg
  std::size_t total = 0;
  for (const Level& L : levels) total += static_cast<std::size_t>(L.A.nonZeros());
  return total;
}

std::size_t matfree_hierarchy_nonzeros(const VoxelGrid& grid,
                                       double youngs_modulus, double poisson,
                                       const std::vector<DirichletBC>& bcs,
                                       const std::vector<NodalLoad>& loads,
                                       const std::vector<double>* elem_youngs) {
  MatfreeReduced m = fea_detail::mf_build_reduced(
      grid, youngs_modulus, poisson, bcs, loads, elem_youngs,
      "matfree_hierarchy_nonzeros", nullptr);
  if (m.ng == 0) return 0;
  MfHierarchy H;
  const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;
  if (!build_mf_hierarchy(m, nnx, nny, nnz, H)) return 0;  // no assembled ops
  std::size_t total = 0;  // fine level (level 0) is matrix-free: 0 assembled nnz
  for (const Level& L : H.coarse)
    total += static_cast<std::size_t>(L.A.nonZeros());
  return total;
}

}  // namespace

FeaSolution fea_solve_mgcg(const VoxelGrid& grid, double youngs_modulus,
                           double poisson, const std::vector<DirichletBC>& bcs,
                           const std::vector<NodalLoad>& loads, double tolerance,
                           int max_iterations, CgInfo* info) {
  ReducedSystem s = fea_detail::assemble_reduced(grid, youngs_modulus, poisson,
                                                 bcs, loads, "fea_solve_mgcg");
  return solve_reduced_mgcg(s, grid, tolerance, max_iterations, info);
}

FeaSolution fea_solve_mgcg(const VoxelGrid& grid,
                           const std::vector<double>& youngs_per_voxel,
                           double poisson, const std::vector<DirichletBC>& bcs,
                           const std::vector<NodalLoad>& loads, double tolerance,
                           int max_iterations, CgInfo* info) {
  ReducedSystem s = fea_detail::assemble_reduced(
      grid, 1.0, poisson, bcs, loads, "fea_solve_mgcg", &youngs_per_voxel);
  return solve_reduced_mgcg(s, grid, tolerance, max_iterations, info);
}

// --- Matrix-free multigrid entry points (opt-in, default OFF) --------------

FeaSolution fea_solve_mgcg_matfree(const VoxelGrid& grid, double youngs_modulus,
                                   double poisson,
                                   const std::vector<DirichletBC>& bcs,
                                   const std::vector<NodalLoad>& loads,
                                   double tolerance, int max_iterations,
                                   CgInfo* info) {
  return solve_mgcg_matfree(grid, youngs_modulus, poisson, bcs, loads, tolerance,
                            max_iterations, info, nullptr);
}

FeaSolution fea_solve_mgcg_matfree(const VoxelGrid& grid,
                                   const std::vector<double>& youngs_per_voxel,
                                   double poisson,
                                   const std::vector<DirichletBC>& bcs,
                                   const std::vector<NodalLoad>& loads,
                                   double tolerance, int max_iterations,
                                   CgInfo* info) {
  return solve_mgcg_matfree(grid, 1.0, poisson, bcs, loads, tolerance,
                            max_iterations, info, &youngs_per_voxel);
}

std::size_t fea_mgcg_assembled_operator_nonzeros(
    const VoxelGrid& grid, double youngs_modulus, double poisson,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads) {
  return assembled_hierarchy_nonzeros(grid, youngs_modulus, poisson, bcs, loads,
                                      nullptr);
}

std::size_t fea_matfree_mgcg_assembled_operator_nonzeros(
    const VoxelGrid& grid, double youngs_modulus, double poisson,
    const std::vector<DirichletBC>& bcs, const std::vector<NodalLoad>& loads) {
  return matfree_hierarchy_nonzeros(grid, youngs_modulus, poisson, bcs, loads,
                                    nullptr);
}

}  // namespace topopt
