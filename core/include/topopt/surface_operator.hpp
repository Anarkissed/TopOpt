#pragma once

// Two candidate surface operators for the optimizer-cut population, and the
// constraint machinery both of them obey (task 2026-08-06-smoothing-operator-
// bakeoff, S1/S2).
//
// WHY THERE IS A SECOND MODULE AT ALL. Mesh FILTERING is retired as a family:
// PR 299 measured the shipped Taubin operator (smooth.hpp) removing 5.5% of the
// stair-step amplitude at the strength the app can ask for and 10.6% at the best
// setting anywhere in the family, reaching that by moving the surface 0.673 mm
// and melting the shape. Neither operator here is a filter — A moves the surface
// along its own normal by its own curvature, B reconstructs the ramp a smoother
// field would have produced — and both are bounded by a DISPLACEMENT limit
// (C1/C2) rather than by a pass-band.
//
// ── OPERATOR A, MEAN-CURVATURE FLOW ──────────────────────────────────────────
// Moves each vertex along its own outward normal in proportion to the local mean
// curvature. A staircase is alternating high-positive and high-negative
// curvature at the step edges with near-zero on the treads, so A attacks the
// steps and leaves the flats alone WITHOUT a detector.
//
// Contrast the umbrella Laplacian smooth.hpp uses: it moves a vertex toward its
// neighbours, so its per-pass displacement scales with the local vertex spacing
// and its strength is therefore mesh-density dependent (the same defect Blender
// documents for its own smooth brush, and the same one Taubin's dimensionless
// pass-band k_PB carries). The discrete mean-curvature normal below is
// normalized by the mixed Voronoi area (Meyer et al., "Discrete Differential-
// Geometry Operators for Triangulated 2-Manifolds", 2003), so it carries units
// of 1/length and is a property of the SURFACE, not of its tessellation:
// refining the mesh does not change how far a step edge moves.
//
// The formulation is the one OpenVDB's LevelSetFilter applies on a narrow band.
// OpenVDB is NOT a dependency and is not proposed as one: the mean curvature is
// a short formula and the narrow-band bookkeeping is the only part that would
// have been imported.
//
// ── OPERATOR B, RAMP RECONSTRUCTION ──────────────────────────────────────────
// Rather than diffusing toward the answer, construct it. Refine along the
// terrace, then place the points on the ramp running from the terrace's high
// extreme to its low extreme.
//
// This is what a sub-voxel iso-surface of a SMOOTH field produces naturally:
// marching cubes places each vertex proportionally between its cell's corner
// values, so a field with a real gradient across the step yields the ramp
// directly. The terracing exists because the field is near-binary — SIMP's
// penalisation drives it that way, and the projected rungs finish the job. B
// reconstructs the ramp that a smoother field would have given.
//
// It is NOT the up-res experiment PR 303 §S1.6 refuted. That added triangles
// uniformly and moved nothing: 16x the count, deviation flat at 0.376 -> 0.373
// -> 0.366 mm. B adds points where the ramp must be REPRESENTED and then MOVES
// them onto it.
//
// ── WHAT BOTH OPERATORS ARE NOT ALLOWED TO DO ────────────────────────────────
// C1, C2 and C3 below are enforced inside `apply_surface_operator` for both, and
// are not optional arguments the caller can talk it out of. C4 (CAD faces do not
// move) is NOT implemented here: it needs the CAD-versus-cut classifier that
// task `cad-face-projection` produces, and approximating it with a normal test
// or a curvature heuristic would be writing a second classifier. Callers pass
// the classifier's answer in through `SurfaceConstraints::sign` when it exists.
//
// Deterministic: fixed vertex order, no RNG, no nondeterministic reduction. The
// same mesh and the same parameters twice is byte-identical, and `steps == 0`
// returns the input mesh unchanged.

#include <cstddef>
#include <cstdint>
#include <vector>

#include "topopt/mesh.hpp"   // TriangleMesh, Vec3
#include "topopt/voxel.hpp"  // VoxelGrid, VoxelTag

namespace topopt {

// ─────────────────────────────────────────────────────────────────────────────
// C2 — THE SIGNED TRUST REGION
// ─────────────────────────────────────────────────────────────────────────────
//
// C1 bounds how FAR a vertex may move. C2 sets the bound's SIGN from whichever
// constraint is active at that vertex. The four cases are exhaustive and the
// conflict case resolves to "do nothing", never to a compromise nobody chose:
//
//   material matters (load path, thin section) -> OutwardOnly
//   design box or clearance binds              -> InwardOnly
//   neither binds                              -> Both
//   BOTH bind at once                          -> Pinned
//
// "Outward" is along the vertex's own outward normal, so OutwardOnly permits
// only motion that ADDS material and InwardOnly only motion that REMOVES it.
enum class TrustSign : std::uint8_t {
  Both = 0,
  OutwardOnly = 1,
  InwardOnly = 2,
  Pinned = 3,
};

// HOW "MATERIAL MATTERS" IS DETERMINED, and the defence of it.
//
// Both halves reuse a predicate this project ALREADY treats as the definition of
// the thing, rather than introducing a new criterion that would then have to be
// reconciled with the old one:
//
//   (a) LOAD PATH — the voxel under the vertex, or any of its 26 neighbours, is
//       tagged Load or Fixture. Those are exactly the voxels the certificate
//       applies its boundary conditions to. Removing material there changes the
//       structure the margin was computed on, which is the one change smoothing
//       must never make silently.
//
//   (b) THIN SECTION — the local member width at the vertex is below
//       `thin_section_mm`. Width is `local_member_thickness_mm`, the Hildebrand
//       inscribed-sphere diameter core already computes for the width-aware
//       knockdown gate; it assigns a rib its FULL width at every voxel including
//       the outer fibres, which is the behaviour wanted here (a vertex on the
//       surface of a thin rib must read the rib's thinness, not its own local
//       distance to void). The default threshold is 2 voxels — the same
//       "minimum feature size >= 2 voxels" that §7 V3 gate 4 already refuses
//       designs for, so a section this operator is forbidden to thin is a
//       section the gate would already have rejected.
//
// The INWARD-ONLY half is the design box and the clearance regions: a vertex
// within `bind_tol_mm` of the design-box boundary, or inside a keep-clear
// region, may not move further out into space the user declared off-limits.
struct TrustSignPolicy {
  // (a) load path. Off when the grid carries no Load/Fixture tags.
  bool load_path_binds = true;

  // (b) thin section. <= 0 selects 2 * grid.spacing at classification time.
  double thin_section_mm = 0.0;
  int thickness_cap_voxels = 8;  // cost cap for local_member_thickness_mm

  // The inward-only half: the design box, as a half-open AABB in model space.
  // `has_design_box == false` disables it (nothing binds inward from a box).
  bool has_design_box = false;
  Vec3 box_min;
  Vec3 box_max;
  double bind_tol_mm = 0.0;  // <= 0 selects 1 * grid.spacing
};

// Classify every vertex of `mesh` against `grid` under `policy`. `density` is
// the grid-indexed occupancy the thickness measure reads (size
// grid.voxel_count()); pass the design field, or 1.0 on every non-Empty voxel
// for a plain occupancy. Returns one TrustSign per vertex.
//
// A vertex outside the grid is classified `Both` by the grid half — it is not
// silently pinned, because a vertex the grid cannot see is a vertex the grid has
// no claim about. The design-box half is evaluated in model space and so still
// applies to it.
std::vector<TrustSign> classify_trust_sign(const TriangleMesh& mesh,
                                           const VoxelGrid& grid,
                                           const std::vector<double>& density,
                                           const TrustSignPolicy& policy);

// ─────────────────────────────────────────────────────────────────────────────
// THE CONSTRAINTS BOTH OPERATORS OBEY
// ─────────────────────────────────────────────────────────────────────────────
struct SurfaceConstraints {
  // C1 — THE TRUST REGION (Gibson, "Constrained Elastic Surface Nets", MICCAI
  // 1998). No vertex may leave the voxel that produced it.
  //
  // THE JUSTIFICATION, because it is the whole safety argument. The export is
  // ALREADY only accurate to +/- half a voxel: marching cubes places a vertex by
  // interpolating a field sampled at cell corners, and where that field is
  // near-binary the placement carries the full half-cell uncertainty. So motion
  // INSIDE that band adds no new error — it picks a better point within
  // uncertainty that already exists — while motion OUTSIDE it manufactures error
  // that was not there before. That is the line, and it is why the bound is a
  // displacement limit and not a smoothness target.
  //
  // `cell_mm` is the spacing of the lattice that PRODUCED the vertices: for an
  // export at `output.smooth_factor` f from a grid of spacing h, that is h / f,
  // not h. The box is the axis-aligned cube of half-width
  // `trust_voxels * cell_mm` about the vertex's ORIGINAL position.
  double cell_mm = 0.0;
  double trust_voxels = 0.5;  // <= 0 disables C1 (tests only; never in production)

  // C2 — the per-vertex sign. Empty ⇒ TrustSign::Both everywhere (C2 inert).
  // Size must equal the vertex count when non-empty.
  std::vector<TrustSign> sign;

  // C3 — VOLUME PRESERVATION. Curvature flow shrinks; neither operator ships
  // without a compensator. This is the uniform-shift of the level set: after the
  // operator runs, every movable vertex is shifted along its own normal by the
  // single scalar that closes the volume gap, then re-clamped to C1/C2, and the
  // pair is iterated. Measured residual is reported in the stats either way.
  bool preserve_volume = true;
  int volume_iterations = 40;
  double volume_tolerance = 1e-9;  // |dV|/V at which the iteration stops

  // C5 — THE BRUSH. One weight per vertex in [0,1] scaling that vertex's
  // displacement; empty ⇒ weight 1 everywhere. Weight 0 takes the same verbatim
  // branch as a pinned vertex (a branch, never `p + 0*d`, because 0.0*x on a
  // -0.0 coordinate flips the sign bit and defeats memcmp).
  std::vector<double> vertex_weight;
};

// ─────────────────────────────────────────────────────────────────────────────
// THE RECEIPT
// ─────────────────────────────────────────────────────────────────────────────
struct SurfaceOperatorStats {
  int requested_steps = 0;
  int applied_steps = 0;
  std::size_t vertices_in = 0;
  std::size_t vertices_out = 0;   // differs from vertices_in only for operator B
  std::size_t triangles_in = 0;
  std::size_t triangles_out = 0;

  // C1/C2 bite. `c1_clamped` counts vertices whose proposed position left the
  // trust box; `c2_projected` counts vertices whose proposed NORMAL motion ran
  // against their sign and was projected out; `pinned` counts TrustSign::Pinned.
  std::size_t c1_clamped = 0;
  std::size_t c2_projected = 0;
  std::size_t pinned = 0;
  double max_displacement_mm = 0.0;   // after all clamping
  double max_c1_pullback_mm = 0.0;    // deepest single C1 correction

  // C1 BY CONSTRUCTION (the question S1 asks of operator B). `c1_would_violate`
  // counts vertices whose UNCLAMPED proposed position already lay outside the
  // trust box — i.e. how often C1 was doing real work rather than confirming a
  // bound the construction had already met. Zero means the operator met C1 by
  // construction on this input.
  //
  // It is numerically EQUAL to `c1_clamped` and that is not a redundancy worth
  // removing: they are the same event read for two different purposes, and a
  // future operator that pre-clamped its own proposal internally would make them
  // diverge. `max_unclamped_excursion_mm` is the one that carries the magnitude,
  // and it is the number that answers the question — a count of 5793 says the
  // claim is false, 2.75 mm against a 0.405 mm radius says by how much.
  std::size_t c1_would_violate = 0;
  double max_unclamped_excursion_mm = 0.0;  // deepest such excursion (0 if none)

  // C3.
  double volume_before_mm3 = 0.0;
  double volume_after_operator_mm3 = 0.0;  // before the compensator
  double volume_after_mm3 = 0.0;           // after it
  double volume_drift_fraction = 0.0;      // |after-before|/before
  int volume_shift_iterations = 0;

  // R4: iterations and wall, always both, separately.
  double wall_seconds = 0.0;

  // Operator B only: the terrace segmentation and the envelope clamp.
  std::size_t terraces = 0;
  std::size_t refined_edges = 0;
  std::size_t envelope_clamped = 0;    // ramp targets pulled back to the extremes
  double max_envelope_clamp_mm = 0.0;
};

struct SurfaceOperatorResult {
  TriangleMesh mesh;
  SurfaceOperatorStats stats;
};

// ─────────────────────────────────────────────────────────────────────────────
// OPERATOR A — MEAN-CURVATURE FLOW
// ─────────────────────────────────────────────────────────────────────────────
struct MeanCurvatureParams {
  int steps = 0;  // 0 = OFF (identity: the mesh is returned unchanged)

  // The explicit time step, as a fraction of h^2 where h is the mean edge
  // length. Mean-curvature flow is a heat-type equation, so dt carries units of
  // LENGTH SQUARED; writing it as c * h^2 makes the operator scale-free. At a
  // step edge the curvature is O(1/h) and the displacement is therefore O(c*h) —
  // it attacks the steps — while on a smooth patch of radius R the curvature is
  // 1/R and the displacement is O(c*h^2/R), which is smaller by h/R. That
  // separation is the whole reason A needs no step detector.
  //
  // Explicit MCF is stable for c up to ~1/6 on a well-shaped triangulation;
  // 0.125 leaves margin and is the default.
  double dt_scale = 0.125;
};

SurfaceOperatorResult mean_curvature_flow(const TriangleMesh& mesh,
                                          const MeanCurvatureParams& params,
                                          const SurfaceConstraints& constraints);

// ─────────────────────────────────────────────────────────────────────────────
// OPERATOR B — RAMP RECONSTRUCTION
// ─────────────────────────────────────────────────────────────────────────────
struct RampParams {
  int steps = 0;  // 0 = OFF (identity). >1 re-segments and re-fits each time.

  // A terrace is a connected run of faces whose normals agree within this angle.
  // On a voxelized surface the treads are the flats and the risers are the
  // jumps, so this is the tread detector.
  double terrace_angle_deg = 25.0;

  // Refine any edge inside a terrace longer than this many cells, so the ramp
  // has points to be represented ON. `<= 0` disables refinement (which reduces B
  // to a pure projection and is how the "does refinement matter" row is run).
  double target_edge_cells = 0.5;
  int max_refine_passes = 2;

  // How far beyond the terrace the ramp's fit neighbourhood reaches, in vertex
  // rings. THIS IS WHAT MAKES IT A RAMP AND NOT A RE-FLATTENING: a tread is flat,
  // so a fit over the tread alone reproduces the tread exactly and moves nothing.
  // The extremes the ramp runs between live on the risers and the adjacent
  // treads, one ring out.
  int fit_rings = 1;

  // A terrace must have at least this many faces to be fitted. Smaller runs are
  // left alone: a 1-face "terrace" has no ramp to reconstruct and its plane fit
  // would be degenerate.
  std::size_t min_terrace_faces = 3;

  // Clamp each ramp target into the terrace group's own [low extreme, high
  // extreme] envelope. The claim under test is that this is redundant — that a
  // ramp between a terrace's own extremes lies inside that terrace's envelope by
  // construction — so the stats report how often it bites.
  bool clamp_to_envelope = true;
};

SurfaceOperatorResult ramp_reconstruction(const TriangleMesh& mesh,
                                          const RampParams& params,
                                          const SurfaceConstraints& constraints);

// ─────────────────────────────────────────────────────────────────────────────
// SHARED PIECES, EXPOSED FOR THE TESTS AND THE HARNESS
// ─────────────────────────────────────────────────────────────────────────────

// Area-weighted outward vertex normals, unit length (zero for an isolated
// vertex). "Outward" follows the mesh winding, which for a closed STL body is
// counter-clockwise seen from outside.
std::vector<Vec3> vertex_normals(const TriangleMesh& mesh);

// The discrete mean-curvature normal Kn(v) = L_cot(v) / (2 * A_mixed(v)), in
// units of 1/length, with the sign convention that Kn points INWARD on a convex
// body (so following it shrinks a sphere — that is the flow). Boundary or
// degenerate vertices return the zero vector.
std::vector<Vec3> mean_curvature_normals(const TriangleMesh& mesh);

// WATERTIGHT EDGE REFINEMENT. Splits every edge for which `split_edge` is true
// at its midpoint and re-triangulates each face according to how many of its
// three edges were split (1 -> 2 faces, 2 -> 3, 3 -> 4). The decision is taken
// per EDGE and both incident faces read the same decision, so the result has no
// T-junctions and stays watertight if the input was.
//
// `split_edge` is called once per undirected edge as (a, b) with a < b. New
// vertices are appended in a deterministic order (ascending (a,b)).
// `out_new_vertex_parents`, when non-null, receives one (a,b) pair per APPENDED
// vertex, in the order appended.
TriangleMesh refine_edges(
    const TriangleMesh& mesh,
    const std::vector<char>& split_edge_flag,
    const std::vector<std::pair<int, int>>& edges,
    std::vector<std::pair<int, int>>* out_new_vertex_parents);

// The undirected edge list of `mesh`, each as (a, b) with a < b, in ascending
// order. Deterministic, and the index space `refine_edges` expects.
std::vector<std::pair<int, int>> mesh_edges(const TriangleMesh& mesh);

}  // namespace topopt
