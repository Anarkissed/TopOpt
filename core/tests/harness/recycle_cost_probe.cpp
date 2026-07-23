// recycle_cost_probe.cpp — measurement harness (NOT a CI test) for handoff 133,
// bar (d): the PER-ITERATION cost of the Krylov recycling correction, as a
// function of k.
//
// WHY THIS EXISTS SEPARATELY from recycle_probe. The iteration-count tables are
// the deterministic claim, but an iteration cut is only a real saving if the
// iterations still cost what they used to. The additive correction streams
// (8k + 24)*n bytes EVERY CG iteration, which is not negligible against a
// MATRIX-FREE matvec — that matvec is gather-bound (handoff 112: ~35% of STREAM),
// i.e. cheap per DOF, so the deflation overhead that is single-digit-percent in
// the assembled-matrix literature is ~90% here at k=16. This probe measures that
// ratio so the NET column of the handoff can charge it.
//
// WHAT IT REPORTS. For k in {0, 4, 8, 16, 24} on a solid grid: the CG iteration
// count (deterministic) and the wall time PER ITERATION, as a ratio against k=0.
// The ratio is taken from back-to-back interleaved runs in the SAME process and
// two repeats, so thermal drift moves both terms together — it is a RATIO of
// medians, never an absolute wall-clock claim (handoff 132's protocol). The basis
// is warmed with two solves before the timed one, so the timed solve is a
// steady-state recycled solve, not the bootstrap.
//
// Build + run:
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/opt/eigen/include/eigen3 \
//     tests/harness/recycle_cost_probe.cpp build/libtopopt.a -o recycle_cost_probe
//   ./recycle_cost_probe 48      # grid edge; 48^3 -> ndof 352,947
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"
using namespace topopt;
int main(int argc, char** argv) {
  const int N = argc > 1 ? std::atoi(argv[1]) : 48;
  VoxelGrid g; g.nx=N; g.ny=N; g.nz=N; g.spacing=1.0; g.origin=Vec3{0,0,0};
  g.tags.assign((std::size_t)N*N*N, VoxelTag::Interior);
  std::vector<DirichletBC> bcs; std::vector<NodalLoad> loads;
  for (int b=0;b<=N;++b) for(int a=0;a<=N;++a){int nd=fea_node_index(g,a,b,0);
    bcs.push_back({nd,0,0.0});bcs.push_back({nd,1,0.0});bcs.push_back({nd,2,0.0});}
  for (int b=0;b<=N/8;++b) for(int a=0;a<=N/8;++a)
    loads.push_back({fea_node_index(g,a,b,N),2,-1.0});
  std::vector<double> e(g.voxel_count(), 3500.0);
  auto timed=[&](int k)->std::pair<double,int>{
    fea_set_krylov_recycling(k>0); fea_set_krylov_recycle_dim(k>0?k:16);
    fea_reset_krylov_recycle_space();
    // warm the basis
    CgInfo info; for(int s=0;s<2;++s) fea_solve_cg_matfree(g,e,0.33,bcs,loads,1e-8,200000,&info);
    auto t0=std::chrono::steady_clock::now();
    fea_solve_cg_matfree(g,e,0.33,bcs,loads,1e-8,200000,&info);
    auto t1=std::chrono::steady_clock::now();
    fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
    return {std::chrono::duration<double>(t1-t0).count(), info.iterations};
  };
  std::printf("grid %d^3  ndof=%d\n", N, 3*fea_node_count(g));
  double base_per_it = 0.0;
  for (int rep=0; rep<2; ++rep)
    for (int k : {0,4,8,16,24}) {
      auto r = timed(k);
      const double per_it = r.first / std::max(1, r.second);
      if (k==0 && rep==1) base_per_it = per_it;
      std::printf("  rep%d k=%2d: iters=%5d wall=%.3fs  per_iter=%.4f ms  ratio_vs_k0=%.3f\n",
                  rep, k, r.second, r.first, per_it*1e3,
                  base_per_it>0?per_it/base_per_it:0.0);
    }
  return 0;
}
