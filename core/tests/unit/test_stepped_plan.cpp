// ── ANY-STEP STEPPED: the size menu ─────────────────────────────────────────────
// The expected menus are the maintainer's, from the brief of 2026-09-17, and they are
// asserted to the entry rather than to a count: a menu with the right number of wrong
// sizes would pack a part that does not match the preview the maintainer approved.
#include "topopt/beam_network.hpp"
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
    for (double s : stepped_size_menu(base, 0.45)) mine.push_back(s);
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

  const SteppedPlanCheck v = stepped_validate_plan(cells, {reg}, 0.45);
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
  const SteppedPlanCheck vc = stepped_validate_plan(cut, {reg}, 0.45);
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
  const SteppedPlanCheck vb = stepped_validate_plan(broken, {reg}, 0.45);
  CHECK(!vb.ok && vb.error.find("OVERLAPS") != std::string::npos,
        "CONTROL: a tile moved onto the 9 IS caught as an overlap -- the check has teeth");
}

int main() {
  test_menu_matches_the_brief();
  test_menus_match_the_previews_live_histogram();
  test_depth_is_clean();
  test_menu_shape();
  test_plan_validation();
  test_grouping_preserves_every_cell();
  test_packed_slot_covers_exactly_once();
  test_subdivision_preserves_the_member();
  test_seam_welds_only_when_subdivided();
  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
