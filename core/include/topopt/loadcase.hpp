#pragma once

#include <functional>
#include <string>
#include <vector>

#include "topopt/fea.hpp"       // DirichletBC, NodalLoad
#include "topopt/mesh.hpp"      // Vec3
#include "topopt/pipeline.hpp"  // MinimizePlasticOptions
#include "topopt/step.hpp"      // StepModel
#include "topopt/voxel.hpp"     // VoxelGrid, DesignBox

namespace topopt {

// Depth, in voxels, of the FrozenSolid structural pad frozen behind each
// anchor/load face on the production load-case path (M7.anchor-integrity FIX 1).
// tag_step_face freezes only a ~1-voxel BC skin, so the material behind it is a
// free design variable the optimizer carves away, leaving the anchor boss a
// paper-thin film that then gets isolated and discarded (diagnosis 064). Freezing
// a pad this deep (mask_step_face, FrozenSolid) ties the boundary condition into
// the body so the optimizer must route load through a real structural region. 3
// is conservative: deeper than the 2-voxel min-feature size (§7 V3) without
// pinning a large fraction of a small part. This lived in bridge.cpp; it moved
// here with the shared builder so the app and the CLI use the identical depth.
inline constexpr int kProductionAnchorPadDepthVoxels = 3;

// A front-end-neutral description of the user's declared load case (ARCHITECTURE
// §1 mode (a)). The iPad app maps its BridgeLoadCase to this; topopt-cli maps its
// job.json to this; both then call build_production_loadcase, so the SAME STEP +
// the SAME load case + the SAME resolution produce the SAME grid/BCs/options and
// hence the SAME design regardless of front-end (LAN-offload STEP 0 / handoff
// 093). Face ids index the imported StepModel's B-rep faces.
struct ProductionLoadCase {
  // Anchor B-rep faces: tagged Fixture and fully clamped.
  std::vector<int> anchor_face_ids;

  // One load group: a set of B-rep faces sharing a total force (newtons) that is
  // spread as a consistent distributed traction over the group's exposed faces
  // (topopt::traction_loads) — never a lumped point force. A zero-force group (or
  // one whose faces tag no voxels) contributes nothing.
  struct LoadGroup {
    std::vector<int> face_ids;
    Vec3 force{0.0, 0.0, 0.0};  // fx, fy, fz in N
  };
  std::vector<LoadGroup> load_groups;

  // true → walk the recommendation ladder (production_reduction_ladder) and
  // freeze the anchor/load structural pad; false → a single conservative variant
  // {0.9} with no pad (the mostly-solid "handle the forces, minimal removal"
  // preview). Mirrors BridgeLoadCase::minimize_plastic.
  bool minimize_plastic = true;

  // The print/build direction (the interlayer-margin orientation). (0,0,0)
  // defaults to +Z. gravity_direction is set to its unit negation.
  Vec3 build_dir{0.0, 0.0, 1.0};

  // Sparse-infill override, percent in [0, 100]; < 0 means "no override" (use the
  // M5.1 recommendation, no knockdown). Only scales the ladder acceptance margin.
  double infill_percent = -1.0;

  // Optional design-domain expansion (the "add material" feature). When
  // has_design_box is true the run voxelizes onto a larger grid spanning the
  // union of the part and design_box (model-space mm), and the optimizer may grow
  // material into the box beyond the import; keep_out_boxes become FrozenVoid.
  // Unset → byte-identical to the no-box path.
  bool has_design_box = false;
  DesignBox design_box;
  std::vector<DesignBox> keep_out_boxes;
};

// Permanent per-load-group instrumentation (handoff 099, small-face load loss).
// build_production_loadcase emits ONE line through this sink for every declared
// load group: the group index, its face count, |force| in newtons, the number of
// solid voxels the group's faces tagged Load, and — when the group contributes
// nothing to the run — WHY it was skipped ("zero-force" vs "zero-tagged"). A
// "zero-tagged" line is the fingerprint of the failure this handoff addresses: a
// load face smaller than a voxel footprint at a coarse resolution tags no voxels,
// so its traction never reaches the solver and `external_loads` arrives empty.
// Surfacing it here is the observability that would have caught the silent loss in
// week one — it is NOT the guard (require_external_loads stays the hard backstop).
//
// The default sink writes one line to stderr (surfaced on device via the process
// log, and by topopt-cli). A front-end MAY override it (e.g. to route to os_log),
// and a test MAY capture it. set_loadcase_log_sink installs a new sink and returns
// the previous one; passing an empty std::function silences the log. The sink is a
// process-global set up once before a run (build_production_loadcase runs one at a
// time on a background queue), so it needs no internal locking.
using LoadcaseLogFn = std::function<void(const std::string& line)>;
LoadcaseLogFn set_loadcase_log_sink(LoadcaseLogFn sink);

// The grid, Dirichlet BCs and fully-configured options a production load-case run
// hands to minimize_plastic. `options` already has configure_production_options
// applied (solver/projection/min-feature/Galerkin) PLUS the load case (external
// loads, gravity direction, ladder, anchor pad, design box, infill). It does NOT
// set keyframe_count (a per-front-end viz choice: the app sets 12, the CLI 0) nor
// the progress/on_variant/cancel callbacks (front-end wiring) — the caller adds
// those to `options` before calling minimize_plastic. `solved_grid` is
// minimize_plastic_solved_grid(grid, options): the grid the run actually solves
// on (the expanded domain when a design box is set), needed up front to index a
// progressive-variant stream.
struct ProductionRunSetup {
  VoxelGrid grid;                  // the PART grid, with Fixture/Load tags applied
  std::vector<DirichletBC> bcs;    // clamped anchor nodes (or min-x fallback)
  MinimizePlasticOptions options;  // production config + the load case
  VoxelGrid solved_grid;           // minimize_plastic_solved_grid(grid, options)
};

// Build the production run setup for `lc` from the imported `model`, voxelized at
// `resolution`. This is the SINGLE code path the iPad app (TopOptBridge) and
// topopt-cli both use for a declared load case, so neither can drift into a
// different part. Behavior is the exact geometry the bridge's
// run_minimize_plastic_loadcase performed before the extraction:
//   * anchors → Fixture; each non-zero load group → a distributed traction over
//     its faces (assembled against an anchors-only base grid so groups don't
//     bleed into each other), with the load faces retained on the main grid;
//   * Dirichlet BCs clamp all 8 corner nodes of every Fixture voxel (deduped);
//     with NO anchors, the min-x boundary is auto-clamped so the system is
//     well-posed (mirrors the self-weight path);
//   * configure_production_options + external loads + gravity direction (−build
//     dir) + ladder (reduction ladder when minimize_plastic, else {0.9});
//   * when minimize_plastic, a kProductionAnchorPadDepthVoxels FrozenSolid pad
//     behind every anchor and retained load face (design_mask);
//   * the design box + keep-outs and the infill override when set.
// Degenerate fallbacks keep a run well-posed: no load groups → self-weight (empty
// external loads); no anchors → min-x clamp. Needs OCCT (STEP face selection).
ProductionRunSetup build_production_loadcase(const StepModel& model,
                                             int resolution,
                                             const ProductionLoadCase& lc);

}  // namespace topopt
