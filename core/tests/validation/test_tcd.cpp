// THE CORNER FIX (the reviewer's ruling of 2026-10-26 13:12): every margin is taken on
// the stress averaged over a fixed critical volume (the Theory of Critical Distances,
// volume method, radius kTcdRadiusMm; Ahmed & Susmel 2017, 2019), not at the single
// worst voxel, so a sharp corner stops reading higher at every finer grid.
//   (a) a straight bar in PLAIN TENSION (supported so its stress is uniform): the margin
//       is within 2 % of the raw one and of yield / (F / A): a uniform stress is never
//       forgiven;
//   (b) an L-bracket with a sharp re-entrant corner, clamped at its foot and loaded at
//       its tip, at h = 1, 0.5, 0.25 and 0.125 mm: the averaged margin changes under 5 %
//       from 0.25 to 0.125 mm while the raw single-voxel margin keeps falling. (It
//       settles once the voxel is well under the radius: at h ~ the radius it cannot.)
//   (c) the raw peaks are kept beside the averaged ones, and a grid coarser than the
//       radius reads its raw margin exactly.
// Eigen (the assembled Jacobi-CG solve), OCCT-free.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

Material pla() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

VoxelGrid blank(double lx, double ly, double lz, double h) {
  VoxelGrid g;
  g.nx = static_cast<int>(std::lround(lx / h));
  g.ny = static_cast<int>(std::lround(ly / h));
  g.nz = static_cast<int>(std::lround(lz / h));
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  return g;
}

FixedDesignAnalysis certify(const VoxelGrid& g, const std::vector<DirichletBC>& bcs,
                            const std::vector<NodalLoad>& loads,
                            SolverKind solver = SolverKind::MultigridCG_Matfree) {
  SimpParams p;
  p.youngs_modulus = pla().youngs_modulus_mpa;
  p.poisson = pla().poisson;
  const std::vector<double> rho(g.voxel_count(), 1.0);
  return analyze_fixed_design(g, p, rho, bcs, loads, pla(), Vec3{0.0, 0.0, 1.0}, 1e-10, 0,
                              solver, 1.5, KnockdownSpec{}, true,
                              static_cast<double>(g.solid_count()));
}

// The L-bracket: a 4 mm wide vertical leg (x 0..4, y 0..16) and a 4 mm tall arm (x 0..16,
// y 12..16), 2 mm thick; the re-entrant corner is at (4, 12). Clamped at its foot (y = 0),
// pushed down on its tip (x = 16).
FixedDesignAnalysis bracket(double h) {
  VoxelGrid g = blank(16.0, 16.0, 2.0, h);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const Vec3 c = g.voxel_center(i, j, k);
        if (c.x < 4.0 || c.y > 12.0) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  for (int k = 0; k < g.nz; ++k)
    for (int i = 0; i < g.nx; ++i)
      if (g.solid(i, 0, k)) g.set_tag(i, 0, k, VoxelTag::Fixture);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      if (g.solid(g.nx - 1, j, k)) g.set_tag(g.nx - 1, j, k, VoxelTag::Load);
  std::vector<DirichletBC> bcs;
  for (const int n : fea_tagged_nodes(g, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
  return certify(g, bcs, traction_loads(g, VoxelTag::Load, Vec3{0.0, -40.0, 0.0}));
}

}  // namespace

int main() {
  // ── (a) a bar in plain tension ───────────────────────────────────────────────
  {
    const double F = 400.0, A = 8.0 * 8.0;
    VoxelGrid g = blank(40.0, 8.0, 8.0, 0.5);
    for (VoxelTag& t : g.tags) t = VoxelTag::Interior;
    // Supported so the stress is uniform: x held on the x = 0 face, plus the fewest
    // other constraints that stop it spinning; F spread over the x = L face's nodes as
    // a uniform traction (each node its share of the face area), not over the last
    // slice's side faces too.
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= g.nz; ++c)
      for (int b = 0; b <= g.ny; ++b) bcs.push_back({fea_node_index(g, 0, b, c), 0, 0.0});
    bcs.push_back({fea_node_index(g, 0, 0, 0), 1, 0.0});
    bcs.push_back({fea_node_index(g, 0, 0, 0), 2, 0.0});
    bcs.push_back({fea_node_index(g, 0, g.ny, 0), 2, 0.0});
    std::vector<NodalLoad> loads;
    double wsum = 0.0;
    for (int c = 0; c <= g.nz; ++c)
      for (int b = 0; b <= g.ny; ++b)
        wsum += (b == 0 || b == g.ny ? 0.5 : 1.0) * (c == 0 || c == g.nz ? 0.5 : 1.0);
    for (int c = 0; c <= g.nz; ++c)
      for (int b = 0; b <= g.ny; ++b)
        loads.push_back({fea_node_index(g, g.nx, b, c), 0,
                         F * (b == 0 || b == g.ny ? 0.5 : 1.0) *
                             (c == 0 || c == g.nz ? 0.5 : 1.0) / wsum});
    const FixedDesignAnalysis a = certify(g, bcs, loads);
    const double nominal = pla().yield_strength_mpa / (F / A);
    std::printf("[tcd] bar in tension: margin %.4f (raw peak %.4f MPa, averaged %.4f MPa), "
                "yield / (F/A) = %.4f, radius %.3f mm\n", a.margin.in_plane,
                a.peak_von_mises_raw, a.max_von_mises, nominal, a.tcd_radius_mm);
    CHECK(std::fabs(a.margin.in_plane - nominal) <= 0.02 * nominal &&
              std::fabs(a.max_von_mises - a.peak_von_mises_raw) <= 0.02 * a.peak_von_mises_raw,
          "(a) plain tension: the margin is within 2 % of yield / (F/A) and of the raw one");
  }

  // ── (b) the L-bracket's re-entrant corner ────────────────────────────────────
  {
    const double hs[4] = {1.0, 0.5, 0.25, 0.125};
    double m[4], raw[4];
    for (int r = 0; r < 4; ++r) {
      const FixedDesignAnalysis a = bracket(hs[r]);
      m[r] = a.margin.in_plane;
      raw[r] = pla().yield_strength_mpa / a.peak_von_mises_raw;
      std::printf("[tcd] L-bracket h %.2f mm: margin %.4f (averaged %.3f MPa), raw single-voxel "
                  "margin %.4f (peak %.3f MPa)\n", hs[r], m[r], a.max_von_mises, raw[r],
                  a.peak_von_mises_raw);
      CHECK(a.max_von_mises <= a.peak_von_mises_raw + 1e-12, "(c) the average never exceeds the peak");
    }
    const double change = std::fabs(m[3] - m[2]) / m[2];
    const double raw_change = std::fabs(raw[3] - raw[2]) / raw[2];
    std::printf("[tcd] L-bracket 0.25 -> 0.125 mm: averaged %.2f %%, raw %.2f %%\n",
                100.0 * change, 100.0 * raw_change);
    CHECK(change < 0.05, "(b) the averaged margin changes under 5 % from h 0.25 to 0.125 mm");
    CHECK(raw_change > change, "(b) the raw single-voxel margin drifts more (the corner it fixes)");
  }

  // ── (c) a grid coarser than the radius reads its raw margin exactly ──────────
  {
    VoxelGrid g = blank(40.0, 8.0, 8.0, 2.0);
    for (VoxelTag& t : g.tags) t = VoxelTag::Interior;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j) {
        g.set_tag(0, j, k, VoxelTag::Fixture);
        g.set_tag(g.nx - 1, j, k, VoxelTag::Load);
      }
    std::vector<DirichletBC> bcs;
    for (const int n : fea_tagged_nodes(g, VoxelTag::Fixture))
      for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
    const FixedDesignAnalysis a =
        certify(g, bcs, traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -100.0}));
    CHECK(kTcdRadiusMm < g.spacing && a.max_von_mises == a.peak_von_mises_raw &&
              a.max_interlayer_tension == a.peak_interlayer_raw,
          "(c) a voxel coarser than the radius: the averaged stress IS the raw one");
  }

  if (g_failures == 0) {
    std::printf("tcd (the corner fix): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "tcd (the corner fix): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
