// lattice_anisotropy_probe.cpp — OFFLINE MEASUREMENT harness (handoff
// 2026-07-29-lattice-layer-anisotropy). NOT wired into CTest, NOT production, NO
// gate change. It measures ONE thing: how much the homogenized octet tensor and the
// interlayer stress change if the base material is FDM-anisotropic (transversely
// isotropic, in-plane vs interlayer) instead of the isotropic PLA the production
// library (PR 198) was measured on, across several strut-to-layer (build)
// orientations. Mirrors the sanctioned lattice_homog_probe.cpp pattern: octet
// voxelised programmatically, periodic-BC homogenisation solved with Eigen directly.
//
// The base material is built in the MATERIAL frame (layer plane = xy, layer normal =
// local z, exactly hex8_stiffness_transverse's convention) and ROTATED so the layer
// normal points along the chosen build direction in the (fixed) octet cell frame. The
// octet geometry never moves, so each orientation is the SAME struts printed with a
// different face down. We solve the full 6x6 effective tensor (a transverse base
// breaks octet's cubic symmetry) and, from the same corrector fields, recover the
// microscopic stress under a unit macro strain across the layers to get the
// strut-level interlayer stress concentration.
//
// Build (from core/):
//   cmake --build build --target topopt -j8   # once, for VoxelGrid + hex8_stiffness
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/lattice_anisotropy_probe.cpp build/libtopopt.a \
//       -o build/lattice_anisotropy_probe
//   TOPOPT_ANISO_CSV_DIR=../evidence/2026-07-29-lattice-layer-anisotropy \
//       ./build/lattice_anisotropy_probe

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <Eigen/Dense>
#include <Eigen/IterativeLinearSolvers>
#include <Eigen/SparseCore>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;  // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;   // PLA Poisson

// ---- octet geometry (verbatim from lattice_homog_probe.cpp) ----------------
double point_seg_dist2(double px, double py, double pz, const double a[3],
                       const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double denom = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = denom > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / denom : 0;
  t = std::max(0.0, std::min(1.0, t));
  double c[3] = {a[0] + t * ab[0], a[1] + t * ab[1], a[2] + t * ab[2]};
  double d[3] = {px - c[0], py - c[1], pz - c[2]};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}
std::vector<std::array<std::array<double, 3>, 2>> octet_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x) nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0},
                                                    {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5},
                                                    {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5},
                                                    {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  for (std::size_t fi = 8; fi < nodes.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0;
      for (int k = 0; k < 3; ++k) {
        double v = nodes[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (nodes[ci][k] - v) * (nodes[ci][k] - v);
      }
      if (d2 < 1e-9) segs.push_back({nodes[fi], nodes[ci]});
    }
  return segs;
}
double octet_dist2(double x, double y, double z, double L,
                   const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  double u = std::fmod(x, L) / L, v = std::fmod(y, L) / L, w = std::fmod(z, L) / L;
  if (u < 0) u += 1;
  if (v < 0) v += 1;
  if (w < 0) w += 1;
  double best = 1e30;
  for (auto& s : segs) {
    double d2 = point_seg_dist2(u, v, w, s[0].data(), s[1].data());
    if (d2 < best) best = d2;
  }
  return best * L * L;
}
VoxelGrid build_octet(double L, double r, int vpc) {
  VoxelGrid grid;
  grid.nx = grid.ny = grid.nz = vpc;
  grid.spacing = L / vpc;
  grid.origin = Vec3{0, 0, 0};
  grid.tags.assign((std::size_t)vpc * vpc * vpc, VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < vpc; ++k)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        Vec3 c = grid.voxel_center(i, j, k);
        if (octet_dist2(c.x, c.y, c.z, L, segs) < r * r)
          grid.set_tag(i, j, k, VoxelTag::Interior);
      }
  return grid;
}
double vol_frac(const VoxelGrid& g) {
  return (double)g.solid_count() / ((double)g.nx * g.ny * g.nz);
}
double calibrate_r(double L, double target_vf, int vpc) {
  double lo = 0.0005 * L, hi = 0.30 * L;
  for (int it = 0; it < 30; ++it) {
    double mid = 0.5 * (lo + hi);
    (vol_frac(build_octet(L, mid, vpc)) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// ---- constitutive: transverse-isotropic base D in the MATERIAL frame -------
// Copied algebra from hex8_stiffness_transverse (hex_element.cpp): layer plane xy,
// layer normal z, E_z = k*E, G_yz = G_zx = k*G. k = 1 collapses to isotropic.
void transverse_D(double E, double nu, double k, double D[6][6]) {
  for (int a = 0; a < 6; ++a) for (int b = 0; b < 6; ++b) D[a][b] = 0.0;
  const double nu2 = nu * nu;
  const double detM = (1.0 + nu) * ((1.0 - nu) / k - 2.0 * nu2);
  const double s = E / detM;
  const double G = E / (2.0 * (1.0 + nu));
  D[0][0] = D[1][1] = s * (1.0 / k - nu2);
  D[2][2] = s * (1.0 - nu2);
  D[0][1] = D[1][0] = s * (nu / k + nu2);
  D[0][2] = D[2][0] = D[1][2] = D[2][1] = s * (nu + nu2);
  D[3][3] = G;
  D[4][4] = D[5][5] = k * G;
}

// Voigt index <-> (i,j). Engineering-shear Voigt: 0:xx 1:yy 2:zz 3:xy 4:yz 5:zx.
constexpr int kVi[6] = {0, 1, 2, 0, 1, 2};
constexpr int kVj[6] = {0, 1, 2, 1, 2, 0};

// 6x6 engineering-Voigt D -> 4th-order tensor C[i][j][k][l].
void D_to_C4(const double D[6][6], double C[3][3][3][3]) {
  auto vidx = [](int i, int j) {
    if (i == j) return i;                       // 0,1,2
    if ((i == 0 && j == 1) || (i == 1 && j == 0)) return 3;
    if ((i == 1 && j == 2) || (i == 2 && j == 1)) return 4;
    return 5;                                    // xz/zx
  };
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      for (int k = 0; k < 3; ++k)
        for (int l = 0; l < 3; ++l)
          C[i][j][k][l] = D[vidx(i, j)][vidx(k, l)];
}
// 4th-order tensor -> 6x6 engineering-Voigt D (pick representative index pair).
void C4_to_D(const double C[3][3][3][3], double D[6][6]) {
  for (int I = 0; I < 6; ++I)
    for (int J = 0; J < 6; ++J)
      D[I][J] = C[kVi[I]][kVj[I]][kVi[J]][kVj[J]];
}
// Rotate a 6x6 engineering-Voigt stiffness by R (R columns = material basis in
// cell frame): D_cell = rotate(D_mat). Via the full 4th-order tensor to avoid any
// engineering-shear factor pitfalls.
void rotate_D(const double Dmat[6][6], const double R[3][3], double Dcell[6][6]) {
  double C[3][3][3][3], Cp[3][3][3][3];
  D_to_C4(Dmat, C);
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      for (int k = 0; k < 3; ++k)
        for (int l = 0; l < 3; ++l) {
          double s = 0;
          for (int p = 0; p < 3; ++p)
            for (int q = 0; q < 3; ++q)
              for (int rr = 0; rr < 3; ++rr)
                for (int t = 0; t < 3; ++t)
                  s += R[i][p] * R[j][q] * R[k][rr] * R[l][t] * C[p][q][rr][t];
          Cp[i][j][k][l] = s;
        }
  C4_to_D(Cp, Dcell);
}
// Orthonormal rotation whose 3rd column (material layer-normal) is unit(n).
void frame_from_normal(const double n[3], double R[3][3]) {
  double nn = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
  double e2[3] = {n[0] / nn, n[1] / nn, n[2] / nn};
  double a[3] = {1, 0, 0};
  if (std::fabs(e2[0]) > 0.9) { a[0] = 0; a[1] = 1; }
  // e0 = normalize(a - (a.e2) e2)
  double d = a[0] * e2[0] + a[1] * e2[1] + a[2] * e2[2];
  double e0[3] = {a[0] - d * e2[0], a[1] - d * e2[1], a[2] - d * e2[2]};
  double e0n = std::sqrt(e0[0] * e0[0] + e0[1] * e0[1] + e0[2] * e0[2]);
  for (double& v : e0) v /= e0n;
  double e1[3] = {e2[1] * e0[2] - e2[2] * e0[1], e2[2] * e0[0] - e2[0] * e0[2],
                  e2[0] * e0[1] - e2[1] * e0[0]};
  for (int i = 0; i < 3; ++i) { R[i][0] = e0[i]; R[i][1] = e1[i]; R[i][2] = e2[i]; }
}

// ---- general hex8 element stiffness from an arbitrary 6x6 D -----------------
// Trilinear 8-node hex on [0,h]^3, node order {0,0,0},{1,0,0},{1,1,0},{0,1,0}, then
// top (matches lattice_homog_probe kOff). 2x2x2 Gauss. Validated against
// hex8_stiffness for isotropic D (self-check H0 below).
constexpr int kOff[8][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0},
                            {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};
// B matrix (6x24) at natural coords, engineering shear Voigt.
void hex8_B(double xi, double eta, double zeta, double h, double B[6][24]) {
  const double sgn[8][3] = {{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
                            {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}};
  for (int a = 0; a < 6; ++a) for (int b = 0; b < 24; ++b) B[a][b] = 0.0;
  const double jinv = 2.0 / h;  // dNa/dx = (2/h) dNa/dxi (axis-aligned cube)
  for (int a = 0; a < 8; ++a) {
    double sx = sgn[a][0], sy = sgn[a][1], sz = sgn[a][2];
    double dNdxi = 0.125 * sx * (1 + sy * eta) * (1 + sz * zeta);
    double dNdet = 0.125 * sy * (1 + sx * xi) * (1 + sz * zeta);
    double dNdze = 0.125 * sz * (1 + sx * xi) * (1 + sy * eta);
    double bx = jinv * dNdxi, by = jinv * dNdet, bz = jinv * dNdze;
    int c0 = 3 * a, c1 = 3 * a + 1, c2 = 3 * a + 2;
    B[0][c0] = bx;
    B[1][c1] = by;
    B[2][c2] = bz;
    B[3][c0] = by; B[3][c1] = bx;
    B[4][c1] = bz; B[4][c2] = by;
    B[5][c0] = bz; B[5][c2] = bx;
  }
}
std::array<double, 576> ke_from_D(const double D[6][6], double h) {
  std::array<double, 576> ke{};
  const double g = 1.0 / std::sqrt(3.0);
  const double gp[2] = {-g, g};
  const double detJ = (h / 2) * (h / 2) * (h / 2);
  for (int ix = 0; ix < 2; ++ix)
    for (int iy = 0; iy < 2; ++iy)
      for (int iz = 0; iz < 2; ++iz) {
        double B[6][24];
        hex8_B(gp[ix], gp[iy], gp[iz], h, B);
        // DB = D*B (6x24)
        double DB[6][24];
        for (int r = 0; r < 6; ++r)
          for (int c = 0; c < 24; ++c) {
            double s = 0;
            for (int m = 0; m < 6; ++m) s += D[r][m] * B[m][c];
            DB[r][c] = s;
          }
        for (int r = 0; r < 24; ++r)
          for (int c = 0; c < 24; ++c) {
            double s = 0;
            for (int m = 0; m < 6; ++m) s += B[m][r] * DB[m][c];
            ke[r * 24 + c] += s * detJ;  // gauss weight 1
          }
      }
  return ke;
}

// chi0[dof][J]: nodal displacement producing unit macro strain mode J (geometry).
std::array<std::array<double, 6>, 24> element_chi0(double h) {
  std::array<std::array<double, 6>, 24> chi0{};
  for (int a = 0; a < 8; ++a) {
    double X = kOff[a][0] * h, Y = kOff[a][1] * h, Z = kOff[a][2] * h;
    int dx = 3 * a, dy = 3 * a + 1, dz = 3 * a + 2;
    chi0[dx][0] = X;             // eps_xx
    chi0[dy][1] = Y;             // eps_yy
    chi0[dz][2] = Z;             // eps_zz
    chi0[dx][3] = Y;             // gamma_xy
    chi0[dy][4] = Z;             // gamma_yz
    chi0[dz][5] = X;             // gamma_zx
  }
  return chi0;
}

using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;

struct HomogResult {
  double CH[6][6] = {};
  Eigen::MatrixXd X;   // corrector nodal fields, per strain column
  bool converged = true;
  int cg_iters = 0;
};

// Periodic-BC homogenisation with element stiffness ke (any base D). All 6 columns.
HomogResult homogenize(const VoxelGrid& grid, const std::array<double, 576>& ke) {
  HomogResult R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz, nd = 3 * Np;
  auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    return ((long)(c % nz) * ny + (b % ny)) * nx + (a % nx);
  };
  std::vector<Trip> trips;
  trips.reserve((std::size_t)grid.solid_count() * 576);
  Eigen::MatrixXd F = Eigen::MatrixXd::Zero(nd, 6);
  std::vector<char> touched((std::size_t)nd, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int r = 0; r < 24; ++r) {
          touched[gd[r]] = 1;
          for (int c = 0; c < 24; ++c)
            trips.emplace_back((int)gd[r], (int)gd[c], ke[r * 24 + c]);
          for (int J = 0; J < 6; ++J) {
            double f = 0;
            for (int c = 0; c < 24; ++c) f += ke[r * 24 + c] * chi0[c][J];
            F(gd[r], J) += f;
          }
        }
      }
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  for (long d = 0; d < nd; ++d) if (!touched[d]) pinned[d] = 1;
  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear();
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()])
        it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
  K.prune(0.0);
  for (long d = 0; d < nd; ++d) if (pinned[d]) for (int J = 0; J < 6; ++J) F(d, J) = 0.0;
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(1e-10);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 200000));
  cg.compute(K);
  R.X = Eigen::MatrixXd::Zero(nd, 6);
  for (int J = 0; J < 6; ++J) {
    Eigen::VectorXd x = cg.solve(F.col(J));
    R.X.col(J) = x;
    R.cg_iters = std::max(R.cg_iters, (int)cg.iterations());
    if (cg.info() != Eigen::Success) R.converged = false;
  }
  const double vol = (double)nx * ny * nz * h * h * h;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        for (int J = 0; J < 6; ++J) {
          double diffJ[24];
          for (int r = 0; r < 24; ++r) diffJ[r] = chi0[r][J] - R.X(gd[r], J);
          double kd[24];
          for (int r = 0; r < 24; ++r) {
            double s = 0;
            for (int c = 0; c < 24; ++c) s += ke[r * 24 + c] * diffJ[c];
            kd[r] = s;
          }
          for (int I = 0; I < 6; ++I) {
            double s = 0;
            for (int r = 0; r < 24; ++r) s += chi0[r][I] * kd[r];
            R.CH[I][J] += s / vol;
          }
        }
      }
  return R;
}

// Directional Young's modulus of a 6x6 stiffness CH along unit direction d.
double youngs_along(const double CH[6][6], const double d[3]) {
  // S = CH^{-1} (6x6). E_d = 1 / (eps_dd under unit uniaxial stress along d).
  Eigen::Matrix<double, 6, 6> C;
  for (int i = 0; i < 6; ++i) for (int j = 0; j < 6; ++j) C(i, j) = CH[i][j];
  Eigen::Matrix<double, 6, 6> S = C.inverse();
  // unit stress tensor sigma = d d^T -> stress Voigt (NO factor 2)
  Eigen::Matrix<double, 6, 1> sv;
  sv << d[0] * d[0], d[1] * d[1], d[2] * d[2], d[0] * d[1], d[1] * d[2], d[2] * d[0];
  Eigen::Matrix<double, 6, 1> ev = S * sv;  // engineering strain
  // eps_dd = eps_xx dx^2 + ... + gamma_xy dx dy + gamma_yz dy dz + gamma_zx dz dx
  double eps_dd = ev(0) * d[0] * d[0] + ev(1) * d[1] * d[1] + ev(2) * d[2] * d[2] +
                  ev(3) * d[0] * d[1] + ev(4) * d[1] * d[2] + ev(5) * d[2] * d[0];
  return 1.0 / eps_dd;
}

double von_mises(const std::array<double, 6>& s) {
  // Voigt [xx,yy,zz,xy,yz,zx] TRUE stress
  double a = s[0] - s[1], b = s[1] - s[2], c = s[2] - s[0];
  return std::sqrt(0.5 * (a * a + b * b + c * c) +
                   3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
}
double normal_traction(const std::array<double, 6>& s, const double n[3]) {
  // n.sigma.n with Voigt [xx,yy,zz,xy,yz,zx] TRUE stress.
  return s[0] * n[0] * n[0] + s[1] * n[1] * n[1] + s[2] * n[2] * n[2] +
         2 * s[3] * n[0] * n[1] + 2 * s[4] * n[1] * n[2] + 2 * s[5] * n[2] * n[0];
}

// Recover the per-solid-voxel microscopic stress field under a unit macro strain e0
// (engineering Voigt). Returns one Voigt stress per solid voxel plus the macro
// stress Sigma = CH*e0. The stress field is the strut-level (de-homogenised) stress
// the current lattice cert never computes — its margin uses the SMEARED macro stress.
struct StressField {
  std::vector<std::array<double, 6>> sig;  // per solid voxel (grid scan order)
  std::array<double, 6> macro{};           // Sigma = CH e0
};
StressField recover_stress(const VoxelGrid& grid, const double D[6][6],
                           const HomogResult& R, const double e0v[6]) {
  StressField SF;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  auto pid = [&](int a, int b, int c) -> long {
    return ((long)(c % nz) * ny + (b % ny)) * nx + (a % nx);
  };
  auto chi0 = element_chi0(h);
  for (int I = 0; I < 6; ++I) {
    double s = 0;
    for (int J = 0; J < 6; ++J) s += R.CH[I][J] * e0v[J];
    SF.macro[I] = s;
  }
  double Bc[6][24];
  hex8_B(0, 0, 0, h, Bc);  // centroid B (mean element stress)
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        double u[24];
        for (int r = 0; r < 24; ++r) {
          double s = 0;
          for (int J = 0; J < 6; ++J) s += e0v[J] * (chi0[r][J] - R.X(gd[r], J));
          u[r] = s;
        }
        double eps[6];
        for (int r = 0; r < 6; ++r) {
          double s = 0;
          for (int c = 0; c < 24; ++c) s += Bc[r][c] * u[c];
          eps[r] = s;
        }
        std::array<double, 6> sig{};
        for (int r = 0; r < 6; ++r) {
          double s = 0;
          for (int c = 0; c < 6; ++c) s += D[r][c] * eps[c];
          sig[r] = s;
        }
        SF.sig.push_back(sig);
      }
  return SF;
}

void print_tensor(const char* tag, const double CH[6][6]) {
  std::printf("  %s C11=%.2f C22=%.2f C33=%.2f | C12=%.2f C13=%.2f C23=%.2f | "
              "C44=%.2f C55=%.2f C66=%.2f\n",
              tag, CH[0][0], CH[1][1], CH[2][2], CH[0][1], CH[0][2], CH[1][2],
              CH[3][3], CH[4][4], CH[5][5]);
}

}  // namespace

int main() {
  const char* csv_dir = std::getenv("TOPOPT_ANISO_CSV_DIR");
  const double L = 5.0;
  const int vpc = 32;

  // --- H0: self-check. General ke_from_D(isotropic) == hex8_stiffness, and a solid
  // cell recovers the analytic isotropic tensor. ---
  {
    double Diso[6][6];
    transverse_D(kE, kNu, 1.0, Diso);  // k=1 -> isotropic
    auto keg = ke_from_D(Diso, L / vpc);
    Hex8Stiffness kref = hex8_stiffness(kE, kNu, L / vpc);
    double maxerr = 0;
    for (int i = 0; i < 576; ++i) maxerr = std::max(maxerr, std::fabs(keg[i] - kref.k[i]));
    std::printf("H0 element self-check: max|ke_general - hex8_stiffness| = %.3e\n", maxerr);
  }

  // Build directions (in the fixed octet cell frame) to compare for STIFFNESS.
  struct Dir { const char* name; double n[3]; };
  std::vector<Dir> dirs = {
      {"[001]", {0, 0, 1}},
      {"[011]", {0, 1, 1}},
      {"[111]", {1, 1, 1}},
  };
  std::vector<double> ks = {1.0, 0.85, 0.70, 0.55};
  std::vector<double> vfs = {0.20, 0.30};

  FILE* stiff_csv = nullptr, *strength_csv = nullptr;
  if (csv_dir) {
    std::string p = std::string(csv_dir) + "/stiffness_sweep.csv";
    stiff_csv = std::fopen(p.c_str(), "w");
    std::fprintf(stiff_csv, "vf,rho_measured,build_dir,k_knockdown,E_build_iso,"
                            "E_build_transverse,E_ratio,C33_over_C11_transverse\n");
    std::string q = std::string(csv_dir) + "/interlayer_orientation.csv";
    strength_csv = std::fopen(q.c_str(), "w");
    std::fprintf(strength_csv, "vf,rho_measured,load_dir,build_dir,angle_load_build_deg,"
                               "interlayer_conc_over_macro,vm_conc_over_macro,"
                               "interlayer_vs_peak_vm\n");
  }

  for (double vf : vfs) {
    double r = calibrate_r(L, vf, vpc);
    VoxelGrid grid = build_octet(L, r, vpc);
    double rho = vol_frac(grid);
    std::printf("\n======== octet vf_target=%.2f  rho_measured=%.4f  vpc=%d  solid=%zu ========\n",
                vf, rho, vpc, grid.solid_count());

    // Isotropic control tensor.
    double Diso[6][6];
    transverse_D(kE, kNu, 1.0, Diso);
    HomogResult Riso = homogenize(grid, ke_from_D(Diso, grid.spacing));
    print_tensor("ISO base tensor:", Riso.CH);
    double zener = 2 * Riso.CH[3][3] / (Riso.CH[0][0] - Riso.CH[0][1]);
    std::printf("  Zener=%.3f  E100/Es=%.5f  E110/Es=%.5f  E111/Es=%.5f  (conv=%d)\n",
                zener, youngs_along(Riso.CH, dirs[0].n) / kE,
                youngs_along(Riso.CH, dirs[1].n) / kE,
                youngs_along(Riso.CH, dirs[2].n) / kE, (int)Riso.converged);


    // ---- EXPERIMENT 1: STIFFNESS. Re-homogenize with a transverse base whose layer
    // normal points along each build dir; report how much E_build drops vs isotropic
    // and how far the tensor departs from cubic (C33 != C11). ----
    std::printf("  -- stiffness (transverse base, layer normal = build dir) --\n");
    for (const auto& dr : dirs) {
      double nn = std::sqrt(dr.n[0]*dr.n[0] + dr.n[1]*dr.n[1] + dr.n[2]*dr.n[2]);
      double n[3] = {dr.n[0]/nn, dr.n[1]/nn, dr.n[2]/nn};
      double E_iso = youngs_along(Riso.CH, n);
      for (double k : ks) {
        double R3[3][3];
        frame_from_normal(n, R3);
        double Dmat[6][6], Dcell[6][6];
        transverse_D(kE, kNu, k, Dmat);
        rotate_D(Dmat, R3, Dcell);
        HomogResult Rt = homogenize(grid, ke_from_D(Dcell, grid.spacing));
        double E_build = youngs_along(Rt.CH, n);
        double c33_c11 = Rt.CH[2][2] / Rt.CH[0][0];
        std::printf("     build %-6s k=%.2f  E_build: %.1f (iso) -> %.1f (%.3f x)  "
                    "C33/C11=%.3f\n", dr.name, k, E_iso, E_build, E_build/E_iso, c33_c11);
        if (stiff_csv)
          std::fprintf(stiff_csv, "%.2f,%.4f,%s,%.2f,%.3f,%.3f,%.4f,%.4f\n",
                       vf, rho, dr.name, k, E_iso, E_build, E_build/E_iso, c33_c11);
      }
    }

    // ---- EXPERIMENT 2: INTERLAYER STRENGTH vs BUILD ORIENTATION. Fix the macro load
    // (uniaxial strain along [100]), recover the strut-level stress field ONCE
    // (isotropic base -- the concentration pattern is geometry-driven), then sweep the
    // BUILD direction n and read the worst solid-voxel interlayer traction max(n.s.n).
    // max von Mises is build-independent. Isolates the orientation effect the way
    // orient.cpp does for solids, but at the strut level. ----
    double e0[6] = {1, 0, 0, 0, 0, 0};  // uniaxial strain along [100]
    StressField SF = recover_stress(grid, Diso, Riso, e0);
    double macro_vm = von_mises(SF.macro);
    double load[3] = {1, 0, 0};
    double max_vm = 0;
    for (const auto& s : SF.sig) max_vm = std::max(max_vm, von_mises(s));
    std::printf("  -- interlayer strength: fixed load [100] (macro_vm=%.3f, strut "
                "max_vm=%.2f, vm_conc=%.1fx) --\n", macro_vm, max_vm, max_vm/macro_vm);
    struct BD { std::string name; double n[3]; };
    std::vector<BD> builds;
    for (int deg = 0; deg <= 90; deg += 15) {
      double a = deg * M_PI / 180.0;
      builds.push_back({"xz@" + std::to_string(deg), {std::cos(a), 0, std::sin(a)}});
    }
    builds.push_back({"[110]", {1/std::sqrt(2.0), 1/std::sqrt(2.0), 0}});
    builds.push_back({"[111]", {1/std::sqrt(3.0), 1/std::sqrt(3.0), 1/std::sqrt(3.0)}});
    double best = 1e30, worst = -1e30;
    std::string best_n, worst_n;
    for (const auto& b : builds) {
      double n[3] = {b.n[0], b.n[1], b.n[2]};
      double max_layer = 0;
      for (const auto& s : SF.sig) max_layer = std::max(max_layer, normal_traction(s, n));
      double il_over_macro = max_layer / macro_vm;
      double il_over_vm = max_layer / max_vm;
      double dot = std::fabs(n[0]*load[0] + n[1]*load[1] + n[2]*load[2]);
      double ang = std::acos(std::min(1.0, dot)) * 180.0 / M_PI;
      std::printf("     build %-8s ang(load)=%4.0f  max(n.s.n)/peak_vm=%.3f  "
                  "conc(n.s.n/macro)=%.1fx\n", b.name.c_str(), ang, il_over_vm, il_over_macro);
      if (il_over_vm < best)  { best = il_over_vm;  best_n = b.name; }
      if (il_over_vm > worst) { worst = il_over_vm; worst_n = b.name; }
      if (strength_csv)
        std::fprintf(strength_csv, "%.2f,%.4f,[100],%s,%.1f,%.4f,%.4f,%.4f\n",
                     vf, rho, b.name.c_str(), ang, il_over_macro, max_vm/macro_vm, il_over_vm);
    }
    std::printf("  => BEST build %s (max interlayer = %.3f x peak vm), WORST %s (%.3f x). "
                "Interlayer governs vs in-plane when this ratio > z_knockdown k.\n",
                best_n.c_str(), best, worst_n.c_str(), worst);
  }
  if (stiff_csv) std::fclose(stiff_csv);
  if (strength_csv) std::fclose(strength_csv);
  std::printf("\nDONE.\n");
  return 0;
}

