#include "topopt/materials.hpp"

#include "topopt/lattice.hpp"              // the type ids the print-tests file may name
#include "topopt/lattice_print_tests.hpp"

#include <cctype>
#include <cstddef>
#include <fstream>
#include <functional>
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

// ── the lattice print-tests file (topopt/lattice_print_tests.hpp) ──────────────
// The same parser as materials.json, on purpose: one strictness for maintainer data.
namespace {

bool is_comment_key(const std::string& k) { return !k.empty() && k[0] == '_'; }

bool is_date(const std::string& s) {
  if (s.size() != 10 || s[4] != '-' || s[7] != '-') return false;
  for (std::size_t i : {0u, 1u, 2u, 3u, 5u, 6u, 8u, 9u})
    if (!std::isdigit(static_cast<unsigned char>(s[i]))) return false;
  const int month = (s[5] - '0') * 10 + (s[6] - '0');
  const int day = (s[8] - '0') * 10 + (s[9] - '0');
  return month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

// A JSON object that names a key twice keeps only one of them silently; the file is
// maintainer data, so a repeated key is refused rather than half-read.
void refuse_duplicate_keys(const JsonValue& obj, const std::string& where,
                           const std::function<void(const std::string&)>& bad) {
  for (std::size_t i = 0; i < obj.obj.size(); ++i)
    for (std::size_t j = i + 1; j < obj.obj.size(); ++j)
      if (obj.obj[i].first == obj.obj[j].first)
        bad(where + " names \"" + obj.obj[i].first + "\" twice");
}

// Every id the file may name: lattice_topology_name over every enum value (C++ cannot
// enumerate an enum, so the values are listed here; a value added to the enum without a
// name fails lattice_topology_name's own -Wswitch first), then the planned sheet ids.
bool accepted_type_id(const std::string& id) {
  for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic,
                            LatticeTopology::Bcc, LatticeTopology::Fcc,
                            LatticeTopology::Diamond, LatticeTopology::Kelvin,
                            LatticeTopology::Rhombic, LatticeTopology::Bccz,
                            LatticeTopology::Fccz, LatticeTopology::Reentrant})
    if (id == lattice_topology_name(t)) return true;
  for (const std::string& p : lattice_planned_topology_ids())
    if (id == p) return true;
  return false;
}

}  // namespace

LatticePrintTests parse_lattice_print_tests(const std::string& json_text) {
  auto bad = [](const std::string& m) {
    throw LatticePrintTestsError("lattice_print_tests.json: " + m);
  };
  JsonValue root;
  try {
    root = JsonParser(json_text).parse();
  } catch (const MaterialError& e) {
    bad(e.what());
  }
  if (root.type != JsonValue::Type::Object) bad("the top level must be an object");
  refuse_duplicate_keys(root, "the top level", bad);
  const JsonValue* types = nullptr;
  bool version_seen = false;
  for (const auto& kv : root.obj) {
    if (is_comment_key(kv.first)) continue;
    if (kv.first == "schema_version") {
      if (kv.second.type != JsonValue::Type::Number || kv.second.num != 1.0)
        bad("\"schema_version\" must be 1");
      version_seen = true;
    } else if (kv.first == "types") {
      if (kv.second.type != JsonValue::Type::Object) bad("\"types\" must be an object");
      types = &kv.second;
    } else {
      bad("unknown top-level key \"" + kv.first + "\"");
    }
  }
  if (!version_seen) bad("missing \"schema_version\"");
  if (!types) bad("missing \"types\"");
  refuse_duplicate_keys(*types, "\"types\"", bad);
  LatticePrintTests out;
  for (const auto& tv : types->obj) {
    const std::string& id = tv.first;
    if (is_comment_key(id)) continue;
    if (!accepted_type_id(id))
      bad("\"" + id + "\" is not a lattice type id core knows (ids are core's "
          "topology ids, lower case: octet, sc, bcc, fcc, diamond, kelvin, rhombic, "
          "bccz, fccz, reentrant, gyroid, schwarz_d)");
    if (out.count(id)) bad("type \"" + id + "\" is listed twice");
    if (tv.second.type != JsonValue::Type::Object) bad("type \"" + id + "\" must be an object");
    refuse_duplicate_keys(tv.second, "type \"" + id + "\"", bad);
    LatticePrintStatus st;
    st.listed = true;
    bool seen_tested = false, seen_date = false, seen_note = false;
    for (const auto& f : tv.second.obj) {
      if (is_comment_key(f.first)) continue;
      const JsonValue& v = f.second;
      if (f.first == "print_tested") {
        if (v.type != JsonValue::Type::Bool) bad("\"" + id + "\".print_tested must be true or false");
        st.print_tested = v.num != 0.0;
        seen_tested = true;
      } else if (f.first == "date") {
        if (v.type == JsonValue::Type::String) {
          if (!is_date(v.str)) bad("\"" + id + "\".date must be YYYY-MM-DD (got \"" + v.str + "\")");
          st.date = v.str;
        } else if (v.type != JsonValue::Type::Null) {
          bad("\"" + id + "\".date must be a string or null");
        }
        seen_date = true;
      } else if (f.first == "note") {
        if (v.type == JsonValue::Type::String) st.note = v.str;
        else if (v.type != JsonValue::Type::Null) bad("\"" + id + "\".note must be a string or null");
        seen_note = true;
      } else {
        bad("type \"" + id + "\": unknown key \"" + f.first + "\"");
      }
    }
    if (!seen_tested) bad("type \"" + id + "\": missing \"print_tested\"");
    if (!seen_date) bad("type \"" + id + "\": missing \"date\"");
    if (!seen_note) bad("type \"" + id + "\": missing \"note\"");
    if (st.print_tested && st.date.empty())
      bad("type \"" + id + "\" is marked print_tested but has no date");
    out.emplace(id, std::move(st));
  }
  return out;
}

LatticePrintTests load_lattice_print_tests_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw LatticePrintTestsError("cannot open lattice print-tests file: " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return parse_lattice_print_tests(ss.str());
}

LatticePrintStatus lattice_print_status(const LatticePrintTests& tests, const std::string& id) {
  const auto it = tests.find(id);
  return it == tests.end() ? LatticePrintStatus{} : it->second;
}

}  // namespace topopt
