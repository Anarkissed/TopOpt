// CORE LIST items 41 + 47 — WHAT THE EXPORT KEEPS, and the anchored hole a design
// let go of.
//
// 41. The export kept ONLY THE LARGEST BODY (keep_largest_component on the shell
//     the file carries), so his split Carriage Arms saved one arm per variant. Now
//     every body that holds an anchor or a load is exported; only loose specks
//     holding neither are dropped, and the receipt counts them.
// 47. An anchored hole's pad is a local skin. When the design removes the material
//     around it (on 13185527 every rung was below the frozen floor, item 40) the pad
//     is left as an island, the export dropped it, and nothing said so: "it cut out
//     a part of the holes that I specifically set to anchor". Now a rung whose
//     design detaches an anchored piece that the part AS DRAWN joined to a load is
//     REJECTED, its report line naming the anchored faces, and nothing of it is
//     exported. (Keeping anchors joined in the first place is item 42, on hold.)
//
// Both through run_job, the production path (load case, anchor pad, protections,
// clearances, export), on the parametric level set the app runs, capped at a few
// iterations: what is pinned is what the export keeps and what the verdict says,
// not a design. Every check below reads the exported files and report.json, as the
// app does, so the file compiles against the pre-fix code and FAILS there:
//   A. TWO BLOCKS, one load group across both (his two arms): each accepted
//      variant's file holds BOTH bodies, at smooth_factor 1 and 2, and its report
//      line says how many bodies it exported.
//   B. THE PLATE WITH AN ANCHORED BORE (13185527 in miniature): the bore is
//      anchored and kept clear, the two side faces are protected, so the frozen
//      share exceeds the low rungs and the floor rung removes every free voxel.
//      The bore's pad is then an island. That rung is rejected, naming the bore,
//      and the rungs that would repeat it are skipped saying so.
//
// Eigen (minimize_plastic) and OCCT-free (both parts are meshes), but the block
// sits with the other production-seam gates. Same self-contained CHECK harness
// and test-local JSON reader as test_starved_rung.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <sstream>
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
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++pos_;
      else break;
    }
  }
  char peek() {
    if (pos_ >= s_.size()) throw std::runtime_error("unexpected end of JSON");
    return s_[pos_];
  }
  Json value() {
    skip_ws();
    char c = peek();
    if (c == '{') return object();
    if (c == '[') return array();
    if (c == '"') {
      Json v;
      v.t = Json::T::Str;
      v.str = string();
      return v;
    }
    if (c == '-' || (c >= '0' && c <= '9')) return number();
    if (c == 't' || c == 'f') return boolean();
    if (c == 'n') return null_literal();
    throw std::runtime_error(std::string("unexpected JSON character '") + c +
                             "'");
  }
  Json boolean() {
    Json v;
    v.t = Json::T::Bool;
    if (s_.compare(pos_, 4, "true") == 0) {
      v.boolean = true;
      pos_ += 4;
    } else if (s_.compare(pos_, 5, "false") == 0) {
      v.boolean = false;
      pos_ += 5;
    } else {
      throw std::runtime_error("invalid JSON boolean literal");
    }
    return v;
  }
  Json null_literal() {
    if (s_.compare(pos_, 4, "null") != 0)
      throw std::runtime_error("invalid JSON null literal");
    pos_ += 4;
    Json v;
    v.t = Json::T::Null;
    return v;
  }
  Json object() {
    Json v;
    v.t = Json::T::Obj;
    ++pos_;  // '{'
    skip_ws();
    if (peek() == '}') {
      ++pos_;
      return v;
    }
    while (true) {
      skip_ws();
      if (peek() != '"') throw std::runtime_error("expected JSON object key");
      std::string key = string();
      skip_ws();
      if (peek() != ':') throw std::runtime_error("expected ':' in object");
      ++pos_;
      v.obj.emplace_back(std::move(key), value());
      skip_ws();
      char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == '}') break;
      throw std::runtime_error("expected ',' or '}' in object");
    }
    return v;
  }
  Json array() {
    Json v;
    v.t = Json::T::Arr;
    ++pos_;  // '['
    skip_ws();
    if (peek() == ']') {
      ++pos_;
      return v;
    }
    while (true) {
      v.arr.push_back(value());
      skip_ws();
      char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == ']') break;
      throw std::runtime_error("expected ',' or ']' in array");
    }
    return v;
  }
  Json number() {
    std::size_t start = pos_;
    if (peek() == '-') ++pos_;
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' ||
          c == '+' || c == '-')
        ++pos_;
      else
        break;
    }
    Json v;
    v.t = Json::T::Num;
    v.num = std::stod(s_.substr(start, pos_ - start));
    return v;
  }
  std::string string() {
    ++pos_;  // opening quote
    std::string out;
    while (true) {
      if (pos_ >= s_.size()) throw std::runtime_error("unterminated string");
      char c = s_[pos_++];
      if (c == '"') break;
      if (c == '\\') {
        if (pos_ >= s_.size()) throw std::runtime_error("unterminated escape");
        char e = s_[pos_++];
        switch (e) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'n': out.push_back('\n'); break;
          case 't': out.push_back('\t'); break;
          default: out.push_back(e); break;
        }
      } else {
        out.push_back(c);
      }
    }
    return out;
  }
};

// An axis-aligned box appended to `m` as 12 outward-wound triangles.
void add_box(TriangleMesh& m, const Vec3& lo, const Vec3& hi) {
  const int b = static_cast<int>(m.vertices.size());
  m.vertices.push_back({lo.x, lo.y, lo.z});  // 0
  m.vertices.push_back({hi.x, lo.y, lo.z});  // 1
  m.vertices.push_back({hi.x, hi.y, lo.z});  // 2
  m.vertices.push_back({lo.x, hi.y, lo.z});  // 3
  m.vertices.push_back({lo.x, lo.y, hi.z});  // 4
  m.vertices.push_back({hi.x, lo.y, hi.z});  // 5
  m.vertices.push_back({hi.x, hi.y, hi.z});  // 6
  m.vertices.push_back({lo.x, hi.y, hi.z});  // 7
  const int tris[12][3] = {{0, 2, 1}, {0, 3, 2},   // bottom (-z)
                           {4, 5, 6}, {4, 6, 7},   // top (+z)
                           {0, 1, 5}, {0, 5, 4},   // front (-y)
                           {3, 7, 6}, {3, 6, 2},   // back (+y)
                           {0, 4, 7}, {0, 7, 3},   // left (-x)
                           {1, 2, 6}, {1, 6, 5}};  // right (+x)
  for (const auto& t : tris)
    m.triangles.push_back({b + t[0], b + t[1], b + t[2]});
}

// The centroid of every triangle of face `f`.
Vec3 face_centroid(const StepModel& model, int f) {
  double x = 0, y = 0, z = 0;
  int n = 0;
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    if (model.triangle_face[t] != f) continue;
    for (int w = 0; w < 3; ++w) {
      const Vec3& p = model.mesh.vertices[static_cast<std::size_t>(
          model.mesh.triangles[t][static_cast<std::size_t>(w)])];
      x += p.x;
      y += p.y;
      z += p.z;
      ++n;
    }
  }
  return n > 0 ? Vec3{x / n, y / n, z / n} : Vec3{0, 0, 0};
}

// The planar faces whose normal is within ~8 degrees of `dir`.
std::vector<int> planes_facing(const StepModel& model, const Vec3& dir) {
  std::vector<int> out;
  for (int f = 0; f < model.face_count; ++f) {
    const StepFaceInfo& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind != StepSurfaceKind::Plane) continue;
    const Vec3& n = info.plane_normal;
    const double len = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (!(len > 0.0)) continue;
    if ((n.x * dir.x + n.y * dir.y + n.z * dir.z) / len > 0.99) out.push_back(f);
  }
  return out;
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// A load-case job on the parametric level set, capped at a few iterations.
JobDescription base_job(const std::string& model, int resolution) {
  JobDescription job;
  job.model = model;
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = resolution;
  job.has_plsm = true;
  job.plsm_enabled = true;
  job.plsm_max_iterations = 6;
  job.loads.present = true;
  job.loads.minimize_plastic = true;  // the reduction ladder, with the anchor pad
  job.loads.build_dir = Vec3{0.0, 0.0, 1.0};
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

const Json* line_for(const Json& report, double requested, bool* accepted) {
  for (const char* array : {"variants", "rejected_variants"}) {
    if (!report.has(array)) continue;
    for (const Json& v : report.at(array).arr)
      if (v.has("requested_volume_fraction") &&
          std::fabs(v.at("requested_volume_fraction").num - requested) < 1e-12) {
        if (accepted != nullptr)
          *accepted = std::string(array) == "variants";
        return &v;
      }
  }
  return nullptr;
}

// ── A. TWO BLOCKS ────────────────────────────────────────────────────────────
void section_two_blocks(const MaterialLibrary& materials, const SettingsRules& rules) {
  const std::string dir = TMP_DIR;
  const std::string stl = "export_bodies_two_blocks.stl";
  TriangleMesh blocks;
  add_box(blocks, Vec3{0.0, 0.0, 0.0}, Vec3{10.0, 10.0, 10.0});
  add_box(blocks, Vec3{20.0, 0.0, 0.0}, Vec3{30.0, 10.0, 10.0});
  write_stl_file(dir + "/" + stl, blocks, StlFormat::Binary);
  CHECK(count_components(blocks) == 2, "fixture: the part is two separate blocks");

  const PartModel part = import_part(dir + "/" + stl);
  std::vector<int> anchors, loads;
  for (int f : planes_facing(part.model, Vec3{0.0, 0.0, -1.0})) anchors.push_back(f);
  for (int f : planes_facing(part.model, Vec3{0.0, 0.0, 1.0})) loads.push_back(f);
  int left = 0, right = 0;
  for (int f : anchors) (face_centroid(part.model, f).x < 15.0 ? left : right)++;
  CHECK(anchors.size() == 2 && loads.size() == 2 && left == 1 && right == 1,
        "fixture: one bottom and one top pseudo-face per block");

  for (const int sf : {1, 2}) {
    JobDescription job = base_job(stl, 24);
    job.loads.anchor_face_ids = anchors;
    JobLoadGroup g;  // ONE load group across both blocks, as his arms carried
    g.face_ids = loads;
    g.force = Vec3{0.0, 0.0, -20.0};
    job.loads.groups.push_back(g);
    job.output.smooth_factor = sf;
    const std::string out = dir + "/export_bodies_two_blocks_sf" + std::to_string(sf);
    const RunJobResult r = run_job(job, dir, out, materials, rules,
                                   /*emit_progress=*/false, RunObservability{});
    const Json report = JsonParser(r.report_json).parse();

    std::size_t accepted = 0;
    for (const MinimizePlasticVariant& v : r.pipeline.evaluated)
      if (v.accepted) ++accepted;
    std::printf("[41] two blocks, smooth_factor %d: %zu rung(s), %zu accepted, "
                "%zu file(s)\n",
                sf, r.pipeline.evaluated.size(), accepted, r.mesh_paths.size());
    CHECK(accepted >= 1 && r.mesh_paths.size() == accepted,
          "precondition: rungs are accepted and each wrote its file");
    for (const std::string& p : r.mesh_paths) {
      const StlMesh file = read_stl_file(p);
      const int bodies = count_components(file.mesh);
      std::printf("[41]   %s: %d bodies, %zu triangles\n",
                  p.substr(p.rfind('/') + 1).c_str(), bodies,
                  file.mesh.triangles.size());
      CHECK(bodies == 2,
            "(41): the exported file holds BOTH blocks, each with its own anchor "
            "and load (it kept only the largest)");
    }
    for (const Json& v : report.at("variants").arr) {
      CHECK(v.has("bodies") &&
                static_cast<int>(v.at("bodies").at("exported").num) == 2,
            "(41): the accepted line says it exported 2 bodies");
    }
  }
}

// ── B. THE PLATE WITH AN ANCHORED BORE ───────────────────────────────────────
void section_anchored_bore(const MaterialLibrary& materials,
                           const SettingsRules& rules) {
  const std::string dir = MESH_FIXTURE_DIR;
  const std::string stl = "plate_bore.stl";  // 24 x 16 x 4 mm, an r 3 bore through z
  const PartModel part = import_part(dir + "/" + stl);
  int bore = -1;
  for (int f = 0; f < part.model.face_count; ++f)
    if (part.model.faces[static_cast<std::size_t>(f)].kind ==
        StepSurfaceKind::Cylinder)
      bore = f;
  const std::vector<int> x_lo = planes_facing(part.model, Vec3{-1.0, 0.0, 0.0});
  const std::vector<int> x_hi = planes_facing(part.model, Vec3{1.0, 0.0, 0.0});
  const std::vector<int> y_lo = planes_facing(part.model, Vec3{0.0, -1.0, 0.0});
  const std::vector<int> y_hi = planes_facing(part.model, Vec3{0.0, 1.0, 0.0});
  CHECK(bore >= 0 && x_lo.size() == 1 && x_hi.size() == 1 && y_lo.size() == 1 &&
            y_hi.size() == 1,
        "fixture: the plate segments into a bore and four side faces");
  if (bore < 0 || x_lo.size() != 1 || x_hi.size() != 1 || y_lo.size() != 1 ||
      y_hi.size() != 1)
    return;

  JobDescription job = base_job(stl, 32);
  // Held at its -x end AND by a bolt through the bore; pushed down at its +x end.
  job.loads.anchor_face_ids = {x_lo[0], bore};
  JobLoadGroup g;
  g.face_ids = {x_hi[0]};
  g.force = Vec3{0.0, 0.0, -1.0};
  job.loads.groups.push_back(g);
  // The two long sides protected one voxel deep: they join the end pads into a
  // frame that carries the load at the floor, and leave a band of free material
  // between the frame and the bore's pad.
  job.loads.face_protection_face_ids = {y_lo[0], y_hi[0]};
  job.loads.face_protection_depth_mm = 0.7;
  JobClearance bolt;  // every anchored hole of 13185527 also carried one
  bolt.face_id = bore;
  bolt.kind = "bolt";
  job.loads.clearances.push_back(bolt);
  job.has_design_box = true;  // the whole-domain path, where a rung can saturate
  job.design_box.min = Vec3{-12.0, -8.0, 0.0};
  job.design_box.max = Vec3{12.0, 8.0, 4.0};

  const std::string out = std::string(TMP_DIR) + "/export_bodies_anchored_bore";
  const RunJobResult r = run_job(job, dir, out, materials, rules,
                                 /*emit_progress=*/false, RunObservability{});
  const Json report = JsonParser(r.report_json).parse();
  std::printf("[47] plate: bore face %d, %zu rung(s) evaluated, %zu file(s)\n",
              bore, r.pipeline.evaluated.size(), r.mesh_paths.size());
  for (const MinimizePlasticVariant& v : r.pipeline.evaluated)
    std::printf("[47]   vf %.2f: printed %.4f, %s%s\n", v.requested_volume_fraction,
                v.report.printed_fraction, v.accepted ? "accepted" : "rejected: ",
                v.accepted ? "" : v.report.rejection_reason.c_str());

  CHECK(report.has("frozen_share"),
        "precondition: the protections and pads freeze more than a low rung asks");
  if (!report.has("frozen_share")) return;
  const Json& fs = report.at("frozen_share");
  std::printf("[47] frozen share %.4f\n", fs.at("share").num);

  // The FLOOR rung: the first one whose target clamped to the density floor.
  double floor_vf = -1.0;
  for (const MinimizePlasticVariant& v : r.pipeline.evaluated) {
    bool accepted = false;
    const Json* line = line_for(report, v.requested_volume_fraction, &accepted);
    if (line != nullptr && line->has("target_saturated") &&
        line->at("target_saturated").boolean) {
      floor_vf = v.requested_volume_fraction;
      CHECK(!accepted,
            "(47): the floor rung left the bore's pad an island, so it is "
            "REJECTED, never accepted with the hole silently dropped");
      CHECK(line->has("rejection_reason") &&
                line->at("rejection_reason").str == "anchored piece detached",
            "(47): it says why: an anchored piece detached");
      bool names_bore = false;
      if (line->has("bodies") && line->at("bodies").has("lost_anchor_face_ids"))
        for (const Json& id : line->at("bodies").at("lost_anchor_face_ids").arr)
          if (static_cast<int>(id.num) == bore) names_bore = true;
      CHECK(names_bore, "(47): its line names the bore's face");
      break;
    }
  }
  CHECK(floor_vf > 0.0, "precondition: some rung's target clamped to the floor");

  // Every later floor rung would repeat that rejected design: skipped, saying so.
  for (const Json& s : fs.at("skipped_rungs").arr) {
    CHECK(std::fabs(s.at("same_design_as").num - floor_vf) < 1e-12,
          "(47 + 40): a skipped rung names the rejected floor rung");
    CHECK(s.at("reason").str.find("rejected: anchored piece detached") !=
              std::string::npos,
          "(47 + 40): and says that rung was rejected for a detached anchor");
  }
  // No file was written for a rung that lost the bore.
  for (const std::string& p : r.mesh_paths) {
    char name[32];
    std::snprintf(name, sizeof(name), "variant_%03d.stl",
                  static_cast<int>(std::lround(floor_vf * 100.0)));
    CHECK(p.find(name) == std::string::npos,
          "(47): the rejected floor rung wrote no variant file");
  }
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  try {
    section_two_blocks(materials, rules);
    section_anchored_bore(materials, rules);
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }
  if (g_failures == 0) {
    std::printf("export_bodies (items 41 + 47): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "export_bodies (items 41 + 47): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
