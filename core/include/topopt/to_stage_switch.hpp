// to_stage_switch.hpp -- TO rebuild: THE ONE TEMPORARY SWITCH of the stage in
// progress (docs/design/to-rebuild/02-plan.md section 3: a stage's new behaviour
// sits behind one switch until its gate passes; the switch and the old path are
// deleted in the same stage's close-out).
//
// STAGE 1 (true loads and honest results). TOPOPT_FACE_LOADS:
//   unset / "voxel" : today's behaviour everywhere. The default until the gate.
//   "face"          : loads, pads and protection depths from the drawn face
//                     (face_loads.hpp), pads and protections in mm; anchors clamp
//                     the voxels the face lies on; and the optimiser's stop rule
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

}  // namespace topopt
