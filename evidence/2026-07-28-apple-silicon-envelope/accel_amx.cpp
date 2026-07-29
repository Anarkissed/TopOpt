// H3 — Accelerate / AMX FP64 throughput for the kernels we use, versus our current
// hand-written kernel. Are we leaving anything on the table by not routing the
// element apply through Apple's matrix coprocessor (AMX, reached via Accelerate
// BLAS)?
//
// The production element apply is, per solid element, a 24x24 dense matvec
// y = Ke * ul (matfree.cpp axpy24), 1152 FLOP, done by hand in NEON FP64. Three
// measurements bracket what AMX could offer:
//
//   [1] cblas_dgemv on the 24x24 block, data hot in cache, repeated. The apples-to-
//       apples "one element at a time through BLAS" rate — the drop-in replacement
//       for apply_one_element's inner matvec.
//   [2] cblas_dgemm batching N element vectors as columns: Y[24xN] = Ke[24x24] X[24xN].
//       The AMX-favourable shape (Ke reused across N columns => O(N) arithmetic
//       intensity), i.e. the ceiling IF the apply were restructured to batch a
//       colour's elements. Gather/scatter is NOT included — this is the compute
//       ceiling the restructuring would chase.
//   [3] a large square dgemm, the empirical AMX FP64 peak on this box, as the
//       reference every rate above is quoted against.
//
// Accelerate is a system framework (bar B3: no new build dependency). Nothing here
// is compiled into libtopopt.
//
// Build: c++ -O3 -std=c++17 accel_amx.cpp -framework Accelerate

#include <Accelerate/Accelerate.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

using clk = std::chrono::steady_clock;

namespace {
double now_s(clk::time_point a, clk::time_point b) {
  return std::chrono::duration<double>(b - a).count();
}
}  // namespace

int main() {
  std::mt19937_64 rng(12345);
  std::uniform_real_distribution<double> uni(-1.0, 1.0);

  std::printf("# H3 Accelerate/AMX FP64  (M2 Pro, 6P+4E)\n");
  std::printf("# element block = 24x24; production hand kernel measured ~90 GFLOP/s (H2, 6 thr, gather-bound)\n\n");

  // --- [3] AMX FP64 peak: large square dgemm -------------------------------
  // C = A*B, NxN, FLOP = 2 N^3. Big enough to be compute-bound and AMX-resident.
  double amx_peak = 0.0;
  for (int N : {512, 1024, 2048}) {
    std::vector<double> A(static_cast<std::size_t>(N) * N),
        B(static_cast<std::size_t>(N) * N), C(static_cast<std::size_t>(N) * N, 0.0);
    for (auto& v : A) v = uni(rng);
    for (auto& v : B) v = uni(rng);
    // warm
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, N, N, N, 1.0, A.data(),
                N, B.data(), N, 0.0, C.data(), N);
    const int reps = N <= 1024 ? 10 : 4;
    double best = 1e300;
    for (int r = 0; r < reps; ++r) {
      const auto t0 = clk::now();
      cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, N, N, N, 1.0,
                  A.data(), N, B.data(), N, 0.0, C.data(), N);
      const auto t1 = clk::now();
      best = std::min(best, now_s(t0, t1));
    }
    const double gflops = 2.0 * N * N * N / best / 1e9;
    amx_peak = std::max(amx_peak, gflops);
    std::printf("[3] dgemm %4dx%-4d : %8.1f GFLOP/s\n", N, N, gflops);
  }
  std::printf("    => empirical AMX FP64 peak on this machine ~ %.0f GFLOP/s\n\n", amx_peak);

  // The 24x24 element block, symmetric like Ke.
  const int D = 24;
  std::vector<double> Ke(static_cast<std::size_t>(D) * D);
  for (auto& v : Ke) v = uni(rng);

  // --- [1] one element at a time: cblas_dgemv on 24x24, hot in cache --------
  {
    std::vector<double> ul(D), y(D, 0.0);
    for (auto& v : ul) v = uni(rng);
    const long reps = 20'000'000;  // enough to dominate timing overhead
    // warm
    cblas_dgemv(CblasRowMajor, CblasNoTrans, D, D, 1.0, Ke.data(), D, ul.data(),
                1, 0.0, y.data(), 1);
    const auto t0 = clk::now();
    for (long r = 0; r < reps; ++r) {
      cblas_dgemv(CblasRowMajor, CblasNoTrans, D, D, 1.0, Ke.data(), D, ul.data(),
                  1, 0.0, y.data(), 1);
      ul[r & 15] += y[0] * 1e-18;  // chain to prevent hoisting
    }
    const auto t1 = clk::now();
    const double secs = now_s(t0, t1);
    const double gflops = 2.0 * D * D * reps / secs / 1e9;
    std::printf("[1] dgemv 24x24 (per-element, cache-hot): %6.1f GFLOP/s  (%.1f%% of AMX peak)\n",
                gflops, 100.0 * gflops / amx_peak);
  }

  // --- [2] batched: Y[24xN] = Ke[24x24] * X[24xN] ---------------------------
  for (int N : {64, 256, 1024, 4096}) {
    std::vector<double> X(static_cast<std::size_t>(D) * N),
        Y(static_cast<std::size_t>(D) * N, 0.0);
    for (auto& v : X) v = uni(rng);
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, D, N, D, 1.0, Ke.data(),
                D, X.data(), N, 0.0, Y.data(), N);
    const int reps = 2000;
    double best = 1e300;
    for (int r = 0; r < reps; ++r) {
      const auto t0 = clk::now();
      cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, D, N, D, 1.0,
                  Ke.data(), D, X.data(), N, 0.0, Y.data(), N);
      const auto t1 = clk::now();
      best = std::min(best, now_s(t0, t1));
    }
    const double gflops = 2.0 * D * D * N / best / 1e9;
    std::printf("[2] dgemm 24x24 * 24x%-4d (batched apply): %6.1f GFLOP/s  (%.1f%% of AMX peak)\n",
                N, gflops, 100.0 * gflops / amx_peak);
  }
  std::printf("\n# note: [1]/[2] are COMPUTE ceilings (data hot, no gather/scatter). The\n");
  std::printf("# production apply is gather-bound (H2 ~90 GFLOP/s / ~54 GB/s issued), so a\n");
  std::printf("# BLAS swap only helps if the gather is amortised (batching a colour).\n");
  return 0;
}
