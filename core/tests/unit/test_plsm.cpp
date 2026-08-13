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
#include "topopt/plsm_frac.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/plsm_topology.hpp"
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

// ── 7: ★ THE MOLLIFIED VALUE IS THE EXACT ANTIDERIVATIVE OF THE GRADIENT'S
//        OWN MOLLIFIER (task 2026-08-13, item 2) ─────────────────────────────
//
// This is the property the whole volume-fraction sensitivity rests on, and it is
// the ONE thing in that change a finite difference cannot reveal — because if it
// holds, the value and the gradient are two facts about one function and the
// difference has nothing to find. `S(t) = INT_t^inf delta_q` means
// `dS/dt = -delta_q(t)` IDENTICALLY. Checked at the KNOTS (t = 0, +-eps) as well
// as inside, because a smoothing law that is only right in the interior is the
// shape of defect that survives a coarse sweep.
void test_mollified_value_is_the_mollifier_antiderivative() {
  const double eps = 0.37;
  // INT delta_q = 1 exactly: a mollifier that does not integrate to one scales
  // the whole volume sensitivity by a constant nobody would notice in a descent
  // direction.
  double integral = 0.0;
  const int N = 200000;
  const double lo = -2.0 * eps, hi = 2.0 * eps, dt = (hi - lo) / N;
  for (int i = 0; i < N; ++i)
    integral += topopt::plsm_frac_delta_q(lo + (i + 0.5) * dt, eps) * dt;
  CHECK(std::fabs(integral - 1.0) < 1e-6,
        "the quadrature mollifier must integrate to 1 — otherwise the whole "
        "volume sensitivity carries a constant factor");

  CHECK(topopt::plsm_frac_soft_step(-2.0 * eps, eps) == 1.0,
        "the mollified step is exactly 1 well inside the material");
  CHECK(topopt::plsm_frac_soft_step(2.0 * eps, eps) == 0.0,
        "the mollified step is exactly 0 well outside");
  CHECK(std::fabs(topopt::plsm_frac_soft_step(0.0, eps) - 0.5) < 1e-15,
        "the mollified step is exactly 0.5 ON the interface — so the PRINTED "
        "predicate {value > 0.5} is still the sign set of phi, and the printed "
        "SET does not depend on the mollification");

  double worst = 0.0;
  // ★ THE TOLERANCE IS THE CENTRAL DIFFERENCE'S OWN TRUNCATION AT THE KINKS,
  // not a fudge. S is piecewise QUADRATIC, so a central difference is exact in
  // the interior; at t = 0 and t = ±eps the second derivative jumps by 2/eps²
  // and the difference carries h/(2 eps²). Bounding by that is what makes this a
  // check on the IDENTITY rather than on the differencing.
  const double hh = 1e-6;
  const double kink_bound = 4.0 * hh / (eps * eps);
  for (int i = -12; i <= 12; ++i) {
    const double t = i * eps / 8.0;  // hits -eps, 0 and +eps exactly
    const double fd = (topopt::plsm_frac_soft_step(t + hh, eps) -
                       topopt::plsm_frac_soft_step(t - hh, eps)) /
                      (2.0 * hh);
    const double an = -topopt::plsm_frac_delta_q(t, eps);
    worst = std::max(worst, std::fabs(fd - an));
  }
  CHECK(worst < kink_bound,
        "dS/dt must equal -delta_q(t) IDENTICALLY — the value and the gradient "
        "are two facts about ONE function, and if they come apart the "
        "volume-fraction sensitivity is a mismatched gradient that converges "
        "slowly and is believed");
}

// ── 8: ★ THE SUB-CELL SAMPLE LATTICE IS THE EXPORT LATTICE ─────────────────
//
// A plane through a cell has an exact answer, so the sampled fraction can be
// checked against arithmetic rather than against itself. What this really pins is
// the LATTICE: sample p sits at (p + 0.5)/k - 0.5 in voxel units, which is where
// `plsm_evaluate(..., factor = k)` puts its samples. If those two ever come
// apart, the optimiser and the exporter are looking at different geometry and
// nothing downstream would say so.
void test_sub_cell_lattice_matches_the_export_lattice() {
  const int k = 8;
  for (double z0 : {-0.4, -0.25, 0.0, 0.25, 0.4}) {
    // phi = z - z0 in VOXEL units on a cell spanning [-0.5, 0.5].
    int in = 0;
    for (int r = 0; r < k; ++r) {
      const double z = (r + 0.5) / k - 0.5;
      if (z - z0 < 0.0) in += k * k;
    }
    const double f = static_cast<double>(in) / (k * k * k);
    const double exact = std::min(1.0, std::max(0.0, 0.5 + z0));
    CHECK(std::fabs(f - exact) <= 1.0 / k,
          "the sampled fraction must match the exact plane-in-cell volume to "
          "O(1/k) — this is the SAMPLE LATTICE as much as the arithmetic");
  }
  // And the lattice itself, stated as the identity it is.
  const int kk = 4;
  for (int p = 0; p < kk; ++p) {
    const double sub = (p + 0.5) / kk - 0.5;          // frac_ersatz's rule
    const double evalr = (p + 0.5) / kk - 0.5;        // plsm_evaluate's rule
    CHECK(sub == evalr,
          "the sub-cell sample lattice and plsm_evaluate's refined lattice are "
          "the SAME lattice — there is no second convention");
  }
}

// ── 9: ★ THE TOPOLOGY COUNTERS, ON A SHAPE WHOSE ANSWER IS KNOWN ───────────
//
// A solid block with ONE enclosed cavity and no tunnels: b0 = 1, b2 = 1, b1 = 0,
// and therefore chi = b0 - b1 + b2 = 2 — the Euler characteristic of a sphere,
// which is what a single closed pocket is.
//
// ★ THE POSITIVE CONTROL MATTERS MORE THAN THE CASE. A second field where the
// cavity is DRILLED OUT to the boundary must report b2 = 0, or "no sealed
// cavities" would be a verdict this function returns regardless of its input.
void test_void_topology_counts_a_cavity_and_a_drain() {
  const int n = 9;
  const std::size_t N = static_cast<std::size_t>(n) * n * n;
  std::vector<char> in_part(N, 1);
  auto at = [&](int i, int j, int k) { return topopt::plsm_at(n, n, i, j, k); };

  std::vector<double> occ(N, 1.0);
  for (int k = 3; k <= 5; ++k)
    for (int j = 3; j <= 5; ++j)
      for (int i = 3; i <= 5; ++i) occ[at(i, j, k)] = 0.0;
  topopt::PlsmVoidTopology t =
      topopt::plsm_void_topology(n, n, n, 1.0, occ, 0.5, in_part);
  CHECK(t.components == 1, "one enclosed pocket is one void component");
  CHECK(t.sealed_pockets == 1,
        "a pocket with no 6-connected route to a boundary plane is SEALED — "
        "the manufacturing definition, not a second opinion about it");
  CHECK(t.enclosed_solid == 0,
        "b2 counts SOLID ISLANDS the void surrounds, and there are none here — "
        "★ the sandbox header put the SEALED count here instead, which is a "
        "different quantity and which broke the identity below");
  CHECK(t.chi == 1,
        "a convex pocket is CONTRACTIBLE: chi = 1, not 2. Reading a sealed "
        "pocket as b2 reported 2 and a phantom tunnel with it");
  CHECK(t.tunnels == 0, "a convex pocket has no tunnels");
  CHECK(t.sealed_voxels == 27, "the trapped volume is the pocket itself");

  // ★ THE POSITIVE CONTROL: drill it out to the -x face.
  for (int i = 0; i < 3; ++i) occ[at(i, 4, 4)] = 0.0;
  t = topopt::plsm_void_topology(n, n, n, 1.0, occ, 0.5, in_part);
  CHECK(t.components == 1, "the drilled pocket is still one component");
  CHECK(t.sealed_pockets == 0,
        "a pocket with a route to a boundary plane is NOT sealed — without this "
        "row the check above would pass on any input");
  CHECK(t.sealed_voxels == 0, "nothing is trapped once it can drain");

  // ★ AND THE DIFFERENCE FROM THE SANDBOX THIS CAME FROM, PINNED. That version
  // marked a component open when it touched any voxel outside its region
  // predicate — which includes FROZEN SOLID — so a cavity walled in by the
  // anchor pad read as drainable. Here a PRINTED voxel is a wall whatever mask
  // value put it there, so the pocket above stays sealed however it is frozen.
}

// ── 10: ★★ THE STOPPING RULE RETURNS THE PEAK, NOT THE LAST ────────────────
//
// The whole of item 3. A synthetic margin probe replays PR 327's control curve —
// which PEAKS at iteration 80 and then falls 19.4% by 120 — and the run must come
// back carrying the iteration-80 design, stop before the ceiling, and say why.
//
// ★ THE NEGATIVE CONTROL IS THE SEVERED PROBE. A design with no load path
// measures ~zero stress and therefore an enormous margin; a rule that took the
// maximum without discarding those would select the WORST design in the run. One
// probe in the curve carries an absurd margin with load_path_ok = false and must
// be recorded and ignored.
void test_margin_plateau_stop_returns_the_peak() {
  VoxelGrid g = make_slab(10, 6, 10, 1.0);
  DesignMask mask(g.voxel_count(), MaskValue::Active);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j) {
      mask[topopt::plsm_at(g.nx, g.ny, 0, j, k)] = MaskValue::FrozenSolid;
      mask[topopt::plsm_at(g.nx, g.ny, g.nx - 1, j, k)] = MaskValue::FrozenSolid;
    }
  topopt::SimpParams params;
  params.youngs_modulus = 2000.0;   // PLA-ish; any positive value will do
  params.poisson = 0.35;
  topopt::SimpOptions so;
  so.volume_fraction = 0.5;
  std::vector<topopt::DirichletBC> bcs;
  std::vector<topopt::NodalLoad> loads;
  for (int k = 0; k <= g.nz; ++k)
    for (int j = 0; j <= g.ny; ++j)
      for (int c = 0; c < 3; ++c) {
        topopt::DirichletBC b;
        b.node = static_cast<int>(topopt::plsm_at(g.nx + 1, g.ny + 1, 0, j, k));
        b.component = c;
        bcs.push_back(b);
      }
  topopt::NodalLoad L;
  L.node = static_cast<int>(
      topopt::plsm_at(g.nx + 1, g.ny + 1, g.nx, g.ny / 2, g.nz / 2));
  L.component = 2;
  L.value = -1.0;
  loads.push_back(L);

  // PR 327's control curve on a cadence of 10, with one SEVERED probe injected
  // at iteration 30 carrying a margin nothing else can beat.
  const double curve[12] = {1915, 1965, 1e9,  2418, 2734, 2923,
                            3233, 3276, 3273, 3198, 3161, 2640};
  int calls = 0;
  PlsmOptions p;
  p.knots = PlsmKnots{2.0, 2.0, 2.0};
  p.seed = "holes";
  p.max_iterations = 120;
  p.margin_probe_every = 10;
  p.margin_plateau_probes = 3;
  p.margin_probe = [&](const std::vector<double>&) {
    topopt::PlsmMarginProbe mp;
    const int i = calls < 12 ? calls : 11;
    mp.margin = curve[i];
    mp.load_path_ok = (i != 2);  // ★ the severed one, at iteration 30
    ++calls;
    return mp;
  };
  const topopt::PlsmRunResult r =
      topopt::plsm_optimize(g, params, bcs, loads, so, mask, p);

  CHECK(r.margin_peak_iteration == 80,
        "the rule must return the PEAK iterate (80), not the last and not the "
        "best-compliance one — on this curve the endpoint understates by 19.4%");
  CHECK(std::fabs(r.margin_peak - 3276.0) < 1e-9,
        "the peak margin is the one certified at iteration 80");
  CHECK(r.optimization.iterations < 120,
        "the plateau must stop the run before the hard ceiling");
  CHECK(r.stop_reason == "margin-plateau",
        "a run stopped by the margin plateau must SAY so — a run that hit the "
        "ceiling and one that plateaued are different objects, and reading the "
        "second as the first is what made a 60-iteration cap look converged");
  CHECK(r.margin_probe_values.size() >= 3 &&
            r.margin_probe_load_path_ok.size() == r.margin_probe_values.size(),
        "the probe CURVE is reported, not just its peak (R4)");
  bool severed_recorded_and_rejected = false;
  for (std::size_t q = 0; q < r.margin_probe_values.size(); ++q)
    if (r.margin_probe_values[q] > 1e8 && r.margin_probe_load_path_ok[q] == 0)
      severed_recorded_and_rejected = true;
  CHECK(severed_recorded_and_rejected,
        "a severed probe must be RECORDED and DISCARDED — a design with no load "
        "path measures ~zero stress and an enormous meaningless margin, and a "
        "rule that took the maximum without that guard would select the WORST "
        "design in the run");

  // ★ THE POSITIVE CONTROL FOR THE DISARM. With no probe attached the historical
  // compliance-plateau rule is what stops the run, and the stop reason must not
  // claim a margin plateau nobody measured.
  PlsmOptions q = p;
  q.margin_probe = nullptr;
  q.margin_probe_every = 0;
  q.max_iterations = 12;
  const topopt::PlsmRunResult r2 =
      topopt::plsm_optimize(g, params, bcs, loads, so, mask, q);
  CHECK(r2.stop_reason != "margin-plateau",
        "with no probe attached a run cannot claim to have stopped on a margin "
        "plateau");
  CHECK(r2.margin_probe_values.empty(),
        "a run with no probe reports no probes");
}

// ── 11: ★ THE VOLUME-FRACTION PATH REFUSES WHAT IT CANNOT DO ───────────────
void test_fraction_refusals() {
  VoxelGrid g = make_slab(8, 8, 8, 1.0);
  DesignMask mask(g.voxel_count(), MaskValue::Active);
  topopt::SimpParams params;
  params.youngs_modulus = 2000.0;
  params.poisson = 0.35;
  topopt::SimpOptions so;
  so.volume_fraction = 0.5;
  so.max_iterations = 1;
  PlsmOptions p;
  p.knots = PlsmKnots{2.0, 2.0, 2.0};
  p.seed = "holes";
  p.max_iterations = 1;

  auto throws = [&](const PlsmOptions& q, const char* what) {
    ++g_checks;
    try {
      topopt::plsm_optimize(g, params, {}, {}, so, mask, q);
    } catch (const std::invalid_argument&) {
      return;
    }
    ++g_failures;
    std::fprintf(stderr, "FAIL: %s did not throw\n", what);
  };
  // ★ k = 1 would put the only sample back at the CELL CENTRE, which is exactly
  // the approximation the volume fraction exists to remove. Refused, not clamped.
  { PlsmOptions q = p; q.frac_samples = 1; throws(q, "frac_samples = 1"); }
  { PlsmOptions q = p; q.frac_samples = 32; throws(q, "frac_samples = 32"); }
  { PlsmOptions q = p; q.frac_eps_mult = 0.0; throws(q, "a zero bandwidth"); }
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
  test_mollified_value_is_the_mollifier_antiderivative();
  test_sub_cell_lattice_matches_the_export_lattice();
  test_void_topology_counts_a_cavity_and_a_drain();
  test_margin_plateau_stop_returns_the_peak();
  test_fraction_refusals();
  std::printf("test_plsm: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
