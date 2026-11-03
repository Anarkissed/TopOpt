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
// "A x20" (51.6 % of stair-step amplitude removed on the analytic sphere at app
// strength; Taubin 11.2 %).

#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

inline constexpr int kFinishMcfSteps = 20;
inline constexpr double kFinishMcfDtScale = 0.125;
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
  // The CAD the projection used: its faces pin the vertices on them. Null = none.
  const StepModel* cad = nullptr;
  double cad_spacing_mm = 0.0;  // the solve spacing the projection's tolerances use
};

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
TriangleMesh surface_finish(const TriangleMesh& mesh, const FinishContext& ctx,
                            const std::vector<char>& pinned,
                            const std::vector<char>& outward_only,
                            FinishReport* report);

// (e) — every check re-run on the FINISHED shape (the exported file). `*_before` is
// the unfinished shape, for information only.
struct FinishRecheck {
  bool ran = false;
  double margin = 0.0;
  double margin_before = 0.0;
  double margin_required = 0.0;
  long long keep_clear_voxels = 0;
  int pieces = 1;
  int loose_pieces = 0;
  int thin_joints = 0;
  int thin_spots_left = 0;
  double mass_grams = 0.0;
  double mass_before_grams = 0.0;
};
// "" when a version the gate accepted is still good on its finished shape, else the
// plain line that refuses it ("After finishing, the margin is 1.42× (needs 1.5×)").
std::string finish_verdict_reason(const FinishRecheck& r);

// The local thickness (mm) at each vertex, capped at `cap_mm` (a vertex at least
// that thick reports cap_mm). Exposed for the tests.
std::vector<double> vertex_local_thickness_mm(const TriangleMesh& mesh, double cap_mm);

}  // namespace topopt
