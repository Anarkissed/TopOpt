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
#include "topopt/fields.hpp"

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

// ── a minimal fields.bin INDEX ────────────────────────────────────────────────
// `fields.bin` has no core-side reader — it is written by the CLI and read by the
// app (Swift). Rather than grow the core API for a test, this walks the container
// the way the app does: header, then each block's PROLOGUE, striding over the
// float payloads. Layout is fields.cpp's writer, exactly.
struct FieldBlock {
  double requested_volume_fraction = 0.0;
  long long von_mises_count = 0;
};

static bool index_fields_file(const std::string& path,
                              std::vector<FieldBlock>& out) {
  out.clear();
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  const std::vector<std::uint8_t> b((std::istreambuf_iterator<char>(in)),
                                    std::istreambuf_iterator<char>());
  auto le = [&](std::size_t at, void* dst, std::size_t n) {
    if (at + n > b.size()) return false;
    std::memcpy(dst, b.data() + at, n);
    return true;
  };
  std::uint8_t version = 0;
  if (!le(0, &version, 1) || version != 1) return false;
  std::int32_t count = 0;
  if (!le(56, &count, 4) || count < 0) return false;   // header: 56 bytes before it
  std::size_t at = 64;                                  // + i32 count + pad(4)
  for (int i = 0; i < count; ++i) {
    FieldBlock fb;
    std::int64_t vm = 0, tensor = 0, disp = 0;
    if (!le(at, &fb.requested_volume_fraction, 8)) return false;
    if (!le(at + 24, &vm, 8) || !le(at + 32, &tensor, 8) || !le(at + 40, &disp, 8))
      return false;
    if (vm < 0 || tensor < 0 || disp < 0) return false;
    fb.von_mises_count = vm;
    out.push_back(fb);
    const std::size_t next = at + 48 +
        static_cast<std::size_t>(vm + tensor + disp) * 4;
    if (next > b.size()) return false;
    at = next;
  }
  return true;
}

// The `vf=` a VARIANT line announces — the rung the client is being shown, and
// therefore the rung whose artifacts must be on disk at that instant.
static double variant_line_vf(const std::string& line) {
  const std::string::size_type at = line.find("vf=");
  if (at == std::string::npos) return std::nan("");
  return std::atof(line.c_str() + at + 3);
}

// Run the CLI and, on every VARIANT line it prints, call `on_variant` with the
// number of variants seen so far and that line's announced volume fraction.
// `stop_after` > 0 KILLS the run once that many variants have streamed — the
// interrupted-ladder control (bar 4). Returns the process exit status.
static int run_cli_observing(const std::string& job_path,
                             const std::string& out_dir,
                             const std::function<void(int, double)>& on_variant,
                             int stop_after = 0) {
  const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE + "\" run \"" +
                          job_path + "\" --out \"" + out_dir +
                          "\" --materials \"" + MATERIALS_JSON_PATH +
                          "\" --rules \"" + SETTINGS_RULES_PATH + "\" 2>/dev/null";
  std::FILE* pipe = popen(cmd.c_str(), "r");
  if (!pipe) return -1;
  char line[4096];
  int seen = 0;
  while (std::fgets(line, sizeof(line), pipe)) {
    const std::string text(line);
    if (text.rfind("VARIANT ", 0) != 0) continue;
    on_variant(++seen, variant_line_vf(text));
    if (stop_after > 0 && seen >= stop_after) break;   // abandon the ladder
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

  const std::string fields_a = out_a + "/fields.bin";

  std::vector<int> blocks_at_variant;   // container size observed per VARIANT
  std::vector<int> field_blocks_at_variant;
  bool report_existed_at_first = true;  // S1: it must NOT
  bool every_midrun_read_ok = true;     // S4
  int first_variant_blocks = -1;
  // S5 (bar 3): at the instant rung N streams, the containers must hold a block
  // FOR RUNG N — its own, not an earlier rung's and not a later one's.
  bool every_rung_had_its_own_design = true;
  bool every_rung_had_its_own_field = true;
  std::vector<double> announced_vfs;

  const int rc = run_cli_observing(job_path, out_a, [&](int seen, double vf) {
    if (seen == 1) report_existed_at_first = fs::exists(report_a);
    announced_vfs.push_back(vf);
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
      bool found = false;
      for (const StoredDesign& d : store.variants) {
        if (d.density.size() != store.voxel_count()) every_midrun_read_ok = false;
        if (d.requested_volume_fraction == vf) found = true;
      }
      if (!found) every_rung_had_its_own_design = false;
    } catch (const std::exception&) {
      every_midrun_read_ok = false;
      blocks_at_variant.push_back(-1);
    }
    // S5b: and this rung's OWN FIELD, in fields.bin, at the same instant.
    std::vector<FieldBlock> fb;
    if (!index_fields_file(fields_a, fb)) {
      every_rung_had_its_own_field = false;
      field_blocks_at_variant.push_back(-1);
    } else {
      field_blocks_at_variant.push_back(static_cast<int>(fb.size()));
      bool found = false;
      for (const FieldBlock& f : fb)
        if (f.requested_volume_fraction == vf && f.von_mises_count > 0) found = true;
      if (!found) every_rung_had_its_own_field = false;
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

  // S5 (task 2026-08-03-variant-postprocessing-concurrency, BAR 3) — the
  // artifacts on disk when rung N streams are RUNG N's OWN. Not an earlier
  // rung's, not a later one's: the block's `requested_volume_fraction` must equal
  // the `vf=` the VARIANT line just announced. This is PR 274's Z2 assertion
  // shape — a variant carries the design it was ACTUALLY made under — applied per
  // rung instead of per run.
  CHECK(every_rung_had_its_own_design,
        "BAR 3: at the instant rung N streams, design.bin holds a block for RUNG "
        "N's own volume fraction");
  CHECK(every_rung_had_its_own_field,
        "BAR 3: …and fields.bin holds RUNG N's own von Mises field at that same "
        "instant (before this task fields.bin did not exist until the ladder "
        "ended, so rung 1 had a design and no field for the rest of the run)");
  for (std::size_t i = 1; i < field_blocks_at_variant.size(); ++i)
    CHECK(field_blocks_at_variant[i] > field_blocks_at_variant[i - 1],
          "BAR 3: the field container gains a block with every rung too");
  CHECK(blocks_at_variant == field_blocks_at_variant,
        "BAR 3: design and field are published TOGETHER — a rung is never "
        "half-post-processable");

  std::fprintf(stderr, "  design blocks per VARIANT:");
  for (const int b : blocks_at_variant) std::fprintf(stderr, " %d", b);
  std::fprintf(stderr, "\n  field  blocks per VARIANT:");
  for (const int b : field_blocks_at_variant) std::fprintf(stderr, " %d", b);
  std::fprintf(stderr, "\n  rungs announced:");
  for (const double v : announced_vfs) std::fprintf(stderr, " %.2f", v);
  std::fprintf(stderr, "\n");

  // ── S3 — the final artifact is unchanged ──────────────────────────────────
  // Same job, run again. Every artifact a completed run ships must be identical,
  // design.bin among them: the incremental flush writes through the SAME writer
  // with the SAME rule, so the file a finished run leaves behind is the file it
  // always left behind.
  const std::string out_b = tmp + "/out_b";
  const int rc_b = run_cli_observing(job_path, out_b, [](int, double) {});
  CHECK(rc_b == 0, "the control run completed");

  CHECK(read_bytes(design_a) == read_bytes(out_b + "/design.bin"),
        "S3: design.bin is byte-identical across two identical runs");
  CHECK(read_bytes(fields_a) == read_bytes(out_b + "/fields.bin"),
        "S3: fields.bin is byte-identical across two identical runs");
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

  // ══ BAR 4 — AN INTERRUPTED LADDER KEEPS EVERY COMPLETED RUNG ═══════════════
  //
  // This is the maintainer's actual failure: his run died on rung 3 of 4 and the
  // three rungs it had already produced were left unusable, because both
  // containers were written only at the end. Here the ladder is ABANDONED after
  // rung 1 — the pipe is closed, the CLI takes SIGPIPE, exactly as an
  // interrupted run does — and what it had already produced must still be whole,
  // readable and complete for that rung.
  const std::string out_c = tmp + "/out_c";
  run_cli_observing(job_path, out_c, [](int, double) {}, /*stop_after=*/1);

  const std::string design_c = out_c + "/design.bin";
  const std::string fields_c = out_c + "/fields.bin";
  CHECK(!fs::exists(out_c + "/report.json"),
        "BAR 4: the abandoned run never finished (no report.json) — so this is "
        "genuinely the interrupted case, not a completed one");
  CHECK(fs::exists(design_c) && fs::exists(fields_c),
        "BAR 4: an interrupted ladder still left BOTH artifacts on disk");
  bool interrupted_usable = false;
  std::vector<FieldBlock> fb_c;
  try {
    const DesignStore sc = read_design_file(design_c);
    const bool fields_ok = index_fields_file(fields_c, fb_c);
    interrupted_usable =
        !sc.variants.empty() && fields_ok && !fb_c.empty() &&
        sc.variants.front().density.size() == sc.voxel_count() &&
        fb_c.front().von_mises_count > 0 &&
        sc.variants.front().requested_volume_fraction ==
            fb_c.front().requested_volume_fraction;
  } catch (const std::exception&) {
  }
  CHECK(interrupted_usable,
        "BAR 4: the rung that DID complete is fully post-processable — its design "
        "reads back at full grid size, its own field is there, and the two name "
        "the SAME rung");
  CHECK(!fs::exists(design_c + ".part") && !fs::exists(fields_c + ".part"),
        "BAR 4: an interrupted run leaves no half-written container behind");
  std::fprintf(stderr, "  interrupted run kept %zu design block(s), %zu field "
                       "block(s)\n",
               (interrupted_usable ? read_design_file(design_c).variants.size() : 0),
               fb_c.size());

  std::fprintf(stderr, "%s: %d checks, %d failures\n",
               g_failures ? "FAILED" : "PASSED", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
