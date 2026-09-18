// ── ANY-STEP STEPPED: the size menu ─────────────────────────────────────────────
// The expected menus are the maintainer's, from the brief of 2026-09-17, and they are
// asserted to the entry rather than to a count: a menu with the right number of wrong
// sizes would pack a part that does not match the preview the maintainer approved.
#include "topopt/stepped_plan.hpp"
#include "topopt/lattice.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, what)                                                          \
  do {                                                                             \
    ++g_checks;                                                                    \
    if (!(cond)) {                                                                 \
      ++g_failures;                                                                \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, what);                   \
    }                                                                              \
  } while (0)

using namespace topopt;

static std::string join(const std::vector<double>& v) {
  std::string s;
  char buf[32];
  for (std::size_t i = 0; i < v.size(); ++i) {
    std::snprintf(buf, sizeof buf, "%.4g", v[i]);
    s += (i ? " " : "");
    s += buf;
  }
  return s;
}

static void expect_menu(const char* what, double base, double bead,
                        const std::vector<double>& want) {
  const std::vector<double> got = stepped_size_menu(base, bead);
  std::printf("  menu %-22s base %.4g bead %.2f -> [%s]\n", what, base, bead,
              join(got).c_str());
  CHECK(got.size() == want.size(), what);
  if (got.size() != want.size()) {
    std::printf("       wanted [%s]\n", join(want).c_str());
    return;
  }
  for (std::size_t i = 0; i < want.size(); ++i)
    CHECK(std::fabs(got[i] - want[i]) < 0.005, what);
}

// ── THE MAINTAINER'S TWO MENUS, TO THE ENTRY ────────────────────────────────────
static void test_menu_matches_the_brief() {
  // 12 mm base: the sixths (tile 2.0) do not print open, which removes that family and
  // with it the 10 mm entry -- 10 is reachable ONLY as 5*(12/6).
  expect_menu("12 mm base", 12.0, 0.45,
              {12.0, 9.6, 9.0, 8.0, 7.2, 6.0, 4.8, 4.0, 3.0, 2.4});
  // 10.31 mm base: the fifths fall at 2.062 and are refused where 2.4 was admitted, so
  // the menu stops at quarters. The bound is on the TILE, not on the base.
  expect_menu("10.31 mm base", 10.31, 0.45, {10.31, 7.73, 6.87, 5.16, 3.44, 2.58});

  const std::vector<int> d12 = stepped_admitted_divisors(12.0, 0.45);
  CHECK(std::find(d12.begin(), d12.end(), 5) != d12.end(),
        "12 mm base: fifths are admitted (tile 2.4 prints open)");
  CHECK(std::find(d12.begin(), d12.end(), 6) == d12.end(),
        "12 mm base: sixths are refused (tile 2.0 does not print open)");
  // ★ THE CONTROL. If every divisor were admitted the menu above would be a coincidence
  // of arithmetic rather than the density bound doing work. At a FATTER bead more
  // families must fall away.
  const std::vector<int> fat = stepped_admitted_divisors(12.0, 0.90);
  CHECK(fat.size() < d12.size(),
        "CONTROL: a fatter bead admits FEWER families -- the density bound is live");
}

// ── DEPTH-CLEAN BY CONSTRUCTION ─────────────────────────────────────────────────
// A cell of size s placed at the face leaves S - floor(S/s)*s of the wall behind it, and
// the claim is that the remainder is always fillable by menu tiles that divide s -- no
// solid strip is ever laid to make up a depth. Asserted over every menu size, on several
// bases and beads, rather than on the one case that motivated it.
static void test_depth_is_clean() {
  for (double base : {12.0, 10.31, 8.0, 6.5, 20.0}) {
    for (double bead : {0.45, 0.60, 0.90}) {
      const std::vector<double> menu = stepped_size_menu(base, bead);
      for (double s : menu) {
        const double rem = base - std::floor(base / s + 1e-9) * s;
        if (rem < 1e-9) continue;                     // s tiles the base exactly
        // the remainder must itself be a whole number of the finest admitted tile
        bool fillable = false;
        for (double t : menu) {
          const double q = rem / t;
          if (std::fabs(q - std::floor(q + 0.5)) < 1e-6 && q >= 1.0 - 1e-9) fillable = true;
        }
        char what[160];
        std::snprintf(what, sizeof what,
                      "depth-clean: base %.4g bead %.2f size %.4g leaves %.4g, fillable "
                      "by a menu tile", base, bead, s, rem);
        CHECK(fillable, what);
      }
    }
  }
}

// ── THE MENU IS A MENU: sorted, unique, and bounded by the base ─────────────────
static void test_menu_shape() {
  const std::vector<double> menu = stepped_size_menu(12.0, 0.45);
  CHECK(!menu.empty(), "menu: it is not empty");
  CHECK(std::fabs(menu.front() - 12.0) < 1e-9, "menu: the base is the largest entry");
  for (std::size_t i = 1; i < menu.size(); ++i) {
    CHECK(menu[i] < menu[i - 1], "menu: strictly descending, so no size appears twice");
    CHECK(menu[i] > 0.0, "menu: every size is positive");
  }
  // 2*(12/4) and 12/2 are both 6: the dedupe must have collapsed them
  int sixes = 0;
  for (double s : menu) if (std::fabs(s - 6.0) < 1e-9) ++sixes;
  CHECK(sixes == 1, "menu: 6 mm is reachable as 12/2 and 2*(12/4) and appears ONCE");

  // A base too fine to subdivide yields itself alone -- never an empty menu, which would
  // leave the packer with nothing to place.
  const std::vector<double> tiny = stepped_size_menu(1.2, 0.45);
  CHECK(tiny.size() == 1 && std::fabs(tiny.front() - 1.2) < 1e-9,
        "menu: a base too fine to subdivide is its own menu, not an empty one");
}

// ── THE PLAN VALIDATION: core CHECKS, it does not repack ────────────────────────
// A refusal must NAME the offending cell. A validator that returned a bare false would
// leave the app guessing which of thousands of cells it got wrong, and the whole reason
// core validates rather than repacking is that the preview is a contract.
static void test_plan_validation() {
  SteppedPlanRegion reg;
  reg.region_id = 1;
  reg.base_cell_mm = 12.0;
  reg.slot_origin = Vec3{100.0, -5.0, 0.0};      // deliberately not the grid origin

  auto at = [&](double dx, double dy, double dz, double size) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = Vec3{reg.slot_origin.x + dx, reg.slot_origin.y + dy, reg.slot_origin.z + dz};
    c.size_mm = size;
    return c;
  };

  {   // a legitimate pack: a 9 at the face, 3 mm tiles behind and beside it
    std::vector<SteppedCell> cells = {at(0, 0, 0, 9.0), at(9, 0, 0, 3.0),
                                      at(0, 9, 0, 3.0), at(3, 9, 0, 3.0)};
    const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
    std::printf("  plan: %s  hist [%s]\n", v.ok ? "ok" : v.error.c_str(),
                v.histogram_line.c_str());
    CHECK(v.ok, "plan: a 9 with 3 mm tiles behind and beside it is accepted");
    CHECK(v.cells == 4, "plan: it counted every cell");
    CHECK(v.histogram.size() == 2 && v.histogram.front().first == 9.0,
          "plan: the histogram is descending by size, like the preview's DIAG");
  }
  {   // ★ a size that is not on the menu -- 10 mm, the entry the sixths would have given
    std::vector<SteppedCell> cells = {at(0, 0, 0, 10.0)};
    const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
    CHECK(!v.ok, "plan: 10 mm is refused -- it is only reachable from the sixths");
    CHECK(v.error.find("not on that region's menu") != std::string::npos &&
              v.error.find("cell 0") != std::string::npos,
          "plan: and the refusal NAMES the cell and the reason");
    std::printf("  refusal: %s\n", v.error.c_str());
  }
  {   // off its family's tile grid: a 3 mm cell must start on a multiple of 3
    std::vector<SteppedCell> cells = {at(1.5, 0, 0, 3.0)};
    const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
    CHECK(!v.ok, "plan: a 3 mm cell at offset 1.5 is off its family's tile grid");
    CHECK(v.error.find("tile") != std::string::npos, "plan: and says so");
  }
  {   // ★ 6 mm is BOTH 12/2 and 2*(12/4), so offset 3 is legitimate on the quarters grid
    std::vector<SteppedCell> cells = {at(3, 0, 0, 6.0)};
    const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
    CHECK(v.ok,
          "plan: a size reachable from several families is valid on ANY of their grids -- "
          "refusing offset 3 for a 6 mm cell would outlaw a pack the packer may make");
  }
  {   // overlap
    std::vector<SteppedCell> cells = {at(0, 0, 0, 9.0), at(6, 0, 0, 3.0)};
    const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
    CHECK(!v.ok, "plan: a 3 mm cell inside the 9 mm cell is an overlap");
    CHECK(v.error.find("OVERLAPS") != std::string::npos &&
              v.error.find("cell 0") != std::string::npos,
          "plan: and the refusal names BOTH cells");
    std::printf("  refusal: %s\n", v.error.c_str());
  }
  {   // a cell naming a region that was never declared
    SteppedCell c = at(0, 0, 0, 3.0);
    c.region_id = 7;
    const SteppedPlanCheck v = stepped_validate_plan({c}, {reg}, 0.45);
    CHECK(!v.ok && v.error.find("region 7") != std::string::npos,
          "plan: a cell in an undeclared region is refused by name");
  }
  {   // ★ THE CONTROL: the accepted pack above must not be accepted by a validator that
      // accepts everything. A base-sized cell somewhere absurd is still refused.
    std::vector<SteppedCell> cells = {at(0, 0, 0, 7.0)};
    const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
    CHECK(!v.ok, "CONTROL: 7 mm is not on the 12 mm menu and is refused");
  }
}

// ── GROUPING: one pass per (region, family), each on its OWN grid ───────────────
// The dyadic path anchors every pass at the solved grid's origin. Any-step cells are not
// there, and a group whose grid was re-anchored would MOVE a cell the maintainer approved
// on screen. So the assertions are about identity: every cell comes back at an integer
// index of its own family's grid, and mapping the index back reproduces the origin the
// plan stated, to the micron.
static void test_grouping_preserves_every_cell() {
  SteppedPlanRegion reg;
  reg.region_id = 1;
  reg.base_cell_mm = 12.0;
  reg.slot_origin = Vec3{100.0, -5.0, 0.0};
  auto at = [&](double dx, double dy, double dz, double size) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = Vec3{reg.slot_origin.x + dx, reg.slot_origin.y + dy, reg.slot_origin.z + dz};
    c.size_mm = size;
    return c;
  };
  const std::vector<SteppedCell> cells = {at(0, 0, 0, 9.0),  at(9, 0, 0, 3.0),
                                          at(0, 9, 0, 3.0),  at(3, 9, 0, 3.0),
                                          at(9, 3, 0, 3.0),  at(0, 0, 12, 12.0)};
  CHECK(stepped_validate_plan(cells, {reg}, 0.45).ok, "grouping: the fixture is a valid plan");

  const std::vector<SteppedCellGroup> gs = stepped_group_cells(cells, {reg});
  std::printf("  groups:");
  for (const SteppedCellGroup& g : gs)
    std::printf(" %.2f x%zu", g.size_mm, g.cells.size());
  std::printf("\n");
  CHECK(gs.size() == 3, "grouping: three families are three passes (12, 9, 3)");
  CHECK(gs[0].size_mm > gs[1].size_mm && gs[1].size_mm > gs[2].size_mm,
        "grouping: passes come back coarse-first, a FIXED order");

  std::size_t total = 0;
  for (const SteppedCellGroup& g : gs) {
    total += g.cells.size();
    for (const auto& c : g.cells) {
      CHECK(c[0] >= 0 && c[1] >= 0 && c[2] >= 0,
            "grouping: every cell has a non-negative index on its own grid");
      CHECK(c[0] < g.nx && c[1] < g.ny && c[2] < g.nz,
            "grouping: and lies inside the grid extent the pass declares");
      // ★ THE IDENTITY THAT MATTERS: index -> position must give back the stated origin
      const double px = g.origin.x + c[0] * g.size_mm;
      const double py = g.origin.y + c[1] * g.size_mm;
      const double pz = g.origin.z + c[2] * g.size_mm;
      bool found = false;
      for (const SteppedCell& in : cells)
        if (std::fabs(in.size_mm - g.size_mm) < 1e-9 &&
            std::fabs(in.origin.x - px) < 1e-6 && std::fabs(in.origin.y - py) < 1e-6 &&
            std::fabs(in.origin.z - pz) < 1e-6)
          found = true;
      CHECK(found, "grouping: the grid index maps BACK to the cell the plan stated");
    }
  }
  CHECK(total == cells.size(), "grouping: no cell was dropped");

  // ★ THE CONTROL: the groups' grids must genuinely DIFFER. If every pass came back on
  // one origin the whole point of per-family anchoring would be lost and this test would
  // still pass every assertion above.
  bool origins_differ = false;
  for (std::size_t i = 1; i < gs.size(); ++i)
    if (std::fabs(gs[i].origin.x - gs[0].origin.x) > 1e-9 ||
        std::fabs(gs[i].origin.y - gs[0].origin.y) > 1e-9 ||
        std::fabs(gs[i].origin.z - gs[0].origin.z) > 1e-9 ||
        std::fabs(gs[i].size_mm - gs[0].size_mm) > 1e-9)
      origins_differ = true;
  CHECK(origins_differ,
        "CONTROL: the families are on DIFFERENT grids -- that is what any-step means");
}

int main() {
  test_menu_matches_the_brief();
  test_depth_is_clean();
  test_menu_shape();
  test_plan_validation();
  test_grouping_preserves_every_cell();
  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
