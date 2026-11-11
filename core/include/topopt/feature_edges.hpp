#pragma once

// ★ FEATURE EDGES OF A SHIPPED SURFACE (the reviewer's ruling 11-08 (A): a rim on a real
// part). The rim rides the SHARP edges of the surface the file actually carries -- the
// CAD-projected / smoothed shell, or the part's own mesh when the part itself is latticed
// -- never the voxel grid, on which every staircase step would read as an edge.
//
// An edge is a feature edge when the angle between its two faces' normals exceeds the
// threshold (the reviewer's start: 30 degrees; the receipt states it). This is the
// standard dihedral test (CGAL Polygon Mesh Processing, detect_sharp_edges). Feature edges
// are joined into chains: a chain runs between vertices where the feature graph does not
// simply continue (a corner where three or more feature edges meet, or an end), or round a
// closed loop. Chains that meet at a corner belong to one connected piece, and a piece
// shorter in total than `min_piece_mm` (one cell) is dropped and counted: a rim shorter
// than a cell is a bump, not a rim.
//
// The mesh is welded by position first (an STL is a triangle soup). An edge with one face
// (an open boundary) or more than two (non-manifold) has no dihedral angle and is skipped
// and counted, never guessed.

#include <cstddef>
#include <vector>

#include "topopt/mesh.hpp"  // Vec3, TriangleMesh

namespace topopt {

struct FeatureChain {
  // The chain's points in order (welded positions). For a closed loop the first point is
  // NOT repeated at the end; `closed` says it wraps.
  std::vector<Vec3> points;
  // Per segment i (points[i] -> points[i+1], wrapping for a closed loop): the unit outward
  // normals of the face on its LEFT and its RIGHT (left = the face whose winding runs
  // points[i] -> points[i+1]), and the dihedral angle between them in degrees.
  std::vector<Vec3> left_normal, right_normal;
  std::vector<double> angle_deg;
  // Whether the edge is CONVEX (the material lies inside the wedge the two faces make,
  // e.g. a box's outer edge) or concave (a re-entrant corner).
  std::vector<char> convex;
  bool closed = false;
  double length_mm = 0.0;
  int piece = 0;  // the connected piece (through corners) the chain belongs to
  std::size_t segments() const { return closed ? points.size() : points.size() - 1; }
};

struct FeatureEdgeStats {
  double angle_threshold_deg = 0.0;
  double min_piece_mm = 0.0;
  std::size_t welded_vertices = 0;
  std::size_t edges = 0;            // manifold edges (exactly two faces)
  std::size_t open_edges = 0;       // one face: no angle, skipped
  std::size_t nonmanifold_edges = 0;// more than two faces: skipped
  std::size_t feature_edges = 0;    // over the threshold
  std::size_t chains = 0;           // kept
  std::size_t pieces = 0;           // kept connected pieces
  std::size_t pieces_dropped_short = 0;
  std::size_t chains_dropped_short = 0;
  double length_mm = 0.0;           // kept
  double length_dropped_mm = 0.0;
};

// The feature chains of `mesh` at `angle_threshold_deg`, pieces shorter than
// `min_piece_mm` dropped. Deterministic: chains are ordered by their first point's welded
// index, and walked in index order.
std::vector<FeatureChain> mesh_feature_chains(const TriangleMesh& mesh,
                                              double angle_threshold_deg,
                                              double min_piece_mm,
                                              FeatureEdgeStats* stats = nullptr);

}  // namespace topopt
