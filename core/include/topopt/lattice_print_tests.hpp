#pragma once

// ★ WHICH LATTICE TYPES THE MAINTAINER HAS PRINTED (lattice types round 1, M2 /
// 02-core-spec §6). MAINTAINER DATA: core/src/materials/lattice_print_tests.json. Core
// reads it and never writes it; a type not marked tested is offered with a
// "Not print-tested" tag, and he clears the tag by printing the type's sample block
// (topopt-cli lattice-sample) and editing the file.
//
// The loader is as strict as materials.cpp's: malformed JSON, an unknown key, a
// missing required key or a wrong-typed value is REFUSED, naming it. Keys that start
// with '_' are comments at every level (the file's own "_comment").
//
// THE ACCEPTED TYPE IDS ARE DERIVED, NOT LISTED (reviewer, 2026-09-30): every
// LatticeTopology id (lattice_topology_name over the enum) plus the planned sheet ids
// (lattice_planned_topology_ids). So a row the maintainer adds for any type core knows
// -- fccz and reentrant included -- loads, and a misspelling ("Gyroid") is refused BY
// NAME.
//
// An id with no row reads as NOT print-tested.

#include <map>
#include <stdexcept>
#include <string>

namespace topopt {

struct LatticePrintStatus {
  bool listed = false;        // the file has a row for this id
  bool print_tested = false;
  std::string date;           // "YYYY-MM-DD" when tested; "" when null
  std::string note;           // "" when null
};

using LatticePrintTests = std::map<std::string, LatticePrintStatus>;

class LatticePrintTestsError : public std::runtime_error {
 public:
  explicit LatticePrintTestsError(const std::string& msg) : std::runtime_error(msg) {}
};

// Parse the file's text. Schema (version 1):
//   { "schema_version": 1, "types": { "<id>": { "print_tested": bool,
//                                               "date": "YYYY-MM-DD" | null,
//                                               "note": string | null } } }
// `print_tested: true` requires a date.
LatticePrintTests parse_lattice_print_tests(const std::string& json_text);
LatticePrintTests load_lattice_print_tests_file(const std::string& path);

// The status of one id (absent -> not print-tested, listed = false).
LatticePrintStatus lattice_print_status(const LatticePrintTests& tests, const std::string& id);

}  // namespace topopt
