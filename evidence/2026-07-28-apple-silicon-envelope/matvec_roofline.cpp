// H2 — the PRODUCTION matrix-free operator's achieved bandwidth and FLOP rate.
//
// This drives the EXACT production kernel — `fea_detail::MatfreeReduced::apply_kgg`
// (the element-by-element hex8 matvec matfree.cpp uses inside every CG/V-cycle
// iteration) — at production grid sizes, swept across thread counts, and reports
// GB/s (issued + compulsory byte models) and GFLOP/s against the M2 Pro's 200 GB/s
// theoretical peak and the H1-measured STREAM ceiling. No production source is
// modified; this harness links the same object files CMake compiles.
//
// The point of the exercise (H2): if the operator sits far below the memory
// ceiling, closing THAT gap is a cheaper win than any new algorithm — and it must
// be said plainly. Handoff 113 measured ~45 GB/s issued (=23% of 200) on this box;
// this re-measures on today's thermal state and adds the 128^3 production target.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"
#include "fea_matfree.hpp"  // internal: fea_detail::MatfreeReduced, mf_build_reduced

// solid_count() lives in voxelize.cpp, which pulls geometry deps this harness does
// not need. It is a trivial non-Empty count; define it here so we need not link
// voxelize.o. Byte-identical to the production definition (voxelize.cpp:30). Only
// this TU (matfree.o / assembly.o reference it) sees the symbol — no ODR clash
// because voxelize.o is not in the link.
namespace topopt {
std::size_t VoxelGrid::solid_count() const {
  std::size_t n = 0;
  for (VoxelTag t : tags)
    if (t != VoxelTag::Empty) ++n;
  return n;
}
}  // namespace topopt

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using clk = std::chrono::steady_clock;

namespace {

// Node id of corner (a,b,c) on an nx*ny*nz grid: (c*(ny+1)+b)*(nx+1)+a.
inline int node_id(int a, int b, int c, int nx, int ny) {
  return (c * (ny + 1) + b) * (nx + 1) + a;
}

// A fully-solid block, fixed on the i=0 face, unit load pulling the far (i=nx)
// face in +y — a well-posed elasticity system whose reduced operator is exactly
// what a design-box solve applies thousands of times.
VoxelGrid solid_block(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = 1.0;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

}  // namespace

int main(int argc, char** argv) {
  int nx = 96, ny = 96, nz = 96, reps = 60;
  if (argc > 3) { nx = std::atoi(argv[1]); ny = std::atoi(argv[2]); nz = std::atoi(argv[3]); }
  if (argc > 4) reps = std::atoi(argv[4]);

  VoxelGrid g = solid_block(nx, ny, nz);
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      for (int comp = 0; comp < 3; ++comp)
        bcs.push_back({node_id(0, b, c, nx, ny), comp, 0.0});
  std::vector<NodalLoad> loads;
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      loads.push_back({node_id(nx, b, c, nx, ny), 1, 1.0});

  CgInfo info;
  topopt::fea_detail::MatfreeReduced m = topopt::fea_detail::mf_build_reduced(
      g, /*youngs*/ 1.0, /*poisson*/ 0.3, bcs, loads, /*elem_youngs*/ nullptr,
      "matvec_roofline", &info, /*active_mask*/ nullptr);

  const long ndof = m.ndof;
  const long ng = m.ng;
  const long nel = static_cast<long>(m.elems.size());
  const long ndof_active = ng;  // surviving free DOFs the CG actually iterates on

  std::printf("# H2 matrix-free operator roofline  grid %dx%dx%d\n", nx, ny, nz);
  std::printf("# ndof=%ld  reduced(free,kept)=%ld  solid elements=%ld  reps=%d (best-of)\n",
              ndof, ng, nel, reps);
  std::printf("# M2 Pro theoretical peak = 200 GB/s; H1 STREAM ceiling ~151 GB/s counted\n");
  std::printf("# FLOP/apply = elements * 1152 (24x24 mul+add); bytes bracketed issued..compulsory\n\n");

  // Byte models per apply (matching handoff 113):
  //  issued  = per element: gather 24 x + scatter-RMW 24 y (read+write) + 24 edof
  //            int + 1 factor double.  (double = 8, int = 4)
  //  compulsory = each full-length x read once + y written once (the fill+scatter+
  //            gather apply_kgg does over ndof) + element table streamed once.
  const double issued_bytes =
      static_cast<double>(nel) * (24.0 * 8 + 24.0 * 8 * 2 + 24.0 * 4 + 8);
  const double compulsory_bytes =
      static_cast<double>(ndof) * 8 * 2 +          // xfull read + yfull write
      static_cast<double>(nel) * (24.0 * 4 + 8) +  // element table (edof + factor)
      static_cast<double>(ng) * 8 * 2;             // reduced scatter + gather
  const double flop = static_cast<double>(nel) * 1152.0;

  std::vector<double> x(static_cast<std::size_t>(ng), 1.0);
  std::vector<double> y(static_cast<std::size_t>(ng), 0.0);

  const int threads[] = {1, 4, 6, 8, 10};
  std::printf("%-4s | %-10s %-10s %-10s | %-9s %-9s | %-9s\n", "thr",
              "s/matvec", "GB/s iss", "GB/s cmp", "%pk iss", "%pk cmp", "GFLOP/s");
  std::printf("-----+---------------------------------+---------------------+---------\n");
  for (int t : threads) {
    topopt::fea_set_matfree_threads(t);
    // Warm up (page-in scratch, spin up the pool) and defeat DCE.
    volatile double acc = 0.0;
    for (int w = 0; w < 3; ++w) { m.apply_kgg_raw(x.data(), y.data()); acc += y[0]; }
    double best = 1e300;
    for (int r = 0; r < reps; ++r) {
      const auto t0 = clk::now();
      m.apply_kgg_raw(x.data(), y.data());
      const auto t1 = clk::now();
      const double secs = std::chrono::duration<double>(t1 - t0).count();
      if (secs < best) best = secs;
      acc += y[r % ng];
    }
    (void)acc;
    const double gbs_iss = issued_bytes / best / 1e9;
    const double gbs_cmp = compulsory_bytes / best / 1e9;
    const double gflops = flop / best / 1e9;
    std::printf("%-4d | %-10.5f %-10.1f %-10.1f | %-9.1f %-9.1f | %-9.1f\n",
                t, best, gbs_iss, gbs_cmp, 100.0 * gbs_iss / 200.0,
                100.0 * gbs_cmp / 200.0, gflops);
  }
  std::printf("\n# %%pk = %% of 200 GB/s theoretical peak. issued brackets the gather/scatter\n");
  std::printf("# traffic; compulsory the minimum stream. True DRAM traffic sits between.\n");
  return 0;
}
