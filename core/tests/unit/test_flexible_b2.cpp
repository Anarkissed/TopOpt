// C2 batch B2, first part (reviewer's ruling 2026-10-24 19:25): 2(c) flat_cut, 16 squeeze groups,
// 17's RECEIPT per group (built to work under any assembly rule), 26 grams per group. Red first.
//
//  2(c)  mode "flat_cut" on a press with a flat prism: the target at each column is the distance
//        from its entry to the plane along the press, h − dot(entry − A, d), ≥ 0 (the app's
//        FlexibleFlatPrism.latticeCap formula). No curves.
//  16    "squeeze_groups": [{"faces": [face_region_id, …], "force_n"}]: one force per hand, split
//        over its entries by area (so every entry of a hand sees the same pressure). An entry in a
//        group carries no weight_n; an entry in no group carries its own, as before.
//  17    the receipt's "groups": for each squeeze group (and each loaded entry in none), each
//        column's ACHIEVED depth under its own pressure through the ASSEMBLED field, i.e. the
//        series sum of ε(p; ρ_voxel) along its run, against its target and its design. Shared
//        voxels (owned by another group) are counted.
//  26    grams per squeeze group.

#include "topopt/flexible/data.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"
#include "topopt/flexible/job_block.hpp"
#include "topopt/flexible/run.hpp"
#include "topopt/job.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;
using namespace topopt::flexible;
using flexible_test::box;
namespace fs = std::filesystem;

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

// RE-PINNED (C2 B2b): the current version is pinned in test_flexible_b2b; B2's meaning holds from 6 on.
static_assert(kPressApiVersion >= 6, "B2: the press API version");

static const std::string kDir = std::string(FLEXIBLE_TMP_DIR) + "/flexible_b2_test";

static double num(const std::string& j, const std::string& key, std::size_t from = 0) {
  const std::size_t p = j.find("\"" + key + "\"", from);
  if (p == std::string::npos) return std::nan("");
  return std::atof(j.c_str() + j.find(':', p) + 1);
}

static std::string fr_all(const std::string& more = "") {
  std::string fr;
  for (int f = 0; f < 6; ++f) fr += (f ? "," : "") + std::string("{\"id\":") + std::to_string(100 + f) + ",\"add\":[" + std::to_string(f) + "]}";
  return fr + more;
}

static std::string job(const std::string& faces, const std::string& extra = "", const std::string& more_fr = "",
                       int res = 30) {
  return "{\"model\":\"cube.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"resolution\":" + std::to_string(res) +
         ",\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
         "\"loads\":{\"face_regions\":[" + fr_all(more_fr) + "]},"
         "\"flexible\":{\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":220,\"topology\":\"gyroid\","
         "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42" + extra +
         ",\"faces\":" + faces + "}}";
}

static std::string face(int id, const std::string& weight = ",\"weight_n\":100", double deep = 3) {
  char d[32];
  std::snprintf(d, sizeof(d), "%g", deep);
  return "{\"face_region_id\":" + std::to_string(id) + weight + ",\"role\":\"loaded\",\"deepest_squish_mm\":" + d +
         ",\"mode\":\"both\",\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}";
}

static FlexibleRunResult run(const std::string& name, const std::string& text, double L = 60, double W = 60,
                             double H = 60) {
  const std::string dir = kDir + "/" + name;
  fs::create_directories(dir);
  write_stl_file(dir + "/cube.stl", box(L, W, H).mesh);
  return run_flexible_job(parse_job(text), dir, dir + "/out", FLEXIBLE_MATERIALS_JSON_PATH,
                          FlexibleProvenance{"test", "test", "now"});
}

static bool parse_refused(const std::string& text, const std::string& needle) {
  try {
    parse_job(text);
  } catch (const JobError& e) {
    if (std::string(e.what()).find(needle) != std::string::npos) return true;
    std::fprintf(stderr, "  (refused, but: %s)\n", e.what());
    return false;
  }
  std::fprintf(stderr, "  (accepted)\n");
  return false;
}

// ── 2(c): flat_cut ─────────────────────────────────────────────────────────────────
static void test_flat_cut() {
  // the +X/top edge of a 60 cube, pressed along (−1, 0, −1)/√2 with a flat prism 6 mm past (60, 0, 60)
  const double c = 60.0 - 6.0 * std::sqrt(2.0);
  char cut[400];
  std::snprintf(cut, sizeof(cut),
                ",{\"id\":201,\"add\":[1],\"cuts\":[{\"point\":[%.17g,0,0],\"normal\":[1,0,0]}]},"
                "{\"id\":203,\"add\":[3],\"cuts\":[{\"point\":[0,0,%.17g],\"normal\":[0,0,1]}]}",
                c, c);
  const std::string press =
      "{\"face_region_ids\":[201,203],\"press_direction\":[-1,0,-1],\"flat_prism\":{\"apex_mm\":[60,0,60]},"
      "\"role\":\"loaded\",\"weight_n\":60,\"deepest_squish_mm\":6,\"mode\":\"flat_cut\",\"skin_on\":true}";
  const FlexibleRunResult r = run("flat_cut", job("[" + press + "]", "", cut));
  CHECK(!r.refused, "2(c): a flat_cut press runs");
  if (r.refused) std::fprintf(stderr, "  (%s: %s)\n", r.refusal_code.c_str(), r.refusal_reason.c_str());
  const Stack* s = r.stacks.empty() ? nullptr : &r.stacks[0];
  double worst = -1.0;
  int n = 0;
  if (s != nullptr) {
    SquishMap m;
    m.mode = "flat_cut";
    m.deepest_squish_mm = 6;
    const std::vector<double> S = squish_fraction(*s, m);
    worst = 0.0;
    for (std::size_t k = 0; k < s->columns.size(); ++k) {
      const StackColumn& col = s->columns[k];
      const Vec3 o = s->frame.from_uv(col.u_mm, col.v_mm);
      const Vec3 e{o.x + s->frame.load.x * col.entry_t, o.y + s->frame.load.y * col.entry_t,
                   o.z + s->frame.load.z * col.entry_t};
      const double height = (e.x - 60) * s->frame.load.x + (e.y - 0) * s->frame.load.y + (e.z - 60) * s->frame.load.z;
      const double want = std::max(0.0, 6.0 - height);
      worst = std::max(worst, std::fabs(S[k] * 6.0 - want));
      ++n;
    }
  }
  std::printf("  flat_cut: %d columns, worst |target - (h - height)| = %.3g mm\n", n, worst);
  CHECK(n > 0 && worst >= 0 && worst < 1e-9, "2(c): each column's target is the distance from its entry to the plane");
  const std::string no_prism =
      "{\"face_region_id\":101,\"press_direction\":[0,0,-1],\"role\":\"loaded\",\"weight_n\":60,\"deepest_squish_mm\":6,"
      "\"mode\":\"flat_cut\",\"skin_on\":true}";
  CHECK(parse_refused(job("[" + no_prism + "]"), "flat_cut"), "2(c): flat_cut without a flat prism is refused, naming it");
}

// ── 16 + 17 + 26: squeeze groups, the per-group receipt, group grams ───────────────
static void test_groups() {
  // 16: the top and the +X face in ONE hand of 300 N: split by area (3,600 mm2 each): 150 N each,
  // the same pressure on both.
  const std::string grouped = job("[" + face(101, "") + "," + face(103, "") + "]",
                                  ",\"squeeze_groups\":[{\"faces\":[101,103],\"force_n\":300}]");
  const FlexibleRunResult g = run("group", grouped);
  CHECK(!g.refused, "16: a squeeze group of two faces runs");
  if (g.refused) std::fprintf(stderr, "  (%s: %s)\n", g.refusal_code.c_str(), g.refusal_reason.c_str());
  const std::size_t sg = g.receipt_json.find("\"squeeze_groups\": [");
  const double f101 = num(g.receipt_json, "face_101_n", sg), f103 = num(g.receipt_json, "face_103_n", sg);
  std::printf("  group split: face 101 %.6f N, face 103 %.6f N\n", f101, f103);
  CHECK(sg != std::string::npos && std::fabs(f101 - 150) < 1e-9 && std::fabs(f103 - 150) < 1e-9,
        "16: the hand's 300 N splits by area: 150 N each");
  CHECK(parse_refused(job("[" + face(101) + "," + face(103, "") + "]", ",\"squeeze_groups\":[{\"faces\":[101,103],\"force_n\":300}]"),
                      "weight_n"),
        "16: an entry in a squeeze group may not state its own weight_n");
  CHECK(parse_refused(job("[" + face(101, "") + "]"), "weight_n"), "16: an entry in no group must state weight_n");
  CHECK(parse_refused(job("[" + face(101, "") + "," + face(103, "") + "]",
                          ",\"squeeze_groups\":[{\"faces\":[101],\"force_n\":100},{\"faces\":[101,103],\"force_n\":100}]"),
                      "101"),
        "16: an entry in two groups is refused, naming it");
  CHECK(parse_refused(job("[" + face(101, "") + "]", ",\"squeeze_groups\":[{\"faces\":[101,104],\"force_n\":100}]"),
                      "104"),
        "16: a group naming a face that is not a loaded entry is refused, naming it");

  // 17: two SEPARATE groups crossing at 90 degrees (the top, the +X side), today's assembly.
  // The CONTROL: the top alone; each column's achieved depth equals its design (one owner).
  const FlexibleRunResult alone = run("alone", job("[" + face(101) + "]"));
  const std::size_t ga = alone.receipt_json.find("\"groups\": [");
  const double alone_dev = num(alone.receipt_json, "max_achieved_vs_design_mm", ga);
  std::printf("  17 control (top alone): max |achieved - design| %.3g mm\n", alone_dev);
  CHECK(ga != std::string::npos && alone_dev < 1e-9, "17: a group alone achieves its own design exactly");
  const FlexibleRunResult two =
      run("two", job("[" + face(101, "", 3) + "," + face(103, "", 3) + "]",
                     ",\"squeeze_groups\":[{\"faces\":[101],\"force_n\":100},{\"faces\":[103],\"force_n\":400}]"));
  const std::size_t gt = two.receipt_json.find("\"groups\": [");
  const double two_dev = num(two.receipt_json, "max_achieved_vs_design_mm", gt);
  const double shared = num(two.receipt_json, "shared_voxels", gt);
  std::printf("  17 two groups: group 1 max |achieved - design| %.4f mm, %g voxels on its runs owned by another group\n",
              two_dev, shared);
  CHECK(gt != std::string::npos && two_dev > 1e-3 && shared > 0,
        "17: under today's assembly the crossing group's achieved depth departs from its design, and the receipt says so");
  CHECK(two.receipt_json.find("\"assembly\": \"nearest_face\"") != std::string::npos &&
            two.receipt_json.find("\"tolerance_mm\"") != std::string::npos,
        "17: the receipt names the assembly rule and the tolerance it judged by");

  // 26: grams per group, summing to the total.
  const std::size_t gg = two.receipt_json.find("\"by_group\": {");
  const double g1 = num(two.receipt_json, "group_1_g", gg), g2 = num(two.receipt_json, "group_2_g", gg);
  const double tot = num(two.receipt_json, "total_g", two.receipt_json.find("\"grams\": {"));
  std::printf("  26 group grams: %.3f + %.3f of %.3f\n", g1, g2, tot);
  CHECK(gg != std::string::npos && g1 > 0 && g2 > 0 && std::fabs(g1 + g2 - tot) < 1e-6 * tot,
        "26: grams per squeeze group, summing to the total");
}

// ── 9(a): THE PINCH, the app's rule (FlexiblePinch.swift): two loaded entries of ONE hand on one
// axis with OPPOSITE arrows. A column is pinched when its midpoint (entry → exit) lies in the
// partner's stack; each face designs a pinched column over HALF its run (segmentShare 0.5);
// the field meets at the middle by the existing nearest-face handover. One hand → one pressure
// on both ends (force balance). Opposite arrows in DIFFERENT hands stay refused (separate
// squeezes: the combination, B2b); the same arrow on one axis (a step) stays refused.
static void test_pinch() {
  // a 100 x 60 x 40 block: the -X face (105) and the +X face (103) in one 200 N hand
  const std::string pinch = job("[" + face(103, "", 2) + "," + face(105, "", 2) + "]",
                                ",\"squeeze_groups\":[{\"faces\":[103,105],\"force_n\":200}]");
  FlexibleRunResult r;
  bool threw = false;
  try {
    r = run("pinch", pinch, 100, 60, 40);
  } catch (const std::exception& e) {
    threw = true;
    std::fprintf(stderr, "  (threw: %s)\n", e.what());
  }
  CHECK(!threw && !r.refused, "9(a): two faces of ONE hand with opposite arrows: a pinch, accepted");
  if (r.refused) std::fprintf(stderr, "  (%s: %s)\n", r.refusal_code.c_str(), r.refusal_reason.c_str());
  CHECK(r.receipt_json.find("\"pinches\": [{\"face_a\": 103, \"face_b\": 105") != std::string::npos,
        "9(a): the receipt lists the pinch");
  const std::size_t f3 = r.receipt_json.find("\"face_region_id\": 103"), f5 = r.receipt_json.find("\"face_region_id\": 105");
  const double p3 = num(r.receipt_json, "pinched_columns", f3), p5 = num(r.receipt_json, "pinched_columns", f5);
  const double c3 = num(r.receipt_json, "columns", r.receipt_json.find("\"stack\": {", f3));
  std::printf("  pinch: face 103 %g of %g columns pinched, face 105 %g\n", p3, c3, p5);
  CHECK(p3 > 0 && p3 == c3 && p5 == p3, "9(a): every column of each face is pinched, counted per face (per half)");
  // each face designs over HALF the run: its design height is half the 100 mm column
  double h_worst = 0.0;
  if (r.stacks.size() == 2) {
    const Stack& st = r.stacks[0];
    for (const StackColumn& c : st.columns) h_worst = std::max(h_worst, std::fabs(c.lattice_mm - 100.0));
  }
  const double dh = num(r.receipt_json, "design_height_mm", f3);
  std::printf("  pinch: run %.3f mm off 100 at worst, design height %.3f mm\n", h_worst, dh);
  CHECK(std::fabs(dh - 50.0) < 1e-6, "9(a): a pinched face designs over half its run (segmentShare 0.5)");
  // the same faces in DIFFERENT hands: refused (separate squeezes; the combination is B2b)
  const FlexibleRunResult x = run("pinch_x", job("[" + face(103, "", 2) + "," + face(105, "", 2) + "]",
                                                 ",\"squeeze_groups\":[{\"faces\":[103],\"force_n\":100},{\"faces\":[105],\"force_n\":100}]"),
                                  100, 60, 40);
  // RE-PINNED (C2 B2b, his ruling on item 17): opposite arrows in DIFFERENT hands are separate load
  // cases and go to the combination (they were refused until it existed). Equal 2 mm targets at
  // equal force on one column are reachable, so the pair runs.
  CHECK(!x.refused, "9(a)/B2b: opposite arrows in different hands go to the combination (reachable here)");
  if (x.refused) std::fprintf(stderr, "  (%s: %s)\n", x.refusal_code.c_str(), x.refusal_reason.c_str());
  // a STEP (the same arrow on one axis): the top and an angled top press 10 degrees off, one hand
  const std::string step = job("[" + face(101, "", 2) +
                                   ",{\"face_region_id\":104,\"press_direction\":[0,0.17,-1],\"role\":\"loaded\","
                                   "\"deepest_squish_mm\":2,\"mode\":\"both\",\"curve_x\":[[0,1],[1,1]],"
                                   "\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}]",
                               ",\"squeeze_groups\":[{\"faces\":[101,104],\"force_n\":100}]");
  bool step_refused = false;
  try {
    const FlexibleRunResult s = run("step", step, 60, 60, 60);
    step_refused = s.refused && (s.refusal_code == "one_profile_per_stack" || s.refusal_code == "press_stack_failed");
  } catch (const std::exception&) {
  }
  CHECK(step_refused, "9(a): the same arrow on one axis (a step) stays refused");
}

// ── 19: Auto over each face's REAL span ─────────────────────────────────────────────
static void test_auto_span() {
  // The pinched block in one hand: Auto's candidates score each face over its half. The
  // receipt's recommendation scores the same columns as the design (series in recommend).
  const FlexibleRunResult r = run("pinch_auto", job("[" + face(103, "", 2) + "," + face(105, "", 2) + "]",
                                                    ",\"squeeze_groups\":[{\"faces\":[103,105],\"force_n\":200}]")
                                                    .replace(job("[]").find("\"gyroid\""), 8, "\"auto\""),
                                  100, 60, 40);
  CHECK(!r.refused && r.receipt_json.find("\"scored_over\": \"each face's own span (pinched halves, prism segments)\"") !=
                          std::string::npos,
        "19: Auto scores each face over its own span, and the receipt says so");
}

// ── B2c ruling (2026-10-24 21:35): flat_cut's zero line. Where a flat_cut target is under one
// bead, the column takes the densest tested lattice and is labelled the press's rim, never
// too_soft. On the representative press of B2 part 2 (his pad, the Top/-Y edge at 45 degrees,
// 3 mm): 192 of 576 columns read too_soft before.
static void test_flat_cut_rim() {
  const std::string dir = std::string(FLEXIBLE_FIXTURE_DIR) + "/his_pad_1021";
  const double c = 3.0 * std::sqrt(2.0);
  char cut[400];
  std::snprintf(cut, sizeof(cut),
                ",{\"id\":201,\"add\":[1],\"cuts\":[{\"point\":[0,%.17g,0],\"normal\":[0,-1,0]}]},"
                "{\"id\":202,\"add\":[2],\"cuts\":[{\"point\":[0,0,%.17g],\"normal\":[0,0,1]}]}",
                c, 20.0 - c);
  const std::string press =
      "{\"face_region_ids\":[201,202],\"press_direction\":[0,1,-1],\"flat_prism\":{\"apex_mm\":[0,0,20]},"
      "\"mode\":\"flat_cut\",\"role\":\"loaded\",\"weight_n\":30,\"deepest_squish_mm\":3,\"skin_on\":true}";
  std::string fr;
  for (int f = 0; f < 6; ++f) fr += (f ? "," : "") + std::string("{\"id\":") + std::to_string(100 + f) + ",\"add\":[" + std::to_string(f) + "]}";
  const std::string j =
      "{\"model\":\"model.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"resolution\":96,"
      "\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
      "\"loads\":{\"face_regions\":[" + fr + cut + "]},"
      "\"flexible\":{\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":240,\"topology\":\"gyroid\","
      "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42,\"faces\":[" + press + "]}}";
  const FlexibleRunResult r = run_flexible_job(parse_job(j), dir, kDir + "/flat_cut_rim", FLEXIBLE_MATERIALS_JSON_PATH,
                                               FlexibleProvenance{"test", "test", "now"});
  const std::size_t cs = r.receipt_json.find("\"columns_by_status\"");
  const double rim = num(r.receipt_json, "rim", cs), soft = num(r.receipt_json, "too_soft", cs);
  std::printf("  flat_cut rim: rim %g, too_soft %g\n", rim, soft);
  CHECK(!r.refused && rim > 0, "B2c: flat_cut columns with a target under one bead are the press's rim");
  // before the ruling 192 columns read too_soft; exactly the under-one-bead ones moved to rim, and
  // the rest (targets above one bead that even the firmest lattice overshoots) stay too_soft, said
  CHECK(rim + soft == 192, "B2c: the 192 too-soft columns split into rim (under one bead) and too_soft (above it)");
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::error_code ec;
  fs::remove_all(kDir, ec);
  test_flat_cut();
  test_groups();
  test_pinch();
  test_auto_span();
  test_flat_cut_rim();
  std::printf("test_flexible_b2: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
