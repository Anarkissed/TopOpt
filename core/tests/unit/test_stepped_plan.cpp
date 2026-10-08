// ── ANY-STEP STEPPED: the size menu ─────────────────────────────────────────────
// The expected menus are the maintainer's, from the brief of 2026-09-17, and they are
// asserted to the entry rather than to a count: a menu with the right number of wrong
// sizes would pack a part that does not match the preview the maintainer approved.
#include "topopt/beam_network.hpp"
#include "topopt/stepped_plan.hpp"
#include "topopt/lattice_algorithm.hpp"
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
  const std::vector<double> got = stepped_size_menu(LatticeTopology::Octet, base, bead);
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

  const std::vector<int> d12 = stepped_admitted_divisors(LatticeTopology::Octet, 12.0, 0.45);
  CHECK(std::find(d12.begin(), d12.end(), 5) != d12.end(),
        "12 mm base: fifths are admitted (tile 2.4 prints open)");
  CHECK(std::find(d12.begin(), d12.end(), 6) == d12.end(),
        "12 mm base: sixths are refused (tile 2.0 does not print open)");
  // ★ THE CONTROL. If every divisor were admitted the menu above would be a coincidence
  // of arithmetic rather than the density bound doing work. At a FATTER bead more
  // families must fall away.
  const std::vector<int> fat = stepped_admitted_divisors(LatticeTopology::Octet, 12.0, 0.90);
  CHECK(fat.size() < d12.size(),
        "CONTROL: a fatter bead admits FEWER families -- the density bound is live");
}

// ── AGAINST THE PREVIEW'S OWN LIVE HISTOGRAM ────────────────────────────────────
// The two menus above are the brief's stated examples. THIS is the app's actual output on
// a real part -- the DIAG line from §5 of the brief of 2026-09-17 -- and it is the better
// check, because it was produced by the packer on a part with TWO different base cells
// rather than written down as an expectation. Core's menus for those two bases, unioned,
// must be exactly the set of sizes the preview kept: nothing missing (a size the run
// would refuse that the screen showed) and nothing extra (a size the run would allow that
// the packer never offers).
static void test_menus_match_the_previews_live_histogram() {
  // kept=[12.00 10.31 9.60 9.00 8.00 7.73 7.20 6.87 6.00 5.16 4.80 4.00 3.44 3.00 2.58 2.40]
  const std::vector<double> diag = {12.00, 10.31, 9.60, 9.00, 8.00, 7.73, 7.20, 6.87,
                                    6.00,  5.16,  4.80, 4.00, 3.44, 3.00, 2.58, 2.40};
  std::vector<double> mine;
  for (double base : {12.0, 10.31})
    for (double s : stepped_size_menu(LatticeTopology::Octet, base, 0.45)) mine.push_back(s);
  std::sort(mine.begin(), mine.end(), std::greater<double>());
  mine.erase(std::unique(mine.begin(), mine.end(),
                         [](double a, double b) { return std::fabs(a - b) < 1e-9; }),
             mine.end());
  std::printf("  DIAG cross-check: core offers %zu size(s), the preview kept %zu\n",
              mine.size(), diag.size());
  for (double d : diag) {
    bool found = false;
    for (double m : mine) if (std::fabs(m - d) < 0.006) found = true;
    char what[128];
    std::snprintf(what, sizeof what,
                  "DIAG: the preview kept %.2f mm and core's menu offers it", d);
    CHECK(found, what);
  }
  for (double m : mine) {
    bool found = false;
    for (double d : diag) if (std::fabs(m - d) < 0.006) found = true;
    char what[128];
    std::snprintf(what, sizeof what,
                  "DIAG: core offers %.4f mm and the preview's packer can reach it", m);
    CHECK(found, what);
  }
  CHECK(mine.size() == diag.size(),
        "DIAG: the two codebases agree on the size set exactly, in both directions");
}

// ── THE STRUCTURAL MENU: THE FLOOR ALONE ────────────────────────────────────────
// Core's answer to §3.5. The 20 % "prints open" bound is a rule about how a quilt LOOKS;
// the beam network solves every strut rather than averaging them, so nothing structural
// depends on a cell being mostly air. Under a structural intent the ONLY lower bound is
// the printability floor -- which admits families the aesthetic rule refuses, and the
// difference is the whole point of asking.
static void test_structural_menu_is_the_floor_alone() {
  const double bead = 0.45;
  const double floor_mm = 4.0 * bead;      // the app's stated structural floor: 4 beads
  const std::vector<double> aesthetic = stepped_size_menu(LatticeTopology::Octet, 12.0, bead, 0.0, true);
  const std::vector<double> structural = stepped_size_menu(LatticeTopology::Octet, 12.0, bead, floor_mm, false);
  std::printf("  menu aesthetic  [%s]\n", join(aesthetic).c_str());
  std::printf("  menu structural [%s]  (floor %.2f mm)\n", join(structural).c_str(),
              floor_mm);
  CHECK(structural.size() > aesthetic.size(),
        "structural menu: dropping the aesthetic bound admits MORE sizes -- if it did "
        "not, the decision in §3.5 would have been a distinction without a difference");
  // the sixths of a 12 are 2.0 mm: above a 1.8 mm floor, below the 20 % rule
  bool has_two = false, has_ten = false;
  for (double x : structural) {
    if (std::fabs(x - 2.0) < 1e-9) has_two = true;
    if (std::fabs(x - 10.0) < 1e-9) has_ten = true;
  }
  CHECK(has_two, "structural menu: the sixths (2.0 mm) clear a 1.8 mm floor and are in");
  CHECK(has_ten, "structural menu: and 10 mm returns with them -- it is 5*(12/6)");
  for (double x : aesthetic) {
    CHECK(x > 2.2, "aesthetic menu: nothing that fine survives the 20 % rule");
  }
  // ★ AND THE FLOOR STILL BITES. Raise it and the fine families go, bound or no bound.
  const std::vector<double> tight = stepped_size_menu(LatticeTopology::Octet, 12.0, bead, 2.5, false);
  CHECK(tight.size() < structural.size(),
        "structural menu CONTROL: the floor is doing the work -- raise it and families "
        "fall away, so 'no 20 % rule' does not mean 'no bound'");
}

// ── DEPTH-CLEAN BY CONSTRUCTION ─────────────────────────────────────────────────
// A cell of size s placed at the face leaves S - floor(S/s)*s of the wall behind it, and
// the claim is that the remainder is always fillable by menu tiles that divide s -- no
// solid strip is ever laid to make up a depth. Asserted over every menu size, on several
// bases and beads, rather than on the one case that motivated it.
static void test_depth_is_clean() {
  for (double base : {12.0, 10.31, 8.0, 6.5, 20.0}) {
    for (double bead : {0.45, 0.60, 0.90}) {
      const std::vector<double> menu = stepped_size_menu(LatticeTopology::Octet, base, bead);
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
  const std::vector<double> menu = stepped_size_menu(LatticeTopology::Octet, 12.0, 0.45);
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
  const std::vector<double> tiny = stepped_size_menu(LatticeTopology::Octet, 1.2, 0.45);
  CHECK(tiny.size() == 1 && std::fabs(tiny.front() - 1.2) < 1e-9,
        "menu: a base too fine to subdivide is its own menu, not an empty one");
}

// ── THE PLAN VALIDATION: core CHECKS, it does not repack ────────────────────────
// A refusal must NAME the offending cell. A validator that returned a bare false would
// leave the app guessing which of thousands of cells it got wrong, and the whole reason
// core validates rather than repacking is that the preview is a contract.
// ── ★ RULING A: THE DOUBLED MENU IS THE HALVING LADDER ────────────────────────
// The app sends its placed cells for "doubled" too, and the only thing that differs
// from any-step is which sizes are legal. The property that matters is not that the
// halves are accepted -- a menu that accepted EVERYTHING would do that -- but that an
// any-step plan is REFUSED under Halves. A 9 mm cell on a 12 mm base is the exact
// size the dyadic ladder cannot reach, so it is the control.
// ── ★ RULING C: THE DENSITY MUST STAY WITH ITS OWN CELL ───────────────────────
// stepped_group_cells SORTS the cells into a fixed emission order. The densities
// arrive in the job's order, so pairing them by position after that sort hands the
// wrong strut width to every cell -- silently, with a plausible-looking lattice. The
// cells here are deliberately sent in an order that the sort must change, and each
// one's rho is a function of its own position so a mispairing cannot look right.
// ── R5, R3 and a FALSE ACCEPTANCE (#354's core brief, 2026-10-02) ──────────────
// Overlap was decided by a hash of ONE finest tile -- the smallest size on ANY
// region's menu -- each cell claiming llround(size/finest) slots from slot
// llround(offset/finest). The comment carried the assumption: "every cell is a whole
// number of those on every axis". Three things go wrong with it.
//
//  R5  It holds only if every region's ladder nests in every other's. Where a
//      size/tile ratio has a fraction above a half, the span rounds UP while the next
//      cell's start rounds DOWN, so two cells that merely TOUCH share a slot. One of
//      his projects produced 1,458 such collisions, every one false.
//  R3  The key is (i, j, k) alone and offsets are measured from each region's OWN slot
//      origin, so two cells at the same relative offset collide however far apart they
//      are. The brief's pair is 36 mm apart.
//  ★   And the same rounding hides REAL overlaps. Where the printability rule leaves a
//      region's menu holding nothing but its base (it does for every base at a 0.45 mm
//      bead -- see the menus below), the hash tile EQUALS the cell, so a cell is one
//      slot wide and two cells half a cell apart round into different slots. Base-size
//      cells are exempt from the alignment check, so a non-multiple offset is exactly
//      what the app sends today: two cells overlapping by half their width are
//      ACCEPTED. A false refusal costs a solve; this one ships a wrong part.
//
// So the hash cannot be repaired by changing its tile or its key: it is replaced by an
// exact test of the cells' boxes, bucketed only to find candidates. Each case below
// states its own premise, because every one of them would pass vacuously if the menus
// moved underneath it, and both ways of REFUSING stay tested -- the app reports 1,367
// REAL cross-region overlapping pairs on the stand, so a fix that simply stopped
// comparing across regions would pass R3 and ship those.
static void test_overlap_is_exact_not_a_shared_tile() {
  auto reg = [](int id, double base, Vec3 at) {
    SteppedPlanRegion r;
    r.region_id = id;
    r.base_cell_mm = base;
    r.slot_origin = at;
    return r; };
  auto cell = [](int id, Vec3 at, double size) {
    SteppedCell c;
    c.region_id = id;
    c.origin = at;
    c.size_mm = size;
    return c; };
  const double bead = 0.45;

  // ── R5: two cells that touch, on their own region's own tile grid ──
  // prints_open is OFF here for one reason: with it on, a 2.5 or 3.25 mm base admits
  // NOTHING below itself, and a test of sub-base sizes would have no sizes to use.
  const SteppedPlanRegion r1 = reg(1, 2.5, Vec3{18.0, 0.0, 8.0});
  const SteppedPlanRegion r2 = reg(2, 3.25, Vec3{54.0, 0.0, 18.0});
  const std::vector<double> m1 =
      topopt::stepped_size_menu(LatticeTopology::Octet, 2.5, bead, 0.0, false);
  const std::vector<double> m2 =
      topopt::stepped_size_menu(LatticeTopology::Octet, 3.25, bead, 0.0, false);
  double finest = 0.0;
  for (const std::vector<double>* m : {&m1, &m2})
    for (double s : *m)
      if (finest <= 0.0 || s < finest) finest = s;
  const double size = 2.0 * (3.25 / 5.0);   // 1.3 mm: region 2's own family-5 tile, x2
  bool on_menu = false;
  for (double s : m2) if (std::fabs(s - size) < 1e-9) on_menu = true;
  CHECK(on_menu, "R5 premise: 1.3 mm is on region 2's own menu");
  const double ratio = size / finest;
  CHECK(std::fabs(ratio - std::floor(ratio + 0.5)) > 0.1,
        "R5 premise: and it is NOT a whole number of the GLOBAL finest tile, which is "
        "the condition that rounded a touch into an overlap");
  const std::vector<SteppedCell> touching{
      cell(2, Vec3{54.0 + size, 0.0, 18.0}, size),
      cell(2, Vec3{54.0 + 2.0 * size, 0.0, 18.0}, size)};
  const SteppedPlanCheck t = stepped_validate_plan(LatticeTopology::Octet, touching,
                                                   {r1, r2}, bead, 0.0, false);
  CHECK(t.ok, "R5: two cells that touch on their own grid do not overlap");

  // ── R3: the same relative offset in two regions, 36 mm apart ──
  const SteppedPlanRegion a = reg(1, 3.0, Vec3{18.0, 0.0, 8.0});
  const SteppedPlanRegion b = reg(2, 3.0, Vec3{54.0, 0.0, 18.0});
  CHECK(54.0 - (18.0 + 3.0) > 0.0, "R3 premise: the two cells are disjoint in space");
  const SteppedPlanCheck far = stepped_validate_plan(
      LatticeTopology::Octet,
      {cell(1, Vec3{18.0, 0.0, 8.0}, 3.0), cell(2, Vec3{54.0, 0.0, 18.0}, 3.0)},
      {a, b}, bead);
  CHECK(far.ok, "R3: cells 36 mm apart in different regions do not overlap");

  // ── ★ the false acceptance: a base-only menu, so the tile IS the cell ──
  const std::vector<double> m3 =
      topopt::stepped_size_menu(LatticeTopology::Octet, 3.0, bead);
  CHECK(m3.size() == 1 && std::fabs(m3.front() - 3.0) < 1e-9,
        "premise: at a 0.45 mm bead a 3 mm base admits only itself, so the hash tile "
        "was the cell");
  const SteppedPlanCheck hidden = stepped_validate_plan(
      LatticeTopology::Octet,
      {cell(1, Vec3{18.0, 0.0, 8.0}, 3.0), cell(1, Vec3{19.5, 0.0, 8.0}, 3.0)},
      {a}, bead);
  CHECK(!hidden.ok,
        "overlap: two base cells half a cell apart DO overlap and must be refused");

  // ── and the refusals that must survive the change ──
  const SteppedPlanCheck rich = stepped_validate_plan(
      LatticeTopology::Octet,
      {cell(1, Vec3{18.0, 0.0, 8.0}, 2.5), cell(1, Vec3{19.0, 0.0, 8.0}, 2.5)},
      {reg(1, 2.5, Vec3{18.0, 0.0, 8.0})}, bead, 0.0, false);
  CHECK(!rich.ok, "overlap: a real overlap inside one region is still refused");
  const SteppedPlanCheck xr = stepped_validate_plan(
      LatticeTopology::Octet,
      {cell(1, Vec3{18.0, 0.0, 8.0}, 3.0), cell(2, Vec3{19.5, 0.0, 8.0}, 3.0)},
      {a, reg(2, 3.0, Vec3{19.5, 0.0, 8.0})}, bead);
  CHECK(!xr.ok, "overlap: a real overlap ACROSS two regions is still refused");
  CHECK(xr.error.find("region 1") != std::string::npos &&
            xr.error.find("region 2") != std::string::npos,
        "overlap: and a cross-region refusal names BOTH regions, because 'OVERLAPS "
        "cell 0' alone does not say where to look");
}

// ── R2 / R2x / R2b: ONE CONTAINMENT RULE FOR EVERY FACE ───────────────────────
// `origin` is the cell's MINIMUM corner (stepped_plan.hpp). The depth check projected
// that corner and added the size along the normal, which is the cell's span only when
// the normal points the way that makes the minimum corner the near one -- a POSITIVE
// axis normal. On a wall whose normal has a negative component the minimum corner is
// the cell's DEEPEST point, so every layer read one cell too deep: the deepest layer
// was refused (1,467 sound cells on the stand's -y wall) and a cell one layer in FRONT
// of the face -- outside the prism and outside the part -- was accepted, and laid, on
// the part's face (R2x: 612 triangles at y 11.55-12.45).
//
// The reviewer's ruling of 2026-10-05 settles R2, R2x and R2b with ONE rule for every
// face, axis-aligned or tilted:
//   - the cell's CENTRE must lie in the prism, 0 <= s_mid <= depth;
//   - its FAR side must not pass the depth, using the cube's true projection interval
//     [s0 + S*sum(min(0,n_i)), s0 + S*sum(max(0,n_i))];
//   - its NEAR side MAY stand in front of the face plane.
// That last clause is the one worth a test of its own, and it is the one a "fix" that
// merely swapped the sign would get wrong. The app starts a tilted facet's span in
// front of the plane BY DESIGN, so the cube covers the slant; what falls outside the
// part is not laid. A near-side bound would refuse the stand's 90 face-23 facet cells
// for doing the one thing that makes them cover their face. So the tilted case below
// is asserted ACCEPTED while its near side stands 2.12 mm in front of the plane, and
// it is what distinguishes this rule from any one-sided reading of the interval.
static void test_depth_projects_the_cube_not_one_corner() {
  auto region = [](Vec3 normal, Vec3 face_at) {
    SteppedPlanRegion reg;
    reg.region_id = 1;
    reg.base_cell_mm = 3.0;
    reg.slot_origin = face_at;
    reg.normal = normal;
    reg.depth_mm = 12.0;
    return reg; };
  auto cell_at = [](Vec3 at) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = at;
    c.size_mm = 3.0;   // the base size, so alignment is not what is being tested
    return c; };
  auto ok = [](const SteppedPlanRegion& reg, const SteppedCell& c) {
    return stepped_validate_plan(LatticeTopology::Octet, {c}, {reg}, 0.45).ok; };

  // ── the -y wall: face plane y = 12, prism y in [0, 12] ──
  const SteppedPlanRegion neg = region(Vec3{0.0, -1.0, 0.0}, Vec3{18.0, 12.0, 8.0});
  // The deepest layer, y in [0, 3]: 9 to 12 mm along the normal, centre at 10.5. This
  // is the brief's R2_min_corner_depth.json, which core refused.
  CHECK(ok(neg, cell_at(Vec3{18.0, 0.0, 8.0})),
        "R2: the deepest layer of a -y wall is inside its own prism");
  CHECK(ok(neg, cell_at(Vec3{18.0, 9.0, 8.0})),
        "R2: and so is the layer against the -y face");
  // One layer deeper: the far side reaches 15 mm past a 12 mm prism.
  const SteppedPlanCheck past =
      stepped_validate_plan(LatticeTopology::Octet, {cell_at(Vec3{18.0, -3.0, 8.0})},
                            {neg}, 0.45);
  CHECK(!past.ok, "R2: a cell whose far side passes the prism is refused");
  CHECK(past.error.find("region 1") != std::string::npos &&
            past.error.find("prism") != std::string::npos,
        "R2: and the refusal names the region and what it left");
  // ★ R2x: one layer in FRONT of the face, y in [12, 15]. Its centre projects to
  // -1.5 mm, outside the prism. The one-corner check read it as 0 to 3 and laid it.
  const SteppedPlanCheck in_front =
      stepped_validate_plan(LatticeTopology::Octet, {cell_at(Vec3{18.0, 12.0, 8.0})},
                            {neg}, 0.45);
  CHECK(!in_front.ok,
        "R2x: a cell wholly in front of a -y face is refused, not accepted and laid");

  // ── the +y wall: unchanged by the fix, which is half the point ──
  const SteppedPlanRegion pos = region(Vec3{0.0, 1.0, 0.0}, Vec3{18.0, 0.0, 8.0});
  CHECK(ok(pos, cell_at(Vec3{18.0, 0.0, 8.0})), "R2: +y, the layer at the face is inside");
  CHECK(ok(pos, cell_at(Vec3{18.0, 9.0, 8.0})), "R2: +y, the deepest layer is inside");
  CHECK(!ok(pos, cell_at(Vec3{18.0, 12.0, 8.0})),
        "R2: +y, a cell past the prism is refused");
  CHECK(!ok(pos, cell_at(Vec3{18.0, -3.0, 8.0})),
        "R2: +y, a cell in front of the face is refused -- its centre is outside");

  // ── ★ R2b, THE TILTED FACET: the near side may stand in front of the plane ──
  // A 45-degree normal. At the slot origin itself the cube straddles the plane: its
  // projection runs -2.12 to +2.12 mm (the extent along n is sqrt(2)*S, wider than S)
  // while its centre sits exactly ON the plane, inside the prism. The app places such
  // cells deliberately so the cube covers the slant. Offset zero keeps the alignment
  // check out of this: it is a multiple of every size.
  const double r2 = 0.70710678118654752;
  const SteppedPlanRegion tilt =
      region(Vec3{0.0, -r2, r2}, Vec3{18.0, 12.0, 8.0});
  CHECK(ok(tilt, cell_at(Vec3{18.0, 12.0, 8.0})),
        "R2b: a tilted facet's cell is accepted with its near side in front of the plane");
  // But the centre still has to be in the prism, and the far side still bounded.
  CHECK(!ok(tilt, cell_at(Vec3{18.0, 15.0, 5.0})),
        "R2b: a tilted cell whose CENTRE leaves the prism is still refused");
  // This one has its centre INSIDE (10.61 mm of a 12 mm prism) and fails only on its
  // far side (12.73 mm), so it is what tests the far-side bound rather than the centre.
  CHECK(!ok(tilt, cell_at(Vec3{18.0, 12.0, 23.0})),
        "R2b: and so is one whose centre is inside but whose far side passes the depth");
}

static void test_group_keeps_each_cells_own_rho() {
  SteppedPlanRegion reg;
  reg.region_id = 1;
  reg.base_cell_mm = 12.0;
  reg.slot_origin = Vec3{100.0, -5.0, 0.0};

  auto at = [&](double dx, double dy, double dz, double rho) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = Vec3{reg.slot_origin.x + dx, reg.slot_origin.y + dy, reg.slot_origin.z + dz};
    c.size_mm = 3.0;
    c.rho = rho;
    return c; };
  // sent in DESCENDING corner order, which is the reverse of the emission order
  auto rho_for = [](double dx, double dy, double dz) {
    return 0.10 + 0.01 * (dx / 3.0) + 0.001 * (dy / 3.0) + 0.0001 * (dz / 3.0); };
  std::vector<SteppedCell> cells;
  for (int i = 1; i >= 0; --i)
    for (int j = 1; j >= 0; --j)
      for (int k = 1; k >= 0; --k) {
        const double dx = 3.0 * i, dy = 3.0 * j, dz = 3.0 * k;
        cells.push_back(at(dx, dy, dz, rho_for(dx, dy, dz)));
      }
  const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
  CHECK(v.ok, "rho: the fixture plan is valid");
  const std::vector<SteppedCellGroup> gs = stepped_group_cells(cells, {reg});
  CHECK(gs.size() == 1, "rho: one family, one group");
  const SteppedCellGroup& g = gs.front();
  CHECK(g.rho.size() == g.cells.size(),
        "rho: one density per cell, in the same order");
  std::size_t wrong = 0;
  for (std::size_t c = 0; c < g.cells.size(); ++c) {
    // recover the cell's offset from the group origin and ask what its rho SHOULD be
    const double dx = g.origin.x + g.cells[c][0] * g.size_mm - reg.slot_origin.x;
    const double dy = g.origin.y + g.cells[c][1] * g.size_mm - reg.slot_origin.y;
    const double dz = g.origin.z + g.cells[c][2] * g.size_mm - reg.slot_origin.z;
    if (std::fabs(g.rho[c] - rho_for(dx, dy, dz)) > 1e-12) ++wrong;
  }
  std::printf("  rho: %zu cell(s), %zu mispaired after the sort\n", g.cells.size(), wrong);
  CHECK(g.cells.size() == 8, "rho: every cell survived grouping");
  CHECK(wrong == 0, "rho: each cell kept ITS OWN density through the emission sort");
  // a plan that sent no rho leaves zeros, which is the caller's "derive it as before"
  std::vector<SteppedCell> bare = cells;
  for (SteppedCell& c : bare) c.rho = 0.0;
  const std::vector<SteppedCellGroup> gb = stepped_group_cells(bare, {reg});
  CHECK(!gb.empty() && gb.front().rho.size() == gb.front().cells.size(),
        "rho: the array is still sized when nothing was sent");
  for (double r : gb.front().rho)
    CHECK(r == 0.0, "rho: and it is all zeros, so the caller falls back");
}

// ── ★ RULING B: THE OUTLINE BEAM'S WIDTH IS DERIVED, NOT SENT ─────────────────
// §1.5's formula, pinned on the maintainer's own part so the two sides cannot drift:
// a 1.72 mm voxel at a 0.45 mm bead gives 1.21 mm, the number the brief quotes. Both
// terms are floors, and the test shows each one GOVERNING somewhere -- a formula whose
// second term never binds is a formula with a dead branch.
// ── ★ THE AESTHETIC CEILING IS THE DIAMETER TABLE'S PREIMAGE ──────────────────
// Core holds two measured tables that are not exact inverses. A rho arriving as
// stepped_cells[].rho is consumed by the DIAMETER table, so the ceiling has to be
// stated in the units that table reads -- otherwise core caps at a density which,
// sent through the table that actually sizes the strut, builds a THINNER strut than
// the geometry the maintainer ruled on. Core published the wrong one of the two and
// told the app its number was 3.5 % out; the app pushed back and was right.
// ── ★ §3: THE RUN'S GEOMETRY AGAINST THE LIST THAT SPECIFIED IT ──────────────
// The brief asks for a Hausdorff bound of ONE BEAD between what the preview describes
// and what the run lays down. The app's half is its capsule list; core's half is this
// -- given a cell list with densities, every strut core sizes must match the strut the
// list's own rho implies, under core's law, to within a bead.
//
// ★ THIS IS NOT THAT HAUSDORFF TEST, and saying so is the point. Core cannot measure a
// distance to a preview it does not have; the app's capsule dump is the other half and
// has not arrived. What core can prove alone is the half that is core's: that nothing
// between "the app said rho for this cell" and "core sized a strut" moves the number.
// The mesh-to-mesh bound stays OUTSTANDING rather than being simulated here -- a test
// that compares core against core and calls the answer a parity bound would be worse
// than no test, because it would report agreement no matter how far the two drifted.
static void test_strut_radius_matches_the_sent_rho() {
  const double bead = 0.45;
  SteppedPlanRegion reg;
  reg.region_id = 1;
  reg.base_cell_mm = 12.0;
  reg.slot_origin = Vec3{100.0, -5.0, 0.0};

  // a mixed pack: three sizes, each with its own density, as the app would send
  struct Want { double dx, dy, dz, size, rho; };
  const std::vector<Want> want = {
      {0, 0, 0, 6.0, 0.2189}, {6, 0, 0, 3.0, 0.1740},
      {6, 3, 0, 3.0, 0.4500}, {0, 6, 0, 6.0, 0.0950}};
  std::vector<SteppedCell> cells;
  for (const Want& w : want) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = Vec3{reg.slot_origin.x + w.dx, reg.slot_origin.y + w.dy,
                    reg.slot_origin.z + w.dz};
    c.size_mm = w.size;
    c.rho = w.rho;
    cells.push_back(c);
  }
  const SteppedPlanCheck v =
      stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, bead, 0.0, true, SteppedMenu::Halves);
  CHECK(v.ok, "parity: the fixture plan validates under the doubled menu");

  const std::vector<SteppedCellGroup> gs = stepped_group_cells(cells, {reg});
  // ★ WHAT IS ACTUALLY CHECKED, stated because the obvious version of this test is a
  // TAUTOLOGY: computing "what the run sizes" and "what the list implies" with the same
  // call and diffing them reports 0.000e+00 forever and proves nothing. The wire-to-
  // geometry step core owns is the SURVIVAL of the sent rho -- from the job, through
  // validation and grouping, to the value the radius is taken from -- and then that the
  // radius is a strut a printer can make inside that cell.
  std::size_t checked = 0;
  double worst_rho = 0.0;
  for (const SteppedCellGroup& g : gs)
    for (std::size_t i = 0; i < g.cells.size(); ++i) {
      // the rho this cell was SENT with, recovered from the fixture by position
      const double dx = g.origin.x + g.cells[i][0] * g.size_mm - reg.slot_origin.x;
      const double dy = g.origin.y + g.cells[i][1] * g.size_mm - reg.slot_origin.y;
      const double dz = g.origin.z + g.cells[i][2] * g.size_mm - reg.slot_origin.z;
      double sent = -1.0;
      for (const Want& w : want)
        if (std::fabs(w.dx - dx) < 1e-9 && std::fabs(w.dy - dy) < 1e-9 &&
            std::fabs(w.dz - dz) < 1e-9 && std::fabs(w.size - g.size_mm) < 1e-9)
          sent = w.rho;
      CHECK(sent >= 0.0, "parity: the cell is the one the fixture sent");
      worst_rho = std::max(worst_rho, std::fabs(g.rho[i] - sent));
      const double r = 0.5 * octet_strut_diameter_mm(g.rho[i], g.size_mm);
      ++checked;
      CHECK(2.0 * r >= bead * 0.999,
            "parity: every sized strut is at least a bead across");
      CHECK(2.0 * r < g.size_mm, "parity: and fits inside its own cell");
    }
  std::printf("  parity: %zu cell(s) checked, worst rho drift %.3e (bead %.3f)\n",
              checked, worst_rho, bead);
  CHECK(checked == want.size(), "parity: every sent cell was checked");
  CHECK(worst_rho == 0.0,
        "parity: the density the job sent is the density the radius is taken from, "
        "EXACTLY -- not within a tolerance, because nothing on this path is allowed "
        "to adjust it");

  // ★ THE CONTROL. Size one cell from the WRONG density -- the forward density law's
  // 0.2117 instead of the diameter table's 0.2189 -- and the disagreement must be
  // visible, or this test would pass against a core that used either table.
  const double r_right = 0.5 * octet_strut_diameter_mm(0.218871, 4.0);
  const double r_wrong = 0.5 * octet_strut_diameter_mm(0.211733, 4.0);
  std::printf("  parity control: right %.4f vs wrong-table %.4f mm (delta %.4f)\n",
              r_right, r_wrong, std::fabs(r_right - r_wrong));
  CHECK(std::fabs(r_right - r_wrong) > 1e-3,
        "parity CONTROL: the two tables really do give different struts, so the bound "
        "above is measuring something");
}

static void test_aesthetic_ceiling_is_the_diameter_preimage() {
  const double ceil = octet_aesthetic_density_ceiling();
  const double fwd = octet_relative_density(1.0, 0.5 * kOctetAestheticStrutPerCell);
  std::printf("  ceiling: diameter preimage %.6f | forward law %.6f | that forward "
              "value builds strut/cell %.6f\n", ceil, fwd,
              octet_strut_diameter_mm(fwd, 4.0) / 4.0);
  // it must BUILD the ruled geometry, at any cell
  for (double cell : {2.58, 3.0, 4.0, 12.0}) {
    const double got = octet_strut_diameter_mm(ceil, cell) / cell;
    CHECK(std::fabs(got - kOctetAestheticStrutPerCell) < 1e-6,
          "ceiling: sent through the diameter table it builds strut/cell 0.20 exactly");
  }
  CHECK(std::fabs(ceil - 0.218871) < 1e-5,
        "ceiling: and that is the app's 0.219, not the forward law's 0.2117");
  // ★ THE CONTROL: the forward law's value does NOT build it, which is the whole
  // reason the two cannot be used interchangeably.
  CHECK(std::fabs(octet_strut_diameter_mm(fwd, 4.0) / 4.0 - kOctetAestheticStrutPerCell)
            > 0.003,
        "ceiling: the forward law's value builds a measurably THINNER strut -- the two "
        "tables are not inverses, and which one you use is not a rounding choice");
}

static void test_outline_beam_width() {
  // the brief's part
  const double his = lattice_outline_beam_mm(0.45, 1.72);
  std::printf("  beam: bead 0.45, voxel 1.72 -> %.4f mm (brief says 1.21)\n", his);
  CHECK(std::fabs(his - 1.21) < 0.005,
        "beam: the maintainer's part gives the brief's 1.21 mm");

  // a fat bead on a fine grid: 2*bead governs
  const double fat = lattice_outline_beam_mm(1.20, 0.30);
  CHECK(std::fabs(fat - 2.40) < 1e-12, "beam: a fat bead governs -- two beads wide");
  // a fine bead on a coarse grid: trim + half a voxel governs, trim CLAMPED at 0.35
  const double coarse = lattice_outline_beam_mm(0.20, 4.00);
  CHECK(std::fabs(coarse - (0.35 + 2.00)) < 1e-12,
        "beam: on a coarse grid the trim clamps at 0.35 and the grid term governs");
  // and clamped at the LOW end too: 0.35*0.1 = 0.035 -> 0.10
  const double fine = lattice_outline_beam_mm(0.01, 0.10);
  CHECK(std::fabs(fine - (0.10 + 0.05)) < 1e-12,
        "beam: and at the low end the trim clamps up to 0.10");
  CHECK(lattice_outline_beam_mm(0.45, 0.0) == 0.0,
        "beam: no voxel, no beam -- it is a grid-resolved wall");

  // THE BLEED is a threshold, not a ramp
  CHECK(lattice_outline_bleed_mm(24.99) == 0.0, "bleed: nothing below 25 mm");
  CHECK(std::fabs(lattice_outline_bleed_mm(25.0) - 5.0) < 1e-12, "bleed: 5 mm at 25");
  CHECK(std::fabs(lattice_outline_bleed_mm(30.0) - 7.5) < 1e-12, "bleed: 7.5 mm at 30");
  CHECK(lattice_outline_bleed_mm(0.0) == 0.0, "bleed: and none at all with no band");
  // it is monotone above the threshold, so a wider band never bleeds LESS
  double prev = 0.0;
  for (double b = 25.0; b <= 60.0; b += 0.5) {
    const double v = lattice_outline_bleed_mm(b);
    CHECK(v >= prev, "bleed: monotone in the band width");
    prev = v;
  }
}

static void test_doubled_menu_is_halves_only() {
  const double base = 12.0, bead = 0.45;
  const std::vector<double> halves =
      stepped_size_menu(LatticeTopology::Octet, base, bead, 0.0, true, SteppedMenu::Halves);
  const std::vector<double> anystep =
      stepped_size_menu(LatticeTopology::Octet, base, bead, 0.0, true, SteppedMenu::AnyStep);
  std::printf("  doubled menu:");
  for (double s : halves) std::printf(" %.4g", s);
  std::printf("  (any-step has %zu sizes)\n", anystep.size());

  CHECK(!halves.empty() && halves.front() == base,
        "doubled: the base is on the menu and is the largest");
  for (std::size_t i = 1; i < halves.size(); ++i)
    CHECK(std::fabs(halves[i - 1] / halves[i] - 2.0) < 1e-9,
          "doubled: every step is exactly a halving");
  CHECK(halves.size() < anystep.size(),
        "doubled: and it is a STRICT subset of any-step's menu, not the same list");
  // the sizes any-step reaches that halving cannot
  // (3.0 is 12/4 and IS dyadic -- it belongs on both menus. The sizes below are the
  // ones only k*(S/n) can reach.)
  for (double s : {9.6, 9.0, 8.0, 7.2, 4.8, 2.4}) {
    bool in_halves = false;
    for (double h : halves) if (std::fabs(h - s) < 1e-9) in_halves = true;
    CHECK(!in_halves, "doubled: a k*(S/n) size is NOT on the halving ladder");
  }

  SteppedPlanRegion reg;
  reg.region_id = 1;
  reg.base_cell_mm = base;
  reg.slot_origin = Vec3{100.0, -5.0, 0.0};
  auto at = [&](double dx, double dy, double dz, double size) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = Vec3{reg.slot_origin.x + dx, reg.slot_origin.y + dy, reg.slot_origin.z + dz};
    c.size_mm = size;
    return c; };

  {   // a dyadic pack: a 6 at the face with 3 mm cells beside it
    std::vector<SteppedCell> cells = {at(0, 0, 0, 6.0), at(6, 0, 0, 3.0),
                                      at(6, 3, 0, 3.0), at(0, 6, 0, 6.0)};
    const SteppedPlanCheck v =
        stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, bead, 0.0, true, SteppedMenu::Halves);
    std::printf("  doubled plan: %s\n", v.ok ? "ok" : v.error.c_str());
    CHECK(v.ok, "doubled: a halving pack is accepted");
    CHECK(v.cells == 4, "doubled: every cell counted");
  }
  {   // ★ THE CONTROL: the same validator must REFUSE a 9
    std::vector<SteppedCell> cells = {at(0, 0, 0, 9.0)};
    const SteppedPlanCheck v =
        stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, bead, 0.0, true, SteppedMenu::Halves);
    CHECK(!v.ok, "doubled: a 9 mm any-step cell is REFUSED on the halving ladder");
    CHECK(v.error.find("menu") != std::string::npos,
          "doubled: and the refusal names the menu, with the cell");
    // the same plan under any-step is fine, so the refusal is the MENU and not the cell
    const SteppedPlanCheck a =
        stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, bead, 0.0, true, SteppedMenu::AnyStep);
    CHECK(a.ok, "doubled: and that very cell is accepted under any-step -- the menu is "
                "what refused it, not the geometry");
  }
}

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
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
    std::printf("  plan: %s  hist [%s]\n", v.ok ? "ok" : v.error.c_str(),
                v.histogram_line.c_str());
    CHECK(v.ok, "plan: a 9 with 3 mm tiles behind and beside it is accepted");
    CHECK(v.cells == 4, "plan: it counted every cell");
    CHECK(v.histogram.size() == 2 && v.histogram.front().first == 9.0,
          "plan: the histogram is descending by size, like the preview's DIAG");
  }
  {   // ★ a size that is not on the menu -- 10 mm, the entry the sixths would have given
    std::vector<SteppedCell> cells = {at(0, 0, 0, 10.0)};
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
    CHECK(!v.ok, "plan: 10 mm is refused -- it is only reachable from the sixths");
    CHECK(v.error.find("not on that region's menu") != std::string::npos &&
              v.error.find("cell 0") != std::string::npos,
          "plan: and the refusal NAMES the cell and the reason");
    std::printf("  refusal: %s\n", v.error.c_str());
  }
  {   // off its family's tile grid: a 3 mm cell must start on a multiple of 3
    std::vector<SteppedCell> cells = {at(1.5, 0, 0, 3.0)};
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
    CHECK(!v.ok, "plan: a 3 mm cell at offset 1.5 is off its family's tile grid");
    CHECK(v.error.find("tile") != std::string::npos, "plan: and says so");
  }
  {   // ★ 6 mm is BOTH 12/2 and 2*(12/4), so offset 3 is legitimate on the quarters grid
    std::vector<SteppedCell> cells = {at(3, 0, 0, 6.0)};
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
    CHECK(v.ok,
          "plan: a size reachable from several families is valid on ANY of their grids -- "
          "refusing offset 3 for a 6 mm cell would outlaw a pack the packer may make");
  }
  {   // overlap
    std::vector<SteppedCell> cells = {at(0, 0, 0, 9.0), at(6, 0, 0, 3.0)};
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
    CHECK(!v.ok, "plan: a 3 mm cell inside the 9 mm cell is an overlap");
    CHECK(v.error.find("OVERLAPS") != std::string::npos &&
              v.error.find("cell 0") != std::string::npos,
          "plan: and the refusal names BOTH cells");
    std::printf("  refusal: %s\n", v.error.c_str());
  }
  {   // a cell naming a region that was never declared
    SteppedCell c = at(0, 0, 0, 3.0);
    c.region_id = 7;
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, {c}, {reg}, 0.45);
    CHECK(!v.ok && v.error.find("region 7") != std::string::npos,
          "plan: a cell in an undeclared region is refused by name");
  }
  {   // ★ THE CONTROL: the accepted pack above must not be accepted by a validator that
      // accepts everything. A base-sized cell somewhere absurd is still refused.
    std::vector<SteppedCell> cells = {at(0, 0, 0, 7.0)};
    const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
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
  CHECK(stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45).ok, "grouping: the fixture is a valid plan");

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

// ── A TWO-FAMILY SEAM MUST WELD, AND UN-SUBDIVIDED IT MUST NOT ──────────────────
// The brief's §4 control, and the reason it is a control rather than a nicety: the weld
// is ENDPOINT-based, so an octet strut -- one straight member up to a whole base cell
// long -- meeting another at mid-span has no vertex near the contact and is NOT fused.
// That failure is silent. It does not throw or warn; it reports a lattice in pieces, and
// a lattice in pieces certifies CLEAN because nothing in it is carrying load to complain
// about. So the test asserts both directions: subdivided welds, un-subdivided does not.
static void test_seam_welds_only_when_subdivided() {
  // A 9 mm cell's strut running in x, and a 8 mm cell's strut arriving at its MIDDLE
  // from below -- the seam the brief describes, where a face centre of one family lands
  // mid-strut on another's face.
  const double r = 0.3;
  std::vector<BeamSegment> raw;
  BeamSegment along;  along.a = Vec3{0, 0, 0};   along.b = Vec3{9, 0, 0};  along.radius_mm = r;
  BeamSegment into;   into.a  = Vec3{4.5, -4, 0}; into.b  = Vec3{4.5, 0, 0}; into.radius_mm = r;
  raw.push_back(along);
  raw.push_back(into);

  {   // ★ THE POSITIVE CONTROL: as drawn, the crossing is invisible to an endpoint weld
    const BeamNetwork net = build_beam_network(raw);
    const BeamNetworkSeams seams = beam_network_seams(net);
    std::printf("  seam UN-subdivided: %zu nodes, %zu floating end(s), %zu welded\n",
                net.node_count(), seams.floating_ends, seams.welded_nodes);
    CHECK(seams.floating_ends > 0,
          "CONTROL: un-subdivided, the seam does NOT weld and leaves ends on nothing -- "
          "if this ever passes, the assertion below is proving nothing");
  }
  {
    const std::vector<BeamSegment> fine = subdivide_beam_segments(raw, 0.6);
    CHECK(fine.size() > raw.size(), "subdivision: it actually split the members");
    const BeamNetwork net = build_beam_network(fine);
    const BeamNetworkSeams seams = beam_network_seams(net);
    std::printf("  seam subdivided:    %zu nodes, %zu floating end(s), %zu welded, "
                "%zu T-junction end(s)\n",
                net.node_count(), seams.floating_ends, seams.welded_nodes,
                seams.t_junction_ends);
    CHECK(seams.welded_nodes > 0,
          "seam: subdivided, the two families FUSE at the contact -- exactly as the print "
          "fuses them");
    // The fixture has exactly THREE genuinely free tips -- both ends of the long member
    // and the far end of the arriving one. What must not happen is the seam itself
    // contributing two more, which is what the un-subdivided case above shows (4).
    CHECK(seams.floating_ends == 3,
          "seam: subdivided, the only ends on nothing are the fixture's own three tips -- "
          "the seam is not one of them");
  }
}

// ── SUBDIVISION ITSELF: length preserved, radius and tag carried ────────────────
static void test_subdivision_preserves_the_member() {
  BeamSegment s;
  s.a = Vec3{0, 0, 0};
  s.b = Vec3{10, 0, 0};
  s.radius_mm = 0.4;
  s.tag = 7;
  const std::vector<BeamSegment> out = subdivide_beam_segments({s}, 0.85);
  CHECK(out.size() == 12, "subdivision: 10 mm at 0.85 mm is 12 equal pieces");
  double total = 0.0;
  for (const BeamSegment& p : out) {
    const double dx = p.b.x - p.a.x, dy = p.b.y - p.a.y, dz = p.b.z - p.a.z;
    const double l = std::sqrt(dx * dx + dy * dy + dz * dz);
    total += l;
    CHECK(l <= 0.85 + 1e-9, "subdivision: no piece exceeds the limit");
    CHECK(p.radius_mm == s.radius_mm, "subdivision: the radius is carried");
    CHECK(p.tag == s.tag, "subdivision: and so is the tag the certificate reads");
  }
  CHECK(std::fabs(total - 10.0) < 1e-9,
        "subdivision: the pieces sum to the member -- no length invented or lost");
  // already short enough: returned untouched, so a tracer that already satisfies the
  // precondition pays nothing
  const std::vector<BeamSegment> same = subdivide_beam_segments({s}, 20.0);
  CHECK(same.size() == 1, "subdivision: a member already within the limit is left alone");
}

// ── THE PACKED SLOT: EXACTLY ONE CELL OVER EVERY POINT, OR NONE ─────────────────
// The brief's §4 generator case. Core does not own the packer -- the app sends the cells
// -- so what core owns, and what this asserts, is that a stated pack is laid down whole:
// a 12 mm slot with a 9 at offset 3 and 3 mm tiles filling the rest covers every point of
// the slot EXACTLY ONCE. Sampled on a grid finer than the finest tile rather than
// reasoned about, because "no two cells overlap" and "nothing is left uncovered" are the
// two halves of one claim and a counting argument proves only the first.
static void test_packed_slot_covers_exactly_once() {
  SteppedPlanRegion reg;
  reg.region_id = 1;
  reg.base_cell_mm = 12.0;
  reg.slot_origin = Vec3{0, 0, 0};

  std::vector<SteppedCell> cells;
  auto put = [&](double x, double y, double z, double size) {
    SteppedCell c;
    c.region_id = 1;
    c.origin = Vec3{x, y, z};
    c.size_mm = size;
    cells.push_back(c);
  };
  // the 9, at offset 3 on its family's tile (9 = 3*(12/4), so multiples of 3)
  put(3, 3, 0, 9.0);
  // 3 mm tiles everywhere the 9 is not
  for (int i = 0; i < 4; ++i)
    for (int j = 0; j < 4; ++j)
      for (int k = 0; k < 4; ++k) {
        const double x = i * 3.0, y = j * 3.0, z = k * 3.0;
        const bool in_nine = x >= 3.0 && y >= 3.0 && z < 9.0;
        if (!in_nine) put(x, y, z, 3.0);
      }

  const SteppedPlanCheck v = stepped_validate_plan(LatticeTopology::Octet, cells, {reg}, 0.45);
  std::printf("  packed slot: %zu cells -> %s [%s]\n", cells.size(),
              v.ok ? "valid" : v.error.c_str(), v.histogram_line.c_str());
  CHECK(v.ok, "packed slot: the arrangement validates -- sizes on the menu, on their "
              "grids, and no overlap");
  CHECK(cells.size() == 1 + 37,
        "packed slot: one 9 and thirty-seven 3s fill a 12 mm slot (64 tiles less the 27 "
        "the 9 covers)");

  // ★ COVERAGE, SAMPLED. A point of the slot must be in exactly one cell.
  const double h = 0.5;                       // finer than the finest tile
  std::size_t once = 0, twice = 0, none = 0;
  for (double x = h / 2; x < 12.0; x += h)
    for (double y = h / 2; y < 12.0; y += h)
      for (double z = h / 2; z < 12.0; z += h) {
        int hits = 0;
        for (const SteppedCell& c : cells)
          if (x >= c.origin.x && x < c.origin.x + c.size_mm && y >= c.origin.y &&
              y < c.origin.y + c.size_mm && z >= c.origin.z && z < c.origin.z + c.size_mm)
            ++hits;
        if (hits == 1) ++once; else if (hits == 0) ++none; else ++twice;
      }
  std::printf("  packed slot coverage: %zu once, %zu uncovered, %zu doubled\n", once,
              none, twice);
  CHECK(twice == 0, "packed slot: NO point is covered twice");
  CHECK(none == 0, "packed slot: and no point of the slot is left uncovered");

  // ── cut by the outline: the cells the outline removes are simply absent ───────
  // Depth-cleanliness means what is left behind a cell is a whole number of tiles, so an
  // outline that removes a 3 mm slab leaves an arrangement that is still exactly-once
  // over what remains -- no strip has to be laid solid to make the depth up.
  std::vector<SteppedCell> cut;
  for (const SteppedCell& c : cells)
    if (!(c.origin.x < 3.0)) cut.push_back(c);
  const SteppedPlanCheck vc = stepped_validate_plan(LatticeTopology::Octet, cut, {reg}, 0.45);
  CHECK(vc.ok, "outline-cut slot: still a valid arrangement");
  std::size_t cut_once = 0, cut_bad = 0;
  for (double x = 3.0 + h / 2; x < 12.0; x += h)
    for (double y = h / 2; y < 12.0; y += h)
      for (double z = h / 2; z < 12.0; z += h) {
        int hits = 0;
        for (const SteppedCell& c : cut)
          if (x >= c.origin.x && x < c.origin.x + c.size_mm && y >= c.origin.y &&
              y < c.origin.y + c.size_mm && z >= c.origin.z && z < c.origin.z + c.size_mm)
            ++hits;
        if (hits == 1) ++cut_once; else ++cut_bad;
      }
  CHECK(cut_bad == 0,
        "outline-cut slot: what the outline leaves is STILL covered exactly once -- no "
        "solid strip is needed to make up a depth");

  // ★ THE CONTROL: the coverage test must be able to FAIL. Move one tile onto the 9 and
  // the doubled count has to rise, or the sampling above is proving nothing.
  std::vector<SteppedCell> broken = cells;
  broken.back().origin = Vec3{3, 3, 0};
  const SteppedPlanCheck vb = stepped_validate_plan(LatticeTopology::Octet, broken, {reg}, 0.45);
  CHECK(!vb.ok && vb.error.find("OVERLAPS") != std::string::npos,
        "CONTROL: a tile moved onto the 9 IS caught as an overlap -- the check has teeth");
}

int main() {
  test_menu_matches_the_brief();
  test_menus_match_the_previews_live_histogram();
  test_structural_menu_is_the_floor_alone();
  test_depth_is_clean();
  test_menu_shape();
  test_plan_validation();
  test_depth_projects_the_cube_not_one_corner();
  test_overlap_is_exact_not_a_shared_tile();
  test_doubled_menu_is_halves_only();
  test_group_keeps_each_cells_own_rho();
  test_outline_beam_width();
  test_aesthetic_ceiling_is_the_diameter_preimage();
  test_strut_radius_matches_the_sent_rho();
  test_grouping_preserves_every_cell();
  test_packed_slot_covers_exactly_once();
  test_subdivision_preserves_the_member();
  test_seam_welds_only_when_subdivided();
  // ── ★ WHICH CERTIFICATE RUNS (task 2026-09-28-lattice-types-core) ───────────
  // `refuse_stepped_structural` REQUIRES any-step Stepped under Structural to name
  // `structural_certification: "beam_network"`, and core did not run it: the only call
  // sat inside `algorithm == "organic" && intent == "structural"`, so the TENSOR
  // certified instead -- the exact seam over-claim that refusal exists to prevent.
  // The decision is now one pure function, here, where a test can reach it, including
  // the combinations no job can produce today.
  {
    using topopt::LatticeAlgorithm;
    using topopt::LatticeCertificateKind;
    using topopt::lattice_certificate_kind;

    CHECK(lattice_certificate_kind(LatticeAlgorithm::Stepped, true) ==
              LatticeCertificateKind::BeamNetwork,
          "certificate: any-step Stepped (a plan is present) takes the BEAM NETWORK");
    CHECK(lattice_certificate_kind(LatticeAlgorithm::Stepped, false) ==
              LatticeCertificateKind::HomogenisedTensor,
          "certificate: legacy Stepped (no plan) keeps the tensor");
    CHECK(lattice_certificate_kind(LatticeAlgorithm::Organic, true) ==
                  LatticeCertificateKind::BeamNetwork &&
              lattice_certificate_kind(LatticeAlgorithm::Organic, false) ==
                  LatticeCertificateKind::BeamNetwork,
          "certificate: organic takes the beam network, plan or not");
    // Both bits for Doubled, because a plan must NOT silently change its instrument.
    CHECK(lattice_certificate_kind(LatticeAlgorithm::Doubled, true) ==
                  LatticeCertificateKind::HomogenisedTensor &&
              lattice_certificate_kind(LatticeAlgorithm::Doubled, false) ==
                  LatticeCertificateKind::HomogenisedTensor,
          "certificate: Doubled keeps the tensor whether or not a plan is present");

    const std::vector<std::string> bn =
        topopt::lattice_beam_network_certified_algorithms();
    bool org = false, step = false, dbl = false;
    for (const std::string& n : bn) {
      org = org || n == "organic";
      step = step || n == "stepped";
      dbl = dbl || n == "doubled";
    }
    CHECK(org, "certificate names: organic is beam-network certified");
    CHECK(step, "certificate names: stepped is beam-network certified (any-step)");
    CHECK(!dbl, "certificate names: doubled is NOT -- it keeps the tensor");
    CHECK(bn.size() == 2, "certificate names: exactly those two today");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
