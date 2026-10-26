// LOAD SCENARIOS WITH "REDESIGN TO STRENGTHEN" (the reviewer's ruling of 2026-10-26
// 12:46; his "it needs to work together!"). Strengthen rebuilds the part in its box
// from what is frozen, so it is where a connection between two pieces has to be grown
// (Cool, Aage & Sigmund 2025: a load case whose only path is the connection). Every
// step is judged on the WORST scenario, and every version is verified on its exported
// file in EVERY scenario.
//
// Two 10 mm blocks 10 mm apart, each standing on its own anchor; the design box covers
// the gap. Scenario 1: both anchored, both pushed down. Scenario 2: block B's anchor
// OFF and a push on B, so B's load can reach an anchor only through the gap.
//   (a) the job runs (scenarios + strengthen are no longer refused);
//   (b) at least one version is accepted, and EVERY accepted version is one body,
//       carries both scenarios verified on its export, none unheld, its margin the
//       worst scenario's and at least its target;
//   (c) a refused version's note names its reason;
//   (d) the plain refusals: "Scenario “<name>” has no anchor switched on", "Scenario
//       “<name>” has no load", "Load scenarios can't be combined with bolt bearings yet".
// OCCT-free (a mesh part).

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <utility>
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

// --- Minimal, test-local JSON reader (same idiom as test_starved_rung.cpp) ---
struct Json {
  enum class T { Num, Str, Arr, Obj, Bool, Null } t = T::Num;
  double num = 0.0;
  bool boolean = false;
  std::string str;
  std::vector<Json> arr;
  std::vector<std::pair<std::string, Json>> obj;
  bool has(const std::string& key) const {
    for (const auto& kv : obj)
      if (kv.first == key) return true;
    return false;
  }
  const Json& at(const std::string& key) const {
    for (const auto& kv : obj)
      if (kv.first == key) return kv.second;
    throw std::runtime_error("missing JSON key: " + key);
  }
};

class JsonParser {
 public:
  explicit JsonParser(const std::string& s) : s_(s) {}
  Json parse() {
    skip_ws();
    Json v = value();
    skip_ws();
    if (pos_ != s_.size()) throw std::runtime_error("trailing JSON characters");
    return v;
  }

 private:
  const std::string& s_;
  std::size_t pos_ = 0;
  void skip_ws() {
    while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' ||
                                s_[pos_] == '\n' || s_[pos_] == '\r'))
      ++pos_;
  }
  char peek() {
    if (pos_ >= s_.size()) throw std::runtime_error("unexpected end of JSON");
    return s_[pos_];
  }
  Json value() {
    skip_ws();
    const char c = peek();
    if (c == '{') return object();
    if (c == '[') return array();
    if (c == '"') {
      Json v;
      v.t = Json::T::Str;
      v.str = string();
      return v;
    }
    if (c == 't' || c == 'f') {
      Json v;
      v.t = Json::T::Bool;
      v.boolean = c == 't';
      pos_ += v.boolean ? 4 : 5;
      return v;
    }
    if (c == 'n') {
      pos_ += 4;
      Json v;
      v.t = Json::T::Null;
      return v;
    }
    return number();
  }
  Json object() {
    Json v;
    v.t = Json::T::Obj;
    ++pos_;
    skip_ws();
    if (peek() == '}') {
      ++pos_;
      return v;
    }
    while (true) {
      skip_ws();
      std::string key = string();
      skip_ws();
      ++pos_;  // ':'
      v.obj.emplace_back(std::move(key), value());
      skip_ws();
      const char n = peek();
      ++pos_;
      if (n == '}') break;
    }
    return v;
  }
  Json array() {
    Json v;
    v.t = Json::T::Arr;
    ++pos_;
    skip_ws();
    if (peek() == ']') {
      ++pos_;
      return v;
    }
    while (true) {
      v.arr.push_back(value());
      skip_ws();
      const char n = peek();
      ++pos_;
      if (n == ']') break;
    }
    return v;
  }
  Json number() {
    const std::size_t start = pos_;
    while (pos_ < s_.size() &&
           (std::isdigit(static_cast<unsigned char>(s_[pos_])) || s_[pos_] == '-' ||
            s_[pos_] == '+' || s_[pos_] == '.' || s_[pos_] == 'e' || s_[pos_] == 'E'))
      ++pos_;
    Json v;
    v.num = std::stod(s_.substr(start, pos_ - start));
    return v;
  }
  std::string string() {
    ++pos_;
    std::string out;
    while (s_[pos_] != '"') {
      if (s_[pos_] == '\\') ++pos_;
      out.push_back(s_[pos_++]);
    }
    ++pos_;
    return out;
  }
};

// Two 10 x 10 x 10 mm boxes, A at x 0..10 and B at x 20..30, outward-wound.
TriangleMesh two_blocks() {
  TriangleMesh m;
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7},
                        {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2},
                        {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const double x0 : {0.0, 20.0}) {
    const int b = static_cast<int>(m.vertices.size());
    const double x1 = x0 + 10.0;
    for (const Vec3& v : std::vector<Vec3>{{x0, 0, 0}, {x1, 0, 0}, {x1, 10, 0}, {x0, 10, 0},
                                           {x0, 0, 10}, {x1, 0, 10}, {x1, 10, 10}, {x0, 10, 10}})
      m.vertices.push_back(v);
    for (const auto& tri : t) m.triangles.push_back({b + tri[0], b + tri[1], b + tri[2]});
  }
  return m;
}

// The planar face facing `nz` (+1 top, -1 bottom) on the block whose x is below / above 15.
int face_of(const StepModel& m, double nz, bool block_b) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane || fi.plane_normal.z * nz < 0.99) continue;
    double x = 0.0;
    int n = 0;
    for (std::size_t t = 0; t < m.mesh.triangles.size(); ++t) {
      if (m.triangle_face[t] != f) continue;
      for (int c = 0; c < 3; ++c) x += m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][c])].x;
      n += 3;
    }
    if (n > 0 && (x / n > 15.0) == block_b) return f;
  }
  return -1;
}

std::string scenario_json(const std::string& name, const std::vector<std::pair<int, double>>& pushes,
                          const std::vector<int>& anchors) {
  std::string s = "{\"name\": \"" + name + "\", \"groups\": [";
  for (std::size_t i = 0; i < pushes.size(); ++i)
    s += std::string(i ? ", " : "") + "{\"face_ids\": [" + std::to_string(pushes[i].first) +
         "], \"force\": [0, 0, " + std::to_string(pushes[i].second) + "]}";
  s += "], \"anchor_face_ids\": [";
  for (std::size_t i = 0; i < anchors.size(); ++i)
    s += std::string(i ? ", " : "") + std::to_string(anchors[i]);
  return s + "]}";
}

std::string job_json(const std::string& scenarios, int a_bottom, int b_bottom, int a_top,
                     int b_top, const std::string& extra = "") {
  return "{\"model\": \"scenario_blocks.stl\", \"material\": \"PLA\", \"mode\": "
         "\"minimize_plastic\", \"resolution\": 24, \"plsm\": {\"enabled\": true, "
         "\"max_iterations\": 6}, \"design_box\": {\"min\": [0, 0, 0], \"max\": [30, 10, 10]}, "
         "\"loads\": {\"minimize_plastic\": false, \"redesign\": \"strengthen\", " + extra +
         "\"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" + std::to_string(a_bottom) + ", " +
         std::to_string(b_bottom) + "], \"groups\": [{\"face_ids\": [" + std::to_string(a_top) +
         "], \"force\": [0, 0, -40]}, {\"face_ids\": [" + std::to_string(b_top) +
         "], \"force\": [0, 0, -40]}], \"scenarios\": " + scenarios +
         "}, \"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

std::string refusal(const std::string& json) {
  const std::string path = std::string(TMP_DIR) + "/scenario_blocks_refusal.json";
  std::ofstream(path) << json;
  try {
    (void)load_job_file(path);
    return "";
  } catch (const std::exception& e) {
    return e.what();
  }
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/scenario_blocks.stl", two_blocks(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/scenario_blocks.stl").model;
  const int a_bot = face_of(model, -1, false), b_bot = face_of(model, -1, true);
  const int a_top = face_of(model, 1, false), b_top = face_of(model, 1, true);
  CHECK(a_bot >= 0 && b_bot >= 0 && a_top >= 0 && b_top >= 0 && a_bot != b_bot && a_top != b_top,
        "fixture: each block has its own top and bottom face");

  const std::string both = scenario_json("Both anchored", {{a_top, -40.0}, {b_top, -40.0}},
                                         {a_bot, b_bot});
  const std::string free_b = scenario_json("B free", {{b_top, -40.0}}, {a_bot});
  const std::string path = dir + "/scenario_blocks_job.json";
  std::ofstream(path) << job_json("[" + both + ", " + free_b + "]", a_bot, b_bot, a_top, b_top);

  try {
    // ── (a) the job runs ──────────────────────────────────────────────────────
    const JobDescription job = load_job_file(path);
    const RunJobResult r = run_job(job, dir, dir + "/scenario_blocks_out", materials, rules,
                                   /*emit_progress=*/false, RunObservability{});
    const Json rep = JsonParser(r.report_json).parse();
    CHECK(rep.has("strengthen"), "(a) scenarios + strengthen runs and reports the strengthen block");
    if (rep.has("strengthen")) {
      const Json& s = rep.at("strengthen");
      int accepted = 0, files = 0;
      for (const Json& v : s.at("versions").arr) {
        const std::string st = v.at("status").str;
        std::printf("[scen+str] version %d: %s, verified %.3f vs target %.3f, %.1f g%s%s\n",
                    static_cast<int>(v.at("version").num), st.c_str(),
                    v.at("verified_margin").num, v.at("target_margin").num,
                    v.at("mass_grams").num, v.at("note").str.empty() ? "" : " - ",
                    v.at("note").str.c_str());
        if (v.has("scenarios"))
          for (const Json& sc : v.at("scenarios").arr)
            std::printf("[scen+str]   \"%s\": margin %.3f, weak %.2f %%%s%s\n",
                        sc.at("name").str.c_str(), sc.at("margin").num,
                        100.0 * sc.at("weak_share").num,
                        sc.at("governs").boolean ? ", governs" : "",
                        sc.at("unheld").boolean ? ", UNHELD" : "");
        if (st == "verified" || st == "repaired") {
          ++accepted;
          bool held = v.has("scenarios") && v.at("scenarios").arr.size() == 2;
          double worst = 1e300;
          if (held)
            for (const Json& sc : v.at("scenarios").arr) {
              held = held && !sc.at("unheld").boolean;
              worst = std::min(worst, sc.at("margin").num);
            }
          CHECK(held, "(b) an accepted version carries both scenarios, both held on its export");
          CHECK(held && std::fabs(worst - v.at("verified_margin").num) < 1e-9 &&
                    v.at("verified_margin").num >= v.at("target_margin").num,
                "(b) its margin is the worst scenario's, and meets its target");
        } else if (st == "unreachable") {
          CHECK(!v.at("note").str.empty(), "(c) a refused version names its reason");
        }
      }
      for (const std::string& p : r.mesh_paths) {
        const int bodies = count_components(read_stl_file(p).mesh);
        std::printf("[scen+str] %s: %d bod%s\n", p.c_str(), bodies, bodies == 1 ? "y" : "ies");
        CHECK(bodies == 1, "(b) every accepted version's file is ONE body (the gap was joined)");
        ++files;
      }
      CHECK(accepted >= 1 && files == accepted, "(b) at least one version is accepted, one file each");
    }
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }

  // ── (d) the plain refusals ─────────────────────────────────────────────────
  const std::string no_anchor =
      refusal(job_json("[" + both + ", " + scenario_json("Lifted", {{b_top, -40.0}}, {}) + "]",
                       a_bot, b_bot, a_top, b_top));
  CHECK(no_anchor.find("Scenario \xE2\x80\x9CLifted\xE2\x80\x9D has no anchor switched on") !=
            std::string::npos,
        "(d) no anchor ON: the plain line");
  const std::string no_load =
      refusal(job_json("[" + both + ", " + scenario_json("Idle", {}, {a_bot}) + "]", a_bot, b_bot,
                       a_top, b_top));
  CHECK(no_load.find("Scenario \xE2\x80\x9CIdle\xE2\x80\x9D has no load") != std::string::npos,
        "(d) no load: the plain line");
  const std::string bearing =
      refusal(job_json("[" + both + ", " + free_b + "]", a_bot, b_bot, a_top, b_top,
                       "\"anchor_model\": \"bearing\", "));
  CHECK(bearing.find("Load scenarios can't be combined with bolt bearings yet") !=
            std::string::npos,
        "(d) with bolt bearings: the plain line");
  std::printf("[scen+str] refusals: \"%s\" / \"%s\" / \"%s\"\n", no_anchor.c_str(), no_load.c_str(),
              bearing.c_str());

  if (g_failures == 0) {
    std::printf("scenarios + strengthen: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "scenarios + strengthen: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
