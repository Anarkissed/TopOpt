// Stage 5, THE CONNECTION RULE in its support-only form (the reviewer's ruling
// 2026-11-26, maintainer-approved): inside FeaAnchorBySupportOnly a piece is held
// only when it reaches a support. A loose piece with only its registered body
// load (FeaBodyLoadScope) leaves the solve with that load; a loose piece with
// ANY applied load makes the solve refuse at once (FeaLoadUnheld).
//
// The case: a block held on the floor and a cube floating in the void above it,
// at the optimiser's 1e-9 void floor, both carrying their own weight (a load on
// every solid node), the block also pressed on top. Checks:
//   * today's rule (no scope): the weighted cube counts as held, 0 loose;
//   * support-only with the weight registered: the cube is loose (1 piece), not
//     "loaded" (weight only); the solve converges on multigrid and its answer
//     equals the system with the cube's weight taken out (energy norm), and the
//     weight taken out is reported;
//   * support-only WITHOUT a registration: the cube's weight counts as applied,
//     the solve refuses at once (FeaLoadUnheld, 1 piece) without iterating;
//   * support-only with an APPLIED load on the cube: refused, whatever is
//     registered;
//   * an unloaded floating cube: the same loose set and identical bytes under
//     both rules;
//   * outside the scopes every byte is today's.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

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

constexpr double kWeight = 0.001;  // N per solid voxel, straight down

struct Case {
  VoxelGrid g;
  std::vector<double> E;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<double> body;  // per voxel, what `loads` carries as weight
  int cube_voxels = 0;
};

bool in_block(int, int, int k) { return k < 4; }
bool in_cube(int i, int j, int k) { return i >= 8 && i < 14 && j >= 3 && j < 9 && k >= 9 && k < 14; }

// weigh_cube: the cube carries its weight; cube_weight_in_solve false builds the
// reference system the rule must equal (the cube's weight simply not there).
Case make(bool weigh_cube, bool cube_weight_in_solve = true) {
  Case c;
  c.g.nx = 24; c.g.ny = 12; c.g.nz = 16;
  c.g.spacing = 1.0;
  c.g.origin = Vec3{0.0, 0.0, 0.0};
  c.g.tags.assign(static_cast<std::size_t>(c.g.nx) * c.g.ny * c.g.nz, VoxelTag::Interior);
  c.E.assign(c.g.tags.size(), 1e-9 * 1000.0);
  c.body.assign(c.g.tags.size(), 0.0);
  for (int k = 0; k < c.g.nz; ++k)
    for (int j = 0; j < c.g.ny; ++j)
      for (int i = 0; i < c.g.nx; ++i) {
        const bool b = in_block(i, j, k), q = in_cube(i, j, k);
        if (!b && !q) continue;
        c.E[c.g.index(i, j, k)] = 1000.0;
        if (q) ++c.cube_voxels;
        if (q && !weigh_cube) continue;
        c.body[c.g.index(i, j, k)] = kWeight;
        if (q && !cube_weight_in_solve) continue;
        for (int nd : fea_element_nodes(c.g, i, j, k)) c.loads.push_back({nd, 2, -kWeight / 8.0});
      }
  for (int j = 0; j <= c.g.ny; ++j)
    for (int i = 0; i <= c.g.nx; ++i)
      for (int d = 0; d < 3; ++d) c.bcs.push_back({fea_node_index(c.g, i, j, 0), d, 0.0});
  for (int j = 0; j <= c.g.ny; ++j)
    for (int i = 0; i <= c.g.nx; ++i) c.loads.push_back({fea_node_index(c.g, i, j, 4), 2, -0.01});
  return c;
}

struct Run {
  bool ok = false, unheld = false;
  int unheld_pieces = 0;
  FeaSolution sol;
  CgInfo info;
  fea_detail::MgLooseStats st;
};

Run solve(const Case& c) {
  Run r;
  fea_matfree_reset_mg_stagnation_latch();
  try {
    r.sol = fea_solve_mgcg_matfree(c.g, c.E, 0.39, c.bcs, c.loads, 1e-8, 20000, &r.info, nullptr, nullptr);
    r.ok = true;
  } catch (const FeaLoadUnheld& e) {
    r.unheld = true;
    r.unheld_pieces = e.pieces;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  solve threw: %s\n", e.what());
  }
  r.st = fea_detail::mg_loose_stats();
  return r;
}

bool same_bytes(const FeaSolution& a, const FeaSolution& b) {
  return a.u.size() == b.u.size() && std::memcmp(a.u.data(), b.u.data(), a.u.size() * sizeof(double)) == 0;
}

double energy_diff(const Case& c, const FeaSolution& a, const FeaSolution& ref, const std::vector<double>& Esys) {
  std::vector<double> d(ref.u.size());
  for (std::size_t i = 0; i < d.size(); ++i) d[i] = a.u[i] - ref.u[i];
  const std::vector<double> Kd = fea_matfree_apply(c.g, Esys, 0.39, d);
  const std::vector<double> Kr = fea_matfree_apply(c.g, Esys, 0.39, ref.u);
  double dd = 0.0, rr = 0.0;
  for (std::size_t i = 0; i < d.size(); ++i) { dd += d[i] * Kd[i]; rr += ref.u[i] * Kr[i]; }
  return std::sqrt(std::max(0.0, dd) / std::max(1e-300, rr));
}

}  // namespace

int main() {
  const int prev_threads = fea_set_matfree_threads(1);
  const Vec3 down{0.0, 0.0, -1.0};
  {
    const Case c = make(/*weigh_cube=*/true);
    const fea_detail::MgIslandCensus today = fea_detail::mg_island_census(c.g, c.E, c.bcs, c.loads);
    CHECK(today.pieces == 2 && today.unanchored == 0, "today's rule: the weighted cube counts as held");
    const Run before = solve(c);

    // Support-only, the weight registered: the cube leaves with its weight.
    fea_detail::MgIslandCensus prop;
    Run with;
    {
      FeaAnchorBySupportOnly rule;
      FeaBodyLoadScope body(c.body, down);
      prop = fea_detail::mg_island_census(c.g, c.E, c.bcs, c.loads);
      with = solve(c);
    }
    CHECK(prop.unanchored == 1 && prop.unanchored_voxels == c.cube_voxels && prop.loaded_loose == 0,
          "support-only + weight: the cube is loose and carries no applied load");
    CHECK(with.ok && with.info.converged && with.info.used_multigrid, "support-only + weight: converges on multigrid");
    CHECK(std::fabs(with.st.last_body_removed - kWeight * c.cube_voxels) < 1e-12,
          "the cube's weight taken out is reported");
    // The reference: the cube at the floor modulus and its weight simply absent.
    Case ref = make(/*weigh_cube=*/true, /*cube_weight_in_solve=*/false);
    std::vector<double> Efloor = ref.E;
    for (std::size_t e = 0; e < Efloor.size(); ++e)
      if (in_cube(static_cast<int>(e % ref.g.nx), static_cast<int>((e / ref.g.nx) % ref.g.ny),
                  static_cast<int>(e / (ref.g.nx * ref.g.ny))))
        Efloor[e] = 1e-9 * 1000.0;
    ref.E = Efloor;
    Run rref;
    {
      FeaLoosePieceRuleOff off;  // the reference is solved exactly as built
      rref = solve(ref);
    }
    const double en = rref.ok && with.ok ? energy_diff(ref, with.sol, rref.sol, Efloor) : 1.0;
    CHECK(en < 1e-5, "support-only + weight: the answer equals the system without the cube's weight");

    // Support-only, nothing registered: the weight counts as applied -> refused at once.
    Run noreg;
    {
      FeaAnchorBySupportOnly rule;
      noreg = solve(c);
    }
    CHECK(noreg.unheld && noreg.unheld_pieces == 1, "support-only, no registration: refused (FeaLoadUnheld, 1 piece)");

    // The refusal reaches every optimiser's existing catch: it IS a
    // SolverNonConvergence (iterations 0), and the counter grows by one per refusal.
    const long long count0 = fea_matfree_load_unheld_count();
    bool caught_as_nonconv = false;
    int it_reported = -1;
    {
      FeaAnchorBySupportOnly rule;
      try {
        CgInfo info;
        fea_matfree_reset_mg_stagnation_latch();
        (void)fea_solve_mgcg_matfree(c.g, c.E, 0.39, c.bcs, c.loads, 1e-8, 20000, &info, nullptr, nullptr);
      } catch (const SolverNonConvergence& e) {
        caught_as_nonconv = dynamic_cast<const FeaLoadUnheld*>(&e) != nullptr;
        it_reported = e.iterations;
      }
    }
    int last_pieces = 0;
    long long last_voxels = 0;
    fea_matfree_last_load_unheld(&last_pieces, &last_voxels);
    CHECK(caught_as_nonconv && it_reported == 0, "the refusal is caught as a SolverNonConvergence (iterations 0)");
    CHECK(fea_matfree_load_unheld_count() == count0 + 1, "the refusal counter grows by one");
    CHECK(last_pieces == 1 && last_voxels == c.cube_voxels, "the last refusal reports its pieces and voxels");

    const Run after = solve(c);
    CHECK(after.ok && same_bytes(before.sol, after.sol), "outside the scopes: today's bytes");
    std::printf("weighted cube: today %d loose, %d cycles; support-only + weight: %d loose, %d cycles, weight out %.4f N, energy diff %.1e; no registration: %s\n",
                today.unanchored, before.info.iterations, prop.unanchored, with.info.iterations,
                with.st.last_body_removed, en, noreg.unheld ? "refused" : "NOT refused");
  }
  {
    // An APPLIED load on the floating cube: refused whatever is registered.
    Case c = make(/*weigh_cube=*/true);
    for (int j = 3; j <= 9; ++j)
      for (int i = 8; i <= 14; ++i) c.loads.push_back({fea_node_index(c.g, i, j, 14), 0, 0.002});
    Run r;
    {
      FeaAnchorBySupportOnly rule;
      FeaBodyLoadScope body(c.body, Vec3{0.0, 0.0, -1.0});
      r = solve(c);
    }
    CHECK(r.unheld && r.unheld_pieces == 1, "an applied load on a piece that reaches no support: refused at once");
  }
  {
    const Case c = make(/*weigh_cube=*/false);
    const fea_detail::MgIslandCensus today = fea_detail::mg_island_census(c.g, c.E, c.bcs, c.loads);
    const Run base = solve(c);
    fea_detail::MgIslandCensus prop;
    Run with;
    {
      FeaAnchorBySupportOnly rule;
      FeaBodyLoadScope body(c.body, Vec3{0.0, 0.0, -1.0});
      prop = fea_detail::mg_island_census(c.g, c.E, c.bcs, c.loads);
      with = solve(c);
    }
    CHECK(today.unanchored == 1 && prop.unanchored == 1 && today.drop == prop.drop && prop.loaded_loose == 0,
          "an unloaded floating cube: the same loose set under both rules");
    CHECK(base.ok && with.ok && same_bytes(base.sol, with.sol), "an unloaded floating cube: identical bytes under both rules");
  }
  fea_set_matfree_threads(prev_threads);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
