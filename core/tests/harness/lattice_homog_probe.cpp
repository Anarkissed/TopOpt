// lattice_homog_probe.cpp — OFFLINE homogenization LIBRARY + measurement harness
// for lattice Phase 0 (handoff 2026-07-26-lattice-homog-phase0).
//
// NOT production, NOT a CI test, NOT wired into anything. This is the offline
// library the lattice NO-GO (2026-07-26-lattice-phase0) named as the ONLY honest
// structural route: numerical homogenization. It computes, for a lattice unit
// cell at a given relative density, the EFFECTIVE ELASTICITY TENSOR under
// PERIODIC boundary conditions, sweeps it across a density grid, and writes a
// tensor library. Phase 1 (a separate task) would wire these tensors into the
// macro solver as an element constitutive law; this file only produces and
// validates the numbers.
//
// METHOD — strain(energy) homogenization with periodic BCs (the standard
// Andreassen/Bendsoe formulation, 3D). The unit cell is meshed with the SAME
// 8-node hex element the production solver uses (topopt::hex8_stiffness), so a
// fully-solid cell recovers the analytic material tensor to machine precision
// (H1 self-check). For each of the six unit macroscopic strains e0_I (Voigt
// [xx,yy,zz,gxy,gyz,gzx], engineering shear) we solve for the Y-periodic
// corrector field chi_I:
//        K chi_I = F_I ,   F_I = sum_e ke * chi0_I,e   (periodic assembly)
// where chi0_I,e is the element nodal displacement that produces the uniform
// strain e0_I, and K is assembled with OPPOSITE-FACE NODES IDENTIFIED (torus).
// Three DOFs of one node are pinned to remove the rigid-body translations
// (periodic BCs admit no rotation nullspace). Then
//        C^H_IJ = (1/|Y|) sum_e (chi0_I - chi_I)_e^T ke (chi0_J - chi_J)_e ,
// with |Y| the FULL bounding volume of the cell (solid + void), so C^H is the
// cellular solid's effective stiffness relative to its envelope. Void voxels
// contribute no element (two-phase solid/empty lattice); DOFs touched by no
// solid element are pinned (the production void-DOF gate).
//
// The periodic linear system is assembled and solved with Eigen directly (the
// core solvers do not offer periodic BCs); this is self-contained harness code.
//
// Build (standalone; NOT wired into CTest), from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/lattice_homog_probe.cpp build/libtopopt.a -o build/lattice_homog_probe
// CSV sink: set TOPOPT_LATTICE_CSV_DIR to write machine-readable tables there.

#include <Eigen/Sparse>
#include <Eigen/SparseCholesky>
#include <Eigen/IterativeLinearSolvers>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;   // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;    // PLA Poisson
constexpr double kStrain = 1e-3;  // applied nominal axial strain (direct test)

// =========================================================================
// Lattice geometry (copied verbatim from lattice_probe.cpp — harness files are
// self-contained; the Phase-0 probe validated these generators).
// =========================================================================
enum class Lattice { Gyroid, SchwarzD, Octet };
const char* name_of(Lattice l) {
  switch (l) {
    case Lattice::Gyroid: return "gyroid";
    case Lattice::SchwarzD: return "schwarzD";
    case Lattice::Octet: return "octet";
  }
  return "?";
}

double gyroid_val(double x, double y, double z, double L) {
  const double a = 2.0 * M_PI / L;
  return std::sin(a * x) * std::cos(a * y) + std::sin(a * y) * std::cos(a * z) +
         std::sin(a * z) * std::cos(a * x);
}
double schwarzD_val(double x, double y, double z, double L) {
  const double a = 2.0 * M_PI / L;
  return std::sin(a * x) * std::sin(a * y) * std::sin(a * z) +
         std::sin(a * x) * std::cos(a * y) * std::cos(a * z) +
         std::cos(a * x) * std::sin(a * y) * std::cos(a * z) +
         std::cos(a * x) * std::cos(a * y) * std::sin(a * z);
}
double point_seg_dist2(double px, double py, double pz, const double a[3],
                       const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double denom = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = denom > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / denom
                       : 0.0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  double c[3] = {a[0] + t * ab[0], a[1] + t * ab[1], a[2] + t * ab[2]};
  double d[3] = {px - c[0], py - c[1], pz - c[2]};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}
std::vector<std::array<std::array<double, 3>, 2>> octet_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0},
                                                    {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5},
                                                    {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5},
                                                    {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  auto add = [&](const std::array<double, 3>& p, const std::array<double, 3>& q) {
    segs.push_back({p, q});
  };
  for (std::size_t fi = 8; fi < nodes.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0;
      for (int k = 0; k < 3; ++k) {
        double v = nodes[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (nodes[ci][k] - v) * (nodes[ci][k] - v);
      }
      if (d2 < 1e-9) add(nodes[fi], nodes[ci]);
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

struct GenParams {
  Lattice kind;
  double L;
  double level;
  double octet_r;
};

bool is_solid(const GenParams& g, double x, double y, double z,
              const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  switch (g.kind) {
    case Lattice::Gyroid:
      return std::fabs(gyroid_val(x, y, z, g.L)) < g.level;
    case Lattice::SchwarzD:
      return std::fabs(schwarzD_val(x, y, z, g.L)) < g.level;
    case Lattice::Octet:
      return octet_dist2(x, y, z, g.L, segs) < g.octet_r * g.octet_r;
  }
  return false;
}

VoxelGrid build_lattice(const GenParams& g, int ncx, int ncy, int ncz, int vpc) {
  VoxelGrid grid;
  grid.nx = ncx * vpc;
  grid.ny = ncy * vpc;
  grid.nz = ncz * vpc;
  grid.spacing = g.L / vpc;
  grid.origin = Vec3{0, 0, 0};
  grid.tags.assign(static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz,
                   VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        Vec3 c = grid.voxel_center(i, j, k);
        if (is_solid(g, c.x, c.y, c.z, segs)) grid.set_tag(i, j, k, VoxelTag::Interior);
      }
  return grid;
}

double volume_fraction(const VoxelGrid& g) {
  return static_cast<double>(g.solid_count()) /
         static_cast<double>(g.voxel_count());
}

// Median solid-run length along x over all (j,k) scan-lines (voxels per wall).
double median_wall_voxels(const VoxelGrid& g) {
  std::vector<int> runs;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j) {
      int run = 0;
      for (int i = 0; i < g.nx; ++i) {
        if (g.solid(i, j, k)) ++run;
        else if (run > 0) { runs.push_back(run); run = 0; }
      }
      if (run > 0 && run < g.nx) runs.push_back(run);
    }
  if (runs.empty()) return 0;
  std::sort(runs.begin(), runs.end());
  return runs[runs.size() / 2];
}

double calibrate_level(Lattice kind, double L, double target_vf, int vpc) {
  GenParams g{kind, L, 0.0, 0.0};
  double lo = 0.001, hi = 1.6;
  for (int it = 0; it < 28; ++it) {
    double mid = 0.5 * (lo + hi);
    g.level = mid;
    VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
    (volume_fraction(grid) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}
double calibrate_octet_r(double L, double target_vf, int vpc) {
  GenParams g{Lattice::Octet, L, 0.0, 0.0};
  double lo = 0.0005 * L, hi = 0.30 * L;
  for (int it = 0; it < 28; ++it) {
    double mid = 0.5 * (lo + hi);
    g.octet_r = mid;
    VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
    (volume_fraction(grid) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}
GenParams calibrated(Lattice kind, double L, double target_vf, int vpc) {
  GenParams g{kind, L, 0.0, 0.0};
  if (kind == Lattice::Octet) g.octet_r = calibrate_octet_r(L, target_vf, vpc);
  else g.level = calibrate_level(kind, L, target_vf, vpc);
  return g;
}

// =========================================================================
// PERIODIC HOMOGENIZATION
// =========================================================================

// The reference element stiffness ke (24x24, row-major) from the PRODUCTION
// element, for a cubic voxel of edge h. Identical to what the macro solver
// assembles, so the solid self-check recovers the exact material tensor.
std::array<double, 576> ref_ke(double h) {
  Hex8Stiffness K = hex8_stiffness(kE, kNu, h);
  std::array<double, 576> out{};
  for (int i = 0; i < 576; ++i) out[i] = K.k[i];
  return out;
}

// Element node local offsets in hex8 order (bottom CCW, then top CCW).
constexpr int kOff[8][3] = {{0,0,0},{1,0,0},{1,1,0},{0,1,0},
                            {0,0,1},{1,0,1},{1,1,1},{0,1,1}};

// chi0[dof][J]: element nodal displacement producing unit macro strain e0_J
// (Voigt [xx,yy,zz,gxy,gyz,gzx], engineering shear). Pure geometry (edge h).
// Node a at local (X,Y,Z) in {0,h}^3, dof = 3a+comp.
std::array<std::array<double, 6>, 24> element_chi0(double h) {
  std::array<std::array<double, 6>, 24> chi0{};
  for (int a = 0; a < 8; ++a) {
    double X = kOff[a][0] * h, Y = kOff[a][1] * h, Z = kOff[a][2] * h;
    int dx = 3 * a, dy = 3 * a + 1, dz = 3 * a + 2;
    // e0_0 = eps_xx : u = (X,0,0)
    chi0[dx][0] = X;
    // e0_1 = eps_yy : u = (0,Y,0)
    chi0[dy][1] = Y;
    // e0_2 = eps_zz : u = (0,0,Z)
    chi0[dz][2] = Z;
    // e0_3 = gamma_xy : u = (Y,0,0)  -> du_x/dy = 1
    chi0[dx][3] = Y;
    // e0_4 = gamma_yz : u = (0,Z,0)  -> du_y/dz = 1
    chi0[dy][4] = Z;
    // e0_5 = gamma_zx : u = (0,0,X)  -> du_z/dx = 1
    chi0[dz][5] = X;
  }
  return chi0;
}

using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;

// Full 6x6 homogenized tensor of `grid` (mm units); `cases` selects which of
// the six strain columns to solve (a cubic material needs only {0,3}: column 0
// gives C11=CH(0,0) and C12=CH(1,0)/CH(2,0); column 3 gives C44=CH(3,3)). Only
// the solved columns of CH are meaningful; unsolved rows/cols are left zero.
struct HomogResult {
  double CH[6][6] = {};
  int cg_iters_max = 0;
  bool converged = true;
  double solve_ms = 0;
};

HomogResult homogenize(const VoxelGrid& grid, const std::vector<int>& cases,
                       double cg_tol = 1e-9) {
  HomogResult R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz;         // periodic (torus) node count
  const long nd = 3 * Np;                     // periodic DOF count
  auto ke = ref_ke(h);
  auto chi0 = element_chi0(h);

  // Periodic node id of corner (a,b,c), a in [0,nx] wraps to [0,nx).
  auto pid = [&](int a, int b, int c) -> long {
    int aa = a % nx, bb = b % ny, cc = c % nz;
    return ((long)cc * ny + bb) * nx + aa;
  };

  // Assemble periodic K and the 6 RHS columns F(:,J) = sum_e ke*chi0_J.
  std::vector<Trip> trips;
  trips.reserve((std::size_t)grid.solid_count() * 24 * 24);
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
          for (int J : cases) {
            double f = 0;
            for (int c = 0; c < 24; ++c) f += ke[r * 24 + c] * chi0[c][J];
            F(gd[r], J) += f;
          }
        }
      }

  // Pin rigid-body translation (node 0's 3 DOFs) and every untouched (void) DOF.
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  for (long d = 0; d < nd; ++d) if (!touched[d]) pinned[d] = 1;

  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear();
  trips.shrink_to_fit();
  // Enforce pins by zeroing rows/cols and putting 1 on the diagonal (symmetric).
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it) {
      if (pinned[it.row()] || pinned[it.col()])
        it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
    }
  K.prune(0.0);
  for (long d = 0; d < nd; ++d) if (pinned[d]) for (int J : cases) F(d, J) = 0.0;

  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(cg_tol);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 200000));
  cg.compute(K);
  auto t0 = std::chrono::steady_clock::now();
  Eigen::MatrixXd X = Eigen::MatrixXd::Zero(nd, 6);
  for (int J : cases) {
    Eigen::VectorXd x = cg.solve(F.col(J));
    X.col(J) = x;
    R.cg_iters_max = std::max(R.cg_iters_max, (int)cg.iterations());
    if (cg.info() != Eigen::Success) R.converged = false;
  }
  auto t1 = std::chrono::steady_clock::now();
  R.solve_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

  // CH_IJ = (1/|Y|) sum_e (chi0_I - chi_I)^T ke (chi0_J - chi_J).
  const double vol = (double)nx * ny * nz * h * h * h;  // full bounding volume
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        long gd[24];
        for (int a = 0; a < 8; ++a) {
          long p = pid(i + kOff[a][0], j + kOff[a][1], k + kOff[a][2]);
          gd[3 * a] = 3 * p; gd[3 * a + 1] = 3 * p + 1; gd[3 * a + 2] = 3 * p + 2;
        }
        // For each SOLVED case J, recover the FULL column I=0..5 of CH by the
        // average-stress form  CH[I][J] = (1/V) sum_e chi0_I^T ke (chi0_J - X_J).
        // This uses chi0_I (the geometric unit-strain mode, always available) on
        // the left rather than the corrected (chi0_I - X_I): by Galerkin
        // orthogonality sum_e X_I^T ke (chi0_J - X_J) = 0, so the element sum
        // equals the symmetric energy form for solved I, AND it yields the
        // transverse rows (C12 = CH[1][0], C[2][0]) from a single axial solve —
        // which a cases={0,3} run could not get from the energy form alone.
        for (int J : cases) {
          double diffJ[24];
          for (int r = 0; r < 24; ++r) diffJ[r] = chi0[r][J] - X(gd[r], J);
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

// Cubic constants extracted from CH (averaging the symmetry-equivalent entries
// when all six cases were solved; when only {0,3} were solved they come from
// CH(0,0), CH(1,0)==CH(2,0), CH(3,3) directly).
struct Cubic {
  double C11 = 0, C12 = 0, C44 = 0;
  double zener = 0;      // 2*C44/(C11-C12)
  double E100 = 0, E111 = 0;  // Young's modulus along <100> and <111>
  double offcubic = 0;   // max residual breaking cubic symmetry (full-6 only)
};
Cubic cubic_of(const HomogResult& R, bool full6) {
  Cubic c;
  if (full6) {
    c.C11 = (R.CH[0][0] + R.CH[1][1] + R.CH[2][2]) / 3.0;
    c.C12 = (R.CH[0][1] + R.CH[0][2] + R.CH[1][2] +
             R.CH[1][0] + R.CH[2][0] + R.CH[2][1]) / 6.0;
    c.C44 = (R.CH[3][3] + R.CH[4][4] + R.CH[5][5]) / 3.0;
    // Off-cubic residual: axial-shear coupling + shear cross-terms should be ~0.
    double m = 0;
    for (int I = 0; I < 3; ++I)
      for (int J = 3; J < 6; ++J) m = std::max(m, std::fabs(R.CH[I][J]));
    for (int I = 3; I < 6; ++I)
      for (int J = 3; J < 6; ++J)
        if (I != J) m = std::max(m, std::fabs(R.CH[I][J]));
    c.offcubic = m;
  } else {
    c.C11 = R.CH[0][0];
    c.C12 = 0.5 * (R.CH[1][0] + R.CH[2][0]);
    c.C44 = R.CH[3][3];
  }
  double d = c.C11 - c.C12;
  c.zener = d != 0 ? 2.0 * c.C44 / d : 0.0;
  // Young's modulus of a cubic material along <100>.
  double den = c.C11 + c.C12;
  c.E100 = den != 0 ? d * (c.C11 + 2 * c.C12) / den : 0.0;
  // Compliance for <111>: 1/E111 = S11 - 2*(S11 - S12 - S44/2)/3.
  double det = d * (c.C11 + 2 * c.C12);
  if (det != 0 && c.C44 != 0) {
    double S11 = (c.C11 + c.C12) / det;
    double S12 = -c.C12 / det;
    double S44 = 1.0 / c.C44;
    double inv111 = S11 - 2.0 * (S11 - S12 - 0.5 * S44) / 3.0;
    c.E111 = inv111 != 0 ? 1.0 / inv111 : 0.0;
  }
  return c;
}

// =========================================================================
// DIRECT RESOLVED uniaxial test (the ground truth for the GO/NO-GO bar H4).
// Copied from lattice_probe.cpp: displacement-controlled, free lateral faces,
// reaction on the max face via the assembled operator. Uses the PRODUCTION
// (non-periodic) solver — a finite resolved block, not a homogenized cell.
// =========================================================================
double direct_apparent_E(const VoxelGrid& g, int axis) {
  const int N[3] = {g.nx, g.ny, g.nz};
  const double h = g.spacing;
  const int t1 = (axis + 1) % 3, t2 = (axis + 2) % 3;
  // solid corner-node set
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) {
          auto ns = fea_element_nodes(g, i, j, k);
          for (int n : ns) issolid[n] = 1;
        }
  const double delta = kStrain * (N[axis] * h);
  std::vector<DirichletBC> bcs;
  std::vector<std::array<int, 3>> maxface;
  int pinA = -1, pinB = -1;
  double pinB_t1 = -1;
  long minA = 1L << 60;
  const int nt1 = N[t1], nt2 = N[t2];
  auto make_coord = [&](int fi, int c1, int c2) {
    std::array<int, 3> co{};
    co[axis] = fi; co[t1] = c1; co[t2] = c2; return co;
  };
  for (int c2 = 0; c2 <= nt2; ++c2)
    for (int c1 = 0; c1 <= nt1; ++c1) {
      auto lo = make_coord(0, c1, c2);
      int nlo = fea_node_index(g, lo[0], lo[1], lo[2]);
      if (issolid[nlo]) {
        bcs.push_back({nlo, axis, 0.0});
        long key = (long)c1 + (long)c2 * (nt1 + 1);
        if (key < minA) { minA = key; pinA = nlo; }
        if (c1 > pinB_t1) { pinB_t1 = c1; pinB = nlo; }
      }
      auto hi = make_coord(N[axis], c1, c2);
      int nhi = fea_node_index(g, hi[0], hi[1], hi[2]);
      if (issolid[nhi]) { bcs.push_back({nhi, axis, delta}); maxface.push_back({nhi, c1, c2}); }
    }
  if (pinA >= 0) { bcs.push_back({pinA, t1, 0.0}); bcs.push_back({pinA, t2, 0.0}); }
  if (pinB >= 0 && pinB != pinA) bcs.push_back({pinB, t2, 0.0});
  CgInfo info;
  FeaSolution sol;
  try {
    // Jacobi-CG (multigrid stagnates and falls back on thin-wall lattices, at a
    // net loss). 1e-5 relative residual is ample for a modulus readout; an
    // explicit cap keeps an ill-conditioned free-surface block (under-resolved
    // octet struts form a near-mechanism) from running to the default 2*DOF cap.
    sol = fea_solve_cg(g, kE, kNu, bcs, {}, 1e-5, 30000, &info);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [direct axis %d unconverged: %s]\n", axis, e.what());
    return -1.0;  // sentinel: did not converge
  }
  std::vector<double> Ku = fea_assembled_apply(g, kE, kNu, sol.u);
  double Fsum = 0;
  for (auto& m : maxface) Fsum += Ku[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  return std::fabs(Fsum) / (A * kStrain);
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

const std::vector<int> kAll6 = {0, 1, 2, 3, 4, 5};
const std::vector<int> kCubic2 = {0, 3};

// =========================================================================
// H1 — SELF-CHECK: a fully solid cell must recover the solid tensor to >=4 digits.
// =========================================================================
void H1_self_check() {
  std::printf("\n===== H1 SELF-CHECK — solid cell must recover solid tensor =====\n");
  const double lam = kE * kNu / ((1 + kNu) * (1 - 2 * kNu));
  const double mu = kE / (2 * (1 + kNu));
  const double C11a = lam + 2 * mu, C12a = lam, C44a = mu;
  std::printf("  analytic (isotropic PLA E=%.1f nu=%.2f):  C11=%.4f  C12=%.4f  C44=%.4f  Zener=1.0000\n",
              kE, kNu, C11a, C12a, C44a);
  VoxelGrid g;
  g.nx = g.ny = g.nz = 8;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(8 * 8 * 8, VoxelTag::Interior);
  HomogResult R = homogenize(g, kAll6, 1e-11);
  Cubic c = cubic_of(R, true);
  std::printf("  measured (periodic homogenization):      C11=%.4f  C12=%.4f  C44=%.4f  Zener=%.4f\n",
              c.C11, c.C12, c.C44, c.zener);
  std::printf("  rel.err:  C11=%.2e  C12=%.2e  C44=%.2e   off-cubic residual=%.2e  (cg<=%d)\n",
              std::fabs(c.C11 - C11a) / C11a, std::fabs(c.C12 - C12a) / C12a,
              std::fabs(c.C44 - C44a) / C44a, c.offcubic, R.cg_iters_max);
  bool ok = std::fabs(c.C11 - C11a) / C11a < 1e-4 &&
            std::fabs(c.C12 - C12a) / C12a < 1e-4 &&
            std::fabs(c.C44 - C44a) / C44a < 1e-4;
  std::printf("  -> %s (bar: all three within 1e-4 = 4 digits)\n",
              ok ? "PASS" : "FAIL");
  FILE* csv = csv_open("h1_self_check.csv");
  if (csv) {
    std::fprintf(csv, "quantity,analytic,measured,rel_err\n");
    std::fprintf(csv, "C11,%.6f,%.6f,%.3e\n", C11a, c.C11, std::fabs(c.C11 - C11a) / C11a);
    std::fprintf(csv, "C12,%.6f,%.6f,%.3e\n", C12a, c.C12, std::fabs(c.C12 - C12a) / C12a);
    std::fprintf(csv, "C44,%.6f,%.6f,%.3e\n", C44a, c.C44, std::fabs(c.C44 - C44a) / C44a);
    std::fprintf(csv, "zener,1.0,%.6f,%.3e\n", c.zener, std::fabs(c.zener - 1.0));
    std::fclose(csv);
  }
}

// =========================================================================
// H5 + H2/H6 — DENSITY SWEEP: the tensor library. Per topology, sweep relative
// density; single-cell periodic homogenization -> C11,C12,C44,Zener,E100,E111.
// Fit E100/Es vs rho -> exponent. Report Zener per row (which need a tensor).
// H6 (scale) travels: every row carries cell count(=1), cell size, rho, wall.
// =========================================================================
void H5_density_sweep(double L, int vpc) {
  std::printf("\n===== H5 DENSITY SWEEP + TENSOR LIBRARY (single cell, L=%.1f mm, vpc=%d) =====\n",
              L, vpc);
  std::printf("  H2/H6: Zener != 1 => a scalar knockdown misrepresents; report per row.\n");
  FILE* lib = csv_open("tensor_library.csv");
  if (lib)
    std::fprintf(lib, "lattice,cells,L_mm,vpc,spacing_mm,rho,wall_mm,wall_vox,"
                      "C11_MPa,C12_MPa,C44_MPa,zener,E100_MPa,E111_MPa,E100_over_Es,"
                      "offcubic_MPa,cg_iters,resolved\n");
  const double targets[] = {0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60};
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet}) {
    std::printf("\n  --- %s (L=%.1f mm) ---\n", name_of(l), L);
    std::printf("  %-6s %-8s %-9s %-9s %-9s %-7s %-9s %-9s %-6s\n",
                "rho", "wall_mm", "C11", "C12", "C44", "Zener", "E100/Es", "E111/Es", "cg");
    std::vector<std::pair<double, double>> fitpts;  // (rho, E100/Es)
    for (double tvf : targets) {
      GenParams g = calibrated(l, L, tvf, vpc);
      VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
      double rho = volume_fraction(grid);
      double wall_vox = median_wall_voxels(grid);
      double wall_mm = wall_vox * grid.spacing;
      HomogResult R = homogenize(grid, kAll6, 1e-9);
      Cubic c = cubic_of(R, true);
      double e100 = c.E100 / kE, e111 = c.E111 / kE;
      // Only rows with >=4 voxels/wall are resolution-converged (HR); flag the
      // rest — thin low-density walls alias and the numbers are unreliable there.
      bool resolved = wall_vox >= 4.0;
      if (resolved) fitpts.push_back({rho, e100});  // fit on resolved rows only
      std::printf("  %-6.3f %-8.3f %-9.2f %-9.2f %-9.2f %-7.3f %-9.4f %-9.4f %-6d %s\n",
                  rho, wall_mm, c.C11, c.C12, c.C44, c.zener, e100, e111,
                  R.cg_iters_max, resolved ? "" : "<under-resolved (wall<4vox)>");
      if (lib)
        std::fprintf(lib, "%s,1,%.3f,%d,%.5f,%.5f,%.4f,%.1f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%.4f,%d,%d\n",
                     name_of(l), L, vpc, grid.spacing, rho, wall_mm, wall_vox,
                     c.C11, c.C12, c.C44, c.zener, c.E100, c.E111, e100,
                     c.offcubic, R.cg_iters_max, resolved ? 1 : 0);
    }
    // Fit ln(E100/Es) = p*ln(rho)+b (least squares) over the sweep, and over the
    // low-density half only (where power laws hold; report high-density breakdown).
    auto fit = [&](std::size_t a, std::size_t b) {
      double sx = 0, sy = 0, sxx = 0, sxy = 0;
      int n = 0;
      for (std::size_t i = a; i < b && i < fitpts.size(); ++i) {
        if (fitpts[i].first <= 0 || fitpts[i].second <= 0) continue;
        double x = std::log(fitpts[i].first), y = std::log(fitpts[i].second);
        sx += x; sy += y; sxx += x * x; sxy += x * y; ++n;
      }
      double p = (n * sxy - sx * sy) / (n * sxx - sx * sx);
      return p;
    };
    double p_all = fit(0, fitpts.size());
    double p_low = fit(0, fitpts.size() / 2 + 1);
    std::printf("  -> E100/Es ~ rho^p (RESOLVED rows only, wall>=4vox):  "
                "p(all)=%.2f   p(low half)=%.2f\n", p_all, p_low);
    std::printf("     (octet 'linear' is a rho->0 asymptote; TPMS bending -> ~2; "
                "high-density flattening -> power law breaks as E/Es->1)\n");
  }
  if (lib) std::fclose(lib);
}

// =========================================================================
// H3 — CONVERGENCE with cell count. Fixed density; homogenize on RVEs of
// 1,2,3,5 cells. Report single-cell error vs the 5-cell (best) value.
// =========================================================================
void H3_convergence(double L, int vpc, double tvf) {
  std::printf("\n===== H3 CONVERGENCE — cells per RVE (L=%.1f mm, vpc=%d, target rho=%.2f) =====\n",
              L, vpc, tvf);
  std::printf("  lit: ~15-16%% single-cell error, ~5-10%% at 3+ cells; single-cell RVE warned against.\n");
  std::printf("  TWO boundary conditions per cell count:\n");
  std::printf("   (a) PERIODIC homogenization E100 — exact for a periodic medium; expected flat in K.\n");
  std::printf("   (b) DIRECT free-surface uniaxial E (z axis, production solver) — the WINDOWED RVE\n");
  std::printf("       the literature's single-cell warning is about; converges up with K.\n");
  FILE* csv = csv_open("h3_convergence.csv");
  if (csv)
    std::fprintf(csv, "lattice,cells,L_mm,vpc,spacing_mm,voxels,rho,wall_mm,"
                      "periodic_E100_MPa,periodic_E100_over_Es,zener,"
                      "direct_freeface_E_MPa,direct_over_Es,cg_iters,solve_ms\n");
  const int Ks[] = {1, 2, 3, 5};
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet}) {
    std::printf("\n  --- %s ---\n", name_of(l));
    std::printf("  %-6s %-10s %-6s %-8s | %-11s %-7s | %-13s %-8s\n",
                "cells", "voxels", "rho", "wall_mm", "periodicE100", "Zener",
                "directE(free)", "cg");
    GenParams g = calibrated(l, L, tvf, vpc);
    double per5 = 0, dir5 = 0;
    std::vector<std::array<double, 3>> pts;  // (K, periodicE, directE)
    for (int K : Ks) {
      VoxelGrid grid = build_lattice(g, K, K, K, vpc);
      double rho = volume_fraction(grid);
      double wall_mm = median_wall_voxels(grid) * grid.spacing;
      HomogResult R = homogenize(grid, kCubic2, 1e-9);
      Cubic c = cubic_of(R, false);
      double perE = c.E100;
      // Free-surface direct solve is expensive at 5 cells (~1.5M DOF Jacobi-CG)
      // and unnecessary: it is compared against the exact periodic bulk, which is
      // K-independent. Measure it at K<=3 (enough to name the single-cell error
      // and show it shrinking); K=5 keeps periodic only.
      double dirE = (K <= 3) ? direct_apparent_E(grid, 2) : 0.0;
      pts.push_back({(double)K, perE, dirE});
      per5 = perE;  // periodic is K-independent; last (K=5) == bulk
      if (K == 3) dir5 = dirE;  // best-resolved direct window
      if (dirE > 0)
        std::printf("  %-6d %-10zu %-6.3f %-8.3f | %-11.2f %-7.3f | %-13.2f %-8d\n",
                    K, grid.voxel_count(), rho, wall_mm, perE, c.zener, dirE,
                    R.cg_iters_max);
      else
        std::printf("  %-6d %-10zu %-6.3f %-8.3f | %-11.2f %-7.3f | %-13s %-8d\n",
                    K, grid.voxel_count(), rho, wall_mm, perE, c.zener,
                    "(skipped)", R.cg_iters_max);
      if (csv)
        std::fprintf(csv, "%s,%d,%.3f,%d,%.5f,%zu,%.5f,%.4f,%.4f,%.6f,%.4f,%.4f,%.6f,%d,%.0f\n",
                     name_of(l), K, L, vpc, grid.spacing, grid.voxel_count(), rho,
                     wall_mm, perE, perE / kE, c.zener, dirE, dirE / kE,
                     R.cg_iters_max, R.solve_ms);
    }
    // The periodic homogenized E100 is K-independent and exact for the periodic
    // medium (per1 == per5), so it IS the true bulk. The literature's single-cell
    // error is the FREE-SURFACE window's deviation from that bulk.
    double bulk = per5 > 0 ? per5 : (pts.empty() ? 0 : pts[0][1]);
    if (bulk > 0)
      for (auto& p : pts) {
        if (p[2] > 0)
          std::printf("    K=%d:  periodic err vs bulk = %+.2f%%   |   "
                      "direct(free) err vs periodic-bulk = %+.1f%%%s\n",
                      (int)p[0], 100.0 * (p[1] - bulk) / bulk,
                      100.0 * (p[2] - bulk) / bulk,
                      (int)p[0] == 1 ? "  <-- NAMED single-cell error" : "");
        else
          std::printf("    K=%d:  periodic err vs bulk = %+.2f%%   |   "
                      "direct(free): skipped\n",
                      (int)p[0], 100.0 * (p[1] - bulk) / bulk);
      }
  }
  if (csv) std::fclose(csv);
}

// =========================================================================
// HR — RESOLUTION convergence of the homogenized tensor. The tensor library
// must be computed at a voxel resolution where the periodic modulus has stopped
// moving; and the persistent periodic-vs-free-surface gap seen in H3/H4 must be
// decomposed into (i) discretization error and (ii) the genuine boundary-
// condition (free-surface) effect. Both are answered on a SINGLE cell (cheap
// even at high vpc), holding the physical geometry FIXED (calibrated once at a
// fine reference) and sweeping only the voxel resolution.
// =========================================================================
void HR_resolution(double L, double tvf) {
  std::printf("\n===== HR RESOLUTION CONVERGENCE of the homogenized tensor "
              "(single cell, L=%.1f mm, rho~%.2f) =====\n", L, tvf);
  std::printf("  geometry fixed at a vpc=64 reference; only voxel resolution varies.\n");
  std::printf("  Establishes the voxels-per-wall at which the tensor library (C11/C12/\n");
  std::printf("  C44, Zener, E100) stops moving. rho drifts at coarse vpc (aliasing).\n");
  FILE* csv = csv_open("hr_resolution.csv");
  if (csv)
    std::fprintf(csv, "lattice,cells,L_mm,vpc,spacing_mm,voxels,rho,wall_mm,wall_vox,"
                      "C11_MPa,C12_MPa,C44_MPa,zener,E100_over_Es\n");
  const int vpcs[] = {8, 12, 16, 24, 32, 48};
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet}) {
    std::printf("\n  --- %s ---\n", name_of(l));
    std::printf("  %-5s %-8s %-6s %-8s %-9s %-9s %-9s %-7s %-9s\n",
                "vpc", "h(mm)", "rho", "wall_vox", "C11", "C12", "C44", "Zener", "E100/Es");
    // Fix physical geometry at a fine reference resolution.
    const GenParams gref = calibrated(l, L, tvf, 64);
    for (int vpc : vpcs) {
      GenParams g{l, L, gref.level, gref.octet_r};
      VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
      double rho = volume_fraction(grid);
      double wall_vox = median_wall_voxels(grid);
      HomogResult R = homogenize(grid, kAll6, 1e-9);
      Cubic c = cubic_of(R, true);
      double e100 = c.E100 / kE;
      std::printf("  %-5d %-8.4f %-6.3f %-8.1f %-9.2f %-9.2f %-9.2f %-7.3f %-9.4f\n",
                  vpc, grid.spacing, rho, wall_vox, c.C11, c.C12, c.C44, c.zener, e100);
      if (csv)
        std::fprintf(csv, "%s,1,%.3f,%d,%.5f,%zu,%.5f,%.4f,%.1f,%.4f,%.4f,%.4f,%.4f,%.6f\n",
                     name_of(l), L, vpc, grid.spacing, grid.voxel_count(), rho,
                     wall_vox * grid.spacing, wall_vox, c.C11, c.C12, c.C44,
                     c.zener, e100);
    }
  }
  if (csv) std::fclose(csv);
}

// =========================================================================
// H4 — GO/NO-GO: homogenized modulus within 10% of a DIRECT resolved simulation
// of the SAME cell at 3 cells. Homogenized = single-cell periodic E100.
// Direct = 3x3x3-cell resolved uniaxial apparent E (production solver).
// =========================================================================
void H4_go_no_go(double L, int vpc, double tvf) {
  std::printf("\n===== H4 GO/NO-GO — homogenized vs direct resolved (3 cells) =====\n");
  std::printf("  bar: |homogenized - direct(3-cell)| / direct <= 10%%  => homogenized road OPEN.\n");
  std::printf("  L=%.1f mm, vpc=%d, target rho=%.2f\n", L, vpc, tvf);
  FILE* csv = csv_open("h4_go_no_go.csv");
  if (csv)
    std::fprintf(csv, "lattice,cells,L_mm,vpc,spacing_mm,rho,wall_mm,"
                      "homog_E100_MPa,homog_E100_over_Es,direct3_E_MPa,direct3_over_Es,"
                      "gap_pct,verdict\n");
  std::printf("  %-9s %-6s %-8s %-12s %-12s %-10s %-8s\n",
              "lattice", "rho", "wall_mm", "homog_E100", "direct3_E", "gap%", "verdict");
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet}) {
    GenParams g = calibrated(l, L, tvf, vpc);
    // homogenized single cell
    VoxelGrid one = build_lattice(g, 1, 1, 1, vpc);
    double rho = volume_fraction(one);
    double wall_mm = median_wall_voxels(one) * one.spacing;
    HomogResult R = homogenize(one, kCubic2, 1e-9);
    Cubic c = cubic_of(R, false);
    double homogE = c.E100;
    // direct resolved 3-cell block (z axis; cubic symmetry => axes agree)
    VoxelGrid blk = build_lattice(g, 3, 3, 3, vpc);
    std::printf("  [%s: solving direct 3-cell free-surface block (%zu voxels)...]\n",
                name_of(l), blk.voxel_count());
    std::fflush(stdout);
    double directE = direct_apparent_E(blk, 2);
    if (directE <= 0) {
      std::printf("  %-9s %-6.3f %-8.3f %-12.2f %-12s %-10s %-8s\n",
                  name_of(l), rho, wall_mm, homogE, "UNCONVERGED", "n/a",
                  "n/a (block near-mechanism)");
      if (csv)
        std::fprintf(csv, "%s,1vs3,%.3f,%d,%.5f,%.5f,%.4f,%.4f,%.6f,,,,%s\n",
                     name_of(l), L, vpc, one.spacing, rho, wall_mm, homogE,
                     homogE / kE, "unconverged");
      continue;
    }
    double gap = 100.0 * std::fabs(homogE - directE) / directE;
    const char* verdict = gap <= 10.0 ? "GO" : "NO-GO";
    std::printf("  %-9s %-6.3f %-8.3f %-12.2f %-12.2f %-10.1f %-8s\n",
                name_of(l), rho, wall_mm, homogE, directE, gap, verdict);
    if (csv)
      std::fprintf(csv, "%s,1vs3,%.3f,%d,%.5f,%.5f,%.4f,%.4f,%.6f,%.4f,%.6f,%.2f,%s\n",
                   name_of(l), L, vpc, one.spacing, rho, wall_mm, homogE,
                   homogE / kE, directE, directE / kE, gap, verdict);
  }
  if (csv) std::fclose(csv);
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);  // live progress for long solves
  std::printf("LATTICE HOMOGENIZATION LIBRARY (Phase 0) — E_solid=%.0f MPa nu=%.2f\n",
              kE, kNu);
  std::printf("method: periodic-BC strain homogenization, production Hex8 element\n");
  fea_set_matfree_threads(6);

  const char* only = std::getenv("TOPOPT_HOMOG_ONLY");
  auto want = [&](const char* s) { return !only || std::string(only) == s; };

  if (want("h1")) H1_self_check();
  if (only && std::string(only) == "verify") {
    std::printf("\n=== VERIFY: cubic2 (2 cases) vs full6 (6 cases), gyroid vpc32 ===\n");
    GenParams g = calibrated(Lattice::Gyroid, 5.0, 0.30, 32);
    VoxelGrid grid = build_lattice(g, 1, 1, 1, 32);
    Cubic c2 = cubic_of(homogenize(grid, kCubic2, 1e-9), false);
    Cubic c6 = cubic_of(homogenize(grid, kAll6, 1e-9), true);
    std::printf("  cubic2: C11=%.3f C12=%.3f C44=%.3f Zener=%.4f E100=%.3f\n",
                c2.C11, c2.C12, c2.C44, c2.zener, c2.E100);
    std::printf("  full6 : C11=%.3f C12=%.3f C44=%.3f Zener=%.4f E100=%.3f\n",
                c6.C11, c6.C12, c6.C44, c6.zener, c6.E100);
    return 0;
  }
  if (want("hr")) HR_resolution(5.0, 0.30);
  if (want("h5")) H5_density_sweep(5.0, 48);
  if (want("h3")) H3_convergence(5.0, 16, 0.30);
  if (want("h4")) H4_go_no_go(5.0, 16, 0.30);

  std::printf("\nDONE.\n");
  return 0;
}
