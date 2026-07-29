// spectral_coarse_probe.cpp — Phase-0 GenEO / spectral coarse-space SIZING harness.
//
// NOT a CI test, NOT wired into CTest, NOT linked into any production path. It adds
// ZERO production code and ZERO new build dependency: it uses only the already-present
// Homebrew Eigen (`<Eigen/Eigenvalues>` GeneralizedSelfAdjointEigenSolver) plus the
// production library `libtopopt.a`. No SLEPc, no HPDDM, no Spectra.
//
// WHAT IT ANSWERS (task G1/G2/G4). On a REAL OC-developed 3D SIMP density field it
// measures the size of the spectral coarse space in the Alexandersen & Lazarov (CMAME
// 290, 2015 / arXiv 1411.3923) formulation — the only spectral method demonstrated FOR
// SIMP topology optimisation:
//
//   per agglomerate (subdomain) omega_i, solve the generalised eigenproblem
//       K^{omega_i} psi = lambda diag(K^{omega_i}) psi        (A&L eq. 9, diag weighting §3.2)
//   and keep every eigenvector with lambda < lambda_Omega. N_i = #(such eigenvalues).
//   TOTAL COARSE DIMENSION N_t = sum_i N_i  <-- THE G1 DELIVERABLE.
//
// diag(K) weighting (A&L §3.2: spectrally equivalent to the stiffness-mass matrix,
// cheaper) makes the pencil (K^w, diag(K^w)) symmetric-definite, so a dense
// GeneralizedSelfAdjointEigenSolver gives the EXACT count and the full local spectrum
// (the gap structure that decides whether a threshold cleanly separates the
// contrast-induced near-null modes from the bulk). We report N_t, its memory, the
// per-subdomain distribution, and the correlation with local feature (ligament) count,
// across a few subdomain decompositions, the four production ladder rungs, a contrast
// sweep (rho_min 1e-3 -> contrast 1e9  vs  1e-2 -> 1e6), a threshold sweep, and a
// void-elimination variant (G4).
//
// NORMALISATION. Development uses the FULL production physics (E0=3500 MPa, nu=0.33,
// p=3, rho_min=1e-3, MultigridCG_Matfree, 2.5 mm filter) — the field is real. The
// eigen-analysis then remaps density -> modulus with E0=1 (Emax=1) so the measured
// lambda and the threshold are directly comparable to A&L's lambda_Omega. The
// generalised eigenvalue lambda = (psi^T K psi)/(psi^T diag(K) psi) is invariant to a
// global E scale (checked in `selfcheck`); only the CONTRAST (rho_min) moves it.
//
// BUILD (library built Release first; OCCT off, tests off — matches lattice_homog_probe):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//       core/tests/harness/spectral_coarse_probe.cpp core/build/libtopopt.a \
//       -o core/build/spectral_coarse_probe
// RUN: ./core/build/spectral_coarse_probe <mode> [csvdir]
//   modes: selfcheck | measure | all
//
// THERMAL PROTOCOL. Every number here (mode counts, N_t, memory bytes, eigenvalues) is
// DETERMINISTIC — no wall-clock claim is load-bearing. Field development uses the
// production deterministic OC path.

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <Eigen/Dense>
#include <Eigen/Eigenvalues>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE0 = 3500.0;   // PLA, MPa (development physics)
constexpr double kNu = 0.33;
constexpr int kSimpP = 3;
constexpr double kRhoMinProd = 1e-3;  // production void floor -> contrast 1e9
constexpr double kH = 1.0;            // voxel edge (mm)

// The four production savings-ladder rungs (production_reduction_ladder()).
const std::vector<double> kLadder = {0.68, 0.52, 0.38, 0.26};

// A&L threshold lambda_Omega (§6.1.1 uses 6.5e-4); we also sweep around it.
constexpr double kLambdaAL = 6.5e-4;

// ---------------------------------------------------------------------------
// System = grid + BCs + loads.  Fields developed by the production OC recipe.
// ---------------------------------------------------------------------------
struct System {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::string name;
  double part_fraction = 1.0;  // solid design fraction of the box (for vf scaling)
};

// A cantilever design DOMAIN that FILLS the box: fixed x=0 face, a downward (-z)
// load distributed over the far x=nx face. OC development fills it with a real
// optimised topology at each rung -> realistic feature density everywhere.
System build_cantilever(int nx, int ny, int nz) {
  System S;
  S.name = "cantilever";
  VoxelGrid& g = S.grid;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = kH; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  S.part_fraction = 1.0;

  // Fix the whole x=0 face (a=0), all three components.
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      S.bcs.push_back({nd, 0, 0.0});
      S.bcs.push_back({nd, 1, 0.0});
      S.bcs.push_back({nd, 2, 0.0});
    }
  // Downward line load along the far-face bottom edge (a=nx, c=0), spread in -z.
  std::vector<int> tip;
  for (int b = 0; b <= ny; ++b) tip.push_back(fea_node_index(g, nx, b, 0));
  const double total = -100.0;
  for (int nd : tip) S.loads.push_back({nd, 2, total / static_cast<double>(tip.size())});
  return S;
}

// The committed ultra-dilute L-bracket in a box (48x32x48, handoff 134), lifted
// verbatim from amg_lean_probe.cpp:build_ultradilute — the production complaint's
// shape and the dilute-contrast regime.
System build_ultradilute() {
  const int bx = 48, by = 32, bz = 48;
  const int arm = 24, span = 24, ny = 6, t = 6;
  System S;
  S.name = "ultradilute";
  VoxelGrid& g = S.grid;
  g.nx = bx; g.ny = by; g.nz = bz;
  g.spacing = 1.0; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(bx) * by * bz, VoxelTag::Interior);
  long long part = 0;
  for (int k = 0; k < arm && k < bz; ++k)
    for (int j = 0; j < ny && j < by; ++j)
      for (int i = 0; i < span && i < bx; ++i)
        if (i < t || k < t) { g.set_tag(i, j, k, VoxelTag::Surface); ++part; }
  for (int j = 0; j < ny && j < by; ++j)
    for (int i = 0; i < t && i < bx; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  for (int b = 0; b <= ny && b <= by; ++b)
    for (int a = 0; a <= t && a <= bx; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      S.bcs.push_back({node, 0, 0.0});
      S.bcs.push_back({node, 1, 0.0});
      S.bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t && k < bz; ++k)
    for (int j = 0; j < ny && j < by; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  S.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  S.part_fraction = static_cast<double>(part) / static_cast<double>(g.voxel_count());
  return S;
}

// Run the production OC recipe (rung -> absolute vf = rung*part_fraction) and return
// the DEVELOPED physical density field.  Real physics: E0=3500, MultigridCG_Matfree,
// 2.5mm filter, tol 1e-8. `rho_min` sets the development floor.
std::vector<double> develop_field(const System& S, double rung, int iters,
                                  double rho_min, int* cg_last) {
  SimpParams params;
  params.youngs_modulus = kE0;
  params.poisson = kNu;
  params.penalty = static_cast<double>(kSimpP);
  params.density_min = rho_min;
  const double vf = rung * S.part_fraction;
  const DensityFilter f =
      make_density_filter(S.grid, physical_filter_radius(2.5, S.grid.spacing));
  std::vector<double> x = simp_uniform_density(S.grid, vf);
  std::vector<double> xp;
  for (int it = 0; it < iters; ++it) {
    xp = f.filter_density(x);
    const SimpCompliance c = simp_compliance(S.grid, params, xp, S.bcs, S.loads, 1e-8,
                                             0, nullptr, nullptr,
                                             SolverKind::MultigridCG_Matfree);
    if (cg_last) *cg_last = c.cg.iterations;
    x = oc_update(S.grid, f, x, c.dcompliance, vf, 0.2, rho_min);
  }
  return f.filter_density(x);
}

// ---------------------------------------------------------------------------
// Element stiffness helper: K0 = hex8_stiffness(1, nu, h) as a 24x24 Eigen matrix.
// Modulus factor Efac(rho) = clamp(rho, rho_min, 1)^p  (Emax = 1 normalisation).
// ---------------------------------------------------------------------------
Eigen::Matrix<double, 24, 24> unit_k0() {
  const Hex8Stiffness k = hex8_stiffness(1.0, kNu, kH);
  Eigen::Matrix<double, 24, 24> K0;
  for (int r = 0; r < 24; ++r)
    for (int c = 0; c < 24; ++c) K0(r, c) = k(r, c);
  return K0;
}

inline double efac(double rho, double rho_min) {
  const double r = std::min(1.0, std::max(rho_min, rho));
  return r * r * r;  // p = 3
}

// ---------------------------------------------------------------------------
// A subdomain "core" element block, and its overlapping agglomerate (core grown by
// `ov` elements on each side, clamped to the grid).
// ---------------------------------------------------------------------------
struct Block { int x0, x1, y0, y1, z0, z1; };  // half-open element ranges

Block agglomerate(const Block& core, int ov, const VoxelGrid& g) {
  return Block{std::max(0, core.x0 - ov), std::min(g.nx, core.x1 + ov),
               std::max(0, core.y0 - ov), std::min(g.ny, core.y1 + ov),
               std::max(0, core.z0 - ov), std::min(g.nz, core.z1 + ov)};
}

// Per-subdomain measurement result.
struct SubResult {
  int ndof = 0;            // local free DOF (fixed DOFs eliminated)
  int nmodes = 0;          // #(lambda < threshold_ref)  (ref = kLambdaAL)
  int ncomp = 0;           // #(connected solid components), ligament proxy
  double solid_frac = 0;   // fraction of agglomerate elements with rho > 0.5
  bool solved = false;
  std::array<int, 8> thr_counts{};  // counts at the swept thresholds
  double lam6 = 0, lam7 = 0;        // 7th & 8th eigenvalue (first non-rigid gap)
};

const std::array<double, 8> kThresholds = {1e-5, 1e-4, kLambdaAL, 1e-3,
                                           3e-3, 1e-2, 3e-2, 1e-1};

// Assemble the local Neumann agglomerate matrix (global Dirichlet DOFs eliminated),
// solve the generalised eigenproblem (K, diag K), count modes below each threshold.
// `hard_void` (G4): treat elements with rho < void_cut as ABSENT (element removed,
// its otherwise-untouched DOFs dropped) instead of soft rho_min.
SubResult measure_subdomain(const VoxelGrid& g, const std::vector<double>& rho,
                            const Eigen::Matrix<double, 24, 24>& K0,
                            const std::vector<char>& fixed_dof_lut,  // by global dof
                            const Block& agg, double rho_min, int maxdof,
                            bool hard_void, double void_cut) {
  SubResult R;
  // First pass: count present elements and their solid flag.
  int solid_cnt = 0, elem_cnt = 0;
  for (int k = agg.z0; k < agg.z1; ++k)
    for (int j = agg.y0; j < agg.y1; ++j)
      for (int i = agg.x0; i < agg.x1; ++i) {
        const double r = rho[g.index(i, j, k)];
        if (hard_void && r < void_cut) continue;  // element absent
        ++elem_cnt;
        if (r > 0.5) ++solid_cnt;
      }
  R.solid_frac = elem_cnt ? static_cast<double>(solid_cnt) / elem_cnt : 0.0;

  // Build gdof->local map (non-fixed DOFs touched by present agglomerate elements).
  std::unordered_map<int, int> l;
  l.reserve(4096);
  auto touch_dof = [&](int gdof) {
    if (fixed_dof_lut[static_cast<std::size_t>(gdof)]) return;
    auto it = l.find(gdof);
    if (it == l.end()) l.emplace(gdof, static_cast<int>(l.size()));
  };
  for (int k = agg.z0; k < agg.z1; ++k)
    for (int j = agg.y0; j < agg.y1; ++j)
      for (int i = agg.x0; i < agg.x1; ++i) {
        const double r = rho[g.index(i, j, k)];
        if (hard_void && r < void_cut) continue;
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) touch_dof(3 * en[a] + c);
      }
  const int n = static_cast<int>(l.size());
  R.ndof = n;
  if (n == 0) { R.solved = true; return R; }
  if (n > maxdof) { R.solved = false; return R; }  // too big for dense; skip

  // Assemble dense local K.
  Eigen::MatrixXd K = Eigen::MatrixXd::Zero(n, n);
  for (int k = agg.z0; k < agg.z1; ++k)
    for (int j = agg.y0; j < agg.y1; ++j)
      for (int i = agg.x0; i < agg.x1; ++i) {
        const double r = rho[g.index(i, j, k)];
        if (hard_void && r < void_cut) continue;
        const double E = hard_void ? 1.0 : efac(r, rho_min);  // Emax=1 normalisation
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        int ld[24];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) {
            const int gd = 3 * en[a] + c;
            ld[3 * a + c] = fixed_dof_lut[static_cast<std::size_t>(gd)] ? -1 : l.at(gd);
          }
        for (int p = 0; p < 24; ++p) {
          if (ld[p] < 0) continue;
          for (int q = 0; q < 24; ++q) {
            if (ld[q] < 0) continue;
            K(ld[p], ld[q]) += E * K0(p, q);
          }
        }
      }

  // diag(K) weighting matrix (SPD: every local DOF is touched by >=1 element).
  Eigen::MatrixXd D = Eigen::MatrixXd::Zero(n, n);
  for (int a = 0; a < n; ++a) {
    double d = K(a, a);
    if (d <= 0) d = 1e-30;  // guard (should not happen)
    D(a, a) = d;
  }

  Eigen::GeneralizedSelfAdjointEigenSolver<Eigen::MatrixXd> ges(
      K, D, Eigen::EigenvaluesOnly | Eigen::Ax_lBx);
  if (ges.info() != Eigen::Success) { R.solved = false; return R; }
  const Eigen::VectorXd& ev = ges.eigenvalues();  // ascending
  R.solved = true;
  for (std::size_t t = 0; t < kThresholds.size(); ++t) {
    int cnt = 0;
    for (int a = 0; a < n; ++a) { if (ev(a) < kThresholds[t]) ++cnt; else break; }
    R.thr_counts[t] = cnt;
  }
  // Reference count at A&L threshold.
  R.nmodes = R.thr_counts[2];
  if (n > 6) R.lam6 = ev(6);
  if (n > 7) R.lam7 = ev(7);

  // Connected-component count of solid (rho>0.5) elements in the agglomerate
  // (6-connectivity), a ligament proxy.  Union-find over agglomerate elements.
  const int ax = agg.x1 - agg.x0, ay = agg.y1 - agg.y0, az = agg.z1 - agg.z0;
  const int na = ax * ay * az;
  std::vector<int> uf(na, -1);
  auto lin = [&](int i, int j, int k) { return (k * ay + j) * ax + i; };
  std::function<int(int)> find = [&](int a) {
    while (uf[a] >= 0) { if (uf[uf[a]] >= 0) uf[a] = uf[uf[a]]; a = uf[a]; }
    return a;
  };
  auto issolid = [&](int i, int j, int k) {
    const double r = rho[g.index(agg.x0 + i, agg.y0 + j, agg.z0 + k)];
    return r > 0.5;
  };
  for (int k = 0; k < az; ++k)
    for (int j = 0; j < ay; ++j)
      for (int i = 0; i < ax; ++i) {
        if (!issolid(i, j, k)) continue;
        const int a = lin(i, j, k);
        if (i + 1 < ax && issolid(i + 1, j, k)) {
          int ra = find(a), rb = find(lin(i + 1, j, k)); if (ra != rb) uf[ra] = rb;
        }
        if (j + 1 < ay && issolid(i, j + 1, k)) {
          int ra = find(a), rb = find(lin(i, j + 1, k)); if (ra != rb) uf[ra] = rb;
        }
        if (k + 1 < az && issolid(i, j, k + 1)) {
          int ra = find(a), rb = find(lin(i, j, k + 1)); if (ra != rb) uf[ra] = rb;
        }
      }
  int comps = 0;
  for (int k = 0; k < az; ++k)
    for (int j = 0; j < ay; ++j)
      for (int i = 0; i < ax; ++i)
        if (issolid(i, j, k) && find(lin(i, j, k)) == lin(i, j, k)) ++comps;
  R.ncomp = comps;
  return R;
}

// ---------------------------------------------------------------------------
// Tile a domain into cubic cores of `core` elements, measure every subdomain
// (parallel over subdomains with std::thread), aggregate.
// ---------------------------------------------------------------------------
struct DecompResult {
  int nsub = 0, nsub_solved = 0;
  long long Ntot = 0;                 // total coarse dim at A&L threshold
  std::array<long long, 8> Ntot_thr{};// per swept threshold
  long long fine_dof = 0;
  double basis_mb = 0, coarseop_mb = 0;
  int modes_min = 1 << 30, modes_max = 0;
  double modes_mean = 0;
  std::vector<int> modes_hist;        // per-subdomain nmodes (solved)
  std::vector<SubResult> subs;        // full per-subdomain records
  int core = 0, ov = 0;
};

std::vector<char> build_fixed_lut(const System& S) {
  const int nd = 3 * fea_node_count(S.grid);
  std::vector<char> lut(static_cast<std::size_t>(nd), 0);
  for (const auto& b : S.bcs) lut[static_cast<std::size_t>(3 * b.node + b.component)] = 1;
  return lut;
}

DecompResult run_decomp(const System& S, const std::vector<double>& rho, int core,
                        int ov, double rho_min, int maxdof, bool hard_void,
                        double void_cut) {
  const VoxelGrid& g = S.grid;
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  const std::vector<char> fixed = build_fixed_lut(S);

  std::vector<Block> cores;
  for (int z = 0; z < g.nz; z += core)
    for (int y = 0; y < g.ny; y += core)
      for (int x = 0; x < g.nx; x += core)
        cores.push_back(Block{x, std::min(g.nx, x + core), y, std::min(g.ny, y + core),
                              z, std::min(g.nz, z + core)});

  DecompResult D;
  D.core = core; D.ov = ov;
  D.nsub = static_cast<int>(cores.size());
  D.subs.resize(cores.size());
  D.fine_dof = 3LL * fea_node_count(g);

  std::atomic<int> next{0};
  const unsigned nthreads = std::max(1u, std::thread::hardware_concurrency());
  auto worker = [&]() {
    for (;;) {
      const int idx = next.fetch_add(1);
      if (idx >= static_cast<int>(cores.size())) break;
      const Block agg = agglomerate(cores[static_cast<std::size_t>(idx)], ov, g);
      D.subs[static_cast<std::size_t>(idx)] =
          measure_subdomain(g, rho, K0, fixed, agg, rho_min, maxdof, hard_void, void_cut);
    }
  };
  std::vector<std::thread> pool;
  for (unsigned t = 0; t < nthreads; ++t) pool.emplace_back(worker);
  for (auto& th : pool) th.join();

  double basis_dofs = 0;
  long long sum_dof_solved = 0;
  for (const auto& r : D.subs) {
    if (!r.solved || r.ndof == 0) continue;
    ++D.nsub_solved;
    D.Ntot += r.nmodes;
    for (std::size_t t = 0; t < kThresholds.size(); ++t) D.Ntot_thr[t] += r.thr_counts[t];
    basis_dofs += static_cast<double>(r.nmodes) * r.ndof;  // one coarse vec ~ agglo DOF
    sum_dof_solved += r.ndof;
    D.modes_min = std::min(D.modes_min, r.nmodes);
    D.modes_max = std::max(D.modes_max, r.nmodes);
    D.modes_hist.push_back(r.nmodes);
    D.modes_mean += r.nmodes;
  }
  if (!D.modes_hist.empty()) D.modes_mean /= static_cast<double>(D.modes_hist.size());
  else D.modes_min = 0;
  // Basis storage (double): sum over coarse vectors of their agglomerate DOF support.
  D.basis_mb = basis_dofs * 8.0 / (1024.0 * 1024.0);
  // Coarse operator K_c = R_c K R_c^T is N_t x N_t; dense upper bound (it is sparse,
  // ~neighbour-agglomerate band, so this is an overestimate — reported as a ceiling).
  D.coarseop_mb =
      static_cast<double>(D.Ntot) * static_cast<double>(D.Ntot) * 8.0 / (1024.0 * 1024.0);
  return D;
}

int median(std::vector<int> v) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

// ---------------------------------------------------------------------------
// SELF-CHECK — the bar before any measurement.
// ---------------------------------------------------------------------------
int selfcheck() {
  std::printf("=== SELF-CHECK (bar: uniform block -> exactly 6 rigid-body modes; "
              "count invariant to global E scale) ===\n");
  const int nx = 8, ny = 8, nz = 8;
  System S = build_cantilever(nx, ny, nz);  // BCs unused here; we pass empty fixed
  // Free (no Dirichlet) uniform blocks so the pure rigid-body nullspace is visible.
  System F = S; F.bcs.clear();
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  const std::vector<char> fixed = build_fixed_lut(F);
  const Block agg{0, nx, 0, ny, 0, nz};

  auto run = [&](const std::vector<double>& rho, double rho_min) {
    return measure_subdomain(F.grid, rho, K0, fixed, agg, rho_min, 100000, false, 0.1);
  };

  int fail = 0;
  // (1) uniform solid rho=1
  {
    std::vector<double> rho(F.grid.voxel_count(), 1.0);
    SubResult r = run(rho, kRhoMinProd);
    const int m = r.thr_counts[2];  // A&L threshold
    std::printf("  uniform solid   : ndof=%d modes<lamAL=%d  lam[6]=%.3e lam[7]=%.3e  "
                "%s\n", r.ndof, m, r.lam6, r.lam7, m == 6 ? "PASS(6)" : "FAIL");
    if (m != 6) ++fail;
  }
  // (2) uniform soft rho=rho_min (pure scale of the solid block -> still 6)
  {
    std::vector<double> rho(F.grid.voxel_count(), kRhoMinProd);
    SubResult r = run(rho, kRhoMinProd);
    const int m = r.thr_counts[2];
    std::printf("  uniform soft    : ndof=%d modes<lamAL=%d  %s\n", r.ndof, m,
                m == 6 ? "PASS(6)" : "FAIL");
    if (m != 6) ++fail;
  }
  // (3) global E-scale invariance: rho=0.5 everywhere vs rho=1 -> same normalized
  //     spectrum (both uniform) -> both 6.
  {
    std::vector<double> rho(F.grid.voxel_count(), 0.5);
    SubResult r = run(rho, kRhoMinProd);
    const int m = r.thr_counts[2];
    std::printf("  uniform rho=0.5 : ndof=%d modes<lamAL=%d  %s\n", r.ndof, m,
                m == 6 ? "PASS(6)" : "FAIL");
    if (m != 6) ++fail;
  }
  // (4) high-contrast: TWO disjoint solid cubes weakly coupled through 1e-9 soft
  //     material -> two near-rigid bodies -> ~12 near-null modes (6 global rigid +
  //     6 relative), i.e. the contrast-induced extra modes GenEO must capture.
  {
    std::vector<double> rho(F.grid.voxel_count(), kRhoMinProd);
    for (int k = 0; k < 3; ++k)
      for (int j = 0; j < 3; ++j)
        for (int i = 0; i < 3; ++i) {
          rho[F.grid.index(i, j, k)] = 1.0;                       // corner cube A
          rho[F.grid.index(nx - 1 - i, ny - 1 - j, nz - 1 - k)] = 1.0;  // cube B
        }
    SubResult r = run(rho, kRhoMinProd);
    const int m = r.thr_counts[2];
    std::printf("  two-inclusion   : ndof=%d modes<lamAL=%d (expect ~12) ncomp=%d "
                "lam[6]=%.2e lam[7]=%.2e  %s\n", r.ndof, m, r.ncomp, r.lam6, r.lam7,
                m >= 11 ? "PASS(>=11)" : "FAIL");
    if (m < 11) ++fail;
  }
  std::printf("SELF-CHECK: %s\n\n", fail == 0 ? "ALL PASS" : "FAILURES PRESENT");
  return fail;
}

// ---------------------------------------------------------------------------
void print_decomp(const char* tag, const System& S, double rung, double rho_min,
                  const DecompResult& D, std::FILE* summ) {
  const double contrast = 1.0 / (rho_min * rho_min * rho_min);
  const int med = median(D.modes_hist);
  const double fracfine =
      D.fine_dof ? 100.0 * static_cast<double>(D.Ntot) / static_cast<double>(D.fine_dof) : 0;
  // Extrapolation to the real 8.44M-DOF run at THIS subdomain size:
  const double avg_sub_dof =
      D.nsub_solved ? static_cast<double>(D.fine_dof) / D.nsub_solved : 0;  // ~fine/nsub
  const double modes_per_sub = D.nsub_solved ? static_cast<double>(D.Ntot) / D.nsub_solved : 0;
  const double subs_at_8M = 8.44e6 / std::max(1.0, avg_sub_dof);
  const long long Nt_8M = static_cast<long long>(modes_per_sub * subs_at_8M);
  const double basis_mb_8M =
      D.nsub_solved ? D.basis_mb * subs_at_8M / D.nsub_solved : 0;

  std::printf("[%s] %s rung=%.2f contrast=%.0e core=%d ov=%d : nsub=%d(solved %d) "
              "Ntot=%lld (%.2f%% of fine %lld)  modes/sub[min/med/max]=%d/%d/%d "
              "basis=%.1fMB coarseOpCeil=%.1fMB | 8.44M-DOF proj: Nt~%lld basis~%.0fMB\n",
              tag, S.name.c_str(), rung, contrast, D.core, D.ov, D.nsub, D.nsub_solved,
              D.Ntot, fracfine, D.fine_dof, D.modes_min, med, D.modes_max, D.basis_mb,
              D.coarseop_mb, Nt_8M, basis_mb_8M);
  if (summ) {
    std::fprintf(summ,
                 "%s,%s,%.2f,%.0e,%d,%d,%d,%d,%lld,%.4f,%d,%d,%d,%.3f,%.3f,%lld,%.1f,%.1f\n",
                 tag, S.name.c_str(), rung, contrast, D.core, D.ov, D.nsub, D.nsub_solved,
                 D.Ntot, fracfine, D.modes_min, med, D.modes_max, D.basis_mb, D.coarseop_mb,
                 Nt_8M, basis_mb_8M, modes_per_sub);
    std::fflush(summ);
  }
}

void dump_subs(std::FILE* f, const char* tag, const System& S, double rung,
               double rho_min, const DecompResult& D) {
  if (!f) return;
  const double contrast = 1.0 / (rho_min * rho_min * rho_min);
  for (std::size_t i = 0; i < D.subs.size(); ++i) {
    const SubResult& r = D.subs[i];
    std::fprintf(f, "%s,%s,%.2f,%.0e,%d,%d,%d,%d,%d,%d,%.3f,%.4e,%.4e\n", tag,
                 S.name.c_str(), rung, contrast, D.core, static_cast<int>(i), r.ndof,
                 r.solved ? 1 : 0, r.nmodes, r.ncomp, r.solid_frac, r.lam6, r.lam7);
  }
  std::fflush(f);
}

// ---------------------------------------------------------------------------
int measure(const std::string& csvdir) {
  std::FILE* summ = std::fopen((csvdir + "/coarse_size_summary.csv").c_str(), "w");
  std::FILE* subs = std::fopen((csvdir + "/subdomain_detail.csv").c_str(), "w");
  std::FILE* thr = std::fopen((csvdir + "/threshold_sweep.csv").c_str(), "w");
  if (summ)
    std::fprintf(summ, "tag,fixture,rung,contrast,core,ov,nsub,nsub_solved,Ntot,frac_fine_pct,"
                       "modes_min,modes_med,modes_max,basis_MB,coarseOpCeil_MB,Nt_8M,basis_MB_8M,"
                       "modes_per_sub\n");
  if (subs)
    std::fprintf(subs, "tag,fixture,rung,contrast,core,sub,ndof,solved,nmodes,ncomp,"
                       "solid_frac,lam6,lam7\n");
  if (thr)
    std::fprintf(thr, "tag,fixture,rung,contrast,core,threshold,Ntot\n");

  const int maxdof = 12000;       // dense EigenvaluesOnly cap
  const int dev_iters = 40;       // OC iterations (production recipe uses 40)

  // ---- Primary fixture: domain-filling cantilever, all four ladder rungs -----
  System cant = build_cantilever(48, 24, 48);
  std::printf("\n## Primary fixture: %s %dx%dx%d, fine DOF=%d, developing %d OC iters/rung\n",
              cant.name.c_str(), cant.grid.nx, cant.grid.ny, cant.grid.nz,
              3 * fea_node_count(cant.grid), dev_iters);

  for (double rung : kLadder) {
    int cg = 0;
    std::vector<double> rho = develop_field(cant, rung, dev_iters, kRhoMinProd, &cg);
    // Headline decomposition: core=8, ov=1, contrast 1e9, whole domain tiled.
    DecompResult D = run_decomp(cant, rho, 8, 1, kRhoMinProd, maxdof, false, 0.1);
    print_decomp("G1", cant, rung, kRhoMinProd, D, summ);
    dump_subs(subs, "G1", cant, rung, kRhoMinProd, D);
    if (thr)
      for (std::size_t t = 0; t < kThresholds.size(); ++t)
        std::fprintf(thr, "G1,%s,%.2f,1e+09,8,%.1e,%lld\n", cant.name.c_str(), rung,
                     kThresholds[t], D.Ntot_thr[t]);
    std::fflush(stdout);
  }

  // ---- Decomposition sweep (subdomain-size dependence) on the densest rung -----
  std::printf("\n## Decomposition (subdomain-size) sweep on rung 0.68, contrast 1e9\n");
  {
    int cg = 0;
    std::vector<double> rho = develop_field(cant, 0.68, dev_iters, kRhoMinProd, &cg);
    for (int core : {6, 8, 10, 12}) {
      DecompResult D = run_decomp(cant, rho, core, 1, kRhoMinProd, maxdof, false, 0.1);
      print_decomp("DECOMP", cant, 0.68, kRhoMinProd, D, summ);
    }
  }

  // ---- Contrast sweep (gap a): rho_min 1e-3 (1e9) vs 1e-2 (1e6) on rung 0.52 -----
  std::printf("\n## Contrast sweep on rung 0.52, core=8 (gap a: 1e6 vs 1e9)\n");
  for (double rmin : {1e-3, 1e-2}) {
    int cg = 0;
    std::vector<double> rho = develop_field(cant, 0.52, dev_iters, rmin, &cg);
    DecompResult D = run_decomp(cant, rho, 8, 1, rmin, maxdof, false, 0.1);
    print_decomp("CONTRAST", cant, 0.52, rmin, D, summ);
  }

  // ---- G4: void elimination + raised rho_min on rung 0.38, core=8 --------------
  std::printf("\n## G4: soft-void(1e9) vs void-ELIMINATED vs raised rho_min(1e6), rung 0.38\n");
  {
    int cg = 0;
    std::vector<double> rho = develop_field(cant, 0.38, dev_iters, kRhoMinProd, &cg);
    DecompResult soft = run_decomp(cant, rho, 8, 1, kRhoMinProd, maxdof, false, 0.1);
    print_decomp("G4soft", cant, 0.38, kRhoMinProd, soft, summ);
    DecompResult cut = run_decomp(cant, rho, 8, 1, kRhoMinProd, maxdof, true, 0.1);
    print_decomp("G4voidcut", cant, 0.38, kRhoMinProd, cut, summ);  // rho<0.1 removed
    // raised floor: re-develop at rho_min 1e-2 then measure soft at 1e6
    std::vector<double> rho2 = develop_field(cant, 0.38, dev_iters, 1e-2, &cg);
    DecompResult hi = run_decomp(cant, rho2, 8, 1, 1e-2, maxdof, false, 0.1);
    print_decomp("G4rhomin", cant, 0.38, 1e-2, hi, summ);
  }

  // ---- Secondary fixture: the committed ultra-dilute L-bracket, rung 0.26 & 0.68 -
  System ud = build_ultradilute();
  std::printf("\n## Secondary fixture: %s 48x32x48 (part_frac=%.3f), rungs 0.68 & 0.26\n",
              ud.name.c_str(), ud.part_fraction);
  for (double rung : {0.68, 0.26}) {
    int cg = 0;
    std::vector<double> rho = develop_field(ud, rung, dev_iters, kRhoMinProd, &cg);
    DecompResult D = run_decomp(ud, rho, 8, 1, kRhoMinProd, maxdof, false, 0.1);
    print_decomp("DILUTE", ud, rung, kRhoMinProd, D, summ);
    dump_subs(subs, "DILUTE", ud, rung, kRhoMinProd, D);
  }

  if (summ) std::fclose(summ);
  if (subs) std::fclose(subs);
  if (thr) std::fclose(thr);
  std::printf("\nCSVs written to %s\n", csvdir.c_str());
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "all";
  const std::string csvdir = argc > 2 ? argv[2] : ".";
  if (mode == "selfcheck") return selfcheck();
  if (mode == "measure") return measure(csvdir);
  if (mode == "all") {
    if (selfcheck() != 0) {
      std::printf("SELF-CHECK FAILED — aborting before measurement.\n");
      return 1;
    }
    return measure(csvdir);
  }
  std::printf("usage: %s [selfcheck|measure|all] [csvdir]\n", argv[0]);
  return 2;
}
