// The lattice boundary predicate (handoff 2026-07-29-lattice-boundary-finish).
// See the header for the contract; the load-bearing property implemented here is
// that signed_distance is a 1-LIPSCHITZ LOWER BOUND on the true signed distance:
//   * each primitive term is the EXACT signed distance to its own region
//     (plane, capped cylinder, bounded slab, and the BASE — either the exported
//     shell mesh or, when no mesh was supplied, the voxel-cube union);
//   * the allowed region is base ∩ ¬(∪ keep-outs), and min() of exact terms is
//     a 1-Lipschitz lower bound for the intersection.
// Everything is closed-form arithmetic — no sampled field, no RNG, no state —
// so the predicate is deterministic and clip_segment's Lipschitz certificates
// are sound.

#include "topopt/lattice_boundary.hpp"

#include <algorithm>
#include <cmath>
#include <vector>
#include <memory>
#include <limits>
#include <stdexcept>

#include "topopt/clearance.hpp"
#include "topopt/mesh_distance.hpp"

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

// ── ★ K3 / RULING 2: THE OUTLINE'S EDGE INDEX ─────────────────────────────────
// The exact distance to a polygon is O(edges), and `clip_segment` evaluates the signed
// distance tens of times per strut: 102117B9 carries 177 include regions whose outlines
// run to tens of thousands of vertices, so a linear scan per query is not an option.
//
// A uniform grid over the outline's own (a, b) bounding box, each cell listing every
// edge whose bounding box overlaps it (a superset of the edges that pass through it,
// which is what correctness needs). A query walks Chebyshev rings outward from its own
// cell and stops as soon as the best distance found is within `ring * cell` -- every
// unscanned cell is at least that far away -- so the answer is EXACT, not approximate.
struct LatticeOutlineIndex {
  std::vector<double> ax, ay, bx, by;   // edge endpoints, flattened over every loop
  double lo_a = 0.0, lo_b = 0.0, cell = 1.0;
  int na = 1, nb = 1;
  std::vector<std::vector<int>> bucket;

  // Exact minimum distance from (a, b) to the nearest edge.
  double min_distance(double a, double b) const {
    if (ax.empty()) return std::numeric_limits<double>::infinity();
    const int qi = static_cast<int>(std::floor((a - lo_a) / cell));
    const int qj = static_cast<int>(std::floor((b - lo_b) / cell));
    double best = std::numeric_limits<double>::infinity();
    const int span = std::max(na, nb) +
                     std::max(std::abs(qi), std::abs(qj)) + 1;
    for (int ring = 0; ring <= span; ++ring) {
      // Everything outside this ring is at least `ring * cell` away, so once the best
      // beats that bound no further ring can improve it.
      if (best <= static_cast<double>(ring) * cell) break;
      for (int dj = -ring; dj <= ring; ++dj)
        for (int di = -ring; di <= ring; ++di) {
          if (std::max(std::abs(di), std::abs(dj)) != ring) continue;  // the ring only
          const int i = qi + di, j = qj + dj;
          if (i < 0 || j < 0 || i >= na || j >= nb) continue;
          for (int e : bucket[static_cast<std::size_t>(j) * na + i]) {
            const double ex = bx[e] - ax[e], ey = by[e] - ay[e];
            const double len2 = ex * ex + ey * ey;
            double t = 0.0;
            if (len2 > 0.0) {
              t = ((a - ax[e]) * ex + (b - ay[e]) * ey) / len2;
              t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
            }
            const double dx = a - (ax[e] + t * ex), dy = b - (ay[e] + t * ey);
            best = std::min(best, std::sqrt(dx * dx + dy * dy));
          }
        }
    }
    return best;
  }
};

namespace {

// ── ★ K3: ONE INCLUDE REGION'S OWN SIGNED DISTANCE, OUTLINE AND ALL ───────────
// `keep_out_signed_distance` above is the region's RECTANGLE in the face frame. Where
// the app sent `outline_uv`, the rectangle is merely its bounding box and the outline
// is the boundary the preview drew -- so the in-plane term is the exact distance to the
// outline (clearance.cpp, the same frame the containment predicate reads). Both terms
// are exact signed distances, so their min is 1-Lipschitz.
double include_signed_distance(const ClearanceGeometry& g, const Vec3& p,
                               const LatticeOutlineIndex* idx) {
  if (!g.valid) return -1e30;
  // A mask-backed include has no analytic distance; it must not clip (see the header).
  if (g.mask) return 1e30;
  if (g.kind == ClearanceKind::Bolt || g.outline_uv.empty() || idx == nullptr)
    return keep_out_signed_distance(g, p);
  const Vec3 d = vsub(p, g.origin);
  const double s = vdot(d, g.normal);
  const double ds = std::min(s - 0.0, g.depth - s);
  const double du = vdot(d, g.u), dw = vdot(d, g.w);
  double a = du, b = dw;   // the app's pair in core's (u, w): one definition, clearance.cpp
  clearance_outline_frame_uv(g, du, dw, &a, &b);
  const double dist = idx->min_distance(a, b);
  const double din = point_in_clearance_outline(g, du, dw) ? dist : -dist;
  if (ds >= 0.0 && din >= 0.0) return std::min(ds, din);
  const double os = std::max(-ds, 0.0);
  const double oi = std::max(-din, 0.0);
  return -std::sqrt(os * os + oi * oi);
}

// The certified midpoint refinement shared by both clip entry points. `f` is a
// 1-Lipschitz function of arc length t in [0, len]; kept spans PROVE f >= 0
// throughout, dropped spans prove f <= 0, and undecided slivers at the `tol`
// floor are dropped (conservative) and counted. Deterministic: fixed midpoint
// refinement, ascending-t processing, no RNG. (This is the exact loop
// clip_segment always ran, hoisted so clip_segment_relaxed_base can share it
// with a different f — same arithmetic, same order.)
template <class F>
std::vector<LatticeClipSpan> certified_clip_spans(double len, F&& f, double tol,
                                                  long long* uncertified_dropped) {
  std::vector<LatticeClipSpan> spans;
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
    if (n.t1 - n.t0 <= tol) {
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

void LatticeBoundary::set_shell_base(const TriangleMesh* shell) {
  if (!shell || shell->triangles.empty())
    throw std::invalid_argument(
        "LatticeBoundary::set_shell_base: the shell mesh is empty — a caller "
        "that means \"no shell base\" must not call this");
  shell_ = std::make_shared<const MeshDistance>(*shell);
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

void LatticeBoundary::add_include_region(const ClearanceGeometry& geom) {
  if (!geom.valid) return;  // same safe no-op as the rasterizer / add_keep_out
  includes_.push_back(geom);
  // ── ★ K3 / RULING 2: THE OUTLINE ARMS THE CLIP, AND NOTHING ELSE DOES ────────
  // Scope (b): the term exists for a job whose include carries `outline_uv`, and a job
  // with none cannot reach it. That is the byte-identity bar, enforced here rather than
  // promised somewhere else. A mask-backed include is skipped: no analytic distance.
  std::shared_ptr<const LatticeOutlineIndex> idx;
  if (!geom.outline_uv.empty() && !geom.mask &&
      geom.kind != ClearanceKind::Bolt) {
    auto built = std::make_shared<LatticeOutlineIndex>();
    double lo_a = 1e300, hi_a = -1e300, lo_b = 1e300, hi_b = -1e300;
    for (const auto& loop : geom.outline_uv) {
      const std::size_t n = loop.size();
      if (n < 3) continue;
      for (std::size_t i = 0, j = n - 1; i < n; j = i++) {
        built->ax.push_back(loop[j][0]);
        built->ay.push_back(loop[j][1]);
        built->bx.push_back(loop[i][0]);
        built->by.push_back(loop[i][1]);
        lo_a = std::min({lo_a, loop[i][0], loop[j][0]});
        hi_a = std::max({hi_a, loop[i][0], loop[j][0]});
        lo_b = std::min({lo_b, loop[i][1], loop[j][1]});
        hi_b = std::max({hi_b, loop[i][1], loop[j][1]});
      }
    }
    if (!built->ax.empty()) {
      // About sqrt(edges) cells per axis, so a cell holds a handful of edges on average
      // and the ring walk terminates in one or two rings.
      const std::size_t ne = built->ax.size();
      const int side = std::max(
          1, static_cast<int>(std::ceil(std::sqrt(static_cast<double>(ne)))));
      const double ea = std::max(hi_a - lo_a, 1e-9);
      const double eb = std::max(hi_b - lo_b, 1e-9);
      built->cell = std::max(std::max(ea, eb) / side, 1e-9);
      built->lo_a = lo_a;
      built->lo_b = lo_b;
      built->na = std::max(1, static_cast<int>(std::floor(ea / built->cell)) + 1);
      built->nb = std::max(1, static_cast<int>(std::floor(eb / built->cell)) + 1);
      built->bucket.assign(static_cast<std::size_t>(built->na) * built->nb, {});
      for (std::size_t e = 0; e < ne; ++e) {
        const int i0 = std::max(0, static_cast<int>(std::floor(
                                       (std::min(built->ax[e], built->bx[e]) - lo_a) /
                                       built->cell)));
        const int i1 = std::min(built->na - 1,
                                static_cast<int>(std::floor(
                                    (std::max(built->ax[e], built->bx[e]) - lo_a) /
                                    built->cell)));
        const int j0 = std::max(0, static_cast<int>(std::floor(
                                       (std::min(built->ay[e], built->by[e]) - lo_b) /
                                       built->cell)));
        const int j1 = std::min(built->nb - 1,
                                static_cast<int>(std::floor(
                                    (std::max(built->ay[e], built->by[e]) - lo_b) /
                                    built->cell)));
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            built->bucket[static_cast<std::size_t>(j) * built->na + i].push_back(
                static_cast<int>(e));
      }
      idx = built;
      clip_includes_ = true;
    }
  }
  include_outline_index_.push_back(idx);
}

void LatticeBoundary::add_exclude_region(const ClearanceGeometry& geom) {
  if (!geom.valid) return;
  excludes_.push_back(geom);
}

bool LatticeBoundary::in_include_region(const Vec3& p, double tol) const {
  for (const ClearanceGeometry& g : includes_)
    if (point_in_clearance_region(g, p, tol)) return true;
  return false;
}

bool LatticeBoundary::in_exclude_region(const Vec3& p, double tol) const {
  for (const ClearanceGeometry& g : excludes_)
    if (point_in_clearance_region(g, p, tol)) return true;
  return false;
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

double LatticeBoundary::sd_excluding_relaxed(const Vec3& p, int exclude_face_a,
                                             int exclude_face_b,
                                             double base_relax) const {
  auto excluded = [exclude_face_a, exclude_face_b](int face) {
    return face >= 0 && (face == exclude_face_a || face == exclude_face_b);
  };
  double d = 1e30;
  for (const Plane& pl : planes_) {
    if (excluded(pl.face)) continue;
    d = std::min(d, -vdot(vsub(p, pl.point), pl.unit_outward));
  }
  // THE BASE TERM, and there is exactly ONE of it (task 2026-08-08-strut-clip-
  // matches-shell). When a shell was supplied it SUPERSEDES the voxel-cube
  // union: the cube union is not the surface the export writes, and clipping
  // against a surface the file does not carry is what put strut ends outside
  // the shell at convex edges. Both are exact distances, hence 1-Lipschitz, so
  // the certified-clip refinement is sound either way.
  if (shell_)
    d = std::min(d, shell_->signed_distance(p) + base_relax);
  else if (voxel_grid_)
    d = std::min(d, voxel_distance(p) + base_relax);
  for (std::size_t i = 0; i < keep_outs_.size(); ++i) {
    if (excluded(keep_out_face_[i])) continue;
    d = std::min(d, -keep_out_signed_distance(keep_outs_[i], p));
  }
  // ★ K3: the include UNION as a clip term, when the run armed it. max over the
  // includes, each one's own exact signed distance -- see clip_to_include_regions.
  if (clip_includes_ && !includes_.empty()) {
    // ── ★ THE RECTANGLE BOUNDS THE OUTLINE, AND THE BOUND IS FREE ────────────────
    // The polygon is a SUBSET of its rectangle, so the rectangle's signed distance is an
    // exact UPPER BOUND on the outline's, and it is pure arithmetic. An include whose
    // bound already fails to beat the running max therefore cannot contribute, and its
    // polygon is never queried. That prune is EXACT: any include whose outline value
    // exceeds `best` has a bound that exceeds `best` too, so none is ever skipped.
    //
    // ★ WHAT IS NOT SOUND, and was tried: filtering to the includes whose bound is at
    // the TOP. The region with the highest rectangle bound can be the one the point
    // falls OUTSIDE the outline of, while a region with a slightly lower bound contains
    // it; skipping the second returns a value that is too negative, and clips struts
    // that belong. Every include is bounded, and every include whose bound beats the
    // best so far is evaluated.
    //
    // Evaluating the highest-bounded include FIRST is what makes the prune bite: it is
    // usually the one that answers, so the rest fall out on arithmetic. Measured on
    // 102117B9's own job (177 include regions, all outlined, 2586 outline vertices,
    // largest loop 75), 200k queries over their bounding box:
    //     every outline evaluated, input order ... 4.147 us
    //     highest bound first, then the prune ..... see the handoff's table
    // Scratch is thread_local and reused, so there is no allocation per query after the
    // first; ties keep declaration order, which byte-identical output needs.
    static thread_local std::vector<double> ibound;
    const std::size_t n = includes_.size();
    ibound.assign(n, -1e30);
    std::size_t hi_i = n;
    double hi = -1e30;
    for (std::size_t i = 0; i < n; ++i) {
      const ClearanceGeometry& g = includes_[i];
      if (!g.valid) continue;
      // A mask-backed include has no analytic distance and takes no clip (see the
      // header): +inf keeps it out of the max entirely.
      if (g.mask) { ibound[i] = 1e30; continue; }
      ibound[i] = keep_out_signed_distance(g, p);
      if (ibound[i] > hi) { hi = ibound[i]; hi_i = i; }
    }
    double best = -1e30;
    auto eval = [&](std::size_t i) {
      const LatticeOutlineIndex* idx =
          i < include_outline_index_.size() ? include_outline_index_[i].get() : nullptr;
      best = std::max(best, include_signed_distance(includes_[i], p, idx));
    };
    if (hi_i < n) eval(hi_i);
    for (std::size_t i = 0; i < n; ++i) {
      if (i == hi_i || ibound[i] <= best || ibound[i] > 1e29) continue;
      eval(i);
    }
    // Every include invalid, or every one mask-backed: no term, exactly as before.
    if (best > -1e29 && best < 1e29) d = std::min(d, best);
  }
  return d;
}

double LatticeBoundary::signed_distance_excluding(const Vec3& p,
                                                  int exclude_face_a,
                                                  int exclude_face_b) const {
  return sd_excluding_relaxed(p, exclude_face_a, exclude_face_b, 0.0);
}

double LatticeBoundary::signed_distance_relaxed_base(const Vec3& p,
                                                     double base_relax) const {
  return sd_excluding_relaxed(p, -1, -1, base_relax);
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
  // The base term owns no analytic face, whichever surface supplies it.
  if (shell_ || voxel_grid_) {
    const double d = shell_ ? shell_->signed_distance(p) : voxel_distance(p);
    if (d < best) {
      best = d;
      face = -1;
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
  if (signed_distance(c) <= -half_diag) return false;
  // Lattice roles (task lattice-page-core-hookup) — the same proof discipline,
  // on the SAME exact primitive distances (keep_out_signed_distance is the exact
  // signed distance to a ClearanceGeometry, positive inside):
  //   * include: when include regions exist, drop the cell only when it provably
  //     misses EVERY one (max inside-signed-distance <= -half_diag => no point
  //     of the cell is inside the union => no voxel there can certify latticed);
  //   * exclude: drop the cell only when it provably sits entirely INSIDE one
  //     (inside-signed-distance >= half_diag => every point — so every voxel
  //     centre — is inside, and the certification mask marks them all solid).
  // A cell dropped here therefore provably contains no certifiable-latticed
  // voxel; a partially-overlapping cell stays active and its solid-role voxels
  // are simply masked solid — activation and mask cannot disagree.
  //
  // ★ A MASK-BACKED REGION TAKES THE EXACT BOX TEST, NOT THE BOUND (task
  // 2026-08-15-lattice-regions §1b). A voxel set has no analytic signed
  // distance, but this function is handed the whole CELL BOX — and against a
  // voxel set the box test is exact where the Lipschitz bound is merely
  // conservative. It is therefore strictly stronger, not a weakening: a cell it
  // drops provably contains no set voxel, and a cell it keeps provably does.
  if (!includes_.empty()) {
    double best = -1e30;
    bool mask_overlap = false;
    for (const ClearanceGeometry& g : includes_) {
      if (g.valid && g.mask) {
        if (g.mask->overlaps_box(cell_min, cell_mm)) { mask_overlap = true; break; }
        continue;  // this include provably misses the cell
      }
      best = std::max(best, keep_out_signed_distance(g, c));
    }
    if (!mask_overlap && best <= -half_diag) return false;
  }
  for (const ClearanceGeometry& g : excludes_) {
    if (g.valid && g.mask) {
      if (g.mask->contains_box(cell_min, cell_mm)) return false;
      continue;
    }
    if (keep_out_signed_distance(g, c) >= half_diag) return false;
  }
  return true;
}

std::vector<LatticeClipSpan> LatticeBoundary::clip_segment(
    const Vec3& a, const Vec3& b, double erosion, int exclude_face_a,
    int exclude_face_b, long long* uncertified_dropped,
    double base_relax) const {
  std::vector<LatticeClipSpan> spans;
  const Vec3 ab = vsub(b, a);
  const double len = vnorm(ab);
  if (!(len > 0.0)) return spans;
  const Vec3 dir = vscale(ab, 1.0 / len);
  // Certified midpoint refinement (certified_clip_spans): f is 1-Lipschitz in
  // t, so min(f0, f1) >= (t1-t0)/2 proves f >= 0 on [t0, t1] (keep) and
  // max(f0, f1) <= -(t1-t0)/2 proves f <= 0 (drop); undecided slivers at the
  // tolerance floor are dropped (conservative: the part never grows) and
  // counted. base_relax relaxes the voxel term only (see the header).
  return certified_clip_spans(
      len,
      [&](double t) {
        return sd_excluding_relaxed(vadd(a, vscale(dir, t)), exclude_face_a,
                                    exclude_face_b, base_relax) -
               erosion;
      },
      kClipTolMm, uncertified_dropped);
}

std::vector<char> lattice_certification_mask_per_cell(
    const LatticeBoundary& boundary, const VoxelGrid& grid,
    const std::vector<double>& density, double iso,
    const std::function<bool(const Vec3&, Vec3*, double*)>& owning_cell,
    long long* dropped_by_overlap) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument("lattice_certification_mask_per_cell: size mismatch");
  if (!owning_cell)
    throw std::invalid_argument(
        "lattice_certification_mask_per_cell: no owning-cell provider — the caller must "
        "say which cell of the design covers each voxel; there is no default");
  std::vector<char> mask(grid.voxel_count(), 0);
  long long dropped = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (!(density[e] >= iso)) continue;  // only printed voxels
        const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                     grid.origin.y + (j + 0.5) * grid.spacing,
                     grid.origin.z + (k + 0.5) * grid.spacing};
        if (boundary.in_keep_out(c, 0.0)) continue;  // protected feature
        // Lattice roles (task lattice-page-core-hookup). PRECEDENCE: clearance
        // beat both above (keep-out first); exclude beats include here (a voxel
        // inside both stays SOLID). Skipped voxels are certified solid.
        if (boundary.in_exclude_region(c, 0.0)) continue;
        if (boundary.has_include_regions() && !boundary.in_include_region(c, 0.0))
          continue;
        // Owning lattice cell — the SAME activation the generator uses.
        Vec3 cell_min{0, 0, 0};
        double cell_mm = 0.0;
        if (!owning_cell(c, &cell_min, &cell_mm)) continue;  // no cell covers it
        if (!(cell_mm > 0.0))
          throw std::invalid_argument(
              "lattice_certification_mask_per_cell: the owning-cell provider claimed a "
              "cell covers this voxel but gave it a non-positive edge");
        if (!boundary.cell_may_overlap(cell_min, cell_mm)) {
          ++dropped;
          continue;
        }
        mask[e] = 1;
      }
  if (dropped_by_overlap != nullptr) *dropped_by_overlap = dropped;
  return mask;
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
  // ONE cell, one origin: the graded run's own grid, expressed as the per-cell
  // predicate's degenerate case so the two paths cannot disagree about anything but
  // the cell.
  return lattice_certification_mask_per_cell(
      boundary, grid, density, iso,
      [&region_origin, cell_mm](const Vec3& c, Vec3* cell_min, double* ce) {
        const int ci = static_cast<int>(std::floor((c.x - region_origin.x) / cell_mm));
        const int cj = static_cast<int>(std::floor((c.y - region_origin.y) / cell_mm));
        const int ck = static_cast<int>(std::floor((c.z - region_origin.z) / cell_mm));
        *cell_min = Vec3{region_origin.x + ci * cell_mm,
                         region_origin.y + cj * cell_mm,
                         region_origin.z + ck * cell_mm};
        *ce = cell_mm;
        return true;
      });
}

std::vector<char> lattice_synthesis_domain(const LatticeBoundary& boundary,
                                           const VoxelGrid& grid,
                                           const std::vector<double>& density,
                                           double iso, const Vec3& region_origin,
                                           double cell_mm,
                                           const std::vector<char>& posture_mask,
                                           long long* posture_rejected) {
  std::vector<char> mask = lattice_certification_mask(boundary, grid, density, iso,
                                                      region_origin, cell_mm);
  long long rejected = 0;
  if (!posture_mask.empty()) {
    if (posture_mask.size() != mask.size())
      throw std::invalid_argument("lattice_synthesis_domain: posture size mismatch");
    for (std::size_t e = 0; e < mask.size(); ++e) {
      if (mask[e] && !posture_mask[e]) mask[e] = 0;   // the law kept it solid
      else if (!mask[e] && posture_mask[e]) ++rejected;
    }
  }
  if (posture_rejected != nullptr) *posture_rejected = rejected;
  return mask;
}

}  // namespace topopt
