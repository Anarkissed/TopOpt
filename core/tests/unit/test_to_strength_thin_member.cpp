// TO rebuild stage 2: THE THIN-MEMBER RULE against a beam in pure bending (the
// reviewer's ruling 2026-11-27, item 2).
//
// A ball wider than the member it sits in reaches across it; in bending it averages
// across the neutral line and reads low. So where the member is thinner than twice
// the reading size, the size form falls back to today's one-voxel reading.
//
// The test: a straight beam bent by end tractions that vary linearly through its
// thickness (pure bending: the exact stress is sigma_xx = s0 * (2 y / T - 1), the
// surface stress s0, nothing else), at thicknesses of 0.5, 1, 2 and 4 times the
// reading size, with TOPOPT_STRENGTH=size.
//   * 0.5 and 1 x the size: the analysis must FALL BACK (no voxel read over the
//     size; the number is today's one-voxel reading).
//   * 2 and 4 x the size: read over the size, judged against the reading's own
//     true value (the same ball average of the exact field, the ball centred on
//     the beam's surface): never more than 5 % low.
// Also printed: what the size reading WOULD have given on the thin beams (the low
// reading the rule exists to stop). MEASURES by default; --gate fails on a miss.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

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

constexpr double kSurfaceStress = 10.0;  // MPa, s0
constexpr double kVoxel = 0.5;           // mm
constexpr double kSizeMm = 2.0;          // the reading size: 4 voxels across
constexpr int kLength = 64, kWidth = 16; // voxels along x and z (the width is never the thin side)

struct Result {
  double reading = 0.0;        // max von Mises the analysis reports / s0
  double read_over_mm = 0.0;   // 0 = fell back to one voxel
  std::size_t thick = 0, thin = 0;
  double over_size_anyway = 0.0;  // the size reading with no thin-member rule / s0
  double on_surface = 0.0;        // the same average with the ball centred ON the top face's nodes / s0
  bool ok = false;
};

double node_ball_peak(const VoxelGrid& g, const std::vector<double>& field, double diameter_mm);

Result bend(int thickness_voxels) {
  VoxelGrid g;
  g.nx = kLength;
  g.ny = thickness_voxels;
  g.nz = kWidth;
  g.spacing = kVoxel;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, topopt::VoxelTag::Interior);
  const std::vector<double> density(g.tags.size(), 1.0);
  // End tractions sigma_xx(y) on x = 0 (normal -x) and x = L (+x): each element
  // face carries traction x area, a quarter to each of its four nodes.
  const double q = 0.25 * kVoxel * kVoxel;
  std::vector<NodalLoad> loads;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j) {
      const double s = kSurfaceStress * (2.0 * (j + 0.5) / g.ny - 1.0);
      for (int dk = 0; dk < 2; ++dk)
        for (int dj = 0; dj < 2; ++dj) {
          loads.push_back({topopt::fea_node_index(g, g.nx, j + dj, k + dk), 0, q * s});
          loads.push_back({topopt::fea_node_index(g, 0, j + dj, k + dk), 0, -q * s});
        }
    }
  // The load balances itself; hold the six rigid motions at three corners.
  std::vector<DirichletBC> bcs;
  const int a = topopt::fea_node_index(g, 0, 0, 0);
  const int b = topopt::fea_node_index(g, g.nx, 0, 0);
  const int c = topopt::fea_node_index(g, 0, 0, g.nz);
  bcs.push_back({a, 0, 0.0});
  bcs.push_back({a, 1, 0.0});
  bcs.push_back({a, 2, 0.0});
  bcs.push_back({b, 1, 0.0});
  bcs.push_back({b, 2, 0.0});
  bcs.push_back({c, 1, 0.0});

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
  params.penalty = 3.0;
  topopt::KnockdownSpec knockdown;
  knockdown.stress_reading_mm = kSizeMm;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-9, 40000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  Result r;
  r.ok = !res.non_convergent && res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  r.reading = res.max_von_mises / kSurfaceStress;
  r.read_over_mm = res.stress_read_over_mm;
  r.thick = res.stress_thick_member_voxels;
  r.thin = res.stress_thin_member_voxels;
  if (res.von_mises_material_field.size() == density.size())
    r.over_size_anyway = topopt::peak_stress_over_size(g, res.von_mises_material_field, density,
                                                       topopt::kStressMaterialFloor, kSizeMm) /
                         kSurfaceStress;
  if (res.von_mises_material_field.size() == density.size())
    r.on_surface = node_ball_peak(g, res.von_mises_material_field, kSizeMm) / kSurfaceStress;
  return r;
}

// A MEASURING ARM (finding 1 of 2026-11-27, not in the engine): the same ball
// average of a per-voxel field, but with the ball centred on a NODE (a voxel
// corner) of the beam's top face instead of on a voxel centre, so that on a face
// lying on voxel boundaries the ball sits on the surface as the true value's does.
// Weight = the share of each voxel inside the ball (6 x 6 x 6 sub-points).
double node_ball_peak(const VoxelGrid& g, const std::vector<double>& field, double diameter_mm) {
  const double rad = 0.5 * diameter_mm / g.spacing;  // in voxels
  const int reach = static_cast<int>(std::ceil(rad)) + 1;
  constexpr int kS = 6;
  struct Tap { int di, dj, dk; double share; };
  std::vector<Tap> taps;  // voxel (di, dj, dk) spans [di, di + 1) from the node
  for (int dk = -reach; dk < reach; ++dk)
    for (int dj = -reach; dj < reach; ++dj)
      for (int di = -reach; di < reach; ++di) {
        int in = 0;
        for (int c = 0; c < kS; ++c)
          for (int b = 0; b < kS; ++b)
            for (int a = 0; a < kS; ++a) {
              const double x = di + (a + 0.5) / kS, y = dj + (b + 0.5) / kS, z = dk + (c + 0.5) / kS;
              if (x * x + y * y + z * z <= rad * rad) ++in;
            }
        if (in > 0) taps.push_back({di, dj, dk, static_cast<double>(in) / (kS * kS * kS)});
      }
  double best = 0.0;
  const int j = g.ny;  // the top face's node plane
  for (int k = reach; k <= g.nz - reach; ++k)      // away from the side faces and the ends
    for (int i = g.nx / 4; i <= 3 * g.nx / 4; ++i) {
      double sum = 0.0, weight = 0.0;
      for (const Tap& t : taps) {
        const int a = i + t.di, b = j + t.dj, c = k + t.dk;
        if (a < 0 || b < 0 || c < 0 || a >= g.nx || b >= g.ny || c >= g.nz) continue;
        sum += t.share * field[g.index(a, b, c)];
        weight += t.share;
      }
      if (weight > 0.0) best = std::max(best, sum / weight);
    }
  return best;
}

// The reading's own true value on the exact field: the largest average of
// |2 y / T - 1| over the part of a ball of diameter `size` inside the beam, the
// ball's centre moved from the surface inward (mid-width, so the width never cuts it).
double true_reading(double thickness, double size) {
  const double radius = 0.5 * size;
  const int n = 49;
  double best = 0.0;
  for (int c = 0; c <= 24; ++c) {
    const double cy = thickness - size * c / 24.0;  // from the top surface inward
    double num = 0.0, den = 0.0;
    for (int b = 0; b < n; ++b)
      for (int a = 0; a < n; ++a) {
        const double x = -radius + size * a / (n - 1), y = -radius + size * b / (n - 1);
        const double rho2 = x * x + y * y;
        if (rho2 > radius * radius) continue;
        const double py = cy + y;
        if (py < 0.0 || py > thickness) continue;
        const double w = 2.0 * std::sqrt(std::max(radius * radius - rho2, 0.0));  // chord along z
        num += w * std::fabs(2.0 * py / thickness - 1.0);
        den += w;
      }
    if (den > 0.0) best = std::max(best, num / den);
  }
  return best;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  int failures = 0;
  // LEDGER A-06, measured ahead for stage 4 (the reviewer's ruling 2026-11-27): TODAY'S
  // one-voxel reading (no switch) on the bending beam against the true surface
  // stress, by the number of voxels THROUGH the member. Printed, never judged here.
  unsetenv("TOPOPT_STRENGTH");
  std::printf("[A-06] today's one-voxel reading on a beam in pure bending / the true surface stress, by voxels through the member\n");
  for (int nt : {2, 3, 4, 6, 8, 12, 16}) {
    const Result r = bend(nt);
    if (!r.ok) ++failures;
    std::printf("[A-06] %2d voxels through: %.3f (%+.0f %%); the voxel-centre value of the exact field would be %.3f\n",
                nt, r.reading, 100.0 * (r.reading - 1.0), 1.0 - 1.0 / nt);
    std::fflush(stdout);
  }
  setenv("TOPOPT_STRENGTH", "size", 1);
  std::printf("[thin member] a beam in pure bending, the reading size %.1f mm (%.0f voxels); the surface stress is 1\n",
              kSizeMm, kSizeMm / kVoxel);
  const double kTimes[4] = {0.5, 1.0, 2.0, 4.0};
  for (double times : kTimes) {
    const int nt = static_cast<int>(std::lround(times * kSizeMm / kVoxel));
    const Result r = bend(nt);
    if (!r.ok) ++failures;
    const double truth = true_reading(nt * kVoxel, kSizeMm);
    const bool must_fall_back = times < topopt::kStressThinMemberSizes;
    const bool fell_back = r.read_over_mm == 0.0;
    std::printf("[thin member] thickness %.1f x the size (%2d voxels): %s; reading %.3f; the size reading alone "
                "would give %.3f, its own true value %.3f (%+.1f %%); voxels thick %zu, thin %zu",
                times, nt, fell_back ? "ONE VOXEL (fell back)" : "read over the size", r.reading,
                r.over_size_anyway, truth,
                truth > 0.0 ? 100.0 * (r.over_size_anyway / truth - 1.0) : 0.0, r.thick, r.thin);
    bool row_ok = true;
    if (must_fall_back) {
      // Falls back whole. What the one-voxel reading then gives is PRINTED, not
      // judged here: with 2 or 4 voxels through a bending member the solve itself
      // reads the surface stress far too low (measured 2026-11-27: 0.33 and 0.68 of
      // it), which is the grid's limit, not this rule's.
      row_ok = fell_back;
    } else {
      row_ok = !fell_back && r.reading >= 0.95 * truth;
    }
    std::printf("  %s\n", row_ok ? "as ruled" : "NOT as ruled");
    std::printf("[thin member]   measuring arm, the ball centred ON the top face: %.3f (%+.1f %% against the true value)\n",
                r.on_surface, truth > 0.0 ? 100.0 * (r.on_surface / truth - 1.0) : 0.0);
    if (gate && !row_ok) ++failures;
    std::fflush(stdout);
  }
  unsetenv("TOPOPT_STRENGTH");
  std::printf("[thin member] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
