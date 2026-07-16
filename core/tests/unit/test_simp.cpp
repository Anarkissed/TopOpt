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
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::CgInfo;
using topopt::DensityFilter;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::SimpCompliance;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SolverKind;
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

  // ==========================================================================
  // 6. Density filter (M3.3): partition-of-unity, finite support at `radius`,
  //    the adjoint (transpose) identity for the sensitivity chain rule, and
  //    exclusion of Empty voxels.
  // ==========================================================================
  {
    // 6a. Filtering a constant field returns the same constant (the weights
    //     sum to Hs, so sum_i H_ei x_i / Hs_e = c for x == c). This is the
    //     mesh-independence filter's basic consistency property.
    VoxelGrid g = make_solid_grid(5, 5, 1, 1.0);
    DensityFilter f = topopt::make_density_filter(g, 1.5);
    std::vector<double> c(g.voxel_count(), 0.7);
    std::vector<double> fc = f.filter_density(c);
    bool const_ok = true;
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (!near(fc[g.index(i, j, 0)], 0.7, 1e-12)) const_ok = false;
    CHECK(const_ok, "filter: constant field is preserved (partition of unity)");

    // 6b. Finite support: a unit spike at the centre spreads only to voxels
    //     strictly within `radius`. A face neighbour (dist 1 < 1.5) is nonzero,
    //     a diagonal (dist sqrt2 ~ 1.414 < 1.5) is nonzero, but a knight/edge
    //     voxel at dist 2 and a corner at dist 2*sqrt2 are outside the radius.
    std::vector<double> spike(g.voxel_count(), 0.0);
    spike[g.index(2, 2, 0)] = 1.0;
    std::vector<double> fs = f.filter_density(spike);
    CHECK(fs[g.index(2, 2, 0)] > 0.0, "filter: spike self is nonzero");
    CHECK(fs[g.index(3, 2, 0)] > 0.0, "filter: face neighbour (dist 1) nonzero");
    CHECK(fs[g.index(3, 3, 0)] > 0.0,
          "filter: diagonal neighbour (dist sqrt2) nonzero");
    CHECK(near(fs[g.index(4, 2, 0)], 0.0, 0.0),
          "filter: voxel at dist 2 is outside radius 1.5");
    CHECK(near(fs[g.index(0, 0, 0)], 0.0, 0.0),
          "filter: far corner is outside radius 1.5");

    // 6c. Adjoint identity <M x, s> == <x, M^T s>: filter_sensitivity must be
    //     the exact transpose of filter_density (this is what makes the chain
    //     rule d/dx = M^T d/dxPhys correct). Use two deterministic fields.
    std::vector<double> x(g.voxel_count(), 0.0), s(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      x[e] = 0.1 + 0.03 * static_cast<double>(e);
      s[e] = 1.0 - 0.02 * static_cast<double>(e);
    }
    std::vector<double> Mx = f.filter_density(x);
    std::vector<double> Mts = f.filter_sensitivity(s);
    double lhs = 0.0, rhs = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      lhs += Mx[e] * s[e];
      rhs += x[e] * Mts[e];
    }
    CHECK(near(lhs, rhs, 1e-9 * (std::fabs(lhs) + 1.0)),
          "filter: filter_sensitivity is the transpose of filter_density");

    // 6d. Empty voxels are not design variables: they map to 0 and are excluded
    //     from neighbours (a solid voxel next to a void has smaller Hs than an
    //     interior one, but still filters a constant to itself).
    VoxelGrid gh = make_solid_grid(3, 3, 1, 1.0);
    gh.set_tag(1, 1, 0, VoxelTag::Empty);
    DensityFilter fh = topopt::make_density_filter(gh, 1.5);
    std::vector<double> ch(gh.voxel_count(), 0.5);
    std::vector<double> fch = fh.filter_density(ch);
    CHECK(near(fch[gh.index(1, 1, 0)], 0.0, 0.0),
          "filter: Empty voxel filters to 0");
    CHECK(near(fch[gh.index(0, 0, 0)], 0.5, 1e-12),
          "filter: constant preserved on solid voxels beside a void");

    // 6e. Argument validation.
    bool threw = false;
    try {
      topopt::make_density_filter(g, 0.0);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "filter: radius <= 0 throws");
  }

  // ==========================================================================
  // 7. Optimality-Criteria update (M3.3): the volume constraint is met on the
  //    filtered density, the move limit and box bounds are respected, the step
  //    responds monotonically to the sensitivity, and Empty voxels stay 0.
  // ==========================================================================
  {
    // 7a. Volume constraint: with a near-identity filter (radius 0.5 => each
    //     voxel only itself), a uniform design and uniform sensitivity, the
    //     updated *physical* volume must equal volfrac * n_design.
    VoxelGrid g = make_solid_grid(4, 4, 1, 1.0);
    DensityFilter idf = topopt::make_density_filter(g, 0.5);
    std::vector<double> x = topopt::simp_uniform_density(g, 0.4);
    std::vector<double> dc(g.voxel_count(), -1.0);  // dc/dxPhys < 0
    const double volfrac = 0.55, move = 0.2, dmin = 1e-3;
    std::vector<double> xnew =
        topopt::oc_update(g, idf, x, dc, volfrac, move, dmin);
    std::vector<double> xp = idf.filter_density(xnew);
    double vol = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) vol += xp[e];
    const double n_design = static_cast<double>(g.voxel_count());
    CHECK(near(vol / n_design, volfrac, 5e-3),
          "oc: filtered volume fraction equals the target");

    // 7b. Move limit and box bounds respected on every design voxel.
    bool bounds_ok = true, move_ok = true;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      if (xnew[e] < dmin - 1e-12 || xnew[e] > 1.0 + 1e-12) bounds_ok = false;
      if (std::fabs(xnew[e] - x[e]) > move + 1e-9) move_ok = false;
    }
    CHECK(bounds_ok, "oc: updated densities stay in [density_min, 1]");
    CHECK(move_ok, "oc: updated densities respect the move limit");

    // 7c. Monotone response to the sensitivity: a voxel with a more negative
    //     dc (adding material helps more) must receive at least as much
    //     density as one with a less negative dc, starting from equal density.
    VoxelGrid line = make_solid_grid(4, 1, 1, 1.0);
    DensityFilter lidf = topopt::make_density_filter(line, 0.5);
    std::vector<double> lx = topopt::simp_uniform_density(line, 0.5);
    std::vector<double> ldc(line.voxel_count(), 0.0);
    ldc[line.index(0, 0, 0)] = -4.0;
    ldc[line.index(1, 0, 0)] = -3.0;
    ldc[line.index(2, 0, 0)] = -2.0;
    ldc[line.index(3, 0, 0)] = -1.0;
    std::vector<double> lxn =
        topopt::oc_update(line, lidf, lx, ldc, 0.5, 0.2, 1e-3);
    CHECK(lxn[line.index(0, 0, 0)] > lxn[line.index(1, 0, 0)] &&
              lxn[line.index(1, 0, 0)] > lxn[line.index(2, 0, 0)] &&
              lxn[line.index(2, 0, 0)] > lxn[line.index(3, 0, 0)],
          "oc: density is monotone in the compliance sensitivity");

    // 7d. Empty voxels are excluded from the design and stay exactly 0.
    VoxelGrid gh = make_solid_grid(3, 3, 1, 1.0);
    gh.set_tag(1, 1, 0, VoxelTag::Empty);
    DensityFilter fh = topopt::make_density_filter(gh, 1.5);
    std::vector<double> hx = topopt::simp_uniform_density(gh, 0.5);
    std::vector<double> hdc(gh.voxel_count(), -1.0);
    std::vector<double> hxn =
        topopt::oc_update(gh, fh, hx, hdc, 0.5, 0.2, 1e-3);
    CHECK(near(hxn[gh.index(1, 1, 0)], 0.0, 0.0),
          "oc: Empty voxel stays exactly 0");

    // 7e. Argument validation.
    auto oc_throws = [&](double vf, double mv, double dm) {
      try {
        topopt::oc_update(g, idf, x, dc, vf, mv, dm);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    CHECK(oc_throws(0.0, 0.2, 1e-3), "oc: volume_fraction <= 0 throws");
    CHECK(oc_throws(1.5, 0.2, 1e-3), "oc: volume_fraction > 1 throws");
    CHECK(oc_throws(0.5, 0.0, 1e-3), "oc: move <= 0 throws");
    CHECK(oc_throws(0.5, 0.2, 0.0), "oc: density_min <= 0 throws");
  }

  // ==========================================================================
  // 8. Full SIMP loop simp_optimize (M3.4): drives the filter + penalized
  //    compliance + OC update to a volume-fraction target with convergence
  //    criteria. Here on a tiny cantilever (the fixture-based Gate V2 lives in
  //    tests/validation/test_gate_v2.cpp). Checks the loop's contract:
  //    reduces compliance, meets the volume target, reports a self-consistent
  //    final state, and honours both convergence criteria (change tol + cap).
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(8, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    SimpOptions opt;
    opt.volume_fraction = 0.4;
    opt.filter_radius = 1.5;
    opt.move = 0.2;
    opt.max_iterations = 25;
    opt.change_tol = 0.0;  // no early stop: run the full cap
    opt.cg_tolerance = 1e-9;

    // 8a. A full run to the iteration cap.
    SimpOptimizeResult r = topopt::simp_optimize(g, p, bcs, loads, opt);
    CHECK(r.iterations == opt.max_iterations,
          "optimize: change_tol 0 runs the full iteration cap");
    CHECK(!r.converged,
          "optimize: not flagged converged when stopped by the cap");
    CHECK(r.history.size() == static_cast<std::size_t>(r.iterations),
          "optimize: one history entry per iteration");
    CHECK(near(r.history.front().compliance, r.initial_compliance, 0.0),
          "optimize: initial_compliance == first history compliance");
    CHECK(r.compliance > 0.0, "optimize: final compliance is positive");
    CHECK(r.compliance < r.initial_compliance,
          "optimize: compliance is reduced from the uniform start");
    CHECK(near(r.volume_fraction, opt.volume_fraction, 1e-3),
          "optimize: achieved physical volume fraction meets the target");

    // 8b. Self-consistency of the reported final state:
    //     physical_density == filter(design) and compliance ==
    //     compliance(physical_density).
    DensityFilter f = topopt::make_density_filter(g, opt.filter_radius);
    std::vector<double> xphys = f.filter_density(r.design);
    bool phys_ok = xphys.size() == r.physical_density.size();
    for (std::size_t e = 0; phys_ok && e < xphys.size(); ++e)
      if (!near(xphys[e], r.physical_density[e], 1e-12)) phys_ok = false;
    CHECK(phys_ok, "optimize: physical_density == filter(design)");
    SimpCompliance recomputed = topopt::simp_compliance(
        g, p, r.physical_density, bcs, loads, opt.cg_tolerance, 0);
    CHECK(near(r.compliance, recomputed.compliance,
               1e-5 * std::fabs(recomputed.compliance)),
          "optimize: compliance == compliance(physical_density)");
    // Design variables stay in the admissible box [density_min, 1].
    bool box_ok = true;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double v = r.design[g.index(i, j, k)];
          if (v < p.density_min - 1e-12 || v > 1.0 + 1e-12) box_ok = false;
        }
    CHECK(box_ok, "optimize: design variables stay in [density_min, 1]");

    // 8c. Convergence criterion: a large change tolerance stops after the first
    //     step (an OC step moves any voxel by at most `move` = 0.2 < 1.0).
    SimpOptions early = opt;
    early.change_tol = 1.0;
    SimpOptimizeResult re = topopt::simp_optimize(g, p, bcs, loads, early);
    CHECK(re.iterations == 1,
          "optimize: a loose change_tol stops after one iteration");
    CHECK(re.converged, "optimize: early stop is flagged converged");
    CHECK(re.history.size() == 1, "optimize: early-stop history has one entry");

    // 8d. Argument validation.
    auto opt_throws = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(g, p, bcs, loads, o);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpOptions o0 = opt; o0.volume_fraction = 0.0;
    SimpOptions o1 = opt; o1.volume_fraction = 1.5;
    SimpOptions o2 = opt; o2.move = 0.0;
    SimpOptions o3 = opt; o3.max_iterations = 0;
    SimpOptions o4 = opt; o4.change_tol = -0.1;
    SimpOptions o5 = opt; o5.filter_radius = 0.0;
    CHECK(opt_throws(o0), "optimize: volume_fraction <= 0 throws");
    CHECK(opt_throws(o1), "optimize: volume_fraction > 1 throws");
    CHECK(opt_throws(o2), "optimize: move <= 0 throws");
    CHECK(opt_throws(o3), "optimize: max_iterations < 1 throws");
    CHECK(opt_throws(o4), "optimize: change_tol < 0 throws");
    CHECK(opt_throws(o5), "optimize: filter_radius <= 0 throws");
  }

  // ==========================================================================
  // 9. Heaviside projection + beta continuation (M6.3). The exact analytic
  //    spot values live in fixtures/benchmarks.json and are asserted in
  //    test_gate_v2; here the projection functions are checked against their
  //    mathematical properties and finite differences (independent ground
  //    truth), and the staged simp_optimize loop against its contract.
  // ==========================================================================
  {
    const double eta = 0.5;

    // 9a. Function properties at eta = 0.5: fixed points 0 / 0.5 / 1, strict
    //     monotonicity, the symmetry project(x) + project(1-x) = 1, and
    //     sharpening with beta (higher beta pushes sub-threshold values down).
    for (double beta : {1.0, 8.0, 32.0}) {
      CHECK(near(topopt::heaviside_project(0.0, beta, eta), 0.0, 1e-12),
            "projection: project(0) == 0");
      CHECK(near(topopt::heaviside_project(0.5, beta, eta), 0.5, 1e-12),
            "projection: project(eta) == eta at eta = 0.5");
      CHECK(near(topopt::heaviside_project(1.0, beta, eta), 1.0, 1e-12),
            "projection: project(1) == 1");
      CHECK(topopt::heaviside_project(0.3, beta, eta) <
                topopt::heaviside_project(0.5, beta, eta) &&
            topopt::heaviside_project(0.5, beta, eta) <
                topopt::heaviside_project(0.7, beta, eta),
            "projection: strictly monotone in rho_tilde");
      CHECK(near(topopt::heaviside_project(0.3, beta, eta) +
                     topopt::heaviside_project(0.7, beta, eta),
                 1.0, 1e-12),
            "projection: project(x) + project(1-x) == 1 at eta = 0.5");
      CHECK(topopt::heaviside_project_derivative(0.5, beta, eta) > 0.0,
            "projection: derivative positive at the threshold");
    }
    CHECK(topopt::heaviside_project(0.3, 32.0, eta) <
              topopt::heaviside_project(0.3, 1.0, eta),
          "projection: higher beta pushes sub-threshold density toward 0");
    CHECK(topopt::heaviside_project(0.7, 32.0, eta) >
              topopt::heaviside_project(0.7, 1.0, eta),
          "projection: higher beta pushes super-threshold density toward 1");

    // 9b. Derivative vs central finite difference of the value.
    {
      const double h = 1e-6;
      double worst = 0.0;
      for (double beta : {1.0, 8.0}) {
        for (double rt : {0.1, 0.3, 0.5, 0.7, 0.9}) {
          const double fd = (topopt::heaviside_project(rt + h, beta, eta) -
                             topopt::heaviside_project(rt - h, beta, eta)) /
                            (2.0 * h);
          const double an = topopt::heaviside_project_derivative(rt, beta, eta);
          const double rel = std::fabs(fd - an) / std::max(std::fabs(an), 1e-30);
          worst = std::max(worst, rel);
          CHECK(rel < 1e-6,
                "projection: derivative matches central finite difference");
        }
      }
      std::printf("projection derivative FD: worst relative error %.3e\n",
                  worst);
    }

    // 9c. Argument validation of the projection functions.
    {
      auto proj_throws = [](double rt, double beta, double e) {
        try {
          topopt::heaviside_project(rt, beta, e);
        } catch (const std::invalid_argument&) {
          return true;
        } catch (...) {
          return false;
        }
        return false;
      };
      CHECK(proj_throws(0.5, 0.0, 0.5), "projection: beta <= 0 throws");
      CHECK(proj_throws(0.5, 8.0, 0.0), "projection: eta <= 0 throws");
      CHECK(proj_throws(0.5, 8.0, 1.0), "projection: eta >= 1 throws");
    }
  }

  // ==========================================================================
  // 10. M6.3 GATE (chain rule): the projected compliance gradient — the
  //     projection derivative chained BEFORE the filter transpose,
  //     dc/dx = H^T((dc/drho_bar * drho_bar/drho_tilde)/Hs) — matches a
  //     central finite difference of the composed objective
  //     c(project(filter(x))) on a tiny non-uniform grid. Likewise for the
  //     projected volume V(x) = sum_e project(filter(x))_e whose design-space
  //     gradient is H^T(drho_bar/drho_tilde / Hs). These are the two
  //     sensitivities the projected OC update consumes.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;
    const double beta = 8.0, eta = 0.5;

    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);
    DensityFilter f = topopt::make_density_filter(g, 1.5);

    // Deterministic non-uniform design in [0.4, 0.9]: filtered and projected
    // values stay strictly inside (density_min, 1), so the clamp is inactive
    // and the composed objective is smooth.
    const std::size_t N = g.voxel_count();
    std::vector<double> x(N, 0.0);
    for (std::size_t e = 0; e < N; ++e)
      x[e] = 0.4 + 0.5 * (static_cast<double>(e) / static_cast<double>(N - 1));

    const double tol = 1e-13;
    const int maxit = 8000;
    auto composed = [&](const std::vector<double>& xd) {
      std::vector<double> xt = f.filter_density(xd);
      std::vector<double> xb(xt.size(), 0.0);
      for (std::size_t e = 0; e < xt.size(); ++e)
        xb[e] = topopt::heaviside_project(xt[e], beta, eta);
      return topopt::simp_compliance(g, p, xb, bcs, loads, tol, maxit);
    };
    auto proj_volume = [&](const std::vector<double>& xd) {
      std::vector<double> xt = f.filter_density(xd);
      double v = 0.0;
      for (std::size_t e = 0; e < xt.size(); ++e)
        v += topopt::heaviside_project(xt[e], beta, eta);
      return v;
    };

    // Analytic design-space gradients per the locked chain.
    const std::vector<double> xtilde = f.filter_density(x);
    SimpCompliance base = composed(x);
    CHECK(base.cg.converged, "projected chain: base CG converged");
    std::vector<double> dc_phys(N, 0.0), dproj(N, 0.0);
    for (std::size_t e = 0; e < N; ++e) {
      dproj[e] = topopt::heaviside_project_derivative(xtilde[e], beta, eta);
      dc_phys[e] = base.dcompliance[e] * dproj[e];
    }
    const std::vector<double> dc = f.filter_sensitivity(dc_phys);
    const std::vector<double> dv = f.filter_sensitivity(dproj);

    const double h = 1e-4;
    const std::size_t probes[] = {0, 3, 7, 11, N - 1};
    double worst_c = 0.0, worst_v = 0.0;
    for (std::size_t e : probes) {
      std::vector<double> xp = x, xm = x;
      xp[e] += h;
      xm[e] -= h;
      const double fd_c =
          (composed(xp).compliance - composed(xm).compliance) / (2.0 * h);
      const double rel_c =
          std::fabs(fd_c - dc[e]) / std::max(std::fabs(dc[e]), 1e-30);
      worst_c = std::max(worst_c, rel_c);
      CHECK(rel_c < 1e-3,
            "projected chain: dc/dx matches FD of c(project(filter(x)))");
      const double fd_v = (proj_volume(xp) - proj_volume(xm)) / (2.0 * h);
      const double rel_v =
          std::fabs(fd_v - dv[e]) / std::max(std::fabs(dv[e]), 1e-30);
      worst_v = std::max(worst_v, rel_v);
      CHECK(rel_v < 1e-6,
            "projected chain: dV/dx matches FD of the projected volume");
    }
    std::printf(
        "projected chain FD: worst compliance rel %.3e, volume rel %.3e\n",
        worst_c, worst_v);
  }

  // ==========================================================================
  // 11. Staged projected simp_optimize (M6.3): beta continuation mechanics,
  //     per-stage move limits, self-consistent projected final state, the
  //     projected volume constraint, mask pins under projection, and argument
  //     validation. A short synthetic schedule keeps this a unit test; the
  //     locked 6x50 benchmark schedule is exercised by test_gate_v2.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(8, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    SimpOptions opt;
    opt.volume_fraction = 0.4;
    opt.filter_radius = 1.5;
    opt.move = 0.2;          // ignored in projected mode (per-stage moves)
    opt.max_iterations = 60; // ignored in projected mode (per-stage iterations)
    opt.change_tol = 0.0;
    opt.cg_tolerance = 1e-9;
    opt.projection = {{1.0, 0.2, 6}, {2.0, 0.1, 5}, {4.0, 0.05, 4}};
    opt.projection_eta = 0.5;

    // 11a. Default options run the legacy (unprojected) loop: the projection
    //      schedule is empty by default.
    CHECK(SimpOptions{}.projection.empty(),
          "projected optimize: projection disabled by default");

    SimpOptimizeResult r = topopt::simp_optimize(g, p, bcs, loads, opt);

    // 11b. Iteration accounting: sum of stage iterations, one history entry
    //      per iteration, no convergence flag at change_tol 0.
    CHECK(r.iterations == 15,
          "projected optimize: iterations == sum of stage iterations");
    CHECK(r.history.size() == 15,
          "projected optimize: one history entry per iteration");
    CHECK(!r.converged, "projected optimize: change_tol 0 never converges");

    // 11c. Per-stage move limits honoured (0.2 / 0.1 / 0.05).
    bool moves_ok = true;
    for (std::size_t it = 0; it < r.history.size(); ++it) {
      const double mv = it < 6 ? 0.2 : (it < 11 ? 0.1 : 0.05);
      if (r.history[it].change > mv + 1e-9) moves_ok = false;
    }
    CHECK(moves_ok, "projected optimize: per-stage move limits respected");

    // 11d. Self-consistent projected final state: physical_density ==
    //      project(filter(design)) at the LAST stage's beta, compliance ==
    //      compliance(physical_density), volume_fraction == mean projected
    //      density == target (the constraint is on the projected field).
    DensityFilter f = topopt::make_density_filter(g, opt.filter_radius);
    std::vector<double> xt = f.filter_density(r.design);
    bool phys_ok = xt.size() == r.physical_density.size();
    double vol = 0.0;
    for (std::size_t e = 0; phys_ok && e < xt.size(); ++e) {
      const double xb = topopt::heaviside_project(xt[e], 4.0, 0.5);
      if (!near(xb, r.physical_density[e], 1e-12)) phys_ok = false;
      vol += xb;
    }
    CHECK(phys_ok,
          "projected optimize: physical_density == project(filter(design))");
    CHECK(near(vol / static_cast<double>(g.voxel_count()), r.volume_fraction,
               1e-12),
          "projected optimize: volume_fraction is the projected fraction");
    CHECK(near(r.volume_fraction, opt.volume_fraction, 1e-2),
          "projected optimize: projected volume fraction meets the target");
    SimpCompliance rc = topopt::simp_compliance(
        g, p, r.physical_density, bcs, loads, opt.cg_tolerance, 0);
    CHECK(near(r.compliance, rc.compliance, 1e-5 * std::fabs(rc.compliance)),
          "projected optimize: compliance == compliance(physical_density)");
    CHECK(r.compliance > 0.0 && r.compliance < r.initial_compliance,
          "projected optimize: compliance reduced from the uniform start");

    // 11e. change_tol still ends a stage early (each stage re-converges, then
    //      continuation moves on): a huge tolerance stops every stage after
    //      one iteration.
    SimpOptions early = opt;
    early.change_tol = 1.0;
    SimpOptimizeResult re = topopt::simp_optimize(g, p, bcs, loads, early);
    CHECK(re.iterations == 3,
          "projected optimize: loose change_tol runs one iteration per stage");
    CHECK(re.converged,
          "projected optimize: early stop of the last stage flags converged");

    // 11f. Masked overload under projection: FrozenVoid stays exactly 0,
    //      FrozenSolid exactly 1 in the projected physical density; the run
    //      completes with the same iteration accounting.
    topopt::DesignMask mask = topopt::make_active_mask(g);
    for (int j = 0; j < g.ny; ++j)  // a keep-out channel through mid-x
      mask[g.index(4, j, 2)] = topopt::MaskValue::FrozenVoid;
    mask[g.index(1, 1, 1)] = topopt::MaskValue::FrozenSolid;
    SimpOptimizeResult rm = topopt::simp_optimize(g, p, bcs, loads, opt, mask);
    CHECK(rm.iterations == 15,
          "projected masked: iterations == sum of stage iterations");
    bool pins_ok = true;
    for (int j = 0; j < g.ny; ++j)
      if (!near(rm.physical_density[g.index(4, j, 2)], 0.0, 0.0))
        pins_ok = false;
    CHECK(pins_ok, "projected masked: FrozenVoid physical density pinned 0");
    CHECK(near(rm.physical_density[g.index(1, 1, 1)], 1.0, 0.0),
          "projected masked: FrozenSolid physical density pinned 1");

    // 11g. Argument validation of the projection schedule (both overloads).
    auto opt_throws = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(g, p, bcs, loads, o);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    auto opt_throws_masked = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(g, p, bcs, loads, o, mask);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpOptions b0 = opt; b0.projection[1].beta = 0.0;
    SimpOptions b1 = opt; b1.projection[0].move = 0.0;
    SimpOptions b2 = opt; b2.projection[2].iterations = 0;
    SimpOptions b3 = opt; b3.projection_eta = 1.0;
    CHECK(opt_throws(b0), "projected optimize: stage beta <= 0 throws");
    CHECK(opt_throws(b1), "projected optimize: stage move <= 0 throws");
    CHECK(opt_throws(b2), "projected optimize: stage iterations < 1 throws");
    CHECK(opt_throws(b3), "projected optimize: eta outside (0,1) throws");
    CHECK(opt_throws_masked(b0), "projected masked: stage beta <= 0 throws");
    CHECK(opt_throws_masked(b3), "projected masked: bad eta throws");
  }

  // ==========================================================================
  // 12. Progress callback + polled cancellation (M7.0a). The callback fires
  //     once per completed OC iteration with (iteration, compliance, change)
  //     mirroring the history entry; the cancel flag is polled once per OC
  //     iteration (at its start), and a cancelled run still returns a valid,
  //     self-consistent result. Absent callback/flag must not change the
  //     trajectory (the zero-overhead contract, checked behaviorally).
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(6, 3, 3, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    SimpOptions opt;
    opt.volume_fraction = 0.4;
    opt.filter_radius = 1.5;
    opt.move = 0.2;
    opt.max_iterations = 8;
    opt.change_tol = 0.0;  // run the full cap (deterministic iteration count)
    opt.cg_tolerance = 1e-9;

    // 12a. Defaults: no callback, no cancel flag; a plain run is not cancelled.
    CHECK(!SimpOptions{}.progress, "progress: absent by default");
    CHECK(SimpOptions{}.cancel == nullptr, "cancel: null by default");
    const SimpOptimizeResult r0 = topopt::simp_optimize(g, p, bcs, loads, opt);
    CHECK(!r0.cancelled, "cancel: un-cancelled run reports cancelled == false");
    CHECK(r0.iterations == 8, "progress: baseline runs the full cap");

    // 12b. Callback accounting: one invocation per OC iteration, iteration
    //      numbers 1..N strictly monotone, payload mirrors the history entry.
    struct Rec {
      int iteration;
      double compliance;
      double change;
    };
    std::vector<Rec> recs;
    SimpOptions optcb = opt;
    optcb.progress = [&recs](int it, double c, double ch) {
      recs.push_back({it, c, ch});
    };
    const SimpOptimizeResult r1 = topopt::simp_optimize(g, p, bcs, loads, optcb);
    CHECK(recs.size() == static_cast<std::size_t>(r1.iterations),
          "progress: invocation count == iterations performed");
    bool monotone = true, mirrors = true;
    for (std::size_t i = 0; i < recs.size(); ++i) {
      if (recs[i].iteration != static_cast<int>(i) + 1) monotone = false;
      if (recs[i].compliance != r1.history[i].compliance ||
          recs[i].change != r1.history[i].change)
        mirrors = false;
    }
    CHECK(monotone, "progress: iteration numbers are 1..N strictly monotone");
    CHECK(mirrors, "progress: payload mirrors the history entry exactly");

    // 12c. The callback has no effect on the trajectory: bit-identical result
    //      with and without it (the observable half of "zero overhead when
    //      callback absent" — the data passed is computed for history anyway).
    CHECK(r1.design == r0.design && r1.physical_density == r0.physical_density,
          "progress: trajectory bit-identical with and without callback");
    CHECK(r1.compliance == r0.compliance && r1.iterations == r0.iterations,
          "progress: compliance/iterations identical with and without callback");

    // 12d. Cancel pre-set before the run: zero iterations, cancelled, and a
    //      valid self-consistent result (uniform start design, physical_density
    //      == filter(design), compliance == compliance(physical_density)).
    std::atomic<bool> pre{true};
    SimpOptions optpre = opt;
    optpre.cancel = &pre;
    const SimpOptimizeResult rp = topopt::simp_optimize(g, p, bcs, loads, optpre);
    CHECK(rp.cancelled, "cancel: pre-set flag cancels the run");
    CHECK(rp.iterations == 0 && rp.history.empty(),
          "cancel: pre-set flag => zero OC iterations");
    CHECK(!rp.converged, "cancel: a cancelled run is not converged");
    bool uniform_ok = true;
    for (std::size_t e = 0; e < rp.design.size(); ++e)
      if (rp.design[e] != opt.volume_fraction) uniform_ok = false;
    CHECK(uniform_ok, "cancel: zero-iteration design is the uniform start");
    DensityFilter f12 = topopt::make_density_filter(g, opt.filter_radius);
    CHECK(rp.physical_density == f12.filter_density(rp.design),
          "cancel: cancelled result keeps physical_density == filter(design)");
    const SimpCompliance rpc = topopt::simp_compliance(
        g, p, rp.physical_density, bcs, loads, opt.cg_tolerance, 0);
    CHECK(near(rp.compliance, rpc.compliance, 1e-9 * std::fabs(rpc.compliance)),
          "cancel: cancelled compliance == compliance(physical_density)");

    // 12e. Cancel mid-run from the callback: the flag set at iteration 3 is
    //      observed at the START of iteration 4, so exactly 3 iterations ran,
    //      and they are the same first 3 iterations as the uncancelled run.
    std::atomic<bool> mid{false};
    SimpOptions optmid = opt;
    optmid.cancel = &mid;
    optmid.progress = [&mid](int it, double, double) {
      if (it == 3) mid.store(true);
    };
    const SimpOptimizeResult rm = topopt::simp_optimize(g, p, bcs, loads, optmid);
    CHECK(rm.cancelled, "cancel: mid-run flag cancels the run");
    CHECK(rm.iterations == 3 && rm.history.size() == 3,
          "cancel: flag at iteration 3 => exactly 3 iterations performed");
    bool prefix_ok = true;
    for (std::size_t i = 0; i < rm.history.size(); ++i)
      if (rm.history[i].compliance != r0.history[i].compliance ||
          rm.history[i].change != r0.history[i].change)
        prefix_ok = false;
    CHECK(prefix_ok,
          "cancel: a cancelled trajectory is a prefix of the uncancelled one");
    CHECK(rm.physical_density == f12.filter_density(rm.design),
          "cancel: mid-run cancelled result is self-consistent");

    // 12f. Masked overload: same callback accounting and cancellation; the
    //      mask pins (FrozenSolid 1 / FrozenVoid 0) hold in a cancelled result.
    topopt::DesignMask mask = topopt::make_active_mask(g);
    mask[g.index(3, 1, 1)] = topopt::MaskValue::FrozenVoid;
    mask[g.index(1, 1, 1)] = topopt::MaskValue::FrozenSolid;
    std::size_t masked_calls = 0;
    SimpOptions optmk = opt;
    optmk.progress = [&masked_calls](int, double, double) { ++masked_calls; };
    const SimpOptimizeResult rk =
        topopt::simp_optimize(g, p, bcs, loads, optmk, mask);
    CHECK(masked_calls == static_cast<std::size_t>(rk.iterations),
          "progress(masked): invocation count == iterations performed");
    std::atomic<bool> mcancel{false};
    SimpOptions optmc = opt;
    optmc.cancel = &mcancel;
    optmc.progress = [&mcancel](int it, double, double) {
      if (it == 2) mcancel.store(true);
    };
    const SimpOptimizeResult rmc =
        topopt::simp_optimize(g, p, bcs, loads, optmc, mask);
    CHECK(rmc.cancelled && rmc.iterations == 2,
          "cancel(masked): flag at iteration 2 => exactly 2 iterations");
    CHECK(rmc.physical_density[g.index(3, 1, 1)] == 0.0,
          "cancel(masked): FrozenVoid pinned 0 in a cancelled result");
    CHECK(rmc.physical_density[g.index(1, 1, 1)] == 1.0,
          "cancel(masked): FrozenSolid pinned 1 in a cancelled result");

    // 12g. Projection schedule (M6.3): iteration numbers stay globally
    //      monotone across stages, and a mid-stage cancel stops the
    //      continuation (no later stage runs).
    SimpOptions optpj = opt;
    optpj.projection = {{1.0, 0.2, 3}, {2.0, 0.2, 3}};
    std::vector<int> pj_its;
    optpj.progress = [&pj_its](int it, double, double) { pj_its.push_back(it); };
    const SimpOptimizeResult rj = topopt::simp_optimize(g, p, bcs, loads, optpj);
    CHECK(rj.iterations == 6 && pj_its.size() == 6,
          "progress(projected): one invocation per iteration across stages");
    bool pj_monotone = true;
    for (std::size_t i = 0; i < pj_its.size(); ++i)
      if (pj_its[i] != static_cast<int>(i) + 1) pj_monotone = false;
    CHECK(pj_monotone,
          "progress(projected): iteration numbers monotone across stages");
    std::atomic<bool> pjc{false};
    SimpOptions optpjc = optpj;
    optpjc.cancel = &pjc;
    optpjc.progress = [&pjc](int it, double, double) {
      if (it == 4) pjc.store(true);  // first iteration of stage 2
    };
    const SimpOptimizeResult rjc =
        topopt::simp_optimize(g, p, bcs, loads, optpjc);
    CHECK(rjc.cancelled && rjc.iterations == 4,
          "cancel(projected): mid-stage cancel stops the continuation");
  }

  // ==========================================================================
  // 13. Multigrid solver opt-in (handoff 073). The geometric-multigrid-
  //     preconditioned CG (fea_solve_mgcg) is wired into the optimizer as an
  //     OPT-IN accelerator via SolverKind / SimpOptions::solver, defaulting OFF.
  //     Proves: (a) the DEFAULT path is genuinely Jacobi-CG (used_multigrid ==
  //     false), (b) MultigridCG actually engages on a 2x-divisible grid
  //     (used_multigrid == true — not just a silent fallback), and (c) the SAME
  //     optimization problem run through the full loop with JacobiCG vs
  //     MultigridCG produces the SAME design (max|drho| ~ 1e-6), the SAME final
  //     compliance (~1e-6 relative), and the identical accepted/rejected outcome
  //     — the "same result, faster engine" proof at the OPTIMIZER level (handoff
  //     072 proved it at the single-solve level; this survives iteration after
  //     iteration through the OC updates).
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(8, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    std::vector<double> d = simp_uniform_density(g, 0.5);

    // 13a. DEFAULT simp_compliance (no solver_kind arg) runs Jacobi-CG: the
    //      multigrid path is not reached unless a caller opts in.
    SimpCompliance def = topopt::simp_compliance(g, p, d, bcs, loads, 1e-10, 0);
    CHECK(!def.cg.used_multigrid,
          "mgcg: default simp_compliance uses Jacobi-CG (used_multigrid false)");
    CHECK(def.cg.mg_levels == 0,
          "mgcg: default simp_compliance reports no multigrid levels");

    // 13b. Explicitly-selected JacobiCG is identical to the default (still
    //      Jacobi-CG), and MultigridCG genuinely engages the V-cycle hierarchy
    //      on this 2x-divisible grid (used_multigrid true, >= 2 levels).
    SimpCompliance jac = topopt::simp_compliance(g, p, d, bcs, loads, 1e-10, 0,
                                                 nullptr, nullptr,
                                                 SolverKind::JacobiCG);
    CHECK(!jac.cg.used_multigrid,
          "mgcg: explicit JacobiCG uses Jacobi-CG (used_multigrid false)");
    SimpCompliance mg = topopt::simp_compliance(g, p, d, bcs, loads, 1e-10, 0,
                                                nullptr, nullptr,
                                                SolverKind::MultigridCG);
    CHECK(mg.cg.used_multigrid,
          "mgcg: MultigridCG engages the multigrid path (used_multigrid true)");
    CHECK(mg.cg.mg_levels >= 2,
          "mgcg: multigrid hierarchy has >= 2 levels on an 8x4x4 grid");
    // Same system, same tolerance => same displacement field and compliance.
    double max_du = 0.0;
    for (std::size_t i = 0; i < jac.solution.u.size(); ++i)
      max_du = std::max(max_du, std::fabs(jac.solution.u[i] - mg.solution.u[i]));
    double max_abs_u = 0.0;
    for (double v : jac.solution.u) max_abs_u = std::max(max_abs_u, std::fabs(v));
    CHECK(max_du <= 1e-6 * max_abs_u,
          "mgcg: single-solve field agrees Jacobi-CG vs MG-CG (rel 1e-6)");
    CHECK(near(jac.compliance, mg.compliance, 1e-6 * std::fabs(jac.compliance)),
          "mgcg: single-solve compliance agrees Jacobi-CG vs MG-CG");

    // 13c. Same result through the FULL optimize loop. change_tol = 0 forces
    //      both runs to the full iteration cap (identical iteration counts and
    //      accepted/rejected outcome by construction), so the comparison
    //      isolates the solver: iteration after iteration the MG-accelerated
    //      design must track the Jacobi design.
    SimpOptions base;
    base.volume_fraction = 0.4;
    base.filter_radius = 1.5;
    base.move = 0.2;
    base.max_iterations = 15;
    base.change_tol = 0.0;   // run the full cap on both -> deterministic outcome
    base.cg_tolerance = 1e-10;

    SimpOptions oj = base;  oj.solver = SolverKind::JacobiCG;
    SimpOptions om = base;  om.solver = SolverKind::MultigridCG;
    SimpOptimizeResult rj = topopt::simp_optimize(g, p, bcs, loads, oj);
    SimpOptimizeResult rm = topopt::simp_optimize(g, p, bcs, loads, om);

    // Identical accepted/rejected outcome and iteration count.
    CHECK(rj.iterations == rm.iterations,
          "mgcg: optimize iteration count identical (JacobiCG vs MultigridCG)");
    CHECK(rj.converged == rm.converged,
          "mgcg: optimize converged/outcome identical (JacobiCG vs MultigridCG)");

    // Final designs agree within a tight tolerance, iteration after iteration.
    double max_drho = 0.0;
    bool sized = rj.design.size() == rm.design.size();
    for (std::size_t e = 0; sized && e < rj.design.size(); ++e)
      max_drho = std::max(max_drho, std::fabs(rj.design[e] - rm.design[e]));
    CHECK(sized, "mgcg: optimize designs are the same size");
    CHECK(max_drho <= 1e-6,
          "mgcg: final design agrees JacobiCG vs MultigridCG (max|drho| 1e-6)");
    CHECK(near(rj.compliance, rm.compliance, 1e-6 * std::fabs(rj.compliance)),
          "mgcg: final compliance agrees JacobiCG vs MultigridCG (rel 1e-6)");
  }

  // ==========================================================================
  // 14. REALISTIC multi-level same-answer proof (handoff 074). This is the
  //     evidence that justifies turning MultigridCG ON at the app's production
  //     optimize entry point. It runs the SAME optimization through the FULL
  //     simp_optimize loop TWICE — once JacobiCG, once MultigridCG — on a
  //     realistic ~32^3 grid (a >= 3-level multigrid hierarchy, vs the 8x4x4 /
  //     2-level grid of §13). change_tol = 0 forces both runs to the full
  //     iteration cap, so iteration counts + accepted/rejected outcome are
  //     identical by construction and the comparison isolates the solver.
  //     Proves the fast engine == the slow engine at production scale:
  //     identical iterations/outcome, final max|drho| <= 1e-6, compliance to
  //     1e-6 relative. Then a speedup-REALITY check: it probes every analysis
  //     density the MultigridCG loop visited and reports how many engaged the
  //     V-cycle vs fell back to exact Jacobi-CG. Correctness holds either way
  //     (a fallback IS an exact Jacobi-CG solve); this tells us whether real
  //     filtered/coherent SIMP fields genuinely get the multigrid win rather
  //     than silently falling back.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(32, 32, 32, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    // 14a. On this 32^3 grid the hierarchy is genuinely multi-level (>= 3 grid
    //      levels) and MultigridCG engages the V-cycle on a real filtered start
    //      field — not a silent fallback to Jacobi.
    std::vector<double> d0 = simp_uniform_density(g, 0.5);
    SimpCompliance mg0 = topopt::simp_compliance(g, p, d0, bcs, loads, 1e-10, 0,
                                                 nullptr, nullptr,
                                                 SolverKind::MultigridCG);
    CHECK(mg0.cg.used_multigrid,
          "realistic: MultigridCG engages the V-cycle at 32^3 (not a fallback)");
    CHECK(mg0.cg.mg_levels >= 3,
          "realistic: 32^3 multigrid hierarchy has >= 3 levels");

    // 14b. Same optimization, full loop, both engines. change_tol = 0 => both
    //      hit the cap => identical iteration count and accepted/rejected outcome
    //      by construction, isolating the solver. The MultigridCG run also
    //      captures the analysis density it visits each OC iteration (read-only
    //      playback keyframe — the field the penalized solve uses), so we can
    //      afterward probe how many of those solves the V-cycle accelerated.
    SimpOptions base;
    base.volume_fraction = 0.4;
    base.filter_radius = 1.5;
    base.move = 0.2;
    base.max_iterations = 10;  // realistic multi-iteration loop; keeps the whole
                               // test well under ~2 min with margin for slower CI
    base.change_tol = 0.0;     // run the full cap on both -> deterministic
    base.cg_tolerance = 1e-10;

    std::vector<std::vector<double>> mg_fields;
    SimpOptions oj = base;  oj.solver = SolverKind::JacobiCG;
    SimpOptions om = base;  om.solver = SolverKind::MultigridCG;
    om.keyframe_stride = 1;
    om.keyframe = [&](const std::vector<double>& analysis_density) {
      mg_fields.push_back(analysis_density);
    };

    SimpOptimizeResult rj = topopt::simp_optimize(g, p, bcs, loads, oj);
    SimpOptimizeResult rm = topopt::simp_optimize(g, p, bcs, loads, om);

    CHECK(rj.iterations == rm.iterations,
          "realistic: optimize iteration count identical (JacobiCG vs MultigridCG)");
    CHECK(rj.converged == rm.converged,
          "realistic: optimize converged/outcome identical (JacobiCG vs MultigridCG)");

    double max_drho = 0.0;
    bool sized = rj.design.size() == rm.design.size();
    for (std::size_t e = 0; sized && e < rj.design.size(); ++e)
      max_drho = std::max(max_drho, std::fabs(rj.design[e] - rm.design[e]));
    CHECK(sized, "realistic: optimize designs are the same size");
    CHECK(max_drho <= 1e-6,
          "realistic: final design agrees JacobiCG vs MultigridCG (max|drho| 1e-6)");
    CHECK(near(rm.compliance, rj.compliance, 1e-6 * std::fabs(rj.compliance)),
          "realistic: final compliance agrees JacobiCG vs MultigridCG (rel 1e-6)");

    // 14c. Speedup-REALITY check: re-solve each analysis density the MultigridCG
    //      loop visited (same tolerance) and count V-cycle vs Jacobi-CG fallback.
    //      Deterministic + stateless, so each probe reproduces the loop solve's
    //      own MG-vs-fallback decision on that exact field.
    int mg_used = 0, mg_fell_back = 0, levels = 0;
    for (const std::vector<double>& fld : mg_fields) {
      SimpCompliance c = topopt::simp_compliance(g, p, fld, bcs, loads,
                                                 base.cg_tolerance, 0, nullptr,
                                                 nullptr, SolverKind::MultigridCG);
      if (c.cg.used_multigrid) { ++mg_used; levels = c.cg.mg_levels; }
      else ++mg_fell_back;
    }
    std::printf(
        "realistic(32^3, cap %d): MultigridCG V-cycle engaged on %d/%zu analysis "
        "densities the loop visited (%d fell back to exact Jacobi-CG); hierarchy "
        "= %d levels; final compliance jac=%.10g mg=%.10g; max|drho|=%.3e over %d "
        "iters\n",
        base.max_iterations, mg_used, mg_fields.size(), mg_fell_back, levels,
        rj.compliance, rm.compliance, max_drho, rm.iterations);
    CHECK(!mg_fields.empty(),
          "realistic: the MultigridCG loop visited at least one analysis density");
  }

  // =========================================================================
  // Objective-plateau detector (handoff 086-mma-plateau). The MMA termination
  // test operates on the compliance curve, NOT the design-space max|drho|. Its
  // core requirement is robustness to MMA's NON-MONOTONE compliance: it must not
  // fire in the flat spot that precedes a productive member toggle. These are
  // pure-function checks on hand-built curves (no solve) so the guard is
  // deterministic and fast.
  // =========================================================================
  {
    using topopt::mma_objective_plateau;

    // Tested at the PRODUCTION default window (10). window <= 0 disables the
    // test; fewer than window+1 samples never fire. The first three groups
    // isolate the WINDOW logic (progress gate off, min_drop = 0); the gate is
    // guarded separately at the end.
    const int W = 10;    // production default (SimpOptions::mma_plateau_window)
    const double G = 0.05;  // production default (SimpOptions::mma_plateau_min_drop)
    CHECK(!mma_objective_plateau({1.0, 0.9, 0.8}, 0, 1e-3, 0.0),
          "plateau: window<=0 disables the test");
    CHECK(!mma_objective_plateau({1.0, 0.9, 0.8}, W, 1e-3, 0.0),
          "plateau: fewer than window+1 samples never fires");

    // A steadily descending curve (running min improving every step) must NOT
    // register a plateau, however long.
    {
      std::vector<double> desc;
      double v = 100.0;
      for (int i = 0; i < 40; ++i) { desc.push_back(v); v *= 0.95; }
      CHECK(!mma_objective_plateau(desc, W, 1e-3, 0.0),
            "plateau: a steadily descending curve never plateaus");
    }

    // THE ANTI-EARLY-TERMINATION GUARD. A curve that descends, sits on a flat
    // spot SHORTER than the window, then a member toggles — compliance spikes and
    // recovers to a NEW, materially lower low — then settles. A naive
    // single-iteration relative-change test fires ON the flat spot (premature:
    // the running min there is ~14.4, far above the true optimum ~9). The
    // running-minimum window test must NOT fire there — the flat spot is shorter
    // than the window, so the window still reaches back to real descent.
    std::vector<double> c = {
        200, 120, 80, 55, 40, 32, 26, 22, 19, 17, 15.5, 14.8, 14.5,  // descent 0-12
        14.450, 14.448, 14.447, 14.4465, 14.446, 14.4457, 14.4455, 14.4454, // flat 13-20
        60.0,                                                        // toggle spike 21
        11.0, 10.0, 9.5, 9.1,                                        // recovery 22-25
        9.000, 8.999, 8.998, 8.9975, 8.997, 8.9968, 8.9967, 8.99665, // settle 26-...
        8.99663, 8.99662, 8.996615, 8.996612, 8.996610, 8.996609,
        8.996609, 8.996609, 8.996609};

    // The naive single-iteration test (|c[i]-c[i-1]|/c[i] < tol) fires early,
    // inside the flat spot (its running minimum is still ~14.4), with well more
    // than window+1 samples present — so the window test's refusal below is a
    // genuine check, not a too-few-samples triviality.
    auto naive_fire = [](const std::vector<double>& v, double tol) {
      for (std::size_t i = 1; i < v.size(); ++i)
        if (std::fabs(v[i] - v[i - 1]) / std::fabs(v[i]) < tol)
          return static_cast<int>(i + 1);  // 1-based
      return -1;
    };
    const int nf = naive_fire(c, 1e-3);
    CHECK(nf > W && nf <= 21,
          "plateau: the naive test fires in the flat spot, past window+1 samples");
    double naive_best = c[0];
    for (int i = 0; i < nf; ++i) naive_best = std::min(naive_best, c[i]);
    CHECK(naive_best > 14.0,
          "plateau: the naive test's design is still ~14.4 (far above optimum ~9)");
    // The guard: the window test does NOT fire at the naive point (the prefix up
    // to nf). This is the assertion that FAILS for a naive window=1 detector.
    std::vector<double> prefix(c.begin(), c.begin() + nf);
    CHECK(!mma_objective_plateau(prefix, W, 1e-3, 0.0),
          "plateau GUARD: window=10 does NOT fire in the pre-toggle flat spot");
    // A degenerate window=1 detector WOULD fire there — proving the guard has
    // teeth (the naive test it must beat).
    CHECK(mma_objective_plateau(prefix, 1, 1e-3, 0.0),
          "plateau GUARD: a naive window=1 detector DOES fire there (must beat)");

    // The full curve does eventually plateau, and only AFTER the productive
    // toggle — the kept design's running min is at the true optimum ~9, not ~14.
    CHECK(mma_objective_plateau(c, W, 1e-3, 0.0),
          "plateau: the settled curve past the toggle registers a plateau");
    // Find the first fire point on the full curve and confirm it is post-toggle.
    int fire = -1;
    for (std::size_t n = 1; n <= c.size(); ++n) {
      std::vector<double> pre(c.begin(), c.begin() + n);
      if (mma_objective_plateau(pre, W, 1e-3, 0.0)) { fire = static_cast<int>(n); break; }
    }
    CHECK(fire > 21, "plateau: the window test fires only AFTER the toggle (iter 22+)");
    double fire_best = c[0];
    for (int i = 0; i < fire; ++i) fire_best = std::min(fire_best, c[i]);
    CHECK(fire_best < 9.2,
          "plateau: at the fire point the running min is the true optimum ~9");
    std::printf("[plateau] naive fires@%d (best~%.2f) | window=10 fires@%d (best~%.3f)\n",
                nf, naive_best, fire, fire_best);

    // THE PROGRESS-GATE GUARD (the vf=0.20 failure). A low-volume rung's early
    // "forming" iterations SPIKE far ABOVE the start value while the design
    // percolates, so the running minimum stays PINNED at c[0] for ~10 iterations
    // before the compliance plummets. Without the gate the window test reads
    // "0% improvement over the window" at iter 11 and fires, keeping a
    // near-uniform design (~30x the optimum). This is the exact shape MEASURED on
    // a vf=0.20 self-weight cube (c[0]~18.4, iters 2-11 spike to ~1e5-1e6, then a
    // descent to ~2.3). The gate blocks the fire until the running min has
    // dropped `min_drop` below c[0].
    std::vector<double> spike = {
        18.4, 6.4e5, 1.6e4, 46.9, 1.0e5, 1.3e6, 4.7e4, 3.4e6, 9.2e5,  // 0-8
        1.4e4, 1177.0, 69.5, 23.7, 12.6,                              // 9-13 (min pinned at 18.4)
        9.5, 7.5, 6.0, 4.9, 4.1, 3.5, 3.1, 2.8, 2.6, 2.5,            // 14-23 descent
        2.45, 2.42, 2.40, 2.395};                                    // 24-27 descent
    for (int i = 0; i < 16; ++i) spike.push_back(2.39);              // 28-43 flat settle
    // The running minimum is pinned at c[0]=18.4 through iter 13 (all spikes are
    // above it), so at iter 11 the window improvement is exactly zero.
    std::vector<double> spike11(spike.begin(), spike.begin() + 11);
    CHECK(!mma_objective_plateau(spike11, W, 1e-3, G),
          "plateau GATE: does NOT fire in the spike-heavy forming phase (iter 11)");
    // With NO gate (min_drop = 0) the very same prefix DOES fire — proving the
    // gate is what prevents the near-uniform design (the bug it fixes).
    CHECK(mma_objective_plateau(spike11, W, 1e-3, 0.0),
          "plateau GATE: without the gate the forming-phase prefix fires (the bug)");
    // The gated detector fires only once the objective has genuinely settled,
    // deep in the descent (running min ~2.39, near the ~2.387 optimum).
    int gfire = -1;
    for (std::size_t n = 1; n <= spike.size(); ++n) {
      std::vector<double> pre(spike.begin(), spike.begin() + n);
      if (mma_objective_plateau(pre, W, 1e-3, G)) { gfire = static_cast<int>(n); break; }
    }
    CHECK(gfire > 30, "plateau GATE: fires only after the descent settles (iter 30+)");
    double gbest = spike[0];
    for (int i = 0; i < gfire; ++i) gbest = std::min(gbest, spike[i]);
    CHECK(gbest < 2.45,
          "plateau GATE: at the gated fire point the design is near-optimal (~2.39)");
    std::printf("[plateau gate] ungated fires@11 (best~18.4) | gated fires@%d (best~%.2f)\n",
                gfire, gbest);
  }

  if (g_failures == 0) {
    std::printf("simp: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "simp: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
