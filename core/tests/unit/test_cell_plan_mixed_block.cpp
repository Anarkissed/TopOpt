// plan_cell_sizes (swept): a block the 2:1 balance splits must not be left MIXED.
//
// TO-core's finding (2026-11-04 20:37, credited; routed by the reviewer's ruling of 21:40):
// a swept graded lattice_part of a solid block threw "plan_cell_sizes: level assignment
// is not an aligned octree". The post-balance feasibility pass set level -1 per BASE cell
// where the split had made the strut unprintable, so a block split to L-1 ended up partly
// at L-1 and partly at -1, and the plan's own alignment check threw. Its repro: a
// 60 x 48 x 40 mm block with a 4 mm bore, res 40, octet, swept 1.6-12.8 mm, bead 0.3 mm
// (test_designbox_graded_lattice's fixture, which needs Manifold).
//
// Here the same mechanism on the planner alone, on a field built to trigger it:
//   base cells 1.6 mm, levels 1.6 / 3.2 / 6.4 (max 2), two aligned top blocks side by side.
//   Block A: every cell prints at level 0 except ONE corner cell, whose density only prints
//   at level 2, so the top-down pass gives A level 2. Block B: every cell level 0.
//   Balance splits A to 1 (it touches B's level 0), the corner cell is then unprintable,
//   and before the fix it alone dropped to -1 inside a level-1 block.
// §1 the mixed case plans, and the plan is an aligned octree: the corner cell solid (-1),
//    its seven siblings split to level 0, the rest of A at 1, B at 0.
// §2 control, the case that never threw: every cell of A needs level 2, so after the
//    balance split the WHOLE block drops. The plan is what it always was: A all -1.
#include "topopt/cell_plan.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using namespace topopt;

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

constexpr double kBead = 0.3, kS0 = 1.6;

// The lightest band density whose strut prints at cell `S` and not at `S / 2`: a cell of
// this density needs exactly the level of S. Found by search on the type's own law.
double rho_needing(double S) {
  const LatticeTopology t = LatticeTopology::Octet;
  for (double r = lattice_rho_min(t); r <= lattice_rho_max(t); r += 1e-4)
    if (lattice_strut_diameter_mm(t, r, S) >= kBead &&
        lattice_strut_diameter_mm(t, r, S / 2.0) < kBead)
      return r;
  return -1.0;
}

struct Case {
  VoxelGrid grid;
  std::vector<double> rho, width;
  std::vector<char> cand;
};

// 16 x 8 x 8 voxels of 0.8 mm: 8 x 4 x 4 base cells of 1.6 mm, two 4-cell top blocks.
Case make(double rho_a, double rho_corner, double rho_b) {
  Case c;
  c.grid.nx = 16;
  c.grid.ny = 8;
  c.grid.nz = 8;
  c.grid.spacing = 0.8;
  c.grid.origin = Vec3{0.0, 0.0, 0.0};
  c.grid.tags.assign(static_cast<std::size_t>(16 * 8 * 8), VoxelTag::Interior);
  c.rho.assign(c.grid.voxel_count(), 0.0);
  c.width.assign(c.grid.voxel_count(), 1000.0);   // thick members: the ceiling never binds
  c.cand.assign(c.grid.voxel_count(), 1);
  for (int k = 0; k < c.grid.nz; ++k)
    for (int j = 0; j < c.grid.ny; ++j)
      for (int i = 0; i < c.grid.nx; ++i) {
        const bool in_a = i < 8, corner = i < 2 && j < 2 && k < 2;
        c.rho[c.grid.index(i, j, k)] = !in_a ? rho_b : corner ? rho_corner : rho_a;
      }
  return c;
}

CellPlanParams params() {
  CellPlanParams p;
  p.topology = LatticeTopology::Octet;
  p.mode = CellSizeMode::Swept;
  p.min_cell_size_mm = kS0;
  p.max_cell_size_mm = 4.0 * kS0;
  p.min_extrudable_width_mm = kBead;
  return p;
}

int level(const CellSizePlan& P, int i, int j, int k) { return P.level[P.index(i, j, k)]; }

}  // namespace

int main() {
  const double r0 = rho_needing(kS0), r2 = rho_needing(4.0 * kS0);
  std::printf("[cell-plan] densities needing level 0: %.4f, level 2: %.4f\n", r0, r2);
  CHECK(r0 > 0.0 && r2 > 0.0 && r2 < r0, "precondition: both densities exist in the band");

  // ── §1 one corner cell needs level 2 ────────────────────────────────────────
  {
    const Case c = make(r0, r2, r0);
    CellSizePlan P;
    std::string threw;
    try {
      P = plan_cell_sizes(c.grid, c.rho, c.cand, c.width, params());
    } catch (const std::exception& e) {
      threw = e.what();
      std::printf("  (threw: %s)\n", e.what());
    }
    CHECK(threw.empty(), "§1 the mixed case plans (it threw \"not an aligned octree\")");
    if (threw.empty()) {
      CHECK(level(P, 0, 0, 0) == -1, "§1 the corner cell is left solid");
      bool siblings = true;
      for (int k = 0; k < 2; ++k)
        for (int j = 0; j < 2; ++j)
          for (int i = 0; i < 2; ++i)
            if ((i || j || k) && level(P, i, j, k) != 0) siblings = false;
      CHECK(siblings, "§1 its seven siblings are split to level 0");
      CHECK(level(P, 2, 0, 0) == 1 && level(P, 3, 3, 3) == 1 && level(P, 0, 2, 2) == 1,
            "§1 the rest of block A stays at level 1");
      CHECK(level(P, 4, 0, 0) == 0 && level(P, 7, 3, 3) == 0, "§1 block B is level 0");
    }
  }

  // ── §2 control: every cell of A needs level 2 ───────────────────────────────
  {
    const Case c = make(r2, r2, r0);
    std::string threw;
    CellSizePlan P;
    try {
      P = plan_cell_sizes(c.grid, c.rho, c.cand, c.width, params());
    } catch (const std::exception& e) {
      threw = e.what();
    }
    CHECK(threw.empty(), "§2 control: the uniform block plans, as it always did");
    if (threw.empty()) {
      bool all_solid = true;
      for (int k = 0; k < 4; ++k)
        for (int j = 0; j < 4; ++j)
          for (int i = 0; i < 4; ++i)
            if (level(P, i, j, k) != -1) all_solid = false;
      CHECK(all_solid, "§2 control: the whole of A drops after the balance split, as before");
      CHECK(level(P, 4, 0, 0) == 0, "§2 control: block B is level 0");
    }
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
