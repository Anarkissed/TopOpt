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

// ── Manual (user-placed) primitive geometry (handoff group-editing). ───────
// The hole finder OVER-finds and MISSES; the user needs to hand-place a keep-out
// primitive and hand-delete a phantom one. A hand-placed primitive has NO B-rep
// face, so the axis/radius/normal/outline the rasterizer needs cannot be
// "derived exactly from the B-rep" (this header's original contract). Instead
// the user supplies the BASE geometry here, in the SAME model/voxel frame and mm
// units as StepFaceInfo. `ClearanceParams` (the concentric margin / axial
// clearance / slab depth) is then applied to these values EXACTLY as it is to a
// face-derived primitive — so a manual and an auto primitive of identical base
// geometry resolve to the identical predicate and produce the identical mask
// (BAR B2). This is the ONLY place clearance geometry originates off the B-rep.
struct ManualClearanceGeometry {
  ClearanceKind kind = ClearanceKind::Bolt;

  // Bolt (swept cylinder): a point on the axis + a (not necessarily unit) axis
  // direction, the bore radius, and the HALF-length of the cylinder's own axial
  // extent about `axis_point` (t ∈ [−half_length_mm, +half_length_mm] BEFORE the
  // axial-clearance growth). This mirrors what the auto path reads from the
  // face's tessellation span, only supplied instead of measured.
  Vec3 axis_point{0.0, 0.0, 0.0};
  Vec3 axis_dir{0.0, 0.0, 0.0};
  double radius_mm = 0.0;
  double half_length_mm = 0.0;

  // Face (bounded slab): a point on the plane + the OUTWARD (not necessarily
  // unit) normal, and the centred in-plane half-extents. The rasterizer derives
  // the in-plane (u,w) basis from the normal exactly as the auto path does, so
  // the slab is a `2·half_u_mm × 2·half_w_mm` rectangle centred on `origin`,
  // extruded outward by `slab_depth_mm`.
  Vec3 origin{0.0, 0.0, 0.0};
  Vec3 normal{0.0, 0.0, 0.0};
  double half_u_mm = 0.0;
  double half_w_mm = 0.0;
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

// ── The resolved rasterization predicate (handoff group-editing). ──────────
// The geometry a clearance keep-out reduces to once its SOURCE — a B-rep face OR
// user-supplied manual values — plus the editable `ClearanceParams` distances
// have been folded in. It carries NO StepModel and NO triangles: it is the pure
// swept-cylinder / bounded-slab predicate the voxel loop tests. Splitting
// resolve (source → this) from rasterize (this → mask) is what lets an auto and
// a manual primitive of identical geometry take the IDENTICAL rasterizer and so
// produce the IDENTICAL mask (BAR B2). `valid == false` => an empty region
// (nothing to mark) — the same safe no-op the pre-split code produced for a
// mismatched/untessellated face.
struct ClearanceGeometry {
  ClearanceKind kind = ClearanceKind::Bolt;
  bool valid = false;

  // Bolt: swept cylinder about `axis_point + t·axis_dir` (axis_dir is UNIT),
  // radius `radius`, axial band t ∈ [t_lo, t_hi] (already grown by the axial
  // clearance).
  Vec3 axis_point{0.0, 0.0, 0.0};
  Vec3 axis_dir{0.0, 0.0, 0.0};
  double radius = 0.0;
  double t_lo = 0.0;
  double t_hi = 0.0;

  // Face: bounded slab. `origin + s·normal` for s ∈ [0, depth] (normal is UNIT,
  // outward), clipped to the in-plane rectangle [u_lo,u_hi] × [w_lo,w_hi] in the
  // orthonormal in-plane basis (u, w).
  Vec3 origin{0.0, 0.0, 0.0};
  Vec3 normal{0.0, 0.0, 0.0};
  Vec3 u{0.0, 0.0, 0.0};
  Vec3 w{0.0, 0.0, 0.0};
  double u_lo = 0.0;
  double u_hi = 0.0;
  double w_lo = 0.0;
  double w_hi = 0.0;
  double depth = 0.0;
};

// Resolve the predicate from B-rep face `face_id` of `model` (the AUTO path): the
// axis/radius/normal come from `model.faces[face_id]` and the axial span /
// in-plane rectangle from that face's tessellation triangles, grown by `params`.
// Returns `{valid=false}` when the face's surface kind does not match the
// clearance kind, the geometry is degenerate, or the face owns no triangles.
// Throws std::invalid_argument if `face_id` is out of range or `triangle_face`
// is not parallel to the mesh.
ClearanceGeometry resolve_clearance_from_face(const StepModel& model, int face_id,
                                              const ClearanceParams& params);

// Resolve the predicate from user-supplied MANUAL geometry (no B-rep): `geom`
// carries the base axis/radius/half-length or origin/normal/half-extents, and
// `params` grows them by the same margins the auto path applies. Returns
// `{valid=false}` for a degenerate direction or non-positive extent — the same
// safe no-op the auto path yields.
ClearanceGeometry resolve_clearance_manual(const ManualClearanceGeometry& geom,
                                           const ClearanceParams& params);

// True iff point `p` (model space, mm) lies inside the resolved keep-out region,
// its boundary inflated OUTWARD by `tol` (mm) on every extent (radius / slab
// depth / in-plane rectangle / axial band). `tol == 0` is the exact region
// rasterize_clearance tests at a voxel centre; a positive `tol` widens it into a
// band around the region surface. A `{valid=false}` region contains nothing.
//
// This is the FREEZE PREDICATE the constrained smoother uses (handoff
// 2026-07-26-constrained-smooth-ui): a mesh vertex on a keep-clear bore wall, an
// anchor pad or a protected face is FROZEN so smoothing cannot move it. Freezing
// against the exact primitive geometry (this predicate, resolved once from PR
// 190's ClearanceGeometry) SURVIVES re-meshing — where a voxel-tag or face-id map
// does not, because the exported/smoothed mesh carries no face ids. The math is
// identical to rasterize_clearance's per-voxel inside test, just point-vs-region
// with an outward `tol`, so a frozen vertex and a FrozenVoid voxel agree on the
// same geometry.
bool point_in_clearance_region(const ClearanceGeometry& geom, const Vec3& p,
                               double tol);

// Rasterize an already-resolved predicate onto `solved_grid`, writing
// MaskValue::FrozenVoid into `out`. This is the shared rasterizer both the auto
// and manual paths (and the mask_clearance_region wrapper) funnel through.
//
// PRECEDENCE — FrozenSolid (part material) WINS over FrozenVoid: a solved voxel
// mapping to a SOLID voxel of `part` (at integer offset (offset_i, offset_j,
// offset_k) — solved voxel (i,j,k) is part voxel (i-oi, j-oj, k-ok)) is never
// voided. On the no-box path the solved grid IS the part grid and the offsets
// are 0. `out` is written in place (OR-semantics). A `{valid=false}` predicate
// marks nothing. Cost is O(solved_grid voxels).
//
// Throws std::invalid_argument if out.size() != solved_grid.voxel_count().
ClearanceRasterResult rasterize_clearance(const VoxelGrid& solved_grid,
                                          const VoxelGrid& part, int offset_i,
                                          int offset_j, int offset_k,
                                          const ClearanceGeometry& geom,
                                          DesignMask& out);

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
