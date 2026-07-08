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
#include <exception>
#include <string>

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"

namespace {

int usage(const char* argv0) {
  std::fprintf(stderr,
               "usage: %s run <job.json> [--out DIR] [--materials PATH] "
               "[--rules PATH]\n",
               argv0);
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
  if (argc < 3 || std::string(argv[1]) != "run") return usage(argv[0]);
  const std::string job_path = argv[2];
  std::string out_dir = ".";
  std::string materials_path = TOPOPT_CLI_DEFAULT_MATERIALS;
  std::string rules_path = TOPOPT_CLI_DEFAULT_RULES;
  for (int i = 3; i < argc; ++i) {
    const std::string arg = argv[i];
    if (i + 1 >= argc) return usage(argv[0]);  // every flag takes a value
    if (arg == "--out") {
      out_dir = argv[++i];
    } else if (arg == "--materials") {
      materials_path = argv[++i];
    } else if (arg == "--rules") {
      rules_path = argv[++i];
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

    const topopt::RunJobResult result =
        topopt::run_job(job, dirname_of(job_path), out_dir, materials, rules);

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
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "topopt-cli: %s\n", e.what());
    return 1;
  }
}
