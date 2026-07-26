// draft_quality_phase2_scale.cpp — D4 (the win must survive scale) + probe cost at
// scale, for handoff 2026-07-26-draft-quality-phase2. Phase 1 measured the summed-
// trajectory-CG win at 2.07x on 16x8x16 but only 1.53x at 32x16x32 — a DOWNWARD
// trend, and the maintainer's real job is 128^3. This harness measures the win
// across THREE grid sizes (the largest that runs on a 6-P-core Mac), in BOTH the
// production posture (AD-on, post-187) and Phase 1's pre-187 posture (AD-off), and
// at each grid reports the Phase-2 probe's cost as a fraction of the ladder (D3 at
// scale). Every design/win row carries grid dims + solid-voxel count (D7).
//
// Build as for the other draft harnesses (BUILD.md). Unbuffered stdout: watch live.

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {
constexpr double kIso = 0.5;

VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g; g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0,0,0};
  g.tags.assign(static_cast<std::size_t>(span)*ny*arm, VoxelTag::Empty);
  for (int k=0;k<arm;++k) for (int j=0;j<ny;++j) for (int i=0;i<span;++i)
    if (i<t||k<t) g.set_tag(i,j,k,VoxelTag::Interior);
  auto solid=[&](int i,int j,int k){ if(i<0||j<0||k<0||i>=span||j>=ny||k>=arm) return false;
    return g.tag(i,j,k)!=VoxelTag::Empty; };
  for (int k=0;k<arm;++k) for (int j=0;j<ny;++j) for (int i=0;i<span;++i){
    if(!solid(i,j,k)) continue;
    if(!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||!solid(i,j,k-1)||!solid(i,j,k+1))
      g.set_tag(i,j,k,VoxelTag::Surface); }
  for (int j=0;j<ny;++j) for (int i=0;i<t;++i) g.set_tag(i,j,arm-1,VoxelTag::Fixture);
  bcs.clear();
  for (int b=0;b<=ny;++b) for (int a=0;a<=t;++a){ const int n=fea_node_index(g,a,b,arm);
    bcs.push_back({n,0,0.0}); bcs.push_back({n,1,0.0}); bcs.push_back({n,2,0.0}); }
  for (int k=0;k<t;++k) for (int j=0;j<ny;++j) g.set_tag(span-1,j,k,VoxelTag::Load);
  return g;
}
Material fdm(){ Material m; m.youngs_modulus_mpa=3500; m.yield_strength_mpa=55;
  m.density_g_cm3=1.24; m.z_knockdown=0.55; m.poisson=0.33; m.family="fdm"; return m; }

struct RunOut {
  std::vector<double> rung_cg;      // trajectory CG per rung (probe excluded)
  std::vector<long long> probe_cg;  // probe CG per rung
  std::vector<double> probe_flip;
  long long total_cg = 0;
  double wall_s = 0.0;
};

RunOut run(bool ad, bool draft, double loose, double design_flip,
           const VoxelGrid& part, const std::vector<DirichletBC>& bcs,
           const std::vector<NodalLoad>& loads, const SettingsRules& rules,
           const Material& material, const DesignBox& box,
           const std::vector<double>& ladder) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  if (!ad) o.simp.active_domain_band = 0;
  o.volume_fraction_ladder = ladder;
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0*1e-9; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  o.design_box = box;
  o.simp.cg_tolerance = 1e-8;
  // Optional CG cap (TOPOPT_SCALE_CGCAP): bounds the per-solve CG so a stagnation-
  // dominated tight baseline (multigrid falling to Jacobi-CG on a non-coarsenable
  // large grid) cannot grind for tens of minutes. Where it BINDS, the tight win is a
  // LOWER BOUND (tight would have spent more). Absent => Eigen default (uncapped).
  if (const char* cap = std::getenv("TOPOPT_SCALE_CGCAP"))
    o.simp.cg_max_iterations = std::atoi(cap);
  o.draft_quality = draft;
  o.draft_loose_tol = loose;
  o.draft_escalation_c_gap = 1e30;               // never escalate on gap
  // design_flip < 0 => design trigger OFF (no probe, pure-win run);
  // design_flip >= 0 => armed (1e30 sentinel = probe measured but never fires).
  o.draft_use_design_trigger = design_flip >= 0.0;
  o.draft_escalation_design_flip = design_flip;
  RunOut out;
  std::vector<long long> cg; std::vector<int> it;
  o.on_iteration = [&](std::size_t rung, std::size_t, const SimpIterationObservation& ob){
    if (rung >= cg.size()) { cg.resize(rung+1,0); }
    cg[rung] += ob.cg_iterations;
  };
  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r = minimize_plastic(part, material, "fdm", bcs, rules, o);
  out.wall_s = std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
  for (std::size_t i=0;i<cg.size();++i){ out.rung_cg.push_back((double)cg[i]); out.total_cg += cg[i]; }
  out.probe_cg = r.draft_rung_probe_cg;
  out.probe_flip = r.draft_rung_probe_flip;
  return out;
}

long long solid_count(const VoxelGrid& g){ long long n=0;
  for (int k=0;k<g.nz;++k) for (int j=0;j<g.ny;++j) for (int i=0;i<g.nx;++i)
    if (g.solid(i,j,k)) ++n; return n; }

struct Grid { const char* name; int arm, span, ny, t; std::vector<double> ladder; };

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e){ std::fprintf(stderr,"rules: %s\n", e.what()); return 1; }
  const Material material = fdm();
  const double h = 2.0;

  // Three stagnation grids, geometrically similar to Phase 1's S and L.
  std::vector<Grid> grids = {
    {"S 16x8x16",  8,  8, 3, 2, {0.50,0.35,0.24}},
    {"M 24x12x24", 12, 12, 4, 3, {0.50,0.35,0.25}},
    {"L 32x16x32", 16, 16, 6, 4, {0.50,0.35,0.25}},
  };
  // Focused-subset selection via TOPOPT_SCALE_GRIDS (e.g. "L" or "S,M"): lets a slow
  // stagnation-dominated large grid be measured on its own without redoing the small
  // ones. Absent => all three.
  if (const char* sel = std::getenv("TOPOPT_SCALE_GRIDS")) {
    const std::string s = sel;
    std::vector<Grid> pick;
    for (const Grid& g : grids)
      if (s.find(g.name[0]) != std::string::npos) pick.push_back(g);
    if (!pick.empty()) grids = pick;
  }

  std::printf("D4 — the win across scale (summed trajectory CG, tight vs draft 1e-3),\n");
  std::printf("     and D3 probe cost at scale. floor threshold measured on grid S.\n");

  // Posture selection via TOPOPT_SCALE_AD ("on"/"off"): AD-on tight can FAIL to
  // converge on a large restricted-domain grid (multigrid stalls into Jacobi and the
  // matfree solver throws), so the win-vs-scale trend is measured in the AD-off
  // posture that reliably converges (and matches Phase 1's numbers). Absent => both.
  std::vector<bool> postures = {true, false};
  if (const char* a = std::getenv("TOPOPT_SCALE_AD")) {
    const std::string s = a;
    if (s == "on") postures = {true};
    else if (s == "off") postures = {false};
  }
  for (bool ad : postures) {
    std::printf("\n==================== POSTURE: %s ====================\n",
                ad ? "AD-on (production, post-187)" : "AD-off (Phase-1 pre-187)");
    std::printf(" grid (solid)        | tight CG | draft CG | WIN | probe/ladder %% | probe flips(1e-3)\n");
    for (const Grid& gd : grids) {
      std::vector<DirichletBC> bcs;
      VoxelGrid part = l_bracket(bcs, gd.arm, gd.span, gd.ny, gd.t, h);
      const std::vector<NodalLoad> load = traction_loads(part, VoxelTag::Load, Vec3{0,0,-30});
      DesignBox box; box.min = Vec3{0,0,0};
      box.max = Vec3{gd.span*h*2.0, gd.ny*h*2.0, gd.arm*h*2.0};
      MinimizePlasticOptions dims; dims.design_box = box;
      VoxelGrid sg = minimize_plastic_solved_grid(part, dims);
      const long long sc = solid_count(sg);

      RunOut tight = run(ad, false, 1e-3, -1.0, part, bcs, load, rules, material, box, gd.ladder);
      RunOut draft = run(ad, true, 1e-3, -1.0, part, bcs, load, rules, material, box, gd.ladder);
      // Probe cost: a draft run with the trigger armed-but-measuring (1e30).
      RunOut probed = run(ad, true, 1e-3, 1e30, part, bcs, load, rules, material, box, gd.ladder);
      long long pcg = 0; double maxflip = 0.0;
      for (auto v : probed.probe_cg) pcg += v;
      for (auto v : probed.probe_flip) if (v > maxflip) maxflip = v;
      const double win = draft.total_cg>0 ? double(tight.total_cg)/double(draft.total_cg) : 0.0;
      const double ppct = draft.total_cg>0 ? 100.0*double(pcg)/double(draft.total_cg) : 0.0;
      std::printf(" %-11s %dx%dx%d (%lld) | %8lld | %8lld | %.2fx | %.2f%% | %.4f\n",
                  gd.name, sg.nx, sg.ny, sg.nz, sc, tight.total_cg, draft.total_cg,
                  win, ppct, maxflip);
    }
  }
  std::printf("\n########## DONE (scale bars). ##########\n");
  return 0;
}
