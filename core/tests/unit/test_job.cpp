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

using topopt::JobClearance;
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
                "clearances: missing face_id AND geometry rejected");
}

// --- MANUAL (user-placed) clearance geometry (handoff group-editing) --------
// A hand-placed primitive has no B-rep face, so it carries its geometry inline
// under "geometry" instead of a "face_id". Proves the manual geometry parses for
// both kinds, that a clearance must carry EXACTLY ONE of face_id/geometry (the
// XOR rule), and — BAR B1 — that a manual entry and an auto entry of the same
// kind agree on the shared fields (kind + distances), differing ONLY in the
// geometry SOURCE (face_id vs geometry).
static void test_clearances_manual() {
  const std::string base = R"({
  "model": "part.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "loads": {
    "anchor_face_ids": [8],
    "groups": [ { "face_ids": [0], "force": [0, 0, -50] } ],
    "clearances": [
      { "kind": "bolt", "concentric_margin_mm": 2.5, "axial_clearance_mm": 5.0,
        "geometry": { "axis_point": [8, 8, 8], "axis_dir": [0, 0, 1],
                      "radius_mm": 2.0, "half_length_mm": 4.0 } },
      { "kind": "face", "slab_depth_mm": 3.0,
        "geometry": { "origin": [12, 6, 6], "normal": [1, 0, 0],
                      "half_u_mm": 2.0, "half_w_mm": 2.0 } },
      { "face_id": 8, "kind": "bolt", "concentric_margin_mm": 2.5, "axial_clearance_mm": 5.0 }
    ]
  }
})";
  const JobDescription j = parse_job(base);
  CHECK(j.loads.clearances.size() == 3, "manual: 3 entries parsed");

  const JobClearance& mb = j.loads.clearances[0];
  CHECK(mb.manual && mb.face_id == -1, "manual bolt: manual=true, no face id");
  CHECK(mb.kind == "bolt", "manual bolt: kind carried");
  CHECK(mb.axis_point.x == 8.0 && mb.axis_point.z == 8.0 &&
            mb.axis_dir.z == 1.0 && mb.radius_mm == 2.0 &&
            mb.half_length_mm == 4.0,
        "manual bolt: geometry fields round-trip");
  CHECK(mb.concentric_margin_mm == 2.5 && mb.axial_clearance_mm == 5.0,
        "manual bolt: distances carried the same as an auto bolt");

  const JobClearance& mf = j.loads.clearances[1];
  CHECK(mf.manual && mf.kind == "face", "manual face: manual=true, kind carried");
  CHECK(mf.origin.x == 12.0 && mf.normal.x == 1.0 && mf.half_u_mm == 2.0 &&
            mf.half_w_mm == 2.0,
        "manual face: geometry fields round-trip");
  CHECK(mf.slab_depth_mm == 3.0, "manual face: slab depth carried");

  // BAR B1 — field equivalence: the manual bolt (entry 0) and the auto bolt
  // (entry 2) live in the SAME clearances array and agree on EVERY shared field;
  // the only difference is the geometry source.
  const JobClearance& ab = j.loads.clearances[2];
  CHECK(!ab.manual && ab.face_id == 8, "auto bolt: face-id sourced");
  CHECK(ab.kind == mb.kind &&
            ab.concentric_margin_mm == mb.concentric_margin_mm &&
            ab.axial_clearance_mm == mb.axial_clearance_mm,
        "B1: manual and auto bolt share kind + distances (only source differs)");

  auto with_clearance = [&](const std::string& entry) {
    std::string s = base;
    const std::string needle = "\"clearances\": [";
    const auto at = s.find(needle);
    return s.replace(at + needle.size(), 0, entry + ",");
  };
  // XOR rule: both face_id AND geometry → rejected.
  check_rejects(
      with_clearance(
          R"({ "kind": "bolt", "face_id": 8, "geometry": { "axis_point": [0,0,0], "axis_dir": [0,0,1], "radius_mm": 1, "half_length_mm": 1 } })"),
      "manual: both face_id and geometry rejected (XOR)");
  // A bolt geometry missing a required sub-key → rejected.
  check_rejects(
      with_clearance(
          R"({ "kind": "bolt", "geometry": { "axis_point": [0,0,0], "axis_dir": [0,0,1], "radius_mm": 1 } })"),
      "manual: bolt geometry missing half_length_mm rejected");
  // A face geometry with a bolt sub-key → unknown key rejected (kind-scoped).
  check_rejects(
      with_clearance(
          R"({ "kind": "face", "geometry": { "origin": [0,0,0], "normal": [1,0,0], "half_u_mm": 1, "half_w_mm": 1, "radius_mm": 2 } })"),
      "manual: face geometry with a bolt key rejected");
  // Negative manual radius → rejected.
  check_rejects(
      with_clearance(
          R"({ "kind": "bolt", "geometry": { "axis_point": [0,0,0], "axis_dir": [0,0,1], "radius_mm": -1, "half_length_mm": 1 } })"),
      "manual: negative radius_mm rejected");
}

// Width-aware knockdown slicer metadata crossing the bridge (handoff
// 2026-07-26-width-aware-knockdown): loads.wall_loops / loads.wall_line_width_mm.
static void test_wall_loops() {
  const std::string base = R"({
  "model": "part.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "loads": {
    "anchor_face_ids": [8],
    "groups": [ { "face_ids": [0], "force": [0, 0, -50] } ],
    "wall_loops": 5,
    "wall_line_width_mm": 0.45,
    "wall_line_width_outer_mm": 0.42
  }
})";
  const JobDescription j = parse_job(base);
  CHECK(j.loads.wall_loops == 5, "wall_loops parsed");
  CHECK(j.loads.wall_line_width_mm == 0.45, "wall_line_width_mm (inner) parsed");
  CHECK(j.loads.wall_line_width_outer_mm == 0.42, "wall_line_width_outer_mm parsed");

  // Omitted → defaults (no override): 0 loops, negative widths (inner = core default,
  // outer = mirror inner).
  const std::string none = R"({
  "model": "part.step", "material": "PLA", "mode": "minimize_plastic", "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "loads": { "anchor_face_ids": [8], "groups": [ { "face_ids": [0], "force": [0,0,-50] } ] }
})";
  const JobDescription jn = parse_job(none);
  CHECK(jn.loads.wall_loops == 0, "wall_loops defaults to 0 (no rescue)");
  CHECK(jn.loads.wall_line_width_mm < 0.0, "wall_line_width_mm defaults to core default");
  CHECK(jn.loads.wall_line_width_outer_mm < 0.0,
        "wall_line_width_outer_mm defaults to mirror-inner sentinel");

  // A job that supplies ONLY the inner width still leaves outer at the mirror sentinel,
  // so it sizes t = loops·inner — byte-identical to a pre-split job.
  const std::string inner_only = R"({
  "model": "part.step", "material": "PLA", "mode": "minimize_plastic", "resolution": 48,
  "output": { "report": "report.json", "mesh_format": "3mf", "mesh_prefix": "variant" },
  "loads": { "anchor_face_ids": [8], "groups": [ { "face_ids": [0], "force": [0,0,-50] } ],
             "wall_loops": 3, "wall_line_width_mm": 0.5 }
})";
  const JobDescription ji = parse_job(inner_only);
  CHECK(ji.loads.wall_line_width_mm == 0.5, "inner width parsed without an outer");
  CHECK(ji.loads.wall_line_width_outer_mm < 0.0,
        "an omitted outer stays the mirror-inner sentinel (single-width back-compat)");

  auto replace_first = [&](const std::string& from, const std::string& to) {
    std::string s = base;
    const auto at = s.find(from);
    return s.replace(at, from.size(), to);
  };
  check_rejects(replace_first("\"wall_loops\": 5", "\"wall_loops\": -1"),
                "wall_loops: negative rejected");
  check_rejects(replace_first("\"wall_loops\": 5", "\"wall_loops\": 2.5"),
                "wall_loops: non-integer rejected");
  check_rejects(replace_first("\"wall_line_width_mm\": 0.45",
                              "\"wall_line_width_mm\": 0.0"),
                "wall_line_width_mm: zero rejected");
  check_rejects(replace_first("\"wall_line_width_outer_mm\": 0.42",
                              "\"wall_line_width_outer_mm\": 0.0"),
                "wall_line_width_outer_mm: zero rejected");
  check_rejects(replace_first("\"wall_line_width_outer_mm\": 0.42",
                              "\"wall_line_width_outer_mm\": 200.0"),
                "wall_line_width_outer_mm: over-100 rejected");
}

// --- Optional "lattice" block (handoff 2026-07-28-lattice-generation-production)
static void test_lattice_block() {
  // Absent => present false, defaults untouched (the byte-identical P1 posture).
  {
    const JobDescription j = parse_job(valid_job());
    CHECK(!j.lattice.present, "lattice: absent block => not present");
  }
  // A full block parses into every field.
  {
    const std::string s = mutate(
        "\"output\": { \"report\": \"report.json\", \"mesh_format\": \"3mf\", "
        "\"mesh_prefix\": \"variant\" }",
        "\"output\": { \"report\": \"report.json\", \"mesh_format\": \"3mf\", "
        "\"mesh_prefix\": \"variant\" },\n  \"lattice\": { \"topology\": "
        "\"octet\", \"cell_mm\": 6.0, \"strut_radius_mm\": 0.9, \"emit_stl\": "
        "true, \"emit_3mf\": true }");
    const JobDescription j = parse_job(s);
    CHECK(j.lattice.present, "lattice: present");
    CHECK(j.lattice.topology == "octet", "lattice: topology");
    CHECK(j.lattice.cell_mm == 6.0, "lattice: cell_mm");
    CHECK(j.lattice.strut_radius_mm == 0.9, "lattice: strut_radius_mm");
    CHECK(j.lattice.emit_stl && j.lattice.emit_3mf, "lattice: both formats");
  }
  // Minimal block: only the required numbers; formats default (stl on, 3mf off).
  {
    const std::string s = mutate(
        "\"mesh_prefix\": \"variant\" }",
        "\"mesh_prefix\": \"variant\" },\n  \"lattice\": { \"cell_mm\": 5.0, "
        "\"strut_radius_mm\": 0.7 }");
    const JobDescription j = parse_job(s);
    CHECK(j.lattice.present && j.lattice.emit_stl && !j.lattice.emit_3mf,
          "lattice: default formats (stl on, 3mf off)");
  }
  // Rejections: bad topology, non-positive cell/radius, unknown key, neither
  // format, missing required numbers.
  auto lat = [](const std::string& body) {
    return mutate("\"mesh_prefix\": \"variant\" }",
                  "\"mesh_prefix\": \"variant\" },\n  \"lattice\": " + body);
  };
  check_rejects(lat("{ \"topology\": \"gyroid\", \"cell_mm\": 5, \"strut_radius_mm\": 0.7 }"),
                "lattice: rejects unimplemented topology");
  check_rejects(lat("{ \"cell_mm\": 0, \"strut_radius_mm\": 0.7 }"),
                "lattice: rejects cell_mm <= 0");
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": -1 }"),
                "lattice: rejects strut_radius_mm <= 0");
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"bogus\": 1 }"),
                "lattice: rejects unknown key");
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"emit_stl\": false, \"emit_3mf\": false }"),
                "lattice: rejects neither-format");
  check_rejects(lat("{ \"strut_radius_mm\": 0.7 }"),
                "lattice: rejects missing cell_mm");
  check_rejects(lat("{ \"cell_mm\": 5 }"),
                "lattice: rejects missing strut_radius_mm");
}

// --- Optional "grading" block (handoff 2026-07-29-lattice-grading-law)
static void test_grading_block() {
  // Absent => present false (byte-identical, bar L1).
  {
    const JobDescription j = parse_job(valid_job());
    CHECK(!j.grading.present, "grading: absent block => not present");
  }
  // A full block parses into every field.
  {
    const std::string s =
        mutate("\"mesh_prefix\": \"variant\" }",
               "\"mesh_prefix\": \"variant\" },\n  \"grading\": { \"topology\": "
               "\"octet\", \"cell_mm\": 3.0, \"min_extrudable_width_mm\": 0.4, "
               "\"demand_exponent\": 0.5 }");
    const JobDescription j = parse_job(s);
    CHECK(j.grading.present, "grading: present");
    CHECK(j.grading.topology == "octet", "grading: topology");
    CHECK(j.grading.cell_mm == 3.0, "grading: cell_mm");
    CHECK(j.grading.min_extrudable_width_mm == 0.4, "grading: min width");
    CHECK(j.grading.demand_exponent == 0.5, "grading: demand_exponent");
  }
  // Minimal block: only the two required numbers; exponent defaults to 1.0.
  {
    const std::string s = mutate(
        "\"mesh_prefix\": \"variant\" }",
        "\"mesh_prefix\": \"variant\" },\n  \"grading\": { \"cell_mm\": 4.0, "
        "\"min_extrudable_width_mm\": 0.8 }");
    const JobDescription j = parse_job(s);
    CHECK(j.grading.present && j.grading.demand_exponent == 1.0,
          "grading: demand_exponent defaults to 1.0");
  }
  auto gr = [](const std::string& body) {
    return mutate("\"mesh_prefix\": \"variant\" }",
                  "\"mesh_prefix\": \"variant\" },\n  \"grading\": " + body);
  };
  check_rejects(
      gr("{ \"topology\": \"gyroid\", \"cell_mm\": 4, \"min_extrudable_width_mm\": 0.4 }"),
      "grading: rejects unimplemented topology");
  check_rejects(gr("{ \"cell_mm\": 0, \"min_extrudable_width_mm\": 0.4 }"),
                "grading: rejects cell_mm <= 0");
  check_rejects(gr("{ \"cell_mm\": 4, \"min_extrudable_width_mm\": 0 }"),
                "grading: rejects min_extrudable_width_mm <= 0");
  check_rejects(
      gr("{ \"cell_mm\": 4, \"min_extrudable_width_mm\": 0.4, \"demand_exponent\": 0 }"),
      "grading: rejects demand_exponent <= 0");
  check_rejects(gr("{ \"cell_mm\": 4, \"min_extrudable_width_mm\": 0.4, \"bogus\": 1 }"),
                "grading: rejects unknown key");
  check_rejects(gr("{ \"min_extrudable_width_mm\": 0.4 }"),
                "grading: rejects missing cell_mm");
  check_rejects(gr("{ \"cell_mm\": 4 }"),
                "grading: rejects missing min_extrudable_width_mm");
}

// --- The optional "warm_start" block ---------------------------------------
// Task warm-start-coarse-experiment. Handoff 110 BUILT the res/2 coarse-to-fine
// pre-solve and left it off; nothing ever set it, so no production entry point
// could reach it and it had never been measured at production scale. This block
// is the per-run ARMING switch that makes it reachable. It is NOT a default
// change: absent block => has_warm_start false => the driver keeps its own OFF
// default and the run is byte-identical, which is what the first case pins.
static void test_warm_start_block() {
  // Absent => not present, and the flag reads false (the byte-identical path).
  {
    const JobDescription j = parse_job(valid_job());
    CHECK(!j.has_warm_start, "warm_start: absent block => not present");
    CHECK(!j.warm_start_coarse, "warm_start: absent block => coarse false");
  }
  auto ws = [](const std::string& body) {
    return mutate("\"mesh_prefix\": \"variant\" }",
                  "\"mesh_prefix\": \"variant\" },\n  \"warm_start\": " + body);
  };
  // Armed.
  {
    const JobDescription j = parse_job(ws("{ \"coarse\": true }"));
    CHECK(j.has_warm_start, "warm_start: present");
    CHECK(j.warm_start_coarse, "warm_start: coarse true");
  }
  // Explicitly disarmed is a DIFFERENT fact from absent, and both must parse:
  // a job may want to say "I considered it and chose off" in its own bytes.
  {
    const JobDescription j = parse_job(ws("{ \"coarse\": false }"));
    CHECK(j.has_warm_start, "warm_start: present when explicitly false");
    CHECK(!j.warm_start_coarse, "warm_start: coarse false");
  }
  check_rejects(ws("{ \"coarse\": 1 }"),
                "warm_start: rejects non-boolean coarse");
  check_rejects(ws("{ }"), "warm_start: rejects missing coarse");
  check_rejects(ws("{ \"coarse\": true, \"bogus\": 1 }"),
                "warm_start: rejects unknown key");
  check_rejects(ws("true"), "warm_start: rejects non-object block");
}

// --- Mode "analyze" (task lattice-page-core-hookup stage 3, H3a) ------------
static void test_mode_analyze() {
  // "analyze" is a valid mode...
  {
    const JobDescription j = parse_job(
        mutate("\"mode\": \"minimize_plastic\"", "\"mode\": \"analyze\""));
    CHECK(j.mode == "analyze", "mode: analyze parses");
  }
  // ...and the validation stays STRICT: an unknown mode is refused, exactly as
  // before (adding a mode must never make the field permissive).
  check_rejects(mutate("\"mode\": \"minimize_plastic\"", "\"mode\": \"optimize\""),
                "mode: unknown mode still refused (H3a)");
  check_rejects(mutate("\"mode\": \"minimize_plastic\"", "\"mode\": \"Analyze\""),
                "mode: case-mangled mode refused (no fuzzy match)");
}

// --- lattice.regions roles (task lattice-page-core-hookup stage 1, H1e) ------
static void test_lattice_regions() {
  auto lat = [](const std::string& body) {
    return mutate("\"mesh_prefix\": \"variant\" }",
                  "\"mesh_prefix\": \"variant\" },\n  \"lattice\": " + body);
  };
  const std::string bolt_geom =
      "\"geometry\": { \"axis_point\": [1,2,3], \"axis_dir\": [0,0,1], "
      "\"radius_mm\": 4.0, \"half_length_mm\": 6.0 }";
  const std::string face_geom =
      "\"geometry\": { \"origin\": [0,0,0], \"normal\": [1,0,0], "
      "\"half_u_mm\": 10.0, \"half_w_mm\": 8.0, \"depth_mm\": 5.0 }";
  // Valid: one include bolt + one exclude face.
  {
    const JobDescription j = parse_job(lat(
        "{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": [\n"
        "  { \"role\": \"include\", \"kind\": \"bolt\", " + bolt_geom + " },\n"
        "  { \"role\": \"exclude\", \"kind\": \"face\", " + face_geom + " } ] }"));
    CHECK(j.lattice.regions.size() == 2, "regions: two entries parsed");
    CHECK(j.lattice.regions[0].role == "include" &&
              j.lattice.regions[0].kind == "bolt" &&
              j.lattice.regions[0].radius_mm == 4.0 &&
              j.lattice.regions[0].half_length_mm == 6.0,
          "regions: include bolt fields");
    CHECK(j.lattice.regions[1].role == "exclude" &&
              j.lattice.regions[1].kind == "face" &&
              j.lattice.regions[1].depth_mm == 5.0,
          "regions: exclude face fields");
  }
  // No regions key => empty (byte-identical whole-part lattice).
  {
    const JobDescription j =
        parse_job(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7 }"));
    CHECK(j.lattice.regions.empty(), "regions: absent => empty");
  }
  // H1e — a malformed ROLE is refused, never defaulted.
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
                    "{ \"role\": \"solid\", \"kind\": \"bolt\", " + bolt_geom +
                    " } ] }"),
                "regions: unknown role refused");
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
                    "{ \"role\": \"include\", \"kind\": \"sphere\", " + bolt_geom +
                    " } ] }"),
                "regions: unknown kind refused");
  // H1e — reject_unknown_keys still rejects at every level.
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
                    "{ \"role\": \"include\", \"kind\": \"bolt\", \"extra\": 1, " +
                    bolt_geom + " } ] }"),
                "regions: unknown region key refused");
  check_rejects(
      lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
          "{ \"role\": \"include\", \"kind\": \"bolt\", \"geometry\": { "
          "\"axis_point\": [1,2,3], \"axis_dir\": [0,0,1], \"radius_mm\": 4.0, "
          "\"half_length_mm\": 6.0, \"taper\": 1 } } ] }"),
      "regions: unknown geometry key refused");
  // Degenerate extents refused (a zero-extent region marks nothing — a config
  // mistake, not a silent no-op).
  check_rejects(
      lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
          "{ \"role\": \"exclude\", \"kind\": \"bolt\", \"geometry\": { "
          "\"axis_point\": [1,2,3], \"axis_dir\": [0,0,1], \"radius_mm\": 0, "
          "\"half_length_mm\": 6.0 } } ] }"),
      "regions: zero radius refused");
  check_rejects(
      lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
          "{ \"role\": \"exclude\", \"kind\": \"bolt\", \"geometry\": { "
          "\"axis_point\": [1,2,3], \"axis_dir\": [0,0,0], \"radius_mm\": 4, "
          "\"half_length_mm\": 6.0 } } ] }"),
      "regions: zero axis_dir refused");
  // Missing geometry / role refused.
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
                    "{ \"role\": \"include\", \"kind\": \"bolt\" } ] }"),
                "regions: missing geometry refused");
  check_rejects(lat("{ \"cell_mm\": 5, \"strut_radius_mm\": 0.7, \"regions\": ["
                    "{ \"kind\": \"bolt\", " + bolt_geom + " } ] }"),
                "regions: missing role refused");
}

// --- lattice x grading coupling (task lattice-page-core-hookup stage 4) ------
static void test_lattice_grading_coupling() {
  auto both = [](const std::string& lat_body) {
    return mutate(
        "\"mesh_prefix\": \"variant\" }",
        "\"mesh_prefix\": \"variant\" },\n  \"lattice\": " + lat_body +
            ",\n  \"grading\": { \"cell_mm\": 4.0, "
            "\"min_extrudable_width_mm\": 0.4 }");
  };
  // With a grading block the lattice block carries NO uniform geometry: the
  // graded run derives cell + radii from the run's own field.
  {
    const JobDescription j = parse_job(both("{ \"topology\": \"octet\" }"));
    CHECK(j.lattice.present && j.grading.present,
          "grading+lattice: both blocks parse");
    CHECK(j.lattice.cell_mm == 0.0 && j.lattice.strut_radius_mm == 0.0,
          "grading+lattice: no uniform geometry carried");
  }
  // A uniform cell/radius alongside grading is REFUSED (conflict), never
  // silently ignored.
  check_rejects(both("{ \"cell_mm\": 5.0 }"),
                "grading+lattice: cell_mm refused with grading");
  check_rejects(both("{ \"strut_radius_mm\": 0.7 }"),
                "grading+lattice: strut_radius_mm refused with grading");
  // Without grading the uniform geometry stays REQUIRED (unchanged).
  check_rejects(
      mutate("\"mesh_prefix\": \"variant\" }",
             "\"mesh_prefix\": \"variant\" },\n  \"lattice\": { \"topology\": "
             "\"octet\" }"),
      "lattice alone: cell_mm still required");
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
  test_clearances_manual();
  test_wall_loops();
  test_lattice_block();
  test_grading_block();
  test_warm_start_block();
  test_mode_analyze();
  test_lattice_regions();
  test_lattice_grading_coupling();

  if (g_failures == 0) {
    std::printf("job schema (M6.2): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "job schema (M6.2): %d of %d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
