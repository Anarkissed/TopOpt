// STEP-0 parity gate (handoff 093, LAN compute offload).
//
// The iPad app (TopOptBridge) and topopt-cli are both PRODUCTION front-ends: for
// the same STEP + load case + resolution they must produce the SAME design, or a
// desktop worker running the CLI silently returns a different part than the app.
// They used to diverge because the solver/projection/Galerkin config and the
// load-case geometry lived inline in bridge.cpp only. Both now route through ONE
// core seam — configure_production_options + build_production_loadcase — so drift
// is structurally impossible. This gate proves the seam does what STEP 0 requires:
//
//   (a) configure_production_options sets EXACTLY the production solver config
//       (matrix-free multigrid, physical min-feature 2.5 mm) and enables the
//       process-global Galerkin block cache.
//   (b) build_production_loadcase is DETERMINISTIC: the same model + load case
//       twice yields byte-identical grid, BCs and options.
//   (c) minimize_plastic on that setup is bit-identical run to run — same rung
//       count, same accept/reject decisions, same physical density, same margins.
//       A divergence in any of these would be a different PRODUCT.
//   (d) the load case is actually assembled: external loads present, an anchor
//       pad frozen, and (with a design box) the run solves on the EXPANDED grid.
//
// (b)+(c) are the CLI==app guarantee: run_job (CLI) and run_minimize_plastic_
// loadcase (app) each map their front-end input to a ProductionLoadCase and call
// build_production_loadcase, so identical load cases give identical designs by
// construction; here we prove that construction is deterministic and correctly
// configured. Drives OCCT (STEP import) + Eigen (minimize_plastic), so it is
// gated on both in CMake. The demo l-bracket + real rule table are injected.

#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using topopt::build_production_loadcase;
using topopt::configure_production_options;
using topopt::DesignBox;
using topopt::DirichletBC;
using topopt::Material;
using topopt::MaterialLibrary;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::SettingsRules;
using topopt::SolverKind;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {
int g_failures = 0;
}
#define CHECK(cond, msg)                                             \
  do {                                                               \
    if (!(cond)) {                                                   \
      std::printf("FAIL: %s\n", msg);                                \
      ++g_failures;                                                  \
    }                                                                \
  } while (0)

namespace {

// The exact ProductionLoadCase the parity runs share: the l-bracket's two
// cylindrical holes are anchors, one planar face carries a downward force, the
// reduction ladder + anchor pad are on, and a design box (drawn a little larger
// than the part in +z so it genuinely expands) exercises the domain path.
ProductionLoadCase make_load_case(const StepModel& model) {
  ProductionLoadCase lc;
  ProductionLoadCase::LoadGroup g;
  for (int f = 0; f < model.face_count; ++f) {
    const auto& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind == StepSurfaceKind::Cylinder)
      lc.anchor_face_ids.push_back(f);  // the two O5 holes -> Fixture
    else if (info.kind == StepSurfaceKind::Plane)
      g.face_ids.push_back(f);  // all planar faces carry the load
  }
  g.force = Vec3{0.0, 0.0, -50.0};  // 50 N down, spread over the exposed area
  lc.load_groups.push_back(g);
  lc.minimize_plastic = true;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  // A design box spanning the l-bracket bbox ([-30,-20,0]..[30,20,60]) grown in
  // +z so the expanded grid is strictly larger than the part grid.
  lc.has_design_box = true;
  lc.design_box.min = Vec3{-30.0, -20.0, 0.0};
  lc.design_box.max = Vec3{30.0, 20.0, 75.0};
  return lc;
}

// Bit-identical comparison of two runs' designs — the STEP-0 product guarantee.
void check_designs_identical(const MinimizePlasticResult& a,
                             const MinimizePlasticResult& b) {
  CHECK(a.evaluated.size() == b.evaluated.size(),
        "same rung count run to run");
  CHECK(a.stopped_on_margin == b.stopped_on_margin, "same stop reason");
  CHECK(a.solved_grid.voxel_count() == b.solved_grid.voxel_count(),
        "same solved grid");
  const std::size_t n = std::min(a.evaluated.size(), b.evaluated.size());
  for (std::size_t i = 0; i < n; ++i) {
    const auto& va = a.evaluated[i];
    const auto& vb = b.evaluated[i];
    CHECK(va.accepted == vb.accepted, "same accept/reject per rung");
    CHECK(va.requested_volume_fraction == vb.requested_volume_fraction,
          "same requested VF per rung");
    CHECK(va.report.margin.worst_case == vb.report.margin.worst_case,
          "same worst-case margin per rung (bit-identical)");
    const auto& ra = va.optimization.physical_density;
    const auto& rb = vb.optimization.physical_density;
    CHECK(ra.size() == rb.size(), "same density field size per rung");
    bool same = ra.size() == rb.size();
    for (std::size_t k = 0; same && k < ra.size(); ++k)
      if (ra[k] != rb[k]) same = false;
    CHECK(same, "bit-identical physical density per rung");
  }
}

}  // namespace

int main() {
  const std::string demo_dir = DEMO_FIXTURE_DIR;
  const StepModel model = topopt::import_step_file(demo_dir + "/l-bracket.step");
  const MaterialLibrary materials = topopt::load_materials_file(MATERIALS_JSON_PATH);
  const Material material = materials.at("PLA");
  const SettingsRules rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);

  // (a) configure_production_options sets exactly the production solver config.
  {
    MinimizePlasticOptions opts;  // library defaults
    CHECK(opts.simp.solver == SolverKind::JacobiCG,
          "library default is JacobiCG (Gate-V2 / reference untouched)");
    CHECK(opts.min_feature_mm == 0.0, "library default min_feature is 0");
    CHECK(!opts.simp.mma_projection,
          "library default leaves MMA projection OFF (reference untouched)");
    CHECK(opts.updater == topopt::SimpUpdater::MMA,
          "production default updater is MMA");
    configure_production_options(opts);
    CHECK(opts.simp.solver == SolverKind::MultigridCG_Matfree,
          "production config selects the matrix-free multigrid solver");
    CHECK(opts.min_feature_mm == 2.5,
          "production config sets the 2.5 mm physical min-feature scale");
    // Handoff 116 production flip: the MMA path gets the MMA-correct Heaviside
    // projection so the constraint measures the printed (near-0/1) density, not
    // the gray fringe. Asserted as a CONFIG ECHO (per the 141-lineage mechanism):
    // this gate proves determinism/config, not a golden design.
    CHECK(opts.simp.mma_projection,
          "production config enables MMA Heaviside projection (116 flip)");
    // The Galerkin cache is a process global; configure_production_options must
    // have turned it on (the setter returns the PREVIOUS value).
    const bool prev = topopt::fea_set_matfree_galerkin_block_cache(true);
    CHECK(prev, "production config enabled the Galerkin block cache global");
  }

  const int resolution = 24;  // small: this gate proves determinism, not scale
  const ProductionLoadCase lc = make_load_case(model);

  // (b) build_production_loadcase is deterministic.
  ProductionRunSetup s1 = build_production_loadcase(model, resolution, lc);
  ProductionRunSetup s2 = build_production_loadcase(model, resolution, lc);
  CHECK(s1.grid.voxel_count() == s2.grid.voxel_count(), "same part grid");
  CHECK(s1.bcs.size() == s2.bcs.size(), "same BC count");
  bool bcs_same = s1.bcs.size() == s2.bcs.size();
  for (std::size_t i = 0; bcs_same && i < s1.bcs.size(); ++i)
    if (s1.bcs[i].node != s2.bcs[i].node ||
        s1.bcs[i].component != s2.bcs[i].component)
      bcs_same = false;
  CHECK(bcs_same, "identical BCs");
  CHECK(s1.options.external_loads.size() == s2.options.external_loads.size(),
        "same external-load count");
  CHECK(s1.options.volume_fraction_ladder == s2.options.volume_fraction_ladder,
        "same ladder");

  // (d) the load case is actually assembled + the box expands the domain.
  CHECK(!s1.options.external_loads.empty(),
        "the declared force produced external nodal loads");
  CHECK(!s1.options.design_mask.empty(),
        "the anchor pad was frozen (design_mask non-empty)");
  CHECK(s1.options.volume_fraction_ladder == topopt::production_reduction_ladder(),
        "minimize_plastic path uses the production reduction ladder");
  CHECK(s1.options.simp.solver == SolverKind::MultigridCG_Matfree,
        "the setup carries the production solver config");
  CHECK(s1.solved_grid.voxel_count() > s1.grid.voxel_count(),
        "the design box expands the solved grid beyond the part grid");

  // (e) Warm-start production flip (handoff 114) — LOAD-CASE MODE ONLY. This
  // parity gate has no stored golden design (it proves determinism run-to-run,
  // which the flip preserves — both s1/s2 get the same config), so the flip is
  // asserted here as a CONFIG ECHO: a load-case build (external loads present)
  // enables inheritance; a self-weight build (no load groups → external loads
  // empty) leaves it OFF so self-weight stays byte-identical to the pre-flip run.
  CHECK(s1.options.warm_start_inherit,
        "load-case build enables warm-start inheritance (114 flip)");
  {
    ProductionLoadCase sw = lc;
    sw.load_groups.clear();  // no external loads → self-weight mode
    const ProductionRunSetup sws = build_production_loadcase(model, resolution, sw);
    CHECK(sws.options.external_loads.empty(),
          "self-weight build has no external loads");
    CHECK(!sws.options.warm_start_inherit,
          "self-weight build keeps COLD start (114: not flipped)");
  }

  // (c) minimize_plastic on the setup is bit-identical run to run. Cap iterations
  // (identically on both) so the gate stays fast; determinism is the point.
  s1.options.simp.max_iterations = 8;
  s2.options.simp.max_iterations = 8;
  const MinimizePlasticResult r1 =
      topopt::minimize_plastic(s1.grid, material, "PLA", s1.bcs, rules, s1.options);
  const MinimizePlasticResult r2 =
      topopt::minimize_plastic(s2.grid, material, "PLA", s2.bcs, rules, s2.options);
  check_designs_identical(r1, r2);

  if (g_failures == 0)
    std::printf("production parity (handoff 093): all checks passed\n");
  else
    std::printf("production parity: %d CHECK(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
