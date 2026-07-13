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
#include <vector>

#include <Eigen/IterativeLinearSolvers>
#include <Eigen/SparseCholesky>
#include <Eigen/SparseCore>

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

// Build the multigrid hierarchy from the finest active operator A0 whose active
// DOFs sit on the node grid (nx0,ny0,nz0) with the given active map. Returns the
// levels finest-first, or an empty vector if a usable hierarchy (>= kMinLevels
// with a small enough coarsest level) cannot be built — the caller then falls
// back to Jacobi-CG.
std::vector<Level> build_hierarchy(const SpMat& A0, int nx0, int ny0, int nz0,
                                   std::vector<int> active0) {
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

    // Galerkin coarse operator A_c = P^T A P (materialised stepwise to keep Eigen
    // on the plain sparse*sparse path).
    const SpMat AP = f.A * P;          // n x nc
    SpMat Ac = P.transpose() * AP;     // nc x nc, symmetric
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

}  // namespace topopt
