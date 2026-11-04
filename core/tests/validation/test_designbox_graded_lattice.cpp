// test_designbox_graded_lattice.cpp — GRADING + A DESIGN BOX (reviewer's ruling
// 2026-11-03 23:05, option (b)).
//
// Both entry points refused a "grading" block together with a "design_box": the law
// chose its cell plan before the added-material policy ran, and the SWEPT levels took
// their cells from that plan rather than from the final certification mask, so a graded
// design-box run could write struts into cells the certificate calls solid. The fix
// builds the law's candidates without the added material and lays, on every level and
// pass, only cells covering a voxel of the final mask.
//
//   G1 A graded (swept) design-box job runs end to end through run_job: the rung is
//      accepted and a certified latticed variant is written.
//   G2 NO STRUT IN A CELL THE CERTIFICATE CALLS SOLID: asked of every grid the
//      generator lays (each level), through its own activation chain — no emitted
//      cell covers no certified voxel, certified == emitted summed over the levels,
//      and no companion-solid voxel sits in such a cell.
//   G3 THE FILE RE-CERTIFIES: the same design re-latticed through lattice_variant_job
//      (refused before as well) certifies to the same composite margin.
//   G4 The certificate is LatticeTypes' (ruling 3, 4dc2d1a1): each latticed voxel at
//      min(the law's density, what the file holds), and the run says so.
//   G5 The organic lattice is still refused with a box, in plain words, before any
//      solve.

#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <manifold/manifold.h>

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

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

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static bool contains(const std::string& hay, const std::string& needle) {
  return hay.find(needle) != std::string::npos;
}

static double json_number(const std::string& text, const std::string& key) {
  const std::string pat = "\"" + key + "\": ";
  const std::string::size_type at = text.find(pat);
  if (at == std::string::npos) return std::nan("");
  return std::atof(text.c_str() + at + pat.size());
}

// A block thick enough to grade at more than one cell size (60 x 48 x 40 mm, a 4 mm bore
// through its middle, the bore fixed, its own weight the load), and a design box letting
// the optimizer grow it 12 mm upward: the bending plate thickens into the box, which is the added material.
// Written once by Manifold; the bore's radius is read back from the import, as the
// segmenter fits it.
static std::string g_dir;
static double g_bore_r = 0.0;

static void write_fixture() {
  g_dir = std::string(CLI_TMP_DIR) + "/dbx_graded_fixture";
  std::filesystem::create_directories(g_dir);
  using manifold::Manifold;
  const Manifold plate = Manifold::Cube({60.0, 48.0, 40.0}, true).Translate({0.0, 0.0, 20.0}) -
                         Manifold::Cylinder(50.0, 4.0, -1.0, 48, true).Translate({0.0, 0.0, 20.0});
  const manifold::MeshGL g = plate.GetMeshGL();
  TriangleMesh m;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    m.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                          g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    m.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                           static_cast<int>(g.triVerts[3 * t + 1]),
                           static_cast<int>(g.triVerts[3 * t + 2])});
  write_stl_file(g_dir + "/thick_plate_bore.stl", m, StlFormat::Binary);
  const StepModel part = import_part_file(g_dir + "/thick_plate_bore.stl");
  for (int f = 0; f < part.face_count; ++f)
    if (part.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Cylinder)
      g_bore_r = part.faces[static_cast<std::size_t>(f)].cylinder_radius_mm;
  CHECK(g_bore_r > 3.0 && g_bore_r < 5.0, "fixture: the bore segments as a cylinder");
}

static JobDescription graded_box_job() {
  JobDescription job;
  job.model = "thick_plate_bore.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 40;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", g_bore_r});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.has_build_direction = true;
  job.build_direction = Vec3{0.0, 0.0, 1.0};
  job.ladder = {0.9};
  job.margin_stop = 0.0;
  job.simp_max_iterations = 8;
  job.has_design_box = true;
  job.design_box.min = Vec3{-30.0, -24.0, 0.0};
  job.design_box.max = Vec3{30.0, 24.0, 52.0};
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.lattice.present = true;
  job.lattice.topology = "octet";  // no cell/radius: the law derives them
  job.lattice.emit_stl = true;
  job.grading.present = true;
  job.grading.topology = "octet";
  job.grading.min_extrudable_width_mm = 0.3;
  job.grading.cell_mode = "swept";
  job.grading.cell_min_mm = 1.6;
  job.grading.cell_max_mm = 12.8;
  return job;
}

static std::string g_design_path;
static std::string g_run_receipt;

static void section_run() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string out = std::string(CLI_TMP_DIR) + "/dbx_graded_run";
  std::filesystem::remove_all(out);
  const JobDescription job = graded_box_job();
  RunJobResult run;
  std::string refused;
  try {
    run = run_job(job, g_dir, out, materials, rules, /*emit_progress=*/false,
                  RunObservability{});
  } catch (const std::exception& e) {
    refused = e.what();
  }
  if (!refused.empty()) std::fprintf(stderr, "  run_job refused: %s\n", refused.c_str());
  CHECK(refused.empty(), "G1: a graded design-box job is not refused");
  if (!refused.empty()) return;
  CHECK(run.pipeline.evaluated.size() == 1 && run.pipeline.evaluated[0].accepted,
        "G1: the rung is accepted");
  const std::string rcpt_path = out + "/variant_090_lattice.report.json";
  CHECK(std::filesystem::exists(rcpt_path) &&
            std::filesystem::exists(out + "/variant_090_lattice.stl"),
        "G1: a latticed variant and its certification receipt are written");
  const std::string rcpt = read_file(rcpt_path);
  g_run_receipt = rcpt;
  g_design_path = run.design_path;

  const double outside = json_number(rcpt, "outside_original_part");
  const double kept = json_number(rcpt, "kept_solid_voxels");
  const double certified = json_number(rcpt, "certified_lattice_cells");
  const double emitted = json_number(rcpt, "emitted_lattice_cells");
  const double none = json_number(rcpt, "emitted_cells_covering_no_certified");
  const double both = json_number(rcpt, "voxels_strut_and_solid");
  const double bond = json_number(rcpt, "voxels_strut_and_solid_bond");
  std::printf("[G2] outside the part %.0f voxels, kept solid %.0f; cells certified %.0f, "
              "emitted %.0f, emitted covering no certified voxel %.0f; companion-solid "
              "voxels in such a cell %.0f (bond %.0f)\n",
              outside, kept, certified, emitted, none, both, bond);
  CHECK(outside > 0.0,
        "the optimizer grew material outside the part (else the policy is untested)");
  CHECK(!std::isnan(none),
        "G2: the receipt audits every level (this run lays more than one grid)");
  CHECK(certified > 0.0, "G2: the run latticed something");
  CHECK(none == 0.0, "G2: no level emits a cell that covers no certified voxel");
  CHECK(certified == emitted,
        "G2: certified == emitted, summed over the levels, cell for cell");
  CHECK(both == 0.0,
        "G2: no companion-solid voxel sits in an emitted cell that covers none");

  // G4: the certificate was rebuilt from what shipped (LatticeTypes' ruling 3).
  CHECK(contains(rcpt, "\"voxels_lowered_to_file\""),
        "G4: the certificate reads min(law, what the file holds), and says so");
  std::printf("[G4] lowered to the file %.0f voxel(s), held at the band floor %.0f; "
              "composite margin %.6g\n",
              json_number(rcpt, "voxels_lowered_to_file"),
              json_number(rcpt, "voxels_held_at_band_floor"),
              json_number(rcpt, "lattice_margin_worst_case"));
}

static void section_relattice() {
  if (g_design_path.empty()) {
    CHECK(false, "G3: no stored design to re-lattice (G1 did not run)");
    return;
  }
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string out = std::string(CLI_TMP_DIR) + "/dbx_graded_relattice";
  std::filesystem::remove_all(out);
  JobDescription lv = graded_box_job();
  lv.mode = "lattice_variant";
  lv.variant.present = true;
  lv.variant.design = g_design_path;
  lv.variant.has_index = true;
  lv.variant.index = 0;
  std::string refused;
  LatticeVariantJobResult r;
  try {
    r = lattice_variant_job(lv, g_dir, out, materials, rules);
  } catch (const std::exception& e) {
    refused = e.what();
  }
  if (!refused.empty()) std::fprintf(stderr, "  lattice_variant_job refused: %s\n", refused.c_str());
  CHECK(refused.empty(), "G3: the graded design-box re-lattice is not refused");
  if (!refused.empty()) return;
  const std::string lv_rcpt = read_file(r.lattice_receipt_path);
  const std::string key = "\"lattice_margin_worst_case\": ";
  const std::string::size_type at = lv_rcpt.find(key);
  const std::string text =
      at == std::string::npos ? std::string() : lv_rcpt.substr(at, lv_rcpt.find(',', at) - at);
  CHECK(!text.empty() && contains(g_run_receipt, text),
        "G3: the file re-certifies: the re-lattice path's composite margin EQUALS the run's");
  CHECK(json_number(lv_rcpt, "emitted_cells_covering_no_certified") == 0.0,
        "G3: and its levels lay no cell the certificate calls solid either");
  std::printf("[G3] re-lattice composite margin %.6g\n", r.lattice.margin.worst_case);
}

static void section_organic_refused() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  JobDescription job = graded_box_job();
  job.grading.algorithm = "organic";
  job.grading.cell_mode = "fixed";
  job.grading.cell_min_mm = job.grading.cell_max_mm = 0.0;
  std::string refused;
  try {
    run_job(job, g_dir, std::string(CLI_TMP_DIR) + "/dbx_graded_organic",
            materials, rules, /*emit_progress=*/false, RunObservability{});
  } catch (const std::exception& e) {
    refused = e.what();
  }
  CHECK(contains(refused, "organic lattice can't be used with a design box"),
        "G5: organic + a design box is refused, in plain words");
}

int main() {
  std::printf("=== grading + a design box ===\n");
  write_fixture();
  section_run();
  section_relattice();
  section_organic_refused();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
