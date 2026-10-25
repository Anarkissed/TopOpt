// CORE LIST item 50 — "Redesign to strengthen" (the reviewer's brief of 2026-10-24
// 22:59, approved 01:52): the part is rebuilt inside its design box from what is
// frozen, as three versions, each the least plastic found that meets its target of
// 25 / 50 / 75 % less worst stress than the reference (the part's verified margin
// as drawn, or margin_required when that is higher), each verified on the EXPORTED
// geometry.
//
// Through run_job on a small bar in a box (anchored at one end, pushed at the
// other), read from report.json as the app reads it:
//   (a) the reference is max(as drawn, required), and version 1 passes its target;
//   (b) the versions that pass are strictly stronger, each >= 1.05 x the previous;
//   (c) a target above 0.95 x the box filled solid is reported UNREACHABLE, with no
//       variant behind it;
//   (d) a part that fails as drawn is referenced to the requirement;
//   (e) without the key the run is today's growth ladder: no "strengthen" block.
//
// Eigen (minimize_plastic) on a mesh part, OCCT-free; the parametric level set,
// capped at a few iterations.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
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

// A 40 x 10 x 10 mm bar, outward-wound.
TriangleMesh bar() {
  TriangleMesh m;
  const double x1 = 40.0, y1 = 10.0, z1 = 10.0;
  m.vertices = {{0, 0, 0}, {x1, 0, 0}, {x1, y1, 0}, {0, y1, 0},
                {0, 0, z1}, {x1, 0, z1}, {x1, y1, z1}, {0, y1, z1}};
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7},
                        {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2},
                        {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
}

int face_facing(const StepModel& model, double nx, double ny, double nz) {
  for (int f = 0; f < model.face_count; ++f) {
    const Vec3& n = model.faces[static_cast<std::size_t>(f)].plane_normal;
    if (model.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Plane &&
        n.x * nx + n.y * ny + n.z * nz > 0.99)
      return f;
  }
  return -1;
}

JobDescription bar_job(const StepModel& model, double force_n, bool strengthen) {
  JobDescription job;
  job.model = "strengthen_bar.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.has_plsm = true;
  job.plsm_enabled = true;
  job.plsm_max_iterations = 6;
  job.loads.present = true;
  job.loads.minimize_plastic = false;  // the strengthen side of the checkbox
  job.loads.anchor_face_ids = {face_facing(model, -1, 0, 0)};
  JobLoadGroup g;
  g.face_ids = {face_facing(model, 1, 0, 0)};
  g.force = Vec3{0.0, 0.0, -force_n};
  job.loads.groups.push_back(g);
  job.loads.build_dir = Vec3{0.0, 0.0, 1.0};
  if (strengthen) job.loads.redesign = "strengthen";
  job.has_design_box = true;  // the bar's envelope, 6 mm deeper and taller
  job.design_box.min = Vec3{0.0, -3.0, -3.0};
  job.design_box.max = Vec3{40.0, 13.0, 13.0};
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/strengthen_bar.stl", bar(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/strengthen_bar.stl").model;
  CHECK(face_facing(model, -1, 0, 0) >= 0 && face_facing(model, 1, 0, 0) >= 0,
        "fixture: the bar has its two end faces");

  try {
    // ── (a)-(c): a part that passes as drawn ──────────────────────────────────
    const RunJobResult r = run_job(bar_job(model, 50.0, true), dir,
                                   dir + "/strengthen_out_pass", materials, rules,
                                   /*emit_progress=*/false, RunObservability{});
    const Json rep = JsonParser(r.report_json).parse();
    CHECK(rep.has("strengthen"), "(a) report.json carries the strengthen block");
    if (rep.has("strengthen")) {
      const Json& s = rep.at("strengthen");
      const double drawn = s.at("as_drawn_margin").num;
      const double req = s.at("margin_required").num;
      const double ref = s.at("reference_margin").num;
      const double ceil = s.at("ceiling_margin").num;
      std::printf("[50] pass: as drawn %.4g, required %.4g, reference %.4g, ceiling %.4g\n",
                  drawn, req, ref, ceil);
      CHECK(drawn >= req && std::fabs(ref - std::max(drawn, req)) < 1e-9 * ref,
            "(a) the reference is max(as drawn, required); this part passes as drawn");
      CHECK(s.has("cap") && s.at("cap").at("face_id").num >= 0 &&
                !s.at("cap").at("note").str.empty(),
            "the ceiling's worst-stress site is named (one line per run)");
      if (s.has("cap")) std::printf("[50] cap: %s\n", s.at("cap").at("note").str.c_str());
      const Json& vs = s.at("versions");
      CHECK(vs.arr.size() == 3, "three versions are reported");
      double prev = 0.0;
      int unreachable = 0;
      std::size_t passing = 0;
      for (const Json& v : vs.arr) {
        const std::string st = v.at("status").str;
        const double tgt = v.at("target_margin").num;
        const double ver = v.at("verified_margin").num;
        std::printf("[50]   v%d: target %.4g, status %s, verified %.4g, mass %.4g g, "
                    "vf %.4f, IoU %.3f, %d coarse run(s), %d repair(s)\n",
                    static_cast<int>(v.at("version").num), tgt, st.c_str(), ver,
                    v.at("mass_grams").num, v.at("volume_fraction").num,
                    v.at("iou_with_original").num,
                    static_cast<int>(v.at("coarse_runs").num),
                    static_cast<int>(v.at("repairs").num));
        if (tgt > 0.95 * ceil) {
          CHECK(st == "unreachable",
                "(c) a target above 0.95 x the box filled solid is unreachable");
        }
        if (st == "unreachable") {
          ++unreachable;
          continue;
        }
        if (st == "merged") continue;
        ++passing;
        CHECK(ver >= tgt, "(a)(b) a version that is not unreachable meets its "
                          "target on the VERIFIED (exported) geometry");
        CHECK(ver >= 1.05 * prev, "(b) each version is >= 1.05 x the previous");
        CHECK(v.at("anchors_attached").boolean &&
                  static_cast<int>(v.at("specks").num) == 0 &&
                  static_cast<long long>(v.at("keep_clear_voxels").num) == 0,
              "a version has every anchor attached, no specks, Keep Clears empty");
        prev = ver;
      }
      CHECK(vs.arr.size() == 3 && vs.arr[0].at("status").str != "unreachable" &&
                vs.arr[0].at("status").str != "merged",
            "(a) version 1 passes");
      CHECK(unreachable >= 1,
            "precondition (c): this box makes at least one target unreachable");
      CHECK(r.mesh_paths.size() == passing,
            "one exported file per version that passed, none behind the others");
    }

    // ── (d): a part that fails as drawn ──────────────────────────────────────
    const RunJobResult f = run_job(bar_job(model, 3000.0, true), dir,
                                   dir + "/strengthen_out_fail", materials, rules,
                                   false, RunObservability{});
    const Json frep = JsonParser(f.report_json).parse();
    if (frep.has("strengthen")) {
      const Json& s = frep.at("strengthen");
      std::printf("[50] fail: as drawn %.4g, required %.4g, reference %.4g\n",
                  s.at("as_drawn_margin").num, s.at("margin_required").num,
                  s.at("reference_margin").num);
      CHECK(s.at("as_drawn_margin").num < s.at("margin_required").num,
            "precondition (d): this load fails the bar as drawn");
      CHECK(std::fabs(s.at("reference_margin").num - s.at("margin_required").num) <
                1e-9,
            "(d) a failing part is referenced to the requirement");
      CHECK(std::fabs(s.at("versions").arr[0].at("target_margin").num -
                      s.at("margin_required").num * 4.0 / 3.0) < 1e-6,
            "(d) its version 1 target is the requirement x 4/3");
    } else {
      CHECK(false, "(d) the failing part's report carries the strengthen block");
    }

    // ── (e): the key absent is today's growth ladder ─────────────────────────
    const RunJobResult g = run_job(bar_job(model, 50.0, false), dir,
                                   dir + "/strengthen_out_off", materials, rules,
                                   false, RunObservability{});
    CHECK(g.report_json.find("\"strengthen\"") == std::string::npos &&
              g.pipeline.growth_ladder,
          "(e) without the key: the growth ladder, no strengthen block");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }

  if (g_failures == 0) {
    std::printf("strengthen (item 50): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "strengthen (item 50): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
