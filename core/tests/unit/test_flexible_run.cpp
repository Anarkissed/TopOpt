// F12 of task 2026-09-28-flexible-squish-maths: `topopt-cli flexible`'s runner end
// to end on a box STL this test writes — the files, the receipt, every stage
// refusal — and (where the runners are built) that every OTHER entry point refuses a
// job carrying a flexible block instead of silently ignoring it.

#include "topopt/flexible/run.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <sstream>
#include <string>
#include <system_error>

#include "flexible_test_boxes.hpp"
#include "topopt/stl.hpp"

#ifdef TOPOPT_FLEXIBLE_TEST_RUNNERS
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"
#endif

using namespace topopt;
namespace fs = std::filesystem;

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

static std::string read(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream s;
  s << in.rdbuf();
  return s.str();
}

static const std::string kDir = std::string(FLEXIBLE_TMP_DIR) + "/flexible_run_test";

static std::string job(const std::string& material, const std::string& temp, const std::string& topo,
                       const std::string& faces, int stamp_face = 101) {
  return "{\"model\":\"pad.stl\",\"material\":\"" + material + "\",\"mode\":\"analyze\",\"resolution\":50,"
         "\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
         "\"loads\":{\"face_regions\":[{\"id\":100,\"add\":[0]},{\"id\":101,\"add\":[1]},"
         "{\"id\":103,\"add\":[3]}]},"
         "\"flexible\":{\"material_id\":\"" + material + "\",\"nozzle_temp_c\":" + temp +
         ",\"topology\":\"" + topo + "\",\"feel\":\"springy\",\"beads_per_wall\":1,"
         "\"min_extrudable_width_mm\":0.42,\"faces\":" + faces + ",\"check_stamps\":[{\"face_region_id\":" +
         std::to_string(stamp_face) + ","
         "\"name\":\"sq\",\"mode\":\"soft\",\"force_n\":8,\"origin_mm\":[30,30],\"cell_mm\":10,\"nu\":2,\"nv\":2,"
         "\"values_mpa\":[0.02,0.02,0.02,0.02]}]}}";
}

static const std::string kTop =
    "{\"face_region_id\":101,\"role\":\"loaded\",\"weight_n\":294.3,\"deepest_squish_mm\":4,"
    "\"mode\":\"both\",\"curve_x\":[[0,0.3],[0.5,1],[1,0.3]],\"curve_y\":[[0,0.3],[0.5,1],[1,0.3]],"
    "\"skin_on\":true}";

static FlexibleRunResult run(const std::string& name, const std::string& text) {
  const std::string dir = kDir + "/" + name;
  fs::create_directories(dir);
  write_stl_file(dir + "/pad.stl", flexible_test::box(100, 100, 20).mesh);
  const JobDescription j = parse_job(text);
  return run_flexible_job(j, dir, dir + "/out", FLEXIBLE_MATERIALS_JSON_PATH,
                          FlexibleProvenance{"test", "test", "now"});
}

int main() {
  std::error_code ec;
  fs::remove_all(kDir, ec);

  // A normal run.
  FlexibleRunResult r = run("pad", job("varioshore_tpu", "220", "auto", "[" + kTop + "]"));
  CHECK(!r.refused, "the pad runs");
  for (const char* f : {"face101_target_depth.svg", "face101_buildable_depth.svg", "face101_density.svg",
                        "face101_cell_size.svg", "face101_tier_flags.svg", "face101_columns.csv",
                        "check_sq_face101.svg", "check_sq_face101.csv", "field_xz_density.svg",
                        "field_xz_owner.svg", "run_info.json"})
    CHECK(fs::exists(kDir + "/pad/out/" + f), (std::string("wrote ") + f).c_str());
  const std::string ri = read(kDir + "/pad/out/run_info.json");
  CHECK(ri.find("\"flexible\": {\"stage\": \"flexible\"") != std::string::npos,
        "run_info.json carries the flexible receipt");
  CHECK(ri.find("\"mode\": \"flexible\"") != std::string::npos, "run_info mode is flexible");
  for (const char* k : {"\"density_basis\": \"estimated_core (190", "\"strain_convention\"",
                        "\"bead_width_key\": \"min_extrudable_width_mm\"", "\"tier\": \"literature\"",
                        "\"band\": 0.4", "\"linked_faces\": [{\"face_id\": 0, \"area_fraction\": 1}]",
                        "\"recommendation\"", "\"clamped_columns\"", "\"handover\"", "\"buildable_smoothing\"",
                        "\"not_modelled\""})
    CHECK(ri.find(k) != std::string::npos, (std::string("receipt has ") + k).c_str());
  CHECK(ri.find("certified") == std::string::npos && ri.find("certificate\":") == std::string::npos,
        "no certificate is claimed (R7)");
  CHECK(ri.find("\"accepted\"") == std::string::npos && ri.find("margin") == std::string::npos,
        "no accepted verdict, no margin (R7)");
  const std::string csv = read(kDir + "/pad/out/face101_columns.csv");
  std::size_t lines = 0;
  for (char c : csv) lines += c == '\n';
  CHECK(lines == 1 + 50 * 50, "one CSV row per column");
  const std::string svg = read(kDir + "/pad/out/face101_buildable_depth.svg");
  CHECK(svg.rfind("<svg", 0) == 0 && svg.find("</svg>") != std::string::npos && svg.find("min ") != std::string::npos,
        "an SVG with numbers");

  // Refusals: named, receipt still written, the drawn map still written.
  r = run("stack", job("varioshore_tpu", "220", "auto",
                       "[" + kTop + ",{\"face_region_id\":100,\"role\":\"loaded\",\"weight_n\":100,"
                                    "\"deepest_squish_mm\":2,\"mode\":\"both\",\"curve_x\":[[0,1],[1,1]],"
                                    "\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}]"));
  CHECK(r.refused && r.refusal_code == "one_profile_per_stack" &&
            r.refusal_reason.find("101") != std::string::npos &&
            r.refusal_reason.find("100") != std::string::npos,
        "top + bottom loaded: refused, naming both");
  CHECK(fs::exists(kDir + "/stack/out/run_info.json") && fs::exists(kDir + "/stack/out/face101_target_depth.svg"),
        "a refusal still writes the receipt and the drawn map");
  CHECK(!fs::exists(kDir + "/stack/out/face101_density.svg"), "... and no prediction");
  r = run("cf", job("tpu95a_generic", "220", "auto", "[" + kTop + "]"));
  CHECK(r.refused && r.refusal_code == "calibrate_first", "calibrate_first: no numbers, a reason");
  r = run("temp", job("varioshore_tpu", "205", "auto", "[" + kTop + "]"));
  CHECK(r.refused && r.refusal_code == "temperature_not_tested", "205 C: never interpolated");
  r = run("side", job("varioshore_tpu", "220", "honeycomb",
                      "[{\"face_region_id\":103,\"role\":\"loaded\",\"weight_n\":100,\"deepest_squish_mm\":10,"
                      "\"mode\":\"both\",\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}]",
                      103));
  CHECK(r.refused && r.refusal_code == "honeycomb_side_stack", "honeycomb on a side stack: refused");
  r = run("auto", job("varioshore_tpu", "\"auto\"", "gyroid", "[" + kTop + "]"));
  CHECK(!r.refused && r.receipt_json.find("\"requested\": {\"topology\": \"gyroid\", \"nozzle_temp_c\": \"auto\"}") !=
                          std::string::npos,
        "temperature auto: chosen among the tested ones, request recorded");

#ifdef TOPOPT_FLEXIBLE_TEST_RUNNERS
  // Every other entry point refuses a flexible job before doing any work.
  const JobDescription fj = parse_job(job("varioshore_tpu", "220", "auto", "[" + kTop + "]"));
  const MaterialLibrary mats;
  const SettingsRules rules{};
  auto refuses = [&](const std::function<void()>& f) {
    try {
      f();
    } catch (const JobError& e) {
      return std::string(e.what()).find("topopt-cli flexible") != std::string::npos;
    } catch (...) {
      return false;
    }
    return false;
  };
  CHECK(refuses([&] { run_job(fj, kDir, kDir + "/x", mats, rules, false, RunObservability{}); }),
        "run_job refuses a flexible job");
  CHECK(refuses([&] { analyze_job(fj, kDir, kDir + "/x", mats, rules, "", SmoothRequest{}); }),
        "analyze_job refuses a flexible job");
  CHECK(refuses([&] { lattice_variant_job(fj, kDir, kDir + "/x", mats, rules); }),
        "lattice_variant_job refuses a flexible job");
  CHECK(refuses([&] { preflight_job(fj, kDir, mats); }), "preflight_job refuses a flexible job");
#endif

  std::printf("test_flexible_run: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
