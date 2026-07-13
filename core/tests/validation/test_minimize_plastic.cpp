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

// The SIMP params the driver derives from a material (minimize_plastic.cpp:
// E from the material, penalty p = 3, density_min default). Used to re-run the
// driver's final penalized solve in check_displacement_field.
topopt::SimpParams driver_params(const Material& m) {
  topopt::SimpParams p;
  p.youngs_modulus = m.youngs_modulus_mpa;
  p.poisson = m.poisson;
  p.penalty = 3.0;
  return p;
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

// Per-voxel Cauchy stress tensor field exposed on every evaluated NON-cancelled
// variant (the tensor sibling of von_mises_field that the app's load->anchor
// flux streamlines need). This is EXPOSURE, not recomputation: the tensor is the
// SAME one the trusted von_mises_field scalar is derived from, so the test
// re-derives von Mises FROM the tensor with the field's stated convention
// (Voigt [xx,yy,zz,xy,yz,zx], TRUE shear) and asserts it matches von_mises_field
// voxel by voxel within a tight tolerance. A stub of zeros or a mislabeled Voigt
// order fails this. Also pins the grid-indexed size (6*voxel_count) and the
// zero-off-printed gating.
void check_stress_tensor_field(const MinimizePlasticResult& r,
                               const VoxelGrid& g) {
  const double iso = 0.5;
  for (const MinimizePlasticVariant& ev : r.evaluated) {
    if (ev.optimization.cancelled) continue;  // carve-out checked in scenario H
    const std::vector<double>& rho = ev.optimization.physical_density;

    // Flattened grid-indexed: six Voigt components per voxel.
    CHECK(ev.stress_tensor_field.size() == 6 * g.voxel_count(),
          "stress-tensor: field is flattened grid-indexed (size 6*voxel_count)");
    // The scalar sibling it must agree with is itself grid-indexed.
    CHECK(ev.von_mises_field.size() == g.voxel_count(),
          "stress-tensor: von_mises_field is grid-indexed (size voxel_count)");
    if (ev.stress_tensor_field.size() != 6 * g.voxel_count() ||
        ev.von_mises_field.size() != g.voxel_count())
      continue;  // sizes wrong: the per-voxel checks below would index OOB

    bool vm_matches = true, zero_off_printed = true, any_printed_nonzero = false;
    for (std::size_t idx = 0; idx < rho.size(); ++idx) {
      const std::size_t base = 6 * idx;
      const double sxx = ev.stress_tensor_field[base + 0];
      const double syy = ev.stress_tensor_field[base + 1];
      const double szz = ev.stress_tensor_field[base + 2];
      const double sxy = ev.stress_tensor_field[base + 3];  // TRUE shear (tau)
      const double syz = ev.stress_tensor_field[base + 4];
      const double szx = ev.stress_tensor_field[base + 5];

      if (rho[idx] > iso) {
        // Derive von Mises from the tensor with the field's own convention and
        // compare to the trusted scalar computed in the same solve.
        const double vm_from_tensor = std::sqrt(
            0.5 * ((sxx - syy) * (sxx - syy) + (syy - szz) * (syy - szz) +
                   (szz - sxx) * (szz - sxx)) +
            3.0 * (sxy * sxy + syz * syz + szx * szx));
        const double vm_ref = ev.von_mises_field[idx];
        if (std::fabs(vm_from_tensor - vm_ref) > 1e-9 * (1.0 + std::fabs(vm_ref)))
          vm_matches = false;
        if (vm_from_tensor > 0.0) any_printed_nonzero = true;
      } else {
        // Off the printed set every component is zero, exactly like the scalar.
        if (sxx != 0.0 || syy != 0.0 || szz != 0.0 || sxy != 0.0 ||
            syz != 0.0 || szx != 0.0)
          zero_off_printed = false;
      }
    }
    CHECK(vm_matches,
          "stress-tensor: von Mises re-derived from the tensor matches "
          "von_mises_field voxel by voxel (same tensor, right Voigt order)");
    CHECK(zero_off_printed,
          "stress-tensor: every component is zero off the printed material");
    CHECK(any_printed_nonzero,
          "stress-tensor: at least one printed voxel carries nonzero stress");
  }
}

// M7.disp — the per-node displacement field exposed on every evaluated
// NON-cancelled variant (the sibling of von_mises_field that M7.viz.3's flex
// animation consumes). This is EXPOSURE, not recomputation: the field must equal
// the SAME penalized solve the driver runs on the converged density, so the test
// re-runs that identical solve (simp_compliance with the driver's params / bcs /
// loads / CG settings — deterministic, so bit-identical) and asserts equality
// element-for-element on printed nodes, zero on nodes attached only to
// non-printed voxels, and the right DOF-ordered size. `params`, `bcs`, `loads`
// and the CG settings MUST match what minimize_plastic used for the equality to
// be exact. Fails against a stub that leaves the field default (empty).
void check_displacement_field(const MinimizePlasticResult& r, const VoxelGrid& g,
                              const topopt::SimpParams& params,
                              const std::vector<DirichletBC>& bcs,
                              const std::vector<topopt::NodalLoad>& loads,
                              double cg_tol, int cg_maxit) {
  const double iso = 0.5;
  const int node_count = topopt::fea_node_count(g);
  for (const MinimizePlasticVariant& ev : r.evaluated) {
    if (ev.optimization.cancelled) continue;  // carve-out checked in scenario H
    const std::vector<double>& rho = ev.optimization.physical_density;

    // (1) DOF-ordered, per-node size.
    CHECK(ev.displacement_field.size() ==
              static_cast<std::size_t>(3 * node_count),
          "disp: displacement_field is per-node DOF-ordered (size 3*node_count)");

    // Nodes attached to at least one printed voxel (physical density > iso) —
    // the "printed set" the field is exposed over.
    std::vector<char> node_printed(static_cast<std::size_t>(node_count), 0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!g.solid(i, j, k)) continue;
          if (!(rho[g.index(i, j, k)] > iso)) continue;
          for (int n : topopt::fea_element_nodes(g, i, j, k))
            node_printed[static_cast<std::size_t>(n)] = 1;
        }

    // The SAME penalized solve the driver ran on this variant's density.
    const topopt::SimpCompliance sc =
        topopt::simp_compliance(g, params, rho, bcs, loads, cg_tol, cg_maxit);

    bool exposure_exact = true, zero_off_printed = true, any_printed_nonzero = false;
    for (int n = 0; n < node_count; ++n)
      for (int c = 0; c < 3; ++c) {
        const double got =
            ev.displacement_field[static_cast<std::size_t>(3 * n + c)];
        if (node_printed[static_cast<std::size_t>(n)]) {
          // Exposure, not an independent value: bit-equal to the solve.
          if (got != sc.solution.at(n, c)) exposure_exact = false;
          if (got != 0.0) any_printed_nonzero = true;
        } else if (got != 0.0) {
          zero_off_printed = false;
        }
      }
    CHECK(exposure_exact,
          "disp: printed-node displacement equals the penalized solve exactly");
    CHECK(zero_off_printed,
          "disp: displacement is zero on nodes attached only to non-printed voxels");
    CHECK(any_printed_nonzero,
          "disp: loaded/printed nodes carry nonzero displacement");
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
    // Stress-tensor field: the exposed per-voxel Cauchy tensor is the REAL tensor
    // von_mises_field came from — von Mises re-derived from it matches voxel by
    // voxel, and it is sized/gated like the scalar.
    check_stress_tensor_field(r, g);
    // M7.disp: the per-node displacement field equals the driver's final
    // penalized solve exactly (self-weight loads at this scenario's gravity).
    check_displacement_field(
        r, g, driver_params(material),
        bcs, topopt::self_weight_loads(g, material.density_g_cm3, o.gravity,
                                       o.gravity_direction),
        o.simp.cg_tolerance, o.simp.cg_max_iterations);
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
    // M7.0b/M7.disp carve-out: a cancelled rung ships NO visualization data (its
    // per-rung analysis is skipped), while the accepted prefix rung carries it.
    CHECK(rc.evaluated[1].von_mises_field.empty() &&
              rc.evaluated[1].stress_tensor_field.empty() &&
              rc.evaluated[1].displacement_field.empty() &&
              rc.evaluated[1].support_volume_voxels == 0 &&
              rc.evaluated[1].mass_grams == 0.0 && rc.evaluated[1].mesh().empty(),
          "H1: the cancelled rung's visualization fields stay default");
    CHECK(!rc.evaluated[0].von_mises_field.empty() &&
              rc.evaluated[0].stress_tensor_field.size() ==
                  6 * rc.evaluated[0].von_mises_field.size() &&
              !rc.evaluated[0].displacement_field.empty() &&
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
    // Stress-tensor field on the fully-printed cube: von Mises re-derived from the
    // exposed tensor matches the scalar field everywhere.
    check_stress_tensor_field(r, g);
    // M7.disp: on a fully-printed cube every node is in the printed set, so the
    // field is the solve's displacement everywhere (nonzero away from the clamp).
    check_displacement_field(
        r, g, driver_params(material),
        bcs, topopt::self_weight_loads(g, material.density_g_cm3, o.gravity,
                                       o.gravity_direction),
        o.simp.cg_tolerance, o.simp.cg_max_iterations);

    std::printf("[I known-cube] printed=%zu mass=%.6g g support=%d "
                "mesh_tris=%zu\n",
                printed, ev.mass_grams, ev.support_volume_voxels,
                ev.mesh().triangles.size());
  }

  // =========================================================================
  // Scenario J — external load case (ARCHITECTURE §1 mode (a)): a user tip load
  // REPLACES self-weight as the design load, so the reported margins/stresses
  // reflect that force, not the part's own weight. This is the path the app's
  // declared anchors/loads drive (M7.6 load case -> traction_loads ->
  // options.external_loads). Without this, the optimize ignored the user's forces.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    VoxelGrid g = cantilever_bracket(bcs);
    // Tag the free tip face (i == nx-1) Load and hang a downward force on it.
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j) g.set_tag(g.nx - 1, j, k, VoxelTag::Load);
    const Vec3 tip_force{0.0, 0.0, -2e-4};
    const std::vector<topopt::NodalLoad> tip =
        topopt::traction_loads(g, VoxelTag::Load, tip_force);

    // The assembled nodal loads sum EXACTLY to the applied force (consistent +
    // distributed, never lumped): the load the solver sees IS the user's force.
    double sx = 0, sy = 0, sz = 0;
    for (const topopt::NodalLoad& nl : tip) {
      if (nl.component == 0) sx += nl.value;
      else if (nl.component == 1) sy += nl.value;
      else sz += nl.value;
    }
    CHECK(std::fabs(sx - tip_force.x) < 1e-12 && std::fabs(sy - tip_force.y) < 1e-12 &&
              std::fabs(sz - tip_force.z) < 1e-9 * (1.0 + std::fabs(tip_force.z)),
          "J: tip traction nodal loads sum to the applied force");

    MinimizePlasticOptions o = base_options();
    o.gravity = 0.0;       // unused under external loads: must NOT throw
    o.margin_stop = 0.0;   // accept the whole ladder (isolate the load path)
    o.external_loads = tip;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    CHECK(!r.evaluated.empty() &&
              r.report.variants.size() == o.volume_fraction_ladder.size(),
          "J: external-load run evaluates + accepts the ladder");
    check_stop_invariant(r, o.margin_stop, "J");
    check_v3_on_accepted(r);
    for (const MinimizePlasticVariant& ev : r.evaluated) {
      CHECK(std::isfinite(ev.report.max_stress_mpa) &&
                ev.report.max_stress_mpa > 0.0,
            "J: the tip load produces a real (finite, positive) stress field");
      CHECK(std::isfinite(ev.report.margin.worst_case) &&
                ev.report.margin.worst_case > 0.0,
            "J: a finite positive margin under the external load");
    }

    // The load case actually MATTERS: the same part under self-weight gives a
    // different peak stress than under the tip load (proves the load drives it).
    MinimizePlasticOptions sw = base_options();
    sw.gravity = 1.0;      // self-weight (external_loads empty)
    const MinimizePlasticResult rsw =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, sw);
    CHECK(std::fabs(r.evaluated[0].report.max_stress_mpa -
                    rsw.evaluated[0].report.max_stress_mpa) > 1e-9,
          "J: the external tip load yields a different stress field than self-weight");

    // The gravity relaxation is external-load-only: self-weight with gravity 0
    // still throws (a zero body force is degenerate).
    bool threw = false;
    try {
      MinimizePlasticOptions bad = base_options();
      bad.gravity = 0.0;   // external_loads empty => invalid
      topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, bad);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "J: self-weight (no external loads) still requires gravity > 0");

    std::printf("[J external-load] variants=%zu maxsigma=%.6g (self-weight %.6g)\n",
                r.report.variants.size(), r.evaluated[0].report.max_stress_mpa,
                rsw.evaluated[0].report.max_stress_mpa);
  }

  // =========================================================================
  // Scenario K — progressive results: on_variant streams each ACCEPTED rung as
  // it completes (before the next lighter rung), so the app can show the first
  // optimized variant while the rest are still running.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;   // accept-all: the whole ladder is streamed
    std::vector<double> streamed_vfs;
    o.on_variant = [&](const MinimizePlasticVariant& v) {
      CHECK(v.accepted, "K: only accepted variants are streamed");
      // The variant is fully analysed when streamed (report + viz fields ready).
      CHECK(std::isfinite(v.report.margin.worst_case),
            "K: a streamed variant carries a computed margin");
      CHECK(!v.mesh().vertices.empty(),
            "K: a streamed variant carries its extracted mesh");
      streamed_vfs.push_back(v.optimization.volume_fraction);
    };
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    CHECK(streamed_vfs.size() == r.report.variants.size(),
          "K: on_variant fires once per accepted variant");
    CHECK(streamed_vfs.size() == o.volume_fraction_ladder.size(),
          "K: accept-all streams the whole ladder");
    for (std::size_t i = 1; i < streamed_vfs.size(); ++i)
      CHECK(streamed_vfs[i] < streamed_vfs[i - 1],
            "K: variants stream heaviest-first (ladder order)");
    std::printf("[K progressive] streamed %zu variants\n", streamed_vfs.size());
  }

  // =========================================================================
  // Scenario L — playback keyframes: capturing the optimization history so the
  // app can play back the shape being carved out. Off by default; when
  // keyframe_count > 0 each accepted variant carries ~that many isosurface
  // snapshots, ending at the converged shape.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);

    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;   // accept-all: keyframes captured for every rung
    o.keyframe_count = 6;
    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
    CHECK(!r.evaluated.empty(), "L: keyframe run evaluates");
    for (const MinimizePlasticVariant& ev : r.evaluated) {
      if (!ev.accepted) continue;
      CHECK(ev.keyframe_meshes.size() >= 2,
            "L: each variant captured >= 2 history keyframes");
      CHECK(ev.keyframe_meshes.size() <=
                static_cast<std::size_t>(o.keyframe_count) + 2,
            "L: ~keyframe_count frames (+ first + final)");
      // The final keyframe is the converged shape — non-empty. (Early frames of a
      // low-volume rung can be empty: uniform density below the iso, material not
      // yet formed — that's the point of the playback.)
      const topopt::TriangleMesh& last = ev.keyframe_meshes.back();
      CHECK(!last.vertices.empty() && last.triangle_count() > 0,
            "L: the final keyframe is the converged (non-empty) shape");
    }

    // Off by default: no keyframes, no cost.
    MinimizePlasticOptions off = base_options();
    off.gravity = cal_gravity;
    const MinimizePlasticResult r0 =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, off);
    for (const MinimizePlasticVariant& ev : r0.evaluated)
      CHECK(ev.keyframe_meshes.empty(), "L: keyframes are off by default");

    std::printf("[L keyframes] variant0 frames=%zu\n",
                r.evaluated[0].keyframe_meshes.size());
  }

  // =========================================================================
  // Scenario M — M7.infill-margin: an infill-derived KNOCKDOWN on the ladder
  // ACCEPTANCE-gate margin. The FEA / stress field / stored margin are unchanged
  // (infill NEVER enters the solver, ARCHITECTURE §2); only what the acceptance
  // test compares against shrinks, so a lower infill stops the ladder EARLIER
  // (retains more material / accepts a heavier terminal rung) than the solid
  // part. Back-compat: unset / 100% infill reproduces the current ladder exactly.
  //
  // Gravity is placed (from scenario A's calibrated per-rung margins, which scale
  // as 1/gravity) so the SOLID part comfortably accepts the WHOLE ladder — the
  // "raw margin is large" over-stripping case the knockdown is meant to curb.
  // The weakest (last) rung's solid margin is set to 4x the 1.5 threshold.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    const double g_infill = cal_gravity * cal_margins.back() / (1.5 * 4.0);

    auto run_infill = [&](double infill_percent) {
      MinimizePlasticOptions o = base_options();
      o.gravity = g_infill;
      o.infill_percent = infill_percent;
      return topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
    };

    // The default (infill unset) run and an explicit 100% run must be
    // byte-identical, and both accept the whole ladder with no margin stop: the
    // knockdown is exactly 1.0 (a no-op), so the gate matches the pre-M7 driver.
    MinimizePlasticOptions o_unset = base_options();
    o_unset.gravity = g_infill;  // infill_percent left at its 100.0 default
    const MinimizePlasticResult solid =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o_unset);
    const MinimizePlasticResult solid100 = run_infill(100.0);
    CHECK(topopt::job_report_json(solid.report) ==
              topopt::job_report_json(solid100.report),
          "M: unset infill == explicit 100% infill (byte-identical report)");
    CHECK(!solid.stopped_on_margin &&
              solid.report.variants.size() ==
                  o_unset.volume_fraction_ladder.size(),
          "M: the solid part accepts the whole ladder (large raw margin)");

    // A LOW infill knocks the accepted margin down, stopping the ladder EARLIER:
    // strictly fewer accepted rungs (more material retained, heavier terminal).
    const MinimizePlasticResult low = run_infill(30.0);
    CHECK(low.report.variants.size() < solid.report.variants.size(),
          "M: low infill accepts strictly fewer rungs than solid (less stripping)");
    CHECK(low.stopped_on_margin,
          "M: the knockdown makes the ladder stop on margin (over-stripping curbed)");

    // Monotone: a lower infill never accepts MORE rungs than a higher one (the
    // knockdown factor is monotone in infill and the per-rung solid margins are
    // fixed). And every rung the knockdown DID accept still clears the RAW solid
    // margin (accept => margin*knockdown >= stop, knockdown <= 1 => margin >=
    // stop): the gate only ever rejects more, never accepts something the solid
    // gate would have rejected.
    const double sweep[] = {100.0, 70.0, 50.0, 30.0, 10.0};
    std::size_t prev_accepted = solid.report.variants.size();
    for (double pct : sweep) {
      const MinimizePlasticResult r = run_infill(pct);
      CHECK(r.report.variants.size() <= prev_accepted,
            "M: accepted-rung count is non-increasing as infill drops");
      prev_accepted = r.report.variants.size();
      for (const MinimizePlasticVariant& ev : r.evaluated)
        if (ev.accepted)
          CHECK(ev.report.margin.worst_case >= o_unset.margin_stop,
                "M: an accepted rung still clears the raw solid margin");
    }

    // The knockdown touches ONLY the accept/reject decision — NOT the stored
    // margin, stress, or optimized geometry. For every rung the low-infill run
    // retained, its report line is identical to the solid run's (same FEA, same
    // deterministic optimization; infill never entered the solver).
    for (std::size_t v = 0; v < low.report.variants.size(); ++v) {
      const topopt::VariantReport& a = solid.report.variants[v];
      const topopt::VariantReport& b = low.report.variants[v];
      CHECK(a.margin.worst_case == b.margin.worst_case &&
                a.volume_fraction == b.volume_fraction &&
                a.max_stress_mpa == b.max_stress_mpa,
            "M: a retained rung's stored margin/stress/vf are unchanged by infill");
    }

    std::printf("[M infill-margin] solid_accepted=%zu low(30%%)_accepted=%zu "
                "stopped=%d\n",
                solid.report.variants.size(), low.report.variants.size(),
                static_cast<int>(low.stopped_on_margin));
  }

  // =========================================================================
  // Scenario N — streaming stability under a LONG ladder (regression for the
  // read-after-realloc defect). The progressive-results callback hands its
  // consumer (the bridge's to_optimize_variant) a reference to a variant that
  // lives INSIDE result.evaluated. Every streamed variant's keyframe meshes and
  // displacement field must stay VALID and COMPLETE for the whole run, even as
  // result.evaluated grows across many rungs.
  //
  // Root cause of the fixed bug: result.evaluated was NOT reserved, so a later
  // rung's push_back that grew it past capacity reallocated and freed the block
  // an already-streamed reference pointed into (ASan heap-buffer-overflow,
  // read-after-realloc) — surfacing downstream as empty keyframeMeshes
  // (playback) / empty displacementField (flex). No other scenario caught it
  // because their ladders are only 1–5 rungs, never enough to force a
  // reallocation of result.evaluated.
  //
  // This scenario accept-alls a 16-rung ladder so result.evaluated would (unfixed)
  // reallocate several times mid-stream, and — crucially — on each callback it
  // ALSO re-reads the PREVIOUS streamed variant's keyframe meshes + displacement
  // field. Under the unfixed driver that earlier reference dangles after a
  // reallocation (ASan fires here); under the reserve()'d driver the whole
  // result.evaluated block is stable for the run and the reads stay valid. Small
  // grid + few iters keep it CI-fast: the trigger is VARIANT COUNT, not
  // resolution. Run under ASan to catch a regression as a hard failure rather
  // than a silent empty array.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    const int node_count = topopt::fea_node_count(g);
    const std::size_t disp_len = static_cast<std::size_t>(3 * node_count);

    MinimizePlasticOptions o = base_options();
    o.gravity = cal_gravity;   // accept-all: every rung is accepted and streamed
    o.keyframe_count = 4;
    o.simp.max_iterations = 20;  // keep the long ladder CI-fast
    // A long, strictly-descending, accept-all ladder — enough rungs that, without
    // the reserve() fix, result.evaluated would reallocate several times.
    o.volume_fraction_ladder.clear();
    for (int i = 0; i < 16; ++i)
      o.volume_fraction_ladder.push_back(0.90 - 0.04 * i);  // 0.90 .. 0.30

    // Validate one streamed variant's viz data: keyframes present + internally
    // consistent (triangle indices in range, final frame = converged non-empty
    // shape) and displacement field DOF-ordered, finite, carrying real flex.
    auto check_streamed = [&](const MinimizePlasticVariant& v) {
      CHECK(v.keyframe_meshes.size() >= 2,
            "N: a streamed variant carries its history keyframes");
      bool indices_ok = true;
      for (const topopt::TriangleMesh& km : v.keyframe_meshes)
        for (const auto& t : km.triangles)
          if (static_cast<std::size_t>(t[0]) >= km.vertices.size() ||
              static_cast<std::size_t>(t[1]) >= km.vertices.size() ||
              static_cast<std::size_t>(t[2]) >= km.vertices.size())
            indices_ok = false;
      CHECK(indices_ok, "N: streamed keyframe triangle indices are in range");
      const topopt::TriangleMesh& last = v.keyframe_meshes.back();
      CHECK(!last.vertices.empty() && last.triangle_count() > 0,
            "N: the final streamed keyframe is the non-empty converged shape");
      CHECK(v.displacement_field.size() == disp_len,
            "N: streamed displacement_field is per-node DOF-ordered");
      bool any_nonzero = false, all_finite = true;
      for (double d : v.displacement_field) {
        if (!std::isfinite(d)) all_finite = false;
        if (d != 0.0) any_nonzero = true;
      }
      CHECK(all_finite, "N: streamed displacement_field is finite");
      CHECK(any_nonzero, "N: streamed displacement_field carries nonzero flex");
    };

    std::size_t streamed = 0;
    // The previous callback's streamed variant. It points INTO result.evaluated;
    // re-reading it here (after the driver may have pushed another rung) is the
    // read-after-realloc probe — valid only because the fixed driver reserves.
    const MinimizePlasticVariant* prev = nullptr;
    o.on_variant = [&](const MinimizePlasticVariant& v) {
      ++streamed;
      check_streamed(v);
      if (prev != nullptr) check_streamed(*prev);
      prev = &v;  // stable across callbacks iff result.evaluated never reallocates
    };

    const MinimizePlasticResult r =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);

    CHECK(streamed == r.evaluated.size(),
          "N: on_variant fires once per accepted (evaluated) variant");
    CHECK(r.evaluated.size() == o.volume_fraction_ladder.size(),
          "N: accept-all evaluates the whole long ladder");
    // Well past std::vector's initial capacity: without the reserve() fix this
    // many pushes forces one or more reallocations while streaming.
    CHECK(r.evaluated.size() >= 8,
          "N: the ladder is long enough to have forced a reallocation unreserved");
    // The whole streamed history is still readable after the run (the reserved
    // block never moved) — final belt-and-suspenders on reference stability.
    for (const MinimizePlasticVariant& ev : r.evaluated)
      if (ev.accepted) check_streamed(ev);
    std::printf("[N realloc-stream] streamed %zu variants across a %zu-rung ladder\n",
                streamed, o.volume_fraction_ladder.size());
  }

  // =========================================================================
  // Scenario O — the MMA switchover (M7.mma.4): MMA is the production driver's
  // DEFAULT updater, and it produces valid designs that match or BEAT the OC
  // ladder at the same volume fractions. A tiny gravity (accept-all, scenario A)
  // runs the whole ladder so every rung is compared.
  // =========================================================================
  {
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);

    // The default really is MMA — the switchover, asserted on the option struct.
    CHECK(base_options().updater == topopt::SimpUpdater::MMA,
          "O: minimize_plastic defaults to the MMA updater (the switchover)");

    MinimizePlasticOptions omma = base_options();
    omma.gravity = cal_gravity;  // accept-all: run every rung
    MinimizePlasticOptions ooc = omma;
    ooc.updater = topopt::SimpUpdater::OC;  // retained fall-back

    const MinimizePlasticResult rmma =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, omma);
    const MinimizePlasticResult roc =
        topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, ooc);

    CHECK(rmma.evaluated.size() == omma.volume_fraction_ladder.size(),
          "O: MMA accept-all evaluates the whole ladder");
    CHECK(roc.evaluated.size() == rmma.evaluated.size(),
          "O: OC and MMA walk the same number of rungs");
    // Both updaters are valid designs (V3 gates, volume constraint) and the MMA
    // switchover does not regress the ladder: MMA compliance <= OC * (1 + tol)
    // at each rung's matched volume fraction (MMA should match or beat OC).
    check_v3_on_accepted(rmma);
    const double kTol = 0.02;  // MMA within 2% of the OC compliance (matches or beats)
    for (std::size_t v = 0;
         v < rmma.evaluated.size() && v < roc.evaluated.size(); ++v) {
      const MinimizePlasticVariant& em = rmma.evaluated[v];
      const MinimizePlasticVariant& eo = roc.evaluated[v];
      CHECK(std::fabs(em.optimization.volume_fraction -
                      eo.optimization.volume_fraction) <= 1e-2,
            "O: OC and MMA hit the same achieved volume fraction per rung");
      const double rel =
          std::fabs(em.optimization.compliance - eo.optimization.compliance) /
          std::fabs(eo.optimization.compliance);
      CHECK(em.optimization.compliance <= eo.optimization.compliance * (1.0 + kTol),
            "O: MMA compliance matches or beats OC at the same volume fraction");
      std::printf(
          "[O switchover] rung %zu vf=%.3f  OC c=%.6e it=%d | MMA c=%.6e it=%d "
          "| rel=%+.3f%%\n",
          v, em.requested_volume_fraction, eo.optimization.compliance,
          eo.optimization.iterations, em.optimization.compliance,
          em.optimization.iterations, 100.0 * rel);
    }
  }

  if (g_failures == 0) {
    std::printf("minimize_plastic (M5.3): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "minimize_plastic (M5.3): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
