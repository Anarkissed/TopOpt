#pragma once

#include <map>
#include <stdexcept>
#include <string>

namespace topopt {

// A single material record as defined by ARCHITECTURE.md §6. Every field is
// mandatory; the loader rejects any material that is missing one, carries an
// unknown one, or violates the value rules below.
struct Material {
  double youngs_modulus_mpa = 0.0;
  double yield_strength_mpa = 0.0;
  double density_g_cm3 = 0.0;
  double z_knockdown = 0.0;   // (0, 1]; resins must be exactly 1.0
  double poisson = 0.0;
  std::string family;         // "fdm" or "resin"
};

// Thrown for any failure to load a material set: unreadable file, malformed
// JSON, or a schema/value-rule violation. The message names the offending
// material and field where possible.
class MaterialError : public std::runtime_error {
 public:
  explicit MaterialError(const std::string& msg) : std::runtime_error(msg) {}
};

// Name -> Material. Ordered map keeps iteration deterministic for tests/reports.
using MaterialLibrary = std::map<std::string, Material>;

// Parse and validate a materials set from JSON text (the materials.json
// contents). Throws MaterialError on any malformed input or rule violation.
// Validation per ARCHITECTURE.md §6:
//   - top level is an object of { name: material_object }
//   - every material has exactly the six fields, no more, no fewer
//   - z_knockdown is in (0, 1]
//   - family is "fdm" or "resin"; a resin's z_knockdown must be exactly 1.0
MaterialLibrary parse_materials(const std::string& json_text);

// Read the file at `path` and parse it via parse_materials(). Throws
// MaterialError if the file cannot be opened.
MaterialLibrary load_materials_file(const std::string& path);

}  // namespace topopt
