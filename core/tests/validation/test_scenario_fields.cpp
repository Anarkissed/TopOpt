// LOAD SCENARIOS — EVERY scenario's own fields (his "the scenario selector changes the
// views", 2026-10-27; #354's ask). A run with 2+ scenarios certifies every scenario on
// every rung but fields.bin carries the GOVERNING one's fields only; scenario_fields.bin
// carries each scenario's, so the app's Scenario menu can swap the stress / bend /
// load-flow / break views. fields.bin, report.json and the meshes are unchanged.
//
// Two 10 mm blocks 10 mm apart in a design box (test_scenarios_strengthen's part).
// Scenario 1: both anchored, both pushed down. Scenario 2: block B's anchor OFF, a push
// on B. Run as Redesign to strengthen, as a plain growth run, and without scenarios:
//   (a) scenario_fields.bin is written on both scenario runs, on fields.bin's grid, with
//       report.json's scenario names in order and fields.bin's blocks (join keys);
//   (b) the governing scenario's arrays are fields.bin's, byte for byte, and the other
//       scenario's are its own (they differ);
//   (c) every scenario's fields are that scenario's: an independent certification of
//       its own supports and loads (the weak springs of its OFF anchor included) on the
//       stored design (design.bin) gives the same displacement and von Mises;
//   (d) the run without scenarios writes no scenario_fields.bin.
// OCCT-free (a mesh part).

#include "topopt/analyze.hpp"
#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
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
  return "{\"model\": \"scenario_fields_blocks.stl\", \"material\": \"PLA\", \"mode\": "
         "\"minimize_plastic\", \"resolution\": 24, \"plsm\": {\"enabled\": true, "
         "\"max_iterations\": 6}, \"design_box\": {\"min\": [0, 0, 0], \"max\": [30, 10, 10]}, "
         "\"loads\": {\"minimize_plastic\": false, " + extra +
         "\"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" + std::to_string(a_bottom) + ", " +
         std::to_string(b_bottom) + "], \"groups\": [{\"face_ids\": [" + std::to_string(a_top) +
         "], \"force\": [0, 0, -40]}, {\"face_ids\": [" + std::to_string(b_top) +
         "], \"force\": [0, 0, -40]}]" + (scenarios.empty() ? "" : ", \"scenarios\": " + scenarios) +
         "}, \"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}


// --- the two containers, read back (little-endian, the formats in fields.hpp) ---
struct Reader {
  std::vector<char> b;
  std::size_t p = 0;
  template <typename T>
  T get() {
    if (p + sizeof(T) > b.size()) throw std::runtime_error("short container");
    T v;
    std::memcpy(&v, b.data() + p, sizeof(T));
    p += sizeof(T);
    return v;
  }
  std::vector<float> floats(std::int64_t n) {
    std::vector<float> v(static_cast<std::size_t>(n));
    for (float& x : v) x = get<float>();
    return v;
  }
};
Reader open(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("cannot open " + path);
  return Reader{std::vector<char>(std::istreambuf_iterator<char>(f), {}), 0};
}
struct Grid {
  int nx = 0, ny = 0, nz = 0;
  double ox = 0, oy = 0, oz = 0, h = 0;
  bool operator==(const Grid& o) const {
    return nx == o.nx && ny == o.ny && nz == o.nz && ox == o.ox && oy == o.oy && oz == o.oz &&
           h == o.h;
  }
};
struct Block {
  double key = 0.0;
  int governing = -1;
  std::vector<std::vector<float>> vm, u;  // per scenario (one for fields.bin)
};
struct Container {
  Grid g;
  std::vector<std::string> names;
  std::vector<Block> blocks;
};
Container read_fields(const std::string& path) {
  Reader r = open(path);
  Container c;
  if (r.get<std::uint8_t>() != 1) throw std::runtime_error("fields.bin version");
  r.p += 3;
  c.g.nx = r.get<std::int32_t>(); c.g.ny = r.get<std::int32_t>(); c.g.nz = r.get<std::int32_t>();
  c.g.ox = r.get<double>(); c.g.oy = r.get<double>(); c.g.oz = r.get<double>();
  c.g.h = r.get<double>();
  (void)r.get<double>();
  const int nv = r.get<std::int32_t>();
  r.p += 4;
  for (int v = 0; v < nv; ++v) {
    Block b;
    b.key = r.get<double>();
    (void)r.get<double>();
    r.p += 8;
    const std::int64_t nvm = r.get<std::int64_t>(), nt = r.get<std::int64_t>(),
                       nu = r.get<std::int64_t>();
    b.vm.push_back(r.floats(nvm));
    r.p += static_cast<std::size_t>(4 * nt);
    b.u.push_back(r.floats(nu));
    c.blocks.push_back(std::move(b));
  }
  return c;
}
Container read_scenario_fields(const std::string& path) {
  Reader r = open(path);
  Container c;
  if (r.get<std::uint8_t>() != 1) throw std::runtime_error("scenario_fields.bin version");
  r.p += 3;
  c.g.nx = r.get<std::int32_t>(); c.g.ny = r.get<std::int32_t>(); c.g.nz = r.get<std::int32_t>();
  c.g.ox = r.get<double>(); c.g.oy = r.get<double>(); c.g.oz = r.get<double>();
  c.g.h = r.get<double>();
  const int ns = r.get<std::int32_t>(), nv = r.get<std::int32_t>();
  for (int s = 0; s < ns; ++s) {
    const int n = r.get<std::int32_t>();
    c.names.emplace_back(r.b.data() + r.p, static_cast<std::size_t>(n));
    r.p += static_cast<std::size_t>(n);
  }
  for (int v = 0; v < nv; ++v) {
    Block b;
    b.key = r.get<double>();
    b.governing = r.get<std::int32_t>();
    r.p += 4;
    for (int s = 0; s < ns; ++s) {
      const std::int64_t nvm = r.get<std::int64_t>(), nu = r.get<std::int64_t>();
      b.vm.push_back(r.floats(nvm));
      b.u.push_back(r.floats(nu));
    }
    c.blocks.push_back(std::move(b));
  }
  if (r.p != r.b.size()) throw std::runtime_error("scenario_fields.bin: trailing bytes");
  return c;
}

// max |a - b| / max |b|
double rel_diff(const std::vector<float>& a, const std::vector<double>& b) {
  double d = 0.0, m = 0.0;
  for (std::size_t i = 0; i < b.size() && i < a.size(); ++i) {
    d = std::max(d, std::fabs(static_cast<double>(a[i]) - b[i]));
    m = std::max(m, std::fabs(b[i]));
  }
  return a.size() != b.size() ? 1e30 : (m > 0.0 ? d / m : d);
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/scenario_fields_blocks.stl", two_blocks(), StlFormat::Binary);
  const StepModel model = import_part(dir + "/scenario_fields_blocks.stl").model;
  const int a_bot = face_of(model, -1, false), b_bot = face_of(model, -1, true);
  const int a_top = face_of(model, 1, false), b_top = face_of(model, 1, true);
  CHECK(a_bot >= 0 && b_bot >= 0 && a_top >= 0 && b_top >= 0, "precondition: the faces");
  const std::string scenarios =
      "[" + scenario_json("both pushed", {{a_top, -40.0}, {b_top, -40.0}}, {a_bot, b_bot}) +
      ", " + scenario_json("B off, pushed", {{b_top, -40.0}}, {a_bot}) + "]";
  const Material& pla = materials.at("PLA");

  struct Case {
    const char* what;
    std::string extra, scenarios;
  };
  const Case cases[] = {{"strengthen", "\"redesign\": \"strengthen\", ", scenarios},
                        {"growth", "", scenarios},
                        {"no scenarios", "", ""}};
  for (const Case& cs : cases) {
    const std::string out = dir + "/scenario_fields_" + std::string(cs.what);
    const std::string job_path = dir + "/scenario_fields_job.json";
    std::ofstream(job_path) << job_json(cs.scenarios, a_bot, b_bot, a_top, b_top, cs.extra);
    std::remove((out + "/scenario_fields.bin").c_str());
    try {
      const JobDescription job = load_job_file(job_path);
      const RunJobResult r = run_job(job, dir, out, materials, rules, false, RunObservability{});
      std::ifstream probe(out + "/scenario_fields.bin");
      const bool written = static_cast<bool>(probe);
      if (cs.scenarios.empty()) {
        std::printf("[scenario-fields] %s: scenario_fields.bin %s\n", cs.what,
                    written ? "WRITTEN" : "not written");
        CHECK(!written, "(d) a run without scenarios writes no scenario_fields.bin");
        continue;
      }
      CHECK(written, "(a) scenario_fields.bin is written");
      if (!written) continue;
      const Container f = read_fields(out + "/fields.bin");
      const Container sf = read_scenario_fields(out + "/scenario_fields.bin");
      const Json rep = JsonParser(r.report_json).parse();
      const Json& vars = rep.at("variants");
      std::vector<std::string> names;
      if (vars.arr.size() > 0 && vars.arr[0].has("scenarios"))
        for (const Json& s : vars.arr[0].at("scenarios").arr) names.push_back(s.at("name").str);
      std::printf("[scenario-fields] %s: grid %dx%dx%d, %zu scenario(s), %zu block(s) (fields.bin "
                  "%zu)\n", cs.what, sf.g.nx, sf.g.ny, sf.g.nz, sf.names.size(), sf.blocks.size(),
                  f.blocks.size());
      CHECK(sf.g == f.g, "(a) on fields.bin's grid");
      CHECK(sf.names == names && names.size() == 2, "(a) report.json's scenario names, in order");
      CHECK(!f.blocks.empty() && sf.blocks.size() == f.blocks.size(), "(a) fields.bin's blocks");

      // (c) the reference: each scenario certified alone on the stored design.
      const ProductionRunSetup setup =
          build_production_loadcase(model, job.resolution, production_loadcase_from_job(job, model));
      const SolvedDesignDomain domain = resolve_design_domain(setup.grid, setup.bcs, setup.options);
      const std::vector<SimpScenario> sized =
          sized_scenarios(domain.scenarios, pla.youngs_modulus_mpa, domain.grid.spacing);
      const DesignStore ds = read_design_file(out + "/design.bin");
      CHECK(domain.grid.nx == f.g.nx && domain.grid.ny == f.g.ny && domain.grid.nz == f.g.nz &&
                sized.size() == 2,
            "precondition: the reference rebuilds the run's grid and both scenarios");
      SimpParams params;
      params.youngs_modulus = pla.youngs_modulus_mpa;
      params.poisson = pla.poisson;
      params.penalty = 3.0;
      for (std::size_t v = 0; v < sf.blocks.size() && v < f.blocks.size(); ++v) {
        const Block& b = sf.blocks[v];
        const Block& fb = f.blocks[v];
        CHECK(b.key == fb.key, "(a) the join key is fields.bin's");
        CHECK(b.governing == 0 || b.governing == 1, "(b) a governing scenario is named");
        if (b.governing < 0 || b.governing > 1 || b.vm.size() != 2) continue;
        const std::size_t gi = static_cast<std::size_t>(b.governing), oi = 1 - gi;
        CHECK(b.vm[gi] == fb.vm[0] && b.u[gi] == fb.u[0],
              "(b) the governing scenario's arrays are fields.bin's, byte for byte");
        double diff = 0.0;
        for (std::size_t i = 0; i < b.u[oi].size() && i < b.u[gi].size(); ++i)
          diff = std::max(diff, static_cast<double>(std::fabs(b.u[oi][i] - b.u[gi][i])));
        CHECK(diff > 1e-6, "(b) the other scenario's fields are its own");
        const StoredDesign* d = nullptr;
        for (const StoredDesign& s : ds.variants)
          if (s.accepted && s.requested_volume_fraction == b.key) d = &s;
        CHECK(d != nullptr, "precondition: the block's design in design.bin");
        if (d == nullptr || sized.size() != 2) continue;
        for (std::size_t s = 0; s < 2; ++s) {
          const FixedDesignAnalysis a = analyze_fixed_design(
              domain.grid, params, d->density, sized[s].bcs, sized[s].loads, pla,
              Vec3{0.0, 0.0, 1.0}, setup.options.simp.cg_tolerance,
              setup.options.simp.cg_max_iterations, setup.options.simp.solver,
              setup.options.margin_stop, KnockdownSpec{}, true, 1.0);
          const double du = rel_diff(b.u[s], a.displacement_field);
          const double dvm = rel_diff(b.vm[s], a.von_mises_field);
          std::printf("[scenario-fields] %s block %zu (vf %.4f), \"%s\"%s: vs its own "
                      "certification, displacement %.2e, von Mises %.2e (relative)\n",
                      cs.what, v, b.key, sf.names[s].c_str(), s == gi ? " (governs)" : "", du, dvm);
          CHECK(du <= 1e-4 && dvm <= 1e-4, "(c) the scenario's fields are its own certification's");
        }
      }
    } catch (const std::exception& e) {
      ++g_failures;
      std::fprintf(stderr, "FAIL: %s threw: %s\n", cs.what, e.what());
    }
  }

  if (g_failures == 0) {
    std::printf("scenario fields: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "scenario fields: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
