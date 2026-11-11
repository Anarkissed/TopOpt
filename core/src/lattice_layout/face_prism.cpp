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

Region region_from_face(const StepModel& model, int face_id, int id, Role role,
                        double depth_mm, double expand_mm, bool* ok) {
  Region r;
  r.id = id;
  r.role = role;
  r.expand_mm = expand_mm;
  if (ok) *ok = false;
  if (face_id < 0 || face_id >= model.face_count || !(depth_mm > 0.0)) return r;
  TriangleMesh face = faces_mesh(model, {face_id});
  if (face.triangles.empty()) return r;

  const StepFaceInfo& info = model.faces[static_cast<std::size_t>(face_id)];
  const Vec3 out = info.plane_normal;
  if (info.kind != StepSurfaceKind::Plane || dot(out, out) < 0.25) {
    // A curved face: everything within the depth of the face itself.
    r.shell = std::move(face);
    r.shell_depth_mm = depth_mm;
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

}  // namespace topopt::lattice_layout
