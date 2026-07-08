// M6.2 integration test: `topopt-cli run job.json` on the committed demo job
// (core/tests/fixtures/demo/, maintainer-authored — DECISIONS.md 2026-07-09).
//
// The demo job drives the FULL pipeline (ARCHITECTURE §5): STEP import ->
// watertight check -> voxelize -> geometric fixture-face selection (the locked
// rule: never raw OCCT face indices) -> tag -> self-weight minimize_plastic ->
// report + one exported mesh per accepted variant.
//
// Assertions follow fixtures/demo/expected_values.json: the l-bracket GEOMETRY
// facts are asserted exactly (values cited inline from that file, consumed
// never modified), and the RUN facts are asserted as behavioral invariants —
// no compliance or stress values are pinned (the physics gates V1–V5 pin the
// numerics elsewhere).
//
// 3MF vs STL: the demo job requests mesh_format "3mf". lib3mf is present in CI
// (DEPS=ON), where this test runs the pristine fixture job. On a local build
// without lib3mf (TOPOPT_HAVE_3MF undefined) the CLI cannot write 3MF, so the
// test runs a byte-patched COPY of the fixture job (mesh_format "3mf" -> "stl",
// model path made absolute) written into the build directory — the fixture
// itself is never touched, and every non-3MF assertion still runs. CI remains
// the source of truth for the pristine job.
//
// Determinism is asserted across PROCESSES, which also exercises the real
// binary: run 1 calls run_job() in-process (giving access to the in-memory
// variant meshes for the volume comparisons); run 2 invokes the actual
// topopt-cli executable via std::system on the same job file; the two
// report.json files must be byte-identical (expected_values cli_run_invariants
// "determinism").
//
// No third-party test framework (ARCHITECTURE §4): the self-contained CHECK
// harness the other tests use.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#ifdef TOPOPT_HAVE_3MF
#include "topopt/threemf.hpp"
#endif

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using topopt::check_watertight;
using topopt::count_components;
using topopt::JobDescription;
using topopt::JobError;
using topopt::load_materials_file;
using topopt::load_settings_rules_file;
using topopt::MaterialLibrary;
using topopt::parse_job;
using topopt::run_job;
using topopt::RunJobResult;
using topopt::SettingsRules;
using topopt::signed_volume;
using topopt::StepSurfaceKind;
using topopt::TriangleMesh;
using topopt::Vec3;

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

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "test bug: cannot read %s\n", path.c_str());
    ++g_failures;
    return "";
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static void write_file(const std::string& path, const std::string& text) {
  std::ofstream out(path, std::ios::binary);
  out << text;
}

// Replace the first occurrence of `from` with `to`; the needle must exist.
static void replace_once(std::string& s, const std::string& from,
                         const std::string& to) {
  const std::string::size_type at = s.find(from);
  if (at == std::string::npos) {
    std::fprintf(stderr, "test bug: patch needle not found: %s\n", from.c_str());
    ++g_failures;
    return;
  }
  s.replace(at, from.size(), to);
}

// Re-import an exported variant mesh with the matching M6.1 reader.
static TriangleMesh reimport_mesh(const std::string& path) {
#ifdef TOPOPT_HAVE_3MF
  return topopt::read_3mf_file(path);
#else
  return topopt::read_stl_file(path).mesh;
#endif
}

int main() {
  const std::string demo_dir = DEMO_FIXTURE_DIR;
  const std::string tmp_dir = CLI_TMP_DIR;

  // --- Prepare the job file (pristine in CI; byte-patched STL copy locally) --
  std::string job_text = read_file(demo_dir + "/job.json");
  std::string job_file;
  std::string job_dir;
#ifdef TOPOPT_HAVE_3MF
  job_file = demo_dir + "/job.json";
  job_dir = demo_dir;
  const std::string mesh_ext = "3mf";
#else
  replace_once(job_text, "\"mesh_format\": \"3mf\"", "\"mesh_format\": \"stl\"");
  replace_once(job_text, "\"model\": \"l-bracket.step\"",
               "\"model\": \"" + demo_dir + "/l-bracket.step\"");
  job_file = tmp_dir + "/demo_job_local.json";
  job_dir = tmp_dir;
  write_file(job_file, job_text);
  const std::string mesh_ext = "stl";
  std::printf("[local mode] lib3mf absent: running the demo job with "
              "mesh_format patched to stl (CI runs the pristine 3mf job)\n");
#endif

  const JobDescription job = parse_job(job_text);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

  // --- Run 1: in-process ------------------------------------------------------
  const std::string out1 = tmp_dir + "/cli_out1";
  const RunJobResult run = run_job(job, job_dir, out1, materials, rules);

  // --- Geometry facts, asserted exactly (expected_values.json l-bracket.step) -
  CHECK(run.model.solid_count == 1, "l-bracket: exactly 1 solid");
  CHECK(run.model.face_count == 10, "l-bracket: 10 B-rep faces");
  CHECK(static_cast<int>(run.model.faces.size()) == run.model.face_count,
        "per-face geometry info is parallel to the face list");
  int planar = 0, cylindrical = 0;
  for (const topopt::StepFaceInfo& f : run.model.faces) {
    if (f.kind == StepSurfaceKind::Plane) ++planar;
    if (f.kind == StepSurfaceKind::Cylinder) {
      ++cylindrical;
      CHECK(std::fabs(f.cylinder_radius_mm - 2.5) <= 1e-6,
            "l-bracket: cylindrical face radius 2.5 mm");
    }
  }
  CHECK(planar == 8, "l-bracket: 8 planar faces");
  CHECK(cylindrical == 2, "l-bracket: 2 cylindrical faces");

  // expected_values.json analytic_volume_mm3 at brep_volume_rel_tolerance
  // (values corrected by the maintainer 2026-07-10 — see the fixture's
  // _erratum note and handoff 030's addendum).
  const double analytic_volume = 35525.840734641024;  // expected_values.json
  CHECK(std::fabs(run.model.brep_volume - analytic_volume) <=
            1e-6 * analytic_volume,  // brep_volume_rel_tolerance
        "l-bracket: B-rep volume matches analytic within 1e-6 relative");

  // Bounding box (expected_values.json): [-30,-20,0] .. [30,20,60]. The box
  // extremes lie on planar faces, so tessellated vertices reach them exactly.
  {
    Vec3 lo{1e30, 1e30, 1e30}, hi{-1e30, -1e30, -1e30};
    for (const Vec3& v : run.model.mesh.vertices) {
      lo.x = std::min(lo.x, v.x); lo.y = std::min(lo.y, v.y);
      lo.z = std::min(lo.z, v.z);
      hi.x = std::max(hi.x, v.x); hi.y = std::max(hi.y, v.y);
      hi.z = std::max(hi.z, v.z);
    }
    CHECK(std::fabs(lo.x + 30.0) <= 1e-6 && std::fabs(lo.y + 20.0) <= 1e-6 &&
              std::fabs(lo.z - 0.0) <= 1e-6,
          "l-bracket: bounding-box min (-30, -20, 0)");
    CHECK(std::fabs(hi.x - 30.0) <= 1e-6 && std::fabs(hi.y - 20.0) <= 1e-6 &&
              std::fabs(hi.z - 60.0) <= 1e-6,
          "l-bracket: bounding-box max (30, 20, 60)");
  }

  // Hole facts (expected_values.json hole_axes): both holes run through the
  // mounting plate z in [0, 8], centered at (x, y) = (-17, 0) and (9, 0). Each
  // cylindrical face's tessellation spans exactly that z range (its rim edges
  // lie on the plate's planar faces), and the midpoint of its vertex bounding
  // box recovers the axis center to within the chordal sampling error (well
  // under 0.1 mm at the default deflection, vs 26 mm center separation).
  {
    int at_minus17 = 0, at_9 = 0;
    for (int f = 0; f < run.model.face_count; ++f) {
      if (run.model.faces[static_cast<std::size_t>(f)].kind !=
          StepSurfaceKind::Cylinder)
        continue;
      Vec3 lo{1e30, 1e30, 1e30}, hi{-1e30, -1e30, -1e30};
      for (std::size_t t = 0; t < run.model.triangle_face.size(); ++t) {
        if (run.model.triangle_face[t] != f) continue;
        for (int c = 0; c < 3; ++c) {
          const Vec3& v = run.model.mesh.vertices[static_cast<std::size_t>(
              run.model.mesh.triangles[t][static_cast<std::size_t>(c)])];
          lo.x = std::min(lo.x, v.x); lo.y = std::min(lo.y, v.y);
          lo.z = std::min(lo.z, v.z);
          hi.x = std::max(hi.x, v.x); hi.y = std::max(hi.y, v.y);
          hi.z = std::max(hi.z, v.z);
        }
      }
      CHECK(std::fabs(lo.z - 0.0) <= 1e-6 && std::fabs(hi.z - 8.0) <= 1e-6,
            "hole face spans exactly the plate thickness z in [0, 8]");
      const double cx = 0.5 * (lo.x + hi.x);
      const double cy = 0.5 * (lo.y + hi.y);
      if (std::fabs(cx + 17.0) <= 0.1 && std::fabs(cy) <= 0.1) ++at_minus17;
      if (std::fabs(cx - 9.0) <= 0.1 && std::fabs(cy) <= 0.1) ++at_9;
    }
    CHECK(at_minus17 == 1 && at_9 == 1,
          "one hole centered at (-17, 0) and one at (9, 0)");
  }

  // Tessellated volume approaches the analytic volume FROM ABOVE (the curved
  // surfaces are holes — expected_values.json tessellated_volume_note).
  {
    const double vol = signed_volume(run.model.mesh);
    CHECK(vol >= analytic_volume - 1e-9 * analytic_volume,
          "tessellated volume is not below analytic (holes shrink, solid grows)");
    CHECK(vol <= analytic_volume * 1.005,
          "tessellated volume within 0.5% above analytic at default deflection");
  }

  // --- Run invariants (expected_values.json cli_run_invariants) ---------------
  CHECK(run.fixture_face_ids.size() == 2,
        "cylindrical selector matches exactly 2 faces (the two screw holes)");

  CHECK(run.pipeline.evaluated.size() == 3, "all three ladder rungs evaluated");
  CHECK(!run.pipeline.stopped_on_margin,
        "accept-all: the margin stop never triggered");
  CHECK(run.pipeline.report.variants.size() == 3,
        "report holds exactly 3 variants");
  const double expected_vf[3] = {0.7, 0.5, 0.3};
  for (std::size_t i = 0; i < run.pipeline.evaluated.size() && i < 3; ++i) {
    const topopt::MinimizePlasticVariant& ev = run.pipeline.evaluated[i];
    CHECK(ev.accepted, "every rung is accepted");
    CHECK(std::fabs(ev.report.volume_fraction - expected_vf[i]) <= 0.01,
          "achieved volume fraction within 0.01 of its request");
    CHECK(ev.report.margin.worst_case > job.margin_stop,
          "every margin is above margin_stop");
    CHECK(std::fabs(ev.report.orientation.x) <= 1e-12 &&
              std::fabs(ev.report.orientation.y) <= 1e-12 &&
              std::fabs(ev.report.orientation.z - 1.0) <= 1e-12,
          "build direction is [0, 0, 1] (unit negation of gravity)");
    // Settings: margins are far above 4.0 for real PLA under self-weight at
    // this scale, and max part dimension 84 mm is size class medium (no
    // modifier), so every variant gets rules.json's final band exactly
    // (expected_values.json settings_prediction).
    CHECK(ev.report.settings.family == "fdm", "settings family is fdm");
    CHECK(ev.report.settings.walls == 2, "settings: walls 2");
    CHECK(ev.report.settings.top_layers == 4, "settings: top layers 4");
    CHECK(ev.report.settings.bottom_layers == 3, "settings: bottom layers 3");
    CHECK(ev.report.settings.infill_percent == 15, "settings: infill 15%");
    CHECK(ev.report.settings.infill_pattern == "grid", "settings: grid infill");
  }

  // --- The written report -----------------------------------------------------
  const std::string report_on_disk = read_file(run.report_path);
  CHECK(run.report_path == out1 + "/report.json",
        "report lands at <out>/report.json (job output.report)");
  CHECK(!report_on_disk.empty(), "report.json was written");
  CHECK(report_on_disk == run.report_json,
        "RunJobResult.report_json is the on-disk bytes");
  CHECK(report_on_disk == topopt::job_report_json(run.pipeline.report),
        "report.json is exactly the serialized M5.2 JobReport");
  {
    bool valid = true;
    try {
      topopt::validate_job_report_json(report_on_disk);
    } catch (const topopt::ReportError&) {
      valid = false;
    }
    CHECK(valid, "report.json passes validate_job_report_json");
  }
  CHECK(run.pipeline.report.material == "PLA", "report material is PLA");
  CHECK(report_on_disk.find("\"PLA\"") != std::string::npos,
        "report document names the material PLA");
  CHECK(report_on_disk.find("min_feature_violations") != std::string::npos &&
            report_on_disk.find("min_feature_warning") != std::string::npos,
        "M5.2b min_feature fields present in the report");

  // --- Exported meshes: one per accepted variant, re-importable, V3-holding ---
  CHECK(run.mesh_paths.size() == 3, "one exported mesh per accepted variant");
  const char* expected_names[3] = {"variant_070.", "variant_050.",
                                   "variant_030."};
  for (std::size_t i = 0; i < run.mesh_paths.size() && i < 3; ++i) {
    const std::string& path = run.mesh_paths[i];
    CHECK(path == out1 + "/" + expected_names[i] + mesh_ext,
          "mesh filename is <prefix>_<fraction*100>.<format>");
    const TriangleMesh re = reimport_mesh(path);
    CHECK(check_watertight(re).watertight, "re-imported variant is watertight");
    CHECK(count_components(re) == 1,
          "re-imported variant is a single connected component");
    // |signed volume|, exactly as the M6.1 round-trip tests compare: the mesh
    // winding sign is not pinned anywhere (marching-cubes output currently
    // comes out inward-facing), and the invariant is "nonzero volume".
    const double vol = std::fabs(signed_volume(re));
    const double ref = std::fabs(signed_volume(run.pipeline.evaluated[i].v3.mesh));
    CHECK(vol > 0.0, "re-imported variant has nonzero volume");
    CHECK(std::fabs(vol - ref) <= 0.005 * ref,
          "re-imported volume within 0.5% of the in-memory variant mesh");
  }

  // --- Run 2: the real binary; byte-identical report (determinism) ------------
  {
    const std::string out2 = tmp_dir + "/cli_out2";
    const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE + "\" run \"" +
                            job_file + "\" --out \"" + out2 +
                            "\" --materials \"" + MATERIALS_JSON_PATH +
                            "\" --rules \"" + SETTINGS_RULES_PATH + "\"";
    const int rc = std::system(cmd.c_str());
    CHECK(rc == 0, "topopt-cli run exits 0 on the demo job");
    const std::string report2 = read_file(out2 + "/report.json");
    CHECK(!report2.empty(), "CLI run wrote report.json");
    CHECK(report2 == report_on_disk,
          "two CLI runs produce byte-identical report.json (determinism)");
    for (std::size_t i = 0; i < 3; ++i) {
      std::ifstream mesh_in(out2 + "/" + expected_names[i] + mesh_ext,
                            std::ios::binary);
      CHECK(mesh_in.good(), "CLI run wrote each variant mesh");
    }
  }

  // --- CLI failure modes ------------------------------------------------------
  {
    const int rc = std::system((std::string("\"") + TOPOPT_CLI_EXE +
                                "\" > /dev/null 2>&1")
                                   .c_str());
    CHECK(rc != 0, "topopt-cli with no arguments exits nonzero");
    const int rc2 = std::system((std::string("\"") + TOPOPT_CLI_EXE +
                                 "\" run \"" + tmp_dir +
                                 "/no_such_job_98765.json\" > /dev/null 2>&1")
                                    .c_str());
    CHECK(rc2 != 0, "topopt-cli on a missing job file exits nonzero");
  }

  // --- run_job diagnostics ----------------------------------------------------
  {
    // A selector that matches no face must fail with a diagnostic, BEFORE any
    // solve. (The l-bracket has no r = 7 mm cylinder.)
    JobDescription bad = job;
    bad.fixture_faces[0].radius_mm = 7.0;
    bool threw = false;
    try {
      run_job(bad, job_dir, tmp_dir + "/cli_out_bad", materials, rules);
    } catch (const JobError&) {
      threw = true;
    }
    CHECK(threw, "selector matching zero faces throws JobError");

    JobDescription unknown = job;
    unknown.material = "UNOBTANIUM";
    threw = false;
    try {
      run_job(unknown, job_dir, tmp_dir + "/cli_out_bad", materials, rules);
    } catch (const JobError&) {
      threw = true;
    }
    CHECK(threw, "a material not in materials.json throws JobError");
  }

#ifndef TOPOPT_HAVE_3MF
  {
    // Built without lib3mf, a job requesting 3MF output must fail with a
    // diagnostic rather than silently writing another format.
    JobDescription threemf_job = job;
    threemf_job.output.mesh_format = "3mf";
    bool threw = false;
    try {
      run_job(threemf_job, job_dir, tmp_dir + "/cli_out_bad", materials, rules);
    } catch (const JobError&) {
      threw = true;
    }
    CHECK(threw, "mesh_format 3mf without lib3mf throws JobError");
  }
#endif

  if (g_failures == 0) {
    std::printf("cli demo job (M6.2): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "cli demo job (M6.2): %d of %d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
