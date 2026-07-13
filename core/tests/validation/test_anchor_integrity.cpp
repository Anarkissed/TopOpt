// M7.anchor-integrity — the three policy/display fixes from diagnosis 064,
// exercised against the CORE mechanisms they live in (the bridge run path wires
// these same mechanisms; its end-to-end STEP form needs OCCT and is out of scope
// here). Tests-first, no third-party framework (ARCHITECTURE §4): the same
// self-contained CHECK harness as the other core tests, public API only.
//
//   FIX 1 — MinimizePlasticOptions::design_mask freezes an N-voxel structural
//           PAD (FrozenSolid), so a pinned region stays density 1 AND connected
//           to the body instead of being carved into a 1-voxel skin.
//   FIX 2 — MinimizePlasticOptions::margin_floor_multiple stops the reduction
//           ladder once an accepted rung is comfortably strong (symmetric to
//           margin_stop). Disabled (+infinity, the default) reproduces the
//           legacy walk-to-the-lightest-safe-rung behavior byte-for-byte.
//   FIX 3 — check_v3 never silently deletes a frozen (Load/Fixture) anchor
//           island: it SURFACES the drop via load_fixture_islands (the mesh stays
//           the single largest body), and keep_largest_and_marked_components can
//           retain the island outright when a caller wants it.
//
// The driver drives simp_optimize (Eigen), so this test is Eigen-gated in CMake
// like the other optimizer gates. The settings rule table's absolute path is
// injected (SETTINGS_RULES_PATH) like test_minimize_plastic. Parts are built in
// code (DECISIONS.md reserves core/tests/fixtures/ to the maintainer).

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::make_active_mask;
using topopt::Material;
using topopt::MaskValue;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::TriangleMesh;
using topopt::V3Report;
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

// A cantilever bracket clamped at its root face (i == 0), the same shape the
// other optimizer tests build. Fixture-tagging + clamping the i == 0 plane.
VoxelGrid cantilever(std::vector<DirichletBC>& bcs, int nx, int ny, int nz,
                     double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
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

Material pla_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;  // strong: self-weight margin is astronomically large
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

MinimizePlasticOptions base_options() {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};  // the app reduction ladder
  o.margin_stop = 1.5;
  o.gravity = 9810.0 * 1e-9;  // mm-MPa-consistent self-weight (bridge units)
  o.gravity_direction = Vec3{0, 0, -1};
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 30;
  o.simp.change_tol = 0.0;
  o.simp.cg_tolerance = 1e-8;
  return o;
}

// The real settings rule table (injected path), loaded once. recommend_settings
// needs it; the anchor-integrity behavior does not depend on its contents.
const topopt::SettingsRules& rules() {
  static const topopt::SettingsRules table =
      topopt::load_settings_rules_file(std::string(SETTINGS_RULES_PATH));
  return table;
}

// --- FIX 1: the design-mask structural pad -------------------------------
// A FrozenSolid pad supplied via options.design_mask is pinned to density 1 on
// EVERY rung (even the lightest, most-stripped one) and stays part of the single
// connected body — the mechanism that keeps an anchor boss from being carved
// into an isolated skin. Contrast: without the pad the same voxels are free
// design variables the aggressive rung is free to carve.
void test_pad_freezes_and_connects() {
  const int nx = 24, ny = 4, nz = 5, pad_depth = 3;
  std::vector<DirichletBC> bcs;
  VoxelGrid g = cantilever(bcs, nx, ny, nz, 2.0);
  const Material mat = pla_material();

  // Freeze the first `pad_depth` i-layers as a FrozenSolid pad behind the root
  // (mirrors mask_step_face on a flush anchor face, depth kAnchorPadDepthVoxels).
  DesignMask pad = make_active_mask(g);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < pad_depth; ++i)
        pad[g.index(i, j, k)] = MaskValue::FrozenSolid;

  MinimizePlasticOptions o = base_options();
  o.margin_stop = 0.0;  // disable the strength stop: walk the FULL ladder so the
                        // lightest (0.26) rung applies maximum stripping pressure
  o.design_mask = pad;

  MinimizePlasticResult r =
      topopt::minimize_plastic(g, mat, "pla", bcs, rules(), o);

  CHECK(!r.evaluated.empty(), "pad: the ladder produced at least one variant");
  bool all_rungs_pad_pinned = true;
  bool all_rungs_single_component = true;
  for (const MinimizePlasticVariant& ev : r.evaluated) {
    const std::vector<double>& rho = ev.optimization.physical_density;
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < pad_depth; ++i)
          if (!(rho[g.index(i, j, k)] >= 0.999)) all_rungs_pad_pinned = false;
    if (!ev.v3.gate_single_component()) all_rungs_single_component = false;
  }
  CHECK(all_rungs_pad_pinned,
        "FIX1: every pad voxel is pinned to density 1 on every rung");
  CHECK(all_rungs_single_component,
        "FIX1: the frozen pad stays part of the single connected body");
  CHECK(r.evaluated.back().v3.gate_load_fixture_retained(),
        "FIX1: Fixture skin is retained on the lightest rung too");

  // The pad is NOT vacuous: without it, at least one of those voxels is a real
  // design variable (so an all-Active run may move it). Assert the mask actually
  // bound the density (the pinned value is EXACTLY 1, not merely >= 0.9): only
  // the FrozenSolid pin produces an exact 1 on the stripped lightest rung.
  const std::vector<double>& last = r.evaluated.back().optimization.physical_density;
  bool exact_one = true;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < pad_depth; ++i)
        if (last[g.index(i, j, k)] != 1.0) exact_one = false;
  CHECK(exact_one, "FIX1: pad voxels are pinned to EXACTLY 1 (mask applied)");
}

// The design_mask size is validated.
void test_design_mask_size_guard() {
  std::vector<DirichletBC> bcs;
  VoxelGrid g = cantilever(bcs, 6, 3, 3, 2.0);
  MinimizePlasticOptions o = base_options();
  o.design_mask = DesignMask(g.voxel_count() + 1, MaskValue::Active);  // wrong size
  bool threw = false;
  try {
    topopt::minimize_plastic(g, pla_material(), "pla", bcs, rules(), o);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "FIX1: a design_mask sized != voxel_count is rejected");
}

// --- FIX 2: the ladder floor ---------------------------------------------
// A lightly-loaded (huge-margin) part: with the floor DISABLED (+inf, default)
// the whole ladder is accepted and walks to the lightest rung; with the floor
// SET the walk stops early at a comfortable accepted rung, and the truncated
// prefix is byte-for-byte identical to the disabled run.
void test_ladder_floor() {
  std::vector<DirichletBC> bcs;
  VoxelGrid g = cantilever(bcs, 20, 4, 5, 2.0);
  const Material mat = pla_material();  // yield 55 MPa vs tiny self-weight => huge margin

  // (c) Disabled floor (default +infinity) — the legacy walk. Every rung clears
  // margin_stop, so the full ladder is evaluated and accepted.
  MinimizePlasticOptions disabled = base_options();
  MinimizePlasticResult rd =
      topopt::minimize_plastic(g, mat, "pla", bcs, rules(), disabled);
  CHECK(rd.evaluated.size() == disabled.volume_fraction_ladder.size(),
        "FIX2(disabled): the full ladder is walked");
  bool all_accepted = true;
  for (const MinimizePlasticVariant& ev : rd.evaluated)
    if (!ev.accepted) all_accepted = false;
  CHECK(all_accepted, "FIX2(disabled): every rung is accepted (huge margin)");
  CHECK(!rd.stopped_on_floor, "FIX2(disabled): the floor never fires");
  CHECK(!rd.stopped_on_margin, "FIX2(disabled): no rung falls below margin_stop");

  // An explicit +infinity is identical to leaving the field at its default.
  MinimizePlasticOptions explicit_inf = base_options();
  explicit_inf.margin_floor_multiple = std::numeric_limits<double>::infinity();
  MinimizePlasticResult ri =
      topopt::minimize_plastic(g, mat, "pla", bcs, rules(), explicit_inf);
  CHECK(ri.evaluated.size() == rd.evaluated.size(),
        "FIX2: explicit +inf == default (same ladder length)");

  // (b) Floor SET: stop once an accepted rung is comfortably strong. With a huge
  // margin the FIRST (heaviest) rung already clears 3.0 * margin_stop, so the
  // walk stops there.
  MinimizePlasticOptions floored = base_options();
  floored.margin_floor_multiple = 3.0;
  MinimizePlasticResult rf =
      topopt::minimize_plastic(g, mat, "pla", bcs, rules(), floored);
  CHECK(rf.stopped_on_floor, "FIX2(floored): the ladder stops on the floor");
  CHECK(!rf.stopped_on_margin,
        "FIX2(floored): a floor stop is NOT a margin stop");
  CHECK(rf.evaluated.size() < rd.evaluated.size(),
        "FIX2(floored): the part is NOT stripped to the lightest rung");
  CHECK(!rf.evaluated.empty() && rf.evaluated.back().accepted,
        "FIX2(floored): the terminal rung is ACCEPTED (a coherent variant)");

  // The floored run is a PREFIX of the disabled run: same rungs, byte-identical
  // densities (determinism), the floor only truncates.
  bool prefix_identical = true;
  for (std::size_t v = 0; v < rf.evaluated.size(); ++v) {
    const std::vector<double>& a = rf.evaluated[v].optimization.physical_density;
    const std::vector<double>& b = rd.evaluated[v].optimization.physical_density;
    if (rf.evaluated[v].requested_volume_fraction !=
        rd.evaluated[v].requested_volume_fraction)
      prefix_identical = false;
    if (a.size() != b.size()) {
      prefix_identical = false;
    } else {
      for (std::size_t e = 0; e < a.size(); ++e)
        if (a[e] != b[e]) prefix_identical = false;
    }
  }
  CHECK(prefix_identical,
        "FIX2: the floored prefix is byte-identical to the disabled ladder");
}

// margin_floor_multiple is validated (>= 1 or +infinity).
void test_floor_multiple_guard() {
  std::vector<DirichletBC> bcs;
  VoxelGrid g = cantilever(bcs, 6, 3, 3, 2.0);
  for (double bad : {0.0, 0.5, -1.0, std::numeric_limits<double>::quiet_NaN()}) {
    MinimizePlasticOptions o = base_options();
    o.margin_floor_multiple = bad;
    bool threw = false;
    try {
      topopt::minimize_plastic(g, pla_material(), "pla", bcs, rules(), o);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "FIX2: margin_floor_multiple < 1 (or NaN) is rejected");
  }
}

// --- FIX 3: frozen islands survive cleanup -------------------------------

// A grid with two disconnected solid blobs: a LARGE left block and a SMALL right
// block separated by a void gap. check_v3 keeps only the largest by default —
// but when the small block carries frozen (Fixture) material the drop must be
// SURFACED (load_fixture_islands), never silent, while the shipped mesh stays the
// single largest body so the §7 V3 single-component gate is preserved.
void test_check_v3_keeps_frozen_island() {
  const int nx = 10, ny = 4, nz = 4;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 2.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);

  std::vector<double> density(g.voxel_count(), 0.0);
  auto fill = [&](int i0, int i1) {
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = i0; i <= i1; ++i) {
          g.set_tag(i, j, k, VoxelTag::Interior);
          density[g.index(i, j, k)] = 1.0;
        }
  };
  fill(0, 4);  // large left block  (5 layers)
  fill(7, 9);  // small right block (3 layers), separated by the void gap i=5,6

  // Control: no frozen tag. keep_largest_component drops the small island.
  const V3Report control = topopt::check_v3(g, density, 0.5);
  CHECK(control.mesh_components == 1,
        "FIX3(control): untagged minority island is dropped (one component)");
  CHECK(control.load_fixture_islands == 0,
        "FIX3(control): no frozen island reported");

  // Tag the SMALL block's outer face (i == 9) as Fixture — the anchor-face analog
  // (a surface skin, like tag_step_face produces). density stays 1 there. The
  // block's +i isosurface vertices are then adjacent to frozen voxels, so the
  // cleanup flags the island and SURFACES that it was dropped — rather than
  // silently deleting a pinned region (diagnosis 064). Per the diagnosis the
  // displayed mesh stays the single largest body (keep the §7 V3 gate intact);
  // the drop is exposed via load_fixture_islands.
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(9, j, k, VoxelTag::Fixture);
  const V3Report r = topopt::check_v3(g, density, 0.5);
  CHECK(r.load_fixture_islands == 1,
        "FIX3: the dropped frozen minority island is SURFACED (islands==1)");
  CHECK(control.load_fixture_islands == 0 && r.load_fixture_islands == 1,
        "FIX3: the frozen drop is NOT silent — the count distinguishes it");
  CHECK(r.mesh_components == 1 && r.gate_single_component(),
        "FIX3: the displayed mesh stays the single largest body (gate intact)");
  CHECK(r.mesh.triangles.size() == control.mesh.triangles.size(),
        "FIX3: surfacing the island does not perturb the shipped mesh");
  CHECK(r.gate_load_fixture_retained(),
        "FIX3: the tagged voxels are still retained at density 1");
}

// The mesh primitive directly: keep_largest_and_marked_components keeps a marked
// minority component, and with nothing marked equals keep_largest_component.
void test_keep_marked_components_primitive() {
  // Two disjoint triangles (no shared vertices) => two components. The first
  // (vertices 0,1,2) and the second (vertices 3,4,5).
  TriangleMesh m;
  m.vertices = {Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{0, 1, 0},
                Vec3{5, 0, 0}, Vec3{6, 0, 0}, Vec3{5, 1, 0}};
  m.triangles = {{0, 1, 2}, {3, 4, 5}};

  // Nothing marked => identical to keep_largest_component (one triangle kept).
  int extra = -1;
  std::vector<char> none(m.vertices.size(), 0);
  TriangleMesh kept_none =
      topopt::keep_largest_and_marked_components(m, none, extra);
  const TriangleMesh largest = topopt::keep_largest_component(m);
  CHECK(extra == 0, "FIX3(primitive): nothing marked => 0 extra kept");
  CHECK(kept_none.triangles.size() == largest.triangles.size() &&
            kept_none.triangles.size() == 1,
        "FIX3(primitive): unmarked == keep_largest_component (one component)");

  // Mark a vertex of the SECOND triangle => both components kept.
  std::vector<char> mark(m.vertices.size(), 0);
  mark[4] = 1;
  TriangleMesh kept_mark =
      topopt::keep_largest_and_marked_components(m, mark, extra);
  CHECK(extra == 1, "FIX3(primitive): one marked minority component kept");
  CHECK(kept_mark.triangles.size() == 2,
        "FIX3(primitive): both the largest and the marked component survive");

  // Size guard.
  bool threw = false;
  try {
    std::vector<char> wrong(m.vertices.size() + 1, 0);
    topopt::keep_largest_and_marked_components(m, wrong, extra);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw, "FIX3(primitive): keep_vertex size mismatch is rejected");
}

}  // namespace

int main() {
  test_pad_freezes_and_connects();
  test_design_mask_size_guard();
  test_ladder_floor();
  test_floor_multiple_guard();
  test_check_v3_keeps_frozen_island();
  test_keep_marked_components_primitive();

  std::fprintf(stderr, "anchor_integrity: %d checks, %d failures\n", g_checks,
               g_failures);
  return g_failures == 0 ? 0 : 1;
}
