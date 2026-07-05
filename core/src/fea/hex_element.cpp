#include "topopt/fea.hpp"

#include <cmath>
#include <stdexcept>

namespace topopt {
namespace {

// Natural (isoparametric) coordinates xi/eta/zeta in [-1, 1] of the 8 corner
// nodes, matching the bottom-CCW-then-top-CCW ordering documented in fea.hpp.
constexpr double kXi[8] = {-1, +1, +1, -1, -1, +1, +1, -1};
constexpr double kEta[8] = {-1, -1, +1, +1, -1, -1, +1, +1};
constexpr double kZeta[8] = {-1, -1, -1, -1, +1, +1, +1, +1};

// Integrate the element stiffness Ke = ∫ B^T D B dV of a cubic Hex8 of edge
// `h` with full 2x2x2 Gauss quadrature (exact for the trilinear hexahedron).
// `D` is the 6x6 constitutive matrix in Voigt order [xx,yy,zz,gxy,gyz,gzx] with
// engineering shear. Both the isotropic and the transversely isotropic elements
// differ only in D, so they share this integrator.
Hex8Stiffness integrate_hex8(const double D[6][6], double h) {
  // Full 2x2x2 Gauss rule (exact for the trilinear hexahedron), weights = 1.
  const double gp = 1.0 / std::sqrt(3.0);
  const double pts[2] = {-gp, +gp};

  // Isoparametric map for a cubic voxel: x = (h/2)(xi + 1), so the Jacobian is
  // (h/2) I, detJ = (h/2)^3 and dN/dx = (2/h) dN/dxi.
  const double half = h / 2.0;
  const double detJ = half * half * half;
  const double dnat_to_dx = 2.0 / h;

  Hex8Stiffness Ke;  // k{} is value-initialized to zero

  for (int ig = 0; ig < 2; ++ig)
    for (int jg = 0; jg < 2; ++jg)
      for (int kg = 0; kg < 2; ++kg) {
        const double xi = pts[ig];
        const double eta = pts[jg];
        const double zeta = pts[kg];

        // Shape-function derivatives, natural coords -> physical coords.
        double dNdx[8], dNdy[8], dNdz[8];
        for (int a = 0; a < 8; ++a) {
          const double xa = kXi[a], ea = kEta[a], za = kZeta[a];
          const double dNdxi = 0.125 * xa * (1.0 + eta * ea) * (1.0 + zeta * za);
          const double dNdeta = 0.125 * ea * (1.0 + xi * xa) * (1.0 + zeta * za);
          const double dNdzeta =
              0.125 * za * (1.0 + xi * xa) * (1.0 + eta * ea);
          dNdx[a] = dnat_to_dx * dNdxi;
          dNdy[a] = dnat_to_dx * dNdeta;
          dNdz[a] = dnat_to_dx * dNdzeta;
        }

        // Strain-displacement matrix B (6x24). Node a fills columns 3a..3a+2.
        double B[6][24] = {};
        for (int a = 0; a < 8; ++a) {
          const int cx = 3 * a, cy = 3 * a + 1, cz = 3 * a + 2;
          B[0][cx] = dNdx[a];
          B[1][cy] = dNdy[a];
          B[2][cz] = dNdz[a];
          B[3][cx] = dNdy[a];
          B[3][cy] = dNdx[a];
          B[4][cy] = dNdz[a];
          B[4][cz] = dNdy[a];
          B[5][cx] = dNdz[a];
          B[5][cz] = dNdx[a];
        }

        // DB = D * B (6x24), then Ke += B^T * DB * detJ (weight 1).
        double DB[6][24];
        for (int r = 0; r < 6; ++r)
          for (int col = 0; col < 24; ++col) {
            double s = 0.0;
            for (int m = 0; m < 6; ++m) s += D[r][m] * B[m][col];
            DB[r][col] = s;
          }
        for (int r = 0; r < 24; ++r)
          for (int col = 0; col < 24; ++col) {
            double s = 0.0;
            for (int m = 0; m < 6; ++m) s += B[m][r] * DB[m][col];
            Ke.k[static_cast<std::size_t>(r) * 24 + col] += s * detJ;
          }
      }

  return Ke;
}

}  // namespace

Hex8Stiffness hex8_stiffness(double youngs_modulus, double poisson,
                             double element_size) {
  const double E = youngs_modulus;
  const double nu = poisson;
  const double h = element_size;
  if (!(E > 0.0))
    throw std::invalid_argument("hex8_stiffness: youngs_modulus must be > 0");
  if (!(h > 0.0))
    throw std::invalid_argument("hex8_stiffness: element_size must be > 0");
  if (!(nu > -1.0 && nu < 0.5))
    throw std::invalid_argument("hex8_stiffness: poisson must be in (-1, 0.5)");

  // Isotropic constitutive matrix D (Voigt [xx,yy,zz,gxy,gyz,gzx], engineering
  // shear). Off-shear block only; shear rows are diagonal.
  const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
  double D[6][6] = {};
  D[0][0] = D[1][1] = D[2][2] = c * (1.0 - nu);
  D[0][1] = D[0][2] = D[1][0] = D[1][2] = D[2][0] = D[2][1] = c * nu;
  const double G = c * (1.0 - 2.0 * nu) / 2.0;  // = E / (2 (1 + nu))
  D[3][3] = D[4][4] = D[5][5] = G;

  return integrate_hex8(D, h);
}

Hex8Stiffness hex8_stiffness_transverse(double youngs_modulus, double poisson,
                                        double element_size,
                                        double z_knockdown) {
  const double E = youngs_modulus;
  const double nu = poisson;
  const double h = element_size;
  const double k = z_knockdown;
  if (!(E > 0.0))
    throw std::invalid_argument(
        "hex8_stiffness_transverse: youngs_modulus must be > 0");
  if (!(h > 0.0))
    throw std::invalid_argument(
        "hex8_stiffness_transverse: element_size must be > 0");
  if (!(nu > -1.0 && nu < 0.5))
    throw std::invalid_argument(
        "hex8_stiffness_transverse: poisson must be in (-1, 0.5)");
  if (!(k > 0.0 && k <= 1.0))
    throw std::invalid_argument(
        "hex8_stiffness_transverse: z_knockdown must be in (0, 1]");

  // Transversely isotropic D, layer plane = xy, layer normal = z. Derived by
  // softening the isotropic COMPLIANCE S (strain = S*stress) and inverting:
  //   S[zz][zz]  : 1/E   -> 1/(kE)   (z axial modulus E_z = k*E)
  //   S[yz][yz], S[zx][zx] : 1/G -> 1/(kG)  (transverse shears G_yz=G_zx=k*G)
  // with the in-plane block (S[xx],S[yy],S[xy] and their couplings) left at the
  // isotropic values, so E_x=E_y=E, nu_xy=nu, G_xy=G are unchanged. The normal
  // 3x3 block N of S (factored as (1/E)*M) inverts in closed form; writing the
  // stiffness normal block directly as E*M^{-1} makes k=1 collapse
  // algebraically to the isotropic D (c(1-nu) on the diagonal, c*nu off).
  //
  //       [ 1   -nu  -nu ]                          [ 1/k - nu^2   nu/k+nu^2  nu+nu^2 ]
  //   M = [ -nu  1   -nu ] ,  E*M^{-1} = (E/detM) * [ nu/k+nu^2    1/k-nu^2   nu+nu^2 ]
  //       [ -nu -nu  1/k ]                          [ nu+nu^2      nu+nu^2    1-nu^2  ]
  //   detM = (1+nu) * ((1-nu)/k - 2 nu^2)  (> 0 for nu in (-1,0.5), k in (0,1]).
  const double nu2 = nu * nu;
  const double detM = (1.0 + nu) * ((1.0 - nu) / k - 2.0 * nu2);
  const double s = E / detM;
  const double G = E / (2.0 * (1.0 + nu));

  double D[6][6] = {};
  D[0][0] = D[1][1] = s * (1.0 / k - nu2);
  D[2][2] = s * (1.0 - nu2);
  D[0][1] = D[1][0] = s * (nu / k + nu2);
  D[0][2] = D[2][0] = D[1][2] = D[2][1] = s * (nu + nu2);
  D[3][3] = G;             // in-plane shear (xy) — unchanged
  D[4][4] = D[5][5] = k * G;  // transverse shears (yz, zx) — knocked down

  return integrate_hex8(D, h);
}

Hex8Stress hex8_stress(double youngs_modulus, double poisson,
                       double element_size,
                       const std::array<double, 24>& u_elem, double xi,
                       double eta, double zeta) {
  const double E = youngs_modulus;
  const double nu = poisson;
  const double h = element_size;
  if (!(E > 0.0))
    throw std::invalid_argument("hex8_stress: youngs_modulus must be > 0");
  if (!(h > 0.0))
    throw std::invalid_argument("hex8_stress: element_size must be > 0");
  if (!(nu > -1.0 && nu < 0.5))
    throw std::invalid_argument("hex8_stress: poisson must be in (-1, 0.5)");

  // Same isotropic D (Voigt [xx,yy,zz,gxy,gyz,gzx], engineering shear) as
  // hex8_stiffness, so stress = D * (engineering strain) yields true shear
  // stresses tau = G * gamma directly.
  const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
  double D[6][6] = {};
  D[0][0] = D[1][1] = D[2][2] = c * (1.0 - nu);
  D[0][1] = D[0][2] = D[1][0] = D[1][2] = D[2][0] = D[2][1] = c * nu;
  const double G = c * (1.0 - 2.0 * nu) / 2.0;  // = E / (2 (1 + nu))
  D[3][3] = D[4][4] = D[5][5] = G;

  // Shape-function derivatives at (xi,eta,zeta), natural -> physical coords
  // (same isoparametric map as hex8_stiffness: dN/dx = (2/h) dN/dxi).
  const double dnat_to_dx = 2.0 / h;
  double dNdx[8], dNdy[8], dNdz[8];
  for (int a = 0; a < 8; ++a) {
    const double xa = kXi[a], ea = kEta[a], za = kZeta[a];
    const double dNdxi = 0.125 * xa * (1.0 + eta * ea) * (1.0 + zeta * za);
    const double dNdeta = 0.125 * ea * (1.0 + xi * xa) * (1.0 + zeta * za);
    const double dNdzeta = 0.125 * za * (1.0 + xi * xa) * (1.0 + eta * ea);
    dNdx[a] = dnat_to_dx * dNdxi;
    dNdy[a] = dnat_to_dx * dNdeta;
    dNdz[a] = dnat_to_dx * dNdzeta;
  }

  // Strain-displacement matrix B (6x24), identical layout to hex8_stiffness.
  double B[6][24] = {};
  for (int a = 0; a < 8; ++a) {
    const int cx = 3 * a, cy = 3 * a + 1, cz = 3 * a + 2;
    B[0][cx] = dNdx[a];
    B[1][cy] = dNdy[a];
    B[2][cz] = dNdz[a];
    B[3][cx] = dNdy[a];
    B[3][cy] = dNdx[a];
    B[4][cy] = dNdz[a];
    B[4][cz] = dNdy[a];
    B[5][cx] = dNdz[a];
    B[5][cz] = dNdx[a];
  }

  // Engineering strain = B u, then Cauchy stress = D * strain.
  double strain[6];
  for (int r = 0; r < 6; ++r) {
    double s = 0.0;
    for (int col = 0; col < 24; ++col) s += B[r][col] * u_elem[col];
    strain[r] = s;
  }
  Hex8Stress out;
  for (int r = 0; r < 6; ++r) {
    double s = 0.0;
    for (int m = 0; m < 6; ++m) s += D[r][m] * strain[m];
    out.sigma[static_cast<std::size_t>(r)] = s;
  }

  const double sxx = out.sigma[0], syy = out.sigma[1], szz = out.sigma[2];
  const double txy = out.sigma[3], tyz = out.sigma[4], tzx = out.sigma[5];
  out.von_mises = std::sqrt(
      0.5 * ((sxx - syy) * (sxx - syy) + (syy - szz) * (syy - szz) +
             (szz - sxx) * (szz - sxx)) +
      3.0 * (txy * txy + tyz * tyz + tzx * tzx));
  return out;
}

}  // namespace topopt
