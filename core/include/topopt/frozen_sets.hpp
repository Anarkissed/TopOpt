// frozen_sets.hpp -- what the user froze, kept as GEOMETRY (TO rebuild stage 1,
// for stage 3; ledger P-04, L-03).
//
// The design mask says which voxels are frozen. That is enough for the solve, but
// a surface drawn from it has voxel-shaped inner faces. A FrozenFaceSet carries
// the same freeze as the drawn face's own triangles and a depth in mm, so the
// boundary method and the export can hold the frozen body by true distance.
//
// Filled by build_production_setup only when stage 1 is on (to_stage1_on());
// empty otherwise, and a reader must then fall back to the mask. Covers the
// anchor / retained-load pad and every protected face or region. Keep regions
// and clearances are volumes, not faces, and stay in the mask only.
#pragma once

#include <vector>

#include "topopt/face_region.hpp"  // RegionCut

namespace topopt {

struct FrozenFaceSet {
  // Indices into StepModel::mesh.triangles.
  std::vector<int> triangles;
  // A region's cuts; empty for whole faces. A point p belongs when, for every
  // cut, dot(p - cut.point, cut.normal) >= 0 (> 0 when cut.strict).
  std::vector<RegionCut> cuts;
  // The frozen body is everything of the part within this true distance of the
  // triangles (the rule mask_face_depth_mm applies to voxels).
  double depth_mm = 0.0;
  bool solid = true;  // true: kept solid. false: kept empty.
};

}  // namespace topopt
