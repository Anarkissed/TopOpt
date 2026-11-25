// material_length.hpp -- the length over which stress is read for the strength
// number (TO rebuild stage 2; docs/design/to-rebuild/stages/stage-2-strength-number.md).
//
// A printed plastic part does not fail where one point is highly stressed; it
// fails when the stress over a small length of material is too high (the theory
// of critical distances; Taylor 2008). That length belongs to the material:
//     L = (1 / pi) * (K_Ic / tensile strength)^2
//
// PUBLISHED values only (the maintainer's word, 2026-11-25: "Definitely use
// published values"); his own rig will replace them. Sources:
//   PLA, printed, 100 % infill: K_Ic 3.7 MPa m^0.5, tensile strength 42.9 MPa,
//       so L = 2.4 mm by the formula; the authors calibrated 4.6 mm from sharp
//       notches. The LOWER one is taken. Ahmed and Susmel, Fatigue Fract Eng
//       Mater Struct 41 (2018) 2071, doi 10.1111/ffe.12746.
//   ABS, printed: K_Ic 2.6 MPa m^0.5, tensile strength 23 MPa, L = 4.1 mm.
//       Susmel, review of notched additively manufactured polymers (2022).
//   PETG: K_Ic 2.11 to 2.54 MPa m^0.5 for the filament as received (Guessasma
//       et al., Polymers 11 (2019) 1220); no printed value found. With the
//       lower toughness and 45 MPa: 0.7 mm. Marked NOT printed-part data.
// Every other material in materials.json has no published printed value yet
// and returns `published = false`; what the reading does then is a decision
// that is not taken here.
//
// HIS RULE (2026-11-25): the reading starts at HALF the published length until
// his rig can check it. `reading_size_mm` applies that half.
#pragma once

#include <string>

namespace topopt {

struct MaterialLength {
  bool published = false;      // a published value exists for this material
  bool printed_part = false;   // measured on PRINTED specimens (not filament or moulded)
  double length_mm = 0.0;      // L, as published (the lower value where two exist)
};

inline MaterialLength material_length(const std::string& material_name) {
  if (material_name == "PLA") return {true, true, 2.4};
  if (material_name == "ABS") return {true, true, 4.1};
  if (material_name == "PETG") return {true, false, 0.7};
  return {};
}

// The size the stress is read over: half the published length (his rule). 0 when
// nothing is published; the caller decides what to do then.
inline double reading_size_mm(const MaterialLength& m) {
  return m.published ? 0.5 * m.length_mm : 0.0;
}

}  // namespace topopt
