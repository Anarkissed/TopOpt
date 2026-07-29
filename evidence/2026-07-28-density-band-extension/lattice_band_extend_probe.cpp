// lattice_band_extend_probe.cpp — extend the octet homogenized-material
// CERTIFIABLE DENSITY BAND at BOTH ends (handoff 2026-07-28-density-band-extension).
//
// PR 234 (handoff 2026-07-28-lattice-density-band) established the band as
// rho ~= 0.15 -> 0.62:
//   - bounded BELOW at rho 0.148 by the library's minimum resolved row — an
//     UNDER-RESOLUTION alias floor (thin struts need more voxels across them);
//   - bounded ABOVE by a TENSOR CLAMP at rho 0.591, past which the frozen tensor
//     drifts -16% @0.64, -31% @0.70, -60% @0.90 (real, resolution-independent
//     MODEL error).
// The maintainer wants ~0.05-0.10 at the low end and ~0.80 at the high end. The
// two ends are DIFFERENT PROBLEMS:
//
//   LOW END = a COMPUTE problem. The floor is under-resolution. PR 198 established
//     octet needs 6-8 voxels per strut (strut DIAMETER in voxels). Recompute the
//     low rows at whatever vpc keeps 6-8 vox/strut down to rho 0.05, report the
//     cost, and call the density where resolution drift first falls below 2.4%
//     (PR 234's achieved accuracy in the validated band) the new floor.  -> LOW
//
//   HIGH END = a MODEL problem. Remove the clamp and compute REAL tensors up to
//     rho 0.90 against the frozen-clamp value (fixing the -16/-31/-60% drift). The
//     analytic rho(strut-radius) formula OVER-COUNTS up there (octet struts merge
//     at the nodes), so MEASURE rho from the voxelization and key on that. Validate
//     the new rows against a resolution-converged periodic reference (bar: 2.4%).
//     Report the Zener ratio — if octet becomes effectively isotropic as voids
//     close, say so (that is useful, not a problem).  -> HIGH
//
// The TRUTH throughout is PERIODIC HOMOGENIZATION (PR 198's method): the effective
// cubic tensor of the RESOLVED unit cell under periodic BC. It is resolution-clean
// (no free surface) and its only error is resolution, so "validate a row" == "show
// the periodic tensor has CONVERGED in vpc" (drift vs a finer reference < 2.4%).
// No finite-block resolved solves are needed here (PR 234 used those only to
// cross-check the periodic truth; they agreed to ~1%).  B4: NO PRODUCTION CHANGE —
// this is the OFFLINE library. The extended rows are emitted for a later wiring PR;
// topopt/lattice.cpp is left untouched.
//
// Standalone build (mirrors lattice_density_band_probe.cpp), from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && \
//     cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/lattice_band_extend_probe.cpp build/libtopopt.a \
//       -o build/lattice_band_extend_probe
// CSV sink: TOPOPT_LATTICE_CSV_DIR. Section gate: TOPOPT_BX_ONLY = self|repro|plan|low|high.
// Knobs: TOPOPT_BX_LOW_VFS, TOPOPT_BX_LOW_VPCS, TOPOPT_BX_HIGH_VFS, TOPOPT_BX_HIGH_VPCS,
//        TOPOPT_BX_DRIFT_TOL (default 2.4), TOPOPT_BX_VPS_TARGET (vox/strut target, 6).

#include <Eigen/IterativeLinearSolvers>
#include <Eigen/Sparse>

#include <sys/resource.h>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;   // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;    // PLA Poisson

// Process high-water resident set (macOS ru_maxrss is BYTES).
double peak_rss_mb() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return double(ru.ru_maxrss) / (1024.0 * 1024.0);
}

// ============================ octet geometry (PR 198 / band probe) ==========
double point_seg_dist2(double px, double py, double pz, const double a[3],
                       const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double denom = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = denom > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / denom : 0.0;
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
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0}, {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5}, {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5}, {1.0, 0.5, 0.5}}};
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
VoxelGrid build_octet(double L, double octet_r, int ncx, int ncy, int ncz, int vpc) {
  VoxelGrid g;
  g.nx = ncx * vpc;
  g.ny = ncy * vpc;
  g.nz = ncz * vpc;
  g.spacing = L / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        if (octet_dist2(c.x, c.y, c.z, L, segs) < octet_r * octet_r)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}
double volume_fraction(const VoxelGrid& g) {
  return double(g.solid_count()) / double(g.voxel_count());
}
// Bisection on the MEASURED (voxelized) volume fraction. Because the density map
// rho(r) is a per-vpc step function (aliasing), the achieved rho is REPORTED, never
// assumed — this only gets us near the target so successive rows land distinctly.
double calibrate_octet_r(double L, double target_vf, int vpc) {
  double lo = 0.0005 * L, hi = 0.60 * L;   // hi raised to reach near-solid rho
  for (int it = 0; it < 30; ++it) {
    double mid = 0.5 * (lo + hi);
    VoxelGrid g = build_octet(L, mid, 1, 1, 1, vpc);
    (volume_fraction(g) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// ANALYTIC octet relative density: thin-strut cylinder-sum. Sum of pi*r^2*len over
// the unit cell's struts, divided by L^3. This is the closed form a radius->density
// map uses; it IGNORES the volume shared where struts MERGE at the corner/face
// nodes, so it OVER-COUNTS — negligibly at low r, severely as r grows and the
// octet's 12 struts fuse into a solid with isolated void pockets. L6's point:
// above the merge onset the measured (voxelized, union-correct) rho is the truth.
double octet_rho_analytic(double L, double r) {
  auto segs = octet_struts();          // coordinates in [0,1] cell units
  double len_sum = 0.0;
  for (auto& s : segs) {
    double dx = s[1][0] - s[0][0], dy = s[1][1] - s[0][1], dz = s[1][2] - s[0][2];
    len_sum += std::sqrt(dx * dx + dy * dy + dz * dz) * L;   // strut length in mm
  }
  // Each of the 24 base legs is a face DIAGONAL lying in a boundary face, so it is
  // shared 50/50 with the adjacent cell (its z=0 struts are the neighbour's z=1
  // struts). Per-cell strut length is therefore HALF the base sum — this makes the
  // cylinder-sum the conventional thin-strut octet density that MATCHES the voxelised
  // rho at low r. The residual over-count that remains (node overlap) is small at low
  // r and BLOWS UP as r grows and the 12 struts fuse — that growth is L6's signal.
  const double per_cell_len = 0.5 * len_sum;
  return M_PI * r * r * per_cell_len / (L * L * L);
}

// ============================ periodic homogenization (PR 198) ==============
std::array<double, 576> ref_ke(double h) {
  Hex8Stiffness K = hex8_stiffness(kE, kNu, h);
  std::array<double, 576> out{};
  for (int i = 0; i < 576; ++i) out[i] = K.k[i];
  return out;
}
constexpr int kOff[8][3] = {{0,0,0},{1,0,0},{1,1,0},{0,1,0},
                            {0,0,1},{1,0,1},{1,1,1},{0,1,1}};
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
struct HomogResult {
  double CH[6][6] = {};
  int cg_iters_max = 0;
  bool converged = true;
  double solve_ms = 0;
  long ndof = 0;         // total periodic DOF (3 * cell voxels)
  long ndof_active = 0;  // DOF actually touched by a solid element (the real system)
  double asm_ms = 0;
};
// cases: {0,3} solves the cubic 2-case fast path (recovers C11,C12,C44); use full
// {0,1,2,3,4,5} to verify off-cubic residual. The C12 average-stress form
// (PR 198 gotcha) is honored: CH accumulates over ALL I for every solved J.
HomogResult homogenize(const VoxelGrid& grid, const std::vector<int>& cases, double cg_tol = 1e-9) {
  HomogResult R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz;
  const long nd = 3 * Np;
  R.ndof = nd;
  auto ke = ref_ke(h);
  auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    int aa = a % nx, bb = b % ny, cc = c % nz;
    return ((long)cc * ny + bb) * nx + aa;
  };
  auto t_asm0 = std::chrono::steady_clock::now();
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
          for (int c = 0; c < 24; ++c) trips.emplace_back((int)gd[r], (int)gd[c], ke[r * 24 + c]);
          for (int J : cases) {
            double f = 0;
            for (int c = 0; c < 24; ++c) f += ke[r * 24 + c] * chi0[c][J];
            F(gd[r], J) += f;
          }
        }
      }
  std::vector<char> pinned((std::size_t)nd, 0);
  pinned[0] = pinned[1] = pinned[2] = 1;
  long active = 0;
  for (long d = 0; d < nd; ++d) { if (touched[d]) ++active; else pinned[d] = 1; }
  R.ndof_active = active;
  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear(); trips.shrink_to_fit();
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()]) it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
  K.prune(0.0);
  for (long d = 0; d < nd; ++d) if (pinned[d]) for (int J : cases) F(d, J) = 0.0;
  auto t_asm1 = std::chrono::steady_clock::now();
  R.asm_ms = std::chrono::duration<double, std::milli>(t_asm1 - t_asm0).count();
  Eigen::ConjugateGradient<SpMat, Eigen::Lower | Eigen::Upper> cg;
  cg.setTolerance(cg_tol);
  cg.setMaxIterations((int)std::min<long>(nd * 2, 300000));
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
struct Cubic { double C11 = 0, C12 = 0, C44 = 0, zener = 0, E100 = 0, offcubic = 0; };
Cubic cubic_of(const HomogResult& R, bool full = false) {
  Cubic c;
  c.C11 = R.CH[0][0];
  c.C12 = 0.5 * (R.CH[1][0] + R.CH[2][0]);
  c.C44 = R.CH[3][3];
  double d = c.C11 - c.C12;
  c.zener = d != 0 ? 2.0 * c.C44 / d : 0.0;
  double den = c.C11 + c.C12;
  c.E100 = den != 0 ? d * (c.C11 + 2 * c.C12) / den : 0.0;
  if (full) {
    // Off-cubic residual: coupling terms that a cubic tensor forces to zero.
    double m = 0;
    for (int I = 0; I < 3; ++I)
      for (int J = 3; J < 6; ++J) m = std::max(m, std::fabs(R.CH[I][J]));
    c.offcubic = m;
  }
  return c;
}
double E100_of(double C11, double C12) {
  double d = C11 - C12, den = C11 + C12;
  return den != 0 ? d * (C11 + 2 * C12) / den : 0.0;
}
double zener_of(double C11, double C12, double C44) {
  double d = C11 - C12;
  return d != 0 ? 2.0 * C44 / d : 0.0;
}

// ============================ env helpers ===================================
std::vector<double> env_doubles(const char* key, const std::vector<double>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<double> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atof(tok.c_str()));
  return out.empty() ? def : out;
}
std::vector<int> env_ints(const char* key, const std::vector<int>& def) {
  const char* s = std::getenv(key);
  if (!s) return def;
  std::vector<int> out; std::stringstream ss(s); std::string tok;
  while (std::getline(ss, tok, ',')) if (!tok.empty()) out.push_back(std::atoi(tok.c_str()));
  return out.empty() ? def : out;
}
int env_int(const char* key, int def) { const char* s = std::getenv(key); return s ? std::atoi(s) : def; }
double env_double(const char* key, double def) { const char* s = std::getenv(key); return s ? std::atof(s) : def; }

FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

// ============================ matched-rho row solve =========================
// One periodic-homogenization row at a target density, with r RECALIBRATED at this
// vpc so the achieved rho matches the target at THIS resolution. Holding rho matched
// across vpc (rather than holding r fixed) is what makes the drift a PURE resolution
// measure: the library keys on rho, so "does the periodic tensor at rho X converge
// as the mesh refines?" is the validation question, and at low density dE/drho is so
// steep that a fixed-r rho-staircase (~+-10% rho between resolutions) would otherwise
// swamp the resolution signal. Achieved rho is reported per vpc to prove the match.
struct RowSolve {
  double rho = 0, r = 0, vps = 0;
  double C11 = 0, C12 = 0, C44 = 0, E100 = 0, zener = 0;
  long ndof = 0, ndof_active = 0;
  int cg_iters = 0;
  double asm_ms = 0, solve_ms = 0, rss_mb = 0;
};
RowSolve solve_matched(double L, double target_vf, int vpc) {
  RowSolve rs;
  rs.r = calibrate_octet_r(L, target_vf, vpc);
  VoxelGrid cell = build_octet(L, rs.r, 1, 1, 1, vpc);
  rs.rho = volume_fraction(cell);
  rs.vps = 2.0 * rs.r * vpc / L;
  HomogResult R = homogenize(cell, {0, 3}, 1e-9);
  Cubic c = cubic_of(R);
  rs.C11 = c.C11; rs.C12 = c.C12; rs.C44 = c.C44; rs.E100 = c.E100; rs.zener = c.zener;
  rs.ndof = R.ndof; rs.ndof_active = R.ndof_active; rs.cg_iters = R.cg_iters_max;
  rs.asm_ms = R.asm_ms; rs.solve_ms = R.solve_ms; rs.rss_mb = peak_rss_mb();
  return rs;
}

// ============================ frozen-clamp reference ========================
// The value the library FREEZES above rho_max = 0.591 (its top resolved row). Every
// high-density query today returns this same tensor — the source of the -16/-31/-60%.
CubicTensor frozen_clamp_tensor() {
  return lattice_cubic_tensor(LatticeTopology::Octet, 1.0, kE);  // clamps to rho_max row
}

// ================================ B1 SELF CHECK ============================
void SELF_checks(double L) {
  std::printf("\n===== SELF (bar B1) — instrument recovers E_solid to 4 digits =====\n");
  FILE* csv = csv_open("self_check.csv");
  if (csv) std::fprintf(csv, "vpc,E100_MPa,rel_err,zener,verdict\n");
  for (int vpc : {8, 16, 24, 32}) {
    VoxelGrid g = build_octet(L, 1e9, 1, 1, 1, vpc);  // huge r -> all solid
    if (volume_fraction(g) < 0.999999) { std::printf("  vpc%-3d NOT fully solid\n", vpc); continue; }
    Cubic c = cubic_of(homogenize(g, {0, 3}, 1e-11));
    double relE = (c.E100 - kE) / kE;
    bool pass = std::fabs(relE) < 1e-4;
    std::printf("  vpc%-3d solid cell: E100=%.4f MPa (E_solid=%.1f)  rel=%+.6f  Zener=%.4f -> %s\n",
                vpc, c.E100, kE, relE, c.zener, pass ? "PASS (4 digits)" : "CHECK");
    if (csv) std::fprintf(csv, "%d,%.4f,%+.6e,%.4f,%s\n", vpc, c.E100, relE, c.zener, pass ? "PASS" : "CHECK");
  }
  const double cc = kE / ((1 + kNu) * (1 - 2 * kNu));
  const double C11 = cc * (1 - kNu), C12 = cc * kNu, C44 = kE / (2 * (1 + kNu));
  Hex8Stiffness Kiso = hex8_stiffness(kE, kNu, 1.7);
  Hex8Stiffness Kcub = hex8_stiffness_cubic(C11, C12, C44, 1.7);
  double maxabs = 0;
  for (int i = 0; i < 576; ++i) maxabs = std::max(maxabs, std::fabs(Kiso.k[i] - Kcub.k[i]));
  std::printf("  cubic(iso tensor) vs hex8_stiffness: max|dK|=%.3e -> %s\n",
              maxabs, maxabs == 0.0 ? "BIT-IDENTICAL" : (maxabs < 1e-9 ? "within 1e-9" : "MISMATCH"));
  if (csv) std::fclose(csv);
}

// ================================ B3 REPRODUCE ============================
// The existing validated band (PR 234: rho 0.15-0.54 within +-2.4%) must be
// REPRODUCED UNCHANGED. The library rows ARE the periodic@vpc48 values, so the
// check is: (a) our periodic homogenization reproduces PR 234's E_periodic column,
// and (b) library-vs-periodic model error is still <= 2.4% across the mid band.
void REPRO_band(double L) {
  std::printf("\n===== B3 REPRODUCE — existing validated band rho 0.15-0.54 must be UNCHANGED =====\n");
  const int vpc = 48;
  // (target_vf, PR234 E_periodic @vpc48) from the density-band handoff D1 table.
  struct Ref { double tvf, ePer234; };
  std::vector<Ref> refs = {
      {0.15, 96.13}, {0.20, 155.80}, {0.25, 213.67}, {0.30, 286.42},
      {0.35, 378.91}, {0.40, 489.22}, {0.45, 629.81}, {0.50, 772.34}, {0.55, 917.91}};
  FILE* csv = csv_open("repro_band.csv");
  if (csv) std::fprintf(csv, "target_vf,rho,vox_per_strut,E_periodic_MPa,E234_MPa,repro_err_pct,E_library_MPa,model_err_pct,verdict\n");
  std::printf("  %-6s %-7s %-7s %-11s %-11s %-9s %-11s %-9s %s\n",
              "vf", "rho", "vox/str", "E_periodic", "E234_ref", "reproErr", "E_library", "model%", "verdict");
  bool all_ok = true;
  for (auto& rf : refs) {
    double r = calibrate_octet_r(L, rf.tvf, vpc);
    double vps = 2.0 * r * vpc / L;
    VoxelGrid cell = build_octet(L, r, 1, 1, 1, vpc);
    double rho = volume_fraction(cell);
    double ePer = cubic_of(homogenize(cell, {0, 3}, 1e-9)).E100;
    CubicTensor Clib = lattice_cubic_tensor(LatticeTopology::Octet, rho, kE);
    double eLib = E100_of(Clib.C11, Clib.C12);
    double repro = 100.0 * (ePer - rf.ePer234) / rf.ePer234;
    double model = 100.0 * (eLib - ePer) / ePer;
    // The band criterion is the MODEL error (library vs periodic truth) <= 2.4%.
    // reproErr vs PR 234's ABSOLUTE table is only meaningful at matched rho; at a
    // fixed target vf the calibration lands on a slightly different aliasing step
    // (PR 234's own caveat), so it is reported for provenance, not gated.
    bool ok = std::fabs(model) <= 2.4;
    all_ok = all_ok && ok;
    std::printf("  %-6.2f %-7.4f %-7.2f %-11.2f %-11.2f %-+9.2f %-11.2f %-+9.2f %s\n",
                rf.tvf, rho, vps, ePer, rf.ePer234, repro, eLib, model, ok ? "GO" : "NO-GO");
    if (csv) std::fprintf(csv, "%.2f,%.5f,%.3f,%.4f,%.4f,%+.2f,%.4f,%+.2f,%s\n",
                          rf.tvf, rho, vps, ePer, rf.ePer234, repro, eLib, model, ok ? "GO" : "NO-GO");
  }
  if (csv) std::fclose(csv);
  std::printf("  reproErr%% = our periodic E100 vs PR 234's D1 table (informational; noisy at fixed\n"
              "  target vf because achieved rho lands on a different aliasing step — compare at matched rho).\n"
              "  model%% = library tensor vs periodic truth at the ACHIEVED rho (the certifiable error, <=2.4%%).\n"
              "  B3 verdict (on model%%): %s\n", all_ok ? "REPRODUCED (band unchanged)" : "*** MOVED — investigate ***");
}

// ================================ PLAN (geometry only) ====================
// Cheap: no solves. For each target rho x vpc, report MEASURED rho, ANALYTIC rho,
// and vox/strut. Picks the vpc ladder that keeps octet's 6-8 vox/strut down to 0.05
// and exposes where analytic rho starts over-counting (strut merge) at the high end.
void PLAN_geometry(double L) {
  std::printf("\n===== PLAN — geometry only: vox/strut & analytic-vs-measured rho (no solves) =====\n");
  std::vector<double> vfs = env_doubles("TOPOPT_BX_PLAN_VFS",
      {0.05, 0.06, 0.07, 0.08, 0.10, 0.12, 0.148, 0.20, 0.30, 0.50,
       0.591, 0.62, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90});
  std::vector<int> vpcs = env_ints("TOPOPT_BX_PLAN_VPCS", {48, 64, 96, 128});
  FILE* csv = csv_open("plan_geometry.csv");
  if (csv) std::fprintf(csv, "target_vf,vpc,octet_r_mm,rho_measured,rho_analytic,analytic_over_pct,vox_per_strut\n");
  std::printf("  %-6s | per vpc: vox/strut (rho_meas)   [analytic rho @ finest, over-count %%]\n", "vf");
  for (double tvf : vfs) {
    // Calibrate r ONCE at the finest vpc so geometry is fixed; report per-vpc vox/strut.
    int vfin = vpcs.back();
    double r = calibrate_octet_r(L, tvf, vfin);
    double rho_an = octet_rho_analytic(L, r);
    std::printf("  %-6.3f |", tvf);
    double rho_meas_fin = 0;
    for (int vpc : vpcs) {
      VoxelGrid cell = build_octet(L, r, 1, 1, 1, vpc);
      double rho = volume_fraction(cell);
      if (vpc == vfin) rho_meas_fin = rho;
      double vps = 2.0 * r * vpc / L;
      std::printf(" %5.1f(%.3f)", vps, rho);
      if (csv) {
        double over = rho > 0 ? 100.0 * (rho_an - rho) / rho : 0.0;
        std::fprintf(csv, "%.3f,%d,%.5f,%.5f,%.5f,%.2f,%.3f\n", tvf, vpc, r, rho, rho_an, over, vps);
      }
    }
    double over = rho_meas_fin > 0 ? 100.0 * (rho_an - rho_meas_fin) / rho_meas_fin : 0.0;
    std::printf("   [an %.3f, +%.1f%%]\n", rho_an, over);
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: pick the smallest vpc whose vox/strut >= %.0f for each target rho (the LOW ladder).\n"
              "  analytic over-count grows as struts MERGE (high rho) — L6: key the library on MEASURED rho.\n",
              env_double("TOPOPT_BX_VPS_TARGET", 6.0));
}

// ================================ LOW END (L1/L2/L3) ======================
void LOW_end(double L) {
  std::printf("\n===== LOW END (L1/L2/L3) — recompute low-density rows at 6-8 vox/strut =====\n");
  std::vector<double> vfs = env_doubles("TOPOPT_BX_LOW_VFS", {0.05, 0.06, 0.08, 0.10, 0.12, 0.148});
  std::vector<int> vpcs = env_ints("TOPOPT_BX_LOW_VPCS", {48, 64, 96, 128});
  const double drift_tol = env_double("TOPOPT_BX_DRIFT_TOL", 2.4);
  const double vps_target = env_double("TOPOPT_BX_VPS_TARGET", 6.0);
  const int vpc_ref = vpcs.back();   // finest = convergence reference (matched rho)
  std::printf("  truth = periodic homogenization; reference resolution = vpc%d (finest, MATCHED rho).\n", vpc_ref);
  std::printf("  r is recalibrated at EACH vpc to the target rho, so drift is PURE resolution.\n");
  std::printf("  a row is TRUSTWORTHY when its periodic E100 drift vs vpc%d < %.1f%% AND vox/strut >= %.0f.\n\n",
              vpc_ref, drift_tol, vps_target);

  FILE* csv = csv_open("low_end.csv");
  if (csv) std::fprintf(csv, "target_vf,vpc,octet_r_mm,rho_measured,rho_analytic,vox_per_strut,"
                             "C11,C12,C44,E100_MPa,zener,drift_vs_ref_pct,ndof,ndof_active,cg_iters,"
                             "asm_ms,solve_ms,peak_rss_mb,trustworthy\n");
  std::printf("  %-6s %-5s %-7s %-7s %-8s %-10s %-8s %-9s %-6s %-9s %-8s %s\n",
              "vf", "vpc", "rho", "vox/str", "E100", "drift%", "zener", "DOFact", "cg", "solve_s", "RSS_MB", "row");

  for (double tvf : vfs) {
    // Reference row: matched rho at the finest vpc.
    RowSolve ref = solve_matched(L, tvf, vpc_ref);
    double bestGoodVpc = -1; RowSolve best{}; double bestDrift = 0;
    for (int vpc : vpcs) {
      RowSolve rs = (vpc == vpc_ref) ? ref : solve_matched(L, tvf, vpc);
      double rho_an = octet_rho_analytic(L, rs.r);
      double drift = 100.0 * (rs.E100 - ref.E100) / ref.E100;
      bool good = std::fabs(drift) < drift_tol && rs.vps >= vps_target;
      std::printf("  %-6.3f %-5d %-7.4f %-7.2f %-8.1f %-+10.2f %-8.4f %-9ld %-6d %-9.2f %-8.0f %s%s\n",
                  tvf, vpc, rs.rho, rs.vps, rs.E100, drift, rs.zener, rs.ndof_active, rs.cg_iters,
                  rs.solve_ms / 1000.0, rs.rss_mb, good ? "TRUST" : "-",
                  (vpc == vpc_ref) ? " (ref)" : "");
      if (csv) std::fprintf(csv, "%.3f,%d,%.6f,%.5f,%.5f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%+.2f,%ld,%ld,%d,%.0f,%.0f,%.1f,%d\n",
                            tvf, vpc, rs.r, rs.rho, rho_an, rs.vps, rs.C11, rs.C12, rs.C44, rs.E100, rs.zener,
                            drift, rs.ndof, rs.ndof_active, rs.cg_iters, rs.asm_ms, rs.solve_ms, rs.rss_mb, good ? 1 : 0);
      if (good && bestGoodVpc < 0) { bestGoodVpc = vpc; best = rs; bestDrift = drift; }
    }
    if (bestGoodVpc > 0)
      std::printf("      -> rho %.4f library row: vpc%d, vox/strut %.1f, E100 %.1f MPa, drift %+.2f%% -> TRUSTWORTHY\n",
                  best.rho, (int)bestGoodVpc, best.vps, best.E100, bestDrift);
    else
      std::printf("      -> rho ~%.3f: NO vpc in ladder both converged (<%.1f%%) and >= %.0f vox/strut\n",
                  tvf, drift_tol, vps_target);
    std::printf("\n");
  }
  if (csv) std::fclose(csv);
  std::printf("  L3: the NEW FLOOR is the lowest target rho with a TRUSTWORTHY row above.\n"
              "  L2 cost: DOFact (active periodic DOF), cg iters, solve_s and RSS_MB per row (scales ~vpc^3;\n"
              "  PR 198's largest resolved solve was 512k vox / 1.5M periodic DOF in minutes).\n");
}

// ================================ HIGH END (L5/L6/L7/L8) ==================
void HIGH_end(double L) {
  std::printf("\n===== HIGH END (L5/L6/L7/L8) — remove the clamp, real tensors to rho 0.90 =====\n");
  std::vector<double> vfs = env_doubles("TOPOPT_BX_HIGH_VFS",
      {0.591, 0.62, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90});
  std::vector<int> vpcs = env_ints("TOPOPT_BX_HIGH_VPCS", {48, 64});
  const double drift_tol = env_double("TOPOPT_BX_DRIFT_TOL", 2.4);
  const int vpc_row = vpcs.front();   // the resolution the library row is quoted at (48, matches PR 198)
  const int vpc_ref = vpcs.back();    // finer reference for convergence validation
  CubicTensor Cfrozen = frozen_clamp_tensor();
  double eFrozen = E100_of(Cfrozen.C11, Cfrozen.C12);
  std::printf("  frozen-clamp tensor (rho_max=%.3f): C11=%.1f C12=%.1f C44=%.1f  E100=%.1f MPa.\n",
              lattice_rho_max(LatticeTopology::Octet), Cfrozen.C11, Cfrozen.C12, Cfrozen.C44, eFrozen);
  std::printf("  library row quoted at vpc%d; validated (L7) against periodic vpc%d, bar %.1f%%.\n\n",
              vpc_row, vpc_ref, drift_tol);

  FILE* csv = csv_open("high_end.csv");
  if (csv) std::fprintf(csv, "target_vf,rho_measured,rho_ref,rho_analytic,analytic_over_pct,vpc_row,vox_per_strut,"
                             "C11,C12,C44,E100_row_MPa,zener,E100_frozen_MPa,clamp_err_fixed_pct,"
                             "E100_ref_MPa,drift_vs_ref_pct,ndof_active,solve_ms,peak_rss_mb,valid_2p4\n");
  std::printf("  %-6s %-7s %-8s %-8s %-8s %-9s %-8s %-9s %-9s %-9s %s\n",
              "rho", "an_rho", "an_over%", "vox/str", "E100", "clampFix%", "zener", "E100_ref", "drift%", "valid", "note");

  for (double tvf : vfs) {
    // Row at the library resolution, reference at the finer vpc — BOTH matched to the
    // same target rho (r recalibrated per vpc), so drift is pure resolution not the
    // measured-rho aliasing between two resolutions.
    RowSolve row = solve_matched(L, tvf, vpc_row);
    RowSolve ref = (vpc_ref == vpc_row) ? row : solve_matched(L, tvf, vpc_ref);
    double rho_an = octet_rho_analytic(L, row.r);
    double an_over = row.rho > 0 ? 100.0 * (rho_an - row.rho) / row.rho : 0.0;
    double clamp_fix = 100.0 * (row.E100 - eFrozen) / eFrozen;   // +% == real modulus above frozen
    double drift = 100.0 * (row.E100 - ref.E100) / ref.E100;
    double rss = std::max(row.rss_mb, ref.rss_mb);
    bool valid = std::fabs(drift) < drift_tol;
    std::printf("  %-6.4f %-7.4f %-8.1f %-8.2f %-8.1f %-+9.1f %-8.4f %-9.1f %-+9.2f %-9s %s\n",
                row.rho, rho_an, an_over, row.vps, row.E100, clamp_fix, row.zener, ref.E100, drift,
                valid ? "GO" : "NO-GO",
                std::fabs(tvf - 0.591) < 1e-6 ? "(anchor)" : "");
    if (csv) std::fprintf(csv, "%.3f,%.5f,%.5f,%.5f,%.2f,%d,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%+.2f,%.4f,%+.2f,%ld,%.0f,%.1f,%d\n",
                          tvf, row.rho, ref.rho, rho_an, an_over, vpc_row, row.vps, row.C11, row.C12, row.C44,
                          row.E100, row.zener, eFrozen, clamp_fix, ref.E100, drift,
                          ref.ndof_active, ref.solve_ms, rss, valid ? 1 : 0);
  }
  if (csv) std::fclose(csv);
  std::printf("\n  L5 clampFix%% = real E100 vs the frozen 1124.55 MPa: it is the -16/-31/-60%% drift, now MEASURED.\n"
              "  L6 an_over%% = analytic cylinder-sum rho over MEASURED rho: grows as struts merge (key on measured).\n"
              "  L7 drift%% = periodic vpc%d vs vpc%d: < %.1f%% == converged/validated row.\n"
              "  L8 zener -> if it trends to 1.0 as rho->0.9, octet becomes effectively ISOTROPIC near solid.\n",
              vpc_row, vpc_ref, drift_tol);
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::printf("LATTICE BAND-EXTENSION PROBE — E_solid=%.0f MPa nu=%.2f, octet, L=5 mm\n", kE, kNu);
  std::printf("library resolved band today: rho [%.3f, %.3f]. Extending BOTH ends (offline, B4).\n",
              lattice_rho_min(LatticeTopology::Octet), lattice_rho_max(LatticeTopology::Octet));
  fea_set_matfree_threads(6);

  const char* only = std::getenv("TOPOPT_BX_ONLY");
  auto want = [&](const char* s) { return !only || std::string(only) == s; };
  const double L = 5.0;

  if (want("self"))  SELF_checks(L);
  if (want("repro")) REPRO_band(L);
  if (want("plan"))  PLAN_geometry(L);
  if (want("low"))   LOW_end(L);
  if (want("high"))  HIGH_end(L);

  std::printf("\nDONE.\n");
  return 0;
}
