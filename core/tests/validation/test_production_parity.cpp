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

#include "topopt/analyze.hpp"  // KnockdownSpec, knockdown_spec_for parity
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
    // Handoff 2026-07-29-geneo-arming — the GenEO two-level deflation is a
    // PRODUCTION setting, not a library default: the reference world never calls
    // configure_production_options, so it sees the deflation OFF and every
    // Jacobi-CG fallback byte-identical to the pre-arming tree. THE ONE RULE,
    // checked BEFORE the call (and pinned by the header static_assert on
    // kGeneoTwoLevelLibraryDefaultOff).
    CHECK(!topopt::fea_geneo_twolevel_enabled(),
          "library default leaves the GenEO two-level deflation OFF (reference "
          "untouched, byte-identical)");
    CHECK(topopt::fea_geneo_basis_dim() == 0 &&
              topopt::fea_geneo_basis_builds() == 0,
          "no GenEO basis exists before any production run");
    // Handoff 2026-08-01-multiscale-production-wiring — the MATRIX-FREE CUBIC
    // LATTICE route is a PRODUCTION setting, not a library default: the
    // reference world never calls configure_production_options, so every
    // fea_solve_cg_lattice it runs is the assembled Jacobi-CG path
    // byte-identical to the pre-wiring tree. THE ONE RULE, checked BEFORE the
    // call (and pinned by the header static_assert on
    // kMatfreeCubicLatticeLibraryDefaultOff).
    CHECK(!topopt::fea_matfree_cubic_lattice_enabled(),
          "library default leaves the matrix-free cubic lattice route OFF "
          "(reference untouched, byte-identical)");
    // Handoff 2026-07-26-ad-arming — the ACTIVE DOMAIN band is a PRODUCTION
    // setting, not a library default. The reference world (Gate-V2, the property
    // suite, every core test) never calls configure_production_options, so it sees
    // the band OFF and every trajectory solve on the FULL domain — byte-identical
    // to the pre-arming tree. THE ONE RULE, checked before the call.
    CHECK(opts.simp.active_domain_band == 0,
          "library default leaves the active-domain band OFF (reference untouched, "
          "byte-identical)");
    // Handoff 2026-07-26-draft-arming — DRAFT QUALITY is a PRODUCTION setting, not a
    // library default. The reference world never calls configure_production_options,
    // so it sees draft OFF and every trajectory solve at the tight cg_tolerance —
    // byte-identical to the pre-arming tree. THE ONE RULE, checked BEFORE the call.
    CHECK(!opts.draft_quality,
          "library default leaves draft quality OFF (reference untouched, "
          "byte-identical)");
    CHECK(opts.simp.cg_tolerance == 1e-8,
          "library default certification tolerance is the tight 1e-8");
    // Width-aware knockdown (handoff 2026-07-26-width-aware-knockdown): the library
    // default leaves it OFF, so the reference world gates on the pure f^1.5 scalar —
    // byte-identical to the pre-width gate. THE ONE RULE, checked before the call.
    CHECK(!opts.width_aware_knockdown,
          "library default leaves the width-aware knockdown OFF (reference untouched)");
    const int hw_threads = static_cast<int>(std::thread::hardware_concurrency());
    const int auto_threads = hw_threads > 0 ? hw_threads : 1;
    CHECK(topopt::fea_matfree_thread_count() == auto_threads,
          "library default resolves the thread count to hardware concurrency");

    configure_production_options(opts);
    CHECK(opts.simp.solver == SolverKind::MultigridCG_Matfree,
          "production config selects the matrix-free multigrid solver");
    CHECK(opts.min_feature_mm == 2.5,
          "production config sets the 2.5 mm physical min-feature scale");
    // Width-aware knockdown stays OFF in the SHIPPED production config — arming is a
    // separate maintainer act (handoff 2026-07-26-width-aware-knockdown, bar K1). The
    // config echoes exactly the named constant, so this asserts run_info's posture.
    CHECK(opts.width_aware_knockdown == topopt::production_width_aware_knockdown(),
          "production config echoes the width-aware arming constant");
    CHECK(!opts.width_aware_knockdown,
          "production config leaves the width-aware knockdown OFF (shipped default; "
          "arming is a separate maintainer decision)");
    // Handoff 2026-07-26-post-merge-build-fix (F3) — THE BRIDGE AND THE CLI AGREE.
    // The accept-gate KnockdownSpec that the on-device bridge (TopOptBridge
    // analyze_selfweight), the CLI standalone re-analysis (run_job) and the optimizer
    // all pass is built by ONE shared function, knockdown_spec_for. Assert that the
    // POSTURE it yields from the production options equals what configure_production_options
    // arms — checked against the NAMED constant, not a literal. The post-merge break
    // existed precisely because nothing checked that: the bridge silently kept passing a
    // bare scalar, so the iPad could have certified a part under a different knockdown
    // than the Mac worker. This assertion is the tripwire that would have caught it.
    const topopt::KnockdownSpec bridge_spec = topopt::knockdown_spec_for(opts);
    CHECK(bridge_spec.width_aware == topopt::production_width_aware_knockdown(),
          "the shared knockdown_spec_for posture (what the bridge passes) echoes the "
          "width-aware arming constant configure_production_options arms");
    CHECK(bridge_spec.width_aware == opts.width_aware_knockdown,
          "the shared knockdown spec reads the width-aware flag off the same options "
          "the config populated (bridge == CLI == optimizer by construction)");
    CHECK(!bridge_spec.width_aware,
          "the shared knockdown spec is the pure f^1.5 scalar posture in the shipped "
          "production config (byte-identical to the pre-width gate)");
    CHECK(bridge_spec.infill_percent == opts.infill_percent,
          "the shared knockdown spec carries the job infill for the per-voxel core term");
    // Wall-ring thickness (handoff line-width-plumbing). The shared spec sizes it from
  // the outer/inner split t = outer + (loops-1)·inner. In the production opts the outer
  // width is the mirror-inner sentinel (< 0), so it MUST collapse to loops·inner — the
  // byte-identical value the pre-split formula produced. This pins that the split never
  // perturbs a single-width job.
  CHECK(bridge_spec.wall_thickness_mm ==
              static_cast<double>(opts.wall_loops) * opts.wall_line_width_mm,
          "the shared knockdown spec sizes the wall ring to loops·inner when the outer "
          "width mirrors the inner (byte-identical to the pre-split formula)");
  // And when the outer width is set DIFFERENTLY from the inner, the spec lays down one
  // outer bead + (loops-1) inner beads — what Bambu/Orca actually deposit — not loops×
  // either width. This is the whole point of the split.
  {
    MinimizePlasticOptions split = opts;
    split.wall_loops = 5;
    split.wall_line_width_mm = 0.45;        // inner
    split.wall_line_width_outer_mm = 0.42;  // outer (narrower, a common real profile)
    const topopt::KnockdownSpec s = topopt::knockdown_spec_for(split);
    CHECK(std::abs(s.wall_thickness_mm - (0.42 + 4.0 * 0.45)) < 1e-12,
          "outer≠inner sizes t = outer + (loops-1)·inner (0.42 + 4·0.45 = 2.22 mm)");
    // The naive loops·inner would read 2.25 mm — assert we are NOT that.
    CHECK(std::abs(s.wall_thickness_mm - 5.0 * 0.45) > 1e-6,
          "the split is not the naive loops·inner (2.25 mm)");
    // 0 loops → no ring regardless of the widths.
    split.wall_loops = 0;
    CHECK(topopt::knockdown_spec_for(split).wall_thickness_mm == 0.0,
          "0 wall loops → t = 0 (no wall rescue) even with widths set");
  }
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
    // Handoff 2026-07-29-geneo-arming — the ARMED GenEO two-level deflation.
    // These assertions ARE the config echo run_info.json emits (geneo_twolevel /
    // geneo_trigger_iters / geneo_rebuild_factor come from these same accessors
    // in run_job.cpp). Each value is a measured decision (see the TRIPWIRE in
    // production.cpp and the recipe tripwire in src/fea/geneo.hpp); changing any
    // requires re-running geneo_twolevel_probe + geneo_arming_gate and landing a
    // new gate table.
    CHECK(topopt::fea_geneo_twolevel_enabled() ==
              topopt::production_geneo_twolevel(),
          "production config arms the GenEO deflation to the named constant");
    CHECK(topopt::production_geneo_twolevel(),
          "the production GenEO posture is ARMED (2026-07-29 maintainer decision)");
    CHECK(topopt::fea_geneo_trigger_iters() == 500,
          "the stagnation trigger is 500 plain iterations (~1.5x the measured "
          "healthy-fallback ceiling of ~327, ~0.3x the 1.7k-41k stagnation floor)");
    CHECK(topopt::fea_geneo_rebuild_factor() == 2.0,
          "the degradation rebuild factor is 2.0 (phase 2 §P6: healthy reuse "
          "stays within 1.42x of a fresh rebuild)");
    // Handoff 2026-08-02-geneo-disarm — the ENGAGEMENT GATE's two cost-model
    // constants, echoed into run_info beside the trigger. They set the price at
    // which a HELD basis is allowed to engage: a coarse refresh costs ~2 plain
    // iterations per basis column (N_t matvecs + the N_t^2 Galerkin assembly)
    // and a deflated CG iteration costs ~2 plain ones (PR 275 timed one apply at
    // 1.22 ms against a 1.15 ms matvec; PR 273's medians give 4.70/2.05 = 2.29).
    // 2.0 is the low end of both measurements, deliberately — under-pricing
    // GenEO makes the gate MORE willing to engage, which protects the rescue.
    CHECK(topopt::fea_geneo_refresh_cost_per_column() == 2.0,
          "a coarse refresh is priced at 2 plain iterations per basis column");
    CHECK(topopt::fea_geneo_deflated_iter_cost() == 2.0,
          "a deflated CG iteration is priced at 2 plain ones");
    CHECK(topopt::fea_geneo_declined_solves() >= 0,
          "the gate's decline counter is exposed for the run_info echo");
    // Handoff 2026-08-01-multiscale-production-wiring — the ARMED matrix-free
    // cubic lattice route: every lattice certification solve now rides the
    // matrix-free multigrid + GenEO + recycling stack on the exact three-block
    // cubic operator. Asserted against the named constant (see the TRIPWIRE in
    // production.cpp); an exact accelerator like recycling/GenEO — SPD
    // preconditioners, unchanged stopping test — so the certificate's verdict
    // logic and tolerance are untouched.
    CHECK(topopt::fea_matfree_cubic_lattice_enabled() ==
              topopt::production_matfree_cubic_lattice(),
          "production config arms the matrix-free cubic lattice route to the "
          "named constant");
    CHECK(topopt::production_matfree_cubic_lattice(),
          "the production cubic-lattice posture is ARMED "
          "(2026-08-01 multiscale production wiring)");
    // Handoff 2026-08-01-active-domain-disarm — the active-domain band is
    // DISARMED (0), reversing the 2026-07-26 arming. Asserted against the named
    // constant, not a bare 0, so a drift fails here. With the band at 0 every
    // production trajectory solve runs the FULL domain, so production is once
    // again bit-identical to the library default on this axis. The tripwire is
    // real in BOTH directions: re-arming requires re-running the gate harnesses
    // named in production.cpp and landing a new before/after gate table.
    CHECK(opts.simp.active_domain_band == topopt::production_active_domain_band(),
          "production config sets the active-domain band to the named constant");
    CHECK(topopt::production_active_domain_band() == 0,
          "the production active-domain band is DISARMED (0) "
          "(2026-08-01-active-domain-disarm)");

    // Handoff 2026-07-26-draft-arming — the ARMED draft posture (bar A1). Draft is
    // now the ONLY production dial that is NOT bit-identical when on — the
    // active-domain band was the other, disarmed 2026-08-01 (the trajectory drifts
    // on some mid-ladder rungs; the certificate never does). Asserted against the
    // NAMED loose tolerance, not a bare 1e-3, so a silent drift fails here. The
    // escalation trigger stays DISARMED — 185 (compliance gap) and 197 (design-space
    // probe) each measured it not to separate — so the ALWAYS-exact certification is
    // the sole safety.
    CHECK(opts.draft_quality, "production config arms draft quality");
    CHECK(opts.draft_loose_tol == topopt::production_draft_loose_tol(),
          "production config arms the named draft loose tolerance (not a literal)");
    CHECK(topopt::production_draft_loose_tol() == 1e-3,
          "the production draft loose tolerance is 1e-3 (the measured-safe tight end "
          "of 185/197's 500x robustness sweep; see the production.cpp TRIPWIRE)");
    CHECK(!opts.draft_use_design_trigger,
          "production leaves the design-space escalation trigger DISARMED "
          "(197: measured structurally blind to basin/path divergence)");
    // The Phase-1 compliance-gap fallback is DISABLED, not left at its retired 0.02
    // default: the escalate rule is `gap <= 0 || gap > threshold`, so a threshold far
    // above any achievable relative compliance gap means "never escalate" (while a
    // threshold <= 0 would mean escalate EVERY rung — the opposite). Assert it is that
    // disable sentinel, so a drift back to a firing threshold fails here.
    CHECK(opts.draft_escalation_c_gap > 1e6,
          "production DISABLES the compliance-gap escalation fallback (threshold set "
          "beyond any achievable gap; 197: do not rely on the gap)");

    // Bar A2 — THE GATE NEVER SOFTENS, enforced NDEBUG-INDEPENDENTLY. The C++
    // assert() guards in simp.cpp (the final certification solve) and
    // minimize_plastic.cpp (the stress-recovery + escalation solves) are compiled OUT
    // of a -DNDEBUG Release build, so they cannot be the shipped enforcement. These
    // CHECKs enforce the SAME invariant unconditionally: production never softens the
    // certification tolerance, and the draft loose->tight schedule's FLOOR (design at
    // rest) equals that tight certification tolerance while its ceiling (design at
    // full motion) is never tighter — so the final certified solve is at least as
    // tight as every trajectory solve, whatever draft does to the interior. `sched`
    // is the SimpOptions the driver hands each rung: cg_tolerance_loose set to the
    // armed draft loose endpoint, exactly as minimize_plastic does per rung.
    CHECK(opts.simp.cg_tolerance == 1e-8,
          "production config leaves the certification tolerance tight (1e-8); draft "
          "arms ONLY the loose trajectory endpoint");
    {
      topopt::SimpOptions sched = opts.simp;
      sched.cg_tolerance_loose = opts.draft_loose_tol;  // what the driver sets per rung
      CHECK(topopt::adaptive_traj_cg_tol(sched, 0.0) == sched.cg_tolerance,
            "draft schedule FLOOR (design at rest) == the tight certification "
            "tolerance — the gate never softens (same invariant as the simp.cpp "
            "assert, enforced here regardless of NDEBUG)");
      CHECK(topopt::adaptive_traj_cg_tol(sched, sched.move) >= sched.cg_tolerance,
            "draft schedule is NEVER tighter than the certification tolerance at any "
            "design motion");
      CHECK(sched.cg_tolerance_loose > sched.cg_tolerance,
            "the armed draft loose endpoint is genuinely looser than the tight "
            "certification tolerance (a value <= it would silently do nothing)");
    }
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

  // Handoff 2026-08-01-active-domain-disarm — THE DISARM, PINNED ON A REAL RUN.
  // The arming's bar A2 asserted here that AUTO resolved to a derived positive
  // width; the disarm asserts the reverse on the same real production ladder:
  // every rung ran with band 0, i.e. the FULL domain, so no trajectory solve is
  // restricted and nothing in the run is an approximation on this axis.
  //
  // What is DELIBERATELY still asserted is the DERIVATION ITSELF. Disarming
  // withdrew the production REQUEST, not the mechanism: active_domain_auto_band
  // still resolves ceil(rmin)+1 for the grid this ladder solved on, and the
  // harnesses named in production.cpp's tripwire still drive it. Keeping the
  // derivation pinned here means a future re-arming flips ONE constant and finds
  // this bar already standing, rather than rebuilding it from scratch.
  {
    const double spacing = s1.solved_grid.spacing;
    const double rmin =
        topopt::physical_filter_radius(s1.options.min_feature_mm, spacing);
    const int expected_k = topopt::active_domain_auto_band(rmin);
    CHECK(expected_k > 0,
          "the auto-band derivation still yields a positive width (the mechanism "
          "survives the disarm; only the production request is withdrawn)");
    CHECK(!r1.evaluated.empty(), "the production run evaluated at least one rung");
    for (const auto& v : r1.evaluated) {
      CHECK(v.optimization.active_domain_band == 0,
            "each rung ran with the band DISARMED (0) — every trajectory solve on "
            "the full domain (2026-08-01-active-domain-disarm)");
      CHECK(!v.optimization.active_domain_latched,
            "a disarmed run has no latch to fire");
      CHECK(v.optimization.active_domain_escape_count == 0,
            "a disarmed run has no band to escape");
      // THE OBSERVABILITY SURVIVES THE DISARM (the disarm handoff's T4). Every
      // active_domain_* field is still computed and still finalized onto the
      // variant — run_job.cpp copies them into run_info.json unconditionally —
      // so a disarmed run records "the whole domain was active" as a POSITIVE
      // statement, and a future re-arming has a like-for-like baseline to diff
      // against instead of an absent field.
      CHECK(v.optimization.active_fraction_mean == 1.0,
            "a disarmed run reports active_fraction_mean = 1.0 (the whole domain "
            "was active) — the observability is still written, not dropped");
      CHECK(v.optimization.active_domain_latch_reason.empty(),
            "a disarmed run carries no latch reason");
    }
    std::printf("  [AD disarm] production band DISARMED: every rung ran band=0 "
                "(the AUTO derivation would have given k=%d at rmin=%.3f voxels, "
                "spacing=%.3f mm) on %d rung(s)\n",
                expected_k, rmin, spacing, (int)r1.evaluated.size());
  }

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
