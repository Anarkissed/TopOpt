// Minimal deterministic reference run: ONE production minimize_plastic ladder on
// a tiny L-bracket. Exercises all four per-rung guards in minimize_plastic.cpp
// and both finalize/certification guards in simp.cpp. Prints a stable digest of
// per-rung iterations / compliance / vf / accepted + a checksum of each accepted
// rung's physical density, for byte-identity + CG-iteration comparison across
// libraries built with and without the -UNDEBUG fix.
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

static VoxelGrid l_bracket(std::vector<DirichletBC>& bcs,int arm,int span,int ny,int t,double h){
  VoxelGrid g; g.nx=span; g.ny=ny; g.nz=arm; g.spacing=h; g.origin=Vec3{0,0,0};
  g.tags.assign((std::size_t)span*ny*arm, VoxelTag::Empty);
  for(int k=0;k<arm;k++)for(int j=0;j<ny;j++)for(int i=0;i<span;i++)
    if(i<t||k<t) g.set_tag(i,j,k,VoxelTag::Interior);
  for(int j=0;j<ny;j++)for(int i=0;i<t;i++) g.set_tag(i,j,arm-1,VoxelTag::Fixture);
  bcs.clear();
  for(int b=0;b<=ny;b++)for(int a=0;a<=t;a++){int n=fea_node_index(g,a,b,arm);
    bcs.push_back({n,0,0.0});bcs.push_back({n,1,0.0});bcs.push_back({n,2,0.0});}
  for(int k=0;k<t;k++)for(int j=0;j<ny;j++) g.set_tag(span-1,j,k,VoxelTag::Load);
  return g;
}
static uint64_t digest(const std::vector<double>& v){ // FNV-1a over raw bytes
  uint64_t h=1469598103934665603ull; const unsigned char* p=(const unsigned char*)v.data();
  for(std::size_t i=0;i<v.size()*sizeof(double);i++){h^=p[i];h*=1099511628211ull;} return h;
}
int main(){
  SettingsRules rules=load_settings_rules_file(SETTINGS_RULES_PATH);
  Material m; m.youngs_modulus_mpa=3500; m.yield_strength_mpa=55; m.density_g_cm3=1.24;
  m.z_knockdown=0.55; m.poisson=0.33; m.family="fdm";
  std::vector<DirichletBC> bcs;
  VoxelGrid part=l_bracket(bcs,10,10,4,3,2.0);
  std::vector<NodalLoad> tip=traction_loads(part,VoxelTag::Load,Vec3{0,0,-30.0});
  MinimizePlasticOptions o; configure_production_options(o);
  o.volume_fraction_ladder=production_reduction_ladder();
  o.margin_stop=1.5; o.external_loads=tip; o.gravity=9810.0*1e-9;
  o.gravity_direction=Vec3{0,0,-1.0}; o.infill_percent=100.0; o.simp.cg_tolerance=1e-8;
  long long total_cg=0; std::vector<long long> rung_cg;
  o.on_iteration=[&](std::size_t rung,std::size_t,const SimpIterationObservation& ob){
    total_cg+=ob.cg_iterations;
    if(rung_cg.size()<=rung) rung_cg.resize(rung+1,0);
    rung_cg[rung]+=ob.cg_iterations;
  };
  MinimizePlasticResult res=minimize_plastic(part,m,"fdm",bcs,rules,o);
  std::printf("== REFERENCE RUN digest ==\n");
  std::printf("grid=%dx%dx%d solid=%zu  evaluated_rungs=%zu\n",part.nx,part.ny,part.nz,
              part.solid_count(),res.evaluated.size());
  for(std::size_t i=0;i<res.evaluated.size();i++){
    const auto& v=res.evaluated[i];
    std::printf("rung %zu: req_vf=%.4f compliance=%.10e accepted=%d infeasible=%d "
                "rung_cg=%lld density_fnv=%016llx\n",
                i, v.requested_volume_fraction, v.optimization.compliance,(int)v.accepted,
                (int)v.infeasible, i<rung_cg.size()?rung_cg[i]:-1,
                (unsigned long long)digest(v.optimization.physical_density));
  }
  std::printf("TOTAL_CG_ITERATIONS=%lld\n", total_cg);
  return 0;
}
