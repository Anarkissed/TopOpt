// Stress-constrained optimization on the MMA path (ROADMAP M7.mma.2).
//
// Covers the two things the task requires: (1) a finite-difference check of the
// AGGREGATED von Mises constraint sensitivity (the adjoint of
// simp_stress_aggregate) on a tiny grid, and (2) the BEHAVIORAL INVARIANTS of a
// stress-constrained run — (a) an unconstrained run leaves the aggregate above
// the cap, (b) the constrained run brings the aggregate to <= cap*(1+tol), and
// (c) the constraint costs compliance. The same self-contained CHECK harness as
// the other validation tests; public API only.
//
// The L-bracket reference fixture (core/tests/fixtures/demo/mma2_stress_fixture
// .json, maintainer-authored) pins the load case and the PLA-yield stress cap.
// Its _why_no_pinned_stress note is explicit that the re-entrant corner is a
// mesh-dependent singularity whose measured von Mises RISES with resolution and
// never converges, so NO absolute stress value is pinned. We consume the fixture
// to assert its invariant (a) on the committed geometry (the singular corner
// leaves the aggregate above the cap for any design at this load case). The
// invariants (b)/(c) of a CONSTRAINED L-bracket run at the fixture's yield cap
// are demonstrated on a FEASIBLE case here (Part 2) because the L-bracket cap is
// below the singular-corner stress floor at a CI-affordable resolution — see the
// M7.mma.2 handoff "## Blocked" note for the resolution/feasibility analysis.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"
#ifdef TOPOPT_HAVE_STEP
#include "topopt/step.hpp"
#include <fstream>
#include <sstream>
#include <string>
#endif

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <vector>

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SimpUpdater;
using topopt::StressAggregate;
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

// Clamp the whole x==0 face (removes rigid-body modes -> K_ff SPD).
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

// Transverse -z load spread over the free (x==nx) end-face nodes.
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

}  // namespace

int main() {
  // ==========================================================================
  // 1. M7.mma.2 GATE: finite-difference check of the AGGREGATED von Mises
  //    constraint sensitivity (the adjoint of simp_stress_aggregate) on a tiny
  //    non-uniform grid. Perturbing each physical density by +/-h and
  //    recomputing the P-norm aggregate (each a full primal solve) must match
  //    the analytic dg/drho (which itself runs one adjoint solve). Densities are
  //    kept strictly inside (rho_min, 1) so the clamp is inactive.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);

    const std::size_t N = g.voxel_count();
    std::vector<double> d(N, 0.0);
    for (std::size_t e = 0; e < N; ++e)
      d[e] = 0.4 + 0.5 * (static_cast<double>(e) / static_cast<double>(N - 1));

    const double p_norm = 8.0, q = 0.5;
    const double tol = 1e-13;
    const int maxit = 8000;
    StressAggregate base = topopt::simp_stress_aggregate(
        g, p, d, bcs, loads, p_norm, q, 0.5, tol, maxit);
    CHECK(base.cg.converged, "stress FD: base primal CG converged");
    CHECK(base.adjoint_cg.converged, "stress FD: base adjoint CG converged");
    CHECK(base.value > 0.0, "stress FD: aggregate is positive");
    CHECK(base.dvalue.size() == N, "stress FD: one sensitivity per voxel");

    const double h = 1e-5;
    const std::size_t probes[] = {0, 3, 7, 11, N - 1};
    double worst_rel = 0.0;
    for (std::size_t e : probes) {
      std::vector<double> dp = d, dm = d;
      dp[e] += h;
      dm[e] -= h;
      const double vp = topopt::simp_stress_aggregate(g, p, dp, bcs, loads,
                                                      p_norm, q, 0.5, tol, maxit)
                            .value;
      const double vm = topopt::simp_stress_aggregate(g, p, dm, bcs, loads,
                                                      p_norm, q, 0.5, tol, maxit)
                            .value;
      const double fd = (vp - vm) / (2.0 * h);
      const double an = base.dvalue[e];
      const double rel = std::fabs(fd - an) / std::max(std::fabs(an), 1e-30);
      worst_rel = std::max(worst_rel, rel);
      CHECK(rel < 1e-3,
            "stress FD: analytic dg/drho matches central finite difference");
    }
    std::printf("stress aggregate FD: worst relative error %.3e (tol 1e-3)\n",
                worst_rel);

    // Argument validation.
    auto throws_invalid = [&](double pn, double qq) {
      try {
        topopt::simp_stress_aggregate(g, p, d, bcs, loads, pn, qq);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    CHECK(throws_invalid(1.0, 0.5), "stress FD: p_norm <= 1 throws");
    CHECK(throws_invalid(8.0, 0.0), "stress FD: relaxation_q <= 0 throws");
    CHECK(throws_invalid(8.0, 3.0), "stress FD: relaxation_q >= penalty throws");
  }

  // ==========================================================================
  // 2. BEHAVIORAL INVARIANTS on a feasible case (a cantilever with a clamped-
  //    root stress concentration). The stress-constrained MMA run (M7.mma.2)
  //    must reproduce the three fixture invariants when the cap is reachable:
  //      (a) the unconstrained run leaves the aggregate ABOVE the cap;
  //      (b) the constrained run brings the aggregate to <= cap*(1+tol);
  //      (c) the constrained design's compliance >= the unconstrained design's
  //          at the same volume fraction (the constraint costs stiffness).
  //    Aggregation = P-norm (P = 8); relaxation = qp with q = 0.5 (< penalty).
  //    The recorded aggregation tolerance is tol = 0.15 (the P-norm/qp
  //    aggregation + finite-iteration slack; see the handoff / DECISIONS note).
  // ==========================================================================
  {
    const double p_norm = 8.0, q = 0.5, agg_tol = 0.15;
    VoxelGrid g = make_solid_grid(20, 10, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    SimpOptions opt;
    opt.volume_fraction = 0.5;
    opt.filter_radius = 1.5;
    opt.move = 0.1;
    opt.updater = SimpUpdater::MMA;
    opt.max_iterations = 100;
    opt.change_tol = 0.0;  // run the full cap (deterministic)
    opt.cg_tolerance = 1e-9;

    // Unconstrained compliance-minimizing MMA run and its stress aggregate.
    SimpOptimizeResult un = topopt::simp_optimize(g, p, bcs, loads, opt);
    StressAggregate ua = topopt::simp_stress_aggregate(
        g, p, un.physical_density, bcs, loads, p_norm, q, 0.5, 1e-10, 0);
    CHECK(un.compliance > 0.0, "feasible: unconstrained compliance positive");
    CHECK(ua.max_relaxed > 0.0, "feasible: unconstrained aggregate positive");

    // A reachable cap: 85% of the unconstrained aggregate (the constraint is a
    // genuine, active reduction rather than an impossible target).
    const double cap = 0.85 * ua.max_relaxed;

    StressConstraint sc;
    sc.stress_cap = cap;
    sc.p_norm = p_norm;
    sc.relaxation_q = q;
    sc.printed_threshold = 0.5;
    SimpOptimizeResult co =
        topopt::simp_optimize_stress(g, p, bcs, loads, opt, sc);
    StressAggregate ca = topopt::simp_stress_aggregate(
        g, p, co.physical_density, bcs, loads, p_norm, q, 0.5, 1e-10, 0);

    // (a) unconstrained aggregate strictly above the cap.
    CHECK(ua.max_relaxed > cap,
          "invariant (a): unconstrained aggregate exceeds the cap");
    // (b) constrained aggregate within the recorded aggregation tolerance.
    CHECK(ca.max_relaxed <= cap * (1.0 + agg_tol),
          "invariant (b): constrained aggregate <= cap*(1+tol)");
    // constraint is genuinely active: it reduced the aggregate.
    CHECK(ca.max_relaxed < ua.max_relaxed,
          "invariant (b): the stress constraint reduced the aggregate");
    // (c) the constraint costs compliance.
    CHECK(co.compliance >= un.compliance,
          "invariant (c): constrained compliance >= unconstrained (same vf)");
    // both runs held the same volume fraction.
    CHECK(std::fabs(co.volume_fraction - un.volume_fraction) < 1e-2,
          "feasible: constrained and unconstrained share the volume fraction");
    std::printf(
        "stress invariants (feasible): cap=%.4f  unconstrained_agg=%.4f  "
        "constrained_agg=%.4f (%.1f%% of cap)  compliance %.4f -> %.4f\n",
        cap, ua.max_relaxed, ca.max_relaxed, 100.0 * ca.max_relaxed / cap,
        un.compliance, co.compliance);

    // Scope guards: the stress path is MMA-only; a projection schedule and a
    // non-physical cap/aggregation are rejected.
    auto stress_throws = [&](const SimpOptions& o, const StressConstraint& s) {
      try {
        topopt::simp_optimize_stress(g, p, bcs, loads, o, s);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpOptions oproj = opt;
    oproj.projection = {{1.0, 0.2, 5}};
    CHECK(stress_throws(oproj, sc),
          "stress: a projection schedule is rejected on the stress path");
    StressConstraint sbad = sc;
    sbad.stress_cap = 0.0;
    CHECK(stress_throws(opt, sbad), "stress: stress_cap <= 0 throws");
    StressConstraint sbadq = sc;
    sbadq.relaxation_q = 3.0;
    CHECK(stress_throws(opt, sbadq),
          "stress: relaxation_q >= penalty throws");
  }

#ifdef TOPOPT_HAVE_STEP
  // ==========================================================================
  // 3. L-bracket reference fixture (core/tests/fixtures/demo/
  //    mma2_stress_fixture.json). Consume the committed fixture and assert its
  //    invariant (a) on the committed l-bracket.step geometry: at the fixture's
  //    load case the re-entrant-corner stress leaves the P-norm aggregate above
  //    the yield cap even for the STRONGEST (full-solid) design — so every
  //    design does, "the singular corner guarantees this at any resolution"
  //    (fixture unconstrained_exceeds_cap). No absolute stress value is pinned
  //    (fixture _why_no_pinned_stress). Runs at a CI-affordable resolution; the
  //    aggregate/peak is only ASSERTED to exceed the cap, never pinned.
  // ==========================================================================
  {
    // Read the maintainer-authored cap from the fixture (consume, don't pin).
    std::ifstream fx(std::string(DEMO_FIXTURE_DIR) + "/mma2_stress_fixture.json");
    CHECK(fx.good(), "L-bracket: stress fixture is present");
    std::stringstream ss;
    ss << fx.rdbuf();
    const std::string txt = ss.str();
    const std::string key = "\"stress_cap_mpa\":";
    const std::size_t kpos = txt.find(key);
    CHECK(kpos != std::string::npos, "L-bracket: fixture defines stress_cap_mpa");
    double stress_cap = 0.0;
    if (kpos != std::string::npos)
      stress_cap = std::atof(txt.c_str() + kpos + key.size());
    CHECK(stress_cap > 0.0, "L-bracket: stress cap is positive");

    // Import the committed geometry and voxelize. The fixture pins resolution 48
    // for its independent NumPy reference; the singular corner exceeds the cap
    // at any resolution (fixture note), so a coarser CI resolution still asserts
    // invariant (a). PLA material properties (materials.json), pre-scaled to the
    // mm-MPa unit system used elsewhere in core.
    topopt::StepModel model = topopt::import_step_file(
        std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step");
    const int resolution = 16;
    VoxelGrid grid = topopt::voxelize(model.mesh, resolution);
    CHECK(grid.solid_count() > 0, "L-bracket: voxelization is non-empty");

    // Tag the fixture load case geometrically (never by OCCT face index):
    //  anchor = top of the upright wall (z = 60, wall x in [22, 30]) -> Fixture;
    //  load   = far plate face (x = -30, plate thickness z in [0, 8]) -> Load.
    const double zmax = grid.origin.z + grid.nz * grid.spacing;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!grid.solid(i, j, k)) continue;
          const topopt::Vec3 c = grid.voxel_center(i, j, k);
          if (c.z >= zmax - grid.spacing && c.x >= 22.0 && c.x <= 30.0)
            grid.set_tag(i, j, k, VoxelTag::Fixture);
          else if (c.x <= grid.origin.x + grid.spacing && c.z <= 8.0)
            grid.set_tag(i, j, k, VoxelTag::Load);
        }
    const std::vector<int> fnodes =
        topopt::fea_tagged_nodes(grid, VoxelTag::Fixture);
    CHECK(!fnodes.empty(), "L-bracket: anchor face tagged some voxels");
    std::vector<DirichletBC> bcs;
    for (int n : fnodes)
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    // Total downward force 1220 N over the loaded plate face (consistent nodal
    // traction), per the fixture load spec.
    const std::vector<NodalLoad> loads = topopt::traction_loads(
        grid, VoxelTag::Load, topopt::Vec3{0.0, 0.0, -1220.0});
    CHECK(!loads.empty(), "L-bracket: load face carries a traction");

    SimpParams p;
    p.youngs_modulus = 3500.0;  // PLA E (MPa)
    p.poisson = 0.33;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    // Invariant (a): even the full-solid design leaves the aggregate above the
    // cap. Full solid is the minimum-stress design at this resolution, so every
    // design does -> the unconstrained optimum certainly does.
    std::vector<double> full(grid.voxel_count(), 0.0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i)
          if (grid.solid(i, j, k)) full[grid.index(i, j, k)] = 1.0;
    StressAggregate fa = topopt::simp_stress_aggregate(grid, p, full, bcs, loads,
                                                       8.0, 0.5, 0.5, 1e-9, 0);
    CHECK(fa.cg.converged, "L-bracket: full-solid primal CG converged");
    CHECK(fa.max_von_mises > stress_cap,
          "L-bracket invariant (a): peak von Mises exceeds the cap");
    CHECK(fa.value > stress_cap,
          "L-bracket invariant (a): aggregate exceeds the cap");
    std::printf(
        "L-bracket (res %d): full-solid peak von Mises %.1f MPa, aggregate "
        "%.1f MPa vs cap %.1f MPa (ratio %.2f) - singular corner exceeds cap\n",
        resolution, fa.max_von_mises, fa.value, stress_cap,
        fa.max_von_mises / stress_cap);

    // A stress-constrained MMA run ON the fixture geometry, targeting the yield
    // cap. It asserts the invariants that hold at a CI-affordable resolution:
    //   (a) the unconstrained optimized design leaves the aggregate above the cap;
    //   the stress constraint REDUCES the aggregate (it is active); and
    //   (c) the constrained design's compliance >= the unconstrained design's at
    //   the same volume fraction.
    // NOTE: it does NOT assert the aggregate reaches the cap. At this resolution
    // the singular-corner stress floor (see the full-solid peak above) exceeds
    // the yield cap and no stress-relieving fillet forms; driving the aggregate
    // to the cap needs a fine mesh (~res 48) and is documented as blocked in the
    // M7.mma.2 handoff.
    SimpOptions lopt;
    lopt.volume_fraction = 0.5;
    lopt.filter_radius = 1.5;
    lopt.move = 0.1;
    lopt.updater = SimpUpdater::MMA;
    lopt.max_iterations = 60;
    lopt.change_tol = 0.0;
    lopt.cg_tolerance = 1e-8;

    SimpOptimizeResult lun = topopt::simp_optimize(grid, p, bcs, loads, lopt);
    StressAggregate lua = topopt::simp_stress_aggregate(
        grid, p, lun.physical_density, bcs, loads, 8.0, 0.5, 0.5, 1e-9, 0);
    CHECK(lua.max_relaxed > stress_cap,
          "L-bracket invariant (a): unconstrained optimum aggregate exceeds cap");

    StressConstraint lsc;
    lsc.stress_cap = stress_cap;
    lsc.p_norm = 8.0;
    lsc.relaxation_q = 0.5;
    lsc.printed_threshold = 0.5;
    SimpOptimizeResult lco =
        topopt::simp_optimize_stress(grid, p, bcs, loads, lopt, lsc);
    StressAggregate lca = topopt::simp_stress_aggregate(
        grid, p, lco.physical_density, bcs, loads, 8.0, 0.5, 0.5, 1e-9, 0);
    // The stress constraint is active: it materially reduces the aggregate.
    CHECK(lca.max_relaxed < 0.9 * lua.max_relaxed,
          "L-bracket: the stress constraint reduces the aggregate");
    // (c) the constraint costs compliance at the same volume fraction.
    CHECK(lco.compliance >= lun.compliance,
          "L-bracket invariant (c): constrained compliance >= unconstrained");
    CHECK(std::fabs(lco.volume_fraction - lun.volume_fraction) < 1e-2,
          "L-bracket: constrained and unconstrained share the volume fraction");
    std::printf(
        "L-bracket constrained: aggregate %.1f -> %.1f MPa (cap %.1f, still "
        "above - res-limited fillet), compliance %.4e -> %.4e\n",
        lua.max_relaxed, lca.max_relaxed, stress_cap, lun.compliance,
        lco.compliance);
  }
#endif  // TOPOPT_HAVE_STEP

  if (g_failures == 0) {
    std::printf("stress: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "stress: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
