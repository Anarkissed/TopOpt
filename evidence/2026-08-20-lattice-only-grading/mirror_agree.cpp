// R15 — CORE AND THE APP AGREE ON BOTH INTENTS, to the digit, on his part.
//
// The app's preview no longer computes a normalisation of its own: it calls
// `topoptbridge::grading_demand_fraction_into`, which calls core's
// `topopt::grading_demand_fraction`. This probe FEEDS THE SAME SAMPLES to both and
// compares, so the single-sourcing is demonstrated rather than asserted.
//
// The samples are his own run's von Mises field, read from fields.bin.
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <vector>
#include <algorithm>
#include "topopt/grading.hpp"
#include "TopOptBridge.hpp"
using namespace topopt;
int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: %s <fields.bin>\n", argv[0]); return 2; }
  std::ifstream in(argv[1], std::ios::binary);
  std::vector<std::uint8_t> b((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  std::size_t p = 0;
  auto i32=[&]{ std::int32_t v; std::memcpy(&v,b.data()+p,4); p+=4; return v; };
  auto i64=[&]{ std::int64_t v; std::memcpy(&v,b.data()+p,8); p+=8; return v; };
  auto f64=[&]{ double v; std::memcpy(&v,b.data()+p,8); p+=8; return v; };
  auto f32=[&]{ float v; std::memcpy(&v,b.data()+p,4); p+=4; return v; };
  p=4; i32(); i32(); i32(); f64(); f64(); f64(); f64(); f64(); i32(); p+=4;
  f64(); f64(); i32(); p+=4;
  const std::int64_t n = i64(); i64(); i64();
  std::vector<float> vm(static_cast<std::size_t>(n));
  for (std::int64_t i=0;i<n;++i) vm[static_cast<std::size_t>(i)] = f32();
  std::printf("samples: %lld\n", (long long)n);

  const double allowable = 55.0 / 1.5;
  struct Case { const char* name; int intent; double allow; double q; double tgt; };
  const Case cases[] = {
      {"STRUCTURAL  min_plastic ON ", 0, allowable, 0.0, 1.0},
      {"STRUCTURAL  min_plastic OFF", 0, allowable, 0.0, 0.5},
      {"AESTHETIC   p95            ", 1, 0.0, 0.95, 1.0},
      {"AESTHETIC   p80            ", 1, 0.0, 0.80, 1.0},
  };
  int bad = 0;
  for (const Case& c : cases) {
    // the APP's path
    std::vector<float> app(vm.size());
    topoptbridge::grading_demand_fraction_into(vm.data(), vm.size(), c.intent,
                                               c.allow, c.q, c.tgt, app.data());
    const double ref = topoptbridge::grading_demand_reference(vm.data(), vm.size(),
                                                              c.intent, c.allow, c.q);
    // CORE's own function, on the same samples and the same reference
    const GradingIntent gi = c.intent == 0 ? GradingIntent::Structural
                                           : GradingIntent::Aesthetic;
    double worst = 0.0; std::size_t at = 0;
    for (std::size_t i = 0; i < vm.size(); ++i) {
      // ★ COMPARE AT THE PRECISION THE MIRROR DELIVERS. The bridge stores float32;
      // comparing that against a double64 measures the STORE, not the law, and a
      // first version of this probe reported 1e-11 as "drift". Narrow core's value
      // the same way the bridge does, then require BIT EQUALITY.
      const float core_f = static_cast<float>(grading_demand_fraction(
          gi, std::isfinite(vm[i]) ? vm[i] : 0.0, ref, c.tgt));
      const double d = (core_f == app[i]) ? 0.0
                                          : std::fabs(static_cast<double>(core_f) -
                                                      static_cast<double>(app[i]));
      if (d > worst) { worst = d; at = i; }
    }
    std::printf("%s ref %.10g   max |core-app| = %.3e  (voxel %zu)  %s\n",
                c.name, ref, worst, at, worst == 0.0 ? "BIT-IDENTICAL" : "DIFFERS");
    if (worst != 0.0) ++bad;
  }
  std::printf("\n%s\n", bad == 0
      ? "R15: core and the app agree EXACTLY on both intents, every sample."
      : "R15 FAILED: the mirror has drifted from core.");
  return bad == 0 ? 0 : 1;
}
