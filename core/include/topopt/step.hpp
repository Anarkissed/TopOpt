#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// Thrown for any STEP import failure: a missing/unreadable file, a file OCCT
// cannot parse as STEP, or a STEP that yields no solid. The message describes
// the cause. (OCCT is an implementation detail; it does not appear in this
// public header — ARCHITECTURE.md §3.)
class StepError : public std::runtime_error {
 public:
  explicit StepError(const std::string& msg) : std::runtime_error(msg) {}
};

// Tessellation controls handed to the mesher. `linear_deflection` is the maximum
// chordal deviation (model units, i.e. mm) between the tessellated facets and the
// exact B-rep surface: smaller => finer mesh, and for a curved solid the mesh
// volume converges upward toward the analytic volume as it tightens. This is the
// "controllable deflection" ROADMAP M1.4 calls for. `angular_deflection` bounds
// the angle (radians) between adjacent facets on curved faces.
struct StepTessellation {
  double linear_deflection = 0.1;
  double angular_deflection = 0.5;
};

// A STEP model imported via OCCT: exact B-rep measures plus a triangle mesh
// tessellated at the requested deflection. `brep_volume` and the counts come
// from the exact solid and do NOT depend on tessellation; `mesh` is the
// tessellated surface (welded shared vertices, outward-facing winding) suitable
// for check_watertight and the divergence-theorem signed_volume.
struct StepModel {
  TriangleMesh mesh;
  // Per-triangle B-rep face id, parallel to `mesh.triangles`
  // (triangle_face[t] is the face triangle t was tessellated from). Face ids
  // are the 0-based TopExp_Explorer(TopAbs_FACE) order, so they run
  // [0, face_count) — the same ordering face_count enumerates. This is what
  // lets a caller select "a STEP face" (ROADMAP M1.6) after the per-face
  // triangulations have been welded into one mesh.
  std::vector<int> triangle_face;
  double brep_volume = 0.0;  // exact solid volume, mm^3 (OCCT BRepGProp)
  int solid_count = 0;       // TopAbs_SOLID count in the shape
  int face_count = 0;        // B-rep faces (TopAbs_FACE) across all solids
};

// Import a STEP file (AP203/AP214/AP242) via OCCT and tessellate it at the given
// deflection. The STEP length unit is honored (OCCT converts to millimetres).
// Throws StepError if the file is missing/unreadable, is not valid STEP, or
// contains no solid. This is the pipeline's STEP entry point (ARCHITECTURE.md
// §5: STEP ──OCCT──▶ tessellated surface).
StepModel import_step_file(const std::string& path,
                           const StepTessellation& tess = {});

// Tag every solid voxel of `grid` that lies against B-rep face `face_id` of
// `model` with `tag` (ROADMAP M1.6). `tag` MUST be VoxelTag::Load or
// VoxelTag::Fixture. `grid` must have been voxelized from `model.mesh` (same
// coordinate frame); the face's tessellation triangles are read from
// `model` via `triangle_face`.
//
// A solid voxel is "against" the face iff its centre is within half a voxel
// edge (+ a numeric epsilon) of the closest point on one of that face's
// triangles. For a planar face flush with the solid boundary this selects
// exactly the one-voxel-thick slab of surface voxels adjacent to the face
// (interior voxels sit >= 1.5 voxels from the boundary and are never within
// half a voxel of it). Returns the number of voxels tagged.
//
// Throws std::invalid_argument if `tag` is not Load/Fixture, `face_id` is
// outside [0, model.face_count), or `model.triangle_face` is not parallel to
// `model.mesh.triangles`.
std::size_t tag_step_face(VoxelGrid& grid, const StepModel& model, int face_id,
                          VoxelTag tag);

}  // namespace topopt
