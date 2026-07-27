// ad_L_convergence_probe.cpp — faithful, minimal reproduction of PR 209 result 2:
// on the L grid (draft_quality_phase2_scale.cpp's "L 32x16x32"), the ARMED posture
// (AD-on) FAILS TO CONVERGE (the matfree multigrid stalls into Jacobi-CG and throws),
// while AD-off converges. Runs ONLY the tight ladder for each posture (the scale
// harness ran tight+draft+probed = 3x the cost; result 2 lives in the tight run), at
// the exact production config, UNCAPPED (Eigen/mf default 2*n), so this is the honest
// test of the asymmetry that a too-low CG cap confounds. NOT a CTest target.
//
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/ad_L_convergence_probe.cpp build/libtopopt.a -o /tmp/adl

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0; m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny, int t,
                    double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int n = fea_node_index(g, a, b, arm);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

void run(bool ad, const SettingsRules& rules, const Material& mat) {
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 16, 16, 6, 4, 2.0);  // scale harness "L 32x16x32"
  const std::vector<NodalLoad> load =
      traction_loads(part, VoxelTag::Load, Vec3{0, 0, -30});
  DesignBox box; box.min = Vec3{0, 0, 0}; box.max = Vec3{16*2.0*2.0, 6*2.0*2.0, 16*2.0*2.0};

  MinimizePlasticOptions o;
  configure_production_options(o);
  if (!ad) o.simp.active_domain_band = 0;
  o.volume_fraction_ladder = {0.50, 0.35, 0.25};
  o.margin_stop = 0.0;
  o.external_loads = load;
  o.gravity = 9810.0*1e-9; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  o.design_box = box;
  o.simp.cg_tolerance = 1e-8;
  o.draft_quality = false;   // tight (result 2 is the tight run)
  // UNCAPPED: leave o.simp.cg_max_iterations at its default (mf uses 2*n).

  long long cg = 0;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& ob){
    cg += ob.cg_iterations;
  };
  {
    MinimizePlasticOptions dims; dims.design_box = box;
    VoxelGrid sg = minimize_plastic_solved_grid(part, dims);
    std::printf("[%s] L grid %dx%dx%d, tight 1e-8, UNCAPPED, ladder {0.50,0.35,0.25}\n",
                ad ? "AD-on " : "AD-off", sg.nx, sg.ny, sg.nz);
  }
  const auto t0 = std::chrono::steady_clock::now();
  try {
    const MinimizePlasticResult r = minimize_plastic(part, mat, "fdm", bcs, rules, o);
    const double wall =
        std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
    std::printf("[%s] CONVERGED: trajectory CG=%lld, %zu rung(s) evaluated, %.1f s\n\n",
                ad ? "AD-on " : "AD-off", cg, r.evaluated.size(), wall);
  } catch (const std::exception& e) {
    const double wall =
        std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
    std::printf("[%s] *** THREW (did not converge) after %lld trajectory CG, %.1f s ***\n"
                "        what(): %s\n\n",
                ad ? "AD-on " : "AD-off", cg, wall, e.what());
  }
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e){ std::fprintf(stderr,"rules: %s\n", e.what()); return 1; }
  const Material mat = fdm();
  std::printf("PR 209 result 2 — L-grid AD-on non-convergence (faithful, uncapped)\n\n");
  run(false, rules, mat);  // AD-off: expect CONVERGE
  run(true,  rules, mat);  // AD-on : expect THROW
  return 0;
}
