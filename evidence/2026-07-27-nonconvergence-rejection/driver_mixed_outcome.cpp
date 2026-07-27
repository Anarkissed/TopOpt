#include "topopt/simp.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/voxel.hpp"
#include "topopt/fea.hpp"
#include "topopt/settings.hpp"
#include <cstdio>
#include <vector>
using namespace topopt;
static VoxelGrid cantilever(std::vector<DirichletBC>& bcs){
  const int nx=24,ny=5,nz=6; VoxelGrid g; g.nx=nx;g.ny=ny;g.nz=nz; g.spacing=2.0; g.origin=Vec3{0,0,0};
  g.tags.assign((size_t)nx*ny*nz, VoxelTag::Interior);
  for(int k=0;k<nz;k++)for(int j=0;j<ny;j++){g.set_tag(0,j,k,VoxelTag::Fixture);g.set_tag(nx-1,j,k,VoxelTag::Load);}
  bcs.clear();
  for(int c=0;c<=nz;c++)for(int b=0;b<=ny;b++){int n=fea_node_index(g,0,b,c);bcs.push_back({n,0,0.0});bcs.push_back({n,1,0.0});bcs.push_back({n,2,0.0});}
  return g;
}
static Material mat(){Material m;m.youngs_modulus_mpa=3500;m.yield_strength_mpa=55;m.density_g_cm3=1.24;m.z_knockdown=0.55;m.poisson=0.33;m.family="fdm";return m;}
int main(){
  std::vector<DirichletBC> bcs; VoxelGrid g=cantilever(bcs);
  MinimizePlasticOptions o; o.margin_stop=0.0; o.gravity=9810; o.gravity_direction=Vec3{0,0,-1};
  o.warm_start_inherit=true; o.updater=SimpUpdater::MMA;
  o.simp.filter_radius=1.5; o.simp.move=0.2; o.simp.max_iterations=40; o.simp.change_tol=0.0;
  o.simp.cg_tolerance=1e-8; o.simp.cg_max_iterations=800; o.simp.infeasible_window=0;
  for(int k=0;k<g.nz;k++)for(int j=0;j<g.ny;j++)o.external_loads.push_back({fea_node_index(g,g.nx,j,k),2,-50.0});
  o.volume_fraction_ladder={0.6,0.02};
  SettingsRules rules = load_settings_rules_file("core/src/settings/rules.json");
  auto r=minimize_plastic(g,mat(),"PLA",bcs,rules,o);
  std::printf("evaluated=%zu cancelled=%d stopped_on_margin=%d\n",r.evaluated.size(),r.cancelled,r.stopped_on_margin);
  for(size_t i=0;i<r.evaluated.size();i++){auto&v=r.evaluated[i];
    std::printf(" rung %zu vf=%.2f accepted=%d infeasible=%d nonconv=%d reason='%s' meshtris=%zu\n",
      i,v.requested_volume_fraction,v.accepted,v.infeasible,v.non_convergent,
      v.report.rejection_reason.c_str(), v.mesh().triangles.size());
    std::printf("    opt.non_convergent(traj)=%d opt.iterations=%d\n", v.optimization.non_convergent, v.optimization.iterations);
  }
  std::printf("rung_non_convergent=[");for(char c:r.rung_non_convergent)std::printf("%d ",c);std::printf("]\n");
  std::printf("nc_iter=[");for(int c:r.rung_non_convergent_iteration)std::printf("%d ",c);std::printf("]\n");
  std::printf("nc_resid=[");for(double c:r.rung_non_convergent_residual)std::printf("%g ",c);std::printf("]\n");
  return 0;
}
