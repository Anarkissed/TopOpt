// Determinism guard for the THREADED matrix-free element apply (matrix-free speed
// task). The apply threads a deterministic 8-colour (2x2x2) partition of the voxel
// grid: no two same-colour elements share a node, so each colour is race-free and
// every node's (up to 8) contributions accumulate in a FIXED colour order,
// independent of thread count or scheduling. This test is the guard the task
// requires against a scheduling-dependent scatter — a naive parallel scatter with
// atomics would give run-to-run / thread-count variation and silently break the
// 078 iteration-count parity.
//
// It asserts, on grids large enough to actually engage the worker pool:
//   a. BIT-IDENTICAL output across thread counts 1, 2, 4 and 8 — the reduced
//      solve (fea_solve_cg_matfree), the matrix-free multigrid solve
//      (fea_solve_mgcg_matfree) AND the bare operator (fea_matfree_apply). Not
//      "within a tolerance": the displacement/DOF values must match to the last
//      bit, or the scatter order depends on scheduling.
//   b. REPEATABLE: the same solve run twice at the same thread count is identical.
//   c. STILL CORRECT: the threaded matrix-free MG-CG matches the assembled
//      fea_solve_mgcg DOF-for-DOF within 1e-6 (the 078 same-answer guarantee holds
//      with threading on), and reports the SAME iteration count as the assembled
//      multigrid (the 18==18-style parity) at each thread count.
//
// Public API only (topopt/fea.hpp, topopt/voxel.hpp) + fea_set_matfree_threads.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

VoxelGrid make_solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

std::vector<DirichletBC> clamp_x0_face(const VoxelGrid& g) {
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return bcs;
}

std::vector<NodalLoad> tip_load_z(const VoxelGrid& g, double total) {
  std::vector<int> nodes;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      nodes.push_back(topopt::fea_node_index(g, g.nx, b, c));
  std::vector<NodalLoad> loads;
  const double per = total / static_cast<double>(nodes.size());
  for (int n : nodes) loads.push_back({n, 2, per});
  return loads;
}

// A coherent soft-void graded field (soft spherical core, rho_min^p = 1e-9), the
// same shape the 078 parity test uses — high contrast that still converges under
// geometric multigrid.
std::vector<double> graded_soft_core(const VoxelGrid& g, double e_solid) {
  std::vector<double> E(g.voxel_count(), e_solid);
  const double cx = g.nx * 0.5, cy = g.ny * 0.5, cz = g.nz * 0.5;
  const double R = 0.30 * g.nx;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double dx = i + 0.5 - cx, dy = j + 0.5 - cy, dz = k + 0.5 - cz;
        if (dx * dx + dy * dy + dz * dz < R * R)
          E[g.index(i, j, k)] = e_solid * 1e-9;  // soft-void core
      }
  return E;
}

// Count DOFs where two solutions differ by a single bit, and the max abs diff.
long bit_diff(const FeaSolution& a, const FeaSolution& b, double* maxd) {
  long n = 0;
  double m = 0.0;
  for (std::size_t i = 0; i < a.u.size(); ++i)
    if (a.u[i] != b.u[i]) {
      ++n;
      const double d = std::fabs(a.u[i] - b.u[i]);
      if (d > m) m = d;
    }
  *maxd = m;
  return n;
}

double max_rel_diff(const FeaSolution& a, const FeaSolution& b) {
  double maxu = 0.0, maxd = 0.0;
  for (std::size_t d = 0; d < a.u.size(); ++d) {
    maxu = std::max(maxu, std::fabs(a.u[d]));
    maxd = std::max(maxd, std::fabs(a.u[d] - b.u[d]));
  }
  return maxu > 0.0 ? maxd / maxu : maxd;
}

const int kThreadCounts[] = {1, 2, 4, 8};

}  // namespace

int main() {
  const double nu = 0.3, h = 1.0;

  // ==========================================================================
  // 1. BIT-IDENTICAL across thread counts — matrix-free MG-CG on a graded
  //    soft-void 48^3 grid. 48^3 has ~13.8k elements per colour, several times the
  //    per-chunk threshold, so th=2/4/8 genuinely run multiple pool workers (a
  //    grid whose colours were too small would thread trivially and prove nothing).
  //    Also parity with the assembled multigrid at every thread count.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(48, 48, 48, h);
    const std::vector<DirichletBC> bcs = clamp_x0_face(g);
    const std::vector<NodalLoad> loads = tip_load_z(g, 1.0);
    const std::vector<double> E = graded_soft_core(g, 2000.0);

    // Assembled multigrid reference (single-threaded, unrelated to the pool).
    CgInfo ia;
    const FeaSolution asmMg =
        topopt::fea_solve_mgcg(g, E, nu, bcs, loads, 1e-6, 0, &ia);

    FeaSolution ref;
    int ref_iters = -1;
    bool first = true;
    for (int th : kThreadCounts) {
      topopt::fea_set_matfree_threads(th);
      CgInfo im;
      const FeaSolution s =
          topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-6, 0, &im);
      CHECK(im.used_multigrid, "threads: matrix-free MG engages on graded 32^3");
      if (first) {
        ref = s;
        ref_iters = im.iterations;
        first = false;
        // Same answer as the assembled multigrid, DOF-for-DOF (078 guarantee).
        CHECK(max_rel_diff(s, asmMg) <= 1e-6,
              "threads: threaded matrix-free MG-CG == assembled MG-CG within 1e-6");
        CHECK(im.iterations == ia.iterations,
              "threads: matrix-free iteration count == assembled (parity holds)");
      } else {
        double maxd = 0.0;
        const long nd = bit_diff(s, ref, &maxd);
        char msg[128];
        std::snprintf(msg, sizeof(msg),
                      "threads: MG-CG bit-identical vs 1-thread (th=%d, diff=%ld, "
                      "maxd=%.3e)",
                      th, nd, maxd);
        CHECK(nd == 0, msg);
        CHECK(im.iterations == ref_iters,
              "threads: MG-CG iteration count independent of thread count");
      }
    }
  }

  // ==========================================================================
  // 2. BIT-IDENTICAL across thread counts — the exact matrix-free Jacobi-CG
  //    (fea_solve_cg_matfree) on a solid cantilever, and the bare operator apply
  //    (fea_matfree_apply). These exercise the apply on a different path than the
  //    multigrid one.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(24, 16, 16, h);
    const std::vector<DirichletBC> bcs = clamp_x0_face(g);
    const std::vector<NodalLoad> loads = tip_load_z(g, 1.0);

    FeaSolution refCg;
    bool firstCg = true;
    for (int th : kThreadCounts) {
      topopt::fea_set_matfree_threads(th);
      CgInfo ic;
      const FeaSolution s =
          topopt::fea_solve_cg_matfree(g, 2100.0, nu, bcs, loads, 1e-8, 0, &ic);
      if (firstCg) {
        refCg = s;
        firstCg = false;
      } else {
        double maxd = 0.0;
        const long nd = bit_diff(s, refCg, &maxd);
        CHECK(nd == 0,
              "threads: Jacobi-CG matrix-free bit-identical across thread counts");
      }
    }

    // Bare operator y = K x: build a deterministic input and compare the apply
    // across thread counts, bit-for-bit.
    const int ndof = 3 * topopt::fea_node_count(g);
    std::vector<double> x(static_cast<std::size_t>(ndof));
    for (int i = 0; i < ndof; ++i)
      x[static_cast<std::size_t>(i)] = std::sin(0.1 * i) + 0.3 * ((i % 7) - 3);
    std::vector<double> refY;
    bool firstY = true;
    for (int th : kThreadCounts) {
      topopt::fea_set_matfree_threads(th);
      const std::vector<double> y = topopt::fea_matfree_apply(g, 2100.0, nu, x);
      if (firstY) {
        refY = y;
        firstY = false;
      } else {
        long nd = 0;
        for (std::size_t i = 0; i < y.size(); ++i)
          if (y[i] != refY[i]) ++nd;
        CHECK(nd == 0,
              "threads: fea_matfree_apply (bare operator) bit-identical across "
              "thread counts");
      }
    }
  }

  // ==========================================================================
  // 3. REPEATABLE: the same solve run twice at the SAME (multi-)thread count is
  //    bit-identical (guards against any residual scheduling nondeterminism).
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(24, 24, 24, h);
    const std::vector<DirichletBC> bcs = clamp_x0_face(g);
    const std::vector<NodalLoad> loads = tip_load_z(g, 1.0);
    const std::vector<double> E = graded_soft_core(g, 2000.0);
    topopt::fea_set_matfree_threads(4);
    CgInfo i1, i2;
    const FeaSolution s1 =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-6, 0, &i1);
    const FeaSolution s2 =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-6, 0, &i2);
    double maxd = 0.0;
    const long nd = bit_diff(s1, s2, &maxd);
    CHECK(nd == 0, "threads: repeated 4-thread solve is bit-identical (run-to-run)");
    CHECK(i1.iterations == i2.iterations, "threads: repeated solve, same iters");
  }

  topopt::fea_set_matfree_threads(0);  // restore auto

  if (g_failures == 0) {
    std::printf("fea matfree threads: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "fea matfree threads: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
