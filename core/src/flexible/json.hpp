#pragma once

// INTERNAL to the flexible module (not under include/): the module-local JSON
// reader the house style calls for — materials.cpp, settings.cpp and job.cpp each
// keep their own, because ARCHITECTURE §4 locks the dependency set and a shared
// public "json" API would be speculative. This one adds a WRITER (to_text), which
// the job block needs to hand its lattice regions to the lattice parser verbatim
// (job_block.cpp explains why).

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

#include "topopt/flexible/error.hpp"

namespace topopt {
namespace flexible {
namespace json {

struct Value {
  enum class Type { Null, Bool, Number, String, Array, Object };
  Type type = Type::Null;
  double num = 0.0;
  bool boolean = false;
  std::string str;
  std::vector<Value> arr;
  std::vector<std::pair<std::string, Value>> obj;  // insertion order

  bool is_null() const { return type == Type::Null; }
  bool is_number() const { return type == Type::Number; }
  bool is_string() const { return type == Type::String; }
  bool is_array() const { return type == Type::Array; }
  bool is_object() const { return type == Type::Object; }
  bool is_bool() const { return type == Type::Bool; }
};

// Parse a complete document. Throws FlexibleError("<what>: JSON parse error at
// offset N: ...") on malformed input, including a duplicated object key (a second
// value for the same key would silently win, which strict data must not allow).
Value parse(const std::string& text, const std::string& what);

// Serialise. Numbers print with 17 significant digits, so a parse/write round trip
// is exact.
std::string to_text(const Value& v);

// ── strict accessors. `where` names the object in every diagnostic. ──────────────
// Keys starting with '_' are maintainer comments and are ignored everywhere, as in
// job.cpp.
bool is_comment_key(const std::string& key);
const Value* find(const Value& obj, const std::string& key);
const Value& require(const Value& obj, const std::string& key,
                     const std::string& where);
void reject_unknown(const Value& obj, const std::vector<std::string>& allowed,
                    const std::string& where);
void require_all(const Value& obj, const std::vector<std::string>& required,
                 const std::string& where);
const Value& as_object(const Value& v, const std::string& where);
const Value& as_array(const Value& v, const std::string& where);
double as_number(const Value& v, const std::string& where);  // finite
bool as_bool(const Value& v, const std::string& where);
const std::string& as_string(const Value& v, const std::string& where);
int as_int(const Value& v, const std::string& where);  // integral, finite

[[noreturn]] void fail(const std::string& where, const std::string& msg);

}  // namespace json
}  // namespace flexible
}  // namespace topopt
