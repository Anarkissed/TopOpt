#pragma once

#include <array>
#include <cstddef>
#include <vector>

namespace topopt {

// A point / vector in model space (units are whatever the source file uses;
// STL is conventionally millimetres).
struct Vec3 {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
};

// A triangle mesh with welded (shared) vertices: each triangle stores three
// indices into `vertices`. STL stores each facet's vertices independently, so
// the reader welds geometrically-identical vertices together — that shared
// topology is what makes the watertight check below meaningful.
struct TriangleMesh {
  std::vector<Vec3> vertices;
  std::vector<std::array<int, 3>> triangles;

  std::size_t triangle_count() const { return triangles.size(); }
  bool empty() const { return triangles.empty(); }
};

// Result of the watertight / 2-manifold check. A mesh is watertight when every
// edge is shared by exactly two triangles: no boundary edges (an open hole) and
// no non-manifold edges (an edge shared by three or more triangles).
struct WatertightReport {
  bool watertight = false;
  int boundary_edges = 0;      // edges used by exactly one triangle
  int non_manifold_edges = 0;  // edges used by more than two triangles
};

// Classify a mesh as watertight (closed + 2-manifold) via edge-use counts.
WatertightReport check_watertight(const TriangleMesh& mesh);

// Signed volume enclosed by the mesh, via the divergence theorem:
// sum over triangles of dot(v0, cross(v1, v2)) / 6. For a closed mesh with the
// outward-facing counter-clockwise winding STL specifies, this is the positive
// enclosed volume. It is only meaningful for a closed mesh.
double signed_volume(const TriangleMesh& mesh);

// Axis-aligned bounding box over the mesh vertices. `min` and `max` are left
// unchanged if the mesh has no vertices.
void bounding_box(const TriangleMesh& mesh, Vec3& min, Vec3& max);

}  // namespace topopt
