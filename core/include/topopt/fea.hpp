#pragma once

#include <array>

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

}  // namespace topopt
