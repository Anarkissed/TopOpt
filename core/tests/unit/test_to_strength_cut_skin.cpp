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

// ── THE STATICALLY INDETERMINATE CASE (the reviewer's ruling: first in stage 4a's
// measuring; print only). Two parallel members of DIFFERENT true thickness, t1 = 2.5
// and t2 = 6.5 base voxels, a gap of 6 voxels between them, joined by solid end
// blocks 6 voxels long; length and width as the beam above. Cut faces sit a quarter
// voxel off the grid: member 1 spans y = 0.75..3.25 voxels, member 2 y = 9.25..15.75,
// the blocks y = 0.75..15.75. Every voxel's fill is its share of the true shape
// (exact here: the shape is a union of boxes), real stiffness E x fill. Loaded
// self-equilibrated on the two end faces (traction x fill on each voxel face):
// tension = uniform; bending = linear about the end face's own centroid. How the load
// SPLITS between the members is set by their stiffness in the model: that split is
// what this exposes. The reference is the same shape at 4x the resolution.
namespace ind {

constexpr double kY1a = 0.75, kY1b = 3.25, kY2a = 9.25, kY2b = 15.75;  // base voxels
constexpr int kBlock = 6, kNy = 17;

struct Model {
  VoxelGrid g;
  std::vector<double> density;
  std::vector<NodalLoad> loads;
  std::vector<DirichletBC> bcs;
  int s = 1;
  double h = kH;
};

double overlap(double a0, double a1, double b0, double b1) {
  return std::max(0.0, std::min(a1, b1) - std::max(a0, b0));
}

Model build(int s, bool tension) {
  Model md;
  md.s = s;
  md.h = kH / s;
  VoxelGrid& g = md.g;
  g.nx = kLength * s;
  g.ny = kNy * s;
  g.nz = kWidth * s;
  g.spacing = md.h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  const std::size_t n = static_cast<std::size_t>(g.nx) * g.ny * g.nz;
  g.tags.assign(n, topopt::VoxelTag::Empty);
  md.density.assign(n, 0.0);
  const double vb = 1.0 / s;  // a voxel, in base voxels
  for (int i = 0; i < g.nx; ++i) {
    const bool block = i < kBlock * s || i >= (kLength - kBlock) * s;
    for (int j = 0; j < g.ny; ++j) {
      const double y0 = j * vb, y1 = (j + 1) * vb;
      const double f = block ? overlap(y0, y1, kY1a, kY2b) / vb
                             : (overlap(y0, y1, kY1a, kY1b) + overlap(y0, y1, kY2a, kY2b)) / vb;
      if (!(f > 0.0)) continue;
      for (int k = 0; k < g.nz; ++k) {
        const std::size_t v = g.index(i, j, k);
        g.tags[v] = topopt::VoxelTag::Interior;
        md.density[v] = f;
      }
    }
  }
  // The end face's centroid (fill-weighted), for the bending traction.
  double fa = 0.0, fy = 0.0;
  for (int j = 0; j < g.ny; ++j) {
    const double f = md.density[g.index(0, j, 0)];
    fa += f;
    fy += f * (j + 0.5) * md.h;
  }
  const double yc = fy / fa;
  for (int j = 0; j < g.ny; ++j)
    for (int k = 0; k < g.nz; ++k) {
      const double f = md.density[g.index(0, j, k)];
      if (!(f > 0.0)) continue;
      const double t = tension ? 1.0 : ((j + 0.5) * md.h - yc);  // MPa (any scale)
      const double q = 0.25 * md.h * md.h * f * t;
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj) {
          md.loads.push_back({topopt::fea_node_index(g, g.nx, j + dj, k + dk), 0, q});
          md.loads.push_back({topopt::fea_node_index(g, 0, j + dj, k + dk), 0, -q});
        }
    }
  const int jb = 8 * s;  // a node inside the block
  const int a = topopt::fea_node_index(g, 0, jb, 0);
  const int b = topopt::fea_node_index(g, g.nx, jb, 0);
  const int c = topopt::fea_node_index(g, 0, jb, g.nz);
  md.bcs = {{a, 0, 0.0}, {a, 1, 0.0}, {a, 2, 0.0}, {b, 1, 0.0}, {b, 2, 0.0}, {c, 1, 0.0}};
  return md;
}

struct Member {
  double N = 0.0, M_true = 0.0;  // section forces; M about the TRUE centroid
  double model_section = 0.0;    // (1) section from the model's own fills on the cut
  double true_section = 0.0;     // (2) the true section handed in
  double peak = 0.0;             // (3) per-voxel peak at mid-span in the member
  double carry = 0.0;            // (4) stress_carried_to_surface(.., 1), member mid-span
};

struct Result {
  bool ok = false;
  Member m[2];
};

Result measure(const Model& md) {
  const VoxelGrid& g = md.g;
  const std::size_t n = g.voxel_count();
  topopt::Material mat;
  mat.youngs_modulus_mpa = kE;
  mat.yield_strength_mpa = 55.0;
  mat.density_g_cm3 = 1.24;
  mat.z_knockdown = 1.0;
  mat.poisson = 0.33;
  mat.family = "fdm";
  topopt::SimpParams params;
  params.youngs_modulus = kE;
  params.poisson = mat.poisson;
  params.penalty = 1.0;  // real stiffness: E x fill
  topopt::KnockdownSpec knockdown;
  knockdown.record_material_stress = true;
  Result r;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, md.density, md.bcs, md.loads, mat, Vec3{0.0, 0.0, 1.0}, 1e-9, 60000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true, static_cast<double>(n));
  if (res.non_convergent || !(res.max_von_mises > 0.0)) return r;
  const topopt::SimpCompliance own = topopt::simp_compliance(
      g, params, md.density, md.bcs, md.loads, 1e-9, 60000, nullptr, nullptr,
      topopt::SolverKind::MultigridCG_Matfree);
  std::vector<double> youngs(n, 0.0);
  for (std::size_t v = 0; v < n; ++v)
    if (g.tags[v] != topopt::VoxelTag::Empty) youngs[v] = topopt::simp_youngs(params, md.density[v]);
  const int i_cut = g.nx / 2;
  VoxelGrid left = g;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = i_cut; i < g.nx; ++i) left.tags[g.index(i, j, k)] = topopt::VoxelTag::Empty;
  const std::vector<double> Ku = topopt::fea_matfree_apply(left, youngs, params.poisson, own.solution.u);
  const double h = md.h, width = g.nz * h;
  const double ya[2] = {kY1a * kH, kY2a * kH}, yb[2] = {kY1b * kH, kY2b * kH};  // mm
  const bool have_mat = res.von_mises_material_field.size() == n;
  for (int q = 0; q < 2; ++q) {
    Member& mb = r.m[q];
    const int jlo = static_cast<int>(std::floor(ya[q] / h + 1e-9));
    const int jhi = static_cast<int>(std::ceil(yb[q] / h - 1e-9)) - 1;  // voxels jlo..jhi
    // Section forces at the cut nodes of this member (nodes jlo..jhi+1).
    double N = 0.0, Fy = 0.0;
    for (int k = 0; k <= g.nz; ++k)
      for (int j = jlo; j <= jhi + 1; ++j) {
        const double F = Ku[3 * static_cast<std::size_t>(topopt::fea_node_index(g, i_cut, j, k))];
        N += F;
        Fy += F * j * h;
      }
    // (2) the TRUE section.
    const double t = yb[q] - ya[q], yt = 0.5 * (ya[q] + yb[q]);
    const double At = t * width, It = width * t * t * t / 12.0;
    mb.N = N;
    mb.M_true = Fy - N * yt;
    mb.true_section = std::fabs(N) / At + std::fabs(mb.M_true) * (0.5 * t) / It;
    // (1) the section FROM THE MODEL'S OWN FILLS on the cut (the voxel slab at i_cut):
    // area = sum fill x voxel area; centroid and second moment of each voxel's fill
    // smeared over its height; the extreme fibre = the outermost voxel's inner edge
    // plus its fill x h (the fill taken against the material).
    double A = 0.0, Ay = 0.0;
    for (int j = jlo; j <= jhi; ++j)
      for (int k = 0; k < g.nz; ++k) {
        const double f = md.density[g.index(i_cut, j, k)];
        A += f * h * h;
        Ay += f * h * h * (j + 0.5) * h;
      }
    const double ym = Ay / A;
    double I = 0.0;
    for (int j = jlo; j <= jhi; ++j)
      for (int k = 0; k < g.nz; ++k) {
        const double f = md.density[g.index(i_cut, j, k)];
        const double d = (j + 0.5) * h - ym;
        I += f * h * h * (d * d + h * h / 12.0);
      }
    const double ftop = md.density[g.index(i_cut, jhi, 0)], fbot = md.density[g.index(i_cut, jlo, 0)];
    const double top = jhi * h + ftop * h, bot = (jlo + 1) * h - fbot * h;
    const double cm = std::max(top - ym, ym - bot);
    const double Mm = Fy - N * ym;
    mb.model_section = std::fabs(N) / A + std::fabs(Mm) * cm / I;
    // (3) and (4): mid-span, inside the side margin, this member's voxels only.
    std::vector<double> mf(have_mat ? n : 0, 0.0);
    for (int k = 2 * md.s; k < g.nz - 2 * md.s; ++k)
      for (int j = jlo; j <= jhi; ++j)
        for (int i = g.nx / 4; i < 3 * g.nx / 4; ++i) {
          const std::size_t v = g.index(i, j, k);
          if (v < res.von_mises_field.size()) mb.peak = std::max(mb.peak, res.von_mises_field[v]);
          if (have_mat) mf[v] = res.von_mises_material_field[v];
        }
    if (have_mat) mb.carry = topopt::stress_carried_to_surface(g, mf, md.density, 1).peak;
  }
  r.ok = true;
  return r;
}

void run() {
  std::printf("[indeterminate] two parallel members (true 2.5 and 6.5 base voxels through, gap 6) joined by end blocks; "
              "fills from the true shape, E x fill. Base readings as %% against the 4x model read by (2), "
              "the true section at its own cut.\n");
  for (bool tension : {true, false}) {
    const char* cname = tension ? "tension" : "bending";
    const Result base = measure(build(1, tension));
    const Result fine = measure(build(4, tension));
    if (!base.ok || !fine.ok) {
      std::printf("[indeterminate] %s: DID NOT SOLVE (base %d, 4x %d)\n", cname, base.ok ? 1 : 0, fine.ok ? 1 : 0);
      continue;
    }
    auto pct = [](double x, double ref) { return ref != 0.0 ? 100.0 * (x / ref - 1.0) : 0.0; };
    for (int q = 0; q < 2; ++q) {
      const Member& b = base.m[q];
      const Member& f = fine.m[q];
      const double ref = f.true_section;
      std::printf("[indeterminate] %s member %d (t %.1f): ref 4x (2) %.4f MPa, 4x (4) carry %.4f (%+.1f %%) | base: "
                  "(1) model section %+.1f %%  (2) true section %+.1f %%  (3) per-voxel peak %+.1f %%  (4) carry %+.1f %%\n",
                  cname, q + 1, q == 0 ? kY1b - kY1a : kY2b - kY2a, ref, f.carry, pct(f.carry, ref),
                  pct(b.model_section, ref), pct(b.true_section, ref), pct(b.peak, ref), pct(b.carry, ref));
    }
    auto share = [](double a, double b) { return std::fabs(a) + std::fabs(b) > 0.0 ? std::fabs(a) / (std::fabs(a) + std::fabs(b)) : 0.0; };
    std::printf("[indeterminate] %s load share: N1 base %.4f 4x %.4f, N2 base %.4f 4x %.4f; member 1's share of |N| base %.3f 4x %.3f\n",
                cname, base.m[0].N, fine.m[0].N, base.m[1].N, fine.m[1].N,
                share(base.m[0].N, base.m[1].N), share(fine.m[0].N, fine.m[1].N));
    std::printf("[indeterminate] %s moments (about each member's true centroid): M1 base %.4f 4x %.4f, M2 base %.4f 4x %.4f; "
                "member 1's share of |M| base %.3f 4x %.3f\n",
                cname, base.m[0].M_true, fine.m[0].M_true, base.m[1].M_true, fine.m[1].M_true,
                share(base.m[0].M_true, base.m[1].M_true), share(fine.m[0].M_true, fine.m[1].M_true));
    std::fflush(stdout);
  }
}

}  // namespace ind

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
  std::fflush(stdout);
  ind::run();  // print only: the statically indeterminate case
  return failures == 0 ? 0 : 1;
}
