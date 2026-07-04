// Global assembly, Dirichlet boundary conditions, nodal loads and a direct
// solve for the linear-elastic voxel FEA system (ROADMAP M2.2).
//
// The public API (topopt/fea.hpp) is deliberately Eigen-free: Eigen is the
// locked linear-algebra choice (ARCHITECTURE §4) but it stays an implementation
// detail here. This translation unit is compiled only when Eigen is available
// (see core/CMakeLists.txt), the same way the STEP importer is gated on OCCT.

#include "topopt/fea.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#include <Eigen/IterativeLinearSolvers>
#include <Eigen/SparseCholesky>
#include <Eigen/SparseCore>

namespace topopt {

namespace {

// Grid of corner nodes: one more node than voxels along each axis.
inline int nodes_x(const VoxelGrid& g) { return g.nx + 1; }
inline int nodes_y(const VoxelGrid& g) { return g.ny + 1; }
inline int nodes_z(const VoxelGrid& g) { return g.nz + 1; }

}  // namespace

int fea_node_count(const VoxelGrid& grid) {
  return nodes_x(grid) * nodes_y(grid) * nodes_z(grid);
}

int fea_node_index(const VoxelGrid& grid, int a, int b, int c) {
  return (c * nodes_y(grid) + b) * nodes_x(grid) + a;
}

std::array<int, 8> fea_element_nodes(const VoxelGrid& grid, int i, int j,
                                     int k) {
  // Bottom face CCW (z = k) then top face CCW (z = k+1), matching the Hex8
  // node order documented in fea.hpp.
  return {fea_node_index(grid, i, j, k),         fea_node_index(grid, i + 1, j, k),
          fea_node_index(grid, i + 1, j + 1, k), fea_node_index(grid, i, j + 1, k),
          fea_node_index(grid, i, j, k + 1),     fea_node_index(grid, i + 1, j, k + 1),
          fea_node_index(grid, i + 1, j + 1, k + 1),
          fea_node_index(grid, i, j + 1, k + 1)};
}

std::vector<int> fea_tagged_nodes(const VoxelGrid& grid, VoxelTag tag) {
  std::vector<int> nodes;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.tag(i, j, k) == tag) {
          const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
          nodes.insert(nodes.end(), en.begin(), en.end());
        }
  std::sort(nodes.begin(), nodes.end());
  nodes.erase(std::unique(nodes.begin(), nodes.end()), nodes.end());
  return nodes;
}

namespace {

using SpMat = Eigen::SparseMatrix<double>;
using Vec = Eigen::VectorXd;

// The constrained linear system reduced to its free DOFs: solve
// K_ff u_f = rf, then scatter u_f back into the full field `up` (which already
// carries the prescribed displacements) at the `freedofs` positions. Both
// fea_solve (direct) and fea_solve_cg (iterative) share this assembly + BC
// reduction; only the linear solve differs.
struct ReducedSystem {
  SpMat Kff;             // nf x nf, symmetric positive (semi-)definite
  Vec rf;                // nf, reduced right-hand side
  std::vector<int> freedofs;
  Vec up;                // ndof, full field seeded with prescribed values
  int ndof = 0;
};

ReducedSystem assemble_reduced(const VoxelGrid& grid, double youngs_modulus,
                               double poisson,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               const char* who) {
  const int num_nodes = fea_node_count(grid);
  const int ndof = 3 * num_nodes;

  // Element stiffness is identical for every voxel (uniform material, cubic
  // voxel edge). hex8_stiffness validates the material and throws on bad input.
  const Hex8Stiffness Ke = hex8_stiffness(youngs_modulus, poisson, grid.spacing);

  // --- Assemble the global stiffness from every solid voxel -----------------
  std::vector<Eigen::Triplet<double>> trips;
  trips.reserve(static_cast<std::size_t>(grid.solid_count()) * 576);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        int edof[24];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) edof[3 * a + c] = 3 * en[a] + c;
        for (int r = 0; r < 24; ++r)
          for (int c = 0; c < 24; ++c)
            trips.emplace_back(edof[r], edof[c], Ke(r, c));
      }
  SpMat K(ndof, ndof);
  K.setFromTriplets(trips.begin(), trips.end());

  // --- Load vector ----------------------------------------------------------
  Vec f = Vec::Zero(ndof);
  for (const NodalLoad& l : loads) {
    if (l.node < 0 || l.node >= num_nodes || l.component < 0 || l.component > 2)
      throw std::invalid_argument(std::string(who) + ": load index out of range");
    f[3 * l.node + l.component] += l.value;
  }

  // --- Dirichlet BCs: prescribed displacements ------------------------------
  std::vector<char> fixed(static_cast<std::size_t>(ndof), 0);
  Vec up = Vec::Zero(ndof);  // prescribed displacement vector
  for (const DirichletBC& bc : bcs) {
    if (bc.node < 0 || bc.node >= num_nodes || bc.component < 0 ||
        bc.component > 2)
      throw std::invalid_argument(std::string(who) + ": BC index out of range");
    const int dof = 3 * bc.node + bc.component;
    fixed[static_cast<std::size_t>(dof)] = 1;
    up[dof] = bc.value;
  }

  // Move prescribed displacements to the right-hand side: solve for the free
  // DOFs of K_ff u_f = f_f - (K u_prescribed)_f.
  const Vec rhs_full = f - K * up;

  ReducedSystem out;
  out.ndof = ndof;
  out.up = up;
  out.freedofs.reserve(static_cast<std::size_t>(ndof));
  for (int d = 0; d < ndof; ++d)
    if (!fixed[static_cast<std::size_t>(d)]) out.freedofs.push_back(d);
  const int nf = static_cast<int>(out.freedofs.size());

  if (nf > 0) {
    // Selection matrix P (nf x ndof): P * v keeps the free entries of v.
    SpMat P(nf, ndof);
    std::vector<Eigen::Triplet<double>> ptrips;
    ptrips.reserve(static_cast<std::size_t>(nf));
    for (int r = 0; r < nf; ++r) ptrips.emplace_back(r, out.freedofs[r], 1.0);
    P.setFromTriplets(ptrips.begin(), ptrips.end());

    // Materialise each product into an explicit sparse matrix (K_ff = P K P^T)
    // rather than chaining the whole expression, which keeps Eigen on the plain
    // sparse*sparse path.
    const SpMat KPt = K * P.transpose();  // ndof x nf
    out.Kff = P * KPt;                     // nf x nf, symmetric
    out.Kff.makeCompressed();
    out.rf = P * rhs_full;
  }
  return out;
}

}  // namespace

FeaSolution fea_solve(const VoxelGrid& grid, double youngs_modulus,
                      double poisson, const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads) {
  ReducedSystem s =
      assemble_reduced(grid, youngs_modulus, poisson, bcs, loads, "fea_solve");
  const int nf = static_cast<int>(s.freedofs.size());

  Vec u = s.up;
  if (nf > 0) {
    Eigen::SimplicialLDLT<SpMat> solver;
    solver.compute(s.Kff);
    if (solver.info() != Eigen::Success)
      throw std::invalid_argument(
          "fea_solve: singular system (insufficient constraints to remove "
          "rigid-body motion)");

    // Rank check on the factorisation itself: a rigid-body (zero-energy) mode
    // shows up as a near-zero pivot in the LDLT diagonal D, independent of
    // whether the load happens to be orthogonal to that mode (which would leave
    // the residual small and undetectable otherwise).
    const Vec d = solver.vectorD();
    double dmax = 0.0;
    double dmin = std::numeric_limits<double>::max();
    for (int i = 0; i < d.size(); ++i) {
      const double ad = std::fabs(d[i]);
      dmax = std::max(dmax, ad);
      dmin = std::min(dmin, ad);
    }
    if (!(dmax > 0.0) || dmin <= 1e-12 * dmax)
      throw std::invalid_argument(
          "fea_solve: singular system (insufficient constraints to remove "
          "rigid-body motion)");

    const Vec xf = solver.solve(s.rf);
    if (solver.info() != Eigen::Success || !xf.allFinite())
      throw std::invalid_argument("fea_solve: solve failed (singular system)");

    for (int r = 0; r < nf; ++r) u[s.freedofs[r]] = xf[r];
  }

  FeaSolution sol;
  sol.u.assign(u.data(), u.data() + s.ndof);
  return sol;
}

FeaSolution fea_solve_cg(const VoxelGrid& grid, double youngs_modulus,
                         double poisson, const std::vector<DirichletBC>& bcs,
                         const std::vector<NodalLoad>& loads, double tolerance,
                         int max_iterations, CgInfo* info) {
  ReducedSystem s = assemble_reduced(grid, youngs_modulus, poisson, bcs, loads,
                                     "fea_solve_cg");
  const int nf = static_cast<int>(s.freedofs.size());

  CgInfo diag;  // no free DOFs -> nothing to solve, trivially converged
  diag.converged = true;

  Vec u = s.up;
  if (nf > 0) {
    // Jacobi (diagonal) preconditioned CG — ARCHITECTURE §4's solver for voxel
    // FEA. DiagonalPreconditioner is exactly M = diag(K_ff), i.e. Jacobi. K_ff
    // is symmetric, so the solver views both triangles.
    Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper,
                             Eigen::DiagonalPreconditioner<double>>
        cg;
    cg.setTolerance(tolerance);
    if (max_iterations > 0) cg.setMaxIterations(max_iterations);
    cg.compute(s.Kff);
    if (cg.info() != Eigen::Success) {
      if (info) *info = diag;
      throw std::runtime_error(
          "fea_solve_cg: preconditioner setup failed on K_ff");
    }

    const Vec xf = cg.solve(s.rf);
    diag.iterations = static_cast<int>(cg.iterations());
    diag.residual = cg.error();
    diag.converged = (cg.info() == Eigen::Success) && xf.allFinite();
    if (info) *info = diag;
    if (!diag.converged)
      throw std::runtime_error(
          "fea_solve_cg: CG did not reach the requested tolerance within "
          "max_iterations");

    for (int r = 0; r < nf; ++r) u[s.freedofs[r]] = xf[r];
  } else if (info) {
    *info = diag;
  }

  FeaSolution sol;
  sol.u.assign(u.data(), u.data() + s.ndof);
  return sol;
}

}  // namespace topopt
