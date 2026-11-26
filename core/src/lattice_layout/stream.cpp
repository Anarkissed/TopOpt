// notes30 (option D): the strut stream. See stream.hpp and lattice_layout.hpp (StrutTap).
#include "stream.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <thread>

namespace topopt::lattice_layout {

std::shared_ptr<LayoutMap> make_layout_map(const Layout& layout, const Domain& domain, const MapAsk& ask, int threads,
                                           const std::atomic<bool>* stop) {
  if (!ask.on()) return nullptr;
  const auto t0 = std::chrono::steady_clock::now();
  const int nx = ask.nx, ny = ask.ny, nz = ask.nz;
  const SolidAt solid_at(layout);
  const std::size_t n = static_cast<std::size_t>(nx) * ny * nz;
  std::vector<std::uint8_t> cls(n, 0);   // 0 outside, 1 solid, 2 open, 3 asked for and no cell holds it (D14: solid)
  std::atomic<int> next{0};
  std::array<std::int64_t, 5> nocell_total{};
  std::mutex nocell_mu;
  const auto stopped = [&] { return stop && stop->load(std::memory_order_relaxed); };
  auto work = [&] {
    const Domain::Probe probe = domain.probe();   // one per thread
    std::array<std::int64_t, 5> local{};
    for (int z = next++; z < nz; z = next++) {
      if (stopped()) return;
      for (int y = 0; y < ny; ++y)
        for (int x = 0; x < nx; ++x) {
          const Vec3 p = ask.at(x, y, z);
          const Where w = probe.where(p);
          std::uint8_t c = 1;
          if (w.why == Why::Outside) {
            c = 0;
          } else if (w.why == Why::Lattice) {
            c = solid_at(probe, p, w) ? 3 : 2;
            if (c == 3) ++local[std::min<std::size_t>(4, static_cast<std::size_t>(solid_at.why(probe, p).why))];
          }
          cls[(static_cast<std::size_t>(z) * ny + y) * nx + x] = c;
        }
    }
    std::lock_guard<std::mutex> g(nocell_mu);
    for (std::size_t k = 0; k < 5; ++k) nocell_total[k] += local[k];
  };
  const int nt = std::max(1, threads > 0 ? threads : static_cast<int>(std::thread::hardware_concurrency()));
  std::vector<std::thread> pool;
  for (int i = 1; i < nt; ++i) pool.emplace_back(work);
  work();
  for (std::thread& t : pool) t.join();
  if (stopped()) return nullptr;
  auto out = std::make_shared<LayoutMap>();
  out->nx = nx;
  out->ny = ny;
  out->nz = nz;
  out->rg.assign(2 * n, static_cast<std::int8_t>(-127));
  const auto at = [&](int x, int y, int z) -> std::uint8_t {
    if (x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz) return 0;
    return cls[(static_cast<std::size_t>(z) * ny + y) * nx + x];
  };
  for (int z = 0; z < nz; ++z)
    for (int y = 0; y < ny; ++y)
      for (int x = 0; x < nx; ++x) {
        const std::size_t i = (static_cast<std::size_t>(z) * ny + y) * nx + x;
        const std::uint8_t c = cls[i];
        if (c >= 2) ++out->asked;
        if (c == 3) ++out->unheld;
        bool open = c == 2;
        if (c == 0)   // an outside voxel next to open lattice reads open: the surface at the opening is cut
          open = at(x - 1, y, z) == 2 || at(x + 1, y, z) == 2 || at(x, y - 1, z) == 2 || at(x, y + 1, z) == 2 ||
                 at(x, y, z - 1) == 2 || at(x, y, z + 1) == 2;
        out->rg[2 * i] = open ? 127 : -127;
        out->rg[2 * i + 1] = c != 0 ? 127 : -127;
      }
  out->nocell = nocell_total;
  out->ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  return out;
}

}  // namespace topopt::lattice_layout
