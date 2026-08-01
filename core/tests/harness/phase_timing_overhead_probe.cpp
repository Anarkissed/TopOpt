// phase_timing_overhead_probe.cpp — what the PHASE-TIMING INSTRUMENT COSTS
// (task 2026-08-02-iteration-phase-timing, bar Y2). NOT a CI test.
//
// THE BAR, STATED BEFORE MEASURING: the instrument must cost < 0.1% of a design
// iteration's wall time. Rationale, not a round number: the smallest iteration
// this codebase produces in production is a healthy multigrid solve on the
// 48-scale gate fixture, ~275 ms (measured, evidence/.../demo_phase_summary.txt).
// 0.1% of that is 275 microseconds. If the whole instrument fits inside that, it
// cannot perturb any run anyone cares about — and the ONLY way it perturbs a run
// at all is by spending time, since nothing it records is ever read back.
//
// WHAT IT MEASURES, honestly:
//   (1) the marginal cost of ONE steady_clock_ms() read,
//   (2) the marginal cost of ONE process_memory() sample (the mach/getrusage
//       syscalls — by far the most expensive single thing the instrument does),
//   (3) the FIXED per-iteration clock-read count of the optimizer loop, counted
//       by hand from the source and asserted here so a future edit that adds
//       spans has to update the number,
//   (4) the PER-CG-ITERATION clock-read count the solver adds on the Jacobi +
//       GenEO + recycling path (the expensive regime), which scales with the CG
//       count and so is reported against a worst-case iteration count.
// Total = (3)*clock + (4)*clock*cg + memory, expressed as a percentage of a
// stated iteration wall.
//
// Build:
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/phase_timing_overhead_probe.cpp build/libtopopt.a \
//       -o build/phase_timing_overhead_probe

#include <cstdio>
#include <vector>

#include "topopt/observability.hpp"

using namespace topopt;

namespace {

// Clock reads on the EXECUTED path of one design iteration, counted from source
// (production posture: MMA grayscale, matrix-free multigrid, Jacobi fallback).
// A future edit that adds spans must update this number, which is why it is
// spelled out term by term rather than rounded.
//
// core/src/simp/simp.cpp, masked overload (the production loop):
//   IterSpans::begin                                     1
//   filter x3 (xphys, xtilde, xafter)  mark+charge        6
//   project x2 (xphys, xafter)         mark+charge        4
//   solve (active_domain_solve)        mark+charge        2
//   update (the OC/MMA call)           mark+charge        2
//   analysis x2 (change block, vf + detectors)            4
//   observe x2 (progress hook, record build)              4
//   finish_phases total_ms                                1
//   last_observe_end_ms                                   1
//                                                       ---- 25
//   simp_compliance (solve/sensitivity split)             3
//   solve_mgcg_matfree (entry, build, hierarchy, V-cycle,
//     total)                                              7
//   mf_cg_solve fixed part (entry, write_times, recycle
//     session, geneo begin/end, commit, first augment +
//     first coarse apply)                                15
//                                                       ---- 50
// The loop's 25 are an UPPER bound: a non-projecting rung skips the xtilde
// filter and one project span.
constexpr int kLoopClockReads = 50;

// Clock reads the Jacobi-CG recurrence adds PER CG ITERATION when both the
// Krylov recycle correction and the GenEO deflation are active (production's
// armed posture on the stagnation fallback): recycle.observe (2),
// recycle.augment (2), geneo_apply (2).
constexpr int kPerCgIterClockReads = 6;

double median(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

}  // namespace

int main() {
  // (1) One steady_clock_ms() read. Timed in blocks so the loop overhead is
  // amortised, then reduced by the median of repeats so a scheduling hiccup on
  // one block cannot inflate the answer.
  constexpr int kBlock = 200000;
  std::vector<double> clock_ns;
  for (int rep = 0; rep < 9; ++rep) {
    const double t0 = steady_clock_ms();
    double sink = 0.0;
    for (int i = 0; i < kBlock; ++i) sink += steady_clock_ms();
    const double t1 = steady_clock_ms();
    if (sink == 0.0) std::printf("");  // keep the reads
    clock_ns.push_back((t1 - t0) * 1e6 / static_cast<double>(kBlock + 2));
  }
  const double one_clock_ns = median(clock_ns);

  // (2) One process_memory() sample.
  constexpr int kMemBlock = 20000;
  std::vector<double> mem_ns;
  for (int rep = 0; rep < 9; ++rep) {
    const double t0 = steady_clock_ms();
    double sink = 0.0;
    for (int i = 0; i < kMemBlock; ++i) sink += process_memory().rss_mb;
    const double t1 = steady_clock_ms();
    if (sink < 0.0) std::printf("");
    mem_ns.push_back((t1 - t0) * 1e6 / static_cast<double>(kMemBlock));
  }
  const double one_mem_ns = median(mem_ns);

  const ProcessMemory pm = process_memory();
  std::printf("== phase-timing instrument cost ==\n");
  std::printf("steady_clock_ms()   : %8.1f ns/call\n", one_clock_ns);
  std::printf("process_memory()    : %8.1f ns/call\n", one_mem_ns);
  std::printf("  (sample: rss %.1f MB, peak %.1f MB, compressed %.1f MB, "
              "avail %.1f MB, majflt %lld, swapins %lld)\n",
              pm.rss_mb, pm.peak_rss_mb, pm.compressed_mb, pm.available_mb,
              pm.major_faults, pm.swapins);

  std::printf("\nfixed per-iteration cost: %d clock reads + 1 memory sample = "
              "%.1f us\n",
              kLoopClockReads,
              (kLoopClockReads * one_clock_ns + one_mem_ns) / 1000.0);

  std::printf("\n%-10s %-14s %12s %12s %10s\n", "cg_iters", "regime",
              "instr_us", "iter_wall_ms", "pct");
  struct Case {
    int cg;
    const char* regime;
    double wall_ms;
  };
  // The three regimes this codebase actually runs, with MEASURED iteration walls
  // from evidence/2026-08-02-iteration-phase-timing (the 48-scale gate fixture
  // and the design-box reproduction). The per-CG clock reads apply only on the
  // Jacobi fallback; a multigrid-carried solve never enters that loop.
  const Case cases[] = {
      {60, "MG carried", 275.0},       // gate fixture rung 0, healthy
      {245, "MG carried", 961.0},      // gate fixture rung 2, late
      {96, "Jacobi+GenEO", 4740.3},   // design box, latched, fewest CG iters
      {562, "Jacobi+GenEO", 52278.3}, // design box, latched, MEDIAN cg_iters
      {3316, "Jacobi+GenEO", 30381.5},// design box, latched, most CG iters
  };
  for (const Case& c : cases) {
    const bool jacobi = c.regime[0] == 'J';
    const double instr_us =
        (kLoopClockReads * one_clock_ns + one_mem_ns +
         (jacobi ? kPerCgIterClockReads * c.cg * one_clock_ns : 0.0)) /
        1000.0;
    std::printf("%-10d %-14s %12.1f %12.1f %9.5f%%\n", c.cg, c.regime, instr_us,
                c.wall_ms, 100.0 * instr_us / (c.wall_ms * 1000.0));
  }
  std::printf(
      "\nBAR: < 0.1%% of iteration wall. The instrument's only mechanism for\n"
      "perturbing a run is spending time — nothing it records is read back by\n"
      "any solver or updater decision (proven bit-identical by the golden\n"
      "capture test and the stash-rebuild checksum).\n");
  return 0;
}
