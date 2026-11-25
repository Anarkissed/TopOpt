// TO rebuild, repo tests C and D (docs/design/to-rebuild/04-tests.md).
//
// C. The area a load really lands on. A 60 x 40 x 12 mm block carries a drawn
//    20 x 20 mm patch on its top face (true area 400 mm2). The patch is loaded
//    through the shipped path (tag_step_face + traction_loads) at six resolutions
//    and three placements of the patch, and the test reads back the area the force
//    was spread over, where its centre landed, and the total force.
//    Rule 6: area within 2 % of the drawn face, total force unchanged.
//
// D. Protection depth. The same patch is protected to a typed depth of 2, 3 and
//    5 mm at three resolutions through the shipped path (region_depth_layers +
//    mask_step_face); the test measures how deep the frozen material really goes.
//    Rule 3: the typed mm within a tenth of a voxel.
//
// Each table has two halves: TODAY's path (whole voxels; ledger V-01 and L-03),
// which is only reported, and the DRAWN-FACE path (face_loads.hpp, stage 1), which
// is held to the rules:
//   - the loaded area, its centre and the total force, exactly as drawn;
//   - the protected depth as the frozen whole voxels show it (half a voxel at
//     best, by construction) and as the per-voxel protected share shows it (the
//     typed mm within a tenth of a voxel; what a stage that can hold a partly
//     protected voxel will deliver).
// The test fails when the drawn-face path breaks a rule. Today's path never
// fails it.
//
// Pure C++/std: the model is built in code; no OCCT, no Eigen.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "topopt/face_loads.hpp"
#include "topopt/face_region.hpp"
#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

using topopt::StepModel;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

constexpr double kLx = 60.0, kLy = 40.0, kLz = 12.0, kPatch = 20.0;
constexpr int F_BOTTOM = 0, F_SIDES = 1, F_TOP = 2, F_PATCH = 3;
constexpr double kForce = -100.0;  // N, straight down on the patch

// The block, with its top face split 3 x 3 so the middle cell is the patch.
StepModel build_block(double x0, double y0) {
  StepModel model;
  topopt::TriangleMesh& m = model.mesh;
  std::vector<int>& tf = model.triangle_face;
  const double xs[4] = {0.0, x0, x0 + kPatch, kLx};
  const double ys[4] = {0.0, y0, y0 + kPatch, kLy};
  m.vertices = {{0, 0, 0}, {kLx, 0, 0}, {kLx, kLy, 0}, {0, kLy, 0}};
  for (int b = 0; b < 4; ++b)
    for (int a = 0; a < 4; ++a) m.vertices.push_back({xs[a], ys[b], kLz});
  auto T = [](int a, int b) { return 4 + a + 4 * b; };
  auto tri = [&](int a, int b, int c, int face) {
    m.triangles.push_back({a, b, c});
    tf.push_back(face);
  };
  for (int b = 0; b < 3; ++b)
    for (int a = 0; a < 3; ++a) {
      const int f = (a == 1 && b == 1) ? F_PATCH : F_TOP;
      tri(T(a, b), T(a + 1, b), T(a + 1, b + 1), f);
      tri(T(a, b), T(a + 1, b + 1), T(a, b + 1), f);
    }
  tri(0, 2, 1, F_BOTTOM);
  tri(0, 3, 2, F_BOTTOM);
  // Each side is a fan that uses the top edge's own four points (no T-junctions).
  auto side = [&](int b0, int b1, int t0, int t1, int t2, int t3) {
    tri(b0, b1, t0, F_SIDES);
    tri(b0, t0, t1, F_SIDES);
    tri(b0, t1, t2, F_SIDES);
    tri(b0, t2, t3, F_SIDES);
  };
  side(0, 1, T(3, 0), T(2, 0), T(1, 0), T(0, 0));  // y = 0
  side(1, 2, T(3, 3), T(3, 2), T(3, 1), T(3, 0));  // x = Lx
  side(2, 3, T(0, 3), T(1, 3), T(2, 3), T(3, 3));  // y = Ly
  side(3, 0, T(0, 0), T(0, 1), T(0, 2), T(0, 3));  // x = 0
  model.face_count = 4;
  model.solid_count = 1;
  model.brep_volume = kLx * kLy * kLz;
  model.faces.assign(4, topopt::StepFaceInfo{});
  return model;
}

struct LoadRow {
  int res = 0;
  double voxel = 0.0, area = 0.0, centre_off = 0.0, total = 0.0;
  bool ok = false;
};

LoadRow measure_load(int res, double x0, double y0) {
  LoadRow r;
  r.res = res;
  const StepModel model = build_block(x0, y0);
  VoxelGrid g = topopt::voxelize(model.mesh, res);
  r.voxel = g.spacing;
  if (topopt::tag_step_face(g, model, F_PATCH, topopt::VoxelTag::Load) == 0) return r;
  const std::vector<topopt::NodalLoad> loads =
      topopt::traction_loads(g, topopt::VoxelTag::Load, Vec3{0.0, 0.0, kForce});
  std::vector<double> fz(static_cast<std::size_t>(topopt::fea_node_count(g)), 0.0);
  double smallest = 1e300;
  for (const topopt::NodalLoad& l : loads) {
    if (l.component != 2) continue;
    fz[static_cast<std::size_t>(l.node)] += l.value;
    smallest = std::min(smallest, std::fabs(l.value));
  }
  double sx = 0.0, sy = 0.0;
  for (int k = 0; k <= g.nz; ++k)
    for (int j = 0; j <= g.ny; ++j)
      for (int i = 0; i <= g.nx; ++i) {
        const double f = fz[static_cast<std::size_t>(topopt::fea_node_index(g, i, j, k))];
        r.total += f;
        sx += f * (g.origin.x + i * g.spacing);
        sy += f * (g.origin.y + j * g.spacing);
      }
  if (!(std::fabs(r.total) > 0.0) || !(smallest < 1e299)) return r;
  // Every loaded cell-face carries the same share, a quarter to each corner, and
  // a corner node of the loaded area holds exactly one quarter share.
  const double cell_faces = std::fabs(kForce) / (4.0 * smallest);
  r.area = cell_faces * g.spacing * g.spacing;
  r.centre_off = std::hypot(sx / r.total - (x0 + 0.5 * kPatch),
                            sy / r.total - (y0 + 0.5 * kPatch));
  r.ok = true;
  return r;
}

// The same patch through the drawn-face path.
LoadRow measure_load_face(int res, double x0, double y0) {
  LoadRow r;
  r.res = res;
  const StepModel model = build_block(x0, y0);
  const VoxelGrid g = topopt::voxelize(model.mesh, res);
  r.voxel = g.spacing;
  topopt::FaceAreaReport rep;
  const std::vector<topopt::NodeArea> areas = topopt::face_node_areas(
      g, topopt::face_pieces(model, {F_PATCH}, 0.5 * g.spacing), &rep);
  if (areas.empty()) return r;
  for (const topopt::NodalLoad& l :
       topopt::face_traction_loads(areas, Vec3{0.0, 0.0, kForce}))
    if (l.component == 2) r.total += l.value;
  r.area = rep.placed_area;
  r.centre_off = std::hypot(rep.placed_centre.x - (x0 + 0.5 * kPatch),
                            rep.placed_centre.y - (y0 + 0.5 * kPatch));
  r.ok = true;
  return r;
}

struct DepthRow {
  int res = 0;
  double voxel = 0.0, typed = 0.0, measured = 0.0;
  double by_share = 0.0;  // drawn-face path only: depth the protected shares add up to
  bool ok = false;
};

DepthRow measure_depth(int res, double typed_mm) {
  DepthRow r;
  r.res = res;
  r.typed = typed_mm;
  const double x0 = 20.37, y0 = 10.71;
  const StepModel model = build_block(x0, y0);
  const VoxelGrid g = topopt::voxelize(model.mesh, res);
  r.voxel = g.spacing;
  topopt::DesignMask mask(g.voxel_count(), topopt::MaskValue::Active);
  topopt::mask_step_face(g, model, F_PATCH, topopt::MaskValue::FrozenSolid,
                         topopt::region_depth_layers(typed_mm, g.spacing), mask);
  // The column under the patch's centre: how far down the frozen material goes.
  const int i = static_cast<int>((x0 + 0.5 * kPatch - g.origin.x) / g.spacing);
  const int j = static_cast<int>((y0 + 0.5 * kPatch - g.origin.y) / g.spacing);
  int lowest = -1;
  for (int k = g.nz - 1; k >= 0; --k)
    if (g.solid(i, j, k) && mask[g.index(i, j, k)] == topopt::MaskValue::FrozenSolid)
      lowest = k;
  if (lowest < 0) return r;
  r.measured = kLz - (g.origin.z + lowest * g.spacing);
  r.ok = true;
  return r;
}

// The same protection through the drawn-face path.
DepthRow measure_depth_face(int res, double typed_mm) {
  DepthRow r;
  r.res = res;
  r.typed = typed_mm;
  const double x0 = 20.37, y0 = 10.71;
  const StepModel model = build_block(x0, y0);
  const VoxelGrid g = topopt::voxelize(model.mesh, res);
  r.voxel = g.spacing;
  topopt::DesignMask mask(g.voxel_count(), topopt::MaskValue::Active);
  std::vector<float> share;
  topopt::mask_face_depth_mm(g, model, {F_PATCH}, typed_mm,
                             topopt::MaskValue::FrozenSolid, mask, &share);
  const int i = static_cast<int>((x0 + 0.5 * kPatch - g.origin.x) / g.spacing);
  const int j = static_cast<int>((y0 + 0.5 * kPatch - g.origin.y) / g.spacing);
  int lowest = -1;
  double sum = 0.0;
  for (int k = g.nz - 1; k >= 0; --k) {
    if (g.solid(i, j, k) && mask[g.index(i, j, k)] == topopt::MaskValue::FrozenSolid)
      lowest = k;
    // A voxel's share counts only for the part of the voxel that is under the face.
    const double z0 = g.origin.z + k * g.spacing;
    const double under = std::min(std::max(kLz - z0, 0.0), g.spacing) / g.spacing;
    sum += std::min(static_cast<double>(share[g.index(i, j, k)]), under);
  }
  if (lowest < 0) return r;
  r.measured = kLz - (g.origin.z + lowest * g.spacing);
  // Where the face stands above the highest solid voxel, that sliver of the part
  // is not in the grid at all (a voxelisation matter, ledger V-02); it is under
  // the face all the same.
  int top = -1;
  for (int k = 0; k < g.nz; ++k)
    if (g.solid(i, j, k)) top = k;
  const double missing = std::max(kLz - (g.origin.z + (top + 1) * g.spacing), 0.0);
  r.by_share = missing + sum * g.spacing;
  r.ok = true;
  return r;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  int failures = 0;

  const double places[3][2] = {{20.0, 10.0}, {20.37, 10.71}, {20.71, 10.37}};
  std::printf("[test C] a %.0f N load on a drawn %.0f x %.0f mm patch (true area %.0f mm2)\n",
              std::fabs(kForce), kPatch, kPatch, kPatch * kPatch);
  std::printf("%5s %8s %10s %12s %10s %14s %10s\n", "res", "voxel", "placement",
              "area mm2", "area %", "centre off mm", "force N");
  double worst_area = 0.0;
  int nothing_loaded = 0;
  for (int res : {32, 40, 48, 64, 80, 96})
    for (int p = 0; p < 3; ++p) {
      const LoadRow r = measure_load(res, places[p][0], places[p][1]);
      const double pct = 100.0 * (r.area / (kPatch * kPatch) - 1.0);
      const bool force_ok = std::fabs(r.total - kForce) < 1e-6 * std::fabs(kForce);
      std::printf("%5d %8.3f %10d %12.1f %+10.1f %14.3f %10.3f %s\n", r.res, r.voxel,
                  p + 1, r.area, pct, r.centre_off, r.total,
                  !r.ok ? "NOTHING LOADED" : (!force_ok ? "FORCE CHANGED" : ""));
      // No voxel centre lies within half a voxel under the drawn face: today the
      // load lands on nothing (ledger V-01). Counted by the gate, not by MEASURE.
      if (!r.ok) ++nothing_loaded;
      if (r.ok && !force_ok) ++failures;
      worst_area = std::max(worst_area, std::fabs(pct));
    }
  std::printf("[test C] worst area error %.1f %% (rule 6: 2 %%); the load landed on "
              "nothing in %d of 18 cases\n",
              worst_area, nothing_loaded);
  if (gate && (worst_area > 2.0 || nothing_loaded > 0)) ++failures;

  std::printf("\n[test C] the same patch through the drawn-face path\n");
  double worst_face_area = 0.0, worst_face_centre = 0.0;
  for (int res : {32, 40, 48, 64, 80, 96})
    for (int p = 0; p < 3; ++p) {
      const LoadRow r = measure_load_face(res, places[p][0], places[p][1]);
      const double pct = 100.0 * (r.area / (kPatch * kPatch) - 1.0);
      const bool force_ok = std::fabs(r.total - kForce) < 1e-9 * std::fabs(kForce);
      std::printf("%5d %8.3f %10d %12.1f %+10.2f %14.4f %10.3f %s\n", r.res, r.voxel,
                  p + 1, r.area, pct, r.centre_off / r.voxel, r.total,
                  !r.ok ? "NOTHING LOADED" : (!force_ok ? "FORCE CHANGED" : ""));
      if (!r.ok || !force_ok) ++failures;
      worst_face_area = std::max(worst_face_area, std::fabs(pct));
      worst_face_centre = std::max(worst_face_centre, r.centre_off / r.voxel);
    }
  std::printf("[test C] drawn-face path: worst area error %.2f %% (rule 6: 2 %%), "
              "centre off by at most %.3f voxel\n",
              worst_face_area, worst_face_centre);
  if (worst_face_area > 2.0 || worst_face_centre > 0.1) ++failures;

  std::printf("\n[test D] protection depth under the patch\n");
  std::printf("%5s %8s %10s %12s %14s\n", "res", "voxel", "typed mm", "measured mm",
              "off, in voxels");
  double worst_depth = 0.0;
  for (int res : {48, 64, 96})
    for (double typed : {2.0, 3.0, 5.0}) {
      const DepthRow r = measure_depth(res, typed);
      const double off = (r.measured - r.typed) / (r.voxel > 0.0 ? r.voxel : 1.0);
      std::printf("%5d %8.3f %10.1f %12.3f %+14.2f %s\n", r.res, r.voxel, r.typed,
                  r.measured, off, r.ok ? "" : "BROKEN");
      if (!r.ok && gate) ++failures;
      worst_depth = std::max(worst_depth, std::fabs(off));
    }
  std::printf("[test D] today: worst depth error %.2f voxel (rule 3: 0.10)\n", worst_depth);
  if (gate && worst_depth > 0.10) ++failures;

  std::printf("\n[test D] the same protection through the drawn-face path\n");
  std::printf("%5s %8s %10s %14s %14s %12s %14s\n", "res", "voxel", "typed mm",
              "whole voxels", "off, in voxels", "by share mm", "off, in voxels");
  double worst_whole = 0.0, worst_share = 0.0;
  for (int res : {48, 64, 96})
    for (double typed : {2.0, 3.0, 5.0}) {
      const DepthRow r = measure_depth_face(res, typed);
      const double v = r.voxel > 0.0 ? r.voxel : 1.0;
      std::printf("%5d %8.3f %10.1f %14.3f %+14.2f %12.3f %+14.2f %s\n", r.res, r.voxel,
                  r.typed, r.measured, (r.measured - r.typed) / v, r.by_share,
                  (r.by_share - r.typed) / v, r.ok ? "" : "BROKEN");
      if (!r.ok) ++failures;
      worst_whole = std::max(worst_whole, std::fabs(r.measured - r.typed) / v);
      worst_share = std::max(worst_share, std::fabs(r.by_share - r.typed) / v);
    }
  std::printf("[test D] drawn-face path: whole voxels off by at most %.2f voxel (0.5 by "
              "construction), protected share off by at most %.2f voxel (rule 3: 0.10)\n",
              worst_whole, worst_share);
  if (worst_whole > 0.5 + 1e-9 || worst_share > 0.10) ++failures;

  std::printf("[tests C, D] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
