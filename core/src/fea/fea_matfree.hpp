// Internal (non-installed) header shared by the matrix-free FEA translation
// units: matfree.cpp (the matrix-free operator + matrix-free Jacobi-CG) and
// multigrid.cpp (which reuses the matrix-free apply, diagonal, void gate and
// reduced-system build as the FINE level of the matrix-free multigrid solver).
//
// It exposes the element table, the element-by-element apply, the reduced,
// void-gated matrix-free system, and the matrix-free Jacobi-CG so the multigrid
// solver builds its FINEST level WITHOUT ever assembling the global stiffness K
// — that assembled fine K is what OOMs on large design-box grids. Everything
// here is deliberately Eigen-FREE (like matfree.cpp): no Eigen header, no sparse
// matrix; the only dense storage representing K is the single 24x24 reference
// element stiffness Ke (576 doubles), independent of grid size.
//
// This header is NOT part of the public topopt/ API (which stays Eigen-free per
// ARCHITECTURE §4); it is compiled only into the library.

#pragma once

#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace fea_detail {

// One solid element in the fixed grid-scan order: its per-voxel modulus scale
// and its 24 global DOF indices (node-major interleaved, matching hex8_stiffness).
struct MfElem {
  double factor = 1.0;
  int edof[Hex8Stiffness::kDof];
};

// Build the solid-element table (edof + factor). `elem_youngs` selects the graded
// path (factor = per-voxel modulus, validated > 0) when non-null; otherwise the
// uniform path (factor = 1, the modulus already baked into Ke). `who` names the
// caller in thrown messages.
std::vector<MfElem> mf_build_elems(const VoxelGrid& grid,
                                   const std::vector<double>* elem_youngs,
                                   const char* who);

// y = K x over the FULL global stiffness, element-by-element. `x` and `y` are
// full ndof vectors; `y` is overwritten (zeroed) then accumulated. No assembled
// K: only the reference Ke and the local 24-DOF gather/scatter.
void mf_apply_full(const std::vector<MfElem>& elems, const Hex8Stiffness& Ke,
                   const std::vector<double>& x, std::vector<double>& y);

// The reduced, void-gated system in matrix-free form. `kept_global[kg]` is the
// global DOF of surviving free DOF kg; `apply_kgg` realises y_g = K_gg x_g by
// scatter -> full apply -> gather, reusing full-length scratch across iterations.
// This is exactly K restricted to the kept DOFs (fixed and void DOFs carry a zero
// in the scattered vector and are never read back), so it equals the assembled
// reduced operator DOF-for-DOF.
struct MatfreeReduced {
  std::vector<MfElem> elems;
  Hex8Stiffness Ke;
  int ndof = 0;
  int ng = 0;                       // surviving free-DOF count
  std::vector<int> kept_global;     // kg -> global DOF
  std::vector<double> up;           // full field seeded with prescribed values
  std::vector<double> rg;           // ng reduced RHS
  std::vector<double> invdiag;      // ng Jacobi inverse diagonal (matrix-free)
  // Reused full-length scratch for the matvec.
  mutable std::vector<double> xfull, yfull;

  void apply_kgg(const std::vector<double>& xg, std::vector<double>& yg) const;
};

// Build the matrix-free reduced system. Mirrors assemble_reduced + the M3.1 gate
// (void_dof_survivors) but WITHOUT assembling a sparse matrix. On a void-gate
// rejection it sets `*info` (converged=false, 0 iterations) and throws, matching
// solve_reduced_cg. `who` names the caller in thrown messages.
MatfreeReduced mf_build_reduced(const VoxelGrid& grid, double youngs_modulus,
                                double poisson,
                                const std::vector<DirichletBC>& bcs,
                                const std::vector<NodalLoad>& loads,
                                const std::vector<double>* elem_youngs,
                                const char* who, CgInfo* info);

// Matrix-free Jacobi-preconditioned CG on the reduced system `m`, replicating
// Eigen's ConjugateGradient<..., DiagonalPreconditioner> algorithm and relative-
// residual criterion (sqrt(||r||^2/||rhs||^2) <= tolerance). `x` is seeded (warm
// start or zero) and holds the solution on the kept DOFs on return. This is the
// EXACT matrix-free solve; the multigrid path uses it as its exact fallback.
void mf_cg_solve(const MatfreeReduced& m, double tolerance, int max_iterations,
                 std::vector<double>& x, int& iters_out, double& error_out,
                 bool& converged_out);

}  // namespace fea_detail
}  // namespace topopt
