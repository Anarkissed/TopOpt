#pragma once

#include <array>
#include <vector>

#include "topopt/voxel.hpp"

namespace topopt {

// Linear-elastic FEA element library (ARCHITECTURE §4: 8-node hexahedral,
// one element per cubic voxel, small deformation).
//
// M2.1 provides the isotropic element stiffness matrix. The transversely
// isotropic variant (z_knockdown on the layer-normal axis) is M4.
//
// Element geometry — a cubic voxel of edge `element_size`, corner nodes ordered
// bottom face CCW then top face CCW:
//   n0(0,0,0) n1(1,0,0) n2(1,1,0) n3(0,1,0)      (z = 0)
//   n4(0,0,1) n5(1,0,1) n6(1,1,1) n7(0,1,1)      (z = element_size)
// (unit coordinates above are scaled by element_size).
//
// DOF order — node-major interleaved:
//   (u0x,u0y,u0z, u1x,u1y,u1z, ..., u7x,u7y,u7z)  -> 24 DOFs.
//
// Strain/stress use Voigt order [xx, yy, zz, gxy, gyz, gzx] with ENGINEERING
// shear strains (gamma = 2*eps). The matrix is integrated with full 2x2x2
// Gauss quadrature, which is exact for the trilinear hexahedron.

struct Hex8Stiffness {
  static constexpr int kNodes = 8;
  static constexpr int kDof = 24;  // 3 translational DOFs per node

  // Row-major 24x24 element stiffness matrix.
  std::array<double, static_cast<std::size_t>(kDof) * kDof> k{};

  double operator()(int row, int col) const {
    return k[static_cast<std::size_t>(row) * kDof + col];
  }
};

// Isotropic 8-node hexahedral element stiffness for Young's modulus
// `youngs_modulus` (> 0), Poisson ratio `poisson` (in (-1, 0.5)) and cubic
// voxel edge `element_size` (> 0). For fixed Poisson ratio the matrix scales
// as K(E, h) = E * h * K(1, 1). Throws std::invalid_argument on non-physical
// inputs.
Hex8Stiffness hex8_stiffness(double youngs_modulus, double poisson,
                             double element_size);

// Cauchy stress recovered at one point of a Hex8 element from its nodal
// displacements. `sigma` is Voigt order [xx, yy, zz, xy, yz, zx] with TRUE shear
// stresses (tau, not doubled). `von_mises` is the scalar von Mises equivalent
//   sqrt( 1/2[(sxx-syy)^2 + (syy-szz)^2 + (szz-sxx)^2] + 3(txy^2+tyz^2+tzx^2) ).
struct Hex8Stress {
  std::array<double, 6> sigma{};
  double von_mises = 0.0;
};

// Recover the stress at natural coordinates (xi, eta, zeta) in [-1, 1]^3 of a
// cubic Hex8 element of edge `element_size` for an isotropic material (E, nu),
// from the element's 24 nodal displacements `u_elem` (DOF order matching
// hex8_stiffness: node-major interleaved, node order bottom-CCW then top-CCW).
// Defaults to the element centroid (0, 0, 0). Throws std::invalid_argument on
// non-physical material inputs (same checks as hex8_stiffness).
Hex8Stress hex8_stress(double youngs_modulus, double poisson,
                       double element_size,
                       const std::array<double, 24>& u_elem, double xi = 0.0,
                       double eta = 0.0, double zeta = 0.0);

// ---------------------------------------------------------------------------
// Global linear-elastic system over a voxel grid (ROADMAP M2.2).
//
// Nodes sit at voxel corners: a grid of nx*ny*nz voxels has
// (nx+1)*(ny+1)*(nz+1) nodes. The global id of node (a,b,c) (0<=a<=nx,
// 0<=b<=ny, 0<=c<=nz) is (c*(ny+1)+b)*(nx+1)+a. Each node owns 3 translational
// DOFs; the global DOF of component comp (0=x, 1=y, 2=z) at node n is
// 3*n + comp.
//
// Each solid voxel (tag != Empty) contributes one isotropic Hex8 element. The
// element's eight corner nodes are listed in the Hex8 convention documented
// above (bottom face CCW then top face CCW), so global assembly is consistent
// with the element matrix.

// Number of nodes in the corner-node grid of `grid`.
int fea_node_count(const VoxelGrid& grid);

// Global node id of corner (a,b,c). No bounds checking.
int fea_node_index(const VoxelGrid& grid, int a, int b, int c);

// The eight global corner-node ids of voxel (i,j,k), in Hex8 node order.
std::array<int, 8> fea_element_nodes(const VoxelGrid& grid, int i, int j, int k);

// The distinct corner nodes of every voxel carrying `tag`, sorted ascending.
// This bridges M1.6 face tags (Load / Fixture) to the DOFs a caller loads or
// constrains — "loads on tagged voxels".
std::vector<int> fea_tagged_nodes(const VoxelGrid& grid, VoxelTag tag);

// Fix a single DOF (node, component) to a prescribed displacement `value`
// (usually 0). component is 0=x, 1=y, 2=z.
struct DirichletBC {
  int node = 0;
  int component = 0;
  double value = 0.0;
};

// A nodal force `value` applied to (node, component). A point load is one
// entry; a distributed load is the same force split across several nodes.
struct NodalLoad {
  int node = 0;
  int component = 0;
  double value = 0.0;
};

// Nodal displacement solution, DOF-ordered (size 3*fea_node_count).
struct FeaSolution {
  std::vector<double> u;
  double at(int node, int component) const {
    return u[static_cast<std::size_t>(3 * node + component)];
  }
};

// Assemble the global stiffness of all solid voxels (isotropic Hex8 with the
// given material and the grid's `spacing` as element edge), apply the loads and
// Dirichlet BCs, and solve K u = f with a sparse direct factorisation
// (ARCHITECTURE §4: SimplicialLDLT is acceptable for small problems; the CG
// solver for large voxel systems is M2.3). Prescribed non-zero displacements
// are supported.
//
// Throws std::invalid_argument if a BC/load references a node or component out
// of range, or if the constrained system is singular (the model is not
// sufficiently supported to remove rigid-body motion). Material errors (E<=0,
// nu not in (-1,0.5), spacing<=0) propagate from hex8_stiffness.
FeaSolution fea_solve(const VoxelGrid& grid, double youngs_modulus,
                      double poisson, const std::vector<DirichletBC>& bcs,
                      const std::vector<NodalLoad>& loads);

// Convergence diagnostics for the iterative solver fea_solve_cg. `iterations`
// is the number of CG iterations performed; `residual` is the final relative
// residual ||f_f - K_ff u_f|| / ||f_f|| reported by the solver; `converged` is
// true iff `residual` reached the requested tolerance within the iteration cap.
struct CgInfo {
  bool converged = false;
  int iterations = 0;
  double residual = 0.0;
};

// Solve the same global linear-elastic system as fea_solve, but with a Jacobi
// (diagonal) preconditioned Conjugate Gradient iterative solver — ARCHITECTURE
// §4's designated solver for voxel FEA. Intended for large grids (e.g. 64^3)
// where the sparse direct factorisation of fea_solve is too expensive in time
// and memory.
//
// `tolerance` is the CG stopping criterion on the relative residual. If
// `max_iterations > 0` it caps the iteration count; otherwise Eigen's default
// cap (twice the free-DOF count) is used. If `info` is non-null it receives the
// iteration count and final residual (also on the throwing path below).
//
// Throws std::runtime_error if CG does not reach `tolerance` within the
// iteration cap — a guard against silently returning an unconverged field
// (CG on a consistent system converges to *a* answer regardless). BC/load range
// validation and material errors match fea_solve. Prescribed non-zero
// displacements are supported.
FeaSolution fea_solve_cg(const VoxelGrid& grid, double youngs_modulus,
                         double poisson, const std::vector<DirichletBC>& bcs,
                         const std::vector<NodalLoad>& loads,
                         double tolerance = 1e-8, int max_iterations = 0,
                         CgInfo* info = nullptr);

// Heterogeneous-material variant of fea_solve_cg: each solid voxel (i,j,k) uses
// its own Young's modulus youngs_per_voxel[grid.index(i,j,k)] (Poisson ratio and
// cubic voxel edge = grid.spacing shared). Because the isotropic element
// stiffness is exactly linear in E, this assembles E_voxel * K_unit per element
// (K_unit = hex8_stiffness(1, poisson, spacing)). It is the assembly primitive
// SIMP needs to realise density-penalized stiffness E(rho)=rho^p*E0 (ROADMAP
// M3.2) and goes through the same M3.1 void-DOF safety gate and Jacobi-CG solve
// as the uniform overload above.
//
// `youngs_per_voxel` must have size grid.voxel_count(); entries for Empty voxels
// are ignored (those voxels contribute no element). Throws std::invalid_argument
// if the vector size mismatches, a solid voxel's modulus is not > 0, or a BC/load
// index is out of range; throws std::runtime_error on CG non-convergence or a
// void-gate structural rejection (as the uniform overload).
FeaSolution fea_solve_cg(const VoxelGrid& grid,
                         const std::vector<double>& youngs_per_voxel,
                         double poisson, const std::vector<DirichletBC>& bcs,
                         const std::vector<NodalLoad>& loads,
                         double tolerance = 1e-8, int max_iterations = 0,
                         CgInfo* info = nullptr);

// Per-voxel von Mises stress field, one value per grid cell (indexed like the
// grid, size grid.voxel_count()). Each solid voxel's value is the von Mises
// stress at its Hex8 element centroid, recovered from the displacement solution
// `sol` (as returned by fea_solve / fea_solve_cg) with the same material.
// Empty voxels receive 0. Material errors propagate from hex8_stress.
std::vector<double> fea_von_mises_field(const VoxelGrid& grid,
                                        double youngs_modulus, double poisson,
                                        const FeaSolution& sol);

}  // namespace topopt
