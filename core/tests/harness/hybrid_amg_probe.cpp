// hybrid_amg_probe.cpp — CAN AN ALGEBRAIC COARSE SPACE RESCUE THE DILUTE
// REGIME? (task: hybrid-amg-coarsening-probe)
//
// NOT a CI test, NOT in CTest, NOT linked into any production path. It links the
// production library and drives the PRODUCTION solver through two harness-only
// seams in src/fea/fea_matfree.hpp: `mg_set_tuning` (PR 280's) and
// `mg_set_coarse_space_hook` (this task's). Nothing here changes a default —
// tests/unit/test_mg_coarse_hook.cpp asserts the seam is uninstalled by default
// and that a solve after install+clear is bit-identical.
//
// THE QUESTION. PR 280 swept 25 configurations of levels / smoothing / cycle /
// smoother on the maintainer's real stagnating field and got ZERO convergences,
// with levels 2, 3, 4, 5 and MAX all producing an IDENTICAL 4,841 applies. Its
// diagnosis: at achieved_vf 2-5 % inside a design box ~9.2 part-volumes the
// structure is nearly disconnected, and a coarse grid formed by HALVING cannot
// represent a near-null-space that thin — "the coarse space is wrong, not the
// recipe around it". PR 281 confirmed it from the other side: keeping the design
// non-dilute (SIMP p-continuation) took stagnating iterations to zero, but every
// schedule flipped a gate verdict. The solver has to SURVIVE dilution.
//
// THE HYPOTHESIS UNDER TEST is Peetz & Elbanna's hybrid (SMO 63:835-853, arXiv
// 2001.01655): keep level 0 -> 1 geometric and matrix-free exactly as today, and
// build the levels BELOW 1 by ALGEBRAIC aggregation from A1, whose aggregates
// follow the structure rather than the grid. It is architecture-compatible in a
// way pure AMG is not, because levels 1 and below ALREADY HAVE A MATRIX
// (multigrid.cpp forms A1 = P0^T A0 P0 element-locally; A0 is never assembled).
// PR 230's 20-35 GB AMG price is the cost of assembling the FINE level, which
// nothing here goes near.
//
// THE MEASUREMENT, AND WHY IT COMES FIRST. Before building a solver, ASK THE
// COARSE SPACE. For an SPD system A0 u = b, the A-orthogonal projection of the
// exact u onto a coarse space range(P) has energy z^T (P^T A0 P) z where
// (P^T A0 P) z = P^T b, and the exact solution's own energy is u . b. Their ratio
// is the fraction of the solution's energy the coarse space can represent — and
// 1 minus it is precisely what the SMOOTHER has to remove on its own. That is a
// direct, cheap, assumption-free reading of PR 280's diagnosis, and it is
// computed here for the geometric level-1 and level-2 spaces and for algebraic
// spaces AT MATCHED COARSE DIMENSION, side by side.
//
// STATED EXPECTATION, BEFORE THE NUMBERS (AF1 asks for one). The geometric
// level-1 space should capture MOST of the energy — coarse spaces usually do,
// because energy is dominated by large-scale deformation — but the number that
// decides this task is how much is LEFT, and on a 2-5 % dilute field with
// ligaments thinner than a coarse cell I expect the level-2 geometric space to
// lose materially more than the level-1 one, and algebraic aggregation at the
// same dimension to recover part of that gap. If instead LEVEL 1 ITSELF is
// already the deficient space, this task's hypothesis is aimed one level too
// low, and that is the finding.
//
// BUILD (library built Release first):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=ON -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
//       -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//       core/tests/harness/hybrid_amg_probe.cpp core/build/libtopopt.a <OCCT libs> \
//       -o core/build/hybrid_amg_probe
// RUN: ./core/build/hybrid_amg_probe <capture|converge|healthy|mem|det> [dir]
//
// THE FIELD. `capture` and `converge` read the SAME cache file
// mg_component_sweep.cpp writes for PR 280's `ladder32.json` reproduction
// (`<dir>/mg_stepbox_r32.bin`), so this probe measures literally the trajectory
// PR 280 swept — not a re-derivation of it. Produce it with:
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

#include "fea/fea_matfree.hpp"

#include "amg_sa.hpp"
#include "amg_lean.hpp"

using namespace topopt;
using topopt::fea_detail::MatfreeReduced;
using topopt::fea_detail::MgCoarseSeam;
using topopt::fea_detail::MgCoo;
using topopt::fea_detail::MgTuning;

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

double now_ms() {
  struct timespec t;
  timespec_get(&t, TIME_UTC);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

// HOST LOAD, recorded rather than assumed away (PR 277's discipline, kept by
// PR 280). This machine runs other campaigns; a wall number read off a busy host
// is indicative, not evidence, and the reader is entitled to see which.
void print_load(const char* when) {
  double la[3] = {0, 0, 0};
  if (getloadavg(la, 3) < 0) {
    std::printf("   [%s: load unavailable]\n", when);
    return;
  }
  std::printf("   [%s host load average: %.2f %.2f %.2f]\n", when, la[0], la[1],
              la[2]);
}

// Peak resident set of THIS process, in bytes. macOS reports ru_maxrss in bytes
// (Linux in KiB); this probe runs on macOS and the unit is asserted by the
// magnitude check at the call site.
std::size_t peak_rss_bytes() {
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
  return static_cast<std::size_t>(ru.ru_maxrss);
}

// FNV-1a over raw bytes — the determinism fingerprint (same construction as
// mg_component_sweep, so fingerprints are comparable across the two probes).
struct Fnv {
  std::uint64_t h = 1469598103934665603ULL;
  void add(const void* p, std::size_t n) {
    const auto* b = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) {
      h ^= b[i];
      h *= 1099511628211ULL;
    }
  }
  void add_d(double d) { add(&d, sizeof d); }
};

// ============================================================================
// THE FIELD — read from mg_component_sweep's cache, byte format copied verbatim
// so the two probes cannot drift apart. This probe never DEVELOPS a trajectory;
// it insists on the one PR 280 measured.
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

// The SIMP-penalized modulus field the solver is actually handed.
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

// ============================================================================
// A HEALTHY CONTROL (AF6) — a well-connected, domain-filling cantilever whose
// multigrid converges today. Copied from mg_component_sweep so the two probes'
// healthy rows are the same fixture.
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
// THE SEAM — capture A1 and P0 as the PRODUCTION builder forms them.
//
// The hook is installed, records what it is shown, and DECLINES (returns {}), so
// the solver builds its ordinary geometric hierarchy and the capture costs
// nothing but the copy. Every quantity below is therefore the solver's own, not
// a re-derivation: A1 is the element-local Galerkin product multigrid.cpp
// computes, P0 is the trilinear prolongator it built.
// ============================================================================
struct Seam {
  bool seen = false;
  int n1 = 0;
  amg::Csr a1;   // symmetric, so Eigen's CSC reads as CSR unchanged
  SpMat p0;      // ng x n1
  int cnx = 0, cny = 0, cnz = 0;
  std::vector<int> cactive;
};

amg::Csr csr_from_eigen_csc(int n, const int* outer, const int* inner,
                            const double* val) {
  // A1 is symmetric: its column-compressed storage IS its row-compressed
  // storage. Columns within a row come out ascending because Eigen keeps inner
  // indices sorted in a compressed matrix.
  amg::Csr A;
  A.nrow = n;
  A.ncol = n;
  A.rowptr.assign(static_cast<std::size_t>(n) + 1, 0);
  const i64 nnz = outer[n];
  A.col.resize(static_cast<std::size_t>(nnz));
  A.val.resize(static_cast<std::size_t>(nnz));
  for (int j = 0; j <= n; ++j) A.rowptr[static_cast<std::size_t>(j)] = outer[j];
  for (i64 p = 0; p < nnz; ++p) {
    A.col[static_cast<std::size_t>(p)] = inner[p];
    A.val[static_cast<std::size_t>(p)] = val[p];
  }
  return A;
}

SpMat eigen_from_coo(const MgCoo& c) {
  std::vector<Trip> t;
  t.reserve(c.val.size());
  for (std::size_t k = 0; k < c.val.size(); ++k)
    t.emplace_back(c.row[k], c.col[k], c.val[k]);
  SpMat M(c.rows, c.cols);
  M.setFromTriplets(t.begin(), t.end());
  M.makeCompressed();
  return M;
}

MgCoo coo_from_csr(const amg::Csr& P) {
  MgCoo c;
  c.rows = P.nrow;
  c.cols = P.ncol;
  c.row.reserve(static_cast<std::size_t>(P.nnz()));
  c.col.reserve(static_cast<std::size_t>(P.nnz()));
  c.val.reserve(static_cast<std::size_t>(P.nnz()));
  for (int i = 0; i < P.nrow; ++i)
    for (i64 p = P.rowptr[i]; p < P.rowptr[i + 1]; ++p) {
      c.row.push_back(i);
      c.col.push_back(P.col[p]);
      c.val.push_back(P.val[p]);
    }
  return c;
}

// Drive ONE hierarchy build and capture the seam. `max_iterations = 1` keeps the
// solve itself short: the hierarchy is built (which is all this needs), one MG-CG
// iteration is attempted, and the exact Jacobi-CG fallback is capped at one too.
Seam capture_seam(const VoxelGrid& g, const std::vector<double>& ey,
                  const Case& C) {
  Seam S;
  fea_detail::mg_set_coarse_space_hook(
      [&S](const MgCoarseSeam& s) -> std::vector<MgCoo> {
        S.seen = true;
        S.n1 = s.n1;
        S.a1 = csr_from_eigen_csc(s.n1, s.a1_outer, s.a1_inner, s.a1_val);
        S.p0 = eigen_from_coo(s.p0);
        S.cnx = s.cnx;
        S.cny = s.cny;
        S.cnz = s.cnz;
        S.cactive = *s.cactive;
        return {};  // decline: the solver builds its ordinary geometric levels
      });
  fea_matfree_reset_mg_stagnation_latch();
  CgInfo info;
  try {
    fea_solve_mgcg_matfree(g, ey, kNu, C.bcs, C.loads, kCertTol, 1, &info);
  } catch (const std::exception& e) {
    std::printf("   [seam capture solve reported: %s]\n", e.what());
  }
  fea_detail::mg_set_coarse_space_hook({});
  return S;
}

// ============================================================================
// THE GEOMETRIC PROLONGATOR AT LEVEL 1 -> 2, rebuilt here EXACTLY as
// build_hierarchy builds it (trilinear vertex coarsening, inactive coarse nodes
// dropped from the stencil). Returns false when the level-1 grid cannot be
// halved, which is the same stop the solver applies.
// ============================================================================
int axis_weights(int f, int (&ci)[2], double (&cw)[2]) {
  if ((f & 1) == 0) {
    ci[0] = f / 2;
    cw[0] = 1.0;
    return 1;
  }
  ci[0] = (f - 1) / 2;
  cw[0] = 0.5;
  ci[1] = (f + 1) / 2;
  cw[1] = 0.5;
  return 2;
}

bool geometric_prolongator(int fnx, int fny, int fnz,
                           const std::vector<int>& factive, int fn, SpMat& P,
                           int& cnx, int& cny, int& cnz,
                           std::vector<int>& cactive) {
  constexpr int kMinCoarseElems = 2;  // == coarsen.hpp's kMgMinCoarseElems
  const int fex = fnx - 1, fey = fny - 1, fez = fnz - 1;
  if ((fex & 1) || (fey & 1) || (fez & 1)) return false;
  const int cex = fex / 2, cey = fey / 2, cez = fez / 2;
  if (cex < kMinCoarseElems || cey < kMinCoarseElems || cez < kMinCoarseElems)
    return false;
  cnx = cex + 1;
  cny = cey + 1;
  cnz = cez + 1;
  auto fnode = [&](int a, int b, int c) { return (c * fny + b) * fnx + a; };

  cactive.assign(static_cast<std::size_t>(cnx) * cny * cnz * 3, -1);
  int nc = 0;
  for (int c = 0; c < cnz; ++c)
    for (int b = 0; b < cny; ++b)
      for (int a = 0; a < cnx; ++a) {
        const int fn_i = fnode(2 * a, 2 * b, 2 * c);
        const int cnode = (c * cny + b) * cnx + a;
        for (int comp = 0; comp < 3; ++comp)
          if (factive[static_cast<std::size_t>(fn_i) * 3 + comp] >= 0)
            cactive[static_cast<std::size_t>(cnode) * 3 + comp] = nc++;
      }
  if (nc == 0) return false;

  std::vector<Trip> tr;
  tr.reserve(static_cast<std::size_t>(fn) * 8);
  for (int fc = 0; fc < fnz; ++fc)
    for (int fb = 0; fb < fny; ++fb)
      for (int fa = 0; fa < fnx; ++fa) {
        const int fi = fnode(fa, fb, fc);
        bool any = false;
        for (int comp = 0; comp < 3; ++comp)
          if (factive[static_cast<std::size_t>(fi) * 3 + comp] >= 0) any = true;
        if (!any) continue;
        int ia[2], ib[2], ic[2];
        double wa[2], wb[2], wc[2];
        const int na = axis_weights(fa, ia, wa);
        const int nb = axis_weights(fb, ib, wb);
        const int ncz = axis_weights(fc, ic, wc);
        for (int comp = 0; comp < 3; ++comp) {
          const int row = factive[static_cast<std::size_t>(fi) * 3 + comp];
          if (row < 0) continue;
          for (int x = 0; x < na; ++x)
            for (int y = 0; y < nb; ++y)
              for (int z = 0; z < ncz; ++z) {
                const int cnode = (ic[z] * cny + ib[y]) * cnx + ia[x];
                const int col = cactive[static_cast<std::size_t>(cnode) * 3 + comp];
                if (col < 0) continue;
                tr.emplace_back(row, col, wa[x] * wb[y] * wc[z]);
              }
        }
      }
  P = SpMat(fn, nc);
  P.setFromTriplets(tr.begin(), tr.end());
  P.makeCompressed();
  return true;
}

// dof -> node, for a level whose active map is `active` (node*3+comp -> dof).
// The map numbers DOFs in node order, so this is a pure re-read, not a sort.
std::vector<int> dof2node_from_active(const std::vector<int>& active, int n,
                                      int& nnodes) {
  std::vector<int> d2n(static_cast<std::size_t>(n), 0);
  const std::size_t nn = active.size() / 3;
  int node = 0;
  for (std::size_t a = 0; a < nn; ++a) {
    bool any = false;
    for (int c = 0; c < 3; ++c) {
      const int d = active[a * 3 + static_cast<std::size_t>(c)];
      if (d >= 0) {
        d2n[static_cast<std::size_t>(d)] = node;
        any = true;
      }
    }
    if (any) ++node;
  }
  nnodes = node;
  return d2n;
}

// The 6 rigid-body modes at a level whose nodes sit on a (cnx,cny,cnz) grid with
// spacing `h`: 3 translations + 3 rotations about the active centroid, rotations
// scaled by the half-diagonal so all six columns are O(1). Same construction
// amg_probe.cpp uses, so the aggregation is seeded identically.
std::vector<double> rigid_body_modes(int cnx, int cny, int cnz,
                                     const std::vector<int>& cactive, int n,
                                     double h) {
  std::vector<double> X(static_cast<std::size_t>(n)), Y(static_cast<std::size_t>(n)),
      Z(static_cast<std::size_t>(n));
  std::vector<int> comp(static_cast<std::size_t>(n));
  for (int c = 0; c < cnz; ++c)
    for (int b = 0; b < cny; ++b)
      for (int a = 0; a < cnx; ++a) {
        const int node = (c * cny + b) * cnx + a;
        for (int q = 0; q < 3; ++q) {
          const int d = cactive[static_cast<std::size_t>(node) * 3 + q];
          if (d < 0) continue;
          X[static_cast<std::size_t>(d)] = a * h;
          Y[static_cast<std::size_t>(d)] = b * h;
          Z[static_cast<std::size_t>(d)] = c * h;
          comp[static_cast<std::size_t>(d)] = q;
        }
      }
  double sx = 0, sy = 0, sz = 0;
  for (int i = 0; i < n; ++i) {
    sx += X[static_cast<std::size_t>(i)];
    sy += Y[static_cast<std::size_t>(i)];
    sz += Z[static_cast<std::size_t>(i)];
  }
  const double inv = n ? 1.0 / static_cast<double>(n) : 0.0;
  const double cx = sx * inv, cy = sy * inv, cz = sz * inv;
  double L = 0.0;
  for (int i = 0; i < n; ++i) {
    const double dx = X[static_cast<std::size_t>(i)] - cx;
    const double dy = Y[static_cast<std::size_t>(i)] - cy;
    const double dz = Z[static_cast<std::size_t>(i)] - cz;
    L = std::max(L, std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  if (L <= 0.0) L = 1.0;
  std::vector<double> B(static_cast<std::size_t>(n) * 6, 0.0);
  for (int i = 0; i < n; ++i) {
    const int q = comp[static_cast<std::size_t>(i)];
    const double dx = (X[static_cast<std::size_t>(i)] - cx) / L;
    const double dy = (Y[static_cast<std::size_t>(i)] - cy) / L;
    const double dz = (Z[static_cast<std::size_t>(i)] - cz) / L;
    double* r = &B[static_cast<std::size_t>(i) * 6];
    r[q] = 1.0;                                   // translations
    if (q == 0) { r[4] = dz; r[5] = -dy; }        // rot y, rot z
    if (q == 1) { r[3] = -dz; r[5] = dx; }        // rot x, rot z
    if (q == 2) { r[3] = dy; r[4] = -dx; }        // rot x, rot y
  }
  return B;
}

// ============================================================================
// ENERGY CAPTURE. For SPD A0 and a coarse space range(W) (W: ng x m), the
// A-orthogonal projection of the exact u onto range(W) is W z with
//     (W^T A0 W) z = W^T A0 u = W^T b,
// and its energy is z^T (W^T A0 W) z = z . (W^T b). The exact solution's energy
// is u . b. The ratio is the fraction of the solution's energy the space can
// represent; 1 - ratio is what the smoother is left to remove alone.
//
// Ac is passed in already formed (the caller has it from the Galerkin chain), so
// this never re-touches the fine operator.
// ============================================================================
struct Capture {
  int dim = 0;
  double captured = 0.0;   // fraction of u's energy
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
// THE ALGEBRAIC COARSE SPACE, built from A1 by smoothed (or unsmoothed)
// aggregation. Returns the level-1 -> level-2 prolongator ONLY: this task's
// hypothesis keeps level 0 -> 1 geometric, so the aggregation never sees A0.
// ============================================================================
struct AlgLevel {
  amg::Csr P;
  int naggs = 0;
  int ncoarse = 0;
  double setup_s = 0.0;
  std::vector<int> dof2node_c;
  std::vector<double> Bc;
};

bool aggregate_once(const amg::Csr& A, const std::vector<int>& dof2node,
                    int nnodes, const std::vector<double>& B, double theta,
                    bool smooth, double omega_scale, AlgLevel& out) {
  const double t0 = now_ms();
  std::vector<i64> diagpos;
  std::vector<double> invdiag;
  amg::fill_diag(A, diagpos, invdiag);
  const amg::NodeGraph g = amg::build_strength_graph(A, dof2node, nnodes, theta);
  std::vector<int> agg;
  const int naggs = amg::aggregate(g, agg);
  int ncoarse = 0;
  amg::Csr T = amg::build_tentative(agg, naggs, dof2node, A.nrow, 6, B, out.Bc,
                                    ncoarse, out.dof2node_c, 1e-10);
  if (ncoarse <= 0 || ncoarse >= A.nrow) {
    out.setup_s = (now_ms() - t0) / 1e3;
    return false;
  }
  if (smooth) {
    const double lam = amg::gershgorin_dinva(A, diagpos);
    out.P = amg::smooth_prolongator(A, diagpos, T, omega_scale / lam);
  } else {
    out.P = std::move(T);
  }
  out.naggs = naggs;
  out.ncoarse = ncoarse;
  out.setup_s = (now_ms() - t0) / 1e3;
  return true;
}

SpMat eigen_from_csr(const amg::Csr& P) {
  std::vector<Trip> t;
  t.reserve(static_cast<std::size_t>(P.nnz()));
  for (int i = 0; i < P.nrow; ++i)
    for (i64 p = P.rowptr[i]; p < P.rowptr[i + 1]; ++p)
      t.emplace_back(i, P.col[p], P.val[p]);
  SpMat M(P.nrow, P.ncol);
  M.setFromTriplets(t.begin(), t.end());
  M.makeCompressed();
  return M;
}

// ============================================================================
// THE ONE-LEVEL-UP QUESTION. Everything above measures spaces BELOW level 1,
// which is what this task's hypothesis is about. But if the LEVEL-1 space is
// itself the deficient one, no aggregation beneath it can capture more than
// level 1 already does — the hypothesis would be aimed a level too low, and the
// maintainer needs to know that before a solver is designed. So the same
// instrument is pointed at an ALGEBRAIC LEVEL 1: aggregates built from the FINE
// operator instead of by halving.
//
// THIS DOES NOT ASSEMBLE LEVEL 0. amg_lean.hpp (PR 230's lean rebuild) streams
// the fine strength graph, the prolongator smoothing and the Galerkin product
// element-locally from the production `MatfreeReduced` — the same element table
// multigrid.cpp's own A1 build uses. The BLOCKED-STOP condition ("if aggregation
// from A1 requires assembling anything at level 0, STOP — that is pure AMG")
// is not tripped: nothing here builds A0. What IS out of scope is turning this
// into a production coarse space; that is a separate and much larger task, and
// this row exists to say whether it would be worth one.
// ============================================================================
struct L1Alg {
  int dim = 0;
  double captured = 0.0;
  double setup_s = 0.0;
  double nnz_per_row = 0.0;
  bool ok = false;
};

L1Alg algebraic_level1(const MatfreeReduced& m, const Vec& b, double energy,
                       const VoxelGrid& g, double theta, bool smooth) {
  L1Alg out;
  const double t0 = now_ms();
  amglean::FineMF F = amglean::build_fine(m);

  // The 6 rigid-body modes on the FINE kept DOFs — the elasticity near-nullspace
  // the aggregation is seeded with. Built from the grid node coordinates the
  // reduced system's kept_global map names.
  std::vector<double> B(static_cast<std::size_t>(F.ng) * 6, 0.0);
  {
    const int nxp = g.nx + 1, nyp = g.ny + 1;
    std::vector<double> X(static_cast<std::size_t>(F.ng)),
        Y(static_cast<std::size_t>(F.ng)), Z(static_cast<std::size_t>(F.ng));
    std::vector<int> comp(static_cast<std::size_t>(F.ng));
    double sx = 0, sy = 0, sz = 0;
    for (int i = 0; i < F.ng; ++i) {
      const int gd = m.kept_global[static_cast<std::size_t>(i)];
      const int nd = gd / 3;
      const int a = nd % nxp, bb = (nd / nxp) % nyp, c = nd / (nxp * nyp);
      X[static_cast<std::size_t>(i)] = a * g.spacing;
      Y[static_cast<std::size_t>(i)] = bb * g.spacing;
      Z[static_cast<std::size_t>(i)] = c * g.spacing;
      comp[static_cast<std::size_t>(i)] = gd % 3;
      sx += X[static_cast<std::size_t>(i)];
      sy += Y[static_cast<std::size_t>(i)];
      sz += Z[static_cast<std::size_t>(i)];
    }
    const double inv = F.ng ? 1.0 / static_cast<double>(F.ng) : 0.0;
    const double cx = sx * inv, cy = sy * inv, cz = sz * inv;
    double L = 0.0;
    for (int i = 0; i < F.ng; ++i) {
      const double dx = X[static_cast<std::size_t>(i)] - cx;
      const double dy = Y[static_cast<std::size_t>(i)] - cy;
      const double dz = Z[static_cast<std::size_t>(i)] - cz;
      L = std::max(L, std::sqrt(dx * dx + dy * dy + dz * dz));
    }
    if (L <= 0.0) L = 1.0;
    for (int i = 0; i < F.ng; ++i) {
      const int q = comp[static_cast<std::size_t>(i)];
      const double dx = (X[static_cast<std::size_t>(i)] - cx) / L;
      const double dy = (Y[static_cast<std::size_t>(i)] - cy) / L;
      const double dz = (Z[static_cast<std::size_t>(i)] - cz) / L;
      double* r = &B[static_cast<std::size_t>(i) * 6];
      r[q] = 1.0;
      if (q == 0) { r[4] = dz; r[5] = -dy; }
      if (q == 1) { r[3] = -dz; r[5] = dx; }
      if (q == 2) { r[3] = dy; r[4] = -dx; }
    }
  }

  const amg::NodeGraph gr =
      amglean::fine_strength_graph(F, theta, &out.nnz_per_row);
  std::vector<int> agg;
  const int naggs = amg::aggregate(gr, agg);
  std::vector<double> Bc;
  std::vector<int> coarse_agg;
  int ncoarse = 0;
  amg::Csr T = amg::build_tentative(agg, naggs, F.dof2node, F.ng, 6, B, Bc,
                                    ncoarse, coarse_agg, 1e-10);
  if (ncoarse <= 0 || ncoarse >= F.ng) {
    out.setup_s = (now_ms() - t0) / 1e3;
    return out;
  }
  amg::Csr P = smooth ? amglean::fine_smooth_prolongator(
                            F, T, (4.0 / 3.0) / F.lam_dinva)
                      : std::move(T);
  std::vector<int> cbase(static_cast<std::size_t>(naggs) + 1, 0);
  {
    std::vector<int> cnt(static_cast<std::size_t>(naggs), 0);
    for (int I = 0; I < ncoarse; ++I)
      cnt[static_cast<std::size_t>(coarse_agg[static_cast<std::size_t>(I)])]++;
    for (int a = 0; a < naggs; ++a)
      cbase[a + 1] = cbase[a] + cnt[static_cast<std::size_t>(a)];
  }
  const amg::Csr Ac = amglean::fine_galerkin(F, P, coarse_agg, naggs, cbase);
  const double setup_s = (now_ms() - t0) / 1e3;

  const SpMat Ace = eigen_from_csr(Ac);
  const SpMat Pe = eigen_from_csr(P);
  const Vec bc = Pe.transpose() * b;
  Capture c = capture_of(Ace, bc, energy);
  out.dim = ncoarse;
  out.captured = c.captured;
  out.setup_s = setup_s + c.setup_s;
  out.ok = c.ok;
  return out;
}

// ============================================================================
// The exact reference solve — matrix-free Jacobi-CG, which is the solver's own
// exact fallback, driven to the production certification tolerance.
// ============================================================================
struct Reference {
  MatfreeReduced m;
  Vec u;       // ng, exact displacement on the kept DOFs
  Vec b;       // ng, reduced right-hand side
  double energy = 0.0;
  int iters = 0;
  double resid = 0.0;
  bool converged = false;
  double wall_s = 0.0;
  double maxabs = 0.0;
};

Reference reference_solve(const VoxelGrid& g, const std::vector<double>& ey,
                          const Case& C, double tol, int maxit) {
  Reference R;
  CgInfo info;
  R.m = fea_detail::mf_build_reduced(g, 0.0, kNu, C.bcs, C.loads, &ey,
                                     "hybrid_amg_probe", &info);
  std::vector<double> x(static_cast<std::size_t>(R.m.ng), 0.0);
  int it = 0;
  double err = 0;
  bool conv = false;
  const double t0 = now_ms();
  fea_detail::mf_cg_solve(R.m, tol, maxit, x, it, err, conv);
  R.wall_s = (now_ms() - t0) / 1e3;
  R.u = Eigen::Map<const Vec>(x.data(), static_cast<Eigen::Index>(x.size()));
  R.b = Eigen::Map<const Vec>(R.m.rg.data(),
                              static_cast<Eigen::Index>(R.m.rg.size()));
  R.energy = R.u.dot(R.b);
  R.iters = it;
  R.resid = err;
  R.converged = conv;
  R.maxabs = R.u.size() ? R.u.cwiseAbs().maxCoeff() : 0.0;
  return R;
}

// ============================================================================
// MODE: capture (AF1, AF2)
// ============================================================================
struct CaptureRow {
  std::string name;
  int dim = 0;
  double captured = 0.0;
  double setup_s = 0.0;
  const char* kind = "";
};

void print_capture_header() {
  std::printf("\n%-42s %6s %10s %12s %10s\n", "coarse space", "kind", "dim",
              "captured E", "setup s");
  std::printf("%s\n", std::string(86, '-').c_str());
}

void print_capture_row(const CaptureRow& r) {
  std::printf("%-42s %6s %10d %11.4f%% %10.3f\n", r.name.c_str(), r.kind, r.dim,
              100.0 * r.captured, r.setup_s);
}

int mode_capture(const std::string& dir, const Case& C, std::size_t snap,
                 const char* label, FILE* csv) {
  const std::vector<double>& dens = C.traj[snap];
  const std::vector<double> ey = penalized_youngs(C.grid, dens);
  std::printf("\n## %s — snapshot %zu of %zu, grid %dx%dx%d, achieved_vf %.4f\n",
              label, snap, C.traj.size(), C.grid.nx, C.grid.ny, C.grid.nz,
              achieved_vf(C.grid, dens));
  print_load("start");

  // --- the exact reference solution ---------------------------------------
  std::printf("\n   AF1 step 1 — the EXACT reference solve (matrix-free "
              "Jacobi-CG, production tolerance %.0e):\n", kCertTol);
  Reference R = reference_solve(C.grid, ey, C, kCertTol, 200000);
  std::printf("      ng = %d reduced DOFs, %d iterations, converged %s, "
              "residual %.3e, max|u| = %.4e, wall %.1f s\n",
              R.m.ng, R.iters, R.converged ? "YES" : "NO", R.resid, R.maxabs,
              R.wall_s);
  if (!R.converged) {
    std::printf("      [reference did not converge — every capture below would "
                "be measured against a wrong u. STOP.]\n");
    return 1;
  }
  std::printf("      exact energy u.b = %.8e\n", R.energy);

  // --- the seam: A1 and P0, as the production builder formed them ----------
  const double tseam = now_ms();
  Seam S = capture_seam(C.grid, ey, C);
  if (!S.seen) {
    std::printf("      [the solver never reached the coarse-space seam — no "
                "matrix-free hierarchy was built on this field. STOP.]\n");
    return 1;
  }
  std::printf("\n   AF1 step 2 — the seam, as the PRODUCTION builder formed it:\n");
  std::printf("      P0: %d x %d (%lld nnz)   A1: %d x %d (%lld nnz)   "
              "level-1 grid %dx%dx%d nodes   capture wall %.1f s\n",
              static_cast<int>(S.p0.rows()), static_cast<int>(S.p0.cols()),
              static_cast<long long>(S.p0.nonZeros()), S.n1, S.n1,
              static_cast<long long>(S.a1.nnz()), S.cnx, S.cny, S.cnz,
              (now_ms() - tseam) / 1e3);
  if (static_cast<int>(S.p0.rows()) != R.m.ng) {
    std::printf("      [P0 has %d rows but the reduced system has %d DOFs — the "
                "two numberings differ. STOP.]\n",
                static_cast<int>(S.p0.rows()), R.m.ng);
    return 1;
  }

  // A1 must be the Galerkin operator of P0 on A0. Verified, not assumed: for a
  // random z, z^T A1 z must equal (P0 z)^T A0 (P0 z), which is checked
  // matrix-free through the production apply. This is what licenses every
  // capture number below.
  {
    Vec z = Vec::Zero(S.n1);
    std::uint64_t st = 88172645463325252ULL;
    for (int i = 0; i < S.n1; ++i) {
      st ^= st << 13; st ^= st >> 7; st ^= st << 17;
      z[i] = static_cast<double>(static_cast<std::int64_t>(st >> 11)) /
                 9007199254740992.0 - 0.5;
    }
    const SpMat A1e = eigen_from_csr(S.a1);
    const double lhs = z.dot(A1e * z);
    const Vec fz = S.p0 * z;
    std::vector<double> yv(static_cast<std::size_t>(R.m.ng));
    R.m.apply_kgg_raw(fz.data(), yv.data());
    const double rhs =
        fz.dot(Eigen::Map<const Vec>(yv.data(), static_cast<Eigen::Index>(yv.size())));
    const double rel = std::fabs(lhs - rhs) / std::max(1.0, std::fabs(rhs));
    std::printf("      A1 == P0^T A0 P0 check: z^T A1 z = %.10e vs "
                "(P0 z)^T A0 (P0 z) = %.10e   rel %.2e %s\n",
                lhs, rhs, rel, rel < 1e-10 ? "OK" : "MISMATCH");
    if (!(rel < 1e-10)) {
      std::printf("      [the seam is not the Galerkin operator of P0. STOP.]\n");
      return 1;
    }
  }

  const SpMat A1e = eigen_from_csr(S.a1);
  const Vec b1 = S.p0.transpose() * R.b;

  std::vector<CaptureRow> rows;
  // Rows are printed AS THEY ARE PRODUCED: some of the spaces below take
  // minutes to factor, and a table that only appears at the end makes a long
  // run indistinguishable from a hung one.
  print_capture_header();
  auto emit = [&rows](const CaptureRow& r) {
    rows.push_back(r);
    print_capture_row(r);
  };

  // --- AF1: the GEOMETRIC coarse spaces ------------------------------------
  {
    Capture c1 = capture_of(A1e, b1, R.energy);
    emit({"geometric level 1 (range P0)", c1.dim, c1.captured, c1.setup_s, "geo"});
    if (!c1.ok) std::printf("      [level-1 factorisation FAILED]\n");
  }

  // Geometric level 2 and 3, each the solver's own halving rule applied again.
  SpMat A_geo = A1e, P_chain;  // P_chain: level-1 -> level-k
  {
    int fnx = S.cnx, fny = S.cny, fnz = S.cnz;
    std::vector<int> factive = S.cactive;
    int fn = S.n1;
    SpMat W;  // level-1 -> level-k prolongator
    for (int lvl = 2; lvl <= 4; ++lvl) {
      SpMat P;
      int cnx, cny, cnz;
      std::vector<int> cactive;
      const double t0 = now_ms();
      if (!geometric_prolongator(fnx, fny, fnz, factive, fn, P, cnx, cny, cnz,
                                 cactive))
        break;
      W = (lvl == 2) ? P : SpMat(W * P);
      A_geo = SpMat(P.transpose() * (A_geo * P));
      const double build_s = (now_ms() - t0) / 1e3;
      const Vec bk = W.transpose() * b1;
      Capture ck = capture_of(A_geo, bk, R.energy);
      char nm[64];
      std::snprintf(nm, sizeof nm, "geometric level %d (%dx%dx%d nodes)", lvl,
                    cnx, cny, cnz);
      emit({nm, ck.dim, ck.captured, ck.setup_s + build_s, "geo"});
      fnx = cnx; fny = cny; fnz = cnz;
      factive = cactive;
      fn = static_cast<int>(P.cols());
    }
  }

  // --- AF2: the ALGEBRAIC coarse space, from A1 ----------------------------
  // Swept over the strength threshold so the comparison can be made AT MATCHED
  // COARSE DIMENSION rather than at whatever size one theta happens to give.
  int nnodes1 = 0;
  const std::vector<int> d2n1 = dof2node_from_active(S.cactive, S.n1, nnodes1);
  const std::vector<double> B1 =
      rigid_body_modes(S.cnx, S.cny, S.cnz, S.cactive, S.n1,
                       2.0 * C.grid.spacing);
  std::printf("\n   AF2 — algebraic aggregation from A1 (%d level-1 nodes, "
              "%d DOFs). Sweeping theta so the comparison lands at MATCHED "
              "coarse dimension.\n", nnodes1, S.n1);

  const double thetas[] = {0.02, 0.04, 0.08, 0.12, 0.20, 0.30, 0.45};
  for (const bool smooth : {true, false})
    for (const double th : thetas) {
      AlgLevel L;
      if (!aggregate_once(S.a1, d2n1, nnodes1, B1, th, smooth, 4.0 / 3.0, L))
        continue;
      const double t0 = now_ms();
      const SpMat Pa = eigen_from_csr(L.P);
      const SpMat Aa = SpMat(Pa.transpose() * (A1e * Pa));
      const double gal_s = (now_ms() - t0) / 1e3;
      const Vec ba = Pa.transpose() * b1;
      Capture ca = capture_of(Aa, ba, R.energy);
      char nm[80];
      std::snprintf(nm, sizeof nm, "algebraic level 2  theta %.2f  %s", th,
                    smooth ? "smoothed P" : "P = T (unsmoothed)");
      emit({nm, ca.dim, ca.captured, L.setup_s + gal_s + ca.setup_s, "alg"});
    }

  // --- the one-level-up control: an ALGEBRAIC LEVEL 1, matrix-free ---------
  // Run only when the level-1 GEOMETRIC space turns out to be the ceiling, which
  // is the case in which this task's hypothesis is aimed a level too low. It is
  // reported as a separate row kind so nobody reads it as part of the hybrid.
  if (!rows.empty() && rows[0].captured < 0.5) {
    std::printf("\n   the level-1 GEOMETRIC space captured only %.4f%%, which "
                "CAPS every space below it. Pointing the same instrument one "
                "level up: an ALGEBRAIC level 1, aggregated from the FINE "
                "operator matrix-free (amg_lean.hpp; A0 is never assembled).\n",
                100.0 * rows[0].captured);
    // UNSMOOTHED first, and smallest theta first: those are the cheap cells.
    // A smoothed fine-level prolongator densifies the coarse operator, and its
    // direct factorisation is the most expensive thing in this probe — so the
    // sweep is BUDGETED and reports what it skipped rather than running for
    // hours or quietly dropping cells.
    double l1_spent = 0.0;
    const double l1_budget_s = std::getenv("HA_L1_BUDGET")
                                   ? std::atof(std::getenv("HA_L1_BUDGET"))
                                   : 900.0;
    for (const bool smooth : {false, true})
      for (const double th : {0.02, 0.08, 0.20}) {
        if (l1_spent > l1_budget_s) {
          std::printf("      [algebraic level 1, theta %.2f, %s: SKIPPED — the "
                      "sweep has spent %.0f s of its %.0f s budget]\n", th,
                      smooth ? "smoothed P" : "P = T", l1_spent, l1_budget_s);
          continue;
        }
        L1Alg a = algebraic_level1(R.m, R.b, R.energy, C.grid, th, smooth);
        l1_spent += a.setup_s;
        if (!a.ok) {
          std::printf("      [algebraic level 1, theta %.2f, %s: no usable "
                      "coarse space]\n", th, smooth ? "smoothed P" : "P = T");
          continue;
        }
        char nm[80];
        std::snprintf(nm, sizeof nm, "ALGEBRAIC level 1  theta %.2f  %s", th,
                      smooth ? "smoothed P" : "P = T (unsmoothed)");
        emit({nm, a.dim, a.captured, a.setup_s, "alg-L1"});
      }
  }

  if (csv) {
    std::fprintf(csv, "field,space,kind,dim,captured_energy,setup_s\n");
    for (const CaptureRow& r : rows)
      std::fprintf(csv, "%s,\"%s\",%s,%d,%.10f,%.4f\n", label, r.name.c_str(),
                   r.kind, r.dim, r.captured, r.setup_s);
  }
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: converge (AF3, AF4, AF7) — the hybrid V-cycle on the real field, driven
// through the PRODUCTION solver via the coarse-space seam.
// ============================================================================
// A hierarchy's shape, level by level, which is what AF4's DOF- and nnz-weighted
// costs are computed from. Level 0 (matrix-free) is NOT in here; entry 0 is
// level 1 (= A1), entry k is level 1+k.
struct Profile {
  std::vector<int> n;
  std::vector<i64> nnz;
};

// AF4's two currencies for ONE V-cycle, expressed as multiples of a FINE-level
// operator apply. The fine level (level 0) contributes (pre + post + 1) applies
// of A0; every level below contributes the same count weighted by its size — by
// DOF for the first figure, by NONZEROS for the second. The nnz figure is the
// honest one for a sparse apply, and it is the one that charges SMOOTHED
// aggregation for the denser operators it produces.
struct CycleCost {
  double dof_weighted = 0;
  double nnz_weighted = 0;
};

struct Run {
  std::string name;
  bool built = false;
  bool carried = false;
  int levels = 0;
  int cycles = 0;
  i64 matvecs = 0;
  double build_s = 0, cycle_s = 0, total_s = 0;
  double agg_s = 0;       // aggregation setup, charged separately (AF4)
  int fallback_iters = 0;
  double worst_du = 0, rel_du = 0;
  double resid = 0;
  Profile prof;
  CycleCost cost;
  double dof_work = 0, nnz_work = 0;  // cycle cost x cycles actually run
  bool from_hook = false;   // this row's hierarchy came from the seam
  bool hook_taken = false;  // ... and the SOLVER accepted it (see accepted())
};

// Build the algebraic prolongator chain from A1, down to `dof_cap`.
std::vector<MgCoo> algebraic_chain(const MgCoarseSeam& s, double theta,
                                   bool smooth, int dof_cap, int max_extra,
                                   double& agg_s, Profile& prof,
                                   double spacing) {
  const double t0 = now_ms();
  std::vector<MgCoo> out;
  amg::Csr A = csr_from_eigen_csc(s.n1, s.a1_outer, s.a1_inner, s.a1_val);
  prof.n.clear();
  prof.nnz.clear();
  prof.n.push_back(A.nrow);
  prof.nnz.push_back(A.nnz());
  int nnodes = 0;
  std::vector<int> d2n = dof2node_from_active(*s.cactive, s.n1, nnodes);
  std::vector<double> B =
      rigid_body_modes(s.cnx, s.cny, s.cnz, *s.cactive, s.n1, 2.0 * spacing);
  for (int k = 0; k < max_extra; ++k) {
    if (A.nrow <= dof_cap) break;
    AlgLevel L;
    if (!aggregate_once(A, d2n, nnodes, B, theta, smooth, 4.0 / 3.0, L)) break;
    if (static_cast<double>(A.nrow) < 1.15 * static_cast<double>(L.ncoarse)) break;
    out.push_back(coo_from_csr(L.P));
    const amg::Csr Pt = amg::transpose(L.P);
    A = amg::galerkin(A, L.P, Pt);
    prof.n.push_back(A.nrow);
    prof.nnz.push_back(A.nnz());
    d2n = std::move(L.dof2node_c);
    nnodes = L.naggs;
    B = std::move(L.Bc);
  }
  // The bottom level must be under the solver's direct-solve cap, or the solver
  // rejects the hierarchy and falls back to geometric. Trimming trailing levels
  // would hide that, so an over-cap bottom is simply reported as such.
  agg_s = (now_ms() - t0) / 1e3;
  return out;
}

// The GEOMETRIC hierarchy's shape below level 1, rebuilt here by the solver's own
// halving rule so the two profiles are comparable. Costs one Galerkin chain on
// the (small) level-1 operator.
Profile geometric_profile(const Seam& S, int dof_cap) {
  Profile p;
  SpMat A = eigen_from_csr(S.a1);
  p.n.push_back(static_cast<int>(A.cols()));
  p.nnz.push_back(A.nonZeros());
  int fnx = S.cnx, fny = S.cny, fnz = S.cnz, fn = S.n1;
  std::vector<int> factive = S.cactive;
  for (int lvl = 0; lvl < 8; ++lvl) {
    if (static_cast<int>(A.cols()) <= dof_cap) break;
    SpMat P;
    int cnx, cny, cnz;
    std::vector<int> cactive;
    if (!geometric_prolongator(fnx, fny, fnz, factive, fn, P, cnx, cny, cnz,
                               cactive))
      break;
    A = SpMat(P.transpose() * (A * P));
    p.n.push_back(static_cast<int>(A.cols()));
    p.nnz.push_back(A.nonZeros());
    fnx = cnx; fny = cny; fnz = cnz;
    factive = cactive;
    fn = static_cast<int>(P.cols());
  }
  return p;
}

CycleCost cycle_cost(const Profile& p, int ng, i64 nnz0_equiv, int pre, int post) {
  CycleCost c;
  const double per = pre + post + 1;
  c.dof_weighted = per;  // the fine level itself
  c.nnz_weighted = per;
  for (std::size_t l = 0; l < p.n.size(); ++l) {
    const bool bottom = l + 1 == p.n.size();
    const double w = bottom ? 1.0 : per;  // the bottom level is solved, not smoothed
    c.dof_weighted += w * static_cast<double>(p.n[l]) / static_cast<double>(ng);
    c.nnz_weighted += w * static_cast<double>(p.nnz[l]) /
                      static_cast<double>(nnz0_equiv);
  }
  return c;
}

Run run_one(const char* name, const VoxelGrid& g, const std::vector<double>& ey,
            const Case& C, const Reference& R, double ref_scale,
            fea_detail::MgCoarseSpaceHook hook, double* agg_s_out,
            Profile* prof_out) {
  Run r;
  r.name = name;
  fea_matfree_reset_mg_stagnation_latch();
  fea_detail::mg_reset_tuning();
  if (hook) fea_detail::mg_set_coarse_space_hook(std::move(hook));
  CgInfo info;
  FeaSolution sol;
  bool threw = false;
  try {
    sol = fea_solve_mgcg_matfree(g, ey, kNu, C.bcs, C.loads, kCertTol, 0, &info);
  } catch (const std::exception& e) {
    threw = true;
    std::printf("      [%s THREW: %s]\n", name, e.what());
  }
  fea_detail::mg_set_coarse_space_hook({});
  r.built = info.hier_built;
  r.carried = info.used_multigrid;
  r.levels = info.mg_levels;
  r.cycles = info.mg_cycles_attempted;
  r.matvecs = info.matvecs;
  r.build_s = info.t_mg_build_ms / 1e3;
  r.cycle_s = info.t_mg_ms / 1e3;
  r.total_s = info.t_total_ms / 1e3;
  r.resid = info.residual;
  r.fallback_iters = info.used_multigrid ? 0 : info.iterations;
  if (agg_s_out) r.agg_s = *agg_s_out;
  if (prof_out) r.prof = *prof_out;
  // AF7 — EXACTNESS, compared in the SAME numbering. `FeaSolution::u` is the
  // FULL displacement vector (one entry per node DOF); the reference is the
  // REDUCED one (kept DOFs only). Comparing them index-for-index would compare
  // two different vectors, so the reference is lifted through `kept_global`.
  if (!threw && sol.u.size() == static_cast<std::size_t>(R.m.ndof)) {
    for (int kg = 0; kg < R.m.ng; ++kg) {
      const std::size_t gd =
          static_cast<std::size_t>(R.m.kept_global[static_cast<std::size_t>(kg)]);
      r.worst_du = std::max(r.worst_du, std::fabs(sol.u[gd] - R.u[kg]));
    }
    r.rel_du = ref_scale > 0 ? r.worst_du / ref_scale : 0.0;
  }
  return r;
}

void print_run_header() {
  std::printf("\n%-46s %5s %8s %9s %11s %11s %8s %8s %8s %8s %9s\n",
              "configuration", "lvls", "cycles", "carried", "DOF-wtd", "nnz-wtd",
              "build_s", "aggr_s", "cycle_s", "TOTAL_s", "rel |du|");
  std::printf("%s\n", std::string(140, '-').c_str());
}

void print_run(const Run& r) {
  std::printf("%-46s %5d %8d %9s %11.1f %11.1f %8.3f %8.3f %8.3f %8.3f %9.2e%s\n",
              r.name.c_str(), r.levels, r.cycles,
              r.carried ? "YES" : (r.built ? "stag" : "NOBUILD"), r.dof_work,
              r.nnz_work, r.build_s, r.agg_s, r.cycle_s, r.total_s, r.rel_du,
              (r.from_hook && !r.hook_taken) ? "  [chain REFUSED -> geometric]"
                                             : "");
}

// The set of configurations AF3 measures. Both prolongator forms are here
// because PR 230's lean AMG rebuild found the UNSMOOTHED tentative prolongator
// (P = T) flipped the economics outright — smoothing P densifies every coarse
// operator below it, and on a nnz-weighted currency that is not free.
struct Cfg {
  const char* name;
  double theta;
  bool smooth;
};
const Cfg kCfgs[] = {
    {"hybrid: algebraic below 1, theta 0.02, smoothed P", 0.02, true},
    {"hybrid: algebraic below 1, theta 0.08, smoothed P", 0.08, true},
    {"hybrid: algebraic below 1, theta 0.20, smoothed P", 0.20, true},
    {"hybrid: algebraic below 1, theta 0.02, P = T", 0.02, false},
    {"hybrid: algebraic below 1, theta 0.08, P = T", 0.08, false},
    {"hybrid: algebraic below 1, theta 0.20, P = T", 0.20, false},
};

int mode_converge(const Case& C, std::size_t snap, const char* label,
                  FILE* csv) {
  const std::vector<double>& dens = C.traj[snap];
  const std::vector<double> ey = penalized_youngs(C.grid, dens);
  std::printf("\n## AF3/AF4/AF7 — %s, snapshot %zu, grid %dx%dx%d, "
              "achieved_vf %.4f\n", label, snap, C.grid.nx, C.grid.ny, C.grid.nz,
              achieved_vf(C.grid, dens));
  print_load("start");

  std::printf("\n   the exact reference field (matrix-free Jacobi-CG at the "
              "production tolerance):\n");
  Reference R = reference_solve(C.grid, ey, C, kCertTol, 200000);
  std::printf("      %d iterations, converged %s, max|u| = %.4e, wall %.1f s\n",
              R.iters, R.converged ? "YES" : "NO", R.maxabs, R.wall_s);
  const double ref_scale = R.maxabs;
  const int ng = R.m.ng;
  // The fine level is MATRIX-FREE and has no nnz. Its assembled EQUIVALENT is
  // used as the nnz-weighted denominator: a hex-8 node couples to 27 nodes
  // (itself included) via 3x3 blocks, i.e. 81 entries per DOF row. Stated as the
  // proxy it is, so the nnz column is read as a ratio, not as a byte count.
  const i64 nnz0_equiv = static_cast<i64>(ng) * 81;

  // The geometric hierarchy's own shape, so the two cost profiles are comparable.
  Seam S = capture_seam(C.grid, ey, C);
  Profile geo;
  if (S.seen) geo = geometric_profile(S, 6000);

  std::vector<Run> runs;
  {
    Run r = run_one("SHIPPED (geometric, V, 1+1, scalar w0.6)", C.grid, ey, C,
                    R, ref_scale, {}, nullptr, &geo);
    r.cost = cycle_cost(r.prof, ng, nnz0_equiv, 1, 1);
    r.dof_work = r.cost.dof_weighted * r.cycles;
    r.nnz_work = r.cost.nnz_weighted * r.cycles;
    runs.push_back(r);
  }

  for (const Cfg& c : kCfgs) {
    double agg_s = 0;
    Profile prof;
    const double spacing = C.grid.spacing;
    auto hook = [&](const MgCoarseSeam& s) -> std::vector<MgCoo> {
      return algebraic_chain(s, c.theta, c.smooth, 6000, 8, agg_s, prof,
                             spacing);
    };
    Run r = run_one(c.name, C.grid, ey, C, R, ref_scale, hook, &agg_s, &prof);
    r.from_hook = true;
    // The solver applies its OWN acceptance rules to whatever the hook returns
    // (>= 2 levels, bottom under the direct-solve cap, bottom factorable) and
    // falls back to the geometric builder when they fail. A row whose chain was
    // refused is a GEOMETRIC row wearing an algebraic label, so it is marked as
    // one rather than quietly reported as the hybrid.
    r.hook_taken = r.prof.n.size() >= 2 &&
                   r.prof.n.back() <= fea_detail::mg_tuning().coarse_dof_cap;
    r.cost = cycle_cost(r.prof, ng, nnz0_equiv, 1, 1);
    r.dof_work = r.cost.dof_weighted * r.cycles;
    r.nnz_work = r.cost.nnz_weighted * r.cycles;
    runs.push_back(r);
  }

  print_run_header();
  for (const Run& r : runs) print_run(r);
  std::printf("\n   DOF-wtd / nnz-wtd are FINE-LEVEL-APPLY EQUIVALENTS: one "
              "V-cycle's work summed over levels, weighted by each level's DOF "
              "count (resp. nonzeros, against the %lld-entry assembled "
              "equivalent of the matrix-free fine operator), times the cycles "
              "actually run.\n", static_cast<long long>(nnz0_equiv));

  std::printf("\n   hierarchy shape below level 0 — n (nnz) per level:\n");
  for (const Run& r : runs) {
    if (r.prof.n.empty()) continue;
    std::printf("      %-46s", r.name.c_str());
    for (std::size_t l = 0; l < r.prof.n.size(); ++l)
      std::printf("  L%zu %d (%lld)", l + 1, r.prof.n[l],
                  static_cast<long long>(r.prof.nnz[l]));
    std::printf("\n");
  }

  // ------------------------------------------------------------------
  // AF5 — MEMORY. The honest question is not "what does the hierarchy cost"
  // but "what does the HYBRID ADD", because level 1 (A1) is built by production
  // today either way. Bytes are counted at Eigen's compressed layout: 8 for a
  // value + 4 for an inner index, plus 4 per column for the outer array.
  // ------------------------------------------------------------------
  auto op_bytes = [](i64 nnz, int n) {
    return static_cast<double>(nnz) * 12.0 + static_cast<double>(n) * 4.0;
  };
  std::printf("\n   AF5 — memory. Bytes BELOW level 1 (what the hybrid adds; "
              "level 1 itself is production's cost either way):\n");
  const double kProdDof = 8.44e6;
  for (const Run& r : runs) {
    if (r.prof.n.empty()) continue;
    double below = 0, l1 = op_bytes(r.prof.nnz[0], r.prof.n[0]);
    for (std::size_t l = 1; l < r.prof.n.size(); ++l)
      below += op_bytes(r.prof.nnz[l], r.prof.n[l]);
    // Projection to the production scale: level 1 tracks the fine DOF count
    // linearly (it is a fixed 1/8 vertex coarsening of it), and each algebraic
    // level below is a fixed fraction of level 1 on this field, so the whole
    // stack is scaled by the DOF ratio. Stated as the linear extrapolation it
    // is — an aggregation on a DIFFERENT field could coarsen differently.
    const double scale = kProdDof / static_cast<double>(ng);
    std::printf("      %-46s  L1 %7.2f MB   below-L1 %7.2f MB   -> at 8.44M "
                "DOF: L1 %6.2f GB, below-L1 %6.2f GB\n",
                r.name.c_str(), l1 / 1048576.0, below / 1048576.0,
                l1 * scale / 1073741824.0, below * scale / 1073741824.0);
  }
  std::printf("      PR 230 priced PURE AMG (an assembled FINE level) at 20-35 "
              "GB at 8.44M DOF. Nothing above assembles level 0.\n");

  if (csv) {
    std::fprintf(csv, "field,configuration,levels,cycles,carried,fine_applies,"
                      "dof_weighted_work,nnz_weighted_work,build_s,aggr_s,"
                      "cycle_s,total_s,rel_du,residual\n");
    for (const Run& r : runs)
      std::fprintf(csv,
                   "%s,\"%s\",%d,%d,%d,%lld,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,"
                   "%.6e,%.6e\n",
                   label, r.name.c_str(), r.levels, r.cycles, r.carried ? 1 : 0,
                   static_cast<long long>(r.matvecs), r.dof_work, r.nnz_work,
                   r.build_s, r.agg_s, r.cycle_s, r.total_s, r.rel_du, r.resid);
  }
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: energy — WHERE the solution's energy actually lives.
//
// A 1.6 % level-1 capture is a startling number, and a report that leaves it
// unexplained invites the wrong fix. The strain energy is exactly additive over
// elements — sum_e factor_e * (u_e^T Ke u_e) equals u^T A0 u — so the question
// "which material does the energy sit in?" is answered by one O(N) sweep of the
// production element table, with the identity itself used as the self-check.
//
// This is the row that says whether the coarse space is the right thing to fix
// at all.
// ============================================================================
int mode_energy(const Case& C, std::size_t snap, const char* label, FILE* csv) {
  const std::vector<double>& dens = C.traj[snap];
  const std::vector<double> ey = penalized_youngs(C.grid, dens);
  std::printf("\n## WHERE THE ENERGY IS — %s, snapshot %zu, grid %dx%dx%d, "
              "achieved_vf %.4f\n", label, snap, C.grid.nx, C.grid.ny, C.grid.nz,
              achieved_vf(C.grid, dens));
  print_load("start");
  Reference R = reference_solve(C.grid, ey, C, kCertTol, 200000);
  std::printf("   reference: %d iterations, converged %s, max|u| = %.4e, "
              "energy u.b = %.8e\n", R.iters, R.converged ? "YES" : "NO",
              R.maxabs, R.energy);
  if (!R.converged) return 1;

  // u on the FULL DOF numbering: a gated (void/fixed) DOF is zero there, which
  // is exactly how the operator treats it.
  std::vector<double> ufull(static_cast<std::size_t>(R.m.ndof), 0.0);
  for (int kg = 0; kg < R.m.ng; ++kg)
    ufull[static_cast<std::size_t>(
        R.m.kept_global[static_cast<std::size_t>(kg)])] = R.u[kg];

  // Bins by element density, on the SIMP scale the solver sees. rho_min is the
  // production void floor, so bin 0 is "as close to void as the model allows".
  const double edges[] = {1.5e-3, 5e-3, 2e-2, 5e-2, 0.1, 0.3, 0.6, 1.01};
  constexpr int kBins = 8;
  double e_bin[kBins] = {0};
  std::size_t n_bin[kBins] = {0};
  double total = 0.0;

  // The element table is SORTED BY COLOUR, not by voxel, so the bin is read off
  // the element's OWN modulus rather than by pairing it back to a voxel:
  // `factor` IS the per-voxel Young's modulus on the graded path, and this field
  // was built as E = rho^p * E0, so rho = (factor / E0)^(1/p) exactly.
  const auto& Ke = R.m.Ke;
  constexpr int kDofL = 24;
  for (const auto& el : R.m.elems) {
    double ue[kDofL];
    for (int r = 0; r < kDofL; ++r)
      ue[r] = ufull[static_cast<std::size_t>(el.edof[r])];
    double e = 0.0;
    for (int r = 0; r < kDofL; ++r) {
      double s = 0.0;
      for (int c = 0; c < kDofL; ++c) s += Ke(r, c) * ue[c];
      e += ue[r] * s;
    }
    e *= el.factor;
    total += e;
    const double rho = std::pow(std::max(el.factor, 0.0) / kE0,
                                1.0 / static_cast<double>(kSimpP));
    int b = kBins - 1;
    for (int q = 0; q < kBins; ++q)
      if (rho < edges[q]) { b = q; break; }
    e_bin[b] += e;
    n_bin[b]++;
  }

  double sum = total;
  std::printf("\n   element-energy identity check: sum_e factor_e u_e^T Ke u_e "
              "= %.8e vs u.b = %.8e   rel %.2e\n", sum, R.energy,
              std::fabs(sum - R.energy) / std::max(1.0, std::fabs(R.energy)));
  const char* lbl[kBins] = {"rho < 0.0015 (the void floor)",
                            "0.0015 <= rho < 0.005",
                            "0.005  <= rho < 0.02",
                            "0.02   <= rho < 0.05",
                            "0.05   <= rho < 0.10",
                            "0.10   <= rho < 0.30",
                            "0.30   <= rho < 0.60",
                            "rho >= 0.60 (solid)"};
  std::printf("\n%-34s %12s %14s %12s\n", "density bin", "elements",
              "energy", "share");
  std::printf("%s\n", std::string(76, '-').c_str());
  for (int q = 0; q < kBins; ++q)
    std::printf("%-34s %12zu %14.5e %11.4f%%\n", lbl[q], n_bin[q], e_bin[q],
                sum > 0 ? 100.0 * e_bin[q] / sum : 0.0);
  if (csv) {
    std::fprintf(csv, "field,bin,elements,energy,share\n");
    for (int q = 0; q < kBins; ++q)
      std::fprintf(csv, "%s,\"%s\",%zu,%.10e,%.8f\n", label, lbl[q], n_bin[q],
                   e_bin[q], sum > 0 ? e_bin[q] / sum : 0.0);
  }
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: leanconv — the capture number, cashed. Does a hierarchy whose LEVEL 1
// is algebraic actually converge on this field?
//
// This runs ENTIRELY IN THE HARNESS: amg_lean.hpp's matrix-free hierarchy over
// the production reduced operator (`FineMF::apply` is `m.apply_kgg_raw`, the
// production matvec) and its own PCG. No production path builds it, no seam is
// installed, nothing is armed. It exists so the 56-62 % capture figure is
// reported next to an iteration count instead of an inference, and so the
// maintainer can price a follow-on task on measurement.
//
// Reported honestly as an amg_lean measurement, NOT as a production V-cycle:
// its smoother is Chebyshev where production's is damped Jacobi, and its
// coarse levels use symmetric Gauss-Seidel. The comparison it licenses is
// "converges vs stagnates", not a wall ratio against the shipped solver.
// ============================================================================
int mode_leanconv(const Case& C, std::size_t snap, const char* label,
                  FILE* csv) {
  const std::vector<double>& dens = C.traj[snap];
  const std::vector<double> ey = penalized_youngs(C.grid, dens);
  std::printf("\n## ALGEBRAIC LEVEL 1, SOLVED — %s, snapshot %zu, grid "
              "%dx%dx%d, achieved_vf %.4f\n", label, snap, C.grid.nx, C.grid.ny,
              C.grid.nz, achieved_vf(C.grid, dens));
  print_load("start");
  Reference R = reference_solve(C.grid, ey, C, kCertTol, 200000);
  std::printf("   reference: %d Jacobi-CG iterations, converged %s, "
              "max|u| = %.4e, wall %.1f s\n", R.iters,
              R.converged ? "YES" : "NO", R.maxabs, R.wall_s);
  if (!R.converged) return 1;

  // The 6 rigid-body modes on the fine kept DOFs (same construction the capture
  // measurement uses).
  std::vector<double> B(static_cast<std::size_t>(R.m.ng) * 6, 0.0);
  {
    const int nxp = C.grid.nx + 1, nyp = C.grid.ny + 1;
    std::vector<double> X(static_cast<std::size_t>(R.m.ng)),
        Y(static_cast<std::size_t>(R.m.ng)), Z(static_cast<std::size_t>(R.m.ng));
    std::vector<int> comp(static_cast<std::size_t>(R.m.ng));
    double sx = 0, sy = 0, sz = 0;
    for (int i = 0; i < R.m.ng; ++i) {
      const int gd = R.m.kept_global[static_cast<std::size_t>(i)];
      const int nd = gd / 3;
      const int a = nd % nxp, bb = (nd / nxp) % nyp, c = nd / (nxp * nyp);
      X[static_cast<std::size_t>(i)] = a * C.grid.spacing;
      Y[static_cast<std::size_t>(i)] = bb * C.grid.spacing;
      Z[static_cast<std::size_t>(i)] = c * C.grid.spacing;
      comp[static_cast<std::size_t>(i)] = gd % 3;
      sx += X[static_cast<std::size_t>(i)];
      sy += Y[static_cast<std::size_t>(i)];
      sz += Z[static_cast<std::size_t>(i)];
    }
    const double inv = 1.0 / static_cast<double>(R.m.ng);
    const double cx = sx * inv, cy = sy * inv, cz = sz * inv;
    double L = 0.0;
    for (int i = 0; i < R.m.ng; ++i) {
      const double dx = X[static_cast<std::size_t>(i)] - cx;
      const double dy = Y[static_cast<std::size_t>(i)] - cy;
      const double dz = Z[static_cast<std::size_t>(i)] - cz;
      L = std::max(L, std::sqrt(dx * dx + dy * dy + dz * dz));
    }
    if (L <= 0.0) L = 1.0;
    for (int i = 0; i < R.m.ng; ++i) {
      const int q = comp[static_cast<std::size_t>(i)];
      const double dx = (X[static_cast<std::size_t>(i)] - cx) / L;
      const double dy = (Y[static_cast<std::size_t>(i)] - cy) / L;
      const double dz = (Z[static_cast<std::size_t>(i)] - cz) / L;
      double* r = &B[static_cast<std::size_t>(i) * 6];
      r[q] = 1.0;
      if (q == 0) { r[4] = dz; r[5] = -dy; }
      if (q == 1) { r[3] = -dz; r[5] = dx; }
      if (q == 2) { r[3] = dy; r[4] = -dx; }
    }
  }

  std::printf("\n%-38s %6s %8s %9s %10s %10s %10s\n", "configuration", "lvls",
              "PCG its", "converged", "setup_s", "solve_s", "rel |du|");
  std::printf("%s\n", std::string(100, '-').c_str());
  if (csv)
    std::fprintf(csv, "field,configuration,levels,pcg_iters,converged,setup_s,"
                      "solve_s,rel_du,amg_mb,final_rel\n");

  for (const bool smooth : {false, true})
    for (const double th : {0.02, 0.08}) {
      amglean::LeanOptions o;
      o.strength_theta = th;
      o.smooth_prolongator = smooth;
      const double t0 = now_ms();
      amglean::LeanHierarchy H = amglean::lean_setup(R.m, B, 6, o, [] {
        struct timespec t;
        timespec_get(&t, TIME_UTC);
        return t.tv_sec + t.tv_nsec / 1e9;
      });
      const double setup_s = (now_ms() - t0) / 1e3;
      char nm[64];
      std::snprintf(nm, sizeof nm, "amg_lean L1 algebraic  theta %.2f  %s", th,
                    smooth ? "smoothed" : "P = T");
      if (H.P0.nrow == 0) {
        std::printf("%-38s %6s %8s %9s %10.3f %10s %10s\n", nm, "-", "-",
                    "NOBUILD", setup_s, "-", "-");
        for (const std::string& n : H.level_notes)
          std::printf("      note: %s\n", n.c_str());
        continue;
      }
      const double t1 = now_ms();
      amg::SolveStats st = amglean::lean_pcg(H, R.m.rg, kCertTol, 300, o);
      const double solve_s = (now_ms() - t1) / 1e3;
      double worst = 0;
      for (int i = 0; i < R.m.ng; ++i)
        worst = std::max(worst,
                         std::fabs(st.solution[static_cast<std::size_t>(i)] -
                                   R.u[i]));
      const double rel = R.maxabs > 0 ? worst / R.maxabs : 0.0;
      std::printf("%-38s %6d %8d %9s %10.3f %10.3f %10.2e\n", nm, H.levels(),
                  st.cycles, st.converged ? "YES" : "no", setup_s, solve_s, rel);
      std::printf("      levels:");
      std::printf(" L0 %d (matrix-free)", H.fine.ng);
      for (int l = 0; l < H.coarse.levels(); ++l)
        std::printf("  L%d %d (%lld nnz)", l + 1, H.coarse.lv[l].A.nrow,
                    static_cast<long long>(H.coarse.lv[l].A.nnz()));
      std::printf("   AMG adds %.1f MB, final rel resid %.2e\n",
                  H.amg_bytes / 1048576.0, st.final_rel);
      for (const std::string& n : H.level_notes)
        std::printf("      note: %s\n", n.c_str());
      if (csv)
        std::fprintf(csv, "%s,\"%s\",%d,%d,%d,%.4f,%.4f,%.6e,%.3f,%.6e\n", label,
                     nm, H.levels(), st.cycles, st.converged ? 1 : 0, setup_s,
                     solve_s, rel, H.amg_bytes / 1048576.0, st.final_rel);
    }
  print_load("end");
  return 0;
}

// ============================================================================
// MODE: det (AF9) — the same hybrid configuration, twice, fingerprinted.
// ============================================================================
int mode_det(const Case& C, std::size_t snap, const char* label) {
  const std::vector<double>& dens = C.traj[snap];
  const std::vector<double> ey = penalized_youngs(C.grid, dens);
  std::printf("\n## AF9 — determinism, %s snapshot %zu\n", label, snap);
  print_load("start");
  const double spacing = C.grid.spacing;
  for (int rep = 0; rep < 2; ++rep) {
    double agg_s = 0;
    Profile prof;
    auto hook = [&](const MgCoarseSeam& s) -> std::vector<MgCoo> {
      return algebraic_chain(s, 0.08, false, 6000, 8, agg_s, prof, spacing);
    };
    fea_matfree_reset_mg_stagnation_latch();
    fea_detail::mg_set_coarse_space_hook(hook);
    CgInfo info;
    FeaSolution sol;
    try {
      sol = fea_solve_mgcg_matfree(C.grid, ey, kNu, C.bcs, C.loads, kCertTol, 0,
                                   &info);
    } catch (const std::exception& e) {
      std::printf("   [rep %d THREW: %s]\n", rep, e.what());
    }
    fea_detail::mg_set_coarse_space_hook({});
    Fnv f;
    for (double v : sol.u) f.add_d(v);
    std::printf("   rep %d: %d levels, %d cycles, carried %s, coarse dims", rep,
                info.mg_levels, info.mg_cycles_attempted,
                info.used_multigrid ? "YES" : "no");
    for (std::size_t l = 0; l < prof.n.size(); ++l)
      std::printf(" %d", prof.n[l]);
    std::printf(", fingerprint %016llx\n",
                static_cast<unsigned long long>(f.h));
  }
  print_load("end");
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  // Line-buffered, so a long run's progress is visible in a redirected log
  // instead of appearing all at once at the end.
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "capture";
  const std::string dir =
      argc > 2 ? argv[2] : "evidence/2026-08-03-hybrid-amg-coarsening-probe";

  // Every accelerator OFF: this probe measures the V-cycle and nothing else.
  fea_set_krylov_recycling(false);
  fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  fea_detail::mg_reset_tuning();

  const std::size_t snap =
      std::getenv("HA_SNAP") ? static_cast<std::size_t>(
                                   std::atol(std::getenv("HA_SNAP")))
                             : 2;

  auto load_stag = [&](Case& C) -> bool {
    const std::string path = dir + "/mg_stepbox_r32.bin";
    if (!cache_load(path, C)) {
      std::printf("   [no cached stagnating field at %s]\n", path.c_str());
      std::printf("   Produce it with:\n"
                  "     MG_STEP=core/tests/fixtures/demo/l-bracket.step "
                  "MG_RES=32 ./core/build/mg_component_sweep stag %s\n",
                  dir.c_str());
      return false;
    }
    std::printf("   fixture: PR 280's ladder32 reproduction, %zu trajectory "
                "snapshots, grid %dx%dx%d\n",
                C.traj.size(), C.grid.nx, C.grid.ny, C.grid.nz);
    return snap < C.traj.size();
  };

  if (mode == "capture") {
    Case C;
    if (!load_stag(C)) return 2;
    FILE* csv = std::fopen((dir + "/capture_stagnating.csv").c_str(), "w");
    const int rc = mode_capture(dir, C, snap, "stagnating(ladder32)", csv);
    if (csv) std::fclose(csv);
    return rc;
  }
  if (mode == "capture_healthy") {
    // 32x16x32, not the 64-scale control the CONVERGE row uses. The capture
    // measurement factors the level-1 operator directly, and a 64-scale healthy
    // block's A1 is ~55.6k DOFs — a 3D elasticity Cholesky whose fill-in dwarfs
    // every other cost in this probe and tells us nothing extra. The 32-scale
    // control is the same fixture at the scale PR 280 also reported it at.
    Case C = healthy_case(32, 16, 32, 0.6);
    FILE* csv = std::fopen((dir + "/capture_healthy.csv").c_str(), "w");
    const int rc = mode_capture(dir, C, 0, "healthy(rho 0.6, 32x16x32)", csv);
    if (csv) std::fclose(csv);
    return rc;
  }
  if (mode == "converge") {
    Case C;
    if (!load_stag(C)) return 2;
    FILE* csv = std::fopen((dir + "/converge_stagnating.csv").c_str(), "w");
    const int rc = mode_converge(C, snap, "stagnating(ladder32)", csv);
    if (csv) std::fclose(csv);
    std::printf("\n   peak RSS this process: %.2f GB\n",
                peak_rss_bytes() / (1024.0 * 1024.0 * 1024.0));
    return rc;
  }
  if (mode == "healthy") {
    Case C = healthy_case(64, 32, 64, 0.6);
    FILE* csv = std::fopen((dir + "/converge_healthy.csv").c_str(), "w");
    const int rc = mode_converge(C, 0, "healthy(rho 0.6, 64x32x64)", csv);
    if (csv) std::fclose(csv);
    std::printf("\n   peak RSS this process: %.2f GB\n",
                peak_rss_bytes() / (1024.0 * 1024.0 * 1024.0));
    return rc;
  }

  if (mode == "energy") {
    Case C;
    if (!load_stag(C)) return 2;
    FILE* csv = std::fopen((dir + "/energy_stagnating.csv").c_str(), "w");
    const int rc = mode_energy(C, snap, "stagnating(ladder32)", csv);
    if (csv) std::fclose(csv);
    return rc;
  }
  if (mode == "energy_healthy") {
    Case C = healthy_case(32, 16, 32, 0.6);
    FILE* csv = std::fopen((dir + "/energy_healthy.csv").c_str(), "w");
    const int rc = mode_energy(C, 0, "healthy(rho 0.6, 32x16x32)", csv);
    if (csv) std::fclose(csv);
    return rc;
  }
  if (mode == "leanconv") {
    Case C;
    if (!load_stag(C)) return 2;
    FILE* csv = std::fopen((dir + "/leanconv_stagnating.csv").c_str(), "w");
    const int rc = mode_leanconv(C, snap, "stagnating(ladder32)", csv);
    if (csv) std::fclose(csv);
    return rc;
  }
  if (mode == "leanconv_healthy") {
    Case C = healthy_case(64, 32, 64, 0.6);
    FILE* csv = std::fopen((dir + "/leanconv_healthy.csv").c_str(), "w");
    const int rc = mode_leanconv(C, 0, "healthy(rho 0.6, 64x32x64)", csv);
    if (csv) std::fclose(csv);
    return rc;
  }
  if (mode == "det") {
    Case C;
    if (!load_stag(C)) return 2;
    return mode_det(C, snap, "stagnating(ladder32)");
  }

  std::printf("usage: hybrid_amg_probe <capture|capture_healthy|converge|"
              "healthy|det> [dir]\n");
  return 2;
}
