// Lattice rebuild, Install 2a: the stress result a lattice is graded by (rules R16, R17). See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <thread>
#include <vector>

namespace topopt::lattice_layout {

bool DemandField::empty() const {
  if (nx <= 0 || ny <= 0 || nz <= 0 || !(spacing > 0.0)) return true;
  return mpa.size() != static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) * static_cast<std::size_t>(nz);
}

double DemandField::highest_in(const Vec3& lo, const Vec3& hi) const {
  if (empty()) return 0.0;
  const double l[3] = {lo.x, lo.y, lo.z}, h[3] = {hi.x, hi.y, hi.z};
  const double o[3] = {origin.x, origin.y, origin.z};
  const int n[3] = {nx, ny, nz};
  int first[3], last[3];
  for (int ax = 0; ax < 3; ++ax) {
    const double a = (std::min(l[ax], h[ax]) - o[ax]) / spacing;
    const double b = (std::max(l[ax], h[ax]) - o[ax]) / spacing;
    if (!std::isfinite(a) || !std::isfinite(b)) return 0.0;
    // The voxels sharing some volume with [a, b]: floor(a) .. ceil(b) - 1. With no width, the voxel holding it.
    const double f = std::floor(a);
    const double t = b > a ? std::ceil(b) - 1.0 : f;
    if (t < 0.0 || f > n[ax] - 1.0) return 0.0;
    first[ax] = static_cast<int>(std::max(0.0, f));
    last[ax] = static_cast<int>(std::min(n[ax] - 1.0, t));
    if (first[ax] > last[ax]) return 0.0;
  }
  float best = 0.0f;
  bool any = false;
  for (int k = first[2]; k <= last[2]; ++k)
    for (int j = first[1]; j <= last[1]; ++j) {
      const float* row = mpa.data() + index(0, j, k);
      for (int i = first[0]; i <= last[0]; ++i)
        if (!any || row[i] > best) { best = row[i]; any = true; }
    }
  return any ? static_cast<double>(best) : 0.0;
}

double stress_reference(const Domain& domain, const DemandField& field, double percentile, int threads) {
  if (field.empty()) return 0.0;
  const double q = std::clamp(std::isfinite(percentile) ? percentile : 0.0, 0.0, 1.0);
  // One list per layer of the grid, so the threads never share one; joined in layer order.
  std::vector<std::vector<float>> layer(static_cast<std::size_t>(field.nz));
  std::atomic<int> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    for (int k = next.fetch_add(1); k < field.nz; k = next.fetch_add(1)) {
      if (domain.stop_asked()) return;
      std::vector<float>& out = layer[static_cast<std::size_t>(k)];
      for (int j = 0; j < field.ny; ++j)
        for (int i = 0; i < field.nx; ++i) {
          const Vec3 c{field.origin.x + (i + 0.5) * field.spacing, field.origin.y + (j + 0.5) * field.spacing,
                       field.origin.z + (k + 0.5) * field.spacing};
          if (probe.where(c).lattice()) out.push_back(field.mpa[field.index(i, j, k)]);
        }
    }
  };
  const int nt = std::max(1, std::min(field.nz, threads > 0 ? threads
                                                            : static_cast<int>(std::thread::hardware_concurrency())));
  std::vector<std::thread> pool;
  for (int t = 1; t < nt; ++t) pool.emplace_back(work);
  work();
  for (std::thread& t : pool) t.join();
  domain.check_stop();
  std::vector<float> all;
  for (const std::vector<float>& l : layer) all.insert(all.end(), l.begin(), l.end());
  if (all.empty()) return 0.0;
  const std::size_t at = static_cast<std::size_t>(std::floor(q * static_cast<double>(all.size() - 1)));
  std::nth_element(all.begin(), all.begin() + static_cast<std::ptrdiff_t>(at), all.end());
  return static_cast<double>(all[at]);
}

}  // namespace topopt::lattice_layout
