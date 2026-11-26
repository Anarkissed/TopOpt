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
//   ABS, printed: two sources that disagree widely, and the LOWEST is taken.
//       Susmel's review (2022): K_Ic 2.6 MPa m^0.5 with a weak print (tensile
//       strength 23 MPa) gives 4.1 mm. Cicero et al., Materials 13 (2020) 4716,
//       doi 10.3390/ma13214716, on a strong print (52 to 61 MPa, toughness 3.5
//       to 4.1): the formula gives 1.4 to 1.5 mm, but the length that best
//       fitted their 33 notched tests was 0.46 to 0.92 mm averaged over a line
//       and 0.28 to 0.44 mm read at a point, by raster angle. Our reading
//       averages over a size, so the line value's lowest, 0.46 mm, is taken.
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

#include <cstdio>
#include <cstdlib>
#include <string>

namespace topopt {

struct MaterialLength {
  bool published = false;      // a published value exists for this material
  bool printed_part = false;   // measured on PRINTED specimens (not filament or moulded)
  double length_mm = 0.0;      // L, as published (the lower value where two exist)
};

inline MaterialLength material_length(const std::string& material_name) {
  if (material_name == "PLA") return {true, true, 2.4};
  if (material_name == "ABS") return {true, true, 0.46};
  if (material_name == "PETG") return {true, false, 0.7};
  return {};
}

// The size the stress is read over: half the published length (his rule). 0 when
// nothing is published; the caller decides what to do then.
inline double reading_size_mm(const MaterialLength& m) {
  return m.published ? 0.5 * m.length_mm : 0.0;
}

// ACROSS THE LAYERS the length is a fifth of the in-plane one (the maintainer's
// decision, 2026-11-25: "Yes, a fifth"). Basis: CNC Kitchen's notched impact
// tests, lying against standing (PC Blend 27 against about 2 kJ/m2, PCTG 24
// against 1.5): toughness across layers is 13 to 16 times lower while strength
// is 1.3 to 2 times lower, and the length goes as (toughness / strength)^2.
// Not a calibrated measurement; his rig replaces it.
inline constexpr double kAcrossLayerLengthFactor = 0.2;

// The reading size for stress acting ACROSS the layers.
inline double reading_size_across_layers_mm(const MaterialLength& m) {
  return kAcrossLayerLengthFactor * reading_size_mm(m);
}

// The engineers' control, "Stress reading size (mm)" (the maintainer's decision,
// 2026-11-25): a typed size replaces the material's own. Until the app carries
// it, the measuring runs set it through TOPOPT_STRESS_READING_MM.
inline double reading_size_for_job_mm(const std::string& material_name) {
  if (const char* v = std::getenv("TOPOPT_STRESS_READING_MM")) {
    const double typed = std::atof(v);
    if (typed > 0.0) return typed;
  }
  const double size = reading_size_mm(material_length(material_name));
  // Reviewer's ruling 2026-11-26 (d): a material with no published length says
  // so in plain words and keeps today's reading.
  if (!(size > 0.0))
    std::fprintf(stderr,
                 "[strength] no published stress-reading length for %s: this material "
                 "keeps today's strength reading (one voxel).\n",
                 material_name.c_str());
  return size;
}

}  // namespace topopt
