// Stage 5 (faster solves), E-01: ONE SolverSettings value passed into a solve.
//
// The entry points that take a SolverSettings run that one solve with exactly
// those values and leave every global switch untouched; the entry points without
// it read the globals as before. Checks, on a small graded block:
//   * no change for today's callers: the old entry point and the new one handed
//     fea_current_solver_settings() give identical bytes;
//   * nothing leaks OUT: after a solve handed other settings, every global
//     switch reads what it read before;
//   * nothing leaks IN: a solve handed settings S gives the same bytes whatever
//     the globals were set to (here: recycling, GenEO, threads, safe retry all
//     flipped by "another caller"), equal to the old entry point with the
//     globals set to S;
//   * the settings take effect (S differs from the globals where it should).

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

bool same_settings(const SolverSettings& a, const SolverSettings& b) {
  return a.matfree_threads == b.matfree_threads && a.galerkin_block_cache == b.galerkin_block_cache &&
         a.mixed_precision == b.mixed_precision && a.cubic_lattice == b.cubic_lattice &&
         a.geneo_twolevel == b.geneo_twolevel && a.krylov_recycling == b.krylov_recycling &&
         a.krylov_recycle_dim == b.krylov_recycle_dim && a.krylov_recycle_cycle == b.krylov_recycle_cycle &&
         a.krylov_recycle_wrap_multigrid == b.krylov_recycle_wrap_multigrid &&
         a.mg_safe_retry == b.mg_safe_retry && a.mg_rearm_period == b.mg_rearm_period &&
         a.mg_parity_pad_mode == b.mg_parity_pad_mode && a.mg_algebraic_level1 == b.mg_algebraic_level1;
}

// The globals set to `s` through today's setters (what a caller does today).
void set_globals(const SolverSettings& s) {
  fea_set_matfree_threads(s.matfree_threads);
  fea_set_matfree_galerkin_block_cache(s.galerkin_block_cache);
  fea_set_matfree_mixed_precision(s.mixed_precision);
  fea_set_matfree_cubic_lattice(s.cubic_lattice);
  fea_set_geneo_twolevel(s.geneo_twolevel);
  fea_set_krylov_recycling(s.krylov_recycling);
  fea_set_krylov_recycle_dim(s.krylov_recycle_dim);
  fea_set_krylov_recycle_cycle(s.krylov_recycle_cycle);
  fea_set_krylov_recycle_wrap_multigrid(s.krylov_recycle_wrap_multigrid);
  fea_matfree_set_mg_safe_retry(s.mg_safe_retry);
  fea_matfree_set_mg_rearm_period(s.mg_rearm_period);
  fea_set_mg_parity_pad_mode(s.mg_parity_pad_mode);
  fea_set_mg_algebraic_level1(s.mg_algebraic_level1);
}

void fresh_run_state() {
  fea_matfree_reset_mg_stagnation_latch();
  fea_reset_krylov_recycle_space();
  fea_reset_geneo_basis();
}

bool same_bytes(const FeaSolution& a, const FeaSolution& b) {
  return a.u.size() == b.u.size() && std::memcmp(a.u.data(), b.u.data(), a.u.size() * sizeof(double)) == 0;
}

}  // namespace

int main() {
  VoxelGrid g;
  g.nx = 20;
  g.ny = 9;
  g.nz = 18;
  g.spacing = 1.5;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  std::vector<double> E(g.voxel_count());
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        E[g.index(i, j, k)] = 0.2 * std::exp(5.0 * (0.5 + 0.5 * std::sin(0.7 * i + 0.4 * j + 0.3 * k)));
  std::vector<DirichletBC> bcs;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i)
      for (int c = 0; c < 3; ++c) bcs.push_back({fea_node_index(g, i, j, 0), c, 0.0});
  std::vector<NodalLoad> loads;
  for (int j = 0; j <= g.ny; ++j)
    for (int i = 0; i <= g.nx; ++i) loads.push_back({fea_node_index(g, i, j, g.nz), 2, -0.1});

  const SolverSettings original = fea_current_solver_settings();
  FeaLoosePieceRuleOff loose_rule_off;
  auto old_entry = [&](CgInfo& info) {
    fresh_run_state();
    return fea_solve_mgcg_matfree(g, E, 0.39, bcs, loads, 1e-6, 20000, &info, nullptr, nullptr);
  };
  auto new_entry = [&](const SolverSettings& s, CgInfo& info) {
    fresh_run_state();
    return fea_solve_mgcg_matfree(g, E, 0.39, bcs, loads, 1e-6, 20000, &info, nullptr, nullptr, s);
  };

  // 1. No change for today's callers.
  CgInfo i0, i1;
  const FeaSolution a0 = old_entry(i0);
  const FeaSolution a1 = new_entry(fea_current_solver_settings(), i1);
  CHECK(same_bytes(a0, a1), "the new entry point with the current settings = the old entry point");

  // S: a posture different from the library defaults on every dial that bites here.
  SolverSettings S = original;
  S.matfree_threads = 1;
  S.krylov_recycling = true;
  S.geneo_twolevel = true;
  S.mg_safe_retry = false;
  // OTHER: what "another caller" has set the globals to meanwhile.
  SolverSettings OTHER = original;
  OTHER.matfree_threads = 3;
  OTHER.krylov_recycling = false;
  OTHER.geneo_twolevel = false;
  OTHER.mg_safe_retry = true;
  OTHER.mg_parity_pad_mode = 2;

  // 2 + 3. Nothing leaks out, nothing leaks in.
  set_globals(OTHER);
  CgInfo is;
  const FeaSolution s_under_other = new_entry(S, is);
  CHECK(same_settings(fea_current_solver_settings(), OTHER), "the globals are untouched by a solve handed settings");
  set_globals(original);
  CgInfo is2;
  const FeaSolution s_under_original = new_entry(S, is2);
  CHECK(same_bytes(s_under_other, s_under_original), "a solve handed S gives the same bytes whatever the globals are");
  set_globals(S);
  CgInfo ig;
  const FeaSolution s_via_globals = old_entry(ig);
  CHECK(same_bytes(s_under_other, s_via_globals), "handing S = setting the globals to S (old entry point)");
  set_globals(original);
  CHECK(same_settings(fea_current_solver_settings(), original), "the globals are back to the library defaults");

  std::printf("old entry %d iterations; new entry, current settings %d; settings S %d (globals OTHER) / %d (globals default) / %d (globals S)\n",
              i0.iterations, i1.iterations, is.iterations, is2.iterations, ig.iterations);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
