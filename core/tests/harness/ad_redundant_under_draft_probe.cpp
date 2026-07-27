// ad_redundant_under_draft_probe.cpp — question (d) of the AD arming review: once
// DRAFT is armed, does Active Domain add anything, or is it redundant? Draft's looser
// early-iteration tolerance lifts the ultra-dilute solves off the Jacobi-CG stagnation
// latch (draft-arming §A4/B5); AD's only real win was cutting that same Jacobi grind by
// shrinking the domain. If draft already removes the grind, AD buys nothing on top.
//
// Runs the big stagnation fixture (48x32x48, 73728 elems, the PR 209 result-1 fixture),
// recycling armed in all four, capped 12 iters, and reports the 2x2 {AD off/on} x
// {draft off/on} CG / Jacobi-fallback / latch grid. NOT a CTest target.
//
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/ad_redundant_under_draft_probe.cpp build/libtopopt.a -o /tmp/adr

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

struct Res { long long cg = 0; int jac = 0, outer = 0; int latched = 0, latch_iter = 0;
             long long escapes = 0; };

Res run(bool ad, bool draft, int iters, const SettingsRules& rules, const Material& mat) {
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 24, 24, 6, 6, 1.0);
  const std::vector<NodalLoad> loads =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  DesignBox box; box.min = Vec3{-12.0, -13.0, -12.0}; box.max = Vec3{36.0, 19.0, 36.0};

  MinimizePlasticOptions o;
  configure_production_options(o);
  fea_set_krylov_recycling(true);
  o.simp.active_domain_band = ad ? production_active_domain_band() : 0;
  o.draft_quality = draft;
  o.draft_loose_tol = production_draft_loose_tol();
  o.volume_fraction_ladder = {0.50};
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  o.design_box = box;
  o.simp.max_iterations = iters;
  o.simp.mma_plateau_window = 0;
  o.simp.change_tol = 0.0;

  Res r;
  o.on_iteration = [&](std::size_t, std::size_t, const SimpIterationObservation& ob) {
    r.cg += ob.cg_iterations; ++r.outer;
    if (!ob.cg_used_multigrid) ++r.jac;
  };
  const MinimizePlasticResult mr = minimize_plastic(part, mat, "fdm", bcs, rules, o);
  fea_set_krylov_recycling(false);
  if (!mr.evaluated.empty()) {
    const auto& v = mr.evaluated.front().optimization;
    r.latched = v.active_domain_latched ? 1 : 0;
    r.latch_iter = v.active_domain_latch_iteration;
    r.escapes = v.active_domain_escape_count;
  }
  return r;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const int iters = argc > 1 ? std::atoi(argv[1]) : 12;
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e) { std::fprintf(stderr, "rules: %s\n", e.what()); return 1; }
  const Material mat = fdm();

  std::printf("Question (d): is AD redundant once draft is armed? big stagnation 73728, "
              "recycling ON all, capped %d iters\n\n", iters);
  const Res r_none  = run(false, false, iters, rules, mat);  // rec
  const Res r_ad    = run(true,  false, iters, rules, mat);  // rec+AD
  const Res r_draft = run(false, true,  iters, rules, mat);  // rec+draft
  const Res r_both  = run(true,  true,  iters, rules, mat);  // rec+AD+draft

  std::printf(" posture        |    CG | Jacobi | AD latch\n");
  std::printf(" rec            | %5lld |  %d/%d  | -\n", r_none.cg, r_none.jac, r_none.outer);
  std::printf(" rec+AD         | %5lld |  %d/%d  | latched=%d@%d esc=%lld\n",
              r_ad.cg, r_ad.jac, r_ad.outer, r_ad.latched, r_ad.latch_iter, r_ad.escapes);
  std::printf(" rec+draft      | %5lld |  %d/%d  | -\n", r_draft.cg, r_draft.jac, r_draft.outer);
  std::printf(" rec+AD+draft   | %5lld |  %d/%d  | latched=%d@%d esc=%lld\n",
              r_both.cg, r_both.jac, r_both.outer, r_both.latched, r_both.latch_iter, r_both.escapes);

  std::printf("\n READING:\n");
  std::printf("  AD effect, draft OFF: rec+AD/rec       = %.3fx  (%+lld CG)\n",
              r_none.cg ? double(r_ad.cg)/double(r_none.cg) : 0.0, r_ad.cg - r_none.cg);
  std::printf("  AD effect, draft ON : rec+AD+draft/rec+draft = %.3fx  (%+lld CG)\n",
              r_draft.cg ? double(r_both.cg)/double(r_draft.cg) : 0.0, r_both.cg - r_draft.cg);
  std::printf("  draft effect (AD off): rec+draft/rec    = %.3fx\n",
              r_none.cg ? double(r_draft.cg)/double(r_none.cg) : 0.0);
  return 0;
}
