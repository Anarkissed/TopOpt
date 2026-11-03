// E1 FLIP TABLE: for each finished job directory given (job.json + out/design.bin), its
// stored designs re-finished WITHOUT re-optimizing (refinish_job): one line per accepted
// version, the unfinished file and the finished file each re-certified.
//   cmake --build build --target finish_flip_probe
//   ./build/finish_flip_probe <out_root> <job_dir>...
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"

#include <cstdio>
#include <string>

int main(int argc, char** argv) {
  using namespace topopt;
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <out_root> <job_dir>...\n", argv[0]);
    return 2;
  }
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  for (int i = 2; i < argc; ++i) {
    const std::string dir = argv[i];
    std::string id = dir;
    while (!id.empty() && id.back() == '/') id.pop_back();
    id = id.substr(id.find_last_of('/') + 1).substr(0, 8);
    try {
      const JobDescription job = load_job_file(dir + "/job.json");
      for (const std::string& line : refinish_job(job, dir, dir + "/out/design.bin",
                                                  std::string(argv[1]) + "/" + id, materials, rules))
        std::printf("%s %s\n", id.c_str(), line.c_str());
    } catch (const std::exception& e) {
      std::printf("%s {\"error\": \"%s\"}\n", id.c_str(), e.what());
    }
    std::fflush(stdout);
  }
  return 0;
}
