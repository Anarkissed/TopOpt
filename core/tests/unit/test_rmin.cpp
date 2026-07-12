// Unit tests for physical_filter_radius (ROADMAP M7.rmin: "physical mm-based
// density-filter radius"). The density filter takes a radius in VOXEL units, so
// a fixed voxel radius pins the minimum member thickness in voxels — which
// shrinks in millimetres as the grid is refined, letting thin members
// proliferate at high resolution (diagnosis 060). physical_filter_radius scales
// the radius by 1/spacing so the filtered length scale is constant in mm.
//
// The point of this test is RESOLUTION INDEPENDENCE: one fixed physical part
// voxelized at two different resolutions must yield the same effective filter
// radius in mm (rmin_voxels * spacing constant), and the voxel radius must never
// drop below the checkerboarding floor (>= 1.5 voxels, ARCHITECTURE §4).
//
// No third-party test framework (ARCHITECTURE §4); the same self-contained
// CHECK harness as the other unit tests, public API only (topopt/simp.hpp).

#include "topopt/simp.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>

using topopt::physical_filter_radius;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                       \
  do {                                                         \
    ++g_checks;                                                \
    if (!(cond)) {                                             \
      ++g_failures;                                            \
      std::fprintf(stderr, "FAIL: %s\n", msg);                \
    }                                                          \
  } while (0)

static bool near(double a, double b, double tol) {
  return std::fabs(a - b) <= tol;
}

// Does calling f() throw std::invalid_argument?
template <typename F>
static bool throws_invalid(F f) {
  try {
    f();
  } catch (const std::invalid_argument&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

int main() {
  const double inf = std::numeric_limits<double>::infinity();
  const double nan = std::numeric_limits<double>::quiet_NaN();

  // --- Resolution independence: the core M7.rmin contract -------------------
  {
    // One fixed physical part: a 100 mm cube-ish bounding box, and a chosen
    // minimum feature size of 2.5 mm. Voxelize it at two resolutions; the
    // effective filter radius in mm (voxel radius * spacing) must be identical.
    const double part_mm = 100.0;
    const double min_feature_mm = 2.5;
    const int n_coarse = 64, n_fine = 128;
    const double sp_coarse = part_mm / n_coarse;  // ~1.5625 mm/voxel
    const double sp_fine = part_mm / n_fine;       // ~0.78125 mm/voxel

    const double r_coarse = physical_filter_radius(min_feature_mm, sp_coarse);
    const double r_fine = physical_filter_radius(min_feature_mm, sp_fine);

    // Both resolutions are fine enough to keep the feature above the 1.5-voxel
    // floor here, so the mm length scale is preserved exactly.
    CHECK(r_coarse >= 1.5, "coarse voxel radius respects the 1.5 floor");
    CHECK(r_fine >= 1.5, "fine voxel radius respects the 1.5 floor");

    const double eff_coarse = r_coarse * sp_coarse;  // mm
    const double eff_fine = r_fine * sp_fine;         // mm
    CHECK(near(eff_coarse, min_feature_mm, 1e-9),
          "coarse effective radius == min_feature_mm");
    CHECK(near(eff_fine, min_feature_mm, 1e-9),
          "fine effective radius == min_feature_mm");
    CHECK(near(eff_coarse, eff_fine, 1e-9),
          "RESOLUTION INDEPENDENCE: effective mm radius equal across "
          "resolutions");

    // The voxel radius DOES change (that is the whole point — it tracks the
    // grid), growing as the grid refines: 2.5/1.5625=1.6 vs 2.5/0.78125=3.2.
    CHECK(r_fine > r_coarse,
          "voxel radius grows with resolution (mm scale held fixed)");
  }

  // --- Checkerboarding floor ------------------------------------------------
  {
    // A grid too coarse to resolve the feature at >= 1.5 voxels: 2.5/2.0 = 1.25
    // would fall below the floor, so it clamps to 1.5 and the effective mm
    // length scale is intentionally LARGER than requested (documented trade-off:
    // a coarse mesh cannot resolve a feature finer than its own floor).
    const double sp = 2.0, min_feature_mm = 2.5;
    const double r = physical_filter_radius(min_feature_mm, sp);
    CHECK(near(r, 1.5, 1e-12), "floor: sub-1.5 voxel radius clamps to 1.5");
    CHECK(r * sp >= min_feature_mm,
          "floor: effective mm radius never smaller than requested");

    // Exactly on the floor boundary (spacing so 2.5/spacing == 1.5) still floors
    // cleanly, and just above it passes through unclamped.
    CHECK(near(physical_filter_radius(2.5, 2.5 / 1.5), 1.5, 1e-9),
          "floor boundary: == 1.5 stays 1.5");
    CHECK(physical_filter_radius(2.5, (2.5 / 1.5) - 0.01) > 1.5,
          "just below floor spacing: radius exceeds 1.5");

    // A custom (larger) floor is honoured.
    CHECK(near(physical_filter_radius(1.0, 1.0, 2.0), 2.0, 1e-12),
          "custom floor clamps a small feature up to the floor");
    CHECK(near(physical_filter_radius(4.0, 1.0, 2.0), 4.0, 1e-12),
          "custom floor: a feature above the floor passes through");
  }

  // --- Gate-V2 benchmark continuity -----------------------------------------
  {
    // The Gate-V2 benchmarks are 1.0 mm-spaced solid grids with the M6.3-locked
    // rmin = 2.5 voxels (DECISIONS 2026-07-10). Choosing min_feature_mm = 2.5
    // reproduces that voxel radius EXACTLY at spacing 1.0, so the physical fix
    // is numerically continuous with the locked benchmark radius.
    CHECK(near(physical_filter_radius(2.5, 1.0), 2.5, 1e-12),
          "benchmark continuity: 2.5 mm at spacing 1.0 == 2.5 voxels");
  }

  // --- Linearity / plain arithmetic (above the floor) -----------------------
  {
    CHECK(near(physical_filter_radius(3.0, 0.5), 6.0, 1e-12),
          "3.0 mm / 0.5 spacing == 6.0 voxels");
    CHECK(near(physical_filter_radius(3.0, 1.0), 3.0, 1e-12),
          "3.0 mm / 1.0 spacing == 3.0 voxels");
  }

  // --- Validation (<stdexcept>) ---------------------------------------------
  {
    CHECK(throws_invalid([] { physical_filter_radius(0.0, 1.0); }),
          "min_feature_mm == 0 throws");
    CHECK(throws_invalid([] { physical_filter_radius(-1.0, 1.0); }),
          "min_feature_mm < 0 throws");
    CHECK(throws_invalid([&] { physical_filter_radius(inf, 1.0); }),
          "min_feature_mm == inf throws");
    CHECK(throws_invalid([&] { physical_filter_radius(nan, 1.0); }),
          "min_feature_mm == nan throws");
    CHECK(throws_invalid([] { physical_filter_radius(2.5, 0.0); }),
          "spacing == 0 throws");
    CHECK(throws_invalid([] { physical_filter_radius(2.5, -1.0); }),
          "spacing < 0 throws");
    CHECK(throws_invalid([&] { physical_filter_radius(2.5, inf); }),
          "spacing == inf throws");
    CHECK(throws_invalid([&] { physical_filter_radius(2.5, nan); }),
          "spacing == nan throws");
    CHECK(throws_invalid([] { physical_filter_radius(2.5, 1.0, 0.0); }),
          "floor_voxels == 0 throws");
    CHECK(throws_invalid([] { physical_filter_radius(2.5, 1.0, -1.0); }),
          "floor_voxels < 0 throws");
  }

  if (g_failures == 0) {
    std::printf("rmin: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "rmin: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
