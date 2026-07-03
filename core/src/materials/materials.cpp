#include "topopt/materials.hpp"

#include <cctype>
#include <cstddef>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace topopt {
namespace {

// --- Minimal JSON parser --------------------------------------------------
//
// materials.json is small and flat, and ARCHITECTURE §4 locks the dependency
// set (no JSON library available), so this is a purpose-built recursive-descent
// parser covering exactly what the schema needs: objects, arrays, strings,
// numbers, booleans, null. It rejects malformed input rather than repairing it.
// Kept internal to the materials module (no speculative public "json" API).

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
    throw MaterialError("JSON parse error at offset " + std::to_string(pos_) +
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
      return JsonValue{};
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
          case 'u': append_utf8(out, parse_hex4()); break;
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

  unsigned parse_hex4() {
    if (pos_ + 4 > s_.size()) fail("invalid \\u escape");
    unsigned cp = 0;
    for (int i = 0; i < 4; ++i) {
      char c = s_[pos_++];
      cp <<= 4;
      if (c >= '0' && c <= '9') {
        cp |= static_cast<unsigned>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        cp |= static_cast<unsigned>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        cp |= static_cast<unsigned>(c - 'A' + 10);
      } else {
        fail("invalid hex digit in \\u escape");
      }
    }
    return cp;
  }

  static void append_utf8(std::string& out, unsigned cp) {
    if (cp < 0x80) {
      out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
      out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }
};

// --- Schema validation ----------------------------------------------------

const JsonValue* find_field(const JsonValue& obj, const std::string& key) {
  const JsonValue* found = nullptr;
  for (const auto& kv : obj.obj) {
    if (kv.first == key) {
      if (found != nullptr) return nullptr;  // duplicate: signalled separately
      found = &kv.second;
    }
  }
  return found;
}

int field_count(const JsonValue& obj, const std::string& key) {
  int n = 0;
  for (const auto& kv : obj.obj)
    if (kv.first == key) ++n;
  return n;
}

double require_number(const JsonValue& mat, const std::string& name,
                      const std::string& field) {
  const JsonValue* v = find_field(mat, field);
  if (v == nullptr || v->type != JsonValue::Type::Number)
    throw MaterialError("material '" + name + "': field '" + field +
                        "' must be a number");
  return v->num;
}

}  // namespace

MaterialLibrary parse_materials(const std::string& json_text) {
  JsonParser parser(json_text);
  JsonValue root = parser.parse();
  if (root.type != JsonValue::Type::Object)
    throw MaterialError("top-level JSON must be an object of materials");

  static const char* const kFields[] = {
      "youngs_modulus_mpa", "yield_strength_mpa", "density_g_cm3",
      "z_knockdown",        "poisson",            "family"};

  MaterialLibrary lib;
  for (const auto& entry : root.obj) {
    const std::string& name = entry.first;
    const JsonValue& mo = entry.second;

    if (lib.count(name) != 0)
      throw MaterialError("duplicate material name '" + name + "'");
    if (mo.type != JsonValue::Type::Object)
      throw MaterialError("material '" + name + "' must be an object");

    // Reject unknown fields.
    for (const auto& kv : mo.obj) {
      bool known = false;
      for (const char* f : kFields)
        if (kv.first == f) {
          known = true;
          break;
        }
      if (!known)
        throw MaterialError("material '" + name + "': unknown field '" +
                            kv.first + "'");
    }
    // Reject missing or duplicated required fields.
    for (const char* f : kFields) {
      int n = field_count(mo, f);
      if (n == 0)
        throw MaterialError("material '" + name + "': missing field '" +
                            std::string(f) + "'");
      if (n > 1)
        throw MaterialError("material '" + name + "': duplicate field '" +
                            std::string(f) + "'");
    }

    Material m;
    m.youngs_modulus_mpa = require_number(mo, name, "youngs_modulus_mpa");
    m.yield_strength_mpa = require_number(mo, name, "yield_strength_mpa");
    m.density_g_cm3 = require_number(mo, name, "density_g_cm3");
    m.z_knockdown = require_number(mo, name, "z_knockdown");
    m.poisson = require_number(mo, name, "poisson");

    const JsonValue* fam = find_field(mo, "family");
    if (fam == nullptr || fam->type != JsonValue::Type::String)
      throw MaterialError("material '" + name +
                          "': field 'family' must be a string");
    m.family = fam->str;
    if (m.family != "fdm" && m.family != "resin")
      throw MaterialError("material '" + name +
                          "': family must be \"fdm\" or \"resin\"");

    // z_knockdown in (0, 1] (ARCHITECTURE §6).
    if (!(m.z_knockdown > 0.0 && m.z_knockdown <= 1.0))
      throw MaterialError("material '" + name +
                          "': z_knockdown must be in (0, 1]");

    // Resins use 1.0 (ARCHITECTURE §6).
    if (m.family == "resin" && m.z_knockdown != 1.0)
      throw MaterialError("material '" + name +
                          "': resin family requires z_knockdown == 1.0");

    lib.emplace(name, std::move(m));
  }
  return lib;
}

MaterialLibrary load_materials_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw MaterialError("cannot open materials file: " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return parse_materials(ss.str());
}

}  // namespace topopt
