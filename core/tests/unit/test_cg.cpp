// Unit tests for the Jacobi-preconditioned Conjugate Gradient solver
// (ROADMAP M2.3: "CG solver w/ Jacobi preconditioner over Eigen; converges on
// 64^3 problems in CI time budget (< 5 min)"). No third-party test framework
// (ARCHITECTURE §4); same self-contained CHECK harness as the other unit tests,
// public API only (topopt/fea.hpp, topopt/voxel.hpp).
//
// Strategy:
//  * Correctness is checked where the answer is independently known: the exact
//    2x1x1 uniaxial-tension patch field, and a mid-size cantilever cross-checked
//    against the direct SimplicialLDLT solver fea_solve. This proves fea_solve_cg
//    solves the real system, not just "converges to something".
//  * The M2.3 gate itself is the 64^3 convergence test: a fully solid 64^3 grid
//    (823875 DOFs) cantilever must converge to tolerance within a bounded
//    iteration cap, returning a finite, physically sensible field.
//  * The non-convergence guard (throw when the cap is hit before tolerance) and
//    argument validation are checked on small grids.

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

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// Dense solid grid of nx*ny*nz cubic voxels, edge h, origin at 0.
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

// Cantilever boundary conditions: clamp the whole x==0 face (all 3 DOFs of
// every node with a==0), which removes all six rigid-body modes so K_ff is SPD.
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

// Transverse -z load spread over the free (x==nx) end-face nodes.
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

// One solid voxel followed by one empty voxel along +x. The four nodes on the
// far (a == 2) face touch only the empty voxel, so their DOFs have a zero K_ff
// diagonal -> "void DOFs" that the M3.1 gate must filter (or, if loaded, reject).
VoxelGrid make_cube_with_void_tail(double h) {
  VoxelGrid g;
  g.nx = 2;
  g.ny = 1;
  g.nz = 1;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(2, VoxelTag::Empty);
  g.set_tag(0, 0, 0, VoxelTag::Interior);  // voxel (1,0,0) stays Empty
  return g;
}

}  // namespace

int main() {
  // ==========================================================================
  // 1. Exact uniaxial-tension patch (same field the M2.2 direct test verifies).
  //    CG must reproduce the closed-form uniform-strain solution.
  // ==========================================================================
  {
    const double h = 1.0;
    const double E = 100.0, nu = 0.25, F = 1.0;
    VoxelGrid g = make_solid_grid(2, 1, 1, h);
    const double A = (g.ny * h) * (g.nz * h);
    const double eps = F / (A * E);  // 0.01

    std::vector<int> tip;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b) tip.push_back(topopt::fea_node_index(g, 2, b, c));

    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        bcs.push_back({topopt::fea_node_index(g, 0, b, c), 0, 0.0});  // x=0
    for (int c = 0; c <= 1; ++c)
      for (int a = 0; a <= 2; ++a)
        bcs.push_back({topopt::fea_node_index(g, a, 0, c), 1, 0.0});  // y=0
    for (int b = 0; b <= 1; ++b)
      for (int a = 0; a <= 2; ++a)
        bcs.push_back({topopt::fea_node_index(g, a, b, 0), 2, 0.0});  // z=0

    std::vector<NodalLoad> loads;
    for (int n : tip) loads.push_back({n, 0, F / static_cast<double>(tip.size())});

    CgInfo info;
    FeaSolution sol = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-12, 0, &info);
    CHECK(info.converged, "patch: CG converged");
    CHECK(info.iterations > 0, "patch: CG actually iterated");
    CHECK(info.residual <= 1e-12 * 10.0, "patch: final residual near tolerance");

    int bad = 0;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 2; ++a) {
          int n = topopt::fea_node_index(g, a, b, c);
          if (!near(sol.at(n, 0), eps * (a * h), 1e-8)) ++bad;
          if (!near(sol.at(n, 1), -nu * eps * (b * h), 1e-8)) ++bad;
          if (!near(sol.at(n, 2), -nu * eps * (c * h), 1e-8)) ++bad;
        }
    CHECK(bad == 0, "patch: CG matches the exact uniform-strain field");
  }

  // ==========================================================================
  // 2. Cross-check against the direct solver on a mid-size cantilever.
  //    fea_solve (SimplicialLDLT) and fea_solve_cg must agree DOF-for-DOF to
  //    the CG tolerance -> CG solves the actual assembled system, not a proxy.
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(6, 3, 3, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -3.0);

    FeaSolution direct = topopt::fea_solve(g, E, nu, bcs, loads);
    CgInfo info;
    FeaSolution cg = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-12, 0, &info);
    CHECK(info.converged, "cantilever: CG converged");

    double maxu = 0.0, maxdiff = 0.0;
    for (std::size_t d = 0; d < direct.u.size(); ++d) {
      maxu = std::max(maxu, std::fabs(direct.u[d]));
      maxdiff = std::max(maxdiff, std::fabs(direct.u[d] - cg.u[d]));
    }
    CHECK(maxu > 0.0, "cantilever: direct solve produced a nonzero field");
    CHECK(maxdiff <= 1e-6 * maxu,
          "cantilever: CG agrees with direct solve to CG tolerance");

    // Physical sanity: the loaded tip deflects downward (-z), clamped root does
    // not move.
    const int tip = topopt::fea_node_index(g, g.nx, 0, 0);
    const int root = topopt::fea_node_index(g, 0, 0, 0);
    CHECK(cg.at(tip, 2) < 0.0, "cantilever: tip deflects in the load (-z) sense");
    CHECK(near(cg.at(root, 0), 0.0, 1e-12) && near(cg.at(root, 1), 0.0, 1e-12) &&
              near(cg.at(root, 2), 0.0, 1e-12),
          "cantilever: clamped root node is fixed");
  }

  // ==========================================================================
  // 3. Non-convergence guard: capping iterations below what tolerance needs
  //    must throw rather than silently return an unconverged field.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(8, 8, 8, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);
    bool threw = false;
    CgInfo info;
    try {
      topopt::fea_solve_cg(g, 1000.0, 0.3, bcs, loads, 1e-14, 1, &info);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "1-iteration cap on a tight tolerance throws (non-convergence)");
    CHECK(!info.converged && info.iterations >= 1,
          "guard: CgInfo reports the unconverged attempt");
  }

  // ==========================================================================
  // 4. Argument validation (shared with fea_solve): bad BC / load indices.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(2, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    auto throws_invalid = [&](std::vector<DirichletBC> b,
                              std::vector<NodalLoad> l) {
      try {
        topopt::fea_solve_cg(g, 1000.0, 0.3, b, l, 1e-8, 0, nullptr);
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
  // 5. M2.3 GATE: converge on a 64^3 problem within a bounded iteration cap.
  //    65^3 = 274625 nodes -> 823875 DOFs. A fully solid 64^3 cantilever solved
  //    by Jacobi-CG. The cap (4000) is well above the observed iteration count;
  //    hitting it would throw and fail the test.
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(64, 64, 64, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -100.0);

    CgInfo info;
    FeaSolution sol = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-8, 4000, &info);
    CHECK(info.converged, "64^3: CG converged to tolerance");
    CHECK(info.iterations > 0 && info.iterations <= 4000,
          "64^3: converged within the iteration cap");
    CHECK(info.residual <= 1e-8 * 10.0, "64^3: final residual near tolerance");

    bool all_finite = true;
    for (double v : sol.u)
      if (!std::isfinite(v)) all_finite = false;
    CHECK(all_finite, "64^3: solution field is finite");

    const int tip = topopt::fea_node_index(g, g.nx, 0, 0);
    CHECK(sol.at(tip, 2) < 0.0, "64^3: tip deflects in the load (-z) sense");
    std::printf("64^3 cantilever: %d CG iterations, residual %.3e\n",
                info.iterations, info.residual);
  }

  // ==========================================================================
  // 6. M3.1 VOID-DOF GATE — filtering. A node attached only to void voxels has
  //    a zero K_ff diagonal; the Jacobi preconditioner would divide by it. The
  //    gate must pin (drop) such DOFs and still solve the real structure. Grid A
  //    is one solid voxel with a dangling empty voxel (4 void nodes on its far
  //    face); its solution on the solid nodes must equal the lone-cube solve
  //    (Grid B), and the void nodes must come back exactly 0 (not NaN/garbage).
  // ==========================================================================
  {
    const double E = 1500.0, nu = 0.3, h = 1.0;
    VoxelGrid gA = make_cube_with_void_tail(h);
    std::vector<DirichletBC> bcsA = clamp_x0_face(gA);  // clamp a==0 face
    std::vector<NodalLoad> loadsA;                      // -z load on a==1 face
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        loadsA.push_back({topopt::fea_node_index(gA, 1, b, c), 2, -0.25});

    CgInfo infoA;
    FeaSolution solA =
        topopt::fea_solve_cg(gA, E, nu, bcsA, loadsA, 1e-12, 0, &infoA);
    CHECK(infoA.converged, "void gate: CG converges with dangling void nodes");

    bool all_finite = true;
    for (double v : solA.u)
      if (!std::isfinite(v)) all_finite = false;
    CHECK(all_finite,
          "void gate: field is finite (no NaN from a zero Jacobi pivot)");

    bool void_zero = true;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b) {
        const int n = topopt::fea_node_index(gA, 2, b, c);
        for (int comp = 0; comp < 3; ++comp)
          if (!near(solA.at(n, comp), 0.0, 1e-14)) void_zero = false;
      }
    CHECK(void_zero, "void gate: filtered void DOFs return 0, not garbage");

    // Reference: the lone solid cube, same clamp + load on the matching nodes.
    VoxelGrid gB = make_solid_grid(1, 1, 1, h);
    std::vector<DirichletBC> bcsB = clamp_x0_face(gB);
    std::vector<NodalLoad> loadsB;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        loadsB.push_back({topopt::fea_node_index(gB, 1, b, c), 2, -0.25});
    FeaSolution solB =
        topopt::fea_solve_cg(gB, E, nu, bcsB, loadsB, 1e-12, 0, nullptr);

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
          "void gate: filtering void DOFs preserves the real solution");
  }

  // ==========================================================================
  // 7. M3.1 VOID-DOF GATE — under-constrained. A load on a void DOF (a node
  //    with no stiffness) has no equilibrium; the gate must throw, not "solve".
  // ==========================================================================
  {
    const double E = 1500.0, nu = 0.3, h = 1.0;
    VoxelGrid gA = make_cube_with_void_tail(h);
    std::vector<DirichletBC> bcsA = clamp_x0_face(gA);
    std::vector<NodalLoad> loadsA{
        {topopt::fea_node_index(gA, 2, 0, 0), 2, -1.0}};  // load a void node
    CgInfo info;
    info.iterations = -1;  // sentinel: an early structural rejection leaves 0
    bool threw = false;
    try {
      topopt::fea_solve_cg(gA, E, nu, bcsA, loadsA, 1e-10, 0, &info);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "void gate: load on an unsupported void DOF throws");
    CHECK(!info.converged && info.iterations == 0,
          "void gate: rejects before any CG iteration (structural singularity)");
  }

  // ==========================================================================
  // 8. M3.1 VOID-DOF GATE — no stiffness. An all-void grid has no stiffness
  //    anywhere; the gate rejects it instead of returning a zero/garbage field.
  // ==========================================================================
  {
    VoxelGrid g;
    g.nx = 1;
    g.ny = 1;
    g.nz = 1;
    g.spacing = 1.0;
    g.origin = topopt::Vec3{0.0, 0.0, 0.0};
    g.tags.assign(1, VoxelTag::Empty);
    bool threw = false;
    try {
      topopt::fea_solve_cg(g, 1000.0, 0.3, {}, {}, 1e-10, 0, nullptr);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "void gate: an all-void grid (no stiffness) throws");
  }

  if (g_failures == 0) {
    std::printf("fea cg: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "fea cg: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
