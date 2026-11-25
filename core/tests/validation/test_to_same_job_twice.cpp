// TO rebuild, repo test K (docs/design/to-rebuild/04-tests.md; rule 21).
//
// The same job run twice in one process, with an unrelated strength check solved
// in between, must write the same bytes. Every file of the two output folders is
// compared. run_info.json is left out: it records wall-clock times by design.
//
//   no argument : MEASURE. Lists any file that differs; fails only if a run fails.
//   --gate      : also fails when any compared file differs. ctest runs this form
//                 once the first measurement is on record (stage 1's switch may
//                 not flip before it passes; reviewer ruling 2026-11-25).
//
// The job is the maintainer's demo fixture, read in place and never modified.
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"

namespace fs = std::filesystem;

namespace {

std::string read_file(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

std::map<std::string, std::string> folder_bytes(const fs::path& root) {
  std::map<std::string, std::string> out;
  for (const auto& e : fs::recursive_directory_iterator(root))
    if (e.is_regular_file())
      out[fs::relative(e.path(), root).generic_string()] = read_file(e.path());
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  const std::string demo = DEMO_FIXTURE_DIR;
  const fs::path tmp = fs::path(CLI_TMP_DIR) / "to_same_job_twice";
  std::error_code ec;
  fs::remove_all(tmp, ec);
  fs::create_directories(tmp);
  int failures = 0;
  bool kept_for_reading = false;
  try {
    const topopt::JobDescription job = topopt::parse_job(read_file(demo + "/job.json"));
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(MATERIALS_JSON_PATH);
    const topopt::SettingsRules rules =
        topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
    const std::string a = (tmp / "run_a").string(), b = (tmp / "run_b").string();
    topopt::run_job(job, demo, a, materials, rules);
    // An unrelated solve between the two runs: whatever a solve leaves behind in
    // the process (solver caches, latches) must not reach the next run's bytes.
    topopt::analyze_job(job, demo, (tmp / "between").string(), materials, rules, "", {});
    topopt::run_job(job, demo, b, materials, rules);

    const auto fa = folder_bytes(a), fb = folder_bytes(b);
    int compared = 0, differ = 0;
    for (const auto& kv : fa) {
      if (kv.first == "run_info.json") continue;
      const auto it = fb.find(kv.first);
      if (it == fb.end()) {
        std::printf("only in the first run:  %s\n", kv.first.c_str());
        ++differ;
        continue;
      }
      ++compared;
      if (it->second != kv.second) {
        std::printf("differs:                %s (%zu vs %zu bytes)\n", kv.first.c_str(),
                    kv.second.size(), it->second.size());
        // Where it first differs, with a little of each side, so the cause can be
        // named from the log alone (a time, an id, or the geometry itself).
        const std::string &x = kv.second, &y = it->second;
        std::size_t at = 0;
        while (at < x.size() && at < y.size() && x[at] == y[at]) ++at;
        auto show = [&](const std::string& t) {
          const std::size_t from = at > 40 ? at - 40 : 0;
          std::string o = t.substr(from, 80);
          for (char& c : o)
            if (c < 32 || c > 126) c = '.';
          return o;
        };
        std::printf("    first differs at byte %zu\n    first : %s\n    second: %s\n", at,
                    show(x).c_str(), show(y).c_str());
        ++differ;
      }
    }
    for (const auto& kv : fb)
      if (kv.first != "run_info.json" && fa.find(kv.first) == fa.end()) {
        std::printf("only in the second run: %s\n", kv.first.c_str());
        ++differ;
      }
    std::printf("[test K] %d files compared, %d differ\n", compared, differ);
    kept_for_reading = differ > 0;
    if (compared == 0) ++failures;
    if (gate && differ > 0) ++failures;
  } catch (const std::exception& e) {
    std::printf("[test K] a run failed: %s\n", e.what());
    ++failures;
  }
  if (kept_for_reading)
    std::printf("[test K] both runs kept for reading in %s\n", tmp.string().c_str());
  else
    fs::remove_all(tmp, ec);
  std::printf("[test K] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
