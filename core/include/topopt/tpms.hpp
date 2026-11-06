#pragma once

// ★ ONE TPMS FIELD IN CORE (lattice types round 1, R7; DECISIONS 2026-09-28 item 5).
//
// The gyroid and Schwarz-D sheets, as a small, pure, dependency-free module: value and
// gradient of each implicit surface, and the WALL as a band of ONE uniform thickness
// around its zero set. Structural/Aesthetic's sheet lattices and Flexible's bead-walled
// gyroid (its C2 step) both read it, so the sheet core certifies and the sheet it builds
// are one definition.
//
// THE FORMULAS are PR 198's probe's, character for character
// (core/tests/harness/lattice_homog_probe.cpp, gyroid_val / schwarzD_val), with period L
// and phase 0 at the cell grid's anchor (the point the caller passes as `anchor`, the same
// one the app sends, so preview and run agree):
//   gyroid     f = sin(ax)cos(ay) + sin(ay)cos(az) + sin(az)cos(ax)
//   Schwarz-D  f = sin(ax)sin(ay)sin(az) + sin(ax)cos(ay)cos(az)
//                + cos(ax)sin(ay)cos(az) + cos(ax)cos(ay)sin(az)
//   a = 2*pi / L, (x, y, z) measured from the anchor.
//
// THE WALL IS NOT PR 198's. That probe made the sheet as |f| < level, which is thick
// where the field is flat and thin where it is steep. Printing is in whole beads, so the
// production wall is the GRADIENT-NORMALISED band
//     |f| / |grad f| <= t / 2,
// one thickness t to first order everywhere on the sheet. tpms_wall_distance returns the
// signed estimate d = |f|/|grad f| - t/2 (mm; negative inside the wall), the field a mesher
// contours and the voxeliser thresholds. Every tensor row a sheet type certifies with is
// measured on THIS wall, never on PR 198's (01-types §B, trap 1).

#include <cmath>

namespace topopt {

enum class TpmsKind { Gyroid, SchwarzD };

struct TpmsValue {
  double f = 0.0;                    // the implicit function
  double gx = 0.0, gy = 0.0, gz = 0.0;  // its gradient, per mm
};

// The value and exact gradient at (x, y, z) mm, relative to the anchor, period L mm.
inline TpmsValue tpms_eval(TpmsKind kind, double x, double y, double z, double L) {
  const double a = 2.0 * M_PI / L;
  const double sx = std::sin(a * x), cx = std::cos(a * x);
  const double sy = std::sin(a * y), cy = std::cos(a * y);
  const double sz = std::sin(a * z), cz = std::cos(a * z);
  TpmsValue v;
  if (kind == TpmsKind::Gyroid) {
    v.f = sx * cy + sy * cz + sz * cx;
    v.gx = a * (cx * cy - sz * sx);
    v.gy = a * (-sx * sy + cy * cz);
    v.gz = a * (-sy * sz + cz * cx);
  } else {
    v.f = sx * sy * sz + sx * cy * cz + cx * sy * cz + cx * cy * sz;
    v.gx = a * (cx * sy * sz + cx * cy * cz - sx * sy * cz - sx * cy * sz);
    v.gy = a * (sx * cy * sz - sx * sy * cz + cx * cy * cz - cx * sy * sz);
    v.gz = a * (sx * sy * cz - sx * cy * sz - cx * sy * sz + cx * cy * cz);
  }
  return v;
}

// The signed wall-distance estimate (mm): |f|/|grad f| - t/2, negative inside the wall.
// Where the gradient vanishes (the field's critical points, which lie off the zero set)
// the point is far from the sheet, and +L is returned rather than dividing by zero.
inline double tpms_wall_distance(TpmsKind kind, double x, double y, double z, double L,
                                 double t) {
  const TpmsValue v = tpms_eval(kind, x, y, z, L);
  const double g = std::sqrt(v.gx * v.gx + v.gy * v.gy + v.gz * v.gz);
  if (!(g > 1e-12)) return L;
  return std::fabs(v.f) / g - 0.5 * t;
}

inline bool tpms_in_wall(TpmsKind kind, double x, double y, double z, double L, double t) {
  return tpms_wall_distance(kind, x, y, z, L, t) < 0.0;
}

// Core's id for each sheet ("gyroid", "schwarz_d"): the print-tests file's keys and the
// job's topology strings.
inline const char* tpms_id(TpmsKind kind) {
  return kind == TpmsKind::Gyroid ? "gyroid" : "schwarz_d";
}

}  // namespace topopt
