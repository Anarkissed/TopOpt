// O7 — stash-rebuild checksum. Solves on ALREADY-EVEN grids must be
// bit-identical between the pre-change and post-change library. Uses only APIs
// that exist in both builds. Prints FNV-1a hashes of the raw result bytes.
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/voxel.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

using namespace topopt;

static std::uint64_t fnv(const void* data, std::size_t n) {
  const unsigned char* p = static_cast<const unsigned char*>(data);
  std::uint64_t h = 1469598103934665603ull;
  for (std::size_t i = 0; i < n; ++i) {
    h ^= p[i];
    h *= 1099511628211ull;
  }
  return h;
}

static VoxelGrid solid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

int main() {
  // (1) matrix-free MG on even 32^3, solid and graded
  {
    VoxelGrid g = solid(32, 32, 32);
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
          ey[g.index(i, j, k)] =
              ((i * 7 + j * 3 + k) % 5 == 0) ? 1e-9 * 2100.0 : 2100.0;
    CgInfo i0, i1, i2;
    FeaSolution s = fea_solve_mgcg_matfree(g, 2100.0, 0.3, bcs, loads, 1e-10, 0, &i0);
    FeaSolution gr = fea_solve_mgcg_matfree(g, ey, 0.3, bcs, loads, 1e-10, 0, &i1);
    FeaSolution as = fea_solve_mgcg(g, 2100.0, 0.3, bcs, loads, 1e-10, 0, &i2);
    std::printf("mf_solid_32   mg=%d it=%d hash=%016llx\n", i0.used_multigrid,
                i0.iterations, (unsigned long long)fnv(s.u.data(), s.u.size() * 8));
    std::printf("mf_graded_32  mg=%d it=%d hash=%016llx\n", i1.used_multigrid,
                i1.iterations, (unsigned long long)fnv(gr.u.data(), gr.u.size() * 8));
    std::printf("asm_solid_32  mg=%d it=%d hash=%016llx\n", i2.used_multigrid,
                i2.iterations, (unsigned long long)fnv(as.u.data(), as.u.size() * 8));
  }
  // (2) production-config minimize_plastic on even 32^3 (and even-deep-blocked 30^3)
  for (int n : {32, 30}) {
    VoxelGrid g = solid(n, n, n);
    std::vector<DirichletBC> bcs;
    const int nnx = g.nx + 1, nny = g.ny + 1;
    for (int b = 0; b < nny; ++b)
      for (int a = 0; a < nnx; ++a) {
        const int node = (0 * nny + b) * nnx + a;
        for (int c = 0; c < 3; ++c) bcs.push_back({node, c, 0.0});
      }
    Material mat;
    mat.youngs_modulus_mpa = 3500.0;
    mat.yield_strength_mpa = 0.02;
    mat.density_g_cm3 = 1.24;
    mat.z_knockdown = 0.55;
    mat.poisson = 0.33;
    mat.family = "fdm";
    SettingsRules rules;
    FdmBand band;
    band.unbounded = true;
    band.walls = 3;
    band.top_layers = 4;
    band.bottom_layers = 4;
    band.infill_percent = 20;
    band.infill_pattern = "grid";
    rules.fdm_bands.push_back(band);
    MinimizePlasticOptions o;
    configure_production_options(o);
    o.volume_fraction_ladder = {0.6};
    o.margin_stop = 0.0;
    o.gravity = 1.0e6;
    o.gravity_direction = Vec3{0, 0, -1};
    o.simp.max_iterations = 12;
    o.simp.change_tol = 0.0;
    const MinimizePlasticResult r = minimize_plastic(g, mat, "PLA_test", bcs, rules, o);
    std::uint64_t h = 1469598103934665603ull;
    for (const auto& v : r.evaluated) {
      const auto& d = v.optimization.physical_density;
      h ^= fnv(d.data(), d.size() * 8);
      h *= 1099511628211ull;
    }
    std::printf("mp_%d  used_mg=%d levels=%d variants=%zu hash=%016llx\n", n,
                r.used_multigrid, r.mg_levels, r.evaluated.size(),
                (unsigned long long)h);
  }
  return 0;
}
