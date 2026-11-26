// to_stage_switch.hpp -- TO rebuild: THE ONE TEMPORARY SWITCH of the stage in
// progress (docs/design/to-rebuild/02-plan.md section 3: a stage's new behaviour
// sits behind one switch until its gate passes; the switch and the old path are
// deleted in the same stage's close-out).
//
// STAGE 1 (true loads and honest results). TOPOPT_FACE_LOADS:
//   unset / "voxel" : today's behaviour everywhere. The default until the gate.
//   "face"          : loads, pads and protection depths from the drawn face
//                     (face_loads.hpp), pads and protections in mm; a glued
//                     anchor holds the drawn face's own nodes (scenario jobs
//                     still clamp the voxels it lies on); the optimiser's stop rule
//                     watches the design's own stress, not the stress in the
//                     voxels a load or an anchor sits on (ledger P-15).
//   "face_spring"   : as "face", and each anchor node is held by a spring in
//                     proportion to the drawn area it stands for.
#pragma once

#include <cstdlib>
#include <string>

namespace topopt {

enum class FaceLoadMode { Voxel, Face, FaceSpring };

inline FaceLoadMode face_load_mode() {
  const char* v = std::getenv("TOPOPT_FACE_LOADS");
  if (v == nullptr) return FaceLoadMode::Voxel;
  const std::string m(v);
  if (m == "face") return FaceLoadMode::Face;
  if (m == "face_spring") return FaceLoadMode::FaceSpring;
  return FaceLoadMode::Voxel;
}

inline bool to_stage1_on() { return face_load_mode() != FaceLoadMode::Voxel; }

// STAGE 2 (a strength number that holds), written ahead of its gate.
// TOPOPT_STRENGTH:
//   unset   : today's strength check everywhere.
//   "stiff" : a voxel cut by the surface is solved at its real stiffness
//             (E x fill, not E x fill^3; ledger A-01). Nothing else changes.
//   "size"  : as "stiff", and the stress that decides pass or fail is read over
//             the material's length (material_length.hpp), not at one voxel
//             (ledger A-02). Where no length is published, or it is smaller than
//             a voxel, the reading is the single voxel, as today.
enum class StrengthMode { Today, Stiff, Size };

inline StrengthMode strength_mode() {
  const char* v = std::getenv("TOPOPT_STRENGTH");
  if (v == nullptr) return StrengthMode::Today;
  const std::string m(v);
  if (m == "stiff") return StrengthMode::Stiff;
  if (m == "size") return StrengthMode::Size;
  return StrengthMode::Today;
}

inline bool to_stage2_on() { return strength_mode() != StrengthMode::Today; }

}  // namespace topopt
