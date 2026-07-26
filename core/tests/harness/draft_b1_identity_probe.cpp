// draft_b1_identity_probe.cpp — B1 proof for handoff 2026-07-25-draft-quality.
// Runs a FIXED, deterministic production minimize_plastic with draft_quality LEFT
// AT ITS DEFAULT (off — this file never mentions the draft fields, so it also
// compiles UNCHANGED against pristine origin/main), and prints a checksum of the
// full result: terminal + per-rung physical density, per-rung compliance, margins,
// accept flags, and total iterations. Run it on the draft branch and on stashed
// origin/main; identical checksums prove draft-OFF is byte-for-byte main (B1).
// (Both boxed and no-box ladders are exercised, since draft touches both.)

#include <cstdio>
#include <cstdint>
#include <vector>
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"
using namespace topopt;

namespace {
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

// FNV-1a over the run's meaningful bytes.
struct Fnv { std::uint64_t h=1469598103934665603ull;
  void b(const void* p, std::size_t n){ auto* c=(const unsigned char*)p;
    for (std::size_t i=0;i<n;++i){ h^=c[i]; h*=1099511628211ull; } }
  void d(double v){ b(&v,sizeof v); } void i(long long v){ b(&v,sizeof v); } };

void hash_run(Fnv& f, bool with_box, const SettingsRules& rules) {
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, 8, 8, 3, 2, 2.0);
  auto load = traction_loads(part, VoxelTag::Load, Vec3{0,0,-30});
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = {0.50, 0.35, 0.24};
  o.margin_stop = 0.0;
  o.external_loads = load;
  o.gravity = 9810.0*1e-9; o.gravity_direction = Vec3{0,0,-1}; o.infill_percent = 100.0;
  if (with_box) { DesignBox bx; bx.min=Vec3{0,0,0}; bx.max=Vec3{8*2.0*2.0,3*2.0*2.0,8*2.0*2.0}; o.design_box=bx; }
  auto r = minimize_plastic(part, fdm(), "fdm", bcs, rules, o);
  f.i((long long)r.evaluated.size());
  for (auto& v : r.evaluated) {
    f.d(v.optimization.compliance); f.d(v.report.margin.worst_case);
    f.i(v.accepted?1:0); f.i(v.optimization.iterations);
    for (double x : v.optimization.physical_density) f.d(x);
  }
}
}  // namespace

int main() {
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e){ std::fprintf(stderr,"rules: %s\n", e.what()); return 1; }
  Fnv f;
  hash_run(f, false, rules);
  hash_run(f, true, rules);
  std::printf("B1_CHECKSUM=%016llx\n", (unsigned long long)f.h);
  return 0;
}
