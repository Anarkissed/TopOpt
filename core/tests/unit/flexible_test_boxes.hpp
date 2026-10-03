#pragma once

// Box parts for the Flexible tests (task 2026-09-28-flexible-squish-maths). Built in
// memory — no file under tests/fixtures/** is read or written.
//
// Face ids: 0 bottom (-Z), 1 top (+Z), 2 front (-Y), 3 right (+X), 4 back (+Y),
// 5 left (-X). Every triangle is wound OUTWARD, as an imported part is.

#include <cstdio>
#include <string>
#include <vector>

#include "topopt/face_region.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

namespace flexible_test {

using topopt::Vec3;

inline void add_quad(topopt::StepModel& m, Vec3 a, Vec3 b, Vec3 c, Vec3 d, int face) {
  const int base = static_cast<int>(m.mesh.vertices.size());
  for (const Vec3& p : {a, b, c, d}) m.mesh.vertices.push_back(p);
  m.mesh.triangles.push_back({base, base + 1, base + 2});
  m.mesh.triangles.push_back({base, base + 2, base + 3});
  m.triangle_face.push_back(face);
  m.triangle_face.push_back(face);
}

// An L x W x H box with its minimum corner at `o`. The quads are welded by
// coordinate afterwards so the mesh is closed (watertight) like an import.
inline topopt::StepModel box(double L, double W, double H, Vec3 o = {0, 0, 0}) {
  topopt::StepModel m;
  auto P = [&](double x, double y, double z) { return Vec3{o.x + x, o.y + y, o.z + z}; };
  add_quad(m, P(0, 0, 0), P(0, W, 0), P(L, W, 0), P(L, 0, 0), 0);  // bottom -Z
  add_quad(m, P(0, 0, H), P(L, 0, H), P(L, W, H), P(0, W, H), 1);  // top +Z
  add_quad(m, P(0, 0, 0), P(L, 0, 0), P(L, 0, H), P(0, 0, H), 2);  // front -Y
  add_quad(m, P(L, 0, 0), P(L, W, 0), P(L, W, H), P(L, 0, H), 3);  // right +X
  add_quad(m, P(L, W, 0), P(0, W, 0), P(0, W, H), P(L, W, H), 4);  // back +Y
  add_quad(m, P(0, W, 0), P(0, 0, 0), P(0, 0, H), P(0, W, H), 5);  // left -X
  // weld identical coordinates
  std::vector<Vec3> uniq;
  std::vector<int> remap(m.mesh.vertices.size());
  for (std::size_t i = 0; i < m.mesh.vertices.size(); ++i) {
    const Vec3& p = m.mesh.vertices[i];
    int found = -1;
    for (std::size_t j = 0; j < uniq.size(); ++j)
      if (uniq[j].x == p.x && uniq[j].y == p.y && uniq[j].z == p.z) {
        found = static_cast<int>(j);
        break;
      }
    if (found < 0) {
      found = static_cast<int>(uniq.size());
      uniq.push_back(p);
    }
    remap[i] = found;
  }
  m.mesh.vertices = uniq;
  for (auto& t : m.mesh.triangles)
    for (int& k : t) k = remap[static_cast<std::size_t>(k)];
  m.face_count = 6;
  m.faces.resize(6);
  const Vec3 normals[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    m.faces[static_cast<std::size_t>(f)].kind = topopt::StepSurfaceKind::Plane;
    m.faces[static_cast<std::size_t>(f)].plane_normal = normals[f];
  }
  m.solid_count = 1;
  m.brep_volume = L * W * H;
  m.faces_are_fitted = false;
  return m;
}

// One face region per face id: region id = 100 + face id.
inline std::vector<topopt::FaceRegionSpec> one_region_per_face(int faces = 6) {
  std::vector<topopt::FaceRegionSpec> out;
  for (int f = 0; f < faces; ++f) {
    topopt::FaceRegionSpec s;
    s.id = 100 + f;
    s.name = "face " + std::to_string(f);
    s.add = {f};
    out.push_back(s);
  }
  return out;
}

inline const topopt::ResolvedFaceRegion& region(const std::vector<topopt::ResolvedFaceRegion>& rs,
                                                int id) {
  for (const auto& r : rs)
    if (r.id == id) return r;
  std::fprintf(stderr, "no region %d\n", id);
  static topopt::ResolvedFaceRegion none;
  return none;
}

}  // namespace flexible_test
