// Unit tests for the M5.1 settings rule engine (topopt/settings.hpp).
//
// No third-party test framework (ARCHITECTURE §4): a self-contained CHECK
// harness drives the public API only. The engine is pure C++/std, so the test
// runs in every build configuration (no OCCT, no Eigen). Boundary behaviour is
// asserted against BOTH the committed human-seeded settings/rules.json (path
// injected via SETTINGS_RULES_PATH) and small synthetic tables that exercise
// the parser's validation paths.

#include "topopt/settings.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string>

using topopt::load_settings_rules_file;
using topopt::min_feature_warning_text;
using topopt::parse_settings_rules;
using topopt::recommend_settings;
using topopt::SettingsError;
using topopt::SettingsRules;
using topopt::SlicerSettings;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// True iff calling `fn` throws SettingsError.
template <typename F>
bool throws_settings_error(F fn) {
  try {
    fn();
  } catch (const SettingsError&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

// The committed rule table, loaded once for the real-table boundary tests.
const SettingsRules& real_rules() {
  static SettingsRules r = load_settings_rules_file(SETTINGS_RULES_PATH);
  return r;
}

// A medium part (50 < dim <= 150): FDM size modifiers are empty, so band
// outputs pass through unchanged — the cleanest lens on band selection.
constexpr double kMediumDim = 100.0;

// --- FDM margin-band selection + boundary rule ----------------------------
//
// Band thresholds in the seeded table are 1.2, 1.5, 2.0, 4.0. A margin exactly
// on a threshold belongs to the NEXT (higher) band; strictly below stays in
// the lower band. Verified with a medium part so no size modifier interferes.
void test_fdm_bands() {
  const SettingsRules& r = real_rules();

  // Deep below the first threshold → strongest band (band 0), which carries a
  // low-margin warning.
  SlicerSettings s = recommend_settings(r, "fdm", 0.5, kMediumDim);
  CHECK(s.family == "fdm", "band0 family fdm");
  CHECK(s.walls == 6, "band0 walls 6");
  CHECK(s.top_layers == 7, "band0 top 7");
  CHECK(s.bottom_layers == 6, "band0 bottom 6");
  CHECK(s.infill_percent == 60, "band0 infill 60");
  CHECK(s.infill_pattern == "gyroid", "band0 gyroid");
  CHECK(!s.warning.empty(), "band0 carries a warning");
  CHECK(s.print_mode.empty(), "band0 no resin print_mode");

  // Just below 1.2 stays in band 0; exactly 1.2 crosses into band 1.
  CHECK(recommend_settings(r, "fdm", 1.199, kMediumDim).walls == 6,
        "1.199 -> band0 walls 6");
  SlicerSettings at12 = recommend_settings(r, "fdm", 1.2, kMediumDim);
  CHECK(at12.walls == 5, "margin==1.2 -> band1 (walls 5), boundary to NEXT");
  CHECK(at12.top_layers == 6, "band1 top 6");
  CHECK(at12.bottom_layers == 5, "band1 bottom 5");
  CHECK(at12.infill_percent == 50, "band1 infill 50");
  CHECK(at12.warning.empty(), "band1 has no warning");

  // 1.5 boundary: 1.499 -> band1, 1.5 -> band2.
  CHECK(recommend_settings(r, "fdm", 1.499, kMediumDim).walls == 5,
        "1.499 -> band1 walls 5");
  SlicerSettings at15 = recommend_settings(r, "fdm", 1.5, kMediumDim);
  CHECK(at15.walls == 4, "margin==1.5 -> band2 walls 4");
  CHECK(at15.infill_percent == 40, "band2 infill 40");

  // 2.0 boundary: 1.999 -> band2, 2.0 -> band3.
  CHECK(recommend_settings(r, "fdm", 1.999, kMediumDim).walls == 4,
        "1.999 -> band2 walls 4");
  SlicerSettings at20 = recommend_settings(r, "fdm", 2.0, kMediumDim);
  CHECK(at20.walls == 3, "margin==2.0 -> band3 walls 3");
  CHECK(at20.infill_percent == 25, "band3 infill 25");
  CHECK(at20.top_layers == 5, "band3 top 5");

  // 4.0 boundary: 3.999 -> band3, 4.0 -> band4 (the unbounded band).
  CHECK(recommend_settings(r, "fdm", 3.999, kMediumDim).walls == 3,
        "3.999 -> band3 walls 3");
  SlicerSettings at40 = recommend_settings(r, "fdm", 4.0, kMediumDim);
  CHECK(at40.walls == 2, "margin==4.0 -> band4 walls 2");
  CHECK(at40.infill_percent == 15, "band4 infill 15");
  CHECK(at40.infill_pattern == "grid", "band4 pattern grid");

  // Very large margin also lands in the unbounded band.
  CHECK(recommend_settings(r, "fdm", 1e6, kMediumDim).infill_pattern == "grid",
        "huge margin -> unbounded band4 (grid)");
}

// --- Size-class boundaries + additive modifiers ---------------------------
//
// small: dim <= 50 (+5 infill); medium: dim <= 150 (no change); large: dim >
// 150 (+1 top, +1 wall). Band 2 (margin 1.5..2.0: walls 4, top 5, infill 40)
// is well inside every clamp, so the modifier deltas are visible unclamped.
void test_size_classes() {
  const SettingsRules& r = real_rules();
  const double band2_margin = 1.7;  // in [1.5, 2.0)

  // dim == 50 is small (inclusive upper bound).
  SlicerSettings small = recommend_settings(r, "fdm", band2_margin, 50.0);
  CHECK(small.infill_percent == 45, "small (dim==50): infill 40 +5 = 45");
  CHECK(small.walls == 4, "small: walls unchanged");
  CHECK(small.top_layers == 5, "small: top unchanged");

  // dim just past 50 is medium (no modifier).
  SlicerSettings medium = recommend_settings(r, "fdm", band2_margin, 50.001);
  CHECK(medium.infill_percent == 40, "medium (dim=50.001): infill unchanged 40");
  CHECK(medium.walls == 4, "medium: walls unchanged");

  // dim == 150 is still medium (inclusive upper bound).
  CHECK(recommend_settings(r, "fdm", band2_margin, 150.0).infill_percent == 40,
        "dim==150 -> medium, infill unchanged");
  CHECK(recommend_settings(r, "fdm", band2_margin, 150.0).walls == 4,
        "dim==150 -> medium, walls unchanged");

  // dim just past 150 is large: +1 wall, +1 top.
  SlicerSettings large = recommend_settings(r, "fdm", band2_margin, 150.001);
  CHECK(large.walls == 5, "large (dim=150.001): walls 4 +1 = 5");
  CHECK(large.top_layers == 6, "large: top 5 +1 = 6");
  CHECK(large.infill_percent == 40, "large: infill unchanged");
  CHECK(large.bottom_layers == 4, "large: bottom unchanged");
}

// --- Clamps ---------------------------------------------------------------
//
// Clamps apply after modifiers. The seeded table: walls [2,6], infill [10,60].
// Band 0 (walls 6, infill 60) is at the ceiling, so any positive modifier is
// clamped back.
void test_clamps() {
  const SettingsRules& r = real_rules();

  // Small on band 0: infill 60 +5 = 65 -> clamped to the 60 ceiling.
  SlicerSettings small0 = recommend_settings(r, "fdm", 0.5, 30.0);
  CHECK(small0.infill_percent == 60, "small band0: 65 clamped to infill max 60");

  // Large on band 0: walls 6 +1 = 7 -> clamped to the 6 ceiling; top 7 +1 = 8
  // sits exactly on the top-layer ceiling (8) and is unchanged.
  SlicerSettings large0 = recommend_settings(r, "fdm", 0.5, 300.0);
  CHECK(large0.walls == 6, "large band0: 7 clamped to walls max 6");
  CHECK(large0.top_layers == 8, "large band0: top 7 +1 = 8 (== ceiling)");
}

// --- Resin path -----------------------------------------------------------
//
// Resin bands (threshold 1.5) return a solid-print directive and no FDM
// fields, regardless of part size.
void test_resin() {
  const SettingsRules& r = real_rules();

  SlicerSettings low = recommend_settings(r, "resin", 1.0, 80.0);
  CHECK(low.family == "resin", "resin family echoed");
  CHECK(low.print_mode == "solid", "resin low-margin print_mode solid");
  CHECK(!low.warning.empty(), "resin low-margin carries a warning");
  CHECK(low.walls == 0, "resin: no walls");
  CHECK(low.top_layers == 0, "resin: no top layers");
  CHECK(low.bottom_layers == 0, "resin: no bottom layers");
  CHECK(low.infill_percent == 0, "resin: no infill");
  CHECK(low.infill_pattern.empty(), "resin: no infill pattern");

  // Boundary: margin==1.5 -> NEXT (unbounded) band, which has no warning.
  CHECK(recommend_settings(r, "resin", 1.499, 80.0).warning.empty() == false,
        "resin 1.499 -> low band, warning present");
  SlicerSettings hi = recommend_settings(r, "resin", 1.5, 80.0);
  CHECK(hi.print_mode == "solid", "resin high-margin print_mode solid");
  CHECK(hi.warning.empty(), "resin margin==1.5 -> unbounded band, no warning");

  // Part size does not affect the resin path (no modifiers/clamps).
  CHECK(recommend_settings(r, "resin", 1.0, 500.0).print_mode == "solid",
        "resin ignores part size");
}

// --- Input validation -----------------------------------------------------
void test_input_validation() {
  const SettingsRules& r = real_rules();
  const double inf = std::numeric_limits<double>::infinity();
  const double nan = std::numeric_limits<double>::quiet_NaN();

  CHECK(throws_settings_error([&] { recommend_settings(r, "abs", 2.0, 100.0); }),
        "unknown family throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "FDM", 2.0, 100.0); }),
        "family is case-sensitive (\"FDM\" throws)");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", -0.1, 100.0); }),
        "negative margin throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", nan, 100.0); }),
        "NaN margin throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", inf, 100.0); }),
        "inf margin throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", 2.0, 0.0); }),
        "zero part dimension throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", 2.0, -5.0); }),
        "negative part dimension throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", 2.0, inf); }),
        "inf part dimension throws");
  CHECK(throws_settings_error([&] { recommend_settings(r, "fdm", 2.0, nan); }),
        "NaN part dimension throws");

  // margin == 0 is allowed (a fully overloaded part) and lands in band 0.
  CHECK(recommend_settings(r, "fdm", 0.0, 100.0).walls == 6,
        "margin 0 allowed -> band0");
}

// --- Parsing / structural validation --------------------------------------
void test_parse_real_table() {
  const SettingsRules& r = real_rules();
  CHECK(r.fdm_bands.size() == 5, "seeded table has 5 fdm bands");
  CHECK(r.resin_bands.size() == 2, "seeded table has 2 resin bands");
  CHECK(r.fdm_bands.back().unbounded, "last fdm band is unbounded");
  CHECK(r.resin_bands.back().unbounded, "last resin band is unbounded");
  CHECK(r.clamp_walls.lo == 2 && r.clamp_walls.hi == 6, "walls clamp [2,6]");
  CHECK(r.clamp_infill_percent.lo == 10 && r.clamp_infill_percent.hi == 60,
        "infill clamp [10,60]");
  CHECK(r.fdm_small.infill_percent == 5, "small modifier +5 infill");
  CHECK(r.fdm_large.walls == 1 && r.fdm_large.top_layers == 1,
        "large modifier +1 wall +1 top");
}

void test_parse_errors() {
  // Malformed JSON.
  CHECK(throws_settings_error([] { parse_settings_rules("{ not json"); }),
        "malformed JSON throws");
  CHECK(throws_settings_error(
            [] { load_settings_rules_file("does_not_exist_98765.json"); }),
        "missing file throws");

  // Missing fdm section.
  CHECK(throws_settings_error([] {
          parse_settings_rules(R"({"resin":{"margin_bands":[]}})");
        }),
        "missing fdm section throws");

  // Last band not unbounded (no null margin_below terminator).
  CHECK(throws_settings_error([] {
          parse_settings_rules(R"({
            "fdm": {
              "margin_bands": [
                {"margin_below": 2.0, "walls": 3, "top_layers": 4,
                 "bottom_layers": 3, "infill_percent": 20,
                 "infill_pattern": "grid"}
              ],
              "size_modifiers": {"small": {}, "medium": {}, "large": {}},
              "clamps": {"walls": [2,6], "top_layers": [3,8],
                         "bottom_layers": [3,8], "infill_percent": [10,60]}
            },
            "resin": {"margin_bands": [{"margin_below": null,
                                        "print_mode": "solid"}]}
          })");
        }),
        "fdm table without an unbounded terminal band throws");

  // Bands not ascending by margin_below.
  CHECK(throws_settings_error([] {
          parse_settings_rules(R"({
            "fdm": {
              "margin_bands": [
                {"margin_below": 2.0, "walls": 3, "top_layers": 4,
                 "bottom_layers": 3, "infill_percent": 20,
                 "infill_pattern": "grid"},
                {"margin_below": 1.0, "walls": 4, "top_layers": 5,
                 "bottom_layers": 4, "infill_percent": 30,
                 "infill_pattern": "grid"},
                {"margin_below": null, "walls": 2, "top_layers": 4,
                 "bottom_layers": 3, "infill_percent": 15,
                 "infill_pattern": "grid"}
              ],
              "size_modifiers": {"small": {}, "medium": {}, "large": {}},
              "clamps": {"walls": [2,6], "top_layers": [3,8],
                         "bottom_layers": [3,8], "infill_percent": [10,60]}
            },
            "resin": {"margin_bands": [{"margin_below": null,
                                        "print_mode": "solid"}]}
          })");
        }),
        "non-ascending fdm bands throw");

  // A band missing a required numeric field.
  CHECK(throws_settings_error([] {
          parse_settings_rules(R"({
            "fdm": {
              "margin_bands": [
                {"margin_below": null, "walls": 2, "top_layers": 4,
                 "bottom_layers": 3, "infill_pattern": "grid"}
              ],
              "size_modifiers": {"small": {}, "medium": {}, "large": {}},
              "clamps": {"walls": [2,6], "top_layers": [3,8],
                         "bottom_layers": [3,8], "infill_percent": [10,60]}
            },
            "resin": {"margin_bands": [{"margin_below": null,
                                        "print_mode": "solid"}]}
          })");
        }),
        "fdm band missing infill_percent throws");

  // A well-formed minimal synthetic table parses and evaluates.
  SettingsRules mini = parse_settings_rules(R"({
    "fdm": {
      "margin_bands": [
        {"margin_below": 2.0, "walls": 5, "top_layers": 6, "bottom_layers": 5,
         "infill_percent": 45, "infill_pattern": "gyroid",
         "warning": "weak"},
        {"margin_below": null, "walls": 2, "top_layers": 4, "bottom_layers": 3,
         "infill_percent": 15, "infill_pattern": "grid"}
      ],
      "size_modifiers": {"small": {"infill_percent": 10}, "medium": {},
                         "large": {"walls": 2}},
      "clamps": {"walls": [2,6], "top_layers": [3,8], "bottom_layers": [3,8],
                 "infill_percent": [10,60]}
    },
    "resin": {"margin_bands": [
      {"margin_below": 1.5, "print_mode": "solid", "warning": "brittle"},
      {"margin_below": null, "print_mode": "solid"}
    ]}
  })");
  CHECK(mini.fdm_bands.size() == 2, "mini table 2 fdm bands");
  // Below 2.0 -> first band; small (+10 infill) 45+10 = 55.
  SlicerSettings ms = recommend_settings(mini, "fdm", 1.0, 20.0);
  CHECK(ms.infill_percent == 55, "mini small: 45 +10 = 55");
  CHECK(ms.warning == "weak", "mini band0 warning surfaced");
  // large (+2 walls) on band0: 5 +2 = 7 -> clamped to 6.
  CHECK(recommend_settings(mini, "fdm", 1.0, 400.0).walls == 6,
        "mini large: 7 clamped to 6");
}

// --- M5.2b min-feature print warning --------------------------------------
//
// The report-only warning text is driven by settings/rules.json's
// min_feature_warning section (template + threshold). Verified against the
// committed real table and synthetic tables (custom threshold, absent section,
// malformed section).
void test_min_feature_warning() {
  auto has = [](const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
  };
  const SettingsRules& r = real_rules();

  // The committed table parses: threshold 1 and a non-empty template that
  // carries the "{count}" placeholder.
  CHECK(r.min_feature_warning.threshold == 1, "real table threshold 1");
  CHECK(!r.min_feature_warning.message_template.empty(),
        "real table has a min-feature template");
  CHECK(has(r.min_feature_warning.message_template, "{count}"),
        "real template carries {count} placeholder");

  // Below threshold (0 violations with threshold 1) -> no warning.
  CHECK(min_feature_warning_text(r, 0).empty(), "0 violations -> no warning");

  // At/above threshold -> template with {count} replaced by the count, and the
  // literal placeholder gone.
  std::string w1 = min_feature_warning_text(r, 1);
  CHECK(!w1.empty(), "1 violation -> warning present");
  CHECK(has(w1, "1 region"), "warning names the count (1)");
  CHECK(!has(w1, "{count}"), "placeholder substituted (1)");
  std::string w3 = min_feature_warning_text(r, 3);
  CHECK(has(w3, "3 region"), "warning names the count (3)");
  CHECK(!has(w3, "{count}"), "placeholder substituted (3)");

  // Negative violations are rejected.
  CHECK(throws_settings_error([&] { min_feature_warning_text(r, -1); }),
        "negative violations throws");

  // A table WITHOUT a min_feature_warning section: defaults (threshold 1, empty
  // template). Parsing succeeds (backward compatible) and, with no template,
  // no warning is produced even for a positive count.
  SettingsRules no_section = parse_settings_rules(R"({
    "fdm": {
      "margin_bands": [
        {"margin_below": null, "walls": 2, "top_layers": 4, "bottom_layers": 3,
         "infill_percent": 15, "infill_pattern": "grid"}
      ],
      "size_modifiers": {"small": {}, "medium": {}, "large": {}},
      "clamps": {"walls": [2,6], "top_layers": [3,8], "bottom_layers": [3,8],
                 "infill_percent": [10,60]}
    },
    "resin": {"margin_bands": [{"margin_below": null, "print_mode": "solid"}]}
  })");
  CHECK(no_section.min_feature_warning.message_template.empty(),
        "absent section -> empty template");
  CHECK(no_section.min_feature_warning.threshold == 1,
        "absent section -> default threshold 1");
  CHECK(min_feature_warning_text(no_section, 5).empty(),
        "empty template -> no warning even at 5 violations");

  // A custom threshold (3) and a template with two {count} placeholders: below
  // threshold is silent; at threshold both placeholders are substituted.
  SettingsRules custom = parse_settings_rules(R"({
    "fdm": {
      "margin_bands": [
        {"margin_below": null, "walls": 2, "top_layers": 4, "bottom_layers": 3,
         "infill_percent": 15, "infill_pattern": "grid"}
      ],
      "size_modifiers": {"small": {}, "medium": {}, "large": {}},
      "clamps": {"walls": [2,6], "top_layers": [3,8], "bottom_layers": [3,8],
                 "infill_percent": [10,60]}
    },
    "resin": {"margin_bands": [{"margin_below": null, "print_mode": "solid"}]},
    "min_feature_warning": {"template": "{count} thin / {count} total",
                            "threshold": 3}
  })");
  CHECK(custom.min_feature_warning.threshold == 3, "custom threshold 3 parsed");
  CHECK(min_feature_warning_text(custom, 2).empty(),
        "below custom threshold -> no warning");
  CHECK(min_feature_warning_text(custom, 3) == "3 thin / 3 total",
        "both {count} placeholders substituted");

  // Malformed sections are rejected: non-object, and a non-string template.
  CHECK(throws_settings_error([] {
          parse_settings_rules(R"({
            "fdm": {"margin_bands": [{"margin_below": null, "walls": 2,
              "top_layers": 4, "bottom_layers": 3, "infill_percent": 15,
              "infill_pattern": "grid"}],
              "size_modifiers": {"small": {}, "medium": {}, "large": {}},
              "clamps": {"walls": [2,6], "top_layers": [3,8],
                         "bottom_layers": [3,8], "infill_percent": [10,60]}},
            "resin": {"margin_bands": [{"margin_below": null,
                                        "print_mode": "solid"}]},
            "min_feature_warning": {"template": 3}
          })");
        }),
        "non-string min-feature template throws");
}

}  // namespace

int main() {
  try {
    test_fdm_bands();
    test_size_classes();
    test_clamps();
    test_resin();
    test_input_validation();
    test_parse_real_table();
    test_parse_errors();
    test_min_feature_warning();
  } catch (const std::exception& e) {
    std::fprintf(stderr, "UNEXPECTED EXCEPTION: %s\n", e.what());
    return 1;
  }

  if (g_failures == 0) {
    std::printf("settings rule engine (M5.1): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "settings (M5.1): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
