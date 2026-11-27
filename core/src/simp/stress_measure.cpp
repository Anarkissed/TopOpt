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

std::vector<double> stress_over_size_on_surface(const VoxelGrid& grid,
                                                const std::vector<double>& field,
                                                const std::vector<double>& density,
                                                double material_floor, double diameter_mm) {
  const std::size_t n = grid.voxel_count();
  if (field.size() != n || density.size() != n)
    throw std::invalid_argument("stress_over_size_on_surface: field / density size != voxel_count");
  std::vector<double> out(n, 0.0);
  const double radius = 0.5 * diameter_mm / grid.spacing;  // in voxels
  if (!(diameter_mm > 0.0) || radius <= 0.5) return out;
  // The share of each voxel inside a ball centred on a NODE: voxel (di, dj, dk)
  // spans [di, di + 1) from the node, so one stencil serves every node.
  constexpr int kSub = 6;
  const int reach = static_cast<int>(std::ceil(radius)) + 1;
  const double r2 = radius * radius;
  std::vector<Tap> taps;
  for (int dk = -reach; dk < reach; ++dk)
    for (int dj = -reach; dj < reach; ++dj)
      for (int di = -reach; di < reach; ++di) {
        int in = 0;
        for (int c = 0; c < kSub; ++c)
          for (int b = 0; b < kSub; ++b)
            for (int a = 0; a < kSub; ++a) {
              const double x = di + (a + 0.5) / kSub, y = dj + (b + 0.5) / kSub,
                           z = dk + (c + 0.5) / kSub;
              if (x * x + y * y + z * z <= r2) ++in;
            }
        if (in > 0)
          taps.push_back({di, dj, dk, static_cast<double>(in) / (kSub * kSub * kSub)});
      }
  auto holds = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < grid.nx && j < grid.ny && k < grid.nz &&
           density[grid.index(i, j, k)] >= material_floor;
  };
  // Node (i, j, k), 0 <= i <= nx and so on, touches the eight voxels (i - 1 or i, ...).
  for (int k = 0; k <= grid.nz; ++k)
    for (int j = 0; j <= grid.ny; ++j)
      for (int i = 0; i <= grid.nx; ++i) {
        int with = 0;
        for (int c = -1; c <= 0; ++c)
          for (int b = -1; b <= 0; ++b)
            for (int a = -1; a <= 0; ++a) with += holds(i + a, j + b, k + c) ? 1 : 0;
        if (with == 0 || with == 8) continue;  // inside the air, or inside the material
        double sum = 0.0, weight = 0.0;
        for (const Tap& t : taps) {
          const int a = i + t.di, b = j + t.dj, c = k + t.dk;
          if (!holds(a, b, c)) continue;
          const std::size_t u = grid.index(a, b, c);
          const double w = t.share * density[u];
          sum += w * field[u];
          weight += w;
        }
        if (!(weight > 0.0)) continue;
        const double reading = sum / weight;
        for (int c = -1; c <= 0; ++c)
          for (int b = -1; b <= 0; ++b)
            for (int a = -1; a <= 0; ++a)
              if (holds(i + a, j + b, k + c)) {
                double& o = out[grid.index(i + a, j + b, k + c)];
                if (reading > o) o = reading;
              }
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

std::vector<double> interlayer_tension_field(
    const VoxelGrid& grid, const std::vector<std::array<double, 6>>& stress,
    const Vec3& build_dir) {
  const double len = std::sqrt(build_dir.x * build_dir.x + build_dir.y * build_dir.y +
                               build_dir.z * build_dir.z);
  if (len < 1e-12)
    throw std::invalid_argument("interlayer_tension_field: build_dir is zero length");
  if (stress.size() != grid.voxel_count())
    throw std::invalid_argument("interlayer_tension_field: stress size != voxel_count");
  const Vec3 n{build_dir.x / len, build_dir.y / len, build_dir.z / len};
  std::vector<double> out(grid.voxel_count(), 0.0);
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t idx = grid.index(i, j, k);
        const std::array<double, 6>& s = stress[idx];
        const double t = n.x * n.x * s[0] + n.y * n.y * s[1] + n.z * n.z * s[2] +
                         2.0 * n.x * n.y * s[3] + 2.0 * n.y * n.z * s[4] +
                         2.0 * n.z * n.x * s[5];
        if (t > 0.0) out[idx] = t;
      }
  return out;
}

}  // namespace topopt
