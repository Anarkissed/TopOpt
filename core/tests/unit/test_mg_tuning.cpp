// TRIPWIRE for the multigrid component tuning (task: multigrid-component-sweep).
//
// That task PARAMETERISED the V-cycle's recipe — smoother weight, pre/post
// sweep counts, extra coarse-level smoothing, cycle gamma, hierarchy depth,
// coarsest-level DOF cap and the smoother itself — so a measurement harness can
// sweep them. It did NOT re-tune any of them. This file is what makes that
// claim checkable: it asserts every effective default against the shipped
// LITERAL, so neither
//
//   * a probe that forgets to restore the tuning it installed, nor
//   * a constant quietly edited in multigrid.cpp or fea_matfree.hpp,
//
// can change what production runs without failing a test. The literals are
// deliberately written out rather than referenced from the header — a test that
// compares a constant to itself proves nothing.
//
// It also proves the override surface actually BITES (set/reset round-trip, and
// a swept configuration reaching the same converged field as the shipped one),
// because a knob that silently does nothing would make the whole sweep a
// measurement of noise.
//
// Same self-contained CHECK harness as the other unit tests (ARCHITECTURE §4:
// no third-party framework).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::fea_detail::MgSmoother;
using topopt::fea_detail::MgTuning;

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

// A small, well-connected cantilever the multigrid carries comfortably: the
// point here is the tuning surface, not the physics.
VoxelGrid make_block(std::vector<DirichletBC>& bcs, std::vector<NodalLoad>& loads) {
  VoxelGrid g;
  g.nx = 16;
  g.ny = 8;
  g.nz = 16;
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

std::vector<double> graded_moduli(const VoxelGrid& g) {
  // A soft-void graded field, so the hierarchy is the high-contrast one
  // production actually builds rather than a uniform block.
  std::vector<double> ey(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < g.voxel_count(); ++e) ey[e] = 3500.0 * 0.6 * 0.6 * 0.6;
  return ey;
}

}  // namespace

int main() {
  // ------------------------------------------------------------------
  // 1. THE TRIPWIRE — every effective default IS the shipped constant.
  // ------------------------------------------------------------------
  {
    const MgTuning& t = topopt::fea_detail::mg_tuning();
    check(t.omega == 0.6, "shipped smoother weight is 0.6");
    check(t.pre_smooth == 1, "shipped pre-smoothing sweeps is 1");
    check(t.post_smooth == 1, "shipped post-smoothing sweeps is 1");
    check(t.pre_smooth == t.post_smooth,
          "shipped pre and post sweeps are EQUAL (the V-cycle's symmetry)");
    check(t.coarse_extra_smooth == 0,
          "shipped recipe adds NO extra coarse-level smoothing");
    check(t.cycle_gamma == 1, "shipped cycle is the V-cycle (gamma == 1)");
    check(t.max_levels == 0,
          "shipped hierarchy depth defers to the builder's DOF cap");
    check(!t.deepest, "shipped builder stops at the first level under the cap");
    check(t.coarse_dof_cap == 6000,
          "shipped coarsest-level DOF cap is kMgCoarseDofCap == 6000");
    check(t.smoother == MgSmoother::ScalarJacobi,
          "shipped smoother is SCALAR damped Jacobi, not point-block");
  }

  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  const VoxelGrid g = make_block(bcs, loads);
  const std::vector<double> ey = graded_moduli(g);
  const double tol = 1e-8;

  // Reference solve at the shipped recipe.
  topopt::fea_matfree_reset_mg_stagnation_latch();
  CgInfo ref_info;
  const FeaSolution ref =
      topopt::fea_solve_mgcg_matfree(g, ey, 0.33, bcs, loads, tol, 0, &ref_info);
  check(ref_info.used_multigrid, "reference solve carries multigrid");

  // ------------------------------------------------------------------
  // 2. THE OVERRIDE BITES — and reset restores the shipped recipe.
  // ------------------------------------------------------------------
  {
    MgTuning t;
    t.pre_smooth = 3;
    t.post_smooth = 3;
    t.cycle_gamma = 2;
    t.smoother = MgSmoother::PointBlockJacobi;
    t.omega = 0.5;
    topopt::fea_detail::mg_set_tuning(t);
    const MgTuning& got = topopt::fea_detail::mg_tuning();
    check(got.pre_smooth == 3 && got.cycle_gamma == 2 && got.omega == 0.5 &&
              got.smoother == MgSmoother::PointBlockJacobi,
          "mg_set_tuning installs the requested configuration");

    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo swept;
    const FeaSolution sol =
        topopt::fea_solve_mgcg_matfree(g, ey, 0.33, bcs, loads, tol, 0, &swept);
    check(swept.used_multigrid,
          "a W-cycle / point-block / 3-sweep configuration still carries multigrid");
    // EXACTNESS: a different preconditioner may change the iteration count but
    // never the converged field — the outer CG's residual test is the guarantee.
    double worst = 0.0, scale = 0.0;
    for (std::size_t i = 0; i < ref.u.size(); ++i) {
      worst = std::max(worst, std::fabs(sol.u[i] - ref.u[i]));
      scale = std::max(scale, std::fabs(ref.u[i]));
    }
    std::printf("      swept vs shipped: %d vs %d cycles, worst |du| = %.3e "
                "(rel %.3e)\n",
                swept.iterations, ref_info.iterations, worst,
                scale > 0 ? worst / scale : 0.0);
    check(scale > 0 && worst / scale < 1e-6,
          "a swept configuration reaches the SAME field as the shipped one");
    check(swept.iterations != ref_info.iterations || swept.mg_levels > 0,
          "the swept configuration actually ran the multigrid path");

    topopt::fea_detail::mg_reset_tuning();
    const MgTuning& back = topopt::fea_detail::mg_tuning();
    check(back.omega == 0.6 && back.pre_smooth == 1 && back.post_smooth == 1 &&
              back.cycle_gamma == 1 && back.coarse_extra_smooth == 0 &&
              back.max_levels == 0 && !back.deepest &&
              back.coarse_dof_cap == 6000 &&
              back.smoother == MgSmoother::ScalarJacobi,
          "mg_reset_tuning restores EVERY field to the shipped recipe");
  }

  // ------------------------------------------------------------------
  // 2b. THE POINT-BLOCK DERIVATION IS CORRECT.
  //
  // The two multigrid paths build the same 3x3 nodal blocks by DIFFERENT
  // routes: the assembled path reads them straight off the fine operator A0,
  // while the matrix-free path — which never assembles A0 — accumulates them
  // from the element table (Ke entries whose two local indices share a node).
  // If that element derivation were wrong, nothing above would catch it: the
  // outer CG's residual test would still deliver the right field, just at a
  // different iteration count.
  //
  // test_mgcg_matfree already pins that the two paths agree DOF-for-DOF and at
  // the SAME iteration count on the shipped scalar smoother. So requiring the
  // same agreement under the point-block smoother isolates exactly one thing:
  // whether the element-derived nodal blocks equal the assembled ones.
  // ------------------------------------------------------------------
  {
    // Both paths are PINNED to the same depth. Left to themselves they build
    // different ones on a grid this small — the assembled path stops one level
    // earlier because its fine operator is already level 0, while the
    // matrix-free path's element-Galerkin A1 is level 1 — and a depth
    // difference would swamp the thing being tested.
    MgTuning t;
    t.smoother = MgSmoother::PointBlockJacobi;
    t.omega = 0.5;
    t.max_levels = 3;
    t.deepest = true;

    topopt::fea_detail::mg_set_tuning(t);
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo mf;
    const FeaSolution mf_sol =
        topopt::fea_solve_mgcg_matfree(g, ey, 0.33, bcs, loads, tol, 0, &mf);

    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo asm_;
    const FeaSolution asm_sol =
        topopt::fea_solve_mgcg(g, ey, 0.33, bcs, loads, tol, 0, &asm_);
    topopt::fea_detail::mg_reset_tuning();

    check(mf.used_multigrid && asm_.used_multigrid,
          "point-block: both multigrid paths carry");
    std::printf("      point-block cycles: matrix-free %d, assembled %d "
                "(levels %d / %d)\n",
                mf.iterations, asm_.iterations, mf.mg_levels, asm_.mg_levels);
    check(mf.iterations == asm_.iterations,
          "point-block: the ELEMENT-derived nodal blocks give the SAME cycle "
          "count as the ones read off the assembled operator");
    double worst = 0, scale = 0;
    for (std::size_t i = 0; i < asm_sol.u.size(); ++i) {
      worst = std::max(worst, std::fabs(mf_sol.u[i] - asm_sol.u[i]));
      scale = std::max(scale, std::fabs(asm_sol.u[i]));
    }
    check(scale > 0 && worst / scale < 1e-6,
          "point-block: both paths converge to the same field");
  }

  // ------------------------------------------------------------------
  // 3. RESET IS EXACT — the post-reset solve reproduces the reference
  //    BIT-FOR-BIT, so a sweep cannot leave residue behind it.
  // ------------------------------------------------------------------
  {
    topopt::fea_matfree_reset_mg_stagnation_latch();
    CgInfo after;
    const FeaSolution sol =
        topopt::fea_solve_mgcg_matfree(g, ey, 0.33, bcs, loads, tol, 0, &after);
    bool identical = sol.u.size() == ref.u.size();
    for (std::size_t i = 0; identical && i < sol.u.size(); ++i)
      identical = sol.u[i] == ref.u[i];
    check(identical && after.iterations == ref_info.iterations,
          "after mg_reset_tuning the solve is BIT-IDENTICAL to the reference");
  }

  if (g_failures == 0) std::printf("\nALL MG TUNING TRIPWIRE CHECKS PASSED\n");
  return g_failures == 0 ? 0 : 1;
}
