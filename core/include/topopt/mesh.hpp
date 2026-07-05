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

// ---------------------------------------------------------------------------
// Marching cubes + mesh cleanup (ROADMAP M3.5, ARCHITECTURE §3 mesh/, §5
// pipeline "marching cubes -> mesh cleanup").

// Extract the iso = `iso` surface of a scalar field sampled on a voxel grid,
// via marching cubes (Lorensen-Cline, standard 256-case triangle table).
//
// The field is grid-indexed exactly like VoxelGrid: size nx*ny*nz, x-fastest
// then y then z, so field[(k*ny + j)*nx + i] is the sample at voxel (i,j,k). A
// sample sits at the voxel CENTRE, model-space position
//   origin + (i+0.5, j+0.5, k+0.5) * spacing.
// The domain is padded by one layer of background (value 0) on every side, so a
// solid that reaches the grid boundary is closed off there rather than left open
// (the extracted surface of a solid interior is a closed shell). A voxel is
// "inside" the surface when its sample value is strictly greater than `iso`
// (density convention: solid = density > iso; M3.5 uses iso = 0.5).
//
// Vertices are placed on cube edges by linear interpolation of the two corner
// values and welded through a global edge map, so the same lattice edge yields
// one shared vertex across all cubes that use it. On smooth (density-filtered)
// fields the result is a closed, 2-manifold surface (check_watertight);
// checkerboard/diagonal corner patterns — which the M3.3 density filter
// suppresses — are the only configurations that can open it, and mesh cleanup
// (below) drops any disconnected shells left over.
//
// Throws std::invalid_argument if nx/ny/nz < 1, spacing <= 0, or field.size()
// != nx*ny*nz.
TriangleMesh marching_cubes(int nx, int ny, int nz, double spacing,
                            const Vec3& origin, const std::vector<double>& field,
                            double iso);

// Number of connected components of a triangle mesh under shared-EDGE adjacency
// (two triangles are connected when they share an edge, i.e. two vertex
// indices). A watertight solid shell is one component; the marching-cubes output
// of a design with disconnected islands has one component per island. An empty
// mesh has 0 components.
int count_components(const TriangleMesh& mesh);

// Mesh cleanup: drop degenerate (repeated-index) triangles, then keep only the
// largest shared-edge connected component and re-index its vertices (unused
// vertices removed). This is the §5 "mesh cleanup" step that reduces a
// multi-shell marching-cubes output to the single dominant part, so the V3
// single-component / watertight gates apply to the printable body rather than to
// stray 0.5-threshold islands. An empty input returns an empty mesh.
TriangleMesh keep_largest_component(const TriangleMesh& mesh);

}  // namespace topopt
