#include "topopt/fea.hpp"

#include <cmath>
#include <stdexcept>
#include <string>

#include "fea_matfree.hpp"  // fea_detail::hex8_cubic_reference_blocks/_validate

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

namespace {

// Build the cubic constitutive matrix D (Voigt [xx,yy,zz,gxy,gyz,gzx], engineering
// shear) from the three cubic constants and validate physical admissibility. Shared
// by hex8_stiffness_cubic and hex8_stress_cubic so the two agree on the tensor.
void cubic_D(double C11, double C12, double C44, double h, const char* who,
             double D[6][6]) {
  if (!(h > 0.0))
    throw std::invalid_argument(std::string(who) + ": element_size must be > 0");
  fea_detail::hex8_cubic_validate(C11, C12, C44, who);
  for (int r = 0; r < 6; ++r)
    for (int c = 0; c < 6; ++c) D[r][c] = 0.0;
  D[0][0] = D[1][1] = D[2][2] = C11;
  D[0][1] = D[0][2] = D[1][0] = D[1][2] = D[2][0] = D[2][1] = C12;
  D[3][3] = D[4][4] = D[5][5] = C44;
}

}  // namespace

namespace fea_detail {

// The ONE cubic admissibility rule (extracted from cubic_D so the matrix-free
// cubic element build validates per-voxel tensors identically to the assembled
// path). Positive-definiteness of a cubic tensor: the normal block has
// eigenvalues C11 - C12 (double) and C11 + 2*C12 (single); the shear block is
// 3*C44. All three must be > 0 for a physical (SPD) material.
void hex8_cubic_validate(double C11, double C12, double C44, const char* who) {
  if (!(C44 > 0.0))
    throw std::invalid_argument(std::string(who) + ": C44 must be > 0");
  if (!(C11 - C12 > 0.0))
    throw std::invalid_argument(std::string(who) + ": C11 - C12 must be > 0");
  if (!(C11 + 2.0 * C12 > 0.0))
    throw std::invalid_argument(std::string(who) + ": C11 + 2*C12 must be > 0");
}

// The three fixed reference blocks of the exact cubic decomposition
// Ke = C11*K_A + C12*K_B + C44*K_C (PR 252 bar d1: worst rel err 8.5e-16 over
// 8,696 cases), integrated by THE SAME integrate_hex8 hex8_stiffness_cubic
// uses, on the three 0/1 D-matrices the decomposition splits D into. These are
// basis blocks, not physical tensors, so no admissibility check applies (D_A
// alone has C44 = 0 — the SUM the apply forms is what must be admissible, and
// the element build validates each voxel's triplet before it enters the table).
void hex8_cubic_reference_blocks(double element_size, Hex8Stiffness& KA,
                                 Hex8Stiffness& KB, Hex8Stiffness& KC) {
  if (!(element_size > 0.0))
    throw std::invalid_argument(
        "hex8_cubic_reference_blocks: element_size must be > 0");
  double DA[6][6] = {}, DB[6][6] = {}, DC[6][6] = {};
  DA[0][0] = DA[1][1] = DA[2][2] = 1.0;
  DB[0][1] = DB[0][2] = DB[1][0] = DB[1][2] = DB[2][0] = DB[2][1] = 1.0;
  DC[3][3] = DC[4][4] = DC[5][5] = 1.0;
  KA = integrate_hex8(DA, element_size);
  KB = integrate_hex8(DB, element_size);
  KC = integrate_hex8(DC, element_size);
}

}  // namespace fea_detail

// The PUBLIC name of the decomposition (task multiscale-lattice-to) — ONE
// implementation, two names: the library-internal fea_detail one the matrix-free
// kernel and the Galerkin coarse build already use, and this, so the SIMP loop can
// form the multiscale sensitivity without reaching into a private header. Forwarding,
// never a second integration, so the blocks the optimizer differentiates against are
// the SAME blocks the solver applies.
void hex8_cubic_blocks(double element_size, Hex8Stiffness& KA, Hex8Stiffness& KB,
                       Hex8Stiffness& KC) {
  fea_detail::hex8_cubic_reference_blocks(element_size, KA, KB, KC);
}

Hex8Stiffness hex8_stiffness_cubic(double C11, double C12, double C44,
                                   double element_size) {
  double D[6][6];
  cubic_D(C11, C12, C44, element_size, "hex8_stiffness_cubic", D);
  return integrate_hex8(D, element_size);
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

Hex8Stress hex8_stress_cubic(double C11, double C12, double C44,
                             double element_size,
                             const std::array<double, 24>& u_elem, double xi,
                             double eta, double zeta) {
  double D[6][6];
  cubic_D(C11, C12, C44, element_size, "hex8_stress_cubic", D);

  // Same isoparametric B (6x24) at (xi,eta,zeta) as hex8_stress.
  const double h = element_size;
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


// ── ★ THE 2-NODE SPATIAL FRAME ELEMENT ──────────────────────────────────────
// Standard Timoshenko frame. The shear parameter enters as
//     phi = 12 E I / (G k A L^2)
// and divides the bending block; phi = 0 recovers Euler-Bernoulli exactly. Shear
// flexibility is ADDITIVE ALONG THE LENGTH, so subdividing one strut into many short
// elements converges to the same answer as a single long one (verified: 20 elements
// of L/r = 0.25 reproduce the closed form for the whole member to 6 significant
// figures). That matters here because the tracer emits ~0.85 mm segments regardless
// of cell size, so every strut arrives pre-subdivided.
FrameStiffness frame2_stiffness(double youngs_modulus, double shear_modulus,
                                double area, double inertia_y, double inertia_z,
                                double torsion_j, double length,
                                double shear_k) {
  if (!(youngs_modulus > 0.0))
    throw std::invalid_argument("frame2_stiffness: youngs_modulus must be > 0");
  if (!(shear_modulus > 0.0))
    throw std::invalid_argument("frame2_stiffness: shear_modulus must be > 0");
  if (!(area > 0.0))
    throw std::invalid_argument("frame2_stiffness: area must be > 0");
  if (!(inertia_y > 0.0) || !(inertia_z > 0.0))
    throw std::invalid_argument("frame2_stiffness: inertia must be > 0");
  if (!(torsion_j > 0.0))
    throw std::invalid_argument("frame2_stiffness: torsion_j must be > 0");
  if (!(length > 0.0))
    throw std::invalid_argument("frame2_stiffness: length must be > 0");

  FrameStiffness out;
  auto at = [&out](int r, int c) -> double& {
    return out.k[static_cast<std::size_t>(r) * FrameStiffness::kDof + c];
  };
  const double E = youngs_modulus, G = shear_modulus, L = length;

  // axial (ux0, ux1)
  const double ea = E * area / L;
  at(0, 0) = at(6, 6) = ea;
  at(0, 6) = at(6, 0) = -ea;
  // torsion (rx0, rx1)
  const double gj = G * torsion_j / L;
  at(3, 3) = at(9, 9) = gj;
  at(3, 9) = at(9, 3) = -gj;

  // bending in two planes. (I, u_i, r_i, u_j, r_j, sign):
  //   z-inertia couples uy (1, 7) with rz (5, 11)   -- sign +1
  //   y-inertia couples uz (2, 8) with ry (4, 10)   -- sign -1
  struct Plane { double I; int u0, r0, u1, r1; double sgn; };
  const Plane planes[2] = {{inertia_z, 1, 5, 7, 11, 1.0},
                           {inertia_y, 2, 4, 8, 10, -1.0}};
  for (const Plane& p : planes) {
    const double phi =
        (shear_k > 0.0) ? 12.0 * E * p.I / (G * shear_k * area * L * L) : 0.0;
    const double d = 1.0 + phi;
    const double c1 = 12.0 * E * p.I / (L * L * L * d);
    const double c2 = 6.0 * E * p.I / (L * L * d);
    const double c3 = (4.0 + phi) * E * p.I / (L * d);
    const double c4 = (2.0 - phi) * E * p.I / (L * d);
    at(p.u0, p.u0) = at(p.u1, p.u1) = c1;
    at(p.u0, p.u1) = at(p.u1, p.u0) = -c1;
    at(p.r0, p.r0) = at(p.r1, p.r1) = c3;
    at(p.r0, p.r1) = at(p.r1, p.r0) = c4;
    const double s = p.sgn * c2;
    at(p.u0, p.r0) = at(p.r0, p.u0) = s;
    at(p.u0, p.r1) = at(p.r1, p.u0) = s;
    at(p.u1, p.r0) = at(p.r0, p.u1) = -s;
    at(p.u1, p.r1) = at(p.r1, p.u1) = -s;
  }
  return out;
}

double frame_shear_bending_ratio(double youngs_modulus, double poisson,
                                 double radius, double length, double shear_k) {
  if (!(youngs_modulus > 0.0))
    throw std::invalid_argument("frame_shear_bending_ratio: E must be > 0");
  if (!(poisson > -1.0 && poisson < 0.5))
    throw std::invalid_argument("frame_shear_bending_ratio: poisson out of range");
  if (!(radius > 0.0) || !(length > 0.0))
    throw std::invalid_argument("frame_shear_bending_ratio: geometry must be > 0");
  if (!(shear_k > 0.0))
    throw std::invalid_argument("frame_shear_bending_ratio: shear_k must be > 0");
  // chi = delta_shear / delta_bending for a tip-loaded cantilever
  //     = [P L /(k G A)] / [P L^3/(3 E I)] = 3 E I / (k G A L^2),  I/A = r^2/4
  const double G = youngs_modulus / (2.0 * (1.0 + poisson));
  const double r_over_L = radius / length;
  return 0.75 * (youngs_modulus / (shear_k * G)) * r_over_L * r_over_L;
}


// ── ★ TYING A BEAM NODE INTO A SOLID ELEMENT ────────────────────────────────
// Trilinear weights in hex8_stiffness's corner order. Partition of unity holds for
// any point (the weights are a product of affine factors), so a tie built from these
// reproduces a LINEAR displacement field exactly — which is the property that makes
// it a legitimate constraint rather than an interpolation guess.
FrameSolidTie frame_solid_tie(const Vec3& point, const Vec3& element_origin,
                              double element_size) {
  if (!(element_size > 0.0))
    throw std::invalid_argument("frame_solid_tie: element_size must be > 0");
  const double fx = (point.x - element_origin.x) / element_size;
  const double fy = (point.y - element_origin.y) / element_size;
  const double fz = (point.z - element_origin.z) / element_size;

  FrameSolidTie tie;
  tie.inside = (fx >= 0.0 && fx <= 1.0 && fy >= 0.0 && fy <= 1.0 &&
                fz >= 0.0 && fz <= 1.0);
  int n = 0;
  for (int kz = 0; kz < 2; ++kz) {
    const double wz = kz ? fz : (1.0 - fz);
    for (int jy = 0; jy < 2; ++jy) {
      const double wy = jy ? fy : (1.0 - fy);
      for (int ix = 0; ix < 2; ++ix) {
        const double wx = ix ? fx : (1.0 - fx);
        tie.weight[static_cast<std::size_t>(n++)] = wx * wy * wz;
      }
    }
  }
  return tie;
}

double frame_member_peak_stress(const FrameStiffness& k,
                                const std::array<double, 12>& u_local,
                                double radius) {
  if (!(radius > 0.0))
    throw std::invalid_argument("frame_member_peak_stress: radius must be > 0");
  const double area = M_PI * radius * radius;
  const double inertia = M_PI * radius * radius * radius * radius / 4.0;

  std::array<double, 12> f{};
  for (int i = 0; i < 12; ++i) {
    double acc = 0.0;
    for (int j = 0; j < 12; ++j) acc += k(i, j) * u_local[static_cast<std::size_t>(j)];
    f[static_cast<std::size_t>(i)] = acc;
  }
  // node 0 -> (N, My, Mz) = (0, 4, 5);  node 1 -> (6, 10, 11)
  const int probe[2][3] = {{0, 4, 5}, {6, 10, 11}};
  double worst = 0.0;
  for (const auto& p : probe) {
    const double n = std::fabs(f[static_cast<std::size_t>(p[0])]) / area;
    const double my = f[static_cast<std::size_t>(p[1])];
    const double mz = f[static_cast<std::size_t>(p[2])];
    const double bend = std::sqrt(my * my + mz * mz) * radius / inertia;
    worst = std::max(worst, n + bend);
  }
  return worst;
}


// ── ★ THE DKT PLATE-BENDING TRIANGLE ────────────────────────────────────────
// Batoz, Bathe & Ho (1980), eqs (27)-(31) and Appendix A, transcribed directly.
namespace {

// The nine-component H_x,xi / H_y,xi / H_x,eta / H_y,eta vectors of Appendix A.
// The paper's node numbering is 1,2,3 for the corners and 4,5,6 for the mid-points
// of sides 23, 31, 12 respectively; here index 0..2 and the coefficient arrays are
// indexed by k-4 (so a[0] is the paper's a_4, on side 23).
struct DktCoef { double a[3], b[3], c[3], d[3], e[3], P[3], q[3], r[3], t[3]; };

DktCoef dkt_coefficients(const double x[3], const double y[3]) {
  DktCoef C{};
  // k = 4,5,6 for sides ij = 23, 31, 12  (eq. 28)
  const int I[3] = {1, 2, 0};
  const int J[3] = {2, 0, 1};
  for (int k = 0; k < 3; ++k) {
    const double xij = x[I[k]] - x[J[k]];
    const double yij = y[I[k]] - y[J[k]];
    const double l2 = xij * xij + yij * yij;
    if (!(l2 > 0.0))
      throw std::invalid_argument("dkt_stiffness: degenerate triangle (zero-length side)");
    C.a[k] = -xij / l2;
    C.b[k] = 0.75 * xij * yij / l2;
    C.c[k] = (0.25 * xij * xij - 0.5 * yij * yij) / l2;
    C.d[k] = -yij / l2;
    C.e[k] = (0.25 * yij * yij - 0.5 * xij * xij) / l2;
    C.P[k] = -6.0 * xij / l2;          // = 6 a_k
    C.q[k] = 3.0 * xij * yij / l2;     // = 4 b_k
    C.r[k] = 3.0 * yij * yij / l2;
    C.t[k] = -6.0 * yij / l2;          // = 6 d_k
  }
  return C;
}

// Appendix A, verbatim. Index k-4: P[0]=P4, P[1]=P5, P[2]=P6, etc.
void dkt_H_derivatives(const DktCoef& C, double xi, double eta,
                       double Hxx[9], double Hyx[9], double Hxe[9], double Hye[9]) {
  const double P4 = C.P[0], P5 = C.P[1], P6 = C.P[2];
  const double q4 = C.q[0], q5 = C.q[1], q6 = C.q[2];
  const double r4 = C.r[0], r5 = C.r[1], r6 = C.r[2];
  const double t4 = C.t[0], t5 = C.t[1], t6 = C.t[2];

  Hxx[0] = P6 * (1 - 2 * xi) + (P5 - P6) * eta;
  Hxx[1] = q6 * (1 - 2 * xi) - (q5 + q6) * eta;
  Hxx[2] = -4 + 6 * (xi + eta) + r6 * (1 - 2 * xi) - eta * (r5 + r6);
  Hxx[3] = -P6 * (1 - 2 * xi) + eta * (P4 + P6);
  Hxx[4] = q6 * (1 - 2 * xi) - eta * (q6 - q4);
  Hxx[5] = -2 + 6 * xi + r6 * (1 - 2 * xi) + eta * (r4 - r6);
  Hxx[6] = -eta * (P5 + P4);
  Hxx[7] = eta * (q4 - q5);
  Hxx[8] = -eta * (r5 - r4);

  Hyx[0] = t6 * (1 - 2 * xi) + eta * (t5 - t6);
  Hyx[1] = 1 + r6 * (1 - 2 * xi) - eta * (r5 + r6);
  Hyx[2] = -q6 * (1 - 2 * xi) + eta * (q5 + q6);
  Hyx[3] = -t6 * (1 - 2 * xi) + eta * (t4 + t6);
  Hyx[4] = -1 + r6 * (1 - 2 * xi) + eta * (r4 - r6);
  Hyx[5] = -q6 * (1 - 2 * xi) - eta * (q4 - q6);
  Hyx[6] = -eta * (t4 + t5);
  Hyx[7] = eta * (r4 - r5);
  Hyx[8] = -eta * (q4 - q5);

  Hxe[0] = -P5 * (1 - 2 * eta) - xi * (P6 - P5);
  Hxe[1] = q5 * (1 - 2 * eta) - xi * (q5 + q6);
  Hxe[2] = -4 + 6 * (xi + eta) + r5 * (1 - 2 * eta) - xi * (r5 + r6);
  Hxe[3] = xi * (P4 + P6);
  Hxe[4] = xi * (q4 - q6);
  Hxe[5] = -xi * (r6 - r4);
  Hxe[6] = P5 * (1 - 2 * eta) - xi * (P4 + P5);
  Hxe[7] = q5 * (1 - 2 * eta) + xi * (q4 - q5);
  Hxe[8] = -2 + 6 * eta + r5 * (1 - 2 * eta) + xi * (r4 - r5);

  Hye[0] = -t5 * (1 - 2 * eta) - xi * (t6 - t5);
  Hye[1] = 1 + r5 * (1 - 2 * eta) - xi * (r5 + r6);
  Hye[2] = -q5 * (1 - 2 * eta) + xi * (q5 + q6);
  Hye[3] = xi * (t4 + t6);
  Hye[4] = xi * (r4 - r6);
  Hye[5] = -xi * (q4 - q6);
  Hye[6] = t5 * (1 - 2 * eta) - xi * (t4 + t5);
  Hye[7] = -1 + r5 * (1 - 2 * eta) + xi * (r4 - r5);
  Hye[8] = -q5 * (1 - 2 * eta) - xi * (q4 - q5);
}

}  // namespace

DktStiffness dkt_stiffness(const double x[3], const double y[3],
                           double youngs_modulus, double poisson,
                           double thickness) {
  if (!(youngs_modulus > 0.0))
    throw std::invalid_argument("dkt_stiffness: youngs_modulus must be > 0");
  if (!(poisson > -1.0 && poisson < 0.5))
    throw std::invalid_argument("dkt_stiffness: poisson out of range");
  if (!(thickness > 0.0))
    throw std::invalid_argument("dkt_stiffness: thickness must be > 0");

  const double x31 = x[2] - x[0], x12 = x[0] - x[1];
  const double y31 = y[2] - y[0], y12 = y[0] - y[1];
  const double twoA = x31 * y12 - x12 * y31;          // = 2A (under eq. 30)
  if (!(std::fabs(twoA) > 0.0))
    throw std::invalid_argument("dkt_stiffness: degenerate triangle (zero area)");
  const double A = 0.5 * std::fabs(twoA);

  // bending constitutive matrix D_b for an isotropic plate (eq. 12a)
  const double f = youngs_modulus * thickness * thickness * thickness /
                   (12.0 * (1.0 - poisson * poisson));
  const double Db[3][3] = {{f, f * poisson, 0.0},
                           {f * poisson, f, 0.0},
                           {0.0, 0.0, f * (1.0 - poisson) * 0.5}};

  const DktCoef C = dkt_coefficients(x, y);
  DktStiffness out;

  // EXACT with three points at the edge mid-nodes: the integrand is quadratic
  // (paper's note under eq. 31), so this is not an approximation.
  const double gp[3][2] = {{0.5, 0.0}, {0.5, 0.5}, {0.0, 0.5}};
  const double wgt = 1.0 / 6.0;                      // sum = 1/2, the ref triangle

  for (int g = 0; g < 3; ++g) {
    double Hxx[9], Hyx[9], Hxe[9], Hye[9];
    dkt_H_derivatives(C, gp[g][0], gp[g][1], Hxx, Hyx, Hxe, Hye);
    // eq. (30): B = (1/2A) [ y31*Hx,xi + y12*Hx,eta ;
    //                       -x31*Hy,xi - x12*Hy,eta ;
    //                       -x31*Hx,xi - x12*Hx,eta + y31*Hy,xi + y12*Hy,eta ]
    double B[3][9];
    for (int i = 0; i < 9; ++i) {
      B[0][i] = (y31 * Hxx[i] + y12 * Hxe[i]) / twoA;
      B[1][i] = (-x31 * Hyx[i] - x12 * Hye[i]) / twoA;
      B[2][i] = (-x31 * Hxx[i] - x12 * Hxe[i] + y31 * Hyx[i] + y12 * Hye[i]) / twoA;
    }
    // K += 2A * w * B^T Db B
    const double scale = 2.0 * A * wgt;
    for (int i = 0; i < 9; ++i) {
      double DB[3];
      for (int r2 = 0; r2 < 3; ++r2)
        DB[r2] = Db[r2][0] * B[0][i] + Db[r2][1] * B[1][i] + Db[r2][2] * B[2][i];
      for (int j = 0; j < 9; ++j)
        out.k[static_cast<std::size_t>(i) * 9 + j] +=
            scale * (B[0][j] * DB[0] + B[1][j] * DB[1] + B[2][j] * DB[2]);
    }
  }
  return out;
}


// ── ★ THE FLAT FACET SHELL TRIANGLE ─────────────────────────────────────────
ShellStiffness shell3_stiffness(const double x[3], const double y[3],
                                double youngs_modulus, double poisson,
                                double thickness, double drilling_factor) {
  if (!(youngs_modulus > 0.0))
    throw std::invalid_argument("shell3_stiffness: youngs_modulus must be > 0");
  if (!(poisson > -1.0 && poisson < 0.5))
    throw std::invalid_argument("shell3_stiffness: poisson out of range");
  if (!(thickness > 0.0))
    throw std::invalid_argument("shell3_stiffness: thickness must be > 0");

  const double x31 = x[2] - x[0], x12 = x[0] - x[1];
  const double y31 = y[2] - y[0], y12 = y[0] - y[1];
  const double twoA = x31 * y12 - x12 * y31;
  if (!(std::fabs(twoA) > 0.0))
    throw std::invalid_argument("shell3_stiffness: degenerate triangle");
  const double A = 0.5 * std::fabs(twoA);

  ShellStiffness out;
  auto at = [&out](int r, int c) -> double& {
    return out.k[static_cast<std::size_t>(r) * ShellStiffness::kDof + c];
  };

  // ── MEMBRANE: the constant-strain triangle. B is constant, so K = t*A*B^T D B
  // exactly -- no quadrature. Node i's shape function gradient is (b_i, c_i)/2A
  // with b_i = y_j - y_k, c_i = x_k - x_j (cyclic).
  const double b[3] = {y[1] - y[2], y[2] - y[0], y[0] - y[1]};
  const double c[3] = {x[2] - x[1], x[0] - x[2], x[1] - x[0]};
  const double dm = youngs_modulus / (1.0 - poisson * poisson);
  const double Dm[3][3] = {{dm, dm * poisson, 0.0},
                           {dm * poisson, dm, 0.0},
                           {0.0, 0.0, dm * (1.0 - poisson) * 0.5}};
  double Bm[3][6];
  for (int n = 0; n < 3; ++n) {
    Bm[0][2 * n + 0] = b[n] / twoA;  Bm[0][2 * n + 1] = 0.0;
    Bm[1][2 * n + 0] = 0.0;          Bm[1][2 * n + 1] = c[n] / twoA;
    Bm[2][2 * n + 0] = c[n] / twoA;  Bm[2][2 * n + 1] = b[n] / twoA;
  }
  // local dof index of membrane entry m (node m/2, component m%2 -> u or v)
  const int mdof[6] = {0, 1, 6, 7, 12, 13};
  for (int i = 0; i < 6; ++i) {
    double DB[3];
    for (int r = 0; r < 3; ++r)
      DB[r] = Dm[r][0] * Bm[0][i] + Dm[r][1] * Bm[1][i] + Dm[r][2] * Bm[2][i];
    for (int j = 0; j < 6; ++j)
      at(mdof[i], mdof[j]) += thickness * A *
          (Bm[0][j] * DB[0] + Bm[1][j] * DB[1] + Bm[2][j] * DB[2]);
  }

  // ── BENDING: the DKT triangle, scattered into (w, theta_x, theta_y).
  const DktStiffness Kb = dkt_stiffness(x, y, youngs_modulus, poisson, thickness);
  const int bdof[9] = {2, 3, 4, 8, 9, 10, 14, 15, 16};
  for (int i = 0; i < 9; ++i)
    for (int j = 0; j < 9; ++j) at(bdof[i], bdof[j]) += Kb(i, j);

  // ── DRILLING: theta_z tied to the membrane's OWN rotation (Hughes-Brezzi).
  // A naive penalty on theta_z alone does NOT work, and the failure is silent: the
  // membrane already represents in-plane rotation through u and v, theta_z
  // represents the same physical rotation, and a term that only couples the three
  // theta_z values leaves the DIFFERENCE between the two representations as a free
  // zero-energy mode. MEASURED: the element came back with nullity 7 instead of 6,
  // and a test that only checked six NAMED modes were force-free passed anyway --
  // asserting the nullity is what caught it.
  //
  // So penalise (theta_z - omega), where omega is the CST's constant in-plane
  // rotation (1/2)(dv/dx - du/dy) = (1/4A) sum (b_i v_i - c_i u_i). That couples the
  // two and removes the spurious mode. gamma is a penalty, not physics: a test
  // asserts a 100x sweep leaves real bending and membrane answers unchanged.
  if (drilling_factor > 0.0) {
    double mean_diag = 0.0;
    for (int i = 0; i < 9; ++i) mean_diag += Kb(i, i);
    mean_diag /= 9.0;
    const double gamma = drilling_factor * mean_diag;
    // The penalty is a FIELD integral, gamma/2 * int (theta_z - omega)^2 dA, with
    // theta_z interpolated LINEARLY over the triangle. A rank-1 form on the AVERAGE
    // theta_z is not enough -- it leaves the two differential theta_z modes free
    // (measured: nullity 8). The full integral constrains all three.
    //   int Ni Nj dA = (A/12)(1 + delta_ij),   int Ni dA = A/3,   omega is constant.
    const int tz[3] = {5, 11, 17};
    double w[18] = {};                          // omega as a linear form on the dof
    for (int n = 0; n < 3; ++n) {
      w[6 * n + 0] = -c[n] / (2.0 * twoA);      // -(1/4A) c_n u_n
      w[6 * n + 1] = b[n] / (2.0 * twoA);       // +(1/4A) b_n v_n
    }
    // theta_z^T M theta_z
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j)
        at(tz[i], tz[j]) += gamma * (A / 12.0) * ((i == j) ? 2.0 : 1.0);
    // -2 * (A/3) * theta_z_i * omega   (symmetrised)
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 18; ++j)
        if (w[j] != 0.0) {
          const double v = -gamma * (A / 3.0) * w[j];
          at(tz[i], j) += v;
          at(j, tz[i]) += v;
        }
    // + A * omega^2
    for (int i = 0; i < 18; ++i)
      for (int j = 0; j < 18; ++j)
        if (w[i] != 0.0 && w[j] != 0.0) at(i, j) += gamma * A * w[i] * w[j];
  }
  return out;
}

}  // namespace topopt
