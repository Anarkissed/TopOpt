// E2.1 (plan.md §B6, his Q11): a lattice on a job with load scenarios is graded from
// the WORST stress over the scenarios it uses and certified under EACH of them.
//
// Before E2.1 the lattice was graded from the governing scenario and certified under
// scenario 1 alone, whichever governed. Measured on this test's bar, with the light
// scenario listed first: the latticed file read margin 138.3 ACCEPTED while its solid
// governed at 8.02 under the heavy one; "Lattice an optimized result" refused the same
// design outright (recorded 4.95, reproduced 77.95); "Lattice the original part"
// re-certified under the light load too.
//
// §1 lattice.scenarios at the parse: names checked, refusals by name.
// §2 the run path: the receipt certifies under both scenarios, the HEAVY one governs,
//    the solid re-certification reproduces the run, and the light scenario's lattice
//    margin (what the old certificate printed) is far above the governing one.
// §3 an analyze job with a grading block: re-certified under each scenario the lattice
//    uses; with lattice.scenarios = ["light down"] the heavy one is left out (the
//    control that the filter works).
// §4 "Lattice an optimized result" (lattice_variant) on §2's stored run: latticed
//    again, not refused, the heavy scenario governing.
// §5 "Lattice the original part" (lattice_part) on a top-face layer: the heavy scenario
//    governs, with a finite margin.
// Every section starts from an empty output folder (a stale receipt once passed §5).
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
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

// A 60 x 20 x 20 mm bar.
TriangleMesh bar() {
  TriangleMesh m;
  const double L = 60.0, W = 20.0, H = 20.0;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
}

int face_with_normal(const StepModel& m, double nx, double ny, double nz) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane) continue;
    if (fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz > 0.99)
      return f;
  }
  return -1;
}

struct Faces { int left = -1, top = -1, right = -1; };

// "light down": 30 N down on the top. "heavy side": 300 N in +y on the free end. Both
// anchored at x = 0. The light one is listed FIRST, which is the case the old
// certificate got wrong.
std::string job_json(const Faces& f, const std::string& mode, const std::string& lattice_extra,
                     const std::string& grading_extra) {
  const std::string anchor = "[" + std::to_string(f.left) + "]";
  const std::string light = "{\"name\": \"light down\", \"groups\": [{\"face_ids\": [" +
                            std::to_string(f.top) + "], \"force\": [0, 0, -30]}], "
                            "\"anchor_face_ids\": " + anchor + "}";
  const std::string heavy = "{\"name\": \"heavy side\", \"groups\": [{\"face_ids\": [" +
                            std::to_string(f.right) + "], \"force\": [0, 300, 0]}], "
                            "\"anchor_face_ids\": " + anchor + "}";
  return "{\"model\": \"lattice_scenarios_bar.stl\", \"material\": \"PLA\", \"mode\": \"" +
         mode + "\", \"resolution\": 24, "
         "\"loads\": {\"minimize_plastic\": false, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": " + anchor + ", \"groups\": [{\"face_ids\": [" +
         std::to_string(f.top) + "], \"force\": [0, 0, -30]}], \"scenarios\": [" + light +
         ", " + heavy + "]}, "
         "\"lattice\": {\"topology\": \"octet\"" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45" + grading_extra + "}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

bool refused_with(const std::string& json, const std::string& words) {
  try {
    (void)parse_job(json);
  } catch (const JobError& e) {
    const bool ok = std::string(e.what()).find(words) != std::string::npos;
    if (!ok) std::printf("  (refused, but with: %s)\n", e.what());
    return ok;
  }
  return false;
}

std::string read_file(const std::string& p) {
  std::ifstream in(p);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// The number after `"key": ` at or after `from` (NaN when absent or null).
double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}

// The lattice margin per_scenario lists for `name`.
double scenario_margin(const std::string& receipt, const std::string& name) {
  const std::size_t k = receipt.find("{\"name\": \"" + name + "\", \"lattice_margin\"");
  return k == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                : num_after(receipt, "lattice_margin", k);
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_scenarios_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_scenarios_bar.stl").model;
  Faces f;
  f.left = face_with_normal(model, -1, 0, 0);
  f.top = face_with_normal(model, 0, 0, 1);
  f.right = face_with_normal(model, 1, 0, 0);
  CHECK(f.left >= 0 && f.top >= 0 && f.right >= 0, "precondition: the bar's three faces");

  // ── §1 the key at the parse ─────────────────────────────────────────────────
  {
    const JobDescription none = parse_job(job_json(f, "minimize_plastic", "", ""));
    CHECK(!none.lattice.scenarios_stated && none.lattice.scenarios.empty(),
          "§1 absent: not stated (the lattice uses every scenario)");
    const JobDescription two = parse_job(job_json(
        f, "minimize_plastic", ", \"scenarios\": [\"heavy side\", \"light down\"]", ""));
    CHECK(two.lattice.scenarios_stated && two.lattice.scenarios.size() == 2 &&
              two.lattice.scenarios[0] == "heavy side",
          "§1 two names parse, in the order given (control)");
    CHECK(refused_with(job_json(f, "minimize_plastic", ", \"scenarios\": [\"sideways\"]", ""),
                       "\"sideways\", which is not one of this job's load scenarios"),
          "§1 a name that is not a scenario is refused, naming it");
    CHECK(refused_with(job_json(f, "minimize_plastic", ", \"scenarios\": []", ""),
                       "\"lattice.scenarios\" is empty"),
          "§1 an empty list is refused");
    CHECK(refused_with(job_json(f, "minimize_plastic",
                                ", \"scenarios\": [\"light down\", \"light down\"]", ""),
                       "names \"light down\" twice"),
          "§1 a name given twice is refused");
    // A job with one load case: the key has nothing to choose from.
    std::string one = job_json(f, "minimize_plastic", ", \"scenarios\": [\"light down\"]", "");
    const std::size_t a = one.find(", \"scenarios\": [{");
    const std::size_t b = one.find("]}, \"lattice\"");
    one.erase(a, b + 1 - a);
    CHECK(refused_with(one, "this job has no load scenarios"),
          "§1 on a job without scenarios the key is refused, saying why");
  }

  // ── §2 the run path ─────────────────────────────────────────────────────────
  {
    const std::string out = dir + "/lattice_scenarios_run";
    std::filesystem::remove_all(out);
    std::ofstream(dir + "/lattice_scenarios_run.json") << job_json(f, "minimize_plastic", "", "");
    const JobDescription job = load_job_file(dir + "/lattice_scenarios_run.json");
    (void)run_job(job, dir, out, materials, rules, false, RunObservability{});
    // The first latticed rung's receipt (rungs are named by their volume fraction).
    std::string first;
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0 &&
          (first.empty() || n > first))
        first = n;
    }
    std::printf("[lattice-scenarios] run: receipt %s\n", first.c_str());
    const std::string r = first.empty() ? std::string() : read_file(out + "/" + first);
    CHECK(!r.empty(), "§2 a rung is latticed (its receipt exists)");
    if (!r.empty()) {
      CHECK(r.find("\"graded_on\": [\"light down\", \"heavy side\"]") != std::string::npos,
            "§2 graded and certified on both scenarios");
      CHECK(r.find("\"governing\": \"heavy side\"") != std::string::npos,
            "§2 the heavy scenario governs the lattice");
      const double light = scenario_margin(r, "light down");
      const double heavy = scenario_margin(r, "heavy side");
      const double lattice = num_after(r, "lattice_margin_effective");
      std::printf("[lattice-scenarios] run: lattice margin %.4f (light %.4f, heavy %.4f)\n",
                  lattice, light, heavy);
      CHECK(std::isfinite(light) && std::isfinite(heavy) && heavy < light,
            "§2 per_scenario: the heavy margin is the lower");
      CHECK(lattice == heavy, "§2 the lattice margin IS the governing scenario's");
      CHECK(light > 5.0 * heavy,
            "§2 control: the light scenario's margin (what the old certificate printed) "
            "is over 5x the governing one");
      CHECK(r.find("\"solid_reconstruction_reproduces\": true") != std::string::npos,
            "§2 the solid re-certification reproduces the run under both scenarios");
      const double s1 = num_after(r, "share", r.find("\"stress_share\""));
      const double s2 = num_after(r, "share", r.find("\"share\"", r.find("\"stress_share\"")) + 1);
      CHECK(std::fabs(s1 + s2 - 1.0) < 1e-9, "§2 the stress shares sum to 1");
    }
  }

  // ── §3 the analyze path ─────────────────────────────────────────────────────
  // It re-certifies its lattice under each scenario the lattice uses. (Its margin is
  // the SOLID region's, and a whole-part lattice leaves none, so it reads infinite here
  // with or without scenarios: a known limit of that path, not checked.)
  for (const bool light_only : {false, true}) {
    const std::string tag = light_only ? "light_only" : "both";
    const std::string out = dir + "/lattice_scenarios_an_" + tag;
    std::filesystem::remove_all(out);
    std::ofstream(dir + "/lattice_scenarios_an.json")
        << job_json(f, "analyze", light_only ? ", \"scenarios\": [\"light down\"]" : "",
                    ", \"intent\": \"structural\"");
    const JobDescription job = load_job_file(dir + "/lattice_scenarios_an.json");
    (void)analyze_job(job, dir, out, materials, rules, "", {});
    const std::string ri = read_file(out + "/run_info.json");
    const std::size_t list = ri.find("\"recertified_scenarios\": [");
    const std::string names = list == std::string::npos ? "" : ri.substr(list, ri.find(']', list) - list);
    const bool has_light = names.find("\"light down\"") != std::string::npos;
    const bool has_heavy = names.find("\"heavy side\"") != std::string::npos;
    if (!light_only)
      CHECK(has_light && has_heavy, "§3 both: re-certified under both scenarios");
    else
      CHECK(has_light && !has_heavy,
            "§3 light only: re-certified under the light scenario, the heavy one left out");
  }

  // ── §4 the lattice-variant path ("Lattice an optimized result") ─────────────
  // §2's stored run, latticed again. Before E2.1 the stored design was re-certified
  // under scenario 1 alone and refused as "not the one that produced this variant".
  {
    const std::string out = dir + "/lattice_scenarios_lv";
    std::filesystem::remove_all(out);
    std::string j = job_json(f, "lattice_variant", "", "");
    j.insert(j.size() - 1, ", \"variant\": {\"design\": \"lattice_scenarios_run/design.bin\", "
                           "\"index\": 0}");
    std::ofstream(dir + "/lattice_scenarios_lv.json") << j;
    bool ok = true;
    std::string why;
    try {
      const JobDescription job = load_job_file(dir + "/lattice_scenarios_lv.json");
      (void)lattice_variant_job(job, dir, out, materials, rules);
    } catch (const std::exception& e) {
      ok = false;
      why = e.what();
      std::printf("  (lattice_variant refused: %s)\n", why.c_str());
    }
    CHECK(ok, "§4 the stored scenario design is latticed again, not refused");
    std::string r;
    if (ok)
      for (const auto& e : std::filesystem::directory_iterator(out)) {
        const std::string n = e.path().filename().string();
        if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
          r = read_file(e.path().string());
      }
    CHECK(r.find("\"governing\": \"heavy side\"") != std::string::npos &&
              r.find("\"solid_reconstruction_reproduces\": true") != std::string::npos,
          "§4 its receipt: the heavy scenario governs and the solid reproduces");
    if (!r.empty())
      std::printf("[lattice-scenarios] lattice-variant: lattice margin %.4f\n",
                  num_after(r, "lattice_margin_effective"));
  }

  // ── §5 the lattice-part path ("Lattice the original part") ──────────────────
  {
    const std::string out = dir + "/lattice_scenarios_lp";
    std::filesystem::remove_all(out);
    // The lattice is a 6 mm layer under the top face, so the rest of the bar is solid and
    // carries the certified margin. (Latticed whole, no voxel is solid: the certificate
    // leaves latticed voxels out of the margin, so every scenario reads infinite and the
    // first listed "governs" on the tie; the receipt flags strut_strength_uncertified.)
    // A latticed layer seals its void inside, and its default diagrid skin finds nothing
    // to dress; both refusals are other tests', so they are off here.
    // Growth off: with it on, lattice_part latticed the whole auto-derived growth box
    // (reported to TO-core, 2026-11-04; fixed in 49048743).
    char top_layer[400];
    std::snprintf(top_layer, sizeof(top_layer),
                  ", \"regions\": [{\"role\": \"include\", \"kind\": \"face\", \"face_id\": %d, "
                  "\"geometry\": {\"origin\": [30, 10, 20], \"normal\": [0, 0, -1], "
                  "\"half_u_mm\": 30, \"half_w_mm\": 10, \"depth_mm\": 6}}]",
                  f.top);
    std::string lp = job_json(f, "lattice_part",
                              ", \"skin\": \"none\", \"require_lattice_void_reaches_exterior\": false" +
                                  std::string(top_layer),
                              "");
    lp.replace(lp.find("\"minimize_plastic\": false"), std::string("\"minimize_plastic\": false").size(),
               "\"minimize_plastic\": true");
    std::ofstream(dir + "/lattice_scenarios_lp.json") << lp;
    std::string r;
    try {
      const JobDescription job = load_job_file(dir + "/lattice_scenarios_lp.json");
      (void)lattice_variant_job(job, dir, out, materials, rules);
      for (const auto& e : std::filesystem::directory_iterator(out)) {
        const std::string n = e.path().filename().string();
        if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
          r = read_file(e.path().string());
      }
    } catch (const std::exception& e) {
      std::printf("  (lattice_part refused: %s)\n", e.what());
    }
    CHECK(r.find("\"graded_on\": [\"light down\", \"heavy side\"]") != std::string::npos &&
              r.find("\"governing\": \"heavy side\"") != std::string::npos,
          "§5 lattice_part: graded and certified on both, the heavy scenario governing");
    CHECK(std::isfinite(num_after(r, "lattice_margin_effective")) &&
              scenario_margin(r, "light down") > num_after(r, "lattice_margin_effective"),
          "§5 its margin is the solid's, finite, and the light scenario's is above it");
    if (!r.empty())
      std::printf("[lattice-scenarios] lattice-part: lattice margin %.4f (light %.4f)\n",
                  num_after(r, "lattice_margin_effective"), scenario_margin(r, "light down"));
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
