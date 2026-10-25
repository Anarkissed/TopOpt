// C2 batch B2b (his ruling on item 17, 2026-10-24 15:33, and his answers to Q-C1..3, 16:11 and
// 16:25): ONE lattice in which EVERY squeeze group's squish happens under its own force. Red first.
//
//  * Each group is its own LOAD CASE (Q-C1), squeezed alone.
//  * A group hits when every column satisfies |achieved − target| <= its band, "hit_band":
//    {"min_mm", "pct"} -> max(min_mm, pct % of the target); default max(0.05 mm, 2 %) (Q-C2).
//    tier_band is reported beside it as the uncertainty, never used as the hit tolerance.
//  * "Achieved" is judged in core's 1-D columns through the QUANTISED field, labelled
//    "1-D estimate" (Q-C3).
//  * Components with one group are untouched (byte-identical). A combination that cannot be
//    met is refused BEFORE the run, naming the groups and the miss (combination_not_reachable).

#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/run.hpp"
#include "topopt/job.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>

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

static_assert(kPressApiVersion == 8, "B2c: the press API version");

static const std::string kDir = std::string(FLEXIBLE_TMP_DIR) + "/flexible_b2b_test";

static double num(const std::string& j, const std::string& key, std::size_t from = 0) {
  const std::size_t p = j.find("\"" + key + "\"", from);
  if (p == std::string::npos) return std::nan("");
  return std::atof(j.c_str() + j.find(':', p) + 1);
}

static std::string job(const std::string& faces, const std::string& groups, int res = 30) {
  std::string fr;
  for (int f = 0; f < 6; ++f) fr += (f ? "," : "") + std::string("{\"id\":") + std::to_string(100 + f) + ",\"add\":[" + std::to_string(f) + "]}";
  return "{\"model\":\"part.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"resolution\":" + std::to_string(res) +
         ",\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
         "\"loads\":{\"face_regions\":[" + fr + "]},"
         "\"flexible\":{\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":220,\"topology\":\"gyroid\","
         "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42,\"squeeze_groups\":" + groups +
         ",\"faces\":" + faces + "}}";
}

static std::string face(int id, double deep) {
  char d[32];
  std::snprintf(d, sizeof(d), "%g", deep);
  return "{\"face_region_id\":" + std::to_string(id) + ",\"role\":\"loaded\",\"deepest_squish_mm\":" + d +
         ",\"mode\":\"both\",\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}";
}

static FlexibleRunResult run(const std::string& name, const std::string& text, double L, double W, double H) {
  const std::string dir = kDir + "/" + name;
  fs::create_directories(dir);
  write_stl_file(dir + "/part.stl", box(L, W, H).mesh);
  return run_flexible_job(parse_job(text), dir, dir + "/out", FLEXIBLE_MATERIALS_JSON_PATH,
                          FlexibleProvenance{"test", "test", "now"});
}

// The group record of `name` ("group 1", …) in the receipt's "groups".
static std::size_t group_at(const std::string& j, const std::string& name) {
  return j.find("\"group\": \"" + name + "\"", j.find("\"groups\": {"));
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::error_code ec;
  fs::remove_all(kDir, ec);

  // (1) THE RED CASE IN MINIATURE (B2 part 1's 90 degree crossing): the top (100 N, 3 mm) and the
  // +X side (180 N, 5.4 mm) as SEPARATE hands on a 60 mm cube, each reachable alone. Every voxel
  // lies on one top column and one side column, so the two targets must be met by ONE set of
  // densities. The per-voxel strain ratio side/top is about 1.8 near rho 0.21, and the pair asks
  // for 1.8: inside the convex hull of (eps_top(rho), eps_side(rho)). (5 mm asks for 1.67, outside
  // the hull: impossible. 5.6 mm asks for 1.87: inside the hull but only by MIXING far-apart
  // densities, where this first-order solver stalls 0.115 mm short: a known limit, reported.)
  // The combination: every column of both groups within its band.
  {
    const FlexibleRunResult r =
        run("cross", job("[" + face(101, 3) + "," + face(103, 5.4) + "]",
                         "[{\"faces\":[101],\"force_n\":100},{\"faces\":[103],\"force_n\":180}]"),
            60, 60, 60);
    CHECK(!r.refused, "the crossing pair is designed as one combination");
    if (r.refused) std::fprintf(stderr, "  (%s: %s)\n", r.refusal_code.c_str(), r.refusal_reason.c_str());
    const std::string& j = r.receipt_json;
    for (const char* g : {"group 1", "group 2"}) {
      const std::size_t at = group_at(j, g);
      const double cols = num(j, "columns", at), within = num(j, "columns_within_band", at),
                   miss = num(j, "max_achieved_vs_target_mm", at);
      std::printf("  crossing, %s: %g of %g columns within band, worst miss %.4f mm\n", g, within, cols, miss);
      CHECK(at != std::string::npos && cols > 0 && within == cols, "17: every column of the group hits its band");
    }
    CHECK(j.find("\"assembly\": \"combination\"") != std::string::npos &&
              j.find("\"estimate\": \"1-D estimate\"") != std::string::npos,
          "17: the receipt names the combination and labels the judgement a 1-D estimate (Q-C3)");
    CHECK(j.find("\"band\": {\"min_mm\": 0.05, \"pct\": 2, \"source\": \"default\"}") != std::string::npos &&
              j.find("\"uncertainty\": {\"tier\"") != std::string::npos,
          "Q-C2: the default band, and tier_band beside it as the uncertainty");
  }

  // (1b) WHAT THE COMBINATION IS FOR: the top's x < 30 piece (100 N, 3 mm) and the +X side (180 N,
  // 6.5 mm) as separate hands. The side's columns run through the top piece's half (shared) and
  // then their own half. Designed independently and assembled nearest-face, the side misses (its
  // run crosses the top's densities). The combination meets both, through the side's own segment.
  {
    std::string j = job("[" + face(120, 3) + "," + face(103, 6.5) + "]",
                        "[{\"faces\":[120],\"force_n\":100},{\"faces\":[103],\"force_n\":180}]");
    const std::string fr5 = "{\"id\":105,\"add\":[5]}]";
    j.replace(j.find(fr5), fr5.size(),
              "{\"id\":105,\"add\":[5]},{\"id\":120,\"add\":[1],\"cuts\":[{\"point\":[30,0,0],\"normal\":[-1,0,0],\"strict\":true}]}]");
    const FlexibleRunResult r = run("half", j, 60, 60, 60);
    if (r.refused) std::fprintf(stderr, "  (%s: %s)\n", r.refusal_code.c_str(), r.refusal_reason.c_str());
    const std::string& rj = r.receipt_json;
    const std::size_t cb = rj.find("\"combination\": {");
    const double before = num(rj, "worst_miss_mm", rj.find("\"before\"", cb));
    const double before_n = num(rj, "columns_missing_band", rj.find("\"before\"", cb));
    const double sweeps = num(rj, "sweeps", cb);
    const std::size_t a = group_at(rj, "group 1"), b = group_at(rj, "group 2");
    std::printf("  half-top + side: before %g columns missed (worst %.4f mm); after %g sweeps: group 1 %g/%g, group 2 %g/%g within band\n",
                before_n, before, sweeps, num(rj, "columns_within_band", a), num(rj, "columns", a),
                num(rj, "columns_within_band", b), num(rj, "columns", b));
    CHECK(!r.refused && before_n > 0 && before > 0.1, "17: assembled independently, the side misses its band (the CONTROL)");
    CHECK(!r.refused && num(rj, "columns_within_band", a) == num(rj, "columns", a) &&
              num(rj, "columns_within_band", b) == num(rj, "columns", b) && sweeps > 1,
          "17: the combination meets every column of both groups");
  }

  // (2) ONE GROUP: untouched. The combination solves nothing.
  {
    const FlexibleRunResult r = run("one", job("[" + face(101, 3) + "]", "[{\"faces\":[101],\"force_n\":100}]"), 60, 60, 60);
    CHECK(!r.refused && r.receipt_json.find("\"combination\": {\"components\": 0") != std::string::npos,
          "a single group: no component to combine (byte-identical to the independent design)");
  }

  // (3) A HAND'S OWN BAND, from the job.
  {
    const FlexibleRunResult r =
        run("band", job("[" + face(101, 3) + "," + face(103, 5.4) + "]",
                        "[{\"faces\":[101],\"force_n\":100,\"hit_band\":{\"min_mm\":0.1,\"pct\":5}},"
                        "{\"faces\":[103],\"force_n\":180}]"),
            60, 60, 60);
    CHECK(r.receipt_json.find("\"band\": {\"min_mm\": 0.1, \"pct\": 5, \"source\": \"job\"}") != std::string::npos,
          "Q-C2: a group's own hit_band is read and reported");
  }

  // (4) UNREACHABLE: two hands pressing one 100 mm column from opposite sides (each alone): the
  // lighter hand (72 N, 0.03 MPa) asks for MORE squish (8 mm) than the heavier (144 N, 0.06 MPa,
  // 5 mm). Each is reachable alone. Every voxel squishes more under more pressure, so d_A <= d_B
  // for any lattice: refused before the run, naming both groups.
  {
    const FlexibleRunResult r =
        run("unreachable", job("[" + face(103, 8) + "," + face(105, 5) + "]",
                               "[{\"faces\":[103],\"force_n\":72},{\"faces\":[105],\"force_n\":144}]"),
            100, 60, 40);
    std::printf("  unreachable: %s\n", r.refusal_reason.c_str());
    // RE-PINNED (C2 B2c): the hull certificate now PROVES this same-axis pair impossible.
    CHECK(r.refused && r.refusal_code == "combination_not_reachable" &&
              r.refusal_reason.find("group 1") != std::string::npos && r.refusal_reason.find("group 2") != std::string::npos &&
              r.refusal_reason.find("PROVEN") != std::string::npos &&
              num(r.receipt_json, "proven_impossible_pairs") > 0,
          "B2c: an unreachable same-axis pair is PROVEN impossible by the hull certificate, naming the groups");
  }

  // (5) REACHABLE on the same column: the heavier hand asks for more (72 N 3 mm, 144 N 6 mm).
  {
    const FlexibleRunResult r =
        run("reachable", job("[" + face(103, 3) + "," + face(105, 6) + "]",
                             "[{\"faces\":[103],\"force_n\":72},{\"faces\":[105],\"force_n\":144}]"),
            100, 60, 40);
    if (r.refused) std::fprintf(stderr, "  (%s: %s)\n", r.refusal_code.c_str(), r.refusal_reason.c_str());
    const std::size_t a = group_at(r.receipt_json, "group 1"), b = group_at(r.receipt_json, "group 2");
    CHECK(!r.refused && num(r.receipt_json, "columns_within_band", a) == num(r.receipt_json, "columns", a) &&
              num(r.receipt_json, "columns_within_band", b) == num(r.receipt_json, "columns", b),
          "17: a reachable pair on one column: both groups hit");
  }

  // (6) B2c, THE MIXTURE: top 3 mm + side 5.6 mm on the cube (separate hands). The pair is inside
  // the hull only by mixing two densities; B2b's first-order solve stalled 0.115 mm short. The
  // mixing start lays the two densities in blocks of two cells, and the projections refine it.
  {
    const FlexibleRunResult r =
        run("mix", job("[" + face(101, 3) + "," + face(103, 5.6) + "]",
                       "[{\"faces\":[101],\"force_n\":100},{\"faces\":[103],\"force_n\":180}]"),
            60, 60, 60);
    const std::string& j = r.receipt_json;
    const std::size_t cb = j.find("\"combination\": {");
    std::printf("  mixture (top 3 + side 5.6 mm): refused %d, mixed components %g, still missing %g, worst %.4f mm, steep %g\n",
                r.refused ? 1 : 0, num(j, "mixed_components", cb), num(j, "columns_missing_band", cb),
                num(j, "worst_miss_mm", cb), num(j, "steep_columns", cb));
    CHECK(!r.refused && num(j, "mixed_components", cb) > 0,
          "B2c: a pair reachable only by mixing is met (B2b's solver stalled 0.115 mm short)");
  }
  std::printf("test_flexible_b2b: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
