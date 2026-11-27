// TO rebuild, repo test E (docs/design/to-rebuild/04-tests.md), first half.
//
// The strength number against a stress that is known from the textbook: a wide
// flat plate with a round hole, pulled along an axis TILTED 30 degrees to the
// grid. The peak stress at the hole's edge is 3 times the far stress (Kirsch;
// about 3.03 for a plate ten holes wide). The tilt puts the peak on a
// stair-stepped part of the hole, which is where a voxel stress reading is
// weakest. The plate is solved at four resolutions (hole radius 3, 4, 5, 6
// voxels) and with three ways of treating the hole's edge: each voxel
// all-or-nothing; each voxel's exact fill fraction solved as today (stiffness
// E x fill^3, ledger A-01); and the exact fill fraction solved with stiffness
// E x fill (a cut voxel is about as stiff as the material it holds).
//
// The plate is the SAME physical plate at every resolution (hole radius 6 mm), so
// a reading over a fixed size in mm can be compared across resolutions. On the
// E x fill arm the stress is also read over 0.9, 1.8 and 3.6 mm (2, 4 and 8 line
// widths of 0.45 mm; stress_measure.hpp). An averaged reading sits below the
// textbook peak by design, so those columns are judged on their spread only.
//
// Rule 5 asks: within 5 % of the textbook value, and the four resolutions within
// 10 % of one another. Today's reading is the peak over voxels and is not
// expected to meet that, so:
//   no argument : MEASURE. Prints the table; fails only on a broken run.
//                 This is what ctest runs until stage 2.
//   --gate      : also fails outside the two bands. Stage 2 switches ctest to it.
//
// The thick ring under pressure (the test's second half) needs pressure applied
// on a curved face, which stage 1's area loading provides; it is added there.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "to_reference_reading.hpp"
#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/stress_measure.hpp"
#include "topopt/voxel.hpp"

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

// THE SWITCH POINT (the reviewer's ruling 2026-11-26, item 2): extra sizes read on
// the same solve, set by main() for one resolution at a time (mm in, reading out).
std::vector<double> g_switch_sizes_mm;
std::vector<double> g_switch_readings;
// The engine's carry (stress_carried_to_surface) over the far stress, the loaded
// edges masked, and its unresolved count. Filled by peak_ratio.
double g_engine_carry = 0.0;
std::size_t g_engine_unresolved = 0;
// The curvature-shaped carry (shape 1) over the reference stress, its curved points and
// how many of those were read as concave (the centre of curvature in the air).
double g_carry2 = 0.0;
std::size_t g_carry2_curved = 0, g_carry2_concave = 0, g_carry2_tight = 0, g_carry2_capped = 0,
            g_carry2_unresolved = 0;
// The patch recovery (stress_recovered_at_surface) over the far stress, the loaded
// edges masked the same way, at patch radius 2.5 and 3.5 voxels, and its unresolved counts.
double g_patch[2] = {0.0, 0.0};
std::size_t g_patch_unresolved[2] = {0, 0};
double g_quad[2] = {0.0, 0.0};  // the quadratic patch (order 2) at radius 3.5 and 4.5
std::size_t g_quad_unresolved[2] = {0, 0}, g_quad_dropped[2] = {0, 0};

constexpr double kFarStress = 10.0;   // MPa
constexpr double kTiltDeg = 30.0;
constexpr double kTextbook = 3.03;    // Kirsch 3.0, finite width d/W = 0.1
constexpr int kThickness = 2;         // voxels
constexpr int kSub = 8;
constexpr double kHoleRadiusMm = 6.0;
constexpr double kSizesMm[3] = {0.9, 1.8, 3.6};

struct Row {
  int radius_voxels = 0;
  double ratio_binary = 0.0;
  double ratio_fill = 0.0;         // exact fill, stiffness E x fill^3 (today)
  double ratio_fill_linear = 0.0;  // exact fill, stiffness E x fill
  double over_size[3] = {0.0, 0.0, 0.0};  // E x fill arm, read over kSizesMm
};

std::vector<NodalLoad> edge_tractions(const VoxelGrid& g, double sxx, double syy,
                                      double sxy) {
  // Each boundary element face carries traction * area, a quarter to each node.
  const double q = 0.25 * g.spacing * g.spacing;
  std::vector<NodalLoad> loads;
  auto push = [&](int i, int j, int k, double fx, double fy) {
    const int n = topopt::fea_node_index(g, i, j, k);
    loads.push_back({n, 0, fx});
    loads.push_back({n, 1, fy});
  };
  for (int k = 0; k < g.nz; ++k) {
    for (int j = 0; j < g.ny; ++j)      // faces x = 0 (normal -x) and x = W (+x)
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj) {
          push(g.nx, j + dj, k + dk, q * sxx, q * sxy);
          push(0, j + dj, k + dk, -q * sxx, -q * sxy);
        }
    for (int i = 0; i < g.nx; ++i)      // faces y = 0 (normal -y) and y = W (+y)
      for (int dk = 0; dk < 2; ++dk)
        for (int di = 0; di < 2; ++di) {
          push(i + di, g.ny, k + dk, q * sxy, q * syy);
          push(i + di, 0, k + dk, -q * sxy, -q * syy);
        }
  }
  return loads;
}

// `thickness` (voxels, default kThickness): the plate's thickness; the `[thick6]` rows
// pass 6 (the reviewer: "a plate several voxels thick, not 2"). At any other thickness
// than kThickness the patch recoveries are skipped (only the carry is read there).
bool g_non_convergent = false;
double peak_ratio(int radius_voxels, bool exact_fill, double penalty, bool* ok,
                  double* over_size = nullptr, int thickness = kThickness) {
  const int w = 20 * radius_voxels;  // plate ten holes wide
  VoxelGrid g;
  g.nx = w;
  g.ny = w;
  g.nz = thickness;
  g.spacing = kHoleRadiusMm / radius_voxels;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(w) * w * thickness, topopt::VoxelTag::Interior);

  // Hole centre off the grid lines, so nothing is symmetric by luck.
  const double cx = 0.5 * w + 0.29, cy = 0.5 * w - 0.41, r = radius_voxels;
  std::vector<double> density(g.tags.size(), 1.0);
  for (int j = 0; j < w; ++j)
    for (int i = 0; i < w; ++i) {
      double v;
      if (exact_fill) {
        int in = 0;
        for (int b = 0; b < kSub; ++b)
          for (int a = 0; a < kSub; ++a)
            if (std::hypot(i + (a + 0.5) / kSub - cx, j + (b + 0.5) / kSub - cy) > r) ++in;
        v = static_cast<double>(in) / (kSub * kSub);
      } else {
        v = std::hypot(i + 0.5 - cx, j + 0.5 - cy) > r ? 1.0 : 0.0;
      }
      for (int k = 0; k < thickness; ++k)
        density[(static_cast<std::size_t>(k) * w + j) * w + i] = v;
    }

  const double t = kTiltDeg * std::acos(-1.0) / 180.0;
  const double c = std::cos(t), s = std::sin(t);
  const std::vector<NodalLoad> loads =
      edge_tractions(g, kFarStress * c * c, kFarStress * s * s, kFarStress * s * c);

  // The load balances itself; hold only the six rigid motions, at three corners.
  std::vector<DirichletBC> bcs;
  const int a = topopt::fea_node_index(g, 0, 0, 0);
  const int b = topopt::fea_node_index(g, w, 0, 0);
  const int d = topopt::fea_node_index(g, 0, w, 0);
  bcs.push_back({a, 0, 0.0});
  bcs.push_back({a, 1, 0.0});
  bcs.push_back({a, 2, 0.0});
  bcs.push_back({b, 1, 0.0});
  bcs.push_back({b, 2, 0.0});
  bcs.push_back({d, 2, 0.0});

  topopt::Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 1.0;
  m.poisson = 0.33;
  m.family = "fdm";

  topopt::SimpParams params;
  params.youngs_modulus = m.youngs_modulus_mpa;
  params.poisson = m.poisson;
  params.penalty = penalty;

  topopt::KnockdownSpec knockdown;
  // The cut voxels' stress too: a size is read with the ball free to sit on the
  // part's edge (stress_measure.hpp, "the edge of the part").
  knockdown.record_material_stress = true;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-8, 20000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  *ok = res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  g_non_convergent = res.non_convergent;
  g_switch_readings.clear();
  if (res.von_mises_material_field.size() == density.size())
    for (double mm : g_switch_sizes_mm)
      g_switch_readings.push_back(topopt::peak_stress_over_size_edge_and_surface(
                                      g, res.von_mises_material_field, density,
                                      topopt::kStressMaterialFloor, mm) /
                                  kFarStress);
  if (over_size != nullptr && res.von_mises_material_field.size() == density.size())
    for (int q = 0; q < 3; ++q)
      over_size[q] = topopt::peak_stress_over_size(g, res.von_mises_material_field, density,
                                                   topopt::kStressMaterialFloor,
                                                   kSizesMm[q]) /
                     kFarStress;
  g_engine_carry = 0.0;
  g_engine_unresolved = 0;
  g_carry2 = 0.0;
  g_carry2_tight = g_carry2_unresolved = 0;
  if (res.von_mises_material_field.size() == density.size()) {
    std::vector<double> f = res.von_mises_material_field;  // the loaded edges masked
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < w; ++j)
        for (int i = 0; i < w; ++i)
          if (i < 3 || j < 3 || i >= w - 3 || j >= w - 3) f[g.index(i, j, k)] = 0.0;
    const topopt::SurfaceCarry sc = topopt::stress_carried_to_surface(g, f, density);
    g_engine_carry = sc.peak / kFarStress;
    g_engine_unresolved = sc.unresolved;
    const topopt::SurfaceCarry sc2 = topopt::stress_carried_to_surface(g, f, density, 1);
    g_carry2 = sc2.peak / kFarStress;
    g_carry2_curved = sc2.curved_points;
    g_carry2_concave = sc2.curved_concave;
    g_carry2_tight = sc2.tight_points;
    g_carry2_capped = sc2.capped_points;
    g_carry2_unresolved = sc2.unresolved;
  }
  g_patch[0] = g_patch[1] = 0.0;
  g_patch_unresolved[0] = g_patch_unresolved[1] = 0;
  g_quad[0] = g_quad[1] = 0.0;
  g_quad_unresolved[0] = g_quad_unresolved[1] = g_quad_dropped[0] = g_quad_dropped[1] = 0;
  if (thickness == kThickness && res.stress_tensor_field.size() == 6 * density.size()) {
    std::vector<double> tf = res.stress_tensor_field;  // the loaded edges masked
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < w; ++j)
        for (int i = 0; i < w; ++i)
          if (i < 3 || j < 3 || i >= w - 3 || j >= w - 3)
            for (int c6 = 0; c6 < 6; ++c6) tf[6 * g.index(i, j, k) + c6] = 0.0;
    const double radii[2] = {2.5, 3.5};
    for (int q = 0; q < 2; ++q) {
      const topopt::SurfaceRecovery sr =
          topopt::stress_recovered_at_surface(g, tf, density, nullptr, radii[q]);
      g_patch[q] = sr.peak / kFarStress;
      g_patch_unresolved[q] = sr.unresolved;
    }
    const double quad_radii[2] = {3.5, 4.5};
    for (int q = 0; q < 2; ++q) {
      const topopt::SurfaceRecovery sr = topopt::stress_recovered_at_surface(
          g, tf, density, nullptr, quad_radii[q], 2);
      g_quad[q] = sr.peak / kFarStress;
      g_quad_unresolved[q] = sr.unresolved;
      g_quad_dropped[q] = sr.squares_dropped;
    }
  }
  return res.max_von_mises / kFarStress;
}

// A REAL 3D RAISER (the reviewer, 2026-11-27: "an inside-corner fillet, radius 4 voxels
// or more, against a solve 4 times finer"). Print-only, `[fillet]` rows. An L bracket in
// the x-y plane, extruded 6 voxels in z: two arms 8 voxels thick, their outer faces at
// x = 1.29 and y = 1.59 voxels, running to the grid's edge at 30 voxels (about 28.5
// voxels long); a fillet of radius R in the inside corner, its centre at (9.29 + R,
// 9.59 + R), off the grid lines by (0.29, -0.41). The end face of the upright arm
// (y = 30) is clamped; the end face of the flat arm (x = 30) carries a uniform 1 MPa
// shear traction in -y, which opens the corner (the fillet is in tension). `scale` 1, 2
// or 4: the same physical bracket (base voxel 1 mm) at that many voxels per base voxel.
// The readings and the counts are restricted to a box within R + 4 base voxels of the
// fillet centre in x and y (the clamp and the loaded face are outside it).
struct FilletReading {
  bool ok = false, non_convergent = false;
  double carry = 0.0;      // stress_carried_to_surface shape 1 on the boxed field, MPa
  double per_voxel = 0.0;  // the largest von_mises_field voxel in the box, MPa
  std::size_t tight = 0, unresolved = 0;
  double seconds = 0.0;
  int nx = 0, nz = 0;
};

FilletReading fillet_reading(double R, int scale) {
  FilletReading out;
  const int n = 30 * scale, nzv = 6 * scale;
  VoxelGrid g;
  g.nx = n;
  g.ny = n;
  g.nz = nzv;
  g.spacing = 1.0 / scale;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * nzv, topopt::VoxelTag::Empty);
  out.nx = n;
  out.nz = nzv;

  // In base voxels.
  const double ox = 1.29, oy = 1.59;          // the outer faces
  const double ix = ox + 8.0, iy = oy + 8.0;  // the inside corner (before the fillet)
  const double fcx = ix + R, fcy = iy + R;    // the fillet's centre
  auto inside = [&](double x, double y, double z) {
    if (z < 0.0 || z > 6.0 || x < ox || y < oy) return false;
    if (x <= ix || y <= iy) return true;  // in one of the arms
    return x < fcx && y < fcy && std::hypot(x - fcx, y - fcy) > R;  // the fillet
  };
  std::vector<double> density(g.tags.size(), 0.0);
  const double inv = 1.0 / scale;
  for (int k = 0; k < nzv; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        int in = 0;
        for (int c = 0; c < kSub; ++c)
          for (int b = 0; b < kSub; ++b)
            for (int a = 0; a < kSub; ++a)
              if (inside((i + (a + 0.5) / kSub) * inv, (j + (b + 0.5) / kSub) * inv,
                         (k + (c + 0.5) / kSub) * inv))
                ++in;
        const std::size_t idx = g.index(i, j, k);
        density[idx] = static_cast<double>(in) / (kSub * kSub * kSub);
        if (in > 0) g.tags[idx] = topopt::VoxelTag::Interior;
      }

  // Clamp: every node of the material's faces on y = top.
  std::vector<DirichletBC> bcs;
  std::vector<char> held(static_cast<std::size_t>(n + 1) * (n + 1) * (nzv + 1), 0);
  for (int k = 0; k < nzv; ++k)
    for (int i = 0; i < n; ++i)
      if (density[g.index(i, n - 1, k)] > 0.0)
        for (int dk = 0; dk < 2; ++dk)
          for (int di = 0; di < 2; ++di) {
            const int node = topopt::fea_node_index(g, i + di, n, k + dk);
            if (held[static_cast<std::size_t>(node)]) continue;
            held[static_cast<std::size_t>(node)] = 1;
            for (int dof = 0; dof < 3; ++dof) bcs.push_back({node, dof, 0.0});
          }
  // Load: 1 MPa in -y on the material's faces on x = right; each face carries traction x
  // its area (the voxel's fill: the arm's section is uniform along x there), a quarter to
  // each node.
  constexpr double kTraction = 1.0;  // MPa
  std::vector<NodalLoad> loads;
  for (int k = 0; k < nzv; ++k)
    for (int j = 0; j < n; ++j) {
      const double d = density[g.index(n - 1, j, k)];
      if (d <= 0.0) continue;
      const double f = -0.25 * kTraction * g.spacing * g.spacing * d;
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj)
          loads.push_back({topopt::fea_node_index(g, n, j + dj, k + dk), 1, f});
    }

  topopt::Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 1.0;
  m.poisson = 0.33;
  m.family = "fdm";
  topopt::SimpParams params;
  params.youngs_modulus = m.youngs_modulus_mpa;
  params.poisson = m.poisson;
  params.penalty = 1.0;  // real stiffness: a cut voxel at E x fill
  topopt::KnockdownSpec knockdown;
  knockdown.record_material_stress = true;
  const auto t0 = std::chrono::steady_clock::now();
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-8, 20000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  out.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  out.non_convergent = res.non_convergent;
  out.ok = !res.non_convergent && res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises) &&
           res.von_mises_material_field.size() == density.size();
  if (!out.ok) return out;

  const double box = R + 4.0;
  std::vector<double> f = res.von_mises_material_field;
  // The box also limits which surface points are read and counted (`only`), so the tight
  // and unresolved counts are the fillet region's, not the whole bracket's.
  std::vector<char> in_box(density.size(), 0);
  for (int k = 0; k < nzv; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        const std::size_t idx = g.index(i, j, k);
        const double x = (i + 0.5) * inv, y = (j + 0.5) * inv;
        if (std::fabs(x - fcx) > box || std::fabs(y - fcy) > box) {
          f[idx] = 0.0;
          continue;
        }
        in_box[idx] = 1;
        if (res.von_mises_field.size() == density.size()) {
          out.per_voxel = std::max(out.per_voxel, res.von_mises_field[idx]);
        }
      }
  const topopt::SurfaceCarry sc = topopt::stress_carried_to_surface(g, f, density, 1, &in_box);
  out.carry = sc.peak;
  out.tight = sc.tight_points;
  out.unresolved = sc.unresolved;
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  int failures = 0;
  std::vector<Row> rows;
  double thin_carry2[4] = {0.0, 0.0, 0.0, 0.0};
  std::size_t thin_tight[4] = {0, 0, 0, 0}, thin_unresolved[4] = {0, 0, 0, 0};
  std::printf("[test E] plate with a hole, pulled at %.0f deg to the grid; peak / far "
              "stress, textbook %.2f\n",
              kTiltDeg, kTextbook);
  std::printf("%-12s %9s %14s %16s %14s %9s %9s %9s\n", "hole radius", "voxel mm",
              "all-or-nothing", "fill, E x fill^3", "fill, E x fill", "over 0.9", "over 1.8",
              "over 3.6");
  for (int r : {3, 4, 5, 6}) {
    Row row;
    row.radius_voxels = r;
    bool ok1 = false, ok2 = false, ok3 = false;
    row.ratio_binary = peak_ratio(r, false, 3.0, &ok1);
    row.ratio_fill = peak_ratio(r, true, 3.0, &ok2);
    row.ratio_fill_linear = peak_ratio(r, true, 1.0, &ok3, row.over_size);
    const double engine_carry = g_engine_carry;
    const std::size_t engine_unresolved = g_engine_unresolved;
    const double carry2 = g_carry2;
    thin_carry2[r - 3] = g_carry2;
    thin_tight[r - 3] = g_carry2_tight;
    thin_unresolved[r - 3] = g_carry2_unresolved;
    const std::size_t carry2_curved = g_carry2_curved, carry2_concave = g_carry2_concave,
                      carry2_tight = g_carry2_tight, carry2_capped = g_carry2_capped;
    const double patch[2] = {g_patch[0], g_patch[1]};
    const std::size_t patch_unresolved[2] = {g_patch_unresolved[0], g_patch_unresolved[1]};
    const double quad[2] = {g_quad[0], g_quad[1]};
    const std::size_t quad_unresolved[2] = {g_quad_unresolved[0], g_quad_unresolved[1]};
    const std::size_t quad_dropped[2] = {g_quad_dropped[0], g_quad_dropped[1]};
    if (!ok1 || !ok2 || !ok3) ++failures;
    std::printf("%-12d %9.3f %14.3f %16.3f %14.3f %9.3f %9.3f %9.3f\n", r,
                kHoleRadiusMm / r, row.ratio_binary, row.ratio_fill, row.ratio_fill_linear,
                row.over_size[0], row.over_size[1], row.over_size[2]);
    std::printf("[carry] hole radius %d voxels: ENGINE carry (E x fill), percent against the textbook %+.1f, unresolved %zu\n",
                r, 100.0 * (engine_carry / kTextbook - 1.0), engine_unresolved);
    std::printf("[carry2] hole radius %d voxels: curvature-shaped carry (E x fill), percent against the textbook %+.1f "
                "(straight line %+.1f), curved points %zu, of them concave %zu, tight %zu, capped %zu\n",
                r, 100.0 * (carry2 / kTextbook - 1.0), 100.0 * (engine_carry / kTextbook - 1.0),
                carry2_curved, carry2_concave, carry2_tight, carry2_capped);
    std::printf("[patch] hole radius %d voxels: tensor patch recovery (E x fill), percent against the textbook: "
                "radius 2.5: %+.1f %%, unresolved %zu; radius 3.5: %+.1f %%, unresolved %zu\n",
                r, 100.0 * (patch[0] / kTextbook - 1.0), patch_unresolved[0],
                100.0 * (patch[1] / kTextbook - 1.0), patch_unresolved[1]);
    std::printf("[patch] hole radius %d voxels: QUADRATIC patch (order 2): radius 3.5: %+.1f %%, unresolved %zu, squares dropped %zu; "
                "radius 4.5: %+.1f %%, unresolved %zu, squares dropped %zu\n",
                r, 100.0 * (quad[0] / kTextbook - 1.0), quad_unresolved[0], quad_dropped[0],
                100.0 * (quad[1] / kTextbook - 1.0), quad_unresolved[1], quad_dropped[1]);
    rows.push_back(row);
  }
  // WHERE IS A HOLE "RESOLVED" for the carry (the reviewer's bar of 2026-11-27: never
  // more than 5 % under where the feature is resolved)? The same reading at larger
  // hole radii, real stiffness only. Printed, never judged.
  // ONLY with `--large` (never in the suite): on 2026-11-27 these four solves did not
  // converge inside the cap on plates this wide and only two voxels thick (the fields
  // came back empty, every figure read -100 %), and took 15 minutes doing it.
  const bool large = argc > 1 && std::strcmp(argv[1], "--large") == 0;
  for (int r : {8, 10, 12, 16}) {
    if (!large) break;
    bool ok = false;
    double unused[3] = {0.0, 0.0, 0.0};
    const double one_voxel = peak_ratio(r, true, 1.0, &ok, unused);
    std::printf("[carry] hole radius %d voxels: ENGINE carry (E x fill) %+.1f %%, unresolved %zu; the one-voxel reading %+.1f %%; "
                "linear patch 2.5: %+.1f %%; quadratic patch 4.5: %+.1f %%\n",
                r, 100.0 * (g_engine_carry / kTextbook - 1.0), g_engine_unresolved,
                100.0 * (one_voxel / kTextbook - 1.0), 100.0 * (g_patch[0] / kTextbook - 1.0),
                100.0 * (g_quad[1] / kTextbook - 1.0));
    std::fflush(stdout);
  }
  auto band = [&](double Row::*f, const char* name) {
    double lo = 1e300, hi = 0.0, worst = 0.0;
    for (const Row& r : rows) {
      lo = std::min(lo, r.*f);
      hi = std::max(hi, r.*f);
      worst = std::max(worst, std::fabs(r.*f / kTextbook - 1.0));
    }
    const double spread = lo > 0.0 ? hi / lo - 1.0 : 9.99;
    const bool pass = worst <= 0.05 && spread <= 0.10;
    std::printf("%-18s worst miss from textbook %5.1f %%, spread across resolutions "
                "%5.1f %%  %s\n",
                name, 100.0 * worst, 100.0 * spread, pass ? "ok" : "outside rule 5");
    if (gate && !pass) ++failures;
  };
  band(&Row::ratio_binary, "all-or-nothing");
  band(&Row::ratio_fill, "fill, E x fill^3");
  band(&Row::ratio_fill_linear, "fill, E x fill");
  for (int q = 0; q < 3; ++q) {
    double lo = 1e300, hi = 0.0;
    for (const Row& r : rows) {
      lo = std::min(lo, r.over_size[q]);
      hi = std::max(hi, r.over_size[q]);
    }
    std::printf("read over %.1f mm   spread across resolutions %5.1f %%\n", kSizesMm[q],
                lo > 0.0 ? 100.0 * (hi / lo - 1.0) : 0.0);
  }
  // THE BAR (reviewer, 2026-11-26): the shipped reading may never read more than
  // 5 % BELOW the textbook at any resolution; stiffness and reading size are
  // judged together. Every pair of (how a cut voxel's stiffness goes with its
  // fill, the size the stress is read over), over the four resolutions.
  std::printf("\n[bar] lowest and highest reading against the textbook over the four resolutions, "
              "and their spread\n");
  std::printf("%-22s %-10s %10s %10s %10s  %s\n", "cut voxel stiffness", "read over", "lowest %",
              "highest %", "spread %", "never more than 5 % low?");
  for (double pen : {1.0, 2.0, 3.0}) {
    double lo[4] = {1e300, 1e300, 1e300, 1e300}, hi[4] = {0.0, 0.0, 0.0, 0.0};
    // Against the reading's OWN true value (the same average on the exact
    // solution): the lowest and highest miss over the resolutions.
    double own_lo[4] = {1e300, 1e300, 1e300, 1e300}, own_hi[4] = {-1e300, -1e300, -1e300, -1e300};
    for (int r : {3, 4, 5, 6}) {
      bool ok = false;
      double ae = 0.0;
      (void)ae;
      double os[3] = {0.0, 0.0, 0.0};
      const double peak = peak_ratio(r, true, pen, &ok, os);
      const double v[4] = {peak, os[0], os[1], os[2]};
      for (int q = 0; q < 4; ++q) {
        lo[q] = std::min(lo[q], v[q]);
        hi[q] = std::max(hi[q], v[q]);
        const double truth = q == 0 ? kTextbook : to_reference::plate_reading(kHoleRadiusMm, kSizesMm[q - 1], kThickness * kHoleRadiusMm / r);
        own_lo[q] = std::min(own_lo[q], v[q] / truth - 1.0);
        own_hi[q] = std::max(own_hi[q], v[q] / truth - 1.0);
      }
    }
    const char* names[4] = {"one voxel", "0.9 mm", "1.8 mm", "3.6 mm"};
    for (int q = 0; q < 4; ++q)
      std::printf("E x fill^%-12.0f %-10s %+10.1f %+10.1f %10.1f  %s\n", pen, names[q],
                  100.0 * (lo[q] / kTextbook - 1.0), 100.0 * (hi[q] / kTextbook - 1.0),
                  100.0 * (hi[q] / lo[q] - 1.0), lo[q] >= 0.95 * kTextbook ? "yes" : "NO");
    for (int q = 1; q < 4; ++q)
      std::printf("E x fill^%-12.0f %-10s against the reading's own true value: %+6.1f to %+6.1f %%  %s\n",
                  pen, names[q], 100.0 * own_lo[q], 100.0 * own_hi[q],
                  own_lo[q] >= -0.05 ? "never more than 5 % low" : "more than 5 % low somewhere");
  }

  // THE SWITCH POINT: real stiffness (E x fill), the size chosen to span a stated
  // number of voxels at each resolution, against the reading's own true value.
  // The smallest span from which every resolution is inside the bar (never more
  // than 5 % low, within 10 % of one another) is where the reading over a size
  // may take over from the one-voxel form.
  {
    const double kSpans[8] = {1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0};
    const int kRes[4] = {3, 4, 5, 6};
    double off[8][4];
    for (int ri = 0; ri < 4; ++ri) {
      const int r = kRes[ri];
      const double voxel = kHoleRadiusMm / r;
      g_switch_sizes_mm.clear();
      for (double s : kSpans) g_switch_sizes_mm.push_back(s * voxel);
      bool ok = false;
      double unused[3] = {0.0, 0.0, 0.0};
      (void)peak_ratio(r, true, 1.0, &ok, unused);
      for (int s = 0; s < 8; ++s) {
        const double mm = kSpans[s] * voxel;
        const double truth = to_reference::plate_reading(kHoleRadiusMm, mm, kThickness * kHoleRadiusMm / r);
        off[s][ri] = s < static_cast<int>(g_switch_readings.size())
                         ? 100.0 * (g_switch_readings[static_cast<std::size_t>(s)] / truth - 1.0)
                         : -999.0;
      }
    }
    g_switch_sizes_mm.clear();
    std::printf("\n[switch] E x fill read over a size (voxel centres and surface nodes), by the voxels the size spans; percent against the "
                "reading's own true value at radius 3 / 4 / 5 / 6 voxels\n");
    for (int s = 0; s < 8; ++s) {
      double lo = 1e9, hi = -1e9;
      for (int ri = 0; ri < 4; ++ri) {
        lo = std::min(lo, off[s][ri]);
        hi = std::max(hi, off[s][ri]);
      }
      std::printf("[switch] %4.2f voxels across: %+6.1f %+6.1f %+6.1f %+6.1f   lowest %+6.1f, spread %5.1f  %s\n",
                  kSpans[s], off[s][0], off[s][1], off[s][2], off[s][3], lo, hi - lo,
                  lo >= -5.0 && hi - lo <= 10.0 ? "inside the bar" : "outside");
    }
  }

  // THICK PLATES (the reviewer, 2026-11-27: "a plate several voxels thick, not 2"): the
  // same shape-1 reading (E x fill, the loaded edges masked) on the plate SIX voxels
  // thick, beside the two-voxel `[carry2]` rows. Print-only. The finest plate is skipped
  // when the one before it took over 70 s (it would take over about two minutes).
  if (!gate) {
    std::printf("\n[thick6] the plate 6 voxels thick (the [carry2] reading, E x fill, loaded edges masked); percent against the textbook %.2f\n",
                kTextbook);
    double last_seconds = 0.0;
    for (int r : {3, 4, 5, 6}) {
      if (r == 6 && last_seconds > 70.0) {
        std::printf("[thick6] hole radius 6 voxels: SKIPPED (radius 5 took %.0f s; radius 6 would take over about two minutes)\n",
                    last_seconds);
        continue;
      }
      bool ok = false;
      double unused[3] = {0.0, 0.0, 0.0};
      const auto t0 = std::chrono::steady_clock::now();
      (void)peak_ratio(r, true, 1.0, &ok, unused, 6);
      last_seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
      if (g_non_convergent || !ok) {
        std::printf("[thick6] hole radius %d voxels: the solve DID NOT CONVERGE inside its cap (20000 iterations); no reading "
                    "(two thick: %+.1f %%)\n", r, 100.0 * (thin_carry2[r - 3] / kTextbook - 1.0));
      } else {
        std::printf("[thick6] hole radius %d voxels: 6 thick %+.1f %%, tight %zu, unresolved %zu;  2 thick %+.1f %%, tight %zu, unresolved %zu\n",
                    r, 100.0 * (g_carry2 / kTextbook - 1.0), g_carry2_tight, g_carry2_unresolved,
                    100.0 * (thin_carry2[r - 3] / kTextbook - 1.0), thin_tight[r - 3], thin_unresolved[r - 3]);
      }
      std::printf("[thick6] (timing) hole radius %d voxels: %.1f s\n", r, last_seconds);
      std::fflush(stdout);
    }
  }

  // THE FILLET (a real 3D raiser), only when started without arguments.
  if (argc == 1) {
    std::printf("\n[fillet] L bracket, arms 8 voxels thick, extruded 6, inside-corner fillet, the corner opened by a 1 MPa "
                "end traction; readings in a box within R + 4 voxels of the fillet centre; the reference is the same "
                "bracket at 4 x the voxels per axis\n");
    for (double R : {4.0, 6.0}) {
      FilletReading fr[3];
      const int scales[3] = {1, 2, 4};
      for (int q = 0; q < 3; ++q) {
        fr[q] = fillet_reading(R, scales[q]);
        std::printf("[fillet] R = %.0f, %dx (%d x %d x %d voxels): ", R, scales[q], fr[q].nx, fr[q].nx, fr[q].nz);
        if (fr[q].ok)
          std::printf("shape-1 carry %.3f MPa, tight %zu, unresolved %zu; plain per-voxel peak %.3f MPa\n",
                      fr[q].carry, fr[q].tight, fr[q].unresolved, fr[q].per_voxel);
        else
          std::printf("the solve %s; no reading\n",
                      fr[q].non_convergent ? "DID NOT CONVERGE inside its cap (20000 iterations)" : "failed");
        std::printf("[fillet] (timing) R = %.0f, %dx: %.1f s\n", R, scales[q], fr[q].seconds);
        std::fflush(stdout);
      }
      const int ref = fr[2].ok ? 2 : (fr[1].ok ? 1 : -1);
      if (ref < 0 || !fr[0].ok) {
        std::printf("[fillet] R = %.0f: no comparison (a solve gave no reading)\n", R);
        continue;
      }
      if (ref == 2) {
        std::printf("[fillet] R = %.0f: against the 4x carry (%.3f MPa): base carry %+.1f %%, base plain per-voxel peak %+.1f %%; "
                    "4x plain per-voxel peak %+.1f %%\n",
                    R, fr[2].carry, 100.0 * (fr[0].carry / fr[2].carry - 1.0),
                    100.0 * (fr[0].per_voxel / fr[2].carry - 1.0),
                    100.0 * (fr[2].per_voxel / fr[2].carry - 1.0));
        if (fr[1].ok)
          std::printf("[fillet] R = %.0f: against the 4x carry: 2x carry %+.1f %%, 2x plain per-voxel peak %+.1f %%\n",
                      R, 100.0 * (fr[1].carry / fr[2].carry - 1.0),
                      100.0 * (fr[1].per_voxel / fr[2].carry - 1.0));
      } else {
        std::printf("[fillet] R = %.0f: the 4x model gave no reading; against the 2x carry (%.3f MPa) only: base carry %+.1f %%, "
                    "base plain per-voxel peak %+.1f %%\n",
                    R, fr[1].carry, 100.0 * (fr[0].carry / fr[1].carry - 1.0),
                    100.0 * (fr[0].per_voxel / fr[1].carry - 1.0));
      }
    }
  }

  std::printf("[test E] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
