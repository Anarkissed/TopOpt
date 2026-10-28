#pragma once

#include <string>
#include <vector>

namespace topopt {
namespace flexible {

// ════════════════════════════════════════════════════════════════════════════════
// F4 — THE PEN CURVE (02 §12, R12, M11)
//
// The user draws a squish curve with a pen tool: control points (x, y), x the
// position along the face edge (or the centre->edge fraction) and y the squish as a
// fraction of the deepest squish. Core evaluates it; the app calls this to DRAW it,
// so the curve on screen is the curve core builds (DECISIONS 2026-09-27 item 4).
//
// Method: monotone piecewise-cubic Hermite, Fritsch & Carlson 1980 (SIAM J. Numer.
// Anal. 17(2) 238–246). Tangents start as the average of the neighbouring secants,
// are zero at every local extremum and on every flat run, and are scaled back where
// α² + β² > 9. On each interval the cubic is then monotone, so it NEVER leaves the
// [min, max] of that interval's two points: an S-curve bends through its points and
// never overshoots them. The result is clamped to [0, 1].
//
// Input rules (refused, never repaired): at least 2 points, x[0] == 0, x[n-1] == 1,
// x strictly increasing, every y in [0, 1], everything finite. A query outside
// [0, 1] is evaluated at the nearer end.
// ════════════════════════════════════════════════════════════════════════════════

// "" when the control points are valid, else one sentence naming the problem. The
// app calls this before drawing, to show the user why a point is refused.
std::string pen_curve_error(const std::vector<double>& x, const std::vector<double>& y);

// The curve at every query in `t`. Throws FlexibleError with pen_curve_error's text
// when the control points are invalid.
std::vector<double> pen_curve_values(const std::vector<double>& x,
                                     const std::vector<double>& y,
                                     const std::vector<double>& t);

// One value (a convenience over pen_curve_values).
double pen_curve_value(const std::vector<double>& x, const std::vector<double>& y,
                       double t);

// A curve prepared once and evaluated many times (the squish maps evaluate one per
// column). Construction validates exactly as pen_curve_values does.
class PenCurve {
 public:
  PenCurve(const std::vector<double>& x, const std::vector<double>& y);
  double operator()(double t) const;

 private:
  std::vector<double> x_, y_, m_;
};

}  // namespace flexible
}  // namespace topopt
