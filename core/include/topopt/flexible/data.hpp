#pragma once

#include <map>
#include <string>
#include <vector>

#include "topopt/flexible/error.hpp"

namespace topopt {
namespace flexible {

// ════════════════════════════════════════════════════════════════════════════════
// F1 — THE MAINTAINER'S DATA, LOADED STRICTLY
//
// Two maintainer-seeded files (DECISIONS 2026-09-27 item 3):
//   core/src/materials/flexible_materials.json            — the filament catalogue
//   core/src/materials/flexible_curves/<table>.json       — squish curve tables,
//       schema docs/design/flexibles/data/curve_table.schema.json
//
// The same strictness as materials.cpp: an unknown key at any documented level, a
// missing required key or a value of the wrong type REJECTS the whole file. A
// loading curve that is not strictly increasing in strain AND stress, or a
// relative_density outside (0, 1], rejects it too.
//
// ★ NULL MEANS UNKNOWN (README "Rules for agents"). Every nullable field below
// carries a `known` flag instead of a default, and nothing in this module ever
// reads the value of an unknown field.
// ════════════════════════════════════════════════════════════════════════════════

// A nullable number.
struct MaybeNumber {
  bool known = false;
  double value = 0.0;
};

// A nullable [lo, hi] pair (a scalar is read as lo == hi where the file allows
// one — drying temperature and hours).
struct MaybeRange {
  bool known = false;
  double lo = 0.0;
  double hi = 0.0;
};

// flexible_materials.json → error_band_defaults. Fractions of the predicted
// squish depth (02 §7). `status` and `note` are carried for the receipt.
struct ErrorBands {
  double literature_same_material = 0.0;
  double calibrated = 0.0;
  double proxy = 0.0;
  std::string status;
  std::string note;
};

struct Drying {
  bool known = false;       // false when the file says null
  MaybeRange temp_c;
  MaybeRange hours;
  MaybeNumber hours_min;
  std::string method;       // "" when absent
};

struct SolidModulus {
  bool known = false;       // false when the file says null
  double value_mpa = 0.0;
  std::string condition;
};

// One filament. Field names follow the file. The required set is the fifteen keys
// every entry carries; the rest are optional and are "" / empty / unknown when
// absent.
struct Material {
  std::string id;
  // required
  std::string display_name;
  std::string family;
  MaybeNumber shore_a_nominal;
  bool foaming = false;
  std::string tier;  // "literature" | "proxy_candidate" | "calibrate_first"
  MaybeRange nozzle_temp_range_c;
  MaybeRange bed_temp_c;
  MaybeRange speed_mm_s;
  bool retraction_known = false;
  std::string retraction;
  Drying drying;
  bool ams_compatible_known = false;
  bool ams_compatible = false;
  MaybeNumber solid_density_g_cm3;
  SolidModulus solid_youngs_modulus_mpa;
  std::vector<std::string> squish_tables;
  std::vector<std::string> sources;
  // optional
  MaybeNumber shore_d_nominal;
  // ★ THE TEMPERATURES A USER MAY PICK (R10). Empty when the key is absent — and
  // then a FOAMING material offers no temperature at all.
  std::vector<double> offered_nozzle_temps_c;
  std::string offered_temps_note;
  std::map<double, double> flow_pct_at_temp;
  std::map<double, double> hardness_by_temp_shore_a;
  MaybeRange hardness_range_shore_a;
  MaybeNumber max_volumetric_flow_mm3_s;
  std::string nozzle_temp_note, hardness_note, flow_note, note, storage,
      hyperelastic_constants;
};

struct MaterialCatalogue {
  int schema_version = 0;
  std::string status;
  std::map<std::string, std::string> tiers;  // tier name -> meaning
  ErrorBands error_bands;
  std::map<std::string, Material> materials;
  std::map<std::string, std::string> excluded_v1;
};

// Throws FlexibleError naming the material and key.
MaterialCatalogue parse_material_catalogue(const std::string& json_text);
MaterialCatalogue load_material_catalogue(const std::string& path);

// One point of a loading curve: NOMINAL strain (dimensionless) and NOMINAL stress
// (MPa), exactly as the table states them (02 §2: the specimen convention).
struct CurvePoint {
  double strain = 0.0;
  double stress_mpa = 0.0;
};

struct Specimen {
  std::string shape;  // "cylinder" | "block"
  MaybeNumber diameter_mm, width_mm, depth_mm;
  double height_mm = 0.0;
  double skin_total_mm = 0.0;
  bool has_side_skin = false;
  bool side_skin = false;
  MaybeNumber cells_across;
  MaybeNumber mass_density_g_cm3;
};

struct Conditioning {
  int cycle_reported = 0;
  double rate_mm_per_min = 0.0;
  bool has_toe_corrected = false;
  bool toe_corrected = false;
};

// One curve-table entry (curve_table.schema.json → entries[]).
struct CurveEntry {
  std::string table;  // the file it came from (for the receipt)
  std::string id;
  std::string tier;   // "literature" | "calibrated" | "proxy"
  std::string material_id;
  double nozzle_temp_c = 0.0;
  MaybeNumber flow_pct;
  std::string topology;         // "gyroid" | "honeycomb"
  std::string geometry_source;  // "slicer_infill" | "generated_mesh"
  MaybeNumber beads_per_wall;   // integer 1..2 when known
  MaybeNumber bead_width_mm;
  double relative_density = 0.0;       // (0, 1], meaning per the basis below
  std::string relative_density_basis;  // nominal_infill | estimated_core | measured_core | designed
  MaybeNumber est_core_relative_density;
  MaybeNumber cell_mm;
  Specimen specimen;
  Conditioning conditioning;
  std::vector<CurvePoint> loading;     // strictly increasing in both
  bool has_unloading = false;          // unloading: null or absent => false
  std::vector<CurvePoint> unloading;
  double strain_max_measured = 0.0;    // >= the last loading strain
  MaybeNumber replicates;
  MaybeNumber rel_sd;
  std::string source;
};

struct CurveTable {
  std::string name;  // file name, e.g. "iacob2024_curves.json"
  int schema_version = 0;
  std::vector<CurveEntry> entries;
};

// Throws FlexibleError naming the entry id and key.
CurveTable parse_curve_table(const std::string& json_text, const std::string& name);

// The catalogue plus every table its materials name, cross-checked: every entry's
// material exists and LISTS the table the entry came from; entry ids are unique.
struct FlexibleData {
  MaterialCatalogue catalogue;
  std::vector<CurveTable> tables;
};

// Cross-check an already-parsed catalogue and tables. Throws FlexibleError.
FlexibleData make_flexible_data(MaterialCatalogue catalogue,
                                std::vector<CurveTable> tables);

// Load the catalogue at `materials_path` and every table it names from the
// `flexible_curves/` directory beside it.
FlexibleData load_flexible_data(const std::string& materials_path);

// ════════════════════════════════════════════════════════════════════════════════
// F2 — THE DENSITY AXIS (02 §2, R2)
//
// Iacob's rows are keyed on NOMINAL slicer infill, which is not the printed
// density: their own Table 3 masses put the 10 % gyroid core at ~0.14. The lookup
// therefore keys every row on the ESTIMATED PRINTED-CORE density.
//
// The map is built per (material, topology) from the rows that CARRY
// est_core_relative_density — for Iacob, the 190 °C rows, the only temperature
// where the solid density is known — and applied to EVERY temperature of that
// pattern: the slicer paths are the same and flow compensation targets the same
// bead width. That is an assumption (02 §2 "flag it"), and it is recorded on every
// result as the basis string.
// ════════════════════════════════════════════════════════════════════════════════

struct DensityMapPoint {
  double nominal = 0.0;  // the entry's relative_density on the nominal_infill basis
  double core = 0.0;     // its est_core_relative_density
};

struct DensityAxis {
  std::string material_id;
  std::string topology;
  // ascending in nominal; empty when the material's rows are not on the
  // nominal_infill basis (they are then used as stated)
  std::vector<DensityMapPoint> map;
  double mapping_temp_c = 0.0;  // the temperature the map was measured at
  // "estimated_core (190 °C mapping)" for Iacob; for rows stated on a core basis,
  // that basis ("measured_core", "designed", "estimated_core").
  std::string density_basis;
};

// Throws FlexibleError when the rows cannot define one axis: est_core values from
// more than one temperature, a nominal value mapped twice, a map that is not
// strictly increasing, a nominal-basis row whose value is not in the map, or bases
// mixed within one (material, topology).
DensityAxis build_density_axis(const FlexibleData& data,
                               const std::string& material_id,
                               const std::string& topology);

// The printed-core density of one entry on `axis`. Throws FlexibleError if the
// entry's nominal value is not on the map.
double core_density_of(const DensityAxis& axis, const CurveEntry& entry);

}  // namespace flexible
}  // namespace topopt
