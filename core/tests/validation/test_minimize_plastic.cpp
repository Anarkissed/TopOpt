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
#include "topopt/orient.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <atomic>
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

// A fully solid n x n x n cube clamped (and Fixture-tagged) on its i == 0 face.
// Used by the M7.0b visualization-data scenario, where a known all-solid shape
// gives hand-computable mass and a support-free build direction.
VoxelGrid solid_cube(std::vector<DirichletBC>& bcs, int n, double h) {
  VoxelGrid g;
  g.nx = n;
  g.ny = n;
  g.nz = n;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Interior);
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
  bcs.clear();
  for (int c = 0; c <= n; ++c)
    for (int b = 0; b <= n; ++b) {
      const int node = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  return g;
}

// M7.0b — the visualization data exposed on every evaluated NON-cancelled
// variant: (a) printed-voxel von Mises field, (b) the extracted+cleaned variant
// mesh, (c) the support-volume proxy, (d) printed mass. Each is recomputed here
// independently from the variant's own converged density and compared, so these
// checks fail against a stub that leaves the fields default. `build_dir` is the
// analysed build direction (the unit negation of the run's gravity direction).
void check_viz_fields(const MinimizePlasticResult& r, const VoxelGrid& g,
                      const Material& mat, const Vec3& build_dir) {
  const double iso = 0.5;
  for (const MinimizePlasticVariant& ev : r.evaluated) {
    if (ev.optimization.cancelled) continue;  // carve-out checked in scenario H
    const std::vector<double>& rho = ev.optimization.physical_density;

    // (a) von Mises field: grid-indexed, zero on non-printed voxels, nonzero on
    // loaded printed material (the same iso 0.5 the mesh is extracted at).
    CHECK(ev.von_mises_field.size() == g.voxel_count(),
          "viz(a): von_mises_field is grid-indexed (size voxel_count)");
    bool zero_off_printed = true, any_printed_positive = false;
    std::size_t printed = 0;
    for (std::size_t idx = 0; idx < rho.size(); ++idx) {
      const bool is_printed = rho[idx] > iso;
      if (is_printed) ++printed;
      if (!is_printed && ev.von_mises_field[idx] != 0.0) zero_off_printed = false;
      if (is_printed && ev.von_mises_field[idx] > 0.0) any_printed_positive = true;
    }
    CHECK(zero_off_printed, "viz(a): von Mises is zero off the printed material");
    CHECK(any_printed_positive,
          "viz(a): at least one printed voxel carries nonzero von Mises");

    // (b) mesh(): exposes the variant's OWN v3 mesh (same object, not a copy or
    // a recompute), which itself equals an independent check_v3 on the density.
    CHECK(&ev.mesh() == &ev.v3.mesh,
          "viz(b): mesh() aliases v3.mesh (exposed, not duplicated)");
    const topopt::V3Report indep = topopt::check_v3(g, rho, iso);
    CHECK(ev.v3.mesh.vertices.size() == indep.mesh.vertices.size() &&
              ev.v3.mesh.triangles.size() == indep.mesh.triangles.size(),
          "viz(b): the variant mesh matches an independent check_v3");

    // (c) support_volume_voxels: the M4.3 overhang proxy over the PRINTED
    // subgrid (non-printed voxels removed), for the analysed build direction.
    VoxelGrid printed_grid = g;
    for (std::size_t idx = 0; idx < printed_grid.tags.size(); ++idx)
      if (!(rho[idx] > iso)) printed_grid.tags[idx] = VoxelTag::Empty;
    const int want_support =
        topopt::support_overhang_voxels(printed_grid, build_dir);
    CHECK(ev.support_volume_voxels == want_support,
          "viz(c): support_volume_voxels == M4.3 overhang proxy on printed grid");

    // (d) mass_grams: density (g/cm^3) * printed volume (mm^3) / 1000. Recompute
    // in the driver's operation order so the comparison is exact.
    const double want_mass = mat.density_g_cm3 *
                             (static_cast<double>(printed) * g.voxel_volume()) /
                             1000.0;
    CHECK(std::fabs(ev.mass_grams - want_mass) <= 1e-9 * (1.0 + want_mass),
          "viz(d): mass_grams = density * printed volume (spacing-aware)");
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
    // M7.0b: the visualization data on every (accepted, non-cancelled) rung is
    // consistent with an independent recompute (build_dir = -gravity_direction).
    check_viz_fields(r, g, material, Vec3{0, 0, 1});
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

  // =========================================================================
  // Scenario G — per-rung progress forwarding (M7.0a): the driver forwards
  // (rung index, rung count, iteration) once per OC iteration of every rung,
  // and the callback has no effect on the outcome. A short ladder + a small
  // iteration cap keep this fast; accept-all gravity so both rungs run fully.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;  // accept-all (scenario A)
    o.volume_fraction_ladder = {0.7, 0.5};
    o.simp.max_iterations = 6;

    const MinimizePlasticResult base =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
    CHECK(!base.cancelled,
          "G: an un-cancelled run reports cancelled == false");

    struct Rec {
      std::size_t rung;
      std::size_t count;
      int iteration;
    };
    std::vector<Rec> recs;
    MinimizePlasticOptions ocb = o;
    ocb.progress = [&recs](std::size_t r, std::size_t n, int it) {
      recs.push_back({r, n, it});
    };
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, ocb);

    // The callback changed nothing observable.
    CHECK(topopt::job_report_json(r.report) ==
              topopt::job_report_json(base.report),
          "G: progress callback does not change the report");

    // Per-rung accounting: every record carries the ladder size as the count;
    // rung indices are non-decreasing 0..n-1; within each rung the iteration
    // numbers are 1..k strictly monotone with k = that rung's iterations.
    std::size_t total = 0;
    for (const MinimizePlasticVariant& ev : r.evaluated)
      total += static_cast<std::size_t>(ev.optimization.iterations);
    CHECK(recs.size() == total,
          "G: one invocation per OC iteration across the whole ladder");
    bool counts_ok = true, rungs_ok = true, iters_ok = true;
    std::size_t prev_rung = 0;
    int expect_it = 1;
    for (std::size_t i = 0; i < recs.size(); ++i) {
      if (recs[i].count != o.volume_fraction_ladder.size()) counts_ok = false;
      if (recs[i].rung >= o.volume_fraction_ladder.size()) rungs_ok = false;
      if (recs[i].rung < prev_rung) rungs_ok = false;
      if (recs[i].rung != prev_rung) expect_it = 1;  // new rung restarts at 1
      if (recs[i].iteration != expect_it) iters_ok = false;
      ++expect_it;
      prev_rung = recs[i].rung;
    }
    CHECK(counts_ok, "G: every record carries rung_count == ladder size");
    CHECK(rungs_ok, "G: rung indices are non-decreasing and in range");
    CHECK(iters_ok, "G: per-rung iteration numbers are 1..k monotone");
    // Both rungs actually reported (the forwarding is per rung, not just the
    // first one).
    bool saw0 = false, saw1 = false;
    for (const Rec& rec : recs) {
      if (rec.rung == 0) saw0 = true;
      if (rec.rung == 1) saw1 = true;
    }
    CHECK(saw0 && saw1, "G: progress reported for every evaluated rung");
  }

  // =========================================================================
  // Scenario H — cancellation (M7.0a): a cancel flag raised mid-run stops the
  // ladder; the cancelled rung is rejected, no later rung runs, and the
  // result (incl. the report of the accepted prefix) stays valid.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;  // accept-all, so only the cancel can reject
    o.volume_fraction_ladder = {0.7, 0.5, 0.3};
    o.simp.max_iterations = 6;

    // H1: cancel during rung 1 (the second rung), iteration 2.
    std::atomic<bool> stop{false};
    MinimizePlasticOptions oc = o;
    oc.cancel = &stop;
    oc.progress = [&stop](std::size_t r, std::size_t, int it) {
      if (r == 1 && it == 2) stop.store(true);
    };
    const MinimizePlasticResult rc =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, oc);
    CHECK(rc.cancelled, "H1: mid-run cancel sets result.cancelled");
    CHECK(!rc.stopped_on_margin, "H1: a cancel is not a margin stop");
    CHECK(rc.evaluated.size() == 2,
          "H1: no rung after the cancelled one is evaluated");
    CHECK(rc.evaluated[0].accepted,
          "H1: the rung completed before the cancel stays accepted");
    CHECK(!rc.evaluated[1].accepted,
          "H1: the cancelled rung is rejected (valid rejected result)");
    CHECK(rc.evaluated[1].optimization.cancelled &&
              rc.evaluated[1].optimization.iterations == 2,
          "H1: the cancelled rung stopped at the flagged iteration");
    CHECK(rc.report.variants.size() == 1,
          "H1: the report carries exactly the accepted prefix");
    // M7.0b carve-out: a cancelled rung ships NO visualization data (its
    // per-rung analysis is skipped), while the accepted prefix rung carries it.
    CHECK(rc.evaluated[1].von_mises_field.empty() &&
              rc.evaluated[1].support_volume_voxels == 0 &&
              rc.evaluated[1].mass_grams == 0.0 && rc.evaluated[1].mesh().empty(),
          "H1: the cancelled rung's visualization fields stay default");
    CHECK(!rc.evaluated[0].von_mises_field.empty() &&
              rc.evaluated[0].mass_grams > 0.0 && !rc.evaluated[0].mesh().empty(),
          "H1: the accepted prefix rung still carries visualization data");
    bool valid = true;
    try {
      topopt::validate_job_report_json(topopt::job_report_json(rc.report));
    } catch (const std::exception&) {
      valid = false;
    }
    CHECK(valid, "H1: the cancelled run's report still validates");

    // H2: cancel pre-set before the run: the first rung is cancelled at zero
    // iterations, rejected, and the report is empty but valid.
    std::atomic<bool> pre{true};
    MinimizePlasticOptions op = o;
    op.cancel = &pre;
    const MinimizePlasticResult rp =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, op);
    CHECK(rp.cancelled, "H2: pre-set cancel flag cancels the run");
    CHECK(rp.evaluated.size() == 1 && !rp.evaluated[0].accepted,
          "H2: exactly one (rejected) rung evaluated");
    CHECK(rp.evaluated[0].optimization.cancelled &&
              rp.evaluated[0].optimization.iterations == 0,
          "H2: the first rung was cancelled before any OC iteration");
    CHECK(rp.report.variants.empty(),
          "H2: nothing accepted => empty report");
    bool valid2 = true;
    try {
      topopt::validate_job_report_json(topopt::job_report_json(rp.report));
    } catch (const std::exception&) {
      valid2 = false;
    }
    CHECK(valid2, "H2: the empty cancelled report still validates");
  }

  // =========================================================================
  // Scenario I — M7.0b visualization data on a known solid cube. A 6x6x6 cube
  // run at volume fraction 1.0 keeps every voxel printed, giving a
  // hand-computable mass and a support-free build direction (a solid box resting
  // on the plate has no unsupported overhangs). Exercises the exact-value end of
  // the viz fields that check_viz_fields' recompute cannot pin on its own.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const int n = 6;
    const double h = 2.0;
    const VoxelGrid g = solid_cube(bcs, n, h);
    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;            // accept-all
    o.volume_fraction_ladder = {1.0};   // keep all material => fully printed
    o.simp.max_iterations = 20;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    CHECK(r.evaluated.size() == 1 && r.evaluated[0].accepted,
          "I: the vf=1.0 rung is evaluated and accepted");
    const MinimizePlasticVariant& ev = r.evaluated[0];

    // vf = 1.0 over an all-Active/Frozen grid forces every voxel to full density.
    std::size_t printed = 0;
    for (double d : ev.optimization.physical_density)
      if (d > 0.5) ++printed;
    CHECK(printed == g.solid_count(),
          "I: vf=1.0 prints every solid voxel of the cube");

    // (d) hand-computed mass: 216 voxels * 8 mm^3 = 1728 mm^3 = 1.728 cm^3,
    // * 1.24 g/cm^3 = 2.14272 g.
    const double want_mass = 1.24 * 216.0 * 8.0 / 1000.0;
    CHECK(std::fabs(ev.mass_grams - want_mass) <= 1e-9 * (1.0 + want_mass),
          "I: mass_grams matches the hand-computed cube mass (2.14272 g)");

    // (c) a fully solid cube built along +z has no unsupported overhangs.
    CHECK(ev.support_volume_voxels == 0,
          "I: a fully solid cube needs no support along its build axis");

    // (a,b) full recompute consistency (build_dir = +z here).
    check_viz_fields(r, g, material, Vec3{0, 0, 1});

    std::printf("[I known-cube] printed=%zu mass=%.6g g support=%d "
                "mesh_tris=%zu\n",
                printed, ev.mass_grams, ev.support_volume_voxels,
                ev.mesh().triangles.size());
  }

  if (g_failures == 0) {
    std::printf("minimize_plastic (M5.3): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "minimize_plastic (M5.3): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
