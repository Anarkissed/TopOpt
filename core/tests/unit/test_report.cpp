// Unit tests for the M5.2 job report (topopt/report.hpp).
//
// No third-party test framework (ARCHITECTURE §4): a self-contained CHECK
// harness drives the public API only. The report module is pure C++/std (no
// OCCT, no Eigen), so this test runs in every build configuration. It covers:
//   * compute_stress_margin (the locked margin_definition), incl. the
//     unbounded-margin (zero-stress) and resin (k=1) cases and input validation;
//   * job_report_json emits the schema the validator accepts (round trip), with
//     the derived volume_saved_fraction, non-finite -> null, and string escaping;
//   * validate_job_report_json rejects documents that violate the schema
//     (missing/wrong-typed fields, non-integer counts, inconsistent volume
//     saved, out-of-range values, malformed JSON) — the schema has teeth.

#include "topopt/report.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <string>

using topopt::compute_stress_margin;
using topopt::JobReport;
using topopt::job_report_json;
using topopt::ReportError;
using topopt::SlicerSettings;
using topopt::StressMargin;
using topopt::validate_job_report_json;
using topopt::VariantReport;
using topopt::Vec3;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();

template <typename F>
bool throws_report_error(F fn) {
  try {
    fn();
  } catch (const ReportError&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

bool near(double a, double b, double tol = 1e-9) { return std::fabs(a - b) <= tol; }

bool contains(const std::string& hay, const std::string& needle) {
  return hay.find(needle) != std::string::npos;
}

// --- compute_stress_margin: the locked margin_definition -------------------

void test_margin_basic() {
  // yield 55, k 0.55: in_plane = 55/27.5 = 2.0; interlayer = (0.55*55)/13.75
  //                 = 30.25/13.75 = 2.2; worst = min = 2.0 (in_plane governs).
  StressMargin m = compute_stress_margin(55.0, 0.55, 27.5, 13.75);
  CHECK(near(m.in_plane, 2.0), "in_plane 2.0");
  CHECK(near(m.interlayer, 2.2), "interlayer 2.2");
  CHECK(near(m.worst_case, 2.0), "worst_case = in_plane");

  // Interlayer governs: in_plane = 55/11 = 5.0; interlayer = (0.5*55)/55 = 0.5.
  StressMargin m2 = compute_stress_margin(55.0, 0.5, 11.0, 55.0);
  CHECK(near(m2.in_plane, 5.0), "in_plane 5.0");
  CHECK(near(m2.interlayer, 0.5), "interlayer 0.5");
  CHECK(near(m2.worst_case, 0.5), "worst_case = interlayer");
}

void test_margin_unbounded() {
  // Zero von Mises -> in_plane unbounded; worst_case = finite interlayer.
  StressMargin m = compute_stress_margin(40.0, 0.7, 0.0, 14.0);
  CHECK(std::isinf(m.in_plane), "in_plane inf when vm=0");
  CHECK(near(m.interlayer, (0.7 * 40.0) / 14.0), "interlayer finite");
  CHECK(near(m.worst_case, (0.7 * 40.0) / 14.0), "worst_case = interlayer (min)");

  // Zero interlayer tension (flat-printed part, pure in-plane load) -> interlayer
  // unbounded; worst_case = finite in_plane. This is a realistic common case.
  StressMargin m2 = compute_stress_margin(40.0, 0.7, 20.0, 0.0);
  CHECK(std::isinf(m2.interlayer), "interlayer inf when it=0");
  CHECK(near(m2.in_plane, 2.0), "in_plane 2.0");
  CHECK(near(m2.worst_case, 2.0), "worst_case = in_plane (min)");

  // Both zero -> both unbounded -> worst_case unbounded (unloaded part).
  StressMargin m3 = compute_stress_margin(40.0, 0.7, 0.0, 0.0);
  CHECK(std::isinf(m3.worst_case), "worst_case inf when both stresses 0");
}

void test_margin_resin() {
  // Resin z_knockdown = 1: with equal stresses the two terms coincide.
  StressMargin m = compute_stress_margin(60.0, 1.0, 15.0, 15.0);
  CHECK(near(m.in_plane, 4.0), "resin in_plane 4.0");
  CHECK(near(m.interlayer, 4.0), "resin interlayer 4.0 (k=1)");
  CHECK(near(m.worst_case, 4.0), "resin worst_case 4.0");
}

void test_margin_validation() {
  CHECK(throws_report_error([] { compute_stress_margin(0.0, 0.5, 10.0, 5.0); }),
        "yield 0 throws");
  CHECK(throws_report_error([] { compute_stress_margin(-1.0, 0.5, 10.0, 5.0); }),
        "yield negative throws");
  CHECK(throws_report_error([] { compute_stress_margin(kInf, 0.5, 10.0, 5.0); }),
        "yield inf throws");
  CHECK(throws_report_error([] { compute_stress_margin(50.0, 0.0, 10.0, 5.0); }),
        "k 0 throws");
  CHECK(throws_report_error([] { compute_stress_margin(50.0, 1.01, 10.0, 5.0); }),
        "k > 1 throws");
  CHECK(throws_report_error([] { compute_stress_margin(50.0, -0.5, 10.0, 5.0); }),
        "k negative throws");
  CHECK(throws_report_error([] { compute_stress_margin(50.0, 0.5, -1.0, 5.0); }),
        "negative von Mises throws");
  CHECK(throws_report_error(
            [] { compute_stress_margin(50.0, 0.5, std::nan(""), 5.0); }),
        "NaN von Mises throws");
  CHECK(throws_report_error([] { compute_stress_margin(50.0, 0.5, 10.0, -1.0); }),
        "negative interlayer throws");
  CHECK(throws_report_error([] { compute_stress_margin(50.0, 0.5, 10.0, kInf); }),
        "inf interlayer throws");
  // k = 1 (resin) is allowed.
  CHECK(!throws_report_error([] { compute_stress_margin(50.0, 1.0, 10.0, 5.0); }),
        "k = 1 allowed");
}

// --- Report assembly helpers ----------------------------------------------

SlicerSettings fdm_settings() {
  SlicerSettings s;
  s.family = "fdm";
  s.walls = 5;
  s.top_layers = 6;
  s.bottom_layers = 5;
  s.infill_percent = 50;
  s.infill_pattern = "gyroid";
  return s;
}

SlicerSettings resin_settings() {
  SlicerSettings s;
  s.family = "resin";
  s.print_mode = "solid";
  s.warning = "Predicted stress margin is below 1.5x.";
  return s;
}

// --- job_report_json round trip + emitted content -------------------------

void test_serialize_validate() {
  JobReport r;
  r.material = "PLA";

  VariantReport v0;
  v0.volume_fraction = 0.5;
  v0.max_stress_mpa = 20.0;
  v0.max_interlayer_tension_mpa = 5.0;
  v0.margin = compute_stress_margin(55.0, 0.55, 20.0, 5.0);
  v0.orientation = Vec3{0.0, 0.0, 1.0};
  v0.settings = fdm_settings();
  r.variants.push_back(v0);

  VariantReport v1;
  v1.volume_fraction = 0.3;
  v1.max_stress_mpa = 30.0;
  v1.max_interlayer_tension_mpa = 8.0;
  v1.margin = compute_stress_margin(60.0, 1.0, 30.0, 8.0);
  v1.orientation = Vec3{1.0, 0.0, 0.0};
  v1.settings = resin_settings();
  r.variants.push_back(v1);

  std::string json = job_report_json(r);

  // The document this module emits must satisfy its own schema validator.
  CHECK(!throws_report_error([&] { validate_job_report_json(json); }),
        "emitted report validates");

  // Stable structural content.
  CHECK(contains(json, "\"material\": \"PLA\""), "material emitted");
  CHECK(contains(json, "\"variants\""), "variants key emitted");
  CHECK(contains(json, "\"volume_fraction\""), "volume_fraction emitted");
  CHECK(contains(json, "\"volume_saved_fraction\""),
        "derived volume_saved_fraction emitted");
  CHECK(contains(json, "\"max_stress_mpa\""), "max_stress emitted");
  CHECK(contains(json, "\"max_interlayer_tension_mpa\""),
        "max_interlayer_tension emitted");
  CHECK(contains(json, "\"margin\""), "margin object emitted");
  CHECK(contains(json, "\"in_plane\""), "margin.in_plane emitted");
  CHECK(contains(json, "\"interlayer\""), "margin.interlayer emitted");
  CHECK(contains(json, "\"worst_case\""), "margin.worst_case emitted");
  CHECK(contains(json, "\"orientation\""), "orientation object emitted");
  CHECK(contains(json, "\"settings\""), "settings object emitted");

  // Settings content for both families.
  CHECK(contains(json, "\"family\": \"fdm\""), "fdm family emitted");
  CHECK(contains(json, "\"infill_pattern\": \"gyroid\""), "infill pattern emitted");
  CHECK(contains(json, "\"walls\": 5"), "walls integer emitted");
  CHECK(contains(json, "\"family\": \"resin\""), "resin family emitted");
  CHECK(contains(json, "\"print_mode\": \"solid\""), "resin print_mode emitted");
}

void test_volume_saved_derived() {
  // volume_saved_fraction must be emitted as exactly 1 - volume_fraction.
  JobReport r;
  r.material = "PETG";
  VariantReport v;
  v.volume_fraction = 0.3;  // -> volume_saved_fraction 0.7
  v.max_stress_mpa = 10.0;
  v.max_interlayer_tension_mpa = 2.0;
  v.margin = compute_stress_margin(50.0, 0.7, 10.0, 2.0);
  v.orientation = Vec3{0.0, 1.0, 0.0};
  v.settings = fdm_settings();
  r.variants.push_back(v);

  std::string json = job_report_json(r);
  CHECK(contains(json, "\"volume_fraction\": 0.3"), "volume_fraction 0.3 emitted");
  CHECK(contains(json, "\"volume_saved_fraction\": 0.7"),
        "volume_saved_fraction 0.7 derived");
  CHECK(!throws_report_error([&] { validate_job_report_json(json); }),
        "derived report validates");
}

void test_nonfinite_margin_null() {
  // A variant whose interlayer tension is 0 -> interlayer margin unbounded ->
  // emitted as JSON null, and the document still validates (number-or-null).
  JobReport r;
  r.material = "ASA";
  VariantReport v;
  v.volume_fraction = 0.5;
  v.max_stress_mpa = 20.0;
  v.max_interlayer_tension_mpa = 0.0;
  v.margin = compute_stress_margin(50.0, 0.6, 20.0, 0.0);  // interlayer = inf
  v.orientation = Vec3{0.0, 0.0, 1.0};
  v.settings = fdm_settings();
  r.variants.push_back(v);

  std::string json = job_report_json(r);
  CHECK(contains(json, "\"interlayer\": null"), "unbounded margin -> null");
  CHECK(!throws_report_error([&] { validate_job_report_json(json); }),
        "report with null margin validates");
}

void test_empty_variants() {
  JobReport r;
  r.material = "PLA";  // no variants
  std::string json = job_report_json(r);
  CHECK(contains(json, "\"variants\": []"), "empty variants array emitted");
  CHECK(!throws_report_error([&] { validate_job_report_json(json); }),
        "empty-variant report validates");
}

void test_string_escaping() {
  // Material name and a warning containing characters that must be escaped.
  JobReport r;
  r.material = "PL\"A\\x";  // quote + backslash
  VariantReport v;
  v.volume_fraction = 0.5;
  v.max_stress_mpa = 20.0;
  v.max_interlayer_tension_mpa = 5.0;
  v.margin = compute_stress_margin(55.0, 0.55, 20.0, 5.0);
  v.orientation = Vec3{0.0, 0.0, 1.0};
  v.settings = fdm_settings();
  v.settings.warning = "line1\nline2\ttab";  // newline + tab
  r.variants.push_back(v);

  std::string json = job_report_json(r);
  CHECK(contains(json, "PL\\\"A\\\\x"), "quote and backslash escaped");
  CHECK(contains(json, "line1\\nline2\\ttab"), "control chars escaped");
  // Escaped output must still be a valid, schema-conforming document.
  CHECK(!throws_report_error([&] { validate_job_report_json(json); }),
        "escaped report validates");
}

// --- validator teeth: reject schema violations ----------------------------

// A canonical valid document; the teeth below mutate exactly one thing.
const char* kValid = R"({
  "material": "PLA",
  "variants": [
    {
      "volume_fraction": 0.5,
      "volume_saved_fraction": 0.5,
      "max_stress_mpa": 20.0,
      "max_interlayer_tension_mpa": 5.0,
      "margin": { "in_plane": 2.75, "interlayer": 6.05, "worst_case": 2.75 },
      "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
      "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" }
    }
  ]
})";

void test_validator_accepts_canonical() {
  CHECK(!throws_report_error([] { validate_job_report_json(kValid); }),
        "canonical document validates");
}

void test_validator_rejects() {
  auto rejects = [](const std::string& doc) {
    return throws_report_error([&] { validate_job_report_json(doc); });
  };

  CHECK(rejects("not json"), "garbage rejected");
  CHECK(rejects("{ \"variants\": [] }"), "missing material rejected");
  CHECK(rejects("{ \"material\": \"PLA\" }"), "missing variants rejected");
  CHECK(rejects("{ \"material\": 3, \"variants\": [] }"),
        "non-string material rejected");
  CHECK(rejects("{ \"material\": \"PLA\", \"variants\": {} }"),
        "non-array variants rejected");

  // Variant with a missing settings block.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 } } ] })"),
        "variant missing settings rejected");

  // volume_saved_fraction inconsistent with volume_fraction (0.5 vs 1-0.5).
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.9,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "inconsistent volume_saved_fraction rejected");

  // Non-integer wall count.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5.5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "non-integer walls rejected");

  // margin.worst_case a string (not number-or-null).
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": "x" },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "string margin rejected");

  // volume_fraction out of [0,1].
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 1.5, "volume_saved_fraction": -0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "volume_fraction out of range rejected");

  // orientation missing z.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "orientation missing component rejected");

  // negative max stress.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": -1.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "negative max stress rejected");

  // margin null accepted (number-or-null) — a positive control on the teeth.
  CHECK(!rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 0.0,
        "margin": { "in_plane": 2.75, "interlayer": null, "worst_case": 2.75 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "null margin accepted");
}

// --- M5.2b min-feature print warning field --------------------------------

void test_min_feature_emitted() {
  JobReport r;
  r.material = "PLA";

  // A variant with violations + a warning (as the pipeline would fill from
  // settings min_feature_warning_text).
  VariantReport v0;
  v0.volume_fraction = 0.3;
  v0.max_stress_mpa = 20.0;
  v0.max_interlayer_tension_mpa = 5.0;
  v0.margin = compute_stress_margin(55.0, 0.55, 20.0, 5.0);
  v0.orientation = Vec3{0.0, 0.0, 1.0};
  v0.settings = fdm_settings();
  v0.min_feature_violations = 3;
  v0.min_feature_warning = "3 region(s) may be thinner than 2 voxels.";
  r.variants.push_back(v0);

  // A clean variant: no violations, no warning (the defaults).
  VariantReport v1;
  v1.volume_fraction = 0.5;
  v1.max_stress_mpa = 10.0;
  v1.max_interlayer_tension_mpa = 2.0;
  v1.margin = compute_stress_margin(55.0, 0.55, 10.0, 2.0);
  v1.orientation = Vec3{0.0, 0.0, 1.0};
  v1.settings = fdm_settings();
  r.variants.push_back(v1);

  std::string json = job_report_json(r);
  CHECK(contains(json, "\"min_feature_violations\": 3"),
        "violation count emitted");
  CHECK(contains(json, "3 region(s) may be thinner than 2 voxels."),
        "warning text emitted");
  CHECK(contains(json, "\"min_feature_violations\": 0"),
        "clean variant emits 0 violations");
  CHECK(contains(json, "\"min_feature_warning\": \"\""),
        "clean variant emits empty warning");
  CHECK(!throws_report_error([&] { validate_job_report_json(json); }),
        "report with min-feature fields validates");
}

void test_min_feature_validator() {
  auto rejects = [](const std::string& doc) {
    return throws_report_error([&] { validate_job_report_json(doc); });
  };

  // Non-integer violation count.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" },
        "min_feature_violations": 2.5, "min_feature_warning": "" } ] })"),
        "non-integer min_feature_violations rejected");

  // Negative violation count.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" },
        "min_feature_violations": -1, "min_feature_warning": "" } ] })"),
        "negative min_feature_violations rejected");

  // Non-string warning.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" },
        "min_feature_violations": 3, "min_feature_warning": 5 } ] })"),
        "non-string min_feature_warning rejected");

  // A non-empty warning with zero violations is inconsistent.
  CHECK(rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" },
        "min_feature_violations": 0, "min_feature_warning": "thin!" } ] })"),
        "warning without violations rejected");

  // Positive control: a non-empty warning with a positive count is accepted.
  CHECK(!rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" },
        "min_feature_violations": 2, "min_feature_warning": "2 thin regions" } ] })"),
        "warning with positive count accepted");

  // Positive control: the fields may be omitted entirely (backward compatible).
  CHECK(!rejects(R"({ "material": "PLA", "variants": [ {
        "volume_fraction": 0.5, "volume_saved_fraction": 0.5,
        "max_stress_mpa": 20.0, "max_interlayer_tension_mpa": 5.0,
        "margin": { "in_plane": 2.0, "interlayer": 3.0, "worst_case": 2.0 },
        "orientation": { "x": 0.0, "y": 0.0, "z": 1.0 },
        "settings": { "family": "fdm", "walls": 5, "top_layers": 6, "bottom_layers": 5, "infill_percent": 50, "infill_pattern": "gyroid", "print_mode": "", "warning": "" } } ] })"),
        "omitted min-feature fields accepted (backward compatible)");
}

}  // namespace

int main() {
  test_margin_basic();
  test_margin_unbounded();
  test_margin_resin();
  test_margin_validation();
  test_serialize_validate();
  test_volume_saved_derived();
  test_nonfinite_margin_null();
  test_empty_variants();
  test_string_escaping();
  test_validator_accepts_canonical();
  test_validator_rejects();
  test_min_feature_emitted();
  test_min_feature_validator();

  if (g_failures == 0) {
    std::printf("job report (M5.2): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "job report (M5.2): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
