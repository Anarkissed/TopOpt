// M5.2 job report: data model -> single JSON document + schema validation
// (topopt/report.hpp). Pure C++/std (no OCCT, no Eigen), so it builds in every
// configuration and its test runs in the dependency-light CI path too.
//
// Like materials.cpp and settings.cpp (ARCHITECTURE §4: no JSON library), this
// TU carries a module-local minimal JSON parser for the schema validator plus a
// small hand-rolled serializer for the emitter. The validator is the concrete
// definition of the report schema.

#include "topopt/report.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace topopt {
namespace {

// --- Serialization --------------------------------------------------------

// A finite double as a JSON number; a non-finite value (e.g. an unbounded
// margin term when a stress is 0) as JSON null.
std::string num_json(double v) {
  if (!std::isfinite(v)) return "null";
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.10g", v);
  return std::string(buf);
}

// A JSON string literal with the mandatory escapes (RFC 8259): the quote,
// the backslash, and all control characters (< 0x20).
std::string str_json(const std::string& s) {
  std::string out = "\"";
  for (char ch : s) {
    unsigned char c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(ch);
        }
    }
  }
  out.push_back('"');
  return out;
}

void emit_settings(std::string& out, const SlicerSettings& s,
                   const std::string& indent) {
  const std::string in2 = indent + "  ";
  out += "{\n";
  out += in2 + "\"family\": " + str_json(s.family) + ",\n";
  out += in2 + "\"walls\": " + std::to_string(s.walls) + ",\n";
  out += in2 + "\"top_layers\": " + std::to_string(s.top_layers) + ",\n";
  out += in2 + "\"bottom_layers\": " + std::to_string(s.bottom_layers) + ",\n";
  out += in2 + "\"infill_percent\": " + std::to_string(s.infill_percent) + ",\n";
  out += in2 + "\"infill_pattern\": " + str_json(s.infill_pattern) + ",\n";
  out += in2 + "\"print_mode\": " + str_json(s.print_mode) + ",\n";
  out += in2 + "\"warning\": " + str_json(s.warning) + "\n";
  out += indent + "}";
}

void emit_variant(std::string& out, const VariantReport& v,
                  const std::string& indent) {
  const std::string in2 = indent + "  ";
  out += "{\n";
  out += in2 + "\"volume_fraction\": " + num_json(v.volume_fraction) + ",\n";
  // "Volume saved" is the material removed vs the original solid part.
  out += in2 + "\"volume_saved_fraction\": " +
         num_json(1.0 - v.volume_fraction) + ",\n";
  out += in2 + "\"max_stress_mpa\": " + num_json(v.max_stress_mpa) + ",\n";
  out += in2 + "\"max_interlayer_tension_mpa\": " +
         num_json(v.max_interlayer_tension_mpa) + ",\n";
  out += in2 + "\"margin\": {\n";
  out += in2 + "  \"in_plane\": " + num_json(v.margin.in_plane) + ",\n";
  out += in2 + "  \"interlayer\": " + num_json(v.margin.interlayer) + ",\n";
  out += in2 + "  \"worst_case\": " + num_json(v.margin.worst_case) + "\n";
  out += in2 + "},\n";
  out += in2 + "\"orientation\": {\n";
  out += in2 + "  \"x\": " + num_json(v.orientation.x) + ",\n";
  out += in2 + "  \"y\": " + num_json(v.orientation.y) + ",\n";
  out += in2 + "  \"z\": " + num_json(v.orientation.z) + "\n";
  out += in2 + "},\n";
  out += in2 + "\"settings\": ";
  emit_settings(out, v.settings, in2);
  out += ",\n";
  // M5.2b — min-feature print warning (report-only).
  out += in2 + "\"min_feature_violations\": " +
         std::to_string(v.min_feature_violations) + ",\n";
  out += in2 + "\"min_feature_warning\": " +
         str_json(v.min_feature_warning) + "\n";
  out += indent + "}";
}

// --- Minimal JSON parser (for the schema validator) -----------------------

struct JsonValue {
  enum class Type { Null, Bool, Number, String, Array, Object };
  Type type = Type::Null;
  bool boolean = false;
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
    throw ReportError("job report JSON: " + msg);
  }

  void skip_ws() {
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        ++pos_;
      else
        break;
    }
  }

  char peek() {
    if (pos_ >= s_.size()) fail("unexpected end of input");
    return s_[pos_];
  }

  JsonValue parse_value() {
    skip_ws();
    char c = peek();
    switch (c) {
      case '{': return parse_object();
      case '[': return parse_array();
      case '"': {
        JsonValue v;
        v.type = JsonValue::Type::String;
        v.str = parse_string();
        return v;
      }
      case 't':
      case 'f': return parse_bool();
      case 'n': return parse_null();
      default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
        fail("unexpected character");
    }
  }

  JsonValue parse_object() {
    JsonValue v;
    v.type = JsonValue::Type::Object;
    ++pos_;  // consume '{'
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == '}') {
      ++pos_;
      return v;
    }
    while (true) {
      skip_ws();
      if (peek() != '"') fail("expected string key");
      std::string key = parse_string();
      skip_ws();
      if (peek() != ':') fail("expected ':' after key");
      ++pos_;
      JsonValue val = parse_value();
      v.obj.emplace_back(std::move(key), std::move(val));
      skip_ws();
      char c = peek();
      if (c == ',') {
        ++pos_;
        continue;
      }
      if (c == '}') {
        ++pos_;
        break;
      }
      fail("expected ',' or '}' in object");
    }
    return v;
  }

  JsonValue parse_array() {
    JsonValue v;
    v.type = JsonValue::Type::Array;
    ++pos_;  // consume '['
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == ']') {
      ++pos_;
      return v;
    }
    while (true) {
      v.arr.push_back(parse_value());
      skip_ws();
      char c = peek();
      if (c == ',') {
        ++pos_;
        continue;
      }
      if (c == ']') {
        ++pos_;
        break;
      }
      fail("expected ',' or ']' in array");
    }
    return v;
  }

  JsonValue parse_bool() {
    if (s_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      JsonValue v;
      v.type = JsonValue::Type::Bool;
      v.boolean = true;
      return v;
    }
    if (s_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      JsonValue v;
      v.type = JsonValue::Type::Bool;
      v.boolean = false;
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
          default: fail("invalid escape sequence");
        }
      } else if ((unsigned char)c < 0x20) {
        fail("control character in string");
      } else {
        out.push_back(c);
      }
    }
    return out;
  }
};

// --- Schema-validation helpers --------------------------------------------

const JsonValue* find_field(const JsonValue& obj, const std::string& key) {
  for (const auto& kv : obj.obj)
    if (kv.first == key) return &kv.second;
  return nullptr;
}

const JsonValue& require_object(const JsonValue& parent, const std::string& key,
                                const std::string& ctx) {
  const JsonValue* v = find_field(parent, key);
  if (v == nullptr || v->type != JsonValue::Type::Object)
    throw ReportError(ctx + ": missing or non-object '" + key + "'");
  return *v;
}

const JsonValue& require_array(const JsonValue& parent, const std::string& key,
                               const std::string& ctx) {
  const JsonValue* v = find_field(parent, key);
  if (v == nullptr || v->type != JsonValue::Type::Array)
    throw ReportError(ctx + ": missing or non-array '" + key + "'");
  return *v;
}

std::string require_string(const JsonValue& obj, const std::string& key,
                           const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr || v->type != JsonValue::Type::String)
    throw ReportError(ctx + ": field '" + key + "' must be a string");
  return v->str;
}

double require_number(const JsonValue& obj, const std::string& key,
                      const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr || v->type != JsonValue::Type::Number)
    throw ReportError(ctx + ": field '" + key + "' must be a number");
  return v->num;
}

// A margin term: a JSON number, or null (an unbounded margin when the matching
// stress is 0). Presence is required; any other type is rejected.
void require_number_or_null(const JsonValue& obj, const std::string& key,
                            const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr ||
      (v->type != JsonValue::Type::Number && v->type != JsonValue::Type::Null))
    throw ReportError(ctx + ": field '" + key + "' must be a number or null");
}

void require_int(const JsonValue& obj, const std::string& key,
                 const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr || v->type != JsonValue::Type::Number)
    throw ReportError(ctx + ": field '" + key + "' must be a number");
  if (std::floor(v->num) != v->num)
    throw ReportError(ctx + ": field '" + key + "' must be an integer");
}

}  // namespace

// --- Public API -----------------------------------------------------------

StressMargin compute_stress_margin(double yield_strength_mpa, double z_knockdown,
                                   double max_von_mises_stress,
                                   double max_interlayer_tension) {
  if (!(std::isfinite(yield_strength_mpa) && yield_strength_mpa > 0.0))
    throw ReportError("stress margin: yield_strength_mpa must be finite and > 0");
  if (!(std::isfinite(z_knockdown) && z_knockdown > 0.0 && z_knockdown <= 1.0))
    throw ReportError("stress margin: z_knockdown must be in (0, 1]");
  if (!(std::isfinite(max_von_mises_stress) && max_von_mises_stress >= 0.0))
    throw ReportError(
        "stress margin: max_von_mises_stress must be finite and >= 0");
  if (!(std::isfinite(max_interlayer_tension) && max_interlayer_tension >= 0.0))
    throw ReportError(
        "stress margin: max_interlayer_tension must be finite and >= 0");

  const double inf = std::numeric_limits<double>::infinity();
  StressMargin m;
  // A zero stress in a failure mode carries no load -> unbounded margin.
  m.in_plane = (max_von_mises_stress > 0.0)
                   ? yield_strength_mpa / max_von_mises_stress
                   : inf;
  m.interlayer = (max_interlayer_tension > 0.0)
                     ? (z_knockdown * yield_strength_mpa) / max_interlayer_tension
                     : inf;
  m.worst_case = std::min(m.in_plane, m.interlayer);
  return m;
}

std::string job_report_json(const JobReport& report) {
  std::string out = "{\n";
  out += "  \"material\": " + str_json(report.material) + ",\n";
  if (report.variants.empty()) {
    out += "  \"variants\": []\n";
  } else {
    out += "  \"variants\": [\n";
    for (std::size_t i = 0; i < report.variants.size(); ++i) {
      out += "    ";
      emit_variant(out, report.variants[i], "    ");
      out += (i + 1 < report.variants.size()) ? ",\n" : "\n";
    }
    out += "  ]\n";
  }
  out += "}\n";
  return out;
}

void validate_job_report_json(const std::string& json_text) {
  JsonValue root = JsonParser(json_text).parse();
  if (root.type != JsonValue::Type::Object)
    throw ReportError("report: root must be an object");

  require_string(root, "material", "report");
  const JsonValue& variants = require_array(root, "variants", "report");

  for (std::size_t i = 0; i < variants.arr.size(); ++i) {
    const std::string ctx = "variant[" + std::to_string(i) + "]";
    const JsonValue& v = variants.arr[i];
    if (v.type != JsonValue::Type::Object)
      throw ReportError(ctx + ": must be an object");

    const double vf = require_number(v, "volume_fraction", ctx);
    if (!(vf >= 0.0 && vf <= 1.0))
      throw ReportError(ctx + ": volume_fraction must be in [0, 1]");
    const double vsf = require_number(v, "volume_saved_fraction", ctx);
    if (!(vsf >= 0.0 && vsf <= 1.0))
      throw ReportError(ctx + ": volume_saved_fraction must be in [0, 1]");
    if (std::fabs(vsf - (1.0 - vf)) > 1e-9)
      throw ReportError(ctx +
                        ": volume_saved_fraction must equal 1 - volume_fraction");

    const double ms = require_number(v, "max_stress_mpa", ctx);
    if (!(ms >= 0.0))
      throw ReportError(ctx + ": max_stress_mpa must be >= 0");
    const double it = require_number(v, "max_interlayer_tension_mpa", ctx);
    if (!(it >= 0.0))
      throw ReportError(ctx + ": max_interlayer_tension_mpa must be >= 0");

    const JsonValue& margin = require_object(v, "margin", ctx);
    require_number_or_null(margin, "in_plane", ctx + ".margin");
    require_number_or_null(margin, "interlayer", ctx + ".margin");
    require_number_or_null(margin, "worst_case", ctx + ".margin");

    const JsonValue& orient = require_object(v, "orientation", ctx);
    require_number(orient, "x", ctx + ".orientation");
    require_number(orient, "y", ctx + ".orientation");
    require_number(orient, "z", ctx + ".orientation");

    const JsonValue& settings = require_object(v, "settings", ctx);
    require_string(settings, "family", ctx + ".settings");
    require_int(settings, "walls", ctx + ".settings");
    require_int(settings, "top_layers", ctx + ".settings");
    require_int(settings, "bottom_layers", ctx + ".settings");
    require_int(settings, "infill_percent", ctx + ".settings");
    require_string(settings, "infill_pattern", ctx + ".settings");
    require_string(settings, "print_mode", ctx + ".settings");
    require_string(settings, "warning", ctx + ".settings");

    // M5.2b min-feature warning (report-only). Optional for backward
    // compatibility; when present, min_feature_violations is a non-negative
    // integer, min_feature_warning is a string, and a non-empty warning
    // requires a positive violation count (no warning without violations).
    bool violations_positive = false;
    const JsonValue* mfv = find_field(v, "min_feature_violations");
    if (mfv != nullptr) {
      if (mfv->type != JsonValue::Type::Number)
        throw ReportError(ctx + ": min_feature_violations must be a number");
      if (std::floor(mfv->num) != mfv->num)
        throw ReportError(ctx + ": min_feature_violations must be an integer");
      if (mfv->num < 0.0)
        throw ReportError(ctx + ": min_feature_violations must be >= 0");
      violations_positive = mfv->num > 0.0;
    }
    const JsonValue* mfw = find_field(v, "min_feature_warning");
    if (mfw != nullptr) {
      if (mfw->type != JsonValue::Type::String)
        throw ReportError(ctx + ": min_feature_warning must be a string");
      if (!mfw->str.empty() && !violations_positive)
        throw ReportError(
            ctx +
            ": non-empty min_feature_warning requires min_feature_violations > 0");
    }
  }
}

}  // namespace topopt
