// Regression gate for the savings-ladder rung COLLAPSE (diagnosis
// 084-ladder-collapse-diagnosis). A comfortably-strong part must produce MULTIPLE savings
// rungs — the ladder walks toward the lightest safe rung, which is the variant the
// app recommends. Before the fix, the bridge set MinimizePlasticOptions::
// margin_floor_multiple = 2.0 on the loadcase path (BOTH no-box and box), which
// halted the walk at the first accepted rung clearing 2*margin_stop = 3.0. Because
// the ladder walks HEAVIEST -> lightest and margin peaks at rung 0, that fired at
// rung 0 for any strong part, collapsing the ladder to a single rung on both paths.
//
// Guards (each would FAIL against the pre-fix production behavior, reproduced here by
// explicitly re-enabling the floor):
//   (1) PRODUCTION no-box  -> >= 3 rungs (walks toward the lightest safe rung).
//   (2) PRODUCTION box     -> >= 3 rungs (same; the collapse was never box-specific).
//   (3) NON-VACUOUS: with the withdrawn floor re-enabled (margin_floor_multiple=2.0)
//       the SAME strong part collapses to strictly fewer rungs than production — so
//       this part genuinely sits in the regime the bug destroyed, and guards (1)/(2)
//       are meaningful, not trivially satisfied by a weak part that stops early on
//       margin anyway.
//
// Production options mirror the FIXED bridge: the 4-rung reduction ladder, margin_stop
// 1.5, MMA, the anchor pad — and margin_floor_multiple LEFT AT ITS +infinity default
// (the bridge no longer turns it on). Drives minimize_plastic (Eigen), so Eigen-gated
// in CMake like the sibling optimizer gates; the real settings rule table is injected.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

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

// The same thin L-bracket the 080/082 gates build.
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

// Production-shaped options, mirroring the FIXED bridge: 4-rung reduction ladder,
// margin_stop 1.5, MMA. margin_floor_multiple LEFT at its +infinity default (the
// bridge no longer sets it) => the ladder walks to the lightest safe rung.
MinimizePlasticOptions prod_options(const std::vector<NodalLoad>& loads) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
  o.margin_stop = 1.5;
  // o.margin_floor_multiple left at +infinity (disabled) — the fix.
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = topopt::SimpUpdater::MMA;
  o.infill_percent = 100.0;
  return o;
}

std::size_t rung_count(const VoxelGrid& part, const Material& material,
                       const std::vector<DirichletBC>& bcs,
                       const SettingsRules& rules,
                       const MinimizePlasticOptions& opts) {
  return topopt::minimize_plastic(part, material, "fdm", bcs, rules, opts)
      .evaluated.size();
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

  DesignBox box;
  box.min = Vec3{0.0, 0.0, 0.0};
  box.max = Vec3{16.0, 6.0, 16.0};

  // A LIGHT tip load: the part is comfortably strong, so the ladder should walk
  // several rungs before any drops below margin_stop. This is the regime the device
  // repro lived in (and where the withdrawn floor collapsed the ladder to one rung).
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -5.0});

  // (1) PRODUCTION no-box -> multiple rungs.
  const std::size_t no_box_rungs = rung_count(part, material, bcs, rules,
                                              prod_options(tip));
  CHECK(no_box_rungs >= 3,
        "(1): production no-box ladder walks >= 3 rungs (did not collapse)");

  // (2) PRODUCTION box -> multiple rungs (collapse was never box-specific).
  MinimizePlasticOptions box_opts = prod_options(tip);
  box_opts.design_box = box;
  const std::size_t box_rungs = rung_count(part, material, bcs, rules, box_opts);
  CHECK(box_rungs >= 3,
        "(2): production box ladder walks >= 3 rungs (did not collapse)");

  // (3) NON-VACUOUS: re-enabling the withdrawn floor collapses the SAME part to
  // strictly fewer rungs — proving the part sits in the regime the bug destroyed.
  MinimizePlasticOptions floored = prod_options(tip);
  floored.margin_floor_multiple = 2.0;  // the withdrawn kAnchorMarginFloorMultiple
  const std::size_t floored_no_box = rung_count(part, material, bcs, rules, floored);
  MinimizePlasticOptions floored_box = floored;
  floored_box.design_box = box;
  const std::size_t floored_box_rungs =
      rung_count(part, material, bcs, rules, floored_box);
  CHECK(floored_no_box < no_box_rungs,
        "(3): the withdrawn floor DID collapse the no-box ladder (regime is real)");
  CHECK(floored_box_rungs < box_rungs,
        "(3): the withdrawn floor DID collapse the box ladder (regime is real)");

  std::printf(
      "[ladder] production: no_box_rungs=%zu  box_rungs=%zu  |  "
      "floor-on: no_box=%zu  box=%zu\n",
      no_box_rungs, box_rungs, floored_no_box, floored_box_rungs);

  if (g_failures == 0) {
    std::printf("ladder_rung_count: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "ladder_rung_count: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
