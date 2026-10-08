#pragma once
// ── THE WETTED JOIN, TRANSCRIBED FROM THE PREVIEW'S SHADER ────────────────────
//
// (maintainer, 2026-09-18: "implement the wetting fillet -- but can you do it the *exact*
// way that App does it? Because the way it was being implemented prior was just... bad.")
//
// ★ WHAT WAS THERE BEFORE WAS A COMMENT, NOT A FEATURE. organic_lattice.hpp carried a
// full derivation of a meniscus fillet -- rho(z) = r + R - sqrt(R^2 - (R - z)^2), tangent
// to the solid at one end and the strut at the other -- and that formula appears NOWHERE
// in the emitted geometry. A strut simply stopped where it met solid. The header's
// confidence is exactly what stopped anyone checking.
//
// ★ AND THE MENISCUS IS NOT WHAT THE PREVIEW DRAWS. The app tried a symmetric profile
// centred on the surface and rejected it: it "put a trumpet a full bead's width up the
// strut -- the visible neck". It then tried clamping to one side and rejected that too:
// "the weight jumps from 0 to 1 across the surface, and a step in the radius is a HARD
// EDGE, which is the flat-rimmed foot". What ships is neither, and each of its three
// properties was arrived at by fixing a defect the maintainer could see:
//
//   1. IT EASES IN AND OUT ON BOTH SIDES. smoothstep has zero slope at both ends, so the
//      two halves meet at the peak with matching derivatives: no edge, no step.
//   2. ITS WIDEST POINT IS BURIED HALF A FILLET INSIDE THE SOLID, not on the surface.
//      With the peak at s = 0 the fattest ring sat in the plane of the wall and read as
//      "an oval foot under every strut".
//   3. THE REACH IS ASYMMETRIC -- short above the joint, long below -- so the bead stays
//      where the strut meets material instead of climbing it.
//
// This is a transcription, deliberately: same constants, same branch, same smoothstep, so
// the run's surface is the preview's surface and not an interpretation of it.

#include <algorithm>
#include <cmath>

namespace topopt {

// The fillet and the embed are both this multiple of the strut's OWN radius, so a thin
// strut gets a small bead and a fat one a big one -- there is no absolute length here to
// be wrong at another scale. Hard-coded at the maintainer's instruction (2026-09-18).
inline constexpr double kOrganicWetScale = 1.0;
// The flare reaches twice the fillet, the peak sits half a reach inside the solid, and it
// fades out 0.35 of a reach above that. The shader's numbers, not re-derived.
inline constexpr double kOrganicWetReachPerFillet = 2.0;
inline constexpr double kOrganicWetPeakFraction = 0.5;
inline constexpr double kOrganicWetAboveFraction = 0.35;

// GLSL/Metal smoothstep: 0 below `a`, 1 above `b`, 3t^2 - 2t^3 between, zero slope at
// both ends. Written out rather than approximated, because the zero slope at the ends is
// the whole reason the two halves of the flare meet without an edge.
inline double wet_smoothstep(double a, double b, double x) {
  if (!(b > a)) return x < a ? 0.0 : 1.0;
  double t = (x - a) / (b - a);
  t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
  return t * t * (3.0 - 2.0 * t);
}

// How much to fatten the strut at a point, in units of the fillet: 0 to 1.
//   `d_part`  signed distance to the PART, NEGATIVE inside material. A strut breaking out
//             into AIR gets a clean cut and no bead, which is what this gates.
//   `s`       signed distance to the boundary between "lattice may be here" and "solid":
//             NEGATIVE where the lattice lives, POSITIVE inside the solid.
//   `reach`   2 x fillet.
inline double organic_wet_flare(double d_part, double s, double reach) {
  if (!(reach > 0.0)) return 0.0;
  // A meniscus needs something to climb: 1 well inside the part, 0 at its own surface.
  const double solid = 1.0 - wet_smoothstep(-reach, 0.0, d_part);
  if (!(solid > 0.0)) return 0.0;
  const double peak = kOrganicWetPeakFraction * reach;
  const double above_reach = peak + kOrganicWetAboveFraction * reach;
  const double d = s - peak;
  if (d < 0.0) return solid * (1.0 - wet_smoothstep(0.0, above_reach, -d));
  return solid * (1.0 - wet_smoothstep(0.0, reach, d));
}

}  // namespace topopt
