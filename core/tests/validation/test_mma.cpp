// M7.mma.1 validation — the MMA (Method of Moving Asymptotes, Svanberg 1987)
// design updater, exposed behind SimpOptions.updater = MMA, is a drop-in
// alternative to the default Optimality-Criteria updater for the minimum-
// compliance problem with a single volume constraint. This test asserts the
// task's acceptance criteria:
//
//   * MMA reproduces the SIMP minimum-compliance benchmarks (the same 3D
//     cantilever and clamped-beam geometries as Gate V2) within 2% of the OC
//     references at the same volume fraction — the OC references are computed
//     here (no fixture is touched; the locked benchmarks.json is the PROJECTED
//     formulation and stays OC-only, per ROADMAP M7.mma.1 "NO fixture changes");
//   * both updaters meet the volume-fraction target and reduce compliance from
//     the uniform start;
//   * the MMA design stays in the admissible box and honours the move limit;
//   * MMA is correctly scoped for this task: combining it with a Heaviside
//     projection schedule, or with a passive-region mask, throws.
//
// Per-benchmark iteration counts are printed (informational, per the task).
//
// The finite-difference sensitivity checks the task also names ("existing FD
// sensitivity checks pass unchanged") live in test_simp.cpp and are unaffected:
// MMA consumes the same simp_compliance sensitivities OC does — only the design
// update rule differs — so those checks are not duplicated here.
//
// No third-party test framework (ARCHITECTURE §4); the same self-contained
// CHECK harness as the other tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SimpUpdater;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

// The two Gate-V2 benchmark problems, IDENTICAL geometry/BCs/loads/material/
// volfrac to fixtures/benchmarks.json (cantilever: clamp x=0, total Fz = -1 over
// the tip face; clamped beam: clamp both end faces, total Fz = -1 over the top
// center line). volfrac 0.3, E0 = 1, nu = 0.3, spacing 1.
struct Problem {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

Problem make_cantilever(int nx, int ny, int nz) {
  Problem pr;
  pr.grid = solid_grid(nx, ny, nz, 1.0);
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(pr.grid, 0, b, c);
      pr.bcs.push_back({n, 0, 0.0});
      pr.bcs.push_back({n, 1, 0.0});
      pr.bcs.push_back({n, 2, 0.0});
    }
  const double fz = -1.0 / static_cast<double>((ny + 1) * (nz + 1));
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      pr.loads.push_back({topopt::fea_node_index(pr.grid, nx, b, c), 2, fz});
  return pr;
}

Problem make_clamped_beam(int nx, int ny, int nz) {
  Problem pr;
  pr.grid = solid_grid(nx, ny, nz, 1.0);
  auto clamp_face = [&](int a) {
    for (int c = 0; c <= nz; ++c)
      for (int b = 0; b <= ny; ++b) {
        const int n = topopt::fea_node_index(pr.grid, a, b, c);
        pr.bcs.push_back({n, 0, 0.0});
        pr.bcs.push_back({n, 1, 0.0});
        pr.bcs.push_back({n, 2, 0.0});
      }
  };
  clamp_face(0);
  clamp_face(nx);
  const double fz = -1.0 / static_cast<double>(ny + 1);
  for (int b = 0; b <= ny; ++b)
    pr.loads.push_back({topopt::fea_node_index(pr.grid, nx / 2, b, nz), 2, fz});
  return pr;
}

SimpParams bench_params() {
  SimpParams p;
  p.youngs_modulus = 1.0;
  p.poisson = 0.3;
  p.penalty = 3.0;
  p.density_min = 1e-3;
  return p;
}

// Shared loop options for the OC-vs-MMA comparison: the plain (unprojected)
// compliance loop at volfrac 0.3, run to convergence with a tight CG tolerance.
// filter_radius is 2.5 — the SAME radius the committed benchmarks.json uses
// ("formulation_locked": rmin = 2.5). At that radius the minimum-compliance
// design is well-regularised (no near-degenerate single-voxel members), so OC
// and MMA converge to essentially the same layout (measured rel < 0.5% on both
// benchmarks) — a robust check that MMA reproduces the OC optimum, comfortably
// inside the 2% acceptance band. move 0.2 matches the OC path so the two
// updaters are compared at the same move limit.
SimpOptions bench_options() {
  SimpOptions opt;
  opt.volume_fraction = 0.3;
  opt.filter_radius = 2.5;
  opt.move = 0.2;
  opt.max_iterations = 150;
  opt.change_tol = 0.01;
  opt.cg_tolerance = 1e-9;
  return opt;
}

}  // namespace

int main() {
  const double kVolTol = 0.02;  // MMA within 2% of the OC reference compliance

  // ==========================================================================
  // 1. Benchmark parity: on both Gate-V2 geometries, MMA reproduces the OC
  //    minimum-compliance reference within 2% at the same volume fraction.
  // ==========================================================================
  struct Bench {
    const char* name;
    Problem pr;
  };
  std::vector<Bench> benches;
  benches.push_back({"cantilever_24x8x8", make_cantilever(24, 8, 8)});
  benches.push_back({"clamped_beam_48x8x8", make_clamped_beam(48, 8, 8)});

  const SimpParams p = bench_params();
  for (Bench& bench : benches) {
    const Problem& pr = bench.pr;

    SimpOptions oc = bench_options();
    oc.updater = SimpUpdater::OC;
    SimpOptions mma = bench_options();
    mma.updater = SimpUpdater::MMA;

    const SimpOptimizeResult roc =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, oc);
    const SimpOptimizeResult rmma =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, mma);

    const double rel = std::fabs(rmma.compliance - roc.compliance) /
                       std::fabs(roc.compliance);
    std::printf(
        "MMA %-20s: OC c=%.6f vf=%.4f it=%d | MMA c=%.6f vf=%.4f it=%d | "
        "rel=%.3f%%\n",
        bench.name, roc.compliance, roc.volume_fraction, roc.iterations,
        rmma.compliance, rmma.volume_fraction, rmma.iterations, 100.0 * rel);

    CHECK(roc.compliance > 0.0 && rmma.compliance > 0.0,
          "benchmark: both updaters produce a positive compliance");
    CHECK(rmma.compliance < rmma.initial_compliance,
          "benchmark: MMA reduces compliance from the uniform start");
    CHECK(near(rmma.volume_fraction, oc.volume_fraction, 1e-2),
          "benchmark: MMA meets the volume-fraction target");
    CHECK(near(roc.volume_fraction, oc.volume_fraction, 1e-2),
          "benchmark: OC meets the volume-fraction target");
    CHECK(rel <= kVolTol,
          "benchmark: MMA compliance within 2% of the OC reference");

    // MMA design stays in the admissible box and respects the move limit.
    bool box_ok = true;
    for (int k = 0; k < pr.grid.nz; ++k)
      for (int j = 0; j < pr.grid.ny; ++j)
        for (int i = 0; i < pr.grid.nx; ++i) {
          const double v = rmma.design[pr.grid.index(i, j, k)];
          if (v < p.density_min - 1e-12 || v > 1.0 + 1e-12) box_ok = false;
        }
    CHECK(box_ok, "benchmark: MMA design stays in [density_min, 1]");
    bool moves_ok = true;
    for (const topopt::SimpIteration& h : rmma.history)
      if (h.change > mma.move + 1e-9) moves_ok = false;
    CHECK(moves_ok, "benchmark: MMA per-iteration change respects the move limit");
  }

  // ==========================================================================
  // 2. Self-consistency of the MMA result on a small cantilever: the reported
  //    final state matches the SimpOptimizeResult contract (physical_density ==
  //    filter(design), compliance == compliance(physical_density)), exactly as
  //    for OC — MMA only changes the update rule, not the reporting.
  // ==========================================================================
  {
    Problem pr = make_cantilever(8, 4, 4);
    SimpOptions opt;
    opt.volume_fraction = 0.3;
    opt.filter_radius = 1.5;
    opt.move = 0.2;
    opt.max_iterations = 40;
    opt.change_tol = 0.005;
    opt.cg_tolerance = 1e-9;
    opt.updater = SimpUpdater::MMA;
    const SimpOptimizeResult r =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, opt);
    CHECK(r.iterations >= 1 && r.iterations <= opt.max_iterations,
          "small: MMA runs within the iteration cap");
    CHECK(r.history.size() == static_cast<std::size_t>(r.iterations),
          "small: one history entry per MMA iteration");
    CHECK(near(r.history.front().compliance, r.initial_compliance, 0.0),
          "small: initial_compliance == first history compliance");

    topopt::DensityFilter f = topopt::make_density_filter(pr.grid, opt.filter_radius);
    std::vector<double> xphys = f.filter_density(r.design);
    bool phys_ok = xphys.size() == r.physical_density.size();
    for (std::size_t e = 0; phys_ok && e < xphys.size(); ++e)
      if (!near(xphys[e], r.physical_density[e], 1e-12)) phys_ok = false;
    CHECK(phys_ok, "small: MMA physical_density == filter(design)");
    topopt::SimpCompliance rc = topopt::simp_compliance(
        pr.grid, p, r.physical_density, pr.bcs, pr.loads, opt.cg_tolerance, 0);
    CHECK(near(r.compliance, rc.compliance, 1e-5 * std::fabs(rc.compliance)),
          "small: MMA compliance == compliance(physical_density)");
    CHECK(near(r.volume_fraction, opt.volume_fraction, 1e-2),
          "small: MMA meets the volume target");
  }

  // ==========================================================================
  // 3. Scope guards (ROADMAP M7.mma.1): MMA is the plain compliance loop only.
  //    Combining it with a projection schedule, or with a passive-region mask,
  //    throws std::invalid_argument rather than silently misbehaving.
  // ==========================================================================
  {
    Problem pr = make_cantilever(6, 3, 3);

    SimpOptions proj = bench_options();
    proj.updater = SimpUpdater::MMA;
    proj.projection = {{1.0, 0.2, 4}};
    bool threw_proj = false;
    try {
      topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, proj);
    } catch (const std::invalid_argument&) {
      threw_proj = true;
    }
    CHECK(threw_proj, "scope: MMA + projection schedule throws");

    SimpOptions masked = bench_options();
    masked.updater = SimpUpdater::MMA;
    DesignMask mask = topopt::make_active_mask(pr.grid);
    bool threw_mask = false;
    try {
      topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, masked, mask);
    } catch (const std::invalid_argument&) {
      threw_mask = true;
    }
    CHECK(threw_mask, "scope: MMA + passive-region mask throws");

    // The OC masked path is unaffected (still runs).
    SimpOptions ocm = bench_options();
    ocm.max_iterations = 8;
    bool oc_masked_ok = true;
    try {
      topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, ocm, mask);
    } catch (...) {
      oc_masked_ok = false;
    }
    CHECK(oc_masked_ok, "scope: OC masked path still runs");
  }

  if (g_failures == 0) {
    std::printf("mma: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mma: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
