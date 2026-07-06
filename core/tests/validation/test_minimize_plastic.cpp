// M5.3 integration test — the minimize_plastic end-to-end driver
// (topopt/pipeline.hpp): self-weight loading + a descending volume-fraction
// ladder, stopping at the first rung whose worst-case stress margin < 1.5.
//
// The "bracket fixture": DECISIONS.md (2026-07-03) reserves core/tests/fixtures/
// authoring to the human maintainer, and no bracket file is committed, so — as
// the other end-to-end optimizer tests do (test_v3 group 4, test_variants,
// test_v4 all build their parts in code) — this test builds a cantilever
// BRACKET voxel grid in code: a solid arm clamped at its root (mounting) face
// that projects out and sags under the part's own weight. No golden numeric
// values are asserted; the checks are behavioral/structural (the stop
// invariant, V3 property gates, descending volume fractions, schema validity,
// determinism), so nothing here is a maintainer-owned fixture value.
//
// The driver drives simp_optimize (Eigen), so this test is gated on Eigen in
// CMake like the other optimizer gates. The settings rule table's absolute path
// is injected (SETTINGS_RULES_PATH) like test_settings, so the real table is
// used. No third-party test framework (ARCHITECTURE §4); the same self-contained
// CHECK harness as the other tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::DirichletBC;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::SettingsRules;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

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

namespace {

// A cantilever bracket: a solid rectangular arm clamped at its root face
// (i == 0, the mounting face) that projects out in +i and sags under its own
// weight (gravity -z). This is the §5 self-weight case on the same clamped-root
// cantilever the M3 optimizer tests use (test_v3 / test_variants), where lower
// volume fraction => a weaker arm => lower stress margin (monotone), so the
// ladder crosses margin_stop cleanly. Small on purpose (fast CI): 20 x 4 x 5
// grid = 400 solid voxels.
VoxelGrid cantilever_bracket(std::vector<DirichletBC>& bcs, double h = 2.0) {
  const int nx = 20, ny = 4, nz = 5;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);

  // Mounting face: the root plane i == 0, tagged Fixture (retained structurally
  // by the mask-aware optimizer, M3.7).
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);

  // Clamp every node on the i == 0 plane in all three DOFs (fully removes rigid
  // body modes; matches the cantilever clamp in test_v3 / test_variants).
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
}

// A synthetic FDM material. Real materials.json values (PLA yield 55 MPa) give
// an astronomically large self-weight margin for a cm-scale plastic part, so
// the ladder would never cross 1.5. To exercise the stop rule we use a low
// yield strength; this is an in-code test material (NOT an edit to
// materials.json), analogous to the synthetic variants in test_report.
Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 0.02;  // low, so self-weight stress is comparable
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

MinimizePlasticOptions base_options() {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.7, 0.5, 0.3};
  o.margin_stop = 1.5;
  o.gravity = 1.0;                       // scaled per scenario below
  o.gravity_direction = Vec3{0, 0, -1};  // build direction +z
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 40;
  o.simp.change_tol = 0.0;  // run the full cap (oscillating discrete designs)
  o.simp.cg_tolerance = 1e-8;
  return o;
}

// The core stop invariant, independent of the physics scale: the accepted
// prefix all clear the threshold, the terminal rejected rung (if any) is below
// it, and nothing was evaluated past the stop.
void check_stop_invariant(const MinimizePlasticResult& r, double stop,
                          const char* ctx) {
  for (std::size_t v = 0; v < r.evaluated.size(); ++v) {
    const MinimizePlasticVariant& ev = r.evaluated[v];
    const bool is_last = (v + 1 == r.evaluated.size());
    const double m = ev.report.margin.worst_case;
    if (ev.accepted) {
      CHECK(m >= stop, "invariant: accepted rung has margin >= margin_stop");
    } else {
      CHECK(is_last, "invariant: only the terminal rung may be rejected");
      CHECK(r.stopped_on_margin,
            "invariant: a rejected rung sets stopped_on_margin");
      CHECK(m < stop, "invariant: the terminal rung has margin < margin_stop");
    }
    (void)ctx;
  }
  // The report holds exactly the accepted rungs, in order.
  std::size_t accepted = 0;
  for (const MinimizePlasticVariant& ev : r.evaluated)
    if (ev.accepted) ++accepted;
  CHECK(r.report.variants.size() == accepted,
        "invariant: report carries exactly the accepted variants");
  // Achieved volume fractions strictly descend across accepted variants (the
  // ladder is descending and each rung hits its own target).
  for (std::size_t v = 1; v < r.report.variants.size(); ++v)
    CHECK(r.report.variants[v].volume_fraction <
              r.report.variants[v - 1].volume_fraction,
          "invariant: accepted variants descend in volume fraction");
  // The assembled report is schema-valid.
  bool valid = true;
  try {
    topopt::validate_job_report_json(topopt::job_report_json(r.report));
  } catch (const std::exception&) {
    valid = false;
  }
  CHECK(valid, "invariant: assembled JobReport validates against the schema");
}

// Every accepted variant's optimizer output passes the two V3 mesh gates that
// the isotropic loop satisfies (watertight + single component) — the §7 V3
// "every optimized output" mandate, and Fixture retention is structural.
void check_v3_on_accepted(const MinimizePlasticResult& r) {
  for (const MinimizePlasticVariant& ev : r.evaluated) {
    if (!ev.accepted) continue;
    CHECK(ev.v3.gate_watertight(),
          "V3(variant): accepted optimizer output is watertight");
    CHECK(ev.v3.gate_single_component(),
          "V3(variant): accepted optimizer output is one component");
    CHECK(ev.v3.gate_load_fixture_retained(),
          "V3(variant): Fixture voxels retained at density >= 0.9");
    // The report line's min-feature count mirrors the V3 report.
    CHECK(ev.report.min_feature_violations == ev.v3.min_feature_violations,
          "report: min_feature_violations mirrors the V3 count");
  }
}

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

  // Calibration carried from scenario A (accept-all) into the mixed-walk
  // scenarios. The margin is a ratio (yield / stress) and the minimum-compliance
  // topology is invariant to the self-weight load magnitude, so each rung's
  // margin scales EXACTLY as 1 / gravity. Measuring every rung's margin once at
  // a reference gravity lets us place the fixed margin_stop = 1.5 threshold
  // between two chosen rungs analytically, instead of guessing a gravity.
  const double cal_gravity = 1e-6;
  std::vector<double> cal_margins;  // per-rung worst-case margin at cal_gravity

  // =========================================================================
  // Scenario A — accept-all: tiny gravity => every rung is far above 1.5, so
  // the whole ladder is accepted and the driver never stops on margin.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    CHECK(!r.stopped_on_margin,
          "A: tiny gravity => no margin stop (whole ladder accepted)");
    CHECK(r.evaluated.size() == o.volume_fraction_ladder.size(),
          "A: every ladder rung evaluated");
    CHECK(r.report.variants.size() == o.volume_fraction_ladder.size(),
          "A: every rung accepted into the report");
    for (const MinimizePlasticVariant& ev : r.evaluated)
      CHECK(ev.accepted && ev.report.margin.worst_case >= o.margin_stop,
            "A: each rung is strong enough");
    check_stop_invariant(r, o.margin_stop, "A");
    check_v3_on_accepted(r);
    // Lower volume fraction => a weaker arm => a lower margin (monotone), which
    // is what makes a descending-ladder mixed walk crossable.
    for (std::size_t v = 0; v < r.evaluated.size(); ++v)
      cal_margins.push_back(r.evaluated[v].report.margin.worst_case);
    for (std::size_t v = 1; v < cal_margins.size(); ++v)
      CHECK(cal_margins[v] < cal_margins[v - 1],
            "A: margin strictly decreases with volume fraction (monotone)");
    std::printf("[A accept-all] evaluated=%zu accepted=%zu stopped=%d\n",
                r.evaluated.size(), r.report.variants.size(),
                static_cast<int>(r.stopped_on_margin));
    for (const MinimizePlasticVariant& ev : r.evaluated)
      std::printf("   [A rung req=%.2f achieved=%.4f margin=%.6g]\n",
                  ev.requested_volume_fraction, ev.report.volume_fraction,
                  ev.report.margin.worst_case);
  }

  // Gravity that places margin_stop between the last two rungs of the ladder:
  // the geometric mean of their calibrated margins, scaled by 1/gravity, sits
  // the threshold strictly between them. With a monotone ladder every earlier
  // rung stays above the threshold, so the driver accepts all but the last rung
  // (a genuine mid-ladder stop) — all with the ROADMAP's margin_stop = 1.5.
  const std::size_t n = cal_margins.size();
  const double g_mixed =
      (n >= 2)
          ? cal_gravity * std::sqrt(cal_margins[n - 2] * cal_margins[n - 1]) /
                1.5
          : 6.0;

  // =========================================================================
  // Scenario B — immediate stop: huge gravity => even the densest rung (0.7)
  // is too weak, so the driver evaluates exactly one rung and stops with an
  // empty report.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = 1e6;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    CHECK(r.stopped_on_margin, "B: huge gravity => margin stop triggers");
    CHECK(r.evaluated.size() == 1,
          "B: the driver stops after the first (densest) rung");
    CHECK(!r.evaluated.front().accepted &&
              r.evaluated.front().report.margin.worst_case < o.margin_stop,
          "B: the densest rung is rejected (margin < margin_stop)");
    CHECK(r.report.variants.empty(),
          "B: no variant is strong enough => empty report");
    check_stop_invariant(r, o.margin_stop, "B");
    // The empty report still validates.
    std::printf("[B immediate-stop] evaluated=%zu accepted=%zu stopped=%d "
                "margin0=%.4g\n",
                r.evaluated.size(), r.report.variants.size(),
                static_cast<int>(r.stopped_on_margin),
                r.evaluated.front().report.margin.worst_case);
  }

  // =========================================================================
  // Scenario C — mixed walk: the ladder crosses margin_stop = 1.5 at the last
  // rung, so the driver accepts the stronger prefix and stops at the too-weak
  // final rung. The absolute margins are not pinned — only the ordering/stop
  // behavior — so no golden value is asserted; the gravity is derived from A's
  // measured margins (see g_mixed) so the crossing is analytic, not guessed.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = g_mixed;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    check_stop_invariant(r, o.margin_stop, "C");
    check_v3_on_accepted(r);
    CHECK(!r.report.variants.empty(),
          "C: at least one variant is strong enough");
    CHECK(r.stopped_on_margin,
          "C: the ladder crosses the margin threshold and stops");
    CHECK(r.evaluated.size() == r.report.variants.size() + 1,
          "C: exactly one rejected terminal rung past the accepted prefix");
    // The threshold was placed between the last two rungs, so all but the last
    // ladder rung are accepted (a genuine mid-ladder stop).
    CHECK(r.evaluated.size() == o.volume_fraction_ladder.size(),
          "C: the driver walks the whole ladder before the final rung stops it");
    CHECK(r.report.variants.size() == o.volume_fraction_ladder.size() - 1,
          "C: all rungs but the last (too-weak) one are accepted");
    // Margins are non-increasing as volume fraction drops (less material under
    // the same self-weight => weaker). Checked across the evaluated rungs.
    for (std::size_t v = 1; v < r.evaluated.size(); ++v)
      CHECK(r.evaluated[v].report.margin.worst_case <=
                r.evaluated[v - 1].report.margin.worst_case + 1e-9,
            "C: worst-case margin is non-increasing down the ladder");
    for (const MinimizePlasticVariant& ev : r.evaluated)
      std::printf("[C rung vf_req=%.2f vf=%.4f] max_vm=%.4g interlayer=%.4g "
                  "margin=%.4g accepted=%d walls=%d infill=%d%% warn='%s'\n",
                  ev.requested_volume_fraction, ev.report.volume_fraction,
                  ev.report.max_stress_mpa, ev.report.max_interlayer_tension_mpa,
                  ev.report.margin.worst_case, static_cast<int>(ev.accepted),
                  ev.report.settings.walls, ev.report.settings.infill_percent,
                  ev.report.min_feature_warning.c_str());
  }

  // =========================================================================
  // Scenario D — determinism: the same inputs produce byte-identical reports.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = g_mixed;
    const MinimizePlasticResult r1 =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
    const MinimizePlasticResult r2 =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
    CHECK(topopt::job_report_json(r1.report) ==
              topopt::job_report_json(r2.report),
          "D: identical inputs => identical report JSON (deterministic)");
  }

  // =========================================================================
  // Scenario E — settings + margin coupling: the settings recommended for each
  // variant are exactly what recommend_settings returns for that variant's
  // worst-case margin (the driver wires the M5.1 engine, not a hardcode).
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = g_mixed;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
    const double part_dim = 12 * 2.0;  // max grid edge (nx * spacing)
    for (const MinimizePlasticVariant& ev : r.evaluated) {
      const topopt::SlicerSettings want = topopt::recommend_settings(
          rules, material.family, ev.report.margin.worst_case, part_dim);
      CHECK(ev.report.settings.family == want.family &&
                ev.report.settings.walls == want.walls &&
                ev.report.settings.infill_percent == want.infill_percent &&
                ev.report.settings.infill_pattern == want.infill_pattern,
            "E: variant settings match recommend_settings for its margin");
      CHECK(ev.report.settings.family == "fdm",
            "E: FDM material yields FDM settings");
    }
  }

  // =========================================================================
  // Scenario F — argument validation: the driver's own input checks throw.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    auto throws_invalid = [&](MinimizePlasticOptions o) {
      try {
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    MinimizePlasticOptions o = base_options();
    o.gravity = g_mixed;

    MinimizePlasticOptions empty = o;
    empty.volume_fraction_ladder = {};
    CHECK(throws_invalid(empty), "F: empty ladder throws");

    MinimizePlasticOptions ascending = o;
    ascending.volume_fraction_ladder = {0.3, 0.5};
    CHECK(throws_invalid(ascending), "F: non-descending ladder throws");

    MinimizePlasticOptions equal = o;
    equal.volume_fraction_ladder = {0.5, 0.5};
    CHECK(throws_invalid(equal), "F: non-strictly-descending ladder throws");

    MinimizePlasticOptions oob = o;
    oob.volume_fraction_ladder = {1.5, 0.5};
    CHECK(throws_invalid(oob), "F: a ladder fraction > 1 throws");

    MinimizePlasticOptions zerof = o;
    zerof.volume_fraction_ladder = {0.5, 0.0};
    CHECK(throws_invalid(zerof), "F: a zero ladder fraction throws");

    MinimizePlasticOptions badg = o;
    badg.gravity = 0.0;
    CHECK(throws_invalid(badg), "F: zero gravity throws");

    MinimizePlasticOptions badm = o;
    badm.margin_stop = -1.0;
    CHECK(throws_invalid(badm), "F: negative margin_stop throws");

    MinimizePlasticOptions badd = o;
    badd.gravity_direction = Vec3{0, 0, 0};
    CHECK(throws_invalid(badd), "F: zero gravity_direction throws");
  }

  if (g_failures == 0) {
    std::printf("minimize_plastic (M5.3): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "minimize_plastic (M5.3): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
