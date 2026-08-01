// geneo_standing_probe.cpp — DOES GENEO PAY AS AN ALWAYS-ON PRECONDITIONER,
// rather than as the emergency rescue its shipped trigger makes it?
// (task geneo-standing-preconditioner-probe; handoff
// docs/handoffs/2026-08-02-geneo-standing-probe.md)
//
// NOT a CTest target, NOT linked into any production path: a standalone
// measurement harness like geneo_arming_gate.cpp / draft_arming_gate.cpp. It
// links the production library and drives the SHIPPED GenEO provider
// (core/src/fea/geneo.cpp) — its basis, its reuse policy, its rebuild policy,
// its fingerprints — through the PRODUCTION ladder (minimize_plastic), varying
// only the recipe CONSTANTS via the harness-only probe surface
// (fea_detail::geneo_set_probe_config, src/fea/geneo.hpp), whose defaults ARE
// those constants. No production default changes; no gate changes.
//
// THE OBSERVATION UNDER TEST (a real maintainer run, fingerprint 9f6738726016 —
// the WallMount bracket with 4 bolt clearances): multigrid BUILT, stagnated for
// 3 design iterations (mg_cycles_attempted=300 each), the 127 latch correctly
// turned it off, and every solve after that was plain Jacobi-CG at ~275
// iterations. GenEO never armed, because 275 < kGeneoTriggerIters=500. Correct
// under the shipped recipe — which assumes GenEO is a rescue for the
// 1,685-41,063-iteration regime. Alexandersen & Lazarov (arXiv 1411.3923) use
// the same spectral coarse space as a STANDING preconditioner for this problem
// class instead.
//
// Build (library Release first; OCCT off, tests off):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/geneo_standing_probe.cpp core/build/libtopopt.a \
//     -o core/build/geneo_standing_probe
//
// Modes:
//   regime          W0 — is the fixture at the observed OPERATING POINT?
//                   (multigrid absent; every solve a matrix-free Jacobi-CG)
//   w1              W1/W2 — the cheap test: plain latched Jacobi-CG vs the
//                   SHIPPED trigger vs STANDING GenEO (trigger 0) over one OC
//                   trajectory. Per-design-iteration CG, builds, refreshes,
//                   N_t, basis MB, wall, amortisation.
//   scale           W1b — how the refresh price (N_t) scales against the solve
//                   price (k_jacobi) across grid sizes. THE decisive ratio.
//   bench           W1c — the INTERLEAVED A/B wall-clock benchmark. Use this,
//                   not the trajectory walls, for any timing claim: it
//                   alternates the postures solve-by-solve so machine load
//                   cancels. TOPOPT_GSP_CORE / _CUT / _REPS select the config.
//   w3              W3 — eigenvalue-cut / basis-dimension sweep: total wall vs
//                   N_t (the DTU finding: a smaller basis can win on wall while
//                   losing on iterations).
//   w4              W4 — tiling sweep 4^3 / 8^3 / 16^3.
//   w5a             W5a — diag(K_agglomerate) eigenproblem weighting vs the
//                   shipped D A^Neu D pencil.
//   w5b             W5b — does the shipped rebuild_factor policy catch the
//                   CONTINUATION-parameter change points, or miss them?
//   w6              W6 — correctness: same converged u to solver tolerance,
//                   deterministic across reruns.
//   w7              W7 — the honest comparison: what a HEALTHY multigrid run
//                   costs on a grid where MG does converge.
//
// Evidence dir: TOPOPT_GSP_DIR (default ./gsp_evidence).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <sys/resource.h>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/geneo.hpp"  // the harness-only probe override surface

using namespace topopt;
using topopt::fea_detail::GeneoProbeConfig;

namespace {

std::string evidence_dir() {
  const char* d = std::getenv("TOPOPT_GSP_DIR");
  return d ? std::string(d) : std::string("gsp_evidence");
}

long long peak_rss_bytes() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
  return ru.ru_maxrss;
#else
  return ru.ru_maxrss * 1024;
#endif
}

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// ---------------------------------------------------------------------------
// THE OPERATING POINT. The maintainer run's steady state is: the 127 latch has
// turned multigrid OFF and EVERY solve is the matrix-free Jacobi-CG at ~275
// iterations. The harness reaches that same solve path DIRECTLY and
// deterministically, rather than waiting on three consecutive stagnations:
//   * the analysis grid is built with an ODD axis (non-coarsenable), and
//   * fea_set_mg_parity_pad_mode(0) restores the legacy REJECTION documented in
//     fea.hpp as the way "tests keep exercising the Jacobi fallback".
// So multigrid never runs and every trajectory solve lands in mf_cg_solve — the
// exact solve GenEO lives inside, and the exact solve the latched run performs.
// WHY this is the right isolation: the GenEO economics question is about what a
// ~275-iteration matrix-free Jacobi-CG costs with and without a standing
// deflation. WHY multigrid is absent (latched off vs rejected) does not enter
// that arithmetic, and pinning it removes the run-to-run latch noise that would
// otherwise contaminate every sweep.
void pin_to_jacobi_fallback() {
  fea_set_mg_parity_pad_mode(0);
  fea_matfree_reset_mg_stagnation_latch();
}

}  // namespace

// ---------------------------------------------------------------------------
#include "geneo_standing_probe_modes.inc"

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const std::string mode = argc > 1 ? argv[1] : "regime";
  const std::string dir = evidence_dir();

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm();

  if (!fea_detail::geneo_probe_defaults_match_tripwire()) {
    std::fprintf(stderr,
                 "FAIL: the probe override DEFAULTS no longer equal the shipped "
                 "GenEO recipe constants — every number below would be measuring "
                 "something other than production.\n");
    return 1;
  }
  std::printf("probe defaults == shipped recipe: YES (trigger=%d core=%d ov=%d "
              "block_m=%d cut=%.3f)\n",
              fea_geneo_trigger_iters(), fea_detail::kGeneoCoreCells,
              fea_detail::kGeneoOverlap, fea_detail::kGeneoBlockM,
              fea_detail::kGeneoLambdaCut);

  if (mode == "regime") return mode_regime(rules, material, dir);
  if (mode == "w1") return mode_w1(rules, material, dir);
  if (mode == "scale") return mode_scale(rules, material, dir);
  if (mode == "bench") return mode_bench(rules, material, dir);
  if (mode == "w3") return mode_w3(rules, material, dir);
  if (mode == "w4") return mode_w4(rules, material, dir);
  if (mode == "w5a") return mode_w5a(rules, material, dir);
  if (mode == "w5b") return mode_w5b(rules, material, dir);
  if (mode == "w6") return mode_w6(rules, material, dir);
  if (mode == "w7") return mode_w7(rules, material, dir);
  std::fprintf(stderr, "unknown mode: %s\n", mode.c_str());
  return 2;
}
