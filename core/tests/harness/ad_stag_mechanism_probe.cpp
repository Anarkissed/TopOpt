// ad_stag_mechanism_probe.cpp — localise WHY Active Domain costs MORE CG than
// recycling-alone on the stagnation fixture (PR 209 result 1: rec 15349 CG ->
// rec+AD 19329 CG, +26%, escape latch @iter3). NOT a CTest target; a standalone
// per-iteration diagnostic, sibling of draft_arming_gate.cpp (whose make_big_stagnation
// fixture and l_bracket/traction helpers this reproduces verbatim so the numbers are
// the SAME grid). Prints, per trajectory iteration, the CG count, whether multigrid
// carried or the solve fell to Jacobi-CG, whether the hierarchy built, the V-cycles
// burned, and the AD active fraction / latch state — so the +3980 CG is attributed to
// specific iterations rather than inferred from the aggregate.
//
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/ad_stag_mechanism_probe.cpp build/libtopopt.a -o /tmp/adm

#include <chrono>
#include <cstdio>
#include <cstdlib>
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

// verbatim from draft_arming_gate.cpp
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

void run(const char* label, bool ad, int iters, const SettingsRules& rules,
         const Material& material) {
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 24, 24, 6, 6, 1.0);  // make_big_stagnation()
  const std::vector<NodalLoad> loads =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  DesignBox box; box.min = Vec3{-12.0, -13.0, -12.0}; box.max = Vec3{36.0, 19.0, 36.0};

  MinimizePlasticOptions o;
  configure_production_options(o);
  fea_set_krylov_recycling(true);                            // recycling armed both
  o.simp.active_domain_band = ad ? production_active_domain_band() : 0;
  o.draft_quality = false;                                   // draft OFF (isolate AD)
  o.volume_fraction_ladder = {0.50};
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  o.design_box = box;
  o.simp.max_iterations = iters;
  o.simp.mma_plateau_window = 0;   // capped, apples-to-apples
  o.simp.change_tol = 0.0;

  std::printf("\n===== %s =====\n", label);
  std::printf(" iter |    CG | MG? | hier | cyc | active_frac | AD-latched\n");
  long long cg_total = 0;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& ob) {
    cg_total += ob.cg_iterations;
    std::printf(" %4d | %5d |  %s  |  %s   | %3d |   %.4f    | (see final)\n",
                ob.iteration, ob.cg_iterations, ob.cg_used_multigrid ? "MG" : "Jc",
                ob.cg_hier_built ? "Y" : "n", ob.cg_mg_cycles_attempted,
                ob.active_fraction);
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r = minimize_plastic(part, material, "fdm", bcs, rules, o);
  const double wall =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  fea_set_krylov_recycling(false);

  std::printf(" trajectory CG total = %lld   (%.1f s incl. final cert)\n", cg_total, wall);
  if (!r.evaluated.empty()) {
    const auto& v = r.evaluated.front().optimization;
    std::printf(" AD: band=%d latched=%d@iter%d escapes=%lld f_bar=%.4f\n",
                v.active_domain_band, v.active_domain_latched ? 1 : 0,
                v.active_domain_latch_iteration, v.active_domain_escape_count,
                v.active_fraction_mean);
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const int iters = argc > 1 ? std::atoi(argv[1]) : 12;
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e) { std::fprintf(stderr, "rules: %s\n", e.what()); return 1; }
  const Material material = fdm();
  std::printf("AD stagnation mechanism probe — big stagnation 48x32x48 (73728), capped %d\n",
              iters);
  run("rec (no AD)", false, iters, rules, material);
  run("rec+AD", true, iters, rules, material);
  return 0;
}
