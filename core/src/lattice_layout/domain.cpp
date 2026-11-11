// Lattice layout, stage B: where lattice goes. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
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
}

Domain::Probe::Probe(const Domain& d) : d_(&d), part_(d.measure_->probe()) {
  skins_.reserve(d.spec_.protect.size());
  for (const ProtectSkin& s : d.spec_.protect) skins_.emplace_back(s.face);
  shells_.reserve(d.spec_.regions.size());
  for (const Region& r : d.spec_.regions) shells_.emplace_back(r.shell);
}

Where Domain::Probe::where(const Vec3& p) const {
  const DomainSpec& spec = d_->spec_;
  // D2: a prism only turns existing solid into lattice.
  if (part_.depth(p) <= 0.0) return {Why::Outside, 0};

  // D5, D15: a Protect skin is solid to its exact depth, measured from the face itself,
  // whatever else covers the point. The lattice starts right behind it.
  for (std::size_t i = 0; i < spec.protect.size(); ++i)
    if (skins_[i].unsigned_distance(p) <= d_->protect_depth_mm(spec.protect[i]))
      return {Why::ProtectSkin, spec.protect[i].id};

  // In the region? For a prism also how far the point is from the face plane; for a
  // shell, from the face itself.
  auto holds = [&](std::size_t i, double* dist) {
    const Region& r = spec.regions[i];
    if (r.is_shell()) {
      // D20: the surface carried inward along its own normals, to its own outline.
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
    if (!region_contains(r, p)) return false;
    if (dist) {
      const Vec3& n = r.prism.normal;
      const double ln = std::sqrt(dot(n, n));
      *dist = ln > 0.0 ? std::fabs(dot(sub(p, r.prism.origin), n) / ln)
                       : std::numeric_limits<double>::infinity();
    }
    return true;
  };

  // D6: No lattice beats Lattice.
  for (std::size_t i = 0; i < spec.regions.size(); ++i)
    if (spec.regions[i].role == Role::NoLattice && holds(i, nullptr))
      return {Why::NoLattice, spec.regions[i].id};

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
  if (!owner && spec.start != Start::AllLattice) return {Why::NotAsked, 0};   // D12
  const int id = owner ? owner->id : 0;                                       // D4

  // D8: lattice was asked for here; can the wall hold it?
  if (spec.min_wall_mm > 0.0) {
    const double wall = owner && !owner->is_shell() ? part_.wall_width(p, owner->prism.normal)
                                                     : part_.thickness(p);
    if (wall < spec.min_wall_mm) return {Why::WallTooThin, id};
  }
  return {Why::Lattice, id};
}

}  // namespace topopt::lattice_layout
