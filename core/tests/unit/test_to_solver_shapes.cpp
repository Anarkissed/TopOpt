// Stage 5: the stage-5 smoother on shapes BEYOND his parts (users import any
// model). Five made-up shapes, no maintainer data:
//   block   a plain, firmly held block, pressed on top;
//   hole    the block with a hole through it, pushed sideways;
//   bracket a thin-walled bracket: a plate with a hole and a 2-voxel upright wall,
//           graded modulus, the wall's top pushed sideways;
//   dilute  an optimiser's mid-run density field: the whole box at the 1e-9
//           void floor, about a tenth solid (four columns, braces, a top plate),
//           held only at the four feet;
//   loose   the dilute design plus a loaded cube cut off from every support.
// Checks, with TOPOPT_SOLVER=cheb:2 (the ruled default, 11-26) and jacobi:1.6
// (measured beside it):
//   * block, hole, bracket and dilute converge on multigrid with no l1 safe
//     retry and no fallback, within a cycle budget (about twice the measured);
//   * the loose design under the connection rule (FeaAnchorBySupportOnly) is
//     refused at once (FeaLoadUnheld), never solved on void.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
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

constexpr double kSolid = 1000.0;
constexpr double kVoid = 1e-9 * kSolid;

struct Case {
  std::string name;
  VoxelGrid g;
  std::vector<double> E;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

void box(Case& c, int nx, int ny, int nz, VoxelTag fill, double e) {
  c.g.nx = nx; c.g.ny = ny; c.g.nz = nz;
  c.g.spacing = 1.0;
  c.g.origin = Vec3{0.0, 0.0, 0.0};
  c.g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, fill);
  c.E.assign(c.g.tags.size(), e);
}

void hold_floor(Case& c) {
  for (int j = 0; j <= c.g.ny; ++j)
    for (int i = 0; i <= c.g.nx; ++i)
      for (int d = 0; d < 3; ++d) c.bcs.push_back({fea_node_index(c.g, i, j, 0), d, 0.0});
}

void press_top(Case& c, int comp, double total) {
  const double per = total / ((c.g.nx + 1.0) * (c.g.ny + 1.0));
  for (int j = 0; j <= c.g.ny; ++j)
    for (int i = 0; i <= c.g.nx; ++i) c.loads.push_back({fea_node_index(c.g, i, j, c.g.nz), comp, per});
}

Case block() {
  Case c; c.name = "block";
  box(c, 24, 16, 24, VoxelTag::Interior, kSolid);
  hold_floor(c); press_top(c, 2, -10.0);
  return c;
}

Case hole() {
  Case c; c.name = "hole";
  box(c, 24, 16, 24, VoxelTag::Interior, kSolid);
  for (int k = 0; k < c.g.nz; ++k)
    for (int j = 0; j < c.g.ny; ++j)
      for (int i = 0; i < c.g.nx; ++i)
        if ((i - 12) * (i - 12) + (k - 13) * (k - 13) < 25) {
          c.g.tags[c.g.index(i, j, k)] = VoxelTag::Empty;
          c.E[c.g.index(i, j, k)] = 0.0;
        }
  hold_floor(c); press_top(c, 0, 10.0);
  return c;
}

Case bracket() {
  Case c; c.name = "bracket";
  box(c, 40, 16, 28, VoxelTag::Empty, 0.0);
  for (int k = 0; k < c.g.nz; ++k)
    for (int j = 0; j < c.g.ny; ++j)
      for (int i = 0; i < c.g.nx; ++i) {
        const bool plate = k < 3 && ((i - 28) * (i - 28) + (j - 8) * (j - 8) >= 16);
        const bool wall = i >= 10 && i < 12;
        if (plate || wall) {
          c.g.tags[c.g.index(i, j, k)] = VoxelTag::Interior;
          c.E[c.g.index(i, j, k)] = kSolid * (1.0 + 0.5 * std::sin(0.3 * i + 0.2 * j + 0.1 * k));
        }
      }
  hold_floor(c);
  for (int j = 0; j <= c.g.ny; ++j) c.loads.push_back({fea_node_index(c.g, 11, j, c.g.nz), 0, 0.05});
  return c;
}

Case dilute() {
  Case c; c.name = "dilute";
  box(c, 32, 16, 32, VoxelTag::Interior, kVoid);
  const int cx[2] = {3, 27}, cy[2] = {2, 12};
  for (int k = 0; k < c.g.nz; ++k)
    for (int j = 0; j < c.g.ny; ++j)
      for (int i = 0; i < c.g.nx; ++i) {
        bool s = k >= c.g.nz - 2;
        for (int a = 0; a < 2; ++a)
          for (int b = 0; b < 2; ++b)
            if (i >= cx[a] && i < cx[a] + 2 && j >= cy[b] && j < cy[b] + 2) s = true;
        for (int b = 0; b < 2; ++b)
          if (j >= cy[b] && j < cy[b] + 2) {
            const int up = 3 + (24 * k) / c.g.nz, down = 28 - (24 * k) / c.g.nz;
            if (std::abs(i - up) <= 1 || std::abs(i - down) <= 1) s = true;
          }
        if (s) c.E[c.g.index(i, j, k)] = kSolid;
      }
  for (int a = 0; a < 2; ++a)
    for (int b = 0; b < 2; ++b)
      for (int j = cy[b]; j <= cy[b] + 2; ++j)
        for (int i = cx[a]; i <= cx[a] + 2; ++i)
          for (int d = 0; d < 3; ++d) c.bcs.push_back({fea_node_index(c.g, i, j, 0), d, 0.0});
  press_top(c, 2, -10.0);
  return c;
}

Case loose() {
  Case c = dilute(); c.name = "loose";
  for (int k = 14; k < 19; ++k)
    for (int j = 6; j < 10; ++j)
      for (int i = 14; i < 18; ++i) c.E[c.g.index(i, j, k)] = kSolid;
  for (int j = 6; j <= 10; ++j)
    for (int i = 14; i <= 18; ++i) c.loads.push_back({fea_node_index(c.g, i, j, 19), 2, -0.01});
  return c;
}

struct Run {
  bool ok = false, unheld = false;
  CgInfo info;
  long long l1 = 0;
};

Run solve(const Case& c, const char* setting) {
  Run r;
  setenv("TOPOPT_SOLVER", setting, 1);
  fea_matfree_reset_mg_stagnation_latch();
  const long long l1_before = fea_matfree_mg_safe_engagements();
  try {
    (void)fea_solve_mgcg_matfree(c.g, c.E, 0.39, c.bcs, c.loads, 1e-6, 20000, &r.info, nullptr, nullptr);
    r.ok = true;
  } catch (const FeaLoadUnheld&) {
    r.unheld = true;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  %s %s threw: %s\n", c.name.c_str(), setting, e.what());
  }
  r.l1 = fea_matfree_mg_safe_engagements() - l1_before;
  unsetenv("TOPOPT_SOLVER");
  return r;
}

}  // namespace

int main() {
  const int prev_threads = fea_set_matfree_threads(1);
  struct Budget { const char* name; int cheb2; int jac16; };
  // About twice the cycles measured when this test was written (11-26, 1 thread,
  // tol 1e-6): cheb:2 9 / 20 / 89 / 44, jacobi:1.6 15 / 29 / 119 / 62.
  const Budget budgets[] = {{"block", 18, 30}, {"hole", 40, 58}, {"bracket", 178, 238}, {"dilute", 88, 124}};
  const Case cases[] = {block(), hole(), bracket(), dilute()};
  for (int s = 0; s < 4; ++s) {
    const Case& c = cases[s];
    for (const char* setting : {"cheb:2", "jacobi:1.6"}) {
      const Run r = solve(c, setting);
      const int budget = std::string(setting) == "cheb:2" ? budgets[s].cheb2 : budgets[s].jac16;
      const std::string what = c.name + " / " + setting;
      CHECK(r.ok && r.info.converged && r.info.used_multigrid, (what + ": converges on multigrid").c_str());
      CHECK(r.l1 == 0, (what + ": no l1 safe retry").c_str());
      CHECK(budget == 0 || r.info.iterations <= budget, (what + ": within its cycle budget").c_str());
      std::printf("%-8s %-11s %s cycles %d, l1 retries %lld\n", c.name.c_str(), setting,
                  r.ok ? "converged" : "FAILED", r.info.iterations, r.l1);
    }
  }
  {
    const Case c = loose();
    Run r;
    {
      FeaAnchorBySupportOnly rule;
      r = solve(c, "cheb:2");
    }
    CHECK(r.unheld && !r.ok, "loose: a loaded piece cut off from every support is refused at once");
    std::printf("loose    cheb:2 under the connection rule: %s\n", r.unheld ? "refused (FeaLoadUnheld)" : "NOT refused");
  }
  fea_set_matfree_threads(prev_threads);
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
