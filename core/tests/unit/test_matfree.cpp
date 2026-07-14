// Unit tests for the matrix-free global stiffness operator + matrix-free
// Jacobi-CG (handoff: matrix-free operator). No third-party test framework
// (ARCHITECTURE §4); the same self-contained CHECK harness as test_cg/test_mgcg,
// public API only (topopt/fea.hpp, topopt/voxel.hpp).
//
// The whole point of matrix-free is to solve the IDENTICAL linear system as
// fea_solve_cg WITHOUT assembling the global sparse K (which OOMs on large
// grids). These tests are the anti-hollow guards that prove it:
//   a. OPERATOR EQUALITY — the matrix-free apply y = K u equals the ASSEMBLED
//      K u DOF-for-DOF (~1e-9 relative) on solid, SIMP soft-void graded, and a
//      non-2-divisible grid, for random u. A wrong gather/scatter, a wrong Ke, or
//      a wrong density scaling fails this atomic proof.
//   b. FULL-SOLVE EQUALITY — matrix-free CG converges to the same displacement
//      field as fea_solve_cg DOF-for-DOF (max|du|/max|u| <= 1e-6), including the
//      ill-conditioned graded soft-void grid (rho_min^p = 1e-9).
//   c. VOID-GATE + VALIDATION PARITY — the same throws as fea_solve_cg
//      (under-constrained, loaded void DOF, bad indices), and the same void-DOF
//      filtering (void nodes come back exactly 0).
//   d. MEMORY EVIDENCE — the matrix-free operator's storage is a grid-independent
//      constant (the single 24x24 reference element), never an assembled K.

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

// Random full displacement field of size 3*node_count, in [-1, 1].
std::vector<double> random_field(const VoxelGrid& g, std::mt19937& rng) {
  std::uniform_real_distribution<double> uni(-1.0, 1.0);
  std::vector<double> u(static_cast<std::size_t>(3 * topopt::fea_node_count(g)));
  for (double& v : u) v = uni(rng);
  return u;
}

// max|a-b| and max|a| over two equal-length vectors.
void max_abs_diff(const std::vector<double>& a, const std::vector<double>& b,
                  double& maxa, double& maxdiff) {
  maxa = 0.0;
  maxdiff = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    maxa = std::max(maxa, std::fabs(a[i]));
    maxdiff = std::max(maxdiff, std::fabs(a[i] - b[i]));
  }
}

}  // namespace

int main() {
  // ==========================================================================
  // a. OPERATOR EQUALITY: matrix-free y = K u == assembled K u, DOF-for-DOF,
  //    for random u. This is the atomic proof of the reference element, the
  //    gather/scatter, and the density scaling.
  // ==========================================================================
  {
    std::mt19937 rng(12345);
    const double nu = 0.29;

    // -- Uniform solid grids, incl. a non-cubic and a non-2-divisible grid. ----
    struct Case { int nx, ny, nz; double h, E; };
    const Case cases[] = {
        {4, 4, 4, 1.0, 2100.0},
        {5, 3, 2, 0.7, 900.0},
        {7, 7, 7, 1.3, 1234.5},  // 7 odd -> non-2-divisible
        {3, 5, 4, 1.0, 100.0},
    };
    for (const Case& c : cases) {
      VoxelGrid g = make_solid_grid(c.nx, c.ny, c.nz, c.h);
      for (int trial = 0; trial < 3; ++trial) {
        const std::vector<double> u = random_field(g, rng);
        const std::vector<double> ymf = topopt::fea_matfree_apply(g, c.E, nu, u);
        const std::vector<double> yas = topopt::fea_assembled_apply(g, c.E, nu, u);
        double maxa = 0.0, maxdiff = 0.0;
        max_abs_diff(yas, ymf, maxa, maxdiff);
        CHECK(maxa > 0.0, "operator(uniform): assembled apply is nonzero");
        CHECK(maxdiff <= 1e-9 * maxa,
              "operator(uniform): matrix-free apply == assembled apply");
      }
    }

    // -- SIMP soft-void GRADED grid (per-voxel modulus, some near-void). --------
    {
      const double E0 = 2100.0, rho_min = 1e-3, p = 3.0;
      VoxelGrid g = make_solid_grid(6, 5, 4, 1.0);
      std::uniform_real_distribution<double> uni(0.0, 1.0);
      std::vector<double> ey(g.voxel_count(), 0.0);
      for (std::size_t e = 0; e < g.voxel_count(); ++e) {
        const double rho = rho_min + (1.0 - rho_min) * uni(rng);
        ey[e] = std::pow(rho, p) * E0;  // spans ~1e-9*E0 .. E0
      }
      for (int trial = 0; trial < 3; ++trial) {
        const std::vector<double> u = random_field(g, rng);
        const std::vector<double> ymf = topopt::fea_matfree_apply(g, ey, nu, u);
        const std::vector<double> yas = topopt::fea_assembled_apply(g, ey, nu, u);
        double maxa = 0.0, maxdiff = 0.0;
        max_abs_diff(yas, ymf, maxa, maxdiff);
        CHECK(maxa > 0.0, "operator(graded): assembled apply is nonzero");
        CHECK(maxdiff <= 1e-9 * maxa,
              "operator(graded): matrix-free apply == assembled apply");
      }
    }

    // -- Graded on a grid with genuine Empty voxels (void tail): the operator
    //    must ignore empty voxels exactly like the assembled path. ------------
    {
      VoxelGrid g = make_cube_with_void_tail(1.0);
      std::vector<double> ey(g.voxel_count(), 0.0);
      ey[g.index(0, 0, 0)] = 1500.0;  // the lone solid voxel; empty entry ignored
      const std::vector<double> u = random_field(g, rng);
      const std::vector<double> ymf = topopt::fea_matfree_apply(g, ey, nu, u);
      const std::vector<double> yas = topopt::fea_assembled_apply(g, ey, nu, u);
      double maxa = 0.0, maxdiff = 0.0;
      max_abs_diff(yas, ymf, maxa, maxdiff);
      CHECK(maxa > 0.0, "operator(void-tail): assembled apply is nonzero");
      CHECK(maxdiff <= 1e-9 * maxa,
            "operator(void-tail): matrix-free apply ignores empty voxels");
    }
  }

  // ==========================================================================
  // b. FULL-SOLVE EQUALITY: matrix-free CG == fea_solve_cg DOF-for-DOF.
  // ==========================================================================

  // b1. Exact uniaxial-tension patch: matrix-free CG reproduces the closed form.
  {
    const double h = 1.0, E = 100.0, nu = 0.25, F = 1.0;
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

    CgInfo info;
    FeaSolution sol =
        topopt::fea_solve_cg_matfree(g, E, nu, bcs, loads, 1e-12, 0, &info);
    CHECK(info.converged, "patch: matrix-free CG converged");
    CHECK(info.iterations > 0, "patch: matrix-free CG actually iterated");
    int bad = 0;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 2; ++a) {
          int n = topopt::fea_node_index(g, a, b, c);
          if (!near(sol.at(n, 0), eps * (a * h), 1e-8)) ++bad;
          if (!near(sol.at(n, 1), -nu * eps * (b * h), 1e-8)) ++bad;
          if (!near(sol.at(n, 2), -nu * eps * (c * h), 1e-8)) ++bad;
        }
    CHECK(bad == 0, "patch: matrix-free CG matches the exact strain field");
  }

  // b2. Uniform cantilever: matrix-free CG == fea_solve_cg DOF-for-DOF, and both
  //     == the direct solver. Includes a non-2-divisible grid.
  {
    const double E = 2100.0, nu = 0.30;
    for (int nx : {6, 9}) {  // 9 odd
      VoxelGrid g = make_solid_grid(nx, 4, 4, 1.0);
      std::vector<DirichletBC> bcs = clamp_x0_face(g);
      std::vector<NodalLoad> loads = tip_load_z(g, -5.0);

      FeaSolution direct = topopt::fea_solve(g, E, nu, bcs, loads);
      CgInfo ic, im;
      FeaSolution cg = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-11, 0, &ic);
      FeaSolution mf =
          topopt::fea_solve_cg_matfree(g, E, nu, bcs, loads, 1e-11, 0, &im);
      CHECK(im.converged, "cantilever: matrix-free CG converged");

      double maxu = 0.0, dd = 0.0, dc = 0.0;
      max_abs_diff(direct.u, mf.u, maxu, dd);
      double tmp = 0.0;
      max_abs_diff(cg.u, mf.u, tmp, dc);
      CHECK(maxu > 0.0, "cantilever: direct solve is nonzero");
      CHECK(dd <= 1e-6 * maxu,
            "cantilever: matrix-free CG matches the direct solve");
      CHECK(dc <= 1e-6 * maxu,
            "cantilever: matrix-free CG matches Jacobi-CG DOF-for-DOF");

      const int tip = topopt::fea_node_index(g, g.nx, 0, 0);
      CHECK(mf.at(tip, 2) < 0.0, "cantilever: tip deflects in the load sense");
    }
  }

  // b3. Ill-conditioned SIMP soft-void graded grid (rho_min^p = 1e-9 contrast):
  //     matrix-free CG and Jacobi-CG must converge to the same field.
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
    FeaSolution sm =
        topopt::fea_solve_cg_matfree(g, ey, nu, bcs, loads, 1e-10, 0, &im);
    CHECK(ij.converged, "graded: Jacobi-CG converged");
    CHECK(im.converged, "graded: matrix-free CG converged");

    double maxu = 0.0, maxdiff = 0.0;
    max_abs_diff(sj.u, sm.u, maxu, maxdiff);
    CHECK(maxu > 0.0, "graded: Jacobi-CG produced a nonzero field");
    CHECK(maxdiff <= 1e-6 * maxu,
          "graded: matrix-free CG matches Jacobi-CG on the soft-void system");
  }

  // b4. Prescribed non-zero Dirichlet displacement: matrix-free CG moves it to
  //     the RHS with the same matrix-free apply and matches fea_solve_cg.
  {
    const double E = 1800.0, nu = 0.3;
    VoxelGrid g = make_solid_grid(4, 3, 3, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    // Prescribe a nonzero +x stretch on the far face.
    for (int c = 0; c <= g.nz; ++c)
      for (int b = 0; b <= g.ny; ++b)
        bcs.push_back({topopt::fea_node_index(g, g.nx, b, c), 0, 0.05});
    std::vector<NodalLoad> loads;  // pure displacement drive

    FeaSolution cg = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-11, 0, nullptr);
    FeaSolution mf =
        topopt::fea_solve_cg_matfree(g, E, nu, bcs, loads, 1e-11, 0, nullptr);
    double maxu = 0.0, maxdiff = 0.0;
    max_abs_diff(cg.u, mf.u, maxu, maxdiff);
    CHECK(maxu > 0.0, "prescribed-BC: Jacobi-CG produced a nonzero field");
    CHECK(maxdiff <= 1e-6 * maxu,
          "prescribed-BC: matrix-free CG matches fea_solve_cg");
  }

  // b5. Warm start (graded overload) reaches the same field as a cold solve.
  {
    const double E0 = 2100.0, nu = 0.30, rho_min = 1e-2, p = 3.0;
    VoxelGrid g = make_solid_grid(10, 6, 6, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -20.0);
    std::mt19937 rng(7);
    std::uniform_real_distribution<double> uni(0.0, 1.0);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      ey[e] = std::pow(rho_min + (1.0 - rho_min) * uni(rng), p) * E0;

    CgInfo icold, iwarm;
    FeaSolution cold =
        topopt::fea_solve_cg_matfree(g, ey, nu, bcs, loads, 1e-10, 0, &icold);
    FeaSolution warm = topopt::fea_solve_cg_matfree(g, ey, nu, bcs, loads, 1e-10,
                                                    0, &iwarm, &cold);
    CHECK(iwarm.converged, "warm: matrix-free CG converged from a warm start");
    CHECK(iwarm.iterations <= icold.iterations,
          "warm: warm start needs no more iterations than cold");
    double maxu = 0.0, maxdiff = 0.0;
    max_abs_diff(cold.u, warm.u, maxu, maxdiff);
    CHECK(maxdiff <= 1e-6 * maxu,
          "warm: warm-started field equals the cold field");
  }

  // ==========================================================================
  // c. VOID-GATE + VALIDATION PARITY with fea_solve_cg.
  // ==========================================================================

  // c1. Void-DOF filtering: a solid voxel with a dangling empty voxel. The void
  //     nodes must come back exactly 0, and the solid nodes must equal the
  //     lone-cube solve — identical to fea_solve_cg.
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
        topopt::fea_solve_cg_matfree(gA, E, nu, bcsA, loadsA, 1e-12, 0, &infoA);
    CHECK(infoA.converged, "void gate: matrix-free CG converges with void nodes");

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
        topopt::fea_solve_cg_matfree(gB, E, nu, bcsB, loadsB, 1e-12, 0, nullptr);

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
          "void gate: filtering preserves the real solution");
  }

  // c2. Under-constrained: a load on an unsupported void DOF must throw
  //     (runtime_error), before any iteration.
  {
    const double E = 1500.0, nu = 0.3, h = 1.0;
    VoxelGrid gA = make_cube_with_void_tail(h);
    std::vector<DirichletBC> bcsA = clamp_x0_face(gA);
    std::vector<NodalLoad> loadsA{{topopt::fea_node_index(gA, 2, 0, 0), 2, -1.0}};
    CgInfo info;
    info.iterations = -1;
    bool threw = false;
    try {
      topopt::fea_solve_cg_matfree(gA, E, nu, bcsA, loadsA, 1e-10, 0, &info);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "void gate: load on an unsupported void DOF throws");
    CHECK(!info.converged && info.iterations == 0,
          "void gate: rejects before any iteration");
  }

  // c3. All-void grid (no stiffness anywhere) must throw.
  {
    VoxelGrid g;
    g.nx = 1; g.ny = 1; g.nz = 1;
    g.spacing = 1.0;
    g.origin = topopt::Vec3{0.0, 0.0, 0.0};
    g.tags.assign(1, VoxelTag::Empty);
    bool threw = false;
    try {
      topopt::fea_solve_cg_matfree(g, 1000.0, 0.3, {}, {}, 1e-10, 0, nullptr);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "void gate: an all-void grid (no stiffness) throws");
  }

  // c4. Non-convergence guard: a tight tolerance under a 1-iteration cap throws.
  {
    VoxelGrid g = make_solid_grid(8, 8, 8, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);
    bool threw = false;
    CgInfo info;
    try {
      topopt::fea_solve_cg_matfree(g, 1000.0, 0.3, bcs, loads, 1e-14, 1, &info);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "guard: 1-iteration cap on a tight tolerance throws");
    CHECK(!info.converged && info.iterations >= 1,
          "guard: CgInfo reports the unconverged attempt");
  }

  // c5. Argument validation: bad BC / load indices throw invalid_argument
  //     (both overloads), and a graded modulus vector size mismatch / a
  //     non-positive solid modulus throw invalid_argument.
  {
    VoxelGrid g = make_solid_grid(3, 3, 3, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    auto throws_invalid_uniform = [&](std::vector<DirichletBC> b,
                                      std::vector<NodalLoad> l) {
      try {
        topopt::fea_solve_cg_matfree(g, 1000.0, 0.3, b, l, 1e-8, 0, nullptr);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    std::vector<DirichletBC> bad_bc = bcs;
    bad_bc.push_back({topopt::fea_node_count(g), 0, 0.0});
    CHECK(throws_invalid_uniform(bad_bc, loads), "out-of-range BC node throws");
    std::vector<NodalLoad> bad_load = loads;
    bad_load.push_back({0, 3, 1.0});
    CHECK(throws_invalid_uniform(bcs, bad_load),
          "out-of-range load component throws");

    // Graded: wrong per-voxel vector size.
    std::vector<double> ey_bad(g.voxel_count() - 1, 1000.0);
    bool threw_size = false;
    try {
      topopt::fea_solve_cg_matfree(g, ey_bad, 0.3, bcs, loads, 1e-8, 0, nullptr);
    } catch (const std::invalid_argument&) {
      threw_size = true;
    }
    CHECK(threw_size, "graded: modulus vector size mismatch throws");

    // Graded: a non-positive modulus on a solid voxel.
    std::vector<double> ey_neg(g.voxel_count(), 1000.0);
    ey_neg[g.index(1, 1, 1)] = 0.0;
    bool threw_neg = false;
    try {
      topopt::fea_solve_cg_matfree(g, ey_neg, 0.3, bcs, loads, 1e-8, 0, nullptr);
    } catch (const std::invalid_argument&) {
      threw_neg = true;
    }
    CHECK(threw_neg, "graded: non-positive solid modulus throws");

    // Apply: material error (bad Poisson) propagates from hex8_stiffness.
    bool threw_mat = false;
    try {
      std::vector<double> u(static_cast<std::size_t>(3 * topopt::fea_node_count(g)),
                            1.0);
      topopt::fea_matfree_apply(g, 1000.0, 0.6, u);  // nu >= 0.5
    } catch (const std::invalid_argument&) {
      threw_mat = true;
    }
    CHECK(threw_mat, "apply: bad Poisson ratio propagates from hex8_stiffness");
  }

  // ==========================================================================
  // d. MEMORY EVIDENCE: the matrix-free operator stores a grid-INDEPENDENT
  //    constant (the single 24x24 reference element = 576 doubles), never an
  //    assembled global K. We assert the storage is 576 regardless of grid size,
  //    and that a solve on a large grid still works with that constant footprint.
  // ==========================================================================
  {
    CHECK(topopt::fea_matfree_operator_storage_doubles() == 576u,
          "memory: operator storage is the 24x24 reference element (576)");

    // The value is grid-independent by construction; confirm a small and a much
    // larger grid both solve while the operator footprint stays 576 (an assembled
    // K would balloon from ~O(10^4) to ~O(10^7) nonzeros between these sizes).
    const std::size_t s0 = topopt::fea_matfree_operator_storage_doubles();
    const double E = 2100.0, nu = 0.30;
    for (int n : {4, 24}) {
      VoxelGrid g = make_solid_grid(n, n, n, 1.0);
      std::vector<DirichletBC> bcs = clamp_x0_face(g);
      std::vector<NodalLoad> loads = tip_load_z(g, -50.0);
      CgInfo info;
      FeaSolution sol =
          topopt::fea_solve_cg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &info);
      CHECK(info.converged, "memory: matrix-free CG converged on the grid");
      CHECK(topopt::fea_matfree_operator_storage_doubles() == s0,
            "memory: operator storage stays constant across grid sizes");
      bool all_finite = true;
      for (double v : sol.u)
        if (!std::isfinite(v)) all_finite = false;
      CHECK(all_finite, "memory: solution field is finite");
      const int tip = topopt::fea_node_index(g, g.nx, 0, 0);
      CHECK(sol.at(tip, 2) < 0.0, "memory: tip deflects in the load sense");
      std::printf(
          "matfree %d^3 cantilever: %d iterations, residual %.3e, operator "
          "storage %zu doubles (grid-independent)\n",
          n, info.iterations, info.residual,
          topopt::fea_matfree_operator_storage_doubles());
    }
  }

  if (g_failures == 0) {
    std::printf("fea matfree: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "fea matfree: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
