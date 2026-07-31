// O8 — what parity costs in general. The CLI voxelizer gives the longest axis
// exactly `resolution` voxels and each other axis ceil(ext/h): at resolution
// 128 the two shorter axes take whatever integer their aspect ratio lands on.
// Sweep realistic aspect ratios and count how often the CURRENT rule rejects
// the multigrid hierarchy, and how much the parity pad recovers.
#include "topopt/coarsen.hpp"

#include <cstdio>
#include <initializer_list>

using namespace topopt;

int main() {
  const int res = 128;
  long long total = 0, accepted = 0, rej_fine_odd = 0, rej_deep = 0;
  long long pad_fixed = 0, pad_still_rejected = 0;
  // Shorter axes from 15% to 100% of the longest, in 1-voxel steps: every
  // realistic aspect ratio lands on one of these integer dim pairs.
  const int lo = res * 15 / 100;
  for (int b = lo; b <= res; ++b)
    for (int c = lo; c <= res; ++c) {
      ++total;
      const MgCoarsenPlan plan = mg_coarsen_plan(res, b, c);
      if (plan.accepted) { ++accepted; continue; }
      const bool fine_odd = (res & 1) || (b & 1) || (c & 1);
      if (fine_odd) {
        ++rej_fine_odd;
        int px, py, pz;
        if (mg_pad_target(res, b, c, px, py, pz) > 0) ++pad_fixed;
        else ++pad_still_rejected;
      } else {
        ++rej_deep;
      }
    }
  std::printf("resolution %d, shorter axes %d..%d (%lld grids)\n", res, lo, res,
              total);
  std::printf("  accepted today:            %6lld (%.1f%%)\n", accepted,
              100.0 * accepted / total);
  std::printf("  REJECTED today:            %6lld (%.1f%%)\n", total - accepted,
              100.0 * (total - accepted) / total);
  std::printf("    of which fine-odd axis:  %6lld (%.1f%% of all grids)\n",
              rej_fine_odd, 100.0 * rej_fine_odd / total);
  std::printf("    of which all-even deep:  %6lld (%.1f%% of all grids)\n",
              rej_deep, 100.0 * rej_deep / total);
  std::printf("  after parity pad: fixed    %6lld, still rejected (odd) %lld\n",
              pad_fixed, pad_still_rejected);
  const long long after_rej = rej_deep + pad_still_rejected;
  std::printf("  rejection rate after fix:  %.1f%% (was %.1f%%)\n",
              100.0 * after_rej / total, 100.0 * (total - accepted) / total);

  // Same sweep at a few other resolutions for context.
  for (int r : {64, 96, 160, 192}) {
    long long t = 0, acc = 0, fo = 0, fix = 0;
    const int l = r * 15 / 100;
    for (int b = l; b <= r; ++b)
      for (int c = l; c <= r; ++c) {
        ++t;
        if (mg_coarsen_plan(r, b, c).accepted) { ++acc; continue; }
        const bool fine_odd = (r & 1) || (b & 1) || (c & 1);
        if (fine_odd) {
          ++fo;
          int px, py, pz;
          if (mg_pad_target(r, b, c, px, py, pz) > 0) ++fix;
        }
      }
    std::printf("res %3d: rejected %.1f%% -> after fix %.1f%% (fine-odd was "
                "%.1f%% of grids)\n",
                r, 100.0 * (t - acc) / t, 100.0 * (t - acc - fix) / t,
                100.0 * fo / t);
  }
  return 0;
}
