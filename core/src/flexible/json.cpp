#include "json.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace topopt {
namespace flexible {
namespace json {
namespace {

class Parser {
 public:
  Parser(const std::string& s, const std::string& what) : s_(s), what_(what) {}

  Value parse() {
    skip_ws();
    Value v = parse_value();
    skip_ws();
    if (pos_ != s_.size()) fail_at("trailing characters after the JSON value");
    return v;
  }

 private:
  const std::string& s_;
  const std::string& what_;
  std::size_t pos_ = 0;

  [[noreturn]] void fail_at(const std::string& msg) {
    throw FlexibleError(what_ + ": JSON parse error at offset " +
                        std::to_string(pos_) + ": " + msg);
  }

  char peek() {
    if (pos_ >= s_.size()) fail_at("unexpected end of input");
    return s_[pos_];
  }

  void skip_ws() {
    while (pos_ < s_.size()) {
      const char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        ++pos_;
      else
        break;
    }
  }

  Value parse_value() {
    skip_ws();
    const char c = peek();
    if (c == '{') return parse_object();
    if (c == '[') return parse_array();
    if (c == '"') {
      Value v;
      v.type = Value::Type::String;
      v.str = parse_string();
      return v;
    }
    if (s_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      Value v;
      v.type = Value::Type::Bool;
      v.boolean = true;
      return v;
    }
    if (s_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      Value v;
      v.type = Value::Type::Bool;
      v.boolean = false;
      return v;
    }
    if (s_.compare(pos_, 4, "null") == 0) {
      pos_ += 4;
      return Value{};
    }
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
    fail_at(std::string("unexpected character '") + c + "'");
  }

  Value parse_object() {
    Value v;
    v.type = Value::Type::Object;
    ++pos_;
    skip_ws();
    if (peek() == '}') {
      ++pos_;
      return v;
    }
    while (true) {
      skip_ws();
      if (peek() != '"') fail_at("expected a string key in an object");
      std::string key = parse_string();
      for (const auto& kv : v.obj)
        if (kv.first == key) fail_at("duplicated key \"" + key + "\"");
      skip_ws();
      if (peek() != ':') fail_at("expected ':' after an object key");
      ++pos_;
      Value val = parse_value();
      v.obj.emplace_back(std::move(key), std::move(val));
      skip_ws();
      const char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == '}') break;
      fail_at("expected ',' or '}' in an object");
    }
    return v;
  }

  Value parse_array() {
    Value v;
    v.type = Value::Type::Array;
    ++pos_;
    skip_ws();
    if (peek() == ']') {
      ++pos_;
      return v;
    }
    while (true) {
      v.arr.push_back(parse_value());
      skip_ws();
      const char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == ']') break;
      fail_at("expected ',' or ']' in an array");
    }
    return v;
  }

  Value parse_number() {
    const std::size_t start = pos_;
    if (peek() == '-') ++pos_;
    if (pos_ >= s_.size()) fail_at("invalid number");
    if (s_[pos_] == '0') {
      ++pos_;
    } else if (s_[pos_] >= '1' && s_[pos_] <= '9') {
      while (pos_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[pos_])))
        ++pos_;
    } else {
      fail_at("invalid number");
    }
    if (pos_ < s_.size() && s_[pos_] == '.') {
      ++pos_;
      if (pos_ >= s_.size() || !std::isdigit(static_cast<unsigned char>(s_[pos_])))
        fail_at("invalid number: expected a digit after '.'");
      while (pos_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[pos_])))
        ++pos_;
    }
    if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) ++pos_;
      if (pos_ >= s_.size() || !std::isdigit(static_cast<unsigned char>(s_[pos_])))
        fail_at("invalid number: expected a digit in the exponent");
      while (pos_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[pos_])))
        ++pos_;
    }
    Value v;
    v.type = Value::Type::Number;
    v.num = std::stod(s_.substr(start, pos_ - start));
    return v;
  }

  unsigned hex4() {
    if (pos_ + 4 > s_.size()) fail_at("invalid \\u escape");
    unsigned cp = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = s_[pos_++];
      cp <<= 4;
      if (c >= '0' && c <= '9')
        cp |= static_cast<unsigned>(c - '0');
      else if (c >= 'a' && c <= 'f')
        cp |= static_cast<unsigned>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F')
        cp |= static_cast<unsigned>(c - 'A' + 10);
      else
        fail_at("invalid \\u escape");
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

  std::string parse_string() {
    ++pos_;
    std::string out;
    while (true) {
      if (pos_ >= s_.size()) fail_at("unterminated string");
      const char c = s_[pos_++];
      if (c == '"') break;
      if (c == '\\') {
        if (pos_ >= s_.size()) fail_at("unterminated escape");
        const char e = s_[pos_++];
        switch (e) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'b': out.push_back('\b'); break;
          case 'f': out.push_back('\f'); break;
          case 'n': out.push_back('\n'); break;
          case 'r': out.push_back('\r'); break;
          case 't': out.push_back('\t'); break;
          case 'u': append_utf8(out, hex4()); break;
          default: fail_at("invalid escape sequence");
        }
      } else if (static_cast<unsigned char>(c) < 0x20) {
        fail_at("control character in a string");
      } else {
        out.push_back(c);
      }
    }
    return out;
  }
};

void write_string(std::string& out, const std::string& s) {
  out.push_back('"');
  for (const char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char b[8];
          std::snprintf(b, sizeof(b), "\\u%04x", static_cast<unsigned>(c));
          out += b;
        } else {
          out.push_back(c);
        }
    }
  }
  out.push_back('"');
}

void write_value(std::string& out, const Value& v) {
  switch (v.type) {
    case Value::Type::Null: out += "null"; return;
    case Value::Type::Bool: out += v.boolean ? "true" : "false"; return;
    case Value::Type::Number: {
      char b[40];
      std::snprintf(b, sizeof(b), "%.17g", v.num);
      out += b;
      return;
    }
    case Value::Type::String: write_string(out, v.str); return;
    case Value::Type::Array:
      out.push_back('[');
      for (std::size_t i = 0; i < v.arr.size(); ++i) {
        if (i) out.push_back(',');
        write_value(out, v.arr[i]);
      }
      out.push_back(']');
      return;
    case Value::Type::Object:
      out.push_back('{');
      for (std::size_t i = 0; i < v.obj.size(); ++i) {
        if (i) out.push_back(',');
        write_string(out, v.obj[i].first);
        out.push_back(':');
        write_value(out, v.obj[i].second);
      }
      out.push_back('}');
      return;
  }
}

}  // namespace

Value parse(const std::string& text, const std::string& what) {
  return Parser(text, what).parse();
}

std::string to_text(const Value& v) {
  std::string out;
  write_value(out, v);
  return out;
}

void fail(const std::string& where, const std::string& msg) {
  throw FlexibleError(where + ": " + msg);
}

bool is_comment_key(const std::string& key) {
  return !key.empty() && key[0] == '_';
}

const Value* find(const Value& obj, const std::string& key) {
  for (const auto& kv : obj.obj)
    if (kv.first == key) return &kv.second;
  return nullptr;
}

const Value& require(const Value& obj, const std::string& key,
                     const std::string& where) {
  const Value* v = find(obj, key);
  if (v == nullptr) fail(where, "missing required key \"" + key + "\"");
  return *v;
}

void reject_unknown(const Value& obj, const std::vector<std::string>& allowed,
                    const std::string& where) {
  for (const auto& kv : obj.obj) {
    if (is_comment_key(kv.first)) continue;
    bool known = false;
    for (const std::string& a : allowed)
      if (a == kv.first) {
        known = true;
        break;
      }
    if (!known) fail(where, "unknown key \"" + kv.first + "\"");
  }
}

void require_all(const Value& obj, const std::vector<std::string>& required,
                 const std::string& where) {
  for (const std::string& k : required) require(obj, k, where);
}

const Value& as_object(const Value& v, const std::string& where) {
  if (!v.is_object()) fail(where, "must be an object");
  return v;
}

const Value& as_array(const Value& v, const std::string& where) {
  if (!v.is_array()) fail(where, "must be an array");
  return v;
}

double as_number(const Value& v, const std::string& where) {
  if (!v.is_number()) fail(where, "must be a number");
  if (!std::isfinite(v.num)) fail(where, "must be finite");
  return v.num;
}

bool as_bool(const Value& v, const std::string& where) {
  if (!v.is_bool()) fail(where, "must be true or false");
  return v.boolean;
}

const std::string& as_string(const Value& v, const std::string& where) {
  if (!v.is_string()) fail(where, "must be a string");
  return v.str;
}

int as_int(const Value& v, const std::string& where) {
  const double d = as_number(v, where);
  if (d != std::floor(d) || std::fabs(d) > 1e9) fail(where, "must be an integer");
  return static_cast<int>(d);
}

}  // namespace json
}  // namespace flexible
}  // namespace topopt
