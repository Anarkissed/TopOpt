// Lattice layout, stage B: where lattice goes. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
#include <thread>
#include <atomic>
#include <limits>
#include <utility>

#include "topopt/stepped_plan.hpp"  // include_wins_plane_tie

namespace topopt::lattice_layout {
namespace {
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double segment_distance2(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 ab = sub(b, a), ap = sub(p, a);
  const double l2 = dot(ab, ab);
  double t = l2 > 0.0 ? dot(ap, ab) / l2 : 0.0;
  t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
  const Vec3 d{ap.x - ab.x * t, ap.y - ab.y * t, ap.z - ab.z * t};
  return dot(d, d);
}
}  // namespace

double region_edge_distance(const Region& r, const Vec3& p) {
  const ClearanceGeometry& g = r.prism;
  if (r.is_shell() || !g.valid || g.mask || g.kind != ClearanceKind::Face)
    return std::numeric_limits<double>::infinity();
  const Vec3 rel = sub(p, g.origin);
  const double du = dot(rel, g.u), dw = dot(rel, g.w);
  const double edge = g.outline_uv.empty()
      ? std::min(std::min(du - g.u_lo, g.u_hi - du), std::min(dw - g.w_lo, g.w_hi - dw))
      : clearance_outline_signed_distance(g, du, dw);
  return edge + r.expand_mm;
}

bool region_contains(const Region& r, const Vec3& p) {
  if (r.is_shell()) return false;  // a shell is answered by the probe (it needs a distance)
  const ClearanceGeometry& g = r.prism;
  // Expand 0 is exactly the face: the predicate core already uses, not a second one.
  if (r.expand_mm == 0.0 || !g.valid || g.mask || g.kind != ClearanceKind::Face)
    return point_in_clearance_region(g, p, 0.0);
  // Rule D11. The depth is untouched; only the in-plane edge moves, by expand_mm.
  const Vec3 rel = sub(p, g.origin);
  const double s = dot(rel, g.normal);
  if (s < 0.0 || s > g.depth) return false;
  const double du = dot(rel, g.u), dw = dot(rel, g.w);
  double edge;  // in-plane distance to the outline, positive inside
  if (g.outline_uv.empty())
    edge = std::min(std::min(du - g.u_lo, g.u_hi - du), std::min(dw - g.w_lo, g.w_hi - dw));
  else
    edge = clearance_outline_signed_distance(g, du, dw);
  return edge >= -r.expand_mm;
}

Domain::Domain(const PartMeasure& measure, DomainSpec spec)
    : measure_(&measure), spec_(std::move(spec)) {
  // Rule D13: the caller's order is not an input.
  std::stable_sort(spec_.regions.begin(), spec_.regions.end(),
                   [](const Region& a, const Region& b) { return a.id < b.id; });
  std::stable_sort(spec_.protect.begin(), spec_.protect.end(),
                   [](const ProtectSkin& a, const ProtectSkin& b) { return a.id < b.id; });
  for (const ProtectSkin& s : spec_.protect) near_skin_.emplace_back(s.face, protect_depth_mm(s));
  for (const Region& r : spec_.regions) near_shell_.emplace_back(r.shell, r.shell_depth_mm);
  sure_.resize(spec_.regions.size());
  for (std::size_t i = 0; i < spec_.regions.size(); ++i) {
    const Region& r = spec_.regions[i];
    const ClearanceGeometry& g = r.prism;
    // Only where measuring to the edge is the costly part: a face's own outline.
    if (r.is_shell() || !g.valid || g.mask || g.kind != ClearanceKind::Face || g.outline_uv.empty())
      continue;
    Sure& s = sure_[i];
    const double grow = std::max(0.0, r.expand_mm) + 1.0;
    s.u0 = g.u_lo - grow;
    s.w0 = g.w_lo - grow;
    s.nu = static_cast<int>(std::ceil((g.u_hi - g.u_lo + 2 * grow) / s.pitch));
    s.nw = static_cast<int>(std::ceil((g.w_hi - g.w_lo + 2 * grow) / s.pitch));
    s.side.assign(static_cast<std::size_t>(std::max(0, s.nu)) * std::max(0, s.nw), 0);
    const double margin = 0.5 * std::sqrt(2.0) * s.pitch + 1e-6;
    std::atomic<int> next{0};
    auto rows = [&]() {
      for (int j = next.fetch_add(1); j < s.nw; j = next.fetch_add(1))
        for (int a = 0; a < s.nu; ++a) {
          const double du = s.u0 + (a + 0.5) * s.pitch, dw = s.w0 + (j + 0.5) * s.pitch;
          const double d = clearance_outline_signed_distance(g, du, dw) + r.expand_mm;
          s.side[static_cast<std::size_t>(j) * s.nu + a] = d > margin ? 1 : (d < -margin ? -1 : 0);
        }
    };
    std::vector<std::thread> pool;
    const int nt = std::min(s.nw, std::max(1, static_cast<int>(std::thread::hardware_concurrency())));
    for (int t = 1; t < nt; ++t) pool.emplace_back(rows);
    rows();
    for (std::thread& t : pool) t.join();
  }
}

bool Domain::region_holds(std::size_t i, const Vec3& p) const {
  const Region& r = spec_.regions[i];
  const Sure& sure = sure_[i];
  if (sure.side.empty()) return region_contains(r, p);
  const ClearanceGeometry& g = r.prism;
  const Vec3 rel = sub(p, g.origin);
  const double s = dot(rel, g.normal);
  if (s < 0.0 || s > g.depth) return false;        // as both paths of region_contains do
  const double du = dot(rel, g.u), dw = dot(rel, g.w);
  const int side = sure.at(du, dw);
  if (side < 0) return false;
  if (side > 0)   // inside the outline for certain; at Expand 0 also the face's own rectangle
    return r.expand_mm != 0.0 ||
           (du >= g.u_lo && du <= g.u_hi && dw >= g.w_lo && dw <= g.w_hi);
  return region_contains(r, p);
}

Domain::Near::Near(const TriangleMesh& surface, double within_mm) {
  if (surface.triangles.empty()) return;
  const double r = std::max(0.0, within_mm) * (1.0 + 1e-9) + 1e-9;
  double mn[3] = {1e300, 1e300, 1e300}, mx[3] = {-1e300, -1e300, -1e300};
  auto co = [](const Vec3& v, int a) { return a == 0 ? v.x : a == 1 ? v.y : v.z; };
  for (const auto& t : surface.triangles)
    for (int k = 0; k < 3; ++k)
      for (int a = 0; a < 3; ++a) {
        const double x = co(surface.vertices[static_cast<std::size_t>(t[k])], a);
        mn[a] = std::min(mn[a], x); mx[a] = std::max(mx[a], x);
      }
  lo = Vec3{mn[0] - r, mn[1] - r, mn[2] - r};
  const double ext[3] = {mx[0] - mn[0] + 2 * r, mx[1] - mn[1] + 2 * r, mx[2] - mn[2] + 2 * r};
  cell = std::max(std::max(ext[0], std::max(ext[1], ext[2])) / 64.0, 1e-3);
  for (int a = 0; a < 3; ++a) n[a] = std::max(1, static_cast<int>(std::ceil(ext[a] / cell)));
  on.assign(static_cast<std::size_t>(n[0]) * n[1] * n[2], 0);
  const double l[3] = {lo.x, lo.y, lo.z};
  for (const auto& t : surface.triangles) {
    int a0[3], a1[3];
    for (int a = 0; a < 3; ++a) {
      double tmn = 1e300, tmx = -1e300;
      for (int k = 0; k < 3; ++k) {
        const double x = co(surface.vertices[static_cast<std::size_t>(t[k])], a);
        tmn = std::min(tmn, x); tmx = std::max(tmx, x);
      }
      a0[a] = std::clamp(static_cast<int>(std::floor((tmn - r - l[a]) / cell)), 0, n[a] - 1);
      a1[a] = std::clamp(static_cast<int>(std::floor((tmx + r - l[a]) / cell)), 0, n[a] - 1);
    }
    for (int z = a0[2]; z <= a1[2]; ++z)
      for (int y = a0[1]; y <= a1[1]; ++y)
        for (int x = a0[0]; x <= a1[0]; ++x)
          on[(static_cast<std::size_t>(z) * n[1] + y) * n[0] + x] = 1;
  }
}

Domain::Probe::Probe(const Domain& d) : d_(&d), part_(d.measure_->probe()) {
  skins_.reserve(d.spec_.protect.size());
  for (const ProtectSkin& s : d.spec_.protect) skins_.emplace_back(s.face);
  shells_.reserve(d.spec_.regions.size());
  for (const Region& r : d.spec_.regions) shells_.emplace_back(r.shell);
}

double Domain::Probe::skin_gap(const Vec3& p) const {
  double g = std::numeric_limits<double>::infinity();
  for (std::size_t i = 0; i < skins_.size(); ++i)
    g = std::min(g, skins_[i].unsigned_distance(p) - d_->protect_depth_mm(d_->spec_.protect[i]));
  // Finish Covered is a skin on every face of the part.
  const double cover = d_->cover_depth_mm();
  if (cover > 0.0) g = std::min(g, part_.depth_up_to(p, cover + 2.0) - cover);
  return g;
}

// Walk by the gap itself: a step of that length cannot reach a skin, and a skin met
// square-on is landed on exactly by the first step. Running along one a hair away
// would crawl, so a step is never under 0.05 mm; a start it then oversteps is found
// again by halving (as PartMeasure::reach does at the part's surface).
double Domain::Probe::skin_ahead(const Vec3& p, const Vec3& dir, double limit) const {
  if ((skins_.empty() && !(d_->cover_depth_mm() > 0.0)) || !(limit > 0.0)) return -1.0;
  const double kMinStep = 0.05, kOn = 1e-7;   // mm
  auto gap_at = [&](double t) {
    return skin_gap(Vec3{p.x + dir.x * t, p.y + dir.y * t, p.z + dir.z * t});
  };
  double t = 0.0, g = gap_at(0.0);
  while (true) {
    if (g <= kOn) return t;
    if (t >= limit) return -1.0;
    const double prev = t;
    t = std::min(limit, t + std::max(g, kMinStep));
    g = gap_at(t);
    if (g >= -kOn) continue;
    double out = prev, in = t;   // clear of the skin at `out`, inside it at `in`
    for (int k = 0; k < 30 && in - out > 1e-7; ++k) {
      const double m = 0.5 * (in + out);
      if (gap_at(m) > 0.0) out = m; else in = m;
    }
    return 0.5 * (in + out);
  }
}

Where Domain::Probe::where(const Vec3& p, double* wall_mm, Room* room) const {
  const DomainSpec& spec = d_->spec_;
  // D2: a prism only turns existing solid into lattice.
  // A point ON the surface (within a nanometre) is not inside: a width measured from it
  // has nowhere to start, and the distance there is rounding, not geometry.
  // Outside comes first in MEANING: every answer below is given only for a point inside
  // the part. It is READ where that is cheapest: under a flat region whose wall is wanted
  // too, the line that reads the wall says whether the point is inside.
  auto inside_or = [&](Where inside) { return part_.inside(p) ? inside : Where{Why::Outside, 0}; };

  // D5, D15: a Protect skin is solid to its exact depth, measured from the face itself,
  // whatever else covers the point. The lattice starts right behind it.
  for (std::size_t i = 0; i < spec.protect.size(); ++i)
    if (d_->near_skin_[i].maybe(p) &&
        skins_[i].unsigned_distance(p) <= d_->protect_depth_mm(spec.protect[i]))
      return inside_or({Why::ProtectSkin, spec.protect[i].id});

  // In the region? For a prism also how far the point is from the face plane; for a
  // shell, from the face itself.
  auto holds_at = [&](std::size_t i, const Vec3& p, double* dist) {
    const Region& r = spec.regions[i];
    if (r.is_shell()) {
      // D20: the surface carried inward along its own normals, to its own outline.
      if (!d_->near_shell_[i].maybe(p)) return false;   // farther than its depth
      const double d = shells_[i].unsigned_distance(p);
      if (dist) *dist = d;
      if (d > r.shell_depth_mm) return false;
      if (r.shell_edge.empty()) return true;          // a closed surface has no outline
      double e2 = std::numeric_limits<double>::infinity();
      for (const auto& seg : r.shell_edge) e2 = std::min(e2, segment_distance2(p, seg[0], seg[1]));
      // The nearest point of the surface is inside its outline exactly when the surface
      // is nearer than its border. How far inside, along the surface: the other leg.
      const double along2 = e2 - d * d;
      if (!(along2 > 1e-12)) return false;
      return r.expand_mm >= 0.0 || along2 >= r.expand_mm * r.expand_mm;
    }
    if (!d_->region_holds(i, p)) return false;
    if (dist) {
      const Vec3& n = r.prism.normal;
      const double ln = std::sqrt(dot(n, n));
      *dist = ln > 0.0 ? std::fabs(dot(sub(p, r.prism.origin), n) / ln)
                       : std::numeric_limits<double>::infinity();
    }
    return true;
  };

  auto holds = [&](std::size_t i, double* dist) { return holds_at(i, p, dist); };

  // D6: No lattice beats Lattice.
  for (std::size_t i = 0; i < spec.regions.size(); ++i)
    if (spec.regions[i].role == Role::NoLattice && holds(i, nullptr))
      return inside_or({Why::NoLattice, spec.regions[i].id});

  // D6: among the Lattice regions that hold the point, the nearer face owns it; on one
  // face plane the deeper; then the lower id (include_wins_plane_tie, as core rules today).
  const Region* owner = nullptr;
  double best = 0.0;
  for (std::size_t i = 0; i < spec.regions.size(); ++i) {
    const Region& r = spec.regions[i];
    double d = 0.0;
    if (r.role != Role::Lattice || !holds(i, &d)) continue;
    bool wins = !owner || d < best;
    if (!wins && d == best)   // regions are in id order, so a shell tie keeps the lower id
      wins = !r.is_shell() && !owner->is_shell() &&
             include_wins_plane_tie(r.prism, r.id, owner->prism, owner->id);
    if (wins) {
      owner = &r;
      best = d;
    }
  }
  if (!owner && spec.start != Start::AllLattice) return inside_or({Why::NotAsked, 0});   // D12
  const int id = owner ? owner->id : 0;                                       // D4
  const bool flat = owner && !owner->is_shell();
  const bool wall_wanted = spec.min_wall_mm > 0.0 || wall_mm || room;
  double on_m = 0.0, back_m = 0.0;
  if (flat && wall_wanted) {
    const Vec3& n = owner->prism.normal;
    if (!part_.inside_along(p, n, &on_m)) return {Why::Outside, 0};
    back_m = part_.reach_in(p, Vec3{-n.x, -n.y, -n.z});
  } else if (!part_.inside(p)) {
    return {Why::Outside, 0};
  }

  // S1, S2, S10: the rim. Within its width of the owning region's own edge, where the
  // part's solid backs that edge: one step beyond the nearest point of the edge, at the
  // same depth, there is material, and it is no Lattice region's (a seam).
  const double rim = d_->rim_width_mm();
  if (rim > 0.0 && owner && !owner->is_shell()) {
    const double e = region_edge_distance(*owner, p);
    if (e < rim) {
      const ClearanceGeometry& g = owner->prism;
      const double h = 0.01;
      const double du = region_edge_distance(*owner, Vec3{p.x + g.u.x * h, p.y + g.u.y * h, p.z + g.u.z * h}) -
                        region_edge_distance(*owner, Vec3{p.x - g.u.x * h, p.y - g.u.y * h, p.z - g.u.z * h});
      const double dw = region_edge_distance(*owner, Vec3{p.x + g.w.x * h, p.y + g.w.y * h, p.z + g.w.z * h}) -
                        region_edge_distance(*owner, Vec3{p.x - g.w.x * h, p.y - g.w.y * h, p.z - g.w.z * h});
      const double l = std::sqrt(du * du + dw * dw);
      if (l > 0.0) {
        // Toward the edge and one step past it.
        const double go = e + std::max(0.2, 0.5 * rim);
        const Vec3 out{p.x - (g.u.x * du + g.w.x * dw) / l * go, p.y - (g.u.y * du + g.w.y * dw) / l * go,
                       p.z - (g.u.z * du + g.w.z * dw) / l * go};
        if (part_.inside(out)) {
          bool seam = false;
          for (std::size_t i = 0; i < spec.regions.size() && !seam; ++i)
            seam = spec.regions[i].role == Role::Lattice && holds_at(i, out, nullptr);
          if (!seam) return {Why::Rim, id};
        }
      }
    }
  }

  // D8: lattice was asked for here; can the wall hold it?
  // S9: Finish Covered. Lattice within the cover's thickness of the part's surface is
  // the solid shell instead.
  const double cover = d_->cover_depth_mm();
  if (cover > 0.0 && part_.depth_up_to(p, cover * (1.0 + 1e-9) + 1e-9) <= cover) return {Why::Cover, id};

  if (wall_wanted) {
    double wall = 0.0;
    if (flat) {   // the wall's width along the region's direction (PartMeasure::wall_width)
      wall = on_m + back_m;
    } else {
      // A caller that wants the width gets it; one that only needs "can this wall hold
      // lattice?" (D8) lets the measure stop as soon as no line through here is shorter.
      wall = wall_mm ? part_.thickness_in(p) : part_.thickness_in(p, spec.min_wall_mm);
    }
    if (wall_mm) *wall_mm = wall;
    double holds_mm = wall;   // the width lattice can use: the wall less its Protect skins
    if (flat && (!skins_.empty() || cover > 0.0)) {
      // Only within the region's own slab: `best` is how far `p` is below its face.
      const Vec3& n = owner->prism.normal;
      const Vec3 toward{-n.x, -n.y, -n.z};
      Room r;
      r.back = skin_ahead(p, toward, std::min(back_m, best + 1e-3));
      r.on = skin_ahead(p, n, std::min(on_m, owner->prism.depth - best + 1e-3));
      r.skin_back = r.back >= 0.0;
      r.skin_on = r.on >= 0.0;
      holds_mm = (r.skin_back ? r.back : back_m) + (r.skin_on ? r.on : on_m);
      if (room) *room = r;
    }
    if (room && flat) {
      room->part_back = back_m;
      room->part_on = on_m;
    }
    if (spec.min_wall_mm > 0.0 && holds_mm < spec.min_wall_mm) return {Why::WallTooThin, id};
  }
  return {Why::Lattice, id};
}

}  // namespace topopt::lattice_layout
