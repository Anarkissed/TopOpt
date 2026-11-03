// The sheet-lattice generator (topopt/tpms_gen.hpp states the contract).

#include "topopt/tpms_gen.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

#include "topopt/lattice_boundary.hpp"

namespace topopt {

namespace {

// generate_tpms's field, shared with tpms_clipped_field so the generator and the run's
// volume check read one set. The body is the generator's, moved here unchanged.
double clipped_field(TpmsKind kind, const TpmsRegion& R, const TpmsWallField& wall, double h,
                     const Vec3& p) {
  const double L = R.cell_mm;
  auto active = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= R.nx || j >= R.ny || k >= R.nz) return false;
    return !R.latticed || R.latticed(i, j, k);
  };
  // Depth inside the union of active cells, as a distance to the nearest face shared with
  // an inactive cell (positive inside, negative in an inactive cell). Exact enough for a
  // cap: the cap surface is a cell face, and the max() below makes it a plane cut.
  auto active_depth = [&](const Vec3& q) {
    const double u = (q.x - R.anchor.x) / L, v = (q.y - R.anchor.y) / L,
                 w = (q.z - R.anchor.z) / L;
    const int i = static_cast<int>(std::floor(u)), j = static_cast<int>(std::floor(v)),
              k = static_cast<int>(std::floor(w));
    const double fx = (u - i) * L, fy = (v - j) * L, fz = (w - k) * L;
    if (!active(i, j, k)) {
      // outside: the distance to this cell's nearest face that borders an active cell
      double best = L;
      if (active(i - 1, j, k)) best = std::min(best, fx);
      if (active(i + 1, j, k)) best = std::min(best, L - fx);
      if (active(i, j - 1, k)) best = std::min(best, fy);
      if (active(i, j + 1, k)) best = std::min(best, L - fy);
      if (active(i, j, k - 1)) best = std::min(best, fz);
      if (active(i, j, k + 1)) best = std::min(best, L - fz);
      return -best;
    }
    double best = L;
    if (!active(i - 1, j, k)) best = std::min(best, fx);
    if (!active(i + 1, j, k)) best = std::min(best, L - fx);
    if (!active(i, j - 1, k)) best = std::min(best, fy);
    if (!active(i, j + 1, k)) best = std::min(best, L - fy);
    if (!active(i, j, k - 1)) best = std::min(best, fz);
    if (!active(i, j, k + 1)) best = std::min(best, L - fz);
    return best;
  };
  // Cheapest term first. A max() of signed distances is positive as soon as ONE term is,
  // so once a term is more than two DC cells positive the sign is decided and the exact
  // value no longer matters: every point the contour actually bisects or differentiates
  // lies within a cell of the surface, where all three terms are evaluated in full. This
  // keeps the part's (expensive) boundary distance off the bulk of the box.
  const double far = 2.0 * h;
  double d = -active_depth(p);
  if (d > far) return d;
  d = std::max(d, tpms_wall_distance(kind, p.x - R.anchor.x, p.y - R.anchor.y,
                                     p.z - R.anchor.z, L, wall.at(p)));
  if (d > far) return d;
  // The part, ERODED BY ONE DC CELL. Dual contouring places each vertex by its cell's
  // QEF and clamps it to the cell, so where the wall meets the clip plane at an angle a
  // vertex can land on the far face of a cell the surface only grazes: measured half a
  // cell (0.100 mm at h = 0.2) outside the part on a clipped gyroid block. The strut clip
  // erodes by each strut's radius for the same reason -- the run's export guard refuses
  // lattice geometry outside the shell -- and the band given up lies under the solid
  // shell (wall_thickness_mm, ~2 mm), so it is never seen.
  if (R.boundary) d = std::max(d, h - R.boundary->signed_distance(p));
  return d;
}

}  // namespace

TpmsGenStats generate_tpms(TpmsKind kind, const TpmsRegion& R, const TpmsWallField& wall,
                           TriangleSink& sink, const TpmsGenOptions& opt) {
  if (R.nx < 1 || R.ny < 1 || R.nz < 1 || !(R.cell_mm > 0.0))
    throw std::invalid_argument("generate_tpms: degenerate region");
  double h = opt.dc_cell_mm;
  if (!(h > 0.0)) {
    if (!(opt.min_wall_mm > 0.0))
      throw std::invalid_argument("generate_tpms: state dc_cell_mm or min_wall_mm");
    h = opt.min_wall_mm / 3.0;
  }
  TpmsGenStats st;
  st.dc_cell_mm = h;
  const double L = R.cell_mm;
  auto active = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= R.nx || j >= R.ny || k >= R.nz) return false;
    return !R.latticed || R.latticed(i, j, k);
  };
  for (int k = 0; k < R.nz; ++k)
    for (int j = 0; j < R.ny; ++j)
      for (int i = 0; i < R.nx; ++i)
        if (active(i, j, k)) ++st.latticed_cells;

  const std::function<double(const Vec3&)> field = [&](const Vec3& p) {
    return clipped_field(kind, R, wall, h, p);
  };
  const double e = std::max(1e-4, 0.01 * h);
  const std::function<Vec3(const Vec3&)> gradient = [&](const Vec3& p) {
    const Vec3 g{field({p.x + e, p.y, p.z}) - field({p.x - e, p.y, p.z}),
                 field({p.x, p.y + e, p.z}) - field({p.x, p.y - e, p.z}),
                 field({p.x, p.y, p.z + e}) - field({p.x, p.y, p.z - e})};
    const double l = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
    return l > 1e-12 ? Vec3{g.x / l, g.y / l, g.z / l} : Vec3{0, 0, 1};
  };
  // The box: the cell block padded by one DC cell so the field is positive on its faces.
  const Vec3 lo{R.anchor.x - h, R.anchor.y - h, R.anchor.z - h};
  const Vec3 hi{R.anchor.x + R.nx * L + h, R.anchor.y + R.ny * L + h,
                R.anchor.z + R.nz * L + h};
  st.dc = lattice_dual_contour_field(field, gradient, lo, hi, h, sink);
  return st;
}

double tpms_clipped_field(TpmsKind kind, const TpmsRegion& region, const TpmsWallField& wall,
                          double h, const Vec3& p) {
  return clipped_field(kind, region, wall, h, p);
}

}  // namespace topopt
