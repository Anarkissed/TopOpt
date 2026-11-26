// part_scale.hpp -- is the part big enough for the nozzle to leave the optimiser
// any printable room? (TO rebuild; the maintainer, 2026-11-26: "Definitely a
// pop-up for when a part is too small for the nozzle with a recommendation for
// either a different nozzle size or to switch to resin printing.")
//
// The smallest thing a printer can make is a wall two lines wide (his print
// test, 2026-11-12: one line does not print on a 0.4 mm nozzle). To remove
// anything from a section and still leave something printable, the optimiser
// needs room for two such walls and a gap at least as wide between them: three
// times two line widths = six line widths. A part whose THICKEST section is
// under that has nowhere a cut could go.
//
// Pure arithmetic; the caller supplies the thickest section (the largest value
// of local_member_thickness_mm over the part as drawn).
#pragma once

#include <initializer_list>

namespace topopt {

struct PartScale {
  double thickest_mm = 0.0;        // the part's thickest section
  double line_width_mm = 0.0;      // the job's wall line width
  double needed_mm = 0.0;          // six line widths
  bool too_small = false;          // thickest < needed
  // The largest common nozzle (0.6, 0.4, 0.25, 0.2 mm; line width taken as 1.125
  // x nozzle, as 0.45 is to 0.4) on which the part WOULD have room; 0 when even a
  // 0.2 mm nozzle leaves none, and then the advice is resin.
  double nozzle_that_fits_mm = 0.0;
};

inline PartScale part_scale(double thickest_mm, double line_width_mm) {
  PartScale s;
  s.thickest_mm = thickest_mm;
  s.line_width_mm = line_width_mm > 0.0 ? line_width_mm : 0.45;
  s.needed_mm = 6.0 * s.line_width_mm;
  s.too_small = thickest_mm < s.needed_mm;
  for (double nozzle : {0.6, 0.4, 0.25, 0.2})
    if (thickest_mm >= 6.0 * 1.125 * nozzle) {
      s.nozzle_that_fits_mm = nozzle;
      break;
    }
  return s;
}

}  // namespace topopt
