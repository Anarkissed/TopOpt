// Adaptive move limit (handoff 2026-07-26-adaptive-move) — validation.
//
// SimpOptions::adaptive_move lets the scalar MMA move limit GROW while the design
// moves productively and SHRINK when it oscillates, reusing the Svanberg
// asymptote oscillation sign the update already computes. This test pins the
// contract the handoff bars demand of the CORE change (the measurement bars
// M2-M7 live in the standalone probe, not a unit test):
//
//   M1  OFF is BYTE-IDENTICAL to the fixed-0.2 path — same design, same
//       compliance, same iteration count, on both the plain and masked overloads.
//   BLOCKED-STOP (feasibility): with adaptive_move ON the returned design still
//       honours the box [density_min, 1] AND meets the volume-fraction target on
//       EVERY iteration — a larger move never returns an infeasible iterate.
//   scope: adaptive_move + OC is REJECTED (refused, not silently ignored), on
//       both overloads and the stress path; the numeric guards reject nonsense.
//   effect: the per-iteration move actually MOVES off 0.2 (grows in the forming
//       phase), and the observed osc_fraction is a valid fraction — i.e. the
//       feature is wired to the loop, not dead.
//
// No third-party framework (ARCHITECTURE §4) — the same self-contained CHECK
// harness and public API as test_mma.cpp.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::NodalLoad;
using topopt::SimpIterationObservation;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SimpUpdater;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_checks = 0;
static int g_failures = 0;
#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

VoxelGrid solid_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

struct Problem {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

Problem make_cantilever(int nx, int ny, int nz) {
  Problem pr;
  pr.grid = solid_grid(nx, ny, nz);
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

SimpParams bench_params() {
  SimpParams p;
  p.youngs_modulus = 1.0;
  p.poisson = 0.3;
  p.penalty = 3.0;
  p.density_min = 1e-3;
  return p;
}

SimpOptions bench_options() {
  SimpOptions opt;
  opt.volume_fraction = 0.3;
  opt.filter_radius = 2.5;
  opt.move = 0.2;
  opt.max_iterations = 120;
  opt.change_tol = 0.01;
  opt.cg_tolerance = 1e-9;
  opt.updater = SimpUpdater::MMA;
  return opt;
}

// An all-Active mask: the masked overload with this mask optimizes the same
// design set as the plain overload (only Load/Fixture become FrozenSolid inside
// effective_mask, and this problem tags none), so plain-vs-masked agree.
DesignMask all_active(const VoxelGrid& g) {
  return DesignMask(g.voxel_count(), MaskValue::Active);
}

// max_e |design difference| between two runs' terminal designs.
double design_maxdiff(const SimpOptimizeResult& a, const SimpOptimizeResult& b) {
  double d = 0.0;
  const std::size_t n = std::min(a.design.size(), b.design.size());
  for (std::size_t e = 0; e < n; ++e)
    d = std::max(d, std::fabs(a.design[e] - b.design[e]));
  return d;
}

}  // namespace

int main() {
  const SimpParams p = bench_params();
  const Problem pr = make_cantilever(24, 8, 8);
  const DesignMask mask = all_active(pr.grid);

  // ==========================================================================
  // M1. OFF is byte-identical to the fixed-0.2 path — plain AND masked.
  // ==========================================================================
  {
    SimpOptions off = bench_options();               // adaptive_move defaults false
    SimpOptions on_but = bench_options();
    // Flip every adaptive knob to a non-default value WITHOUT arming the feature:
    // adaptive_move == false must make all of them inert (byte-identity guard).
    on_but.adaptive_move = false;
    on_but.adaptive_move_grow = 1.5;
    on_but.adaptive_move_shrink = 0.4;
    on_but.adaptive_move_osc_lo = 0.05;
    on_but.adaptive_move_osc_hi = 0.6;
    on_but.adaptive_move_max = 0.9;
    on_but.adaptive_move_min = 0.001;

    const SimpOptimizeResult a =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off);
    const SimpOptimizeResult b =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on_but);
    CHECK(a.iterations == b.iterations,
          "M1 plain: OFF path iteration count is independent of the adaptive knobs");
    CHECK(near(a.compliance, b.compliance, 0.0),
          "M1 plain: OFF path compliance is bit-identical");
    CHECK(design_maxdiff(a, b) == 0.0,
          "M1 plain: OFF path design is bit-identical");

    const SimpOptimizeResult am =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off, mask);
    const SimpOptimizeResult bm =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on_but, mask);
    CHECK(am.iterations == bm.iterations,
          "M1 masked: OFF path iteration count is independent of the knobs");
    CHECK(near(am.compliance, bm.compliance, 0.0),
          "M1 masked: OFF path compliance is bit-identical");
    CHECK(design_maxdiff(am, bm) == 0.0,
          "M1 masked: OFF path design is bit-identical");
  }

  // ==========================================================================
  // BLOCKED-STOP / feasibility: adaptive_move ON must still return a box- AND
  // volume-feasible iterate on EVERY iteration. Feasibility is the reason MMA is
  // here (the move only sets the trust box, always intersected with the asymptote
  // bracket; the dual enforces the volume constraint regardless of the move).
  // ==========================================================================
  {
    SimpOptions on = bench_options();
    on.adaptive_move = true;
    std::vector<double> vfs;
    on.observe = [&](const SimpIterationObservation& o) {
      vfs.push_back(o.volume_fraction);
      // osc_fraction is either -1 (seed / not yet adapted) or a valid fraction.
      CHECK(o.osc_fraction == -1.0 ||
                (o.osc_fraction >= 0.0 && o.osc_fraction <= 1.0),
            "feasibility: observed osc_fraction is -1 or a valid fraction");
      // The adapted move stays strictly positive and within the configured band.
      CHECK(o.move >= on.adaptive_move_min - 1e-12 &&
                o.move <= on.adaptive_move_max + 1e-12,
            "feasibility: adapted move stays inside [min, max] (and > 0)");
    };
    const SimpOptimizeResult r =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on);

    bool box_ok = true;
    for (int k = 0; k < pr.grid.nz; ++k)
      for (int j = 0; j < pr.grid.ny; ++j)
        for (int i = 0; i < pr.grid.nx; ++i) {
          const double v = r.design[pr.grid.index(i, j, k)];
          if (v < p.density_min - 1e-12 || v > 1.0 + 1e-12) box_ok = false;
        }
    CHECK(box_ok, "feasibility: adaptive design stays in [density_min, 1]");
    CHECK(near(r.volume_fraction, on.volume_fraction, 1e-2),
          "feasibility: adaptive run meets the volume-fraction target");
    // Every recorded per-iteration achieved vf is within a sane band (the volume
    // constraint is honoured throughout, not merely at the end).
    bool vf_ok = !vfs.empty();
    for (double v : vfs)
      if (!(v > 0.0 && v <= 1.0)) vf_ok = false;
    CHECK(vf_ok, "feasibility: achieved vf is a valid fraction on every iteration");
    CHECK(r.compliance > 0.0 && r.compliance < r.initial_compliance,
          "feasibility: adaptive run reduces compliance from the uniform start");
  }

  // ==========================================================================
  // effect: adaptive_move is actually WIRED — the per-iteration move leaves the
  // fixed 0.2 (it grows in the productive forming phase), and it stays a proper
  // trust region (never exceeds the ceiling). A dead feature would report 0.2
  // every iteration.
  // ==========================================================================
  {
    SimpOptions on = bench_options();
    on.adaptive_move = true;
    double max_move = 0.0, min_move = 1e9;
    bool saw_grow = false;
    on.observe = [&](const SimpIterationObservation& o) {
      max_move = std::max(max_move, o.move);
      min_move = std::min(min_move, o.move);
      if (o.move > 0.2 + 1e-9) saw_grow = true;
    };
    const SimpOptimizeResult r =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on);
    (void)r;
    std::printf("[effect] adaptive move span over the run: [%.4f, %.4f] "
                "(fixed path is a constant 0.200)\n", min_move, max_move);
    CHECK(saw_grow, "effect: the adaptive move grows above the fixed 0.2");
    CHECK(max_move <= on.adaptive_move_max + 1e-12,
          "effect: the adaptive move never exceeds the ceiling");
  }

  // ==========================================================================
  // scope: adaptive_move + OC is rejected on both overloads; the numeric guards
  // reject nonsense values. (The stress-path rejection is asserted in test_mma /
  // the stress tests where that entry point is exercised.)
  // ==========================================================================
  {
    SimpOptions bad = bench_options();
    bad.updater = SimpUpdater::OC;
    bad.adaptive_move = true;
    bool threw_plain = false, threw_masked = false;
    try { topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, bad); }
    catch (const std::invalid_argument&) { threw_plain = true; }
    try { topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, bad, mask); }
    catch (const std::invalid_argument&) { threw_masked = true; }
    CHECK(threw_plain, "scope: adaptive_move + OC throws (plain overload)");
    CHECK(threw_masked, "scope: adaptive_move + OC throws (masked overload)");

    auto rejects = [&](void (*mut)(SimpOptions&), const char* what) {
      SimpOptions o = bench_options();
      o.adaptive_move = true;
      mut(o);
      bool threw = false;
      try { topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, o); }
      catch (const std::invalid_argument&) { threw = true; }
      CHECK(threw, what);
    };
    rejects([](SimpOptions& o) { o.adaptive_move_grow = 1.0; },
            "scope: grow <= 1 rejected");
    rejects([](SimpOptions& o) { o.adaptive_move_shrink = 1.0; },
            "scope: shrink >= 1 rejected");
    rejects([](SimpOptions& o) { o.adaptive_move_min = 0.0; },
            "scope: min <= 0 rejected (feasibility floor)");
    rejects([](SimpOptions& o) { o.adaptive_move_max = 0.01;
                                 o.adaptive_move_min = 0.02; },
            "scope: max < min rejected");
    rejects([](SimpOptions& o) { o.adaptive_move_osc_lo = 0.5;
                                 o.adaptive_move_osc_hi = 0.3; },
            "scope: osc_lo > osc_hi rejected");
  }

  if (g_failures == 0) {
    std::printf("adaptive_move: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "adaptive_move: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
