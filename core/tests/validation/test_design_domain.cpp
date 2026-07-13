// M7.dom-core acceptance test — the "add material" feature: the optimizer grows
// NEW material BEYOND the imported part (grow ribs/gussets into empty space along
// the load path) via a user-defined DESIGN VOLUME box, on top of the frozen
// imported part. Pure physics (FEA-verified), no ML.
//
// The mechanism is the M3.7 design mask; this task EXPANDS the Active region
// beyond the import by voxelizing a larger design box (expand_design_domain,
// voxel.hpp) and running the existing mask-aware MMA/SIMP optimizer over the
// larger grid+mask (wired through MinimizePlasticOptions::design_box).
//
// Fixture (built in code — DECISIONS.md reserves tests/fixtures/ to the
// maintainer, so like the other end-to-end optimizer gates this test builds its
// part in code): a THIN L-bracket wrapped in a corner design box, mounted at the
// top of its vertical arm and loaded downward at the free end of its horizontal
// foot so the re-entrant INNER corner is the stress concentration. The empty
// concave "notch" of the L (plus a margin beyond the part's bounding box) is the
// Active design volume the optimizer can grow a gusset into.
//
// Acceptance assertions (the proof the feature works):
//   (a) the optimizer GROWS material in the Active design volume (added solid
//       voxels where the import had none — measured on the Active-mask voxels);
//   (b) the keep-out region stays empty (every FrozenVoid voxel is void);
//   (c) the imported part is NEVER removed (every FrozenSolid voxel density>=0.9);
//   (d) the grown result has LOWER compliance than the import alone (adding
//       material along the load path helped).
// Plus: the expansion actually enlarges the grid, the effective mask is built per
// the rules, node remapping is exercised end-to-end (nonzero offsets — a wrong
// remap would misplace the clamp and wreck the solve), and the DEFAULT (no design
// box) run is byte-identical to the legacy driver (Active == the import).
//
// Drives minimize_plastic / simp_compliance (Eigen), so it is Eigen-gated in
// CMake like the other optimizer tests. The settings rule table path is injected
// (SETTINGS_RULES_PATH). No third-party framework (ARCHITECTURE §4): the same
// self-contained CHECK harness as the sibling tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::DesignBox;
using topopt::DesignDomain;
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

constexpr double kIso = 0.5;

// A thin L-bracket in the i-k plane, `t` voxels thick in each arm, `ny` voxels
// thick out of plane (j). The vertical arm rises along +k (i in [0,t)); the
// horizontal foot runs along +i at the base (k in [0,t)). The empty concave
// notch is i in [t, nx), k in [t, nz). The top face of the vertical arm is the
// mount (tagged Fixture + clamped), and the free end of the foot (i == nx-1) is
// tagged Load for the downward tip force. Returns the grid; fills `bcs`.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span;
  g.ny = ny;
  g.nz = arm;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);

  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        const bool vertical_arm = (i < t);          // the wall
        const bool horizontal_foot = (k < t);       // the foot
        if (vertical_arm || horizontal_foot)
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  // Reclassify true surface voxels (any Empty/off-grid face-neighbour) so the
  // fixture is a faithful voxelization; not strictly needed for FEA but keeps the
  // grid self-consistent with the voxelizer's output.
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        const bool boundary =
            !solid(i - 1, j, k) || !solid(i + 1, j, k) || !solid(i, j - 1, k) ||
            !solid(i, j + 1, k) || !solid(i, j, k - 1) || !solid(i, j, k + 1);
        if (boundary) g.set_tag(i, j, k, VoxelTag::Surface);
      }

  // Mount: the top face of the vertical arm (k == arm), tagged Fixture on its top
  // voxel row and clamped on the top node plane (nodes a in [0,t], b in [0,ny]).
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

  // Load face: the free end of the foot (i == span-1, k in [0,t)).
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

topopt::SimpParams driver_params(const Material& m) {
  topopt::SimpParams p;
  p.youngs_modulus = m.youngs_modulus_mpa;
  p.poisson = m.poisson;
  p.penalty = 3.0;
  return p;
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

  // --- The L-bracket part + its load case ----------------------------------
  const int arm = 8, span = 8, ny = 3, t = 2;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  // Downward tip force at the free end of the foot (a distributed traction that
  // sums exactly to the applied force), node-indexed to the PART grid.
  const Vec3 tip_force{0.0, 0.0, -2.0e-4};
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, tip_force);

  // --- The design volume: the empty notch + a margin beyond the part bbox ---
  // The part bounding box is x,z in [0, span*h] = [0,16], y in [0, ny*h] = [0,6].
  // The design box extends 1 voxel below the origin in x and z (forcing a NONZERO
  // voxel offset so node remapping is genuinely exercised) and 2 voxels beyond
  // the far faces, and spans the part's full thickness in y (no y expansion). Its
  // interior covers the concave notch the optimizer can grow a gusset into.
  DesignBox box;
  box.min = Vec3{-2.0, 0.5, -2.0};
  box.max = Vec3{20.0, 5.5, 20.0};
  // Keep-out: the OUTER corner of the notch (x,z in [12,16]) must stay empty.
  DesignBox keep_out;
  keep_out.min = Vec3{12.0, -1.0, 12.0};
  keep_out.max = Vec3{16.0, 7.0, 16.0};

  // The expanded design domain the driver will build (deterministic — the same
  // call the driver makes internally, so its grid/mask align index-for-index with
  // the run's physical_density).
  const DesignDomain domain =
      topopt::expand_design_domain(part, box, {keep_out});

  // The expansion actually ENLARGED the grid (new Active volume beyond the import)
  // and shifted the part by a nonzero offset (exercising node remapping).
  CHECK(domain.grid.voxel_count() > part.voxel_count(),
        "expand: the design box enlarges the grid beyond the import");
  CHECK(domain.offset_i == 1 && domain.offset_k == 1 && domain.offset_j == 0,
        "expand: the part sits at the expected nonzero voxel offset");
  CHECK(domain.grid.nx == 11 && domain.grid.ny == 3 && domain.grid.nz == 11,
        "expand: the expanded grid has the expected dimensions");
  CHECK(domain.mask.size() == domain.grid.voxel_count(),
        "expand: the mask is sized to the expanded grid");

  // Mask composition: every imported-part voxel is FrozenSolid; every keep-out
  // voxel is FrozenVoid; the physical location of a remapped part voxel is
  // preserved (offset shift only). Count the classes for reporting.
  std::size_t frozen_solid = 0, frozen_void = 0, active = 0;
  for (int k = 0; k < domain.grid.nz; ++k)
    for (int j = 0; j < domain.grid.ny; ++j)
      for (int i = 0; i < domain.grid.nx; ++i) {
        const std::size_t idx = domain.grid.index(i, j, k);
        switch (domain.mask[idx]) {
          case MaskValue::FrozenSolid: ++frozen_solid; break;
          case MaskValue::FrozenVoid: ++frozen_void; break;
          case MaskValue::Active: ++active; break;
        }
      }
  CHECK(frozen_solid == part.solid_count(),
        "expand: FrozenSolid voxel count equals the imported solid voxel count");
  CHECK(frozen_void > 0, "expand: the keep-out box produced FrozenVoid voxels");
  CHECK(active > 0, "expand: the design volume opened Active growth voxels");

  // Every FrozenSolid voxel maps back to a solid part voxel at the SAME physical
  // centre (remap correctness at the mask level).
  bool frozen_are_part = true;
  for (int k = 0; k < domain.grid.nz; ++k)
    for (int j = 0; j < domain.grid.ny; ++j)
      for (int i = 0; i < domain.grid.nx; ++i) {
        if (domain.mask[domain.grid.index(i, j, k)] != MaskValue::FrozenSolid)
          continue;
        const int pi = i - domain.offset_i, pj = j - domain.offset_j,
                  pk = k - domain.offset_k;
        if (pi < 0 || pi >= part.nx || pj < 0 || pj >= part.ny || pk < 0 ||
            pk >= part.nz || !part.solid(pi, pj, pk))
          frozen_are_part = false;
      }
  CHECK(frozen_are_part,
        "expand: every FrozenSolid voxel is an imported-part voxel");

  // remap_node_to_domain: the part origin corner node maps to the offset corner.
  const int part_corner = topopt::fea_node_index(part, 0, 0, 0);
  const int want_corner = topopt::fea_node_index(
      domain.grid, domain.offset_i, domain.offset_j, domain.offset_k);
  CHECK(topopt::remap_node_to_domain(part, domain, part_corner) == want_corner,
        "remap: the part origin node maps to the offset corner node");

  // --- Run the optimizer over the expanded design domain -------------------
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.5};  // a single rung; grow 50% of the Active volume
  o.margin_stop = 0.0;               // accept the rung (isolate the growth/compliance)
  o.gravity = 0.0;                   // unused: an external load case drives the design
  o.gravity_direction = Vec3{0, 0, -1};
  o.external_loads = tip;            // node-indexed to the PART; the driver remaps it
  o.design_box = box;
  o.keep_out_boxes = {keep_out};
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 40;
  o.simp.change_tol = 0.0;           // run the full cap (oscillating discrete design)
  o.simp.cg_tolerance = 1e-8;

  const MinimizePlasticResult grown =
      topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, o);
  CHECK(grown.evaluated.size() == 1 && grown.evaluated[0].accepted,
        "run: the design-box rung is evaluated and accepted");
  const std::vector<double>& rho = grown.evaluated[0].optimization.physical_density;
  CHECK(rho.size() == domain.grid.voxel_count(),
        "run: the result is on the expanded grid (physical_density aligns with mask)");

  // (c) The imported part is NEVER removed: every FrozenSolid voxel is retained
  // at density >= 0.9 (they are pinned to 1.0).
  double min_frozen = 1.0;
  for (std::size_t idx = 0; idx < rho.size(); ++idx)
    if (domain.mask[idx] == MaskValue::FrozenSolid && rho[idx] < min_frozen)
      min_frozen = rho[idx];
  CHECK(min_frozen >= 0.9,
        "(c): the imported part is retained (min FrozenSolid density >= 0.9)");
  CHECK(grown.evaluated[0].v3.gate_load_fixture_retained(),
        "(c): the §7 V3 Load/Fixture retention gate holds on the frozen part");

  // (a) The optimizer GREW material in the Active design volume — added solid
  // voxels where the import had NONE.
  std::size_t grown_active = 0;
  for (std::size_t idx = 0; idx < rho.size(); ++idx)
    if (domain.mask[idx] == MaskValue::Active && rho[idx] > kIso) ++grown_active;
  CHECK(grown_active > 0,
        "(a): the optimizer grew new solid material in the Active design volume");

  // (b) The keep-out region stays EMPTY: every FrozenVoid voxel is void.
  double max_void = 0.0;
  for (std::size_t idx = 0; idx < rho.size(); ++idx)
    if (domain.mask[idx] == MaskValue::FrozenVoid && rho[idx] > max_void)
      max_void = rho[idx];
  CHECK(max_void <= kIso,
        "(b): every keep-out (FrozenVoid) voxel stays empty (density <= iso)");
  CHECK(max_void == 0.0,
        "(b): FrozenVoid voxels are pinned to exactly zero density");

  // (d) The grown result has LOWER compliance than the import ALONE. The import's
  // compliance is a full-density solve on the part grid under the SAME physical
  // load — the stiffest import-only state. Adding gusset material along the load
  // path can only reduce compliance, so the grown design beats it.
  const topopt::SimpParams params = driver_params(material);
  const std::vector<double> solid_import =
      topopt::simp_uniform_density(part, 1.0);
  const topopt::SimpCompliance import_only = topopt::simp_compliance(
      part, params, solid_import, bcs, tip, o.simp.cg_tolerance,
      o.simp.cg_max_iterations);
  const double grown_compliance = grown.evaluated[0].optimization.compliance;
  CHECK(grown_compliance < import_only.compliance,
        "(d): the grown result has lower compliance than the import alone");

  // --- Default (no design box) is byte-identical to the legacy driver -------
  // With design_box unset the run uses the imported grid verbatim (Active == the
  // import): the result is on the PART grid, not an expanded one, and the whole
  // existing test_minimize_plastic gate (legacy path) is unaffected.
  MinimizePlasticOptions o_legacy = o;
  o_legacy.design_box.reset();
  o_legacy.keep_out_boxes.clear();
  const MinimizePlasticResult legacy =
      topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, o_legacy);
  CHECK(!legacy.evaluated.empty() &&
            legacy.evaluated[0].von_mises_field.size() == part.voxel_count(),
        "default: no design box runs on the imported grid (Active == the import)");
  CHECK(grown.evaluated[0].von_mises_field.size() == domain.grid.voxel_count() &&
            grown.evaluated[0].von_mises_field.size() >
                legacy.evaluated[0].von_mises_field.size(),
        "default: the design-box run is on the larger expanded grid");

  // A caller design_mask together with a design box is rejected (the box builds
  // the mask itself).
  bool threw = false;
  try {
    MinimizePlasticOptions bad = o;
    bad.design_mask = topopt::make_active_mask(part);
    topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, bad);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "guard: a design box plus a caller design_mask throws");

  std::printf(
      "[dom-core] part_solid=%zu expanded_voxels=%zu (frozen=%zu void=%zu "
      "active=%zu) grown_active=%zu\n",
      part.solid_count(), domain.grid.voxel_count(), frozen_solid, frozen_void,
      active, grown_active);
  std::printf(
      "[dom-core] compliance: import_only=%.6e grown=%.6e (%.1f%% lower)\n",
      import_only.compliance, grown_compliance,
      100.0 * (import_only.compliance - grown_compliance) / import_only.compliance);

  if (g_failures == 0) {
    std::printf("design_domain (M7.dom-core): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "design_domain (M7.dom-core): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
