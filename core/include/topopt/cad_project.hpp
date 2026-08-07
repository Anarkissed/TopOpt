#pragma once

#include <cstddef>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

namespace topopt {

// ---------------------------------------------------------------------------
// PROJECTION ONTO THE KNOWN ANALYTIC CAD SURFACE
// (task 2026-08-06-cad-face-projection).
//
// THIS IS NOT SMOOTHING, AND THE DISTINCTION IS THE WHOLE POINT.
//
// A voxelized-and-re-tessellated part carries two completely different kinds of
// surface:
//
//   * surface that came from the user's CAD — a mounting face, a bolt bore, a
//     wall. There the TRUE SURFACE IS KNOWN EXACTLY: `StepFaceInfo` already
//     carries "this wall is this plane" and "this hole is this cylinder, this
//     radius, this axis", read from the B-rep on import. Nothing is estimated.
//     Moving such a vertex onto its own analytic surface is DIMENSIONALLY EXACT
//     BY CONSTRUCTION: afterwards a flat face is flat to floating-point and a
//     bore is round to floating-point. Smoothing those surfaces can only make
//     them worse, and PR 303 measured exactly that.
//
//   * surface the OPTIMIZER CUT. No ground truth exists there at all. Nothing in
//     this header touches it — an unattributed vertex is LEFT ALONE, which is the
//     safe direction.
//
// SUB-VOXEL BY CONSTRUCTION. Every motion here is bounded by the attribution
// tolerance, which is a fraction of one voxel. The design field, the optimizer,
// the physics and the reported mass are untouched; only the exported surface's
// vertex positions move, and only towards geometry the CAD already stated.
//
// DEFAULT OFF. With `CadProjectOptions::enabled == false` nothing in the export
// path calls into this file and every exported byte is unchanged.
// ---------------------------------------------------------------------------

// How to attribute and project. Lengths in millimetres, model frame.
struct CadProjectOptions {
  // Master switch. False (the DEFAULT) => the export path never calls in.
  bool enabled = false;

  // ATTRIBUTION TOLERANCE. A vertex is attributed to the nearest CAD face iff
  // its unsigned distance to that face's tessellated patch is <= this. Callers
  // derive it from the voxel: the exported iso-surface of a retained CAD face
  // sits within half a voxel of that face plus the marching-cubes/tricubic
  // placement error, so the tolerance has to be stated in voxels and MEASURED,
  // never guessed. `cad_project_options_for_grid` below is the one place that
  // turns a voxel spacing into these numbers.
  double tolerance_mm = 0.0;

  // AMBIGUITY BAND. A vertex is AMBIGUOUS when a second CAD face of a DIFFERENT
  // surface kind lies within this distance of the nearest one — the vertex could
  // honestly belong to either, so no projection is applied and it is counted and
  // reported rather than silently assigned.
  double ambiguity_band_mm = 0.0;

  // MOTION GUARD. A projection that would move a vertex further than this is
  // REFUSED (the vertex is left where it is) and counted. Rationale: the
  // exported surface can only be half a voxel from a face it actually came from,
  // so a larger correction means the ATTRIBUTION is wrong, not that the CAD is.
  double max_move_mm = 0.0;

  // FOLD GUARD. Refuse any vertex motion that would reverse an incident
  // triangle's normal, putting that vertex back where it started. ON by default,
  // because MEASURED on the maintainer's own part the raw projection inverts 987
  // triangles carrying 0.096% of the surface: flattening a terraced oblique face
  // onto its plane collapses the risers, and a collapsed riser can fold through
  // itself. Reverted vertices lose their exactness and are counted.
  bool fold_guard = true;

  // SEAM TRANSITION BAND, in rings of mesh edges. 0 disables it.
  //
  // Projection moves a CAD-face vertex up to a voxel; its optimizer-cut
  // neighbour does not move at all, so a step appears exactly where the two
  // meet. This carries the projection's own displacement outward into the
  // optimizer-cut surface with a linearly decaying weight, over this many rings,
  // so the surface arrives at the CAD face continuously instead of stepping onto
  // it.
  //
  // THIS IS NOT SMOOTHING, and the distinction is the same one the header opens
  // with. Nothing is averaged with itself and no surface with a known answer is
  // touched: every attributed vertex keeps its EXACT analytic position, and the
  // only vertices that move are ones the optimizer cut, where no ground truth
  // exists — so displacing them costs no known quantity. The displacement is
  // bounded by the projection's own, i.e. by one voxel.
  int seam_blend_rings = 2;

  // The voxel spacing these tolerances were derived from, carried along so every
  // reported displacement can be stated in voxels without the caller having to
  // supply the grid again. Reporting only; nothing branches on it.
  double voxel_mm = 0.0;

  // Project vertices attributed to a Plane face onto that plane. (Both of these
  // exist so a probe can isolate one kind; production sets both.)
  bool project_planes = true;
  // Project vertices attributed to a Cylinder face onto that cylinder.
  bool project_cylinders = true;
};

// The tolerances for a given voxel spacing, in ONE place so the probe, the test
// and the production export cannot use three different numbers. The multipliers
// are justified against the measurement in
// docs/handoffs/2026-08-06-cad-face-projection.md S1/S2.
CadProjectOptions cad_project_options_for_grid(double voxel_spacing_mm);

// Which CAD face each vertex belongs to, and why some belong to none.
struct CadAttribution {
  // face_of_vertex[i] is the B-rep/pseudo face id vertex i was attributed to, or
  // -1 for "not attributed" — too far from any face, or ambiguous. -1 is treated
  // as OPTIMIZER-CUT surface everywhere downstream: it is left alone.
  std::vector<int> face_of_vertex;
  // Unsigned distance from each vertex to the CAD surface (mm), reported so a
  // caller can histogram the population the tolerance is cutting.
  std::vector<double> distance_mm;
  // A vertex is a SEAM vertex when it is attributed to face F and at least one
  // of its mesh-edge neighbours is either unattributed (optimizer-cut) or
  // attributed to a DIFFERENT face. Seam vertices are projected under an extra
  // constraint — see project_onto_cad_faces.
  std::vector<char> seam;
  // Per-vertex: this vertex WAS within tolerance of the CAD, but a second face
  // of a different kind was just as close, so no face was picked. It is on the
  // CAD; we simply refuse to say which face. Kept per-vertex (not only as a
  // count) so a caller can separate "off the CAD" from "on a CAD edge".
  std::vector<char> ambiguous_flag;

  bool ambiguous_at(std::size_t i) const {
    return i < ambiguous_flag.size() && ambiguous_flag[i] != 0;
  }

  std::size_t attributed = 0;
  std::size_t unattributed = 0;   // includes `ambiguous` and `off_analytic_surface`
  std::size_t ambiguous = 0;
  // Within tolerance of a face's tessellated PATCH but NOT of that face's
  // ANALYTIC surface — a vertex just past the end of a partial cylinder is the
  // canonical case. Withheld rather than projected sideways.
  std::size_t off_analytic_surface = 0;
  std::size_t n_plane = 0;        // attributed, face kind Plane
  std::size_t n_cylinder = 0;     // attributed, face kind Cylinder
  std::size_t n_other = 0;        // attributed, kind Other — LEFT ALONE
  std::size_t n_seam = 0;
};

// Attribute every vertex of `mesh` to a face of `model`, geometrically.
//
// WHY GEOMETRIC AND NOT INHERITED: the exported variant mesh carries NO face
// ids. It is extracted by marching cubes from a scalar density field
// (core/src/cli/run_job.cpp:321), and the field has no face channel; nor does
// the STL/3MF the app and the certification re-import, which have no per-triangle
// attribute slot at all. So attribution has to be re-established from geometry,
// at export, while the imported `StepModel` is still in hand.
//
// Throws std::invalid_argument if `opts.tolerance_mm <= 0`.
CadAttribution attribute_to_cad_faces(const TriangleMesh& mesh,
                                      const StepModel& model,
                                      const CadProjectOptions& opts);

// What the projection did, so the caller can report it rather than assert it.
struct CadProjectionStats {
  std::size_t moved = 0;
  std::size_t moved_plane = 0;
  std::size_t moved_cylinder = 0;
  std::size_t left_other = 0;       // attributed to a kind we have no surface for
  std::size_t left_unattributed = 0;
  std::size_t seam_constrained = 0; // seam vertices held inside the face patch
  std::size_t refused_by_guard = 0; // would have moved further than max_move_mm
  // Optimizer-cut vertices carried by the transition band, and the largest
  // distance any of them was carried.
  std::size_t blended = 0;
  double max_blend_mm = 0.0;
  // Vertices put back where they started because moving them would have folded
  // an incident triangle. These do NOT end up on their analytic surface; they
  // are the price of not shipping an inverted facet.
  std::size_t reverted_by_fold_guard = 0;
  // Transition-band vertices the guard put back. These cost NOTHING — an
  // optimizer-cut vertex has no correct position to lose — which is why the
  // guard spends them before it spends any exactness.
  std::size_t reverted_band = 0;
  int fold_guard_passes = 0;
  // ★ VERTICES PUT BACK BECAUSE PROJECTING THEM WOULD HAVE WELDED THE MESH SHUT
  // (task 2026-08-06-arm-projection-and-void-check).
  //
  // A DIFFERENT failure from a fold, found only when projection was armed by
  // default and run on a COARSE grid. Where an oblique CAD face was exported as
  // a staircase, a terrace riser is perpendicular to the face, so its two
  // endpoints share their in-plane position EXACTLY and differ only along the
  // normal. Projecting both onto that plane therefore lands them on the SAME
  // POINT, to the bit. No triangle inverts and none becomes degenerate, so the
  // fold guard passes over it by design (it treats a collapsed riser as having
  // "nothing to fold through") — but the two surface sheets the riser separated
  // are now topologically welded, and the exported file stops being watertight.
  //
  // Measured on the demo l-bracket at resolution 48: 124 positions each
  // received two distinct vertices, producing 293 edges shared by FOUR
  // triangles instead of two. On the maintainer's own part at resolution 128
  // it does not bite (two vertices coincide, no non-manifold edge results),
  // which is why PR 307 never saw it — the coarser the grid relative to the
  // feature, the more of the surface is terraced.
  std::size_t reverted_by_weld_guard = 0;
  // Distinct positions that two or more vertices would have landed on, before
  // the guard broke them up. Reported so a pass is distinguishable from a
  // check that never ran.
  std::size_t weld_collisions_found = 0;
  // Triangles left with a REVERSED normal, and the area they carry. Counted
  // whether or not the guard ran, so "with the guard" and "without it" are the
  // same measurement rather than two different ones.
  std::size_t inverted_triangles_remaining = 0;
  double inverted_area_mm2 = 0.0;
  double max_move_mm = 0.0;
  double rms_move_mm = 0.0;
  // The largest step introduced at a CAD/optimizer-cut junction: over every mesh
  // edge joining a MOVED vertex to an UNMOVED one, the distance the moved
  // endpoint travelled. This is the height of any crease the operation creates.
  double max_seam_step_mm = 0.0;
  double rms_seam_step_mm = 0.0;
  std::size_t seam_edges = 0;

  // WHETHER THAT STEP READS AS A CREASE. A displacement is not a crease; a
  // change of SURFACE ANGLE is. So the dihedral angle across every moved/unmoved
  // edge is measured before and after, and what is reported is the CHANGE. The
  // comparison that decides "new visible defect" is against the dihedral the
  // exported surface ALREADY carries: a voxel staircase is 90-degree risers, so
  // a seam kink smaller than the terracing next to it is not a new thing to see.
  double max_seam_dihedral_change_deg = 0.0;
  double rms_seam_dihedral_change_deg = 0.0;
  // The same statistic over EVERY edge of the mesh, before the projection —
  // the yardstick the line above is read against.
  double rms_dihedral_before_deg = 0.0;
  double rms_dihedral_after_deg = 0.0;

  // "A VISIBLE CREASE AT EVERY CAD BOUNDARY" IS A COUNT, NOT AN EXTREME. A max
  // over ten thousand edges is one edge. What decides whether the operation
  // trades an old defect for a new one is HOW MANY sharp edges the surface has
  // before and after — a voxel staircase is already full of them (90-degree
  // risers joined by 45-degree marching-cubes chamfers), so an operation that
  // adds few adds nothing anyone will see.
  //
  // Counted at three explicit thresholds over EVERY manifold edge of the mesh.
  std::size_t total_edges = 0;
  std::size_t sharp45_before = 0, sharp45_after = 0;
  std::size_t sharp60_before = 0, sharp60_after = 0;
  std::size_t sharp90_before = 0, sharp90_after = 0;
  // Edges that were NOT sharp (< 45 deg) and became sharp (>= 60 deg). These are
  // the creases the operation actually created.
  std::size_t newly_sharp = 0;
  std::size_t newly_sharp_at_seam = 0;

  // THE BLOCKED-STOP CHECK, answered with data rather than a rule. The task's
  // stop condition reads "projection moves a vertex further than half a voxel —
  // that means the attribution is wrong, not that the CAD is." So for every
  // vertex that DID move further than half a voxel, we ask the question that
  // settles it: does its analytic projection still land ON the tessellated patch
  // of the very face it was attributed to? If it does, the attribution is right
  // and the distance is the density filter's inward pull, not a mistake.
  std::size_t moved_over_half_voxel = 0;
  std::size_t over_half_still_on_own_patch = 0;

  // Per-vertex displacement (mm), 0 for a vertex that did not move. Sized to the
  // mesh so a caller can histogram it.
  std::vector<double> move_mm;
  // Per-vertex: this vertex WAS projected and the fold guard put it back. It is
  // therefore NOT on its analytic surface, and any "exact" reading must exclude
  // it or say that it doesn't. Sized to the mesh.
  std::vector<char> reverted;
};

// Return `mesh` with every attributed vertex moved onto the exact analytic
// surface of its CAD face:
//
//   Plane    -> the point's orthogonal projection onto (plane_origin,
//               plane_normal). Exact.
//   Cylinder -> the point's radial projection onto the cylinder of
//               `cylinder_radius_mm` about (axis_point, axis_dir). Exact.
//   Other    -> LEFT ALONE. There is no analytic surface to project onto and
//               approximating one would be a guess.
//
// SEAM CONSTRAINT: a seam vertex (a CAD-face vertex neighbouring optimizer-cut
// surface, or a different face) is additionally held inside its own face's
// tessellated PATCH — its analytic projection is accepted only while it stays on
// the patch; otherwise the vertex is placed at the closest point of the patch,
// which for a planar face IS the exact CAD boundary. It cannot slide across a
// CAD edge onto a surface it does not belong to.
//
// Topology is untouched: the same vertex count, the same triangle indices.
TriangleMesh project_onto_cad_faces(const TriangleMesh& mesh,
                                    const StepModel& model,
                                    const CadProjectOptions& opts,
                                    const CadAttribution& att,
                                    CadProjectionStats* out_stats = nullptr);

// ---------------------------------------------------------------------------
// MEASUREMENT — the numbers the maintainer has never had.

// How round one cylindrical CAD face actually is in an exported mesh: the radii
// of every vertex attributed to it, measured about its OWN nominal axis.
struct BoreRoundness {
  int face_id = -1;
  double nominal_radius_mm = 0.0;
  std::size_t vertices = 0;
  double min_mm = 0.0, max_mm = 0.0, mean_mm = 0.0;
  double rms_error_mm = 0.0;         // rms of (measured - nominal)
  double out_of_roundness_mm = 0.0;  // max - min
};

// Measure every Cylinder face of `model` that `att` attributed any vertex to.
// `exclude` (optional, per-vertex, sized to the mesh) drops vertices from the
// reading — pass CadProjectionStats::reverted to measure the surface the
// projection actually produced rather than averaging in the vertices the fold
// guard had to put back. `out_excluded_per_face` (optional) receives, per face
// id, how many were dropped, so the exclusion is reported and not hidden.
std::vector<BoreRoundness> measure_bores(
    const TriangleMesh& mesh, const StepModel& model, const CadAttribution& att,
    const std::vector<char>* exclude = nullptr,
    std::vector<std::size_t>* out_excluded_per_face = nullptr);

// How flat one planar CAD face actually is: signed distances to its own nominal
// plane.
struct FaceFlatness {
  int face_id = -1;
  std::size_t vertices = 0;
  double max_abs_mm = 0.0;
  double rms_mm = 0.0;
  // MEAN SIGNED deviation along the face's OUTWARD normal. Positive = the
  // exported surface sits OUTSIDE the CAD plane, i.e. the part is too big there.
  // The absolute figures above cannot show that, and it is what explains a
  // change in the part's volume when the surface is put back.
  double mean_signed_mm = 0.0;
};

// Same `exclude` / `out_excluded_per_face` contract as measure_bores.
std::vector<FaceFlatness> measure_flats(
    const TriangleMesh& mesh, const StepModel& model, const CadAttribution& att,
    const std::vector<char>* exclude = nullptr,
    std::vector<std::size_t>* out_excluded_per_face = nullptr);

}  // namespace topopt
