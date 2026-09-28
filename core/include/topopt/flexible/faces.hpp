#pragma once

#include <string>
#include <vector>

#include "topopt/face_region.hpp"  // ResolvedFaceRegion
#include "topopt/mesh.hpp"         // TriangleMesh, Vec3
#include "topopt/step.hpp"         // StepModel
#include "topopt/voxel.hpp"        // VoxelGrid

namespace topopt {
namespace flexible {

// ════════════════════════════════════════════════════════════════════════════════
// F5 — FACE FRAMES AND STACKS (02 §10, M12, M13, R11, R13)
//
// A loaded face is a face REGION (loads.face_regions). Its geometry is read from
// the imported mesh: `StepModel::mesh` + `triangle_face` for a STEP part AND for an
// STL/3MF part (whose faces are the importer's pseudo-faces), so everything below
// works on both.
// ════════════════════════════════════════════════════════════════════════════════

// Tolerances named once. R6/02 §10: a stack is "side" when its load is more than
// 15° from build Z. R13: a face whose normals spread more than 30° is flagged. Two
// stacks are "on the same axis" (one profile per stack, M13) when their load lines
// are within 15° of each other.
inline constexpr double kSideStackDeg = 15.0;
inline constexpr double kNormalSpreadFlagDeg = 30.0;
inline constexpr double kSameAxisDeg = 15.0;

// THE FACE FRAME (R13).
//   load  = into the part, along the face's area-weighted normal
//   X     = the principal (longest) axis of the face projected onto the plane ⟂ load
//   Y     = load × X
//   then rotated about the load by frame_rotation_deg (0 / 90 / 180 / 270).
// Face coordinates (u, v) are in mm along X and Y, measured from the corner of the
// projected face's bounding box, so u ∈ [0, u_extent_mm], v ∈ [0, v_extent_mm].
//
// Determinism (so the app and core draw the same frame): the principal axis comes
// from the EXACT area second moment of the projected triangles (no vertex
// sampling); its sign makes it point along the first of model +X, +Y, +Z it is not
// perpendicular to; and a face with no longest direction (a square or a disc:
// principal moments within 1e-6) takes model +X projected into the plane (else +Y).
struct FaceFrame {
  bool valid = false;
  std::string reason;  // why not, when !valid
  Vec3 load{0, 0, -1};
  Vec3 x_axis{1, 0, 0};
  Vec3 y_axis{0, 1, 0};
  int rotation_deg = 0;
  Vec3 centroid{0, 0, 0};  // area centroid of the face
  double u_min = 0.0;      // bounding box of the projected face, relative to the
  double v_min = 0.0;      //   centroid along X / Y
  double u_extent_mm = 0.0;
  double v_extent_mm = 0.0;
  double area_mm2 = 0.0;            // true surface area
  double projected_area_mm2 = 0.0;  // area ⟂ load
  // The angle between the two most different triangle normals (a two-sweep
  // estimate: the normal farthest from the mean, then the one farthest from that).
  double normal_spread_deg = 0.0;
  bool normal_spread_flag = false;  // > kNormalSpreadFlagDeg
  double build_angle_deg = 0.0;     // angle between the load line and build Z (0..90)
  bool side = false;                // > kSideStackDeg
  bool principal_axis_tied = false; // no longest direction: the +X/+Y rule chose X

  // (u, v) of a model point, and the model point at (u, v) on the frame plane
  // (the plane through the centroid ⟂ load).
  void to_uv(const Vec3& p, double& u, double& v) const;
  Vec3 from_uv(double u, double v) const;
};

// The frame of the given triangles of `mesh` (outward-wound, as every imported
// part is). Returns valid == false with a reason for an empty or degenerate set.
// Throws FlexibleError for a rotation that is not a multiple of 90.
FaceFrame face_frame(const TriangleMesh& mesh, const std::vector<int>& triangles,
                     int rotation_deg, const Vec3& build_dir);

// One column of the stack: a ray along the load through the (u, v) cell centre.
struct StackColumn {
  int iu = 0, iv = 0;        // cell in the column grid
  double u_mm = 0.0, v_mm = 0.0;
  double area_mm2 = 0.0;     // pitch² (⟂ load)
  double entry_t = 0.0;      // along the load, from the frame plane to the face
  double exit_t = 0.0;       // ... to where the ray leaves the part
  double lattice_mm = 0.0;   // latticed length inside [entry, exit]
  int exit_face = -1;        // the face the ray leaves through; -1 = not found
};

// A face or region the stack leaves through, with the share of the footprint area
// that leaves there.
struct StackLink {
  int id = -1;
  double area_fraction = 0.0;
};

// THE STACK (M13, 02 §10): the material swept from the loaded face along the load
// until it leaves the part. Its columns are the solve's columns; the faces it
// leaves through are the LINKED OTHER END.
struct Stack {
  int face_region_id = -1;
  FaceFrame frame;
  double pitch_mm = 0.0;
  int nu = 0, nv = 0;             // the column grid over [0, u_extent] × [0, v_extent]
  std::vector<int> cell;          // nu*nv (index iv*nu + iu) -> column index, or -1
  std::vector<StackColumn> columns;
  std::vector<StackLink> exit_faces;    // by face id, largest share first
  std::vector<StackLink> exit_regions;  // declared face regions holding an exit face
  double exit_unresolved_fraction = 0.0;  // columns with no exit found (should be 0)
  double footprint_area_mm2 = 0.0;        // Σ column areas
  int latticed_columns = 0;               // columns with lattice_mm > 0
  double lattice_mm_min = 0.0, lattice_mm_max = 0.0, lattice_mm_mean = 0.0;
  double stack_mm_max = 0.0;              // longest entry->exit run

  int column_at(int iu, int iv) const {
    if (iu < 0 || iv < 0 || iu >= nu || iv >= nv) return -1;
    return cell[static_cast<std::size_t>(iv) * static_cast<std::size_t>(nu) +
                static_cast<std::size_t>(iu)];
  }
};

// Build the stack of `face` on `model`. `lattice_mask` (size grid.voxel_count(),
// 1 = latticed) is sampled along every column for `lattice_mm`; `regions` are the
// job's resolved face regions, used only to name the linked exit regions.
//
// A region with CUTS (a sector of a split face) keeps only the columns whose face
// point satisfies every cut, and its frame's X axis and extents are then taken from
// those columns (the whole face's would describe the wrong shape).
//
// Throws FlexibleError when the frame is invalid, the face has no column at this
// pitch, or pitch_mm <= 0.
Stack build_stack(const StepModel& model, const ResolvedFaceRegion& face,
                  const std::vector<ResolvedFaceRegion>& regions, const VoxelGrid& grid,
                  const std::vector<char>& lattice_mask, int rotation_deg,
                  const Vec3& build_dir, double pitch_mm);

// Angle between two load LINES (0..90°): the sign of a direction does not matter.
double axis_angle_deg(const Vec3& a, const Vec3& b);

}  // namespace flexible
}  // namespace topopt
