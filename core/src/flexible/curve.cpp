#include "topopt/flexible/curve.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/flexible/error.hpp"

namespace topopt {
namespace flexible {

std::string pen_curve_error(const std::vector<double>& x, const std::vector<double>& y) {
  if (x.size() != y.size())
    return "a pen curve needs the same number of x and y values (" +
           std::to_string(x.size()) + " x, " + std::to_string(y.size()) + " y)";
  if (x.size() < 2) return "a pen curve needs at least 2 points";
  for (std::size_t i = 0; i < x.size(); ++i)
    if (!std::isfinite(x[i]) || !std::isfinite(y[i]))
      return "point " + std::to_string(i) + " is not finite";
  if (x.front() != 0.0) return "a pen curve must start at x = 0";
  if (x.back() != 1.0) return "a pen curve must end at x = 1";
  for (std::size_t i = 1; i < x.size(); ++i)
    if (!(x[i] > x[i - 1]))
      return "x must be strictly increasing (point " + std::to_string(i) + ")";
  for (std::size_t i = 0; i < y.size(); ++i)
    if (y[i] < 0.0 || y[i] > 1.0) {
      char b[96];
      std::snprintf(b, sizeof(b), "y must lie in [0, 1] (point %zu is %g)", i, y[i]);
      return b;
    }
  return "";
}

PenCurve::PenCurve(const std::vector<double>& x, const std::vector<double>& y) {
  const std::string err = pen_curve_error(x, y);
  if (!err.empty()) throw FlexibleError(err);
  x_ = x;
  y_ = y;
  const std::size_t n = x.size();
  std::vector<double> d(n - 1);  // secants
  for (std::size_t k = 0; k + 1 < n; ++k) d[k] = (y[k + 1] - y[k]) / (x[k + 1] - x[k]);
  m_.assign(n, 0.0);
  m_[0] = d[0];
  m_[n - 1] = d[n - 2];
  for (std::size_t k = 1; k + 1 < n; ++k)
    // Fritsch–Carlson step 1: zero at an extremum or beside a flat run, else the
    // mean of the two secants.
    m_[k] = (d[k - 1] * d[k] <= 0.0) ? 0.0 : 0.5 * (d[k - 1] + d[k]);
  for (std::size_t k = 0; k + 1 < n; ++k) {
    if (d[k] == 0.0) {
      m_[k] = 0.0;
      m_[k + 1] = 0.0;
      continue;
    }
    // a, b >= 0 always: the end tangents ARE the end secants, and an interior tangent is
    // either 0 or the mean of two secants of the same sign as d[k].
    const double a = m_[k] / d[k];
    const double b = m_[k + 1] / d[k];
    const double s = a * a + b * b;
    if (s > 9.0) {  // step 3: pull the pair back inside the monotone region
      const double tau = 3.0 / std::sqrt(s);
      m_[k] = tau * a * d[k];
      m_[k + 1] = tau * b * d[k];
    }
  }
}

double PenCurve::operator()(double t) const {
  if (!(t > 0.0)) return y_.front();  // also catches NaN
  if (t >= 1.0) return y_.back();
  std::size_t k = static_cast<std::size_t>(
      std::upper_bound(x_.begin(), x_.end(), t) - x_.begin());
  if (k == 0) k = 1;
  if (k >= x_.size()) k = x_.size() - 1;
  --k;  // x_[k] <= t < x_[k+1]
  const double h = x_[k + 1] - x_[k];
  const double s = (t - x_[k]) / h;
  const double s2 = s * s, s3 = s2 * s;
  const double h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s;
  const double h01 = -2 * s3 + 3 * s2, h11 = s3 - s2;
  // No per-interval clamp: the Fritsch–Carlson tangents alone keep the cubic inside
  // its two points, and test_flexible_curve checks exactly that. Only the [0, 1]
  // clamp R12 asks for is applied.
  const double v = h00 * y_[k] + h10 * h * m_[k] + h01 * y_[k + 1] + h11 * h * m_[k + 1];
  return std::min(std::max(v, 0.0), 1.0);
}

std::vector<double> pen_curve_values(const std::vector<double>& x,
                                     const std::vector<double>& y,
                                     const std::vector<double>& t) {
  const PenCurve c(x, y);
  std::vector<double> out;
  out.reserve(t.size());
  for (double v : t) out.push_back(c(v));
  return out;
}

double pen_curve_value(const std::vector<double>& x, const std::vector<double>& y,
                       double t) {
  return PenCurve(x, y)(t);
}

}  // namespace flexible
}  // namespace topopt
