#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

namespace topopt {

// ---------------------------------------------------------------------------
// Mesh segmentation into PSEUDO-FACES (STL/3MF import, handoff 134).
//
// A STEP file carries B-rep faces, and the whole downstream flow — tap
// selection, anchor/load groups, keep-clear, protect, the design box — is keyed
// on a face id (`StepModel::triangle_face` + `StepModel::faces`). A triangle
// soup has no faces at all, so an imported STL is inert: every tap misses.
//
// This segmenter MANUFACTURES the missing faces. It partitions the triangles
// into maximal regions whose neighbours meet across a shallow dihedral angle,
// which is exactly the "smooth patch bounded by a crease" a human means by
// "that face". The output is shaped as the SAME StepFaceInfo the STEP importer
// produces, so `import_part_file` can hand downstream code a StepModel it
// cannot distinguish from a tessellated B-rep. That is the contract: the
// selection SOURCE is pluggable, the face id is the interface, and nothing
// downstream changes. (This header therefore includes step.hpp deliberately —
// reusing that type is the point, not an accident of layering.)
//
// DETERMINISM (a hard requirement — pseudo-face ids are persisted in a project
// and must survive a re-import of the same file). Every choice is fixed:
//   * seeds are visited in ASCENDING triangle index order;
//   * the frontier is a FIFO queue, so growth order is fully determined;
//   * each triangle's three edges are walked in the fixed order
//     (v0,v1), (v1,v2), (v2,v0);
//   * each edge's incident triangles are visited in ascending triangle index;
//   * region ids are handed out in seed order, starting at 0.
// No hashing, no floating-point-keyed containers, no parallelism. Same triangle
// list => same ids, bit for bit. The STL reader welds vertices through an
// ordered std::map keyed on exact coordinates, so the triangle list itself is a
// pure function of the file bytes; `import_part_file` welds 3MF the same way.

// Controls for `segment_mesh_faces`.
struct SegmentOptions {
  // Two edge-adjacent triangles join the same pseudo-face iff the angle between
  // their unit normals is <= this. A crease sharper than the threshold is a
  // face boundary.
  //
  // SHIPPED VALUE 35 deg. The value is bounded from both sides, and both bounds
  // were MEASURED by the sweep in handoff 134 (evidence/134/threshold_sweep.txt,
  // reproducible via the `segment_evidence` target) rather than reasoned about:
  //
  //   LOWER — it must exceed the per-facet turn of a reasonably tessellated
  //   curved surface, or barrels shatter. A 12-gon cylinder (30 deg/facet)
  //   segments to 3 faces at 35 deg but to 9 at 30 deg. So: strictly above 30.
  //
  //   UPPER — it must stay below the shallowest crease real CAD uses, or
  //   features get swallowed. A 45-deg chamfered box holds at 7 faces through
  //   45 deg and collapses to 5 at 50 deg. So: at most 45.
  //
  // The admissible window is therefore (30, 45]. 35 sits inside it with margin
  // on both sides. On the three reference meshes the region count is FLAT from
  // 20 to 60 deg — on real parts this choice is nowhere near knife-edge, which
  // is why the window's ends had to be found with synthetic cases.
  //
  // KNOWN CAVEAT, stated rather than hidden: a curved surface tessellated more
  // coarsely than ~2*180/35 ~= 10 facets per revolution turns MORE than the
  // threshold per facet, so its barrel fragments into facet-sized pseudo-faces.
  // An 8-sided cylinder (45 deg per facet) does this. Raising the threshold to
  // absorb it would start swallowing real chamfers, so the segmenter takes the
  // fragmentation and the caveat instead.
  double dihedral_threshold_deg = 35.0;

  // Second-stage guard against the ONE failure the pure local-dihedral rule
  // cannot see: a flat face LEAKING through a smoothly-tessellated fillet or
  // chamfer into a face a human reads as distinct. The shelf-bracket failure
  // that motivated paint mode (handoff 2026-07-24) was exactly this — a chamfered
  // bolt-hole rim gives a chain of sub-threshold facet steps from the flat top
  // face down into the bore, so region growing walks straight across the crease
  // a human sees, and one tap on the hole selects the top (Load) face too.
  //
  // The rule is SELECTIVE, and that is the whole point. When a region is SEEDED
  // on a locally flat triangle (all its edge-neighbours within
  // `plane_tolerance_deg`, i.e. it sits on a planar plateau), the region may only
  // absorb a triangle whose normal is within this cone of the SEED normal. A flat
  // face grows to its own crease and stops; the fillet's normal tilts away from
  // the seed and, once past this cap, is refused — so the leak is cut at the
  // fillet instead of running through it. A region seeded on a CURVED triangle
  // (a barrel, a blob) does not arm the cone at all and grows by pure dihedral
  // exactly as before, so genuinely curved surfaces are never fragmented by it.
  //
  // MEASURED (evidence/2026-07-24-mesh-selection-paint/): at the shipped 40 deg
  // this is a NO-OP on all three handoff-134 reference meshes (their flats meet
  // at sharp >cap creases, their curved faces have curved seeds) and on the demo
  // L-bracket — region counts are byte-identical — and it splits the committed
  // chamfered-hole fixture's top face away from its bore. Because it changes no
  // reference id, existing sharp-edged mesh projects keep their persisted
  // pseudo-face ids; only a part that WAS leaking (already unusable) re-segments.
  //
  // <= 0 disables the cone entirely (pure local-dihedral growth, the exact
  // handoff-134 behaviour). The admissible values are (0, 180).
  double planar_region_cone_deg = 40.0;

  // A region is classified Plane iff every triangle normal in it is within this
  // of the region's area-weighted mean normal. Tight: a planar face's facets
  // are exactly parallel up to the file's float precision.
  double plane_tolerance_deg = 1.0;

  // A region is classified Cylinder iff it is not planar, every normal is
  // within this of perpendicular to the fitted axis, and the least-squares
  // circle fit is tight (see `cylinder_radius_tolerance`).
  double cylinder_tolerance_deg = 5.0;

  // Max relative RMS residual of the circle fit (residual / radius) for a
  // region to be accepted as a Cylinder. A sphere or a cone passes the
  // axis-perpendicularity test in places but fails this.
  double cylinder_radius_tolerance = 0.05;

  // A fitted radius larger than this many times the MESH's bounding-box
  // diagonal is rejected, and the region falls back to Other.
  //
  // This is a physical bound, not a numerical one: a cylindrical feature of a
  // part cannot be meaningfully larger than the part. Without it, a nearly-flat
  // region — say a flat wall that merged with the coarse rounded corner next to
  // it — fits a huge, almost-straight circle with a small relative residual and
  // passes as a Cylinder. That misclassification is not cosmetic: a bolt
  // keep-clear tapped on such a face would sweep a keep-out of that bogus
  // radius. Found on the handoff-134 reference bracket, where a 60 mm plate's
  // side fit as a 140 mm cylinder.
  //
  // TIGHTENED 1.0 → 0.5 (handoff 2026-07-29, clearance-heuristic-fix). At 1.0
  // the ceiling was the WHOLE bbox diagonal, so on the 290 mm WallMount shelf
  // bracket a nearly-flat outer edge fit a 221 mm "cylinder" (r/diag 0.77) and
  // passed — feeding the auto-clearance finder a Ø443 mm bolt keep-out on a
  // 20 mm-thick plate (the "135 mm axial", now 443 mm, that got the heuristic
  // flagged). A cylinder wider than HALF the part's space diagonal is not a
  // feature of the part; 0.5 rejects those flat-wall misfits (the bracket's
  // 0.77 and 0.69 fits fall back to Other) while leaving every real bore
  // untouched — the widest genuine bore across the mesh fixtures is the
  // filleted-plate rim at r/diag 0.35, well under 0.5, so all fixtures whose
  // classification was already correct are byte-identical (evidence 2026-07-29).
  double max_cylinder_radius_span = 0.5;
};

// The manufactured face partition. Shaped to drop straight into StepModel.
struct MeshSegmentation {
  // Pseudo-face id per triangle, parallel to `mesh.triangles`, values in
  // [0, face_count). Same role and same invariants as StepModel::triangle_face.
  std::vector<int> triangle_face;
  int face_count = 0;
  // Per-pseudo-face surface geometry, indexed by face id (size face_count).
  // Planes and cylinders are FITTED from the triangles, so keep-clear (which
  // needs a cylinder axis + radius) and face clearance (which needs an outward
  // plane normal) work on a mesh import exactly as they do on STEP.
  std::vector<StepFaceInfo> faces;
};

// Partition `mesh` into pseudo-faces by dihedral-angle region growing and fit
// each region's surface. `mesh` must have welded (shared) vertices — the walk
// is over shared-EDGE adjacency, so an unwelded soup yields one region per
// triangle. An empty mesh yields an empty segmentation (face_count == 0).
//
// Degenerate triangles (repeated vertex index, or zero area) have no meaningful
// normal; they are assigned to the region of the first non-degenerate neighbour
// that reaches them, or to a region of their own if isolated, so
// `triangle_face` is always total over the triangle list.
//
// Throws std::invalid_argument if dihedral_threshold_deg is outside (0, 180).
MeshSegmentation segment_mesh_faces(const TriangleMesh& mesh,
                                    const SegmentOptions& opts = {});

// ---------------------------------------------------------------------------
// Small deterministic linear-algebra helpers the fit needs. Exposed for tests
// (and because the core's Eigen dependency is optional — segment.cpp is built
// on every platform, including the OCCT/Eigen-free iOS slice, so it cannot use
// Eigen).

// Fit ONE pseudo-face's surface geometry from its triangle set — the same
// area-weighted plane test and Kasa cylinder fit `segment_mesh_faces` runs per
// region, factored out so a PAINTED face (an arbitrary triangle set, handoff
// 2026-07-24) is classified and measured identically. `tris` are indices into
// `mesh.triangles`; `bb_diag` is the mesh bounding-box diagonal, the physical
// bound on a fitted cylinder radius. An empty `tris` yields a default (Other)
// StepFaceInfo. Deterministic: the accumulation order is `tris`' own order, and
// the circle fit sorts its vertex set.
StepFaceInfo fit_pseudo_face(const TriangleMesh& mesh, const std::vector<int>& tris,
                             const SegmentOptions& opts, double bb_diag);

// Eigen-decomposition of a symmetric 3x3 matrix by cyclic Jacobi rotations.
// `a` is row-major [9]. On return `values[i]` are the eigenvalues in ASCENDING
// order and `vectors` holds the corresponding unit eigenvectors as ROWS
// (vectors[3i .. 3i+2] belongs to values[i]). Deterministic: a fixed sweep
// count and a fixed rotation order.
void symmetric_eigen3(const double a[9], double values[3], double vectors[9]);

}  // namespace topopt
