// draft_quality_inherit_probe.cpp — companion to the draft_quality probes
// (handoff 2026-07-25-draft-quality). The base + divergence probes ran with
// warm_start_inherit OFF and found the SHIPPED design tolerance-robust (each rung
// re-optimizes from uniform, so a diverged non-terminal rung never reaches the
// terminal one). But the PRODUCTION loadcase path runs warm_start_inherit = TRUE
// (loadcase.cpp): rung k+1 seeds from rung k's converged design, so a rung that
// diverges under an aggressive loose tolerance can PROPAGATE that divergence down
// to the shipped rung. THIS is the case where the escalation belt (part d) earns
// its keep — a rung re-run tight re-seeds the next rung from the corrected design.
//
// It measures, on the 16x8x16 stagnation grid with inheritance ON:
//   * the production-tolerance (1e-3) win + terminal design vs tight,
//   * whether an AGGRESSIVE loose tolerance (5e-1) makes the terminal design
//     genuinely diverge from tight WITH inheritance,
//   * whether escalation (conservative "every rung", and the gap-triggered
//     threshold) RECOVERS the terminal design, and at what CG cost.
// Same determinism / thermal discipline. Build as for the base probe.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
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

struct ClassDiff { long long flips=0, ref_solid=0; double frac=0.0; };
ClassDiff class_diff(const std::vector<double>& ref, const std::vector<double>& b){
  ClassDiff d; if (ref.size()!=b.size()||ref.empty()) return d;
  for (std::size_t i=0;i<ref.size();++i){ bool ra=ref[i]>kIso, rb=b[i]>kIso;
    if(ra)++d.ref_solid; if(ra!=rb)++d.flips; }
  d.frac = d.ref_solid>0 ? double(d.flips)/double(d.ref_solid) : 0.0; return d;
}
struct RungOut { double vf=0; long long cg=0; std::vector<double> density;
  double gap=-1; int escalated=0; };
struct RunOut { std::vector<RungOut> rungs; std::vector<double> terminal; long long total_cg=0; double wall=0; };

RunOut run(bool draft, double loose, double esc,
           const VoxelGrid& part, const std::vector<DirichletBC>& bcs,
           const std::vector<NodalLoad>& loads, const SettingsRules& rules,
           const Material& material, const DesignBox& box,
           const std::vector<double>& ladder) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = ladder;
  o.margin_stop = 0.0;
  o.external_loads = loads;
  o.gravity = 9810.0*1e-9; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  o.design_box = box;
  o.warm_start_inherit = true;          // the production loadcase posture
  o.simp.cg_tolerance = 1e-8;
  o.draft_quality = draft; o.draft_loose_tol = loose; o.draft_escalation_c_gap = esc;
  RunOut out; std::vector<long long> cg;
  o.on_iteration = [&](std::size_t r, std::size_t, const SimpIterationObservation& ob){
    if (r>=cg.size()) cg.resize(r+1,0); cg[r]+=ob.cg_iterations; };
  auto t0=std::chrono::steady_clock::now();
  auto res = minimize_plastic(part, material, "fdm", bcs, rules, o);
  out.wall = std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
  for (std::size_t i=0;i<res.evaluated.size();++i){ RungOut row;
    row.vf=res.evaluated[i].requested_volume_fraction;
    row.cg = i<cg.size()?cg[i]:0;
    row.density=res.evaluated[i].optimization.physical_density;
    if (i<res.draft_rung_c_gap.size()) row.gap=res.draft_rung_c_gap[i];
    if (i<res.draft_rung_escalated.size()) row.escalated=res.draft_rung_escalated[i];
    out.total_cg+=row.cg; out.rungs.push_back(std::move(row)); }
  if (!res.evaluated.empty()) out.terminal=res.evaluated.back().optimization.physical_density;
  return out;
}
}  // namespace

int main(){
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e){ std::fprintf(stderr,"rules: %s\n", e.what()); return 1; }
  const Material material = fdm(); const double h=2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 8, 8, 3, 2, h);
  auto load = traction_loads(part, VoxelTag::Load, Vec3{0,0,-30});
  DesignBox box; box.min=Vec3{0,0,0}; box.max=Vec3{8*h*2.0,3*h*2.0,8*h*2.0};
  const std::vector<double> ladder = {0.50, 0.35, 0.24};
  auto R=[&](bool d,double l,double e){ return run(d,l,e,part,bcs,load,rules,material,box,ladder); };

  std::printf("\n########## WARM-START INHERITANCE ON (production loadcase posture) ##########\n");
  RunOut T = R(false, 0, 1e30);
  std::printf("[tight+inherit] total_cg=%lld\n", T.total_cg);

  auto report = [&](const char* tag, const RunOut& m){
    ClassDiff term = class_diff(T.terminal, m.terminal);
    const double ratio = m.total_cg>0 ? double(T.total_cg)/double(m.total_cg) : 0.0;
    std::printf("[%s] total_cg=%lld (%.2fx)  TERMINAL flip-frac vs tight = %.4f (%lld/%lld)\n",
                tag, m.total_cg, ratio, term.frac, term.flips, term.ref_solid);
    for (std::size_t i=0;i<m.rungs.size();++i){
      ClassDiff rc = class_diff(T.rungs[i].density, m.rungs[i].density);
      std::printf("      r%zu vf=%.2f cg=%lld gap=%.4f %s flip-vs-tight=%.4f\n", i,
                  m.rungs[i].vf, m.rungs[i].cg, m.rungs[i].gap,
                  m.rungs[i].escalated?"[ESC]":"     ", rc.frac);
    }
    std::fflush(stdout);
  };

  std::printf("\n--- production tolerance (loose 1e-3), escalation OFF ---\n");
  report("draft 1e-3 noesc", R(true, 1e-3, 1e30));

  std::printf("\n--- AGGRESSIVE loose 5e-1, escalation OFF (does inheritance propagate divergence?) ---\n");
  RunOut aggNo = R(true, 5e-1, 1e30);
  report("draft 5e-1 noesc", aggNo);

  std::printf("\n--- AGGRESSIVE loose 5e-1, escalation ON gap<=0 (escalate EVERY rung) ---\n");
  report("draft 5e-1 esc-all", R(true, 5e-1, -1.0));

  std::printf("\n--- AGGRESSIVE loose 5e-1, escalation ON gap=0.02 (gap-triggered) ---\n");
  report("draft 5e-1 esc-gap", R(true, 5e-1, 0.02));

  std::printf("\n########## DONE ##########\n");
  return 0;
}
