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

// ---------------------------------------------------------------------------
// Surface resampling for smooth tessellation (handoff 086-surface-resample).
//
// The optimizer's physical density is a GRAYSCALE field: the M3.3 density filter
// blurs the 0/1 design into a ramp roughly one min-feature radius wide. Marching
// cubes at the native grid tessellates that ramp with facets ~= one voxel across,
// so a smoothly-curved iso-surface is UNDER-tessellated and reads as terracing.
// The remedy is pure geometry: resample the SAME field to a finer lattice and run
// the SAME marching cubes there, yielding a better polygonal approximation of the
// SAME 0.5 iso-surface. It adds NO design information — the surface is already in
// the field — and makes no claim the optimizer did not make. It changes ONLY the
// tessellation, not the design, physics, or optimizer.

// Interpolant used to evaluate the coarse field at the fine sample locations.
//   Trilinear : C0 across cell boundaries — cheap but leaves visible creases at
//               the original cell walls; a poor smoother (kept for comparison).
//   Tricubic  : Catmull-Rom cubic convolution (Keys a = -1/2). C1-continuous AND
//               interpolating — it passes exactly through the original samples,
//               so the extracted surface is still the 0.5 level set of the input
//               samples, not an approximation of it. This is the smoothing choice.
enum class ResampleInterp { Trilinear, Tricubic };

// Resample a scalar field (VoxelGrid layout: size nx*ny*nz, x-fastest) onto a
// lattice `factor`x finer on every axis, returning the fine field of size
// (nx*factor)*(ny*factor)*(nz*factor) in the same layout. Fine sample m along an
// axis maps to the continuous coarse-centre coordinate u = (m+0.5)/factor - 0.5,
// so the fine and coarse lattices cover the SAME physical domain and centre
// convention as marching_cubes. Samples outside [0,n) read as background 0 — the
// same one-layer zero padding marching_cubes uses — so a solid touching the grid
// boundary is closed off identically. `factor` must be >= 1 (1 is the identity);
// throws std::invalid_argument on factor < 1 or field.size() != nx*ny*nz.
std::vector<double> resample_field(int nx, int ny, int nz,
                                   const std::vector<double>& field, int factor,
                                   ResampleInterp interp);

// Extract the iso-surface of `field` at `factor`x finer tessellation: resample
// the field (above) then run the standard marching_cubes on the fine lattice at
// spacing/factor. factor == 1 is byte-identical to marching_cubes(...) (the
// resample is the identity and reuses the same MC), so this is a strict superset.
// Same argument validation as marching_cubes plus factor >= 1.
TriangleMesh marching_cubes_resampled(int nx, int ny, int nz, double spacing,
                                      const Vec3& origin,
                                      const std::vector<double>& field,
                                      double iso, int factor,
                                      ResampleInterp interp);

// M7.anchor-integrity (FIX 3): like keep_largest_component, but ALSO retains any
// non-largest component that contains at least one "marked" vertex, and reports
// how many such components there were. `keep_vertex` is a per-vertex flag
// (size == mesh.vertices.size()); a component is kept when it is the largest OR
// any of its triangles touches a flagged vertex. `out_extra_kept` receives the
// number of non-largest components retained solely because they were marked; 0
// means the result is byte-for-byte keep_largest_component(mesh).
//
// check_v3 uses this to detect a pinned Load/Fixture anchor region that broke off
// as a minority island: it passes vertices adjacent to frozen voxels as the marks
// and reads `out_extra_kept` as the load_fixture_islands SIGNAL (it ships the
// single largest body as the mesh, so the §7 V3 single-component gate is
// unchanged — see voxelize.cpp check_v3). Callers that want the frozen region
// physically retained can use the returned mesh directly. Throws
// std::invalid_argument if keep_vertex.size() != mesh.vertices.size().
TriangleMesh keep_largest_and_marked_components(const TriangleMesh& mesh,
                                                const std::vector<char>& keep_vertex,
                                                int& out_extra_kept);

}  // namespace topopt
