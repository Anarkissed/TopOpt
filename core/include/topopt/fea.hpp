#pragma once

#include <array>
#include <stdexcept>
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

// Transversely isotropic 8-node hexahedral element stiffness (ROADMAP M4.1).
// The plane of isotropy is the FDM print-layer plane (x, y); the layer-normal
// (build) axis is z. The in-plane engineering constants are the full isotropic
// (E, nu) values; the z axis is knocked down by `z_knockdown` = k, in (0, 1]
// (materials.json `z_knockdown` per ARCHITECTURE §4/§6; resins use 1.0):
//   E_x = E_y = E,   E_z = k * E,   nu_xy = nu,
//   G_xy = E / (2 (1 + nu)),        G_yz = G_zx = k * G_xy.
// It is built by softening the compliance (z axial + the two transverse shears)
// and inverting; the in-plane compliance block is untouched, so E_x, nu_xy and
// G_xy are exactly the isotropic values and E_z is exactly k*E. k = 1 collapses
// to the isotropic hex8_stiffness(E, nu, element_size) (to floating-point
// roundoff), so isotropic mode is preserved. Same DOF order, Voigt convention
// and 2x2x2 quadrature as hex8_stiffness. Throws std::invalid_argument on
// non-physical material inputs (same checks as hex8_stiffness) and if
// z_knockdown is not in (0, 1].
Hex8Stiffness hex8_stiffness_transverse(double youngs_modulus, double poisson,
                                        double element_size, double z_knockdown);

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

// Self-weight body load (ROADMAP M4.2 / ARCHITECTURE §5: "load = gravity x
// density x voxel volume, applied per solid voxel, direction = chosen print
// orientation's build-plate normal"). Every solid voxel (tag != Empty) carries
// a body force of magnitude `gravity * density * grid.voxel_volume()` acting in
// the unit `direction`, lumped equally to the voxel's eight corner nodes (1/8
// each) and accumulated over shared nodes. For a cubic trilinear hex under a
// uniform body force the consistent (energy) load vector puts an equal share on
// each of the eight nodes, so this equal 1/8 lumping IS the consistent load.
// The result is one NodalLoad per (node, non-zero component), ready to pass to
// fea_solve / fea_solve_cg.
//
// `direction` is the direction the weight pulls (opposite the build-plate
// normal); the default is -z, i.e. gravity down the grid z axis. It need not be
// unit length — it is normalised internally. `density` and `gravity` are in
// caller-chosen consistent units (force = mass-density x acceleration x volume);
// the loader's density_g_cm3 and a chosen g fix the unit system. The layer
// normal for the transversely isotropic element (M4.1) is a separate concern;
// this function only builds the load vector.
//
// Throws std::invalid_argument if density < 0, gravity < 0, or `direction` has
// (near) zero length.
std::vector<NodalLoad> self_weight_loads(const VoxelGrid& grid, double density,
                                         double gravity,
                                         Vec3 direction = Vec3{0.0, 0.0, -1.0});

// Uniform-traction surface load over the exposed faces of the voxels carrying
// `tag` (ROADMAP M7.6-core / MOD-F1 D7: "a load group hands the solver a
// uniform traction over the combined area of its selected faces ... consistent
// nodal loads, never a centroid point force"). The loaded surface is every
// cell-face of a `tag` voxel whose axis-neighbour is not solid (Empty or off-
// grid) — i.e. the exposed boundary of the tagged region. The tag is typically
// VoxelTag::Load (the selection's tagged slab from tag_step_face), but any tag
// is accepted.
//
// `total_force` is the resultant spread as a uniform traction over that
// surface. Because the voxels are cubic every free face has the same area, so
// each free face carries total_force / face_count, distributed to its four
// corner nodes 1/4 each — the consistent (energy) load vector of a bilinear
// quad under a uniform traction. Contributions accumulate over shared nodes, so
// the emitted nodal loads sum EXACTLY to `total_force` and the load is genuinely
// distributed, never lumped at a centroid. `total_force`'s direction is applied
// uniformly to every free face regardless of that face's own normal (a fixed-
// direction traction: the UI's Gravity / Push / Pull, ROADMAP M7.6-app).
//
// Returns one NodalLoad per (node, non-zero component), ready to pass to
// fea_solve / fea_solve_cg. A zero `total_force` yields no loads. Throws
// std::invalid_argument if the tagged region has no exposed face — nothing to
// load (the tag is carried by no voxel, or only by fully-interior voxels).
std::vector<NodalLoad> traction_loads(const VoxelGrid& grid, VoxelTag tag,
                                      Vec3 total_force);

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
  // Set by fea_solve_mgcg: true if the geometric-multigrid-preconditioned CG
  // path ran, false if it fell back to (or the caller used) plain Jacobi-CG.
  // `mg_levels` is the number of grid levels in the multigrid hierarchy (0 when
  // multigrid did not run). The Jacobi-CG entry points leave both at their
  // defaults.
  bool used_multigrid = false;
  int mg_levels = 0;
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

// Geometric-multigrid-preconditioned CG variants of fea_solve_cg (handoff 072).
// These solve the IDENTICAL BC-reduced, void-gated system Ku=f as fea_solve_cg,
// to the same relative-residual `tolerance`, but precondition CG with a standard
// V-cycle geometric multigrid (vertex coarsening 2x/level, trilinear transfer,
// Galerkin coarse operators, damped-Jacobi smoother) instead of the weak Jacobi
// (diagonal) preconditioner. On the voxel grids the profile targets this cuts
// the CG iteration count by ~10-30x (handoff 072 reports the measured numbers).
//
// The multigrid preconditioner is a drop-in ACCELERATOR, not a different model:
// the converged displacement field — and hence compliance, sensitivities and the
// optimized design — are unchanged within tolerance. The solver is fully OPT-IN
// (nothing calls it unless a caller chooses it); the existing fea_solve_cg path
// is byte-for-byte untouched, so Gate-V2 and the reference path are unaffected.
//
// ROBUST FALLBACK: if a multigrid hierarchy is not applicable (the grid is not
// 2x-divisible enough to build >= 2 levels, or the coarsest level is too large
// for a direct solve) or MG-CG fails to converge / produces a non-finite field,
// the solver transparently FALLS BACK to the exact Jacobi-CG path — it never
// returns a wrong or unconverged result. `info->used_multigrid` reports which
// path actually ran. Throwing behaviour (bad BC/load index, void-gate rejection,
// CG non-convergence of the fallback) matches fea_solve_cg.
FeaSolution fea_solve_mgcg(const VoxelGrid& grid, double youngs_modulus,
                           double poisson, const std::vector<DirichletBC>& bcs,
                           const std::vector<NodalLoad>& loads,
                           double tolerance = 1e-8, int max_iterations = 0,
                           CgInfo* info = nullptr);

// Heterogeneous-material variant of fea_solve_mgcg: each solid voxel (i,j,k) uses
// its own Young's modulus youngs_per_voxel[grid.index(i,j,k)] (the SIMP graded
// path, E(rho)=rho^p*E0). Same contract, hierarchy and fallback as the uniform
// overload above; solves the identical system as the graded fea_solve_cg.
FeaSolution fea_solve_mgcg(const VoxelGrid& grid,
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
