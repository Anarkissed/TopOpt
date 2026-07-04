#include "topopt/mesh.hpp"

#include <algorithm>
#include <map>
#include <utility>

namespace topopt {
namespace {

// Canonical undirected edge key: the two welded vertex indices, low first, so
// the same edge from two triangles maps to one key regardless of winding.
std::pair<int, int> edge_key(int a, int b) {
  return (a < b) ? std::make_pair(a, b) : std::make_pair(b, a);
}

}  // namespace

WatertightReport check_watertight(const TriangleMesh& mesh) {
  // Count how many triangles use each undirected edge.
  std::map<std::pair<int, int>, int> uses;
  for (const auto& t : mesh.triangles) {
    ++uses[edge_key(t[0], t[1])];
    ++uses[edge_key(t[1], t[2])];
    ++uses[edge_key(t[2], t[0])];
  }

  WatertightReport r;
  for (const auto& kv : uses) {
    if (kv.second == 1) ++r.boundary_edges;
    else if (kv.second > 2) ++r.non_manifold_edges;
  }
  // A closed 2-manifold surface has every edge shared by exactly two triangles.
  // An empty mesh has no triangles and is not a watertight solid.
  r.watertight = !mesh.triangles.empty() && r.boundary_edges == 0 &&
                 r.non_manifold_edges == 0;
  return r;
}

double signed_volume(const TriangleMesh& mesh) {
  double v6 = 0.0;  // six times the volume
  for (const auto& t : mesh.triangles) {
    const Vec3& a = mesh.vertices[t[0]];
    const Vec3& b = mesh.vertices[t[1]];
    const Vec3& c = mesh.vertices[t[2]];
    // dot(a, cross(b, c))
    const double cx = b.y * c.z - b.z * c.y;
    const double cy = b.z * c.x - b.x * c.z;
    const double cz = b.x * c.y - b.y * c.x;
    v6 += a.x * cx + a.y * cy + a.z * cz;
  }
  return v6 / 6.0;
}

void bounding_box(const TriangleMesh& mesh, Vec3& min, Vec3& max) {
  if (mesh.vertices.empty()) return;
  min = max = mesh.vertices.front();
  for (const auto& v : mesh.vertices) {
    min.x = std::min(min.x, v.x);
    min.y = std::min(min.y, v.y);
    min.z = std::min(min.z, v.z);
    max.x = std::max(max.x, v.x);
    max.y = std::max(max.y, v.y);
    max.z = std::max(max.z, v.z);
  }
}

}  // namespace topopt
