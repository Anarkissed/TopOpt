// TRIPWIRE for ALGEBRAIC LEVEL-1 COARSENING (task: algebraic-level1-coarsening).
//
// That task made the matrix-free multigrid hierarchy able to build its LEVEL 1
// by AGGREGATING the fine operator instead of by halving the fine grid — the
// space PR 283 measured at 56.3293 % energy capture on the maintainer's dilute
// field against the geometric 1.5954 %. It ships LIBRARY-DEFAULT OFF. This file
// is what makes that claim checkable, and it asserts six separate things:
//
//   1. THE PATH IS DISARMED BY DEFAULT. A process that never calls the setter
//      reports `fea_mg_algebraic_level1_enabled() == false`, so every solve
//      takes the geometric hierarchy it always has, and the named library
//      default constant agrees. A harness that forgot to disarm fails here.
//   2. ARM-THEN-DISARM LEAVES NO TRACE. The solve after arm+disarm is
//      BIT-IDENTICAL to one taken before the flag was ever touched — compared as
//      raw doubles with memcmp, not "close enough". This is THE ONE RULE
//      (byte-identical reference world) made executable.
//   3. THE PATH ACTUALLY BITES. Armed, the solver really does build a
//      NON-GEOMETRIC level 1: the reported coarse dimension differs from the
//      geometric one, aggregates are formed, and the hierarchy is reported as
//      algebraic. A flag that silently did nothing would make every measurement
//      in the handoff a measurement of noise, so this is asserted, not assumed.
//   4. IT STAYS EXACT. The armed solve reaches the SAME displacement field as
//      the geometric one to solver tolerance. This is structurally guaranteed —
//      only the coarse SPACES change, R = P^T and the SPD bottom solve keep the
//      cycle a valid CG preconditioner, and the outer FP64 CG's relative-residual
//      test is what defines convergence — but a guarantee nobody checks is a
//      wish, so it is checked.
//   5. A REFUSAL FALLS BACK CLEANLY. On a system the aggregation cannot coarsen
//      into a usable chain, the armed solve is BIT-IDENTICAL to the disarmed one
//      (the geometric builder ran) and the refusal is REPORTED rather than
//      silently swallowed.
//   6. IT IS DETERMINISTIC. Two armed setups on the same input produce the same
//      aggregate count, the same coarse dimensions and a bit-identical field.
//
// Same self-contained CHECK harness as the other unit tests (ARCHITECTURE §4:
// no third-party framework).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

// The tuning seam is INTERNAL (src/ on this target's include path). Bar 5 uses
// it to force a refusal deterministically; nothing else in this file needs it.
#include "fea/fea_matfree.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::MgAlgebraicLevel1Info;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

int g_failures = 0;

void check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    ++g_failures;
  } else {
    std::printf("ok:   %s\n", what);
  }
}

// A well-connected cantilever the geometric multigrid carries comfortably. Using
// the HEALTHY case for the parity and exactness bars is deliberate: it is the
// case where multigrid genuinely preconditions the CG in both postures, so a
// difference in the field would be a real difference, not two runs that both
// fell back to the same exact Jacobi-CG and agreed trivially.
VoxelGrid make_block(std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
  VoxelGrid g;
  g.nx = 32;
  g.ny = 16;
  g.nz = 32;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  bcs.clear();
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int nd = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({nd, 0, 0.0});
      bcs.push_back({nd, 1, 0.0});
      bcs.push_back({nd, 2, 0.0});
    }
  loads.clear();
  for (int b = 0; b <= g.ny; ++b)
    loads.push_back({topopt::fea_node_index(g, g.nx, b, 0), 2,
                     -100.0 / (g.ny + 1)});
  return g;
}

// A grid small enough that the aggregation cannot build a chain reaching the
// solver's 6,000-DOF direct-solve cap through admissible levels — the refusal
// path bar 5 exercises.
VoxelGrid make_tiny(std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
  VoxelGrid g;
  g.nx = 8;
  g.ny = 4;
  g.nz = 4;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  bcs.clear();
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int nd = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({nd, 0, 0.0});
      bcs.push_back({nd, 1, 0.0});
      bcs.push_back({nd, 2, 0.0});
    }
  loads.clear();
  loads.push_back({topopt::fea_node_index(g, g.nx, g.ny, 0), 2, -10.0});
  return g;
}

std::vector<double> graded_moduli(const VoxelGrid& g) {
  return std::vector<double>(g.voxel_count(), 3500.0 * 0.6 * 0.6 * 0.6);
}

// Bit-for-bit equality. Deliberately NOT a tolerance: the claim being tested is
// that production is UNCHANGED, and "close" would not support it.
bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return false;
  return std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

double rel_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return 1.0;
  double num = 0.0, den = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const double d = a[i] - b[i];
    num += d * d;
    den += b[i] * b[i];
  }
  return den > 0.0 ? std::sqrt(num / den) : std::sqrt(num);
}

FeaSolution solve(const VoxelGrid& g, const std::vector<double>& ey,
                  const std::vector<DirichletBC>& bcs,
                  const std::vector<NodalLoad>& loads, CgInfo* info) {
  topopt::fea_matfree_reset_mg_stagnation_latch();
  topopt::fea_mg_reset_algebraic_level1_info();
  return topopt::fea_solve_mgcg_matfree(g, ey, 0.33, bcs, loads, 1e-8, 0, info);
}

}  // namespace

int main() {
  // ------------------------------------------------------------------
  // 1. THE TRIPWIRE — DISARMED in a default process.
  // ------------------------------------------------------------------
  check(!topopt::kMgAlgebraicLevel1LibraryDefaultOn,
        "the named library default constant says OFF");
  check(!topopt::fea_mg_algebraic_level1_enabled(),
        "algebraic level 1 is DISARMED in a default process");

  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  const VoxelGrid g = make_block(bcs, loads);
  const std::vector<double> ey = graded_moduli(g);

  CgInfo geo_info;
  const FeaSolution geo = solve(g, ey, bcs, loads, &geo_info);
  check(geo_info.used_multigrid, "geometric reference solve carries multigrid");
  const MgAlgebraicLevel1Info geo_stats = topopt::fea_mg_algebraic_level1_info();
  check(geo_stats.coarse_dim == 0 && geo_stats.aggregates == 0,
        "a disarmed solve reports no algebraic build at all");
  std::printf("      geometric: %d levels, %d cycles\n", geo_info.mg_levels,
              geo_info.iterations);

  // ------------------------------------------------------------------
  // 3 + 4. ARMED: the path BITES, and stays EXACT.
  // ------------------------------------------------------------------
  MgAlgebraicLevel1Info alg_stats;
  CgInfo alg_info;
  FeaSolution alg;
  {
    const bool prev = topopt::fea_set_mg_algebraic_level1(true);
    check(!prev, "the setter reports the previous state (OFF)");
    check(topopt::fea_mg_algebraic_level1_enabled(),
          "fea_set_mg_algebraic_level1(true) arms the path");
    alg = solve(g, ey, bcs, loads, &alg_info);
    alg_stats = topopt::fea_mg_algebraic_level1_info();
    topopt::fea_set_mg_algebraic_level1(false);
  }
  check(!alg_stats.refused, "the armed build was not refused on this fixture");
  check(alg_stats.aggregates > 0, "the armed build formed aggregates");
  check(alg_stats.coarse_dim > 0 && alg_stats.coarse_dim != geo_stats.coarse_dim,
        "the armed level-1 space is NOT the geometric one");
  // >= 2 (matrix-free fine + at least one coarse level), not >= 3: on a grid
  // whose algebraic level 1 already fits the solver's direct-solve cap, a
  // TWO-level cycle is the correct outcome, and it is the same fallback the
  // geometric builder takes in that situation.
  check(alg_stats.levels >= 2, "the armed hierarchy is usable (>= 2 levels)");
  check(alg_stats.bytes > 0, "the armed build reports what it added, in bytes");
  std::printf("      algebraic: %d levels, %d cycles, %d aggregates, "
              "coarse dim %d, %.1f MB\n",
              alg_info.mg_levels, alg_info.iterations, alg_stats.aggregates,
              alg_stats.coarse_dim,
              static_cast<double>(alg_stats.bytes) / (1024.0 * 1024.0));
  std::printf("      level dims:");
  for (int i = 0; i < alg_stats.level_count; ++i)
    std::printf(" %d", alg_stats.level_dim[i]);
  std::printf("\n");

  check(alg_info.used_multigrid, "the armed solve CARRIES multigrid");
  const double rel = rel_diff(alg.u, geo.u);
  // The two solves stop on the same 1e-8 relative-residual test but land at
  // different points inside that basin, so the bar is the basin, not bit parity.
  check(rel < 1e-6, "the armed solve reaches the SAME field as the geometric one");
  std::printf("      worst relative field deviation: %.3e\n", rel);

  // ------------------------------------------------------------------
  // 2. ARM-THEN-DISARM LEAVES NO TRACE — THE ONE RULE, executable.
  // ------------------------------------------------------------------
  {
    CgInfo info;
    const FeaSolution after = solve(g, ey, bcs, loads, &info);
    check(bit_identical(after.u, geo.u),
          "a solve after arm+disarm is BIT-IDENTICAL to one before arming");
    check(info.mg_levels == geo_info.mg_levels &&
              info.iterations == geo_info.iterations,
          "arm+disarm leaves the hierarchy and cycle count unchanged");
  }

  // ------------------------------------------------------------------
  // 6. DETERMINISM — two armed setups agree exactly.
  // ------------------------------------------------------------------
  {
    topopt::fea_set_mg_algebraic_level1(true);
    CgInfo info;
    const FeaSolution again = solve(g, ey, bcs, loads, &info);
    const MgAlgebraicLevel1Info s2 = topopt::fea_mg_algebraic_level1_info();
    topopt::fea_set_mg_algebraic_level1(false);
    check(s2.aggregates == alg_stats.aggregates &&
              s2.coarse_dim == alg_stats.coarse_dim &&
              s2.level_count == alg_stats.level_count,
          "two armed setups produce the SAME aggregation");
    bool dims_equal = true;
    for (int i = 0; i < s2.level_count; ++i)
      if (s2.level_dim[i] != alg_stats.level_dim[i]) dims_equal = false;
    check(dims_equal, "two armed setups produce the same level dimensions");
    check(bit_identical(again.u, alg.u),
          "two armed solves are BIT-IDENTICAL to each other");
    check(info.iterations == alg_info.iterations,
          "two armed solves take the same cycle count");
  }

  // ------------------------------------------------------------------
  // 5. A REFUSAL FALLS BACK CLEANLY, and SAYS SO.
  //
  // Forced DETERMINISTICALLY rather than left to a fixture that might coarsen:
  // the POINT-BLOCK smoother needs a nodal structure a general aggregation does
  // not have below level 1, so the algebraic builder refuses it outright. That
  // is a refusal the test can rely on firing on every machine and every grid,
  // which is what makes the bit-identity claim below worth anything.
  // ------------------------------------------------------------------
  {
    topopt::fea_detail::MgTuning t;
    t.smoother = topopt::fea_detail::MgSmoother::PointBlockJacobi;
    topopt::fea_detail::mg_set_tuning(t);

    CgInfo off_info;
    const FeaSolution off = solve(g, ey, bcs, loads, &off_info);

    topopt::fea_set_mg_algebraic_level1(true);
    CgInfo on_info;
    const FeaSolution on = solve(g, ey, bcs, loads, &on_info);
    const MgAlgebraicLevel1Info s = topopt::fea_mg_algebraic_level1_info();
    topopt::fea_set_mg_algebraic_level1(false);
    topopt::fea_detail::mg_reset_tuning();

    check(s.refused, "the point-block smoother REFUSES the algebraic path");
    std::printf("      refusal reason: %s\n", s.refuse_reason);
    check(s.refuse_reason[0] != '\0',
          "a refusal REPORTS its reason rather than failing silently");
    check(bit_identical(on.u, off.u),
          "a REFUSED armed solve is BIT-IDENTICAL to the disarmed one "
          "(the geometric builder ran)");
    check(on_info.mg_levels == off_info.mg_levels &&
              on_info.iterations == off_info.iterations,
          "a refusal leaves the hierarchy and cycle count unchanged");
  }

  // A SMALL system: the algebraic level 1 already fits the solver's
  // direct-solve cap, so the correct outcome is a TWO-level cycle, not a
  // refusal — the same fallback the geometric builder takes there. Asserted
  // because getting it wrong is silent: the path would simply decline on every
  // small grid and nobody would notice.
  {
    std::vector<DirichletBC> tb;
    std::vector<NodalLoad> tl;
    const VoxelGrid tg = make_tiny(tb, tl);
    const std::vector<double> tey = graded_moduli(tg);

    CgInfo off_info;
    const FeaSolution off = solve(tg, tey, tb, tl, &off_info);

    topopt::fea_set_mg_algebraic_level1(true);
    CgInfo on_info;
    const FeaSolution on = solve(tg, tey, tb, tl, &on_info);
    const MgAlgebraicLevel1Info s = topopt::fea_mg_algebraic_level1_info();
    topopt::fea_set_mg_algebraic_level1(false);

    check(!s.refused && s.levels == 2,
          "a small system yields a TWO-level algebraic cycle, not a refusal");
    std::printf("      small system: level-1 dim %d, %d levels\n", s.coarse_dim,
                s.levels);
    check(rel_diff(on.u, off.u) < 1e-6,
          "the small system's armed solve reaches the same field");
  }

  // The flag must be back OFF however the bars above went, or a later test in
  // the same process would inherit an armed solver.
  check(!topopt::fea_mg_algebraic_level1_enabled(),
        "the path is DISARMED again at the end of the test");

  if (g_failures == 0) {
    std::printf("\nAll algebraic-level-1 tripwire checks passed.\n");
    return 0;
  }
  std::printf("\n%d check(s) FAILED.\n", g_failures);
  return 1;
}
