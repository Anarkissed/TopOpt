// test_loadcase_analyze — the correctness bar for analyzing a FIXED design under a
// DECLARED external load case (handoff 2026-07-28-loadcase-analyze).
//
// PR 200 disclosed that the analyze path was SELF-WEIGHT ONLY. Under self-weight a
// lighter part is always safer, so no geometry change can move a verdict DOWN —
// which blocks bar S3 of the smoothing work (proving re-certification can LOWER a
// margin). This test locks the extension: the analyze path now accepts a "loads"
// block and certifies the design under that EXTERNAL load, through the SAME
// production_loadcase_from_job → build_production_loadcase seam the optimizer uses.
//
// The bars (from the task):
//   L1. Self-weight analyze is byte-identical — re-proved: a self-weight rung's OWN
//       certification numbers reproduce bit-for-bit through analyze_fixed_design.
//   L2. Reproduce a rung's OWN numbers UNDER A LOADCASE: run a loadcase
//       optimization, analyze that variant's converged density, and assert every
//       certification number with '==' (NOT within a tolerance).
//   L3. THE GATE CAN REJECT: a margin_stop above the analyzed margin comes back
//       REJECTED, and raising the threshold changes ONLY the verdict, not the
//       physics.
//   L4. Deterministic re-run — the analysis is a pure, stateless function.
//   L5. A declared load referencing a face that does not exist, or whose groups tag
//       no voxel / are zero-force, FAILS LOUDLY and NEVER silently falls back to
//       self-weight (the PR-178 param-drop bug). Proved both at the builder level
//       (the precondition) and end-to-end through analyze_job (the loud refusal).
//
// Two levels of evidence, in one test:
//   * L1-L4 + the L5 builder precondition run on a SYNTHETIC in-code StepModel (a
//     solid beam) so the reproduction is fully controlled — no OCCT, no disk. This
//     is the analyze_fixed_design + build_production_loadcase + minimize_plastic
//     seam, exactly the code analyze_job's loadcase branch calls.
//   * The analyze_job integration (the loud L5 refusals, a loadcase smoke, and the
//     self-weight regression) runs on the committed demo l-bracket.step via an
//     in-code JobDescription, so it drives the REAL front-door end to end.
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness the
// other core tests use, public API only.

#include "topopt/analyze.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::analyze_fixed_design;
using topopt::analyze_job;
using topopt::AnalyzeJobResult;
using topopt::build_production_loadcase;
using topopt::DirichletBC;
using topopt::FixedDesignAnalysis;
using topopt::JobDescription;
using topopt::JobError;
using topopt::JobLoadGroup;
using topopt::KnockdownSpec;
using topopt::knockdown_spec_for;
using topopt::load_path_connected;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::NodalLoad;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::self_weight_loads;
using topopt::SettingsRules;
using topopt::SimpParams;
using topopt::StepModel;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

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

namespace {

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

Vec3 normalized(const Vec3& v) {
  const double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return Vec3{v.x / n, v.y / n, v.z / n};
}

void add_tri(StepModel& m, int fid, Vec3 a, Vec3 b, Vec3 c) {
  const int base = static_cast<int>(m.mesh.vertices.size());
  m.mesh.vertices.push_back(a);
  m.mesh.vertices.push_back(b);
  m.mesh.vertices.push_back(c);
  m.mesh.triangles.push_back({base, base + 1, base + 2});
  m.triangle_face.push_back(fid);
}

void add_quad(StepModel& m, int fid, Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
  add_tri(m, fid, a, b, c);
  add_tri(m, fid, a, c, d);
}

// A solid axis-aligned box L(x)×W(y)×H(z) as a synthetic StepModel. Six planar
// faces, outward winding: 0=-X (anchor), 1=+X (load), 2=-Y, 3=+Y, 4=-Z, 5=+Z.
StepModel make_box(double L, double W, double H) {
  StepModel m;
  const Vec3 v0{0, 0, 0}, v1{L, 0, 0}, v2{L, W, 0}, v3{0, W, 0};
  const Vec3 v4{0, 0, H}, v5{L, 0, H}, v6{L, W, H}, v7{0, W, H};
  add_quad(m, 0, v0, v4, v7, v3);   // -X (anchor)
  add_quad(m, 1, v1, v2, v6, v5);   // +X (load)
  add_quad(m, 2, v0, v1, v5, v4);   // -Y
  add_quad(m, 3, v3, v7, v6, v2);   // +Y
  add_quad(m, 4, v0, v3, v2, v1);   // -Z
  add_quad(m, 5, v4, v5, v6, v7);   // +Z
  m.face_count = 6;
  m.faces.resize(6);
  m.solid_count = 1;
  return m;
}

// Count DOFs at which two fields differ AT ALL. The only acceptable answer for
// "the same solve, re-run" is zero.
std::size_t differing(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return a.size() + b.size() + 1;
  std::size_t n = 0;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i] != b[i]) ++n;
  return n;
}

// Reproduce a converged variant's certification through analyze_fixed_design, given
// the EXACT inputs the run's per-rung recovery block used (G, B, loads, params,
// solver, tolerance, knockdown). Returns the reproduced analysis; the caller
// asserts every field == the variant's own numbers. This mirrors the shared
// single-source-of-truth (analyze_fixed_design) that both the optimizer's
// certification and analyze_job's loadcase branch call.
FixedDesignAnalysis reproduce(const VoxelGrid& grid, const Material& material,
                              const std::vector<DirichletBC>& bcs,
                              const std::vector<NodalLoad>& loads,
                              const MinimizePlasticOptions& options,
                              const std::vector<double>& density,
                              double margin_stop) {
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ARCHITECTURE §4
  const Vec3 build_dir = normalized(Vec3{-options.gravity_direction.x,
                                         -options.gravity_direction.y,
                                         -options.gravity_direction.z});
  const KnockdownSpec knockdown = knockdown_spec_for(options);
  const bool load_path_ok = load_path_connected(grid, density, 0.5);
  const double part_solid = static_cast<double>(grid.solid_count());
  return analyze_fixed_design(grid, params, density, bcs, loads, material,
                              build_dir, options.simp.cg_tolerance,
                              options.simp.cg_max_iterations, options.simp.solver,
                              margin_stop, knockdown, load_path_ok, part_solid);
}

// Assert every certification number of `a` matches the run variant `v` BIT-for-BIT
// (== not tolerance). `label` names the case in a failure line.
void assert_reproduces(const FixedDesignAnalysis& a,
                       const MinimizePlasticVariant& v, const char* label) {
  std::fprintf(stderr, "  [%s] reproduction check\n", label);
  CHECK(differing(a.von_mises_field, v.von_mises_field) == 0,
        "von Mises field bit-identical to the run");
  CHECK(differing(a.stress_tensor_field, v.stress_tensor_field) == 0,
        "Cauchy stress tensor field bit-identical to the run");
  CHECK(differing(a.displacement_field, v.displacement_field) == 0,
        "displacement field bit-identical to the run");
  CHECK(a.mass_grams == v.mass_grams, "printed mass bit-identical to the run");
  CHECK(a.support_volume_voxels == v.support_volume_voxels,
        "support volume bit-identical to the run");
  CHECK(a.max_von_mises == v.report.max_stress_mpa,
        "peak von Mises bit-identical to the run");
  CHECK(a.max_interlayer_tension == v.report.max_interlayer_tension_mpa,
        "peak interlayer tension bit-identical to the run");
  CHECK(a.margin.in_plane == v.report.margin.in_plane,
        "in-plane margin bit-identical to the run");
  CHECK(a.margin.interlayer == v.report.margin.interlayer,
        "interlayer margin bit-identical to the run");
  CHECK(a.margin.worst_case == v.report.margin.worst_case,
        "worst-case margin bit-identical to the run");
  CHECK(a.margin_effective == v.report.margin_effective,
        "infill-adjusted margin bit-identical to the run");
  CHECK(a.v3.min_feature_violations == v.report.min_feature_violations,
        "min-feature violation count bit-identical to the run");
  CHECK(a.printed_fraction == v.report.printed_fraction,
        "printed fraction bit-identical to the run");
  CHECK(a.accepted == v.accepted, "acceptance verdict identical to the run");
}

// --- L2/L3/L4: analyze a loadcase rung's OWN converged density ----------------
void test_loadcase_reproduction(const Material& material,
                                const SettingsRules& rules) {
  // A clamped-root, tip-loaded cantilever beam, driven through the PRODUCTION
  // loadcase seam (build_production_loadcase → minimize_plastic). The external
  // load makes the margin a finite, meaningful number that the re-certification
  // can bite on (unlike a self-weight demo's astronomically over-provisioned one).
  const StepModel model = make_box(24.0, 8.0, 8.0);
  const int resolution = 12;  // spacing 2 mm -> a 12×4×4 grid

  ProductionLoadCase lc;
  lc.anchor_face_ids = {0};                   // -X clamped
  ProductionLoadCase::LoadGroup g;
  g.face_ids = {1};                            // +X tip
  g.force = Vec3{0.0, 0.0, -1500.0};           // downward tip load (N)
  lc.load_groups.push_back(g);
  lc.minimize_plastic = false;                 // ONE conservative {0.9} rung, no pad

  ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
  CHECK(!setup.options.external_loads.empty(),
        "the tip load produced a non-empty external traction set");
  CHECK(setup.options.require_external_loads,
        "a declared load group arms require_external_loads");

  const MinimizePlasticResult result = topopt::minimize_plastic(
      setup.grid, material, "PLA_test", setup.bcs, rules, setup.options);
  CHECK(!result.evaluated.empty(), "the loadcase produced a variant");
  if (result.evaluated.empty()) return;
  const MinimizePlasticVariant& v = result.evaluated[0];
  CHECK(!v.infeasible, "the loadcase rung is feasible (was analysed)");
  CHECK(!v.non_convergent, "the loadcase rung certified (converged)");
  CHECK(!v.von_mises_field.empty(), "the run produced a stress field to match");
  if (v.von_mises_field.empty()) return;

  // L2 — reproduce the rung's OWN numbers under the loadcase, bit-for-bit. The
  // loads are the EXTERNAL tractions (no design box → no remap), exactly what the
  // per-rung certification used.
  const FixedDesignAnalysis a =
      reproduce(setup.grid, material, setup.bcs, setup.options.external_loads,
                setup.options, v.optimization.physical_density,
                setup.options.margin_stop);
  assert_reproduces(a, v, "L2 loadcase");

  // The peak von Mises is a real, positive stress (the cantilever is loaded), so
  // the equalities above bind on MEANINGFUL numbers, not a trivial zero.
  CHECK(a.max_von_mises > 0.0,
        "the loaded cantilever carries real stress (the bar is non-trivial)");

  // L4 — deterministic re-run: the analysis is a pure, stateless function.
  const FixedDesignAnalysis a2 =
      reproduce(setup.grid, material, setup.bcs, setup.options.external_loads,
                setup.options, v.optimization.physical_density,
                setup.options.margin_stop);
  CHECK(differing(a2.von_mises_field, a.von_mises_field) == 0,
        "L4: loadcase analysis is deterministic (re-run bit-identical field)");
  CHECK(a2.mass_grams == a.mass_grams &&
            a2.margin.worst_case == a.margin.worst_case,
        "L4: loadcase analysis re-run mass and margin bit-identical");

  // L3 — THE GATE CAN REJECT under a declared load. Independent of the default
  // threshold: a margin_stop BELOW the measured (infill-adjusted) margin ACCEPTS,
  // one just ABOVE it REJECTS, and raising it changes ONLY the verdict — the
  // physics (the stress field, the reported margin) is untouched. This is the fact
  // S3 needs: under a declared load a threshold can put the verdict BELOW the line
  // (under self-weight it never can, because a lighter part is always safer).
  CHECK(a.margin_effective > 0.0 && std::isfinite(a.margin_effective),
        "L3 precondition: the loaded design has a finite, positive margin to gate on");
  const FixedDesignAnalysis acc =
      reproduce(setup.grid, material, setup.bcs, setup.options.external_loads,
                setup.options, v.optimization.physical_density,
                a.margin_effective * 0.5);
  CHECK(acc.accepted,
        "L3: the gate ACCEPTS when margin_stop is below the measured margin");
  const FixedDesignAnalysis rej =
      reproduce(setup.grid, material, setup.bcs, setup.options.external_loads,
                setup.options, v.optimization.physical_density,
                a.margin_effective * 1.0001);
  CHECK(!rej.accepted,
        "L3: the gate REJECTS when margin_stop exceeds the measured loadcase margin");
  CHECK(differing(rej.von_mises_field, a.von_mises_field) == 0,
        "L3: raising margin_stop changes only the verdict, not the physics");
  CHECK(rej.margin.worst_case == a.margin.worst_case,
        "L3: the REPORTED margin is unchanged (only the gate comparison moved)");
}

// --- L1: self-weight analyze is byte-identical (re-prove) ---------------------
void test_selfweight_reproduction(const Material& material,
                                  const SettingsRules& rules) {
  // A self-weight run reproduced through the SAME analyze_fixed_design. This is the
  // path PR 196 established and production depends on; re-prove it survives the
  // loadcase extension bit-for-bit.
  const StepModel model = make_box(24.0, 8.0, 8.0);
  const int resolution = 12;
  const VoxelGrid grid = topopt::voxelize(model.mesh, resolution);

  // Clamp the -X boundary nodes (a well-posed self-weight cantilever).
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= grid.nz; ++c)
    for (int b = 0; b <= grid.ny; ++b) {
      const int n = topopt::fea_node_index(grid, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }

  MinimizePlasticOptions o;
  topopt::configure_production_options(o);
  o.volume_fraction_ladder = {0.9};
  o.margin_stop = 0.0;  // accept whatever converges (the verdict is L3's job)
  o.gravity = 9810.0 * 1e-9;  // magnitude(mm/s^2) · (g/cm^3 → t/mm^3), as production
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};

  const MinimizePlasticResult result =
      topopt::minimize_plastic(grid, material, "PLA_test", bcs, rules, o);
  CHECK(!result.evaluated.empty(), "the self-weight run produced a variant");
  if (result.evaluated.empty()) return;
  const MinimizePlasticVariant& v = result.evaluated[0];
  CHECK(!v.infeasible && !v.non_convergent,
        "the self-weight rung is feasible and certified");
  if (v.von_mises_field.empty()) return;

  // The certification uses self_weight_loads on the solved grid (uniform envelope
  // self-weight, computed once) — the SAME loads analyze_job's self-weight branch
  // builds on `design_grid`.
  const std::vector<NodalLoad> sw = self_weight_loads(
      grid, material.density_g_cm3, o.gravity, o.gravity_direction);
  const FixedDesignAnalysis a = reproduce(
      grid, material, bcs, sw, o, v.optimization.physical_density, o.margin_stop);
  assert_reproduces(a, v, "L1 self-weight");
}

// --- L5 builder precondition: empty external + out-of-range face --------------
void test_loadcase_guard_preconditions() {
  const StepModel model = make_box(24.0, 8.0, 8.0);
  const int resolution = 12;

  // A zero-force group tags no traction → external_loads empty AND
  // require_external_loads set: the exact state analyze_job's guard refuses on
  // (rather than silently running self-weight).
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {0};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{0.0, 0.0, 0.0};  // zero force
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;
    ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
    CHECK(setup.options.external_loads.empty(),
          "L5 precondition: a zero-force group yields an EMPTY external set");
    CHECK(setup.options.require_external_loads,
          "L5 precondition: require_external_loads is armed (the guard fires here)");
  }

  // An out-of-range load face id throws from the builder (tag_step_face) — the
  // 'face does not exist' failure analyze_job surfaces as a loud JobError.
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {0};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {9999};  // no such face
    g.force = Vec3{0.0, 0.0, -100.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;
    bool threw = false;
    try {
      ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
      (void)setup;
    } catch (const std::exception&) {
      threw = true;
    }
    CHECK(threw,
          "L5 precondition: an out-of-range load face id throws from the builder");
  }
}

// --- analyze_job integration on the demo l-bracket.step (OCCT front door) ------
#if defined(DEMO_FIXTURE_DIR) && defined(MATERIALS_JSON_PATH) && \
    defined(SETTINGS_RULES_PATH)

// Build a JobDescription for the l-bracket with a declared load case: anchors on
// the two Ø5 mounting bores (cylindrical selector, radius 2.5), one load group on
// a real load face, and a force. `load_face_ids` selects the load geometrically or
// by raw id per the caller; `force` is the group force.
JobDescription lbracket_loadcase_job(const std::vector<int>& load_face_ids,
                                     Vec3 force) {
  JobDescription job;
  job.model = "l-bracket.step";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 24;
  job.output.report = "analysis_report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.loads.present = true;
  job.loads.anchors = {topopt::JobFaceSelector{"cylindrical", 2.5}};
  JobLoadGroup g;
  g.face_ids = load_face_ids;
  g.force = force;
  job.loads.groups.push_back(g);
  job.loads.minimize_plastic = false;  // a single conservative variant (fast)
  return job;
}

// A real planar load face that actually TAGS voxels at `resolution` (so its
// traction reaches the solver) and is NOT one of the cylindrical anchor bores.
// Chosen the way the builder would see it — voxelize, tag each candidate on a
// fresh grid, pick the planar face tagging the most Load voxels.
int best_load_face(const StepModel& model, int resolution) {
  const VoxelGrid grid = topopt::voxelize(model.mesh, resolution);
  int best = -1;
  std::size_t best_n = 0;
  for (int f = 0; f < model.face_count; ++f) {
    if (model.faces[static_cast<std::size_t>(f)].kind !=
        topopt::StepSurfaceKind::Plane)
      continue;
    VoxelGrid gg = grid;
    const std::size_t tagged =
        topopt::tag_step_face(gg, model, f, VoxelTag::Load);
    if (tagged > best_n) {
      best_n = tagged;
      best = f;
    }
  }
  return best;
}

void test_analyze_job_integration() {
  const std::string dir = DEMO_FIXTURE_DIR;
  topopt::MaterialLibrary materials;
  SettingsRules rules;
  try {
    materials = topopt::load_materials_file(MATERIALS_JSON_PATH);
    rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load materials/rules: %s\n", e.what());
    ++g_failures;
    return;
  }
  const std::string out = std::string(CLI_TMP_DIR) + "/loadcase_analyze_out";

  // Discover a real planar load face on the actual model (raw ids are stable
  // within a single import; analyze_job re-imports the SAME file).
  StepModel model;
  try {
    model = topopt::import_part_file_resolved(dir + "/l-bracket.step");
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not import l-bracket.step: %s\n", e.what());
    ++g_failures;
    return;
  }
  const int load_face = best_load_face(model, 24);
  CHECK(load_face >= 0, "found a planar load face on the l-bracket that tags voxels");
  if (load_face < 0) return;

  // (integration) A declared load case runs analyze_job end to end under the
  // EXTERNAL load — NOT self-weight — and writes the receipt.
  {
    const JobDescription job =
        lbracket_loadcase_job({load_face}, Vec3{0.0, 0.0, -800.0});
    bool ok = true;
    AnalyzeJobResult r;
    try {
      r = analyze_job(job, dir, out, materials, rules);
    } catch (const std::exception& e) {
      ok = false;
      std::fprintf(stderr, "  analyze_job(loadcase) threw: %s\n", e.what());
    }
    CHECK(ok, "analyze_job runs a declared load case end to end");
    if (ok) {
      CHECK(r.report_json.find("\"material\"") != std::string::npos,
            "loadcase analyze wrote a report");
      // The provenance discloses the load source — proof it did NOT fall back to
      // self-weight.
      std::string prov;
      {
        std::ifstream in(r.provenance_path, std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        prov = ss.str();
      }
      CHECK(prov.find("\"load_source\": \"loadcase\"") != std::string::npos,
            "provenance records load_source: loadcase (not self-weight)");
      CHECK(r.margin_required == 1.5,
            "loadcase uses the production margin_stop default (1.5)");
    }
  }

  // (L5-a) A load group referencing a face that does not exist FAILS LOUDLY — a
  // JobError naming the out-of-range id — and never analyzes under self-weight.
  {
    const JobDescription job =
        lbracket_loadcase_job({999999}, Vec3{0.0, 0.0, -800.0});
    bool threw = false;
    std::string what;
    try {
      analyze_job(job, dir, out, materials, rules);
    } catch (const JobError& e) {
      threw = true;
      what = e.what();
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw, "L5: a nonexistent load face makes analyze_job THROW");
    CHECK(what.find("out of range") != std::string::npos,
          "L5: the diagnostic names the out-of-range face");
    // Task analyze-loadcase-resolution (N5): out-of-range must be LEGIBLE, not
    // just loud — the id, the count available, and the mesh it was resolved
    // against are all in the message (the maintainer's device surfaced the raw
    // "tag_step_face: face_id out of range", which names none of them).
    CHECK(what.find("999999") != std::string::npos,
          "N5: the diagnostic names the offending id (999999)");
    CHECK(what.find(std::to_string(model.face_count) + " faces") !=
              std::string::npos,
          "N5: the diagnostic names the face count available on the model");
    CHECK(what.find("l-bracket.step") != std::string::npos,
          "N5: the diagnostic names the mesh the id was resolved against");
  }

  // (L5-b) A zero-force load group produces NO external load; analyze_job REFUSES
  // rather than silently analyzing under self-weight (the PR-178 bug).
  {
    const JobDescription job =
        lbracket_loadcase_job({load_face}, Vec3{0.0, 0.0, 0.0});
    bool threw = false;
    std::string what;
    try {
      analyze_job(job, dir, out, materials, rules);
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw, "L5: an empty external load makes analyze_job THROW");
    CHECK(what.find("SELF-WEIGHT") != std::string::npos ||
              what.find("self-weight") != std::string::npos,
          "L5: the diagnostic explicitly refuses the self-weight fallback");
    // Task analyze-loadcase-resolution (N4): the refusal must say WHICH group
    // resolved to nothing and WHY — "every group zero-force or tagged no
    // voxels" tells the user nothing they can act on.
    CHECK(what.find("group 0") != std::string::npos,
          "N4: the refusal names the group that resolved to nothing");
    CHECK(what.find("zero force") != std::string::npos,
          "N4: the refusal says WHY (this group's force is zero)");
  }

  // (N3) A REJECTED loadcase analyze still SERVES its field. The analyze
  // pseudo-variant mirrors the margin verdict, and the fields writer's
  // accepted-only default therefore wrote an EMPTY fields.bin whenever the
  // verdict was REJECTED — the field was computed, then dropped, and the app's
  // Auto density overlay went flat exactly when the part was overstressed. A
  // deliberately crushing force guarantees rejection; the container must still
  // carry ONE variant with a non-zero von Mises field.
  {
    const JobDescription job =
        lbracket_loadcase_job({load_face}, Vec3{0.0, 0.0, -80000.0});
    AnalyzeJobResult r;
    bool ok = true;
    try {
      r = analyze_job(job, dir, out, materials, rules);
    } catch (const std::exception& e) {
      ok = false;
      std::fprintf(stderr, "  analyze_job(crushing load) threw: %s\n", e.what());
    }
    CHECK(ok, "N3: a crushing load analyzes (rejection is a verdict, not an error)");
    if (ok) {
      CHECK(!r.analysis.accepted,
            "N3: the crushing load is REJECTED by the margin gate");
      std::ifstream in(r.fields_path, std::ios::binary);
      std::vector<char> bytes((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
      bool fields_ok = bytes.size() > 64;
      std::int32_t variant_count = 0;
      if (fields_ok) {
        std::memcpy(&variant_count, bytes.data() + 56, sizeof(variant_count));
        fields_ok = variant_count == 1;
      }
      CHECK(fields_ok,
            "N3: the REJECTED analyze's fields.bin still carries its ONE variant");
      if (fields_ok) {
        // First variant block starts at 64: 16 (vf+mass) + 8 (support+pad) +
        // 24 (three i64 counts) then the f32 von Mises array.
        std::int64_t vm_count = 0;
        std::memcpy(&vm_count, bytes.data() + 64 + 24, sizeof(vm_count));
        CHECK(vm_count > 0, "N3: the served variant carries a von Mises field");
        float vm_max = 0.0f;
        const char* vm0 = bytes.data() + 64 + 48;
        for (std::int64_t i = 0; i < vm_count; ++i) {
          float x;
          std::memcpy(&x, vm0 + 4 * i, sizeof(x));
          if (x > vm_max) vm_max = x;
        }
        CHECK(vm_max > 0.0f, "N3: the served von Mises field is non-zero");
      }
    }
  }

  // (L1 regression) A self-weight analyze_job (no loads block) still runs after the
  // refactor — the byte-identical path is intact end to end.
  {
    JobDescription job;
    job.model = "l-bracket.step";
    job.material = "PLA";
    job.mode = "minimize_plastic";
    job.resolution = 24;
    job.fixture_faces = {topopt::JobFaceSelector{"cylindrical", 2.5}};
    job.gravity.direction = Vec3{0.0, 0.0, -1.0};
    job.gravity.magnitude_mm_s2 = 9810.0;
    job.ladder = {0.9};
    job.margin_stop = 1.5;
    job.output.report = "analysis_report.json";
    job.output.mesh_format = "stl";
    job.output.mesh_prefix = "variant";
    bool ok = true;
    AnalyzeJobResult r;
    try {
      r = analyze_job(job, dir, out, materials, rules);
    } catch (const std::exception& e) {
      ok = false;
      std::fprintf(stderr, "  analyze_job(self-weight) threw: %s\n", e.what());
    }
    CHECK(ok, "L1: self-weight analyze_job still runs after the refactor");
    if (ok)
      CHECK(r.margin_required == 1.5,
            "L1: self-weight uses the job's margin_stop unchanged");
  }
}
#endif  // DEMO_FIXTURE_DIR && ...

}  // namespace

int main() {
  SettingsRules rules;
  try {
    rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  test_selfweight_reproduction(material, rules);   // L1
  test_loadcase_reproduction(material, rules);      // L2, L3, L4
  test_loadcase_guard_preconditions();              // L5 (builder precondition)
#if defined(DEMO_FIXTURE_DIR) && defined(MATERIALS_JSON_PATH) && \
    defined(SETTINGS_RULES_PATH)
  test_analyze_job_integration();                   // L5 loud refusal + smoke + L1
#endif

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
