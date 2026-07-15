// Unit tests for the MATRIX-FREE geometric-multigrid-preconditioned CG solver
// fea_solve_mgcg_matfree (handoff 078). No third-party test framework
// (ARCHITECTURE §4); the same self-contained CHECK harness as test_mgcg /
// test_matfree, public API only (topopt/fea.hpp, topopt/voxel.hpp).
//
// The overriding requirement is CORRECTNESS: the matrix-free MG-CG solves the
// IDENTICAL system Ku=f as the assembled fea_solve_mgcg (and thus as
// fea_solve_cg) and must converge to the SAME field, on both a solid grid and an
// ill-conditioned SIMP soft-void graded grid, WITHOUT ever assembling the fine
// stiffness matrix. The tests prove, DOF-for-DOF:
//   a. same field as fea_solve_mgcg / fea_solve_cg on a solid 32^3 grid and on a
//      graded soft-void 32^3 grid (rho_min^p = 1e-9), at a size that builds a
//      real >= 3-level hierarchy;
//   b. the matrix-free V-cycle is SPD — CG with it as a preconditioner converges
//      (a non-symmetric preconditioner would stall/diverge);
//   c. the robust FALLBACK: an odd (non-coarsenable) grid falls back to the EXACT
//      matrix-free Jacobi-CG (used_multigrid == false) and still matches the
//      direct solve; throws-on-non-convergence parity with the assembled path;
//   d. MEMORY: no assembled FINE operator is built — the fine-level storage is a
//      grid-independent 576 doubles, and the matrix-free hierarchy's assembled
//      (coarse-only) nonzeros are a small, shrinking fraction of the assembled
//      hierarchy's (which includes the fine A0).

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
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

double max_rel_diff(const FeaSolution& a, const FeaSolution& b) {
  double maxu = 0.0, maxd = 0.0;
  for (std::size_t d = 0; d < a.u.size(); ++d) {
    maxu = std::max(maxu, std::fabs(a.u[d]));
    maxd = std::max(maxd, std::fabs(a.u[d] - b.u[d]));
  }
  return maxu > 0.0 ? maxd / maxu : maxd;
}

}  // namespace

int main() {
  // ==========================================================================
  // 1a. SAME FIELD on a SOLID grid: matrix-free MG-CG must match the assembled
  //     fea_solve_mgcg AND the assembled Jacobi-CG fea_solve_cg DOF-for-DOF, on
  //     a 32^3 grid that builds a real >= 3-level hierarchy.
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -100.0);

    CgInfo icg, img, imf;
    FeaSolution scg = topopt::fea_solve_cg(g, E, nu, bcs, loads, 1e-8, 0, &icg);
    FeaSolution smg = topopt::fea_solve_mgcg(g, E, nu, bcs, loads, 1e-8, 0, &img);
    FeaSolution smf =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &imf);

    CHECK(imf.converged, "solid: matrix-free MG-CG converged");
    CHECK(imf.used_multigrid, "solid: 32^3 uses the matrix-free multigrid path");
    CHECK(imf.mg_levels >= 3, "solid: hierarchy has >= 3 levels");
    CHECK(max_rel_diff(scg, smf) <= 1e-6,
          "solid: matrix-free MG-CG matches assembled Jacobi-CG (fea_solve_cg)");
    CHECK(max_rel_diff(smg, smf) <= 1e-6,
          "solid: matrix-free MG-CG matches assembled MG-CG (fea_solve_mgcg)");
    std::printf(
        "matfree MG-CG solid 32^3: %d iters, residual %.3e, %d levels\n",
        imf.iterations, imf.residual, imf.mg_levels);
  }

  // ==========================================================================
  // 1b. SAME FIELD on the ILL-CONDITIONED SIMP soft-void graded grid: a COHERENT
  //     soft-core structure with rho_min^p = 1e-9 modulus contrast (a soft
  //     spherical inclusion in a solid box — representative of a real SIMP
  //     iterate, on which geometric multigrid engages). This is the correctness
  //     crux for STEP 0: the matrix-free element-local GALERKIN coarsening must
  //     preserve assembled Galerkin's soft-void robustness — the matrix-free
  //     MG-CG must ENGAGE multigrid and converge to the assembled path's field
  //     DOF-for-DOF, in the SAME iteration count (a rediscretised coarse operator
  //     would degrade here; matrix-free Galerkin reproduces A_c exactly).
  // ==========================================================================
  {
    const double E0 = 2100.0, nu = 0.30, rho_min = 1e-3, p = 3.0;  // rho_min^p=1e-9
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

    CgInfo icg, img, imf;
    FeaSolution scg = topopt::fea_solve_cg(g, ey, nu, bcs, loads, 1e-9, 0, &icg);
    FeaSolution smg = topopt::fea_solve_mgcg(g, ey, nu, bcs, loads, 1e-9, 0, &img);
    FeaSolution smf =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &imf);

    CHECK(icg.converged, "graded: assembled Jacobi-CG converged");
    CHECK(img.used_multigrid, "graded: assembled MG engages on the soft-core");
    CHECK(imf.converged, "graded: matrix-free MG-CG converged");
    CHECK(imf.used_multigrid,
          "graded: matrix-free MG engages on the soft-void core (Galerkin robust)");
    CHECK(imf.mg_levels >= 3, "graded: hierarchy has >= 3 levels");
    CHECK(max_rel_diff(scg, smf) <= 1e-6,
          "graded: matrix-free MG-CG matches assembled Jacobi-CG on soft-void");
    CHECK(max_rel_diff(smg, smf) <= 1e-6,
          "graded: matrix-free MG-CG matches assembled MG-CG on soft-void");
    CHECK(std::abs(imf.iterations - img.iterations) <= 2,
          "graded: matrix-free Galerkin converges in the same iteration count as "
          "assembled Galerkin (coarse operator reproduced, not degraded)");
    std::printf(
        "matfree MG-CG graded soft-void 32^3: %d iters (assembled MG %d), "
        "residual %.3e, %d levels\n",
        imf.iterations, img.iterations, imf.residual, imf.mg_levels);
  }

  // ==========================================================================
  // 1c. ADVERSARIAL parity: a per-voxel-independent RANDOM high-contrast field
  //     (rho_min^p = 1e-9) is the pathological case where geometric multigrid
  //     (assembled OR matrix-free) legitimately degrades and BOTH fall back to
  //     exact CG. The matrix-free path must match the assembled fea_solve_mgcg's
  //     fallback decision (used_multigrid parity) and converge to the SAME field
  //     — proving the fallback discipline is preserved, never a wrong answer.
  // ==========================================================================
  {
    const double E0 = 2100.0, nu = 0.30, rho_min = 1e-3, p = 3.0;
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -50.0);

    std::mt19937 rng(2024);
    std::uniform_real_distribution<double> uni(0.0, 1.0);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      const double rho = rho_min + (1.0 - rho_min) * uni(rng);
      ey[e] = std::pow(rho, p) * E0;
    }

    CgInfo icg, img, imf;
    FeaSolution scg = topopt::fea_solve_cg(g, ey, nu, bcs, loads, 1e-9, 0, &icg);
    FeaSolution smg = topopt::fea_solve_mgcg(g, ey, nu, bcs, loads, 1e-9, 0, &img);
    FeaSolution smf =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &imf);

    CHECK(icg.converged && imf.converged, "adversarial: both solvers converged");
    CHECK(imf.used_multigrid == img.used_multigrid,
          "adversarial: matrix-free fallback decision matches assembled MG-CG");
    CHECK(max_rel_diff(scg, smf) <= 1e-6,
          "adversarial: matrix-free result matches the exact field (Jacobi-CG)");
    CHECK(max_rel_diff(smg, smf) <= 1e-6,
          "adversarial: matrix-free result matches assembled fea_solve_mgcg");
    std::printf(
        "matfree MG-CG adversarial random 32^3: used_mg=%d (assembled used_mg=%d), "
        "%d iters, residual %.3e\n",
        static_cast<int>(imf.used_multigrid),
        static_cast<int>(img.used_multigrid), imf.iterations, imf.residual);
  }

  // ==========================================================================
  // 2. SPD PRECONDITIONER: the matrix-free V-cycle is symmetric positive
  //    definite, so MG-preconditioned CG converges. A non-symmetric
  //    preconditioner would stall/diverge — here we require convergence in an
  //    order of magnitude fewer iterations than the free-DOF count (Jacobi-CG on
  //    these grids needs hundreds), which only a valid SPD preconditioner gives.
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(16, 16, 16, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -30.0);

    CgInfo imf;
    FeaSolution smf =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 100, &imf);
    CHECK(imf.converged, "spd: matrix-free MG-CG converged (V-cycle is SPD)");
    CHECK(imf.used_multigrid, "spd: multigrid path used");
    CHECK(imf.iterations > 0 && imf.iterations <= 40,
          "spd: converges in <= 40 iters (a broken/non-SPD M would not)");
    bool finite = true;
    for (double v : smf.u)
      if (!std::isfinite(v)) finite = false;
    CHECK(finite, "spd: field is finite");
  }

  // ==========================================================================
  // 3. VOID-GATE parity: a solid voxel with a dangling empty voxel. Matrix-free
  //    MG-CG must filter the void DOFs (finite field, void nodes exactly 0) and
  //    match the lone-cube solution, exactly as the assembled paths do.
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
        topopt::fea_solve_mgcg_matfree(gA, E, nu, bcsA, loadsA, 1e-12, 0, &infoA);
    CHECK(infoA.converged, "void gate: matrix-free MG-CG converges with void tail");

    bool void_zero = true, all_finite = true;
    for (double v : solA.u)
      if (!std::isfinite(v)) all_finite = false;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b) {
        const int n = topopt::fea_node_index(gA, 2, b, c);
        for (int comp = 0; comp < 3; ++comp)
          if (!near(solA.at(n, comp), 0.0, 1e-14)) void_zero = false;
      }
    CHECK(all_finite, "void gate: field is finite (no NaN)");
    CHECK(void_zero, "void gate: filtered void DOFs return 0");

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
    CHECK(maxu > 0.0 && maxdiff <= 1e-6 * maxu,
          "void gate: matrix-free filtering preserves the real solution");
  }

  // ==========================================================================
  // 4. VOID-GATE REJECTION parity: a load on an unsupported void DOF throws (no
  //    equilibrium) before any solve, and reports the rejection in *info.
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
      topopt::fea_solve_mgcg_matfree(gA, E, nu, bcsA, loadsA, 1e-10, 0, &info);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "reject: load on an unsupported void DOF throws");
    CHECK(!info.converged && info.iterations == 0,
          "reject: rejects before any iteration");
  }

  // ==========================================================================
  // 5. ARGUMENT VALIDATION parity: bad BC / load indices throw invalid_argument.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(4, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);
    auto throws_invalid = [&](std::vector<DirichletBC> b,
                              std::vector<NodalLoad> l) {
      try {
        topopt::fea_solve_mgcg_matfree(g, 1000.0, 0.3, b, l, 1e-8, 0, nullptr);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    std::vector<DirichletBC> bad_bc = bcs;
    bad_bc.push_back({topopt::fea_node_count(g), 0, 0.0});
    CHECK(throws_invalid(bad_bc, loads), "validate: out-of-range BC node throws");
    std::vector<NodalLoad> bad_load = loads;
    bad_load.push_back({0, 3, 1.0});
    CHECK(throws_invalid(bcs, bad_load),
          "validate: out-of-range load component throws");
  }

  // ==========================================================================
  // 6. FALLBACK on a non-2x-divisible grid: 15x6x6 elements cannot build a 2x
  //    hierarchy, so the matrix-free MG-CG must fall back to the EXACT
  //    matrix-free Jacobi-CG (used_multigrid == false) and still return the
  //    correct field (cross-checked against the direct solver).
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;
    VoxelGrid g = make_solid_grid(15, 6, 6, 1.0);  // 15 odd -> no coarsening
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -10.0);

    FeaSolution direct = topopt::fea_solve(g, E, nu, bcs, loads);
    CgInfo info;
    FeaSolution mf =
        topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-10, 0, &info);
    CHECK(info.converged, "fallback: matrix-free MG-CG(fallback) converged");
    CHECK(!info.used_multigrid,
          "fallback: odd grid falls back to matrix-free Jacobi-CG");
    CHECK(info.mg_levels == 0, "fallback: no multigrid levels reported");
    CHECK(max_rel_diff(direct, mf) <= 1e-6,
          "fallback: matrix-free Jacobi-CG fallback matches the direct solve");
  }

  // ==========================================================================
  // 7. NON-CONVERGENCE guard parity on the fallback path: an odd grid (fallback)
  //    with a 1-iteration cap and a tight tolerance must throw, like fea_solve_cg
  //    and the assembled fea_solve_mgcg.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(9, 6, 6, 1.0);  // odd -> fallback
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);
    bool threw = false;
    try {
      topopt::fea_solve_mgcg_matfree(g, 1000.0, 0.3, bcs, loads, 1e-14, 1, nullptr);
    } catch (const std::runtime_error&) {
      threw = true;
    }
    CHECK(threw, "fallback: 1-iteration cap on a tight tolerance throws");
  }

  // ==========================================================================
  // 8. MEMORY EVIDENCE: no assembled FINE operator on the matrix-free path.
  //    (i)  The fine-level operator storage is a grid-independent 576 doubles
  //         (the single reference Ke), constant across grid sizes.
  //    (ii) The matrix-free hierarchy assembles only the COARSE operators — a
  //         small fraction (~12%) of the assembled hierarchy's nonzeros. The
  //         complementary ~88% is the fine A0 the matrix-free path never builds,
  //         and the ABSOLUTE nonzeros it avoids scale with the grid (voxel count)
  //         while the matrix-free fine footprint stays 576 doubles — the memory
  //         win the whole task exists to deliver.
  // ==========================================================================
  {
    const double E = 2100.0, nu = 0.30;

    CHECK(topopt::fea_matfree_operator_storage_doubles() == 576,
          "memory: fine-level operator storage is the 576-double reference Ke");

    std::size_t avoided8 = 0, avoided24 = 0;
    for (int n : {8, 24}) {
      VoxelGrid g = make_solid_grid(n, n, n, 1.0);
      std::vector<DirichletBC> bcs = clamp_x0_face(g);
      std::vector<NodalLoad> loads = tip_load_z(g, -10.0);

      CgInfo im;
      FeaSolution smf =
          topopt::fea_solve_mgcg_matfree(g, E, nu, bcs, loads, 1e-8, 0, &im);
      CHECK(im.converged && im.used_multigrid,
            "memory: matrix-free MG-CG solves with multigrid at this size");

      const std::size_t asm_nnz =
          topopt::fea_mgcg_assembled_operator_nonzeros(g, E, nu, bcs, loads);
      const std::size_t mf_nnz =
          topopt::fea_matfree_mgcg_assembled_operator_nonzeros(g, E, nu, bcs,
                                                               loads);
      CHECK(asm_nnz > 0 && mf_nnz > 0,
            "memory: both hierarchies build assembled coarse operators");
      CHECK(mf_nnz < asm_nnz,
            "memory: matrix-free assembled nnz < assembled (fine A0 absent)");
      CHECK(static_cast<double>(mf_nnz) < 0.20 * static_cast<double>(asm_nnz),
            "memory: coarse operators are < 20% of the hierarchy (fine A0 is the "
            "absent bulk)");
      const std::size_t avoided = asm_nnz - mf_nnz;  // fine-level nnz not built
      if (n == 8) avoided8 = avoided;
      if (n == 24) avoided24 = avoided;
      std::printf(
          "memory %d^3: assembled hierarchy %zu nnz, matrix-free (coarse-only) "
          "%zu nnz -> avoids %zu fine nnz (%.1f%% assembled), fine footprint 576 "
          "doubles\n",
          n, asm_nnz, mf_nnz, avoided,
          100.0 * static_cast<double>(mf_nnz) / static_cast<double>(asm_nnz));
    }
    // The avoided (fine) nonzeros scale with voxel count ((24/8)^3 = 27x) while
    // the matrix-free fine footprint stays a 576-double constant.
    CHECK(avoided24 > 20 * avoided8,
          "memory: avoided fine-operator storage scales with grid size (~27x from "
          "8^3 to 24^3) while the matrix-free fine footprint stays 576 doubles");
  }

  if (g_failures == 0) {
    std::printf("fea mgcg matfree: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "fea mgcg matfree: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
