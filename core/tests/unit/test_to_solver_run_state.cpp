// Stage 5 (faster solves), E-01: the RUN STATE passed into a solve
// (SolverRunState: stagnation and safe-retry latches, Krylov recycle basis,
// GenEO basis). Test K's rule: a result must not depend on which solves ran
// before it, except the solves of its OWN run.
//
// Jacobi-CG with Krylov recycling on (the recycle basis is carried from solve to
// solve, so the state matters), on a small graded block. Checks:
//   * the state matters: a run's third solve takes fewer iterations than the
//     same solve with a fresh state (the basis carried);
//   * two runs interleaved (A1 B1 A2 B2 A3), each with its own SolverRunState,
//     give run A the identical bytes it gets alone;
//   * a solve handed a FRESH state gives the same bytes whatever ran before it;
//   * the thread's default state (the old entry points) is untouched by solves
//     handed a state: an old-entry sequence gives the same bytes before and after.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace topopt;

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
bool same_bytes(const FeaSolution& a, const FeaSolution& b) {
  return a.u.size() == b.u.size() && std::memcmp(a.u.data(), b.u.data(), a.u.size() * sizeof(double)) == 0;
}
}  // namespace

int main() {
  VoxelGrid g;
  g.nx = 16;
  g.ny = 8;
  g.nz = 14;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  std::vector<double> E(g.tags.size());
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        E[g.index(i, j, k)] = 0.5 * std::exp(4.0 * (0.5 + 0.5 * std::sin(0.6 * i + 0.5 * j + 0.4 * k)));
  std::vector<DirichletBC> bcs;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i)
      for (int c = 0; c < 3; ++c) bcs.push_back({fea_node_index(g, i, j, 0), c, 0.0});
  auto loads_for = [&](double scale, int comp) {
    std::vector<NodalLoad> l;
    for (int j = 0; j <= g.ny; ++j)
      for (int i = 0; i <= g.nx; ++i) l.push_back({fea_node_index(g, i, j, g.nz), comp, scale * 0.1});
    return l;
  };
  SolverSettings S = fea_current_solver_settings();
  S.krylov_recycling = true;
  S.krylov_recycle_dim = 8;
  S.geneo_twolevel = false;
  FeaLoosePieceRuleOff loose_rule_off;
  auto solve = [&](double scale, int comp, SolverRunState* run, CgInfo& info) {
    return fea_solve_cg_matfree(g, E, 0.39, bcs, loads_for(scale, comp), 1e-8, 20000, &info, nullptr,
                                nullptr, S, run);
  };

  // Run A alone.
  std::vector<FeaSolution> alone;
  std::vector<int> alone_it;
  {
    SolverRunState A;
    for (double sc : {1.0, 1.1, 1.2}) {
      CgInfo info;
      alone.push_back(solve(sc, 2, &A, info));
      alone_it.push_back(info.iterations);
    }
  }
  // The state matters: A3 with a fresh state.
  CgInfo cold_info;
  SolverRunState fresh1;
  const FeaSolution a3_cold = solve(1.2, 2, &fresh1, cold_info);
  CHECK(alone_it[2] < cold_info.iterations, "the carried recycle basis cuts the third solve's iterations");

  // An old-entry sequence on the thread's default state, before.
  fea_reset_krylov_recycle_space();
  const bool prev_rc = fea_set_krylov_recycling(true);
  std::vector<FeaSolution> old_before;
  for (double sc : {0.8, 0.9}) {
    CgInfo info;
    old_before.push_back(fea_solve_cg_matfree(g, E, 0.39, bcs, loads_for(sc, 0), 1e-8, 20000, &info));
  }

  // A and B interleaved, each with its own state.
  {
    SolverRunState A, B;
    std::vector<FeaSolution> a;
    CgInfo i;
    a.push_back(solve(1.0, 2, &A, i));
    solve(0.5, 0, &B, i);
    a.push_back(solve(1.1, 2, &A, i));
    solve(0.7, 1, &B, i);
    a.push_back(solve(1.2, 2, &A, i));
    CHECK(same_bytes(a[0], alone[0]) && same_bytes(a[1], alone[1]) && same_bytes(a[2], alone[2]),
          "run A interleaved with run B = run A alone, byte for byte");
  }
  // A fresh state after all that = a fresh state at the start.
  CgInfo i2;
  SolverRunState fresh2;
  const FeaSolution a3_cold2 = solve(1.2, 2, &fresh2, i2);
  CHECK(same_bytes(a3_cold, a3_cold2), "a solve handed a fresh state does not depend on what ran before it");

  // The old-entry sequence again: the default state was untouched by all of the above.
  fea_reset_krylov_recycle_space();
  std::vector<FeaSolution> old_after;
  for (double sc : {0.8, 0.9}) {
    CgInfo info;
    old_after.push_back(fea_solve_cg_matfree(g, E, 0.39, bcs, loads_for(sc, 0), 1e-8, 20000, &info));
  }
  CHECK(same_bytes(old_before[0], old_after[0]) && same_bytes(old_before[1], old_after[1]),
        "the thread's default state is untouched by solves handed their own state");
  fea_set_krylov_recycling(prev_rc);
  fea_reset_krylov_recycle_space();

  std::printf("run A alone: %d / %d / %d iterations; A3 with a fresh state: %d\n", alone_it[0], alone_it[1],
              alone_it[2], cold_info.iterations);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
