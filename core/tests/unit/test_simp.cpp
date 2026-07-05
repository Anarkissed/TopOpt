// Unit tests for the SIMP density interpolation, compliance and sensitivities
// (ROADMAP M3.2: "Density field + SIMP-penalized stiffness (p=3), compliance +
// sensitivities. Finite-difference check of sensitivities on a tiny grid").
// No third-party test framework (ARCHITECTURE §4); the same self-contained
// CHECK harness as the other unit tests, public API only (topopt/simp.hpp,
// topopt/fea.hpp, topopt/voxel.hpp).
//
// Strategy:
//  * The interpolation law E(rho)=rho^p*E0 and its clamp/validation are checked
//    directly against closed form.
//  * Correctness of the penalized compliance is anchored two independent ways:
//    (a) a uniform density field must reproduce the uniform-material solve
//    fea_solve_cg(E=rho^p*E0) DOF-for-DOF, and (b) the returned compliance must
//    equal f^T u computed straight from the loads and the solution.
//  * The M3.2 deliverable — the analytic sensitivity dc/drho_e — is verified by
//    a central finite-difference check on a tiny non-uniform grid: perturbing
//    each design density by +/-h and re-solving must match the analytic gradient.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
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
using topopt::SimpCompliance;
using topopt::SimpParams;
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

// Clamp the whole x==0 face (removes all six rigid-body modes -> K_ff SPD).
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

double dot_load_solution(const std::vector<NodalLoad>& loads,
                         const FeaSolution& sol) {
  double s = 0.0;
  for (const NodalLoad& l : loads) s += l.value * sol.at(l.node, l.component);
  return s;
}

}  // namespace

int main() {
  // ==========================================================================
  // 1. Interpolation law E(rho) = clamp(rho, rho_min, 1)^p * E0, and validation.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    CHECK(near(topopt::simp_youngs(p, 1.0), 2100.0, 1e-9),
          "simp_youngs: full density gives E0");
    CHECK(near(topopt::simp_youngs(p, 0.5), 0.125 * 2100.0, 1e-9),
          "simp_youngs: rho=0.5, p=3 gives 0.125*E0");
    CHECK(near(topopt::simp_youngs(p, 1e-3), 1e-9 * 2100.0, 1e-12),
          "simp_youngs: rho=rho_min gives rho_min^3 * E0");
    // Clamping: rho above 1 pins to E0, rho below rho_min pins to E(rho_min).
    CHECK(near(topopt::simp_youngs(p, 1.7), 2100.0, 1e-9),
          "simp_youngs: rho>1 clamps to E0");
    CHECK(near(topopt::simp_youngs(p, 0.0), 1e-9 * 2100.0, 1e-12),
          "simp_youngs: rho<rho_min clamps to E(rho_min)");
    // Monotone increasing in rho on [rho_min, 1].
    CHECK(topopt::simp_youngs(p, 0.4) < topopt::simp_youngs(p, 0.6),
          "simp_youngs: monotone increasing in density");

    auto throws_invalid = [](SimpParams q) {
      try {
        topopt::simp_youngs(q, 0.5);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpParams bad_e = p;
    bad_e.youngs_modulus = 0.0;
    CHECK(throws_invalid(bad_e), "simp_youngs: E0<=0 throws");
    SimpParams bad_p = p;
    bad_p.penalty = 0.0;
    CHECK(throws_invalid(bad_p), "simp_youngs: penalty<=0 throws");
    SimpParams bad_min = p;
    bad_min.density_min = 0.0;
    CHECK(throws_invalid(bad_min), "simp_youngs: density_min<=0 throws");
    SimpParams bad_min2 = p;
    bad_min2.density_min = 1.5;
    CHECK(throws_invalid(bad_min2), "simp_youngs: density_min>1 throws");
  }

  // ==========================================================================
  // 2. Uniform initial density field: solids = value, Empty = 0.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(2, 2, 2, 1.0);
    g.set_tag(1, 1, 1, VoxelTag::Empty);  // punch one void
    std::vector<double> d = topopt::simp_uniform_density(g, 0.5);
    CHECK(d.size() == g.voxel_count(), "simp_uniform_density: size = voxel_count");
    int solids = 0, voids = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double v = d[g.index(i, j, k)];
          if (g.solid(i, j, k)) {
            if (near(v, 0.5, 0.0)) ++solids;
          } else {
            if (near(v, 0.0, 0.0)) ++voids;
          }
        }
    CHECK(solids == 7, "simp_uniform_density: every solid voxel = value");
    CHECK(voids == 1, "simp_uniform_density: every Empty voxel = 0");
  }

  // ==========================================================================
  // 3. Uniform density reproduces the uniform-material solve, and the returned
  //    compliance equals f^T u.  With every voxel at density rho the penalized
  //    modulus is uniform E = rho^p * E0, so simp_compliance must match
  //    fea_solve_cg(E) DOF-for-DOF and c must equal f^T u.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    const double rho = 0.6;
    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);
    std::vector<double> d = topopt::simp_uniform_density(g, rho);

    SimpCompliance r =
        topopt::simp_compliance(g, p, d, bcs, loads, 1e-12, 5000);
    CHECK(r.cg.converged, "uniform: penalized CG converged");

    const double E_uniform = std::pow(rho, p.penalty) * p.youngs_modulus;
    CgInfo info;
    FeaSolution ref =
        topopt::fea_solve_cg(g, E_uniform, p.poisson, bcs, loads, 1e-12, 5000, &info);

    double maxu = 0.0, maxdiff = 0.0;
    for (std::size_t k = 0; k < ref.u.size(); ++k) {
      maxu = std::max(maxu, std::fabs(ref.u[k]));
      maxdiff = std::max(maxdiff, std::fabs(ref.u[k] - r.solution.u[k]));
    }
    CHECK(maxu > 0.0, "uniform: reference field is nonzero");
    CHECK(maxdiff <= 1e-6 * maxu,
          "uniform: penalized solve matches the uniform-material solve");

    const double fTu = dot_load_solution(loads, r.solution);
    CHECK(near(r.compliance, fTu, 1e-6 * std::fabs(fTu)),
          "uniform: compliance equals f^T u");
    CHECK(r.compliance > 0.0, "uniform: compliance is positive");
    CHECK(r.dcompliance.size() == g.voxel_count(),
          "uniform: one sensitivity per voxel");
  }

  // ==========================================================================
  // 4. M3.2 GATE: finite-difference check of the analytic sensitivities on a
  //    tiny non-uniform grid.  For each tested design voxel, the analytic
  //    dc/drho_e must match the central difference (c(rho+h)-c(rho-h))/(2h) from
  //    two independent re-solves.  Densities are kept strictly inside
  //    (rho_min, 1) so the clamp is inactive and the derivative is smooth.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);

    // Deterministic non-uniform design in [0.4, 0.9].
    const std::size_t N = g.voxel_count();
    std::vector<double> d(N, 0.0);
    for (std::size_t e = 0; e < N; ++e)
      d[e] = 0.4 + 0.5 * (static_cast<double>(e) / static_cast<double>(N - 1));

    const double tol = 1e-13;
    const int maxit = 8000;
    SimpCompliance base = topopt::simp_compliance(g, p, d, bcs, loads, tol, maxit);
    CHECK(base.cg.converged, "sensitivity: base penalized CG converged");

    // All design voxels under this load should have negative compliance
    // sensitivity (adding material stiffens the structure).
    bool all_negative = true;
    for (std::size_t e = 0; e < N; ++e)
      if (!(base.dcompliance[e] < 0.0)) all_negative = false;
    CHECK(all_negative, "sensitivity: dc/drho < 0 for every design voxel");

    const double h = 1e-4;
    // Cover corner, mid, and last voxels of the design domain.
    const std::size_t probes[] = {0, 3, 7, 11, N - 1};
    double worst_rel = 0.0;
    for (std::size_t e : probes) {
      std::vector<double> dp = d, dm = d;
      dp[e] += h;
      dm[e] -= h;
      const double cp =
          topopt::simp_compliance(g, p, dp, bcs, loads, tol, maxit).compliance;
      const double cm =
          topopt::simp_compliance(g, p, dm, bcs, loads, tol, maxit).compliance;
      const double fd = (cp - cm) / (2.0 * h);
      const double an = base.dcompliance[e];
      const double rel = std::fabs(fd - an) / std::max(std::fabs(an), 1e-30);
      worst_rel = std::max(worst_rel, rel);
      CHECK(rel < 1e-3,
            "sensitivity: analytic dc/drho matches central finite difference");
    }
    std::printf("SIMP sensitivity FD: worst relative error %.3e (tol 1e-3)\n",
                worst_rel);
  }

  // ==========================================================================
  // 5. Empty voxels carry zero sensitivity and are excluded from the design.
  //    A 2x2x1 grid with one Empty voxel: its dc must be exactly 0, while a
  //    loaded solid voxel keeps a nonzero (negative) sensitivity.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 1000.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    VoxelGrid g = make_solid_grid(2, 2, 1, 1.0);
    g.set_tag(1, 1, 0, VoxelTag::Empty);  // one void voxel
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    // -z load on the solid voxel (1,0,0)'s outer face nodes.
    std::vector<NodalLoad> loads;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 0; ++b)
        loads.push_back({topopt::fea_node_index(g, 2, b, c), 2, -0.5});

    std::vector<double> d = topopt::simp_uniform_density(g, 0.7);
    SimpCompliance r = topopt::simp_compliance(g, p, d, bcs, loads, 1e-12, 5000);
    CHECK(r.cg.converged, "empty: penalized CG converged");
    CHECK(near(r.dcompliance[g.index(1, 1, 0)], 0.0, 0.0),
          "empty: Empty voxel has exactly zero sensitivity");
    CHECK(r.dcompliance[g.index(1, 0, 0)] < 0.0,
          "empty: loaded solid voxel has a negative sensitivity");
  }

  if (g_failures == 0) {
    std::printf("simp: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "simp: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
