#include "topopt/settings.hpp"

#include <algorithm>
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

// --- Minimal JSON parser --------------------------------------------------
//
// settings/rules.json is small and read-only to the engine, and ARCHITECTURE
// §4 locks the dependency set (no JSON library), so this mirrors the module-
// local parser the materials loader uses: a purpose-built recursive-descent
// parser over objects/arrays/strings/numbers/booleans/null. It rejects
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
    throw SettingsError("rules.json parse error at offset " +
                        std::to_string(pos_) + ": " + msg);
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

// --- Field lookup helpers -------------------------------------------------

const JsonValue* find_field(const JsonValue& obj, const std::string& key) {
  for (const auto& kv : obj.obj)
    if (kv.first == key) return &kv.second;
  return nullptr;
}

const JsonValue& require_object(const JsonValue& parent, const std::string& key,
                                const std::string& ctx) {
  const JsonValue* v = find_field(parent, key);
  if (v == nullptr || v->type != JsonValue::Type::Object)
    throw SettingsError(ctx + ": missing or non-object '" + key + "'");
  return *v;
}

const JsonValue& require_array(const JsonValue& parent, const std::string& key,
                               const std::string& ctx) {
  const JsonValue* v = find_field(parent, key);
  if (v == nullptr || v->type != JsonValue::Type::Array)
    throw SettingsError(ctx + ": missing or non-array '" + key + "'");
  return *v;
}

// Require an integer-valued number field. Rule counts (walls, layers, infill %)
// are whole numbers; reject a non-number or a non-integral value.
int require_int(const JsonValue& obj, const std::string& key,
                const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr || v->type != JsonValue::Type::Number)
    throw SettingsError(ctx + ": field '" + key + "' must be a number");
  if (std::floor(v->num) != v->num)
    throw SettingsError(ctx + ": field '" + key + "' must be an integer");
  return static_cast<int>(v->num);
}

std::string require_string(const JsonValue& obj, const std::string& key,
                           const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr || v->type != JsonValue::Type::String)
    throw SettingsError(ctx + ": field '" + key + "' must be a string");
  return v->str;
}

// Optional string field ("" when absent). Throws if present but not a string.
std::string optional_string(const JsonValue& obj, const std::string& key,
                            const std::string& ctx) {
  const JsonValue* v = find_field(obj, key);
  if (v == nullptr) return std::string();
  if (v->type != JsonValue::Type::String)
    throw SettingsError(ctx + ": field '" + key + "' must be a string");
  return v->str;
}

// margin_below is a number, or JSON null for the final unbounded band.
void parse_margin_below(const JsonValue& band, const std::string& ctx,
                        bool& unbounded, double& margin_below) {
  const JsonValue* v = find_field(band, "margin_below");
  if (v == nullptr)
    throw SettingsError(ctx + ": missing field 'margin_below'");
  if (v->type == JsonValue::Type::Null) {
    unbounded = true;
    margin_below = 0.0;
    return;
  }
  if (v->type != JsonValue::Type::Number)
    throw SettingsError(ctx + ": 'margin_below' must be a number or null");
  unbounded = false;
  margin_below = v->num;
}

SizeModifier parse_size_modifier(const JsonValue& mods, const std::string& key,
                                 const std::string& ctx) {
  const JsonValue* v = find_field(mods, key);
  if (v == nullptr || v->type != JsonValue::Type::Object)
    throw SettingsError(ctx + ": missing or non-object size class '" + key +
                        "'");
  SizeModifier m;
  // Every key is optional and additive; an empty object means no change.
  const std::string mctx = ctx + "." + key;
  if (find_field(*v, "walls")) m.walls = require_int(*v, "walls", mctx);
  if (find_field(*v, "top_layers"))
    m.top_layers = require_int(*v, "top_layers", mctx);
  if (find_field(*v, "bottom_layers"))
    m.bottom_layers = require_int(*v, "bottom_layers", mctx);
  if (find_field(*v, "infill_percent"))
    m.infill_percent = require_int(*v, "infill_percent", mctx);
  return m;
}

FieldClamp parse_clamp(const JsonValue& clamps, const std::string& key,
                       const std::string& ctx) {
  const JsonValue* v = find_field(clamps, key);
  if (v == nullptr || v->type != JsonValue::Type::Array || v->arr.size() != 2)
    throw SettingsError(ctx + ": clamp '" + key +
                        "' must be a [lo, hi] array");
  if (v->arr[0].type != JsonValue::Type::Number ||
      v->arr[1].type != JsonValue::Type::Number)
    throw SettingsError(ctx + ": clamp '" + key + "' bounds must be numbers");
  FieldClamp c;
  c.lo = static_cast<int>(v->arr[0].num);
  c.hi = static_cast<int>(v->arr[1].num);
  if (c.lo > c.hi)
    throw SettingsError(ctx + ": clamp '" + key + "' has lo > hi");
  return c;
}

// A band array must be non-empty, ordered strictly ascending by margin_below,
// and terminate with exactly one unbounded band (the last entry). This is the
// structure evaluation_order relies on.
template <typename Band>
void validate_band_order(const std::vector<Band>& bands,
                         const std::string& ctx) {
  if (bands.empty()) throw SettingsError(ctx + ": no margin bands");
  for (std::size_t i = 0; i + 1 < bands.size(); ++i) {
    if (bands[i].unbounded)
      throw SettingsError(ctx + ": only the last band may be unbounded");
    if (bands[i + 1].unbounded) continue;
    if (!(bands[i].margin_below < bands[i + 1].margin_below))
      throw SettingsError(ctx + ": bands must ascend by margin_below");
  }
  if (!bands.back().unbounded)
    throw SettingsError(ctx + ": last band must be unbounded (margin_below null)");
}

}  // namespace

SettingsRules parse_settings_rules(const std::string& json_text) {
  JsonValue root = JsonParser(json_text).parse();
  if (root.type != JsonValue::Type::Object)
    throw SettingsError("rules.json: top-level value must be an object");

  SettingsRules rules;

  // --- fdm section ---
  const JsonValue& fdm = require_object(root, "fdm", "rules.json");
  const JsonValue& fdm_bands = require_array(fdm, "margin_bands", "fdm");
  for (std::size_t i = 0; i < fdm_bands.arr.size(); ++i) {
    const JsonValue& b = fdm_bands.arr[i];
    const std::string ctx = "fdm.margin_bands[" + std::to_string(i) + "]";
    if (b.type != JsonValue::Type::Object)
      throw SettingsError(ctx + ": band must be an object");
    FdmBand band;
    parse_margin_below(b, ctx, band.unbounded, band.margin_below);
    band.walls = require_int(b, "walls", ctx);
    band.top_layers = require_int(b, "top_layers", ctx);
    band.bottom_layers = require_int(b, "bottom_layers", ctx);
    band.infill_percent = require_int(b, "infill_percent", ctx);
    band.infill_pattern = require_string(b, "infill_pattern", ctx);
    band.warning = optional_string(b, "warning", ctx);
    rules.fdm_bands.push_back(std::move(band));
  }
  validate_band_order(rules.fdm_bands, "fdm.margin_bands");

  const JsonValue& mods = require_object(fdm, "size_modifiers", "fdm");
  rules.fdm_small = parse_size_modifier(mods, "small", "fdm.size_modifiers");
  rules.fdm_medium = parse_size_modifier(mods, "medium", "fdm.size_modifiers");
  rules.fdm_large = parse_size_modifier(mods, "large", "fdm.size_modifiers");

  const JsonValue& clamps = require_object(fdm, "clamps", "fdm");
  rules.clamp_walls = parse_clamp(clamps, "walls", "fdm.clamps");
  rules.clamp_top_layers = parse_clamp(clamps, "top_layers", "fdm.clamps");
  rules.clamp_bottom_layers = parse_clamp(clamps, "bottom_layers", "fdm.clamps");
  rules.clamp_infill_percent =
      parse_clamp(clamps, "infill_percent", "fdm.clamps");

  // --- resin section ---
  const JsonValue& resin = require_object(root, "resin", "rules.json");
  const JsonValue& resin_bands = require_array(resin, "margin_bands", "resin");
  for (std::size_t i = 0; i < resin_bands.arr.size(); ++i) {
    const JsonValue& b = resin_bands.arr[i];
    const std::string ctx = "resin.margin_bands[" + std::to_string(i) + "]";
    if (b.type != JsonValue::Type::Object)
      throw SettingsError(ctx + ": band must be an object");
    ResinBand band;
    parse_margin_below(b, ctx, band.unbounded, band.margin_below);
    band.print_mode = require_string(b, "print_mode", ctx);
    band.warning = optional_string(b, "warning", ctx);
    rules.resin_bands.push_back(std::move(band));
  }
  validate_band_order(rules.resin_bands, "resin.margin_bands");

  return rules;
}

SettingsRules load_settings_rules_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw SettingsError("cannot open rules file: " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return parse_settings_rules(ss.str());
}

namespace {

int clamp_field(int value, const FieldClamp& c) {
  return std::min(std::max(value, c.lo), c.hi);
}

}  // namespace

SlicerSettings recommend_settings(const SettingsRules& rules,
                                  const std::string& family,
                                  double worst_case_stress_margin,
                                  double max_part_dimension_mm) {
  if (family != "fdm" && family != "resin")
    throw SettingsError("recommend_settings: family must be \"fdm\" or "
                        "\"resin\", got \"" + family + "\"");
  if (!std::isfinite(worst_case_stress_margin) ||
      worst_case_stress_margin < 0.0)
    throw SettingsError(
        "recommend_settings: worst_case_stress_margin must be finite and >= 0");
  if (!std::isfinite(max_part_dimension_mm) || max_part_dimension_mm <= 0.0)
    throw SettingsError(
        "recommend_settings: max_part_dimension_mm must be finite and > 0");

  SlicerSettings out;
  out.family = family;

  // Band gate: first band whose margin_below exceeds the input margin. A margin
  // exactly equal to a band's margin_below falls into the NEXT band
  // (band_boundary_rule), so the comparison is strict `<`. The final unbounded
  // band matches anything, so the loop always selects a band.
  if (family == "resin") {
    const ResinBand* sel = nullptr;
    for (const ResinBand& b : rules.resin_bands) {
      if (b.unbounded || worst_case_stress_margin < b.margin_below) {
        sel = &b;
        break;
      }
    }
    if (sel == nullptr)  // guaranteed non-null by validate_band_order
      throw SettingsError("recommend_settings: no resin band matched");
    out.print_mode = sel->print_mode;
    out.warning = sel->warning;
    return out;  // resin: no FDM fields, no size modifiers, no clamps
  }

  const FdmBand* sel = nullptr;
  for (const FdmBand& b : rules.fdm_bands) {
    if (b.unbounded || worst_case_stress_margin < b.margin_below) {
      sel = &b;
      break;
    }
  }
  if (sel == nullptr)  // guaranteed non-null by validate_band_order
    throw SettingsError("recommend_settings: no fdm band matched");

  out.walls = sel->walls;
  out.top_layers = sel->top_layers;
  out.bottom_layers = sel->bottom_layers;
  out.infill_percent = sel->infill_percent;
  out.infill_pattern = sel->infill_pattern;
  out.warning = sel->warning;

  // Size class → additive modifier (semantics_locked.size_classes).
  const SizeModifier* mod = nullptr;
  if (max_part_dimension_mm <= kSmallMaxDimensionMm) {
    mod = &rules.fdm_small;
  } else if (max_part_dimension_mm <= kMediumMaxDimensionMm) {
    mod = &rules.fdm_medium;
  } else {
    mod = &rules.fdm_large;
  }
  out.walls += mod->walls;
  out.top_layers += mod->top_layers;
  out.bottom_layers += mod->bottom_layers;
  out.infill_percent += mod->infill_percent;

  // Clamps (applied after modifiers). infill_pattern is not clamped.
  out.walls = clamp_field(out.walls, rules.clamp_walls);
  out.top_layers = clamp_field(out.top_layers, rules.clamp_top_layers);
  out.bottom_layers = clamp_field(out.bottom_layers, rules.clamp_bottom_layers);
  out.infill_percent =
      clamp_field(out.infill_percent, rules.clamp_infill_percent);

  return out;
}

}  // namespace topopt
