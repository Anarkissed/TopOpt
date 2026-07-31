// P5 — the new residual. Re-run 262's 12,100-grid aspect-ratio sweep (O8 of
// the odd-axis-cliff handoff) under the WIDENED pad scope: the pad now engages
// whenever the unpadded grid is rejected (odd fine axis OR all-even deep
// block), i.e. a grid is still rejected only when mg_pad_target finds NO
// feasible depth. Reports the rejection rate before 262 (98.7%), after 262
// (23.7%), and after this change — and names the shapes that still fail.
#include "topopt/coarsen.hpp"

#include <cstdio>
#include <initializer_list>

using namespace topopt;

int main() {
  const int res = 128;
  long long total = 0, accepted = 0, rej_fine_odd = 0, rej_deep = 0;
  long long odd_padded = 0, deep_padded = 0, still_rejected = 0;
  const int lo = res * 15 / 100;
  for (int b = lo; b <= res; ++b)
    for (int c = lo; c <= res; ++c) {
      ++total;
      const MgCoarsenPlan plan = mg_coarsen_plan(res, b, c);
      if (plan.accepted) { ++accepted; continue; }
      const bool fine_odd = (res & 1) || (b & 1) || (c & 1);
      int px, py, pz;
      const bool padded = mg_pad_target(res, b, c, px, py, pz) > 0;
      if (fine_odd) ++rej_fine_odd; else ++rej_deep;
      if (padded) { if (fine_odd) ++odd_padded; else ++deep_padded; }
      else {
        ++still_rejected;
        if (still_rejected <= 20)
          std::printf("  still rejected: %dx%dx%d\n", res, b, c);
      }
    }
  std::printf("resolution %d, shorter axes %d..%d (%lld grids)\n", res, lo, res,
              total);
  std::printf("  accepted with no pad:      %6lld (%.1f%%)\n", accepted,
              100.0 * accepted / total);
  std::printf("  rejected unpadded:         %6lld (%.1f%%)  [pre-262 rate]\n",
              total - accepted, 100.0 * (total - accepted) / total);
  std::printf("    fine-odd, pad fixes:     %6lld  [262's scope]\n", odd_padded);
  std::printf("    all-even deep, pad fixes:%6lld  [THIS task's scope]\n",
              deep_padded);
  std::printf("  after 262 (odd only):      %.1f%% rejected\n",
              100.0 * (rej_deep + (rej_fine_odd - odd_padded)) / total);
  std::printf("  after THIS change:         %6lld (%.2f%%) rejected\n",
              still_rejected, 100.0 * still_rejected / total);

  for (int r : {64, 96, 160, 192}) {
    long long t = 0, rej_before = 0, rej_262 = 0, rej_now = 0;
    const int l = r * 15 / 100;
    for (int b = l; b <= r; ++b)
      for (int c = l; c <= r; ++c) {
        ++t;
        if (mg_coarsen_plan(r, b, c).accepted) continue;
        ++rej_before;
        const bool fine_odd = (r & 1) || (b & 1) || (c & 1);
        int px, py, pz;
        const bool padded = mg_pad_target(r, b, c, px, py, pz) > 0;
        if (!(fine_odd && padded)) ++rej_262;
        if (!padded) ++rej_now;
      }
    std::printf("res %3d: rejected %.1f%% -> after 262 %.1f%% -> after THIS "
                "%.2f%%\n",
                r, 100.0 * rej_before / t, 100.0 * rej_262 / t,
                100.0 * rej_now / t);
  }
  return 0;
}
