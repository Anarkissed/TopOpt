// ACTIVE DOMAIN phase 1 — the restricted-analysis mask.
//
// WHAT THIS GUARDS. On a design-box run the analysis grid is 10-60x larger than
// the part and the converged design is a thin skeleton inside it, so most
// elements carry only the rho_min floor and cost a full solve to say nothing.
// SimpOptions::active_domain_band restricts every TRAJECTORY solve to the
// material plus a growth band. Handoff 134 (active-domain phase 0) measured the
// ceiling, the error and the mechanics on a read-only prototype; this test pins
// the SHIPPED mechanism, in the order the four §6.6 seams are stated:
//
//   (a) OFF IS OFF, and "everything active" is EXACT. band == 0 changes nothing.
//       A band so wide it covers the whole domain produces a design, a
//       compliance and an iteration count BIT-FOR-BIT equal to band == 0 — the
//       mask machinery is exact when it eliminates nothing, which is the
//       property the whole feature rests on.
//   (b) THE MASK IS A PURE FUNCTION with a fixed traversal: re-derivation from
//       the same field (and from a bit-identical copy) is bit-identical, for
//       every band, plus the Chebyshev geometry is what it claims to be.
//   (c) THE GROWTH INVARIANT — "the band must grow before the design can". On a
//       FULL-DOMAIN trajectory (so the answer does not depend on the restriction
//       being right), no voxel the step raises above the active threshold ever
//       lands outside the band derived one iteration earlier. Handoff 134 §3b
//       measured zero escapes over 400 iterations; here it is ASSERTED.
//   (d) THE LATCH fires AND is recorded when the band degenerates, and a
//       restricted solve that FAILS latches and falls back to the full domain
//       instead of propagating — a band may never break a run.
//
// Plus the scoping rules: the auto sizing rule's exact values, and the refusal
// to arm on a solver that is not the matrix-free multigrid (a feature that
// silently does nothing is the failure mode 125 §0 keeps re-teaching).
//
// Eigen-gated in CMake like the other optimizer tests. Public API only, same
// self-contained CHECK harness as its neighbours.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SolverKind;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::active_domain_auto_band;
using topopt::active_domain_mask;

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

// A cantilever design box: every voxel an element (the design-box shape — the
// FEA runs on the whole box every iteration), clamped on the x = 0 face, loaded
// downward at the far face's mid-height.
struct Cantilever {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

// `load_i` places the loaded node plane at that i index (default: the far face).
// Loading it SHORT of the far face is what makes the fixture genuinely dilute:
// the optimal structure lives between the clamp and the load and the rest of the
// box goes to the density floor — the design-box shape this feature exists for.
Cantilever cantilever(int nx, int ny, int nz, double tip = 10.0,
                      int load_i = -1) {
  Cantilever c;
  VoxelGrid& g = c.grid;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k <= nz; ++k)
    for (int j = 0; j <= ny; ++j) {
      const int node = topopt::fea_node_index(g, 0, j, k);
      c.bcs.push_back({node, 0, 0.0});
      c.bcs.push_back({node, 1, 0.0});
      c.bcs.push_back({node, 2, 0.0});
    }
  const int li = load_i >= 0 ? load_i : nx;
  for (int j = 0; j <= ny; ++j)
    c.loads.push_back(
        {topopt::fea_node_index(g, li, j, nz / 2), 2, -tip / (ny + 1)});
  return c;
}

SimpParams params_for() {
  SimpParams p;
  p.youngs_modulus = 2000.0;
  p.poisson = 0.35;
  p.penalty = 3.0;
  p.density_min = 1e-3;
  return p;
}

// A deterministically textured density field (no RNG — the mask must be a pure
// function of it, and the field itself must be reproducible).
std::vector<double> textured(const VoxelGrid& g, double floor) {
  std::vector<double> rho(g.voxel_count(), floor);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (((i * 7 + j * 13 + k * 29) % 11) == 0)
          rho[g.index(i, j, k)] = 0.4 + 0.01 * ((i + j + k) % 7);
  return rho;
}

long long count_active(const std::vector<char>& m) {
  long long n = 0;
  for (char c : m) n += c ? 1 : 0;
  return n;
}

}  // namespace

int main() {
  const SimpParams params = params_for();
  const double thresh = 1.5 * params.density_min;

  // =========================================================================
  // (b) THE MASK IS A PURE FUNCTION — determinism, and the geometry it claims.
  // =========================================================================
  {
    const Cantilever c = cantilever(16, 8, 12);
    const std::vector<double> rho = textured(c.grid, params.density_min);
    const std::vector<double> rho_copy = rho;  // bit-identical copy

    for (int band : {0, 1, 2, 4, 8}) {
      const std::vector<char> a =
          active_domain_mask(c.grid, rho, params.density_min, band);
      const std::vector<char> b =
          active_domain_mask(c.grid, rho, params.density_min, band);
      const std::vector<char> d =
          active_domain_mask(c.grid, rho_copy, params.density_min, band);
      CHECK(a == b && a == d,
            "mask determinism: re-derivation is bit-identical (same vector and "
            "a bit-identical copy)");
    }

    // MONOTONE IN THE BAND: a wider band can only ADD elements. This is what
    // makes "ship the wider k" a strictly safer choice rather than a different
    // one, and it is the sign every error metric in handoff 134 §2c moves in.
    long long prev = -1;
    for (int band : {1, 2, 4, 8, 64}) {
      const long long n =
          count_active(active_domain_mask(c.grid, rho, params.density_min, band));
      if (prev >= 0) CHECK(n >= prev, "mask is monotone non-decreasing in band");
      prev = n;
    }

    // A band wider than the grid covers every solid voxel exactly — the
    // degenerate case the latch exists to notice.
    const std::vector<char> all =
        active_domain_mask(c.grid, rho, params.density_min, 64);
    CHECK(count_active(all) ==
              static_cast<long long>(c.grid.solid_count()),
          "a band wider than the grid activates every solid voxel");
    // band <= 0 is the OFF path and returns exactly the same all-solid mask.
    CHECK(active_domain_mask(c.grid, rho, params.density_min, 0) == all,
          "band 0 returns the all-solid mask (the OFF path)");

    // CHEBYSHEV GEOMETRY, checked against the definition on a single seed: with
    // one core voxel, active == the cube of half-width `band` around it,
    // clipped to the grid. A Euclidean band of the same radius is a SUBSET of
    // this, which is why every fraction handoff 134 reports is an upper bound.
    {
      Cantilever s = cantilever(11, 11, 11);
      std::vector<double> one(s.grid.voxel_count(), params.density_min);
      one[s.grid.index(5, 5, 5)] = 1.0;
      const int band = 3;
      const std::vector<char> m =
          active_domain_mask(s.grid, one, params.density_min, band);
      bool exact = true;
      for (int k = 0; k < s.grid.nz; ++k)
        for (int j = 0; j < s.grid.ny; ++j)
          for (int i = 0; i < s.grid.nx; ++i) {
            const int cheb = std::max({std::abs(i - 5), std::abs(j - 5),
                                       std::abs(k - 5)});
            const bool want = cheb <= band;
            if ((m[s.grid.index(i, j, k)] != 0) != want) exact = false;
          }
      CHECK(exact,
            "the growth band is exactly the Chebyshev ball of radius `band` "
            "around the core set");
    }

    // THE BC PIN: a Load/Fixture voxel is active even at the density floor, so
    // the M3.1 void-load gate can never be handed a load on a void DOF.
    {
      Cantilever s = cantilever(9, 5, 5);
      s.grid.set_tag(8, 2, 2, VoxelTag::Load);
      s.grid.set_tag(0, 2, 2, VoxelTag::Fixture);
      const std::vector<double> floorfield(s.grid.voxel_count(),
                                           params.density_min);
      const std::vector<char> m =
          active_domain_mask(s.grid, floorfield, params.density_min, 0 + 1);
      CHECK(m[s.grid.index(8, 2, 2)] && m[s.grid.index(0, 2, 2)],
            "BC pin: Load and Fixture voxels are active at the density floor");
      // ...and nothing else within the band of them is spuriously core: the
      // pinned voxels' own band is all that survives on an all-floor field.
      CHECK(count_active(m) > 2 && count_active(m) <
                                       static_cast<long long>(
                                           s.grid.solid_count()),
            "BC pin: an all-floor field activates the pins' band, not the domain");
    }
  }

  // =========================================================================
  // The AUTO sizing rule — ceil(rmin) + 1, the width the invariant's argument
  // licenses. These exact values are what "k = 4 under the production config"
  // means, so a retune must come back through this test.
  // =========================================================================
  {
    CHECK(active_domain_auto_band(2.5) == 4,
          "auto band: rmin 2.5 voxels (min_feature 2.5 mm on a 1.0 mm grid) -> 4");
    CHECK(active_domain_auto_band(1.5) == 3,
          "auto band: the floored rmin 1.5 -> 3 (the >= 3 floor of 134 §3d)");
    CHECK(active_domain_auto_band(3.0) == 4, "auto band: rmin 3.0 -> 4");
    CHECK(active_domain_auto_band(0.0) == 1 && active_domain_auto_band(-1.0) == 1,
          "auto band: a degenerate radius floors at 1, never 0 (0 would mean OFF)");
  }

  // =========================================================================
  // (a) OFF IS OFF, and an all-covering band is BIT-IDENTICAL to off.
  //     Plus (d): that same run must LATCH, because the band buys nothing.
  // =========================================================================
  {
    const Cantilever c = cantilever(16, 6, 10);

    SimpOptions base;
    base.volume_fraction = 0.4;
    base.filter_radius = 1.5;
    base.move = 0.2;
    base.max_iterations = 12;
    base.change_tol = 0.0;  // run the full 12 iterations, both postures
    base.solver = SolverKind::MultigridCG_Matfree;

    SimpOptions off = base;  // active_domain_band == 0 (the default)
    SimpOptions wide = base;
    wide.active_domain_band = 64;  // wider than the grid: every element survives

    const SimpOptimizeResult r_off =
        topopt::simp_optimize(c.grid, params, c.bcs, c.loads, off);
    const SimpOptimizeResult r_wide =
        topopt::simp_optimize(c.grid, params, c.bcs, c.loads, wide);

    CHECK(r_off.iterations == r_wide.iterations,
          "all-covering band: same iteration count as OFF");
    CHECK(r_off.design == r_wide.design,
          "all-covering band: the design is BIT-IDENTICAL to OFF");
    CHECK(r_off.physical_density == r_wide.physical_density,
          "all-covering band: the physical density is BIT-IDENTICAL to OFF");
    CHECK(r_off.compliance == r_wide.compliance,
          "all-covering band: the compliance is BIT-IDENTICAL to OFF");

    // OFF reports itself as off, and its observability column is the neutral 1.0.
    CHECK(r_off.active_domain_band == 0 && !r_off.active_domain_latched &&
              r_off.active_fraction_mean == 1.0,
          "OFF: band 0, never latched, active fraction 1.0");

    // (d) THE LATCH: the band covered the domain, so it must SAY it buys
    // nothing rather than silently cost — at exactly the stated window.
    CHECK(r_wide.active_domain_band == 64, "latched run still reports its band");
    CHECK(r_wide.active_domain_latched, "LATCH fired on an all-covering band");
    CHECK(r_wide.active_domain_latch_iteration ==
              topopt::kActiveDomainLatchWindow,
          "LATCH fired at exactly the stated window of consecutive iterations");
    CHECK(r_wide.active_domain_latch_reason.find("buys nothing") !=
              std::string::npos,
          "LATCH recorded WHY it fired");
    CHECK(r_wide.active_fraction_mean == 1.0,
          "a domain-covering band reports an active fraction of 1.0");
    std::printf("[latch] iteration %d: %s\n", r_wide.active_domain_latch_iteration,
                r_wide.active_domain_latch_reason.c_str());

  }

  // =========================================================================
  // A REAL band on a DILUTE box actually restricts, does NOT latch, and moves
  // the design only slightly. This is the feature doing its job rather than
  // degenerating — the small-scale shadow of the production gate.
  // =========================================================================
  {
    // A SHORT cantilever inside a LONG box: clamped at x = 0, loaded at x = 8,
    // box running to x = 40. The load path can only live in the first fifth of
    // the domain, so the rest goes to the density floor — the design-box shape.
    // Fat enough in every axis that a k = 4 band cannot simply span it.
    const Cantilever c = cantilever(40, 12, 16, 10.0, /*load_i=*/8);

    SimpOptions base;
    base.volume_fraction = 0.06;  // dilute: a thin skeleton in a large box
    base.filter_radius = 2.5;     // the production rmin on a 1.0 mm grid
    base.move = 0.2;
    base.max_iterations = 20;
    base.change_tol = 0.0;
    base.solver = SolverKind::MultigridCG_Matfree;

    SimpOptions banded = base;
    banded.active_domain_band = -1;  // AUTO: ceil(2.5) + 1 = 4

    const SimpOptimizeResult r_off =
        topopt::simp_optimize(c.grid, params, c.bcs, c.loads, base);
    const SimpOptimizeResult r_band =
        topopt::simp_optimize(c.grid, params, c.bcs, c.loads, banded);

    CHECK(r_band.active_domain_band == 4,
          "AUTO resolves to ceil(filter_radius) + 1 = 4 at rmin 2.5");
    CHECK(!r_band.active_domain_latched,
          "a dilute run does NOT latch — the band is buying something");
    CHECK(r_band.active_fraction_mean < 0.85,
          "a dilute run genuinely restricts (mean active fraction below the "
          "latch threshold)");
    CHECK(std::isfinite(r_band.compliance) && r_band.compliance > 0.0,
          "a restricted run produces a finite, positive compliance");

    double mean_drho = 0.0, max_drho = 0.0;
    for (std::size_t e = 0; e < r_band.design.size(); ++e) {
      const double d = std::fabs(r_band.design[e] - r_off.design[e]);
      mean_drho += d;
      max_drho = std::max(max_drho, d);
    }
    if (!r_band.design.empty())
      mean_drho /= static_cast<double>(r_band.design.size());
    // The calibrated design-motion bar handoff 130 blocked its flip on. This is
    // a 25-iteration toy, not the production gate (that lives in the handoff's
    // evidence) — but a regression that moved the design by MORE than the bar
    // this project uses to decide whether an approximation ships must fail here.
    CHECK(mean_drho <= 0.03,
          "restricted vs full design motion is inside the calibrated 0.03 bar");
    std::printf("[dilute k=4] mean active fraction %.4f, mean|drho| %.3e, "
                "max|drho| %.3e, compliance %.6g vs %.6g\n",
                r_band.active_fraction_mean, mean_drho, max_drho,
                r_band.compliance, r_off.compliance);
  }

  // =========================================================================
  // SCOPING: the band is a matrix-free-operator feature and refuses to pretend
  // otherwise. A silent no-op would be worse than a throw.
  // =========================================================================
  {
    const Cantilever c = cantilever(8, 4, 6);
    SimpOptions o;
    o.volume_fraction = 0.5;
    o.max_iterations = 2;
    o.active_domain_band = 2;
    o.solver = SolverKind::JacobiCG;
    bool threw = false;
    try {
      topopt::simp_optimize(c.grid, params, c.bcs, c.loads, o);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "a non-zero band on a non-matrix-free solver is REJECTED");

    // ...and the STRESS path refuses it too: out of scope must mean refused,
    // never quietly ignored.
    SimpOptions so;
    so.volume_fraction = 0.5;
    so.max_iterations = 2;
    so.active_domain_band = 2;
    so.updater = topopt::SimpUpdater::MMA;
    so.solver = SolverKind::MultigridCG_Matfree;
    topopt::StressConstraint stress;
    stress.stress_cap = 100.0;
    bool threw_stress = false;
    try {
      topopt::simp_optimize_stress(c.grid, params, c.bcs, c.loads, so, stress);
    } catch (const std::invalid_argument&) {
      threw_stress = true;
    }
    CHECK(threw_stress, "a non-zero band on the STRESS path is REJECTED");
  }

  // =========================================================================
  // (c) THE GROWTH INVARIANT — the band must grow before the design can.
  //
  // Measured on the FULL-DOMAIN trajectory, so the answer does not depend on
  // the restriction being right: derive the band from iteration i's physical
  // field, take the FULL-domain step, filter, and count voxels above the active
  // threshold lying OUTSIDE that band. Any such voxel is a voxel the restricted
  // solve would have frozen at the floor — a real approximation error, and the
  // one thing that would make the mask unsound.
  // =========================================================================
  {
    const Cantilever c = cantilever(20, 6, 14);
    const double rmin = 2.5;  // the production filter radius on a 1.0 mm grid
    const int band = active_domain_auto_band(rmin);
    CHECK(band == 4, "the invariant is measured at the production band k = 4");

    const topopt::DensityFilter filter =
        topopt::make_density_filter(c.grid, rmin);
    const double vf = 0.15;  // dilute: a thin skeleton in a big box
    std::vector<double> x = topopt::simp_uniform_density(c.grid, vf);

    long long escapes = 0;
    double worst_escape_density = 0.0;
    int iters = 0;
    for (int it = 0; it < 30; ++it) {
      const std::vector<double> xphys = filter.filter_density(x);
      // The band THIS iteration would have solved on.
      const std::vector<char> m =
          active_domain_mask(c.grid, xphys, params.density_min, band);
      // The FULL-domain step (no restriction anywhere in this loop).
      const topopt::SimpCompliance sc = topopt::simp_compliance(
          c.grid, params, xphys, c.bcs, c.loads, 1e-10, 0, nullptr, nullptr,
          SolverKind::MultigridCG_Matfree);
      x = topopt::oc_update(c.grid, filter, x, sc.dcompliance, vf, 0.2,
                            params.density_min);
      const std::vector<double> after = filter.filter_density(x);
      for (std::size_t e = 0; e < after.size(); ++e) {
        if (c.grid.tags[e] == VoxelTag::Empty) continue;
        if (after[e] > thresh && m[e] == 0) {
          ++escapes;
          worst_escape_density = std::max(worst_escape_density, after[e]);
        }
      }
      ++iters;
    }
    CHECK(escapes == 0,
          "GROWTH INVARIANT: zero band escapes — the optimizer never wanted "
          "material the band forbade");
    std::printf("[invariant] %d iterations at k=%d, rmin=%.1f: %lld escapes "
                "(worst out-of-band density %.6f)\n",
                iters, band, rmin, escapes, worst_escape_density);
  }

  // =========================================================================
  // (d, second half) A RESTRICTED SOLVE THAT FAILS LATCHES AND FALLS BACK.
  //
  // Constructed deterministically: seed the run with a design concentrated at
  // the clamped end, so iteration 1's physical field is at the density floor
  // everywhere near the LOADED corner. With a narrow band the loaded node's
  // DOFs carry no element at all and the M3.1 void-load gate rejects the
  // restricted system outright. That throw must NEVER reach the caller: the run
  // latches, re-solves the same field on the full domain, and finishes.
  // =========================================================================
  {
    const Cantilever c = cantilever(24, 4, 8);

    // A seed that lives only in the first two columns (next to the clamp).
    std::vector<double> seed(c.grid.voxel_count(), 0.0);
    for (int k = 0; k < c.grid.nz; ++k)
      for (int j = 0; j < c.grid.ny; ++j)
        for (int i = 0; i < 2; ++i) seed[c.grid.index(i, j, k)] = 1.0;

    SimpOptions o;
    o.volume_fraction = 0.05;
    o.filter_radius = 1.5;
    o.move = 0.05;  // small steps: the field cannot reach the tip in one iter
    o.max_iterations = 3;
    o.change_tol = 0.0;
    o.solver = SolverKind::MultigridCG_Matfree;
    o.active_domain_band = 1;
    o.initial_design = seed;

    bool completed = true;
    SimpOptimizeResult r;
    try {
      r = topopt::simp_optimize(c.grid, params, c.bcs, c.loads, o);
    } catch (const std::exception& ex) {
      completed = false;
      std::fprintf(stderr, "  (restricted solve propagated: %s)\n", ex.what());
    }
    CHECK(completed,
          "a restricted solve that FAILS never propagates — the run completes");
    if (completed) {
      CHECK(r.active_domain_latched,
            "a failed restricted solve LATCHES the band off for the run");
      CHECK(r.active_domain_latch_reason.find("restricted solve failed") !=
                std::string::npos,
            "the failure latch records the underlying exception's message");
      CHECK(std::isfinite(r.compliance) && r.compliance > 0.0,
            "after the fallback the run produces a real, full-domain result");
      std::printf("[fallback] latched at iteration %d: %s\n",
                  r.active_domain_latch_iteration,
                  r.active_domain_latch_reason.c_str());
    }
  }

  if (g_failures == 0) {
    std::printf("active_domain: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "active_domain: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
