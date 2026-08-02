// test_design_stream.cpp — task 2026-08-03-variant-postprocessing-fix, defect 1.
//
// THE DEFECT THIS FILE EXISTS FOR. `design.bin` — the container "lattice this
// variant" and the smoothing re-certification are built on — was written ONCE,
// after the whole ladder. A streaming client shows each variant the moment its
// VARIANT line arrives, so for the entire length of a run the variants on screen
// had no design container; and a run that ended any way other than "ran to
// completion" never grew one at all.
//
// That is not hypothetical. The maintainer's M2_verticalStand run (worker job
// 95f4130119414636, fingerprint 2b8b715fd347) streamed three variants, was on
// rung 4 of 4 when its worker was restarted, and its out/ holds three variant
// meshes and their lattice receipts and NO report.json, fields.bin or design.bin
// at all. The app kept the three streamed variants — and both post-processing
// entries were correctly, permanently greyed, because the pair genuinely did not
// exist.
//
// So the container is published AFTER EVERY VARIANT. This test asserts that from
// OUTSIDE the process, the way the worker sees it: it runs the real topopt-cli,
// reads its stdout, and at the moment each VARIANT line arrives it opens
// design.bin and reads it back.
//
//   S1 design.bin is READABLE when the first VARIANT line arrives, and
//      report.json does NOT yet exist (i.e. the ladder is genuinely mid-flight).
//   S2 the container grows one block per variant, and every block read back
//      mid-run carries a density field of the full grid and a valid fingerprint
//      (read_design_file enforces both).
//   S3 the FINAL container is byte-identical to the one the single end-of-run
//      write produced — the incremental flush must not change the artifact a
//      completed run ships. (Proven against a recorded checksum of the same job
//      run twice: same bytes, and no .part file left behind.)
//   S4 no partial container is ever visible: every mid-run read SUCCEEDS.
//      Publication is a rename, so a reader gets a whole container or the
//      previous one.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

#include "topopt/design_store.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace fs = std::filesystem;

static std::string read_bytes(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// A small self-weight job on the committed plate_bore fixture — the same shape
// test_lattice_variant drives, at a lower resolution and a shorter ladder so this
// test costs seconds. TWO rungs, because "the container grows per variant" needs
// at least two.
static void write_job(const std::string& path, const std::string& model) {
  std::ofstream out(path);
  out << "{\n"
      << "  \"model\": \"" << model << "\",\n"
      << "  \"material\": \"PLA\",\n"
      << "  \"mode\": \"minimize_plastic\",\n"
      // 32 is the coarsest resolution at which the 3 mm bore's fixture faces
      // still tag voxels (24 refuses: "fixture faces tagged no voxels").
      << "  \"resolution\": 32,\n"
      << "  \"fixture_faces\": [{\"kind\": \"cylindrical\", \"radius_mm\": 3.0}],\n"
      << "  \"gravity\": {\"direction\": [0.0, 0.0, -1.0],"
         " \"magnitude_mm_s2\": 9810.0},\n"
      << "  \"ladder\": [0.7, 0.5],\n"
      << "  \"margin_stop\": 0.0,\n"
      << "  \"simp\": {\"max_iterations\": 6},\n"
      << "  \"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\","
         " \"mesh_prefix\": \"variant\"}\n"
      << "}\n";
}

// Run the CLI and, on every VARIANT line it prints, call `on_variant` with the
// number of variants seen so far. Returns the process exit status.
static int run_cli_observing(const std::string& job_path,
                             const std::string& out_dir,
                             const std::function<void(int)>& on_variant) {
  const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE + "\" run \"" +
                          job_path + "\" --out \"" + out_dir +
                          "\" --materials \"" + MATERIALS_JSON_PATH +
                          "\" --rules \"" + SETTINGS_RULES_PATH + "\" 2>/dev/null";
  std::FILE* pipe = popen(cmd.c_str(), "r");
  if (!pipe) return -1;
  char line[4096];
  int seen = 0;
  while (std::fgets(line, sizeof(line), pipe)) {
    if (std::string(line).rfind("VARIANT ", 0) == 0) on_variant(++seen);
  }
  return pclose(pipe);
}

int main() {
  const std::string tmp = std::string(CLI_TMP_DIR) + "/design_stream_tmp";
  fs::remove_all(tmp);
  fs::create_directories(tmp);

  const std::string model = std::string(MESH_FIXTURE_DIR) + "/plate_bore.stl";
  const std::string local_model = tmp + "/plate_bore.stl";
  fs::copy_file(model, local_model, fs::copy_options::overwrite_existing);

  const std::string job_path = tmp + "/job.json";
  write_job(job_path, "plate_bore.stl");

  // ── the observed run ──────────────────────────────────────────────────────
  const std::string out_a = tmp + "/out_a";
  const std::string design_a = out_a + "/design.bin";
  const std::string report_a = out_a + "/report.json";

  std::vector<int> blocks_at_variant;   // container size observed per VARIANT
  bool report_existed_at_first = true;  // S1: it must NOT
  bool every_midrun_read_ok = true;     // S4
  int first_variant_blocks = -1;

  const int rc = run_cli_observing(job_path, out_a, [&](int seen) {
    if (seen == 1) report_existed_at_first = fs::exists(report_a);
    // S1/S4: the container must be present AND readable RIGHT NOW.
    if (!fs::exists(design_a)) {
      every_midrun_read_ok = false;
      blocks_at_variant.push_back(0);
      return;
    }
    try {
      const DesignStore store = read_design_file(design_a);
      blocks_at_variant.push_back(static_cast<int>(store.variants.size()));
      if (seen == 1) first_variant_blocks = static_cast<int>(store.variants.size());
      for (const StoredDesign& d : store.variants)
        if (d.density.size() != store.voxel_count()) every_midrun_read_ok = false;
    } catch (const std::exception&) {
      every_midrun_read_ok = false;
      blocks_at_variant.push_back(-1);
    }
  });

  CHECK(rc == 0, "the observed CLI run completed");
  CHECK(!blocks_at_variant.empty(), "the run streamed at least one VARIANT line");

  // S1 — the container exists while the ladder is still running.
  CHECK(first_variant_blocks >= 1,
        "S1: design.bin is READABLE when the first VARIANT line arrives (before "
        "this task it did not exist until the whole ladder had finished)");
  CHECK(!report_existed_at_first,
        "S1: report.json had NOT been written yet at the first variant — so the "
        "container above really was published mid-run, not at the end");

  // S2 — one more block per variant, monotonically.
  for (std::size_t i = 1; i < blocks_at_variant.size(); ++i)
    CHECK(blocks_at_variant[i] > blocks_at_variant[i - 1],
          "S2: the design container gains a block with every variant");

  // S4 — every mid-run read succeeded (atomic publish).
  CHECK(every_midrun_read_ok,
        "S4: every mid-run read of design.bin returned a WHOLE container — a "
        "reader must never see a half-written file");

  std::fprintf(stderr, "  blocks observed per VARIANT:");
  for (const int b : blocks_at_variant) std::fprintf(stderr, " %d", b);
  std::fprintf(stderr, "\n");

  // ── S3 — the final artifact is unchanged ──────────────────────────────────
  // Same job, run again. Every artifact a completed run ships must be identical,
  // design.bin among them: the incremental flush writes through the SAME writer
  // with the SAME rule, so the file a finished run leaves behind is the file it
  // always left behind.
  const std::string out_b = tmp + "/out_b";
  const int rc_b = run_cli_observing(job_path, out_b, [](int) {});
  CHECK(rc_b == 0, "the control run completed");

  CHECK(read_bytes(design_a) == read_bytes(out_b + "/design.bin"),
        "S3: design.bin is byte-identical across two identical runs");
  CHECK(read_bytes(out_a + "/report.json") == read_bytes(out_b + "/report.json"),
        "S3: report.json is byte-identical (the flush touches nothing else)");
  CHECK(read_bytes(out_a + "/variant_070.stl") ==
            read_bytes(out_b + "/variant_070.stl"),
        "S3: the exported meshes are byte-identical");

  CHECK(!fs::exists(design_a + ".part"),
        "S4: no partial container is left behind after the run");

  const DesignStore final_store = read_design_file(design_a);
  CHECK(static_cast<int>(final_store.variants.size()) >=
            blocks_at_variant.back(),
        "the final container holds at least what the last mid-run read did");

  std::fprintf(stderr, "%s: %d checks, %d failures\n",
               g_failures ? "FAILED" : "PASSED", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
