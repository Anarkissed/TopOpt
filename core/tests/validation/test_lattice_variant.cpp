// test_lattice_variant.cpp — task 2026-08-02-lattice-a-variant: LATTICE A
// FINISHED VARIANT, driven end to end through run_job -> lattice_variant_job on
// the committed plate_bore.stl fixture and a synthetic thick cylinder.
//
// The bars this file is the evidence for:
//
//   Z1 NO LADDER RUNS. design_iterations == 0, variant_meshes_written == 0, no
//      variant_*.stl in the output directory, and a small FIXED number of
//      certification solves — reported, not claimed. Wall time is printed.
//   Z2 THE LOAD CASE IS THE SAME ONE. The loadcase.json the optimize run wrote
//      and the one the re-lattice run wrote are compared BYTE FOR BYTE (resolved
//      force magnitude and tagged voxel count per group among them), and the
//      restored design must reproduce the margin the run RECORDED — enforced,
//      so a mismatch throws instead of certifying. The NEGATIVE case is checked
//      too: a job whose load case was re-authored differently is REFUSED.
//   Z3 THE CERTIFIED OBJECT IS THE EXPORTED ONE. One fingerprint over the
//      density field, shared by the stored design, the mesh emission and the
//      composite certification; a corrupted store is refused outright.
//   Z4 AUTO GRADING WITH NO SIM. A graded lattice comes out of this path from
//      the variant's own recovered field alone, with per-voxel rho VARYING (the
//      achieved range is reported).
//   Z5 THE STRUT-STRENGTH REPORT COMES ALONG. Separate in-plane and interlayer
//      margins on this path's receipt.
//   Z6 (partial, here) the pre-existing artifacts of an optimize run are
//      unchanged in shape and the new ones are ADDITIVE; the cross-commit byte
//      identity is proven separately by a stash-rebuild checksum.
//   Z8 DETERMINISM. Every file the job writes is byte-identical on a rerun
//      (run_info.json excepted — it carries a deliberate wall-clock stamp, as
//      the optimize path's does).
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

#include "topopt/design_store.hpp"
#include "topopt/grading.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
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

// ---------------------------------------------------------------------------
// Fixtures.

// The plate_bore self-weight optimize job (mirrors test_lattice_hookup's).
static JobDescription plate_job() {
  JobDescription job;
  job.model = "plate_bore.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", 3.0});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.ladder = {0.6};
  job.margin_stop = 0.0;
  job.simp_max_iterations = 8;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

// THE CONTRACT: a lattice_variant job is the ORIGINAL job with `mode` swapped
// and a `variant` + `lattice` block added. Nothing about the load case is
// re-authored — which is exactly what makes Z2 checkable.
static JobDescription relattice_job(const JobDescription& original,
                                    const std::string& design_path,
                                    int variant_index) {
  JobDescription job = original;
  job.mode = "lattice_variant";
  job.variant.present = true;
  job.variant.design = design_path;
  job.variant.has_index = true;
  job.variant.index = variant_index;
  job.lattice.present = true;
  job.lattice.topology = "octet";
  job.lattice.cell_mm = 3.0;
  job.lattice.strut_radius_mm = 0.45;  // rho ~0.41, inside the band
  job.lattice.emit_stl = true;
  return job;
}

// A closed right cylinder as a clean triangle mesh — thick enough that the
// cells-per-member floor is satisfiable, so the grading law has room to work.
static TriangleMesh cylinder_mesh(double R, double H, int n) {
  TriangleMesh m;
  const int c0 = 0, c1 = 1;
  m.vertices.push_back(Vec3{0, 0, 0});
  m.vertices.push_back(Vec3{0, 0, H});
  for (int i = 0; i < n; ++i) {
    const double a = 2.0 * M_PI * i / n;
    m.vertices.push_back(Vec3{R * std::cos(a), R * std::sin(a), 0.0});
    m.vertices.push_back(Vec3{R * std::cos(a), R * std::sin(a), H});
  }
  auto lo = [n](int i) { return 2 + 2 * (i % n); };
  auto hi = [n](int i) { return 3 + 2 * (i % n); };
  for (int i = 0; i < n; ++i) {
    m.triangles.push_back({lo(i), lo(i + 1), hi(i + 1)});
    m.triangles.push_back({lo(i), hi(i + 1), hi(i)});
    m.triangles.push_back({c0, lo(i + 1), lo(i)});
    m.triangles.push_back({c1, hi(i), hi(i + 1)});
  }
  return m;
}

// ---------------------------------------------------------------------------
// A. The whole flow on plate_bore: optimize once, then lattice a variant of it.
//    Bars Z1, Z2, Z3, Z5, Z6(shape), Z8.
static void section_flow() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  // ── the ORIGINAL run. A plain optimize job: no lattice block at all, which
  // is the realistic case — the user optimizes first and decides to lattice
  // afterwards, which is precisely the job that did not exist.
  const std::string run_out = tmp + "/lv_run";
  std::filesystem::remove_all(run_out);
  const JobDescription original = plate_job();
  const RunJobResult run = run_job(original, fixture_dir, run_out, materials,
                                   rules, /*emit_progress=*/false,
                                   RunObservability{});
  CHECK(run.pipeline.evaluated.size() >= 1, "the original run produced a rung");

  // ── Z6 (shape): the new artifacts exist and are ADDITIVE — the pre-existing
  // report / fields / meshes are untouched files beside them.
  CHECK(!run.design_path.empty() && std::filesystem::exists(run.design_path),
        "Z6: design.bin written beside the existing artifacts");
  CHECK(run.design_variant_count >= 1, "design.bin holds the run's variants");
  CHECK(std::filesystem::exists(run.loadcase_receipt_path),
        "Z2: loadcase.json written by the optimize run");
  CHECK(std::filesystem::exists(run.report_path) &&
            std::filesystem::exists(run.fields_path),
        "Z6: report.json and fields.bin still written");

  // The stored design must round-trip and be the SAME field the run held.
  const DesignStore store = read_design_file(run.design_path);
  CHECK(store.nx == run.pipeline.solved_grid.nx &&
            store.ny == run.pipeline.solved_grid.ny &&
            store.nz == run.pipeline.solved_grid.nz,
        "design.bin header names the solved grid");
  CHECK(store.variants.size() ==
            static_cast<std::size_t>(run.design_variant_count),
        "design.bin block count matches the reported count");
  {
    const std::vector<double>& live =
        run.pipeline.evaluated[0].optimization.physical_density;
    CHECK(store.variants[0].density == live,
          "design.bin round-trips the density field EXACTLY (double precision "
          "— a narrowed field could not reproduce the recorded margin)");
    CHECK(store.variants[0].margin_worst_case ==
              run.pipeline.evaluated[0].report.margin.worst_case,
          "design.bin records the variant's OWN margin");
  }

  // ── the RE-LATTICE job. Same document, mode swapped.
  const std::string lv_out = tmp + "/lv_lattice";
  std::filesystem::remove_all(lv_out);
  const JobDescription lv = relattice_job(original, "../lv_run/design.bin", 0);
  // The design path resolves against the JOB dir; point the job dir at the
  // fixture dir the model lives in and give the design an absolute path
  // instead, which is what a front-end does.
  JobDescription lv_abs = lv;
  lv_abs.variant.design = run.design_path;
  const LatticeVariantJobResult r =
      lattice_variant_job(lv_abs, fixture_dir, lv_out, materials, rules);

  // ── Z1: NO LADDER RUNS.
  CHECK(r.design_iterations == 0, "Z1: zero design iterations");
  CHECK(r.variant_meshes_written == 0, "Z1: zero variant meshes written");
  CHECK(r.analysis_solves >= 2 && r.analysis_solves <= 4,
        "Z1: a small FIXED number of certification solves (the reproduction "
        "proof, the pipeline's own reproduction, the composite, and the "
        "band-clamp counterfactual when one was needed) — never a design loop");
  {
    int variant_meshes = 0, lattice_meshes = 0;
    for (const auto& e : std::filesystem::directory_iterator(lv_out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 4 && n.substr(n.size() - 4) == ".stl") {
        if (contains(n, "_lattice")) ++lattice_meshes;
        else ++variant_meshes;
      }
    }
    CHECK(variant_meshes == 0,
          "Z1: the output directory holds NO optimizer variant meshes");
    CHECK(lattice_meshes == 1, "Z1: exactly the latticed file was written");
  }
  std::printf("[Z1] lattice-variant wall time: %.2f s (%d certification "
              "solves, 0 design iterations)\n",
              r.wall_seconds, r.analysis_solves);

  // ── Z2: THE LOAD CASE IS THE SAME ONE.
  const std::string run_lc = read_file(run.loadcase_receipt_path);
  const std::string lv_lc = read_file(r.loadcase_receipt_path);
  CHECK(!run_lc.empty() && run_lc == lv_lc,
        "Z2: the re-lattice run resolved the IDENTICAL load case — its "
        "loadcase.json is byte-for-byte the optimize run's (anchor faces, "
        "clamped DOF, and per group the resolved force magnitude and the "
        "voxels its faces tagged)");
  CHECK(contains(run_lc, "\"fixture_voxels_tagged\": ") &&
            json_number(run_lc, "fixture_voxels_tagged") > 0.0,
        "Z2: the receipt records the tagged voxel count, not just that a load "
        "exists");
  CHECK(json_number(run_lc, "anchor_bc_dofs") > 0.0,
        "Z2: the receipt records the clamped DOF count");
  CHECK(r.reproduction_exact &&
            r.reproduced_margin_worst_case == r.recorded_margin_worst_case,
        "Z2: the restored design reproduces the RECORDED margin exactly");
  CHECK(r.recorded_margin_worst_case ==
            run.pipeline.evaluated[0].report.margin.worst_case,
        "Z2: and that recorded margin is the one the original run reported");

  // Z2 NEGATIVE: re-author the load case differently (a coarser resolution is
  // the smallest honest change that moves the tagged voxel counts) and the job
  // must REFUSE rather than certify under a load case that is merely similar.
  {
    JobDescription bad = lv_abs;
    bad.resolution = 48;
    bool threw = false;
    std::string what;
    try {
      lattice_variant_job(bad, fixture_dir, tmp + "/lv_bad", materials, rules);
    } catch (const JobError& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw, "Z2: a job whose load case does not match the stored design "
                 "is REFUSED, never silently certified");
    if (!threw || !contains(what, "grid does not match"))
      std::fprintf(stderr, "  (resolution-mismatch refusal said: %s)\n",
                   what.c_str());
    CHECK(contains(what, "grid does not match"),
          "Z2: and the refusal names the reason");
  }
  // Z2 NEGATIVE, subtler: same grid, different FORCE. The self-weight fixture
  // has no force groups, so move gravity instead — the design is unchanged, the
  // grid is unchanged, only the load differs, and the reproduction check is the
  // only thing standing between that and a wrong certificate.
  {
    JobDescription bad = lv_abs;
    bad.gravity.magnitude_mm_s2 = 9810.0 * 2.0;
    bool threw = false;
    std::string what;
    try {
      lattice_variant_job(bad, fixture_dir, tmp + "/lv_bad2", materials, rules);
    } catch (const JobError& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw,
          "Z2: a DIFFERENT load on the same grid and the same design is caught "
          "by the reproduction check and REFUSED");
    CHECK(contains(what, "does NOT reproduce the margin"),
          "Z2: and the refusal says the margin did not reproduce");
  }

  // ── Z3: THE CERTIFIED OBJECT IS THE EXPORTED ONE.
  const std::string prov = read_file(r.provenance_path);
  CHECK(r.design_fingerprint == store.variants[0].fingerprint,
        "Z3: the design this job latticed is the one on record (fingerprint)");
  CHECK(contains(prov, "\"design_fingerprint\": \"" +
                           std::to_string(r.design_fingerprint) + "\""),
        "Z3: the provenance names that fingerprint");
  CHECK(contains(prov, "\"design_iterations\": 0") &&
            contains(prov, "\"variant_meshes_written\": 0"),
        "Z1: the provenance states the no-ladder facts");
  // A corrupted store must never reach the gate.
  {
    const std::string corrupt = tmp + "/lv_corrupt_design.bin";
    std::string bytes = read_file(run.design_path);
    CHECK(bytes.size() > 4096, "design.bin is substantial enough to corrupt");
    bytes[bytes.size() - 9] = static_cast<char>(bytes[bytes.size() - 9] ^ 0x40);
    { std::ofstream o(corrupt, std::ios::binary); o << bytes; }
    bool threw = false;
    std::string what;
    try {
      read_design_file(corrupt);
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw && contains(what, "fingerprint"),
          "Z3: a design that does not hash to its record is refused, not "
          "certified");
  }

  // ── Z5: THE STRUT-STRENGTH REPORT COMES ALONG.
  const std::string rcpt = read_file(r.lattice_receipt_path);
  CHECK(!rcpt.empty(), "the per-variant lattice receipt was written");
  CHECK(contains(rcpt, "\"strut_strength\""),
        "Z5: the strut-strength report is on THIS path's receipt");
  CHECK(contains(rcpt, "\"margin_in_plane\"") &&
            contains(rcpt, "\"margin_interlayer\""),
        "Z5: with the in-plane and interlayer margins reported SEPARATELY");
  CHECK(contains(rcpt, "\"gated\": false"),
        "Z5: and still labelled report-only, exactly as on the optimize path");
  CHECK(r.lattice.lattice_strut_report,
        "Z5: the result carries the strut report too");
  CHECK(contains(rcpt, "\"solid_margin_reproduced\""),
        "the receipt keeps the null-posture reproduction proof");

  // The receipt describes the SAME object the mesh is: same cell, and the
  // certified lattice voxel count is non-zero.
  CHECK(json_number(rcpt, "lattice_voxels") > 0.0,
        "Z3: a non-empty lattice region was certified");
  CHECK(r.mesh_paths.size() == 1 &&
            std::filesystem::exists(r.mesh_paths[0]),
        "the latticed mesh was written");

  // ── Z8: DETERMINISM. Every written file byte-identical on a rerun.
  {
    const std::string lv_out2 = tmp + "/lv_lattice_2";
    std::filesystem::remove_all(lv_out2);
    const LatticeVariantJobResult r2 =
        lattice_variant_job(lv_abs, fixture_dir, lv_out2, materials, rules);
    CHECK(read_file(r2.mesh_paths[0]) == read_file(r.mesh_paths[0]),
          "Z8: the latticed mesh is byte-identical on a rerun");
    CHECK(read_file(r2.lattice_receipt_path) == rcpt,
          "Z8: the lattice receipt is byte-identical on a rerun");
    CHECK(read_file(r2.report_path) == read_file(r.report_path),
          "Z8: the report is byte-identical on a rerun");
    CHECK(read_file(r2.provenance_path) == prov,
          "Z8: the provenance is byte-identical on a rerun (no wall clock in "
          "any written artifact)");
    CHECK(read_file(r2.loadcase_receipt_path) == lv_lc,
          "Z8: the load-case receipt is byte-identical on a rerun");
    CHECK(read_file(r2.fields_path) == read_file(r.fields_path),
          "Z8: fields.bin is byte-identical on a rerun");
  }

  // ── the ORIGINAL run is itself deterministic with the new artifacts in it:
  // design.bin and loadcase.json must not introduce any nondeterminism.
  {
    const std::string run_out2 = tmp + "/lv_run_2";
    std::filesystem::remove_all(run_out2);
    const RunJobResult run2 =
        run_job(original, fixture_dir, run_out2, materials, rules,
                /*emit_progress=*/false, RunObservability{});
    CHECK(read_file(run2.design_path) == read_file(run.design_path),
          "Z8: design.bin is byte-identical across two identical runs");
    CHECK(read_file(run2.loadcase_receipt_path) == run_lc,
          "Z8: loadcase.json is byte-identical across two identical runs");
    CHECK(read_file(run2.report_path) == read_file(run.report_path),
          "Z6/Z8: the optimize run's report is unchanged and deterministic");
    CHECK(read_file(run2.fields_path) == read_file(run.fields_path),
          "Z6/Z8: the optimize run's fields.bin is unchanged and deterministic");
  }
}

// ---------------------------------------------------------------------------
// B. Z4 — AUTO GRADING WITH NO SIM, on a thick cylinder.
static void section_graded() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  const std::string cyl_path = tmp + "/lv_cyl.stl";
  write_stl_file(cyl_path, cylinder_mesh(40.0, 80.0, 48), StlFormat::Binary);
  double fitted_r = 0.0;
  {
    const StepModel part = import_part_file(cyl_path);
    for (int f = 0; f < part.face_count; ++f)
      if (part.faces[static_cast<std::size_t>(f)].kind ==
          StepSurfaceKind::Cylinder)
        fitted_r = part.faces[static_cast<std::size_t>(f)].cylinder_radius_mm;
  }
  CHECK(fitted_r > 10.0, "cylinder fixture: side wall segments as a cylinder");

  JobDescription original;
  original.model = "lv_cyl.stl";
  original.material = "PLA";
  original.mode = "minimize_plastic";
  original.resolution = 32;
  original.fixture_faces.push_back(JobFaceSelector{"cylindrical", fitted_r});
  original.gravity.direction = Vec3{0.0, 0.0, -1.0};
  original.gravity.magnitude_mm_s2 = 9810.0;
  original.ladder = {0.7};
  original.margin_stop = 0.0;
  original.simp_max_iterations = 8;
  original.output.report = "report.json";
  original.output.mesh_format = "stl";
  original.output.mesh_prefix = "variant";

  const std::string run_out = tmp + "/lv_g_run";
  std::filesystem::remove_all(run_out);
  const RunJobResult run = run_job(original, tmp, run_out, materials, rules,
                                   /*emit_progress=*/false, RunObservability{});
  CHECK(run.design_variant_count >= 1, "graded flow: the run stored a design");

  // The re-lattice job asks for GRADED density. Note what is NOT here: no
  // stress field input, no simulation step, no second run. The demand field is
  // recovered from the stored design by the reproduction solve this job runs
  // anyway — which is the whole of "Auto density is available immediately".
  JobDescription lv = original;
  lv.mode = "lattice_variant";
  lv.variant.present = true;
  lv.variant.design = run.design_path;
  lv.variant.has_volume_fraction = true;
  lv.variant.volume_fraction = 0.7;  // named by RUNG, the app's join key
  lv.lattice.present = true;
  lv.lattice.topology = "octet";
  lv.lattice.emit_stl = true;
  lv.grading.present = true;
  lv.grading.topology = "octet";
  lv.grading.cell_mm = 3.0;
  lv.grading.min_extrudable_width_mm = 0.42;
  lv.grading.demand_exponent = 1.0;

  const std::string lv_out = tmp + "/lv_g_lattice";
  std::filesystem::remove_all(lv_out);
  const LatticeVariantJobResult r =
      lattice_variant_job(lv, tmp, lv_out, materials, rules);

  CHECK(r.requested_volume_fraction == 0.7,
        "Z4: the rung named by volume_fraction is the one that was latticed");
  CHECK(r.graded, "Z4: the graded path ran");
  CHECK(r.rho_max_used > r.rho_min_used,
        "Z4: per-voxel relative density VARIES across the part — a graded "
        "lattice, not a uniform one wearing the label");
  CHECK(r.rho_min_used >= lattice_rho_min(LatticeTopology::Octet) &&
            r.rho_max_used <= lattice_rho_max(LatticeTopology::Octet),
        "Z4: and every graded density sits inside the certifiable band core "
        "owns");
  std::printf("[Z4] graded from the variant's own stored design, NO sim: rho "
              "%.4f .. %.4f over %lld latticed voxels, cell %.3f mm\n",
              r.rho_min_used, r.rho_max_used, r.latticed_voxels,
              r.cell_size_mm);
  CHECK(r.latticed_voxels > 0, "Z4: a non-empty graded lattice was certified");

  const std::string prov = read_file(r.provenance_path);
  CHECK(contains(prov, "field_provenance"),
        "Z4: the provenance states WHERE the demand field came from");
  CHECK(contains(prov, "THIS variant's own certification von Mises field"),
        "Z4: and that it is this variant's own field, not the solid part's");

  const std::string rcpt = read_file(r.lattice_receipt_path);
  CHECK(contains(rcpt, "\"grading\""), "Z4: the receipt carries the law's record");
  CHECK(contains(rcpt, "\"graded_from\""),
        "Z4: including the field's provenance block");
  CHECK(contains(rcpt, "\"strut_strength\""),
        "Z5: the strut report is present on the GRADED re-lattice path too");

  // Z8 on the graded path.
  {
    const std::string lv_out2 = tmp + "/lv_g_lattice_2";
    std::filesystem::remove_all(lv_out2);
    const LatticeVariantJobResult r2 =
        lattice_variant_job(lv, tmp, lv_out2, materials, rules);
    CHECK(read_file(r2.mesh_paths[0]) == read_file(r.mesh_paths[0]),
          "Z8: the graded latticed mesh is byte-identical on a rerun");
    CHECK(read_file(r2.lattice_receipt_path) == rcpt,
          "Z8: the graded receipt is byte-identical on a rerun");
  }
}

// ---------------------------------------------------------------------------
// D. Task 2026-08-04-variant-volume-fraction-mismatch — WHICH VARIANT, AND WHAT
//    HAPPENS WHEN THERE IS NO LATTICE TO EMIT.
//
//   A2/A3 The variant is named by its DESIGN FINGERPRINT, and the achieved
//         volume fraction it carries is CHECKED against the stored design. The
//         (0, 1] bound on `variant.volume_fraction` is untouched — a growth
//         ladder's rung simply stopped travelling in that key.
//   L3    A configuration the grading law can lattice NOTHING of is REFUSED
//         with the predicate and the counts, not emitted as a file with zero
//         struts in it and reported as a successful build.
static void section_identity_and_zero_density() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  // The same cylinder the graded section uses — thick enough that a sane cell
  // DOES lattice it, so the refusal below is about the configuration and not
  // about a fixture that could never work.
  const std::string cyl_path = tmp + "/lv_id_cyl.stl";
  write_stl_file(cyl_path, cylinder_mesh(40.0, 80.0, 48), StlFormat::Binary);
  double fitted_r = 0.0;
  {
    const StepModel part = import_part_file(cyl_path);
    for (int f = 0; f < part.face_count; ++f)
      if (part.faces[static_cast<std::size_t>(f)].kind ==
          StepSurfaceKind::Cylinder)
        fitted_r = part.faces[static_cast<std::size_t>(f)].cylinder_radius_mm;
  }

  JobDescription original;
  original.model = "lv_id_cyl.stl";
  original.material = "PLA";
  original.mode = "minimize_plastic";
  original.resolution = 32;
  original.fixture_faces.push_back(JobFaceSelector{"cylindrical", fitted_r});
  original.gravity.direction = Vec3{0.0, 0.0, -1.0};
  original.gravity.magnitude_mm_s2 = 9810.0;
  original.ladder = {0.7};
  original.margin_stop = 0.0;
  original.simp_max_iterations = 8;
  original.output.report = "report.json";
  original.output.mesh_format = "stl";
  original.output.mesh_prefix = "variant";

  const std::string run_out = tmp + "/lv_id_run";
  std::filesystem::remove_all(run_out);
  const RunJobResult run = run_job(original, tmp, run_out, materials, rules,
                                   /*emit_progress=*/false, RunObservability{});
  CHECK(run.design_variant_count >= 1, "identity flow: the run stored a design");

  const DesignStore store = read_design_file(run.design_path);
  CHECK(!store.variants.empty(), "identity flow: the container holds a block");
  const StoredDesign& sd = store.variants[0];

  // ── A3: SELECT BY FINGERPRINT, CHECK THE ACHIEVED FRACTION ────────────────
  JobDescription lv = original;
  lv.mode = "lattice_variant";
  lv.variant.present = true;
  lv.variant.design = run.design_path;
  lv.variant.has_fingerprint = true;
  lv.variant.fingerprint = sd.fingerprint;
  lv.variant.has_achieved_volume_fraction = true;
  lv.variant.achieved_volume_fraction = sd.achieved_volume_fraction;
  lv.lattice.present = true;
  lv.lattice.topology = "octet";
  lv.lattice.cell_mm = 3.0;
  lv.lattice.strut_radius_mm = 0.45;
  lv.lattice.emit_stl = true;

  const std::string lv_out = tmp + "/lv_id_lattice";
  std::filesystem::remove_all(lv_out);
  const LatticeVariantJobResult r =
      lattice_variant_job(lv, tmp, lv_out, materials, rules);
  CHECK(r.design_fingerprint == sd.fingerprint,
        "A3: the design the job named by fingerprint is the design it latticed");
  CHECK(r.achieved_volume_fraction == sd.achieved_volume_fraction,
        "A3: and it reports that design's own achieved fraction");
  CHECK(r.latticed_voxels > 0, "A3: the fingerprint-selected job really ran");

  // A fingerprint the container does not hold is REFUSED, and the message says
  // what it does hold — never a nearest-design guess.
  {
    JobDescription bad = lv;
    bad.variant.fingerprint = sd.fingerprint ^ 0xFFULL;
    bool threw = false;
    std::string what;
    try {
      lattice_variant_job(bad, tmp, tmp + "/lv_id_bad_fp", materials, rules);
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw && contains(what, "no stored design with fingerprint"),
          "A3: an unknown design fingerprint is refused by name");
  }

  // *** THE BAR A3 CHECK, ENFORCED AT RUNTIME. *** A job that says this variant
  // achieved one number while the stored design achieved another is describing a
  // different variant than the one it selected, and is refused.
  {
    JobDescription bad = lv;
    bad.variant.achieved_volume_fraction = sd.achieved_volume_fraction * 0.5;
    bool threw = false;
    std::string what;
    try {
      lattice_variant_job(bad, tmp, tmp + "/lv_id_bad_vf", materials, rules);
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw && contains(what, "describing a different variant"),
          "A3: a job whose achieved fraction is not the design's is refused");
  }

  // ── L3: A ZERO-DENSITY LATTICE IS REFUSED, NOT EMITTED ────────────────────
  //
  // The cell is far wider than the part, so no member holds the cells-per-member
  // floor and the grading law lattices NOTHING. Before this task that produced a
  // "lattice" with rho_min_used 0, rho_max_used 0, strut radius 0.00 mm and a
  // strut-strength margin computed on no material — reported as a build.
  {
    JobDescription none = lv;
    none.lattice.cell_mm = 0.0;          // the grading block owns the cell
    none.lattice.strut_radius_mm = 0.0;
    none.grading.present = true;
    none.grading.topology = "octet";
    none.grading.cell_mm = 200.0;        // 5 cells across ⇒ a 1000 mm member
    none.grading.min_extrudable_width_mm = 0.42;
    none.grading.demand_exponent = 1.0;

    const std::string out = tmp + "/lv_id_zero";
    std::filesystem::remove_all(out);
    bool threw = false;
    std::string what;
    try {
      lattice_variant_job(none, tmp, out, materials, rules);
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw, "L3: a configuration that lattices NOTHING is refused");
    CHECK(contains(what, "could lattice NONE"),
          "L3: and the refusal names the predicate");
    CHECK(contains(what, "member_too_thin_for_cell="),
          "L3: with the per-reason counts");
    CHECK(contains(what, "min_extrudable_width_mm"),
          "L3: and the extrusion width that sets the printability floor — the "
          "knob that actually unlocks it");
    // NOTHING was written. A refusal that still left a zero-strut mesh on disk
    // would be the same failure with an error message attached.
    int meshes = 0;
    if (std::filesystem::exists(out))
      for (const auto& e : std::filesystem::directory_iterator(out))
        if (e.path().extension() == ".stl") ++meshes;
    CHECK(meshes == 0,
          "L3: and no geometry was emitted — the refusal is a refusal, not a "
          "warning printed beside a file with no struts in it");
    std::printf("[L3] zero-density lattice refused: %s\n", what.c_str());
  }

  // ── THE FORECAST NAMES THE EXTRUSION-WIDTH REMEDY ─────────────────────────
  //
  // `irrecoverable_by_any_cell_size` is true only INSIDE a fixed printability
  // floor, and that floor is `min_extrudable_width_mm / phi(rho_lo, unit cell)` —
  // a DECLARED parameter over a constant. The forecast used to withhold every
  // remedy in this case and then state "no parameter change could help", which is
  // measurably false and is what the maintainer read for a week.
  //
  // Declared width 0.8 mm puts the floor at ~8.8 mm; the widest member here is
  // ~25 mm and needs 5 cells, so no legal cell reaches it and nothing lattices.
  // A finer declared width does.
  {
    JobDescription fc = lv;
    fc.lattice.cell_mm = 0.0;
    fc.lattice.strut_radius_mm = 0.0;
    fc.lattice.forecast_only = true;
    fc.lattice.min_extrudable_width_mm = 0.8;
    fc.grading.present = true;
    fc.grading.topology = "octet";
    fc.grading.cell_mm = 0.0;            // Auto ⇒ the law takes the floor
    fc.grading.cell_mode = "auto";
    fc.grading.min_extrudable_width_mm = 0.8;
    fc.grading.demand_exponent = 1.0;

    const std::string out = tmp + "/lv_id_fc";
    std::filesystem::remove_all(out);
    const LatticeVariantJobResult fr =
        lattice_variant_job(fc, tmp, out, materials, rules);
    const std::string j = read_file(fr.forecast_path);
    CHECK(contains(j, "\"would_lattice_voxels\": 0"),
          "the 0.8 mm declared width lattices nothing — the case the forecast "
          "used to call hopeless");
    CHECK(contains(j, "lattice.min_extrudable_width_mm"),
          "the forecast now NAMES the extrusion width as an evaluated remedy");
    CHECK(contains(j, "\"cell_mm\":"),
          "and carries the cell that width unlocks — the remedy is genuinely "
          "two-dimensional and half of it is not actionable");
    CHECK(!contains(j, "no parameter change could help"),
          "and it no longer claims to have exhausted the space it never probed");
    std::printf("[B] extrusion-width remedy present in the forecast\n");
  }
}

// ---------------------------------------------------------------------------
// C. Schema: the mode and its block are validated STRICTLY, before any work.
static void section_schema() {
  auto parse_fails = [](const std::string& json, const std::string& needle) {
    try {
      parse_job(json);
    } catch (const JobError& e) {
      return contains(std::string(e.what()), needle);
    }
    return false;
  };
  const std::string base =
      R"({"model":"p.stl","material":"PLA","resolution":32,)"
      R"("output":{"report":"r.json","mesh_format":"stl","mesh_prefix":"v"},)"
      R"("fixture_faces":[{"kind":"cylindrical","radius_mm":3}],)"
      R"("gravity":{"direction":[0,0,-1],"magnitude_mm_s2":9810},)"
      R"("ladder":[0.6],"margin_stop":0,)";

  CHECK(parse_fails(base + R"("mode":"lattice_variant"})",
                    "requires a \"variant\" block"),
        "schema: lattice_variant without a variant block is refused");
  CHECK(parse_fails(base +
                        R"("mode":"minimize_plastic","variant":{"design":"d.bin","index":0}})",
                    "only allowed with"),
        "schema: a variant block on a non-lattice_variant job is refused");
  CHECK(parse_fails(base +
                        R"("mode":"lattice_variant","variant":{"design":"d.bin","index":0,"volume_fraction":0.6},)"
                        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})",
                    "EXACTLY ONE"),
        "schema: index AND volume_fraction together is refused");
  CHECK(parse_fails(base + R"("mode":"lattice_variant","variant":{"design":"d.bin","index":0}})",
                    "requires a \"lattice\" block"),
        "schema: lattice_variant without a lattice block is refused");
  CHECK(parse_fails(base + R"("mode":"nonsense"})", "lattice_variant"),
        "schema: an unknown mode is refused and the message names the three "
        "valid ones");
  {
    const JobDescription ok = parse_job(
        base +
        R"("mode":"lattice_variant","variant":{"design":"d.bin","volume_fraction":0.6},)"
        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})");
    CHECK(ok.mode == "lattice_variant" && ok.variant.present &&
              ok.variant.has_volume_fraction && !ok.variant.has_index &&
              ok.variant.volume_fraction == 0.6 && ok.variant.design == "d.bin",
          "schema: a well-formed lattice_variant job parses");
  }

  // ── Task 2026-08-04-variant-volume-fraction-mismatch ──────────────────────
  //
  // A2: THE BOUND IS UNTOUCHED. The maintainer's growth rung (1.1) is still
  // refused in this key, and must stay refused: a number that describes a part's
  // volume fraction belongs in (0, 1]. What changed is that a ladder POSITION no
  // longer travels in a field shaped like a fraction.
  CHECK(parse_fails(base +
                        R"("mode":"lattice_variant","variant":{"design":"d.bin","volume_fraction":1.1},)"
                        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})",
                    "must be in (0, 1]"),
        "A2: variant.volume_fraction > 1 is STILL refused — the bound was never "
        "the problem and was not widened");
  CHECK(parse_fails(base +
                        R"("mode":"lattice_variant","variant":{"design":"d.bin","volume_fraction":0},)"
                        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})",
                    "must be in (0, 1]"),
        "A2: and 0 is still refused at the other end");
  {
    // The FINGERPRINT form: a u64 as a decimal string, parsed exactly. The
    // maintainer's 1.10 rung hashes to 2898949975693851963, which a JSON double
    // cannot hold — which is why the wire form is text.
    const JobDescription fp = parse_job(
        base +
        R"("mode":"lattice_variant","variant":{"design":"d.bin",)"
        R"("fingerprint":"2898949975693851963","achieved_volume_fraction":1.0866043075327818},)"
        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})");
    CHECK(fp.variant.has_fingerprint &&
              fp.variant.fingerprint == 2898949975693851963ULL,
          "A1: the design fingerprint round-trips EXACTLY through the wire form "
          "— a JSON double would have lost the low digits");
    CHECK(fp.variant.has_achieved_volume_fraction &&
              fp.variant.achieved_volume_fraction == 1.0866043075327818,
          "A3: and a GROWTH variant's achieved fraction — part-relative, and "
          "legitimately > 1 — is carried as measured, not clamped");
    CHECK(!fp.variant.has_volume_fraction && !fp.variant.has_index,
          "the fingerprint form is a selector in its own right");
  }
  CHECK(parse_fails(base +
                        R"("mode":"lattice_variant","variant":{"design":"d.bin","fingerprint":"12","index":0},)"
                        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})",
                    "EXACTLY ONE"),
        "schema: two selectors together is refused, as with the original pair");
  CHECK(parse_fails(base +
                        R"("mode":"lattice_variant","variant":{"design":"d.bin","fingerprint":"0x1f"},)"
                        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})",
                    "DECIMAL STRING"),
        "schema: a fingerprint that is not decimal digits is refused, never "
        "half-parsed");
  CHECK(parse_fails(base +
                        R"("mode":"lattice_variant","variant":{"design":"d.bin","fingerprint":"12",)"
                        R"("achieved_volume_fraction":0},)"
                        R"("lattice":{"cell_mm":3,"strut_radius_mm":0.45}})",
                    "achieved_volume_fraction\" must be > 0"),
        "schema: a non-positive achieved fraction is refused — it describes no "
        "part");
}

// ---------------------------------------------------------------------------
// ★ "LATTICE THIS" — lattice_part: THE IMPORTED PART, NO OPTIMIZATION
// (task 2026-08-17-lattice-stage-repair; maintainer: "implement a 'Lattice This'
// button just above the 'Optimize' button ... which only lattices the selection
// and does not optimize").
//
// ★ WHY A NEW MODE WAS NEEDED AT ALL. Core took exactly three modes, and the
// only latticing one — `lattice_variant` — is DEFINED by the finished design it
// selects: it refuses without a `variant` block naming a design.bin and a rung.
// There is no design when nothing has been optimized. `lattice_part` asks the
// other question: lattice the part AS IMPORTED. Everything downstream is shared
// verbatim — same load case, same certification solves, same grading law, same
// mesh emission — so this is one branch, not a second pipeline.
static void section_lattice_part() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);
  const std::string out = tmp + "/lattice_part";
  std::filesystem::remove_all(out);
  std::filesystem::create_directories(out);

  // The SAME plate the variant flow uses, so the only thing that differs from
  // the shipping path is that NOTHING WAS OPTIMIZED first.
  JobDescription job = plate_job();
  job.mode = "lattice_part";
  job.lattice.present = true;
  job.lattice.topology = "octet";
  job.lattice.cell_mm = 3.0;
  job.lattice.strut_radius_mm = 0.45;   // rho ~0.41, inside the band
  job.lattice.emit_stl = true;

  LatticeVariantJobResult r;
  bool threw = false;
  std::string why;
  try {
    r = lattice_variant_job(job, fixture_dir, out, materials, rules);
  } catch (const std::exception& e) {
    threw = true;
    why = e.what();
  }
  CHECK(!threw, ("lattice_part runs with NO variant block and NO design.bin: " +
                 why).c_str());
  if (threw) return;

  // ★ THE PART IS THE DESIGN, and its fraction is MEASURED — the part's own
  // occupancy of its grid. Reporting 1.0 would claim the bounding BOX is solid
  // and every mass and saving downstream would be wrong by that ratio.
  CHECK(r.requested_volume_fraction > 0.0 &&
            r.requested_volume_fraction <= 1.0,
        "lattice_part: the volume fraction is the part's own occupancy");
  CHECK(r.design_fingerprint != 0,
        "lattice_part: the synthesised design still has an identity");

  // ★★ AND IT ACTUALLY LATTICED SOMETHING. A job that runs clean and emits an
  // empty lattice is the failure this whole area was bitten by for weeks.
  CHECK(r.latticed_voxels > 0, "lattice_part: the run latticed real voxels");
}

// ★ THE SCHEMA HALF: the two modes are distinguished, and each refuses what
// belongs to the other.
static void section_lattice_part_schema() {
  auto parse_fails = [](const std::string& json, const std::string& needle) {
    try {
      parse_job(json);
    } catch (const JobError& e) {
      return contains(std::string(e.what()), needle);
    }
    return false;
  };
  const std::string base =
      R"({"model":"m.step","material":"PLA","resolution":16,)"
      R"("fixture_faces":[{"kind":"cylindrical","radius_mm":1}],)"
      R"("gravity":{"direction":[0,0,-1],"magnitude_mm_s2":9810},)"
      R"("ladder":[0.5],"margin_stop":1.5,)"
      R"("output":{"report":"r.json","mesh_format":"stl","mesh_prefix":"v"},)";

  // ★ `lattice_part` NEEDS A LATTICE BLOCK — it exists to lattice, and a job
  // with no lattice work is a mistake rather than a no-op.
  CHECK(parse_fails(base + R"("mode":"lattice_part"})", "lattice_part"),
        "lattice_part with no lattice block is refused");

  // ★ AND IT TAKES NO VARIANT — there is no design to select.
  CHECK(parse_fails(base +
                        R"("mode":"lattice_part",)"
                        R"("variant":{"design":"d.bin","index":0},)"
                        R"("lattice":{"topology":"octet","cell_mm":3,)"
                        R"("strut_radius_mm":0.45,"emit_stl":true}})",
                    "variant"),
        "lattice_part refuses a variant block");

  // …and the refusal for a bare lattice_variant now POINTS AT the new mode, so
  // the message names the thing the user actually wanted.
  CHECK(parse_fails(base + R"("mode":"lattice_variant"})", "lattice_part"),
        "the lattice_variant refusal names lattice_part as the alternative");

  // The accepting case parses and keeps its mode.
  {
    const std::string ok_json =
        base +
        R"("mode":"lattice_part",)"
        R"("lattice":{"topology":"octet","cell_mm":3,"strut_radius_mm":0.45,)"
        R"("emit_stl":true}})";
    JobDescription ok = parse_job(ok_json);
    CHECK(ok.mode == "lattice_part" && !ok.variant.present &&
              ok.lattice.present,
          "lattice_part parses, carries a lattice block and no variant");
  }
}

int main() {
  section_schema();
  section_flow();
  section_graded();
  section_identity_and_zero_density();
  section_lattice_part_schema();
  section_lattice_part();
  std::printf("test_lattice_variant: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
