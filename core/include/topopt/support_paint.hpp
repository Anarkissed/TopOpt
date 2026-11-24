// PAINTED SUPPORTS (his print orientation, 2026-11-23; spec 1.5, piece P3).
//
// His words: "I would ABSOLUTELY love to have manual supports drawn on the required places in the file". The part's own
// overhangs stay the slicer's business (the 11-19 rule, decision D6); the file now TELLS the slicer exactly where: the
// part's triangles under each overhang are painted as support ENFORCERS, and the file turns support on for the part
// with only the painted places supported (decision D4: Bambu Studio / OrcaSlicer "Tree (manual)", PrusaSlicer "For
// support enforcers only"). The lattice is never painted.
//
// The file side lives in the 3MF writer (threemf_stream.hpp: Options::supports, add_indexed with a paint flag).
#pragma once

#include <cstddef>
#include <functional>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

struct SupportPaintAsk {
  double layer_mm = 0.2;       // the printer's layer
  double line_mm = 0.45;       // the printer's line width
  double down_deg = 45.0;      // a triangle faces down when its outward normal is more than this from the bed's normal
  double grow_deg = 5.0;       // the paint grows over an edge only to a neighbour turned at most this much
  // Only triangles [0, first_not_part) are the part's (a lattice file's base triangles; the shells after are never
  // painted). 0: every triangle is the part's.
  std::size_t part_triangles = 0;
  // The places that need support (the layer check's own overhangs of the part, x y z). Given: only the down-facing part
  // triangles within reach of a place are painted, and what joins them across an edge (grow_deg). Null: every down-
  // facing part triangle above the bed is painted (a topology result: no layer check, the 45 degree rule).
  const std::vector<Vec3>* places = nullptr;
  // True where the point is outside the part (air): a triangle is painted only with air one layer below it (never over
  // the lattice, nor over the part's own material). Null: every point below a down-facing face counts as air.
  std::function<bool(const Vec3&)> outside;
};

struct SupportPaint {
  std::vector<char> painted;      // per triangle of the mesh
  std::size_t triangles = 0;      // painted
  std::size_t places = 0;         // places that painted at least one triangle
  std::size_t places_unpainted = 0;
  double area_mm2 = 0.0;          // painted area
  // The support the slicer would lay under them (the part only): each painted triangle's area seen from below times
  // its drop to the first material below or to the bed. An estimate.
  double est_volume_mm3 = 0.0;
  std::vector<Vec3> at;           // the places that painted (as given)
  double z_bed = 0.0;
};

// Up is +Z (the print frame, print_frame.hpp). Deterministic, no threads.
SupportPaint paint_supports(const TriangleMesh& mesh, const SupportPaintAsk& ask);

}  // namespace topopt
