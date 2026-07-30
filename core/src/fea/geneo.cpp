// Matrix-free GenEO two-level DEFLATION preconditioner — the PRODUCTION provider
// (handoff 2026-07-29-geneo-arming). The algorithms are the measured Phase-2
// recipe (core/tests/harness/geneo_twolevel_probe.cpp, handoff
// 2026-07-29-matrixfree-geneo-phase2), ported coarse-term-only: the local
// additive-Schwarz term measured useless (§P7b) is not here.
//
// Uses Eigen (dense LDLT / small dense eigensolves on subdomain blocks and the
// N_t x N_t coarse operator) — linked PRIVATE like multigrid.cpp; the fine system
// is never assembled. Compiled only in the Eigen-gated solver group.
//
// DETERMINISM. Subdomains are independent; each LOBPCG runs a fixed seed keyed to
// its subdomain index, and the coarse columns are merged in fixed core order — so
// the basis, the coarse operator and every CG iteration count are identical for
// any thread count (the same discipline as the 8-colour matvec).

#include "geneo.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <random>
#include <unordered_map>
#include <vector>

#include <Eigen/Cholesky>
#include <Eigen/Dense>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace fea_detail {

namespace {

using Eigen::MatrixXd;
using Eigen::VectorXd;

// FNV-1a (the repo's evidence fingerprint).
struct Fnv {
  std::uint64_t h = 1469598103934665603ULL;
  void add(const void* p, std::size_t n) {
    const auto* b = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) {
      h ^= b[i];
      h *= 1099511628211ULL;
    }
  }
};

struct Block {
  int x0, x1, y0, y1, z0, z1;  // half-open ELEMENT ranges
};

Block agglomerate(const Block& core, int ov, const VoxelGrid& g) {
  return Block{std::max(0, core.x0 - ov), std::min(g.nx, core.x1 + ov),
               std::max(0, core.y0 - ov), std::min(g.ny, core.y1 + ov),
               std::max(0, core.z0 - ov), std::min(g.nz, core.z1 + ov)};
}

// Raw PoU node weight (phase 2): 1 on the core, linear taper across the overlap
// band, floored at 1/(ov+1) so the local pencil stays non-degenerate.
inline double raw_weight(const Block& core, const Block& agg, const VoxelGrid& g,
                         int ov, double x, double y, double z) {
  const double wfloor = 1.0 / (ov + 1.0);
  auto axis = [&](double p, int c0, int c1, int a0, int a1) -> double {
    const double pe = p / g.spacing;
    if (pe <= c0) {
      if (a0 == c0) return 1.0;
      const double t = (pe - a0 + 0.5) / static_cast<double>(c0 - a0);
      return std::max(0.0, std::min(1.0, t));
    }
    if (pe >= c1) {
      if (a1 == c1) return 1.0;
      const double t = (a1 - pe + 0.5) / static_cast<double>(a1 - c1);
      return std::max(0.0, std::min(1.0, t));
    }
    return 1.0;
  };
  const double w = axis(x, core.x0, core.x1, agg.x0, agg.x1) *
                   axis(y, core.y0, core.y1, agg.y0, agg.y1) *
                   axis(z, core.z0, core.z1, agg.z0, agg.z1);
  return std::max(wfloor, w);
}

// Local subdomain operator: the production operator restricted to the
// agglomerate (per-voxel modulus, element-by-element, never an n-by-n matrix).
struct LocalOp {
  int n = 0;
  std::vector<std::array<int, 24>> edof;
  std::vector<double> eE;       // per-element modulus (iso elements)
  // CUBIC (latticed) elements (multiscale production wiring): ecub[e] != 0
  // selects the exact three-block element eA*K_A + eB*K_B + eC*K_C instead of
  // eE*K0 — the SAME decomposition the global operator applies, so the local
  // Neumann pencil sees the true composite stiffness, not a scalar surrogate.
  // All-zero ecub (every scalar path) leaves applyNeu on the K0 branch
  // element-for-element as before.
  std::vector<char> ecub;
  std::vector<double> eA, eB, eC;
  std::vector<double> D;        // normalized PoU diagonal (w_i / W)
  std::vector<double> diagNeu;  // diag(A^Neu) for the LOBPCG Jacobi step
  std::vector<int> dofNode;
  std::vector<double> nodeXYZ;
  std::vector<int> gdof;  // local dof -> GLOBAL dof (3*node+comp)
  const Eigen::Matrix<double, 24, 24>* K0 = nullptr;
  const Eigen::Matrix<double, 24, 24>* KA = nullptr;
  const Eigen::Matrix<double, 24, 24>* KB = nullptr;
  const Eigen::Matrix<double, 24, 24>* KC = nullptr;

  void applyNeu(const double* x, double* y) const {
    for (int i = 0; i < n; ++i) y[i] = 0.0;
    Eigen::Matrix<double, 24, 1> xe, ye;
    for (std::size_t e = 0; e < edof.size(); ++e) {
      const auto& d = edof[e];
      for (int a = 0; a < 24; ++a) xe(a) = (d[a] >= 0) ? x[d[a]] : 0.0;
      if (ecub[e]) {
        ye.noalias() = eA[e] * ((*KA) * xe);
        ye.noalias() += eB[e] * ((*KB) * xe);
        ye.noalias() += eC[e] * ((*KC) * xe);
        for (int a = 0; a < 24; ++a)
          if (d[a] >= 0) y[d[a]] += ye(a);
      } else {
        ye.noalias() = (*K0) * xe;
        const double E = eE[e];
        for (int a = 0; a < 24; ++a)
          if (d[a] >= 0) y[d[a]] += E * ye(a);
      }
    }
  }
  VectorXd applyNeuV(const VectorXd& x) const {
    VectorXd y(n);
    applyNeu(x.data(), y.data());
    return y;
  }
  VectorXd applyDadV(const VectorXd& x) const {
    VectorXd dx(n);
    for (int i = 0; i < n; ++i) dx(i) = D[i] * x(i);
    VectorXd y = applyNeuV(dx);
    for (int i = 0; i < n; ++i) y(i) *= D[i];
    return y;
  }
  MatrixXd applyNeuBlock(const MatrixXd& X) const {
    MatrixXd Y(n, X.cols());
    for (int c = 0; c < X.cols(); ++c) Y.col(c) = applyNeuV(X.col(c));
    return Y;
  }
  MatrixXd applyDadBlock(const MatrixXd& X) const {
    MatrixXd Y(n, X.cols());
    for (int c = 0; c < X.cols(); ++c) Y.col(c) = applyDadV(X.col(c));
    return Y;
  }
};

std::vector<Block> tile_cores(const VoxelGrid& g, int core) {
  std::vector<Block> cores;
  for (int z = 0; z < g.nz; z += core)
    for (int y = 0; y < g.ny; y += core)
      for (int x = 0; x < g.nx; x += core)
        cores.push_back(Block{x, std::min(g.nx, x + core), y,
                              std::min(g.ny, y + core), z,
                              std::min(g.nz, z + core)});
  return cores;
}

std::vector<double> build_pou_normaliser(const VoxelGrid& g,
                                         const std::vector<Block>& cores, int ov) {
  const int nnode = fea_node_count(g);
  std::vector<double> W(static_cast<std::size_t>(nnode), 0.0);
  const int Nx = g.nx + 1, Ny = g.ny + 1;
  for (const Block& core : cores) {
    const Block agg = agglomerate(core, ov, g);
    for (int c = agg.z0; c <= agg.z1; ++c)
      for (int b = agg.y0; b <= agg.y1; ++b)
        for (int a = agg.x0; a <= agg.x1; ++a) {
          const int gnode = a + Nx * (b + Ny * c);
          W[static_cast<std::size_t>(gnode)] +=
              raw_weight(core, agg, g, ov, a * g.spacing, b * g.spacing,
                         c * g.spacing);
        }
  }
  return W;
}

LocalOp build_local(const VoxelGrid& g, const std::vector<double>& emod,
                    const Block& core, int ov,
                    const Eigen::Matrix<double, 24, 24>& K0,
                    const std::vector<char>& fixed_dof_lut,
                    const std::vector<double>& nodeWglobal,
                    const MfLatticeArrays& lat,
                    const Eigen::Matrix<double, 24, 24>* KA,
                    const Eigen::Matrix<double, 24, 24>* KB,
                    const Eigen::Matrix<double, 24, 24>* KC) {
  const Block agg = agglomerate(core, ov, g);
  LocalOp L;
  L.K0 = &K0;
  L.KA = KA;
  L.KB = KB;
  L.KC = KC;
  std::unordered_map<int, int> lmap;
  lmap.reserve(8192);
  auto local_dof = [&](int gd) -> int {
    if (fixed_dof_lut[static_cast<std::size_t>(gd)]) return -1;
    auto it = lmap.find(gd);
    if (it != lmap.end()) return it->second;
    const int id = static_cast<int>(lmap.size());
    lmap.emplace(gd, id);
    return id;
  };
  for (int k = agg.z0; k < agg.z1; ++k)
    for (int j = agg.y0; j < agg.y1; ++j)
      for (int i = agg.x0; i < agg.x1; ++i) {
        if (!g.solid(i, j, k)) continue;
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
        const std::size_t idx = g.index(i, j, k);
        const bool cub = lat.present() && (*lat.mask)[idx] != 0;
        L.edof.push_back(d);
        L.ecub.push_back(cub ? 1 : 0);
        if (cub) {
          // Latticed voxel: the true composite element (its scalar modulus is
          // never read — matching the global operator's contract).
          L.eE.push_back(0.0);
          L.eA.push_back((*lat.c11)[idx]);
          L.eB.push_back((*lat.c12)[idx]);
          L.eC.push_back((*lat.c44)[idx]);
        } else {
          L.eE.push_back(emod[idx]);
          L.eA.push_back(0.0);
          L.eB.push_back(0.0);
          L.eC.push_back(0.0);
        }
      }
  L.n = static_cast<int>(lmap.size());
  L.dofNode.assign(L.n, -1);
  L.gdof.assign(L.n, -1);
  std::unordered_map<int, int> gnode_to_local;
  for (const auto& kv : lmap) {
    const int gd = kv.first, ld = kv.second;
    const int gnode = gd / 3;
    auto it = gnode_to_local.find(gnode);
    int lnode;
    if (it == gnode_to_local.end()) {
      lnode = static_cast<int>(gnode_to_local.size());
      gnode_to_local.emplace(gnode, lnode);
    } else {
      lnode = it->second;
    }
    L.dofNode[ld] = lnode;
    L.gdof[ld] = gd;
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
  L.D.assign(L.n, 1.0);
  for (int d = 0; d < L.n; ++d) {
    const int ln = L.dofNode[d];
    const double x = L.nodeXYZ[3 * ln + 0], y = L.nodeXYZ[3 * ln + 1],
                 z = L.nodeXYZ[3 * ln + 2];
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
    for (int a = 0; a < 24; ++a) {
      if (d[a] < 0) continue;
      L.diagNeu[d[a]] +=
          L.ecub[e] ? L.eA[e] * (*KA)(a, a) + L.eB[e] * (*KB)(a, a) +
                          L.eC[e] * (*KC)(a, a)
                    : L.eE[e] * K0(a, a);
    }
  }
  return L;
}

// B-orthonormalization + capture-LOBPCG (phase 1/2, verbatim recipe).
struct BOrtho {
  MatrixXd Q, BQ;
  int r = 0;
};
BOrtho borthonormalize(const MatrixXd& S, const MatrixXd& BS, double tol) {
  MatrixXd G = S.transpose() * BS;
  G = 0.5 * (G + G.transpose());
  Eigen::SelfAdjointEigenSolver<MatrixXd> es(G);
  const VectorXd& ev = es.eigenvalues();
  const MatrixXd& U = es.eigenvectors();
  const double emax = ev(ev.size() - 1);
  BOrtho out;
  std::vector<int> keep;
  for (int i = 0; i < ev.size(); ++i)
    if (ev(i) > tol * std::max(emax, 1e-300)) keep.push_back(i);
  out.r = static_cast<int>(keep.size());
  if (out.r == 0) return out;
  MatrixXd T(S.cols(), out.r);
  for (int c = 0; c < out.r; ++c)
    T.col(c) = U.col(keep[c]) / std::sqrt(ev(keep[c]));
  out.Q = S * T;
  out.BQ = BS * T;
  return out;
}
MatrixXd apply_jacobi(const LocalOp& L, const MatrixXd& R) {
  MatrixXd W(L.n, R.cols());
  for (int c = 0; c < R.cols(); ++c)
    for (int i = 0; i < L.n; ++i)
      W(i, c) = R(i, c) / std::max(L.diagNeu[i], 1e-300);
  return W;
}

struct LobpcgResult {
  VectorXd lambda;
  MatrixXd V;
  bool converged = false;
};

LobpcgResult lobpcg(const LocalOp& L, int m, double lambda_cut, int maxiter,
                    unsigned seed) {
  const int n = L.n;
  auto AN = [&](const MatrixXd& X) { return L.applyNeuBlock(X); };
  auto BN = [&](const MatrixXd& X) { return L.applyDadBlock(X); };
  m = std::min(m, n);
  std::mt19937 rng(seed);
  std::normal_distribution<double> nd(0, 1);
  MatrixXd X(n, m);
  for (int i = 0; i < n; ++i)
    for (int c = 0; c < m; ++c) X(i, c) = nd(rng);
  {
    BOrtho bo = borthonormalize(X, BN(X), 1e-12);
    X = bo.Q;
    m = X.cols();
  }
  MatrixXd AX = AN(X), BX = BN(X);
  {
    MatrixXd Axx = X.transpose() * AX;
    Axx = 0.5 * (Axx + Axx.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Axx);
    MatrixXd C = es.eigenvectors().leftCols(m);
    X = X * C;
    AX = AX * C;
    BX = BX * C;
  }
  VectorXd lam(m);
  for (int c = 0; c < m; ++c) lam(c) = X.col(c).dot(AX.col(c));
  LobpcgResult res;
  MatrixXd P, BP;
  bool haveP = false;
  std::vector<VectorXd> lamH;
  std::vector<int> belowH;
  for (int it = 0; it < maxiter; ++it) {
    MatrixXd Rr = AX;
    for (int c = 0; c < m; ++c) Rr.col(c) -= lam(c) * BX.col(c);
    std::vector<double> relres(m);
    for (int c = 0; c < m; ++c) {
      const double denom =
          std::max(std::abs(lam(c)), lambda_cut) * BX.col(c).norm() + 1e-300;
      relres[c] = Rr.col(c).norm() / denom;
    }
    int below = 0;
    for (int c = 0; c < m; ++c) {
      if (lam(c) < lambda_cut)
        ++below;
      else
        break;
    }
    // Capture-based stop (phase 1 piece 2): the below-cut FRONT is settled and a
    // clean frontier gap exists above it.
    const double eig_tol = 1e-2;
    const int W = 6;
    const double frontier_gap = 1.5, frontier_rtol = 0.1;
    lamH.push_back(lam);
    belowH.push_back(below);
    bool gap = (below < m) && (lam(below) > lambda_cut * frontier_gap) &&
               (relres[below] < frontier_rtol);
    bool settled = gap && static_cast<int>(lamH.size()) > W;
    if (settled) {
      const VectorXd& past = lamH[lamH.size() - 1 - W];
      bool below_const = true;
      for (int t = static_cast<int>(belowH.size()) - 1 - W;
           t < static_cast<int>(belowH.size()); ++t)
        if (belowH[t] != below) {
          below_const = false;
          break;
        }
      settled = below_const && (past.size() == lam.size());
      if (settled)
        for (int c = 0; c <= below && c < m; ++c) {
          const double d = std::abs(lam(c) - past(c)) /
                           std::max(std::abs(lam(c)), lambda_cut);
          if (d > eig_tol) {
            settled = false;
            break;
          }
        }
    }
    if (it >= W && settled) {
      res.converged = true;
      break;
    }
    MatrixXd Wm = apply_jacobi(L, Rr);
    MatrixXd S, BS;
    if (haveP) {
      S.resize(n, 3 * m);
      BS.resize(n, 3 * m);
      S << X, Wm, P;
      BS << BX, BN(Wm), BP;
    } else {
      S.resize(n, 2 * m);
      BS.resize(n, 2 * m);
      S << X, Wm;
      BS << BX, BN(Wm);
    }
    BOrtho bs = borthonormalize(S, BS, 1e-12);
    if (bs.r < m && haveP) {
      haveP = false;
      S.resize(n, 2 * m);
      BS.resize(n, 2 * m);
      S << X, Wm;
      BS << BX, BN(Wm);
      bs = borthonormalize(S, BS, 1e-13);
    }
    const int mm = std::min(m, bs.r);
    MatrixXd AQ = AN(bs.Q);
    MatrixXd Ah = bs.Q.transpose() * AQ;
    Ah = 0.5 * (Ah + Ah.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Ah);
    MatrixXd C = es.eigenvectors().leftCols(mm);
    MatrixXd Xn = bs.Q * C, AXn = AQ * C, BXn = bs.BQ * C;
    if (mm < m) {
      MatrixXd Xp(n, m), AXp(n, m), BXp(n, m);
      Xp.leftCols(mm) = Xn;
      AXp.leftCols(mm) = AXn;
      BXp.leftCols(mm) = BXn;
      Xp.rightCols(m - mm) = X.rightCols(m - mm);
      AXp.rightCols(m - mm) = AX.rightCols(m - mm);
      BXp.rightCols(m - mm) = BX.rightCols(m - mm);
      Xn = Xp;
      AXn = AXp;
      BXn = BXp;
      VectorXd lp(m);
      lp.head(mm) = es.eigenvalues().head(mm);
      lp.tail(m - mm) = lam.tail(m - mm);
      lam = lp;
    } else {
      for (int c = 0; c < m; ++c) lam(c) = es.eigenvalues()(c);
    }
    P = Xn - X;
    BP = BXn - BX;
    haveP = true;
    X = Xn;
    AX = AXn;
    BX = BXn;
  }
  res.lambda = lam;
  res.V = X;
  return res;
}

// A coarse column stored sparsely in KEPT-DOF (reduced) coordinates.
struct CoarseCol {
  std::vector<int> idx;
  std::vector<double> val;
};

// ---------------------------------------------------------------------------
// The process-global GenEO state (one production run drives its solves from one
// thread; the recycle space follows the same discipline).
// ---------------------------------------------------------------------------
struct GeneoState {
  bool enabled = false;

  // The held basis (empty when have_basis == false).
  bool have_basis = false;
  std::vector<CoarseCol> cols;
  int Nt = 0;
  long long basis_bytes = 0;
  // The DOF-set the basis is expressed in (kept indices): a mismatch INVALIDATES
  // the basis outright, not just the coarse operator.
  std::uint64_t structure_fp = 0;
  // The moduli the coarse operator currently matches. A stale coarse operator is
  // NOT a deflation for a new system (phase 2 §P6 measured divergence), so a
  // moduli mismatch forces a refresh before the basis may be applied.
  std::uint64_t moduli_fp = 0;

  // Coarse operator: dense LDLT at or under the cap, capped inner CG above.
  MatrixXd coarse_A;
  Eigen::LDLT<MatrixXd> coarse_ldlt;
  bool coarse_dense = false;

  // Reuse policy (see geneo.hpp tripwire).
  bool rebuild_scheduled = false;
  int ref_iters = -1;      // post-rebuild reference iteration count
  bool ref_pending = false;
  std::uint64_t mem_refused_fp = 0;  // structure whose build busted the cap

  // Per-solve.
  bool active = false;
  GeneoReport last;

  // Cumulative since reset.
  long long builds = 0, refreshes = 0, armed_solves = 0;

  // Apply scratch.
  std::vector<double> ccoarse;
};

GeneoState g_geneo;

std::uint64_t structure_fingerprint(const MatfreeReduced& m,
                                    const MfSolveContext& ctx) {
  Fnv f;
  const int dims[4] = {ctx.grid->nx, ctx.grid->ny, ctx.grid->nz, m.ng};
  f.add(dims, sizeof dims);
  if (!m.kept_global.empty())
    f.add(m.kept_global.data(), m.kept_global.size() * sizeof(int));
  return f.h;
}

std::uint64_t moduli_fingerprint(const MfSolveContext& ctx) {
  Fnv f;
  if (ctx.elem_youngs != nullptr && !ctx.elem_youngs->empty())
    f.add(ctx.elem_youngs->data(), ctx.elem_youngs->size() * sizeof(double));
  else
    f.add(&ctx.youngs_modulus, sizeof ctx.youngs_modulus);
  f.add(&ctx.poisson, sizeof ctx.poisson);
  // CUBIC LATTICE FIELDS (multiscale production wiring). A cubic design is
  // THREE fields beyond the scalar moduli; two designs sharing the same
  // scalar-modulus-equivalent field but different tensors are DIFFERENT
  // operators, and a fingerprint blind to the tensors would silently reuse the
  // held coarse operator V^T A_old V against the new A — exactly the stale
  // reuse the mandatory refresh exists to prevent (phase 2 §P6 measured
  // divergence). The mask participates too: moving a voxel between the iso and
  // cubic lists changes the operator even if every array value is unchanged. A
  // presence tag keeps "no lattice" distinct from "empty lattice arrays".
  const unsigned char lat_present = ctx.lattice.present() ? 1 : 0;
  f.add(&lat_present, sizeof lat_present);
  if (ctx.lattice.present()) {
    f.add(ctx.lattice.mask->data(), ctx.lattice.mask->size() * sizeof(char));
    f.add(ctx.lattice.c11->data(), ctx.lattice.c11->size() * sizeof(double));
    f.add(ctx.lattice.c12->data(), ctx.lattice.c12->size() * sizeof(double));
    f.add(ctx.lattice.c44->data(), ctx.lattice.c44->size() * sizeof(double));
  }
  return f.h;
}

// The per-voxel modulus vector the local operators read: the graded vector when
// present, else the single modulus broadcast over solid voxels (uniform path).
const std::vector<double>& modulus_vector(const MfSolveContext& ctx,
                                          std::vector<double>& scratch) {
  if (ctx.elem_youngs != nullptr && !ctx.elem_youngs->empty())
    return *ctx.elem_youngs;
  scratch.assign(ctx.grid->voxel_count(), ctx.youngs_modulus);
  return scratch;
}

// Refresh (or first-build) the coarse operator V^T A V against the CURRENT
// reduced operator: N_t global matvecs + a small dense factor.
void build_coarse_operator(GeneoState& S, const MatfreeReduced& m) {
  const int Nt = S.Nt;
  MatrixXd Ac = MatrixXd::Zero(Nt, Nt);
  std::vector<double> vq(static_cast<std::size_t>(m.ng)),
      Avq(static_cast<std::size_t>(m.ng));
  for (int q = 0; q < Nt; ++q) {
    std::fill(vq.begin(), vq.end(), 0.0);
    const CoarseCol& cq = S.cols[q];
    for (std::size_t t = 0; t < cq.idx.size(); ++t) vq[cq.idx[t]] = cq.val[t];
    m.apply_kgg_raw(vq.data(), Avq.data());
    for (int p = 0; p < Nt; ++p) {
      const CoarseCol& cp = S.cols[p];
      double dot = 0;
      for (std::size_t t = 0; t < cp.idx.size(); ++t)
        dot += cp.val[t] * Avq[cp.idx[t]];
      Ac(p, q) = dot;
    }
  }
  Ac = 0.5 * (Ac + Ac.transpose());
  S.coarse_dense = (Nt > 0 && Nt <= kGeneoCoarseDenseCap);
  if (S.coarse_dense) S.coarse_ldlt.compute(Ac);
  S.coarse_A = std::move(Ac);
  S.ccoarse.assign(static_cast<std::size_t>(Nt), 0.0);
}

// Inner-CG on the dense coarse operator (Jacobi-preconditioned), capped — the
// inexact coarse solve for N_t above the dense-factor budget.
VectorXd coarse_inner_cg(const GeneoState& S, const VectorXd& b) {
  const int n = S.Nt;
  VectorXd x = VectorXd::Zero(n);
  VectorXd d(n);
  for (int i = 0; i < n; ++i) d(i) = S.coarse_A(i, i);
  VectorXd r = b, z(n);
  for (int i = 0; i < n; ++i) z(i) = r(i) / std::max(d(i), 1e-300);
  VectorXd p = z;
  double rz = r.dot(z);
  for (int it = 0; it < kGeneoCoarseInnerIters; ++it) {
    VectorXd Ap = S.coarse_A * p;
    const double a = rz / std::max(p.dot(Ap), 1e-300);
    x += a * p;
    r -= a * Ap;
    if (r.norm() <= 1e-6 * b.norm()) break;
    for (int i = 0; i < n; ++i) z(i) = r(i) / std::max(d(i), 1e-300);
    const double rzn = r.dot(z);
    p = z + (rzn / std::max(rz, 1e-300)) * p;
    rz = rzn;
  }
  return x;
}

// Full basis build: decomposition + per-subdomain capture-LOBPCG, columns merged
// in fixed core order. Returns false when the stored basis busts the memory cap
// (the caller stays plain Jacobi-CG — exact, just slower).
bool build_basis(GeneoState& S, const MatfreeReduced& m,
                 const MfSolveContext& ctx) {
  const VoxelGrid& g = *ctx.grid;
  std::vector<double> mod_scratch;
  const std::vector<double>& emod = modulus_vector(ctx, mod_scratch);

  Eigen::Matrix<double, 24, 24> K0;
  {
    const Hex8Stiffness k = hex8_stiffness(1.0, ctx.poisson, g.spacing);
    for (int r = 0; r < 24; ++r)
      for (int c = 0; c < 24; ++c) K0(r, c) = k(r, c);
  }
  // The three cubic reference blocks (multiscale production wiring), built only
  // when the solve context carries lattice fields — the scalar path allocates
  // and computes nothing extra.
  Eigen::Matrix<double, 24, 24> KAe, KBe, KCe;
  const Eigen::Matrix<double, 24, 24>* KAp = nullptr;
  const Eigen::Matrix<double, 24, 24>* KBp = nullptr;
  const Eigen::Matrix<double, 24, 24>* KCp = nullptr;
  if (ctx.lattice.present()) {
    Hex8Stiffness kA, kB, kC;
    hex8_cubic_reference_blocks(g.spacing, kA, kB, kC);
    for (int r = 0; r < 24; ++r)
      for (int c = 0; c < 24; ++c) {
        KAe(r, c) = kA(r, c);
        KBe(r, c) = kB(r, c);
        KCe(r, c) = kC(r, c);
      }
    KAp = &KAe;
    KBp = &KBe;
    KCp = &KCe;
  }
  // global DOF -> kept index; a DOF is eliminated iff not kept (Dirichlet-fixed
  // OR void-gated) — the exact set the reduced system drops, so every subdomain
  // inherits the global Dirichlet boundary (classical A_i = R_i A R_i^T).
  std::vector<int> kept_of_gdof(static_cast<std::size_t>(3 * fea_node_count(g)),
                                -1);
  for (int kg = 0; kg < m.ng; ++kg)
    kept_of_gdof[static_cast<std::size_t>(m.kept_global[kg])] = kg;
  std::vector<char> fixed(kept_of_gdof.size(), 0);
  for (std::size_t gd = 0; gd < kept_of_gdof.size(); ++gd)
    if (kept_of_gdof[gd] < 0) fixed[gd] = 1;

  const std::vector<Block> cores = tile_cores(g, kGeneoCoreCells);
  const std::vector<double> W = build_pou_normaliser(g, cores, kGeneoOverlap);

  // Independent subdomains, threaded on the SHARED persistent matrix-free pool
  // (132's P-core pin governs), merged in fixed core order (deterministic).
  struct SubBuild {
    std::vector<CoarseCol> cols;
    bool ok = false;
  };
  std::vector<SubBuild> built(cores.size());
  mf_parallel_ranges(
      0, static_cast<int>(cores.size()), 1, [&](int lo, int hi) {
        for (int si = lo; si < hi; ++si) {
          LocalOp L = build_local(g, emod, cores[si], kGeneoOverlap, K0, fixed,
                                  W, ctx.lattice, KAp, KBp, KCp);
          if (L.n < 24) continue;
          const int mm = std::min(kGeneoBlockM, L.n);
          LobpcgResult lob = lobpcg(L, mm, kGeneoLambdaCut, 800,
                                    20260729u + static_cast<unsigned>(si));
          int kept = 0;
          for (int c = 0; c < lob.lambda.size(); ++c) {
            if (lob.lambda(c) < kGeneoLambdaCut)
              ++kept;
            else
              break;
          }
          SubBuild& b = built[si];
          b.ok = true;
          for (int cc = 0; cc < kept; ++cc) {
            CoarseCol col;
            for (int d = 0; d < L.n; ++d) {
              const int kgi = kept_of_gdof[static_cast<std::size_t>(L.gdof[d])];
              if (kgi < 0) continue;
              col.idx.push_back(kgi);
              col.val.push_back(L.D[d] * lob.V(d, cc));
            }
            if (!col.idx.empty()) b.cols.push_back(std::move(col));
          }
        }
      });

  S.cols.clear();
  long long bytes = 0;
  for (std::size_t si = 0; si < built.size(); ++si) {
    if (!built[si].ok) continue;
    for (auto& col : built[si].cols) {
      bytes += static_cast<long long>(col.idx.size()) * (4 + 8);
      S.cols.push_back(std::move(col));
    }
  }
  S.Nt = static_cast<int>(S.cols.size());
  S.basis_bytes = bytes;
  if (bytes > static_cast<long long>(kGeneoMaxBasisMB) * 1024 * 1024) {
    S.cols.clear();
    S.Nt = 0;
    S.basis_bytes = 0;
    return false;
  }
  build_coarse_operator(S, m);
  S.have_basis = true;
  S.structure_fp = structure_fingerprint(m, ctx);
  S.moduli_fp = moduli_fingerprint(ctx);
  S.rebuild_scheduled = false;
  S.ref_pending = true;  // the next solve_end sets the degradation reference
  ++S.builds;
  return true;
}

}  // namespace

bool geneo_enabled() { return g_geneo.enabled; }

bool geneo_set_enabled(bool enable) {
  const bool prev = g_geneo.enabled;
  g_geneo.enabled = enable;
  return prev;
}

void geneo_reset() {
  const bool en = g_geneo.enabled;
  g_geneo = GeneoState{};
  g_geneo.enabled = en;
}

bool geneo_solve_begin(const MatfreeReduced& m, const MfSolveContext& ctx) {
  GeneoState& S = g_geneo;
  S.active = false;
  S.last = GeneoReport{};
  if (!S.enabled || ctx.grid == nullptr) return false;

  const std::uint64_t sfp = structure_fingerprint(m, ctx);
  if (S.have_basis && sfp != S.structure_fp) {
    // DOF-set changed (rung/grid/BC change, an AD mask flip): the basis columns
    // index a different kept set and are meaningless — drop, and let the trigger
    // policy decide whether the NEW system stagnates before paying a build.
    S.cols.clear();
    S.Nt = 0;
    S.basis_bytes = 0;
    S.have_basis = false;
    S.rebuild_scheduled = false;
    S.ref_iters = -1;
    S.ref_pending = false;
  }
  if (!S.have_basis) return false;

  if (S.rebuild_scheduled) {
    // Degradation trigger fired on a previous solve: pay the full eigensolve now.
    if (!build_basis(S, m, ctx)) {
      S.mem_refused_fp = sfp;
      S.last.action = 4;
      return false;
    }
    S.last.action = 3;
    S.last.dim = S.Nt;
    S.active = true;
    return true;
  }

  const std::uint64_t mfp = moduli_fingerprint(ctx);
  if (mfp != S.moduli_fp) {
    // Same DOF set, moved moduli: REFRESH the cheap coarse operator so the
    // deflation is consistent with the current A (mandatory — phase 2 §P6).
    build_coarse_operator(S, m);
    S.moduli_fp = mfp;
    ++S.refreshes;
    S.last.action = 2;
  } else {
    S.last.action = 1;
  }
  S.last.dim = S.Nt;
  S.active = true;
  return true;
}

bool geneo_build_now(const MatfreeReduced& m, const MfSolveContext& ctx,
                     int iterations_burned) {
  GeneoState& S = g_geneo;
  if (!S.enabled || ctx.grid == nullptr) return false;
  const std::uint64_t sfp = structure_fingerprint(m, ctx);
  if (S.mem_refused_fp != 0 && sfp == S.mem_refused_fp) return false;
  if (!build_basis(S, m, ctx)) {
    S.mem_refused_fp = sfp;  // pay the wasted build at most once per structure
    S.last.action = 4;
    return false;
  }
  S.last.action = 3;
  S.last.dim = S.Nt;
  S.last.trigger_burn = iterations_burned;
  S.active = true;
  return true;
}

void geneo_apply(const double* r, double* z) {
  GeneoState& S = g_geneo;
  const int Nt = S.Nt;
  if (!S.active || Nt == 0) return;
  for (int p = 0; p < Nt; ++p) {
    const CoarseCol& cp = S.cols[p];
    double s = 0;
    for (std::size_t t = 0; t < cp.idx.size(); ++t)
      s += cp.val[t] * r[cp.idx[t]];
    S.ccoarse[p] = s;
  }
  VectorXd c(Nt);
  for (int p = 0; p < Nt; ++p) c(p) = S.ccoarse[p];
  const VectorXd cc = S.coarse_dense ? VectorXd(S.coarse_ldlt.solve(c))
                                     : coarse_inner_cg(S, c);
  for (int p = 0; p < Nt; ++p) {
    const CoarseCol& cp = S.cols[p];
    const double v = cc(p);
    for (std::size_t t = 0; t < cp.idx.size(); ++t)
      z[cp.idx[t]] += v * cp.val[t];
  }
}

void geneo_solve_end(int iterations, bool converged) {
  GeneoState& S = g_geneo;
  if (!S.enabled || !S.active) return;
  ++S.armed_solves;
  if (S.ref_pending) {
    // First (or freshly-rebuilt) deflated solve: its count is the degradation
    // reference. Only a CONVERGED solve is evidence (the recycle discipline).
    if (converged) {
      S.ref_iters = iterations;
      S.ref_pending = false;
    }
  } else if (S.ref_iters > 0 && S.last.action != 3 &&
             static_cast<double>(iterations) >
                 kGeneoRebuildFactor * static_cast<double>(S.ref_iters)) {
    // The design moved faster than the held basis can represent: this solve was
    // still EXACT (only slower); rebuild before the next one.
    S.rebuild_scheduled = true;
  }
  S.active = false;
}

GeneoReport geneo_last_report() { return g_geneo.last; }

long long geneo_basis_builds() { return g_geneo.builds; }
long long geneo_coarse_refreshes() { return g_geneo.refreshes; }
long long geneo_armed_solves() { return g_geneo.armed_solves; }
int geneo_basis_dim() { return g_geneo.Nt; }
std::size_t geneo_basis_bytes() {
  return static_cast<std::size_t>(g_geneo.basis_bytes);
}

}  // namespace fea_detail
}  // namespace topopt
