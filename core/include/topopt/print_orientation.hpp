// THE PRINT ORIENTATION RANKING (his print orientation, 2026-11-23; spec 2e, piece P4).
//
// His words: Results offers "Print orientation recommendation", which "will then take into account the "Gravity"
// position the user put as well as the shape of the part and decide which orientation is best ... it should also take
// into account layer lines and orientation and guessed strength for the orientation recommendation!"
//
// Phase 1 (decision D5): the candidates are the part's six axes (each with a flat face square to it on the bed), in the
// frame the job ran in, its own up (+Z: as placed, or the chosen face) first. Per candidate:
//   strength  the solid's margin with its layers across that up (EXACT from the one stress solve: the solve does not
//             read the build direction) and the struts' smallest margin with the rise along it (the same forces; an
//             ESTIMATE: a lay along that up would grow other struts, decision D2); the guessed strength is the least;
//   support   the part's own support (the voxel estimate: never under the lattice, never the lattice's own);
//   height    and layers (decision D3: no print time);
//   bed       the flat face on the bed, and whether the centre of mass stands over it.
// The rule is recommend_print_orientation (build_orientation.hpp), the one rule.
#pragma once

#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

struct VoxelGrid;
struct PrintFrame;

// The six candidates, in the job's own frame: +Z (as placed) first, then -Z, +X, -X, +Y, -Y.
const std::array<Vec3, 6>& orientation_axes();

// What the strength check knows per candidate (NaN: not known).
struct OrientationStrength {
  double solid = 0.0;              // the solid's effective margin (the gate's), layers across the up
  double solid_interlayer = 0.0;   // its layer margin alone
  double struts = 0.0;             // the struts' smallest margin (estimate)
  std::size_t struts_under = 0;    // struts under the safety margin (estimate)
  double support_mm3 = 0.0;        // the part's own support (voxel estimate)
};
struct OrientationStrengths {
  bool known = false;
  double required_margin = 1.5;
  std::array<OrientationStrength, 6> by_axis{};
  Vec3 centre_of_mass{};
  bool has_centre_of_mass = false;
};

// The part's own support along a grid axis (axis 0 x, 1 y, 2 z; `up_sign` +1 or -1), mm3: under every printed-solid
// voxel (`solid`) whose voxel below is not part (`in_part`: solid or lattice) and that no part voxel holds within the
// 45 degree cone below, the voxels down to the first part voxel or the bed (the lowest part layer along that up).
double support_along_axis(const VoxelGrid& grid, const std::vector<char>& in_part, const std::vector<char>& solid,
                          int axis, int up_sign);

// What the file's mesh says per candidate: its height, its flat face on the bed (triangles facing straight down within
// 1 degree at the lowest point, to 0.01 mm) and that face's outline (the convex hull of its corners, in the two other
// axes).
struct OrientationGeometry {
  double height_mm = 0.0;
  double contact_mm2 = 0.0;
  std::vector<std::array<double, 2>> hull;   // counter-clockwise
};
std::array<OrientationGeometry, 6> orientation_geometry(const TriangleMesh& mesh);
// Whether `p` stands over candidate `k`'s face (its projection inside the hull, within `tol` mm).
bool stands_over(const OrientationGeometry& g, int k, const Vec3& p, double tol = 0.5);

// The ranking and the recommendation as the report's block ("print_orientation"); every up in the MODEL frame (`frame`
// turns the job's frame back; off: the same). `layer_mm` for the layers.
std::string print_orientation_json(const OrientationStrengths& s, const std::array<OrientationGeometry, 6>& g,
                                   const PrintFrame& frame, double layer_mm);

// ── PHASE 2 (his 11-23 evening: "I *would* add the 45 degree sides in this run", then "Both - flat sides and edges
// held by supports") ────────────────────────────────────────────────────────────────────────────────────────────────
// The candidates are every face of the part's convex hull it can rest on (coplanar hull facets merged; the 45 degree
// sides of his stand among them), and every hull EDGE between two such faces, the part tilted so the edge is lowest
// and both faces lean equally (up = -(n1 + n2) / |n1 + n2|; a right-angle edge gives two 45 degree faces). An edge has
// almost no bed contact: it stands only HELD BY SUPPORTS, painted bands on both faces next to the edge, widened until
// the footprint holds the centre of mass with a margin (orientation_stand, the ONE "must stand" place). Every number
// is here, in one place, so he can change it.
struct CandidateRule {
  double plate_min_mm2 = 5.0;       // spec 2d: a hull face under 5 mm2 is no face
  double plate_min_side_mm = 1.0;   // ... nor one under 1 mm across
  double coplanar_deg = 0.5;        // hull facets this close in angle, and
  double coplanar_mm = 0.02;        // ... this close in offset, are one face
  int faces_max = 30;               // the largest faces kept (the rest counted, never silent)
  double edge_min_mm = 10.0;        // 362's proposal (11-23 23:00): an edge at least 10 mm long
  int edges_max = 30;               // ... the 30 longest kept (the rest counted)
  double stand_margin_mm = 5.0;     // the centre of mass at least 5 mm inside the footprint
  double band_step_mm = 1.0;        // stand-support bands widened 1 mm at a time
  double band_min_mm = 2.0;         // ... and never under 2 mm on either face
  double face_stands_tol_mm = 0.0;  // a face stands when the centre of mass is over it (no margin: D1)
};
struct OrientationCandidate {
  enum class Kind { Lowest, Face, Edge };   // Lowest: as placed on neither a hull face nor an edge (its lowest points)
  Kind kind = Kind::Lowest;
  bool as_placed = false;       // his placement (the job's own +Z): the first candidate
  Vec3 up{0.0, 0.0, 1.0};       // in the job's own frame
  double contact_mm2 = 0.0;     // the part's own triangles lying on the bed plane (an edge: 0)
  double plate_mm2 = 0.0;       // the hull face's area (a face)
  double height_mm = 0.0;       // the part's extent along the up
  std::vector<Vec3> plate;      // a face: its outline on the hull (job frame), counter-clockwise seen from outside
  // An edge: its two ends, its two faces' outward normals, how far each face reaches from it (in the face).
  Vec3 e0{}, e1{}, n1{}, n2{};
  double w1 = 0.0, w2 = 0.0;
  // orientation_stand:
  bool stands = true;
  bool held_by_supports = false;   // an edge (it stands on its stand supports)
  double band1_mm = 0.0, band2_mm = 0.0;   // the bands' widths on the two faces
  double stand_area_mm2 = 0.0, stand_support_mm3 = 0.0;
};
struct OrientationCandidates {
  std::vector<OrientationCandidate> list;   // as placed first
  bool hull = false;                        // the hull was made (false: the six axes only)
  std::size_t faces_small = 0, faces_over_cap = 0, edges_short = 0, edges_over_cap = 0;
};
// From the part's triangles (the first `part_triangles` of `mesh`; 0: all), in the job's own frame.
OrientationCandidates print_candidates(const TriangleMesh& mesh, std::size_t part_triangles = 0,
                                             const CandidateRule& rule = CandidateRule{});
// THE "must stand" (D1, with his edges): a face stands when the centre of mass, seen along the up, is over its outline;
// an edge when bands of stand supports on its two faces (each at least band_min_mm, widened band_step_mm at a time up
// to the face's own reach) give a footprint (the edge plus the bands seen from above) holding the centre of mass with
// stand_margin_mm all round; the bands' area and the support under them are set. As placed: as the face or edge it
// is, else over the part's lowest triangles.
void orientation_stand(OrientationCandidate& c, const Vec3& centre_of_mass, const CandidateRule& rule = CandidateRule{});
// The part's own support along any up (voxels; support_along_axis's rule with the 45 degree cone read at four points).
double support_along(const VoxelGrid& grid, const std::vector<char>& in_part, const std::vector<char>& solid, const Vec3& up);
// The volume centroid of a closed mesh's first `part_triangles` (0: all): the centre of mass of the solid.
Vec3 mesh_centroid(const TriangleMesh& mesh, std::size_t part_triangles = 0);
// The block for the candidates (strengths per candidate in s.by_up, same order); `layer_mm` for the layers.
struct OrientationStrengthsN {
  bool known = false;
  double required_margin = 1.5;
  std::vector<OrientationStrength> by_up;
  Vec3 centre_of_mass{};
  bool has_centre_of_mass = false;
};
std::string print_orientation_json(const OrientationStrengthsN& s, OrientationCandidates& c, const PrintFrame& frame,
                                   double layer_mm, const CandidateRule& rule = CandidateRule{});
// A part resting on an edge (`c`, orientation_stand done): its stand supports cut into the mesh and painted, as the
// overhangs are (support_paint.hpp). The part's triangles (the first `part_triangles`) crossed by a band's edge are split
// along it (their neighbours too, so no point is left on an edge); the new pieces follow the part's triangles (the
// part's count grows by `added`; anything after the part, a lattice's shells, keeps its order); `painted` per triangle
// of the mesh returned.
struct StandPaint {
  std::vector<char> painted;
  std::size_t added = 0, triangles = 0;
  double area_mm2 = 0.0;
};
StandPaint paint_stand_supports(TriangleMesh& mesh, std::size_t part_triangles, const OrientationCandidate& c);

}  // namespace topopt
