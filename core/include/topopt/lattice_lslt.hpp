#pragma once
// ── LSLT: a watertight analytic triangulation for the organic beam lattice ────
//
// Replaces the marching-cubes weld for the lattice body. The weld samples a voxel
// field, so its cost scales with the part's BOUNDING BOX: on the M2 stand the raster
// cap forces a pitch of ~0.39 mm against struts 0.84 mm across, and the result is the
// staircase the maintainer rejected. This meshes each beam ANALYTICALLY, so cost
// scales with the STRUT COUNT and the surface is exact to a stated chord error however
// large the part is.
//
// METHOD — Chougrani, Pernot, Veron & Abed, "Lattice structure lightweight
// triangulation for additive manufacturing", Computer-Aided Design 90:95-104 (2017),
// DOI 10.1016/j.cad.2017.05.016. The three parts that matter:
//
//  1. THE INTERFERENCE PLANE. Two cylinders of equal radius whose axes meet at a node
//     intersect in a curve that lies exactly on a PLANE through the node with normal
//     (d1 - d2): a point on both satisfies |x|^2 - (x.d1)^2 = |x|^2 - (x.d2)^2, hence
//     x.(d1 - d2) = 0. So the expensive cylinder-cylinder intersection is never
//     computed -- a plane stands in for it, in closed form.
//
//  2. THE SPECIAL BOOLEAN. Rather than cutting triangles and re-meshing (which adds
//     triangles and breaks connectivity), each section vertex is PUSHED ALONG ITS OWN
//     BEAM AXIS onto that plane. Triangle count and connectivity are preserved exactly;
//     only positions move. Paper's eq. (10).
//
//  3. MANDATORY VERTICES (paper 3.1). For each PAIR of beams at a node, the two points
//     N_i +/- R_i * (d_ik x d_ij)/||d_ik x d_ij|| lie on BOTH cylinders and on the node
//     sphere -- they are where the interference curve crosses it. Putting them in BOTH
//     sections as the SAME mesh vertex is what connects the rings into one surface: the
//     gaps between arms then become genuine holes bounded by arcs of several rings, and
//     one fill closes the joint instead of a cone cap per arm.
//
//  4. HOLE FILLING. Pushing opens holes at the joints. Every boundary loop is closed by
//     fanning it to its own barycentre projected onto the node's sphere of radius R_i
//     (eq. 16). Chougrani proves that sphere is the MINIMUM surface on which the
//     interference vertices can lie (eqs. 7-9), so the projection never pulls a vertex
//     inside the solid.
//
// WHAT WE DO DIFFERENTLY, and why. Chougrani assumes one radius per node ("a unique
// radius R_i ... defines the common radius of all the sections connected to it"). Our
// struts vary: measured on the M2 stand, the radii meeting at a node differ by a median
// of 14 % and a p99 of 58 %. We keep each beam's own radius on its own section and take
// R_i = max over the incident beams for the node sphere, which is the smallest sphere
// that still contains every section. That is the variable-radius case Virtual-Trim
// (J. Comput. Design Eng. 11(2):345-364, 2024) treats with frusta; the plane above is
// then an approximation rather than exact, and the hole filling is what keeps the mesh
// closed regardless.
//
// VIRTUAL-TRIM'S TWO ADDITIONS, both built here because both target the joints:
//
//  A. NODE CLOSURE (their 4.3). A node is "closed" only if the union of its struts'
//     half-spaces covers the whole sphere; if some direction x has d_i . x <= 0 for
//     EVERY strut, the arms leave a gap that no amount of trimming can reconcile. They
//     pose it as an LP feasibility problem; the same condition is that the strut
//     directions POSITIVELY SPAN R^3, i.e. the origin lies inside their convex hull, so
//     it is solved here by minimising max_i (d_i . x) over the unit sphere. A negative
//     minimum both detects the gap and points along it. Such a node's ring vertices are
//     then EXTENDED along their own beams (their eq. 6-7, d = 2 x node radius) so the
//     arms reach far enough to be closed.
//
//  B. MATCHING THE TRIMMED POINTS (their 4.5). Ring vertices are generated per strut and
//     so do not line up between struts; for each, the mutually-nearest vertex on ANOTHER
//     strut at the same node is found and both are moved to their midpoint. That is the
//     published fix for gaps between adjacent arms.
//
// KNOWN LIMIT, stated because the papers state it: two beams meeting at a very shallow
// angle interfere OUTSIDE the node sphere, and neither the plane push nor the hole fill
// removes that overlap. The mesh stays closed; it is not guaranteed self-intersection
// free. Virtual-Trim's E-REDP extension is the published fix.

#include <cstddef>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/organic_lattice.hpp"

namespace topopt {

struct LsltOptions {
  // Chord error as a FRACTION OF THE RADIUS. The section vertex count follows from it
  // and is therefore the same for every beam however thick, which is what makes one
  // global count correct rather than a compromise: e = 1 - cos(pi/N).
  double chord_error_ratio = 0.05;   // 5 %, the paper's own figure
  int min_section_vertices = 6;
  int max_section_vertices = 64;
  // Endpoints closer than this are the same node.
  double weld_tol_mm = 1e-4;
};

struct LsltStats {
  std::size_t beams = 0;
  std::size_t nodes = 0;
  std::size_t sections = 0;      // rings; fewer than 2 x beams wherever a joint welded
  int section_vertices = 0;          // N, from the chord error
  std::size_t vertices_pushed = 0;   // section vertices moved onto an interference plane
  std::size_t mandatory_vertices = 0;  // shared between the two sections of each pair
  std::size_t joints_stitched = 0;     // valence >= 3 nodes closed as ONE joint
  std::size_t edges_swept = 0;         // boundary the umbrella walk could not trace
  // ★ Virtual-Trim 4.3: nodes whose struts do not between them cover the node sphere.
  std::size_t nodes_unclosed = 0;
  std::size_t vertices_extended = 0;
  // ★ Virtual-Trim 4.5: ring vertices on DIFFERENT struts that were mutually nearest and
  // were merged to their midpoint, closing the gap between adjacent arms.
  std::size_t vertices_matched = 0;
  std::size_t holes_filled = 0;
  std::size_t hole_triangles = 0;
  std::size_t triangles = 0;
  std::size_t boundary_edges_left = 0;   // MUST be 0: the mesh is closed or it is not
  bool watertight = false;
  double volume_mm3 = 0.0;
  int max_valence = 0;
};

// `spans` are the emitted beams (a, b, radius). Degenerate spans are dropped.
TriangleMesh lattice_lslt(const std::vector<OrganicSpan>& spans,
                          const LsltOptions& opt, LsltStats& stats);

}  // namespace topopt
