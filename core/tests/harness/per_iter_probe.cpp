// per_iter_probe.cpp — per-iteration fragmentation bisect (NOT a CI test).
//
// ONE rung (vf 0.26, the lightest — where fragmentation shows) on a small
// PROTRUDING-tab cantilever, plateau vs cap-60, printing PER ITERATION:
//   iter  change=max|drho|  compliance  #components  largest%  SAME-COMP
//   load-face min-density  neck min-density  BREAK@ (first iter tab disconnects)
//
// Also resolves STEP 0 with counts: the anchor/load pad's FrozenSolid voxel
// count AT the load face, and whether any loaded DOF is a void (throw) DOF.
//
// argv[1] = plateau window (10 = plateau; 0 = cap-60). argv[2] = cap (window==0).

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <queue>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {
constexpr double kIso = 0.5;

struct Geom {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignMask pad;
  std::vector<std::size_t> load_vox, fix_vox, neck_vox;
  int lblock = 0, pad_load_face = 0;
};

// Block [0,lblock) full section; protruding tw x tw tab [lblock,nx). Load on the
// tab far face; anchor on i=0. Pad = pad_depth solid layers behind each face.
Geom make_geom(int nx, int ny, int nz, double h, int tw, int td, double force,
               int pad_depth) {
  Geom G;
  VoxelGrid& g = G.grid;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h; g.origin = Vec3{0,0,0};
  g.tags.assign(static_cast<std::size_t>(nx)*ny*nz, VoxelTag::Empty);
  const int lblock = nx - td;
  G.lblock = lblock;
  const int j0 = (ny-tw)/2, k0 = (nz-tw)/2;
  for (int i=0;i<lblock;++i) for (int k=0;k<nz;++k) for (int j=0;j<ny;++j)
    g.set_tag(i,j,k,VoxelTag::Interior);
  for (int i=lblock;i<nx;++i) for (int k=k0;k<k0+tw;++k) for (int j=j0;j<j0+tw;++j)
    g.set_tag(i,j,k,VoxelTag::Interior);
  for (int k=0;k<nz;++k) for (int j=0;j<ny;++j) {
    g.set_tag(0,j,k,VoxelTag::Fixture); G.fix_vox.push_back(g.index(0,j,k));
  }
  for (int c=0;c<=nz;++c) for (int b=0;b<=ny;++b) {
    const int n = fea_node_index(g,0,b,c);
    G.bcs.push_back({n,0,0.0}); G.bcs.push_back({n,1,0.0}); G.bcs.push_back({n,2,0.0});
  }
  const bool self_weight = std::getenv("TOPOPT_SELFWEIGHT") != nullptr;
  for (int i=nx-td;i<nx;++i) for (int k=k0;k<k0+tw;++k) for (int j=j0;j<j0+tw;++j) {
    // For the self-weight run the tab is a plain design variable (NOT tagged Load,
    // NOT frozen), exactly as a pure self-weight optimize would see it; for the
    // external run it is the loaded, retained tab.
    if (self_weight) { G.load_vox.push_back(g.index(i,j,k)); }  // track, don't tag
    else { g.set_tag(i,j,k,VoxelTag::Load); G.load_vox.push_back(g.index(i,j,k)); }
  }
  // Neck = the tab patch layer adjacent to the block + the block's last full
  // layer over the patch (where a carve would sever the tab).
  for (int k=k0;k<k0+tw;++k) for (int j=j0;j<j0+tw;++j) {
    G.neck_vox.push_back(g.index(lblock-1,j,k));
    G.neck_vox.push_back(g.index(lblock,j,k));
  }
  Vec3 dir{0,0,-1};
  if (const char* d = std::getenv("TOPOPT_LOADDIR")) {
    std::string s=d;
    if (s=="x") dir=Vec3{1,0,0}; else if (s=="-x") dir=Vec3{-1,0,0};
    else if (s=="y") dir=Vec3{0,1,0}; else if (s=="z") dir=Vec3{0,0,1};
    else if (s=="xz") dir=Vec3{0.707,0,-0.707};
  }
  if (self_weight)
    G.loads = self_weight_loads(g, 1.24e-3, 9810.0*1e-9, Vec3{0,0,-1});
  else
    G.loads = traction_loads(g, VoxelTag::Load, Vec3{force*dir.x,force*dir.y,force*dir.z});
  // Pad (anchor always; load-face pad only on the external path — self-weight has
  // no retained load face, so its tab gets NO freeze, exactly like the bridge).
  G.pad = make_active_mask(g);
  for (int d=0;d<pad_depth;++d) for (int k=0;k<nz;++k) for (int j=0;j<ny;++j)
    G.pad[g.index(d,j,k)] = MaskValue::FrozenSolid;
  if (!self_weight)
    for (int d=0;d<pad_depth;++d) for (int k=k0;k<k0+tw;++k) for (int j=j0;j<j0+tw;++j) {
      const int i = nx-1-d;
      if (i>=0 && g.solid(i,j,k)) { G.pad[g.index(i,j,k)] = MaskValue::FrozenSolid; ++G.pad_load_face; }
    }
  return G;
}

struct Comp { std::vector<int> id; std::vector<std::size_t> size; };
Comp connected(const VoxelGrid& g, const std::vector<double>& rho) {
  Comp C; C.id.assign(g.voxel_count(), -1);
  auto on=[&](int i,int j,int k){return rho[g.index(i,j,k)]>kIso;};
  int nx=g.nx,ny=g.ny,nz=g.nz,next=0;
  for (int k=0;k<nz;++k) for (int j=0;j<ny;++j) for (int i=0;i<nx;++i) {
    if (!on(i,j,k)||C.id[g.index(i,j,k)]>=0) continue;
    std::size_t sz=0; std::queue<std::array<int,3>> q; q.push({i,j,k});
    C.id[g.index(i,j,k)]=next;
    while(!q.empty()){auto c=q.front();q.pop();++sz;
      const int d[6][3]={{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
      for(auto&o:d){int ni=c[0]+o[0],nj=c[1]+o[1],nk=c[2]+o[2];
        if(ni<0||nj<0||nk<0||ni>=nx||nj>=ny||nk>=nz)continue;
        if(!on(ni,nj,nk)||C.id[g.index(ni,nj,nk)]>=0)continue;
        C.id[g.index(ni,nj,nk)]=next; q.push({ni,nj,nk});}}
    C.size.push_back(sz); ++next;
  }
  return C;
}

int comp_of(const Comp& C, const std::vector<std::size_t>& set){
  std::vector<std::size_t> t(C.size.size(),0);
  for(std::size_t x:set) if(C.id[x]>=0) t[C.id[x]]++;
  int b=-1; std::size_t bn=0;
  for(std::size_t c=0;c<t.size();++c) if(t[c]>bn){bn=t[c];b=(int)c;}
  return b;
}
}  // namespace

int main(int argc, char** argv) {
  const int window = argc>1?std::atoi(argv[1]):10;
  const int cap = argc>2?std::atoi(argv[2]):60;
  const char* se = std::getenv("TOPOPT_SOLVER");
  const bool mf = !(se && std::string(se)=="jc");

  // Protruding-tab cantilever; grid configurable via env (default 32x10x10).
  auto envi=[&](const char* k,int d){const char* v=std::getenv(k);return v?std::atoi(v):d;};
  const int NX=envi("PX",32), NY=envi("PY",10), NZ=envi("PZ",10);
  const int TW=envi("PTW",3), TD=envi("PTD",2);
  const double h = 8.2;  // physical ~ device; rmin floors at 1.5 vox regardless
  const int pad_depth = 3;
  Geom G = make_geom(NX,NY,NZ,h,TW,TD,100.0,pad_depth);
  const VoxelGrid& g = G.grid;
  const double rmin = physical_filter_radius(2.5, h);

  // STEP 0 numbers.
  const bool self_weight = std::getenv("TOPOPT_SELFWEIGHT") != nullptr;
  std::size_t load_frozen_by_pad = 0;
  std::size_t tab_tagged_load = 0;
  for (std::size_t idx : G.load_vox) {
    if (g.tags[idx]==VoxelTag::Load) ++tab_tagged_load;  // -> FrozenSolid (simp.cpp:949)
    if (G.pad[idx]==MaskValue::FrozenSolid) ++load_frozen_by_pad;
  }
  std::size_t pad_fs=0; for (auto v:G.pad) if (v==MaskValue::FrozenSolid) ++pad_fs;
  std::printf("== window=%d cap=%d  grid=%dx%dx%d solid=%zu  rmin=%.3f vox  solver=%s  LOAD=%s ==\n",
      window,cap,g.nx,g.ny,g.nz,g.solid_count(),rmin,mf?"matfree":"jacobi",
      self_weight?"SELF-WEIGHT (tab NOT tagged/frozen)":"external tip shear (tab tagged Load)");
  std::printf("[STEP0-pad] tab voxels=%zu  tagged Load(->FrozenSolid)=%zu  "
      "in mask_step_face load pad=%zu  |  total pad FrozenSolid=%zu (load-face pad layer=%d)\n",
      G.load_vox.size(), tab_tagged_load, load_frozen_by_pad, pad_fs, G.pad_load_face);

  SimpParams params; params.youngs_modulus=2000.0; params.poisson=0.35; params.penalty=3.0;

  SimpOptions opt;
  opt.volume_fraction=0.26; opt.filter_radius=rmin; opt.move=0.2;
  opt.updater=SimpUpdater::MMA;
  opt.solver = mf?SolverKind::MultigridCG_Matfree:SolverKind::JacobiCG;
  opt.cg_tolerance=1e-8;
  if (window>0){opt.max_iterations=200;opt.mma_plateau_window=window;
    opt.mma_plateau_tol=1e-3;opt.mma_plateau_min_drop=0.05;opt.change_tol=0.0;}
  else {opt.max_iterations=cap;opt.mma_plateau_window=0;opt.change_tol=0.0;}

  // Per-iteration instrumentation: progress records (iter,compliance,change);
  // keyframe (stride 1) gives the physical density -> connectivity + load/neck.
  int last_iter=-1; double p_comp=0,p_change=0; int p_iter=0;
  int break_iter=-1;
  opt.progress=[&](int it,double c,double ch){p_iter=it;p_comp=c;p_change=ch;};
  opt.keyframe_stride=1;
  opt.keyframe=[&](const std::vector<double>& rho){
    if (p_iter==last_iter) return;  // skip the post-loop final keyframe dup
    last_iter=p_iter;
    Comp C=connected(g,rho);
    std::size_t printed=0,largest=0; int lid=-1;
    for(double d:rho) if(d>kIso)++printed;
    for(std::size_t c=0;c<C.size.size();++c) if(C.size[c]>largest){largest=C.size[c];lid=(int)c;}
    int lc=comp_of(C,G.load_vox), fc=comp_of(C,G.fix_vox);
    const bool same=(lc>=0&&lc==fc);
    double lmin=1e9; for(std::size_t x:G.load_vox) lmin=std::min(lmin,rho[x]);
    double nmin=1e9; for(std::size_t x:G.neck_vox) nmin=std::min(nmin,rho[x]);
    if(!same && break_iter<0) break_iter=p_iter;
    std::printf("it=%3d chg=%.4f C=%.5e ncomp=%2zu largest=%5.1f%% SAME=%-3s "
        "loadmin=%.3f neckmin=%.3f%s\n",
        p_iter,p_change,p_comp,C.size.size(),
        printed?100.0*largest/printed:0.0, same?"YES":"NO",
        lmin,nmin, (!same&&p_iter==break_iter)?"  <== TAB DISCONNECTS":"");
  };

  SimpOptimizeResult r=simp_optimize(g,params,G.bcs,G.loads,opt,G.pad);
  // Final field connectivity + STEP0 throw check.
  Comp C=connected(g,r.physical_density);
  std::size_t largest=0; for(auto s:C.size) largest=std::max(largest,s);
  int lc=comp_of(C,G.load_vox), fc=comp_of(C,G.fix_vox);
  double lmin=1e9,amin=1e9; std::size_t empty_load=0;
  for(std::size_t x:G.load_vox) lmin=std::min(lmin,r.physical_density[x]);
  // "solid" DOF check: every Active/Load voxel keeps a hex element (tag!=Empty);
  // min density over ALL non-empty voxels shows elements never vanish -> the
  // topological void-DOF gate cannot fire on a loaded DOF.
  for(std::size_t idx=0; idx<g.voxel_count(); ++idx){
    if(g.tags[idx]==VoxelTag::Empty) continue;
    amin=std::min(amin,r.physical_density[idx]);
  }
  for(std::size_t x:G.load_vox) if(g.tags[x]==VoxelTag::Empty) ++empty_load;
  std::printf("\n[FINAL w%d] iters=%d converged=%d C=%.5e  ncomp=%zu largest=%zu "
      "SAME-COMPONENT=%s  BREAK@iter=%d\n",
      window,r.iterations,(int)r.converged,r.compliance,C.size.size(),largest,
      (lc>=0&&lc==fc)?"YES":"NO", break_iter);
  std::printf("[STEP0-throw w%d] load-face min density=%.4f (pinned solid=%s)  "
      "min density over ALL non-Empty voxels=%.3e (>0 => every loaded DOF has a "
      "stiff element)  loaded voxels that are Empty(void)=%zu  => throw fires=%s\n",
      window, lmin, lmin>0.999?"YES":"NO", amin, empty_load,
      empty_load>0?"YES":"NO");
  return 0;
}
