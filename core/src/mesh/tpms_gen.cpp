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
  if (R.clip) d = std::max(d, h - R.clip(p));
  else if (R.boundary) d = std::max(d, h - R.boundary->signed_distance(p));
  return d;
}

// The cut alone: the active cells' faces and the part (eroded by one DC cell), as in
// clipped_field. Positive outside the cut.
double clip_term(const TpmsRegion& R, double h, const Vec3& p) {
  TpmsWallField none;
  none.uniform_mm = 0.0;
  const double L = R.cell_mm;
  auto active = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= R.nx || j >= R.ny || k >= R.nz) return false;
    return !R.latticed || R.latticed(i, j, k);
  };
  const double u = (p.x - R.anchor.x) / L, v = (p.y - R.anchor.y) / L, w = (p.z - R.anchor.z) / L;
  const int i = static_cast<int>(std::floor(u)), j = static_cast<int>(std::floor(v)),
            k = static_cast<int>(std::floor(w));
  const double fx = (u - i) * L, fy = (v - j) * L, fz = (w - k) * L;
  double depth = L;  // as active_depth: to the nearest face shared with the other kind
  const bool in = active(i, j, k);
  if (active(i - 1, j, k) != in) depth = std::min(depth, fx);
  if (active(i + 1, j, k) != in) depth = std::min(depth, L - fx);
  if (active(i, j - 1, k) != in) depth = std::min(depth, fy);
  if (active(i, j + 1, k) != in) depth = std::min(depth, L - fy);
  if (active(i, j, k - 1) != in) depth = std::min(depth, fz);
  if (active(i, j, k + 1) != in) depth = std::min(depth, L - fz);
  double d = in ? -depth : depth;
  if (R.clip) d = std::max(d, h - R.clip(p));
  else if (R.boundary) d = std::max(d, h - R.boundary->signed_distance(p));
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
  if (!(opt.max_deviation_mm > 0.0)) {
    st.dc = lattice_dual_contour_field(field, gradient, lo, hi, h, sink);
    return st;
  }
  // ★ Finding 8: bounded edge collapse against the TRUE field, streamed in slabs (below);
  // a vertex within three DC cells of the contouring front is still live.
  const double dev = opt.max_deviation_mm, bead = opt.bead_mm;
  BoundedSimplifyOptions so;
  so.max_out_mm = dev;
  TpmsWallField CW = wall;  // the wall contoured: the true one, offset near the bead
  if (bead > 0.0 && opt.true_wall_mm) {
    const auto tw = opt.true_wall_mm;
    so.max_in_mm = [dev, bead, tw](const Vec3& p) {
      return std::clamp(0.5 * (tw(p) - bead), 0.0, dev);
    };
    if (opt.wall_param_of) {
      const auto law = opt.wall_param_of;
      CW.field = [dev, bead, tw, law](const Vec3& p) {
        return law(tpms_contoured_wall_mm(tw(p), bead, dev));
      };
    }
  }
  so.sample_spacing_mm = std::min(0.1, 0.5 * h);
  // At a CREASE only: within three DC cells of both the cut and the wall. A cap's flat
  // interior is free to simplify like any other surface.
  so.at_cut = [&R, h, kind, &CW](const Vec3& p) {
    const double c = clip_term(R, h, p);
    if (!(std::abs(c) < 3.0 * h)) return false;
    const double w = tpms_wall_distance(kind, p.x - R.anchor.x, p.y - R.anchor.y,
                                        p.z - R.anchor.z, R.cell_mm, CW.at(p));
    return std::abs(w) < 3.0 * h;
  };
  so.cut_tol_mm = std::max(dev, 0.5 * h);
  // Long slabs: a seam is where a triangle beside a written one can no longer be mended
  // (measured: 0.005 mm past the bound at one seam of a 24 mm gyroid block in 16 mm
  // slabs, none in one flush). The receipt states the measured maximum either way.
  so.slab_mm = std::max(64.0, 4.0 * L);
  so.front_margin_mm = 3.0 * h;
  const std::function<double(const Vec3&)> contoured = [&](const Vec3& p) {
    return clipped_field(kind, R, CW, h, p);
  };
  const std::function<Vec3(const Vec3&)> contoured_gradient = [&](const Vec3& p) {
    const Vec3 g{contoured({p.x + e, p.y, p.z}) - contoured({p.x - e, p.y, p.z}),
                 contoured({p.x, p.y + e, p.z}) - contoured({p.x, p.y - e, p.z}),
                 contoured({p.x, p.y, p.z + e}) - contoured({p.x, p.y, p.z - e})};
    const double l = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
    return l > 1e-12 ? Vec3{g.x / l, g.y / l, g.z / l} : Vec3{0, 0, 1};
  };
  BoundedSimplifySink simp(sink, field, so);
  st.dc = lattice_dual_contour_field(contoured, contoured_gradient, lo, hi, h, simp, 12, 0.02,
                                     /*best_diagonal=*/true);
  simp.finish();
  st.simplified = true;
  st.simplify = simp.stats();
  return st;
}

double tpms_clipped_field(TpmsKind kind, const TpmsRegion& region, const TpmsWallField& wall,
                          double h, const Vec3& p) {
  return clipped_field(kind, region, wall, h, p);
}

}  // namespace topopt
