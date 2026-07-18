// Handoff 094 regression gate — the SAVINGS % REPORTING BASIS.
//
// The app shows `savings = 1 - achieved_volume_fraction`
// (ResultsModel.swift). For that number to describe the printed object rather
// than a ladder target, `achieved` must be the PART-RELATIVE printed fraction
//   printed_voxels / part_solid        (printed_voxels = #{ρ > 0.5})
// the SAME voxel count the reported mass is built from
// (mass = density · printed_voxels · voxel_volume / 1000). Then the % and the
// mass are two views of one number and cannot disagree.
//
// Handoff 080 already made `achieved` part-relative on the DESIGN-BOX path.
// Handoff 094 extends it to the NO-BOX path — the branch 080 did not cover, and
// the one the production ladder runs. Before 094 the no-box path shipped the
// optimizer's CONTINUOUS active fraction Σρ/n_active, which the volume
// constraint drives to the ladder TARGET, so the displayed savings was
// `1 - vf_target` while the mass counted `#{ρ>0.5}`. On the grayscale MMA field
// (MMA runs without Heaviside projection, so the physical density is a ramp ~1
// filter-radius wide) the two disagree, and the gap grows with finer features
// (093-savings-floor-diagnosis.md).
//
// The gate asserts, on a deliberately GRAYSCALE field (min_feature_mm set so the
// density filter spans > 1 voxel → members never reach ρ=1 at their core):
//   (gray)   #{ρ>0.5} strictly exceeds Σρ — the count over-reads the continuous
//            sum, i.e. we are in the regime where the two bases diverge. Without
//            this the fixture could be crisp and the gate would not bite.
//   (no-box) the printed/count basis == printed_voxels / part_solid, and
//            equivalently mass / printed == the part's mass. This is what 094 fixes.
//   (box)    the same identity still holds on the 080 design-box path (no
//            regression).
//
// Handoff 104 update: the savings/count basis is now the dedicated `printed_fraction`
// report field (this gate reads v.report.printed_fraction), because 104 reverted
// optimization.volume_fraction to the optimizer's CONTINUOUS achieved fraction on
// the no-box path (the number the cli_demo invariant tests — see 102). The COUNT
// basis 094 established is unchanged in value; only the field it lives in moved.
//
// Drives minimize_plastic (Eigen), so it is Eigen-gated in CMake like the other
// optimizer gates; the real settings rule table is injected (SETTINGS_RULES_PATH).
// Same self-contained CHECK harness as test_designbox_reduction, public API only.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

using topopt::DesignBox;
using topopt::DirichletBC;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::NodalLoad;
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

// The same thin L-bracket test_designbox_reduction / test_design_domain build: a
// vertical arm mounted at the top, a horizontal foot loaded down at its free end.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = topopt::fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

double part_mass_grams(const VoxelGrid& part, const Material& m) {
  return m.density_g_cm3 * static_cast<double>(part.solid_count()) *
         part.voxel_volume() / 1000.0;
}

// Production-shaped options (bridge.cpp): the 4-rung reduction ladder, the anchor
// ladder floor, MMA updater — plus the physical min-feature filter, which is what
// makes the field grayscale (the filter radius floors at 1.5 voxels, so members
// thinner than the filter never reach ρ=1 at their core).
MinimizePlasticOptions prod_options(const std::vector<NodalLoad>& loads) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
  o.margin_stop = 1.5;
  o.margin_floor_multiple = 2.0;   // kAnchorMarginFloorMultiple
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = topopt::SimpUpdater::MMA;
  o.infill_percent = 100.0;
  o.min_feature_mm = 2.5;          // production min-feature → grayscale ramp
  return o;
}

// Recompute the printed voxel count (#{ρ>0.5} over solid voxels) and the
// continuous density sum Σρ from the variant's physical density on `grid`,
// exactly as minimize_plastic counts them (kIso = 0.5, solid voxels only).
struct FieldMeasures {
  std::size_t printed = 0;  // #{ρ > 0.5}, the mass / part-relative basis
  double sum_rho = 0.0;     // Σρ over solid voxels, the continuous basis
};
FieldMeasures measure_field(const VoxelGrid& grid,
                            const MinimizePlasticVariant& v) {
  FieldMeasures fm;
  const std::vector<double>& rho = v.optimization.physical_density;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const double r = rho[grid.index(i, j, k)];
        fm.sum_rho += r;
        if (r > 0.5) ++fm.printed;
      }
  return fm;
}

// NO-BOX gate: the field is indexed to the PART grid (G == grid), so the printed
// count can be recomputed directly. Assert the field is grayscale (the bases
// diverge here), the reported achieved == printed_voxels/part_solid, and
// equivalently mass/achieved == the part's mass — the % and the voxel-count mass
// share one basis. This is what 094 fixes; it FAILS against pre-094 core, which
// reported the optimizer's continuous Σρ/n_active (the ladder target).
void check_no_box(const VoxelGrid& part, double part_mass,
                  const MinimizePlasticVariant& v) {
  const FieldMeasures fm = measure_field(part, v);
  const double part_solid = static_cast<double>(part.solid_count());
  const double expected = static_cast<double>(fm.printed) / part_solid;
  // Handoff 104: the savings/mass basis is now the dedicated `printed_fraction`
  // field (#{ρ>0.5}/part_solid), NOT `optimization.volume_fraction` — which on the
  // no-box path reverted to the optimizer's CONTINUOUS achieved fraction (102).
  // Reading printed_fraction keeps this 094 gate testing the same count basis.
  const double reported = v.report.printed_fraction;

  // (gray) the whole-voxel count strictly exceeds the continuous sum by a clear
  // margin, so a Σρ-based basis and a #{ρ>0.5}-based basis DO diverge here.
  CHECK(static_cast<double>(fm.printed) > fm.sum_rho + 0.02 * part_solid,
        "(gray): #{ρ>0.5} strictly exceeds Σρ — grayscale field, bases diverge");

  // (basis) reported achieved == printed_voxels / part_solid.
  CHECK(std::fabs(reported - expected) <= 1e-9 * expected + 1e-12,
        "(no-box): reported achieved == printed_voxels / part_solid");

  // (mass) equivalently, mass / achieved resolves to the PART's mass.
  const double implied_baseline = v.mass_grams / reported;
  CHECK(std::fabs(implied_baseline - part_mass) <= 1e-6 * part_mass + 1e-12,
        "(no-box): mass / achieved == the part's mass (one shared basis)");

  // (104 split) the OPTIMIZER-ACHIEVED fraction (volume_fraction) is a SEPARATE,
  // continuous basis: it equals simp's own value verbatim (handoff 094's no-box
  // overwrite to the count basis is reverted) and, on this grayscale field, differs
  // from the printed/count basis by a clear margin. If a future change re-clobbered
  // volume_fraction with the count, this would fail — the two labeled fields must
  // stay distinct (handoff 104, resolving 102).
  CHECK(v.report.volume_fraction == v.optimization.volume_fraction,
        "(104): report.volume_fraction is simp's continuous achieved fraction, not overwritten");
  CHECK(std::fabs(v.report.volume_fraction - v.report.printed_fraction) > 1e-3,
        "(104): optimizer-achieved fraction is distinct from the printed count basis");

  std::printf(
      "[094] no-box printed=%zu sum_rho=%.2f part_solid=%.0f  achieved=%.4f "
      "expected=%.4f  mass=%.5g g  implied_baseline=%.5g g  savings=%.1f%%\n",
      fm.printed, fm.sum_rho, part_solid, reported, expected, v.mass_grams,
      implied_baseline, 100.0 * (1.0 - reported));
}

// DESIGN-BOX gate (080, no regression): on the box path the field is indexed to
// the EXPANDED domain grid, so the printed count is not recomputed here. The
// grid-agnostic identity mass/achieved == part_mass still holds (the reported
// achieved is printed_voxels/part_solid), and achieved is bounded below 1 (a
// part-relative fraction, not the ballooned Active-envelope fraction). Same
// invariant test_designbox_reduction locks; asserted here so 094's shared gate
// covers BOTH paths (guard a).
void check_box(double part_mass, const MinimizePlasticVariant& v) {
  // Handoff 104: read the printed/count basis (see check_no_box). On the box path
  // optimization.volume_fraction still equals printed_fraction (080's overwrite),
  // but printed_fraction is the canonical savings basis, so read it here too.
  const double reported = v.report.printed_fraction;
  const double implied_baseline = v.mass_grams / reported;
  CHECK(std::fabs(implied_baseline - part_mass) <= 1e-6 * part_mass + 1e-12,
        "(box): mass / achieved == the part's mass (080 part-relative, one basis)");
  CHECK(reported < 1.0,
        "(box): achieved is a part-relative fraction (< 1, not the envelope)");
  std::printf(
      "[094] box    achieved=%.4f  mass=%.5g g  implied_baseline=%.5g g  "
      "savings=%.1f%%\n",
      reported, v.mass_grams, implied_baseline, 100.0 * (1.0 - reported));
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

  // A grid + spacing where the production min-feature filter (2.5 mm → rmin =
  // max(2.5/h, 1.5) voxels) is wider than the bracket's members, so the printed
  // field is grayscale: h = 1.0 mm → rmin = 2.5 voxels, members t = 2 voxels are
  // gray through their whole thickness. Small enough to solve in a few seconds.
  const int arm = 10, span = 10, ny = 3, t = 2;
  const double h = 1.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const double part_mass = part_mass_grams(part, material);

  const Vec3 tip_force{0.0, 0.0, -30.0};
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, tip_force);

  // --- NO-BOX path (094: the branch 080 did not cover) ----------------------
  const MinimizePlasticResult no_box =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules,
                               prod_options(tip));
  CHECK(!no_box.evaluated.empty(), "no-box produced at least one rung");
  if (!no_box.evaluated.empty())
    check_no_box(part, part_mass, no_box.evaluated.front());

  // --- DESIGN-BOX path (080: must stay part-relative — no regression) --------
  DesignBox box;
  box.min = Vec3{0.0, 0.0, 0.0};
  box.max = Vec3{static_cast<double>(span) * h, static_cast<double>(ny) * h,
                 static_cast<double>(arm) * h};
  MinimizePlasticOptions box_opts = prod_options(tip);
  box_opts.design_box = box;
  const MinimizePlasticResult with_box =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, box_opts);
  CHECK(!with_box.evaluated.empty(), "box produced at least one rung");
  if (!with_box.evaluated.empty())
    check_box(part_mass, with_box.evaluated.front());

  if (g_failures == 0) {
    std::printf("savings_part_relative (094): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "savings_part_relative (094): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
