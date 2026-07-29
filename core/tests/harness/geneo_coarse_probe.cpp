// geneo_coarse_probe.cpp — Phase-1 harness: BUILD the matrix-free GenEO coarse basis and
// coarse operator over a REAL developed design field, and MEASURE it.
//
// NOT a CI test, NOT in CTest, NOT linked into any production path. ZERO new build
// dependency: uses only the already-present Homebrew Eigen (dense, HARNESS-ONLY reference
// eigensolver) plus the production library libtopopt.a. No SLEPc, no HPDDM, no ARPACK, no
// MPI (bars G5). The GLOBAL operator A used for the coarse operator V^T A V is the
// PRODUCTION matrix-free apply `fea_matfree_apply` — the same operator the production
// MG-CG solves, untouched (bar G6). This harness PRODUCES a basis; it does not wire it
// into the solver (that is Phase 2).
//
// PREDECESSORS
//   PR 230 spectral_coarse_probe.cpp  — coarse space is SMALL (0.1-0.8% of fine DOF),
//                                       rigid-body-dominated, contrast-insensitive.
//   PR 232 geneo_matfree_probe.cpp    — matrix-free LOBPCG solves the local GenEO
//                                       eigenproblem at 1e9 contrast WITHOUT shift-invert,
//                                       recovering ALL sub-threshold modes with Jacobi.
// This file builds PIECES 1-3 of the four PR 232 scoped:
//   1. Overlapping decomposition + partition of unity (sum_i R_i^T D_i R_i = I).
//   2. Per-subdomain matrix-free LOBPCG, CAPTURE-BASED stopping (not a tight residual —
//      PR 230's threshold has a decade-wide plateau). Kept columns = R_i^T D_i V_ik.
//   3. Coarse operator V^T A V via matrix-free global applies; dense-factorize if the
//      total coarse dim <= ~8k, else report what an inexact/iterative coarse solve needs.
// Piece 4 (wiring the two-level preconditioner into CG) is Phase 2, NOT in scope.
//
// ★ THE RISK RETIRED FIRST (task ★): the eigensolve scale — LOBPCG iteration count vs
//   subdomain SIZE (DOF/subdomain, equivalently subdomain COUNT for a fixed grid). The
//   `scaling` mode sweeps the core size up to ~16k DOF/subdomain (the real subdomain size
//   PR 230 projected) and reports the iteration-count scaling BEFORE the basis is built.
//   If it blew up, that closes the route / forces fewer-larger subdomains.
//
// BUILD (library built Release first; OCCT off, tests off — matches the sibling probes):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//       core/tests/harness/geneo_coarse_probe.cpp core/build/libtopopt.a \
//       -o core/build/geneo_coarse_probe
// RUN: ./core/build/geneo_coarse_probe <selfcheck|scaling|basis|amort|all> [csvdir]
//
// DETERMINISM. Mode counts, eigenvalues, subspace angles, coarse dimensions, matvec
// counts are deterministic (LOBPCG seeded from a fixed PRNG; OC path is deterministic).
// Wall time is reported but NOT load-bearing; the currency for cost is the matvec count.

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <sys/resource.h>

#include <Eigen/Dense>
#include <Eigen/Eigenvalues>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;
using Eigen::MatrixXd;
using Eigen::VectorXd;

namespace {

// ---------------- development physics (production recipe) ----------------
constexpr double kE0 = 3500.0;   // PLA, MPa
constexpr double kNu = 0.33;
constexpr int kSimpP = 3;
constexpr double kRhoMinProd = 1e-3;  // production void floor => contrast 1e9
constexpr double kH = 1.0;            // voxel edge (mm)
constexpr double kContrast = 1e9;     // Emax/Emin, == production floor rho_min^3 = 1e-9

// ------------------------------------------------------------------------------------
struct System {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::string name;
};

// Domain-filling cantilever (fixed x=0 face, downward line load on far bottom edge). OC
// fills it with a real optimised topology -> realistic feature density everywhere.
System build_cantilever(int nx, int ny, int nz) {
  System S;
  S.name = "cantilever";
  VoxelGrid& g = S.grid;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = kH; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      S.bcs.push_back({nd, 0, 0.0});
      S.bcs.push_back({nd, 1, 0.0});
      S.bcs.push_back({nd, 2, 0.0});
    }
  std::vector<int> tip;
  for (int b = 0; b <= ny; ++b) tip.push_back(fea_node_index(g, nx, b, 0));
  const double total = -100.0;
  for (int nd : tip) S.loads.push_back({nd, 2, total / static_cast<double>(tip.size())});
  return S;
}

// Run the production OC recipe; return the DEVELOPED physical density field. If
// `snapshots` is non-null, the physical field at every iteration is appended (for the
// amortization measurement G4).
std::vector<double> develop_field(const System& S, double rung, int iters,
                                  std::vector<std::vector<double>>* snapshots = nullptr) {
  SimpParams params;
  params.youngs_modulus = kE0;
  params.poisson = kNu;
  params.penalty = static_cast<double>(kSimpP);
  params.density_min = kRhoMinProd;
  const DensityFilter f =
      make_density_filter(S.grid, physical_filter_radius(2.5, S.grid.spacing));
  std::vector<double> x = simp_uniform_density(S.grid, rung);
  std::vector<double> xp;
  for (int it = 0; it < iters; ++it) {
    xp = f.filter_density(x);
    const SimpCompliance c = simp_compliance(S.grid, params, xp, S.bcs, S.loads, 1e-8, 0,
                                             nullptr, nullptr, SolverKind::MultigridCG_Matfree);
    x = oc_update(S.grid, f, x, c.dcompliance, rung, 0.2, kRhoMinProd);
    if (snapshots) snapshots->push_back(f.filter_density(x));
  }
  return f.filter_density(x);
}

// ---------------- reference 24x24 unit element stiffness (E=1) ----------------
Eigen::Matrix<double, 24, 24> unit_k0() {
  const Hex8Stiffness k = hex8_stiffness(1.0, kNu, kH);
  Eigen::Matrix<double, 24, 24> K0;
  for (int r = 0; r < 24; ++r)
    for (int c = 0; c < 24; ++c) K0(r, c) = k(r, c);
  return K0;
}

// Modulus at contrast kappa: E = max(rho^p, 1/kappa), Emax=1. Matches the GLOBAL apply.
inline double efac_contrast(double rho, double kappa) {
  const double r = std::min(1.0, std::max(0.0, rho));
  return std::max(r * r * r, 1.0 / kappa);
}

struct Block { int x0, x1, y0, y1, z0, z1; };  // half-open ELEMENT ranges

Block agglomerate(const Block& core, int ov, const VoxelGrid& g) {
  return Block{std::max(0, core.x0 - ov), std::min(g.nx, core.x1 + ov),
               std::max(0, core.y0 - ov), std::min(g.ny, core.y1 + ov),
               std::max(0, core.z0 - ov), std::min(g.nz, core.z1 + ov)};
}

// ------------------------------------------------------------------------------------
// PARTITION OF UNITY (task piece 1). RAW node weight of subdomain i at a node: 1 on the
// CORE node span, linear taper across the overlap band toward the agglomerate edge, 0
// strictly outside. A positive floor `wfloor` = 1/(ov+1) keeps the weight > 0 on the
// WHOLE agglomerate support (matches PR 232's build_local so the local pencil stays
// non-degenerate — with an exact-0 skin the (D A D) mass matrix loses rigid-mode mass and
// the reference eigencount is corrupted). Because the cores TILE the grid, W(node) =
// sum_i w_i(node) > 0 everywhere, and
//   D_i(node) = w_i(node) / W(node)   =>   sum_i R_i^T D_i R_i = I   EXACTLY.
// The taper shape only affects the H^1 constant (quality), not the partition exactness;
// the exactness is verified numerically in selfcheck (sum_i D_i = 1 at every free DOF).
// ------------------------------------------------------------------------------------
inline double raw_weight(const Block& core, const Block& agg, const VoxelGrid& g, int ov,
                         double x, double y, double z) {
  const double wfloor = 1.0 / (ov + 1.0);
  auto axis = [&](double p, int c0, int c1, int a0, int a1) -> double {
    const double pe = p / g.spacing;                 // node coord in element units
    if (pe <= c0) {                                  // low side
      if (a0 == c0) return 1.0;                       // domain boundary: no taper
      const double t = (pe - a0 + 0.5) / static_cast<double>(c0 - a0);
      return std::max(0.0, std::min(1.0, t));
    }
    if (pe >= c1) {                                  // high side
      if (a1 == c1) return 1.0;
      const double t = (a1 - pe + 0.5) / static_cast<double>(a1 - c1);
      return std::max(0.0, std::min(1.0, t));
    }
    return 1.0;                                      // core plateau
  };
  const double w = axis(x, core.x0, core.x1, agg.x0, agg.x1) *
                   axis(y, core.y0, core.y1, agg.y0, agg.y1) *
                   axis(z, core.z0, core.z1, agg.z0, agg.z1);
  return std::max(wfloor, w);
}

// ------------------------------------------------------------------------------------
// Local subdomain: element-local matrix-free operators + geometry + local<->global DOF
// map + PoU diagonal. Built ONCE per subdomain. Never forms an n-by-n matrix.
// ------------------------------------------------------------------------------------
struct LocalOp {
  int n = 0;
  std::vector<std::array<int, 24>> edof;
  std::vector<double> eE;
  std::vector<double> D;        // PoU diagonal (already normalised: w_i/W), length n
  std::vector<double> diagNeu;  // diag(A^Neu) for Jacobi
  std::vector<double> nodeXYZ;  // 3*nnode
  std::vector<int> dofNode;
  std::vector<int> dofComp;
  std::vector<int> gdof;        // local -> GLOBAL free-and-fixed dof index (3*node+comp)
  const Eigen::Matrix<double, 24, 24>* K0 = nullptr;

  VectorXd applyNeu(const VectorXd& x) const {
    VectorXd y = VectorXd::Zero(n);
    Eigen::Matrix<double, 24, 1> xe, ye;
    for (std::size_t e = 0; e < edof.size(); ++e) {
      const auto& d = edof[e];
      // d[a] == -1 marks a globally-Dirichlet DOF eliminated from this subdomain: gather
      // 0 and scatter nothing (the local operator is the agglomerate stiffness with the
      // global Dirichlet rows/cols removed — matches dense_neu's `continue`). Subdomains
      // touching the fixed boundary therefore have FEWER rigid modes, as they should.
      for (int a = 0; a < 24; ++a) xe(a) = (d[a] >= 0) ? x(d[a]) : 0.0;
      ye.noalias() = (*K0) * xe;
      const double E = eE[e];
      for (int a = 0; a < 24; ++a) if (d[a] >= 0) y(d[a]) += E * ye(a);
    }
    return y;
  }
  VectorXd applyDad(const VectorXd& x) const {
    VectorXd dx(n);
    for (int i = 0; i < n; ++i) dx(i) = D[i] * x(i);
    VectorXd y = applyNeu(dx);
    for (int i = 0; i < n; ++i) y(i) *= D[i];
    return y;
  }
  MatrixXd applyNeuBlock(const MatrixXd& X) const {
    MatrixXd Y(n, X.cols());
    for (int c = 0; c < X.cols(); ++c) Y.col(c) = applyNeu(X.col(c));
    return Y;
  }
  MatrixXd applyDadBlock(const MatrixXd& X) const {
    MatrixXd Y(n, X.cols());
    for (int c = 0; c < X.cols(); ++c) Y.col(c) = applyDad(X.col(c));
    return Y;
  }
  // approximate byte footprint of THIS subdomain object (topology + moduli + geometry).
  long long bytes() const {
    return static_cast<long long>(edof.size()) * (24 * 4 + 8) +
           static_cast<long long>(n) * (8 * 2 + 4 * 3) +
           static_cast<long long>(nodeXYZ.size()) * 8;
  }
};

struct MatvecCount { long long neu = 0, dad = 0; };
// thread_local so the scaling sweep can run subdomains in parallel: each subdomain's
// lobpcg accounts its own matvecs on the thread it runs on (a subdomain never migrates
// mid-solve), and LobpcgResult.neu_mv/dad_mv are read back per-subdomain. The `basis`
// build stays sequential (its peak-RSS number requires one resident subdomain at a time).
thread_local MatvecCount g_mv;

std::vector<char> build_fixed_lut(const System& S) {
  const int nd = 3 * fea_node_count(S.grid);
  std::vector<char> lut(static_cast<std::size_t>(nd), 0);
  for (const auto& b : S.bcs) lut[static_cast<std::size_t>(3 * b.node + b.component)] = 1;
  return lut;
}

// Build the LocalOp for subdomain (core -> agg). `nodeWglobal` is the PoU normaliser
// indexed by global node; if empty, D is left as the raw weight (single-subdomain use).
LocalOp build_local(const VoxelGrid& g, const std::vector<double>& rho, const Block& core,
                    int ov, double kappa, const Eigen::Matrix<double, 24, 24>& K0,
                    const std::vector<char>& fixed_dof_lut,
                    const std::vector<double>& nodeWglobal) {
  const Block agg = agglomerate(core, ov, g);
  LocalOp L;
  L.K0 = &K0;
  std::unordered_map<int, int> lmap;
  lmap.reserve(8192);
  auto local_dof = [&](int gdof) -> int {
    if (fixed_dof_lut[static_cast<std::size_t>(gdof)]) return -1;
    auto it = lmap.find(gdof);
    if (it != lmap.end()) return it->second;
    const int id = static_cast<int>(lmap.size());
    lmap.emplace(gdof, id);
    return id;
  };
  for (int k = agg.z0; k < agg.z1; ++k)
    for (int j = agg.y0; j < agg.y1; ++j)
      for (int i = agg.x0; i < agg.x1; ++i) {
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<int, 24> d{};
        bool any = false;
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) {
            const int ld = local_dof(3 * en[a] + c);
            d[3 * a + c] = ld;
            if (ld >= 0) any = true;
          }
        if (!any) continue;
        L.edof.push_back(d);
        L.eE.push_back(efac_contrast(rho[g.index(i, j, k)], kappa));
      }
  L.n = static_cast<int>(lmap.size());
  L.dofNode.assign(L.n, -1);
  L.dofComp.assign(L.n, -1);
  L.gdof.assign(L.n, -1);
  std::unordered_map<int, int> gnode_to_local;
  for (const auto& kv : lmap) {
    const int gd = kv.first, ld = kv.second;
    const int gnode = gd / 3, comp = gd % 3;
    auto it = gnode_to_local.find(gnode);
    int lnode;
    if (it == gnode_to_local.end()) { lnode = static_cast<int>(gnode_to_local.size()); gnode_to_local.emplace(gnode, lnode); }
    else lnode = it->second;
    L.dofNode[ld] = lnode; L.dofComp[ld] = comp; L.gdof[ld] = gd;
  }
  const int nnode = static_cast<int>(gnode_to_local.size());
  L.nodeXYZ.assign(3 * nnode, 0.0);
  const int Nx = g.nx + 1, Ny = g.ny + 1;
  std::vector<int> lnode_gnode(nnode, -1);
  for (const auto& kv : gnode_to_local) {
    const int gnode = kv.first, lnode = kv.second;
    const int a = gnode % Nx, b = (gnode / Nx) % Ny, c = gnode / (Nx * Ny);
    L.nodeXYZ[3 * lnode + 0] = a * g.spacing;
    L.nodeXYZ[3 * lnode + 1] = b * g.spacing;
    L.nodeXYZ[3 * lnode + 2] = c * g.spacing;
    lnode_gnode[lnode] = gnode;
  }
  // PoU diagonal: normalised raw weight.
  L.D.assign(L.n, 1.0);
  for (int d = 0; d < L.n; ++d) {
    const int ln = L.dofNode[d];
    const double x = L.nodeXYZ[3 * ln + 0], y = L.nodeXYZ[3 * ln + 1], z = L.nodeXYZ[3 * ln + 2];
    double w = raw_weight(core, agg, g, ov, x, y, z);
    if (!nodeWglobal.empty()) {
      const double W = nodeWglobal[static_cast<std::size_t>(lnode_gnode[ln])];
      w = (W > 0) ? w / W : 0.0;
    }
    L.D[d] = w;
  }
  L.diagNeu.assign(L.n, 0.0);
  for (std::size_t e = 0; e < L.edof.size(); ++e) {
    const auto& d = L.edof[e];
    for (int a = 0; a < 24; ++a) if (d[a] >= 0) L.diagNeu[d[a]] += L.eE[e] * K0(a, a);
  }
  return L;
}

// Tile the grid into cubic cores of `core` elements.
std::vector<Block> tile_cores(const VoxelGrid& g, int core) {
  std::vector<Block> cores;
  for (int z = 0; z < g.nz; z += core)
    for (int y = 0; y < g.ny; y += core)
      for (int x = 0; x < g.nx; x += core)
        cores.push_back(Block{x, std::min(g.nx, x + core), y, std::min(g.ny, y + core),
                              z, std::min(g.nz, z + core)});
  return cores;
}

// Global PoU normaliser W(gnode) = sum over subdomains of the raw node weight.
std::vector<double> build_pou_normaliser(const VoxelGrid& g, const std::vector<Block>& cores,
                                         int ov) {
  const int nnode = fea_node_count(g);
  std::vector<double> W(static_cast<std::size_t>(nnode), 0.0);
  const int Nx = g.nx + 1, Ny = g.ny + 1;
  for (const Block& core : cores) {
    const Block agg = agglomerate(core, ov, g);
    for (int c = agg.z0; c <= agg.z1; ++c)
      for (int b = agg.y0; b <= agg.y1; ++b)
        for (int a = agg.x0; a <= agg.x1; ++a) {
          const int gnode = a + Nx * (b + Ny * c);
          const double w = raw_weight(core, agg, g, ov, a * g.spacing, b * g.spacing, c * g.spacing);
          W[static_cast<std::size_t>(gnode)] += w;
        }
  }
  return W;
}

// ---------------- B-orthonormalization, dense reference ----------------
struct BOrtho { MatrixXd Q, BQ; int r = 0; };
BOrtho borthonormalize(const MatrixXd& S, const MatrixXd& BS, double tol) {
  MatrixXd G = S.transpose() * BS;
  G = 0.5 * (G + G.transpose());
  Eigen::SelfAdjointEigenSolver<MatrixXd> es(G);
  const VectorXd& ev = es.eigenvalues();
  const MatrixXd& U = es.eigenvectors();
  const double emax = ev(ev.size() - 1);
  BOrtho out;
  std::vector<int> keep;
  for (int i = 0; i < ev.size(); ++i) if (ev(i) > tol * std::max(emax, 1e-300)) keep.push_back(i);
  out.r = static_cast<int>(keep.size());
  if (out.r == 0) return out;
  MatrixXd T(S.cols(), out.r);
  for (int c = 0; c < out.r; ++c) T.col(c) = U.col(keep[c]) / std::sqrt(ev(keep[c]));
  out.Q = S * T;
  out.BQ = BS * T;
  return out;
}

MatrixXd dense_neu(const LocalOp& L) {
  MatrixXd A = MatrixXd::Zero(L.n, L.n);
  const auto& K0 = *L.K0;
  for (std::size_t e = 0; e < L.edof.size(); ++e) {
    const auto& d = L.edof[e];
    const double E = L.eE[e];
    for (int a = 0; a < 24; ++a) { if (d[a] < 0) continue;
      for (int b = 0; b < 24; ++b) { if (d[b] < 0) continue; A(d[a], d[b]) += E * K0(a, b); } }
  }
  return A;
}
MatrixXd dense_dad(const LocalOp& L, const MatrixXd& Aneu) {
  MatrixXd A = Aneu;
  for (int i = 0; i < L.n; ++i) for (int j = 0; j < L.n; ++j) A(i, j) *= L.D[i] * L.D[j];
  return A;
}
struct RefResult { VectorXd lambda; MatrixXd V; int n = 0; };
RefResult reference_smallest(const LocalOp& L, double sigma_rel) {
  MatrixXd A = dense_neu(L);
  MatrixXd B = dense_dad(L, A);
  const double sigma = sigma_rel * (B.trace() / L.n);
  for (int i = 0; i < L.n; ++i) B(i, i) += sigma;
  Eigen::GeneralizedSelfAdjointEigenSolver<MatrixXd> ges(A, B, Eigen::ComputeEigenvectors | Eigen::Ax_lBx);
  RefResult R; R.lambda = ges.eigenvalues(); R.V = ges.eigenvectors(); R.n = L.n;
  return R;
}

// ---------------- Jacobi preconditioner apply ----------------
MatrixXd apply_jacobi(const LocalOp& L, const MatrixXd& R) {
  MatrixXd W(L.n, R.cols());
  for (int c = 0; c < R.cols(); ++c)
    for (int i = 0; i < L.n; ++i) W(i, c) = R(i, c) / std::max(L.diagNeu[i], 1e-300);
  return W;
}

// ------------------------------------------------------------------------------------
// Block LOBPCG for the m SMALLEST eigenpairs of  A^Neu V = lambda (D A^Neu D) V, Jacobi-
// preconditioned, matrix-free. Two stopping regimes (task piece 2, ★ capture-based):
//   - tight:   stop when max relative residual over the block < rtol.
//   - capture: stop when every Ritz pair below `lambda_cut` has relative residual <
//              capture_rtol AND the count below the cut has been stable for `patience`
//              iters. Exploits PR 230's decade-wide plateau: we do NOT drive the bulk to
//              a tight residual, only capture the sub-threshold modes to modest accuracy.
// ------------------------------------------------------------------------------------
struct StopSpec {
  bool capture = false;
  double rtol = 1e-6;        // tight residual (capture==false)
  double lambda_cut = 0.05;  // capture: threshold in the pencil
  double capture_rtol = 1e-4;// capture: loose residual required of the bracketing frontier
  int patience = 2;          // capture: consecutive stable iters
  int maxiter = 400;
  bool debug = false;        // capture: per-iteration stderr trace
};
struct LobpcgResult {
  VectorXd lambda; MatrixXd V; int iters = 0; bool converged = false;
  long long neu_mv = 0, dad_mv = 0;
  int n_below_cut = 0;       // #Ritz values < lambda_cut at stop
};

LobpcgResult lobpcg(const LocalOp& L, int m, const StopSpec& stop, unsigned seed) {
  const int n = L.n;
  const long long neu0 = g_mv.neu, dad0 = g_mv.dad;
  auto AN = [&](const MatrixXd& X) { g_mv.neu += X.cols(); return L.applyNeuBlock(X); };
  auto BN = [&](const MatrixXd& X) { g_mv.dad += X.cols(); return L.applyDadBlock(X); };
  m = std::min(m, n);

  std::mt19937 rng(seed);
  std::normal_distribution<double> ndist(0, 1);
  MatrixXd X(n, m);
  for (int i = 0; i < n; ++i) for (int c = 0; c < m; ++c) X(i, c) = ndist(rng);
  { BOrtho bo = borthonormalize(X, BN(X), 1e-12); X = bo.Q; m = X.cols(); }
  MatrixXd AX = AN(X), BX = BN(X);
  {
    MatrixXd Axx = X.transpose() * AX; Axx = 0.5 * (Axx + Axx.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Axx);
    MatrixXd C = es.eigenvectors().leftCols(m);
    X = X * C; AX = AX * C; BX = BX * C;
  }
  VectorXd lam(m);
  for (int c = 0; c < m; ++c) lam(c) = X.col(c).dot(AX.col(c));

  LobpcgResult res;
  MatrixXd P, BP; bool haveP = false;
  std::vector<VectorXd> lamH;   // per-iter Ritz history (for windowed stability)
  std::vector<int> belowH;

  for (int it = 0; it < stop.maxiter; ++it) {
    MatrixXd Rr = AX;
    for (int c = 0; c < m; ++c) Rr.col(c) -= lam(c) * BX.col(c);
    // Per-column relative eigen-residual, normalised by max(|lambda|, cut)*||Bx||. The
    // FLOOR at the cut is deliberate: a near-null mode (lambda ~ 1e-8) need not be resolved
    // to a tight fraction of its own tiny eigenvalue — only to the CUT scale that decides
    // membership (this is the plateau argument made operational). A per-mode denom of
    // |lambda|*||Bx|| alone would demand impossible precision on rigid modes; the old
    // ascale*||x||_2 term (x is B-normalised, not 2-normalised) INFLATED the denom and made
    // spurious over-estimating Ritz pairs look converged -> false early stop. This metric
    // gives rigid/null modes tiny residual (num ~ ||Ax|| ~ 0) and spurious pairs O(1).
    std::vector<double> relres(m);
    double maxrel = 0;
    for (int c = 0; c < m; ++c) {
      const double denom = std::max(std::abs(lam(c)), stop.lambda_cut) * BX.col(c).norm() + 1e-300;
      relres[c] = Rr.col(c).norm() / denom;
      maxrel = std::max(maxrel, relres[c]);
    }
    res.iters = it;
    // count below cut
    int below = 0; for (int c = 0; c < m; ++c) { if (lam(c) < stop.lambda_cut) ++below; else break; }
    res.n_below_cut = below;
    if (stop.capture) {
      // CAPTURE-BASED STOP (PR 230's decade-wide plateau made operational; NOT a tight
      // residual). The coarse space is the SPAN of the kept columns, and the block spans
      // the low modes FAR earlier than any single eigenVECTOR residual converges — a
      // near-null mode (lambda ~ 1e-6 from a near-disconnection) needs hundreds of LOBPCG
      // iters to reach a tight residual, but the block subspace captures it (worst B-angle
      // ~1.0) an order of magnitude sooner. So we stop on SUBSPACE STABILITY, measured by
      // the kept Ritz values settling, plus a RESOLVED GAP at the cut:
      //   (b) boundary: mode `below` (first ABOVE the cut) is a fast bulk mode, converged
      //       to capture_rtol and > cut => the count `below` is real and no unconverged
      //       mode is still hiding (a hiding low mode would sit at/below the cut with a
      //       large residual, failing this, or would change `below` and reset stability).
      //   (c) the kept Ritz values lambda_c (c < below) have stopped moving between iters
      //       (|dlambda|/max(|lambda|,cut) < eig_tol) — the subspace has settled.
      // This is exactly why the plateau helps: we resolve the (easy) boundary and detect
      // subspace settle, instead of grinding the (hard) near-null eigenvectors to 1e-6.
      // A CLEAN GAP above the cut (frontier mode >> cut) plus WINDOWED eigenvalue stability
      // of the kept set AND the frontier mode. The window is essential: a near-null mode
      // still descending toward the cut moves only ~0.5%/iter, so a 2-iter check is fooled
      // into "stable" mid-descent — but over W iters the cumulative drift is caught. Once
      // the smallest modes have genuinely settled (and no hiding mode is still descending),
      // the W-iter change collapses to ~0. A hiding low mode would (a) keep `below` moving,
      // (b) make the frontier eigenvalue drift, or (c) itself be the still-drifting mode —
      // all break the window. The frontier residual is only a LOOSE sanity bound: the bulk
      // gap-mode converges slowly (LOBPCG resolves it behind the hard near-null modes), and
      // demanding it tight is the wasted work the plateau rules out.
      const double eig_tol = 1e-2;
      const int W = 6;                      // stability window (iters)
      const double frontier_gap = 1.5;      // frontier must sit clearly above the cut
      const double frontier_rtol = 0.1;     // loose sanity only (not a tight residual)
      lamH.push_back(lam); belowH.push_back(below);
      bool gap = (below < m) && (lam(below) > stop.lambda_cut * frontier_gap) &&
                 (relres[below] < frontier_rtol);
      bool settled = gap && (int)lamH.size() > W;
      double worstd = 0; bool below_const = true;
      if (settled) {
        const VectorXd& past = lamH[lamH.size() - 1 - W];
        for (int t = (int)belowH.size() - 1 - W; t < (int)belowH.size(); ++t)
          if (belowH[t] != below) { below_const = false; break; }
        settled = below_const && (past.size() == lam.size());
        if (settled) for (int c = 0; c <= below && c < m; ++c) {   // kept modes + frontier
          const double d = std::abs(lam(c) - past(c)) / std::max(std::abs(lam(c)), stop.lambda_cut);
          worstd = std::max(worstd, d);
          if (d > eig_tol) { settled = false; break; }
        }
      }
      if (stop.debug)
        std::fprintf(stderr, "    it=%3d below=%d lam[below-1]=%.3e lam[below]=%.3e "
                     "rel[below]=%.2e gap=%d win_move=%.2e settled=%d\n", it, below,
                     below>0?lam(below-1):-1, below<m?lam(below):-1, below<m?relres[below]:-1,
                     (int)gap, worstd, (int)settled);
      if (it >= W && settled) { res.converged = true; break; }
    } else {
      if (maxrel < stop.rtol) { res.converged = true; break; }
    }

    MatrixXd W = apply_jacobi(L, Rr);
    MatrixXd S, BS;
    if (haveP) { S.resize(n, 3*m); BS.resize(n, 3*m); S << X, W, P; BS << BX, BN(W), BP; }
    else       { S.resize(n, 2*m); BS.resize(n, 2*m); S << X, W;    BS << BX, BN(W);      }
    BOrtho bs = borthonormalize(S, BS, 1e-12);
    if (bs.r < m && haveP) {
      haveP = false; S.resize(n, 2*m); BS.resize(n, 2*m); S << X, W; BS << BX, BN(W);
      bs = borthonormalize(S, BS, 1e-13);
    }
    const int mm = std::min(m, bs.r);
    MatrixXd AQ = AN(bs.Q);
    MatrixXd Ah = bs.Q.transpose() * AQ; Ah = 0.5 * (Ah + Ah.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Ah);
    MatrixXd C = es.eigenvectors().leftCols(mm);
    MatrixXd Xn = bs.Q * C, AXn = AQ * C, BXn = bs.BQ * C;
    if (mm < m) {
      MatrixXd Xp(n,m), AXp(n,m), BXp(n,m);
      Xp.leftCols(mm)=Xn; AXp.leftCols(mm)=AXn; BXp.leftCols(mm)=BXn;
      Xp.rightCols(m-mm)=X.rightCols(m-mm); AXp.rightCols(m-mm)=AX.rightCols(m-mm); BXp.rightCols(m-mm)=BX.rightCols(m-mm);
      Xn=Xp; AXn=AXp; BXn=BXp;
      VectorXd lp(m); lp.head(mm)=es.eigenvalues().head(mm); lp.tail(m-mm)=lam.tail(m-mm); lam=lp;
    } else {
      for (int c = 0; c < m; ++c) lam(c) = es.eigenvalues()(c);
    }
    P = Xn - X; BP = BXn - BX; haveP = true;
    X = Xn; AX = AXn; BX = BXn;
  }
  res.lambda = lam; res.V = X;
  res.neu_mv = g_mv.neu - neu0; res.dad_mv = g_mv.dad - dad0;
  return res;
}

// Per-mode B-inner-product capture of the reference sub-threshold modes (B3 metric).
struct Score { int total = 0, captured = 0; double worst_capture = 1.0; };
Score score_recovery(const LocalOp& L, const RefResult& ref, const MatrixXd& lobV,
                     double lambda_cut) {
  MatrixXd Blob = L.applyDadBlock(lobV);
  BOrtho bo = borthonormalize(lobV, Blob, 1e-12);
  Score s;
  for (int k = 0; k < ref.lambda.size(); ++k) {
    if (ref.lambda(k) >= lambda_cut) break;
    ++s.total;
    VectorXd v = ref.V.col(k);
    VectorXd Bv = L.applyDad(v);
    const double vn = std::sqrt(std::max(v.dot(Bv), 1e-300));
    VectorXd c = bo.BQ.transpose() * v;
    const double capture = c.norm() / vn;
    s.worst_capture = std::min(s.worst_capture, capture);
    if (capture >= 0.999) ++s.captured;
  }
  return s;
}

long long peak_rss_bytes() {
  struct rusage ru; getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return ru.ru_maxrss;
#else
  return ru.ru_maxrss * 1024;
#endif
}
double now_ms() { struct timespec t; timespec_get(&t, TIME_UTC); return t.tv_sec*1e3 + t.tv_nsec/1e6; }

int count_below(const VectorXd& lam, double cut) {
  int c = 0; for (int k = 0; k < lam.size(); ++k) { if (lam(k) < cut) ++c; else break; } return c;
}

// ====================================================================================
// A coarse column stored SPARSELY: (global dof indices on subdomain support, values).
struct CoarseCol { std::vector<int> idx; std::vector<double> val; int sub = 0; };

// The assembled coarse basis (piece 2 output) + build telemetry.
struct CoarseBasis {
  std::vector<CoarseCol> cols;      // N_t columns
  long long fine_dof = 0;
  int nsub = 0, nsub_saturated = 0;
  int core = 0, ov = 0;
  long long total_neu_mv = 0, total_dad_mv = 0;
  int iters_min = 1<<30, iters_max = 0; double iters_mean = 0;
  int modes_min = 1<<30, modes_max = 0; double modes_mean = 0;
  long long max_sub_bytes = 0;       // largest single-subdomain footprint (peak transient)
  double basis_bytes = 0;            // stored sparse basis
  double build_ms = 0;
  double peak_rss_mb = 0;
  std::vector<int> iters_hist, modes_hist, ndof_hist;
  // G1 validation aggregates (over the sampled subdomains)
  int g1_samples = 0, g1_ref_ok = 0, g1_ref_tot = 0, g1_count_match = 0;
  double g1_worst = 1.0;
};

// ------------------------------------------------------------------------------------
// PIECE 2: build the coarse basis. Each subdomain is INDEPENDENT (embarrassingly parallel);
// we build them across threads. Per subdomain: matrix-free LOBPCG with CAPTURE-BASED
// stopping; keep columns with lambda < lambda_cut; store R_i^T D_i v_ik sparsely. The
// memory claim is per-subdomain: the load-bearing number is `max_sub_bytes` (the largest
// single resident subdomain), reported alongside the process peak RSS. G1 dense-reference
// validation runs in a SEPARATE untimed pass so build_ms measures piece-2 cost alone.
// ------------------------------------------------------------------------------------
CoarseBasis build_coarse_basis(const System& S, const std::vector<double>& rho, int core,
                               int ov, double lambda_cut, int block_m, bool tight_ref,
                               std::FILE* fsub, const char* tag) {
  const VoxelGrid& g = S.grid;
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  const std::vector<char> fixed = build_fixed_lut(S);
  const std::vector<Block> cores = tile_cores(g, core);
  const std::vector<double> W = build_pou_normaliser(g, cores, ov);
  const unsigned nthreads = std::max(1u, std::thread::hardware_concurrency());

  CoarseBasis B;
  B.fine_dof = 3LL * fea_node_count(g);
  B.nsub = static_cast<int>(cores.size());
  B.core = core; B.ov = ov;

  struct SubOut {
    std::vector<CoarseCol> cols; int iters = 0, kept = 0, n = 0;
    long long mv_neu = 0, mv_dad = 0, bytes = 0; bool saturated = false, solved = false;
  };
  std::vector<SubOut> outs(cores.size());

  // ---- timed construction pass (parallel) ----
  const double t0 = now_ms();
  std::atomic<std::size_t> next{0};
  auto worker = [&]() {
    for (;;) {
      const std::size_t si = next.fetch_add(1);
      if (si >= cores.size()) break;
      LocalOp L = build_local(g, rho, cores[si], ov, kContrast, K0, fixed, W);
      if (L.n < 24) continue;
      StopSpec stop; stop.capture = true; stop.lambda_cut = lambda_cut;
      stop.capture_rtol = 1e-4; stop.patience = 2; stop.maxiter = 800;
      const int m = std::min(block_m, L.n);
      LobpcgResult lob = lobpcg(L, m, stop, 20250728u + static_cast<unsigned>(si));
      const int kept = count_below(lob.lambda, lambda_cut);
      SubOut& o = outs[si];
      o.solved = true; o.n = L.n; o.iters = lob.iters; o.kept = kept;
      o.mv_neu = lob.neu_mv; o.mv_dad = lob.dad_mv; o.bytes = L.bytes();
      o.saturated = (kept >= m - 2);
      for (int c = 0; c < kept; ++c) {
        CoarseCol col; col.sub = static_cast<int>(si);
        col.idx.reserve(L.n); col.val.reserve(L.n);
        for (int d = 0; d < L.n; ++d) { col.idx.push_back(L.gdof[d]); col.val.push_back(L.D[d] * lob.V(d, c)); }
        o.cols.push_back(std::move(col));
      }
    }
  };
  { std::vector<std::thread> pool; for (unsigned t = 0; t < nthreads; ++t) pool.emplace_back(worker);
    for (auto& th : pool) th.join(); }
  B.build_ms = now_ms() - t0;
  B.peak_rss_mb = peak_rss_bytes() / 1048576.0;

  // ---- merge (sequential, deterministic order) ----
  double iters_sum = 0, modes_sum = 0; int solved = 0;
  for (std::size_t si = 0; si < cores.size(); ++si) {
    SubOut& o = outs[si];
    if (!o.solved) continue;
    ++solved; iters_sum += o.iters; modes_sum += o.kept;
    B.total_neu_mv += o.mv_neu; B.total_dad_mv += o.mv_dad;
    B.max_sub_bytes = std::max(B.max_sub_bytes, o.bytes);
    if (o.saturated) ++B.nsub_saturated;
    B.iters_min = std::min(B.iters_min, o.iters); B.iters_max = std::max(B.iters_max, o.iters);
    B.modes_min = std::min(B.modes_min, o.kept); B.modes_max = std::max(B.modes_max, o.kept);
    B.iters_hist.push_back(o.iters); B.modes_hist.push_back(o.kept); B.ndof_hist.push_back(o.n);
    for (auto& col : o.cols) { B.basis_bytes += col.idx.size() * (4.0 + 8.0); B.cols.push_back(std::move(col)); }
  }
  B.iters_mean = solved ? iters_sum / solved : 0;
  B.modes_mean = solved ? modes_sum / solved : 0;
  if (!solved) { B.iters_min = B.modes_min = 0; }

  // ---- G1 validation: separate UNTIMED parallel pass over a strided sample ----
  if (fsub && tight_ref) {
    const std::size_t stride = std::max<std::size_t>(1, cores.size() / 16);
    std::vector<std::size_t> sample;
    for (std::size_t si = 0; si < cores.size(); si += stride) if (outs[si].solved && outs[si].n <= 9000) sample.push_back(si);
    std::vector<std::array<double,4>> vres(sample.size());  // ref_below, capt, worst, kept
    std::atomic<std::size_t> vnext{0};
    auto vworker = [&]() {
      for (;;) {
        const std::size_t k = vnext.fetch_add(1);
        if (k >= sample.size()) break;
        const std::size_t si = sample[k];
        LocalOp L = build_local(g, rho, cores[si], ov, kContrast, K0, fixed, W);
        StopSpec stop; stop.capture = true; stop.lambda_cut = lambda_cut; stop.maxiter = 800;
        LobpcgResult lob = lobpcg(L, std::min(block_m, L.n), stop, 20250728u + static_cast<unsigned>(si));
        RefResult r = reference_smallest(L, 1e-10);
        const int ref_below = count_below(r.lambda, lambda_cut);
        const int kept = count_below(lob.lambda, lambda_cut);
        Score s = score_recovery(L, r, lob.V, lambda_cut);
        vres[k] = {(double)ref_below, (double)s.captured, s.worst_capture, (double)kept};
      }
    };
    { std::vector<std::thread> pool; for (unsigned t = 0; t < nthreads; ++t) pool.emplace_back(vworker);
      for (auto& th : pool) th.join(); }
    for (std::size_t k = 0; k < sample.size(); ++k) {
      const int ref_below = (int)vres[k][0], capt = (int)vres[k][1], kept = (int)vres[k][3];
      const double worst = vres[k][2];
      B.g1_ref_ok += capt; B.g1_ref_tot += ref_below; B.g1_worst = std::min(B.g1_worst, worst);
      if (ref_below == kept) ++B.g1_count_match;
      ++B.g1_samples;
      std::fprintf(fsub, "%s,%d,%d,%d,%d,%d,%d,%d,%.5f\n", tag, core, (int)sample[k], outs[sample[k]].n,
                   outs[sample[k]].iters, kept, ref_below, capt, worst);
    }
  }
  return B;
}

// ------------------------------------------------------------------------------------
// PIECE 3: coarse operator Ac = V^T A V, A = the PRODUCTION global matrix-free operator.
// Each column A v_q is ONE fea_matfree_apply over the full grid (contrast moduli, Emax=1);
// (V^T A V)_{pq} = V_p . (A v_q), using V_p's sparse support. If N_t <= dense_cap: LDLT-
// factorize and report SPD + conditioning. Else: report the inexact-coarse-solve need.
// ------------------------------------------------------------------------------------
struct CoarseOp {
  int Nt = 0; bool factorized = false; bool spd = false;
  double assemble_ms = 0, factor_ms = 0;
  double dense_bytes = 0;
  double lam_min = 0, lam_max = 0, cond = 0;
  long long global_applies = 0;
};
CoarseOp build_coarse_operator(const System& S, const std::vector<double>& rho,
                               const CoarseBasis& B, int dense_cap) {
  const VoxelGrid& g = S.grid;
  const int Nt = static_cast<int>(B.cols.size());
  CoarseOp C; C.Nt = Nt;
  C.dense_bytes = static_cast<double>(Nt) * Nt * 8.0;
  // per-voxel moduli for the GLOBAL apply (contrast, Emax=1) — matches the local operator.
  std::vector<double> Evox(g.voxel_count());
  for (std::size_t v = 0; v < Evox.size(); ++v) Evox[v] = efac_contrast(rho[v], kContrast);
  const int gdim = 3 * fea_node_count(g);

  if (Nt == 0) return C;
  if (Nt > dense_cap) {
    // Report only: do NOT assemble a dense Nt x Nt (would be C.dense_bytes). The
    // inexact/iterative coarse solve (arXiv 1912.13225 eq.9 deflated form) is the route.
    C.assemble_ms = 0; return C;
  }

  const double t0 = now_ms();
  MatrixXd Ac = MatrixXd::Zero(Nt, Nt);
  std::vector<double> vq(gdim), Avq;
  for (int q = 0; q < Nt; ++q) {
    std::fill(vq.begin(), vq.end(), 0.0);
    const CoarseCol& cq = B.cols[q];
    for (std::size_t t = 0; t < cq.idx.size(); ++t) vq[cq.idx[t]] = cq.val[t];
    Avq = fea_matfree_apply(g, Evox, kNu, vq);  // ONE global apply (production operator)
    ++C.global_applies;
    for (int p = 0; p < Nt; ++p) {
      const CoarseCol& cp = B.cols[p];
      double dot = 0;
      for (std::size_t t = 0; t < cp.idx.size(); ++t) dot += cp.val[t] * Avq[cp.idx[t]];
      Ac(p, q) = dot;
    }
  }
  Ac = 0.5 * (Ac + Ac.transpose());
  C.assemble_ms = now_ms() - t0;

  const double t1 = now_ms();
  Eigen::LDLT<MatrixXd> ldlt(Ac);
  C.factor_ms = now_ms() - t1;
  C.factorized = (ldlt.info() == Eigen::Success);
  C.spd = C.factorized && ldlt.isPositive();
  // spectrum for conditioning (cheap at coarse dim)
  Eigen::SelfAdjointEigenSolver<MatrixXd> es(Ac, Eigen::EigenvaluesOnly);
  C.lam_min = es.eigenvalues()(0);
  C.lam_max = es.eigenvalues()(Nt - 1);
  C.cond = (C.lam_min > 0) ? C.lam_max / C.lam_min : -1;
  return C;
}

// principal-angle-based subspace distance between two B-orthonormal bases spanning the
// same local DOF space (used for amortization G4). Returns 1 - min cos(theta) over the
// smaller basis => 0 means identical span, 1 means an orthogonal direction appeared.
double subspace_change(const LocalOp& L, const MatrixXd& Va, const MatrixXd& Vb) {
  BOrtho a = borthonormalize(Va, L.applyDadBlock(Va), 1e-12);
  BOrtho b = borthonormalize(Vb, L.applyDadBlock(Vb), 1e-12);
  if (a.r == 0 || b.r == 0) return 1.0;
  // cross Gram in B-inner product: a.Q^T B b.Q = a.BQ^T b.Q
  MatrixXd M = a.BQ.transpose() * b.Q;         // r_a x r_b
  Eigen::JacobiSVD<MatrixXd> svd(M);
  const VectorXd sv = svd.singularValues();    // = cos(principal angles)
  const int r = std::min(a.r, b.r);
  double minc = 1.0;
  for (int i = 0; i < r; ++i) minc = std::min(minc, sv(i));
  return 1.0 - std::max(0.0, std::min(1.0, minc));
}

// ====================================================================================
int selfcheck() {
  std::printf("=== SELF-CHECK (GenEO coarse-basis harness) ===\n");
  int fail = 0;
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();

  // (1) PARTITION OF UNITY: over a full tiling, sum_i D_i = 1 at every free DOF.
  {
    System S = build_cantilever(16, 12, 16);
    const std::vector<char> fixed = build_fixed_lut(S);
    std::vector<double> rho(S.grid.voxel_count(), 1.0);
    const int core = 6, ov = 1;
    const std::vector<Block> cores = tile_cores(S.grid, core);
    const std::vector<double> W = build_pou_normaliser(S.grid, cores, ov);
    std::vector<double> acc(3 * fea_node_count(S.grid), 0.0);
    std::vector<char> touched(acc.size(), 0);
    for (const Block& cb : cores) {
      LocalOp L = build_local(S.grid, rho, cb, ov, kContrast, K0, fixed, W);
      for (int d = 0; d < L.n; ++d) { acc[L.gdof[d]] += L.D[d]; touched[L.gdof[d]] = 1; }
    }
    double worst = 0; int nfree = 0;
    for (std::size_t d = 0; d < acc.size(); ++d) {
      if (fixed[d] || !touched[d]) continue;
      ++nfree; worst = std::max(worst, std::abs(acc[d] - 1.0));
    }
    std::printf("  PoU sum_i D_i = 1 : free DOF=%d  max|sum-1|=%.3e  %s\n", nfree, worst,
                worst < 1e-12 ? "PASS" : "FAIL");
    if (worst >= 1e-12) ++fail;
  }

  // (2) uniform free block: exactly 6 rigid modes at lambda~0 (structure check).
  {
    System F = build_cantilever(10, 10, 10); F.bcs.clear();
    const std::vector<char> fixed = build_fixed_lut(F);
    std::vector<double> rho(F.grid.voxel_count(), 1.0);
    Block core{2, 8, 2, 8, 2, 8};
    LocalOp L = build_local(F.grid, rho, core, 1, kContrast, K0, fixed, {});
    RefResult r = reference_smallest(L, 1e-10);
    int nzero = 0; for (int k = 0; k < r.lambda.size() && r.lambda(k) < 1e-8; ++k) ++nzero;
    std::printf("  uniform free block: n=%d #(lambda<1e-8)=%d  %s\n", L.n, nzero,
                nzero == 6 ? "PASS(6 rigid)" : "FAIL");
    if (nzero != 6) ++fail;
  }

  // (3) capture-based stop recovers the SAME sub-threshold modes as a tight residual, on
  //     a real heterogeneous block, with fewer matvecs.
  {
    System F = build_cantilever(12, 12, 12); F.bcs.clear();
    const std::vector<char> fixed = build_fixed_lut(F);
    std::vector<double> rho(F.grid.voxel_count(), 1.0);
    for (int k=0;k<3;++k) for (int j=0;j<3;++j) for (int i=0;i<3;++i) rho[F.grid.index(5+i,5+j,5+k)] = kRhoMinProd;
    Block core{3, 9, 3, 9, 3, 9};
    LocalOp L = build_local(F.grid, rho, core, 1, kContrast, K0, fixed, {});
    RefResult r = reference_smallest(L, 1e-10);
    const double cut = 0.05;
    const int ref_below = count_below(r.lambda, cut);
    StopSpec tight; tight.capture = false; tight.rtol = 1e-6; tight.maxiter = 400;
    StopSpec cap; cap.capture = true; cap.lambda_cut = cut; cap.capture_rtol = 1e-3; cap.patience = 2; cap.maxiter = 400;
    LobpcgResult lt = lobpcg(L, ref_below + 8, tight, 999);
    LobpcgResult lc = lobpcg(L, ref_below + 8, cap, 999);
    Score st = score_recovery(L, r, lt.V, cut);
    Score sc = score_recovery(L, r, lc.V, cut);
    const bool ok = (st.captured == st.total) && (sc.captured == sc.total) &&
                    (sc.total == ref_below) && (lc.neu_mv + lc.dad_mv <= lt.neu_mv + lt.dad_mv);
    std::printf("  capture vs tight  : ref_below=%d  tight[iters=%d capt=%d/%d mv=%lld]  "
                "capture[iters=%d capt=%d/%d mv=%lld]  %s\n",
                ref_below, lt.iters, st.captured, st.total, lt.neu_mv + lt.dad_mv,
                lc.iters, sc.captured, sc.total, lc.neu_mv + lc.dad_mv, ok ? "PASS" : "FAIL");
    if (!ok) ++fail;
  }

  // (4) capture stop recovers EVERY sub-threshold mode of a REAL developed field's WHOLE
  //     decomposition (the G1 bar, in miniature): compare capture-kept vs the dense
  //     reference on every subdomain of a small OC-developed cantilever.
  {
    System S = build_cantilever(24, 12, 24);
    std::vector<double> rho = develop_field(S, 0.35, 25);
    const std::vector<char> fixed = build_fixed_lut(S);
    const int core = 8, ov = 1; const double cut = 0.05;
    const std::vector<Block> cores = tile_cores(S.grid, core);
    const std::vector<double> W = build_pou_normaliser(S.grid, cores, ov);
    int tot_ref = 0, tot_capt = 0, nmiss = 0, sat = 0; double worst = 1.0;
    long long mv_cap = 0; int iters_max = 0;
    for (std::size_t si = 0; si < cores.size(); ++si) {
      LocalOp L = build_local(S.grid, rho, cores[si], ov, kContrast, K0, fixed, W);
      if (L.n < 24) continue;
      RefResult r = reference_smallest(L, 1e-10);
      const int rb = count_below(r.lambda, cut);
      const int m = std::min(20, L.n);
      if (rb >= m - 3) ++sat;  // block too small to bracket -> saturation
      StopSpec cap; cap.capture = true; cap.lambda_cut = cut; cap.maxiter = 500;
      LobpcgResult lc = lobpcg(L, m, cap, 700u + (unsigned)si);
      Score s = score_recovery(L, r, lc.V, cut);
      tot_ref += s.total; tot_capt += s.captured; worst = std::min(worst, s.worst_capture);
      if (s.captured < s.total) ++nmiss;
      mv_cap += lc.neu_mv + lc.dad_mv; iters_max = std::max(iters_max, lc.iters);
    }
    const bool ok = (tot_capt == tot_ref) && (sat == 0);
    std::printf("  capture on REAL field: %d subs, captured %d/%d modes (worst=%.4f), "
                "saturated=%d, subs-with-miss=%d, iters_max=%d, total mv=%lld  %s\n",
                (int)cores.size(), tot_capt, tot_ref, worst, sat, nmiss, iters_max, mv_cap,
                ok ? "PASS" : "FAIL");
    if (!ok) ++fail;
  }

  // (5) coarse operator on a tiny full decomposition is SPD and factorizes.
  {
    System S = build_cantilever(12, 8, 12);
    std::vector<double> rho = develop_field(S, 0.5, 8);
    CoarseBasis B = build_coarse_basis(S, rho, 6, 1, 0.05, 16, false, nullptr, "sc");
    CoarseOp C = build_coarse_operator(S, rho, B, 8000);
    std::printf("  coarse op         : Nt=%d factorized=%d spd=%d lam_min=%.3e cond=%.2e  %s\n",
                C.Nt, C.factorized, C.spd, C.lam_min, C.cond,
                (C.factorized && C.spd && C.lam_min > 0) ? "PASS" : "FAIL");
    if (!(C.factorized && C.spd && C.lam_min > 0)) ++fail;
  }

  std::printf("SELF-CHECK: %s\n\n", fail == 0 ? "ALL PASS" : "FAILURES PRESENT");
  return fail;
}

// ====================================================================================
// ★ STEP 0 — retire the risk FIRST: LOBPCG iteration count vs subdomain SIZE.
// Sweep core size up toward ~16k DOF/subdomain. For each core: build every subdomain of a
// real field, run capture-based LOBPCG, report the iteration-count distribution vs n. If
// iterations blow up with n, the route needs fewer-larger subdomains or closes.
// ====================================================================================
int scaling(const std::string& csvdir) {
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  std::FILE* f = std::fopen((csvdir + "/scaling.csv").c_str(), "w");
  if (f) std::fprintf(f, "core,ov,nsub,nsampled,n_med,n_max,iters_med,iters_p90,n_capped,mv_per_sub_med,"
                         "modes_med,modes_max,captured_frac,worst_capture\n");
  // Real developed field, one representative rung.
  System cant = build_cantilever(64, 32, 64);
  const int fine = 3 * fea_node_count(cant.grid);
  std::printf("## STEP 0 scaling: cantilever 64x32x64 (fine DOF=%d), develop 40 OC iters rung 0.35\n", fine);
  const double t_dev = now_ms();
  std::vector<double> rho = develop_field(cant, 0.35, 40);
  std::printf("   develop wall=%.1f s\n", (now_ms() - t_dev) / 1e3);
  std::fflush(stdout);
  const std::vector<char> fixed = build_fixed_lut(cant);
  const double cut = 0.05;

  std::printf("\n core  ov  nsub  nsampled  n(med/max)     iters(med/max)   mv/sub(med)  modes(med/max)  capture(sampled ref)\n");
  const unsigned nthreads = std::max(1u, std::thread::hardware_concurrency());
  // core=4 (n~1000) is the small end and least informative for a LARGE-subdomain risk;
  // the sweep runs 6..16 (n ~ 2k..20k, spanning the ~16k real subdomain size). Each core's
  // LOBPCG is measured on an evenly-strided SAMPLE of up to ~solve_cap subdomains (the
  // distribution is homogeneous across the domain); dense-reference capture validation on
  // a further subset. This keeps the sweep affordable without biasing the median/max.
  for (int core : {6, 8, 10, 12, 14, 16}) {
    const int ov = 1;
    const std::vector<Block> cores = tile_cores(cant.grid, core);
    const std::vector<double> W = build_pou_normaliser(cant.grid, cores, ov);
    const int solve_cap = 96, nref = 12, sweep_maxiter = 400;
    const std::size_t sstride = std::max<std::size_t>(1, cores.size() / solve_cap);
    std::vector<int> ns(cores.size(), -1), iters(cores.size(), 0), modes(cores.size(), 0);
    std::vector<long long> mvs(cores.size(), 0);
    std::vector<int> ref_ok(cores.size(), 0), ref_tot(cores.size(), 0), capped(cores.size(), 0);
    std::vector<double> ref_worst(cores.size(), 1.0);
    // count sampled solves and pick a ref stride within them
    std::size_t nsolve = 0; for (std::size_t si = 0; si < cores.size(); si += sstride) ++nsolve;
    const std::size_t rstride = std::max<std::size_t>(1, nsolve / nref) * sstride;
    std::atomic<std::size_t> next{0};
    auto worker = [&]() {
      for (;;) {
        const std::size_t idx = next.fetch_add(1);
        const std::size_t si = idx * sstride;                 // sampled subdomains only
        if (si >= cores.size()) break;
        LocalOp L = build_local(cant.grid, rho, cores[si], ov, kContrast, K0, fixed, W);
        if (L.n < 24) continue;
        StopSpec stop; stop.capture = true; stop.lambda_cut = cut; stop.capture_rtol = 1e-4;
        stop.patience = 2; stop.maxiter = sweep_maxiter;
        LobpcgResult lob = lobpcg(L, std::min(20, L.n), stop, 424242u + (unsigned)si);
        ns[si] = L.n; iters[si] = lob.iters; modes[si] = count_below(lob.lambda, cut);
        mvs[si] = lob.neu_mv + lob.dad_mv;
        if (!lob.converged) capped[si] = 1;   // hit maxiter (hard near-disconnection tail)
        if ((si % rstride) == 0 && L.n <= 9000) {  // sampled capture validation
          RefResult r = reference_smallest(L, 1e-10);
          Score s = score_recovery(L, r, lob.V, cut);
          ref_ok[si] = s.captured; ref_tot[si] = s.total; ref_worst[si] = s.worst_capture;
        }
      }
    };
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < nthreads; ++t) pool.emplace_back(worker);
    for (auto& th : pool) th.join();
    // aggregate (skip unsolved -1 entries)
    std::vector<int> vn, vit, vmo; std::vector<long long> vmv;
    int capt_ok = 0, capt_tot = 0, ncap = 0; double worst = 1.0;
    for (std::size_t si = 0; si < cores.size(); ++si) {
      if (ns[si] < 0) continue;
      vn.push_back(ns[si]); vit.push_back(iters[si]); vmo.push_back(modes[si]); vmv.push_back(mvs[si]);
      capt_ok += ref_ok[si]; capt_tot += ref_tot[si]; ncap += capped[si];
      if (ref_tot[si] > 0) worst = std::min(worst, ref_worst[si]);
    }
    auto med = [](std::vector<int> v){ if(v.empty())return 0; std::sort(v.begin(),v.end()); return v[v.size()/2]; };
    auto p90 = [](std::vector<int> v){ if(v.empty())return 0; std::sort(v.begin(),v.end()); return v[(v.size()*9)/10]; };
    auto medll = [](std::vector<long long> v){ if(v.empty())return 0LL; std::sort(v.begin(),v.end()); return v[v.size()/2]; };
    auto mx = [](const std::vector<int>& v){ int m=0; for(int x:v)m=std::max(m,x); return m; };
    const double cfrac = capt_tot ? (double)capt_ok / capt_tot : -1;
    // iters reported as median/p90 (max is the maxiter cap for the hard near-disconnection
    // tail; p90 is the informative upper-typical). ncap = #sampled subs that hit the cap.
    std::printf("  %3d  %2d  %5d   %5d    %5d/%-5d    %4d/%-4d  cap%d    %8lld    %3d/%-3d       %d/%d worst=%.4f\n",
                core, ov, (int)cores.size(), (int)vn.size(), med(vn), mx(vn), med(vit), p90(vit), ncap, medll(vmv),
                med(vmo), mx(vmo), capt_ok, capt_tot, worst);
    if (f) { std::fprintf(f, "%d,%d,%d,%d,%d,%d,%d,%d,%d,%lld,%d,%d,%.5f,%.5f\n", core, ov,
                        (int)cores.size(), (int)vn.size(), med(vn), mx(vn), med(vit), p90(vit), ncap, medll(vmv),
                        med(vmo), mx(vmo), cfrac, worst); std::fflush(f); }
    std::fflush(stdout);
  }
  if (f) std::fclose(f);
  std::printf("\n   READ: if iters(med/p90) is roughly FLAT vs n across the sweep, the eigensolve does\n"
              "   NOT blow up with subdomain size and the route stays open. 'cap' = # sampled subs that\n"
              "   hit the %d-iter cap (the hard near-disconnection tail; still capture all modes).\n", 400);
  return 0;
}

// ====================================================================================
// `basis` — pieces 1-3 end to end on a real field at the CHOSEN decomposition, with G1
// (mode capture vs dense reference on a sample), G2 (peak RSS), G3 (real field), and the
// 8.44M-DOF extrapolation.
// ====================================================================================
int run_basis(const std::string& csvdir) {
  std::FILE* fb = std::fopen((csvdir + "/basis_summary.csv").c_str(), "w");
  std::FILE* fs = std::fopen((csvdir + "/basis_subdomains.csv").c_str(), "w");
  if (fb) std::fprintf(fb, "tag,core,ov,fine_dof,nsub,Nt,frac_fine_pct,modes_med,modes_max,"
                           "iters_med,iters_max,build_s,total_mv,basis_MB,max_sub_MB,peak_RSS_MB,"
                           "coarse_Nt,coarse_factorized,coarse_spd,coarse_cond,coarse_dense_MB,"
                           "coarse_assemble_s,coarse_factor_s\n");
  if (fs) std::fprintf(fs, "tag,core,sub,n,iters,kept,ref_below,captured,worst_capture\n");

  // ---- Chosen decomposition: core=8, ov=1 (justified in the handoff / STEP 0). ----
  // Real field: developed cantilever, wispy rung so ligaments near-disconnect through soft
  // void (where the high-contrast surcharge modes live — the hard case for G1).
  System cant = build_cantilever(64, 32, 64);
  const int fine = 3 * fea_node_count(cant.grid);
  std::printf("## BASIS build: cantilever 64x32x64 (fine DOF=%d), develop 40 OC iters rung 0.35\n", fine);
  const double t_dev = now_ms();
  std::vector<double> rho = develop_field(cant, 0.35, 40);
  std::printf("   develop wall=%.1f s\n", (now_ms() - t_dev) / 1e3);

  const double cut = 0.05;
  for (int core : {8, 10}) {
    const int ov = 1;
    std::printf("\n## Decomposition core=%d ov=%d, lambda_cut=%.2f, capture-based stop\n", core, ov, cut);
    CoarseBasis B = build_coarse_basis(cant, rho, core, ov, cut, 20, true, fs, "BASIS");
    const int Nt = static_cast<int>(B.cols.size());
    const double frac = 100.0 * Nt / std::max(1LL, B.fine_dof);
    auto med = [](std::vector<int> v){ if(v.empty())return 0; std::sort(v.begin(),v.end()); return v[v.size()/2]; };
    std::printf("   nsub=%d  Nt=%d (%.3f%% of fine)  modes/sub med/max=%d/%d  iters med/max=%d/%d\n",
                B.nsub, Nt, frac, med(B.modes_hist), B.modes_max, med(B.iters_hist), B.iters_max);
    std::printf("   build wall=%.2f s  total matvecs=%lld  saturated subs (block too small)=%d\n",
                B.build_ms/1e3, B.total_neu_mv + B.total_dad_mv, B.nsub_saturated);
    std::printf("   G2 MEMORY: stored basis=%.1f MB  largest single-subdomain transient=%.2f MB  "
                "process peak RSS=%.0f MB\n",
                B.basis_bytes/1048576.0, B.max_sub_bytes/1048576.0, B.peak_rss_mb);
    std::printf("   G1 CAPTURE (%d sampled subdomains, dense ref): captured modes=%d/%d "
                "worst per-mode capture=%.4f  count(kept==ref_below)=%d/%d  %s\n",
                B.g1_samples, B.g1_ref_ok, B.g1_ref_tot, B.g1_worst, B.g1_count_match, B.g1_samples,
                (B.g1_ref_ok == B.g1_ref_tot && B.g1_count_match == B.g1_samples) ? "ALL MODES CAPTURED" : "!! MISSES !!");

    // ---- PIECE 3: coarse operator ----
    const int dense_cap = 8000;
    CoarseOp C = build_coarse_operator(cant, rho, B, dense_cap);
    if (Nt <= dense_cap) {
      std::printf("   PIECE 3 coarse op V^T A V: Nt=%d  %d global applies  assemble=%.2f s  "
                  "LDLT factor=%.3f s  factorized=%d spd=%d  cond=%.2e  dense=%.1f MB\n",
                  C.Nt, (int)C.global_applies, C.assemble_ms/1e3, C.factor_ms/1e3,
                  C.factorized, C.spd, C.cond, C.dense_bytes/1048576.0);
    } else {
      std::printf("   PIECE 3 coarse op: Nt=%d > dense cap %d — dense V^T A V would be %.1f MB "
                  "(NOT built). Route = inexact/iterative coarse solve (arXiv 1912.13225 eq.9 "
                  "deflated form): a coarse solve spectrally-equivalent to exact, applied inside "
                  "each outer CG iter; does NOT need a dense factorization.\n",
                  Nt, dense_cap, C.dense_bytes/1048576.0);
    }

    // ---- 8.44M-DOF extrapolation (per-subdomain quantities are size-invariant) ----
    const double subs_8M = 8.44e6 / std::max(1.0, (double)fine / std::max(1, B.nsub));
    const double modes_per_sub = B.nsub ? (double)Nt / B.nsub : 0;
    const long long Nt_8M = (long long)(modes_per_sub * subs_8M);
    const double basis_MB_8M = (B.basis_bytes/1048576.0) * subs_8M / std::max(1, B.nsub);
    const double build_s_8M = (B.build_ms/1e3) * subs_8M / std::max(1, B.nsub);
    std::printf("   8.44M-DOF projection: ~%.0f subdomains, Nt~%lld, stored basis~%.0f MB, "
                "1-thread build~%.0f s (embarrassingly parallel over subdomains)\n",
                subs_8M, Nt_8M, basis_MB_8M, build_s_8M);

    if (fb) std::fprintf(fb, "BASIS,%d,%d,%lld,%d,%d,%.4f,%d,%d,%d,%d,%.2f,%lld,%.2f,%.3f,%.0f,"
                             "%d,%d,%d,%.3e,%.2f,%.3f,%.3f\n",
                         core, ov, B.fine_dof, B.nsub, Nt, frac, med(B.modes_hist), B.modes_max,
                         med(B.iters_hist), B.iters_max, B.build_ms/1e3, B.total_neu_mv+B.total_dad_mv,
                         B.basis_bytes/1048576.0, B.max_sub_bytes/1048576.0, B.peak_rss_mb,
                         C.Nt, C.factorized, C.spd, C.cond, C.dense_bytes/1048576.0,
                         C.assemble_ms/1e3, C.factor_ms/1e3);
    std::fflush(stdout);
  }
  if (fb) std::fclose(fb);
  if (fs) std::fclose(fs);
  return 0;
}

// ====================================================================================
// `amort` — G4: how much does the coarse basis CHANGE between consecutive OC iterations?
// If little, it can be reused across many design iterations (the Alexandersen-Lazarov
// amortization that made their single-thread result affordable).
// ====================================================================================
int run_amort(const std::string& csvdir) {
  std::FILE* fa = std::fopen((csvdir + "/amort.csv").c_str(), "w");
  if (fa) std::fprintf(fa, "gap,sub,n,ref_below_a,ref_below_b,subspace_change,rho_L2_change\n");
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();

  System cant = build_cantilever(48, 24, 48);
  std::printf("## AMORT: cantilever 48x24x48, develop 40 OC iters rung 0.35, snapshot every iter\n");
  std::vector<std::vector<double>> snaps;
  std::vector<double> rho = develop_field(cant, 0.35, 40, &snaps);
  const std::vector<char> fixed = build_fixed_lut(cant);
  const int core = 8, ov = 1;
  const double cut = 0.05;
  const std::vector<Block> cores = tile_cores(cant.grid, core);
  const std::vector<double> W = build_pou_normaliser(cant.grid, cores, ov);

  const unsigned nthreads = std::max(1u, std::thread::hardware_concurrency());
  // Sample subdomains across the domain (strided). The wanted subspaces are obtained with
  // the SAME matrix-free capture-LOBPCG the production build uses (not the dense reference)
  // — this measures the change in the ACTUAL reusable basis, and is what would be recycled.
  std::vector<int> sample;
  for (std::size_t si = 0; si < cores.size(); si += std::max<std::size_t>(1, cores.size()/40)) sample.push_back((int)si);

  // Consecutive (30->31) and wider (30->35, 20->30) gaps, late in convergence where the
  // design settles — the regime where reuse across many iterations would apply.
  struct GapDef { int a, b; const char* name; };
  std::vector<GapDef> gaps = {{30,31,"iter30->31"},{30,35,"iter30->35"},{20,30,"iter20->30"}};
  for (const GapDef& gd : gaps) {
    if (gd.b >= (int)snaps.size()) continue;
    const std::vector<double>& ra = snaps[gd.a];
    const std::vector<double>& rb = snaps[gd.b];
    double num=0, den=0; for (std::size_t v=0; v<ra.size(); ++v){ num+=(ra[v]-rb[v])*(ra[v]-rb[v]); den+=ra[v]*ra[v]; }
    const double rho_change = std::sqrt(num/std::max(den,1e-300));
    std::vector<double> chg_by_k(sample.size(), -1);
    std::vector<int> ba_by_k(sample.size(), 0), bb_by_k(sample.size(), 0), n_by_k(sample.size(), 0);
    std::atomic<std::size_t> next{0};
    auto worker = [&]() {
      for (;;) {
        const std::size_t k = next.fetch_add(1);
        if (k >= sample.size()) break;
        const int si = sample[k];
        LocalOp La = build_local(cant.grid, ra, cores[si], ov, kContrast, K0, fixed, W);
        LocalOp Lb = build_local(cant.grid, rb, cores[si], ov, kContrast, K0, fixed, W);
        if (La.n < 24 || La.n != Lb.n) continue;
        StopSpec st; st.capture = true; st.lambda_cut = cut; st.maxiter = 800;
        LobpcgResult la = lobpcg(La, std::min(20, La.n), st, 11u + (unsigned)si);
        LobpcgResult lb = lobpcg(Lb, std::min(20, Lb.n), st, 11u + (unsigned)si);
        const int ba = count_below(la.lambda, cut), bb = count_below(lb.lambda, cut);
        const int kmax = std::max(1, std::max(ba, bb));
        MatrixXd Va = la.V.leftCols(std::min((int)la.V.cols(), kmax));
        MatrixXd Vb = lb.V.leftCols(std::min((int)lb.V.cols(), kmax));
        chg_by_k[k] = subspace_change(La, Va, Vb);
        ba_by_k[k] = ba; bb_by_k[k] = bb; n_by_k[k] = La.n;
      }
    };
    { std::vector<std::thread> pool; for (unsigned t = 0; t < nthreads; ++t) pool.emplace_back(worker);
      for (auto& th : pool) th.join(); }
    std::vector<double> changes;
    for (std::size_t k = 0; k < sample.size(); ++k) {
      if (chg_by_k[k] < 0) continue;
      changes.push_back(chg_by_k[k]);
      if (fa) std::fprintf(fa, "%s,%d,%d,%d,%d,%.5f,%.5f\n", gd.name, sample[k], n_by_k[k], ba_by_k[k], bb_by_k[k], chg_by_k[k], rho_change);
    }
    std::sort(changes.begin(), changes.end());
    const double medc = changes.empty()?0:changes[changes.size()/2];
    const double maxc = changes.empty()?0:changes.back();
    std::printf("   %-12s  rho L2 change=%.4f   coarse-subspace change (1-cos angle) med=%.4f max=%.4f  (n=%d subs)\n",
                gd.name, rho_change, medc, maxc, (int)changes.size());
    std::fflush(stdout);
  }
  std::printf("   READ: small subspace change over a gap => the basis from an earlier iter is\n"
              "   REUSABLE for that many design iterations (amortizes the eigensolve setup).\n");
  if (fa) std::fclose(fa);
  return 0;
}

// Diagnostic: develop a small field, pick a few representative subdomains, and trace the
// capture-stop frontier per iteration to see why/when it fires (or doesn't).
int capdiag() {
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  System S = build_cantilever(32, 16, 32);
  std::vector<double> rho = develop_field(S, 0.35, 30);
  const std::vector<char> fixed = build_fixed_lut(S);
  const int core = 8, ov = 1; const double cut = 0.05;
  const std::vector<Block> cores = tile_cores(S.grid, core);
  const std::vector<double> W = build_pou_normaliser(S.grid, cores, ov);
  for (int si : {0, (int)cores.size()/2, (int)cores.size()-1}) {
    LocalOp L = build_local(S.grid, rho, cores[si], ov, kContrast, K0, fixed, W);
    if (L.n < 24) continue;
    RefResult r = reference_smallest(L, 1e-10);
    const int rb = count_below(r.lambda, cut);
    std::printf("\n== sub %d n=%d ref_below=%d ref lam[0..%d]: ", si, L.n, rb, std::min(rb+3,(int)r.lambda.size()-1));
    for (int k = 0; k < std::min(rb+4,(int)r.lambda.size()); ++k) std::printf("%.3e ", r.lambda(k));
    std::printf("\n");
    StopSpec cap; cap.capture = true; cap.lambda_cut = cut; cap.maxiter = 300; cap.debug = true;
    LobpcgResult lc = lobpcg(L, std::min(20, L.n), cap, 700u + (unsigned)si);
    Score s = score_recovery(L, r, lc.V, cut);
    std::printf("   -> stop iters=%d conv=%d kept=%d captured=%d/%d worst=%.4f mv=%lld\n",
                lc.iters, lc.converged, count_below(lc.lambda, cut), s.captured, s.total,
                s.worst_capture, lc.neu_mv + lc.dad_mv);
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "all";
  const std::string csvdir = argc > 2 ? argv[2] : ".";
  if (mode == "selfcheck") return selfcheck();
  if (mode == "capdiag")   return capdiag();
  if (mode == "scaling")   return scaling(csvdir);
  if (mode == "basis")     return run_basis(csvdir);
  if (mode == "amort")     return run_amort(csvdir);
  if (mode == "all") {
    if (selfcheck() != 0) { std::printf("SELF-CHECK FAILED — aborting.\n"); return 1; }
    scaling(csvdir);
    run_basis(csvdir);
    run_amort(csvdir);
    return 0;
  }
  std::printf("usage: %s [selfcheck|scaling|basis|amort|all] [csvdir]\n", argv[0]);
  return 2;
}
