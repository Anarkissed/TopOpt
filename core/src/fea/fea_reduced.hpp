// Internal (non-installed) header shared by the FEA linear-solver translation
// units: assembly.cpp (assembly + direct/Jacobi-CG solve) and multigrid.cpp
// (geometric-multigrid-preconditioned CG). It exposes the Eigen-typed reduced
// system and the two structural helpers so the multigrid solver can build its
// grid hierarchy on the SAME BC-reduced, void-gated operator the Jacobi-CG
// solver uses — guaranteeing both solve the identical system Ku=f.
//
// This header is compiled only where assembly.cpp is (Eigen present); it is NOT
// part of the public topopt/ API, which stays Eigen-free (ARCHITECTURE §4).

#pragma once

#include <vector>

#include <Eigen/SparseCore>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace fea_detail {

using SpMat = Eigen::SparseMatrix<double>;
using Vec = Eigen::VectorXd;

// The constrained linear system reduced to its free DOFs: solve K_ff u_f = rf,
// then scatter u_f back into the full field `up` (which already carries the
// prescribed displacements) at the `freedofs` positions.
struct ReducedSystem {
  SpMat Kff;              // nf x nf, symmetric positive (semi-)definite
  Vec rf;                 // nf, reduced right-hand side
  std::vector<int> freedofs;
  Vec up;                 // ndof, full field seeded with prescribed values
  int ndof = 0;
};

// Assemble the global stiffness of all solid voxels (uniform or per-voxel
// graded modulus), apply loads and Dirichlet BCs, and reduce to the free DOFs.
// `who` names the caller in thrown messages. `elem_youngs` (size voxel_count)
// selects the graded path when non-null.
ReducedSystem assemble_reduced(const VoxelGrid& grid, double youngs_modulus,
                               double poisson,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               const char* who,
                               const std::vector<double>* elem_youngs = nullptr);

// M3.1 void-DOF safety gate. Returns the indices (into the reduced free-DOF
// numbering of Kff/rf) of the surviving non-void free DOFs — those with a
// non-negligible stiffness diagonal. Throws std::runtime_error if the system is
// genuinely under-constrained (every free DOF void, or a void DOF is loaded).
std::vector<int> void_dof_survivors(const SpMat& Kff, const Vec& rf,
                                    const char* who);

}  // namespace fea_detail
}  // namespace topopt
