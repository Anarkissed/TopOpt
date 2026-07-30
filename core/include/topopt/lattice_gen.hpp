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
#include <string>
#include <vector>

#include "topopt/mesh.hpp"  // Vec3, TriangleSink

namespace topopt {

class LatticeBoundary;  // topopt/lattice_boundary.hpp — the shared predicate

// The strut-lattice topologies. Only Octet is implemented this task (the printed,
// certified one); the enum leaves room for the rest exactly as lattice.hpp does.
// (Explicit underlying type so the enum-probe tripwire in test_lattice_gen can
// legally test values beyond the last case.)
enum class LatticeGenTopology : int { Octet };

// Human-readable name ("octet"), stable for run_info / job serialization.
// Throws std::logic_error for an enum value with no name — a new case must be
// named here before anything can serialize it (never a silent fallback).
const char* lattice_gen_topology_name(LatticeGenTopology topo);

// The names of every GENERATABLE topology, in enum order — the single source the
// app bridge reads so its picker set can never drift from this enum (the exact
// counterpart of lattice_certifiable_topology_names(), which the certification
// library already exposes; handoff 2026-07-30-lattice-page reported this one
// missing). test_lattice_gen's enum-probe tripwire fails if a new enum case is
// named in lattice_gen_topology_name but not enumerated here.
std::vector<std::string> lattice_gen_topology_names();

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

  // The boundary finish (handoff 2026-07-29-lattice-boundary-finish). Null =>
  // the legacy whole-strut behaviour, byte-identical to every pre-boundary run.
  // Non-null => (a) a cell is ACTIVE iff `latticed` accepts it AND the boundary
  // cannot prove the cell misses the allowed region (activation by OVERLAP, so
  // partial boundary cells are generated rather than dropped whole), and (b)
  // every strut centreline is CLIPPED to the allowed region eroded by that
  // strut's own radius, so the swept SOLID stays inside the part — never just
  // the centreline. Must outlive the generate_lattice call.
  const LatticeBoundary* boundary = nullptr;
};

// Boundary SKIN (requirement (c)). None => interior lattice only (plus the
// clipping above). Rim => just the edge loops where boundary faces meet (and
// collar rim tori on protected bores). Diagrid => rim PLUS a 2D lattice on the
// boundary faces whose nodes are ANCHORED at the exact points where clipped
// interior struts meet the surface (their landings), linked into ring + both
// diagonal families — so no clipped end is left floating (bar B6).
enum class LatticeSkinMode { None, Rim, Diagrid };

struct LatticeSkinSpec {
  LatticeSkinMode mode = LatticeSkinMode::None;
  // The skin's OWN printability clamp (radius, mm): the AUTO skin radius is
  // max(local interior strut radius, min_radius_mm). Compute it with
  // lattice_skin_min_radius_mm below — callers never hardcode the law.
  double min_radius_mm = 0.0;
  // FREEFORM skin (task 2026-07-30-lattice-skin-freeform). false (default):
  // the diagrid links landings on ANALYTIC faces only — byte-identical to the
  // boundary-finish behaviour, which left the voxel-derived outer surface of a
  // real optimized part bare (its landings own no analytic face). true: landings
  // attributed to no analytic face (face == -1, the voxel base) are ALSO linked
  // by the same mutual-kNN discipline; each accepted chord is re-walked as a
  // station polyline projected onto the composite offset surface {sd == r_skin}
  // and certified-clipped with clip_segment_relaxed_base, so the skin rides an
  // ARBITRARY triangulated/voxel surface. Chords that leave the surface band
  // (bulge across a concavity / tunnel under a convex ridge) are REJECTED and
  // counted, never bent silently. Requires mode == Diagrid to emit anything.
  bool freeform = false;
};

// The skin printability clamp law (bar (e)) — CORE owns this number, callers
// read it. An interior strut's floor is one extrusion width of diameter
// (grading.hpp's printability floor). A skin strut is boundary-exposed: it
// prints as a partially supported perimeter that bridges the lattice openings
// beneath it, so it gets half an extra width of headroom. TRIPWIRE: the factor
// is a conservative engineering default, not yet print-validated; re-measure it
// the way PR 201 validated the interior floor before relaxing it.
inline constexpr double kLatticeSkinWidthFactor = 1.5;
inline double lattice_skin_min_radius_mm(double min_extrudable_width_mm) {
  return kLatticeSkinWidthFactor * 0.5 * min_extrudable_width_mm;
}

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

  // ── boundary finish (all zero on the legacy null-boundary path) ────────────
  std::uint64_t clipped_struts = 0;    // struts trimmed at the boundary
  std::uint64_t dropped_struts = 0;    // struts entirely outside the eroded region
  std::uint64_t strut_fragments = 0;   // kept sub-struts emitted from clipped struts
  std::uint64_t landings = 0;          // cut ends (the skin's anchor sites)
  std::uint64_t anchor_nodes = 0;      // anchor balls emitted at landings
  std::uint64_t skin_struts = 0;       // diagrid edge fragments emitted
  std::uint64_t rim_elements = 0;      // rim tori / rim line runs emitted
  std::uint64_t skin_triangles = 0;    // diagrid edges + anchor balls
  std::uint64_t rim_triangles = 0;     // rim loops (tori + plane-pair lines)
  long long uncertified_spans_dropped = 0;  // clip slivers conservatively dropped
  long long skipped_nonorthogonal_rims = 0; // face pairs the rim pass cannot dress
  // ── freeform skin (task 2026-07-30-lattice-skin-freeform; all zero unless
  //    LatticeSkinSpec.freeform) ─────────────────────────────────────────────
  // A CHORD is one accepted mutual-kNN landing pair; its polyline emission
  // fragments into several skin_struts (station segments), so both are counted.
  std::uint64_t skin_chords = 0;                    // chords emitted (>=1 span)
  std::uint64_t skin_chords_rejected_band = 0;      // left the surface band
  std::uint64_t skin_chords_rejected_projection = 0;// station projection failed
  std::uint64_t skin_chords_clipped_away = 0;       // accepted, but 0 spans kept
  // Emitted-solid volume accounting (bar B9). Analytic per-primitive volumes of
  // the interpenetrating soup; overlaps are NOT deducted (same basis as the
  // triangle counts — state it wherever these are reported).
  double interior_volume_mm3 = 0.0;
  double skin_volume_mm3 = 0.0;   // diagrid edges + anchor balls
  double rim_volume_mm3 = 0.0;    // rim tori + rim lines (the collar's rings)
};

// Count the cells the region's predicate accepts (the achieved latticed-cell
// count; a discretised grid cannot hit an arbitrary target region exactly).
long long latticed_cell_count(const LatticeRegion& region);

// Optional generation observer — a pure read-only tap on what is emitted, in
// the emission order (deterministic). This is how the boundary-finish bars are
// MEASURED from the real generator rather than asserted (B6: every cut end vs
// the skin), and what an app preview can consume without re-deriving geometry.
// Null callbacks are skipped; observing never changes the emitted bytes.
enum class LatticeGenElement {
  InteriorStrut,  // a (possibly clipped) interior strut fragment: a -> b
  Node,           // an interior node ball at a (b == a), radius r
  AnchorNode,     // a skin anchor ball at a clipped strut end (b == a)
  SkinStrut,      // a diagrid skin edge fragment: a -> b
  RimStrut,       // a plane-pair rim line fragment: a -> b
  RimTorusChord,  // one station chord of a rim torus run: a -> b, tube radius r
};
// The freeform skin pass's per-chord verdict (see LatticeSkinSpec.freeform) —
// how the E3/E4 bars are measured from the real generator.
enum class LatticeSkinChordVerdict {
  Accepted,            // emitted (at least one certified span)
  RejectedBand,        // straight chord left the surface band (bulge/tunnel)
  RejectedProjection,  // a station could not be projected onto the surface
  ClippedAway,         // accepted geometry entirely removed by the clip
};

struct LatticeGenObserver {
  // A clipped strut's cut end (landing): position, the strut's radius there,
  // and the boundary face it landed on (-1: no analytic face).
  std::function<void(const Vec3& pos, double r, int face)> on_landing;
  // Every emitted solid, reduced to segment + radius (a ball reports a == b).
  std::function<void(LatticeGenElement kind, const Vec3& a, const Vec3& b,
                     double r)>
      on_element;
  // Every freeform skin CHORD considered (the landing pair, straight-line
  // endpoints) and its verdict — fired once per chord, in emission order.
  std::function<void(const Vec3& a, const Vec3& b, LatticeSkinChordVerdict v)>
      on_skin_chord;
};

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
                                 TriangleSink& sink,
                                 const LatticeSkinSpec& skin = LatticeSkinSpec{},
                                 const LatticeGenObserver* observer = nullptr);

}  // namespace topopt
