// topopt-cli — the canonical headless entry point (ARCHITECTURE §9 M6):
//
//   topopt-cli run job.json [--out DIR] [--materials PATH] [--rules PATH]
//
// Runs the full §5 pipeline described by job.json (schema: the maintainer-
// authored demo fixture core/tests/fixtures/demo/job.json) and writes the M5.2
// report plus one exported mesh per accepted variant into --out (default: the
// current directory). --materials / --rules default to the committed
// materials.json / settings rules.json paths injected at build time (this
// binary is the repo's dev/CI driver, not an installed product).
//
// Exit codes: 0 success; 1 any job/pipeline failure (diagnostic on stderr);
// 2 usage error.

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"
#include "topopt/version.hpp"

// A build fingerprint (typically the core git commit SHA), injected by CMake. A
// LAN worker exposes it via /health so the iPad app can REFUSE a worker whose
// core differs from its own — the version-skew guard (handoff 093 STEP 3d): two
// cores that differ silently produce different parts. Defaults to "dev" for an
// un-instrumented local build.
#ifndef TOPOPT_BUILD_FINGERPRINT
#define TOPOPT_BUILD_FINGERPRINT "dev"
#endif

namespace {

int usage(const char* argv0) {
  std::fprintf(stderr,
               "usage: %s run <job.json> [--out DIR] [--materials PATH] "
               "[--rules PATH]\n"
               "              [--no-iteration-csv] [--snapshots] "
               "[--snapshot-every N] [--snapshot-cap N]\n"
               "       %s --version\n"
               "\n"
               "Observability (handoff 114), written to --out:\n"
               "  run_info.json      version + config record (always)\n"
               "  iterations.csv     per-iteration trace (default ON; "
               "--no-iteration-csv disables)\n"
               "  snapshots/*.f16    float16 density snapshots (opt-in "
               "--snapshots; ~10.8 MB each at 5.4M voxels)\n",
               argv0, argv0);
  return 2;
}

std::string dirname_of(const std::string& path) {
  const std::string::size_type slash = path.find_last_of('/');
  if (slash == std::string::npos) return ".";
  if (slash == 0) return "/";
  return path.substr(0, slash);
}

}  // namespace

int main(int argc, char** argv) {
  // Version / build fingerprint, one parseable line, for the worker /health probe.
  if (argc >= 2 &&
      (std::string(argv[1]) == "--version" || std::string(argv[1]) == "version")) {
    std::printf("topopt-cli version=%s fingerprint=%s\n", topopt::version(),
                TOPOPT_BUILD_FINGERPRINT);
    return 0;
  }
  if (argc < 3 || std::string(argv[1]) != "run") return usage(argv[0]);
  const std::string job_path = argv[2];
  std::string out_dir = ".";
  std::string materials_path = TOPOPT_CLI_DEFAULT_MATERIALS;
  std::string rules_path = TOPOPT_CLI_DEFAULT_RULES;
  // Handoff 114 — observability config. The build fingerprint (this binary's
  // TOPOPT_BUILD_FINGERPRINT) is stamped into run_info.json so the era is provable.
  topopt::RunObservability obs;
  obs.fingerprint = TOPOPT_BUILD_FINGERPRINT;
  for (int i = 3; i < argc; ++i) {
    const std::string arg = argv[i];
    // Value-less flags first.
    if (arg == "--no-iteration-csv") {
      obs.iteration_csv = false;
      continue;
    }
    if (arg == "--snapshots") {
      obs.density_snapshots = true;
      continue;
    }
    // Every remaining flag takes a value.
    if (i + 1 >= argc) return usage(argv[0]);
    if (arg == "--out") {
      out_dir = argv[++i];
    } else if (arg == "--materials") {
      materials_path = argv[++i];
    } else if (arg == "--rules") {
      rules_path = argv[++i];
    } else if (arg == "--snapshot-every") {
      obs.snapshot_every = std::atoi(argv[++i]);
      if (obs.snapshot_every < 1) return usage(argv[0]);
    } else if (arg == "--snapshot-cap") {
      obs.snapshot_cap = std::atoi(argv[++i]);
    } else {
      return usage(argv[0]);
    }
  }

  try {
    const topopt::JobDescription job = topopt::load_job_file(job_path);
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(materials_path);
    const topopt::SettingsRules rules =
        topopt::load_settings_rules_file(rules_path);

    // emit_progress = true: stream PROGRESS/VARIANT checkpoint lines to stdout and
    // export each accepted variant as it completes, so a wrapper (the LAN worker,
    // handoff 093) can forward live progress + progressive artifacts.
    const topopt::RunJobResult result =
        topopt::run_job(job, dirname_of(job_path), out_dir, materials, rules,
                        /*emit_progress=*/true, obs);

    std::printf("model: %s (%d B-rep faces, %zu fixture faces matched)\n",
                job.model.c_str(), result.model.face_count,
                result.fixture_face_ids.size());
    std::printf("variants: %zu evaluated, %zu accepted%s\n",
                result.pipeline.evaluated.size(), result.mesh_paths.size(),
                result.pipeline.stopped_on_margin
                    ? " (stopped on margin)"
                    : "");
    for (const topopt::MinimizePlasticVariant& v : result.pipeline.evaluated) {
      std::printf(
          "  vf %.2f: margin %.3g, %s\n", v.requested_volume_fraction,
          v.report.margin.worst_case,
          v.accepted ? "accepted" : "rejected (below margin_stop)");
    }
    std::printf("report: %s\n", result.report_path.c_str());
    for (const std::string& p : result.mesh_paths)
      std::printf("mesh: %s\n", p.c_str());
    // Handoff 114 — surface the observability artifacts (forwarded to the worker
    // log / SSE as plain log lines; they do not affect the SSE protocol).
    if (!result.run_info_path.empty())
      std::printf("run_info: %s\n", result.run_info_path.c_str());
    if (!result.iteration_csv_path.empty())
      std::printf("iterations: %s\n", result.iteration_csv_path.c_str());
    if (result.snapshot_count > 0)
      std::printf("snapshots: %zu written\n", result.snapshot_count);
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "topopt-cli: %s\n", e.what());
    return 1;
  }
}
