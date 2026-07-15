// Design-box grid-report guard — the reported result grid MUST equal the grid
// minimize_plastic actually solved on.
//
// THE BUG this locks down (bridge.cpp): the app-facing bridge rebuilt the grid it
// reports to the app with a 3-argument expand_design_domain(part, box, keep_out)
// call, which takes the library DEFAULTS freeze_part=true and coarsen_align=1 —
// an UNPADDED grid. But minimize_plastic solves on
// expand_design_domain(part, box, keep_out, options.freeze_imported_part,
// kDesignBoxCoarsenAlign) — a grid whose element dims are rounded UP to a multiple
// of 8, and whose mask semantics follow freeze_imported_part. The two grids have
// DIFFERENT dims, so the app received grid metadata for the wrong grid and sampled
// every grid-indexed field (von Mises, displacement, playback) at the wrong
// voxels. No crash (the real field is larger) — silently wrong.
//
// The structural fix makes minimize_plastic RETURN the grid it solved on
// (MinimizePlasticResult::solved_grid) and exposes minimize_plastic_solved_grid()
// so a caller needing that grid BEFORE the solve returns (the progressive-variant
// stream) derives it through the SAME code path. This gate asserts:
//   (a) solved_grid == minimize_plastic_solved_grid(part, opts), dims/origin/
//       spacing, voxel-for-voxel — and that the OLD 3-arg default derivation
//       produces DIFFERENT dims (so it would MISREPORT; this documents the bug
//       and fails loudly if anyone restores the 3-arg call).
//   (b) the per-variant von-Mises / displacement / density field lengths match
//       solved_grid's voxel / node counts (a size tripwire for any future drift).
//   (c) no-box path: solved_grid IS the part grid, byte-identical.
//
// Drives minimize_plastic / the design-box multigrid (Eigen), so it is Eigen-gated
// in CMake like the sibling optimizer gates. The settings rule table path is
// injected (SETTINGS_RULES_PATH). Public API only; the same self-contained CHECK
// harness as the sibling tests (ARCHITECTURE §4 — no third-party framework).

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cstddef>
#include <cstdio>
#include <stdexcept>
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
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

// A solid block, `t` voxels thick out of plane (j). The top face (k == nz-1) is
// tagged Fixture + clamped; the free bottom edge (i == nx-1, k == 0) is tagged
// Load for a downward tip force. Returns the grid; fills `bcs`.
VoxelGrid block(std::vector<DirichletBC>& bcs, int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  // Surface skin so the voxelization is self-consistent (not required for FEA).
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const bool boundary = i == 0 || i == nx - 1 || j == 0 || j == ny - 1 ||
                              k == 0 || k == nz - 1;
        if (boundary) g.set_tag(i, j, k, VoxelTag::Surface);
      }
  // Mount: the top voxel row, clamped on the top node plane.
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < nx; ++i) g.set_tag(i, j, nz - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= nx; ++a) {
      const int node = topopt::fea_node_index(g, a, b, nz);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  // Load: the free bottom edge.
  for (int j = 0; j < ny; ++j) g.set_tag(nx - 1, j, 0, VoxelTag::Load);
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

bool same_geometry(const VoxelGrid& a, const VoxelGrid& b) {
  return a.nx == b.nx && a.ny == b.ny && a.nz == b.nz &&
         a.spacing == b.spacing && a.origin.x == b.origin.x &&
         a.origin.y == b.origin.y && a.origin.z == b.origin.z;
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

  // --- A part + a design box whose UNPADDED expanded dims are NOT multiples of
  // 8, so the coarsening alignment the driver applies actually changes the dims.
  // This is what makes the 3-arg (unpadded) derivation observably wrong.
  const int nx = 5, ny = 3, nz = 5;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = block(bcs, nx, ny, nz, h);
  const Vec3 tip_force{0.0, 0.0, -2.0e-4};
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, tip_force);

  // The part bbox is x,z in [0, 10], y in [0, 6]. Extend the box a couple voxels
  // beyond +x and +z so the raw expanded element dims (e.g. 7x3x7) are not
  // multiples of 8 → alignment rounds them UP to 8x8x8, a DIFFERENT grid.
  DesignBox box;
  box.min = Vec3{0.0, 0.0, 0.0};
  box.max = Vec3{14.0, 6.0, 14.0};

  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.5};
  o.margin_stop = 0.0;              // accept the single rung
  o.gravity = 0.0;                  // an external load case drives the design
  o.gravity_direction = Vec3{0, 0, -1};
  o.external_loads = tip;           // node-indexed to the PART; the driver remaps
  o.design_box = box;
  // freeze_imported_part left at its production DEFAULT (false, whole-domain
  // optimize) — exactly the design-box run the bridge issues.
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 20;
  o.simp.change_tol = 0.0;
  o.simp.cg_tolerance = 1e-8;

  // The grid a caller must report, derived up front through the SAME path the
  // driver uses (this is what the fixed bridge feeds the progressive stream).
  const VoxelGrid reported = topopt::minimize_plastic_solved_grid(part, o);

  // The OLD, BUGGY bridge derivation: 3-arg defaults (freeze_part=true,
  // coarsen_align=1) → an UNPADDED grid. Reproduced here to prove it diverges.
  const VoxelGrid buggy =
      topopt::expand_design_domain(part, box, o.keep_out_boxes).grid;

  const MinimizePlasticResult mp =
      topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, o);
  CHECK(!mp.evaluated.empty() && mp.evaluated[0].accepted,
        "run: the design-box rung is evaluated and accepted");

  // (a) The reported grid EQUALS the grid the driver solved on, voxel-for-voxel.
  CHECK(same_geometry(mp.solved_grid, reported),
        "(a): minimize_plastic_solved_grid == MinimizePlasticResult::solved_grid");
  CHECK(mp.solved_grid.nx == reported.nx && mp.solved_grid.ny == reported.ny &&
            mp.solved_grid.nz == reported.nz,
        "(a): reported grid dims equal the solved grid dims");

  // The design box genuinely enlarged the grid beyond the part (the branch is
  // exercised, not a no-op) and alignment rounded the dims to multiples of 8.
  CHECK(mp.solved_grid.voxel_count() > part.voxel_count(),
        "(a): the design box enlarges the solved grid beyond the part");
  CHECK(mp.solved_grid.nx % 8 == 0 && mp.solved_grid.ny % 8 == 0 &&
            mp.solved_grid.nz % 8 == 0,
        "(a): the solved grid's element dims are coarsening-aligned (mult of 8)");

  // THE BUG, made loud: the 3-arg default derivation the old bridge used reports
  // DIFFERENT dims than the grid actually solved on. If anyone restores that call
  // this fails, instead of the app silently sampling fields at the wrong voxels.
  CHECK(!same_geometry(buggy, mp.solved_grid),
        "(a): the 3-arg default derivation MISREPORTS the solved grid (bug guard)");
  CHECK(buggy.nx != mp.solved_grid.nx || buggy.ny != mp.solved_grid.ny ||
            buggy.nz != mp.solved_grid.nz,
        "(a): the unpadded 3-arg dims differ from the solved (padded) dims");
  std::printf(
      "[grid-report] solved=%dx%dx%d  unpadded-3arg=%dx%dx%d  part=%dx%dx%d\n",
      mp.solved_grid.nx, mp.solved_grid.ny, mp.solved_grid.nz, buggy.nx, buggy.ny,
      buggy.nz, part.nx, part.ny, part.nz);

  // (b) Every per-variant grid-indexed field is sized to the REPORTED grid. A
  // caller sampling field[index(i,j,k)] with solved_grid's dims stays in-bounds
  // AND correct; a length mismatch would be caught here rather than silently.
  const auto& v = mp.evaluated[0];
  CHECK(v.optimization.physical_density.size() == mp.solved_grid.voxel_count(),
        "(b): physical_density length == solved grid voxel count");
  CHECK(v.von_mises_field.size() == mp.solved_grid.voxel_count(),
        "(b): von_mises_field length == solved grid voxel count");
  CHECK(v.stress_tensor_field.size() == 6u * mp.solved_grid.voxel_count(),
        "(b): stress_tensor_field length == 6 * solved grid voxel count");
  CHECK(v.displacement_field.size() ==
            3u * static_cast<std::size_t>(topopt::fea_node_count(mp.solved_grid)),
        "(b): displacement_field length == 3 * solved grid node count");

  // (c) No-box path: the solved grid IS the part grid, byte-identical (dims,
  // spacing, origin AND tags). Self-weight drives it (no external load remap).
  MinimizePlasticOptions nb;
  nb.volume_fraction_ladder = {0.6};
  nb.margin_stop = 0.0;
  nb.gravity = 9.81;
  nb.gravity_direction = Vec3{0, 0, -1};
  nb.simp.filter_radius = 1.5;
  nb.simp.move = 0.2;
  nb.simp.max_iterations = 20;
  nb.simp.change_tol = 0.0;
  nb.simp.cg_tolerance = 1e-8;

  const VoxelGrid nb_reported = topopt::minimize_plastic_solved_grid(part, nb);
  CHECK(same_geometry(nb_reported, part),
        "(c): no-box minimize_plastic_solved_grid geometry == part grid");
  CHECK(nb_reported.tags == part.tags,
        "(c): no-box reported grid tags are byte-identical to the part");

  const MinimizePlasticResult mp_nb =
      topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, nb);
  CHECK(!mp_nb.evaluated.empty(),
        "(c): the no-box run evaluated at least one rung");
  CHECK(same_geometry(mp_nb.solved_grid, part),
        "(c): no-box solved_grid geometry == part grid");
  CHECK(mp_nb.solved_grid.tags == part.tags,
        "(c): no-box solved_grid tags are byte-identical to the part");
  CHECK(mp_nb.evaluated[0].von_mises_field.size() == part.voxel_count(),
        "(c): no-box von_mises_field length == part voxel count");

  std::printf("[test_designbox_grid_report] %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
