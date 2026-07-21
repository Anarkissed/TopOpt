// Conditional MMA Heaviside projection — "polish only when gray" (handoff 123),
// the driver-level gate that supersedes always-on production projection (PR 146,
// closed unmerged). PR 146's evidence: always-on projection paid ~4× iterations
// on parts that were ALREADY crisp, buying nothing. This gate measures the
// converged grayscale field's discreteness (Mnd) per rung and continues ONLY the
// gray rungs into β-projection, so the tax is paid only where it earns a crisper,
// honest design. What this pins:
//
//   (0) THE ONE RULE — opt-in, OFF == byte-identical. threshold 0 (the default)
//       runs the grayscale ladder unchanged and leaves the per-rung result
//       vectors empty; every existing driver caller / fixture is unaffected.
//   (a) CRISP fixture — the gate NEVER fires and adds ZERO cost. A near-solid
//       heavy rung converges crisp (Mnd well below the 0.07 threshold); with the
//       gate armed the run is BYTE-IDENTICAL to the disabled baseline (same
//       design, same iterations). The ~4× tax is dead on crisp parts.
//   (b) GRAY fixture — the gate FIRES and crisps. A coarse light rung converges
//       gray (Mnd >> 0.07); the gate continues it into β-projection (β cap 64)
//       and Mnd COLLAPSES to <= 0.05, at a reported (~3-4×) iteration cost.
//       (Min-feature 2×2×2 violations do NOT collapse on this coarse fixture — a
//       KNOWN single-field-projection limitation, handoff 116 / benchmarks.json
//       honest_limitations; the 128³ collapse is the maintainer's confirmation.)
//   (c) Determinism — the fired run reproduces byte-for-byte, twice.
//   (d) PER-RUNG gating — one ladder {crisp-heavy, gray-light} fires ONLY on the
//       gray rung, exactly the mixed-ladder behaviour the design targets.
//   (e) Scoping — the gate is INERT (result vectors empty, byte-identical to gray)
//       under updater == OC and under an always-on simp.mma_projection; a negative
//       threshold is rejected.
//   (f) The gate METRIC (design_discreteness_mnd) is correct on constructed fields.
//
// Drives minimize_plastic (Eigen); Eigen-gated in CMake. Synthetic tip-load
// cantilevers (no OCCT), the 116 / Gate-V2 fixture family; the real settings rule
// table is injected. cg_tolerance loosened to 1e-7 (behavioral test).

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#ifndef SETTINGS_RULES_PATH
#error "SETTINGS_RULES_PATH must be injected"
#endif

using namespace topopt;

static int g_failures = 0, g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

struct Problem {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

// Clamped-root cantilever, downward tip load (Fz total = -1 over the tip face) —
// the 116 / Gate-V2 fixture family, external-load path of minimize_plastic.
Problem tip_cantilever(int nx, int ny, int nz) {
  Problem pr;
  VoxelGrid& g = pr.grid;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      pr.bcs.push_back({n, 0, 0.0});
      pr.bcs.push_back({n, 1, 0.0});
      pr.bcs.push_back({n, 2, 0.0});
    }
  const double fz = -1.0 / static_cast<double>((ny + 1) * (nz + 1));
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      pr.loads.push_back({fea_node_index(g, nx, b, c), 2, fz});
  return pr;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 0.02;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// A minimize_plastic setup over `pr` at the given ladder, threshold and β cap.
MinimizePlasticOptions options(const Problem& pr, std::vector<double> ladder,
                               double threshold, double beta_max = 32.0,
                               int max_iters = 200) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = std::move(ladder);
  o.margin_stop = 0.0;  // run every rung (no margin variance)
  o.external_loads = pr.loads;
  o.require_external_loads = true;
  o.gravity_direction = Vec3{0, 0, -1};
  o.conditional_mma_projection_mnd_threshold = threshold;
  o.simp.mma_projection_beta_max = beta_max;
  o.simp.max_iterations = max_iters;
  o.simp.cg_tolerance = 1e-7;
  return o;
}

MinimizePlasticResult run(const Problem& pr, const MinimizePlasticOptions& o,
                          const SettingsRules& rules) {
  return minimize_plastic(pr.grid, fdm_material(), "FDM", pr.bcs, rules, o);
}

double final_mnd(const MinimizePlasticResult& r, std::size_t rung) {
  const DesignMask amask = make_active_mask(r.solved_grid);
  return design_discreteness_mnd(
      r.solved_grid, r.evaluated[rung].optimization.physical_density, amask);
}

bool density_bit_equal(const MinimizePlasticResult& a,
                       const MinimizePlasticResult& b, std::size_t rung) {
  const auto& ra = a.evaluated[rung].optimization.physical_density;
  const auto& rb = b.evaluated[rung].optimization.physical_density;
  return ra.size() == rb.size() &&
         std::memcmp(ra.data(), rb.data(), ra.size() * sizeof(double)) == 0;
}

}  // namespace

int main() {
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const double kThreshold = 0.07;  // the production grayness threshold (handoff 123)

  // ==========================================================================
  // (f) The gate METRIC: design_discreteness_mnd on constructed fields.
  // ==========================================================================
  {
    Problem pr = tip_cantilever(4, 4, 4);
    const DesignMask amask = make_active_mask(pr.grid);
    const std::size_t n = pr.grid.voxel_count();
    std::vector<double> crisp(n, 1.0), gray(n, 0.5), mixed(n, 0.0);
    for (std::size_t i = 0; i < n; ++i) mixed[i] = (i % 2) ? 1.0 : 0.0;  // 0/1
    CHECK(design_discreteness_mnd(pr.grid, crisp, amask) == 0.0,
          "metric: all-solid field is perfectly discrete (Mnd 0)");
    CHECK(design_discreteness_mnd(pr.grid, mixed, amask) == 0.0,
          "metric: a 0/1 field is perfectly discrete (Mnd 0)");
    CHECK(std::fabs(design_discreteness_mnd(pr.grid, gray, amask) - 1.0) < 1e-12,
          "metric: uniform-0.5 field is maximally gray (Mnd 1)");
    // A field just above/below the threshold reads accordingly.
    std::vector<double> lo(n, 0.0), hi(n, 0.0);
    for (std::size_t i = 0; i < n; ++i) { lo[i] = 0.99; hi[i] = 0.9; }
    CHECK(design_discreteness_mnd(pr.grid, lo, amask) < kThreshold,
          "metric: a near-solid (rho=0.99) field is below the gate threshold");
    CHECK(design_discreteness_mnd(pr.grid, hi, amask) > kThreshold,
          "metric: a rho=0.9 field is above the gate threshold");
  }

  // ==========================================================================
  // (0) THE ONE RULE — threshold 0 disables the gate: the per-rung result
  //     vectors are EMPTY and the run is byte-identical to a plain gray run.
  // (a) CRISP fixture — the gate never fires and adds ZERO cost. A near-solid
  //     heavy rung (vf 0.985) converges crisp (Mnd << 0.07); armed vs disabled
  //     is byte-identical (same design + same iterations): the 4× tax is dead.
  // ==========================================================================
  {
    Problem pr = tip_cantilever(24, 8, 8);
    const MinimizePlasticResult off =
        run(pr, options(pr, {0.985}, /*threshold=*/0.0, 32.0, 60), rules);
    CHECK(off.rung_grayscale_mnd.empty() &&
              off.conditional_projection_fired.empty(),
          "THE ONE RULE: disabled gate leaves the per-rung vectors empty");

    const MinimizePlasticResult armed =
        run(pr, options(pr, {0.985}, kThreshold, 32.0, 60), rules);
    CHECK(armed.conditional_projection_fired.size() == 1 &&
              armed.rung_grayscale_mnd.size() == 1,
          "armed gate records one per-rung outcome");
    CHECK(armed.rung_grayscale_mnd[0] < kThreshold,
          "CRISP: the near-solid rung's grayscale Mnd is below the threshold");
    CHECK(armed.conditional_projection_fired[0] == 0,
          "CRISP: the gate does NOT fire on the already-crisp rung");
    CHECK(final_mnd(armed, 0) < kThreshold, "CRISP: the kept field is crisp");
    // Tax-is-dead: armed-but-not-fired is byte-identical to the disabled run.
    CHECK(armed.evaluated[0].optimization.iterations ==
              off.evaluated[0].optimization.iterations,
          "CRISP: armed gate adds ZERO iterations when it does not fire");
    CHECK(density_bit_equal(armed, off, 0),
          "CRISP: armed-not-fired design is byte-identical to disabled");
    std::printf("(a) CRISP vf0.985: gray_mnd=%.4f fired=%d iters armed=%d off=%d\n",
                armed.rung_grayscale_mnd[0], armed.conditional_projection_fired[0],
                armed.evaluated[0].optimization.iterations,
                off.evaluated[0].optimization.iterations);
  }

  // ==========================================================================
  // (b) GRAY fixture — the gate FIRES and Mnd collapses to <= 0.05, at a
  //     reported iteration cost. (c) DETERMINISM — the fired run twice, byte
  //     identical. Coarse vf-0.30 tip cantilever, β cap 64 (the 116 headline cap).
  // ==========================================================================
  {
    Problem pr = tip_cantilever(24, 8, 8);
    const MinimizePlasticOptions o = options(pr, {0.30}, kThreshold, 64.0, 200);
    const MinimizePlasticResult gray_off =
        run(pr, options(pr, {0.30}, /*threshold=*/0.0, 64.0, 200), rules);
    const MinimizePlasticResult a = run(pr, o, rules);
    const MinimizePlasticResult b = run(pr, o, rules);

    CHECK(a.rung_grayscale_mnd[0] > kThreshold,
          "GRAY: the light rung's grayscale Mnd exceeds the threshold");
    CHECK(a.conditional_projection_fired[0] == 1,
          "GRAY: the gate FIRES on the gray rung");
    CHECK(final_mnd(a, 0) <= 0.05,
          "GRAY: β-projection collapses Mnd to <= 0.05 (the honesty payoff)");
    CHECK(final_mnd(a, 0) < 0.25 * a.rung_grayscale_mnd[0],
          "GRAY: projection cuts Mnd by well over 4x");
    // The cost is real and reported: firing runs materially more iterations than
    // the grayscale baseline (the β-continuation stages). Honest, not hidden.
    CHECK(a.evaluated[0].optimization.iterations >
              2 * gray_off.evaluated[0].optimization.iterations,
          "GRAY: firing reports a materially higher iteration cost");
    // Determinism (c): same inputs -> byte-identical design and iteration count.
    CHECK(a.evaluated[0].optimization.iterations ==
              b.evaluated[0].optimization.iterations,
          "DETERMINISM: fired run has identical iteration count twice");
    CHECK(density_bit_equal(a, b, 0),
          "DETERMINISM: fired run is byte-identical twice");
    std::printf(
        "(b) GRAY vf0.30: gray_mnd=%.4f -> final_mnd=%.4f | iters gray=%d "
        "fired=%d | mfv=%d\n",
        a.rung_grayscale_mnd[0], final_mnd(a, 0),
        gray_off.evaluated[0].optimization.iterations,
        a.evaluated[0].optimization.iterations,
        a.evaluated[0].report.min_feature_violations);
  }

  // ==========================================================================
  // (d) PER-RUNG gating — ONE ladder with a crisp-heavy rung and a gray-light
  //     rung fires ONLY on the gray rung (the mixed-ladder the design targets).
  // ==========================================================================
  {
    Problem pr = tip_cantilever(24, 8, 8);
    const MinimizePlasticResult r =
        run(pr, options(pr, {0.985, 0.30}, kThreshold, 64.0, 200), rules);
    CHECK(r.evaluated.size() == 2, "per-rung: both rungs ran");
    CHECK(r.conditional_projection_fired.size() == 2,
          "per-rung: one gate outcome per rung");
    CHECK(r.conditional_projection_fired[0] == 0,
          "per-rung: the crisp heavy rung does NOT fire");
    CHECK(r.conditional_projection_fired[1] == 1,
          "per-rung: the gray light rung DOES fire");
    CHECK(final_mnd(r, 0) < kThreshold, "per-rung: heavy rung stays crisp");
    CHECK(final_mnd(r, 1) <= 0.05, "per-rung: light rung is crisped by projection");
    std::printf("(d) ladder{0.985,0.30}: fired=[%d,%d] final_mnd=[%.4f,%.4f]\n",
                r.conditional_projection_fired[0],
                r.conditional_projection_fired[1], final_mnd(r, 0),
                final_mnd(r, 1));
  }

  // ==========================================================================
  // (e) SCOPING — inert under OC and under an always-on simp.mma_projection;
  //     a negative threshold is rejected.
  // ==========================================================================
  {
    Problem pr = tip_cantilever(16, 6, 6);
    // OC updater: the gate is inert (projection there is the OC schedule). The
    // per-rung vectors stay empty and the run does not project via this path.
    MinimizePlasticOptions oc = options(pr, {0.40}, kThreshold, 32.0, 80);
    oc.updater = SimpUpdater::OC;
    const MinimizePlasticResult oc_r = run(pr, oc, rules);
    CHECK(oc_r.rung_grayscale_mnd.empty() &&
              oc_r.conditional_projection_fired.empty(),
          "SCOPING: gate inert under the OC updater (no per-rung records)");

    // Always-on simp.mma_projection: the gate is inert (every rung projects
    // unconditionally); the per-rung records stay empty.
    MinimizePlasticOptions on = options(pr, {0.40}, kThreshold, 32.0, 80);
    on.simp.mma_projection = true;
    const MinimizePlasticResult on_r = run(pr, on, rules);
    CHECK(on_r.rung_grayscale_mnd.empty() &&
              on_r.conditional_projection_fired.empty(),
          "SCOPING: gate inert when always-on MMA projection is already set");

    // A negative threshold is rejected.
    bool threw = false;
    try {
      MinimizePlasticOptions bad = options(pr, {0.40}, -0.1, 32.0, 80);
      run(pr, bad, rules);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "SCOPING: a negative threshold throws std::invalid_argument");
  }

  std::printf("conditional-projection: %d/%d checks passed\n",
              g_checks - g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
