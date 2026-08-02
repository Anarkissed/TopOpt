// alg_level1_probe.cpp — DOES THE ALGEBRAIC LEVEL-1 COARSE SPACE SURVIVE
// PRODUCTION? (task: algebraic-level1-coarsening)
//
// NOT a CI test, NOT in CTest, NOT linked into any production path. It links the
// production library and drives the PRODUCTION solver through the PUBLIC arming
// dial `fea_set_mg_algebraic_level1`, plus (for the capture rows only) PR 283's
// harness-only coarse-space seam, which is how the GEOMETRIC level-1 operator is
// read out without re-deriving it.
//
// WHAT PR 283 ESTABLISHED, AND WHAT THIS HAS TO SHOW
//   PR 283 measured that the geometric level-1 space captures 1.5954 % of the
//   exact solution's energy on PR 280's stagnating field (99.2959 % on a healthy
//   control), that every space below level 1 is a subspace of it, and that
//   aggregating from the FINE operator lifts capture to 56.3293 % at coarse
//   dimension 13,140 (against the geometric 18,738) and converges in 86 PCG
//   iterations. Those were amg_lean measurements with a Chebyshev fine smoother.
//   THIS probe re-measures them through the shipped solver, whose fine smoother
//   is damped Jacobi — a production path that cannot reproduce the probe is
//   wrong, and the agreement (or the gap) is the point.
//
// THE INSTRUMENT IS PR 283's, NOT A NEW ONE. For SPD A0 and a coarse space
// range(W), the A-orthogonal projection of the exact u onto range(W) is W z with
// (W^T A0 W) z = W^T b, and its energy is z . (W^T b); the exact solution's
// energy is u . b, and the ratio is the fraction the space can represent. The
// implementation below is PR 283's `capture_of` verbatim, and the probe REPORTS
// PR 283's geometric numbers as a CONTROL: if this file does not reproduce
// 1.5954 % and 99.2959 % on the same fields, the instrument has drifted and no
// algebraic number here means anything. That control is checked, not assumed.
//
// *** A0 IS NEVER ASSEMBLED, HERE EITHER. *** The level-1 operator for the
// algebraic space is formed by amg_lean's element-local `fine_galerkin` off the
// production element table — the same kernel PR 283 used — and the probe
// VERIFIES it is the true Galerkin operator of the production prolongator by
// comparing z^T A1 z against (P0 z)^T A0 (P0 z) through the production
// matrix-free apply. The prolongator itself is the PRODUCTION one:
// `fea_detail::alg_level1_prolongator`, the function the solver calls.
//
// BUILD (library built Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src -I core/src/fea \
//       -I core/tests/harness -I /opt/homebrew/include/eigen3 \
//       -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//       core/tests/harness/alg_level1_probe.cpp core/build/libtopopt.a <OCCT libs> \
//       -o core/build/alg_level1_probe
//   (core/src/fea is on the path because amg_lean.hpp includes "fea_matfree.hpp"
//    unqualified; core/tests/harness because this file includes amg_sa.hpp.)
// RUN: ./core/build/alg_level1_probe <capture|converge|mem|det> [dir]
//
// THE FIELD. `capture` and `converge` read the SAME cache file
// mg_component_sweep.cpp writes for PR 280's `ladder32.json` reproduction
// (`<dir>/mg_stepbox_r32.bin`), which is also the file PR 283 read — so all
// three probes measure literally the same trajectory. Produce it with:
//   MG_STEP=core/tests/fixtures/demo/l-bracket.step MG_RES=32 \
//     ./core/build/mg_component_sweep stag <dir>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

#include <sys/resource.h>
#include <unistd.h>

#include <Eigen/Sparse>
#include <Eigen/SparseCholesky>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/voxel.hpp"

#include "fea/algebraic_coarsen.hpp"
#include "fea/fea_matfree.hpp"

#include "amg_sa.hpp"
#include "amg_lean.hpp"

using namespace topopt;
using topopt::fea_detail::AlgCoarsenStats;
using topopt::fea_detail::MatfreeReduced;
using topopt::fea_detail::MgCoarseSeam;
using topopt::fea_detail::MgCoo;

namespace {

using SpMat = Eigen::SparseMatrix<double>;
using Trip = Eigen::Triplet<double>;
using Vec = Eigen::VectorXd;
using i64 = std::int64_t;

// ---------------- production recipe constants (== mg_component_sweep) --------
constexpr double kE0 = 3500.0;        // PLA, MPa
constexpr double kNu = 0.33;
constexpr int kSimpP = 3;
constexpr double kRhoMinProd = 1e-3;  // production void floor => contrast 1e9
constexpr double kCertTol = 1e-8;     // production simp.cg_tolerance

// PR 283's published numbers, quoted here so the probe can CHECK itself against
// them rather than leaving the reader to diff two documents.
constexpr double kPr283GeoCaptureStag = 0.015954;
constexpr double kPr283GeoCaptureHealthy = 0.992959;
constexpr double kPr283AlgCaptureStag = 0.563293;
constexpr int kPr283GeoDimStag = 18738;
constexpr int kPr283AlgDimStag = 13140;
constexpr int kPr283AlgPcgIters = 86;

double now_ms() {
  struct timespec t;
  timespec_get(&t, TIME_UTC);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

// HOST LOAD, recorded rather than assumed away (PR 277's discipline, kept by
// PR 280 and PR 283). This machine runs other campaigns; a wall number read off
// a busy host is indicative, not evidence, and the reader is entitled to see
// which.
void print_load(const char* when) {
  double la[3] = {0, 0, 0};
  if (getloadavg(la, 3) < 0) {
    std::printf("[load %s] unavailable\n", when);
    return;
  }
  std::printf("[load %s] 1m %.2f  5m %.2f  15m %.2f  (on %ld logical cores)\n",
              when, la[0], la[1], la[2], sysconf(_SC_NPROCESSORS_ONLN));
}

double peak_rss_mb() {
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0) return 0.0;
#ifdef __APPLE__
  return static_cast<double>(ru.ru_maxrss) / (1024.0 * 1024.0);  // bytes
#else
  return static_cast<double>(ru.ru_maxrss) / 1024.0;  // KB
#endif
}

// FNV-1a over a field, for the determinism bar.
std::string fingerprint(const std::vector<double>& v) {
  std::uint64_t h = 1469598103934665603ull;
  const unsigned char* p = reinterpret_cast<const unsigned char*>(v.data());
  for (std::size_t i = 0; i < v.size() * sizeof(double); ++i) {
    h ^= p[i];
    h *= 1099511628211ull;
  }
  char buf[32];
  std::snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h));
  return buf;
}

// ============================================================================
// THE FIELD — read from mg_component_sweep's cache, byte format copied verbatim
// from hybrid_amg_probe.cpp so the three probes cannot drift apart.
// ============================================================================
struct Case {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<std::vector<double>> traj;
};

bool cache_load(const std::string& path, Case& C) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  int dims[3];
  double sp;
  std::size_t nb, nl, nt;
  bool ok = std::fread(dims, sizeof(int), 3, f) == 3 &&
            std::fread(&sp, sizeof(double), 1, f) == 1;
  C.grid.nx = dims[0];
  C.grid.ny = dims[1];
  C.grid.nz = dims[2];
  C.grid.spacing = sp;
  C.grid.origin = Vec3{0, 0, 0};
  C.grid.tags.resize(static_cast<std::size_t>(dims[0]) * dims[1] * dims[2]);
  ok = ok && std::fread(C.grid.tags.data(), sizeof(VoxelTag), C.grid.tags.size(),
                        f) == C.grid.tags.size();
  ok = ok && std::fread(&nb, sizeof nb, 1, f) == 1;
  C.bcs.resize(ok ? nb : 0);
  ok = ok && std::fread(C.bcs.data(), sizeof(DirichletBC), nb, f) == nb;
  ok = ok && std::fread(&nl, sizeof nl, 1, f) == 1;
  C.loads.resize(ok ? nl : 0);
  ok = ok && std::fread(C.loads.data(), sizeof(NodalLoad), nl, f) == nl;
  ok = ok && std::fread(&nt, sizeof nt, 1, f) == 1;
  if (ok) {
    C.traj.resize(nt);
    for (std::size_t i = 0; ok && i < nt; ++i) {
      std::size_t n;
      ok = ok && std::fread(&n, sizeof n, 1, f) == 1;
      C.traj[i].resize(ok ? n : 0);
      ok = ok && std::fread(C.traj[i].data(), sizeof(double), n, f) == n;
    }
  }
  std::fclose(f);
  return ok && !C.traj.empty() && C.traj.back().size() == C.grid.voxel_count();
}

std::vector<double> penalized_youngs(const VoxelGrid& g,
                                     const std::vector<double>& dens) {
  std::vector<double> y(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (g.tag(i, j, k) == VoxelTag::Empty) continue;
        const double rho = std::max(kRhoMinProd, dens[e]);
        y[e] = std::pow(rho, kSimpP) * kE0;
      }
  return y;
}

double achieved_vf(const VoxelGrid& g, const std::vector<double>& dens) {
  double s = 0;
  std::size_t n = 0;
  for (std::size_t e = 0; e < dens.size(); ++e)
    if (g.tags[e] != VoxelTag::Empty) {
      s += dens[e];
      ++n;
    }
  return n ? s / static_cast<double>(n) : 0.0;
}

// The SWITCHING-SIGNAL candidate PR 283 named (§6): the share of design elements
// sitting at the SIMP void floor. Free — one pass over the density vector the
// solver is already handed.
double void_floor_share(const VoxelGrid& g, const std::vector<double>& dens) {
  std::size_t n = 0, at_floor = 0;
  for (std::size_t e = 0; e < dens.size(); ++e) {
    if (g.tags[e] == VoxelTag::Empty) continue;
    ++n;
    if (dens[e] < 0.0015) ++at_floor;
  }
  return n ? static_cast<double>(at_floor) / static_cast<double>(n) : 0.0;
}

// ============================================================================
// A HEALTHY CONTROL — copied from mg_component_sweep / hybrid_amg_probe so the
// healthy rows of all three probes are the same fixture.
// ============================================================================
Case healthy_case(int nx, int ny, int nz, double rho) {
  Case C;
  VoxelGrid& g = C.grid;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      C.bcs.push_back({nd, 0, 0.0});
      C.bcs.push_back({nd, 1, 0.0});
      C.bcs.push_back({nd, 2, 0.0});
    }
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(nx - 1, j, k, VoxelTag::Load);
  C.loads = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  C.traj.push_back(std::vector<double>(g.voxel_count(), rho));
  return C;
}

// ============================================================================
// ENERGY CAPTURE — PR 283's instrument, unchanged. For SPD A0 and a coarse space
// range(W) (W: ng x m), the A-orthogonal projection of the exact u onto range(W)
// is W z with (W^T A0 W) z = W^T A0 u = W^T b, and its energy is
// z^T (W^T A0 W) z = z . (W^T b). The exact solution's energy is u . b. The
// ratio is the fraction of the solution's energy the space can represent;
// 1 - ratio is what the smoother is left to remove alone.
//
// Ac is passed in already formed, so this never re-touches the fine operator.
// ============================================================================
struct Capture {
  int dim = 0;
  double captured = 0.0;
  double setup_s = 0.0;
  bool ok = false;
};

Capture capture_of(const SpMat& Ac, const Vec& bc, double energy_exact) {
  Capture c;
  c.dim = static_cast<int>(Ac.cols());
  const double t0 = now_ms();
  Eigen::SimplicialLDLT<SpMat> ldlt;
  ldlt.compute(Ac);
  if (ldlt.info() != Eigen::Success) {
    c.setup_s = (now_ms() - t0) / 1e3;
    return c;
  }
  const Vec z = ldlt.solve(bc);
  c.setup_s = (now_ms() - t0) / 1e3;
  c.captured = energy_exact > 0 ? z.dot(bc) / energy_exact : 0.0;
  c.ok = true;
  return c;
}

// ============================================================================
// THE EXACT REFERENCE. Matrix-free Jacobi-CG at the production certification
// tolerance, so `u` and `energy = u . b` are trustworthy. The probe REFUSES to
// report a capture if the reference did not converge (PR 283's rule).
// ============================================================================
struct Reference {
  Vec u;         // over the KEPT DOFs
  Vec b;         // reduced RHS
  double energy = 0.0;
  int iters = 0;
  double residual = 0.0;
  double maxabs = 0.0;
  bool ok = false;
};

Reference exact_reference(const MatfreeReduced& m) {
  Reference R;
  const int n = m.ng;
  R.b = Eigen::Map<const Vec>(m.rg.data(), n);
  Vec x = Vec::Zero(n), r = R.b, z(n), p(n), Ap(n);
  for (int i = 0; i < n; ++i) z[i] = m.invdiag[static_cast<std::size_t>(i)] * r[i];
  p = z;
  double rz = r.dot(z);
  const double bn = R.b.norm();
  const int cap = 200000;
  int it = 0;
  for (; it < cap; ++it) {
    m.apply_kgg_raw(p.data(), Ap.data());
    const double pAp = p.dot(Ap);
    if (!(pAp > 0.0) || !std::isfinite(pAp)) break;
    const double alpha = rz / pAp;
    x += alpha * p;
    r -= alpha * Ap;
    const double rel = r.norm() / bn;
    if (rel <= kCertTol) {
      R.residual = rel;
      ++it;
      break;
    }
    for (int i = 0; i < n; ++i)
      z[i] = m.invdiag[static_cast<std::size_t>(i)] * r[i];
    const double rz_new = r.dot(z);
    p = z + (rz_new / rz) * p;
    rz = rz_new;
    R.residual = rel;
  }
  R.u = x;
  R.iters = it;
  R.energy = x.dot(R.b);
  R.maxabs = x.cwiseAbs().maxCoeff();
  R.ok = R.residual <= kCertTol && R.energy > 0.0;
  return R;
}

// ============================================================================
// THE GEOMETRIC LEVEL-1 SPACE — captured at PR 283's seam as the PRODUCTION
// builder forms it, not re-derived. The hook records what it is shown and
// DECLINES, so the solver builds its ordinary hierarchy.
// ============================================================================
struct GeoSeam {
  int n1 = 0;
  SpMat A1, P0;
  bool seen = false;
};

GeoSeam capture_geometric_seam(const VoxelGrid& g,
                               const std::vector<double>& ey,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads) {
  GeoSeam S;
  topopt::fea_detail::mg_set_coarse_space_hook(
      [&](const MgCoarseSeam& s) -> std::vector<MgCoo> {
        S.seen = true;
        S.n1 = s.n1;
        S.A1 = SpMat(s.n1, s.n1);
        {
          std::vector<Trip> t;
          for (int j = 0; j < s.n1; ++j)
            for (int p = s.a1_outer[j]; p < s.a1_outer[j + 1]; ++p)
              t.emplace_back(s.a1_inner[p], j, s.a1_val[p]);
          S.A1.setFromTriplets(t.begin(), t.end());
        }
        S.P0 = SpMat(s.p0.rows, s.p0.cols);
        {
          std::vector<Trip> t;
          for (std::size_t k = 0; k < s.p0.val.size(); ++k)
            t.emplace_back(s.p0.row[k], s.p0.col[k], s.p0.val[k]);
          S.P0.setFromTriplets(t.begin(), t.end());
        }
        return {};  // decline
      });
  CgInfo info;
  topopt::fea_matfree_reset_mg_stagnation_latch();
  topopt::fea_solve_mgcg_matfree(g, ey, kNu, bcs, loads, kCertTol, 0, &info);
  topopt::fea_detail::mg_set_coarse_space_hook({});
  return S;
}

// ============================================================================
// THE ALGEBRAIC LEVEL-1 SPACE — built by the PRODUCTION function
// `alg_level1_prolongator`, then projected with amg_lean's element-local
// `fine_galerkin` so A0 is never assembled here either.
// ============================================================================
struct AlgSpace {
  SpMat P0;
  SpMat A1;
  AlgCoarsenStats st;
  double galerkin_check = 0.0;  // rel |z^T A1 z - (P0 z)^T A0 (P0 z)|
  bool ok = false;
};

AlgSpace build_algebraic_space(const MatfreeReduced& m, int nnx, int nny,
                               int nnz) {
  AlgSpace A;
  std::vector<int> active(static_cast<std::size_t>(m.ndof), -1);
  for (int kg = 0; kg < m.ng; ++kg)
    active[static_cast<std::size_t>(m.kept_global[static_cast<std::size_t>(kg)])] =
        kg;

  std::vector<std::vector<std::pair<int, double>>> rows;
  int nc = 0;
  std::vector<int> coarse_block;
  std::vector<double> bcoarse;
  if (!topopt::fea_detail::alg_level1_prolongator(m, active, nnx, nny, nnz, rows,
                                                  nc, coarse_block, bcoarse,
                                                  A.st))
    return A;

  // P0 as an Eigen matrix (for the capture RHS) and as an amg::Csr (for the
  // element-local Galerkin).
  {
    std::vector<Trip> t;
    for (int i = 0; i < m.ng; ++i)
      for (const auto& kv : rows[static_cast<std::size_t>(i)])
        t.emplace_back(i, kv.first, kv.second);
    A.P0 = SpMat(m.ng, nc);
    A.P0.setFromTriplets(t.begin(), t.end());
    A.P0.makeCompressed();
  }
  amg::Csr P;
  P.nrow = m.ng;
  P.ncol = nc;
  P.rowptr.assign(static_cast<std::size_t>(m.ng) + 1, 0);
  for (int i = 0; i < m.ng; ++i)
    P.rowptr[i + 1] =
        P.rowptr[i] + static_cast<i64>(rows[static_cast<std::size_t>(i)].size());
  for (int i = 0; i < m.ng; ++i)
    for (const auto& kv : rows[static_cast<std::size_t>(i)]) {
      P.col.push_back(kv.first);
      P.val.push_back(kv.second);
    }

  // cbase: first coarse DOF of each aggregate (contiguous by construction).
  const int naggs = A.st.naggregates;
  std::vector<int> cbase(static_cast<std::size_t>(naggs) + 1, 0);
  {
    std::vector<int> cnt(static_cast<std::size_t>(naggs), 0);
    for (int I = 0; I < nc; ++I)
      cnt[static_cast<std::size_t>(coarse_block[static_cast<std::size_t>(I)])]++;
    for (int a = 0; a < naggs; ++a) cbase[a + 1] = cbase[a] + cnt[static_cast<std::size_t>(a)];
  }

  amglean::FineMF F = amglean::build_fine(m);
  const amg::Csr A1c = amglean::fine_galerkin(F, P, coarse_block, naggs, cbase);
  {
    std::vector<Trip> t;
    for (int i = 0; i < A1c.nrow; ++i)
      for (i64 p = A1c.rowptr[i]; p < A1c.rowptr[i + 1]; ++p)
        t.emplace_back(i, A1c.col[static_cast<std::size_t>(p)],
                       A1c.val[static_cast<std::size_t>(p)]);
    A.A1 = SpMat(nc, nc);
    A.A1.setFromTriplets(t.begin(), t.end());
    A.A1.makeCompressed();
  }

  // VERIFY A1 IS THE GALERKIN OPERATOR OF P0, rather than assuming it: for a
  // pseudo-random z, compare z^T A1 z against (P0 z)^T A0 (P0 z) through the
  // PRODUCTION matrix-free apply. This is the check that licenses every capture
  // number below (PR 283 read 1.29e-15 on the geometric side).
  {
    Vec z(nc);
    std::uint64_t s = 88172645463325252ull;
    for (int i = 0; i < nc; ++i) {
      s ^= s << 13; s ^= s >> 7; s ^= s << 17;
      z[i] = static_cast<double>(s % 2000) / 1000.0 - 1.0;
    }
    const Vec pz = A.P0 * z;
    Vec apz(m.ng);
    m.apply_kgg_raw(pz.data(), apz.data());
    const double lhs = z.dot(A.A1 * z);
    const double rhs = pz.dot(apz);
    A.galerkin_check =
        std::fabs(rhs) > 0 ? std::fabs(lhs - rhs) / std::fabs(rhs) : std::fabs(lhs - rhs);
  }
  A.ok = true;
  return A;
}

// ============================================================================
// A PRODUCTION SOLVE, armed or disarmed, with everything the bars need.
// ============================================================================
struct Run {
  CgInfo info;
  FeaSolution sol;
  topopt::MgAlgebraicLevel1Info alg;
  std::vector<int> dims;
  double wall_s = 0.0;
  double dof_weighted = 0.0;  // fine-level-apply equivalents
};

// One V-cycle's smoother work summed over levels, weighted by each level's DOF
// count against the fine level — the load-independent work currency. Pre + post
// smoothing on every level except the bottom, which is a direct solve.
double dof_weighted_per_cycle(const std::vector<int>& dims) {
  if (dims.empty() || dims[0] <= 0) return 0.0;
  const double fine = dims[0];
  double w = 0.0;
  for (std::size_t i = 0; i + 1 < dims.size(); ++i)
    w += 2.0 * static_cast<double>(dims[i]) / fine;  // pre + post
  return w;
}

Run production_solve(const VoxelGrid& g, const std::vector<double>& ey,
                     const std::vector<DirichletBC>& bcs,
                     const std::vector<NodalLoad>& loads, bool armed) {
  Run R;
  topopt::fea_set_mg_algebraic_level1(armed);
  topopt::fea_matfree_reset_mg_stagnation_latch();
  topopt::fea_mg_reset_algebraic_level1_info();
  const double t0 = now_ms();
  R.sol = topopt::fea_solve_mgcg_matfree(g, ey, kNu, bcs, loads, kCertTol, 0,
                                         &R.info);
  R.wall_s = (now_ms() - t0) / 1e3;
  R.alg = topopt::fea_mg_algebraic_level1_info();
  int buf[32];
  const int n = topopt::fea_mg_last_hierarchy_dims(buf, 32);
  for (int i = 0; i < n && i < 32; ++i) R.dims.push_back(buf[i]);
  R.dof_weighted =
      dof_weighted_per_cycle(R.dims) * static_cast<double>(R.info.iterations);
  topopt::fea_set_mg_algebraic_level1(false);
  return R;
}

// Lift a reduced-DOF reference into the FULL displacement numbering so it can be
// compared against FeaSolution::u. Getting this wrong is easy and silent: `u` is
// the full vector while the reference is over the KEPT DOFs (PR 283 §AF7).
double worst_rel_deviation(const MatfreeReduced& m, const Reference& R,
                           const std::vector<double>& full) {
  double num = 0.0, den = 0.0;
  for (int i = 0; i < m.ng; ++i) {
    const int gd = m.kept_global[static_cast<std::size_t>(i)];
    const double a = full[static_cast<std::size_t>(gd)];
    const double d = a - R.u[i];
    num += d * d;
    den += R.u[i] * R.u[i];
  }
  return den > 0 ? std::sqrt(num / den) : std::sqrt(num);
}

MatfreeReduced build_reduced(const VoxelGrid& g, const std::vector<double>& ey,
                             const std::vector<DirichletBC>& bcs,
                             const std::vector<NodalLoad>& loads) {
  CgInfo info;
  return topopt::fea_detail::mf_build_reduced(g, kE0, kNu, bcs, loads, &ey,
                                              "alg_level1_probe", &info);
}

// ---------------------------------------------------------------------------
std::string g_dir = ".";
std::string path(const char* name) { return g_dir + "/" + name; }

}  // namespace

// ============================================================================
// MODE: capture — AH2's headline, plus AH6's diagnosis.
// ============================================================================
static int mode_capture(Case& stag, bool have_stag) {
  print_load("start");
  FILE* csv = std::fopen(path("capture.csv").c_str(), "w");
  std::fprintf(csv, "field,space,dim,captured_energy,pr283,agreement\n");

  auto one_field = [&](const char* name, Case& C, std::size_t snap,
                       double pr283_geo, double pr283_alg, int pr283_geo_dim,
                       int pr283_alg_dim) {
    const std::vector<double>& dens = C.traj[snap];
    const std::vector<double> ey = penalized_youngs(C.grid, dens);
    std::printf("\n=== %s: grid %dx%dx%d, achieved_vf %.4f, void-floor share "
                "%.4f ===\n",
                name, C.grid.nx, C.grid.ny, C.grid.nz, achieved_vf(C.grid, dens),
                void_floor_share(C.grid, dens));

    const MatfreeReduced m = build_reduced(C.grid, ey, C.bcs, C.loads);
    std::printf("    reduced DOFs: %d\n", m.ng);

    const double tref = now_ms();
    const Reference R = exact_reference(m);
    std::printf("    exact reference: %d iters, residual %.4e, max|u| %.4e, "
                "%.1f s\n",
                R.iters, R.residual, R.maxabs, (now_ms() - tref) / 1e3);
    if (!R.ok) {
      std::printf("    REFERENCE DID NOT CONVERGE — refusing to report capture "
                  "(PR 283's rule)\n");
      return;
    }

    // --- geometric level 1, read at PR 283's seam ---------------------------
    const GeoSeam S = capture_geometric_seam(C.grid, ey, C.bcs, C.loads);
    if (S.seen) {
      const Vec bc = S.P0.transpose() * R.b;
      const Capture cg = capture_of(S.A1, bc, R.energy);
      const double agree = pr283_geo > 0 ? cg.captured / pr283_geo : 0.0;
      std::printf("    GEOMETRIC level 1: dim %6d  capture %8.4f %%   "
                  "(PR 283: %.4f %% at dim %d -> agreement %.4fx)\n",
                  cg.dim, 100.0 * cg.captured, 100.0 * pr283_geo, pr283_geo_dim,
                  agree);
      std::fprintf(csv, "%s,geometric,%d,%.6f,%.6f,%.4f\n", name, cg.dim,
                   cg.captured, pr283_geo, agree);
    } else {
      std::printf("    GEOMETRIC level 1: the solver never reached the seam "
                  "(no hierarchy on this grid)\n");
      std::fprintf(csv, "%s,geometric,0,0,%.6f,0\n", name, pr283_geo);
    }

    // --- algebraic level 1, from the PRODUCTION prolongator -----------------
    const double talg = now_ms();
    const AlgSpace A = build_algebraic_space(m, C.grid.nx + 1, C.grid.ny + 1,
                                             C.grid.nz + 1);
    const double alg_setup = (now_ms() - talg) / 1e3;
    if (!A.ok) {
      std::printf("    ALGEBRAIC level 1: REFUSED (%s)\n",
                  A.st.refuse_reason.c_str());
      std::fprintf(csv, "%s,algebraic,0,0,%.6f,0\n", name, pr283_alg);
      return;
    }
    std::printf("    Galerkin identity check (z^T A1 z vs (P0 z)^T A0 (P0 z)): "
                "%.3e relative\n",
                A.galerkin_check);
    const Vec bca = A.P0.transpose() * R.b;
    const Capture ca = capture_of(A.A1, bca, R.energy);
    const double agree = pr283_alg > 0 ? ca.captured / pr283_alg : 0.0;
    std::printf("    ALGEBRAIC level 1: dim %6d  capture %8.4f %%   "
                "(PR 283: %.4f %% at dim %d -> agreement %.4fx)\n",
                ca.dim, 100.0 * ca.captured, 100.0 * pr283_alg, pr283_alg_dim,
                agree);
    std::printf("      aggregates %d, setup %.3f s (strength %.0f ms, "
                "aggregate %.0f ms, tentative %.0f ms), adds %.1f MB\n",
                A.st.naggregates, alg_setup, A.st.t_strength_ms,
                A.st.t_aggregate_ms, A.st.t_tentative_ms,
                static_cast<double>(A.st.bytes) / (1024.0 * 1024.0));
    std::fprintf(csv, "%s,algebraic,%d,%.6f,%.6f,%.4f\n", name, ca.dim,
                 ca.captured, pr283_alg, agree);
  };

  if (have_stag) {
    // Snapshot 2 of the trajectory — the field PR 280 swept and PR 283 measured.
    const std::size_t snap = std::min<std::size_t>(2, stag.traj.size() - 1);
    one_field("stagnating", stag, snap, kPr283GeoCaptureStag,
              kPr283AlgCaptureStag, kPr283GeoDimStag, kPr283AlgDimStag);
  } else {
    std::printf("\n=== stagnating field UNAVAILABLE (no cache) — skipped ===\n");
  }

  Case H = healthy_case(32, 16, 32, 0.6);
  one_field("healthy", H, 0, kPr283GeoCaptureHealthy, 0.0, 7344, 0);

  std::fclose(csv);
  std::printf("\npeak RSS %.2f GB\n", peak_rss_mb() / 1024.0);
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: converge — AH2 (iterations), AH5 (setup cost), AH6 (healthy),
// AH8 (exactness).
// ============================================================================
static int mode_converge(Case& stag, bool have_stag) {
  print_load("start");
  FILE* csv = std::fopen(path("converge.csv").c_str(), "w");
  std::fprintf(csv,
               "field,posture,levels,carried,iters,dof_weighted,build_ms,"
               "cycle_ms,wall_s,matvecs,rel_dev,coarse_dim,aggregates,bytes\n");

  auto one_field = [&](const char* name, Case& C, std::size_t snap) {
    const std::vector<double>& dens = C.traj[snap];
    const std::vector<double> ey = penalized_youngs(C.grid, dens);
    std::printf("\n=== %s: grid %dx%dx%d, achieved_vf %.4f, void-floor share "
                "%.4f ===\n",
                name, C.grid.nx, C.grid.ny, C.grid.nz, achieved_vf(C.grid, dens),
                void_floor_share(C.grid, dens));

    const MatfreeReduced m = build_reduced(C.grid, ey, C.bcs, C.loads);
    const Reference R = exact_reference(m);
    std::printf("    exact reference: %d Jacobi-CG iters, residual %.3e, "
                "max|u| %.4e\n",
                R.iters, R.residual, R.maxabs);

    for (int armed = 0; armed <= 1; ++armed) {
      const Run r = production_solve(C.grid, ey, C.bcs, C.loads, armed != 0);
      const double dev = worst_rel_deviation(m, R, r.sol.u);
      std::printf("    %-9s levels %d  %-9s iters %5d  DOF-wtd %8.1f  "
                  "build %7.1f ms  cycles %8.1f ms  wall %6.2f s  "
                  "rel dev %.3e\n",
                  armed ? "ALGEBRAIC" : "geometric", r.info.mg_levels,
                  r.info.used_multigrid ? "CARRIED" : "STAGNATES",
                  r.info.iterations, r.dof_weighted, r.info.t_mg_build_ms,
                  r.info.t_mg_ms, r.wall_s, dev);
      std::printf("              level dims:");
      for (int d : r.dims) std::printf(" %d", d);
      if (armed) {
        std::printf("   [aggregates %d, adds %.1f MB, setup %.0f ms]",
                    r.alg.aggregates,
                    static_cast<double>(r.alg.bytes) / (1024.0 * 1024.0),
                    r.alg.setup_ms);
        if (r.alg.refused) std::printf("  REFUSED: %s", r.alg.refuse_reason);
      }
      std::printf("\n");
      std::fprintf(csv, "%s,%s,%d,%d,%d,%.2f,%.2f,%.2f,%.3f,%lld,%.3e,%d,%d,%llu\n",
                   name, armed ? "algebraic" : "geometric", r.info.mg_levels,
                   r.info.used_multigrid ? 1 : 0, r.info.iterations,
                   r.dof_weighted, r.info.t_mg_build_ms, r.info.t_mg_ms,
                   r.wall_s, static_cast<long long>(r.info.matvecs), dev,
                   r.alg.coarse_dim, r.alg.aggregates,
                   static_cast<unsigned long long>(r.alg.bytes));
    }
    std::printf("    PR 283's algebraic reference on this field: %d PCG "
                "iterations (amg_lean, Chebyshev fine smoother)\n",
                kPr283AlgPcgIters);
  };

  if (have_stag) {
    const std::size_t snap = std::min<std::size_t>(2, stag.traj.size() - 1);
    one_field("stagnating", stag, snap);
  } else {
    std::printf("\n=== stagnating field UNAVAILABLE (no cache) — skipped ===\n");
  }
  Case H = healthy_case(64, 32, 64, 0.6);
  one_field("healthy", H, 0);

  std::fclose(csv);
  std::printf("\npeak RSS %.2f GB\n", peak_rss_mb() / 1024.0);
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: mem — AH3, THE LIKELIEST KILLER. Aggregate count, coarse dimension and
// bytes at grid sizes spanning >= 20x, so the growth can be FITTED rather than
// assumed linear, and projected to the maintainer's 8.44M-DOF job.
// ============================================================================
static int mode_mem(Case& stag, bool have_stag) {
  print_load("start");
  FILE* csv = std::fopen(path("mem.csv").c_str(), "w");
  std::fprintf(csv, "nx,ny,nz,dofs,nodes,aggregates,coarse_dim,levels,bytes,"
                    "bytes_per_dof,setup_ms\n");
  std::printf("\n=== AH3: memory scaling of the algebraic level-1 space ===\n");
  std::printf("%-14s %9s %9s %9s %7s %10s %12s %9s\n", "grid", "DOFs",
              "aggregates", "coarse", "levels", "MB", "bytes/DOF", "setup ms");

  struct Row { int dofs; double bytes; };
  std::vector<Row> rows;

  const int grids[][3] = {{16, 8, 16}, {24, 12, 24}, {32, 16, 32},
                          {48, 24, 48}, {64, 32, 64}, {80, 40, 80}};
  for (const auto& gd : grids) {
    Case C = healthy_case(gd[0], gd[1], gd[2], 0.6);
    const std::vector<double> ey = penalized_youngs(C.grid, C.traj[0]);
    const MatfreeReduced m = build_reduced(C.grid, ey, C.bcs, C.loads);

    std::vector<int> active(static_cast<std::size_t>(m.ndof), -1);
    for (int kg = 0; kg < m.ng; ++kg)
      active[static_cast<std::size_t>(
          m.kept_global[static_cast<std::size_t>(kg)])] = kg;
    std::vector<std::vector<std::pair<int, double>>> pr;
    int nc = 0;
    std::vector<int> cb;
    std::vector<double> bc;
    AlgCoarsenStats st;
    const double t0 = now_ms();
    const bool ok = topopt::fea_detail::alg_level1_prolongator(
        m, active, C.grid.nx + 1, C.grid.ny + 1, C.grid.nz + 1, pr, nc, cb, bc,
        st);
    const double setup_ms = now_ms() - t0;
    if (!ok) {
      std::printf("%-14s REFUSED: %s\n",
                  (std::to_string(gd[0]) + "x" + std::to_string(gd[1]) + "x" +
                   std::to_string(gd[2])).c_str(),
                  st.refuse_reason.c_str());
      continue;
    }
    // Charge the FULL armed hierarchy: level 1's own setup plus every coarse
    // level the chain builds. This is what the algebraic path ADDS.
    Run r = production_solve(C.grid, ey, C.bcs, C.loads, /*armed=*/true);
    const double bytes = static_cast<double>(r.alg.bytes);
    char gname[32];
    std::snprintf(gname, sizeof gname, "%dx%dx%d", gd[0], gd[1], gd[2]);
    std::printf("%-14s %9d %9d %9d %7d %10.2f %12.3f %9.0f\n", gname, m.ng,
                st.naggregates, nc, r.alg.levels, bytes / (1024.0 * 1024.0),
                bytes / static_cast<double>(m.ng), setup_ms);
    std::fprintf(csv, "%d,%d,%d,%d,%d,%d,%d,%d,%.0f,%.4f,%.1f\n", gd[0], gd[1],
                 gd[2], m.ng, st.fine_nodes, st.naggregates, nc, r.alg.levels,
                 bytes, bytes / static_cast<double>(m.ng), setup_ms);
    rows.push_back({m.ng, bytes});
  }

  // THE DILUTE ROW. The fit above is measured on HEALTHY (rho 0.6) fixtures
  // because those are the ones that can be swept over a 20x+ size range
  // cheaply. A dilute field aggregates DIFFERENTLY, so projecting a healthy fit
  // onto the maintainer's dilute job without checking would be exactly the
  // unstated assumption PR 283 flagged ("a different field aggregates
  // differently"). This row is the check: if the dilute bytes/DOF sits in the
  // healthy band, the fit transfers; if it does not, the projection is only
  // good for healthy fields and this says so.
  if (have_stag) {
    const std::size_t snap = std::min<std::size_t>(2, stag.traj.size() - 1);
    const std::vector<double>& dens = stag.traj[snap];
    const std::vector<double> ey = penalized_youngs(stag.grid, dens);
    const MatfreeReduced m = build_reduced(stag.grid, ey, stag.bcs, stag.loads);
    Run r = production_solve(stag.grid, ey, stag.bcs, stag.loads, true);
    std::printf("%-14s %9d %9d %9d %7d %10.2f %12.3f %9.0f   <- DILUTE "
                "(achieved_vf %.4f, void-floor %.4f)\n",
                "stagnating", m.ng, r.alg.aggregates, r.alg.coarse_dim,
                r.alg.levels,
                static_cast<double>(r.alg.bytes) / (1024.0 * 1024.0),
                static_cast<double>(r.alg.bytes) / static_cast<double>(m.ng),
                r.alg.setup_ms, achieved_vf(stag.grid, dens),
                void_floor_share(stag.grid, dens));
    std::fprintf(csv, "%d,%d,%d,%d,%d,%d,%d,%d,%.0f,%.4f,%.1f\n", stag.grid.nx,
                 stag.grid.ny, stag.grid.nz, m.ng, 0, r.alg.aggregates,
                 r.alg.coarse_dim, r.alg.levels,
                 static_cast<double>(r.alg.bytes),
                 static_cast<double>(r.alg.bytes) / static_cast<double>(m.ng),
                 r.alg.setup_ms);
  }

  // FIT the growth rather than assuming linearity: least squares on
  // log(bytes) = log(a) + p * log(dofs). p ~ 1 means bytes/DOF is constant and a
  // linear projection is honest; p > 1 means it is not.
  if (rows.size() >= 3) {
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    const double n = static_cast<double>(rows.size());
    for (const Row& r : rows) {
      const double x = std::log(static_cast<double>(r.dofs));
      const double y = std::log(r.bytes);
      sx += x; sy += y; sxx += x * x; sxy += x * y;
    }
    const double p = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    const double loga = (sy - p * sx) / n;
    const double a = std::exp(loga);
    const double target = 8.44e6;
    const double proj = a * std::pow(target, p);
    std::printf("\n  FIT: bytes = %.4g * DOFs^%.4f   (range %dx: %d -> %d DOFs)\n",
                a, p, static_cast<int>(rows.back().dofs / rows.front().dofs),
                rows.front().dofs, rows.back().dofs);
    std::printf("  PROJECTION to 8.44M DOF: %.2f GB\n", proj / 1e9);
    std::printf("  This machine's RAM: %.1f GB.  PR 248's refuse-and-fall-back "
                "precedent (kGeneoMaxBasisMB) is 2048 MB;\n"
                "  this path's cap kAlgMaxCoarseBytes is %llu MB.\n",
                16.0,
                static_cast<unsigned long long>(
                    topopt::fea_detail::kAlgMaxCoarseBytes / (1024 * 1024)));
    FILE* f = std::fopen(path("mem_fit.txt").c_str(), "w");
    std::fprintf(f, "bytes = %.6g * DOFs^%.6f\nprojection at 8.44e6 DOF = %.4f GB\n"
                    "cap kAlgMaxCoarseBytes = %llu MB\n",
                 a, p, proj / 1e9,
                 static_cast<unsigned long long>(
                     topopt::fea_detail::kAlgMaxCoarseBytes / (1024 * 1024)));
    std::fclose(f);
  }

  std::fclose(csv);
  std::printf("\npeak RSS %.2f GB\n", peak_rss_mb() / 1024.0);
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: det — AH10. Byte-identical rerun in EACH posture.
// ============================================================================
static int mode_det(Case& stag, bool have_stag) {
  print_load("start");
  FILE* f = std::fopen(path("det.txt").c_str(), "w");
  auto one = [&](const char* name, Case& C, std::size_t snap) {
    const std::vector<double> ey = penalized_youngs(C.grid, C.traj[snap]);
    for (int armed = 0; armed <= 1; ++armed) {
      const Run a = production_solve(C.grid, ey, C.bcs, C.loads, armed != 0);
      const Run b = production_solve(C.grid, ey, C.bcs, C.loads, armed != 0);
      const std::string fa = fingerprint(a.sol.u), fb = fingerprint(b.sol.u);
      const bool same = fa == fb && a.info.iterations == b.info.iterations &&
                        a.alg.coarse_dim == b.alg.coarse_dim &&
                        a.alg.aggregates == b.alg.aggregates;
      std::printf("  %-11s %-9s  iters %d/%d  dim %d/%d  fp %s / %s  -> %s\n",
                  name, armed ? "ALGEBRAIC" : "geometric", a.info.iterations,
                  b.info.iterations, a.alg.coarse_dim, b.alg.coarse_dim,
                  fa.c_str(), fb.c_str(), same ? "IDENTICAL" : "DIFFERS");
      std::fprintf(f, "%s,%s,%d,%d,%d,%d,%s,%s,%s\n", name,
                   armed ? "algebraic" : "geometric", a.info.iterations,
                   b.info.iterations, a.alg.coarse_dim, b.alg.coarse_dim,
                   fa.c_str(), fb.c_str(), same ? "IDENTICAL" : "DIFFERS");
    }
  };
  std::printf("\n=== AH10: determinism, per posture ===\n");
  if (have_stag)
    one("stagnating", stag, std::min<std::size_t>(2, stag.traj.size() - 1));
  Case H = healthy_case(32, 16, 32, 0.6);
  one("healthy", H, 0);
  std::fclose(f);
  print_load("end");
  return 0;
}

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "capture";
  if (argc > 2) g_dir = argv[2];

  Case stag;
  const bool have_stag = cache_load(path("mg_stepbox_r32.bin"), stag);
  if (have_stag)
    std::printf("loaded PR 280's cached trajectory: %dx%dx%d, %zu snapshots\n",
                stag.grid.nx, stag.grid.ny, stag.grid.nz, stag.traj.size());
  else
    std::printf("NOTE: %s not found — stagnating rows will be skipped\n",
                path("mg_stepbox_r32.bin").c_str());

  if (mode == "capture") return mode_capture(stag, have_stag);
  if (mode == "converge") return mode_converge(stag, have_stag);
  if (mode == "mem") return mode_mem(stag, have_stag);
  if (mode == "det") return mode_det(stag, have_stag);
  std::printf("unknown mode '%s' (capture|converge|mem|det)\n", mode.c_str());
  return 2;
}
