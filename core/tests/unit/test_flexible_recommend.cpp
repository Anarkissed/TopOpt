// F9 of task 2026-09-28-flexible-squish-maths: the Auto recommender — eligibility
// (R6), reachability per family and tested temperature, the feel preference, the
// tiebreaks, and the "nothing reachable" answer.

#include "topopt/flexible/recommend.hpp"

#include <cstdio>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;
using namespace topopt::flexible;
using flexible_test::box;
using flexible_test::one_region_per_face;
using flexible_test::region;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static const FlexibleData& data() {
  static FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  return d;
}

static bool has(const Recommendation& r, const std::string& code) {
  for (const Reason& x : r.reasons)
    if (x.code == code) return true;
  return false;
}

static SquishMap flat(double d) {
  SquishMap m;
  m.mode = "both";
  m.x_x = m.y_x = {0, 1};
  m.x_y = m.y_y = {1, 1};
  m.deepest_squish_mm = d;
  return m;
}

static std::vector<char> all_solid(const VoxelGrid& g) {
  std::vector<char> m(g.voxel_count(), 0);
  for (std::size_t i = 0; i < g.tags.size(); ++i) m[i] = g.tags[i] != VoxelTag::Empty;
  return m;
}

int main() {
  const StepModel m = box(100, 100, 20);
  const VoxelGrid g = voxelize(m.mesh, 50);
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  const std::vector<char> lat = all_solid(g);
  const Stack top = build_stack(m, region(rs, 101), rs, g, lat, 0, {0, 0, 1}, 2.0);
  const Stack side = build_stack(m, region(rs, 103), rs, g, lat, 0, {0, 0, 1}, 2.0);
  const double W = 30 * 9.81;
  const std::vector<std::string> both{"gyroid", "honeycomb"};

  // 0.6 mm under 30 kg on the top: both families reach it at 220 °C (gyroid spans
  // 0.35..4.35 mm here, honeycomb 0.23..0.92 mm).
  FaceRequest f{&top, flat(0.6), W, nullptr};
  Recommendation r = recommend(data(), "varioshore_tpu", {220}, both, "springy", 1, 0.42, {f});
  CHECK(r.chosen && r.reachable && r.topology == "gyroid", "springy -> gyroid when both reach");
  CHECK(has(r, "feel_springy_prefers_gyroid"), "the feel is the stated reason");
  CHECK(r.candidates.size() == 2 && r.candidates[0].reachable && r.candidates[1].reachable,
        "both candidates reported reachable");
  CHECK(!r.sentence.empty(), "a one-line reason");
  r = recommend(data(), "varioshore_tpu", {220}, both, "damped", 1, 0.42, {f});
  CHECK(r.reachable && r.topology == "honeycomb" && has(r, "feel_damped_prefers_honeycomb"),
        "damped -> honeycomb when both reach");

  // 3 mm under 30 kg: honeycomb cannot go that soft; damped still gets gyroid.
  f.map = flat(3.0);
  r = recommend(data(), "varioshore_tpu", {220}, both, "damped", 1, 0.42, {f});
  CHECK(r.reachable && r.topology == "gyroid", "only gyroid reaches 3 mm");
  CHECK(has(r, "only_family_reachable"), "... and the reason says the preferred one cannot");
  bool honey_fails = false;
  for (const Candidate& c : r.candidates)
    if (c.topology == "honeycomb")
      honey_fails = !c.reachable && !c.failures.empty() && c.failures[0].too_firm > 0 &&
                    c.failures[0].face_region_id == 101 && c.failures[0].nearest_known &&
                    !c.failures[0].text.empty();
  CHECK(honey_fails, "honeycomb's failure names the face, the kind and the nearest squish");

  // A side stack: honeycomb is not eligible at all (R6).
  FaceRequest fs{&side, flat(10.0), 25 * 9.81, nullptr};
  r = recommend(data(), "varioshore_tpu", {220}, both, "damped", 1, 0.42, {f, fs});
  bool honey_inel = false;
  for (const Candidate& c : r.candidates)
    if (c.topology == "honeycomb") honey_inel = !c.eligible && c.refusal.code == "honeycomb_side_stack";
  CHECK(honey_inel, "honeycomb ineligible with a side stack");
  CHECK(has(r, "honeycomb_side_stack") && r.topology == "gyroid", "gyroid, and why");

  // Temperatures: 3 mm is too firm for every 190 °C gyroid; 220 and 240 reach it.
  r = recommend(data(), "varioshore_tpu", {190, 220, 240}, {"gyroid"}, "springy", 1, 0.42, {f});
  CHECK(r.reachable && (r.temp_c == 220 || r.temp_c == 240), "a reachable temperature is chosen");
  bool t190 = false;
  for (const Candidate& c : r.candidates)
    if (c.temp_c == 190) t190 = !c.reachable && !c.failures.empty();
  CHECK(t190, "190 °C reported unreachable with its failure");
  CHECK(has(r, "tiebreak_near_edge") || has(r, "tiebreak_material") || has(r, "tiebreak_inside_data"),
        "the temperature was settled by a named tiebreak");

  // Nothing reachable: 8 mm of 20 is past the tested strain for everything.
  f.map = flat(8.0);
  r = recommend(data(), "varioshore_tpu", {220}, both, "springy", 1, 0.42, {f});
  CHECK(r.chosen && !r.reachable && has(r, "nothing_reachable"), "nothing reachable, said so");
  CHECK(!r.failures.empty() && r.failures[0].face_region_id == 101 &&
            r.failures[0].beyond_data > 0,
        "the failure names the face and says it is beyond the data");

  // A material with no data predicts nothing.
  r = recommend(data(), "tpu95a_generic", {220}, both, "springy", 1, 0.42, {f});
  CHECK(!r.chosen && has(r, "calibrate_first"), "calibrate_first: no recommendation, a reason");

  bool threw = false;
  try {
    recommend(data(), "varioshore_tpu", {220}, both, "bouncy", 1, 0.42, {f});
  } catch (const FlexibleError&) {
    threw = true;
  }
  CHECK(threw, "an unknown feel is refused");

  std::printf("test_flexible_recommend: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
