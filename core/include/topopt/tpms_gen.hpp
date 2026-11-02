#pragma once

// ★ THE SHEET-LATTICE GENERATOR (lattice types round 1, K2: 02-core-spec §3).
//
// Gyroid and Schwarz-D are built as the zero set of ONE field, contoured by core's dual-
// contouring mesher (lattice_dc.hpp, Schaefer, Ju & Warren 2007) streamed one layer at a
// time:
//
//     d(p) = max( tpms_wall_distance(p - anchor, L, t(p)),   the wall (tpms.hpp, R7)
//                 -inside_active_cells(p),                   the region's own cells
//                 h - boundary.signed_distance(p) )          the part eroded by one DC
//                                                            cell h (one surface: the
//                                                            same LatticeBoundary the
//                                                            strut clip and the shell use)
//
// A max of signed distances is their intersection, so where the wall meets an inactive
// cell or the part's surface it is CAPPED by that surface, and the result is closed.
//
// Grading is by wall THICKNESS at one cell size (R5): `wall_mm` is a field over the part
// (the run's graded density through the type's wall law), the period L never changes.
// The phase is 0 at `anchor`, the cell grid's origin, which is what the app sends.
//
// Deterministic (fixed traversal, no RNG, no threads) and streaming (memory is two layers
// of the DC grid, whatever the region).

#include <functional>

#include "topopt/lattice_dc.hpp"
#include "topopt/mesh.hpp"
#include "topopt/tpms.hpp"

namespace topopt {

class LatticeBoundary;

struct TpmsRegion {
  Vec3 anchor{0.0, 0.0, 0.0};      // the cell grid's origin; phase 0 here
  int nx = 0, ny = 0, nz = 0;      // cells
  double cell_mm = 0.0;            // the period L
  std::function<bool(int, int, int)> latticed;  // null => every cell
  const LatticeBoundary* boundary = nullptr;    // null => the cell block alone
};

struct TpmsWallField {
  double uniform_mm = 0.0;
  std::function<double(const Vec3&)> field;   // null => uniform_mm everywhere
  double at(const Vec3& p) const { return field ? field(p) : uniform_mm; }
};

struct TpmsGenOptions {
  // The DC cell. 0 => a THIRD of the thinnest wall the field can return (`min_wall_mm`).
  // Measured (gyroid / Schwarz-D, t = 0.8 mm, L = 8 mm, against the exact solid fraction):
  // t/h = 8, 4, 3, 2 -> mesh volume -0.06 / -0.20 / -0.37 / -1.13 % (gyroid), -0.04 /
  // -0.16 / -0.43 / -1.54 % (Schwarz-D), at 126k / 31k / 17k / 7k triangles per cell. A
  // third keeps the mass the certificate assumed to within half a percent.
  double dc_cell_mm = 0.0;
  double min_wall_mm = 0.0;        // required when dc_cell_mm is 0
};

struct TpmsGenStats {
  long long latticed_cells = 0;
  LatticeDcFieldStats dc;
  double dc_cell_mm = 0.0;
};

TpmsGenStats generate_tpms(TpmsKind kind, const TpmsRegion& region, const TpmsWallField& wall,
                           TriangleSink& sink, const TpmsGenOptions& opt);

}  // namespace topopt
