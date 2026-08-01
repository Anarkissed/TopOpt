// TRIPWIRE for the multigrid COARSE-SPACE SEAM (task: hybrid-amg-coarsening-probe).
//
// That task added ONE seam to the solver: build_mf_hierarchy may take the
// prolongators for levels 2.. from a harness-installed hook instead of building
// them by halving the grid. It changed NO default and armed NOTHING. This file
// is what makes that claim checkable, and it asserts four separate things:
//
//   1. THE SEAM IS UNINSTALLED BY DEFAULT. A process that never touches the
//      setter reports `mg_coarse_space_hook_installed() == false`, so
//      build_mf_hierarchy takes the geometric branch it always has. A probe that
//      forgot to clear its hook would fail here.
//   2. AN INSTALLED-THEN-CLEARED HOOK LEAVES NO TRACE. The solve after
//      install+decline+clear is BIT-IDENTICAL to one taken before the hook ever
//      existed — compared as raw doubles, not "close enough".
//   3. THE SOLVER DOES NOT TRUST THE HOOK. A malformed prolongator (wrong row
//      count, out-of-range index, empty) is REJECTED and the geometric hierarchy
//      is built instead, again bit-identically. A hook cannot make the solver do
//      something unsound; at worst it declines to help.
//   4. THE SEAM ACTUALLY BITES, AND STAYS EXACT. A valid non-geometric
//      prolongator changes the hierarchy the solver builds (a different coarse
//      dimension, a different cycle count) and still reaches the SAME
//      displacement field — which is structurally guaranteed, since R = P^T and
//      an SPD bottom solve keep the cycle a valid CG preconditioner whatever P
//      is, and the outer FP64 CG's residual test is what defines convergence.
//      A seam that silently did nothing would make the whole probe a measurement
//      of noise, so this is asserted rather than assumed.
//
// Same self-contained CHECK harness as the other unit tests (ARCHITECTURE §4:
// no third-party framework).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::fea_detail::MgCoarseSeam;
using topopt::fea_detail::MgCoo;

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

// A small, well-connected cantilever the multigrid carries comfortably, and
// whose grid coarsens deep enough that levels 2.. genuinely exist — which is
// what makes the seam reachable at all.
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

std::vector<double> graded_moduli(const VoxelGrid& g) {
  std::vector<double> ey(g.voxel_count(), 3500.0 * 0.6 * 0.6 * 0.6);
  return ey;
}

// Bit-for-bit equality of two displacement fields. Deliberately NOT a tolerance:
// the claim being tested is that production is UNCHANGED, and "close" would not
// support it.
bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return false;
  return std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

// A valid, deliberately NON-GEOMETRIC prolongator: level-1 DOFs are grouped into
// consecutive blocks of `chunk` NODES (3 DOFs each), one coarse DOF per (block,
// component), with weight 1. Disjoint supports and unit entries make it full
// column rank, so P^T A1 P stays SPD — exactly the piecewise-constant tentative
// prolongator an aggregation produces, with a trivially chosen aggregation.
MgCoo chunk_prolongator(int n1, int chunk) {
  MgCoo P;
  P.rows = n1;
  const int nnodes = (n1 + 2) / 3;
  const int naggs = (nnodes + chunk - 1) / chunk;
  P.cols = naggs * 3;
  for (int i = 0; i < n1; ++i) {
    const int node = i / 3, comp = i % 3;
    P.row.push_back(i);
    P.col.push_back((node / chunk) * 3 + comp);
    P.val.push_back(1.0);
  }
  return P;
}

FeaSolution solve(const VoxelGrid& g, const std::vector<double>& ey,
                  const std::vector<DirichletBC>& bcs,
                  const std::vector<NodalLoad>& loads, CgInfo* info) {
  topopt::fea_matfree_reset_mg_stagnation_latch();
  return topopt::fea_solve_mgcg_matfree(g, ey, 0.33, bcs, loads, 1e-8, 0, info);
}

}  // namespace

int main() {
  // ------------------------------------------------------------------
  // 1. THE TRIPWIRE — the seam is UNINSTALLED in a default process.
  // ------------------------------------------------------------------
  check(!topopt::fea_detail::mg_coarse_space_hook_installed(),
        "no coarse-space hook is installed by default");

  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  const VoxelGrid g = make_block(bcs, loads);
  const std::vector<double> ey = graded_moduli(g);

  CgInfo ref_info;
  const FeaSolution ref = solve(g, ey, bcs, loads, &ref_info);
  check(ref_info.used_multigrid, "reference solve carries multigrid");
  check(ref_info.mg_levels >= 3,
        "the reference hierarchy has levels BELOW level 1 (the seam is reachable)");
  std::printf("      reference: %d levels, %d cycles\n", ref_info.mg_levels,
              ref_info.iterations);

  // ------------------------------------------------------------------
  // 2. A DECLINING HOOK CHANGES NOTHING — and the seam is genuinely reached.
  // ------------------------------------------------------------------
  int seen = 0;
  int n1_seen = 0, p0_rows = 0, p0_cols = 0;
  {
    topopt::fea_detail::mg_set_coarse_space_hook(
        [&](const MgCoarseSeam& s) -> std::vector<MgCoo> {
          ++seen;
          n1_seen = s.n1;
          p0_rows = s.p0.rows;
          p0_cols = s.p0.cols;
          return {};  // decline
        });
    check(topopt::fea_detail::mg_coarse_space_hook_installed(),
          "mg_set_coarse_space_hook installs the hook");
    CgInfo info;
    const FeaSolution sol = solve(g, ey, bcs, loads, &info);
    check(seen > 0, "the solver REACHES the coarse-space seam");
    check(n1_seen > 0 && p0_rows > n1_seen && p0_cols == n1_seen,
          "the seam hands out a level-1 operator and a matching P0 "
          "(fine rows > coarse cols)");
    std::printf("      seam: n1 = %d, P0 = %d x %d\n", n1_seen, p0_rows, p0_cols);
    check(bit_identical(sol.u, ref.u),
          "a DECLINING hook leaves the solve BIT-IDENTICAL");
    check(info.mg_levels == ref_info.mg_levels &&
              info.iterations == ref_info.iterations,
          "a declining hook leaves the hierarchy and cycle count unchanged");
  }

  // ------------------------------------------------------------------
  // 3. THE SOLVER DOES NOT TRUST THE HOOK — every malformed return falls back
  //    to the geometric hierarchy, bit-identically.
  // ------------------------------------------------------------------
  {
    struct Bad {
      const char* what;
      int mode;
    };
    const Bad bads[] = {
        {"a prolongator with the WRONG row count is rejected", 0},
        {"a prolongator with an OUT-OF-RANGE index is rejected", 1},
        {"an EMPTY prolongator is rejected", 2},
        {"a prolongator that does not SHRINK the level is rejected", 3},
        {"ragged row/col/val arrays are rejected", 4},
    };
    for (const Bad& b : bads) {
      const int mode = b.mode;
      topopt::fea_detail::mg_set_coarse_space_hook(
          [mode](const MgCoarseSeam& s) -> std::vector<MgCoo> {
            MgCoo P = chunk_prolongator(s.n1, 8);
            switch (mode) {
              case 0: P.rows = s.n1 + 7; break;
              case 1: P.col[0] = P.cols + 100; break;
              case 2: P.row.clear(); P.col.clear(); P.val.clear(); break;
              case 3: P.cols = s.n1; break;
              case 4: P.val.pop_back(); break;
              default: break;
            }
            return {P};
          });
      CgInfo info;
      const FeaSolution sol = solve(g, ey, bcs, loads, &info);
      check(bit_identical(sol.u, ref.u) &&
                info.mg_levels == ref_info.mg_levels &&
                info.iterations == ref_info.iterations,
            b.what);
    }
  }

  // ------------------------------------------------------------------
  // 4. THE SEAM BITES, AND STAYS EXACT.
  // ------------------------------------------------------------------
  {
    topopt::fea_detail::mg_set_coarse_space_hook(
        [](const MgCoarseSeam& s) -> std::vector<MgCoo> {
          // One non-geometric level, coarse enough to be under the direct-solve
          // cap so the solver accepts the hierarchy.
          int chunk = 8;
          const int nnodes = (s.n1 + 2) / 3;
          while (((nnodes + chunk - 1) / chunk) * 3 > 6000) chunk *= 2;
          return {chunk_prolongator(s.n1, chunk)};
        });
    CgInfo info;
    const FeaSolution sol = solve(g, ey, bcs, loads, &info);
    check(info.hier_built, "the hybrid hierarchy BUILDS");
    check(info.mg_levels != ref_info.mg_levels ||
              info.iterations != ref_info.iterations,
          "a valid non-geometric coarse space CHANGES the hierarchy the solver runs");
    std::printf("      hybrid: %d levels, %d cycles, carried %s\n",
                info.mg_levels, info.iterations,
                info.used_multigrid ? "YES" : "no");
    double worst = 0.0, scale = 0.0;
    for (std::size_t i = 0; i < ref.u.size(); ++i) {
      worst = std::max(worst, std::fabs(sol.u[i] - ref.u[i]));
      scale = std::max(scale, std::fabs(ref.u[i]));
    }
    std::printf("      hybrid vs shipped: worst |du| = %.3e (rel %.3e)\n", worst,
                scale > 0 ? worst / scale : 0.0);
    check(scale > 0 && worst / scale < 1e-6,
          "a hybrid coarse space reaches the SAME field as the geometric one");
  }

  // ------------------------------------------------------------------
  // 5. CLEARING RESTORES THE SHIPPED PATH, BIT-FOR-BIT.
  // ------------------------------------------------------------------
  {
    topopt::fea_detail::mg_set_coarse_space_hook({});
    check(!topopt::fea_detail::mg_coarse_space_hook_installed(),
          "a default-constructed hook CLEARS the seam");
    CgInfo info;
    const FeaSolution sol = solve(g, ey, bcs, loads, &info);
    check(bit_identical(sol.u, ref.u) &&
              info.mg_levels == ref_info.mg_levels &&
              info.iterations == ref_info.iterations,
          "after clearing, the solve is BIT-IDENTICAL to the pre-hook reference");
  }

  if (g_failures) {
    std::printf("\n%d check(s) FAILED\n", g_failures);
    return 1;
  }
  std::printf("\nall checks passed\n");
  return 0;
}
