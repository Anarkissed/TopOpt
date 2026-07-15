// Matrix-free global stiffness operator + matrix-free Jacobi-CG for the voxel
// FEA (handoff 077: matrix-free operator). The assembled sparse global K is what
// OOMs on large (design-box) grids; this computes the IDENTICAL linear system
// element-by-element WITHOUT ever assembling K.
//
// KEY: this translation unit is deliberately Eigen-FREE — it includes no Eigen
// header and constructs no sparse matrix. The ONLY dense storage representing K
// is the single 24x24 reference element stiffness Ke (576 doubles), independent
// of grid size (see fea_matfree_operator_storage_doubles). Every apply is a
// gather -> local 24x24 multiply -> scatter over the solid voxels, exploiting
// the regular grid where every element is the same unit cube: K(E) = E * Ke, so
// each element's contribution scales its reference block by the voxel modulus.
//
// The matrix-free CG mirrors fea_solve_cg exactly: same free-DOF numbering, same
// M3.1 void-DOF gate (resolved topologically — a free DOF survives iff it is
// touched by a solid element, which equals the assembled diagonal-zero test for
// strictly-positive moduli, as PenalizedSolver already relies on), same Jacobi
// (diagonal) preconditioner, and the same relative-residual stopping criterion
// and iteration algorithm Eigen's ConjugateGradient<DiagonalPreconditioner> uses
// — so it converges to the same displacement field. The assembled fea_solve_cg
// path is untouched; these are new, opt-in entry points.
//
// The element table (mf_build_elems), the element-by-element apply
// (mf_apply_full), the reduced void-gated system (mf_build_reduced) and the
// matrix-free Jacobi-CG (mf_cg_solve) live in fea_detail (declared in the
// internal fea_matfree.hpp) so the matrix-free MULTIGRID solver (multigrid.cpp)
// can reuse the identical apply, diagonal and void gate as its FINE level — it
// must not reimplement them.

#include "topopt/fea.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "fea_matfree.hpp"

namespace topopt {

namespace fea_detail {

namespace {
constexpr int kDof = Hex8Stiffness::kDof;  // 24
}  // namespace

// Build the solid-element table (edof + factor). `elem_youngs` selects the graded
// path (factor = per-voxel modulus, validated > 0) when non-null; otherwise the
// uniform path (factor = 1, the modulus already baked into Ke).
std::vector<MfElem> mf_build_elems(const VoxelGrid& grid,
                                   const std::vector<double>* elem_youngs,
                                   const char* who) {
  if (elem_youngs != nullptr && elem_youngs->size() != grid.voxel_count())
    throw std::invalid_argument(
        std::string(who) + ": per-voxel modulus vector size != voxel_count");
  std::vector<MfElem> elems;
  elems.reserve(grid.solid_count());
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        MfElem el;
        if (elem_youngs != nullptr) {
          el.factor = (*elem_youngs)[grid.index(i, j, k)];
          if (!(el.factor > 0.0))
            throw std::invalid_argument(
                std::string(who) +
                ": per-voxel Young's modulus must be > 0 on a solid voxel");
        }
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) el.edof[3 * a + c] = 3 * en[a] + c;
        elems.push_back(el);
      }
  return elems;
}

// y = K x over the full global stiffness, element-by-element. `x` and `y` are
// full ndof vectors; `y` is overwritten (zeroed) then accumulated. No assembled
// K: only the reference Ke and the local 24-DOF gather/scatter.
void mf_apply_full(const std::vector<MfElem>& elems, const Hex8Stiffness& Ke,
                   const std::vector<double>& x, std::vector<double>& y) {
  std::fill(y.begin(), y.end(), 0.0);
  for (const MfElem& el : elems) {
    double ul[kDof];
    for (int r = 0; r < kDof; ++r)
      ul[r] = x[static_cast<std::size_t>(el.edof[r])];
    for (int r = 0; r < kDof; ++r) {
      double s = 0.0;
      const double* krow = &Ke.k[static_cast<std::size_t>(r) * kDof];
      for (int c = 0; c < kDof; ++c) s += krow[c] * ul[c];
      y[static_cast<std::size_t>(el.edof[r])] += el.factor * s;
    }
  }
}

void MatfreeReduced::apply_kgg(const std::vector<double>& xg,
                               std::vector<double>& yg) const {
  std::fill(xfull.begin(), xfull.end(), 0.0);
  for (int k = 0; k < ng; ++k)
    xfull[static_cast<std::size_t>(kept_global[static_cast<std::size_t>(k)])] =
        xg[static_cast<std::size_t>(k)];
  mf_apply_full(elems, Ke, xfull, yfull);
  yg.assign(static_cast<std::size_t>(ng), 0.0);
  for (int k = 0; k < ng; ++k)
    yg[static_cast<std::size_t>(k)] =
        yfull[static_cast<std::size_t>(kept_global[static_cast<std::size_t>(k)])];
}

// Build the matrix-free reduced system. Mirrors assemble_reduced + the M3.1 gate
// (void_dof_survivors) but without ever assembling a sparse matrix. On a void-gate
// rejection it sets `*info` (converged=false, 0 iterations) and throws, matching
// solve_reduced_cg's behaviour.
MatfreeReduced mf_build_reduced(const VoxelGrid& grid, double youngs_modulus,
                                double poisson,
                                const std::vector<DirichletBC>& bcs,
                                const std::vector<NodalLoad>& loads,
                                const std::vector<double>* elem_youngs,
                                const char* who, CgInfo* info) {
  const int num_nodes = fea_node_count(grid);
  const int ndof = 3 * num_nodes;

  MatfreeReduced m;
  m.ndof = ndof;
  m.Ke = hex8_stiffness(elem_youngs != nullptr ? 1.0 : youngs_modulus, poisson,
                        grid.spacing);
  m.elems = mf_build_elems(grid, elem_youngs, who);
  m.xfull.assign(static_cast<std::size_t>(ndof), 0.0);
  m.yfull.assign(static_cast<std::size_t>(ndof), 0.0);

  // Dirichlet BCs -> fixed mask + prescribed field up (validate indices).
  std::vector<char> fixed(static_cast<std::size_t>(ndof), 0);
  m.up.assign(static_cast<std::size_t>(ndof), 0.0);
  bool nonzero_bc = false;
  for (const DirichletBC& bc : bcs) {
    if (bc.node < 0 || bc.node >= num_nodes || bc.component < 0 ||
        bc.component > 2)
      throw std::invalid_argument(std::string(who) + ": BC index out of range");
    const int dof = 3 * bc.node + bc.component;
    fixed[static_cast<std::size_t>(dof)] = 1;
    m.up[static_cast<std::size_t>(dof)] = bc.value;
    if (bc.value != 0.0) nonzero_bc = true;
  }

  // Load vector (validate indices).
  std::vector<double> f(static_cast<std::size_t>(ndof), 0.0);
  for (const NodalLoad& l : loads) {
    if (l.node < 0 || l.node >= num_nodes || l.component < 0 || l.component > 2)
      throw std::invalid_argument(std::string(who) + ": load index out of range");
    f[static_cast<std::size_t>(3 * l.node + l.component)] += l.value;
  }

  // rhs_full = f - K*up. up is all-zero unless a prescribed non-zero BC exists,
  // in which case K*up is the matrix-free apply of the prescribed field.
  std::vector<double> rhs_full = f;
  if (nonzero_bc) {
    std::vector<double> kup(static_cast<std::size_t>(ndof), 0.0);
    mf_apply_full(m.elems, m.Ke, m.up, kup);
    for (int d = 0; d < ndof; ++d)
      rhs_full[static_cast<std::size_t>(d)] -= kup[static_cast<std::size_t>(d)];
  }

  // Free-DOF numbering.
  std::vector<int> free_of_dof(static_cast<std::size_t>(ndof), -1);
  int nf = 0;
  for (int d = 0; d < ndof; ++d)
    if (!fixed[static_cast<std::size_t>(d)]) free_of_dof[static_cast<std::size_t>(d)] = nf++;

  // M3.1 void-DOF gate, resolved topologically: a free DOF survives iff a solid
  // element touches it (equivalent to the assembled non-zero-diagonal test for
  // strictly-positive moduli). Also accumulate the Jacobi diagonal in the same
  // sweep (diag[d] += factor_e * Ke(local,local)).
  std::vector<char> touched(static_cast<std::size_t>(nf), 0);
  std::vector<double> diagfull(static_cast<std::size_t>(ndof), 0.0);
  for (const MfElem& el : m.elems)
    for (int r = 0; r < kDof; ++r) {
      const int fr = free_of_dof[static_cast<std::size_t>(el.edof[r])];
      if (fr >= 0) touched[static_cast<std::size_t>(fr)] = 1;
      diagfull[static_cast<std::size_t>(el.edof[r])] +=
          el.factor * m.Ke(r, r);
    }

  // Under-constrained: every free DOF void (no stiffness anywhere).
  if (nf > 0) {
    bool any = false;
    for (int fr = 0; fr < nf; ++fr)
      if (touched[static_cast<std::size_t>(fr)]) { any = true; break; }
    if (!any) {
      if (info) { info->converged = false; info->iterations = 0; info->residual = 0.0; }
      throw std::runtime_error(
          std::string(who) +
          ": singular system (no stiffness — every free DOF is void)");
    }
  }

  // Void-load check: a load on a stiffness-free (void) free DOF has no
  // equilibrium. rmax over ALL free DOFs of |rhs_full| (matches the assembled
  // gate, which forms rmax over the reduced RHS rf).
  double rmax = 0.0;
  for (int d = 0; d < ndof; ++d) {
    const int fr = free_of_dof[static_cast<std::size_t>(d)];
    if (fr >= 0) rmax = std::max(rmax, std::fabs(rhs_full[static_cast<std::size_t>(d)]));
  }
  const double load_tol = 1e-9 * rmax;
  for (int d = 0; d < ndof; ++d) {
    const int fr = free_of_dof[static_cast<std::size_t>(d)];
    if (fr < 0 || touched[static_cast<std::size_t>(fr)]) continue;
    if (std::fabs(rhs_full[static_cast<std::size_t>(d)]) > load_tol) {
      if (info) { info->converged = false; info->iterations = 0; info->residual = 0.0; }
      throw std::runtime_error(
          std::string(who) +
          ": under-constrained system (load applied to a void DOF with no "
          "stiffness — no equilibrium possible)");
    }
  }

  // Surviving free-DOF numbering + reduced RHS + Jacobi inverse diagonal.
  m.kept_global.clear();
  m.kept_global.reserve(static_cast<std::size_t>(nf));
  for (int d = 0; d < ndof; ++d) {
    const int fr = free_of_dof[static_cast<std::size_t>(d)];
    if (fr < 0 || !touched[static_cast<std::size_t>(fr)]) continue;
    m.kept_global.push_back(d);
  }
  m.ng = static_cast<int>(m.kept_global.size());
  m.rg.assign(static_cast<std::size_t>(m.ng), 0.0);
  m.invdiag.assign(static_cast<std::size_t>(m.ng), 0.0);
  for (int k = 0; k < m.ng; ++k) {
    const int d = m.kept_global[static_cast<std::size_t>(k)];
    m.rg[static_cast<std::size_t>(k)] = rhs_full[static_cast<std::size_t>(d)];
    m.invdiag[static_cast<std::size_t>(k)] =
        1.0 / diagfull[static_cast<std::size_t>(d)];
  }
  return m;
}

// Jacobi-preconditioned CG on the reduced system, replicating Eigen's
// ConjugateGradient<..., DiagonalPreconditioner> algorithm and convergence
// criterion (relative residual sqrt(||r||^2/||rhs||^2) <= tolerance) so the
// matrix-free solve converges to the same field. `x` is seeded (warm start or
// zero) and holds the solution on the kept DOFs.
void mf_cg_solve(const MatfreeReduced& m, double tolerance, int max_iterations,
                 std::vector<double>& x, int& iters_out, double& error_out,
                 bool& converged_out) {
  const int n = m.ng;
  const double tol = tolerance;
  const int maxIters = (max_iterations > 0) ? max_iterations : 2 * n;

  auto dot = [n](const std::vector<double>& a, const std::vector<double>& b) {
    double s = 0.0;
    for (int i = 0; i < n; ++i)
      s += a[static_cast<std::size_t>(i)] * b[static_cast<std::size_t>(i)];
    return s;
  };

  double rhsNorm2 = dot(m.rg, m.rg);
  if (rhsNorm2 == 0.0) {
    std::fill(x.begin(), x.end(), 0.0);
    iters_out = 0;
    error_out = 0.0;
    converged_out = true;
    return;
  }
  const double considerAsZero = std::numeric_limits<double>::min();
  double threshold = tol * tol * rhsNorm2;
  if (threshold < considerAsZero) threshold = considerAsZero;

  std::vector<double> residual(static_cast<std::size_t>(n));
  std::vector<double> tmp(static_cast<std::size_t>(n));
  m.apply_kgg(x, tmp);  // tmp = K x (x is the guess)
  for (int i = 0; i < n; ++i)
    residual[static_cast<std::size_t>(i)] =
        m.rg[static_cast<std::size_t>(i)] - tmp[static_cast<std::size_t>(i)];

  double residualNorm2 = dot(residual, residual);
  if (residualNorm2 < threshold) {
    iters_out = 0;
    error_out = std::sqrt(residualNorm2 / rhsNorm2);
    converged_out = (error_out <= tol);
    return;
  }

  std::vector<double> p(static_cast<std::size_t>(n));
  std::vector<double> z(static_cast<std::size_t>(n));
  for (int i = 0; i < n; ++i)  // p = M^-1 residual
    p[static_cast<std::size_t>(i)] =
        m.invdiag[static_cast<std::size_t>(i)] * residual[static_cast<std::size_t>(i)];
  double absNew = dot(residual, p);

  int i = 0;
  while (i < maxIters) {
    m.apply_kgg(p, tmp);  // tmp = K p
    const double alpha = absNew / dot(p, tmp);
    for (int q = 0; q < n; ++q) {
      x[static_cast<std::size_t>(q)] += alpha * p[static_cast<std::size_t>(q)];
      residual[static_cast<std::size_t>(q)] -= alpha * tmp[static_cast<std::size_t>(q)];
    }
    residualNorm2 = dot(residual, residual);
    if (residualNorm2 < threshold) break;
    for (int q = 0; q < n; ++q)
      z[static_cast<std::size_t>(q)] =
          m.invdiag[static_cast<std::size_t>(q)] * residual[static_cast<std::size_t>(q)];
    const double absOld = absNew;
    absNew = dot(residual, z);
    const double beta = absNew / absOld;
    for (int q = 0; q < n; ++q)
      p[static_cast<std::size_t>(q)] =
          z[static_cast<std::size_t>(q)] + beta * p[static_cast<std::size_t>(q)];
    ++i;
  }
  error_out = std::sqrt(residualNorm2 / rhsNorm2);
  iters_out = i;
  bool finite = true;
  for (int q = 0; q < n; ++q)
    if (!std::isfinite(x[static_cast<std::size_t>(q)])) { finite = false; break; }
  converged_out = (error_out <= tol) && finite;
}

}  // namespace fea_detail

namespace {

using fea_detail::MatfreeReduced;
using fea_detail::MfElem;

std::vector<double> matfree_apply_impl(const VoxelGrid& grid,
                                       double youngs_modulus, double poisson,
                                       const std::vector<double>* elem_youngs,
                                       const std::vector<double>& u) {
  const int ndof = 3 * fea_node_count(grid);
  if (static_cast<int>(u.size()) != ndof)
    throw std::invalid_argument(
        "fea_matfree_apply: u size != 3*fea_node_count");
  // Uniform: Ke carries the modulus, factor == 1. Graded: Ke is the unit-modulus
  // element, factor == per-voxel E (hex8 stiffness is exactly linear in E). This
  // matches the assembled path's two element builds byte-for-byte.
  const Hex8Stiffness Ke = hex8_stiffness(
      elem_youngs != nullptr ? 1.0 : youngs_modulus, poisson, grid.spacing);
  const std::vector<MfElem> elems =
      fea_detail::mf_build_elems(grid, elem_youngs, "fea_matfree_apply");
  std::vector<double> y(static_cast<std::size_t>(ndof), 0.0);
  fea_detail::mf_apply_full(elems, Ke, u, y);
  return y;
}

FeaSolution solve_cg_matfree_impl(const VoxelGrid& grid, double youngs_modulus,
                                  double poisson,
                                  const std::vector<DirichletBC>& bcs,
                                  const std::vector<NodalLoad>& loads,
                                  double tolerance, int max_iterations,
                                  CgInfo* info,
                                  const std::vector<double>* elem_youngs,
                                  const FeaSolution* initial_guess) {
  MatfreeReduced m = fea_detail::mf_build_reduced(
      grid, youngs_modulus, poisson, bcs, loads, elem_youngs,
      "fea_solve_cg_matfree", info);

  CgInfo diag;
  diag.converged = true;  // no free DOFs -> trivially converged

  std::vector<double> u = m.up;  // full field seeded with prescribed values
  if (m.ng > 0) {
    std::vector<double> x(static_cast<std::size_t>(m.ng), 0.0);
    if (initial_guess != nullptr &&
        static_cast<int>(initial_guess->u.size()) == m.ndof)
      for (int k = 0; k < m.ng; ++k)
        x[static_cast<std::size_t>(k)] = initial_guess->u[static_cast<std::size_t>(
            m.kept_global[static_cast<std::size_t>(k)])];

    fea_detail::mf_cg_solve(m, tolerance, max_iterations, x, diag.iterations,
                            diag.residual, diag.converged);
    if (info) *info = diag;
    if (!diag.converged)
      throw std::runtime_error(
          "fea_solve_cg_matfree: CG did not reach the requested tolerance "
          "within max_iterations");
    for (int k = 0; k < m.ng; ++k)
      u[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(k)])] =
          x[static_cast<std::size_t>(k)];
  } else if (info) {
    *info = diag;
  }

  FeaSolution sol;
  sol.u = std::move(u);
  return sol;
}

}  // namespace

std::vector<double> fea_matfree_apply(const VoxelGrid& grid,
                                      double youngs_modulus, double poisson,
                                      const std::vector<double>& u) {
  return matfree_apply_impl(grid, youngs_modulus, poisson, nullptr, u);
}

std::vector<double> fea_matfree_apply(const VoxelGrid& grid,
                                      const std::vector<double>& youngs_per_voxel,
                                      double poisson,
                                      const std::vector<double>& u) {
  return matfree_apply_impl(grid, 1.0, poisson, &youngs_per_voxel, u);
}

std::size_t fea_matfree_operator_storage_doubles() {
  return static_cast<std::size_t>(Hex8Stiffness::kDof) * Hex8Stiffness::kDof;
}

FeaSolution fea_solve_cg_matfree(const VoxelGrid& grid, double youngs_modulus,
                                 double poisson,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 double tolerance, int max_iterations,
                                 CgInfo* info) {
  return solve_cg_matfree_impl(grid, youngs_modulus, poisson, bcs, loads,
                               tolerance, max_iterations, info, nullptr, nullptr);
}

FeaSolution fea_solve_cg_matfree(const VoxelGrid& grid,
                                 const std::vector<double>& youngs_per_voxel,
                                 double poisson,
                                 const std::vector<DirichletBC>& bcs,
                                 const std::vector<NodalLoad>& loads,
                                 double tolerance, int max_iterations,
                                 CgInfo* info, const FeaSolution* initial_guess) {
  return solve_cg_matfree_impl(grid, 1.0, poisson, bcs, loads, tolerance,
                               max_iterations, info, &youngs_per_voxel,
                               initial_guess);
}

}  // namespace topopt
