// MMA Heaviside projection + beta continuation (handoff 114 — "finish the
// design"). This is the MMA-CORRECT projection path, opt-in via
// SimpOptions::mma_projection, SEPARATE from the OC-locked `projection`
// schedule that test_mma_projection_gate guards (that gate — MMA rejects the
// `projection` schedule — is UNTOUCHED here and still green; this test never
// sets options.projection). What this pins:
//
//   (0) THE ONE RULE — opt-in, OFF == byte-identical. mma_projection defaults
//       false; a run with it false (even with the beta knobs set) is
//       bit-for-bit the plain grayscale MMA run.
//   (1) The honesty payoff (interaction c). Plain MMA leaves a gray ramp: the
//       discreteness Mnd is large and the CONTINUOUS volume fraction (Sigma
//       rho) diverges from the PRINTED fraction (#{rho>0.5}) — the 102/103
//       divergence. Projection drives the field near 0/1: Mnd collapses to the
//       <= 0.05 headline (at the beta-64 cap) and the two volume bases converge.
//   (2) The volume constraint is met on the PROJECTED density (what prints).
//   (3) beta continuation runs multiple stages and TERMINATES on a plateau at
//       the capped beta (composing with 086), not always the safety cap.
//   (4) Determinism: same inputs -> byte-identical output, twice.
//   (5) Min-feature contract (interaction d): the projected MMA design is no
//       worse on the §7-V3 2x2x2 min-feature metric than the ACCEPTED OC
//       projection on the same fixture (the 2x2x2 count does not go to zero
//       under projection on these coarse meshes — see benchmarks.json
//       honest_limitations — but MMA stays within OC's regime).
//   (6) Scoping: mma_projection under OC, with a projection schedule, with a bad
//       beta cap, or on the stress path is rejected (std::invalid_argument).
//   (7) The masked overload (the production loop) behaves the same.
//
// No third-party framework (ARCHITECTURE §4); the self-contained CHECK harness,
// public API only. Grids are built in code and kept small so the JacobiCG solve
// is fast; cg_tolerance is loosened to 1e-7 (behavioral test, not a parity gate).

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
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SimpUpdater;
using topopt::StressConstraint;
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

// A clamped-tip cantilever (clamp x=0, total Fz = -1 over the tip face) — the
// same family as the Gate-V2 / projection-gate cantilever.
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
  opt.filter_radius = 2.5;  // the 2.5-voxel min-feature filter
  opt.move = 0.2;
  opt.updater = SimpUpdater::MMA;
  opt.max_iterations = 300;  // headroom for the continuation stages
  opt.change_tol = 0.01;
  opt.cg_tolerance = 1e-7;
  opt.projection_eta = 0.5;
  return opt;
}

// Discreteness Mnd = mean over design voxels of 4 rho (1-rho): 0 crisp, 1 gray.
double discreteness_mnd(const VoxelGrid& g, const std::vector<double>& rho) {
  double acc = 0.0;
  std::size_t n = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const double r = rho[g.index(i, j, k)];
        acc += 4.0 * r * (1.0 - r);
        ++n;
      }
  return n > 0 ? acc / static_cast<double>(n) : 0.0;
}

// Continuous volume fraction Sigma rho / n_design.
double continuous_fraction(const VoxelGrid& g, const std::vector<double>& rho) {
  double s = 0.0;
  std::size_t n = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        s += rho[g.index(i, j, k)];
        ++n;
      }
  return n > 0 ? s / static_cast<double>(n) : 0.0;
}

// Printed fraction #{rho>0.5} / n_design (the mass / savings basis).
double printed_fraction(const VoxelGrid& g, const std::vector<double>& rho) {
  std::size_t p = 0, n = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        if (rho[g.index(i, j, k)] > 0.5) ++p;
        ++n;
      }
  return n > 0 ? static_cast<double>(p) / static_cast<double>(n) : 0.0;
}

double basis_divergence(const VoxelGrid& g, const std::vector<double>& rho) {
  return std::fabs(continuous_fraction(g, rho) - printed_fraction(g, rho));
}

bool designs_identical(const SimpOptimizeResult& a,
                       const SimpOptimizeResult& b) {
  if (a.physical_density.size() != b.physical_density.size()) return false;
  if (a.design.size() != b.design.size()) return false;
  for (std::size_t e = 0; e < a.design.size(); ++e)
    if (a.design[e] != b.design[e]) return false;
  for (std::size_t e = 0; e < a.physical_density.size(); ++e)
    if (a.physical_density[e] != b.physical_density[e]) return false;
  return a.compliance == b.compliance && a.iterations == b.iterations;
}

}  // namespace

int main() {
  const SimpParams p = bench_params();

  // ==========================================================================
  // (0) THE ONE RULE: mma_projection defaults false, and false is byte-for-byte
  //     the plain grayscale MMA run regardless of the (inert) beta knobs.
  // ==========================================================================
  {
    Problem pr = make_cantilever(20, 7, 7);
    SimpOptions plain = base_options();  // mma_projection defaults false
    CHECK(!plain.mma_projection, "default: mma_projection is OFF");
    const SimpOptimizeResult a =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, plain);

    SimpOptions off = base_options();
    off.mma_projection = false;      // explicit OFF
    off.mma_projection_beta0 = 4.0;  // knobs set but inert while OFF
    off.mma_projection_beta_max = 64.0;
    const SimpOptimizeResult b =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off);
    CHECK(designs_identical(a, b),
          "OFF path is byte-identical regardless of the (inert) beta knobs");
  }

  // ==========================================================================
  // (1)+(2)+(5) Honesty payoff + volume target + min-feature contract, on the
  //     24x8x8 cantilever (the Gate-V2 fixture family). Plain MMA vs MMA+proj
  //     (beta cap 64 -> the <= 0.05 headline) vs the ACCEPTED OC projection.
  // ==========================================================================
  {
    Problem pr = make_cantilever(24, 8, 8);

    SimpOptions off = base_options();
    const SimpOptimizeResult gray =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off);

    SimpOptions on = base_options();
    on.mma_projection = true;
    on.mma_projection_beta0 = 1.0;
    on.mma_projection_beta_max = 64.0;  // reaches the <= 0.05 headline
    const SimpOptimizeResult proj =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on);

    // Accepted reference: OC + the locked Heaviside continuation schedule.
    SimpOptions oc = base_options();
    oc.updater = SimpUpdater::OC;
    oc.projection = topopt::heaviside_continuation_schedule();
    const SimpOptimizeResult ocp =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, oc);

    const double mnd_gray = discreteness_mnd(pr.grid, gray.physical_density);
    const double mnd_proj = discreteness_mnd(pr.grid, proj.physical_density);
    const double div_gray = basis_divergence(pr.grid, gray.physical_density);
    const double div_proj = basis_divergence(pr.grid, proj.physical_density);
    const int mfv_proj =
        topopt::min_feature_violations(pr.grid, proj.physical_density, 0.5);
    const int mfv_oc =
        topopt::min_feature_violations(pr.grid, ocp.physical_density, 0.5);

    std::printf(
        "mma-proj 24x8x8: Mnd %.4f -> %.4f (OC-ref %.4f) | vol-basis div "
        "%.4f -> %.4f | c %.3f -> %.3f | it gray=%d proj=%d | mfv proj=%d "
        "OC=%d\n",
        mnd_gray, mnd_proj, discreteness_mnd(pr.grid, ocp.physical_density),
        div_gray, div_proj, gray.compliance, proj.compliance, gray.iterations,
        proj.iterations, mfv_proj, mfv_oc);

    CHECK(mnd_gray > 0.30, "plain MMA leaves a gray field (Mnd large)");
    CHECK(mnd_proj <= 0.05,
          "projection collapses Mnd to <= 0.05 at the beta-64 cap (headline)");
    CHECK(mnd_proj < 0.25 * mnd_gray, "projection cuts Mnd by well over 4x");
    CHECK(div_gray > 0.02,
          "plain MMA: continuous and printed volume diverge (102/103)");
    CHECK(div_proj < 0.01,
          "projection: the two volume bases collapse together (honesty)");
    CHECK(div_proj < 0.2 * div_gray,
          "projection shrinks the volume-basis divergence by over 5x");
    // Volume target on the PROJECTED density.
    CHECK(std::fabs(proj.volume_fraction - on.volume_fraction) < 3e-2,
          "projected run meets the volume target on the projected density");
    CHECK(proj.compliance > 0.0 &&
              proj.compliance < proj.initial_compliance,
          "projected run reduces compliance from the uniform start");
    // Min-feature contract: no worse than the accepted OC projection (the
    // 2x2x2 count does not zero on coarse meshes for EITHER path).
    CHECK(mfv_proj <= static_cast<int>(1.10 * mfv_oc) + 1,
          "projected MMA min-feature is within the accepted OC regime");
  }

  // ==========================================================================
  // (3)+(4) beta continuation multi-stage + plateau termination at the default
  //     cap (32) + determinism, on the 20x7x7 cantilever (cheaper). The
  //     compliance trajectory's upward jumps count the beta stage boundaries.
  // ==========================================================================
  {
    Problem pr = make_cantilever(20, 7, 7);
    SimpOptions on = base_options();
    on.mma_projection = true;
    on.mma_projection_beta0 = 1.0;
    on.mma_projection_beta_max = 32.0;  // 1,2,4,8,16,32 -> up to 5 doublings
    std::vector<double> traj;
    on.progress = [&traj](int, double c, double) { traj.push_back(c); };
    const SimpOptimizeResult r =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on);

    int jumps = 0;
    for (std::size_t i = 1; i < traj.size(); ++i)
      if (traj[i] > traj[i - 1] * 1.03) ++jumps;
    std::printf(
        "mma-proj continuation: %d beta jumps, %d iterations, conv=%d, "
        "Mnd=%.4f\n",
        jumps, r.iterations, static_cast<int>(r.converged),
        discreteness_mnd(pr.grid, r.physical_density));
    CHECK(jumps >= 2, "beta continuation advances through multiple stages");
    CHECK(r.converged,
          "run terminates on a plateau at the capped beta (not the cap)");
    CHECK(r.iterations < on.max_iterations,
          "termination is a real plateau, below the iteration safety cap");
    // Default-cap (32) collapse still clears the accepted OC cantilever bar
    // (benchmarks.json discreteness_Mnd_max = 0.1 for this fixture family).
    CHECK(discreteness_mnd(pr.grid, r.physical_density) <= 0.10,
          "default beta cap collapses Mnd within the accepted OC bar");

    // Determinism: reproduces byte-for-byte (drop the progress hook).
    SimpOptions on2 = on;
    on2.progress = nullptr;
    const SimpOptimizeResult a =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on2);
    const SimpOptimizeResult b =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, on2);
    CHECK(designs_identical(a, b),
          "projected MMA run is deterministic (twice-run byte-identical)");
  }

  // ==========================================================================
  // (6) Scoping / rejection: mma_projection is MMA-only, exclusive with the
  //     projection schedule, needs a valid beta cap, and is unsupported on the
  //     stress path.
  // ==========================================================================
  {
    Problem sm = make_cantilever(10, 4, 4);

    auto throws_invalid = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(sm.grid, p, sm.bcs, sm.loads, o);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };

    SimpOptions oc_proj = base_options();
    oc_proj.updater = SimpUpdater::OC;
    oc_proj.mma_projection = true;
    CHECK(throws_invalid(oc_proj), "mma_projection under OC is rejected");

    SimpOptions both = base_options();
    both.mma_projection = true;
    both.projection = {{1.0, 0.2, 4}};  // an OC-style schedule too
    CHECK(throws_invalid(both),
          "mma_projection + a projection schedule is rejected");

    SimpOptions bad_beta = base_options();
    bad_beta.mma_projection = true;
    bad_beta.mma_projection_beta_max = 0.5;  // < beta0
    CHECK(throws_invalid(bad_beta),
          "mma_projection_beta_max < beta0 is rejected");

    // Stress path rejects mma_projection.
    SimpOptions stress_opt = base_options();
    stress_opt.mma_projection = true;
    StressConstraint sc;
    sc.stress_cap = 1.0;
    bool threw = false;
    try {
      topopt::simp_optimize_stress(sm.grid, p, sm.bcs, sm.loads, stress_opt, sc);
    } catch (const std::invalid_argument&) {
      threw = true;
    } catch (...) {
    }
    CHECK(threw, "mma_projection on the stress path is rejected");
  }

  // ==========================================================================
  // (7) Masked overload (the production loop) — all-Active mask reproduces the
  //     unconstrained projected behavior: Mnd collapses and it converges.
  // ==========================================================================
  {
    Problem mpr = make_cantilever(18, 6, 6);
    DesignMask mask(mpr.grid.voxel_count(), MaskValue::Active);

    SimpOptions off = base_options();
    const SimpOptimizeResult gray =
        topopt::simp_optimize(mpr.grid, p, mpr.bcs, mpr.loads, off, mask);

    SimpOptions on = base_options();
    on.mma_projection = true;
    on.mma_projection_beta0 = 1.0;
    on.mma_projection_beta_max = 32.0;
    const SimpOptimizeResult crisp =
        topopt::simp_optimize(mpr.grid, p, mpr.bcs, mpr.loads, on, mask);

    const double mnd_gray = discreteness_mnd(mpr.grid, gray.physical_density);
    const double mnd_proj = discreteness_mnd(mpr.grid, crisp.physical_density);
    std::printf("mma-proj masked: Mnd %.4f -> %.4f | it %d conv=%d\n", mnd_gray,
                mnd_proj, crisp.iterations, static_cast<int>(crisp.converged));
    // On this small masked grid the default beta-32 cap collapses Mnd ~5x
    // (0.68 -> ~0.14); a finer grid or the beta-64 cap goes lower (the
    // unconstrained 24x8x8 headline reaches 0.03). The collapse ratio is the
    // guard here, with a generous absolute ceiling for the small grid.
    CHECK(mnd_proj <= 0.15, "masked projected run: Mnd collapses (<= 0.15)");
    CHECK(mnd_proj < 0.35 * mnd_gray,
          "masked projected run is far crisper than gray MMA");
    CHECK(crisp.converged, "masked projected run terminates on a plateau");
  }

  if (g_failures == 0) {
    std::printf("mma-projection: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mma-projection: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
