// test_width_aware_knockdown — the width-aware accept-gate knockdown (handoff
// 2026-07-26-width-aware-knockdown).
//
// Four bars from the decision brief, all first-hand:
//   K3  the SHIPPED width_aware_knockdown reproduces 191/192's member-scale composite
//       (E_eff/E_solid and the margin@1.5 the gate would certify) — if the production
//       model disagreed with the harness that motivated it, the production model
//       would be wrong;
//   K5  degenerate cases — solid infill is EXACTLY 1.0, wall-less members reduce to
//       f^1.5, thin / single-voxel / thinner-than-2t members never divide by zero or
//       exceed 1.0;
//   the LOCAL MEMBER WIDTH distance transform measures a rib's full width (bar (b));
//   the composite is monotone and its SIGN is always "no less conservative than f^1.5"
//       (bar K4): width_aware_knockdown >= f^1.5 everywhere, so it only ever RELIEVES,
//       and it relieves less as the member thickens.

#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/voxel.hpp"

using topopt::infill_margin_knockdown;
using topopt::local_member_thickness_mm;
using topopt::wall_area_fraction;
using topopt::width_aware_knockdown;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static void check(bool ok, const std::string& what) {
  if (!ok) {
    std::printf("  FAIL: %s\n", what.c_str());
    ++g_failures;
  }
}
static bool close(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

// A solid W_x × W_y × W_z voxel block centred in a padded grid (void margin all
// round), spacing `h` mm. Density is 1.0 on the block, 0.0 elsewhere.
static VoxelGrid solid_block(int wx, int wy, int wz, int pad, double h,
                             std::vector<double>& density) {
  VoxelGrid g;
  g.nx = wx + 2 * pad;
  g.ny = wy + 2 * pad;
  g.nz = wz + 2 * pad;
  g.spacing = h;
  const std::size_t n =
      static_cast<std::size_t>(g.nx) * g.ny * g.nz;  // voxel_count() reads tags.size()
  g.tags.assign(n, VoxelTag::Empty);
  density.assign(n, 0.0);
  for (int k = pad; k < pad + wz; ++k)
    for (int j = pad; j < pad + wy; ++j)
      for (int i = pad; i < pad + wx; ++i) {
        g.tags[g.index(i, j, k)] = VoxelTag::Interior;
        density[g.index(i, j, k)] = 1.0;
      }
  return g;
}

int main() {
  const double kInf = std::numeric_limits<double>::infinity();
  const double kNaN = std::numeric_limits<double>::quiet_NaN();

  // ─── K5: wall_area_fraction degenerate cases ───────────────────────────────
  // A ring can't exceed the half-width: a member thinner than 2t is all wall → 1.
  check(wall_area_fraction(10.0, 0.0) == 0.0, "no walls (t=0) → f_wall 0");
  check(wall_area_fraction(0.0, 2.0) == 0.0, "zero width → f_wall 0 (no div by zero)");
  check(wall_area_fraction(-1.0, 2.0) == 0.0, "negative width → f_wall 0");
  check(wall_area_fraction(kInf, 2.0) == 0.0, "unbounded width → f_wall 0 (thick, no rescue)");
  check(wall_area_fraction(2.0, 5.0) == 1.0, "t > W/2 (member thinner than wall stack) → 1");
  check(wall_area_fraction(4.0, 2.0) == 1.0, "t == W/2 → exactly 1 (all wall)");
  {
    // A finite interior value in (0,1): 10 mm member, t = 2.25 (5×0.45).
    const double fw = wall_area_fraction(10.0, 2.25);
    check(fw > 0.0 && fw < 1.0, "interior f_wall strictly in (0,1)");
    check(close(fw, 4.0 * 2.25 * (10.0 - 2.25) / 100.0, 1e-12),
          "f_wall matches 4t(W-t)/W² exactly");
  }

  // ─── K5: width_aware_knockdown degenerate cases ────────────────────────────
  // Solid infill is EXACTLY 1.0 for ANY member / wall geometry (no knockdown).
  check(width_aware_knockdown(100.0, 10.0, 2.25) == 1.0, "solid infill → exactly 1.0 (walled)");
  check(width_aware_knockdown(100.0, 0.3, 0.0) == 1.0, "solid infill → exactly 1.0 (thin, wall-less)");
  check(width_aware_knockdown(150.0, 10.0, 2.25) == 1.0, ">100 infill → clamped to 1.0");
  // Wall-less member reduces EXACTLY to the scalar f^1.5 (the pre-width gate).
  for (double p : {15.0, 30.0, 60.0, 0.0}) {
    check(width_aware_knockdown(p, 10.0, 0.0) == infill_margin_knockdown(p),
          "wall-less member (t=0) == infill_margin_knockdown at " + std::to_string(p));
    check(width_aware_knockdown(p, kInf, 2.25) == infill_margin_knockdown(p),
          "unbounded-width member == infill_margin_knockdown at " + std::to_string(p));
  }
  // Single-voxel / very thin members: bounded in (0,1], never NaN/inf.
  for (double W : {0.001, 0.31, 1.0, 3.0}) {
    const double k = width_aware_knockdown(30.0, W, 2.25);
    check(std::isfinite(k) && k > 0.0 && k <= 1.0,
          "thin member knockdown in (0,1], finite at W=" + std::to_string(W));
  }
  // A member thinner than 2t is all-wall → solid-equivalent knockdown 1.0.
  check(close(width_aware_knockdown(30.0, 4.0, 2.25), 1.0, 1e-12),
        "member thinner than 2t → knockdown 1.0 (all wall)");
  check(std::isfinite(width_aware_knockdown(30.0, kNaN, 2.25)),
        "NaN width → finite (treated as no-member, no rescue)");

  // ─── K4: SIGN — the composite is never less conservative than f^1.5, and it ─
  // relieves monotonically less as the member thickens. width_aware >= f^1.5 means
  // margin_effective = worst_case·k >= worst_case·f^1.5, so the gate only ever
  // becomes LESS cautious, and only in proportion to the wall rescue; a thick member
  // (small f_wall) is left at ~today's f^1.5, so caution on thick sections is kept.
  for (double p : {15.0, 30.0, 60.0}) {
    const double core = infill_margin_knockdown(p);
    double prev = 1.0;  // k at the thinnest → 1.0; must DECREASE toward core as W grows
    for (double W : {2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 400.0}) {
      const double k = width_aware_knockdown(p, W, 2.25);  // 5 loops
      check(k >= core - 1e-12, "k >= f^1.5 (never MORE conservative) p=" + std::to_string(p) +
                                   " W=" + std::to_string(W));
      check(k <= prev + 1e-12, "k monotonically decreases with width p=" + std::to_string(p) +
                                   " W=" + std::to_string(W));
      prev = k;
    }
    check(width_aware_knockdown(p, 400.0, 2.25) > core - 1e-12 &&
              width_aware_knockdown(p, 400.0, 2.25) < core + 0.05,
          "very wide member → within 5% of f^1.5 (thick region ~unchanged) p=" +
              std::to_string(p));
  }

  // ─── K3: reproduce 191/192's member-scale composite ────────────────────────
  // Each row is a DIRECTLY-RESOLVED wall-and-core specimen from handoff
  // 2026-07-26-knockdown-member-scale (§1 M_axial.csv, §A3): the measured stiffness
  // ratio E_meas/E_solid and the true margin of a part the OLD gate certifies at 1.5
  // (margin@1.5 = 1.5·E_meas/f^1.5). The shipped model is the SAME Voigt composite the
  // harness validated, evaluated on the NOMINAL φ_wall = 4t(W-t)/W² with t = loops·0.45.
  // Two gaps separate the nominal composite from the measurement, both named in 192:
  // the specimen's DISCRETIZED φ_wall (vpc16) differs from nominal by up to ~5%, and a
  // real resolved part is ~2-3% softer than the rule of mixtures. Net ≤ 7%.
  const double kLine = 0.45;  // the line width 191/192 used (0.4 mm nozzle)
  struct Row { double W; int loops; double infill; double e_meas; double margin15; };
  const std::vector<Row> table = {
      {10.0, 5, 30.0, 0.7321, 6.68},  {10.0, 3, 60.0, 0.6791, 2.19},
      {10.0, 5, 15.0, 0.7182, 18.54}, {10.0, 5, 60.0, 0.8225, 2.65},
      {5.0, 5, 30.0, 0.9900, 9.04},   {5.0, 3, 60.0, 0.8850, 2.86},
      {10.0, 3, 30.0, 0.5210, 4.76},
  };
  std::printf("  K3 — shipped composite vs 192's directly-resolved members:\n");
  std::printf("  %-6s %-5s %-6s | %-8s %-8s %-6s | %-8s %-8s\n", "W(mm)", "loops",
              "infill", "shipped", "E_meas", "ratio", "m@1.5", "192");
  for (const Row& r : table) {
    const double t = r.loops * kLine;
    const double k = width_aware_knockdown(r.infill, r.W, t);
    // (a) the shipped value IS the exact Voigt composite (single source of the law).
    const double fw = wall_area_fraction(r.W, t);
    const double voigt = fw + (1.0 - fw) * infill_margin_knockdown(r.infill);
    check(close(k, voigt, 1e-12), "shipped == exact Voigt composite");
    // (b) it reproduces the MEASUREMENT within the stated 7% (discretization + softening).
    const double ratio = k / r.e_meas;
    check(close(ratio, 1.0, 0.07), "composite within 7% of measured E_meas/Es");
    // (c) the margin the shipped gate would certify reproduces 192's margin@1.5 (±8%).
    const double m15 = 1.5 * k / infill_margin_knockdown(r.infill);
    check(close(m15 / r.margin15, 1.0, 0.08), "margin@1.5 within 8% of 192");
    std::printf("  %-6.0f %-5d %-6.0f | %-8.4f %-8.4f %-6.3f | %-8.2f %-8.2f\n", r.W,
                r.loops, r.infill, k, r.e_meas, ratio, m15, r.margin15);
  }

  // ─── bar (b): the LOCAL MEMBER WIDTH distance transform ────────────────────
  // A slab W_z voxels thick (spacing h) → every printed voxel reads the slab's full
  // width 2·round(W_z/2)·h, INCLUDING the outer-fibre voxels (a plain 2·EDT would
  // read those as one voxel). The distance transform gives the INSCRIBED thickness.
  {
    const double h = 1.0;
    std::vector<double> d;
    // A 40×40×6 slab (thin in z), pad 4 → interior thickness 6 voxels = 6·h.
    VoxelGrid g = solid_block(40, 40, 6, 4, h, d);
    const std::vector<double> tau = local_member_thickness_mm(g, d, 0.5, 32);
    // Centre voxel and an outer-fibre voxel (top face of the slab) both read 6 mm.
    const std::size_t ctr = g.index(20, 20, 4 + 3);
    const std::size_t face = g.index(20, 20, 4);  // z = first slab layer (outer fibre)
    check(close(tau[ctr], 6.0, 1e-9), "slab centre thickness == 6 mm (full width)");
    check(close(tau[face], 6.0, 1e-9),
          "slab OUTER-FIBRE voxel also reads 6 mm (inscribed, not 2·EDT)");
    // A void voxel reads 0.
    check(tau[g.index(0, 0, 0)] == 0.0, "void voxel thickness 0");
  }
  {
    // A single isolated voxel → minimum thickness 2·spacing (K5 single-voxel).
    const double h = 2.5;
    std::vector<double> d;
    VoxelGrid g = solid_block(1, 1, 1, 4, h, d);
    const std::vector<double> tau = local_member_thickness_mm(g, d, 0.5, 32);
    check(close(tau[g.index(4, 4, 4)], 2.0 * h, 1e-9),
          "single-voxel member thickness == 2·spacing");
  }
  {
    // A block thicker than 2·cap·spacing → +inf (thick, no wall rescue → conservative).
    const double h = 1.0;
    std::vector<double> d;
    VoxelGrid g = solid_block(20, 20, 20, 2, h, d);
    const std::vector<double> tau = local_member_thickness_mm(g, d, 0.5, 4);
    const std::size_t ctr = g.index(2 + 10, 2 + 10, 2 + 10);
    check(std::isinf(tau[ctr]), "region past the cap → +inf thickness (no rescue)");
    // …and width_aware_knockdown on that +inf reads as f^1.5 (thick, unchanged).
    check(width_aware_knockdown(30.0, tau[ctr], 2.25) == infill_margin_knockdown(30.0),
          "capped (+inf) thickness → knockdown == f^1.5 (thick region kept cautious)");
  }

  if (g_failures == 0)
    std::printf("width-aware knockdown: all checks passed\n");
  else
    std::printf("width-aware knockdown: %d CHECK(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
