#pragma once

// THE lattice boundary predicate (handoff 2026-07-29-lattice-boundary-finish).
//
// One object answers every boundary question the lattice pipeline asks:
//
//   * the GENERATOR asks "clip this strut centreline to the allowed region
//     eroded by the strut's radius" (clip_segment) and "may this cell overlap
//     the allowed region at all?" (cell_may_overlap);
//   * the CERTIFICATION posture asks "is this voxel's centre latticed?"
//     (lattice_certification_mask, built from the SAME cell_may_overlap and
//     keep-out predicates);
//   * the SKIN pass asks "which analytic faces bound the region?" (faces()).
//
// run_job.cpp's lattice_region_for already states the principle for the region
// ("the object the gate certifies and the file the slicer opens are the SAME
// region by construction"); this type extends it to the BOUNDARY, so the
// generator's emitted silhouette and the certification mask cannot drift apart
// (bar B7). There is deliberately NO second keep-out concept: protected
// features enter as the EXISTING resolved ClearanceGeometry (clearance.hpp),
// exactly what resolve_clearance_from_face / resolve_clearance_manual produce.
//
// THE ONE GUARANTEE everything else leans on: signed_distance(p) is a LOWER
// BOUND on the true signed distance from p to the allowed region's boundary
// (positive inside, negative outside), and it is 1-Lipschitz. Therefore
//
//     signed_distance(c) >= r   =>   the whole ball B(c, r) lies inside,
//
// which is why clipping a strut's CENTRELINE to {signed_distance >= radius}
// keeps the strut's SOLID inside the part (bar B3 — clip the solid, not the
// line). Every primitive here is evaluated ANALYTICALLY (planes, capped
// cylinders, bounded slabs, and the exact distance to a voxel solid set); no
// sampled contour or distance field is ever consulted, so the prototype's
// 0.093 mm contour-sampling overshoot cannot be inherited (blocked-stop 1).
//
// Clipping itself is a Lipschitz-CERTIFIED interval refinement: an interval is
// kept only when min(f(a), f(b)) >= (b-a)/2 PROVES f >= 0 throughout (f is
// 1-Lipschitz along a unit-speed segment). Kept spans are therefore
// guaranteed-inside to machine arithmetic, and uncertifiable slivers are
// dropped (conservative — the part never grows) and COUNTED, never silently
// kept.

#include <cstddef>
#include <vector>

#include "topopt/clearance.hpp"  // ClearanceGeometry — the existing keep-out
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/voxel.hpp"      // VoxelGrid

namespace topopt {

// An analytic face of the allowed region's boundary — what the skin/rim/collar
// pass walks. Faces come from the SAME primitives the signed distance is built
// from (never a third description of the boundary).
struct LatticeBoundaryFace {
  enum class Kind {
    Plane,  // a base half-space's boundary plane (material behind it)
    Bore,   // a Bolt keep-out's cylindrical wall (material OUTSIDE radius)
  };
  Kind kind = Kind::Plane;

  // Plane: point + OUTWARD unit normal (material where dot(p-origin, normal) <= 0).
  Vec3 origin{0.0, 0.0, 0.0};
  Vec3 normal{0.0, 0.0, 0.0};

  // Bore: the keep-out cylinder (UNIT axis_dir), radius, axial band [t_lo, t_hi]
  // — copied verbatim from the resolved ClearanceGeometry.
  Vec3 axis_point{0.0, 0.0, 0.0};
  Vec3 axis_dir{0.0, 0.0, 0.0};
  double radius = 0.0;
  double t_lo = 0.0;
  double t_hi = 0.0;

  // Bore only: emit a collar boss (rim tori + anchored diagrid) on this wall.
  bool collar = false;
};

// One kept sub-interval of a clipped segment, as arc-length parameters along
// the segment (0 at a, |b-a| at b).
struct LatticeClipSpan {
  double t0 = 0.0;
  double t1 = 0.0;
};

class LatticeBoundary {
 public:
  // ── construction ──────────────────────────────────────────────────────────
  // Base region primitives (intersection of half-spaces — the part blank).
  // `outward_normal` need not be unit; degenerate (zero) normals throw.
  void add_half_space(const Vec3& point, const Vec3& outward_normal);
  // Convenience: an axis-aligned box [lo, hi] as 6 half-spaces (+6 skin faces).
  void add_box(const Vec3& lo, const Vec3& hi);

  // Voxel base (the run_job path): the allowed base region is the union of the
  // solid voxel cubes (density >= iso). The distance evaluated is the EXACT
  // geometric distance to that union (expanding-shell search), clamped to
  // +/- window_mm — exact wherever |distance| < window_mm, which is all the
  // clipping ever needs (pass window_mm >= max erosion + one cell diagonal).
  // `grid` and `density` must outlive this object.
  void set_voxel_base(const VoxelGrid* grid, const std::vector<double>* density,
                      double iso, double window_mm);

  // Protected feature: the EXISTING clearance keep-out, subtracted from the
  // allowed region. A Bolt keep-out contributes a Bore face (collar-capable);
  // a Face slab keep-out only subtracts (it lives in void space in front of a
  // face — there is no lattice wall to dress). Invalid geometries are ignored
  // (the same safe no-op the rasterizer produces).
  void add_keep_out(const ClearanceGeometry& geom, bool collar);

  // ── the predicate ─────────────────────────────────────────────────────────
  // 1-Lipschitz lower bound on the true signed distance to the allowed-region
  // boundary; > 0 inside, < 0 outside.
  double signed_distance(const Vec3& p) const;

  // signed_distance with the terms of up to two faces skipped — what the skin
  // pass uses to clip an edge that lies ON a face's own offset surface (a rim
  // lies on TWO), where clipping against the owning face would degenerate into
  // f == 0 everywhere. Pass -1 to exclude nothing.
  double signed_distance_excluding(const Vec3& p, int exclude_face_a,
                                   int exclude_face_b) const;

  // The face whose term is the active (minimal) constraint at p — how a clipped
  // strut's cut end is attributed to the surface it landed on. Returns -1 when
  // the active term has no analytic face (the voxel base or a slab keep-out).
  // Deterministic: first-index tie-break.
  int nearest_face(const Vec3& p) const;

  // True iff p is inside SOME keep-out region inflated outward by tol —
  // point_in_clearance_region on each stored keep-out (the certification mask's
  // exclusion test; identical math to the rasterizer's).
  bool in_keep_out(const Vec3& p, double tol) const;

  // Conservative cell activation (bar (a) — activation by OVERLAP, not centre):
  // false ONLY when the Lipschitz bound PROVES the cell cannot intersect the
  // allowed region (signed_distance(centre) <= -half_diagonal). A cell this
  // returns true for may still emit nothing once clipped — harmless; a cell it
  // returns false for provably contains no allowed material.
  bool cell_may_overlap(const Vec3& cell_min, double cell_mm) const;

  // ── clipping (bar (b)) ────────────────────────────────────────────────────
  // Clip segment a->b to {signed_distance_excluding(p, ...) >= erosion}. Kept
  // spans are Lipschitz-PROVEN inside; boundary crossings are located to
  // kClipTolMm. Returns spans in ascending t; `uncertified_dropped` (when
  // non-null) is incremented for every sliver that had to be dropped because
  // the certificate could not decide it at the tolerance floor (conservative:
  // dropped, never kept). Deterministic: fixed midpoint refinement, no RNG.
  std::vector<LatticeClipSpan> clip_segment(const Vec3& a, const Vec3& b,
                                            double erosion, int exclude_face_a,
                                            int exclude_face_b,
                                            long long* uncertified_dropped) const;

  // The analytic boundary faces (skin/rim/collar surfaces). Plane faces appear
  // in the order their half-spaces were added; Bore faces in keep-out order.
  const std::vector<LatticeBoundaryFace>& faces() const { return faces_; }

  bool has_base() const { return !planes_.empty() || voxel_grid_ != nullptr; }
  std::size_t keep_out_count() const { return keep_outs_.size(); }

  // The crossing-location tolerance (mm) clip_segment refines to. Well under
  // every geometric bar (B5's overshoot bar is 0.05 mm).
  static constexpr double kClipTolMm = 1e-4;

 private:
  struct Plane {
    Vec3 point;
    Vec3 unit_outward;
    int face = -1;  // index into faces_
  };
  double voxel_distance(const Vec3& p) const;  // exact, window-clamped

  std::vector<Plane> planes_;
  std::vector<ClearanceGeometry> keep_outs_;
  std::vector<int> keep_out_face_;  // index into faces_ (-1: slab, no face)
  std::vector<LatticeBoundaryFace> faces_;

  const VoxelGrid* voxel_grid_ = nullptr;
  const std::vector<double>* voxel_density_ = nullptr;
  double voxel_iso_ = 0.5;
  double voxel_window_mm_ = 0.0;
};

// The certification-side voxel mask, built from the SAME predicate the
// generator emits against (bar B7): voxel e is latticed iff its density is
// printed (>= iso) AND its owning lattice cell (edge cell_mm, grid anchored at
// region_origin) may overlap the allowed region AND its centre is not inside
// any keep-out. Returns grid.voxel_count() flags (1 = latticed).
std::vector<char> lattice_certification_mask(const LatticeBoundary& boundary,
                                             const VoxelGrid& grid,
                                             const std::vector<double>& density,
                                             double iso, const Vec3& region_origin,
                                             double cell_mm);

}  // namespace topopt
