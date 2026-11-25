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

namespace topopt {

// TOPOPT_SURFACE:
//   unset / "off"  today's export (voxel fill -> resample -> CAD snap -> flow).
//   "on"           the surface from the function, drawn faces exact, with the
//                  basis, reach and knot spacing stage 3 chose by measurement.
//   "on:<basis>:<reach>:<knot>"  a measurement arm: basis gaussian | wendland |
//                  wendland_c4 | bspline; reach in knot spacings (ignored for
//                  bspline, whose reach is 2); knot spacing in print LINE WIDTHS
//                  (0 = today's 3.41 mm rule). Example "on:wendland_c4:3:3".
struct SurfaceSwitch {
  bool on = false;
  bool basis_set = false;
  PlsmBasisKind basis = PlsmBasisKind::BSpline3;
  double reach = 2.0;
  double knot_line_widths = 0.0;
  std::string raw;
};
SurfaceSwitch to_surface_switch();
inline bool to_surface_on() { return to_surface_switch().on; }

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

}  // namespace topopt
