// What a stress reading over a size SHOULD give on tests E's two textbook cases
// (TO rebuild stage 2). The reading (stress_measure.hpp) is the average of the
// von Mises stress over the material inside a ball of a stated diameter, and
// the number reported is the largest such average. Here the same average is
// taken on the EXACT solutions (Kirsch for the plate with a hole, with the
// finite-width factor 3.03 / 3; Lame for the thick ring, plane stress), so a
// measured reading is judged against the reading's own true value and not
// against the peak, which an average is below by design.
// The same sums as docs/design/to-rebuild/stages/reference_reading.py.
#pragma once

#include <algorithm>
#include <cmath>

namespace to_reference {

// The largest ball average, the ball's centre moved along the line from the
// hottest point into the material; `thickness` is the plate's (the ball's chord
// through it weights each point).
template <class Vm, class Inside>
double ball_reference(Vm vm, Inside inside, double hot_x, double hot_y, double dir_x, double dir_y,
                      double diameter, double thickness) {
  const double radius = 0.5 * diameter;
  const int n = 61;
  double best = 0.0;
  for (int c = 0; c < 25; ++c) {
    const double e = diameter * c / 24.0;
    const double cx = hot_x + dir_x * e, cy = hot_y + dir_y * e;
    double num = 0.0, den = 0.0;
    for (int b = 0; b < n; ++b)
      for (int a = 0; a < n; ++a) {
        const double x = -radius + diameter * a / (n - 1), y = -radius + diameter * b / (n - 1);
        const double rho2 = x * x + y * y;
        if (rho2 > radius * radius) continue;
        const double px = cx + x, py = cy + y;
        if (!inside(px, py)) continue;
        const double w = std::min(thickness, 2.0 * std::sqrt(std::max(radius * radius - rho2, 0.0)));
        num += w * vm(px, py);
        den += w;
      }
    if (den > 0.0) best = std::max(best, num / den);
  }
  return best;
}

// Plate with a round hole of radius a, pulled along x with far stress 1; the
// reading in units of the far stress. The hottest point is at (0, a).
inline double plate_reading(double a, double diameter, double thickness) {
  auto vm = [a](double x, double y) {
    const double r = std::max(std::hypot(x, y), a), th = std::atan2(y, x), q = a * a / (r * r);
    const double c2 = std::cos(2.0 * th), s2 = std::sin(2.0 * th);
    const double srr = 0.5 * (1.0 - q) + 0.5 * (1.0 - 4.0 * q + 3.0 * q * q) * c2;
    const double stt = 0.5 * (1.0 + q) - 0.5 * (1.0 + 3.0 * q * q) * c2;
    const double srt = -0.5 * (1.0 + 2.0 * q - 3.0 * q * q) * s2;
    return std::sqrt(srr * srr + stt * stt - srr * stt + 3.0 * srt * srt) * (3.03 / 3.0);
  };
  auto inside = [a](double x, double y) { return std::hypot(x, y) >= a; };
  return ball_reference(vm, inside, 0.0, a, 0.0, 1.0, diameter, thickness);
}

// The same plate, the tension ALONG THE PULL (what the across-layer check reads
// when the layers are stacked along the pull): sigma_xx from Kirsch, tension only.
// Hottest at (0, a), where it equals the von Mises value (the state there is
// uniaxial).
inline double plate_reading_along_pull(double a, double diameter, double thickness) {
  auto sxx = [a](double x, double y) {
    const double r = std::max(std::hypot(x, y), a), th = std::atan2(y, x), q = a * a / (r * r);
    const double c2 = std::cos(2.0 * th), s2 = std::sin(2.0 * th);
    const double srr = 0.5 * (1.0 - q) + 0.5 * (1.0 - 4.0 * q + 3.0 * q * q) * c2;
    const double stt = 0.5 * (1.0 + q) - 0.5 * (1.0 + 3.0 * q * q) * c2;
    const double srt = -0.5 * (1.0 + 2.0 * q - 3.0 * q * q) * s2;
    const double c = std::cos(th), s = std::sin(th);
    const double v = srr * c * c + stt * s * s - 2.0 * srt * s * c;
    return std::max(v, 0.0) * (3.03 / 3.0);
  };
  auto inside = [a](double x, double y) { return std::hypot(x, y) >= a; };
  return ball_reference(sxx, inside, 0.0, a, 0.0, 1.0, diameter, thickness);
}

// Thick ring, inner radius ri and outer ro, pressure 1 on the inner face, plane
// stress; the reading in units of the pressure. Hottest at the inner face.
inline double ring_reading(double ri, double ro, double diameter, double thickness) {
  auto vm = [ri, ro](double x, double y) {
    const double r = std::min(std::max(std::hypot(x, y), ri), ro), k = ri * ri / (ro * ro - ri * ri);
    const double st = k * (1.0 + ro * ro / (r * r)), sr = k * (1.0 - ro * ro / (r * r));
    return std::sqrt(st * st + sr * sr - st * sr);
  };
  auto inside = [ri, ro](double x, double y) {
    const double r = std::hypot(x, y);
    return r >= ri && r <= ro;
  };
  return ball_reference(vm, inside, ri, 0.0, 1.0, 0.0, diameter, thickness);
}

}  // namespace to_reference
