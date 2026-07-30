// lattice_orientation_probe.cpp — OFFLINE orientation-dependent homogenization
// harness for the layer-anisotropy task (handoff 2026-07-29-layer-anisotropy-fea).
//
// EXTENDS PR 245's core/tests/harness/lattice_anisotropy_probe.cpp (which already
// carries the TI base, full 4th-order tensor rotation and periodic homogenizer,
// octet-only) with a BCCZ generator, a fixed-load "how should I orient it" sweep,
// and a 3-material pass. NOT production, NOT a CI test, NOT wired into anything. It
// measures — it does not change the gate. Same discipline as lattice_homog_probe.cpp
// and PR 245's probe. It answers STEP 2 (D4-D6):
//
//   D4  Re-run periodic homogenization with a TRANSVERSELY ISOTROPIC base
//       material (weak axis = the build/layer-normal direction), for octet and
//       BCCZ, across a sweep of lattice-to-build orientations. Report how the
//       effective tensor AND the interlayer margin move with orientation.
//   D5  The maintainer's case: BCCZ printed FLAT (Z-struts vertical == build)
//       vs printed ON EDGE (layer lines diagonal to the strut axes). Quantify.
//   D6  Worst/best orientation per topology; is best topology-dependent?
//
// The base material is transversely isotropic with the SAME convention as the
// production element topopt::hex8_stiffness_transverse (fea.hpp): layer plane =
// the isotropy plane, layer normal (build) axis knocked down by k = z_knockdown,
//   E_p = E, E_t = k E, nu_p = nu, nu_pt = nu, G_p = E/(2(1+nu)), G_t = k G_p.
// Orientation is a rotation of that base tensor so its weak (layer-normal) axis
// points along an arbitrary build direction in the CELL frame — because the
// lattice geometry is fixed in the part and the print bed defines the layers, so
// changing "how the part sits on the bed" = rotating the build axis vs the cell.
//
// The whole point (STEP 1 honesty): k here is materials.json's z_knockdown, an
// ASSUMPTION (ARCHITECTURE.md:118 "seeded conservative, human-tuned"). This probe
// reports how much ORIENTATION matters under that assumption; the ABSOLUTE
// numbers inherit the assumption's error bar (see the handoff's residual section).
//
// SELF-CHECKS (printed at start; all must pass or the numbers are meaningless):
//   A1  our self-contained integrator reproduces topopt::hex8_stiffness (iso) and
//       ::hex8_stiffness_transverse (k<1) entrywise to ~1e-12.
//   A2  rotating an ISOTROPIC tensor by an arbitrary R leaves it unchanged.
//   A3  rotating the TI base by 90 deg about x moves the weak axis z->y exactly.
//   A4  a fully-solid cell homogenizes back to the (rotated) base tensor to ~1e-3.
//
// Build (standalone; NOT wired into CTest), from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/lattice_orientation_probe.cpp build/libtopopt.a -o build/lattice_orientation_probe
// CSV sink: set TOPOPT_LATTICE_CSV_DIR to write machine-readable tables there.

#include <Eigen/Dense>
#include <Eigen/Sparse>
#include <Eigen/IterativeLinearSolvers>

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

// ---- Base material: PLA solid (materials.json). k swept per material below. ----
constexpr double kE = 3500.0;   // PLA in-plane modulus, MPa
constexpr double kNu = 0.33;    // PLA Poisson

// =========================================================================
// SELF-CONTAINED hex8 integrator for an ARBITRARY 6x6 D (engineering-shear
// Voigt [xx,yy,zz,gxy,gyz,gzx]). Byte-for-byte the production algorithm
// (hex_element.cpp integrate_hex8) — self-check A1 asserts it reproduces the
// production element. Production's integrate_hex8 is file-local (not exported),
// so a rotated (fully anisotropic) D can only be integrated by carrying it here.
// =========================================================================
constexpr double gXi[8] = {-1, +1, +1, -1, -1, +1, +1, -1};
constexpr double gEta[8] = {-1, -1, +1, +1, -1, -1, +1, +1};
constexpr double gZeta[8] = {-1, -1, -1, -1, +1, +1, +1, +1};

std::array<double, 576> integrate_hex8_D(const double D[6][6], double h) {
  const double gp = 1.0 / std::sqrt(3.0);
  const double pts[2] = {-gp, +gp};
  const double half = h / 2.0;
  const double detJ = half * half * half;
  const double dnat_to_dx = 2.0 / h;
  std::array<double, 576> K{};
  for (int ig = 0; ig < 2; ++ig)
    for (int jg = 0; jg < 2; ++jg)
      for (int kg = 0; kg < 2; ++kg) {
        const double xi = pts[ig], eta = pts[jg], zeta = pts[kg];
        double B[6][24] = {};
        for (int a = 0; a < 8; ++a) {
          const double xa = gXi[a], ea = gEta[a], za = gZeta[a];
          const double dNdx = dnat_to_dx * 0.125 * xa * (1 + eta * ea) * (1 + zeta * za);
          const double dNdy = dnat_to_dx * 0.125 * ea * (1 + xi * xa) * (1 + zeta * za);
          const double dNdz = dnat_to_dx * 0.125 * za * (1 + xi * xa) * (1 + eta * ea);
          const int cx = 3 * a, cy = 3 * a + 1, cz = 3 * a + 2;
          B[0][cx] = dNdx; B[1][cy] = dNdy; B[2][cz] = dNdz;
          B[3][cx] = dNdy; B[3][cy] = dNdx;
          B[4][cy] = dNdz; B[4][cz] = dNdy;
          B[5][cx] = dNdz; B[5][cz] = dNdx;
        }
        double DB[6][24];
        for (int r = 0; r < 6; ++r)
          for (int col = 0; col < 24; ++col) {
            double s = 0;
            for (int m = 0; m < 6; ++m) s += D[r][m] * B[m][col];
            DB[r][col] = s;
          }
        for (int r = 0; r < 24; ++r)
          for (int col = 0; col < 24; ++col) {
            double s = 0;
            for (int m = 0; m < 6; ++m) s += B[m][r] * DB[m][col];
            K[(std::size_t)r * 24 + col] += s * detJ;
          }
      }
  return K;
}

// Strain-displacement B at the element CENTROID (natural 0,0,0), for micro-stress
// recovery. ε_voigt = B0 · u_e (engineering shear); σ_voigt = D · ε_voigt.
void centroid_B(double h, double B0[6][24]) {
  const double dnat_to_dx = 2.0 / h;
  for (int r = 0; r < 6; ++r) for (int c = 0; c < 24; ++c) B0[r][c] = 0.0;
  for (int a = 0; a < 8; ++a) {
    const double dNdx = dnat_to_dx * 0.125 * gXi[a];
    const double dNdy = dnat_to_dx * 0.125 * gEta[a];
    const double dNdz = dnat_to_dx * 0.125 * gZeta[a];
    const int cx = 3 * a, cy = 3 * a + 1, cz = 3 * a + 2;
    B0[0][cx] = dNdx; B0[1][cy] = dNdy; B0[2][cz] = dNdz;
    B0[3][cx] = dNdy; B0[3][cy] = dNdx;
    B0[4][cy] = dNdz; B0[4][cz] = dNdy;
    B0[5][cx] = dNdz; B0[5][cz] = dNdx;
  }
}

// =========================================================================
// Constitutive tensors and rotation.
// =========================================================================
// Isotropic D (matches hex8_stiffness).
void iso_D(double E, double nu, double D[6][6]) {
  const double c = E / ((1 + nu) * (1 - 2 * nu));
  for (int r = 0; r < 6; ++r) for (int cc = 0; cc < 6; ++cc) D[r][cc] = 0;
  D[0][0] = D[1][1] = D[2][2] = c * (1 - nu);
  D[0][1] = D[0][2] = D[1][0] = D[1][2] = D[2][0] = D[2][1] = c * nu;
  const double G = E / (2 * (1 + nu));
  D[3][3] = D[4][4] = D[5][5] = G;
}
// Transversely isotropic D, weak axis = +z (matches hex8_stiffness_transverse).
void ti_D(double E, double nu, double k, double D[6][6]) {
  const double nu2 = nu * nu;
  const double detM = (1 + nu) * ((1 - nu) / k - 2 * nu2);
  const double s = E / detM;
  const double G = E / (2 * (1 + nu));
  for (int r = 0; r < 6; ++r) for (int cc = 0; cc < 6; ++cc) D[r][cc] = 0;
  D[0][0] = D[1][1] = s * (1.0 / k - nu2);
  D[2][2] = s * (1 - nu2);
  D[0][1] = D[1][0] = s * (nu / k + nu2);
  D[0][2] = D[2][0] = D[1][2] = D[2][1] = s * (nu + nu2);
  D[3][3] = G;
  D[4][4] = D[5][5] = k * G;
}

// Voigt index (engineering) <-> tensor index pair. Order [xx,yy,zz,xy,yz,zx].
constexpr int vp[6][2] = {{0, 0}, {1, 1}, {2, 2}, {0, 1}, {1, 2}, {2, 0}};

// Engineering-Voigt 6x6 stiffness D -> 4th-order tensor C_ijkl. For a STIFFNESS
// matrix in engineering-shear convention, C_ijkl == D[voigt(ij)][voigt(kl)]
// directly (the engineering factor 2 on strain and the minor-symmetry factor 2
// cancel). Fill all minor-symmetric slots.
void D_to_C(const double D[6][6], double C[3][3][3][3]) {
  for (int a = 0; a < 6; ++a)
    for (int b = 0; b < 6; ++b) {
      int i = vp[a][0], j = vp[a][1], k = vp[b][0], l = vp[b][1];
      double val = D[a][b];
      C[i][j][k][l] = C[j][i][k][l] = C[i][j][l][k] = C[j][i][l][k] = val;
    }
}
void C_to_D(const double C[3][3][3][3], double D[6][6]) {
  for (int a = 0; a < 6; ++a)
    for (int b = 0; b < 6; ++b)
      D[a][b] = C[vp[a][0]][vp[a][1]][vp[b][0]][vp[b][1]];
}
// C'_ijkl = R_ip R_jq R_kr R_ls C_pqrs. R rows are the material axes expressed in
// the target (cell) frame; equivalently the material tensor is rotated by R.
void rotate_C(const double C[3][3][3][3], const double R[3][3],
              double Cout[3][3][3][3]) {
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      for (int k = 0; k < 3; ++k)
        for (int l = 0; l < 3; ++l) {
          double s = 0;
          for (int p = 0; p < 3; ++p)
            for (int q = 0; q < 3; ++q)
              for (int r = 0; r < 3; ++r)
                for (int t = 0; t < 3; ++t)
                  s += R[i][p] * R[j][q] * R[k][r] * R[l][t] * C[p][q][r][t];
          Cout[i][j][k][l] = s;
        }
}
// Rotate an engineering-Voigt D by R (through the 4th-order tensor).
void rotate_D(const double D[6][6], const double R[3][3], double Dout[6][6]) {
  double C[3][3][3][3], C2[3][3][3][3];
  D_to_C(D, C);
  rotate_C(C, R, C2);
  C_to_D(C2, Dout);
}

// Minimal rotation taking +z (material weak axis) to unit vector n (Rodrigues).
// TI is invariant to spin about its own axis, so any such R is equivalent.
void rot_z_to(const double n[3], double R[3][3]) {
  const double z[3] = {0, 0, 1};
  double v[3] = {z[1] * n[2] - z[2] * n[1], z[2] * n[0] - z[0] * n[2],
                 z[0] * n[1] - z[1] * n[0]};  // z x n
  double c = z[0] * n[0] + z[1] * n[1] + z[2] * n[2];  // cos angle
  double slen = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  // identity
  for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) R[i][j] = (i == j);
  if (slen < 1e-14) {                       // parallel or antiparallel
    if (c < 0) { R[0][0] = 1; R[1][1] = -1; R[2][2] = -1; }  // 180 deg about x
    return;
  }
  double K[3][3] = {{0, -v[2], v[1]}, {v[2], 0, -v[0]}, {-v[1], v[0], 0}};
  double K2[3][3];
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) {
      double s = 0;
      for (int m = 0; m < 3; ++m) s += K[i][m] * K[m][j];
      K2[i][j] = s;
    }
  const double f = (1 - c) / (slen * slen);
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) R[i][j] += K[i][j] + f * K2[i][j];
}

// =========================================================================
// Lattice geometry — segment lists in unit-cell coords [0,1]^3, periodic
// distance via 27 neighbor images (robust for struts on faces/edges/corners).
// =========================================================================
using Seg = std::array<std::array<double, 3>, 2>;

std::vector<Seg> octet_segs() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z) for (int y = 0; y <= 1; ++y) for (int x = 0; x <= 1; ++x)
    nodes.push_back({(double)x, (double)y, (double)z});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0}, {0.5, 0.5, 1.0},
      {0.5, 0.0, 0.5}, {0.5, 1.0, 0.5}, {0.0, 0.5, 0.5}, {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  std::vector<Seg> segs;
  for (std::size_t fi = 8; fi < nodes.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0;
      for (int k = 0; k < 3; ++k) {
        double val = nodes[fi][k];
        if (val == 0.0 || val == 1.0) d2 += (nodes[ci][k] - val) * (nodes[ci][k] - val);
      }
      if (d2 < 1e-9) segs.push_back({nodes[fi], nodes[ci]});
    }
  return segs;
}
// BCCZ = BCC (8 corners -> body center) + Z pillars on the 4 vertical edges.
std::vector<Seg> bccz_segs() {
  std::vector<Seg> segs;
  const std::array<double, 3> c = {0.5, 0.5, 0.5};
  for (int z = 0; z <= 1; ++z) for (int y = 0; y <= 1; ++y) for (int x = 0; x <= 1; ++x)
    segs.push_back({std::array<double, 3>{(double)x, (double)y, (double)z}, c});
  const std::array<std::array<double, 2>, 4> xy = {{{0, 0}, {1, 0}, {0, 1}, {1, 1}}};
  for (auto& e : xy)
    segs.push_back({std::array<double, 3>{e[0], e[1], 0.0},
                    std::array<double, 3>{e[0], e[1], 1.0}});
  return segs;
}

double pt_seg_d2(const double p[3], const double a[3], const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {p[0] - a[0], p[1] - a[1], p[2] - a[2]};
  double den = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = den > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / den : 0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  double d[3] = {p[0] - (a[0] + t * ab[0]), p[1] - (a[1] + t * ab[1]),
                 p[2] - (a[2] + t * ab[2])};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}
// Periodic min distance^2 (cell coords in [0,1)) over 27 images. r in cell units.
double min_d2_periodic(double u, double v, double w, const std::vector<Seg>& segs) {
  double best = 1e30;
  for (int ox = -1; ox <= 1; ++ox)
    for (int oy = -1; oy <= 1; ++oy)
      for (int oz = -1; oz <= 1; ++oz)
        for (const Seg& s : segs) {
          double a[3] = {s[0][0] + ox, s[0][1] + oy, s[0][2] + oz};
          double b[3] = {s[1][0] + ox, s[1][1] + oy, s[1][2] + oz};
          double p[3] = {u, v, w};
          double d2 = pt_seg_d2(p, a, b);
          if (d2 < best) best = d2;
        }
  return best;
}

VoxelGrid build_cell(const std::vector<Seg>& segs, double L, int vpc, double r_cell) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = vpc;
  g.spacing = L / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)vpc * vpc * vpc, VoxelTag::Empty);
  const double r2 = r_cell * r_cell;
  for (int k = 0; k < vpc; ++k)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        double u = (i + 0.5) / vpc, v = (j + 0.5) / vpc, w = (k + 0.5) / vpc;
        if (min_d2_periodic(u, v, w, segs) < r2) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}
double vol_frac(const VoxelGrid& g) {
  return (double)g.solid_count() / (double)g.voxel_count();
}
double calib_r(const std::vector<Seg>& segs, double L, int vpc, double tvf) {
  double lo = 0.0005, hi = 0.35;  // cell units
  for (int it = 0; it < 26; ++it) {
    double mid = 0.5 * (lo + hi);
    VoxelGrid g = build_cell(segs, L, vpc, mid);
    (vol_frac(g) < tvf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// =========================================================================
// PERIODIC HOMOGENIZATION (adapted from lattice_homog_probe.cpp, parametrized on
// a per-cell element stiffness ke[576] so a ROTATED anisotropic base can be used;
// also returns the corrector fields X for micro-stress recovery).
// =========================================================================
constexpr int kOff[8][3] = {{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}};

std::array<std::array<double, 6>, 24> element_chi0(double h) {
  std::array<std::array<double, 6>, 24> chi0{};
  for (int a = 0; a < 8; ++a) {
    double X = kOff[a][0] * h, Y = kOff[a][1] * h, Z = kOff[a][2] * h;
    int dx = 3 * a, dy = 3 * a + 1, dz = 3 * a + 2;
    chi0[dx][0] = X; chi0[dy][1] = Y; chi0[dz][2] = Z;
    chi0[dx][3] = Y; chi0[dy][4] = Z; chi0[dz][5] = X;
  }
  return chi0;
}

using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;

struct Homog {
  double CH[6][6] = {};
  Eigen::MatrixXd X;     // nd x 6 corrector fields
  std::vector<int> gid;  // periodic dof id per (voxel-corner) — for recovery
  int cg_iters = 0;
  bool converged = true;
};

Homog homogenize(const VoxelGrid& grid, const std::array<double, 576>& ke,
                 double cg_tol = 1e-9) {
  Homog R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz, nd = 3 * Np;
  auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    return ((long)(c % nz) * ny + (b % ny)) * nx + (a % nx);
  };
  std::vector<Trip> trips;
  Eigen::MatrixXd F = Eigen::MatrixXd::Zero(nd, 6);
  std::vector<char> touched((std::size_t)nd, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3*a] = 3*p; gd[3*a+1] = 3*p+1; gd[3*a+2] = 3*p+2;
        }
        for (int r = 0; r < 24; ++r) {
          touched[gd[r]] = 1;
          for (int c = 0; c < 24; ++c) trips.emplace_back((int)gd[r], (int)gd[c], ke[r*24+c]);
          for (int J = 0; J < 6; ++J) {
            double f = 0;
            for (int c = 0; c < 24; ++c) f += ke[r*24+c] * chi0[c][J];
            F(gd[r], J) += f;
          }
        }
      }
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  for (long d = 0; d < nd; ++d) if (!touched[d]) pinned[d] = 1;
  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear(); trips.shrink_to_fit();
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()])
        it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
  K.prune(0.0);
  for (long d = 0; d < nd; ++d) if (pinned[d]) for (int J = 0; J < 6; ++J) F(d, J) = 0;
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(cg_tol);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 200000));
  cg.compute(K);
  R.X = Eigen::MatrixXd::Zero(nd, 6);
  for (int J = 0; J < 6; ++J) {
    R.X.col(J) = cg.solve(F.col(J));
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
          gd[3*a] = 3*p; gd[3*a+1] = 3*p+1; gd[3*a+2] = 3*p+2;
        }
        for (int J = 0; J < 6; ++J) {
          double diffJ[24], kd[24];
          for (int r = 0; r < 24; ++r) diffJ[r] = chi0[r][J] - R.X(gd[r], J);
          for (int r = 0; r < 24; ++r) {
            double s = 0;
            for (int c = 0; c < 24; ++c) s += ke[r*24+c] * diffJ[c];
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

// Effective Young's modulus along a unit direction d from full compliance S=CH^-1.
double E_along(const double CH[6][6], const double d[3]) {
  Eigen::Matrix<double, 6, 6> C;
  for (int r = 0; r < 6; ++r) for (int c = 0; c < 6; ++c) C(r, c) = CH[r][c];
  Eigen::Matrix<double, 6, 6> S = C.inverse();
  // Uniaxial stress sigma = d⊗d (Voigt eng: [dx^2,dy^2,dz^2,2dxdy,2dydz,2dzdx]).
  Eigen::Matrix<double, 6, 1> sig;
  sig << d[0]*d[0], d[1]*d[1], d[2]*d[2], 2*d[0]*d[1], 2*d[1]*d[2], 2*d[2]*d[0];
  Eigen::Matrix<double, 6, 1> eps = S * sig;  // engineering strain
  // axial strain along d = d·ε·d (tensor strain; halve engineering shears)
  double e = eps(0)*d[0]*d[0] + eps(1)*d[1]*d[1] + eps(2)*d[2]*d[2] +
             eps(3)*d[0]*d[1] + eps(4)*d[1]*d[2] + eps(5)*d[2]*d[0];
  return e > 0 ? 1.0 / e : 0.0;  // sigma magnitude = 1
}

// Micro-stress interlayer scan under a macro UNIAXIAL stress along `loaddir`
// (unit). Returns (max interlayer tension n·σ·n, max von Mises) over solid
// voxels, where n = build direction. Both scale linearly with the macro stress
// magnitude (taken = 1), so only their RATIO matters for the margin.
struct MicroScan { double max_interlayer = 0, max_vm = 0; };
MicroScan micro_scan(const VoxelGrid& grid, const Homog& H, const double D[6][6],
                     const double CH[6][6], const double loaddir[3],
                     const double nbuild[3]) {
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  auto pid = [&](int a, int b, int c) -> long {
    return ((long)(c % nz) * ny + (b % ny)) * nx + (a % nx);
  };
  Eigen::Matrix<double, 6, 6> C;
  for (int r = 0; r < 6; ++r) for (int c = 0; c < 6; ++c) C(r, c) = CH[r][c];
  Eigen::Matrix<double, 6, 6> S = C.inverse();
  Eigen::Matrix<double, 6, 1> Sig;
  Sig << loaddir[0]*loaddir[0], loaddir[1]*loaddir[1], loaddir[2]*loaddir[2],
         2*loaddir[0]*loaddir[1], 2*loaddir[1]*loaddir[2], 2*loaddir[2]*loaddir[0];
  Eigen::Matrix<double, 6, 1> Emac = S * Sig;  // macro engineering strain
  double B0[6][24]; centroid_B(h, B0);
  auto chi0 = element_chi0(h);
  MicroScan out;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3*a] = 3*p; gd[3*a+1] = 3*p+1; gd[3*a+2] = 3*p+2;
        }
        double u[24];
        for (int r = 0; r < 24; ++r) {
          double val = 0;
          for (int J = 0; J < 6; ++J)
            val += Emac(J) * (chi0[r][J] - H.X(gd[r], J));
          u[r] = val;
        }
        double eps[6];
        for (int r = 0; r < 6; ++r) {
          double s = 0;
          for (int c = 0; c < 24; ++c) s += B0[r][c] * u[c];
          eps[r] = s;
        }
        double sg[6];  // Voigt stress [xx,yy,zz,xy,yz,zx], true shear
        for (int r = 0; r < 6; ++r) {
          double s = 0;
          for (int c = 0; c < 6; ++c) s += D[r][c] * eps[c];
          sg[r] = s;
        }
        const double* n = nbuild;
        double interl = n[0]*n[0]*sg[0] + n[1]*n[1]*sg[1] + n[2]*n[2]*sg[2] +
                        2*n[0]*n[1]*sg[3] + 2*n[1]*n[2]*sg[4] + 2*n[2]*n[0]*sg[5];
        double vm = std::sqrt(0.5 * (
            (sg[0]-sg[1])*(sg[0]-sg[1]) + (sg[1]-sg[2])*(sg[1]-sg[2]) +
            (sg[2]-sg[0])*(sg[2]-sg[0]) +
            6.0 * (sg[3]*sg[3] + sg[4]*sg[4] + sg[5]*sg[5])));
        if (interl > out.max_interlayer) out.max_interlayer = interl;
        if (vm > out.max_vm) out.max_vm = vm;
      }
  return out;
}

// -------------------------------------------------------------- CSV helpers
FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

double maxdiff(const std::array<double,576>& a, const Hex8Stiffness& b) {
  double m = 0, ref = 0;
  for (int i = 0; i < 576; ++i) { m = std::max(m, std::fabs(a[i]-b.k[i])); ref = std::max(ref, std::fabs(b.k[i])); }
  return ref > 0 ? m / ref : m;
}

// =========================================================================
void self_checks() {
  std::printf("\n===== SELF-CHECKS (all must pass) =====\n");
  const double h = 0.5;
  // A1: our integrator == production element (iso and TI).
  double Diso[6][6]; iso_D(kE, kNu, Diso);
  double e1 = maxdiff(integrate_hex8_D(Diso, h), hex8_stiffness(kE, kNu, h));
  double Dti[6][6]; ti_D(kE, kNu, 0.55, Dti);
  double e2 = maxdiff(integrate_hex8_D(Dti, h), hex8_stiffness_transverse(kE, kNu, h, 0.55));
  std::printf("  A1 integrator vs production:  iso rel=%.2e  TI(k=.55) rel=%.2e  -> %s\n",
              e1, e2, (e1 < 1e-11 && e2 < 1e-11) ? "PASS" : "FAIL");
  // A2: rotating isotropic by an arbitrary R is a no-op.
  double n[3] = {0.3, -0.7, 0.65}; double ln = std::sqrt(n[0]*n[0]+n[1]*n[1]+n[2]*n[2]);
  n[0]/=ln; n[1]/=ln; n[2]/=ln;
  double Rn[3][3]; rot_z_to(n, Rn);
  double Diso_r[6][6]; rotate_D(Diso, Rn, Diso_r);
  double a2 = 0, ref = 0;
  for (int r=0;r<6;++r) for (int c=0;c<6;++c){ a2=std::max(a2,std::fabs(Diso_r[r][c]-Diso[r][c])); ref=std::max(ref,std::fabs(Diso[r][c])); }
  std::printf("  A2 rotate isotropic no-op:    rel=%.2e  -> %s\n", a2/ref, a2/ref<1e-12?"PASS":"FAIL");
  // A3: rotate TI weak-axis z by 90 deg about x -> weak axis y. Check D'[1][1]==Dti[2][2].
  double ny[3] = {0, 1, 0}; double Ry[3][3]; rot_z_to(ny, Ry);
  double Dti_y[6][6]; rotate_D(Dti, Ry, Dti_y);
  double a3 = std::fabs(Dti_y[1][1] - Dti[2][2]) / std::fabs(Dti[2][2]);
  std::printf("  A3 rotate TI z->y:            D'[yy]=%.3f vs base[zz]=%.3f rel=%.2e -> %s\n",
              Dti_y[1][1], Dti[2][2], a3, a3<1e-10?"PASS":"FAIL");
  // A4: fully solid cell homogenizes back to the rotated base tensor.
  VoxelGrid g; g.nx=g.ny=g.nz=6; g.spacing=1.0; g.origin=Vec3{0,0,0};
  g.tags.assign(6*6*6, VoxelTag::Interior);
  double Dti_r[6][6]; rotate_D(Dti, Rn, Dti_r);
  Homog H = homogenize(g, integrate_hex8_D(Dti_r, g.spacing), 1e-11);
  double a4 = 0, r4 = 0;
  for (int r=0;r<6;++r) for (int c=0;c<6;++c){ a4=std::max(a4,std::fabs(H.CH[r][c]-Dti_r[r][c])); r4=std::max(r4,std::fabs(Dti_r[r][c])); }
  std::printf("  A4 solid cell recovers base:  rel=%.2e (cg=%d) -> %s\n",
              a4/r4, H.cg_iters, a4/r4<2e-3?"PASS":"FAIL");
}

struct MatSpec { const char* name; double k; };
struct TopoSpec { const char* name; std::vector<Seg> segs; };

// Orientation sweep — DECISION framing. The lattice geometry and the external
// load are FIXED in the PART frame; reorienting the part on the print bed changes
// the BUILD (layer-normal) direction relative to the part. So: sweep the build
// direction nb in the x-z plane from part-z (0deg == printed "flat", layers in
// the x-y plane) to part-x (90deg), and hold the load fixed along part-x (the
// "sideways" load the maintainer worries about). For each build orientation we
// rotate the TI base so its weak axis = nb, homogenize, and report:
//   E_x  effective Young's modulus along the LOAD (part-x), fixed direction
//   E_z  effective modulus along part-z (BCCZ's pillar axis; geometry-stiff)
//   r    max interlayer tension / max von Mises under the fixed part-x load
//   k/r  interlayer margin RELATIVE to the in-plane margin (<1 => interlayer
//        governs; delamination reached before yield)
// build=0 (flat) has load perpendicular to build (good for interlayer) but, for
// BCCZ, part-x is the geometry-SOFT axis. build=90 aligns build WITH the load
// (worst for interlayer). The two effects pull opposite ways — that is the point.
void run_sweep(const MatSpec& mat, const TopoSpec& topo, double L, int vpc,
               double tvf, FILE* csv) {
  double Dbase[6][6]; ti_D(kE, kNu, mat.k, Dbase);
  double r_cell = calib_r(topo.segs, L, vpc, tvf);
  VoxelGrid cell = build_cell(topo.segs, L, vpc, r_cell);
  double rho = vol_frac(cell);
  const double load[3] = {1, 0, 0};  // fixed sideways load, part-x
  const double xaxis[3] = {1, 0, 0}, zaxis[3] = {0, 0, 1};
  std::printf("\n  --- %s / %s  (L=%.1f vpc=%d rho=%.3f k=%.2f) load=part-x ---\n",
              mat.name, topo.name, L, vpc, rho, mat.k);
  std::printf("  %-8s %-9s %-9s %-11s %-11s %-9s\n",
              "build", "E_x(load)", "E_z", "r=int/vm", "margin k/r", "gov?");
  const double angles[] = {0, 15, 30, 45, 60, 75, 90};
  double best_margin = -1, worst_margin = 1e30, best_ang = 0, worst_ang = 0;
  for (double deg : angles) {
    double a = deg * M_PI / 180.0;
    double nb[3] = {std::sin(a), 0, std::cos(a)};  // build dir, part x-z plane
    double R[3][3]; rot_z_to(nb, R);
    double Dr[6][6]; rotate_D(Dbase, R, Dr);
    Homog H = homogenize(cell, integrate_hex8_D(Dr, cell.spacing), 1e-9);
    double Ex = E_along(H.CH, xaxis), Ez = E_along(H.CH, zaxis);
    MicroScan ms = micro_scan(cell, H, Dr, H.CH, load, nb);
    double r = ms.max_vm > 0 ? ms.max_interlayer / ms.max_vm : 0;
    double margin = r > 0 ? mat.k / r : 1e9;
    bool gov = margin < 1.0;
    if (margin > best_margin) { best_margin = margin; best_ang = deg; }
    if (margin < worst_margin) { worst_margin = margin; worst_ang = deg; }
    std::printf("  %-8.0f %-9.1f %-9.1f %-11.3f %-11.3f %-9s\n",
                deg, Ex, Ez, r, margin, gov ? "INTERLYR" : "in-plane");
    if (csv)
      std::fprintf(csv, "%s,%s,%.3f,%.0f,%.4f,%.4f,%.4f,%.4f,%.4f,%d\n",
                   mat.name, topo.name, rho, deg, Ex, Ez, r, margin, mat.k, H.cg_iters);
  }
  std::printf("  -> interlayer margin k/r: best %.2f @%.0fdeg   worst %.2f @%.0fdeg\n",
              best_margin, best_ang, worst_margin, worst_ang);
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::printf("LATTICE LAYER-ANISOTROPY PROBE — TI base, orientation sweep\n");
  std::printf("base: PLA-like E=%.0f nu=%.2f; k = materials.json z_knockdown (ASSUMPTION)\n", kE, kNu);
  fea_set_matfree_threads(6);

  self_checks();

  const int vpc = std::getenv("TOPOPT_ANISO_VPC") ? std::atoi(std::getenv("TOPOPT_ANISO_VPC")) : 28;
  const double L = 5.0, tvf = 0.30;
  std::printf("\n===== ORIENTATION SWEEP (L=%.1f mm, vpc=%d, target rho=%.2f) =====\n", L, vpc, tvf);
  std::printf("  DECISION framing: lattice geometry + load FIXED in the part; build (layer-normal)\n");
  std::printf("  direction swept from part-z (0deg = printed flat) to part-x (90deg). Load = part-x.\n");
  std::printf("  E_x(load) = eff. modulus along the load; E_z = along part-z (BCCZ pillar axis).\n");
  std::printf("  r = max interlayer tension / max von Mises; margin k/r: interlayer vs in-plane\n");
  std::printf("  (<1 => interlayer governs, delamination before yield). k = z_knockdown (ASSUMED).\n");

  FILE* csv = csv_open("anisotropy_sweep.csv");
  if (csv) std::fprintf(csv, "material,topology,rho,build_deg,E_build,E_side,r_int_vm,margin_k_over_r,k,cg_iters\n");

  std::vector<MatSpec> mats = {{"PLA", 0.55}, {"PETG", 0.70}, {"ASA", 0.60}};
  TopoSpec octet{"octet", octet_segs()};
  TopoSpec bccz{"bccz", bccz_segs()};

  for (const auto& m : mats) {
    run_sweep(m, octet, L, vpc, tvf, csv);
    run_sweep(m, bccz, L, vpc, tvf, csv);
  }
  if (csv) std::fclose(csv);
  std::printf("\nDONE.\n");
  return 0;
}
