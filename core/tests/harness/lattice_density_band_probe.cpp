// lattice_density_band_probe.cpp — VALIDATION harness for the lattice
// homogenized-material DENSITY BAND + graded-transition study
// (handoff 2026-07-28-lattice-density-band).
//
// This answers two questions the maintainer raised after PR 220's C2 result
// (12.96% NO-GO @ vf0.20, 3.47% GO @ 0.30, 16.22% NO-GO @ 0.40, all at vpc16):
//
//   Q1  Is C2's density dependence a REAL model error or a PROBE artifact
//       (under-resolution)?  ->  D1/D2/D3.
//   Q2  Can a lattice grade continuously up to solid (strut radius -> 100%),
//       and is the homogenized material trustworthy across that ramp? -> D4/D5.
//
// It reuses PR 220's C2 methodology (finite-block apparent modulus, resolved vs
// homogenized) AND PR 198's periodic homogenization (the TRUE effective tensor at
// any resolution). Having BOTH lets it DECOMPOSE the C2 gap into:
//     (a) tensor error      : library tensor (fixed @vpc48) vs true periodic @vpc
//     (b) free-surface error: finite resolved block vs periodic bulk
//     (c) resolution error  : true periodic @vpc vs true periodic @vpc48
// which is what separates "probe artifact" from "real model error".
//
//   D1  density sweep vf 0.15..0.90 (<=0.05 steps) x vpc {16,32,48}; every row
//       carries VOXELS-PER-STRUT (PR198's governing quantity), achieved rho,
//       cells, the resolved reference, and the model gap.
//   D2  the vf 0.40 cause, decomposed with numbers.
//   D3  the certifiable band: rho range where the homogenized model stays within
//       10% of resolved truth at a stated resolution.
//   D4  a continuous lattice->solid RAMP solved resolved vs homogenized
//       (per-element density), error along the ramp, AND the same as a HARD
//       boundary for comparison.
//   D5  ramp length sweep: error + stress-concentration vs transition length.
//
// NOT production, NOT a CI test. Standalone build (mirrors lattice_cert_probe.cpp
// / lattice_homog_probe.cpp), from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && \
//     cmake --build build --target topopt -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/lattice_density_band_probe.cpp build/libtopopt.a \
//       -o build/lattice_density_band_probe
// CSV sink: set TOPOPT_LATTICE_CSV_DIR to write the machine-readable tables there.
// Section gate: TOPOPT_DB_ONLY = self|d1|d2|d3|d4|d5 (default: all).
// Sweep knobs (D1): TOPOPT_DB_CELLS (block cells/side, default 2),
//   TOPOPT_DB_VPCS ("16,32,48"), TOPOPT_DB_VFS ("0.15,...,0.90").

#include <Eigen/IterativeLinearSolvers>
#include <Eigen/Sparse>

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
constexpr double kStrain = 1e-3;

// ============================ octet geometry (PR 198 / cert probe) ==========
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
double calibrate_octet_r(double L, double target_vf, int vpc) {
  double lo = 0.0005 * L, hi = 0.45 * L;   // hi raised for high-vf sweep
  for (int it = 0; it < 34; ++it) {
    double mid = 0.5 * (lo + hi);
    VoxelGrid g = build_octet(L, mid, 1, 1, 1, vpc);
    (volume_fraction(g) < target_vf ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}
// Max achievable octet relative density (largest single-cell rho at hi radius).
double octet_rho_at_r(double L, double r, int vpc) {
  return volume_fraction(build_octet(L, r, 1, 1, 1, vpc));
}

// ============================ uniaxial apparent modulus =====================
// (verbatim from lattice_cert_probe.cpp) Displacement-controlled uniaxial test.
double apparent_E(const VoxelGrid& g, const std::vector<double>& elem_youngs,
                  const std::vector<char>& lattice_mask,
                  const std::vector<double>& c11, const std::vector<double>& c12,
                  const std::vector<double>& c44, int axis, bool lattice,
                  double* solve_ms = nullptr, long* ndof_out = nullptr,
                  FeaSolution* sol_out = nullptr, bool confine = false) {
  const int N[3] = {g.nx, g.ny, g.nz};
  const double h = g.spacing;
  const int t1 = (axis + 1) % 3, t2 = (axis + 2) % 3;
  std::vector<char> issolid((std::size_t)fea_node_count(g), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k))
          for (int n : fea_element_nodes(g, i, j, k)) issolid[n] = 1;
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
  if (confine) {
    // Symmetry (roller) confinement on the 4 lateral faces: u_t1=0 on both
    // t1-normal faces, u_t2=0 on both t2-normal faces. This is a laterally
    // CONFINED uniaxial (oedometric) test — it removes the rocking / Poisson
    // near-singular modes that stall CG on a tall, soft-based graded column, and
    // it matches the confinement implicit in the coarse homogenized macro solve.
    // Applied IDENTICALLY to the resolved and homogenized ramp so the comparison
    // is fair. It measures the confined modulus, not free E100 — consistent on
    // both sides. (D1's density sweep keeps free faces; confine is ramp-only.)
    for (int cA = 0; cA <= N[axis]; ++cA)
      for (int c2 = 0; c2 <= nt2; ++c2)
        for (int side = 0; side < 2; ++side) {
          auto co = make_coord(cA, side == 0 ? 0 : nt1, c2);
          int n = fea_node_index(g, co[0], co[1], co[2]);
          if (issolid[n]) bcs.push_back({n, t1, 0.0});
        }
    for (int cA = 0; cA <= N[axis]; ++cA)
      for (int c1 = 0; c1 <= nt1; ++c1)
        for (int side = 0; side < 2; ++side) {
          auto co = make_coord(cA, c1, side == 0 ? 0 : nt2);
          int n = fea_node_index(g, co[0], co[1], co[2]);
          if (issolid[n]) bcs.push_back({n, t2, 0.0});
        }
  } else {
    if (pinA >= 0) { bcs.push_back({pinA, t1, 0.0}); bcs.push_back({pinA, t2, 0.0}); }
    if (pinB >= 0 && pinB != pinA) bcs.push_back({pinB, t2, 0.0});
  }
  if (ndof_out) *ndof_out = 3L * fea_node_count(g);

  FeaSolution sol;
  // Resolved (non-lattice) large blocks: geometric-multigrid matrix-free is far
  // faster than assembled Jacobi-CG when TOPOPT_DB_MG=1 (default). It solves the
  // IDENTICAL system (same void-gate, same BCs); it can fall back to Jacobi on
  // sparse/uncoarsenable geometry (loud, handled by the library).
  static const bool use_mg = [] { const char* s = std::getenv("TOPOPT_DB_MG"); return !s || std::string(s) != "0"; }();
  static const double rtol = [] { const char* s = std::getenv("TOPOPT_DB_RESTOL"); return s ? std::atof(s) : 1e-5; }();
  static const int rmax = [] { const char* s = std::getenv("TOPOPT_DB_RESMAXIT"); return s ? std::atoi(s) : 30000; }();
  auto t0 = std::chrono::steady_clock::now();
  try {
    if (lattice)
      sol = fea_solve_cg_lattice(g, elem_youngs, lattice_mask, c11, c12, c44, kNu,
                                 bcs, {}, 1e-5, 30000, nullptr);
    else if (use_mg)
      sol = fea_solve_mgcg_matfree(g, elem_youngs, kNu, bcs, {}, rtol, rmax, nullptr, nullptr);
    else
      sol = fea_solve_cg(g, elem_youngs, kNu, bcs, {}, rtol, rmax, nullptr, nullptr);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E axis %d unconverged: %s]\n", axis, e.what());
    return -1.0;
  }
  auto t1c = std::chrono::steady_clock::now();
  if (solve_ms) *solve_ms = std::chrono::duration<double, std::milli>(t1c - t0).count();

  double Fsum = 0.0;
  std::vector<double> react(3L * fea_node_count(g), 0.0);
  const Hex8Stiffness KeIso1 = hex8_stiffness(1.0, kNu, h);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<double, 24> ue{};
        int edof[24];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) {
            edof[3 * a + c] = 3 * en[a] + c;
            ue[3 * a + c] = sol.at(en[a], c);
          }
        Hex8Stiffness Ke;
        if (lattice && !lattice_mask.empty() && lattice_mask[e])
          Ke = hex8_stiffness_cubic(c11[e], c12[e], c44[e], h);
        else {
          const double f = elem_youngs[e];
          Ke = KeIso1;
          for (auto& v : Ke.k) v *= f;
        }
        for (int r = 0; r < 24; ++r) {
          double s = 0;
          for (int c = 0; c < 24; ++c) s += Ke(r, c) * ue[c];
          react[edof[r]] += s;
        }
      }
  for (auto& m : maxface) Fsum += react[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  if (sol_out) *sol_out = sol;
  return std::fabs(Fsum) / (A * kStrain);
}

double mean_uz_on_plane(const VoxelGrid& g, const FeaSolution& sol, int kp) {
  double sum = 0;
  long cnt = 0;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i) {
      bool solid = false;
      for (int dk = -1; dk <= 0 && !solid; ++dk)
        for (int dj = -1; dj <= 0 && !solid; ++dj)
          for (int di = -1; di <= 0 && !solid; ++di) {
            int vi = i + di, vj = j + dj, vk = kp + dk;
            if (vi >= 0 && vj >= 0 && vk >= 0 && vi < g.nx && vj < g.ny && vk < g.nz &&
                g.solid(vi, vj, vk))
              solid = true;
          }
      if (!solid) continue;
      sum += sol.at(fea_node_index(g, i, j, kp), 2);
      ++cnt;
    }
  return cnt > 0 ? sum / double(cnt) : 0.0;
}

double resolved_E(const VoxelGrid& g, int axis, double* ms = nullptr, long* nd = nullptr,
                  FeaSolution* sol = nullptr, bool confine = false) {
  std::vector<double> ey(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
  return apparent_E(g, ey, {}, {}, {}, {}, axis, /*lattice=*/false, ms, nd, sol, confine);
}

VoxelGrid macro_grid(double L, int ncx, int ncy, int ncz) {
  VoxelGrid g;
  g.nx = ncx; g.ny = ncy; g.nz = ncz; g.spacing = L; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)ncx * ncy * ncz, VoxelTag::Interior);
  return g;
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
struct HomogResult { double CH[6][6] = {}; int cg_iters_max = 0; bool converged = true; double solve_ms = 0; };
HomogResult homogenize(const VoxelGrid& grid, const std::vector<int>& cases, double cg_tol = 1e-9) {
  HomogResult R;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const long Np = (long)nx * ny * nz;
  const long nd = 3 * Np;
  auto ke = ref_ke(h);
  auto chi0 = element_chi0(h);
  auto pid = [&](int a, int b, int c) -> long {
    int aa = a % nx, bb = b % ny, cc = c % nz;
    return ((long)cc * ny + bb) * nx + aa;
  };
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
  for (long d = 0; d < nd; ++d) if (!touched[d]) pinned[d] = 1;
  SpMat K((int)nd, (int)nd);
  K.setFromTriplets(trips.begin(), trips.end());
  trips.clear(); trips.shrink_to_fit();
  for (int c = 0; c < K.outerSize(); ++c)
    for (SpMat::InnerIterator it(K, c); it; ++it)
      if (pinned[it.row()] || pinned[it.col()]) it.valueRef() = (it.row() == it.col()) ? 1.0 : 0.0;
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
struct Cubic { double C11 = 0, C12 = 0, C44 = 0, zener = 0, E100 = 0; };
Cubic cubic_of(const HomogResult& R) {
  Cubic c;
  c.C11 = R.CH[0][0];
  c.C12 = 0.5 * (R.CH[1][0] + R.CH[2][0]);
  c.C44 = R.CH[3][3];
  double d = c.C11 - c.C12;
  c.zener = d != 0 ? 2.0 * c.C44 / d : 0.0;
  double den = c.C11 + c.C12;
  c.E100 = den != 0 ? d * (c.C11 + 2 * c.C12) / den : 0.0;
  return c;
}
// E100 of a cubic tensor (same closed form).
double E100_of(double C11, double C12) {
  double d = C11 - C12, den = C11 + C12;
  return den != 0 ? d * (C11 + 2 * C12) / den : 0.0;
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
int env_int(const char* key, int def) {
  const char* s = std::getenv(key);
  return s ? std::atoi(s) : def;
}

FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

// ================================ B1 SELF CHECK ============================
// Periodic homogenization of a fully-SOLID cell must recover E_solid to 4 digits;
// and the cubic element with the isotropic tensor == hex8_stiffness bit-for-bit.
void SELF_checks(double L) {
  std::printf("\n===== SELF (bar B1) — instrument recovers E_solid =====\n");
  for (int vpc : {8, 16, 24}) {
    VoxelGrid g = build_octet(L, 1e9, 1, 1, 1, vpc);  // huge r -> all solid
    if (volume_fraction(g) < 0.999999) { std::printf("  vpc%-3d NOT fully solid (rho=%.6f)\n", vpc, volume_fraction(g)); continue; }
    HomogResult R = homogenize(g, {0, 3}, 1e-11);
    Cubic c = cubic_of(R);
    double relE = (c.E100 - kE) / kE;
    std::printf("  vpc%-3d solid cell: E100=%.4f MPa (E_solid=%.1f)  rel=%+.6f  Zener=%.4f -> %s\n",
                vpc, c.E100, kE, relE, c.zener,
                std::fabs(relE) < 1e-4 ? "PASS (4 digits)" : "CHECK");
  }
  const double cc = kE / ((1 + kNu) * (1 - 2 * kNu));
  const double C11 = cc * (1 - kNu), C12 = cc * kNu, C44 = kE / (2 * (1 + kNu));
  Hex8Stiffness Kiso = hex8_stiffness(kE, kNu, 1.7);
  Hex8Stiffness Kcub = hex8_stiffness_cubic(C11, C12, C44, 1.7);
  double maxabs = 0;
  for (int i = 0; i < 576; ++i) maxabs = std::max(maxabs, std::fabs(Kiso.k[i] - Kcub.k[i]));
  std::printf("  cubic(iso tensor) vs hex8_stiffness: max|dK|=%.3e -> %s\n",
              maxabs, maxabs == 0.0 ? "BIT-IDENTICAL" : (maxabs < 1e-9 ? "within 1e-9" : "MISMATCH"));
  std::printf("  library E100 at solid limit (rho=%.3f clamp): %.1f MPa (vs E_solid %.1f) — the\n"
              "  library CANNOT represent solid: its max resolved row is rho=%.3f.\n",
              lattice_rho_max(LatticeTopology::Octet),
              E100_of(lattice_cubic_tensor(LatticeTopology::Octet, 1.0, kE).C11,
                      lattice_cubic_tensor(LatticeTopology::Octet, 1.0, kE).C12),
              kE, lattice_rho_max(LatticeTopology::Octet));
}

// ================================ D1/D2/D3 ================================
// The master decomposition table. For each (vf, vpc): resolved finite block,
// true periodic tensor @vpc, library tensor (fixed @vpc48), homogenized macro
// model. Reports voxels-per-strut and every error component.
void D1_density_band(double L) {
  std::printf("\n===== D1/D2/D3 — density band: homogenized model vs RESOLVED truth =====\n");
  const int Nc = env_int("TOPOPT_DB_CELLS", 2);
  std::vector<int> vpcs = env_ints("TOPOPT_DB_VPCS", {16, 32, 48});
  std::vector<double> vfs = env_doubles("TOPOPT_DB_VFS",
      {0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.80, 0.90});
  // Resolved FINITE-BLOCK solves (free surfaces, PR220's C2 method) are O(10^6) DOF
  // and cost minutes at high vpc / low density (measured: vpc48 2-cell dilute is
  // tens of minutes on a 6-P-core Mac — B4). They run only up to this vpc cap; the
  // TRUTH the model is graded against is the PERIODIC homogenization (resolved unit
  // cell, periodic BC), which is resolution-clean, converges by vpc48, and is
  // affordable (~1-3 s) at every density. TOPOPT_DB_RES_MAXVPC raises the finite cap.
  const int res_maxvpc = env_int("TOPOPT_DB_RES_MAXVPC", 16);
  const int vpc_ref = env_int("TOPOPT_DB_REF_VPC", 48);   // resolution the band is quoted at
  std::printf("  finite block = %d^3 cells; TRUTH = periodic homogenization (resolved unit cell).\n", Nc);
  std::printf("  bar: |E_library - E_periodic| / E_periodic <= 10%%. band quoted at vpc%d.\n", vpc_ref);
  std::printf("  resolved FINITE blocks (C2 method) run only up to vpc%d (cost gate, B4); shown for cross-check.\n\n", res_maxvpc);

  FILE* csv = csv_open("d1_density_band.csv");
  if (csv) std::fprintf(csv, "target_vf,rho,vpc,vox_per_strut,cells,E_periodic_MPa,E_periodic_ref_MPa,"
                             "E_library_MPa,model_err_pct,res_drift_pct,E_resolved_finite_MPa,"
                             "fs_err_pct,finite_gap_pct,clamped,resolved_dof,resolved_ms,verdict_ref\n");
  std::printf("  %-6s %-7s %-5s %-8s %-11s %-11s %-11s %-9s %-8s %-8s\n",
              "vf", "rho", "vpc", "vox/str", "E_periodic", "E_library", "E_resFinite",
              "model%", "resdft%", "verdict");

  for (double tvf : vfs) {
    double r = calibrate_octet_r(L, vpc_ref >= 16 ? tvf : tvf, std::max(vpc_ref, 48));  // FIXED geometry, calibrated fine
    // periodic truth at the reference resolution (the number the band is quoted at)
    double ePerRef = cubic_of(homogenize(build_octet(L, r, 1, 1, 1, vpc_ref), {0, 3}, 1e-9)).E100;
    bool clampedRef = false;
    { VoxelGrid rb = build_octet(L, r, Nc, Nc, Nc, vpc_ref);
      lattice_cubic_tensor(LatticeTopology::Octet, volume_fraction(rb), kE, &clampedRef); }
    for (int vpc : vpcs) {
      double vox_per_strut = 2.0 * r * vpc / L;
      VoxelGrid blk = build_octet(L, r, Nc, Nc, Nc, vpc);
      double rho = volume_fraction(blk);

      // periodic truth at THIS vpc (cheap)
      double ePer = (vpc == vpc_ref) ? ePerRef
                    : cubic_of(homogenize(build_octet(L, r, 1, 1, 1, vpc), {0, 3}, 1e-9)).E100;

      // library model
      bool clamped = false;
      CubicTensor Clib = lattice_cubic_tensor(LatticeTopology::Octet, rho, kE, &clamped);
      double eLib = E100_of(Clib.C11, Clib.C12);
      double model_err = 100.0 * (eLib - ePer) / ePer;          // model vs periodic truth (this vpc)
      double res_drift = 100.0 * (ePer - ePerRef) / ePerRef;    // tensor's own resolution drift

      // resolved finite block (C2 method) — only within the affordability cap
      double eR = -1, msR = 0; long ndR = 0; double fs = 0, finite_gap = 0;
      if (vpc <= res_maxvpc) {
        eR = resolved_E(blk, 2, &msR, &ndR);
        if (eR > 0) {
          VoxelGrid mg = macro_grid(L, Nc, Nc, Nc);
          std::vector<double> ey(mg.voxel_count(), kE);
          std::vector<char> mask(mg.voxel_count(), 1);
          std::vector<double> c11(mg.voxel_count(), Clib.C11), c12(mg.voxel_count(), Clib.C12),
              c44(mg.voxel_count(), Clib.C44);
          double eMacro = apparent_E(mg, ey, mask, c11, c12, c44, 2, true);
          fs = 100.0 * (eR - ePer) / ePer;                      // free-surface softening/stiffening
          finite_gap = 100.0 * std::fabs(eMacro - eR) / eR;     // the exact C2 metric
        }
      }

      bool go = std::fabs(model_err) <= 10.0;
      std::printf("  %-6.2f %-7.4f %-5d %-8.2f %-11.2f %-11.2f %-11s %-+9.2f %-+8.2f %-8s%s\n",
                  tvf, rho, vpc, vox_per_strut, ePer, eLib,
                  eR > 0 ? (std::to_string((long)std::lround(eR))).c_str() : "—",
                  model_err, res_drift, go ? "GO" : "NO-GO", clamped ? " [CLAMPED]" : "");
      if (csv) std::fprintf(csv, "%.2f,%.5f,%d,%.3f,%d,%.4f,%.4f,%.4f,%.2f,%.2f,%.4f,%.2f,%.2f,%d,%ld,%.0f,%s\n",
                            tvf, rho, vpc, vox_per_strut, Nc, ePer, ePerRef, eLib, model_err, res_drift,
                            eR, fs, finite_gap, clamped ? 1 : 0, ndR, msR, go ? "GO" : "NO-GO");
    }
    std::printf("\n");
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: model%% = library tensor vs periodic truth at that vpc — the certifiable error.\n"
              "  resdft%% = the periodic tensor's own resolution drift (->0 at vpc%d): if it is small while\n"
              "  model%% is large, the miss is the MODEL, not the mesh. [CLAMPED] = rho exceeds the\n"
              "  library's max resolved row (%.3f), so the tensor is FROZEN and model%% grows without bound.\n"
              "  E_resFinite / finite_gap (CSV) cross-check against PR220's finite-block C2 method where affordable.\n",
              vpc_ref, lattice_rho_max(LatticeTopology::Octet));
}

}  // namespace

// D4/D5 live in the same file below (declared here, defined after main-helpers).
namespace { void D4_ramp(double L); void D5_ramp_length(double L); }

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::printf("LATTICE DENSITY-BAND + RAMP PROBE — E_solid=%.0f MPa nu=%.2f, octet, L=5 mm\n", kE, kNu);
  std::printf("cores: matfree=6 (6 P-core Mac). library max resolved rho=%.3f.\n",
              lattice_rho_max(LatticeTopology::Octet));
  fea_set_matfree_threads(6);

  const char* only = std::getenv("TOPOPT_DB_ONLY");
  auto want = [&](const char* s) { return !only || std::string(only) == s; };
  const double L = 5.0;

  if (want("self")) SELF_checks(L);
  if (want("d1") || want("d2") || want("d3")) D1_density_band(L);
  if (want("d4")) D4_ramp(L);
  if (want("d5")) D5_ramp_length(L);

  std::printf("\nDONE.\n");
  return 0;
}

// ================================ D4 / D5 ================================
namespace {

// Radius (mm) that makes a single octet cell essentially fully solid at `vpc`.
double octet_solid_radius(double L, int vpc, double* rho_out = nullptr) {
  double lo = 0.10 * L, hi = 0.90 * L, best = hi, bestrho = 0;
  for (int it = 0; it < 30; ++it) {
    double mid = 0.5 * (lo + hi);
    double rho = octet_rho_at_r(L, mid, vpc);
    if (rho >= 0.999) { best = mid; bestrho = rho; hi = mid; } else { lo = mid; bestrho = rho; }
  }
  if (rho_out) *rho_out = octet_rho_at_r(L, best, vpc);
  return best;
}

// Build a resolved graded octet bar: radius varies continuously with world-z.
// Layout along z (cells): [pad_lo lattice @ r_lo] [Ltrans ramp r_lo->r_solid]
// [pad_hi solid]. For hard=true, no ramp: lattice below the transition midplane,
// solid above (same total height). `cell_rho` receives the achieved rho of each
// z-cell layer (the per-element density the homogenized model consumes).
VoxelGrid build_ramp(double L, int vpc, int Nl, int pad_lo, int Ltrans, int pad_hi,
                     double r_lo, double r_solid, bool hard,
                     std::vector<double>& cell_rho) {
  const int Nz = pad_lo + Ltrans + pad_hi;
  VoxelGrid g;
  g.nx = Nl * vpc; g.ny = Nl * vpc; g.nz = Nz * vpc;
  g.spacing = L / vpc; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)g.nx * g.ny * g.nz, VoxelTag::Empty);
  auto segs = octet_struts();
  const double z0 = pad_lo * L, z1 = (pad_lo + Ltrans) * L;
  const double zmid = pad_lo * L + 0.5 * Ltrans * L;  // hard-boundary plane
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        bool solid = false;
        if (hard) {
          if (c.z >= zmid) solid = true;
          else solid = octet_dist2(c.x, c.y, c.z, L, segs) < r_lo * r_lo;
        } else {
          double r;
          if (c.z < z0) r = r_lo;
          else if (c.z < z1) { double t = (c.z - z0) / (z1 - z0); r = r_lo + t * (r_solid - r_lo); }
          else r = 1e9;  // solid cap
          solid = octet_dist2(c.x, c.y, c.z, L, segs) < r * r;
        }
        if (solid) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  // Per-cell-layer achieved rho.
  cell_rho.assign(Nz, 0.0);
  for (int cz = 0; cz < Nz; ++cz) {
    long s = 0, t = 0;
    for (int k = cz * vpc; k < (cz + 1) * vpc; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) { ++t; if (g.solid(i, j, k)) ++s; }
    cell_rho[cz] = double(s) / double(t);
  }
  return g;
}

// Homogenized macro model for a ramp: one cubic (or isotropic-solid) element per
// z-cell, tensor from the library at that cell's achieved rho. Returns apparent E
// and (via out) the per-cell homogenized axial strain and the count of cells that
// landed in the library's CLAMPED band (rho > lattice_rho_max).
double ramp_homogenized_E(double L, int Nl, const std::vector<double>& cell_rho,
                          int* clamped_cells, FeaSolution* sol_out) {
  const int Nz = (int)cell_rho.size();
  VoxelGrid mg = macro_grid(L, Nl, Nl, Nz);
  std::vector<double> ey(mg.voxel_count(), kE);
  std::vector<char> mask(mg.voxel_count(), 0);
  std::vector<double> c11(mg.voxel_count(), 0), c12(mg.voxel_count(), 0), c44(mg.voxel_count(), 0);
  int nclamp = 0;
  const double rho_max = lattice_rho_max(LatticeTopology::Octet);
  for (int cz = 0; cz < Nz; ++cz) {
    double rho = cell_rho[cz];
    for (int j = 0; j < Nl; ++j)
      for (int i = 0; i < Nl; ++i) {
        std::size_t e = mg.index(i, j, cz);
        if (rho >= 0.98) { mask[e] = 0; ey[e] = kE; }   // solid cell -> isotropic
        else {
          bool cl = false;
          CubicTensor C = lattice_cubic_tensor(LatticeTopology::Octet, rho, kE, &cl);
          mask[e] = 1; c11[e] = C.C11; c12[e] = C.C12; c44[e] = C.C44;
          if (cl && i == 0 && j == 0) ++nclamp;
        }
      }
  }
  if (clamped_cells) *clamped_cells = nclamp;
  return apparent_E(mg, ey, mask, c11, c12, c44, 2, true, nullptr, nullptr, sol_out, /*confine=*/true);
}

// Von Mises stress-concentration factor of a resolved ramp: peak vM anywhere over
// the mean vM in the pure-lattice pad (far field). SCF proxy for the junction.
double ramp_scf(const VoxelGrid& g, const FeaSolution& sol, int vpc, int pad_lo) {
  std::vector<double> vm = fea_von_mises_field(g, kE, kNu, sol);
  double peak = 0, padsum = 0; long padn = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        double v = vm[g.index(i, j, k)];
        if (v > peak) peak = v;
        if (k < pad_lo * vpc) { padsum += v; ++padn; }   // far-field lattice pad
      }
  double farfield = padn > 0 ? padsum / double(padn) : 0.0;
  return farfield > 0 ? peak / farfield : 0.0;
}

// Solve one ramp (resolved + homogenized) and report along-ramp error + SCF.
struct RampResult {
  double eR = 0, eH = 0, gap = 0, scf = 0;
  int clamped = 0; long dof = 0; double ms = 0;
};
RampResult solve_ramp(double L, int vpc, int Nl, int pad_lo, int Ltrans, int pad_hi,
                      double r_lo, double r_solid, bool hard, FILE* layer_csv,
                      const char* tag) {
  RampResult R;
  std::vector<double> cell_rho;
  VoxelGrid g = build_ramp(L, vpc, Nl, pad_lo, Ltrans, pad_hi, r_lo, r_solid, hard, cell_rho);
  FeaSolution solR;
  double ms = 0; long dof = 0;
  R.eR = resolved_E(g, 2, &ms, &dof, &solR, /*confine=*/true);
  R.ms = ms; R.dof = dof;
  FeaSolution solH;
  R.eH = ramp_homogenized_E(L, Nl, cell_rho, &R.clamped, &solH);
  R.gap = R.eR > 0 ? 100.0 * std::fabs(R.eH - R.eR) / R.eR : -1;
  R.scf = ramp_scf(g, solR, vpc, pad_lo);
  // Per-layer axial strain: resolved vs homogenized, the error ALONG the ramp.
  const int Nz = pad_lo + Ltrans + pad_hi;
  for (int layer = 0; layer < Nz; ++layer) {
    double ur0 = mean_uz_on_plane(g, solR, layer * vpc);
    double ur1 = mean_uz_on_plane(g, solR, (layer + 1) * vpc);
    double uh0 = mean_uz_on_plane(macro_grid(L, Nl, Nl, Nz), solH, layer);
    double uh1 = mean_uz_on_plane(macro_grid(L, Nl, Nl, Nz), solH, layer + 1);
    double eps_r = (ur1 - ur0) / L / kStrain;
    double eps_h = (uh1 - uh0) / L / kStrain;
    double err = eps_h != 0 ? 100.0 * (eps_r - eps_h) / eps_h : 0.0;
    if (layer_csv)
      std::fprintf(layer_csv, "%s,%d,%.5f,%.5f,%.5f,%.2f\n", tag, layer, cell_rho[layer], eps_r, eps_h, err);
  }
  return R;
}

void D4_ramp(double L) {
  std::printf("\n===== D4 — continuous lattice->solid RAMP vs homogenized (per-element rho) =====\n");
  const int vpc = env_int("TOPOPT_DB_RAMP_VPC", 12);
  const int Nl = env_int("TOPOPT_DB_RAMP_NL", 2);
  const int pad_lo = 2, pad_hi = 2, Ltrans = env_int("TOPOPT_DB_RAMP_LTRANS", 4);
  // Base rho 0.40: a legitimate in-band lattice, well-connected (a barely-connected
  // rho~0.20 base at coarse vpc leaves the tall column near-singular — CG cannot
  // solve it; that is a solver-conditioning limit, not the model's). Confined solve.
  const double rho_lo = env_doubles("TOPOPT_DB_RAMP_BASE", {0.40})[0];
  double r_lo = calibrate_octet_r(L, rho_lo, vpc);
  double solid_rho = 0; double r_solid = octet_solid_radius(L, vpc, &solid_rho);
  std::printf("  vpc=%d, %dx%d lateral, layout: %d lattice(rho~%.2f) + %d ramp + %d solid cells.\n",
              vpc, Nl, Nl, pad_lo, rho_lo, Ltrans, pad_hi);
  std::printf("  octet becomes solid at r=%.3f mm (rho=%.4f); r_lo=%.3f mm.\n", r_solid, solid_rho, r_lo);

  FILE* layer_csv = csv_open("d4_ramp_layers.csv");
  if (layer_csv) std::fprintf(layer_csv, "design,layer,cell_rho,eps_resolved,eps_homog,err_pct\n");

  RampResult G = solve_ramp(L, vpc, Nl, pad_lo, Ltrans, pad_hi, r_lo, r_solid, false, layer_csv, "graded");
  RampResult H = solve_ramp(L, vpc, Nl, pad_lo, Ltrans, pad_hi, r_lo, r_solid, true, layer_csv, "hard");
  if (layer_csv) std::fclose(layer_csv);

  FILE* csv = csv_open("d4_ramp_summary.csv");
  if (csv) {
    std::fprintf(csv, "design,vpc,Nl,pad_lo,Ltrans,pad_hi,E_resolved_MPa,E_homog_MPa,model_gap_pct,scf,clamped_cells,resolved_dof,resolved_ms\n");
    std::fprintf(csv, "graded,%d,%d,%d,%d,%d,%.4f,%.4f,%.2f,%.4f,%d,%ld,%.0f\n",
                 vpc, Nl, pad_lo, Ltrans, pad_hi, G.eR, G.eH, G.gap, G.scf, G.clamped, G.dof, G.ms);
    std::fprintf(csv, "hard,%d,%d,%d,%d,%d,%.4f,%.4f,%.2f,%.4f,%d,%ld,%.0f\n",
                 vpc, Nl, pad_lo, Ltrans, pad_hi, H.eR, H.eH, H.gap, H.scf, H.clamped, H.dof, H.ms);
    std::fclose(csv);
  }
  std::printf("  %-8s %-11s %-11s %-9s %-7s %-8s %-12s\n", "design", "E_resolved", "E_homog", "gap%", "SCF", "clamped", "resolved");
  std::printf("  %-8s %-11.2f %-11.2f %-9.2f %-7.3f %-8d %ld DOF %.0f ms\n",
              "graded", G.eR, G.eH, G.gap, G.scf, G.clamped, G.dof, G.ms);
  std::printf("  %-8s %-11.2f %-11.2f %-9.2f %-7.3f %-8d %ld DOF %.0f ms\n",
              "hard", H.eR, H.eH, H.gap, H.scf, H.clamped, H.dof, H.ms);
  std::printf("  READ: 'clamped' = ramp cells whose rho exceeds the library's max resolved row\n"
              "  (%.3f) and are therefore modeled with a FROZEN too-soft tensor. SCF is peak/far-field\n"
              "  von Mises in the RESOLVED struts — the hard boundary's stress concentration vs the ramp's.\n",
              lattice_rho_max(LatticeTopology::Octet));
}

void D5_ramp_length(double L) {
  std::printf("\n===== D5 — how long must the ramp be? error + stress-concentration vs length =====\n");
  const int vpc = env_int("TOPOPT_DB_RAMP_VPC", 12);
  const int Nl = env_int("TOPOPT_DB_RAMP_NL", 2);
  const int pad_lo = 2, pad_hi = 2;
  const double rho_lo = env_doubles("TOPOPT_DB_RAMP_BASE", {0.40})[0];
  double r_lo = calibrate_octet_r(L, rho_lo, vpc);
  double solid_rho = 0; double r_solid = octet_solid_radius(L, vpc, &solid_rho);
  std::vector<int> lens = env_ints("TOPOPT_DB_LENS", {1, 2, 3, 4, 6, 8});

  FILE* csv = csv_open("d5_ramp_length.csv");
  if (csv) std::fprintf(csv, "Ltrans_cells,vpc,Nl,E_resolved_MPa,E_homog_MPa,model_gap_pct,scf,clamped_cells,resolved_dof,resolved_ms\n");
  std::printf("  vpc=%d, %dx%d lateral, rho_lo=%.2f -> solid. transition length in cells:\n", vpc, Nl, Nl, rho_lo);
  std::printf("  %-8s %-11s %-11s %-9s %-7s %-8s %-10s\n", "Ltrans", "E_resolved", "E_homog", "gap%", "SCF", "clamped", "res_ms");
  for (int Lt : lens) {
    RampResult G = solve_ramp(L, vpc, Nl, pad_lo, Lt, pad_hi, r_lo, r_solid, false, nullptr, "graded");
    std::printf("  %-8d %-11.2f %-11.2f %-9.2f %-7.3f %-8d %.0f\n",
                Lt, G.eR, G.eH, G.gap, G.scf, G.clamped, G.ms);
    if (csv) std::fprintf(csv, "%d,%d,%d,%.4f,%.4f,%.2f,%.4f,%d,%ld,%.0f\n",
                          Lt, vpc, Nl, G.eR, G.eH, G.gap, G.scf, G.clamped, G.dof, G.ms);
  }
  if (csv) std::fclose(csv);
  std::printf("  READ: find the shortest Ltrans where SCF and gap%% stop improving. A ramp that must be\n"
              "  many cells long is a costlier feature than one that works in 2.\n");
}

}  // namespace
