// The sheet-lattice generator (topopt/tpms_gen.hpp states the contract).

#include "topopt/tpms_gen.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <unordered_map>
#include <vector>

#include "topopt/lattice_boundary.hpp"

namespace topopt {

namespace {

// ★ A LOWER BOUND ON THE PART'S DISTANCE, cached on a lattice of nodes `g` apart. The
// boundary's signed distance is 1-Lipschitz (every term of it is an exact distance, or a
// min, max or halved difference of them: lattice_boundary.cpp), so at p it is at least
// its value at the nearest node minus the distance to that node. Where that bound already
// keeps the clip term under the field's other terms, the exact query cannot change the
// field and is skipped: the field is the same to the bit (the sample cube's STL is byte-
// identical with it). Measured on the M2 stand's gyroid rung 0.52, a field evaluation in
// the simplifier averaged 0.60 us without it and 0.10 us with it.
class ClipBound {
 public:
  ClipBound(const LatticeBoundary& b, double g) : b_(b), g_(g) {}
  double lower(const Vec3& p) const {
    const long long i = std::llround(p.x / g_), j = std::llround(p.y / g_),
                    k = std::llround(p.z / g_);
    const std::uint64_t key = (static_cast<std::uint64_t>(i & 0x1fffff) << 42) |
                              (static_cast<std::uint64_t>(j & 0x1fffff) << 21) |
                              static_cast<std::uint64_t>(k & 0x1fffff);
    const Vec3 c{static_cast<double>(i) * g_, static_cast<double>(j) * g_,
                 static_cast<double>(k) * g_};
    auto it = node_.find(key);
    if (it == node_.end()) it = node_.emplace(key, b_.signed_distance(c)).first;
    const double dx = p.x - c.x, dy = p.y - c.y, dz = p.z - c.z;
    return it->second - std::sqrt(dx * dx + dy * dy + dz * dz) - 1e-7;  // rounding margin
  }

 private:
  const LatticeBoundary& b_;
  double g_;
  mutable std::unordered_map<std::uint64_t, double> node_;
};

// ★ The distance from p to the nearest cell of the OTHER kind (active against inactive),
// capped at one cell: exact, since any cell nearer than L lies in the 26 about p's own, and
// so continuous. It was the distance to the nearest FACE so shared, which is L in an
// inactive cell that meets an active one only along an edge or at a corner: the field read
// 4.0 a hair outside a 4 mm cell's convex edge, and no mesh can follow that jump (82 such
// samples on the M2 stand's gyroid rung 0.52, each up to 4 mm outside any band).
//
// A cell's 27 neighbours: bit c (c = 0..26, 13 = the cell) is set when that one is of the
// other kind, bit 27 when the cell is active.
std::uint32_t cell_kinds_mask(const TpmsRegion& R, int i, int j, int k) {
  auto active = [&](int a, int b, int c) {
    if (a < 0 || b < 0 || c < 0 || a >= R.nx || b >= R.ny || c >= R.nz) return false;
    return !R.latticed || R.latticed(a, b, c);
  };
  const bool in = active(i, j, k);
  std::uint32_t m = in ? (1u << 27) : 0u;
  for (int c = 0; c < 27; ++c)
    if (c != 13 && active(i + c % 3 - 1, j + c / 3 % 3 - 1, k + c / 9 - 1) != in) m |= 1u << c;
  return m;
}

// The masks cached per cell of the grid, so a field evaluation reads one word instead of
// calling `latticed` 27 times.
class CellKinds {
 public:
  explicit CellKinds(const TpmsRegion& R)
      : R_(R), mask_(static_cast<std::size_t>(R.nx) * R.ny * R.nz, kUnread) {}
  std::uint32_t at(int i, int j, int k) const {
    if (i < 0 || j < 0 || k < 0 || i >= R_.nx || j >= R_.ny || k >= R_.nz)
      return cell_kinds_mask(R_, i, j, k);
    std::uint32_t& m = mask_[(static_cast<std::size_t>(k) * R_.ny + j) * R_.nx + i];
    if (m == kUnread) m = cell_kinds_mask(R_, i, j, k);
    return m;
  }

 private:
  static constexpr std::uint32_t kUnread = 0xffffffffu;
  const TpmsRegion& R_;
  mutable std::vector<std::uint32_t> mask_;
};

double depth_to_other_kind(const TpmsRegion& R, const Vec3& p, bool* in_out,
                           const CellKinds* kinds) {
  const double L = R.cell_mm;
  const double u = (p.x - R.anchor.x) / L, v = (p.y - R.anchor.y) / L, w = (p.z - R.anchor.z) / L;
  const int i = static_cast<int>(std::floor(u)), j = static_cast<int>(std::floor(v)),
            k = static_cast<int>(std::floor(w));
  const std::uint32_t m = kinds ? kinds->at(i, j, k) : cell_kinds_mask(R, i, j, k);
  *in_out = (m >> 27) & 1u;
  if (!(m & ((1u << 27) - 1u))) return L;
  const double f[3] = {(u - i) * L, (v - j) * L, (w - k) * L};
  double best2 = L * L;
  for (int c = 0; c < 27; ++c) {
    const int o[3] = {c % 3 - 1, c / 3 % 3 - 1, c / 9 - 1};
    if (!((m >> c) & 1u)) continue;
    double d2 = 0.0;
    for (int a = 0; a < 3; ++a) {
      const double g = o[a] < 0 ? f[a] : o[a] > 0 ? L - f[a] : 0.0;
      d2 += g * g;
    }
    best2 = std::min(best2, d2);
  }
  return std::sqrt(best2);
}

// What generate_tpms keeps beside the field, so it is evaluated faster and unchanged.
struct FieldAids {
  const ClipBound* clip = nullptr;
  const CellKinds* kinds = nullptr;
};

// The clip term of the field at p, joined onto the field's other terms `d`: exactly
// max(d, h - clip(p)), with the exact query skipped where `cb` proves it cannot bind.
double join_clip(const TpmsRegion& R, double h, const Vec3& p, double d, const ClipBound* cb) {
  if (R.clip) return std::max(d, h - R.clip(p));
  if (!R.boundary) return d;
  if (cb && h - cb->lower(p) <= d) return d;
  return std::max(d, h - R.boundary->signed_distance(p));
}

// generate_tpms's field, shared with tpms_clipped_field so the generator and the run's
// volume check read one set.
double clipped_field(TpmsKind kind, const TpmsRegion& R, const TpmsWallField& wall, double h,
                     const Vec3& p, const FieldAids& aids = FieldAids{}) {
  const double L = R.cell_mm;
  // Depth inside the union of active cells (positive inside, negative in an inactive cell):
  // the cap surface is a cell face, and the max() below makes it a plane cut.
  auto active_depth = [&](const Vec3& q) {
    bool in = false;
    const double d = depth_to_other_kind(R, q, &in, aids.kinds);
    return in ? d : -d;
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
  return join_clip(R, h, p, d, aids.clip);
}

// The cut alone: the active cells' faces and the part (eroded by one DC cell), as in
// clipped_field. Positive outside the cut.
double clip_term(const TpmsRegion& R, double h, const Vec3& p, const FieldAids& aids) {
  TpmsWallField none;
  none.uniform_mm = 0.0;
  bool in = false;
  const double depth = depth_to_other_kind(R, p, &in, aids.kinds);  // as active_depth
  const double d = in ? -depth : depth;
  return join_clip(R, h, p, d, aids.clip);
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
  // The part's distance is queried at every sample the simplifier takes; nodes two DC
  // cells apart bound it exactly enough to skip it a DC cell or so inside the part.
  std::unique_ptr<ClipBound> cbo;
  if (R.boundary && !R.clip) cbo = std::make_unique<ClipBound>(*R.boundary, 2.0 * h);
  const CellKinds kinds(R);
  FieldAids aids;
  aids.clip = cbo.get();
  aids.kinds = &kinds;
  const std::function<double(const Vec3&)> true_field = [&](const Vec3& p) {
    return clipped_field(kind, R, wall, h, p, aids);
  };
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
  so.at_cut = [&R, h, kind, &CW, &aids](const Vec3& p) {
    const double c = clip_term(R, h, p, aids);
    if (!(std::abs(c) < 3.0 * h)) return false;
    const double w = tpms_wall_distance(kind, p.x - R.anchor.x, p.y - R.anchor.y,
                                        p.z - R.anchor.z, R.cell_mm, CW.at(p));
    return std::abs(w) < 3.0 * h;
  };
  so.cut_tol_mm = std::max(dev, 0.5 * h);
  // ★ Steps (TpmsGenOptions::true_wall_steps): the walls in reach are read at the 27 points
  // of the cube of half-side three DC cells about p (the cut's reach). A step's band runs
  // from the bound outside the THICKEST of them to the THINNEST one's own floor inside it
  // (max_in at that wall, as above); the answer is how far p lies outside it.
  if (opt.true_wall_steps && opt.true_wall_mm && opt.wall_param_of) {
    const auto tw = opt.true_wall_mm;
    const auto law = opt.wall_param_of;
    const double reach = 3.0 * h;
    so.step = [&R, h, kind, tw, law, dev, bead, reach, &aids](const Vec3& p) {
      double wlo = tw(p), whi = wlo;
      for (int c = 0; c < 27; ++c) {
        if (c == 13) continue;  // p itself
        const Vec3 q{p.x + reach * (c % 3 - 1), p.y + reach * (c / 3 % 3 - 1),
                     p.z + reach * (c / 9 - 1)};
        const double w = tw(q);
        wlo = std::min(wlo, w);
        whi = std::max(whi, w);
      }
      if (!(whi > wlo)) return -1.0;
      TpmsWallField thick, thin;
      thick.uniform_mm = law(whi);
      thin.uniform_mm = law(wlo);
      const double floor_in = bead > 0.0 ? std::clamp(0.5 * (wlo - bead), 0.0, dev) : dev;
      const double out = clipped_field(kind, R, thick, h, p, aids) - dev;
      const double in = -clipped_field(kind, R, thin, h, p, aids) - floor_in;
      return std::max({0.0, out, in});
    };
  }
  // Long slabs: a seam is where a triangle beside a written one can no longer be mended
  // (measured: 0.005 mm past the bound at one seam of a 24 mm gyroid block in 16 mm
  // slabs, none in one flush). The receipt states the measured maximum either way.
  so.slab_mm = std::max(64.0, 4.0 * L);
  so.front_margin_mm = 3.0 * h;
  const std::function<double(const Vec3&)> contoured = [&](const Vec3& p) {
    return clipped_field(kind, R, CW, h, p, aids);
  };
  const std::function<Vec3(const Vec3&)> contoured_gradient = [&](const Vec3& p) {
    const Vec3 g{contoured({p.x + e, p.y, p.z}) - contoured({p.x - e, p.y, p.z}),
                 contoured({p.x, p.y + e, p.z}) - contoured({p.x, p.y - e, p.z}),
                 contoured({p.x, p.y, p.z + e}) - contoured({p.x, p.y, p.z - e})};
    const double l = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
    return l > 1e-12 ? Vec3{g.x / l, g.y / l, g.z / l} : Vec3{0, 0, 1};
  };
  BoundedSimplifySink simp(sink, true_field, so);
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
