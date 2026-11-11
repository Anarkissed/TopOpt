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
}  // namespace

bool region_contains(const Region& r, const Vec3& p) {
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

  // D6: No lattice beats Lattice.
  for (const Region& r : spec.regions)
    if (r.role == Role::NoLattice && region_contains(r, p)) return {Why::NoLattice, r.id};

  // D6: among the Lattice prisms that hold the point, the nearer face owns it; on one
  // face plane the deeper; then the lower id (include_wins_plane_tie, as core rules today).
  const Region* owner = nullptr;
  double best = 0.0;
  for (const Region& r : spec.regions) {
    if (r.role != Role::Lattice || !region_contains(r, p)) continue;
    const Vec3& n = r.prism.normal;
    const double ln = std::sqrt(dot(n, n));
    const double d = ln > 0.0 ? std::fabs(dot(sub(p, r.prism.origin), n) / ln)
                              : std::numeric_limits<double>::infinity();
    if (!owner || d < best ||
        (d == best && include_wins_plane_tie(r.prism, r.id, owner->prism, owner->id))) {
      owner = &r;
      best = d;
    }
  }
  if (owner) return {Why::Lattice, owner->id};

  // D4 / D12.
  return spec.start == Start::AllLattice ? Where{Why::Lattice, 0} : Where{Why::NotAsked, 0};
}

}  // namespace topopt::lattice_layout
