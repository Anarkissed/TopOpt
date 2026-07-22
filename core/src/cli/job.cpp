#include "topopt/job.hpp"

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
                      {"model", "material", "mode", "resolution",
                       "fixture_faces", "gravity", "ladder", "margin_stop",
                       "simp", "output", "loads", "design_box", "keep_outs"},
                      "the job");

  JobDescription job;
  job.model =
      require_nonempty_string(require_key(root, "model", "the job"), "model");
  job.material = require_nonempty_string(
      require_key(root, "material", "the job"), "material");
  job.mode =
      require_nonempty_string(require_key(root, "mode", "the job"), "mode");
  if (job.mode != "minimize_plastic")
    schema_fail("\"mode\" must be \"minimize_plastic\" (got \"" + job.mode +
                "\")");
  job.resolution = require_positive_int(
      require_key(root, "resolution", "the job"), "resolution");

  // The run is in LOADCASE mode iff a "loads" block is present. In that mode the
  // anchors are the fixtures, the groups are the design load, and the production
  // ladder / fixed self-weight magnitude / default margin apply (exactly the app
  // path) — so the self-weight keys are MEANINGLESS and rejected rather than
  // silently ignored. In SELF-WEIGHT mode (no "loads") they are required as before.
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
        lv, {"anchors", "anchor_face_ids", "groups", "clearances",
             "face_protections", "face_protection_depth_mm", "build_dir",
             "infill_percent", "minimize_plastic"},
        "loads");
    job.loads.present = true;
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
        reject_unknown_keys(gv, {"faces", "face_ids", "force"}, "a loads group");
        JobLoadGroup grp;
        if (const JsonValue* fs = find_key(gv, "faces"))
          grp.faces = parse_selector_array(*fs, "faces");
        if (const JsonValue* fid = find_key(gv, "face_ids"))
          grp.face_ids = parse_int_array(*fid, "face_ids");
        if (grp.faces.empty() && grp.face_ids.empty())
          schema_fail("a loads group must give \"faces\" or \"face_ids\"");
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
                            {"face_id", "kind", "concentric_margin_mm",
                             "axial_clearance_mm", "slab_depth_mm"},
                            "a clearance");
        JobClearance cl;
        const double fid = require_number(
            require_key(cv, "face_id", "a clearance"), "clearance face_id");
        if (fid < 0.0 || fid != std::floor(fid))
          schema_fail("a clearance \"face_id\" must be a non-negative integer");
        cl.face_id = static_cast<int>(fid);
        cl.kind = require_nonempty_string(
            require_key(cv, "kind", "a clearance"), "clearance kind");
        if (cl.kind != "bolt" && cl.kind != "face")
          schema_fail("a clearance \"kind\" must be \"bolt\" or \"face\" (got \"" +
                      cl.kind + "\")");
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
    if (const JsonValue* fp = find_key(lv, "face_protections"))
      job.loads.face_protection_face_ids =
          parse_int_array(*fp, "face_protections");
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

  // output block.
  {
    const JsonValue& out =
        require_object(require_key(root, "output", "the job"), "output");
    reject_unknown_keys(
        out, {"report", "mesh_format", "mesh_prefix", "smooth_factor"},
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
