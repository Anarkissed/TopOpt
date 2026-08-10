// The PARAMETRIC LEVEL SET on the production path (task
// 2026-08-10-plsm-production). Uses the public API only, on a small synthetic
// grid, so it runs in seconds in every configuration CI builds.
//
// WHAT IS PINNED HERE, and why each one is a property the mode's whole claim
// rests on rather than a smoke test:
//
//   1. ★ THE FROZEN SET IS HELD ABOVE THE ISO BY CONSTRUCTION. PR 324 measured
//      that an analytic phi leaks 40 frozen voxels of 40,216 below the 0.5 iso,
//      that `load_path_connected` then finds no route from the anchor to the
//      load, and that EVERY certification was rejected on the LOAD PATH and not
//      on the margin. The smooth boolean is what fixes it, and this is the check
//      that says so: `plsm_frozen_floor_occupancy` is the SMALLEST ersatz value
//      any FrozenSolid voxel can take, and it must exceed 0.5. It is a property
//      of (eta, the mask) alone, so it is decidable without a solve.
//   2. THE BOOLEAN IS A UNION, NOT A STAMP. Frozen material is added SMOOTHLY:
//      the ersatz decays over the band outside the frozen set instead of
//      stepping, which is the whole difference between 5.54% and 51.31% of
//      surface crossings landing on a cell midpoint.
//   3. ★ EMPTY IS NOT A KEEP-OUT. A voxel outside the part must NOT pull the
//      part's own outermost solid layer down through the void boolean. This is
//      the one place this implementation deliberately differs from PR 324's
//      probe, and a regression here is a CAD-error regression nothing else in
//      the suite would catch.
//   4. ★ THE KNOT RULE NEVER TAKES A MINIMUM OVER THE AXES (R4). On a 4:1 slab
//      the spacing must be the same on all three axes and must follow the
//      SPACING, not the extent. This is the trap PR 323 lost a day to.
//   5. ★ THE CONDITIONAL HEAVISIDE PROJECTION MUST NOT FIRE ON A PLSM RUNG.
//      Found by running the production path: the gate measured the ersatz band
//      as "grayness", fired, and re-ran `simp_optimize` seeded from the
//      parametric field — silently replacing the design the run was made for
//      with a voxel one. The projection is disarmed on this path and this is the
//      check that keeps it disarmed.
//   6. THE REFUSALS. A bad basis, a bad seed and a non-positive knot spacing
//      throw rather than being silently defaulted.

#include "topopt/plsm.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::DesignMask;
using topopt::MaskValue;
using topopt::MinimizePlasticOptions;
using topopt::PlsmBasisKind;
using topopt::PlsmFrozenBoolean;
using topopt::PlsmKnots;
using topopt::PlsmMode;
using topopt::PlsmOptions;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// A slab with the same aspect ratio as his part (128 x 31 x 118 -> 4:1), small
// enough to be instant. Every voxel solid; the mask is set per test.
VoxelGrid make_slab(int nx, int ny, int nz, double spacing) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = spacing;
  g.origin = {0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) *
                    static_cast<std::size_t>(nz),
                VoxelTag::Interior);
  return g;
}

// ── 1 + 2: the frozen set, held above the iso, SMOOTHLY ────────────────────
void test_frozen_boolean_holds_the_load_path() {
  VoxelGrid g = make_slab(16, 8, 16, 1.7);
  DesignMask mask(g.voxel_count(), MaskValue::Active);
  // A pad three voxels deep on the low-x face — the shape of a face protection.
  std::size_t frozen = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < 3; ++i) {
        mask[g.index(i, j, k)] = MaskValue::FrozenSolid;
        ++frozen;
      }

  const PlsmFrozenBoolean fb = topopt::plsm_build_frozen_boolean(g, mask, 2);
  CHECK(fb.n_solid == frozen, "the boolean must see every FrozenSolid voxel");
  CHECK(fb.n_void == 0, "no keep-outs were set, so the void set must be empty");

  // ★ THE LOAD-PATH GUARANTEE. Every FrozenSolid voxel centre is at least half a
  // voxel inside the frozen region, so phi_eff <= -h/2 there BY CONSTRUCTION and
  // the ersatz is H_eta(h/2) — which must exceed the 0.5 iso for the
  // anchor-to-load walk to survive. At eta = 2 voxels this is 0.7376.
  const double floor2 = topopt::plsm_frozen_floor_occupancy(fb, 2.0);
  CHECK(floor2 > 0.5,
        "the smooth boolean must hold every FrozenSolid voxel above the 0.5 iso "
        "at eta = 2 voxels, or every certification is rejected on the LOAD PATH");
  CHECK(std::fabs(floor2 - 0.73758) < 1e-4,
        "the floor at eta = 2 voxels is H_eta(h/2) = 0.73758");

  // The guarantee is a property of eta and degrades monotonically with it: a band
  // wider than the frozen pad would stop holding. The optimiser refuses to run in
  // that regime rather than certifying a design whose walk is about to break.
  const double floor8 = topopt::plsm_frozen_floor_occupancy(fb, 8.0);
  CHECK(floor8 < floor2, "a wider band must hold the frozen set less firmly");

  // ★ 2. A UNION, NOT A STAMP: the frozen distance must be a genuine signed
  // distance that DECAYS outward, not a two-valued indicator. If it were a stamp,
  // every voxel outside the set would carry the same value.
  const double d1 = fb.phi_solid[g.index(3, 4, 8)];
  const double d2 = fb.phi_solid[g.index(5, 4, 8)];
  const double d3 = fb.phi_solid[g.index(7, 4, 8)];
  CHECK(d1 > 0.0 && d2 > d1 && d3 > d2,
        "outside the frozen set the distance must GROW with distance — a stamp "
        "would be constant, and a stamp is the staircase this mode exists to "
        "avoid");
  CHECK(fb.phi_solid[g.index(0, 4, 8)] < 0.0,
        "inside the frozen set the distance must be negative");
}

// ── 3: Empty is not a keep-out ─────────────────────────────────────────────
void test_empty_is_not_a_keepout() {
  VoxelGrid g = make_slab(12, 8, 12, 1.7);
  // Hollow out a shell of Empty voxels, as an imported part's bounding grid has.
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (i == 0 || j == 0 || k == 0 || i == g.nx - 1 || j == g.ny - 1 ||
            k == g.nz - 1)
          g.tags[g.index(i, j, k)] = VoxelTag::Empty;

  DesignMask mask(g.voxel_count(), MaskValue::Active);
  const PlsmFrozenBoolean fb = topopt::plsm_build_frozen_boolean(g, mask, 2);

  // ★ THE DEVIATION FROM PR 324's PROBE, PINNED. Its boolean put Empty voxels
  // into the frozen-VOID distance, which pulls the ersatz down to 0.74 in the
  // part's own outermost SOLID layer and moves the exported skin inward by ~0.2
  // voxels. Empty is outside the domain, not a keep-out the optimiser must
  // respect, so it contributes NOTHING to the void boolean and the part's skin
  // is quantised exactly as SIMP's is.
  CHECK(fb.n_void == 0,
        "Empty voxels must NOT enter the frozen-void boolean — they are outside "
        "the domain, not a keep-out, and folding them in carves the part's own "
        "skin for nothing");
  CHECK(fb.n_active > 0, "the interior must still be Active");

  // With a genuine keep-out it DOES engage, so the distinction is between the two
  // kinds of void and not between "some void" and "none".
  DesignMask k2(g.voxel_count(), MaskValue::Active);
  k2[g.index(6, 4, 6)] = MaskValue::FrozenVoid;
  const PlsmFrozenBoolean fb2 = topopt::plsm_build_frozen_boolean(g, k2, 2);
  CHECK(fb2.n_void == 1, "a genuine keep-out must enter the void boolean");
}

// ── 4: the knot rule, per axis, never a minimum ────────────────────────────
void test_knot_rule_is_per_axis_and_takes_no_minimum() {
  // His production grid's spacing.
  VoxelGrid his = make_slab(128, 31, 118, 1.705279);
  const PlsmKnots k = topopt::plsm_knots_for_grid(his);
  CHECK(k.dx == k.dy && k.dy == k.dz,
        "the spacing must be the same on every axis on a cubic-voxel grid");
  CHECK(std::fabs(k.dx - 2.0) < 1e-6,
        "his production grid must derive 2 voxels per axis");

  // ★ THE SLAB TRAP, REFUTED BY CONSTRUCTION. A rule keyed to the EXTENT of the
  // thin axis would give a different (and on a thinner slab, a catastrophic)
  // answer. Same spacing, a FAR thinner slab: the knot spacing must not move.
  VoxelGrid thin = make_slab(128, 8, 118, 1.705279);
  const PlsmKnots kt = topopt::plsm_knots_for_grid(thin);
  CHECK(kt.dx == k.dx && kt.dy == k.dy && kt.dz == k.dz,
        "the knot spacing must not depend on the part's ASPECT RATIO — that is "
        "the minimum(el_size) trap PR 323 lost a day to");

  // And it DOES follow the spacing, which is the thing it is a length in.
  VoxelGrid fine = make_slab(192, 47, 177, 1.705279 * 128.0 / 192.0);
  const PlsmKnots kf = topopt::plsm_knots_for_grid(fine);
  CHECK(kf.dx > k.dx + 0.5,
        "a finer grid must take MORE voxels per knot, so the feature scale the "
        "basis can express stays the same LENGTH");

  // The lattice built from it is per-axis all the way down: an anisotropic
  // spacing must give an anisotropic support ellipsoid, never a sphere.
  const topopt::PlsmKnotLattice L =
      topopt::plsm_make_lattice(64, 16, 64, 4.0, 2.0, 4.0, 2.0);
  CHECK(L.rx == 8.0 && L.ry == 4.0 && L.rz == 8.0,
        "the support must be an ELLIPSOID R_a = support * D_a, per axis");
}

// ── 5: the conditional Heaviside projection must not fire on a PLSM rung ───
void test_conditional_projection_is_disarmed_on_plsm() {
  // ★ THE DEFECT THIS PINS, FOUND BY RUNNING THE PRODUCTION PATH. The gate reads
  // `design_discreteness_mnd` — the fraction of the design that is neither 0 nor
  // 1 — and a PLSM ersatz is gray over its whole band BY CONSTRUCTION, so the
  // gate always fires. What it then does is the problem: it re-runs
  // `simp_optimize` seeded from the parametric field, which throws the RBF
  // coefficients away and continues the rung as a voxel design. The run would
  // report a PLSM rung and ship a SIMP one.
  //
  // There is nothing for a Heaviside projection to project here: the design
  // variable is a coefficient, not a density, and the band is the ersatz's
  // smoothing law rather than optimiser indecision. So the gate is disarmed on
  // this path, exactly as SEMDOT disarms it and for the same kind of reason.
  MinimizePlasticOptions opts;
  CHECK(opts.plsm.mode == PlsmMode::Off,
        "PlsmMode::Off must be the DEFAULT — R1 rests on it");
  // The LIBRARY default leaves the gate disarmed (threshold 0); production arms
  // it at 0.07 (configure_production_options). Arm it here, because a positive
  // control that is disarmed proves nothing.
  opts.conditional_mma_projection_mnd_threshold = 0.07;
  CHECK(topopt::conditional_mma_projection_armed(opts),
        "the gate is armed on the default SIMP path (this is the positive "
        "control: without it the next check passes vacuously)");
  opts.plsm.mode = PlsmMode::Parametric;
  CHECK(!topopt::conditional_mma_projection_armed(opts),
        "the conditional Heaviside projection must be DISARMED on a PLSM rung — "
        "otherwise it re-runs simp_optimize on the parametric field and the run "
        "silently ships a voxel design");
}

// ── 6: the refusals ────────────────────────────────────────────────────────
void test_refusals() {
  VoxelGrid g = make_slab(8, 8, 8, 1.0);
  DesignMask mask(g.voxel_count(), MaskValue::Active);
  topopt::SimpParams params;
  params.youngs_modulus = 2000.0;
  params.poisson = 0.35;
  topopt::SimpOptions so;
  so.volume_fraction = 0.5;
  PlsmOptions p;
  p.mode = PlsmMode::Parametric;
  p.max_iterations = 1;

  auto throws = [&](PlsmOptions po, const char* what) {
    ++g_checks;
    try {
      topopt::plsm_optimize(g, params, {}, {}, so, mask, po);
    } catch (const std::invalid_argument&) {
      return;
    } catch (...) {
      ++g_failures;
      std::fprintf(stderr, "FAIL: %s threw the wrong type\n", what);
      return;
    }
    ++g_failures;
    std::fprintf(stderr, "FAIL: %s did not throw\n", what);
  };

  { PlsmOptions q = p; q.basis = "cubic"; throws(q, "an unknown basis"); }
  { PlsmOptions q = p; q.seed = "simp"; throws(q, "an unknown seed"); }
  { PlsmOptions q = p; q.support = 0.5; throws(q, "a support below 1"); }
  { PlsmOptions q = p; q.eta_voxels = 0.0; throws(q, "a zero band width"); }
  {
    PlsmOptions q = p;
    q.knots.dx = 2.0;
    q.knots.dy = -1.0;
    q.knots.dz = 2.0;
    throws(q, "a negative knot spacing on one axis");
  }
  {
    ++g_checks;
    try {
      DesignMask wrong(3, MaskValue::Active);
      topopt::plsm_optimize(g, params, {}, {}, so, wrong, p);
      ++g_failures;
      std::fprintf(stderr, "FAIL: a mask of the wrong size did not throw\n");
    } catch (const std::invalid_argument&) {
    }
  }
}

}  // namespace

int main() {
  test_frozen_boolean_holds_the_load_path();
  test_empty_is_not_a_keepout();
  test_knot_rule_is_per_axis_and_takes_no_minimum();
  test_conditional_projection_is_disarmed_on_plsm();
  test_refusals();
  std::printf("test_plsm: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
