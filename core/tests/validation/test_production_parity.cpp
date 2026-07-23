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
//       (matrix-free multigrid, physical min-feature 2.5 mm) and arms the right
//       process globals: the Galerkin block cache and the performance-core thread
//       pin (handoff 132 (C)) ON, the mixed-precision V-cycle (handoff 132 (D))
//       deliberately OFF. Each global is checked BEFORE and AFTER the call, so the
//       test proves both halves of the one rule: the LIBRARY defaults are untouched
//       (cache off, FP64, automatic hardware-concurrency — what Gate-V2 and every
//       core reference run see, since they never call this function) and PRODUCTION
//       arms exactly what it should. These are the values run_info.json echoes.
//   (f) the thread pin is a pure performance dial: a whole production ladder is
//       bit-identical at the pinned count and at full hardware concurrency.
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
#include <thread>  // hardware_concurrency — the 132 (C) thread-count assertions
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
    // Handoff 123 — the CONDITIONAL projection gate is a PRODUCTION-config setting,
    // not a library default: the library leaves the threshold 0 (gate disabled) and
    // simp.mma_projection false, so Gate-V2 and every core reference run — which
    // never call configure_production_options — stay byte-identical. (This
    // supersedes PR 146's always-on flip, which set simp.mma_projection = true here;
    // the conditional never sets that bool — the driver flips it per-rung when the
    // gate fires.)
    CHECK(opts.conditional_mma_projection_mnd_threshold == 0.0,
          "library default leaves the conditional-projection gate OFF");
    CHECK(!opts.simp.mma_projection,
          "library default leaves MMA projection OFF (reference untouched)");
    CHECK(opts.updater == topopt::SimpUpdater::MMA,
          "production default updater is MMA (the gate's target path)");

    // Handoff 132 — the three matrix-free PROCESS GLOBALS, read BEFORE the call.
    // This half of the assertion is the "library defaults untouched" rule: the
    // reference world (Gate-V2, the property suite, every core test) never calls
    // configure_production_options, so what it sees is exactly this state.
    CHECK(!topopt::fea_matfree_galerkin_block_cache_enabled(),
          "library default leaves the Galerkin block cache OFF");
    CHECK(!topopt::fea_matfree_mixed_precision_enabled(),
          "library default leaves the mixed-precision V-cycle OFF (reference FP64)");
    // Handoff 133 — Krylov recycling is a PRODUCTION setting, not a library
    // default: the reference world never calls configure_production_options, so it
    // sees recycling OFF and every solve byte-identical to the pre-133 tree.
    CHECK(!topopt::fea_krylov_recycling_enabled(),
          "library default leaves Krylov recycling OFF (reference untouched)");
    CHECK(!opts.krylov_recycle_reset_per_rung,
          "library default carries the recycle basis across rungs (133 §4 lifetime)");
    const int hw_threads = static_cast<int>(std::thread::hardware_concurrency());
    const int auto_threads = hw_threads > 0 ? hw_threads : 1;
    CHECK(topopt::fea_matfree_thread_count() == auto_threads,
          "library default resolves the thread count to hardware concurrency");

    configure_production_options(opts);
    CHECK(opts.simp.solver == SolverKind::MultigridCG_Matfree,
          "production config selects the matrix-free multigrid solver");
    CHECK(opts.min_feature_mm == 2.5,
          "production config sets the 2.5 mm physical min-feature scale");
    // Config echo (per the 141-lineage mechanism): the production config ARMS the
    // conditional gate at the 0.07 grayness threshold and does NOT set the always-on
    // simp.mma_projection bool — projection is now per-rung and gate-driven.
    CHECK(opts.conditional_mma_projection_mnd_threshold == 0.07,
          "production config arms the conditional-projection gate at Mnd 0.07");
    CHECK(!opts.simp.mma_projection,
          "production config leaves the always-on MMA projection bool OFF "
          "(the driver flips it per-rung when the gate fires)");
    // The three process globals, read AFTER the call — the "production arms them"
    // half. Read through the 114 accessors (pure reads, they never perturb state)
    // because these ARE the values run_info.json echoes: galerkin_block_cache,
    // mixed_precision and matfree_threads all come from these same functions in
    // run_job.cpp's build_run_info, so asserting them here is asserting the echo.
    CHECK(topopt::fea_matfree_galerkin_block_cache_enabled(),
          "production config enabled the Galerkin block cache global");
    // Handoff 132 (D) — mixed precision stays OFF in production, and that is a
    // MEASURED DECISION, not an oversight. The flip was implemented and gated on a
    // full l-bracket ladder; it regressed CG iterations 40715 -> 48717 (1.197x) in
    // both the grayscale and fired-projection phases, so it was withdrawn. This
    // assertion is the tripwire: anyone who arms it must re-run that gate first
    // (core/tests/harness/mixed_precision_probe.cpp) and land new numbers.
    CHECK(!topopt::fea_matfree_mixed_precision_enabled(),
          "production config leaves the mixed-precision V-cycle OFF "
          "(132 (D): gated, measured a 1.197x CG-iteration regression, blocked)");
    // Handoff 132 (C) — the performance-core pin. Asserted against the named
    // production count rather than a literal, so this stays true on Apple silicon
    // (P-core count), on Intel Macs and on Linux CI (hardware_concurrency).
    const int prod_threads = topopt::production_matfree_thread_count();
    CHECK(prod_threads >= 1, "the production thread count is at least 1");
    CHECK(prod_threads <= auto_threads,
          "the production thread count never exceeds hardware concurrency");
    CHECK(topopt::fea_matfree_thread_count() == prod_threads,
          "production config pinned the matrix-free apply to the production "
          "(performance-core) thread count");

    // Handoff 133 §10 — the ARMED Krylov recycling package. These four assertions
    // ARE the config echo run_info.json emits (krylov_recycling / recycle_dim /
    // wrap_multigrid come from these same accessors in run_job.cpp), so asserting
    // them here asserts the echo. Each value is a measured decision, not a default:
    // changing any of them requires re-running core/tests/harness/recycle_probe.cpp
    // on BOTH regimes and landing new numbers.
    CHECK(topopt::fea_krylov_recycling_enabled(),
          "production config arms Krylov recycling");
    CHECK(topopt::fea_krylov_recycle_dim() == topopt::production_krylov_recycle_dim(),
          "production config arms the measured recycle dimension k");
    CHECK(topopt::production_krylov_recycle_dim() == 16,
          "the measured production k is 16 (the {8,16,24} sweep optimum)");
    // The tripwire on the maintainer's §10 decision: wrapping the V-cycle REGRESSED
    // the multigrid regime 1.23x-2.07x across the whole k sweep, so the armed
    // posture is Jacobi-only and the non-targeted regime is an exact no-op.
    CHECK(!topopt::fea_krylov_recycle_wrap_multigrid(),
          "production config arms the JACOBI-ONLY posture (133 §10: wrapping the "
          "V-cycle measured a 1.23x-2.07x regression)");
    CHECK(topopt::fea_krylov_recycle_cycle() == 1,
          "production leaves the rebuild cycle at 1 (a 4-solve-old basis measured "
          "worth almost nothing: 48.1% -> 2.7%)");
    CHECK(!opts.krylov_recycle_reset_per_rung,
          "production config carries the recycle basis across rung boundaries "
          "(133 §4: measured mildly better in both regimes, worse in neither)");
    // The pin is a DEFAULT, not a lock: an explicit fea_set_matfree_threads after
    // configure_production_options must win, and n <= 0 must restore automatic
    // hardware-concurrency resolution. (Restored to the production pin after, so
    // the rest of this gate runs under the real production configuration.)
    topopt::fea_set_matfree_threads(auto_threads);
    CHECK(topopt::fea_matfree_thread_count() == auto_threads,
          "an explicit thread count overrides the production pin");
    topopt::fea_set_matfree_threads(0);
    CHECK(topopt::fea_matfree_thread_count() == auto_threads,
          "n <= 0 restores automatic hardware-concurrency resolution");
    topopt::fea_set_matfree_threads(prod_threads);
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

  // (f) Handoff 132 (C) — DETERMINISM AT BOTH THREAD COUNTS, end to end. r1/r2 above
  // ran at the production pin (the performance-core count). The matrix-free apply's
  // 8-colour partition makes the field bit-identical at any thread count BY DESIGN,
  // and test_matfree_threads asserts that at the solver level; this asserts it where
  // the flip actually lands — a whole production minimize_plastic ladder — so the
  // pin is proven to be a pure performance dial and not a design change. Re-run the
  // SAME setup at full hardware concurrency and require the same part, bit for bit.
  //
  // Skipped when the two counts coincide (a non-Apple-silicon or single-core-class
  // host), where there is no second count to compare against and r3 would be r1.
  {
    const int prod_threads = topopt::production_matfree_thread_count();
    const int hw = static_cast<int>(std::thread::hardware_concurrency());
    const int auto_threads = hw > 0 ? hw : 1;
    if (prod_threads != auto_threads) {
      ProductionRunSetup s3 = build_production_loadcase(model, resolution, lc);
      s3.options.simp.max_iterations = 8;
      topopt::fea_set_matfree_threads(auto_threads);
      CHECK(topopt::fea_matfree_thread_count() == auto_threads,
            "the cross-check run is really on the full hardware thread count");
      const MinimizePlasticResult r3 = topopt::minimize_plastic(
          s3.grid, material, "PLA", s3.bcs, rules, s3.options);
      topopt::fea_set_matfree_threads(prod_threads);  // restore the production pin
      check_designs_identical(r1, r3);
      std::printf("  [132 (C)] design bit-identical at %d and %d threads\n",
                  prod_threads, auto_threads);
    } else {
      std::printf("  [132 (C)] single core class (%d threads): "
                  "no second count to cross-check\n", prod_threads);
    }
  }

  if (g_failures == 0)
    std::printf("production parity (handoff 093): all checks passed\n");
  else
    std::printf("production parity: %d CHECK(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
