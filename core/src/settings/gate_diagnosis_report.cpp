// gate_diagnosis (report half) — the STABLE NAMES and the JSON emitter for a
// GateDiagnosis (topopt/gate_diagnosis.hpp).
//
// WHY IT IS SPLIT FROM THE EVALUATOR. `report.cpp` is in the ALWAYS-BUILT library
// (no Eigen, no OCCT) and it emits a variant's diagnosis, so the emitter has to
// build there too. `diagnose_gate` (src/simp/gate_diagnosis.cpp) calls
// gate_margin_effective, which lives in the Eigen-gated analyze.cpp — so the
// evaluator is gated and this half is not. Same value types, one contract.
//
// Nothing here computes or decides anything: it renders a struct.

#include "topopt/gate_diagnosis.hpp"

#include <cmath>
#include <cstdio>
#include <string>

namespace topopt {

namespace {

std::string num_json(double v) {
  if (!std::isfinite(v)) return "null";
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.10g", v);
  return std::string(buf);
}

std::string str_json(const std::string& s) {
  std::string out = "\"";
  for (char ch : s) {
    const unsigned char c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(ch);
        }
    }
  }
  out.push_back('"');
  return out;
}

}  // namespace

const char* gate_term_name(GateTerm t) {
  switch (t) {
    case GateTerm::None: return "none";
    case GateTerm::LoadPath: return "load_path";
    case GateTerm::InPlane: return "in_plane";
    case GateTerm::Interlayer: return "interlayer";
    case GateTerm::Knockdown: return "knockdown";
    case GateTerm::MinFeature: return "min_feature";
  }
  return "none";
}

const char* gate_lever_name(GateLever l) {
  switch (l) {
    case GateLever::Infill: return "infill";
    case GateLever::WallLoops: return "wall_loops";
    case GateLever::BuildOrientation: return "build_orientation";
    case GateLever::VolumeFraction: return "volume_fraction";
    case GateLever::Material: return "material";
    case GateLever::Resolution: return "resolution";
    case GateLever::Load: return "load";
  }
  return "infill";
}

void emit_gate_diagnosis(std::string& out, const GateDiagnosis& d,
                         const std::string& indent) {
  const std::string in2 = indent + "  ";
  const std::string in3 = in2 + "  ";
  const std::string in4 = in3 + "  ";
  out += "{\n";
  out += in2 + "\"binding_term\": " + str_json(gate_term_name(d.binding)) + ",\n";
  out += in2 + "\"binding_value\": " + num_json(d.binding_value) + ",\n";
  out += in2 + "\"required_value\": " + num_json(d.required_value) + ",\n";
  out += in2 + "\"ratio\": " + num_json(d.ratio) + ",\n";
  // BOTH margin numbers, always. They differ by the knockdown, and only one of
  // them explains a refusal — the motivating dialog showed neither.
  out += in2 + "\"margin_worst_case_raw\": " + num_json(d.margin_worst_case) + ",\n";
  out += in2 + "\"margin_in_plane_raw\": " + num_json(d.margin_in_plane) + ",\n";
  out += in2 + "\"margin_interlayer_raw\": " + num_json(d.margin_interlayer) + ",\n";
  out += in2 + "\"margin_effective\": " + num_json(d.margin_effective) + ",\n";
  out += in2 + "\"knockdown_factor\": " + num_json(d.knockdown_factor) + ",\n";
  out += in2 + "\"infill_percent\": " + num_json(d.infill_percent) + ",\n";
  out += in2 + "\"min_feature_violations\": " +
         std::to_string(d.min_feature_violations) + ",\n";
  out += in2 + "\"inherits_unsourced_z_knockdown\": " +
         std::string(d.inherits_unsourced_z_knockdown ? "true" : "false") + ",\n";
  out += in2 + "\"provenance\": " + str_json(d.provenance) + ",\n";
  out += in2 + "\"no_setting_fixes_this\": " +
         std::string(d.no_setting_fixes_this ? "true" : "false") + ",\n";
  out += in2 + "\"no_fix_reason\": " + str_json(d.no_fix_reason) + ",\n";
  if (d.headroom_evaluated) {
    out += in2 + "\"headroom_min_infill_percent\": " +
           num_json(d.headroom_min_infill_percent) + ",\n";
  }
  out += in2 + "\"recommendations\": ";
  if (d.recommendations.empty()) {
    out += "[]";
  } else {
    out += "[\n";
    for (std::size_t i = 0; i < d.recommendations.size(); ++i) {
      const GateRecommendation& r = d.recommendations[i];
      out += in3 + "{\n";
      out += in4 + "\"lever\": " + str_json(gate_lever_name(r.lever)) + ",\n";
      out += in4 + "\"parameter\": " + str_json(r.parameter) + ",\n";
      out += in4 + "\"current_value\": " + num_json(r.current_value) + ",\n";
      out += in4 + "\"proposed_value\": " + num_json(r.proposed_value) + ",\n";
      out += in4 + "\"proposed_label\": " + str_json(r.proposed_label) + ",\n";
      out += in4 + "\"margin_effective_at_proposal\": " +
             num_json(r.margin_effective_at_proposal) + ",\n";
      out += in4 + "\"margin_required\": " + num_json(r.margin_required) + ",\n";
      out += in4 + "\"verified_through_gate\": " +
             std::string(r.verified_through_gate ? "true" : "false") + ",\n";
      out += in4 + "\"inherits_unsourced_z_knockdown\": " +
             std::string(r.inherits_unsourced_z_knockdown ? "true" : "false") + ",\n";
      out += in4 + "\"provenance\": " + str_json(r.provenance) + ",\n";
      out += in4 + "\"note\": " + str_json(r.note) + "\n";
      out += in3 + "}" + (i + 1 < d.recommendations.size() ? ",\n" : "\n");
    }
    out += in2 + "]";
  }
  out += ",\n";
  out += in2 + "\"levers\": ";
  if (d.levers.empty()) {
    out += "[]\n";
  } else {
    out += "[\n";
    for (std::size_t i = 0; i < d.levers.size(); ++i) {
      const GateLeverOutcome& l = d.levers[i];
      out += in3 + "{ \"lever\": " + str_json(gate_lever_name(l.lever));
      out += ", \"evaluable\": " + std::string(l.evaluable ? "true" : "false");
      out += ", \"candidates_tried\": " + std::to_string(l.candidates_tried);
      out += ", \"passed\": " + std::string(l.passed ? "true" : "false");
      out += ", \"reason\": " + str_json(l.reason) + " }";
      out += (i + 1 < d.levers.size() ? ",\n" : "\n");
    }
    out += in2 + "]\n";
  }
  out += indent + "}";
}

}  // namespace topopt
