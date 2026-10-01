// test_run_info_fingerprint — ★ EVERY SUBCOMMAND THAT WRITES A RECEIPT STAMPS THE
// BINARY THAT WROTE IT (reviewer, 2026-10-01).
//
// `run_info.json` exists to answer one question — "which core did that run use" —
// and main.cpp:371 says so. For two of the three subcommands that write one, it
// could not:
//
//     main.cpp:354   analyze          -> returns
//     main.cpp:359   preflight        -> returns   (writes no run_info)
//     main.cpp:362   lattice-variant  -> returns
//     main.cpp:386   obs.fingerprint = TOPOPT_BUILD_FINGERPRINT;
//     main.cpp:387   obs.build_time  = __DATE__ " " __TIME__;
//
// `analyze` and `lattice-variant` return 24 lines before those assignments, so
// `RunObservability`'s defaults survived into the file: `fingerprint = "unknown"`
// (job.hpp:1178) and an empty `build_time`. Nothing was wrong with the build — the
// value was simply never handed to the path that writes the receipt. `lattice-variant`
// is the app's relattice path, so every relattice receipt in production carried it.
//
// ★ THE ASSERTION IS AGAINST THE BINARY'S OWN --version, not against a literal. A test
// that pinned a particular SHA would fail on every commit; a test that only checked
// "not unknown" would pass on a typo. The binary announces its fingerprint on one
// parseable line, and the receipt must agree with it.
//
// ★ AND IT WAS PROVED RED BEFORE THE FIX: on today's code both subcommands write the
// literal string "unknown", so all four assertions below fail.
//
// Self-contained CHECK harness (ARCHITECTURE §4); CLI as a subprocess, the
// test_cli / test_lattice_variant pattern.

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static std::string read_file(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static void write_file(const std::string& p, const std::string& t) {
  std::ofstream out(p, std::ios::binary);
  out << t;
}

// The string after "\"key\": \"" up to the closing quote; "" when absent.
static std::string json_str(const std::string& s, const std::string& key) {
  const std::string pat = "\"" + key + "\": \"";
  const std::string::size_type at = s.find(pat);
  if (at == std::string::npos) return "";
  const std::string::size_type b = at + pat.size();
  const std::string::size_type e = s.find('"', b);
  if (e == std::string::npos) return "";
  return s.substr(b, e - b);
}

// `topopt-cli --version` prints one line: "topopt-cli version=X fingerprint=Y".
static std::string binary_fingerprint() {
  const std::string out = std::string(CLI_TMP_DIR) + "/fp_version.txt";
  const std::string cmd =
      std::string("\"") + TOPOPT_CLI_EXE + "\" --version > \"" + out + "\" 2>/dev/null";
  if (std::system(cmd.c_str()) != 0) return "";
  const std::string text = read_file(out);
  const std::string pat = "fingerprint=";
  const std::string::size_type at = text.find(pat);
  if (at == std::string::npos) return "";
  std::string v = text.substr(at + pat.size());
  while (!v.empty() && (v.back() == '\n' || v.back() == '\r' || v.back() == ' '))
    v.pop_back();
  return v;
}

// Run a subcommand and return the run_info.json it wrote (empty when none).
static std::string run_and_read_run_info(const char* verb, const std::string& job,
                                         const std::string& out_dir) {
  const std::string cmd = std::string("rm -rf \"") + out_dir + "\" && mkdir -p \"" +
                          out_dir + "\" && \"" + TOPOPT_CLI_EXE + "\" " + verb +
                          " \"" + job + "\" --out \"" + out_dir +
                          "\" > \"" + out_dir + "/stdout.txt\" 2> \"" + out_dir +
                          "/stderr.txt\"";
  const int rc = std::system(cmd.c_str());
  if (rc != 0) {
    std::fprintf(stderr, "  %s exited %d; stderr tail:\n", verb, rc);
    const std::string err = read_file(out_dir + "/stderr.txt");
    std::fprintf(stderr, "%s\n", err.size() > 700 ? err.substr(err.size() - 700).c_str()
                                                  : err.c_str());
  }
  return read_file(out_dir + "/run_info.json");
}

int main() {
  const std::string tmp = CLI_TMP_DIR;
  const std::string fp = binary_fingerprint();
  CHECK(!fp.empty(), "the binary must print a parseable fingerprint on --version");
  CHECK(fp != "unknown",
        "the BINARY's own fingerprint must not be \"unknown\" — if it is, this build "
        "has no git SHA and the test below cannot distinguish the defect from the "
        "build (configure in a git checkout)");
  std::printf("  binary fingerprint: %s\n", fp.c_str());

  // ── 1. lattice-variant — the app's relattice path ───────────────────────────
  {
    const std::string info = run_and_read_run_info(
        "lattice-variant", std::string(ORGANIC_FIXTURE_DIR) + "/dead_parity.json",
        tmp + "/fp_lattice_variant");
    CHECK(!info.empty(), "lattice-variant must write a run_info.json");
    const std::string got = json_str(info, "fingerprint");
    const std::string bt = json_str(info, "build_time");
    char msg[320];
    std::snprintf(msg, sizeof msg,
                  "lattice-variant: run_info fingerprint is \"%s\", the binary's is "
                  "\"%s\" — the receipt must name the binary that wrote it",
                  got.c_str(), fp.c_str());
    CHECK(got == fp, msg);
    CHECK(got != "unknown",
          "lattice-variant: run_info fingerprint must never be \"unknown\"");
    CHECK(!bt.empty(), "lattice-variant: run_info build_time must not be empty");
  }

  // ── 2. analyze — writes a run_info too, and has the same gap ────────────────
  // ★ ONLY ON THE GRADED PATH. `analyze_job`'s write site (run_job.cpp:9442) sits
  // inside `if (job.grading.present)` (:9157), whose own comment says so: "Absent ->
  // this block is skipped, no run_info is written". My first version of this job had
  // no grading block, wrote no run_info, and the arm failed for the wrong reason --
  // which is what mapping a write site to its function without RUNNING it buys you.
  // So the job below carries a grading block, and that is the path the app's
  // re-certification uses.
  {
    const std::string job = tmp + "/fp_analyze.json";
    write_file(job,
               std::string("{\n  \"model\": \"") + ORGANIC_FIXTURE_DIR +
                   "/dead_parity_tab.stl\",\n"
                   "  \"material\": \"PLA\",\n"
                   "  \"mode\": \"analyze\",\n"
                   "  \"resolution\": 32,\n"
                   "  \"output\": { \"mesh_format\": \"stl\", \"report\": "
                   "\"report.json\", \"mesh_prefix\": \"a\" },\n"
                   "  \"loads\": { \"anchor_face_ids\": [2], \"groups\": [ "
                   "{ \"face_ids\": [9], \"force\": [0.0, 0.0, -400.0] } ],\n"
                   "    \"minimize_plastic\": false, \"build_dir\": [0, 0, 1] },\n"
                   "  \"grading\": { \"cell_mm\": 6.0, "
                   "\"min_extrudable_width_mm\": 0.45, \"topology\": \"octet\" }\n}\n");
    const std::string info =
        run_and_read_run_info("analyze", job, tmp + "/fp_analyze");
    CHECK(!info.empty(), "analyze must write a run_info.json");
    if (!info.empty()) {
      const std::string got = json_str(info, "fingerprint");
      char msg[320];
      std::snprintf(msg, sizeof msg,
                    "analyze: run_info fingerprint is \"%s\", the binary's is \"%s\"",
                    got.c_str(), fp.c_str());
      CHECK(got == fp, msg);
      CHECK(got != "unknown",
            "analyze: run_info fingerprint must never be \"unknown\"");
      CHECK(!json_str(info, "build_time").empty(),
            "analyze: run_info build_time must not be empty");
    }
  }

  if (g_failures == 0) {
    std::printf("run_info fingerprint: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "run_info fingerprint: %d of %d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
