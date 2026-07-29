// H1 — STREAM-style sustained memory bandwidth on THIS machine.
//
// A deliberately dependency-free (libc++/pthreads only) STREAM triad
//   a[i] = b[i] + s * c[i]
// over arrays far larger than the last-level cache, swept across thread counts.
// This is the memory-system ceiling every iterative solver on this box runs into
// (bandwidth-bound, O(1) arithmetic intensity). It is measurement-only: nothing
// here is compiled into libtopopt or production.
//
// Byte accounting: the triad touches 3 arrays per element (read b, read c, write
// a) = 3*8 bytes in FP64, 3*4 in FP32 ("counted GB/s"). The write also incurs a
// read-for-ownership (write-allocate) line fill on a write-back cache, so the
// TRUE DRAM traffic is closer to 4 arrays (2R + 1W + 1 RFO). Both are reported so
// the ceiling is bracketed, exactly as handoff 113 did.
//
// Build: see build.sh (clang++ -O3 -std=c++17).

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>
#include <chrono>
#include <algorithm>

namespace {

using clk = std::chrono::steady_clock;

// Run `body(lo,hi)` split into contiguous chunks across `n` threads; block.
template <class F>
void parallel_for(std::size_t n_elems, int nthreads, F&& body) {
  if (nthreads <= 1) { body(std::size_t{0}, n_elems); return; }
  std::vector<std::thread> ts;
  ts.reserve(static_cast<std::size_t>(nthreads - 1));
  const std::size_t chunk = (n_elems + static_cast<std::size_t>(nthreads) - 1) /
                            static_cast<std::size_t>(nthreads);
  for (int t = 1; t < nthreads; ++t) {
    const std::size_t lo = std::min(n_elems, static_cast<std::size_t>(t) * chunk);
    const std::size_t hi = std::min(n_elems, lo + chunk);
    ts.emplace_back([lo, hi, &body] { body(lo, hi); });
  }
  body(std::size_t{0}, std::min(n_elems, chunk));
  for (auto& th : ts) th.join();
}

template <class T>
double triad_gbs(std::size_t n, int nthreads, int reps, int arrays_counted) {
  std::vector<T> a(n), b(n), c(n);
  const T s = static_cast<T>(3.14159);
  // Touch/init in parallel so first-touch NUMA placement matches the run (moot on
  // unified memory, but keeps the pages warm and consistently owned).
  parallel_for(n, nthreads, [&](std::size_t lo, std::size_t hi) {
    for (std::size_t i = lo; i < hi; ++i) { a[i] = T(1); b[i] = T(2); c[i] = T(0.5); }
  });

  double best = 0.0;
  for (int r = 0; r < reps; ++r) {
    const auto t0 = clk::now();
    parallel_for(n, nthreads, [&](std::size_t lo, std::size_t hi) {
      for (std::size_t i = lo; i < hi; ++i) a[i] = b[i] + s * c[i];
    });
    const auto t1 = clk::now();
    const double secs = std::chrono::duration<double>(t1 - t0).count();
    const double bytes =
        static_cast<double>(n) * arrays_counted * static_cast<double>(sizeof(T));
    const double gbs = bytes / secs / 1e9;
    best = std::max(best, gbs);
  }
  // Defeat dead-store elimination.
  volatile T sink = a[n / 2] + a[0] + a[n - 1];
  (void)sink;
  return best;
}

}  // namespace

int main(int argc, char** argv) {
  // ~512 MB per FP64 array => 1.5 GB working set, far past the 4 MB L2 / SLC.
  std::size_t bytes_per_array = 512ull * 1024 * 1024;
  int reps = 20;
  if (argc > 1) bytes_per_array = static_cast<std::size_t>(std::atoll(argv[1])) * 1024 * 1024;
  if (argc > 2) reps = std::atoi(argv[2]);

  const std::size_t n64 = bytes_per_array / sizeof(double);
  const std::size_t n32 = bytes_per_array / sizeof(float);

  std::printf("# STREAM triad  a = b + s*c   arrays=%zu MB each  reps=%d (best-of)\n",
              bytes_per_array / (1024 * 1024), reps);
  std::printf("# GB/s counted 3 arrays (2R+1W); '+RFO' counts 4 (write-allocate line fill)\n");
  std::printf("# hw.perflevel0.physicalcpu = 6 P-cores, 4 E-cores; M2 Pro peak = 200 GB/s theoretical\n\n");

  const int threads[] = {1, 2, 4, 6, 8, 10};
  std::printf("%-8s | %-12s %-12s | %-12s %-12s\n", "threads",
              "FP64 GB/s", "FP64 +RFO", "FP32 GB/s", "FP32 +RFO");
  std::printf("---------+--------------------------+--------------------------\n");
  for (int t : threads) {
    const double f64 = triad_gbs<double>(n64, t, reps, 3);
    const double f32 = triad_gbs<float>(n32, t, reps, 3);
    std::printf("%-8d | %-12.1f %-12.1f | %-12.1f %-12.1f\n",
                t, f64, f64 * 4.0 / 3.0, f32, f32 * 4.0 / 3.0);
  }
  std::printf("\n# theoretical peak 200 GB/s => best triad is %% of peak (see handoff)\n");
  return 0;
}
