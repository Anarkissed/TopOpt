// M6.2 job-file schema test (`topopt-cli run job.json`).
//
// The committed demo fixture core/tests/fixtures/demo/job.json DEFINES the CLI
// job schema (its _comment; DECISIONS.md 2026-07-09): the parser must implement
// exactly its keys and reject unknown keys or missing required ones with a
// diagnostic, with the same strictness as the materials loader. Keys beginning
// with '_' are maintainer comments and are ignored at every object level (the
// fixture itself carries _comment / _fixture_note / _gravity_note /
// _output_note).
//
// parse_job / load_job_file are pure C++/std (no OCCT, no Eigen, no lib3mf), so
// this test builds and runs in every configuration. Running the job (run_job)
// is the OCCT+Eigen-gated integration test in tests/validation/test_cli.cpp.
// No third-party test framework (ARCHITECTURE §4): the self-contained CHECK
// harness the other tests use.

#include "topopt/job.hpp"

#include <cmath>
#include <cstdio>
#include <string>

using topopt::JobDescription;
using topopt::JobError;
using topopt::load_job_file;
using topopt::parse_job;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

// Expect parse_job(text) to throw JobError.
static void check_rejects(const std::string& text, const char* msg) {
  bool threw = false;
  try {
    parse_job(text);
  } catch (const JobError&) {
    threw = true;
  }
  CHECK(threw, msg);
}

// A minimal valid job document. Each rejection test below is a single
// mutation of this baseline, so the failure is attributable to that mutation.
static std::string valid_job() {
  return R"({
  "model": "part.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "fixture_faces": [ { "kind": "cylindrical", "radius_mm": 2.5 } ],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.7, 0.5, 0.3],
  "margin_stop": 1.5,
  "simp": { "max_iterations": 30 },
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" }
})";
}

// Replace the first occurrence of `from` in valid_job() with `to`. The needle
// must exist — a typo in a test mutation should fail loudly, not silently
// test the unmodified baseline.
static std::string mutate(const std::string& from, const std::string& to) {
  std::string s = valid_job();
  const std::string::size_type at = s.find(from);
  if (at == std::string::npos) {
    std::fprintf(stderr, "test bug: mutation needle not found: %s\n",
                 from.c_str());
    ++g_failures;
    return s;
  }
  return s.replace(at, from.size(), to);
}

// --- The baseline parses and every field lands where it should --------------
static void test_valid_baseline() {
  const JobDescription j = parse_job(valid_job());
  CHECK(j.model == "part.step", "baseline: model");
  CHECK(j.material == "PLA", "baseline: material");
  CHECK(j.mode == "minimize_plastic", "baseline: mode");
  CHECK(j.resolution == 48, "baseline: resolution");
  CHECK(j.fixture_faces.size() == 1, "baseline: one fixture-face selector");
  CHECK(j.fixture_faces[0].kind == "cylindrical", "baseline: selector kind");
  CHECK(j.fixture_faces[0].radius_mm == 2.5, "baseline: selector radius");
  CHECK(j.gravity.direction.x == 0.0 && j.gravity.direction.y == 0.0 &&
            j.gravity.direction.z == -1.0,
        "baseline: gravity direction");
  CHECK(j.gravity.magnitude_mm_s2 == 9810.0, "baseline: gravity magnitude");
  CHECK(j.ladder.size() == 3 && j.ladder[0] == 0.7 && j.ladder[1] == 0.5 &&
            j.ladder[2] == 0.3,
        "baseline: ladder");
  CHECK(j.margin_stop == 1.5, "baseline: margin_stop");
  CHECK(j.simp_max_iterations == 30, "baseline: simp.max_iterations");
  CHECK(j.output.report == "report.json", "baseline: output.report");
  CHECK(j.output.mesh_format == "3mf", "baseline: output.mesh_format");
  CHECK(j.output.mesh_prefix == "variant", "baseline: output.mesh_prefix");
}

// --- The committed demo fixture parses and matches its on-disk values -------
// (fixture values per core/tests/fixtures/demo/job.json; the fixture is
// consumed, never modified — DECISIONS.md 2026-07-03.)
static void test_demo_fixture() {
  const JobDescription j =
      load_job_file(std::string(DEMO_FIXTURE_DIR) + "/job.json");
  CHECK(j.model == "l-bracket.step", "demo: model is l-bracket.step");
  CHECK(j.material == "PLA", "demo: material is PLA");
  CHECK(j.mode == "minimize_plastic", "demo: mode");
  CHECK(j.resolution == 48, "demo: resolution 48");
  CHECK(j.fixture_faces.size() == 1, "demo: one selector");
  CHECK(j.fixture_faces.size() == 1 &&
            j.fixture_faces[0].kind == "cylindrical" &&
            j.fixture_faces[0].radius_mm == 2.5,
        "demo: cylindrical r=2.5 selector");
  CHECK(j.gravity.direction.x == 0.0 && j.gravity.direction.y == 0.0 &&
            j.gravity.direction.z == -1.0,
        "demo: gravity pulls -Z");
  CHECK(j.gravity.magnitude_mm_s2 == 9810.0, "demo: gravity 9810 mm/s^2");
  CHECK(j.ladder.size() == 3 && j.ladder[0] == 0.7 && j.ladder[1] == 0.5 &&
            j.ladder[2] == 0.3,
        "demo: ladder [0.7, 0.5, 0.3]");
  CHECK(j.margin_stop == 1.5, "demo: margin_stop 1.5");
  CHECK(j.simp_max_iterations == 30, "demo: simp.max_iterations 30");
  CHECK(j.output.report == "report.json" && j.output.mesh_format == "3mf" &&
            j.output.mesh_prefix == "variant",
        "demo: output block");
}

// --- Underscore-prefixed keys are comments, ignored at every level ----------
static void test_underscore_comments() {
  std::string s = mutate("\"model\"", "\"_note\": \"top-level comment\", \"model\"");
  s.replace(s.find("\"kind\""), 6, "\"_why\": \"selector comment\", \"kind\"");
  const JobDescription j = parse_job(s);
  CHECK(j.model == "part.step", "underscore keys ignored, real keys parsed");
}

// --- Unknown keys rejected (schema strictness, per the fixture _comment) ----
static void test_unknown_keys() {
  check_rejects(mutate("\"model\"", "\"extra\": 1, \"model\""),
                "unknown top-level key rejected");
  check_rejects(mutate("\"kind\"", "\"depth\": 2, \"kind\""),
                "unknown selector key rejected");
  check_rejects(mutate("\"direction\"", "\"units\": \"si\", \"direction\""),
                "unknown gravity key rejected");
  check_rejects(mutate("\"max_iterations\"", "\"penalty\": 3, \"max_iterations\""),
                "unknown simp key rejected");
  check_rejects(mutate("\"report\"", "\"gcode\": \"a.gcode\", \"report\""),
                "unknown output key rejected");
}

// --- Missing required keys rejected ------------------------------------------
static void test_missing_required() {
  check_rejects(mutate("\"model\": \"part.step\",", ""), "missing model rejected");
  check_rejects(mutate("\"material\": \"PLA\",", ""), "missing material rejected");
  check_rejects(mutate("\"mode\": \"minimize_plastic\",", ""),
                "missing mode rejected");
  check_rejects(mutate("\"resolution\": 48,", ""), "missing resolution rejected");
  check_rejects(
      mutate("\"fixture_faces\": [ { \"kind\": \"cylindrical\", \"radius_mm\": 2.5 } ],",
             ""),
      "missing fixture_faces rejected");
  check_rejects(
      mutate("\"gravity\": { \"direction\": [0.0, 0.0, -1.0], \"magnitude_mm_s2\": 9810.0 },",
             ""),
      "missing gravity rejected");
  check_rejects(mutate("\"ladder\": [0.7, 0.5, 0.3],", ""),
                "missing ladder rejected");
  check_rejects(mutate("\"margin_stop\": 1.5,", ""), "missing margin_stop rejected");
  check_rejects(
      mutate("\"output\": { \"report\": \"report.json\", \"mesh_format\": \"3mf\", \"mesh_prefix\": \"variant\" }",
             "\"output\": { \"mesh_format\": \"3mf\", \"mesh_prefix\": \"variant\" }"),
      "missing output.report rejected");
  check_rejects(mutate("\"radius_mm\": 2.5", "\"_x\": 0"),
                "selector missing radius_mm rejected");
  check_rejects(mutate("\"magnitude_mm_s2\": 9810.0", "\"_x\": 0"),
                "gravity missing magnitude rejected");

  // simp is OPTIONAL (defaults apply when absent) — removing it still parses.
  const JobDescription j =
      parse_job(mutate("\"simp\": { \"max_iterations\": 30 },", ""));
  CHECK(j.simp_max_iterations == 0, "absent simp block -> 0 (driver default)");
  // ... and an empty simp block is also fine.
  const JobDescription j2 =
      parse_job(mutate("{ \"max_iterations\": 30 }", "{ }"));
  CHECK(j2.simp_max_iterations == 0, "empty simp block -> 0 (driver default)");
}

// --- Type and value rules -----------------------------------------------------
static void test_types_and_values() {
  check_rejects(mutate("\"part.step\"", "42"), "non-string model rejected");
  check_rejects(mutate("\"part.step\"", "\"\""), "empty model rejected");
  check_rejects(mutate("\"PLA\"", "\"\""), "empty material rejected");
  check_rejects(mutate("\"minimize_plastic\"", "\"maximize_plastic\""),
                "unsupported mode rejected");
  check_rejects(mutate("\"resolution\": 48", "\"resolution\": 48.5"),
                "non-integral resolution rejected");
  check_rejects(mutate("\"resolution\": 48", "\"resolution\": 0"),
                "resolution < 1 rejected");
  check_rejects(mutate("\"resolution\": 48", "\"resolution\": \"48\""),
                "string resolution rejected");

  check_rejects(mutate("[ { \"kind\": \"cylindrical\", \"radius_mm\": 2.5 } ]", "[ ]"),
                "empty fixture_faces rejected");
  check_rejects(mutate("[ { \"kind\": \"cylindrical\", \"radius_mm\": 2.5 } ]",
                       "{ \"kind\": \"cylindrical\", \"radius_mm\": 2.5 }"),
                "non-array fixture_faces rejected");
  check_rejects(mutate("\"cylindrical\"", "\"planar\""),
                "unsupported selector kind rejected");
  check_rejects(mutate("\"radius_mm\": 2.5", "\"radius_mm\": 0.0"),
                "non-positive selector radius rejected");
  check_rejects(mutate("\"radius_mm\": 2.5", "\"radius_mm\": \"2.5\""),
                "string selector radius rejected");

  check_rejects(mutate("[0.0, 0.0, -1.0]", "[0.0, 0.0]"),
                "2-component gravity direction rejected");
  check_rejects(mutate("[0.0, 0.0, -1.0]", "[0.0, 0.0, 0.0]"),
                "zero gravity direction rejected");
  check_rejects(mutate("[0.0, 0.0, -1.0]", "[0.0, 0.0, \"down\"]"),
                "non-numeric gravity direction rejected");
  check_rejects(mutate("\"magnitude_mm_s2\": 9810.0", "\"magnitude_mm_s2\": 0.0"),
                "non-positive gravity magnitude rejected");

  check_rejects(mutate("[0.7, 0.5, 0.3]", "[]"), "empty ladder rejected");
  check_rejects(mutate("[0.7, 0.5, 0.3]", "[0.7, 0.5, 1.3]"),
                "ladder entry > 1 rejected");
  check_rejects(mutate("[0.7, 0.5, 0.3]", "[0.7, 0.5, 0.0]"),
                "ladder entry <= 0 rejected");
  check_rejects(mutate("[0.7, 0.5, 0.3]", "[0.3, 0.5, 0.7]"),
                "ascending ladder rejected");
  check_rejects(mutate("[0.7, 0.5, 0.3]", "[0.7, 0.7, 0.3]"),
                "non-strictly-descending ladder rejected");

  check_rejects(mutate("\"margin_stop\": 1.5", "\"margin_stop\": -1.0"),
                "negative margin_stop rejected");
  check_rejects(mutate("\"margin_stop\": 1.5", "\"margin_stop\": \"1.5\""),
                "string margin_stop rejected");
  // margin_stop 0 disables the stop (pipeline.hpp) and is valid.
  CHECK(parse_job(mutate("\"margin_stop\": 1.5", "\"margin_stop\": 0.0"))
                .margin_stop == 0.0,
        "margin_stop 0 accepted (stop disabled)");

  check_rejects(mutate("\"max_iterations\": 30", "\"max_iterations\": 0"),
                "simp.max_iterations < 1 rejected");
  check_rejects(mutate("\"max_iterations\": 30", "\"max_iterations\": 30.5"),
                "non-integral simp.max_iterations rejected");

  check_rejects(mutate("\"3mf\"", "\"obj\""), "unsupported mesh_format rejected");
  check_rejects(mutate("\"report.json\"", "\"\""), "empty output.report rejected");
  check_rejects(mutate("\"variant\"", "\"\""), "empty mesh_prefix rejected");
  // "stl" is the secondary format (ARCHITECTURE §4) and is valid.
  CHECK(parse_job(mutate("\"3mf\"", "\"stl\"")).output.mesh_format == "stl",
        "mesh_format stl accepted");
}

// --- Malformed documents ------------------------------------------------------
static void test_malformed() {
  check_rejects("", "empty document rejected");
  check_rejects("[1, 2]", "non-object top level rejected");
  check_rejects(valid_job() + "junk", "trailing characters rejected");
  check_rejects(mutate("\"margin_stop\": 1.5,", "\"margin_stop\": 1.5"),
                "missing comma rejected");

  bool threw = false;
  try {
    load_job_file(std::string(DEMO_FIXTURE_DIR) + "/does_not_exist_98765.json");
  } catch (const JobError&) {
    threw = true;
  }
  CHECK(threw, "load_job_file on a missing file throws JobError");
}

// --- Loadcase "clearances" block (handoff 100) ------------------------------
// A loads job may carry "Keep clear" regions; each is a raw face id + kind
// ("bolt"/"face") + optional editable mm distances. The self-weight keys are
// dropped (loadcase mode). Proves the block parses, populates job.loads.clearances,
// and rejects a bad kind / negative distance / non-integer face id.
static void test_clearances() {
  const std::string base = R"({
  "model": "part.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "loads": {
    "anchor_face_ids": [8, 9],
    "groups": [ { "face_ids": [0], "force": [0, 0, -50] } ],
    "clearances": [
      { "face_id": 8, "kind": "bolt", "concentric_margin_mm": 2.5, "axial_clearance_mm": 5.0 },
      { "face_id": 3, "kind": "face", "slab_depth_mm": 4.0 },
      { "face_id": 9, "kind": "bolt" }
    ]
  }
})";
  const JobDescription j = parse_job(base);
  CHECK(j.loads.present, "clearances: loads block present");
  CHECK(j.loads.clearances.size() == 3, "clearances: 3 entries parsed");
  CHECK(j.loads.clearances[0].face_id == 8 && j.loads.clearances[0].kind == "bolt",
        "clearances: bolt face id + kind");
  CHECK(j.loads.clearances[0].concentric_margin_mm == 2.5 &&
            j.loads.clearances[0].axial_clearance_mm == 5.0,
        "clearances: bolt distances");
  CHECK(j.loads.clearances[1].kind == "face" &&
            j.loads.clearances[1].slab_depth_mm == 4.0,
        "clearances: face slab depth");
  CHECK(j.loads.clearances[2].concentric_margin_mm == 0.0,
        "clearances: omitted distance defaults to 0 (run_job fills the suggestion)");

  auto with_clearance = [&](const std::string& entry) {
    std::string s = base;
    const std::string needle = "\"clearances\": [";
    const auto at = s.find(needle);
    return s.replace(at + needle.size(), 0, entry + ",");
  };
  check_rejects(with_clearance(R"({ "face_id": 8, "kind": "slot" })"),
                "clearances: unknown kind rejected");
  check_rejects(with_clearance(R"({ "face_id": -1, "kind": "bolt" })"),
                "clearances: negative face id rejected");
  check_rejects(with_clearance(R"({ "face_id": 8, "kind": "face", "slab_depth_mm": -1 })"),
                "clearances: negative slab depth rejected");
  check_rejects(with_clearance(R"({ "face_id": 8, "kind": "bolt", "bogus": 1 })"),
                "clearances: unknown key rejected");
  check_rejects(with_clearance(R"({ "kind": "bolt" })"),
                "clearances: missing face_id rejected");
}

int main() {
  test_valid_baseline();
  test_demo_fixture();
  test_underscore_comments();
  test_unknown_keys();
  test_missing_required();
  test_types_and_values();
  test_malformed();
  test_clearances();

  if (g_failures == 0) {
    std::printf("job schema (M6.2): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "job schema (M6.2): %d of %d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
