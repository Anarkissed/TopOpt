#pragma once

#include <cstddef>

#include "topopt/step.hpp"   // StepModel, StepFaceInfo
#include "topopt/voxel.hpp"  // VoxelGrid, DesignMask, MaskValue

namespace topopt {

// ---------------------------------------------------------------------------
// Shape-aware clearance regions — "Keep clear" (handoff 100 / design 095).
//
// A clearance is user-declared EMPTY SPACE the optimizer must not grow material
// into: the swept volume a bolt head/washer/driver occupies through a fastener
// hole, or a shallow slab in front of a mounting face. It is *shape-aware
// keep-out* — it feeds the SAME FrozenVoid path (voxel.hpp) the design-box
// keep_out boxes do, so a cleared voxel carries no FEA element and no design
// variable. Unlike an axis-aligned keep_out box, the region is derived from the
// EXACT B-rep geometry (StepFaceInfo axis/radius/normal) the STEP importer
// captured, so it hugs the real hole/face.
//
// This is NOT mask_step_face (step.hpp): that walks part-SOLID layers to freeze
// the BC skin. Clearance lives in VOID space — the bore interior, the space in
// front of a face — which is exactly where the optimizer would otherwise fill.
//
// The rasterizer math needs no OCCT: it consumes the already-captured
// StepFaceInfo, so it is unit-tested headlessly against synthetic cylinder /
// plane models.

// Which keep-out volume a face contributes (design 095 STEP 1). The integer
// values are STABLE — the CLI job schema, the Swift bridge and the results
// diagnostics all encode the kind as this int.
enum class ClearanceKind : int {
  Bolt = 0,  // swept cylinder along a bore's axis (a cylindrical face)
  Face = 1,  // bounded slab extruded from a planar face's outline
};

// Editable clearance parameters. The GEOMETRY (axis/radius/normal/outline) is
// derived exactly from the B-rep; these SCALARS are the judgement-call distances
// the UI prefills with the design defaults and lets the user edit. All mm.
struct ClearanceParams {
  ClearanceKind kind = ClearanceKind::Bolt;

  // Bolt (swept cylinder): the keep-out radius is bore_radius + concentric_margin_mm;
  // the swept axial extent is the bore's through-part span grown by
  // axial_clearance_mm out each side (driver access + fastener protrusion).
  double concentric_margin_mm = 0.0;
  double axial_clearance_mm = 0.0;

  // Face (bounded slab): the face outline (its tessellation's in-plane extent)
  // extruded OUTWARD along the plane normal by this depth. A bounded slab, never
  // an infinite half-space, so a wrap-around gusset can still grow from the sides.
  double slab_depth_mm = 0.0;
};

// ── Suggested default distances (design 095 STEP 1/2). ────────────────────
// The GEOMETRY is exact; these are the judgement-call distances the UI prefills
// and labels as suggestions. Validated against ISO 4762 (socket-head cap screw
// head) + DIN 125 (plain washer OD) in handoff 100:
//   * A bolt's keep-out DIAMETER should clear the larger of the head OD and the
//     washer OD. For a nominal Ø d clearance-fit hole (bore ≈ 1.1 d), ISO 4762
//     head Ø dk ≈ 1.5 d and DIN 125 washer OD ≈ 2.0–2.3 d. Defaulting the
//     concentric margin to the BORE RADIUS gives keep-out Ø ≈ 2 × bore ≈ 2.2 d —
//     it brackets head + washer. (concentric_margin = bore_radius.)
//   * Axial access for the driver + fastener/nut protrusion is ≈ one bolt
//     diameter each side; defaulting axial clearance to the BORE DIAMETER
//     (2 × radius) covers it. (axial_clearance = 2 × bore_radius.)
//   * A mounting-face slab defaults SHALLOW and conservative so it never silently
//     kills a legitimate wrap-around gusset — a small fixed depth (see below).
inline constexpr double kClearanceFaceSlabDepthDefaultMm = 3.0;

// The suggested Bolt-clearance params for a bore of the given radius (mm).
inline ClearanceParams default_bolt_clearance(double bore_radius_mm) {
  ClearanceParams p;
  p.kind = ClearanceKind::Bolt;
  p.concentric_margin_mm = bore_radius_mm;        // keep-out Ø ≈ 2× hole Ø
  p.axial_clearance_mm = 2.0 * bore_radius_mm;    // bore diameter out each side
  return p;
}

// The suggested Face-clearance params (a shallow bounded slab).
inline ClearanceParams default_face_clearance() {
  ClearanceParams p;
  p.kind = ClearanceKind::Face;
  p.slab_depth_mm = kClearanceFaceSlabDepthDefaultMm;
  return p;
}

// The outcome of rasterizing ONE clearance region — enough for an honest UI:
// what was forbidden, and whether the region even reached the solved grid.
struct ClearanceRasterResult {
  std::size_t voxels_frozen = 0;  // voxels this call newly set FrozenVoid in `out`
  std::size_t region_voxels = 0;  // voxel centres geometrically inside the region
                                  // AND inside the grid (pre-precedence)
  bool region_in_grid = false;    // region_voxels > 0 — the region intersects the
                                  // solved grid at all (false => a silent no-op the
                                  // caller should SURFACE, not hide)
};

// Rasterize the clearance keep-out derived from B-rep face `face_id` of `model`
// onto `solved_grid`, writing MaskValue::FrozenVoid into `out` (which MUST be
// indexed on `solved_grid`, size solved_grid.voxel_count()).
//
// PRECEDENCE — FrozenSolid (part material) WINS over FrozenVoid (clearance): a
// solved voxel that maps to a SOLID voxel of `part` (which sits inside
// `solved_grid` at integer offset (offset_i, offset_j, offset_k) — voxel
// (i,j,k) of the solved grid is part voxel (i-offset_i, j-offset_j, k-offset_k))
// is part material and is NEVER voided, so a concentric margin overlapping the
// material around a bore leaves the part intact. On the no-box path the solved
// grid IS the part grid and the offsets are 0. Clearance forbids only NEW
// growth, never removes declared/preserved material (design 095 STEP 1c).
//
// `out` is written in place (OR-semantics: existing FrozenVoid entries are kept
// and this call adds more). `params.kind` selects the swept cylinder (Bolt) or
// bounded slab (Face); the corresponding StepFaceInfo geometry must be populated
// (a Bolt on a non-cylinder face, or a Face on a non-plane face, marks nothing).
// Cost is O(solved_grid voxels) — trivial next to a solve; not optimized.
//
// Throws std::invalid_argument if `face_id` is out of range or `out.size()` !=
// solved_grid.voxel_count().
ClearanceRasterResult mask_clearance_region(const VoxelGrid& solved_grid,
                                            const VoxelGrid& part, int offset_i,
                                            int offset_j, int offset_k,
                                            const StepModel& model, int face_id,
                                            const ClearanceParams& params,
                                            DesignMask& out);

}  // namespace topopt
