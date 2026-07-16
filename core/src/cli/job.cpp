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

}  // namespace

JobDescription parse_job(const std::string& json_text) {
  JsonParser parser(json_text);
  const JsonValue root = parser.parse();
  if (root.type != JsonValue::Type::Object)
    schema_fail("top level must be an object");

  reject_unknown_keys(root,
                      {"model", "material", "mode", "resolution",
                       "fixture_faces", "gravity", "ladder", "margin_stop",
                       "simp", "output"},
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

  // fixture_faces: non-empty array of geometric selectors.
  {
    const JsonValue& faces = require_key(root, "fixture_faces", "the job");
    if (faces.type != JsonValue::Type::Array)
      schema_fail("\"fixture_faces\" must be an array");
    if (faces.arr.empty())
      schema_fail("\"fixture_faces\" must contain at least one selector");
    for (const JsonValue& sel : faces.arr) {
      if (sel.type != JsonValue::Type::Object)
        schema_fail("every fixture_faces entry must be a selector object");
      reject_unknown_keys(sel, {"kind", "radius_mm"}, "a fixture_faces selector");
      JobFaceSelector s;
      s.kind = require_nonempty_string(
          require_key(sel, "kind", "a fixture_faces selector"), "kind");
      if (s.kind != "cylindrical")
        schema_fail("selector \"kind\" must be \"cylindrical\" (got \"" +
                    s.kind + "\")");
      s.radius_mm = require_number(
          require_key(sel, "radius_mm", "a fixture_faces selector"),
          "radius_mm");
      if (!(s.radius_mm > 0.0))
        schema_fail("selector \"radius_mm\" must be > 0");
      job.fixture_faces.push_back(s);
    }
  }

  // gravity: direction (3 finite numbers, non-zero) + magnitude.
  {
    const JsonValue& g =
        require_object(require_key(root, "gravity", "the job"), "gravity");
    reject_unknown_keys(g, {"direction", "magnitude_mm_s2"}, "gravity");
    const JsonValue& dir = require_key(g, "direction", "gravity");
    if (dir.type != JsonValue::Type::Array || dir.arr.size() != 3)
      schema_fail("gravity \"direction\" must be an array of 3 numbers");
    double d[3];
    for (int i = 0; i < 3; ++i)
      d[i] = require_number(dir.arr[static_cast<std::size_t>(i)],
                            "gravity direction component");
    job.gravity.direction = Vec3{d[0], d[1], d[2]};
    if (d[0] * d[0] + d[1] * d[1] + d[2] * d[2] <= 0.0)
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
