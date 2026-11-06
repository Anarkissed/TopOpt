// Ruling 11-06 2(a) + 2(c): a lattice is never "margin inf, ACCEPTED", and run_info.json
// never writes a bare inf.
//
// The certificate leaves latticed voxels out of the solid margin (their strut strength
// is report-only), so a part latticed through, with no solid voxel carrying stress,
// read margin inf and was ACCEPTED. Measured on this test's bar ("Lattice the original
// part", no region, skin none): 1,536 of 1,536 voxels latticed, both scenario margins
// null, the first listed "governing" on the tie, lattice_accepted true. The same bar as
// an analyze job with a grading block wrote "recertified_margin": inf (not JSON).
//
// Now, where no solid voxel carries stress, the latticed voxels are certified by the
// run path's certificate (each voxel at min(the law's density, what the file holds))
// with the measured strut law folded into the gate; where the law cannot apply (a type
// with no measured strut law, or below the cells-per-member floor) the answer is "not
// certified", in words.
//
// §1 octet, latticed through, two scenarios: the strut law gates it; every margin is
//    finite; it is never ACCEPTED on an unbounded margin.
// §2 the same job as FCC (no measured strut law): not certified, said in words.
// §3 an analyze job with a grading block on the same bar: the re-certification is
//    never ACCEPTED on an unbounded margin.
// §4 every run_info.json above is JSON: no bare inf or nan; a non-finite number is
//    null, and the file says which and why.
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

#include <cctype>
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

// test_lattice_scenarios' bar and scenarios: "light down" 30 N on the top, "heavy side"
// 300 N in +y on the free end, both anchored at x = 0. Growth off (lattice_part).
std::string job_json(const Faces& f, const std::string& mode, const std::string& topology,
                     const std::string& lattice_extra, const std::string& grading_extra) {
  const std::string anchor = "[" + std::to_string(f.left) + "]";
  const std::string light = "{\"name\": \"light down\", \"groups\": [{\"face_ids\": [" +
                            std::to_string(f.top) + "], \"force\": [0, 0, -30]}], "
                            "\"anchor_face_ids\": " + anchor + "}";
  const std::string heavy = "{\"name\": \"heavy side\", \"groups\": [{\"face_ids\": [" +
                            std::to_string(f.right) + "], \"force\": [0, 300, 0]}], "
                            "\"anchor_face_ids\": " + anchor + "}";
  return "{\"model\": \"lattice_no_solid_bar.stl\", \"material\": \"PLA\", \"mode\": \"" +
         mode + "\", \"resolution\": 24, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": " + anchor + ", \"groups\": [{\"face_ids\": [" +
         std::to_string(f.top) + "], \"force\": [0, 0, -30]}], \"scenarios\": [" + light +
         ", " + heavy + "]}, "
         "\"lattice\": {\"topology\": \"" + topology + "\"" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"" + topology + "\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45" + grading_extra + "}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
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

bool has(const std::string& s, const std::string& what) { return s.find(what) != std::string::npos; }

// The lattice margin per_scenario lists for `name`.
double scenario_margin(const std::string& receipt, const std::string& name) {
  const std::size_t k = receipt.find("{\"name\": \"" + name + "\", \"lattice_margin\"");
  return k == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                : num_after(receipt, "lattice_margin", k);
}

// Every bare word outside a string that JSON does not allow (inf, nan, ...).
std::string bare_words(const std::string& s) {
  std::string bad;
  bool in_str = false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    const char c = s[i];
    if (in_str) {
      if (c == '\\') ++i;
      else if (c == '"') in_str = false;
      continue;
    }
    if (c == '"') { in_str = true; continue; }
    if (!std::isalpha(static_cast<unsigned char>(c))) continue;
    std::size_t j = i;
    while (j < s.size() && std::isalpha(static_cast<unsigned char>(s[j]))) ++j;
    const std::string w = s.substr(i, j - i);
    // An exponent's 'e' sits between digits ("1e-05").
    const bool exponent = (w == "e" || w == "E") && i > 0 &&
                          std::isdigit(static_cast<unsigned char>(s[i - 1]));
    if (w != "true" && w != "false" && w != "null" && !exponent) bad += w + " ";
    i = j - 1;
  }
  return bad;
}

// lattice_part on the bar, latticed through. Returns the receipt ("" when none) and
// the run's run_info.json text.
struct Lp { std::string receipt, run_info, refused; };
Lp lattice_part(const std::string& dir, const Faces& f, const std::string& topology) {
  Lp out;
  const std::string folder = dir + "/lattice_no_solid_" + topology;
  std::filesystem::remove_all(folder);
  const std::string j = job_json(
      f, "lattice_part", topology,
      ", \"skin\": \"none\", \"require_lattice_void_reaches_exterior\": false", "");
  std::ofstream(dir + "/lattice_no_solid_" + topology + ".json") << j;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/lattice_no_solid_" + topology + ".json");
    (void)lattice_variant_job(job, dir, folder, materials, rules);
  } catch (const std::exception& e) {
    out.refused = e.what();
    std::printf("  (%s lattice_part refused: %s)\n", topology.c_str(), e.what());
  }
  if (std::filesystem::exists(folder))
    for (const auto& e : std::filesystem::directory_iterator(folder)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        out.receipt = read_file(e.path().string());
    }
  out.run_info = read_file(folder + "/run_info.json");
  return out;
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/lattice_no_solid_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/lattice_no_solid_bar.stl").model;
  Faces f;
  f.left = face_with_normal(model, -1, 0, 0);
  f.top = face_with_normal(model, 0, 0, 1);
  f.right = face_with_normal(model, 1, 0, 0);
  CHECK(f.left >= 0 && f.top >= 0 && f.right >= 0, "precondition: the bar's three faces");

  // ── §1 octet, latticed through ─────────────────────────────────────────────
  const Lp oct = lattice_part(dir, f, "octet");
  {
    const std::string& r = oct.receipt;
    const double m = num_after(r, "lattice_margin_effective");
    std::printf("[no-solid] octet: lattice_voxels %.0f, margin %.4f (light %.4f, heavy %.4f), "
                "accepted %s, gated %s\n",
                num_after(r, "lattice_voxels"), m, scenario_margin(r, "light down"),
                scenario_margin(r, "heavy side"),
                has(r, "\"lattice_accepted\": true") ? "true" : "false",
                has(r, "\"gated\": true") ? "true" : "false");
    CHECK(!r.empty(), "§1 the receipt is written");
    CHECK(!has(r, "\"lattice_accepted\": true") || std::isfinite(m),
          "§1 never ACCEPTED on an unbounded margin");
    CHECK(std::isfinite(m), "§1 the lattice margin is finite");
    CHECK(has(r, "\"gated\": true") && has(r, "\"strut_strength_uncertified\": false"),
          "§1 the measured strut law is in the gate (no solid voxel carries the load)");
    CHECK(std::isfinite(scenario_margin(r, "light down")) &&
              std::isfinite(scenario_margin(r, "heavy side")),
          "§1 each scenario's margin is finite (no tie of infinities)");
    CHECK(has(r, "\"governing\": \"heavy side\""), "§1 the heavy scenario governs");
  }

  // ── §2 FCC: no measured strut law ──────────────────────────────────────────
  const Lp fcc = lattice_part(dir, f, "fcc");
  {
    const std::string& r = fcc.receipt;
    std::printf("[no-solid] fcc: accepted %s, %s\n",
                has(r, "\"lattice_accepted\": true") ? "true" : "false",
                fcc.refused.empty() ? "(written)" : fcc.refused.c_str());
    CHECK(!has(r, "\"lattice_accepted\": true"), "§2 FCC latticed through is not accepted");
    CHECK(has(r, "\"lattice_not_certified\": true") &&
              has(r, "no measured strut-strength law"),
          "§2 the receipt says not certified, and why, in words");
  }

  // ── §3 an analyze job with a grading block ─────────────────────────────────
  std::string an_ri;
  {
    const std::string out = dir + "/lattice_no_solid_an";
    std::filesystem::remove_all(out);
    std::ofstream(dir + "/lattice_no_solid_an.json")
        << job_json(f, "analyze", "octet", "", ", \"intent\": \"structural\"");
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/lattice_no_solid_an.json");
    (void)analyze_job(job, dir, out, materials, rules, "", {});
    an_ri = read_file(out + "/run_info.json");
    const double rm = num_after(an_ri, "recertified_margin");
    std::printf("[no-solid] analyze: recertified_margin %.4f, accepted %s\n", rm,
                has(an_ri, "\"recertified_accepted\": true") ? "true" : "false");
    CHECK(!an_ri.empty(), "§3 run_info.json is written");
    CHECK(!has(an_ri, "\"recertified_accepted\": true") || std::isfinite(rm),
          "§3 the re-certification is never ACCEPTED on an unbounded margin");
  }

  // ── §4 run_info.json is JSON ───────────────────────────────────────────────
  for (const auto& [name, ri] : std::vector<std::pair<std::string, std::string>>{
           {"octet", oct.run_info}, {"fcc", fcc.run_info}, {"analyze", an_ri}}) {
    const std::string bad = bare_words(ri);
    if (!bad.empty()) std::printf("  (%s run_info bare words: %s)\n", name.c_str(), bad.c_str());
    CHECK(!ri.empty() && bad.empty(), ("§4 " + name + ": no bare inf or nan").c_str());
  }
  // The writer itself, on a number the runs above no longer produce: an unbounded
  // re-certified margin, as the analyze job wrote before (a).
  {
    RunInfo info;
    info.grading_present = true;
    info.grading_recertified = true;
    info.grading_recertified_margin = std::numeric_limits<double>::infinity();
    const std::string ri = run_info_json(info);
    CHECK(bare_words(ri).empty() && has(ri, "\"recertified_margin\": null"),
          "§4 the writer: an infinite number is written as null");
    CHECK(has(ri, "\"null_numbers\": {\"fields\": [{\"field\": "
                  "\"grading.recertified_margin\", \"value\": \"inf\"}]") &&
              has(ri, "\"reason\": \""),
          "§4 the writer: the file names the field, its value and the reason");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
