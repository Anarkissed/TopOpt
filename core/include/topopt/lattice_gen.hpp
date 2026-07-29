#pragma once

// Strut-lattice GENERATOR (handoff 2026-07-28-lattice-generation-production).
//
// This is the PRODUCTION home of the octet-truss generator that PR 201 measured
// as a Phase-0 study in core/tests/harness/octet_gen_probe.cpp and a physical
// print then certified. It is NOT the certification library (topopt/lattice.hpp);
// that one carries a latticed element's homogenized STIFFNESS through the solver.
// This one builds the printable GEOMETRY: it meshes each octet strut as a swept
// solid (a capped n-gon prism) and each node as an icosahedron, then unions them
// as an interpenetrating triangle soup that a slicer accepts (the union PR 201
// closed on a real print). No marching cubes, no occupancy field — swept solids.
//
// Two properties are load-bearing and preserved verbatim from the harness:
//
//   STREAMING. The generator pushes triangles to a TriangleSink one at a time and
//   holds no global state, so a sink that flushes to disk keeps peak RSS flat in
//   OUTPUT SIZE. This rests on CELL-LOCAL OWNERSHIP: each strut / node is emitted
//   by exactly one cell (integer half-coordinate keying, no global dedup set), so
//   the traversal is a single fixed-order sweep with O(1) live memory.
//
//   DETERMINISM. Fixed traversal order, no RNG, no threads, no float atomics ->
//   the same inputs produce a byte-identical file.
//
// SCOPE (this task): OCTET ONLY, matching topopt/lattice.hpp's certification enum.
// The radius/DENSITY field is an INPUT — uniform, or an externally supplied
// callback. How that field is DERIVED from stress (the grading law) is a separate
// task, held until the certifiable density band is measured. This proves the
// pipeline carries a field; it does not invent one.

#include <cstdint>
#include <functional>
#include <stdexcept>

#include "topopt/mesh.hpp"  // Vec3, TriangleSink

namespace topopt {

// The strut-lattice topologies. Only Octet is implemented this task (the printed,
// certified one); the enum leaves room for the rest exactly as lattice.hpp does.
enum class LatticeGenTopology { Octet };

// Human-readable name ("octet"), stable for run_info / job serialization.
const char* lattice_gen_topology_name(LatticeGenTopology topo);

// The lattice REGION: a rectangular block of nx*ny*nz cubic cells of edge
// `cell_mm`, its (i=0,j=0,k=0) corner at `origin` (model mm). Cell (ci,cj,ck) is
// latticed iff `latticed(ci,cj,ck)` returns true; a null predicate means EVERY
// cell (a full block — the harness's frac=1 case). Because ownership is
// cell-local, this occupancy predicate ALONE decides which struts and nodes are
// emitted (a leg shared with a non-latticed neighbour is emitted once, at the
// region boundary), with no global set — the streaming requirement.
struct LatticeRegion {
  Vec3 origin{0.0, 0.0, 0.0};
  int nx = 0;
  int ny = 0;
  int nz = 0;
  double cell_mm = 0.0;
  std::function<bool(int, int, int)> latticed;  // null => all cells latticed
};

// The strut RADIUS field (mm). `field`, when set, is called at each strut/node
// MIDPOINT (model mm) and its return is used as the radius; otherwise `uniform_mm`
// is used everywhere. `nseg` is the strut cross-section polygon segment count
// (8 = the octagonal prism the harness measured and printed). This is the
// externally-supplied field the pipeline must CARRY; the grading law is elsewhere.
struct LatticeRadiusField {
  double uniform_mm = 0.0;
  std::function<double(Vec3)> field;  // null => uniform_mm everywhere
  int nseg = 8;
  double radius_at(const Vec3& midpoint) const {
    return field ? field(midpoint) : uniform_mm;
  }
};

// What one generation pass emitted — counts for the run_info record and the
// self-checks. Triangle counts are exact (strut = 4*nseg tris, node = 20 tris).
struct LatticeGenStats {
  std::uint64_t triangles = 0;
  std::uint64_t strut_triangles = 0;
  std::uint64_t node_triangles = 0;
  std::uint64_t struts = 0;
  std::uint64_t nodes = 0;
  long long latticed_cells = 0;   // cells the predicate accepted
  double min_strut_diameter_mm = 0.0;
  double max_strut_diameter_mm = 0.0;
};

// Count the cells the region's predicate accepts (the achieved latticed-cell
// count; a discretised grid cannot hit an arbitrary target region exactly).
long long latticed_cell_count(const LatticeRegion& region);

// Generate `topo` over `region` with `radius`, pushing every triangle to `sink`
// in a fixed traversal order, and return the emitted counts. Deterministic (no
// RNG / threads / global state), so a streaming sink writes a byte-identical file
// for identical inputs. Throws std::invalid_argument if `topo` is not Octet, if
// the region is degenerate (nx/ny/nz < 1 or cell_mm <= 0), if nseg < 3, or if a
// non-positive radius is produced. `sink` may stream to disk (flat peak memory)
// or accumulate a MeshSink (bounded meshes / tests).
LatticeGenStats generate_lattice(LatticeGenTopology topo,
                                 const LatticeRegion& region,
                                 const LatticeRadiusField& radius,
                                 TriangleSink& sink);

}  // namespace topopt
