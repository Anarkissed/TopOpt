// TO rebuild, repo test E (docs/design/to-rebuild/04-tests.md), first half.
//
// The strength number against a stress that is known from the textbook: a wide
// flat plate with a round hole, pulled along an axis TILTED 30 degrees to the
// grid. The peak stress at the hole's edge is 3 times the far stress (Kirsch;
// about 3.03 for a plate ten holes wide). The tilt puts the peak on a
// stair-stepped part of the hole, which is where a voxel stress reading is
// weakest. The plate is solved at four resolutions (hole radius 3, 4, 6, 8
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
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

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

double peak_ratio(int radius_voxels, bool exact_fill, double penalty, bool* ok,
                  double* over_size = nullptr) {
  const int w = 20 * radius_voxels;  // plate ten holes wide
  VoxelGrid g;
  g.nx = w;
  g.ny = w;
  g.nz = kThickness;
  g.spacing = kHoleRadiusMm / radius_voxels;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(w) * w * kThickness, topopt::VoxelTag::Interior);

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
      for (int k = 0; k < kThickness; ++k)
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
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-8, 20000,
      topopt::SolverKind::JacobiCG, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  *ok = res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  if (over_size != nullptr && res.von_mises_field.size() == density.size())
    for (int q = 0; q < 3; ++q)
      over_size[q] = topopt::peak_stress_over_size(g, res.von_mises_field, density, 0.5,
                                                   kSizesMm[q]) /
                     kFarStress;
  return res.max_von_mises / kFarStress;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  int failures = 0;
  std::vector<Row> rows;
  std::printf("[test E] plate with a hole, pulled at %.0f deg to the grid; peak / far "
              "stress, textbook %.2f\n",
              kTiltDeg, kTextbook);
  std::printf("%-12s %9s %14s %16s %14s %9s %9s %9s\n", "hole radius", "voxel mm",
              "all-or-nothing", "fill, E x fill^3", "fill, E x fill", "over 0.9", "over 1.8",
              "over 3.6");
  for (int r : {3, 4, 6, 8}) {
    Row row;
    row.radius_voxels = r;
    bool ok1 = false, ok2 = false, ok3 = false;
    row.ratio_binary = peak_ratio(r, false, 3.0, &ok1);
    row.ratio_fill = peak_ratio(r, true, 3.0, &ok2);
    row.ratio_fill_linear = peak_ratio(r, true, 1.0, &ok3, row.over_size);
    if (!ok1 || !ok2 || !ok3) ++failures;
    std::printf("%-12d %9.3f %14.3f %16.3f %14.3f %9.3f %9.3f %9.3f\n", r,
                kHoleRadiusMm / r, row.ratio_binary, row.ratio_fill, row.ratio_fill_linear,
                row.over_size[0], row.over_size[1], row.over_size[2]);
    rows.push_back(row);
  }
  auto band = [&](double Row::*f, const char* name) {
    double lo = 1e300, hi = 0.0, worst = 0.0;
    for (const Row& r : rows) {
      lo = std::min(lo, r.*f);
      hi = std::max(hi, r.*f);
      worst = std::max(worst, std::fabs(r.*f / kTextbook - 1.0));
    }
    const double spread = lo > 0.0 ? hi / lo - 1.0 : 1e300;
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
  std::printf("[test E] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
