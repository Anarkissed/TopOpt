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
//   UserTagged - solid, claimed by a later stage (e.g. M1.6 LOAD/FIXTURE face
//                tagging). The voxelizer never emits this; it exists so the
//                grid can store a user tag per voxel (ROADMAP M1.5:
//                "interior / surface / user-tagged").
enum class VoxelTag : std::uint8_t {
  Empty = 0,
  Interior = 1,
  Surface = 2,
  UserTagged = 3,
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

}  // namespace topopt
