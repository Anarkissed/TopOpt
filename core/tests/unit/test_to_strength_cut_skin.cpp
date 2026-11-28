// TO rebuild, stage 2, ONE JUDGE: what the stiffness law on CUT voxels does to a
// thin member (the finding of 2026-11-27 on Top Motor Mount: with the file's own
// fills at E x fill^3 the whole part read about 24 % higher and every version was
// refused). MEASURE ONLY: prints a table, judges nothing.
//
// A beam in pure bending whose two faces CUT their voxels: `core` full voxels
// through, plus one skin voxel on each side holding a fraction `fill` of material,
// so the true thickness is (core + 2 fill) voxels. The same end moment is put on
// every model (on the core's end faces; read at mid-span, away from the ends).
// Models of the skin:
//   all-or-nothing  the skin voxel is full when fill >= 0.5, absent below (the
//                   re-check today)
//   E x fill^3      the file's fill at the loop's law (one judge as built)
//   E x fill^2, E x fill   the same fill at the two other laws
// For each: the beam's CURVATURE against the exact beam of the true thickness
// (the stiffness the model sees: above 1 = too soft), and the PEAK the analysis
// reads at mid-span against the true surface stress.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/stress_measure.hpp"

namespace {

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;

constexpr double kH = 0.5;                // mm, the voxel
constexpr int kLength = 64, kWidth = 12;  // voxels along x and z
constexpr double kE = 3500.0;

struct Out {
  double curvature = 0.0;  // model / exact
  double peak = 0.0;       // the analysis's per-voxel reading at mid-span / true surface stress
  double peak_material = 0.0;  // the same from the material-stress field when the analysis gives one
  // MEASURING ARM (stage 4's question, measured ahead; not in the engine): the stress
  // of the two outermost FULL voxels carried in a straight line out to the TRUE
  // surface (half a voxel plus the skin's fill beyond the outer full voxel's centre).
  double at_surface = 0.0;
  // The engine's carry (stress_carried_to_surface), mid-span only, / true surface stress.
  double engine_carry = 0.0;
  std::size_t engine_unresolved = 0;
  // The patch recovery of the tensor (stress_recovered_at_surface), mid-span only, at
  // patch radius 2.5 and 3.5 voxels, / true surface stress.
  double patch25 = 0.0, patch35 = 0.0;
  double quad35 = 0.0, quad45 = 0.0;  // the quadratic patch (order 2) at radius 3.5 and 4.5
  double carry2 = 0.0;  // the curvature-shaped carry (shape 1)
  double carry_s2 = 0.0, carry_s3 = 0.0;  // shapes 2 and 3 (flat: must equal the straight line)
  // The one judge under TOPOPT_STRENGTH=surface (E x fill rows only): its max_von_mises
  // / true surface stress (the loaded ends included: the judge cannot mask them), its
  // tight and unresolved counts, and the same solve's material field read at the
  // surface (shape 1) at mid-span only, as the engine-carry row is.
  double judge = 0.0, judge_mid = 0.0;
  std::size_t judge_tight = 0, judge_unresolved = 0;
  // SECTION FORCES (task B, measuring arm): the stress from the mid-span section's own
  // forces (membrane N / A plus bending M c / I on the TRUE section) / true surface
  // stress (bending) or / N_applied / A_true (tension); the measured M (bending) or N
  // (tension) / the one applied, from the nodal loads as applied.
  double section = 0.0, section_ratio = 0.0;
  bool ok = false;
};

// skin_density < 0: the skin voxels are absent (Empty).
Out bend(int core, double fill, double skin_density, double penalty, bool tension = false) {
  VoxelGrid g;
  g.nx = kLength;
  g.ny = core + 2;
  g.nz = kWidth;
  g.spacing = kH;
  g.origin = Vec3{0.0, 0.0, 0.0};
  const std::size_t n = static_cast<std::size_t>(g.nx) * g.ny * g.nz;
  g.tags.assign(n, topopt::VoxelTag::Interior);
  std::vector<double> density(n, 1.0);
  for (int k = 0; k < g.nz; ++k)
    for (int i = 0; i < g.nx; ++i)
      for (int j : {0, g.ny - 1}) {
        const std::size_t v = g.index(i, j, k);
        if (skin_density < 0.0) {
          g.tags[v] = topopt::VoxelTag::Empty;
          density[v] = 0.0;
        } else {
          density[v] = skin_density;
        }
      }
  // The end moment, on the core's end faces only: a linear traction about the
  // mid-plane. Its moment per unit width, from the forces as they are applied.
  const double mid = 0.5 * g.ny * kH;
  const double q = 0.25 * kH * kH;
  double moment = 0.0;  // per unit width
  double applied_moment = 0.0, applied_force = 0.0;  // at the +x end, from the nodal loads as applied
  std::vector<NodalLoad> loads;
  for (int j = 1; j <= core; ++j) {
    const double arm = (j + 0.5) * kH - mid;
    // traction, MPa per mm of arm (any scale: everything is linear); uniform in tension
    const double s = tension ? 1.0 : arm;
    moment += s * kH * arm;
    for (int k = 0; k < g.nz; ++k)
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj) {
          loads.push_back({topopt::fea_node_index(g, g.nx, j + dj, k + dk), 0, q * s});
          loads.push_back({topopt::fea_node_index(g, 0, j + dj, k + dk), 0, -q * s});
          applied_force += q * s;
          applied_moment += q * s * ((j + dj) * kH - mid);
        }
  }
  std::vector<DirichletBC> bcs;
  const int a = topopt::fea_node_index(g, 0, 1, 0);
  const int b = topopt::fea_node_index(g, g.nx, 1, 0);
  const int c = topopt::fea_node_index(g, 0, 1, g.nz);
  bcs.push_back({a, 0, 0.0});
  bcs.push_back({a, 1, 0.0});
  bcs.push_back({a, 2, 0.0});
  bcs.push_back({b, 1, 0.0});
  bcs.push_back({b, 2, 0.0});
  bcs.push_back({c, 1, 0.0});

  topopt::Material m;
  m.youngs_modulus_mpa = kE;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 1.0;
  m.poisson = 0.33;
  m.family = "fdm";
  topopt::SimpParams params;
  params.youngs_modulus = kE;
  params.poisson = m.poisson;
  params.penalty = penalty;
  topopt::KnockdownSpec knockdown;
  knockdown.record_material_stress = true;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-9, 60000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true, static_cast<double>(n));
  Out o;
  o.ok = !res.non_convergent && res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  if (!o.ok) return o;
  // The exact beam of the true thickness under this moment.
  const double thick = (core + 2.0 * fill) * kH;
  const double surface = 6.0 * moment / (thick * thick);
  const double exact_curvature = 12.0 * moment / (kE * thick * thick * thick);
  {
    // SECTION FORCES: the model's own displacement (its own solve: the analysis zeroes
    // the nodes of voxels it does not print, which a thin skin's outer nodes are), the
    // unconstrained operator applied over the elements on the low-x side of the cut at
    // mid-span only, read at the nodes on the cut plane: the section's nodal forces.
    const topopt::SimpCompliance own = topopt::simp_compliance(
        g, params, density, bcs, loads, 1e-9, 60000, nullptr, nullptr,
        topopt::SolverKind::MultigridCG_Matfree);
    std::vector<double> youngs(n, 0.0);
    for (std::size_t v = 0; v < n; ++v)
      if (g.tags[v] != topopt::VoxelTag::Empty) youngs[v] = topopt::simp_youngs(params, density[v]);
    const int i_cut = g.nx / 2;
    VoxelGrid left = g;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = i_cut; i < g.nx; ++i) left.tags[g.index(i, j, k)] = topopt::VoxelTag::Empty;
    const std::vector<double> Ku = topopt::fea_matfree_apply(left, youngs, params.poisson, own.solution.u);
    double N = 0.0, M = 0.0;
    for (int k = 0; k <= g.nz; ++k)
      for (int j = 0; j <= g.ny; ++j) {
        const double F = Ku[3 * static_cast<std::size_t>(topopt::fea_node_index(g, i_cut, j, k))];
        N += F;
        M += F * (j * kH - mid);
      }
    // The TRUE section: (core + 2 fill) voxels through about the mid-plane, the beam's width.
    const double width = g.nz * kH;
    const double A = thick * width, I = width * thick * thick * thick / 12.0, c = 0.5 * thick;
    const double sigma = std::fabs(N) / A + std::fabs(M) * c / I;
    if (tension) {
      const double exact = applied_force / A;
      o.section = sigma / exact;
      o.section_ratio = applied_force != 0.0 ? std::fabs(N) / std::fabs(applied_force) : 0.0;
      // the plain per-voxel peak at mid-span over the same
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = g.nx / 4; i < 3 * g.nx / 4; ++i)
            o.peak = std::max(o.peak, res.von_mises_field[g.index(i, j, k)] / exact);
      return o;
    }
    o.section = sigma / surface;
    o.section_ratio = applied_moment != 0.0 ? std::fabs(M) / std::fabs(applied_moment) : 0.0;
  }
  // Curvature from the rotation of two cross-sections (the core's top and bottom
  // node planes), a quarter and three quarters along, mid-width.
  const int kz = g.nz / 2;
  auto ux = [&](int i, int j) {
    return res.displacement_field[3 * static_cast<std::size_t>(topopt::fea_node_index(g, i, j, kz))];
  };
  const int i0 = g.nx / 4, i1 = 3 * g.nx / 4;
  const double height = core * kH;
  const double rot0 = (ux(i0, core + 1) - ux(i0, 1)) / height;
  const double rot1 = (ux(i1, core + 1) - ux(i1, 1)) / height;
  o.curvature = std::fabs(rot1 - rot0) / ((i1 - i0) * kH) / exact_curvature;
  for (int k = 2; k < g.nz - 2; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = i0; i < i1; ++i) {
        const std::size_t v = g.index(i, j, k);
        if (v < res.von_mises_field.size()) o.peak = std::max(o.peak, res.von_mises_field[v] / surface);
        if (v < res.von_mises_material_field.size() && density[v] >= topopt::kStressMaterialFloor)
          o.peak_material = std::max(o.peak_material, res.von_mises_material_field[v] / surface);
      }
  if (core >= 3 && res.von_mises_material_field.size() == n) {
    const int im = g.nx / 2;
    const std::vector<double>& f = res.von_mises_material_field;
    const double top = f[g.index(im, core, kz)], top_in = f[g.index(im, core - 1, kz)];
    const double bot = f[g.index(im, 1, kz)], bot_in = f[g.index(im, 2, kz)];
    const double reach = 0.5 + fill;  // voxels from the outer full voxel's centre to the true surface
    o.at_surface = std::max(top + (top - top_in) * reach, bot + (bot - bot_in) * reach) / surface;
  }
  if (res.von_mises_material_field.size() == n) {
    // Only mid-span stresses may make the peak: the loaded ends disturb the field.
    std::vector<double> mid_field = res.von_mises_material_field;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i)
          if (i < g.nx / 4 || i >= 3 * g.nx / 4 || k < 2 || k >= g.nz - 2)
            mid_field[g.index(i, j, k)] = 0.0;
    const topopt::SurfaceCarry sc = topopt::stress_carried_to_surface(g, mid_field, density);
    o.engine_carry = sc.peak / surface;
    o.engine_unresolved = sc.unresolved;
    o.carry2 = topopt::stress_carried_to_surface(g, mid_field, density, 1).peak / surface;
    o.carry_s2 = topopt::stress_carried_to_surface(g, mid_field, density, 2).peak / surface;
    o.carry_s3 = topopt::stress_carried_to_surface(g, mid_field, density, 3).peak / surface;
  }
  if (penalty == 1.0 && skin_density >= 0.0) {
    setenv("TOPOPT_STRENGTH", "surface", 1);
    const topopt::FixedDesignAnalysis rs = topopt::analyze_fixed_design(
        g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-9, 60000,
        topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true, static_cast<double>(n));
    unsetenv("TOPOPT_STRENGTH");
    o.judge = rs.max_von_mises / surface;
    o.judge_tight = rs.surface_tight_points;
    o.judge_unresolved = rs.surface_unresolved_points;
    if (rs.von_mises_material_field.size() == n) {
      std::vector<double> mf = rs.von_mises_material_field;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i)
            if (i < g.nx / 4 || i >= 3 * g.nx / 4 || k < 2 || k >= g.nz - 2)
              mf[g.index(i, j, k)] = 0.0;
      o.judge_mid = topopt::stress_carried_to_surface(g, mf, density, 1).peak / surface;
    }
  }
  if (res.stress_tensor_field.size() == 6 * n) {
    std::vector<double> mid_tensor = res.stress_tensor_field;  // the same mask as the carry
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i)
          if (i < g.nx / 4 || i >= 3 * g.nx / 4 || k < 2 || k >= g.nz - 2)
            for (int c = 0; c < 6; ++c) mid_tensor[6 * g.index(i, j, k) + c] = 0.0;
    o.patch25 = topopt::stress_recovered_at_surface(g, mid_tensor, density, nullptr, 2.5).peak / surface;
    o.patch35 = topopt::stress_recovered_at_surface(g, mid_tensor, density, nullptr, 3.5).peak / surface;
    o.quad35 = topopt::stress_recovered_at_surface(g, mid_tensor, density, nullptr, 3.5, 2).peak / surface;
    o.quad45 = topopt::stress_recovered_at_surface(g, mid_tensor, density, nullptr, 4.5, 2).peak / surface;
  }
  return o;
}

}  // namespace

int main() {
  unsetenv("TOPOPT_STRENGTH");
  int failures = 0;
  std::printf("[cut skin] a beam in pure bending, `core` full voxels through plus a skin voxel of the given fill on each face.\n");
  std::printf("[cut skin] curvature = model / exact (above 1: the model is too soft); peak = the reading at mid-span / the true surface stress\n");
  for (int core : {2, 4, 8, 16})
    for (double fill : {0.25, 0.5, 0.75}) {
      std::printf("[cut skin] core %2d, skin fill %.2f (true thickness %.2f voxels):\n", core, fill, core + 2.0 * fill);
      struct Model { const char* name; double skin; double penalty; };
      const Model models[4] = {{"all-or-nothing", fill >= 0.5 ? 1.0 : -1.0, 3.0},
                               {"E x fill^3    ", fill, 3.0},
                               {"E x fill^2    ", fill, 2.0},
                               {"E x fill      ", fill, 1.0}};
      for (const Model& md : models) {
        const Out o = bend(core, fill, md.skin, md.penalty);
        if (!o.ok) {
          ++failures;
          std::printf("[cut skin]   %s  DID NOT SOLVE\n", md.name);
          continue;
        }
        std::printf("[cut skin]   %s  curvature %.3f (%+.0f %%)   peak %.3f (%+.0f %%)   material-stress peak %.3f   "
                    "carried to the true surface %.3f (%+.0f %%)   engine carry %.3f (%+.0f %%), unresolved %zu   patch2.5 %.3f, patch3.5 %.3f   patch2 3.5 %.3f, 4.5 %.3f   carry2 %.3f",
                    md.name, o.curvature, 100.0 * (o.curvature - 1.0), o.peak, 100.0 * (o.peak - 1.0),
                    o.peak_material, o.at_surface, 100.0 * (o.at_surface - 1.0), o.engine_carry,
                    100.0 * (o.engine_carry - 1.0), o.engine_unresolved, o.patch25, o.patch35, o.quad35, o.quad45, o.carry2);
        if (md.penalty == 1.0 && md.skin >= 0.0)
          std::printf("   JUDGE(surface) %.3f, tight %zu, unresolved %zu (its field at mid-span only, at the surface: %.3f)",
                      o.judge, o.judge_tight, o.judge_unresolved, o.judge_mid);
        std::printf("   SECTION %.3f (M measured / applied %.4f)", o.section, o.section_ratio);
        std::printf("\n");
        std::printf("[cut skin s2/s3]   %s  s2 %.6f, s3 %.6f; straight line (engine carry) %.6f, carry2 %.6f: %s\n",
                    md.name, o.carry_s2, o.carry_s3, o.engine_carry, o.carry2,
                    o.carry_s2 == o.engine_carry && o.carry_s3 == o.engine_carry ? "s2 = s3 = the straight line"
                                                                                   : "DIFFERENT from the straight line");
        std::fflush(stdout);
      }
    }
  // SECTION FORCES, 2 to 6 voxels through densely (task B): cores 1, 3 and 6, the two
  // models that matter.
  std::printf("[section] extra cores: stress from the mid-span section's own forces / true surface stress, and M measured / M applied\n");
  for (int core : {1, 3, 6})
    for (double fill : {0.25, 0.5, 0.75}) {
      const struct { const char* name; double skin; double penalty; } extra[2] = {
          {"all-or-nothing", fill >= 0.5 ? 1.0 : -1.0, 3.0}, {"E x fill      ", fill, 1.0}};
      for (const auto& md : extra) {
        const Out o = bend(core, fill, md.skin, md.penalty);
        if (!o.ok) {
          // measuring rows: a row that does not solve is printed, not counted
          std::printf("[section] core %d, fill %.2f, %s  DID NOT SOLVE\n", core, fill, md.name);
          continue;
        }
        std::printf("[section] core %d, fill %.2f (true thickness %.2f voxels), %s   peak %.3f   carry2 %.3f   SECTION %.3f (M measured / applied %.4f)\n",
                    core, fill, core + 2.0 * fill, md.name, o.peak, o.carry2, o.section, o.section_ratio);
        std::fflush(stdout);
      }
    }
  // A MEMBER IN TENSION: the same beam pulled by a uniform end traction on the core.
  std::printf("[section] tension: section-force stress / (N applied / A true), per-voxel peak at mid-span / the same, N measured / N applied\n");
  for (int core : {2, 4}) {
    const double fill = 0.5;
    const struct { const char* name; double skin; double penalty; } tm[2] = {
        {"all-or-nothing", 1.0, 3.0}, {"E x fill      ", fill, 1.0}};
    for (const auto& md : tm) {
      const Out o = bend(core, fill, md.skin, md.penalty, true);
      if (!o.ok) {
        // measuring rows: a row that does not solve is printed, not counted
        std::printf("[section] tension core %d, %s  DID NOT SOLVE\n", core, md.name);
        continue;
      }
      std::printf("[section] tension core %d, fill %.2f, %s   SECTION %.3f   per-voxel peak %.3f   (N measured / applied %.4f)\n",
                  core, fill, md.name, o.section, o.peak, o.section_ratio);
      std::fflush(stdout);
    }
  }
  std::printf("[cut skin] measure only: %d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
