// TO rebuild stage 2: the ACROSS-LAYER reading over a size, against a textbook case.
//
// The plate with a round hole of tests E, with the layers stacked ALONG the pull
// (the build direction is the pull's own axis, tilted 30 degrees to the grid), so
// the across-layer check reads the tension along the pull: 3 times the far stress
// at the hole's edge (Kirsch; 3.03 for this plate). With TOPOPT_STRENGTH=size the
// analysis reads that tension over the job's size, the ball free to sit on the
// part's edge. Here the size is chosen to span a stated number of voxels at each
// of four resolutions and the result is set against the reading's own true value
// (the same average of Kirsch's sigma along the pull, to_reference_reading.hpp).
// The maintainer's word: the same size across the layers as within them.
// MEASURES by default; --gate fails outside the bar (never more than 5 % low,
// within 10 % across resolutions) for spans of kStressSizeSwitchVoxels and more.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "to_reference_reading.hpp"
#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/stress_measure.hpp"

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

constexpr double kFarStress = 10.0;  // MPa
constexpr double kTiltDeg = 30.0;
constexpr int kThickness = 2;        // voxels
constexpr int kSub = 8;
constexpr double kHoleRadiusMm = 6.0;

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

// The across-layer tension the analysis reports / the far stress, read over
// `size_mm` (0 = one voxel, today's form).
double across_ratio(int radius_voxels, double size_mm, bool* ok) {
  const int w = 20 * radius_voxels;
  VoxelGrid g;
  g.nx = w;
  g.ny = w;
  g.nz = kThickness;
  g.spacing = kHoleRadiusMm / radius_voxels;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(w) * w * kThickness, topopt::VoxelTag::Interior);
  const double cx = 0.5 * w + 0.29, cy = 0.5 * w - 0.41, r = radius_voxels;
  std::vector<double> density(g.tags.size(), 1.0);
  for (int j = 0; j < w; ++j)
    for (int i = 0; i < w; ++i) {
      int in = 0;
      for (int b = 0; b < kSub; ++b)
        for (int a = 0; a < kSub; ++a)
          if (std::hypot(i + (a + 0.5) / kSub - cx, j + (b + 0.5) / kSub - cy) > r) ++in;
      const double v = static_cast<double>(in) / (kSub * kSub);
      for (int k = 0; k < kThickness; ++k)
        density[(static_cast<std::size_t>(k) * w + j) * w + i] = v;
    }
  const double t = kTiltDeg * std::acos(-1.0) / 180.0;
  const double c = std::cos(t), s = std::sin(t);
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
  params.penalty = 3.0;  // today's; the size form sets real stiffness itself

  topopt::KnockdownSpec knockdown;
  knockdown.stress_reading_mm = size_mm;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{c, s, 0.0}, 1e-8, 20000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  *ok = !res.non_convergent && res.max_interlayer_tension > 0.0 &&
        std::isfinite(res.max_interlayer_tension) &&
        (size_mm > 0.0) == (res.stress_read_over_mm > 0.0);
  return res.max_interlayer_tension / kFarStress;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  setenv("TOPOPT_STRENGTH", "size", 1);
  const int kRes[4] = {3, 4, 5, 6};
  const double kSpans[5] = {1.75, 2.0, 2.5, 3.0, 4.0};
  int failures = 0;
  std::printf("[across] plate with a hole, layers stacked along the pull; the across-layer tension / far stress\n");
  std::printf("[across] one voxel (today's form) at radius 3 / 4 / 5 / 6 voxels, against 3.03:");
  for (int r : kRes) {
    bool ok = false;
    const double v = across_ratio(r, 0.0, &ok);
    if (!ok) ++failures;
    std::printf(" %+6.1f %%", 100.0 * (v / 3.03 - 1.0));
    std::fflush(stdout);
  }
  std::printf("\n[across] read over a size, by the voxels it spans; percent against the reading's own true value\n");
  for (double span : kSpans) {
    double lo = 1e9, hi = -1e9, off[4];
    for (int ri = 0; ri < 4; ++ri) {
      const int r = kRes[ri];
      const double voxel = kHoleRadiusMm / r, mm = span * voxel;
      bool ok = false;
      const double v = across_ratio(r, mm, &ok);
      if (!ok) ++failures;
      const double truth = to_reference::plate_reading_along_pull(kHoleRadiusMm, mm, kThickness * voxel);
      off[ri] = 100.0 * (v / truth - 1.0);
      lo = std::min(lo, off[ri]);
      hi = std::max(hi, off[ri]);
    }
    const bool in = lo >= -5.0 && hi - lo <= 10.0;
    if (gate && !in) ++failures;
    std::printf("[across] %4.2f voxels across: %+6.1f %+6.1f %+6.1f %+6.1f   lowest %+6.1f, spread %5.1f  %s\n",
                span, off[0], off[1], off[2], off[3], lo, hi - lo, in ? "inside the bar" : "outside");
    std::fflush(stdout);
  }
  unsetenv("TOPOPT_STRENGTH");
  std::printf("[across] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
