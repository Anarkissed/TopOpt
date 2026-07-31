// Reproduction of the 128x31x118 odd-axis run (task: multigrid-odd-axis-cliff,
// O5/O6). Self-weight minimize_plastic on a solid block of exactly the
// maintainer run's grid, production solver config (matfree MG + GenEO armed),
// limited MMA iterations so the before/after comparison is tractable.
// BEFORE = parity pad OFF (today's behavior: build-rejected, Jacobi+GenEO)
// AFTER  = parity pad AUTO (the fix: index space padded to 128x32x120)
#include "topopt/coarsen.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace topopt;

int main(int argc, char** argv) {
  const int pad_mode = argc > 1 ? std::atoi(argv[1]) : 1;
  const int max_iters = argc > 2 ? std::atoi(argv[2]) : 5;
  const int nx = argc > 3 ? std::atoi(argv[3]) : 128;
  const int ny = argc > 4 ? std::atoi(argv[4]) : 31;
  const int nz = argc > 5 ? std::atoi(argv[5]) : 118;

  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz;
  g.spacing = 1.7053;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);

  // Clamp the z=0 face.
  std::vector<DirichletBC> bcs;
  const int nnx = g.nx + 1, nny = g.ny + 1;
  for (int b = 0; b < nny; ++b)
    for (int a = 0; a < nnx; ++a) {
      const int node = (0 * nny + b) * nnx + a;
      for (int c = 0; c < 3; ++c) bcs.push_back({node, c, 0.0});
    }

  Material mat;
  mat.youngs_modulus_mpa = 3500.0;
  mat.yield_strength_mpa = 35.0;
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
  configure_production_options(o);  // matfree MG solver, GenEO armed, etc.
  o.volume_fraction_ladder = {0.6};
  o.margin_stop = 0.0;
  o.gravity = 9810.0 * 1e-9 * 1.24 * 1e3;  // self-weight-ish; magnitude irrelevant to conditioning story
  o.gravity = 1.0e6;
  o.gravity_direction = Vec3{0, 0, -1};
  o.simp.max_iterations = max_iters;
  o.simp.change_tol = 0.0;

  long long total_cg = 0, mg_solves = 0, jac_solves = 0;
  int max_levels = 0;
  o.on_iteration = [&](std::size_t, std::size_t,
                       const SimpIterationObservation& obs) {
    total_cg += obs.cg_iterations;
    if (obs.cg_used_multigrid) { ++mg_solves; if (obs.cg_mg_levels > max_levels) max_levels = obs.cg_mg_levels; }
    else ++jac_solves;
    std::printf("  iter %3d: cg=%6d mg=%d levels=%d hier_built=%d geneo_dim=%d\n",
                obs.iteration, obs.cg_iterations, obs.cg_used_multigrid ? 1 : 0,
                obs.cg_mg_levels, obs.cg_hier_built ? 1 : 0, obs.cg_geneo_dim);
    std::fflush(stdout);
  };

  fea_set_mg_parity_pad_mode(pad_mode);
  std::printf("=== repro %dx%dx%d pad_mode=%d max_iters=%d ===\n", nx, ny, nz,
              pad_mode, max_iters);
  std::fflush(stdout);
  const MinimizePlasticResult r = minimize_plastic(g, mat, "PLA_test", bcs,
                                                   rules, o);
  std::printf(
      "RESULT pad_mode=%d: used_multigrid=%d mg_levels=%d hier_ever_built=%d\n"
      "  observer solves: mg=%lld jacobi=%lld total_cg_iters=%lld max_levels=%d\n"
      "  geneo: armed_solves=%lld basis_builds=%lld coarse_refreshes=%lld "
      "basis_dim=%d basis_mb=%.1f\n",
      pad_mode, r.used_multigrid ? 1 : 0, r.mg_levels,
      r.mg_hierarchy_ever_built ? 1 : 0, mg_solves, jac_solves, total_cg,
      max_levels, fea_geneo_armed_solves(), fea_geneo_basis_builds(),
      fea_geneo_coarse_refreshes(), fea_geneo_basis_dim(),
      static_cast<double>(fea_geneo_basis_bytes()) / (1024.0 * 1024.0));
  return 0;
}
