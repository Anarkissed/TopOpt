// level_surface.hpp -- TO rebuild stage 3: the print surface is the zero surface
// of the optimiser's own function, meshed directly (ledger X-01, X-04; research 3a
// candidate 1). No voxel fill, no resample: every vertex is found on the true zero
// set of the function to a stated tolerance, and the triangles between them are
// the only approximation (chord error, measured by test A).
//
// THE ONE TEMPORARY SWITCH of stage 3 lives here (02-plan.md section 3): it and the
// old path are deleted in the stage's close-out.
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// TOPOPT_SURFACE:
//   unset / "off"  today's export (voxel fill -> resample -> CAD snap -> flow).
//   "on"           the surface from the function, drawn faces exact, with the
//                  basis, reach and knot spacing stage 3 chose by measurement.
//   "on:<basis>:<reach>:<knot>"  a measurement arm: basis gaussian | wendland |
//                  wendland_c4 | bspline; reach in knot spacings (ignored for
//                  bspline, whose reach is 2); knot spacing in print LINE WIDTHS
//                  (0 = today's 3.41 mm rule), or "v<n>" for n voxels (a
//                  measurement arm); either is floored at 1 voxel. Optional 5th field: the re-fit
//                  weights the band |phi| <= that many voxels 1 and the rest
//                  0.01 (default 1.5; 0 = uniform, today). Example
//                  "on:bspline:2:v1.5:1.5".
struct SurfaceSwitch {
  bool on = false;
  bool basis_set = false;
  PlsmBasisKind basis = PlsmBasisKind::BSpline3;
  double reach = 2.0;
  double knot_line_widths = 0.0;
  double knot_voxels = 0.0;  // > 0: the knot spacing in voxels (measurement arm)
  double fit_band_voxels = 0.0;
  std::string raw;
};
SurfaceSwitch to_surface_switch();
bool to_surface_on();

// Parse a basis name; false when unknown.
bool plsm_parse_basis(const std::string& s, PlsmBasisKind& out);

// The optimiser's function in model space (mm): phi(x) = sum alpha_i psi_i, with
// the knot lattice in voxel units of a grid whose voxel (i,j,k) centre is
// origin + (i + 0.5) * h. Values are in mm (the fit targets are distances in mm).
struct PlsmFieldView {
  const PlsmKnotLattice* lattice = nullptr;
  PlsmBasisKind basis = PlsmBasisKind::Gaussian;
  const std::vector<double>* alpha = nullptr;
  Vec3 origin{0, 0, 0};
  double h = 1.0;
  double value(const Vec3& p, Vec3* grad = nullptr) const;
};

struct LevelSurfaceStats {
  long long evaluations = 0;
  long long vertices = 0, triangles = 0;
  double seconds = 0.0;
  bool used_manifold = false;
};

// The closed surface of {f < 0} inside the box [lo, hi] (the box closes it),
// triangles about `cell_mm` across, every vertex within `tol_mm` of f = 0.
// Watertight and 2-manifold by construction (marching tetrahedra on a
// body-centred grid, Manifold::LevelSet). `f` must be safe to call from one
// thread at a time. Returns an empty mesh when this build has no Manifold.
TriangleMesh mesh_level_surface(const std::function<double(const Vec3&)>& f,
                                const Vec3& lo, const Vec3& hi, double cell_mm,
                                double tol_mm, LevelSurfaceStats* stats = nullptr);

// Worst and RMS distance of a mesh from the zero set of `sd` (a true signed
// distance), sampled at every vertex AND inside every triangle (centroid and the
// three edge midpoints), so chord error between vertices is counted too. Points
// with |sd| > `ignore_mm` (a box wall, not the shape) are skipped.
struct SurfaceError {
  double worst = 0.0, rms = 0.0;
  long long points = 0;
};
SurfaceError surface_error(const TriangleMesh& m,
                           const std::function<double(const Vec3&)>& sd,
                           const Vec3& lo, const Vec3& hi, double ignore_mm);

// Two closed meshes intersected exactly (Manifold). Empty with `why` set when
// either is not a closed manifold or this build has no Manifold.
TriangleMesh mesh_intersection(const TriangleMesh& a, const TriangleMesh& b,
                               std::string* why = nullptr);

// ── the print surface of one optimised version (02-plan.md stage 3) ─────────
//
// The zero surface of the optimiser's own function, cut by the DRAWN part, so
// every drawn face that the design keeps is the drawn face itself and every cut
// wall is the function's. The voxels the run stamped (frozen solid / frozen
// void) and that the function does not already explain are recovered from the
// shipped density, sample for sample on the optimiser's own sub-cell lattice, so
// the shape that ships holds exactly what was certified. Bodies that carry no
// load or anchor are dropped exactly as the voxel export drops them.
//
// With `frozen` (and the `model` whose mesh its triangle indices point into), each
// frozen body is held by TRUE distance: everything within its depth in mm of its
// own drawn triangles, inside its cuts (frozen_sets.hpp; ledger P-04). The
// stamped-voxel recovery then covers only what those do not explain (keep
// regions, clearances, bridges).
//
// With `keeps` and `keep_solid` (the keep regions as one closed solid), the part
// inside each keep region is kept exactly: the keep solid joins the function's
// solid BEFORE the one cut by the drawn part, so there is a single exact boolean
// and no second union along the drawn faces.
//
// Empty with `why` set when it cannot be made (no analytic design, no drawn part,
// a design-box run, no Manifold): the caller keeps today's export and says so.
struct MinimizePlasticVariant;
struct FrozenFaceSet;
struct StepModel;
struct FunctionSurfaceReport {
  long long stamped_solid = 0, stamped_void = 0;
  int frozen_sets = 0;  // frozen bodies held by true distance (frozen_sets.hpp)
  int unpinched = 0;    // pinch-point copies moved 1 um apart (level_surface.cpp)
  long long evaluations = 0, triangles = 0;
  double mesh_s = 0.0, cut_s = 0.0;
  double slope_min = 0.0, slope_median = 0.0, slope_max = 0.0;  // |grad phi| at vertices
};
TriangleMesh function_surface_mesh(const MinimizePlasticVariant& v, const VoxelGrid& sg,
                                   const TriangleMesh& part, int smooth_factor,
                                   double printed_iso, std::string* why,
                                   FunctionSurfaceReport* rep = nullptr,
                                   const std::vector<FrozenFaceSet>* frozen = nullptr,
                                   const StepModel* model = nullptr,
                                   const std::vector<KeepRegion>* keeps = nullptr,
                                   const TriangleMesh* keep_solid = nullptr);

}  // namespace topopt
