#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/clearance.hpp"  // ClearanceVoxelMask
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// ---------------------------------------------------------------------------
// FACE REGIONS — THE SECOND LAYER OF IDENTITY (task 2026-08-14-face-regions §1)
//
// ★ A "face" was one thing doing two jobs. This header splits them.
//
//   LAYER 1  voxel -> ORIGINAL CAD FACE ID (`StepModel::triangle_face`).
//            Used for PROJECTION (mesh/cad_project.cpp), for the CAD/cut
//            classifier, and for every `StepFaceInfo` lookup (clearance axes,
//            plane normals, cylinder radii). ★ NOTHING IN THIS HEADER WRITES IT.
//
//   LAYER 2  voxel -> REGION (this header). Used for roles, depth, split and
//            union — the layer the UI manipulates.
//
// ★ WHY LAYER 1 IS NON-NEGOTIABLE. PR 307's projection puts an exported vertex
// exactly on its own plane or cylinder, and the CAD-derived frozen region of PR
// 326 reached 0.3232 mm against SIMP's 0.4293 — the best dimensional-accuracy
// result this project has. ★ A UNION HAS NO ANALYTIC SURFACE: two planes do not
// merge into one plane, and a fillet unioned with a chamfer is neither. If a
// union renumbered or re-fitted `triangle_face`, every one of those results would
// be destroyed — which is exactly what `apply_face_overrides` (face_overrides.hpp)
// does for PAINT, and why paint is NOT the mechanism used here.
//
// So a region NEVER touches the face partition. It is a derived selection:
//
//     region  =  (member FACE IDS)  ∩  (an intersection of HALF-SPACES)
//
// The member faces keep their own ids and their own analytic surfaces; the
// half-spaces are stored as model-space GEOMETRY (a point and a normal), never
// as "region 24, half A" (§4e). A voxel belongs to the region iff it is against
// one of the member faces' triangles (the SAME half-voxel test tag_step_face
// has always used) AND it satisfies every cut.
//
// ---------------------------------------------------------------------------
// WHY THE CUTS TEST THE VOXEL AND NOT THE TRIANGLE
//
// A tessellation triangle can be arbitrarily large — a flat CAD wall is often
// two triangles covering the whole face. Classifying TRIANGLES by a half-space
// would send both to one side and hand back 48 empty sub-regions out of a 10x5
// grid split. The cut is therefore evaluated at the VOXEL CENTRE, which is what
// §4 says in the first place ("voxels of the region on each side become
// sub-regions") and is resolution-honest: a split is a statement about space,
// not about how the CAD happened to be triangulated.
// ---------------------------------------------------------------------------

// ONE HALF-SPACE. A voxel centre `p` is inside iff
//     dot(p - point, normal)  >=  0   (strict == false)
//     dot(p - point, normal)  >   0   (strict == true)
// `normal` need not be unit; it must be non-zero.
//
// The two senses exist so a grid split PARTITIONS: each cell takes its lower
// boundary non-strictly and its upper boundary strictly, so a voxel centre
// sitting exactly on a cut plane lands in exactly one cell, never two and never
// none.
struct RegionCut {
  Vec3 point{0.0, 0.0, 0.0};
  Vec3 normal{0.0, 0.0, 0.0};
  bool strict = false;
};

// ---------------------------------------------------------------------------
// THE SELECTION FILTER (§2)
//
// ★ "ALL FILLETS AND CHAMFERS" IS NOT A `kind` FILTER, and that correction is
// load-bearing. A CHAMFER is a flat bevel — StepSurfaceKind::Plane. A FILLET is
// rounded — Cylinder, or a torus that lands in Other. Filtering on Other would
// MISS most chamfers and CATCH unrelated splines and cones.
//
// What actually identifies a blend face is that it is SMALL and ADJACENT TO TWO
// LARGER FACES: it is the transition between two real walls. The maintainer's
// own bracket carries seven such faces (41-47, sixteen voxels each) beside a
// 10,554-voxel wall — a 660x range on one part.
//
// Every predicate set here is ANDed. An all-unset filter matches NOTHING (it is
// not "match everything": a region with no filter and no `add` is empty, and an
// empty region is refused at resolve time rather than silently tagging nothing).
//
// SIZE IS MEASURED IN mm^2, NOT VOXELS. A voxel count depends on the run
// resolution, so a filter expressed in voxels would match a different set of
// faces at 64 than at 128 and a persisted union would drift for a reason that
// has nothing to do with the CAD. Area is a property of the part. The UI shows
// the equivalent voxel count at the current resolution (area / spacing^2) so the
// number the user reasons about is still the one §2(b) asks for.
struct RegionFilter {
  // Face area upper bound (mm^2). <= 0 means unset.
  double max_area_mm2 = 0.0;
  // Face area lower bound (mm^2). <= 0 means unset.
  double min_area_mm2 = 0.0;

  // ADJACENCY (the blend signal). A face passes iff at least
  // `min_larger_neighbours` of its edge-adjacent faces have an area of at least
  // `larger_ratio` times its own. min_larger_neighbours <= 0 means unset.
  int min_larger_neighbours = 0;
  double larger_ratio = 2.0;

  // Surface class: "" (unset) | "plane" | "cylinder" | "other".
  std::string kind;

  // ANALYTIC SIGNATURE — "all six bolt bores in one tap". Matches a Cylinder
  // face whose radius is within `cylinder_radius_tol_mm` of
  // `cylinder_radius_mm`. <= 0 means unset.
  double cylinder_radius_mm = 0.0;
  double cylinder_radius_tol_mm = 0.05;

  bool any() const {
    return max_area_mm2 > 0.0 || min_area_mm2 > 0.0 ||
           min_larger_neighbours > 0 || !kind.empty() ||
           cylinder_radius_mm > 0.0;
  }
};

// ---------------------------------------------------------------------------
// THE PERSISTED REGION (§3c, §4e)
//
// ★ A UNION IS NOT STORED AS A LIST OF FACE IDS. A re-import after a CAD edit
// renumbers B-rep faces (OCCT's TopExp_Explorer order is not stable across an
// edit) and a stored id list would then be silently WRONG — pointing at whatever
// face inherited the number. What is stored instead is the DEFINING FILTER plus
// an explicit add/remove list, re-evaluated on every import; `filter_matched_at_author`
// records what the filter matched when the union was made, so a re-import can
// REPORT the change (resolve_face_regions fills `filter_drift`) instead of
// absorbing it.
//
// `add` / `remove` are still face ids and still renumber. That is unavoidable
// for a hand correction — but a hand correction is a SMALL, VISIBLE list, and
// the drift report names its size, so a change is surfaced rather than hidden.
struct FaceRegionSpec {
  // Author-assigned, unique within a job, >= 0. Load groups / anchors /
  // protections refer to a region by this id.
  int id = -1;
  std::string name;

  RegionFilter filter;
  // What `filter` matched when this region was authored. < 0 means "not
  // recorded" (no drift can be reported).
  int filter_matched_at_author = -1;

  std::vector<int> add;     // face ids explicitly added by tap
  std::vector<int> remove;  // face ids explicitly removed by tap

  // The region is the INTERSECTION of these half-spaces. Empty = no split.
  std::vector<RegionCut> cuts;

  // Provenance for the receipt: the region this one was split out of, -1 for a
  // root region. Never used to RESOLVE anything (see §4e: a split is stored as
  // geometry, not as a parent reference) — it exists so the log can say
  // "region 118, cell 3x2 of region 100".
  int parent_id = -1;
};

// A region after it has been resolved against ONE import.
struct ResolvedFaceRegion {
  int id = -1;
  std::string name;
  int parent_id = -1;

  // The face ids that make up the region on THIS import: filter matches, plus
  // `add`, minus `remove`. Ascending, deduplicated.
  std::vector<int> member_faces;
  // What the FILTER alone matched on this import (before add/remove).
  int filter_matched = 0;
  // filter_matched - spec.filter_matched_at_author, or 0 when the author count
  // was not recorded. ★ A NON-ZERO VALUE IS REPORTED, NEVER ABSORBED.
  int filter_drift = 0;
  bool filter_drift_known = false;

  std::vector<RegionCut> cuts;

  // Triangles of the member faces (indices into mesh.triangles), ascending.
  // The cuts are NOT applied here — they are voxel-centre tests (see the note
  // at the top of this header).
  std::vector<int> member_triangles;

  // Sum of the member faces' areas, mm^2.
  double area_mm2 = 0.0;
};

// Per-face area (mm^2), indexed by face id, size model.face_count. A face with
// no triangles has area 0.
std::vector<double> face_areas_mm2(const StepModel& model);

// Face-level edge adjacency: face f is adjacent to face g iff a triangle of f
// and a triangle of g share a welded mesh edge. Indexed by face id, size
// model.face_count, each entry ascending and free of self-references.
std::vector<std::vector<int>> face_adjacency(const StepModel& model);

// The face ids `filter` matches on `model`, ascending. An all-unset filter
// matches nothing.
std::vector<int> match_region_filter(const StepModel& model,
                                     const RegionFilter& filter);

// Resolve every spec against `model`.
//
// Throws std::invalid_argument when: an id is negative or repeated; an `add` /
// `remove` id is out of range (the message names the id, the count and the
// range, matching the face_tag.cpp diagnostic); a cut normal is zero; or a
// region resolves to NO member faces (an empty region is never a selection —
// it would tag nothing and report Ok, which is the "green run that measures
// nothing" failure).
std::vector<ResolvedFaceRegion> resolve_face_regions(
    const StepModel& model, const std::vector<FaceRegionSpec>& specs);

// ---------------------------------------------------------------------------
// THE REGION'S OWN COORDINATES (§4b)
// ---------------------------------------------------------------------------

// The frame a grid split is placed in. Either CYLINDRICAL (every member face is
// a cylinder and they share an axis within tolerance — "a union of fillets
// around a bore") or PCA (the principal axes of the member faces' vertices).
//
// ★ `cylindrical == false` on a mixed or irregular union is a fact the UI must
// SAY, not hide: "equal" is then equal in the PCA parameter, which is not equal
// in any intrinsic sense on a curved surface (§4b, mixed case).
struct RegionFrame {
  bool cylindrical = false;
  bool valid = false;

  // Cylindrical: the shared axis.
  Vec3 axis_point{0.0, 0.0, 0.0};
  Vec3 axis_dir{0.0, 0.0, 1.0};  // unit
  // PCA: origin at the centroid, u the PRINCIPAL (longest) axis, v the second,
  // w the third. All unit and mutually orthogonal.
  Vec3 origin{0.0, 0.0, 0.0};
  Vec3 u{1.0, 0.0, 0.0};
  Vec3 v{0.0, 1.0, 0.0};
  Vec3 w{0.0, 0.0, 1.0};

  // Extents of the region's vertices. Cylindrical: along the axis (axial_lo,
  // axial_hi) — the angular extent is always the full circle. PCA: along u and
  // along v.
  double axial_lo = 0.0;
  double axial_hi = 0.0;
  double u_lo = 0.0;
  double u_hi = 0.0;
  double v_lo = 0.0;
  double v_hi = 0.0;
};

// Tolerance (degrees) within which member cylinder axes count as "the same
// axis" for the cylindrical frame.
inline constexpr double kRegionAxisToleranceDeg = 2.0;

// Derive the frame of a resolved region. A region whose members are all
// cylinders sharing an axis gets the cylindrical frame; anything else gets PCA
// over the member faces' vertices. `valid == false` when the region has fewer
// than 3 distinct vertices (no frame is derivable).
RegionFrame region_frame(const StepModel& model,
                         const ResolvedFaceRegion& region);

// ---------------------------------------------------------------------------
// SPLITS (§4)
// ---------------------------------------------------------------------------

// The snap candidates a MANUAL split's rotate button cycles (§4a): the region's
// principal axis, its perpendicular, and 45 degrees between them. The returned
// normals are unit and lie in the plane the cut plane may rotate in.
//
// Index 0 is the DEFAULT: the cut plane whose normal is the region's PRINCIPAL
// axis, i.e. the plane that cuts ACROSS the long direction — the cut a user
// draws first on an elongated face.
std::vector<Vec3> manual_split_snap_normals(const RegionFrame& frame);

// One cell of a grid split.
struct GridSplitCell {
  int i = 0;  // index along the first family (angle, or u)
  int j = 0;  // index along the second family (axis, or v)
  std::vector<RegionCut> cuts;
};

// Place an N x M grid split in the region's own coordinates (§4b Mode B).
//
//   CYLINDRICAL — `n` sectors about the axis (each bounded by two half-spaces
//     whose planes CONTAIN the axis) and `m` slabs perpendicular to it. That is
//     the maintainer's worked example: "a face arcing around a donut, 10 equal
//     faces and 5 equal cuts perpendicular to it".
//   PCA — `n` slabs perpendicular to u and `m` slabs perpendicular to v.
//
// "Equal" means EQUAL IN PARAMETER (angle, or distance), which is what he drew
// — not equal in voxel count. The per-cell voxel counts are what
// `grid_split_voxel_counts` reports so a sliver is visible BEFORE confirming
// (§4c).
//
// Cells are returned in (i major, j minor) order, n*m of them. Throws
// std::invalid_argument if n < 1, m < 1, or the frame is invalid.
std::vector<GridSplitCell> grid_split_cells(const RegionFrame& frame, int n,
                                            int m);

// ---------------------------------------------------------------------------
// VOXELS, COUNTS, AND THE SLIVER GUARD (§5a)
// ---------------------------------------------------------------------------

// The grid indices of the SOLID voxels lying within (depth_voxels - 0.5) voxel
// edges of the region's member triangles — the same test, to the epsilon, that
// tag_step_face (depth 1) and mask_step_face (depth >= 1) have always used, so
// a one-member region tags exactly what its face tags today.
//
// The region's CUTS ARE NOT APPLIED. This is the union over the member faces;
// `cut_voxels` then applies the half-spaces. Splitting the two lets a whole
// grid split be priced in ONE scan of the grid instead of n*m scans.
//
// Throws std::invalid_argument if depth_voxels < 1 or triangle_face is not
// parallel to mesh.triangles.
std::vector<int> region_member_voxels(const VoxelGrid& grid,
                                      const StepModel& model,
                                      const ResolvedFaceRegion& region,
                                      int depth_voxels = 1);

// Those of `voxels` (grid indices, as returned above) satisfying every cut.
std::vector<int> cut_voxels(const VoxelGrid& grid, const std::vector<int>& voxels,
                            const std::vector<RegionCut>& cuts);

// The voxel count of every cell of a grid split, in `cells` order. One scan of
// the member voxels, then a cheap half-space test per cell.
std::vector<std::size_t> grid_split_voxel_counts(
    const VoxelGrid& grid, const std::vector<int>& member_voxels,
    const std::vector<GridSplitCell>& cells);

// ★★ THE MEDIAN — AND THE ARC IS WORTH MORE THAN THE ANSWER
// (task 2026-08-15-lattice-regions).
//
// This changed three times. The record matters because the wrong turns were
// caused by measuring one degenerate case and generalising from it.
//
//   1. MINIMUM. Four bore sectors declared 3.0/4.5/6.0/7.5 mm all returned
//      3.4106 mm, so the minimum looked boundary-dominated and degenerate.
//   2. MEDIAN. Same four sectors, same 3.4106 mm. So that diagnosis looked
//      wrong too, and it was reverted to the minimum.
//   3. `region_extent_probe` printed the DISTRIBUTION instead of one number,
//      on two different regions, and settled it:
//
//   the four BORE sectors (split height binding, ~2 voxels tall):
//        min == p25 == median == max == 3.411 for every sector
//        -> the distribution is a POINT; NO statistic can separate them, and
//           the region really IS that thin. Nothing was broken here.
//
//   ONE LARGE FACE split in two, depths 3.0 and 7.5 mm (depth binding):
//        sector 0  bbox 126x2x56    min 3.411   median  6.821
//        sector 1  bbox 117x4x104   min 3.411   median 13.642
//        -> the MINIMUM is 3.411 for BOTH, though one body is twice as thick.
//           The MEDIAN tracks the declared depth exactly, 2x for 2x.
//
// So the minimum IS boundary-dominated — a voxel on a set's boundary has a ~1-2
// voxel inscribed ball however thick the body is — and the median measures the
// body. Step 1's diagnosis was right; step 2 tested it on the one region where
// nothing could have worked, and step 2's revert generalised from that.
//
// ★ THE LESSON, RECORDED BECAUSE IT COST THREE CHANGES: when a measurement comes
// back flat, print the DISTRIBUTION before changing the statistic. The probe
// that settled this runs in seconds and existed after the second wrong fix.
//
// The median is also what the fit law needs: it asks how many cells lie ACROSS
// the latticed body, and the body's thickness — not its thinnest boundary voxel
// — is that quantity.
double region_thinnest_extent_mm(const ClearanceVoxelMask& mask);

// ★ THE ONE mm → VOXEL-LAYER CONVERSION (task 2026-08-15-lattice-regions §2b,
// bar R5).
//
// PR 328 §0 established that a face's PROTECTION depth and its LATTICE depth
// must be the same number: 5 mm of protection under a 7 mm lattice region left
// the lattice pass finding material only in the frozen collar — 79% of
// everything it latticed was the protected skin, and the rest was void a lattice
// cannot conjure material into.
//
// "The same number" is not enough on its own, because both are converted to
// WHOLE VOXEL LAYERS against the run's grid, and two call sites rounding
// independently is exactly how the two drift apart again. So the conversion is
// spelled ONCE, here, and both `build_production_loadcase` (the protection) and
// `lattice_role_regions_from_job` (the lattice) call it. Same mm, same grid,
// same layer count, same voxels — structurally, not by agreement.
//
// Floored at 1: a protection always freezes a real skin, and a lattice region
// always has a layer to fill.
inline int region_depth_layers(double depth_mm, double spacing) {
  if (!(spacing > 0.0)) return 1;
  const double layers = depth_mm / spacing;
  return layers > 0.0
             ? (layers + 0.5 >= 1.0 ? static_cast<int>(layers + 0.5) : 1)
             : 1;
}

// ★ THE SLIVER FLOOR, AND WHY THIS NUMBER.
//
// A 10x5 grid split is FIFTY sub-regions from one operation. On the maintainer's
// face 16 (10,554 voxels) that is ~211 each and fine; on a 500-voxel face it is
// ten each and useless. The floor below is not a taste: it is the size of the
// SMALLEST FACE HIS OWN CAD HANDED HIM. Faces 41-47 of M2_verticalStand.step tag
// sixteen voxels each at resolution 128 and he selects them today. The guard
// therefore refuses to MANUFACTURE anything smaller than the smallest thing the
// CAD itself produced — a bound the part sets, not one this code invents.
inline constexpr std::size_t kRegionSliverFloorVoxels = 16;

// The verdict of the sliver guard.
struct SliverVerdict {
  bool ok = false;
  std::size_t min_cell_voxels = 0;
  int min_cell_i = 0;
  int min_cell_j = 0;
  std::size_t empty_cells = 0;
  std::size_t floor_voxels = kRegionSliverFloorVoxels;
  std::size_t member_voxels = 0;
  // The largest n*m that WOULD clear the floor at this member count, as a
  // straight budget (member_voxels / floor). It is an upper bound, not a
  // promise: an uneven region can fail below it, which is why the guard prices
  // the actual cells rather than trusting the budget.
  int max_cells_budget = 0;
  std::string reason;  // empty iff ok
};

// ★ REFUSE BEFORE DOING ANYTHING (R5). Prices the actual per-cell counts and
// returns ok == false, with the number, when any cell falls below `floor`.
SliverVerdict check_sliver(const std::vector<std::size_t>& cell_voxels,
                           const std::vector<GridSplitCell>& cells,
                           std::size_t member_voxels,
                           std::size_t floor = kRegionSliverFloorVoxels);

// ---------------------------------------------------------------------------
// TAGGING BY REGION — the layer-2 counterparts of tag_step_face / mask_step_face
// ---------------------------------------------------------------------------

// Tag every solid voxel of the region with `tag`. Identical in every respect to
// tag_step_face over the region's member faces, then intersected with the cuts.
// A one-member, zero-cut region tags EXACTLY what tag_step_face tags for that
// face — that identity is what makes day one byte-identical (R1).
//
// Throws std::invalid_argument if `tag` is not Load/Fixture.
std::size_t tag_step_region(VoxelGrid& grid, const StepModel& model,
                            const ResolvedFaceRegion& region, VoxelTag tag);

// mask_step_face over a region: walk `depth_voxels` part-solid layers behind the
// region's member faces and write `mask_value`, intersected with the cuts.
std::size_t mask_step_region(const VoxelGrid& grid, const StepModel& model,
                             const ResolvedFaceRegion& region,
                             MaskValue mask_value, int depth_voxels,
                             DesignMask& mask);

}  // namespace topopt
