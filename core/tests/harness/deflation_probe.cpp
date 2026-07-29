// deflation_probe.cpp — measurement harness (NOT a CI test) for the handoff
// 2026-07-28-deflation-phase0: DEFLATED CG WITH SOLID-COMPONENT RIGID-BODY MODES.
//
// THE IDEA (Jonsthovel, van Gijzen, MacLachlan & Vuik 2011): deflation projects
// the small eigenvalues that stall CG out of the operator by handing CG an
// a-priori subspace U built from the RIGID-BODY MODES of homogeneous-material
// regions. For a near-void/solid SIMP field the natural U is the 6 rigid-body
// modes (3 translations + 3 rotations) of each connected SOLID component.
//
// THE POINT OF PHASE 0 (measurement only, NO production change, B2). We do NOT
// build a production deflated solver. We MEASURE, on REAL per-rung design fields
// (B1), the three numbers that decide whether the method is worth building:
//   D1 ★ HOW MANY MODES? Count connected solid components per rung -> deflation
//        dimension k = 6 * n_components. If small, the k x k coarse solve is
//        cheap; if the design fragments, k grows and the coarse solve becomes the
//        cost. This number decides the method.
//   D2   ITERATION REDUCTION. We do better than a Lanczos estimate: we rebuild
//        the EXACT matrix-free operator A = K(rho) at each real rung's density and
//        run the SAME Jacobi-PCG the production path runs, once plain and once
//        with the additive rigid-body-mode coarse correction
//        M_rec^{-1} = M^{-1} + U E^{-1} U^T,  E = U^T A U,
//        counting iterations to the same 1e-8 relative residual. That IS the
//        deflated-CG iteration count on the real field. A short Lanczos gives the
//        low-spectrum / condition-number cross-check.
//   D3   INTERACTION WITH RECYCLING. The production recycler (armed Jacobi-only,
//        handoff 133, ~45% fewer CG iters) uses the IDENTICAL additive machinery,
//        with U HARVESTED from CG's Lanczos process instead of CONSTRUCTED from
//        components. We measure how much of the low spectrum RBM deflation removes
//        so we can say whether the two compose, duplicate, or conflict.
//   D4   MEMORY: k vectors of length ng + a k x k solve. Reported per rung.
//
// The operator, Jacobi diagonal, RHS and CG stopping test are the library's own
// (fea_matfree.hpp / matfree.cpp), so the baseline column is the production solve
// bit-for-bit; the probe validates this by reproducing mf_cg_solve's iteration
// count with its OWN un-deflated PCG before trusting the deflated delta.
//
// Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I include -I src -I /opt/homebrew/include/eigen3 \
//     -I /opt/homebrew/opt/eigen/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
//     tests/harness/deflation_probe.cpp build/libtopopt.a -o deflation_probe
// Run:  ./deflation_probe load    (loadcase L-bracket ladder, no design box)
//       ./deflation_probe box     (dilute design-box ladder — the recycler regime)
//   env: DF_ARM, DF_NY, DF_T, DF_SPAN override the fixture; DF_CSV_DIR sets output;
//        DF_CONN=6|26 the component connectivity (default 6, face-connected).

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

// Internal (non-installed) headers: the matrix-free operator + its Jacobi-CG. The
// probe reaches into these deliberately so the operator and stopping test it
// measures are the PRODUCTION ones, not a re-implementation.
#include "fea/fea_matfree.hpp"

using namespace topopt;
using topopt::fea_detail::MatfreeReduced;
using topopt::fea_detail::mf_build_reduced;
using topopt::fea_detail::mf_cg_solve;

namespace {

constexpr double kTol = 1e-8;          // production simp.cg_tolerance
constexpr double kIso = 0.5;           // "printed" density threshold
constexpr int kMaxIter = 40000;

// ---------------------------------------------------------------------------
// Fixtures (the same L-bracket the ladder gates and recycle_probe build).
// ---------------------------------------------------------------------------
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h, double hole_frac) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  const double cz = arm * 0.55, cy = ny * 0.5, rr = hole_frac * arm;
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!(i < t || k < t)) continue;
        if (hole_frac > 0.0) {
          const double dz = k + 0.5 - cz, dy = j + 0.5 - cy;
          if (std::sqrt(dz * dz + dy * dy) < rr) continue;
        }
        g.set_tag(i, j, k, VoxelTag::Interior);
      }
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

// ---------------------------------------------------------------------------
// Rebuild the SAME Dirichlet BCs / traction loads the driver used, but on the
// (possibly expanded) solved grid, by reading the tags the driver stamped on it.
// mf_build_reduced then reconstructs the exact operator; the probe self-checks
// this reconstruction by reproducing mf_cg_solve's iteration count.
// ---------------------------------------------------------------------------
void bcs_loads_from_tags(const VoxelGrid& g, std::vector<DirichletBC>& bcs,
                         std::vector<NodalLoad>& loads, const Vec3& traction) {
  bcs.clear();
  std::vector<char> pinned(static_cast<std::size_t>(fea_node_count(g)), 0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (g.tag(i, j, k) != VoxelTag::Fixture) continue;
        for (int dk = 0; dk <= 1; ++dk)
          for (int dj = 0; dj <= 1; ++dj)
            for (int di = 0; di <= 1; ++di) {
              const int node = fea_node_index(g, i + di, j + dj, k + dk);
              if (pinned[node]) continue;
              pinned[node] = 1;
              bcs.push_back({node, 0, 0.0});
              bcs.push_back({node, 1, 0.0});
              bcs.push_back({node, 2, 0.0});
            }
      }
  loads = traction_loads(g, VoxelTag::Load, traction);
}

// SIMP penalized modulus, matching simp_compliance exactly (penalty 3, E0, floor).
std::vector<double> penalized_youngs(const VoxelGrid& g,
                                     const std::vector<double>& density,
                                     double E0, double penalty, double rho_min) {
  std::vector<double> y(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const double rho = std::min(1.0, std::max(rho_min, density[e]));
        y[e] = std::pow(rho, penalty) * E0;
      }
  return y;
}

// ---------------------------------------------------------------------------
// D1: label connected PRINTED (rho > iso) components on the voxel grid. This is
// the pass the flood-fill belt does NOT provide (voxelize.cpp:load_path_connected
// is a single-source reachability BOOLEAN, not a labeler) — B3.
// ---------------------------------------------------------------------------
struct Components {
  std::vector<int> label;   // grid-indexed; -1 for non-printed voxels
  int count = 0;
  std::vector<int> size;    // voxels per component
};

Components label_components(const VoxelGrid& g, const std::vector<double>& density,
                            int connectivity /*6 or 26*/) {
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  Components c;
  c.label.assign(g.voxel_count(), -1);
  auto printed = [&](int i, int j, int k) {
    return g.solid(i, j, k) && density[g.index(i, j, k)] > kIso;
  };
  // Neighbour offsets.
  std::vector<std::array<int, 3>> nb;
  for (int dk = -1; dk <= 1; ++dk)
    for (int dj = -1; dj <= 1; ++dj)
      for (int di = -1; di <= 1; ++di) {
        if (di == 0 && dj == 0 && dk == 0) continue;
        const int man = std::abs(di) + std::abs(dj) + std::abs(dk);
        if (connectivity == 6 && man != 1) continue;   // faces only
        nb.push_back({di, dj, dk});
      }
  std::vector<int> stack;
  for (int k0 = 0; k0 < nz; ++k0)
    for (int j0 = 0; j0 < ny; ++j0)
      for (int i0 = 0; i0 < nx; ++i0) {
        if (!printed(i0, j0, k0)) continue;
        const int idx0 = static_cast<int>(g.index(i0, j0, k0));
        if (c.label[idx0] != -1) continue;
        const int lab = c.count++;
        int sz = 0;
        stack.clear();
        stack.push_back(idx0);
        c.label[idx0] = lab;
        while (!stack.empty()) {
          const int idx = stack.back(); stack.pop_back();
          ++sz;
          const int i = idx % nx, t = idx / nx, j = t % ny, k = t / ny;
          for (const auto& o : nb) {
            const int ii = i + o[0], jj = j + o[1], kk = k + o[2];
            if (ii < 0 || jj < 0 || kk < 0 || ii >= nx || jj >= ny || kk >= nz)
              continue;
            if (!printed(ii, jj, kk)) continue;
            const int nidx = static_cast<int>(g.index(ii, jj, kk));
            if (c.label[nidx] != -1) continue;
            c.label[nidx] = lab;
            stack.push_back(nidx);
          }
        }
        c.size.push_back(sz);
      }
  return c;
}

// ---------------------------------------------------------------------------
// Build the rigid-body-mode deflation basis U over the REDUCED free DOFs.
// 6 modes per component (3 translations + 3 centroid-relative rotations),
// supported on the free DOFs whose node touches that component's printed voxels.
// Columns are modified-Gram-Schmidt orthonormalised; degenerate columns (e.g. a
// one-voxel component's near-linearly-dependent rotations) are dropped in fixed
// order, so k_eff <= 6 * n_components.
// ---------------------------------------------------------------------------
struct RbmBasis {
  int ng = 0;
  int k = 0;                       // surviving columns
  std::vector<double> cols;        // ng * k, column-major
  int raw_k = 0;                   // 6 * n_components before rank drop
  int touched_dofs = 0;            // free DOFs assigned to some component
};

RbmBasis build_rbm(const VoxelGrid& g, const MatfreeReduced& m,
                   const Components& comp) {
  RbmBasis R;
  R.ng = m.ng;
  const int nc = comp.count;
  if (nc == 0) return R;
  const int nxn = g.nx + 1, nyn = g.ny + 1;
  auto node_abc = [&](int node, int& a, int& b, int& cc) {
    a = node % nxn; const int t = node / nxn; b = t % nyn; cc = t / nyn;
  };
  // Assign each free DOF's node to one component (lowest label among adjacent
  // printed voxels); accumulate per-component centroid over assigned nodes.
  std::vector<int> dof_comp(m.ng, -1);
  std::vector<double> cx(nc, 0.0), cy(nc, 0.0), cz(nc, 0.0);
  std::vector<long long> cn(nc, 0);
  auto node_component = [&](int node) -> int {
    int a, b, cc; node_abc(node, a, b, cc);
    int best = -1;
    for (int dk = 0; dk <= 1; ++dk)
      for (int dj = 0; dj <= 1; ++dj)
        for (int di = 0; di <= 1; ++di) {
          const int i = a - di, j = b - dj, k = cc - dk;
          if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz)
            continue;
          if (!g.solid(i, j, k)) continue;
          const int lab = comp.label[g.index(i, j, k)];
          if (lab < 0) continue;
          if (best < 0 || lab < best) best = lab;
        }
    return best;
  };
  for (int kg = 0; kg < m.ng; ++kg) {
    const int gdof = m.kept_global[kg];
    const int node = gdof / 3;
    const int lab = node_component(node);
    dof_comp[kg] = lab;
    if (lab >= 0) {
      int a, b, cc; node_abc(node, a, b, cc);
      // one contribution per node (only on the x-DOF to avoid triple counting)
      if (gdof % 3 == 0) {
        cx[lab] += a; cy[lab] += b; cz[lab] += cc; cn[lab] += 1;
      }
    }
  }
  for (int l = 0; l < nc; ++l)
    if (cn[l] > 0) { cx[l] /= cn[l]; cy[l] /= cn[l]; cz[l] /= cn[l]; }

  // Raw columns: 6 per component. Column order [comp0: Tx Ty Tz Rx Ry Rz, comp1..]
  const int raw_k = 6 * nc;
  R.raw_k = raw_k;
  std::vector<double> raw(static_cast<std::size_t>(m.ng) * raw_k, 0.0);
  int touched = 0;
  for (int kg = 0; kg < m.ng; ++kg) {
    const int lab = dof_comp[kg];
    if (lab < 0) continue;
    ++touched;
    const int gdof = m.kept_global[kg];
    const int node = gdof / 3, dofc = gdof % 3;
    int a, b, cc; node_abc(node, a, b, cc);
    const double rx = a - cx[lab], ry = b - cy[lab], rz = cc - cz[lab];
    const int base = 6 * lab;
    double* col = raw.data();
    auto set = [&](int j, double v) {
      col[static_cast<std::size_t>(j) * m.ng + kg] = v;
    };
    // translations
    if (dofc == 0) set(base + 0, 1.0);
    if (dofc == 1) set(base + 1, 1.0);
    if (dofc == 2) set(base + 2, 1.0);
    // rotations w x r : Rx=(1,0,0)->(0,-rz,ry), Ry->(rz,0,-rx), Rz->(-ry,rx,0)
    if (dofc == 1) set(base + 3, -rz);
    if (dofc == 2) set(base + 3,  ry);
    if (dofc == 0) set(base + 4,  rz);
    if (dofc == 2) set(base + 4, -rx);
    if (dofc == 0) set(base + 5, -ry);
    if (dofc == 1) set(base + 5,  rx);
  }
  R.touched_dofs = touched;

  // Modified Gram-Schmidt with fixed-order rank drop.
  auto dot = [&](const double* u, const double* v) {
    double s = 0.0; for (int i = 0; i < m.ng; ++i) s += u[i] * v[i]; return s;
  };
  std::vector<double> kept;
  kept.reserve(raw.size());
  int kkeep = 0;
  std::vector<double> tmp(m.ng);
  for (int j = 0; j < raw_k; ++j) {
    const double* src = raw.data() + static_cast<std::size_t>(j) * m.ng;
    for (int i = 0; i < m.ng; ++i) tmp[i] = src[i];
    const double n0 = std::sqrt(dot(tmp.data(), tmp.data()));
    if (n0 <= 0.0) continue;
    for (int p = 0; p < kkeep; ++p) {
      const double* q = kept.data() + static_cast<std::size_t>(p) * m.ng;
      const double d = dot(q, tmp.data());
      for (int i = 0; i < m.ng; ++i) tmp[i] -= d * q[i];
    }
    const double n1 = std::sqrt(dot(tmp.data(), tmp.data()));
    if (n1 < 1e-8 * n0) continue;          // rank-deficient — drop in order
    const double inv = 1.0 / n1;
    kept.resize(static_cast<std::size_t>(kkeep + 1) * m.ng);
    double* dst = kept.data() + static_cast<std::size_t>(kkeep) * m.ng;
    for (int i = 0; i < m.ng; ++i) dst[i] = tmp[i] * inv;
    ++kkeep;
  }
  R.k = kkeep;
  R.cols = std::move(kept);
  return R;
}

// ---------------------------------------------------------------------------
// Dense k x k Cholesky (row-major lower) and solve, for E = U^T A U.
// ---------------------------------------------------------------------------
bool chol(std::vector<double>& a, int k) {
  for (int i = 0; i < k; ++i)
    for (int j = 0; j <= i; ++j) {
      double s = a[i * k + j];
      for (int p = 0; p < j; ++p) s -= a[i * k + p] * a[j * k + p];
      if (i == j) {
        if (s <= 0.0) return false;
        a[i * k + j] = std::sqrt(s);
      } else {
        a[i * k + j] = s / a[j * k + j];
      }
    }
  return true;
}
void chol_solve(const std::vector<double>& L, int k, std::vector<double>& x) {
  for (int i = 0; i < k; ++i) {
    double s = x[i];
    for (int p = 0; p < i; ++p) s -= L[i * k + p] * x[p];
    x[i] = s / L[i * k + i];
  }
  for (int i = k - 1; i >= 0; --i) {
    double s = x[i];
    for (int p = i + 1; p < k; ++p) s -= L[p * k + i] * x[p];
    x[i] = s / L[i * k + i];
  }
}

// Coarse operator E = U^T A U (k matvecs) and its Cholesky. Returns false if E is
// not SPD (should not happen for orthonormal U with SPD A, but guarded).
struct Coarse {
  int k = 0;
  std::vector<double> Lchol;         // k x k lower (row-major)
  long long setup_matvecs = 0;
};
bool build_coarse(const MatfreeReduced& m, const RbmBasis& R, Coarse& out) {
  const int k = R.k, ng = R.ng;
  out.k = k;
  if (k == 0) return false;
  std::vector<double> E(static_cast<std::size_t>(k) * k, 0.0);
  std::vector<double> au(ng), col(ng);
  for (int j = 0; j < k; ++j) {
    const double* uj = R.cols.data() + static_cast<std::size_t>(j) * ng;
    m.apply_kgg_raw(uj, au.data());
    ++out.setup_matvecs;
    for (int i = 0; i <= j; ++i) {
      const double* ui = R.cols.data() + static_cast<std::size_t>(i) * ng;
      double s = 0.0; for (int t = 0; t < ng; ++t) s += ui[t] * au[t];
      E[i * k + j] = s; E[j * k + i] = s;
    }
  }
  out.Lchol = E;
  return chol(out.Lchol, k);
}

// ---------------------------------------------------------------------------
// Preconditioned CG matching mf_cg_solve's algorithm and relative-residual test
// (sqrt(rTr/bTb) <= tol), with an OPTIONAL additive coarse correction
// z += U E^{-1} (U^T r). With `R`/`coarse` null this reproduces the production
// Jacobi-CG iteration count (the reconstruction self-check).
// ---------------------------------------------------------------------------
int pcg(const MatfreeReduced& m, const std::vector<double>& b,
        const RbmBasis* R, const Coarse* coarse, double tol, int maxit,
        double& relres_out, std::vector<double>* cg_alpha = nullptr,
        std::vector<double>* cg_beta = nullptr) {
  const int ng = m.ng;
  std::vector<double> x(ng, 0.0), r(b), z(ng), p(ng), Ap(ng);
  const double bnorm2 = [&] {
    double s = 0.0; for (double v : b) s += v * v; return s;
  }();
  if (bnorm2 == 0.0) { relres_out = 0.0; return 0; }

  auto precond = [&](const std::vector<double>& rr, std::vector<double>& zz) {
    for (int i = 0; i < ng; ++i) zz[i] = m.invdiag[i] * rr[i];   // M^{-1}
    if (R && coarse && coarse->k > 0) {                          // + U E^-1 U^T
      const int k = coarse->k;
      std::vector<double> c(k, 0.0);
      for (int j = 0; j < k; ++j) {
        const double* uj = R->cols.data() + static_cast<std::size_t>(j) * ng;
        double s = 0.0; for (int t = 0; t < ng; ++t) s += uj[t] * rr[t];
        c[j] = s;
      }
      chol_solve(coarse->Lchol, k, c);
      for (int j = 0; j < k; ++j) {
        const double* uj = R->cols.data() + static_cast<std::size_t>(j) * ng;
        const double cj = c[j];
        for (int t = 0; t < ng; ++t) zz[t] += cj * uj[t];
      }
    }
  };

  precond(r, z);
  p = z;
  double rz = [&] { double s = 0.0; for (int i = 0; i < ng; ++i) s += r[i] * z[i]; return s; }();
  int it = 0;
  double rr = [&] { double s = 0.0; for (double v : r) s += v * v; return s; }();
  for (; it < maxit; ++it) {
    if (std::sqrt(rr / bnorm2) <= tol) break;
    m.apply_kgg_raw(p.data(), Ap.data());
    double pAp = 0.0; for (int i = 0; i < ng; ++i) pAp += p[i] * Ap[i];
    const double alpha = rz / pAp;
    for (int i = 0; i < ng; ++i) { x[i] += alpha * p[i]; r[i] -= alpha * Ap[i]; }
    precond(r, z);
    const double rz_new = [&] { double s = 0.0; for (int i = 0; i < ng; ++i) s += r[i] * z[i]; return s; }();
    const double beta = rz_new / rz;
    if (cg_alpha) cg_alpha->push_back(alpha);
    if (cg_beta) cg_beta->push_back(beta);
    for (int i = 0; i < ng; ++i) p[i] = z[i] + beta * p[i];
    rz = rz_new;
    rr = [&] { double s = 0.0; for (double v : r) s += v * v; return s; }();
  }
  relres_out = std::sqrt(rr / bnorm2);
  return it;
}

// ---------------------------------------------------------------------------
// Symmetric-tridiagonal eigenvalues by implicit-shift QL (Numerical-Recipes
// tqli, eigenvalues only). d = diagonal (n), e = subdiagonal (n, e[0] unused).
// Both are overwritten; on return d holds the eigenvalues.
// ---------------------------------------------------------------------------
void tqli(std::vector<double>& d, std::vector<double>& e, int n) {
  auto pythag = [](double a, double b) {
    const double aa = std::fabs(a), ab = std::fabs(b);
    if (aa > ab) { const double r = ab / aa; return aa * std::sqrt(1.0 + r * r); }
    if (ab == 0.0) return 0.0;
    const double r = aa / ab; return ab * std::sqrt(1.0 + r * r);
  };
  for (int i = 1; i < n; ++i) e[i - 1] = e[i];
  e[n - 1] = 0.0;
  for (int l = 0; l < n; ++l) {
    int iter = 0, mm;
    do {
      for (mm = l; mm < n - 1; ++mm) {
        const double dd = std::fabs(d[mm]) + std::fabs(d[mm + 1]);
        if (std::fabs(e[mm]) <= 1e-300 + 1e-15 * dd) break;
      }
      if (mm != l) {
        if (iter++ == 60) break;   // no convergence; give what we have
        double g = (d[l + 1] - d[l]) / (2.0 * e[l]);
        double r = pythag(g, 1.0);
        g = d[mm] - d[l] + e[l] / (g + (g >= 0 ? std::fabs(r) : -std::fabs(r)));
        double s = 1.0, c = 1.0, p = 0.0;
        int i;
        for (i = mm - 1; i >= l; --i) {
          double f = s * e[i], bb = c * e[i];
          r = pythag(f, g);
          e[i + 1] = r;
          if (r == 0.0) { d[i + 1] -= p; e[mm] = 0.0; break; }
          s = f / r; c = g / r;
          g = d[i + 1] - p;
          r = (d[i] - g) * s + 2.0 * c * bb;
          p = s * r;
          d[i + 1] = g + p;
          g = c * r - bb;
        }
        if (r == 0.0 && i >= l) continue;
        d[l] -= p; e[l] = g; e[mm] = 0.0;
      }
    } while (mm != l);
  }
}

// Effective spectrum extremes of the (possibly deflated) preconditioned operator,
// reconstructed from the PCG coefficients (the exact CG->Lanczos tridiagonal):
//   T diagonal   d_1 = 1/a_1,  d_j = 1/a_j + b_{j-1}/a_{j-1}
//   T subdiag    e_j = sqrt(b_j)/a_j
// where a_j = CG step length, b_j = CG beta. Eigenvalues of T approximate those
// of M^{-1}A on the Krylov space actually traversed — so lmax/lmin is the
// EFFECTIVE condition number CG saw. Uses the SAME preconditioner the solve ran,
// coarse correction included.
void cg_spectrum_extremes(const std::vector<double>& a,
                          const std::vector<double>& b, double& lmin,
                          double& lmax) {
  const int n = static_cast<int>(a.size());
  if (n == 0) { lmin = lmax = 0.0; return; }
  std::vector<double> d(n), e(n, 0.0);
  d[0] = 1.0 / a[0];
  for (int j = 1; j < n; ++j) d[j] = 1.0 / a[j] + b[j - 1] / a[j - 1];
  for (int j = 0; j < n - 1; ++j) e[j + 1] = std::sqrt(std::max(b[j], 0.0)) / a[j];
  tqli(d, e, n);
  lmin = 1e300; lmax = -1e300;
  for (int j = 0; j < n; ++j) {
    if (!std::isfinite(d[j])) continue;
    lmin = std::min(lmin, d[j]); lmax = std::max(lmax, d[j]);
  }
  if (lmin <= 0.0 || lmin > 1e299) lmin = 0.0;
}

// ---------------------------------------------------------------------------
struct RungResult {
  double vf = 0.0;
  bool accepted = false, infeasible = false, non_convergent = false;
  long long solid = 0, printed = 0;
  int nc6 = 0, nc26 = 0;
  int largest = 0, small_comps = 0;      // small = <1% of printed
  int ng = 0;
  int raw_k = 0, k = 0;                   // deflation dim before/after rank drop
  int iters_base = 0, iters_defl = 0;
  int iters_mf = 0;                       // library baseline (self-check)
  long long setup_mv = 0;
  double lmin_base = 0, lmax_base = 0, lmin_defl = 0, lmax_defl = 0;
  double mem_mb = 0.0;
};

}  // namespace

int main(int argc, char** argv) {
  const std::string which = argc > 1 ? argv[1] : "load";
  const int conn = std::getenv("DF_CONN") ? std::atoi(std::getenv("DF_CONN")) : 6;
  const char* csv_dir = std::getenv("DF_CSV_DIR");
  std::setvbuf(stdout, nullptr, _IOLBF, 0);

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();
  const double E0 = material.youngs_modulus_mpa;
  const double nu = material.poisson;
  const double penalty = 3.0, rho_min = 1e-3;

  // Fixture.
  const double h = 2.0;
  const int arm = std::getenv("DF_ARM") ? std::atoi(std::getenv("DF_ARM"))
                                        : (which == "box" ? 16 : 40);
  const int ny = std::getenv("DF_NY") ? std::atoi(std::getenv("DF_NY"))
                                      : std::max(4, arm / 3);
  const int t = std::getenv("DF_T") ? std::atoi(std::getenv("DF_T"))
                                    : std::max(2, arm / 4);
  const int span = std::getenv("DF_SPAN") ? std::atoi(std::getenv("DF_SPAN")) : arm;

  std::vector<DirichletBC> bcs;
  const bool use_box = (which == "box");
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h, use_box ? 0.16 : 0.0);
  const Vec3 traction{0.0, 0.0, -30.0};
  std::vector<NodalLoad> loads = traction_loads(part, VoxelTag::Load, traction);

  std::printf("===== DEFLATION PROBE [%s] part %dx%dx%d, %zu solid, h=%.1f, conn=%d%s =====\n",
              which.c_str(), part.nx, part.ny, part.nz, part.solid_count(), h,
              conn, use_box ? ", design box" : "");

  // ---- Real per-rung fields: run the production ladder (B1). Gravity OFF so the
  // rebuilt operator/RHS reconstruction is exact and self-checkable.
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = production_reduction_ladder();
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 0.0;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (use_box) {
    DesignBox box;
    box.min = Vec3{0.0, 0.0, 0.0};
    box.max = Vec3{span * h * 2.0, ny * h * 2.0, arm * h * 1.5};
    o.design_box = box;
  }
  // Turn recycling OFF for the field-generating run so baseline numbers are clean.
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();

  MinimizePlasticResult r =
      minimize_plastic(part, material, "fdm", bcs, rules, o);
  const VoxelGrid& g = r.solved_grid;
  std::printf("  solved_grid %dx%dx%d (%zu voxels), rungs evaluated=%zu\n",
              g.nx, g.ny, g.nz, g.voxel_count(), r.evaluated.size());

  // BCs/loads on the solved grid (reconstructed from its tags).
  std::vector<DirichletBC> sbcs;
  std::vector<NodalLoad> sloads;
  bcs_loads_from_tags(g, sbcs, sloads, traction);

  std::vector<RungResult> out;
  for (std::size_t ri = 0; ri < r.evaluated.size(); ++ri) {
    const MinimizePlasticVariant& v = r.evaluated[ri];
    RungResult rr;
    rr.vf = v.requested_volume_fraction;
    rr.accepted = v.accepted;
    rr.infeasible = v.infeasible;
    rr.non_convergent = v.non_convergent;
    const std::vector<double>& density = v.optimization.physical_density;
    if (density.size() != g.voxel_count()) {
      std::printf("  rung vf=%.2f: density size mismatch (%zu vs %zu) — skipped\n",
                  rr.vf, density.size(), g.voxel_count());
      out.push_back(rr);
      continue;
    }
    rr.solid = static_cast<long long>(g.solid_count());
    for (std::size_t e = 0; e < density.size(); ++e)
      if (g.tags[e] != VoxelTag::Empty && density[e] > kIso) ++rr.printed;

    // D1: components.
    Components c6 = label_components(g, density, 6);
    Components c26 = label_components(g, density, 26);
    rr.nc6 = c6.count; rr.nc26 = c26.count;
    for (int s : c6.size) rr.largest = std::max(rr.largest, s);
    const long long small_thresh = std::max<long long>(1, rr.printed / 100);
    for (int s : c6.size) if (s < small_thresh) ++rr.small_comps;

    // Rebuild the exact operator at this rung's density.
    std::vector<double> ey = penalized_youngs(g, density, E0, penalty, rho_min);
    CgInfo info;
    MatfreeReduced m;
    try {
      m = mf_build_reduced(g, E0, nu, sbcs, sloads, &ey, "deflation_probe", &info);
    } catch (const std::exception& e) {
      std::printf("  rung vf=%.2f: operator build threw (%s) — skipped\n", rr.vf, e.what());
      out.push_back(rr);
      continue;
    }
    rr.ng = m.ng;

    // Library baseline (self-check) — production Jacobi-CG iterations.
    {
      std::vector<double> x(m.ng, 0.0);
      int iters = 0; double err = 0; bool conv = false;
      mf_cg_solve(m, kTol, kMaxIter, x, iters, err, conv, nullptr);
      rr.iters_mf = iters;
    }

    // RHS = reduced load vector the operator carries.
    const std::vector<double>& b = m.rg;

    // Baseline PCG (no deflation) — must reproduce iters_mf. Record CG scalars
    // for the effective-spectrum reconstruction.
    double relres = 0.0;
    std::vector<double> a_base, b_base;
    rr.iters_base = pcg(m, b, nullptr, nullptr, kTol, kMaxIter, relres,
                        &a_base, &b_base);

    // Build RBM deflation basis on the chosen connectivity.
    const Components& cc = (conn == 26) ? c26 : c6;
    RbmBasis R = build_rbm(g, m, cc);
    rr.raw_k = R.raw_k; rr.k = R.k;
    rr.mem_mb = (static_cast<double>(R.k) * m.ng * sizeof(double)) / (1024.0 * 1024.0);

    Coarse coarse;
    bool have_coarse = R.k > 0 && build_coarse(m, R, coarse);
    rr.setup_mv = coarse.setup_matvecs;
    std::vector<double> a_defl, b_defl;
    if (have_coarse) {
      rr.iters_defl = pcg(m, b, &R, &coarse, kTol, kMaxIter, relres,
                          &a_defl, &b_defl);
    } else {
      rr.iters_defl = rr.iters_base;
    }

    // Effective-spectrum cross-check from the PCG coefficients (D2).
    cg_spectrum_extremes(a_base, b_base, rr.lmin_base, rr.lmax_base);
    if (have_coarse)
      cg_spectrum_extremes(a_defl, b_defl, rr.lmin_defl, rr.lmax_defl);
    else { rr.lmin_defl = rr.lmin_base; rr.lmax_defl = rr.lmax_base; }

    const double cut = rr.iters_base > 0
        ? 100.0 * (1.0 - double(rr.iters_defl) / double(rr.iters_base)) : 0.0;
    const double kb = rr.lmin_base > 0 ? rr.lmax_base / rr.lmin_base : 0.0;
    const double kd = rr.lmin_defl > 0 ? rr.lmax_defl / rr.lmin_defl : 0.0;
    std::printf("  vf=%.2f %-10s printed=%7lld ng=%7d | comps 6c=%3d 26c=%3d "
                "largest=%.1f%% small=%d | k_raw=%d k=%d setup_mv=%lld mem=%.1fMB "
                "| CG base=%d(mf=%d) defl=%d cut=%.1f%% | kappa %.1f->%.1f\n",
                rr.vf,
                rr.infeasible ? "INFEAS" : rr.non_convergent ? "NONCONV"
                    : rr.accepted ? "accept" : "reject",
                rr.printed, rr.ng, rr.nc6, rr.nc26,
                rr.printed > 0 ? 100.0 * rr.largest / rr.printed : 0.0,
                rr.small_comps, rr.raw_k, rr.k, rr.setup_mv, rr.mem_mb,
                rr.iters_base, rr.iters_mf, rr.iters_defl, cut, kb, kd);
    out.push_back(rr);
  }

  // CSV.
  if (csv_dir) {
    std::string path = std::string(csv_dir) + "/deflation_" + which + ".csv";
    if (FILE* f = std::fopen(path.c_str(), "w")) {
      std::fprintf(f, "vf,status,printed,solid,ng,nc6,nc26,largest_pct,small_comps,"
                      "raw_k,k,setup_mv,mem_mb,iters_base,iters_mf,iters_defl,cut_pct,"
                      "lmin_base,lmax_base,kappa_base,lmin_defl,lmax_defl,kappa_defl\n");
      for (const RungResult& rr : out) {
        const double cut = rr.iters_base > 0
            ? 100.0 * (1.0 - double(rr.iters_defl) / double(rr.iters_base)) : 0.0;
        const double kb = rr.lmin_base > 0 ? rr.lmax_base / rr.lmin_base : 0.0;
        const double kd = rr.lmin_defl > 0 ? rr.lmax_defl / rr.lmin_defl : 0.0;
        std::fprintf(f, "%.2f,%s,%lld,%lld,%d,%d,%d,%.2f,%d,%d,%d,%lld,%.2f,%d,%d,%d,%.2f,"
                        "%.6e,%.6e,%.2f,%.6e,%.6e,%.2f\n",
                     rr.vf,
                     rr.infeasible ? "infeasible" : rr.non_convergent ? "nonconvergent"
                         : rr.accepted ? "accepted" : "rejected",
                     rr.printed, rr.solid, rr.ng, rr.nc6, rr.nc26,
                     rr.printed > 0 ? 100.0 * rr.largest / rr.printed : 0.0,
                     rr.small_comps, rr.raw_k, rr.k, rr.setup_mv, rr.mem_mb,
                     rr.iters_base, rr.iters_mf, rr.iters_defl, cut,
                     rr.lmin_base, rr.lmax_base, kb, rr.lmin_defl, rr.lmax_defl, kd);
      }
      std::fclose(f);
      std::printf("  wrote %s\n", path.c_str());
    }
  }
  return 0;
}
