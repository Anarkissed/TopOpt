// M7.mma projection-gate (Option B) validation. After the M7.mma.4 switchover
// MMA is the production default updater, but the app/bridge run path
// (run_minimize_plastic_loadcase -> enable_projection) turned on a Heaviside
// projection schedule unconditionally — and simp_optimize REJECTS MMA + a
// projection schedule (the projected chain is the OC-locked Gate-V2 formulation),
// so real MMA runs threw. The fix gates projection on the updater: it is applied
// only when projection_supported(updater), i.e. only under OC. This test pins
// that gate.
//
// The gate itself lives in the bridge's enable_projection, a SwiftPM C++ target
// that is NOT part of this CMake/ctest build. The DECISION it makes is the pure
// core predicate topopt::projection_supported(SimpUpdater) — the single source of
// truth the bridge calls. So we test the predicate directly AND both loop configs
// it selects between, at the public simp_optimize layer (no mesh/STL needed):
//
//   (a) MMA with a previously-projection-enabled config now runs without throwing
//       once the gate clears projection (and WOULD throw if projection were kept
//       — proving the gate is what unblocks it);
//   (b) OC with projection still applies projection, byte-identical to the
//       ungated OC + projection run (the gate is a no-op for OC — Gate-V2 stays
//       exactly as before).
//
// No third-party framework (ARCHITECTURE §4); the self-contained CHECK harness,
// public API only.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::ProjectionStage;
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

struct Problem {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

// A small clamped-tip cantilever (same shape as the Gate-V2 cantilever, sized
// down for a fast projected run): clamp x=0, total Fz = -1 over the tip face.
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

SimpParams bench_params() {
  SimpParams p;
  p.youngs_modulus = 1.0;
  p.poisson = 0.3;
  p.penalty = 3.0;
  p.density_min = 1e-3;
  return p;
}

SimpOptions base_options() {
  SimpOptions opt;
  opt.volume_fraction = 0.3;
  opt.filter_radius = 2.5;
  opt.move = 0.2;
  opt.max_iterations = 40;
  opt.change_tol = 0.01;
  opt.cg_tolerance = 1e-9;
  opt.projection_eta = 0.5;
  return opt;
}

// A short (2-stage) Heaviside schedule — stands in for the locked production
// schedule enable_projection installs. The gate decision does not depend on the
// schedule length, so a small one keeps this test fast while still producing a
// visibly projected (near-0/1) design under OC.
std::vector<ProjectionStage> short_schedule() {
  return {{1.0, 0.2, 8}, {4.0, 0.2, 8}};
}

// The EXACT decision the bridge run-path helper (enable_projection) makes: start
// from a projection-enabled config and keep the schedule only when the updater
// supports it. Mirrored here so the test exercises the shipped predicate.
SimpOptions gated_options(SimpUpdater updater,
                          const std::vector<ProjectionStage>& schedule) {
  SimpOptions opt = base_options();
  opt.updater = updater;
  if (topopt::projection_supported(updater)) opt.projection = schedule;
  return opt;
}

// Fraction of physical-density values that are crisp (near 0 or 1) — projection
// pushes the design toward 0/1, so a projected run is markedly crisper than the
// grayscale plain-loop result.
double crisp_fraction(const std::vector<double>& xphys) {
  std::size_t crisp = 0;
  for (double v : xphys)
    if (v < 0.05 || v > 0.95) ++crisp;
  return xphys.empty() ? 0.0
                       : static_cast<double>(crisp) /
                             static_cast<double>(xphys.size());
}

}  // namespace

int main() {
  const SimpParams p = bench_params();
  const std::vector<ProjectionStage> schedule = short_schedule();

  // ==========================================================================
  // 0. The pure predicate: projection is supported ONLY under OC. This is the
  //    single source of truth the bridge's enable_projection gates on.
  // ==========================================================================
  CHECK(topopt::projection_supported(SimpUpdater::OC),
        "predicate: projection supported under OC");
  CHECK(!topopt::projection_supported(SimpUpdater::MMA),
        "predicate: projection NOT supported under MMA");

  // ==========================================================================
  // (a) MMA + a previously-projection-enabled config. The gate clears the
  //     schedule, so the MMA run now completes without throwing. Kept, the same
  //     schedule WOULD throw — confirming the gate is what unblocks the run.
  // ==========================================================================
  {
    Problem pr = make_cantilever(12, 4, 4);

    // Ungated: MMA + projection is rejected (the bug the gate resolves).
    SimpOptions ungated = base_options();
    ungated.updater = SimpUpdater::MMA;
    ungated.projection = schedule;
    bool threw = false;
    try {
      topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, ungated);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "MMA: ungated projection schedule still throws (the bug)");

    // Gated: enable_projection's decision clears projection for MMA -> runs.
    SimpOptions gated = gated_options(SimpUpdater::MMA, schedule);
    CHECK(gated.projection.empty(),
          "MMA: gate skips the projection schedule");
    bool ran = false;
    SimpOptimizeResult r;
    try {
      r = topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, gated);
      ran = true;
    } catch (const std::exception&) {
      ran = false;
    }
    CHECK(ran, "MMA: gated run completes without throwing");
    CHECK(ran && r.compliance > 0.0 && r.compliance < r.initial_compliance,
          "MMA: gated run reduces compliance from the uniform start");
    CHECK(ran && std::fabs(r.volume_fraction - gated.volume_fraction) < 2e-2,
          "MMA: gated run meets the volume target");
  }

  // ==========================================================================
  // (b) OC + projection is unchanged. The gate keeps the schedule under OC, so
  //     the projected run is BYTE-IDENTICAL to the ungated OC + projection run
  //     (the gate is a no-op for OC — Gate-V2 stays exactly as before) and the
  //     projection visibly takes effect (crisp near-0/1 design vs. the plain
  //     grayscale loop).
  // ==========================================================================
  {
    Problem pr = make_cantilever(16, 6, 6);

    // Reference: OC + projection built directly (no gate).
    SimpOptions oc_ref = base_options();
    oc_ref.updater = SimpUpdater::OC;
    oc_ref.projection = schedule;
    const SimpOptimizeResult ref =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, oc_ref);

    // Same problem through the gate: projection retained for OC.
    SimpOptions oc_gated = gated_options(SimpUpdater::OC, schedule);
    CHECK(oc_gated.projection.size() == schedule.size(),
          "OC: gate retains the projection schedule");
    const SimpOptimizeResult gated =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, oc_gated);

    bool identical = ref.design.size() == gated.design.size() &&
                     ref.physical_density.size() ==
                         gated.physical_density.size();
    for (std::size_t e = 0; identical && e < ref.design.size(); ++e)
      if (ref.design[e] != gated.design[e]) identical = false;
    for (std::size_t e = 0; identical && e < ref.physical_density.size(); ++e)
      if (ref.physical_density[e] != gated.physical_density[e])
        identical = false;
    CHECK(identical && ref.compliance == gated.compliance &&
              ref.iterations == gated.iterations,
          "OC: gated == ungated OC+projection, byte-identical");

    // Projection actually applied: the projected design is far crisper than the
    // plain (no-projection) OC loop on the same problem.
    SimpOptions oc_plain = base_options();
    oc_plain.updater = SimpUpdater::OC;  // no projection schedule
    const SimpOptimizeResult plain =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, oc_plain);

    const double crisp_proj = crisp_fraction(gated.physical_density);
    const double crisp_plain = crisp_fraction(plain.physical_density);
    std::printf(
        "mma-proj-gate OC: crisp(projected)=%.3f crisp(plain)=%.3f "
        "c_proj=%.6f c_plain=%.6f\n",
        crisp_proj, crisp_plain, gated.compliance, plain.compliance);
    CHECK(crisp_proj > crisp_plain,
          "OC: projected design is crisper than the plain loop");
  }

  if (g_failures == 0) {
    std::printf("mma-projection-gate: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mma-projection-gate: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
