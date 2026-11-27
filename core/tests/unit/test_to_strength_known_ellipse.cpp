// TO rebuild stage 2, the THIRD SHAPE (the reviewer's ruling of 2026-11-26, item 5).
//
// "E x fill^2 read at one voxel" passed the 5 % bar on the plate with a round hole
// and on the thick ring, but it was FOUND on those two shapes. Before it may
// replace today's reading (for a stress-reading size under the check voxel, and
// for materials with no published length), it is run here on a shape that had no
// part in choosing it: an ELLIPTICAL hole with a / b = 2 in a wide plate under
// tension, the long axis across the pull. The peak at the end of the long axis is
// (1 + 2 a / b) = 5 times the far stress (Inglis 1913, exact for an infinite
// plate; here the hole's long axis is a fifth of the plate's width, so the finite
// width RAISES the true peak by a few percent: judging against 5.00 is therefore
// the lenient side, and a reading that misses 5.00 misses the true value by more).
//
// As in the round-hole test the pull is tilted 30 degrees to the grid and the
// hole's centre sits off the grid lines, and the SAME physical plate (b = 3 mm,
// a = 6 mm) is solved at four resolutions: b = 3, 4, 5, 6 voxels.
//
// Printed for stiffness E x fill, E x fill^2 and E x fill^3 (today): the peak over
// voxels against 5.00. The bar: never more than 5 % UNDER the reference at any
// resolution (reading high is the safe side). MEASURES by default; --gate fails
// when E x fill^2 misses the bar.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

constexpr double kFarStress = 10.0;  // MPa
constexpr double kTiltDeg = 30.0;
constexpr double kReference = 5.0;   // Inglis, a / b = 2
constexpr int kThickness = 2;        // voxels
constexpr int kSub = 8;
constexpr double kShortAxisMm = 3.0;  // b; a = 2 b = 6 mm

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

// The peak von Mises over voxels / the far stress, for the ellipse with short
// semi-axis `b_voxels` and stiffness E x fill^penalty in the voxels the hole cuts.
double peak_ratio(int b_voxels, double penalty, bool* ok) {
  const int a_voxels = 2 * b_voxels;
  const int w = 10 * a_voxels;  // the hole's long axis is a fifth of the plate's width... (2 a / W = 0.2)
  VoxelGrid g;
  g.nx = w;
  g.ny = w;
  g.nz = kThickness;
  g.spacing = kShortAxisMm / b_voxels;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(w) * w * kThickness, topopt::VoxelTag::Interior);

  const double t = kTiltDeg * std::acos(-1.0) / 180.0;
  const double c = std::cos(t), s = std::sin(t);
  // Hole centre off the grid lines. u runs along the pull, v across it; the long
  // axis (a) lies across the pull.
  const double cx = 0.5 * w + 0.29, cy = 0.5 * w - 0.41;
  auto solid = [&](double x, double y) {
    const double dx = x - cx, dy = y - cy;
    const double u = dx * c + dy * s, v = -dx * s + dy * c;
    return (u * u) / (static_cast<double>(b_voxels) * b_voxels) +
               (v * v) / (static_cast<double>(a_voxels) * a_voxels) > 1.0;
  };
  std::vector<double> density(g.tags.size(), 1.0);
  for (int j = 0; j < w; ++j)
    for (int i = 0; i < w; ++i) {
      int in = 0;
      for (int bb = 0; bb < kSub; ++bb)
        for (int aa = 0; aa < kSub; ++aa)
          if (solid(i + (aa + 0.5) / kSub, j + (bb + 0.5) / kSub)) ++in;
      const double v = static_cast<double>(in) / (kSub * kSub);
      for (int k = 0; k < kThickness; ++k)
        density[(static_cast<std::size_t>(k) * w + j) * w + i] = v;
    }

  const std::vector<NodalLoad> loads =
      edge_tractions(g, kFarStress * c * c, kFarStress * s * s, kFarStress * s * c);

  std::vector<DirichletBC> bcs;
  const int n0 = topopt::fea_node_index(g, 0, 0, 0);
  const int n1 = topopt::fea_node_index(g, w, 0, 0);
  const int n2 = topopt::fea_node_index(g, 0, w, 0);
  bcs.push_back({n0, 0, 0.0});
  bcs.push_back({n0, 1, 0.0});
  bcs.push_back({n0, 2, 0.0});
  bcs.push_back({n1, 1, 0.0});
  bcs.push_back({n1, 2, 0.0});
  bcs.push_back({n2, 2, 0.0});

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
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-8, 20000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  *ok = !res.non_convergent && res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  if (res.non_convergent)
    std::printf("  (b = %d voxels, fill^%.0f: the solve did not converge)\n", b_voxels, penalty);
  return res.max_von_mises / kFarStress;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  const int kB[4] = {3, 4, 5, 6};
  const double kPenalty[3] = {1.0, 2.0, 3.0};
  const char* kName[3] = {"E x fill^1", "E x fill^2", "E x fill^3 (today)"};
  int broken = 0;
  double low[3] = {1e9, 1e9, 1e9}, high[3] = {-1e9, -1e9, -1e9};
  std::printf("[ellipse] elliptical hole a / b = 2, pull tilted %.0f degrees; peak over voxels / far stress; reference %.2f\n",
              kTiltDeg, kReference);
  std::printf("%-20s", "b in voxels");
  for (int b : kB) std::printf(" %8d", b);
  std::printf("   lowest to highest against the reference\n");
  for (int p = 0; p < 3; ++p) {
    std::printf("%-20s", kName[p]);
    for (int b : kB) {
      bool ok = false;
      const double r = peak_ratio(b, kPenalty[p], &ok);
      if (!ok) ++broken;
      const double off = 100.0 * (r / kReference - 1.0);
      low[p] = std::min(low[p], off);
      high[p] = std::max(high[p], off);
      std::printf(" %8.3f", r);
      std::fflush(stdout);
    }
    std::printf("   %+6.1f to %+6.1f %%  %s\n", low[p], high[p],
                low[p] >= -5.0 ? "never more than 5 % low" : "MORE THAN 5 % LOW somewhere");
  }
  const bool pass = low[1] >= -5.0;
  std::printf("[ellipse] E x fill^2 at one voxel on the third shape: %s (%s)\n",
              pass ? "holds the bar" : "MISSES the bar", gate ? "gate" : "measure only");
  if (broken) return 2;
  return gate && !pass ? 1 : 0;
}
