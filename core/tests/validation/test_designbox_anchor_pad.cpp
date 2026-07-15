// Handoff 082 regression gate — anchor integrity on the DESIGN-BOX path.
//
// Handoff 080 ("whole-domain optimize", MinimizePlasticOptions::freeze_imported_part
// == false, the DEFAULT box path) made the imported part an Active/REMOVABLE region:
// only the 1-voxel Load/Fixture BC skin stays pinned, so the optimizer can carve the
// material behind an anchor thin (the boss the no-box path protects with the N-voxel
// FrozenSolid pad of diagnosis 064). Before this gate the bridge SKIPPED that pad
// under a design box and the driver REJECTED a design_mask alongside a design_box, so
// there was no way to protect the boss on the box path.
//
// The fix: minimize_plastic now MERGES a caller anchor pad (a FrozenSolid design_mask
// on the PART grid) into the expanded design domain, remapping it by the same
// whole-voxel offset the BCs/loads use. This gate proves it.
//
// Guards (each FAILS on the pre-082 driver):
//   (a) THE PAD PROTECTS — every pad voxel, remapped into the expanded grid, is
//       retained solid (density >= 0.9) after a whole-domain box optimize. On the
//       pre-082 driver this run cannot even execute: design_box + design_mask threw
//       unconditionally, so the CHECK below could never be reached.
//   (b) REMAP AT A NONZERO OFFSET — the box is drawn so the part sits at a strictly
//       positive whole-voxel offset inside the expanded grid, and the pad is checked
//       at the offset-remapped indices (mirrors test_designbox_padding's nonzero
//       offset approach). A zero/wrong offset in the merge would land the check on
//       unpinned Active voxels and fail.
//   (c) STILL REDUCES — with the pad merged the box path still REMOVES material
//       (printed mass < part mass); the pad must not re-freeze so much that the run
//       returns near-solid. Reports savings % with vs without the pad.
//   (d) THE ADD-MATERIAL CONTRACT SURVIVES — design_box + design_mask still THROWS
//       when freeze_imported_part == true (that path builds its own mask; the pad is
//       only merged on the removable-part path).
//
// Drives minimize_plastic (Eigen), so it is Eigen-gated in CMake like the sibling
// optimizer gates; the real settings rule table is injected (SETTINGS_RULES_PATH).
// Same self-contained CHECK harness, public API only.

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
using topopt::DesignDomain;
using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::MaskValue;
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

// The same thin L-bracket the diagnosis / reduction gate build: a vertical arm
// mounted (Fixture) at the top, a horizontal foot Load-ed down at its free end.
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

// The anchor PAD the bridge builds (mask_step_face, kAnchorPadDepthVoxels=3): the
// N solid layers BEHIND the top Fixture face (its boss), FrozenSolid on the PART
// grid. Built by hand here (no StepModel needed): the Fixture layer k=arm-1 plus
// the two interior layers below it, over i<t, all j. The interior layers are the
// meaningful part — the Fixture skin is pinned by effective_mask regardless.
DesignMask anchor_pad(const VoxelGrid& part, int arm, int t, int pad_depth) {
  DesignMask pad = topopt::make_active_mask(part);
  for (int k = arm - pad_depth; k < arm; ++k)
    for (int j = 0; j < part.ny; ++j)
      for (int i = 0; i < t; ++i)
        if (k >= 0) pad[part.index(i, j, k)] = MaskValue::FrozenSolid;
  return pad;
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

  const int arm = 8, span = 8, ny = 3, t = 2, pad_depth = 3;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const double part_mass = part_mass_grams(part, material);

  // A design box drawn LARGER than the part on the low side of every axis, so the
  // part sits at a STRICTLY POSITIVE whole-voxel offset inside the expanded grid
  // (guard b). Part bbox is x,z in [0,16], y in [0,6]; extend the low corner below
  // the origin. spacing = 2 => offsets = ceil(6/2)=3, ceil(4/2)=2, ceil(6/2)=3.
  DesignBox box;
  box.min = Vec3{-6.0, -4.0, -6.0};
  box.max = Vec3{16.0, 6.0, 16.0};

  const Vec3 tip_force{0.0, 0.0, -30.0};
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, tip_force);

  // The expanded domain the driver builds internally (SAME args: whole-domain
  // freeze_part=false, coarsen_align=8) — used to compute the offset-remapped pad
  // indices and to size-check the result. Offsets are independent of coarsen_align.
  const DesignDomain domain =
      topopt::expand_design_domain(part, box, /*keep_out=*/{},
                                   /*freeze_part=*/false, /*coarsen_align=*/8);
  CHECK(domain.offset_i > 0 && domain.offset_j > 0 && domain.offset_k > 0,
        "(b): the box forces a strictly positive offset on every axis");

  const DesignMask pad = anchor_pad(part, arm, t, pad_depth);

  // --- The whole-domain box run WITH the anchor pad merged ------------------
  MinimizePlasticOptions pad_opts = prod_options(tip);
  pad_opts.design_box = box;            // freeze_imported_part defaults to false
  pad_opts.design_mask = pad;           // the anchor pad — MERGED (pre-082: threw)
  const MinimizePlasticResult with_pad =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, pad_opts);

  CHECK(!with_pad.evaluated.empty(), "box+pad run produced at least one rung");
  const std::vector<double>& rho =
      with_pad.evaluated.front().optimization.physical_density;
  CHECK(rho.size() == domain.grid.voxel_count(),
        "(b): the result is on the expanded grid the driver built (dims match)");

  // (a)+(b): every pad voxel, remapped by the SAME offset the BC/load remap uses,
  // is retained solid. A zero/wrong offset would sample an unpinned Active voxel.
  double min_pad_density = 1.0;
  std::size_t pad_voxels = 0, protected_voxels = 0;
  for (int pk = 0; pk < part.nz; ++pk)
    for (int pj = 0; pj < part.ny; ++pj)
      for (int pi = 0; pi < part.nx; ++pi) {
        if (pad[part.index(pi, pj, pk)] != MaskValue::FrozenSolid) continue;
        ++pad_voxels;
        const std::size_t e = domain.grid.index(
            pi + domain.offset_i, pj + domain.offset_j, pk + domain.offset_k);
        if (e < rho.size() && rho[e] >= 0.9) ++protected_voxels;
        if (e < rho.size() && rho[e] < min_pad_density) min_pad_density = rho[e];
      }
  CHECK(pad_voxels > 0, "sanity: the pad marks a non-empty anchor neighbourhood");
  CHECK(protected_voxels == pad_voxels,
        "(a): every remapped pad voxel is retained SOLID (density >= 0.9)");

  // (c): the pad must not turn the box run near-solid. Compare to the SAME box run
  // WITHOUT the pad and report both savings. Both must still remove material.
  MinimizePlasticOptions nopad_opts = prod_options(tip);
  nopad_opts.design_box = box;
  const MinimizePlasticResult no_pad =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, nopad_opts);
  CHECK(!no_pad.evaluated.empty(), "box (no pad) run produced at least one rung");

  const double pad_mass = with_pad.evaluated.back().mass_grams;
  const double pad_achieved = with_pad.evaluated.back().optimization.volume_fraction;
  const double nopad_mass = no_pad.evaluated.back().mass_grams;
  const double nopad_achieved =
      no_pad.evaluated.back().optimization.volume_fraction;
  CHECK(pad_mass < part_mass,
        "(c): box+pad still REMOVES material (printed mass < part mass)");
  CHECK(pad_achieved < 1.0,
        "(c): box+pad part-relative achieved fraction is below 1 (not near-solid)");

  // (d): the add-material contract — design_box + design_mask still throws when the
  // part is FROZEN (freeze_imported_part == true). The pad is meaningless there.
  bool threw_frozen = false;
  try {
    MinimizePlasticOptions frozen = prod_options(tip);
    frozen.design_box = box;
    frozen.freeze_imported_part = true;
    frozen.design_mask = pad;
    topopt::minimize_plastic(part, material, "fdm", bcs, rules, frozen);
  } catch (const std::invalid_argument&) {
    threw_frozen = true;
  }
  CHECK(threw_frozen,
        "(d): design_box + design_mask still throws when freeze_imported_part=true");

  std::printf(
      "[082] part_mass=%.6g g  pad_voxels=%zu (min density %.4f)  offset=(%d,%d,%d)\n",
      part_mass, pad_voxels, min_pad_density, domain.offset_i, domain.offset_j,
      domain.offset_k);
  std::printf(
      "[082] box+pad : rungs=%zu  achieved(part-rel)=%.4f  mass=%.6g g  savings=%.1f%%\n",
      with_pad.evaluated.size(), pad_achieved, pad_mass,
      100.0 * (1.0 - pad_achieved));
  std::printf(
      "[082] box nopad: rungs=%zu  achieved(part-rel)=%.4f  mass=%.6g g  savings=%.1f%%\n",
      no_pad.evaluated.size(), nopad_achieved, nopad_mass,
      100.0 * (1.0 - nopad_achieved));

  if (g_failures == 0) {
    std::printf("designbox_anchor_pad (082): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "designbox_anchor_pad (082): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
