// semdot.cpp — the smooth-edged material distribution map. See
// topopt/semdot.hpp for the method, the single discretization parameter, and the
// tie rule that meets the volume without a first-iteration special case.

#include "topopt/semdot.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace topopt {
namespace {

// Histogram resolution for the level-set search. The histogram only BRACKETS the
// level-set value; the bin that contains it is then collected and sorted exactly,
// so this number affects how much work the exact pass does and nothing else —
// not the answer, not the volume, not determinism.
constexpr int kLevelBins = 4096;

inline int bin_of(double v) {
  int b = static_cast<int>(v * static_cast<double>(kLevelBins));
  if (b < 0) b = 0;
  if (b >= kLevelBins) b = kLevelBins - 1;
  return b;
}

// The eight nodal values of voxel (i,j,k), in the trilinear corner order
// (a + 2b + 4c) for a,b,c in {0,1} along x,y,z.
struct Corners {
  double v[8];
};

inline Corners corners_of(const std::vector<double>& nodal, int nx, int ny,
                          int i, int j, int k) {
  const std::size_t sx = 1;
  const std::size_t sy = static_cast<std::size_t>(nx) + 1;
  const std::size_t sz = sy * (static_cast<std::size_t>(ny) + 1);
  const std::size_t base = static_cast<std::size_t>(k) * sz +
                           static_cast<std::size_t>(j) * sy +
                           static_cast<std::size_t>(i) * sx;
  Corners c;
  for (int a = 0; a < 2; ++a)
    for (int b = 0; b < 2; ++b)
      for (int d = 0; d < 2; ++d)
        c.v[static_cast<std::size_t>(a + 2 * b + 4 * d)] =
            nodal[base + static_cast<std::size_t>(a) * sx +
                  static_cast<std::size_t>(b) * sy +
                  static_cast<std::size_t>(d) * sz];
  return c;
}

// Trilinear interpolation at local coordinates (x,y,z) in [0,1]^3.
inline double trilerp(const Corners& c, double x, double y, double z) {
  const double mx = 1.0 - x, my = 1.0 - y, mz = 1.0 - z;
  return c.v[0] * mx * my * mz + c.v[1] * x * my * mz + c.v[2] * mx * y * mz +
         c.v[3] * x * y * mz + c.v[4] * mx * my * z + c.v[5] * x * my * z +
         c.v[6] * mx * y * z + c.v[7] * x * y * z;
}

// The cell-centred sub-lattice offsets: (a + 0.5)/n for a = 0..n-1. Cell-centred
// rather than node-centred so no sample sits on a voxel face and gets counted by
// two voxels, and so the sample set is symmetric about the voxel centre for every
// n (even and odd alike).
std::vector<double> sample_offsets(int n) {
  std::vector<double> t(static_cast<std::size_t>(n));
  for (int a = 0; a < n; ++a)
    t[static_cast<std::size_t>(a)] =
        (static_cast<double>(a) + 0.5) / static_cast<double>(n);
  return t;
}

}  // namespace

std::vector<double> semdot_nodal_density(const VoxelGrid& grid,
                                         const std::vector<double>& density) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "semdot_nodal_density: density.size() != grid.voxel_count()");
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const std::size_t sy = static_cast<std::size_t>(nx) + 1;
  const std::size_t sz = sy * (static_cast<std::size_t>(ny) + 1);
  std::vector<double> nodal(sz * (static_cast<std::size_t>(nz) + 1), 0.0);
  // Every node averages the voxels INCIDENT TO IT THAT EXIST — the divisor is the
  // in-grid count, not a fixed 8. See the header for why the fixed-8 background
  // rule is wrong here.
  for (int k = 0; k <= nz; ++k)
    for (int j = 0; j <= ny; ++j)
      for (int i = 0; i <= nx; ++i) {
        double s = 0.0;
        int cnt = 0;
        for (int dk = -1; dk <= 0; ++dk)
          for (int dj = -1; dj <= 0; ++dj)
            for (int di = -1; di <= 0; ++di) {
              const int a = i + di, b = j + dj, c = k + dk;
              if (a < 0 || b < 0 || c < 0 || a >= nx || b >= ny || c >= nz)
                continue;
              s += density[grid.index(a, b, c)];
              ++cnt;
            }
        nodal[static_cast<std::size_t>(k) * sz +
              static_cast<std::size_t>(j) * sy + static_cast<std::size_t>(i)] =
            cnt > 0 ? s / static_cast<double>(cnt) : 0.0;
      }
  return nodal;
}

SemdotField semdot_volume_fractions(const VoxelGrid& grid,
                                    const std::vector<double>& density,
                                    const DesignMask& mask,
                                    double target_volume, int grid_points) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "semdot_volume_fractions: density.size() != grid.voxel_count()");
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument(
        "semdot_volume_fractions: mask.size() != grid.voxel_count()");
  if (grid_points < 1)
    throw std::invalid_argument(
        "semdot_volume_fractions: grid_points must be >= 1");
  if (!(target_volume >= 0.0) || !std::isfinite(target_volume))
    throw std::invalid_argument(
        "semdot_volume_fractions: target_volume must be finite and >= 0");

  SemdotField out;
  out.volume_fraction = density;  // non-Active entries carry through untouched

  const int n = grid_points;
  const std::size_t per_voxel =
      static_cast<std::size_t>(n) * static_cast<std::size_t>(n) *
      static_cast<std::size_t>(n);
  const std::vector<double> t = sample_offsets(n);

  // The design set, in traversal order, so every pass below visits exactly the
  // same voxels in exactly the same order.
  std::vector<std::size_t> design;
  design.reserve(grid.voxel_count() / 4 + 1);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t e = grid.index(i, j, k);
        if (mask[e] == MaskValue::Active) design.push_back(e);
      }
  out.design_voxels = design.size();
  if (design.empty()) return out;
  if (target_volume > static_cast<double>(design.size()) + 1e-9)
    throw std::invalid_argument(
        "semdot_volume_fractions: target_volume exceeds the Active voxel count");

  const std::vector<double> nodal = semdot_nodal_density(grid, density);

  // Iterating a design voxel's grid-point samples. One place, so the histogram
  // pass, the exact pass and the fraction pass cannot drift apart.
  auto for_each_sample = [&](std::size_t e, auto&& fn) {
    const int i = static_cast<int>(e % static_cast<std::size_t>(grid.nx));
    const int j = static_cast<int>((e / static_cast<std::size_t>(grid.nx)) %
                                   static_cast<std::size_t>(grid.ny));
    const int k = static_cast<int>(e / (static_cast<std::size_t>(grid.nx) *
                                        static_cast<std::size_t>(grid.ny)));
    const Corners c = corners_of(nodal, grid.nx, grid.ny, i, j, k);
    for (int c3 = 0; c3 < n; ++c3)
      for (int c2 = 0; c2 < n; ++c2)
        for (int c1 = 0; c1 < n; ++c1)
          fn(trilerp(c, t[static_cast<std::size_t>(c1)],
                     t[static_cast<std::size_t>(c2)],
                     t[static_cast<std::size_t>(c3)]));
  };

  // PASS 1 — bracket the level-set value with a histogram of every sample.
  std::vector<std::uint64_t> hist(static_cast<std::size_t>(kLevelBins), 0);
  for (std::size_t e : design)
    for_each_sample(e, [&](double v) { ++hist[static_cast<std::size_t>(bin_of(v))]; });

  // K = the number of grid points that must end up inside for the volume target.
  const double kd = target_volume * static_cast<double>(per_voxel);
  const std::uint64_t total =
      static_cast<std::uint64_t>(design.size()) * per_voxel;
  std::uint64_t K = static_cast<std::uint64_t>(std::llround(kd));
  if (K > total) K = total;

  // Walk bins from the top until the cumulative count reaches K. `above` is the
  // number of samples in strictly higher bins than the one that contains phi.
  int level_bin = 0;
  std::uint64_t above = 0;
  if (K == 0) {
    // Nothing may be inside: put the level above every sample.
    out.level_set = 1.0 + 1.0 / static_cast<double>(kLevelBins);
    out.tie_fraction = 0.0;
    for (std::size_t e : design) out.volume_fraction[e] = 0.0;
    out.achieved_volume = 0.0;
    return out;
  }
  {
    std::uint64_t cum = 0;
    level_bin = 0;
    for (int b = kLevelBins - 1; b >= 0; --b) {
      if (cum + hist[static_cast<std::size_t>(b)] >= K) {
        level_bin = b;
        above = cum;
        break;
      }
      cum += hist[static_cast<std::size_t>(b)];
    }
  }

  // PASS 2 — collect that one bin exactly and select the (K - above)-th largest
  // value in it. That value IS the level set.
  std::vector<double> in_bin;
  in_bin.reserve(static_cast<std::size_t>(hist[static_cast<std::size_t>(level_bin)]));
  for (std::size_t e : design)
    for_each_sample(e, [&](double v) {
      if (bin_of(v) == level_bin) in_bin.push_back(v);
    });
  const std::size_t rank = static_cast<std::size_t>(K - above) - 1;  // 0-based
  // Descending selection: the rank-th largest.
  std::nth_element(in_bin.begin(), in_bin.begin() + static_cast<long>(rank),
                   in_bin.end(), std::greater<double>());
  const double phi = in_bin[rank];
  out.level_set = phi;

  // PASS 3 — the per-voxel counts, and the global tie fraction that makes the
  // volume come out right (header, "TIES").
  //
  // ★ THE TIE TEST IS NOT `v == phi`, AND THE REASON IS MEASURED. A sample is a
  // mean of up to eight voxel densities blended trilinearly, so two samples that
  // are mathematically the same number can differ by a few ulps — on a UNIFORM
  // field they all should be equal and, at cnt = 3/5/6/7 incident voxels, they are
  // not. With an exact test the ulp noise sorts into a spurious "above" group, f
  // clamps, and a uniform field comes back as a BINARY pattern chosen by rounding
  // error. That is the field iteration 1 of the first rung starts from;
  // test_semdot caught it there.
  //
  // The band is a floating-point epsilon, not a control parameter: it is fixed at
  // the arithmetic's own noise floor (8 ulps — one per term of the widest mean)
  // and it cannot be tuned to steer the optimizer, because 1e-15 is 12 orders
  // below the 1/n^3 quantum the volume fractions are resolved to anyway.
  const double tie_band = 8.0 * std::numeric_limits<double>::epsilon() *
                          std::fmax(1.0, std::fabs(phi));
  std::vector<std::uint32_t> n_gt(design.size(), 0);
  std::vector<std::uint32_t> n_eq(design.size(), 0);
  std::uint64_t N_gt = 0, N_eq = 0;
  for (std::size_t d = 0; d < design.size(); ++d) {
    std::uint32_t gt = 0, eq = 0;
    for_each_sample(design[d], [&](double v) {
      if (v > phi + tie_band) ++gt;
      else if (v >= phi - tie_band) ++eq;
    });
    n_gt[d] = gt;
    n_eq[d] = eq;
    N_gt += gt;
    N_eq += eq;
  }
  out.tied_samples = static_cast<std::size_t>(N_eq);
  // f is in (0, 1] by construction and never needs the clamps below to be
  // correct — they are a floor against a pathological input, not the rule.
  // phi is the K-th largest sample, so #{v > phi} <= K-1 and #{v >= phi} >= K;
  // widening by the tie band only moves samples from `gt` into `eq`, so
  // N_gt <= K-1 and N_gt + N_eq >= K.
  double f = N_eq > 0 ? (static_cast<double>(K) - static_cast<double>(N_gt)) /
                            static_cast<double>(N_eq)
                      : 0.0;
  if (!(f >= 0.0)) f = 0.0;
  if (f > 1.0) f = 1.0;
  out.tie_fraction = f;

  const double inv = 1.0 / static_cast<double>(per_voxel);
  double vol = 0.0;
  for (std::size_t d = 0; d < design.size(); ++d) {
    const double V =
        (static_cast<double>(n_gt[d]) + f * static_cast<double>(n_eq[d])) * inv;
    out.volume_fraction[design[d]] = V;
    vol += V;
    if (V > 0.0 && V < 1.0) ++out.fractional_voxels;
  }
  out.achieved_volume = vol;
  return out;
}

}  // namespace topopt
