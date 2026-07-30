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
//   4. THE REUSE POLICY. A second solve of the same system REUSES the basis
//      (action 1, deflated from iteration 0, far fewer iterations); a solve of
//      a moduli-perturbed system REFRESHES the coarse operator (action 2) and
//      still converges deflated.
//
//   5. DETERMINISM. Reset + repeat produces bit-identical fields and identical
//      iteration counts (fixed LOBPCG seeds, fixed merge order, thread-count
//      independent).
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

  // --- 4. REUSE + REFRESH --------------------------------------------------
  const Solve armed2 = solve(f);
  std::printf("armed#2: %d iterations, action=%d\n", armed2.info.iterations,
              armed2.info.geneo_action);
  CHECK(armed2.info.geneo_action == 1, "same system REUSES the basis (action 1)");
  CHECK(armed2.info.iterations < plain.info.iterations / 2,
        "a reused basis deflates from iteration 0 (well under half of plain)");
  CHECK(fea_geneo_basis_builds() == 1, "reuse pays no second eigensolve");

  const std::vector<double> youngs0 = f.youngs;
  for (double& v : f.youngs) v *= 1.01;
  const Solve armed3 = solve(f);
  std::printf("armed#3 (moduli moved): %d iterations, action=%d\n",
              armed3.info.iterations, armed3.info.geneo_action);
  CHECK(armed3.info.converged, "refreshed solve converges");
  CHECK(armed3.info.geneo_action == 2,
        "a moduli move REFRESHES the coarse operator (action 2)");
  CHECK(fea_geneo_coarse_refreshes() == 1, "exactly one refresh was paid");
  CHECK(fea_geneo_basis_builds() == 1, "a refresh is not a rebuild");
  f.youngs = youngs0;

  // --- 5. DETERMINISM ------------------------------------------------------
  fea_reset_geneo_basis();
  const Solve armed4 = solve(f);
  CHECK(armed4.info.iterations == armed1.info.iterations,
        "reset + repeat: identical iteration count");
  CHECK(armed4.u == armed1.u, "reset + repeat: bit-identical field");

  fea_set_geneo_twolevel(false);
  fea_reset_geneo_basis();
  std::printf("test_geneo: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
