// Correctness guards for the GENEO TWO-LEVEL DEFLATION (handoff
// 2026-07-29-geneo-arming) — the opt-in, LIBRARY-default-OFF SPD additive
// coarse-space correction on the matrix-free Jacobi-CG stagnation fallback
// (fea_set_geneo_twolevel; production arms it in configure_production_options).
//
// The bars this file enforces:
//
//   1. DEFAULT OFF / INERTNESS. With the feature off (the library default) a
//      solve engages nothing: no basis, zero lifecycle counters, geneo_action 0.
//      THE ONE RULE's CI face — the reference world never sees the deflation.
//
//   2. THE STAGNATION TRIGGER. A solve that converges under the trigger budget
//      never pays the eigensolve (armed but inert on a healthy-ish fallback);
//      a solve that burns the budget unconverged builds the basis IN-SOLVE
//      (action 3, trigger_burn == fea_geneo_trigger_iters()), restarts deflated,
//      and finishes in FEWER total iterations than the plain solve.
//
//   3. EXACTNESS. The deflated solve converges to the SAME field as the plain
//      solve (max|du|/max|u| <= 1e-6): every added term is SPD, so the compound
//      preconditioner changes the route, never the answer or the stopping test.
//
//   4. THE ENGAGEMENT GATE (handoff 2026-08-02-geneo-disarm), BOTH BRANCHES.
//      A held basis no longer carries the arming decision from one solve to the
//      next: each solve starts plain and must burn past the MEASURED all-in
//      price of the armed alternative (2*N_t + burn + 2*tail) before deflating.
//      DECLINE branch — on this fixture that price exceeds the plain solve, so
//      the gate keeps the solve plain (action 5), pays no refresh, reproduces
//      the plain field exactly, and KEEPS the basis for a later hard solve.
//      ENGAGE branch — with the threshold opened, the same held basis still
//      REFRESHES against moved moduli (action 2) and still deflates from
//      iteration 0 in well under half the plain count. The reuse policy is
//      intact; what changed is that it is paid for only when it is worth paying.
//
//   5. DETERMINISM. Reset + repeat produces bit-identical fields and identical
//      iteration counts (fixed LOBPCG seeds, fixed merge order, thread-count
//      independent) — and the gate takes the SAME decision on the same numbers,
//      because it compares counts and never a clock.
//
// Fixture: the phase-2 `hard` checkerboard high-contrast composite (n=32,
// cell=4, contrast 1e9) — many near-null modes, Jacobi-CG ~628 iterations, past
// the 500-iteration stagnation trigger. Small enough for CI, genuinely in the
// regime the feature exists for.

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/geneo.hpp"  // the harness-only probe override surface

using namespace topopt;

namespace {

int g_checks = 0;
int g_failures = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

struct Fixture {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<double> youngs;  // per-voxel penalized modulus
};

Fixture checkerboard(int n, int cs) {
  Fixture f;
  VoxelGrid& g = f.grid;
  g.nx = n;
  g.ny = n;
  g.nz = n;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Interior);
  for (int c = 0; c <= n; ++c)
    for (int b = 0; b <= n; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      f.bcs.push_back({nd, 0, 0.0});
      f.bcs.push_back({nd, 1, 0.0});
      f.bcs.push_back({nd, 2, 0.0});
    }
  for (int b = 0; b <= n; ++b)
    for (int c = 0; c <= n; ++c)
      f.loads.push_back(
          {fea_node_index(g, n, b, c), 2, -100.0 / ((n + 1.0) * (n + 1.0))});
  std::vector<double> rho(g.voxel_count(), 1.0);
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i)
        if ((((i / cs) + (j / cs) + (k / cs)) & 1) != 0)
          rho[g.index(i, j, k)] = 1e-3;
  for (int b = 0; b < n; ++b)
    for (int c = 0; c < n; ++c) {
      rho[g.index(0, b, c)] = 1.0;
      rho[g.index(n - 1, b, c)] = 1.0;
    }
  f.youngs.assign(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < rho.size(); ++e)
    f.youngs[e] = std::pow(std::max(1e-3, rho[e]), 3) * 3500.0;
  return f;
}

// The same composite on a grid with an ODD axis, so the multigrid hierarchy is
// REJECTED under parity-pad mode 0 and the solve lands in the Jacobi fallback —
// the documented test lever for exercising the path GenEO lives in.
Fixture checkerboard_odd(int n, int cs) {
  Fixture f = checkerboard(n, cs);
  VoxelGrid& g = f.grid;
  const int nz = n - 1;  // 31 for n=32: not coarsenable
  VoxelGrid go;
  go.nx = n; go.ny = n; go.nz = nz; go.spacing = 1.0; go.origin = Vec3{0, 0, 0};
  go.tags.assign(static_cast<std::size_t>(n) * n * nz, VoxelTag::Interior);
  std::vector<double> yo(go.voxel_count());
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i)
        yo[go.index(i, j, k)] = f.youngs[g.index(i, j, k)];
  Fixture o;
  o.grid = go;
  o.youngs = yo;
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= n; ++b) {
      const int nd = fea_node_index(go, 0, b, c);
      o.bcs.push_back({nd, 0, 0.0});
      o.bcs.push_back({nd, 1, 0.0});
      o.bcs.push_back({nd, 2, 0.0});
    }
  for (int b = 0; b <= n; ++b)
    for (int c = 0; c <= nz; ++c)
      o.loads.push_back(
          {fea_node_index(go, n, b, c), 2, -100.0 / ((n + 1.0) * (nz + 1.0))});
  return o;
}

struct Solve {
  std::vector<double> u;
  CgInfo info;
};

Solve solve(const Fixture& f) {
  Solve s;
  FeaSolution sol = fea_solve_cg_matfree(f.grid, f.youngs, 0.33, f.bcs, f.loads,
                                         1e-8, 60000, &s.info, nullptr, nullptr);
  s.u = std::move(sol.u);
  return s;
}

double rel_max_diff(const std::vector<double>& a, const std::vector<double>& b) {
  double num = 0, den = 0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    num = std::max(num, std::abs(a[i] - b[i]));
    den = std::max(den, std::abs(a[i]));
  }
  return den > 0 ? num / den : 0.0;
}

}  // namespace

int main() {
  Fixture f = checkerboard(32, 4);

  // --- 1. DEFAULT OFF / INERTNESS -----------------------------------------
  CHECK(!fea_geneo_twolevel_enabled(), "library default is OFF");
  CHECK(kGeneoTwoLevelLibraryDefaultOff,
        "the header default-off tripwire constant holds");
  // The standing-preconditioner PROBE (task geneo-standing-preconditioner-probe,
  // handoff 2026-08-02-geneo-standing-probe) added a harness-only override
  // surface for the recipe constants, and fea_geneo_trigger_iters() now reports
  // the EFFECTIVE trigger rather than the constant directly. Nothing in
  // production sets an override, so the effective value must still BE the
  // shipped recipe — asserted here so a stray override, or a probe default that
  // drifts from the tripwire, fails a test instead of silently changing what
  // production runs. (The probe measured that arming every solve LOSES 1.25x on
  // wall at this operating point, so 500 is the value that belongs here.)
  CHECK(fea_geneo_trigger_iters() == 500,
        "effective GenEO trigger is the shipped 500 at library default");
  CHECK(fea_geneo_rebuild_factor() == 2.0,
        "effective GenEO rebuild factor is the shipped 2.0");
  const Solve plain = solve(f);
  CHECK(plain.info.converged, "plain Jacobi-CG converges");
  CHECK(plain.info.geneo_action == 0 && plain.info.geneo_dim == 0,
        "off: geneo diagnostics stay 0");
  CHECK(fea_geneo_basis_builds() == 0 && fea_geneo_basis_dim() == 0,
        "off: no basis, no builds");
  std::printf("plain: %d iterations\n", plain.info.iterations);
  CHECK(plain.info.iterations > fea_geneo_trigger_iters(),
        "fixture is genuinely past the stagnation trigger");

  // --- 2+3. TRIGGER BUILD + EXACTNESS -------------------------------------
  fea_set_geneo_twolevel(true);
  fea_reset_geneo_basis();
  const Solve armed1 = solve(f);
  std::printf("armed#1: %d iterations, action=%d, Nt=%d, burn=%d\n",
              armed1.info.iterations, armed1.info.geneo_action,
              armed1.info.geneo_dim, armed1.info.geneo_trigger_burn);
  CHECK(armed1.info.converged, "armed solve converges");
  CHECK(armed1.info.geneo_action == 3, "first stagnating solve BUILDS (action 3)");
  CHECK(armed1.info.geneo_trigger_burn == fea_geneo_trigger_iters(),
        "the build fires exactly at the named trigger budget");
  CHECK(armed1.info.geneo_dim > 0, "a nonempty coarse space was built");
  CHECK(fea_geneo_basis_builds() == 1, "exactly one eigensolve was paid");
  CHECK(armed1.info.iterations < plain.info.iterations,
        "the trigger build pays for itself within the same solve");
  CHECK(rel_max_diff(plain.u, armed1.u) <= 1e-6,
        "EXACTNESS: deflated and plain fields agree to 1e-6 (SPD additive)");

  // --- 4. THE ENGAGEMENT GATE, BOTH BRANCHES -------------------------------
  // Handoff 2026-08-02-geneo-disarm. A held basis no longer carries the arming
  // decision: every later solve starts plain and must burn past the MEASURED
  // all-in price of the armed alternative before deflating. Both branches are
  // pinned here — the decline (this fixture) and the engagement (the same basis
  // against a system that genuinely needs it, further down). The reuse and
  // refresh machinery is unchanged and is still asserted; what is asserted in
  // addition is that it is now paid for only when it is worth paying for.
  const int threshold_expected =
      static_cast<int>(std::ceil(fea_geneo_refresh_cost_per_column() *
                                     armed1.info.geneo_dim +
                                 armed1.info.geneo_trigger_burn +
                                 fea_geneo_deflated_iter_cost() *
                                     (armed1.info.iterations -
                                      armed1.info.geneo_trigger_burn)));
  const Solve armed2 = solve(f);
  std::printf("armed#2: %d iterations, action=%d, burn=%d, threshold=%d "
              "(expected %d)\n",
              armed2.info.iterations, armed2.info.geneo_action,
              armed2.info.geneo_trigger_burn, armed2.info.geneo_threshold,
              threshold_expected);
  CHECK(armed2.info.converged, "the declined solve still converges");
  CHECK(armed2.info.geneo_threshold == threshold_expected,
        "the gate's threshold IS the measured armed cost: 2*N_t + burn + 2*tail");
  CHECK(threshold_expected > plain.info.iterations,
        "on this fixture the armed alternative genuinely costs MORE than plain "
        "— so a correct gate must decline, and this test is testing that");
  CHECK(armed2.info.geneo_action == 5,
        "a held basis that cannot pay is DECLINED by the gate (action 5)");
  CHECK(armed2.info.geneo_trigger_burn == armed2.info.iterations,
        "a declined solve reports its whole burn — the number it was graded on");
  CHECK(armed2.info.iterations == plain.info.iterations,
        "a declined solve IS the plain solve: same iteration count");
  CHECK(rel_max_diff(plain.u, armed2.u) <= 1e-12,
        "EXACTNESS: a declined solve reproduces the plain field exactly");
  CHECK(fea_geneo_declined_solves() == 1, "the decline is counted");
  CHECK(fea_geneo_armed_solves() == 1, "and is NOT counted as an armed solve");
  CHECK(fea_geneo_basis_builds() == 1, "a decline pays no second eigensolve");
  CHECK(fea_geneo_coarse_refreshes() == 0,
        "and pays NO coarse refresh — the whole point of the gate");
  CHECK(fea_geneo_basis_dim() == armed1.info.geneo_dim,
        "the basis is KEPT, not dropped: a later hard solve re-engages it "
        "with a refresh, never a fresh eigensolve");

  // The gate DECIDES, it does not disarm: drop the threshold to zero through the
  // harness-only probe surface and the same held basis engages, refreshes
  // against the moved moduli, and deflates — the reuse policy intact underneath.
  const std::vector<double> youngs0 = f.youngs;
  for (double& v : f.youngs) v *= 1.01;
  // The plain reference for the PERTURBED system — the exactness bar below has
  // to compare like with like, not against the unperturbed field.
  fea_set_geneo_twolevel(false);
  const Solve plain_moved = solve(f);
  fea_set_geneo_twolevel(true);
  {
    fea_detail::GeneoProbeConfig cfg;
    cfg.engage_threshold = 0;  // harness-only: open the gate, keep everything else
    fea_detail::geneo_set_probe_config(cfg);
  }
  const Solve armed3 = solve(f);
  fea_detail::geneo_set_probe_config(fea_detail::GeneoProbeConfig{});
  std::printf("armed#3 (moduli moved, gate opened): %d iterations, action=%d\n",
              armed3.info.iterations, armed3.info.geneo_action);
  CHECK(armed3.info.converged, "refreshed solve converges");
  CHECK(armed3.info.geneo_action == 2,
        "a moduli move REFRESHES the coarse operator (action 2)");
  CHECK(armed3.info.iterations < plain_moved.info.iterations / 2,
        "an ENGAGED reused basis still deflates from iteration 0 (well under "
        "half of plain) — the gate changed WHEN, not WHETHER, it works");
  CHECK(fea_geneo_coarse_refreshes() == 1, "exactly one refresh was paid");
  CHECK(fea_geneo_basis_builds() == 1, "a refresh is not a rebuild");
  CHECK(rel_max_diff(plain_moved.u, armed3.u) <= 1e-6,
        "EXACTNESS: the re-engaged field still agrees with the plain solve of "
        "the SAME (perturbed) system to 1e-6");
  f.youngs = youngs0;
  fea_reset_geneo_basis();
  const Solve armed1b = solve(f);
  CHECK(armed1b.info.iterations == armed1.info.iterations &&
            armed1b.u == armed1.u,
        "the gate is stateless across a reset: rebuild reproduces armed#1");

  // --- 4b. BOTH ENTRY POINTS REPORT THE SAME DECISION ----------------------
  // Two matrix-free entry points fill CgInfo from the GenEO report: the direct
  // one used above, and the MULTIGRID route's Jacobi fallback — which is the one
  // production actually runs. They had already drifted: the multigrid site
  // reported `geneo_trigger_burn` and silently dropped `geneo_threshold`, so a
  // real ladder wrote `geneo_threshold = 0` on every row while this file, which
  // uses the OTHER entry point, read it correctly. Both now copy through the one
  // `geneo_fill_cg_info` mapping, and this is the check that keeps them honest.
  //
  // The fixture must have an ODD axis: pad mode 0 rejects a hierarchy only when
  // an axis cannot be coarsened, and a 32^3 grid coarsens fine — the first
  // version of this check silently measured a multigrid solve that never entered
  // GenEO at all (35 iterations, action 0).
  {
    Fixture fo = checkerboard_odd(32, 4);
    fea_reset_geneo_basis();
    fea_set_mg_parity_pad_mode(0);
    fea_matfree_reset_mg_stagnation_latch();
    CgInfo mg1, mg2;
    fea_solve_mgcg_matfree(fo.grid, fo.youngs, 0.33, fo.bcs, fo.loads, 1e-8,
                           60000, &mg1, nullptr);
    fea_solve_mgcg_matfree(fo.grid, fo.youngs, 0.33, fo.bcs, fo.loads, 1e-8,
                           60000, &mg2, nullptr);
    fea_set_mg_parity_pad_mode(1);
    std::printf("via multigrid entry: #1 %d iters action=%d dim=%d burn=%d "
                "thr=%d | #2 %d iters action=%d dim=%d burn=%d thr=%d\n",
                mg1.iterations, mg1.geneo_action, mg1.geneo_dim,
                mg1.geneo_trigger_burn, mg1.geneo_threshold, mg2.iterations,
                mg2.geneo_action, mg2.geneo_dim, mg2.geneo_trigger_burn,
                mg2.geneo_threshold);
    CHECK(!mg1.used_multigrid && !mg2.used_multigrid,
          "the odd-axis fixture really does land in the Jacobi fallback — "
          "without this the check measures a solve GenEO never sees");
    CHECK(mg1.geneo_action == 3 && mg1.geneo_trigger_burn == 500,
          "the multigrid route's fallback builds on the stagnation trigger, "
          "reported through the SAME mapping");
    CHECK(mg2.geneo_dim > 0,
          "the second solve is decided against a HELD basis");
    CHECK(mg2.geneo_threshold > 0,
          "and the multigrid route reports the gate's REAL threshold, not a "
          "zero — the exact field the drifted copy site used to drop");
    CHECK(mg2.geneo_threshold ==
              static_cast<int>(std::ceil(
                  fea_geneo_refresh_cost_per_column() * mg1.geneo_dim +
                  mg1.geneo_trigger_burn +
                  fea_geneo_deflated_iter_cost() *
                      (mg1.iterations - mg1.geneo_trigger_burn))),
          "and it is the cost model's own number, computed from THIS run's "
          "measured N_t and armed cost");
    fea_reset_geneo_basis();
  }

  // --- 5. DETERMINISM ------------------------------------------------------
  // The engagement gate is a comparison of COUNTS, never of wall time, so the
  // arming point — and with it the CG route and the field it lands on — is
  // reproducible run to run (handoff 2026-08-02-geneo-disarm, bar AA4).
  fea_reset_geneo_basis();
  const Solve armed4 = solve(f);
  CHECK(armed4.info.iterations == armed1.info.iterations,
        "reset + repeat: identical iteration count");
  CHECK(armed4.u == armed1.u, "reset + repeat: bit-identical field");
  const Solve armed5 = solve(f);
  CHECK(armed5.info.geneo_action == armed2.info.geneo_action &&
            armed5.info.geneo_threshold == armed2.info.geneo_threshold &&
            armed5.info.iterations == armed2.info.iterations,
        "reset + repeat: the gate takes the SAME decision on the same numbers");

  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  std::printf("test_geneo: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
