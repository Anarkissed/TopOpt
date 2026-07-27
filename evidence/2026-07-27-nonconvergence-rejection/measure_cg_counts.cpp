#include "topopt/simp.hpp"
#include "topopt/analyze.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/voxel.hpp"
#include "topopt/fea.hpp"
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
static int solveCount(const VoxelGrid&g,const std::vector<DirichletBC>&bcs,const std::vector<NodalLoad>&loads,const std::vector<double>&dens,int cap){
  SimpParams p; p.youngs_modulus=3500; p.poisson=0.33; p.penalty=3.0; p.density_min=1e-3;
  try{ auto sc=simp_compliance(g,p,dens,bcs,loads,1e-8,cap,nullptr,nullptr,SolverKind::JacobiCG); return sc.cg.iterations; }
  catch(const SolverNonConvergence&e){ std::printf("  THREW nonconv iters=%d resid=%g\n",e.iterations,e.residual); return -1; }
}
int main(){
  std::vector<DirichletBC> bcs; VoxelGrid g=cantilever(bcs);
  std::vector<NodalLoad> loads;
  for(int k=0;k<g.nz;k++)for(int j=0;j<g.ny;j++) loads.push_back({fea_node_index(g,g.nx,j,k),2,-50.0});
  size_t n=(size_t)g.nx*g.ny*g.nz;
  std::vector<double> dense(n,0.6);
  // a very light / near-void design over the design region (keep fixture+load solid)
  std::vector<double> light(n,1e-3);
  for(int k=0;k<g.nz;k++)for(int j=0;j<g.ny;j++){light[g.index(0,j,k)]=1.0; light[g.index(g.nx-1,j,k)]=1.0;}
  std::printf("dense(0.6) cold cert count: %d\n", solveCount(g,bcs,loads,dense,2000000));
  std::printf("light(~void) cold cert count: %d\n", solveCount(g,bcs,loads,light,2000000));
  return 0;
}
