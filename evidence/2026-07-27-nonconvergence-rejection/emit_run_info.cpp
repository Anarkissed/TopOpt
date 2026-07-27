#include "topopt/simp.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/voxel.hpp"
#include "topopt/fea.hpp"
#include "topopt/settings.hpp"
#include "topopt/observability.hpp"
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
int main(int argc,char**argv){
  std::vector<DirichletBC> bcs; VoxelGrid g=cantilever(bcs);
  MinimizePlasticOptions o; o.margin_stop=0.0; o.gravity=9810; o.gravity_direction=Vec3{0,0,-1};
  o.warm_start_inherit=true; o.updater=SimpUpdater::MMA;
  o.simp.filter_radius=1.5; o.simp.move=0.2; o.simp.max_iterations=40; o.simp.change_tol=0.0;
  o.simp.cg_tolerance=1e-8; o.simp.cg_max_iterations=800; o.simp.infeasible_window=0;
  for(int k=0;k<g.nz;k++)for(int j=0;j<g.ny;j++)o.external_loads.push_back({fea_node_index(g,g.nx,j,k),2,-50.0});
  o.volume_fraction_ladder={0.6,0.02};
  SettingsRules rules = load_settings_rules_file("core/src/settings/rules.json");
  auto r=minimize_plastic(g,mat(),"PLA",bcs,rules,o);
  RunInfo info;
  info.rung_non_convergent.assign(r.rung_non_convergent.begin(),r.rung_non_convergent.end());
  info.rung_non_convergent_iteration.assign(r.rung_non_convergent_iteration.begin(),r.rung_non_convergent_iteration.end());
  info.rung_non_convergent_residual.assign(r.rung_non_convergent_residual.begin(),r.rung_non_convergent_residual.end());
  info.rung_infeasible.assign(r.rung_infeasible.begin(),r.rung_infeasible.end());
  write_run_info(argv[1], info);
  return 0;
}
