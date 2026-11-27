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

namespace {
constexpr double kFullVoxel = 0.999;  // a voxel the surface does not cut
}  // namespace

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
        int with = 0, cut = 0;
        for (int c = -1; c <= 0; ++c)
          for (int b = -1; b <= 0; ++b)
            for (int a = -1; a <= 0; ++a)
              if (holds(i + a, j + b, k + c)) {
                ++with;
                if (density[grid.index(i + a, j + b, k + c)] < kFullVoxel) ++cut;
              }
        if (with == 0 || with == 8) continue;  // inside the air, or inside the material
        // Only where the surface lies ON voxel boundaries (every voxel at the node is
        // full). Where the surface cuts voxels, a voxel-centred ball already sits on
        // the edge (on the cut voxels), and a node there would average mostly
        // slivers, whose stress the solve reads high: measured 2026-11-27, the plate
        // and the ring read 10 to 68 % high with such nodes counted.
        if (cut > 0) continue;
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

SurfaceCarry stress_carried_to_surface(const VoxelGrid& grid, const std::vector<double>& field,
                                       const std::vector<double>& density) {
  const std::size_t n = grid.voxel_count();
  if (field.size() != n || density.size() != n)
    throw std::invalid_argument("stress_carried_to_surface: field / density size != voxel_count");
  auto inside = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < grid.nx && j < grid.ny && k < grid.nz;
  };
  // The fill the normal is taken from: 0 outside the grid and on Empty voxels.
  auto fill = [&](int i, int j, int k) {
    if (!inside(i, j, k)) return 0.0;
    const std::size_t v = grid.index(i, j, k);
    if (grid.tags[v] == VoxelTag::Empty) return 0.0;
    return density[v];
  };
  auto air = [&](int i, int j, int k) {
    if (!inside(i, j, k)) return true;
    const std::size_t v = grid.index(i, j, k);
    return grid.tags[v] == VoxelTag::Empty || !(density[v] >= kStressMaterialFloor);
  };
  auto full = [&](int i, int j, int k) {
    return !air(i, j, k) && density[grid.index(i, j, k)] >= kFullVoxel;
  };
  SurfaceCarry out;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (air(i, j, k)) continue;
        const std::size_t v = grid.index(i, j, k);
        const bool is_full = density[v] >= kFullVoxel;
        if (is_full) {
          out.peak = std::max(out.peak, field[v]);
          if (!air(i - 1, j, k) && !air(i + 1, j, k) && !air(i, j - 1, k) &&
              !air(i, j + 1, k) && !air(i, j, k - 1) && !air(i, j, k + 1))
            continue;  // inside the material: not a surface voxel
        }
        // One surface voxel can lie on MORE THAN ONE face of the part (the edge where a
        // hole's wall meets a flat top face). Each face is carried on its own normal:
        //  - a FLAT face lying on a voxel boundary along an axis: the neighbour on one
        //    side is air and the fill does not change towards the other side (a full
        //    voxel, or a cut voxel whose neighbour behind is cut the same);
        //  - the CUT face through the voxel: -grad(fill) with the flat axes left out
        //    (a diagonal normal across an edge would put the surface in the wrong place).
        const int ijk[3] = {i, j, k};
        bool flat[3] = {false, false, false};
        int flat_sign[3] = {0, 0, 0};  // the side the air is on
        for (int ax = 0; ax < 3; ++ax) {
          int lo[3] = {i, j, k}, hi[3] = {i, j, k};
          --lo[ax];
          ++hi[ax];
          const bool air_lo = air(lo[0], lo[1], lo[2]), air_hi = air(hi[0], hi[1], hi[2]);
          if (air_lo == air_hi) {
            // air on both sides: a sheet one voxel thick along this axis, flat both ways
            if (air_lo) flat[ax] = true;
            continue;
          }
          const double behind = air_lo ? fill(hi[0], hi[1], hi[2]) : fill(lo[0], lo[1], lo[2]);
          if (is_full || std::fabs(behind - density[v]) < 0.25) {
            flat[ax] = true;
            flat_sign[ax] = air_hi ? 1 : -1;
          }
        }
        (void)ijk;
        // carry along a unit normal nv with the surface t_surf voxels out from the centre
        auto carry = [&](const double nv[3], double t_surf) {
          const double c[3] = {i + 0.5, j + 0.5, k + 0.5};
          bool have_a = false, have_b = false;
          std::size_t va = 0, vb = 0;
          double s_a = 0.0, s_b = 0.0;
          for (int step = 0; step <= 25 && !have_b; ++step) {
            const double s = -0.2 * step;
            const int a = static_cast<int>(std::floor(c[0] + s * nv[0]));
            const int b = static_cast<int>(std::floor(c[1] + s * nv[1]));
            const int d = static_cast<int>(std::floor(c[2] + s * nv[2]));
            if (!full(a, b, d)) continue;
            const std::size_t u = grid.index(a, b, d);
            const double su = (a + 0.5 - c[0]) * nv[0] + (b + 0.5 - c[1]) * nv[1] +
                              (d + 0.5 - c[2]) * nv[2];
            if (!have_a) {
              have_a = true;
              va = u;
              s_a = su;
            } else if (u != va && su < s_a - 0.5) {
              // b at least half a voxel further in than a, measured along the normal: two
              // voxels side by side across the ray would divide by almost nothing.
              have_b = true;
              vb = u;
              s_b = su;
            }
          }
          if (have_b) {
            double carried = field[va] + (field[va] - field[vb]) * (t_surf - s_a) / (s_a - s_b);
            if (carried < 0.0) carried = 0.0;
            ++out.surface_points;
            out.peak = std::max(out.peak, carried);
          } else {
            const double fallback = have_a ? field[va] : field[v];
            ++out.unresolved;
            out.peak_unresolved = std::max(out.peak_unresolved, fallback);
            out.peak = std::max(out.peak, fallback);
          }
        };
        // The flat faces of a FULL voxel (a cut voxel's flat faces have no full voxel
        // straight behind them; its cut face carries it).
        if (is_full)
          for (int ax = 0; ax < 3; ++ax)
            if (flat[ax] && flat_sign[ax] != 0) {
              double nv[3] = {0.0, 0.0, 0.0};
              nv[ax] = flat_sign[ax];
              carry(nv, 0.5);
            }
        if (is_full) continue;
        // The cut face: n = -grad(fill), Sobel-weighted over the 3 x 3 x 3 neighbourhood,
        // the flat axes left out.
        double g[3] = {0.0, 0.0, 0.0};
        for (int p = -1; p <= 1; ++p)
          for (int q = -1; q <= 1; ++q) {
            const double wgt = (p == 0 ? 2.0 : 1.0) * (q == 0 ? 2.0 : 1.0);
            g[0] += wgt * (fill(i + 1, j + p, k + q) - fill(i - 1, j + p, k + q));
            g[1] += wgt * (fill(i + p, j + 1, k + q) - fill(i + p, j - 1, k + q));
            g[2] += wgt * (fill(i + p, j + q, k + 1) - fill(i + p, j + q, k - 1));
          }
        for (int ax = 0; ax < 3; ++ax)
          if (flat[ax]) g[ax] = 0.0;
        const double norm = std::sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
        if (norm < 1e-9) {
          ++out.unresolved;
          out.peak_unresolved = std::max(out.peak_unresolved, field[v]);
          out.peak = std::max(out.peak, field[v]);
          continue;
        }
        const double nv[3] = {-g[0] / norm, -g[1] / norm, -g[2] / norm};
        const double l1 = std::fabs(nv[0]) + std::fabs(nv[1]) + std::fabs(nv[2]);
        // The true surface along n from the centre, in voxels (material on the - side).
        carry(nv, (density[v] - 0.5) * l1);
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
