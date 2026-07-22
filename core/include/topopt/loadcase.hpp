#pragma once

#include <functional>
#include <string>
#include <vector>

#include "topopt/clearance.hpp"  // ClearanceParams, ClearanceKind
#include "topopt/fea.hpp"        // DirichletBC, NodalLoad
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/pipeline.hpp"   // MinimizePlasticOptions
#include "topopt/step.hpp"       // StepModel
#include "topopt/voxel.hpp"      // VoxelGrid, DesignBox

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

// Handoff 124 — the ONE GLOBAL depth (mm) that governs EVERY Face protection in a
// project unless the front-end overrides it. A Face protection means "the
// optimizer may not TOUCH this face": it freezes the part's OWN material solid
// behind the selected face to this depth (FrozenSolid preservation — the opposite
// polarity of a keep-clear FrozenVoid). The default is ~2× the 2.5mm min-feature
// size: deep enough to keep a real skin, shallow enough not to pin a large
// fraction of a small part. The app shows ONE editable number; the CLI reads
// "face_protection_depth_mm". Converted to a voxel-layer count against the run's
// grid spacing (rounded, floored at 1) so a protection always freezes ≥ 1 layer.
inline constexpr double kFaceProtectionDepthDefaultMm = 5.0;

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

  // Handoff 100 — "Keep clear" clearance regions. Each entry is a B-rep face and
  // its (editable) clearance distances; build_production_loadcase derives the
  // exact swept-cylinder (bore) / bounded-slab (plane) keep-out from the face's
  // StepFaceInfo geometry and ORs it into the effective mask as FrozenVoid. The
  // app AUTO-adds a Bolt clearance for an anchored bore and takes an EXPLICIT Face
  // clearance for a mounting plane; the CLI reads them from job.json "clearances".
  // Empty (the default) → no clearance → byte-identical to the pre-100 path.
  struct Clearance {
    int face_id = -1;
    ClearanceParams params;  // kind (Bolt/Face) + the editable mm distances
  };
  std::vector<Clearance> clearances;

  // Handoff 124 — Face protections (preserve-skin). Each id is a B-rep face whose
  // OWN part material the optimizer may not touch: build_production_loadcase walks
  // the part-solid layers behind the face (mask_step_face, the SAME primitive the
  // anchor pad uses) to `face_protection_depth_mm` and pins them FrozenSolid,
  // footprint-only — ONLY the selected face's own solid, never surrounding void.
  // This is the OPPOSITE polarity of a keep-clear (which voids space in FRONT of a
  // face): a protection NEVER frees void, it only freezes EXISTING part solid, so
  // the handoff-100 part-membership precedence runs in reverse — a protection
  // overlapping a clearance margin keeps the part solid (FrozenSolid wins over
  // FrozenVoid; see the merge in minimize_plastic). ONE global depth governs ALL
  // protections. Empty (the default) → no protection → byte-identical to the run
  // before this handoff (THE ONE RULE).
  std::vector<int> face_protection_face_ids;
  double face_protection_depth_mm = kFaceProtectionDepthDefaultMm;
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

  // Handoff 100 — what each declared clearance actually did on the solved grid,
  // so a front-end can report HONESTLY: which face, which kind, how many voxels
  // it forbade, and whether the region reached the grid at all. `in_grid == false`
  // means the region fell entirely outside the solved domain (a silent no-op the
  // UI must SURFACE, not hide — e.g. a clearance in unreachable void with no design
  // box). Numbers shown to the user are these numbers. Empty when no clearance was
  // declared.
  struct ClearanceReport {
    int face_id = -1;
    ClearanceKind kind = ClearanceKind::Bolt;
    std::size_t voxels_frozen = 0;  // voxels this clearance set FrozenVoid
    bool in_grid = false;           // the region intersected the solved grid
  };
  std::vector<ClearanceReport> clearance_reports;

  // Handoff 124 — what each declared Face protection actually froze, so a
  // front-end reports HONESTLY (no silent over-claim): which face, how many part
  // voxels it pinned FrozenSolid, the depth (in voxels) it used, and — the honest
  // edge — whether the face's own solid was THINNER than that depth (so the
  // protection froze what exists, not a full `depth` layers everywhere). `frozen`
  // is the real footprint×depth intersected with the part solid, deduped against
  // itself; a protection whose face tags no solid voxels reports frozen == 0.
  // Numbers shown to the user are these numbers. Empty when none was declared.
  struct FaceProtectionReport {
    int face_id = -1;
    std::size_t voxels_frozen = 0;   // part voxels this protection set FrozenSolid
    int depth_voxels = 0;            // the depth (layers) used on this run's grid
    bool thinner_than_depth = false; // the face's solid was shallower than depth
  };
  std::vector<FaceProtectionReport> face_protection_reports;
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
