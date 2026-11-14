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

namespace {
// The region under a surface (`face`, not empty) made of the listed faces of the model
// (`ids`, sorted, none repeated, not empty): from here on a region of whole faces and one
// of pieces (D22) are the same code.
Region region_from_surface(const StepModel& model, const std::vector<int>& ids, TriangleMesh face, Region r,
                           double depth_mm, double expand_mm, bool* ok) {
  const int id = r.id;
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
}  // namespace

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
  return region_from_surface(model, ids, std::move(face), std::move(r), depth_mm, expand_mm, ok);
}

namespace {
// Rule D22. One convex part of a model triangle, and on which side of each cut it lies:
// +1 where (p - point) . normal >= 0 holds all over it, -1 where it fails, 0 when the part
// lies in the cut's plane.
struct CutPart {
  std::vector<Vec3> v;
  std::vector<signed char> side;
};
// The surface of the pieces, and the faces it keeps a triangle of (sorted).
TriangleMesh cut_surface(const StepModel& model, const std::vector<FacePiece>& pieces, bool* ok,
                         std::vector<int>* kept_faces) {
  if (ok) *ok = false;
  if (pieces.empty()) return {};
  const std::size_t nt = std::min(model.mesh.triangles.size(), model.triangle_face.size());
  std::vector<int> per_face(static_cast<std::size_t>(std::max(0, model.face_count)), 0);
  for (std::size_t t = 0; t < nt; ++t) {
    const int f = model.triangle_face[t];
    if (f >= 0 && f < model.face_count) ++per_face[static_cast<std::size_t>(f)];
  }
  auto finite = [](const Vec3& v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); };
  // Every cut of every piece, its normal made unit; each piece's own cuts are its numbers here.
  std::vector<Vec3> at, n;
  std::vector<bool> strict;
  std::vector<std::vector<std::size_t>> owns(pieces.size());
  std::map<int, std::vector<std::size_t>> pieces_of;   // face -> the pieces that list it
  for (std::size_t p = 0; p < pieces.size(); ++p) {
    if (pieces[p].faces.empty()) return {};
    for (int f : pieces[p].faces) {
      if (f < 0 || f >= model.face_count || per_face[static_cast<std::size_t>(f)] == 0) return {};
      std::vector<std::size_t>& list = pieces_of[f];
      if (list.empty() || list.back() != p) list.push_back(p);
    }
    for (const FaceCut& c : pieces[p].cuts) {
      const double len = std::sqrt(dot(c.normal, c.normal));
      if (!finite(c.point) || !finite(c.normal) || !std::isfinite(len) || !(len > 0.0)) return {};
      owns[p].push_back(at.size());
      at.push_back(c.point);
      n.push_back(Vec3{c.normal.x / len, c.normal.y / len, c.normal.z / len});
      strict.push_back(c.strict);
    }
  }
  // A point within a nanometre of a cut's plane is on it: two cuts in one plane (one piece's
  // and its neighbour's, the other way) then cut at the same points, with no sliver between.
  const double kOn = 1e-9;
  // Where a cut crosses an edge, from the edge's two ends taken in one fixed order: every
  // triangle that has the edge gets the very same point.
  auto cross = [](const Vec3& a, double da, const Vec3& b, double db) {
    const bool swap = b.x < a.x || (b.x == a.x && (b.y < a.y || (b.y == a.y && b.z < a.z)));
    const Vec3& p = swap ? b : a;
    const Vec3& q = swap ? a : b;
    const double dp = swap ? db : da, dq = swap ? da : db;
    const double t = dp / (dp - dq);
    return Vec3{p.x + t * (q.x - p.x), p.y + t * (q.y - p.y), p.z + t * (q.z - p.z)};
  };
  MeshSink sink;
  std::vector<int> kept;
  std::vector<CutPart> parts, next;
  std::vector<double> d;
  for (std::size_t t = 0; t < nt; ++t) {
    const auto found = pieces_of.find(model.triangle_face[t]);
    if (found == pieces_of.end()) continue;
    const auto& tri = model.mesh.triangles[t];
    parts.assign(1, CutPart{{model.mesh.vertices[tri[0]], model.mesh.vertices[tri[1]], model.mesh.vertices[tri[2]]},
                            std::vector<signed char>(at.size(), 0)});
    for (std::size_t k = 0; k < at.size(); ++k) {
      next.clear();
      for (CutPart& part : parts) {
        d.resize(part.v.size());
        bool above = false, below = false;
        for (std::size_t i = 0; i < part.v.size(); ++i) {
          d[i] = dot(sub(part.v[i], at[k]), n[k]);
          above = above || d[i] > kOn;
          below = below || d[i] < -kOn;
        }
        if (!below || !above) {
          part.side[k] = above ? 1 : below ? -1 : 0;
          next.push_back(std::move(part));
          continue;
        }
        CutPart up{{}, part.side}, down{{}, part.side};
        up.side[k] = 1;
        down.side[k] = -1;
        for (std::size_t i = 0; i < part.v.size(); ++i) {
          const std::size_t j = (i + 1) % part.v.size();
          if (d[i] >= -kOn) up.v.push_back(part.v[i]);
          if (d[i] <= kOn) down.v.push_back(part.v[i]);
          if ((d[i] > kOn && d[j] < -kOn) || (d[i] < -kOn && d[j] > kOn)) {
            const Vec3 x = cross(part.v[i], d[i], part.v[j], d[j]);
            up.v.push_back(x);
            down.v.push_back(x);
          }
        }
        next.push_back(std::move(up));
        next.push_back(std::move(down));
      }
      parts.swap(next);
    }
    for (const CutPart& part : parts) {
      bool keep = false;
      for (std::size_t p : found->second) {
        bool all = true;
        for (std::size_t k : owns[p]) all = all && (part.side[k] > 0 || (part.side[k] == 0 && !strict[k]));
        keep = keep || all;
      }
      if (!keep || part.v.size() < 3) continue;
      if (part.v.size() == 3) {   // a whole triangle, or a corner cut off one: as it is
        sink.add_triangle(part.v[0], part.v[1], part.v[2]);
      } else {
        // Its corners can stand in a straight line (where a neighbour was cut), so it is
        // cut into triangles from its middle, none of them flat.
        Vec3 c{0, 0, 0}, e{0, 0, 0};
        for (std::size_t i = 0; i < part.v.size(); ++i) {
          const Vec3& a = part.v[i];
          const Vec3& b = part.v[(i + 1) % part.v.size()];
          c = Vec3{c.x + a.x, c.y + a.y, c.z + a.z};
          e = Vec3{e.x + (a.y - b.y) * (a.z + b.z), e.y + (a.z - b.z) * (a.x + b.x), e.z + (a.x - b.x) * (a.y + b.y)};
        }
        if (!(dot(e, e) > 0.0)) continue;   // no area
        const double m = 1.0 / static_cast<double>(part.v.size());
        c = Vec3{c.x * m, c.y * m, c.z * m};
        for (std::size_t i = 0; i < part.v.size(); ++i)
          sink.add_triangle(c, part.v[i], part.v[(i + 1) % part.v.size()]);
      }
      kept.push_back(model.triangle_face[t]);
    }
  }
  if (sink.mesh.triangles.empty()) return {};
  std::sort(kept.begin(), kept.end());
  kept.erase(std::unique(kept.begin(), kept.end()), kept.end());
  if (kept_faces) *kept_faces = std::move(kept);
  if (ok) *ok = true;
  return std::move(sink.mesh);
}
}  // namespace

TriangleMesh pieces_mesh(const StepModel& model, const std::vector<FacePiece>& pieces, bool* ok) {
  return cut_surface(model, pieces, ok, nullptr);
}

Region region_from_pieces(const StepModel& model, const std::vector<FacePiece>& pieces, int id, Role role,
                          double depth_mm, double expand_mm, bool* ok) {
  Region r;
  r.id = id;
  r.role = role;
  r.expand_mm = expand_mm;
  if (ok) *ok = false;
  if (!(depth_mm > 0.0)) return r;
  bool good = false;
  std::vector<int> ids;
  TriangleMesh face = cut_surface(model, pieces, &good, &ids);
  if (!good) return r;
  return region_from_surface(model, ids, std::move(face), std::move(r), depth_mm, expand_mm, ok);
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
