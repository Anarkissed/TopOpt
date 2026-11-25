// face_loads.hpp -- loads, anchors and protection depth taken from the DRAWN face
// (TO rebuild stage 1; ledger V-01, L-03; docs/design/to-rebuild/03-rules.md rules 3, 6).
//
// The old path (tag_step_face / mask_step_face / traction_loads) gives a face to
// the voxels whose centre lies within half a voxel of it, then spreads the force
// evenly over whatever was tagged. Where the face falls in the grid decides the
// loaded area, and on about half of all alignments a flat face tags nothing.
//
// Here the face itself carries the area. Its triangles are cut into small pieces;
// each piece hands its own area to the solid voxel it lies on, shared between
// that voxel's eight corner nodes by where the piece sits in the voxel. The
// result is, per node, the area of drawn face that node stands for:
//   - a load is the force times each node's share of the area: the total force
//     is exact and its centre is the face's own, whatever the grid alignment;
//   - an anchor holds each node in proportion to its area (a spring), or holds
//     every node that carries area (a clamp);
//   - a protection depth is measured in mm from the face, not in voxel layers.
//
// Pure C++/std (no Eigen, no OCCT): reads only StepModel::mesh / triangle_face
// and the grid, like face_tag.cpp.
#pragma once

#include <cstddef>
#include <vector>

#include "topopt/face_region.hpp"
#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// One small piece of a drawn face.
struct FacePiece {
  Vec3 point;          // its centre
  Vec3 normal;         // unit, pointing out of the part
  double area = 0.0;   // mm^2
};

// Cut the triangles of the given faces into pieces no longer than `max_edge` mm
// on any side. Throws std::invalid_argument on a face id out of range, a model
// whose triangle_face is not parallel to its triangles, or max_edge <= 0.
std::vector<FacePiece> face_pieces(const StepModel& model,
                                   const std::vector<int>& face_ids,
                                   double max_edge);
// The same for an explicit list of triangle indices (a region of a face).
std::vector<FacePiece> triangle_pieces(const StepModel& model,
                                       const std::vector<int>& triangles,
                                       double max_edge);

// The same for a region: its member faces, kept only where every one of the
// region's cuts holds at the piece's centre (the same test cut_voxels applies to
// voxel centres, applied here to the face itself).
std::vector<FacePiece> region_pieces(const StepModel& model,
                                     const ResolvedFaceRegion& region,
                                     double max_edge);

// Tag the solid voxels the pieces lie on (Load or Fixture), so everything that
// reads tags (the frozen skin, the receipts) sees the same voxels the nodes'
// areas came from. Returns how many voxels were newly tagged. Unlike
// tag_step_face this never comes back empty for a face that touches the part.
std::size_t tag_face_hosts(VoxelGrid& grid, const std::vector<FacePiece>& pieces,
                           VoxelTag tag);

// The area of drawn face each node stands for.
struct NodeArea {
  int node = 0;
  double area = 0.0;   // mm^2
  Vec3 normal;         // area-weighted mean outward normal, unit
};

struct FaceAreaReport {
  double drawn_area = 0.0;    // mm^2, the face's own
  double placed_area = 0.0;   // mm^2, the part of it that found a solid voxel
  std::size_t pieces = 0;
  std::size_t unplaced = 0;   // pieces with no solid voxel within one voxel
  Vec3 drawn_centre;          // area centre of the drawn face
  Vec3 placed_centre;         // area centre of what the nodes carry
};

// Share every piece between the corner nodes of the solid voxel it lies on (the
// voxel just inside the face; failing that, the nearest solid voxel within one
// voxel). Nodes are returned in ascending order, each once.
std::vector<NodeArea> face_node_areas(const VoxelGrid& grid,
                                      const std::vector<FacePiece>& pieces,
                                      FaceAreaReport* report = nullptr);

// A total force spread over the drawn face: node force = total_force x the
// node's share of the placed area. The emitted loads sum to total_force exactly.
// Throws std::invalid_argument when no piece found a solid voxel.
std::vector<NodalLoad> face_traction_loads(const std::vector<NodeArea>& areas,
                                           Vec3 total_force);

// Anchor, clamp form: every node that carries at least `min_area_fraction` of a
// full cell-face (spacing^2) is held in all three directions.
std::vector<DirichletBC> face_clamp_bcs(const VoxelGrid& grid,
                                        const std::vector<NodeArea>& areas,
                                        double min_area_fraction = 0.25);

// Anchor, spring form: each node is held by a spring of `stiffness_per_area`
// (N/mm per mm^2) times its own area, the same in every direction. Uses the
// solver's existing spring entries (DirichletBC::spring, contact = false).
std::vector<DirichletBC> face_spring_bcs(const std::vector<NodeArea>& areas,
                                         double stiffness_per_area);

// Protection / pad depth in mm. Marks every SOLID voxel whose centre lies within
// `depth_mm` of the given pieces' triangles (true distance, any direction), and
// always at least the voxels the pieces lie on, so a protection never freezes
// nothing. Returns how many voxels were set. `fraction`, when given, is resized
// to the grid and receives for each voxel the share of its volume that lies
// within the depth (1 well inside, 0 outside, between at the boundary), for the
// stages that can hold a partly protected voxel.
std::size_t mask_face_depth_mm(const VoxelGrid& grid, const StepModel& model,
                               const std::vector<int>& face_ids, double depth_mm,
                               MaskValue mask_value, DesignMask& mask,
                               std::vector<float>* fraction = nullptr);
// The same for a region (member faces; the cuts are applied to each voxel's
// centre, as mask_step_region does).
std::size_t mask_region_depth_mm(const VoxelGrid& grid, const StepModel& model,
                                 const ResolvedFaceRegion& region, double depth_mm,
                                 MaskValue mask_value, DesignMask& mask,
                                 std::vector<float>* fraction = nullptr);

}  // namespace topopt
