// ad_L_draft_probe.cpp — the PRODUCTION-RELEVANT half of result 2. Production ships
// rec+AD+DRAFT (both armed). Result 2 (AD-on throws at L) was measured draft-OFF
// (tight). Draft loosens the early ultra-dilute solves off the Jacobi stagnation latch
// (draft-arming A4/B5) — so the question that actually governs the shipped posture is:
// with DRAFT ON, does AD still cause the L-grid non-convergence, or does draft's looser
// trajectory keep the multigrid healthy so AD-on+draft converges? Runs the L grid full
// ladder {0.50,0.35,0.25} with draft ON, AD off then on, try/catch. NOT a CTest target.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <exception>
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

void run(bool ad, bool draft, const SettingsRules& rules, const Material& mat) {
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 16, 16, 6, 4, 2.0);
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
  o.draft_quality = draft;
  o.draft_loose_tol = production_draft_loose_tol();

  long long cg = 0; int jac = 0, outer = 0;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& ob){
    cg += ob.cg_iterations; ++outer; if (!ob.cg_used_multigrid) ++jac;
  };
  const char* tag = ad ? (draft ? "AD-on +draft " : "AD-on  tight ")
                       : (draft ? "AD-off+draft " : "AD-off tight ");
  const auto t0 = std::chrono::steady_clock::now();
  try {
    const MinimizePlasticResult r = minimize_plastic(part, mat, "fdm", bcs, rules, o);
    const double wall =
        std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
    std::printf("[%s] CONVERGED: CG=%lld, Jacobi=%d/%d, %zu rungs, %.1f s\n",
                tag, cg, jac, outer, r.evaluated.size(), wall);
  } catch (const std::exception& e) {
    const double wall =
        std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
    std::printf("[%s] *** THREW after %lld CG (Jacobi=%d/%d), %.1f s: %s ***\n",
                tag, cg, jac, outer, wall, e.what());
  }
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e){ std::fprintf(stderr,"rules: %s\n", e.what()); return 1; }
  const Material mat = fdm();
  std::printf("L-grid full ladder, DRAFT ON (production stack): does AD still break?\n\n");
  run(false, true, rules, mat);  // rec+draft (AD off)   -> the production-minus-AD baseline
  run(true,  true, rules, mat);  // rec+AD+draft         -> the SHIPPED posture
  return 0;
}
