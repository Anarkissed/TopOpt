// See topopt/voxel_sdf.hpp for why this is exact rather than a chamfer.
#include "topopt/voxel_sdf.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace topopt {
namespace {

constexpr double kInf = std::numeric_limits<double>::max() * 0.25;

// Felzenszwalb & Huttenlocher's 1-D transform: the lower envelope of the parabolas
// rooted at (q, f[q]). `v` and `z` are the envelope's vertex indices and the boundaries
// between them; both are scratch of length n (n + 1 for z).
void edt_1d(std::vector<double>& f, std::vector<int>& v, std::vector<double>& z, int n) {
  int k = 0;
  v[0] = 0;
  z[0] = -kInf;
  z[1] = kInf;
  for (int q = 1; q < n; ++q) {
    double s = ((f[q] + static_cast<double>(q) * q) -
                (f[v[k]] + static_cast<double>(v[k]) * v[k])) /
               (2.0 * q - 2.0 * v[k]);
    while (k > 0 && s <= z[k]) {
      --k;
      s = ((f[q] + static_cast<double>(q) * q) -
           (f[v[k]] + static_cast<double>(v[k]) * v[k])) /
          (2.0 * q - 2.0 * v[k]);
    }
    ++k;
    v[k] = q;
    z[k] = s;
    z[k + 1] = kInf;
  }
  std::vector<double> out(static_cast<std::size_t>(n));
  k = 0;
  for (int q = 0; q < n; ++q) {
    while (z[k + 1] < q) ++k;
    const double d = static_cast<double>(q) - v[k];
    out[static_cast<std::size_t>(q)] = d * d + f[v[k]];
  }
  for (int q = 0; q < n; ++q) f[static_cast<std::size_t>(q)] = out[static_cast<std::size_t>(q)];
}

// Squared distance, in VOXELS, from every voxel to the nearest seed.
std::vector<double> edt_squared(const VoxelGrid& grid, const std::vector<char>& seed) {
  const std::size_t n = grid.voxel_count();
  std::vector<double> f(n, kInf);
  for (std::size_t e = 0; e < n; ++e) if (seed[e]) f[e] = 0.0;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const int m = std::max(nx, std::max(ny, nz));
  std::vector<double> row(static_cast<std::size_t>(m)), z(static_cast<std::size_t>(m) + 1);
  std::vector<int> v(static_cast<std::size_t>(m));
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      for (int i = 0; i < nx; ++i) row[static_cast<std::size_t>(i)] = f[grid.index(i, j, k)];
      edt_1d(row, v, z, nx);
      for (int i = 0; i < nx; ++i) f[grid.index(i, j, k)] = row[static_cast<std::size_t>(i)];
    }
  for (int k = 0; k < nz; ++k)
    for (int i = 0; i < nx; ++i) {
      for (int j = 0; j < ny; ++j) row[static_cast<std::size_t>(j)] = f[grid.index(i, j, k)];
      edt_1d(row, v, z, ny);
      for (int j = 0; j < ny; ++j) f[grid.index(i, j, k)] = row[static_cast<std::size_t>(j)];
    }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < nx; ++i) {
      for (int k = 0; k < nz; ++k) row[static_cast<std::size_t>(k)] = f[grid.index(i, j, k)];
      edt_1d(row, v, z, nz);
      for (int k = 0; k < nz; ++k) f[grid.index(i, j, k)] = row[static_cast<std::size_t>(k)];
    }
  return f;
}

}  // namespace

std::vector<double> voxel_signed_distance_mm(const VoxelGrid& grid,
                                             const std::vector<char>& inside) {
  const std::size_t n = grid.voxel_count();
  std::vector<double> out;
  if (inside.size() != n || n == 0) return out;
  // Outside points measure to the set; inside points measure to its complement. Two
  // transforms, so the field is exact on BOTH sides rather than exact outside and
  // approximated within.
  std::vector<char> comp(n, 0);
  bool any_in = false, any_out = false;
  for (std::size_t e = 0; e < n; ++e) {
    comp[e] = inside[e] ? 0 : 1;
    (inside[e] ? any_in : any_out) = true;
  }
  const double h = grid.spacing;
  out.assign(n, 0.0);
  if (!any_in) { for (double& x : out) x = kInf; return out; }   // nothing to be inside of
  if (!any_out) { for (double& x : out) x = -kInf; return out; }
  const std::vector<double> d_to_set = edt_squared(grid, inside);
  const std::vector<double> d_to_air = edt_squared(grid, comp);
  for (std::size_t e = 0; e < n; ++e)
    out[e] = inside[e] ? -std::sqrt(d_to_air[e]) * h : std::sqrt(d_to_set[e]) * h;
  return out;
}

double voxel_field_sample(const VoxelGrid& grid, const std::vector<double>& field,
                          const Vec3& p) {
  if (field.size() != grid.voxel_count() || grid.nx < 1) return 0.0;
  const double h = grid.spacing;
  // voxel CENTRES sit at origin + (i + 0.5) h, so the sample coordinate is offset by half
  const double fx = (p.x - grid.origin.x) / h - 0.5;
  const double fy = (p.y - grid.origin.y) / h - 0.5;
  const double fz = (p.z - grid.origin.z) / h - 0.5;
  auto cl = [](int a, int hi) { return a < 0 ? 0 : (a > hi ? hi : a); };
  const int i0 = cl(static_cast<int>(std::floor(fx)), grid.nx - 1);
  const int j0 = cl(static_cast<int>(std::floor(fy)), grid.ny - 1);
  const int k0 = cl(static_cast<int>(std::floor(fz)), grid.nz - 1);
  const int i1 = cl(i0 + 1, grid.nx - 1), j1 = cl(j0 + 1, grid.ny - 1),
            k1 = cl(k0 + 1, grid.nz - 1);
  const double tx = std::min(1.0, std::max(0.0, fx - i0));
  const double ty = std::min(1.0, std::max(0.0, fy - j0));
  const double tz = std::min(1.0, std::max(0.0, fz - k0));
  auto at = [&](int i, int j, int k) { return field[grid.index(i, j, k)]; };
  const double c00 = at(i0, j0, k0) * (1 - tx) + at(i1, j0, k0) * tx;
  const double c10 = at(i0, j1, k0) * (1 - tx) + at(i1, j1, k0) * tx;
  const double c01 = at(i0, j0, k1) * (1 - tx) + at(i1, j0, k1) * tx;
  const double c11 = at(i0, j1, k1) * (1 - tx) + at(i1, j1, k1) * tx;
  const double c0 = c00 * (1 - ty) + c10 * ty, c1 = c01 * (1 - ty) + c11 * ty;
  return c0 * (1 - tz) + c1 * tz;
}

}  // namespace topopt
