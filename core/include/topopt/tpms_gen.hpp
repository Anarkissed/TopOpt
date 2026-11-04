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

#include <algorithm>
#include <functional>

#include "topopt/lattice_dc.hpp"
#include "topopt/mesh_simplify.hpp"
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
  // An analytic clip (positive inside, a distance or a Lipschitz-1 bound on one) used in
  // place of `boundary` when set: the sample coupon's own shape, where the exact distance
  // to its mesh would be evaluated at every one of the contouring's samples.
  std::function<double(const Vec3&)> clip;
};

struct TpmsWallField {
  double uniform_mm = 0.0;
  std::function<double(const Vec3&)> field;   // null => uniform_mm everywhere
  double at(const Vec3& p) const { return field ? field(p) : uniform_mm; }
};

// ★ Finding 8 (ruling 2026-11-02): the furthest a sheet's mesh may sit from its true surface
// in a run and in the sample block, both ways (well under a 0.2 mm layer).
constexpr double kSheetMaxDeviationMm = 0.02;

struct TpmsGenOptions {
  // The DC cell. 0 => a THIRD of the thinnest wall the field can return (`min_wall_mm`).
  // Measured (gyroid / Schwarz-D, t = 0.8 mm, L = 8 mm, against the exact solid fraction):
  // t/h = 8, 4, 3, 2 -> mesh volume -0.06 / -0.20 / -0.37 / -1.13 % (gyroid), -0.04 /
  // -0.16 / -0.43 / -1.54 % (Schwarz-D), at 126k / 31k / 17k / 7k triangles per cell. A
  // third keeps the mass the certificate assumed to within half a percent.
  double dc_cell_mm = 0.0;
  double min_wall_mm = 0.0;        // required when dc_cell_mm is 0
  // ★ Finding 8 (ruling 2026-11-02): the contoured mesh simplified by bounded edge collapse
  // (mesh_simplify.hpp) to at most this distance from the true surface. 0 => the mesh as
  // contoured, byte-identical to before. With `bead_mm` and `true_wall_mm` (the TRUE wall
  // at a point), no wall is cut below one bead: where the wall is within twice the bound of
  // the bead, the mesh may only bulge outward.
  double max_deviation_mm = 0.0;
  double bead_mm = 0.0;
  std::function<double(const Vec3&)> true_wall_mm;
  // The type's wall law, TRUE wall (mm) -> the field parameter (lattice_sheet_wall_param_mm).
  // With it, a wall nearer the bead than twice the bound is CONTOURED offset outward by
  // half the shortfall, so the mesh can sit either side of what it contours and still
  // never cut the true wall: the band about the true surface is [-a, +bound], a = half
  // the wall's margin over the bead (capped at the bound), and about the contoured surface
  // it is symmetric, +-(bound + a)/2. Measured against the TRUE wall either way.
  std::function<double(double)> wall_param_of;
};

struct TpmsGenStats {
  long long latticed_cells = 0;
  LatticeDcFieldStats dc;
  double dc_cell_mm = 0.0;
  bool simplified = false;          // max_deviation_mm > 0
  BoundedSimplifyStats simplify;    // triangles in/out and the MEASURED deviation
};

TpmsGenStats generate_tpms(TpmsKind kind, const TpmsRegion& region, const TpmsWallField& wall,
                           TriangleSink& sink, const TpmsGenOptions& opt);

// The wall generate_tpms CONTOURS when it simplifies (max_deviation_mm > 0): the true wall,
// thickened where it is within twice the bound of the bead so the mesh may sit either side
// of what it contours and never cut the true wall below the bead (TpmsGenOptions). Exposed
// so a measurement of the written mesh (the run's volume check) reads the same wall.
inline double tpms_contoured_wall_mm(double true_wall_mm, double bead_mm, double dev_mm) {
  if (!(bead_mm > 0.0) || !(dev_mm > 0.0)) return true_wall_mm;
  const double a = std::clamp(0.5 * (true_wall_mm - bead_mm), 0.0, dev_mm);
  return true_wall_mm + (dev_mm - a);  // each face out by (dev - a) / 2
}

// The field generate_tpms contours, at DC cell `h` (TpmsGenStats::dc_cell_mm): negative
// inside the emitted solid. The same function the generator calls, so the run's volume
// check (lattice_volume_check.hpp, Finding 7) measures the set the mesh is contoured from.
double tpms_clipped_field(TpmsKind kind, const TpmsRegion& region, const TpmsWallField& wall,
                          double h, const Vec3& p);

}  // namespace topopt
