#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"      // Vec3
#include "topopt/settings.hpp"  // SlicerSettings

namespace topopt {

// M5.2 — the single JSON job report emitted per optimization run
// (ARCHITECTURE.md §5 pipeline: "... -> 3MF/STL export + JSON report"; §9 M5
// "JSON report format"). One run produces one report describing every requested
// variant: its achieved volume fraction / material saved, worst-case stress and
// margin, chosen build orientation, and recommended slicer settings.
//
// This module is the report DATA MODEL + JSON serialization + schema validation
// only. It is pure C++/std (no Eigen, no OCCT), so it lives in the always-built
// library and its test runs in every configuration. It does NOT run FEA, SIMP,
// orientation scoring or the settings engine — the caller (the M5.3 pipeline
// driver) assembles a JobReport from those results and hands it here to
// serialize. The one piece of derived numeric logic it owns is the stress
// margin, whose definition is locked in settings/rules.json (see below).

// Worst-case stress margin for one variant's chosen build orientation, per
// settings/rules.json semantics_locked.margin_definition (DECISIONS.md
// 2026-07-08). All three are dimensionless safety factors (yield / stress);
// larger is safer, and worst_case is the number the M5.1 settings engine
// consumes as its `worst_case_stress_margin` input.
struct StressMargin {
  double in_plane = 0.0;    // yield_strength_mpa / max_von_mises_stress
  double interlayer = 0.0;  // (z_knockdown * yield_strength_mpa) / max_interlayer_tension
  double worst_case = 0.0;  // min(in_plane, interlayer)
};

// Thrown for any failure to build, serialize or validate a job report:
// a non-physical margin input or a JSON document that does not match the
// report schema.
class ReportError : public std::runtime_error {
 public:
  explicit ReportError(const std::string& msg) : std::runtime_error(msg) {}
};

// Compute the worst-case stress margin from a chosen orientation's stress state,
// exactly per the locked definition:
//   in_plane_margin   = yield_strength_mpa / max_von_mises_stress
//   interlayer_margin = (z_knockdown * yield_strength_mpa) / max_interlayer_tension
//   worst_case        = min(in_plane_margin, interlayer_margin)
// A stress that is exactly 0 means that failure mode carries no load, i.e. an
// unbounded margin: the corresponding term is +infinity, and the min falls back
// to the other (loaded) term. For resin (z_knockdown == 1) the two terms scale
// identically. Throws ReportError if yield_strength_mpa is not finite and > 0,
// z_knockdown is not in (0, 1], or either stress is not finite and >= 0.
StressMargin compute_stress_margin(double yield_strength_mpa, double z_knockdown,
                                   double max_von_mises_stress,
                                   double max_interlayer_tension);

// One variant's line in the job report (§5 "per variant").
struct VariantReport {
  // Achieved physical volume fraction of the optimized variant relative to the
  // original solid part (SimpOptimizeResult.volume_fraction). "Volume saved" is
  // the complement 1 - volume_fraction and is emitted in the JSON.
  double volume_fraction = 0.0;
  // Peak stresses for the chosen orientation (MPa): the max von Mises stress
  // ("max stress") and the max tension across layer planes (M4.4 field).
  double max_stress_mpa = 0.0;
  double max_interlayer_tension_mpa = 0.0;
  // Worst-case stress margin (compute_stress_margin).
  StressMargin margin;
  // The chosen build orientation (unit build direction, the M4.4 winner).
  Vec3 orientation{0.0, 0.0, 0.0};
  // Recommended slicer settings for this variant (M5.1 engine output).
  SlicerSettings settings;
};

// The whole run's report: the material used and one entry per requested variant.
struct JobReport {
  std::string material;  // material name (key into materials.json)
  std::vector<VariantReport> variants;
};

// Serialize a job report to a single JSON document (2-space indented). Numeric
// fields that are not finite (e.g. an unbounded margin term when a stress is 0)
// are emitted as JSON null. Each variant additionally carries the derived
// "volume_saved_fraction" = 1 - volume_fraction. The output always satisfies
// validate_job_report_json below.
std::string job_report_json(const JobReport& report);

// Schema-validate a job report JSON document (the report schema this module
// emits). Parses `json_text` and checks that every required field is present
// with the right type, that counts are integers, that volume_saved_fraction is
// consistent with volume_fraction, and that stresses / volume fractions are in
// range. Throws ReportError on malformed JSON or any schema violation; returns
// normally when the document conforms.
void validate_job_report_json(const std::string& json_text);

}  // namespace topopt
