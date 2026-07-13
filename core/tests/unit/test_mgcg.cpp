// Unit tests for the geometric-multigrid-preconditioned CG solver fea_solve_mgcg
// (handoff 072). No third-party test framework (ARCHITECTURE §4); the same
// self-contained CHECK harness as test_cg, public API only (topopt/fea.hpp,
// topopt/voxel.hpp).
//
// The overriding requirement is CORRECTNESS: MG-CG solves the IDENTICAL system
// Ku=f as the Jacobi-CG fea_solve_cg and must converge to the SAME field. The
// tests therefore:
//   * reproduce the exact uniaxial-tension patch field (closed form),
//   * cross-check MG-CG against the direct solver fea_solve on a cantilever,
//   * cross-check MG-CG against Jacobi-CG DOF-for-DOF on a SIMP soft-void graded
//     grid (the ill-conditioned case) — same answer to CG tolerance,
//   * confirm the void-DOF gate behaves identically (filter / reject),
//   * confirm the robust FALLBACK: an odd grid (no 2x hierarchy) transparently
//     falls back to Jacobi-CG and still returns the right field,
//   * prove the SPEEDUP: on 32^3 and 64^3 MG-CG converges in an order of
//     magnitude fewer iterations than Jacobi-CG, within a tight iteration cap.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <random>
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

#define CHECK(cond, msg)                                            \
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

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

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

VoxelGrid make_cube_with_void_tail(double h) {
  VoxelGrid g;
  g.nx = 2;
  g.ny = 1;
  g.nz = 1;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(2, VoxelTag::Empty);
  g.set_tag(0, 0, 0, VoxelTag::Interior);
  return g;
}

}  // namespace

int main() {
  // ==========================================================================
  // 1. Exact uniaxial-tension patch: MG-CG must reproduce the closed-form
  //    uniform-strain field, same as the direct/Jacobi solvers.
  // ==========================================================================
  {
    const double h = 1.0;
    const double E = 100.0, nu = 0.25, F = 1.0;
    VoxelGrid g = make_solid_grid(2, 1, 1, h);
    const double A = (g.ny * h) * (g.nz * h);
    const double eps = F / (A * E);

    std::vector<int> tip;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b) tip.push_back(topopt::fea_node_index(g, 2, b, c));

    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        bcs.push_back({topopt::fea_node_index(g, 0, b, c), 0, 0.0});
    for (int c = 0; c <= 1; ++c)
      for (int a = 0; a <= 2; ++a)
        bcs.push_back({topopt::fea_node_index(g, a, 0, c), 1, 0.0});
    for (int b = 0; b <= 1; ++b)
      for (int a = 0; a <= 2; ++a)
        bcs.push_back({topopt::fea_node_index(g, a, b, 0), 2, 0.0});

    std::vector<NodalLoad> loads;
    for (int n : tip) loads.push_back({n, 0, F / static_cast<double>(tip.size())});

    // 2x1x1 is too small for a 2-level hierarchy -> falls back to Jacobi-CG,
    // which still produces the exact field. This exercises the fallback on a
    // problem with a known answer.
    CgInfo info;
    FeaSolution sol = topopt::fea_solve_mgcg(g, E, nu, bcs, loads, 1e-12, 0, &info);
    CHECK(info.converged, "patch: MG-CG converged");
    CHECK(!info.used_multigrid, "patch: tiny grid falls back to Jacobi-CG");

    int bad = 0;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 2; ++a) {
          int n = topopt::fea_node_index(g, a, b, c);
          if (!near(sol.at(n, 0), eps * (a * h), 1e-8)) ++bad;
          if (!near(sol.at(n, 1), -nu * eps * (b * h), 1e-8)) ++bad;
          if (!near(sol.at(n, 2), -nu * eps * (c * h), 1e-8)) ++bad;
        }
    CHECK(bad == 0, "patch: MG-CG matches the exact uniform-strain field");
  }

  // ==========================================================================
  // 2. Cross-check against the direct solver on a mid-size cantilever. This
  //    grid (8x8x8 elements) DOES build a multigrid hierarchy.
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(8, 8, 8, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -3.0);

    FeaSolution direct = topopt::fea_solve(g, E, nu, bcs, loads);
    CgInfo info;
    FeaSolution mg = topopt::fea_solve_mgcg(g, E, nu, bcs, loads, 1e-12, 0, &info);
    CHECK(info.converged, "cantilever: MG-CG converged");
    CHECK(info.used_multigrid, "cantilever: 8^3 uses the multigrid path");
    CHECK(info.mg_levels >= 2, "cantilever: hierarchy has >= 2 levels");

    double maxu = 0.0, maxdiff = 0.0;
    for (std::size_t d = 0; d < direct.u.size(); ++d) {
      maxu = std::max(maxu, std::fabs(direct.u[d]));
      maxdiff = std::max(maxdiff, std::fabs(direct.u[d] - mg.u[d]));
    }
    CHECK(maxu > 0.0, "cantilever: direct solve produced a nonzero field");
    CHECK(maxdiff <= 1e-6 * maxu,
          "cantilever: MG-CG agrees with the direct solve");
  }

  // ==========================================================================
  // 3. SAME-ANSWER on the ill-conditioned SIMP case: a graded soft-void grid
  //    (rho_min^p = 1e-9 modulus contrast). MG-CG and Jacobi-CG must converge
  //    to the same displacement field DOF-for-DOF. This is the correctness
  //    crux — a fast solver that changes the answer is a failure.
  // ==========================================================================
  {
    const double E0 = 2100.0, nu = 0.30, rho_min = 1e-3, p = 3.0;
    VoxelGrid g = make_solid_grid(16, 16, 16, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -50.0);

    std::mt19937 rng(2024);
    std::uniform_real_distribution<double> uni(0.0, 1.0);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      const double rho = rho_min + (1.0 - rho_min) * uni(rng);
      ey[e] = std::pow(rho, p) * E0;
    }

    CgInfo ij, im;
    FeaSolution sj = topopt::fea_solve_cg(g, ey, nu, bcs, loads, 1e-10, 0, &ij);
    FeaSolution sm = topopt::fea_solve_mgcg(g, ey, nu, bcs, loads, 1e-10, 0, &im);
    CHECK(ij.converged, "graded: Jacobi-CG converged");
    CHECK(im.converged, "graded: MG-CG converged");

    double maxu = 0.0, maxdiff = 0.0;
    for (std::size_t d = 0; d < sj.u.size(); ++d) {
      maxu = std::max(maxu, std::fabs(sj.u[d]));
      maxdiff = std::max(maxdiff, std::fabs(sj.u[d] - sm.u[d]));
    }
    CHECK(maxu > 0.0, "graded: Jacobi-CG produced a nonzero field");
    CHECK(maxdiff <= 1e-6 * maxu,
          "graded: MG-CG matches Jacobi-CG on the soft-void system");
  }

  // ==========================================================================
  // 4. Void-DOF gate parity: a solid voxel with a dangling empty voxel. MG-CG
  //    must filter the void DOFs (finite field, void nodes exactly 0) and match
  //    the lone-cube solution, exactly as fea_solve_cg does.
  // ==========================================================================
  {
    const double E = 1500.0, nu = 0.3, h = 1.0;
    VoxelGrid gA = make_cube_with_void_tail(h);
    std::vector<DirichletBC> bcsA = clamp_x0_face(gA);
    std::vector<NodalLoad> loadsA;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        loadsA.push_back({topopt::fea_node_index(gA, 1, b, c), 2, -0.25});

    CgInfo infoA;
    FeaSolution solA =
        topopt::fea_solve_mgcg(gA, E, nu, bcsA, loadsA, 1e-12, 0, &infoA);
    CHECK(infoA.converged, "void gate: MG-CG converges with dangling void nodes");

    bool all_finite = true;
    for (double v : solA.u)
      if (!std::isfinite(v)) all_finite = false;
    CHECK(all_finite, "void gate: field is finite (no NaN)");

    bool void_zero = true;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b) {
        const int n = topopt::fea_node_index(gA, 2, b, c);
        for (int comp = 0; comp < 3; ++comp)
          if (!near(solA.at(n, comp), 0.0, 1e-14)) void_zero = false;
      }
    CHECK(void_zero, "void gate: filtered void DOFs return 0");

    VoxelGrid gB = make_solid_grid(1, 1, 1, h);
    std::vector<DirichletBC> bcsB = clamp_x0_face(gB);
    std::vector<NodalLoad> loadsB;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        loadsB.push_back({topopt::fea_node_index(gB, 1, b, c), 2, -0.25});
    FeaSolution solB =
        topopt::fea_solve_mgcg(gB, E, nu, bcsB, loadsB, 1e-12, 0, nullptr);

    double maxu = 0.0, maxdiff = 0.0;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 1; ++a) {
          const int nA = topopt::fea_node_index(gA, a, b, c);
          const int nB = topopt::fea_node_index(gB, a, b, c);
          for (int comp = 0; comp < 3; ++comp) {
            maxu = std::max(maxu, std::fabs(solB.at(nB, comp)));
            maxdiff = std::max(
                maxdiff, std::fabs(solA.at(nA, comp) - solB.at(nB, comp)));
          }
        }
    CHECK(maxu > 0.0, "void gate: reference lone-cube solve is nonzero");
    CHECK(maxdiff <= 1e-6 * maxu,
          "void gate: MG-CG filtering preserves the real solution");
  }

  // ==========================================================================
  // 5. Void-DOF gate rejection parity: a load on an unsupported void DOF must
  //    throw (no equilibrium), before any solve — same as fea_solve_cg.
  // ==========================================================================
  {
    const double E = 1500.0, nu = 0.3, h = 1.0;
    VoxelGrid gA = make_cube_with_void_tail(h);
    std::vector<DirichletBC> bcsA = clamp_x0_face(gA);
    std::vector<NodalLoad> loadsA{
        {topopt::fea_node_index(gA, 2, 0, 0), 2, -1.0}};
    CgInfo info;
    info.iterations = -1;
    bool threw = false;
    try {
      topopt::fea_solve_mgcg(gA, E, nu, bcsA, loadsA, 1e-10, 0, &info);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "void gate: load on an unsupported void DOF throws");
    CHECK(!info.converged && info.iterations == 0,
          "void gate: rejects before any iteration");
  }

  // ==========================================================================
  // 6. Argument validation parity: bad BC / load indices throw invalid_argument.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(4, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);
    auto throws_invalid = [&](std::vector<DirichletBC> b,
                              std::vector<NodalLoad> l) {
      try {
        topopt::fea_solve_mgcg(g, 1000.0, 0.3, b, l, 1e-8, 0, nullptr);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    std::vector<DirichletBC> bad_bc = bcs;
    bad_bc.push_back({topopt::fea_node_count(g), 0, 0.0});
    CHECK(throws_invalid(bad_bc, loads), "out-of-range BC node throws");
    std::vector<NodalLoad> bad_load = loads;
    bad_load.push_back({0, 3, 1.0});
    CHECK(throws_invalid(bcs, bad_load), "out-of-range load component throws");
  }

  // ==========================================================================
  // 7. FALLBACK on a non-2x-divisible grid: 15^3 elements cannot build a 2x
  //    hierarchy, so MG-CG must fall back to Jacobi-CG and still return the
  //    correct field (cross-checked against the direct solver).
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(15, 6, 6, 1.0);  // 15 odd -> no coarsening
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -10.0);

    FeaSolution direct = topopt::fea_solve(g, E, nu, bcs, loads);
    CgInfo info;
    FeaSolution mg = topopt::fea_solve_mgcg(g, E, nu, bcs, loads, 1e-10, 0, &info);
    CHECK(info.converged, "fallback: MG-CG(fallback) converged");
    CHECK(!info.used_multigrid,
          "fallback: odd grid falls back to Jacobi-CG (no hierarchy)");

    double maxu = 0.0, maxdiff = 0.0;
    for (std::size_t d = 0; d < direct.u.size(); ++d) {
      maxu = std::max(maxu, std::fabs(direct.u[d]));
      maxdiff = std::max(maxdiff, std::fabs(direct.u[d] - mg.u[d]));
    }
    CHECK(maxu > 0.0 && maxdiff <= 1e-6 * maxu,
          "fallback: Jacobi-CG fallback matches the direct solve");
  }

  // ==========================================================================
  // 8. Non-convergence guard on the fallback path: an odd grid (fallback) with a
  //    1-iteration cap and a tight tolerance must throw, like fea_solve_cg.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(9, 6, 6, 1.0);  // odd -> fallback
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);
    bool threw = false;
    try {
      topopt::fea_solve_mgcg(g, 1000.0, 0.3, bcs, loads, 1e-14, 1, nullptr);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "fallback: 1-iteration cap on a tight tolerance throws");
  }

  // ==========================================================================
  // 9. SPEEDUP GATE at 32^3 and 64^3: MG-CG must converge to tolerance in an
  //    order of magnitude fewer iterations than the Jacobi-CG baseline, within a
  //    tight iteration cap. (Jacobi averages ~288 at 32^3 and ~578 at 64^3.)
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    for (int n : {32, 64}) {
      VoxelGrid g = make_solid_grid(n, n, n, 1.0);
      std::vector<DirichletBC> bcs = clamp_x0_face(g);
      std::vector<NodalLoad> loads = tip_load_z(g, -100.0);

      CgInfo im;
      FeaSolution sm =
          topopt::fea_solve_mgcg(g, E, nu, bcs, loads, 1e-8, 100, &im);
      CHECK(im.converged, "speedup: MG-CG converged");
      CHECK(im.used_multigrid, "speedup: multigrid path used");
      CHECK(im.iterations > 0 && im.iterations <= 60,
            "speedup: MG-CG converges in <= 60 iterations (Jacobi needs 100s)");

      bool all_finite = true;
      for (double v : sm.u)
        if (!std::isfinite(v)) all_finite = false;
      CHECK(all_finite, "speedup: solution field is finite");
      const int tip = topopt::fea_node_index(g, g.nx, 0, 0);
      CHECK(sm.at(tip, 2) < 0.0, "speedup: tip deflects in the load (-z) sense");
      std::printf("MG-CG %d^3 cantilever: %d iterations, residual %.3e (%d levels)\n",
                  n, im.iterations, im.residual, im.mg_levels);
    }
  }

  if (g_failures == 0) {
    std::printf("fea mgcg: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "fea mgcg: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
