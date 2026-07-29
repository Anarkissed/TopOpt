// geneo_twolevel_probe.cpp — Phase-2 harness: WIRE the matrix-free GenEO two-level
// preconditioner into CG and MEASURE it on the case that motivated the campaign —
// the high-contrast design-box rung whose geometric multigrid STAGNATES and falls
// back to tens-of-thousands of full-domain Jacobi-CG iterations.
//
// NOT a CI test, NOT in CTest, NOT linked into any production path. It links the
// production library and, via the DEFAULT-OFF hook added in phase 2
// (fea_detail::mf_set_precond_hook), injects the two-level preconditioner into the
// PRODUCTION matrix-free Jacobi-CG loop (mf_cg_solve) — the exact solve the
// stagnating rung falls back to. The eigensolve/decomposition machinery (Eigen,
// dense reference) lives HERE, in the harness, never in the library. With no hook
// installed the library is byte-for-byte unchanged (bar P1).
//
// THE PRECONDITIONER (task piece 4). A two-level additive Schwarz operator
//   M2^-1 r = V (V^T A V)^-1 (V^T r)  +  sum_i R_i^T A_i^-1 R_i r,
// added to the base Jacobi D^-1 the CG already runs (every term SPD => the compound
// preconditioner is SPD => it changes ITERATIONS, never the converged field or the
// stopping test). V is Phase-1's captured GenEO coarse basis (mapped into the
// reduced kept-DOF space); A = the PRODUCTION reduced operator (MatfreeReduced::
// apply_kgg); A_i = the same operator restricted to overlapping subdomain i, solved
// INEXACTLY (Jacobi sweeps or a capped inner CG — never an exact factorization, never
// a subdomain multigrid: the memory sink and the circular dependency the task rules
// out). The coarse solve is dense-Cholesky where N_t fits and a capped inner CG at
// production extents.
//
// BUILD (library built Release first; OCCT off, tests off):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
//       -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//       core/tests/harness/geneo_twolevel_probe.cpp core/build/libtopopt.a \
//       -o core/build/geneo_twolevel_probe
// RUN: ./core/build/geneo_twolevel_probe <selfcheck|stag|p2|control|amort|healthy|det|byteid> [csvdir]
//
// DETERMINISM. CG iteration counts, coarse dimensions and mode counts are
// deterministic (fixed PRNG seeds, deterministic operator). Wall time is reported
// but NOT load-bearing; the currency for cost is the CG iteration / matvec count.

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <sys/resource.h>

#include <Eigen/Dense>
#include <Eigen/Cholesky>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"  // MatfreeReduced, mf_build_reduced, mf_cg_solve, hook

using namespace topopt;
using topopt::fea_detail::MatfreeReduced;
using topopt::fea_detail::mf_build_reduced;
using topopt::fea_detail::mf_cg_solve;
using topopt::fea_detail::MfSolveContext;
using topopt::fea_detail::MfPrecondHook;
using Eigen::MatrixXd;
using Eigen::VectorXd;

namespace {

// ---------------- production recipe constants (== geneo_coarse_probe) ----------------
constexpr double kE0 = 3500.0;        // PLA, MPa
constexpr double kNu = 0.33;
constexpr int kSimpP = 3;
constexpr double kRhoMinProd = 1e-3;  // production void floor => contrast 1e9
constexpr double kContrast = 1e9;
constexpr double kCertTol = 1e-8;     // production simp.cg_tolerance (the tight gate)
constexpr double kIso = 0.5;

double now_ms() { struct timespec t; timespec_get(&t, TIME_UTC); return t.tv_sec*1e3 + t.tv_nsec/1e6; }
long long peak_rss_bytes() {
  struct rusage ru; getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return ru.ru_maxrss;
#else
  return ru.ru_maxrss * 1024;
#endif
}

// FNV-1a over raw bytes (P1/P8 fingerprints).
struct Fnv { std::uint64_t h = 1469598103934665603ULL;
  void add(const void* p, std::size_t n) { const auto* b = static_cast<const unsigned char*>(p);
    for (std::size_t i=0;i<n;++i){ h ^= b[i]; h *= 1099511628211ULL; } }
  void add_d(double d){ add(&d,sizeof d); }
  void add_i(long long v){ add(&v,sizeof v); }
};

// ---------------- reference unit element stiffness (E=1, at the grid spacing) ----------------
Eigen::Matrix<double, 24, 24> unit_k0(double spacing) {
  const Hex8Stiffness k = hex8_stiffness(1.0, kNu, spacing);
  Eigen::Matrix<double, 24, 24> K0;
  for (int r = 0; r < 24; ++r)
    for (int c = 0; c < 24; ++c) K0(r, c) = k(r, c);
  return K0;
}

struct Block { int x0, x1, y0, y1, z0, z1; };  // half-open ELEMENT ranges

Block agglomerate(const Block& core, int ov, const VoxelGrid& g) {
  return Block{std::max(0, core.x0 - ov), std::min(g.nx, core.x1 + ov),
               std::max(0, core.y0 - ov), std::min(g.ny, core.y1 + ov),
               std::max(0, core.z0 - ov), std::min(g.nz, core.z1 + ov)};
}

// Raw PoU node weight (== geneo_coarse_probe): 1 on the core, linear taper across the
// overlap band, floored at 1/(ov+1) so the local pencil stays non-degenerate.
inline double raw_weight(const Block& core, const Block& agg, const VoxelGrid& g, int ov,
                         double x, double y, double z) {
  const double wfloor = 1.0 / (ov + 1.0);
  auto axis = [&](double p, int c0, int c1, int a0, int a1) -> double {
    const double pe = p / g.spacing;
    if (pe <= c0) { if (a0 == c0) return 1.0;
      const double t = (pe - a0 + 0.5) / static_cast<double>(c0 - a0);
      return std::max(0.0, std::min(1.0, t)); }
    if (pe >= c1) { if (a1 == c1) return 1.0;
      const double t = (a1 - pe + 0.5) / static_cast<double>(a1 - c1);
      return std::max(0.0, std::min(1.0, t)); }
    return 1.0;
  };
  const double w = axis(x, core.x0, core.x1, agg.x0, agg.x1) *
                   axis(y, core.y0, core.y1, agg.y0, agg.y1) *
                   axis(z, core.z0, core.z1, agg.z0, agg.z1);
  return std::max(wfloor, w);
}

// Local subdomain operator (== geneo_coarse_probe's LocalOp) but taking the PER-VOXEL
// MODULUS directly (the same `emod` = penalized_youngs vector the reduced operator m
// uses), so the local A_i is EXACTLY the production operator restricted to the
// agglomerate — no Emax=1 normalization mismatch. Never forms an n-by-n matrix.
struct LocalOp {
  int n = 0;
  std::vector<std::array<int, 24>> edof;
  std::vector<double> eE;        // per-element modulus (== emod[voxel])
  std::vector<double> D;         // PoU diagonal (normalised w_i/W)
  std::vector<double> diagNeu;   // diag(A^Neu) for Jacobi
  std::vector<double> nodeXYZ;
  std::vector<int> dofNode;
  std::vector<int> gdof;         // local -> GLOBAL dof (3*node+comp)
  const Eigen::Matrix<double, 24, 24>* K0 = nullptr;

  void applyNeu(const double* x, double* y) const {
    for (int i = 0; i < n; ++i) y[i] = 0.0;
    Eigen::Matrix<double, 24, 1> xe, ye;
    for (std::size_t e = 0; e < edof.size(); ++e) {
      const auto& d = edof[e];
      for (int a = 0; a < 24; ++a) xe(a) = (d[a] >= 0) ? x[d[a]] : 0.0;
      ye.noalias() = (*K0) * xe;
      const double E = eE[e];
      for (int a = 0; a < 24; ++a) if (d[a] >= 0) y[d[a]] += E * ye(a);
    }
  }
  VectorXd applyNeuV(const VectorXd& x) const {
    VectorXd y(n); applyNeu(x.data(), y.data()); return y;
  }
  VectorXd applyDadV(const VectorXd& x) const {
    VectorXd dx(n); for (int i=0;i<n;++i) dx(i)=D[i]*x(i);
    VectorXd y = applyNeuV(dx); for (int i=0;i<n;++i) y(i)*=D[i]; return y;
  }
  MatrixXd applyNeuBlock(const MatrixXd& X) const {
    MatrixXd Y(n, X.cols()); for (int c=0;c<X.cols();++c) Y.col(c)=applyNeuV(X.col(c)); return Y;
  }
  MatrixXd applyDadBlock(const MatrixXd& X) const {
    MatrixXd Y(n, X.cols()); for (int c=0;c<X.cols();++c) Y.col(c)=applyDadV(X.col(c)); return Y;
  }
  long long bytes() const {
    return static_cast<long long>(edof.size()) * (24 * 4 + 8) +
           static_cast<long long>(n) * (8 * 2 + 4 * 2) +
           static_cast<long long>(nodeXYZ.size()) * 8;
  }
};

struct MatvecCount { long long neu = 0; };
thread_local MatvecCount g_mv;

std::vector<char> build_fixed_lut(const VoxelGrid& g, const std::vector<DirichletBC>& bcs) {
  const int nd = 3 * fea_node_count(g);
  std::vector<char> lut(static_cast<std::size_t>(nd), 0);
  for (const auto& b : bcs) lut[static_cast<std::size_t>(3 * b.node + b.component)] = 1;
  return lut;
}

// Build the LocalOp for subdomain (core -> agg), using per-voxel modulus `emod`.
LocalOp build_local(const VoxelGrid& g, const std::vector<double>& emod, const Block& core,
                    int ov, const Eigen::Matrix<double, 24, 24>& K0,
                    const std::vector<char>& fixed_dof_lut,
                    const std::vector<double>& nodeWglobal) {
  const Block agg = agglomerate(core, ov, g);
  LocalOp L; L.K0 = &K0;
  std::unordered_map<int, int> lmap; lmap.reserve(8192);
  auto local_dof = [&](int gdof) -> int {
    if (fixed_dof_lut[static_cast<std::size_t>(gdof)]) return -1;
    auto it = lmap.find(gdof);
    if (it != lmap.end()) return it->second;
    const int id = static_cast<int>(lmap.size()); lmap.emplace(gdof, id); return id;
  };
  for (int k = agg.z0; k < agg.z1; ++k)
    for (int j = agg.y0; j < agg.y1; ++j)
      for (int i = agg.x0; i < agg.x1; ++i) {
        if (!g.solid(i, j, k)) continue;   // only elements the reduced operator has
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        std::array<int, 24> d{}; bool any = false;
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) {
            const int ld = local_dof(3 * en[a] + c); d[3*a+c] = ld; if (ld >= 0) any = true;
          }
        if (!any) continue;
        L.edof.push_back(d);
        L.eE.push_back(emod[g.index(i, j, k)]);
      }
  L.n = static_cast<int>(lmap.size());
  L.dofNode.assign(L.n, -1); L.gdof.assign(L.n, -1);
  std::unordered_map<int, int> gnode_to_local;
  for (const auto& kv : lmap) {
    const int gd = kv.first, ld = kv.second;
    const int gnode = gd / 3;
    auto it = gnode_to_local.find(gnode); int lnode;
    if (it == gnode_to_local.end()) { lnode = static_cast<int>(gnode_to_local.size()); gnode_to_local.emplace(gnode, lnode); }
    else lnode = it->second;
    L.dofNode[ld] = lnode; L.gdof[ld] = gd;
  }
  const int nnode = static_cast<int>(gnode_to_local.size());
  L.nodeXYZ.assign(3 * nnode, 0.0);
  const int Nx = g.nx + 1, Ny = g.ny + 1;
  std::vector<int> lnode_gnode(nnode, -1);
  for (const auto& kv : gnode_to_local) {
    const int gnode = kv.first, lnode = kv.second;
    const int a = gnode % Nx, b = (gnode / Nx) % Ny, c = gnode / (Nx * Ny);
    L.nodeXYZ[3*lnode+0]=a*g.spacing; L.nodeXYZ[3*lnode+1]=b*g.spacing; L.nodeXYZ[3*lnode+2]=c*g.spacing;
    lnode_gnode[lnode]=gnode;
  }
  L.D.assign(L.n, 1.0);
  for (int d = 0; d < L.n; ++d) {
    const int ln = L.dofNode[d];
    const double x=L.nodeXYZ[3*ln+0], y=L.nodeXYZ[3*ln+1], z=L.nodeXYZ[3*ln+2];
    double w = raw_weight(core, agg, g, ov, x, y, z);
    if (!nodeWglobal.empty()) { const double W = nodeWglobal[static_cast<std::size_t>(lnode_gnode[ln])]; w = (W>0)?w/W:0.0; }
    L.D[d] = w;
  }
  L.diagNeu.assign(L.n, 0.0);
  for (std::size_t e = 0; e < L.edof.size(); ++e) {
    const auto& d = L.edof[e];
    for (int a = 0; a < 24; ++a) if (d[a] >= 0) L.diagNeu[d[a]] += L.eE[e] * K0(a, a);
  }
  return L;
}

std::vector<Block> tile_cores(const VoxelGrid& g, int core) {
  std::vector<Block> cores;
  for (int z = 0; z < g.nz; z += core)
    for (int y = 0; y < g.ny; y += core)
      for (int x = 0; x < g.nx; x += core)
        cores.push_back(Block{x, std::min(g.nx, x+core), y, std::min(g.ny, y+core), z, std::min(g.nz, z+core)});
  return cores;
}

std::vector<double> build_pou_normaliser(const VoxelGrid& g, const std::vector<Block>& cores, int ov) {
  const int nnode = fea_node_count(g);
  std::vector<double> W(static_cast<std::size_t>(nnode), 0.0);
  const int Nx = g.nx + 1, Ny = g.ny + 1;
  for (const Block& core : cores) {
    const Block agg = agglomerate(core, ov, g);
    for (int c = agg.z0; c <= agg.z1; ++c)
      for (int b = agg.y0; b <= agg.y1; ++b)
        for (int a = agg.x0; a <= agg.x1; ++a) {
          const int gnode = a + Nx * (b + Ny * c);
          W[static_cast<std::size_t>(gnode)] += raw_weight(core, agg, g, ov, a*g.spacing, b*g.spacing, c*g.spacing);
        }
  }
  return W;
}

// ---------------- B-orthonormalization + LOBPCG (== geneo_coarse_probe) ----------------
struct BOrtho { MatrixXd Q, BQ; int r = 0; };
BOrtho borthonormalize(const MatrixXd& S, const MatrixXd& BS, double tol) {
  MatrixXd G = S.transpose() * BS; G = 0.5 * (G + G.transpose());
  Eigen::SelfAdjointEigenSolver<MatrixXd> es(G);
  const VectorXd& ev = es.eigenvalues(); const MatrixXd& U = es.eigenvectors();
  const double emax = ev(ev.size()-1);
  BOrtho out; std::vector<int> keep;
  for (int i=0;i<ev.size();++i) if (ev(i) > tol*std::max(emax,1e-300)) keep.push_back(i);
  out.r = static_cast<int>(keep.size()); if (out.r==0) return out;
  MatrixXd T(S.cols(), out.r);
  for (int c=0;c<out.r;++c) T.col(c) = U.col(keep[c]) / std::sqrt(ev(keep[c]));
  out.Q = S*T; out.BQ = BS*T; return out;
}
MatrixXd apply_jacobi(const LocalOp& L, const MatrixXd& R) {
  MatrixXd W(L.n, R.cols());
  for (int c=0;c<R.cols();++c) for (int i=0;i<L.n;++i) W(i,c)=R(i,c)/std::max(L.diagNeu[i],1e-300);
  return W;
}
struct StopSpec { double lambda_cut=0.05; int maxiter=800; };
struct LobpcgResult { VectorXd lambda; MatrixXd V; int iters=0; bool converged=false; long long neu_mv=0; };
int count_below(const VectorXd& lam, double cut) { int c=0; for (int k=0;k<lam.size();++k){ if(lam(k)<cut)++c; else break; } return c; }

LobpcgResult lobpcg(const LocalOp& L, int m, const StopSpec& stop, unsigned seed) {
  const int n = L.n; const long long neu0 = g_mv.neu;
  auto AN = [&](const MatrixXd& X){ g_mv.neu += X.cols(); return L.applyNeuBlock(X); };
  auto BN = [&](const MatrixXd& X){ return L.applyDadBlock(X); };
  m = std::min(m, n);
  std::mt19937 rng(seed); std::normal_distribution<double> nd(0,1);
  MatrixXd X(n,m); for (int i=0;i<n;++i) for (int c=0;c<m;++c) X(i,c)=nd(rng);
  { BOrtho bo = borthonormalize(X, BN(X), 1e-12); X=bo.Q; m=X.cols(); }
  MatrixXd AX=AN(X), BX=BN(X);
  { MatrixXd Axx=X.transpose()*AX; Axx=0.5*(Axx+Axx.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Axx); MatrixXd C=es.eigenvectors().leftCols(m);
    X=X*C; AX=AX*C; BX=BX*C; }
  VectorXd lam(m); for (int c=0;c<m;++c) lam(c)=X.col(c).dot(AX.col(c));
  LobpcgResult res; MatrixXd P,BP; bool haveP=false;
  std::vector<VectorXd> lamH; std::vector<int> belowH;
  for (int it=0; it<stop.maxiter; ++it) {
    MatrixXd Rr=AX; for (int c=0;c<m;++c) Rr.col(c) -= lam(c)*BX.col(c);
    std::vector<double> relres(m); double maxrel=0;
    for (int c=0;c<m;++c){ const double denom=std::max(std::abs(lam(c)),stop.lambda_cut)*BX.col(c).norm()+1e-300;
      relres[c]=Rr.col(c).norm()/denom; maxrel=std::max(maxrel,relres[c]); }
    res.iters=it;
    int below=0; for (int c=0;c<m;++c){ if(lam(c)<stop.lambda_cut)++below; else break; }
    // capture-based stop (== geneo_coarse_probe piece 2)
    const double eig_tol=1e-2; const int W=6; const double frontier_gap=1.5, frontier_rtol=0.1;
    lamH.push_back(lam); belowH.push_back(below);
    bool gap=(below<m)&&(lam(below)>stop.lambda_cut*frontier_gap)&&(relres[below]<frontier_rtol);
    bool settled=gap&&(int)lamH.size()>W; double worstd=0; bool below_const=true;
    if (settled){ const VectorXd& past=lamH[lamH.size()-1-W];
      for (int t=(int)belowH.size()-1-W;t<(int)belowH.size();++t) if(belowH[t]!=below){below_const=false;break;}
      settled=below_const&&(past.size()==lam.size());
      if (settled) for (int c=0;c<=below&&c<m;++c){ const double d=std::abs(lam(c)-past(c))/std::max(std::abs(lam(c)),stop.lambda_cut);
        worstd=std::max(worstd,d); if(d>eig_tol){settled=false;break;} } }
    if (it>=W && settled){ res.converged=true; break; }
    MatrixXd Wm=apply_jacobi(L,Rr); MatrixXd S,BS;
    if (haveP){ S.resize(n,3*m); BS.resize(n,3*m); S<<X,Wm,P; BS<<BX,BN(Wm),BP; }
    else      { S.resize(n,2*m); BS.resize(n,2*m); S<<X,Wm;   BS<<BX,BN(Wm);    }
    BOrtho bs=borthonormalize(S,BS,1e-12);
    if (bs.r<m && haveP){ haveP=false; S.resize(n,2*m); BS.resize(n,2*m); S<<X,Wm; BS<<BX,BN(Wm); bs=borthonormalize(S,BS,1e-13); }
    const int mm=std::min(m,bs.r); MatrixXd AQ=AN(bs.Q);
    MatrixXd Ah=bs.Q.transpose()*AQ; Ah=0.5*(Ah+Ah.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Ah); MatrixXd C=es.eigenvectors().leftCols(mm);
    MatrixXd Xn=bs.Q*C, AXn=AQ*C, BXn=bs.BQ*C;
    if (mm<m){ MatrixXd Xp(n,m),AXp(n,m),BXp(n,m);
      Xp.leftCols(mm)=Xn; AXp.leftCols(mm)=AXn; BXp.leftCols(mm)=BXn;
      Xp.rightCols(m-mm)=X.rightCols(m-mm); AXp.rightCols(m-mm)=AX.rightCols(m-mm); BXp.rightCols(m-mm)=BX.rightCols(m-mm);
      Xn=Xp; AXn=AXp; BXn=BXp;
      VectorXd lp(m); lp.head(mm)=es.eigenvalues().head(mm); lp.tail(m-mm)=lam.tail(m-mm); lam=lp;
    } else for (int c=0;c<m;++c) lam(c)=es.eigenvalues()(c);
    P=Xn-X; BP=BXn-BX; haveP=true; X=Xn; AX=AXn; BX=BXn;
  }
  res.lambda=lam; res.V=X; res.neu_mv=g_mv.neu-neu0; return res;
}

}  // namespace

// ======================================================================================
// The rest (fixture, extraction, the TwoLevelPreconditioner, the measurement modes) is
// appended below; kept in a separate section for readability.
// ======================================================================================
#include "geneo_twolevel_probe_part2.inc"
