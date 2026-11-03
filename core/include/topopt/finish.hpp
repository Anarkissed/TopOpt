#pragma once
// ENGINE BATCH E1 — THE FINISHED SHAPE (reviewer's brief 2026-11-02, his go; app
// design plan.md § B4). There is no Smooth page and no brush: every result is shown,
// exported and certified as ONE finished shape. Per exported version, in order:
//   CAD projection -> exact Protect (keep regions) -> (c) thin-spot cleanup ->
//   (d) surface finish; then (e), in run_job, re-checks every verdict on that file.
//
// (c) THIN-SPOT CLEANUP adds material only. The thickness at a surface point is the
// diameter of the largest sphere inside the shape through that point (the local
// thickness of Hildebrand & Rüegsegger, "A new method for the model-independent
// assessment of thickness in three-dimensional images", J. Microscopy 185:67-75,
// 1997, doi 10.1046/j.1365-2818.1997.1340694.x), evaluated at each vertex as the
// largest ball tangent there that holds no OPPOSING surface (a facet facing within
// 30 degrees of the vertex's own normal, n_t . n_v < -0.866): a sharp convex edge or
// corner (of the voxel staircase, or of a plate) is not a thin member. A vertex thinner than the printable minimum moves
// outward along its normal by half the shortfall per pass, never into a Keep clear,
// Protect's reach, past the design box (growth) or outside the part (reduction),
// and never if it is on a CAD face or inside a keep region. A spot that cannot be
// thickened is left as it is and reported with its reason.
//
// (d) SURFACE FINISH: the mean-curvature flow of surface_operator.hpp on the
// optimizer's cut surfaces, inside the Gibson trust region (no vertex leaves the
// cell that produced it: Gibson, "Constrained elastic surface nets", MICCAI 1998,
// LNCS 1496:888-898, doi 10.1007/BFb0056277), signed: outward-only where material
// matters (load path, thin sections, the spots (c) thickened), inward-only at the
// design box and at Keep clear, pinned on CAD faces and inside keep regions. One
// fixed strength: kFinishMcfSteps steps at dt = kFinishMcfDtScale x h^2, PR 306's
// "A x20" flow time (51.6 % of stair-step amplitude removed on the analytic sphere at
// app strength; Taubin 11.2 %), with no triangle turned over (53.2 % here).
//
// SLIM, WITH A SAFE FALLBACK (his answer, reviewer's ruling 2026-11-03 02:48). C2's
// thin-section line is 2 x the printable minimum (1.8 mm at a 0.45 mm outer wall),
// not 2 x the solve spacing (3.8 mm at resolution 64, which held most of his members
// outward-only: 0.0 % removed on 6d9b535f). A member at least that thick may thin by
// up to half a cell per side (Gibson's box), and NEVER below the line: a vertex the
// flow takes under it (measured on the mesh, the Hildebrand thickness above) turns
// outward-only and the flow re-runs. Below the line, outward-only as before. Per
// version, a finished shape that fails a re-check the safe finish would pass is
// redone with the safe finish (C2's 2 x spacing line) and says so: finish_fallback.

#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// PR 306's "A x20" flow time (20 x 0.125 h^2) in four times finer steps: the coarse
// step overshoots (164 triangles of the analytic sphere turned over; 52 at this one).
inline constexpr int kFinishMcfSteps = 80;
inline constexpr double kFinishMcfDtScale = 0.03125;
inline constexpr int kFinishThinPasses = 6;
// The stair-step measure's reference: a Taubin lambda/mu low-pass this many iterations.
inline constexpr int kFinishRefIterations = 2000;

struct FinishContext {
  // (c): the printable minimum (mm) and where it came from; <= 0 disables (c).
  double min_thickness_mm = 0.0;
  std::string min_thickness_source;
  // (d): the export cell (solve spacing / smooth factor): Gibson's trust region is
  // half of it about each vertex's start. <= 0 disables (d).
  double cell_mm = 0.0;
  int mcf_steps = kFinishMcfSteps;
  // The solve grid and its design, for the material-matters signs (classify_trust_
  // sign) and the forbidden voxels: `forbidden` is solve-grid indexed, FrozenVoid =
  // a Keep clear or Protect's reach (empty = none).
  const VoxelGrid* grid = nullptr;
  const std::vector<double>* density = nullptr;
  const DesignMask* forbidden = nullptr;
  const std::vector<KeepRegion>* keeps = nullptr;
  // Growth runs may not leave the design box; reduction runs may not leave the part
  // (its voxels on the solve grid: `part_solid`, solve-grid indexed, 1 = part).
  bool growth = false;
  bool has_box = false;
  DesignBox box{};
  const std::vector<char>* part_solid = nullptr;
  // The CAD the projection used: its faces pin the vertices on them. Null = none: then
  // the part's own voxels on the solve grid (`part_voxels`, 1 = the part as drawn,
  // either run type) pin the drawn surface instead.
  const StepModel* cad = nullptr;
  const std::vector<char>* part_voxels = nullptr;
  double cad_spacing_mm = 0.0;  // the solve spacing the projection's tolerances use
  // The slim finish's thin-section line (mm): 2 x the printable minimum. <= 0 = the
  // safe finish (C2's own line, 2 x the solve spacing).
  double slim_line_mm = 0.0;
};
// How many times the slim finish may re-run the flow with more vertices held
// outward-only before it gives up and uses the safe finish.
inline constexpr int kFinishSlimRounds = 8;

struct ThinSpot {
  Vec3 centre_mm{0.0, 0.0, 0.0};
  double before_mm = 0.0;
  double after_mm = 0.0;  // fixed spots: the thinnest after; left spots: as found
  std::string reason;     // left spots only, plain words
};

struct FinishReport {
  bool ran = false;
  double min_thickness_mm = 0.0;
  std::string min_thickness_source;
  std::vector<ThinSpot> fixed;
  std::vector<ThinSpot> left;
  bool surface_applied = false;
  double stair_step_removed_pct = 0.0;
  double roughness_before_mm = 0.0;  // RMS distance from the low-passed surface
  double roughness_after_mm = 0.0;
  std::size_t roughness_vertices = 0;
  std::size_t pinned_vertices = 0;
  std::size_t pinned_moved = 0;  // a CAD / keep-region vertex the finish moved (0, by design)
  std::size_t outward_only_vertices = 0;  // free vertices the flow may only move out
  // The slim finish: whether it was the one applied, the flow re-runs its 1.8 mm
  // guard took, and the vertices it held outward-only. A slim finish that could not
  // keep every member at its line falls back to the safe one (fallback_reason).
  bool slim = false;
  int slim_rounds = 0;
  std::size_t slim_guarded_vertices = 0;
  std::size_t fold_held_vertices = 0;  // corners walked back off a triangle the flow turned over
  bool fallback = false;
  std::string fallback_reason;
  double volume_before_mm3 = 0.0;
  double volume_after_mm3 = 0.0;
  double seconds = 0.0;
};

// The finished shape of an exported mesh (already CAD-projected and keep-exact).
// Deterministic. Returns the mesh unchanged (report.ran false) when both stages are
// disabled.
TriangleMesh finish_shape(const TriangleMesh& mesh, const FinishContext& ctx,
                          FinishReport* report);

// (c) alone and (d) alone, for the tests. `pinned` (per vertex, may be empty) adds
// to the context's own pins.
TriangleMesh thin_spot_cleanup(const TriangleMesh& mesh, const FinishContext& ctx,
                               const std::vector<char>& pinned, FinishReport* report,
                               std::vector<char>* moved = nullptr);
// `movable` (may be null): per vertex, whether the flow could move it outward (free or
// outward-only), for the never-remove-material nudge after it.
TriangleMesh surface_finish(const TriangleMesh& mesh, const FinishContext& ctx,
                            const std::vector<char>& pinned,
                            const std::vector<char>& outward_only,
                            FinishReport* report, std::vector<char>* movable = nullptr);

// (e) — every check re-run on the FINISHED shape (the exported file). `*_before` is
// the unfinished shape, for information only.
struct FinishRecheck {
  bool ran = false;
  double margin = 0.0;
  double margin_before = 0.0;
  double margin_required = 0.0;
  long long keep_clear_voxels = 0;
  int pieces = 1;
  int loose_pieces = 0;        // the file's pieces holding neither a load nor an anchor
  int loose_pieces_before = 0;  // the same count on the unfinished file
  int thin_joints = 0;
  int thin_joints_before = 0;  // the same count on the unfinished file
  // The analysis of the file itself: its load-path belt, its anchors, its solve.
  bool load_path_ok = true;
  bool anchors_slide = false;
  bool non_convergent = false;
  int thin_spots_left = 0;
  double mass_grams = 0.0;
  double mass_before_grams = 0.0;
};
// "" when a version the gate accepted is still good on its finished shape, else the
// plain line that refuses it ("After finishing, the margin is 1.42× (needs 1.5×)").
std::string finish_verdict_reason(const FinishRecheck& r);

// THE PER-VERSION FALLBACK, one decision for every run type: finish slim and
// re-check; on a failing re-check, finish safe and re-check again. A safe finish that
// passes ships with fallback = true and the slim one's reason; one that fails refuses
// the version on its own merits (its reason), exactly as before slimming.
// `finish(slim)` returns the finished shape; `check(shape)` returns "" or the reason.
struct FallbackOutcome {
  bool slim_used = true;
  bool fallback = false;
  std::string fallback_reason;  // the slim finish's failing re-check, plain words
  std::string refusal;          // non-empty: the version is refused for this reason
};
template <class Finish, class Check>
FallbackOutcome finish_with_fallback(Finish&& finish, Check&& check) {
  FallbackOutcome o;
  const std::string slim_why = check(finish(true));
  if (slim_why.empty()) return o;
  o.slim_used = false;
  const std::string safe_why = check(finish(false));
  if (safe_why.empty()) {
    o.fallback = true;
    o.fallback_reason = slim_why;
  } else {
    o.refusal = safe_why;
  }
  return o;
}

// The voxels of `occupancy` (1 = printed, solve-grid indexed) that hold together
// only along an edge or at a corner: the fragile-joint count minimize_plastic reports
// for the solved design, taken here on a FILE voxelized onto the same grid (face-
// connected pieces of printed voxels meeting through edge / corner neighbours only,
// one per piece pair).
int file_thin_joints(const VoxelGrid& grid, const std::vector<char>& occupancy);

// The pieces of `occupancy` (26-connected, as the export's bodies are) that hold no
// Load or Fixture voxel of `grid`: loose in the print.
int file_loose_pieces(const VoxelGrid& grid, const std::vector<char>& occupancy);

// The mesh's bodies: its connected shells with positive signed volume (a sealed
// internal void is a negative shell, not a piece).
int positive_volume_bodies(const TriangleMesh& mesh);

// A mesh as its file holds it: vertices rounded to float (STL's precision) and welded
// by exact position, as every reader (core's import, any slicer) welds them. Edges on
// more than two triangles, open edges, and the closed shells (connected through
// shared edges) of that welded mesh. The E1 bar: 0, 0 and one shell per body.
struct WrittenAudit {
  int non_manifold_edges = 0;
  int boundary_edges = 0;
  int non_manifold_vertices = 0;  // a vertex where two shells touch at a point
  int shells = 0;
  int bodies = 0;  // shells with positive volume (a sealed void is a shell, not a body)
  std::vector<Vec3> bad_edge_midpoints;  // the first few, for the probes
};
WrittenAudit audit_as_written(const TriangleMesh& mesh);

// THE WRITTEN FILE IS CLEAN (reviewer's ruling 2026-11-03 02:46: 0 edges on more
// than two triangles, one closed shell per body). Two vertices that are distinct in
// double but the same float are ONE vertex in the file; a triangle on two of them is
// a zero-area sliver whose long edge then carries four triangles (his squish rig: the
// exact-Protect boolean left them where a Protect cylinder's end met the voxel
// surface). This merges such vertices, drops the triangles they collapse (and a
// zero-volume fin, a triangle pair on the same three vertices), and drops unused
// vertices. A mesh with no float-coincident vertices is returned as it is.
TriangleMesh weld_as_written(const TriangleMesh& mesh);

// The fragments a boolean leaves: shells (edge-connected) under `min_volume_mm3` in
// absolute volume — a piece smaller than one solve voxel is nothing the optimizer
// made — except the `keep_bodies` largest positive shells, which stay whatever their
// size. `dropped` (may be null) counts the shells removed.
TriangleMesh drop_fragment_shells(const TriangleMesh& mesh, double min_volume_mm3,
                                  int keep_bodies, int* dropped);

// The local thickness (mm) at each vertex, capped at `cap_mm` (a vertex at least
// that thick reports cap_mm). Exposed for the tests.
std::vector<double> vertex_local_thickness_mm(const TriangleMesh& mesh, double cap_mm);
// THE BAR's "no member under the line that was not": the vertices of `after` (the same
// vertices as `before`, moved) newly under `line` by the surface measure, along
// `before`'s normals — `measured` all of them, `by_inward` those where the vertex or
// the facet limiting its ball moved INWARD (outward motion only adds material, which
// cannot thin a member; finish.cpp thinned_by_inward_motion). The slim guard holds
// exactly the by_inward ones.
struct ThinnedCount {
  bool comparable = true;  // false: different vertex counts
  int measured = 0;
  int by_inward = 0;
  double thinnest_mm = 0.0;  // the thinnest by_inward one
};
ThinnedCount count_thinned(const TriangleMesh& before, const TriangleMesh& after, double line);

// The same, each ball along `normals_from`'s vertex normals (same vertex count): a
// finished shape measured along its unfinished normals, like for like.
std::vector<double> vertex_local_thickness_mm(const TriangleMesh& mesh, double cap_mm,
                                              const TriangleMesh& normals_from);

}  // namespace topopt
