// Handoff 080 regression gate — the design-box "whole-domain optimize" path
// (MinimizePlasticOptions::freeze_imported_part == false, the DEFAULT) must
// genuinely REDUCE plastic measured against the imported PART, not fill the box
// on top of a frozen part (the near-solid failure diagnosed in
// 080-designbox-nearsolid-diagnosis.md).
//
// Three assertions, one per named failure the fix addresses:
//   (a) REMOVAL — a design-box run on a part with obvious removable material
//       removes it: the achieved fraction (part-relative) is bounded well below 1,
//       and the printed mass is < the part's mass. This is the guard that the box
//       path can never silently return near-solid again.
//   (b) BASELINE — the implied baseline (mass_grams / achieved_volume_fraction, the
//       app's `savings = 1 - achieved` reference) equals the PART's mass, not the
//       filled expanded domain (which ballooned ~2-3.6x on device).
//   (c) LADDER — the box path evaluates the SAME number of ladder rungs as the
//       no-box path on an equivalent case (the ladder did not collapse to one rung).
//
// Drives minimize_plastic (Eigen), so it is Eigen-gated in CMake like the other
// optimizer gates; the real settings rule table is injected (SETTINGS_RULES_PATH).
// Same self-contained CHECK harness as the sibling validation tests, public API only.

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

// The same thin L-bracket the diagnosis used (and test_design_domain builds): a
// vertical arm mounted at the top, a horizontal foot loaded down at its free end.
// The concave notch + a snug bounding box is the design volume.
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
// ladder floor, MMA updater. Caller sets the load and (optionally) the box.
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
  return o;
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

  const int arm = 8, span = 8, ny = 3, t = 2;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const double part_mass = part_mass_grams(part, material);

  // A design box drawn SNUG around the part's bounding box (x,z in [0,16],
  // y in [0,6]) — "as small as possible", the device repro. Offsets are 0; the
  // Active add-region is the empty notch inside the bbox.
  DesignBox box;
  box.min = Vec3{0.0, 0.0, 0.0};
  box.max = Vec3{16.0, 6.0, 16.0};

  // A load in the regime where the no-box ladder walks >1 rung (so the collapse
  // guard in (c) is meaningful).
  const Vec3 tip_force{0.0, 0.0, -30.0};
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, tip_force);

  // --- Run: no box vs whole-domain box (freeze_imported_part == false default) --
  const MinimizePlasticResult no_box =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules,
                               prod_options(tip));
  MinimizePlasticOptions box_opts = prod_options(tip);
  box_opts.design_box = box;
  const MinimizePlasticResult with_box =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, box_opts);

  CHECK(!no_box.evaluated.empty(), "no-box produced at least one rung");
  CHECK(!with_box.evaluated.empty(), "box produced at least one rung");

  const auto& box0 = with_box.evaluated.front();
  const double achieved = box0.optimization.volume_fraction;  // part-relative now
  const double mass = box0.mass_grams;

  // (a) REMOVAL — the box run strips obvious material. The part-relative achieved
  // fraction is well below 1 (NOT near-solid), and the printed mass is below the
  // part's mass. The 0.9 bound is the hard guard against a silent near-solid return
  // (pre-fix this rung reported achieved ~1.88x the part / a near-solid box).
  CHECK(achieved < 0.9,
        "(a): box run removes material — achieved part-fraction < 0.9 (not near-solid)");
  CHECK(mass < part_mass,
        "(a): box run printed mass is below the imported part's mass");

  // (b) BASELINE — the implied baseline (mass / achieved) is the PART's mass, not
  // the filled expanded domain. Exact by construction; a loose tolerance absorbs
  // FP only.
  const double implied_baseline = mass / achieved;
  CHECK(std::fabs(implied_baseline - part_mass) <= 1e-6 * part_mass + 1e-12,
        "(b): box-path baseline (mass / achieved) equals the part's mass");

  // (c) LADDER — the box path walks the SAME number of rungs as the no-box path;
  // the ladder did not collapse to one rung.
  CHECK(with_box.evaluated.size() == no_box.evaluated.size(),
        "(c): box path evaluates the same rung count as the no-box path");

  std::printf(
      "[080] part_mass=%.6g g  no_box_rungs=%zu  box_rungs=%zu\n",
      part_mass, no_box.evaluated.size(), with_box.evaluated.size());
  std::printf(
      "[080] box rung0: achieved(part-rel)=%.4f  mass=%.6g g  "
      "implied_baseline=%.6g g  savings=%.1f%%\n",
      achieved, mass, implied_baseline, 100.0 * (1.0 - achieved));

  if (g_failures == 0) {
    std::printf("designbox_reduction (080): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "designbox_reduction (080): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
