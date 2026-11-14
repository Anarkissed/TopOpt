// Lattice layout, stage B: the region under a face, from the face. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <utility>

namespace topopt::lattice_layout {
namespace {
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
}  // namespace

TriangleMesh faces_mesh(const StepModel& model, const std::vector<int>& face_ids) {
  std::vector<int> want(face_ids);
  std::sort(want.begin(), want.end());
  MeshSink sink;
  for (std::size_t t = 0; t < model.mesh.triangles.size() && t < model.triangle_face.size(); ++t) {
    if (!std::binary_search(want.begin(), want.end(), model.triangle_face[t])) continue;
    const auto& tri = model.mesh.triangles[t];
    sink.add_triangle(model.mesh.vertices[tri[0]], model.mesh.vertices[tri[1]],
                      model.mesh.vertices[tri[2]]);
  }
  return sink.mesh;
}

Region region_from_faces(const StepModel& model, const std::vector<int>& face_ids, int id,
                         Role role, double depth_mm, double expand_mm, bool* ok) {
  Region r;
  r.id = id;
  r.role = role;
  r.expand_mm = expand_mm;
  if (ok) *ok = false;
  if (!(depth_mm > 0.0)) return r;
  std::vector<int> ids;
  for (int f : face_ids)
    if (f >= 0 && f < model.face_count) ids.push_back(f);
  std::sort(ids.begin(), ids.end());
  ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
  if (ids.empty()) return r;
  TriangleMesh face = faces_mesh(model, ids);
  if (face.triangles.empty()) return r;

  // One flat face? Every listed face a plane, facing the same way, in the same plane.
  const StepFaceInfo& info = model.faces[static_cast<std::size_t>(ids[0])];
  const Vec3 out = info.plane_normal;
  bool flat = info.kind == StepSurfaceKind::Plane && dot(out, out) > 0.25;
  for (std::size_t i = 1; flat && i < ids.size(); ++i) {
    const StepFaceInfo& o = model.faces[static_cast<std::size_t>(ids[i])];
    flat = o.kind == StepSurfaceKind::Plane &&
           dot(o.plane_normal, out) >= (1.0 - 1e-9) * std::sqrt(dot(out, out) * dot(o.plane_normal, o.plane_normal)) &&
           std::fabs(dot(sub(o.plane_origin, info.plane_origin), out)) <= 1e-4 * std::sqrt(dot(out, out));
  }
  if (!flat) {
    // Rule D20. The outline of the surface: its edges used by one triangle only, so an
    // edge two listed faces share is inside the region, not on its border.
    struct K3 {
      long long x, y, z;
      bool operator<(const K3& o) const { return x != o.x ? x < o.x : y != o.y ? y < o.y : z < o.z; }
    };
    auto k3 = [](const Vec3& v) { return K3{std::llround(v.x * 1e5), std::llround(v.y * 1e5), std::llround(v.z * 1e5)}; };
    std::map<std::pair<K3, K3>, std::pair<int, std::array<Vec3, 2>>> edges;
    for (const auto& t : face.triangles)
      for (int c = 0; c < 3; ++c) {
        const Vec3& va = face.vertices[t[c]];
        const Vec3& vb = face.vertices[t[(c + 1) % 3]];
        const K3 ka = k3(va), kb = k3(vb);
        if (!(ka < kb) && !(kb < ka)) continue;
        auto& e = edges[ka < kb ? std::make_pair(ka, kb) : std::make_pair(kb, ka)];
        ++e.first;
        e.second = {va, vb};
      }
    for (const auto& kv : edges)
      if (kv.second.first == 1) r.shell_edge.push_back(kv.second.second);
    r.shell = std::move(face);
    r.shell_depth_mm = depth_mm;
    if (expand_mm > 0.0) {
      r.expand_mm = 0.0;
      r.expand_ignored = true;
    }
    if (ok) *ok = true;
    return r;
  }

  // A flat face: a prism INTO the material. The frame comes from the same resolver every
  // other prism uses, so there is one convention for (u, w).
  ManualClearanceGeometry m;
  m.kind = ClearanceKind::Face;
  m.origin = info.plane_origin;
  m.normal = Vec3{-out.x, -out.y, -out.z};
  m.half_u_mm = m.half_w_mm = 1.0;   // replaced below by the face's own extent
  ClearanceParams params;
  params.kind = ClearanceKind::Face;
  params.slab_depth_mm = depth_mm;
  ClearanceGeometry g = resolve_clearance_manual(m, params);
  if (!g.valid) return r;

  // Rule D10: the face's true outline. An edge of the face's triangles used by one
  // triangle only is on the outline; chained end to end they are its loops (holes too).
  struct Key {
    long long a, b;
    bool operator<(const Key& o) const { return a != o.a ? a < o.a : b < o.b; }
  };
  std::vector<std::array<double, 2>> uv(face.vertices.size());
  std::vector<Key> key(face.vertices.size());
  double u_lo = 1e300, u_hi = -1e300, w_lo = 1e300, w_hi = -1e300;
  for (std::size_t i = 0; i < face.vertices.size(); ++i) {
    const Vec3 rel = sub(face.vertices[i], g.origin);
    uv[i] = {dot(rel, g.u), dot(rel, g.w)};
    key[i] = {std::llround(uv[i][0] * 1e5), std::llround(uv[i][1] * 1e5)};
    u_lo = std::min(u_lo, uv[i][0]); u_hi = std::max(u_hi, uv[i][0]);
    w_lo = std::min(w_lo, uv[i][1]); w_hi = std::max(w_hi, uv[i][1]);
  }
  std::map<std::pair<Key, Key>, int> count;          // undirected edge -> uses
  std::map<Key, std::array<double, 2>> point;
  for (const auto& t : face.triangles)
    for (int c = 0; c < 3; ++c) {
      const Key a = key[t[c]], b = key[t[(c + 1) % 3]];
      point[a] = uv[t[c]];
      if (!(a < b) && !(b < a)) continue;
      ++count[a < b ? std::make_pair(a, b) : std::make_pair(b, a)];
    }
  std::multimap<Key, Key> next;                       // outline edges, both ways
  for (const auto& kv : count)
    if (kv.second == 1) {
      next.emplace(kv.first.first, kv.first.second);
      next.emplace(kv.first.second, kv.first.first);
    }
  auto take = [&](const Key& a, const Key& b) {       // remove edge a-b in both directions
    for (int pass = 0; pass < 2; ++pass) {
      const Key& x = pass ? b : a;
      const Key& y = pass ? a : b;
      auto range = next.equal_range(x);
      for (auto it = range.first; it != range.second; ++it)
        if (!(it->second < y) && !(y < it->second)) { next.erase(it); break; }
    }
  };
  while (!next.empty()) {
    std::vector<std::array<double, 2>> loop;
    const Key start = next.begin()->first;
    Key at = start;
    for (;;) {
      auto it = next.find(at);
      if (it == next.end()) break;
      const Key to = it->second;
      loop.push_back(point[at]);
      take(at, to);
      at = to;
      if (!(at < start) && !(start < at)) break;
    }
    if (loop.size() >= 3) g.outline_uv.push_back(std::move(loop));
  }
  if (g.outline_uv.empty()) return r;
  g.outline_frame = 0;   // the loops are already in (u, w)
  g.u_lo = u_lo; g.u_hi = u_hi; g.w_lo = w_lo; g.w_hi = w_hi;
  g.declared_region_id = id;
  r.prism = std::move(g);
  if (ok) *ok = true;
  return r;
}

// Rule D21: a zone is a flat region whose prism is stated, not read off a face.
Region region_from_zone(const Zone& zone, int id, Role role, double expand_mm, bool* ok) {
  Region r;
  r.id = id;
  r.role = role;
  r.expand_mm = expand_mm;
  if (ok) *ok = false;
  auto finite = [](const Vec3& v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); };
  auto unit = [](const Vec3& v) { return std::fabs(std::sqrt(dot(v, v)) - 1.0) <= 1e-6; };
  if (!finite(zone.centre)) return r;
  const Vec3& n = zone.axis[2];
  const double half_depth = zone.half[2];
  if (!finite(n) || !unit(n) || !std::isfinite(half_depth) || !(half_depth > 0.0)) return r;
  const Vec3 start{zone.centre.x - n.x * half_depth, zone.centre.y - n.y * half_depth,
                   zone.centre.z - n.z * half_depth};
  ClearanceGeometry g;
  if (zone.kind == Zone::Kind::Box) {
    for (int a = 0; a < 2; ++a)
      if (!finite(zone.axis[a]) || !unit(zone.axis[a]) || !std::isfinite(zone.half[a]) || !(zone.half[a] > 0.0))
        return r;
    if (std::fabs(dot(zone.axis[0], zone.axis[1])) > 1e-6 || std::fabs(dot(zone.axis[0], n)) > 1e-6 ||
        std::fabs(dot(zone.axis[1], n)) > 1e-6)
      return r;
    // The box's own axes are the prism's in-plane axes. The predicate reads (u, w) as given;
    // the manual resolver would refuse them (frame_conflict) wherever they are not plane_basis's.
    const double h0 = zone.half[0], h1 = zone.half[1];
    g.kind = ClearanceKind::Face;
    g.origin = start;
    g.normal = n;
    g.u = zone.axis[0];
    g.w = zone.axis[1];
    g.depth = 2.0 * half_depth;
    g.u_lo = -h0; g.u_hi = h0; g.w_lo = -h1; g.w_hi = h1;
    g.outline_uv = {{{-h0, -h1}, {h0, -h1}, {h0, h1}, {-h0, h1}}};
    g.valid = true;
  } else if (zone.kind == Zone::Kind::Cylinder) {
    const double radius = zone.half[0];
    if (!std::isfinite(radius) || !(radius > 0.0)) return r;
    ManualClearanceGeometry m;
    m.kind = ClearanceKind::Face;
    m.origin = start;
    m.normal = n;
    m.half_u_mm = m.half_w_mm = radius;   // replaced below by the loop's own extent
    ClearanceParams params;
    params.kind = ClearanceKind::Face;
    params.slab_depth_mm = 2.0 * half_depth;
    g = resolve_clearance_manual(m, params);
    if (!g.valid) return r;
    // 96 equal sides, corners on a circle of radius R with (96/2) R^2 sin(2 pi / 96) = pi r^2:
    // the loop's area is the circle's, so it is neither inside nor outside it.
    constexpr int kSides = 96;
    const double pi = 3.14159265358979323846;
    const double corner = radius * std::sqrt(2.0 * pi / (kSides * std::sin(2.0 * pi / kSides)));
    std::vector<std::array<double, 2>> loop;
    for (int k = 0; k < kSides; ++k) {
      const double t = 2.0 * pi * k / kSides;
      loop.push_back({corner * std::cos(t), corner * std::sin(t)});
    }
    g.outline_uv = {std::move(loop)};
    g.u_lo = g.w_lo = -corner;
    g.u_hi = g.w_hi = corner;
  } else {
    return r;
  }
  g.outline_frame = 0;   // the loops are in (u, w)
  g.declared_region_id = id;
  r.prism = std::move(g);
  if (ok) *ok = true;
  return r;
}

}  // namespace topopt::lattice_layout
