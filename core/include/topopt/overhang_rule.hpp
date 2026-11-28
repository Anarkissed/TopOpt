#pragma once

// TO rebuild, stage 4b: the OVERHANG rule as a measure and as Langelaar's layer
// filter, for a build direction along +z or -z of the grid. Header-only.
//
// THE RULE IS TODAY'S (core/src/orient/orient.cpp support_overhang_voxels, with
// kOverhangAngleDeg = 45 in orient.hpp, applied to the printed design the way
// core/src/simp/analyze.cpp does before calling it):
//   * printed = tag != Empty AND density > threshold (strictly).
//   * a printed voxel is SUPPORTED if one of the neighbours below it within 45
//     degrees of straight down is printed. On the voxel grid that is FIVE voxels:
//     the one directly below and its four FACE neighbours in the layer below
//     (offsets (+-1,0,-1), (0,+-1,-1) sit exactly at 45 degrees and count; the
//     four corner offsets (+-1,+-1,-1) sit at 54.7 degrees and do not).
//   * the build plate is the part's OWN lowest printed layer (in the build
//     direction), not the grid's lowest layer: every voxel in that layer is
//     supported. Off-grid neighbours are not support.
//
// overhang_filter is Langelaar's AM filter (Struct Multidisc Optim 55:871, 2017;
// Additive Manufacturing 12:60, 2016) in its simple voxel form over the same five
// supports: going up from the plate, out(v) = min(rho(v), smax(out over the five
// supports of v)), smax the P-norm maximum (P = 40). Only the forward field here:
// the ADJOINT (sensitivities through the layers, top layer first) is the next step,
// and with it the hard min likely becomes Langelaar's smooth min.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

struct OverhangMeasure {
  bool direction_supported = true;   // false: build direction not along +-z (nothing measured)
  std::size_t unsupported_voxels = 0;
  double unsupported_area_mm2 = 0.0;  // unsupported voxels x spacing^2
  double largest_patch_mm2 = 0.0;     // largest in-layer FACE-connected patch of them
};

namespace overhang_detail {

constexpr double kSmaxP = 40.0;
constexpr int kSupport[5][2] = {{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}};

inline bool printed(const VoxelGrid& g, const std::vector<double>& d, std::size_t idx,
                    double thr) {
  return g.tags[idx] != VoxelTag::Empty && d[idx] > thr;
}

// The plate layer: the part's lowest printed layer along the build direction; -1 if none.
inline int plate_layer(const VoxelGrid& g, const std::vector<double>& d, bool up, double thr) {
  const std::size_t layer = static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny);
  for (int s = 0; s < g.nz; ++s) {
    const int k = up ? s : g.nz - 1 - s;
    const std::size_t base = static_cast<std::size_t>(k) * layer;
    for (std::size_t q = 0; q < layer; ++q)
      if (printed(g, d, base + q, thr)) return k;
  }
  return -1;
}

inline void check_size(const VoxelGrid& g, const std::vector<double>& d, const char* who) {
  if (d.size() != g.voxel_count())
    throw std::invalid_argument(std::string(who) + ": density size != grid.voxel_count()");
}

// +1 for +z, -1 for -z, 0 for anything else (not supported).
inline int axis_of(const Vec3& dir) {
  const double len = std::sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
  if (!(len > 1e-12)) throw std::invalid_argument("overhang: build direction is zero length");
  if (std::fabs(dir.x) / len > 1e-9 || std::fabs(dir.y) / len > 1e-9) return 0;
  return dir.z > 0 ? 1 : -1;
}

}  // namespace overhang_detail

inline OverhangMeasure overhang_measure(const VoxelGrid& grid, const std::vector<double>& density,
                                        bool build_up, double threshold = 0.5) {
  using namespace overhang_detail;
  check_size(grid, density, "overhang_measure");
  OverhangMeasure out;
  const int plate = plate_layer(grid, density, build_up, threshold);
  if (plate < 0) return out;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz, below = build_up ? -1 : 1;
  // Byte per voxel: 1 = unsupported, 2 = already in a patch.
  std::vector<std::uint8_t> m(grid.voxel_count(), 0);
  for (int k = 0; k < nz; ++k) {
    if (k == plate) continue;
    const int kb = k + below;
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t idx = grid.index(i, j, k);
        if (!printed(grid, density, idx, threshold)) continue;
        bool held = false;
        if (kb >= 0 && kb < nz)
          for (const auto& o : kSupport) {
            const int ni = i + o[0], nj = j + o[1];
            if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
            if (printed(grid, density, grid.index(ni, nj, kb), threshold)) {
              held = true;
              break;
            }
          }
        if (!held) {
          m[idx] = 1;
          ++out.unsupported_voxels;
        }
      }
  }
  const double a = grid.spacing * grid.spacing;
  out.unsupported_area_mm2 = static_cast<double>(out.unsupported_voxels) * a;
  // Largest in-layer patch, face-connected (4 neighbours in the layer).
  std::vector<std::size_t> stack;
  std::size_t best = 0;
  for (std::size_t seed = 0; seed < m.size(); ++seed) {
    if (m[seed] != 1) continue;
    m[seed] = 3;
    stack.assign(1, seed);
    std::size_t n = 0;
    while (!stack.empty()) {
      const std::size_t idx = stack.back();
      stack.pop_back();
      ++n;
      const int i = static_cast<int>(idx % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((idx / static_cast<std::size_t>(nx)) % static_cast<std::size_t>(ny));
      const int k = static_cast<int>(idx / (static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny)));
      for (int q = 1; q < 5; ++q) {
        const int ni = i + kSupport[q][0], nj = j + kSupport[q][1];
        if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
        const std::size_t nb = grid.index(ni, nj, k);
        if (m[nb] != 1) continue;
        m[nb] = 3;
        stack.push_back(nb);
      }
    }
    best = std::max(best, n);
  }
  out.largest_patch_mm2 = static_cast<double>(best) * a;
  return out;
}

// Any direction: only +-z is measured; any other gives direction_supported = false.
inline OverhangMeasure overhang_measure(const VoxelGrid& grid, const std::vector<double>& density,
                                        const Vec3& build_dir, double threshold = 0.5) {
  const int ax = overhang_detail::axis_of(build_dir);
  if (ax == 0) {
    OverhangMeasure out;
    out.direction_supported = false;
    return out;
  }
  return overhang_measure(grid, density, ax > 0, threshold);
}

// Langelaar's layer filter (forward only). Layers up to and including the plate
// layer pass unchanged; Empty voxels pass unchanged and support nothing.
inline std::vector<double> overhang_filter(const VoxelGrid& grid, const std::vector<double>& density,
                                           bool build_up, double threshold = 0.5) {
  using namespace overhang_detail;
  check_size(grid, density, "overhang_filter");
  std::vector<double> out = density;
  const int plate = plate_layer(grid, density, build_up, threshold);
  if (plate < 0) return out;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz, step = build_up ? 1 : -1;
  for (int k = plate + step; k >= 0 && k < nz; k += step) {
    const int kb = k - step;
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t idx = grid.index(i, j, k);
        if (grid.tags[idx] == VoxelTag::Empty) continue;
        double sum = 0.0;
        for (const auto& o : kSupport) {
          const int ni = i + o[0], nj = j + o[1];
          if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
          const std::size_t nb = grid.index(ni, nj, kb);
          if (grid.tags[nb] == VoxelTag::Empty) continue;
          const double x = std::max(0.0, out[nb]);
          if (x > 0.0) sum += std::pow(x, kSmaxP);
        }
        const double smax = sum > 0.0 ? std::pow(sum, 1.0 / kSmaxP) : 0.0;
        out[idx] = std::min(density[idx], smax);
      }
  }
  return out;
}

// Any direction: only +-z is filtered; any other returns an EMPTY vector (not supported).
inline std::vector<double> overhang_filter(const VoxelGrid& grid, const std::vector<double>& density,
                                           const Vec3& build_dir, double threshold = 0.5) {
  const int ax = overhang_detail::axis_of(build_dir);
  if (ax == 0) return {};
  return overhang_filter(grid, density, ax > 0, threshold);
}

}  // namespace topopt
