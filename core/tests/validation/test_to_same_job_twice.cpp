// TO rebuild, repo test K (docs/design/to-rebuild/04-tests.md; rule 21).
//
// The same job run twice in one process, with an unrelated strength check solved
// in between, must write the same bytes. Every file of the two output folders is
// compared. run_info.json is left out: it records wall-clock times by design.
//
// Three things are known to differ without the result differing (first
// measurement, 2026-11-25) and are blanked before comparing, and nothing else:
//   - a print file (.3mf) is compared by its unpacked model, with the random
//     p:UUID ids the 3MF library stamps on every write blanked;
//   - a number whose key ends in _seconds or _wall_s (a wall-clock time);
//   - the run's own output folder where a file names it.
//   --compare A B : skip the runs and compare two kept output folders.
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
#include <regex>
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

// The unpacked model of a .3mf (a zip), through the system's unzip.
std::string unpacked_model(const fs::path& p) {
  const std::string cmd = "unzip -p '" + p.string() + "' 3D/3dmodel.model 2>/dev/null";
  std::string out;
  if (FILE* f = popen(cmd.c_str(), "r")) {
    char buf[1 << 16];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    pclose(f);
  }
  return out;
}

void replace_all(std::string& t, const std::string& from, const std::string& to) {
  if (from.empty()) return;
  for (std::size_t at = 0; (at = t.find(from, at)) != std::string::npos; at += to.size())
    t.replace(at, from.size(), to);
}

std::string comparable(const fs::path& p, const fs::path& root) {
  const std::string ext = p.extension().string();
  if (ext == ".3mf") {
    std::string m = unpacked_model(p);
    if (m.empty()) return read_file(p);  // not unpacked: compare the raw bytes
    static const std::regex uuid("p:UUID=\"[^\"]*\"");
    return std::regex_replace(m, uuid, "p:UUID=\"\"");
  }
  if (ext == ".json" || ext == ".meta") {
    std::string t = read_file(p);
    replace_all(t, root.string(), "<out>");
    static const std::regex timed("((_seconds|_wall_s)\"?:?\\s+)[-+0-9.eE]+");
    return std::regex_replace(t, timed, "$1<time>");
  }
  return read_file(p);
}

std::map<std::string, std::string> folder_bytes(const fs::path& root) {
  std::map<std::string, std::string> out;
  for (const auto& e : fs::recursive_directory_iterator(root))
    if (e.is_regular_file())
      out[fs::relative(e.path(), root).generic_string()] = comparable(e.path(), root);
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  const std::string demo = DEMO_FIXTURE_DIR;
  const bool compare_only = argc > 3 && std::strcmp(argv[1], "--compare") == 0;
  const fs::path tmp = fs::path(CLI_TMP_DIR) / "to_same_job_twice";
  std::error_code ec;
  if (!compare_only) {
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp);
  }
  int failures = 0;
  bool kept_for_reading = false;
  try {
    const std::string a = compare_only ? argv[2] : (tmp / "run_a").string();
    const std::string b = compare_only ? argv[3] : (tmp / "run_b").string();
    if (!compare_only) {
      const topopt::JobDescription job = topopt::parse_job(read_file(demo + "/job.json"));
      const topopt::MaterialLibrary materials =
          topopt::load_materials_file(MATERIALS_JSON_PATH);
      const topopt::SettingsRules rules =
          topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
      topopt::run_job(job, demo, a, materials, rules);
      // An unrelated solve between the two runs: whatever a solve leaves behind in
      // the process (solver caches, latches) must not reach the next run's bytes.
      topopt::analyze_job(job, demo, (tmp / "between").string(), materials, rules, "", {});
      topopt::run_job(job, demo, b, materials, rules);
    }
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
    kept_for_reading = differ > 0 || compare_only;
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
