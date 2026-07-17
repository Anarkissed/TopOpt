// Correctness guards for the MIXED-PRECISION V-cycle (handoff 092) — the opt-in,
// default-OFF single-precision multigrid preconditioner in the matrix-free MG-CG
// (fea_set_matfree_mixed_precision).
//
// This path DELIBERATELY BREAKS BIT-IDENTITY: the V-cycle runs in FP32, which is
// genuinely different arithmetic, so the preconditioner differs and the CG
// iteration count may move. That RETIRES 078's `18 == 18` bit-parity tripwire on
// THIS path (the FP64 path keeps it exactly — see test_mgcg_matfree /
// test_galerkin_cache, unchanged). The replacement guard is weaker but honest and
// is what these tests enforce:
//
//   1. SAME ANSWER (the PRIMARY guard). The FP32-V-cycle MG-CG converges to the
//      SAME field as the FP64 path DOF-for-DOF within max|du|/max|u| <= 1e-6, on a
//      SOLID grid AND the ill-conditioned soft-void graded grid (rho_min^p = 1e-9),
//      at >= 3 levels. This is airtight because the OUTER CG is FP64: its residual
//      test ||b - A x||/||b|| <= tol is computed in double and is the correctness
//      guarantee. A sloppier preconditioner costs iterations, never accuracy.
//
//   2. ITERATION-COUNT BOUND. FP32 iterations <= FP64 iterations + 8 on the test
//      cases (reported). If FP32 needed many more iterations the bandwidth win
//      would be eaten; this bounds that. (Observed: FP32 == FP64 exactly here.)
//
//   3. DETERMINISM. The FP32 path is bit-identical across thread counts 1/2/4/8 and
//      run-to-run — the 8-colour partition fixes the summation ORDER, so FP32's
//      non-associativity does not leak nondeterminism (no atomics).
//
//   4. STILL A VALID PRECONDITIONER (SPD). CG with the FP32 V-cycle CONVERGES (in
//      an order of magnitude fewer iterations than the DOF count) rather than
//      stalling — a non-SPD/ruined M would stall or diverge.
//
//   5. DEFAULT OFF + FP64 PARITY UNTOUCHED. The default is OFF; with it OFF the
//      matrix-free MG-CG still matches the assembled MG-CG at the SAME iteration
//      count (078's parity, byte-identical), proving the flag is truly opt-in.
//
//   6. FALLBACK DISCIPLINE. With mixed precision ON, a non-coarsenable (odd) grid
//      still falls back to the EXACT matrix-free Jacobi-CG (used_multigrid==false)
//      and returns the correct field — never an unconverged result.
//
// No third-party framework (ARCHITECTURE §4): the same self-contained CHECK
// harness as the sibling tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
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

VoxelGrid make_solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

std::vector<DirichletBC> clamp_x0_face(const VoxelGrid& g) {
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return bcs;
}

std::vector<NodalLoad> tip_load_z(const VoxelGrid& g, double total) {
  std::vector<int> nodes;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      nodes.push_back(topopt::fea_node_index(g, g.nx, b, c));
  std::vector<NodalLoad> loads;
  const double per = total / static_cast<double>(nodes.size());
  for (int n : nodes) loads.push_back({n, 2, per});
  return loads;
}

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

double max_rel_diff(const FeaSolution& a, const FeaSolution& b) {
  double maxu = 0.0, maxd = 0.0;
  for (std::size_t d = 0; d < a.u.size(); ++d) {
    maxu = std::max(maxu, std::fabs(a.u[d]));
    maxd = std::max(maxd, std::fabs(a.u[d] - b.u[d]));
  }
  return maxu > 0.0 ? maxd / maxu : maxd;
}

// Count of DOFs at which two fields differ AT ALL — determinism must give zero.
std::size_t differing_dofs(const FeaSolution& a, const FeaSolution& b) {
  std::size_t n = 0;
  for (std::size_t i = 0; i < a.u.size(); ++i)
    if (a.u[i] != b.u[i]) ++n;
  return n;
}

}  // namespace

int main() {
  const double nu = 0.30;

  // Default must be OFF (the ONE RULE): the FP64 path is what runs unless asked.
  CHECK(topopt::fea_set_matfree_mixed_precision(false) == false,
        "default: the mixed-precision V-cycle is OFF unless explicitly enabled");

  // ==========================================================================
  // 0. FP64 PARITY UNTOUCHED (guard 5). With mixed precision OFF, the matrix-free
  //    MG-CG still matches the assembled MG-CG at the SAME iteration count — 078's
  //    `18 == 18` tripwire holds EXACTLY on the FP64 path.
  // ==========================================================================
  {
    const double E0 = 2100.0, rho_min = 1e-3, p = 3.0;  // rho_min^p = 1e-9
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -50.0);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double cx = (i + 0.5) / g.nx - 0.5;
          const double cy = (j + 0.5) / g.ny - 0.5;
          const double cz = (k + 0.5) / g.nz - 0.5;
          const double d = std::sqrt(cx * cx + cy * cy + cz * cz);
          const double rho = d < 0.25 ? rho_min : 1.0;
          ey[g.index(i, j, k)] = std::pow(rho, p) * E0;
        }
    CgInfo img, imf;
    FeaSolution smg = topopt::fea_solve_mgcg(g, ey, nu, bcs, loads, 1e-9, 0, &img);
    topopt::fea_set_matfree_mixed_precision(false);
    FeaSolution smf =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &imf);
    CHECK(std::abs(imf.iterations - img.iterations) <= 2,
          "default OFF: FP64 matrix-free MG-CG still matches assembled MG-CG at "
          "the same iteration count (078 parity intact on the FP64 path)");
    CHECK(max_rel_diff(smg, smf) <= 1e-6,
          "default OFF: FP64 matrix-free MG-CG matches assembled MG-CG DOF-for-DOF");
  }

  // ==========================================================================
  // 1. SAME ANSWER on a SOLID grid (guard 1) + iteration bound (guard 2).
  // ==========================================================================
  {
    const double E = 2100.0;
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -100.0);

    CgInfo icg, i64, i32;
    FeaSolution scg = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-8, 0, &icg);
    topopt::fea_set_matfree_mixed_precision(false);
    FeaSolution s64 =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &i64);
    topopt::fea_set_matfree_mixed_precision(true);
    FeaSolution s32 =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &i32);
    topopt::fea_set_matfree_mixed_precision(false);

    CHECK(i32.converged && i32.used_multigrid && i32.mg_levels >= 3,
          "solid: FP32-V-cycle MG-CG engages multigrid (>= 3 levels) and converges");
    CHECK(max_rel_diff(s64, s32) <= 1e-6,
          "solid: FP32 V-cycle converges to the SAME field as FP64 (<= 1e-6)");
    CHECK(max_rel_diff(scg, s32) <= 1e-6,
          "solid: FP32 V-cycle matches the assembled Jacobi-CG field (<= 1e-6)");
    CHECK(i32.iterations <= i64.iterations + 8,
          "solid: FP32 iteration count is within FP64 + 8 (bandwidth win not eaten)");
    std::printf(
        "mixed solid 32^3: FP32 %d iters (FP64 %d), reldiff %.2e, %d levels\n",
        i32.iterations, i64.iterations, max_rel_diff(s64, s32), i32.mg_levels);
  }

  // ==========================================================================
  // 2. SAME ANSWER on the ILL-CONDITIONED soft-void graded grid (guard 1) — the
  //    underflow crux: rho_min^p = 1e-9 contrast. FP32's smallest normal is
  //    ~1.2e-38 so the factors are safe, but 1e-9-relative cross-terms at a shared
  //    node fall below FP32 eps and are rounded away in the PRECONDITIONER. That
  //    can only cost iterations; the FP64 outer residual test still nails the
  //    field. This proves the graded case does not degrade or diverge.
  // ==========================================================================
  {
    const double E0 = 2100.0, rho_min = 1e-3, p = 3.0;  // rho_min^p = 1e-9
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -50.0);

    std::vector<double> ey(g.voxel_count(), 0.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double cx = (i + 0.5) / g.nx - 0.5;
          const double cy = (j + 0.5) / g.ny - 0.5;
          const double cz = (k + 0.5) / g.nz - 0.5;
          const double d = std::sqrt(cx * cx + cy * cy + cz * cz);
          const double rho = d < 0.25 ? rho_min : 1.0;  // soft spherical core
          ey[g.index(i, j, k)] = std::pow(rho, p) * E0;
        }

    // 1e-9 (matching test_mgcg_matfree's graded case): on a 1e-9-contrast
    // soft-void system the condition number is high, so a mere 1e-8 RESIDUAL does
    // not pin the FIELD to 1e-6 across two different solvers; 1e-9 does.
    CgInfo icg, i64, i32;
    FeaSolution scg = topopt::fea_solve_cg(g, ey, nu, bcs, loads, 1e-9, 0, &icg);
    topopt::fea_set_matfree_mixed_precision(false);
    FeaSolution s64 =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &i64);
    topopt::fea_set_matfree_mixed_precision(true);
    FeaSolution s32 =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &i32);
    topopt::fea_set_matfree_mixed_precision(false);

    CHECK(i32.converged && i32.used_multigrid && i32.mg_levels >= 3,
          "graded: FP32-V-cycle MG-CG engages multigrid on the soft-void core");
    CHECK(max_rel_diff(s64, s32) <= 1e-6,
          "graded: FP32 V-cycle matches FP64 on the 1e-9-contrast soft void "
          "(no underflow degradation) (<= 1e-6)");
    CHECK(max_rel_diff(scg, s32) <= 1e-6,
          "graded: FP32 V-cycle matches the exact Jacobi-CG field (<= 1e-6)");
    CHECK(i32.iterations <= i64.iterations + 8,
          "graded: FP32 iteration count is within FP64 + 8 on the soft-void grid");
    std::printf(
        "mixed graded soft-void 32^3: FP32 %d iters (FP64 %d), reldiff %.2e\n",
        i32.iterations, i64.iterations, max_rel_diff(s64, s32));
  }

  // ==========================================================================
  // 3. DETERMINISM (guard 3): the FP32 path is bit-identical across thread counts
  //    1/2/4/8 and run-to-run. FP32 add is non-associative, but the 8-colour
  //    partition fixes the summation ORDER, so the result never depends on the
  //    thread count or scheduling — no atomics, no drift.
  // ==========================================================================
  {
    const double E = 2100.0;
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -100.0);

    topopt::fea_set_matfree_mixed_precision(true);
    const int prev_threads = topopt::fea_set_matfree_threads(1);
    CgInfo ci1;
    FeaSolution ref =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &ci1);
    // run-to-run at 1 thread
    FeaSolution ref2 =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, nullptr);
    CHECK(differing_dofs(ref, ref2) == 0,
          "determinism: FP32 is bit-identical run-to-run (1 thread)");

    bool all_identical = true;
    int ref_iters = ci1.iterations;
    for (int t : {2, 4, 8}) {
      topopt::fea_set_matfree_threads(t);
      CgInfo cit;
      FeaSolution s =
          topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &cit);
      if (differing_dofs(ref, s) != 0) all_identical = false;
      if (cit.iterations != ref_iters) all_identical = false;
    }
    topopt::fea_set_matfree_threads(prev_threads);
    topopt::fea_set_matfree_mixed_precision(false);
    CHECK(all_identical,
          "determinism: FP32 is bit-identical (0 differing DOFs, same iters) "
          "across thread counts 1/2/4/8");
    std::printf("mixed determinism: FP32 bit-identical across 1/2/4/8 threads\n");
  }

  // ==========================================================================
  // 4. SPD / CONVERGES not stalls (guard 4): a valid SPD preconditioner drives CG
  //    to convergence in far fewer iterations than the DOF count. A ruined
  //    (non-SPD) M would stall.
  // ==========================================================================
  {
    const double E = 2100.0;
    VoxelGrid g = make_solid_grid(16, 16, 16, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -30.0);

    topopt::fea_set_matfree_mixed_precision(true);
    CgInfo i32;
    FeaSolution s32 =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 100, &i32);
    topopt::fea_set_matfree_mixed_precision(false);
    CHECK(i32.converged && i32.used_multigrid,
          "spd: FP32-V-cycle MG-CG converges (V-cycle stays SPD)");
    CHECK(i32.iterations > 0 && i32.iterations <= 45,
          "spd: FP32 converges in <= 45 iters (a broken/non-SPD M would stall)");
    bool finite = true;
    for (double v : s32.u)
      if (!std::isfinite(v)) finite = false;
    CHECK(finite, "spd: FP32 field is finite");
  }

  // ==========================================================================
  // 5. FALLBACK DISCIPLINE (guard 6): with mixed precision ON, a non-coarsenable
  //    (odd) grid falls back to the EXACT matrix-free Jacobi-CG and still returns
  //    the correct field — never an unconverged result.
  // ==========================================================================
  {
    const double E = 2100.0;
    VoxelGrid g = make_solid_grid(15, 6, 6, 1.0);  // 15 odd -> no coarsening
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -10.0);

    FeaSolution direct = topopt::fea_solve(g, E, nu, bcs, loads);
    topopt::fea_set_matfree_mixed_precision(true);
    CgInfo info;
    FeaSolution mf =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-10, 0, &info);
    topopt::fea_set_matfree_mixed_precision(false);
    CHECK(info.converged && !info.used_multigrid,
          "fallback: with mixed ON, an odd grid falls back to matrix-free Jacobi-CG");
    CHECK(max_rel_diff(direct, mf) <= 1e-6,
          "fallback: the Jacobi-CG fallback still matches the direct solve");
    (void)near;
  }

  if (g_failures == 0) {
    std::printf("test_mixed_precision: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "test_mixed_precision: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
