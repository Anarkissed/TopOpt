// The lattice boundary predicate (handoff 2026-07-29-lattice-boundary-finish).
// See the header for the contract; the load-bearing property implemented here is
// that signed_distance is a 1-LIPSCHITZ LOWER BOUND on the true signed distance:
//   * each primitive term is the EXACT signed distance to its own region
//     (plane, capped cylinder, bounded slab, voxel-cube union);
//   * the allowed region is base ∩ ¬(∪ keep-outs), and min() of exact terms is
//     a 1-Lipschitz lower bound for the intersection.
// Everything is closed-form arithmetic — no sampled field, no RNG, no state —
// so the predicate is deterministic and clip_segment's Lipschitz certificates
// are sound.

#include "topopt/lattice_boundary.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace topopt {
namespace {

Vec3 vsub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 vadd(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 vscale(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double vdot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
double vnorm(const Vec3& a) { return std::sqrt(vdot(a, a)); }

// EXACT signed distance of p to keep-out region K (positive INSIDE K). The
// allowed-region term is its negation: positive outside K.
double keep_out_signed_distance(const ClearanceGeometry& g, const Vec3& p) {
  if (!g.valid) return -1e30;  // an invalid region contains nothing
  if (g.kind == ClearanceKind::Bolt) {
    const Vec3 d = vsub(p, g.axis_point);
    const double t = vdot(d, g.axis_dir);
    const Vec3 radial = vsub(d, vscale(g.axis_dir, t));
    const double rho = vnorm(radial);
    const double d_rad = g.radius - rho;              // >0: radially inside
    const double d_ax = std::min(t - g.t_lo, g.t_hi - t);  // >0: axially inside
    if (d_rad >= 0.0 && d_ax >= 0.0) return std::min(d_rad, d_ax);
    const double out_r = std::max(-d_rad, 0.0);
    const double out_a = std::max(-d_ax, 0.0);
    return -std::sqrt(out_r * out_r + out_a * out_a);
  }
  // Face slab: a box in the (u, w, normal) frame — s in [0, depth],
  // u in [u_lo, u_hi], w in [w_lo, w_hi].
  const Vec3 d = vsub(p, g.origin);
  const double s = vdot(d, g.normal);
  const double u = vdot(d, g.u);
  const double w = vdot(d, g.w);
  const double ds = std::min(s - 0.0, g.depth - s);
  const double du = std::min(u - g.u_lo, g.u_hi - u);
  const double dw = std::min(w - g.w_lo, g.w_hi - w);
  if (ds >= 0.0 && du >= 0.0 && dw >= 0.0) return std::min({ds, du, dw});
  const double os = std::max(-ds, 0.0);
  const double ou = std::max(-du, 0.0);
  const double ow = std::max(-dw, 0.0);
  return -std::sqrt(os * os + ou * ou + ow * ow);
}

}  // namespace

void LatticeBoundary::add_half_space(const Vec3& point, const Vec3& outward_normal) {
  const double n = vnorm(outward_normal);
  if (!(n > 0.0))
    throw std::invalid_argument("LatticeBoundary: degenerate half-space normal");
  Plane pl;
  pl.point = point;
  pl.unit_outward = vscale(outward_normal, 1.0 / n);
  pl.face = static_cast<int>(faces_.size());
  planes_.push_back(pl);

  LatticeBoundaryFace f;
  f.kind = LatticeBoundaryFace::Kind::Plane;
  f.origin = point;
  f.normal = pl.unit_outward;
  faces_.push_back(f);
}

void LatticeBoundary::add_box(const Vec3& lo, const Vec3& hi) {
  add_half_space({lo.x, 0.5 * (lo.y + hi.y), 0.5 * (lo.z + hi.z)}, {-1, 0, 0});
  add_half_space({hi.x, 0.5 * (lo.y + hi.y), 0.5 * (lo.z + hi.z)}, {1, 0, 0});
  add_half_space({0.5 * (lo.x + hi.x), lo.y, 0.5 * (lo.z + hi.z)}, {0, -1, 0});
  add_half_space({0.5 * (lo.x + hi.x), hi.y, 0.5 * (lo.z + hi.z)}, {0, 1, 0});
  add_half_space({0.5 * (lo.x + hi.x), 0.5 * (lo.y + hi.y), lo.z}, {0, 0, -1});
  add_half_space({0.5 * (lo.x + hi.x), 0.5 * (lo.y + hi.y), hi.z}, {0, 0, 1});
}

void LatticeBoundary::set_voxel_base(const VoxelGrid* grid,
                                     const std::vector<double>* density,
                                     double iso, double window_mm) {
  if (!grid || !density || density->size() != grid->voxel_count())
    throw std::invalid_argument("LatticeBoundary: voxel base size mismatch");
  if (!(window_mm > 0.0))
    throw std::invalid_argument("LatticeBoundary: voxel window must be > 0");
  voxel_grid_ = grid;
  voxel_density_ = density;
  voxel_iso_ = iso;
  voxel_window_mm_ = window_mm;
}

void LatticeBoundary::add_keep_out(const ClearanceGeometry& geom, bool collar) {
  if (!geom.valid) return;  // same safe no-op as the rasterizer
  keep_outs_.push_back(geom);
  if (geom.kind == ClearanceKind::Bolt) {
    LatticeBoundaryFace f;
    f.kind = LatticeBoundaryFace::Kind::Bore;
    f.axis_point = geom.axis_point;
    f.axis_dir = geom.axis_dir;
    f.radius = geom.radius;
    f.t_lo = geom.t_lo;
    f.t_hi = geom.t_hi;
    f.collar = collar;
    keep_out_face_.push_back(static_cast<int>(faces_.size()));
    faces_.push_back(f);
  } else {
    keep_out_face_.push_back(-1);  // slab keep-out: no wall to dress
  }
}

// Distance from p to a solid voxel cube [i,i+1]x[j,j+1]x[k,k+1] (grid units,
// converted to mm) — the exact point-to-axis-aligned-box distance.
double LatticeBoundary::voxel_distance(const Vec3& p) const {
  const VoxelGrid& g = *voxel_grid_;
  const std::vector<double>& dens = *voxel_density_;
  const double h = g.spacing;
  const double W = voxel_window_mm_;
  // p in grid units.
  const double gx = (p.x - g.origin.x) / h;
  const double gy = (p.y - g.origin.y) / h;
  const double gz = (p.z - g.origin.z) / h;
  const int ci = static_cast<int>(std::floor(gx));
  const int cj = static_cast<int>(std::floor(gy));
  const int ck = static_cast<int>(std::floor(gz));
  auto solid = [&](int i, int j, int k) -> bool {
    if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz)
      return false;  // outside the grid is void
    return dens[g.index(i, j, k)] >= voxel_iso_;
  };
  const bool inside = solid(ci, cj, ck);
  // Expanding Chebyshev shells: nearest cube of the OPPOSITE occupancy. The
  // shell lower bound (shell-1)*h lets us stop as soon as no closer cube can
  // exist; the result is the exact distance, clamped to the window.
  auto box_dist = [&](int i, int j, int k) -> double {
    const double lox = g.origin.x + i * h, hix = lox + h;
    const double loy = g.origin.y + j * h, hiy = loy + h;
    const double loz = g.origin.z + k * h, hiz = loz + h;
    const double dx = std::max({lox - p.x, 0.0, p.x - hix});
    const double dy = std::max({loy - p.y, 0.0, p.y - hiy});
    const double dz = std::max({loz - p.z, 0.0, p.z - hiz});
    return std::sqrt(dx * dx + dy * dy + dz * dz);
  };
  const int max_shell = static_cast<int>(std::ceil(W / h)) + 1;
  const bool occ_target = !inside;  // nearest cube of the OPPOSITE occupancy
  double best = W;
  auto visit = [&](int i, int j, int k) {
    // Grid-exterior cells count as void (solid() already returns false there).
    if (solid(i, j, k) != occ_target) return;
    const double d = box_dist(i, j, k);
    if (d < best) best = d;
  };
  for (int s = 0; s <= max_shell; ++s) {
    if (static_cast<double>(s - 1) * h >= best) break;  // no closer cube possible
    if (s == 0) {
      visit(ci, cj, ck);
      continue;
    }
    // Enumerate ONLY the Chebyshev-shell surface: two full k-faces, then the
    // four side bands of each intermediate k-slab.
    for (int j = cj - s; j <= cj + s; ++j)
      for (int i = ci - s; i <= ci + s; ++i) {
        visit(i, j, ck - s);
        visit(i, j, ck + s);
      }
    for (int k = ck - s + 1; k <= ck + s - 1; ++k) {
      for (int i = ci - s; i <= ci + s; ++i) {
        visit(i, cj - s, k);
        visit(i, cj + s, k);
      }
      for (int j = cj - s + 1; j <= cj + s - 1; ++j) {
        visit(ci - s, j, k);
        visit(ci + s, j, k);
      }
    }
  }
  return inside ? best : -best;
}

double LatticeBoundary::signed_distance(const Vec3& p) const {
  return signed_distance_excluding(p, -1, -1);
}

double LatticeBoundary::signed_distance_excluding(const Vec3& p,
                                                  int exclude_face_a,
                                                  int exclude_face_b) const {
  auto excluded = [exclude_face_a, exclude_face_b](int face) {
    return face >= 0 && (face == exclude_face_a || face == exclude_face_b);
  };
  double d = 1e30;
  for (const Plane& pl : planes_) {
    if (excluded(pl.face)) continue;
    d = std::min(d, -vdot(vsub(p, pl.point), pl.unit_outward));
  }
  if (voxel_grid_) d = std::min(d, voxel_distance(p));
  for (std::size_t i = 0; i < keep_outs_.size(); ++i) {
    if (excluded(keep_out_face_[i])) continue;
    d = std::min(d, -keep_out_signed_distance(keep_outs_[i], p));
  }
  return d;
}

int LatticeBoundary::nearest_face(const Vec3& p) const {
  double best = 1e30;
  int face = -1;
  for (const Plane& pl : planes_) {
    const double d = -vdot(vsub(p, pl.point), pl.unit_outward);
    if (d < best) {
      best = d;
      face = pl.face;
    }
  }
  if (voxel_grid_) {
    const double d = voxel_distance(p);
    if (d < best) {
      best = d;
      face = -1;  // the voxel base owns no analytic face
    }
  }
  for (std::size_t i = 0; i < keep_outs_.size(); ++i) {
    const double d = -keep_out_signed_distance(keep_outs_[i], p);
    if (d < best) {
      best = d;
      face = keep_out_face_[i];
    }
  }
  return face;
}

bool LatticeBoundary::in_keep_out(const Vec3& p, double tol) const {
  for (const ClearanceGeometry& g : keep_outs_)
    if (point_in_clearance_region(g, p, tol)) return true;
  return false;
}

bool LatticeBoundary::cell_may_overlap(const Vec3& cell_min, double cell_mm) const {
  const Vec3 c{cell_min.x + 0.5 * cell_mm, cell_min.y + 0.5 * cell_mm,
               cell_min.z + 0.5 * cell_mm};
  const double half_diag = 0.5 * cell_mm * std::sqrt(3.0);
  // Lipschitz: sd(centre) <= -half_diag PROVES every point of the cell is
  // outside the allowed region. Anything else may overlap.
  return signed_distance(c) > -half_diag;
}

std::vector<LatticeClipSpan> LatticeBoundary::clip_segment(
    const Vec3& a, const Vec3& b, double erosion, int exclude_face_a,
    int exclude_face_b, long long* uncertified_dropped) const {
  std::vector<LatticeClipSpan> spans;
  const Vec3 ab = vsub(b, a);
  const double len = vnorm(ab);
  if (!(len > 0.0)) return spans;
  const Vec3 dir = vscale(ab, 1.0 / len);
  auto f = [&](double t) {
    return signed_distance_excluding(vadd(a, vscale(dir, t)), exclude_face_a,
                                     exclude_face_b) -
           erosion;
  };

  // Certified midpoint refinement on an explicit stack, processed in ascending-
  // t order so spans come out sorted and merging is a single pass. f is
  // 1-Lipschitz in t, so:
  //   min(f0, f1) >= (t1-t0)/2  proves f >= 0 on [t0, t1]  (keep, certified)
  //   max(f0, f1) <= -(t1-t0)/2 proves f <= 0 on [t0, t1]  (drop, certified)
  // At the tolerance floor an undecided sliver is DROPPED (conservative: the
  // part never grows) and counted.
  struct Node {
    double t0, t1, f0, f1;
  };
  std::vector<Node> stack;
  stack.push_back({0.0, len, f(0.0), f(len)});
  auto emit = [&spans](double t0, double t1) {
    if (!spans.empty() && std::fabs(spans.back().t1 - t0) < 1e-12)
      spans.back().t1 = t1;  // merge adjacent certified spans
    else
      spans.push_back({t0, t1});
  };
  while (!stack.empty()) {
    // Process the node with the smallest t0 (stack is LIFO; we push the right
    // half first so the left half is on top — ascending order overall).
    Node n = stack.back();
    stack.pop_back();
    const double half = 0.5 * (n.t1 - n.t0);
    if (std::min(n.f0, n.f1) >= half) {
      emit(n.t0, n.t1);
      continue;
    }
    if (std::max(n.f0, n.f1) <= -half) continue;
    if (n.t1 - n.t0 <= kClipTolMm) {
      if (uncertified_dropped) ++(*uncertified_dropped);
      continue;  // undecided sliver: conservative drop
    }
    const double tm = 0.5 * (n.t0 + n.t1);
    const double fm = f(tm);
    stack.push_back({tm, n.t1, fm, n.f1});  // right half (processed later)
    stack.push_back({n.t0, tm, n.f0, fm});  // left half (processed next)
  }
  return spans;
}

std::vector<char> lattice_certification_mask(const LatticeBoundary& boundary,
                                             const VoxelGrid& grid,
                                             const std::vector<double>& density,
                                             double iso, const Vec3& region_origin,
                                             double cell_mm) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument("lattice_certification_mask: size mismatch");
  if (!(cell_mm > 0.0))
    throw std::invalid_argument("lattice_certification_mask: cell_mm must be > 0");
  std::vector<char> mask(grid.voxel_count(), 0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!(density[e] >= iso)) continue;  // only printed voxels
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        if (boundary.in_keep_out(c, 0.0)) continue;  // protected feature
        // Owning lattice cell — the SAME activation the generator uses.
        const int ci = static_cast<int>(std::floor((c.x - region_origin.x) / cell_mm));
        const int cj = static_cast<int>(std::floor((c.y - region_origin.y) / cell_mm));
        const int ck = static_cast<int>(std::floor((c.z - region_origin.z) / cell_mm));
        const Vec3 cell_min{region_origin.x + ci * cell_mm,
                            region_origin.y + cj * cell_mm,
                            region_origin.z + ck * cell_mm};
        if (!boundary.cell_may_overlap(cell_min, cell_mm)) continue;
        mask[e] = 1;
      }
  return mask;
}

}  // namespace topopt
