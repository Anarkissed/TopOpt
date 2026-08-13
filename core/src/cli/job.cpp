#include "topopt/job.hpp"

#include "topopt/cell_plan.hpp"  // cell_size_mode_from_name (the ONE mode vocabulary)

#include <cctype>
#include <cmath>
#include <cstddef>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace topopt {
namespace {

// --- Minimal JSON parser ----------------------------------------------------
//
// job.json is small and read-only to the CLI, and ARCHITECTURE §4 locks the
// dependency set (no JSON library), so this mirrors the module-local parser
// the materials loader and settings engine use: a purpose-built recursive-
// descent parser over objects/arrays/strings/numbers/booleans/null. It rejects
// malformed input rather than repairing it, and is kept internal to this
// module (no speculative shared "json" API).

struct JsonValue {
  enum class Type { Null, Bool, Number, String, Array, Object };
  Type type = Type::Null;
  double num = 0.0;
  std::string str;
  std::vector<JsonValue> arr;
  std::vector<std::pair<std::string, JsonValue>> obj;  // insertion order
};

class JsonParser {
 public:
  explicit JsonParser(const std::string& s) : s_(s) {}

  JsonValue parse() {
    skip_ws();
    JsonValue v = parse_value();
    skip_ws();
    if (pos_ != s_.size()) fail("trailing characters after JSON value");
    return v;
  }

 private:
  const std::string& s_;
  std::size_t pos_ = 0;

  [[noreturn]] void fail(const std::string& msg) {
    throw JobError("job.json parse error at offset " + std::to_string(pos_) +
                   ": " + msg);
  }

  char peek() {
    if (pos_ >= s_.size()) fail("unexpected end of input");
    return s_[pos_];
  }

  void skip_ws() {
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        ++pos_;
      } else {
        break;
      }
    }
  }

  JsonValue parse_value() {
    skip_ws();
    char c = peek();
    switch (c) {
      case '{':
        return parse_object();
      case '[':
        return parse_array();
      case '"': {
        JsonValue v;
        v.type = JsonValue::Type::String;
        v.str = parse_string();
        return v;
      }
      case 't':
      case 'f':
        return parse_bool();
      case 'n':
        return parse_null();
      default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
        fail(std::string("unexpected character '") + c + "'");
    }
  }

  JsonValue parse_object() {
    JsonValue v;
    v.type = JsonValue::Type::Object;
    ++pos_;  // consume '{'
    skip_ws();
    if (peek() == '}') {
      ++pos_;
      return v;
    }
    while (true) {
      skip_ws();
      if (peek() != '"') fail("expected string key in object");
      std::string key = parse_string();
      skip_ws();
      if (peek() != ':') fail("expected ':' after object key");
      ++pos_;  // consume ':'
      JsonValue val = parse_value();
      v.obj.emplace_back(std::move(key), std::move(val));
      skip_ws();
      char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == '}') break;
      fail("expected ',' or '}' in object");
    }
    return v;
  }

  JsonValue parse_array() {
    JsonValue v;
    v.type = JsonValue::Type::Array;
    ++pos_;  // consume '['
    skip_ws();
    if (peek() == ']') {
      ++pos_;
      return v;
    }
    while (true) {
      v.arr.push_back(parse_value());
      skip_ws();
      char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == ']') break;
      fail("expected ',' or ']' in array");
    }
    return v;
  }

  JsonValue parse_bool() {
    if (s_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      JsonValue v;
      v.type = JsonValue::Type::Bool;
      v.num = 1.0;
      return v;
    }
    if (s_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      JsonValue v;
      v.type = JsonValue::Type::Bool;
      v.num = 0.0;
      return v;
    }
    fail("invalid literal");
  }

  JsonValue parse_null() {
    if (s_.compare(pos_, 4, "null") == 0) {
      pos_ += 4;
      return JsonValue{};  // Type::Null
    }
    fail("invalid literal");
  }

  JsonValue parse_number() {
    std::size_t start = pos_;
    if (peek() == '-') ++pos_;
    if (pos_ >= s_.size()) fail("invalid number");
    if (s_[pos_] == '0') {
      ++pos_;
    } else if (s_[pos_] >= '1' && s_[pos_] <= '9') {
      while (pos_ < s_.size() && std::isdigit((unsigned char)s_[pos_])) ++pos_;
    } else {
      fail("invalid number");
    }
    if (pos_ < s_.size() && s_[pos_] == '.') {
      ++pos_;
      if (pos_ >= s_.size() || !std::isdigit((unsigned char)s_[pos_]))
        fail("invalid number: expected digit after '.'");
      while (pos_ < s_.size() && std::isdigit((unsigned char)s_[pos_])) ++pos_;
    }
    if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) ++pos_;
      if (pos_ >= s_.size() || !std::isdigit((unsigned char)s_[pos_]))
        fail("invalid number: expected digit in exponent");
      while (pos_ < s_.size() && std::isdigit((unsigned char)s_[pos_])) ++pos_;
    }
    JsonValue v;
    v.type = JsonValue::Type::Number;
    v.num = std::stod(s_.substr(start, pos_ - start));
    return v;
  }

  std::string parse_string() {
    ++pos_;  // consume opening quote
    std::string out;
    while (true) {
      if (pos_ >= s_.size()) fail("unterminated string");
      char c = s_[pos_++];
      if (c == '"') break;
      if (c == '\\') {
        if (pos_ >= s_.size()) fail("unterminated escape");
        char e = s_[pos_++];
        switch (e) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'b': out.push_back('\b'); break;
          case 'f': out.push_back('\f'); break;
          case 'n': out.push_back('\n'); break;
          case 'r': out.push_back('\r'); break;
          case 't': out.push_back('\t'); break;
          default: fail("unsupported string escape");
        }
      } else {
        out.push_back(c);
      }
    }
    return out;
  }
};

// --- Schema helpers -----------------------------------------------------------

[[noreturn]] void schema_fail(const std::string& msg) {
  throw JobError("job.json: " + msg);
}

// A maintainer-comment key: ignored everywhere (the demo fixture's _comment /
// _fixture_note / _gravity_note / _output_note).
bool is_comment_key(const std::string& key) {
  return !key.empty() && key[0] == '_';
}

// Reject any non-comment key of `v` that is not in `allowed`. `where` names the
// object in the diagnostic.
void reject_unknown_keys(const JsonValue& v,
                         const std::vector<std::string>& allowed,
                         const std::string& where) {
  for (const auto& kv : v.obj) {
    if (is_comment_key(kv.first)) continue;
    bool known = false;
    for (const std::string& a : allowed) {
      if (kv.first == a) {
        known = true;
        break;
      }
    }
    if (!known) schema_fail("unknown key \"" + kv.first + "\" in " + where);
  }
}

// Find required/optional key. Returns nullptr when absent.
const JsonValue* find_key(const JsonValue& v, const std::string& key) {
  for (const auto& kv : v.obj) {
    if (kv.first == key) return &kv.second;
  }
  return nullptr;
}

const JsonValue& require_key(const JsonValue& v, const std::string& key,
                             const std::string& where) {
  const JsonValue* found = find_key(v, key);
  if (found == nullptr)
    schema_fail("missing required key \"" + key + "\" in " + where);
  return *found;
}

std::string require_string(const JsonValue& v, const std::string& name) {
  if (v.type != JsonValue::Type::String)
    schema_fail("\"" + name + "\" must be a string");
  return v.str;
}

std::string require_nonempty_string(const JsonValue& v,
                                    const std::string& name) {
  std::string s = require_string(v, name);
  if (s.empty()) schema_fail("\"" + name + "\" must be a non-empty string");
  return s;
}

double require_number(const JsonValue& v, const std::string& name) {
  if (v.type != JsonValue::Type::Number)
    schema_fail("\"" + name + "\" must be a number");
  if (!std::isfinite(v.num)) schema_fail("\"" + name + "\" must be finite");
  return v.num;
}

int require_positive_int(const JsonValue& v, const std::string& name) {
  const double d = require_number(v, name);
  if (d < 1.0 || d != std::floor(d))
    schema_fail("\"" + name + "\" must be an integer >= 1");
  return static_cast<int>(d);
}

const JsonValue& require_object(const JsonValue& v, const std::string& name) {
  if (v.type != JsonValue::Type::Object)
    schema_fail("\"" + name + "\" must be an object");
  return v;
}

// One geometric face selector ({"kind":"cylindrical","radius_mm":r}) — the same
// locked GEOMETRIC selection fixture_faces uses (never a raw OCCT face index).
// Shared by fixture_faces, loadcase anchors, and load-group faces so all three
// enforce identical selector semantics.
JobFaceSelector parse_face_selector(const JsonValue& sel, const std::string& where) {
  if (sel.type != JsonValue::Type::Object)
    schema_fail("every " + where + " entry must be a selector object");
  reject_unknown_keys(sel, {"kind", "radius_mm"}, "a " + where + " selector");
  JobFaceSelector s;
  s.kind = require_nonempty_string(
      require_key(sel, "kind", "a " + where + " selector"), "kind");
  if (s.kind != "cylindrical")
    schema_fail("selector \"kind\" must be \"cylindrical\" (got \"" + s.kind +
                "\")");
  s.radius_mm = require_number(
      require_key(sel, "radius_mm", "a " + where + " selector"), "radius_mm");
  if (!(s.radius_mm > 0.0)) schema_fail("selector \"radius_mm\" must be > 0");
  return s;
}

// A non-empty array of face selectors.
std::vector<JobFaceSelector> parse_selector_array(const JsonValue& v,
                                                  const std::string& where) {
  if (v.type != JsonValue::Type::Array)
    schema_fail("\"" + where + "\" must be an array");
  if (v.arr.empty())
    schema_fail("\"" + where + "\" must contain at least one selector");
  std::vector<JobFaceSelector> out;
  for (const JsonValue& sel : v.arr) out.push_back(parse_face_selector(sel, where));
  return out;
}

// A non-empty array of non-negative integers (raw B-rep face ids).
std::vector<int> parse_int_array(const JsonValue& v, const std::string& name) {
  if (v.type != JsonValue::Type::Array)
    schema_fail("\"" + name + "\" must be an array");
  if (v.arr.empty())
    schema_fail("\"" + name + "\" must contain at least one id");
  std::vector<int> out;
  for (const JsonValue& e : v.arr) {
    const double d = require_number(e, name + " entry");
    if (d < 0.0 || d != std::floor(d))
      schema_fail("every \"" + name + "\" entry must be a non-negative integer");
    out.push_back(static_cast<int>(d));
  }
  return out;
}

// A 3-number array -> Vec3.
Vec3 parse_vec3(const JsonValue& v, const std::string& name) {
  if (v.type != JsonValue::Type::Array || v.arr.size() != 3)
    schema_fail("\"" + name + "\" must be an array of 3 numbers");
  double d[3];
  for (int i = 0; i < 3; ++i)
    d[i] = require_number(v.arr[static_cast<std::size_t>(i)], name + " component");
  return Vec3{d[0], d[1], d[2]};
}

// An axis-aligned box {"min":[x,y,z],"max":[x,y,z]}, min <= max componentwise.
JobBox parse_box(const JsonValue& v, const std::string& name) {
  require_object(v, name);
  reject_unknown_keys(v, {"min", "max"}, name);
  JobBox b;
  b.min = parse_vec3(require_key(v, "min", name), name + ".min");
  b.max = parse_vec3(require_key(v, "max", name), name + ".max");
  if (b.max.x < b.min.x || b.max.y < b.min.y || b.max.z < b.min.z)
    schema_fail("\"" + name + "\" max must be >= min componentwise");
  return b;
}

}  // namespace

JobDescription parse_job(const std::string& json_text) {
  JsonParser parser(json_text);
  const JsonValue root = parser.parse();
  if (root.type != JsonValue::Type::Object)
    schema_fail("top level must be an object");

  reject_unknown_keys(root,
                      {"model", "source_format", "material", "mode",
                       "resolution", "fixture_faces", "gravity", "ladder",
                       "margin_stop", "simp", "draft", "warm_start", "output",
                       "lattice", "grading", "loads", "design_box", "keep_outs",
                       "build_direction", "build_orientation_report",
                       "bake_build_orientation", "variant", "semdot",
                       "plsm"},
                      "the job");

  JobDescription job;
  job.model =
      require_nonempty_string(require_key(root, "model", "the job"), "model");
  // Optional provenance override (handoff 2026-07-26-3mf-optimize-path): the true
  // source format when `model` is a working copy in another format. A plain string;
  // empty/absent => run_info derives it from the model extension.
  if (const JsonValue* sf = find_key(root, "source_format"))
    job.source_format = require_string(*sf, "source_format");
  job.material = require_nonempty_string(
      require_key(root, "material", "the job"), "material");
  job.mode =
      require_nonempty_string(require_key(root, "mode", "the job"), "mode");
  // Exactly three modes (task lattice-page-core-hookup stage 3 added "analyze"
  // so the LAN worker can route a fixed-design analysis; task
  // 2026-08-02-lattice-a-variant added "lattice_variant", which lattices a
  // FINISHED variant of a completed run with NO optimization). The validation
  // stays STRICT: anything else is refused here, before any work.
  if (job.mode != "minimize_plastic" && job.mode != "analyze" &&
      job.mode != "lattice_variant")
    schema_fail(
        "\"mode\" must be \"minimize_plastic\", \"analyze\" or "
        "\"lattice_variant\" (got \"" +
        job.mode + "\")");
  job.resolution = require_positive_int(
      require_key(root, "resolution", "the job"), "resolution");

  // The run is in LOADCASE mode iff a "loads" block is present. In that mode the
  // anchors are the fixtures, the groups are the design load, and the production
  // ladder / fixed self-weight magnitude / default margin apply (exactly the app
  // path) — so the self-weight keys are MEANINGLESS and rejected rather than
  // silently ignored. In SELF-WEIGHT mode (no "loads") they are required as before.
  // ── build_direction / build_orientation_report (handoff
  // 2026-08-01-build-direction-separation) ────────────────────────────────────
  // Parsed BEFORE the mode branch because both are mode-independent: the plate
  // orientation is a property of the print, not of how the load was declared.
  // Both optional; absent means the pre-separation behaviour to the byte.
  if (const JsonValue* bd = find_key(root, "build_direction")) {
    job.build_direction = parse_vec3(*bd, "build_direction");
    const Vec3& b = job.build_direction;
    if (b.x * b.x + b.y * b.y + b.z * b.z <= 0.0)
      schema_fail("\"build_direction\" must be non-zero");
    job.has_build_direction = true;
  }
  if (const JsonValue* br = find_key(root, "build_orientation_report")) {
    if (br->type != JsonValue::Type::Bool)
      schema_fail("\"build_orientation_report\" must be a boolean");
    job.build_orientation_report = (br->num != 0.0);
  }
  // "bake_build_orientation" (handoff 2026-08-01-bake-build-orientation) — three
  // spellings, validated STRICTLY here so a typo is refused before any work
  // rather than silently falling back to the default and exporting an
  // unreoriented file the report claims is reoriented.
  if (const JsonValue* bb = find_key(root, "bake_build_orientation")) {
    job.bake_build_orientation = require_string(*bb, "bake_build_orientation");
    if (job.bake_build_orientation != "auto" &&
        job.bake_build_orientation != "always" &&
        job.bake_build_orientation != "off")
      schema_fail(
          "\"bake_build_orientation\" must be \"auto\", \"always\" or \"off\" "
          "(got \"" +
          job.bake_build_orientation + "\")");
  }

  const JsonValue* loads_v = find_key(root, "loads");
  const bool loadcase = loads_v != nullptr;

  if (loadcase) {
    for (const char* k : {"fixture_faces", "gravity", "ladder", "margin_stop"})
      if (find_key(root, k))
        schema_fail(std::string("\"") + k +
                    "\" is not allowed with \"loads\": in loadcase mode the "
                    "anchors are the fixtures, the groups are the design load, "
                    "and the production ladder + margin apply");

    const JsonValue& lv = require_object(*loads_v, "loads");
    reject_unknown_keys(
        lv, {"anchors", "anchor_face_ids", "face_regions", "anchor_region_ids",
             "groups", "clearances",
             "face_protections", "face_protection_depth_mm", "build_dir",
             "infill_percent", "minimize_plastic", "wall_loops",
             "wall_line_width_mm", "wall_line_width_outer_mm"},
        "loads");
    job.loads.present = true;

    // ── THE REGION LAYER (task 2026-08-14-face-regions §1) ─────────────────
    //
    // A region is declared ONCE here and referred to by id from the anchors,
    // the groups and the protections, so a union that feeds three consumers is
    // written once and cannot drift between them.
    //
    // ★ A UNION IS NOT A LIST OF FACE IDS ON THE WIRE (§3c). What is stored is
    // the defining FILTER plus an explicit add/remove list, re-evaluated on
    // every import — a re-import after a CAD edit renumbers B-rep faces, and a
    // stored id list would then point at whatever inherited the number.
    // "filter_matched_at_author" records what the filter matched when the union
    // was made, so the run REPORTS a change instead of absorbing it.
    //
    // ★ A SPLIT IS STORED AS GEOMETRY (§4e): "cuts" are model-space half-spaces
    // (a point and a normal), never "region 24, half A".
    if (const JsonValue* rs = find_key(lv, "face_regions")) {
      if (rs->type != JsonValue::Type::Array)
        schema_fail("\"loads.face_regions\" must be an array");
      for (const JsonValue& rv : rs->arr) {
        require_object(rv, "a face region");
        reject_unknown_keys(rv,
                            {"id", "name", "filter", "filter_matched_at_author",
                             "add", "remove", "cuts", "parent_id"},
                            "a face region");
        FaceRegionSpec spec;
        const double id =
            require_number(require_key(rv, "id", "a face region"), "face region id");
        if (id < 0.0 || id != std::floor(id))
          schema_fail("a face region \"id\" must be a non-negative integer");
        spec.id = static_cast<int>(id);
        if (const JsonValue* nv = find_key(rv, "name"))
          spec.name = require_string(*nv, "a face region name");
        if (const JsonValue* av = find_key(rv, "add"))
          spec.add = parse_int_array(*av, "a face region \"add\"");
        if (const JsonValue* rmv = find_key(rv, "remove"))
          spec.remove = parse_int_array(*rmv, "a face region \"remove\"");
        if (const JsonValue* pv = find_key(rv, "parent_id"))
          spec.parent_id =
              static_cast<int>(require_number(*pv, "a face region parent_id"));
        if (const JsonValue* mv = find_key(rv, "filter_matched_at_author"))
          spec.filter_matched_at_author = static_cast<int>(
              require_number(*mv, "face region filter_matched_at_author"));
        if (const JsonValue* fv = find_key(rv, "filter")) {
          const JsonValue& f = require_object(*fv, "a face region filter");
          reject_unknown_keys(f,
                              {"max_area_mm2", "min_area_mm2",
                               "min_larger_neighbours", "larger_ratio", "kind",
                               "cylinder_radius_mm", "cylinder_radius_tol_mm"},
                              "a face region filter");
          RegionFilter& rf = spec.filter;
          if (const JsonValue* v = find_key(f, "max_area_mm2"))
            rf.max_area_mm2 = require_number(*v, "filter max_area_mm2");
          if (const JsonValue* v = find_key(f, "min_area_mm2"))
            rf.min_area_mm2 = require_number(*v, "filter min_area_mm2");
          if (const JsonValue* v = find_key(f, "min_larger_neighbours"))
            rf.min_larger_neighbours =
                static_cast<int>(require_number(*v, "filter min_larger_neighbours"));
          if (const JsonValue* v = find_key(f, "larger_ratio"))
            rf.larger_ratio = require_number(*v, "filter larger_ratio");
          if (const JsonValue* v = find_key(f, "kind")) {
            rf.kind = require_string(*v, "filter kind");
            if (rf.kind != "plane" && rf.kind != "cylinder" && rf.kind != "other")
              schema_fail(
                  "a face region filter \"kind\" must be \"plane\", "
                  "\"cylinder\" or \"other\" (got \"" + rf.kind + "\")");
          }
          if (const JsonValue* v = find_key(f, "cylinder_radius_mm"))
            rf.cylinder_radius_mm = require_number(*v, "filter cylinder_radius_mm");
          if (const JsonValue* v = find_key(f, "cylinder_radius_tol_mm"))
            rf.cylinder_radius_tol_mm =
                require_number(*v, "filter cylinder_radius_tol_mm");
          if (rf.min_larger_neighbours > 0 && !(rf.larger_ratio > 1.0))
            schema_fail(
                "a face region filter's \"larger_ratio\" must be > 1 — a "
                "neighbour the same size is not a LARGER neighbour, and the "
                "blend signal is that the face sits between two bigger ones");
        }
        if (const JsonValue* cs = find_key(rv, "cuts")) {
          if (cs->type != JsonValue::Type::Array)
            schema_fail("a face region \"cuts\" must be an array");
          for (const JsonValue& cv : cs->arr) {
            require_object(cv, "a face region cut");
            reject_unknown_keys(cv, {"point", "normal", "strict"},
                                "a face region cut");
            RegionCut cut;
            cut.point = parse_vec3(require_key(cv, "point", "a face region cut"),
                                   "a cut point");
            cut.normal = parse_vec3(require_key(cv, "normal", "a face region cut"),
                                    "a cut normal");
            if (cut.normal.x == 0.0 && cut.normal.y == 0.0 && cut.normal.z == 0.0)
              schema_fail("a face region cut \"normal\" must be non-zero");
            if (const JsonValue* sv = find_key(cv, "strict"))
              {
                if (sv->type != JsonValue::Type::Bool)
                  schema_fail("a face region cut \"strict\" must be a boolean");
                cut.strict = sv->num != 0.0;
              }
            spec.cuts.push_back(cut);
          }
        }
        if (!spec.filter.any() && spec.add.empty())
          schema_fail(
              "face region " + std::to_string(spec.id) +
              " declares neither a filter nor any \"add\" faces — it would "
              "resolve to nothing and tag nothing");
        job.loads.face_regions.push_back(std::move(spec));
      }
    }
    if (const JsonValue* arid = find_key(lv, "anchor_region_ids"))
      job.loads.anchor_region_ids =
          parse_int_array(*arid, "anchor_region_ids");
    // anchors: optional, given as geometric selectors ("anchors") OR raw B-rep
    // face ids ("anchor_face_ids", the id form the app produces). Empty => min-x
    // clamp fallback, like the app. The two forms compose.
    if (const JsonValue* a = find_key(lv, "anchors"))
      job.loads.anchors = parse_selector_array(*a, "anchors");
    if (const JsonValue* aid = find_key(lv, "anchor_face_ids"))
      job.loads.anchor_face_ids = parse_int_array(*aid, "anchor_face_ids");
    // groups: optional (empty => self-weight fallback). Each group's faces are
    // {"faces":[selectors]} OR {"face_ids":[ids]}, plus a "force":[fx,fy,fz].
    if (const JsonValue* gs = find_key(lv, "groups")) {
      if (gs->type != JsonValue::Type::Array)
        schema_fail("\"loads.groups\" must be an array");
      for (const JsonValue& gv : gs->arr) {
        require_object(gv, "a loads group");
        reject_unknown_keys(gv, {"faces", "face_ids", "region_ids", "force"},
                            "a loads group");
        JobLoadGroup grp;
        if (const JsonValue* fs = find_key(gv, "faces"))
          grp.faces = parse_selector_array(*fs, "faces");
        if (const JsonValue* fid = find_key(gv, "face_ids"))
          grp.face_ids = parse_int_array(*fid, "face_ids");
        // ★ A group may name REGIONS instead of (or as well as) faces. That is
        // what turns his 23-face load group into one row.
        if (const JsonValue* rid = find_key(gv, "region_ids"))
          grp.region_ids = parse_int_array(*rid, "region_ids");
        if (grp.faces.empty() && grp.face_ids.empty() && grp.region_ids.empty())
          schema_fail(
              "a loads group must give \"faces\", \"face_ids\" or "
              "\"region_ids\"");
        grp.force = parse_vec3(require_key(gv, "force", "a loads group"),
                               "a loads group force");
        job.loads.groups.push_back(std::move(grp));
      }
    }
    // clearances: optional "Keep clear" keep-out regions (handoff 100). Each is a
    // raw B-rep face id + a kind ("bolt"/"face") + the editable mm distances (the
    // relevant ones; the others default to the same spec suggestions the app
    // prefills). Empty/absent => no clearance => byte-identical to the pre-100 run.
    if (const JsonValue* cs = find_key(lv, "clearances")) {
      if (cs->type != JsonValue::Type::Array)
        schema_fail("\"loads.clearances\" must be an array");
      for (const JsonValue& cv : cs->arr) {
        require_object(cv, "a clearance");
        reject_unknown_keys(cv,
                            {"face_id", "geometry", "kind",
                             "concentric_margin_mm", "axial_clearance_mm",
                             "slab_depth_mm"},
                            "a clearance");
        JobClearance cl;
        cl.kind = require_nonempty_string(
            require_key(cv, "kind", "a clearance"), "clearance kind");
        if (cl.kind != "bolt" && cl.kind != "face")
          schema_fail("a clearance \"kind\" must be \"bolt\" or \"face\" (got \"" +
                      cl.kind + "\")");
        // A clearance is EITHER an auto face (a "face_id") OR a manual primitive
        // (a "geometry" object) — exactly one (handoff group-editing). The manual
        // primitive supplies the axis/radius/normal/extent the auto path would
        // otherwise derive from the B-rep, so a hand-placed keep-out survives the
        // bridge and job schema intact.
        const JsonValue* fid_v = find_key(cv, "face_id");
        const JsonValue* geom_v = find_key(cv, "geometry");
        if ((fid_v == nullptr) == (geom_v == nullptr))
          schema_fail(
              "a clearance must have exactly one of \"face_id\" or \"geometry\"");
        if (fid_v != nullptr) {
          const double fid = require_number(*fid_v, "clearance face_id");
          if (fid < 0.0 || fid != std::floor(fid))
            schema_fail("a clearance \"face_id\" must be a non-negative integer");
          cl.face_id = static_cast<int>(fid);
        } else {
          cl.manual = true;
          const JsonValue& gv = require_object(*geom_v, "clearance geometry");
          if (cl.kind == "bolt") {
            reject_unknown_keys(
                gv, {"axis_point", "axis_dir", "radius_mm", "half_length_mm"},
                "a bolt clearance geometry");
            cl.axis_point = parse_vec3(
                require_key(gv, "axis_point", "a bolt clearance geometry"),
                "clearance axis_point");
            cl.axis_dir = parse_vec3(
                require_key(gv, "axis_dir", "a bolt clearance geometry"),
                "clearance axis_dir");
            cl.radius_mm = require_number(
                require_key(gv, "radius_mm", "a bolt clearance geometry"),
                "clearance radius_mm");
            cl.half_length_mm = require_number(
                require_key(gv, "half_length_mm", "a bolt clearance geometry"),
                "clearance half_length_mm");
            if (cl.radius_mm < 0.0 || cl.half_length_mm < 0.0)
              schema_fail(
                  "a bolt clearance geometry radius_mm/half_length_mm must be "
                  ">= 0");
          } else {  // face
            reject_unknown_keys(
                gv, {"origin", "normal", "half_u_mm", "half_w_mm"},
                "a face clearance geometry");
            cl.origin =
                parse_vec3(require_key(gv, "origin", "a face clearance geometry"),
                           "clearance origin");
            cl.normal =
                parse_vec3(require_key(gv, "normal", "a face clearance geometry"),
                           "clearance normal");
            cl.half_u_mm = require_number(
                require_key(gv, "half_u_mm", "a face clearance geometry"),
                "clearance half_u_mm");
            cl.half_w_mm = require_number(
                require_key(gv, "half_w_mm", "a face clearance geometry"),
                "clearance half_w_mm");
            if (cl.half_u_mm < 0.0 || cl.half_w_mm < 0.0)
              schema_fail(
                  "a face clearance geometry half_u_mm/half_w_mm must be >= 0");
          }
        }
        if (const JsonValue* m = find_key(cv, "concentric_margin_mm")) {
          cl.concentric_margin_mm = require_number(*m, "concentric_margin_mm");
          if (cl.concentric_margin_mm < 0.0)
            schema_fail("\"concentric_margin_mm\" must be >= 0");
        }
        if (const JsonValue* a = find_key(cv, "axial_clearance_mm")) {
          cl.axial_clearance_mm = require_number(*a, "axial_clearance_mm");
          if (cl.axial_clearance_mm < 0.0)
            schema_fail("\"axial_clearance_mm\" must be >= 0");
        }
        if (const JsonValue* d = find_key(cv, "slab_depth_mm")) {
          cl.slab_depth_mm = require_number(*d, "slab_depth_mm");
          if (cl.slab_depth_mm < 0.0)
            schema_fail("\"slab_depth_mm\" must be >= 0");
        }
        job.loads.clearances.push_back(std::move(cl));
      }
    }
    // Face protections (handoff 124): raw B-rep face ids whose own material must
    // not be touched, plus ONE global depth (mm). A protection freezes the part-
    // solid skin behind the face FrozenSolid. Omitted / empty => no protection =>
    // byte-identical. A depth <= 0 (or omitted) means "use the core default".
    //
    // TWO FORMS (task 2026-08-12 §0a). The legacy array of ids —
    //     "face_protections": [16]
    // — every protection at the global depth. Or an array of objects carrying a
    // PER-FACE depth, which is what a face marked protect AND "lattice here"
    // emits so its protection is exactly as deep as its lattice region:
    //     "face_protections": [{"face_id": 16, "depth_mm": 7}]
    // Mixing the two forms in one array is REFUSED, never guessed at.
    if (const JsonValue* fp = find_key(lv, "face_protections")) {
      if (fp->type != JsonValue::Type::Array)
        schema_fail("\"face_protections\" must be an array");
      if (fp->arr.empty())
        schema_fail("\"face_protections\" must contain at least one id");
      const bool object_form = fp->arr.front().type == JsonValue::Type::Object;
      for (const JsonValue& e : fp->arr)
        if ((e.type == JsonValue::Type::Object) != object_form)
          schema_fail("\"face_protections\" must be ALL bare face ids or ALL "
                      "{\"face_id\", \"depth_mm\"} objects, never a mix");
      if (!object_form) {
        job.loads.face_protection_face_ids =
            parse_int_array(*fp, "face_protections");
      } else {
        // The object form names EITHER a face_id (handoff 124) OR a region_id
        // (task 2026-08-14-face-regions) — never both, because they are two
        // different things and a protection that claimed to be both would leave
        // the receipt unable to say which one it froze.
        for (const JsonValue& e : fp->arr) {
          reject_unknown_keys(e, {"face_id", "region_id", "depth_mm"},
                              "a face protection");
          const JsonValue* fv = find_key(e, "face_id");
          const JsonValue* rv = find_key(e, "region_id");
          if ((fv == nullptr) == (rv == nullptr))
            schema_fail(
                "a \"face_protections\" entry must give exactly one of "
                "\"face_id\" or \"region_id\"");
          const double id = require_number(
              fv != nullptr ? *fv : *rv,
              fv != nullptr ? "face_protections face_id"
                            : "face_protections region_id");
          if (id < 0.0 || id != std::floor(id))
            schema_fail("every \"face_protections\" id must be a "
                        "non-negative integer");
          double depth = -1.0;  // absent => the global depth
          if (const JsonValue* dv = find_key(e, "depth_mm")) {
            depth = require_number(*dv, "face_protections depth_mm");
            if (!(depth > 0.0))
              schema_fail("a \"face_protections\" depth_mm must be > 0");
          }
          if (fv != nullptr) {
            job.loads.face_protection_face_ids.push_back(static_cast<int>(id));
            job.loads.face_protection_depths_mm.push_back(depth);
          } else {
            job.loads.face_protection_region_ids.push_back(static_cast<int>(id));
            job.loads.face_protection_region_depths_mm.push_back(depth);
          }
        }
      }
    }
    if (const JsonValue* fpd = find_key(lv, "face_protection_depth_mm")) {
      job.loads.face_protection_depth_mm =
          require_number(*fpd, "loads.face_protection_depth_mm");
      if (!(job.loads.face_protection_depth_mm > 0.0))
        schema_fail("\"loads.face_protection_depth_mm\" must be > 0");
    }
    if (const JsonValue* bd = find_key(lv, "build_dir")) {
      job.loads.build_dir = parse_vec3(*bd, "loads.build_dir");
      if (job.loads.build_dir.x == 0.0 && job.loads.build_dir.y == 0.0 &&
          job.loads.build_dir.z == 0.0)
        schema_fail("\"loads.build_dir\" must be non-zero");
    }
    if (const JsonValue* ip = find_key(lv, "infill_percent")) {
      job.loads.infill_percent = require_number(*ip, "loads.infill_percent");
      if (job.loads.infill_percent < 0.0 || job.loads.infill_percent > 100.0)
        schema_fail("\"loads.infill_percent\" must be in [0, 100]");
    }
    if (const JsonValue* mp = find_key(lv, "minimize_plastic")) {
      if (mp->type != JsonValue::Type::Bool)
        schema_fail("\"loads.minimize_plastic\" must be a boolean");
      job.loads.minimize_plastic = (mp->num != 0.0);
    }
    // Width-aware knockdown slicer metadata (handoff 2026-07-26-width-aware-knockdown).
    if (const JsonValue* wl = find_key(lv, "wall_loops")) {
      const double n = require_number(*wl, "loads.wall_loops");
      if (n < 0.0 || n != std::floor(n) || n > 1000.0)
        schema_fail("\"loads.wall_loops\" must be a non-negative integer <= 1000");
      job.loads.wall_loops = static_cast<int>(n);
    }
    if (const JsonValue* ww = find_key(lv, "wall_line_width_mm")) {
      job.loads.wall_line_width_mm =
          require_number(*ww, "loads.wall_line_width_mm");
      if (!(job.loads.wall_line_width_mm > 0.0) ||
          job.loads.wall_line_width_mm > 100.0)
        schema_fail("\"loads.wall_line_width_mm\" must be in (0, 100]");
    }
    // The OUTER-wall line width (handoff line-width-plumbing). Same (0, 100] bound as
    // the inner width; omitted → the JobLoads default -1 (mirror inner), so a job that
    // supplies only wall_line_width_mm is byte-identical to before.
    if (const JsonValue* wwo = find_key(lv, "wall_line_width_outer_mm")) {
      job.loads.wall_line_width_outer_mm =
          require_number(*wwo, "loads.wall_line_width_outer_mm");
      if (!(job.loads.wall_line_width_outer_mm > 0.0) ||
          job.loads.wall_line_width_outer_mm > 100.0)
        schema_fail("\"loads.wall_line_width_outer_mm\" must be in (0, 100]");
    }
  } else {
    // Self-weight mode: fixture_faces (required, non-empty geometric selectors).
    job.fixture_faces =
        parse_selector_array(require_key(root, "fixture_faces", "the job"),
                             "fixture_faces");

    // gravity: direction (3 finite numbers, non-zero) + magnitude.
    {
      const JsonValue& g =
          require_object(require_key(root, "gravity", "the job"), "gravity");
      reject_unknown_keys(g, {"direction", "magnitude_mm_s2"}, "gravity");
      job.gravity.direction =
          parse_vec3(require_key(g, "direction", "gravity"), "gravity.direction");
      const Vec3& d = job.gravity.direction;
      if (d.x * d.x + d.y * d.y + d.z * d.z <= 0.0)
        schema_fail("gravity \"direction\" must be non-zero");
      job.gravity.magnitude_mm_s2 = require_number(
          require_key(g, "magnitude_mm_s2", "gravity"), "magnitude_mm_s2");
      if (!(job.gravity.magnitude_mm_s2 > 0.0))
        schema_fail("gravity \"magnitude_mm_s2\" must be > 0");
    }

    // ladder: non-empty, entries in (0,1], strictly descending (the same rules
    // minimize_plastic enforces — validated here so the diagnostic points at the
    // job file, before any import/solve work).
    {
      const JsonValue& ladder = require_key(root, "ladder", "the job");
      if (ladder.type != JsonValue::Type::Array || ladder.arr.empty())
        schema_fail("\"ladder\" must be a non-empty array of numbers");
      for (const JsonValue& r : ladder.arr) {
        const double f = require_number(r, "ladder entry");
        if (!(f > 0.0) || f > 1.0)
          schema_fail("every \"ladder\" entry must be in (0, 1]");
        if (!job.ladder.empty() && f >= job.ladder.back())
          schema_fail("\"ladder\" must be strictly descending");
        job.ladder.push_back(f);
      }
    }

    job.margin_stop = require_number(
        require_key(root, "margin_stop", "the job"), "margin_stop");
    if (job.margin_stop < 0.0) schema_fail("\"margin_stop\" must be >= 0");
  }

  // design_box + keep_outs: optional in BOTH modes (the "add material" feature).
  if (const JsonValue* db = find_key(root, "design_box")) {
    job.has_design_box = true;
    job.design_box = parse_box(*db, "design_box");
  }
  if (const JsonValue* kos = find_key(root, "keep_outs")) {
    if (kos->type != JsonValue::Type::Array)
      schema_fail("\"keep_outs\" must be an array");
    if (!job.has_design_box && !kos->arr.empty())
      schema_fail("\"keep_outs\" requires a \"design_box\"");
    for (const JsonValue& kv : kos->arr)
      job.keep_out_boxes.push_back(parse_box(kv, "a keep_outs box"));
  }

  // simp: optional; the only key the schema defines is max_iterations.
  if (const JsonValue* simp = find_key(root, "simp")) {
    require_object(*simp, "simp");
    reject_unknown_keys(*simp, {"max_iterations"}, "simp");
    if (const JsonValue* iters = find_key(*simp, "max_iterations"))
      job.simp_max_iterations =
          require_positive_int(*iters, "simp.max_iterations");
  }

  // draft: optional (handoff 2026-07-25-draft-quality). The approximate-trajectory
  // / exact-certification posture. Absent => OFF (byte-identical). `quality` is
  // required inside the block (an empty draft block is a config mistake, not a
  // silent no-op); the two tolerances are optional and default to the option
  // defaults. loose_tol / escalation_c_gap must be finite and >= 0.
  if (const JsonValue* draft = find_key(root, "draft")) {
    require_object(*draft, "draft");
    reject_unknown_keys(*draft,
                        {"quality", "loose_tol", "escalation_c_gap",
                         "use_design_trigger", "escalation_design_flip",
                         "probe_iters"},
                        "draft");
    job.has_draft = true;
    const JsonValue& q = require_key(*draft, "quality", "draft");
    if (q.type != JsonValue::Type::Bool)
      schema_fail("\"draft.quality\" must be a boolean");
    job.draft_quality = (q.num != 0.0);
    if (const JsonValue* lt = find_key(*draft, "loose_tol")) {
      const double v = require_number(*lt, "draft.loose_tol");
      if (v < 0.0) schema_fail("\"draft.loose_tol\" must be >= 0");
      job.draft_loose_tol = v;
    }
    if (const JsonValue* eg = find_key(*draft, "escalation_c_gap")) {
      // A negative value is meaningful (escalate every rung), so only reject
      // non-finite; require_number already rejects NaN/inf.
      job.draft_escalation_c_gap = require_number(*eg, "draft.escalation_c_gap");
    }
    // Handoff 2026-07-26-draft-quality-phase2 — the design-space trigger.
    // use_design_trigger arms it and REPLACES the compliance-gap decision;
    // escalation_design_flip is the threshold (0 = the negative-control floor);
    // probe_iters is the per-reseed OC budget (>= 1).
    if (const JsonValue* ut = find_key(*draft, "use_design_trigger")) {
      if (ut->type != JsonValue::Type::Bool)
        schema_fail("\"draft.use_design_trigger\" must be a boolean");
      job.draft_use_design_trigger = (ut->num != 0.0);
    }
    if (const JsonValue* df = find_key(*draft, "escalation_design_flip")) {
      const double v = require_number(*df, "draft.escalation_design_flip");
      if (v < 0.0) schema_fail("\"draft.escalation_design_flip\" must be >= 0");
      job.draft_escalation_design_flip = v;
    }
    if (const JsonValue* pi = find_key(*draft, "probe_iters")) {
      const double v = require_number(*pi, "draft.probe_iters");
      if (v < 1.0) schema_fail("\"draft.probe_iters\" must be >= 1");
      job.draft_probe_iters = static_cast<int>(v);
    }
  }

  // Optional "warm_start" block (handoff 110 Part B; measured by handoff
  // 2026-08-02-warm-start-coarse-experiment). ABSENT (has_warm_start == false,
  // the DEFAULT) => the driver keeps its OFF default and the run is
  // byte-identical. The block exists so the res/2 coarse pre-solve — built by
  // 110 but never reachable from any production entry point, which is WHY it
  // had never been measured at production scale — can be armed per run without
  // changing any default.
  if (const JsonValue* ws = find_key(root, "warm_start")) {
    require_object(*ws, "warm_start");
    reject_unknown_keys(*ws, {"coarse", "matfree"}, "warm_start");
    job.has_warm_start = true;
    const JsonValue& c = require_key(*ws, "coarse", "warm_start");
    if (c.type != JsonValue::Type::Bool)
      schema_fail("\"warm_start.coarse\" must be a boolean");
    job.warm_start_coarse = (c.num != 0.0);
    // ── THE MATRIX-FREE TRAJECTORY WARM START (task 2026-08-10-plsm-production).
    // Optional inside the block; absent => OFF, the byte-identical default. It
    // arms SimpOptions::matfree_warm_start, which lets the loop's ALREADY-HELD
    // previous displacement field reach the matrix-free solver — the one branch
    // that dropped it until this task. Trajectory-only: the certification solve
    // passes nullptr unconditionally, so no verdict can move.
    if (const JsonValue* mf = find_key(*ws, "matfree")) {
      if (mf->type != JsonValue::Type::Bool)
        schema_fail("\"warm_start.matfree\" must be a boolean");
      job.warm_start_matfree = (mf->num != 0.0);
    }
  }

  // Optional "semdot" block (task 2026-08-08-semdot-does-it-come-out-smoother):
  // the SECOND MODE. ABSENT (has_semdot == false, the DEFAULT) => the driver
  // keeps its OFF default and the run is byte-identical. `enabled` is REQUIRED
  // inside the block (an empty semdot block is a config mistake, not a silent
  // no-op — the same rule "draft" carries); `grid_points` is optional and
  // defaults to kSemdotDefaultGridPoints.
  if (const JsonValue* sd = find_key(root, "semdot")) {
    require_object(*sd, "semdot");
    reject_unknown_keys(*sd, {"enabled", "grid_points"}, "semdot");
    job.has_semdot = true;
    const JsonValue& en = require_key(*sd, "enabled", "semdot");
    if (en.type != JsonValue::Type::Bool)
      schema_fail("\"semdot.enabled\" must be a boolean");
    job.semdot = (en.num != 0.0);
    if (const JsonValue* gp = find_key(*sd, "grid_points")) {
      const double v = require_number(*gp, "semdot.grid_points");
      if (v < 1.0) schema_fail("\"semdot.grid_points\" must be >= 1");
      job.semdot_grid_points = static_cast<int>(v);
    }
  }

  // ── Optional "plsm" block (task 2026-08-10-plsm-production) ───────────────
  //
  // ★ ABSENT (has_plsm == false, THE DEFAULT) => the driver keeps PlsmMode::Off
  // and the run is BYTE-IDENTICAL — R1 of that task is a stash-rebuild checksum
  // of exactly that. `enabled` is REQUIRED inside the block (an empty plsm block
  // is a config mistake, not a silent no-op — the rule "draft" and "semdot"
  // carry).
  //
  // Every other key is OPTIONAL and defaults to the production posture in
  // PlsmOptions. `knots` is the one to read twice: it is THREE numbers, PER AXIS,
  // in VOXELS, and OMITTING it is the right thing — the run then derives the
  // spacing from the grid with `plsm_knots_for_grid`, which is the rule the S2
  // frontier chose and the only thing that follows a change of resolution. A job
  // that names one number for all three axes is refused: there is no scalar knot
  // spacing in this schema, because a scalar is how PR 323 lost a day to
  // `minimum(el_size)` on a 4:1 slab.
  if (const JsonValue* pl = find_key(root, "plsm")) {
    require_object(*pl, "plsm");
    reject_unknown_keys(*pl,
                        {"enabled", "basis", "knots", "support", "eta_voxels",
                         "max_iterations", "seed", "refit_every", "move",
                         "cg_tolerance_loose", "warm_start", "ersatz", "sens_weight",
                         "frac_samples", "frac_eps_mult", "frac_mollified",
                         "frac_sens_exact", "frac_eps_l1",
                         "margin_probe_every", "margin_plateau_probes",
                         "margin_plateau_tol"},
                        "plsm");
    job.has_plsm = true;
    const JsonValue& en = require_key(*pl, "enabled", "plsm");
    if (en.type != JsonValue::Type::Bool)
      schema_fail("\"plsm.enabled\" must be a boolean");
    job.plsm_enabled = (en.num != 0.0);
    if (const JsonValue* b = find_key(*pl, "basis")) {
      job.plsm_basis = require_nonempty_string(*b, "plsm.basis");
      if (job.plsm_basis != "gaussian" && job.plsm_basis != "wendland")
        schema_fail("\"plsm.basis\" must be \"gaussian\" or \"wendland\"");
    }
    if (const JsonValue* k = find_key(*pl, "knots")) {
      if (k->type != JsonValue::Type::Array || k->arr.size() != 3)
        schema_fail(
            "\"plsm.knots\" must be an array of exactly 3 numbers — the knot "
            "spacing in VOXELS, PER AXIS. There is no scalar form: one number "
            "for three axes is the slab trap this schema refuses to offer. Omit "
            "the key to let the run derive the spacing from the grid.");
      double* dst[3] = {&job.plsm_knots[0], &job.plsm_knots[1], &job.plsm_knots[2]};
      for (std::size_t i = 0; i < 3; ++i) {
        const double v = require_number(k->arr[i], "plsm.knots");
        if (!(v > 0.0)) schema_fail("\"plsm.knots\" entries must be > 0");
        *dst[i] = v;
      }
    }
    if (const JsonValue* v = find_key(*pl, "support")) {
      const double x = require_number(*v, "plsm.support");
      if (!(x >= 1.0)) schema_fail("\"plsm.support\" must be >= 1");
      job.plsm_support = x;
    }
    if (const JsonValue* v = find_key(*pl, "eta_voxels")) {
      const double x = require_number(*v, "plsm.eta_voxels");
      if (!(x > 0.0)) schema_fail("\"plsm.eta_voxels\" must be > 0");
      job.plsm_eta_voxels = x;
    }
    if (const JsonValue* v = find_key(*pl, "max_iterations")) {
      const double x = require_number(*v, "plsm.max_iterations");
      if (x < 1.0) schema_fail("\"plsm.max_iterations\" must be >= 1");
      job.plsm_max_iterations = static_cast<int>(x);
    }
    if (const JsonValue* v = find_key(*pl, "seed")) {
      job.plsm_seed = require_nonempty_string(*v, "plsm.seed");
      if (job.plsm_seed != "inherit" && job.plsm_seed != "holes")
        schema_fail("\"plsm.seed\" must be \"inherit\" or \"holes\"");
    }
    if (const JsonValue* v = find_key(*pl, "refit_every")) {
      const double x = require_number(*v, "plsm.refit_every");
      if (x < 0.0) schema_fail("\"plsm.refit_every\" must be >= 0");
      job.plsm_refit_every = static_cast<int>(x);
    }
    if (const JsonValue* v = find_key(*pl, "move")) {
      const double x = require_number(*v, "plsm.move");
      if (!(x > 0.0)) schema_fail("\"plsm.move\" must be > 0");
      job.plsm_move = x;
    }
    if (const JsonValue* v = find_key(*pl, "cg_tolerance_loose")) {
      const double x = require_number(*v, "plsm.cg_tolerance_loose");
      if (!(x >= 0.0)) schema_fail("\"plsm.cg_tolerance_loose\" must be >= 0");
      job.plsm_cg_tolerance_loose = x;
    }
    if (const JsonValue* v = find_key(*pl, "warm_start")) {
      if (v->type != JsonValue::Type::Bool)
        schema_fail("\"plsm.warm_start\" must be a boolean");
      job.plsm_warm_start = (v->num != 0.0);
    }
    // ── the volume-fraction ersatz (task 2026-08-13, item 2) ────────────────
    if (const JsonValue* v = find_key(*pl, "ersatz")) {
      job.plsm_ersatz = require_nonempty_string(*v, "plsm.ersatz");
      if (job.plsm_ersatz != "fraction" && job.plsm_ersatz != "heaviside")
        schema_fail(
            "\"plsm.ersatz\" must be \"fraction\" (the exact cell volume "
            "fraction inside {phi < 0}, the production default) or "
            "\"heaviside\" (the centre-sampled smoothed step it replaces)");
    }
    if (const JsonValue* v = find_key(*pl, "sens_weight")) {
      job.plsm_sens_weight = require_nonempty_string(*v, "plsm.sens_weight");
      if (job.plsm_sens_weight != "discrete" &&
          job.plsm_sens_weight != "continuum")
        schema_fail(
            "\"plsm.sens_weight\" must be \"discrete\" (the derivative of the "
            "stiffness law production actually runs, the default) or "
            "\"continuum\" (the classical shape derivative's strain-energy "
            "density, which is correct only for a LINEAR law and which R2 "
            "measured 45-56% off on this path)");
    }
    if (const JsonValue* v = find_key(*pl, "frac_samples")) {
      const double x = require_number(*v, "plsm.frac_samples");
      if (x < 2.0 || x > 16.0)
        schema_fail(
            "\"plsm.frac_samples\" must be in [2, 16] — 1 would put the only "
            "sample back at the cell centre, which is the approximation the "
            "volume fraction replaces");
      job.plsm_frac_samples = static_cast<int>(x);
    }
    if (const JsonValue* v = find_key(*pl, "frac_eps_mult")) {
      const double x = require_number(*v, "plsm.frac_eps_mult");
      if (!(x > 0.0)) schema_fail("\"plsm.frac_eps_mult\" must be > 0");
      job.plsm_frac_eps_mult = x;
    }
    if (const JsonValue* v = find_key(*pl, "frac_mollified")) {
      if (v->type != JsonValue::Type::Bool)
        schema_fail("\"plsm.frac_mollified\" must be a boolean");
      job.plsm_frac_mollified = (v->num != 0.0);
    }
    if (const JsonValue* v = find_key(*pl, "frac_sens_exact")) {
      if (v->type != JsonValue::Type::Bool)
        schema_fail("\"plsm.frac_sens_exact\" must be a boolean");
      job.plsm_frac_sens_exact = (v->num != 0.0);
    }
    if (const JsonValue* v = find_key(*pl, "frac_eps_l1")) {
      if (v->type != JsonValue::Type::Bool)
        schema_fail("\"plsm.frac_eps_l1\" must be a boolean");
      job.plsm_frac_eps_l1 = (v->num != 0.0);
    }
    // ── the margin-plateau stop (task 2026-08-13, item 3) ───────────────────
    if (const JsonValue* v = find_key(*pl, "margin_probe_every")) {
      const double x = require_number(*v, "plsm.margin_probe_every");
      if (x < 0.0) schema_fail("\"plsm.margin_probe_every\" must be >= 0 (0 = off)");
      job.plsm_margin_probe_every = static_cast<int>(x);
    }
    if (const JsonValue* v = find_key(*pl, "margin_plateau_probes")) {
      const double x = require_number(*v, "plsm.margin_plateau_probes");
      if (x < 1.0) schema_fail("\"plsm.margin_plateau_probes\" must be >= 1");
      job.plsm_margin_plateau_probes = static_cast<int>(x);
    }
    if (const JsonValue* v = find_key(*pl, "margin_plateau_tol")) {
      const double x = require_number(*v, "plsm.margin_plateau_tol");
      if (!(x >= 0.0)) schema_fail("\"plsm.margin_plateau_tol\" must be >= 0");
      job.plsm_margin_plateau_tol = x;
    }
  }

  // output block.
  {
    const JsonValue& out =
        require_object(require_key(root, "output", "the job"), "output");
    reject_unknown_keys(
        out,
        {"report", "mesh_format", "mesh_prefix", "smooth_factor",
         "project_cad_faces"},
        "output");
    job.output.report = require_nonempty_string(
        require_key(out, "report", "output"), "output.report");
    job.output.mesh_format = require_nonempty_string(
        require_key(out, "mesh_format", "output"), "output.mesh_format");
    if (job.output.mesh_format != "3mf" && job.output.mesh_format != "stl")
      schema_fail("output \"mesh_format\" must be \"3mf\" or \"stl\" (got \"" +
                  job.output.mesh_format + "\")");
    job.output.mesh_prefix = require_nonempty_string(
        require_key(out, "mesh_prefix", "output"), "output.mesh_prefix");
    // Optional smooth-export factor (handoff 086); absent => 1 (native export).
    if (const JsonValue* sf = find_key(out, "smooth_factor")) {
      job.output.smooth_factor =
          require_positive_int(*sf, "output.smooth_factor");
      if (job.output.smooth_factor < 1 || job.output.smooth_factor > 4)
        schema_fail("output \"smooth_factor\" must be in [1, 4] (got " +
                    std::to_string(job.output.smooth_factor) + ")");
    }
    // Optional CAD-face projection (task 2026-08-06-cad-face-projection);
    // absent => false, and the exported bytes are unchanged.
    if (const JsonValue* p = find_key(out, "project_cad_faces")) {
      if (p->type != JsonValue::Type::Bool)
        schema_fail("output \"project_cad_faces\" must be a boolean");
      job.output.project_cad_faces = (p->num != 0.0);
    }
  }

  // Optional "lattice" block (handoff 2026-07-28-lattice-generation-production).
  // Absent => present stays false and the run is byte-identical (the P1 bar).
  // A "grading" block changes what the lattice block may carry (see below), so
  // its presence is looked up first.
  const bool has_grading_block = find_key(root, "grading") != nullptr;
  if (const JsonValue* latv = find_key(root, "lattice")) {
    const JsonValue& lat = require_object(*latv, "lattice");
    reject_unknown_keys(lat,
                        {"topology", "cell_mm", "strut_radius_mm", "emit_stl",
                         "emit_3mf", "skin", "min_extrudable_width_mm",
                         "outer_finish", "regions", "multiscale",
                         "forecast_only",
                         "require_lattice_void_reaches_exterior"},
                        "lattice");
    job.lattice.present = true;
    if (const JsonValue* t = find_key(lat, "topology")) {
      job.lattice.topology = require_nonempty_string(*t, "lattice.topology");
      if (job.lattice.topology != "octet")
        schema_fail("lattice \"topology\" must be \"octet\" (got \"" +
                    job.lattice.topology + "\")");
    }
    // Uniform geometry (cell_mm + strut_radius_mm): REQUIRED without a "grading"
    // block, REJECTED with one — a graded run derives the cell from
    // grading.cell_mm (raised to the printability floor) and the strut radii
    // from the run's own graded densities, so a uniform cell/radius here would
    // conflict and is refused rather than silently ignored (stage 4).
    if (has_grading_block) {
      for (const char* k : {"cell_mm", "strut_radius_mm"})
        if (find_key(lat, k))
          schema_fail(std::string("lattice \"") + k +
                      "\" is not allowed with a \"grading\" block: a graded run "
                      "derives the cell size from grading.cell_mm (raised to the "
                      "printability floor) and the strut radii from the run's own "
                      "graded densities");
    } else {
      job.lattice.cell_mm = require_number(
          require_key(lat, "cell_mm", "lattice"), "lattice.cell_mm");
      if (!(job.lattice.cell_mm > 0.0))
        schema_fail("lattice \"cell_mm\" must be > 0");
      job.lattice.strut_radius_mm =
          require_number(require_key(lat, "strut_radius_mm", "lattice"),
                         "lattice.strut_radius_mm");
      if (!(job.lattice.strut_radius_mm > 0.0))
        schema_fail("lattice \"strut_radius_mm\" must be > 0");
    }
    // Lattice ROLE regions (task lattice-page-core-hookup stage 1) — the
    // lattice.regions schema PR 254 proposed. Absent/empty => whole-part
    // lattice, byte-identical. Each entry is {role, kind, geometry} with the
    // SAME manual-primitive geometry a manual clearance carries; a malformed
    // role/kind is REFUSED, never defaulted (H1e).
    if (const JsonValue* regs = find_key(lat, "regions")) {
      if (regs->type != JsonValue::Type::Array)
        schema_fail("\"lattice.regions\" must be an array");
      for (const JsonValue& rv : regs->arr) {
        require_object(rv, "a lattice region");
        reject_unknown_keys(rv, {"role", "kind", "geometry", "face_id"},
                            "a lattice region");
        JobLatticeRegion reg;
        // Optional provenance: the B-rep face this region was spawned from, so
        // the depth tie below can be CHECKED (task 2026-08-12 §0a).
        if (const JsonValue* fv = find_key(rv, "face_id")) {
          const double d = require_number(*fv, "lattice region face_id");
          if (d < 0.0 || d != std::floor(d))
            schema_fail("a lattice region \"face_id\" must be a non-negative "
                        "integer");
          reg.face_id = static_cast<int>(d);
        }
        reg.role = require_nonempty_string(
            require_key(rv, "role", "a lattice region"), "lattice region role");
        if (reg.role != "include" && reg.role != "exclude")
          schema_fail("a lattice region \"role\" must be \"include\" or "
                      "\"exclude\" (got \"" + reg.role + "\")");
        reg.kind = require_nonempty_string(
            require_key(rv, "kind", "a lattice region"), "lattice region kind");
        if (reg.kind != "bolt" && reg.kind != "face")
          schema_fail("a lattice region \"kind\" must be \"bolt\" or \"face\" "
                      "(got \"" + reg.kind + "\")");
        const JsonValue& gv = require_object(
            require_key(rv, "geometry", "a lattice region"),
            "lattice region geometry");
        if (reg.kind == "bolt") {
          reject_unknown_keys(
              gv, {"axis_point", "axis_dir", "radius_mm", "half_length_mm"},
              "a bolt lattice region geometry");
          reg.axis_point = parse_vec3(
              require_key(gv, "axis_point", "a bolt lattice region geometry"),
              "lattice region axis_point");
          reg.axis_dir = parse_vec3(
              require_key(gv, "axis_dir", "a bolt lattice region geometry"),
              "lattice region axis_dir");
          reg.radius_mm = require_number(
              require_key(gv, "radius_mm", "a bolt lattice region geometry"),
              "lattice region radius_mm");
          reg.half_length_mm = require_number(
              require_key(gv, "half_length_mm", "a bolt lattice region geometry"),
              "lattice region half_length_mm");
          if (!(reg.radius_mm > 0.0) || !(reg.half_length_mm > 0.0))
            schema_fail("a bolt lattice region radius_mm/half_length_mm must be "
                        "> 0 (a zero-extent region marks nothing)");
          const Vec3& ad = reg.axis_dir;
          if (ad.x * ad.x + ad.y * ad.y + ad.z * ad.z <= 0.0)
            schema_fail("a bolt lattice region \"axis_dir\" must be non-zero");
        } else {  // face
          reject_unknown_keys(
              gv, {"origin", "normal", "half_u_mm", "half_w_mm", "depth_mm"},
              "a face lattice region geometry");
          reg.origin = parse_vec3(
              require_key(gv, "origin", "a face lattice region geometry"),
              "lattice region origin");
          reg.normal = parse_vec3(
              require_key(gv, "normal", "a face lattice region geometry"),
              "lattice region normal");
          reg.half_u_mm = require_number(
              require_key(gv, "half_u_mm", "a face lattice region geometry"),
              "lattice region half_u_mm");
          reg.half_w_mm = require_number(
              require_key(gv, "half_w_mm", "a face lattice region geometry"),
              "lattice region half_w_mm");
          reg.depth_mm = require_number(
              require_key(gv, "depth_mm", "a face lattice region geometry"),
              "lattice region depth_mm");
          if (!(reg.half_u_mm > 0.0) || !(reg.half_w_mm > 0.0) ||
              !(reg.depth_mm > 0.0))
            schema_fail("a face lattice region half_u_mm/half_w_mm/depth_mm "
                        "must be > 0 (a zero-extent region marks nothing)");
          const Vec3& nn = reg.normal;
          if (nn.x * nn.x + nn.y * nn.y + nn.z * nn.z <= 0.0)
            schema_fail("a face lattice region \"normal\" must be non-zero");
        }
        job.lattice.regions.push_back(std::move(reg));
      }
    }
    // MULTISCALE (task multiscale-lattice-to). Absent => false => the two-step
    // pipeline, byte-identical. It needs a "grading" block: a multiscale design is
    // graded by construction (every latticed voxel carries its OWN density), so
    // asking for it without one is a contradiction, refused here rather than
    // silently ignored.
    if (const JsonValue* m = find_key(lat, "multiscale")) {
      if (m->type != JsonValue::Type::Bool)
        schema_fail("lattice \"multiscale\" must be a boolean");
      job.lattice.multiscale = (m->num != 0.0);
      if (job.lattice.multiscale && !has_grading_block)
        schema_fail(
            "lattice \"multiscale\" requires a \"grading\" block: a multiscale "
            "design is graded by construction (every latticed voxel carries its "
            "own relative density)");
    }
    if (const JsonValue* s = find_key(lat, "emit_stl")) {
      if (s->type != JsonValue::Type::Bool)
        schema_fail("lattice \"emit_stl\" must be a boolean");
      job.lattice.emit_stl = (s->num != 0.0);
    }
    if (const JsonValue* m = find_key(lat, "emit_3mf")) {
      if (m->type != JsonValue::Type::Bool)
        schema_fail("lattice \"emit_3mf\" must be a boolean");
      job.lattice.emit_3mf = (m->num != 0.0);
    }
    if (!job.lattice.emit_stl && !job.lattice.emit_3mf)
      schema_fail("lattice block requests neither STL nor 3MF output");
    // Boundary finish (handoff 2026-07-29-lattice-boundary-finish). "skin"
    // picks the finish; the clip to part + clearance keep-outs is not optional.
    if (const JsonValue* s = find_key(lat, "skin")) {
      job.lattice.skin = require_nonempty_string(*s, "lattice.skin");
      if (job.lattice.skin != "none" && job.lattice.skin != "rim" &&
          job.lattice.skin != "diagrid")
        schema_fail("lattice \"skin\" must be \"none\", \"rim\" or \"diagrid\" "
                    "(got \"" + job.lattice.skin + "\")");
    }
    if (const JsonValue* w = find_key(lat, "min_extrudable_width_mm")) {
      job.lattice.min_extrudable_width_mm =
          require_number(*w, "lattice.min_extrudable_width_mm");
      if (!(job.lattice.min_extrudable_width_mm > 0.0))
        schema_fail("lattice \"min_extrudable_width_mm\" must be > 0");
    }
    // Outer finish (task 2026-07-30-lattice-skin-freeform). Absent => "shell",
    // byte-identical to the boundary-finish behaviour.
    if (const JsonValue* f = find_key(lat, "outer_finish")) {
      job.lattice.outer_finish =
          require_nonempty_string(*f, "lattice.outer_finish");
      if (job.lattice.outer_finish != "shell" &&
          job.lattice.outer_finish != "skin" &&
          job.lattice.outer_finish != "shell+skin")
        schema_fail("lattice \"outer_finish\" must be \"shell\", \"skin\" or "
                    "\"shell+skin\" (got \"" + job.lattice.outer_finish + "\")");
      if (job.lattice.outer_finish != "shell" && job.lattice.skin != "diagrid")
        schema_fail("lattice outer_finish \"" + job.lattice.outer_finish +
                    "\" needs skin \"diagrid\" — the diagrid IS the outer "
                    "finish that replaces or dresses the shell");
    }
    // THE PRE-FLIGHT FORECAST (task 2026-08-03-variant-postprocessing-fix, bar
    // F3). Absent => false => every existing job runs exactly as it did.
    if (const JsonValue* fo = find_key(lat, "forecast_only")) {
      if (fo->type != JsonValue::Type::Bool)
        schema_fail("lattice \"forecast_only\" must be a boolean");
      job.lattice.forecast_only = (fo->num != 0.0);
    }
    // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
    // Absent => false => every existing job runs, and writes, exactly as it did.
    if (const JsonValue* rv =
            find_key(lat, "require_lattice_void_reaches_exterior")) {
      if (rv->type != JsonValue::Type::Bool)
        schema_fail("lattice \"require_lattice_void_reaches_exterior\" must be "
                    "a boolean");
      job.lattice.require_lattice_void_reaches_exterior = (rv->num != 0.0);
    }
  }

  // Optional "grading" block (handoff 2026-07-29-lattice-grading-law). Absent =>
  // present stays false and the run is byte-identical (bar L1). The certifiable band
  // and cells-per-member floor are NOT job knobs — the law reads them from core — so
  // they are not accepted here.
  if (const JsonValue* gradv = find_key(root, "grading")) {
    const JsonValue& gr = require_object(*gradv, "grading");
    reject_unknown_keys(
        gr, {"topology", "cell_mm", "min_extrudable_width_mm", "demand_exponent",
             "cell_mode", "cell_min_mm", "cell_max_mm",
             "retain_subfloor_in_unloaded_regions", "subfloor_stress_fraction",
             "subfloor_aggregate_cap", "report_region_cells",
             "subfloor_per_region"},
        "grading");
    job.grading.present = true;
    if (const JsonValue* t = find_key(gr, "topology")) {
      job.grading.topology = require_nonempty_string(*t, "grading.topology");
      if (job.grading.topology != "octet")
        schema_fail("grading \"topology\" must be \"octet\" (got \"" +
                    job.grading.topology + "\")");
    }
    // Cell-size mode (handoff 2026-08-01-lattice-cell-size-sweep). Absent => "fixed",
    // which is the pre-sweep schema exactly: cell_mm required, no ladder keys.
    if (const JsonValue* m = find_key(gr, "cell_mode")) {
      job.grading.cell_mode = require_nonempty_string(*m, "grading.cell_mode");
      CellSizeMode parsed;
      if (!cell_size_mode_from_name(job.grading.cell_mode.c_str(), parsed))
        schema_fail(
            "grading \"cell_mode\" must be \"fixed\", \"auto\", \"swept\" or "
            "\"fit\" (got \"" + job.grading.cell_mode + "\")");
    }
    const bool swept = job.grading.cell_mode == "swept";
    const bool auto_cell = job.grading.cell_mode == "auto";
    // FIT (task 2026-08-05-lattice-cell-fit-mode). The cell is DERIVED per declared
    // include region, so like "auto" it takes no target — and unlike any other mode it
    // needs somewhere to derive FROM.
    const bool fit_cell = job.grading.cell_mode == "fit";
    if (swept) {
      // A target cell alongside a ladder is a CONFLICT, not a hint: refuse it rather
      // than silently ignore one of the two.
      if (find_key(gr, "cell_mm"))
        schema_fail(
            "grading \"cell_mm\" is not allowed with \"cell_mode\": \"swept\" — the "
            "swept ladder is set by \"cell_min_mm\" and \"cell_max_mm\"");
      job.grading.cell_min_mm = require_number(
          require_key(gr, "cell_min_mm", "grading"), "grading.cell_min_mm");
      job.grading.cell_max_mm = require_number(
          require_key(gr, "cell_max_mm", "grading"), "grading.cell_max_mm");
      if (!(job.grading.cell_min_mm > 0.0))
        schema_fail("grading \"cell_min_mm\" must be > 0");
      if (!(job.grading.cell_max_mm >= job.grading.cell_min_mm))
        schema_fail("grading \"cell_max_mm\" must be >= \"cell_min_mm\"");
    } else {
      if (find_key(gr, "cell_min_mm") || find_key(gr, "cell_max_mm"))
        schema_fail(
            "grading \"cell_min_mm\" / \"cell_max_mm\" are only allowed with "
            "\"cell_mode\": \"swept\"");
      if (auto_cell || fit_cell) {
        // Core picks the cell; a stated target would be ignored, so refuse it.
        if (find_key(gr, "cell_mm"))
          schema_fail(
              std::string("grading \"cell_mm\" is not allowed with "
                          "\"cell_mode\": \"") +
              (fit_cell ? "fit\" — core derives the cell from each declared include "
                          "region's own extent"
                        : "auto\" — core chooses the cell from the printability "
                          "floor"));
      } else {
        job.grading.cell_mm =
            require_number(require_key(gr, "cell_mm", "grading"), "grading.cell_mm");
        if (!(job.grading.cell_mm > 0.0))
          schema_fail("grading \"cell_mm\" must be > 0");
      }
    }
    job.grading.min_extrudable_width_mm = require_number(
        require_key(gr, "min_extrudable_width_mm", "grading"),
        "grading.min_extrudable_width_mm");
    if (!(job.grading.min_extrudable_width_mm > 0.0))
      schema_fail("grading \"min_extrudable_width_mm\" must be > 0");
    if (const JsonValue* e = find_key(gr, "demand_exponent")) {
      job.grading.demand_exponent = require_number(*e, "grading.demand_exponent");
      if (!(job.grading.demand_exponent > 0.0))
        schema_fail("grading \"demand_exponent\" must be > 0");
    }
    // SUB-FLOOR RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions).
    // Absent => false => bit-identical (bar S1).
    if (const JsonValue* r =
            find_key(gr, "retain_subfloor_in_unloaded_regions")) {
      if (r->type != JsonValue::Type::Bool)
        schema_fail(
            "grading \"retain_subfloor_in_unloaded_regions\" must be a boolean");
      job.grading.retain_subfloor_in_unloaded_regions = (r->num != 0.0);
    }
    if (const JsonValue* f = find_key(gr, "subfloor_stress_fraction")) {
      // A threshold stated WITHOUT arming retention is a job that means one thing and
      // says another — refuse it rather than silently ignore the number.
      if (!job.grading.retain_subfloor_in_unloaded_regions)
        schema_fail(
            "grading \"subfloor_stress_fraction\" is only allowed with "
            "\"retain_subfloor_in_unloaded_regions\": true");
      job.grading.subfloor_stress_fraction =
          require_number(*f, "grading.subfloor_stress_fraction");
      if (!(job.grading.subfloor_stress_fraction > 0.0 &&
            job.grading.subfloor_stress_fraction <= 1.0))
        schema_fail(
            "grading \"subfloor_stress_fraction\" must be > 0 and <= 1 (a fraction "
            "of the part's PEAK von Mises, not a percentage)");
    }
    if (const JsonValue* c = find_key(gr, "subfloor_aggregate_cap")) {
      // Same rule as the stress fraction: a cap stated WITHOUT arming retention is
      // a job that means one thing and says another.
      if (!job.grading.retain_subfloor_in_unloaded_regions)
        schema_fail(
            "grading \"subfloor_aggregate_cap\" is only allowed with "
            "\"retain_subfloor_in_unloaded_regions\": true");
      job.grading.subfloor_aggregate_cap =
          require_number(*c, "grading.subfloor_aggregate_cap");
      if (!(job.grading.subfloor_aggregate_cap > 0.0 &&
            job.grading.subfloor_aggregate_cap <= 1.0))
        schema_fail(
            "grading \"subfloor_aggregate_cap\" must be > 0 and <= 1 (a fraction of "
            "the PRINTED set, not a percentage)");
    }
    // ── Stage A/E: the per-region cell derivation REPORT. Additive and decision-
    // free, so unlike the retention keys it carries no companion requirement.
    if (const JsonValue* r = find_key(gr, "report_region_cells")) {
      if (r->type != JsonValue::Type::Bool)
        schema_fail("grading \"report_region_cells\" must be a boolean");
      job.grading.report_region_cells = (r->num != 0.0);
    }
    // ── Stage B: per-region evaluation of the retention predicate. It only means
    // anything with retention armed, and a job that asks for it WITHOUT arming
    // retention means one thing and says another — the same rule the two keys
    // above already apply, for the same reason.
    if (const JsonValue* p = find_key(gr, "subfloor_per_region")) {
      if (p->type != JsonValue::Type::Bool)
        schema_fail("grading \"subfloor_per_region\" must be a boolean");
      if ((p->num != 0.0) && !job.grading.retain_subfloor_in_unloaded_regions)
        schema_fail(
            "grading \"subfloor_per_region\" is only allowed with "
            "\"retain_subfloor_in_unloaded_regions\": true — it changes HOW the "
            "unloaded-region predicate is evaluated, and there is no predicate to "
            "evaluate without retention");
      job.grading.subfloor_per_region = (p->num != 0.0);
    }
  }

  // ── "variant": the finished design to lattice (task
  // 2026-08-02-lattice-a-variant). THE CONTRACT is that a lattice_variant job is
  // the ORIGINAL RUN'S JOB with `mode` changed and `variant` + a lattice/grading
  // block added — the load case is not re-authored, it is re-used. That is what
  // makes bar Z2 ("the load case is the SAME one") a property of the document
  // rather than of a reconstruction: the anchors, the force groups, the
  // clearances, the protections, the resolution and the material are the same
  // bytes that produced the variant. `ladder` keeps its self-weight-mode
  // requirement and is UNUSED here (no ladder runs) — required rather than
  // rejected precisely so the original job can be reused verbatim.
  if (const JsonValue* vv = find_key(root, "variant")) {
    if (job.mode != "lattice_variant")
      schema_fail(
          "\"variant\" is only allowed with \"mode\": \"lattice_variant\" (got "
          "mode \"" +
          job.mode + "\")");
    const JsonValue& v = require_object(*vv, "variant");
    reject_unknown_keys(v,
                        {"design", "index", "volume_fraction", "fingerprint",
                         "achieved_volume_fraction"},
                        "variant");
    job.variant.present = true;
    job.variant.design = require_nonempty_string(
        require_key(v, "design", "variant"), "variant.design");
    const JsonValue* iv = find_key(v, "index");
    const JsonValue* fv = find_key(v, "volume_fraction");
    const JsonValue* pv = find_key(v, "fingerprint");
    const int selectors = (iv != nullptr) + (fv != nullptr) + (pv != nullptr);
    if (selectors != 1)
      schema_fail(
          "a \"variant\" must give EXACTLY ONE of \"index\", "
          "\"volume_fraction\" or \"fingerprint\"");
    if (iv != nullptr) {
      const double d = require_number(*iv, "variant.index");
      if (d < 0.0 || d != std::floor(d))
        schema_fail("\"variant.index\" must be a non-negative integer");
      job.variant.has_index = true;
      job.variant.index = static_cast<int>(d);
    } else if (fv != nullptr) {
      job.variant.volume_fraction =
          require_number(*fv, "variant.volume_fraction");
      if (!(job.variant.volume_fraction > 0.0) ||
          job.variant.volume_fraction > 1.0)
        schema_fail("\"variant.volume_fraction\" must be in (0, 1]");
      job.variant.has_volume_fraction = true;
    } else {
      // The design FINGERPRINT, as a DECIMAL STRING — see JobVariantRef. A u64
      // does not round-trip through a JSON double (the maintainer's 1.10 rung
      // hashes to 2898949975693851963, which a double cannot hold), so the wire
      // form is text and the parse is exact or it fails.
      const std::string s =
          require_nonempty_string(*pv, "variant.fingerprint");
      if (s.find_first_not_of("0123456789") != std::string::npos)
        schema_fail(
            "\"variant.fingerprint\" must be the design fingerprint as a "
            "DECIMAL STRING of digits (got \"" +
            s + "\")");
      try {
        std::size_t used = 0;
        job.variant.fingerprint = std::stoull(s, &used);
        if (used != s.size()) throw std::invalid_argument("trailing");
      } catch (const std::exception&) {
        schema_fail("\"variant.fingerprint\" is not a 64-bit unsigned value (\"" +
                    s + "\")");
      }
      job.variant.has_fingerprint = true;
    }
    // The variant's OWN achieved fraction, carried so the job can be CHECKED
    // against the container rather than trusted. Deliberately un-bounded above:
    // a growth ladder's achieved fraction is part-relative and exceeds 1.
    if (const JsonValue* av = find_key(v, "achieved_volume_fraction")) {
      job.variant.achieved_volume_fraction =
          require_number(*av, "variant.achieved_volume_fraction");
      if (!(job.variant.achieved_volume_fraction > 0.0))
        schema_fail("\"variant.achieved_volume_fraction\" must be > 0");
      job.variant.has_achieved_volume_fraction = true;
    }
  } else if (job.mode == "lattice_variant") {
    schema_fail(
        "\"mode\": \"lattice_variant\" requires a \"variant\" block naming the "
        "finished design to lattice (its run's design.bin + which rung)");
  }
  // A lattice_variant job with no lattice work to do is a mistake, not a no-op:
  // refuse it here rather than run three certification solves and write a file
  // identical to one the run already produced.
  if (job.mode == "lattice_variant" && !job.lattice.present)
    schema_fail(
        "\"mode\": \"lattice_variant\" requires a \"lattice\" block — there is "
        "nothing to lattice without one");

  // ── FIT's two cross-field requirements (task 2026-08-05-lattice-cell-fit-mode).
  // Checked here rather than in the grading block because both are about the LATTICE
  // block, which parses after it.
  if (job.grading.present && job.grading.cell_mode == "fit") {
    // (1) FIT DERIVES THE CELL FROM A DECLARED REGION, so there must be one. Without
    // an include region there is no stated requirement to fit — and the design's own
    // measured member width is NOT a substitute: it is what the optimizer produced,
    // not what the user asked to lattice.
    std::size_t includes = 0;
    for (const JobLatticeRegion& r : job.lattice.regions)
      if (r.role == "include") ++includes;
    if (includes == 0)
      schema_fail(
          "grading \"cell_mode\": \"fit\" needs at least one lattice region with "
          "\"role\": \"include\" — fit derives the cell from what each declared "
          "region has to fit into, and a job that declares none states no "
          "requirement to fit. Use \"auto\" or \"fixed\" for a whole-part lattice.");
    // (see also the depth tie below — it applies to every mode, not just fit)
    // (2) Two mechanisms for the same voxel, with two receipts. See grade_lattice.
    if (job.grading.retain_subfloor_in_unloaded_regions)
      schema_fail(
          "grading \"cell_mode\": \"fit\" and "
          "\"retain_subfloor_in_unloaded_regions\" are mutually exclusive — fit "
          "already derives a cell per region and reports the out-of-regime material "
          "it emits");
  }

  // ★★ THE DEPTH TIE (task 2026-08-12 §0a, bar R2). A face marked protect AND
  // "lattice here" is ONE slab: the depth the user drags is how deep TO may not
  // cut AND how deep the lattice is allowed. When a face-kind lattice region
  // NAMES the protected face it came from, the two must be the SAME NUMBER.
  // They must not differ silently, so a job stating two is refused with both
  // figures rather than run into the failure it encodes — TO removing everything
  // past the shallower one, and the lattice pass then finding material only in
  // the frozen skin (79% of everything latticed, on the maintainer's own run).
  //
  // Checked only when the region carries `face_id`; the app always emits it. A
  // hand-authored job with no id keeps the pre-task freedom, unchecked.
  for (const JobLatticeRegion& r : job.lattice.regions) {
    if (r.kind != "face" || r.face_id < 0) continue;
    for (std::size_t i = 0; i < job.loads.face_protection_face_ids.size(); ++i) {
      if (job.loads.face_protection_face_ids[i] != r.face_id) continue;
      double prot = job.loads.face_protection_depth_mm;   // <= 0 => core default
      if (i < job.loads.face_protection_depths_mm.size() &&
          job.loads.face_protection_depths_mm[i] > 0.0)
        prot = job.loads.face_protection_depths_mm[i];
      if (!(prot > 0.0)) prot = kFaceProtectionDepthDefaultMm;
      if (std::abs(prot - r.depth_mm) > 1e-9)
        schema_fail(
            "face " + std::to_string(r.face_id) + " is BOTH protected and a "
            "lattice region, at two different depths: the protection is " +
            std::to_string(prot) + " mm and the lattice region is " +
            std::to_string(r.depth_mm) +
            " mm. They are one slab — the depth the face is held to IS the depth "
            "the lattice is allowed. A protection shallower than its region "
            "leaves the rest of that region as void the optimizer removed, and a "
            "lattice cannot conjure material there.");
    }
  }

  return job;
}

JobDescription load_job_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw JobError("cannot open job file: " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return parse_job(ss.str());
}

}  // namespace topopt
