// THE TWO DEFAULTS ARE ARMED (task 2026-08-06-arm-projection-and-void-check).
//
//   output.project_cad_faces                      — PR 307, was false
//   lattice.require_lattice_void_reaches_exterior — PR 305, was false
//
// This test exists because the maintainer decided both features are on BY
// DEFAULT, UNIVERSALLY. "Universally" means ONE answer, and the answer lives
// HERE — in the core's own `JobDescription` — not in whichever front-end
// happens to be assembling a job. This project has already been bitten by two
// front-ends disagreeing about a setting: the dropped outer wall line width,
// where bridge.cpp wrote it correctly and the CLI helper silently did not, and
// device runs and LAN runs quietly diverged for a week. So the default is
// asserted on the STRUCT and on the PARSER, and the app's own duty to send the
// key explicitly is asserted separately in
// app/TopOptKit/Tests/TopOptFlowsTests/DefaultArmingTests.swift.
//
// FOUR ASSERTIONS PER KEY, and they are not redundant:
//
//   1. the C++ struct's own initializer is true   — what an in-process caller
//      that never touches JSON (the on-device bridge) gets;
//   2. a job document with the key ABSENT parses to true — what every existing
//      job file on disk now means;
//   3. an explicit `false` still parses to false  — the OFF CONTROL. A default
//      flip that also removed the ability to turn the thing off would be a
//      much larger change than the one that was asked for, and the maintainer
//      needs to run the same job both ways while he evaluates it;
//   4. an explicit `true` still parses to true    — so 2 and 3 cannot both be
//      passing because the key stopped being read at all.
//
// (3) and (4) are the reason this file cannot pass vacuously: an implementation
// that hard-wired the value to true would fail (3), and one that ignored the
// key entirely would fail whichever of (3)/(4) disagreed with its constant.
//
// parse_job is pure C++/std (no OCCT, no Eigen, no lib3mf), so this runs in
// every CI configuration — the same reason test_job.cpp is a unit test.

#include "topopt/job.hpp"

#include <cstdio>
#include <string>

using topopt::JobDescription;
using topopt::parse_job;

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

// A minimal valid job with NO `output` block key beyond the required ones and
// NO lattice arming key — i.e. exactly the shape every job document already on
// disk has. What this parses to IS the default, by definition.
static std::string job_without_either_key() {
  return R"({
  "model": "part.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "fixture_faces": [ { "kind": "cylindrical", "radius_mm": 2.5 } ],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.7, 0.5, 0.3],
  "margin_stop": 1.5,
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" },
  "lattice": { "topology": "octet", "cell_mm": 5.0, "strut_radius_mm": 0.7 }
})";
}

// Same document with `body` spliced into the `output` block.
static std::string with_output(const std::string& body) {
  std::string s = job_without_either_key();
  const std::string needle = "\"mesh_prefix\": \"variant\"";
  const std::string::size_type at = s.find(needle);
  if (at == std::string::npos) {
    std::fprintf(stderr, "test bug: output needle not found\n");
    ++g_failures;
    return s;
  }
  return s.replace(at, needle.size(), needle + ", " + body);
}

// Same document with `body` spliced into the `lattice` block.
static std::string with_lattice(const std::string& body) {
  std::string s = job_without_either_key();
  const std::string needle = "\"strut_radius_mm\": 0.7";
  const std::string::size_type at = s.find(needle);
  if (at == std::string::npos) {
    std::fprintf(stderr, "test bug: lattice needle not found\n");
    ++g_failures;
    return s;
  }
  return s.replace(at, needle.size(), needle + ", " + body);
}

// --- output.project_cad_faces ------------------------------------------------
//
// PR 307 shipped this false: "absent or false keeps every existing job
// byte-for-byte identical". It is now ARMED. The exported surfaces of every
// run are restored to the shapes the CAD states — which also means every
// MESH-DERIVED mass drops by about 8%, because PR 307 measured the exported
// part ~8% oversize (100% of flat-face vertices outside their own CAD plane).
static void test_project_cad_faces_default_is_armed() {
  const JobDescription plain = parse_job(job_without_either_key());
  std::fprintf(stderr,
               "observed: output.project_cad_faces with the key ABSENT = %s\n",
               plain.output.project_cad_faces ? "true" : "false");
  CHECK(plain.output.project_cad_faces,
        "project_cad_faces: an ABSENT key must now mean ARMED (was false "
        "before this task)");

  const JobDescription fresh;
  CHECK(fresh.output.project_cad_faces,
        "project_cad_faces: the JobOutput struct's own default must be armed, "
        "so an in-process caller that never parses JSON agrees with the CLI");

  // THE OFF CONTROL. He must be able to run the same job both ways.
  const JobDescription off =
      parse_job(with_output("\"project_cad_faces\": false"));
  CHECK(!off.output.project_cad_faces,
        "project_cad_faces: an explicit false must STILL turn it off");

  const JobDescription on =
      parse_job(with_output("\"project_cad_faces\": true"));
  CHECK(on.output.project_cad_faces,
        "project_cad_faces: an explicit true stays true");
}

// --- lattice.require_lattice_void_reaches_exterior ---------------------------
//
// PR 305 shipped this false. It is now ARMED, and it is NOT the same kind of
// change as the one above: projection moves geometry, this one REFUSES RUNS. A
// job that succeeded yesterday can fail today. That is why the refusal text is
// asserted separately (test_lattice_void.cpp) to name a way forward.
static void test_void_check_default_is_armed() {
  const JobDescription plain = parse_job(job_without_either_key());
  std::fprintf(stderr,
               "observed: lattice.require_lattice_void_reaches_exterior with "
               "the key ABSENT = %s\n",
               plain.lattice.require_lattice_void_reaches_exterior ? "true"
                                                                  : "false");
  CHECK(plain.lattice.require_lattice_void_reaches_exterior,
        "require_lattice_void_reaches_exterior: an ABSENT key must now mean "
        "ARMED (was false before this task)");

  const JobDescription fresh;
  CHECK(fresh.lattice.require_lattice_void_reaches_exterior,
        "require_lattice_void_reaches_exterior: the JobLattice struct's own "
        "default must be armed, so the in-process caller agrees with the CLI");

  // THE OFF CONTROL.
  const JobDescription off = parse_job(
      with_lattice("\"require_lattice_void_reaches_exterior\": false"));
  CHECK(!off.lattice.require_lattice_void_reaches_exterior,
        "require_lattice_void_reaches_exterior: an explicit false must STILL "
        "turn it off");

  const JobDescription on = parse_job(
      with_lattice("\"require_lattice_void_reaches_exterior\": true"));
  CHECK(on.lattice.require_lattice_void_reaches_exterior,
        "require_lattice_void_reaches_exterior: an explicit true stays true");
}

// --- the two are INDEPENDENT -------------------------------------------------
//
// They are not one switch and must never become one. Projection changes
// geometry; the void check refuses runs. Turning one off must not touch the
// other, or an evaluation of one would silently be an evaluation of both.
static void test_the_two_switches_are_independent() {
  const JobDescription a =
      parse_job(with_output("\"project_cad_faces\": false"));
  CHECK(!a.output.project_cad_faces &&
            a.lattice.require_lattice_void_reaches_exterior,
        "independence: disarming projection leaves the void check armed");

  const JobDescription b = parse_job(
      with_lattice("\"require_lattice_void_reaches_exterior\": false"));
  CHECK(b.output.project_cad_faces &&
            !b.lattice.require_lattice_void_reaches_exterior,
        "independence: disarming the void check leaves projection armed");
}

int main() {
  test_project_cad_faces_default_is_armed();
  test_void_check_default_is_armed();
  test_the_two_switches_are_independent();

  if (g_failures == 0) {
    std::printf("default arming: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "default arming: %d of %d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
