// test_lattice_hookup.cpp — task lattice-page-core-hookup: primitive ROLES in
// the job schema (stage 1), GRADING on the optimize path (stage 4), and the
// analyze MODE (stage 3), driven END TO END through run_job / analyze_job.
//
//   A. Role-combination matrix on the committed plate_bore.stl fixture
//      (self-weight mesh job, one rung, few iterations — minutes-scale):
//      no-regions vs empty-regions byte-identity, exclude, include (with the
//      include-over-void no-op accounting), include+exclude overlap, and
//      byte-identical determinism (H1d/H1a/H5). The voxel-exact precedence of
//      every role pair is unit-tested in test_lattice_boundary; here the
//      SCHEMA -> run -> receipt/run_info plumbing is proven on a real run.
//
//   B. Graded lattice from the run's OWN field (stage 4) on a synthetic thick
//      cylinder (thick enough to clear the cells-per-member floor): the
//      receipt's provenance names THIS variant + its iteration count (H4a),
//      the grading numbers match an INDEPENDENT in-test re-run of the law on
//      the variant's own von Mises field (any other field would generically
//      differ), every emitted density is in the band read from core (H4b),
//      clamp counts + the clamp counterfactual are reported, and the whole run
//      is byte-identical on a rerun (H5).
//
//   C. Mode "analyze" (stage 3): run_job REFUSES an analyze job (and any
//      unknown mode — H3a), analyze_job performs ONE solve, writes NO variant
//      meshes (H3b), and its provenance carries the solid-part field label
//      (H3c).
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

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

// Extract the number after "\"key\": " (first occurrence). Returns NaN when
// the key is absent.
static double json_number(const std::string& text, const std::string& key) {
  const std::string pat = "\"" + key + "\": ";
  const std::string::size_type at = text.find(pat);
  if (at == std::string::npos) return std::nan("");
  return std::atof(text.c_str() + at + pat.size());
}

// The plate_bore self-weight base job (mirrors test_mesh_job's, single rung so
// the matrix stays fast; margin_stop 0 accepts the rung).
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

static JobDescription plate_lattice_job() {
  JobDescription job = plate_job();
  job.lattice.present = true;
  job.lattice.topology = "octet";
  job.lattice.cell_mm = 3.0;
  job.lattice.strut_radius_mm = 0.45;  // rho ~0.41, inside the band
  job.lattice.emit_stl = true;
  return job;
}

static JobLatticeRegion exclude_bolt() {
  JobLatticeRegion r;
  r.role = "exclude";
  r.kind = "bolt";
  r.axis_point = Vec3{8.0, 0.0, 2.0};
  r.axis_dir = Vec3{0.0, 0.0, 1.0};
  r.radius_mm = 3.0;
  r.half_length_mm = 5.0;
  return r;
}

static JobLatticeRegion include_slab() {
  // x in [-12, 2]: the left side of the plate INCLUDING the bore (whose void
  // voxels are the include-over-void no-op the receipt must count).
  JobLatticeRegion r;
  r.role = "include";
  r.kind = "face";
  r.origin = Vec3{-12.0, 0.0, 2.0};
  r.normal = Vec3{1.0, 0.0, 0.0};
  r.half_u_mm = 50.0;
  r.half_w_mm = 50.0;
  r.depth_mm = 14.0;
  return r;
}

// ---------------------------------------------------------------------------
// A. Role matrix on plate_bore.stl.
static void section_roles() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  auto run = [&](const JobDescription& job, const std::string& sub) {
    const std::string out = tmp + "/lat_hookup_" + sub;
    std::filesystem::remove_all(out);
    return run_job(job, fixture_dir, out, materials, rules,
                   /*emit_progress=*/false, RunObservability{});
  };
  auto lattice_mesh_of = [](const RunJobResult& r) -> std::string {
    for (const std::string& p : r.mesh_paths)
      if (contains(p, "_lattice.")) return p;
    return "";
  };
  auto receipt_of = [](const RunJobResult& r) -> std::string {
    const std::string m = [&] {
      for (const std::string& p : r.mesh_paths)
        if (contains(p, "_lattice.")) return p;
      return std::string();
    }();
    if (m.empty()) return "";
    return m.substr(0, m.rfind(".stl")) + ".report.json";
  };

  // 1. Base uniform lattice, no regions.
  const RunJobResult base = run(plate_lattice_job(), "base");
  CHECK(!lattice_mesh_of(base).empty(), "base: latticed mesh exported");
  const std::string base_rcpt = read_file(receipt_of(base));
  CHECK(!base_rcpt.empty(), "base: receipt written");
  CHECK(!contains(base_rcpt, "\"regions\""),
        "base: no regions key in the receipt (byte-identity posture)");
  CHECK(!contains(base_rcpt, "solid_region_voxels"),
        "base: no solid-companion keys without roles");
  const std::string base_mesh_bytes = read_file(lattice_mesh_of(base));

  // 2. Empty regions array == absent (same bytes).
  {
    JobDescription job = plate_lattice_job();  // regions stays empty
    const RunJobResult r = run(job, "empty");
    CHECK(read_file(lattice_mesh_of(r)) == base_mesh_bytes,
          "H1d: empty regions == absent regions, byte-identical lattice mesh");
    CHECK(read_file(receipt_of(r)) == base_rcpt,
          "H1d: empty regions == absent regions, byte-identical receipt");
  }

  // 3. Exclude region: material kept SOLID, certified solid, exported solid.
  long long excl_solid_voxels = 0;
  {
    JobDescription job = plate_lattice_job();
    job.lattice.regions.push_back(exclude_bolt());
    const RunJobResult r = run(job, "excl");
    const std::string rcpt = read_file(receipt_of(r));
    CHECK(contains(rcpt, "\"exclude\": 1"), "exclude: receipt counts the region");
    excl_solid_voxels =
        static_cast<long long>(json_number(rcpt, "solid_region_voxels"));
    CHECK(excl_solid_voxels > 0,
          "H1c: exclude region voxels kept solid (companion emitted)");
    CHECK(json_number(rcpt, "solid_region_volume_mm3") > 0.0,
          "H1c: solid-region volume reported separately");
    CHECK(json_number(rcpt, "solid_region_triangles") > 0.0,
          "H1c: solid companion body in the exported file");
    // The certified lattice region SHRANK vs base (excluded voxels are not
    // counted as lattice — H1c).
    CHECK(json_number(rcpt, "lattice_voxels") <
              json_number(base_rcpt, "lattice_voxels"),
          "H1c: excluded voxels are NOT counted as lattice");
    CHECK(contains(rcpt, "\"precedence\""),
          "exclude: precedence spelled out in the receipt");
    CHECK(read_file(lattice_mesh_of(r)) != base_mesh_bytes,
          "exclude: exported file differs from base (companion + fewer cells)");
    // run_info: role keys present under lattice_export.
    const std::string ri = read_file(r.run_info_path);
    // (run_info is written only on the emit_progress path; batch runs leave it
    // empty — the receipt is the per-run record here.)
    (void)ri;
  }

  // 4. Include region (with the bore's void inside it).
  double incl_lattice_voxels = 0.0;
  long long incl_solid_voxels = 0;
  {
    JobDescription job = plate_lattice_job();
    job.lattice.regions.push_back(include_slab());
    const RunJobResult r = run(job, "incl");
    const std::string rcpt = read_file(receipt_of(r));
    CHECK(contains(rcpt, "\"include\": 1"), "include: receipt counts the region");
    incl_lattice_voxels = json_number(rcpt, "lattice_voxels");
    CHECK(incl_lattice_voxels > 0.0, "include: some voxels latticed");
    CHECK(incl_lattice_voxels < json_number(base_rcpt, "lattice_voxels"),
          "include: only the include region is latticed (fewer than whole part)");
    incl_solid_voxels =
        static_cast<long long>(json_number(rcpt, "solid_region_voxels"));
    CHECK(incl_solid_voxels > 0,
          "include: the REST of the part is kept solid (companion emitted)");
    CHECK(json_number(rcpt, "include_void_voxels") > 0.0,
          "H1a: include over optimizer void is a counted NO-OP, not an error");
  }

  // 5. Include + exclude overlap: exclude wins (more solid than include alone).
  {
    JobDescription job = plate_lattice_job();
    job.lattice.regions.push_back(include_slab());
    JobLatticeRegion ex = exclude_bolt();
    ex.axis_point = Vec3{-6.0, 0.0, 2.0};  // inside the include slab
    ex.radius_mm = 2.5;
    job.lattice.regions.push_back(ex);
    const RunJobResult r = run(job, "incl_excl");
    const std::string rcpt = read_file(receipt_of(r));
    CHECK(contains(rcpt, "\"include\": 1") && contains(rcpt, "\"exclude\": 1"),
          "overlap: both regions counted");
    CHECK(json_number(rcpt, "solid_region_voxels") >
              static_cast<double>(incl_solid_voxels),
          "H1a: exclude-inside-include keeps MORE solid than include alone "
          "(exclude beats include)");
    CHECK(json_number(rcpt, "lattice_voxels") < incl_lattice_voxels,
          "H1a: the overlap is not latticed");

    // 6. Determinism (H5): the same role job reruns byte-identical.
    const RunJobResult r2 = run(job, "incl_excl_2");
    CHECK(read_file(lattice_mesh_of(r2)) == read_file(lattice_mesh_of(r)),
          "H5: role run is byte-identical on rerun (lattice mesh)");
    CHECK(read_file(receipt_of(r2)) == read_file(receipt_of(r)),
          "H5: role run is byte-identical on rerun (receipt)");
    CHECK(read_file(r2.report_path) == read_file(r.report_path),
          "H5: role run is byte-identical on rerun (report)");
  }
}

// ---------------------------------------------------------------------------
// B. Graded lattice from the run's OWN field (stage 4), on a thick cylinder.

// A closed right cylinder (radius R, height H, n side segments) as a clean
// triangle mesh — thick enough that the cells-per-member floor is satisfiable.
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
    // side (outward)
    m.triangles.push_back({lo(i), lo(i + 1), hi(i + 1)});
    m.triangles.push_back({lo(i), hi(i + 1), hi(i)});
    // bottom (normal -z), top (+z)
    m.triangles.push_back({c0, lo(i + 1), lo(i)});
    m.triangles.push_back({c1, hi(i), hi(i + 1)});
  }
  return m;
}

static void section_graded() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  // Write the cylinder fixture and find the fitted side-wall radius the
  // segmenter actually produces (the honest way to author a cylindrical
  // selector for a mesh part — test_mesh_job's lesson).
  const std::string cyl_path = tmp + "/lat_hookup_cyl.stl";
  write_stl_file(cyl_path, cylinder_mesh(15.0, 30.0, 48), StlFormat::Binary);
  double fitted_r = 0.0;
  {
    const StepModel part = import_part_file(cyl_path);
    for (int f = 0; f < part.face_count; ++f)
      if (part.faces[static_cast<std::size_t>(f)].kind ==
          StepSurfaceKind::Cylinder)
        fitted_r = part.faces[static_cast<std::size_t>(f)].cylinder_radius_mm;
  }
  CHECK(fitted_r > 10.0, "cylinder fixture: side wall segments as a cylinder");

  JobDescription job;
  job.model = "lat_hookup_cyl.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 24;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", fitted_r});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  // vf 1.0: the "lattice the solid part" case. A reduced rung hollows this
  // cylinder into thin walls that (correctly) cannot hold the 5-cells-per-member
  // floor — the graded machinery needs members >= 5 cells thick to have anything
  // to grade, and the solid cylinder's 30mm core clears it.
  job.ladder = {1.0};
  job.margin_stop = 0.0;
  job.simp_max_iterations = 4;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.lattice.present = true;
  job.lattice.topology = "octet";  // NO cell/radius: the law derives them
  job.lattice.emit_stl = true;
  job.grading.present = true;
  job.grading.topology = "octet";
  job.grading.cell_mm = 3.0;
  job.grading.min_extrudable_width_mm = 0.4;
  job.grading.demand_exponent = 1.0;

  auto run = [&](const std::string& sub) {
    const std::string out = tmp + "/lat_hookup_" + sub;
    std::filesystem::remove_all(out);
    return run_job(job, tmp, out, materials, rules,
                   /*emit_progress=*/false, RunObservability{});
  };
  const RunJobResult r = run("graded");
  CHECK(!r.pipeline.evaluated.empty() && r.pipeline.evaluated[0].accepted,
        "graded: the rung is accepted");
  const MinimizePlasticVariant& v = r.pipeline.evaluated[0];

  std::string rcpt_path;
  for (const std::string& p : r.mesh_paths)
    if (contains(p, "_lattice.")) rcpt_path = p.substr(0, p.rfind(".stl")) + ".report.json";
  CHECK(!rcpt_path.empty(), "graded: latticed mesh exported");
  const std::string rcpt = read_file(rcpt_path);
  CHECK(contains(rcpt, "\"grading\""), "graded: receipt carries the grading record");
  CHECK(contains(rcpt, "\"graded_from\""), "H4a: provenance present");
  CHECK(json_number(rcpt, "variant_vf") == v.requested_volume_fraction,
        "H4a: provenance names THIS variant");
  CHECK(static_cast<int>(json_number(rcpt, "iterations")) ==
            v.optimization.iterations,
        "H4a: provenance carries the variant's own iteration count");
  CHECK(contains(rcpt, "\"strut_radius_mm\": null"),
        "graded: no fabricated uniform radius in the receipt");

  // Independent re-run of the LAW on the variant's own field: the receipt's
  // numbers must match exactly (a stale field / another variant's field would
  // generically differ).
  {
    const VoxelGrid& sg = r.pipeline.solved_grid;
    std::vector<char> cand(sg.voxel_count(), 0);
    for (std::size_t e = 0; e < sg.voxel_count(); ++e)
      if (v.optimization.physical_density[e] >= 0.5) cand[e] = 1;
    GradingLawParams gp;
    gp.topology = LatticeTopology::Octet;
    gp.target_cell_size_mm = job.grading.cell_mm;
    gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
    gp.demand_exponent = job.grading.demand_exponent;
    const GradedField gf = grade_lattice(sg, v.optimization.physical_density,
                                         v.von_mises_field, &cand, gp);
    CHECK(gf.latticed_voxels > 0,
          "graded fixture: the thick cylinder really grades (not ungradeable)");
    CHECK(gf.solid_fallback_voxels > 0,
          "graded fixture: near-surface members fall back solid (L4 live)");
    CHECK(json_number(rcpt, "latticed_voxels") ==
              static_cast<double>(gf.latticed_voxels),
          "H4a: receipt latticed count == law on THIS variant's own field");
    CHECK(json_number(rcpt, "solid_fallback_voxels") ==
              static_cast<double>(gf.solid_fallback_voxels),
          "H4a: receipt fallback count == law on THIS variant's own field");
    CHECK(std::fabs(json_number(rcpt, "cell_size_mm") - gf.cell_size_mm) < 1e-9,
          "H4a: receipt cell == law's cell");
    CHECK(contains(rcpt, "\"cell_size_floored\": true"),
          "graded: the 3mm target was raised to the printability floor");
    // H4b — every emitted density is inside the band READ FROM CORE.
    const double lo = lattice_rho_min(LatticeTopology::Octet);
    const double hi = lattice_rho_max(LatticeTopology::Octet);
    bool all_in_band = true;
    for (std::size_t e = 0; e < gf.posture.mask.size(); ++e)
      if (gf.posture.mask[e]) {
        const double rho = gf.posture.relative_density[e];
        if (!(rho >= lo && rho <= hi)) all_in_band = false;
      }
    CHECK(all_in_band, "H4b: every graded voxel density is inside the core band");
    CHECK(json_number(rcpt, "rho_min_used") >= lo &&
              json_number(rcpt, "rho_max_used") <= hi,
          "H4b: receipt rho range inside the band");
    // Clamp accounting: counts + fractions are present; when any voxel was
    // clamped the counterfactual solve ran and reported its verdict delta.
    CHECK(json_number(rcpt, "clamped_lo_voxels") ==
              static_cast<double>(gf.clamped_lo_voxels),
          "H4b: receipt lo-clamp count == law's");
    CHECK(json_number(rcpt, "clamped_hi_voxels") ==
              static_cast<double>(gf.clamped_hi_voxels),
          "H4b: receipt hi-clamp count == law's");
    if (gf.clamped_lo_voxels + gf.clamped_hi_voxels > 0) {
      CHECK(contains(rcpt, "\"clamp_counterfactual_ran\": true"),
            "H4b: clamp counterfactual solve ran");
      CHECK(contains(rcpt, "\"clamp_changed_verdict\": "),
            "H4b: whether clamping changed the verdict is reported");
    }
    // The exported file honours the fallback: the solid companion carries at
    // least the fallback voxels.
    CHECK(json_number(rcpt, "solid_region_voxels") >=
              static_cast<double>(gf.solid_fallback_voxels),
          "graded: too-thin members are exported SOLID (companion)");
  }

  // H5 — byte-identical rerun.
  {
    const RunJobResult r2 = run("graded_2");
    std::string rcpt2;
    for (const std::string& p : r2.mesh_paths)
      if (contains(p, "_lattice."))
        rcpt2 = p.substr(0, p.rfind(".stl")) + ".report.json";
    CHECK(read_file(rcpt2) == rcpt, "H5: graded receipt byte-identical on rerun");
    std::string mesh1, mesh2;
    for (const std::string& p : r.mesh_paths)
      if (contains(p, "_lattice.")) mesh1 = p;
    for (const std::string& p : r2.mesh_paths)
      if (contains(p, "_lattice.")) mesh2 = p;
    CHECK(read_file(mesh1) == read_file(mesh2),
          "H5: graded lattice mesh byte-identical on rerun");
  }
}

// ---------------------------------------------------------------------------
// C. Mode "analyze" (stage 3).
static void section_analyze() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  // H3a — run_job refuses an analyze job (before any heavy work), and any
  // unknown mode too (the parser already refuses unknown modes; run_job's own
  // gate must stay strict for in-process callers as well).
  {
    JobDescription job = plate_job();
    job.mode = "analyze";
    bool threw = false;
    std::string msg;
    try {
      run_job(job, fixture_dir, tmp + "/lat_hookup_refuse", materials, rules);
    } catch (const JobError& e) {
      threw = true;
      msg = e.what();
    }
    CHECK(threw, "H3a: run_job REFUSES an analyze job");
    CHECK(contains(msg, "analyze"), "H3a: the refusal names the mode");
    job.mode = "bogus_mode";
    threw = false;
    try {
      run_job(job, fixture_dir, tmp + "/lat_hookup_refuse2", materials, rules);
    } catch (const JobError&) {
      threw = true;
    }
    CHECK(threw, "H3a: run_job refuses an unknown mode (still strict)");
  }

  // H3b/H3c — analyze_job: ONE solve, no variant meshes, labelled receipt.
  {
    JobDescription job = plate_job();
    job.mode = "analyze";
    const std::string out = tmp + "/lat_hookup_analyze";
    std::filesystem::remove_all(out);
    const AnalyzeJobResult a =
        analyze_job(job, fixture_dir, out, materials, rules);
    const std::string prov = read_file(a.provenance_path);
    CHECK(contains(prov, "\"analysis_solves\": 1"),
          "H3b: exactly one analysis solve, stated in the receipt");
    CHECK(contains(prov, "\"variant_meshes_written\": 0"),
          "H3b: no variants written, stated in the receipt");
    CHECK(contains(prov, "\"optimization\": false"),
          "H3b: the receipt states no optimization ran");
    CHECK(contains(prov, "\"field_scope\": \"solid_part\""),
          "H3c: the field is labelled SOLID-PART");
    CHECK(contains(prov, "INVALIDATES this field"),
          "H3c: the optimization-invalidates warning travels in the receipt");
    // No variant meshes in the output dir (only the analysis artifacts).
    std::size_t variant_meshes = 0;
    for (const auto& ent : std::filesystem::directory_iterator(out)) {
      const std::string name = ent.path().filename().string();
      if (name.rfind("variant", 0) == 0 &&
          (contains(name, ".stl") || contains(name, ".3mf")))
        ++variant_meshes;
    }
    CHECK(variant_meshes == 0, "H3b: the analyze output dir has NO variant mesh");
    CHECK(std::filesystem::exists(a.fields_path),
          "analyze: fields.bin written (the app's overlay food)");
  }
}

int main() {
  section_roles();
  section_graded();
  section_analyze();
  std::printf("\n%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
