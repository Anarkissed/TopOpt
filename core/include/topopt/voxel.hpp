#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

// Per-voxel classification stored in the grid.
//   Empty      - outside the solid.
//   Interior   - solid, all six face-neighbours are also solid.
//   Surface    - solid, on the boundary of the solid (at least one face-
//                neighbour is Empty or lies outside the grid).
//   UserTagged - solid, claimed by a later stage. The voxelizer never emits
//                this; it exists so the grid can store a generic user tag per
//                voxel (ROADMAP M1.5: "interior / surface / user-tagged").
//   Load       - solid, on a face the user tagged as a load-application face
//                (ROADMAP M1.6). The voxelizer never emits this.
//   Fixture    - solid, on a face the user tagged as a mounting/fixture face
//                (ROADMAP M1.6). The voxelizer never emits this.
enum class VoxelTag : std::uint8_t {
  Empty = 0,
  Interior = 1,
  Surface = 2,
  UserTagged = 3,
  Load = 4,
  Fixture = 5,
};

// A dense, axis-aligned voxel grid with cubic voxels (one hex FEA element per
// voxel, ARCHITECTURE.md §4). Voxel (i,j,k) occupies the box
// [origin + (i,j,k)*spacing, origin + (i+1,j+1,k+1)*spacing]; its centre is
// origin + (i+0.5, j+0.5, k+0.5)*spacing. Tags are one byte per voxel in
// x-fastest, then y, then z order.
struct VoxelGrid {
  int nx = 0;
  int ny = 0;
  int nz = 0;
  double spacing = 0.0;  // cubic voxel edge length (model units, mm)
  Vec3 origin;           // grid minimum corner (= mesh bounding-box min)
  std::vector<VoxelTag> tags;

  std::size_t index(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) +
            static_cast<std::size_t>(j)) *
               static_cast<std::size_t>(nx) +
           static_cast<std::size_t>(i);
  }

  VoxelTag tag(int i, int j, int k) const { return tags[index(i, j, k)]; }
  void set_tag(int i, int j, int k, VoxelTag t) { tags[index(i, j, k)] = t; }

  // A voxel is solid iff it is not Empty (Interior, Surface, or UserTagged).
  bool solid(int i, int j, int k) const {
    return tag(i, j, k) != VoxelTag::Empty;
  }

  std::size_t voxel_count() const { return tags.size(); }
  std::size_t solid_count() const;  // number of non-Empty voxels

  double voxel_volume() const { return spacing * spacing * spacing; }
  double solid_volume() const {
    return static_cast<double>(solid_count()) * voxel_volume();
  }

  Vec3 voxel_center(int i, int j, int k) const {
    return Vec3{origin.x + (static_cast<double>(i) + 0.5) * spacing,
               origin.y + (static_cast<double>(j) + 0.5) * spacing,
               origin.z + (static_cast<double>(k) + 0.5) * spacing};
  }
};

// Voxelize a closed triangle mesh into a solid-filled grid. `resolution` is the
// number of voxels along the mesh's longest bounding-box axis; the other axes
// receive enough cubic voxels of the same edge length to cover the bounding
// box, so voxels are cubic (required by the hex-element FEA, §4). Solid voxels
// are tagged Interior or Surface; voxels outside the solid are Empty.
//
// Inside/outside is decided by a vertical (+Z) signed-crossing (winding) scan
// through each voxel centre, which is robust to a ray grazing an edge shared by
// two same-facing triangles. The mesh is expected to be watertight (the §5
// pipeline voxelizes only after the watertight check); an open mesh yields an
// undefined fill. Throws std::invalid_argument if resolution < 1 or the mesh is
// empty / degenerate (zero-volume bounding box).
VoxelGrid voxelize(const TriangleMesh& mesh, int resolution);

// ---------------------------------------------------------------------------
// Marching cubes on a density field + Gate V3 property suite (ROADMAP M3.5).
//
// After the SIMP loop (M3.4) produces a physical density field, M3.5 extracts a
// printable surface (marching cubes at threshold 0.5) and runs the ARCHITECTURE
// §7 V3 property checks on the result. This is the "property checks" pipeline
// stage (§5) that every optimizer output must pass before export.

// Marching cubes over a grid-indexed density field (size grid.voxel_count()),
// samples at voxel centres, background-padded so the surface closes at the grid
// boundary. Thin wrapper over the mesh/ marching_cubes with the grid's geometry.
// Throws std::invalid_argument if density.size() != grid.voxel_count().
TriangleMesh marching_cubes(const VoxelGrid& grid,
                            const std::vector<double>& density, double iso = 0.5);

// Result of the Gate V3 property suite. `passes` is the conjunction of the four
// ARCHITECTURE §7 V3 gates; the individual fields expose why.
struct V3Report {
  TriangleMesh mesh;         // cleaned isosurface (largest component)
  WatertightReport watertight;  // gate 1: closed + 2-manifold
  int mesh_components_raw = 0;   // components of the raw MC output (pre-cleanup)
  int mesh_components = 0;       // gate 2: components of the cleaned mesh (== 1)
  bool load_fixture_retained = false;  // gate 3: all Load/Fixture voxels rho>=0.9
  double min_load_fixture_density = 1.0;  // min rho over Load/Fixture voxels
  int load_fixture_voxels = 0;            // number of Load/Fixture voxels checked
  int min_feature_violations = 0;  // gate 4: solid voxels not in any 2x2x2 block
  bool passes = false;

  // Gate accessors (each true iff that §7 V3 gate holds).
  bool gate_watertight() const { return watertight.watertight; }
  bool gate_single_component() const {
    return !mesh.triangles.empty() && mesh_components == 1;
  }
  bool gate_load_fixture_retained() const { return load_fixture_retained; }
  bool gate_min_feature() const { return min_feature_violations == 0; }
};

// The minimum retained-density threshold for Load/Fixture voxels (§7 V3: ">=
// 0.9"). A voxel counts as a feature-support voxel when its tag is Load or
// Fixture (M1.6). With no such voxels the retention gate is vacuously satisfied.
constexpr double kV3RetentionThreshold = 0.9;

// Number of solid voxels (density > iso) that are NOT covered by any fully-solid
// 2x2x2 block of voxels — i.e. features thinner than 2 voxels in some direction
// (§7 V3: "Minimum feature size >= 2 voxels"). 0 means every solid voxel sits in
// at least one solid 2x2x2 block. Throws std::invalid_argument on size mismatch.
int min_feature_violations(const VoxelGrid& grid,
                           const std::vector<double>& density, double iso = 0.5);

// Run the full Gate V3 property suite on an optimizer output: extract + clean
// the marching-cubes surface and evaluate all four §7 V3 gates. `iso` is the
// density threshold (0.5 for M3.5). Throws std::invalid_argument if
// density.size() != grid.voxel_count().
V3Report check_v3(const VoxelGrid& grid, const std::vector<double>& density,
                  double iso = 0.5);

}  // namespace topopt
