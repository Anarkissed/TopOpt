// stress_measure.cpp -- see stress_measure.hpp.
#include "topopt/stress_measure.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace topopt {

namespace {

struct Tap {
  int di, dj, dk;
  double share;  // share of that neighbour voxel's volume inside the ball
};

// The ball is centred on a voxel centre, so the share of each neighbour voxel
// inside it depends only on the offset: one stencil serves the whole grid.
std::vector<Tap> ball_stencil(double radius_in_voxels) {
  constexpr int kSub = 6;
  const int reach = static_cast<int>(std::ceil(radius_in_voxels + 0.5));
  const double r2 = radius_in_voxels * radius_in_voxels;
  std::vector<Tap> taps;
  for (int dk = -reach; dk <= reach; ++dk)
    for (int dj = -reach; dj <= reach; ++dj)
      for (int di = -reach; di <= reach; ++di) {
        int in = 0;
        for (int c = 0; c < kSub; ++c)
          for (int b = 0; b < kSub; ++b)
            for (int a = 0; a < kSub; ++a) {
              const double x = di - 0.5 + (a + 0.5) / kSub;
              const double y = dj - 0.5 + (b + 0.5) / kSub;
              const double z = dk - 0.5 + (c + 0.5) / kSub;
              if (x * x + y * y + z * z <= r2) ++in;
            }
        if (in > 0)
          taps.push_back({di, dj, dk, static_cast<double>(in) / (kSub * kSub * kSub)});
      }
  return taps;
}

}  // namespace

std::vector<double> stress_over_size(const VoxelGrid& grid,
                                     const std::vector<double>& field,
                                     const std::vector<double>& density, double iso,
                                     double diameter_mm) {
  const std::size_t n = grid.voxel_count();
  if (field.size() != n || density.size() != n)
    throw std::invalid_argument("stress_over_size: field / density size != voxel_count");
  std::vector<double> out(n, 0.0);
  const double radius = 0.5 * diameter_mm / grid.spacing;
  // A ball that does not reach past its own voxel reads that voxel alone.
  const bool self_only = !(diameter_mm > 0.0) || radius <= 0.5;
  const std::vector<Tap> taps = self_only ? std::vector<Tap>{} : ball_stencil(radius);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const std::size_t v = grid.index(i, j, k);
        if (!(density[v] >= iso)) continue;
        if (self_only) {
          out[v] = field[v];
          continue;
        }
        double sum = 0.0, weight = 0.0;
        for (const Tap& t : taps) {
          const int a = i + t.di, b = j + t.dj, c = k + t.dk;
          if (a < 0 || b < 0 || c < 0 || a >= grid.nx || b >= grid.ny || c >= grid.nz)
            continue;
          const std::size_t u = grid.index(a, b, c);
          if (!(density[u] >= iso)) continue;
          const double w = t.share * density[u];
          sum += w * field[u];
          weight += w;
        }
        out[v] = weight > 0.0 ? sum / weight : field[v];
      }
  return out;
}

double peak_stress_over_size(const VoxelGrid& grid, const std::vector<double>& field,
                             const std::vector<double>& density, double iso,
                             double diameter_mm) {
  double peak = 0.0;
  for (double s : stress_over_size(grid, field, density, iso, diameter_mm))
    peak = std::max(peak, s);
  return peak;
}

}  // namespace topopt
