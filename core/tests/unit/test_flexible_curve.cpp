// F4 of task 2026-09-28-flexible-squish-maths: the monotone pen curve
// (Fritsch–Carlson), the function the app will call to draw squish curves.

#include "topopt/flexible/curve.hpp"
#include "topopt/flexible/error.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

using namespace topopt::flexible;

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

// Dense sampling: the curve passes through every point and, between two points,
// never leaves their [min, max].
static void check_shape(const std::vector<double>& x, const std::vector<double>& y,
                        const char* name) {
  bool through = true, bounded = true, clamped = true, continuous = true;
  for (std::size_t i = 0; i < x.size(); ++i)
    if (std::fabs(pen_curve_value(x, y, x[i]) - y[i]) > 1e-12) through = false;
  double prev = pen_curve_value(x, y, 0.0);
  for (std::size_t i = 0; i + 1 < x.size(); ++i) {
    const double lo = std::min(y[i], y[i + 1]), hi = std::max(y[i], y[i + 1]);
    for (int k = 0; k <= 400; ++k) {
      const double t = x[i] + (x[i + 1] - x[i]) * k / 400.0;
      const double v = pen_curve_value(x, y, t);
      if (v < lo - 1e-12 || v > hi + 1e-12) bounded = false;
      if (v < 0.0 || v > 1.0) clamped = false;
      if (std::fabs(v - prev) > 0.05) continuous = false;
      prev = v;
    }
  }
  std::string n(name);
  CHECK(through, (n + ": passes through every control point").c_str());
  CHECK(bounded, (n + ": never leaves the [min, max] of its two neighbours").c_str());
  CHECK(clamped, (n + ": stays in [0, 1]").c_str());
  CHECK(continuous, (n + ": continuous at the sampling pitch").c_str());
}

static void test_shapes() {
  check_shape({0, 1}, {0.2, 0.9}, "2-point");
  check_shape({0, 1}, {0.5, 0.5}, "flat 2-point");
  check_shape({0, 0.3, 0.7, 1}, {0.4, 0.4, 0.4, 0.4}, "flat 4-point");
  check_shape({0, 0.25, 0.5, 0.75, 1}, {0, 0.05, 0.5, 0.95, 1}, "S-curve");
  check_shape({0, 0.5, 1}, {0, 1, 0}, "centre peak");
  check_shape({0, 0.1, 0.12, 0.9, 1}, {1, 0, 1, 0, 1}, "sharp zigzag");
  check_shape({0, 0.4, 0.45, 1}, {0, 1, 1, 0}, "plateau");
  check_shape({0, 0.2, 0.8, 1}, {1, 1, 0, 0}, "step down");
  // Extremes INSIDE (0, 1), where the [0, 1] clamp cannot hide an overshoot.
  check_shape({0, 0.3, 0.6, 1}, {0.2, 0.7, 0.3, 0.5}, "interior zigzag");
  check_shape({0, 0.1, 0.5, 0.55, 1}, {0.3, 0.35, 0.8, 0.8, 0.25}, "interior plateau");
  check_shape({0, 0.05, 0.1, 1}, {0.5, 0.9, 0.45, 0.4}, "interior spike");

  // 2-point is the straight line.
  CHECK(std::fabs(pen_curve_value({0, 1}, {0.2, 0.9}, 0.5) - 0.55) < 1e-15,
        "two points: linear");
  // Flat runs stay flat (no bulge between equal points).
  CHECK(pen_curve_value({0, 0.3, 0.7, 1}, {0.4, 0.4, 0.4, 0.4}, 0.51) == 0.4,
        "flat: exactly flat");
  CHECK(pen_curve_value({0, 0.4, 0.45, 1}, {0, 1, 1, 0}, 0.43) == 1.0,
        "a plateau between two equal points does not overshoot 1");
  // S-curve is monotone overall.
  bool mono = true;
  double prev = -1.0;
  for (int k = 0; k <= 1000; ++k) {
    const double v = pen_curve_value({0, 0.25, 0.5, 0.75, 1}, {0, 0.05, 0.5, 0.95, 1}, k / 1000.0);
    if (v < prev) mono = false;
    prev = v;
  }
  CHECK(mono, "monotone data gives a monotone curve");
  // An extremum sits exactly at its control point.
  double best = -1.0, at = -1.0;
  for (int k = 0; k <= 1000; ++k) {
    const double v = pen_curve_value({0, 0.3, 1}, {0.1, 0.8, 0.2}, k / 1000.0);
    if (v > best) { best = v; at = k / 1000.0; }
  }
  CHECK(std::fabs(best - 0.8) < 1e-12 && std::fabs(at - 0.3) < 1e-12,
        "the peak is the drawn point, not past it");
  // Out-of-range queries evaluate at the nearer end.
  CHECK(pen_curve_value({0, 1}, {0.2, 0.9}, -3.0) == 0.2 &&
            pen_curve_value({0, 1}, {0.2, 0.9}, 7.0) == 0.9,
        "queries outside [0,1] clamp to the ends");
  // The batch form equals the scalar form, and PenCurve too.
  const std::vector<double> x{0, 0.25, 0.5, 0.75, 1}, y{0, 0.05, 0.5, 0.95, 1};
  const std::vector<double> ts{0.0, 0.1, 0.33, 0.9, 1.0};
  const std::vector<double> vs = pen_curve_values(x, y, ts);
  const PenCurve pc(x, y);
  bool same = vs.size() == ts.size();
  for (std::size_t i = 0; same && i < ts.size(); ++i)
    same = vs[i] == pen_curve_value(x, y, ts[i]) && vs[i] == pc(ts[i]);
  CHECK(same, "batch, scalar and prepared forms agree exactly");
}

static bool refused(const std::vector<double>& x, const std::vector<double>& y,
                    const char* needle) {
  const std::string e = pen_curve_error(x, y);
  if (e.empty() || e.find(needle) == std::string::npos) {
    std::fprintf(stderr, "  (error was: \"%s\")\n", e.c_str());
    return false;
  }
  try {
    pen_curve_values(x, y, {0.5});
  } catch (const FlexibleError& ex) {
    return std::string(ex.what()).find(needle) != std::string::npos;
  }
  return false;
}

static void test_refusals() {
  CHECK(pen_curve_error({0, 1}, {0, 1}).empty(), "a valid curve has no error");
  CHECK(refused({0}, {0}, "at least 2"), "one point refused");
  CHECK(refused({0, 1}, {0}, "same number"), "mismatched arrays refused");
  CHECK(refused({0.1, 1}, {0, 1}, "start at x = 0"), "x[0] != 0 refused");
  CHECK(refused({0, 0.9}, {0, 1}, "end at x = 1"), "x[n-1] != 1 refused");
  CHECK(refused({0, 0.5, 0.5, 1}, {0, 1, 0, 1}, "strictly increasing"), "repeated x refused");
  CHECK(refused({0, 0.6, 0.4, 1}, {0, 1, 0, 1}, "strictly increasing"), "decreasing x refused");
  CHECK(refused({0, 1}, {0, 1.2}, "[0, 1]"), "y above 1 refused");
  CHECK(refused({0, 1}, {-0.1, 1}, "[0, 1]"), "y below 0 refused");
  CHECK(refused({0, std::numeric_limits<double>::quiet_NaN(), 1}, {0, 0.5, 1}, "finite"),
        "NaN refused");
}

int main() {
  test_shapes();
  test_refusals();
  std::printf("test_flexible_curve: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
