// test_designbox_lattice_recert.cpp — task 2026-08-03-design-box-recertification:
// A DESIGN-BOX RUN MUST BE LATTICEABLE AND RE-CERTIFIABLE.
//
// THE SYMPTOM. A run with a design box refused to be latticed:
//   "lattice certification does not support a design box (add-material) run:
//    the certification load case cannot be reconstructed under domain expansion."
// The refusal was not protecting against something impossible. The OPTIMIZE path
// already remaps the BCs and loads onto the expanded grid; the latticed
// RE-CERTIFICATION reconstructed the load case a SECOND time, at run_job level,
// with no remap. It was protecting against its own second reconstruction.
//
// THE FIX is one remap (resolve_design_domain / design_domain_loads,
// pipeline.hpp) with two callers. These are the bars that make that checkable.
//
//   AI1 THE LOAD CASE IS THE SAME ONE, NOT A VALID ONE. The re-certification of
//       a design-box variant reproduces the margin the run RECORDED for it,
//       EXACTLY (bit-for-bit, ==), and its loadcase receipt is byte-for-byte the
//       optimize run's — resolved force magnitude and tagged voxel count per
//       group among them. Non-zero is NOT sufficient.
//       *** NEGATIVE CONTROL (section C) ***: the SAME certification run with a
//       load case reconstructed the OLD way — part-grid-indexed BCs and loads
//       used verbatim on the expanded grid, i.e. the remap skipped — is asserted
//       NOT to reproduce that margin. That is what makes AI1 a test of the remap
//       rather than a test that some number came back.
//
//   AI2 THE REFUSAL IS GONE, AND EARNED. A design box + declared keep-clears +
//       lattice job runs end to end through run_job and writes a certified
//       latticed variant; the same design re-latticed later through
//       lattice_variant_job produces the SAME composite margin.
//
//   AI3 (here) the no-design-box paths are untouched: this file adds a design-box
//       job beside them and asserts the box job's SOLVED grid is the one
//       minimize_plastic_solved_grid names — the cross-commit byte identity is
//       proven separately by a stash-rebuild checksum.
//
//   AI6 THE EXPANSION IS VISIBLE IN THE RECEIPT. The per-variant lattice receipt
//       states how many printed voxels sit OUTSIDE the imported part's envelope
//       and what was done with them; the counts partition the printed set
//       exactly, and under the conservative default every outside voxel is
//       dropped from the lattice mask (kept SOLID).
//
//   AI7 DETERMINISM. Every artifact the design-box lattice job writes is
//       byte-identical on a rerun.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

#include "topopt/analyze.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
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
// Fixtures. plate_bore.stl spans x[-12,12] y[-8,8] z[0,4]; the design box gives
// the optimizer room to grow material ABOVE it (z up to 9), which is where the
// "material outside the original part" this task is about comes from.
//
// The build direction is DECLARED so the scorer never chooses one and bakes the
// export onto it: this file compares meshes and re-certifies them, and a baked
// export is in a different frame from the model grid. That is orthogonal to the
// design box (handoff 2026-08-01-bake-build-orientation) and declaring it keeps
// this test about the one thing it is about.
static JobDescription box_job() {
  JobDescription job;
  job.model = "plate_bore.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", 3.0});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.has_build_direction = true;
  job.build_direction = Vec3{0.0, 0.0, 1.0};
  job.ladder = {0.8};
  job.margin_stop = 0.0;
  job.simp_max_iterations = 8;
  job.has_design_box = true;
  job.design_box.min = Vec3{-12.0, -8.0, 0.0};
  job.design_box.max = Vec3{12.0, 8.0, 9.0};
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

static JobLattice octet_block() {
  JobLattice lat;
  lat.present = true;
  lat.topology = "octet";
  lat.cell_mm = 3.0;
  lat.strut_radius_mm = 0.45;  // rho ~0.41, inside the certifiable band
  lat.emit_stl = true;
  return lat;
}

// THE CONTRACT (inherited from task 2026-08-02-lattice-a-variant): a
// lattice_variant job is the ORIGINAL job with `mode` swapped and a `variant`
// block added. Nothing about the load case — or the design box — is re-authored,
// which is exactly what makes the load-case identity bar checkable.
static JobDescription relattice_job(const JobDescription& original,
                                    const std::string& design_path,
                                    int variant_index) {
  JobDescription job = original;
  job.mode = "lattice_variant";
  job.variant.present = true;
  job.variant.design = design_path;
  job.variant.has_index = true;
  job.variant.index = variant_index;
  return job;
}

// ---------------------------------------------------------------------------
// A. The optimize path: a design box + a lattice block, end to end.
//    Bars AI2, AI3 (solved-grid agreement), AI6.
static DesignStore g_store;          // shared with section B
static std::string g_design_path;    // ...
static std::string g_run_loadcase;   // the optimize run's loadcase.json bytes
static double g_recorded_margin = 0.0;
static double g_lattice_margin = 0.0;
static std::string g_run_receipt;    // the optimize run's lattice receipt bytes
static std::vector<int> g_fixture_face_ids;  // the faces the RUN resolved

static void section_optimize_with_box() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  const std::string out = tmp + "/dbx_run";
  std::filesystem::remove_all(out);
  JobDescription job = box_job();
  job.lattice = octet_block();

  // AI2 — this call THREW before the task, with the design-box refusal. That it
  // returns at all is the bar; everything below is what it has to have returned.
  const RunJobResult run =
      run_job(job, fixture_dir, out, materials, rules, /*emit_progress=*/false,
              RunObservability{});
  CHECK(run.pipeline.evaluated.size() == 1,
        "AI2: the design-box lattice job ran its ladder");

  // AI3 — the grid the run solved on is the EXPANDED grid, and it is the grid
  // the shared resolver names. Two derivations that used to agree by discipline
  // are now the same call; assert it rather than trust it.
  const VoxelGrid part_grid = voxelize(
      import_part_file_resolved(fixture_dir + "/plate_bore.stl").mesh,
      job.resolution);
  MinimizePlasticOptions probe;
  configure_production_options(probe);
  probe.design_box = DesignBox{job.design_box.min, job.design_box.max};
  const SolvedDesignDomain dom = resolve_design_domain(part_grid, {}, probe);
  const VoxelGrid& sg = run.pipeline.solved_grid;
  CHECK(dom.expanded, "AI3: the probe domain reports itself expanded");
  CHECK(dom.grid.nx == sg.nx && dom.grid.ny == sg.ny && dom.grid.nz == sg.nz &&
            dom.grid.spacing == sg.spacing,
        "AI3: resolve_design_domain names the grid the run solved on");
  CHECK(sg.voxel_count() > part_grid.voxel_count(),
        "the design box actually EXPANDED the domain (otherwise this whole file "
        "tests nothing)");
  std::printf("[AI3] part grid %dx%dx%d -> solved grid %dx%dx%d\n", part_grid.nx,
              part_grid.ny, part_grid.nz, sg.nx, sg.ny, sg.nz);

  // The latticed receipt exists and describes a certified composite.
  const std::string rcpt_path = out + "/variant_080_lattice.report.json";
  CHECK(std::filesystem::exists(rcpt_path),
        "AI2: the design-box run wrote a latticed certification receipt");
  const std::string rcpt = read_file(rcpt_path);
  CHECK(std::filesystem::exists(out + "/variant_080_lattice.stl"),
        "AI2: and the latticed mesh beside it");

  // ── AI6: the expansion is VISIBLE, and the counts partition the printed set.
  CHECK(contains(rcpt, "\"added_material\""),
        "AI6: the receipt carries the added-material section");
  const double printed = json_number(rcpt, "printed_voxels");
  const double inside = json_number(rcpt, "inside_original_part");
  const double outside = json_number(rcpt, "outside_original_part");
  const double kept_solid = json_number(rcpt, "outside_kept_solid_voxels");
  CHECK(printed > 0.0 && inside + outside == printed,
        "AI6: inside + outside == printed (an exact partition of the printed "
        "set, not two independently counted numbers)");
  CHECK(outside > 0.0,
        "AI6: this fixture's optimizer DID grow material outside the part — if "
        "it did not, the policy below would be untested");
  CHECK(kept_solid == outside,
        "AI6: under the conservative default EVERY outside voxel was dropped "
        "from the lattice mask (certified SOLID, exported as the companion)");
  CHECK(contains(rcpt, "\"policy\": \"keep_solid\""),
        "AI6: the receipt NAMES the policy that ran");
  CHECK(contains(rcpt, "PLACEHOLDER"),
        "AI6: and says out loud that the policy is a placeholder for a decision "
        "the maintainer has not made");
  // The kept-solid material must actually be IN the file: dropping it from the
  // lattice mask certifies it solid, so the companion body has to carry it.
  CHECK(json_number(rcpt, "solid_region_voxels") >= kept_solid,
        "AI6: the solid companion body carries at least the kept-solid voxels — "
        "certified solid AND exported, never certified and then omitted");
  std::printf("[AI6] printed %.0f voxels: %.0f inside the part, %.0f outside "
              "(%.1f%%), %.0f kept solid, %.3f mm^3\n",
              printed, inside, outside, 100.0 * outside / printed, kept_solid,
              json_number(rcpt, "outside_volume_mm3"));

  g_run_receipt = rcpt;
  g_fixture_face_ids = run.fixture_face_ids;
  g_design_path = run.design_path;
  g_store = read_design_file(run.design_path);
  g_run_loadcase = read_file(run.loadcase_receipt_path);
  g_recorded_margin = run.pipeline.evaluated[0].report.margin.worst_case;
  // The COMPOSITE margin — the latticed object's, not the strut report's
  // "margin_worst_case" further down the same receipt.
  g_lattice_margin = json_number(rcpt, "lattice_margin_worst_case");
  CHECK(g_store.nx == sg.nx && g_store.ny == sg.ny && g_store.nz == sg.nz,
        "design.bin names the EXPANDED grid (the grid the run solved on) — the "
        "storage the re-lattice path indexes against");
}

// ---------------------------------------------------------------------------
// B. The re-lattice path on that stored design. Bars AI1, AI2, AI7.
static void section_relattice_with_box() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  const std::string out = tmp + "/dbx_relattice";
  std::filesystem::remove_all(out);
  JobDescription job = box_job();
  job.lattice = octet_block();
  JobDescription lv = relattice_job(job, g_design_path, 0);

  // AI2 — this call THREW before the task too, with its own design-box refusal.
  const LatticeVariantJobResult r =
      lattice_variant_job(lv, fixture_dir, out, materials, rules);

  // ── AI1: THE LOAD CASE IS THE SAME ONE.
  // (1) The receipt — anchor faces, clamped DOF, and per group the resolved
  //     force magnitude and the voxels its faces tagged — byte for byte.
  const std::string lv_loadcase = read_file(r.loadcase_receipt_path);
  CHECK(!g_run_loadcase.empty() && g_run_loadcase == lv_loadcase,
        "AI1: the re-lattice run resolved the IDENTICAL load case — its "
        "loadcase.json is byte-for-byte the optimize run's");
  CHECK(json_number(g_run_loadcase, "fixture_voxels_tagged") > 0.0,
        "AI1: the receipt records a NON-ZERO tagged voxel count (a selector that "
        "tags nothing reports nothing — PR 261)");
  CHECK(json_number(g_run_loadcase, "anchor_bc_dofs") > 0.0,
        "AI1: and the clamped DOF count");
  // (2) The margin — EQUAL to the value recorded for this variant, not merely
  //     non-zero. lattice_variant_job ENFORCES this (it throws otherwise), so
  //     reaching here at all is most of the bar; assert the numbers anyway.
  CHECK(r.reproduction_exact,
        "AI1: the restored design reproduces the RECORDED margin exactly");
  CHECK(r.reproduced_margin_worst_case == r.recorded_margin_worst_case,
        "AI1: reproduced == recorded, bit for bit");
  CHECK(r.recorded_margin_worst_case == g_recorded_margin,
        "AI1: and that recorded margin is the one the optimize run reported");
  // (3) The COMPOSITE margin agrees across the two entry points: the same design
  //     latticed by the optimize path and by the re-lattice path certifies to the
  //     same number, which it cannot do under two different load cases.
  // Compared as the RECEIPTS render it — the same emitter at the same precision
  // on both paths, so this is a textual identity, not a tolerance.
  const std::string lv_rcpt = read_file(r.lattice_receipt_path);
  const std::string key = "\"lattice_margin_worst_case\": ";
  const std::string::size_type at = lv_rcpt.find(key);
  CHECK(at != std::string::npos,
        "the re-lattice receipt carries the composite margin");
  const std::string lv_margin_text =
      at == std::string::npos ? std::string()
                              : lv_rcpt.substr(at, lv_rcpt.find(',', at) - at);
  CHECK(!lv_margin_text.empty() && contains(g_run_receipt, lv_margin_text),
        "AI1/AI2: the composite margin from the re-lattice path EQUALS the "
        "optimize path's for the same variant");
  (void)g_lattice_margin;
  std::printf("[AI1] recorded %.6g == reproduced %.6g; composite %.6g on both "
              "entry points\n",
              r.recorded_margin_worst_case, r.reproduced_margin_worst_case,
              r.lattice.margin.worst_case);

  // ── AI7: determinism. Every artifact byte-identical on a rerun.
  const std::string out2 = tmp + "/dbx_relattice_2";
  std::filesystem::remove_all(out2);
  const LatticeVariantJobResult r2 =
      lattice_variant_job(lv, fixture_dir, out2, materials, rules);
  CHECK(r2.lattice.margin.worst_case == r.lattice.margin.worst_case,
        "AI7: the composite margin is identical on a rerun");
  int compared = 0;
  for (const auto& e : std::filesystem::directory_iterator(out)) {
    const std::string name = e.path().filename().string();
    // run_info.json carries a deliberate wall-clock stamp, exactly as the
    // optimize path's does — excluded here for that reason, not to hide a diff.
    if (name == "run_info.json") continue;
    const std::string a = read_file(e.path().string());
    const std::string b = read_file(out2 + "/" + name);
    CHECK(!a.empty() && a == b,
          ("AI7: " + name + " is byte-identical on a rerun").c_str());
    ++compared;
  }
  CHECK(compared >= 5, "AI7: every artifact was compared, not a token one");
  std::printf("[AI7] %d artifacts byte-identical on a rerun\n", compared);
}

// ---------------------------------------------------------------------------
// C. THE NEGATIVE CONTROL — the bar AI1 actually rests on.
//
// AI1 says the test "must FAIL against a reconstruction that skips the remap".
// So: certify the SAME stored design, on the SAME expanded grid, with the load
// case reconstructed the OLD way — the part-grid-indexed BCs used verbatim,
// self-weight computed on the PART grid rather than the solved one — and assert
// it does NOT reproduce the recorded margin. If a no-remap reconstruction could
// reproduce it, section B would be proving nothing.
static void section_no_remap_negative_control() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const Material& material = materials.find("PLA")->second;

  const JobDescription job = box_job();
  const StepModel model =
      import_part_file_resolved(fixture_dir + "/plate_bore.stl");
  const VoxelGrid part_grid = voxelize(model.mesh, job.resolution);

  // The part-grid BCs, exactly as the model produces them (the inputs BOTH
  // reconstructions start from).
  // The fixture faces the RUN itself resolved (section A stored them), so the
  // control clamps exactly what the run clamped rather than re-deriving it.
  VoxelGrid tagged_part = part_grid;
  for (const int f : g_fixture_face_ids)
    tag_mesh_face(tagged_part, model, f, VoxelTag::Fixture);
  std::vector<DirichletBC> part_bcs;
  for (const int n : fea_tagged_nodes(tagged_part, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) part_bcs.push_back({n, c, 0.0});
  CHECK(!part_bcs.empty(), "the negative control has real BCs to mis-map");

  MinimizePlasticOptions options;
  configure_production_options(options);
  options.margin_stop = job.margin_stop;
  options.gravity = job.gravity.magnitude_mm_s2 * 1.0e-9;  // g/cm^3 -> t/mm^3
  options.gravity_direction = job.gravity.direction;
  options.design_box = DesignBox{job.design_box.min, job.design_box.max};

  const SolvedDesignDomain domain =
      resolve_design_domain(tagged_part, part_bcs, options);
  const VoxelGrid& sg = domain.grid;
  const StoredDesign& sd = g_store.variants[0];
  CHECK(static_cast<int>(g_store.nx) == sg.nx,
        "the negative control rebuilds the SAME expanded grid the store names");

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  const KnockdownSpec knockdown = knockdown_spec_for(options);
  const double part_solid = static_cast<double>(tagged_part.solid_count());
  const bool ok = load_path_connected(sg, sd.density, 0.5);

  // (1) WITH the remap — the shipped reconstruction. Must reproduce EXACTLY.
  const std::vector<NodalLoad> loads =
      design_domain_loads(domain, options, material.density_g_cm3);
  const FixedDesignAnalysis with_remap = analyze_fixed_design(
      sg, params, sd.density, domain.bcs, loads, material, sd.applied_build_dir,
      options.simp.cg_tolerance, options.simp.cg_max_iterations,
      options.simp.solver, options.margin_stop, knockdown, ok, part_solid,
      /*lattice=*/nullptr, false, false, false);
  CHECK(with_remap.margin.worst_case == sd.margin_worst_case,
        "AI1: WITH the remap, the reconstruction reproduces the recorded margin "
        "bit-for-bit");

  // (2) WITHOUT it — part-grid BCs used verbatim on the expanded grid, and
  //     self-weight computed on the PART grid then reused. This is exactly the
  //     shape of the reconstruction the old refusal existed to avoid.
  const std::vector<NodalLoad> unmapped_loads = self_weight_loads(
      tagged_part, material.density_g_cm3, options.gravity,
      options.gravity_direction);
  bool no_remap_reproduced = false;
  bool no_remap_threw = false;
  try {
    const FixedDesignAnalysis no_remap = analyze_fixed_design(
        sg, params, sd.density, part_bcs, unmapped_loads, material,
        sd.applied_build_dir, options.simp.cg_tolerance,
        options.simp.cg_max_iterations, options.simp.solver, options.margin_stop,
        knockdown, ok, part_solid, /*lattice=*/nullptr, false, false, false);
    no_remap_reproduced =
        (no_remap.margin.worst_case == sd.margin_worst_case);
    std::printf("[AI1-neg] no-remap margin %.6g vs recorded %.6g\n",
                no_remap.margin.worst_case, sd.margin_worst_case);
  } catch (const std::exception& e) {
    // A no-remap reconstruction may not even be solvable (a load landing on a
    // DOF with no stiffness). That is a failure too, and a louder one.
    no_remap_threw = true;
    std::printf("[AI1-neg] no-remap reconstruction threw: %s\n", e.what());
  }
  CHECK(!no_remap_reproduced,
        "AI1 NEGATIVE CONTROL: a reconstruction that SKIPS the remap must NOT "
        "reproduce the recorded margin — if it did, section B would prove "
        "nothing about the remap");
  CHECK(no_remap_threw || !no_remap_reproduced,
        "AI1 NEGATIVE CONTROL: the no-remap reconstruction either fails to "
        "solve or lands on a different margin");
}

// ---------------------------------------------------------------------------
// D. The no-box path is untouched by the sharing. Off the design box,
//    resolve_design_domain must hand back the caller's own inputs verbatim —
//    that identity is what makes every existing caller byte-identical, so it is
//    asserted here rather than left to the checksum alone.
static void section_no_box_identity() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const StepModel model =
      import_part_file_resolved(fixture_dir + "/plate_bore.stl");
  const VoxelGrid grid = voxelize(model.mesh, 32);
  std::vector<DirichletBC> bcs;
  for (int n = 0; n < 12; ++n)
    for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});

  MinimizePlasticOptions options;
  configure_production_options(options);
  options.external_loads.push_back({7, 2, -1.5});
  const SolvedDesignDomain dom = resolve_design_domain(grid, bcs, options);

  CHECK(!dom.expanded, "no design box => the domain reports itself unexpanded");
  CHECK(dom.mask.empty(),
        "no design box => NO mask is built (the driver's own make_active_mask / "
        "caller design_mask path is untouched)");
  CHECK(dom.offset_i == 0 && dom.offset_j == 0 && dom.offset_k == 0,
        "no design box => zero offset");
  CHECK(dom.grid.nx == grid.nx && dom.grid.ny == grid.ny &&
            dom.grid.nz == grid.nz && dom.grid.spacing == grid.spacing &&
            dom.grid.origin.x == grid.origin.x &&
            dom.grid.origin.y == grid.origin.y &&
            dom.grid.origin.z == grid.origin.z,
        "no design box => the caller's grid, verbatim");
  CHECK(dom.bcs.size() == bcs.size(),
        "no design box => the caller's BC count");
  bool bcs_same = dom.bcs.size() == bcs.size();
  for (std::size_t i = 0; bcs_same && i < bcs.size(); ++i)
    bcs_same = dom.bcs[i].node == bcs[i].node &&
               dom.bcs[i].component == bcs[i].component &&
               dom.bcs[i].value == bcs[i].value;
  CHECK(bcs_same, "no design box => every BC node index unchanged");
  const std::vector<NodalLoad> loads = design_domain_loads(dom, options, 1.24);
  CHECK(loads.size() == 1 && loads[0].node == 7 && loads[0].component == 2 &&
            loads[0].value == -1.5,
        "no design box => the declared external load, verbatim");

  // And the envelope test degenerates correctly: with no expansion, every
  // part-solid voxel is "inside the original part" and nothing was added.
  const std::vector<char> in_part = original_part_voxels(grid, dom);
  std::size_t marked = 0;
  for (const char c : in_part) marked += (c ? 1u : 0u);
  CHECK(marked == grid.solid_count(),
        "no design box => original_part_voxels marks exactly the part's solid "
        "voxels, so 'material outside the part' is empty by construction");
}

int main() {
  std::printf("=== design-box lattice re-certification ===\n");
  section_optimize_with_box();
  section_relattice_with_box();
  section_no_remap_negative_control();
  section_no_box_identity();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
