#pragma once

#include <stdexcept>
#include <string>
#include <vector>

namespace topopt {

// M5.1 — rule-based slicer-settings engine (ARCHITECTURE.md §1.3, §9 M5).
//
// Inputs: material family ("fdm" | "resin"), a worst-case stress margin, and
// the part's largest bounding-box edge (mm). Output: recommended walls,
// top/bottom layers, infill % and pattern (FDM) or a solid-print directive
// (resin), plus an optional low-margin warning. These are heuristic rules over
// a stress margin, NOT simulated infill (ARCHITECTURE.md §2).
//
// The rule table lives in settings/rules.json (human-seeded, DECISIONS.md
// 2026-07-08). This engine consumes that table; it never encodes the rule
// values. Computing the margin itself is pipeline wiring (M5.2/M5.3); this
// engine takes the margin as an input, per rules.json semantics_locked.

// Recommended slicer settings for one variant.
struct SlicerSettings {
  std::string family;  // echoes the input family ("fdm" | "resin")
  // FDM outputs — meaningful when family == "fdm" (0/empty otherwise).
  int walls = 0;
  int top_layers = 0;
  int bottom_layers = 0;
  int infill_percent = 0;
  std::string infill_pattern;
  // Resin output — meaningful when family == "resin" (empty otherwise).
  std::string print_mode;
  // Low-margin warning from the selected band ("" when the band has none).
  std::string warning;
};

// One FDM margin band (settings/rules.json fdm.margin_bands[]). Bands are
// ordered ascending; a band covers [previous margin_below, margin_below), and
// the last band is unbounded (rules.json margin_below = null → +infinity).
struct FdmBand {
  bool unbounded = false;     // last band: matches any margin at/above its floor
  double margin_below = 0.0;  // exclusive upper bound (ignored when unbounded)
  int walls = 0;
  int top_layers = 0;
  int bottom_layers = 0;
  int infill_percent = 0;
  std::string infill_pattern;
  std::string warning;  // "" when the band carries no warning
};

// One resin margin band (settings/rules.json resin.margin_bands[]).
struct ResinBand {
  bool unbounded = false;
  double margin_below = 0.0;
  std::string print_mode;
  std::string warning;
};

// Additive size-class modifiers (settings/rules.json fdm.size_modifiers.*).
// Absent keys are 0 (no change to that field).
struct SizeModifier {
  int walls = 0;
  int top_layers = 0;
  int bottom_layers = 0;
  int infill_percent = 0;
};

// [lo, hi] output clamp for one FDM field (settings/rules.json fdm.clamps.*).
struct FieldClamp {
  int lo = 0;
  int hi = 0;
};

// M5.2b — min-feature print warning (settings/rules.json min_feature_warning).
// Report-only text emitted per variant: when a variant's check_v3
// min_feature_violations count is at or above `threshold`, the job report
// carries `message_template` with the "{count}" placeholder replaced by the
// count. Never gates or modifies geometry (ARCHITECTURE §2). The section is
// optional in the table; when absent, `message_template` is "" (no warning).
struct MinFeatureWarning {
  std::string message_template;  // "" when the section is absent
  int threshold = 1;             // warn when violations >= threshold (> 0 default)
};

// The parsed rule table. A faithful in-memory image of settings/rules.json's
// engine-relevant sections (metadata / comment keys are ignored on load).
struct SettingsRules {
  std::vector<FdmBand> fdm_bands;
  SizeModifier fdm_small;
  SizeModifier fdm_medium;
  SizeModifier fdm_large;
  FieldClamp clamp_walls;
  FieldClamp clamp_top_layers;
  FieldClamp clamp_bottom_layers;
  FieldClamp clamp_infill_percent;
  std::vector<ResinBand> resin_bands;
  MinFeatureWarning min_feature_warning;  // M5.2b (optional; report-only)
};

// Thrown for any failure to load or apply the rule table: unreadable file,
// malformed JSON, a structurally invalid table, or a bad engine input.
class SettingsError : public std::runtime_error {
 public:
  explicit SettingsError(const std::string& msg) : std::runtime_error(msg) {}
};

// Size-class thresholds (settings/rules.json semantics_locked.size_classes:
// small <= 50 mm; medium <= 150 mm; large > 150 mm). Defined in prose in the
// locked table rather than as JSON numbers, so they are named constants here.
inline constexpr double kSmallMaxDimensionMm = 50.0;
inline constexpr double kMediumMaxDimensionMm = 150.0;

// Parse and structurally validate the rule table from JSON text (the
// settings/rules.json contents). Throws SettingsError on malformed JSON or a
// table missing the structure the engine depends on.
SettingsRules parse_settings_rules(const std::string& json_text);

// Read the file at `path` and parse it via parse_settings_rules(). Throws
// SettingsError if the file cannot be opened.
SettingsRules load_settings_rules_file(const std::string& path);

// Apply the rule table (settings/rules.json semantics_locked.evaluation_order):
// family gate → first band whose margin_below exceeds `margin` (a margin equal
// to a band's margin_below falls into the NEXT band) → additive size modifier
// for the part's size class → clamps. Deterministic; no other inputs.
//
// `family` must be "fdm" or "resin"; `worst_case_stress_margin` must be finite
// and >= 0; `max_part_dimension_mm` must be finite and > 0. Throws
// SettingsError otherwise.
SlicerSettings recommend_settings(const SettingsRules& rules,
                                  const std::string& family,
                                  double worst_case_stress_margin,
                                  double max_part_dimension_mm);

// M5.2b — format the per-variant min-feature print warning. `violations` is the
// variant's check_v3 min_feature_violations count (solid regions thinner than 2
// voxels, ARCHITECTURE §7 V3 gate 4). Returns "" when `violations` is below
// rules.min_feature_warning.threshold (no warning) or no template is configured;
// otherwise rules.min_feature_warning.message_template with every "{count}"
// occurrence replaced by `violations`. Report-only: never gates or modifies
// geometry. Throws SettingsError if `violations` is negative.
std::string min_feature_warning_text(const SettingsRules& rules, int violations);

}  // namespace topopt
