// solver_arm_sweep.cpp — WHY ARE THE TWO BUILT ACCELERATORS NOT RUNNING, AND
// WHAT DOES ARMING THEM COST? (task solver-speed-arm-and-diagnose; handoff
// docs/handoffs/2026-08-14-solver-speed-arm-and-diagnose.md)
//
// NOT a CTest target and NOT linked into any production path: a standalone
// measurement harness, the sibling of geneo_standing_probe.cpp /
// warm_start_coarse_gate.cpp / mg_rearm_probe.cpp. It links the production
// library and drives THE PRODUCTION DRIVER — topopt::run_job, the same entry
// point core/src/cli/main.cpp calls — on the MAINTAINER'S OWN CAPTURED JOB,
// varying only postures that production already has switches for but no
// production writer:
//
//   fea_set_mg_algebraic_level1        public in fea.hpp, ZERO production
//                                      callers (the §4a lever)
//   fea_matfree_set_mg_rearm_period    the measurement-only latch re-arm this
//                                      task added; 0 is production (the §2b
//                                      lever, closing 2026-07-27-mg-stagnation
//                                      -phase0 §7's own named gap)
//   geneo_set_probe_config             the harness-only GenEO recipe surface
//                                      whose DEFAULTS ARE the shipped tripwire
//                                      constants (the §1b/§1c levers)
//   fea_set_matfree_mixed_precision    public, production-blocked (the §4d lever)
//
// ★ THE FIRST AND LAST OF THOSE RIDE `RunObservability`, NOT A DIRECT SETTER.
// `configure_production_options` re-asserts both at run start, so setting them
// here would be silently overwritten and would measure the shipped posture while
// reporting an armed one. See THE POSTURE below — that is where it cost this
// task an arm before the artifact caught it.
//
// WHY run_job AND NOT A SYNTHETIC FIXTURE. Every prior measurement of these two
// accelerators was taken on a proxy, and every one of them named the same gap in
// its own text: geneo-standing-probe priced the refresh at an operating point
// (N_t/k_jacobi = 27.6) that the shipped job no longer sits at, and
// mg-stagnation-phase0 §7 said in as many words that the developed-rung verdict
// "requires the maintainer's actual part". run_job.cpp is compiled into
// libtopopt, so the real job — STEP import, loadcase, preflight, the production
// ladder, the production PLSM path — is reachable from a harness without a
// single production line changing. Bar R4 asks for his job; this is how.
//
// WHAT IT DOES NOT DO. It sets no default, arms nothing in production, and
// touches no gate. Every posture below is applied by this file, in this process,
// and the shipped posture (`--arm base`) applies NOTHING — so `base` is the
// control that proves the harness itself is inert.
//
// Build (library Release first):
//   cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
//   cmake --build build --target topopt -j8
//   c++ -std=c++17 -O2 -I core/include -I core/src \
//       core/tests/harness/solver_arm_sweep.cpp build/libtopopt.a \
//       $(pkg-config --libs --cflags opencascade 2>/dev/null) -o build/solver_arm_sweep
//   (the evidence directory's run_arms.sh does this with the project's own
//    OCCT link line, since the job is a STEP part)
//
// Usage:
//   solver_arm_sweep <job.json> <out_dir> --arm NAME [--threads N] [--iters N]
//
// Arms:
//   base        the shipped posture. Nothing applied. The R1 denominator.
//   rearm=N     fea_matfree_set_mg_rearm_period(N). N=1 is the latch-disabled
//               build: multigrid attempts a hierarchy on EVERY solve.
//   alg1        fea_set_mg_algebraic_level1(true).
//   core=N      GenEO subdomain tiling: kGeneoCoreCells -> N. Bigger cores =>
//               fewer subdomains => smaller N_t => a cheaper refresh. This is
//               the ONLY lever measured to move N_t at all (geneo-standing-probe
//               W3: a 50x lambda_cut sweep moved N_t by 0.7%).
//   cut=X       GenEO lambda cut. Kept reachable so W3's inertness is re-tested
//               on THIS operating point rather than assumed.
//   trig=N      kGeneoTriggerIters -> N (the §1c question).
//   thr=N       the engagement gate's threshold, forced to N plain iterations.
//               0 engages the deflation the moment a basis is held.
//   mixed       fea_set_matfree_mixed_precision(true), via RunObservability.
//               §4d says do not run this before §2 resolves; the arm exists so
//               that ordering can be honoured explicitly rather than by omission.
//
// Output: whatever run_job writes to <out_dir> (run_info.json + iterations.csv
// are the load-bearing ones) plus a one-line ARM_SUMMARY on stdout carrying the
// figures of merit R1 asks for — TOTAL CG ITERATIONS first, wall beside it.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"

#include "../../src/fea/geneo.hpp"

namespace {

std::string dirname_of(const std::string& p) {
  const std::size_t s = p.find_last_of("/\\");
  return s == std::string::npos ? std::string(".") : p.substr(0, s);
}

// The posture, applied ONCE before the run. Every field's default is the
// shipped value, so a `base` arm applies nothing at all.
struct Arm {
  std::string name = "base";
  int rearm_period = 0;
  bool algebraic_level1 = false;
  bool mixed_precision = false;
  int geneo_core = 0;        // 0 = shipped kGeneoCoreCells
  double geneo_cut = -1.0;   // < 0 = shipped kGeneoLambdaCut
  int geneo_trigger = -1;    // < 0 = shipped kGeneoTriggerIters
  int geneo_threshold = -1;  // < 0 = the shipped measured cost model
};

bool parse_arm(const std::string& spec, Arm& a) {
  a.name = spec;
  if (spec == "base") return true;
  if (spec == "alg1") { a.algebraic_level1 = true; return true; }
  if (spec == "mixed") { a.mixed_precision = true; return true; }
  const std::size_t eq = spec.find('=');
  if (eq == std::string::npos) return false;
  const std::string k = spec.substr(0, eq);
  const std::string v = spec.substr(eq + 1);
  if (k == "rearm") { a.rearm_period = std::atoi(v.c_str()); return true; }
  if (k == "core") { a.geneo_core = std::atoi(v.c_str()); return true; }
  if (k == "cut") { a.geneo_cut = std::atof(v.c_str()); return true; }
  if (k == "trig") { a.geneo_trigger = std::atoi(v.c_str()); return true; }
  if (k == "thr") { a.geneo_threshold = std::atoi(v.c_str()); return true; }
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: solver_arm_sweep <job.json> <out_dir> [--arm SPEC]... "
                 "[--threads N] [--iters N]\n");
    return 2;
  }
  const std::string job_path = argv[1];
  const std::string out_dir = argv[2];
  Arm arm;
  int threads = 0;
  int iters = 0;
  for (int i = 3; i < argc; ++i) {
    const std::string f = argv[i];
    if (f == "--arm" && i + 1 < argc) {
      if (!parse_arm(argv[++i], arm)) {
        std::fprintf(stderr, "solver_arm_sweep: unknown arm '%s'\n", argv[i]);
        return 2;
      }
    } else if (f == "--threads" && i + 1 < argc) {
      threads = std::atoi(argv[++i]);
    } else if (f == "--iters" && i + 1 < argc) {
      iters = std::atoi(argv[++i]);
    } else {
      std::fprintf(stderr, "solver_arm_sweep: unknown flag '%s'\n", f.c_str());
      return 2;
    }
  }

  topopt::JobDescription job = topopt::load_job_file(job_path);
  // The CLI's own rule (main.cpp): `topopt-cli run` has no SIMP route, so the
  // production verb forces the parametric level set on. Mirrored here so the
  // harness measures the SHIPPED algorithm and not a path no user can reach.
  job.has_plsm = true;
  job.plsm_enabled = true;
  if (iters > 0) job.plsm_max_iterations = iters;

  const topopt::MaterialLibrary materials =
      topopt::load_materials_file("core/src/materials/materials.json");
  const topopt::SettingsRules rules =
      topopt::load_settings_rules_file("core/src/settings/rules.json");

  topopt::RunObservability obs;

  // ── THE POSTURE. Applied here and nowhere else; `base` applies nothing.
  //
  // ★ THE THREE SOLVER GLOBALS RIDE `RunObservability`, NOT A DIRECT SETTER, and
  // that is not a stylistic choice. `configure_production_options` re-asserts
  // `fea_set_mg_algebraic_level1` and the mixed-precision flag at the start of
  // every run (production.cpp) — deliberately, so a thread that ran a harness
  // earlier cannot leak an armed solver into a production run. A harness that
  // called the setter HERE would be silently overwritten and would then measure
  // the shipped posture while reporting an armed one. That is not hypothetical:
  // the first `alg1` arm of this task did exactly that, and what caught it was
  // `mg_algebraic_level1: false` sitting in the armed arm's own run_info.json.
  // run_job applies these AFTER configure_production_options, which is the only
  // correct point.
  //
  // The GenEO probe config below is different and IS set directly: it has no
  // production writer at all, so nothing re-asserts it.
  obs.mg_rearm_period = arm.rearm_period;
  if (arm.algebraic_level1) obs.mg_algebraic_level1 = 1;
  if (arm.mixed_precision) obs.matfree_mixed_precision = 1;
  if (arm.geneo_core > 0 || arm.geneo_cut > 0.0 || arm.geneo_trigger >= 0 ||
      arm.geneo_threshold >= 0) {
    topopt::fea_detail::GeneoProbeConfig cfg;  // defaults ARE the tripwire
    if (arm.geneo_core > 0) cfg.core_cells = arm.geneo_core;
    if (arm.geneo_cut > 0.0) cfg.lambda_cut = arm.geneo_cut;
    if (arm.geneo_trigger >= 0) cfg.trigger_iters = arm.geneo_trigger;
    if (arm.geneo_threshold >= 0) cfg.engage_threshold = arm.geneo_threshold;
    topopt::fea_detail::geneo_set_probe_config(cfg);
  }

  obs.iteration_csv = true;
  obs.fingerprint = "solver_arm_sweep";
  obs.matfree_threads = threads;

  std::printf("ARM %s  job=%s  out=%s  threads=%d  plsm_max_iterations=%d\n",
              arm.name.c_str(), job_path.c_str(), out_dir.c_str(), threads,
              job.plsm_max_iterations);
  std::fflush(stdout);

  const auto t0 = std::chrono::steady_clock::now();
  // ★ emit_progress = true, and it is NOT cosmetic: run_job writes run_info.json
  // and iterations.csv ONLY under this flag (run_job.cpp, the `if
  // (emit_progress)` block that constructs IterationCsvWriter). With it false the
  // run completes and leaves no per-solve record at all, which is to say no
  // measurement — this harness lost two arms to exactly that before the flag was
  // read. It is also what core/src/cli/main.cpp passes, so the harness and the
  // production CLI now drive run_job identically, which is what makes the
  // base-arm byte-identity check in run_arms.sh mean anything.
  const topopt::RunJobResult result =
      topopt::run_job(job, dirname_of(job_path), out_dir, materials, rules,
                      /*emit_progress=*/true, obs);
  const double wall_s =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
          .count();

  // ── R1: TOTAL CG ITERATIONS IS THE FIGURE OF MERIT, WALL BESIDE IT.
  // Summed by re-reading the iterations.csv run_job just wrote, rather than from
  // a private counter, so the headline number and the committed per-iteration
  // record cannot disagree — the failure mode a separate counter invites.
  long long total_cg = 0, design_iters = 0, hier_attempts = 0;
  {
    const std::string csv = out_dir + "/iterations.csv";
    std::FILE* f = std::fopen(csv.c_str(), "r");
    if (f == nullptr) {
      std::fprintf(stderr,
                   "solver_arm_sweep: %s missing — the run wrote no "
                   "per-iteration record, so no figure of merit can be "
                   "reported. Refusing to print a summary.\n",
                   csv.c_str());
      return 1;
    }
    char line[8192];
    // Column indices are read from the header rather than hard-coded: the CSV
    // has gained columns three times (128, 133, the phase-timing task) and a
    // fixed index would silently sum the wrong column.
    int col_cg = -1, col_hier = -1, n_cols = 0;
    if (std::fgets(line, sizeof(line), f) != nullptr) {
      char* save = nullptr;
      for (char* t = strtok_r(line, ",\r\n", &save); t != nullptr;
           t = strtok_r(nullptr, ",\r\n", &save), ++n_cols) {
        if (std::strcmp(t, "cg_iters") == 0) col_cg = n_cols;
        if (std::strcmp(t, "hier_built") == 0) col_hier = n_cols;
      }
    }
    if (col_cg < 0) {
      std::fclose(f);
      std::fprintf(stderr,
                   "solver_arm_sweep: no 'cg_iters' column in %s\n",
                   csv.c_str());
      return 1;
    }
    while (std::fgets(line, sizeof(line), f) != nullptr) {
      char* save = nullptr;
      int c = 0;
      for (char* t = strtok_r(line, ",\r\n", &save); t != nullptr;
           t = strtok_r(nullptr, ",\r\n", &save), ++c) {
        if (c == col_cg) total_cg += std::atoll(t);
        if (c == col_hier && std::atoi(t) != 0) ++hier_attempts;
      }
      ++design_iters;
    }
    std::fclose(f);
  }

  // ── R3: NO VERDICT MOVES. One line per evaluated rung, accepted or not, with
  // the certified worst-case margin — so a solver arm that quietly moved the
  // design is visible in the same stdout as the speed number, not in a separate
  // pass someone has to remember to run.
  for (const topopt::MinimizePlasticVariant& v : result.pipeline.evaluated)
    std::printf("ARM_RUNG arm=%s vf_requested=%.6f margin=%.9g accepted=%d\n",
                arm.name.c_str(), v.requested_volume_fraction,
                v.report.margin.worst_case, v.accepted ? 1 : 0);

  std::printf(
      "ARM_SUMMARY arm=%s total_cg=%lld design_iters=%lld wall_s=%.1f "
      "hier_attempts=%lld rearm_attempts=%lld rearm_carries=%lld "
      "geneo_armed=%lld geneo_declined=%lld geneo_dim=%d geneo_builds=%lld "
      "alg1=%d\n",
      arm.name.c_str(), total_cg, design_iters, wall_s, hier_attempts,
      topopt::fea_matfree_mg_rearm_attempts(),
      topopt::fea_matfree_mg_rearm_carries(), topopt::fea_geneo_armed_solves(),
      topopt::fea_geneo_declined_solves(), topopt::fea_geneo_basis_dim(),
      topopt::fea_geneo_basis_builds(),
      topopt::fea_mg_algebraic_level1_enabled() ? 1 : 0);
  std::fflush(stdout);
  return 0;
}
