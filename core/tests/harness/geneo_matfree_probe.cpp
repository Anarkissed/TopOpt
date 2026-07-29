// geneo_matfree_probe.cpp — Phase-0 harness: can the GenEO local eigenproblem be
// solved MATRIX-FREE (LOBPCG, no shift-and-invert factorization)?
//
// NOT a CI test, NOT in CTest, NOT linked into any production path. ZERO new build
// dependency: uses only the already-present Homebrew Eigen (dense) plus the production
// library libtopopt.a. No SLEPc, no HPDDM, no Spectra, no ARPACK. The LOBPCG solver is
// implemented here from scratch; the only "factorized" object anywhere is the DENSE
// reference eigensolver, which is HARNESS-ONLY ground truth (bar B4).
//
// THE ONE QUESTION (task ★): GenEO needs the sub-threshold modes of a local generalized
// eigenproblem. Posed for a Krylov eigensolver they are the HARD (small-magnitude) end,
// whose standard route is shift-and-invert — a factorization we cannot afford at 8M DOF.
// LOBPCG needs only A.x, B.x and a preconditioner, all of which we have matrix-free.
// Whether it recovers ALL sub-threshold modes at 1e9 contrast WITHOUT shift-and-invert
// is the crux this harness measures.
//
// THE PENCIL (arXiv 1912.13225 Def 3.1, == the task's pencil):
//     (D_i A_i D_i) V = tau A_i^Neu V ,   coarse space keeps tau > tau_thr (largest).
// Equivalently the SMALLEST eigenvalues of the reciprocal
//     A_i^Neu V = lambda (D_i A_i D_i) V ,   lambda = 1/tau ,  keep lambda < 1/tau_thr,
// which is exactly HPDDM/SLEPc's shift-invert target. We use the standard partition-of-
// unity Neumann variant A_i := A_i^Neu (the survey's "A_ovlp = D A^Neu D" form), so both
// pencil operators are element-local matrix-free applies over the agglomerate:
//     A^Neu . x   = sum_{e in agg} E_e (Ke . x_e)              (Ke = one ref 24x24)
//     (D A^Neu D) . x = D o ( A^Neu . (D o x) )                (D = PoU diagonal)
// no assembled n-by-n matrix, no factorization.
//
// KEY STRUCTURE. A^Neu has an EXACT 6-dim rigid-body kernel even under soft-void SIMP
// (rigid motion => zero strain in every element for ANY positive modulus field), so the
// 6 rigid modes are lambda=0 eigenpairs with FINITE mass (D A^Neu D . rigid != 0). Hence
// LOBPCG-smallest is well posed on the wanted subspace; the contrast-induced modes sit
// just above at small lambda>0. This is the whole reason a matrix-free route is even a
// candidate — verified by the dense reference (self-check: exactly 6 lambda~0).
//
// BUILD (library built Release first; matches spectral_coarse_probe):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//       core/tests/harness/geneo_matfree_probe.cpp core/build/libtopopt.a \
//       -o core/build/geneo_matfree_probe
// RUN: ./core/build/geneo_matfree_probe <selfcheck|measure|all> [csvdir]
//
// DETERMINISM. Mode counts, eigenvalues, subspace angles, matvec counts are deterministic
// (LOBPCG seeded from a fixed PRNG). Wall time is reported but NOT load-bearing; the
// currency for cost is the matvec count (implementation-independent).

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
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

// -------- development physics (production recipe, same as spectral_coarse_probe) -------
constexpr double kE0 = 3500.0;   // PLA, MPa
constexpr double kNu = 0.33;
constexpr int kSimpP = 3;
constexpr double kRhoMinProd = 1e-3;  // production void floor
constexpr double kH = 1.0;            // voxel edge (mm)

// -------------------------------------------------------------------------------------
struct System {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::string name;
};

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

// Run the production OC recipe and return the DEVELOPED physical density field.
std::vector<double> develop_field(const System& S, double rung, int iters) {
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
  }
  return f.filter_density(x);
}

// -------- reference 24x24 unit element stiffness (E=1) --------------------------------
Eigen::Matrix<double, 24, 24> unit_k0() {
  const Hex8Stiffness k = hex8_stiffness(1.0, kNu, kH);
  Eigen::Matrix<double, 24, 24> K0;
  for (int r = 0; r < 24; ++r)
    for (int c = 0; c < 24; ++c) K0(r, c) = k(r, c);
  return K0;
}

// Modulus of a voxel at a given CONTRAST kappa: E = max(rho^p, 1/kappa), Emax=1 => the
// solid-to-void modulus ratio is exactly kappa. kappa=1e9 reproduces production
// (rho_min=1e-3 => rho_min^3 = 1e-9 floor).
inline double efac_contrast(double rho, double kappa) {
  const double r = std::min(1.0, std::max(0.0, rho));
  return std::max(r * r * r, 1.0 / kappa);
}

struct Block { int x0, x1, y0, y1, z0, z1; };  // half-open element ranges

Block agglomerate(const Block& core, int ov, const VoxelGrid& g) {
  return Block{std::max(0, core.x0 - ov), std::min(g.nx, core.x1 + ov),
               std::max(0, core.y0 - ov), std::min(g.ny, core.y1 + ov),
               std::max(0, core.z0 - ov), std::min(g.nz, core.z1 + ov)};
}

// -------------------------------------------------------------------------------------
// Local subdomain: element-local matrix-free operators + geometry, in a compact local
// DOF numbering. Built ONCE per (agglomerate, contrast). This is the "matrix-free"
// object — it stores element topology + per-element modulus + the shared 24x24 K0, and
// the PoU diagonal. It NEVER forms an n-by-n matrix.
// -------------------------------------------------------------------------------------
struct LocalOp {
  int n = 0;                              // local free DOF count
  std::vector<std::array<int, 24>> edof;  // per element, its 24 local DOF indices
  std::vector<double> eE;                 // per element modulus
  std::vector<double> D;                  // PoU diagonal, length n (in (0,1])
  std::vector<double> diagNeu;            // diag(A^Neu), length n (for Jacobi precond)
  std::vector<double> nodeXYZ;            // 3*nnode local, node coords (for rigid modes)
  std::vector<int> dofNode;              // length n: node id of each local DOF
  std::vector<int> dofComp;             // length n: component (0/1/2) of each local DOF
  const Eigen::Matrix<double, 24, 24>* K0 = nullptr;

  // y = A^Neu . x
  VectorXd applyNeu(const VectorXd& x) const {
    VectorXd y = VectorXd::Zero(n);
    Eigen::Matrix<double, 24, 1> xe, ye;
    for (std::size_t e = 0; e < edof.size(); ++e) {
      const auto& d = edof[e];
      for (int a = 0; a < 24; ++a) xe(a) = x(d[a]);
      ye.noalias() = (*K0) * xe;
      const double E = eE[e];
      for (int a = 0; a < 24; ++a) y(d[a]) += E * ye(a);
    }
    return y;
  }
  // y = (D A^Neu D) . x
  VectorXd applyDad(const VectorXd& x) const {
    VectorXd dx(n);
    for (int i = 0; i < n; ++i) dx(i) = D[i] * x(i);
    VectorXd y = applyNeu(dx);
    for (int i = 0; i < n; ++i) y(i) *= D[i];
    return y;
  }
  // block applies (columns)
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
};

// Global matvec counter (the cost currency for E4).
struct MatvecCount { long long neu = 0, dad = 0; long long total() const { return neu + dad; } };
MatvecCount g_mv;

// Build the LocalOp for an agglomerate at a given contrast.
LocalOp build_local(const VoxelGrid& g, const std::vector<double>& rho, const Block& agg,
                    int ov, double kappa, const Eigen::Matrix<double, 24, 24>& K0,
                    const std::vector<char>& fixed_dof_lut) {
  LocalOp L;
  L.K0 = &K0;
  // Local DOF map over non-fixed DOFs touched by agglomerate elements.
  std::unordered_map<int, int> lmap;
  lmap.reserve(8192);
  std::unordered_map<int, int> nmap;  // global node -> local node
  nmap.reserve(4096);
  auto local_dof = [&](int gdof) -> int {
    if (fixed_dof_lut[static_cast<std::size_t>(gdof)]) return -1;
    auto it = lmap.find(gdof);
    if (it != lmap.end()) return it->second;
    const int id = static_cast<int>(lmap.size());
    lmap.emplace(gdof, id);
    return id;
  };
  // First pass: register DOFs / nodes so local ids are stable, and collect element edof.
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
        if (!any) continue;  // fully fixed element (won't happen in interior box)
        L.edof.push_back(d);
        L.eE.push_back(efac_contrast(rho[g.index(i, j, k)], kappa));
      }
  L.n = static_cast<int>(lmap.size());

  // dof -> node/component, and node coords. Recover node from gdof = 3*node+comp.
  L.dofNode.assign(L.n, -1);
  L.dofComp.assign(L.n, -1);
  std::unordered_map<int, int> gnode_to_local;
  for (const auto& kv : lmap) {
    const int gdof = kv.first, ld = kv.second;
    const int gnode = gdof / 3, comp = gdof % 3;
    auto it = gnode_to_local.find(gnode);
    int lnode;
    if (it == gnode_to_local.end()) { lnode = static_cast<int>(gnode_to_local.size()); gnode_to_local.emplace(gnode, lnode); }
    else lnode = it->second;
    L.dofNode[ld] = lnode; L.dofComp[ld] = comp;
  }
  const int nnode = static_cast<int>(gnode_to_local.size());
  L.nodeXYZ.assign(3 * nnode, 0.0);
  // Recover (a,b,c) node coord from global node index: fea_node_index uses
  // a + (nx+1)*(b + (ny+1)*c). Invert.
  const int Nx = g.nx + 1, Ny = g.ny + 1;
  for (const auto& kv : gnode_to_local) {
    const int gnode = kv.first, lnode = kv.second;
    const int a = gnode % Nx;
    const int b = (gnode / Nx) % Ny;
    const int c = gnode / (Nx * Ny);
    L.nodeXYZ[3 * lnode + 0] = a * g.spacing;
    L.nodeXYZ[3 * lnode + 1] = b * g.spacing;
    L.nodeXYZ[3 * lnode + 2] = c * g.spacing;
  }

  // PoU diagonal D: 1 in the core, linear taper to a floor across the overlap layer.
  // Weight per node = min over axes of (distance to outer agglomerate boundary)/ov,
  // clamped to [wfloor,1]; core nodes (>= ov from every agglomerate boundary that is an
  // overlap, i.e. not a true domain boundary) get 1. Simplicial, standard chi_i.
  const double wfloor = 1.0 / (ov + 1.0);  // avoid exact 0 (keeps D>0 => local system SPD-on-range)
  auto node_weight = [&](double x, double y, double z) -> double {
    // Standard chi_i: 1 in the core, linear taper across the overlap layer to wfloor.
    // Taper only on agglomerate faces that are genuine overlaps (interior of the global
    // grid), not true domain boundaries (where the partition of unity is 1).
    auto axis_w = [&](double p, int lo_elem, int hi_elem, int gmax) -> double {
      double w = 1.0;
      const double pe = p / g.spacing;              // node coordinate in element units
      if (lo_elem > 0)     w = std::min(w, (pe - lo_elem + 0.5) / ov);  // overlap low face
      if (hi_elem < gmax)  w = std::min(w, (hi_elem - pe + 0.5) / ov);  // overlap high face
      return w;
    };
    const double w = std::min({axis_w(x, agg.x0, agg.x1, g.nx),
                               axis_w(y, agg.y0, agg.y1, g.ny),
                               axis_w(z, agg.z0, agg.z1, g.nz)});
    return std::min(1.0, std::max(wfloor, w));
  };
  L.D.assign(L.n, 1.0);
  for (int d = 0; d < L.n; ++d) {
    const int ln = L.dofNode[d];
    L.D[d] = node_weight(L.nodeXYZ[3 * ln + 0], L.nodeXYZ[3 * ln + 1], L.nodeXYZ[3 * ln + 2]);
  }

  // diag(A^Neu) for Jacobi.
  L.diagNeu.assign(L.n, 0.0);
  for (std::size_t e = 0; e < L.edof.size(); ++e) {
    const auto& d = L.edof[e];
    for (int a = 0; a < 24; ++a) if (d[a] >= 0) L.diagNeu[d[a]] += L.eE[e] * K0(a, a);
  }
  return L;
}

std::vector<char> build_fixed_lut(const System& S) {
  const int nd = 3 * fea_node_count(S.grid);
  std::vector<char> lut(static_cast<std::size_t>(nd), 0);
  for (const auto& b : S.bcs) lut[static_cast<std::size_t>(3 * b.node + b.component)] = 1;
  return lut;
}

// -------------------------------------------------------------------------------------
// Dense assembly (REFERENCE ONLY, harness-only ground truth). Forms A^Neu and D A^Neu D
// as dense n-by-n, solves the generalized eigenproblem for the SMALLEST lambda of
//   A^Neu V = lambda (D A^Neu D) V .
// D A^Neu D is singular (kernel = D^{-1}.rigid), so we regularize the RHS with a tiny
// Tikhonov sigma*I; rigid modes stay at lambda=0 exactly (A^Neu.rigid=0). sigma-
// insensitivity is checked in selfcheck().
// -------------------------------------------------------------------------------------
MatrixXd dense_neu(const LocalOp& L) {
  MatrixXd A = MatrixXd::Zero(L.n, L.n);
  const auto& K0 = *L.K0;
  for (std::size_t e = 0; e < L.edof.size(); ++e) {
    const auto& d = L.edof[e];
    const double E = L.eE[e];
    for (int a = 0; a < 24; ++a) {
      if (d[a] < 0) continue;
      for (int b = 0; b < 24; ++b) {
        if (d[b] < 0) continue;
        A(d[a], d[b]) += E * K0(a, b);
      }
    }
  }
  return A;
}
MatrixXd dense_dad(const LocalOp& L, const MatrixXd& Aneu) {
  MatrixXd A = Aneu;
  for (int i = 0; i < L.n; ++i)
    for (int j = 0; j < L.n; ++j) A(i, j) *= L.D[i] * L.D[j];
  return A;
}

struct RefResult {
  VectorXd lambda;   // ascending
  MatrixXd V;        // columns = eigenvectors (DAD-orthonormal-ish)
  int n = 0;
  double sigma = 0;
};

RefResult reference_smallest(const LocalOp& L, double sigma_rel) {
  MatrixXd A = dense_neu(L);
  MatrixXd B = dense_dad(L, A);
  const double tr = B.trace() / L.n;
  const double sigma = sigma_rel * tr;
  for (int i = 0; i < L.n; ++i) B(i, i) += sigma;
  Eigen::GeneralizedSelfAdjointEigenSolver<MatrixXd> ges(A, B, Eigen::ComputeEigenvectors | Eigen::Ax_lBx);
  RefResult R;
  R.lambda = ges.eigenvalues();
  R.V = ges.eigenvectors();
  R.n = L.n;
  R.sigma = sigma;
  return R;
}

// eigenvalues only (faster; for the subdomain surcharge scan).
VectorXd reference_values(const LocalOp& L, double sigma_rel) {
  MatrixXd A = dense_neu(L);
  MatrixXd B = dense_dad(L, A);
  const double sigma = sigma_rel * (B.trace() / L.n);
  for (int i = 0; i < L.n; ++i) B(i, i) += sigma;
  Eigen::GeneralizedSelfAdjointEigenSolver<MatrixXd> ges(A, B, Eigen::EigenvaluesOnly | Eigen::Ax_lBx);
  return ges.eigenvalues();
}

// -------------------------------------------------------------------------------------
// Preconditioners for LOBPCG (approximate (A^Neu)^{-1}).
// -------------------------------------------------------------------------------------
enum class Precond { None, Jacobi, InnerCG };

// Analytic rigid-body modes of the agglomerate (6, DAD-orthonormalized). Span ker(A^Neu).
MatrixXd rigid_modes(const LocalOp& L) {
  const int nnode = static_cast<int>(L.nodeXYZ.size() / 3);
  double cx = 0, cy = 0, cz = 0;
  for (int i = 0; i < nnode; ++i) { cx += L.nodeXYZ[3*i]; cy += L.nodeXYZ[3*i+1]; cz += L.nodeXYZ[3*i+2]; }
  cx /= nnode; cy /= nnode; cz /= nnode;
  MatrixXd Rm = MatrixXd::Zero(L.n, 6);
  for (int d = 0; d < L.n; ++d) {
    const int ln = L.dofNode[d], c = L.dofComp[d];
    const double x = L.nodeXYZ[3*ln] - cx, y = L.nodeXYZ[3*ln+1] - cy, z = L.nodeXYZ[3*ln+2] - cz;
    if (c == 0) Rm(d, 0) = 1.0;             // T_x
    if (c == 1) Rm(d, 1) = 1.0;             // T_y
    if (c == 2) Rm(d, 2) = 1.0;             // T_z
    // R_x : (y->-z, z->y) ; R_y : (x->z, z->-x) ; R_z : (x->-y, y->x)
    if (c == 1) Rm(d, 3) = -z; if (c == 2) Rm(d, 3) = y;
    if (c == 0) Rm(d, 4) = z;  if (c == 2) Rm(d, 4) = -x;
    if (c == 0) Rm(d, 5) = -y; if (c == 1) Rm(d, 5) = x;
  }
  return Rm;
}

// Inner PCG solve of A^Neu w = r with the rigid nullspace projected out each step
// (Jacobi-preconditioned). Emulates using the EXISTING matrix-free CG/MG as an inexact
// local inverse; iter count vs contrast is the E3 circular-dependency probe.
VectorXd inner_pcg(const LocalOp& L, const VectorXd& r_in, const MatrixXd& rigidON, int maxit,
                   long long* neu_mv) {
  auto projout = [&](VectorXd v) {
    // remove components along the (already-orthonormal in l2) rigid space
    for (int c = 0; c < rigidON.cols(); ++c) v -= rigidON.col(c) * (rigidON.col(c).dot(v));
    return v;
  };
  VectorXd r = projout(r_in);
  VectorXd x = VectorXd::Zero(L.n);
  VectorXd z(L.n);
  for (int i = 0; i < L.n; ++i) z(i) = r(i) / std::max(L.diagNeu[i], 1e-300);
  z = projout(z);
  VectorXd p = z;
  double rz = r.dot(z);
  const double r0 = r.norm() + 1e-300;
  for (int it = 0; it < maxit; ++it) {
    VectorXd Ap = L.applyNeu(p); if (neu_mv) ++*neu_mv;
    Ap = projout(Ap);
    const double pap = p.dot(Ap);
    if (pap <= 0) break;
    const double alpha = rz / pap;
    x += alpha * p;
    r -= alpha * Ap;
    if (r.norm() <= 1e-8 * r0) break;
    for (int i = 0; i < L.n; ++i) z(i) = r(i) / std::max(L.diagNeu[i], 1e-300);
    z = projout(z);
    const double rz2 = r.dot(z);
    p = z + (rz2 / rz) * p;
    rz = rz2;
  }
  return projout(x);
}

MatrixXd apply_precond(const LocalOp& L, Precond pc, const MatrixXd& R, const MatrixXd& rigidON,
                       int inner_it) {
  MatrixXd W(L.n, R.cols());
  if (pc == Precond::None) return R;
  if (pc == Precond::Jacobi) {
    for (int c = 0; c < R.cols(); ++c)
      for (int i = 0; i < L.n; ++i) W(i, c) = R(i, c) / std::max(L.diagNeu[i], 1e-300);
    return W;
  }
  for (int c = 0; c < R.cols(); ++c) W.col(c) = inner_pcg(L, R.col(c), rigidON, inner_it, &g_mv.neu);
  return W;
}

// -------------------------------------------------------------------------------------
// B-inner-product orthonormalization of a block S (n x k), robust to rank deficiency:
// returns Q (n x r) with Q^T B Q = I (r <= k), dropping directions with B-norm below
// tol. Needs BS = B.S passed in (so we don't re-apply B). Also returns BQ.
// -------------------------------------------------------------------------------------
struct BOrtho { MatrixXd Q, BQ; int r = 0; };
BOrtho borthonormalize(const MatrixXd& S, const MatrixXd& BS, double tol) {
  MatrixXd G = S.transpose() * BS;  // k x k, = S^T B S
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
  out.Q = S * T;    // n x r, B-orthonormal
  out.BQ = BS * T;
  return out;
}

// -------------------------------------------------------------------------------------
// Block LOBPCG for the m SMALLEST eigenpairs of  A^Neu V = lambda (D A^Neu D) V.
// Uses ONLY matrix-free applies (applyNeu / applyDad) + a preconditioner. No shift,
// no factorization of the pencil. Returns eigenvalues (ascending) + eigenvectors and
// per-iteration residual history.
// -------------------------------------------------------------------------------------
struct LobpcgResult {
  VectorXd lambda;         // m ascending
  MatrixXd V;              // n x m
  int iters = 0;
  bool converged = false;
  std::vector<double> maxres_hist;   // max residual over the target block per iter
  long long neu_mv = 0, dad_mv = 0;  // matvecs consumed
};

LobpcgResult lobpcg_smallest(const LocalOp& L, int m, Precond pc, int inner_it, int maxiter,
                             double rtol, unsigned seed, const MatrixXd* rigidON_in = nullptr) {
  const int n = L.n;
  const long long neu0 = g_mv.neu, dad0 = g_mv.dad;
  auto AN = [&](const MatrixXd& X) { g_mv.neu += X.cols(); return L.applyNeuBlock(X); };
  auto BN = [&](const MatrixXd& X) { g_mv.dad += X.cols(); return L.applyDadBlock(X); };

  MatrixXd rigidON;
  if (rigidON_in) rigidON = *rigidON_in;
  else { rigidON = rigid_modes(L); Eigen::HouseholderQR<MatrixXd> qr(rigidON); rigidON = qr.householderQ() * MatrixXd::Identity(n, 6); }

  std::mt19937 rng(seed);
  std::normal_distribution<double> nd(0, 1);
  MatrixXd X(n, m);
  for (int i = 0; i < n; ++i) for (int c = 0; c < m; ++c) X(i, c) = nd(rng);

  // B-orthonormalize the initial block, then one Rayleigh-Ritz to sort it.
  { BOrtho bo = borthonormalize(X, BN(X), 1e-12); X = bo.Q; }
  MatrixXd AX = AN(X), BX = BN(X);
  {
    MatrixXd Axx = X.transpose() * AX; Axx = 0.5 * (Axx + Axx.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Axx);
    MatrixXd C = es.eigenvectors().leftCols(m);
    X = X * C; AX = AX * C; BX = BX * C;
  }
  VectorXd lam(m);
  for (int c = 0; c < m; ++c) lam(c) = X.col(c).dot(AX.col(c));  // X is B-orthonormal

  LobpcgResult res;
  MatrixXd P, BP;  // previous search block (n x m) and its B-image; A-image recomputed
  bool haveP = false;
  double ascale = 0; for (int i = 0; i < n; ++i) ascale += L.diagNeu[i]; ascale /= n;

  for (int it = 0; it < maxiter; ++it) {
    MatrixXd Rr = AX;
    for (int c = 0; c < m; ++c) Rr.col(c) -= lam(c) * BX.col(c);
    double maxrel = 0;
    for (int c = 0; c < m; ++c) {
      const double denom = std::abs(lam(c)) * BX.col(c).norm() + ascale * X.col(c).norm() + 1e-300;
      maxrel = std::max(maxrel, Rr.col(c).norm() / denom);
    }
    res.maxres_hist.push_back(maxrel);
    res.iters = it;
    if (maxrel < rtol) { res.converged = true; break; }

    MatrixXd W = apply_precond(L, pc, Rr, rigidON, inner_it);
    // Subspace S = [X | W | P]. Only B-images are needed for orthonormalization; the
    // A-image of the orthonormal basis is recomputed once (matrix-free) — robust and
    // cheap at subdomain scale. This keeps the whole eigensolve matrix-free.
    MatrixXd S, BS;
    if (haveP) { S.resize(n, 3*m); BS.resize(n, 3*m); S << X, W, P; BS << BX, BN(W), BP; }
    else       { S.resize(n, 2*m); BS.resize(n, 2*m); S << X, W;    BS << BX, BN(W);      }
    BOrtho bs = borthonormalize(S, BS, 1e-12);
    if (bs.r < m && haveP) {                 // degenerate P: restart without it
      haveP = false; S.resize(n, 2*m); BS.resize(n, 2*m); S << X, W; BS << BX, BN(W);
      bs = borthonormalize(S, BS, 1e-13);
    }
    const int mm = std::min(m, bs.r);
    MatrixXd AQ = AN(bs.Q);
    MatrixXd Ah = bs.Q.transpose() * AQ; Ah = 0.5 * (Ah + Ah.transpose());
    Eigen::SelfAdjointEigenSolver<MatrixXd> es(Ah);
    MatrixXd C = es.eigenvectors().leftCols(mm);
    MatrixXd Xn  = bs.Q  * C;
    MatrixXd AXn = AQ    * C;
    MatrixXd BXn = bs.BQ * C;
    if (mm < m) {  // pad (rare): keep old columns for the deficit — will refresh next iter
      MatrixXd Xp(n,m), AXp(n,m), BXp(n,m);
      Xp.leftCols(mm)=Xn; AXp.leftCols(mm)=AXn; BXp.leftCols(mm)=BXn;
      Xp.rightCols(m-mm)=X.rightCols(m-mm); AXp.rightCols(m-mm)=AX.rightCols(m-mm); BXp.rightCols(m-mm)=BX.rightCols(m-mm);
      Xn=Xp; AXn=AXp; BXn=BXp;
      VectorXd lp(m); lp.head(mm)=es.eigenvalues().head(mm); lp.tail(m-mm)=lam.tail(m-mm); lam=lp;
    } else {
      for (int c = 0; c < m; ++c) lam(c) = es.eigenvalues()(c);
    }
    P = Xn - X; BP = BXn - BX; haveP = true;   // Knyazev search direction
    X = Xn; AX = AXn; BX = BXn;
  }
  res.lambda = lam;
  res.V = X;
  res.neu_mv = g_mv.neu - neu0;
  res.dad_mv = g_mv.dad - dad0;
  return res;
}

// -------------------------------------------------------------------------------------
// Scoring: does LOBPCG recover the reference sub-threshold modes? (B3: report misses.)
// For each reference eigenvector v_k with lambda_k below the cut, compute the captured
// energy = || proj_{span(Vlob)} v_k ||_B / ||v_k||_B (B = DAD). A mode is "captured" if
// >= 0.999. Returns count captured / total and the worst per-mode capture.
// -------------------------------------------------------------------------------------
struct Score { int total = 0, captured = 0; double worst_capture = 1.0; double max_lam_err = 0; };

Score score_recovery(const LocalOp& L, const RefResult& ref, const LobpcgResult& lob,
                     double lambda_cut) {
  // Build B-orthonormal basis of LOBPCG subspace.
  MatrixXd Blob = L.applyDadBlock(lob.V);
  BOrtho bo = borthonormalize(lob.V, Blob, 1e-12);
  const MatrixXd& Q = bo.Q; const MatrixXd& BQ = bo.BQ;
  Score s;
  for (int k = 0; k < ref.lambda.size(); ++k) {
    if (ref.lambda(k) >= lambda_cut) break;
    ++s.total;
    VectorXd v = ref.V.col(k);
    // B-normalize v
    VectorXd Bv = L.applyDad(v);
    const double vn = std::sqrt(std::max(v.dot(Bv), 1e-300));
    // projection coefficients onto Q in B-inner-product: c = Q^T B v = BQ^T v
    VectorXd c = BQ.transpose() * v;
    const double proj = c.norm();  // since Q B-orthonormal, ||proj||_B = ||c||
    const double capture = proj / vn;
    s.worst_capture = std::min(s.worst_capture, capture);
    if (capture >= 0.999) ++s.captured;
    // matched eigenvalue error (nearest lob lambda)
    double best = 1e300;
    for (int j = 0; j < lob.lambda.size(); ++j) best = std::min(best, std::abs(lob.lambda(j) - ref.lambda(k)));
    s.max_lam_err = std::max(s.max_lam_err, best / (ref.lambda(k) + 1e-12 + 1e-3 * ref.lambda(ref.lambda.size()-1)));
  }
  return s;
}

long long peak_rss_bytes() {
  struct rusage ru; getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return ru.ru_maxrss;          // bytes on macOS
#else
  return ru.ru_maxrss * 1024;   // KB on Linux
#endif
}

// count reference modes strictly below a lambda cut
int count_below(const RefResult& ref, double cut) {
  int c = 0; for (int k = 0; k < ref.lambda.size(); ++k) { if (ref.lambda(k) < cut) ++c; else break; } return c;
}

// -------------------------------------------------------------------------------------
int selfcheck() {
  std::printf("=== SELF-CHECK (GenEO matrix-free harness) ===\n");
  int fail = 0;
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  System S = build_cantilever(12, 12, 12);
  System F = S; F.bcs.clear();  // free block => visible rigid nullspace
  const std::vector<char> fixed = build_fixed_lut(F);

  // (1) uniform solid block: exactly 6 rigid modes at lambda~0, clean gap after.
  {
    std::vector<double> rho(F.grid.voxel_count(), 1.0);
    Block core{3, 9, 3, 9, 3, 9};
    Block agg = agglomerate(core, 1, F.grid);
    LocalOp L = build_local(F.grid, rho, agg, 1, 1e9, K0, fixed);
    RefResult r = reference_smallest(L, 1e-10);
    int nzero = 0; for (int k = 0; k < r.lambda.size() && r.lambda(k) < 1e-8; ++k) ++nzero;
    const double gap = r.lambda(6) / std::max(r.lambda(5), 1e-30);
    std::printf("  uniform solid : n=%d lam[0..7]=%.2e %.2e %.2e %.2e %.2e %.2e | %.2e %.2e  #(<1e-8)=%d  %s\n",
                L.n, r.lambda(0), r.lambda(1), r.lambda(2), r.lambda(3), r.lambda(4), r.lambda(5),
                r.lambda(6), r.lambda(7), nzero, nzero == 6 ? "PASS(6 rigid)" : "FAIL");
    if (nzero != 6) ++fail;
    (void)gap;

    // rigid modes analytic vs reference lambda~0 subspace: capture >= 0.999
    MatrixXd Rm = rigid_modes(L);
    MatrixXd BR = L.applyDadBlock(Rm);
    BOrtho bo = borthonormalize(Rm, BR, 1e-12);
    double worst = 1.0;
    for (int k = 0; k < 6; ++k) {
      VectorXd v = r.V.col(k); VectorXd Bv = L.applyDad(v);
      const double vn = std::sqrt(std::max(v.dot(Bv), 1e-300));
      VectorXd c = bo.BQ.transpose() * v; worst = std::min(worst, c.norm() / vn);
    }
    std::printf("  analytic rigid modes capture ref lambda~0 space: worst=%.6f  %s\n",
                worst, worst > 0.999 ? "PASS" : "FAIL");
    if (worst <= 0.999) ++fail;
  }

  // (2) sigma-insensitivity of the reference: wanted count stable across sigma decades.
  {
    std::vector<double> rho(F.grid.voxel_count(), 1.0);
    for (int k = 0; k < 3; ++k) for (int j = 0; j < 3; ++j) for (int i = 0; i < 3; ++i) {
      rho[F.grid.index(4+i,4+j,4+k)] = kRhoMinProd;  // a soft pocket => contrast modes
    }
    Block core{3,9,3,9,3,9}; Block agg = agglomerate(core,1,F.grid);
    LocalOp L = build_local(F.grid, rho, agg, 1, 1e9, K0, fixed);
    const double cut = 1e-3;
    int c1 = count_below(reference_smallest(L, 1e-8), cut);
    int c2 = count_below(reference_smallest(L, 1e-10), cut);
    int c3 = count_below(reference_smallest(L, 1e-12), cut);
    std::printf("  sigma-insensitivity #(<%.0e): sigma1e-8=%d 1e-10=%d 1e-12=%d  %s\n",
                cut, c1, c2, c3, (c1==c2 && c2==c3) ? "PASS" : "FAIL");
    if (!(c1==c2 && c2==c3)) ++fail;
  }

  // (3) LOBPCG (matrix-free, Jacobi) recovers the SUBSPACE of the smallest modes of a
  //     mildly heterogeneous block (kappa 1e3). Scored by B-inner-product capture
  //     (the real B3 metric), not raw eigenvalue error (meaningless for lambda~0).
  {
    std::vector<double> rho(F.grid.voxel_count(), 1.0);
    for (int k=0;k<3;++k) for (int j=0;j<3;++j) for (int i=0;i<3;++i) rho[F.grid.index(4+i,4+j,4+k)] = 0.3;
    Block core{3,9,3,9,3,9}; Block agg = agglomerate(core,1,F.grid);
    LocalOp L = build_local(F.grid, rho, agg, 1, 1e3, K0, fixed);
    RefResult r = reference_smallest(L, 1e-10);
    const double cut = 0.5 * (r.lambda(11) + r.lambda(12));  // between mode 12 and 13
    LobpcgResult lob = lobpcg_smallest(L, 20, Precond::Jacobi, 0, 400, 1e-7, 12345);
    Score s = score_recovery(L, r, lob, cut);
    std::printf("  LOBPCG smallest-12 (kappa1e3): conv=%d iters=%d captured=%d/%d worst_capture=%.5f  %s\n",
                lob.converged, lob.iters, s.captured, s.total, s.worst_capture,
                (s.captured == s.total && s.worst_capture > 0.999) ? "PASS" : "FAIL");
    std::printf("    ref  lambda[0..13]: "); for (int k=0;k<14;++k) std::printf("%.3e ", r.lambda(k)); std::printf("\n");
    std::printf("    lob  lambda[0..13]: "); for (int k=0;k<14 && k<lob.lambda.size();++k) std::printf("%.3e ", lob.lambda(k)); std::printf("\n");
    if (!(s.captured == s.total && s.worst_capture > 0.999)) ++fail;
  }

  std::printf("SELF-CHECK: %s\n\n", fail == 0 ? "ALL PASS" : "FAILURES PRESENT");
  return fail;
}

// -------------------------------------------------------------------------------------
// Find the real agglomerate with the largest HIGH-CONTRAST SURCHARGE: the most
// generalized eigenvalues in the contrast band (1e-8, surcharge_cut) BEYOND the 6 rigid.
// These are the near-null modes a near-disconnection through soft void creates — the
// modes the contrast-independence guarantee hinges on (B3), and the hard case for the
// eigensolver. Uses a dense eigenvalues-only reference per candidate (small n).
struct Pick { Block core; int surcharge = 0; int below = 0; int n = 0; double solid_frac = 0; };
Pick pick_surcharge(const VoxelGrid& g, const std::vector<double>& rho, int coreSz, int ov,
                    const Eigen::Matrix<double,24,24>& K0, const std::vector<char>& fixed,
                    double kappa, double surcharge_cut) {
  Pick best; best.surcharge = -1;
  auto solidf = [&](const Block& a){ long long s=0,t=0; for(int k=a.z0;k<a.z1;++k)for(int j=a.y0;j<a.y1;++j)for(int i=a.x0;i<a.x1;++i){++t; if(rho[g.index(i,j,k)]>0.5)++s;} return t? (double)s/t:0.0; };
  for (int z = 0; z + coreSz <= g.nz; z += coreSz)
    for (int y = 0; y + coreSz <= g.ny; y += coreSz)
      for (int x = 0; x + coreSz <= g.nx; x += coreSz) {
        Block core{x,x+coreSz,y,y+coreSz,z,z+coreSz};
        Block agg = agglomerate(core, ov, g);
        const double sf = solidf(agg);
        if (sf < 0.10 || sf > 0.95) continue;
        LocalOp L = build_local(g, rho, agg, ov, kappa, K0, fixed);
        if (L.n < 100) continue;
        VectorXd ev = reference_values(L, 1e-10);
        int below = 0; for (int k = 0; k < ev.size() && ev(k) < surcharge_cut; ++k) ++below;
        const int surcharge = below - 6;  // beyond the 6 rigid
        if (surcharge > best.surcharge) { best.surcharge = surcharge; best.below = below; best.core = core; best.n = L.n; best.solid_frac = sf; }
      }
  return best;
}

int measure(const std::string& csvdir) {
  const Eigen::Matrix<double, 24, 24> K0 = unit_k0();
  std::FILE* f_e1 = std::fopen((csvdir + "/e1_recovery.csv").c_str(), "w");
  std::FILE* f_e2 = std::fopen((csvdir + "/e2_contrast.csv").c_str(), "w");
  std::FILE* f_e3 = std::fopen((csvdir + "/e3_precond.csv").c_str(), "w");
  std::FILE* f_e4 = std::fopen((csvdir + "/e4_cost.csv").c_str(), "w");
  std::FILE* f_sp = std::fopen((csvdir + "/spectrum.csv").c_str(), "w");
  if (f_e1) std::fprintf(f_e1, "case,kappa,n,block_m,lambda_cut,ref_below,captured,worst_capture,max_lam_relerr,iters,converged\n");
  if (f_e2) std::fprintf(f_e2, "kappa,n,ref_rigid,ref_below_cut,cut,block_m,precond,iters,converged,captured,ref_below,worst_capture,neu_mv,dad_mv,maxres_final\n");
  if (f_e3) std::fprintf(f_e3, "kappa,precond,inner_it,iters,converged,captured,ref_below,worst_capture,neu_mv,dad_mv,inner_pcg_total_mv\n");
  if (f_e4) std::fprintf(f_e4, "phase,n,nelem,bytes_matfree,bytes_dense,neu_mv,dad_mv,wall_ms,peak_rss_mb\n");
  if (f_sp) std::fprintf(f_sp, "kappa,idx,lambda\n");

  // --- Develop ONE real field (production recipe), contrast 1e9 ---
  System cant = build_cantilever(32, 16, 32);
  const int fine_dof = 3 * fea_node_count(cant.grid);
  // Lower rung (0.30) => wispier, load-bearing truss-like optimum with thin members that
  // near-disconnect through soft void — where the high-contrast surcharge modes live.
  const double dev_rung = 0.30;
  std::printf("## Real field: cantilever 32x16x32, fine DOF=%d, developing 40 OC iters (rung %.2f)\n", fine_dof, dev_rung);
  std::vector<double> rho = develop_field(cant, dev_rung, 40);
  const std::vector<char> fixed = build_fixed_lut(cant);

  const int coreSz = 6, ov = 1;
  const double surcharge_cut = 0.05;  // contrast band: below the elastic bulk (~0.1)

  // --- Find the real subdomain with the largest high-contrast SURCHARGE (eig-based) ---
  std::printf("## Scanning core-6 ov-1 agglomerates for the largest high-contrast surcharge (modes in (1e-8,%.0e) beyond 6 rigid) @ kappa=1e9...\n", surcharge_cut);
  Pick hard = pick_surcharge(cant.grid, rho, coreSz, ov, K0, fixed, 1e9, surcharge_cut);
  std::printf("   picked core=[%d,%d)x[%d,%d)x[%d,%d)  n=%d solid_frac=%.2f  modes<%.0e=%d (surcharge beyond rigid=%d)\n",
              hard.core.x0, hard.core.x1, hard.core.y0, hard.core.y1, hard.core.z0, hard.core.z1,
              hard.n, hard.solid_frac, surcharge_cut, hard.below, hard.surcharge);
  Block agg = agglomerate(hard.core, ov, cant.grid);

  // Scoring cut for the "wanted" set: the largest multiplicative gap in (1e-9, 0.2),
  // i.e. the boundary between the wanted cluster (rigid + surcharge) and the elastic bulk.
  auto choose_cut = [&](const RefResult& r) -> double {
    double bestgap = 1, cutpos = surcharge_cut;
    for (int k = 6; k + 1 < r.lambda.size(); ++k) {
      if (r.lambda(k) < 1e-9) continue;
      if (r.lambda(k) > 0.2) break;
      const double gp = r.lambda(k+1) / std::max(r.lambda(k), 1e-30);
      if (gp > bestgap) { bestgap = gp; cutpos = std::sqrt(r.lambda(k) * r.lambda(k+1)); }
    }
    return cutpos;
  };

  // Adversarial channel density: real developed field + a 1-voxel soft-void plane through
  // the core's mid-x, near-disconnecting the block into two halves coupled only through
  // 1e-9 material => ~12 sub-threshold modes at 1e9 (6 global rigid + 6 relative-body).
  // Feature density is real; the channel amplifies a real near-disconnection. Used by the
  // many-mode B3 stress (E1b) and the contrast sweep (E2), where the surcharge is
  // contrast-sensitive (the informative case for "convergence vs contrast").
  std::vector<double> rho_chan = rho;
  {
    const int midx = (agg.x0 + agg.x1) / 2;
    for (int k = agg.z0; k < agg.z1; ++k)
      for (int j = agg.y0; j < agg.y1; ++j)
        rho_chan[cant.grid.index(midx, j, k)] = kRhoMinProd;
  }

  // ========================= E1 (contrast 1e9, headline) =========================
  std::printf("\n## E1: dense reference vs matrix-free LOBPCG on the hardest subdomain, kappa=1e9\n");
  {
    LocalOp L = build_local(cant.grid, rho, agg, ov, 1e9, K0, fixed);
    RefResult r = reference_smallest(L, 1e-10);
    const double cut = choose_cut(r);
    const int below = count_below(r, cut);
    int rigid = 0; for (int k = 0; k < r.lambda.size() && r.lambda(k) < 1e-8; ++k) ++rigid;
    std::printf("   n=%d  rigid(lambda<1e-8)=%d  wanted(lambda<%.2e)=%d\n", L.n, rigid, cut, below);
    std::printf("   ref smallest lambda: ");
    for (int k = 0; k < std::min<int>(16, r.lambda.size()); ++k) std::printf("%.2e ", r.lambda(k));
    std::printf("\n");
    for (int k = 0; k < std::min<int>(40, r.lambda.size()); ++k)
      if (f_sp) std::fprintf(f_sp, "1e9,%d,%.6e\n", k, r.lambda(k));

    const int m = std::max(below + 8, 16);  // block: wanted + buffer
    for (Precond pc : {Precond::Jacobi, Precond::InnerCG}) {
      const int inner = (pc == Precond::InnerCG) ? 20 : 0;
      LobpcgResult lob = lobpcg_smallest(L, m, pc, inner, 300, 1e-6, 20250728);
      Score s = score_recovery(L, r, lob, cut);
      const char* pcn = (pc == Precond::Jacobi) ? "jacobi" : "innerCG20";
      std::printf("   LOBPCG[%s] m=%d: iters=%d conv=%d captured=%d/%d worst_capture=%.4f lam_relerr=%.2e neu_mv=%lld dad_mv=%lld\n",
                  pcn, m, lob.iters, lob.converged, s.captured, s.total, s.worst_capture, s.max_lam_err, lob.neu_mv, lob.dad_mv);
      if (f_e1) std::fprintf(f_e1, "E1,1e9,%d,%d,%.6e,%d,%d,%.6f,%.6e,%d,%d\n",
                             L.n, m, cut, s.total, s.captured, s.worst_capture, s.max_lam_err, lob.iters, lob.converged);
    }
  }

  // ===================== E1b: adversarial HIGH-SURCHARGE B3 stress =====================
  // Real developed density, but a 1-voxel soft-void channel is forced through the core's
  // mid-x plane, near-disconnecting the block into two halves coupled only through 1e-9
  // material. This manufactures ~12 sub-threshold modes (6 global rigid + 6 relative-body)
  // at 1e9 contrast — the many-mode case where "18 of 20" would be a silent failure (B3).
  // Feature density is real; the channel amplifies a real near-disconnection.
  std::printf("\n## E1b: adversarial high-surcharge (real density + inserted soft-void channel), kappa=1e9\n");
  {
    LocalOp L = build_local(cant.grid, rho_chan, agg, ov, 1e9, K0, fixed);
    RefResult r = reference_smallest(L, 1e-10);
    const double cut = choose_cut(r);
    const int below = count_below(r, cut);
    int rigid = 0; for (int k = 0; k < r.lambda.size() && r.lambda(k) < 1e-8; ++k) ++rigid;
    std::printf("   n=%d rigid=%d wanted(lambda<%.2e)=%d\n", L.n, rigid, cut, below);
    std::printf("   ref smallest lambda: "); for (int k=0;k<std::min<int>(20,r.lambda.size());++k) std::printf("%.2e ", r.lambda(k)); std::printf("\n");
    const int m = std::max(below + 8, 20);
    for (Precond pc : {Precond::Jacobi, Precond::InnerCG}) {
      const int inner = (pc == Precond::InnerCG) ? 20 : 0;
      LobpcgResult lob = lobpcg_smallest(L, m, pc, inner, 500, 1e-6, 20250728);
      Score s = score_recovery(L, r, lob, cut);
      const char* pcn = (pc == Precond::Jacobi) ? "jacobi" : "innerCG20";
      std::printf("   LOBPCG[%s] m=%d: iters=%d conv=%d captured=%d/%d worst_capture=%.4f neu_mv=%lld dad_mv=%lld  %s\n",
                  pcn, m, lob.iters, lob.converged, s.captured, s.total, s.worst_capture, lob.neu_mv, lob.dad_mv,
                  (s.captured==s.total && s.worst_capture>0.999) ? "ALL MODES" : "!! MISSED MODES !!");
      if (f_e1) std::fprintf(f_e1, "E1b_surcharge,1e9,%d,%d,%.6e,%d,%d,%.6f,%.6e,%d,%d\n",
                             L.n, m, cut, s.total, s.captured, s.worst_capture, s.max_lam_err, lob.iters, lob.converged);
    }
  }

  // ========================= E2 (contrast sweep) =========================
  std::printf("\n## E2: convergence vs contrast on the SURCHARGE geometry (channel), re-moduli. Jacobi + innerCG20.\n");
  for (double kappa : {1e3, 1e6, 1e9, 1e12}) {
    LocalOp L = build_local(cant.grid, rho_chan, agg, ov, kappa, K0, fixed);
    RefResult r = reference_smallest(L, 1e-10);
    const double cut = choose_cut(r);
    const int below = count_below(r, cut);
    int rigid = 0; for (int k = 0; k < r.lambda.size() && r.lambda(k) < 1e-8; ++k) ++rigid;
    const int m = std::max(below + 8, 16);
    for (int k = 0; k < std::min<int>(40, r.lambda.size()); ++k)
      if (f_sp) std::fprintf(f_sp, "%.0e,%d,%.6e\n", kappa, k, r.lambda(k));
    for (Precond pc : {Precond::Jacobi, Precond::InnerCG}) {
      const int inner = (pc == Precond::InnerCG) ? 20 : 0;
      LobpcgResult lob = lobpcg_smallest(L, m, pc, inner, 400, 1e-6, 20250728);
      Score s = score_recovery(L, r, lob, cut);
      const char* pcn = (pc == Precond::Jacobi) ? "jacobi" : "innerCG20";
      const double finalres = lob.maxres_hist.empty() ? -1 : lob.maxres_hist.back();
      std::printf("   kappa=%.0e n=%d rigid=%d wanted(<%.2e)=%d LOBPCG[%s]: iters=%d conv=%d captured=%d/%d worst=%.4f\n",
                  kappa, L.n, rigid, cut, below, pcn, lob.iters, lob.converged, s.captured, s.total, s.worst_capture);
      if (f_e2) std::fprintf(f_e2, "%.0e,%d,%d,%d,%.6e,%d,%s,%d,%d,%d,%d,%.6f,%lld,%lld,%.3e\n",
                             kappa, L.n, rigid, below, cut, m, pcn, lob.iters, lob.converged, s.captured, s.total,
                             s.worst_capture, lob.neu_mv, lob.dad_mv, finalres);
    }
  }

  // ========================= E3 (preconditioner study, kappa=1e9) =========================
  std::printf("\n## E3: preconditioner @ kappa=1e9 on the SURCHARGE geometry (None / Jacobi / innerCG{5,20,50}). Circular-dep probe = inner PCG iters.\n");
  {
    LocalOp L = build_local(cant.grid, rho_chan, agg, ov, 1e9, K0, fixed);
    RefResult r = reference_smallest(L, 1e-10);
    const double cut = choose_cut(r);
    const int below = count_below(r, cut);
    const int m = std::max(below + 8, 16);
    struct Pc { Precond pc; int inner; const char* name; };
    std::vector<Pc> pcs = {{Precond::None,0,"none"},{Precond::Jacobi,0,"jacobi"},
                           {Precond::InnerCG,5,"innerCG5"},{Precond::InnerCG,20,"innerCG20"},
                           {Precond::InnerCG,50,"innerCG50"}};
    for (auto& p : pcs) {
      LobpcgResult lob = lobpcg_smallest(L, m, p.pc, p.inner, 500, 1e-6, 20250728);
      Score s = score_recovery(L, r, lob, cut);
      // neu_mv includes the inner-PCG applies (the circular-dependency cost of using the
      // matrix-free solver as the eigen-preconditioner); dad_mv is block-apply only.
      const double neu_per_iter = lob.iters > 0 ? (double)lob.neu_mv / lob.iters : 0;
      std::printf("   [%s] iters=%d conv=%d captured=%d/%d worst=%.4f neu_mv=%lld dad_mv=%lld neu/iter=%.0f\n",
                  p.name, lob.iters, lob.converged, s.captured, s.total, s.worst_capture, lob.neu_mv, lob.dad_mv, neu_per_iter);
      if (f_e3) std::fprintf(f_e3, "1e9,%s,%d,%d,%d,%d,%d,%.6f,%lld,%lld,%.0f\n",
                             p.name, p.inner, lob.iters, lob.converged, s.captured, s.total, s.worst_capture,
                             lob.neu_mv, lob.dad_mv, neu_per_iter);
    }
  }

  // ========================= E4 (memory & cost) =========================
  std::printf("\n## E4: memory (matrix-free vs assembled) and cost per subdomain, kappa=1e9\n");
  {
    LocalOp L = build_local(cant.grid, rho, agg, ov, 1e9, K0, fixed);
    const long long nelem = static_cast<long long>(L.edof.size());
    RefResult r4 = reference_smallest(L, 1e-10);
    const int m = std::max(count_below(r4, choose_cut(r4)) + 8, 16);
    // matrix-free footprint: element topology (24 int) + modulus (double) per elem
    //   + D,diagNeu (2*n double) + LOBPCG blocks ~ (X,AX,BX,P,AP,BP,W,AW,BW) ~ 9*n*m double
    const long long bytes_mf = nelem * (24*4 + 8) + 2LL*L.n*8 + 9LL*L.n*m*8 + 576*8;
    // assembled/factorized reference: dense A,B (2*n^2) + eigenvectors (n^2) + solver workspace (~n^2)
    const long long bytes_dense = 4LL*L.n*L.n*8;
    const long long rss0 = peak_rss_bytes();
    struct timespec t0, t1; clockid_t clk = CLOCK_MONOTONIC;
    timespec_get(&t0, TIME_UTC); (void)clk;
    const long long neu0 = g_mv.neu, dad0 = g_mv.dad;
    LobpcgResult lob = lobpcg_smallest(L, m, Precond::Jacobi, 0, 300, 1e-6, 20250728);
    timespec_get(&t1, TIME_UTC);
    const double ms = (t1.tv_sec - t0.tv_sec)*1e3 + (t1.tv_nsec - t0.tv_nsec)/1e6;
    const long long rss1 = peak_rss_bytes();
    std::printf("   n=%d nelem=%lld block_m=%d\n", L.n, nelem, m);
    std::printf("   matrix-free footprint ~= %.2f MB   |   dense assembled+factorized ~= %.2f MB   (ratio %.1fx)\n",
                bytes_mf/1048576.0, bytes_dense/1048576.0, (double)bytes_dense/bytes_mf);
    std::printf("   LOBPCG(jacobi) one-subdomain solve: neu_mv=%lld dad_mv=%lld wall=%.1f ms  process peak RSS=%.0f MB\n",
                lob.neu_mv, lob.dad_mv, ms, rss1/1048576.0);
    if (f_e4) std::fprintf(f_e4, "lobpcg_jacobi_1e9,%d,%lld,%lld,%lld,%lld,%lld,%.1f,%.0f\n",
                           L.n, nelem, bytes_mf, bytes_dense, g_mv.neu-neu0, g_mv.dad-dad0, ms, rss1/1048576.0);
    (void)rss0;
    // Extrapolate to full subdomain count at the real 8.44M-DOF run.
    const double subs_8M = 8.44e6 / std::max(1.0, (double)L.n);
    std::printf("   extrapolation @ 8.44M DOF: ~%.0f subdomains of this size; matrix-free eigensolve peak = %.2f MB (one subdomain at a time; embarrassingly parallel) or %.2f GB (all resident at once)\n",
                subs_8M, bytes_mf/1048576.0, bytes_mf*subs_8M/1073741824.0);
    std::printf("      vs assembled-GenEO per-subdomain %.2f MB * %.0f = %.1f GB resident (the PR230 20-35 GB blocker)\n",
                bytes_dense/1048576.0, subs_8M, bytes_dense*subs_8M/1073741824.0);
  }

  if (f_e1) std::fclose(f_e1);
  if (f_e2) std::fclose(f_e2);
  if (f_e3) std::fclose(f_e3);
  if (f_e4) std::fclose(f_e4);
  if (f_sp) std::fclose(f_sp);
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
    if (selfcheck() != 0) { std::printf("SELF-CHECK FAILED — aborting.\n"); return 1; }
    return measure(csvdir);
  }
  std::printf("usage: %s [selfcheck|measure|all] [csvdir]\n", argv[0]);
  return 2;
}
