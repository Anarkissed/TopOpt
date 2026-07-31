// O9 determinism — a parity-padded odd-grid solve is bit-identical run-to-run
// and within-process repeat, at 1, 2, 4, 8 matvec threads.
#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <cstdint>
#include <cstdio>
#include <initializer_list>
#include <vector>

using namespace topopt;

static std::uint64_t fnv(const void* data, std::size_t n) {
  const unsigned char* p = static_cast<const unsigned char*>(data);
  std::uint64_t h = 1469598103934665603ull;
  for (std::size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}

int main() {
  VoxelGrid g;
  g.nx = 31; g.ny = 15; g.nz = 27;  // every axis odd -> full pad engagement
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      for (int k = 0; k < 3; ++k) bcs.push_back({n, k, 0.0});
    }
  std::vector<NodalLoad> loads;
  for (int b = 0; b <= g.ny; ++b)
    loads.push_back({fea_node_index(g, g.nx, b, g.nz), 2, -10.0});
  std::vector<double> ey(g.voxel_count());
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        ey[g.index(i, j, k)] = ((i * 7 + j * 3 + k) % 5 == 0) ? 2.1e-6 : 2100.0;

  for (int threads : {1, 2, 4, 8}) {
    fea_set_matfree_threads(threads);
    CgInfo i1, i2;
    FeaSolution a = fea_solve_mgcg_matfree(g, ey, 0.3, bcs, loads, 1e-10, 0, &i1);
    FeaSolution b = fea_solve_mgcg_matfree(g, ey, 0.3, bcs, loads, 1e-10, 0, &i2);
    std::printf("threads=%d mg=%d levels=%d it=%d/%d hash=%016llx repeat=%s\n",
                threads, i1.used_multigrid, i1.mg_levels, i1.iterations,
                i2.iterations,
                (unsigned long long)fnv(a.u.data(), a.u.size() * 8),
                fnv(a.u.data(), a.u.size() * 8) == fnv(b.u.data(), b.u.size() * 8)
                    ? "IDENTICAL" : "DIFFERS");
  }
  return 0;
}
