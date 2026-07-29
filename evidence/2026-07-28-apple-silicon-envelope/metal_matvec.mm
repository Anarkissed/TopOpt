// H4 — a Metal FP32 matvec PROTOTYPE: just the operator application (y = K x over
// the full stiffness), NOT a solver. It answers two questions the brief poses:
//   (a) throughput of an FP32 GPU element-apply vs the CPU FP64 apply (H2), and
//   (b) whether the FP32 precision makes it usable for anything, given that the
//       project's FP32 iterative-refinement attempt already failed on accuracy.
//
// FAITHFULNESS. The GPU kernel is the same element-by-element hex8 apply as
// matfree.cpp, dispatched one COLOUR at a time over the production 8-colour
// (2x2x2) partition — so within a dispatch no two elements write the same node and
// the plain (non-atomic) scatter is race-free, exactly as the CPU path. The element
// table (edof + factor), the colour offsets and Ke come from the production
// `mf_build_reduced`, reused verbatim — no reimplementation. Correctness is checked
// against the CPU FP64 apply (`mf_apply_full`) and the CPU FP32 apply
// (`mf_apply_full_f32`) on the same input.
//
// Metal + Foundation are system frameworks (bar B3). Nothing here touches
// libtopopt or production; this is an evidence-only prototype under `accel/`-free
// scratch, and (per handoff 113 / ARCHITECTURE §8) no Metal code is added to the
// tree beyond this measurement harness.
//
// Build: c++ -O3 -std=c++17 -fobjc-arc metal_matvec.mm -framework Metal -framework Foundation

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"
#include "fea_matfree.hpp"

namespace topopt {
std::size_t VoxelGrid::solid_count() const {  // see matvec_roofline.cpp
  std::size_t n = 0;
  for (VoxelTag t : tags)
    if (t != VoxelTag::Empty) ++n;
  return n;
}
}  // namespace topopt

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::Hex8Stiffness;
using topopt::NodalLoad;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::fea_detail::MfElem;
using clk = std::chrono::steady_clock;

static const char* kKernelSrc = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void element_apply(
    device const float* x       [[buffer(0)]],
    device float*       y       [[buffer(1)]],
    device const int*   edof    [[buffer(2)]],   // nel * 24 global DOFs
    device const float* factor  [[buffer(3)]],   // nel
    constant float*     KeCM    [[buffer(4)]],   // 576, column-major (KeCM[c*24+r])
    constant uint&      lo      [[buffer(5)]],
    constant uint&      hi      [[buffer(6)]],
    uint gid [[thread_position_in_grid]])
{
    uint e = lo + gid;
    if (e >= hi) return;
    float ul[24];
    float res[24];
    for (int r = 0; r < 24; ++r) { ul[r] = x[edof[e*24 + r]]; res[r] = 0.0f; }
    for (int c = 0; c < 24; ++c) {
        float w = ul[c];
        for (int r = 0; r < 24; ++r) res[r] += w * KeCM[c*24 + r];  // mul+add
    }
    float f = factor[e];
    for (int r = 0; r < 24; ++r) y[edof[e*24 + r]] += f * res[r];   // race-free in colour
}
)METAL";

namespace {

int node_id(int a, int b, int c, int nx, int ny) {
  return (c * (ny + 1) + b) * (nx + 1) + a;
}

double relnorm(const std::vector<double>& a, const std::vector<float>& b) {
  double num = 0, den = 0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const double d = a[i] - static_cast<double>(b[i]);
    num += d * d;
    den += a[i] * a[i];
  }
  return std::sqrt(num / den);
}

}  // namespace

int main(int argc, char** argv) {
  int nx = 96, ny = 96, nz = 96, reps = 100;
  if (argc > 3) { nx = std::atoi(argv[1]); ny = std::atoi(argv[2]); nz = std::atoi(argv[3]); }
  if (argc > 4) reps = std::atoi(argv[4]);

  // --- Build the production element table via the real core code -----------
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = 1.0;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
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
  auto m = topopt::fea_detail::mf_build_reduced(
      g, 1.0, 0.3, bcs, loads, nullptr, "metal_matvec", &info, nullptr);

  const int ndof = m.ndof;
  const long nel = static_cast<long>(m.elems.size());
  const Hex8Stiffness& Ke = m.Ke;

  // Flatten the element table for the GPU: edof[nel*24] (int) + factor[nel] (fp32);
  // KeCM column-major (KeCM[c*24+r] = Ke(r,c)), matching build_ke_colmajor.
  std::vector<int> edof(static_cast<std::size_t>(nel) * 24);
  std::vector<float> factor(static_cast<std::size_t>(nel));
  for (long e = 0; e < nel; ++e) {
    factor[e] = static_cast<float>(m.elems[e].factor);
    for (int r = 0; r < 24; ++r) edof[e * 24 + r] = m.elems[e].edof[r];
  }
  std::vector<float> KeCM(576);
  for (int r = 0; r < 24; ++r)
    for (int c = 0; c < 24; ++c) KeCM[c * 24 + r] = static_cast<float>(Ke(r, c));

  // Random full-length input.
  std::mt19937_64 rng(7);
  std::uniform_real_distribution<double> uni(-1.0, 1.0);
  std::vector<double> x64(static_cast<std::size_t>(ndof));
  std::vector<float> x32(static_cast<std::size_t>(ndof));
  for (int i = 0; i < ndof; ++i) { x64[i] = uni(rng); x32[i] = static_cast<float>(x64[i]); }

  // --- CPU references -------------------------------------------------------
  std::vector<double> y64(static_cast<std::size_t>(ndof), 0.0);
  std::vector<float> yc32(static_cast<std::size_t>(ndof), 0.0f);
  topopt::fea_set_matfree_threads(6);
  topopt::fea_detail::mf_apply_full(m.elems, m.color_offsets, Ke, x64, y64);
  topopt::fea_detail::mf_apply_full_f32(m.elems, m.color_offsets, Ke, x32, yc32);

  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { std::fprintf(stderr, "no Metal device\n"); return 1; }
    NSError* err = nil;
    id<MTLLibrary> libm = [dev newLibraryWithSource:[NSString stringWithUTF8String:kKernelSrc]
                                            options:nil error:&err];
    if (!libm) { std::fprintf(stderr, "MSL compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> pso =
        [dev newComputePipelineStateWithFunction:[libm newFunctionWithName:@"element_apply"] error:&err];
    if (!pso) { std::fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];

    auto buf = [&](const void* p, NSUInteger bytes) {
      return [dev newBufferWithBytes:p length:bytes options:MTLResourceStorageModeShared];
    };
    id<MTLBuffer> bx = buf(x32.data(), x32.size() * sizeof(float));
    id<MTLBuffer> by = [dev newBufferWithLength:x32.size() * sizeof(float)
                                        options:MTLResourceStorageModeShared];
    id<MTLBuffer> bedof = buf(edof.data(), edof.size() * sizeof(int));
    id<MTLBuffer> bfac = buf(factor.data(), factor.size() * sizeof(float));
    id<MTLBuffer> bke = buf(KeCM.data(), KeCM.size() * sizeof(float));

    const std::vector<int>& co = m.color_offsets;  // 9 delimiters

    auto run_apply = [&]() {
      id<MTLCommandBuffer> cb = [q commandBuffer];
      // y = 0
      id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
      [blit fillBuffer:by range:NSMakeRange(0, by.length) value:0];
      [blit endEncoding];
      // one dispatch per colour (race-free scatter within a colour)
      for (int col = 0; col < 8; ++col) {
        uint lo = static_cast<uint>(co[col]);
        uint hi = static_cast<uint>(co[col + 1]);
        if (hi <= lo) continue;
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:bx offset:0 atIndex:0];
        [enc setBuffer:by offset:0 atIndex:1];
        [enc setBuffer:bedof offset:0 atIndex:2];
        [enc setBuffer:bfac offset:0 atIndex:3];
        [enc setBuffer:bke offset:0 atIndex:4];
        [enc setBytes:&lo length:sizeof(uint) atIndex:5];
        [enc setBytes:&hi length:sizeof(uint) atIndex:6];
        NSUInteger tpg = pso.maxTotalThreadsPerThreadgroup;
        if (tpg > 256) tpg = 256;
        [enc dispatchThreads:MTLSizeMake(hi - lo, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(tpg, 1, 1)];
        [enc endEncoding];
      }
      [cb commit];
      [cb waitUntilCompleted];
    };

    run_apply();  // warm (compile pipelines, page-in)
    const float* yg = static_cast<const float*>(by.contents);
    std::vector<float> yg32(yg, yg + ndof);

    double best = 1e300;
    for (int r = 0; r < reps; ++r) {
      const auto t0 = clk::now();
      run_apply();
      const auto t1 = clk::now();
      best = std::min(best, std::chrono::duration<double>(t1 - t0).count());
    }

    // Byte / FLOP models identical to H2 but FP32 (4-byte) for the moved data.
    const double issued_bytes =
        static_cast<double>(nel) * (24.0 * 4 + 24.0 * 4 * 2 + 24.0 * 4 + 4);
    const double flop = static_cast<double>(nel) * 1152.0;
    const double gbs = issued_bytes / best / 1e9;
    const double gflops = flop / best / 1e9;

    std::printf("# H4 Metal FP32 element-apply prototype  grid %dx%dx%d\n", nx, ny, nz);
    std::printf("# ndof=%d  solid elements=%ld  reps=%d (best-of)  GPU=%s\n",
                ndof, nel, reps, dev.name.UTF8String);
    std::printf("# M2 Pro theoretical peak = 200 GB/s; the GPU shares the SAME unified bus\n\n");
    std::printf("Metal FP32 apply : %.5f s/matvec  |  %.1f GB/s issued (%.1f%% of 200)  |  %.1f GFLOP/s\n",
                best, gbs, 100.0 * gbs / 200.0, gflops);
    std::printf("CPU  FP64 apply  : (H2) ~54 GB/s issued / ~90 GFLOP/s on 6 P-cores\n\n");

    std::printf("# ACCURACY (the usability question)\n");
    std::printf("rel L2  GPU-FP32 vs CPU-FP64 = %.3e\n", relnorm(y64, yg32));
    std::printf("rel L2  CPU-FP32 vs CPU-FP64 = %.3e   (same FP32 floor, CPU)\n", relnorm(y64, yc32));
    double gpu_cpu32 = 0, den = 0;
    for (int i = 0; i < ndof; ++i) {
      const double d = static_cast<double>(yg32[i]) - static_cast<double>(yc32[i]);
      gpu_cpu32 += d * d; den += static_cast<double>(yc32[i]) * yc32[i];
    }
    std::printf("rel L2  GPU-FP32 vs CPU-FP32 = %.3e   (kernel agreement, not precision)\n",
                std::sqrt(gpu_cpu32 / den));
  }
  return 0;
}
